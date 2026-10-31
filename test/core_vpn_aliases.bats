#!/usr/bin/env bats

setup() {
  load test_helper
  load core_options_test_helper
}

teardown() {
  cleanup_sandbox
}

f304_vpn_json_alias_case() {
  command -v jq >/dev/null || skip "jq is not installed"
  export F304_JSON_BRANCH="$1"
  f304_mock_local_probes
  cat > "$HOME/program.zsh" <<'ZSH'
emulate -R zsh
if [[ "$F304_ALIAS_MODE" == aliased ]]; then
  alias jq='print -r -- F304_ALIASED_JQ'
fi
vpn-menu --help >/dev/null 2>&1 || exit 31
_vpn_load_provider_urls() {
  reply=()
  [[ "$1" == _vpn_ipinfo_json_providers ]] || return 1
  reply=(https://json.example.invalid/)
}
_vpn_curl_bounded() {
  print -r -- '{"ip":"198.51.100.7","country":"XX","org":"Example"}'
}
local result
case "$F304_JSON_BRANCH" in
  info)
    result=$(_vpn_get_ip_info) || exit 32
    [[ "$result" == $'198.51.100.7\t\t\tXX\tExample\tjson.example.invalid' ]] || exit 33
    ;;
  crosscheck)
    result=$(_vpn_crosscheck_provider json https://json.example.invalid/) || exit 34
    [[ "$result" == $'json.example.invalid\t198.51.100.7' ]] || exit 35
    ;;
  *) exit 36 ;;
esac
if [[ "$F304_ALIAS_MODE" == aliased ]]; then
  [[ "${aliases[jq]:-}" == 'print -r -- F304_ALIASED_JQ' ]] || exit 37
fi
ZSH
  local mode
  for mode in control aliased; do
    export F304_ALIAS_MODE="$mode"
    run f304_lazy_shell "$HOME/program.zsh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "F3-04 alias boundary: JSON IP-info uses jq with a late alias and without it" {
  f304_vpn_json_alias_case info
}

@test "F3-04 alias boundary: JSON cross-check uses jq with a late alias and without it" {
  f304_vpn_json_alias_case crosscheck
}

@test "F3-04 alias boundary: both report dates use date with a late alias and without it" {
  load vpn_test_helper
  vpn_pin_kernel Linux
  f304_mock_local_probes
  export VPN_CONFIG_DIR="$HOME/wireguard"
  mkdir -p "$VPN_CONFIG_DIR"
  chmod -- 700 "$VPN_CONFIG_DIR"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/date"
  cat >> "$TEST_MOCK_BIN/date" <<'BASH'
printf '<%s>\n' "$@" >> "$F304_DATE_CALLS"
case "${1:-}" in
  '+%Y-%m-%d %H:%M:%S %Z') printf '%s\n' '2026-10-31 12:34:56 UTC' ;;
  +%Y-%m-%d_%H%M%S) printf '%s\n' '2026-10-31_123456' ;;
  *) exit 97 ;;
esac
BASH
  chmod -- 755 "$TEST_MOCK_BIN/date"
  cat > "$HOME/program.zsh" <<'ZSH'
emulate -R zsh
if [[ "$F304_ALIAS_MODE" == aliased ]]; then
  alias date='print -r -- F304_ALIASED_DATE'
fi
vpn-menu --help >/dev/null 2>&1 || exit 31
# Only report timestamps and the real private publication path are under
# test; every live diagnostic probe is replaced by an unavailable result.
_vpn_check_ip_stack() { return 0; }
_vpn_info_capture_bounded() { return 1; }
_vpn_have_sudo_cache() { return 1; }
_vpn_should_apply_wsl_ipv6_fix() { return 1; }
_vpn_dns_resolvers() { return 1; }
_vpn_get_ip_info() { return 1; }
_vpn_get_ip_crosscheck() { return 1; }
vpn-report > "$HOME/report.stdout" 2> "$HOME/report.stderr" || {
  command cat "$HOME/report.stderr"
  exit 32
}
[[ ! -s "$HOME/report.stdout" ]] || exit 33
if [[ "$F304_ALIAS_MODE" == aliased ]]; then
  [[ "${aliases[date]:-}" == 'print -r -- F304_ALIASED_DATE' ]] || exit 34
fi
ZSH
  local mode report_file
  for mode in control aliased; do
    export F304_ALIAS_MODE="$mode"
    export F304_DATE_CALLS="$HOME/date-$mode.calls"
    export VPN_MENU_REPORT_DIR="$HOME/reports-$mode"
    : > "$F304_DATE_CALLS"
    run f304_lazy_shell "$HOME/program.zsh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    report_file=$(find "$VPN_MENU_REPORT_DIR" -type f -name 'vpn-report-*.md')
    [ -f "$report_file" ]
    grep -Fxq -- '- **Generated:** 2026-10-31 12:34:56 UTC' "$report_file"
    grep -Fxq -- '- **Finished:** 2026-10-31 12:34:56 UTC' "$report_file"
    ! grep -Fq -- F304_ALIASED_DATE "$report_file" || false
    [ "$(grep -Fxc -- '<+%Y-%m-%d %H:%M:%S %Z>' "$F304_DATE_CALLS")" -eq 2 ]
  done
}
