#!/usr/bin/env bats
# Single-quoted scripts execute in Zsh; exports are isolated by BATS.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  for client in curl dig host ping getent; do
    printf '#!/bin/sh\nexit 97\n' > "$TEST_MOCK_BIN/$client"
    chmod +x "$TEST_MOCK_BIN/$client"
  done
}

teardown() {
  cleanup_sandbox
}

@test "net recovery: empty MX does not discard successful address queries" {
  run run_zsh '
    net-menu --help >/dev/null 2>&1
    _net_capture_probe() {
      case "$*" in
        "131072 8 dig +time=2 +tries=1 +short A example.test") REPLY=192.0.2.42 ;;
        "131072 8 dig +time=2 +tries=1 +short AAAA example.test") REPLY=2001:db8::42 ;;
        "131072 8 dig +time=2 +tries=1 +short MX example.test") REPLY="" ;;
        *) return 97 ;;
      esac
      return 0
    }
    net-dns example.test >"$HOME/out" 2>"$HOME/err" || return
    [[ ! -s "$HOME/out" ]] || return 1
    grep -q "192.0.2.42" "$HOME/err" || return 1
    grep -q "MX Records.*(none)" "$HOME/err"
  '
  [ "$status" -eq 0 ]
}

@test "net recovery: ping interruption with a valid summary never becomes success" {
  for code in 130 143; do
    export NET_RECOVERY_RC="$code"
    run run_zsh '
      net-menu --help >/dev/null 2>&1
      _net_capture_probe() {
        REPLY=$'\''5 packets transmitted, 5 received, 0% packet loss\nrtt min/avg/max/mdev = 1/2/3/0.1 ms'\''
        return "$NET_RECOVERY_RC"
      }
      net-ping --count 5 192.0.2.42
    '
    [ "$status" -eq "$code" ]
    [[ "$output" != *"Ping probe completed"* ]]
  done
}

@test "net recovery: ordinary ping failure keeps its packet summary and failure status" {
  run run_zsh '
    net-menu --help >/dev/null 2>&1
    _net_capture_probe() {
      REPLY=$'\''5 packets transmitted, 0 received, 100% packet loss'\''
      return 1
    }
    net-ping --count 5 192.0.2.42
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Packet Loss"*"100%"* ]]
  [[ "$output" != *"Ping probe completed"* ]]
}

@test "net recovery: public IP interruption prevents every provider fallback" {
  for code in 130 143; do
    export NET_RECOVERY_RC="$code"
    for mode in normal cross; do
      export NET_RECOVERY_MODE="$mode"
      run run_zsh '
        net-menu --help >/dev/null 2>&1
        _net_fetch_url() {
          print -r -- "$1" >> "$HOME/calls"
          return "$NET_RECOVERY_RC"
        }
        : > "$HOME/calls"
        local -a args=()
        [[ "$NET_RECOVERY_MODE" == cross ]] && args=(--cross-check)
        net-public-ip "${args[@]}"
        local result=$?
        [[ $(wc -l < "$HOME/calls") == 1 ]] || return 97
        return $result
      '
      [ "$status" -eq "$code" ]
    done
  done
}

@test "net recovery: dashboard interruption prevents remaining sections" {
  for code in 130 143; do
    export NET_RECOVERY_RC="$code"
    run run_zsh '
      net-menu --help >/dev/null 2>&1
      _net_ping_probe_record() { return "$NET_RECOVERY_RC"; }
      _net_public_info_record() { print -r called > "$HOME/later"; return 97; }
      _net_resolve_one() { print -r called > "$HOME/later"; return 97; }
      _net_primary_route_record() { print -r called > "$HOME/later"; return 97; }
      _net_interface_inventory() { print -r called > "$HOME/later"; return 97; }
      net-dashboard
    '
    [ "$status" -eq "$code" ]
    [ ! -e "$HOME/later" ]
    [[ "$output" != *"snapshot complete"* ]]
  done
}

@test "net recovery: interrupted resolver does not fall through to DNS clients" {
  for code in 130 143; do
    export NET_RECOVERY_RC="$code"
    run run_zsh '
      net-menu --help >/dev/null 2>&1
      _net_capture_probe() {
        [[ "$*" == "65536 8 getent ahosts example.test" ]] || return 97
        return "$NET_RECOVERY_RC"
      }
      _net_dns_query_type() { print -r called > "$HOME/later"; return 97; }
      _net_resolve_one example.test
    '
    [ "$status" -eq "$code" ]
    [ ! -e "$HOME/later" ]
  done
}

@test "net recovery: throughput interruption is preserved for curl and CLI" {
  for code in 130 143; do
    export NET_RECOVERY_RC="$code"
    cat <<'EOF' > "$TEST_MOCK_BIN/curl"
#!/bin/sh
printf 'zdx-net-size:10485760\n'
exit "$NET_RECOVERY_RC"
EOF
    for backend in curl speedtest-cli; do
      export NET_RECOVERY_BACKEND="$backend"
      run run_zsh '
        net-menu --help >/dev/null 2>&1
        _net_speedtest_backend() { print -r -- "$NET_RECOVERY_BACKEND"; }
        _net_capture_probe() { REPLY=""; return "$NET_RECOVERY_RC"; }
        net-speedtest --yes
      '
      [ "$status" -eq "$code" ]
      [[ "$output" != *"Throughput test completed"* ]]
    done
  done
}

@test "net recovery: unavailable clock never invents a throughput estimate" {
  cat <<'EOF' > "$TEST_MOCK_BIN/curl"
#!/bin/sh
printf 'zdx-net-size:10485760\n'
EOF
  run run_zsh '
    net-menu --help >/dev/null 2>&1
    _net_now_ms() { return 1; }
    _net_speedtest_backend() { print -r -- curl; }
    net-speedtest --yes
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"elapsed time and rate are unavailable"* ]]
  [[ "$output" != *"Mbps"* ]]
}

@test "net recovery: interrupted oversized capture still stops the diagnostic chain" {
  for code in 130 143; do
    export NET_RECOVERY_RC="$code"
    run run_zsh '
      net-menu --help >/dev/null 2>&1
      export TMPDIR="$HOME/tmp"
      mkdir -m 700 -p "$TMPDIR"
      _net_run_probe() {
        print -r -- 12345678901234
        return "$NET_RECOVERY_RC"
      }
      _net_capture_probe 10 1 ignored-command
      local result=$?
      [[ -z "$REPLY" ]] || return 97
      local -a leftovers=("$TMPDIR"/zdx-net-probe.*(N))
      (( ${#leftovers} == 0 )) || return 97
      return $result
    '
    [ "$status" -eq "$code" ]
  done
}
