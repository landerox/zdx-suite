#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Lazy custom plugins: discovery without sourcing, manifest stubs, and the
# full loader chain on first use.

setup() {
  load test_helper
  LAZY_HOME="$TEST_TEMP_DIR/lazy-home"
  LAZY_PLUGINS="$LAZY_HOME/.config/zdx/plugins"
  mkdir -p "$LAZY_PLUGINS/demo"
  chmod 755 "$LAZY_HOME" "$LAZY_HOME/.config" "$LAZY_HOME/.config/zdx" "$LAZY_PLUGINS/demo"
  chmod 700 "$LAZY_PLUGINS"
  cat > "$LAZY_PLUGINS/demo/demo-menu.zsh" <<'ZSH'
print -r -- "demo sourced" >> "$LAZY_LOG"
demo-menu() { print -r -- "demo menu: $*"; }
demo-status() { print -r -- "demo status: $*"; }
ZSH
  chmod 644 "$LAZY_PLUGINS/demo/demo-menu.zsh"
  printf '%s\n' '# demo commands' 'demo-status' '' > "$LAZY_PLUGINS/demo/commands"
  chmod 644 "$LAZY_PLUGINS/demo/commands"
  export LAZY_HOME LAZY_PLUGINS
  export LAZY_LOG="$TEST_TEMP_DIR/lazy.log"
  : > "$LAZY_LOG"
  # A zsh on PATH that records every `zsh -n` the loader runs.
  mkdir -p "$TEST_TEMP_DIR/zsh-recorder"
  cat > "$TEST_TEMP_DIR/zsh-recorder/zsh" <<SH
#!/bin/sh
printf 'zsh %s\n' "\$*" >> "$LAZY_LOG"
exec "$(command -v zsh)" "\$@"
SH
  chmod +x "$TEST_TEMP_DIR/zsh-recorder/zsh"
}

teardown() {
  cleanup_sandbox
}

lazy_shell() {
  env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME HOME="$LAZY_HOME" \
    PATH="$TEST_TEMP_DIR/zsh-recorder:$PATH" ZDX_LAZY_LOAD=1 \
    "$(command -v zsh)" -f -c '
      source "$1/functions.zsh" || exit 90
      '"$1"'
    ' _ "$TEST_SUITE_ROOT"
}

@test "lazy plugins: startup discovers without sourcing or syntax checks" {
  run lazy_shell '
    print -r -- "discovered=${(j:,:)ZDX_DISCOVERED_PLUGINS} loaded=${(j:,:)ZDX_LOADED_PLUGINS}"
    whence -w demo-menu demo-status
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "discovered=demo loaded=" ]
  [ "${lines[1]}" = "demo-menu: function" ]
  [ "${lines[2]}" = "demo-status: function" ]
  [ ! -s "$LAZY_LOG" ]
}

@test "lazy plugins: the first call runs the full chain and dispatches" {
  run lazy_shell '
    demo-status one two
    print -r -- "loaded=${(j:,:)ZDX_LOADED_PLUGINS}"
    demo-menu three
    zdx demo four
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "demo status: one two" ]
  [ "${lines[1]}" = "loaded=demo" ]
  [ "${lines[2]}" = "demo menu: three" ]
  [ "${lines[3]}" = "demo menu: four" ]
  [ "$(grep -c '^demo sourced$' "$LAZY_LOG")" -eq 1 ]
  [ "$(grep -c '^zsh -n -- ' "$LAZY_LOG")" -eq 1 ]
}

@test "lazy plugins: a plugin changed after discovery is refused on first use" {
  run lazy_shell '
    chmod 666 "$HOME/.config/zdx/plugins/demo/demo-menu.zsh"
    demo-menu
    print -r -- "rc=$? loaded=${(j:,:)ZDX_LOADED_PLUGINS}"
  '
  [[ "$output" == *"refusing unsafe plugin entrypoint 'demo'"* ]]
  [[ "$output" == *"rc=1 loaded="* ]]
  [ ! -s "$LAZY_LOG" ]
}

@test "lazy plugins: invalid or unsafe manifests register only the menu" {
  printf '%s\n' 'demo-status' 'other-tool' > "$LAZY_PLUGINS/demo/commands"
  run lazy_shell 'whence -w demo-menu; whence -w demo-status || print -r -- "no status stub"'
  [[ "$output" == *"invalid entry other-tool"* ]]
  [[ "$output" == *"demo-menu: function"* ]]
  [[ "$output" == *"no status stub"* ]]

  printf '%s\n' 'demo-status' > "$LAZY_PLUGINS/demo/commands"
  chmod 666 "$LAZY_PLUGINS/demo/commands"
  run lazy_shell 'whence -w demo-status || print -r -- "no status stub"'
  [[ "$output" == *"ignoring the unsafe command manifest of plugin 'demo'"* ]]
  [[ "$output" == *"no status stub"* ]]
}

@test "lazy plugins: a declared command the plugin never defines fails clearly" {
  printf '%s\n' 'demo-status' 'demo-missing' > "$LAZY_PLUGINS/demo/commands"
  run lazy_shell '
    demo-missing
    print -r -- "rc=$?"
    whence -w demo-missing || print -r -- "stub removed"
  '
  [[ "$output" == *"plugin 'demo' declares demo-missing but does not define it"* ]]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"stub removed"* ]]
}

@test "lazy plugins: status counts discovered plugins separately" {
  [ -n "$(command -v jq)" ] || skip "jq is not installed"
  run lazy_shell 'cd "$HOME"; zdx-status --json 2>/dev/null'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e \
    '.zdx.custom_plugins == 0 and .zdx.custom_plugins_available == 1'
}

@test "lazy plugins: eager shells keep loading plugins at startup" {
  run env HOME="$LAZY_HOME" zsh -f -c '
    source "$1/functions.zsh" || exit 90
    print -r -- "loaded=${(j:,:)ZDX_LOADED_PLUGINS} discovered=${(j:,:)ZDX_DISCOVERED_PLUGINS}"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "loaded=demo discovered=demo" ]
}

@test "lazy plugins: a core sourced from a function, as Oh My Zsh does, loads them on first use" {
  # Oh My Zsh sources each plugin entrypoint from its _omz_source function,
  # so the loaded-plugin list must stay global after that function returns.
  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME HOME="$LAZY_HOME" \
    PATH="$TEST_TEMP_DIR/zsh-recorder:$PATH" "$(command -v zsh)" -f -c '
      unset -m "ZDX_*"
      ZDX_LAZY_LOAD=1 NO_COLOR=1
      _omz_source() {
        local context filepath="$1"
        source "$filepath"
      }
      _omz_source "$1/zdx-suite.plugin.zsh" || exit 90
      print -r -- "after-source: set=${+ZDX_LOADED_PLUGINS} loaded=[${(j:,:)ZDX_LOADED_PLUGINS}]"
      demo-status one two
      print -r -- "first-call: rc=$? loaded=[${(j:,:)ZDX_LOADED_PLUGINS}]"
      zdx demo three
      zdx-plugins --list 2>&1 | grep -E "^demo "
    ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "after-source: set=1 loaded=[]" ]
  [ "${lines[1]}" = "demo status: one two" ]
  [ "${lines[2]}" = "first-call: rc=0 loaded=[demo]" ]
  [ "${lines[3]}" = "demo menu: three" ]
  [[ "${lines[4]}" =~ ^demo\ +Active\ +Local$ ]]
  [ "$(grep -c '^demo sourced$' "$LAZY_LOG")" -eq 1 ]
}
