#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
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

  run run_zsh "_vpn_test_resolv_conf"
  [ "$status" -eq 0 ]
}

@test "vpn: _vpn_test_resolv_conf fails when no write access and chattr missing" {
  export MOCK_SUDO_WRITE_ETC_RESOLV_CONF=0
  export MOCK_LSATTR_ETC_RESOLV_CONF="----i---- /etc/resolv.conf"
  export MOCK_CHATTR_MISSING=1

  run run_zsh "_vpn_test_resolv_conf"
  [ "$status" -eq 1 ]
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
  # _vpn_is_wsl calls `command grep` on purpose, so a shell function named grep
  # cannot intercept it. The mock therefore models the external binary, which is
  # the boundary docs/testing.md asks tests to replace.
  install_proc_version_grep() {
    cat > "$TEST_MOCK_BIN/grep" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == "/proc/version" ]]; then
    exit ${1}
  fi
done
exec /usr/bin/grep "\$@"
EOF
    chmod +x "$TEST_MOCK_BIN/grep"
  }

  # Case 1: WSL_DISTRO_NAME is set, so /proc/version is never consulted.
  install_proc_version_grep 1
  run run_zsh "WSL_DISTRO_NAME='Ubuntu' _vpn_is_wsl"
  [ "$status" -eq 0 ]

  # Case 2: no WSL_DISTRO_NAME, but /proc/version reports a Microsoft kernel.
  install_proc_version_grep 0
  run run_zsh "unset WSL_DISTRO_NAME; _vpn_is_wsl"
  [ "$status" -eq 0 ]

  # Case 3: neither signal is present.
  install_proc_version_grep 1
  run run_zsh "unset WSL_DISTRO_NAME; _vpn_is_wsl"
  [ "$status" -eq 1 ]

  rm -f "$TEST_MOCK_BIN/grep"
}

@test "vpn: _vpn_apply_wsl_dns_hooks patches configuration correctly and is idempotent" {
  run run_zsh "
    export MOCK_SUDO_WRITE_ETC_RESOLV_CONF=1
    export MOCK_SUDO_ALLOW='true,test,install,mktemp,mv,rm'
    export MOCK_LSATTR_ETC_RESOLV_CONF='--------- /etc/resolv.conf'

    local profile_dir=\"\$HOME/wireguard\"
    command mkdir -p -- \"\$profile_dir\"
    command chmod 700 -- \"\$profile_dir\"
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
    command chmod 600 -- \"\$conf\"

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
