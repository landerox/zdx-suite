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

@test "dev: dev-run-eslint uses npx when eslint is not installed locally" {
  : > "$DEV_PROJECT/package.json"

  cat > "$TEST_MOCK_BIN/npx" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *eslint* ]]; then
  echo "mock eslint run"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/npx"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_ALLOW_EPHEMERAL=1
    dev-run-eslint
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"mock eslint run"* ]]
  [[ "$output" == *"ESLint: no issues found."* ]]
}

@test "dev: dev-run-prettier verifies formatting without rewriting" {
  : > "$DEV_PROJECT/package.json"

  cat > "$TEST_MOCK_BIN/npx" <<'EOF'
#!/usr/bin/env bash
echo "prettier args: $*"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/npx"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_ALLOW_EPHEMERAL=1
    dev-run-prettier
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"--check"* ]]
  [[ "$output" != *"--write"* ]]
  [[ "$output" == *"Prettier: all files match the configured style."* ]]
}

@test "dev: dev-run-clippy detects Cargo.toml and runs clippy" {
  : > "$DEV_PROJECT/Cargo.toml"

  cat > "$TEST_MOCK_BIN/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *clippy* ]]; then
  echo "mock clippy run"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/cargo"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-clippy'

  [ "$status" -eq 0 ]
  [[ "$output" == *"mock clippy run"* ]]
  [[ "$output" == *"Clippy: no warnings or errors found."* ]]
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
  [[ "$output" == *"Analyzing 1 shell file(s) with ShellCheck..."* ]]
  [[ "$output" == *"Parsing 1 Zsh file(s) with zsh -n..."* ]]
  [[ "$output" == *"ShellCheck: no issues found."* ]]
}

@test "dev: dev-run-all-checks runs polyglot gates and prints a result table" {
  : > "$DEV_PROJECT/package.json"
  : > "$DEV_PROJECT/Cargo.toml"
  : > "$DEV_PROJECT/script.sh"

  local tool
  for tool in npx cargo shellcheck; do
    cat > "$TEST_MOCK_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_MOCK_BIN/$tool"
  done

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_ALLOW_EPHEMERAL=1
    dev-run-all-checks
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"ESLint"* ]]
  [[ "$output" == *"Prettier"* ]]
  [[ "$output" == *"Cargo Clippy"* ]]
  [[ "$output" == *"ShellCheck"* ]]
  [[ "$output" == *"Check Results"* ]]
  [[ "$output" == *"passed"* ]]
}

@test "dev: a project with no applicable gate reports a clean no-op" {
  run run_zsh 'cd "$DEV_PROJECT" && dev-run-all-checks'

  [ "$status" -eq 0 ]
  [[ "$output" == *"No applicable checks for this project."* ]]
}

# --- Deprecated compatibility surface ---------------------------------------

@test "dev: a deprecated alias still runs and warns exactly once per session" {
  : > "$DEV_PROJECT/Cargo.toml"

  cat > "$TEST_MOCK_BIN/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/cargo"

  run run_zsh '
    cd "$DEV_PROJECT"
    run-clippy >/dev/null
    run-clippy >/dev/null
  '

  [ "$status" -eq 0 ]
  [ "$(grep -c "run-clippy. is deprecated" <<< "$output")" -eq 1 ]
  [[ "$output" == *"use 'dev-run-clippy' instead"* ]]
}

@test "dev: Docker cleanup tokens delegate to the owning suite" {
  run run_zsh '
    docker-menu() { print -r -- "docker-menu called with: $*"; return 0; }
    clean-docker
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"owned by docker-menu"* ]]
  [[ "$output" == *"docker-menu called with: docker-clean"* ]]
}

@test "dev: venv tokens delegate to the py suite" {
  run run_zsh '
    py-menu() { print -r -- "py-menu called with: $*"; return 0; }
    _dev_verify_deps() { return 0; }
    dev-menu venv-list
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"py-menu called with: venv-list"* ]]
}
