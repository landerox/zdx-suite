#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  SCOPE_ORIGINAL_PATH="$PATH"
  load test_helper
  export SCOPE_LOG="$HOME/operations.log" SCOPE_FAIL_PHASE="" SCOPE_TOOL=""
  export SCOPE_STATUS=143 SCOPE_BACKEND=fnm SCOPE_REAL_RM
  export SCOPE_REAL_TERM=0
  SCOPE_REAL_RM=$(command -v rm)
  : > "$SCOPE_LOG"
  cat > "$HOME/tool-mock" <<'MOCK'
#!/usr/bin/env bash
name=${0##*/}
phase=${1:-}
if [[ "$name" == brew && "$phase" == cleanup && "${SCOPE_CHECK_POLICY:-0}" == 1 ]]; then
  [[ "${HOMEBREW_NO_AUTO_UPDATE:-}" == 1 && "${SUDO_ASKPASS:-}" == /usr/bin/false ]] || exit 96
fi
case "$name:$*" in
  'fnm:current') printf 'v24.22.0\n'; exit 0 ;;
  'uv:--version') printf 'uv 0.9.0\n'; exit 0 ;;
  'brew:list starship'|'brew:list awscli') [[ "$SCOPE_BACKEND" == brew ]]; exit $? ;;
  'brew:list fnm'|'brew:list uv') exit 1 ;;
  'brew:outdated --quiet') exit 0 ;;
  'cargo:install --list') printf 'starship v1.0.0:\n'; exit 0 ;;
esac
printf '%s %s\n' "$name" "$*" >> "$SCOPE_LOG"
if IFS= read -r value; then
  printf 'unexpected-stdin:%s\n' "$value" >> "$SCOPE_LOG"
  exit 98
fi
if [[ "$name" == "$SCOPE_TOOL" && "$phase" == "$SCOPE_FAIL_PHASE" ]]; then
  if [[ "$SCOPE_REAL_TERM" == 1 && "$SCOPE_STATUS" == 143 ]]; then
    builtin kill -s TERM "$$"
    exit 99
  fi
  exit "$SCOPE_STATUS"
fi
exit 0
MOCK
  local name
  for name in fnm uv pipx rustup gcloud brew cargo snap; do
    cp "$HOME/tool-mock" "$TEST_MOCK_BIN/$name"
    chmod -- 700 "$TEST_MOCK_BIN/$name"
  done
  cat > "$TEST_MOCK_BIN/rm" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == -* ]] && continue
  [[ "$arg" == "$TEST_TEMP_DIR" || "$arg" == "$TEST_TEMP_DIR/"* ]] || exit 97
done
case "$*" in
  *"$HOME/releases/"*|*"$HOME/.nvm/versions/node/"*|*"$HOME/aws/v2/"*)
    printf 'rm %s\n' "$*" >> "$SCOPE_LOG"
    exit "$SCOPE_STATUS"
    ;;
esac
exec "$SCOPE_REAL_RM" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/rm"
  cat > "$HOME/scope-context.zsh" <<'ZSH'
emulate -R zsh
builtin cd -q -- "$TEST_TEMP_DIR" || return 90
command() {
  if [[ "$1" == -v ]]; then
    case "${2:-}" in apt-get|npm|pip|pip3|python3|rustup|go|pre-commit) return 1 ;; esac
  fi
  builtin command "$@"
}
_sys_clean_running_executables() { reply=(); }
_sys_clean_protected_roots() { reply=(); }
_sys_capabilities_refresh() { return 0; }
_sys_has_capability() {
  [[ "$1" == privilege:sudo || ( "$1" == os:darwin && "$SCOPE_BACKEND" == darwin ) ]]
}
_sys_resolve_privilege_prefix() { reply=(); }
_sys_update_step_requires_privilege() { return 1; }
_sys_update_probe_version() { REPLY=1.0.0; }
_sys_update_pipx_inventory() { print -r -- $'demo\t1.0'; }
_sys_update_tool_program() { REPLY="$TEST_MOCK_BIN/$1"; }
_sys_tool_program() {
  [[ "$1" != fnm || "$SCOPE_BACKEND" != nvm ]] || return 1
  REPLY="$TEST_MOCK_BIN/$1"
}
_sys_tool_available() { [[ "$1" == cargo ]]; }
_sys_uv_resolved_program() { REPLY="$TEST_MOCK_BIN/uv"; }
_sys_uv_updated_version() { REPLY=0.9.0; }
_sys_uv_homebrew_managed() { [[ "$SCOPE_BACKEND" == brew ]]; }
_sys_gcloud_owner() { REPLY=self; reply=("$TEST_MOCK_BIN/gcloud"); }
_sys_brew_askpass_program() { REPLY=/usr/bin/false; }
nvm() {
  case "$1" in
    current) if [[ -e "$HOME/nvm-used" ]]; then print v24.22.0; else print v24.21.0; fi; return 0 ;;
    version) [[ "$2" == default ]] && print v24.21.0 || print v24.22.0; return 0 ;;
  esac
  print -r -- "nvm $*" >> "$SCOPE_LOG"
  if [[ "$SCOPE_TOOL" == nvm && "$1" == "$SCOPE_FAIL_PHASE" ]]; then
    return "$SCOPE_STATUS"
  fi
  [[ "$1" != use ]] || : > "$HOME/nvm-used"
  return 0
}
ZSH
  mkdir -p "$HOME/.nvm/versions/node/v24.21.0/lib/node_modules/demo" \
    "$HOME/.nvm/versions/node/v24.22.0/lib/node_modules/npm" "$HOME/.nvm/alias"
  printf '%s\n' v24.22.0 > "$HOME/.nvm/alias/default"
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/apt-scope-env"
  cat >> "$TEST_MOCK_BIN/apt-scope-env" <<'MOCK'
[[ "${1:-}" == -i ]] || exit 97
shift
while [[ "${1:-}" == *=* ]]; do shift; done
[[ "${1:-}" == apt-get ]] || exit 97
shift
if [[ " $* " == *' -s '* ]]; then
  if [[ "$SCOPE_FAIL_PHASE" == simulate ]]; then
    printf 'apt:simulate\n' >> "$SCOPE_LOG"
    exit "$SCOPE_STATUS"
  fi
  printf 'Inst demo [1.0] (1.1 stable)\n'
  exit 0
fi
case " $* " in
  *' update '*) phase=update ;;
  *' full-upgrade '*) phase=full-upgrade ;;
  *' autoremove '*) phase=autoremove ;;
  *) exit 97 ;;
esac
printf 'apt:%s\n' "$phase" >> "$SCOPE_LOG"
if [[ "$SCOPE_FAIL_PHASE" == "$phase" ]]; then exit "$SCOPE_STATUS"; fi
exit 0
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/apt-scope-env"
  cat > "$HOME/apt-context.zsh" <<'ZSH'
emulate -R zsh
source "$HOME/scope-context.zsh" || return 90
_SYS_PRIVILEGE_NONINTERACTIVE=1
_sys_has_capability() { [[ "$1" == package:apt ]]; }
_sys_update_resolve_trusted_program() { REPLY="$TEST_MOCK_BIN/apt-scope-env"; }
_sys_apt_key_plan() { REPLY=0; }
_sys_apt_plan_blocker() { REPLY=""; }
_sys_apt_prepare_transaction() { print -r -- audit:before >> "$SCOPE_LOG"; }
_sys_apt_key_renewal_enabled() { return 1; }
_sys_apt_key_guidance() { REPLY=""; }
_sys_apt_dpkg_state_clean() {
  print -r -- "audit:${1:-before}" >> "$SCOPE_LOG"
  return "${SCOPE_POST_AUDIT_STATUS:-0}"
}
_sys_apt_report_reboot_requirement() { REPLY=""; }
ZSH
}

teardown() {
  PATH="$SCOPE_ORIGINAL_PATH"
  hash -r
  cleanup_sandbox
}

scope_failure() {
  printf 'status=%s output=%s\n' "$status" "$output" >&2
  cat "$SCOPE_LOG" >&2
  false
}

@test "sys cleanup scope: nested nvm aliases keep their selected runtime" {
  mkdir -p "$HOME/.nvm/versions/node/v24.22.0/lib/node_modules/demo"
  mkdir -p "$HOME/.nvm/alias/lts" "$HOME/.nvm/alias/team/development"
  printf '%s\n' v24.21.0 > "$HOME/.nvm/alias/lts/jod"
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    _sys_clean_nvm_candidates "$HOME/.nvm" "$HOME/.nvm/versions/node" || exit 91
    (( ${#reply} == 0 )) || exit 92
    command mv "$HOME/.nvm/alias/lts/jod" "$HOME/.nvm/alias/team/development/default" || exit 93
    _sys_clean_nvm_candidates "$HOME/.nvm" "$HOME/.nvm/versions/node" || exit 94
    (( ${#reply} == 0 )) || exit 95
  '
  [ "$status" -eq 0 ] || scope_failure
}

@test "sys cleanup scope: canonical and literal HOME spellings reject inner links" {
  mkdir -p "$HOME/realhome/data/cache/npm" "$HOME/realhome/plain/cache"
  ln -s "$HOME/realhome" "$HOME/linkhome"
  ln -s data/cache "$HOME/realhome/.cache"
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    local real_home="$HOME/realhome"
    HOME="$HOME/linkhome"
    _sys_clean_validate_user_path "$HOME/.cache/npm" >/dev/null 2>/dev/null
    (( $? == 1 )) || exit 91
    _sys_clean_validate_user_path "$real_home/.cache/npm" >/dev/null 2>/dev/null
    (( $? == 1 )) || exit 92
    _sys_clean_validate_user_path "$real_home/plain/cache" || exit 93
    [[ "$REPLY" == "$real_home/plain/cache" ]] || exit 94
  '
  [ "$status" -eq 0 ] || scope_failure
}

@test "sys cleanup scope: interrupted release removal stops before later names" {
  mkdir -p "$HOME/releases/2.0.0" "$HOME/releases/2.0.1"
  local interrupt
  for interrupt in 130 143; do
    export SCOPE_STATUS="$interrupt"
    : > "$SCOPE_LOG"
    run run_zsh '
      source "$HOME/scope-context.zsh" || exit 90
      _sys_clean_release_targets() {
        REPLY="$HOME/releases"
        reply=("$HOME/releases/2.0.0" "$HOME/releases/2.0.1")
      }
      _sys_clean_step_releases "Claude CLI versions" "$HOME/releases|2.0.0 2.0.1"
    '
    [ "$status" -eq "$interrupt" ] || scope_failure
    [ "$(wc -l < "$SCOPE_LOG")" -eq 1 ]
    [ -d "$HOME/releases/2.0.1" ]
    [[ "$output" == *2.0.1* ]]
  done
}

@test "sys cleanup scope: interrupted nvm removal stops before later runtimes" {
  mkdir -p "$HOME/.nvm/versions/node/v24.20.0"
  local interrupt
  for interrupt in 130 143; do
    export SCOPE_STATUS="$interrupt"
    : > "$SCOPE_LOG"
    run run_zsh '
      source "$HOME/scope-context.zsh" || exit 90
      _sys_clean_nvm_targets() { REPLY="$HOME/.nvm/versions/node"; reply=(v24.20.0 v24.21.0); }
      _sys_clean_step_nvm_runtimes "$HOME/.nvm/versions/node|v24.20.0 v24.21.0"
    '
    [ "$status" -eq "$interrupt" ] || scope_failure
    [ "$(wc -l < "$SCOPE_LOG")" -eq 1 ]
    [ -d "$HOME/.nvm/versions/node/v24.21.0" ]
    [[ "$output" == *v24.21.0* ]]
  done
}

@test "sys cleanup scope: ordinary removal failure still examines later planned names" {
  mkdir -p "$HOME/releases/2.0.0" "$HOME/releases/2.0.1"
  export SCOPE_STATUS=1
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    _sys_clean_release_targets() {
      REPLY="$HOME/releases"
      reply=("$HOME/releases/2.0.0" "$HOME/releases/2.0.1")
    }
    _sys_clean_step_releases "Claude CLI versions" "$HOME/releases|2.0.0 2.0.1"
  '
  [ "$status" -eq 1 ] || scope_failure
  [ "$(wc -l < "$SCOPE_LOG")" -eq 2 ]
  [ -d "$HOME/releases/2.0.0" ]
  [ -d "$HOME/releases/2.0.1" ]
}

@test "sys cleanup scope: interrupted AWS removal retains its status and stops aggregate steps" {
  mkdir -p "$HOME/aws/v2/2.30.0" "$HOME/aws/v2/2.31.0"
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    _sys_clean_awscli_root() { REPLY="$HOME/aws/v2"; reply=(2.32.0 "$EUID"); }
    _sys_clean_awscli_superseded() { reply=("$HOME/aws/v2/2.30.0" "$HOME/aws/v2/2.31.0"); }
    _sys_clean_mode_steps() {
      reply=("AWS CLI bundles;_sys_clean_step_awscli_bundles" "Temporary files;_scope_later")
    }
    _scope_later() { print -r -- later >> "$SCOPE_LOG"; }
    _sys_clean_run quick $'"'"'AWS CLI bundles|'"'"'"$HOME/aws/v2|2.30.0 2.31.0"$'"'"'\nTemporary files|fixture'"'"'
  '
  [ "$status" -eq 143 ] || scope_failure
  [ "$(wc -l < "$SCOPE_LOG")" -eq 1 ]
  [[ "$output" == *"not run"* || "$output" == *"not-run"* ]]
}

@test "sys cleanup scope: Snap removal interruptions stop before the next revision" {
  export SCOPE_TOOL=snap SCOPE_FAIL_PHASE=remove
  local interrupt
  for interrupt in 130 143; do
    export SCOPE_STATUS="$interrupt"
    : > "$SCOPE_LOG"
    run run_zsh '
      source "$HOME/scope-context.zsh" || exit 90
      _sys_disabled_snap_revisions() { print -r -- $'"'"'one 11\ntwo 22'"'"'; }
      sudo() {
        [[ "$1" == -v ]] && return 0
        [[ "$1" == -n ]] || return 97
        shift
        command "$@"
      }
      _sys_remove_disabled_snap_revisions $'"'"'one 11\ntwo 22'"'"'
    '
    [ "$status" -eq "$interrupt" ] || scope_failure
    [ "$(cat "$SCOPE_LOG")" = 'snap remove one --revision=11' ]
  done
}

@test "sys cleanup scope: direct clean-snaps propagates an interrupted removal" {
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    _sys_snap_ready() { return 0; }
    _sys_disabled_snap_revisions() { print -r -- "one 11"; }
    _sys_remove_disabled_snap_revisions() { return 143; }
    clean-snaps --yes
  '
  [ "$status" -eq 143 ] || scope_failure
}

@test "sys cleanup scope: interrupted Snap revalidation starts no removal" {
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    _sys_disabled_snap_revisions() { return 130; }
    sudo() { [[ "$1" == -v ]]; }
    _sys_remove_disabled_snap_revisions $'"'"'one 11\ntwo 22'"'"'
  '
  [ "$status" -eq 130 ] || scope_failure
  [ ! -s "$SCOPE_LOG" ]
}

@test "sys cleanup scope: Homebrew cleanup removes only caches with closed stdin" {
  printf '%s\n' hidden-input > "$HOME/cleanup.input"
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    _sys_clean_step_homebrew < "$HOME/cleanup.input"
  '
  [ "$status" -eq 0 ] || scope_failure
  [ "$(cat "$SCOPE_LOG")" = 'brew cleanup --prune=all' ]
}

@test "sys cleanup scope: Homebrew plan does not include dependency removal" {
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    _sys_clean_plan deep
  '
  [ "$status" -eq 0 ] || scope_failure
  [[ "$output" == *'Homebrew cleanup|brew cleanup --prune=all'* ]]
  [[ "$output" != *autoremove* ]]
}

@test "sys cleanup scope: Darwin Homebrew cleanup replaces inherited askpass and disables auto-update" {
  export SCOPE_BACKEND=darwin SCOPE_CHECK_POLICY=1
  export SUDO_ASKPASS="$HOME/untrusted-askpass"
  run run_zsh 'source "$HOME/scope-context.zsh" || exit 90; _sys_clean_step_homebrew'
  [ "$status" -eq 0 ] || scope_failure
  [ "$(cat "$SCOPE_LOG")" = 'brew cleanup --prune=all' ]
}

@test "sys updater interruptions: actual fnm install stops the aggregate before Rust" {
  export SCOPE_TOOL=fnm SCOPE_FAIL_PHASE=install
  local interrupt
  for interrupt in 130 143; do
    export SCOPE_STATUS="$interrupt"
    : > "$SCOPE_LOG"
    run run_zsh '
      source "$HOME/scope-context.zsh" || exit 90
      _sys_update_run 0 1 0 0 "Node.js;update-node" "Rust;update-rust"
    '
    [ "$status" -eq "$interrupt" ] || scope_failure
    [ "$(cat "$SCOPE_LOG")" = 'fnm install --lts' ]
  done
}

@test "sys updater interruptions: a fnm child terminated by TERM stops the aggregate" {
  export SCOPE_TOOL=fnm SCOPE_FAIL_PHASE=install SCOPE_STATUS=143 SCOPE_REAL_TERM=1
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    _sys_update_run 0 1 0 0 "Node.js;update-node" "Rust;update-rust"
  '
  [ "$status" -eq 143 ] || scope_failure
  [ "$(cat "$SCOPE_LOG")" = 'fnm install --lts' ]
}

@test "sys updater interruptions: fnm activation and default changes retain interruptions" {
  export SCOPE_TOOL=fnm
  local phase interrupt
  for phase in use default; do
    for interrupt in 130 143; do
      export SCOPE_FAIL_PHASE="$phase" SCOPE_STATUS="$interrupt"
      : > "$SCOPE_LOG"
      run run_zsh 'source "$HOME/scope-context.zsh" || exit 90; update-node'
      [ "$status" -eq "$interrupt" ] || scope_failure
      if [ "$phase" = use ]; then
        [ "$(cat "$SCOPE_LOG")" = $'fnm install --lts\nfnm use lts-latest' ]
      fi
    done
  done
}

@test "sys updater interruptions: nvm install and post-install phases retain interruptions" {
  export SCOPE_BACKEND=nvm SCOPE_TOOL=nvm
  local phase interrupt
  for phase in install alias use reinstall-packages; do
    for interrupt in 130 143; do
      export SCOPE_FAIL_PHASE="$phase" SCOPE_STATUS="$interrupt"
      : > "$SCOPE_LOG"
      "$SCOPE_REAL_RM" -f -- "$HOME/nvm-used"
      run run_zsh 'source "$HOME/scope-context.zsh" || exit 90; update-node'
      [ "$status" -eq "$interrupt" ] || scope_failure
      if [ "$phase" = alias ]; then
        [ "$(cat "$SCOPE_LOG")" = $'nvm install --lts\nnvm alias default v24.22.0' ]
      fi
    done
  done
}

@test "sys updater interruptions: uv pipx rustup and gcloud preserve mutating child statuses" {
  local tool entry phase interrupt
  for entry in 'uv update-uv-system self' 'pipx update-pipx upgrade-all' \
    'rustup update-rust update' 'gcloud update-gcloud components'; do
    read -r tool SCOPE_COMMAND phase <<< "$entry"
    export SCOPE_TOOL="$tool" SCOPE_FAIL_PHASE="$phase" SCOPE_COMMAND
    for interrupt in 130 143; do
      export SCOPE_STATUS="$interrupt"
      : > "$SCOPE_LOG"
      run run_zsh 'source "$HOME/scope-context.zsh" || exit 90; "$SCOPE_COMMAND"'
      [ "$status" -eq "$interrupt" ] || scope_failure
    done
  done
}

@test "sys updater interruptions: Homebrew update phases stop at an interrupted child" {
  export SCOPE_TOOL=brew
  local phase interrupt
  for phase in update upgrade autoremove cleanup; do
    for interrupt in 130 143; do
      export SCOPE_STATUS="$interrupt" SCOPE_FAIL_PHASE="$phase"
      : > "$SCOPE_LOG"
      run run_zsh 'source "$HOME/scope-context.zsh" || exit 90; update-brew'
      [ "$status" -eq "$interrupt" ] || scope_failure
      if [ "$phase" = upgrade ]; then
        [ "$(tail -1 "$SCOPE_LOG")" = 'brew upgrade --no-ask' ]
      else
        [ "$(tail -1 "$SCOPE_LOG")" = "brew $phase" ]
      fi
    done
  done
}

@test "sys updater interruptions: Homebrew-owned tools and Cargo retain status" {
  local item tool phase backend interrupt
  for item in 'update-uv-system brew upgrade brew' 'update-awscli brew upgrade brew' \
    'update-starship brew upgrade brew' \
    'update-starship cargo install cargo'; do
    read -r SCOPE_COMMAND tool phase backend <<< "$item"
    export SCOPE_COMMAND SCOPE_TOOL="$tool" SCOPE_FAIL_PHASE="$phase" SCOPE_BACKEND="$backend"
    for interrupt in 130 143; do
      export SCOPE_STATUS="$interrupt"
      : > "$SCOPE_LOG"
      run run_zsh 'source "$HOME/scope-context.zsh" || exit 90; "$SCOPE_COMMAND"'
      [ "$status" -eq "$interrupt" ] || scope_failure
    done
  done
}

@test "sys updater interruptions: APT index upgrade and removal preserve interruptions after audit" {
  local phase interrupt
  for phase in update full-upgrade autoremove; do
    for interrupt in 130 143; do
      export SCOPE_FAIL_PHASE="$phase" SCOPE_STATUS="$interrupt"
      : > "$SCOPE_LOG"
      run run_zsh 'source "$HOME/apt-context.zsh" || exit 90; update-apt --yes'
      [ "$status" -eq "$interrupt" ] || scope_failure
      [ "$(tail -1 "$SCOPE_LOG")" = audit:after ]
      if [ "$phase" = update ]; then
        [ "$(cat "$SCOPE_LOG")" = $'audit:before\napt:update\naudit:after' ]
      fi
    done
  done
}

@test "sys updater interruptions: post-audit failure cannot downgrade a prior APT interruption" {
  export SCOPE_FAIL_PHASE=full-upgrade SCOPE_STATUS=143 SCOPE_POST_AUDIT_STATUS=1
  run run_zsh 'source "$HOME/apt-context.zsh" || exit 90; update-apt --yes'
  [ "$status" -eq 143 ] || scope_failure
  [ "$(tail -1 "$SCOPE_LOG")" = audit:after ]
}

@test "sys updater interruptions: an interrupted APT simulation starts no transaction" {
  export SCOPE_FAIL_PHASE=simulate SCOPE_STATUS=130
  run run_zsh 'source "$HOME/apt-context.zsh" || exit 90; update-apt --yes'
  [ "$status" -eq 130 ] || scope_failure
  [ "$(cat "$SCOPE_LOG")" = apt:simulate ]
}

@test "sys updater interruptions: interrupted APT indexes do not begin another key renewal" {
  run run_zsh '
    source "$HOME/apt-context.zsh" || exit 90
    _sys_apt_key_renewal_enabled() { return 0; }
    _sys_apt_key_renew_expired() { return 0; }
    _sys_apt_index_update() { REPLY=""; return 143; }
    _sys_apt_key_renew_reported() { print -r -- late-key-renewal >> "$SCOPE_LOG"; }
    _sys_apt_refresh_indexes
    [[ "${reply[1]}" == 143 ]] || exit 91
  '
  [ "$status" -eq 0 ] || scope_failure
  [ ! -s "$SCOPE_LOG" ]
}

@test "sys cleanup scope: unreadable nvm alias files keep every runtime" {
  mkdir -p "$HOME/.nvm/versions/node/v24.22.0/lib/node_modules/demo" "$HOME/.nvm/alias/lts"
  local alias_name
  for alias_name in team lts/jod; do
    printf '%s\n' v24.21.0 > "$HOME/.nvm/alias/$alias_name"
    chmod -- 000 "$HOME/.nvm/alias/$alias_name"
    export SCOPE_ALIAS="$HOME/.nvm/alias/$alias_name"
    run run_zsh '
      source "$HOME/scope-context.zsh" || exit 90
      [[ ! -r "$SCOPE_ALIAS" ]] || exit 87
      _sys_clean_nvm_candidates "$HOME/.nvm" "$HOME/.nvm/versions/node"
      (( $? == 1 && ${#reply} == 0 )) || exit 91
    '
    [ "$status" -eq 0 ] || scope_failure
    chmod -- 600 "$SCOPE_ALIAS"
    rm -- "$SCOPE_ALIAS"
  done
}

@test "sys cleanup scope: unreadable nvm alias directories keep every runtime" {
  mkdir -p "$HOME/.nvm/versions/node/v24.22.0/lib/node_modules/demo" "$HOME/.nvm/alias/lts"
  printf '%s\n' v24.21.0 > "$HOME/.nvm/alias/lts/jod"
  chmod -- 000 "$HOME/.nvm/alias/lts"
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    [[ ! -r "$HOME/.nvm/alias/lts" ]] || exit 87
    _sys_clean_nvm_candidates "$HOME/.nvm" "$HOME/.nvm/versions/node"
    (( $? == 1 && ${#reply} == 0 )) || exit 91
  '
  [ "$status" -eq 0 ] || scope_failure
  chmod -- 700 "$HOME/.nvm/alias/lts"
}

@test "sys cleanup scope: failed nvm alias reads keep every runtime" {
  mkdir -p "$HOME/.nvm/versions/node/v24.22.0/lib/node_modules/demo"
  printf '%s\n' v24.21.0 > "$HOME/.nvm/alias/team"
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    TRAPDEBUG() {
      if [[ "$ZSH_DEBUG_CMD" == alias_target=* && -e "$HOME/.nvm/alias/team" ]]; then
        builtin command rm -- "$HOME/.nvm/alias/team" || return 86
        print -r -- read-failed >> "$SCOPE_LOG"
      fi
    }
    _sys_clean_nvm_candidates "$HOME/.nvm" "$HOME/.nvm/versions/node"
    local -i candidates_rc=$?
    unfunction TRAPDEBUG
    (( candidates_rc == 1 && ${#reply} == 0 )) || exit 91
  '
  [ "$status" -eq 0 ] || scope_failure
  [ "$(cat "$SCOPE_LOG")" = read-failed ]
}

@test "sys cleanup scope: an unreadable alias after one removal protects later runtimes" {
  mkdir -p "$HOME/.nvm/versions/node/v24.22.0/lib/node_modules/demo" \
    "$HOME/.nvm/versions/node/v24.20.0/lib/node_modules"
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    command() {
      if [[ "$1" == rm && "${argv[-1]}" == "$HOME/.nvm/versions/node/"v<->.<->.<-> ]]; then
        print -r -- "$*" >> "$SCOPE_LOG"
        builtin command "$SCOPE_REAL_RM" "${@:2}" || return 86
        print -r -- v24.21.0 > "$HOME/.nvm/alias/team"
        builtin command chmod -- 000 "$HOME/.nvm/alias/team" || return 86
        return 0
      fi
      builtin command "$@"
    }
    _sys_clean_step_nvm_runtimes "$HOME/.nvm/versions/node|v24.20.0 v24.21.0"
  '
  [ "$status" -eq 1 ] || scope_failure
  [ "$(wc -l < "$SCOPE_LOG")" -eq 1 ]
  [[ "$(cat "$SCOPE_LOG")" == *v24.20.0 ]]
  [ ! -d "$HOME/.nvm/versions/node/v24.20.0" ]
  [ -d "$HOME/.nvm/versions/node/v24.21.0" ]
  [[ "$output" == *"Removed before stopping:"*v24.20.0* ]]
  [[ "$output" == *"Not run:"*v24.21.0* ]]
  chmod -- 600 "$HOME/.nvm/alias/team"
}

@test "sys cleanup scope: interrupted alias inventory retains statuses through candidates and targets" {
  local interrupt
  for interrupt in 130 143; do
    export SCOPE_STATUS="$interrupt"
    run run_zsh '
      source "$HOME/scope-context.zsh" || exit 90
      functions[_scope_bounded_probe]="${functions[_sys_run_bounded_probe]}"
      _sys_run_bounded_probe() {
        [[ "${3:-}" != find ]] || return "$SCOPE_STATUS"
        _scope_bounded_probe "$@"
      }
      _sys_clean_nvm_candidates "$HOME/.nvm" "$HOME/.nvm/versions/node"
      (( $? == SCOPE_STATUS && ${#reply} == 0 )) || exit 91
      _sys_clean_nvm_targets
      (( $? == SCOPE_STATUS && ${#reply} == 0 )) || exit 92
    '
    [ "$status" -eq 0 ] || scope_failure
  done
}

@test "sys cleanup scope: an unterminated alias inventory never proves a runtime unselected" {
  mkdir -p "$HOME/.nvm/versions/node/v24.22.0/lib/node_modules/demo"
  run run_zsh '
    source "$HOME/scope-context.zsh" || exit 90
    functions[_scope_bounded_probe]="${functions[_sys_run_bounded_probe]}"
    _sys_run_bounded_probe() {
      if [[ "${3:-}" == find ]]; then
        print -rn -- "$HOME/.nvm/alias"
        return 0
      fi
      _scope_bounded_probe "$@"
    }
    _sys_clean_nvm_candidates "$HOME/.nvm" "$HOME/.nvm/versions/node"
    (( $? == 1 && ${#reply} == 0 )) || exit 91
  '
  [ "$status" -eq 0 ] || scope_failure
}

@test "sys cleanup scope: interrupted alias planning starts no cleanup" {
  local interrupt
  for interrupt in 130 143; do
    export SCOPE_STATUS="$interrupt"
    run run_zsh '
      source "$HOME/scope-context.zsh" || exit 90
      functions[_scope_bounded_probe]="${functions[_sys_run_bounded_probe]}"
      _sys_run_bounded_probe() {
        [[ "${3:-}" != find ]] || return "$SCOPE_STATUS"
        _scope_bounded_probe "$@"
      }
      _sys_clean_run() { print -r -- mutation >> "$SCOPE_LOG"; }
      clean-system --quick --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    '
    [ "$status" -eq "$interrupt" ] || scope_failure
    [ ! -s "$HOME/result.stdout" ]
    run grep -F mutation "$SCOPE_LOG"
    [ "$status" -eq 1 ]
  done
}

@test "sys cleanup scope: interrupted alias revalidation reports completed and unrun runtimes" {
  mkdir -p "$HOME/.nvm/versions/node/v24.22.0/lib/node_modules/demo" \
    "$HOME/.nvm/versions/node/v24.20.0/lib/node_modules"
  local interrupt
  for interrupt in 130 143; do
    export SCOPE_STATUS="$interrupt"
    mkdir -p "$HOME/.nvm/versions/node/v24.20.0/lib/node_modules"
    : > "$SCOPE_LOG"
    "$SCOPE_REAL_RM" -f -- "$HOME/alias-interrupted"
    run run_zsh '
      source "$HOME/scope-context.zsh" || exit 90
      functions[_scope_bounded_probe]="${functions[_sys_run_bounded_probe]}"
      _sys_run_bounded_probe() {
        if [[ "${3:-}" == find && -e "$HOME/alias-interrupted" ]]; then
          return "$SCOPE_STATUS"
        fi
        _scope_bounded_probe "$@"
      }
      command() {
        if [[ "$1" == rm && "${argv[-1]}" == "$HOME/.nvm/versions/node/"v<->.<->.<-> ]]; then
          print -r -- "$*" >> "$SCOPE_LOG"
          builtin command "$SCOPE_REAL_RM" "${@:2}" || return 86
          : > "$HOME/alias-interrupted"
          return 0
        fi
        builtin command "$@"
      }
      _sys_clean_step_nvm_runtimes "$HOME/.nvm/versions/node|v24.20.0 v24.21.0"
    '
    [ "$status" -eq "$interrupt" ] || scope_failure
    [ "$(wc -l < "$SCOPE_LOG")" -eq 1 ]
    [ ! -d "$HOME/.nvm/versions/node/v24.20.0" ]
    [ -d "$HOME/.nvm/versions/node/v24.21.0" ]
    [[ "$output" == *"Removed before stopping:"*v24.20.0* ]]
    [[ "$output" == *"Not run:"*v24.21.0* ]]
  done
}
