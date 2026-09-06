#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

install_mutation_sentinels() {
  export SYS_MUTATION_LOG="$TEST_TEMP_DIR/sys-mutations"
  : > "$SYS_MUTATION_LOG"

  cat <<'EOF' > "$TEST_MOCK_BIN/kill"
#!/usr/bin/env bash
printf 'kill %s\n' "$*" >> "$SYS_MUTATION_LOG"
exit 97
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/systemctl"
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$SYS_MUTATION_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/kill" "$TEST_MOCK_BIN/systemctl"
}

@test "sys: sys-menu.zsh and modules source cleanly" {
  run run_zsh "echo SOURCED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED"* ]]
}

@test "sys: _sys_test_pkg_manager succeeds when no lock" {
  export MOCK_APT_LOCKED=0
  export MOCK_BREW_LOCKED=0
  # Mock both package managers to be present to test both code paths
  touch "$TEST_MOCK_BIN/apt-get" && chmod +x "$TEST_MOCK_BIN/apt-get"
  touch "$TEST_MOCK_BIN/brew" && chmod +x "$TEST_MOCK_BIN/brew"

  run run_zsh "_sys_test_pkg_manager apt && _sys_test_pkg_manager brew"
  [ "$status" -eq 0 ]
}

@test "sys: _sys_test_pkg_manager fails when apt is locked" {
  export MOCK_APT_LOCKED=1
  install_mutation_sentinels
  # Mock apt-get to be present
  touch "$TEST_MOCK_BIN/apt-get" && chmod +x "$TEST_MOCK_BIN/apt-get"

  run run_zsh "_sys_test_pkg_manager apt"
  [ "$status" -eq 1 ]
  [ ! -s "$SYS_MUTATION_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys: Homebrew analytics is not treated as a package-manager lock" {
  export MOCK_BREW_LOCKED=1
  install_mutation_sentinels
  touch "$TEST_MOCK_BIN/brew" && chmod +x "$TEST_MOCK_BIN/brew"

  run run_zsh '
    ps() {
      print -r -- \
        "curl --user-agent Linuxbrew/6.0 --header Authorization:\ Token\ DO_NOT_PRINT_VALUE_42"
    }
    _sys_test_pkg_manager brew
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"Homebrew appears to be locked"* ]]
  [[ "$output" != *"DO_NOT_PRINT_VALUE_42"* ]]
  [ ! -s "$SYS_MUTATION_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys: Homebrew commands use the public analytics opt-out" {
  export BREW_ANALYTICS_LOG="$TEST_TEMP_DIR/brew-analytics"
  cat <<'EOF' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
printf '%s:%s\n' \
  "${HOMEBREW_CURL_RETRIES:-unset}" \
  "${HOMEBREW_NO_ANALYTICS:-unset}" > "$BREW_ANALYTICS_LOG"
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  run run_zsh "_sys_brew list uv"

  [ "$status" -eq 0 ]
  [ "$(cat "$BREW_ANALYTICS_LOG")" = "0:1" ]
}

@test "sys: APT update exposes no package-lock polling helpers" {
  run run_zsh '
    (( ! ${+functions[_sys_package_lock_pause]} ))
    (( ! ${+functions[_sys_wait_for_package_manager]} ))
  '

  [ "$status" -eq 0 ]
}

@test "sys: missing menu dependencies annotate only the affected entry" {
  run run_zsh '
    command() {
      if [[ "$1" == "-v" && "${2:-}" == "brew" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    _sys_menu_entry "Update Homebrew Packages" "update-brew" \
      "Refresh formulae, upgrade installed packages, and clean old versions."
    _sys_menu_entry "Show System Info" "sys-info" \
      "Inspect OS, kernel, memory, tools, packages, and WSL state."
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "  Update Homebrew Packages (missing: brew)|update-brew|Refresh formulae, upgrade installed packages, and clean old versions." ]
  [ "${lines[1]}" = "  Show System Info|sys-info|Inspect OS, kernel, memory, tools, packages, and WSL state." ]
}

@test "sys: _sys_format_duration formats seconds correctly" {
  run run_zsh "
    echo \$(_sys_format_duration 0)
    echo \$(_sys_format_duration 65)
    echo \$(_sys_format_duration 3605)
  "
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "0m 00s" ]]
  [[ "${lines[1]}" == "1m 05s" ]]
  [[ "${lines[2]}" == "60m 05s" ]]
}

@test "sys: _sys_repeat_char repeats character" {
  run run_zsh "
    echo \$(_sys_repeat_char '#' 5)
    echo \$(_sys_repeat_char '=' 0)
  "
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "#####" ]]
  [[ "${lines[1]}" == "" ]]
}

@test "sys: _sys_run_with_timeout runs command" {
  run run_zsh "
    _sys_run_with_timeout 5 echo 'timeout-ok'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"timeout-ok"* ]]
}

@test "sys: _sys_run_with_timeout supports BusyBox-style timeout" {
  export TIMEOUT_CALLS_FILE="$TEST_TEMP_DIR/timeout-calls"
  : > "$TIMEOUT_CALLS_FILE"

  cat <<'EOF' > "$TEST_MOCK_BIN/timeout"
#!/usr/bin/env bash
{
  printf 'timeout'
  printf ' %q' "$@"
  printf '\n'
} >> "$TIMEOUT_CALLS_FILE"

if [[ "${1:-}" == "--help" ]]; then
  sleep 30
  exit 99
fi

[[ "${1:-}" == "-k" && "${2:-}" == "2s" ]] || exit 98
shift 2
duration="${1:-}"
shift
[[ "$duration" == *s && "$#" -gt 0 ]] || exit 98
"$@"
EOF
  chmod +x "$TEST_MOCK_BIN/timeout"

  run run_zsh "
    : > \"\$TIMEOUT_CALLS_FILE\"
    _sys_run_with_timeout 7 echo timeout-busybox-ok
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"timeout-busybox-ok"* ]]
  [ "$(sed -n '1p' "$TIMEOUT_CALLS_FILE")" = \
    "timeout -k 2s 7s echo timeout-busybox-ok" ]
  [ "$(wc -l < "$TIMEOUT_CALLS_FILE")" -eq 1 ]
  if grep -q -- '--foreground' "$TIMEOUT_CALLS_FILE"; then
    return 1
  fi
}

@test "sys: _sys_run_bounded_probe enforces time and byte limits" {
  run run_zsh \
    "_sys_run_bounded_probe 2 16 printf '%s' 'bounded-output'"
  [ "$status" -eq 0 ]
  [ "$output" = "bounded-output" ]

  run run_zsh \
    "_sys_run_bounded_probe 2 8 printf '%s' 'output-is-too-large'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  run run_zsh "_sys_run_bounded_probe 1 64 zsh -c 'sleep 5; print late'"
  [ "$status" -eq 124 ]
  [ -z "$output" ]
}

@test "sys: privilege resolver uses direct access or the sudo recorder" {
  export PRIVILEGE_APT_LOG="$TEST_TEMP_DIR/privilege-apt-calls"
  : > "$PRIVILEGE_APT_LOG"
  cat <<'EOF' > "$TEST_MOCK_BIN/apt-get"
#!/usr/bin/env bash
{
  printf 'apt-get'
  printf ' %q' "$@"
  printf '\n'
} >> "$PRIVILEGE_APT_LOG"
EOF
  chmod +x "$TEST_MOCK_BIN/apt-get"
  export MOCK_SUDO_ALLOW="apt-get"

  run run_zsh "
    _SYS_CAPABILITIES=(
      package_manager apt
      privilege direct
    )
    _SYS_CAPABILITIES_READY=1
    _sys_clean_step_apt_cache
  "

  [ "$status" -eq 0 ]
  [ "$(cat "$PRIVILEGE_APT_LOG")" = "apt-get clean" ]
  [ ! -s "$MOCK_SUDO_LOG" ]

  : > "$PRIVILEGE_APT_LOG"
  : > "$MOCK_SUDO_LOG"
  run run_zsh "
    _SYS_CAPABILITIES=(
      package_manager apt
      privilege sudo
    )
    _SYS_CAPABILITIES_READY=1
    _sys_clean_step_apt_cache
  "

  [ "$status" -eq 0 ]
  [ "$(cat "$PRIVILEGE_APT_LOG")" = "apt-get clean" ]
  if (( EUID == 0 )); then
    [ ! -s "$MOCK_SUDO_LOG" ]
  else
    [ "$(cat "$MOCK_SUDO_LOG")" = "sudo apt-get clean" ]
  fi
}

@test "sys: _sys_confirm rejects piped confirmation without a terminal" {
  run run_zsh "echo 'y' | _sys_confirm 'Proceed'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Interactive confirmation requires a terminal"* ]]

  run run_zsh "echo 'n' | _sys_confirm 'Proceed'"
  [ "$status" -eq 1 ]

  run run_zsh "_sys_confirm 'Proceed'"
  [ "$status" -eq 1 ]
}

@test "sys: _sys_has_systemd returns correctly" {
  run run_zsh "_sys_has_systemd"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "sys: _sys_snap_ready returns correctly" {
  run run_zsh "_sys_snap_ready"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "sys: _sys_run_logged suppresses success output and surfaces bounded failures" {
  local capture_tmp="$HOME/run-logged-tmp"
  mkdir -p "$capture_tmp"

  run run_zsh "
    export TMPDIR='$capture_tmp'
    _sys_run_logged test_cmd zsh -c \
      'echo success-out; echo success-err >&2'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running test_cmd"* ]]
  [[ "$output" != *"success-out"* ]]
  [[ "$output" != *"success-err"* ]]
  [ -z "$(find "$capture_tmp" -mindepth 1 -print -quit)" ]

  run run_zsh "
    export TMPDIR='$capture_tmp'
    _sys_run_logged test_cmd zsh -c \
      'echo failure-out; echo some-error >&2; exit 5'
  "
  [ "$status" -eq 5 ]
  [[ "$output" == *"failure-out"* ]]
  [[ "$output" == *"some-error"* ]]
  [ -z "$(find "$capture_tmp" -mindepth 1 -print -quit)" ]

  run run_zsh "
    export TMPDIR='$capture_tmp'
    _sys_run_logged bounded zsh -c \
      'for i in {1..100}; do printf \"bounded-%03d\\n\" \"\$i\"; done; exit 9'
  "
  [ "$status" -eq 9 ]
  [[ "$output" != *"bounded-001"* ]]
  [[ "$output" == *"bounded-021"* ]]
  [[ "$output" == *"bounded-100"* ]]
  [ -z "$(find "$capture_tmp" -mindepth 1 -print -quit)" ]
}

@test "sys: _sys_run_logged closes command stdin" {
  local capture_tmp="$HOME/run-logged-stdin-tmp"
  mkdir -p "$capture_tmp"

  run run_zsh "
    export TMPDIR='$capture_tmp'
    print -r -- 'must-not-reach-command' | _sys_run_logged stdin-check \
      zsh -c 'if IFS= read -r input; then print -r -- \"unexpected:\$input\"; exit 97; fi'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"Running stdin-check"* ]]
  [[ "$output" != *"must-not-reach-command"* ]]
  [[ "$output" != *"unexpected:"* ]]
  [ -z "$(find "$capture_tmp" -mindepth 1 -print -quit)" ]
}

@test "sys: _sys_npm_install_g rejects unsafe package before npm or sudo" {
  export NPM_CALLS_FILE="$TEST_TEMP_DIR/npm-calls"
  : > "$NPM_CALLS_FILE"

  cat <<'EOF' > "$TEST_MOCK_BIN/npm"
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NPM_CALLS_FILE"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/npm"

  run run_zsh "
    : > \"\$NPM_CALLS_FILE\"
    _sys_npm_install_g '../unsafe-package'
  "
  [ "$status" -eq 2 ]
  [[ "$output" == *"Invalid npm package identifier"* ]]
  [ ! -s "$NPM_CALLS_FILE" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys: _sys_npm_install_g rejects unwritable prefix without sudo" {
  export NPM_CALLS_FILE="$TEST_TEMP_DIR/npm-calls"
  export MOCK_NPM_PREFIX="$HOME/missing-npm-prefix"
  : > "$NPM_CALLS_FILE"

  cat <<'EOF' > "$TEST_MOCK_BIN/npm"
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NPM_CALLS_FILE"
if [[ "$1" == "config" && "$2" == "get" ]]; then
  echo "$MOCK_NPM_PREFIX"
elif [[ "$1" == "install" ]]; then
  echo 'npm install output must stay private'
fi
EOF
  chmod +x "$TEST_MOCK_BIN/npm"

  run run_zsh "
    : > \"\$NPM_CALLS_FILE\"
    _sys_npm_install_g 'some-pkg'
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"not user-writable"* ]]
  [ "$(cat "$NPM_CALLS_FILE")" = "config get prefix" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys: _sys_npm_install_g uses writable user prefix without sudo" {
  export NPM_CALLS_FILE="$TEST_TEMP_DIR/npm-calls"
  export MOCK_NPM_PREFIX="$HOME/npm-prefix"
  : > "$NPM_CALLS_FILE"
  mkdir -p "$MOCK_NPM_PREFIX/lib"

  cat <<'EOF' > "$TEST_MOCK_BIN/npm"
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NPM_CALLS_FILE"
if [[ "$1" == "config" && "$2" == "get" ]]; then
  echo "$MOCK_NPM_PREFIX"
elif [[ "$1" == "install" ]]; then
  echo 'npm install output must stay private'
fi
EOF
  chmod +x "$TEST_MOCK_BIN/npm"

  run run_zsh "
    : > \"\$NPM_CALLS_FILE\"
    _sys_npm_install_g 'some-pkg'
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"npm install output"* ]]
  [ "$(cat "$NPM_CALLS_FILE")" = $'config get prefix\ninstall -g -- some-pkg' ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "sys: sys-menu direct argument execution works" {
  run run_zsh "
    # Run sys-menu with subcommand direct argument
    sys-menu sys-info
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"System Information"* ]]
}
