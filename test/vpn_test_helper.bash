# vpn_test_helper.bash - VPN platform fixtures, loaded after test_helper.
#
# The VPN suite chooses Linux, WSL, or macOS behavior from `uname -s`. A
# mocked platform branch is selected through capability mocks, never by the
# host (docs/testing.md), so every VPN file pins the kernel it exercises and
# the same assertions hold on a Linux runner and on a macOS host.

# vpn_pin_kernel NAME: answer `uname -s` with NAME (Linux, Darwin, FreeBSD).
# Other uname queries reach the host binary.
vpn_pin_kernel() {
  cat > "$TEST_MOCK_BIN/uname" <<EOF
#!$BASH
if [[ "\${1:-}" == -s ]]; then
  printf '%s\\n' '$1'
  exit 0
fi
exec /usr/bin/uname "\$@"
EOF
  chmod 755 "$TEST_MOCK_BIN/uname"
}

# vpn_darwin_fixture: a macOS host with Homebrew wireguard-tools in the
# sandbox. It provides a Homebrew prefix ($VPN_BREW) whose bin directory leads
# PATH with a real Bash 4+ link, recording wg-quick, wg, and wireguard-go
# mocks, and a `brew --prefix` that names it; BSD ifconfig, route, netstat, and
# scutil mocks; a private wg-quick runtime directory ($VPN_RUN_DIR); and a
# Zsh setup file ($VPN_DARWIN_SETUP) that points the suite's private macOS
# locations at those fixtures. wg-quick calls are appended to
# $VPN_WG_QUICK_LOG as "<interpreter-free argv>".
vpn_darwin_fixture() {
  vpn_pin_kernel Darwin

  export VPN_BREW="$TEST_TEMP_DIR/homebrew"
  export VPN_RUN_DIR="$TEST_TEMP_DIR/run-wireguard"
  export VPN_WG_QUICK_LOG="$TEST_TEMP_DIR/wg-quick.calls"
  export VPN_WG_DEVICES=""
  export VPN_DARWIN_SETUP="$TEST_TEMP_DIR/darwin-setup.zsh"
  mkdir -p "$VPN_BREW/bin" "$VPN_BREW/etc" "$VPN_RUN_DIR"
  chmod 755 "$VPN_BREW" "$VPN_BREW/bin" "$VPN_BREW/etc" "$VPN_RUN_DIR"
  : > "$VPN_WG_QUICK_LOG"

  # Homebrew's Bash: the real interpreter running these tests (4.1 or newer).
  ln -s "$BASH" "$VPN_BREW/bin/bash"

  cat > "$VPN_BREW/bin/wg-quick" <<EOF
#!$BASH
printf '%s\\n' "\$*" >> "\$VPN_WG_QUICK_LOG"
exit "\${VPN_WG_QUICK_STATUS:-0}"
EOF

  # wg lists devices without privileges; per-device state needs root, as on
  # macOS, where the UAPI socket is mode 0700 and owned by root.
  cat > "$VPN_BREW/bin/wg" <<EOF
#!$BASH
case "\${1:-}" in
  --version)
    printf '%s\\n' 'wireguard-tools v1.0.20250521 - https://git.zx2c4.com/wireguard-tools/'
    exit 0
    ;;
  show) ;;
  *) exit 1 ;;
esac
if [[ "\${2:-}" == interfaces ]]; then
  [[ -z "\$VPN_WG_DEVICES" ]] || printf '%s\\n' "\$VPN_WG_DEVICES"
  exit 0
fi
if [[ "\${MOCK_SUDO_ROOT:-0}" != 1 ]]; then
  printf 'Unable to access interface: Permission denied\\n' >&2
  exit 1
fi
case "\${3:-}" in
  endpoints) printf 'PEER=\\t203.0.113.7:51820\\n' ;;
  latest-handshakes) printf 'PEER=\\t0\\n' ;;
  transfer) printf 'PEER=\\t1024\\t2048\\n' ;;
  '') printf 'interface: %s\\n  public key: TEST\\n' "\$2" ;;
  *) exit 1 ;;
esac
EOF

  cat > "$VPN_BREW/bin/wireguard-go" <<EOF
#!$BASH
exit 0
EOF

  cat > "$VPN_BREW/bin/brew" <<EOF
#!$BASH
if [[ "\$*" == --prefix ]]; then
  printf '%s\\n' "\$VPN_BREW"
  exit 0
fi
exit 1
EOF
  chmod 755 "$VPN_BREW/bin/wg-quick" "$VPN_BREW/bin/wg" \
    "$VPN_BREW/bin/wireguard-go" "$VPN_BREW/bin/brew"

  cat > "$TEST_MOCK_BIN/ifconfig" <<EOF
#!$BASH
case "\${1:-}" in
  utun5)
    printf '%s\\n' \\
      'utun5: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420' \\
      '	inet 10.64.0.2 --> 10.64.0.2 netmask 0xffffff00' \\
      '	inet6 fe80::1%utun5 prefixlen 64 scopeid 0x13' \\
      '	inet6 fd00::2 prefixlen 128' \\
      '	nd6 options=201<PERFORMNUD,DAD>'
    ;;
  *) exit 1 ;;
esac
EOF

  cat > "$TEST_MOCK_BIN/route" <<EOF
#!$BASH
[[ "\${1:-} \${2:-}" == '-n get' && -n "\${3:-}" ]] || exit 64
printf '%s\\n' \\
  "   route to: \$3" \\
  'destination: 0.0.0.0' \\
  '       mask: 128.0.0.0' \\
  '  interface: utun5' \\
  '      flags: <UP,DONE,STATIC,PRCLONING>'
EOF

  cat > "$TEST_MOCK_BIN/netstat" <<EOF
#!$BASH
[[ "\$*" == '-rn -f inet' || "\$*" == '-rn -f inet6' ]] || exit 64
printf '%s\\n' 'Routing tables' '' 'Internet:' \\
  'Destination        Gateway            Flags               Netif Expire' \\
  '0/1                utun5              USc                 utun5' \\
  'default            192.168.1.1        UGScg                 en0'
EOF

  cat > "$TEST_MOCK_BIN/scutil" <<EOF
#!$BASH
[[ "\$*" == --dns ]] || exit 64
printf '%s\\n' 'DNS configuration' '' 'resolver #1' \\
  '  nameserver[0] : 10.64.0.1' \\
  '  if_index : 19 (utun5)' \\
  '  flags    : Request A records' '' 'resolver #2' \\
  '  domain   : local' \\
  '  options  : mdns' '' 'DNS configuration (for scoped queries)' '' \\
  'resolver #1' \\
  '  nameserver[0] : 192.168.1.1' \\
  '  nameserver[1] : fe80::1%en0' \\
  '  if_index : 6 (en0)' \\
  '  flags    : Scoped, Request A records'
EOF
  chmod 755 "$TEST_MOCK_BIN/ifconfig" "$TEST_MOCK_BIN/route" \
    "$TEST_MOCK_BIN/netstat" "$TEST_MOCK_BIN/scutil"

  export PATH="$VPN_BREW/bin:$PATH"

  cat > "$VPN_DARWIN_SETUP" <<'EOF'
_VPN_DARWIN_RUN_DIR="$VPN_RUN_DIR"
_VPN_DARWIN_SYSTEM_CONFIG_DIR="$HOME/private/etc/wireguard"
# The install mock models root ownership without being root.
_VPN_DARWIN_SYSTEM_TOOLS[install]="$TEST_MOCK_BIN/install"
EOF
}

# vpn_set_mtime PATH EPOCH: set a fixture's modification time, including a
# socket's, without GNU or BSD touch differences.
vpn_set_mtime() {
  command perl -e 'utime($ARGV[1], $ARGV[1], $ARGV[0]) or die "utime: $!\n"' \
    "$1" "$2"
}

# vpn_darwin_record PROFILE DEVICE EPOCH: the .name file wireguard-go writes,
# root-only on a real host and owner-only here.
vpn_darwin_record() {
  printf '%s\n' "$2" > "$VPN_RUN_DIR/$1.name"
  chmod 400 "$VPN_RUN_DIR/$1.name"
  vpn_set_mtime "$VPN_RUN_DIR/$1.name" "$3"
}

# vpn_darwin_socket DEVICE EPOCH: the UAPI socket wireguard-go serves. It is
# bound through a relative path, so a long sandbox path cannot exceed the
# socket address limit.
vpn_darwin_socket() {
  (
    cd "$VPN_RUN_DIR" || exit 1
    zsh -fc 'zmodload zsh/net/socket && zsocket -l "$1"' _ "$1.sock"
  ) || return 1
  vpn_set_mtime "$VPN_RUN_DIR/$1.sock" "$2"
}

# vpn_darwin_profile DIR NAME: a private profile in a user-owned directory.
vpn_darwin_profile() {
  mkdir -p "$1"
  chmod 700 "$1"
  printf '[Interface]\nPrivateKey = TEST-KEY=\nAddress = 10.64.0.2/24\nDNS = 10.64.0.1\n\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 10.123.45.0/24\nEndpoint = 192.0.2.1:51820\n' \
    > "$1/$2.conf"
  chmod 600 "$1/$2.conf"
}
