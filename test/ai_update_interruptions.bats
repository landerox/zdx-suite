#!/usr/bin/env bats
# Quoted programs are passed literally to the isolated Zsh process.
# BATS runs each test body with its own exported mock controls.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export AI_UPDATE_MOCKS="$TEST_TEMP_DIR/update-mocks.zsh"
  cat >"$AI_UPDATE_MOCKS" <<'EOF'
source "$ZSH_CUSTOM/functions/ai-menu.zsh"
source "$ZSH_CUSTOM/functions/sys-menu.zsh"
_ai_update_capture_binary() {
  if [[ "${AI_ONLY_ONE:-0}" == 1 && "$1" != claude ]]; then
    return 1
  fi
  _AI_UPDATE_BINARY="/reviewed/$1"
  _AI_UPDATE_CANONICAL="$_AI_UPDATE_BINARY"
  _AI_UPDATE_FINGERPRINT="stable-$1"
  _AI_UPDATE_PATH_PREFIX=""
}
_ai_probe_cli() { print -r -- "$1 1.0.0"; }
_ai_update_run_captured() {
  local cli="${1:t}"
  print -r -- "$cli" >>"$HOME/updater.calls"
  _AI_UPDATE_FAILURE_KIND="updater"
  [[ "$cli" == "$AI_FAILURE_CLI" ]] && return "$AI_FAILURE_STATUS"
  return 0
}
_zdx_timed_mark_partial() { print -r -- partial >>"$HOME/partial.calls"; }
EOF
}

teardown() {
  cleanup_sandbox
}

@test "ai update interruptions: INT and TERM preserve status and complete the eight-target ledger" {
  for interruption_status in 130 143; do
    export AI_FAILURE_CLI=codex AI_FAILURE_STATUS="$interruption_status"
    : >"$HOME/updater.calls"
    run run_zsh '
      source "$AI_UPDATE_MOCKS"
      ai-menu ai-update --yes --result-tsv >"$HOME/results.tsv"
      local update_rc=$?
      _sys_update_ai_parse_results "$(<"$HOME/results.tsv")" || return 97
      return $update_rc
    '

    [ "$status" -eq "$interruption_status" ]
    [ "$(cat "$HOME/updater.calls")" = $'claude\ncodex' ]
    [ "$(wc -l <"$HOME/results.tsv")" -eq 8 ]
    grep -Fq $'codex\tCodex CLI\tfailed\tupdater-failed\t'"$interruption_status" \
      "$HOME/results.tsv"
    [ "$(grep -c $'\tnot-run\tinterrupted\t'"$interruption_status" "$HOME/results.tsv")" -eq 6 ]
    [[ "$output" == *"not run (update interrupted)"* ]]
    [[ "$output" != *"partial failures"* ]]
  done
  [ ! -e "$HOME/partial.calls" ]
}

@test "ai update interruptions: absent tools do not turn an all-failed update into partial success" {
  export AI_ONLY_ONE=1 AI_FAILURE_CLI=claude AI_FAILURE_STATUS=23
  run run_zsh '
    source "$AI_UPDATE_MOCKS"
    ai-menu ai-update --yes --result-tsv >"$HOME/results.tsv"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/updater.calls")" = claude ]
  [[ "$output" == *"0 updated, 0 already current, 1 failed, 7 skipped"* ]]
  [ ! -e "$HOME/partial.calls" ]
}

@test "ai update interruptions: an ordinary failure still runs later targets and marks real partial success" {
  export AI_FAILURE_CLI=codex AI_FAILURE_STATUS=23
  run run_zsh '
    source "$AI_UPDATE_MOCKS"
    ai-menu ai-update --yes --result-tsv >"$HOME/results.tsv"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/updater.calls")" = $'claude\ncodex\nagy\nopencode\ncursor-agent\ncopilot\namp\nhermes' ]
  [ "$(cat "$HOME/partial.calls")" = partial ]
  [[ "$output" == *"0 updated, 7 already current, 1 failed, 0 skipped"* ]]
}

@test "ai update interruptions: System rejects an interrupted record with an ordinary status" {
  export AI_FAILURE_CLI=codex AI_FAILURE_STATUS=130
  run run_zsh '
    source "$AI_UPDATE_MOCKS"
    ai-menu ai-update --yes --result-tsv >"$HOME/results.tsv"
    local report="$(<"$HOME/results.tsv")"
    report="${report//$'\''not-run\tinterrupted\t130'\''/$'\''not-run\tinterrupted\t23'\''}"
    _sys_update_ai_parse_results "$report"
  '

  [ "$status" -eq 2 ]
}

@test "ai update interruptions: the interactive route preserves updater interruption status" {
  export AI_FAILURE_CLI=codex AI_FAILURE_STATUS=143
  run run_zsh '
    source "$AI_UPDATE_MOCKS"
    _ai_authorize() { return 0; }
    _ai_fzf_capture() {
      local row
      while IFS= read -r row; do
        [[ "$row" == *"|ai-update|"* ]] && REPLY="$row"
      done
      return 0
    }
    ai-menu
  '

  [ "$status" -eq 143 ]
  [ "$(cat "$HOME/updater.calls")" = $'claude\ncodex' ]
}
