#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export VPN_CONFIG_DIR="$HOME/WireGuard profiles"
  export VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"
  export VPN_RECOVERY_CALLS="$HOME/tunnel-calls"
  export VPN_RECOVERY_ACTIVE="wg0 wg1"
  export VPN_RECOVERY_FAIL_IFACE=""
  export VPN_RECOVERY_STATUS=0
  export MOCK_SUDO_ALLOW='true,__validate__,wg-quick'
  unset WSL_DISTRO_NAME WSL_INTEROP VPN_MENU_WSL_IPV6_FIX
  mkdir -m 700 "$VPN_CONFIG_DIR"
  local iface
  for iface in wg0 wg1; do
    printf '[Interface]\nPrivateKey = TEST-KEY=\nAddress = 10.0.0.2/24\n\n[Peer]\nPublicKey = PEER-KEY=\nAllowedIPs = 0.0.0.0/0\n' \
      > "$VPN_CONFIG_DIR/$iface.conf"
    chmod 600 "$VPN_CONFIG_DIR/$iface.conf"
  done
  : > "$VPN_RECOVERY_CALLS"
  cat > "$TEST_MOCK_BIN/wg-quick" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$#" >> "$VPN_RECOVERY_CALLS"
iface="${2##*/}"
iface="${iface%.conf}"
if [[ "$iface" == "$VPN_RECOVERY_FAIL_IFACE" ]]; then
  exit "$VPN_RECOVERY_STATUS"
fi
exit 0
EOF
  cat > "$TEST_MOCK_BIN/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == 'show interfaces' ]]; then
  printf '%s\n' "$VPN_RECOVERY_ACTIVE"
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/wg-quick" "$TEST_MOCK_BIN/wg"
}

teardown() {
  cleanup_sandbox
}

@test "vpn control recovery: up and down execute the exact validated path with spaces" {
  run run_zsh '
    _vpn_should_apply_wsl_ipv6_fix() { return 1; }
    vpn-details() { return 0; }
    vpn-on wg0 > "$HOME/up-stdout" || return
    vpn-off wg0 > "$HOME/down-stdout"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/up-stdout" ]
  [ ! -s "$HOME/down-stdout" ]
  [ "$(cat "$VPN_RECOVERY_CALLS")" = \
    "$(printf 'up\t%s/wg0.conf\t2\ndown\t%s/wg0.conf\t2' "$VPN_CONFIG_DIR" "$VPN_CONFIG_DIR")" ]
}

@test "vpn control recovery: down refuses a missing configured profile without fallback" {
  mv "$VPN_CONFIG_DIR/wg0.conf" "$HOME/unrelated.conf"
  run run_zsh 'vpn-off wg0'
  [ "$status" -eq 1 ]
  [ ! -s "$VPN_RECOVERY_CALLS" ]
}

@test "vpn control recovery: down refuses a profile changed during authentication" {
  run run_zsh '
    _vpn_ensure_sudo_access() {
      print -r -- "# changed during authentication" >> "$VPN_CONFIG_DIR/wg0.conf"
      return 0
    }
    vpn-off wg0
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed during authentication"* ]]
  [ ! -s "$VPN_RECOVERY_CALLS" ]
}

@test "vpn control recovery: down refuses a replaced profile directory" {
  run run_zsh '
    _vpn_ensure_sudo_access() {
      command mv -- "$VPN_CONFIG_DIR" "$HOME/old-profiles" || return
      command mkdir -m 700 -- "$VPN_CONFIG_DIR" || return
      command cp -- "$HOME/old-profiles/wg0.conf" "$VPN_CONFIG_DIR/wg0.conf"
    }
    vpn-off wg0
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"VPN_CONFIG_DIR changed"* ]]
  [ ! -s "$VPN_RECOVERY_CALLS" ]
}

@test "vpn control recovery: down revalidates the profile after querying active interfaces" {
  run run_zsh '
    _vpn_get_active_interfaces() {
      print -r -- "# changed during active-interface query" >> "$VPN_CONFIG_DIR/wg0.conf"
      print -r -- wg0
    }
    vpn-off wg0
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed during authentication"* ]]
  [ ! -s "$VPN_RECOVERY_CALLS" ]
}

@test "vpn control recovery: protected profile access is authorized before fingerprinting" {
  run run_zsh '
    functions[_vpn_recovery_fingerprint]=$functions[_vpn_profile_file_fingerprint]
    _vpn_configs_access_state() { print -r -- locked; }
    _vpn_profile_file_fingerprint() {
      [[ -e "$HOME/profiles-unlocked" ]] || return 90
      _vpn_recovery_fingerprint "$@"
    }
    _vpn_ensure_sudo_access() {
      print -u2 -r -- "PROFILE ACCESS AUTHORIZED"
      : > "$HOME/profiles-unlocked"
    }
    vpn-details() { return 0; }
    vpn-off wg0
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Privileged operation: wg-quick down"*"PROFILE ACCESS AUTHORIZED"* ]]
  [ "$(cat "$VPN_RECOVERY_CALLS")" = \
    "$(printf 'down\t%s/wg0.conf\t2' "$VPN_CONFIG_DIR")" ]
}

@test "vpn control recovery: direct transitions preserve backend interruptions" {
  export VPN_RECOVERY_FAIL_IFACE=wg0
  local action code
  for action in vpn-on vpn-off; do
    for code in 130 143; do
      export VPN_RECOVERY_STATUS="$code" VPN_RECOVERY_ACTION="$action"
      run run_zsh '
        _vpn_should_apply_wsl_ipv6_fix() { return 1; }
        vpn-details() { print -r -- details >> "$HOME/details-called"; }
        "$VPN_RECOVERY_ACTION" wg0
      '
      [ "$status" -eq "$code" ]
      [ ! -e "$HOME/details-called" ]
      [ ! -e "$VPN_CACHE_DIR/last-iface" ]
      [[ "$output" != *"is now ON"* ]]
      [[ "$output" != *"is now OFF"* ]]
    done
  done
}

@test "vpn control recovery: authentication interruptions run no tunnel command" {
  local action code
  for action in vpn-on vpn-off; do
    for code in 130 143; do
      export VPN_RECOVERY_STATUS="$code" VPN_RECOVERY_ACTION="$action"
      run run_zsh '
        _vpn_should_apply_wsl_ipv6_fix() { return 1; }
        _vpn_ensure_sudo_access() { return "$VPN_RECOVERY_STATUS"; }
        "$VPN_RECOVERY_ACTION" wg0
      '
      [ "$status" -eq "$code" ]
      [ ! -s "$VPN_RECOVERY_CALLS" ]
    done
  done
}

@test "vpn control recovery: bulk disconnect stops later targets after interruption" {
  export VPN_RECOVERY_FAIL_IFACE=wg0
  local code
  for code in 130 143; do
    : > "$VPN_RECOVERY_CALLS"
    export VPN_RECOVERY_STATUS="$code"
    run run_zsh '
      vpn-details() { print -r -- details >> "$HOME/details-called"; }
      vpn-off-all --yes
    '
    [ "$status" -eq "$code" ]
    [ "$(wc -l < "$VPN_RECOVERY_CALLS")" -eq 1 ]
    [[ "$output" == *"not attempted"* ]]
    [[ "$output" == *"wg1"* ]]
    [ ! -e "$HOME/details-called" ]
  done
}

@test "vpn control recovery: ordinary disconnect failures allow later targets" {
  export VPN_RECOVERY_FAIL_IFACE=wg0 VPN_RECOVERY_STATUS=9
  run run_zsh 'vpn-off-all --yes'
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$VPN_RECOVERY_CALLS")" -eq 2 ]
  [[ "$output" == *"VPN (wg1) is now OFF"* ]]
  [[ "$output" == *"1 of 2 interface(s) failed to disconnect"* ]]
}

@test "vpn control recovery: interruption on the last target invents no pending interface" {
  export VPN_RECOVERY_FAIL_IFACE=wg1 VPN_RECOVERY_STATUS=130
  run run_zsh 'vpn-off-all --yes'
  [ "$status" -eq 130 ]
  [ "$(wc -l < "$VPN_RECOVERY_CALLS")" -eq 2 ]
  [[ "$output" != *"Not attempted:"* ]]
}

@test "vpn control recovery: default and reconnect refuse unknown active state" {
  local action code
  for action in vpn-default-connect vpn-reconnect-last; do
    for code in 1 130 143; do
      export VPN_RECOVERY_ACTION="$action" VPN_RECOVERY_STATUS="$code"
      run run_zsh '
        _vpn_read_last_iface() { print -r -- wg0; }
        _vpn_effective_default_iface() { print -r -- wg0; }
        _vpn_active_interfaces() { return "$VPN_RECOVERY_STATUS"; }
        vpn-on() { print -r -- started >> "$HOME/unexpected-start"; }
        "$VPN_RECOVERY_ACTION"
      '
      [ "$status" -eq "$code" ]
      [ ! -e "$HOME/unexpected-start" ]
      [ ! -s "$VPN_RECOVERY_CALLS" ]
    done
  done
}

@test "vpn control recovery: reconnect does not restart after interrupted disconnect" {
  export VPN_RECOVERY_FAIL_IFACE=wg0
  local code
  for code in 130 143; do
    : > "$VPN_RECOVERY_CALLS"
    export VPN_RECOVERY_STATUS="$code"
    run run_zsh '
      _vpn_read_last_iface() { print -r -- wg0; }
      vpn-on() { print -r -- started >> "$HOME/unexpected-start"; }
      vpn-reconnect-last
    '
    [ "$status" -eq "$code" ]
    [ ! -e "$HOME/unexpected-start" ]
    [ "$(wc -l < "$VPN_RECOVERY_CALLS")" -eq 1 ]
  done
}

@test "vpn control recovery: active-interface capture preserves interruption statuses" {
  local code
  for code in 130 143; do
    export VPN_RECOVERY_STATUS="$code"
    run run_zsh '
      _vpn_get_active_interfaces() { return "$VPN_RECOVERY_STATUS"; }
      _vpn_active_interfaces
    '
    [ "$status" -eq "$code" ]
  done
}

@test "vpn control recovery: bulk dry-run uses no sudo and needs no profile mutation" {
  run run_zsh 'vpn-off-all --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -s "$VPN_RECOVERY_CALLS" ]
}

@test "vpn control recovery: interrupted profile fingerprints stop before later mutations" {
  local action phase code
  for action in up all; do
    for phase in 1 2; do
      for code in 130 143; do
        export VPN_RECOVERY_ACTION="$action" VPN_RECOVERY_PHASE="$phase"
        export VPN_RECOVERY_STATUS="$code"
        : > "$HOME/fingerprint-calls"
        run run_zsh '
          _vpn_should_apply_wsl_ipv6_fix() { return 1; }
          _vpn_profile_file_fingerprint() {
            local -i calls=0
            [[ ! -s "$HOME/fingerprint-calls" ]] \
              || calls=$(<"$HOME/fingerprint-calls")
            calls=$(( calls + 1 ))
            print -r -- "$calls" > "$HOME/fingerprint-calls"
            (( calls != VPN_RECOVERY_PHASE )) || return "$VPN_RECOVERY_STATUS"
            print -r -- unchanged-fingerprint
          }
          case "$VPN_RECOVERY_ACTION" in
            up) vpn-on wg0 ;;
            all) vpn-off-all --yes ;;
          esac
        '
        [ "$status" -eq "$code" ]
        [ ! -s "$VPN_RECOVERY_CALLS" ]
        [ "$(cat "$HOME/fingerprint-calls")" -eq "$phase" ]
        [ ! -e "$VPN_CACHE_DIR/last-iface" ]
      done
    done
  done
}

@test "vpn control recovery: interrupted profile existence inspection is preserved" {
  local code
  for code in 130 143; do
    export VPN_RECOVERY_STATUS="$code"
    run run_zsh '
      _vpn_profile_path_state() { return "$VPN_RECOVERY_STATUS"; }
      vpn-on wg0
    '
    [ "$status" -eq "$code" ]
    [ ! -s "$VPN_RECOVERY_CALLS" ]
    [ ! -e "$VPN_CACHE_DIR/last-iface" ]
  done
}

@test "vpn control recovery: default and reconnect authorize cold live-state access" {
  local action code
  for action in vpn-default-connect vpn-reconnect-last; do
    for code in 0 1 130 143; do
      export VPN_RECOVERY_ACTION="$action" VPN_RECOVERY_STATUS="$code"
      export VPN_RECOVERY_CASE="$HOME/access-$action-$code"
      run run_zsh '
        _vpn_read_last_iface() { print -r -- wg0; }
        _vpn_effective_default_iface() { print -r -- wg0; }
        _vpn_wg_access_state() { print -r -- locked; }
        _vpn_ensure_sudo_access() {
          (( VPN_RECOVERY_STATUS == 0 )) || return "$VPN_RECOVERY_STATUS"
          : > "${VPN_RECOVERY_CASE}.authenticated"
        }
        _vpn_get_active_interfaces() {
          : > "${VPN_RECOVERY_CASE}.queried"
          [[ -e "${VPN_RECOVERY_CASE}.authenticated" ]] || return 1
          return 0
        }
        vpn-on() { : > "${VPN_RECOVERY_CASE}.started"; }
        "$VPN_RECOVERY_ACTION"
      '
      [ "$status" -eq "$code" ]
      if [ "$code" -eq 0 ]; then
        [ -e "${VPN_RECOVERY_CASE}.authenticated" ]
        [ -e "${VPN_RECOVERY_CASE}.queried" ]
        [ -e "${VPN_RECOVERY_CASE}.started" ]
      else
        [ ! -e "${VPN_RECOVERY_CASE}.queried" ]
        [ ! -e "${VPN_RECOVERY_CASE}.started" ]
      fi
      [ ! -s "$VPN_RECOVERY_CALLS" ]
    done
  done
}
