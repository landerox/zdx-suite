#!/usr/bin/env bats

setup() {
  load test_helper

  # Create a custom mock git in TEST_MOCK_BIN
  cat <<'EOF' > "$TEST_MOCK_BIN/git"
#!/usr/bin/env bash
if [[ "$1" == "clone" ]]; then
  if [[ "$MOCK_GIT_CLONE_FAIL" == "1" ]]; then
    echo "mock git clone: fatal: repository not found" >&2
    exit 1
  fi

  target_dir="${@: -1}"
  plugin_name=$(basename "$target_dir")

  mkdir -p "$target_dir"
  mkdir -p "$target_dir/.git"

  if [[ "$MOCK_GIT_CLONE_CONTRACT_NO_FILE" == "1" ]]; then
    exit 0
  elif [[ "$MOCK_GIT_CLONE_CONTRACT_SYNTAX_ERROR" == "1" ]]; then
    cat <<INNER_EOF > "$target_dir/${plugin_name}-menu.zsh"
# syntax error
${plugin_name}-menu() {
  echo "broken
}
INNER_EOF
    exit 0
  elif [[ "$MOCK_GIT_CLONE_CONTRACT_NO_FUNC" == "1" ]]; then
    cat <<INNER_EOF > "$target_dir/${plugin_name}-menu.zsh"
# No function defined
echo "hello"
INNER_EOF
    exit 0
  else
    # Default valid plugin
    cat <<INNER_EOF > "$target_dir/${plugin_name}-menu.zsh"
${plugin_name}-menu() {
  echo "Hello from mock plugin ${plugin_name}!"
}
INNER_EOF
    exit 0
  fi
fi

if [[ "$1" == "-C" && "$3" == "remote" && "$4" == "get-url" ]]; then
  echo "https://github.com/example/$(basename "$2").git"
  exit 0
fi

if [[ "$1" == "-C" && "$3" == "pull" ]]; then
  if [[ "$MOCK_GIT_PULL_FAIL" == "1" ]]; then
    echo "mock git pull: fatal: connection timed out" >&2
    exit 1
  fi

  target_dir="$2"
  plugin_name=$(basename "$target_dir")
  # Update content
  cat <<INNER_EOF > "$target_dir/${plugin_name}-menu.zsh"
${plugin_name}-menu() {
  echo "Hello from updated mock plugin ${plugin_name}!"
}
INNER_EOF
  echo "Already up to date."
  exit 0
fi

exec git "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/git"
}

teardown() {
  cleanup_sandbox
}

@test "zdx-plugins: --help works" {
  run run_zsh "zdx-plugins --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zdx-plugins --install"* ]]
}

@test "zdx-plugins: --list displays 'No plugins installed.' when empty" {
  run run_zsh "zdx-plugins --list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No plugins installed."* ]]
}

@test "zdx-plugins: --install clones and registers a valid plugin" {
  run run_zsh "
    zdx-plugins --install https://github.com/example/my-plugin
    zdx-plugins --list
    my-plugin-menu
  "
  if [ "$status" -ne 0 ]; then
    echo "STATUS: $status"
    echo "OUTPUT: $output"
    return 1
  fi
  [[ "$output" == *"Plugin 'my-plugin' successfully installed and activated"* ]]
  [[ "$output" == *"my-plugin"* ]]
  [[ "$output" == *"Hello from mock plugin my-plugin!"* ]]
}

@test "zdx-plugins: --install rejects invalid names" {
  run run_zsh "zdx-plugins --install https://github.com/example/invalid@name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Plugin name 'invalid@name' is invalid"* ]]
}

@test "zdx-plugins: --install handles git clone failure cleanly" {
  run run_zsh "
    export MOCK_GIT_CLONE_FAIL=1
    zdx-plugins --install https://github.com/example/my-plugin
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to clone Git repository"* ]]
  run run_zsh "[[ -d \$HOME/.config/zdx/plugins/my-plugin ]] && echo 'exists' || echo 'clean'"
  [[ "$output" == "clean" ]]
}

@test "zdx-plugins: --install detects missing entrypoint file (contract check)" {
  run run_zsh "
    export MOCK_GIT_CLONE_CONTRACT_NO_FILE=1
    zdx-plugins --install https://github.com/example/no-file-plugin
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ecosystem Contract Violation: Entrypoint script 'no-file-plugin-menu.zsh' not found"* ]]
  run run_zsh "[[ -d \$HOME/.config/zdx/plugins/no-file-plugin ]] && echo 'exists' || echo 'clean'"
  [[ "$output" == "clean" ]]
}

@test "zdx-plugins: --install detects syntax errors in entrypoint (contract check)" {
  run run_zsh "
    export MOCK_GIT_CLONE_CONTRACT_SYNTAX_ERROR=1
    zdx-plugins --install https://github.com/example/broken-syntax
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ecosystem Contract Violation: Syntax error"* ]]
  run run_zsh "[[ -d \$HOME/.config/zdx/plugins/broken-syntax ]] && echo 'exists' || echo 'clean'"
  [[ "$output" == "clean" ]]
}

@test "zdx-plugins: --install detects missing menu function definition (contract check)" {
  run run_zsh "
    export MOCK_GIT_CLONE_CONTRACT_NO_FUNC=1
    zdx-plugins --install https://github.com/example/no-func-plugin
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ecosystem Contract Violation: Function 'no-func-plugin-menu' was not defined"* ]]
  run run_zsh "[[ -d \$HOME/.config/zdx/plugins/no-func-plugin ]] && echo 'exists' || echo 'clean'"
  [[ "$output" == "clean" ]]
}

@test "zdx-plugins: --update updates a specific plugin and re-sources it" {
  run run_zsh "
    zdx-plugins --install https://github.com/example/up-plugin
    zdx-plugins --update up-plugin
    up-plugin-menu
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plugin 'up-plugin' successfully updated and reloaded"* ]]
  [[ "$output" == *"Hello from updated mock plugin up-plugin!"* ]]
}

@test "zdx-plugins: --update all updates all git-tracked plugins" {
  run run_zsh "
    zdx-plugins --install https://github.com/example/plugin-one
    zdx-plugins --install https://github.com/example/plugin-two
    zdx-plugins --update
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Successfully checked/updated 2 plugin(s)"* ]]
}

@test "zdx-plugins: --remove deletes plugin under confirmation gate" {
  run run_zsh "
    zdx-plugins --install https://github.com/example/rem-plugin
    echo 'y' | zdx-plugins --remove rem-plugin
    zdx-plugins --list
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plugin 'rem-plugin' removed successfully"* ]]
  [[ "$output" == *"No plugins installed"* ]]
}

@test "zdx-plugins: --remove cancels deletion" {
  run run_zsh "
    zdx-plugins --install https://github.com/example/keep-plugin
    echo 'n' | zdx-plugins --remove keep-plugin
    zdx-plugins --list
  "
  if [ "$status" -ne 0 ]; then
    echo "STATUS: $status"
    echo "OUTPUT: $output"
    return 1
  fi
  [[ "$output" == *"Uninstallation canceled"* ]]
  [[ "$output" == *"keep-plugin"* ]]
}

@test "zdx-plugins: --remove blocks directory traversal path escape attempts" {
  run run_zsh "
    mkdir -p \$HOME/.config/zdx/plugins
    zdx-plugins --remove '../../..'
  "
  if [ "$status" -eq 0 ]; then
    echo "STATUS: $status"
    echo "OUTPUT: $output"
    return 1
  fi
  [[ "$output" == *"Security Alert: Invalid plugin path"* ]]
}
