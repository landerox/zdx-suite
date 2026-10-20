#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Reserved plugin names and the namespace guard around plugin sourcing.

setup() {
  load test_helper
  NS_HOME="$TEST_TEMP_DIR/ns-home"
  NS_PLUGINS="$NS_HOME/.config/zdx/plugins"
  mkdir -p "$NS_PLUGINS"
  chmod 755 "$NS_HOME" "$NS_HOME/.config" "$NS_HOME/.config/zdx"
  chmod 700 "$NS_PLUGINS"
  export NS_HOME NS_PLUGINS
}

teardown() {
  cleanup_sandbox
}

# Creates plugin NAME whose entrypoint body is read from stdin.
ns_plugin() {
  local name="$1"
  mkdir -p "$NS_PLUGINS/$name"
  chmod 755 "$NS_PLUGINS/$name"
  cat > "$NS_PLUGINS/$name/$name-menu.zsh"
  chmod 644 "$NS_PLUGINS/$name/$name-menu.zsh"
}

ns_start() {
  HOME="$NS_HOME" zsh -f -c '
    source "$1/functions.zsh"
    print -r -- "loaded=${(j:,:)ZDX_LOADED_PLUGINS}"
    '"${1:-}"'
  ' _ "$TEST_SUITE_ROOT"
}

@test "plugin namespace: reserved names are refused by the loader" {
  local name
  for name in git zdx git-extra ws_tools tk status; do
    printf '%s-menu() { :; }\n' "$name" | ns_plugin "$name"
  done
  run ns_start
  [ "$status" -eq 0 ]
  for name in git zdx git-extra ws_tools tk status; do
    [[ "$output" == *"refusing plugin '$name': the name is reserved for ZDX"* ]]
  done
  [[ "$output" == *"loaded="$'\n'* || "$output" == *"loaded=" ]]
}

@test "plugin namespace: the installer refuses reserved names before fetching" {
  run env HOME="$NS_HOME" zsh -f -c '
    source "$1/functions.zsh"
    zdx-plugins --install https://example.invalid/repo.git git --yes
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Plugin name 'git' is reserved for ZDX"* ]]
  [ ! -e "$NS_PLUGINS/git" ]
}

@test "plugin namespace: a plugin that replaces ZDX functions is refused and undone" {
  ns_plugin rogue <<'ZSH'
rogue-menu() { :; }
_rogue_helper() { :; }
git-push() { print -r -- hijacked; }
_zdx_ui_label() { print -r -- hijacked; }
ZSH
  # The names keep byte order even when LC_ALL names a locale that sorts
  # "_" after letters.
  local locale_name=""
  locale_name=$(locale -a 2>/dev/null | grep -iE '^en_US\.utf-?8$' | head -n 1)
  [ -z "$locale_name" ] || export LC_ALL="$locale_name"
  run ns_start '
    [[ -n "${functions[git-push]-}" && "${functions[git-push]}" != *hijacked* ]] \
      && print -r -- "command=restored"
    [[ "${functions[_zdx_ui_label]}" != *hijacked* ]] && print -r -- "core=restored"
    (( ${+functions[rogue-menu]} || ${+functions[_rogue_helper]} )) || print -r -- "plugin=removed"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing plugin 'rogue': it defined or replaced functions outside rogue-* and _rogue_*: _zdx_ui_label, git-push"* ]]
  [[ "$output" == *"loaded="$'\n'* ]]
  [[ "$output" == *"command=restored"* ]]
  [[ "$output" == *"core=restored"* ]]
  [[ "$output" == *"plugin=removed"* ]]
}

@test "plugin namespace: generic helper names are refused" {
  ns_plugin noisy <<'ZSH'
noisy-menu() { :; }
log() { print -r -- "$*"; }
ZSH
  run ns_start '(( ${+functions[log]} )) || print -r -- "log=removed"'
  [[ "$output" == *"refusing plugin 'noisy'"*": log"* ]]
  [[ "$output" == *"log=removed"* ]]
}

@test "plugin namespace: namespaced functions and new autoload stubs load" {
  ns_plugin my-tool <<'ZSH'
autoload -Uz add-zsh-hook
my-tool-menu() { :; }
my-tool-status() { :; }
_my_tool_helper() { :; }
ZSH
  run ns_start
  [ "$status" -eq 0 ]
  [[ "$output" == *"loaded=my-tool"* ]]
  [[ "$output" != *"refusing plugin"* ]]
}

@test "plugin namespace: a failed source still restores replaced functions" {
  ns_plugin broken <<'ZSH'
zdx-status() { print -r -- hijacked; }
return 3
ZSH
  run ns_start '[[ "${functions[zdx-status]}" != *hijacked* ]] && print -r -- "restored"'
  [[ "$output" == *"refusing plugin 'broken'"* ]]
  [[ "$output" == *"restored"* ]]
}
