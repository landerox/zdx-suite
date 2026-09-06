#!/usr/bin/env bats

setup() {
  load test_helper

  export VPN_PROFILE_DIR="$HOME/wireguard"
  export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
  export VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"

  mkdir -p "$VPN_PROFILE_DIR"
  chmod 700 "$VPN_PROFILE_DIR"
}

teardown() {
  cleanup_sandbox
}

write_profile_file() {
  local target="$1"
  local interface_extra="${2-}"

  mkdir -p "$(dirname "$target")"
  {
    printf '[Interface]\n'
    printf 'PrivateKey = TEST-PRIVATE-KEY=\n'
    printf 'Address = 10.0.0.2/24\n'
    [[ -n "$interface_extra" ]] && printf '%s\n' "$interface_extra"
    printf '\n[Peer]\n'
    printf 'PublicKey = TEST-PEER-KEY=\n'
    printf 'AllowedIPs = 0.0.0.0/0\n'
    printf 'Endpoint = 203.0.113.10:51820\n'
  } > "$target"
  chmod 600 "$target"
}

install_fixed_date_mock() {
  cat > "$TEST_MOCK_BIN/date" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  +%Y-%m-%d_%H%M%S) printf '%s\n' '2026-07-26_010203' ;;
  +%Y%m%d_%H%M%S) printf '%s\n' '20260726_010203' ;;
  +*) printf '%s\n' '2026-07-26 01:02:03 VET' ;;
  *) printf '%s\n' '2026-07-26 01:02:03 VET' ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/date"
}

# --- Profile-directory boundary --------------------------------------------

@test "vpn hardening: filesystem root is rejected before sudo" {
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    VPN_CONFIG_DIR=/
    vpn-profile-create wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"protected VPN_CONFIG_DIR"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: a relative profile directory is rejected before sudo" {
  mkdir -p "$HOME/relative-wireguard"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    cd "$HOME" || return 1
    VPN_CONFIG_DIR=relative-wireguard
    vpn-profile-create wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"absolute path"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: traversal in the profile directory is rejected before sudo" {
  mkdir -p "$HOME/base" "$HOME/wireguard"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    VPN_CONFIG_DIR="$HOME/base/../wireguard"
    vpn-profile-create wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"must not contain '..'"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: any symlinked profile-directory component is rejected before sudo" {
  mkdir -p "$HOME/real-config/wireguard"
  ln -s "$HOME/real-config" "$HOME/config-link"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    VPN_CONFIG_DIR="$HOME/config-link/wireguard"
    vpn-profile-create wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink component"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ -z "$(find "$HOME/real-config/wireguard" -mindepth 1 -print -quit)" ]
}

# --- Imported profile trust boundary ---------------------------------------

@test "vpn hardening: imported profiles reject every wg-quick hook by default" {
  local hook
  for hook in PreUp PostUp PreDown PostDown; do
    write_profile_file \
      "$HOME/import-${hook}.conf" \
      "${hook} = touch $HOME/root-hook-${hook}"
  done
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    local hook
    for hook in PreUp PostUp PreDown PostDown; do
      if vpn-profile-import "$HOME/import-${hook}.conf"; then
        print -u2 -r -- "unsafe hook accepted: $hook"
        return 40
      fi
    done
    return 0
  '

  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ -z "$(find "$VPN_PROFILE_DIR" -mindepth 1 -print -quit)" ]
}

@test "vpn hardening: profile import rejects a symlink source" {
  write_profile_file "$HOME/source-target.conf"
  ln -s "$HOME/source-target.conf" "$HOME/source-link.conf"
  : > "$MOCK_SUDO_LOG"

  run run_zsh 'vpn-profile-import "$HOME/source-link.conf"'

  [ "$status" -eq 1 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: profile import rejects a multiply linked source" {
  write_profile_file "$HOME/source-original.conf"
  ln "$HOME/source-original.conf" "$HOME/source-hardlink.conf"
  : > "$MOCK_SUDO_LOG"

  run run_zsh 'vpn-profile-import "$HOME/source-hardlink.conf"'

  [ "$status" -eq 1 ]
  [ "$(stat -c '%h' "$HOME/source-original.conf")" -eq 2 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: profile import rejects a source larger than one MiB" {
  local oversized="$HOME/source-oversized.conf"
  write_profile_file "$oversized"
  truncate -s 1048577 "$oversized"
  chmod 600 "$oversized"
  : > "$MOCK_SUDO_LOG"

  run run_zsh 'vpn-profile-import "$HOME/source-oversized.conf"'

  [ "$status" -eq 1 ]
  [ "$(stat -c '%s' "$oversized")" -gt 1048576 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

# --- Installed profile identity and privacy --------------------------------

@test "vpn hardening: inventory and existence reject unsafe profile files" {
  write_profile_file "$VPN_PROFILE_DIR/safe.conf"

  write_profile_file "$HOME/symlink-target.conf"
  ln -s "$HOME/symlink-target.conf" "$VPN_PROFILE_DIR/symlinked.conf"

  write_profile_file "$VPN_PROFILE_DIR/hardlinked.conf"
  ln "$VPN_PROFILE_DIR/hardlinked.conf" "$HOME/hardlink-peer.conf"

  write_profile_file "$VPN_PROFILE_DIR/public.conf"
  chmod 644 "$VPN_PROFILE_DIR/public.conf"

  run run_zsh '
    local inventory
    inventory=$(_vpn_get_configs 2>/dev/null)

    [[ "$inventory" == "safe" ]] || return 10

    _vpn_config_exists safe || return 11
    _vpn_config_exists symlinked && return 12
    _vpn_config_exists hardlinked && return 13
    _vpn_config_exists public && return 14
    return 0
  '

  [ "$status" -eq 0 ]
}

# --- DNS parser --------------------------------------------------------------

@test "vpn hardening: DNS validation enforces numeric IPv4 and structural IPv6" {
  run run_zsh '
    local candidate
    for candidate in \
      256.0.0.1 \
      1.2.3.999 \
      :::: \
      2001:db8:::1 \
      1:2:3:4:5:6:7:8:9 \
      2001:db8:1; do
      _vpn_validate_dns_list "$candidate" && return 10
    done

    for candidate in \
      0.0.0.0 \
      255.255.255.255 \
      ::1 \
      2001:db8::1 \
      2001:db8:0:1:1:1:1:1; do
      _vpn_validate_dns_list "$candidate" || return 20
    done
    _vpn_validate_dns_list "1.1.1.1, 2001:4860:4860::8888"
  '

  [ "$status" -eq 0 ]
}

# --- Picker records ----------------------------------------------------------

@test "vpn hardening: ambiguous picker output is rejected" {
  run run_zsh '
    _vpn_sanitize_iface_capture $'"'"'wg0\nwg1'"'"' && return 10
    _vpn_sanitize_iface_capture $'"'"'wg0\nwg0'"'"' && return 11
    _vpn_sanitize_iface_capture $'"'"'invalid/name\nwg0'"'"' && return 12
    [[ "$(_vpn_sanitize_iface_capture $'"'"'\n wg0 \n'"'"')" == "wg0" ]]
  '

  [ "$status" -eq 0 ]
}

# --- Cache persistence -------------------------------------------------------

@test "vpn hardening: cache rejects a symlink in any directory component" {
  mkdir -p "$HOME/cache-real"
  chmod 700 "$HOME/cache-real"
  ln -s "$HOME/cache-real" "$HOME/cache-link"

  run run_zsh '
    VPN_CACHE_DIR="$HOME/cache-link/vpn"
    _vpn_set_default_iface wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink"* ]]
  [ -z "$(find "$HOME/cache-real" -mindepth 1 -print -quit)" ]
}

@test "vpn hardening: cache rejects a multiply linked entry without modifying it" {
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  printf '%s\n' old-profile > "$HOME/cache-anchor"
  chmod 600 "$HOME/cache-anchor"
  ln "$HOME/cache-anchor" "$VPN_CACHE_DIR/default-iface"
  local before
  before=$(stat -c '%d:%i:%h:%a' "$HOME/cache-anchor")

  run run_zsh '
    _vpn_peek_default_iface >/dev/null && return 10
    _vpn_set_default_iface wg0
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/cache-anchor")" = "old-profile" ]
  [ "$(stat -c '%d:%i:%h:%a' "$HOME/cache-anchor")" = "$before" ]
}

@test "vpn hardening: cache rejects a public entry without repairing it in place" {
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  printf '%s\n' old-profile > "$VPN_CACHE_DIR/default-iface"
  chmod 644 "$VPN_CACHE_DIR/default-iface"
  local before
  before=$(stat -c '%d:%i:%a' "$VPN_CACHE_DIR/default-iface")

  run run_zsh '
    _vpn_peek_default_iface >/dev/null && return 10
    _vpn_set_default_iface wg0
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = "old-profile" ]
  [ "$(stat -c '%d:%i:%a' "$VPN_CACHE_DIR/default-iface")" = "$before" ]
}

@test "vpn hardening: cache updates use private atomic replacement" {
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  printf '%s\n' old-profile > "$VPN_CACHE_DIR/default-iface"
  chmod 600 "$VPN_CACHE_DIR/default-iface"
  local before_inode
  before_inode=$(stat -c '%d:%i' "$VPN_CACHE_DIR/default-iface")

  run run_zsh '_vpn_set_default_iface wg0'

  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = "wg0" ]
  [ "$(stat -c '%a' "$VPN_CACHE_DIR/default-iface")" = "600" ]
  [ "$(stat -c '%d:%i' "$VPN_CACHE_DIR/default-iface")" != "$before_inode" ]
  [ "$(find "$VPN_CACHE_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 ]
}

@test "vpn hardening: a failed cache publication preserves the old entry" {
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  printf '%s\n' old-profile > "$VPN_CACHE_DIR/default-iface"
  chmod 600 "$VPN_CACHE_DIR/default-iface"
  local before
  before=$(stat -c '%d:%i:%a' "$VPN_CACHE_DIR/default-iface")

  cat > "$TEST_MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
exit 73
EOF
  chmod +x "$TEST_MOCK_BIN/mv"

  run run_zsh '_vpn_set_default_iface wg0'

  [ "$status" -eq 1 ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = "old-profile" ]
  [ "$(stat -c '%d:%i:%a' "$VPN_CACHE_DIR/default-iface")" = "$before" ]
  [ "$(find "$VPN_CACHE_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 ]
}

# --- Report publication ------------------------------------------------------

@test "vpn hardening: same-second reports publish unique private files" {
  install_fixed_date_mock

  run run_zsh '
    _vpn_check_wg_quick() { return 0; }
    _vpn_check_ip_stack() { return 0; }
    _vpn_have_sudo_cache() { return 1; }
    _vpn_should_apply_wsl_ipv6_fix() { return 1; }
    _vpn_configs_access_state() { print -r -- direct; }
    _vpn_wg_access_state() { print -r -- direct; }
    _vpn_dns_resolvers() { return 1; }
    _vpn_get_active_interfaces() { return 0; }
    _vpn_get_ip_info() { return 1; }
    _vpn_get_ip_crosscheck() { return 1; }

    vpn-report || return 10
    vpn-report || return 11
  '

  [ "$status" -eq 0 ]
  [ "$(find "$VPN_MENU_REPORT_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 2 ]
  local report_file
  while IFS= read -r report_file; do
    [ "$(stat -c '%a' "$report_file")" = "600" ]
    grep -q '^# VPN Diagnostic Report' "$report_file"
  done < <(find "$VPN_MENU_REPORT_DIR" -mindepth 1 -maxdepth 1 -type f)
}

@test "vpn hardening: report retention keeps the newest reports and skips unsafe entries" {
  mkdir -p "$VPN_MENU_REPORT_DIR"
  chmod 700 "$VPN_MENU_REPORT_DIR"
  local index
  for index in 1 2 3 4 5; do
    printf 'old %s\n' "$index" \
      > "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-0${index}_000000-host.md"
    chmod 600 "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-0${index}_000000-host.md"
  done
  printf 'unsafe\n' \
    > "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000001-host.md"
  chmod 644 "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000001-host.md"
  printf 'published\n' \
    > "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_000000-host.md"
  chmod 600 "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_000000-host.md"

  run run_zsh '
    export VPN_MENU_REPORT_RETENTION=3
    _vpn_report_prune \
      "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_000000-host.md" \
      vpn-report md
  '

  [ "$status" -eq 0 ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_000000-host.md" ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-04_000000-host.md" ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-05_000000-host.md" ]
  [ ! -e "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000000-host.md" ]
  [ ! -e "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-02_000000-host.md" ]
  [ ! -e "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-03_000000-host.md" ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000001-host.md" ]
}

@test "vpn hardening: invalid report retention fails closed before any report work" {
  run run_zsh '
    export VPN_MENU_REPORT_RETENTION=many
    _vpn_report_temp_create() {
      print -r -- unexpected-report-staging
      return 1
    }
    vpn-report
  '

  [ "$status" -eq 2 ]
  [[ "$output" == *"must be an integer from 0 through 1000"* ]]
  [[ "$output" != *"unexpected-report-staging"* ]]
}

@test "vpn hardening: pre-restore undo copies are visible in the inventory" {
  write_profile_file "$VPN_PROFILE_DIR/wg0.conf"
  write_profile_file "$VPN_PROFILE_DIR/wg1.conf"
  write_profile_file "$VPN_PROFILE_DIR/wg0.conf.pre-restore"

  run run_zsh 'vpn-config-dir'

  [ "$status" -eq 0 ]
  [[ "$output" == *"wg0.conf"* ]]
  [[ "$output" == *"wg1.conf"* ]]
  [[ "$output" == *"pre-restore undo: kept"* ]]
  [ "$(grep -c 'pre-restore undo' <<<"$output")" -eq 1 ]
}

@test "vpn hardening: report failure clears its target and removes staged output" {
  install_fixed_date_mock

  run run_zsh '
    _vpn_check_wg_quick() { return 0; }
    _vpn_check_ip_stack() { return 0; }
    _vpn_have_sudo_cache() { return 1; }
    _vpn_rpt_h1() { return 73; }

    local -i report_status=0
    vpn-report || report_status=$?
    (( report_status != 0 )) || return 10
    [[ -z "$_VPN_REPORT_TARGET" ]] || return 11
    [[ -z "$(command find "$VPN_MENU_REPORT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]
  '

  [ "$status" -eq 0 ]
}

# --- Broad disconnect plan ---------------------------------------------------

@test "vpn hardening: vpn-off-all dry-run performs zero sudo calls" {
  cat > "$TEST_MOCK_BIN/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "show interfaces" ]]; then
  printf '%s\n' 'wg0 wg1'
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/wg"
  : > "$MOCK_SUDO_LOG"

  run run_zsh 'vpn-off-all --dry-run'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Plan: bring down 2 interface(s): wg0 wg1"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}
