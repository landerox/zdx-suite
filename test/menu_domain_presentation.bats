#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_FZF_ARGS_FILE"
cat > "$MOCK_FZF_INPUT_FILE"
exit 130
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
}

teardown() { cleanup_sandbox; }

@test "menu presentation: Python multi help matches its existing read-only bindings" {
  run run_zsh 'py-menu --multi >"$HOME/stdout"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fxq -- '--bind=ctrl-/:toggle-preview' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- '--bind=ctrl-a:select-all,ctrl-d:deselect-all' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq 'Tab mark | Ctrl-A all | Ctrl-D none | Read-only tasks only' "$MOCK_FZF_ARGS_FILE"
  [ "$(cut -d '|' -f 2 "$MOCK_FZF_INPUT_FILE" | LC_ALL=C sort)" = $'tool-list\nvenv-list\nvenv-python-list' ]
}

@test "menu presentation: AI multi help does not advertise unbound selection shortcuts" {
  run run_zsh 'ai-menu --multi >"$HOME/stdout"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fxq -- '--bind=ctrl-/:toggle-preview' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq 'Tab mark | Read-only tasks only' "$MOCK_FZF_ARGS_FILE"
  ! grep -Eq 'Ctrl-A|Ctrl-D|select-all|deselect-all' "$MOCK_FZF_ARGS_FILE" || return 1
  [ "$(cut -d '|' -f 2 "$MOCK_FZF_INPUT_FILE" | LC_ALL=C sort)" = $'ai-disk-usage\nai-doctor\nai-log-tail\nai-mcp-doctor\nai-mcp-list\nai-versions' ]
}

@test "menu presentation: telemetry actions have details without changing compact selection" {
  run run_zsh 'sys-telemetry >"$HOME/stdout"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fxq -- '--height=50%' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- '--bind=ctrl-/:toggle-preview' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- '--prompt=sys telemetry > ' "$MOCK_FZF_ARGS_FILE"
  grep -Fq 'Type to filter | Enter run | Esc cancel | Ctrl-/ details' "$MOCK_FZF_ARGS_FILE"
  grep -Fq 'case {2} in :)' "$MOCK_FZF_ARGS_FILE"
  [ "$(cut -d '|' -f 2 "$MOCK_FZF_INPUT_FILE" | LC_ALL=C sort)" = $'--browse\n--clear\n--dashboard\n:' ]
}

@test "menu presentation: VPN advertises details only when its private preview exists" {
  run run_zsh 'vpn-menu >"$HOME/stdout"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fxq -- '--bind=ctrl-/:toggle-preview' "$MOCK_FZF_ARGS_FILE"
  grep -Fq 'Type to filter | Enter run | Esc cancel | Ctrl-/ details' "$MOCK_FZF_ARGS_FILE"
  grep -Fq '/{n}' "$MOCK_FZF_ARGS_FILE"
  grep -Fxq -- '--preview-window=right:50%:wrap,<120(down:10:wrap)' "$MOCK_FZF_ARGS_FILE"
  awk -F '|' 'NF != 4 { exit 1 }' "$MOCK_FZF_INPUT_FILE"

  run run_zsh '
    source "$ZSH_CUSTOM/functions/vpn-menu.zsh"
    _vpn_preview_build() { return 1; }
    vpn-menu >"$HOME/stdout"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  grep -Fxq -- '--preview-window=hidden' "$MOCK_FZF_ARGS_FILE"
  grep -Fq 'Type to filter | Enter run | Esc cancel' "$MOCK_FZF_ARGS_FILE"
  ! grep -Eq 'toggle-preview|Ctrl-/' "$MOCK_FZF_ARGS_FILE" || return 1
}
