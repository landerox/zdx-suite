#!/usr/bin/env bats
# shellcheck disable=SC2016
# Introduced-candidate controls; these are not vulnerabilities in old BASE.

setup() {
  load test_helper
  load plugins_test_helper
  load plugins_ownership_test_helper
  load plugins_inventory_safety_test_helper
  plugins_git_recorder
  mkdir -p "$PLUGINS_ROOT"
  chmod -- 700 "$PLUGINS_ROOT"
  f307_safety_prepare
}

teardown() {
  cleanup_sandbox
}

@test "plugin inventory safety: a FIFO replacing the genuine write-open capture fails without blocking or deleting it" {
  f307_plugin pending
  f307_plugin independent
  run f307_safety_fifo_case write
  [ "$status" -eq 0 ]
  [ "$output" = bounded-refusal ]
  f307_safety_assert_fifo write
  [ "$(cat "$F307_SAFETY_DIR/child-complete")" = refused-with-state ]
}

@test "plugin inventory safety: a FIFO after genuine positive-size pre-read metadata fails without blocking or deletion" {
  f307_plugin pending
  f307_plugin independent
  run f307_safety_fifo_case read
  [ "$status" -eq 0 ]
  [ "$output" = bounded-refusal ]
  f307_safety_assert_fifo read
  [ "$(cat "$F307_SAFETY_DIR/child-complete")" = refused-with-state ]
}

@test "plugin inventory safety: first lazy source repeats entrypoint trust after the final genuine namespace observation" {
  f307_plugin pending
  f307_plugin independent
  export F307_SAFETY_TARGET=pending F307_SAFETY_EXPECTED_OID=""
  f307_safety_find_recorder
  local before
  before=$(sha256_file "$PLUGINS_ROOT/pending/pending-menu.zsh")
  run f307_shell lazy '
    independent-menu >"$HOME/live.stdout" 2>"$HOME/live.stderr" || exit 31
    local pending_body="${functions[pending-menu]}" live_body="${functions[independent-menu]}"
    local old_loaded="${(j:,:)ZDX_LOADED_PLUGINS}" old_discovered="${(j:,:)ZDX_DISCOVERED_PLUGINS}"
    print -r -- armed > "$F307_SAFETY_DIR/armed"
    local -i rc=0
    pending-menu >"$HOME/activation.stdout" 2>"$HOME/activation.stderr" || rc=$?
    (( rc == 1 )) || exit 32
    [[ -s "$F307_SAFETY_DIR/chmodded" && ! -s "$HOME/activation.stdout" && -s "$HOME/activation.stderr" ]] || exit 33
    (( ! ${+PENDING_SOURCED} )) || exit 34
    [[ "${INDEPENDENT_SOURCED-}" == 1 && "${functions[pending-menu]}" == "$pending_body" \
      && "${functions[independent-menu]}" == "$live_body" ]] || exit 35
    [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == "$old_loaded" && "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == "$old_discovered" ]] || exit 36
    [[ "${_ZDX_PLUGIN_STUBS[pending-menu]-}" == pending ]] || exit 37
    print -r -- unsafe-before-source
  '
  [ "$status" -eq 0 ]
  [ "$output" = unsafe-before-source ]
  [ "$(file_mode "$PLUGINS_ROOT/pending/pending-menu.zsh")" = 666 ]
  [ "$(sha256_file "$PLUGINS_ROOT/pending/pending-menu.zsh")" = "$before" ]
  [ "$(cat "$F307_SAFETY_DIR/chmodded")" = lazy ]
}

@test "plugin inventory safety: managed reload rechecks a published entrypoint changed by the final namespace observation" {
  plugin_origin_create incoming
  plugin_origin_commit incoming 'Guard the original version' \
    $'[[ -n "${_INCOMING_MENU_SOURCED-}" ]] && return 0\nincoming-menu() { print -r -- "incoming v1"; }\ntypeset -g _INCOMING_MENU_SOURCED=1'
  plugins_install incoming
  local old_head before
  old_head=$(plugin_installed_head incoming)
  before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/incoming")
  plugin_origin_commit incoming 'New source canary for reload trust checks' \
    $'typeset -g INCOMING_UNSAFE_SOURCE=1\n[[ -n "${_INCOMING_MENU_SOURCED-}" ]] && return 0\nincoming-menu() { print -r -- "incoming v2"; }\ntypeset -g _INCOMING_MENU_SOURCED=1'
  f307_plugin independent
  export F307_SAFETY_TARGET=incoming F307_SAFETY_EXPECTED_OID
  F307_SAFETY_EXPECTED_OID=$(plugin_origin_head incoming)
  f307_safety_find_recorder
  run f307_shell lazy '
    incoming-menu >"$HOME/old.stdout" 2>"$HOME/old.stderr" || exit 31
    independent-menu >"$HOME/live.stdout" 2>"$HOME/live.stderr" || exit 32
    local old_body="${functions[incoming-menu]}" live_body="${functions[independent-menu]}"
    local old_sentinel="${_INCOMING_MENU_SOURCED-}"
    local old_loaded="${(j:,:)ZDX_LOADED_PLUGINS}" old_discovered="${(j:,:)ZDX_DISCOVERED_PLUGINS}"
    print -r -- armed > "$F307_SAFETY_DIR/armed"
    local -i rc=0
    zdx-plugins --update incoming --yes >"$HOME/update.stdout" 2>"$HOME/update.stderr" || rc=$?
    (( rc == 1 )) || exit 33
    [[ "$(<"$F307_SAFETY_DIR/chmodded")" == "$F307_SAFETY_EXPECTED_OID" ]] || exit 34
    (( ! ${+INCOMING_UNSAFE_SOURCE} )) || exit 35
    [[ "${functions[incoming-menu]}" == "$old_body" && "${functions[independent-menu]}" == "$live_body" \
      && "${_INCOMING_MENU_SOURCED-}" == "$old_sentinel" && "$old_sentinel" == 1 ]] || exit 36
    [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == "$old_loaded" && "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == "$old_discovered" ]] || exit 37
    [[ ! -s "$HOME/update.stdout" && -s "$HOME/update.stderr" ]] || exit 38
    incoming-menu >"$HOME/retained.stdout" 2>"$HOME/retained.stderr" || exit 39
    [[ "$(<"$HOME/retained.stdout")" == "incoming v1" ]] || exit 40
    print -r -- unsafe-reload-rolled-back
  '
  [ "$status" -eq 0 ]
  [ "$output" = unsafe-reload-rolled-back ]
  [ "$(plugin_installed_head incoming)" = "$old_head" ]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/incoming")" = "$before" ]
  [ "$(file_mode "$PLUGINS_ROOT/incoming/incoming-menu.zsh")" = 644 ]
  [ -z "$(plugins_staging_left)" ]
}
