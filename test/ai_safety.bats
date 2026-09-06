#!/usr/bin/env bats

setup() {
  load test_helper
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 "$TMPDIR"
}

teardown() {
  cleanup_sandbox
}

@test "ai safety: cleanup dry-run has no filesystem mutation" {
  mkdir -p "$HOME/.claude/debug"
  printf '%s\n' "keep" > "$HOME/.claude/debug/debug.log"
  run run_zsh 'global-clean-claude --dry-run'
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/debug/debug.log" ]
  [ ! -e "$HOME/.local/share/zdx/ai-trash" ]
}

@test "ai safety: hidden parent bypass is rejected with status 2" {
  mkdir -p "$HOME/.claude/debug"
  printf '%s\n' "keep" > "$HOME/.claude/debug/debug.log"
  run run_zsh 'global-clean-claude --from-parent'
  [ "$status" -eq 2 ]
  [ -f "$HOME/.claude/debug/debug.log" ]
}

@test "ai safety: noninteractive cleanup fails closed without yes" {
  mkdir -p "$HOME/.codex/tmp"
  printf '%s\n' "keep" > "$HOME/.codex/tmp/item"
  run run_zsh 'global-clean-codex'
  [ "$status" -eq 1 ]
  [ -f "$HOME/.codex/tmp/item" ]
  [[ "$output" == *"requires a terminal"* ]]
}

@test "ai safety: global cleanup quarantines only ephemeral allowlisted state" {
  mkdir -p \
    "$HOME/.claude/debug" \
    "$HOME/.claude/tasks" \
    "$HOME/.claude/todos" \
    "$HOME/.claude/plans" \
    "$HOME/.gemini/antigravity-cli/log" \
    "$HOME/.gemini/antigravity-cli/conversations" \
    "$HOME/.gemini/antigravity-cli/brain"
  printf x > "$HOME/.claude/debug/item"
  printf x > "$HOME/.claude/tasks/item"
  printf x > "$HOME/.claude/todos/item"
  printf x > "$HOME/.claude/plans/item"
  printf x > "$HOME/.gemini/antigravity-cli/log/item"
  printf x > "$HOME/.gemini/antigravity-cli/conversations/item"
  printf x > "$HOME/.gemini/antigravity-cli/brain/item"

  run run_zsh 'global-clean-ai --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/debug" ]
  [ ! -e "$HOME/.gemini/antigravity-cli/log" ]
  grep -RqxF "$HOME/.claude/debug" "$HOME/.local/share/zdx/ai-trash"
  [ -f "$HOME/.claude/tasks/item" ]
  [ -f "$HOME/.claude/todos/item" ]
  [ -f "$HOME/.claude/plans/item" ]
  [ -f "$HOME/.gemini/antigravity-cli/conversations/item" ]
  [ -f "$HOME/.gemini/antigravity-cli/brain/item" ]
}

@test "ai safety: repeated quarantine preserves content origin and no-clobber recovery" {
  local source_dir="$HOME/.claude/debug"
  local trash_dir="$HOME/.local/share/zdx/ai-trash"
  local expected_first="$TEST_TEMP_DIR/expected-first.bin"
  local expected_second="$TEST_TEMP_DIR/expected-second.bin"
  mkdir -p "$source_dir/nested"
  printf 'first payload\0with bytes\n' > "$expected_first"
  cp "$expected_first" "$source_dir/nested/payload.bin"

  run run_zsh 'global-clean-claude --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$source_dir" ]

  local first_entry
  first_entry=$(
    find "$trash_dir" -mindepth 1 -maxdepth 1 \
      -type d -name 'zdx-ai-trash.*' -print
  )
  [ -n "$first_entry" ]
  [ "$(find "$trash_dir" -mindepth 1 -maxdepth 1 \
    -type d -name 'zdx-ai-trash.*' | wc -l)" -eq 1 ]
  [ "$(cat "$first_entry/.zdx-origin")" = "$source_dir" ]
  [ "$(stat -c '%a' "$first_entry/.zdx-origin")" = "600" ]
  cmp "$expected_first" "$first_entry/debug/nested/payload.bin"

  mkdir -p "$source_dir/nested"
  printf 'second payload\0must not clobber first\n' > "$expected_second"
  cp "$expected_second" "$source_dir/nested/payload.bin"
  run run_zsh 'global-clean-claude --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$source_dir" ]

  local second_entry
  second_entry=$(
    find "$trash_dir" -mindepth 1 -maxdepth 1 \
      -type d -name 'zdx-ai-trash.*' ! -path "$first_entry" -print
  )
  [ -n "$second_entry" ]
  [ "$second_entry" != "$first_entry" ]
  [ "$(find "$trash_dir" -mindepth 1 -maxdepth 1 \
    -type d -name 'zdx-ai-trash.*' | wc -l)" -eq 2 ]
  [ "$(cat "$second_entry/.zdx-origin")" = "$source_dir" ]
  cmp "$expected_first" "$first_entry/debug/nested/payload.bin"
  cmp "$expected_second" "$second_entry/debug/nested/payload.bin"

  local recovery_path
  recovery_path=$(cat "$second_entry/.zdx-origin")
  mv "$second_entry/debug" "$recovery_path"
  cmp "$expected_second" "$recovery_path/nested/payload.bin"
  cmp "$expected_first" "$first_entry/debug/nested/payload.bin"
}

@test "ai safety: project sweep dry-run preserves ephemeral and durable state" {
  mkdir -p "$HOME/repo/.claude/debug" "$HOME/repo/.claude/todos"
  printf x > "$HOME/repo/.claude/debug/item"
  printf x > "$HOME/repo/.claude/todos/item"
  run run_zsh \
    'project-sweep-ai --root "$HOME" --depth 4 --xdev --dry-run'
  [ "$status" -eq 0 ]
  [ -f "$HOME/repo/.claude/debug/item" ]
  [ -f "$HOME/repo/.claude/todos/item" ]
  [[ "$output" == *".claude/debug"* ]]
  [[ "$output" != *".claude/todos"* ]]
}

@test "ai safety: config backup dry-run creates no backup root" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{}' > "$HOME/.claude/settings.json"
  run run_zsh 'ai-config-backup --dry-run'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.ai-suite-backups" ]
}

@test "ai safety: restore rejects traversal and malformed snapshot tokens" {
  run run_zsh 'ai-config-restore ../escape --dry-run'
  [ "$status" -eq 2 ]
  run run_zsh 'ai-config-restore 20260101T010101-1/../../escape --dry-run'
  [ "$status" -eq 2 ]
  [ ! -e "$TEST_TEMP_DIR/escape" ]
}

@test "ai safety: restore rejects a manifest traversal before mutation" {
  local token="20260101T010101-1"
  local snapshot="$HOME/.ai-suite-backups/$token"
  mkdir -p "$snapshot/files"
  chmod 700 "$HOME/.ai-suite-backups" "$snapshot"
  printf '../../escape\t1\t1\n' > "$snapshot/manifest.tsv"
  run run_zsh "ai-config-restore $token --dry-run"
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TEMP_DIR/escape" ]
  [[ "$output" == *"invalid record"* || "$output" == *"disallowed path"* ]]
}

@test "ai safety: log excerpts redact tokens escape controls and bound lines" {
  mkdir -p "$HOME/.codex/log"
  printf 'token=sk-abcdefghijklmnopqrstuvwxyz\033[31mDANGER\033[0m\n' \
    > "$HOME/.codex/log/recent.log"
  run run_zsh 'NO_COLOR=1 ai-log-tail --lines 5'
  [ "$status" -eq 0 ]
  [[ "$output" == *"REDACTED"* ]]
  [[ "$output" != *"sk-abcdefghijklmnopqrstuvwxyz"* ]]
  [[ "$output" != *$'\033[31m'* ]]
  [[ "$output" == *'^[[31m'* ]]
}

@test "ai safety: source contains no shell evaluator or remote pipe installer" {
  run bash -c '
    ! grep -REn \
      "(^|[[:space:]])eval[[:space:]]|curl[^[:cntrl:]]*\\|[[:space:]]*(ba|z|)sh|@latest" \
      "$1/functions/ai-common.zsh" \
      "$1/functions/ai-menu.zsh" \
      "$1/functions/ai"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "ai safety: representative command parsers reject unknown flags as usage" {
  local command_name
  for command_name in \
    global-clean-claude project-sweep-ai ai-init-agents ai-update-claude \
    ai-mcp-list ai-config-backup ai-config-restore ai-doctor ai-disk-usage \
    ai-versions ai-log-tail; do
    run run_zsh "$command_name --definitely-invalid"
    [ "$status" -eq 2 ]
  done
}

@test "ai safety: flag profiles reject valid options from other commands" {
  run run_zsh 'global-clean-codex --json'
  [ "$status" -eq 2 ]
  run run_zsh 'ai-config-backup --trash'
  [ "$status" -eq 2 ]
  run run_zsh 'ai-doctor --dry-run'
  [ "$status" -eq 2 ]
  run run_zsh 'ai-disk-usage --report'
  [ "$status" -eq 2 ]
  run run_zsh 'ai-versions --trash'
  [ "$status" -eq 2 ]
}

@test "ai safety: Cursor versions and Amp recovery state are preserved" {
  mkdir -p \
    "$HOME/.local/share/cursor-agent/versions/active-old" \
    "$HOME/.local/share/cursor-agent/versions/newer" \
    "$HOME/.cursor/projects/example" \
    "$HOME/.amp/file-changes"
  printf x > "$HOME/.cursor/projects/example/worker.log"
  printf x > "$HOME/.amp/file-changes/recovery"

  run run_zsh 'global-clean-ai --yes'
  [ "$status" -eq 0 ]
  [ -f "$HOME/.cursor/projects/example/worker.log" ]
  [ -d "$HOME/.local/share/cursor-agent/versions/active-old" ]
  [ -d "$HOME/.local/share/cursor-agent/versions/newer" ]
  [ -f "$HOME/.amp/file-changes/recovery" ]
}

@test "ai safety: cleanup rejects a symlinked trash ancestor" {
  local outside="$TEST_TEMP_DIR/outside"
  mkdir -p "$outside" "$HOME/.claude/debug"
  printf keep > "$HOME/.claude/debug/item"
  ln -s "$outside" "$HOME/.local"

  run run_zsh 'global-clean-claude --yes'
  [ "$status" -eq 1 ]
  [ -f "$HOME/.claude/debug/item" ]
  [ ! -e "$outside/share" ]
}

@test "ai safety: sweep never selects name-only lookalikes" {
  mkdir -p "$HOME/repo"
  printf durable > "$HOME/repo/claude-code-roadmap"
  run run_zsh 'project-sweep-ai --root "$HOME" --depth 4 --yes'
  [ "$status" -eq 0 ]
  [ -f "$HOME/repo/claude-code-roadmap" ]
}

@test "ai safety: init rejects delimiter-bearing project roots before mutation" {
  mkdir -p "$HOME/project|segment"
  run run_zsh 'cd "$HOME/project|segment" && ai-init-agents --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/project|segment/AGENTS.md" ]
  [ ! -e "$HOME/AGENTS.md" ]
}

@test "ai safety: update dry-run is passive and the exact self-updater requires authorization" {
  cat <<'EOF' > "$TEST_MOCK_BIN/claude"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  [[ -e "$HOME/claude-updated" ]] && echo "1.2.4" || echo "1.2.3"
  exit 0
fi
if [[ "$1" == "update" && "$#" -eq 1 ]]; then
  printf '%s\n' "$*" > "$HOME/claude-updated"
  exit 0
fi
exit 97
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/npm"
#!/usr/bin/env bash
printf called > "$HOME/npm-called"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/claude" "$TEST_MOCK_BIN/npm"

  run run_zsh 'ai-update-claude --dry-run'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/claude-updated" ]
  [ ! -e "$HOME/npm-called" ]
  [[ "$output" == \
    *"Dry run: 1 installed AI CLI is eligible for reviewed updater execution."* ]]
  [[ "$output" != *"would be updated"* ]]

  run run_zsh 'ai-update-claude'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/claude-updated" ]

  run run_zsh 'ai-update-claude --yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/claude-updated")" = "update" ]
  [ ! -e "$HOME/npm-called" ]
  [[ "$output" == *"1.2.3 -> 1.2.4"* ]]
}

@test "ai safety: Cursor authentication failure is classified without replaying vendor output" {
  cat <<'EOF' > "$TEST_MOCK_BIN/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/cursor-argv"
case "$1" in
  --version)
    printf '%s\n' "cursor-agent 1.0.0"
    exit 0
    ;;
  update)
    if IFS= read -r vendor_input; then
      printf '%s\n' "$vendor_input" > "$HOME/cursor-updater-stdin"
    fi
    printf '%s\n' \
      '[unauthenticated] token=vendor-secret-value' >&2
    exit 1
    ;;
  *)
    exit 97
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/cursor-agent"
  printf '%s\n' "must-not-reach-updater" > "$HOME/vendor-input"

  run run_zsh 'ai-update-cursor --yes < "$HOME/vendor-input"'
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/cursor-updater-stdin" ]
  [[ "$output" == *"vendor authentication is required"* ]]
  [[ "$output" == *"cursor-agent login"* ]]
  [[ "$output" == *"ai-update-cursor"* ]]
  [[ "$output" != *"vendor-secret-value"* ]]
  [[ "$output" != *"[unauthenticated]"* ]]
  grep -Fxq -- "--version" "$HOME/cursor-argv"
  grep -Fxq -- "update" "$HOME/cursor-argv"
  ! grep -Eq '(^| )(login|install)( |$)' "$HOME/cursor-argv"
}

@test "ai safety: result records are complete and a Cursor failure does not hide Amp" {
  cat <<'EOF' > "$TEST_MOCK_BIN/cursor-agent"
#!/usr/bin/env bash
case "$1" in
  --version)
    printf '%s\n' "cursor-agent 1.0.0"
    exit 0
    ;;
  update)
    printf '%s\n' '[unauthenticated] token=vendor-secret-value' >&2
    exit 1
    ;;
  *) exit 97 ;;
esac
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/amp"
#!/usr/bin/env bash
case "$1" in
  --version)
    [[ -e "$HOME/amp-updated" ]] \
      && printf '%s\n' "amp 2.0.0" \
      || printf '%s\n' "amp 1.0.0"
    exit 0
    ;;
  update)
    printf updated > "$HOME/amp-updated"
    exit 0
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/cursor-agent" "$TEST_MOCK_BIN/amp"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    ai-update --yes --result-tsv \
      > "$HOME/ai-results.tsv" 2> "$HOME/ai-results.stderr"
  '

  [ "$status" -eq 1 ]
  [ -e "$HOME/amp-updated" ]
  [ "$(wc -l < "$HOME/ai-results.tsv")" -eq 8 ]
  awk -F '\t' '
    NF != 6 || $1 != "ai-update-result-v1" { exit 1 }
  ' "$HOME/ai-results.tsv"
  [ "$(cut -f 2 "$HOME/ai-results.tsv")" = \
    $'claude\ncodex\nantigravity\nopencode\ncursor\ncopilot\namp\nhermes' ]
  [ "$(cut -f 2 "$HOME/ai-results.tsv" | sort -u | wc -l)" -eq 8 ]
  grep -Fxq -- \
    $'ai-update-result-v1\tcursor\tCursor Agent\tfailed\tauthentication-required\t1' \
    "$HOME/ai-results.tsv"
  grep -Fxq -- \
    $'ai-update-result-v1\tamp\tAmp CLI\tupdated\tversion-changed\t0' \
    "$HOME/ai-results.tsv"
  grep -Fq -- "AI updater results:" "$HOME/ai-results.stderr"
  local result_block="$TEST_TEMP_DIR/ai-result-block.txt"
  sed -n '/AI updater results:/,/Update summary:/p' \
    "$HOME/ai-results.stderr" > "$result_block"
  [ "$(wc -l < "$result_block")" -eq 10 ]
  local label
  for label in \
    "Claude Code" "Codex CLI" "Antigravity CLI" "OpenCode" \
    "Cursor Agent" "GitHub Copilot CLI" "Amp CLI" "Hermes Agent"; do
    [ "$(grep -Fc -- "$label —" "$result_block")" -eq 1 ]
  done
  grep -Fq -- "Cursor Agent — authentication required" "$result_block"
  grep -Fq -- "Amp CLI — updated" "$result_block"
  ! grep -Fq -- "vendor-secret-value" "$HOME/ai-results.stderr"
  ! grep -Fq -- "vendor-secret-value" "$HOME/ai-results.tsv"
}

@test "ai safety: cancellation does not hide an earlier planning failure" {
  cat <<'EOF' > "$TEST_MOCK_BIN/claude"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { printf '%s\n' "claude 1.0.0"; exit 0; }
exit 97
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/codex"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { printf '%s\n' "codex 1.0.0"; exit 0; }
[[ "$1" == "update" ]] && exit 0
exit 97
EOF
  chmod 775 "$TEST_MOCK_BIN/claude"
  chmod 755 "$TEST_MOCK_BIN/codex"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    _ai_authorize() { return 130; }
    ai-update --result-tsv \
      > "$HOME/cancel-results.tsv" 2> "$HOME/cancel-results.stderr"
  '

  [ "$status" -eq 1 ]
  grep -Fq -- $'claude\tClaude Code\tfailed\texecutable-validation-failed' \
    "$HOME/cancel-results.tsv"
  grep -Fq -- $'codex\tCodex CLI\tnot-run\tcancelled\t0' \
    "$HOME/cancel-results.tsv"
  grep -Fq -- "1 failed, 6 skipped, 1 not run" \
    "$HOME/cancel-results.stderr"
  [ ! -e "$HOME/codex-updated" ]
}

@test "ai safety: authorization refusal is not classified as a partial failure" {
  cat <<'EOF' > "$TEST_MOCK_BIN/codex"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { printf '%s\n' "codex 1.0.0"; exit 0; }
[[ "$1" == "update" ]] && { printf invoked > "$HOME/codex-updated"; exit 0; }
exit 97
EOF
  chmod 755 "$TEST_MOCK_BIN/codex"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    _ai_authorize() { return 1; }
    _timed ai:authorization-refused ai-update --result-tsv \
      > "$HOME/refused-results.tsv" 2> "$HOME/refused-results.stderr"
  '

  [ "$status" -eq 1 ]
  grep -Fq -- $'codex\tCodex CLI\tnot-run\tauthorization-not-granted\t1' \
    "$HOME/refused-results.tsv"
  grep -Fq -- "1 not run" "$HOME/refused-results.stderr"
  grep -Fq -- "ai:authorization-refused failed after" \
    "$HOME/refused-results.stderr"
  ! grep -Fq -- "completed with partial failures" \
    "$HOME/refused-results.stderr"
  [ ! -e "$HOME/codex-updated" ]
}

@test "ai safety: vendor precondition is distinct from a generic updater failure" {
  cat <<'EOF' > "$TEST_MOCK_BIN/opencode"
#!/usr/bin/env bash
case "$1" in
  --version)
    printf '%s\n' "opencode 1.0.0"
    exit 0
    ;;
  upgrade)
    printf '%s\n' \
      '[failed_precondition] token=vendor-secret-value' >&2
    exit 9
    ;;
  *)
    exit 97
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/opencode"

  run run_zsh 'ai-update-opencode --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unmet vendor precondition"* ]]
  [[ "$output" == *"ai-update-opencode"* ]]
  [[ "$output" != *"vendor-secret-value"* ]]
  [[ "$output" != *"[failed_precondition]"* ]]

  cat <<'EOF' > "$TEST_MOCK_BIN/opencode"
#!/usr/bin/env bash
case "$1" in
  --version)
    printf '%s\n' "opencode 1.0.0"
    exit 0
    ;;
  upgrade)
    printf '%s\n' 'unexpected token=other-secret-value' >&2
    exit 23
    ;;
  *)
    exit 97
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/opencode"

  run run_zsh 'ai-update-opencode --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"updater failed with status 23"* ]]
  [[ "$output" != *"vendor authentication is required"* ]]
  [[ "$output" != *"unmet vendor precondition"* ]]
  [[ "$output" != *"other-secret-value"* ]]
}

@test "ai safety: updater identity changes after review fail closed" {
  cat <<'EOF' > "$TEST_MOCK_BIN/codex"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "codex-cli 1.0.0"; exit 0; }
[[ "$1" == "update" ]] && printf invoked > "$HOME/codex-invoked"
EOF
  chmod +x "$TEST_MOCK_BIN/codex"

  run run_zsh '
    _ai_authorize() {
      print -r -- "#!/bin/sh\nexit 0" > "$TEST_MOCK_BIN/codex"
      chmod 755 "$TEST_MOCK_BIN/codex"
      return 0
    }
    ai-update-codex
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/codex-invoked" ]
  [[ "$output" == *"changed after review"* ]]
}

@test "ai safety: Hermes uses its version flag and backup update action" {
  cat <<'EOF' > "$TEST_MOCK_BIN/hermes"
#!/usr/bin/env bash
if [[ "$1" == "--version" && "$#" -eq 1 ]]; then
  [[ -e "$HOME/hermes-updated" ]] \
    && echo "Hermes Agent v0.20.7" || echo "Hermes Agent v0.20.6"
  exit 0
fi
if [[ "$*" == "update --backup --yes" ]]; then
  printf '%s\n' "$*" > "$HOME/hermes-updated"
  exit 0
fi
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/hermes"

  run run_zsh 'ai-update-hermes --yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/hermes-updated")" = "update --backup --yes" ]
  [[ "$output" == *"Hermes Agent v0.20.6 -> Hermes Agent v0.20.7"* ]]
}

@test "ai safety: updater rejects a group-writable executable target" {
  cat <<'EOF' > "$TEST_MOCK_BIN/codex"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && echo "codex-cli 1"
EOF
  chmod 775 "$TEST_MOCK_BIN/codex"

  run run_zsh 'ai-update-codex --dry-run'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not an owner/root-controlled regular file"* ]]
}

@test "ai safety: Homebrew-owned assistants can be left to Homebrew" {
  mkdir -p "$HOME/Homebrew/Cellar/antigravity/1/bin"
  cat <<'EOF' > "$HOME/Homebrew/Cellar/antigravity/1/bin/agy"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "agy 1"; exit 0; }
[[ "$1" == "update" ]] && printf invoked > "$HOME/agy-invoked"
EOF
  chmod +x "$HOME/Homebrew/Cellar/antigravity/1/bin/agy"
  ln -s "$HOME/Homebrew/Cellar/antigravity/1/bin/agy" "$TEST_MOCK_BIN/agy"

  run run_zsh 'ai-update-antigravity --skip-homebrew-managed --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/agy-invoked" ]
  [[ "$output" == *"left to the Homebrew update step"* ]]
}

@test "ai safety: aggregate updater authorizes once and reports partial failure" {
  cat <<'EOF' > "$TEST_MOCK_BIN/claude"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  [[ -e "$HOME/claude-called" ]] && echo "claude 2" || echo "claude 1"
  exit 0
fi
[[ "$1" == "update" ]] && { printf called > "$HOME/claude-called"; exit 0; }
exit 97
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/codex"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "codex 1"; exit 0; }
[[ "$1" == "update" ]] && { printf called > "$HOME/codex-called"; exit 23; }
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/claude" "$TEST_MOCK_BIN/codex"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    typeset -gi authorization_count=0
    _ai_authorize() {
      (( authorization_count += 1 ))
      return 0
    }
    ai-update
    local update_rc=$?
    print -r -- "authorizations:$authorization_count"
    return $update_rc
  '
  [ "$status" -eq 1 ]
  [ -e "$HOME/claude-called" ]
  [ -e "$HOME/codex-called" ]
  [[ "$output" == *"authorizations:1"* ]]
  [[ "$output" == \
    *"1 updated, 0 already current, 1 failed, 6 skipped"* ]]
}

@test "ai safety: update summary separates changed and already-current CLIs" {
  cat <<'EOF' > "$TEST_MOCK_BIN/claude"
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  [[ -e "$HOME/claude-changed" ]] && echo "claude 2" || echo "claude 1"
  exit 0
fi
[[ "$1" == "update" ]] \
  && { printf changed > "$HOME/claude-changed"; exit 0; }
exit 97
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/codex"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "codex 1"; exit 0; }
[[ "$1" == "update" ]] \
  && { printf current > "$HOME/codex-current"; exit 0; }
exit 97
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/opencode"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "opencode 1"; exit 0; }
[[ "$1" == "upgrade" ]] \
  && { printf failed > "$HOME/opencode-failed"; exit 23; }
exit 97
EOF
  chmod +x \
    "$TEST_MOCK_BIN/claude" \
    "$TEST_MOCK_BIN/codex" \
    "$TEST_MOCK_BIN/opencode"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    _ai_authorize() { return 0; }
    ai-update
  '

  [ "$status" -eq 1 ]
  [ -e "$HOME/claude-changed" ]
  [ -e "$HOME/codex-current" ]
  [ -e "$HOME/opencode-failed" ]
  [[ "$output" == *"Claude Code updated: claude 1 -> claude 2"* ]]
  [[ "$output" == *"Codex CLI is already at the latest"* ]]
  [[ "$output" == \
    *"1 updated, 1 already current, 1 failed, 5 skipped"* ]]
}

@test "ai safety: same version with an atomic executable replacement counts updated" {
  cat <<'EOF' > "$TEST_MOCK_BIN/codex"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "codex 1"; exit 0; }
if [[ "$1" == "update" ]]; then
  /usr/bin/mv "$HOME/codex-replacement" "$0" || exit 97
  printf replaced > "$HOME/codex-replaced"
  exit 0
fi
exit 97
EOF
  cat <<'EOF' > "$HOME/codex-replacement"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "codex 1"; exit 0; }
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/codex" "$HOME/codex-replacement"
  local before_inode
  before_inode=$(stat -c '%i' "$TEST_MOCK_BIN/codex")

  run run_zsh 'ai-update-codex --yes'

  [ "$status" -eq 0 ]
  [ -e "$HOME/codex-replaced" ]
  [ "$(stat -c '%i' "$TEST_MOCK_BIN/codex")" != "$before_inode" ]
  [[ "$output" == \
    *"executable changed while reporting the same version (codex 1)"* ]]
  [[ "$output" == \
    *"1 updated, 0 already current, 0 failed, 0 skipped"* ]]
}

@test "ai safety: Amp version probe uses its private cache and correct passive flag" {
  cat <<'EOF' > "$TEST_MOCK_BIN/amp"
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HOME/amp-probe-argv"
[[ "$1" == "--version" && "$#" -eq 1 ]] || exit 97
case "${XDG_CACHE_HOME:-}" in
  "$TMPDIR"/zdx-ai-probe.*/cache) ;;
  *) exit 41 ;;
esac
printf '%s\n' "$XDG_CACHE_HOME" > "$HOME/amp-probe-cache"
mkdir -p "$XDG_CACHE_HOME/amp/logs"
dd if=/dev/zero of="$XDG_CACHE_HOME/native-module.bin" \
  bs=1024 count=256 status=none || exit 42
printf '%s\n' "amp 9.8.7"
EOF
  chmod +x "$TEST_MOCK_BIN/amp"

  run run_zsh '_ai_probe_cli amp'
  [ "$status" -eq 0 ]
  [ "$output" = "amp 9.8.7" ]
  [ "$(cat "$HOME/amp-probe-argv")" = "--version" ]
  local private_cache
  private_cache=$(cat "$HOME/amp-probe-cache")
  [[ "$private_cache" == "$TMPDIR"/zdx-ai-probe.*/cache ]]
  [ ! -e "$private_cache" ]
  [ ! -e "$HOME/.cache/amp" ]
  [ -z "$(find "$TMPDIR" -maxdepth 1 \
    -type d -name 'zdx-ai-probe.*' -print)" ]
}

@test "ai safety: versions distinguish successful, failed, and absent probes" {
  cat <<'EOF' > "$TEST_MOCK_BIN/agy"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "agy 2.0.0"; exit 0; }
exit 97
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/codex"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && exit 9
exit 97
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/cursor-agent"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && exit 9
exit 97
EOF
  chmod +x \
    "$TEST_MOCK_BIN/agy" \
    "$TEST_MOCK_BIN/codex" \
    "$TEST_MOCK_BIN/cursor-agent"

  run run_zsh 'ai-versions --json'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.antigravity.version' <<< "$output")" = "agy 2.0.0" ]
  [ "$(jq -r '.codex.installed' <<< "$output")" = "true" ]
  [ "$(jq -r '.codex.probeStatus' <<< "$output")" = "failed" ]
  [ "$(jq -r '.cursor.installed' <<< "$output")" = "true" ]
  [ "$(jq -r '.cursor.probeStatus' <<< "$output")" = "failed" ]
  [ "$(jq -r 'has("gemini")' <<< "$output")" = "false" ]

  run run_zsh 'NO_COLOR=1 ai-versions'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cursor Agent       (version unavailable)"* ]]
  [[ "$output" != *"Cursor Agent       (not installed)"* ]]
}

@test "ai safety: versions report a shell-only wrapper without executing it" {
  ln -s "$(command -v jq)" "$TEST_MOCK_BIN/jq"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    codex() {
      print executed > "$HOME/wrapper-executed"
    }
    ai-versions --json
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/wrapper-executed" ]
  [ "$(jq -r '.codex.installed' <<< "$output")" = "false" ]
  [ "$(jq -r '.codex.available' <<< "$output")" = "true" ]
  [ "$(jq -r '.codex.state' <<< "$output")" = "wrapper-only" ]
}

@test "ai safety: lazy NVM Codex uses only the exact safe default alias" {
  local nvm_root="$HOME/.nvm"
  local default_root="$nvm_root/versions/node/v24.18.0"
  local decoy_root="$nvm_root/versions/node/v26.4.0"
  mkdir -p \
    "$nvm_root/alias" \
    "$default_root/bin" \
    "$default_root/lib/node_modules/@openai/codex/bin" \
    "$decoy_root/bin"
  printf 'v24.18.0\n' > "$nvm_root/alias/default"
  cat <<'EOF' > "$default_root/bin/node"
#!/usr/bin/env bash
script="$1"
shift
exec /usr/bin/bash "$script" "$@"
EOF
  cat <<'EOF' > "$default_root/lib/node_modules/@openai/codex/bin/codex.js"
#!/usr/bin/env node
case "${1:-}" in
  --version)
    printf '%s\n' "codex-cli 24.18.0"
    ;;
  update)
    printf invoked > "$HOME/codex-updated"
    ;;
  *)
    exit 97
    ;;
esac
EOF
  ln -s \
    "../lib/node_modules/@openai/codex/bin/codex.js" \
    "$default_root/bin/codex"
  cat <<'EOF' > "$decoy_root/bin/codex"
#!/usr/bin/env bash
printf invoked > "$HOME/decoy-invoked"
exit 97
EOF
  chmod +x \
    "$default_root/bin/node" \
    "$default_root/lib/node_modules/@openai/codex/bin/codex.js" \
    "$decoy_root/bin/codex"

  run run_zsh '
    NVM_DIR="$HOME/.nvm"
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    hash codex="$HOME/stale-codex"
    _load_nvm() {
      print -r -- invoked > "$HOME/lazy-wrapper-invoked"
      return 97
    }
    alias codex="_load_nvm && unalias codex && codex"

    _ai_resolve_cli codex || return 1
    [[ "$REPLY" \
      == "$HOME/.nvm/versions/node/v24.18.0/bin/codex" ]] || return 2
    [[ "$_AI_RESOLVED_PATH_PREFIX" \
      == "$HOME/.nvm/versions/node/v24.18.0/bin" ]] || return 3
    [[ "$_AI_RESOLVED_NODE" \
      == "$HOME/.nvm/versions/node/v24.18.0/bin/node" ]] || return 4
    [[ "$(_ai_probe_cli codex)" == "codex-cli 24.18.0" ]] || return 5
    ai-update-codex --yes || return 6
    [[ -e "$HOME/codex-updated" ]] || return 7
    command mv -- "$HOME/codex-updated" "$HOME/codex-first-update"

    _ai_authorize() {
      printf "#!/usr/bin/env bash\nexit 0\n" \
        > "$HOME/.nvm/versions/node/v24.18.0/bin/node"
      chmod 755 "$HOME/.nvm/versions/node/v24.18.0/bin/node"
      return 0
    }
    ai-update-codex && return 8
    [[ ! -e "$HOME/codex-updated" ]] || return 9

    print -r -- "lts/*" > "$HOME/.nvm/alias/default"
    _ai_resolve_cli codex && return 10
    local ignored=""
    ignored=$(_ai_probe_cli codex)
    (( $? == 2 )) || return 11
    [[ -z "$ignored" ]]
  '
  [ "$status" -eq 0 ]
  [ -e "$HOME/codex-first-update" ]
  [ ! -e "$HOME/lazy-wrapper-invoked" ]
  [ ! -e "$HOME/decoy-invoked" ]
  [[ "$output" == *"changed after review"* ]]
}

@test "ai safety: Antigravity MCP scopes hide server URLs" {
  mkdir -p "$HOME/.gemini/config" "$HOME/project/.agents"
  cat <<'EOF' > "$HOME/.gemini/config/mcp_config.json"
{"mcpServers":{"global":{"serverUrl":"https://secret.example.invalid/global"}}}
EOF
  cat <<'EOF' > "$HOME/project/.agents/mcp_config.json"
{"mcpServers":{"workspace":{"serverUrl":"https://secret.example.invalid/workspace"}}}
EOF
  chmod 600 \
    "$HOME/.gemini/config/mcp_config.json" \
    "$HOME/project/.agents/mcp_config.json"

  run run_zsh 'cd "$HOME/project" && ai-mcp-doctor'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Antigravity CLI"* ]]
  [[ "$output" == *"remote serverUrl declared (not contacted)"* ]]
  [[ "$output" != *"secret.example.invalid"* ]]
}

@test "ai safety: project initialization creates no legacy instruction link" {
  mkdir -p "$HOME/project"
  run run_zsh 'cd "$HOME/project" && ai-init-agents --minimal --yes'
  [ "$status" -eq 0 ]
  [ -f "$HOME/project/AGENTS.md" ]
  [ "$(readlink "$HOME/project/CLAUDE.md")" = "AGENTS.md" ]
  [ ! -e "$HOME/project/GEMINI.md" ]
}

@test "ai safety: MCP audit reads current scopes without execution or URL disclosure" {
  cat <<'EOF' > "$TEST_MOCK_BIN/mcp-local"
#!/usr/bin/env bash
printf executed > "$HOME/mcp-executed"
EOF
  chmod +x "$TEST_MOCK_BIN/mcp-local"
  cat <<EOF > "$HOME/.claude.json"
{"mcpServers":{"local":{"command":"mcp-local"},"remote":{"type":"http","url":"https://secret.example.invalid/mcp","headers":{"Authorization":"Bearer secret"}}}}
EOF
  mkdir -p "$HOME/project"
  cat <<'EOF' > "$HOME/project/.mcp.json"
{"mcpServers":{"shared":{"command":"mcp-local"}}}
EOF
  chmod 600 "$HOME/.claude.json" "$HOME/project/.mcp.json"

  run run_zsh 'cd "$HOME/project" && ai-mcp-doctor'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/mcp-executed" ]
  [[ "$output" == *"remote http declared (not contacted)"* ]]
  [[ "$output" == *"Shared project"* ]]
  [[ "$output" != *"secret.example.invalid"* ]]
  [[ "$output" != *"Bearer secret"* ]]
}

@test "ai safety: config snapshot restores with an atomic rollback link" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{"theme":"before"}' > "$HOME/.claude/settings.json"
  chmod 600 "$HOME/.claude/settings.json"
  run run_zsh 'ai-config-backup --yes'
  [ "$status" -eq 0 ]

  local snapshot
  snapshot=$(find "$HOME/.ai-suite-backups" -mindepth 1 -maxdepth 1 \
    -type d -printf '%f\n')
  [ -n "$snapshot" ]
  printf '%s\n' '{"theme":"after"}' > "$HOME/.claude/settings.json"
  run run_zsh "ai-config-restore $snapshot --yes"
  [ "$status" -eq 0 ]
  grep -q '"before"' "$HOME/.claude/settings.json"
  grep -q '"after"' "$HOME/.claude/settings.json.bak.$snapshot"
}

@test "ai safety: existing-file restore does not require GNU mv -T" {
  cat <<'EOF' > "$TEST_MOCK_BIN/mv"
#!/usr/bin/env bash
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/mv"

  mkdir -p "$HOME/.claude"
  printf '%s\n' '{"theme":"before"}' > "$HOME/.claude/settings.json"
  chmod 600 "$HOME/.claude/settings.json"
  run run_zsh 'ai-config-backup --yes'
  [ "$status" -eq 0 ]

  local snapshot
  snapshot=$(find "$HOME/.ai-suite-backups" -mindepth 1 -maxdepth 1 \
    -type d -printf '%f\n')
  [ -n "$snapshot" ]
  printf '%s\n' '{"theme":"after"}' > "$HOME/.claude/settings.json"
  run run_zsh "ai-config-restore $snapshot --yes"
  [ "$status" -eq 0 ]
  grep -q '"before"' "$HOME/.claude/settings.json"
  grep -q '"after"' "$HOME/.claude/settings.json.bak.$snapshot"
}

@test "ai safety: fallback replacement refuses a directory destination" {
  cat <<'EOF' > "$TEST_MOCK_BIN/mv"
#!/usr/bin/env bash
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/mv"

  run run_zsh '
    source "$ZSH_CUSTOM/functions/ai-menu.zsh" || exit 98
    print -r -- staged-content > "$HOME/staged"
    mkdir -p "$HOME/dirdst"
    if _ai_config_replace_file "$HOME/staged" "$HOME/dirdst"; then
      exit 9
    fi
    [[ -f "$HOME/staged" && -d "$HOME/dirdst" ]] || exit 8
    [[ ! -e "$HOME/dirdst/staged" ]] || exit 7
  '
  [ "$status" -eq 0 ]
}

@test "ai safety: log redaction fails closed for common secret indicators" {
  run run_zsh '
    for line in \
      "{\"api_key\":\"supersecretvalue\"}" \
      "password=hunter2" \
      "AWS_ACCESS_KEY_ID=AKIAEXAMPLE" \
      "-----BEGIN PRIVATE KEY-----"; do
      _ai_log_redact "$line"
      print -r -- "$REPLY"
    done
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'[REDACTED_SENSITIVE_LINE]\n[REDACTED_SENSITIVE_LINE]\n[REDACTED_SENSITIVE_LINE]\n[REDACTED_SENSITIVE_LINE]' ]
  [[ "$output" != *"supersecretvalue"* ]]
  [[ "$output" != *"hunter2"* ]]
}

@test "ai safety: a byte-window partial line is discarded before redaction" {
  mkdir -p "$HOME/.codex/log"
  awk 'BEGIN {
    secret = "password=HUNTERTWO987654321XYZ"
    total = 262156
    printf "%s", secret
    for (i = length(secret); i < total - 6; i++) printf "A"
    printf "\nSAFE\n"
  }' > "$HOME/.codex/log/recent.log"

  run run_zsh 'ai-log-tail --lines 5'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SAFE"* ]]
  [[ "$output" != *"HUNTERTWO"* ]]
  [[ "$output" != *"NTERTWO"* ]]
}

@test "ai safety: unrelated files do not consume the eligible log cap" {
  mkdir -p "$HOME/.codex/log"
  local index
  for index in $(seq 1 513); do
    printf x > "$HOME/.codex/log/unrelated-$index.txt"
  done
  printf 'ELIGIBLE\n' > "$HOME/.codex/log/recent.log"

  run run_zsh 'ai-log-tail --lines 5'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ELIGIBLE"* ]]
  [[ "$output" != *"exceeds 512"* ]]
}

@test "ai safety: bounded find diagnostics are never exposed verbatim" {
  mkdir -p "$HOME/.codex/log"
  cat <<'EOF' > "$TEST_MOCK_BIN/find"
#!/usr/bin/env bash
printf '%s\n' 'HOSTILE_FIND_ERROR password=raw-secret' >&2
exit 71
EOF
  chmod +x "$TEST_MOCK_BIN/find"

  run run_zsh 'ai-log-tail --lines 5'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not complete the bounded log inventory"* ]]
  [[ "$output" != *"HOSTILE_FIND_ERROR"* ]]
  [[ "$output" != *"raw-secret"* ]]
}

@test "ai safety: linked Claude config is ignored" {
  printf '%s\n' '{"mcpServers":{"bad":{"command":"mcp-local"}}}' \
    > "$HOME/real-claude.json"
  ln -s "$HOME/real-claude.json" "$HOME/.claude.json"
  run run_zsh 'ai-mcp-list'
  [ "$status" -eq 0 ]
  [[ "$output" != *"mcp-local"* ]]
  [[ "$output" == *"No safe Claude MCP config file found"* ]]
}

@test "ai contract: every parser help includes public syntax" {
  local command_name
  for command_name in \
    global-clean-claude project-sweep-ai ai-config-backup ai-config-restore \
    ai-doctor ai-disk-usage ai-versions ai-init-agents ai-log-tail \
    ai-mcp-list ai-mcp-update ai-update-claude; do
    run run_zsh "$command_name --help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: $command_name"* ]]
  done
  run run_zsh 'ai-init-agents --help'
  [[ "$output" == *"--minimal"* && "$output" == *"--dry-run"* ]]
  run run_zsh 'ai-log-tail --help'
  [[ "$output" == *"--lines N"* ]]
  run run_zsh 'ai-config-restore --help'
  [[ "$output" == *"[SNAPSHOT]"* ]]
}

@test "ai safety: module parsers honor the option terminator" {
  mkdir -p "$HOME/project"
  run run_zsh 'cd "$HOME/project" && ai-init-agents --dry-run --'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/project/AGENTS.md" ]
  run run_zsh 'cd "$HOME/project" && ai-init-agents --dry-run -- extra'
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/project/AGENTS.md" ]
  run run_zsh 'ai-log-tail --lines 5 --'
  [ "$status" -eq 0 ]
  run run_zsh 'ai-log-tail -- extra'
  [ "$status" -eq 2 ]
}

@test "ai safety: restore without a token selects from the private snapshot picker" {
  mkdir -p "$HOME/.claude"
  printf '%s\n' '{"theme":"before"}' > "$HOME/.claude/settings.json"
  chmod 600 "$HOME/.claude/settings.json"
  run run_zsh 'ai-config-backup --yes'
  [ "$status" -eq 0 ]
  local snapshot
  snapshot=$(find "$HOME/.ai-suite-backups" -mindepth 1 -maxdepth 1 \
    -type d -printf '%f\n')
  [ -n "$snapshot" ]
  printf '%s\n' '{"theme":"after"}' > "$HOME/.claude/settings.json"

  export MOCK_FZF_MODE="cancel" MOCK_FZF_STATUS="130"
  run run_zsh 'ai-config-restore --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled."* ]]
  grep -q '"after"' "$HOME/.claude/settings.json"
  [ ! -e "$HOME/.claude/settings.json.bak.$snapshot" ]
  grep -Fq -- "|$snapshot|" "$MOCK_FZF_INPUT_FILE"
  grep -Fq -- "(1 file)" "$MOCK_FZF_INPUT_FILE"
  grep -Fq -- 'ai\ snapshots' "$MOCK_FZF_ARGS_FILE"

  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="forged  (1 file)|$snapshot|forged description"
  run run_zsh 'ai-config-restore --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the picker inventory"* ]]
  grep -q '"after"' "$HOME/.claude/settings.json"

  export MOCK_FZF_MODE="match" MOCK_FZF_MATCH="|$snapshot|"
  run run_zsh 'ai-config-restore --yes'
  [ "$status" -eq 0 ]
  grep -q '"before"' "$HOME/.claude/settings.json"
  grep -q '"after"' "$HOME/.claude/settings.json.bak.$snapshot"
}

@test "ai safety: restore without a token fails closed without snapshots or a picker" {
  run run_zsh 'ai-config-restore --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"No restorable snapshot"* ]]
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]

  local root="$HOME/.ai-suite-backups"
  mkdir -p "$root/20260101T010101-1" "$root/20260102T020202-2"
  chmod 700 "$root" "$root/20260101T010101-1" "$root/20260102T020202-2"
  run run_zsh '
    command() {
      [[ "$1" == "-v" && "$2" == "fzf" ]] && return 1
      builtin command "$@"
    }
    ai-config-restore --yes
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"A snapshot token is required."* ]]
  [[ "$output" == *"20260102T020202-2"* ]]
  [[ "$output" == *"20260101T010101-1"* ]]
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]

  chmod 750 "$root"
  run run_zsh 'ai-config-restore --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a private owned directory"* ]]
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]
}

@test "ai safety: version records use one documented shape per assistant" {
  ln -s "$(command -v jq)" "$TEST_MOCK_BIN/jq"
  cat <<'EOF' > "$TEST_MOCK_BIN/copilot"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "copilot 1.0.0"; exit 0; }
exit 97
EOF
  cat <<'EOF' > "$TEST_MOCK_BIN/hermes"
#!/usr/bin/env bash
[[ "$1" == "version" ]] && exit 9
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/copilot" "$TEST_MOCK_BIN/hermes"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    amp() { print executed > "$HOME/amp-wrapper-executed"; }
    ai-versions --json
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/amp-wrapper-executed" ]
  [ "$(jq -r 'keys | join(",")' <<< "$output")" = \
    "amp,antigravity,claude,codex,copilot,cursor,hermes,opencode,runtime" ]
  [ "$(jq -r '.copilot.installed' <<< "$output")" = "true" ]
  [ "$(jq -r '.copilot.version' <<< "$output")" = "copilot 1.0.0" ]
  [ "$(jq -r '.copilot.binary' <<< "$output")" = "$TEST_MOCK_BIN/copilot" ]
  [ "$(jq -r '.hermes.probeStatus' <<< "$output")" = "failed" ]
  [ "$(jq -r '.hermes.version' <<< "$output")" = "unavailable" ]
  [ "$(jq -r '.amp.state' <<< "$output")" = "wrapper-only" ]
  [ "$(jq -r '.claude.installed' <<< "$output")" = "false" ]
  jq -e '
    [to_entries[] | select(.key != "runtime") | .value | keys | join(",")]
    | all(
      . == "binary,installed,label,version"
      or . == "binary,installed,label,probeStatus,version"
      or . == "available,installed,label,state"
      or . == "installed,label")
  ' <<< "$output" >/dev/null

  run run_zsh 'PATH="$TEST_MOCK_BIN:/usr/bin:/bin"; NO_COLOR=1 ai-versions'
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub Copilot     copilot 1.0.0"* ]]
  [[ "$output" == *"Hermes Agent       (version unavailable)"* ]]
  [[ "$output" == *"Claude Code        (not installed)"* ]]
}

@test "ai safety: doctor reports a wrapper-only assistant without executing it" {
  cat <<'EOF' > "$TEST_MOCK_BIN/codex"
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "codex-cli 1.0.0"; exit 0; }
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/codex"

  run run_zsh '
    PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
    claude() { print executed > "$HOME/claude-wrapper-executed"; }
    cd "$HOME" && NO_COLOR=1 ai-doctor --report
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/claude-wrapper-executed" ]
  [[ "$output" == *"── Claude Code ──"* ]]
  [[ "$output" == *"Available, but the bounded version probe failed."* ]]
  [[ "$output" == *"Installed: codex-cli 1.0.0"* ]]
  [[ "$output" == *"issue(s) found"* ]]

  local report
  report=$(find "$HOME/ai-suite-reports" -type f -name '*-ai-doctor.md')
  [ -n "$report" ]
  [ "$(stat -c '%a' "$report")" = "600" ]
  grep -Fq -- "## Claude Code" "$report"
  grep -Fq -- "- FAILED: Available, but the bounded version probe failed." \
    "$report"
  grep -Fq -- "## OpenAI Codex" "$report"
  grep -Fq -- "- OK: Installed: codex-cli 1.0.0" "$report"
  grep -Fq -- "- INFO: Binary: $TEST_MOCK_BIN/codex" "$report"
  grep -Fq -- "## Hermes Agent" "$report"
  grep -Fq -- "## API Keys" "$report"
}

@test "ai safety: OpenCode roots honor an absolute XDG_DATA_HOME consistently" {
  mkdir -p "$HOME/xdg-data/opencode/logs"
  printf 'OPENCODE-LINE\n' > "$HOME/xdg-data/opencode/logs/app.log"

  run run_zsh 'export XDG_DATA_HOME="$HOME/xdg-data"; global-clean-opencode --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/xdg-data/opencode/logs"* ]]
  [ -f "$HOME/xdg-data/opencode/logs/app.log" ]

  run run_zsh 'export XDG_DATA_HOME="$HOME/xdg-data"; ai-log-tail --lines 5'
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPENCODE-LINE"* ]]

  run run_zsh 'export XDG_DATA_HOME="$HOME/xdg-data"; NO_COLOR=1 ai-disk-usage'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/xdg-data/opencode"* ]]

  run run_zsh 'export XDG_DATA_HOME="relative/override"; global-clean-opencode --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" != *"relative/override"* ]]
}
