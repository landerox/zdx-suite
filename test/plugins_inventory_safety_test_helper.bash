# plugins_inventory_safety_test_helper.bash - candidate regression controls
# shellcheck disable=SC2016 # Literal Zsh programs expand in the child shell.
# Only test-owned capture paths and entrypoints are replaced or chmodded.

F307_SAFETY_FIND=$(type -P find)
F307_SAFETY_CAT=$(type -P cat)
F307_SAFETY_CHMOD=$(type -P chmod)
export F307_SAFETY_FIND F307_SAFETY_CAT F307_SAFETY_CHMOD

f307_safety_prepare() {
  export F307_SAFETY_SANDBOX="$TEST_TEMP_DIR" F307_SAFETY_TMP="$TMPDIR"
  export F307_SAFETY_DIR="$TMPDIR/f307-safety"
  export F307_FIFO_PROGRAM="$F307_SAFETY_DIR/fifo-case.zsh"
  mkdir -m 700 "$F307_SAFETY_DIR"
  cat > "$F307_FIFO_PROGRAM" <<'ZSH'
emulate -R zsh
cd "$HOME" || exit 89
source "$1/functions.zsh" >"$HOME/child-startup.stdout" 2>"$HOME/child-startup.stderr" || exit 90
independent-menu >"$HOME/child-live.stdout" 2>"$HOME/child-live.stderr" || exit 31
local old_loaded="${(j:,:)ZDX_LOADED_PLUGINS}" old_discovered="${(j:,:)ZDX_DISCOVERED_PLUGINS}"
local -A old_owners=("${(@kv)_ZDX_PLUGIN_STUBS}") old_bodies=()
local name="" value=""
for name in pending-menu pending-status pending-check independent-menu; do
  old_bodies[$name]="${functions[$name]-}"
done
typeset -g F307_FIFO_MODE="$2"

_f307_fifo_swap() {
  emulate -L zsh
  local capture_path="$1" expected_size="$2" directory="${1:h}" saved="$F307_SAFETY_DIR/original.log"
  local -A root_meta=() directory_meta=() log_meta=() fifo_meta=()
  [[ "$F307_SAFETY_SANDBOX" == "${HOME:h}" \
    && "$F307_SAFETY_TMP" == "$F307_SAFETY_SANDBOX/tmpdir" \
    && "$TMPDIR" == "$F307_SAFETY_TMP" && "$TMPDIR" == "${TMPDIR:A}" \
    && "$F307_SAFETY_DIR" == "$TMPDIR/f307-safety" \
    && "$capture_path" == /* && "$capture_path" == "${capture_path:a}" \
    && "${directory:h}" == "$TMPDIR" && "$directory" == "$_zdx_cap_dir" \
    && "$capture_path" == "$_zdx_cap_log" && ! -L "$directory" && ! -L "$capture_path" \
    && ! -e "$saved" && ! -L "$saved" ]] || return 91
  builtin zstat -LH root_meta -- "$TMPDIR" || return 92
  builtin zstat -LH directory_meta -- "$directory" || return 93
  builtin zstat -LH log_meta -- "$capture_path" || return 94
  (( (root_meta[mode] & 8#170777) == 8#040700 && root_meta[uid] == EUID \
    && (directory_meta[mode] & 8#170777) == 8#040700 && directory_meta[uid] == EUID \
    && (log_meta[mode] & 8#170777) == 8#100600 && log_meta[uid] == EUID \
    && log_meta[nlink] == 1 )) || return 95
  [[ "${log_meta[device]}:${log_meta[inode]}" == "$_zdx_cap_log_id" ]] || return 96
  if [[ "$expected_size" == positive ]]; then
    (( log_meta[size] > 0 )) || return 97
  else
    (( log_meta[size] == 0 )) || return 98
  fi
  # No mutation occurs before all private-root and genuine-metadata checks.
  command mv -- "$capture_path" "$saved" || return 101
  (umask 077; command mkfifo "$capture_path") || return 102
  builtin zstat -LH fifo_meta -- "$capture_path" || return 103
  (( (fifo_meta[mode] & 8#170777) == 8#010600 && fifo_meta[uid] == EUID )) || return 104
  print -rn -- "$capture_path"$'\0' > "$F307_SAFETY_DIR/fifo.path0"
  print -r -- "${fifo_meta[device]}:${fifo_meta[inode]}" > "$F307_SAFETY_DIR/fifo.identity"
  print -r -- "${log_meta[size]}" > "$F307_SAFETY_DIR/original.size"
  print -r -- "$F307_FIFO_MODE" > "$F307_SAFETY_DIR/swapped"
}

if [[ "$F307_FIFO_MODE" == write ]]; then
  functions[_f307_original_capture_open]="${functions[_zdx_capture_open]}"
  _zdx_capture_open() {
    _f307_original_capture_open "$@" || return $?
    if [[ "${funcstack[2]-}" == _zdx_plugin_inventory_observe \
      && ! -e "$F307_SAFETY_DIR/swapped" ]]; then
      _f307_fifo_swap "$_zdx_cap_log" zero || return $?
    fi
    return 0
  }
elif [[ "$F307_FIFO_MODE" == read ]]; then
  zstat() {
    emulate -L zsh
    local -a _f307_fifo_args=("$@")
    local -A _f307_fifo_meta=()
    local -i _f307_fifo_rc=0
    builtin zstat "$@" || _f307_fifo_rc=$?
    (( _f307_fifo_rc == 0 )) || return "$_f307_fifo_rc"
    if [[ "${funcstack[2]-}" == _zdx_plugin_inventory_observe \
      && -n "${_zdx_cap_log-}" && "${_f307_fifo_args[-1]-}" == "$_zdx_cap_log" \
      && ! -e "$F307_SAFETY_DIR/swapped" ]]; then
      builtin zstat -LH _f307_fifo_meta -- "$_zdx_cap_log" || return 105
      if (( _f307_fifo_meta[size] > 0 )); then
        # The caller already received real positive-size regular-file metadata.
        # Preserve those values; replace only the path before its read-open.
        _f307_fifo_swap "$_zdx_cap_log" positive || return $?
      fi
    fi
    return 0
  }
else
  exit 106
fi

local -i activation_rc=0
pending-menu >"$HOME/fifo.stdout" 2>"$HOME/fifo.stderr" || activation_rc=$?
(( activation_rc == 1 )) || exit 107
[[ -s "$F307_SAFETY_DIR/swapped" && ! -s "$HOME/fifo.stdout" ]] || exit 108
(( ! ${+PENDING_SOURCED} )) || exit 109
[[ "${INDEPENDENT_SOURCED-}" == 1 \
  && "${(j:,:)ZDX_LOADED_PLUGINS}" == "$old_loaded" \
  && "${(j:,:)ZDX_DISCOVERED_PLUGINS}" == "$old_discovered" ]] || exit 110
(( ${#_ZDX_PLUGIN_STUBS} == ${#old_owners} )) || exit 111
for name value in "${(@kv)old_owners}"; do
  [[ "${_ZDX_PLUGIN_STUBS[$name]-}" == "$value" ]] || exit 112
done
for name value in "${(@kv)old_bodies}"; do
  [[ "${functions[$name]-}" == "$value" ]] || exit 113
done
print -r -- refused-with-state > "$F307_SAFETY_DIR/child-complete"
exit "$activation_rc"
ZSH
}

# The payload is an executable Zsh, so timeout/gtimeout and the native Zsh
# watchdog both execute the actual public consumer. A shell function would
# be an unknown executable to GNU timeout and falsely return127.
f307_safety_fifo_case() {
  export F307_FIFO_MODE="$1"
  f307_shell lazy '
    local -i child_rc=0
    _zdx_run_with_timeout 10 "$F307_REAL_ZSH" -f "$F307_FIFO_PROGRAM" "$1" "$F307_FIFO_MODE" \
      >"$HOME/bounded.stdout" 2>"$HOME/bounded.stderr" || child_rc=$?
    case "$child_rc" in
      1) ;;
      0) print -u2 -r -- "The FIFO child unexpectedly succeeded."; exit 71 ;;
      *) print -u2 -r -- "Bounded FIFO child status: $child_rc"; exit "$child_rc" ;;
    esac
    [[ "$(<"$F307_SAFETY_DIR/child-complete")" == refused-with-state ]] || exit 72
    print -r -- bounded-refusal
  '
}

f307_safety_assert_fifo() {
  local mode="$1" path="" identity="" directory=""
  IFS= read -r -d '' path < "$F307_SAFETY_DIR/fifo.path0"
  directory="${path%/*}"
  [ "${directory%/*}" = "$TMPDIR" ]
  [ -p "$path" ]
  [ ! -L "$path" ]
  IFS= read -r identity < "$F307_SAFETY_DIR/fifo.identity"
  [ "$(file_identity "$path")" = "$identity" ]
  [ "$(cat "$F307_SAFETY_DIR/swapped")" = "$mode" ]
  [ "$(file_mode "$path")" = 600 ]
  if [[ "$mode" == read ]]; then
    [ "$(cat "$F307_SAFETY_DIR/original.size")" -gt 0 ]
    [ -s "$F307_SAFETY_DIR/original.log" ]
  else
    [ "$(cat "$F307_SAFETY_DIR/original.size")" -eq 0 ]
  fi
}

# Change execution trust only after genuine successful candidate-batch output.
# Managed reload additionally requires the new OID at the published path;
# neither a call ordinal nor an implementation-local transaction hash is used.
f307_safety_find_recorder() {
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/find"
  cat >> "$TEST_MOCK_BIN/find" <<'MOCK'
set -u
"$F307_SAFETY_FIND" "$@" > "$F307_SAFETY_DIR/find.native"
rc=$?
"$F307_SAFETY_CAT" "$F307_SAFETY_DIR/find.native" || exit 97
(( rc == 0 )) || exit "$rc"
[[ -s "$F307_SAFETY_DIR/armed" && ! -e "$F307_SAFETY_DIR/chmodded" ]] || exit 0
matched=0
for argument in "$@"; do
  [[ "$argument" != "$PLUGINS_ROOT/$F307_SAFETY_TARGET/." ]] || matched=1
done
(( matched )) || exit 0
if [[ -n "${F307_SAFETY_EXPECTED_OID:-}" ]]; then
  oid=$("$PLUGINS_REAL_GIT" -C "$PLUGINS_ROOT/$F307_SAFETY_TARGET" rev-parse HEAD) || exit 96
  [[ "$oid" == "$F307_SAFETY_EXPECTED_OID" ]] || exit 0
fi
entry="$PLUGINS_ROOT/$F307_SAFETY_TARGET/$F307_SAFETY_TARGET-menu.zsh"
[[ "$PLUGINS_ROOT" == "$F307_SAFETY_SANDBOX/home/.config/zdx/plugins" \
  && "$HOME" == "$F307_SAFETY_SANDBOX/home" \
  && "$F307_SAFETY_TARGET" != */* && -d "$PLUGINS_ROOT" && ! -L "$PLUGINS_ROOT" \
  && -d "$PLUGINS_ROOT/$F307_SAFETY_TARGET" && ! -L "$PLUGINS_ROOT/$F307_SAFETY_TARGET" \
  && -f "$entry" && ! -L "$entry" ]] || exit 95
[[ -s "$F307_SAFETY_DIR/find.native" ]] || exit 94
printf '%s\0' "$@" > "$F307_SAFETY_DIR/chmod.argv"
"$F307_SAFETY_CHMOD" -- 666 "$entry" || exit 93
printf '%s\0' "$entry" > "$F307_SAFETY_DIR/chmod.path0"
printf '%s\n' "${oid:-lazy}" > "$F307_SAFETY_DIR/chmodded"
exit 0
MOCK
  chmod -- 755 "$TEST_MOCK_BIN/find"
}
