#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export LC_ALL=C TERM=dumb NO_COLOR=1
  export VPN_CONFIG_DIR="$HOME/wireguard" VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export STATE_PROBE_RC=130 STATE_TARGET=default
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  printf 'wg0\n' > "$VPN_CACHE_DIR/default-iface"
  printf 'wg0\n' > "$VPN_CACHE_DIR/last-iface"
  chmod 600 "$VPN_CACHE_DIR/default-iface" "$VPN_CACHE_DIR/last-iface"
}

teardown() {
  cleanup_sandbox
}

@test "vpn state recovery: interrupted profile checks never become usable cached pointers" {
  for probe_rc in 130 143; do
    export STATE_PROBE_RC="$probe_rc"
    run run_zsh '
      _vpn_config_exists() { return "$STATE_PROBE_RC"; }
      local captured="" read_rc=0
      captured=$(_vpn_read_cached_iface default-iface) || read_rc=$?
      [[ "$read_rc" == "$STATE_PROBE_RC" && -z "$captured" ]] || return 91
      read_rc=0
      captured=$(_vpn_effective_default_iface) || read_rc=$?
      [[ "$read_rc" == "$STATE_PROBE_RC" && -z "$captured" ]] || return 92
      read_rc=0
      captured=$(_vpn_effective_last_iface) || read_rc=$?
      [[ "$read_rc" == "$STATE_PROBE_RC" && -z "$captured" ]] || return 93
    '
    [ "$status" -eq 0 ]
    [ ! -s "$MOCK_SUDO_LOG" ]
  done
}

@test "vpn state recovery: default and reconnect stop before live queries after cached-profile interruption" {
  for probe_rc in 130 143; do
    export STATE_PROBE_RC="$probe_rc"
    for target in default last; do
      export STATE_TARGET="$target"
      run run_zsh '
        _vpn_require_platform() { return 0; }
        _vpn_config_exists() { return "$STATE_PROBE_RC"; }
        _vpn_active_interfaces() {
          print -r -- unexpected >> "$HOME/live.calls"
          return 97
        }
        vpn-on() { print -r -- unexpected >> "$HOME/on.calls"; return 0; }
        case "$STATE_TARGET" in
          default) vpn-default-connect ;;
          last) vpn-reconnect-last ;;
          *) return 99 ;;
        esac
      '
      [ "$status" -eq "$probe_rc" ]
      [[ "$output" != *"No last-used VPN profile"* ]]
      [[ "$output" != *"No default VPN profile"* ]]
      [ ! -e "$HOME/live.calls" ]
      [ ! -e "$HOME/on.calls" ]
      [ ! -s "$MOCK_SUDO_LOG" ]
    done
  done
}

@test "vpn state recovery: ordinary stale pointers still display and an absent last pointer remains a no-op" {
  run run_zsh '
    _vpn_config_exists() { return 1; }
    [[ "$(_vpn_effective_default_iface)" == wg0 ]] || return 91
    [[ "$(_vpn_effective_last_iface)" == wg0 ]] || return 92
    _vpn_read_cached_iface last-iface && return 93
    command rm -- "$VPN_CACHE_DIR/last-iface" || return 94
    _vpn_require_platform() { return 0; }
    _vpn_active_interfaces() { print -r -- unexpected >> "$HOME/live.calls"; return 97; }
    vpn-on() { print -r -- unexpected >> "$HOME/on.calls"; return 0; }
    vpn-reconnect-last
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"No last-used VPN profile is recorded."* ]]
  [ ! -e "$HOME/live.calls" ]
  [ ! -e "$HOME/on.calls" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}
