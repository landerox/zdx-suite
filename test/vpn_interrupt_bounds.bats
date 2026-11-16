#!/usr/bin/env bats
# Independently collected finite cells preserve the whole matrix before assertions.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  vpn_pin_kernel Linux
  unset WSL_DISTRO_NAME WSL_INTEROP VPN_MENU_WSL_IPV6_FIX
  export TERM=dumb NO_COLOR=1
  export F511_ROOT="$HOME/f511" F511_STAGE=none F511_CODE=0 F511_PLATFORM=linux
  export F511_GROUP=mtu F511_OUTPUT=normal F511_COUNT=1 F511_REPLACE=none
  export F511_LOCAL_CACHE_RC=0 F511_LOCAL_PAYLOAD_RC=0 F511_LOCAL_HOST_SHORT_RC=0
  export F511_FIXTURE_BASH="$BASH"
  mkdir -m 700 "$F511_ROOT" || return 1
  printf '#!%s\n' "$BASH" > "$F511_ROOT/backend" || return 1
  cat >> "$F511_ROOT/backend" <<'MOCK'
tool="${0##*/}"
printf '%s\t%s\n' "$tool" "$*" >> "$F511_CASE/calls" || exit 97
printf '%s\0' "$0" "$@" >> "$F511_CASE/argv.nul" || exit 97
if [[ "$F511_GROUP" == mtu ]]; then
  stop=0
  case "$F511_STAGE:$tool:$*" in
    'route:ip:-4 route get '*|'route:route:-n get '*) stop=1 ;;
    'egress-mtu:ip:-o link show dev eth0'|'egress-mtu:ifconfig:eth0') stop=1 ;;
    'wireguard:wg:show interfaces') stop=1 ;;
    'tunnel-mtu:ip:-o link show dev wg0'|'tunnel-mtu:ifconfig:wg0') stop=1 ;;
  esac
  if (( stop )); then
    printf 'STOP\t%s\n' "$F511_STAGE" >> "$F511_CASE/calls" || exit 97
    printf '%s\n' "$F511_CODE" > "$F511_CASE/reached-configured-return" || exit 97
    exit "$F511_CODE"
  fi
  case "$tool:$*" in
    'ping:-V') printf 'ping from iputils 20240117\n' ;;
    ping:*)
      size=56 target=''
      while (( $# )); do
        case "$1" in -s) size="$2"; shift 2 ;; --) target="$2"; shift 2 ;; *) shift ;; esac
      done
      [[ "$target" == 192.0.2.1 ]] || exit 97
      printf 'PING %s (%s) %s(%s) bytes of data.\n' "$target" "$target" "$size" "$((size+28))"
      printf '%s bytes from %s: icmp_seq=1 ttl=55 time=0.1 ms\n' "$((size+8))" "$target"
      ;;
    'ip:-4 route get 192.0.2.1') printf '192.0.2.1 dev eth0 src 192.0.2.9\n' ;;
    'ip:-o link show dev eth0') printf '2: eth0: mtu 1500 qdisc noop\n' ;;
    'ip:-o link show dev wg0') printf '3: wg0: mtu 1420 qdisc noop\n' ;;
    'route:-n get 192.0.2.1') printf 'route to: 192.0.2.1\n  interface: eth0\n' ;;
    'ifconfig:eth0') printf 'eth0: flags=1 mtu 1500\n' ;;
    'ifconfig:wg0') printf 'wg0: flags=1 mtu 1420\n' ;;
    'wg:show interfaces') printf 'wg0\n' ;;
    *) exit 97 ;;
  esac
elif [[ "$F511_GROUP" == wsl ]]; then
  case "$tool:$*" in
    'wslinfo:--networking-mode') printf '%s' "$F511_MODE_TEXT"; code="$F511_MODE_RC" ;;
    'ip:-6 route show default') printf '%s' "$F511_ROUTE_TEXT"; code="$F511_ROUTE_RC" ;;
    *) exit 97 ;;
  esac
  printf '%s\t%s\n' "$tool" "$code" >> "$F511_CASE/reached-configured-returns" || exit 97
  exit "$code"
elif [[ "$F511_GROUP" == local ]]; then
  if IFS= read -r token; then printf 'open:%s\n' "$token" > "$F511_CASE/producer.stdin"
  else printf 'closed\n' > "$F511_CASE/producer.stdin"; fi
  case "$tool:$*" in
    'wg:show interfaces') [[ $# == 2 ]] || exit 97; printf 'wg0\n' ;;
    'wg:show wg0')
      [[ $# == 2 ]] || exit 97
      printf '%s\n' "${WG_HIDE_KEYS-unset}" > "$F511_CASE/wg.hide.keys"
      printf 'interface: wg0\n  private key: PRIVATE-LOCAL-CANARY\n  preshared key: PRESHARED-LOCAL-CANARY\n  public key: PUBLIC-LOCAL-CANARY\n'
      ;;
    'ip:-o addr show dev wg0') [[ $# == 5 ]] || exit 97; printf '3: wg0 inet 10.0.0.2/24 scope global wg0\n' ;;
    'ip:route get 1.1.1.1') [[ $# == 3 ]] || exit 97; printf '1.1.1.1 dev eth0 src 192.0.2.9\n' ;;
    *) exit 97 ;;
  esac
elif [[ "$F511_GROUP" == curl ]]; then
  printf '%s\0' "$@" > "$F511_CASE/curl.argv.nul" || exit 97
  cat > "$F511_CASE/curl.stdin" || exit 97
  case "$F511_OUTPUT" in
    normal) printf '{"ip":"203.0.113.7"}\n' ;;
    empty) : ;;
    excess) awk 'BEGIN { for (i=0;i<262145;i++) printf "x" }' ;;
    utf8-under) awk 'BEGIN { for (i=0;i<131072;i++) printf "\303\251" }' ;;
    utf8-over) awk 'BEGIN { for (i=0;i<131073;i++) printf "\303\251" }' ;;
    tail-over) awk 'BEGIN { for (i=0;i<262144;i++) printf "x"; printf "\n" }' ;;
    tail-under) printf 'OK\n\n' ;;
    *) exit 97 ;;
  esac
  printf 'PRIVATE-CHILD-DIAGNOSTIC-SECRET\n' >&2
  printf '%s\n' "$F511_CODE" > "$F511_CASE/reached-configured-return" || exit 97
  exit "$F511_CODE"
else
  if IFS= read -r token; then
    printf 'open:%s\n' "$token" > "$F511_CASE/producer.stdin"
  else
    printf 'closed\n' > "$F511_CASE/producer.stdin"
  fi
  printf 'PRIVATE-CHILD-DIAGNOSTIC-SECRET\n' >&2
  case "$F511_OUTPUT" in
    normal) printf 'PAYLOAD\n' ;;
    empty) : ;;
    excess) awk 'BEGIN { for (i=0;i<4097;i++) printf "x" }' ;;
    utf8-under) printf '\303\251' ;;
    utf8-over) printf '\303\251\303\251' ;;
    tail-over) printf 'ABC\n' ;;
    tail-under) printf 'AB\n\n' ;;
    *) exit 97 ;;
  esac
  printf '%s\n' "$F511_CODE" > "$F511_CASE/reached-configured-return" || exit 97
  exit "$F511_CODE"
fi
MOCK
  local tool
  for tool in ping ip wg route ifconfig wslinfo curl vpn-probe; do
    cp "$F511_ROOT/backend" "$TEST_MOCK_BIN/$tool" || return 1
    chmod -- 700 "$TEST_MOCK_BIN/$tool" || return 1
  done
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/hostname" || return 1
  cat >> "$TEST_MOCK_BIN/hostname" <<'MOCK'
if [[ "$F511_GROUP" == local ]]; then
  printf '%s\0' "$0" "$@" >> "$F511_CASE/local.argv.nul" || exit 97
  [[ $# == 0 || ( $# == 1 && "$1" == -s ) ]] || exit 97
  if [[ "${1-}" == -s && "$F511_LOCAL_HOST_SHORT_RC" != 0 ]]; then exit "$F511_LOCAL_HOST_SHORT_RC"; fi
fi
printf 'fixture-host\n'
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/date" || return 1
  cat >> "$TEST_MOCK_BIN/date" <<'MOCK'
if [[ "$F511_GROUP" == local ]]; then printf '%s\0' "$0" "$@" >> "$F511_CASE/local.argv.nul" || exit 97; fi
[[ $# == 1 ]] || exit 97
case "$1" in +%s) printf '1000\n' ;; +%Y-%m-%d_%H%M%S) printf '2026-02-01_010203\n' ;; +*) printf '2026-02-01 01:02:03 UTC\n' ;; *) exit 97 ;; esac
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/python3" || return 1
  printf '[[ "$*" == --version ]] || exit 97\nprintf "Python fixture\\n"\n' >> "$TEST_MOCK_BIN/python3" || return 1
  chmod -- 700 "$TEST_MOCK_BIN/hostname" "$TEST_MOCK_BIN/date" "$TEST_MOCK_BIN/python3" || return 1
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/sudo" || return 1
  cat >> "$TEST_MOCK_BIN/sudo" <<'MOCK'
printf '%s\0' "$0" "$@" >> "$F511_CASE/sudo.argv.nul" || exit 97
if [[ "$F511_GROUP" == local ]]; then
  if IFS= read -r token; then printf 'open:%s\n' "$token" >> "$F511_CASE/sudo.stdin"
  else printf 'closed\n' >> "$F511_CASE/sudo.stdin"; fi
  if [[ $# == 2 && "$1" == -n && "$2" == true ]]; then exit "$F511_LOCAL_CACHE_RC"; fi
  if [[ $# == 5 && "$1" == -n && "$2" == -- && "${3##*/}" == test && "$4" == -e && "$5" == "$VPN_CONFIG_DIR/wg0.conf" ]]; then
    printf 'test\n' >> "$F511_CASE/payload.site" || exit 97
    [[ "$F511_LOCAL_PAYLOAD_RC" == 0 ]] || printf 'PRIVATE-SUDO-PARTIAL\n'
    exit "$F511_LOCAL_PAYLOAD_RC"
  fi
  if [[ $# == 8 && "$1" == -n && "$2" == -- && "$3" == "$F511_STAT_ZSH" && "$4" == -f && "$5" == -c \
    && "$6" == "$F511_STAT_PROGRAM" && "$7" == zdx-vpn-stat && "$8" == "$VPN_CONFIG_DIR/wg0.conf" ]]; then
    printf 'metadata\n' >> "$F511_CASE/payload.site" || exit 97
    printf '1:2:1000:33152:1:33:100:100\n'
    exit 0
  fi
  exit 97
fi
if [[ $# == 2 && "$1" == -n && "$2" == true ]]; then [[ "$F511_GROUP" == nul ]]; exit $?; fi
if [[ "$F511_GROUP" == nul && $# == 9 && "$1" == -n && "$2" == -- && "${3##*/}" == find \
  && "$4" == "$VPN_CONFIG_DIR" && "$5" == -maxdepth && "$6" == 1 && "$7" == -type && "$8" == f && "$9" == -print0 ]]; then
  printf '%s\0%s\0' "$VPN_CONFIG_DIR/wg0.conf" "$VPN_CONFIG_DIR/wg9.conf"
  printf 'PRIVATE-SUDO-CHILD-DIAGNOSTIC\n' >&2
  exit 0
fi
exit 97
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/sudo" || return 1
}

teardown() {
  cleanup_sandbox
}

f511_state() {
  local target metadata links checksum directory
  for directory in "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR"; do
    [[ -d "$directory" && ! -L "$directory" && -r "$directory" && -x "$directory" ]] || return 41
    metadata=$(file_stat "$directory" device inode uid gid mode) || return 42
    printf 'directory:%s\t%s\n' "${directory##*/}" "$metadata" || return 43
  done
  for target in "$VPN_CONFIG_DIR/wg0.conf" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" \
    "$VPN_CONFIG_DIR/wg0.conf.pre-restore" "$VPN_CONFIG_DIR/wg9.conf" \
    "$VPN_CONFIG_DIR/office.conf" "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu" "$VPN_CONFIG_DIR/office.conf.pre-restore" \
    "$VPN_CACHE_DIR/default-iface" "$VPN_CACHE_DIR/last-iface"; do
    if [[ -L "$target" ]]; then
      metadata=$(file_stat "$target" device inode uid gid mode) || return 44
      checksum=$(readlink "$target") || return 45
      printf '%s\tsymlink:%s\t%s\n' "${target##*/}" "$metadata" "$checksum" || return 46
    elif [[ -f "$target" ]]; then
      metadata=$(file_stat "$target" device inode uid gid mode) || return 1
      links=$(file_links "$target") || return 1
      checksum=$(sha256_file "$target") || return 1
      printf '%s\t%s:%s\t%s\n' "${target##*/}" "$metadata" "$links" "$checksum" || return 1
    elif [[ -e "$target" ]]; then
      metadata=$(file_stat "$target" device inode uid gid mode) || return 47
      printf '%s\tnonregular:%s\n' "${target##*/}" "$metadata" || return 48
    else
      printf '%s\tabsent\n' "${target##*/}" || return 1
    fi
  done
}

f511_observe() {
  local name="$1" program="$2" wrapper=0
  export F511_CASE="$F511_ROOT/$name"
  export VPN_CONFIG_DIR="$F511_CASE/profiles" VPN_CACHE_DIR="$F511_CASE/cache" VPN_MENU_REPORT_DIR="$F511_CASE/reports"
  mkdir -m 700 "$F511_CASE" "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$VPN_MENU_REPORT_DIR" || return 1
  vpn_darwin_profile "$VPN_CONFIG_DIR" wg0 || return 1
  vpn_darwin_profile "$VPN_CONFIG_DIR" wg9 || return 1
  printf 'BACKUP-PRIVATE-CANARY\n' > "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" || return 1
  printf 'UNDO-PRIVATE-CANARY\n' > "$VPN_CONFIG_DIR/wg0.conf.pre-restore" || return 1
  printf 'wg0\n' > "$VPN_CACHE_DIR/default-iface" || return 1
  printf 'wg0\n' > "$VPN_CACHE_DIR/last-iface" || return 1
  chmod -- 600 "$VPN_CONFIG_DIR/"* "$VPN_CACHE_DIR/"* || return 1
  : > "$F511_CASE/calls" || return 1
  printf '%s\n' "$program" > "$F511_CASE/action.zsh" || return 1
  f511_state > "$F511_CASE/state.before" || return 1
  if run_zsh '
    builtin source "$ZSH_CUSTOM/functions/vpn-menu.zsh"
    unfunction command
    _VPN_PLATFORM="$F511_PLATFORM"
    _vpn_is_wsl() { [[ "$F511_PLATFORM" == wsl ]]; }
    _f511_action() { builtin source "$F511_CASE/action.zsh"; }
    local -i primary=0
    _f511_action > "$F511_CASE/stdout" 2> "$F511_CASE/stderr" || primary=$?
    print -r -- "$primary" > "$F511_CASE/primary.status" || return 98
    print -rn -- "$REPLY" > "$F511_CASE/reply" || return 98
    return 0
  ' > "$F511_CASE/wrapper.stdout" 2> "$F511_CASE/wrapper.stderr"; then wrapper=0; else wrapper=$?; fi
  printf '%s\n' "$wrapper" > "$F511_CASE/wrapper.status" || return 1
  f511_state > "$F511_CASE/state.after" || return 1
}

f511_primary() {
  local dir="$1" wanted="$2" name
  for name in primary.status stdout stderr wrapper.status wrapper.stdout wrapper.stderr reply state.before state.after; do
    [[ -f "$dir/$name" && ! -L "$dir/$name" ]] || return 31
  done
  printf '%s\n' "$wanted" > "$dir/expected.status" || return 32
  cmp "$dir/expected.status" "$dir/primary.status" || return 33
  printf '0\n' > "$dir/expected.wrapper" || return 34
  cmp "$dir/expected.wrapper" "$dir/wrapper.status" || return 35
  [[ ! -s "$dir/wrapper.stdout" && ! -s "$dir/wrapper.stderr" ]] || return 36
}

f511_unchanged() {
  cmp "$1/state.before" "$1/state.after" || return 37
  [[ ! -e "$1/profiles/office.conf" && ! -L "$1/profiles/office.conf" \
    && ! -e "$1/profiles/office.conf.bak-vpn-menu" && ! -L "$1/profiles/office.conf.bak-vpn-menu" \
    && ! -e "$1/profiles/office.conf.pre-restore" && ! -L "$1/profiles/office.conf.pre-restore" ]] || return 38
}

f511_moved() {
  local before after
  before=$(grep -F "$2"$'\t' "$1/state.before") || return 39
  after=$(grep -F "$3"$'\t' "$1/state.after") || return 39
  [[ "$before" == "$2"$'\t'* && "$after" == "$3"$'\t'* \
    && "${before#*$'\t'}" == "${after#*$'\t'}" ]] || return 40
}

# These finite callbacks model caller boundaries; their files record a reached
# configured return site. The surrounding primary.status records after return.
f511_profile_context() {
  cat <<'ZSH'
_vpn_ensure_profile_access() {
  print -r -- access >> "$F511_CASE/sites" || return 90
  [[ "$F511_STAGE" != access ]] || return "$F511_CODE"
  return 0
}
_vpn_active_interfaces() {
  reply=()
  if [[ "$F511_STAGE" == active ]]; then
    print -r -- active >> "$F511_CASE/sites" || return 90
    return "$F511_CODE"
  fi
  [[ "$F511_STAGE" != disconnect ]] || reply=(wg0)
  return 0
}
_vpn_ensure_sudo_access() {
  print -r -- authorization >> "$F511_CASE/sites" || return 90
  [[ "$F511_STAGE" != authorization ]] || return "$F511_CODE"
  return 0
}
_vpn_tunnel_down() {
  print -r -- disconnect >> "$F511_CASE/sites" || return 90
  return "$F511_CODE"
}
_vpn_sudo_exec() {
  local op="${1:t}"
  [[ "$op" == mv && $# == 4 && "$2" == -- && "$3" == "$VPN_CONFIG_DIR/"* && "$4" == "$VPN_CONFIG_DIR/"* ]] \
    || [[ "$op" == rm && $# == 3 && "$2" == -- && "$3" == "$VPN_CONFIG_DIR/"* ]] || return 97
  print -r -- "$*" >> "$F511_CASE/mutations" || return 90
  command "$@"
}
ZSH
}

@test "vpn interrupt bounds: rename and removal preserve stopped boundary statuses without family mutations" {
  local op stage code dir program expected
  export F511_PLATFORM=linux
  for op in rename remove; do
    for stage in access authorization disconnect; do
      export F511_STAGE="$stage"
      for code in 17 130 143; do
        export F511_CODE="$code"
        program=$(f511_profile_context) || return 1
        if [[ "$op" == rename ]]; then program+=$'\nvpn-profile-rename wg0 office --yes'
        else program+=$'\nvpn-profile-remove wg0 --with-backup --yes'; fi
        f511_observe "profile-$op-$stage-$code" "$program" || return 1
      done
    done
    # Ordinary active-state failure remains the existing explicit --yes
    # continuation control; raw stops must return before authorization/work.
    export F511_STAGE=active
    for code in 0 17 130 143; do
      export F511_CODE="$code"
      program=$(f511_profile_context) || return 1
      if [[ "$op" == rename ]]; then program+=$'\nvpn-profile-rename wg0 office --yes'
      else program+=$'\nvpn-profile-remove wg0 --with-backup --yes'; fi
      f511_observe "profile-$op-active-$code" "$program" || return 1
    done
    for stage in healthy declined unavailable; do
      export F511_STAGE="$stage" F511_CODE=0
      program=$(f511_profile_context) || return 1
      case "$stage" in
        declined) program+=$'\n_vpn_confirm_outcome() { print -r -- cancelled; }' ;;
        unavailable) program+=$'\n_vpn_confirm_outcome() { print -r -- unavailable; }' ;;
      esac
      if [[ "$op" == rename ]]; then program+=$'\nvpn-profile-rename wg0 office --yes'
      else program+=$'\nvpn-profile-remove wg0 --with-backup --yes'; fi
      f511_observe "profile-$op-$stage" "$program" || return 1
    done
  done
  for op in rename remove; do
    for stage in access authorization disconnect; do
      for code in 17 130 143; do
        dir="$F511_ROOT/profile-$op-$stage-$code"; expected="$code"
        [[ "$code" != 17 ]] || expected=1
        f511_primary "$dir" "$expected" || return $?
        f511_unchanged "$dir" || return $?
        [ "$(tail -n 1 "$dir/sites")" = "$stage" ]
        [ ! -e "$dir/mutations" ]
        [[ ! -s "$dir/stdout" ]] || return 60
      done
    done
    for stage in declined unavailable; do
      dir="$F511_ROOT/profile-$op-$stage"; expected=0
      [[ "$stage" != unavailable ]] || expected=1
      f511_primary "$dir" "$expected" || return $?
      f511_unchanged "$dir" || return $?
      [ ! -e "$dir/mutations" ]
    done
    for code in 0 17 130 143; do
      dir="$F511_ROOT/profile-$op-active-$code"; expected="$code"
      case "$code" in 0|17) expected=0 ;; esac
      f511_primary "$dir" "$expected" || return $?
      if [[ "$expected" != 0 ]]; then
        f511_unchanged "$dir" || return $?
        [ "$(tail -n 1 "$dir/sites")" = active ]
        [ ! -e "$dir/mutations" ]
      else
        [ "$(cat "$dir/sites")" = $'access\nactive\nauthorization' ]
        [ -s "$dir/mutations" ]
      fi
    done
    dir="$F511_ROOT/profile-$op-healthy"
    f511_primary "$dir" 0 || return $?
    [ -s "$dir/mutations" ]
    if [[ "$op" == rename ]]; then
      [ -f "$dir/profiles/office.conf" ]
      [ -f "$dir/profiles/office.conf.bak-vpn-menu" ]
      [ -f "$dir/profiles/office.conf.pre-restore" ]
      [ "$(cat "$dir/cache/default-iface")" = office ]
      [ "$(cat "$dir/cache/last-iface")" = office ]
      f511_moved "$dir" wg0.conf office.conf || return $?
      f511_moved "$dir" wg0.conf.bak-vpn-menu office.conf.bak-vpn-menu || return $?
      f511_moved "$dir" wg0.conf.pre-restore office.conf.pre-restore || return $?
    else
      [ ! -e "$dir/profiles/wg0.conf" ]
      [ ! -e "$dir/profiles/wg0.conf.bak-vpn-menu" ]
      [ ! -e "$dir/profiles/wg0.conf.pre-restore" ]
      [ ! -e "$dir/cache/default-iface" ]
      [ ! -e "$dir/cache/last-iface" ]
    fi
    [ -f "$dir/profiles/wg9.conf" ]
  done
}

@test "vpn interrupt bounds: partial rename counts three files and two failed pointers with one verdict" {
  local program dir name
  export F511_STAGE=healthy F511_CODE=0 F511_PLATFORM=linux
  program=$(f511_profile_context) || return 1
  program+=$'\n_vpn_remember_iface() { print -r -- last >> "$F511_CASE/pointers"; return 1; }\n_vpn_set_default_iface() { print -r -- default >> "$F511_CASE/pointers"; return 1; }\n_timed vpn-profile-rename vpn-profile-rename wg0 office --yes'
  f511_observe partial-rename "$program" || return 1
  dir="$F511_ROOT/partial-rename"
  f511_primary "$dir" 1 || return $?
  [[ ! -s "$dir/stdout" ]] || return 70
  [ "$(cat "$dir/pointers")" = $'last\ndefault' ]
  [ "$(cat "$dir/cache/default-iface")" = wg0 ]
  [ "$(cat "$dir/cache/last-iface")" = wg0 ]
  for name in wg0.conf wg0.conf.bak-vpn-menu wg0.conf.pre-restore; do [ ! -e "$dir/profiles/$name" ]; done
  for name in office.conf office.conf.bak-vpn-menu office.conf.pre-restore; do [ -f "$dir/profiles/$name" ]; done
  [ "$(cat "$dir/profiles/office.conf.bak-vpn-menu")" = BACKUP-PRIVATE-CANARY ]
  [ "$(cat "$dir/profiles/office.conf.pre-restore")" = UNDO-PRIVATE-CANARY ]
  f511_moved "$dir" wg0.conf office.conf || return $?
  f511_moved "$dir" wg0.conf.bak-vpn-menu office.conf.bak-vpn-menu || return $?
  f511_moved "$dir" wg0.conf.pre-restore office.conf.pre-restore || return $?
  [ "$(grep -c 'Rename completed with partial failures: 2 of 5 changes failed\.' "$dir/stderr")" -eq 1 ]
  [ "$(grep -c 'vpn:vpn-profile-rename completed with partial failures in .* (status 1)' "$dir/stderr")" -eq 1 ]
  [[ "$(tail -n 1 "$dir/stderr")" == *'vpn:vpn-profile-rename completed with partial failures in '* ]] || return 71
}

f511_curl_receipt() {
  local dir="$1" word glob_count=0 index=0
  local -a actual=() expected=(-q -fsS --proto =https --proto-redir =https --max-filesize 262144 --max-time 4 --connect-timeout 2 --config -)
  [[ -f "$dir/curl.argv.nul" && -f "$dir/curl.stdin" ]] || return 72
  while IFS= read -r -d '' word; do
    if [[ "$word" == --globoff || "$word" == -g ]]; then glob_count=$((glob_count+1))
    else actual+=("$word"); fi
  done < "$dir/curl.argv.nul"
  [[ "$glob_count" == 1 && "${#actual[@]}" == "${#expected[@]}" ]] || return 73
  for word in "${expected[@]}"; do
    [[ "${actual[$index]}" == "$word" ]] || return 74
    index=$((index+1))
  done
  printf 'url = "%s"\n' "$F511_URL" > "$dir/expected.stdin" || return 75
  cmp "$dir/expected.stdin" "$dir/curl.stdin" || return 76
  [[ "$(cat "$dir/stderr")" != *PRIVATE-CHILD-DIAGNOSTIC-SECRET* ]] || return 77
}

@test "vpn interrupt bounds: provider requests prevent globs bound bytes and keep private URL data off argv" {
  local url index=0 dir scene
  export F511_PLATFORM=linux F511_GROUP=curl F511_CODE=0 F511_OUTPUT=normal
  local -a valid=('https://example.com/json' 'https://example.com/path?name=value#part' \
    'https://[2001:db8::1]/json' 'https://[2001:db8::1]:443/status')
  local -a invalid=('https://example.com/json[1-5000]' 'https://example.com/{json,a,b}' \
    'https://example.com/json?fields=[1-5]' 'https://[2001:db8::1]/json?x={a,b}')
  for url in "${valid[@]}" "${invalid[@]}"; do
    export F511_URL="$url"; index=$((index+1))
    f511_observe "url-$index" '_vpn_validate_provider_url "$F511_URL"' || return 1
  done
  export F511_URL='https://example.com/json?token=FAKE_FIXTURE_CANARY&path=a%2Fb#fragment'
  for scene in normal empty excess failure int term utf8-under utf8-over tail-over tail-under; do
    export F511_OUTPUT=normal F511_CODE=0
    case "$scene" in empty|excess|utf8-under|utf8-over|tail-over|tail-under) export F511_OUTPUT="$scene" ;; failure) export F511_CODE=17 ;; int) export F511_CODE=130 ;; term) export F511_CODE=143 ;; esac
    f511_observe "curl-$scene" '
      local text="éé"
      [[ -o multibyte && ${#text} == 2 ]] || return 93
      print -r -- "$options[multibyte]|$LANG|${LC_ALL-unset}" > "$F511_CASE/options.before" || return 94
      local -i observed=0
      _vpn_curl_bounded "$F511_URL" 4 2 || observed=$?
      print -r -- "$options[multibyte]|$LANG|${LC_ALL-unset}" > "$F511_CASE/options.after" || return 94
      return "$observed"
    ' || return 1
  done
  export F511_OUTPUT=excess F511_CODE=0
  f511_observe curl-excess-producer 'command "$TEST_MOCK_BIN/curl" --qualification </dev/null' || return 1
  for scene in utf8-under utf8-over tail-over tail-under; do
    export F511_OUTPUT="$scene"
    f511_observe "curl-$scene-producer" 'command "$TEST_MOCK_BIN/curl" --qualification </dev/null' || return 1
  done
  for index in 1 2 3 4; do
    f511_primary "$F511_ROOT/url-$index" 0 || return $?
  done
  for index in 5 6 7 8; do
    f511_primary "$F511_ROOT/url-$index" 1 || return $?
  done
  f511_primary "$F511_ROOT/curl-excess-producer" 0 || return $?
  [ "$(file_size "$F511_ROOT/curl-excess-producer/stdout")" -eq 262145 ]
  [ "$(file_size "$F511_ROOT/curl-utf8-under-producer/stdout")" -eq 262144 ]
  [ "$(file_size "$F511_ROOT/curl-utf8-over-producer/stdout")" -eq 262146 ]
  f511_primary "$F511_ROOT/curl-tail-over-producer" 0 || return $?
  f511_primary "$F511_ROOT/curl-tail-under-producer" 0 || return $?
  [ "$(file_size "$F511_ROOT/curl-tail-over-producer/stdout")" -eq 262145 ]
  printf 'OK\n\n' > "$F511_ROOT/curl-tail-under-producer/expected.raw" || return 79
  cmp "$F511_ROOT/curl-tail-under-producer/expected.raw" "$F511_ROOT/curl-tail-under-producer/stdout" || return 79
  for scene in normal empty excess failure int term utf8-under utf8-over tail-over tail-under; do
    dir="$F511_ROOT/curl-$scene"
    case "$scene" in normal|empty|utf8-under|tail-under) index=0 ;; excess|utf8-over|tail-over) index=1 ;; failure) index=17 ;; int) index=130 ;; term) index=143 ;; esac
    f511_primary "$dir" "$index" || return $?
    f511_curl_receipt "$dir" || return $?
    cmp "$dir/options.before" "$dir/options.after" || return 79
    if [[ "$scene" == normal ]]; then
      printf '{"ip":"203.0.113.7"}\n' > "$dir/expected.raw" || return 79
      cmp "$dir/expected.raw" "$dir/stdout" || return 79
    elif [[ "$scene" == utf8-under ]]; then
      [ "$(file_size "$dir/stdout")" -eq 262144 ]
    elif [[ "$scene" == tail-under ]]; then
      printf 'OK\n\n' > "$dir/expected.raw" || return 79
      cmp "$dir/expected.raw" "$dir/stdout" || return 79
    else
      [[ ! -s "$dir/stdout" ]] || return 78
    fi
    f511_unchanged "$dir" || return $?
  done
}

f511_wsl_context() {
  cat <<'ZSH'
_VPN_PLATFORM=wsl
_vpn_is_wsl() { return 0; }
if [[ "$F511_STAGE" == absent ]]; then
  command() {
    [[ "$1" != -v || "$2" != wslinfo ]] || return 1
    builtin command "$@"
  }
fi
if [[ "$F511_OVERRIDE" == unset ]]; then unset VPN_MENU_WSL_IPV6_FIX
else VPN_MENU_WSL_IPV6_FIX="$F511_OVERRIDE"; fi
_vpn_ensure_profile_access() { return 0; }
_vpn_check_wg_quick() { return 0; }
_vpn_fix_ipv6_config() { print -r -- "$1" >> "$F511_CASE/rewrite"; }
_vpn_tunnel_up() { print -r -- "$1" >> "$F511_CASE/start"; }
_vpn_details_sections() { return 0; }
ZSH
}

f511_route_receipt() {
  local count
  [[ -f "$1/calls" && -f "$1/reached-configured-returns" ]] || return 84
  count=$(grep -Fxc -- $'ip\t-6 route show default' "$1/calls" || true)
  [[ "$count" == 1 ]] || return 85
  count=$(grep -Fxc -- "$(printf 'ip\t%s' "$2")" "$1/reached-configured-returns" || true)
  [[ "$count" == 1 ]] || return 86
}

# Companion caller protocol, not a claim that M10's real snapshot already
# returned these stops. Four actual consumers are menu/summary/report/restore.
f511_snapshot_context() {
  cat <<'ZSH'
_vpn_should_apply_wsl_ipv6_fix() { return 1; }
_vpn_check_ip_stack() { return 0; }
_vpn_have_sudo_cache() { return 1; }
_vpn_configs_access_state() { print -r -- direct; }
_vpn_wg_access_state() { print -r -- direct; }
_vpn_active_interfaces() { reply=(); return 0; }
_vpn_dns_resolvers() { return 1; }
_vpn_get_ip_info() { print -r -- provider >> "$F511_CASE/after-snapshot"; return 1; }
_vpn_get_ip_crosscheck() { return 1; }
_vpn_backup_state() { print -r -- backup >> "$F511_CASE/after-snapshot"; print -r -- available; }
_vpn_redacted_backup_excerpt() { return 0; }
_vpn_menu_rows() { print -r -- rows >> "$F511_CASE/after-snapshot"; print -r -- "Fixture|vpn-summary|Finite fixture.|"; }
_vpn_menu_context() { print -r -- fixture; }
_vpn_preview_render() { print -r -- fixture; }
fzf() { command cat >/dev/null; print -r -- picker >> "$F511_CASE/after-snapshot"; return 130; }
functions[_f511_snapshot_label]="${functions[_vpn_label]}"
_vpn_label() {
  [[ ! -e "$F511_CASE/snapshot-site" ]] || print -r -- label >> "$F511_CASE/after-snapshot" || return 90
  _f511_snapshot_label "$@"
}
_vpn_state_load() {
  print -r -- "$F511_SNAPSHOT_CODE" >> "$F511_CASE/snapshot-site" || return 90
  _VPN_MENU_PLATFORM=linux
  _VPN_MENU_CONFIG_ACCESS_STATE=direct
  _VPN_MENU_WG_ACCESS_STATE=direct
  _VPN_MENU_CONFIGS_KNOWN=0
  _VPN_MENU_ACTIVE_KNOWN=0
  _VPN_MENU_CONFIGS=()
  _VPN_MENU_ACTIVE_IFACES=()
  return "$F511_SNAPSHOT_CODE"
}
ZSH
}

@test "vpn interrupt bounds: WSL bounded observations distinguish absence unknown and returned interruptions" {
  local scene kind program dir expected expected_mode gate fix consumer code
  local -a scenes=(nat present absent missing failure timeout route-failure route-timeout mode-int mode-term route-int route-term override-off override-on)
  export F511_PLATFORM=wsl F511_GROUP=wsl
  for scene in "${scenes[@]}"; do
    export F511_MODE_TEXT=$'mirrored\n' F511_MODE_RC=0 F511_ROUTE_TEXT='' F511_ROUTE_RC=0 F511_STAGE=none F511_OVERRIDE=unset
    case "$scene" in
      nat) export F511_MODE_TEXT=$'nat\n' F511_ROUTE_TEXT='default via fe80::1 dev eth0' ;;
      present) export F511_ROUTE_TEXT='default via fe80::1 dev eth0' ;;
      absent) : ;;
      missing) export F511_STAGE=absent ;;
      failure) export F511_MODE_RC=17 F511_MODE_TEXT='' ;;
      timeout) export F511_MODE_RC=124 F511_MODE_TEXT='' ;;
      route-failure) export F511_ROUTE_RC=17 ;;
      route-timeout) export F511_ROUTE_RC=124 ;;
      mode-int) export F511_MODE_RC=130 F511_MODE_TEXT='' ;;
      mode-term) export F511_MODE_RC=143 F511_MODE_TEXT='' ;;
      route-int) export F511_ROUTE_RC=130 ;;
      route-term) export F511_ROUTE_RC=143 ;;
      override-off) export F511_OVERRIDE=0 F511_MODE_RC=130 ;;
      override-on) export F511_OVERRIDE=1 F511_MODE_RC=130 ;;
    esac
    for kind in mode gate public; do
      program=$(f511_wsl_context) || return 1
      case "$kind" in mode) program+=$'\n_vpn_wsl_networking_mode' ;; gate) program+=$'\n_vpn_should_apply_wsl_ipv6_fix' ;; public) program+=$'\nvpn-on wg0' ;; esac
      f511_observe "wsl-$scene-$kind" "$program" || return 1
    done
  done
  export F511_GROUP=capture F511_OUTPUT=normal F511_PLATFORM=linux
  for consumer in menu summary report restore; do
    export F511_CONSUMER="$consumer"
    for code in 0 2 130 143; do
      export F511_SNAPSHOT_CODE="$code" F511_CODE=0
      program=$(f511_snapshot_context) || return 1
      program+=$'\nlocal -i observed=0\ncase "$F511_CONSUMER" in menu) vpn-menu || observed=$? ;; summary) vpn-summary || observed=$? ;; report) vpn-report || observed=$? ;; restore) vpn-config-restore wg0 --dry-run || observed=$? ;; esac\nprint -rn -- "$_VPN_PREVIEW_DIR$_VPN_PREVIEW_DIR_IDENTITY" > "$F511_CASE/preview.after" || return 90\nreturn "$observed"'
      f511_observe "snapshot-$consumer-$code" "$program" || return 1
    done
  done
  for scene in "${scenes[@]}"; do
    expected_mode=mirrored; gate=0; fix=1; expected=0
    case "$scene" in
      nat) expected_mode=nat ;;
      present) gate=1; fix=0 ;;
      missing|failure|timeout) expected_mode=unknown ;;
      route-failure|route-timeout) gate=2; fix=0 ;;
      mode-int) expected=130; gate=130; fix=0 ;;
      mode-term) expected=143; gate=143; fix=0 ;;
      route-int) gate=130; fix=0 ;;
      route-term) gate=143; fix=0 ;;
      override-off) expected=130; gate=1; fix=0 ;;
      override-on) expected=130; gate=0; fix=1 ;;
    esac
    dir="$F511_ROOT/wsl-$scene-mode"
    f511_primary "$dir" "$expected" || return $?
    if [[ "$expected" == 0 ]]; then [ "$(cat "$dir/stdout")" = "$expected_mode" ]
    else [[ ! -s "$dir/stdout" ]] || return 80; fi
    dir="$F511_ROOT/wsl-$scene-gate"
    f511_primary "$dir" "$gate" || return $?
    [[ ! -s "$dir/stdout" ]] || return 81
    if [[ "$scene" == override-* ]]; then [ ! -s "$dir/calls" ]; fi
    if [[ "$scene" == nat || "$scene" == mode-int || "$scene" == mode-term ]]; then
      [[ "$(cat "$dir/calls")" != *'ip'* ]] || return 82
    fi
    case "$scene" in
      present|absent|missing|failure|timeout) f511_route_receipt "$dir" 0 || return $? ;;
      route-failure) f511_route_receipt "$dir" 17 || return $? ;;
      route-timeout) f511_route_receipt "$dir" 124 || return $? ;;
      route-int) f511_route_receipt "$dir" 130 || return $? ;;
      route-term) f511_route_receipt "$dir" 143 || return $? ;;
    esac
    dir="$F511_ROOT/wsl-$scene-public"; expected=0
    case "$gate" in 130|143) expected="$gate" ;; esac
    f511_primary "$dir" "$expected" || return $?
    [[ ! -s "$dir/stdout" ]] || return 83
    if [[ "$expected" != 0 ]]; then
      [ ! -e "$dir/start" ]; [ ! -e "$dir/rewrite" ]
    else
      [ "$(cat "$dir/start")" = wg0 ]
      if [[ "$fix" == 1 ]]; then [ "$(cat "$dir/rewrite")" = wg0 ]; else [ ! -e "$dir/rewrite" ]; fi
    fi
    case "$scene" in
      present|absent|missing|failure|timeout) f511_route_receipt "$dir" 0 || return $? ;;
      route-failure) f511_route_receipt "$dir" 17 || return $? ;;
      route-timeout) f511_route_receipt "$dir" 124 || return $? ;;
      route-int) f511_route_receipt "$dir" 130 || return $? ;;
      route-term) f511_route_receipt "$dir" 143 || return $? ;;
    esac
    f511_unchanged "$dir" || return $?
  done
  for consumer in menu summary report restore; do
    for code in 0 2 130 143; do
      dir="$F511_ROOT/snapshot-$consumer-$code"; expected="$code"
      case "$code" in 0|2) expected=0 ;; esac
      f511_primary "$dir" "$expected" || return $?
      [ "$(cat "$dir/snapshot-site")" = "$code" ]
      [[ ! -s "$dir/stdout" && ! -s "$dir/preview.after" ]] || return 87
      if [[ "$expected" == 0 ]]; then [ -s "$dir/after-snapshot" ]; else [ ! -e "$dir/after-snapshot" ]; fi
      f511_unchanged "$dir" || return $?
    done
  done
}

# This recorder executes only the finite sandbox leaf. It observes the leaf's
# returned status after execution; it does not measure a physical deadline.
f511_native_receipt() {
  local word index=0 matches=0
  local -a words=()
  [[ -f "$1/argv.nul" && -f "$1/timeout.argv.nul" ]] || return 87
  printf '%s\0' "$TEST_MOCK_BIN/vpn-probe" literal > "$1/expected.leaf.argv" || return 88
  cmp "$1/expected.leaf.argv" "$1/argv.nul" || return 89
  while IFS= read -r -d '' word; do words+=("$word"); done < "$1/timeout.argv.nul"
  while (( index + 2 < ${#words[@]} )); do
    if [[ "${words[$index]}" == 3 && "${words[$((index+1))]}" == "$TEST_MOCK_BIN/vpn-probe" \
      && "${words[$((index+2))]}" == literal ]]; then matches=$((matches+1)); fi
    index=$((index+1))
  done
  [[ "$matches" == 1 ]] || return 90
}

f511_timeout_context() {
  cat <<'ZSH'
_vpn_run_with_timeout() {
  printf "%s\0" "$@" >> "$F511_CASE/timeout.argv.nul" || return 90
  [[ "$1" == 3 && "$2" == /* && -x "$2" ]] || return 96
  print -r -- "$1"$'\t'"$2" >> "$F511_CASE/timeout.valid.calls" || return 90
  shift
  local unexpected=""
  if IFS= read -r unexpected; then
    print -r -- "open:$unexpected" > "$F511_CASE/timeout.stdin" || return 90
    return 98
  fi
  print -r -- closed > "$F511_CASE/timeout.stdin" || return 90
  local -i observed_rc=0
  "$@" || observed_rc=$?
  print -r -- "$1"$'\t'"$observed_rc" >> "$F511_CASE/timeout.leaf.post.tsv" || return 90
  print -r -- "$observed_rc" > "$F511_CASE/timeout.leaf.post.status" || return 90
  return "$observed_rc"
}

# MODEL: route the new external-adapter protocol to the same qualified finite
# recorder. Actual native backend selection is covered by the F512 controls.
if (( ${+functions[_vpn_external_exec]} )); then
  _vpn_external_exec() {
    local seconds="${1-}" REPLY=""
    (( $# >= 2 )) || return 2
    shift
    _vpn_cmd_path "$1" || return 127
    local program="$REPLY"
    shift
    _vpn_run_with_timeout "$seconds" "$program" "$@"
  }
fi

ZSH
}

f511_positive_budget() {
  local dir="$1" program="$2" line found=0 returned=0
  [[ -f "$dir/timeout.valid.calls" && -f "$dir/timeout.leaf.post.tsv" ]] || return 91
  while IFS= read -r line; do
    [[ "$line" == 3$'\t'/* ]] || return 92
    [[ "$line" != "3"$'\t'"$program" ]] || found=1
  done < "$dir/timeout.valid.calls"
  [[ "$found" == 1 ]] || return 93
  while IFS= read -r line; do
    [[ "$line" != "$program"$'\t'0 ]] || returned=1
  done < "$dir/timeout.leaf.post.tsv"
  [[ "$returned" == 1 ]] || return 94
}

f511_local_program() {
  cat <<'ZSH'
WG_HIDE_KEYS=caller-sentinel
local -i local_rc=0
case "$F511_LOCAL_OWNER" in
  wg-access) _vpn_wg_access_state || local_rc=$? ;;
  addresses) _vpn_iface_internal_addrs wg0 || local_rc=$? ;;
  route) _vpn_default_route || local_rc=$? ;;
  details) _vpn_get_iface_details wg0 || local_rc=$? ;;
  sudo-cache) _vpn_have_sudo_cache <<< finite-input || local_rc=$? ;;
  sudo-test) _vpn_sudo_probe test -e "$VPN_CONFIG_DIR/wg0.conf" <<< finite-input || local_rc=$? ;;
  sudo-stat)
    # Model only the selector protocol for the fixed privileged argv. The
    # engine is never executed, and no native root trust is established.
    printf '#!%s\nexit 97\n' "$F511_FIXTURE_BASH" > "$F511_CASE/stat-engine" || return 95
    command chmod -- 700 "$F511_CASE/stat-engine" || return 95
    _vpn_trusted_zsh() {
      print -r -- selector >> "$F511_CASE/stat.selector.calls" || return 1
      local selected="$F511_CASE/stat-engine"
      local -A state=()
      [[ "$selected" == /* && -f "$selected" && ! -L "$selected" && -x "$selected" ]] || return 1
      zmodload -F zsh/stat b:zstat || return 1
      zstat -LH state -- "$selected" || return 1
      (( state[uid] == EUID && state[mode] == 8#100700 && state[nlink] == 1 )) || return 1
      REPLY="$selected"
    }
    _vpn_trusted_zsh || return 95
    export F511_STAT_ZSH="$REPLY" F511_STAT_PROGRAM="$_VPN_STAT_PROBE_PROGRAM"
    print -r -- "$REPLY" > "$F511_CASE/selected.stat.zsh" || return 95
    _vpn_privileged_stat "$VPN_CONFIG_DIR/wg0.conf" || local_rc=$?
    ;;
  timestamp) _vpn_state_timestamp || local_rc=$? ;;
  report-name|report-name-fallback) _vpn_report_path || local_rc=$? ;;
  age) _vpn_human_age 940 || local_rc=$? ;;
  cache-default17) _vpn_sudo_probe test -e "$VPN_CONFIG_DIR/wg0.conf" || local_rc=$? ;;
  cache-explicit17) _vpn_sudo_probe --timeout 5 test -e "$VPN_CONFIG_DIR/wg0.conf" || local_rc=$? ;;
  payload17-raw) _vpn_sudo_probe test -e "$VPN_CONFIG_DIR/wg0.conf" || local_rc=$? ;;
  payload17-captured) _vpn_info_capture_bounded 4096 _vpn_sudo_probe test -e "$VPN_CONFIG_DIR/wg0.conf" || local_rc=$? ;;
esac
print -r -- "$WG_HIDE_KEYS" > "$F511_CASE/caller.wg.hide.keys" || return 95
return "$local_rc"
ZSH
}

@test "vpn interrupt bounds: diagnostic leaves use bounded closed input without changing callbacks or NUL streams" {
  local helper code program dir expected scene service qualification_rc owner mode
  # Qualify the actual Bash declaration/call boundary, not only copied bodies.
  declare -F f511_native_receipt >/dev/null || return 99
  dir="$F511_ROOT/native-helper-qualification"
  mkdir -m 700 "$dir" || return 98
  printf '%s\0' "$TEST_MOCK_BIN/vpn-probe" literal > "$dir/argv.nul" || return 98
  printf '%s\0' 3 "$TEST_MOCK_BIN/vpn-probe" literal > "$dir/timeout.argv.nul" || return 98
  qualification_rc=0
  f511_native_receipt "$dir" > "$dir/good.stdout" 2> "$dir/good.stderr" || qualification_rc=$?
  printf '%s\n' "$qualification_rc" > "$dir/good.status" || return 98
  printf '%s\0' "$TEST_MOCK_BIN/ip" literal > "$dir/argv.nul" || return 98
  qualification_rc=0
  f511_native_receipt "$dir" > "$dir/wrong-sibling.stdout" 2> "$dir/wrong-sibling.stderr" || qualification_rc=$?
  printf '%s\n' "$qualification_rc" > "$dir/wrong-sibling.status" || return 98
  export F511_GROUP=capture F511_OUTPUT=normal F511_CODE=0 F511_PLATFORM=linux
  program=$(f511_timeout_context) || return 1
  f511_observe timeout-qualified "$program"$'\n_vpn_run_with_timeout 3 "$TEST_MOCK_BIN/vpn-probe" literal </dev/null' || return 1
  f511_observe timeout-bad-budget "$program"$'\n_vpn_run_with_timeout 0 "$TEST_MOCK_BIN/vpn-probe" literal </dev/null' || return 1
  f511_observe timeout-bare "$program"$'\n_vpn_run_with_timeout 3 vpn-probe literal </dev/null' || return 1
  f511_observe timeout-open "$program"$'\n_vpn_run_with_timeout 3 "$TEST_MOCK_BIN/vpn-probe" literal <<< finite-input' || return 1
  for code in 0 17 124 130 143; do
    export F511_CODE="$code" F511_OUTPUT=normal
    f511_observe "capture-producer-$code" 'command "$TEST_MOCK_BIN/vpn-probe" literal </dev/null' || return 1
    for helper in _vpn_info_capture_bounded _vpn_darwin_capture; do
      export F511_CAPTURE="$helper"
      f511_observe "capture-$helper-$code" "$program"$'\n"$F511_CAPTURE" 4096 command "$TEST_MOCK_BIN/vpn-probe" literal <<< finite-input' || return 1
    done
  done
  export F511_CODE=0
  for scene in empty excess; do
    export F511_OUTPUT="$scene"
    f511_observe "capture-producer-$scene" 'command "$TEST_MOCK_BIN/vpn-probe" literal </dev/null' || return 1
    for helper in _vpn_info_capture_bounded _vpn_darwin_capture; do
      export F511_CAPTURE="$helper"
      f511_observe "capture-$helper-$scene" "$program"$'\n"$F511_CAPTURE" 4096 command "$TEST_MOCK_BIN/vpn-probe" literal <<< finite-input' || return 1
    done
  done
  for service in core standalone; do
    export F511_SERVICE="$service"
    for scene in normal empty excess; do
      export F511_OUTPUT="$scene"
      f511_observe "callback-$service-$scene" '
        if [[ "$F511_SERVICE" == standalone ]]; then unfunction _zdx_run_with_timeout; fi
        _f511_callback() {
          case "$F511_OUTPUT" in normal) print -rn -- PAYLOAD ;; empty) return 0 ;; excess) print -rn -- 123456789 ;; esac
        }
        _vpn_info_capture_bounded 8 _f511_callback
      ' || return 1
    done
  done
  export F511_GROUP=nul F511_OUTPUT=normal F511_CODE=0
  f511_observe retained-copy-nul '_vpn_sudo_probe --timeout 5 find "$VPN_CONFIG_DIR" -maxdepth 1 -type f -print0' || return 1
  export F511_GROUP=local F511_LOCAL_CACHE_RC=0 F511_LOCAL_PAYLOAD_RC=0
  for owner in wg-access addresses route details sudo-cache sudo-test sudo-stat timestamp report-name report-name-fallback age; do
    export F511_LOCAL_OWNER="$owner" F511_LOCAL_HOST_SHORT_RC=0
    [[ "$owner" != report-name-fallback ]] || export F511_LOCAL_HOST_SHORT_RC=17
    program=$(f511_timeout_context) || return 1
    program+=$'\n'"$(f511_local_program)"
    f511_observe "local-$owner" "$program" || return 1
  done
  for owner in cache-default17 cache-explicit17 payload17-raw payload17-captured; do
    export F511_LOCAL_OWNER="$owner" F511_LOCAL_CACHE_RC=0 F511_LOCAL_PAYLOAD_RC=0
    case "$owner" in cache-*) export F511_LOCAL_CACHE_RC=17 ;; payload*) export F511_LOCAL_PAYLOAD_RC=17 ;; esac
    # Explicit five-second inventory transport retains its existing service;
    # the local three-second recorder intentionally cannot accept that mode.
    program=$(f511_local_program) || return 1
    if [[ "$owner" != cache-explicit17 ]]; then program="$(f511_timeout_context)"$'\n'"$program"; fi
    f511_observe "local-$owner" "$program" || return 1
  done
  export F511_GROUP=capture F511_CODE=0
  for scene in utf8-under utf8-over; do
    export F511_OUTPUT="$scene"
    f511_observe "capture-producer-$scene" 'command "$TEST_MOCK_BIN/vpn-probe" literal </dev/null' || return 1
    for helper in _vpn_info_capture_bounded _vpn_darwin_capture; do
      export F511_CAPTURE="$helper"
      program=$(f511_timeout_context) || return 1
      program+=$'\n'"$(cat <<'ZSH'
local text="éé"
[[ -o multibyte && ${#text} == 2 ]] || return 93
print -r -- "$options[multibyte]|$LANG|${LC_ALL-unset}" > "$F511_CASE/options.before" || return 94
local -i observed=0
"$F511_CAPTURE" 3 command "$TEST_MOCK_BIN/vpn-probe" literal || observed=$?
print -r -- "$options[multibyte]|$LANG|${LC_ALL-unset}" > "$F511_CASE/options.after" || return 94
return "$observed"
ZSH
)"
      f511_observe "capture-$helper-$scene" "$program" || return 1
    done
  done
  for scene in tail-over tail-under; do
    export F511_OUTPUT="$scene"
    f511_observe "capture-producer-$scene" 'command "$TEST_MOCK_BIN/vpn-probe" literal </dev/null' || return 1
    for helper in _vpn_info_capture_bounded _vpn_darwin_capture; do
      export F511_CAPTURE="$helper" F511_TAIL_MAX=3
      [[ "$scene" != tail-under ]] || export F511_TAIL_MAX=4
      program=$(f511_timeout_context) || return 1
      f511_observe "capture-$helper-$scene" "$program"$'\n"$F511_CAPTURE" "$F511_TAIL_MAX" command "$TEST_MOCK_BIN/vpn-probe" literal' || return 1
    done
  done
  for service in core standalone; do
    export F511_SERVICE="$service"
    f511_observe "callback-$service-multibyte" '
      if [[ "$F511_SERVICE" == standalone ]]; then unfunction _zdx_run_with_timeout; fi
      local text="éé"
      [[ -o multibyte && ${#text} == 2 ]] || return 93
      print -r -- "$options[multibyte]|$LANG|${LC_ALL-unset}" > "$F511_CASE/options.before" || return 94
      _f511_multibyte_callback() { local value="éé"; print -rn -- "${#value}"; }
      local -i observed=0
      _vpn_info_capture_bounded 3 _f511_multibyte_callback || observed=$?
      print -r -- "$options[multibyte]|$LANG|${LC_ALL-unset}" > "$F511_CASE/options.after" || return 94
      return "$observed"
    ' || return 1
  done
  program=$(cat <<'ZSH'
printf '#!%s\n' "$F511_FIXTURE_BASH" > "$TEST_MOCK_BIN/wg" || return 91
cat >> "$TEST_MOCK_BIN/wg" <<'MOCK'
printf '%s\0' "$0" "$@" >> "$F511_CASE/wg.argv.nul" || exit 97
[[ $# == 2 && "$1" == show && "$2" == wg0 ]] || exit 97
case "$F511_WG_MODE" in
 direct) printf 'DIRECT\n\n'; exit 0 ;;
 fallback) exit 17 ;;
 stop124) exit 124 ;;
 stop130) exit 130 ;;
 stop143) exit 143 ;;
esac
exit 97
MOCK
printf '#!%s\n' "$F511_FIXTURE_BASH" > "$TEST_MOCK_BIN/sudo" || return 91
cat >> "$TEST_MOCK_BIN/sudo" <<'MOCK'
printf '%s\0' "$0" "$@" >> "$F511_CASE/sudo.argv.nul" || exit 97
if [[ $# == 2 && "$1" == -n && "$2" == true ]]; then exit 0; fi
[[ $# == 5 && "$1" == -n && "$2" == -- && "$3" == wg && "$4" == show && "$5" == wg0 ]] || exit 97
printf 'FALLBACK\n\n'
MOCK
command chmod -- 700 "$TEST_MOCK_BIN/wg" "$TEST_MOCK_BIN/sudo" || return 92
WG_HIDE_KEYS=caller-sentinel
local -i observed=0
case "$F511_WG_ROLE" in
 producer) command "$TEST_MOCK_BIN/wg" show wg0 || observed=$? ;;
 probe) _vpn_sudo_probe wg show wg0 || observed=$? ;;
 run) _vpn_run_wg show wg0 || observed=$? ;;
esac
print -r -- "$WG_HIDE_KEYS" > "$F511_CASE/caller.flag" || return 93
return "$observed"
ZSH
)
  for mode in direct fallback stop124 stop130 stop143; do
    export F511_WG_MODE="$mode" F511_WG_ROLE=run
    f511_observe "wg-raw-$mode" "$program" || return 1
  done
  export F511_WG_MODE=direct F511_WG_ROLE=producer
  f511_observe wg-raw-producer "$program" || return 1
  export F511_WG_MODE=fallback F511_WG_ROLE=probe
  f511_observe wg-raw-probe "$program" || return 1
  [ "$(cat "$F511_ROOT/native-helper-qualification/good.status")" = 0 ]
  [ "$(cat "$F511_ROOT/native-helper-qualification/wrong-sibling.status")" = 89 ]
  f511_primary "$F511_ROOT/timeout-qualified" 0 || return $?
  [ "$(cat "$F511_ROOT/timeout-qualified/timeout.leaf.post.status")" = 0 ]
  f511_primary "$F511_ROOT/timeout-bad-budget" 96 || return $?
  f511_primary "$F511_ROOT/timeout-bare" 96 || return $?
  f511_primary "$F511_ROOT/timeout-open" 98 || return $?
  for scene in timeout-bad-budget timeout-bare timeout-open; do [ ! -s "$F511_ROOT/$scene/calls" ]; done
  for code in 0 17 124 130 143; do
    f511_primary "$F511_ROOT/capture-producer-$code" "$code" || return $?
    expected="$code"; [[ "$code" != 17 ]] || expected=1
    for helper in _vpn_info_capture_bounded _vpn_darwin_capture; do
      dir="$F511_ROOT/capture-$helper-$code"
      f511_primary "$dir" "$expected" || return $?
      f511_native_receipt "$dir" || return $?
      [ "$(cat "$dir/timeout.stdin")" = closed ]
      [ "$(cat "$dir/producer.stdin")" = closed ]
      [ "$(cat "$dir/timeout.leaf.post.status")" = "$code" ]
      [[ ! -s "$dir/stderr" ]] || return 91
      if [[ "$code" == 0 ]]; then [ "$(cat "$dir/stdout")" = PAYLOAD ]; else [[ ! -s "$dir/stdout" ]] || return 92; fi
    done
  done
  [ "$(file_size "$F511_ROOT/capture-producer-excess/stdout")" -eq 4097 ]
  f511_primary "$F511_ROOT/capture-producer-empty" 0 || return $?
  for helper in _vpn_info_capture_bounded _vpn_darwin_capture; do
    f511_primary "$F511_ROOT/capture-$helper-empty" 0 || return $?
    [ "$(file_size "$F511_ROOT/capture-$helper-empty/stdout")" -eq 1 ]
    f511_primary "$F511_ROOT/capture-$helper-excess" 1 || return $?
    [[ ! -s "$F511_ROOT/capture-$helper-excess/stdout" ]] || return 93
  done
  for service in core standalone; do
    f511_primary "$F511_ROOT/callback-$service-normal" 0 || return $?
    [ "$(cat "$F511_ROOT/callback-$service-normal/stdout")" = PAYLOAD ]
    f511_primary "$F511_ROOT/callback-$service-empty" 0 || return $?
    [ "$(file_size "$F511_ROOT/callback-$service-empty/stdout")" -eq 1 ]
    f511_primary "$F511_ROOT/callback-$service-excess" 1 || return $?
    [[ ! -s "$F511_ROOT/callback-$service-excess/stdout" ]] || return 94
  done
  dir="$F511_ROOT/retained-copy-nul"
  f511_primary "$dir" 0 || return $?
  printf '%s\0%s\0' "$dir/profiles/wg0.conf" "$dir/profiles/wg9.conf" > "$dir/expected.nul" || return 95
  cmp "$dir/expected.nul" "$dir/stdout" || return 96
  [[ ! -s "$dir/stderr" ]] || return 97
  for owner in wg-access addresses route details sudo-cache sudo-test sudo-stat timestamp report-name report-name-fallback age; do
    dir="$F511_ROOT/local-$owner"
    f511_primary "$dir" 0 || return $?
    case "$owner" in
      wg-access|details) f511_positive_budget "$dir" "$TEST_MOCK_BIN/wg" || return $? ;;
      addresses|route) f511_positive_budget "$dir" "$TEST_MOCK_BIN/ip" || return $? ;;
      sudo-*) f511_positive_budget "$dir" "$TEST_MOCK_BIN/sudo" || return $? ;;
      timestamp|age) f511_positive_budget "$dir" "$TEST_MOCK_BIN/date" || return $? ;;
      report-name*)
        f511_positive_budget "$dir" "$TEST_MOCK_BIN/date" || return $?
        f511_positive_budget "$dir" "$TEST_MOCK_BIN/hostname" || return $?
        ;;
    esac
    case "$owner" in
      wg-access) [ "$(cat "$dir/stdout")" = direct ] ;;
      addresses) [ "$(cat "$dir/stdout")" = 10.0.0.2/24 ] ;;
      route) [ "$(cat "$dir/stdout")" = '1.1.1.1 dev eth0 src 192.0.2.9' ] ;;
      details)
        [[ "$(cat "$dir/stdout")" == *PUBLIC-LOCAL-CANARY* \
          && "$(cat "$dir/stdout")" != *PRIVATE-LOCAL-CANARY* \
          && "$(cat "$dir/stdout")" != *PRESHARED-LOCAL-CANARY* ]] || return 98
        [ "$(cat "$dir/wg.hide.keys")" = always ]
        ;;
      sudo-cache|sudo-test) [[ ! -s "$dir/stdout" ]] || return 99 ;;
      sudo-stat)
        [ "$(cat "$dir/stdout")" = '1:2:1000:33152:1:33:100:100' ]
        [ "$(cat "$dir/selected.stat.zsh")" = "$dir/stat-engine" ]
        [ "$(wc -l < "$dir/stat.selector.calls")" -eq 2 ]
        [ "$(file_mode "$dir/stat-engine")" = 700 ]
        [ "$(file_links "$dir/stat-engine")" -eq 1 ]
        ;;
      timestamp) [ "$(cat "$dir/stdout")" = 2026-02-01_010203 ] ;;
      report-name|report-name-fallback) [ "$(cat "$dir/stdout")" = "$dir/reports/vpn-report-2026-02-01_010203-fixture-host.md" ] ;;
      age) [ "$(cat "$dir/stdout")" = '1m 0s ago' ] ;;
    esac
    [ "$(cat "$dir/caller.wg.hide.keys")" = caller-sentinel ]
    f511_unchanged "$dir" || return $?
  done
  f511_primary "$F511_ROOT/local-cache-default17" 1 || return $?
  f511_primary "$F511_ROOT/local-cache-explicit17" 17 || return $?
  for owner in cache-default17 cache-explicit17; do
    dir="$F511_ROOT/local-$owner"
    [[ ! -s "$dir/stdout" && ! -e "$dir/payload.site" ]] || return 100
    f511_unchanged "$dir" || return $?
  done
  f511_primary "$F511_ROOT/local-payload17-raw" 17 || return $?
  [ "$(cat "$F511_ROOT/local-payload17-raw/stdout")" = PRIVATE-SUDO-PARTIAL ]
  f511_primary "$F511_ROOT/local-payload17-captured" 1 || return $?
  [[ ! -s "$F511_ROOT/local-payload17-captured/stdout" ]] || return 101
  [ "$(file_size "$F511_ROOT/capture-producer-utf8-under/stdout")" -eq 2 ]
  [ "$(file_size "$F511_ROOT/capture-producer-utf8-over/stdout")" -eq 4 ]
  for helper in _vpn_info_capture_bounded _vpn_darwin_capture; do
    dir="$F511_ROOT/capture-$helper-utf8-under"
    f511_primary "$dir" 0 || return $?
    [ "$(file_size "$dir/stdout")" -eq 3 ]
    cmp "$dir/options.before" "$dir/options.after" || return 102
    dir="$F511_ROOT/capture-$helper-utf8-over"
    f511_primary "$dir" 1 || return $?
    [[ ! -s "$dir/stdout" ]] || return 103
    cmp "$dir/options.before" "$dir/options.after" || return 102
  done
  for service in core standalone; do
    dir="$F511_ROOT/callback-$service-multibyte"
    f511_primary "$dir" 0 || return $?
    [ "$(cat "$dir/stdout")" = 2 ]
    cmp "$dir/options.before" "$dir/options.after" || return 104
  done
  for scene in tail-over tail-under; do
    f511_primary "$F511_ROOT/capture-producer-$scene" 0 || return $?
    [ "$(file_size "$F511_ROOT/capture-producer-$scene/stdout")" -eq 4 ]
    for helper in _vpn_info_capture_bounded _vpn_darwin_capture; do
      dir="$F511_ROOT/capture-$helper-$scene"
      if [[ "$scene" == tail-over ]]; then
        f511_primary "$dir" 1 || return $?
        [[ ! -s "$dir/stdout" ]] || return 105
      else
        f511_primary "$dir" 0 || return $?
        printf 'AB\n' > "$dir/expected.normalized" || return 105
        cmp "$dir/expected.normalized" "$dir/stdout" || return 105
      fi
      f511_native_receipt "$dir" || return $?
    done
  done
  for mode in direct fallback; do
    dir="$F511_ROOT/wg-raw-$mode"
    f511_primary "$dir" 0 || return $?
    if [[ "$mode" == direct ]]; then printf 'DIRECT\n\n' > "$dir/expected.raw"; else printf 'FALLBACK\n\n' > "$dir/expected.raw"; fi
    cmp "$dir/expected.raw" "$dir/stdout" || return 94
  done
  for mode in 124 130 143; do
    dir="$F511_ROOT/wg-raw-stop$mode"
    f511_primary "$dir" "$mode" || return $?
    [[ ! -s "$dir/stdout" && ! -e "$dir/sudo.argv.nul" ]] || return 95
  done
  for mode in direct fallback stop124 stop130 stop143 producer probe; do
    [ "$(cat "$F511_ROOT/wg-raw-$mode/caller.flag")" = caller-sentinel ]
  done
}

@test "vpn interrupt bounds: all MTU context interruptions stop before later probes in text and JSON" {
  command -v jq >/dev/null || skip "jq is not installed"
  local platform stage code mode dir expected
  for platform in linux darwin; do
    export F511_PLATFORM="$platform"
    for stage in route egress-mtu wireguard tunnel-mtu; do
      export F511_STAGE="$stage"
      for code in 130 143; do
        export F511_CODE="$code"
        for mode in text json; do
          export F511_FORMAT="$mode"
          f511_observe "mtu-$platform-$stage-$code-$mode" '
            if [[ "$F511_FORMAT" == json ]]; then vpn-mtu-probe --target 192.0.2.1 --json
            else vpn-mtu-probe --target 192.0.2.1; fi
          ' || return 1
        done
      done
    done
    for code in 0 17; do
      export F511_CODE="$code" F511_STAGE=none
      [[ "$code" == 0 ]] || export F511_STAGE=route
      f511_observe "mtu-$platform-control-$code" "vpn-mtu-probe --target 192.0.2.1" || return 1
    done
  done
  for platform in linux darwin; do
    for stage in route egress-mtu wireguard tunnel-mtu; do
      for code in 130 143; do
        for mode in text json; do
          dir="$F511_ROOT/mtu-$platform-$stage-$code-$mode"
          f511_primary "$dir" "$code" || return $?
          [[ ! -s "$dir/stdout" ]] || return 40
          [ "$(tail -n 1 "$dir/calls")" = "$(printf 'STOP\t%s' "$stage")" ]
          [ "$(grep -c 'ping.* -s ' "$dir/calls")" -eq 1 ]
          f511_unchanged "$dir" || return $?
        done
      done
    done
    for code in 0 17; do
      dir="$F511_ROOT/mtu-$platform-control-$code"
      f511_primary "$dir" 0 || return $?
      [ "$(grep -c 'ping.* -s ' "$dir/calls")" -eq 2 ]
    done
  done
}

@test "vpn interrupt bounds: oversized report cleanup retains replacements links and unrelated bytes" {
  export F511_GROUP=report F511_CODE=0 F511_OUTPUT=normal F511_PLATFORM=linux
  local scene dir staged original_identity
  for scene in success oversized replacement symlink hardlink; do
    export F511_REPLACE="$scene" F511_COUNT=20
    [[ "$scene" != success ]] || export F511_COUNT=1
    f511_observe "report-$scene" '
      zmodload -F zsh/stat b:zstat || return 80
      _vpn_check_ip_stack() { return 0; }
      _vpn_have_sudo_cache() { return 1; }
      _vpn_should_apply_wsl_ipv6_fix() { return 1; }
      _vpn_configs_access_state() { print -r -- direct; }
      _vpn_wg_access_state() { print -r -- direct; }
      _vpn_get_active_interfaces() { local i; for ((i=1;i<=F511_COUNT;i++)); do print -r -- "wg$i"; done; }
      _vpn_active_interfaces() { reply=(); local i; for ((i=1;i<=F511_COUNT;i++)); do reply+=("wg$i"); done; return 0; }
      _vpn_get_iface_details() {
        print -r -- "$1" >> "$F511_CASE/details.calls" || return 81
        command cat -- "$F511_CASE/section"
      }
      _vpn_iface_internal_addrs() { return 1; }
      _vpn_iface_endpoint() { return 1; }
      _vpn_iface_latest_handshake() { return 1; }
      _vpn_iface_transfer() { return 1; }
      _vpn_dns_from_conf() { return 1; }
      _vpn_dns_resolvers() { return 1; }
      _vpn_get_ip_info() { return 1; }
      _vpn_get_ip_crosscheck() { return 1; }
      command awk "BEGIN { for (i=0;i<60000;i++) printf \"x\"; printf \"\\n\" }" > "$F511_CASE/section" || return 82
      print -r -- UNRELATED-REPORT-CANARY > "$VPN_MENU_REPORT_DIR/unrelated.md" || return 82
      command chmod -- 600 "$VPN_MENU_REPORT_DIR/unrelated.md" || return 82
      local -A observed=()
      zstat -LH observed -- "$VPN_MENU_REPORT_DIR/unrelated.md" || return 83
      print -r -- "$observed[device]:$observed[inode]" > "$F511_CASE/unrelated.identity" || return 83
      functions[_f511_publish]="${functions[_vpn_report_publish]}"
      _vpn_report_publish() {
        local -A st=()
        zstat -LH st -- "$1" || return 84
        print -r -- "$1" > "$F511_CASE/staged.path" || return 84
        print -r -- "$st[size]" > "$F511_CASE/staged.bytes" || return 84
        print -r -- "$st[device]:$st[inode]" > "$F511_CASE/staged.identity" || return 84
        local -i producer_rc=0
        _f511_publish "$@" || producer_rc=$?
        print -r -- "$producer_rc" > "$F511_CASE/publisher.primary.status" || return 85
        if (( producer_rc != 0 )); then
          case "$F511_REPLACE" in
            replacement|symlink)
              command mv -- "$1" "$F511_CASE/owned-stage" || return 86
              print -r -- REPLACEMENT-CANARY > "$F511_CASE/replacement" || return 86
              command chmod -- 600 "$F511_CASE/replacement" || return 86
              if [[ "$F511_REPLACE" == replacement ]]; then command mv -- "$F511_CASE/replacement" "$1" || return 86
              else command ln -s "$F511_CASE/replacement" "$1" || return 86; fi
              ;;
            hardlink) command ln -- "$1" "$F511_CASE/stage-anchor" || return 86 ;;
          esac
        fi
        return "$producer_rc"
      }
      local -i public_rc=0
      vpn-report || public_rc=$?
      print -rn -- "$_VPN_REPORT_TARGET" > "$F511_CASE/report.target.after" || return 87
      local -a staging=("$VPN_MENU_REPORT_DIR"/.vpn-report.*(N)) published=("$VPN_MENU_REPORT_DIR"/vpn-report-*.md(N))
      print -r -- "${#staging}" > "$F511_CASE/staging.count" || return 87
      print -r -- "${#published}" > "$F511_CASE/published.count" || return 87
      return "$public_rc"
    ' || return 1
  done
  for scene in success oversized replacement symlink hardlink; do
    dir="$F511_ROOT/report-$scene"
    f511_primary "$dir" "$([[ "$scene" == success ]] && printf 0 || printf 1)" || return $?
    [[ ! -s "$dir/stdout" && ! -s "$dir/report.target.after" ]] || return 50
    [ "$(file_size "$dir/section")" -eq 60001 ]
    [ "$(cat "$dir/reports/unrelated.md")" = UNRELATED-REPORT-CANARY ]
    [ "$(file_identity "$dir/reports/unrelated.md")" = "$(cat "$dir/unrelated.identity")" ]
    staged=$(cat "$dir/staged.path") || return 51
    [[ "$staged" == "$dir/reports/.vpn-report."* ]] || return 51
    if [[ "$scene" == success ]]; then
      [ "$(cat "$dir/publisher.primary.status")" = 0 ]
      [ "$(cat "$dir/published.count")" = 1 ]
      [ "$(cat "$dir/staging.count")" = 0 ]
      [ "$(wc -l < "$dir/details.calls")" -eq 1 ]
    else
      [ "$(cat "$dir/publisher.primary.status")" = 1 ]
      [ "$(cat "$dir/staged.bytes")" -gt 1048576 ]
      [ "$(cat "$dir/published.count")" = 0 ]
      [ "$(wc -l < "$dir/details.calls")" -eq 20 ]
      case "$scene" in
        oversized) [ "$(cat "$dir/staging.count")" = 0 ]; [ ! -e "$staged" ] ;;
        replacement) [ "$(cat "$dir/staging.count")" = 1 ]; [ "$(cat "$staged")" = REPLACEMENT-CANARY ] ;;
        symlink) [ -L "$staged" ]; [ "$(cat "$dir/replacement")" = REPLACEMENT-CANARY ] ;;
        hardlink)
          [ "$(file_links "$dir/stage-anchor")" -eq 2 ]
          [ "$(file_identity "$dir/stage-anchor")" = "$(cat "$dir/staged.identity")" ]
          ;;
      esac
    fi
  done
}
