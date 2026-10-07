#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "py safety: create never replaces an existing .venv" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project/.venv"
    print -r -- "version = 3.12.1" >"$project/.venv/pyvenv.cfg"
    cd "$project" || return 1
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    venv-create --uv --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$HOME/project/.venv/pyvenv.cfg" ]
  [ ! -e "$HOME/uv-called" ]
  [[ "$output" == *"/project/.venv already exists; venv-create never replaces it."* ]]
}

@test "py safety: create dry-run plans without invoking a backend" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project"
    cd "$project" || return 1
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    venv-create --uv --python 3.12 --dry-run
  '

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/project/.venv" ]
  [ ! -e "$HOME/uv-called" ]
}

@test "py safety: non-interactive create fails closed without --yes" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project"
    cd "$project" || return 1
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    venv-create --uv
  ' < /dev/null

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/project/.venv" ]
  [ ! -e "$HOME/uv-called" ]
}

@test "py safety: remove rejects external environments and preserves them" {
  run run_zsh '
    local project="$HOME/project"
    local external="$HOME/external"
    command mkdir -p "$project" "$external"
    print -r -- "version = 3.12.1" >"$external/pyvenv.cfg"
    cd "$project" || return 1
    venv-remove --path "$external" --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$HOME/external/pyvenv.cfg" ]
  [[ "$output" == *"not in the validated discovery snapshot"* ]]
}

@test "py safety: remove dry-run preserves a fingerprinted local environment" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project/.venv"
    print -r -- "version = 3.12.1" >"$project/.venv/pyvenv.cfg"
    cd "$project" || return 1
    NO_COLOR=1 venv-remove --path "$project/.venv" --dry-run
  '

  [ "$status" -eq 0 ]
  [ -f "$HOME/project/.venv/pyvenv.cfg" ]
  printf '%s\n' "$output" | grep -Eq '^  Environment: +(~|/.*)/project/[.]venv$'
  printf '%s\n' "$output" | grep -Eq '^  Python: +3[.]12[.]1$'
  [[ "$output" == *"➜ Dry run: nothing was removed."* ]]
  # Internal identities are revalidated, not displayed.
  [[ "$output" != *"ingerprint"* ]]
}

@test "py safety: rebuild is fail-closed even with --yes" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project/.venv"
    print -r -- "version = 3.12.1" >"$project/.venv/pyvenv.cfg"
    cd "$project" || return 1
    venv-rebuild --path "$project/.venv" --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$HOME/project/.venv/pyvenv.cfg" ]
  [[ "$output" == *"Automatic rebuild is disabled"* ]]
  [[ "$output" == *"Nothing was changed."* ]]
}

@test "py safety: activation revalidates script content after confirmation" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project/.venv/bin"
    print -r -- "version = 3.12.1" >"$project/.venv/pyvenv.cfg"
    print -r -- "export SAFE_ACTIVATED=1" >"$project/.venv/bin/activate"
    cd "$project" || return 1
    _py_confirm() {
      print -r -- "export UNSAFE_ACTIVATED=1" >"$project/.venv/bin/activate"
      return 0
    }
    venv-activate --path "$project/.venv"
    local activate_rc=$?
    [[ -z "${SAFE_ACTIVATED:-}" && -z "${UNSAFE_ACTIVATED:-}" ]]
    return $activate_rc
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed after review"* ]]
}

@test "py safety: package operations reject option-like names before probes" {
  run run_zsh '
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    package-install --malicious
  '

  [ "$status" -eq 2 ]
  [ ! -e "$HOME/uv-called" ]
}

@test "py safety: package install never falls back to ambient pip" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project"
    cd "$project" || return 1
    pip() {
      print -r -- called >"$HOME/pip-called"
      return 0
    }
    package-install ruff --yes
  '

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/pip-called" ]
  [[ "$output" == *"ambient pip installation is never used"* ]]
}

@test "py safety: remote tool install supports a side-effect-free dry-run" {
  run run_zsh '
    uv() {
      print -r -- "$*" >"$HOME/uv-called"
      return 0
    }
    tool-install ruff --backend uv --dry-run
  '

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/uv-called" ]
  [[ "$output" == *"downloads and installs executable package code"* ]]
}

@test "py safety: invalid Python versions fail before uv is invoked" {
  run run_zsh '
    uv() {
      print -r -- called >"$HOME/uv-called"
      return 0
    }
    venv-python-install "../3.12" --yes
  '

  [ "$status" -eq 2 ]
  [ ! -e "$HOME/uv-called" ]
}

@test "py safety: PyPI metadata keeps the caller umask and removes its private files" {
  export TMPDIR="$TEST_TEMP_DIR/pypi-tmp"
  mkdir -m 700 "$TMPDIR"
  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env zsh
local output="" previous="" argument=""
for argument in "$@"; do
  [[ "$previous" == --output ]] && output="$argument"
  previous="$argument"
done
[[ -n "$output" ]] || exit 9
print -r -- '{"info":{"name":"demo","version":"1.2.3","summary":"Demo\u0007 package","requires_python":">=3.9","project_url":"https://pypi.org/project/demo/"}}' > "$output"
EOF
  chmod +x "$TEST_MOCK_BIN/curl"

  run run_zsh 'umask 022; NO_COLOR=1 package-search demo; rc=$?; print -r -- "umask:$(umask) rc:$rc"'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  Name: +demo$'
  printf '%s\n' "$output" | grep -Eq '^  Version: +1[.]2[.]3$'
  printf '%s\n' "$output" | grep -Fq 'Demo\x07 package'
  [[ "$output" == *"umask:022 rc:0"* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]

  printf '#!/bin/sh\nexit 22\n' > "$TEST_MOCK_BIN/curl"
  run run_zsh 'umask 022; package-search demo; rc=$?; print -r -- "umask:$(umask) rc:$rc"'
  [[ "$output" == *"PyPI metadata request failed (status 22)."* ]]
  [[ "$output" == *"umask:022 rc:22"* ]]
  [[ "$output" != *"refusing cleanup"* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "py safety: uv environments report the version recorded as version_info" {
  run run_zsh '
    local project="$HOME/project"
    command mkdir -p "$project/.venv"
    print -rl -- "home = /usr/bin" "version_info = 3.13.15" \
      >"$project/.venv/pyvenv.cfg"
    cd "$project" || return 1
    NO_COLOR=1 venv-list
    NO_COLOR=1 venv-info --path "$project/.venv"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  [.]venv +3[.]13[.]15 +inactive$'
  printf '%s\n' "$output" | grep -Eq '^  Python: +3[.]13[.]15$'
  [[ "$output" != *"unknown"* ]]
}

@test "py safety: tool inventories print a table and keep backend diagnostics private" {
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env zsh
[[ "$*" == "tool list" ]] || exit 97
print -rl -- 'ruff v0.6.9' '- ruff' 'black v24.1.0' '- black'
print -u2 -r -- 'warning: uv diagnostic'
EOF
  cat > "$TEST_MOCK_BIN/pipx" <<'EOF'
#!/usr/bin/env zsh
[[ "$*" == "list --short" ]] || exit 97
print -u2 -r -- 'nothing has been installed with pipx'
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/pipx"

  run run_zsh 'NO_COLOR=1 tool-list'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  Tool +Backend +Version$'
  printf '%s\n' "$output" | grep -Eq '^  ruff +uv +0[.]6[.]9$'
  printf '%s\n' "$output" | grep -Eq '^  black +uv +24[.]1[.]0$'
  [[ "$output" != *"nothing has been installed"* ]]
  [[ "$output" != *"uv diagnostic"* ]]
}

@test "py safety: managed Python runtimes print a table without uv warnings" {
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env zsh
[[ "$*" == "python list --only-installed --managed-python" ]] || exit 97
print -u2 -r -- 'warning: Failed to inspect Python interpreter'
print -r -- "cpython-3.13.15-linux-x86_64-gnu    $HOME/.local/share/uv/python/cpython-3.13/bin/python3.13"
print -r -- "cpython-3.12.4-linux-x86_64-gnu     $HOME/.local/bin/python3.12 -> $HOME/.local/share/uv/python/cpython-3.12/bin/python3.12"
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'NO_COLOR=1 venv-python-list'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq \
    '^  3[.]13[.]15 +~/[.]local/share/uv/python/cpython-3[.]13/bin/python3[.]13$'
  printf '%s\n' "$output" | grep -Eq '^  3[.]12[.]4 +~/[.]local/bin/python3[.]12$'
  [[ "$output" != *"Failed to inspect"* ]]
}

@test "py safety: a runtime install reports the version it added" {
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env zsh
case "$*" in
  'python list --only-installed --managed-python')
    [[ -e "$HOME/installed-3.12" ]] \
      && print -r -- "cpython-3.12.13-linux-x86_64-gnu    $HOME/py/bin/python3.12"
    print -r -- "cpython-3.11.9-linux-x86_64-gnu    $HOME/py/bin/python3.11"
    ;;
  'python install 3.12')
    print -r -- 'Installed Python 3.12.13 in 1.2s'
    : > "$HOME/installed-3.12"
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'NO_COLOR=1 venv-python-install 3.12 --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *'$ uv python install 3.12  (output shown on failure)'* ]]
  [[ "$output" == *"✔ Installed Python 3.12.13."* ]]
  [[ "$output" != *"in 1.2s"* ]]

  run run_zsh 'NO_COLOR=1 venv-python-install 3.12 --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"✔ Python 3.12 was already installed."* ]]
}
