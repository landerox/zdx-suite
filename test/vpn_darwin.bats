#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  vpn_darwin_fixture
  export TERM=dumb NO_COLOR=1
  export VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"
  export VPN_PROFILE_DIR="$HOME/wireguard"
  unset WSL_DISTRO_NAME VPN_MENU_WSL_IPV6_FIX VPN_CONFIG_DIR
  : > "$MOCK_SUDO_LOG"
}

teardown() {
  cleanup_sandbox
}

# One active tunnel, wg0 on utun5, paired by times one second apart.
darwin_one_tunnel() {
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg0
  vpn_darwin_record wg0 utun5 1700000000
  vpn_darwin_socket utun5 1700000001
  export VPN_WG_DEVICES="utun5"
}

# --- Profile directory ------------------------------------------------------

@test "vpn darwin: the default directory prefers the system path, then Homebrew profiles" {
  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    [[ "$VPN_CONFIG_DIR" == /etc/wireguard ]] || return 9
    local system_dir="$HOME/private/etc/wireguard"
    local brew_dir="$VPN_BREW/etc/wireguard"

    # Neither exists: the system path, which profile creation makes private.
    [[ "$(_vpn_config_dir)" == "$system_dir" ]] || return 10

    # An empty Homebrew directory is not a profile directory.
    command mkdir -m 700 -- "$brew_dir" || return 11
    [[ "$(_vpn_config_dir)" == "$system_dir" ]] || return 12

    # A Homebrew directory that already holds profiles is used.
    print -r -- "[Interface]" > "$brew_dir/home.conf"
    [[ "$(_vpn_config_dir)" == "$brew_dir" ]] || return 13

    # An existing system directory always wins.
    command mkdir -p -- "$system_dir" || return 14
    [[ "$(_vpn_config_dir)" == "$system_dir" ]] || return 15

    # An explicit setting is never second-guessed.
    VPN_CONFIG_DIR="$HOME/explicit"
    [[ "$(_vpn_config_dir)" == "$HOME/explicit" ]] || return 16
  '

  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn darwin: only a root-owned system alias may stand in the profile path" {
  # macOS reaches /etc through /etc -> private/etc. Use the first root-owned
  # alias at the root of this host, such as /etc on macOS or /bin on a
  # merged-/usr Linux.
  local alias="" candidate
  for candidate in /etc /bin /sbin /lib /var; do
    if [[ -L "$candidate" && -d "$candidate" && "$(file_owner_uid "$candidate")" == 0 ]]; then
      alias="$candidate"
      break
    fi
  done
  [ -n "$alias" ] || skip "this host has no root-owned top-level alias"

  mkdir -p "$HOME/real-profiles"
  chmod 700 "$HOME/real-profiles"
  ln -s real-profiles "$HOME/linked-profiles"
  export VPN_ALIAS="$alias"

  run run_zsh '
    VPN_CONFIG_DIR="$VPN_ALIAS"
    [[ "$(_vpn_config_dir_resolve)" == "${VPN_ALIAS:A}" ]] || return 10
    [[ "$(_vpn_config_dir_resolve)" != "$VPN_ALIAS" ]] || return 11

    VPN_CONFIG_DIR="$HOME/linked-profiles"
    _vpn_config_dir_resolve
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"symlink components"* ]]
}

# --- Profile-to-device mapping ----------------------------------------------

@test "vpn darwin: an unambiguous pairing maps profiles to devices without privilege" {
  darwin_one_tunnel
  # A stale record whose device is gone stays inactive.
  vpn_darwin_record old utun3 1690000000
  export MOCK_SUDO_ALLOW=""

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    local -a reply=()
    _vpn_active_interfaces || return 10
    print -r -- "profiles=${(j:,:)reply}"
    print -r -- "device=${_VPN_ACTIVE_DEVICES[wg0]}"
    print -r -- "unmanaged=${(j:,:)_VPN_UNMANAGED_DEVICES}"
    print -r -- "access=$(_vpn_wg_access_state)"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"profiles=wg0"* ]]
  [[ "$output" == *"device=utun5"* ]]
  [[ "$output" == *"unmanaged="$'\n'* ]]
  [[ "$output" == *"access=direct"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn darwin: an ambiguous pairing reads the recorded device through sudo" {
  vpn_darwin_record wg0 utun5 1700000000
  vpn_darwin_record wg1 utun6 1700000000
  vpn_darwin_socket utun5 1700000000
  vpn_darwin_socket utun6 1700000001
  export VPN_WG_DEVICES="utun5 utun6"
  export MOCK_SUDO_ALLOW="true,head"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    local -a reply=()
    _vpn_active_interfaces || return 10
    print -r -- "pairs=wg0:${_VPN_ACTIVE_DEVICES[wg0]},wg1:${_VPN_ACTIVE_DEVICES[wg1]}"
    print -r -- "access=$(_vpn_wg_access_state)"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"pairs=wg0:utun5,wg1:utun6"* ]]
  [[ "$output" == *"access=sudo"* ]]
  grep -Fq "sudo -n -- /usr/bin/head -c 32 -- $VPN_RUN_DIR/wg0.name" "$MOCK_SUDO_LOG"
  grep -Fq "sudo -n -- /usr/bin/head -c 32 -- $VPN_RUN_DIR/wg1.name" "$MOCK_SUDO_LOG"
}

@test "vpn darwin: an ambiguous pairing without a sudo timestamp is locked" {
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg0
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg1
  vpn_darwin_record wg0 utun5 1700000000
  vpn_darwin_record wg1 utun6 1700000000
  vpn_darwin_socket utun5 1700000000
  vpn_darwin_socket utun6 1700000001
  export VPN_WG_DEVICES="utun5 utun6"
  export MOCK_SUDO_ALLOW=""

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    local -a reply=()
    local -i map_status=0
    _vpn_active_interfaces || map_status=$?
    print -r -- "status=$map_status"
    print -r -- "access=$(_vpn_wg_access_state)"
    vpn-summary
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"status=4"* ]]
  [[ "$output" == *"access=locked"* ]]
  grep -Eq '^  Active: +locked$' <<<"$output"
  grep -Eq '^  wg0 +unknown ' <<<"$output"
  ! grep -q 'head' "$MOCK_SUDO_LOG" || false
}

@test "vpn darwin: a utun device without a wg-quick profile is never targeted" {
  darwin_one_tunnel
  vpn_darwin_socket utun7 1700000100
  export VPN_WG_DEVICES="utun5 utun7"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    vpn-off-all --dry-run
  '

  [ "$status" -eq 0 ]
  grep -Eq '^  1  wg0 +utun5 ' <<<"$output"
  ! grep -Eq '^  2 ' <<<"$output" || false
  [[ "$output" == *"left unchanged: utun7."* ]]
  [[ "$output" == *"Dry run: 1 tunnel planned; nothing was disconnected."* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

# --- Tunnel transitions -----------------------------------------------------

@test "vpn darwin: connect runs Homebrew wg-quick through an absolute Bash 4" {
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg0
  export MOCK_SUDO_ALLOW="true,bash"
  local conf="$VPN_PROFILE_DIR/wg0.conf"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_details_sections() { return 0; }
    vpn-on wg0
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Privileged operation: $VPN_BREW/bin/bash $VPN_BREW/bin/wg-quick up $conf"* ]]
  [[ "$output" == *"\$ sudo -n $VPN_BREW/bin/bash $VPN_BREW/bin/wg-quick up $conf  (output shown on failure)"* ]]
  grep -Fxq "sudo -n -- $VPN_BREW/bin/bash $VPN_BREW/bin/wg-quick up $conf" "$MOCK_SUDO_LOG"
  [ "$(cat "$VPN_WG_QUICK_LOG")" = "up $conf" ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = "wg0" ]
}

@test "vpn darwin: disconnect and reconnect use the profile, not the device" {
  darwin_one_tunnel
  export MOCK_SUDO_ALLOW="true,bash"
  local conf="$VPN_PROFILE_DIR/wg0.conf"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_details_sections() { return 0; }
    vpn-off wg0 || return 10
    _vpn_remember_iface wg0 || return 11
    vpn-reconnect-last
  '

  [ "$status" -eq 0 ]
  grep -Eq '^  Device: +utun5$' <<<"$output"
  [ "$(cat "$VPN_WG_QUICK_LOG")" = "$(printf 'down %s\ndown %s\nup %s' "$conf" "$conf" "$conf")" ]
  [ "$(grep -c "sudo -n -- $VPN_BREW/bin/bash $VPN_BREW/bin/wg-quick" "$MOCK_SUDO_LOG")" -eq 3 ]
  ! grep -q 'utun5' "$MOCK_SUDO_LOG" || false
}

@test "vpn darwin: a device that changes during authentication aborts the disconnect" {
  darwin_one_tunnel
  vpn_darwin_socket utun6 1700000501
  export VPN_WG_DEVICES="utun5 utun6"
  export MOCK_SUDO_ALLOW="true,bash"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    # wg-quick replaced the tunnel while the prompt was open.
    _vpn_ensure_sudo_access() {
      command chmod -- 600 "$VPN_RUN_DIR/wg0.name"
      print -r -- utun6 >| "$VPN_RUN_DIR/wg0.name"
      command chmod -- 400 "$VPN_RUN_DIR/wg0.name"
      command perl -e "utime(1700000500, 1700000500, \$ARGV[0])" "$VPN_RUN_DIR/wg0.name"
    }
    vpn-off wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"The device of wg0 changed during authentication"* ]]
  [ ! -s "$VPN_WG_QUICK_LOG" ]
}

@test "vpn darwin: vpn-off-all names devices only when they differ from tunnels" {
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg0
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg1
  vpn_darwin_record wg0 utun5 1700000000
  vpn_darwin_record wg1 utun6 1700000100
  vpn_darwin_socket utun5 1700000000
  vpn_darwin_socket utun6 1700000100
  export VPN_WG_DEVICES="utun5 utun6"
  export MOCK_SUDO_ALLOW="true,bash"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_details_sections() { return 0; }
    vpn-off-all --yes
  '

  [ "$status" -eq 0 ]
  grep -Eq '^  # +Tunnel +Device +Profile$' <<<"$output"
  grep -Eq '^  1  wg0 +utun5 ' <<<"$output"
  grep -Eq '^  2  wg1 +utun6 ' <<<"$output"
  [[ "$output" == *"Disconnect completed: 2 tunnels disconnected."* ]]
  [ "$(wc -l < "$VPN_WG_QUICK_LOG")" -eq 2 ]

  # Linux and WSL devices are the tunnels themselves: no Device column.
  vpn_pin_kernel Linux
  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_get_active_interfaces() { print -r -- "wg0 wg1"; }
    vpn-off-all --dry-run
  '

  [ "$status" -eq 0 ]
  grep -Eq '^  # +Tunnel +Profile$' <<<"$output"
  [[ "$output" != *"Device"* ]]
}

# --- Summary, menu, details, and IP info ------------------------------------

@test "vpn darwin: summary and menu show devices beside profiles" {
  darwin_one_tunnel
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg1
  export MOCK_SUDO_ALLOW=""

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    vpn-summary
    _vpn_state_load
    _vpn_menu_context
    _vpn_menu_rows
  '

  [ "$status" -eq 0 ]
  grep -Eq '^  Active: +wg0 \(utun5\)$' <<<"$output"
  grep -Eq '^  Profile +State +Device +Backup$' <<<"$output"
  grep -Eq '^  wg0 +active +utun5 +missing$' <<<"$output"
  grep -Eq '^  wg1 +inactive +missing$' <<<"$output"
  [[ "$output" != *"WSL fix"* ]]
  grep -Eq '^Active: wg0 \| Profiles: 2 \| Sudo: locked \| Platform: darwin$' <<<"$output"
  grep -Fxq '  Disconnect wg0 — utun5|vpn-off|Disconnect this active profile.|wg0' <<<"$output"
  grep -Fxq '  Connect wg1|vpn-on|Connect this profile with WireGuard.|wg1' <<<"$output"
}

@test "vpn darwin: details and IP info read the device with BSD collectors" {
  darwin_one_tunnel
  export MOCK_SUDO_ALLOW="true,wg"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    vpn-details || return 10
    _vpn_have_ip_stack() { return 0; }
    _vpn_get_ip_info() { printf "198.51.100.9\t\t\t\t\tfixture.example\n"; }
    vpn-ip-info
  '

  [ "$status" -eq 0 ]
  grep -Eq '^  Device: +utun5$' <<<"$output"
  [[ "$output" == *"│ interface: utun5"* ]]
  grep -Eq '^  Internal IP: +10\.64\.0\.2/24, fd00::2/128$' <<<"$output"
  grep -Eq '^  Endpoint: +203\.0\.113\.7:51820$' <<<"$output"
  grep -Eq '^  Transfer: +↓ 1\.0 KiB  ↑ 2\.0 KiB$' <<<"$output"
  grep -Eq '^  Tunnel DNS: +10\.64\.0\.1$' <<<"$output"
  grep -Eq '^  Default route: +1\.1\.1\.1 dev utun5$' <<<"$output"
  grep -Eq '^  Nameserver: +10\.64\.0\.1$' <<<"$output"
  grep -Eq '^  Nameserver: +192\.168\.1\.1$' <<<"$output"
  [[ "$output" != *"not present in"* ]]
  [[ "$output" != *"/etc/resolv.conf"* ]]
  # Root reads per-device state through the validated absolute wg.
  grep -Fq "sudo -n -- $VPN_BREW/bin/wg show utun5" "$MOCK_SUDO_LOG"
}

@test "vpn darwin: the report records platform, Bash, routes, and scutil resolvers" {
  darwin_one_tunnel
  export MOCK_SUDO_ALLOW="true,wg"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_check_ip_stack() { return 0; }
    _vpn_get_ip_info() { return 1; }
    _vpn_get_ip_crosscheck() { return 1; }
    vpn-report
  '

  [ "$status" -eq 0 ]
  local report
  report=$(find "$VPN_MENU_REPORT_DIR" -name 'vpn-report-*.md' -type f)
  [ -n "$report" ]
  grep -Fq -- '- **Platform:** darwin' "$report"
  grep -Fq -- '- **WSL:** no' "$report"
  grep -Fq -- '- **Bash for wg-quick:** ' "$report"
  grep -Fq -- '- **Device:** utun5' "$report"
  grep -Fq -- '**route -n get 1.1.1.1:**' "$report"
  grep -Fq -- '**netstat -rn -f inet6:**' "$report"
  grep -Fq -- '**scutil --dns:**' "$report"
  grep -Fq -- '- 10.64.0.1' "$report"
  ! grep -Fq 'resolv.conf' "$report" || false
}

# --- Privilege model --------------------------------------------------------

@test "vpn darwin: profile installs and directory creation use owner 0 and group 0" {
  mkdir -p "$HOME/private/etc"
  export MOCK_SUDO_ALLOW="true,install,mktemp,ln,rm"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    _VPN_AUTO_YES=1
    vpn-profile-create wg9
  '

  [ "$status" -eq 0 ]
  local system_dir="$HOME/private/etc/wireguard"
  [ "$(file_mode "$system_dir")" = "700" ]
  [ "$(file_mode "$system_dir/wg9.conf")" = "600" ]
  grep -Fq "install -d -m 700 -o 0 -g 0 -- $system_dir" "$MOCK_SUDO_LOG"
  grep -Eq 'install -m 600 -o 0 -g 0 -- .+ '"$system_dir"'/\.zdx-vpn-profile-install\.' "$MOCK_SUDO_LOG"
  grep -Fq "sudo -n -- /usr/bin/mktemp $system_dir/.zdx-vpn-profile-install." "$MOCK_SUDO_LOG"
  grep -Fq "sudo -n -- /bin/ln -- " "$MOCK_SUDO_LOG"
  ! grep -Eq ' -(o|g) root' "$MOCK_SUDO_LOG" || false

  # Linux uses the same numeric owner and group through sudo's secure_path.
  vpn_pin_kernel Linux
  : > "$MOCK_SUDO_LOG"
  vpn_darwin_profile "$VPN_PROFILE_DIR" seed
  run run_zsh '
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    vpn-profile-create wg8
  '
  [ "$status" -eq 0 ]
  grep -Eq '^sudo -n -- install -m 600 -o 0 -g 0 -- ' "$MOCK_SUDO_LOG"
}

@test "vpn darwin: privileged file primitives run from fixed system paths" {
  run run_zsh '
    local -a reply=()
    _vpn_privileged_argv mv -- a b || return 10
    [[ "${reply[1]}" == /bin/mv && "${reply[2]}" == -- ]] || return 11
    _vpn_privileged_argv true || return 12
    [[ "${reply[*]}" == /usr/bin/true ]] || return 13
    _vpn_privileged_argv "$VPN_BREW/bin/wg" show || return 14
    [[ "${reply[1]}" == "$VPN_BREW/bin/wg" ]] || return 15
    # A bare name outside the fixed set never reaches sudo on macOS.
    _vpn_privileged_argv wg-quick down x && return 16
    _vpn_sudo_exec wg-quick down x && return 17
    return 0
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Refusing an unpinned privileged command: wg-quick"* ]]
  ! grep -q 'wg-quick' "$MOCK_SUDO_LOG" || false
}

@test "vpn darwin: the privileged metadata probe matches the unprivileged fingerprint" {
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg0
  export MOCK_SUDO_ALLOW="true,zdx-vpn-stat,cksum"
  local kernel
  for kernel in Darwin Linux; do
    vpn_pin_kernel "$kernel"
    : > "$MOCK_SUDO_LOG"
    run run_zsh '
      export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
      local conf="$VPN_CONFIG_DIR/wg0.conf" direct="" privileged=""
      direct=$(_vpn_profile_file_fingerprint "$conf") || return 10
      # Model a protected profile: direct metadata reads fail, so the state
      # and fingerprint come from the fixed program run through sudo.
      zmodload zsh/stat
      zstat() {
        [[ "${argv[-1]}" == "$conf" ]] && return 1
        builtin zstat "$@"
      }
      [[ "$(_vpn_profile_path_state "$conf")" == safe ]] || return 11
      privileged=$(_vpn_profile_file_fingerprint "$conf") || return 12
      [[ "$direct" == "$privileged" ]] || {
        print -r -- "direct=$direct privileged=$privileged"
        return 13
      }
      command chmod -- 644 "$conf"
      [[ "$(_vpn_profile_path_state "$conf")" == unsafe ]] || return 14
    '
    [ "$status" -eq 0 ]
    grep -Eq 'sudo -n -- /(usr/)?bin/zsh -f -c .*zdx-vpn-stat '"$VPN_PROFILE_DIR"'/wg0.conf$' "$MOCK_SUDO_LOG"
    ! grep -Eq -- '-printf|-perm' "$MOCK_SUDO_LOG" || false
    chmod 600 "$VPN_PROFILE_DIR/wg0.conf"
  done
}

@test "vpn darwin: a profile in a user-owned directory is edited without sudo" {
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg0
  export VPN_EDIT_RC_FILE="$TEST_TEMP_DIR/edit-rc"
  export VPN_EDIT_CHILD="$TEST_TEMP_DIR/edit-child.zsh"
  export VPN_EDIT_MODE=change
  cat > "$TEST_MOCK_BIN/fixture-editor" <<EOF
#!$BASH
[[ "\$VPN_EDIT_MODE" == change ]] || exit 0
printf '# edited\\n' >> "\$1"
EOF
  chmod 755 "$TEST_MOCK_BIN/fixture-editor"
  cat > "$VPN_EDIT_CHILD" <<'EOF'
source "$ZSH_CUSTOM/functions/vpn-menu.zsh" || exit 91
source "$VPN_DARWIN_SETUP" || exit 92
export VPN_CONFIG_DIR="$VPN_PROFILE_DIR" EDITOR=fixture-editor
unset SUDO_EDITOR VISUAL
_VPN_AUTO_YES=1
vpn-config-edit wg0
print -r -- "$?" > "$VPN_EDIT_RC_FILE"
EOF
  local inode_before
  inode_before=$(file_inode "$VPN_PROFILE_DIR/wg0.conf")

  run_edit_in_pty() {
    rm -f "$VPN_EDIT_RC_FILE"
    run run_zsh '
      zmodload zsh/zpty || return 80
      zmodload zsh/datetime || return 79
      zpty -b vpn-edit zsh -dfi "$VPN_EDIT_CHILD" || return 81
      {
        local -F deadline=$(( EPOCHREALTIME + 30 ))
        local chunk="" transcript=""
        while [[ ! -s "$VPN_EDIT_RC_FILE" ]] && (( EPOCHREALTIME < deadline )); do
          if zpty -r -t vpn-edit chunk 2>/dev/null; then
            transcript+="$chunk"
          fi
          command sleep 0.01
        done
        while zpty -r -t vpn-edit chunk 2>/dev/null; do transcript+="$chunk"; done
        print -r -- "$transcript"
        [[ -s "$VPN_EDIT_RC_FILE" ]] || return 82
        return "$(<"$VPN_EDIT_RC_FILE")"
      } always {
        zpty -d vpn-edit 2>/dev/null || true
      }
    '
  }

  run_edit_in_pty
  [ "$status" -eq 0 ]
  [[ "$output" == *"Your editor runs as your own user on a private copy."* ]]
  [[ "$output" == *"Saved wg0.conf."* ]]
  grep -qx '# edited' "$VPN_PROFILE_DIR/wg0.conf"
  [ "$(file_mode "$VPN_PROFILE_DIR/wg0.conf")" = "600" ]
  [ "$(file_inode "$VPN_PROFILE_DIR/wg0.conf")" != "$inode_before" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ -z "$(find "$VPN_PROFILE_DIR" -name '.zdx-vpn-*' -print)" ]
  [ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'zdx-vpn-edit.*' -print)" ]

  # An unchanged copy publishes nothing.
  export VPN_EDIT_MODE=keep
  inode_before=$(file_inode "$VPN_PROFILE_DIR/wg0.conf")
  run_edit_in_pty
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes were made; wg0.conf is unchanged."* ]]
  [ "$(file_inode "$VPN_PROFILE_DIR/wg0.conf")" = "$inode_before" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn darwin: tunnel rows say when Bash 4 is missing" {
  rm "$VPN_BREW/bin/bash"
  cat > "$VPN_BREW/bin/bash" <<EOF
#!$BASH
# macOS /bin/bash 3.2 answers the version probe; everything else needs a
# working interpreter for the other mocks.
if [[ "\${1:-}" == -c && "\${2:-}" == *BASH_VERSINFO* ]]; then
  printf '3\\n'
  exit 0
fi
exec "$BASH" "\$@"
EOF
  chmod 755 "$VPN_BREW/bin/bash"
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg0
  export MOCK_SUDO_ALLOW="true,bash"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    _vpn_state_load
    _vpn_menu_rows
    vpn-on wg0
  '

  [ "$status" -eq 1 ]
  grep -Fq '  ○ Connect Profile (missing: bash 4+)|vpn-on|' <<<"$output"
  grep -Fq '  ○ Connect wg0 (missing: bash 4+)|vpn-on|' <<<"$output"
  [[ "$output" == *"wg-quick on macOS needs Bash 4 or newer"* ]]
  [ ! -s "$VPN_WG_QUICK_LOG" ]
  ! grep -q 'wg-quick' "$MOCK_SUDO_LOG" || false
}

@test "vpn darwin: the WSL IPv6 tweak is refused rather than applied" {
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg0
  cp "$VPN_PROFILE_DIR/wg0.conf" "$HOME/original.conf"
  export MOCK_SUDO_ALLOW="true,bash"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    VPN_MENU_WSL_IPV6_FIX=1
    _vpn_should_apply_wsl_ipv6_fix && return 10
    vpn-on wg0
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"VPN_MENU_WSL_IPV6_FIX=1 applies only to Linux and WSL."* ]]
  cmp -s "$HOME/original.conf" "$VPN_PROFILE_DIR/wg0.conf"
  [ ! -e "$VPN_PROFILE_DIR/wg0.conf.bak-vpn-menu" ]
  [ ! -s "$VPN_WG_QUICK_LOG" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn darwin: a tool another account can change is refused before sudo" {
  vpn_darwin_profile "$VPN_PROFILE_DIR" wg0
  chmod 775 "$VPN_BREW/bin"
  export MOCK_SUDO_ALLOW="true,bash"

  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    export VPN_CONFIG_DIR="$VPN_PROFILE_DIR"
    vpn-on wg0
  '

  chmod 755 "$VPN_BREW/bin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing wg-quick at $VPN_BREW/bin/wg-quick"* ]]
  [[ "$output" != *"Privileged operation"* ]]
  [ ! -s "$VPN_WG_QUICK_LOG" ]
  ! grep -q 'wg-quick' "$MOCK_SUDO_LOG" || false

  # Homebrew makes its prefix directories group-writable by admin (80), whose
  # members can already use sudo; wheel (0) is accepted too. Any other group,
  # other users, and the root-only policy for zsh still refuse group write.
  run run_zsh '
    local -i dir_mode=$(( 8#40775 ))
    _vpn_trusted_owner_mode "$EUID" 80 "$dir_mode" 1 || return 10
    _vpn_trusted_owner_mode "$EUID" 0 "$dir_mode" 1 || return 11
    _vpn_trusted_owner_mode "$EUID" 20 "$dir_mode" 1 && return 12
    _vpn_trusted_owner_mode 0 80 "$dir_mode" 0 && return 13
    _vpn_trusted_owner_mode "$EUID" 80 $(( 8#40777 )) 1 && return 14
    _vpn_trusted_owner_mode 0 0 $(( 8#41777 )) 0 || return 15
    return 0
  '
  [ "$status" -eq 0 ]
  vpn_pin_kernel Linux
  run run_zsh '_vpn_trusted_owner_mode "$EUID" 80 $(( 8#40775 )) 1'
  [ "$status" -eq 1 ]
}
