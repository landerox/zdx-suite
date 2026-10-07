#!/usr/bin/env bats
# Developer behavior on macOS and WSL hosts, selected through mocks and
# fixtures rather than the runner: the metadata interpreter, Windows launchers
# on the WSL PATH, DrvFs modes, Command Line Tools placeholders, Homebrew
# prefixes, network probe advice, hard-link publication, and menu marks.
# Quoted programs execute in Zsh; each BATS test owns its exported mock state.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  mkdir -p "$DEV_PROJECT"
}

teardown() {
  cleanup_sandbox
}

# Sets REAL_PYTHON to a host interpreter with the standard tomllib. Fixtures
# wrap it; the product reaches it only through those wrappers. The
# interpreter's own sys.executable is used because a version-manager shim,
# such as pyenv's, can stop working once a fixture shadows python3 on PATH.
find_real_python() {
  local candidate resolved executable
  for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
    resolved=$(command -v "$candidate" 2>/dev/null) || continue
    executable=$("$resolved" -I -S -c \
      'import sys, tomllib; print(sys.executable)' 2>/dev/null) || continue
    [[ "$executable" == /* && -x "$executable" ]] || continue
    export REAL_PYTHON="$executable"
    return 0
  done
  return 1
}

# A python3 like the 3.9 of Apple's Command Line Tools: it runs, but it has
# no tomllib. Each invocation is logged as `probe` or `other`.
write_old_python3() {
  export OLD_PYTHON_LOG="$TEST_TEMP_DIR/old-python3.log"
  cat > "$TEST_MOCK_BIN/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-I -S -c import tomllib" ]]; then
  printf 'probe\n' >> "$OLD_PYTHON_LOG"
  printf "ModuleNotFoundError: No module named 'tomllib'\n" >&2
  exit 1
fi
printf 'other\n' >> "$OLD_PYTHON_LOG"
[[ "$*" == "--version" ]] && { printf 'Python 3.9.6\n'; exit 0; }
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/python3"
}

# A working interpreter under <name> that logs `probe` for the tomllib probe
# and its first two arguments for every other invocation.
# Usage: write_python_wrapper <name> <log>
write_python_wrapper() {
  local name="$1" log="$2"
  cat > "$TEST_MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "-I -S -c import tomllib" ]]; then
  printf 'probe\n' >> "$log"
else
  printf '%s %s\n' "\${1:-}" "\${2:-}" >> "$log"
fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod +x "$TEST_MOCK_BIN/$name"
}

# Present but unusable commands, so host interpreters cannot answer for them.
write_unusable_commands() {
  local name
  for name in "$@"; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_MOCK_BIN/$name"
    chmod +x "$TEST_MOCK_BIN/$name"
  done
}

write_demo_pyproject() {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["requests>=2"]

[tool.pytest.ini_options]
addopts = "-q"
EOF
}

write_failing_xcode_select() {
  cat > "$TEST_MOCK_BIN/xcode-select" <<'EOF'
#!/usr/bin/env bash
printf 'xcode-select: error: unable to get active developer directory\n' >&2
exit 2
EOF
  chmod +x "$TEST_MOCK_BIN/xcode-select"
}

write_probe_curl_mock() {
  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Honors -w with CURL_MOCK_WRITE and exits with CURL_MOCK_STATUS.
write_format=""
while (( $# > 0 )); do
  case "$1" in
    -w) write_format="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$write_format" ]] && printf '%s' "${CURL_MOCK_WRITE:-000 0.000 0 }"
exit "${CURL_MOCK_STATUS:-28}"
EOF
  chmod +x "$TEST_MOCK_BIN/curl"
}

# --- Metadata interpreter ---------------------------------------------------

@test "dev platform: metadata readers pass over an old python3 to python3.12" {
  find_real_python || skip "these fixtures need a Python 3.11+ interpreter"
  write_demo_pyproject
  write_old_python3
  write_unusable_commands python3.14 python3.13
  export GOOD_PYTHON_LOG="$TEST_TEMP_DIR/python3.12.log"
  write_python_wrapper python3.12 "$GOOD_PYTHON_LOG"
  export UV_LOG="$TEST_TEMP_DIR/uv.log"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    local _DEV_RUN_PYTHON=""
    _dev_python_toml_resolve || return 1
    print -r -- "resolved=$REPLY"
    _dev_pyproject_main_deps
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved=$TEST_MOCK_BIN/python3.12"* ]]
  printf '%s\n' "$output" | grep -Fxq 'requests'
  # python3 was probed once and never used to parse.
  [ "$(cat "$OLD_PYTHON_LOG")" = "probe" ]
  [ "$(grep -c '^-I -S$' "$GOOD_PYTHON_LOG")" -eq 1 ]
  [ ! -e "$UV_LOG" ]
}

@test "dev platform: a uv-managed Python 3.11+ answers when PATH has none" {
  find_real_python || skip "these fixtures need a Python 3.11+ interpreter"
  write_demo_pyproject
  write_old_python3
  write_unusable_commands python3.14 python3.13 python3.12 python3.11
  export UV_LOG="$TEST_TEMP_DIR/uv.log"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_LOG"
if [[ "$*" == "python find --system --no-project >=3.11" ]]; then
  printf '%s\n' "$REAL_PYTHON"
  exit 0
fi
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    local _DEV_RUN_PYTHON=""
    _dev_python_toml_resolve || return 1
    print -r -- "resolved=$REPLY"
    _dev_pyproject_has_dep requests
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved=$REAL_PYTHON"* ]]
  # --system keeps uv from answering with an unvalidated virtual environment.
  [ "$(cat "$UV_LOG")" = "python find --system --no-project >=3.11" ]
}

@test "dev platform: the validated project .venv interpreter is the last candidate" {
  find_real_python || skip "these fixtures need a Python 3.11+ interpreter"
  write_demo_pyproject
  write_old_python3
  write_unusable_commands python3.14 python3.13 python3.12 python3.11 uv
  "$REAL_PYTHON" -m venv --without-pip "$DEV_PROJECT/.venv" \
    || skip "the venv module is unavailable for $REAL_PYTHON"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_python_toml_resolve || return 1
    print -r -- "resolved=$REPLY"
    _dev_pyproject_has_dep requests
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved=$DEV_PROJECT/.venv/bin/python"* ]]

  # Without that environment no candidate qualifies, and no parser runs.
  rm -r "$DEV_PROJECT/.venv"
  : > "$OLD_PYTHON_LOG"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pyproject_has_dep requests
  '

  [ "$status" -eq 2 ]
  [[ "$output" == *"Python 3.11+ with tomllib is required to parse pyproject.toml."* ]]
  [[ "$output" != *"uv python pin"* ]]
  [ "$(cat "$OLD_PYTHON_LOG")" = "probe" ]
}

@test "dev platform: one command run resolves the interpreter once" {
  find_real_python || skip "these fixtures need a Python 3.11+ interpreter"
  write_demo_pyproject
  : > "$DEV_PROJECT/module.py"
  write_old_python3
  write_unusable_commands python3.14 python3.13
  export GOOD_PYTHON_LOG="$TEST_TEMP_DIR/python3.12.log"
  write_python_wrapper python3.12 "$GOOD_PYTHON_LOG"

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      case "${1:-}:${2:-}" in
        -v:ty|-v:pyright) return 1 ;;
      esac
      builtin command "$@"
    }
    dev-menu dev-check-types
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"No type checker found."* ]]
  # One probe per candidate, then two parses with the remembered interpreter.
  [ "$(cat "$OLD_PYTHON_LOG")" = "probe" ]
  [ "$(grep -c '^probe$' "$GOOD_PYTHON_LOG")" -eq 1 ]
  [ "$(grep -c '^-I -S$' "$GOOD_PYTHON_LOG")" -eq 2 ]

  # Outside a command run each use resolves again, so PATH changes are seen.
  : > "$OLD_PYTHON_LOG"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_require_python_toml && _dev_require_python_toml
  '

  [ "$status" -eq 0 ]
  [ "$(grep -c '^probe$' "$OLD_PYTHON_LOG")" -eq 2 ]
}

@test "dev platform: every metadata reader runs isolated without site" {
  find_real_python || skip "these fixtures need a Python 3.11+ interpreter"
  write_demo_pyproject
  cat > "$DEV_PROJECT/uv.lock" <<'EOF'
version = 1

[[package]]
name = "requests"
version = "2.32.3"
EOF
  write_old_python3
  write_unusable_commands python3.14 python3.13
  export GOOD_PYTHON_LOG="$TEST_TEMP_DIR/python3.12.log"
  write_python_wrapper python3.12 "$GOOD_PYTHON_LOG"

  run run_zsh '
    cd "$DEV_PROJECT"
    local _DEV_RUN_PYTHON=""
    _dev_pyproject_has_dep requests || return 1
    [[ "$(_dev_pyproject_requires_python)" == ">=3.11" ]] || return 2
    [[ "$(_dev_update_lock_versions uv.lock)" == "requests"$'\''\t'\''"2.32.3" ]] \
      || return 3
    _dev_has_pytest_config || return 4
    _dev_update_file_fingerprint "$PWD/pyproject.toml" || return 5
  '

  [ "$status" -eq 0 ]
  [ "$(grep -c '^probe$' "$GOOD_PYTHON_LOG")" -eq 1 ]
  [ "$(grep -c '^-I -S$' "$GOOD_PYTHON_LOG")" -eq 5 ]
  ! grep -Evx 'probe|-I -S' "$GOOD_PYTHON_LOG" || false
}

@test "dev platform: python3 is no hard dependency when python3.12 qualifies" {
  find_real_python || skip "these fixtures need a Python 3.11+ interpreter"
  write_demo_pyproject
  write_unusable_commands python3.14 python3.13
  export GOOD_PYTHON_LOG="$TEST_TEMP_DIR/python3.12.log"
  write_python_wrapper python3.12 "$GOOD_PYTHON_LOG"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/uv"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/curl"
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/curl"

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "python3" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    _dev_verify_deps dev-update-deps || return 1
    _dev_verify_deps dev-check-outdated || return 2
    _dev_require_python_toml || return 3
    print -r -- "resolved=$REPLY"
    local REPLY
    _dev_menu_missing_requirements dev-update-deps reply || return 4
    print -r -- "missing=<$REPLY>"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"resolved=$TEST_MOCK_BIN/python3.12"* ]]
  [[ "$output" == *"missing=<>"* ]]
  [[ "$output" != *"Missing required dependency"* ]]
}

@test "dev platform: a missing Python 3.11+ names this platform's installers" {
  printf 'ID=ubuntu\nID_LIKE=debian\n' > "$TEST_TEMP_DIR/os-ubuntu"
  printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\n' > "$TEST_TEMP_DIR/os-mint"
  printf 'ID=fedora\n' > "$TEST_TEMP_DIR/os-fedora"

  run run_zsh 'OSTYPE=darwin23.0; _dev_python_install_hint'
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 or python3.11 through python3.14 on PATH, or a uv-managed Python"* ]]
  [[ "$output" == *"brew install python@3.14"* ]]
  [[ "$output" == *"uv python install 3.14"* ]]
  [[ "$output" != *"deadsnakes"* ]]
  [[ "$output" != *"uv python pin"* ]]

  local release
  for release in ubuntu mint; do
    run run_zsh "OSTYPE=linux-gnu; _dev_python_install_hint '$TEST_TEMP_DIR/os-$release'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"uv python install 3.14"* ]]
    [[ "$output" == *"ppa:deadsnakes/ppa"* ]]
    [[ "$output" == *"sudo apt install python3.14"* ]]
    [[ "$output" != *"brew install"* ]]
  done

  run run_zsh "OSTYPE=linux-gnu; _dev_python_install_hint '$TEST_TEMP_DIR/os-fedora'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uv python install 3.14"* ]]
  [[ "$output" == *"distribution's Python 3.11+ package"* ]]
  [[ "$output" != *"deadsnakes"* ]]
}

# --- Python pins ------------------------------------------------------------

@test "dev platform: a commented CRLF Python pin selects its minor" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
requires-python = ">=3.11"
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" ]]; then
  printf 'CPython\n'
  exit 0
fi
printf 'Python 3.11.9\n'
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/uv"
  chmod +x "$TEST_MOCK_BIN/uv"
  # As `uv python pin` writes it, saved with Windows line endings.
  printf '# Managed by uv\r\n3.11\r\n' > "$DEV_PROJECT/.python-version"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_read_python_pin || return 1
    print -r -- "pin=<$REPLY>"
    _dev_update_python_rebuild() { print -r -- "rebuild request=$5"; }
    dev-update-python --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"pin=<3.11>"* ]]
  [[ "$output" == *"Python minor selected for patch upgrade: 3.11"* ]]
  [[ "$output" == *"rebuild request=3.11"* ]]

  # Comment lines never count as a request; two requests stay ambiguous.
  printf '# Managed by uv\r\n3.11\r\n3.12\r\n' > "$DEV_PROJECT/.python-version"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_update_python_rebuild() { print -r -- "rebuild request=$5"; }
    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *".python-version must contain exactly one Python request."* ]]
  [[ "$output" == *"py-menu venv-python-pin <major.minor>"* ]]
  [[ "$output" != *"rebuild request"* ]]
}

# --- Host detection ---------------------------------------------------------

@test "dev platform: WSL1 and WSL2 are told apart from the kernel release" {
  mkdir -p "$TEST_TEMP_DIR/proc/sys/kernel" "$TEST_TEMP_DIR/proc/sys/fs/binfmt_misc"

  run run_zsh '
    unset WSL_DISTRO_NAME WSL_INTEROP
    OSTYPE=linux-gnu
    local proc="$TEST_TEMP_DIR/proc"
    check() {
      print -r -- "$2" > "$proc/sys/kernel/osrelease"
      local REPLY=""
      _dev_host_wsl_version "$proc"
      print -r -- "$1:$?:$REPLY"
    }
    check wsl1 4.4.0-19041-Microsoft
    check wsl2 5.15.153.1-microsoft-standard-WSL2
    check linux 6.8.0-45-generic
    : > "$proc/sys/fs/binfmt_misc/WSLInterop"
    check custom-kernel 6.6.36-custom
    OSTYPE=darwin23.0
    check darwin 5.15.153.1-microsoft-standard-WSL2
  '

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fxq 'wsl1:0:wsl1'
  printf '%s\n' "$output" | grep -Fxq 'wsl2:0:wsl2'
  printf '%s\n' "$output" | grep -Fxq 'linux:1:'
  printf '%s\n' "$output" | grep -Fxq 'custom-kernel:0:wsl2'
  printf '%s\n' "$output" | grep -Fxq 'darwin:1:'
}

# --- Windows launchers and DrvFs on WSL ---------------------------------------

@test "dev platform: Windows launchers on the WSL PATH count as missing tools" {
  : > "$DEV_PROJECT/README.md"

  # zsh `hash` stands in for the appended Windows PATH, so nothing is created
  # under a real /mnt drive.
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=linux-gnu
    DEV_ALLOW_EPHEMERAL=1
    _dev_host_wsl_version() { REPLY=wsl2; return 0; }
    hash markdownlint=/mnt/c/Users/demo/AppData/Roaming/npm/markdownlint
    hash npx="/mnt/c/Program Files/nodejs/npx"

    _dev_have_command markdownlint && return 11
    _dev_have_command npx && return 12
    _dev_node_tool_available markdownlint && return 13
    _dev_menu_entry "Lint Markdown" dev-run-markdownlint "Check Markdown style."
    _dev_require_command markdownlint
    print -r -- "require_status=$?"
    dev-run-markdownlint
    print -r -- "run_status=$?"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"  ○ Lint Markdown (missing: markdownlint)|dev-run-markdownlint|Check Markdown style."* ]]
  [[ "$output" == *"require_status=1"* ]]
  [[ "$output" == *"markdownlint on PATH is a Windows program: /mnt/c/Users/demo/AppData/Roaming/npm/markdownlint"* ]]
  [[ "$output" == *"Install a Linux markdownlint inside WSL."* ]]
  [[ "$output" == *"run_status=1"* ]]

  # A Linux build inside WSL is a tool, and native Linux keeps every path.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/markdownlint"
  chmod +x "$TEST_MOCK_BIN/markdownlint"
  run run_zsh '
    OSTYPE=linux-gnu
    _dev_host_wsl_version() { REPLY=wsl2; return 0; }
    _dev_have_command markdownlint || return 1
    _dev_host_wsl_version() { REPLY=""; return 1; }
    hash npx="/mnt/c/Program Files/nodejs/npx"
    _dev_have_command npx
  '
  [ "$status" -eq 0 ]
}

@test "dev platform: DrvFs mode refusals on WSL explain the supported remedies" {
  run run_zsh '
    OSTYPE=linux-gnu
    _dev_host_wsl_version() { REPLY=wsl2; return 0; }
    for candidate in /mnt/c/Users/demo/project /mnt/d /mnt/cdrom/x \
      /mnt/wsl/shared "$HOME/mnt/c/project"; do
      _dev_path_on_windows_drive "$candidate"
      print -r -- "$candidate:$?"
    done
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fxq '/mnt/c/Users/demo/project:0'
  printf '%s\n' "$output" | grep -Fxq '/mnt/d:0'
  printf '%s\n' "$output" | grep -Fxq '/mnt/cdrom/x:1'
  printf '%s\n' "$output" | grep -Fxq '/mnt/wsl/shared:1'
  printf '%s\n' "$output" | grep -Fxq "$HOME/mnt/c/project:1"

  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  mkdir -m 777 "$DEV_PROJECT/.dev-suite-backups"

  # DrvFs without metadata accepts chmod but keeps every mode at 777; the
  # project stands in for one below /mnt/c.
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=linux-gnu
    _dev_host_wsl_version() { REPLY=wsl2; return 0; }
    _dev_path_on_windows_drive() { return 0; }
    command() {
      [[ "${1:-}" == chmod ]] && return 0
      builtin command "$@"
    }
    _dev_backup_pyproject
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"The backup directory must be private (mode 700)"* ]]
  [[ "$output" == *"Windows drive (DrvFs), which reports every file as mode 777"* ]]
  [[ "$output" == *"Linux home (~)"* ]]
  [[ "$output" == *'options = "metadata,umask=22,fmask=11"'* ]]
  [[ "$output" == *"wsl.exe --shutdown"* ]]
  [ -z "$(find "$DEV_PROJECT/.dev-suite-backups" -mindepth 1 -print -quit)" ]

  # The same refusal on native Linux names no WSL remedy.
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=linux-gnu
    _dev_host_wsl_version() { REPLY=""; return 1; }
    _dev_path_on_windows_drive() { return 0; }
    command() {
      [[ "${1:-}" == chmod ]] && return 0
      builtin command "$@"
    }
    _dev_backup_pyproject
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be private (mode 700)"* ]]
  [[ "$output" != *"DrvFs"* ]]

  # A world-writable project directory refuses rollback with the same remedy.
  chmod -- 777 "$DEV_PROJECT"
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=linux-gnu
    _dev_host_wsl_version() { REPLY=wsl2; return 0; }
    _dev_path_on_windows_drive() { return 0; }
    _dev_write_directory_identity "$PWD" "project directory"
  '
  chmod -- 755 "$DEV_PROJECT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing a group/world-writable project directory"* ]]
  [[ "$output" == *"Windows drive (DrvFs)"* ]]
}

# --- macOS ------------------------------------------------------------------

@test "dev platform: macOS Command Line Tools placeholders are never run" {
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  write_failing_xcode_select
  export PLACEHOLDER_RUN_LOG="$TEST_TEMP_DIR/placeholder-runs.log"

  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=darwin23.0
    hash python3=/usr/bin/python3 git=/usr/bin/git
    command() {
      case "${1:-}:${2:-}" in
        -v:python3.1[1-4]|-v:uv) return 1 ;;
      esac
      case "${1:-}" in
        git|python3|/usr/bin/git|/usr/bin/python3)
          print -r -- "$*" >> "$PLACEHOLDER_RUN_LOG"
          ;;
      esac
      builtin command "$@"
    }
    _dev_have_command python3 && return 11
    _dev_have_command git && return 12
    _dev_python_toml_resolve && return 13
    _dev_require_command git
    print -r -- "git_status=$?"
    _dev_require_python_toml
    print -r -- "python_status=$?"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"git_status=1"* ]]
  [[ "$output" == *"/usr/bin/git is the Apple Command Line Tools placeholder"* ]]
  [[ "$output" == *"xcode-select --install"* ]]
  [[ "$output" == *"python_status=1"* ]]
  [[ "$output" == *"brew install python@3.14"* ]]
  [ ! -e "$PLACEHOLDER_RUN_LOG" ]

  # uv would query the placeholder python3 too, so it may answer only with
  # its own installations.
  export UV_LOG="$TEST_TEMP_DIR/uv.log"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_LOG"
exit 2
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=darwin23.0
    hash python3=/usr/bin/python3
    command() {
      case "${1:-}:${2:-}" in
        -v:python3.1[1-4]) return 1 ;;
      esac
      builtin command "$@"
    }
    _dev_python_toml_resolve
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$UV_LOG")" = \
    "python find --system --no-project --python-preference only-managed >=3.11" ]
  rm "$TEST_MOCK_BIN/uv"

  # Health reports both gaps once, still without running a placeholder.
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=darwin23.0
    hash python3=/usr/bin/python3 git=/usr/bin/git
    command() {
      case "${1:-}:${2:-}" in
        -v:python3.1[1-4]|-v:uv) return 1 ;;
      esac
      case "${1:-}" in
        git|python3|/usr/bin/git|/usr/bin/python3)
          print -r -- "$*" >> "$PLACEHOLDER_RUN_LOG"
          ;;
      esac
      builtin command "$@"
    }
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"pyproject.toml found but not parsed"* ]]
  [[ "$output" == *"git not found."* ]]
  [[ "$output" == *"Python 3.11+ with tomllib was not found for project metadata."* ]]
  [[ "$output" != *"could not be parsed safely"* ]]
  [ ! -e "$PLACEHOLDER_RUN_LOG" ]

  # Once xcode-select reports the tools, /usr/bin/git is the real Git.
  cat > "$TEST_MOCK_BIN/xcode-select" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$TEST_TEMP_DIR"
EOF
  run run_zsh '
    OSTYPE=darwin23.0
    hash git=/usr/bin/git
    _dev_have_command git
  '
  [ "$status" -eq 0 ]
}

@test "dev platform: probe advice uses each platform's tools" {
  write_probe_curl_mock

  # BSD ping sets Don't Fragment with -D, and macOS keeps DNS in scutil.
  run run_zsh '
    export CURL_MOCK_STATUS=28 CURL_MOCK_WRITE="000 0.000 1 151.101.0.223"
    OSTYPE=darwin23.0
    _dev_pypi_check_connectivity
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"smaller MTU"* ]]
  [[ "$output" == *"ping -D -s 1364 -c1 pypi.org"* ]]
  [[ "$output" != *"-M do"* ]]
  [[ "$output" != *"eth0"* ]]

  run run_zsh '
    export CURL_MOCK_STATUS=6 CURL_MOCK_WRITE="000 0.000 0 "
    OSTYPE=darwin23.0
    _dev_pypi_check_connectivity
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"scutil --dns"* ]]
  [[ "$output" != *"resolv.conf"* ]]

  run run_zsh '
    export CURL_MOCK_STATUS=6 CURL_MOCK_WRITE="000 0.000 0 "
    OSTYPE=linux-gnu
    _dev_pypi_check_connectivity
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"/etc/resolv.conf"* ]]
  [[ "$output" != *"scutil"* ]]

  # WSL1 shares the Windows network stack: the eth0 remedy is WSL2-only.
  run run_zsh '
    export CURL_MOCK_STATUS=28 CURL_MOCK_WRITE="000 0.000 1 151.101.0.223"
    OSTYPE=linux-gnu
    _dev_host_wsl_version() { REPLY=wsl1; return 0; }
    _dev_pypi_check_connectivity
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"WSL1 shares the Windows network stack"* ]]
  [[ "$output" != *"eth0"* ]]
  [[ "$output" != *"WSL2"* ]]
}

@test "dev platform: Homebrew ownership follows the prefix that owns the binary" {
  export PATH_BREW_PREFIX="$TEST_TEMP_DIR/opt/homebrew"
  export OTHER_BREW_PREFIX="$TEST_TEMP_DIR/usr/local"
  export OTHER_BREW_LOG="$TEST_TEMP_DIR/other-brew.log"
  mkdir -p "$PATH_BREW_PREFIX/bin" "$OTHER_BREW_PREFIX/bin"

  # The brew on PATH reports its own prefix; the second installation's brew
  # must never run.
  cat > "$TEST_MOCK_BIN/brew" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--prefix" ]]; then
  printf '%s\n' "$PATH_BREW_PREFIX"
  exit 0
fi
exit 97
EOF
  cat > "$OTHER_BREW_PREFIX/bin/brew" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OTHER_BREW_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/brew" "$OTHER_BREW_PREFIX/bin/brew"

  local tool version
  for tool in terraform tflint; do
    version=1.9.0
    [[ "$tool" == tflint ]] && version=0.61.0
    mkdir -p "$OTHER_BREW_PREFIX/Cellar/$tool/$version/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' \
      > "$OTHER_BREW_PREFIX/Cellar/$tool/$version/bin/$tool"
    chmod +x "$OTHER_BREW_PREFIX/Cellar/$tool/$version/bin/$tool"
    ln -s "$OTHER_BREW_PREFIX/Cellar/$tool/$version/bin/$tool" \
      "$TEST_MOCK_BIN/$tool"
  done

  run run_zsh 'dev-update-terraform'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Managed by the Homebrew at $OTHER_BREW_PREFIX, not the brew on PATH."* ]]
  [[ "$output" == *"$OTHER_BREW_PREFIX/bin/brew upgrade terraform"* ]]
  [[ "$output" != *"sys-menu update-brew"* ]]

  run run_zsh 'dev-update-tflint'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$OTHER_BREW_PREFIX/bin/brew upgrade tflint"* ]]
  [ ! -e "$OTHER_BREW_LOG" ]

  # A keg outside any Homebrew installation proves no owner.
  rm "$OTHER_BREW_PREFIX/bin/brew"
  run run_zsh 'dev-update-tflint'
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not prove that the active TFLint binary"* ]]
  [[ "$output" != *"Managed by"* ]]
}

# --- Publication ------------------------------------------------------------

@test "dev platform: a filesystem without hard links stops publication at once" {
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  export LN_LOG="$TEST_TEMP_DIR/ln.log"

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "${1:-}" == ln ]]; then
        print -r -- "$*" >> "$LN_LOG"
        print -u2 -r -- "ln: failed to create hard link: Operation not permitted"
        return 1
      fi
      builtin command "$@"
    }
    _dev_backup_pyproject
    print -r -- "backup_status=$?"
    _dev_report_init "Health"
    _dev_report_save health.md
    print -r -- "report_status=$?"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"backup_status=1"* ]]
  [[ "$output" == *"report_status=1"* ]]
  [[ "$output" == *"Could not publish the backup: its filesystem refused the hard link"* ]]
  [[ "$output" == *"Set DEV_BACKUP_DIR to a directory"* ]]
  [[ "$output" == *"Set DEV_REPORT_DIR to a directory"* ]]
  [[ "$output" != *"unique backup filename"* ]]
  [[ "$output" != *"unique report filename"* ]]
  # One attempt each, and the private temporaries are gone.
  [ "$(grep -c '' "$LN_LOG")" -eq 2 ]
  [ -z "$(find "$DEV_PROJECT/.dev-suite-backups" "$DEV_PROJECT/dev-suite-reports" \
    -mindepth 1 -print -quit)" ]
}

# --- Menu marks -------------------------------------------------------------

@test "dev platform: Darwin and WSL menu marks appear only where a command cannot run" {
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/curl"
  chmod +x "$TEST_MOCK_BIN/curl"
  write_failing_xcode_select
  export PYTHON_RUN_LOG="$TEST_TEMP_DIR/python-runs.log"

  # A Mac without the tools: python3 and git are placeholders and no other
  # candidate exists, so only the metadata commands are marked for Python.
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=darwin23.0
    hash python3=/usr/bin/python3 git=/usr/bin/git
    command() {
      case "${1:-}:${2:-}" in
        -v:python3.1[1-4]|-v:uv|-v:uvx) return 1 ;;
      esac
      [[ "${1:-}" == (python3*|/usr/bin/python3) ]] \
        && print -r -- "$*" >> "$PYTHON_RUN_LOG"
      builtin command "$@"
    }
    _dev_menu_rows
  '

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq \
    '  ○ Update Project Dependencies (missing: uv, Python 3.11+)|dev-update-deps|'
  printf '%s\n' "$output" | grep -Fq \
    '  ○ Update Pre-commit Hooks (missing: uv, Python 3.11+)|dev-update-precommit|'
  printf '%s\n' "$output" | grep -Fq \
    '  ○ List Outdated Dependencies (missing: uv, Python 3.11+)|dev-check-outdated|'
  printf '%s\n' "$output" | grep -Fq \
    '  ○ Update GitHub Actions (missing: git, Python 3.11+)|dev-update-actions|'
  [ "$(printf '%s\n' "$output" | grep -c 'Python 3.11+')" -eq 4 ]
  printf '%s\n' "$output" | grep -Fq '  Inspect Python Project Health|dev-check-health|'
  [ ! -e "$PYTHON_RUN_LOG" ]

  # A Homebrew python3.12 is a candidate: the Python mark disappears.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/python3.12"
  chmod +x "$TEST_MOCK_BIN/python3.12"
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=darwin23.0
    hash python3=/usr/bin/python3
    command() {
      case "${1:-}:${2:-}" in
        -v:python3.1[134]|-v:uv|-v:uvx) return 1 ;;
      esac
      builtin command "$@"
    }
    _dev_menu_rows
  '

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq \
    '  ○ Update Project Dependencies (missing: uv)|dev-update-deps|'
  [[ "$output" != *"Python 3.11+"* ]]

  # On WSL a Windows-only markdownlint marks its row; a Linux build does not.
  : > "$DEV_PROJECT/README.md"
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=linux-gnu
    DEV_ALLOW_EPHEMERAL=0
    _dev_host_wsl_version() { REPLY=wsl2; return 0; }
    hash markdownlint=/mnt/c/Users/demo/AppData/Roaming/npm/markdownlint
    _dev_menu_rows
  '

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq \
    '  ○ Lint Markdown (missing: markdownlint)|dev-run-markdownlint|'
  ! printf '%s\n' "$output" | grep -Fq 'Python 3.11+' || false

  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/markdownlint"
  chmod +x "$TEST_MOCK_BIN/markdownlint"
  run run_zsh '
    cd "$DEV_PROJECT"
    OSTYPE=linux-gnu
    _dev_host_wsl_version() { REPLY=wsl2; return 0; }
    _dev_menu_rows
  '

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq '  Lint Markdown|dev-run-markdownlint|'
}
