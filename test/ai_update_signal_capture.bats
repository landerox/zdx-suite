#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  export AI_SIGNAL_REAL_TAIL
  AI_SIGNAL_REAL_TAIL="$(type -P tail)"
  load test_helper
  export PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 "$TMPDIR"
  export AI_SIGNAL_UPDATER_RC=130 AI_SIGNAL_SINK_RC=143
  cat > "$TEST_MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env zsh
[[ "$*" == --version ]] && { print -r -- 'claude 1.0.0'; exit 0; }
[[ "$*" == update ]] || exit 97
print -r -- claude >> "$HOME/updater.calls"
exit "$AI_SIGNAL_UPDATER_RC"
EOF
  cat > "$TEST_MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env zsh
[[ "$*" == --version ]] && { print -r -- 'codex 1.0.0'; exit 0; }
[[ "$*" == update ]] || exit 97
print -r -- codex >> "$HOME/updater.calls"
EOF
  cat > "$TEST_MOCK_BIN/tail" <<'EOF'
#!/usr/bin/env zsh
# Model the independently interrupted output sink without signaling BATS.
[[ "$*" == '-c 262144' ]] || exec "$AI_SIGNAL_REAL_TAIL" "$@"
command cat > /dev/null
exit "$AI_SIGNAL_SINK_RC"
EOF
  chmod +x "$TEST_MOCK_BIN/claude" "$TEST_MOCK_BIN/codex" \
    "$TEST_MOCK_BIN/tail"
}

teardown() {
  cleanup_sandbox
}

@test "ai signal capture: pipeline interruptions preserve status and stop later updates" {
  for signal_case in '130 143 130' '143 130 143' '0 130 130' '0 143 143'; do
    read -r AI_SIGNAL_UPDATER_RC AI_SIGNAL_SINK_RC interruption_status <<< "$signal_case"
    export AI_SIGNAL_UPDATER_RC AI_SIGNAL_SINK_RC
    : > "$HOME/updater.calls"
    run run_zsh '
      source "$ZSH_CUSTOM/functions/ai-menu.zsh"
      # The shared command wrapper replaces the real pipeline statuses.
      unfunction command
      ai-update --yes --result-tsv > "$HOME/results.tsv"
    '

    [ "$status" -eq "$interruption_status" ]
    [ "$(cat "$HOME/updater.calls")" = claude ]
    [ "$(wc -l < "$HOME/results.tsv")" -eq 8 ]
    grep -Fxq $'ai-update-result-v1\tclaude\tClaude Code\tfailed\tresult-capture-failed\t'"$interruption_status" \
      "$HOME/results.tsv"
    grep -Fxq $'ai-update-result-v1\tcodex\tCodex CLI\tnot-run\tinterrupted\t'"$interruption_status" \
      "$HOME/results.tsv"
    [ "$(grep -c $'\tskipped\tnot-installed\t0' "$HOME/results.tsv")" -eq 6 ]
    [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
  done
}

@test "ai signal capture: ordinary sink failures retain output integrity failure status" {
  for updater_status in 0 23; do
    export AI_SIGNAL_UPDATER_RC="$updater_status" AI_SIGNAL_SINK_RC=1
    run run_zsh '
      source "$ZSH_CUSTOM/functions/ai-menu.zsh"
      unfunction command
      _ai_update_run_captured "$TEST_MOCK_BIN/claude" "" claude update
      local capture_rc=$?
      print -r -- "kind=$_AI_UPDATE_FAILURE_KIND"
      return $capture_rc
    '

    [ "$status" -eq 125 ]
    [[ "$output" == 'kind=adapter' ]]
    [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
  done
}
