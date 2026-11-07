#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  vpn_pin_kernel Linux
  unset WSL_DISTRO_NAME WSL_INTEROP
  export VPN_CONFIG_DIR="$HOME/wireguard" VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/reports" REPORT_HOST=fixture-host
  export REPORT_PROVIDER_TEXT='[Login](https://example.invalid/path) *bold*'
  export REPORT_PROBE_STATUS=130
  mkdir -p "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$VPN_MENU_REPORT_DIR"
  chmod -- 700 "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$VPN_MENU_REPORT_DIR"
  printf 'wg0\n' > "$VPN_CACHE_DIR/default-iface"
  printf 'last0\n' > "$VPN_CACHE_DIR/last-iface"
  chmod -- 600 "$VPN_CACHE_DIR"/*
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/hostname"
  cat >> "$TEST_MOCK_BIN/hostname" <<'MOCK'
[[ $# == 0 || ( $# == 1 && "$1" == -s ) ]] || exit 97
printf '%s\n' "$REPORT_HOST"
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/date"
  cat >> "$TEST_MOCK_BIN/date" <<'MOCK'
case "${1:-}" in
  +%Y-%m-%d_%H%M%S) printf '2026-02-01_010203\n' ;;
  +*) printf '2026-02-01 01:02:03 UTC\n' ;;
  *) exit 97 ;;
esac
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/hostname" "$TEST_MOCK_BIN/date"
}

teardown() {
  chmod -- 700 "$HOME/locked" 2>/dev/null || true
  cleanup_sandbox
}

report_file() {
  printf '%s\n' "$2" > "$VPN_MENU_REPORT_DIR/$1"
  chmod -- 600 "$VPN_MENU_REPORT_DIR/$1"
}

run_fixture_report() {
  run run_zsh '
    _vpn_platform() { print -r -- linux; }
    _vpn_check_ip_stack() { return 0; }
    _vpn_have_sudo_cache() { return 1; }
    _vpn_should_apply_wsl_ipv6_fix() { return 1; }
    _vpn_configs_access_state() { print -r -- direct; }
    _vpn_wg_access_state() { print -r -- direct; }
    _vpn_get_active_interfaces() { return 0; }
    _vpn_dns_resolvers() { return 1; }
    _vpn_get_ip_info() {
      printf "203.0.113.7\tFixture City\tFixture Region\tZZ\t%s\tprovider.example\n" "$REPORT_PROVIDER_TEXT"
    }
    _vpn_get_ip_crosscheck() { return 1; }
    vpn-report >"$HOME/report.out" 2>"$HOME/report.err"
  '
}

@test "vpn report safety: successful publication preserves unrelated files with the report prefix" {
  report_file vpn-report-user-notes.md USER-CONTENT-CANARY
  export VPN_MENU_REPORT_RETENTION=1
  run_fixture_report
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_MENU_REPORT_DIR/vpn-report-user-notes.md")" = USER-CONTENT-CANARY ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-fixture-host.md" ]
  [ ! -s "$HOME/report.out" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn report safety: timestamp host and suffix lookalikes remain outside retention" {
  local host64 name
  printf -v host64 '%064d' 0
  local -a names=(
    vpn-report-notes.md
    vpn-report-2026-1-01_000000-host.md
    vpn-report-2026-01-01_00000-host.md
    vpn-report-2026-01-01_000000-.md
    vpn-report-2026-01-01_000000-'space host'.md
    vpn-report-2026-01-01_000000-höst.md
    "vpn-report-2026-01-01_000000-${host64}x.md"
    "vpn-report-2026-01-01_000000-${host64}.0.md"
    "vpn-report-2026-01-01_000000-${host64}.01.md"
    "vpn-report-2026-01-01_000000-${host64}.1000.md"
  )
  for name in "${names[@]}"; do report_file "$name" USER-CONTENT-CANARY; done
  report_file vpn-report-2026-02-01_010203-host.md PUBLISHED
  run run_zsh '
    VPN_MENU_REPORT_RETENTION=1
    _vpn_report_prune "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-host.md"
  '
  [ "$status" -eq 0 ]
  for name in "${names[@]}"; do
    [ "$(cat "$VPN_MENU_REPORT_DIR/$name")" = USER-CONTENT-CANARY ]
  done
}

@test "vpn report safety: legitimate dotted hosts and bounded unique suffixes remain eligible" {
  local host64 name
  printf -v host64 '%064d' 0
  local -a names=(
    vpn-report-2026-01-01_000000-host.name_1-.md
    vpn-report-2026-01-01_000000-host.0.md
    vpn-report-2026-01-01_000000-host.01.md
    "vpn-report-2026-01-01_000000-${host64}.md"
    "vpn-report-2026-01-01_000000-${host64}.1.md"
    "vpn-report-2026-01-01_000000-${host64}.999.md"
  )
  for name in "${names[@]}"; do report_file "$name" OLD-GENERATED; done
  report_file vpn-report-2026-02-01_010203-host.md PUBLISHED
  run run_zsh '
    VPN_MENU_REPORT_RETENTION=1
    _vpn_report_prune "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-host.md"
  '
  [ "$status" -eq 0 ]
  for name in "${names[@]}"; do [ ! -e "$VPN_MENU_REPORT_DIR/$name" ]; done
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-host.md" ]
}

@test "vpn report safety: same-second publication with a maximum-length hostname protects the new collision name" {
  printf -v REPORT_HOST '%064d' 0
  export REPORT_HOST VPN_MENU_REPORT_RETENTION=1
  run_fixture_report
  [ "$status" -eq 0 ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-$REPORT_HOST.md" ]
  run_fixture_report
  [ "$status" -eq 0 ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-$REPORT_HOST.1.md" ]
  [ ! -e "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-$REPORT_HOST.md" ]
  [ "$(file_mode "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-$REPORT_HOST.1.md")" = 600 ]
}

@test "vpn report safety: the just-published report stays protected even when its name sorts oldest" {
  report_file vpn-report-2025-01-01_000000-host.md PUBLISHED
  report_file vpn-report-2026-01-01_000000-host.md OLD-GENERATED
  run run_zsh '
    VPN_MENU_REPORT_RETENTION=1
    _vpn_report_prune "$VPN_MENU_REPORT_DIR/vpn-report-2025-01-01_000000-host.md"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_MENU_REPORT_DIR/vpn-report-2025-01-01_000000-host.md")" = PUBLISHED ]
  [ ! -e "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000000-host.md" ]
}

@test "vpn report safety: changed candidate identity is kept during retention" {
  report_file vpn-report-2026-01-01_000000-host.md OLD-GENERATED
  report_file vpn-report-2026-02-01_010203-host.md PUBLISHED
  run run_zsh '
    VPN_MENU_REPORT_RETENTION=1
    local target="$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000000-host.md"
    print -r -- 0 > "$HOME/validation.count"
    functions[_vpn_report_original_validate]="${functions[_vpn_state_validate_file]}"
    _vpn_state_validate_file() {
      if [[ "$1" == "$target" ]]; then
        local -i observations=$(<"$HOME/validation.count")
        (( ++observations ))
        print -r -- "$observations" > "$HOME/validation.count"
        if (( observations == 2 )); then
          (umask 077; print -r -- REPLACEMENT-CANARY > "$HOME/replacement") || return 91
          command mv -- "$HOME/replacement" "$target" || return 92
        fi
      fi
      _vpn_report_original_validate "$@"
    }
    _vpn_report_prune "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-host.md"
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000000-host.md")" = REPLACEMENT-CANARY ]
  [ "$(cat "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-host.md")" = PUBLISHED ]
}

@test "vpn report safety: unsafe or multiply linked generated entries are not removed" {
  report_file vpn-report-2026-01-01_000000-public.md PUBLIC
  chmod -- 644 "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000000-public.md"
  report_file vpn-report-2026-01-01_000000-linked.md LINKED
  ln "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000000-linked.md" "$HOME/link-anchor"
  report_file vpn-report-2026-02-01_010203-host.md PUBLISHED
  run run_zsh '
    VPN_MENU_REPORT_RETENTION=1
    _vpn_report_prune "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-host.md"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000000-public.md")" = PUBLIC ]
  [ "$(cat "$HOME/link-anchor")" = LINKED ]
  [ "$(file_links "$HOME/link-anchor")" -eq 2 ]
}

@test "vpn report safety: disabled retention is passive" {
  report_file vpn-report-user-notes.md USER-CONTENT-CANARY
  report_file vpn-report-2026-01-01_000000-host.md OLD-GENERATED
  run run_zsh 'VPN_MENU_REPORT_RETENTION=0; _vpn_report_prune missing-path'
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_MENU_REPORT_DIR/vpn-report-user-notes.md")" = USER-CONTENT-CANARY ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000000-host.md" ]
}

clear_interruption() {
  export REPORT_PROBE_STATUS="$1"
  run run_zsh '
    _vpn_config_exists() { return "$REPORT_PROBE_STATUS"; }
    _vpn_confirm_ask() { print -r -- unexpected >> "$HOME/confirm.calls"; return 0; }
    vpn-default-clear >"$HOME/clear.out" 2>"$HOME/clear.err"
  '
  if [ "$status" -ne "$1" ]; then
    printf 'actual-status=%s expected=%s pointer-exists=%s\n' "$status" "$1" "$(test -e "$VPN_CACHE_DIR/default-iface" && printf yes || printf no)" >&2
    cat "$HOME/clear.err" >&2
    false
  fi
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ ! -e "$HOME/confirm.calls" ]
  [ ! -s "$HOME/clear.out" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn pointer safety: interrupted inspection130 keeps the default before confirmation" { clear_interruption 130; }
@test "vpn pointer safety: interrupted inspection143 keeps the default before confirmation" { clear_interruption 143; }

@test "vpn pointer safety: a non-private cache directory is unknown rather than absent" {
  chmod -- 755 "$VPN_CACHE_DIR"
  run run_zsh 'vpn-default-clear --yes'
  [ "$status" -eq 1 ]
  [[ "$output" != *'No default VPN profile is configured'* ]]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(file_mode "$VPN_CACHE_DIR")" = 755 ]
}

@test "vpn pointer safety: a symlinked cache directory is refused rather than absent" {
  mv "$VPN_CACHE_DIR" "$HOME/real-cache"
  ln -s "$HOME/real-cache" "$VPN_CACHE_DIR"
  run run_zsh 'vpn-default-clear --yes'
  [ "$status" -eq 1 ]
  [[ "$output" != *'No default VPN profile is configured'* ]]
  [ "$(cat "$HOME/real-cache/default-iface")" = wg0 ]
  [ -L "$VPN_CACHE_DIR" ]
}

@test "vpn pointer safety: an inaccessible ancestor cannot establish cache absence" {
  mkdir "$HOME/locked"
  mv "$VPN_CACHE_DIR" "$HOME/locked/cache"
  export VPN_CACHE_DIR="$HOME/locked/cache"
  chmod -- 000 "$HOME/locked"
  run run_zsh 'vpn-default-clear --yes'
  chmod -- 700 "$HOME/locked"
  [ "$status" -eq 1 ]
  [[ "$output" != *'No default VPN profile is configured'* ]]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
}

@test "vpn pointer safety: an unsafe pointer file is kept without permission repair" {
  chmod -- 644 "$VPN_CACHE_DIR/default-iface"
  run run_zsh 'vpn-default-clear --yes'
  [ "$status" -eq 1 ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(file_mode "$VPN_CACHE_DIR/default-iface")" = 644 ]
}

@test "vpn pointer safety: genuine absent cache and pointer paths remain passive no-ops" {
  export VPN_CACHE_DIR="$HOME/not-created/cache"
  run run_zsh 'vpn-default-clear --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *'No default VPN profile is configured'* ]]
  [ ! -e "$HOME/not-created" ]
  mkdir -p "$VPN_CACHE_DIR"
  chmod -- 700 "$VPN_CACHE_DIR"
  run run_zsh 'vpn-default-clear --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$VPN_CACHE_DIR/default-iface" ]
}

@test "vpn pointer safety: a valid stale pointer still needs terminal confirmation or yes" {
  run run_zsh '_vpn_config_exists() { return 1; }; vpn-default-clear'
  [ "$status" -eq 1 ]
  [[ "$output" == *'pass --yes'* ]]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
}

@test "vpn pointer safety: declining a stale pointer clear keeps both saved choices" {
  run run_zsh '
    _vpn_config_exists() { return 1; }
    _vpn_confirm_ask() { return 1; }
    vpn-default-clear
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'Cancelled'* ]]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = last0 ]
}

@test "vpn pointer safety: yes clears only the validated stale default pointer" {
  run run_zsh '_vpn_config_exists() { return 1; }; vpn-default-clear --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$VPN_CACHE_DIR/default-iface" ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = last0 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn pointer safety: an unknown default inspection result cannot authorize deletion" {
  run run_zsh '
    _vpn_effective_default_iface() { return 1; }
    _vpn_confirm_ask() { print -r -- unexpected >> "$HOME/confirm.calls"; return 0; }
    vpn-default-clear --yes
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ ! -e "$HOME/confirm.calls" ]
}

@test "vpn report safety: link and emphasis delimiters receive exactly one Markdown escape" {
  export REPORT_MARKDOWN_INPUT='[Login](https://example.invalid/path) *bold*'
  run run_zsh '_vpn_rpt_escape "$REPORT_MARKDOWN_INPUT"'
  [ "$status" -eq 0 ]
  [ "$output" = '\[Login\](https://example.invalid/path) \*bold\*' ]
}

@test "vpn report safety: existing Markdown escape characters keep their literal encoding" {
  export REPORT_MARKDOWN_INPUT='a\b|`_<>'
  run run_zsh '_vpn_rpt_escape "$REPORT_MARKDOWN_INPUT"'
  [ "$status" -eq 0 ]
  [ "$output" = 'a\\b\|\`\_\<\>' ]
}

@test "vpn report safety: provider link and emphasis text stays escaped in the complete saved report" {
  run_fixture_report
  [ "$status" -eq 0 ]
  local report="$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_010203-fixture-host.md"
  [ "$(file_mode "$report")" = 600 ]
  grep -Fq -- '\[Login\](https://example.invalid/path) \*bold\*' "$report"
  [ ! -s "$HOME/report.out" ]
}

@test "vpn pointer safety: mode000 existing cache remains unknown and keeps pointers without permission repair" {
  chmod -- 000 "$VPN_CACHE_DIR"
  run run_zsh 'vpn-default-clear --yes >"$HOME/clear.out" 2>"$HOME/clear.err"'
  local clear_status="$status" observed_cache_mode="" cache_mode_rc=0
  observed_cache_mode=$(file_mode "$VPN_CACHE_DIR") || cache_mode_rc=$?
  chmod -- 700 "$VPN_CACHE_DIR"
  [ "$cache_mode_rc" -eq 0 ]
  if [ "$clear_status" -ne 1 ]; then
    printf 'actual-status=%s expected=1 observed-cache-mode=%s\n' "$clear_status" "$observed_cache_mode" >&2
    cat "$HOME/clear.err" >&2
    false
  fi
  [ "$observed_cache_mode" = 0 ]
  grep -qF 'Refusing to clear default state that could not be inspected safely.' "$HOME/clear.err"
  ! grep -qF 'No default VPN profile is configured.' "$HOME/clear.err" || false
  [ ! -s "$HOME/clear.out" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(file_mode "$VPN_CACHE_DIR/default-iface")" = 600 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = last0 ]
  [ "$(file_mode "$VPN_CACHE_DIR/last-iface")" = 600 ]
}

@test "vpn pointer safety: mode0600 existing cache remains unknown and keeps pointers without permission repair" {
  chmod -- 600 "$VPN_CACHE_DIR"
  run run_zsh 'vpn-default-clear --yes >"$HOME/clear.out" 2>"$HOME/clear.err"'
  local clear_status="$status" observed_cache_mode="" cache_mode_rc=0
  observed_cache_mode=$(file_mode "$VPN_CACHE_DIR") || cache_mode_rc=$?
  chmod -- 700 "$VPN_CACHE_DIR"
  [ "$cache_mode_rc" -eq 0 ]
  if [ "$clear_status" -ne 1 ]; then
    printf 'actual-status=%s expected=1 observed-cache-mode=%s\n' "$clear_status" "$observed_cache_mode" >&2
    cat "$HOME/clear.err" >&2
    false
  fi
  [ "$observed_cache_mode" = 600 ]
  grep -qF 'Refusing to clear default state that could not be inspected safely.' "$HOME/clear.err"
  ! grep -qF 'No default VPN profile is configured.' "$HOME/clear.err" || false
  [ ! -s "$HOME/clear.out" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(file_mode "$VPN_CACHE_DIR/default-iface")" = 600 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = last0 ]
  [ "$(file_mode "$VPN_CACHE_DIR/last-iface")" = 600 ]
}
