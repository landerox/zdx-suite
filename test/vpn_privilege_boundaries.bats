#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  vpn_pin_kernel Linux
  unset WSL_DISTRO_NAME WSL_INTEROP
  export VPN_BOUNDARY_PARENT="$HOME/profile parent"
  export VPN_CONFIG_DIR="$VPN_BOUNDARY_PARENT/wireguard profiles"
  export VPN_CACHE_DIR="$HOME/.cache/zdx/vpn" VPN_MENU_REPORT_DIR="$HOME/reports"
  export VPN_BOUNDARY_AUTH="$HOME/authenticated" VPN_BOUNDARY_FLOW="$HOME/flow.stderr"
  export VPN_BOUNDARY_RACE="" VPN_BOUNDARY_FAIL="" VPN_BOUNDARY_AUTH_STATUS=0
  export VPN_BOUNDARY_MUTATIONS="$HOME/mutations"
  mkdir -p "$VPN_BOUNDARY_PARENT"
  chmod -- 700 "$VPN_BOUNDARY_PARENT"
  : > "$VPN_BOUNDARY_MUTATIONS"
  : > "$VPN_BOUNDARY_FLOW"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/sudo"
  cat >> "$TEST_MOCK_BIN/sudo" <<'MOCK'
{ printf 'sudo'; printf ' %q' "$@"; printf '\n'; } >> "$MOCK_SUDO_LOG"
[[ "$HOME" == "$TEST_TEMP_DIR/home" \
  && "$VPN_BOUNDARY_PARENT" == "$HOME/profile parent" \
  && "$VPN_CONFIG_DIR" == "$VPN_BOUNDARY_PARENT/wireguard profiles" \
  && "$VPN_BOUNDARY_AUTH" == "$HOME/authenticated" \
  && "$VPN_BOUNDARY_MUTATIONS" == "$HOME/mutations" \
  && -d "$VPN_BOUNDARY_PARENT" && ! -L "$VPN_BOUNDARY_PARENT" ]] || exit 98
if (( $# == 2 )) && [[ "$1" == -n && ( "$2" == true || "$2" == /usr/bin/true ) ]]; then
  [[ -f "$VPN_BOUNDARY_AUTH" ]]
  exit $?
fi
if (( $# == 1 )) && [[ "$1" == -v ]]; then
  printf 'AUTH_BOUNDARY\n' >&2
  [[ "$VPN_BOUNDARY_AUTH_STATUS" == 0 ]] || exit "$VPN_BOUNDARY_AUTH_STATUS"
  : > "$VPN_BOUNDARY_AUTH"
  case "$VPN_BOUNDARY_RACE" in
    directory) mkdir -m 755 -- "$VPN_CONFIG_DIR" ;;
    file) printf 'appeared\n' > "$VPN_CONFIG_DIR" ;;
    link) ln -s "$HOME/elsewhere" "$VPN_CONFIG_DIR" ;;
    parent)
      mv -- "$VPN_BOUNDARY_PARENT" "$HOME/parent-before-auth"
      mkdir -m 700 -- "$VPN_BOUNDARY_PARENT"
      ;;
    '') ;;
    *) exit 98 ;;
  esac
  exit 0
fi
(( $# >= 3 )) && [[ "$1" == -n && "$2" == -- \
  && -f "$VPN_BOUNDARY_AUTH" ]] || exit 98
shift 2
case "$1" in
  install|/usr/bin/install) operation=install ;;
  rm|/bin/rm) operation=rm ;;
  mv|/bin/mv) operation=mv ;;
  *) exit 98 ;;
esac
{ printf '%q' "$1"; printf ' %q' "${@:2}"; printf '\n'; } >> "$VPN_BOUNDARY_MUTATIONS"
case "$operation" in
  install)
    (( $# == 10 )) && [[ "$2" == -d && "$3" == -m && "$4" == 700 \
      && "$5" == -o && "$6" == 0 && "$7" == -g && "$8" == 0 \
      && "$9" == -- && "${10}" == "$VPN_CONFIG_DIR" \
      && ! -e "$VPN_CONFIG_DIR" && ! -L "$VPN_CONFIG_DIR" ]] || exit 98
    mkdir -m 700 -- "$VPN_CONFIG_DIR"
    ;;
  rm)
    (( $# == 3 )) && [[ "$2" == -- \
      && ( "$3" == "$VPN_CONFIG_DIR/wg0.conf" || "$3" == "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ) \
      && -d "$VPN_CONFIG_DIR" && ! -L "$VPN_CONFIG_DIR" \
      && -f "$3" && ! -L "$3" ]] || exit 98
    /bin/rm -- "$3"
    ;;
  mv)
    (( $# == 4 )) && [[ "$2" == -- \
      && -d "$VPN_CONFIG_DIR" && ! -L "$VPN_CONFIG_DIR" \
      && -f "$3" && ! -L "$3" && ! -e "$4" && ! -L "$4" ]] || exit 98
    case "$3|$4" in
      "$VPN_CONFIG_DIR/wg0.conf|$VPN_CONFIG_DIR/office.conf" \
      |"$VPN_CONFIG_DIR/office.conf|$VPN_CONFIG_DIR/wg0.conf") ;;
      "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu|$VPN_CONFIG_DIR/office.conf.bak-vpn-menu")
        [[ "$VPN_BOUNDARY_FAIL" != backup ]] || exit 1
        ;;
      *) exit 98 ;;
    esac
    /bin/mv -- "$3" "$4"
    ;;
  *) exit 98 ;;
esac
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/sudo"
}

teardown() {
  chmod -- 700 "$VPN_CONFIG_DIR" 2>/dev/null || true
  cleanup_sandbox
}

boundary_profiles() {
  mkdir -p "$VPN_CONFIG_DIR"
  chmod -- 700 "$VPN_CONFIG_DIR"
  printf '[Interface]\nPrivateKey = FIXTURE=\nAddress = 10.0.0.2/24\n[Peer]\nPublicKey = PEER=\nAllowedIPs = 0.0.0.0/0\n' > "$VPN_CONFIG_DIR/wg0.conf"
  cp "$VPN_CONFIG_DIR/wg0.conf" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  chmod -- 600 "$VPN_CONFIG_DIR"/*
}

@test "vpn privilege boundaries: supplied invalid names fail before any runtime access through direct and routed calls" {
  local route action
  for route in direct routed; do
    export VPN_BOUNDARY_ROUTE="$route"
    for action in create remove rename-old rename-new; do
      export VPN_BOUNDARY_ACTION="$action"
      run run_zsh '
        _vpn_require_platform() { print -r -- reached > "$HOME/runtime"; return 91; }
        local -a invocation=()
        case "$VPN_BOUNDARY_ACTION" in
          create) invocation=(vpn-profile-create bad/name) ;;
          remove) invocation=(vpn-profile-remove bad/name --yes) ;;
          rename-old) invocation=(vpn-profile-rename bad/name office --yes) ;;
          rename-new) invocation=(vpn-profile-rename wg0 bad/name --yes) ;;
        esac
        if [[ "$VPN_BOUNDARY_ROUTE" == routed ]]; then
          vpn-menu "${invocation[@]}"
        else
          "${invocation[@]}"
        fi
      '
      [ "$status" -eq 2 ]
      [ ! -e "$HOME/runtime" ]
      [ ! -e "$VPN_CONFIG_DIR" ]
      [ ! -s "$MOCK_SUDO_LOG" ]
    done
  done
}

@test "vpn privilege boundaries: invalid create never authenticates or creates its missing directory" {
  run run_zsh '
    _vpn_confirm_ask() { return 0; }
    vpn-profile-create bad/name >"$HOME/create.stdout" 2>"$VPN_BOUNDARY_FLOW"
  '
  [ "$status" -eq 2 ]
  [ ! -e "$VPN_CONFIG_DIR" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -s "$VPN_BOUNDARY_MUTATIONS" ]
  [ ! -s "$HOME/create.stdout" ]
}

@test "vpn privilege boundaries: invalid rename and remove never unlock a locked directory" {
  boundary_profiles
  chmod -- 000 "$VPN_CONFIG_DIR"
  local action
  for action in remove rename-old rename-new; do
    export VPN_BOUNDARY_ACTION="$action"
    run run_zsh '
      case "$VPN_BOUNDARY_ACTION" in
        remove) vpn-profile-remove bad/name --yes ;;
        rename-old) vpn-profile-rename bad/name office --yes ;;
        rename-new) vpn-profile-rename wg0 bad/name --yes ;;
      esac
    '
    [ "$status" -eq 2 ]
    [ ! -s "$MOCK_SUDO_LOG" ]
  done
}

@test "vpn privilege boundaries: a creation target appearing during authentication is never installed" {
  mkdir -m 755 "$HOME/elsewhere"
  local race
  for race in directory file link; do
    export VPN_BOUNDARY_RACE="$race"
    run run_zsh '
      _vpn_confirm_ask() { return 0; }
      _vpn_ensure_profile_dir >"$HOME/create.stdout" 2>"$VPN_BOUNDARY_FLOW"
    '
    [ "$status" -eq 1 ]
    [ ! -s "$VPN_BOUNDARY_MUTATIONS" ]
    [ ! -s "$HOME/create.stdout" ]
    [ "$(file_mode "$HOME/elsewhere")" = 755 ]
    grep -qF 'appeared' "$VPN_BOUNDARY_FLOW"
    if [ -L "$VPN_CONFIG_DIR" ] || [ -f "$VPN_CONFIG_DIR" ]; then
      rm -- "$VPN_CONFIG_DIR"
    else
      rmdir -- "$VPN_CONFIG_DIR"
    fi
    rm -f -- "$VPN_BOUNDARY_AUTH"
  done
}

@test "vpn privilege boundaries: creation refuses a replaced existing parent after authentication" {
  export VPN_BOUNDARY_RACE=parent
  run run_zsh '
    _vpn_confirm_ask() { return 0; }
    _vpn_ensure_profile_dir >"$HOME/create.stdout" 2>"$VPN_BOUNDARY_FLOW"
  '
  [ "$status" -eq 1 ]
  [ ! -e "$VPN_CONFIG_DIR" ]
  [ ! -s "$VPN_BOUNDARY_MUTATIONS" ]
  grep -qF 'parent changed' "$VPN_BOUNDARY_FLOW"
}

@test "vpn privilege boundaries: stable missing directory creation announces exact argv before authenticating once" {
  run run_zsh '
    _vpn_confirm_ask() { return 0; }
    _vpn_ensure_profile_dir >"$HOME/create.stdout" 2>"$VPN_BOUNDARY_FLOW"
  '
  [ "$status" -eq 0 ]
  [ -d "$VPN_CONFIG_DIR" ]
  [ "$(file_mode "$VPN_CONFIG_DIR")" = 700 ]
  [ "$(grep -c '^sudo -v$' "$MOCK_SUDO_LOG")" -eq 1 ]
  [ "$(wc -l < "$VPN_BOUNDARY_MUTATIONS" | tr -d ' ')" -eq 1 ]
  local operation announce_line auth_line
  operation=$(cat "$VPN_BOUNDARY_MUTATIONS")
  grep -qF "Privileged operation: $operation" "$VPN_BOUNDARY_FLOW"
  announce_line=$(grep -nF "Privileged operation: $operation" "$VPN_BOUNDARY_FLOW" | cut -d: -f1)
  auth_line=$(grep -nF AUTH_BOUNDARY "$VPN_BOUNDARY_FLOW" | cut -d: -f1)
  [ "$announce_line" -lt "$auth_line" ]
  [ ! -s "$HOME/create.stdout" ]
}

boundary_completion() {
  run zsh -f -c '
    emulate -R zsh
    if [[ "$VPN_BOUNDARY_LOADED" == yes ]]; then
      source "$TEST_SUITE_ROOT/functions.zsh" || exit 90
    fi
    typeset -ga words=(vpn-on)
    _arguments() {
      local spec
      for spec in "$@"; do
        [[ "$spec" == 1:profile:_vpn_menu_profiles ]] && _vpn_menu_profiles
      done
      return 0
    }
    _describe() { print -rl -- "${(@P)${@[-1]}}"; }
    source "$TEST_SUITE_ROOT/completions/_vpn-menu"
  '
}

@test "vpn privilege boundaries: writable profile directories are unsafe and absent from inventories and completion" {
  boundary_profiles
  local mode loaded
  for mode in 770 777; do
    : > "$MOCK_SUDO_LOG"
    chmod -- "$mode" "$VPN_CONFIG_DIR"
    run run_zsh '
      local result observation_rc=0
      [[ "$(_vpn_configs_access_state)" == unsafe ]] || return 41
      result=$(_vpn_get_configs 2>/dev/null) || observation_rc=$?
      [[ "$observation_rc" == 1 && -z "$result" ]] || return 42
      _vpn_state_load
      [[ "$(_vpn_state_profiles_text)" == unsafe ]] || return 43
    '
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    for loaded in yes no; do
      export VPN_BOUNDARY_LOADED="$loaded"
      boundary_completion
      [ "$status" -eq 0 ]
      [ -z "$output" ]
    done
    # The header independently observes the existing cached-access protocol.
    # Inventory and completion must add no credential request or payload.
    [ "$(cat "$MOCK_SUDO_LOG")" = 'sudo -n true' ]
  done
}

@test "vpn privilege boundaries: safe directories retain direct inventories and completion without sudo" {
  boundary_profiles
  run run_zsh '
    [[ "$(_vpn_configs_access_state)" == direct ]] || return 41
    [[ "$(_vpn_get_configs)" == wg0 ]] || return 42
  '
  [ "$status" -eq 0 ]
  local loaded
  for loaded in yes no; do
    export VPN_BOUNDARY_LOADED="$loaded"
    boundary_completion
    [ "$status" -eq 0 ]
    [ "$output" = wg0 ]
  done
  [ ! -s "$MOCK_SUDO_LOG" ]
}

boundary_assert_announcements() {
  local operation announce_line auth_line
  auth_line=$(grep -nF AUTH_BOUNDARY "$VPN_BOUNDARY_FLOW" | head -n 1 | cut -d: -f1)
  [ -n "$auth_line" ]
  while IFS= read -r operation; do
    grep -qF "Privileged operation: $operation" "$VPN_BOUNDARY_FLOW"
    announce_line=$(grep -nF "Privileged operation: $operation" "$VPN_BOUNDARY_FLOW" | head -n 1 | cut -d: -f1)
    [ "$announce_line" -lt "$auth_line" ]
  done < "$VPN_BOUNDARY_MUTATIONS"
}

@test "vpn privilege boundaries: remove announces each exact profile and backup argv before credentials" {
  boundary_profiles
  run run_zsh '
    _vpn_get_active_interfaces() { return 0; }
    vpn-profile-remove wg0 --with-backup --yes >"$HOME/remove.stdout" 2>"$VPN_BOUNDARY_FLOW"
  '
  [ "$status" -eq 0 ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]
  [ "$(wc -l < "$VPN_BOUNDARY_MUTATIONS" | tr -d ' ')" -eq 2 ]
  [ ! -s "$HOME/remove.stdout" ]
  boundary_assert_announcements
}

@test "vpn privilege boundaries: rename announces profile backup and conditional rollback argv before credentials" {
  boundary_profiles
  run run_zsh '
    _vpn_get_active_interfaces() { return 0; }
    vpn-profile-rename wg0 office --yes >"$HOME/rename.stdout" 2>"$VPN_BOUNDARY_FLOW"
  '
  [ "$status" -eq 0 ]
  [ -f "$VPN_CONFIG_DIR/office.conf" ]
  [ -f "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu" ]
  [ "$(wc -l < "$VPN_BOUNDARY_MUTATIONS" | tr -d ' ')" -eq 2 ]
  [ ! -s "$HOME/rename.stdout" ]
  boundary_assert_announcements
  grep -qF 'rollback if backup rename fails' "$VPN_BOUNDARY_FLOW"
}

@test "vpn privilege boundaries: executed rollback was announced before the original authentication" {
  boundary_profiles
  export VPN_BOUNDARY_FAIL=backup
  run run_zsh '
    _vpn_get_active_interfaces() { return 0; }
    vpn-profile-rename wg0 office --yes >"$HOME/rename.stdout" 2>"$VPN_BOUNDARY_FLOW"
  '
  [ "$status" -eq 1 ]
  [ -f "$VPN_CONFIG_DIR/wg0.conf" ]
  [ -f "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]
  [ ! -e "$VPN_CONFIG_DIR/office.conf" ]
  [ "$(wc -l < "$VPN_BOUNDARY_MUTATIONS" | tr -d ' ')" -eq 3 ]
  boundary_assert_announcements
}

@test "vpn privilege boundaries: file operations are disclosed before an active tunnel requests credentials" {
  boundary_profiles
  run run_zsh '
    _vpn_get_active_interfaces() { print -r -- wg0; }
    _vpn_tunnel_down() {
      _vpn_announce_privileged "fixture tunnel disconnect wg0"
      _vpn_ensure_sudo_access "Fixture tunnel disconnect"
    }
    vpn-profile-rename wg0 office --yes >"$HOME/rename.stdout" 2>"$VPN_BOUNDARY_FLOW"
  '
  [ "$status" -eq 0 ]
  [ -f "$VPN_CONFIG_DIR/office.conf" ]
  [ "$(grep -c '^sudo -v$' "$MOCK_SUDO_LOG")" -eq 1 ]
  boundary_assert_announcements
}

# The restricted tool namespace may map the real filesystem-root owner to
# nobody. Model the suite's documented uid-0 root policy while retaining each
# actual file mode, user-owned file, link target and ancestor observation.
boundary_trust_context() {
  export VPN_BOUNDARY_TRUST_CONTEXT="$HOME/trust-context.zsh"
  cat > "$VPN_BOUNDARY_TRUST_CONTEXT" <<'ZSH'
emulate -R zsh
zmodload -F zsh/stat b:zstat || return 90
local -A root_metadata=()
builtin zstat -LH root_metadata -- / || return 91
typeset -gi VPN_BOUNDARY_ROOT_UID=${root_metadata[uid]}
zstat() {
  builtin zstat "$@" || return
  local array_name="" argument="" previous=""
  for argument in "$@"; do
    [[ "$previous" == -*H ]] && array_name="$argument"
    previous="$argument"
  done
  [[ -n "$array_name" ]] || return 0
  local -A observed=("${(@kvP)array_name}")
  if (( observed[uid] == VPN_BOUNDARY_ROOT_UID )); then
    observed[uid]=0
    set -A "$array_name" "${(@kv)observed}"
  fi
}
ZSH
}

boundary_link_chain() {
  boundary_trust_context
  export VPN_BOUNDARY_TOOLS="$HOME/tool-chain"
  mkdir -p "$VPN_BOUNDARY_TOOLS/bin" "$VPN_BOUNDARY_TOOLS/real" "$VPN_BOUNDARY_TOOLS/shared"
  chmod -- 700 "$VPN_BOUNDARY_TOOLS" "$VPN_BOUNDARY_TOOLS/bin" "$VPN_BOUNDARY_TOOLS/real"
  printf '#!%s\nexit 0\n' "$BASH" > "$VPN_BOUNDARY_TOOLS/real/tool"
  chmod -- 700 "$VPN_BOUNDARY_TOOLS/real/tool"
  ln -s ../real/tool "$VPN_BOUNDARY_TOOLS/shared/hop"
  ln -s ../shared/hop "$VPN_BOUNDARY_TOOLS/bin/tool"
}

@test "vpn privilege boundaries: a writable intermediate link target is refused in standalone and loaded validators" {
  boundary_link_chain
  chmod -- 777 "$VPN_BOUNDARY_TOOLS/shared"
  local loading
  for loading in standalone core; do
    export VPN_BOUNDARY_LOADING="$loading"
    run zsh -f -c '
      emulate -R zsh
      if [[ "$VPN_BOUNDARY_LOADING" == core ]]; then
        source "$TEST_SUITE_ROOT/functions.zsh" || exit 90
      else
        source "$TEST_SUITE_ROOT/functions/vpn-common.zsh" || exit 90
      fi
      source "$VPN_BOUNDARY_TRUST_CONTEXT" || exit 91
      _vpn_trusted_executable --user "$VPN_BOUNDARY_TOOLS/bin/tool"
    '
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn privilege boundaries: safe relative link chains remain trusted without weakening root-only mode" {
  boundary_link_chain
  chmod -- 700 "$VPN_BOUNDARY_TOOLS/shared"
  run run_zsh '
    source "$VPN_BOUNDARY_TRUST_CONTEXT" || return 90
    _vpn_trusted_executable --user "$VPN_BOUNDARY_TOOLS/bin/tool" || {
      print -u2 -r -- "safe chain resolves to ${${:-$VPN_BOUNDARY_TOOLS/bin/tool}:A}"
      _vpn_trusted_dir_chain --user "$VPN_BOUNDARY_TOOLS/real" || print -u2 -r -- "real directory chain refused"
      command ls -ld -- "$VPN_BOUNDARY_TOOLS" "$VPN_BOUNDARY_TOOLS/bin" "$VPN_BOUNDARY_TOOLS/shared" "$VPN_BOUNDARY_TOOLS/real" "$VPN_BOUNDARY_TOOLS/real/tool" >&2
      return 41
    }
    if _vpn_trusted_executable "$VPN_BOUNDARY_TOOLS/bin/tool"; then return 42; fi
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "vpn privilege boundaries: Darwin tunnel tools refuse a writable hop inside the wg-quick target" {
  boundary_trust_context
  vpn_darwin_fixture
  mkdir -p "$VPN_BREW/Cellar" "$HOME/shared-tool-hop"
  chmod -- 755 "$VPN_BREW/Cellar"
  chmod -- 777 "$HOME/shared-tool-hop"
  mv -- "$VPN_BREW/bin/wg-quick" "$VPN_BREW/Cellar/wg-quick"
  ln -s "$VPN_BREW/Cellar/wg-quick" "$HOME/shared-tool-hop/hop"
  ln -s "$HOME/shared-tool-hop/hop" "$VPN_BREW/bin/wg-quick"
  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    source "$VPN_BOUNDARY_TRUST_CONTEXT" || return 90
    local -a reply=()
    _vpn_darwin_tunnel_tools
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing wg-quick"* ]]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -s "$VPN_WG_QUICK_LOG" ]
}

@test "vpn privilege boundaries: Darwin retains a safe chained Homebrew tool layout" {
  boundary_trust_context
  vpn_darwin_fixture
  mkdir -p "$VPN_BREW/Cellar" "$HOME/safe-tool-hop"
  chmod -- 755 "$VPN_BREW/Cellar"
  chmod -- 700 "$HOME/safe-tool-hop"
  mv -- "$VPN_BREW/bin/wg-quick" "$VPN_BREW/Cellar/wg-quick"
  ln -s "$VPN_BREW/Cellar/wg-quick" "$HOME/safe-tool-hop/hop"
  ln -s "$HOME/safe-tool-hop/hop" "$VPN_BREW/bin/wg-quick"
  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    source "$VPN_BOUNDARY_TRUST_CONTEXT" || return 90
    local -a reply=()
    _vpn_darwin_tunnel_tools || return 41
    (( ${#reply} == 2 )) || return 42
    [[ "${reply[1]}" == /* && "${reply[2]}" == "$VPN_BREW/bin/wg-quick" ]] || return 43
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -s "$VPN_WG_QUICK_LOG" ]
}

@test "vpn privilege boundaries: Darwin remove announces the exact pinned filesystem primitives" {
  boundary_profiles
  vpn_darwin_fixture
  run run_zsh '
    source "$VPN_DARWIN_SETUP"
    _vpn_get_active_interfaces() { return 0; }
    vpn-profile-remove wg0 --with-backup --yes >"$HOME/remove.stdout" 2>"$VPN_BOUNDARY_FLOW"
  '
  [ "$status" -eq 0 ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]
  [ "$(grep -c '^/bin/rm -- ' "$VPN_BOUNDARY_MUTATIONS")" -eq 2 ]
  boundary_assert_announcements
}

@test "vpn privilege boundaries: mode000 parent hiding an existing profile directory refuses create before consent or authentication" {
  boundary_profiles
  printf '# F417-R2-EXISTING-PROFILE-CANARY\n' >> "$VPN_CONFIG_DIR/wg0.conf"
  cp "$VPN_CONFIG_DIR/wg0.conf" "$HOME/r2.expected-profile"
  cp "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" "$HOME/r2.expected-backup"
  chmod -- 000 "$VPN_BOUNDARY_PARENT"
  run run_zsh '
    _vpn_confirm_ask() { print -r -- prompt >> "$HOME/r2.prompt"; return 0; }
    vpn-profile-create office >"$HOME/r2.stdout" 2>"$VPN_BOUNDARY_FLOW"
    local create_rc=$? access_rc=0 observed_access=""
    observed_access=$(_vpn_configs_access_state) || access_rc=$?
    print -r -- "$observed_access" > "$HOME/r2.access-state"
    print -r -- "$access_rc" > "$HOME/r2.access-status"
    return "$create_rc"
  '
  local create_status="$status" observed_parent_mode="" mode_rc=0
  observed_parent_mode=$(file_mode "$VPN_BOUNDARY_PARENT") || mode_rc=$?
  chmod -- 700 "$VPN_BOUNDARY_PARENT"
  local observed_access="unrecorded" access_rc=99 prompt_count=0 auth_count=0 install_count=0
  if [ -f "$HOME/r2.access-state" ]; then observed_access=$(cat "$HOME/r2.access-state"); fi
  if [ -f "$HOME/r2.access-status" ]; then access_rc=$(cat "$HOME/r2.access-status"); fi
  if [ -f "$HOME/r2.prompt" ]; then prompt_count=$(wc -l < "$HOME/r2.prompt" | tr -d ' '); fi
  auth_count=$(grep -c '^sudo -v$' "$MOCK_SUDO_LOG" || true)
  install_count=$(grep -c '^install ' "$VPN_BOUNDARY_MUTATIONS" || true)
  printf 'R2 mode000: status=%s access=%s access-status=%s parent-mode=%s prompt=%s auth=%s install=%s\n' \
    "$create_status" "$observed_access" "$access_rc" "$observed_parent_mode" "$prompt_count" "$auth_count" "$install_count" >&2
  cat "$VPN_BOUNDARY_FLOW" >&2
  [ "$mode_rc" -eq 0 ]
  [ "$create_status" -eq 1 ]
  [ "$access_rc" -eq 0 ]
  [ "$observed_access" = unsafe ]
  [ "$observed_parent_mode" = 0 ]
  [ "$prompt_count" -eq 0 ]
  [ "$auth_count" -eq 0 ]
  [ "$install_count" -eq 0 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -s "$VPN_BOUNDARY_MUTATIONS" ]
  [ ! -s "$HOME/r2.stdout" ]
  [ "$(file_mode "$VPN_CONFIG_DIR")" = 700 ]
  cmp "$HOME/r2.expected-profile" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/r2.expected-backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  [ "$(file_mode "$VPN_CONFIG_DIR/wg0.conf")" = 600 ]
  [ "$(file_mode "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu")" = 600 ]
}

@test "vpn privilege boundaries: mode0600 parent hiding an existing profile directory refuses create before consent or authentication" {
  boundary_profiles
  printf '# F417-R2-EXISTING-PROFILE-CANARY\n' >> "$VPN_CONFIG_DIR/wg0.conf"
  cp "$VPN_CONFIG_DIR/wg0.conf" "$HOME/r2.expected-profile"
  cp "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" "$HOME/r2.expected-backup"
  chmod -- 600 "$VPN_BOUNDARY_PARENT"
  run run_zsh '
    _vpn_confirm_ask() { print -r -- prompt >> "$HOME/r2.prompt"; return 0; }
    vpn-profile-create office >"$HOME/r2.stdout" 2>"$VPN_BOUNDARY_FLOW"
    local create_rc=$? access_rc=0 observed_access=""
    observed_access=$(_vpn_configs_access_state) || access_rc=$?
    print -r -- "$observed_access" > "$HOME/r2.access-state"
    print -r -- "$access_rc" > "$HOME/r2.access-status"
    return "$create_rc"
  '
  local create_status="$status" observed_parent_mode="" mode_rc=0
  observed_parent_mode=$(file_mode "$VPN_BOUNDARY_PARENT") || mode_rc=$?
  chmod -- 700 "$VPN_BOUNDARY_PARENT"
  local observed_access="unrecorded" access_rc=99 prompt_count=0 auth_count=0 install_count=0
  if [ -f "$HOME/r2.access-state" ]; then observed_access=$(cat "$HOME/r2.access-state"); fi
  if [ -f "$HOME/r2.access-status" ]; then access_rc=$(cat "$HOME/r2.access-status"); fi
  if [ -f "$HOME/r2.prompt" ]; then prompt_count=$(wc -l < "$HOME/r2.prompt" | tr -d ' '); fi
  auth_count=$(grep -c '^sudo -v$' "$MOCK_SUDO_LOG" || true)
  install_count=$(grep -c '^install ' "$VPN_BOUNDARY_MUTATIONS" || true)
  printf 'R2 mode0600: status=%s access=%s access-status=%s parent-mode=%s prompt=%s auth=%s install=%s\n' \
    "$create_status" "$observed_access" "$access_rc" "$observed_parent_mode" "$prompt_count" "$auth_count" "$install_count" >&2
  cat "$VPN_BOUNDARY_FLOW" >&2
  [ "$mode_rc" -eq 0 ]
  [ "$create_status" -eq 1 ]
  [ "$access_rc" -eq 0 ]
  [ "$observed_access" = unsafe ]
  [ "$observed_parent_mode" = 600 ]
  [ "$prompt_count" -eq 0 ]
  [ "$auth_count" -eq 0 ]
  [ "$install_count" -eq 0 ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -s "$VPN_BOUNDARY_MUTATIONS" ]
  [ ! -s "$HOME/r2.stdout" ]
  [ "$(file_mode "$VPN_CONFIG_DIR")" = 700 ]
  cmp "$HOME/r2.expected-profile" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/r2.expected-backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  [ "$(file_mode "$VPN_CONFIG_DIR/wg0.conf")" = 600 ]
  [ "$(file_mode "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu")" = 600 ]
}
