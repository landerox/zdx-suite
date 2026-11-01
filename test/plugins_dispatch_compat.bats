#!/usr/bin/env bats
# shellcheck disable=SC2016
# Positive F306 preservation controls: availability never forces activation.

setup() {
  load test_helper
  load plugins_test_helper
  load plugins_ownership_test_helper
  mkdir -p "$PLUGINS_ROOT"
  chmod -- 700 "$PLUGINS_ROOT"
}

teardown() {
  cleanup_sandbox
}

@test "plugin dispatch compatibility: a trusted function present before discovery is called without activation" {
  f307_plugin foo
  local overrides="$HOME/.config/zdx/overrides.zsh"
  cat > "$overrides" <<'ZSH'
typeset -gi F307_COMPAT_OVERRIDE_SOURCES=$(( ${F307_COMPAT_OVERRIDE_SOURCES:-0} + 1 ))
foo-menu() {
  typeset -g F307_COMPAT_OVERRIDE_CALLED=1
  print -r -- "trusted override"
}
ZSH
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx"
  chmod -- 600 "$overrides"
  [ "$(file_mode "$overrides")" = 600 ]
  [ "$(file_links "$overrides")" -eq 1 ]
  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME \
    ZDX_EAGER_LOAD=0 ZDX_LAZY_LOAD=1 ZDX_PLUGINS_DIR="$PLUGINS_ROOT" \
    "$F307_REAL_ZSH" -f -c '
      emulate -R zsh
      cd "$HOME" || exit 89
      (( ! ${+_ZDX_FUNCTIONS_SOURCED} )) || exit 31
      unset F307_COMPAT_OVERRIDE_SOURCES
      # Deliberate fixture preload; the real core later validates/sources it.
      source "$HOME/.config/zdx/overrides.zsh" || exit 32
      local before="${functions[foo-menu]}"
      source "$1/functions.zsh" >"$HOME/startup.stdout" 2>"$HOME/startup.stderr" || exit 90
      (( F307_COMPAT_OVERRIDE_SOURCES == 2 )) || exit 43
      (( ${#ZDX_DISCOVERED_PLUGINS} == 1 && ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} )) || exit 33
      (( ${#ZDX_LOADED_PLUGINS} == 0 && ! ${+FOO_SOURCED} )) || exit 34
      (( ! ${+_ZDX_PLUGIN_STUBS[foo-menu]} )) || exit 35
      [[ "${_ZDX_PLUGIN_STUBS[foo-status]-}" == foo ]] || exit 36
      [[ "${functions[foo-menu]}" == "$before" && ! -s "$HOME/startup.stdout" ]] || exit 37
      zdx foo >"$HOME/dispatch.stdout" 2>"$HOME/dispatch.stderr" || exit 38
      [[ "$(<"$HOME/dispatch.stdout")" == "trusted override" && ! -s "$HOME/dispatch.stderr" ]] || exit 39
      [[ "${F307_COMPAT_OVERRIDE_CALLED-}" == 1 && "${functions[foo-menu]}" == "$before" ]] || exit 40
      (( ! ${+FOO_SOURCED} && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 41
      (( ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} )) || exit 42
      (( F307_COMPAT_OVERRIDE_SOURCES == 2 )) || exit 44
      local model=""
      model=$(_zdx_menu_model) || exit 45
      [[ "$model" == *"Open foo|foo|Available in this shell. Open the custom menu."* ]] || exit 46
      (( ! ${+FOO_SOURCED} && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 47
      print -r -- existing-function-called
    ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = existing-function-called ]
}

@test "plugin dispatch compatibility: a current-shell stub replacement receives literal argv without activation" {
  f307_plugin foo
  run f307_shell lazy '
    (( ${#ZDX_DISCOVERED_PLUGINS} == 1 && ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} )) || exit 31
    [[ "${_ZDX_PLUGIN_STUBS[foo-menu]-}" == foo ]] || exit 32
    local original_stub="${functions[foo-menu]}"
    foo-menu() {
      typeset -g F307_COMPAT_REPLACEMENT_CALLED=1
      printf "%s\0" "$@" > "$HOME/compat.received"
      print -r -- "trusted replacement"
    }
    local before="${functions[foo-menu]}"
    [[ "$before" != "$original_stub" ]] || exit 33
    local -a arguments=(
      "" "two words" $'\''line\nbreak'\''
      '\''$(touch "$HOME/compat-substitution")'\''
      '\''`touch "$HOME/compat-backticks"`'\''
      '\''; touch "$HOME/compat-semicolon"'\''
      "*"
    )
    zdx foo "${arguments[@]}" >"$HOME/dispatch.stdout" 2>"$HOME/dispatch.stderr" || exit 34
    [[ "$(<"$HOME/dispatch.stdout")" == "trusted replacement" && ! -s "$HOME/dispatch.stderr" ]] || exit 35
    [[ "${F307_COMPAT_REPLACEMENT_CALLED-}" == 1 && "${functions[foo-menu]}" == "$before" ]] || exit 36
    (( ! ${+FOO_SOURCED} && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 37
    (( ${ZDX_DISCOVERED_PLUGINS[(Ie)foo]} )) || exit 38
    [[ ! -e "$HOME/compat-substitution" && ! -e "$HOME/compat-backticks" && ! -e "$HOME/compat-semicolon" ]] || exit 39
    local model=""
    model=$(_zdx_menu_model) || exit 40
    [[ "$model" == *"Open foo|foo|Available in this shell. Open the custom menu."* ]] || exit 41
    (( ! ${+FOO_SOURCED} && ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 42
    print -r -- replacement-called-literally
  '
  [ "$status" -eq 0 ]
  [ "$output" = replacement-called-literally ]
  printf '%s\0' '' 'two words' $'line\nbreak' \
    '$(touch "$HOME/compat-substitution")' \
    '`touch "$HOME/compat-backticks"`' \
    '; touch "$HOME/compat-semicolon"' '*' > "$HOME/compat.expected"
  cmp "$HOME/compat.expected" "$HOME/compat.received"
}
