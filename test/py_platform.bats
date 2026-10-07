#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Python portability: macOS, WSL, and standalone branches reproduced on any
# host through uname mocks, PATH shims, function overrides, and fixtures.

setup() {
  PY_PLATFORM_ORIGINAL_PATH="$PATH"
  load test_helper
  export PY_PROJECT="$HOME/project"
  mkdir -m 700 "$PY_PROJECT"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env zsh
[[ "$*" == "tool list" ]] || exit 97
print -rl -- 'ruff v0.6.9' '- ruff'
EOF
  cat > "$TEST_MOCK_BIN/pipx" <<'EOF'
#!/usr/bin/env zsh
[[ "$*" == "list --short" ]] || exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/pipx"
  # Hides timeout and gtimeout from the core and from this suite.
  export PY_NO_TIMEOUT="$TEST_TEMP_DIR/no-timeout.zsh"
  cat > "$PY_NO_TIMEOUT" <<'ZSH'
command() {
  if [[ "$1" == -v && ( "$2" == timeout || "$2" == gtimeout ) ]]; then
    return 1
  fi
  builtin command "$@"
}
whence() {
  if [[ "$1" == -p && ( "$2" == timeout || "$2" == gtimeout ) ]]; then
    return 1
  fi
  builtin whence "$@"
}
ZSH
}

teardown() {
  PATH="$PY_PLATFORM_ORIGINAL_PATH"
  hash -r
  cleanup_sandbox
}

# mock_kernel NAME: uname -s reports NAME.
mock_kernel() {
  cat > "$TEST_MOCK_BIN/uname" <<SH
#!/usr/bin/env bash
printf '%s\n' '$1'
SH
  chmod +x "$TEST_MOCK_BIN/uname"
}

# A validated project-local environment.
make_venv() {
  mkdir -p "$PY_PROJECT/.venv/lib"
  printf '%s\n' "version = 3.12.1" > "$PY_PROJECT/.venv/pyvenv.cfg"
}

@test "py platform: inventories use the core watchdog without timeout or gtimeout" {
  run run_zsh '
    source "$PY_NO_TIMEOUT" || return 90
    NO_COLOR=1 tool-list
  '

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  ruff +uv +0[.]6[.]9$'
}

@test "py platform: a standalone source needs timeout or gtimeout and fails closed" {
  run zsh -f -c '
    source "$1/functions/py-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    tool-list
  ' _ "$TEST_SUITE_ROOT" "$PY_NO_TIMEOUT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Bounded Py commands need timeout or gtimeout when the ZDX core is not loaded."* ]]
  [[ "$output" != *"ruff"* ]]

  # With gtimeout alone, the standalone fallback bounds the inventory.
  export PY_TIMEOUT_LOG="$TEST_TEMP_DIR/gtimeout.log"
  cat > "$TEST_MOCK_BIN/gtimeout" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PY_TIMEOUT_LOG"
[[ "$1" == -k && "$2" == 2s && "$3" == 15s ]] || exit 98
shift 3
exec "$@"
SH
  chmod +x "$TEST_MOCK_BIN/gtimeout"
  run zsh -f -c '
    source "$1/functions/py-menu.zsh" || exit 90
    whence() {
      [[ "$1" == -p && "$2" == timeout ]] && return 1
      builtin whence "$@"
    }
    NO_COLOR=1 tool-list
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ruff"* ]]
  grep -q "^-k 2s 15s $TEST_MOCK_BIN/uv tool list$" "$PY_TIMEOUT_LOG"
}

@test "py platform: macOS removal walks devices and reads no mount table" {
  mock_kernel Darwin
  make_venv
  cat > "$TEST_MOCK_BIN/findmnt" <<'SH'
#!/usr/bin/env bash
printf 'findmnt\n' >> "$HOME/findmnt-calls"
exit 97
SH
  chmod +x "$TEST_MOCK_BIN/findmnt"

  run run_zsh '
    source "$PY_NO_TIMEOUT" || return 90
    _py_mount_table_path() {
      print -r -- read >> "$HOME/table-reads"
      REPLY=/nonexistent/mountinfo
    }
    cd "$PY_PROJECT" || return 91
    venv-remove --path .venv --dry-run || return 92
    venv-remove --path .venv --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: nothing was removed."* ]]
  [[ "$output" == *"Removed"* ]]
  [ ! -e "$PY_PROJECT/.venv" ]
  [ ! -e "$HOME/table-reads" ]
  [ ! -e "$HOME/findmnt-calls" ]
}

@test "py platform: macOS device walks refuse a mount at or below the target" {
  mock_kernel Darwin
  # /dev has its own device on Linux and macOS.
  run run_zsh '_py_assert_no_mounts_under /dev'
  [ "$status" -eq 1 ]
  [[ "$output" == *'Refusing an environment containing a mount or bind mount: "/dev"'* ]]

  # A readable system directory with a mount directly below it: macOS keeps
  # its volumes below /System/Volumes, and Linux mounts cgroup2 and other
  # filesystems below /sys/fs.
  local parent
  if [ -d /System/Volumes/Data ]; then
    parent=/System/Volumes
  elif [ -r /proc/self/mountinfo ] \
    && grep -Eq '^[^ ]+ [^ ]+ [^ ]+ [^ ]+ /sys/fs/[^/ ]+ ' /proc/self/mountinfo; then
    parent=/sys/fs
  else
    skip "no readable directory with a mount directly below it on this host"
  fi
  export PY_MOUNT_PARENT="$parent"
  run run_zsh '_py_assert_no_mounts_under "$PY_MOUNT_PARENT"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing an environment containing a mount or bind mount: \"$parent/"* ]]
}

@test "py platform: Linux removal reads the mount table and refuses mounts below" {
  mock_kernel Linux
  make_venv
  local escaped="${PY_PROJECT}/.venv/lib/bound\\040dir"
  printf '%s\n' \
    '22 1 8:1 / / rw,relatime - ext4 /dev/root rw' \
    "45 22 8:1 /elsewhere $escaped rw,relatime - ext4 /dev/root rw" \
    > "$TEST_TEMP_DIR/mountinfo"
  printf '%s\n' '22 1 8:1 / / rw,relatime - ext4 /dev/root rw' \
    > "$TEST_TEMP_DIR/mountinfo-clean"
  printf '%s\n' '22 1 8:1 / / rw - ext4 /dev/root rw' '23 22 8:1 / /x\q rw - ext4 a b' \
    > "$TEST_TEMP_DIR/mountinfo-bad"

  local fixture
  for fixture in mountinfo mountinfo-bad mountinfo-clean; do
    export PY_MOUNT_FIXTURE="$TEST_TEMP_DIR/$fixture"
    run run_zsh '
      _py_mount_table_path() { REPLY="$PY_MOUNT_FIXTURE"; }
      cd "$PY_PROJECT" && venv-remove --path .venv --dry-run
    '
    case "$fixture" in
      mountinfo)
        [ "$status" -eq 1 ]
        [[ "$output" == *"Refusing an environment containing a mount or bind mount: \"$PY_PROJECT/.venv/lib/bound dir\""* ]]
        ;;
      mountinfo-bad)
        [ "$status" -eq 1 ]
        [[ "$output" == *"Could not validate the mount boundary below the environment."* ]]
        ;;
      mountinfo-clean)
        [ "$status" -eq 0 ]
        [[ "$output" == *"Dry run: nothing was removed."* ]]
        ;;
    esac
  done
  [ -f "$PY_PROJECT/.venv/pyvenv.cfg" ]
}

@test "py platform: recursive removal fails closed on other kernels" {
  mock_kernel FreeBSD
  make_venv

  run run_zsh 'cd "$PY_PROJECT" && venv-remove --path .venv --dry-run'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Recursive environment removal is not supported on FreeBSD."* ]]
  [ -f "$PY_PROJECT/.venv/pyvenv.cfg" ]
}

@test "py platform: picker setup failures are errors, not cancellations" {
  mkdir -m 777 "$TEST_TEMP_DIR/shared"
  chmod 777 "$TEST_TEMP_DIR/shared"

  TMPDIR="$TEST_TEMP_DIR/shared" run run_zsh '_py_fzf_capture </dev/null'
  [ "$status" -eq 125 ]

  TMPDIR="$TEST_TEMP_DIR/shared" run run_zsh 'py-menu'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unable to open the interactive Py menu (status 125)."* ]]
  [[ "$output" != *"Cancelled"* ]]
  [ -z "$(ls -A "$TEST_TEMP_DIR/shared")" ]

  # Two tools need the tool picker; only its private directory fails.
  export PY_REAL_MKTEMP
  PY_REAL_MKTEMP=$(command -v mktemp)
  cat > "$TEST_MOCK_BIN/mktemp" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  [[ "$argument" == */zdx-py-fzf.* ]] && exit 1
done
exec "$PY_REAL_MKTEMP" "$@"
SH
  cat > "$TEST_MOCK_BIN/uv" <<'SH'
#!/usr/bin/env zsh
[[ "$*" == "tool list" ]] || exit 97
print -rl -- 'ruff v0.6.9' '- ruff' 'black v24.1.0' '- black'
SH
  chmod +x "$TEST_MOCK_BIN/mktemp" "$TEST_MOCK_BIN/uv"
  run run_zsh 'tool-uninstall'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not create a private Py picker directory."* ]]
  [[ "$output" == *"The Py picker failed (status 125)."* ]]
  [[ "$output" != *"Cancelled"* ]]
}

@test "py platform: relocatable activation is refused before review without proc descriptors" {
  mkdir -m 700 "$PY_PROJECT/.venv" "$PY_PROJECT/.venv/bin"
  printf 'version = 3.12.3\nrelocatable = true\n' > "$PY_PROJECT/.venv/pyvenv.cfg"
  printf 'print -r -- sourced >> "$HOME/activate.log"\n' > "$PY_PROJECT/.venv/bin/activate"
  chmod 600 "$PY_PROJECT/.venv/pyvenv.cfg" "$PY_PROJECT/.venv/bin/activate"

  local arguments
  for arguments in "--dry-run" "--yes"; do
    export PY_ACTIVATE_ARGS="$arguments"
    run run_zsh '
      _py_proc_descriptors_available() { return 1; }
      cd "$PY_PROJECT" && venv-activate --path .venv "$PY_ACTIVATE_ARGS"
    '
    [ "$status" -eq 1 ]
    [[ "$output" == *"Relocatable environments cannot be activated on this host: activation needs a stable descriptor path from /proc/<pid>/fd"*"(macOS has no /proc)."* ]]
    [[ "$output" == *"Nothing was changed. Review the script, then source it yourself: source "*"/project/.venv/bin/activate"* ]]
    [[ "$output" != *"Activate Virtual Environment"* ]]
  done
  [ ! -e "$HOME/activate.log" ]
}

@test "py platform: package inspection needs Python 3 but not tomllib" {
  # The interpreter itself, not a version-manager shim that would find the
  # mock below on PATH again.
  export PY_REAL_PYTHON
  PY_REAL_PYTHON=$(python3 -c 'import sys; print(sys.executable)')
  [ -x "$PY_REAL_PYTHON" ]
  # A Python older than 3.11, which has no tomllib.
  cat > "$TEST_MOCK_BIN/python3" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ "$argument" == *tomllib* ]]; then
    printf "ModuleNotFoundError: No module named 'tomllib'\n" >&2
    exit 1
  fi
done
exec "$PY_REAL_PYTHON" "$@"
SH
  cat > "$TEST_MOCK_BIN/curl" <<'SH'
#!/usr/bin/env bash
output=""
previous=""
for argument in "$@"; do
  [[ "$previous" == --output ]] && output="$argument"
  previous="$argument"
done
[[ -n "$output" ]] || exit 9
printf '%s\n' '{"info":{"name":"demo","version":"1.2.3","summary":"Demo","requires_python":">=3.9","project_url":"https://pypi.org/project/demo/"}}' > "$output"
SH
  chmod +x "$TEST_MOCK_BIN/python3" "$TEST_MOCK_BIN/curl"

  run run_zsh 'NO_COLOR=1 package-search demo'

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  Version: +1[.]2[.]3$'
  [[ "$output" != *"3.11 or newer"* ]]
}

@test "py platform: python.org framework interpreters are trusted only on macOS" {
  export PY_FRAMEWORK="$HOME/Library/Frameworks/Python.framework"
  local version_dir="$PY_FRAMEWORK/Versions/3.12"
  mkdir -p "$version_dir/bin"
  printf '#!/bin/sh\n' > "$version_dir/bin/python3.12"
  printf '#!/bin/sh\n' > "$version_dir/python3.12"
  chmod 775 "$PY_FRAMEWORK" "$PY_FRAMEWORK/Versions" "$version_dir" \
    "$version_dir/bin" "$version_dir/bin/python3.12" "$version_dir/python3.12"
  mkdir -m 700 "$PY_PROJECT/.venv" "$PY_PROJECT/.venv/bin"
  printf '%s\n' "version = 3.12.4" > "$PY_PROJECT/.venv/pyvenv.cfg"
  ln -s "$version_dir/bin/python3.12" "$PY_PROJECT/.venv/bin/python"
  export PY_FRAMEWORK_GID
  PY_FRAMEWORK_GID=$(file_stat "$version_dir/bin/python3.12" gid)
  local check='
    _py_python_org_framework() {
      reply=("$PY_FRAMEWORK" "$EUID" "${PY_FRAMEWORK_ADMIN_GID:-$PY_FRAMEWORK_GID}")
    }
    _py_fingerprint_venv_python "$PY_PROJECT/.venv" >/dev/null
  '

  mock_kernel Darwin
  run run_zsh "$check"
  [ "$status" -eq 0 ]

  # Another group, a world-writable file, an interpreter outside a version's
  # bin directory, a group-writable directory above the framework, or
  # another kernel keeps the interpreter refused.
  PY_FRAMEWORK_ADMIN_GID=$(( PY_FRAMEWORK_GID + 1 )) run run_zsh "$check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing an unsafe virtual-environment interpreter"* ]]

  chmod 777 "$version_dir/bin/python3.12"
  run run_zsh "$check"
  [ "$status" -eq 1 ]
  chmod 775 "$version_dir/bin/python3.12"

  ln -sf "$version_dir/python3.12" "$PY_PROJECT/.venv/bin/python"
  run run_zsh "$check"
  [ "$status" -eq 1 ]
  ln -sf "$version_dir/bin/python3.12" "$PY_PROJECT/.venv/bin/python"

  chmod 775 "$HOME/Library/Frameworks"
  run run_zsh "$check"
  [ "$status" -eq 1 ]
  chmod 755 "$HOME/Library/Frameworks"

  mock_kernel Linux
  run run_zsh "$check"
  [ "$status" -eq 1 ]

  mock_kernel Darwin
  run run_zsh "$check"
  [ "$status" -eq 0 ]
}

@test "py platform: WSL drive refusals explain DrvFs metadata" {
  run run_zsh '
    _py_host_is_wsl() { return 0; }
    _py_wsl_drive_hint /mnt/c/Users/me/project
    _py_wsl_drive_hint /home/me/project
    _py_host_is_wsl() { return 1; }
    _py_wsl_drive_hint /mnt/c/Users/me/project
  '

  [ "$status" -eq 0 ]
  [ "$(grep -c 'DrvFs metadata' <<< "$output")" -eq 1 ]
  [[ "$output" == *'[automount] options="metadata,umask=22,fmask=11"'* ]]

  mock_kernel Linux
  run run_zsh '
    unset WSL_DISTRO_NAME WSL_INTEROP
    command mkdir -p "$HOME/proc/sys/kernel" "$HOME/native/sys/kernel"
    print -r -- "4.4.0-19041-Microsoft" > "$HOME/proc/sys/kernel/osrelease"
    print -r -- "6.8.0-generic" > "$HOME/native/sys/kernel/osrelease"
    _py_host_is_wsl "$HOME/proc" && print -r -- wsl1=WSL
    _py_host_is_wsl "$HOME/native" || print -r -- native=Linux
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'wsl1=WSL\nnative=Linux' ]
}

@test "py platform: menu rows mark bounded actions only without any timeout support" {
  run run_zsh '
    source "$PY_NO_TIMEOUT" || return 90
    _py_menu_rows
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"missing:"* ]]
  [[ "$output" == *$'\n  ● List Global Tools|tool-list|'* ]]

  run zsh -f -c '
    source "$1/functions/py-menu.zsh" || exit 90
    source "$2" || exit 91
    _py_menu_rows
  ' _ "$TEST_SUITE_ROOT" "$PY_NO_TIMEOUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n  ○ List Global Tools (missing: timeout or gtimeout)|tool-list|'* ]]
  [[ "$output" == *$'\n  ○ Remove Environment (missing: timeout or gtimeout)|venv-remove|'* ]]
  [[ "$output" == *$'\n  ● List Environments|venv-list|'* ]]
  [[ "$output" == *$'\n  ● Install Global Tool|tool-install|'* ]]
}
