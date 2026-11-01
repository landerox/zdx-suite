#!/usr/bin/env bats
# shellcheck disable=SC2016
# Public consumers of the proposed two-batch external inventory observer.
# Load after the immutable ownership and eligibility preparation is applied.

setup() {
  load test_helper
  load plugins_test_helper
  load plugins_ownership_test_helper
  load plugins_inventory_observer_test_helper
  plugins_git_recorder
  mkdir -p "$PLUGINS_ROOT"
  chmod -- 700 "$PLUGINS_ROOT"
  f307_find_recorder
}

teardown() {
  cleanup_sandbox
}

@test "plugin inventory observer: lazy and eager startup discard valid output from a failed batch" {
  local mode call
  for mode in lazy eager; do
    for call in 1 2; do
      export PLUGINS_ROOT="$HOME/startup-$mode-$call/plugins"
      f307_plugin pending
      f307_plugin independent
      f307_find_arm after-error "$call"
      run f307_shell "$mode" '
        (( ${#ZDX_DISCOVERED_PLUGINS} == 0 && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 31
        (( ! ${+PENDING_SOURCED} && ! ${+INDEPENDENT_SOURCED} )) || exit 32
        local name=""
        for name in pending-menu pending-status pending-check independent-menu independent-status independent-check; do
          (( ! ${+functions[$name]} && ! ${+_ZDX_PLUGIN_STUBS[$name]} )) || exit 33
        done
        (( ${+functions[zdx]} && ${+functions[env-menu]} )) || exit 34
        env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 35
        [[ ! -s "$HOME/startup.stdout" && -s "$HOME/startup.stderr" ]] || exit 36
        [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" ]] || exit 37
        print -r -- refused-with-builtins
      '
      [ "$status" -eq 0 ]
      [ "$output" = refused-with-builtins ]
      f307_find_assert_fired after-error "$call"
      grep -Eiq -- 'plugin|inventory|enumerat|find' "$HOME/startup.stderr"
    done
  done
}

@test "plugin inventory observer: malformed successful output refuses the whole startup inventory" {
  local fault call
  for fault in unterminated empty-record cross-startpath; do
    export PLUGINS_ROOT="$HOME/malformed-$fault/plugins"
    f307_plugin pending
    mkdir -p "$PLUGINS_ROOT/bad.dot"
    printf '%s\n' 'bad.dot-menu() { :; }' > "$PLUGINS_ROOT/bad.dot/bad.dot-menu.zsh"
    call=2
    f307_find_arm "$fault" "$call"
    run f307_shell lazy '
      (( ${#ZDX_DISCOVERED_PLUGINS} == 0 && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 31
      (( ! ${+PENDING_SOURCED} && ! ${+functions[pending-menu]} )) || exit 32
      (( ! ${+_ZDX_PLUGIN_STUBS[pending-menu]} )) || exit 33
      [[ ! -s "$HOME/startup.stdout" && -s "$HOME/startup.stderr" ]] || exit 34
      (( ${+functions[zdx]} && ${+functions[env-menu]} )) || exit 35
      print -r -- malformed-refused
    '
    [ "$status" -eq 0 ]
    [ "$output" = malformed-refused ]
    f307_find_assert_fired "$fault" "$call"
  done
}

@test "plugin inventory observer: first lazy activation preserves all live state and retries after observation failure" {
  local scenario fault call
  for scenario in 'after-error 1' 'after-error 2' 'status124 2'; do
    read -r fault call <<< "$scenario"
    export F307_OBSERVER_FAULT="$fault" F307_OBSERVER_CALL="$call"
    f307_plugin pending
    f307_plugin independent
    : > "$F307_FIND_CONTROL"
    run f307_shell lazy '
      independent-menu >"$HOME/live.stdout" 2>"$HOME/live.stderr" || exit 31
      local -A old_stubs=("${(@kv)_ZDX_PLUGIN_STUBS}") old_bodies=()
      local old_loaded="${(j:,:)ZDX_LOADED_PLUGINS}" old_discovered="${(j:,:)ZDX_DISCOVERED_PLUGINS}"
      local name="" value=""
      for name in pending-menu pending-status pending-check independent-menu _independent_helper; do
        old_bodies[$name]="${functions[$name]-}"
      done
      print -r -- 0 > "$F307_FIND_COUNT"
      print -r -- "$F307_OBSERVER_FAULT $F307_OBSERVER_CALL" > "$F307_FIND_CONTROL"
      local -i rc=0
      pending-menu >"$HOME/activation.stdout" 2>"$HOME/activation.stderr" || rc=$?
      (( rc == 1 )) || exit 32
      [[ ! -s "$HOME/activation.stdout" && -s "$HOME/activation.stderr" ]] || exit 33
      [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == "$old_loaded" && "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == "$old_discovered" ]] || exit 34
      (( ${#_ZDX_PLUGIN_STUBS} == ${#old_stubs} )) || exit 35
      for name value in "${(@kv)old_stubs}"; do
        [[ "${_ZDX_PLUGIN_STUBS[$name]-}" == "$value" ]] || exit 36
      done
      for name value in "${(@kv)old_bodies}"; do
        [[ "${functions[$name]-}" == "$value" ]] || exit 37
      done
      (( ! ${+PENDING_SOURCED} )) || exit 38
      [[ "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 39
      : > "$F307_FIND_CONTROL"
      pending-menu >"$HOME/retry.stdout" 2>"$HOME/retry.stderr" || exit 40
      [[ "$(<"$HOME/retry.stdout")" == "pending menu" && ! -s "$HOME/retry.stderr" ]] || exit 41
      [[ "${PENDING_SOURCED-}" == 1 && "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 42
      (( ${ZDX_LOADED_PLUGINS[(Ie)pending]} && ${ZDX_LOADED_PLUGINS[(Ie)independent]} )) || exit 43
      [[ "${functions[independent-menu]}" == "${old_bodies[independent-menu]}" ]] || exit 44
      print -r -- preserved-and-retried
    '
    [ "$status" -eq 0 ]
    [ "$output" = preserved-and-retried ]
    f307_find_assert_fired "$fault" "$call"
  done
}

@test "plugin inventory observer: install refuses failed prefetch inventory without clone or published state" {
  plugin_origin_create incoming
  plugin_origin_commit incoming 'Records incoming source' \
    $'typeset -g INCOMING_NEW_SOURCE=1\n'"$(plugin_source incoming v2)"
  export F307_INCOMING_URL
  F307_INCOMING_URL=$(plugin_origin_url incoming)
  f307_plugin independent
  local call
  for call in 1 2; do
    export F307_OBSERVER_CALL="$call"
    : > "$F307_FIND_CONTROL"
    run f307_shell lazy '
      independent-menu >"$HOME/live.stdout" 2>"$HOME/live.stderr" || exit 31
      zdx-plugins --help >"$HOME/help.stdout" 2>"$HOME/help.stderr" || exit 32
      local old_body="${functions[independent-menu]}"
      local old_loaded="${(j:,:)ZDX_LOADED_PLUGINS}" old_discovered="${(j:,:)ZDX_DISCOVERED_PLUGINS}"
      print -r -- 0 > "$F307_FIND_COUNT"
      print -r -- "after-error $F307_OBSERVER_CALL" > "$F307_FIND_CONTROL"
      : > "$PLUGINS_GIT_LOG"
      local -i rc=0
      zdx-plugins --install "$F307_INCOMING_URL" --yes >"$HOME/install.stdout" 2>"$HOME/install.stderr" || rc=$?
      (( rc == 1 )) || exit 33
      [[ ! -e "$PLUGINS_ROOT/incoming" && ! -L "$PLUGINS_ROOT/incoming" ]] || exit 34
      (( ! ${+INCOMING_NEW_SOURCE} && ! ${+functions[incoming-menu]} )) || exit 35
      [[ "${functions[independent-menu]}" == "$old_body" && "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 36
      [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == "$old_loaded" && "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == "$old_discovered" ]] || exit 37
      [[ ! -s "$HOME/install.stdout" && -s "$HOME/install.stderr" ]] || exit 38
      print -r -- refused-before-fetch
    '
    [ "$status" -eq 0 ]
    [ "$output" = refused-before-fetch ]
    f307_find_assert_fired after-error "$call"
    run grep -E -- '(^|[[:space:]])(clone|fetch)([[:space:]]|$)' "$PLUGINS_GIT_LOG"
    [ "$status" -eq 1 ]
    : > "$F307_FIND_CONTROL"
    [ -z "$(plugins_staging_left)" ]
  done
}

@test "plugin inventory observer: update refuses failed prepublication inventory and retains the active checkout" {
  plugin_origin_create incoming
  plugins_install incoming
  local old_head before call
  old_head=$(plugin_installed_head incoming)
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/incoming")
  plugin_origin_commit incoming 'New source must not run before publication' \
    $'typeset -g INCOMING_NEW_SOURCE=1\n'"$(plugin_source incoming v2)"
  f307_plugin independent
  for call in 1 2; do
    export F307_OBSERVER_CALL="$call"
    : > "$F307_FIND_CONTROL"
    run f307_shell lazy '
      incoming-menu >"$HOME/old.stdout" 2>"$HOME/old.stderr" || exit 31
      [[ "$(<"$HOME/old.stdout")" == "incoming v1" ]] || exit 32
      independent-menu >"$HOME/live.stdout" 2>"$HOME/live.stderr" || exit 33
      zdx-plugins --help >"$HOME/help.stdout" 2>"$HOME/help.stderr" || exit 34
      functions[_f307_find_original_confirm]="${functions[_zdx_plugins_confirm]}"
      _zdx_plugins_confirm() {
        _f307_find_original_confirm "$@" || return $?
        typeset -g F307_FIND_CONFIRMED=1
        print -r -- 0 > "$F307_FIND_COUNT"
        print -r -- "after-error $F307_OBSERVER_CALL" > "$F307_FIND_CONTROL"
      }
      local old_body="${functions[incoming-menu]}" live_body="${functions[independent-menu]}"
      local old_loaded="${(j:,:)ZDX_LOADED_PLUGINS}" old_discovered="${(j:,:)ZDX_DISCOVERED_PLUGINS}"
      : > "$PLUGINS_GIT_LOG"
      local -i rc=0
      zdx-plugins --update incoming --yes >"$HOME/update.stdout" 2>"$HOME/update.stderr" || rc=$?
      (( rc == 1 )) || exit 35
      [[ "${F307_FIND_CONFIRMED-}" == 1 ]] || exit 36
      [[ "${functions[incoming-menu]}" == "$old_body" && "${functions[independent-menu]}" == "$live_body" ]] || exit 37
      [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == "$old_loaded" && "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == "$old_discovered" ]] || exit 38
      (( ! ${+INCOMING_NEW_SOURCE} )) || exit 39
      [[ ! -s "$HOME/update.stdout" && -s "$HOME/update.stderr" ]] || exit 40
      incoming-menu >"$HOME/retained.stdout" 2>"$HOME/retained.stderr" || exit 41
      [[ "$(<"$HOME/retained.stdout")" == "incoming v1" ]] || exit 42
      print -r -- refused-before-publication
    '
    [ "$status" -eq 0 ]
    [ "$output" = refused-before-publication ]
    f307_find_assert_fired after-error "$call"
    grep -Eq -- '(^|[[:space:]])(clone|fetch)([[:space:]]|$)' "$PLUGINS_GIT_LOG"
    : > "$F307_FIND_CONTROL"
    [ "$(plugin_installed_head incoming)" = "$old_head" ]
    [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/incoming")" = "$before" ]
    [ -z "$(plugins_staging_left)" ]
  done
}

@test "plugin inventory observer: exact two-batch argv preserves disjoint names and opaque root paths" {
  export PLUGINS_ROOT="$HOME/"$'root with spaces\nsecond line/plugins'
  f307_plugin alpha
  f307_plugin beta
  mkdir -p "$PLUGINS_ROOT/.hidden" "$PLUGINS_ROOT/bad.dot" "$HOME/elsewhere"
  printf '%s\n' 'typeset -g HIDDEN_SOURCE=1' '.hidden-menu() { :; }' \
    > "$PLUGINS_ROOT/.hidden/.hidden-menu.zsh"
  printf '%s\n' 'typeset -g INVALID_SOURCE=1' 'bad.dot-menu() { :; }' \
    > "$PLUGINS_ROOT/bad.dot/bad.dot-menu.zsh"
  printf '%s\n' 'typeset -g ALIAS_SOURCE=1' 'alias-menu() { :; }' \
    > "$HOME/elsewhere/alias-menu.zsh"
  ln -s "$HOME/elsewhere" "$PLUGINS_ROOT/alias"
  printf '0\n' > "$F307_FIND_COUNT"
  run f307_shell lazy '
    (( ${#ZDX_DISCOVERED_PLUGINS} == 2 && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 31
    (( ${ZDX_DISCOVERED_PLUGINS[(Ie)alpha]} && ${ZDX_DISCOVERED_PLUGINS[(Ie)beta]} )) || exit 32
    (( ${+functions[alpha-menu]} && ${+functions[beta-menu]} )) || exit 33
    (( ! ${+ALPHA_SOURCED} && ! ${+BETA_SOURCED} && ! ${+ALIAS_SOURCE} && ! ${+HIDDEN_SOURCE} && ! ${+INVALID_SOURCE} )) || exit 34
    (( ! ${+functions[alias-menu]} )) || exit 35
    [[ ! -s "$HOME/startup.stdout" && ! -s "$HOME/startup.stderr" ]] || exit 36
    print -r -- two-batches
  '
  [ "$status" -eq 0 ]
  [ "$output" = two-batches ]
  [ "$(cat "$F307_FIND_COUNT")" -eq 2 ]
  f307_find_assert_argv 1 -P "$PLUGINS_ROOT/." '!' -name . -prune -print0
  f307_find_assert_batch 2 "$PLUGINS_ROOT/alpha/." "$PLUGINS_ROOT/beta/."
  f307_find_assert_native_row 1 "$PLUGINS_ROOT/./.hidden"
  f307_find_assert_native_row 1 "$PLUGINS_ROOT/./alias"
  f307_find_assert_native_row 2 "$PLUGINS_ROOT/alpha/./alpha-menu.zsh"
  f307_find_assert_native_row 2 "$PLUGINS_ROOT/beta/./beta-menu.zsh"
}

@test "plugin inventory observer: no eligible direct directories means no second find batch" {
  mkdir -p "$PLUGINS_ROOT/.hidden"
  printf '%s\n' 'not a candidate' > "$PLUGINS_ROOT/ordinary-file"
  printf '0\n' > "$F307_FIND_COUNT"
  run f307_shell lazy '
    (( ${#ZDX_DISCOVERED_PLUGINS} == 0 && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 31
    [[ ! -s "$HOME/startup.stdout" && ! -s "$HOME/startup.stderr" ]] || exit 32
    (( ${+functions[zdx]} && ${+functions[env-menu]} )) || exit 33
    print -r -- root-only
  '
  [ "$status" -eq 0 ]
  [ "$output" = root-only ]
  [ "$(cat "$F307_FIND_COUNT")" -eq 1 ]
  f307_find_assert_argv 1 -P "$PLUGINS_ROOT/." '!' -name . -prune -print0
}

@test "plugin inventory observer: genuinely missing find keeps builtins help and removal usable" {
  f307_plugin pending
  f307_find_missing_path
  run f307_find_shell_without_find lazy '
    (( ! ${+commands[find]} )) || exit 31
    (( ${#ZDX_DISCOVERED_PLUGINS} == 0 && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 32
    (( ! ${+PENDING_SOURCED} && ! ${+functions[pending-menu]} )) || exit 33
    [[ ! -s "$HOME/startup.stdout" && -s "$HOME/startup.stderr" ]] || exit 34
    env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 35
    zdx-plugins --help >"$HOME/help.stdout" 2>"$HOME/help.stderr" || exit 36
    zdx-plugins --remove pending --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr" || exit 37
    [[ ! -e "$PLUGINS_ROOT/pending" && ! -L "$PLUGINS_ROOT/pending" ]] || exit 38
    (( ! ${+PENDING_SOURCED} )) || exit 39
    [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" ]] || exit 40
    [[ ! -s "$HOME/help.stdout" && -s "$HOME/help.stderr" && ! -s "$HOME/remove.stdout" ]] || exit 41
    print -r -- missing-local-to-customs
  '
  [ "$status" -eq 0 ]
  [ "$output" = missing-local-to-customs ]
  grep -Eiq -- 'find' "$HOME/startup.stderr"
  [ "$(cat "$F307_FIND_COUNT")" -eq 0 ]
}
