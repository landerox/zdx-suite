# plugins_inventory_test_helper.bash - narrow plugin metadata fault fixtures
# shellcheck disable=SC2016 # Literal Zsh programs expand in the child shell.
#
# Load after the original plugins_ownership_test_helper, before the Git recorder.
# Programs remain static test text. Only the matching-entry zstat observation is
# replaced; no collector, namespace decision, source or manager is simulated.

f307_inventory_probes() {
  f307_plugin probe-one
  f307_plugin probe-two
}

# MODE is lazy/eager; ARM is startup/later. A missing probe entry always delegates
# to the real builtin. For two PRESENT probe entries, the first distinct entry
# must have a successful real zstat before the second one receives an I/O error.
# No directory ordering, permission bypass or ERRNO protocol is assumed.
f307_inventory_shell() {
  local mode="$1" arm="$2" program="$3" eager=0
  [[ "$mode" == eager ]] && eager=1
  env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME \
    ZDX_EAGER_LOAD="$eager" ZDX_LAZY_LOAD=1 ZDX_PLUGINS_DIR="$PLUGINS_ROOT" \
    F307_INVENTORY_INITIAL_ARM="$arm" \
    "$F307_REAL_ZSH" -f -c '
      emulate -R zsh
      cd "$HOME" || exit 89
      zmodload -F zsh/stat b:zstat || exit 91
      typeset -gi F307_INVENTORY_ENABLED=0 F307_INVENTORY_FAULTS=0
      typeset -g F307_INVENTORY_EARLIER_PATH="" F307_INVENTORY_FAULT_PATH=""
      zstat() {
        emulate -L zsh
        local -a _f307_inventory_args=("$@")
        local _f307_inventory_path="${_f307_inventory_args[-1]-}"
        if [[ "$F307_INVENTORY_ENABLED" == 1 \
          && ( "$_f307_inventory_path" == "$PLUGINS_ROOT/probe-one/probe-one-menu.zsh" \
            || "$_f307_inventory_path" == "$PLUGINS_ROOT/probe-two/probe-two-menu.zsh" ) \
          && -f "$_f307_inventory_path" && ! -L "$_f307_inventory_path" ]]; then
          if [[ -z "$F307_INVENTORY_EARLIER_PATH" ]]; then
            if builtin zstat "$@"; then
              F307_INVENTORY_EARLIER_PATH="$_f307_inventory_path"
              return 0
            else
              return $?
            fi
          elif [[ "$_f307_inventory_path" != "$F307_INVENTORY_EARLIER_PATH" ]]; then
            F307_INVENTORY_FAULT_PATH="$_f307_inventory_path"
            (( ++F307_INVENTORY_FAULTS ))
            print -u2 -r -- "f307: injected matching-entry metadata I/O failure"
            return 1
          fi
        fi
        builtin zstat "$@"
      }
      _f307_inventory_arm() {
        F307_INVENTORY_EARLIER_PATH=""
        F307_INVENTORY_FAULT_PATH=""
        F307_INVENTORY_FAULTS=0
        F307_INVENTORY_ENABLED=1
      }
      _f307_inventory_fault_proven() {
        [[ -n "$F307_INVENTORY_EARLIER_PATH" \
          && -n "$F307_INVENTORY_FAULT_PATH" \
          && "$F307_INVENTORY_EARLIER_PATH" != "$F307_INVENTORY_FAULT_PATH" \
          && -f "$F307_INVENTORY_EARLIER_PATH" && ! -L "$F307_INVENTORY_EARLIER_PATH" \
          && -f "$F307_INVENTORY_FAULT_PATH" && ! -L "$F307_INVENTORY_FAULT_PATH" ]] || return 1
        (( F307_INVENTORY_FAULTS > 0 )) || return 1
        return 0
      }
      _f307_inventory_snapshot() {
        emulate -L zsh
        typeset -ga F307_BEFORE_LOADED=("${ZDX_LOADED_PLUGINS[@]}")
        typeset -ga F307_BEFORE_DISCOVERED=("${ZDX_DISCOVERED_PLUGINS[@]}")
        typeset -gA F307_BEFORE_OWNERS=("${(@kv)_ZDX_PLUGIN_STUBS}")
        typeset -gA F307_BEFORE_BODIES=()
        local _f307_inventory_function=""
        for _f307_inventory_function in "${(@k)_ZDX_PLUGIN_STUBS}" "$@"; do
          (( ${+functions[$_f307_inventory_function]} )) || return 1
          F307_BEFORE_BODIES[$_f307_inventory_function]="${functions[$_f307_inventory_function]}"
        done
        return 0
      }
      _f307_inventory_preserved() {
        emulate -L zsh
        [[ "${(j:,:)ZDX_LOADED_PLUGINS}" == "${(j:,:)F307_BEFORE_LOADED}" \
          && "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == "${(j:,:)F307_BEFORE_DISCOVERED}" ]] || return 1
        (( ${#_ZDX_PLUGIN_STUBS} == ${#F307_BEFORE_OWNERS} )) || return 1
        local _f307_inventory_function=""
        for _f307_inventory_function in "${(@k)F307_BEFORE_OWNERS}"; do
          [[ "${_ZDX_PLUGIN_STUBS[$_f307_inventory_function]-}" \
            == "${F307_BEFORE_OWNERS[$_f307_inventory_function]}" ]] || return 1
        done
        for _f307_inventory_function in "${(@k)F307_BEFORE_BODIES}"; do
          [[ "${functions[$_f307_inventory_function]-}" \
            == "${F307_BEFORE_BODIES[$_f307_inventory_function]}" ]] || return 1
        done
        return 0
      }
      if [[ "$F307_INVENTORY_INITIAL_ARM" == startup ]]; then
        _f307_inventory_arm
      fi
      source "$1/functions.zsh" >"$HOME/startup.stdout" \
        2>"$HOME/startup.stderr" || exit 90
      '"$program" _ "$TEST_SUITE_ROOT"
}
