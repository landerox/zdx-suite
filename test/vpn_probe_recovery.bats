#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export PATH="$TEST_MOCK_BIN:/usr/bin:/bin"
  export VPN_PROBE_LOG="$HOME/probe.calls"
  export VPN_PROBE_CACHE_RC=0 VPN_PROBE_AUTH_RC=0
  export VPN_PROBE_DIRECT_RC=0 VPN_PROBE_PRIVILEGED_RC=0
  export VPN_PROBE_PAYLOAD_RC=0
  export VPN_PROBE_DIRECT_OUTPUT='' VPN_PROBE_PRIVILEGED_OUTPUT='wg0 wg1'
  export VPN_CONFIG_DIR="$HOME/wireguard"
  mkdir -m 700 "$VPN_CONFIG_DIR"
  : > "$VPN_PROBE_LOG"

  cat > "$TEST_MOCK_BIN/sudo" <<'EOF'
#!/usr/bin/env zsh
print -r -- "sudo:$*" >> "$VPN_PROBE_LOG"
case "$*" in
  '-n true') exit "$VPN_PROBE_CACHE_RC" ;;
  '-v') exit "$VPN_PROBE_AUTH_RC" ;;
esac
[[ "$1" == -n && "$2" == -- ]] || exit 97
shift 2
case "$1" in
  wg|vpn-probe-payload|find|cksum|test)
    export VPN_PROBE_PRIVILEGED=1
    exec "$TEST_MOCK_BIN/$1" "${@:2}"
    ;;
  *) exit 97 ;;
esac
EOF
  cat > "$TEST_MOCK_BIN/wg" <<'EOF'
#!/usr/bin/env zsh
if [[ "${VPN_PROBE_PRIVILEGED:-0}" == 1 ]]; then
  print -r -- "wg:privileged:$*" >> "$VPN_PROBE_LOG"
  [[ -z "$VPN_PROBE_PRIVILEGED_OUTPUT" ]] || print -r -- "$VPN_PROBE_PRIVILEGED_OUTPUT"
  exit "$VPN_PROBE_PRIVILEGED_RC"
fi
print -r -- "wg:direct:$*" >> "$VPN_PROBE_LOG"
[[ -z "$VPN_PROBE_DIRECT_OUTPUT" ]] || print -r -- "$VPN_PROBE_DIRECT_OUTPUT"
exit "$VPN_PROBE_DIRECT_RC"
EOF
  cat > "$TEST_MOCK_BIN/vpn-probe-payload" <<'EOF'
#!/usr/bin/env zsh
print -r -- "payload:$*" >> "$VPN_PROBE_LOG"
exit "$VPN_PROBE_PAYLOAD_RC"
EOF
  chmod +x "$TEST_MOCK_BIN/sudo" "$TEST_MOCK_BIN/wg" "$TEST_MOCK_BIN/vpn-probe-payload"
  export VPN_PROBE_SETUP="$HOME/probe-setup.zsh"
  cat > "$VPN_PROBE_SETUP" <<'EOF'
source "$ZSH_CUSTOM/functions/vpn-menu.zsh"
# The shared command wrapper can replace pipestatus in the real capture path.
unfunction command
_VPN_PLATFORM=linux
EOF
}

teardown() {
  chmod 700 "$VPN_CONFIG_DIR" 2>/dev/null || true
  cleanup_sandbox
}

# Simulate root-only metadata access without changing ownership or using sudo.
# All fallback payloads remain external recorders; only zstat is forced to fail.
setup_profile_probe() {
  export VPN_PROBE_PROFILE="$VPN_CONFIG_DIR/wg0.conf"
  export VPN_PROBE_PROFILE_LOG="$HOME/profile.calls"
  export VPN_PROBE_METADATA_COUNT="$HOME/metadata.count"
  export VPN_PROBE_PROFILE_INTERRUPT=none VPN_PROBE_PROFILE_STATUS=130
  export VPN_PROBE_PROFILE_PROTECTED=1
  printf '[Interface]\nPrivateKey = fixture\n' > "$VPN_PROBE_PROFILE"
  chmod 600 "$VPN_PROBE_PROFILE"
  : > "$VPN_PROBE_PROFILE_LOG"
  printf '0\n' > "$VPN_PROBE_METADATA_COUNT"
  cat >> "$VPN_PROBE_SETUP" <<'EOF'
zmodload zsh/stat
zstat() {
  if [[ "$VPN_PROBE_PROFILE_PROTECTED" == 1 && "${argv[-1]}" == "$VPN_PROBE_PROFILE" ]]; then
    return 1
  fi
  builtin zstat "$@"
}
EOF
  cat > "$TEST_MOCK_BIN/find" <<'EOF'
#!/usr/bin/env zsh
[[ "$1" == "$VPN_PROBE_PROFILE" ]] || exit 97
typeset phase=safety
if [[ "$*" == *-printf* ]]; then
  typeset -i count=$(< "$VPN_PROBE_METADATA_COUNT")
  (( ++count ))
  print -r -- "$count" > "$VPN_PROBE_METADATA_COUNT"
  if (( count == 1 )); then
    phase=metadata-before
  else
    phase=metadata-after
  fi
fi
print -r -- "$phase" >> "$VPN_PROBE_PROFILE_LOG"
[[ "$VPN_PROBE_PROFILE_INTERRUPT" != "$phase" ]] || exit "$VPN_PROBE_PROFILE_STATUS"
if [[ "$phase" == safety ]]; then
  print -r -- "$1"
else
  print -r -- '1:2:0:600:1:33:100:100'
fi
EOF
  cat > "$TEST_MOCK_BIN/cksum" <<'EOF'
#!/usr/bin/env zsh
print -r -- checksum >> "$VPN_PROBE_PROFILE_LOG"
[[ "$VPN_PROBE_PROFILE_INTERRUPT" != checksum ]] || exit "$VPN_PROBE_PROFILE_STATUS"
if (( $# == 0 )); then
  print -r -- '123 33'
else
  [[ "$1" == -- && "$2" == "$VPN_PROBE_PROFILE" ]] || exit 97
  print -r -- "123 33 $2"
fi
EOF
  cat > "$TEST_MOCK_BIN/test" <<'EOF'
#!/usr/bin/env zsh
[[ "$2" == "$VPN_PROBE_PROFILE" ]] || exit 97
case "$1" in
  -e) typeset phase=presence ;;
  -L) typeset phase=symlink ;;
  *) exit 97 ;;
esac
print -r -- "$phase" >> "$VPN_PROBE_PROFILE_LOG"
[[ "$VPN_PROBE_PROFILE_INTERRUPT" != "$phase" ]] || exit "$VPN_PROBE_PROFILE_STATUS"
# The absence result allows the second existence probe to be exercised.
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/find" "$TEST_MOCK_BIN/cksum" "$TEST_MOCK_BIN/test"
}

@test "vpn probe recovery: interrupted cached authorization never starts authentication" {
  local expected
  for expected in 130 143; do
    export VPN_PROBE_CACHE_RC="$expected"
    : > "$VPN_PROBE_LOG"
    run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_ensure_sudo_access "Test access"'

    [ "$status" -eq "$expected" ]
    [ "$(cat "$VPN_PROBE_LOG")" = 'sudo:-n true' ]
    [[ "$output" != *'unlocked'* ]]
  done
}

@test "vpn probe recovery: authentication cancellation preserves INT and TERM statuses" {
  export VPN_PROBE_CACHE_RC=1
  local expected
  for expected in 130 143; do
    export VPN_PROBE_AUTH_RC="$expected"
    : > "$VPN_PROBE_LOG"
    run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_ensure_sudo_access "Test access"'

    [ "$status" -eq "$expected" ]
    [ "$(cat "$VPN_PROBE_LOG")" = $'sudo:-n true\nsudo:-v' ]
    [[ "$output" == *'authentication interrupted'* ]]
    [[ "$output" != *'unlocked'* ]]
  done
}

@test "vpn probe recovery: ordinary authorization success and refusal retain their contract" {
  run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_ensure_sudo_access "Test access"'
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_PROBE_LOG")" = 'sudo:-n true' ]

  export VPN_PROBE_CACHE_RC=1
  : > "$VPN_PROBE_LOG"
  run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_ensure_sudo_access "Test access"'
  [ "$status" -eq 0 ]
  [ "$(cat "$VPN_PROBE_LOG")" = $'sudo:-n true\nsudo:-v' ]
  [[ "$output" == *'unlocked'* ]]

  export VPN_PROBE_AUTH_RC=23
  : > "$VPN_PROBE_LOG"
  run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_ensure_sudo_access "Test access"'
  [ "$status" -eq 1 ]
  [ "$(cat "$VPN_PROBE_LOG")" = $'sudo:-n true\nsudo:-v' ]
  [[ "$output" != *'unlocked'* ]]
}

@test "vpn probe recovery: interrupted cache checks stop privileged execution and probes" {
  local helper expected
  for helper in _vpn_sudo_exec _vpn_sudo_probe; do
    export VPN_PROBE_HELPER="$helper"
    for expected in 130 143; do
      export VPN_PROBE_CACHE_RC="$expected"
      : > "$VPN_PROBE_LOG"
      run run_zsh 'source "$VPN_PROBE_SETUP"; "$VPN_PROBE_HELPER" vpn-probe-payload operation'

      [ "$status" -eq "$expected" ]
      [ "$(cat "$VPN_PROBE_LOG")" = 'sudo:-n true' ]
    done
  done
}

@test "vpn probe recovery: privileged payload interruptions propagate without authentication" {
  local helper expected
  for helper in _vpn_sudo_exec _vpn_sudo_probe; do
    export VPN_PROBE_HELPER="$helper"
    for expected in 130 143; do
      export VPN_PROBE_PAYLOAD_RC="$expected"
      : > "$VPN_PROBE_LOG"
      run run_zsh 'source "$VPN_PROBE_SETUP"; "$VPN_PROBE_HELPER" vpn-probe-payload operation'

      [ "$status" -eq "$expected" ]
      [ "$(cat "$VPN_PROBE_LOG")" = $'sudo:-n true\nsudo:-n -- vpn-probe-payload operation\npayload:operation' ]
    done
  done
}

@test "vpn probe recovery: direct WireGuard interruptions never fall back to sudo" {
  local expected
  for expected in 130 143; do
    export VPN_PROBE_DIRECT_RC="$expected"
    : > "$VPN_PROBE_LOG"
    run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_run_wg show interfaces'

    [ "$status" -eq "$expected" ]
    [ "$(cat "$VPN_PROBE_LOG")" = 'wg:direct:show interfaces' ]
  done
}

@test "vpn probe recovery: bounded interface capture preserves interruptions and hides partial output" {
  export VPN_PROBE_DIRECT_OUTPUT='partial-wg'
  local expected
  for expected in 130 143; do
    export VPN_PROBE_DIRECT_RC="$expected"
    : > "$VPN_PROBE_LOG"
    run run_zsh '
      source "$VPN_PROBE_SETUP"
      _vpn_get_active_interfaces > "$HOME/interfaces.stdout"
    '

    [ "$status" -eq "$expected" ]
    [ ! -s "$HOME/interfaces.stdout" ]
    [ "$(cat "$VPN_PROBE_LOG")" = 'wg:direct:show interfaces' ]
  done
}

@test "vpn probe recovery: ordinary direct failure still uses an already warm cache" {
  export VPN_PROBE_DIRECT_RC=23
  run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_get_active_interfaces'

  [ "$status" -eq 0 ]
  [ "$output" = 'wg0 wg1' ]
  [ "$(cat "$VPN_PROBE_LOG")" = $'wg:direct:show interfaces\nsudo:-n true\nsudo:-n -- wg show interfaces\nwg:privileged:show interfaces' ]
}

@test "vpn probe recovery: cold or interrupted fallback cache checks never authenticate" {
  export VPN_PROBE_DIRECT_RC=23
  local expected
  for expected in 1 130 143; do
    export VPN_PROBE_CACHE_RC="$expected"
    : > "$VPN_PROBE_LOG"
    run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_get_active_interfaces'

    [ "$status" -eq "$expected" ]
    [ "$output" = '' ]
    [ "$(cat "$VPN_PROBE_LOG")" = $'wg:direct:show interfaces\nsudo:-n true' ]
  done
}

@test "vpn probe recovery: privileged interface interruption survives bounded capture" {
  export VPN_PROBE_DIRECT_RC=23 VPN_PROBE_PRIVILEGED_OUTPUT='partial-wg'
  local expected
  for expected in 130 143; do
    export VPN_PROBE_PRIVILEGED_RC="$expected"
    : > "$VPN_PROBE_LOG"
    run run_zsh '
      source "$VPN_PROBE_SETUP"
      _vpn_get_active_interfaces > "$HOME/interfaces.stdout"
    '

    [ "$status" -eq "$expected" ]
    [ ! -s "$HOME/interfaces.stdout" ]
    [ "$(cat "$VPN_PROBE_LOG")" = $'wg:direct:show interfaces\nsudo:-n true\nsudo:-n -- wg show interfaces\nwg:privileged:show interfaces' ]
  done
}

@test "vpn probe recovery: ordinary fallback errors preserve raw execution and normalized capture statuses" {
  export VPN_PROBE_DIRECT_RC=23 VPN_PROBE_PRIVILEGED_RC=47
  export VPN_PROBE_PRIVILEGED_OUTPUT=''
  run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_run_wg show interfaces'
  [ "$status" -eq 47 ]

  : > "$VPN_PROBE_LOG"
  run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_get_active_interfaces'
  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ "$(cat "$VPN_PROBE_LOG")" = $'wg:direct:show interfaces\nsudo:-n true\nsudo:-n -- wg show interfaces\nwg:privileged:show interfaces' ]
}

@test "vpn probe recovery: interface capture still rejects oversized successful output" {
  export VPN_PROBE_DIRECT_OUTPUT='wg0 wg1 wg2 wg3 wg4'
  run run_zsh '
    source "$VPN_PROBE_SETUP"
    _VPN_MAX_PREVIEW_BYTES=16
    _vpn_get_active_interfaces > "$HOME/interfaces.stdout"
  '

  [ "$status" -eq 1 ]
  [ ! -s "$HOME/interfaces.stdout" ]
  [ "$(cat "$VPN_PROBE_LOG")" = 'wg:direct:show interfaces' ]
}

@test "vpn probe recovery: live access state interruptions stop before fallback or authentication" {
  local helper expected
  for helper in _vpn_wg_access_state _vpn_ensure_wg_access; do
    export VPN_PROBE_HELPER="$helper"
    for expected in 130 143; do
      export VPN_PROBE_DIRECT_RC="$expected"
      : > "$VPN_PROBE_LOG"
      run run_zsh 'source "$VPN_PROBE_SETUP"; "$VPN_PROBE_HELPER"'

      [ "$status" -eq "$expected" ]
      [ "$output" = '' ]
      [ "$(cat "$VPN_PROBE_LOG")" = 'wg:direct:show interfaces' ]
    done
  done
}

@test "vpn probe recovery: live access state preserves an interrupted sudo cache probe" {
  export VPN_PROBE_DIRECT_RC=23
  local expected
  for expected in 130 143; do
    export VPN_PROBE_CACHE_RC="$expected"
    : > "$VPN_PROBE_LOG"
    run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_ensure_wg_access'

    [ "$status" -eq "$expected" ]
    [ "$output" = '' ]
    [ "$(cat "$VPN_PROBE_LOG")" = $'wg:direct:show interfaces\nsudo:-n true' ]
  done
}

@test "vpn probe recovery: locked live access preserves authentication interruption" {
  export VPN_PROBE_DIRECT_RC=23 VPN_PROBE_CACHE_RC=1
  local expected
  for expected in 130 143; do
    export VPN_PROBE_AUTH_RC="$expected"
    : > "$VPN_PROBE_LOG"
    run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_ensure_wg_access'

    [ "$status" -eq "$expected" ]
    [[ "$output" != *'unlocked'* ]]
    [ "$(cat "$VPN_PROBE_LOG")" = $'wg:direct:show interfaces\nsudo:-n true\nsudo:-n true\nsudo:-v' ]
  done
}

@test "vpn probe recovery: protected profile access preserves interrupted cache checks" {
  [ "$(id -u)" -ne 0 ] || skip 'Permission checks require an unprivileged test user'
  chmod 000 "$VPN_CONFIG_DIR"
  local helper expected
  for helper in _vpn_configs_access_state _vpn_ensure_profile_access; do
    export VPN_PROBE_HELPER="$helper"
    for expected in 130 143; do
      export VPN_PROBE_CACHE_RC="$expected"
      : > "$VPN_PROBE_LOG"
      run run_zsh 'source "$VPN_PROBE_SETUP"; "$VPN_PROBE_HELPER"'

      [ "$status" -eq "$expected" ]
      [ "$output" = '' ]
      [ "$(cat "$VPN_PROBE_LOG")" = 'sudo:-n true' ]
    done
  done
}

@test "vpn probe recovery: locked profile access preserves authentication interruption" {
  [ "$(id -u)" -ne 0 ] || skip 'Permission checks require an unprivileged test user'
  chmod 000 "$VPN_CONFIG_DIR"
  export VPN_PROBE_CACHE_RC=1
  local expected
  for expected in 130 143; do
    export VPN_PROBE_AUTH_RC="$expected"
    : > "$VPN_PROBE_LOG"
    run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_ensure_profile_access'

    [ "$status" -eq "$expected" ]
    [[ "$output" != *'unlocked'* ]]
    [ "$(cat "$VPN_PROBE_LOG")" = $'sudo:-n true\nsudo:-n true\nsudo:-v' ]
  done
}

@test "vpn probe recovery: protected profile existence interruptions stop without classifying the path" {
  [ "$(id -u)" -ne 0 ] || skip 'Permission checks require an unprivileged test user'
  setup_profile_probe
  chmod 000 "$VPN_CONFIG_DIR"
  local phase expected expected_calls
  for phase in presence symlink; do
    export VPN_PROBE_PROFILE_INTERRUPT="$phase"
    expected_calls=presence
    [ "$phase" != symlink ] || expected_calls=$'presence\nsymlink'
    for expected in 130 143; do
      export VPN_PROBE_PROFILE_STATUS="$expected"
      : > "$VPN_PROBE_PROFILE_LOG"
      run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_profile_path_state "$VPN_PROBE_PROFILE"'

      [ "$status" -eq "$expected" ]
      [ "$output" = '' ]
      [ "$(cat "$VPN_PROBE_PROFILE_LOG")" = "$expected_calls" ]
    done
  done
}

@test "vpn probe recovery: interrupted privileged safety inspection stops path and fingerprint probes" {
  setup_profile_probe
  export VPN_PROBE_PROFILE_INTERRUPT=safety
  local helper expected
  for helper in _vpn_profile_path_state _vpn_profile_file_fingerprint; do
    export VPN_PROBE_HELPER="$helper"
    for expected in 130 143; do
      export VPN_PROBE_PROFILE_STATUS="$expected"
      : > "$VPN_PROBE_PROFILE_LOG"
      run run_zsh 'source "$VPN_PROBE_SETUP"; "$VPN_PROBE_HELPER" "$VPN_PROBE_PROFILE"'

      [ "$status" -eq "$expected" ]
      [ "$output" = '' ]
      [ "$(cat "$VPN_PROBE_PROFILE_LOG")" = safety ]
    done
  done
}

@test "vpn probe recovery: direct checksum interruptions publish no profile fingerprint" {
  setup_profile_probe
  export VPN_PROBE_PROFILE_PROTECTED=0 VPN_PROBE_PROFILE_INTERRUPT=checksum
  local expected
  for expected in 130 143; do
    export VPN_PROBE_PROFILE_STATUS="$expected"
    : > "$VPN_PROBE_PROFILE_LOG"
    run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_profile_file_fingerprint "$VPN_PROBE_PROFILE"'

    [ "$status" -eq "$expected" ]
    [ "$output" = '' ]
    [ "$(cat "$VPN_PROBE_PROFILE_LOG")" = checksum ]
    [ ! -s "$VPN_PROBE_LOG" ]
  done
}

@test "vpn probe recovery: interrupted protected fingerprint phases stop all remaining probes" {
  setup_profile_probe
  local phase expected expected_calls
  for phase in metadata-before checksum metadata-after; do
    export VPN_PROBE_PROFILE_INTERRUPT="$phase"
    case "$phase" in
      metadata-before) expected_calls=$'safety\nmetadata-before' ;;
      checksum) expected_calls=$'safety\nmetadata-before\nchecksum' ;;
      metadata-after) expected_calls=$'safety\nmetadata-before\nchecksum\nmetadata-after' ;;
    esac
    for expected in 130 143; do
      export VPN_PROBE_PROFILE_STATUS="$expected"
      : > "$VPN_PROBE_PROFILE_LOG"
      printf '0\n' > "$VPN_PROBE_METADATA_COUNT"
      run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_profile_file_fingerprint "$VPN_PROBE_PROFILE"'

      [ "$status" -eq "$expected" ]
      [ "$output" = '' ]
      [ "$(cat "$VPN_PROBE_PROFILE_LOG")" = "$expected_calls" ]
    done
  done
}

@test "vpn probe recovery: protected fingerprints keep successful and ordinary failure behavior" {
  setup_profile_probe
  run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_profile_file_fingerprint "$VPN_PROBE_PROFILE"'
  [ "$status" -eq 0 ]
  [ "$output" = '1:2:0:600:1:33:100:100:123:33' ]
  [ "$(cat "$VPN_PROBE_PROFILE_LOG")" = $'safety\nmetadata-before\nchecksum\nmetadata-after' ]

  export VPN_PROBE_PROFILE_INTERRUPT=checksum VPN_PROBE_PROFILE_STATUS=47
  : > "$VPN_PROBE_PROFILE_LOG"
  printf '0\n' > "$VPN_PROBE_METADATA_COUNT"
  run run_zsh 'source "$VPN_PROBE_SETUP"; _vpn_profile_file_fingerprint "$VPN_PROBE_PROFILE"'
  [ "$status" -eq 1 ]
  [ "$output" = '' ]
  [ "$(cat "$VPN_PROBE_PROFILE_LOG")" = $'safety\nmetadata-before\nchecksum' ]
}
