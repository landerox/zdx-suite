#!/usr/bin/env bats
# shellcheck disable=SC2016
# Apply after the original ownership proposal and structural eligibility addendum.

setup() {
  load test_helper
  load plugins_test_helper
  load plugins_ownership_test_helper
  load plugins_inventory_test_helper
  plugins_git_recorder
  mkdir -p "$PLUGINS_ROOT"
  chmod -- 700 "$PLUGINS_ROOT"
}

teardown() {
  cleanup_sandbox
}

@test "plugin inventory: a failed present-entry observation prevents all new startup registration" {
  local mode
  for mode in lazy eager; do
    export PLUGINS_ROOT="$HOME/inventory-startup-$mode/plugins"
    f307_inventory_probes
    f307_plugin pending
    run f307_inventory_shell "$mode" startup '
      _f307_inventory_fault_proven || exit 31
      (( ${#ZDX_DISCOVERED_PLUGINS} == 0 && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 32
      (( ${#_ZDX_PLUGIN_STUBS} == 0 )) || exit 33
      (( ! ${+PROBE_ONE_SOURCED} && ! ${+PROBE_TWO_SOURCED} && ! ${+PENDING_SOURCED} )) || exit 34
      local name=""
      for name in probe-one probe-two pending; do
        (( ! ${+functions[${name}-menu]} && ! ${+functions[${name}-status]} \
          && ! ${+functions[${name}-check]} )) || exit 35
      done
      [[ ! -s "$HOME/startup.stdout" ]] || exit 36
      env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 37
      [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" ]] || exit 38
      (( ! ${+PENDING_SOURCED} )) || exit 39
      print -r -- startup-refused
    '
    [ "$status" -eq 0 ]
    [ "$output" = startup-refused ]
    grep -Eiq -- 'inventory' "$HOME/startup.stderr"
  done
}

@test "plugin inventory: first lazy activation fails closed on partial metadata and recovers after the fault clears" {
  f307_inventory_probes
  f307_plugin independent
  f307_plugin pending
  run f307_inventory_shell lazy later '
    independent-menu >"$HOME/independent.stdout" 2>"$HOME/independent.stderr" || exit 31
    [[ "$(<"$HOME/independent.stdout")" == "independent menu" && ! -s "$HOME/independent.stderr" ]] || exit 32
    (( ${ZDX_DISCOVERED_PLUGINS[(Ie)pending]} && ! ${ZDX_LOADED_PLUGINS[(Ie)pending]} )) || exit 33
    (( ! ${+PENDING_SOURCED} && ! ${+PROBE_ONE_SOURCED} && ! ${+PROBE_TWO_SOURCED} )) || exit 34
    _f307_inventory_snapshot independent-menu independent-status _independent_helper || exit 35
    _f307_inventory_arm
    local -i rc=0
    pending-menu >"$HOME/activation.stdout" 2>"$HOME/activation.stderr" || rc=$?
    (( rc == 1 )) || exit 36
    _f307_inventory_fault_proven || exit 37
    [[ ! -s "$HOME/activation.stdout" ]] || exit 38
    (( ! ${+PENDING_SOURCED} && ! ${+PROBE_ONE_SOURCED} && ! ${+PROBE_TWO_SOURCED} )) || exit 39
    _f307_inventory_preserved || exit 40
    [[ "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 41
    env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 42
    [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" ]] || exit 43
    _f307_inventory_preserved || exit 44
    F307_INVENTORY_ENABLED=0
    pending-menu >"$HOME/retry.stdout" 2>"$HOME/retry.stderr" || exit 45
    [[ "$(<"$HOME/retry.stdout")" == "pending menu" && ! -s "$HOME/retry.stderr" ]] || exit 46
    [[ "${PENDING_SOURCED-}" == 1 && "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 47
    (( ${ZDX_LOADED_PLUGINS[(Ie)pending]} && ${ZDX_LOADED_PLUGINS[(Ie)independent]} )) || exit 48
    (( ! ${+PROBE_ONE_SOURCED} && ! ${+PROBE_TWO_SOURCED} )) || exit 49
    print -r -- lazy-refused-then-recovered
  '
  [ "$status" -eq 0 ]
  [ "$output" = lazy-refused-then-recovered ]
  grep -Eiq -- 'inventory' "$HOME/activation.stderr"
}

@test "plugin inventory: a partial scan refuses a disjoint managed install before clone fetch or publication" {
  f307_inventory_probes
  f307_plugin independent
  f307_plugin pending
  plugin_origin_create incoming
  plugin_origin_commit incoming 'Records incoming activation' \
    $'typeset -g INCOMING_SOURCED=1\n'"$(plugin_source incoming v1)"
  export F307_INSTALL_URL
  F307_INSTALL_URL=$(plugin_origin_url incoming)
  local probe_before
  probe_before=$(plugin_tree_fingerprint "$PLUGINS_ROOT/probe-two")
  : > "$PLUGINS_GIT_LOG"
  run f307_inventory_shell lazy later '
    independent-menu >"$HOME/independent.stdout" 2>"$HOME/independent.stderr" || exit 31
    [[ "$(<"$HOME/independent.stdout")" == "independent menu" && ! -s "$HOME/independent.stderr" ]] || exit 32
    _f307_inventory_snapshot independent-menu independent-status _independent_helper || exit 33
    _f307_inventory_arm
    local -i rc=0
    zdx-plugins --install "$F307_INSTALL_URL" --yes \
      >"$HOME/install.stdout" 2>"$HOME/install.stderr" || rc=$?
    (( rc == 1 )) || exit 34
    _f307_inventory_fault_proven || exit 35
    [[ ! -s "$HOME/install.stdout" && ! -e "$PLUGINS_ROOT/incoming" && ! -L "$PLUGINS_ROOT/incoming" ]] || exit 36
    (( ! ${+INCOMING_SOURCED} && ! ${+PENDING_SOURCED} && ! ${+PROBE_ONE_SOURCED} && ! ${+PROBE_TWO_SOURCED} )) || exit 37
    (( ! ${+functions[incoming-menu]} && ! ${+_ZDX_PLUGIN_STUBS[incoming-menu]} )) || exit 38
    _f307_inventory_preserved || exit 39
    env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 40
    [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" ]] || exit 41
    _f307_inventory_preserved || exit 42
    command cp -- "$PLUGINS_GIT_LOG" "$HOME/refused.gitlog" || exit 43
    local -a refused_staging=("$PLUGINS_ROOT"/.zdx-staging.*(N))
    (( ${#refused_staging} == 0 )) || exit 44
    F307_INVENTORY_ENABLED=0
    zdx-plugins --install "$F307_INSTALL_URL" --yes \
      >"$HOME/install-retry.stdout" 2>"$HOME/install-retry.stderr" || exit 45
    [[ ! -s "$HOME/install-retry.stdout" && "${INCOMING_SOURCED-}" == 1 ]] || exit 46
    (( ${ZDX_LOADED_PLUGINS[(Ie)incoming]} && ${ZDX_LOADED_PLUGINS[(Ie)independent]} )) || exit 47
    [[ "${functions[independent-menu]}" == "${F307_BEFORE_BODIES[independent-menu]}" ]] || exit 48
    (( ! ${+PENDING_SOURCED} && ! ${+PROBE_ONE_SOURCED} && ! ${+PROBE_TWO_SOURCED} )) || exit 49
    print -r -- install-refused-before-fetch-then-recovered
  '
  [ "$status" -eq 0 ]
  [ "$output" = install-refused-before-fetch-then-recovered ]
  grep -Eiq -- 'inventory' "$HOME/install.stderr"
  run grep -Eq -- '(^| )(clone|fetch)( |$)' "$HOME/refused.gitlog"
  [ "$status" -eq 1 ]
  [ "$(plugin_installed_head incoming)" = "$(plugin_origin_head incoming)" ]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/probe-two")" = "$probe_before" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugin inventory: metadata failure after trust preserves the installed version before update publication" {
  plugin_origin_create stable
  plugins_install stable
  f307_inventory_probes
  f307_plugin independent
  local old_head old_tree
  old_head=$(plugin_installed_head stable)
  old_tree=$(plugin_tree_fingerprint "$PLUGINS_ROOT/stable")
  plugin_origin_commit stable 'Records the incoming version' \
    $'typeset -g STABLE_NEW_SOURCE=1\n'"$(plugin_source stable v2)"
  : > "$PLUGINS_GIT_LOG"
  run f307_inventory_shell eager later '
    source "$1/functions/zdx-plugins.zsh" || exit 31
    (( ${ZDX_LOADED_PLUGINS[(Ie)stable]} && ${ZDX_LOADED_PLUGINS[(Ie)independent]} )) || exit 32
    stable-menu >"$HOME/old.stdout" 2>"$HOME/old.stderr" || exit 33
    [[ "$(<"$HOME/old.stdout")" == "stable v1" && ! -s "$HOME/old.stderr" ]] || exit 34
    _f307_inventory_snapshot stable-menu independent-menu independent-status _independent_helper || exit 35
    _zdx_plugins_confirm() {
      _f307_inventory_arm
      return 0
    }
    local -i rc=0
    zdx-plugins --update stable --yes >"$HOME/update.stdout" 2>"$HOME/update.stderr" || rc=$?
    (( rc == 1 )) || exit 36
    _f307_inventory_fault_proven || exit 37
    [[ ! -s "$HOME/update.stdout" ]] || exit 38
    (( ! ${+STABLE_NEW_SOURCE} )) || exit 39
    _f307_inventory_preserved || exit 40
    stable-menu >"$HOME/retained.stdout" 2>"$HOME/retained.stderr" || exit 41
    [[ "$(<"$HOME/retained.stdout")" == "stable v1" && ! -s "$HOME/retained.stderr" ]] || exit 42
    env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 43
    [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" ]] || exit 44
    _f307_inventory_preserved || exit 45
    print -r -- update-refused-before-publication
  '
  [ "$status" -eq 0 ]
  [ "$output" = update-refused-before-publication ]
  grep -Eiq -- 'inventory' "$HOME/update.stderr"
  grep -Eq -- '(^| )(clone|fetch)( |$)' "$PLUGINS_GIT_LOG"
  [ "$(plugin_installed_head stable)" = "$old_head" ]
  [ "$(plugin_tree_fingerprint "$PLUGINS_ROOT/stable")" = "$old_tree" ]
  [ -f "$PLUGINS_ROOT/probe-one/probe-one-menu.zsh" ]
  [ -f "$PLUGINS_ROOT/probe-two/probe-two-menu.zsh" ]
  [ -z "$(plugins_staging_left)" ]
}

@test "plugin inventory: missing entries and complete disjoint inventories permit startup lazy use and managed install" {
  plugin_origin_create incoming
  plugin_origin_commit incoming 'Records the positive activation' \
    $'typeset -g INCOMING_SOURCED=1\n'"$(plugin_source incoming v1)"
  export F307_INSTALL_URL
  F307_INSTALL_URL=$(plugin_origin_url incoming)
  local mode missing_before
  for mode in lazy eager; do
    export PLUGINS_ROOT="$HOME/inventory-control-$mode/plugins"
    f307_inventory_probes
    f307_plugin pending
    rm -- "$PLUGINS_ROOT/probe-two/probe-two-menu.zsh"
    missing_before=$(file_identity "$PLUGINS_ROOT/probe-two")
    run f307_inventory_shell "$mode" startup '
      (( F307_INVENTORY_FAULTS == 0 )) || exit 31
      [[ -d "$PLUGINS_ROOT/probe-two" && ! -e "$PLUGINS_ROOT/probe-two/probe-two-menu.zsh" \
        && ! -L "$PLUGINS_ROOT/probe-two/probe-two-menu.zsh" ]] || exit 32
      (( ${ZDX_DISCOVERED_PLUGINS[(Ie)pending]} && ${ZDX_DISCOVERED_PLUGINS[(Ie)probe-one]} )) || exit 33
      (( ! ${ZDX_DISCOVERED_PLUGINS[(Ie)probe-two]} && ! ${ZDX_LOADED_PLUGINS[(Ie)probe-two]} )) || exit 34
      (( ! ${+functions[probe-two-menu]} && ! ${+_ZDX_PLUGIN_STUBS[probe-two-menu]} )) || exit 35
      pending-menu >"$HOME/control.stdout" 2>"$HOME/control.stderr" || exit 36
      [[ "$(<"$HOME/control.stdout")" == "pending menu" && ! -s "$HOME/control.stderr" ]] || exit 37
      [[ "${PENDING_SOURCED-}" == 1 ]] || exit 38
      zdx-plugins --install "$F307_INSTALL_URL" --yes \
        >"$HOME/install.stdout" 2>"$HOME/install.stderr" || exit 39
      [[ ! -s "$HOME/install.stdout" && -f "$PLUGINS_ROOT/incoming/incoming-menu.zsh" ]] || exit 40
      [[ "${INCOMING_SOURCED-}" == 1 ]] || exit 41
      (( ${ZDX_LOADED_PLUGINS[(Ie)incoming]} && F307_INVENTORY_FAULTS == 0 )) || exit 42
      (( ! ${+PROBE_TWO_SOURCED} )) || exit 43
      [[ ! -s "$HOME/startup.stdout" ]] || exit 44
      print -r -- missing-and-disjoint-permitted
    '
    [ "$status" -eq 0 ]
    [ "$output" = missing-and-disjoint-permitted ]
    [ "$(file_identity "$PLUGINS_ROOT/probe-two")" = "$missing_before" ]
    [ "$(plugin_installed_head incoming)" = "$(plugin_origin_head incoming)" ]
    [ -z "$(plugins_staging_left)" ]
  done
}
