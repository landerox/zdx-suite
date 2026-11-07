#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  vpn_pin_kernel Linux
  unset WSL_DISTRO_NAME WSL_INTEROP
  export VPN_CONFIG_DIR="$HOME/wireguard" VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/reports" VPN_SECRET_ACTIVE=0
  export VPN_SECRET_AUTH="$HOME/authenticated" VPN_SECRET_RACE="" VPN_SECRET_FAIL=""
  export VPN_SECRET_INTERRUPT=130
  export VPN_SECRET_MUTATIONS="$HOME/mutations" VPN_SECRET_WG_LOG="$HOME/wg.log"
  export VPN_SECRET_WG_MODE=honor VPN_SECRET_WG_STATUS=1
  export VPN_SECRET_FIND_MODE=success VPN_SECRET_CACHE_MODE=normal
  export VPN_SECRET_CURL_MODE=fail VPN_SECRET_CURL_ARGS="$HOME/curl.argv"
  export VPN_SECRET_CURL_INPUT="$HOME/curl.stdin"
  export VPN_FAKE_TOKEN=FAKE_PROVIDER_CANARY
  export VPN_MENU_IPINFO_URLS='https://provider.example/json?token=FAKE_PROVIDER_CANARY#private-fragment'
  export VPN_MENU_IPINFO_PLAIN_URLS='' VPN_MENU_IPINFO_TRACE_URLS=''
  mkdir -p "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$HOME/expected"
  chmod -- 700 "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$HOME/expected"
  secret_profile "$VPN_CONFIG_DIR/wg0.conf" LIVE-FAKE-KEY 10.0.0.2
  secret_profile "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" BACKUP-FAKE-KEY 10.1.0.2
  secret_profile "$VPN_CONFIG_DIR/wg0.conf.pre-restore" UNDO-FAKE-KEY 10.2.0.2
  cp "$VPN_CONFIG_DIR/wg0.conf" "$HOME/expected/live"
  cp "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" "$HOME/expected/backup"
  cp "$VPN_CONFIG_DIR/wg0.conf.pre-restore" "$HOME/expected/undo"
  printf 'wg0\n' > "$VPN_CACHE_DIR/default-iface"
  printf 'wg0\n' > "$VPN_CACHE_DIR/last-iface"
  chmod -- 600 "$VPN_CACHE_DIR"/*
  : > "$VPN_SECRET_MUTATIONS"
  : > "$VPN_SECRET_WG_LOG"
  : > "$VPN_SECRET_CURL_ARGS"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/sudo"
  cat >> "$TEST_MOCK_BIN/sudo" <<'MOCK'
{ printf 'sudo'; printf ' %q' "$@"; printf '\n'; } >> "$MOCK_SUDO_LOG"
[[ "$HOME" == "$TEST_TEMP_DIR/home" && -d "$HOME" && ! -L "$HOME" \
  && "$VPN_CONFIG_DIR" == "$HOME/wireguard" && -d "$VPN_CONFIG_DIR" && ! -L "$VPN_CONFIG_DIR" \
  && "$VPN_SECRET_AUTH" == "$HOME/authenticated" \
  && "$VPN_SECRET_MUTATIONS" == "$HOME/mutations" \
  && "$TEST_MOCK_BIN" == "$TEST_TEMP_DIR/bin" && ! -L "$TEST_MOCK_BIN" ]] || exit 98
if (( $# == 2 )) && [[ "$1" == -n && "$2" == true ]]; then
  case "$VPN_SECRET_CACHE_MODE" in
    normal) ;;
    hang) exec /bin/sleep 20 ;;
    *) exit "$VPN_SECRET_CACHE_MODE" ;;
  esac
  [[ -f "$VPN_SECRET_AUTH" ]]
  exit $?
fi
if (( $# == 1 )) && [[ "$1" == -v ]]; then
  : > "$VPN_SECRET_AUTH"
  printf 'AUTH_BOUNDARY\n' >&2
  case "$VPN_SECRET_RACE" in
    undo) printf '# changed during authentication\n' >> "$VPN_CONFIG_DIR/wg0.conf.pre-restore" ;;
    target-undo) printf 'appeared\n' > "$VPN_CONFIG_DIR/office.conf.pre-restore" ;;
    '') ;;
    *) exit 98 ;;
  esac
  exit 0
fi
(( $# >= 3 )) && [[ "$1" == -n && "$2" == -- && -f "$VPN_SECRET_AUTH" ]] || exit 98
shift 2
profile_operand() {
  local operand="$1"
  [[ "$operand" == "$VPN_CONFIG_DIR/"* && "$operand" != *[[:cntrl:]]* \
    && "$operand" != */../* && "$operand" != */.. && "$operand" != */./* \
    && "$operand" != */. && "$operand" != *'//'* && "$operand" != */ \
    && ! -L "$operand" ]] || return 1
  case "${operand##*/}" in
    wg0.conf|wg0.conf.bak-vpn-menu|wg0.conf.pre-restore \
    |office.conf|office.conf.bak-vpn-menu|office.conf.pre-restore \
    |.zdx-vpn-restore.*|.zdx-vpn-undo.*) ;;
    *) return 1 ;;
  esac
  [[ "${operand%/*}" == "$VPN_CONFIG_DIR" ]]
}
operation="$1"
case "$operation" in
  rm)
    (( $# == 3 )) && [[ "$2" == -- ]] && profile_operand "$3" || exit 98
    ;;
  mv)
    if (( $# == 4 )) && [[ "$2" == -- ]]; then
      profile_operand "$3" && profile_operand "$4" || exit 98
    elif (( $# == 5 )) && [[ "$2" == -f && "$3" == -- ]]; then
      profile_operand "$4" && profile_operand "$5" || exit 98
    else exit 98; fi
    ;;
  install)
    (( $# == 10 )) && [[ "$2" == -m && "$3" == 600 && "$4" == -o \
      && "$5" == 0 && "$6" == -g && "$7" == 0 && "$8" == -- ]] \
      && profile_operand "$9" && profile_operand "${10}" || exit 98
    ;;
  mktemp)
    (( $# == 2 )) && [[ "$2" == "$VPN_CONFIG_DIR/.zdx-vpn-restore.XXXXXX" \
      || "$2" == "$VPN_CONFIG_DIR/.zdx-vpn-undo.XXXXXX" ]] || exit 98
    ;;
  ln)
    (( $# == 4 )) && [[ "$2" == -- ]] \
      && profile_operand "$3" && profile_operand "$4" || exit 98
    ;;
  wg)
    (( $# == 3 )) && [[ "$2" == show && "$3" == wg0 ]] || exit 98
    export MOCK_SUDO_ROOT=1
    exec "$TEST_MOCK_BIN/wg" show wg0
    ;;
  find)
    (( $# == 14 )) && [[ "$2" == "$VPN_CONFIG_DIR" && "$3" == -maxdepth \
      && "$4" == 1 && "$5" == -type && "$6" == f && "$7" == '(' \
      && "$8" == -name && "$9" == '*.conf.bak-vpn-menu' && "${10}" == -o \
      && "${11}" == -name && "${12}" == '*.conf.pre-restore' \
      && "${13}" == ')' && "${14}" == -print ]] || exit 98
    printf 'find\n' >> "$HOME/find.calls"
    printf '%s\n' "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
    case "$VPN_SECRET_FIND_MODE" in
      success) printf '%s\n' "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"; exit 0 ;;
      hang) exec /bin/sleep 20 ;;
      *) exit "$VPN_SECRET_FIND_MODE" ;;
    esac
    ;;
  *) exit 98 ;;
esac
{ printf '%q' "$1"; printf ' %q' "${@:2}"; printf '\n'; } >> "$VPN_SECRET_MUTATIONS"
if [[ "$operation" == rm && "${3:-}" == "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" \
  && "$VPN_SECRET_FAIL" == backup-interrupt ]]; then
  exit "$VPN_SECRET_INTERRUPT"
fi
if [[ "$operation" == rm && "${3:-}" == "$VPN_CONFIG_DIR/wg0.conf.pre-restore" \
  && "$VPN_SECRET_FAIL" == undo-remove-interrupt ]]; then
  exit "$VPN_SECRET_INTERRUPT"
fi
if [[ "$operation" == mv && "${3:-}" == "$VPN_CONFIG_DIR/wg0.conf.pre-restore" ]]; then
  case "$VPN_SECRET_FAIL" in
    undo) exit 1 ;;
    undo-interrupt) exit "$VPN_SECRET_INTERRUPT" ;;
    undo-target)
      (umask 077; printf 'APPEARED-BACKUP-CANARY\n' > "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu")
      exit 1
      ;;
  esac
fi
if [[ "$operation" == mv && "${2:-}" == -f \
  && "${5:-}" == "$VPN_CONFIG_DIR/wg0.conf.pre-restore" \
  && "$VPN_SECRET_FAIL" == restore-undo-interrupt ]]; then
  exit "$VPN_SECRET_INTERRUPT"
fi
case "$operation" in
  install) exec /usr/bin/install -m 600 -- "$9" "${10}" ;;
  rm) exec /bin/rm "${@:2}" ;;
  mv) exec /bin/mv "${@:2}" ;;
  ln) exec /bin/ln "${@:2}" ;;
  mktemp) exec mktemp "$2" ;;
esac
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/sudo"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/wg"
  cat >> "$TEST_MOCK_BIN/wg" <<'MOCK'
printf '%s|%s|%s\n' "${WG_HIDE_KEYS:-unset}" "${MOCK_SUDO_ROOT:-0}" "$*" >> "$VPN_SECRET_WG_LOG"
case "$*" in
  --version) printf 'wireguard-tools fixture\n' ;;
  'show interfaces') [[ "$VPN_SECRET_ACTIVE" != 1 ]] || printf 'wg0\n' ;;
  'show wg0')
    if [[ "$VPN_SECRET_WG_MODE" == fallback && "${MOCK_SUDO_ROOT:-0}" != 1 ]]; then exit "$VPN_SECRET_WG_STATUS"; fi
    printf 'interface: wg0\n'
    if [[ "$VPN_SECRET_WG_MODE" == ignore-knob || "${WG_HIDE_KEYS:-}" == never ]]; then
      printf '  private key: LIVE-WG-PRIVATE-CANARY=\n  preshared key: LIVE-WG-PSK-CANARY=\n'  # gitleaks:allow -- intentional fixture keys
    else printf '  private key: (hidden)\n  preshared key: (hidden)\n'; fi
    printf 'peer: PUBLIC-PEER-KEY=\n  endpoint: 203.0.113.7:51820\n'
    ;;
  'show wg0 endpoints') printf 'PUBLIC-PEER-KEY=\t203.0.113.7:51820\n' ;;
  'show wg0 latest-handshakes') printf 'PUBLIC-PEER-KEY=\t0\n' ;;
  'show wg0 transfer') printf 'PUBLIC-PEER-KEY=\t1\t2\n' ;;
  *) exit 97 ;;
esac
exit 0
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/curl"
  cat >> "$TEST_MOCK_BIN/curl" <<'MOCK'
printf '%s\n' "$@" >> "$VPN_SECRET_CURL_ARGS"
cat > "$VPN_SECRET_CURL_INPUT"
if [[ "$VPN_SECRET_CURL_MODE" == success ]]; then printf '{"ip":"203.0.113.7","city":"fixture"}\n'; exit 0; fi
printf 'URL rejected: https://provider.example/?token=%s\n' "$VPN_FAKE_TOKEN" >&2
exit 22
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/wg" "$TEST_MOCK_BIN/curl"
  local tool
  for tool in ip hostname resolvectl python3; do
    printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/$tool"
  done
  printf 'printf "default via 192.0.2.1 dev fixture0\\n"\n' >> "$TEST_MOCK_BIN/ip"
  printf 'printf "fixture-host\\n"\n' >> "$TEST_MOCK_BIN/hostname"
  printf 'exit 1\n' >> "$TEST_MOCK_BIN/resolvectl"
  printf 'printf "Python 3.12 fixture\\n"\n' >> "$TEST_MOCK_BIN/python3"
  chmod -- 700 "$TEST_MOCK_BIN/ip" "$TEST_MOCK_BIN/hostname" "$TEST_MOCK_BIN/resolvectl" "$TEST_MOCK_BIN/python3"
}

teardown() {
  chmod -- 700 "$VPN_CONFIG_DIR" 2>/dev/null || true
  cleanup_sandbox
}

secret_profile() {
  printf '[Interface]\nPrivateKey = %s=\nAddress = %s/24\n[Peer]\nPublicKey = PUBLIC-PEER-KEY=\nAllowedIPs = 0.0.0.0/0\n' "$2" "$3" > "$1"
  chmod -- 600 "$1"
}

@test "vpn secret retention: provider tokens reach curl only through stdin and failures expose no token" {
  run run_zsh '
    _vpn_curl_bounded "$VPN_MENU_IPINFO_URLS" 4 2 >"$HOME/curl.stdout" 2>"$HOME/curl.stderr"
  '
  [ "$status" -eq 22 ]
  ! grep -qF "$VPN_FAKE_TOKEN" "$VPN_SECRET_CURL_ARGS" "$HOME/curl.stderr" || false
  grep -qF "$VPN_FAKE_TOKEN" "$VPN_SECRET_CURL_INPUT"
  grep -qFx -- --config "$VPN_SECRET_CURL_ARGS"
  [ "$(head -n 1 "$VPN_SECRET_CURL_ARGS")" = -q ]
  [ ! -s "$HOME/curl.stdout" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn secret retention: a successful configured provider still returns its validated address" {
  export VPN_SECRET_CURL_MODE=success
  run run_zsh '_vpn_get_ip_info'
  [ "$status" -eq 0 ]
  [[ "$output" == $'203.0.113.7\tfixture\t'*$'\tprovider.example' ]]
  ! grep -qF "$VPN_FAKE_TOKEN" "$VPN_SECRET_CURL_ARGS" || false
  grep -qF "$VPN_FAKE_TOKEN" "$VPN_SECRET_CURL_INPUT"
}

@test "vpn secret retention: provider failure diagnostics and saved reports contain only safe authorities" {
  run run_zsh '
    vpn-ip-info >"$HOME/info.stdout" 2>"$HOME/info.stderr" || return 41
    vpn-report >"$HOME/report.stdout" 2>"$HOME/report.stderr"
  '
  [ "$status" -eq 0 ]
  local report
  report=$(find "$VPN_MENU_REPORT_DIR" -name 'vpn-report-*.md' -type f)
  [ -n "$report" ]
  ! grep -qF "$VPN_FAKE_TOKEN" "$HOME/info.stderr" "$HOME/report.stderr" "$report" "$VPN_SECRET_CURL_ARGS" || false
  ! grep -qF private-fragment "$HOME/info.stderr" "$report" || false
  grep -qF provider.example "$HOME/info.stderr"
  grep -qF provider.example "$report"
  [ "$(file_mode "$report")" = 600 ]
  [ "$(file_mode "$VPN_MENU_REPORT_DIR")" = 700 ]
  [ ! -s "$HOME/info.stdout" ]
  [ ! -s "$HOME/report.stdout" ]
}

@test "vpn secret retention: direct and warm privileged wg reads force hidden keys without changing caller policy" {
  export WG_HIDE_KEYS=never VPN_SECRET_WG_MODE=fallback
  : > "$VPN_SECRET_AUTH"
  run run_zsh '
    _vpn_get_iface_details wg0 >"$HOME/details" || return 41
    [[ "$WG_HIDE_KEYS" == never ]] || return 42
  '
  [ "$status" -eq 0 ]
  ! grep -qE 'LIVE-WG-(PRIVATE|PSK)-CANARY' "$HOME/details" || false
  grep -qF 'always|0|show wg0' "$VPN_SECRET_WG_LOG"
  grep -qF 'always|1|show wg0' "$VPN_SECRET_WG_LOG"
  grep -qF PUBLIC-PEER-KEY "$HOME/details"
}

@test "vpn secret retention: active panes details and reports redact keys even when wg ignores its hiding knob" {
  export WG_HIDE_KEYS=never VPN_SECRET_ACTIVE=1 VPN_SECRET_WG_MODE=ignore-knob
  run run_zsh '
    _vpn_state_load
    _vpn_preview_render vpn-off "Disconnect fixture." wg0 >"$HOME/pane"
    vpn-details >"$HOME/details.stdout" 2>"$HOME/details.stderr" || return 41
    vpn-report >"$HOME/report.stdout" 2>"$HOME/report.stderr"
  '
  [ "$status" -eq 0 ]
  local report
  report=$(find "$VPN_MENU_REPORT_DIR" -name 'vpn-report-*.md' -type f)
  [ -n "$report" ]
  ! grep -qE 'LIVE-WG-(PRIVATE|PSK)-CANARY' "$HOME/pane" "$HOME/details.stderr" "$report" || false
  grep -qF PUBLIC-PEER-KEY "$HOME/pane"
  grep -qF PUBLIC-PEER-KEY "$HOME/details.stderr"
  grep -qF PUBLIC-PEER-KEY "$report"
  [ ! -s "$HOME/details.stdout" ]
  [ ! -s "$HOME/report.stdout" ]
}

@test "vpn secret retention: live key filtering preserves interrupted read statuses" {
  export VPN_SECRET_WG_MODE=fallback
  local code
  for code in 130 143; do
    export VPN_SECRET_WG_STATUS="$code"
    run run_zsh '_vpn_get_iface_details wg0'
    [ "$status" -eq "$code" ]
    [ -z "$output" ]
  done
}

@test "vpn secret retention: commented and inline private keys disappear from excerpts panes and restore plans" {
  cat >> "$VPN_CONFIG_DIR/wg0.conf" <<'PROFILE'
# PrivateKey = OLD-PRIVATE-CANARY=
; PresharedKey = OLD-PSK-CANARY=
# # Private Key = SPACED-PRIVATE-CANARY=
Address = 10.9.0.2/32 # PresharedKey = INLINE-PSK-CANARY=
PROFILE
  cp "$VPN_CONFIG_DIR/wg0.conf" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  run run_zsh '
    _vpn_redacted_config_excerpt wg0 >"$HOME/excerpt"
    _vpn_redacted_backup_excerpt wg0 >"$HOME/backup-excerpt"
    _vpn_state_load
    _vpn_preview_render vpn-on "Connect fixture." wg0 >"$HOME/pane"
    vpn-config-restore wg0 --dry-run >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"
  '
  [ "$status" -eq 0 ]
  ! grep -qE '(LIVE-FAKE-KEY|OLD-PRIVATE-CANARY|OLD-PSK-CANARY|SPACED-PRIVATE-CANARY|INLINE-PSK-CANARY)' "$HOME/excerpt" "$HOME/backup-excerpt" "$HOME/pane" "$HOME/restore.stderr" || false
  grep -qF PUBLIC-PEER-KEY "$HOME/excerpt"
  [ ! -s "$HOME/restore.stdout" ]
  [ ! -s "$VPN_SECRET_MUTATIONS" ]
}

@test "vpn secret retention: remove keeps and discloses both unrequested credential copies" {
  run run_zsh 'vpn-profile-remove wg0 --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr"'
  [ "$status" -eq 0 ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  grep -qF wg0.conf.pre-restore "$HOME/remove.stderr"
  grep -qF -- --with-backup "$HOME/remove.stderr"
  [ ! -s "$HOME/remove.stdout" ]
}

@test "vpn secret retention: with-backup dry run names all three files and is passive" {
  run run_zsh 'vpn-profile-remove wg0 --with-backup --dry-run >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"'
  [ "$status" -eq 0 ]
  grep -qF wg0.conf.pre-restore "$HOME/plan.stderr"
  grep -qF '3 files planned' "$HOME/plan.stderr"
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  [ ! -s "$VPN_SECRET_MUTATIONS" ]
  [ ! -s "$HOME/plan.stdout" ]
}

@test "vpn secret retention: with-backup deletes only the three reviewed profile family files" {
  printf 'keep\n' > "$VPN_CONFIG_DIR/unrelated"
  run run_zsh 'vpn-profile-remove wg0 --with-backup --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr"'
  [ "$status" -eq 0 ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.pre-restore" ]
  [ "$(cat "$VPN_CONFIG_DIR/unrelated")" = keep ]
  [ "$(grep -c '^rm -- ' "$VPN_SECRET_MUTATIONS")" -eq 3 ]
  grep -qF '3 files deleted' "$HOME/remove.stderr"
}

@test "vpn secret retention: changed undo bytes after authentication stop removal before any deletion" {
  export VPN_SECRET_RACE=undo
  run run_zsh 'vpn-profile-remove wg0 --with-backup --yes'
  [ "$status" -eq 1 ]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  [ ! -s "$VPN_SECRET_MUTATIONS" ]
}

@test "vpn secret retention: rename plans and moves the complete credential family" {
  run run_zsh 'vpn-profile-rename wg0 office --yes >"$HOME/rename.stdout" 2>"$HOME/rename.stderr"'
  [ "$status" -eq 0 ]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/office.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu"
  cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/office.conf.pre-restore"
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.pre-restore" ]
  grep -qF wg0.conf.pre-restore "$HOME/rename.stderr"
  [ "$(file_mode "$VPN_CONFIG_DIR/office.conf.pre-restore")" = 600 ]
  [ ! -s "$HOME/rename.stdout" ]
}

@test "vpn secret retention: appeared undo target after authentication stops rename before any move" {
  export VPN_SECRET_RACE=target-undo
  run run_zsh 'vpn-profile-rename wg0 office --yes'
  [ "$status" -eq 1 ]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  [ ! -s "$VPN_SECRET_MUTATIONS" ]
}

@test "vpn secret retention: failed undo rename rolls back the already moved profile and backup" {
  export VPN_SECRET_FAIL=undo
  run run_zsh 'vpn-profile-rename wg0 office --yes'
  [ "$status" -eq 1 ]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  [ ! -e "$VPN_CONFIG_DIR/office.conf" ]
  [ ! -e "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu" ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(grep -c '^mv -- ' "$VPN_SECRET_MUTATIONS")" -eq 5 ]
}

@test "vpn secret retention: orphaned undo and backup copies stay visible without profile contents" {
  rm -- "$VPN_CONFIG_DIR/wg0.conf"
  run run_zsh 'vpn-config-dir >"$HOME/inventory.stdout" 2>"$HOME/inventory.stderr"'
  [ "$status" -eq 0 ]
  grep -qF wg0.conf.pre-restore "$HOME/inventory.stderr"
  grep -qF wg0.conf.bak-vpn-menu "$HOME/inventory.stderr"
  ! grep -qE '(UNDO-FAKE-KEY|BACKUP-FAKE-KEY)' "$HOME/inventory.stderr" || false
  [ ! -s "$HOME/inventory.stdout" ]
  [ ! -s "$VPN_SECRET_MUTATIONS" ]
}

@test "vpn secret retention: restore discloses replacement of an existing credential-bearing undo copy" {
  run run_zsh 'vpn-config-restore wg0 --dry-run >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"'
  [ "$status" -eq 0 ]
  grep -qF wg0.conf.pre-restore "$HOME/restore.stderr"
  grep -qF replaced "$HOME/restore.stderr"
  cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  [ ! -s "$VPN_SECRET_MUTATIONS" ]
}

@test "vpn secret retention: non-private undo copies stop remove and rename before authentication" {
  chmod -- 644 "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  local action
  for action in remove rename; do
    export VPN_SECRET_ACTION="$action"
    run run_zsh '
      case "$VPN_SECRET_ACTION" in
        remove) vpn-profile-remove wg0 --with-backup --yes ;;
        rename) vpn-profile-rename wg0 office --yes ;;
      esac
    '
    [ "$status" -eq 1 ]
    cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
    cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
    [ ! -s "$VPN_SECRET_MUTATIONS" ]
    ! grep -qFx 'sudo -v' "$MOCK_SUDO_LOG" || false
  done
}

@test "vpn secret retention: with-backup includes an undo copy when no ordinary backup exists" {
  rm -- "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  run run_zsh 'vpn-profile-remove wg0 --with-backup --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.pre-restore" ]
  [ "$(grep -c '^rm -- ' "$VPN_SECRET_MUTATIONS")" -eq 2 ]
}

@test "vpn undo rollback safety: an appeared rollback target is preserved and retained backup location is disclosed" {
  export VPN_SECRET_FAIL=undo-target
  run run_zsh 'vpn-profile-rename wg0 office --yes >"$HOME/rename.stdout" 2>"$HOME/rename.stderr"'
  [ "$status" -eq 1 ]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu"
  cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  [ "$(cat "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu")" = APPEARED-BACKUP-CANARY ]
  grep -qF office.conf.bak-vpn-menu "$HOME/rename.stderr"
  ! grep -qF 'nothing remains renamed' "$HOME/rename.stderr" || false
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
}

# Only protected metadata is modeled. The real inventory/probe/timeout code
# still runs; the sudo fixture produces a fixed read-only listing.
secret_protected_context() {
  export VPN_SECRET_PROTECTED_CONTEXT="$HOME/protected-context.zsh"
  cat > "$VPN_SECRET_PROTECTED_CONTEXT" <<'ZSH'
emulate -R zsh
_vpn_profile_path_state() {
  print -r -- observed >> "$HOME/metadata.calls"
  case "$1" in
    "$VPN_CONFIG_DIR/wg0.conf.pre-restore"|"$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu") print -r -- safe ;;
    *) print -r -- unsafe ;;
  esac
}
ZSH
  : > "$VPN_SECRET_AUTH"
  chmod -- 000 "$VPN_CONFIG_DIR"
}

@test "vpn retained inventory: protected copies use a bounded warm nonprompting read" {
  secret_protected_context
  run run_zsh 'source "$VPN_SECRET_PROTECTED_CONTEXT"; _vpn_config_copy_inventory'
  [ "$status" -eq 0 ]
  [ "$output" = $'wg0.conf.bak-vpn-menu\tbackup\nwg0.conf.pre-restore\tpre-restore' ]
  [ "$(cat "$HOME/find.calls")" = find ]
  ! grep -qFx 'sudo -v' "$MOCK_SUDO_LOG" || false
  [ ! -s "$VPN_SECRET_MUTATIONS" ]
}

@test "vpn retained inventory: failed or interrupted collection never consumes partial rows" {
  secret_protected_context
  local code
  for code in 1 130 143; do
    export VPN_SECRET_FIND_MODE="$code"
    run run_zsh 'source "$VPN_SECRET_PROTECTED_CONTEXT"; _vpn_config_copy_inventory'
    [ "$status" -eq "$code" ]
    [ -z "$output" ]
    [ ! -e "$HOME/metadata.calls" ]
  done
  ! grep -qFx 'sudo -v' "$MOCK_SUDO_LOG" || false
  [ ! -s "$VPN_SECRET_MUTATIONS" ]
}

@test "vpn retained inventory: a stalled payload times out without publishing partial rows" {
  secret_protected_context
  export VPN_SECRET_FIND_MODE=hang
  run run_zsh 'source "$VPN_SECRET_PROTECTED_CONTEXT"; _vpn_config_copy_inventory'
  [ "$status" -eq 124 ]
  [ -z "$output" ]
  [ ! -e "$HOME/metadata.calls" ]
  [ ! -s "$VPN_SECRET_MUTATIONS" ]
}

@test "vpn retained inventory: a stalled cache probe times out before the listing starts" {
  secret_protected_context
  export VPN_SECRET_CACHE_MODE=hang
  run run_zsh 'source "$VPN_SECRET_PROTECTED_CONTEXT"; _vpn_config_copy_inventory'
  [ "$status" -eq 124 ]
  [ -z "$output" ]
  [ ! -e "$HOME/find.calls" ]
  [ ! -e "$HOME/metadata.calls" ]
  ! grep -qFx 'sudo -v' "$MOCK_SUDO_LOG" || false
}

@test "vpn retained inventory: oversized listings and cold timestamps are refused without escalation" {
  secret_protected_context
  run run_zsh '
    source "$VPN_SECRET_PROTECTED_CONTEXT"
    local _VPN_MAX_PROFILE_BYTES=8
    _vpn_config_copy_inventory
  '
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -e "$HOME/metadata.calls" ]
  run run_zsh '
    source "$VPN_SECRET_PROTECTED_CONTEXT"
    local first_path="$VPN_CONFIG_DIR/wg0.conf.pre-restore"
    local _VPN_MAX_PROFILE_BYTES=$(( ${#first_path} + 1 ))
    _vpn_config_copy_inventory
  '
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -e "$HOME/metadata.calls" ]
  local before_count
  before_count=$(wc -l < "$HOME/find.calls")
  rm -- "$VPN_SECRET_AUTH"
  run run_zsh 'source "$VPN_SECRET_PROTECTED_CONTEXT"; _vpn_config_copy_inventory'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(wc -l < "$HOME/find.calls")" -eq "$before_count" ]
  ! grep -qFx 'sudo -v' "$MOCK_SUDO_LOG" || false
}

@test "vpn retained inventory: timeout bounds validate before sudo and standalone requires a bounded backend" {
  local value
  for value in 0 601 invalid; do
    export VPN_SECRET_TIMEOUT="$value"
    run run_zsh '_vpn_sudo_probe --timeout "$VPN_SECRET_TIMEOUT" find "$VPN_CONFIG_DIR"'
    [ "$status" -eq 2 ]
    [ ! -s "$MOCK_SUDO_LOG" ]
  done
  run zsh -f -c '
    emulate -R zsh
    source "$TEST_SUITE_ROOT/functions/vpn-common.zsh" || exit 90
    PATH="$TEST_MOCK_BIN"
    _vpn_sudo_probe --timeout 5 find "$VPN_CONFIG_DIR"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"timeout or gtimeout"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

secret_backup_interrupt_probe() {
  export VPN_SECRET_FAIL=backup-interrupt VPN_SECRET_INTERRUPT="$1"
  run run_zsh 'vpn-profile-remove wg0 --with-backup --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr"'
  if [ "$status" -ne "$1" ]; then
    printf 'actual-status=%s expected-interruption=%s\n' "$status" "$1" >&2
    cat "$VPN_SECRET_MUTATIONS" "$HOME/remove.stderr" >&2
    false
  fi
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  run grep -Fx -- "rm -- $VPN_CONFIG_DIR/wg0.conf.pre-restore" "$VPN_SECRET_MUTATIONS"
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/remove.stdout" ]
  grep -qF 'profile was already removed' "$HOME/remove.stderr"
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
}

@test "vpn secret interruption: backup status130 stops the new undo deletion" { secret_backup_interrupt_probe 130; }
@test "vpn secret interruption: backup status143 stops the new undo deletion" { secret_backup_interrupt_probe 143; }

secret_undo_interrupt_probe() {
  export VPN_SECRET_FAIL=undo-remove-interrupt VPN_SECRET_INTERRUPT="$1"
  run run_zsh 'vpn-profile-remove wg0 --with-backup --yes >"$HOME/remove.stdout" 2>"$HOME/remove.stderr"'
  if [ "$status" -ne "$1" ]; then
    printf 'actual-status=%s expected-interruption=%s\n' "$status" "$1" >&2
    cat "$VPN_SECRET_MUTATIONS" "$HOME/remove.stderr" >&2
    printf 'remaining-default=%s remaining-last=%s\n' "$(cat "$VPN_CACHE_DIR/default-iface" 2>/dev/null)" "$(cat "$VPN_CACHE_DIR/last-iface" 2>/dev/null)" >&2
    false
  fi
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]
  cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
}

@test "vpn secret interruption: undo status130 stops saved choice changes" { secret_undo_interrupt_probe 130; }
@test "vpn secret interruption: undo status143 stops saved choice changes" { secret_undo_interrupt_probe 143; }

@test "vpn secret interruption: interrupted undo rename rolls earlier files back before saved choices" {
  local code
  for code in 130 143; do
    export VPN_SECRET_FAIL=undo-interrupt VPN_SECRET_INTERRUPT="$code"
    run run_zsh 'vpn-profile-rename wg0 office --yes >"$HOME/rename.stdout" 2>"$HOME/rename.stderr"'
    [ "$status" -eq "$code" ]
    cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
    cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
    cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
    [ ! -e "$VPN_CONFIG_DIR/office.conf" ]
    [ ! -e "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu" ]
    [ ! -s "$HOME/rename.stdout" ]
    grep -qF 'Rollback completed' "$HOME/rename.stderr"
    [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
    [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
  done
}

@test "vpn secret interruption: failed undo publication stops restore before replacing the profile" {
  local code
  for code in 130 143; do
    export VPN_SECRET_FAIL=restore-undo-interrupt VPN_SECRET_INTERRUPT="$code"
    run run_zsh 'vpn-config-restore wg0 --yes >"$HOME/restore.stdout" 2>"$HOME/restore.stderr"'
    # Existing restore status mapping remains unchanged; the failed undo step
    # must stop publication before any later live-profile replacement.
    [ "$status" -eq 1 ]
    cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
    cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
    cmp "$HOME/expected/undo" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
    [ ! -s "$HOME/restore.stdout" ]
    [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
    [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
  done
}
