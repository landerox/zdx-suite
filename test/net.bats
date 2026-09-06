#!/usr/bin/env bats

setup() {
  load test_helper

  export NET_TEST_NETWORK_LOG="$TEST_TEMP_DIR/network-calls"
  : > "$NET_TEST_NETWORK_LOG"

  cat <<'EOF' > "$TEST_MOCK_BIN/timeout"
#!/usr/bin/env bash
printf 'timeout %q\n' "$*" >> "$NET_TEST_NETWORK_LOG"
while (($#)); do
  case "$1" in
    -k) shift 2 ;;
    *s) shift ;;
    *) break ;;
  esac
done
exec "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/timeout"

  cat <<'EOF' > "$TEST_MOCK_BIN/curl"
#!/usr/bin/env bash
url=""
while (($#)); do
  if [[ "$1" == "--url" && $# -ge 2 ]]; then
    url="$2"
    shift 2
    continue
  fi
  shift
done
printf 'curl %s\n' "$url" >> "$NET_TEST_NETWORK_LOG"
case "$url" in
  *speed.cloudflare.com*)
    printf '%s\n' "zdx-net-size:10485760"
    ;;
  *ipapi.co*)
    printf '%s\n' \
      '{"ip":"8.8.8.8","city":"Mountain View","region":"California","country_name":"United States","org":"Google LLC"}'
    ;;
  *ipinfo.io*)
    printf '%s\n' \
      '{"ip":"8.8.4.4","city":"Mountain View","region":"California","country":"US","org":"Google LLC"}'
    ;;
  *freeipapi.com*)
    printf '%s\n' \
      '{"ipAddress":"1.1.1.1","cityName":"Sydney","regionName":"NSW","countryName":"Australia","asnOrganisation":"Cloudflare"}'
    ;;
  *icanhazip.com*) printf '%s\n' "8.8.8.8" ;;
  *ifconfig.me*) printf '%s\n' "8.8.4.4" ;;
  *api.ipify.org*) printf '%s\n' "1.1.1.1" ;;
  *cdn-cgi/trace*)
    printf '%s\n' "ip=1.0.0.1" "loc=US" "colo=IAD"
    ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/curl"

  cat <<'EOF' > "$TEST_MOCK_BIN/jq"
#!/usr/bin/env python3
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

values = [
    data.get("ip", data.get("ipAddress", "")),
    data.get("city", data.get("cityName", "")),
    data.get("region", data.get("region_name", data.get("regionName", ""))),
    data.get("country_name", data.get("country", "")),
    data.get("org", data.get("asn_org", data.get("asnOrganisation", ""))),
]
if not all(isinstance(value, str) for value in values):
    raise SystemExit(1)
print("\t".join(values))
EOF
  chmod +x "$TEST_MOCK_BIN/jq"

  cat <<'EOF' > "$TEST_MOCK_BIN/ping"
#!/usr/bin/env bash
count="5"
while (($#)); do
  if [[ "$1" == "-c" && $# -ge 2 ]]; then
    count="$2"
    shift 2
    continue
  fi
  shift
done
printf 'ping %s\n' "$count" >> "$NET_TEST_NETWORK_LOG"
printf '%s\n' \
  "$count packets transmitted, $count received, 0% packet loss, time 10ms" \
  "rtt min/avg/max/mdev = 10.230/12.243/14.120/1.590 ms"
EOF
  chmod +x "$TEST_MOCK_BIN/ping"

  cat <<'EOF' > "$TEST_MOCK_BIN/dig"
#!/usr/bin/env bash
printf 'dig %q\n' "$*" >> "$NET_TEST_NETWORK_LOG"
case " $* " in
  *" A "*) printf '%s\n' "93.184.216.34" ;;
  *" AAAA "*) printf '%s\n' "2606:2800:220:1:248:1893:25c8:1946" ;;
  *" MX "*) printf '%s\n' "10 mail.example.com." ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/dig"

  cat <<'EOF' > "$TEST_MOCK_BIN/ip"
#!/usr/bin/env bash
case "$*" in
  "-o -4 addr show")
    printf '%s\n' \
      "1: lo inet 127.0.0.1/8 scope host lo" \
      "2: eth0 inet 192.0.2.10/24 scope global eth0"
    ;;
  "-o -6 addr show")
    printf '%s\n' \
      "1: lo inet6 ::1/128 scope host" \
      "2: eth0 inet6 2001:db8::10/64 scope global"
    ;;
  "route show default")
    printf '%s\n' "default via 192.0.2.1 dev eth0"
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/ip"
}

teardown() {
  cleanup_sandbox
}

@test "net: exact loader exposes every module and public command" {
  run run_zsh '
    net-menu --help
    print -r -- \
      "${_NET_MENU_SOURCED}:${_NET_COMMON_SOURCED}:${_NET_PUBLIC_SOURCED}:${_NET_DIAGNOSTICS_SOURCED}:${_NET_INTERFACES_SOURCED}:${_NET_THROUGHPUT_SOURCED}:${_NET_DASHBOARD_SOURCED}"
    local command_name=""
    for command_name in net-dashboard net-public-ip net-interfaces \
      net-ping net-dns net-speedtest; do
      typeset -f "$command_name" >/dev/null || return 1
    done
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"1:1:1:1:1:1:1"* ]]
}

@test "net: top-level help is stderr-only and discloses network effects" {
  run run_zsh '
    net-menu --help >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "net-speedtest" "$HOME/stderr"
    grep -q "requires --yes" "$HOME/stderr"
    grep -q "timeout or gtimeout" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "net: dashboard renders independent validated sections on stderr" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_ping_probe_record() {
      print -r -- $'\''1\t1\t0\t10.0\t12.0\t14.0\t1.0'\''
    }
    _net_public_info_record() {
      print -r -- $'\''8.8.8.8\tMountain View\tCalifornia\tUS\tGoogle LLC\tipapi.co'\''
    }
    _net_resolve_one() { print -r -- "104.16.132.229"; }
    _net_primary_route_record() {
      print -r -- $'\''eth0\t192.0.2.1'\''
    }
    _net_interface_inventory() {
      print -r -- $'\''eth0\tUP\t1500\t00:11:22:33:44:55\t192.0.2.10/24\t-\t1000\t2000'\''
    }
    NO_COLOR=1 net-dashboard >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "Internet Route: reachable" "$HOME/stderr"
    grep -q "8.8.8.8" "$HOME/stderr"
    grep -q "104.16.132.229" "$HOME/stderr"
    grep -q "192.0.2.1" "$HOME/stderr"
    grep -q "eth0" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "net: public IP cross-check contacts each fixed provider at most once" {
  run run_zsh '
    net-menu --help >/dev/null
    : > "$NET_TEST_NETWORK_LOG"
    NO_COLOR=1 net-public-ip --cross-check \
      >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "8.8.8.8" "$HOME/stderr"
    grep -q "ipapi.co" "$HOME/stderr"
    grep -q "icanhazip.com" "$HOME/stderr"
    (( $(grep -c "^curl " "$NET_TEST_NETWORK_LOG") == 7 ))
    (( $(grep "^curl " "$NET_TEST_NETWORK_LOG" | sort -u | wc -l) == 7 ))
    grep -q "^timeout .*jq" "$NET_TEST_NETWORK_LOG"
  '
  [ "$status" -eq 0 ]
}

@test "net: ping validates and renders a bounded summary" {
  run run_zsh '
    net-menu --help >/dev/null
    NO_COLOR=1 net-ping --count 3 1.1.1.1 \
      >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "3 packets" "$HOME/stderr"
    grep -q "12.243 ms" "$HOME/stderr"
    grep -q "0%" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "net: DNS renders only validated bounded records" {
  run run_zsh '
    net-menu --help >/dev/null
    NO_COLOR=1 net-dns example.com \
      >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "93.184.216.34" "$HOME/stderr"
    grep -q "2606:2800" "$HOME/stderr"
    grep -q "mail.example.com" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "net: interface renderer consumes one bounded typed inventory" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_interface_inventory() {
      print -r -- $'\''eth0\tUP\t1500\t00:11:22:33:44:55\t192.0.2.10/24\t2001:db8::10/64\t512000\t1024000'\''
    }
    NO_COLOR=1 net-interfaces >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "eth0" "$HOME/stderr"
    grep -q "00:11:22:33:44:55" "$HOME/stderr"
    grep -q "500.00 KiB" "$HOME/stderr"
    grep -q "1000.00 KiB" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "net: speedtest dry-run transfers nothing and yes runs fixed HTTPS fallback" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_speedtest_backend() { print -r -- "curl"; }
    : > "$NET_TEST_NETWORK_LOG"
    NO_COLOR=1 net-speedtest --dry-run
    [[ ! -s "$NET_TEST_NETWORK_LOG" ]]
    NO_COLOR=1 net-speedtest --yes
    grep -q "speed.cloudflare.com" "$NET_TEST_NETWORK_LOG"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run complete"* ]]
  [[ "$output" == *"Throughput test completed"* ]]
}
