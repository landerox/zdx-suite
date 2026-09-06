#!/usr/bin/env bats

setup() {
  load test_helper

  export VPN_CONFIG_DIR="$HOME/wireguard"
  export VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"

  mkdir -p "$VPN_CONFIG_DIR"
  chmod 700 "$VPN_CONFIG_DIR"
}

teardown() {
  cleanup_sandbox
}

write_regression_profile() {
  local target="$1"
  local address="${2:-10.0.0.2/24}"
  local dns="${3:-1.1.1.1}"
  local allowed="${4:-0.0.0.0/0}"

  {
    printf '[Interface]\n'
    printf 'PrivateKey = TEST-PRIVATE-KEY=\n'
    printf 'Address = %s\n' "$address"
    printf 'DNS = %s\n' "$dns"
    printf '\n[Peer]\n'
    printf 'PublicKey = TEST-PEER-KEY=\n'
    printf 'AllowedIPs = %s\n' "$allowed"
    printf 'Endpoint = 203.0.113.10:51820\n'
  } > "$target"
  chmod 600 "$target"
}

@test "vpn regressions: default HTTPS providers pass strict URL validation" {
  run run_zsh '
    local url
    for url in \
      https://ipinfo.io/json \
      https://ifconfig.co/json \
      https://1.1.1.1/cdn-cgi/trace \
      https://example.com:443/status \
      https://\["2606:4700:4700::1111"\]/cdn-cgi/trace; do
      _vpn_validate_provider_url "$url" || return 10
    done

    for url in \
      http://example.com \
      file:///etc/passwd \
      https://user@example.com \
      https://example..com \
      https://example.com:99999; do
      _vpn_validate_provider_url "$url" && return 20
    done

    _vpn_load_provider_urls _vpn_ipinfo_json_providers || return 30
    (( ${#reply[@]} == 3 ))
  '

  [ "$status" -eq 0 ]
}

@test "vpn regressions: curl receives bounded HTTPS-only arguments before the URL" {
  export VPN_CURL_ARGS_LOG="$HOME/curl.args"
  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$VPN_CURL_ARGS_LOG"
printf '%s\n' '{"ip":"203.0.113.7"}'
EOF
  chmod +x "$TEST_MOCK_BIN/curl"

  run run_zsh '
    local response
    response=$(_vpn_curl_bounded "https://example.com/status" 4 2) || return 1
    [[ "$response" == *"203.0.113.7"* ]] || return 2

    local args
    args=$(<"$VPN_CURL_ARGS_LOG")
    [[ "$args" == *$'"'"'--proto\n=https\n'"'"'* ]] || return 3
    [[ "$args" == *$'"'"'--proto-redir\n=https\n'"'"'* ]] || return 4
    [[ "$args" == *$'"'"'--max-filesize\n262144\n'"'"'* ]] || return 5
    [[ "$args" == *$'"'"'\n--\nhttps://example.com/status'"'"'* ]] || return 6
  '

  [ "$status" -eq 0 ]
}

@test "vpn regressions: custom trace providers preserve type and hide query data" {
  run run_zsh '
    _vpn_ipinfo_json_providers() { return 1; }
    _vpn_ipinfo_plain_providers() { return 1; }
    _vpn_ipinfo_trace_providers() {
      print -r -- "https://trace.example?token=DO-NOT-DISPLAY"
    }
    _vpn_curl_bounded() {
      [[ "$1" == "https://trace.example?token=DO-NOT-DISPLAY" ]] || return 1
      print -rl -- \
        "fl=29f10" \
        "ip=203.0.113.77" \
        "loc=VE" \
        "colo=MIA"
    }

    local result
    result=$(_vpn_get_ip_crosscheck) || return 1
    [[ "$result" == $'"'"'trace.example\t203.0.113.77'"'"' ]] || return 2
    [[ "$result" != *"token"* && "$result" != *"DO-NOT-DISPLAY"* ]] \
      || return 3
  '

  [ "$status" -eq 0 ]
}

@test "vpn regressions: an incomplete WSL sentinel is never trusted as idempotent" {
  run run_zsh '
    local valid
    valid=$(_vpn_wsl_hook_lines 10.0.0.53 1.1.1.1 9.9.9.9)
    _vpn_wsl_existing_hook_state "$valid" || return 10
    [[ "$REPLY" == "10.0.0.53" ]] || return 11

    _vpn_wsl_existing_hook_state \
      "$_VPN_DNS_HOOK_SENTINEL"$'"'"'\n'"'"'"PostUp = incomplete"
    (( $? == 2 )) || return 20

    _vpn_wsl_existing_hook_state \
      "# user text containing $_VPN_DNS_HOOK_SENTINEL only"
    (( $? == 2 )) || return 21
    return 0
  '

  [ "$status" -eq 0 ]
}

@test "vpn regressions: each WSL fallback must be one IP before any sudo probe" {
  write_regression_profile "$VPN_CONFIG_DIR/wg0.conf"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    VPN_DNS_FALLBACK_PRIMARY="1.1.1.1, 9.9.9.9"
    _vpn_apply_wsl_dns_hooks "$VPN_CONFIG_DIR/wg0.conf"
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"one plain IP address"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
  ! grep -q 'zdx: wsl-dns-hooks' "$VPN_CONFIG_DIR/wg0.conf"
}

@test "vpn regressions: WSL IPv6 stripping is validated, atomic, and backed up" {
  write_regression_profile \
    "$VPN_CONFIG_DIR/wg0.conf" \
    "10.0.0.2/24, fd00::2/128" \
    "1.1.1.1, 2606:4700:4700::1111" \
    "0.0.0.0/0, ::/0"
  cp "$VPN_CONFIG_DIR/wg0.conf" "$HOME/original.conf"
  chmod 600 "$HOME/original.conf"
  export MOCK_SUDO_ALLOW="true,install,mktemp,ln,rm,mv"

  run run_zsh '
    _vpn_fix_ipv6_config wg0 || return 1
    command cmp -s \
      "$HOME/original.conf" \
      "$VPN_CONFIG_DIR/wg0.conf${VPN_BACKUP_SUFFIX}" || return 2
    command grep -q "Address = 10.0.0.2/24" \
      "$VPN_CONFIG_DIR/wg0.conf" || return 3
    command grep -q "DNS = 1.1.1.1" "$VPN_CONFIG_DIR/wg0.conf" || return 4
    command grep -q "AllowedIPs = 0.0.0.0/0" \
      "$VPN_CONFIG_DIR/wg0.conf" || return 5
    command grep -Eq \
      "^(Address|DNS|AllowedIPs)[[:space:]]*=.*:" \
      "$VPN_CONFIG_DIR/wg0.conf" && return 6
    return 0
  '

  [ "$status" -eq 0 ]
}

@test "vpn regressions: IPv6-only WSL profiles fail before mutation or sudo" {
  write_regression_profile \
    "$VPN_CONFIG_DIR/wg0.conf" "fd00::2/128" \
    "2606:4700:4700::1111" "::/0"
  cp "$VPN_CONFIG_DIR/wg0.conf" "$HOME/original.conf"
  chmod 600 "$HOME/original.conf"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '_vpn_fix_ipv6_config wg0'

  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot retain an IPv4 value"* ]]
  cmp -s "$HOME/original.conf" "$VPN_CONFIG_DIR/wg0.conf"
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn regressions: vpn-on aborts when its required WSL tweak fails" {
  write_regression_profile "$VPN_CONFIG_DIR/wg0.conf"

  run run_zsh '
    _vpn_should_apply_wsl_ipv6_fix() { return 0; }
    _vpn_fix_ipv6_config() { return 1; }
    _vpn_check_wg_quick() { return 0; }
    _vpn_tunnel_up() {
      print -u2 -r -- "TUNNEL SHOULD NOT RUN"
      return 0
    }
    vpn-on wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"tunnel was not started"* ]]
  [[ "$output" != *"TUNNEL SHOULD NOT RUN"* ]]
}

@test "vpn regressions: vpn-details keeps raw wg output off stdout" {
  cat > "$TEST_MOCK_BIN/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "show interfaces" ]]; then
  printf '%s\n' 'wg0'
elif [[ "$*" == "show wg0" ]]; then
  printf '%s\n' 'interface: wg0' '  public key: TEST'
else
  exit 1
fi
EOF
  chmod +x "$TEST_MOCK_BIN/wg"
  local stdout_file="$HOME/details.out"
  local stderr_file="$HOME/details.err"

  run run_zsh \
    "vpn-details >'$stdout_file' 2>'$stderr_file'"

  [ "$status" -eq 0 ]
  [ ! -s "$stdout_file" ]
  grep -q 'interface: wg0' "$stderr_file"
  grep -q 'public key: TEST' "$stderr_file"
}

@test "vpn regressions: vpn-access-lock reports sudo invalidation failure" {
  : > "$MOCK_SUDO_LOG"

  run run_zsh 'vpn-access-lock'

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not invalidate"* ]]
  [[ "$output" != *"Invalidated the current session"* ]]
  grep -q 'sudo -k' "$MOCK_SUDO_LOG"
}

@test "vpn regressions: oversized cache entries are rejected before content read" {
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  truncate -s 1048576 "$VPN_CACHE_DIR/last-iface"
  chmod 600 "$VPN_CACHE_DIR/last-iface"

  run run_zsh '_vpn_peek_last_iface'

  [ "$status" -eq 1 ]
  [[ "$output" == *"oversized cache entry"* ]]
}

@test "vpn regressions: bounded diagnostic capture rejects oversized output" {
  run run_zsh '
    _vpn_regression_producer() {
      print -rn -- "123456789"
    }
    _vpn_info_capture_bounded 8 _vpn_regression_producer >/dev/null
  '

  [ "$status" -eq 1 ]
}

@test "vpn regressions: a terminated interactive menu removes its preview directory" {
  run run_zsh '
    zmodload zsh/system || return 1
    local marker="$HOME/preview.path"
    fzf() {
      command cat >/dev/null
      local argument pane_dir
      for argument in "$@"; do
        if [[ "$argument" == --preview=command\ cat\ --\ * ]]; then
          pane_dir="${${argument#--preview=command cat -- }%/\{n\}}"
          pane_dir="${(Q)pane_dir}"
          print -r -- "$pane_dir" > "$marker"
        fi
      done
      builtin kill -TERM "$sysparams[pid]"
      return 143
    }

    vpn-menu >/dev/null 2>&1
    local menu_rc=$?
    (( menu_rc == 143 )) || return 10
    [[ -s "$marker" ]] || return 11

    local pane_dir
    pane_dir=$(<"$marker")
    [[ ! -e "$pane_dir" ]] || return 12
    return 0
  '

  [ "$status" -eq 0 ]
}
