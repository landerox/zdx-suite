#!/usr/bin/env bats
# Literal Zsh programs and per-test exported mock controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  # A Linux kernel unless a test pins another. Tests that need plain Linux
  # replace the WSL detector, because the host may itself be WSL.
  vpn_pin_kernel Linux
  export TERM=dumb NO_COLOR=1
  unset VPN_MENU_MTU_TARGET

  export MOCK_PING_LOG="$TEST_TEMP_DIR/ping.calls"
  : > "$MOCK_PING_LOG"
  export MOCK_PING_MAX=1364 MOCK_EGRESS=eth0 MOCK_IFACE_MTUS="eth0=1500"
  export MOCK_WG_DEVICES=""

  # ping: don't-fragment probes up to MOCK_PING_MAX payload bytes pass, and
  # larger ones fail silently. MOCK_PING_HINT reports the MTU like iputils,
  # MOCK_PING_FRAG an ICMP "Frag needed", MOCK_PING_EMSGSIZE a bare BSD
  # "Message too long"; MOCK_PING_LOSE_ONCE loses the first reply at one size;
  # MOCK_PING_HANG_ABOVE hangs larger probes; and MOCK_PING_FLAVOR selects
  # iputils, busybox, or darwin.
  cat > "$TEST_MOCK_BIN/ping" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_PING_LOG"
flavor="${MOCK_PING_FLAVOR:-iputils}"
if [[ "${1:-}" == -V ]]; then
  if [[ "$flavor" == busybox ]]; then
    printf '%s\n' "ping: invalid option -- 'V'" \
      'BusyBox v1.36.1 multi-call binary.' 'Usage: ping [OPTIONS] HOST' >&2
    exit 1
  fi
  printf '%s\n' 'ping from iputils 20240117'
  exit 0
fi
if [[ "$flavor" == busybox ]]; then
  printf '%s\n' 'ping: unrecognized option: M' 'Usage: ping [OPTIONS] HOST' >&2
  exit 1
fi
size=56
target=""
while (( $# > 0 )); do
  case "$1" in
    -s) size="$2"; shift 2 ;;
    --) target="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "${MOCK_PING_EPERM:-}" == 1 ]]; then
  printf 'ping: socket: Operation not permitted\n' >&2
  exit 2
fi
if [[ "${MOCK_PING_UNKNOWN_HOST:-}" == 1 ]]; then
  printf 'ping: %s: Name or service not known\n' "$target" >&2
  exit 2
fi
if [[ -n "${MOCK_PING_HANG_ABOVE:-}" ]] && (( size > MOCK_PING_HANG_ABOVE )); then
  exec sleep 30
fi
address="$target"
[[ "$target" == *[a-z]* ]] && address="${MOCK_PING_ADDRESS:-192.0.2.10}"
if [[ "$flavor" == darwin ]]; then
  printf 'PING %s (%s): %d data bytes\n' "$target" "$address" "$size"
else
  printf 'PING %s (%s) %d(%d) bytes of data.\n' \
    "$target" "$address" "$size" "$(( size + 28 ))"
fi
lost=0
if [[ "$size" == "${MOCK_PING_LOSE_ONCE:-}" && ! -e "$MOCK_PING_LOG.lost" ]]; then
  : > "$MOCK_PING_LOG.lost"
  lost=1
fi
if (( size <= MOCK_PING_MAX && ! lost )); then
  printf '%d bytes from %s: icmp_seq=1 ttl=55 time=10.0 ms\n' \
    "$(( size + 8 ))" "$address"
  exit 0
fi
if (( lost )); then
  :
elif [[ "${MOCK_PING_HINT:-}" == 1 ]]; then
  printf 'ping: local error: message too long, mtu=%d\n' \
    "$(( MOCK_PING_MAX + 28 ))" >&2
elif [[ "${MOCK_PING_FRAG:-}" == 1 ]]; then
  printf 'From 192.0.2.1 icmp_seq=1 Frag needed and DF set (mtu = %d)\n' \
    "$(( MOCK_PING_MAX + 28 ))"
elif [[ "${MOCK_PING_EMSGSIZE:-}" == 1 ]]; then
  printf 'ping: sendto: Message too long\n' >&2
fi
printf '\n--- %s ping statistics ---\n' "$target"
printf '1 packets transmitted, 0 received, 100%% packet loss\n'
exit 1
EOF

  # ip: the route names MOCK_EGRESS; link MTUs come from MOCK_IFACE_MTUS.
  cat > "$TEST_MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
[[ "${MOCK_IP_FAIL:-}" == 1 ]] && exit 1
case "$*" in
  "-4 route get "*)
    printf '%s via 192.0.2.1 dev %s src 192.0.2.10 uid 1000\n    cache\n' \
      "$4" "$MOCK_EGRESS"
    ;;
  "-o link show dev "*)
    for pair in $MOCK_IFACE_MTUS; do
      if [[ "${pair%%=*}" == "$5" ]]; then
        printf '2: %s: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu %s qdisc mq state UP\n' \
          "$5" "${pair#*=}"
        exit 0
      fi
    done
    printf 'Device "%s" does not exist.\n' "$5" >&2
    exit 1
    ;;
  *) exit 1 ;;
esac
EOF

  # macOS collectors: route -n get and ifconfig, from the same controls.
  cat > "$TEST_MOCK_BIN/route" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-} ${2:-}" == '-n get' && -n "${3:-}" ]] || exit 64
printf '   route to: %s\ndestination: default\n  interface: %s\n' \
  "$3" "$MOCK_EGRESS"
EOF
  cat > "$TEST_MOCK_BIN/ifconfig" <<'EOF'
#!/usr/bin/env bash
for pair in $MOCK_IFACE_MTUS; do
  if [[ "${pair%%=*}" == "${1:-}" ]]; then
    printf '%s: flags=8863<UP,BROADCAST,RUNNING> mtu %s\n' "$1" "${pair#*=}"
    exit 0
  fi
done
exit 1
EOF

  # wg lists MOCK_WG_DEVICES without privileges, as the real tool does.
  cat > "$TEST_MOCK_BIN/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == 'show interfaces' ]]; then
  [[ -z "$MOCK_WG_DEVICES" ]] || printf '%s\n' "$MOCK_WG_DEVICES"
  exit 0
fi
exit 1
EOF
  chmod 755 "$TEST_MOCK_BIN/ping" "$TEST_MOCK_BIN/ip" "$TEST_MOCK_BIN/route" \
    "$TEST_MOCK_BIN/ifconfig" "$TEST_MOCK_BIN/wg"
}

teardown() {
  cleanup_sandbox
}

require_jq() {
  command -v jq >/dev/null || skip "jq is not installed"
}

# Zsh prelude for a plain Linux host and for a WSL2 host.
LINUX='_vpn_is_wsl() { return 1; };'
WSL2='_vpn_is_wsl() { return 0; }; _vpn_mtu_wsl_generation() { REPLY=wsl2; };'

# value LABEL: the value of one key-value line in $output.
value() {
  sed -n "s/^  $1: *//p" <<<"$output" | head -n 1
}

# DF probes sent, excluding the ping -V capability check.
probe_count() {
  grep -c -- ' -s ' "$MOCK_PING_LOG" || true
}

# --- Measurement ------------------------------------------------------------

@test "vpn mtu: bisection finds the 1392-byte path behind a 1500-byte eth0" {
  run run_zsh "$WSL2"' vpn-mtu-probe'

  [ "$status" -eq 0 ]
  [ "$(value 'Path MTU')" = 1392 ]
  [ "$(value 'Largest payload')" = '1364 bytes' ]
  [ "$(value 'Egress interface')" = eth0 ]
  [ "$(value 'Egress MTU')" = 1500 ]
  [ "$(value 'Through tunnel')" = no ]
  # The boundary was proven from both sides with Don't Fragment set.
  grep -Fxq -- '-4 -n -c 1 -W 1 -M do -s 1364 -- 1.1.1.1' "$MOCK_PING_LOG"
  grep -Fxq -- '-4 -n -c 1 -W 1 -M do -s 1365 -- 1.1.1.1' "$MOCK_PING_LOG"
  # Silent failures: the boundary failure was retried before it decided the
  # result, and everything fits the 16-probe cap.
  [ "$(grep -c -- '-s 1365 -- ' "$MOCK_PING_LOG")" -eq 2 ]
  (( $(probe_count) <= 16 ))
  [[ "$output" == *"⚠ Path MTU 1392 is below the eth0 MTU 1500; nothing was changed."* ]]
  # Read-only and unprivileged.
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn mtu: no profile, privileged probe, or sudo fallback is reached" {
  export MOCK_WG_DEVICES=wg0 MOCK_IFACE_MTUS="eth0=1500 wg0=1420"
  run run_zsh "$WSL2"'
    for helper in _vpn_conf_path _vpn_get_configs _vpn_dns_from_conf \
      _vpn_run_wg _vpn_sudo_probe _vpn_sudo_exec _vpn_have_sudo_cache \
      _vpn_ensure_sudo_access _vpn_active_interfaces _vpn_state_load; do
      functions[$helper]="print -u2 -r -- REACHED:$helper; return 97"
    done
    vpn-mtu-probe --profile wg0
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"REACHED:"* ]]
  [ "$(value 'WireGuard tunnel')" = 'wg0, MTU 1420' ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn mtu: other boundaries converge to the exact path MTU" {
  local payload expected
  for payload in 1252 1372 1420 1452 1471; do
    export MOCK_PING_MAX="$payload"
    : > "$MOCK_PING_LOG"
    run run_zsh "$LINUX"' vpn-mtu-probe'
    [ "$status" -eq 0 ]
    expected=$(( payload + 28 ))
    if [ "$(value 'Path MTU')" != "$expected" ]; then
      printf 'payload %s measured %s\n' "$payload" "$(value 'Path MTU')" >&2
      return 1
    fi
    (( $(probe_count) <= 16 ))
  done
}

@test "vpn mtu: a healthy path costs two probes and recommends nothing" {
  export MOCK_PING_MAX=1472
  run run_zsh "$WSL2"' vpn-mtu-probe'

  [ "$status" -eq 0 ]
  [ "$(value 'Path MTU')" = 1500 ]
  [ "$(probe_count)" -eq 2 ]
  [[ "$output" != *"Recommendations"* ]]
  [[ "$output" == *"✔ Path MTU 1500 fits the eth0 MTU; no interface change is needed."* ]]
}

@test "vpn mtu: a reported MTU is tried first and confirmed by one byte more" {
  export MOCK_PING_HINT=1
  run run_zsh "$LINUX"' vpn-mtu-probe'

  [ "$status" -eq 0 ]
  [ "$(value 'Path MTU')" = 1392 ]
  [ "$(probe_count)" -eq 4 ]
  sed -n 2,4p "$MOCK_PING_LOG" | grep -q -- '-s 1472 '
  sed -n 2,4p "$MOCK_PING_LOG" | grep -q -- '-s 1364 '
  sed -n 2,5p "$MOCK_PING_LOG" | grep -q -- '-s 1365 '
}

@test "vpn mtu: a host name is resolved once and later probes use the address" {
  export MOCK_PING_ADDRESS=192.0.2.44
  run run_zsh "$LINUX"' vpn-mtu-probe --target one.example.net'

  [ "$status" -eq 0 ]
  [ "$(value 'Target')" = one.example.net ]
  [ "$(value 'Address')" = 192.0.2.44 ]
  [ "$(value 'Path MTU')" = 1392 ]
  [ "$(grep -c -- '-- one.example.net$' "$MOCK_PING_LOG")" -eq 1 ]
  [ "$(grep -c -- '-- 192.0.2.44$' "$MOCK_PING_LOG")" -ge 2 ]
}

@test "vpn mtu: an unknown egress MTU caps the search and reports a lower bound" {
  export MOCK_IP_FAIL=1 MOCK_PING_MAX=1472
  run run_zsh "$LINUX"' vpn-mtu-probe'

  [ "$status" -eq 0 ]
  [ "$(value 'Path MTU')" = 'at least 1500' ]
  [ "$(value 'Egress interface')" = unknown ]
  [[ "$output" == *"larger packets were not tried because the egress MTU is unknown"* ]]
  [[ "$output" != *"Recommendations"* ]]
}

# --- Failures and capabilities ----------------------------------------------

@test "vpn mtu: an unreachable target fails after one retry" {
  export MOCK_PING_MAX=-1
  run run_zsh "$LINUX"' vpn-mtu-probe'

  [ "$status" -eq 1 ]
  [[ "$output" == *"✘ Path MTU not measured: no reply to a 56-byte ping."* ]]
  [[ "$output" == *"--target HOST or VPN_MENU_MTU_TARGET"* ]]
  [ "$(probe_count)" -eq 2 ]

  # One lost reply to the small ping is not an unreachable target.
  : > "$MOCK_PING_LOG"
  export MOCK_PING_MAX=1364 MOCK_PING_LOSE_ONCE=56
  run run_zsh "$LINUX"' vpn-mtu-probe'
  [ "$status" -eq 0 ]
  [ "$(value 'Path MTU')" = 1392 ]
}

@test "vpn mtu: a single lost reply at a passing size does not lower the result" {
  # Lost early: the failure would discard most of the range, so it is
  # retried at once.
  export MOCK_PING_LOSE_ONCE=764
  run run_zsh "$LINUX"' vpn-mtu-probe --json 2>/dev/null'
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '-s 764 -- ' "$MOCK_PING_LOG")" -eq 2 ]
  [[ "$output" == *'"path_mtu":1392,"exact":true'* ]]

  # Lost late: retried when it bounds the result, then the search resumes
  # above it. The retry costs probes, so the cap may turn the answer into a
  # lower bound, but never into a smaller exact value.
  local size
  for size in 1363 1364 1339; do
    rm -f "$MOCK_PING_LOG.lost"
    : > "$MOCK_PING_LOG"
    export MOCK_PING_LOSE_ONCE="$size"
    run run_zsh "$LINUX"' vpn-mtu-probe --json 2>/dev/null'
    [ "$status" -eq 0 ]
    if [[ "$output" != *'"path_mtu":1392,"exact":true'* \
      && "$output" != *'"exact":false'* ]]; then
      printf 'loss at %s: %s\n' "$size" "$output" >&2
      return 1
    fi
    [[ "$output" != *'"exact":true'* || "$output" == *'"path_mtu":1392,'* ]]
    (( $(probe_count) <= 16 ))
  done
}

@test "vpn mtu: explicit too-large evidence is final and never retried" {
  local mode
  for mode in MOCK_PING_EMSGSIZE MOCK_PING_FRAG; do
    : > "$MOCK_PING_LOG"
    export "$mode=1"
    run run_zsh "$LINUX"' vpn-mtu-probe'
    unset "$mode"
    [ "$status" -eq 0 ]
    [ "$(value 'Path MTU')" = 1392 ]
    # Every size was probed once: no failure was retried.
    [ -z "$(grep -- ' -s ' "$MOCK_PING_LOG" | sort | uniq -d)" ]
  done
}

@test "vpn mtu: a host name that does not resolve is named" {
  export MOCK_PING_UNKNOWN_HOST=1
  run run_zsh "$LINUX"' vpn-mtu-probe --target nohost.example'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Path MTU not measured: could not resolve nohost.example."* ]]
}

@test "vpn mtu: BusyBox ping is unsupported before any probe is sent" {
  export MOCK_PING_FLAVOR=busybox
  run run_zsh "$LINUX"' vpn-mtu-probe'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Path MTU not measured: ping cannot send don't-fragment probes"* ]]
  [[ "$output" == *"Install iputils ping"* ]]
  [ "$(probe_count)" -eq 0 ]
}

@test "vpn mtu: a ping that rejects the options or the socket is unsupported" {
  # An iputils-looking ping that still refuses -M do.
  cat > "$TEST_MOCK_BIN/ping" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -V ]] && { echo 'ping from iputils s20161105'; exit 0; }
printf "ping: invalid option -- '4'\nUsage: ping [-aAbBdDfhLnOqrRUvV] host\n" >&2
exit 2
EOF
  run run_zsh "$LINUX"' vpn-mtu-probe'
  [ "$status" -eq 1 ]
  [[ "$output" == *"ping rejected the don't-fragment options"* ]]

  rm -f "$TEST_MOCK_BIN/ping"
  cat > "$TEST_MOCK_BIN/ping" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -V ]] && { echo 'ping from iputils 20240117'; exit 0; }
echo 'ping: socket: Operation not permitted' >&2
exit 2
EOF
  chmod 755 "$TEST_MOCK_BIN/ping"
  run run_zsh "$LINUX"' vpn-mtu-probe'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not permitted to send ICMP from this account"* ]]
  [[ "$output" == *"never uses sudo"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn mtu: a missing ping is reported, and the menu row is marked" {
  run run_zsh "$LINUX"'
    _vpn_check_cmd() { [[ "$1" != ping ]] && command -v "$1" &>/dev/null; }
    vpn-mtu-probe
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Path MTU not measured: ping is not installed."* ]]

  run run_zsh '
    _vpn_menu_have() { [[ "$1" != ping ]]; }
    _vpn_state_load
    _vpn_menu_rows
  '
  [ "$status" -eq 0 ]
  grep -Fq '  ○ Probe Path MTU (missing: ping)|vpn-mtu-probe|' <<<"$output"
}

@test "vpn mtu: another kernel is not applicable, without a heading" {
  vpn_pin_kernel FreeBSD
  export VPN_CONFIG_DIR="$HOME/wireguard"
  run run_zsh 'vpn-mtu-probe'

  [ "$status" -eq 1 ]
  [[ "$output" == *"✘ vpn-mtu-probe is not applicable on this host: the probe supports Linux, WSL, and macOS."* ]]
  [[ "$output" != *"════"* ]]
  [ "$(probe_count)" -eq 0 ]
}

# --- Bounds -----------------------------------------------------------------

@test "vpn mtu: a hanging reachability ping ends at the probe deadline" {
  export MOCK_PING_HANG_ABOVE=0
  local started=$SECONDS
  run run_zsh "$LINUX"' _VPN_MTU_PROBE_SECONDS=1; vpn-mtu-probe'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Path MTU not measured: no reply within 1 second."* ]]
  (( SECONDS - started < 8 ))
}

@test "vpn mtu: the time budget stops a search that keeps hanging" {
  export MOCK_PING_HANG_ABOVE=1364
  local started=$SECONDS
  run run_zsh "$LINUX"'
    _VPN_MTU_PROBE_SECONDS=1
    _VPN_MTU_BUDGET_SECONDS=4
    vpn-mtu-probe
  '

  [ "$status" -eq 0 ]
  [[ "$(value 'Path MTU')" == "at least "* ]]
  [[ "$output" == *"probing stopped at its 4s limit after "*" probes."* ]]
  [[ "$output" == *"No change is recommended from a partial measurement."* ]]
  [[ "$output" != *"Recommendations"* ]]
  (( $(probe_count) < 16 ))
  (( SECONDS - started < 10 ))
}

@test "vpn mtu: a wall-clock jump never shrinks the accounted budget" {
  run run_zsh '
    typeset -A mtu=(spent 0)
    _VPN_MTU_PROBE_SECONDS=3
    # Backwards (as when WSL resynchronizes): the whole deadline and grace.
    _vpn_mtu_account $(( EPOCHREALTIME + 100 ))
    (( mtu[spent] == 5 )) || return 1
    # A plausible reading counts as measured.
    _vpn_mtu_account $(( EPOCHREALTIME - 0.5 ))
    (( mtu[spent] > 5.4 && mtu[spent] < 5.7 )) || return 2
    # Forwards beyond what the deadline allows: also capped.
    _vpn_mtu_account $(( EPOCHREALTIME - 100 ))
    (( mtu[spent] > 10.4 && mtu[spent] < 10.7 )) || return 3
  '
  [ "$status" -eq 0 ]
}

@test "vpn mtu: the probe count is capped" {
  run run_zsh "$LINUX"' _VPN_MTU_MAX_PROBES=4; vpn-mtu-probe'

  [ "$status" -eq 0 ]
  [ "$(probe_count)" -eq 4 ]
  [[ "$output" == *"probing stopped at its limit of 4 probes."* ]]
}

# --- Target and argument validation -----------------------------------------

@test "vpn mtu: hostile or ambiguous targets are refused before any probe" {
  local targets="$TEST_TEMP_DIR/targets"
  printf '%s\n' \
    '-c1' '--help' '-x.example' '1.1.1.1;id' '$(id)' '`id`' 'a b' 'host|x' \
    'host>x' '::1' 'fe80::1' '010.1.1.1' '1.2.3' '1.1.1.256' '0x7f000001' \
    'host..example' '.example' 'example.' 'example.123' 'ex_ample.com' \
    'xn--.example' "$(printf 'a%.0s' {1..64}).example" > "$targets"
  export TARGETS_FILE="$targets"

  run run_zsh '
    local hostile=""
    while IFS= read -r hostile; do
      vpn-mtu-probe --target "$hostile" >/dev/null 2>&1
      if (( $? != 2 )); then
        print -r -- "accepted: $hostile"
        return 1
      fi
    done < "$TARGETS_FILE"
    vpn-mtu-probe --target "" >/dev/null 2>&1
    (( $? == 2 )) || return 2
  '
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_PING_LOG" ]

  run run_zsh 'vpn-mtu-probe --target "1.1.1.1;id"'
  [ "$status" -eq 2 ]
  [[ "$output" == *"✘ Refusing the probe target: 1.1.1.1;id"* ]]
}

@test "vpn mtu: plain IPv4 literals and host names are accepted" {
  run run_zsh "$LINUX"'
    _vpn_mtu_validate_target 1.1.1.1 || return 1
    _vpn_mtu_validate_target 0.0.0.0 || return 2
    _vpn_mtu_validate_target 255.255.255.255 || return 3
    _vpn_mtu_validate_target one.one.one.one || return 4
    _vpn_mtu_validate_target localhost || return 5
    _vpn_mtu_validate_target 1password.com || return 6
    _vpn_mtu_validate_target a-b.example.co || return 7
  '
  [ "$status" -eq 0 ]
}

@test "vpn mtu: VPN_MENU_MTU_TARGET sets the default and is validated" {
  export VPN_MENU_MTU_TARGET=192.0.2.9
  run run_zsh "$LINUX"' vpn-mtu-probe'
  [ "$status" -eq 0 ]
  [ "$(value 'Target')" = 192.0.2.9 ]
  grep -q -- '-- 192.0.2.9$' "$MOCK_PING_LOG"

  : > "$MOCK_PING_LOG"
  export VPN_MENU_MTU_TARGET='-I eth0'
  run run_zsh "$LINUX"' vpn-mtu-probe'
  [ "$status" -eq 2 ]
  [[ "$output" == *"VPN_MENU_MTU_TARGET is not an IPv4 address or host name"* ]]
  [ ! -s "$MOCK_PING_LOG" ]

  # An explicit --target wins over the setting.
  run run_zsh "$LINUX"' vpn-mtu-probe --target 192.0.2.7'
  [ "$status" -eq 0 ]
  [ "$(value 'Target')" = 192.0.2.7 ]
}

@test "vpn mtu: invalid arguments return 2 before any probe" {
  local -a invocations=(
    '--target'
    '--profile'
    '--target 1.1.1.1 --target 8.8.8.8'
    '--profile wg0 --profile wg1'
    '--profile ../wg0'
    '--profile -wg0'
    '--yes'
    '--dry-run'
    '1.1.1.1'
    '-- 1.1.1.1'
  )
  local invocation
  for invocation in "${invocations[@]}"; do
    run run_zsh "vpn-mtu-probe $invocation"
    if [ "$status" -ne 2 ]; then
      printf 'accepted: %s (status %s)\n' "$invocation" "$status" >&2
      return 1
    fi
  done
  [ ! -s "$MOCK_PING_LOG" ]

  run run_zsh 'vpn-mtu-probe --help >"$HOME/help.out"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/help.out" ]
  [[ "$output" == *"Usage: vpn-mtu-probe [--target HOST] [--profile NAME] [--json]"* ]]
}

# --- Recommendations --------------------------------------------------------

@test "vpn mtu: WSL2 advice names the exact /etc/wsl.conf boot line" {
  run run_zsh "$WSL2"' vpn-mtu-probe'

  [ "$status" -eq 0 ]
  grep -Fxq '  Lower eth0 to the path MTU for this session:' <<<"$output"
  grep -Fxq '    sudo ip link set dev eth0 mtu 1392' <<<"$output"
  grep -Fxq '  Keep it across restarts with this line under [boot] in /etc/wsl.conf, then run wsl.exe --shutdown from Windows:' <<<"$output"
  grep -Fxq '    command = /usr/sbin/ip link set dev eth0 mtu 1392' <<<"$output"
  [[ "$output" != *"nmcli"* && "$output" != *"networksetup"* ]]
}

@test "vpn mtu: WSL1 advice points at the Windows adapter" {
  run run_zsh '
    _vpn_is_wsl() { return 0; }
    _vpn_mtu_wsl_generation() { REPLY=wsl1; }
    vpn-mtu-probe
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"WSL1 shares the Windows network stack: set MTU 1392 on the Windows adapter that carries this route instead."* ]]
  [[ "$output" != *"wsl.conf"* && "$output" != *"sudo ip link"* ]]
}

@test "vpn mtu: Linux advice is a session command plus persistent hints" {
  unset WSL_DISTRO_NAME
  run run_zsh "$LINUX"' vpn-mtu-probe'

  [ "$status" -eq 0 ]
  grep -Fxq '    sudo ip link set dev eth0 mtu 1392' <<<"$output"
  grep -Fxq '    nmcli connection modify <connection> ethernet.mtu 1392' <<<"$output"
  grep -Fxq '    MTUBytes=1392' <<<"$output"
  [[ "$output" != *"wsl.conf"* ]]
}

@test "vpn mtu: macOS maps the probe to BSD ping and networksetup" {
  vpn_pin_kernel Darwin
  export MOCK_PING_FLAVOR=darwin MOCK_EGRESS=en0 MOCK_IFACE_MTUS="en0=1500"
  run run_zsh 'vpn-mtu-probe'

  [ "$status" -eq 0 ]
  [ "$(value 'Path MTU')" = 1392 ]
  [ "$(value 'Egress interface')" = en0 ]
  grep -Fxq -- '-n -c 1 -t 1 -D -s 1364 -- 1.1.1.1' "$MOCK_PING_LOG"
  ! grep -Eq -- '-M|-W|-4|^-V' "$MOCK_PING_LOG" || false
  grep -Fxq '    sudo networksetup -setMTU en0 1392' <<<"$output"
  [[ "$output" != *"sudo ip link"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn mtu: a named profile gets the WireGuard MTU for the measured path" {
  run run_zsh "$WSL2"' vpn-mtu-probe --profile office'

  [ "$status" -eq 0 ]
  [ "$(value 'Profile')" = office ]
  grep -Fq 'of the office profile: path MTU 1392 less 80 bytes of WireGuard overhead, safe for IPv6 endpoints (IPv4-only endpoints need 60, allowing 1332):' <<<"$output"
  grep -Fxq '    MTU = 1312' <<<"$output"
}

@test "vpn mtu: an active split tunnel is sized only when its MTU is too large" {
  export MOCK_WG_DEVICES=wg0 MOCK_IFACE_MTUS="eth0=1500 wg0=1420"
  run run_zsh "$LINUX"' vpn-mtu-probe'
  [ "$status" -eq 0 ]
  [ "$(value 'Through tunnel')" = no ]
  [ "$(value 'WireGuard tunnel')" = 'wg0, MTU 1420' ]
  grep -Fq 'of the wg0 profile: path MTU 1392' <<<"$output"
  grep -Fxq '    MTU = 1312' <<<"$output"

  export MOCK_IFACE_MTUS="eth0=1500 wg0=1300"
  run run_zsh "$LINUX"' vpn-mtu-probe'
  [ "$status" -eq 0 ]
  [[ "$output" != *"MTU = "* ]]
}

@test "vpn mtu: a named active profile is the tunnel it reports and sizes" {
  export MOCK_WG_DEVICES="alpha wg0" MOCK_IFACE_MTUS="eth0=1500 alpha=1420 wg0=1300"
  run run_zsh "$LINUX"' vpn-mtu-probe --profile wg0'
  [ "$status" -eq 0 ]
  [ "$(value 'WireGuard tunnel')" = 'wg0, MTU 1300' ]
  # wg0 already fits the 1392-byte path, so only the host interface advice.
  [[ "$output" != *"MTU = "* ]]
  grep -Fxq '    sudo ip link set dev eth0 mtu 1392' <<<"$output"

  run run_zsh "$LINUX"' vpn-mtu-probe'
  [ "$status" -eq 0 ]
  [ "$(value 'WireGuard tunnel')" = 'alpha, MTU 1420' ]
  grep -Fq 'of the alpha profile: path MTU 1392' <<<"$output"
}

@test "vpn mtu: a full tunnel route measures the inner path and sizes the tunnel" {
  export MOCK_WG_DEVICES=wg0 MOCK_EGRESS=wg0 MOCK_IFACE_MTUS="eth0=1500 wg0=1420"
  export MOCK_PING_MAX=1352
  run run_zsh "$LINUX"' vpn-mtu-probe'

  [ "$status" -eq 0 ]
  [ "$(value 'Through tunnel')" = yes ]
  [ "$(value 'Path MTU')" = 1380 ]
  [[ "$output" == *"This route goes through wg0, so the probe measured the path inside the tunnel"* ]]
  grep -Fxq '    MTU = 1380' <<<"$output"
  [[ "$output" != *"sudo ip link"* ]]
  [[ "$output" == *"⚠ Path MTU 1380 inside wg0 is below its MTU 1420; nothing was changed."* ]]
}

# --- JSON -------------------------------------------------------------------

@test "vpn mtu: --json prints exactly one schema document on stdout" {
  require_jq
  run run_zsh "$WSL2"'
    vpn-menu vpn-mtu-probe --json >"$HOME/out.json" 2>"$HOME/err.txt"
  '
  [ "$status" -eq 0 ]

  jq -e -s 'length == 1 and (.[0] | type) == "object"' "$HOME/out.json"
  # One compact line, ending in a newline.
  [ "$(wc -l < "$HOME/out.json" | tr -d ' ')" = 1 ]
  [ "$(tail -c 1 "$HOME/out.json" | od -An -c | tr -d ' ')" = '\n' ]
  jq -e 'keys_unsorted[0] == "schema"' "$HOME/out.json"
  jq -e '
    .schema == "zdx.vpn-mtu-probe.v1"
    and .applicable == true and .supported == true and .reachable == true
    and .target == "1.1.1.1" and .address == "1.1.1.1"
    and .profile == null and .platform == "wsl"
    and .path_mtu == 1392 and .exact == true
    and .egress_interface == "eth0" and .egress_mtu == 1500
    and .through_tunnel == false
    and .tunnel_interface == null and .tunnel_mtu == null
    and (.probes | type) == "number" and .probes <= 16
    and (.duration_ms | type) == "number"
    and .reason == null
    and (.recommendations | index("Keep it across restarts with this line under [boot] in /etc/wsl.conf, then run wsl.exe --shutdown from Windows: command = /usr/sbin/ip link set dev eth0 mtu 1392")) != null
  ' "$HOME/out.json"
  # No UI, color, or heading on stdout; the timing line stays on stderr.
  ! grep -Eq $'\033|════|➜' "$HOME/out.json" || false
  grep -q 'vpn:vpn-mtu-probe completed' "$HOME/err.txt"
  [[ "$(cat "$HOME/err.txt")" != *"════"* ]]
}

@test "vpn mtu: --json failures keep the text status and explain themselves" {
  require_jq
  export MOCK_PING_MAX=-1
  run run_zsh "$LINUX"' vpn-mtu-probe --json >"$HOME/out.json" 2>"$HOME/err.txt"'
  [ "$status" -eq 1 ]
  jq -e '
    .reachable == false and .supported == true and .path_mtu == null
    and .exact == null and .recommendations == []
    and .reason == "no reply to a 56-byte ping"
  ' "$HOME/out.json"
  grep -q 'Path MTU not measured' "$HOME/err.txt"

  export MOCK_PING_MAX=1364 MOCK_PING_FLAVOR=busybox
  run run_zsh "$LINUX"' vpn-mtu-probe --json >"$HOME/out.json" 2>/dev/null'
  [ "$status" -eq 1 ]
  jq -e '.supported == false and .reachable == null and (.reason | type) == "string"' \
    "$HOME/out.json"

  vpn_pin_kernel FreeBSD
  run run_zsh 'vpn-mtu-probe --json >"$HOME/out.json" 2>/dev/null'
  [ "$status" -eq 1 ]
  jq -e '.applicable == false and (.reason | test("Linux, WSL, and macOS"))' \
    "$HOME/out.json"
}

@test "vpn mtu: --json without jq fails on stderr and prints nothing" {
  run run_zsh "$LINUX"'
    _vpn_check_cmd() { [[ "$1" != jq ]] && command -v "$1" &>/dev/null; }
    vpn-mtu-probe --json >"$HOME/out.json"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/out.json" ]
  [[ "$output" == *"jq is required for --json output."* ]]
  [ ! -s "$MOCK_PING_LOG" ]
}

@test "vpn mtu: --json reports the tunnel and the profile advice" {
  require_jq
  export MOCK_WG_DEVICES=wg0 MOCK_EGRESS=wg0 MOCK_IFACE_MTUS="eth0=1500 wg0=1420"
  export MOCK_PING_MAX=1352
  run run_zsh "$LINUX"' vpn-mtu-probe --profile wg0 --json 2>/dev/null'
  [ "$status" -eq 0 ]
  jq -e '
    .platform == "linux" and .profile == "wg0"
    and .through_tunnel == true and .tunnel_interface == "wg0"
    and .tunnel_mtu == 1420 and .path_mtu == 1380
    and (.recommendations | length) == 2
    and (.recommendations[1] | endswith(": MTU = 1380"))
  ' <<<"$output"
}
