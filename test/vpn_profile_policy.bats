#!/usr/bin/env bats
# Finite public-workflow models; no host VPN, hooks or DNS are run.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  export TERM=dumb NO_COLOR=1 F512P_ROOT="$HOME/f512-policy"
  export F512P_LIVE='SaveConfig = false' F512P_BACKUP='SaveConfig = false'
  export F512P_ACTIVE=wg0 F512P_ACTIVE_RC=0 F512P_EDITOR_RC=0 F512P_EDITOR_OFFER=yes
  export F512P_PLATFORM=linux F512P_ROOT_MODE=700 F512P_OMIT_LIVE=0 F512P_STRIP_RC=0
  unset WSL_DISTRO_NAME WSL_INTEROP VPN_MENU_WSL_IPV6_FIX
  unset F512P_CONTENT F512P_OWNER F512P_FLAG F512P_SCENE F512P_HOOK_SCENE F512P_TARGET
  unset F512P_READER_SCENE F512P_AFTER_AUTH
  mkdir -m 700 "$F512P_ROOT" || return 1
  export F512P_SUDO="$F512P_ROOT/allowlisted-sudo"
  export F512P_CACHE_WARM=0
  cp "$TEST_MOCK_BIN/sudo" "$F512P_SUDO" || return 1
  export MOCK_SUDO_ALLOW='true,__validate__,test,head,cksum,find,install,mktemp,ln,rm,mv,wg,wg-quick'
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/sudo" || return 1
  cat >> "$TEST_MOCK_BIN/sudo" <<'MOCK'
printf '%s\0' "$#" "$0" "$@" >> "$F512P_CASE/sudo.argv.nul" || exit 97
if [[ $# == 2 && "$1" == -n && "$2" == true ]]; then
  printf 'cache\n' >> "$F512P_CASE/cache.calls"
  [[ "$F512P_CACHE_WARM" == 1 || -e "$F512P_CASE/authenticated" ]] || exit 1
  exec "$F512P_SUDO" "$@"
fi
if [[ $# == 1 && "$1" == -v ]]; then
  printf 'auth\n' >> "$F512P_CASE/auth.calls"
  "$F512P_SUDO" "$@" || exit $?
  : > "$F512P_CASE/authenticated"
  if [[ "${F512P_AFTER_AUTH:-}" == active ]]; then
    printf 'wg0\n' > "$F512P_CASE/active" || exit 97
    printf 'fixture-activity-change\n' > "$F512P_CASE/active.fixture-change" || exit 97
  fi
  exit 0
fi
[[ $# -ge 3 && "$1" == -n && "$2" == -- ]] || exit 97
args=("$@")
shift 2
# Freeze the actually executed leaf; a same-basename sibling is not approved.
program="$1"; token="${program##*/}"; expected_program=""
while IFS= read -r -d '' known && IFS= read -r -d '' executable; do
  if [[ "$known" == "$token" ]]; then expected_program="$executable"; break; fi
done < "$F512P_TOOL_MAP"
[[ "$expected_program" == /* && -f "$expected_program" && -x "$expected_program" \
  && ( "$program" == "$token" || "$program" == "$expected_program" ) ]] || exit 97
args[2]="$expected_program"
path_operand() {
  local operand="$1" cursor="$1"
  [[ "$operand" == "$F512P_CASE/"* || "$operand" == "$TMPDIR/"* ]] || return 1
  [[ "$operand" != *[[:cntrl:]]* && "$operand" != */../* && "$operand" != */.. \
    && "$operand" != */./* && "$operand" != */. && "$operand" != *'//'* ]] || return 1
  while [[ "$cursor" != "$F512P_CASE" && "$cursor" != "$TMPDIR" ]]; do
    [[ ! -L "$cursor" ]] || return 1
    cursor="${cursor%/*}"
  done
}
case "$token" in
  test)
    [[ $# == 3 && "$2" == -[eLrw] ]] && path_operand "$3" || exit 97 ;;
  head)
    [[ $# == 5 && "$2" == -c && ( "$3" == 1048576 || "$3" == 1048577 ) && "$4" == -- ]] \
      && path_operand "$5" || exit 97 ;;
  cksum)
    [[ $# == 3 && "$2" == -- ]] && path_operand "$3" || exit 97 ;;
  find)
    [[ $# == 9 && "$3" == -maxdepth && "$4" == 1 && "$5" == -type && "$6" == f \
      && "$7" == -name && "$8" == '*.conf' && "$9" == -print ]] && path_operand "$2" || exit 97 ;;
  install)
    [[ $# == 10 && "$2" == -m && "$3" == 600 && "$4" == -o && "$5" == 0 \
      && "$6" == -g && "$7" == 0 && "$8" == -- ]] \
      && path_operand "$9" && path_operand "${10}" || exit 97 ;;
  mktemp)
    [[ $# == 2 && "$2" == "$VPN_CONFIG_DIR/.zdx-vpn-"*.XXXXXX ]] && path_operand "$2" || exit 97 ;;
  ln)
    [[ $# == 4 && "$2" == -- ]] && path_operand "$3" && path_operand "$4" || exit 97 ;;
  rm)
    [[ $# == 3 && "$2" == -- ]] && path_operand "$3" || exit 97 ;;
  mv)
    if [[ $# == 4 && "$2" == -- ]]; then path_operand "$3" && path_operand "$4" || exit 97
    elif [[ $# == 5 && "$2" == -f && "$3" == -- ]]; then path_operand "$4" && path_operand "$5" || exit 97
    else exit 97; fi ;;
  wg)
    [[ $# == 3 && "$2" == show && "$3" == interfaces && "$expected_program" == "$TEST_MOCK_BIN/wg" ]] || exit 97 ;;
  wg-quick)
    [[ $# == 3 && ( "$2" == down || "$2" == strip ) ]] && path_operand "$3" || exit 97 ;;
  *) exit 97 ;;
esac
case "$token" in install|mktemp|ln|rm|mv) printf '%s\n' "$token" >> "$F512P_CASE/mutation.calls" || exit 97 ;; esac
exec "$F512P_SUDO" "${args[@]}"
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/wg" || return 1
  cat >> "$TEST_MOCK_BIN/wg" <<'MOCK'
[[ "$0" == "$TEST_MOCK_BIN/wg" ]] || exit 97
printf '%s\0' "$#" "$0" "$@" >> "$F512P_CASE/wg.argv.nul" || exit 97
if [[ $# == 2 && "$1" == show && "$2" == interfaces ]]; then
  actual_modeled_return="$F512P_ACTIVE_RC"
  if [[ -e "$F512P_CASE/authenticated" && -n "${F512P_AFTER_AUTH:-}" ]]; then
    printf 'query\n' >> "$F512P_CASE/active.after-auth.calls" || exit 97
    case "$F512P_AFTER_AUTH" in
      active) actual_modeled_return=0 ;;
      unknown) actual_modeled_return=17 ;;
      stop143) actual_modeled_return=143 ;;
      *) exit 97 ;;
    esac
  fi
  cat "$F512P_CASE/active" || exit 97
  printf '%s\n' "$actual_modeled_return" > "$F512P_CASE/active.reached-configured-return" || exit 97
  exit "$actual_modeled_return"
fi
[[ $# == 1 && "$1" == --version ]] || exit 97
printf 'wireguard-tools fixture\n'
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/wg-quick" || return 1
  cat >> "$TEST_MOCK_BIN/wg-quick" <<'MOCK'
printf '%s\0' "$#" "$0" "$@" >> "$F512P_CASE/wg-quick.argv.nul" || exit 97
if [[ $# == 2 && "$1" == down && "$2" == "$VPN_CONFIG_DIR/wg0.conf" ]]; then
  : > "$F512P_CASE/active"
  exit 0
fi
if [[ $# == 2 && "$1" == strip && "$2" == "$TMPDIR/"* && -f "$2" && ! -L "$2" ]]; then
  cp "$2" "$F512P_CASE/strip-input.conf" || exit 97
  printf '%s\n' "$F512P_STRIP_RC" > "$F512P_CASE/strip.reached-configured-return"
  exit "$F512P_STRIP_RC"
fi
exit 97
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/sudoedit" || return 1
  cat >> "$TEST_MOCK_BIN/sudoedit" <<'MOCK'
target="$VPN_CONFIG_DIR/new0.conf"
[[ "$F512P_OWNER" != direct ]] || target="$VPN_CONFIG_DIR/wg0.conf"
[[ "$0" == "$TEST_MOCK_BIN/sudoedit" && $# == 3 && "$1" == -n && "$2" == -- \
  && "$3" == "$target" && -f "$target" && ! -L "$target" ]] || exit 97
printf '%s\0' "$#" "$0" "$@" >> "$F512P_CASE/editor.argv.nul" || exit 97
printf 'EDITOR-STDOUT\n'; printf 'EDITOR-STDERR\n' >&2
printf '%s\n' "$EUID" > "$F512P_CASE/editor.uid" || exit 97
printf '%s\n' "$F512P_EDITOR_RC" > "$F512P_CASE/editor.reached-configured-return" || exit 97
exit "$F512P_EDITOR_RC"
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/uname" || return 1
  cat >> "$TEST_MOCK_BIN/uname" <<'MOCK'
case "$*" in -s) printf 'Linux\n' ;; -r) printf 'fixture-linux\n' ;; -sr) printf 'Linux fixture-linux\n' ;; *) exit 97 ;; esac
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/sudo" "$TEST_MOCK_BIN/wg" "$TEST_MOCK_BIN/wg-quick" "$TEST_MOCK_BIN/sudoedit" "$TEST_MOCK_BIN/uname" || return 1
  export F512P_TOOL_MAP="$F512P_ROOT/selected-tools.nul"
  local tool executable
  : > "$F512P_TOOL_MAP" || return 1
  for tool in test head cksum find install mktemp ln rm mv wg wg-quick; do
    executable=$(type -P -- "$tool") || return 1
    [[ "$executable" == /* && "$executable" != *[[:cntrl:]]* && -f "$executable" && -x "$executable" ]] || return 1
    [[ "$tool" != wg || ( "$executable" == "$TEST_MOCK_BIN/wg" && ! -L "$executable" ) ]] || return 1
    printf '%s\0%s\0' "$tool" "$executable" >> "$F512P_TOOL_MAP" || return 1
  done
}

teardown() {
  cleanup_sandbox
}

f512p_profile() {
  printf '[Interface]\nPrivateKey = PRIVATE-FIXTURE=\nAddress = %s/24\n%b\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 192.0.2.1:51820\n' "$2" "$3" > "$1" || return 1
  chmod -- 600 "$1" || return 1
}

f512p_state() {
  local target metadata links digest parent entry
  for target in "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$VPN_MENU_REPORT_DIR" \
    "$VPN_CONFIG_DIR/wg0.conf" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" "$VPN_CONFIG_DIR/wg0.conf.pre-restore" \
    "$VPN_CONFIG_DIR/office.conf" "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu" "$VPN_CONFIG_DIR/office.conf.pre-restore" \
    "$VPN_CONFIG_DIR/new0.conf" "$VPN_CACHE_DIR/default-iface" "$VPN_CACHE_DIR/last-iface" "$F512P_CASE/active"; do
    if [[ -L "$target" ]]; then
      metadata=$(file_stat "$target" device inode uid gid mode) || return 21
      digest=$(readlink "$target") || return 22
      printf '%s\tlink:%s:%s\n' "$target" "$metadata" "$digest" || return 23
    elif [[ -f "$target" ]]; then
      metadata=$(file_stat "$target" device inode uid gid mode) || return 24
      links=$(file_links "$target") || return 25
      digest=$(sha256_file "$target") || return 26
      printf '%s\tregular:%s:%s:%s\n' "$target" "$metadata" "$links" "$digest" || return 27
    elif [[ -e "$target" ]]; then
      metadata=$(file_stat "$target" device inode uid gid mode) || return 28
      printf '%s\tnonregular:%s\n' "$target" "$metadata" || return 29
    else
      # Refuse an unreadable known ancestor instead of converting it to absence.
      parent="${target%/*}"
      while [[ "$parent" != "$HOME" && ! -e "$parent" && ! -L "$parent" ]]; do parent="${parent%/*}"; done
      [[ -d "$parent" && ! -L "$parent" && -r "$parent" && -x "$parent" ]] || return 30
      file_stat "$parent" device inode uid gid mode >/dev/null || return 31
      printf '%s\tabsent\n' "$target" || return 32
    fi
  done
  # Exact immediate membership catches unexpected sibling publication too.
  for parent in "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$VPN_MENU_REPORT_DIR"; do
    [[ -d "$parent" && ! -L "$parent" ]] || continue
    for entry in "$parent"/.[!.]* "$parent"/..?* "$parent"/*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      printf '%s\tmember:%s\n' "$parent" "${entry##*/}" || return 33
    done
  done
}

f512p_observe() {
  local name="$1" program="$2" wrapper=0
  export F512P_CASE="$F512P_ROOT/$name"
  export VPN_CONFIG_DIR="$F512P_CASE/profiles" VPN_CACHE_DIR="$F512P_CASE/cache" VPN_MENU_REPORT_DIR="$F512P_CASE/reports"
  mkdir -m 700 "$F512P_CASE" "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$VPN_MENU_REPORT_DIR" "$F512P_CASE/import" || return 1
  f512p_profile "$VPN_CONFIG_DIR/wg0.conf" 10.0.0.2 "$F512P_LIVE" || return 1
  if [[ -n "${F512P_CONTENT:-}" ]]; then printf '%s' "$F512P_CONTENT" > "$VPN_CONFIG_DIR/wg0.conf" || return 1; fi
  f512p_profile "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" 10.0.0.3 "$F512P_BACKUP" || return 1
  f512p_profile "$VPN_CONFIG_DIR/wg0.conf.pre-restore" 10.0.0.4 'SaveConfig = true' || return 1
  f512p_profile "$F512P_CASE/import/new0.conf" 10.0.0.9 '' || return 1
  printf 'wg0\n' > "$VPN_CACHE_DIR/default-iface" || return 1
  printf 'wg0\n' > "$VPN_CACHE_DIR/last-iface" || return 1
  chmod -- 600 "$VPN_CACHE_DIR/"* || return 1
  printf '%s' "$F512P_ACTIVE" > "$F512P_CASE/active" || return 1
  [[ "$F512P_OMIT_LIVE" == 0 ]] || rm -- "$VPN_CONFIG_DIR/wg0.conf" || return 1
  if [[ "$F512P_ROOT_MODE" == missing ]]; then
    rm -- "$VPN_CACHE_DIR/default-iface" "$VPN_CACHE_DIR/last-iface" || return 1
    rmdir -- "$VPN_CACHE_DIR" "$VPN_MENU_REPORT_DIR" || return 1
  else chmod -- "$F512P_ROOT_MODE" "$VPN_CACHE_DIR" "$VPN_MENU_REPORT_DIR" || return 1; fi
  cp "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" "$F512P_CASE/expected.backup" || return 1
  cp "$VPN_CONFIG_DIR/wg0.conf.pre-restore" "$F512P_CASE/expected.undo" || return 1
  if [[ -f "$VPN_CONFIG_DIR/wg0.conf" ]]; then cp "$VPN_CONFIG_DIR/wg0.conf" "$F512P_CASE/expected.live" || return 1; fi
  printf '%s\n' "$program" > "$F512P_CASE/action.zsh" || return 1
  f512p_state > "$F512P_CASE/state.before" || return 1
  if run_zsh '
    builtin source "$ZSH_CUSTOM/functions/vpn-menu.zsh" || return 90
    unfunction command
    builtin cd -- "$F512P_CASE" || return 90
    _VPN_PLATFORM="$F512P_PLATFORM"
    _vpn_is_wsl() { [[ "$F512P_PLATFORM" == wsl ]]; }
    _f512p_action() { builtin source "$F512P_CASE/action.zsh"; }
    local -i primary=0
    _f512p_action > "$F512P_CASE/stdout" 2> "$F512P_CASE/stderr" || primary=$?
    print -r -- "$primary" > "$F512P_CASE/primary.status" || return 98
    print -rn -- "${REPLY-}" > "$F512P_CASE/reply" || return 98
    return 0
  ' > "$F512P_CASE/wrapper.stdout" 2> "$F512P_CASE/wrapper.stderr"; then wrapper=0; else wrapper=$?; fi
  printf '%s\n' "$wrapper" > "$F512P_CASE/wrapper.status" || return 1
  f512p_state > "$F512P_CASE/state.after" || return 1
}

f512p_primary() {
  local dir="$1" wanted="$2" name
  for name in primary.status stdout stderr reply state.before state.after wrapper.status wrapper.stdout wrapper.stderr; do
    [[ -f "$dir/$name" && ! -L "$dir/$name" ]] || return 41
  done
  printf '%s\n' "$wanted" > "$dir/expected.status" || return 42
  cmp "$dir/expected.status" "$dir/primary.status" || return 43
  printf '0\n' > "$dir/expected.wrapper" || return 44
  cmp "$dir/expected.wrapper" "$dir/wrapper.status" || return 45
  [[ ! -s "$dir/wrapper.stdout" && ! -s "$dir/wrapper.stderr" ]] || return 46
  [[ ! -s "$dir/stdout" ]] || return 47
}

f512p_unchanged() {
  cmp "$1/state.before" "$1/state.after" || return 48
  [[ ! -e "$1/profiles/office.conf" && ! -L "$1/profiles/office.conf" \
    && ! -e "$1/profiles/office.conf.bak-vpn-menu" && ! -L "$1/profiles/office.conf.bak-vpn-menu" \
    && ! -e "$1/profiles/office.conf.pre-restore" && ! -L "$1/profiles/office.conf.pre-restore" ]] || return 49
}

f512p_no_mutation() {
  f512p_unchanged "$1" || return $?
  [[ ! -e "$1/mutation.calls" && ! -e "$1/auth.calls" && ! -e "$1/wg-quick.argv.nul" ]] || return 50
}

f512p_regular() {
  local metadata links
  [[ -f "$1" && ! -L "$1" ]] || return 81
  metadata=$(file_stat "$1" uid mode) || return 82
  links=$(file_links "$1") || return 83
  [[ "$metadata" == "$EUID:600" && "$links" == 1 ]] || return 84
  cmp "$2" "$1" || return 85
}

f512p_renamed_identity() {
  local original tail device inode current
  original=$(awk -F '\t' -v wanted="$2" '$1==wanted { print $2 }' "$1/state.before") || return 86
  [[ "$original" == regular:* ]] || return 87
  tail="${original#regular:}"; device="${tail%%:*}"; tail="${tail#*:}"; inode="${tail%%:*}"
  current=$(file_identity "$3") || return 88
  [[ "$current" == "$device:$inode" ]] || return 89
}

f512p_changed_family() {
  local dir="$1" owner="$2" suffix expected
  case "$owner" in
    rename)
      for suffix in '' .bak-vpn-menu .pre-restore; do
        expected=live
        case "$suffix" in .bak-vpn-menu) expected=backup ;; .pre-restore) expected=undo ;; esac
        [[ ! -e "$dir/profiles/wg0.conf$suffix" && ! -L "$dir/profiles/wg0.conf$suffix" ]] || return 91
        f512p_regular "$dir/profiles/office.conf$suffix" "$dir/expected.$expected" || return $?
        f512p_renamed_identity "$dir" "$dir/profiles/wg0.conf$suffix" "$dir/profiles/office.conf$suffix" || return $?
      done
      printf 'office\n' > "$dir/expected.pointer" || return 92
      f512p_regular "$dir/cache/default-iface" "$dir/expected.pointer" || return $?
      f512p_regular "$dir/cache/last-iface" "$dir/expected.pointer" || return $?
      ;;
    remove)
      for suffix in '' .bak-vpn-menu .pre-restore; do
        [[ ! -e "$dir/profiles/wg0.conf$suffix" && ! -L "$dir/profiles/wg0.conf$suffix" ]] || return 93
      done
      [[ ! -e "$dir/cache/default-iface" && ! -L "$dir/cache/default-iface" \
        && ! -e "$dir/cache/last-iface" && ! -L "$dir/cache/last-iface" ]] || return 94
      ;;
    restore)
      f512p_regular "$dir/profiles/wg0.conf" "$dir/expected.backup" || return $?
      f512p_regular "$dir/profiles/wg0.conf.bak-vpn-menu" "$dir/expected.backup" || return $?
      expected=undo
      [[ ! -f "$dir/expected.live" ]] || expected=live
      f512p_regular "$dir/profiles/wg0.conf.pre-restore" "$dir/expected.$expected" || return $?
      ;;
    *) return 95 ;;
  esac
  [[ -s "$dir/mutation.calls" && -s "$dir/auth.calls" ]] || return 96
}

f512p_credentials_unchanged() {
  local dir="$1" side
  # Only the explicitly modeled activity field is excluded; all typed credential
  # paths, root identities, sibling sets and both pointers remain authoritative.
  for side in before after; do
    [[ -f "$dir/state.$side" && ! -L "$dir/state.$side" ]] || return 105
    awk -F '\t' -v activity="$dir/active" '
      $1==activity { excluded++; next }
      { print }
      END { if(excluded!=1) exit 1 }
    ' "$dir/state.$side" > "$dir/credentials.$side" || return 105
  done
  cmp "$dir/credentials.before" "$dir/credentials.after" || return 106
}

@test "vpn profile policy: SaveConfig guards relevant files before active or unknown mutations" {
  local owner scene live backup active code flag expected dir program
  # All public cells finish before the first product assertion.
  for owner in rename remove restore; do
    for scene in active-true unknown-true inactive-true active-false unknown-false backup-only true-dry-run; do
      live='SaveConfig = true'; backup='SaveConfig = false'; active=wg0; code=0; flag=--yes
      case "$scene" in
        unknown-true) code=17 ;;
        inactive-true) active='' ;;
        active-false) live='SaveConfig = false' ;;
        unknown-false) live='SaveConfig = false'; code=17 ;;
        backup-only) live='SaveConfig = false'; backup='SaveConfig = true' ;;
        true-dry-run) flag=--dry-run ;;
      esac
      export F512P_LIVE="$live" F512P_BACKUP="$backup" F512P_ACTIVE="$active" F512P_ACTIVE_RC="$code" F512P_OWNER="$owner" F512P_FLAG="$flag"
      f512p_observe "saveconfig-$owner-$scene" '
        case "$F512P_OWNER" in
          rename) vpn-profile-rename wg0 office "$F512P_FLAG" ;;
          remove) vpn-profile-remove wg0 --with-backup "$F512P_FLAG" ;;
          restore) vpn-config-restore wg0 "$F512P_FLAG" ;;
        esac' || return 1
    done
  done
  for scene in both-true absent-active-true absent-unknown-true absent-inactive-true absent-active-false; do
    export F512P_LIVE='SaveConfig = true' F512P_BACKUP='SaveConfig = true' F512P_ACTIVE=wg0 F512P_ACTIVE_RC=0 F512P_OMIT_LIVE=0
    case "$scene" in
      absent-*) F512P_OMIT_LIVE=1 ;;
    esac
    case "$scene" in
      absent-unknown-true) F512P_ACTIVE_RC=17 ;;
      absent-inactive-true) F512P_ACTIVE='' ;;
      absent-active-false) F512P_BACKUP='SaveConfig = false' ;;
    esac
    f512p_observe "saveconfig-restore-$scene" 'vpn-config-restore wg0 --yes' || return 1
  done
  export F512P_OMIT_LIVE=0 F512P_ACTIVE_RC=0
  program=$(cat <<'ZSH'
if (( ! ${+functions[_vpn_saveconfig_from_text]} )); then
  print -r -- NEW_PATH_NOT_PRESENT_ON_BASE > "$F512P_CASE/parser.classification"
  return 0
fi
print -r -- CANDIDATE_ONLY_CLASSIFIER > "$F512P_CASE/parser.classification"
local text rc
local -a labels=(casefold last-false last-true peer other-section invalid missing-equals invalid-then-true comment absent nul control)
local -a texts=(
  $'[InTeRfAcE]\n SaVeCoNfIg = TrUe # note\r\n[Peer]\n'
  $'[Interface]\nSaveConfig=true\nSaveConfig=false\n[Peer]\n'
  $'[Interface]\nSaveConfig=false\nSaveConfig=true\n[Peer]\n'
  $'[Interface]\n[Peer]\nSaveConfig=true\n'
  $'[Interface]\n[other] = ignored\nSaveConfig=true\n'
  $'[Interface]\nSaveConfig=invalid\nSaveConfig=false\n'
  $'[Interface]\nSaveConfig\n[Peer]\n'
  $'[Interface]\nSaveConfig=invalid\nSaveConfig=true\n'
  $'[Interface]\n# SaveConfig=true\nSaveConfig = false # true\n'
  $'[Interface]\nAddress=10.0.0.2/24\n'
  $'[Interface]\nSaveConfig=tr\0ue\n'
  $'[Interface]\nSaveConfig=true\a\n'
)
local -i index=0
for text in "${texts[@]}"; do
  (( index += 1 )); REPLY=STALE; rc=0
  _vpn_saveconfig_from_text "$text" || rc=$?
  print -r -- "$rc:$REPLY" > "$F512P_CASE/parser-${labels[index]}" || return 98
 done
return 0
ZSH
  ) || return 1
  f512p_observe saveconfig-grammar "$program" || return 1
  export F512P_LIVE='SaveConfig = true' F512P_BACKUP='SaveConfig = false'
  export F512P_ACTIVE='' F512P_ACTIVE_RC=0 F512P_OMIT_LIVE=0
  program=$(cat <<'ZSH'
if (( ! ${+functions[_vpn_profile_saveconfig]} )); then
  print -r -- NEW_PATH_NOT_PRESENT_ON_BASE > "$F512P_CASE/reader.classification"
  return 0
fi
print -r -- CANDIDATE_ONLY_READER > "$F512P_CASE/reader.classification"
local leased_dir="" leased_file="" REPLY=""
leased_dir=$(_vpn_config_dir_identity) || return 98
leased_file=$(_vpn_profile_file_fingerprint "$VPN_CONFIG_DIR/wg0.conf" "reader fixture") || return 98
functions[_f512p_saved_readonly_exec]="${functions[_vpn_readonly_exec]}"
_f512p_read_model() {
  print -rn -- '[' || return 98
  case "$F512P_READER_SCENE" in
    partial0) return 0 ;; failed17) return 17 ;; timeout124) return 124 ;;
    stop130) return 130 ;; stop143) return 143 ;; *) return 98 ;;
  esac
}
_vpn_readonly_exec() {
  [[ $# == 6 && "$1" == 3 && "${2:t}" == head && "$3" == -c && "$4" == 1048577 \
    && "$5" == -- && "$6" == "$VPN_CONFIG_DIR/wg0.conf" ]] || return 98
  print -rN -- "$#" "$@" > "$F512P_CASE/reader.argv.nul" || return 98
  local -i actual_read_status=0
  case "$F512P_READER_SCENE" in
    complete|file-replaced|dir-replaced)
      _f512p_saved_readonly_exec "$@" > "$F512P_CASE/reader.raw" || actual_read_status=$?
      ;;
    *) _f512p_read_model > "$F512P_CASE/reader.raw" || actual_read_status=$? ;;
  esac
  print -r -- "$actual_read_status" > "$F512P_CASE/reader.seam.actual.status" || return 98
  case "$F512P_READER_SCENE" in
    file-replaced)
      command cp -- "$6" "$VPN_CONFIG_DIR/.replacement" || return 98
      command chmod -- 600 "$VPN_CONFIG_DIR/.replacement" || return 98
      command mv -- "$VPN_CONFIG_DIR/.replacement" "$6" || return 98
      print -r -- file > "$F512P_CASE/reader.fixture-change" || return 98
      ;;
    dir-replaced)
      command mv -- "$VPN_CONFIG_DIR" "$F512P_CASE/profiles-before-read" || return 98
      command mkdir -m 700 -- "$VPN_CONFIG_DIR" || return 98
      command cp -- "$F512P_CASE/profiles-before-read/"* "$VPN_CONFIG_DIR/" || return 98
      command chmod -- 600 "$VPN_CONFIG_DIR/"* || return 98
      print -r -- directory > "$F512P_CASE/reader.fixture-change" || return 98
      ;;
  esac
  command cat -- "$F512P_CASE/reader.raw" || return 98
  return "$actual_read_status"
}
local -i reader_status=0
REPLY=STALE
_vpn_profile_saveconfig "$VPN_CONFIG_DIR/wg0.conf" "$leased_dir" "$leased_file" || reader_status=$?
print -r -- "$reader_status" > "$F512P_CASE/reader.actual.status" || return 98
print -rn -- "$REPLY" > "$F512P_CASE/reader.actual.reply" || return 98
return 0
ZSH
  ) || return 1
  for scene in complete partial0 failed17 timeout124 stop130 stop143 file-replaced dir-replaced; do
    export F512P_READER_SCENE="$scene"
    f512p_observe "saveconfig-reader-$scene" "$program" || return 1
  done
  unset F512P_READER_SCENE
  program=$(cat <<'ZSH'
if (( ! ${+functions[_vpn_revalidate_saveconfig_inactive]} )); then
  print -r -- NEW_PATH_NOT_PRESENT_ON_BASE > "$F512P_CASE/activity.classification"
  return 0
fi
print -r -- CANDIDATE_ONLY_ACTIVITY > "$F512P_CASE/activity.classification"
case "$F512P_OWNER" in
  rename) vpn-profile-rename wg0 office --yes ;;
  remove) vpn-profile-remove wg0 --with-backup --yes ;;
  restore) vpn-config-restore wg0 --yes ;;
esac
ZSH
  ) || return 1
  for scene in rename-true-active remove-true-unknown restore-true-stop143 restore-false-active restore-absent-unknown; do
    export F512P_LIVE='SaveConfig = true' F512P_BACKUP='SaveConfig = false'
    export F512P_ACTIVE='' F512P_ACTIVE_RC=0 F512P_OWNER="${scene%%-*}" F512P_AFTER_AUTH="${scene##*-}"
    case "$scene" in
      restore-false-active) F512P_LIVE='SaveConfig = false' ;;
      restore-absent-unknown) F512P_LIVE=''; F512P_BACKUP='' ;;
    esac
    f512p_observe "saveconfig-auth-$scene" "$program" || return 1
  done
  unset F512P_AFTER_AUTH
  for owner in rename remove restore; do
    for scene in active-true unknown-true inactive-true active-false unknown-false backup-only true-dry-run; do
      dir="$F512P_ROOT/saveconfig-$owner-$scene"; expected=0
      case "$scene" in active-true|unknown-true|true-dry-run) expected=1 ;; backup-only) [[ "$owner" != restore ]] || expected=1 ;; esac
      f512p_primary "$dir" "$expected" || return $?
      if [[ "$expected" == 1 ]]; then
        f512p_no_mutation "$dir" || return $?
        grep -Eiq 'SaveConfig|activity.*(unknown|establish)|disconnect' "$dir/stderr" || return 51
        if grep -Fq 'Dry run:' "$dir/stderr"; then return 52; fi
      else f512p_changed_family "$dir" "$owner" || return $?; fi
      if grep -Fq PRIVATE-FIXTURE "$dir/stderr"; then return 53; fi
    done
  done
  for scene in both-true absent-active-true absent-unknown-true absent-inactive-true absent-active-false; do
    dir="$F512P_ROOT/saveconfig-restore-$scene"; expected=1
    case "$scene" in absent-inactive-true|absent-active-false) expected=0 ;; esac
    f512p_primary "$dir" "$expected" || return $?
    if [[ "$expected" == 1 ]]; then f512p_no_mutation "$dir" || return $?
    else f512p_changed_family "$dir" restore || return $?; fi
  done
  dir="$F512P_ROOT/saveconfig-grammar"
  f512p_primary "$dir" 0 || return $?
  if [[ $(cat "$dir/parser.classification") == CANDIDATE_ONLY_CLASSIFIER ]]; then
    [[ $(cat "$dir/parser-casefold") == 0:true && $(cat "$dir/parser-last-true") == 0:true ]] || return 54
    for scene in last-false peer other-section comment absent; do [[ $(cat "$dir/parser-$scene") == 0:false ]] || return 55; done
    for scene in invalid missing-equals invalid-then-true nul control; do [[ $(cat "$dir/parser-$scene") == 1: ]] || return 56; done
  else [[ $(cat "$dir/parser.classification") == NEW_PATH_NOT_PRESENT_ON_BASE ]] || return 57; fi
  for scene in complete partial0 failed17 timeout124 stop130 stop143 file-replaced dir-replaced; do
    dir="$F512P_ROOT/saveconfig-reader-$scene"
    f512p_primary "$dir" 0 || return $?
    if [[ $(cat "$dir/reader.classification") == NEW_PATH_NOT_PRESENT_ON_BASE ]]; then continue; fi
    [[ $(cat "$dir/reader.classification") == CANDIDATE_ONLY_READER ]] || return 107
    expected=1
    case "$scene" in complete) expected=0 ;; timeout124) expected=124 ;; stop130) expected=130 ;; stop143) expected=143 ;; esac
    [[ $(cat "$dir/reader.actual.status") == "$expected" ]] || return 108
    local seam_expected=0
    case "$scene" in failed17) seam_expected=17 ;; timeout124) seam_expected=124 ;; stop130) seam_expected=130 ;; stop143) seam_expected=143 ;; esac
    [[ $(cat "$dir/reader.seam.actual.status") == "$seam_expected" ]] || return 120
    if [[ "$scene" == partial0 || "$scene" == failed17 || "$scene" == timeout124 || "$scene" == stop* ]]; then
      printf '[' > "$dir/reader.expected-prefix" || return 121
      cmp "$dir/reader.expected-prefix" "$dir/reader.raw" || return 122
    fi
    if [[ "$scene" == complete ]]; then
      [[ $(cat "$dir/reader.actual.reply") == true ]] || return 109
      cmp "$dir/reader.raw" "$dir/expected.live" || return 110
    else [[ -f "$dir/reader.actual.reply" && ! -s "$dir/reader.actual.reply" ]] || return 111; fi
    case "$scene" in file-replaced|dir-replaced) [[ -s "$dir/reader.fixture-change" ]] || return 112 ;;
      *) f512p_unchanged "$dir" || return $? ;;
    esac
    [[ ! -e "$dir/auth.calls" && ! -e "$dir/mutation.calls" ]] || return 113
    if [[ "$scene" == partial0 ]]; then
      [[ $(cat "$dir/reader.seam.actual.status") == 0 ]] || return 114
      [[ $(file_size "$dir/reader.raw") -lt $(file_size "$dir/expected.live") ]] || return 115
    fi
  done
  for scene in rename-true-active remove-true-unknown restore-true-stop143 restore-false-active restore-absent-unknown; do
    dir="$F512P_ROOT/saveconfig-auth-$scene"
    if [[ $(cat "$dir/activity.classification") == NEW_PATH_NOT_PRESENT_ON_BASE ]]; then
      f512p_primary "$dir" 0 || return $?; continue
    fi
    [[ $(cat "$dir/activity.classification") == CANDIDATE_ONLY_ACTIVITY ]] || return 116
    expected=1
    case "$scene" in restore-true-stop143) expected=143 ;; restore-false-active|restore-absent-unknown) expected=0 ;; esac
    f512p_primary "$dir" "$expected" || return $?
    [[ $(wc -l < "$dir/auth.calls" | tr -d ' ') == 1 ]] || return 117
    case "$scene" in
      restore-false-active|restore-absent-unknown)
        [[ ! -e "$dir/active.after-auth.calls" ]] || return 118
        f512p_changed_family "$dir" restore || return $?
        ;;
      *)
        [[ -s "$dir/active.after-auth.calls" && ! -e "$dir/mutation.calls" && ! -e "$dir/wg-quick.argv.nul" ]] || return 119
        f512p_credentials_unchanged "$dir" || return $?
        ;;
    esac
  done

}

@test "vpn profile policy: create and import delegate editing after one consent" {
  local owner scene code dir wanted target program expected_heading
  program=$(cat <<'ZSH'
_vpn_prompt_profile_name() { print -r -- new0; }
_vpn_offer_set_default_profile() { return 0; }
_vpn_confirm_ask() {
  print -r -- "$1" >> "$F512P_CASE/prompts" || return 98
  if [[ "$1" == Open* ]]; then
    local target="$VPN_CONFIG_DIR/new0.conf"
    [[ "$F512P_OWNER" != direct ]] || target="$VPN_CONFIG_DIR/wg0.conf"
    if [[ ! -e "$F512P_CASE/committed.before-editor" ]]; then
      command cp -- "$target" "$F512P_CASE/committed.before-editor" || return 98
      if [[ "$F512P_SCENE" == replaced-after-offer ]]; then
        command cp -- "$target" "$VPN_CONFIG_DIR/.replacement" || return 98
        command chmod -- 600 "$VPN_CONFIG_DIR/.replacement" || return 98
        command mv -- "$VPN_CONFIG_DIR/.replacement" "$target" || return 98
      fi
    fi
    [[ "$F512P_EDITOR_OFFER" == yes ]] || return 1
  fi
  return 0
}
case "$F512P_OWNER" in
  create) vpn-profile-create new0 ;;
  import) vpn-profile-import "$F512P_CASE/import/new0.conf" ;;
  direct) vpn-config-edit wg0 ;;
esac
ZSH
  ) || return 1
  for owner in create import direct; do
    for scene in accept decline editor-failed replaced-after-offer; do
      code=0; [[ "$scene" != editor-failed ]] || code=17
      export F512P_EDITOR_RC="$code" F512P_EDITOR_OFFER=yes F512P_OWNER="$owner" F512P_SCENE="$scene"
      [[ "$scene" != decline ]] || export F512P_EDITOR_OFFER=no
      f512p_observe "editor-$owner-$scene" "$program" || return 1
    done
  done
  export F512P_PLATFORM=wsl F512P_EDITOR_OFFER=no F512P_EDITOR_RC=0
  f512p_observe editor-import-hardening-failed '
    _vpn_prompt_profile_name() { print -r -- new0; }
    _vpn_offer_set_default_profile() { return 0; }
    _vpn_confirm_ask() { print -r -- "$1" >> "$F512P_CASE/prompts" || return 98; [[ "$1" != Open* ]]; }
    _vpn_apply_wsl_dns_hooks() { print -r -- reached > "$F512P_CASE/hardening.reached" || return 98; return 17; }
    vpn-profile-import "$F512P_CASE/import/new0.conf"' || return 1
  for owner in create import direct; do
    for scene in accept decline editor-failed replaced-after-offer; do
      dir="$F512P_ROOT/editor-$owner-$scene"; wanted=0; target=new0
      if [[ "$owner" == direct ]]; then
        target=wg0
        case "$scene" in editor-failed|replaced-after-offer) wanted=1 ;; esac
      fi
      f512p_primary "$dir" "$wanted" || return $?
      [[ $(grep -c '^Open ' "$dir/prompts") == 1 ]] || return 58
      [[ $(grep -c '════' "$dir/stderr") == 1 ]] || return 59
      case "$owner" in create) expected_heading='Create VPN Profile (new0)' ;; import) expected_heading='Import VPN Profile (new0)' ;; direct) expected_heading='Edit VPN Configuration (wg0)' ;; esac
      grep -Fxq "════ $expected_heading ════" "$dir/stderr" || return 60
      if [[ "$scene" == decline || "$scene" == replaced-after-offer ]]; then
        [[ ! -e "$dir/editor.argv.nul" && ! -L "$dir/editor.argv.nul" ]] || return 61
      else
        f512p_editor_argv "$dir" "$target" || return $?
        grep -Fq EDITOR-STDOUT "$dir/stderr" || return 63
        grep -Fq EDITOR-STDERR "$dir/stderr" || return 64
        [[ $(cat "$dir/editor.uid") == "$EUID" ]] || return 65
      fi
      f512p_regular "$dir/profiles/$target.conf" "$dir/committed.before-editor" || return $?
      f512p_regular "$dir/profiles/wg0.conf.bak-vpn-menu" "$dir/expected.backup" || return $?
      f512p_regular "$dir/profiles/wg0.conf.pre-restore" "$dir/expected.undo" || return $?
      if [[ "$owner" == import ]]; then cmp "$dir/import/new0.conf" "$dir/profiles/new0.conf" || return 66; fi
    done
  done
  dir="$F512P_ROOT/editor-import-hardening-failed"
  f512p_primary "$dir" 1 || return $?
  [[ -f "$dir/hardening.reached" && ! -e "$dir/editor.argv.nul" ]] || return 67
  f512p_regular "$dir/profiles/new0.conf" "$dir/import/new0.conf" || return $?
}

@test "vpn profile policy: an explicitly inactive disconnect requests no credentials" {
  local scene code active
  for scene in inactive bare-empty active unknown interrupt130 interrupt143; do
    code=0; active=wg0
    case "$scene" in inactive) active=wg9 ;; bare-empty) active='' ;; unknown) code=17 ;; interrupt130) code=130 ;; interrupt143) code=143 ;; esac
    export F512P_ACTIVE="$active" F512P_ACTIVE_RC="$code" F512P_SCENE="$scene"
    f512p_observe "off-$scene" '
      _vpn_details_sections() { return 0; }
      if [[ "$F512P_SCENE" == bare-empty ]]; then vpn-off; else vpn-off wg0; fi' || return 1
  done
  for scene in inactive bare-empty active unknown interrupt130 interrupt143; do
    local dir="$F512P_ROOT/off-$scene" wanted=1
    case "$scene" in bare-empty|active) wanted=0 ;; interrupt130) wanted=130 ;; interrupt143) wanted=143 ;; esac
    f512p_primary "$dir" "$wanted" || return $?
    [[ -s "$dir/wg.argv.nul" ]] || return 65
    if [[ "$scene" == inactive || "$scene" == bare-empty || "$scene" == interrupt* ]]; then
      f512p_no_mutation "$dir" || return $?
      if grep -Fq 'Privileged operation:' "$dir/stderr"; then return 66; fi
    fi
    if [[ "$scene" == active ]]; then
      [[ -s "$dir/auth.calls" && -s "$dir/wg-quick.argv.nul" && ! -s "$dir/active" ]] || return 77
    fi
    if [[ "$scene" == inactive ]]; then
      grep -Fq 'not active' "$dir/stderr" || return 67
      if grep -Fq 'no longer active' "$dir/stderr"; then return 68; fi
    fi
  done
}

@test "vpn private state: unsafe existing roots are refused without permission repair" {
  local mode target
  export F512P_ACTIVE='' F512P_ACTIVE_RC=0
  for mode in 755 750 700 missing; do
    for target in cache report; do
      export F512P_ROOT_MODE="$mode" F512P_TARGET="$target"
      f512p_observe "roots-$target-$mode" '
        case "$F512P_TARGET" in
          cache) vpn-default-set wg0 ;;
          report) _vpn_report_root > "$F512P_CASE/resolved-root" ;;
        esac' || return 1
    done
  done
  for mode in 755 750 700 missing; do
    for target in cache report; do
      local dir="$F512P_ROOT/roots-$target-$mode" wanted=0
      [[ "$mode" == 755 || "$mode" == 750 ]] && wanted=1
      f512p_primary "$dir" "$wanted" || return $?
      if [[ "$wanted" == 1 ]]; then
        f512p_unchanged "$dir" || return $?
        [[ $(file_mode "$dir/cache") == "$mode" && $(file_mode "$dir/reports") == "$mode" ]] || return 69
        [[ ! -e "$dir/resolved-root" || ! -s "$dir/resolved-root" ]] || return 70
      else
        [[ $(file_mode "$dir/$([[ "$target" == cache ]] && printf cache || printf reports)") == 700 ]] || return 71
      fi
    done
  done
}

f512p_hooks_in_interface() {
  # Literal expected bytes are test data, separate from the production generator.
  [[ -f "$1" && ! -L "$1" && -f "$2" && ! -L "$2" ]] || return 100
  LC_ALL=C awk '
    NR==FNR { expected[++expected_count]=$0; next }
    { raw=$0; data=$0; sub(/#.*/, "", data); key=data; sub(/=.*/, "", key); gsub(/^[ \t\r]+|[ \t\r]+$/, "", key); key=tolower(key) }
    key ~ /^\[/ { section=(key == "[interface]" ? "interface" : "other") }
    raw == "# zdx: wsl-dns-hooks v1" { sentinel++; if(section!="interface" || raw!=expected[1]) bad=1; next_hook=2; next }
    next_hook { if(raw!=expected[next_hook]) bad=1; next_hook++; if(next_hook>3) next_hook=0 }
    key=="postup" || key=="postdown" { hooks++; if(section!="interface") bad=1 }
    key=="dns" && section=="interface" { bad=1 }
    END { if(bad || expected_count!=3 || sentinel!=1 || hooks!=2 || next_hook!=0) exit 1 }
  ' "$2" "$1" || return 101
}

f512p_editor_argv() {
  local dir="$1" target="$2"
  [[ -f "$dir/editor.argv.nul" && ! -L "$dir/editor.argv.nul" ]] || return 102
  printf '%s\0' 3 "$TEST_MOCK_BIN/sudoedit" -n -- "$dir/profiles/$target.conf" > "$dir/editor.expected.argv.nul" || return 103
  cmp "$dir/editor.expected.argv.nul" "$dir/editor.argv.nul" || return 104
}

@test "vpn private state: DNS hooks remain inside the actual Interface section" {
  local scene code dir wanted program hook_block
  export F512P_PLATFORM=wsl F512P_ROOT_MODE=700 F512P_ACTIVE='' F512P_ACTIVE_RC=0
  # Literal expected hook data, never executed and not copied from a generator.
  hook_block=$(cat <<'HOOKS'
# zdx: wsl-dns-hooks v1
PostUp = sh -c 'chattr -i /etc/resolv.conf 2>/dev/null || true; printf "nameserver 10.64.0.53\n" > /etc/resolv.conf; chattr +i /etc/resolv.conf 2>/dev/null || true'
PostDown = sh -c 'chattr -i /etc/resolv.conf 2>/dev/null || true; printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\n" > /etc/resolv.conf; chattr +i /etc/resolv.conf 2>/dev/null || true'
HOOKS
  ) || return 1
  printf '%s\n' "$hook_block" > "$F512P_ROOT/expected-hooks.block" || return 1
  program=$(cat <<'ZSH'
_vpn_test_resolv_conf() { return 0; }
command cp -- "$VPN_CONFIG_DIR/wg0.conf" "$F512P_CASE/hook.before" || return 98
local -i first_status=0 second_status=0
_vpn_apply_wsl_dns_hooks "$VPN_CONFIG_DIR/wg0.conf" || first_status=$?
if (( first_status == 0 )); then
  command cp -- "$VPN_CONFIG_DIR/wg0.conf" "$F512P_CASE/hook.first" || return 98
  _vpn_apply_wsl_dns_hooks "$VPN_CONFIG_DIR/wg0.conf" || second_status=$?
  print -r -- "$second_status" > "$F512P_CASE/idempotent.status" || return 98
fi
return "$first_status"
ZSH
  ) || return 1
  for scene in normal next-other peer-first interface-last casefold-crlf correct-existing misplaced-existing partial-sentinel imitated-sentinel absent-interface strip-failed strip130 strip143; do
    code=0
    case "$scene" in strip-failed) code=17 ;; strip130) code=130 ;; strip143) code=143 ;; esac
    export F512P_STRIP_RC="$code"
    case "$scene" in
      peer-first) F512P_CONTENT=$'[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n[Interface]\nPrivateKey = PRIVATE-FIXTURE=\nDNS = 10.64.0.53\n[Peer]\nPublicKey = SECOND=\n' ;;
      interface-last) F512P_CONTENT=$'[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n[Interface]\nPrivateKey = PRIVATE-FIXTURE=\nDNS = 10.64.0.53\n' ;;
      next-other) F512P_CONTENT=$'[Interface]\nPrivateKey = PRIVATE-FIXTURE=\nDNS = 10.64.0.53\n[Other]\nValue = literal\n[Peer]\nPublicKey = PEER=\n' ;;
      casefold-crlf) F512P_CONTENT=$'[iNtErFaCe] # note\r\nPrivateKey = PRIVATE-FIXTURE=\r\nDNS = 10.64.0.53 # retain-comment\r\n[pEeR]\r\nPublicKey = PEER=\r\n' ;;
      correct-existing) printf -v F512P_CONTENT '[Interface]\nPrivateKey = PRIVATE-FIXTURE=\n%s\n[Peer]\nPublicKey = PEER=\n' "$hook_block" ;;
      misplaced-existing) printf -v F512P_CONTENT '[Interface]\nPrivateKey = PRIVATE-FIXTURE=\n[Peer]\nPublicKey = PEER=\n%s\n' "$hook_block" ;;
      partial-sentinel) F512P_CONTENT=$'[Interface]\nPrivateKey = PRIVATE-FIXTURE=\n# zdx: wsl-dns-hooks v1\n[Peer]\nPublicKey = PEER=\n' ;;
      imitated-sentinel) F512P_CONTENT=$'[Interface]\nPrivateKey = PRIVATE-FIXTURE=\n# zdx: wsl-dns-hooks v1 trailing-imitation\n[Peer]\nPublicKey = PEER=\n' ;;
      absent-interface) F512P_CONTENT=$'[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n' ;;
      *) F512P_CONTENT=$'[Interface]\nPrivateKey = PRIVATE-FIXTURE=\nAddress = 10.0.0.2/24\nDNS = 10.64.0.53\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n' ;;
    esac
    export F512P_CONTENT
    f512p_observe "hooks-$scene" "$program" || return 1
  done
  for scene in normal next-other peer-first interface-last casefold-crlf correct-existing misplaced-existing partial-sentinel imitated-sentinel absent-interface strip-failed strip130 strip143; do
    dir="$F512P_ROOT/hooks-$scene"; wanted=0
    case "$scene" in misplaced-existing|partial-sentinel|imitated-sentinel|absent-interface|strip-failed) wanted=1 ;; strip130) wanted=130 ;; strip143) wanted=143 ;; esac
    f512p_primary "$dir" "$wanted" || return $?
    if [[ "$wanted" == 0 ]]; then
      f512p_hooks_in_interface "$dir/profiles/wg0.conf" "$F512P_ROOT/expected-hooks.block" || return $?
      [[ $(cat "$dir/idempotent.status") == 0 ]] || return 73
      cmp "$dir/hook.first" "$dir/profiles/wg0.conf" || return 74
      if [[ "$scene" == correct-existing ]]; then
        f512p_no_mutation "$dir" || return $?
      else
        [[ -s "$dir/strip-input.conf" && -s "$dir/mutation.calls" && -s "$dir/auth.calls" ]] || return 75
        f512p_hooks_in_interface "$dir/strip-input.conf" "$F512P_ROOT/expected-hooks.block" || return $?
      fi
    else
      cmp "$dir/hook.before" "$dir/profiles/wg0.conf" || return 76
      f512p_unchanged "$dir" || return $?
    fi
  done
}
