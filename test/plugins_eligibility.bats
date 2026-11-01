#!/usr/bin/env bats
# shellcheck disable=SC2016
# Additional structural-candidate checks; apply after plugins_ownership tests.

setup() {
  load test_helper
  load plugins_test_helper
  load plugins_ownership_test_helper
  plugins_git_recorder
  mkdir -p "$PLUGINS_ROOT"
  chmod -- 700 "$PLUGINS_ROOT"
}

teardown() {
  cleanup_sandbox
}

# Keep the original executable outside discovery, then leave a matching
# directory entry whose existence cannot authorize sourcing its contents.
f307_eligibility_entrypoint() {
  local kind="$1"
  f307_plugin foo
  mv "$PLUGINS_ROOT/foo/foo-menu.zsh" "$PLUGINS_ROOT/../saved-foo-menu.zsh"
  case "$kind" in
    dangling)
      ln -s "$PLUGINS_ROOT/../missing-foo-menu.zsh" \
        "$PLUGINS_ROOT/foo/foo-menu.zsh"
      ;;
    directory)
      mkdir -m 755 "$PLUGINS_ROOT/foo/foo-menu.zsh"
      ;;
    *) return 98 ;;
  esac
}

@test "plugin eligibility: a peer added after discovery blocks first lazy activation" {
  f307_plugin foo-bar
  f307_plugin independent
  run f307_shell lazy '
    (( ${ZDX_DISCOVERED_PLUGINS[(Ie)foo-bar]} )) || exit 31
    (( ! ${ZDX_LOADED_PLUGINS[(Ie)foo-bar]} && ! ${+FOO_BAR_SOURCED} )) || exit 32
    independent-menu >"$HOME/independent.stdout" 2>"$HOME/independent.stderr" || exit 33
    [[ "$(<"$HOME/independent.stdout")" == "independent menu" && ! -s "$HOME/independent.stderr" ]] || exit 34
    local live_body="${functions[independent-menu]}"
    command mkdir -- "$PLUGINS_ROOT/foo" || exit 35
    print -rl -- "typeset -g FOO_SOURCED=1" "foo-menu() { :; }" \
      > "$PLUGINS_ROOT/foo/foo-menu.zsh" || exit 36
    local -i activation_rc=0
    foo-bar-menu >"$HOME/activation.stdout" 2>"$HOME/activation.stderr" || activation_rc=$?
    (( activation_rc == 1 )) || exit 37
    [[ ! -s "$HOME/activation.stdout" ]] || exit 38
    (( ! ${+FOO_SOURCED} && ! ${+FOO_BAR_SOURCED} )) || exit 39
    (( ! ${ZDX_LOADED_PLUGINS[(Ie)foo-bar]} && ! ${ZDX_LOADED_PLUGINS[(Ie)foo]} )) || exit 40
    (( ! ${+functions[foo-menu]} && ! ${+_ZDX_PLUGIN_STUBS[foo-menu]} )) || exit 41
    [[ "${functions[independent-menu]}" == "$live_body" && "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 42
    [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == independent ]] || exit 43
    [[ -f "$PLUGINS_ROOT/foo/foo-menu.zsh" ]] || exit 44
    env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 45
    [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" ]] || exit 46
    print -r -- refused-before-source
  '
  [ "$status" -eq 0 ]
  [ "$output" = refused-before-source ]
  grep -Eq -- '(^|[^a-z0-9_-])foo([^a-z0-9_-]|$)' "$HOME/activation.stderr"
  grep -Eq -- '(^|[^a-z0-9_-])foo-bar([^a-z0-9_-]|$)' "$HOME/activation.stderr"
  grep -Eiq -- 'namespace|overlap|conflict' "$HOME/activation.stderr"
}

@test "plugin eligibility: a disjoint peer added after discovery permits first lazy activation" {
  f307_plugin foo-bar
  f307_plugin independent
  run f307_shell lazy '
    (( ${ZDX_DISCOVERED_PLUGINS[(Ie)foo-bar]} )) || exit 31
    (( ! ${ZDX_LOADED_PLUGINS[(Ie)foo-bar]} && ! ${+FOO_BAR_SOURCED} )) || exit 32
    independent-menu >"$HOME/independent.stdout" 2>"$HOME/independent.stderr" || exit 33
    local live_body="${functions[independent-menu]}"
    command mkdir -- "$PLUGINS_ROOT/foobar" || exit 34
    print -rl -- "typeset -g FOOBAR_SOURCED=1" "foobar-menu() { :; }" \
      > "$PLUGINS_ROOT/foobar/foobar-menu.zsh" || exit 35
    foo-bar-menu >"$HOME/activation.stdout" 2>"$HOME/activation.stderr" || exit 36
    [[ "$(<"$HOME/activation.stdout")" == "foo-bar menu" && ! -s "$HOME/activation.stderr" ]] || exit 37
    [[ "${FOO_BAR_SOURCED-}" == 1 ]] || exit 38
    (( ${ZDX_LOADED_PLUGINS[(Ie)foo-bar]} && ${ZDX_LOADED_PLUGINS[(Ie)independent]} )) || exit 39
    (( ! ${+FOOBAR_SOURCED} && ! ${+functions[foobar-menu]} )) || exit 40
    [[ "${functions[independent-menu]}" == "$live_body" && "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 41
    env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 42
    [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" ]] || exit 43
    print -r -- activated-disjoint
  '
  [ "$status" -eq 0 ]
  [ "$output" = activated-disjoint ]
}

@test "plugin eligibility: a dangling matching entrypoint reserves its namespace without activation" {
  local mode
  for mode in lazy eager; do
    export PLUGINS_ROOT="$HOME/dangling-$mode/plugins"
    f307_eligibility_entrypoint dangling
    f307_plugin foo-bar
    f307_plugin independent
    [ -L "$PLUGINS_ROOT/foo/foo-menu.zsh" ]
    [ ! -e "$PLUGINS_ROOT/foo/foo-menu.zsh" ]
    run f307_shell "$mode" '
      [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == independent ]] || exit 31
      (( ! ${+FOO_SOURCED} && ! ${+FOO_BAR_SOURCED} )) || exit 32
      local command_name=""
      for command_name in foo-menu foo-status foo-check foo-bar-menu foo-bar-status foo-bar-check; do
        (( ! ${+functions[$command_name]} && ! ${+_ZDX_PLUGIN_STUBS[$command_name]} )) || exit 33
      done
      (( ! ${+functions[_foo_helper]} && ! ${+functions[_foo_bar_helper]} )) || exit 34
      independent-menu >"$HOME/independent.stdout" 2>"$HOME/independent.stderr" || exit 35
      [[ "$(<"$HOME/independent.stdout")" == "independent menu" && ! -s "$HOME/independent.stderr" ]] || exit 36
      [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == independent && "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 37
      env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 38
      [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" && ! -s "$HOME/startup.stdout" ]] || exit 39
      print -r -- dangling-reserved
    '
    [ "$status" -eq 0 ]
    [ "$output" = dangling-reserved ]
    grep -Eq -- '(^|[^a-z0-9_-])foo([^a-z0-9_-]|$)' "$HOME/startup.stderr"
    grep -Eq -- '(^|[^a-z0-9_-])foo-bar([^a-z0-9_-]|$)' "$HOME/startup.stderr"
    grep -Eiq -- 'namespace|overlap|conflict' "$HOME/startup.stderr"
  done
}

@test "plugin eligibility: a wrong-type matching entrypoint reserves its namespace without activation" {
  local mode
  for mode in lazy eager; do
    export PLUGINS_ROOT="$HOME/wrong-type-$mode/plugins"
    f307_eligibility_entrypoint directory
    f307_plugin foo-bar
    f307_plugin independent
    [ -d "$PLUGINS_ROOT/foo/foo-menu.zsh" ]
    [ ! -L "$PLUGINS_ROOT/foo/foo-menu.zsh" ]
    run f307_shell "$mode" '
      [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == independent ]] || exit 31
      (( ! ${+FOO_SOURCED} && ! ${+FOO_BAR_SOURCED} )) || exit 32
      local command_name=""
      for command_name in foo-menu foo-status foo-check foo-bar-menu foo-bar-status foo-bar-check; do
        (( ! ${+functions[$command_name]} && ! ${+_ZDX_PLUGIN_STUBS[$command_name]} )) || exit 33
      done
      (( ! ${+functions[_foo_helper]} && ! ${+functions[_foo_bar_helper]} )) || exit 34
      independent-menu >"$HOME/independent.stdout" 2>"$HOME/independent.stderr" || exit 35
      [[ "$(<"$HOME/independent.stdout")" == "independent menu" && ! -s "$HOME/independent.stderr" ]] || exit 36
      [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == independent && "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 37
      env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 38
      [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" && ! -s "$HOME/startup.stdout" ]] || exit 39
      print -r -- wrong-type-reserved
    '
    [ "$status" -eq 0 ]
    [ "$output" = wrong-type-reserved ]
    grep -Eq -- '(^|[^a-z0-9_-])foo([^a-z0-9_-]|$)' "$HOME/startup.stderr"
    grep -Eq -- '(^|[^a-z0-9_-])foo-bar([^a-z0-9_-]|$)' "$HOME/startup.stderr"
    grep -Eiq -- 'namespace|overlap|conflict' "$HOME/startup.stderr"
  done
}

@test "plugin eligibility: managed install reserves dangling and wrong-type peer namespaces before fetch" {
  plugin_origin_create foo-bar
  plugin_origin_commit foo-bar 'Records source activation' \
    $'typeset -g FOO_BAR_SOURCED=1\n'"$(plugin_source foo-bar v1)"
  export F307_INSTALL_URL
  F307_INSTALL_URL=$(plugin_origin_url foo-bar)
  local kind before_directory before_entry
  for kind in dangling directory; do
    export PLUGINS_ROOT="$HOME/install-$kind/plugins"
    f307_eligibility_entrypoint "$kind"
    f307_plugin independent
    before_directory=$(file_identity "$PLUGINS_ROOT/foo")
    before_entry=$(file_identity "$PLUGINS_ROOT/foo/foo-menu.zsh")
    : > "$PLUGINS_GIT_LOG"
    run f307_shell lazy '
      independent-menu >"$HOME/independent.stdout" 2>"$HOME/independent.stderr" || exit 31
      [[ "$(<"$HOME/independent.stdout")" == "independent menu" && ! -s "$HOME/independent.stderr" ]] || exit 32
      local live_body="${functions[independent-menu]}"
      local -i install_rc=0
      zdx-plugins --install "$F307_INSTALL_URL" --yes \
        >"$HOME/install.stdout" 2>"$HOME/install.stderr" || install_rc=$?
      (( install_rc == 1 )) || exit 33
      [[ ! -s "$HOME/install.stdout" && ! -e "$PLUGINS_ROOT/foo-bar" && ! -L "$PLUGINS_ROOT/foo-bar" ]] || exit 34
      (( ! ${+FOO_SOURCED} && ! ${+FOO_BAR_SOURCED} )) || exit 35
      (( ! ${+functions[foo-menu]} && ! ${+functions[foo-bar-menu]} )) || exit 36
      [[ "${functions[independent-menu]}" == "$live_body" && "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 37
      [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == independent && "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == independent ]] || exit 38
      env-menu --help >"$HOME/builtin.stdout" 2>"$HOME/builtin.stderr" || exit 39
      [[ ! -s "$HOME/builtin.stdout" && -s "$HOME/builtin.stderr" ]] || exit 40
      print -r -- install-refused
    '
    [ "$status" -eq 0 ]
    [ "$output" = install-refused ]
    [ "$(file_identity "$PLUGINS_ROOT/foo")" = "$before_directory" ]
    [ "$(file_identity "$PLUGINS_ROOT/foo/foo-menu.zsh")" = "$before_entry" ]
    grep -Eq -- '(^|[^a-z0-9_-])foo([^a-z0-9_-]|$)' "$HOME/install.stderr"
    grep -Eiq -- 'namespace|overlap|conflict' "$HOME/install.stderr"
    run grep -E -- '(^|[[:space:]])(clone|fetch)([[:space:]]|$)' "$PLUGINS_GIT_LOG"
    [ "$status" -eq 1 ]
    [ -z "$(plugins_staging_left)" ]
  done
}
