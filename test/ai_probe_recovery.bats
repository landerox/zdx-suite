#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 "$TMPDIR"
  export PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
  cat > "$TEST_MOCK_BIN/hermes" <<'EOF'
#!/usr/bin/env zsh
case "$*" in
  --version)
    [[ "${PYTHONUNBUFFERED:-}" == 1 ]] || exit 98
    if IFS= read -r unexpected; then
      print -r -- consumed-input > "$HOME/probe-consumed-input"
      exit 99
    fi
    if [[ -n "${HERMES_HEADER:-}" ]]; then
      print -r -- "$HERMES_HEADER"
    elif [[ -e "$HOME/hermes-updated" ]]; then
      print -r -- 'Hermes Agent v0.20.7 (2026.8.28)'
    else
      print -r -- 'Hermes Agent v0.20.6 (2026.8.27)'
    fi
    print -r -- 'Private trailing diagnostic' >&2
    if [[ "${HERMES_OVERFLOW:-0}" == 1 ]]; then
      repeat 7000 print -r -- 0123456789
    fi
    if [[ "${HERMES_SLOW_STATUS:-0}" == 1 ]]; then
      trap 'print -r -- stopped > "$HOME/status-check-stopped"; exit 0' TERM
      sleep 30 &
      wait
    fi
    exit "${HERMES_PROBE_RC:-0}"
    ;;
  'update --backup --yes')
    print -r -- "$*" > "$HOME/hermes-updated"
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/hermes"
}

teardown() {
  cleanup_sandbox
}

@test "ai probe recovery: current Hermes version flag enters a dry-run plan" {
  run run_zsh 'ai-update-hermes --dry-run --result-tsv'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ai-update-result-v1\thermes\tHermes Agent\tplanned\teligible\t0'* ]]
  [ ! -e "$HOME/hermes-updated" ]
  [[ "$output" != *"Private trailing diagnostic"* ]]
}

@test "ai probe recovery: complete Hermes version survives an ancillary check timeout" {
  export HERMES_PROBE_RC=124
  run run_zsh 'ai-update-hermes --yes --result-tsv'
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/hermes-updated")" = 'update --backup --yes' ]
  [[ "$output" == *$'\thermes\tHermes Agent\tupdated\tversion-changed\t0'* ]]
  [[ "$output" != *"Private trailing diagnostic"* ]]
}

@test "ai probe recovery: malformed Hermes header cannot authorize an update after timeout" {
  export HERMES_PROBE_RC=124 HERMES_HEADER='Hermes Agent version lookup pending'
  run run_zsh 'ai-update-hermes --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/hermes-updated" ]
  [[ "$output" == *"version probe failed"* ]]
}

@test "ai probe recovery: Hermes runtime failure is not accepted as a trailing timeout" {
  export HERMES_PROBE_RC=9
  run run_zsh 'ai-update-hermes --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/hermes-updated" ]
}

@test "ai probe recovery: Hermes timeout recovery preserves the output size bound" {
  export HERMES_PROBE_RC=124 HERMES_OVERFLOW=1
  run run_zsh 'ai-update-hermes --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/hermes-updated" ]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "ai probe recovery: other assistants cannot reuse a version from a failed probe" {
  cat > "$TEST_MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env zsh
print -r -- 'codex-cli 0.153.4'
exit 124
EOF
  chmod +x "$TEST_MOCK_BIN/codex"
  run run_zsh 'ai-update-codex --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"version probe failed"* ]]
}

@test "ai probe recovery: version probes close input and scope Hermes buffering" {
  run run_zsh '
    export PYTHONUNBUFFERED=original
    print -r -- retained-input | _ai_probe_cli hermes || return 1
    [[ "$PYTHONUNBUFFERED" == original ]] || return 2
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/probe-consumed-input" ]
  [[ "$output" == 'Hermes Agent v0.20.6 (2026.8.27)' ]]
}

@test "ai probe recovery: a real bounded Hermes status check yields its version and cleans up" {
  export HERMES_SLOW_STATUS=1
  run run_zsh '_ai_probe_cli hermes'
  [ "$status" -eq 0 ]
  [[ "$output" == 'Hermes Agent v0.20.6 (2026.8.27)' ]]
  [ -e "$HOME/status-check-stopped" ]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}
