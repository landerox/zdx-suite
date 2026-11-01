#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Complete candidate namespaces, lazy ownership removal, and the plugin menu.
# Local origins and every mutation belong to the shared disposable sandbox.

setup() {
  load test_helper
  load plugins_test_helper
  load plugins_ownership_test_helper
  plugins_git_recorder
  mkdir -p "$PLUGINS_ROOT"
  chmod 700 "$PLUGINS_ROOT"
}

teardown() {
  cleanup_sandbox
}

@test "plugin ownership: lazy discovery refuses every member of each namespace conflict" {
  f307_startup_matrix lazy
}

@test "plugin ownership: eager startup refuses every conflict before any candidate is sourced" {
  f307_startup_matrix eager
}

@test "plugin ownership: complete-set preflight refuses a connected three-candidate conflict" {
  local mode order name index=0
  local -a names=()
  for mode in lazy eager; do
    for order in 'foo foo-bar foo_baz' 'foo foo_baz foo-bar' \
      'foo-bar foo foo_baz' 'foo-bar foo_baz foo' \
      'foo_baz foo foo-bar' 'foo_baz foo-bar foo'; do
      index=$((index + 1))
      export PLUGINS_ROOT="$HOME/connected/$index/plugins" F307_MODE="$mode"
      read -r -a names <<< "$order"
      for name in "${names[@]}" independent; do
        f307_plugin "$name"
      done
      run f307_shell "$mode" '
        local name="" command_name="" source_flag=""
        for name in foo foo-bar foo_baz; do
          (( ! ${ZDX_DISCOVERED_PLUGINS[(Ie)$name]} )) || exit 31
          (( ! ${ZDX_LOADED_PLUGINS[(Ie)$name]} )) || exit 32
          source_flag="${(U)${name//-/_}}_SOURCED"
          (( ! ${+parameters[$source_flag]} )) || exit 33
          for command_name in "${name}-menu" "${name}-status" "${name}-check"; do
            (( ! ${+functions[$command_name]} && ! ${+_ZDX_PLUGIN_STUBS[$command_name]} )) || exit 34
          done
        done
        [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == independent ]] || exit 35
        if [[ "$F307_MODE" == eager ]]; then
          [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == independent ]] || exit 36
        else
          (( ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 37
        fi
        print -r -- complete-set
      '
      [ "$status" -eq 0 ]
      [ "$output" = complete-set ]
      for name in foo foo-bar foo_baz; do
        grep -Eq -- "(^|[^a-z0-9_-])${name}([^a-z0-9_-]|$)" "$HOME/startup.stderr"
      done
    done
  done
}

@test "plugin ownership: similar disjoint names remain independently available" {
  local mode pair left right index=0
  for mode in lazy eager; do
    for pair in 'foo foobar' 'foo-bar foo-barista' 'foo-bar foo_bars'; do
      index=$((index + 1))
      read -r left right <<< "$pair"
      export PLUGINS_ROOT="$HOME/disjoint/$index/plugins"
      f307_plugin "$left"
      f307_plugin "$right"
      export F307_LEFT="$left" F307_RIGHT="$right" F307_MODE="$mode"
      run f307_shell "$mode" '
        local name="" source_flag=""
        for name in "$F307_LEFT" "$F307_RIGHT"; do
          (( ${ZDX_DISCOVERED_PLUGINS[(Ie)$name]} )) || exit 31
          (( ${+functions[${name}-menu]} )) || exit 32
          source_flag="${(U)${name//-/_}}_SOURCED"
          if [[ "$F307_MODE" == eager ]]; then
            (( ${ZDX_LOADED_PLUGINS[(Ie)$name]} )) || exit 33
            [[ "${(P)source_flag}" == 1 ]] || exit 34
          else
            (( ! ${ZDX_LOADED_PLUGINS[(Ie)$name]} )) || exit 35
            (( ! ${+parameters[$source_flag]} )) || exit 36
          fi
        done
        print -r -- separate
      '
      [ "$status" -eq 0 ]
      [ "$output" = separate ]
      [ ! -s "$HOME/startup.stderr" ]
    done
  done
}

@test "plugin ownership: a present unsafe entrypoint still reserves its conflicting namespace" {
  local mode
  for mode in lazy eager; do
    export PLUGINS_ROOT="$HOME/unsafe-$mode/plugins"
    f307_plugin foo
    f307_plugin foo-bar
    f307_plugin independent
    chmod 666 "$PLUGINS_ROOT/foo/foo-menu.zsh"
    run f307_shell "$mode" '
      [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == independent ]] || exit 31
      (( ! ${+functions[foo-menu]} && ! ${+functions[foo-bar-menu]} )) || exit 32
      (( ! ${+FOO_SOURCED} && ! ${+FOO_BAR_SOURCED} )) || exit 33
      print -r -- reserved
    '
    [ "$status" -eq 0 ]
    [ "$output" = reserved ]
  done
}

@test "plugin ownership: linked entrypoints cannot authorize a conflicting safe peer" {
  f307_plugin foo
  f307_plugin foo-bar
  mv "$PLUGINS_ROOT/foo/foo-menu.zsh" "$HOME/linked-entrypoint.zsh"
  ln -s "$HOME/linked-entrypoint.zsh" "$PLUGINS_ROOT/foo/foo-menu.zsh"
  run f307_shell lazy '
    (( ${#ZDX_DISCOVERED_PLUGINS} == 0 )) || exit 31
    (( ! ${+functions[foo-menu]} && ! ${+functions[foo-bar-menu]} )) || exit 32
    print -r -- refused
  '
  [ "$status" -eq 0 ]
  [ "$output" = refused ]
}

@test "plugin ownership: an unsafe direct directory still reserves its present candidate namespace" {
  local mode
  for mode in lazy eager; do
    export PLUGINS_ROOT="$HOME/unsafe-directory-$mode/plugins"
    f307_plugin foo
    f307_plugin foo-bar
    f307_plugin independent
    chmod 777 "$PLUGINS_ROOT/foo"
    run f307_shell "$mode" '
      [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == independent ]] || exit 31
      (( ! ${+functions[foo-menu]} && ! ${+functions[foo-bar-menu]} )) || exit 32
      (( ! ${+FOO_SOURCED} && ! ${+FOO_BAR_SOURCED} )) || exit 33
      print -r -- reserved
    '
    [ "$status" -eq 0 ]
    [ "$output" = reserved ]
  done
}

@test "plugin ownership: directories without matching entrypoints and directory links are not candidates" {
  mkdir -p "$PLUGINS_ROOT/foo" "$HOME/elsewhere"
  f307_plugin foo-bar
  run f307_shell lazy '
    [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == foo-bar ]] || exit 31
    (( ${+functions[foo-bar-menu]} )) || exit 32
    print -r -- available
  '
  [ "$status" -eq 0 ]
  [ "$output" = available ]

  rmdir "$PLUGINS_ROOT/foo"
  printf '%s\n' 'foo-menu() { :; }' > "$HOME/elsewhere/foo-menu.zsh"
  ln -s "$HOME/elsewhere" "$PLUGINS_ROOT/foo"
  run f307_shell lazy '
    [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == foo-bar ]] || exit 33
    (( ! ${+functions[foo-menu]} )) || exit 34
    print -r -- available
  '
  [ "$status" -eq 0 ]
  [ "$output" = available ]
}

@test "plugin ownership: an overlapping manifest never takes another candidate's commands" {
  f307_plugin foo
  f307_plugin foo-bar
  printf '%s\n' foo-bar-menu foo-bar-status > "$PLUGINS_ROOT/foo/commands"
  run f307_shell lazy '
    (( ${#ZDX_DISCOVERED_PLUGINS} == 0 )) || exit 31
    local command_name=""
    for command_name in foo-menu foo-bar-menu foo-bar-status; do
      (( ! ${+functions[$command_name]} )) || exit 32
      (( ! ${+_ZDX_PLUGIN_STUBS[$command_name]} )) || exit 33
    done
    (( ! ${+FOO_SOURCED} && ! ${+FOO_BAR_SOURCED} )) || exit 34
    print -r -- no-takeover
  '
  [ "$status" -eq 0 ]
  [ "$output" = no-takeover ]
}

@test "plugin ownership: sequential installs reject namespace overlaps in both installation orders before fetch" {
  local pair left right first second order index=0
  for pair in 'foo foo-bar' 'foo foo_bar' 'foo-bar foo_bar' 'foo-bar foo_bar-baz'; do
    read -r left right <<< "$pair"
    for first in "$left" "$right"; do
      if [ ! -d "$TEST_TEMP_DIR/origins/$first.git" ]; then
        plugin_origin_create "$first"
      fi
    done
    for order in forward reverse; do
      index=$((index + 1))
      first="$left" second="$right"
      if [[ "$order" == reverse ]]; then
        first="$right" second="$left"
      fi
      export PLUGINS_ROOT="$HOME/install-$index/plugins"
      mkdir -p "$PLUGINS_ROOT"
      export F307_FIRST="$first" F307_SECOND="$second"
      export F307_FIRST_URL F307_SECOND_URL
      F307_FIRST_URL=$(plugin_origin_url "$first")
      F307_SECOND_URL=$(plugin_origin_url "$second")
      run f307_shell lazy '
        zdx-plugins --install "$F307_FIRST_URL" --yes \
          >"$HOME/first.stdout" 2>"$HOME/first.stderr" || exit 31
        local menu_name="${F307_FIRST}-menu" before_body=""
        before_body="${functions[$menu_name]}"
        : > "$PLUGINS_GIT_LOG"
        local -i rc=0
        zdx-plugins --install "$F307_SECOND_URL" --yes \
          >"$HOME/second.stdout" 2>"$HOME/second.stderr" || rc=$?
        (( rc == 1 )) || exit 32
        [[ ! -e "$PLUGINS_ROOT/$F307_SECOND" ]] || exit 33
        [[ "${functions[$menu_name]}" == "$before_body" ]] || exit 34
        [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == "$F307_FIRST" ]] || exit 35
        [[ ! -s "$HOME/second.stdout" ]] || exit 36
        print -r -- refused
      '
      [ "$status" -eq 0 ]
      [ "$output" = refused ]
      grep -Eq -- "(^|[^a-z0-9_-])${first}([^a-z0-9_-]|$)" "$HOME/second.stderr"
      run grep -E -- '(^|[[:space:]])(clone|fetch)([[:space:]]|$)' "$PLUGINS_GIT_LOG"
      [ "$status" -eq 1 ]
      [ "$(plugin_installed_head "$first")" = "$(plugin_origin_head "$first")" ]
      [ -z "$(plugins_staging_left)" ]
    done
  done
}

@test "plugin ownership: installation checks a peer added after the shell's discovery" {
  plugin_origin_create foo-bar
  export F307_INSTALL_URL
  F307_INSTALL_URL=$(plugin_origin_url foo-bar)
  run f307_shell lazy '
    command mkdir -p "$PLUGINS_ROOT/foo" || exit 31
    print -r -- "foo-menu() { :; }" > "$PLUGINS_ROOT/foo/foo-menu.zsh" || exit 32
    local -i rc=0
    zdx-plugins --install "$F307_INSTALL_URL" --yes \
      >"$HOME/install.stdout" 2>"$HOME/install.stderr" || rc=$?
    (( rc == 1 )) || exit 33
    [[ -f "$PLUGINS_ROOT/foo/foo-menu.zsh" && ! -e "$PLUGINS_ROOT/foo-bar" ]] || exit 34
    (( ! ${+functions[foo-menu]} && ! ${+functions[foo-bar-menu]} )) || exit 35
    print -r -- refused
  '
  [ "$status" -eq 0 ]
  [ "$output" = refused ]
  [ ! -s "$HOME/install.stdout" ]
  run grep -E -- '(^|[[:space:]])(clone|fetch)([[:space:]]|$)' "$PLUGINS_GIT_LOG"
  [ "$status" -eq 1 ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugin ownership: discovered and loaded owners reserve their live namespace after their directory disappears" {
  plugin_origin_create foo-bar
  export F307_INSTALL_URL
  F307_INSTALL_URL=$(plugin_origin_url foo-bar)
  local mode
  for mode in lazy eager; do
    export PLUGINS_ROOT="$HOME/vanished-$mode/plugins" F307_MODE="$mode"
    f307_plugin foo
    : > "$PLUGINS_GIT_LOG"
    run f307_shell "$mode" '
      local before="${functions[foo-menu]}"
      command mv "$PLUGINS_ROOT/foo" "$HOME/moved-owner-$F307_MODE" || exit 31
      local -i rc=0
      zdx-plugins --install "$F307_INSTALL_URL" --yes 2>"$HOME/install.stderr" || rc=$?
      (( rc == 1 )) || exit 32
      [[ ! -e "$PLUGINS_ROOT/foo-bar" ]] || exit 33
      [[ "${functions[foo-menu]}" == "$before" ]] || exit 34
      (( ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} )) || exit 35
      if [[ "$F307_MODE" == eager ]]; then
        (( ${ZDX_LOADED_PLUGINS[(Ie)foo]} )) || exit 36
        [[ "${FOO_SOURCED-}" == 1 ]] || exit 37
      else
        [[ "${_ZDX_PLUGIN_STUBS[foo-menu]-}" == foo ]] || exit 38
        (( ! ${+FOO_SOURCED} )) || exit 39
      fi
      print -r -- refused
    '
    [ "$status" -eq 0 ]
    [ "$output" = refused ]
    run grep -E -- '(^|[[:space:]])(clone|fetch)([[:space:]]|$)' "$PLUGINS_GIT_LOG"
    [ "$status" -eq 1 ]
  done
}

@test "plugin ownership: a peer appearing at the trust decision prevents publication and activation" {
  plugin_origin_create foo-bar
  plugin_origin_commit foo-bar 'Adds a source-time observation' \
    $'typeset -g FOO_BAR_NEW_SOURCE=1\n'"$(plugin_source foo-bar v2)"
  export F307_INSTALL_URL
  F307_INSTALL_URL=$(plugin_origin_url foo-bar)
  run f307_shell lazy '
    source "$1/functions/zdx-plugins.zsh" || exit 31
    _zdx_plugins_confirm() {
      command mkdir -p "$PLUGINS_ROOT/foo" || return 91
      print -r -- "foo-menu() { :; }" > "$PLUGINS_ROOT/foo/foo-menu.zsh" || return 92
      return 0
    }
    local -i rc=0
    zdx-plugins --install "$F307_INSTALL_URL" --yes \
      >"$HOME/install.stdout" 2>"$HOME/install.stderr" || rc=$?
    (( rc == 1 )) || exit 32
    [[ -f "$PLUGINS_ROOT/foo/foo-menu.zsh" && ! -e "$PLUGINS_ROOT/foo-bar" ]] || exit 33
    (( ! ${+functions[foo-bar-menu]} )) || exit 34
    (( ! ${ZDX_LOADED_PLUGINS[(Ie)foo-bar]} )) || exit 35
    (( ! ${+FOO_BAR_NEW_SOURCE} )) || exit 36
    print -r -- refused
  '
  [ "$status" -eq 0 ]
  [ "$output" = refused ]
  [ ! -s "$HOME/install.stdout" ]
  grep -Eq -- '(^|[^a-z0-9_-])foo([^a-z0-9_-]|$)' "$HOME/install.stderr"
  [ -z "$(plugins_staging_left)" ]
}

@test "plugin ownership: an exact owner's ordinary update is not its own namespace conflict" {
  plugin_origin_create foo
  plugins_install foo
  plugin_origin_commit foo 'New version' \
    $'typeset -g FOO_V2_SOURCE=1\n'"$(plugin_source foo v2)"
  run f307_shell eager '
    zdx-plugins --update foo --yes >"$HOME/update.stdout" 2>"$HOME/update.stderr" || exit 31
    [[ "${FOO_V2_SOURCE-}" == 1 ]] || exit 32
    foo-menu
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'foo v2' ]
  [ "$(plugin_installed_head foo)" = "$(plugin_origin_head foo)" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugin ownership: update rechecks a newly added peer and preserves the active version" {
  plugin_origin_create foo
  plugins_install foo
  local old_head before
  old_head=$(plugin_installed_head foo)
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/foo")
  plugin_origin_commit foo 'New version' \
    $'typeset -g FOO_V2_SOURCE=1\n'"$(plugin_source foo v2)"
  run f307_shell eager '
    source "$1/functions/zdx-plugins.zsh" || exit 31
    _zdx_plugins_confirm() {
      command mkdir -p "$PLUGINS_ROOT/foo-bar" || return 91
      print -r -- "foo-bar-menu() { :; }" > "$PLUGINS_ROOT/foo-bar/foo-bar-menu.zsh" || return 92
      return 0
    }
    local before="${functions[foo-menu]}"
    local -i rc=0
    zdx-plugins --update foo --yes >"$HOME/update.stdout" 2>"$HOME/update.stderr" || rc=$?
    (( rc == 1 )) || exit 32
    [[ "${functions[foo-menu]}" == "$before" ]] || exit 33
    (( ${ZDX_LOADED_PLUGINS[(Ie)foo]} )) || exit 34
    (( ! ${+functions[foo-bar-menu]} )) || exit 35
    (( ! ${+FOO_V2_SOURCE} )) || exit 36
    foo-menu
  '
  [ "$status" -eq 0 ]
  [ "$output" = 'foo v1' ]
  [ "$(plugin_installed_head foo)" = "$old_head" ]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/foo")" = "$before" ]
  [ -f "$PLUGINS_ROOT/foo-bar/foo-bar-menu.zsh" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugin ownership: removing a never-loaded plugin clears both registries and every owned stub" {
  f307_plugin foo
  f307_plugin independent
  run f307_shell lazy '
    local other_body="${functions[independent-menu]}"
    (( ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 31
    zdx-plugins --remove foo --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || exit 32
    (( ! ${ZDX_LOADED_PLUGINS[(Ie)foo]} && ! ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} )) || exit 33
    local command_name="" owner=""
    for command_name in foo-menu foo-status foo-check; do
      (( ! ${+functions[$command_name]} && ! ${+_ZDX_PLUGIN_STUBS[$command_name]} )) || exit 34
    done
    for owner in "${(@v)_ZDX_PLUGIN_STUBS}"; do
      [[ "$owner" != foo ]] || exit 35
    done
    [[ "${functions[independent-menu]}" == "$other_body" ]] || exit 36
    [[ "${_ZDX_PLUGIN_STUBS[independent-status]-}" == independent ]] || exit 37
    (( ! ${+FOO_SOURCED} && ! ${+INDEPENDENT_SOURCED} )) || exit 38
    source "$1/functions/zdx-menu.zsh" || exit 39
    local model=""
    model=$(_zdx_menu_model) || exit 40
    [[ "$model" != *"|foo|"* && "$model" == *"|independent|"* ]] || exit 41
    local -i rc=0
    zdx foo >"$HOME/dispatch.stdout" 2>"$HOME/dispatch.stderr" || rc=$?
    (( rc == 2 )) || exit 42
    print -r -- unregistered
  '
  [ "$status" -eq 0 ]
  [ "$output" = unregistered ]
  [ ! -e "$PLUGINS_ROOT/foo" ]
  [ -d "$PLUGINS_ROOT/independent" ]
  [ ! -s "$HOME/remove.stdout" ]
  [[ "$(cat "$HOME/dispatch.stderr")" != *'unsafe plugin entrypoint'* ]]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugin ownership: lazy removal preserves foreign replacements even when their text mentions the dispatcher" {
  f307_plugin foo
  run f307_shell lazy '
    foo-menu() { print -r -- "foreign menu _zdx_plugin_lazy_dispatch"; }
    foo-status() { print -r -- "foreign action _zdx_plugin_lazy_dispatch"; }
    foo-local() { print -r -- "unregistered local function"; }
    local before_menu="${functions[foo-menu]}" before_action="${functions[foo-status]}"
    local before_local="${functions[foo-local]}"
    zdx-plugins --remove foo --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || exit 31
    [[ "${functions[foo-menu]-}" == "$before_menu" ]] || exit 32
    [[ "${functions[foo-status]-}" == "$before_action" ]] || exit 33
    [[ "${functions[foo-local]-}" == "$before_local" ]] || exit 34
    (( ! ${+functions[foo-check]} )) || exit 35
    local owner=""
    for owner in "${(@v)_ZDX_PLUGIN_STUBS}"; do
      [[ "$owner" != foo ]] || exit 36
    done
    (( ! ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} )) || exit 37
    print -r -- preserved
  '
  [ "$status" -eq 0 ]
  [ "$output" = preserved ]
  [ ! -e "$PLUGINS_ROOT/foo" ]
}

@test "plugin ownership: loaded removal still leaves the plugin's other definitions until a new shell" {
  f307_plugin foo
  run f307_shell eager '
    (( ${ZDX_LOADED_PLUGINS[(Ie)foo]} )) || exit 31
    local before="${functions[foo-status]}"
    zdx-plugins --remove foo --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || exit 32
    (( ! ${+functions[foo-menu]} )) || exit 33
    [[ "${functions[foo-status]-}" == "$before" ]] || exit 34
    (( ${+functions[_foo_helper]} )) || exit 35
    (( ! ${ZDX_LOADED_PLUGINS[(Ie)foo]} && ! ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} )) || exit 36
    print -r -- loaded-policy
  '
  [ "$status" -eq 0 ]
  [ "$output" = loaded-policy ]
}

@test "plugin ownership: dry-run and decline preserve lazy registration and directory identity" {
  f307_plugin foo
  local before mode
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/foo")
  for mode in dry-run decline; do
    export F307_REMOVE_MODE="$mode"
    run f307_shell lazy '
      source "$1/functions/zdx-plugins.zsh" || exit 31
      local before_menu="${functions[foo-menu]}" before_status="${functions[foo-status]}"
      local -a before_discovered=("${ZDX_DISCOVERED_PLUGINS[@]}")
      if [[ "$F307_REMOVE_MODE" == decline ]]; then
        _zdx_plugins_terminal() { return 0; }
        _zdx_plugins_confirm() { return 1; }
        zdx-plugins --remove foo >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || exit 32
      else
        zdx-plugins --remove foo --dry-run >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || exit 33
      fi
      [[ "${functions[foo-menu]}" == "$before_menu" ]] || exit 34
      [[ "${functions[foo-status]}" == "$before_status" ]] || exit 35
      [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == "${(j:,:)before_discovered}" ]] || exit 36
      [[ "${_ZDX_PLUGIN_STUBS[foo-menu]-}" == foo ]] || exit 37
      (( ${#ZDX_LOADED_PLUGINS} == 0 && ! ${+FOO_SOURCED} )) || exit 38
      print -r -- unchanged
    '
    [ "$status" -eq 0 ]
    [ "$output" = unchanged ]
    [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/foo")" = "$before" ]
    [ -z "$(plugins_staging_left)" ]
  done
}

@test "plugin ownership: a failed quarantine move leaves lazy ownership untouched" {
  f307_plugin foo
  local before
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/foo")
  run f307_shell lazy '
    source "$1/functions/zdx-plugins.zsh" || exit 31
    local before="${functions[foo-menu]}"
    _zdx_plugins_move() { return 1; }
    local -i rc=0
    zdx-plugins --remove foo --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || rc=$?
    (( rc == 1 )) || exit 32
    [[ "${functions[foo-menu]}" == "$before" ]] || exit 33
    [[ "${_ZDX_PLUGIN_STUBS[foo-menu]-}" == foo ]] || exit 34
    (( ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} && ! ${+FOO_SOURCED} )) || exit 35
    print -r -- unchanged
  '
  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/foo")" = "$before" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugin ownership: partial deletion after quarantine cannot retain stale lazy ownership" {
  f307_plugin foo
  run f307_shell lazy '
    source "$1/functions/zdx-plugins.zsh" || exit 31
    _zdx_plugins_remove_stage() { return 1; }
    local -i rc=0
    zdx-plugins --remove foo --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || rc=$?
    (( rc == 1 )) || exit 32
    [[ ! -e "$PLUGINS_ROOT/foo" ]] || exit 33
    (( ! ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} && ! ${ZDX_LOADED_PLUGINS[(Ie)foo]} )) || exit 34
    (( ! ${+functions[foo-menu]} && ! ${+functions[foo-status]} )) || exit 35
    local owner=""
    for owner in "${(@v)_ZDX_PLUGIN_STUBS}"; do
      [[ "$owner" != foo ]] || exit 36
    done
    print -r -- unregistered
  '
  [ "$status" -eq 0 ]
  [ "$output" = unregistered ]
  [[ "$(cat "$HOME/remove.stderr")" == *'left the plugin root'*'manually'* ]]
  [ -n "$(plugins_staging_left)" ]
}

@test "plugin ownership: removal can resolve an initially conflicting layout without activating either plugin" {
  f307_plugin foo
  f307_plugin foo-bar
  run f307_shell lazy '
    (( ${#ZDX_DISCOVERED_PLUGINS} == 0 && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 31
    zdx-plugins --remove foo-bar --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || exit 32
    (( ! ${+FOO_SOURCED} && ! ${+FOO_BAR_SOURCED} )) || exit 33
    print -r -- resolved
  '
  [ "$status" -eq 0 ]
  [ "$output" = resolved ]
  [ -d "$PLUGINS_ROOT/foo" ]
  [ ! -e "$PLUGINS_ROOT/foo-bar" ]
  run f307_shell lazy '
    [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == foo ]] || exit 34
    (( ${+functions[foo-menu]} && ! ${+FOO_SOURCED} )) || exit 35
    print -r -- available
  '
  [ "$status" -eq 0 ]
  [ "$output" = available ]
}

@test "plugin ownership: master rows distinguish available plugins from plugins actually loaded" {
  f307_plugin foo
  run f307_shell lazy '
    source "$1/functions/zdx-menu.zsh" || exit 31
    local before="" after=""
    before=$(_zdx_menu_model) || exit 32
    [[ "$before" == *"|foo|Available in this shell; loads on first use."* ]] || exit 33
    [[ "$before" == *"Open available custom suites."* ]] || exit 34
    (( ! ${+FOO_SOURCED} )) || exit 35
    foo-menu >"$HOME/plugin.stdout" || exit 36
    after=$(_zdx_menu_model) || exit 37
    local -a rows=("${(@M)${(@f)after}:#*|foo|*}")
    (( ${#rows} == 1 )) || exit 38
    [[ "${rows[1]}" == *"|foo|Loaded in this shell. Open the custom plugin menu." ]] || exit 39
    [[ "${FOO_SOURCED-}" == 1 ]] || exit 40
    (( ${ZDX_LOADED_PLUGINS[(Ie)foo]} && ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} )) || exit 41
    print -r -- accurate
  '
  [ "$status" -eq 0 ]
  [ "$output" = accurate ]
  [ "$(cat "$HOME/plugin.stdout")" = 'foo menu' ]
}

@test "plugin ownership: completion of discovered membership does not activate code and dispatch preserves literal argv" {
  f307_plugin foo
  cat > "$PLUGINS_ROOT/foo/foo-menu.zsh" <<'ZSH'
typeset -g FOO_SOURCED=1
foo-menu() { printf '%s\0' "$@" > "$HOME/received-argv"; }
foo-status() { :; }
foo-check() { :; }
ZSH
  run f307_shell lazy '
    _arguments() { state=suite; }
    _describe() { local name="$4"; print -rl -- "${(@P)name}"; }
    _f307_complete() { source "$1/completions/_zdx-menu"; }
    local service=zdx
    _f307_complete "$1" >"$HOME/completion.stdout" || exit 31
    (( ! ${+FOO_SOURCED} )) || exit 32
    zdx foo "space and ; semicolon" "\$(touch must-not-run)" "*" "" || exit 33
    [[ "${FOO_SOURCED-}" == 1 ]] || exit 34
    [[ ! -e "$HOME/must-not-run" ]] || exit 35
    print -r -- literal
  '
  [ "$status" -eq 0 ]
  [ "$output" = literal ]
  grep -Fq -- 'foo:Custom plugin' "$HOME/completion.stdout"
  printf '%s\0' 'space and ; semicolon' '$(touch must-not-run)' '*' '' > "$HOME/expected-argv"
  cmp "$HOME/expected-argv" "$HOME/received-argv"
}

@test "plugin ownership: a discovered plugin with a missing function is not described as loaded" {
  f307_plugin foo
  run f307_shell lazy '
    source "$1/functions/zdx-menu.zsh" || exit 31
    unfunction foo-menu || exit 32
    local -i rc=0
    zdx foo >"$HOME/dispatch.stdout" 2>"$HOME/dispatch.stderr" || rc=$?
    (( rc == 1 )) || exit 33
    (( ! ${+FOO_SOURCED} && ! ${ZDX_LOADED_PLUGINS[(Ie)foo]} )) || exit 34
    [[ ! -s "$HOME/dispatch.stdout" ]] || exit 35
    print -r -- available-state
  '
  [ "$status" -eq 0 ]
  [ "$output" = available-state ]
  [[ "$(cat "$HOME/dispatch.stderr")" == *"Plugin 'foo'"*'foo-menu'* ]]
  [[ "$(cat "$HOME/dispatch.stderr")" != *'Loaded plugin'* ]]
}

@test "plugin ownership: the manager shares the command-menu frame and isolates fzf defaults" {
  f307_fzf_recorder
  export FZF_DEFAULT_OPTS='--multi --height=20%'
  export FZF_DEFAULT_OPTS_FILE="$HOME/not-a-config" FZF_DEFAULT_COMMAND='MUST NOT RUN'
  run f307_shell lazy '
    zdx-plugins >"$HOME/menu.stdout" 2>"$HOME/menu.stderr" || exit 31
    [[ ! -s "$HOME/menu.stdout" ]] || exit 32
    [[ "$FZF_DEFAULT_OPTS" == "--multi --height=20%" ]] || exit 33
    [[ "$FZF_DEFAULT_OPTS_FILE" == "$HOME/not-a-config" ]] || exit 34
    [[ "$FZF_DEFAULT_COMMAND" == "MUST NOT RUN" ]] || exit 35
    print -r -- cancelled
  '
  [ "$status" -eq 0 ]
  [ "$output" = cancelled ]
  run command python3 - "$F307_FZF_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
args = root.joinpath("argv").read_bytes().decode().split("\0")[:-1]
options = dict(arg.partition("=")[::2] for arg in args)
for key, value in {
    "--height": "80%", "--layout": "reverse", "--border": "rounded",
    "--delimiter": "[|]", "--with-nth": "1", "--pointer": "▶",
    "--prompt": "plugins > ", "--preview-window": "down:4:wrap",
}.items():
    assert options.get(key) == value, (key, options.get(key))
bindings = ",".join(a.partition("=")[2] for a in args if a.startswith("--bind="))
assert "ctrl-/:toggle-preview" in bindings.split(","), bindings
assert "Type to filter | Enter run | Esc cancel | Ctrl-/ details" in options["--header"].splitlines()
assert "\x1b" not in options["--header"]
assert "--multi" not in options
assert "Tab mark" not in options["--header"]
assert root.joinpath("environment").read_bytes().split(b"\0") == [b"", b"", b"", b"/bin/sh", b""]
assert len(root.joinpath("calls").read_text().splitlines()) == 1
PY
  [ "$status" -eq 0 ]
}

@test "plugin ownership: the manager's plain mode remains invocation-local" {
  f307_fzf_recorder
  export ZDX_FZF_PLAIN=1
  run f307_shell lazy '
    zdx-plugins >"$HOME/menu.stdout" 2>"$HOME/menu.stderr" || exit 31
    [[ "${ZDX_FZF_PLAIN-}" == 1 ]] || exit 32
    print -r -- plain
  '
  [ "$status" -eq 0 ]
  [ "$output" = plain ]
  run command python3 - "$F307_FZF_DIR/argv" <<'PY'
from pathlib import Path
import sys

args = Path(sys.argv[1]).read_bytes().decode().split("\0")[:-1]
assert "--no-color" in args and "--no-unicode" in args
assert [x for x in args if x.startswith("--pointer=")][-1] == "--pointer=>"
assert [x for x in args if x.startswith("--marker=")][-1] == "--marker=+"
PY
  [ "$status" -eq 0 ]
}

@test "plugin ownership: manager previews use the existing flag CLI and treat description metacharacters as data" {
  f307_fzf_recorder
  run f307_shell lazy '
    zdx-plugins >"$HOME/menu.stdout" 2>"$HOME/menu.stderr" || exit 31
    local option="" preview="" action="" rendered="" program="" flag=""
    for option in "${(@0)$(<"$F307_FZF_DIR/argv")}"; do
      [[ "$option" == --preview=* ]] && preview="${option#--preview=}"
    done
    [[ -n "$preview" ]] || exit 32
    local description="literal \$(touch must-not-run), \`touch must-not-run-2\`, quote '\'' and 100%"
    for action in list install update remove :; do
      program="${preview//\{2\}/${(qq)action}}"
      program="${program//\{3\}/${(qq)description}}"
      rendered=$(command /bin/sh -c "$program") || exit 33
      if [[ "$action" == : ]]; then
        [[ "$rendered" == "$description" ]] || exit 34
      else
        flag="--$action"
        [[ "$rendered" == "Command: zdx-plugins $flag"* ]] || exit 35
        [[ "$rendered" == *"$description" ]] || exit 36
      fi
      [[ ! -e "$HOME/must-not-run" && ! -e "$HOME/must-not-run-2" ]] || exit 37
    done
    print -r -- preview-data
  '
  [ "$status" -eq 0 ]
  [ "$output" = preview-data ]
}

@test "plugin ownership: manager row helpers reject delimiter newline and NUL before emitting any data" {
  run f307_shell lazy '
    source "$1/functions/zdx-plugins.zsh" || exit 31
    local field="" kind="" row="" description="safe description"
    local -a fields=()
    local -i index=0 rc=0
    for field in "bad|field" $'\''bad\nfield'\'' $'\''bad\0field'\''; do
      for kind in section entry; do
        if [[ "$kind" == section ]]; then
          for index in 1 2; do
            fields=("Title" "$description")
            fields[$index]="$field"
            rc=0
            row=$(_zdx_plugins_menu_section "${fields[@]}" 2>"$HOME/row.stderr") || rc=$?
            (( rc == 2 )) && [[ -z "$row" ]] || exit 32
          done
        else
          for index in 1 2 3; do
            fields=("List Plugins" list "$description")
            fields[$index]="$field"
            rc=0
            row=$(_zdx_plugins_menu_entry "${fields[@]}" 2>"$HOME/row.stderr") || rc=$?
            (( rc == 2 )) && [[ -z "$row" ]] || exit 33
          done
        fi
      done
    done
    row=$(_zdx_plugins_menu_entry "List Plugins" list "literal \$(...) and 100%") || exit 34
    [[ "$row" == "  List Plugins|list|literal \$(...) and 100%" ]] || exit 35
    print -r -- validated
  '
  [ "$status" -eq 0 ]
  [ "$output" = validated ]
}

@test "plugin ownership: a refused manager row aborts construction without opening a partial menu" {
  f307_fzf_recorder
  run f307_shell lazy '
    source "$1/functions/zdx-plugins.zsh" || exit 31
    _zdx_plugins_menu_entry() { return 2; }
    local -i rc=0
    zdx-plugins >"$HOME/menu.stdout" 2>"$HOME/menu.stderr" || rc=$?
    (( rc != 0 )) || exit 32
    [[ ! -s "$F307_FZF_DIR/calls" && ! -s "$HOME/menu.stdout" ]] || exit 33
    print -r -- refused
  '
  [ "$status" -eq 0 ]
  [ "$output" = refused ]
}

@test "plugin ownership: manager cancellation statuses stay successful and capture errors stay failures" {
  f307_fzf_recorder
  local rc
  for rc in 1 130 125; do
    export F307_FZF_STATUS="$rc"
    run f307_shell lazy '
      local -i rc=0 expected=0
      (( F307_FZF_STATUS == 125 )) && expected=1
      zdx-plugins >"$HOME/menu.stdout" 2>"$HOME/menu.stderr" || rc=$?
      (( rc == expected )) || exit 31
      [[ ! -s "$HOME/menu.stdout" ]] || exit 32
      print -r -- handled
    '
    [ "$status" -eq 0 ]
    [ "$output" = handled ]
    [ -z "$(find "$TMPDIR" -name 'zdx-plugins-fzf.*' -print)" ]
  done
}

@test "plugin ownership: a manager section refreshes and a forged row dispatches no action" {
  f307_fzf_recorder
  printf '%s\n' '── Plugin Manager ──|:|List, install, update, and remove custom plugins.' \
    > "$F307_FZF_DIR/responses"
  run f307_shell lazy '
    zdx-plugins >"$HOME/menu.stdout" 2>"$HOME/menu.stderr" || exit 31
    print -r -- refreshed
  '
  [ "$status" -eq 0 ]
  [ "$output" = refreshed ]
  [ "$(wc -l < "$F307_FZF_DIR/calls")" -eq 2 ]

  : > "$F307_FZF_DIR/calls"
  printf '%s\n' '  Forged|list|Never rendered.' > "$F307_FZF_DIR/responses"
  run f307_shell lazy '
    source "$1/functions/zdx-plugins.zsh" || exit 32
    _zdx_plugins_list() { print -r -- INVOKED; return 0; }
    local -i rc=0
    zdx-plugins >"$HOME/menu.stdout" 2>"$HOME/menu.stderr" || rc=$?
    (( rc == 1 )) || exit 33
    [[ ! -s "$HOME/menu.stdout" ]] || exit 34
    print -r -- refused
  '
  [ "$status" -eq 0 ]
  [ "$output" = refused ]
  [[ "$(cat "$HOME/menu.stderr")" == *'not in the plugin menu snapshot'* ]]
}
