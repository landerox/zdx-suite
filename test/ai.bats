#!/usr/bin/env bats

setup() {
  load test_helper
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 "$TMPDIR"

  # Set up mock configuration folder
  mkdir -p "$HOME/.claude"
  echo '{"mcpServers": {}}' > "$HOME/.claude.json"

  # Create mock claude binary
  cat <<'EOF' > "$TEST_MOCK_BIN/claude"
#!/usr/bin/env bash
if [[ "$*" == *"mcp list"* ]]; then
  echo "No MCP servers configured"
  exit 0
elif [[ "$*" == *"--version"* ]]; then
  echo "claude version 0.1.0-mock"
  exit 0
fi
echo "mock claude: unknown args: $*" >&2
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/claude"
}

teardown() {
  cleanup_sandbox
}

@test "ai: ai-menu.zsh and ai-common.zsh source cleanly" {
  run run_zsh "echo SOURCED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED"* ]]
}

@test "ai: ai-menu --help prints Usage block" {
  run run_zsh "ai-menu --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"ai-menu"* ]]
  [[ "$output" == *"global-clean-ai"* ]]
}

@test "ai: _ai_dispatch rejects unknown command as usage status 2" {
  run run_zsh "_ai_dispatch invalid-command"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command: invalid-command"* ]]
}

@test "ai: ai-doctor runs diagnostics successfully and detects mock claude" {
  run run_zsh "ai-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AI CLI Diagnostics"* ]]
  [[ "$output" == *"claude version 0.1.0-mock"* ]]
}

@test "ai: ai-mcp-list lists mcp servers successfully" {
  run run_zsh "ai-mcp-list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MCP Declarations"* ]]
  [[ "$output" == *"No MCP servers declared"* ]]
}
