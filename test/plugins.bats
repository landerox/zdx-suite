#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "plugins: loads a valid plugin and registers it" {
  local pdir="$HOME/.config/zdx/plugins/hello"
  mkdir -p "$pdir"
  cat <<'EOF' > "$pdir/hello-menu.zsh"
hello-menu() {
  echo "Hello from plugin!"
}
EOF

  run run_zsh "
    hello-menu
    echo \"loaded=\${ZDX_LOADED_PLUGINS[*]}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello from plugin!"* ]]
  [[ "$output" == *"loaded=hello"* ]]
}

@test "plugins: warns but does not crash on syntax error in plugin" {
  local pdir="$HOME/.config/zdx/plugins/broken"
  mkdir -p "$pdir"
  # syntax error: unbalanced parentheses/quotes
  cat <<'EOF' > "$pdir/broken-menu.zsh"
broken-menu() {
  echo "broken
}
EOF

  run run_zsh "
    echo 'STILL ALIVE'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"STILL ALIVE"* ]]
  [[ "$output" == *"failed to load plugin 'broken'"* ]]
}

@test "plugins: warns if entrypoint function is not defined" {
  local pdir="$HOME/.config/zdx/plugins/nofunc"
  mkdir -p "$pdir"
  cat <<'EOF' > "$pdir/nofunc-menu.zsh"
# Just some random comment, no nofunc-menu function
echo "noop"
EOF

  run run_zsh "
    echo 'STILL ALIVE'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"STILL ALIVE"* ]]
  [[ "$output" == *"failed to define function 'nofunc-menu'"* ]]
}

@test "plugins: ignores plugin directories with invalid names" {
  local pdir="$HOME/.config/zdx/plugins/invalid@name"
  mkdir -p "$pdir"
  cat <<'EOF' > "$pdir/invalid@name-menu.zsh"
invalid@name-menu() {
  echo "invalid"
}
EOF

  run run_zsh "
    echo \"loaded=\${ZDX_LOADED_PLUGINS[*]}\"
  "
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"invalid@name"* ]]
}

@test "plugins: refuses a symlinked entrypoint" {
  local pdir="$HOME/.config/zdx/plugins/linked"
  local target="$HOME/linked-menu.zsh"
  mkdir -p "$pdir"
  cat <<'EOF' > "$target"
linked-menu() {
  echo "MUST NOT RUN"
}
EOF
  ln -s "$target" "$pdir/linked-menu.zsh"

  run run_zsh "
    (( \${+functions[linked-menu]} )) && linked-menu
    echo \"loaded=\${ZDX_LOADED_PLUGINS[*]}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing unsafe plugin entrypoint 'linked'"* ]]
  [[ "$output" == *"loaded="* ]]
  [[ "$output" != *"MUST NOT RUN"* ]]
}

@test "plugins: refuses a multiply-linked entrypoint" {
  local pdir="$HOME/.config/zdx/plugins/linked"
  local alternate="$HOME/alternate-menu.zsh"
  mkdir -p "$pdir"
  cat <<'EOF' > "$alternate"
linked-menu() {
  echo "MUST NOT RUN"
}
EOF
  ln "$alternate" "$pdir/linked-menu.zsh"

  run run_zsh "
    (( \${+functions[linked-menu]} )) && linked-menu
    echo \"loaded=\${ZDX_LOADED_PLUGINS[*]}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing unsafe plugin entrypoint 'linked'"* ]]
  [[ "$output" == *"loaded="* ]]
  [[ "$output" != *"MUST NOT RUN"* ]]
}

@test "plugins: refuses a plugin root reached through a symlink" {
  local real_root="$HOME/real-plugins"
  local linked_root="$HOME/.config/zdx/plugins"
  mkdir -p "$real_root/hello" "$(dirname "$linked_root")"
  cat <<'EOF' > "$real_root/hello/hello-menu.zsh"
hello-menu() {
  echo "MUST NOT RUN"
}
EOF
  ln -s "$real_root" "$linked_root"

  run run_zsh "
    (( \${+functions[hello-menu]} )) && hello-menu
    echo \"loaded=\${ZDX_LOADED_PLUGINS[*]}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing unsafe plugin root"* ]]
  [[ "$output" == *"loaded="* ]]
  [[ "$output" != *"MUST NOT RUN"* ]]
}

@test "plugins: preserves diagnostics emitted while sourcing" {
  local pdir="$HOME/.config/zdx/plugins/noisy"
  mkdir -p "$pdir"
  cat <<'EOF' > "$pdir/noisy-menu.zsh"
print -u2 -r -- "plugin diagnostic preserved"
noisy-menu() {
  return 0
}
EOF

  run run_zsh "echo \"loaded=\${ZDX_LOADED_PLUGINS[*]}\""

  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin diagnostic preserved"* ]]
  [[ "$output" == *"loaded=noisy"* ]]
}
