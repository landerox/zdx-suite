#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  mkdir -m 700 "$HOME/shared" "$HOME/shared/private"
  export SYS_TEST_TEMP="$HOME/shared/private"
  export SYS_REAL_MKTEMP
  SYS_REAL_MKTEMP=$(command -v mktemp)
  cat > "$TEST_MOCK_BIN/mktemp" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$HOME/temp-allocation.calls"
exec "$SYS_REAL_MKTEMP" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/mktemp"
  cat > "$TEST_MOCK_BIN/sys-probe" <<'MOCK'
#!/usr/bin/env bash
printf 'called\n' >> "$HOME/probe.calls"
printf 'probe-data\n'
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/sys-probe"
}

teardown() { cleanup_sandbox; }

sys_refuse_temp() {
  run run_zsh '
    export TMPDIR="$SYS_TEST_TEMP"
    local validation_rc=0 staging_rc=0 probe_rc=0
    _sys_temp_parent_safe "$TMPDIR" || validation_rc=$?
    _sys_apt_key_session_open || staging_rc=$?
    _sys_run_bounded_probe 5 1024 "$TEST_MOCK_BIN/sys-probe" \
      >"$HOME/probe.stdout" 2>"$HOME/probe.stderr" || probe_rc=$?
    print -r -- "$validation_rc,$staging_rc,$probe_rc"
  '
  [ "$status" -eq 0 ]
  [ "$output" = '1,1,1' ]
  [ ! -e "$HOME/temp-allocation.calls" ]
  [ ! -e "$HOME/probe.calls" ]
}

@test "sys temporary safety: refuse capture allocation under an unsafe leaf" {
  chmod -- 777 "$SYS_TEST_TEMP"
  sys_refuse_temp
}

@test "sys temporary safety: refuse probes and APT staging below a group-writable ancestor" {
  chmod -- 770 "$HOME/shared"
  sys_refuse_temp
}

@test "sys temporary safety: refuse probes and APT staging below a non-sticky writable ancestor" {
  chmod -- 777 "$HOME/shared"
  sys_refuse_temp
}

@test "sys temporary safety: standalone capture refuses unsafe roots before allocation" {
  chmod -- 777 "$SYS_TEST_TEMP"
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/sys-common.zsh" || exit 90
    export TMPDIR="$SYS_TEST_TEMP"
    _sys_run_bounded_probe 5 1024 "$TEST_MOCK_BIN/sys-probe" \
      >"$HOME/probe.stdout" 2>"$HOME/probe.stderr"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ ! -s "$HOME/probe.stdout" ]
  [ ! -e "$HOME/temp-allocation.calls" ]
  [ ! -e "$HOME/probe.calls" ]
}

@test "sys temporary safety: standalone watchdog refuses writable ancestors" {
  chmod -- 770 "$HOME/shared"
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/sys-common.zsh" || exit 90
    # Select the native watchdog without changing the real host PATH.
    command() {
      if [[ "$1" == -v && "$2" == (timeout|gtimeout) ]]; then return 1; fi
      builtin command "$@"
    }
    export TMPDIR="$SYS_TEST_TEMP"
    _sys_run_with_timeout 5 "$TEST_MOCK_BIN/sys-probe"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/temp-allocation.calls" ]
  [ ! -e "$HOME/probe.calls" ]
}

@test "sys temporary safety: trusted aliases resolve to the physical capture and staging root" {
  ln -s "$HOME/shared" "$HOME/alias"
  run run_zsh '
    export TMPDIR="$HOME/alias/private"
    _sys_temp_parent_safe "$TMPDIR" || exit 90
    [[ "$REPLY" == "$SYS_TEST_TEMP" ]] || exit 91
    _sys_apt_key_session_open || exit 92
    local session="$REPLY"
    [[ "${session:h}" == "$SYS_TEST_TEMP" ]] || exit 93
    _sys_apt_key_session_close "$session" || exit 94
    _sys_run_bounded_probe 5 1024 "$TEST_MOCK_BIN/sys-probe" || exit 95
    [[ -z "$(command ls -A "$SYS_TEST_TEMP")" ]] || exit 96
  '
  [ "$status" -eq 0 ]
  [ "$output" = probe-data ]
  [ -s "$HOME/temp-allocation.calls" ]
  run grep -F "$HOME/alias" "$HOME/temp-allocation.calls"
  [ "$status" -eq 1 ]
}
