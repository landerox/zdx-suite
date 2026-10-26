#!/usr/bin/env bats

setup() {
  load test_helper
  load vpn_test_helper
  # A Linux kernel unless a test pins another; a WSL host still reads as WSL.
  vpn_pin_kernel Linux

  export VPN_PROFILE_DIR="$HOME/wireguard"
  export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
  export VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"

  mkdir -p "$VPN_PROFILE_DIR"
  chmod 700 "$VPN_PROFILE_DIR"
}

teardown() {
  cleanup_sandbox
}

write_profile_file() {
  local target="$1"
  local interface_extra="${2-}"

  mkdir -p "$(dirname "$target")"
  {
    printf '[Interface]\n'
    printf 'PrivateKey = TEST-PRIVATE-KEY=\n'
    printf 'Address = 10.0.0.2/24\n'
    [[ -n "$interface_extra" ]] && printf '%s\n' "$interface_extra"
    printf '\n[Peer]\n'
    printf 'PublicKey = TEST-PEER-KEY=\n'
    printf 'AllowedIPs = 0.0.0.0/0\n'
    printf 'Endpoint = 203.0.113.10:51820\n'
  } > "$target"
  chmod 600 "$target"
}

# write_raw_profile PATH TEXT: a private profile holding TEXT, whose \n, \t,
# and \r escapes are expanded.
write_raw_profile() {
  printf '%b' "$2" > "$1"
  chmod 600 "$1"
}

# The bypass profile of audit finding VPN-001. wg-quick compares section names
# and keys without letter case, so its first, lower-case [interface] section
# runs the PreUp hook as root. The padding keeps `head` writing after a
# `grep -q` pipeline has matched the hook, so head dies of SIGPIPE and an
# inherited PIPE_FAIL turns that match into a pipeline failure. The exact
# [Interface] and [Peer] headers come last, where a case-sensitive section
# check finds them.
write_padded_hook_profile() {
  local target="$1" line
  {
    printf '[interface]\nPreUp = touch %s/hook-ran\n' "$HOME"
    for (( line = 0; line < 6000; line++ )); do
      printf '# padding line %05d ......................................\n' "$line"
    done
    printf '[Interface]\nPrivateKey = TEST-PRIVATE-KEY=\nAddress = 10.0.0.2/32\n'
    printf '[Peer]\nPublicKey = TEST-PEER-KEY=\nAllowedIPs = 0.0.0.0/0\n'
  } > "$target"
  chmod 600 "$target"
}

# validate_profiles_as CALLER NAME...: runs _vpn_validate_profile_file on
# each $HOME/NAME.conf in one Zsh whose caller first applied CALLER's options:
# "default", "pipe_fail" (setopt pipe_fail), or "sh" (emulate sh). Each call's
# standard error is kept in $HOME/NAME.err, and $output holds one
# "NAME rc=STATUS" line per profile.
validate_profiles_as() {
  local setup name program=""
  case "$1" in
    default) setup=':' ;;
    pipe_fail) setup='setopt pipe_fail' ;;
    sh) setup='emulate sh' ;;
    *) return 64 ;;
  esac
  shift
  for name in "$@"; do
    program+="_vpn_validate_profile_file \"\$HOME/$name.conf\" 2>\"\$HOME/$name.err\""
    program+="; print -r -- \"$name rc=\$?\""$'\n'
  done
  run run_zsh "$setup"$'\n'"$program"
}

# The sudo commands a successful import runs through the mock recorder.
IMPORT_SUDO_ALLOW='true,__validate__,test,install,mktemp,ln,rm,mv'

install_fixed_date_mock() {
  cat > "$TEST_MOCK_BIN/date" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  +%Y-%m-%d_%H%M%S) printf '%s\n' '2026-07-26_010203' ;;
  +%Y%m%d_%H%M%S) printf '%s\n' '20260726_010203' ;;
  +*) printf '%s\n' '2026-07-26 01:02:03 VET' ;;
  *) printf '%s\n' '2026-07-26 01:02:03 VET' ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/date"
}

# --- Profile-directory boundary --------------------------------------------

@test "vpn hardening: filesystem root is rejected before sudo" {
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    VPN_CONFIG_DIR=/
    vpn-profile-create wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"protected VPN_CONFIG_DIR"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: a relative profile directory is rejected before sudo" {
  mkdir -p "$HOME/relative-wireguard"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    cd "$HOME" || return 1
    VPN_CONFIG_DIR=relative-wireguard
    vpn-profile-create wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"absolute path"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: traversal in the profile directory is rejected before sudo" {
  mkdir -p "$HOME/base" "$HOME/wireguard"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    VPN_CONFIG_DIR="$HOME/base/../wireguard"
    vpn-profile-create wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"must not contain '..'"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: any symlinked profile-directory component is rejected before sudo" {
  mkdir -p "$HOME/real-config/wireguard"
  ln -s "$HOME/real-config" "$HOME/config-link"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    VPN_CONFIG_DIR="$HOME/config-link/wireguard"
    vpn-profile-create wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink component"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ -z "$(find "$HOME/real-config/wireguard" -mindepth 1 -print -quit)" ]
}

# --- Imported profile trust boundary ---------------------------------------

@test "vpn hardening: imported profiles reject every wg-quick hook by default" {
  local hook
  for hook in PreUp PostUp PreDown PostDown; do
    write_profile_file \
      "$HOME/import-${hook}.conf" \
      "${hook} = touch $HOME/root-hook-${hook}"
  done
  write_profile_file "$HOME/import-clean.conf"
  export MOCK_SUDO_ALLOW="$IMPORT_SUDO_ALLOW"
  : > "$MOCK_SUDO_LOG"

  # The name prompt is answered with its default, so without a terminal the
  # import still reaches the step that decides: only the hook check can
  # refuse these profiles.
  run run_zsh '
    _vpn_read_line() { print -r -- "$2"; }
    local hook
    for hook in PreUp PostUp PreDown PostDown; do
      if vpn-profile-import "$HOME/import-${hook}.conf"; then
        print -u2 -r -- "unsafe hook accepted: $hook"
        return 40
      fi
    done
    return 0
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ "$(grep -cF 'must not contain PreUp/PostUp/PreDown/PostDown hooks' <<<"$output")" -eq 4 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ -z "$(find "$VPN_PROFILE_DIR" -mindepth 1 -print -quit)" ]

  # Control: the same harness imports a profile without hooks.
  run run_zsh '
    _vpn_read_line() { print -r -- "$2"; }
    vpn-profile-import "$HOME/import-clean.conf"
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [[ "$output" == *"Imported profile: import-clean"* ]]
  [ -f "$VPN_PROFILE_DIR/import-clean.conf" ]
  [ -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: a padded lower-case [interface] hook is refused under any caller options" {
  write_padded_hook_profile "$HOME/padded.conf"

  local caller
  for caller in default pipe_fail sh; do
    validate_profiles_as "$caller" padded
    printf '%s:\n%s\n' "$caller" "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "padded rc=1" ]
    grep -Fq 'must not contain PreUp/PostUp/PreDown/PostDown hooks' "$HOME/padded.err"
  done
}

@test "vpn hardening: hook keys are refused in any letter case, spacing, or section" {
  local peer='\n[Peer]\nPublicKey = P=\nAllowedIPs = 0.0.0.0/0\n'
  write_raw_profile "$HOME/lower-spaced.conf" \
    "[Interface]\nPrivateKey = K=\npostup = touch $HOME/hook-ran\n$peer"
  write_raw_profile "$HOME/compact.conf" \
    "[Interface]\nPrivateKey = K=\nPreDown=touch $HOME/hook-ran\n$peer"
  write_raw_profile "$HOME/upper-tabs-crlf.conf" \
    "[Interface]\r\nPrivateKey = K=\r\n \tPOSTDOWN\t=\ttouch $HOME/hook-ran\r\n\r\n[Peer]\r\nPublicKey = P=\r\n"
  write_raw_profile "$HOME/in-peer.conf" \
    "[Interface]\nPrivateKey = K=\n${peer}PreUp = touch $HOME/hook-ran\n"
  write_raw_profile "$HOME/before-sections.conf" \
    "pReUp = touch $HOME/hook-ran\n[Interface]\nPrivateKey = K=\n$peer"
  # wg-quick's key is the comment-free text before the first `=`, or the
  # whole comment-free line, so both of these still run a hook as root.
  write_raw_profile "$HOME/bare-key.conf" \
    "[Interface]\nPrivateKey = K=\nPostUp\n$peer"
  write_raw_profile "$HOME/comment-before-equals.conf" \
    "[Interface]\nPrivateKey = K=\nPreUp# note = touch $HOME/hook-ran\n$peer"
  # wg-quick trims a carriage return from the key, and it reads a final line
  # that has no line feed.
  write_raw_profile "$HOME/cr-before-equals.conf" \
    "[Interface]\nPrivateKey = K=\nPreUp\r= touch $HOME/hook-ran\n$peer"
  write_raw_profile "$HOME/final-line-no-lf.conf" \
    "[Peer]\nPublicKey = P=\nAllowedIPs = 0.0.0.0/0\n\n[Interface]\nPrivateKey = K=\nPostDown = touch $HOME/hook-ran"

  local caller name
  local -a names=(lower-spaced compact upper-tabs-crlf in-peer before-sections
    bare-key comment-before-equals cr-before-equals final-line-no-lf)
  for caller in default pipe_fail sh; do
    validate_profiles_as "$caller" "${names[@]}"
    printf '%s:\n%s\n' "$caller" "$output"
    [ "$status" -eq 0 ]
    for name in "${names[@]}"; do
      grep -qx "$name rc=1" <<<"$output"
      grep -Fq 'must not contain PreUp/PostUp/PreDown/PostDown hooks' "$HOME/$name.err"
    done
  done
}

@test "vpn hardening: comments neither hide a hook line nor count as one" {
  local peer='\n[Peer]\nPublicKey = P=\nAllowedIPs = 0.0.0.0/0\n'
  write_raw_profile "$HOME/hook-after-comment.conf" \
    "[Interface]\n# Provider settings follow.\nPrivateKey = K= # key note\nPostUp = touch $HOME/hook-ran\n$peer"
  write_raw_profile "$HOME/commented-hooks.conf" \
    "[Interface]\n# PostUp = touch $HOME/hook-ran\nPrivateKey = K= # PreUp = touch $HOME/hook-ran\n$peer"

  local caller
  for caller in default pipe_fail sh; do
    validate_profiles_as "$caller" hook-after-comment commented-hooks
    printf '%s:\n%s\n' "$caller" "$output"
    [ "$status" -eq 0 ]
    [ "$output" = $'hook-after-comment rc=1\ncommented-hooks rc=0' ]
    grep -Fq 'must not contain PreUp/PostUp/PreDown/PostDown hooks' \
      "$HOME/hook-after-comment.err"
    [ ! -s "$HOME/commented-hooks.err" ]
  done
}

@test "vpn hardening: a second [Interface] section is refused under any caller options" {
  local peer='\n[Peer]\nPublicKey = P=\nAllowedIPs = 0.0.0.0/0\n'
  write_raw_profile "$HOME/interface-after-peer.conf" \
    "[Interface]\nPrivateKey = K=\n${peer}\n[Interface]\nAddress = 10.0.0.3/32\n"
  write_raw_profile "$HOME/interface-lower-first.conf" \
    "[interface]\nAddress = 10.0.0.3/32\n\n[Interface]\nPrivateKey = K=\n$peer"

  local caller name
  for caller in default pipe_fail sh; do
    validate_profiles_as "$caller" interface-after-peer interface-lower-first
    printf '%s:\n%s\n' "$caller" "$output"
    [ "$status" -eq 0 ]
    for name in interface-after-peer interface-lower-first; do
      grep -qx "$name rc=1" <<<"$output"
      grep -Fq 'must contain a single [Interface] section' "$HOME/$name.err"
    done
  done
}

@test "vpn hardening: missing sections and an unreadable source state their reason" {
  local peer='\n[Peer]\nPublicKey = P=\nAllowedIPs = 0.0.0.0/0\n'
  write_raw_profile "$HOME/no-peer.conf" '[Interface]\nPrivateKey = K=\n'
  write_raw_profile "$HOME/no-interface.conf" "# [Interface]\nPrivateKey = K=\n$peer"
  write_raw_profile "$HOME/unreadable.conf" "[Interface]\nPrivateKey = K=\n$peer"

  local caller name
  for caller in default pipe_fail sh; do
    validate_profiles_as "$caller" no-peer no-interface
    printf '%s:\n%s\n' "$caller" "$output"
    [ "$status" -eq 0 ]
    [ "$output" = $'no-peer rc=1\nno-interface rc=1' ]
    for name in no-peer no-interface; do
      grep -Fq 'must contain an [Interface] and a [Peer] section' "$HOME/$name.err"
    done
  done

  # The bounded read itself fails.
  cat > "$TEST_MOCK_BIN/head" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod 755 "$TEST_MOCK_BIN/head"
  validate_profiles_as default unreadable
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "unreadable rc=1" ]
  grep -Fq "Could not read $HOME/unreadable.conf." "$HOME/unreadable.err"
}

@test "vpn hardening: a profile with several [Peer] sections passes under any caller options" {
  write_raw_profile "$HOME/two-peers.conf" \
    '[Interface]\nPrivateKey = K=\nAddress = 10.0.0.2/24\n\n[Peer]\nPublicKey = P1=\nAllowedIPs = 10.1.0.0/16\n\n[Peer]\nPublicKey = P2=\nAllowedIPs = 10.2.0.0/16\n'
  write_raw_profile "$HOME/two-peers-crlf.conf" \
    '[Interface]\r\nPrivateKey = K=\r\n\r\n[peer]\r\nPublicKey = P1=\r\n\r\n[Peer] # second peer\r\nPublicKey = P2=\r\n'

  local caller
  for caller in default pipe_fail sh; do
    validate_profiles_as "$caller" two-peers two-peers-crlf
    printf '%s:\n%s\n' "$caller" "$output"
    [ "$status" -eq 0 ]
    [ "$output" = $'two-peers rc=0\ntwo-peers-crlf rc=0' ]
    [ ! -s "$HOME/two-peers.err" ]
    [ ! -s "$HOME/two-peers-crlf.err" ]
  done
}

@test "vpn hardening: an inherited PIPE_FAIL cannot import a padded hook profile" {
  write_padded_hook_profile "$HOME/hooked.conf"
  export MOCK_SUDO_ALLOW="$IMPORT_SUDO_ALLOW"
  : > "$MOCK_SUDO_LOG"

  # The name prompt is answered, so validation is the step that decides.
  run run_zsh '
    setopt pipe_fail
    _vpn_read_line() { print -r -- "$2"; }
    vpn-profile-import "$HOME/hooked.conf"
  '

  printf '%s\n' "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not contain PreUp/PostUp/PreDown/PostDown hooks"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ -z "$(find "$VPN_PROFILE_DIR" -mindepth 1 -print -quit)" ]
}

@test "vpn hardening: profile import rejects a symlink source" {
  write_profile_file "$HOME/source-target.conf"
  ln -s "$HOME/source-target.conf" "$HOME/source-link.conf"
  : > "$MOCK_SUDO_LOG"

  run run_zsh 'vpn-profile-import "$HOME/source-link.conf"'

  [ "$status" -eq 1 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: profile import rejects a multiply linked source" {
  write_profile_file "$HOME/source-original.conf"
  ln "$HOME/source-original.conf" "$HOME/source-hardlink.conf"
  : > "$MOCK_SUDO_LOG"

  run run_zsh 'vpn-profile-import "$HOME/source-hardlink.conf"'

  [ "$status" -eq 1 ]
  [ "$(file_links "$HOME/source-original.conf")" -eq 2 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn hardening: profile import rejects a source larger than one MiB" {
  local oversized="$HOME/source-oversized.conf"
  write_profile_file "$oversized"
  make_sized_file "$oversized" 1048577
  chmod 600 "$oversized"
  : > "$MOCK_SUDO_LOG"

  run run_zsh 'vpn-profile-import "$HOME/source-oversized.conf"'

  [ "$status" -eq 1 ]
  [ "$(file_size "$oversized")" -gt 1048576 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

# --- Installed profile identity and privacy --------------------------------

@test "vpn hardening: inventory and existence reject unsafe profile files" {
  write_profile_file "$VPN_PROFILE_DIR/safe.conf"

  write_profile_file "$HOME/symlink-target.conf"
  ln -s "$HOME/symlink-target.conf" "$VPN_PROFILE_DIR/symlinked.conf"

  write_profile_file "$VPN_PROFILE_DIR/hardlinked.conf"
  ln "$VPN_PROFILE_DIR/hardlinked.conf" "$HOME/hardlink-peer.conf"

  write_profile_file "$VPN_PROFILE_DIR/public.conf"
  chmod 644 "$VPN_PROFILE_DIR/public.conf"

  run run_zsh '
    local inventory
    inventory=$(_vpn_get_configs 2>/dev/null)

    [[ "$inventory" == "safe" ]] || return 10

    _vpn_config_exists safe || return 11
    _vpn_config_exists symlinked && return 12
    _vpn_config_exists hardlinked && return 13
    _vpn_config_exists public && return 14
    return 0
  '

  [ "$status" -eq 0 ]
}

# --- DNS parser --------------------------------------------------------------

@test "vpn hardening: DNS validation enforces numeric IPv4 and structural IPv6" {
  run run_zsh '
    local candidate
    for candidate in \
      256.0.0.1 \
      1.2.3.999 \
      :::: \
      2001:db8:::1 \
      1:2:3:4:5:6:7:8:9 \
      2001:db8:1; do
      _vpn_validate_dns_list "$candidate" && return 10
    done

    for candidate in \
      0.0.0.0 \
      255.255.255.255 \
      ::1 \
      2001:db8::1 \
      2001:db8:0:1:1:1:1:1; do
      _vpn_validate_dns_list "$candidate" || return 20
    done
    _vpn_validate_dns_list "1.1.1.1, 2001:4860:4860::8888"
  '

  [ "$status" -eq 0 ]
}

# --- Picker records ----------------------------------------------------------

@test "vpn hardening: ambiguous picker output is rejected" {
  run run_zsh '
    _vpn_sanitize_iface_capture $'"'"'wg0\nwg1'"'"' && return 10
    _vpn_sanitize_iface_capture $'"'"'wg0\nwg0'"'"' && return 11
    _vpn_sanitize_iface_capture $'"'"'invalid/name\nwg0'"'"' && return 12
    [[ "$(_vpn_sanitize_iface_capture $'"'"'\n wg0 \n'"'"')" == "wg0" ]]
  '

  [ "$status" -eq 0 ]
}

# --- Cache persistence -------------------------------------------------------

@test "vpn hardening: cache rejects a symlink in any directory component" {
  mkdir -p "$HOME/cache-real"
  chmod 700 "$HOME/cache-real"
  ln -s "$HOME/cache-real" "$HOME/cache-link"

  run run_zsh '
    VPN_CACHE_DIR="$HOME/cache-link/vpn"
    _vpn_set_default_iface wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink"* ]]
  [ -z "$(find "$HOME/cache-real" -mindepth 1 -print -quit)" ]
}

@test "vpn hardening: cache rejects a multiply linked entry without modifying it" {
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  printf '%s\n' old-profile > "$HOME/cache-anchor"
  chmod 600 "$HOME/cache-anchor"
  ln "$HOME/cache-anchor" "$VPN_CACHE_DIR/default-iface"
  local before
  before=$(file_stat "$HOME/cache-anchor" device inode nlink mode)

  run run_zsh '
    _vpn_peek_default_iface >/dev/null && return 10
    _vpn_set_default_iface wg0
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/cache-anchor")" = "old-profile" ]
  [ "$(file_stat "$HOME/cache-anchor" device inode nlink mode)" = "$before" ]
}

@test "vpn hardening: cache rejects a public entry without repairing it in place" {
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  printf '%s\n' old-profile > "$VPN_CACHE_DIR/default-iface"
  chmod 644 "$VPN_CACHE_DIR/default-iface"
  local before
  before=$(file_stat "$VPN_CACHE_DIR/default-iface" device inode mode)

  run run_zsh '
    _vpn_peek_default_iface >/dev/null && return 10
    _vpn_set_default_iface wg0
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = "old-profile" ]
  [ "$(file_stat "$VPN_CACHE_DIR/default-iface" device inode mode)" = "$before" ]
}

@test "vpn hardening: cache updates use private atomic replacement" {
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  printf '%s\n' old-profile > "$VPN_CACHE_DIR/default-iface"
  chmod 600 "$VPN_CACHE_DIR/default-iface"
  local before_inode
  before_inode=$(file_identity "$VPN_CACHE_DIR/default-iface")

  run run_zsh '_vpn_set_default_iface wg0'

  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = "wg0" ]
  [ "$(file_mode "$VPN_CACHE_DIR/default-iface")" = "600" ]
  [ "$(file_identity "$VPN_CACHE_DIR/default-iface")" != "$before_inode" ]
  [ "$(find "$VPN_CACHE_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 ]
}

@test "vpn hardening: a failed cache publication preserves the old entry" {
  mkdir -p "$VPN_CACHE_DIR"
  chmod 700 "$VPN_CACHE_DIR"
  printf '%s\n' old-profile > "$VPN_CACHE_DIR/default-iface"
  chmod 600 "$VPN_CACHE_DIR/default-iface"
  local before
  before=$(file_stat "$VPN_CACHE_DIR/default-iface" device inode mode)

  cat > "$TEST_MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
exit 73
EOF
  chmod +x "$TEST_MOCK_BIN/mv"

  run run_zsh '_vpn_set_default_iface wg0'

  [ "$status" -eq 1 ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = "old-profile" ]
  [ "$(file_stat "$VPN_CACHE_DIR/default-iface" device inode mode)" = "$before" ]
  [ "$(find "$VPN_CACHE_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 ]
}

# --- Report publication ------------------------------------------------------

@test "vpn hardening: same-second reports publish unique private files" {
  install_fixed_date_mock

  run run_zsh '
    _vpn_check_wg_quick() { return 0; }
    _vpn_check_ip_stack() { return 0; }
    _vpn_have_sudo_cache() { return 1; }
    _vpn_should_apply_wsl_ipv6_fix() { return 1; }
    _vpn_configs_access_state() { print -r -- direct; }
    _vpn_wg_access_state() { print -r -- direct; }
    _vpn_dns_resolvers() { return 1; }
    _vpn_get_active_interfaces() { return 0; }
    _vpn_get_ip_info() { return 1; }
    _vpn_get_ip_crosscheck() { return 1; }

    vpn-report || return 10
    vpn-report || return 11
  '

  [ "$status" -eq 0 ]
  [ "$(find "$VPN_MENU_REPORT_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 2 ]
  local report_file
  while IFS= read -r report_file; do
    [ "$(file_mode "$report_file")" = "600" ]
    grep -q '^# VPN Diagnostic Report' "$report_file"
  done < <(find "$VPN_MENU_REPORT_DIR" -mindepth 1 -maxdepth 1 -type f)
}

@test "vpn hardening: report retention keeps the newest reports and skips unsafe entries" {
  mkdir -p "$VPN_MENU_REPORT_DIR"
  chmod 700 "$VPN_MENU_REPORT_DIR"
  local index
  for index in 1 2 3 4 5; do
    printf 'old %s\n' "$index" \
      > "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-0${index}_000000-host.md"
    chmod 600 "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-0${index}_000000-host.md"
  done
  printf 'unsafe\n' \
    > "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000001-host.md"
  chmod 644 "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000001-host.md"
  printf 'published\n' \
    > "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_000000-host.md"
  chmod 600 "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_000000-host.md"

  run run_zsh '
    export VPN_MENU_REPORT_RETENTION=3
    _vpn_report_prune \
      "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_000000-host.md" \
      vpn-report md
  '

  [ "$status" -eq 0 ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-02-01_000000-host.md" ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-04_000000-host.md" ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-05_000000-host.md" ]
  [ ! -e "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000000-host.md" ]
  [ ! -e "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-02_000000-host.md" ]
  [ ! -e "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-03_000000-host.md" ]
  [ -f "$VPN_MENU_REPORT_DIR/vpn-report-2026-01-01_000001-host.md" ]
}

@test "vpn hardening: invalid report retention fails closed before any report work" {
  run run_zsh '
    export VPN_MENU_REPORT_RETENTION=many
    _vpn_report_temp_create() {
      print -r -- unexpected-report-staging
      return 1
    }
    vpn-report
  '

  [ "$status" -eq 2 ]
  [[ "$output" == *"must be an integer from 0 through 1000"* ]]
  [[ "$output" != *"unexpected-report-staging"* ]]
}

@test "vpn hardening: pre-restore undo copies are visible in the inventory" {
  write_profile_file "$VPN_PROFILE_DIR/wg0.conf"
  write_profile_file "$VPN_PROFILE_DIR/wg1.conf"
  write_profile_file "$VPN_PROFILE_DIR/wg0.conf.pre-restore"

  run run_zsh 'vpn-config-dir'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Pre-restore copy"* ]]
  grep -Eq '^  wg0\.conf +[a-z]+ +kept$' <<<"$output"
  grep -Eq '^  wg1\.conf +[a-z]+$' <<<"$output"
  [ "$(grep -c 'kept' <<<"$output")" -eq 1 ]
}

@test "vpn hardening: report failure clears its target and removes staged output" {
  install_fixed_date_mock

  run run_zsh '
    _vpn_check_wg_quick() { return 0; }
    _vpn_check_ip_stack() { return 0; }
    _vpn_have_sudo_cache() { return 1; }
    _vpn_rpt_h1() { return 73; }

    local -i report_status=0
    vpn-report || report_status=$?
    (( report_status != 0 )) || return 10
    [[ -z "$_VPN_REPORT_TARGET" ]] || return 11
    [[ -z "$(command find "$VPN_MENU_REPORT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]
  '

  [ "$status" -eq 0 ]
}

# --- Broad disconnect plan ---------------------------------------------------

@test "vpn hardening: vpn-off-all dry-run performs zero sudo calls" {
  cat > "$TEST_MOCK_BIN/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "show interfaces" ]]; then
  printf '%s\n' 'wg0 wg1'
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/wg"
  : > "$MOCK_SUDO_LOG"

  run run_zsh 'vpn-off-all --dry-run'

  [ "$status" -eq 0 ]
  grep -Eq '^  1  wg0 ' <<<"$output"
  grep -Eq '^  2  wg1 ' <<<"$output"
  [[ "$output" == *"Dry run: 2 tunnels planned; nothing was disconnected."* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}
