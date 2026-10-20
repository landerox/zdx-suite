#!/usr/bin/env bats

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  mkdir -p "$DEV_PROJECT"
}

teardown() {
  cleanup_sandbox
}

@test "dev: dev-menu.zsh and dev-common.zsh source cleanly" {
  run run_zsh "typeset -f dev-menu >/dev/null && print -r -- SOURCED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED"* ]]
}

@test "dev: dev-menu --help prints a usage block" {
  run run_zsh "dev-menu --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"dev-menu"* ]]
}

# --- Polyglot quality gates -------------------------------------------------

@test "dev: dev-run-markdownlint uses npx when markdownlint is not installed locally" {
  : > "$DEV_PROJECT/README.md"

  cat > "$TEST_MOCK_BIN/npx" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *markdownlint-cli* ]]; then
  echo "mock markdownlint run: $*"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/npx"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_ALLOW_EPHEMERAL=1
    command() {
      if [[ "$1" == "-v" && "$2" == "markdownlint" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    dev-run-markdownlint
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"through npx: this downloads remote code"* ]]
  [[ "$output" == *"mock markdownlint run: --yes markdownlint-cli ./README.md"* ]]
  [[ "$output" == *"Markdownlint passed."* ]]
}

@test "dev: dev-run-shellcheck analyzes shell files and parses Zsh files" {
  : > "$DEV_PROJECT/script.sh"
  printf 'print -r -- ok\n' > "$DEV_PROJECT/script.zsh"

  cat > "$TEST_MOCK_BIN/shellcheck" <<'EOF'
#!/usr/bin/env bash
echo "mock shellcheck run"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/shellcheck"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-shellcheck'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Analyzing 1 shell file with ShellCheck..."* ]]
  [[ "$output" == *"Parsing 1 Zsh file with zsh -n..."* ]]
  [[ "$output" == *"ShellCheck: no issues found."* ]]
}

@test "dev: dev-run-all-checks runs polyglot gates and prints a result table" {
  : > "$DEV_PROJECT/README.md"
  : > "$DEV_PROJECT/script.sh"

  local tool
  for tool in npx shellcheck; do
    cat > "$TEST_MOCK_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_MOCK_BIN/$tool"
  done

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_ALLOW_EPHEMERAL=1
    command() {
      if [[ "$1" == "-v" && "$2" == "markdownlint" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    dev-run-all-checks
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"ShellCheck"* ]]
  [[ "$output" == *"Markdownlint"* ]]
  [[ "$output" == *"Check Results"* ]]
  [[ "$output" == *"All 2 checks passed."* ]]
}

@test "dev: a project with no applicable gate reports a clean no-op" {
  run run_zsh 'cd "$DEV_PROJECT" && dev-run-all-checks'

  [ "$status" -eq 0 ]
  [[ "$output" == *"No applicable checks for this project."* ]]
}
