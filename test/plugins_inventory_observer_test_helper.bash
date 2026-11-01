# plugins_inventory_observer_test_helper.bash - external inventory observations
# Load after test_helper, plugins_test_helper and plugins_ownership_test_helper.
# Product policy stays real; only the selected external executable is wrapped.

F307_FIND_REAL=$(type -P find)
F307_FIND_CAT=$(type -P cat)
export F307_FIND_REAL F307_FIND_CAT

f307_find_recorder() {
  [[ "$F307_FIND_REAL" == /* && "$F307_FIND_CAT" == /* ]] || return 98
  export F307_FIND_TRACE="$TEST_TEMP_DIR/find-observer"
  export F307_FIND_CONTROL="$F307_FIND_TRACE/control"
  export F307_FIND_COUNT="$F307_FIND_TRACE/count"
  mkdir -m 700 "$F307_FIND_TRACE"
  printf '0\n' > "$F307_FIND_COUNT"
  : > "$F307_FIND_CONTROL"
  : > "$F307_FIND_TRACE/fired"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/find"
  cat >> "$TEST_MOCK_BIN/find" <<'MOCK'
set -u
count=0
IFS= read -r count < "$F307_FIND_COUNT" || exit 97
case "$count" in ''|*[!0-9]*) exit 97 ;; esac
count=$((count + 1))
printf '%s\n' "$count" > "$F307_FIND_COUNT"
printf '%s\0' "$@" > "$F307_FIND_TRACE/$count.argv"

# Preserve genuine output as evidence; a successful reader must not mask a
# failed producer. This wrapper never replaces the policy/collector helper.
"$F307_FIND_REAL" "$@" > "$F307_FIND_TRACE/$count.native"
native_rc=$?
(( native_rc == 0 )) || exit "$native_rc"
mode=none target=0
if [[ -s "$F307_FIND_CONTROL" ]]; then
  IFS=' ' read -r mode target < "$F307_FIND_CONTROL" || exit 97
fi
if [[ "$count" == "$target" && "$mode" == unterminated ]]; then
  # Remove exactly the final delimiter from otherwise genuine rows. Adding
  # a foreign row could test containment instead of framing by accident.
  previous='' row='' seen=0
  while IFS= read -r -d '' row; do
    if (( seen )); then
      printf '%s\0' "$previous" || exit 97
    fi
    previous="$row"
    seen=$((seen + 1))
  done < "$F307_FIND_TRACE/$count.native"
  (( seen > 0 )) || exit 97
  printf '%s' "$previous" || exit 97
  printf '%s %s\n' "$mode" "$count" > "$F307_FIND_TRACE/fired"
  exit 0
fi
"$F307_FIND_CAT" "$F307_FIND_TRACE/$count.native" || exit 97
[[ "$count" == "$target" ]] || exit 0
printf '%s %s\n' "$mode" "$count" > "$F307_FIND_TRACE/fired"
case "$mode" in
  after-error) printf 'fixture find failed after genuine output\n' >&2; exit 1 ;;
  status124) printf 'fixture timeout status after genuine output\n' >&2; exit 124 ;;
  empty-record) printf '\0' ;;
  cross-startpath) printf '%s\0' "$PLUGINS_ROOT/bad.dot/./bad.dot-menu.zsh" ;;
  *) printf 'invalid observer fixture mode\n' >&2; exit 97 ;;
esac
MOCK
  chmod -- 755 "$TEST_MOCK_BIN/find"
}

# Reset only fixture records; never reset product state or replace a helper.
f307_find_arm() {
  local mode="$1" call="$2"
  printf '0\n' > "$F307_FIND_COUNT"
  printf '%s %s\n' "$mode" "$call" > "$F307_FIND_CONTROL"
  : > "$F307_FIND_TRACE/fired"
}

f307_find_assert_fired() {
  local mode="$1" call="$2" actual=""
  IFS= read -r actual < "$F307_FIND_TRACE/fired"
  [ "$actual" = "$mode $call" ]
  [ -s "$F307_FIND_TRACE/$call.native" ]
  local row="" seen=0
  while IFS= read -r -d '' row; do
    seen=$((seen + 1))
  done < "$F307_FIND_TRACE/$call.native"
  [ "$seen" -gt 0 ]
  # read leaves a nonempty remainder for malformed unterminated output.
  [ -z "$row" ]
}

f307_find_assert_argv() {
  local call="$1" word="" index=0
  shift
  local -a actual=()
  while IFS= read -r -d '' word; do
    actual+=("$word")
  done < "$F307_FIND_TRACE/$call.argv"
  [ -z "$word" ]
  [ "${#actual[@]}" -eq "$#" ]
  for word in "$@"; do
    [ "${actual[index]}" = "$word" ]
    index=$((index + 1))
  done
}

# Startpath order is unspecified. Assert the exact set and fixed expression,
# so a split path, followed directory link, extra traversal or filter fails.
f307_find_assert_batch() {
  local call="$1" word="" start="" expected="" matches=0 index=0
  shift
  local -a actual=()
  while IFS= read -r -d '' word; do
    actual+=("$word")
  done < "$F307_FIND_TRACE/$call.argv"
  [ -z "$word" ]
  [ "${#actual[@]}" -eq "$(( $# + 6 ))" ]
  [ "${actual[0]}" = -P ]
  index=$(( ${#actual[@]} - 5 ))
  [ "${actual[index]}" = '!' ]
  [ "${actual[index + 1]}" = -name ]
  [ "${actual[index + 2]}" = . ]
  [ "${actual[index + 3]}" = -prune ]
  [ "${actual[index + 4]}" = -print0 ]
  for expected in "$@"; do
    matches=0
    for (( index=1; index <= $#; index++ )); do
      start="${actual[index]}"
      [[ "$start" != "$expected" ]] || matches=$((matches + 1))
    done
    [ "$matches" -eq 1 ]
  done
}

f307_find_assert_native_row() {
  local call="$1" expected="$2" row="" seen=0
  while IFS= read -r -d '' row; do
    [[ "$row" != "$expected" ]] || seen=1
  done < "$F307_FIND_TRACE/$call.native"
  [ -z "$row" ]
  [ "$seen" -eq 1 ]
}

# An actual executable PATH without find, not a command()/whence replacement.
# Include only the existing sandbox mocks and real support commands needed
# for source/help/removal. Never install a fake executable named find here.
f307_find_missing_path() {
  export F307_FIND_LIMITED_BIN="$TEST_TEMP_DIR/without-find"
  mkdir -m 700 "$F307_FIND_LIMITED_BIN"
  local name="" resolved=""
  for name in awk basename bash cat chmod cp cut date dirname env git grep head \
    id ln mkdir mktemp mv ps pwd readlink rm rmdir sed sleep sort tail timeout \
    gtimeout tr uname wc zsh; do
    resolved=$(type -P "$name") || continue
    ln -s "$resolved" "$F307_FIND_LIMITED_BIN/$name"
  done
}

f307_find_shell_without_find() {
  PATH="$F307_FIND_LIMITED_BIN" f307_shell "$@"
}
