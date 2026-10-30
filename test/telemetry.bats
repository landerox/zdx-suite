#!/usr/bin/env bats

setup() {
  TELEMETRY_TEST_PATH="$PATH"
  load test_helper
}

teardown() {
  export PATH="$TELEMETRY_TEST_PATH"
  hash -r
  cleanup_sandbox
}

@test "telemetry: does not log when disabled (default)" {
  run run_zsh "
    builtin cd -- \"\$HOME\" || exit 80
    # Run _timed which is defined in functions.zsh
    _timed 'sys:sys-info' echo 'Hello'

    # Check if telemetry.json was created
    [ ! -f \"\$HOME/.config/zdx/telemetry.json\" ]
  "
  [ "$status" -eq 0 ]
}

@test "telemetry: logs to telemetry.json when enabled" {
  run run_zsh "
    builtin cd -- \"\$HOME\" || exit 80
    export ZDX_TELEMETRY=1
    _timed 'sys:sys-info' true

    [ -f \"\$HOME/.config/zdx/telemetry.json\" ] || exit 31

    # Read the file and verify content
    content=\$(cat \"\$HOME/.config/zdx/telemetry.json\")
    [[ \"\$content\" == *'\"suite\": \"sys\"'* ]] || exit 32
    [[ \"\$content\" == *'\"command\": \"sys-info\"'* ]] || exit 33
    [[ \"\$content\" == *'\"exit_code\": 0'* ]] || exit 34
    [[ \"\$content\" == *'\"duration_ms\":'* ]] || exit 35
    [[ \"\$content\" == *'\"timestamp\":'* ]]
  "
  [ "$status" -eq 0 ]
}

@test "telemetry: infers ownership from registered commands without a suite prefix" {
  run run_zsh "
    builtin cd -- \"\$HOME\" || exit 80
    export ZDX_TELEMETRY=true
    _timed 'vpn-summary' true

    content=\$(cat \"\$HOME/.config/zdx/telemetry.json\")
    [[ \"\$content\" == *'\"suite\": \"vpn\"'* ]] || exit 36
    [[ \"\$content\" == *'\"command\": \"vpn-summary\"'* ]]
  "
  [ "$status" -eq 0 ]
}

@test "telemetry: _timed reports failures without hiding status or telemetry" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1
    export ZDX_TELEMETRY=1

    _telemetry_timer_failure() { return 23; }

    _timed "sys:sys-info" true || return 90
    _timed "sys:sys-health" _telemetry_timer_failure
    local timer_rc=$?

    command grep -Fq "\"command\": \"sys-info\"" \
      "$HOME/.config/zdx/telemetry.json" || return 91
    command grep -Fq "\"exit_code\": 0" \
      "$HOME/.config/zdx/telemetry.json" || return 92
    command grep -Fq "\"command\": \"sys-health\"" \
      "$HOME/.config/zdx/telemetry.json" || return 93
    command grep -Fq "\"exit_code\": 23" \
      "$HOME/.config/zdx/telemetry.json" || return 94

    return $timer_rc
  '

  [ "$status" -eq 23 ]
  [[ "$output" == *"sys:sys-info completed in "*"s"* ]]
  [[ "$output" == *"sys:sys-health failed after "*"s (status 23)"* ]]
  [[ "$output" != *"sys:sys-health completed in"* ]]
}

@test "telemetry: _timed distinguishes an explicitly marked partial result" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1
    _telemetry_partial_result() {
      _zdx_timed_mark_partial || return 90
      return 1
    }

    _timed "sys:update-system" _telemetry_partial_result
  '

  [ "$status" -eq 1 ]
  [[ "$output" == \
    *"sys:update-system completed with partial failures in "*"s (status 1)"* ]]
  [[ "$output" != *"sys:update-system failed after"* ]]
}

@test "telemetry: sys-telemetry --help works" {
  run run_zsh "
    builtin cd -- \"\$HOME\" || exit 80
    sys-telemetry --help
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"sys-telemetry"* ]]
}

@test "telemetry: sys-telemetry --dashboard warning when empty" {
  run run_zsh "
    builtin cd -- \"\$HOME\" || exit 80
    rm -f \"\$HOME/.config/zdx/telemetry.json\"
    sys-telemetry --dashboard
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"No telemetry data found"* ]]
}

@test "telemetry: sys-telemetry --dashboard displays stats" {
  run run_zsh "
    builtin cd -- \"\$HOME\" || exit 80
    export ZDX_TELEMETRY=1
    _timed 'sys:sys-info' true
    _timed 'vpn:vpn-summary' true
    _timed 'sys:sys-health' false

    sys-telemetry --dashboard
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUMMARY STATISTICS"* ]]
  [[ "$output" == *"Total Runs:"*3* ]]
  [[ "$output" == *"Successful:"*2* ]]
  [[ "$output" == *"Failed:"*1* ]]
  [[ "$output" == *"Suite Distribution"* ]]
  [[ "$output" == *"sys"* ]]
  [[ "$output" == *"vpn"* ]]
  [[ "$output" == *"Recent Executions"* ]]
}

@test "telemetry: sys-telemetry --clear works" {
  run run_zsh "
    builtin cd -- \"\$HOME\" || exit 80
    export ZDX_TELEMETRY=1
    _timed 'sys:sys-info' true
    [ -s \"\$HOME/.config/zdx/telemetry.json\" ] || exit 52

    sys-telemetry --clear --yes
    [ ! -s \"\$HOME/.config/zdx/telemetry.json\" ]
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Telemetry log cleared successfully"* ]]
}

@test "telemetry: unknown timer labels cannot enter the footer or persisted records" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1 ZDX_TELEMETRY=1
    _timed "env:zdx-canary-secret-789" true
    _timed "sys:git-status" true
    _timed "zdx-canary-suite-789:sys-info" true
    command jq -r ".suite + \":\" + .command" "$HOME/.config/zdx/telemetry.json"
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *zdx-canary-secret-789* ]]
  [[ "$output" != *zdx-canary-suite-789* ]]
  [[ "$output" != *'sys:git-status'* ]]
  [[ "$output" == *'env:unknown completed in '* ]]
  [[ "$output" == *'sys:unknown completed in '* ]]
  [[ "$output" == *'unknown:unknown completed in '* ]]
  [ "${lines[${#lines[@]}-3]}" = env:unknown ]
  [ "${lines[${#lines[@]}-2]}" = sys:unknown ]
  [ "${lines[${#lines[@]}-1]}" = unknown:unknown ]
}

@test "telemetry: direct logger calls use registered ownership and the zdx status alias" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    _log_telemetry "sys:git-status" 0.001 0 || exit 31
    _log_telemetry "clean-branches" 0.001 0 || exit 32
    _log_telemetry "zdx:status" 0.001 0 || exit 33
    _log_telemetry "demo:demo-action" 0.001 0 || exit 34
    command jq -r ".suite + \":\" + .command" "$HOME/.config/zdx/telemetry.json"
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'sys:unknown\ngit:clean-branches\nzdx:status\nunknown:unknown' ]
}

@test "telemetry: a shadowed mktemp cannot intercept writer paths" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export ZDX_TELEMETRY=1
    mktemp() {
      print -r -- intercepted > "$HOME/intercepted-mktemp"
      return 97
    }
    _timed "sys:sys-info" true || exit 31
    [[ ! -e "$HOME/intercepted-mktemp" ]] || exit 32
    command jq -e ".suite == \"sys\" and .command == \"sys-info\"" \
      "$HOME/.config/zdx/telemetry.json" >/dev/null
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/intercepted-mktemp" ]
}

@test "telemetry: FORCE_FLOAT does not affect persistence or callback options" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export ZDX_TELEMETRY=1
    _log_telemetry "sys:sys-info" 0.001 0 || exit 31
    setopt force_float
    _telemetry_callback_options() {
      [[ -o force_float ]] || return 78
      typeset -g TELEMETRY_CALLBACK_OPTIONS=preserved
    }
    _timed "sys:sys-health" _telemetry_callback_options || exit 32
    [[ -o force_float && "$TELEMETRY_CALLBACK_OPTIONS" == preserved ]] || exit 33
    command jq -s -e "length == 2 and .[1].command == \"sys-health\"" \
      "$HOME/.config/zdx/telemetry.json" >/dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *'invalid number of lines'* ]]
}

@test "telemetry: a retained lock produces one warning and keeps command statuses" {
  mkdir -p "$HOME/.config/zdx/.telemetry.lock"
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx" "$HOME/.config/zdx/.telemetry.lock"
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1 ZDX_TELEMETRY=1
    _telemetry_callback_failure() { return 23; }
    _timed "sys:sys-info" true 2> "$HOME/telemetry-ui"
    local first_rc=$?
    _timed "sys:sys-health" _telemetry_callback_failure 2>> "$HOME/telemetry-ui"
    local second_rc=$?
    [[ $first_rc == 0 && $second_rc == 23 ]] || exit 31
    [[ -d "$HOME/.config/zdx/.telemetry.lock" && ! -e "$HOME/.config/zdx/telemetry.json" ]] || exit 32
    command grep -c "Telemetry.*could not be written" "$HOME/telemetry-ui"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  [ -d "$HOME/.config/zdx/.telemetry.lock" ]
  [ ! -e "$HOME/.config/zdx/telemetry.json" ]
}

@test "telemetry: writable ancestors are refused without permission repair" {
  mkdir -p "$HOME/.config/zdx"
  chmod -- 777 "$HOME/.config"
  chmod -- 700 "$HOME/.config/zdx"
  run run_zsh '_log_telemetry "sys:sys-info" 0.001 0'
  [ "$status" -eq 1 ]
  [ "$(file_mode "$HOME/.config")" = 777 ]
  [ ! -e "$HOME/.config/zdx/telemetry.json" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "telemetry: a dangling destination link is refused without replacement" {
  mkdir -p "$HOME/.config/zdx"
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx"
  ln -s "$HOME/absent-target" "$HOME/.config/zdx/telemetry.json"
  run run_zsh '_log_telemetry "sys:sys-info" 0.001 0'
  [ "$status" -eq 1 ]
  [ -L "$HOME/.config/zdx/telemetry.json" ]
  [ ! -e "$HOME/absent-target" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "telemetry: a hard-linked destination is refused without rewriting either name" {
  mkdir -p "$HOME/.config/zdx"
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx"
  printf 'sentinel\n' > "$HOME/telemetry-victim"
  chmod -- 600 "$HOME/telemetry-victim"
  ln "$HOME/telemetry-victim" "$HOME/.config/zdx/telemetry.json"
  local before_id
  before_id=$(file_identity "$HOME/.config/zdx/telemetry.json")
  run run_zsh '_log_telemetry "sys:sys-info" 0.001 0'
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/telemetry-victim")" = sentinel ]
  [ "$(file_identity "$HOME/.config/zdx/telemetry.json")" = "$before_id" ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "telemetry: a writable existing log is refused without changing its mode or data" {
  mkdir -p "$HOME/.config/zdx"
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx"
  printf 'sentinel\n' > "$HOME/.config/zdx/telemetry.json"
  chmod -- 666 "$HOME/.config/zdx/telemetry.json"
  run run_zsh '_log_telemetry "sys:sys-info" 0.001 0'
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.config/zdx/telemetry.json")" = sentinel ]
  [ "$(file_mode "$HOME/.config/zdx/telemetry.json")" = 666 ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "telemetry: writer calls place the chmod option terminator before every mode" {
  local chmod_bin
  chmod_bin=$(command -v chmod)
  export TELEMETRY_CHMOD_BIN="$chmod_bin"
  cat > "$TEST_MOCK_BIN/chmod" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" = -- ]] || { printf 'missing mode separator\n' >&2; exit 97; }
exec "$TELEMETRY_CHMOD_BIN" "$@"
MOCK
  chmod -- 755 "$TEST_MOCK_BIN/chmod"
  run run_zsh '_log_telemetry "sys:sys-info" 0.001 0'
  [ "$status" -eq 0 ]
  [ -f "$HOME/.config/zdx/telemetry.json" ]
  [ "$(file_mode "$HOME/.config/zdx/telemetry.json")" = 600 ]
}

@test "telemetry: the writer preserves caller regex result parameters" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    typeset MATCH=caller MBEGIN=7 MEND=12
    typeset -a match=(captured) mbegin=(2) mend=(8)
    _log_telemetry "sys:sys-info" 0.001 0 || exit 31
    [[ "$MATCH" == caller && "$MBEGIN" == 7 && "$MEND" == 12 ]] || exit 32
    [[ "${match[1]}" == captured && "${mbegin[1]}" == 2 && "${mend[1]}" == 8 ]]
  '
  [ "$status" -eq 0 ]
}

@test "telemetry: disabled recording still normalizes private timer labels" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1 ZDX_TELEMETRY=0
    _timed "env:zdx-canary-disabled-789" true > "$HOME/timer.stdout" 2> "$HOME/timer.stderr"
    local timer_rc=$? ui="$(<"$HOME/timer.stderr")"
    [[ "$timer_rc" == 0 && ! -s "$HOME/timer.stdout" ]] || exit 31
    [[ "$ui" == *"env:unknown completed in "* && "$ui" != *zdx-canary-disabled-789* ]] || exit 32
    [[ ! -e "$HOME/.config/zdx/telemetry.json" ]]
  '
  [ "$status" -eq 0 ]
}

@test "telemetry: failed writes can recover without repeating the shell warning" {
  mkdir -p "$HOME/.config/zdx/.telemetry.lock"
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx" "$HOME/.config/zdx/.telemetry.lock"
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1 ZDX_TELEMETRY=1
    _telemetry_retry_failure() { return 23; }
    _timed "sys:sys-info" true 2> "$HOME/telemetry-ui"
    local first_rc=$?
    command rmdir -- "$HOME/.config/zdx/.telemetry.lock" || exit 31
    _timed "sys:sys-health" true 2>> "$HOME/telemetry-ui"
    local second_rc=$?
    command mkdir "$HOME/.config/zdx/.telemetry.lock" || exit 32
    _timed "sys:sys-ports" _telemetry_retry_failure 2>> "$HOME/telemetry-ui"
    local third_rc=$?
    [[ "$first_rc" == 0 && "$second_rc" == 0 && "$third_rc" == 23 ]] || exit 33
    command jq -s -e "length == 1 and .[0].command == \"sys-health\"" \
      "$HOME/.config/zdx/telemetry.json" >/dev/null || exit 34
    command grep -c "Telemetry.*could not be written" "$HOME/telemetry-ui"
  '
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  [ -d "$HOME/.config/zdx/.telemetry.lock" ]
}

@test "telemetry: persistence failure does not abort successful timing under ERR_EXIT" {
  mkdir -p "$HOME/.config/zdx/.telemetry.lock"
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx" "$HOME/.config/zdx/.telemetry.lock"
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1 ZDX_TELEMETRY=1
    setopt err_exit
    _telemetry_err_exit_callback() {
      [[ -o err_exit ]] || return 78
      print -r -- callback > "$HOME/callback.options"
    }
    # This invocation is deliberately outside if/&&/|| so ERR_EXIT is active.
    _timed "sys:sys-info" _telemetry_err_exit_callback > "$HOME/timer.stdout" 2> "$HOME/timer.stderr"
    print -r -- continued
    [[ -o err_exit && "$(<"$HOME/callback.options")" == callback && ! -s "$HOME/timer.stdout" ]]
  '
  [ "$status" -eq 0 ]
  [ "$output" = continued ]
  [ ! -e "$HOME/.config/zdx/telemetry.json" ]
}

@test "telemetry: unprefixed Python commands use their registered owner" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    _log_telemetry "package-install" 0.001 0 || exit 31
    command jq -r ".suite + \":\" + .command" "$HOME/.config/zdx/telemetry.json"
  '
  [ "$status" -eq 0 ]
  [ "$output" = py:package-install ]
}

@test "telemetry: callback results survive changed labels without leaking those labels" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    export NO_COLOR=1 ZDX_TELEMETRY=1
    _telemetry_callback_owned_state() {
      typeset -g REPLY=business-data
      label="env:zdx-callback-secret-789"
      return 23
    }
    _timed "sys:sys-info" _telemetry_callback_owned_state \
      > "$HOME/timer.stdout" 2> "$HOME/timer.stderr"
    local timer_rc=$? callback_reply="$REPLY" ui="$(<"$HOME/timer.stderr")"
    local record="$(<"$HOME/.config/zdx/telemetry.json")"
    [[ "$timer_rc" == 23 && "$callback_reply" == business-data && ! -s "$HOME/timer.stdout" ]] || exit 31
    [[ "$ui" != *zdx-callback-secret-789* && "$record" != *zdx-callback-secret-789* ]] || exit 32
    [[ "$ui" == *"env:unknown failed after "*"(status 23)"* ]] || exit 33
    command jq -e ".suite == \"env\" and .command == \"unknown\" and .exit_code == 23" \
      "$HOME/.config/zdx/telemetry.json" >/dev/null
  '
  [ "$status" -eq 0 ]
}

@test "telemetry: a one-record limit retains only the newest complete record" {
  run run_zsh '
    builtin cd -- "$HOME" || exit 80
    ZDX_TELEMETRY_MAX_RECORDS=1
    _log_telemetry "sys:sys-info" 0.001 0 || exit 31
    _log_telemetry "sys:sys-health" 0.002 23 || exit 32
    command jq -s -e "length == 1 and .[0].command == \"sys-health\" and .[0].exit_code == 23" \
      "$HOME/.config/zdx/telemetry.json" >/dev/null
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/zdx/.telemetry.lock" ]
}

# Interpose at the existing-log read, before publication revalidation. Every
# operation and pathname below belongs to this test's disposable HOME.
_telemetry_race_fixture() {
  case "$HOME" in "$TEST_TEMP_DIR"/*) ;; *) return 90 ;; esac
  TELEMETRY_RACE_LOG="$HOME/.config/zdx/telemetry.json"
  TELEMETRY_RACE_LOCK="$HOME/.config/zdx/.telemetry.lock"
  TELEMETRY_RACE_HOOK="$TEST_TEMP_DIR/read-hook.called"
  TELEMETRY_RACE_ERROR="$TEST_TEMP_DIR/mock.failed"
  TELEMETRY_RACE_STAGE="$TEST_TEMP_DIR/stage.path"
  TELEMETRY_RACE_STATUS="$TEST_TEMP_DIR/writer.status"
  TELEMETRY_RACE_LOCK_ID="$TEST_TEMP_DIR/replacement-lock.identity"
  TELEMETRY_RACE_VICTIM="$HOME/victim"
  TELEMETRY_RACE_REAL_TAIL=$(command -v tail)
  TELEMETRY_RACE_REAL_MKTEMP=$(command -v mktemp)
  TELEMETRY_RACE_REAL_MV=$(command -v mv)
  TELEMETRY_RACE_REAL_MKDIR=$(command -v mkdir)
  TELEMETRY_RACE_REAL_CHMOD=$(command -v chmod)
  TELEMETRY_RACE_REAL_LN=$(command -v ln)
  TELEMETRY_RACE_REAL_ZSH=$(command -v zsh)
  export TELEMETRY_RACE_LOG TELEMETRY_RACE_LOCK TELEMETRY_RACE_HOOK
  export TELEMETRY_RACE_ERROR TELEMETRY_RACE_STAGE TELEMETRY_RACE_STATUS
  export TELEMETRY_RACE_LOCK_ID TELEMETRY_RACE_VICTIM
  export TELEMETRY_RACE_REAL_TAIL TELEMETRY_RACE_REAL_MKTEMP
  export TELEMETRY_RACE_REAL_MV TELEMETRY_RACE_REAL_MKDIR
  export TELEMETRY_RACE_REAL_CHMOD TELEMETRY_RACE_REAL_LN TELEMETRY_RACE_REAL_ZSH
  mkdir -p "$HOME/.config/zdx"
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx"
  printf '%s\n' '{"suite":"sys","command":"sys-info","duration_ms":1,"exit_code":0,"timestamp":"2026-01-01T00:00:00Z"}' > "$TELEMETRY_RACE_LOG"
  printf '%s\n' '{"suite":"sys","command":"sys-health","duration_ms":777,"exit_code":0,"timestamp":"2026-01-02T00:00:00Z"}' > "$HOME/replacement.log"
  printf '%s\n' victim-sentinel > "$TELEMETRY_RACE_VICTIM"
  chmod -- 600 "$TELEMETRY_RACE_LOG" "$HOME/replacement.log" "$TELEMETRY_RACE_VICTIM"
  cat > "$TEST_MOCK_BIN/mktemp" <<'SH'
#!/usr/bin/env bash
stage=$("$TELEMETRY_RACE_REAL_MKTEMP" "$@") || exit "$?"
case "$stage" in
  "$HOME/.config/zdx/.telemetry."*) printf '%s\n' "$stage" > "$TELEMETRY_RACE_STAGE" ;;
esac
printf '%s\n' "$stage"
SH
  cat > "$TEST_MOCK_BIN/tail" <<'SH'
#!/usr/bin/env bash
fail_hook() {
  printf '%s\n' "$1" > "$TELEMETRY_RACE_ERROR"
  exit 96
}
# A real existing-log read is the observable synchronization point. Other
# calls are transparent, including the writer's subsequent retention reads.
if [[ "${!#}" != "$TELEMETRY_RACE_LOG" || -e "$TELEMETRY_RACE_HOOK" ]]; then
  exec "$TELEMETRY_RACE_REAL_TAIL" "$@"
fi
[[ -s "$TELEMETRY_RACE_STAGE" ]] || fail_hook missing-stage
stage=$(<"$TELEMETRY_RACE_STAGE")
[[ -f "$stage" && -d "$TELEMETRY_RACE_LOCK" ]] || fail_hook unowned-window
case "$TELEMETRY_RACE_MODE" in
  log)
    "$TELEMETRY_RACE_REAL_TAIL" "$@" || fail_hook real-tail
    "$TELEMETRY_RACE_REAL_MV" -- "$TELEMETRY_RACE_LOG" "$HOME/log.original" || fail_hook move-log
    "$TELEMETRY_RACE_REAL_MV" -- "$HOME/replacement.log" "$TELEMETRY_RACE_LOG" || fail_hook replace-log
    printf '%s\n' log > "$TELEMETRY_RACE_HOOK"
    exit 0
    ;;
  stage)
    "$TELEMETRY_RACE_REAL_MV" -- "$stage" "$stage.original" || fail_hook move-stage
    "$TELEMETRY_RACE_REAL_LN" -s -- "$TELEMETRY_RACE_VICTIM" "$stage" || fail_hook link-stage
    printf '%s\n' stage > "$TELEMETRY_RACE_HOOK"
    exit 77
    ;;
  lock)
    "$TELEMETRY_RACE_REAL_MV" -- "$TELEMETRY_RACE_LOCK" "$HOME/lock.original" || fail_hook move-lock
    "$TELEMETRY_RACE_REAL_MKDIR" -- "$TELEMETRY_RACE_LOCK" || fail_hook replace-lock
    "$TELEMETRY_RACE_REAL_CHMOD" -- 700 "$TELEMETRY_RACE_LOCK" || fail_hook mode-lock
    "$TELEMETRY_RACE_REAL_ZSH" -f -c '
      emulate -R zsh
      zmodload -F zsh/stat b:zstat || exit 90
      local -A observed=()
      zstat -LH observed -- "$1" || exit 91
      print -r -- "$observed[device]:$observed[inode]"
    ' _ "$TELEMETRY_RACE_LOCK" > "$TELEMETRY_RACE_LOCK_ID" || fail_hook stat-lock
    printf '%s\n' lock > "$TELEMETRY_RACE_HOOK"
    exit 77
    ;;
  *) fail_hook unknown-mode ;;
esac
SH
  chmod -- 755 "$TEST_MOCK_BIN/mktemp" "$TEST_MOCK_BIN/tail"
}

_telemetry_race_call() {
  run run_zsh '
    cd "$HOME" || exit 90
    _log_telemetry "sys:sys-info" 0.001 0 > "$HOME/writer.out" 2> "$HOME/writer.err"
    writer_rc=$?
    print -r -- "$writer_rc" > "$TELEMETRY_RACE_STATUS"
    [[ ! -s "$HOME/writer.out" ]] || exit 91
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$TELEMETRY_RACE_HOOK" ]
  [ ! -e "$TELEMETRY_RACE_ERROR" ]
}

@test "telemetry race: an existing log replaced during its staged read is preserved" {
  _telemetry_race_fixture
  export TELEMETRY_RACE_MODE=log
  local replacement_hash
  replacement_hash=$(sha256_file "$HOME/replacement.log")
  _telemetry_race_call
  printf 'writer=%s replacement-preserved=%s\n' "$(cat "$TELEMETRY_RACE_STATUS")" \
    "$([ "$(sha256_file "$TELEMETRY_RACE_LOG")" = "$replacement_hash" ] && printf yes || printf no)"
  [ "$(cat "$TELEMETRY_RACE_STATUS")" -eq 1 ]
  [ "$(sha256_file "$TELEMETRY_RACE_LOG")" = "$replacement_hash" ]
  [ -f "$HOME/log.original" ]
  [ ! -e "$TELEMETRY_RACE_LOCK" ]
}

@test "telemetry race: failed staging cleanup preserves a replaced stage link and its victim" {
  _telemetry_race_fixture
  export TELEMETRY_RACE_MODE=stage
  local victim_hash original_hash stage
  victim_hash=$(sha256_file "$TELEMETRY_RACE_VICTIM")
  original_hash=$(sha256_file "$TELEMETRY_RACE_LOG")
  _telemetry_race_call
  stage=$(cat "$TELEMETRY_RACE_STAGE")
  printf 'writer=%s stage-link=%s victim-preserved=%s\n' "$(cat "$TELEMETRY_RACE_STATUS")" \
    "$([ -L "$stage" ] && printf present || printf missing)" \
    "$([ "$(sha256_file "$TELEMETRY_RACE_VICTIM")" = "$victim_hash" ] && printf yes || printf no)"
  [ "$(cat "$TELEMETRY_RACE_STATUS")" -eq 1 ]
  [ -L "$stage" ]
  [ "$(readlink "$stage")" = "$TELEMETRY_RACE_VICTIM" ]
  [ "$(sha256_file "$TELEMETRY_RACE_VICTIM")" = "$victim_hash" ]
  [ "$(sha256_file "$TELEMETRY_RACE_LOG")" = "$original_hash" ]
  [ ! -e "$TELEMETRY_RACE_LOCK" ]
}

@test "telemetry race: failure cleanup preserves an empty replacement of the acquired lock" {
  _telemetry_race_fixture
  export TELEMETRY_RACE_MODE=lock
  local original_hash
  original_hash=$(sha256_file "$TELEMETRY_RACE_LOG")
  _telemetry_race_call
  printf 'writer=%s replacement-lock=%s\n' "$(cat "$TELEMETRY_RACE_STATUS")" \
    "$([ -d "$TELEMETRY_RACE_LOCK" ] && printf present || printf missing)"
  [ "$(cat "$TELEMETRY_RACE_STATUS")" -eq 1 ]
  [ -d "$TELEMETRY_RACE_LOCK" ]
  [ "$(file_identity "$TELEMETRY_RACE_LOCK")" = "$(cat "$TELEMETRY_RACE_LOCK_ID")" ]
  [ -d "$HOME/lock.original" ]
  [ "$(sha256_file "$TELEMETRY_RACE_LOG")" = "$original_hash" ]
}
