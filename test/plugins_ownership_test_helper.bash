# plugins_ownership_test_helper.bash - isolated cross-plugin ownership fixtures
# shellcheck disable=SC2016 # Literal Zsh programs expand in the child shell.
#
# Load test_helper and plugins_test_helper once, before installing the Git
# recorder. Reloading plugins_test_helper afterwards would record the recorder
# itself as PLUGINS_REAL_GIT and recursively execute it.

F307_REAL_ZSH=$(command -v zsh)
export F307_REAL_ZSH

# f307_plugin NAME: a regular plugin with a menu and two manifest commands.
# Its namespaced source flag observes activation without writing a source log.
f307_plugin() {
  local name="$1" flag="${1//-/_}"
  flag="${flag^^}_SOURCED"
  mkdir -p "$PLUGINS_ROOT/$name"
  chmod 700 "$PLUGINS_ROOT"
  chmod 755 "$PLUGINS_ROOT/$name"
  cat > "$PLUGINS_ROOT/$name/$name-menu.zsh" <<ZSH
typeset -g $flag=1
$name-menu() { print -r -- '$name menu'; }
$name-status() { print -r -- '$name status'; }
$name-check() { print -r -- '$name check'; }
_${name//-/_}_helper() { print -r -- '$name helper'; }
ZSH
  printf '%s\n' "$name-status" "$name-check" > "$PLUGINS_ROOT/$name/commands"
  chmod 644 "$PLUGINS_ROOT/$name/$name-menu.zsh" "$PLUGINS_ROOT/$name/commands"
}

# Run a fresh real shell with test-forced eager loading removed explicitly.
# MODE is lazy or eager; PROGRAM is static test code, never external input.
# The core is sourced before PROGRAM, so tests can exercise changed inventory
# after discovery without needing an arbitrary sleep or a second core load.
f307_shell() {
  local mode="$1" program="$2" eager=0
  [[ "$mode" == eager ]] && eager=1
  env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME \
    ZDX_EAGER_LOAD="$eager" ZDX_LAZY_LOAD=1 ZDX_PLUGINS_DIR="$PLUGINS_ROOT" \
    "$F307_REAL_ZSH" -f -c '
      emulate -R zsh
      cd "$HOME" || exit 89
      source "$1/functions.zsh" >"$HOME/startup.stdout" \
        2>"$HOME/startup.stderr" || exit 90
      '"$program" _ "$TEST_SUITE_ROOT"
}

# Each matrix case gets a new root; directory creation order never chooses
# the namespace owner. No earlier case's registry or tree can affect another.
f307_startup_matrix() {
  local mode="$1" pair left right order index=0 first second
  for pair in 'foo foo-bar' 'foo foo_bar' 'foo-bar foo_bar' \
    'foo-bar foo_bar-baz' 'foo-bar foo_bar_baz'; do
    read -r left right <<< "$pair"
    for order in forward reverse; do
      index=$((index + 1))
      export PLUGINS_ROOT="$HOME/matrix/$mode/$index/plugins"
      mkdir -p "$PLUGINS_ROOT"
      first="$left" second="$right"
      if [[ "$order" == reverse ]]; then
        first="$right" second="$left"
      fi
      f307_plugin "$first"
      f307_plugin "$second"
      f307_plugin independent
      export F307_LEFT="$left" F307_RIGHT="$right" F307_MODE="$mode"
      run f307_shell "$mode" '
        local name="" command_name="" source_flag=""
        for name in "$F307_LEFT" "$F307_RIGHT"; do
          (( ! ${ZDX_DISCOVERED_PLUGINS[(Ie)$name]} )) || exit 31
          (( ! ${ZDX_LOADED_PLUGINS[(Ie)$name]} )) || exit 32
          source_flag="${(U)${name//-/_}}_SOURCED"
          (( ! ${+parameters[$source_flag]} )) || exit 33
          for command_name in "${name}-menu" "${name}-status" "${name}-check"; do
            (( ! ${+functions[$command_name]} )) || exit 34
            (( ! ${+_ZDX_PLUGIN_STUBS[$command_name]} )) || exit 35
          done
          command_name="_${name//-/_}_helper"
          (( ! ${+functions[$command_name]} )) || exit 36
        done
        [[ "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == independent ]] || exit 37
        if [[ "$F307_MODE" == eager ]]; then
          [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == independent ]] || exit 38
          [[ "${INDEPENDENT_SOURCED-}" == 1 ]] || exit 39
        else
          (( ${#ZDX_LOADED_PLUGINS} == 0 )) || exit 40
          (( ! ${+INDEPENDENT_SOURCED} )) || exit 41
        fi
        [[ ! -s "$HOME/startup.stdout" ]] || exit 42
        print -r -- refused
      '
      # shellcheck disable=SC2154 # BATS run sets this status.
      [ "$status" -eq 0 ]
      # shellcheck disable=SC2154 # BATS run sets this captured output.
      [ "$output" = refused ]
      grep -Eq -- "(^|[^a-z0-9_-])${left}([^a-z0-9_-]|$)" "$HOME/startup.stderr"
      grep -Eq -- "(^|[^a-z0-9_-])${right}([^a-z0-9_-]|$)" "$HOME/startup.stderr"
      grep -Eiq -- 'namespace|overlap|conflict' "$HOME/startup.stderr"
    done
  done
}

# Capture effective fzf argv as NUL records, all rendered rows, and the exact
# isolated defaults passed to the executable. No action is executed by fzf.
f307_fzf_recorder() {
  export F307_FZF_DIR="$TEST_TEMP_DIR/f307-fzf"
  export F307_FZF_STATUS=130
  mkdir -p "$F307_FZF_DIR"
  : > "$F307_FZF_DIR/calls"
  : > "$F307_FZF_DIR/responses"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/fzf"
  cat >> "$TEST_MOCK_BIN/fzf" <<'MOCK'
set -eu
call=$(( $(wc -l < "$F307_FZF_DIR/calls") + 1 ))
printf '%s\n' "$call" >> "$F307_FZF_DIR/calls"
printf '%s\0' "$@" > "$F307_FZF_DIR/argv"
printf '%s\0' "${FZF_DEFAULT_OPTS-}" "${FZF_DEFAULT_OPTS_FILE-}" \
  "${FZF_DEFAULT_COMMAND-}" "${SHELL-}" > "$F307_FZF_DIR/environment"
cat > "$F307_FZF_DIR/rows"
response=$(sed -n "${call}p" "$F307_FZF_DIR/responses")
if [[ -n "$response" ]]; then
  printf '%s\n' "$response"
  exit 0
fi
exit "$F307_FZF_STATUS"
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
}
