#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  vpn_pin_kernel Linux
  export VPN_CONFIG_DIR="$HOME/wireguard" VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"
  export VPN_KEYS_PROFILE="$VPN_CONFIG_DIR/wg0.conf"
  export MOCK_SUDO_ALLOW='true,__validate__,test,head,install,mktemp,ln,rm,mv,wg-quick'
  mkdir -p "$VPN_CONFIG_DIR"
  chmod -- 700 "$VPN_CONFIG_DIR"
}

teardown() {
  chmod -- 600 "$VPN_KEYS_PROFILE" 2>/dev/null || true
  cleanup_sandbox
}

keys_profile() {
  printf '%b' "$1" > "$VPN_KEYS_PROFILE"
  chmod -- 600 "$VPN_KEYS_PROFILE"
  cp "$VPN_KEYS_PROFILE" "$HOME/original.conf"
}

keys_harden() {
  run run_zsh '
    _vpn_test_resolv_conf() { return 0; }
    _vpn_apply_wsl_dns_hooks "$VPN_KEYS_PROFILE" >"$HOME/harden.out" 2>"$HOME/harden.err"
  '
}

@test "vpn WSL keys: the direct DNS reader recognizes lowercase keys" {
  keys_profile '[interface]\nPrivateKey = FIXTURE=\n dns = 10.64.0.53\n[peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  run run_zsh '_vpn_dns_from_conf wg0'
  [ "$status" -eq 0 ]
  [ "$output" = '10.64.0.53' ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn WSL keys: the warm DNS reader recognizes mixed case and drops comments" {
  keys_profile '[InTeRfAcE]\nPrivateKey = FIXTURE=\n\tDnS\t=\t10.64.0.53, 10.64.0.54 # resolver comment\r\n[PeEr]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  export VPN_KEYS_REAL_HEAD
  VPN_KEYS_REAL_HEAD=$(command -v head)
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/head"
  cat >> "$TEST_MOCK_BIN/head" <<'MOCK'
if [[ "$#" == 1 && "$1" == -1 ]]; then
  exec "$VPN_KEYS_REAL_HEAD" -1
fi
[[ "${MOCK_SUDO_ROOT:-0}" == 1 && "$#" == 4 && "$1" == -c \
  && "$2" == 1048576 && "$3" == -- && "$4" == "$VPN_KEYS_PROFILE" \
  && "$HOME" == "$TEST_TEMP_DIR/home" && ! -L "$HOME/original.conf" ]] || exit 97
exec "$VPN_KEYS_REAL_HEAD" -c 1048576 -- "$HOME/original.conf"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/head"
  chmod -- 000 "$VPN_KEYS_PROFILE"
  run run_zsh '_vpn_dns_from_conf wg0'
  chmod -- 600 "$VPN_KEYS_PROFILE"
  [ "$status" -eq 0 ]
  [ "$output" = '10.64.0.53, 10.64.0.54' ]
  grep -Fq -- 'sudo -n -- head -c' "$MOCK_SUDO_LOG"
  run grep -F -- 'sudo -v' "$MOCK_SUDO_LOG"
  [ "$status" -eq 1 ]
}

@test "vpn WSL keys: repeated DNS declarations retain their order" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\nDNS = 10.64.0.53\ndNs = 10.64.0.54\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  run run_zsh '_vpn_dns_from_conf wg0'
  [ "$status" -eq 0 ]
  [ "$output" = '10.64.0.53, 10.64.0.54' ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn WSL keys: lowercase DNS hardening uses the tunnel resolver and removes its declaration" {
  keys_profile '[interface]\nPrivateKey = FIXTURE=\nAddress = 10.0.0.2/24\ndns = 10.64.0.53\n[peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  keys_harden
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/harden.out" ]
  grep -Fq -- 'nameserver 10.64.0.53\n' "$VPN_KEYS_PROFILE"
  run grep -Ei -- '^[[:space:]]*dns[[:space:]]*=' "$VPN_KEYS_PROFILE"
  [ "$status" -eq 1 ]
}

@test "vpn WSL keys: mixed case padding CRLF and comments preserve reviewed hooks" {
  keys_profile ' \t[InTeRfAcE] \t# interface\r\nPrivateKey = FIXTURE=\r\nAddress = 10.0.0.2/24\r\n\tDnS = 10.64.0.53 # resolver note\r\nPreUp = echo reviewed-fixture\r\n# DNS = not a declaration\r\n \t[PeEr] \t# peer\r\nPublicKey = PEER=\r\nAllowedIPs = 0.0.0.0/0\r\n'
  keys_harden
  [ "$status" -eq 0 ]
  grep -Fq -- 'nameserver 10.64.0.53\n' "$VPN_KEYS_PROFILE"
  grep -Fq -- '# resolver note' "$VPN_KEYS_PROFILE"
  grep -Fq -- 'PreUp = echo reviewed-fixture' "$VPN_KEYS_PROFILE"
  grep -Fq -- '# DNS = not a declaration' "$VPN_KEYS_PROFILE"
  grep -Fq -- '[PeEr]' "$VPN_KEYS_PROFILE"
  run grep -Ei -- '^[[:space:]]*dns[[:space:]]*=' "$VPN_KEYS_PROFILE"
  [ "$status" -eq 1 ]
}

@test "vpn WSL keys: an unsafe lowercase DNS value is refused before staging or privilege" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\ndns = 10.64.0.53; touch BAD-CANARY\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  keys_harden
  [ "$status" -eq 1 ]
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -e "$HOME/BAD-CANARY" ]
  [ ! -s "$HOME/harden.out" ]
}

@test "vpn WSL keys: later unsafe DNS declarations cannot hide behind an earlier valid value" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\nDNS = 10.64.0.53\ndNs = 10.64.0.54; touch BAD-CANARY\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  keys_harden
  [ "$status" -eq 1 ]
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -e "$HOME/BAD-CANARY" ]
}

@test "vpn WSL keys: absent DNS retains the documented fallback and exact hooks remain idempotent" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\nAddress = 10.0.0.2/24\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  keys_harden
  [ "$status" -eq 0 ]
  grep -Fq -- 'nameserver 1.1.1.1\n' "$VPN_KEYS_PROFILE"
  cp "$VPN_KEYS_PROFILE" "$HOME/hardened.conf"
  : > "$MOCK_SUDO_LOG"
  keys_harden
  [ "$status" -eq 0 ]
  cmp "$HOME/hardened.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn WSL keys: lowercase IPv6 fields lose only their IPv6 components" {
  keys_profile '[interface]\nPrivateKey = FIXTURE=\naddress = 10.0.0.2/24, fd00::2/128\ndns = 10.64.0.53, 2001:db8::53\n[peer]\nPublicKey = PEER=\nallowedips = 0.0.0.0/0, ::/0\n'
  run run_zsh '_vpn_fix_ipv6_config wg0'
  [ "$status" -eq 0 ]
  grep -Fq -- 'address = 10.0.0.2/24' "$VPN_KEYS_PROFILE"
  grep -Fq -- 'dns = 10.64.0.53' "$VPN_KEYS_PROFILE"
  grep -Fq -- 'allowedips = 0.0.0.0/0' "$VPN_KEYS_PROFILE"
  run grep -F -- '::' "$VPN_KEYS_PROFILE"
  [ "$status" -eq 1 ]
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE.bak-vpn-menu"
}

@test "vpn WSL keys: mixed case IPv6 rewriting preserves comments and existing backup bytes" {
  keys_profile ' \t[InTeRfAcE] # interface\r\nPrivateKey = FIXTURE=\r\n\tAdDrEsS = 10.0.0.2/24, fd00::2/128 # address note: keep\r\nDnS = 10.64.0.53, 2001:db8::53 # resolver note\r\n# dns = comment::only\r\nPostUp = echo reviewed-fixture\r\n[PeEr] # peer\r\nPublicKey = PEER=\r\naLlOwEdIpS = 0.0.0.0/0, ::/0 # route note\r\nEndpoint = 203.0.113.7:51820\r\n'
  printf 'OLDER-REVIEWED-BACKUP\n' > "$VPN_KEYS_PROFILE.bak-vpn-menu"
  chmod -- 600 "$VPN_KEYS_PROFILE.bak-vpn-menu"
  run run_zsh '_vpn_fix_ipv6_config wg0'
  [ "$status" -eq 0 ]
  grep -Fq -- 'AdDrEsS = 10.0.0.2/24 # address note: keep' "$VPN_KEYS_PROFILE"
  grep -Fq -- 'DnS = 10.64.0.53 # resolver note' "$VPN_KEYS_PROFILE"
  grep -Fq -- 'aLlOwEdIpS = 0.0.0.0/0 # route note' "$VPN_KEYS_PROFILE"
  grep -Fq -- '# dns = comment::only' "$VPN_KEYS_PROFILE"
  grep -Fq -- 'PostUp = echo reviewed-fixture' "$VPN_KEYS_PROFILE"
  grep -Fq -- 'Endpoint = 203.0.113.7:51820' "$VPN_KEYS_PROFILE"
  [ "$(cat "$VPN_KEYS_PROFILE.bak-vpn-menu")" = OLDER-REVIEWED-BACKUP ]
}

@test "vpn WSL keys: an IPv6-only lowercase field fails before privilege or publication" {
  keys_profile '[interface]\nPrivateKey = FIXTURE=\naddress = fd00::2/128\n[peer]\nPublicKey = PEER=\nallowedips = ::/0\n'
  run run_zsh '_vpn_fix_ipv6_config wg0'
  [ "$status" -eq 1 ]
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -e "$VPN_KEYS_PROFILE.bak-vpn-menu" ]
}

@test "vpn WSL keys: every peer AllowedIPs field is rewritten and the first backup is retained" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\nAddress = 10.0.0.2/24, fd00::2/128\n[peer]\nPublicKey = PEER-ONE=\nallowedips = 10.1.0.0/16, 2001:db8:1::/48\n[PEER]\nPublicKey = PEER-TWO=\nAlLoWeDiPs = 10.2.0.0/16, 2001:db8:2::/48\n'
  run run_zsh '_vpn_fix_ipv6_config wg0'
  [ "$status" -eq 0 ]
  grep -Fq -- 'allowedips = 10.1.0.0/16' "$VPN_KEYS_PROFILE"
  grep -Fq -- 'AlLoWeDiPs = 10.2.0.0/16' "$VPN_KEYS_PROFILE"
  run grep -F -- '2001:' "$VPN_KEYS_PROFILE"
  [ "$status" -eq 1 ]
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE.bak-vpn-menu"
  cp "$VPN_KEYS_PROFILE" "$HOME/ipv4.conf"
  run run_zsh '_vpn_fix_ipv6_config wg0'
  [ "$status" -eq 0 ]
  cmp "$HOME/ipv4.conf" "$VPN_KEYS_PROFILE"
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE.bak-vpn-menu"
}

@test "vpn WSL keys: an explicit empty DNS value cannot authorize the fallback" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\nDNS = # empty declaration\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  keys_harden
  [ "$status" -eq 1 ]
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn WSL keys: the combined DNS declarations retain the existing eight-address bound" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\nDNS = 10.0.0.1, 10.0.0.2, 10.0.0.3, 10.0.0.4\ndns = 10.0.0.5, 10.0.0.6, 10.0.0.7, 10.0.0.8, 10.0.0.9\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  keys_harden
  [ "$status" -eq 1 ]
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn WSL keys: repeated declarations retain the existing total DNS byte bound" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\nDNS = 1234:1234:1234:1234:1234:1234:1234:1231, 1234:1234:1234:1234:1234:1234:1234:1232, 1234:1234:1234:1234:1234:1234:1234:1233, 1234:1234:1234:1234:1234:1234:1234:1234\ndns = 1234:1234:1234:1234:1234:1234:1234:1235, 1234:1234:1234:1234:1234:1234:1234:1236, 1234:1234:1234:1234:1234:1234:1234:1237, 1234:1234:1234:1234:1234:1234:1234:1238\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  keys_harden
  [ "$status" -eq 1 ]
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn WSL keys: a NUL-obscured DNS key cannot authorize the fallback" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\nd\000ns = 10.64.0.53\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  keys_harden
  if [ "$status" -ne 1 ]; then
    printf 'actual-status=%s\n' "$status" >&2
    cat "$HOME/harden.err" "$MOCK_SUDO_LOG" >&2
    false
  fi
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn WSL keys: an uncommented empty DNS declaration cannot authorize the fallback" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\ndNs = \n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n'
  keys_harden
  [ "$status" -eq 1 ]
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn WSL keys: a NUL-obscured DNS key stops IPv6 rewriting before publication" {
  keys_profile '[Interface]\nPrivateKey = FIXTURE=\nAddress = 10.0.0.2/24, fd00::2/128\nd\000ns = 10.64.0.53, 2001:db8::53\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0, ::/0\n'
  run run_zsh '_vpn_fix_ipv6_config wg0'
  if [ "$status" -ne 1 ]; then
    printf 'actual-status=%s\n' "$status" >&2
    cat "$MOCK_SUDO_LOG" >&2
    false
  fi
  cmp "$HOME/original.conf" "$VPN_KEYS_PROFILE"
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -e "$VPN_KEYS_PROFILE.bak-vpn-menu" ]
}

@test "vpn WSL keys: a valid DNS list at the existing byte boundary stays supported" {
  local address='111:111:111:111:111:111:111:111' values='' index
  for index in 1 2 3 4 5 6 7 8; do
    [[ -z "$values" ]] || values+=,
    values+="$address"
  done
  [ "${#values}" -eq 255 ]
  keys_profile "[Interface]\nPrivateKey = FIXTURE=\nDNS=$values\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n"
  keys_harden
  [ "$status" -eq 0 ]
  grep -Fq -- "nameserver $address\\n" "$VPN_KEYS_PROFILE"
}
