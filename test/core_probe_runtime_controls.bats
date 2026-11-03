#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Additive route and drawable-spinner controls, separate from the prior51.

setup() {
  load test_helper
  load core_probe_test_helper
  load core_probe_runtime_control_test_helper
  f308r_setup
}

teardown() { cleanup_sandbox; }

@test "F308 runtime controls: function-only timeout selectors use the actual direct watchdog and abandon the started version leaf" {
  f308r_slow_pipx
  run "$F308R_REAL_ZSH" -f -c '
    emulate -R zsh
    builtin source "$1/functions.zsh" || exit 90
    builtin source "$1/functions/zdx-doctor.zsh" || exit 91
    path=("$CORE_PROBE_BIN")
    rehash
    whence -p -- timeout >/dev/null 2>&1 && exit 31
    whence -p -- gtimeout >/dev/null 2>&1 && exit 32
    timeout() { print -r -- timeout >> "$HOME/runtime-backend-function-ran"; return 97; }
    gtimeout() { print -r -- gtimeout >> "$HOME/runtime-backend-function-ran"; return 97; }
    local original_watchdog="${functions[_zdx_timeout_watchdog]}"
    functions[_f308r_real_watchdog]="$original_watchdog"
    print -r -- "$original_watchdog" > "$HOME/runtime-original-watchdog.body"
    _zdx_timeout_watchdog() {
      printf "%s\0" "$@" >> "$HOME/runtime-watchdog.argv"
      _f308r_real_watchdog "$@"
    }
    functions[_f308r_real_service]="${functions[_zdx_run_with_timeout]}"
    _zdx_run_with_timeout() {
      print -r -- called >> "$HOME/runtime-generic-service-ran"
      _f308r_real_service "$@"
    }
    exec < "$HOME/runtime-control.stdin" || exit 33
    local -i version_rc=0
    _zdx_doctor_get_version pipx >"$HOME/runtime-version.stdout" \
      2>"$HOME/runtime-version.stderr" || version_rc=$?
    (( version_rc == 124 )) || exit 34
    [[ ! -s "$HOME/runtime-version.stdout" && -s "$HOME/runtime-pipx-started.json" \
      && ! -e "$HOME/runtime-backend-function-ran" && ! -e "$HOME/runtime-generic-service-ran" ]] || exit 35
    local unread=""
    IFS= read -r unread || exit 36
    [[ "$unread" == "Caller input remains unread by the version probe." \
      && "${functions[_f308r_real_watchdog]}" == "$original_watchdog" ]] || exit 37
    local raw="$(<"$HOME/runtime-watchdog.argv")" nul="${(#):-0}"
    [[ "$raw" == "5${nul}${CORE_PROBE_BIN}/pipx${nul}--version${nul}" ]] || exit 38
    # Observe beyond THIS child recorded 8-second monotonic deadline. No
    # stale-PID signal or broad cleanup substitutes for this observation.
    "$F308R_REAL_PYTHON" -B -I "$HOME/observe-pipx-window.py" "$CORE_PROBE_BIN/pipx" || exit 39
    [[ ! -e "$HOME/runtime-pipx-completed" ]] || exit 40
    print -r -- direct-watchdog-abandoned-leaf
  ' _ "$TEST_SUITE_ROOT" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = direct-watchdog-abandoned-leaf ]
}

@test "F308 runtime controls: the drawable spinner never queries or signals its child after one real wait" {
  f308r_spinner_worker
  run f308r_spinner_pty
  [ "$status" -eq 0 ]
  [ "$output" = drawing-branch-observed ]
  [ -s "$HOME/runtime-spinner-child-started" ]
  [ -s "$HOME/runtime-spinner-reaped" ]
  [ ! -e "$HOME/runtime-spinner-post-reap" ]
  [ ! -e "$HOME/runtime-spinner-forbidden-signal" ]
  [ "$(cat "$HOME/runtime-spinner-waits")" = 1 ]
  [ "$(cat "$HOME/runtime-spinner-result")" = 23 ]
}
