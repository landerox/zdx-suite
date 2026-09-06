#!/usr/bin/env bats

setup() {
  load test_helper

  # A sandbox profile directory inside $HOME keeps every read unprivileged, so
  # any sudo call a test records is one the production code genuinely made.
  export VPN_PROFILE_DIR="$HOME/wireguard"
  mkdir -p "$VPN_PROFILE_DIR"
  chmod 700 "$VPN_PROFILE_DIR"

  export VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"
}

teardown() {
  cleanup_sandbox
}

# Writes a syntactically valid WireGuard profile with a caller-chosen DNS line.
write_profile() {
  local name="$1"
  local dns_line="${2-}"

  {
    printf '[Interface]\n'
    printf 'PrivateKey = SUPERSECRETPRIVATEKEY=\n'
    printf 'Address = 10.0.0.2/24\n'
    [[ -n "$dns_line" ]] && printf 'DNS = %s\n' "$dns_line"
    printf '\n[Peer]\n'
    printf 'PublicKey = PEERKEY=\n'
    printf 'PresharedKey = SUPERSECRETPRESHAREDKEY=\n'
    printf 'AllowedIPs = 0.0.0.0/0\n'
    printf 'Endpoint = 203.0.113.7:51820\n'
  } > "$VPN_PROFILE_DIR/${name}.conf"
  chmod 600 "$VPN_PROFILE_DIR/${name}.conf"
}

# --- WSL DNS hook injection -------------------------------------------------

@test "vpn privilege: a DNS value with shell metacharacters is refused" {
  write_profile "wg0" "1.1.1.1'; touch $HOME/pwned; '"

  export MOCK_SUDO_WRITE_ETC_RESOLV_CONF=1
  export MOCK_SUDO_ALLOW='true,test'
  export MOCK_LSATTR_ETC_RESOLV_CONF='--------- /etc/resolv.conf'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_apply_wsl_dns_hooks "$VPN_PROFILE_DIR/wg0.conf"
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"not a plain list of IP addresses"* ]]
  [[ "$output" == *"root-executed hook"* ]]

  # The refusal happens before anything is written or executed.
  [ ! -e "$HOME/pwned" ]
  ! grep -q 'PostUp' "$VPN_PROFILE_DIR/wg0.conf"
  grep -q "touch" "$VPN_PROFILE_DIR/wg0.conf"
}

@test "vpn privilege: a command-substitution DNS value is refused" {
  write_profile "wg0" '$(id > '"$HOME"'/pwned)'

  export MOCK_SUDO_WRITE_ETC_RESOLV_CONF=1
  export MOCK_SUDO_ALLOW='true,test'
  export MOCK_LSATTR_ETC_RESOLV_CONF='--------- /etc/resolv.conf'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_apply_wsl_dns_hooks "$VPN_PROFILE_DIR/wg0.conf"
  '

  [ "$status" -eq 1 ]
  [ ! -e "$HOME/pwned" ]
  ! grep -q 'PostUp' "$VPN_PROFILE_DIR/wg0.conf"
}

@test "vpn privilege: DNS validation accepts only IP literals" {
  run run_zsh '
    _vpn_validate_dns_list "1.1.1.1"                 || return 1
    _vpn_validate_dns_list "1.1.1.1, 9.9.9.9"        || return 2
    _vpn_validate_dns_list "fd00::1"                 || return 3
    _vpn_validate_dns_list "1.1.1.1;id"              && return 4
    _vpn_validate_dns_list "\$(id)"                  && return 5
    _vpn_validate_dns_list "1.1.1.1 \`id\`"          && return 6
    _vpn_validate_dns_list "example.com"             && return 7
    _vpn_validate_dns_list ""                        && return 8
    return 0
  '
  [ "$status" -eq 0 ]
}

@test "vpn privilege: a plain IP DNS list hardens the profile idempotently" {
  write_profile "wg0" "8.8.8.8, 8.8.4.4"

  export MOCK_SUDO_WRITE_ETC_RESOLV_CONF=1
  export MOCK_SUDO_ALLOW='true,test,install,mktemp,mv,rm,__validate__'
  export MOCK_LSATTR_ETC_RESOLV_CONF='--------- /etc/resolv.conf'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_apply_wsl_dns_hooks "$VPN_PROFILE_DIR/wg0.conf" || return 1
    _vpn_apply_wsl_dns_hooks "$VPN_PROFILE_DIR/wg0.conf" || return 2
    return 0
  '

  [ "$status" -eq 0 ]

  local conf="$VPN_PROFILE_DIR/wg0.conf"
  grep -q 'zdx: wsl-dns-hooks v1' "$conf"
  grep -q 'nameserver 8.8.8.8' "$conf"
  ! grep -qE '^[[:space:]]*DNS[[:space:]]*=' "$conf"
  [ "$(grep -c 'PostUp =' "$conf")" -eq 1 ]
  [ "$(grep -c 'PostDown =' "$conf")" -eq 1 ]
}

# --- Editing without a root editor ------------------------------------------

@test "vpn privilege: vpn-config-edit uses sudoedit, never a root editor" {
  write_profile "wg0"

  cat > "$TEST_MOCK_BIN/sudoedit" <<'EOF'
#!/usr/bin/env bash
printf 'sudoedit'; printf ' %q' "$@"; printf '\n' >> /dev/stdout
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/sudoedit"

  export MOCK_SUDO_ALLOW='true'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    export EDITOR="definitely-not-a-real-editor"
    _VPN_AUTO_YES=1
    vpn-config-edit wg0
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"sudoedit"* ]]
  [[ "$output" == *"wg0.conf"* ]]
  [[ "$output" == *"runs as your own user"* ]]

  # The editor must never be handed to sudo, and sudo must not be asked to run
  # it either.
  [[ "$output" != *"definitely-not-a-real-editor"* ]]
  ! grep -q 'definitely-not-a-real-editor' "$MOCK_SUDO_LOG"
}

@test "vpn privilege: a failing sudoedit reports failure and changes nothing" {
  write_profile "wg0"
  local before
  before=$(cat "$VPN_PROFILE_DIR/wg0.conf")

  cat > "$TEST_MOCK_BIN/sudoedit" <<'EOF'
#!/usr/bin/env bash
echo "sudoedit: not permitted" >&2
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/sudoedit"

  export MOCK_SUDO_ALLOW='true'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _VPN_AUTO_YES=1
    vpn-config-edit wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"sudoedit exited with status 1"* ]]
  [ "$(cat "$VPN_PROFILE_DIR/wg0.conf")" = "$before" ]
}

# --- Revalidation after authentication --------------------------------------

@test "vpn privilege: bringing a tunnel up aborts if the profile vanished" {
  write_profile "wg0"
  export MOCK_SUDO_ALLOW='true,__validate__,wg-quick'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    # Model the profile disappearing while the sudo prompt was open.
    _vpn_ensure_sudo_access() {
      command rm -f -- "$VPN_PROFILE_DIR/wg0.conf"
      return 0
    }
    _vpn_tunnel_up wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"disappeared or became unsafe after authentication"* ]]
  # wg-quick must never have run.
  ! grep -q 'wg-quick' "$MOCK_SUDO_LOG"
}

@test "vpn privilege: restore aborts if the backup vanished after authentication" {
  write_profile "wg0"
  cp "$VPN_PROFILE_DIR/wg0.conf" "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"

  export MOCK_SUDO_ALLOW='true,__validate__,test,install,mktemp,ln,rm,mv'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_ensure_sudo_access() {
      command rm -f -- "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"
      return 0
    }
    _vpn_restore_backup wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"disappeared or became unsafe after authentication"* ]]
  ! grep -q 'install' "$MOCK_SUDO_LOG"
}

@test "vpn privilege: restore keeps the previous profile as an undo copy" {
  write_profile "wg0" "1.1.1.1"
  printf '[Interface]\nAddress = 10.9.9.9/24\n\n[Peer]\nPublicKey = OLD=\n' \
    > "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"
  chmod 600 "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"

  export MOCK_SUDO_ALLOW='true,__validate__,test,install,mktemp,ln,rm,mv'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_restore_backup wg0
  '

  [ "$status" -eq 0 ]
  grep -q '10.9.9.9' "$VPN_PROFILE_DIR/wg0.conf"
  [ -f "$VPN_PROFILE_DIR/wg0.conf.pre-restore" ]
  grep -q '10.0.0.2' "$VPN_PROFILE_DIR/wg0.conf.pre-restore"
  # The undo copy must not become a listed profile.
  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_get_configs
  '
  [ "$output" = "wg0" ]
}

# --- Least privilege --------------------------------------------------------

@test "vpn privilege: reading readable profiles requests no privilege at all" {
  write_profile "alpha"
  write_profile "bravo"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_get_configs >/dev/null
    _vpn_backup_state alpha >/dev/null
    _vpn_redacted_config_excerpt alpha >/dev/null
    _vpn_configs_access_state >/dev/null
  '

  [ "$status" -eq 0 ]
  # Not even a cache probe: every read resolved directly.
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn privilege: a successful connect elevates only the final wg-quick" {
  write_profile "wg0"
  export MOCK_SUDO_ALLOW='true,__validate__,wg-quick'
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    unset WSL_DISTRO_NAME
    unset VPN_MENU_WSL_IPV6_FIX
    vpn-details() { return 0; }
    _vpn_tunnel_up wg0
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Privileged operation: wg-quick up $VPN_PROFILE_DIR/wg0.conf"* ]]

  # Exactly one privileged payload, and it is the tunnel transition.
  local payloads
  payloads=$(grep -c 'wg-quick' "$MOCK_SUDO_LOG")
  [ "$payloads" -eq 1 ]
  grep -Fq "sudo -n -- wg-quick up $VPN_PROFILE_DIR/wg0.conf" "$MOCK_SUDO_LOG"
  # No editor, shell, or file utility was ever elevated.
  ! grep -qE 'sudo -n -- (sh|bash|zsh|cat|sed|find|cp|install|rm) ' \
    "$MOCK_SUDO_LOG"
}

@test "vpn privilege: the announcement precedes the credential request" {
  write_profile "wg0"

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_ensure_sudo_access() { print -u2 -r -- "CREDENTIALS REQUESTED"; return 1; }
    _vpn_tunnel_up wg0
  '

  [ "$status" -eq 1 ]
  local announce_line credential_line
  announce_line=$(printf '%s\n' "$output" | grep -n 'Privileged operation' | cut -d: -f1)
  credential_line=$(printf '%s\n' "$output" | grep -n 'CREDENTIALS REQUESTED' | cut -d: -f1)
  [ -n "$announce_line" ]
  [ -n "$credential_line" ]
  [ "$announce_line" -lt "$credential_line" ]
}

# --- Destructive controls ---------------------------------------------------

@test "vpn privilege: vpn-off-all fails closed without a terminal and --yes" {
  export MOCK_SUDO_ALLOW='true,__validate__,wg-quick'
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    _vpn_get_active_interfaces() { print -rl -- wg0 wg1; }
    vpn-off-all
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"pass --yes to disconnect all"* ]]
  ! grep -q 'wg-quick' "$MOCK_SUDO_LOG"
}

@test "vpn privilege: a declined confirmation disconnects nothing and returns 0" {
  export MOCK_SUDO_ALLOW='true,__validate__,wg-quick'
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    _vpn_get_active_interfaces() { print -rl -- wg0 wg1; }
    _vpn_confirm() { return 1; }
    vpn-off-all
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled. No interface was disconnected."* ]]
  ! grep -q 'wg-quick' "$MOCK_SUDO_LOG"
}

@test "vpn privilege: --yes bypasses only the prompt and reports the plan" {
  write_profile wg0
  write_profile wg1
  export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
  export MOCK_SUDO_ALLOW='true,__validate__,wg-quick'
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    _vpn_get_active_interfaces() { print -rl -- wg0 wg1; }
    vpn-details() { return 0; }
    vpn-off-all --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Plan: bring down 2 interface(s): wg0 wg1"* ]]
  [ "$(grep -c 'sudo -n -- wg-quick down' "$MOCK_SUDO_LOG")" -eq 2 ]
}

@test "vpn privilege: vpn-off-all reports a partial failure non-zero" {
  write_profile wg0
  write_profile wg1
  export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
  export MOCK_SUDO_ALLOW='true,__validate__,wg-quick'

  cat > "$TEST_MOCK_BIN/wg-quick" <<'EOF'
#!/usr/bin/env bash
# The second interface refuses to come down.
if [[ "$*" == *wg1* ]]; then
  echo "wg-quick: wg1 is busy" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/wg-quick"

  run run_zsh '
    _vpn_get_active_interfaces() { print -rl -- wg0 wg1; }
    vpn-details() { return 0; }
    vpn-off-all --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2 interface(s) failed to disconnect"* ]]
}

@test "vpn privilege: vpn-profile-remove --dry-run removes nothing" {
  write_profile "wg0"
  cp "$VPN_PROFILE_DIR/wg0.conf" "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    vpn-profile-remove wg0 --dry-run
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"Plan: delete"* ]]
  [ -f "$VPN_PROFILE_DIR/wg0.conf" ]
  [ -f "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu" ]
  # A cache probe may be recorded; no privileged payload may be.
  ! grep -qE 'sudo -n -- (rm|mv|install|cp) ' "$MOCK_SUDO_LOG"
}

# --yes must not answer the backup question on the user's behalf: that would
# widen the target set rather than merely skip a prompt.
@test "vpn privilege: vpn-profile-remove keeps the backup unless asked" {
  write_profile "wg0"
  cp "$VPN_PROFILE_DIR/wg0.conf" "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"
  export MOCK_SUDO_ALLOW='true,__validate__,test,rm'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_get_active_interfaces() { return 1; }
    _vpn_wg_access_state() { print -r -- "missing"; }
    vpn-profile-remove wg0 --yes
  '

  [ "$status" -eq 0 ]
  [ ! -f "$VPN_PROFILE_DIR/wg0.conf" ]
  [ -f "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu" ]
}

@test "vpn privilege: --with-backup removes both files" {
  write_profile "wg0"
  cp "$VPN_PROFILE_DIR/wg0.conf" "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"
  export MOCK_SUDO_ALLOW='true,__validate__,test,rm'

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_get_active_interfaces() { return 1; }
    _vpn_wg_access_state() { print -r -- "missing"; }
    vpn-profile-remove wg0 --with-backup --yes
  '

  [ "$status" -eq 0 ]
  [ ! -f "$VPN_PROFILE_DIR/wg0.conf" ]
  [ ! -f "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu" ]
}

@test "vpn privilege: vpn-config-restore --dry-run shows the plan only" {
  write_profile "wg0" "1.1.1.1"
  printf '[Interface]\nAddress = 10.9.9.9/24\n\n[Peer]\nPublicKey = OLD=\n' \
    > "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"
  chmod 600 "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"
  : > "$MOCK_SUDO_LOG"

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    vpn-config-restore wg0 --dry-run
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"Plan: replace"* ]]
  grep -q '10.0.0.2' "$VPN_PROFILE_DIR/wg0.conf"
  [ ! -e "$VPN_PROFILE_DIR/wg0.conf.pre-restore" ]
  ! grep -qE 'sudo -n -- (rm|mv|install|cp) ' "$MOCK_SUDO_LOG"
}

# --- Secret handling --------------------------------------------------------

@test "vpn privilege: excerpts never expose private or preshared keys" {
  write_profile "wg0" "1.1.1.1"
  cp "$VPN_PROFILE_DIR/wg0.conf" "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu"

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_redacted_config_excerpt wg0
    _vpn_redacted_backup_excerpt wg0
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"SUPERSECRETPRIVATEKEY"* ]]
  [[ "$output" != *"SUPERSECRETPRESHAREDKEY"* ]]
  # Non-secret context still survives.
  [[ "$output" == *"Endpoint = 203.0.113.7:51820"* ]]
}

@test "vpn privilege: a preview pane never exposes profile secrets" {
  write_profile "wg0" "1.1.1.1"

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_state_load
    local rows
    rows=$(_vpn_menu_rows) || return 1
    _vpn_preview_build "${(@f)rows}" || return 1
    command cat -- "$_VPN_PREVIEW_DIR"/*
    _vpn_preview_dir_cleanup
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"SUPERSECRETPRIVATEKEY"* ]]
  [[ "$output" != *"SUPERSECRETPRESHAREDKEY"* ]]
  # The pane still shows the profile and its state.
  [[ "$output" == *"Profile: wg0"* ]]
}

# --- Persisted state --------------------------------------------------------

@test "vpn privilege: the cache directory and its entries are owner-only" {
  write_profile "wg0"

  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_set_default_iface wg0 || return 1
    _vpn_remember_iface wg0 || return 1
  '

  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$VPN_CACHE_DIR")" = "700" ]
  [ "$(stat -c '%a' "$VPN_CACHE_DIR/default-iface")" = "600" ]
  [ "$(stat -c '%a' "$VPN_CACHE_DIR/last-iface")" = "600" ]
}

@test "vpn privilege: a traversal cache override is refused" {
  run run_zsh '
    export VPN_CACHE_DIR="../../escape"
    _vpn_cache_dir
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *".."* ]]
  [ ! -d "$HOME/../../escape" ]
}

@test "vpn privilege: a cache directory outside the home is refused" {
  run run_zsh '
    export VPN_CACHE_DIR="/tmp/zdx-vpn-should-not-exist"
    _vpn_cache_dir
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"inside your home"* ]]
  [ ! -d "/tmp/zdx-vpn-should-not-exist" ]
}

@test "vpn privilege: a symlinked cache directory is refused" {
  mkdir -p "$HOME/elsewhere"
  mkdir -p "$(dirname "$VPN_CACHE_DIR")"
  ln -s "$HOME/elsewhere" "$VPN_CACHE_DIR"

  run run_zsh '_vpn_cache_dir'

  [ "$status" -eq 1 ]
  [[ "$output" == *"symlinked"* ]]
  [ -z "$(ls -A "$HOME/elsewhere")" ]
}

@test "vpn privilege: the report directory is owner-only" {
  run run_zsh '_vpn_report_root'

  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$VPN_MENU_REPORT_DIR")" = "700" ]
}

@test "vpn privilege: a report directory outside the home is refused" {
  run run_zsh '
    export VPN_MENU_REPORT_DIR="/tmp/zdx-vpn-report-escape"
    _vpn_report_path
  '

  [ "$status" -eq 1 ]
  [ ! -d "/tmp/zdx-vpn-report-escape" ]
}

@test "vpn privilege: a stale pointer is visible but not treated as existing" {
  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    # Record a profile, then delete it behind the pointer.
    print -r -- "ghost" > "$(_vpn_cache_file default-iface)"
    command chmod 600 -- "$(_vpn_cache_file default-iface)"

    _vpn_read_default_iface >/dev/null && return 1
    local peeked
    peeked=$(_vpn_peek_default_iface) || return 2
    [[ "$peeked" == "ghost" ]] || return 3
    print -r -- OK
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "vpn privilege: cache entry names are an internal allowlist" {
  run run_zsh '_vpn_cache_file "../../etc/passwd"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown VPN cache entry"* ]]

  run run_zsh '_vpn_write_cached_iface "arbitrary-name" "wg0"'
  [ "$status" -eq 1 ]
}

# --- Platform contract ------------------------------------------------------

@test "vpn privilege: an unsupported host is refused with an override hint" {
  cat > "$TEST_MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then
  echo "Darwin"
  exit 0
fi
exec /usr/bin/uname "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/uname"

  run run_zsh '
    unset WSL_DISTRO_NAME
    # VPN_CONFIG_DIR keeps its Linux default; unsetting it would read as an
    # override and defeat the gate under test.
    [[ "$VPN_CONFIG_DIR" == "/etc/wireguard" ]] || return 9
    _vpn_require_platform
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"targets Linux and WSL"* ]]
  [[ "$output" == *"VPN_CONFIG_DIR"* ]]

  rm -f "$TEST_MOCK_BIN/uname"
}

@test "vpn privilege: an explicit VPN_CONFIG_DIR override proceeds" {
  cat > "$TEST_MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then
  echo "Darwin"
  exit 0
fi
exec /usr/bin/uname "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/uname"

  run run_zsh '
    unset WSL_DISTRO_NAME
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_require_platform
  '

  [ "$status" -eq 0 ]

  rm -f "$TEST_MOCK_BIN/uname"
}

@test "vpn privilege: a profile-reading command reports the platform refusal" {
  cat > "$TEST_MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then
  echo "FreeBSD"
  exit 0
fi
exec /usr/bin/uname "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/uname"

  run run_zsh '
    unset WSL_DISTRO_NAME
    [[ "$VPN_CONFIG_DIR" == "/etc/wireguard" ]] || return 9
    vpn-config-dir
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"targets Linux and WSL"* ]]

  rm -f "$TEST_MOCK_BIN/uname"
}
