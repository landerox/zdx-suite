#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 "$TMPDIR"
  export AI_RECOVERY_LOG="$TEST_TEMP_DIR/ai-recovery.log"
  : > "$AI_RECOVERY_LOG"
  cat > "$TEST_MOCK_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == --version ]]; then printf 'opencode 1.0.0\n'; exit 0; fi
[[ "$*" == upgrade ]] || exit 97
printf 'opencode\n' >> "$AI_RECOVERY_LOG"
case "${AI_RECOVERY_MODE:-failed}" in
  failed)
    printf '\033[31m■\033[0m  Upgrade \033[31mfailed\033[0m\n'
    printf 'Vendor diagnostic: token=DO_NOT_REPLAY_RECOVERY_SECRET\n'
    ;;
  current) printf 'opencode upgrade skipped: 1.0.0 is already installed\n' ;;
  auth)
    printf '■ Upgrade failed\n'
    printf 'Authentication required: token=DO_NOT_REPLAY_RECOVERY_SECRET\n'
    ;;
esac
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/opencode"
}

teardown() {
  cleanup_sandbox
}

@test "ai recovery: OpenCode failure output overrides its successful exit status" {
  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    ai-update-opencode --yes --result-tsv > "$HOME/results.tsv"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$AI_RECOVERY_LOG")" = opencode ]
  [ "$(cat "$HOME/results.tsv")" = $'ai-update-result-v1\topencode\tOpenCode\tfailed\tupdater-failed\t1' ]
  [[ "$output" != *"already at the latest"* ]]
  [[ "$output" != *"DO_NOT_REPLAY_RECOVERY_SECRET"* ]]
  [[ "$(cat "$HOME/results.tsv")" != *"DO_NOT_REPLAY_RECOVERY_SECRET"* ]]
  [ -z "$(find "$TMPDIR" -name 'zdx-ai-update-output.*' -print)" ]
}

@test "ai recovery: OpenCode failure does not prevent a later independent updater" {
  cat > "$TEST_MOCK_BIN/amp" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == --version ]]; then
  if [[ -e "$HOME/amp-updated" ]]; then printf 'amp 2.0.0\n'; else printf 'amp 1.0.0\n'; fi
  exit 0
fi
[[ "$*" == update ]] || exit 97
printf 'amp\n' >> "$AI_RECOVERY_LOG"
printf updated > "$HOME/amp-updated"
EOF
  chmod +x "$TEST_MOCK_BIN/amp"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    ai-update --yes --result-tsv > "$HOME/results.tsv"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$AI_RECOVERY_LOG")" = $'opencode\namp' ]
  grep -Fxq $'ai-update-result-v1\topencode\tOpenCode\tfailed\tupdater-failed\t1' "$HOME/results.tsv"
  grep -Fxq $'ai-update-result-v1\tamp\tAmp CLI\tupdated\tversion-changed\t0' "$HOME/results.tsv"
  [ "$(wc -l < "$HOME/results.tsv")" -eq 8 ]
}

@test "ai recovery: the OpenCode marker does not reinterpret another vendor success" {
  cat > "$TEST_MOCK_BIN/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == --version ]]; then printf 'claude 1.0.0\n'; exit 0; fi
[[ "$*" == update ]] || exit 97
printf 'Upgrade failed\n'
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/claude"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    ai-update-claude --yes --result-tsv > "$HOME/results.tsv"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/results.tsv")" = $'ai-update-result-v1\tclaude\tClaude Code\talready-current\tunchanged\t0' ]
}

@test "ai recovery: OpenCode already-current output remains a successful no-op" {
  export AI_RECOVERY_MODE=current
  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    ai-update-opencode --yes --result-tsv > "$HOME/results.tsv"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/results.tsv")" = $'ai-update-result-v1\topencode\tOpenCode\talready-current\tunchanged\t0' ]
}

@test "ai recovery: OpenCode failure retains its more specific authentication diagnosis" {
  export AI_RECOVERY_MODE=auth
  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    ai-update-opencode --yes --result-tsv > "$HOME/results.tsv"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/results.tsv")" = $'ai-update-result-v1\topencode\tOpenCode\tfailed\tauthentication-required\t1' ]
  [[ "$output" == *"vendor authentication is required"* ]]
  [[ "$output" != *"DO_NOT_REPLAY_RECOVERY_SECRET"* ]]
}
