#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# The plugin API v1: its version, its closed list of services, the documented
# template, and plugin completions.

setup() {
  load test_helper
  API_HOME="$TEST_TEMP_DIR/api-home"
  API_PLUGINS="$API_HOME/.config/zdx/plugins"
  mkdir -p "$API_PLUGINS/mytool"
  chmod 755 "$API_HOME" "$API_HOME/.config" "$API_HOME/.config/zdx" "$API_PLUGINS/mytool"
  chmod 700 "$API_PLUGINS"
  awk '/<!-- plugin-template -->/{f=1; next} /<!-- \/plugin-template -->/{f=0} f' \
    "$TEST_SUITE_ROOT/docs/plugins.md" | sed '1d;$d' \
    > "$API_PLUGINS/mytool/mytool-menu.zsh"
  chmod 644 "$API_PLUGINS/mytool/mytool-menu.zsh"
  printf '%s\n' 'mytool-status' > "$API_PLUGINS/mytool/commands"
  chmod 644 "$API_PLUGINS/mytool/commands"
  export API_HOME API_PLUGINS
}

teardown() {
  cleanup_sandbox
}

@test "plugin api: a folded readonly service list cannot masquerade as API v1" {
  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME HOME="$API_HOME" \
    ZDX_LAZY_LOAD=1 zsh -f -c '
      emulate -R zsh
      source "$1/functions.zsh" || exit 90
      print -r -- "${(j:\n:)_ZDX_PLUGIN_API_SERVICES}"
    ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  local packed_services="$output"
  [ -n "$packed_services" ]

  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME HOME="$API_HOME" \
    ZDX_LAZY_LOAD=1 zsh -f -c '
      emulate -R zsh
      typeset -gr ZDX_PLUGIN_API=1
      typeset -gra _ZDX_PLUGIN_API_SERVICES=("$2")
      [[ ${#_ZDX_PLUGIN_API_SERVICES[@]} == 1 ]] || exit 90
      source "$1/functions.zsh" > "$HOME/source.out" 2> "$HOME/source.err"
      rc=$?
      print -r -- "source=$rc elements=${#_ZDX_PLUGIN_API_SERVICES[@]}"
      [[ "$rc" != 0 && ! -n "${_ZDX_FUNCTIONS_SOURCED-}" ]] || exit 91
      [[ "${_ZDX_PLUGIN_API_SERVICES[1]}" == "$2" ]] || exit 92
      [[ ! -s "$HOME/source.out" && -s "$HOME/source.err" ]] || exit 93
      if ( _ZDX_PLUGIN_API_SERVICES=() ) 2>/dev/null; then
        exit 94
      fi
    ' _ "$TEST_SUITE_ROOT" "$packed_services"
  [ "$status" -eq 0 ]
  [[ "$output" == source=*" elements=1" ]]
}

@test "plugin api: the version is read-only and every listed service exists" {
  local documented
  documented=$(awk '/<!-- plugin-api-v1-services -->/{f=1; next} /<!-- \/plugin-api-v1-services -->/{f=0} f' \
    "$TEST_SUITE_ROOT/docs/plugins.md" | sed -n 's/^| `\(_zdx_[a-z_]*\)` .*/\1/p' | sort)
  local mode
  for mode in eager lazy; do
    run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME HOME="$API_HOME" \
      ZDX_LAZY_LOAD="$([[ "$mode" == lazy ]] && echo 1 || echo 0)" zsh -f -c '
        emulate -R zsh
        source "$1/functions.zsh" || exit 90
        [[ "$ZDX_PLUGIN_API" == 1 ]] || exit 91
        ( ZDX_PLUGIN_API=2 ) 2>/dev/null && exit 92
        local service
        for service in "${_ZDX_PLUGIN_API_SERVICES[@]}"; do
          (( ${+functions[$service]} )) || { print -r -- "missing $service"; exit 93; }
        done
        print -rl -- "${(o)_ZDX_PLUGIN_API_SERVICES[@]}"
      ' _ "$TEST_SUITE_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "$documented" ]
  done
}

@test "plugin api: the documented template stays short and runs lazily" {
  [ "$(wc -l < "$API_PLUGINS/mytool/mytool-menu.zsh")" -le 100 ]
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
IFS= read -r row
printf '%s\n' "$row"
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME HOME="$API_HOME" \
    ZDX_LAZY_LOAD=1 NO_COLOR=1 zsh -f -c '
      emulate -R zsh
      source "$1/functions.zsh" || exit 90
      mytool-status
      print -r -- "loaded=${(j:,:)ZDX_LOADED_PLUGINS}"
      mytool-menu
      mytool-menu extra 2>/dev/null; print -r -- "unknown=$?"
    ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'MyTool Status' <<< "$output")" -eq 2 ]
  [[ "$output" == *"loaded=mytool"* ]]
  [[ "$output" == *"unknown=2"* ]]
  [[ "$output" != *"refusing plugin"* ]]

  run zsh -f -c '
    emulate -R zsh
    source "$1"
    mytool-status
  ' _ "$API_PLUGINS/mytool/mytool-menu.zsh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs the ZDX plugin API v1"* ]]
}

@test "plugin api: a plugin completion is autoloaded and limited to its own commands" {
  printf '%s\n' '#compdef mytool-menu mytool-status' 'print -r -- completing' \
    > "$API_PLUGINS/mytool/_mytool-menu"
  chmod 644 "$API_PLUGINS/mytool/_mytool-menu"
  run env HOME="$API_HOME" zsh -f -c '
    emulate -R zsh
    autoload -Uz compinit && compinit -u -d "$HOME/.zcompdump" || exit 90
    source "$1/zdx-suite.plugin.zsh" || exit 91
    print -r -- "menu=${_comps[mytool-menu]-} status=${_comps[mytool-status]-}"
    whence -w _mytool-menu
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"menu=_mytool-menu status=_mytool-menu"* ]]
  [[ "$output" == *"_mytool-menu: function"* ]]

  printf '%s\n' '#compdef mytool-menu git-push' > "$API_PLUGINS/mytool/_mytool-menu"
  run -0 env HOME="$API_HOME" zsh -f -c '
    emulate -R zsh
    autoload -Uz compinit && compinit -u -d "$HOME/.zcompdump" || exit 90
    source "$1/zdx-suite.plugin.zsh" || exit 91
    print -r -- "push=${_comps[git-push]-}"
  ' _ "$TEST_SUITE_ROOT"
  [[ "$output" == *"ignoring the unsafe or invalid completion of plugin 'mytool'"* ]]
  [[ "$output" != *"push=_mytool-menu"* ]]
}
