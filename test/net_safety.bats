#!/usr/bin/env bats

setup() {
  load test_helper

  export NET_TEST_NETWORK_LOG="$TEST_TEMP_DIR/network-calls"
  : > "$NET_TEST_NETWORK_LOG"

  cat <<'EOF' > "$TEST_MOCK_BIN/timeout"
#!/usr/bin/env bash
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

  cat <<'EOF' > "$TEST_MOCK_BIN/ping"
#!/usr/bin/env bash
printf 'ping\n' >> "$NET_TEST_NETWORK_LOG"
printf '%s\n' \
  "1 packets transmitted, 1 received, 0% packet loss, time 10ms" \
  "rtt min/avg/max/mdev = 1.0/2.0/3.0/0.5 ms"
EOF
  chmod +x "$TEST_MOCK_BIN/ping"

  cat <<'EOF' > "$TEST_MOCK_BIN/curl"
#!/usr/bin/env bash
{
  printf 'curl'
  printf ' %q' "$@"
  printf '\n'
} >> "$NET_TEST_NETWORK_LOG"
url=""
while (($#)); do
  if [[ "$1" == "--url" && $# -ge 2 ]]; then
    url="$2"
    shift 2
    continue
  fi
  shift
done
case "$url" in
  *speed.cloudflare.com*)
    printf '%s\n' "zdx-net-size:10485760"
    ;;
  *icanhazip.com*) printf '%s\n' "203.0.113.10" ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/curl"

  cat <<'EOF' > "$TEST_MOCK_BIN/jq"
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/jq"
}

teardown() {
  cleanup_sandbox
}

@test "net safety: invalid grammar is rejected before any probe" {
  run run_zsh '
    net-menu --help >/dev/null
    : > "$NET_TEST_NETWORK_LOG"
    net-ping --count "1+1" example.com
    local ping_rc=$?
    net-dns "-bad.example"
    local dns_rc=$?
    net-public-ip --unknown
    local public_rc=$?
    [[ ! -s "$NET_TEST_NETWORK_LOG" ]]
    (( ping_rc == 2 && dns_rc == 2 && public_rc == 2 ))
  '
  [ "$status" -eq 0 ]
}

@test "net safety: target and provider validators reject injection syntax" {
  run run_zsh '
    net-menu --help >/dev/null
    ! _net_valid_target "-c"
    ! _net_valid_target $'\''example.com\nattacker'\''
    ! _net_valid_dns_name "bad..example"
    ! _net_safe_provider_url "http://example.com/ip"
    ! _net_safe_provider_url "https://user@example.com/ip"
    ! _net_safe_provider_url $'\''https://example.com/\e[31m'\''
    _net_safe_provider_url "https://api.ipify.org"
  '
  [ "$status" -eq 0 ]
}

@test "net safety: semantic IP validation accepts embedded IPv4 IPv6 literals" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_valid_ipv6 "::ffff:192.0.2.1"
    _net_valid_ipv6 "2001:db8::192.0.2.1"
    ! _net_valid_ipv6 "::ffff:192.0.2.999"
    ! _net_valid_ipv6 "2001:db8::192.0.2.1:80"
  '
  [ "$status" -eq 0 ]
}

@test "net safety: public-IP curl disables config and restricts redirects to HTTPS" {
  run run_zsh '
    net-menu --help >/dev/null
    : > "$NET_TEST_NETWORK_LOG"
    net-public-ip >/dev/null 2>&1
    grep -q -- "--disable" "$NET_TEST_NETWORK_LOG"
    grep -q -- "--proto =https" "$NET_TEST_NETWORK_LOG"
    grep -q -- "--proto-redir =https" "$NET_TEST_NETWORK_LOG"
    grep -q -- "--connect-timeout 2" "$NET_TEST_NETWORK_LOG"
    grep -q -- "--max-time 5" "$NET_TEST_NETWORK_LOG"
    ! grep -q -- "--header" "$NET_TEST_NETWORK_LOG"
  '
  [ "$status" -eq 0 ]
}

@test "net safety: malformed remote IP and terminal controls are never rendered" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_fetch_url() {
      REPLY=$'\''not-an-ip\e[31m'\''
      return 0
    }
    net-public-ip >"$HOME/stdout" 2>"$HOME/stderr"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/stdout" ]
  ! grep -q "31m" "$HOME/stderr"
  grep -q "No configured public-IP provider" "$HOME/stderr"
}

@test "net safety: cross-check revalidates the private provider identity" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_public_crosscheck_records() {
      print -r -- $'\''evil.example\t203.0.113.10'\''
    }
    net-public-ip --cross-check >"$HOME/stdout" 2>"$HOME/stderr"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/stdout" ]
  grep -q "invalid provider data" "$HOME/stderr"
}

@test "net safety: bounded probe output reports status 125" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_run_probe() {
      print -rn -- "01234567890123456789"
    }
    _net_capture_probe 10 1 ignored-command
  '
  [ "$status" -eq 125 ]
  [[ "$output" == *"exceeded its 10-byte output limit"* ]]
}

@test "net safety: ping timeout status is preserved" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_ping_probe_record() { return 124; }
    net-ping --count 1 example.com
  '
  [ "$status" -eq 124 ]
  [[ "$output" == *"timed out"* ]]
}

@test "net safety: DNS record count overflow returns status 125" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_capture_probe() {
      local -a records=()
      local -i record_index=0
      for record_index in {1..65}; do
        records+=("203.0.113.10")
      done
      REPLY="${(F)records}"
    }
    _net_dns_query_type dig A example.com
  '
  [ "$status" -eq 125 ]
}

@test "net safety: speedtest dry-run and missing authorization transfer nothing" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_speedtest_backend() { print -r -- "curl"; }
    : > "$NET_TEST_NETWORK_LOG"
    net-speedtest --dry-run
    local dry_rc=$?
    [[ ! -s "$NET_TEST_NETWORK_LOG" ]] || return 1
    net-speedtest
    local auth_rc=$?
    [[ ! -s "$NET_TEST_NETWORK_LOG" ]] || return 1
    (( dry_rc == 0 && auth_rc == 2 ))
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"pass --yes"* ]]
}

@test "net safety: speedtest dry-run still requires a usable bounded backend" {
  local cli_only_bin="$TEST_TEMP_DIR/cli-only-bin"
  mkdir -p "$cli_only_bin"
  cat > "$cli_only_bin/speedtest-cli" <<'EOF'
#!/usr/bin/env bash
exit 97
EOF
  chmod +x "$cli_only_bin/speedtest-cli"
  export NET_CLI_ONLY_BIN="$cli_only_bin"

  run run_zsh '
    PATH="$NET_CLI_ONLY_BIN"
    net-menu --help >/dev/null
    net-speedtest --dry-run
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"without timeout or gtimeout"* ]]
}

@test "net safety: unusable speedtest CLI falls back to bounded curl" {
  run run_zsh '
    net-menu --help >/dev/null
    speedtest-cli() { return 97; }
    _net_have_timeout() { return 1; }
    [[ "$(_net_speedtest_backend)" == "curl" ]]
  '
  [ "$status" -eq 0 ]
}

@test "net safety: local-only dashboard invokes no remote helper" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_ping_probe_record() { print ping >> "$NET_TEST_NETWORK_LOG"; return 97; }
    _net_public_info_record() { print public >> "$NET_TEST_NETWORK_LOG"; return 97; }
    _net_resolve_one() { print dns >> "$NET_TEST_NETWORK_LOG"; return 97; }
    _net_primary_route_record() {
      print -r -- $'\''eth0\t192.0.2.1'\''
    }
    _net_interface_inventory() {
      print -r -- $'\''eth0\tUP\t1500\t00:11:22:33:44:55\t192.0.2.10/24\t-\t1\t2'\''
    }
    : > "$NET_TEST_NETWORK_LOG"
    net-dashboard --local-only
    [[ ! -s "$NET_TEST_NETWORK_LOG" ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote ICMP, DNS, and public-IP probes are disabled"* ]]
}

@test "net safety: menu cancellation succeeds and removes private capture" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    net-menu
    local menu_rc=$?
    (( menu_rc == 0 )) || return 1
    local -a leftovers=("$TMPDIR"/zdx-net-fzf.*(N))
    (( ${#leftovers[@]} == 0 ))
  '
  [ "$status" -eq 0 ]
}

@test "net safety: forged mktemp directory is not chmodded or removed" {
  export NET_FORGED_MKTEMP_RESULT="$HOME/tmp/not-a-net-capture"
  mkdir -p "$NET_FORGED_MKTEMP_RESULT"
  chmod 700 "$NET_FORGED_MKTEMP_RESULT"
  : > "$NET_FORGED_MKTEMP_RESULT/keep"

  cat > "$TEST_MOCK_BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$NET_FORGED_MKTEMP_RESULT"
EOF
  chmod +x "$TEST_MOCK_BIN/mktemp"

  run run_zsh '
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    net-menu
    local menu_rc=$?
    local -A forged_state=()
    zmodload zsh/stat || return 97
    zstat -LH forged_state -- "$NET_FORGED_MKTEMP_RESULT" || return 98
    [[ -f "$NET_FORGED_MKTEMP_RESULT/keep" ]] || return 99
    (( (forged_state[mode] & 8#77) == 0 )) || return 96
    return $menu_rc
  '
  [ "$status" -eq 125 ]
}

@test "net safety: fzf remains in the terminal foreground process group" {
  export NET_PTY_PGID_FILE="$TEST_TEMP_DIR/net-pty-pgid"
  export NET_PTY_RC_FILE="$TEST_TEMP_DIR/net-pty-rc"
  export NET_PTY_CHILD="$TEST_TEMP_DIR/net-pty-child.zsh"

  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
set -u

cat >/dev/null
current_pgid=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
terminal_pgid=$(ps -o tpgid= -p "$$" | tr -d '[:space:]')
printf '%s|%s\n' "$current_pgid" "$terminal_pgid" > "$NET_PTY_PGID_FILE"
[[ -n "$current_pgid" && "$current_pgid" == "$terminal_pgid" ]] || exit 97
exit 130
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"

  cat > "$NET_PTY_CHILD" <<'EOF'
setopt MONITOR
source "$ZSH_CUSTOM/functions/net-menu.zsh" || exit 91
net-menu
menu_rc=$?
print -r -- "$menu_rc" > "$NET_PTY_RC_FILE"
exit "$menu_rc"
EOF
  chmod +x "$NET_PTY_CHILD"

  run run_zsh '
    _net_pty_foreground_check() {
      zmodload zsh/zpty || return 80
      zpty -b net-foreground zsh -dfi "$NET_PTY_CHILD" || return 81
      {
        local -i attempt=0
        local chunk=""
        while [[ ! -s "$NET_PTY_RC_FILE" ]] && (( ++attempt <= 200 )); do
          zpty -r -t net-foreground chunk 2>/dev/null || true
          command sleep 0.01
        done

        [[ -s "$NET_PTY_RC_FILE" ]] || return 82
        [[ -s "$NET_PTY_PGID_FILE" ]] || return 83
        local process_groups
        process_groups=$(<"$NET_PTY_PGID_FILE")
        local current_pgid="${process_groups%%|*}"
        local terminal_pgid="${process_groups##*|}"
        [[ -n "$current_pgid" && "$current_pgid" == "$terminal_pgid" ]] \
          || return 84
        [[ "$(<"$NET_PTY_RC_FILE")" == "0" ]] || return 85
      } always {
        zpty -d net-foreground 2>/dev/null || true
      }
    }

    _net_pty_foreground_check
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"suspended (tty output)"* ]]
}

@test "net safety: unsafe picker capture status 125 is preserved" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_fzf_capture() {
      REPLY=""
      return 125
    }
    net-menu
  '
  [ "$status" -eq 125 ]
  [[ "$output" == *"status 125"* ]]
}

@test "net safety: cancellation with forged multiline output fails closed" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_fzf_capture() {
      REPLY=$'\''forged-one\nforged-two'\''
      return 130
    }
    net-menu
  '
  [ "$status" -eq 125 ]
  [[ "$output" == *"cancelled Network menu returned unexpected data"* ]]
}

@test "net safety: menu refuses a forged record outside its snapshot" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="Injected|net-speedtest|forged"

  run run_zsh 'net-menu'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the menu snapshot"* ]]
}

@test "net safety: one selected action dispatches once and returns" {
  export MOCK_FZF_MODE="match"
  export MOCK_FZF_MATCH="net-dashboard"

  run run_zsh '
    net-menu --help >/dev/null 2>&1
    net-dashboard() { print -r -- called >> "$HOME/dispatch-log"; }
    net-menu
    [[ "$(<"$HOME/dispatch-log")" == "called" ]]
  '
  [ "$status" -eq 0 ]
}

@test "net safety: route fallback cannot reuse stale fields from ip output" {
  run run_zsh '
    net-menu --help >/dev/null
    ip() { return 0; }
    route() { return 0; }
    _net_capture_probe() {
      shift 2
      case "${(j: :)@}" in
        "ip route show default")
          REPLY="default via invalid-gateway dev stale0"
          ;;
        "route -n get default")
          REPLY="gateway: 192.0.2.1"
          ;;
        *)
          return 97
          ;;
      esac
    }
    ! _net_primary_route_record
  '
  [ "$status" -eq 0 ]
}

@test "net safety: failed exact-root load leaves no false menu sentinel" {
  local isolated="$TEST_TEMP_DIR/isolated"
  mkdir -p "$isolated/net"
  cp "$TEST_SUITE_ROOT/functions/net-menu.zsh" "$isolated/"
  cp "$TEST_SUITE_ROOT/functions/net-common.zsh" "$isolated/"
  cp "$TEST_SUITE_ROOT/functions/net/"*.zsh "$isolated/net/"
  rm "$isolated/net/net-throughput.zsh"

  run env ISOLATED_NET_ROOT="$isolated" zsh -f -c '
    source "$ISOLATED_NET_ROOT/net-menu.zsh"
    source_rc=$?
    (( source_rc != 0 )) || exit 1
    [[ -z "${_NET_MENU_SOURCED:-}" ]] || exit 1
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"net/net-throughput.zsh"* ]]
}
