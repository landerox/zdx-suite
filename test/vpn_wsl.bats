#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  vpn_pin_kernel Linux
  export TERM=dumb NO_COLOR=1
  export VPN_CONFIG_DIR="$HOME/wireguard"
  export VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"
  export WSL_DISTRO_NAME=Ubuntu
  unset VPN_MENU_WSL_IPV6_FIX
  mkdir -m 700 "$VPN_CONFIG_DIR"

  # wslinfo reports $VPN_WSL_MODE; an empty mode models a build without it.
  export VPN_WSL_MODE=nat VPN_IPV6_DEFAULT_ROUTE=""
  cat > "$TEST_MOCK_BIN/wslinfo" <<EOF
#!$BASH
[[ "\$*" == --networking-mode && -n "\$VPN_WSL_MODE" ]] || exit 1
printf '%s\\n' "\$VPN_WSL_MODE"
EOF
  cat > "$TEST_MOCK_BIN/ip" <<EOF
#!$BASH
if [[ "\$*" == '-6 route show default' ]]; then
  [[ -z "\$VPN_IPV6_DEFAULT_ROUTE" ]] || printf '%s\\n' "\$VPN_IPV6_DEFAULT_ROUTE"
  exit 0
fi
exit 1
EOF
  chmod 755 "$TEST_MOCK_BIN/wslinfo" "$TEST_MOCK_BIN/ip"
}

teardown() {
  cleanup_sandbox
}

# Runs _vpn_should_apply_wsl_ipv6_fix and prints on or off.
ipv6_gate() {
  run run_zsh '
    if _vpn_should_apply_wsl_ipv6_fix; then
      print -r -- on
    else
      print -r -- off
    fi
  '
}

@test "vpn wsl: the IPv6 rewrite follows WSL networking, not the mere presence of WSL" {
  local route='default via fe80::1 dev eth0 proto ra metric 100 pref medium'

  export VPN_WSL_MODE=nat VPN_IPV6_DEFAULT_ROUTE="$route"
  ipv6_gate
  [ "$output" = on ]

  # Mirrored networking carries IPv6: stripping ::/0 would leak it.
  export VPN_WSL_MODE=mirrored
  ipv6_gate
  [ "$output" = off ]

  # Without an IPv6 default route there is nothing to leak to.
  export VPN_IPV6_DEFAULT_ROUTE=""
  ipv6_gate
  [ "$output" = on ]

  # An older WSL without wslinfo decides by the route alone.
  export VPN_WSL_MODE="" VPN_IPV6_DEFAULT_ROUTE="$route"
  ipv6_gate
  [ "$output" = off ]
  export VPN_IPV6_DEFAULT_ROUTE=""
  ipv6_gate
  [ "$output" = on ]

  # The explicit settings win on Linux and WSL.
  export VPN_WSL_MODE=nat VPN_MENU_WSL_IPV6_FIX=0
  ipv6_gate
  [ "$output" = off ]
  export VPN_WSL_MODE=mirrored VPN_IPV6_DEFAULT_ROUTE="$route" VPN_MENU_WSL_IPV6_FIX=1
  ipv6_gate
  [ "$output" = on ]
}

@test "vpn wsl: plain Linux applies the rewrite only when it is forced" {
  unset WSL_DISTRO_NAME
  run run_zsh '
    _vpn_is_wsl() { return 1; }
    _vpn_should_apply_wsl_ipv6_fix && return 10
    VPN_MENU_WSL_IPV6_FIX=1
    _vpn_should_apply_wsl_ipv6_fix || return 11
    [[ "$(_vpn_platform)" == linux ]]
  '
  [ "$status" -eq 0 ]
}

@test "vpn wsl: vpn-on rewrites IPv6 only under NAT networking" {
  printf '[Interface]\nPrivateKey = K=\nAddress = 10.0.0.2/24, fd00::2/128\n\n[Peer]\nPublicKey = P=\nAllowedIPs = 0.0.0.0/0, ::/0\n' \
    > "$VPN_CONFIG_DIR/wg0.conf"
  chmod 600 "$VPN_CONFIG_DIR/wg0.conf"
  export VPN_FIX_CALLS="$HOME/fix.calls"
  local mode
  for mode in nat mirrored; do
    export VPN_WSL_MODE="$mode"
    export VPN_IPV6_DEFAULT_ROUTE='default via fe80::1 dev eth0'
    : > "$VPN_FIX_CALLS"
    run run_zsh '
      _vpn_fix_ipv6_config() { print -r -- "$1" >> "$VPN_FIX_CALLS"; }
      _vpn_tunnel_up() { return 0; }
      _vpn_details_sections() { return 0; }
      vpn-on wg0
    '
    [ "$status" -eq 0 ]
    if [ "$mode" = nat ]; then
      [ "$(cat "$VPN_FIX_CALLS")" = wg0 ]
    else
      [ ! -s "$VPN_FIX_CALLS" ]
    fi
  done
}

@test "vpn wsl: the platform, the IPv6 gate, and the report share one WSL detector" {
  # A WSL kernel without WSL_DISTRO_NAME, as in a service or su session.
  unset WSL_DISTRO_NAME
  cat > "$TEST_MOCK_BIN/grep" <<EOF
#!$BASH
for argument in "\$@"; do
  [[ "\$argument" == /proc/version ]] && exit 0
done
exec /usr/bin/grep "\$@"
EOF
  chmod 755 "$TEST_MOCK_BIN/grep"

  run run_zsh '
    _vpn_check_ip_stack() { return 0; }
    _vpn_get_ip_info() { return 1; }
    _vpn_get_ip_crosscheck() { return 1; }
    [[ "$(_vpn_platform)" == wsl ]] || return 10
    _vpn_should_apply_wsl_ipv6_fix || return 11
    vpn-report >/dev/null 2>&1 || return 12
  '

  [ "$status" -eq 0 ]
  local report
  report=$(find "$VPN_MENU_REPORT_DIR" -name 'vpn-report-*.md' -type f)
  grep -Fq -- '- **Platform:** wsl' "$report"
  grep -Fq -- '- **WSL:** yes' "$report"
  grep -Fq -- '- **WSL networking:** nat' "$report"
  grep -Fq -- '- **WSL IPv6 fix:** enabled' "$report"
  rm -f "$TEST_MOCK_BIN/grep"
}

@test "vpn wsl: a WSL variable on another kernel does not make the host WSL" {
  vpn_pin_kernel Darwin
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_MOCK_BIN/brew"
  chmod 755 "$TEST_MOCK_BIN/brew"
  export WSL_DISTRO_NAME=Ubuntu

  run run_zsh '
    _vpn_check_ip_stack() { return 0; }
    _vpn_get_ip_info() { return 1; }
    _vpn_get_ip_crosscheck() { return 1; }
    [[ "$(_vpn_platform)" == darwin ]] || return 10
    _vpn_should_apply_wsl_ipv6_fix && return 11
    vpn-report >/dev/null 2>&1 || return 12
  '

  [ "$status" -eq 0 ]
  local report
  report=$(find "$VPN_MENU_REPORT_DIR" -name 'vpn-report-*.md' -type f)
  grep -Fq -- '- **WSL:** no' "$report"
  ! grep -Fq 'WSL distro' "$report" || false
}

@test "vpn wsl: a resolver pin the filesystem cannot hold is reported, not ignored" {
  # WSL1's filesystem has no Linux file attributes: lsattr's ioctl fails.
  cat > "$TEST_MOCK_BIN/lsattr" <<EOF
#!$BASH
printf 'lsattr: Inappropriate ioctl for device While reading flags on %s\\n' "\${@: -1}" >&2
exit 1
EOF
  chmod 755 "$TEST_MOCK_BIN/lsattr"
  export MOCK_SUDO_ALLOW=true MOCK_SUDO_WRITE_ETC_RESOLV_CONF=1

  run run_zsh '_vpn_resolv_conf_is_symlink() { return 1; }; _vpn_test_resolv_conf'

  [ "$status" -eq 0 ]
  [[ "$output" == *"does not support file attributes (as on WSL1)"* ]]
  [[ "$output" == *"may regenerate it while the tunnel is up"* ]]

  export MOCK_CHATTR_MISSING=1
  run run_zsh '_vpn_resolv_conf_is_symlink() { return 1; }; _vpn_test_resolv_conf'

  [ "$status" -eq 0 ]
  [[ "$output" == *"chattr is not installed"* ]]
}

@test "vpn wsl: DNS leak hints and the WSL fix label name each platform" {
  run_ip_info() {
    run run_zsh '
      _vpn_active_interfaces() { reply=(wg0); _VPN_ACTIVE_DEVICES=(wg0 wg0); return 0; }
      _vpn_run_wg() { return 0; }
      _vpn_have_sudo_cache() { return 0; }
      _vpn_dns_from_conf() { print -r -- 10.0.0.53; }
      _vpn_dns_resolvers() { print -r -- 192.168.1.1; }
      _vpn_have_ip_stack() { return 0; }
      _vpn_get_ip_info() { printf "198.51.100.9\t\t\t\t\tfixture.example\n"; }
      _vpn_get_configs() { return 0; }
      vpn-ip-info
      vpn-summary
    '
  }

  run_ip_info
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tunnel DNS for wg0 (10.0.0.53) not present in /etc/resolv.conf."* ]]
  [[ "$output" == *"WSL typically routes DNS via a Windows relay"* ]]
  grep -Eq '^  WSL fix: +on$' <<<"$output"

  unset WSL_DISTRO_NAME
  cat > "$TEST_MOCK_BIN/grep" <<EOF
#!$BASH
for argument in "\$@"; do
  [[ "\$argument" == /proc/version ]] && exit 1
done
exec /usr/bin/grep "\$@"
EOF
  chmod 755 "$TEST_MOCK_BIN/grep"
  run_ip_info
  rm -f "$TEST_MOCK_BIN/grep"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not present in /etc/resolv.conf."* ]]
  [[ "$output" == *"systemd-resolved; check 'resolvectl dns'"* ]]
  [[ "$output" != *"WSL"* ]]
}
