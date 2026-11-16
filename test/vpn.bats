#!/usr/bin/env bats

setup() {
  load test_helper
  load vpn_test_helper
  # A Linux kernel unless a test pins another; a WSL host still reads as WSL.
  vpn_pin_kernel Linux
}

teardown() {
  cleanup_sandbox
}

@test "vpn: kernel fixture sets child OSTYPE and refuses an invalid model" {
  local work="$HOME/ostype-model" native_status=0 default_status=0 invalid_status=0 model_status=0
  local kernel expected
  mkdir -m 700 "$work" || return 1
  cd "$work" || return 1

  unset TEST_ZSH_OSTYPE
  zsh -f -c 'emulate -R zsh; print -r -- "$OSTYPE"' \
    </dev/null > native.expected 2> native.stderr || native_status=$?
  printf '%s\n' "$native_status" > native.status || return 1
  run_zsh 'print -r -- "$OSTYPE"' > default.stdout 2> default.stderr || default_status=$?
  printf '%s\n' "$default_status" > default.status || return 1

  for kernel in Linux Darwin FreeBSD; do
    vpn_pin_kernel "$kernel" || return 1
    case "$kernel" in Linux) expected=linux-gnu ;; Darwin) expected=darwin-test ;; FreeBSD) expected=freebsd-test ;; esac
    printf '%s\n%s\n' "$expected" "$kernel" > "$kernel.expected" || return 1
    model_status=0
    run_zsh 'print -r -- "$OSTYPE"; command uname -s' \
      > "$kernel.stdout" 2> "$kernel.stderr" || model_status=$?
    printf '%s\n' "$model_status" > "$kernel.status" || return 1
  done

  export TEST_ZSH_OSTYPE=invalid-model
  run_zsh 'print -r -- reached > "$HOME/ostype-model/action.reached"' \
    > invalid.stdout 2> invalid.stderr || invalid_status=$?
  printf '%s\n' "$invalid_status" > invalid.status || return 1
  printf '%s\n' 'test_helper: invalid TEST_ZSH_OSTYPE' > invalid.expected || return 1

  # All five model calls have returned before assertions begin.
  [[ "$native_status" == 0 && "$default_status" == 0 ]] || return 1
  [[ ! -s native.stderr && ! -s default.stderr ]] || return 1
  cmp native.expected default.stdout || return 1
  for kernel in Linux Darwin FreeBSD; do
    [[ $(cat "$kernel.status") == 0 && ! -s "$kernel.stderr" ]] || return 1
    cmp "$kernel.expected" "$kernel.stdout" || return 1
  done
  [[ "$invalid_status" == 2 && ! -s invalid.stdout ]] || return 1
  cmp invalid.expected invalid.stderr || return 1
  [[ ! -e action.reached && ! -L action.reached ]] || return 1
  # This observes the rejected action; Core-before/after-source order is a
  # separate static property of run_zsh, not a source sentinel proved here.
}

@test "vpn: vpn-menu.zsh and vpn-common.zsh source cleanly" {
  run run_zsh "echo SOURCED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED"* ]]
}

@test "vpn: _vpn_test_resolv_conf succeeds when sudo has write access" {
  export MOCK_SUDO_WRITE_ETC_RESOLV_CONF=1
  export MOCK_SUDO_ALLOW=true
  export MOCK_LSATTR_ETC_RESOLV_CONF="--------- /etc/resolv.conf"

  run run_zsh "_vpn_resolv_conf_is_symlink() { return 1; }; _vpn_test_resolv_conf"
  [ "$status" -eq 0 ]
}

@test "vpn: _vpn_test_resolv_conf fails when no write access and chattr missing" {
  export MOCK_SUDO_WRITE_ETC_RESOLV_CONF=0
  export MOCK_LSATTR_ETC_RESOLV_CONF="----i---- /etc/resolv.conf"
  export MOCK_CHATTR_MISSING=1

  run run_zsh "_vpn_resolv_conf_is_symlink() { return 1; }; _vpn_test_resolv_conf"
  [ "$status" -eq 1 ]
}

@test "vpn: _vpn_test_resolv_conf refuses a symlinked resolver it cannot pin" {
  printf 'nameserver 1.1.1.1\n' > "$HOME/generated-resolv.conf"
  ln -s generated-resolv.conf "$HOME/resolv.conf"
  run run_zsh "_vpn_test_resolv_conf \"\$HOME/resolv.conf\""
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be pinned"* ]]
  [[ "$output" == *"generateResolvConf = false"* ]]
}

@test "vpn: _vpn_test_write_access checks directory writability" {
  # Case 1: directory does not exist
  run run_zsh "
    _vpn_config_dir() { echo \"\$HOME/nonexistent_wg\" }
    _vpn_test_write_access
  "
  [ "$status" -eq 1 ]

  # Case 2: directory exists and is writable
  run run_zsh "
    _vpn_config_dir() { echo \"\$HOME/wg_writable\" }
    mkdir -p \"\$HOME/wg_writable\"
    _vpn_test_write_access
  "
  [ "$status" -eq 0 ]
}

@test "vpn: _vpn_validate_iface_name validates interface naming rules" {
  run run_zsh "
    _vpn_validate_iface_name 'wg0' && \
    _vpn_validate_iface_name 'office-vpn' && \
    _vpn_validate_iface_name 'valid.name' && \
    ! _vpn_validate_iface_name 'invalid/name' && \
    ! _vpn_validate_iface_name 'invalid name'
  "
  [ "$status" -eq 0 ]
}

@test "vpn: cache read and write helpers work" {
  run run_zsh "
    _vpn_config_dir() { echo \"\$HOME/wg_mock\" }
    mkdir -p \"\$HOME/wg_mock\"
    touch \"\$HOME/wg_mock/cached-wg0.conf\"
    chmod 700 \"\$HOME/wg_mock\"
    chmod 600 \"\$HOME/wg_mock/cached-wg0.conf\"
    _vpn_write_cached_iface 'test-key' 'cached-wg0' || exit 1
    val=\$(_vpn_read_cached_iface 'test-key') || exit 2
    [[ \"\$val\" == 'cached-wg0' ]] || exit 3

    _vpn_clear_cached_iface 'test-key'
    val2=\$(_vpn_peek_cached_iface 'test-key')
    [[ -z \"\$val2\" ]] || exit 4
  "
  [ "$status" -eq 0 ]
}

@test "vpn: last used interface helpers work" {
  run run_zsh "
    _vpn_config_dir() { echo \"\$HOME/wg_mock\" }
    mkdir -p \"\$HOME/wg_mock\"
    touch \"\$HOME/wg_mock/last-wg1.conf\"
    chmod 700 \"\$HOME/wg_mock\"
    chmod 600 \"\$HOME/wg_mock/last-wg1.conf\"
    _vpn_remember_iface 'last-wg1' || exit 1
    val=\$(_vpn_read_last_iface) || exit 2
    [[ \"\$val\" == 'last-wg1' ]] || exit 3

    _vpn_clear_last_iface
    val2=\$(_vpn_peek_last_iface)
    [[ -z \"\$val2\" ]] || exit 4
  "
  [ "$status" -eq 0 ]
}

@test "vpn: default interface helpers work" {
  run run_zsh "
    _vpn_config_dir() { echo \"\$HOME/wg_mock\" }
    mkdir -p \"\$HOME/wg_mock\"
    touch \"\$HOME/wg_mock/default-wg2.conf\"
    chmod 700 \"\$HOME/wg_mock\"
    chmod 600 \"\$HOME/wg_mock/default-wg2.conf\"
    _vpn_set_default_iface 'default-wg2' || exit 1
    val=\$(_vpn_read_default_iface) || exit 2
    [[ \"\$val\" == 'default-wg2' ]] || exit 3

    _vpn_clear_default_iface
    val2=\$(_vpn_peek_default_iface)
    [[ -z \"\$val2\" ]] || exit 4
  "
  [ "$status" -eq 0 ]
}

@test "vpn: _vpn_is_wsl detects WSL correctly" {
  # Qualify a finite forbidden-grep recorder, then prove the builtin detector
  # never calls it. These are session/OS models, not another host's kernel.
  export VPN_WSL_DETECTOR_GREP_CALLS="$HOME/wsl-detector-grep.calls"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/grep" || return 1
  cat >> "$TEST_MOCK_BIN/grep" <<'MOCK'
printf '%s\0' "$#" "$0" "$@" >> "$VPN_WSL_DETECTOR_GREP_CALLS" || exit 98
exit 97
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/grep" || return 1
  run "$TEST_MOCK_BIN/grep" fixture-control
  [ "$status" -eq 97 ] || return 1
  [[ -s "$VPN_WSL_DETECTOR_GREP_CALLS" ]] || return 1
  rm -- "$VPN_WSL_DETECTOR_GREP_CALLS" || return 1

  # Linux model plus a distro marker; no kernel file needs to be simulated.
  run run_zsh "unset WSL_INTEROP; WSL_DISTRO_NAME='Ubuntu'; _vpn_is_wsl"
  [ "$status" -eq 0 ]

  # A service session may have interop evidence without a distro variable.
  run run_zsh "unset WSL_DISTRO_NAME; WSL_INTEROP=fixture-interop; _vpn_is_wsl"
  [ "$status" -eq 0 ]

  # Non-Linux OS evidence cannot be overridden by WSL-looking variables.
  # This is not a claim about a Linux kernel with no WSL evidence.
  vpn_pin_kernel Darwin
  run run_zsh "WSL_DISTRO_NAME=Ubuntu; WSL_INTEROP=fixture-interop; _vpn_is_wsl"
  [ "$status" -eq 1 ]
  [[ ! -e "$VPN_WSL_DETECTOR_GREP_CALLS" ]] || return 1
  rm -- "$TEST_MOCK_BIN/grep" || return 1
}
@test "vpn: _vpn_apply_wsl_dns_hooks patches configuration correctly and is idempotent" {
  run run_zsh "
    export MOCK_SUDO_WRITE_ETC_RESOLV_CONF=1
    export MOCK_SUDO_ALLOW='true,test,install,mktemp,mv,rm,wg-quick'
    export MOCK_LSATTR_ETC_RESOLV_CONF='--------- /etc/resolv.conf'
    _vpn_resolv_conf_is_symlink() { return 1; }

    local profile_dir=\"\$HOME/wireguard\"
    command mkdir -p -- \"\$profile_dir\"
    command chmod -- 700 \"\$profile_dir\"
    export VPN_CONFIG_DIR=\"\$profile_dir\"
    local conf=\"\$profile_dir/wg-test.conf\"
    cat <<'EOF' > \"\$conf\"
[Interface]
PrivateKey = somekey=
Address = 10.0.0.2/24
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = peerkey=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:51820
EOF
    command chmod -- 600 \"\$conf\"

    _vpn_apply_wsl_dns_hooks \"\$conf\" || exit 1

    if grep -q '^DNS[[:space:]]*=' \"\$conf\"; then
      echo 'FAIL: DNS line was not removed'
      exit 2
    fi
    if ! grep -q 'zdx: wsl-dns-hooks v1' \"\$conf\"; then
      echo 'FAIL: Sentinel comment not found'
      exit 3
    fi
    if ! grep -q 'PostUp =' \"\$conf\" || ! grep -q 'PostDown =' \"\$conf\"; then
      echo 'FAIL: PostUp or PostDown hook missing'
      exit 4
    fi

    if ! grep -q 'nameserver 8.8.8.8' \"\$conf\"; then
      echo 'FAIL: PostUp does not point to first tunnel nameserver'
      exit 5
    fi

    _vpn_apply_wsl_dns_hooks \"\$conf\" || exit 6

    local hooks_count
    hooks_count=\$(grep -c 'PostUp =' \"\$conf\")
    if [[ \"\$hooks_count\" -ne 1 ]]; then
      echo \"FAIL: duplicate hooks added (\$hooks_count)\"
      exit 7
    fi
  "
  [ "$status" -eq 0 ]
}

@test "vpn: WSL DNS hardening accepts the section headers that import accepts" {
  run run_zsh "
    export MOCK_SUDO_WRITE_ETC_RESOLV_CONF=1
    export MOCK_SUDO_ALLOW='true,test,install,mktemp,mv,rm,wg-quick'
    export MOCK_LSATTR_ETC_RESOLV_CONF='--------- /etc/resolv.conf'
    _vpn_resolv_conf_is_symlink() { return 1; }

    local profile_dir=\"\$HOME/wireguard\"
    command mkdir -p -- \"\$profile_dir\"
    command chmod -- 700 \"\$profile_dir\"
    export VPN_CONFIG_DIR=\"\$profile_dir\"
    printf '[interface]\nPrivateKey = somekey=\nDNS = 8.8.8.8\n\n\t[peer] # provider\nPublicKey = peerkey=\nAllowedIPs = 0.0.0.0/0\n' \
      > \"\$profile_dir/lower.conf\"
    printf '  [Interface]\nPrivateKey = somekey=\nDNS = 8.8.8.8\n\n[Peer]\nPublicKey = peerkey=\nAllowedIPs = 0.0.0.0/0\n' \
      > \"\$profile_dir/indented.conf\"
    command chmod -- 600 \"\$profile_dir/lower.conf\" \"\$profile_dir/indented.conf\"

    local name conf hook_line peer_line
    local -i failed=0
    for name in lower indented; do
      conf=\"\$profile_dir/\$name.conf\"
      if ! _vpn_validate_profile_file \"\$conf\"; then
        print -r -- \"FAIL: import refuses \$name\"
        failed=1
        continue
      fi
      if ! _vpn_apply_wsl_dns_hooks \"\$conf\"; then
        print -r -- \"FAIL: hardening refuses \$name\"
        failed=1
        continue
      fi
      grep -q 'zdx: wsl-dns-hooks v1' \"\$conf\" || { print -r -- \"FAIL: no sentinel in \$name\"; failed=1; }
      hook_line=\$(grep -n 'PostUp =' \"\$conf\" | head -n 1 | cut -d: -f1)
      peer_line=\$(grep -niE '^[[:space:]]*\\[peer\\]' \"\$conf\" | head -n 1 | cut -d: -f1)
      (( hook_line > 0 && hook_line < peer_line )) \
        || { print -r -- \"FAIL: hooks are not before the peer header in \$name\"; failed=1; }
    done
    exit \$failed
  "
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}
