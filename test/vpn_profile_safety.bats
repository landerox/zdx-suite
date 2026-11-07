#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  load vpn_test_helper
  vpn_pin_kernel Linux
  unset WSL_DISTRO_NAME WSL_INTEROP
  export VPN_CONFIG_DIR="$HOME/wireguard" VPN_CACHE_DIR="$HOME/.cache/zdx/vpn"
  export VPN_MENU_REPORT_DIR="$HOME/vpn-stats"
  export VPN_SAFETY_CONTEXT="$HOME/profile-context.zsh"
  export VPN_SAFETY_SUDO="$HOME/sudo-recorder" VPN_SAFETY_AUTH="$HOME/authenticated"
  export VPN_SAFETY_MUTATIONS="$HOME/mutations.log" VPN_SAFETY_PROMPTS="$HOME/prompts.log"
  export VPN_SAFETY_STDOUT="$HOME/stdout.log" VPN_SAFETY_TUNNELS="$HOME/tunnels.log"
  export VPN_SAFETY_RACE="" VPN_SAFETY_FAIL="" VPN_SAFETY_ACTIVE=""
  export MOCK_SUDO_ALLOW='true,__validate__,test,install,mktemp,ln,rm,mv,wg-quick'
  mkdir -p "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$HOME/expected"
  chmod -- 700 "$VPN_CONFIG_DIR" "$VPN_CACHE_DIR" "$HOME/expected"
  profile_safety_write wg0 10.0.0.2
  profile_safety_write wg9 10.0.0.9
  cp "$VPN_CONFIG_DIR/wg0.conf" "$HOME/expected/live"
  cp "$VPN_CONFIG_DIR/wg9.conf" "$HOME/expected/unrelated"
  profile_safety_write wg0 10.9.9.9
  mv "$VPN_CONFIG_DIR/wg0.conf" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  cp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cp "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" "$HOME/expected/backup"
  printf 'wg0\n' > "$VPN_CACHE_DIR/default-iface"
  printf 'wg0\n' > "$VPN_CACHE_DIR/last-iface"
  chmod -- 600 "$VPN_CONFIG_DIR"/* "$VPN_CACHE_DIR"/*
  : > "$VPN_SAFETY_MUTATIONS"
  : > "$VPN_SAFETY_PROMPTS"
  : > "$VPN_SAFETY_TUNNELS"
  cp "$TEST_MOCK_BIN/sudo" "$VPN_SAFETY_SUDO"

  # Keep the existing allowlisted recorder. This proxy models a cold timestamp,
  # observable authentication races and selected failures on sandbox resources.
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/sudo"
  cat >> "$TEST_MOCK_BIN/sudo" <<'MOCK'
request=("$@")
record_refusal() {
  { printf 'sudo'; printf ' %q' "$@"; printf '\n'; } >> "$MOCK_SUDO_LOG"
}
reject_request() {
  record_refusal "${request[@]}"
  exit 98
}
[[ "$HOME" == "$TEST_TEMP_DIR/home" \
  && "$VPN_CONFIG_DIR" == "$HOME/wireguard" \
  && "$VPN_SAFETY_SUDO" == "$HOME/sudo-recorder" \
  && -d "$VPN_CONFIG_DIR" && ! -L "$VPN_CONFIG_DIR" ]] || reject_request

# Accept only the suite's exact authentication and timestamp protocols.
if (( $# == 2 )) && [[ "$1" == -n && "$2" == true ]]; then
  if [[ ! -e "$VPN_SAFETY_AUTH" ]]; then
    record_refusal "$@"
    exit 1
  fi
  exec "$VPN_SAFETY_SUDO" "$@"
fi
if (( $# == 1 )) && [[ "$1" == -v ]]; then
  "$VPN_SAFETY_SUDO" "$@" || exit $?
  printf 'AUTH_BOUNDARY\n' >&2
  : > "$VPN_SAFETY_AUTH"
  case "$VPN_SAFETY_RACE" in
    source) printf '# changed during authentication\n' >> "$VPN_CONFIG_DIR/wg0.conf" ;;
    target) cp "$HOME/expected/unrelated" "$VPN_CONFIG_DIR/office.conf" ;;
    backup) printf '# changed during authentication\n' >> "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ;;
    state)
      mv -- "$VPN_CACHE_DIR" "$HOME/cache-before-auth"
      ln -s "$HOME/cache-before-auth" "$VPN_CACHE_DIR"
      ;;
    '') ;;
    *) reject_request ;;
  esac
  exit 0
fi
(( $# >= 3 )) && [[ "$1" == -n && "$2" == -- ]] || reject_request
shift 2
operation="$1"

# Validate operand positions, not every token: modes and option words never
# become paths. Refuse relative/traversing paths and every inner/final symlink.
profile_operand() {
  local operand="$1" cursor="$1"
  [[ "$operand" == "$VPN_CONFIG_DIR/"* && "$operand" != *[[:cntrl:]]* \
    && "$operand" != *'//'* && "$operand" != */../* && "$operand" != */.. \
    && "$operand" != */./* && "$operand" != */. && "$operand" != */ ]] || return 1
  while [[ "$cursor" != "$VPN_CONFIG_DIR" ]]; do
    [[ ! -L "$cursor" ]] || return 1
    cursor="${cursor%/*}"
  done
}
case "$operation" in
  mv)
    if (( $# == 4 )) && [[ "$2" == -- ]]; then
      profile_operand "$3" && profile_operand "$4" || reject_request
    elif (( $# == 5 )) && [[ "$2" == -f && "$3" == -- ]]; then
      profile_operand "$4" && profile_operand "$5" || reject_request
    else
      reject_request
    fi
    ;;
  rm)
    (( $# == 3 )) && [[ "$2" == -- ]] \
      && profile_operand "$3" || reject_request
    ;;
  install)
    (( $# == 10 )) && [[ "$2" == -m && "$3" == 600 && "$4" == -o \
      && "$5" == 0 && "$6" == -g && "$7" == 0 && "$8" == -- ]] \
      && profile_operand "$9" && profile_operand "${10}" || reject_request
    ;;
  mktemp)
    (( $# == 2 )) && [[ "$2" == "$VPN_CONFIG_DIR/.zdx-vpn-restore.XXXXXX" \
      || "$2" == "$VPN_CONFIG_DIR/.zdx-vpn-undo.XXXXXX" ]] \
      && profile_operand "$2" || reject_request
    ;;
  ln)
    (( $# == 4 )) && [[ "$2" == -- ]] \
      && profile_operand "$3" && profile_operand "$4" || reject_request
    ;;
  wg-quick)
    (( $# == 3 )) && [[ "$2" == down && "$3" == "$VPN_CONFIG_DIR/wg0.conf" ]] \
      && profile_operand "$3" || reject_request
    ;;
  *) reject_request ;;
esac

case "$operation" in
  mv|rm|install|mktemp|ln)
    { printf '%s' "$operation"; printf ' %q' "${@:2}"; printf '\n'; } >> "$VPN_SAFETY_MUTATIONS"
    printf 'EXEC_BOUNDARY %s\n' "$operation" >&2
    ;;
esac
if [[ "$VPN_SAFETY_FAIL" == backup && "$operation" == mv && "${3:-}" == "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]] \
  || [[ "$VPN_SAFETY_FAIL" == rollback && "$operation" == mv && ( "${3:-}" == "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" || "${3:-}" == "$VPN_CONFIG_DIR/office.conf" ) ]] \
  || [[ "$VPN_SAFETY_FAIL" == backup && "$operation" == rm && "${3:-}" == "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]] \
  || [[ "$VPN_SAFETY_FAIL" == profile && "$operation" == rm && "${3:-}" == "$VPN_CONFIG_DIR/wg0.conf" ]] \
  || [[ "$VPN_SAFETY_FAIL" == restore && "$operation" == mv && "${4:-}" == "$VPN_CONFIG_DIR/.zdx-vpn-restore."* ]]; then
  record_refusal -n -- "$@"
  exit 1
fi
exec "$VPN_SAFETY_SUDO" -n -- "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/sudo"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/wg"
  cat >> "$TEST_MOCK_BIN/wg" <<'MOCK'
case "$*" in
  'show interfaces') [[ -z "$VPN_SAFETY_ACTIVE" ]] || printf '%s\n' "$VPN_SAFETY_ACTIVE" ;;
  --version) printf 'wireguard-tools v1.0.20250521\n' ;;
  *) exit 97 ;;
esac
exit 0
MOCK
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/wg-quick"
  cat >> "$TEST_MOCK_BIN/wg-quick" <<'MOCK'
printf '%s\n' "$*" >> "$VPN_SAFETY_TUNNELS"
[[ "$*" == "down $VPN_CONFIG_DIR/wg0.conf" ]]
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/wg" "$TEST_MOCK_BIN/wg-quick"
  cat > "$VPN_SAFETY_CONTEXT" <<'ZSH'
emulate -R zsh
_vpn_is_wsl() { return 1; }
ZSH
}

teardown() {
  cleanup_sandbox
}

profile_safety_write() {
  printf '[Interface]\nPrivateKey = FIXTURE-PRIVATE-KEY=\nAddress = %s/24\n\n[Peer]\nPublicKey = FIXTURE-PEER=\nAllowedIPs = 10.77.0.0/16\nEndpoint = 192.0.2.1:51820\n' "$2" > "$VPN_CONFIG_DIR/$1.conf"  # gitleaks:allow -- intentional fixture key
  chmod -- 600 "$VPN_CONFIG_DIR/$1.conf"
}

profile_safety_originals() {
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  cmp "$HOME/expected/unrelated" "$VPN_CONFIG_DIR/wg9.conf"
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
  [ ! -e "$VPN_CONFIG_DIR/office.conf" ]
  [ ! -e "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu" ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.pre-restore" ]
}

profile_safety_passive() {
  profile_safety_originals
  [ ! -s "$VPN_SAFETY_STDOUT" ]
  if [[ "${1:-}" == cache-probe ]]; then
    [ "$(cat "$MOCK_SUDO_LOG")" = 'sudo -n true' ]
  else
    [ ! -s "$MOCK_SUDO_LOG" ]
  fi
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
  [ ! -s "$VPN_SAFETY_TUNNELS" ]
}

profile_safety_failure() {
  printf 'status=%s output=%s\n' "$status" "$output" >&2
  cat "$MOCK_SUDO_LOG" "$VPN_SAFETY_MUTATIONS" >&2
  false
}

@test "vpn profile safety: rename dry-run shows the exact profile backup and pointer plan" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-rename wg0 office --dry-run > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  [[ "$output" =~ 1[[:space:]]+wg0\.conf[[:space:]]+office\.conf ]]
  [[ "$output" =~ 2[[:space:]]+wg0\.conf\.bak-vpn-menu[[:space:]]+office\.conf\.bak-vpn-menu ]]
  [[ "$output" == *"default and last-used choices follow the rename"* ]]
  [[ "$output" == *"Dry run: 2 files planned; nothing was renamed."* ]]
  [[ "$output" != *"wg9.conf"* ]]
  profile_safety_passive
}

@test "vpn profile safety: rename decline cancels before authentication" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    _vpn_confirm_ask() { print -r -- "$1" >> "$VPN_SAFETY_PROMPTS"; return 1; }
    vpn-profile-rename wg0 office > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  [[ "$output" == *"Cancelled: nothing was renamed."* ]]
  [ "$(cat "$VPN_SAFETY_PROMPTS")" = 'Rename wg0 to office?' ]
  profile_safety_passive
}

@test "vpn profile safety: rename without a terminal fails closed" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-rename wg0 office > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"pass --yes to rename"* ]]
  profile_safety_passive
}

@test "vpn profile safety: rename yes authenticates once moves only planned files and follows pointers" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    _vpn_confirm_ask() { print unexpected >> "$VPN_SAFETY_PROMPTS"; return 1; }
    vpn-profile-rename wg0 office --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  [[ "$output" == *"Privileged operation: mv --"*"AUTH_BOUNDARY"*"EXEC_BOUNDARY mv"* ]]
  [ "$(grep -c '^sudo -v$' "$MOCK_SUDO_LOG")" -eq 1 ]
  [ "$(cat "$VPN_SAFETY_MUTATIONS")" = \
    "mv -- $VPN_CONFIG_DIR/wg0.conf $VPN_CONFIG_DIR/office.conf
mv -- $VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu $VPN_CONFIG_DIR/office.conf.bak-vpn-menu" ]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/office.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu"
  cmp "$HOME/expected/unrelated" "$VPN_CONFIG_DIR/wg9.conf"
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = office ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = office ]
  [ ! -s "$VPN_SAFETY_STDOUT" ]
  [ ! -s "$VPN_SAFETY_PROMPTS" ]
}

@test "vpn profile safety: rename revalidates changed source after actual sudo authentication" {
  export VPN_SAFETY_RACE=source
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-rename wg0 office --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"AUTH_BOUNDARY"*"changed after planning"* ]]
  [ -f "$VPN_CONFIG_DIR/wg0.conf" ]
  grep -Fq '# changed during authentication' "$VPN_CONFIG_DIR/wg0.conf"
  [ ! -e "$VPN_CONFIG_DIR/office.conf" ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
}

@test "vpn profile safety: rename refuses a target that appeared during authentication" {
  export VPN_SAFETY_RACE=target
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-rename wg0 office --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"appeared after authentication"* ]]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/unrelated" "$VPN_CONFIG_DIR/office.conf"
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
}

@test "vpn profile safety: rename restores the original name when backup move fails" {
  export VPN_SAFETY_FAIL=backup
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-rename wg0 office --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"Could not rename the backup"*"Rollback completed; nothing remains renamed."* ]]
  [ "$(cat "$VPN_SAFETY_MUTATIONS")" = \
    "mv -- $VPN_CONFIG_DIR/wg0.conf $VPN_CONFIG_DIR/office.conf
mv -- $VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu $VPN_CONFIG_DIR/office.conf.bak-vpn-menu
mv -- $VPN_CONFIG_DIR/office.conf $VPN_CONFIG_DIR/wg0.conf" ]
  profile_safety_originals
}

@test "vpn profile safety: rename reports the retained path when rollback also fails" {
  export VPN_SAFETY_FAIL=rollback
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-rename wg0 office --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"Rollback failed; the profile remains at $VPN_CONFIG_DIR/office.conf."* ]]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/office.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  [ ! -e "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu" ]
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
}

@test "vpn profile safety: rename reports pointer failures after keeping the completed file moves" {
  export VPN_SAFETY_RACE=state
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-rename wg0 office --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"Rename completed, but 2 saved choices could not be updated."* ]]
  [ -L "$VPN_CACHE_DIR" ]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/office.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/office.conf.bak-vpn-menu"
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
}

@test "vpn profile safety: rename yes never bypasses an existing target" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-rename wg0 wg9 --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"Target profile already exists or is unsafe"* ]]
  profile_safety_passive
}

@test "vpn profile safety: active rename dry-run includes disconnect but never changes a tunnel" {
  export VPN_SAFETY_ACTIVE=wg0
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-rename wg0 office --dry-run > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  [[ "$output" =~ 1[[:space:]]+disconnect[[:space:]]+wg0 ]]
  [[ "$output" =~ 2[[:space:]]+rename[[:space:]]+wg0\.conf[[:space:]]+office\.conf ]]
  [[ "$output" == *"nothing was disconnected or renamed"* ]]
  profile_safety_passive
}

@test "vpn profile safety: remove decline keeps both planned files and pointers" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    _vpn_confirm_ask() { print -r -- "$1" >> "$VPN_SAFETY_PROMPTS"; return 1; }
    vpn-profile-remove wg0 --with-backup > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  [ "$(cat "$VPN_SAFETY_PROMPTS")" = 'Remove VPN profile wg0?' ]
  [[ "$output" == *"Cancelled: nothing was removed."* ]]
  profile_safety_passive
}

@test "vpn profile safety: remove without a terminal fails closed" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-remove wg0 --with-backup > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"pass --yes to remove"* ]]
  profile_safety_passive
}

@test "vpn profile safety: remove revalidates changed profile after actual sudo authentication" {
  export VPN_SAFETY_RACE=source
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-remove wg0 --with-backup --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"AUTH_BOUNDARY"*"changed after planning"* ]]
  [ -f "$VPN_CONFIG_DIR/wg0.conf" ]
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
}

@test "vpn profile safety: failed backup removal reports partial results and clears only matching pointers" {
  export VPN_SAFETY_FAIL=backup
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-remove wg0 --with-backup --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"Removal completed with partial failures: 1 of 4 changes failed."* ]]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf" ]
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  cmp "$HOME/expected/unrelated" "$VPN_CONFIG_DIR/wg9.conf"
  [ ! -e "$VPN_CACHE_DIR/default-iface" ]
  [ ! -e "$VPN_CACHE_DIR/last-iface" ]
  [ "$(cat "$VPN_SAFETY_MUTATIONS")" = \
    "rm -- $VPN_CONFIG_DIR/wg0.conf
rm -- $VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]
}

@test "vpn profile safety: failed profile removal preserves pointers and never attempts the backup" {
  export VPN_SAFETY_FAIL=profile
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-profile-remove wg0 --with-backup --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"cached pointers were preserved"* ]]
  [ "$(cat "$VPN_SAFETY_MUTATIONS")" = "rm -- $VPN_CONFIG_DIR/wg0.conf" ]
  profile_safety_originals
}

@test "vpn profile safety: restore decline keeps the live backup and undo target" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    _vpn_confirm_ask() { print -r -- "$1" >> "$VPN_SAFETY_PROMPTS"; return 1; }
    vpn-config-restore wg0 > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  [ "$(cat "$VPN_SAFETY_PROMPTS")" = 'Restore the backup for wg0?' ]
  [[ "$output" == *"Cancelled: nothing was restored."* ]]
  profile_safety_passive cache-probe
}

@test "vpn profile safety: restore without a terminal fails closed" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-config-restore wg0 > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"pass --yes to restore"* ]]
  profile_safety_passive cache-probe
}

@test "vpn profile safety: public restore yes publishes the backup and retains the exact previous profile" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    _vpn_confirm_ask() { print unexpected >> "$VPN_SAFETY_PROMPTS"; return 1; }
    vpn-config-restore wg0 --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  [[ "$output" == *"Restore completed: 1 profile restored."* ]]
  [[ "$output" == *"Privileged operation: atomically install"*"AUTH_BOUNDARY"*"EXEC_BOUNDARY install"* ]]
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  cmp "$HOME/expected/unrelated" "$VPN_CONFIG_DIR/wg9.conf"
  [ "$(file_mode "$VPN_CONFIG_DIR/wg0.conf")" = 600 ]
  [ "$(grep -c '^sudo -v$' "$MOCK_SUDO_LOG")" -eq 1 ]
  grep -Fq "sudo -n -- install -m 600 -o 0 -g 0 -- $VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" "$MOCK_SUDO_LOG"
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
  [ ! -s "$VPN_SAFETY_STDOUT" ]
  [ ! -s "$VPN_SAFETY_PROMPTS" ]
}

@test "vpn profile safety: restore yes never follows an unsafe backup symlink" {
  rm "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  ln -s "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-config-restore wg0 --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"not a safe private regular file"* ]]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  [ -L "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu" ]
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.pre-restore" ]
  [ "$(cat "$MOCK_SUDO_LOG")" = 'sudo -n true' ]
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
}

@test "vpn profile safety: public restore revalidates the backup after actual sudo authentication" {
  export VPN_SAFETY_RACE=backup
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-config-restore wg0 --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"AUTH_BOUNDARY"*"changed after planning"* ]]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  [ ! -e "$VPN_CONFIG_DIR/wg0.conf.pre-restore" ]
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
}

@test "vpn profile safety: default clear decline keeps the exact saved choices" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    _vpn_confirm_ask() { print -r -- "$1" >> "$VPN_SAFETY_PROMPTS"; return 1; }
    vpn-default-clear > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  [ "$(cat "$VPN_SAFETY_PROMPTS")" = 'Clear the default VPN profile (wg0)?' ]
  [[ "$output" == *"Cancelled. The default profile was kept."* ]]
  profile_safety_passive
}

@test "vpn profile safety: default clear without a terminal fails closed" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-default-clear > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"pass --yes in a non-interactive shell"* ]]
  profile_safety_passive
}

@test "vpn profile safety: default clear yes removes only the default pointer without privilege" {
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    _vpn_confirm_ask() { print unexpected >> "$VPN_SAFETY_PROMPTS"; return 1; }
    vpn-default-clear --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  [[ "$output" == *"Cleared the default VPN profile (wg0)."* ]]
  [ ! -e "$VPN_CACHE_DIR/default-iface" ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  cmp "$HOME/expected/unrelated" "$VPN_CONFIG_DIR/wg9.conf"
  [ ! -s "$VPN_SAFETY_STDOUT" ]
  [ ! -s "$VPN_SAFETY_PROMPTS" ]
  [ ! -s "$MOCK_SUDO_LOG" ]
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
}

@test "vpn profile safety: failed public restore publication keeps live and undo bytes and cleans staging" {
  export VPN_SAFETY_FAIL=restore
  run run_zsh '
    source "$VPN_SAFETY_CONTEXT" || exit 90
    vpn-config-restore wg0 --yes > "$VPN_SAFETY_STDOUT"
  '
  [ "$status" -eq 1 ] || profile_safety_failure
  [[ "$output" == *"Failed to restore the backup for wg0."* ]]
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf"
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/wg0.conf.pre-restore"
  cmp "$HOME/expected/backup" "$VPN_CONFIG_DIR/wg0.conf.bak-vpn-menu"
  cmp "$HOME/expected/unrelated" "$VPN_CONFIG_DIR/wg9.conf"
  [ "$(cat "$VPN_CACHE_DIR/default-iface")" = wg0 ]
  [ "$(cat "$VPN_CACHE_DIR/last-iface")" = wg0 ]
  run run_zsh '
    local -a leftovers=("$VPN_CONFIG_DIR"/.zdx-vpn-*(ND))
    (( ${#leftovers} == 0 )) || exit 91
  '
  [ "$status" -eq 0 ]
  [ ! -s "$VPN_SAFETY_STDOUT" ]
}

@test "vpn recorder containment: relative filesystem operand is refused" {
  printf 'only disposable canary\n' > "$HOME/outside-profile-canary"
  run run_zsh '
    builtin cd -q -- "$HOME" || exit 90
    sudo -n -- rm -- outside-profile-canary
  '
  [ "$status" -eq 98 ] || profile_safety_failure
  [ "$(cat "$HOME/outside-profile-canary")" = 'only disposable canary' ]
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
}

@test "vpn recorder containment: unrecognized sudo payload form is refused" {
  printf 'only disposable canary\n' > "$HOME/outside-profile-canary"
  run run_zsh 'sudo -- rm -- "$HOME/outside-profile-canary"'
  [ "$status" -eq 98 ] || profile_safety_failure
  [ "$(cat "$HOME/outside-profile-canary")" = 'only disposable canary' ]
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
}

profile_safety_recorder_refused() {
  : > "$MOCK_SUDO_LOG"
  run "$TEST_MOCK_BIN/sudo" "$@"
  [ "$status" -eq 98 ] || profile_safety_failure
  [ -s "$MOCK_SUDO_LOG" ]
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
  [ ! -s "$VPN_SAFETY_TUNNELS" ]
}

@test "vpn recorder containment: timestamp authentication and payload forms are exact" {
  printf 'only disposable canary\n' > "$HOME/outside-profile-canary"
  profile_safety_recorder_refused -n rm -- "$HOME/outside-profile-canary"
  profile_safety_recorder_refused -v -- rm -- "$HOME/outside-profile-canary"
  profile_safety_recorder_refused -n true "$HOME/outside-profile-canary"
  profile_safety_recorder_refused -n -- true
  profile_safety_recorder_refused -n -- /bin/rm -- "$HOME/outside-profile-canary"
  profile_safety_recorder_refused -n -- env rm -- "$HOME/outside-profile-canary"
  profile_safety_recorder_refused rm -- "$HOME/outside-profile-canary"
  [ "$(cat "$HOME/outside-profile-canary")" = 'only disposable canary' ]
  [ ! -e "$VPN_SAFETY_AUTH" ]
}

@test "vpn recorder containment: each filesystem primitive rejects unplanned operands and flags" {
  printf 'only disposable canary\n' > "$HOME/outside-profile-canary"
  profile_safety_recorder_refused -n -- rm -rf -- "$VPN_CONFIG_DIR/wg0.conf"
  profile_safety_recorder_refused -n -- rm -- "$VPN_CONFIG_DIR/../outside-profile-canary"
  profile_safety_recorder_refused -n -- mv -- "$HOME/outside-profile-canary" "$VPN_CONFIG_DIR/escaped"
  profile_safety_recorder_refused -n -- mv -- relative "$VPN_CONFIG_DIR/escaped"
  profile_safety_recorder_refused -n -- mv -f -- "$VPN_CONFIG_DIR/wg0.conf" "$HOME/escaped"
  profile_safety_recorder_refused -n -- install -m 600 -o 0 -g 0 -- "$HOME/outside-profile-canary" "$VPN_CONFIG_DIR/escaped"
  profile_safety_recorder_refused -n -- install -m 644 -o 0 -g 0 -- "$VPN_CONFIG_DIR/wg0.conf" "$VPN_CONFIG_DIR/escaped"
  profile_safety_recorder_refused -n -- install -m 600 -o 0 -g 0 -- "$VPN_CONFIG_DIR/wg0.conf"
  profile_safety_recorder_refused -n -- mktemp "$HOME/escaped.XXXXXX"
  profile_safety_recorder_refused -n -- ln -- "$VPN_CONFIG_DIR/wg0.conf" "$HOME/escaped"
  profile_safety_recorder_refused -n -- ln -s "$HOME" "$VPN_CONFIG_DIR/escaped"
  profile_safety_recorder_refused -n -- wg-quick down "$HOME/outside-profile-canary"
  [ "$(cat "$HOME/outside-profile-canary")" = 'only disposable canary' ]
  [ ! -e "$HOME/escaped" ]
  [ ! -e "$VPN_CONFIG_DIR/escaped" ]
  profile_safety_originals
}

@test "vpn recorder containment: a symlinked profile root never reaches a filesystem primitive" {
  mv "$VPN_CONFIG_DIR" "$HOME/original-profiles"
  mkdir "$HOME/alternate-profiles"
  printf 'only disposable canary\n' > "$HOME/alternate-profiles/canary"
  ln -s "$HOME/alternate-profiles" "$VPN_CONFIG_DIR"
  profile_safety_recorder_refused -n -- rm -- "$VPN_CONFIG_DIR/canary"
  [ -L "$VPN_CONFIG_DIR" ]
  [ "$(cat "$HOME/alternate-profiles/canary")" = 'only disposable canary' ]
}

@test "vpn recorder containment: inner and final symlinks cannot escape the profile root" {
  printf 'only disposable canary\n' > "$HOME/outside-profile-canary"
  mkdir "$VPN_CONFIG_DIR/nested"
  ln -s "$HOME" "$VPN_CONFIG_DIR/nested/escape"
  ln -s "$HOME/outside-profile-canary" "$VPN_CONFIG_DIR/linked-canary"
  profile_safety_recorder_refused -n -- rm -- "$VPN_CONFIG_DIR/nested/escape/outside-profile-canary"
  profile_safety_recorder_refused -n -- install -m 600 -o 0 -g 0 -- "$VPN_CONFIG_DIR/wg0.conf" "$VPN_CONFIG_DIR/linked-canary"
  profile_safety_recorder_refused -n -- rm -- "$VPN_CONFIG_DIR/linked-canary"
  [ -L "$VPN_CONFIG_DIR/nested/escape" ]
  [ -L "$VPN_CONFIG_DIR/linked-canary" ]
  [ "$(cat "$HOME/outside-profile-canary")" = 'only disposable canary' ]
}

@test "vpn recorder containment: exact cold timestamp authentication and warm timestamp remain usable" {
  run "$TEST_MOCK_BIN/sudo" -n true
  [ "$status" -eq 1 ]
  run "$TEST_MOCK_BIN/sudo" -v
  [ "$status" -eq 0 ]
  [[ "$output" == AUTH_BOUNDARY ]]
  run "$TEST_MOCK_BIN/sudo" -n true
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_SUDO_LOG")" = $'sudo -n true\nsudo -v\nsudo -n true' ]
  [ ! -s "$VPN_SAFETY_MUTATIONS" ]
}

@test "vpn recorder containment: approved primitive arguments keep modes and flags out of path validation" {
  run run_zsh '
    sudo -v || exit 90
    local staged=""
    staged=$(sudo -n -- mktemp "$VPN_CONFIG_DIR/.zdx-vpn-restore.XXXXXX") || exit 91
    sudo -n -- install -m 600 -o 0 -g 0 -- "$VPN_CONFIG_DIR/wg0.conf" "$staged" || exit 92
    sudo -n -- ln -- "$staged" "$VPN_CONFIG_DIR/approved-staged" || exit 93
    sudo -n -- rm -- "$staged" || exit 94
    sudo -n -- mv -f -- "$VPN_CONFIG_DIR/approved-staged" "$VPN_CONFIG_DIR/approved-published" || exit 95
    sudo -n -- mv -- "$VPN_CONFIG_DIR/approved-published" "$VPN_CONFIG_DIR/approved-final"
  '
  [ "$status" -eq 0 ] || profile_safety_failure
  cmp "$HOME/expected/live" "$VPN_CONFIG_DIR/approved-final"
  [ "$(file_mode "$VPN_CONFIG_DIR/approved-final")" = 600 ]
  [ ! -e "$VPN_CONFIG_DIR/approved-staged" ]
  [ ! -e "$VPN_CONFIG_DIR/approved-published" ]
  [ "$(grep -c '^sudo -v$' "$MOCK_SUDO_LOG")" -eq 1 ]
  profile_safety_originals
}
