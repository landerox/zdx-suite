#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "telemetry: does not log when disabled (default)" {
  run run_zsh "
    # Run _timed which is defined in functions.zsh
    _timed 'test_cmd' echo 'Hello'

    # Check if telemetry.json was created
    [ ! -f \"\$HOME/.config/zdx/telemetry.json\" ]
  "
  [ "$status" -eq 0 ]
}

@test "telemetry: logs to telemetry.json when enabled" {
  run run_zsh "
    export ZDX_TELEMETRY=1
    _timed 'sys:test_cmd' true

    [ -f \"\$HOME/.config/zdx/telemetry.json\" ]

    # Read the file and verify content
    content=\$(cat \"\$HOME/.config/zdx/telemetry.json\")
    [[ \"\$content\" == *'\"suite\": \"sys\"'* ]]
    [[ \"\$content\" == *'\"command\": \"test_cmd\"'* ]]
    [[ \"\$content\" == *'\"exit_code\": 0'* ]]
    [[ \"\$content\" == *'\"duration_ms\":'* ]]
    [[ \"\$content\" == *'\"timestamp\":'* ]]
  "
  [ "$status" -eq 0 ]
}

@test "telemetry: falls back to heuristics if suite prefix is absent" {
  run run_zsh "
    export ZDX_TELEMETRY=true
    _timed 'vpn-status' true

    content=\$(cat \"\$HOME/.config/zdx/telemetry.json\")
    [[ \"\$content\" == *'\"suite\": \"vpn\"'* ]]
    [[ \"\$content\" == *'\"command\": \"vpn-status\"'* ]]
  "
  [ "$status" -eq 0 ]
}

@test "telemetry: _timed reports failures without hiding status or telemetry" {
  run run_zsh '
    export NO_COLOR=1
    export ZDX_TELEMETRY=1

    _telemetry_timer_failure() { return 23; }

    _timed "sys:timer-success" true || return 90
    _timed "sys:timer-failure" _telemetry_timer_failure
    local timer_rc=$?

    command grep -Fq "\"command\": \"timer-success\"" \
      "$HOME/.config/zdx/telemetry.json" || return 91
    command grep -Fq "\"exit_code\": 0" \
      "$HOME/.config/zdx/telemetry.json" || return 92
    command grep -Fq "\"command\": \"timer-failure\"" \
      "$HOME/.config/zdx/telemetry.json" || return 93
    command grep -Fq "\"exit_code\": 23" \
      "$HOME/.config/zdx/telemetry.json" || return 94

    return $timer_rc
  '

  [ "$status" -eq 23 ]
  [[ "$output" == *"sys:timer-success completed in "*"s"* ]]
  [[ "$output" == *"sys:timer-failure failed after "*"s (status 23)"* ]]
  [[ "$output" != *"sys:timer-failure completed in"* ]]
}

@test "telemetry: _timed distinguishes an explicitly marked partial result" {
  run run_zsh '
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
    sys-telemetry --help
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"sys-telemetry"* ]]
}

@test "telemetry: sys-telemetry --dashboard warning when empty" {
  run run_zsh "
    rm -f \"\$HOME/.config/zdx/telemetry.json\"
    sys-telemetry --dashboard
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"No telemetry data found"* ]]
}

@test "telemetry: sys-telemetry --dashboard displays stats" {
  run run_zsh "
    export ZDX_TELEMETRY=1
    _timed 'sys:test_cmd_1' true
    _timed 'vpn:test_cmd_2' true
    _timed 'sys:test_cmd_failed' false

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
    export ZDX_TELEMETRY=1
    _timed 'sys:test_cmd' true
    [ -s \"\$HOME/.config/zdx/telemetry.json\" ]

    sys-telemetry --clear --yes
    [ ! -s \"\$HOME/.config/zdx/telemetry.json\" ]
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Telemetry log cleared successfully"* ]]
}
