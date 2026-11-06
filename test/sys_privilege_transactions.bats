#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
setup() {
  load test_helper
  export TX_LOG="$HOME/transactions.log" TX_AUTH="$HOME/authenticated"
  export TX_RACE="" TX_PLATFORM=linux TX_BREW_RC=0 TX_AUTH_STATUS=0
  export TX_CONTEXT="$HOME/transactions.zsh" TX_BREW_PREFIX="$HOME/brew"
  export TX_GUARD_RACE="" TX_GUARD_READY="$HOME/guard-ready"
  export TX_POST_GUARD_LOG="$HOME/post-guard-owner.log"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -p "$TMPDIR" "$TX_BREW_PREFIX/Cellar/awscli/1/libexec/bin" "$TX_BREW_PREFIX/Cellar/starship/1/bin"
  chmod -- 700 "$TMPDIR"
  : > "$TX_LOG"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/sudo"
  cat >> "$TEST_MOCK_BIN/sudo" <<'MOCK'
[[ "$HOME" == "$TEST_TEMP_DIR/home" && "$TEST_MOCK_BIN" == "$TEST_TEMP_DIR/bin" \
  && "$TX_AUTH" == "$HOME/authenticated" && "$TX_LOG" == "$HOME/transactions.log" \
  && ! -L "$HOME" && ! -L "$TEST_MOCK_BIN" ]] || exit 98
printf 'sudo %s\n' "$*" >> "$TX_LOG"
if (( $# == 1 )) && [[ "$1" == -v ]]; then
  [[ "$TX_AUTH_STATUS" == 0 ]] || exit "$TX_AUTH_STATUS"
  : > "$TX_AUTH"
  printf 'AUTH_BOUNDARY\n' >&2
  exit 0
fi
[[ "${1:-}" == -n && -e "$TX_AUTH" ]] || exit 98
shift
case "$*" in
  'snap refresh'|'snap remove fixture --revision=11'|'apt-get clean'|'journalctl --vacuum-time=3d')
    export TX_PRIVILEGED=1
    exec "$TEST_MOCK_BIN/$1" "${@:2}"
    ;;
  "rm -rf -- $HOME/aws/v2/2.1.0")
    [[ -d "$HOME/aws/v2" && ! -L "$HOME/aws" && ! -L "$HOME/aws/v2" \
      && ! -L "$HOME/aws/v2/2.1.0" ]] || exit 98
    printf 'rm fixture\n' >> "$TX_LOG"
    exec /bin/rm -rf -- "$HOME/aws/v2/2.1.0"
    ;;
  *) exit 98 ;;
esac
MOCK
  printf '#!%s\n' "$BASH" > "$HOME/transaction-tool"
  cat >> "$HOME/transaction-tool" <<'MOCK'
if [[ "${0##*/}" == brew && -e "$TX_GUARD_READY" ]]; then
  printf '%s\n' "$*" >> "$TX_POST_GUARD_LOG"
fi
case "${0##*/}:$*" in
  'snap:refresh --list') printf 'Name Version Rev Size Publisher Notes\nfixture 2 12 1MB fixture -\n' ;;
  'snap:list --all') printf 'Name Version Rev Tracking Publisher Notes\nfixture 1 11 latest/stable fixture disabled\n' ;;
  'snap:refresh'|'snap:remove fixture --revision=11'|'apt-get:clean'|'journalctl:--vacuum-time=3d')
    [[ "${TX_PRIVILEGED:-0}" == 1 ]] || exit 98
    printf 'mutate:%s:%s\n' "${0##*/}" "$*" >> "$TX_LOG" ;;
  'journalctl:--disk-usage') printf 'Archived and active journals take up 24.0M in the file system.\n' ;;
  'brew:--version') printf 'Homebrew 4.5.0\n' ;;
  'brew:--prefix') printf '%s\n' "$TX_BREW_PREFIX" ;;
  'brew:list awscli'|'brew:list starship') exit 0 ;;
  'brew:upgrade --no-ask awscli'|'brew:upgrade --no-ask starship')
    if IFS= read -r line; then input=open; else input=closed; fi
    printf 'brew:%s|askpass=%s|auto=%s|input=%s\n' "$*" "${SUDO_ASKPASS-unset}" "${HOMEBREW_NO_AUTO_UPDATE-unset}" "$input" >> "$TX_LOG"
    exit "$TX_BREW_RC" ;;
  'aws:--version') printf 'aws-cli/2.30.0 Python/3.12\n' ;;
  'starship:--version') printf 'starship 1.20.0\n' ;;
  *) exit 98 ;;
esac
MOCK
  local tool
  for tool in snap apt-get journalctl brew aws starship; do
    cp "$HOME/transaction-tool" "$TEST_MOCK_BIN/$tool"
    chmod -- 700 "$TEST_MOCK_BIN/$tool"
  done
  chmod -- 700 "$TEST_MOCK_BIN/sudo"
  mkdir -p "$TX_BREW_PREFIX/bin"
  cp "$TEST_MOCK_BIN/aws" "$TX_BREW_PREFIX/Cellar/awscli/1/libexec/bin/aws"
  cp "$TEST_MOCK_BIN/starship" "$TX_BREW_PREFIX/Cellar/starship/1/bin/starship"
  ln -s ../Cellar/awscli/1/libexec/bin/aws "$TX_BREW_PREFIX/bin/aws"
  ln -s ../Cellar/starship/1/bin/starship "$TX_BREW_PREFIX/bin/starship"
  cat > "$TX_CONTEXT" <<'ZSH'
emulate -R zsh
builtin cd -q -- "$TEST_TEMP_DIR" || return 90
path=("$TX_BREW_PREFIX/bin" $path)
_SYS_CAPABILITIES=(architecture x86_64 environment native os "$TX_PLATFORM" os_updates_backend unavailable package_manager apt ports_backend unavailable privilege sudo process_backend procps service_manager systemd snapd available wsl_interop unavailable)
_SYS_CAPABILITIES_READY=1
# The actual readiness helpers read this cached registry. Only a fresh
# capability observation after authentication exposes the simulated change.
_sys_capabilities_refresh() {
  [[ -e "$TX_AUTH" ]] || return 0
  case "$TX_RACE" in
    snap) _SYS_CAPABILITIES[snapd]=unavailable ;;
    journal) _SYS_CAPABILITIES[service_manager]=unavailable ;;
  esac
  return 0
}
ZSH
}
teardown() { cleanup_sandbox; }

@test "sys privilege transactions: direct Snap refresh authenticates before a nonprompting mutation" {
  run run_zsh 'source "$TX_CONTEXT" || exit 90; update-snap --yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$TX_LOG")" = $'sudo -v\nsudo -n snap refresh\nmutate:snap:refresh' ]
  [[ "$output" == *"Privileged operation: sudo -n snap refresh"*"AUTH_BOUNDARY"* ]]
}

@test "sys privilege transactions: Snap readiness is checked after authentication" {
  export TX_RACE=snap
  run run_zsh 'source "$TX_CONTEXT" || exit 90; update-snap --yes'
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_LOG")" = 'sudo -v' ]
}

@test "sys privilege transactions: direct journal cleanup authenticates before a nonprompting mutation" {
  run run_zsh 'source "$TX_CONTEXT" || exit 90; clean-journal --yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$TX_LOG")" = $'sudo -v\nsudo -n journalctl --vacuum-time=3d\nmutate:journalctl:--vacuum-time=3d' ]
  [[ "$output" == *"Privileged operation: sudo -n journalctl --vacuum-time=3d"*"AUTH_BOUNDARY"* ]]
}

@test "sys privilege transactions: journal readiness is checked after authentication" {
  export TX_RACE=journal
  run run_zsh 'source "$TX_CONTEXT" || exit 90; clean-journal --yes'
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_LOG")" = 'sudo -v' ]
}

@test "sys privilege transactions: one cleanup authentication covers both planned package scopes" {
  run run_zsh '
    source "$TX_CONTEXT" || exit 90
    _sys_clean_plan() { print -r -- "APT cache|apt-get clean"; print -r -- "Journal logs|journal entries older than 3 days"; }
    clean-system --quick --yes
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$TX_LOG")" = $'sudo -v\nsudo -n apt-get clean\nmutate:apt-get:clean\nsudo -n journalctl --vacuum-time=3d\nmutate:journalctl:--vacuum-time=3d' ]
}

@test "sys privilege transactions: an inherited authorized scope never authenticates again" {
  : > "$TX_AUTH"
  run run_zsh '
    source "$TX_CONTEXT" || exit 90
    local _SYS_PRIVILEGE_NONINTERACTIVE=1
    update-snap --yes
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$TX_LOG")" = $'sudo -n snap refresh\nmutate:snap:refresh' ]
}

@test "sys privilege transactions: AWS current selection is revalidated after authentication" {
  mkdir -p "$HOME/aws/v2/2.1.0"
  run run_zsh '
    source "$TX_CONTEXT" || exit 90
    _sys_clean_awscli_root() {
      REPLY="$HOME/aws/v2"
      if [[ -e "$TX_AUTH" ]]; then reply=(2.1.0 0); else reply=(2.3.0 0); fi
    }
    _sys_clean_awscli_superseded() { reply=("$HOME/aws/v2/2.1.0"); }
    _sys_clean_step_awscli_bundles "$HOME/aws/v2|2.1.0"
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_LOG")" = 'sudo -v' ]
  [ -d "$HOME/aws/v2/2.1.0" ]
}

@test "sys privilege transactions: disabled Snap removals are announced before authentication" {
  run run_zsh 'source "$TX_CONTEXT" || exit 90; clean-snaps --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Privileged operation: sudo -n snap remove fixture --revision=11"*"AUTH_BOUNDARY"* ]]
  [ "$(cat "$TX_LOG")" = $'sudo -v\nsudo -n snap remove fixture --revision=11\nmutate:snap:remove fixture --revision=11' ]
}

run_guarded_tool_update() {
  run_zsh '
    source "$TX_CONTEXT" || exit 90
    _sys_brew_askpass_program() {
      REPLY="$HOME/fixed-askpass"
      print -r -- "#!/bin/sh\nexit 1" > "$REPLY"
      command chmod -- 700 "$REPLY" || return
      case "$TX_GUARD_RACE" in
        active)
          local target="$TX_BREW_PREFIX/Cellar/starship/1/bin/starship"
          [[ "$TX_TOOL" == aws ]] && target="$TX_BREW_PREFIX/Cellar/awscli/1/libexec/bin/aws"
          print -r -- "# changed while preparing the guard" >> "$target" || return
          ;;
        manager)
          print -r -- "# changed while preparing the guard" >> "$TEST_MOCK_BIN/brew" || return
          ;;
      esac
      : > "$TX_GUARD_READY"
    }
    _sys_brew_askpass_release() {
      [[ "$1" == "$HOME/fixed-askpass" ]] || return 98
      print release >> "$TX_LOG"
      command rm -- "$1"
    }
    export SUDO_ASKPASS="$HOME/inherited-askpass"
    case "$TX_TOOL" in aws) update-awscli --yes ;; starship) update-starship --yes ;; *) return 98 ;; esac
  '
}

@test "sys privilege transactions: Darwin tool upgrades replace inherited askpass and always release it" {
  export TX_PLATFORM=darwin
  local tool
  for tool in aws starship; do
    export TX_TOOL="$tool" TX_BREW_RC=0
    : > "$TX_LOG"
    run run_guarded_tool_update
    [ "$status" -eq 0 ]
    [[ "$(cat "$TX_LOG")" == *"askpass=$HOME/fixed-askpass|auto=1|input=closed"*$'\nrelease' ]]
    [ ! -e "$HOME/fixed-askpass" ]
  done
}

@test "sys privilege transactions: Darwin owner failure and interruption still release askpass" {
  export TX_PLATFORM=darwin TX_TOOL=aws
  local result
  for result in 1 130 143; do
    export TX_BREW_RC="$result"
    : > "$TX_LOG"
    run run_guarded_tool_update
    [ "$status" -eq "$result" ]
    [[ "$(cat "$TX_LOG")" == *$'\nrelease' ]]
    [ ! -e "$HOME/fixed-askpass" ]
  done
}

@test "sys privilege transactions: failed cleanup authentication does not block unprivileged planned cache work" {
  export TX_AUTH_STATUS=1
  mkdir -p "$HOME/.cache/thumbnails"
  printf 'fixture cache\n' > "$HOME/.cache/thumbnails/remove"
  run run_zsh '
    source "$TX_CONTEXT" || exit 90
    _sys_clean_plan() {
      print -r -- "APT cache|apt-get clean"
      print -r -- "Thumbnail cache|$HOME/.cache/thumbnails"
    }
    clean-system --quick --yes
  '
  [ "$status" -eq 1 ]
  [ "$(grep -c '^sudo -v$' "$TX_LOG")" -eq 1 ]
  [ ! -e "$HOME/.cache/thumbnails/remove" ]
  [ ! -e "$TX_AUTH" ]
  run grep -F 'mutate:' "$TX_LOG"
  [ "$status" -eq 1 ]
}

@test "sys privilege transactions: authentication interruption stops every direct privilege path" {
  local interruption operation
  for interruption in 130 143; do
    export TX_AUTH_STATUS="$interruption"
    for operation in snap journal revisions cleanup; do
      export TX_OPERATION="$operation"
      : > "$TX_LOG"
      rm -f "$TX_AUTH"
      run run_zsh '
        source "$TX_CONTEXT" || exit 90
        case "$TX_OPERATION" in
          snap) update-snap --yes ;;
          journal) clean-journal --yes ;;
          revisions) clean-snaps --yes ;;
          cleanup)
            _sys_clean_plan() { print -r -- "APT cache|apt-get clean"; }
            clean-system --quick --yes
            ;;
        esac
      '
      [ "$status" -eq "$interruption" ]
      [ "$(cat "$TX_LOG")" = 'sudo -v' ]
      [ ! -e "$TX_AUTH" ]
    done
  done
}

@test "sys privilege transactions: a stable root-owned AWS scope authenticates and removes only its planned fixture" {
  mkdir -p "$HOME/aws/v2/2.1.0" "$HOME/aws/v2/2.3.0"
  run run_zsh '
    source "$TX_CONTEXT" || exit 90
    _sys_clean_awscli_root() { REPLY="$HOME/aws/v2"; reply=(2.3.0 0); }
    _sys_clean_awscli_superseded() { reply=("$HOME/aws/v2/2.1.0"); }
    _sys_clean_step_awscli_bundles "$HOME/aws/v2|2.1.0"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$TX_LOG")" = "sudo -v
sudo -n rm -rf -- $HOME/aws/v2/2.1.0
rm fixture" ]
  [ ! -e "$HOME/aws/v2/2.1.0" ]
  [ -d "$HOME/aws/v2/2.3.0" ]
}


assert_askpass_change_refused() {
  export TX_PLATFORM=darwin TX_GUARD_RACE="$1"
  local tool
  for tool in aws starship; do
    export TX_TOOL="$tool"
    : > "$TX_LOG"
    rm -f "$TX_GUARD_READY" "$TX_POST_GUARD_LOG"
    run run_guarded_tool_update
    [ "$status" -eq 1 ]
    [ -e "$TX_GUARD_READY" ]
    [ "$(cat "$TX_LOG")" = release ]
    [ ! -s "$TX_POST_GUARD_LOG" ]
    [ ! -e "$HOME/fixed-askpass" ]
  done
}

@test "sys privilege transactions: askpass setup changing the active program refuses delegation" {
  assert_askpass_change_refused active
}

@test "sys privilege transactions: askpass setup changing the manager refuses later observations and delegation" {
  assert_askpass_change_refused manager
}
