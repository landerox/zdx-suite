#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  unset F505_BOUND_SECONDS F505_FORMULAS F505_PRINT_PREFIX F505_PACKAGE_STATE
  export F505_LOG="$HOME/producers.tsv" F505_MUTATIONS="$HOME/mutations.tsv"
  export F505_TIMEOUT_LOG="$HOME/timeout.tsv" F505_TARGET_TOOL='' F505_TARGET_ARGS=''
  export F505_TARGET_RC=0 F505_BREW_LIST_RC=0
  export F505_PREFIX="$HOME/homebrew" F505_APT_ROOT="$HOME/apt-sdk"
  export F505_CASE="$HOME/observations" F505_SCENARIO=''
  mkdir -p "$F505_CASE" "$F505_PREFIX/Caskroom/gcloud-cli/1/bin" \
    "$F505_PREFIX/Cellar/uv/1/bin" "$F505_PREFIX/Cellar/starship/1/bin" \
    "$F505_APT_ROOT/bin" "$HOME/.cargo/bin"
  : > "$F505_LOG"
  : > "$F505_MUTATIONS"
  : > "$F505_TIMEOUT_LOG"
  printf '#!%s\n' "$BASH" > "$HOME/finite-program"
  cat >> "$HOME/finite-program" <<'MOCK'
tool=${0##*/}
stdin_state=eof
if IFS= read -r input_line; then stdin_state=input; fi
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t' "$tool" "$0" \
    "${F505_BOUND_SECONDS:-none}" "$stdin_state" "${HOMEBREW_NO_AUTO_UPDATE:-unset}" \
    "${HOMEBREW_CURL_RETRIES:-unset}" "${HOMEBREW_NO_ANALYTICS:-unset}" \
    "${HOMEBREW_NO_ENV_HINTS:-unset}" "$#"
  printf '%s\t' "$@"
  printf '\n'
} >> "$F505_LOG" || exit 96
case "$tool:$*" in
  'brew:--prefix') printf '%s\n' "${F505_PRINT_PREFIX:-$F505_PREFIX}" ;;
  'brew:--version') printf 'Homebrew 4.5.0\n' ;;
  'brew:list --formula')
    if [[ ${F505_FORMULAS+x} == x ]]; then printf '%s\n' "$F505_FORMULAS"; else
      printf 'fnm\nstarship\n'
      [[ "$F505_SCENARIO" == fzf-apt ]] || printf 'fzf\n'
    fi ;;
  'brew:list fnm'|'brew:list fzf'|'brew:list starship')
    if [[ "$tool" != "$F505_TARGET_TOOL" || "$*" != "$F505_TARGET_ARGS" ]]; then exit "$F505_BREW_LIST_RC"; fi ;;
  'dpkg:-s google-cloud-cli'|'dpkg:-s fzf') ;;
  dpkg-query:*)
    [[ $# == 4 && "$1" == -W && "$2" == '-f=${db:Status-Status}\n' && "$3" == -- && ( "$4" == google-cloud-cli || "$4" == fzf ) ]] || exit 97
    printf '%s\n' "${F505_PACKAGE_STATE:-installed}" ;;
  'uv:--version') printf 'uv 0.8.0\n' ;;
  'fnm:current') printf 'v22.1.0\n' ;;
  'fzf:--version') printf '0.99.0 (fixture)\n' ;;
  'gcloud:version') printf 'Google Cloud SDK 500.0.0\n' ;;
  'starship:--version') printf 'starship 1.20.0\n' ;;
  'cargo:--version') printf 'cargo 1.80.0\n' ;;
  'cargo:install --list') printf 'starship v1.20.0:\n' ;;
  'brew:upgrade --no-ask uv'|'uv:self update'|'gcloud:components update --quiet'|\
  'fnm:install --lts'|'fnm:use lts-latest'|'fnm:default lts-latest')
    printf '%s\t%s\n' "$tool" "$*" >> "$F505_MUTATIONS" || exit 96 ;;
  *) printf 'unexpected finite invocation: %s %s\n' "$tool" "$*" >&2; exit 97 ;;
esac
if { [[ "$tool" == "$F505_TARGET_TOOL" ]] && { [[ "$*" == "$F505_TARGET_ARGS" ]] \
  || [[ "$tool:$*" == 'brew:list --formula' && "$F505_TARGET_ARGS" == 'list '* ]]; }; } \
  || { [[ "$tool" == dpkg-query && "$F505_TARGET_TOOL" == dpkg && "-s $4" == "$F505_TARGET_ARGS" ]]; }; then
  printf 'finite probe diagnostic\n' >&2
  exit "$F505_TARGET_RC"
fi
exit 0
MOCK
  local tool
  for tool in brew dpkg dpkg-query fnm fzf cargo; do
    cp "$HOME/finite-program" "$TEST_MOCK_BIN/$tool"
    chmod -- 700 "$TEST_MOCK_BIN/$tool"
  done
  for tool in "$F505_PREFIX/Caskroom/gcloud-cli/1/bin/gcloud" \
    "$F505_PREFIX/Cellar/uv/1/bin/uv" "$F505_PREFIX/Cellar/starship/1/bin/starship" \
    "$F505_APT_ROOT/bin/gcloud" "$HOME/.cargo/bin/starship"; do
    cp "$HOME/finite-program" "$tool"
    chmod -- 700 "$tool"
  done
  cat > "$HOME/planning-context.zsh" <<'ZSH'
emulate -R zsh
source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 90
builtin cd -q -- "$TEST_TEMP_DIR" || return 91
_sys_has_capability() { return 1; }
_sys_capabilities_refresh() { _SYS_CAPABILITIES_READY=1; return 0; }
_sys_gcloud_apt_root() { REPLY="$F505_APT_ROOT"; }
# A finite synchronous boundary recorder, not a native timeout implementation.
_sys_run_with_timeout() {
  local -x F505_BOUND_SECONDS="$1"
  shift
  [[ "$F505_BOUND_SECONDS" == <-> && "$F505_BOUND_SECONDS" -gt 0 \
    && "$1" == /* && -f "$1" && -x "$1" ]] || return 92
  printf '%s\t%s\t%s\n' "$F505_BOUND_SECONDS" "$1" "${(j: :)@}" >> "$F505_TIMEOUT_LOG" || return 93
  local -i producer_status=0
  "$@" || producer_status=$?
  print -r -- "$producer_status" > "$F505_CASE/last-timed-producer.status" || return 94
  return "$producer_status"
}
_zdx_run_with_timeout() { _sys_run_with_timeout "$@"; }
ZSH
}

teardown() { cleanup_sandbox; }

planning_select() {
  export F505_SCENARIO="$1" F505_TARGET_RC="${2:-0}" F505_BREW_LIST_RC=0
  case "$1" in
    prefix|gcloud-brew|uv|gcloud-applies|uv-applies|gcloud-plan|uv-plan)
      export F505_TARGET_TOOL=brew F505_TARGET_ARGS=--prefix ;;
    gcloud-apt) export F505_TARGET_TOOL=dpkg F505_TARGET_ARGS='-s google-cloud-cli' ;;
    fnm) export F505_TARGET_TOOL=brew F505_TARGET_ARGS='list fnm' ;;
    fzf-brew) export F505_TARGET_TOOL=brew F505_TARGET_ARGS='list fzf' ;;
    fzf-apt) export F505_TARGET_TOOL=dpkg F505_TARGET_ARGS='-s fzf' F505_BREW_LIST_RC=1 ;;
    *) return 1 ;;
  esac
  rm -f -- "$TEST_MOCK_BIN/gcloud" "$TEST_MOCK_BIN/uv"
  if [[ "$1" == gcloud-apt ]]; then
    ln -s "$F505_APT_ROOT/bin/gcloud" "$TEST_MOCK_BIN/gcloud" || return 2
  else
    ln -s "$F505_PREFIX/Caskroom/gcloud-cli/1/bin/gcloud" "$TEST_MOCK_BIN/gcloud" || return 2
  fi
  ln -s "$F505_PREFIX/Cellar/uv/1/bin/uv" "$TEST_MOCK_BIN/uv" || return 3
}

planning_observe() {
  local wrapper=0
  run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    _f505_action() {
      case "$F505_SCENARIO" in
        prefix) _sys_brew_prefix || return $?; print -r -- "$REPLY" > "$F505_CASE/prefix" ;;
        gcloud-brew|gcloud-apt) update-gcloud ;;
        uv) update-uv-system ;;
        fnm) update-node ;;
        fzf-brew|fzf-apt) update-fzf --dry-run ;;
        gcloud-plan|uv-plan)
          local -i applicability=0
          if [[ "$F505_SCENARIO" == gcloud-plan ]]; then
            _sys_update_gcloud_applies || applicability=$?
          else
            _sys_update_uv_applies || applicability=$?
          fi
          print -r -- "$applicability" > "$F505_CASE/applicability.status" || return 93
          : > "$F505_LOG"
          functions[_f505_original_step_applies]="$functions[_sys_step_applies]"
          _sys_step_applies() {
            case "$F505_SCENARIO:$1" in
              gcloud-plan:update-gcloud|uv-plan:update-uv-system) _f505_original_step_applies "$@" ;;
              *:update-rust) return 0 ;;
              *) return 1 ;;
            esac
          }
          update-rust() { print -r -- forbidden-later-update >> "$F505_MUTATIONS"; }
          update-system --dry-run ;;
        gcloud-applies) _sys_update_gcloud_applies ;;
        uv-applies) _sys_update_uv_applies ;;
        *) return 91 ;;
      esac
    }
    local -i primary=0
    _f505_action > "$F505_CASE/stdout" 2> "$F505_CASE/stderr" <<< finite-open-input || primary=$?
    print -r -- "$primary" > "$F505_CASE/primary.status" || return 92
    return 0
  ' > "$F505_CASE/wrapper.stdout" 2> "$F505_CASE/wrapper.stderr" || wrapper=$?
  printf '%s\n' "$wrapper" > "$F505_CASE/wrapper.status" || return 1
  [[ "$wrapper" -eq 0 ]] || return 2
}

planning_primary() {
  local observed
  observed=$(cat "$F505_CASE/primary.status") || return 1
  [[ "$observed" =~ ^[0-9]+$ && "$observed" -eq "$1" ]] || return 2
  [[ -f "$F505_CASE/stdout" && -f "$F505_CASE/stderr" ]] || return 3
}

planning_probe() {
  local expected_count="${1:-1}"
  awk -F '\t' -v tool="$F505_TARGET_TOOL" -v candidate="$TEST_MOCK_BIN/$F505_TARGET_TOOL" \
    -v expected="$F505_TARGET_ARGS" -v expected_count="$expected_count" '
    $1 == tool || (tool == "dpkg" && $1 == "dpkg-query") {
      argv=""; for (i=10; i<NF; i++) argv=argv (i==10 ? "" : " ") $i
      query="-W -f=${db:Status-Status}\\n -- " substr(expected,4)
      if (argv != expected && !(tool == "brew" && expected ~ /^list (fnm|fzf)$/ && argv == "list --formula") && !($1 == "dpkg-query" && argv == query)) next
      reached++
      wanted=candidate; if ($1 == "dpkg-query") sub(/dpkg$/, "dpkg-query", wanted)
      if ($2 != wanted || $3 !~ /^[0-9]+$/ || $3 < 1 || $3 > 10 || $4 != "eof") bad++
      if (tool == "brew" && ($5 != 1 || $6 != 0 || $7 != 1 || $8 != 1)) bad++
    }
    END { exit !(reached == expected_count && bad == 0) }
  ' "$F505_LOG"
}

planning_success() {
  planning_select "$1" || return 1
  planning_observe || return 2
  planning_primary 0 || return 3
  [[ ! -s "$F505_CASE/stdout" ]] || return 4
  local count=1
  [[ "$1" != uv ]] || count=2
  planning_probe "$count" || return 5
}

planning_failure() {
  local expected="$2" actual_producer=0
  planning_select "$1" "$2" || return 1
  local -a argv=()
  read -r -a argv <<< "$F505_TARGET_ARGS" || return 2
  "$TEST_MOCK_BIN/$F505_TARGET_TOOL" "${argv[@]}" \
    > "$F505_CASE/qualified-producer.stdout" 2> "$F505_CASE/qualified-producer.stderr" \
    </dev/null || actual_producer=$?
  printf '%s\n' "$actual_producer" > "$F505_CASE/qualified-producer.status" || return 3
  [[ "$actual_producer" -eq "$2" ]] || return 4
  : > "$F505_LOG"
  planning_observe || return 5
  [[ "$2" != 17 ]] || expected=1
  planning_primary "$expected" || return 6
  [[ ! -s "$F505_CASE/stdout" && ! -s "$F505_MUTATIONS" ]] || return 7
  planning_probe 1 || return 8
  # A timeout supplied as124 is a returned-code fixture, not a measured deadline.
}

@test "sys planning probes: qualify finite open-unbounded and closed-bounded recorder observations" {
  planning_select prefix
  run run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    unset F505_BOUND_SECONDS
    "$TEST_MOCK_BIN/brew" --prefix <<< finite-input > "$HOME/open.stdout" 2> "$HOME/open.stderr"
  '
  [ "$status" -eq 0 ]
  grep -Fq "$F505_PREFIX" "$HOME/open.stdout"
  run planning_probe 1
  [ "$status" -eq 1 ]
  cp "$F505_LOG" "$HOME/open.tsv"
  : > "$F505_LOG"
  run run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    local -x HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_CURL_RETRIES=0
    local -x HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
    _sys_run_bounded_probe 3 65536 "$TEST_MOCK_BIN/brew" --prefix </dev/null \
      > "$HOME/closed.stdout" 2> "$HOME/closed.stderr"
  '
  [ "$status" -eq 0 ]
  cmp "$HOME/open.stdout" "$HOME/closed.stdout"
  planning_probe 1
  [ "$(cat "$F505_CASE/last-timed-producer.status")" = 0 ]
}

@test "sys planning probes: prefix observes the exact bounded external owner" { planning_success prefix; }

@test "sys planning probes: gcloud-brew observes the exact bounded external owner" { planning_success gcloud-brew; }

@test "sys planning probes: gcloud-apt observes the exact bounded external owner" { planning_success gcloud-apt; }

@test "sys planning probes: uv observes the exact bounded external owner" { planning_success uv; }

@test "sys planning probes: fnm observes the exact bounded external owner" { planning_success fnm; }

@test "sys planning probes: fzf-brew observes the exact bounded external owner" { planning_success fzf-brew; }

@test "sys planning probes: fzf-apt observes the exact bounded external owner" { planning_success fzf-apt; }

@test "sys planning probes: gcloud-brew producer 17 stops before mutation or owner fallback" { planning_failure gcloud-brew 17; }

@test "sys planning probes: gcloud-brew producer 124 stops before mutation or owner fallback" { planning_failure gcloud-brew 124; }

@test "sys planning probes: gcloud-brew producer 130 stops before mutation or owner fallback" { planning_failure gcloud-brew 130; }

@test "sys planning probes: gcloud-brew producer 143 stops before mutation or owner fallback" { planning_failure gcloud-brew 143; }

@test "sys planning probes: gcloud-apt producer 17 stops before mutation or owner fallback" { planning_failure gcloud-apt 17; }

@test "sys planning probes: gcloud-apt producer 124 stops before mutation or owner fallback" { planning_failure gcloud-apt 124; }

@test "sys planning probes: gcloud-apt producer 130 stops before mutation or owner fallback" { planning_failure gcloud-apt 130; }

@test "sys planning probes: gcloud-apt producer 143 stops before mutation or owner fallback" { planning_failure gcloud-apt 143; }

@test "sys planning probes: uv producer 17 stops before mutation or owner fallback" { planning_failure uv 17; }

@test "sys planning probes: uv producer 124 stops before mutation or owner fallback" { planning_failure uv 124; }

@test "sys planning probes: uv producer 130 stops before mutation or owner fallback" { planning_failure uv 130; }

@test "sys planning probes: uv producer 143 stops before mutation or owner fallback" { planning_failure uv 143; }

@test "sys planning probes: fnm producer 17 stops before mutation or owner fallback" { planning_failure fnm 17; }

@test "sys planning probes: fnm producer 124 stops before mutation or owner fallback" { planning_failure fnm 124; }

@test "sys planning probes: fnm producer 130 stops before mutation or owner fallback" { planning_failure fnm 130; }

@test "sys planning probes: fnm producer 143 stops before mutation or owner fallback" { planning_failure fnm 143; }

@test "sys planning probes: fzf-brew producer 17 stops before mutation or owner fallback" { planning_failure fzf-brew 17; }

@test "sys planning probes: fzf-brew producer 124 stops before mutation or owner fallback" { planning_failure fzf-brew 124; }

@test "sys planning probes: fzf-brew producer 130 stops before mutation or owner fallback" { planning_failure fzf-brew 130; }

@test "sys planning probes: fzf-brew producer 143 stops before mutation or owner fallback" { planning_failure fzf-brew 143; }

@test "sys planning probes: fzf-apt producer 17 stops before mutation or owner fallback" { planning_failure fzf-apt 17; }

@test "sys planning probes: fzf-apt producer 124 stops before mutation or owner fallback" { planning_failure fzf-apt 124; }

@test "sys planning probes: fzf-apt producer 130 stops before mutation or owner fallback" { planning_failure fzf-apt 130; }

@test "sys planning probes: fzf-apt producer 143 stops before mutation or owner fallback" { planning_failure fzf-apt 143; }

@test "sys planning probes: recorder independently rejects an open input despite a supplied short budget" {
  planning_select prefix
  run run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    local -x HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_CURL_RETRIES=0
    local -x HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
    _sys_run_with_timeout 3 "$TEST_MOCK_BIN/brew" --prefix <<< finite-input
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$status" > "$F505_CASE/bounded-open.actual.status"
  run planning_probe 1
  [ "$status" -eq 1 ]
}

@test "sys planning probes: recorder independently rejects missing budget despite closed input" {
  planning_select prefix
  run run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    unset F505_BOUND_SECONDS
    local -x HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_CURL_RETRIES=0
    local -x HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
    "$TEST_MOCK_BIN/brew" --prefix </dev/null
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$status" > "$F505_CASE/unbounded-closed.actual.status"
  run planning_probe 1
  [ "$status" -eq 1 ]
}

@test "sys planning probes: existing F4 Homebrew owner uses a bounded qualified manager" {
  export F505_TARGET_TOOL=brew F505_TARGET_ARGS=--prefix
  run run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    _sys_update_homebrew_owns_program starship "$F505_PREFIX/Cellar/starship/1/bin/starship" \
      > "$F505_CASE/stdout" 2> "$F505_CASE/stderr" <<< finite-input
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$status" > "$F505_CASE/existing-private.status"
  planning_probe 1
}

@test "sys planning probes: existing F4 Cargo owner inventory is bounded after proven Homebrew nonownership" {
  export F505_TARGET_TOOL=cargo F505_TARGET_ARGS='install --list'
  run run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    _sys_update_starship_owner "$HOME/.cargo/bin/starship" \
      > "$F505_CASE/stdout" 2> "$F505_CASE/stderr" <<< finite-input
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$status" > "$F505_CASE/existing-private.status"
  planning_probe 1
}

@test "sys planning probes: existing bounded Starship producer124 stops before Cargo fallback" {
  export F505_TARGET_TOOL=brew F505_TARGET_ARGS=--prefix F505_TARGET_RC=124
  ln -s "$HOME/.cargo/bin/starship" "$TEST_MOCK_BIN/starship"
  run run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    local -i private_rc=0 public_rc=0
    _sys_update_homebrew_owns_program starship "$HOME/.cargo/bin/starship" \
      > "$HOME/owner.stdout" 2> "$HOME/owner.stderr" || private_rc=$?
    print -r -- "$private_rc" > "$F505_CASE/bounded-private.status" || return 91
    : > "$F505_LOG"
    update-starship --dry-run > "$F505_CASE/stdout" 2> "$F505_CASE/stderr" || public_rc=$?
    print -r -- "$public_rc" > "$F505_CASE/primary.status" || return 92
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$F505_CASE/bounded-private.status")" = 124 ]
  planning_primary 124
  planning_probe 1
  run grep -Eq $'^cargo\t' "$F505_LOG"
  [ "$status" -eq 1 ]
}

@test "sys planning probes: existing bounded AWS producer124 stops before Snap fallback" {
  export F505_TARGET_TOOL=brew F505_TARGET_ARGS=--prefix F505_TARGET_RC=124
  printf '#!%s\nprintf "aws-cli/2.30.0 Python/3.12\\n"\n' "$BASH" > "$TEST_MOCK_BIN/aws"
  printf '#!%s\nprintf "snap-call\\n" >> "$HOME/snap-reached"\nexit 0\n' "$BASH" > "$TEST_MOCK_BIN/snap"
  chmod -- 700 "$TEST_MOCK_BIN/aws" "$TEST_MOCK_BIN/snap"
  run run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    local -i private_rc=0 public_rc=0
    _sys_update_homebrew_owns_program awscli "$TEST_MOCK_BIN/aws" \
      > "$HOME/owner.stdout" 2> "$HOME/owner.stderr" || private_rc=$?
    print -r -- "$private_rc" > "$F505_CASE/bounded-private.status" || return 91
    : > "$F505_LOG"
    update-awscli --dry-run > "$F505_CASE/stdout" 2> "$F505_CASE/stderr" || public_rc=$?
    print -r -- "$public_rc" > "$F505_CASE/primary.status" || return 92
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$F505_CASE/bounded-private.status")" = 124 ]
  planning_primary 124
  planning_probe 1
  [[ ! -e "$HOME/snap-reached" ]]
}

@test "sys planning probes: gcloud-plan producer 17 aborts the public aggregate before authorization" { planning_failure gcloud-plan 17; }

@test "sys planning probes: gcloud-plan producer 124 aborts the public aggregate before authorization" { planning_failure gcloud-plan 124; }

@test "sys planning probes: gcloud-plan producer 130 aborts the public aggregate before authorization" { planning_failure gcloud-plan 130; }

@test "sys planning probes: gcloud-plan producer 143 aborts the public aggregate before authorization" { planning_failure gcloud-plan 143; }

@test "sys planning probes: uv-plan producer 17 aborts the public aggregate before authorization" { planning_failure uv-plan 17; }

@test "sys planning probes: uv-plan producer 124 aborts the public aggregate before authorization" { planning_failure uv-plan 124; }

@test "sys planning probes: uv-plan producer 130 aborts the public aggregate before authorization" { planning_failure uv-plan 130; }

@test "sys planning probes: uv-plan producer 143 aborts the public aggregate before authorization" { planning_failure uv-plan 143; }

@test "sys planning probes: recorder rejects a bare manager word before executing it" {
  planning_select prefix
  run run_zsh '
    source "$HOME/planning-context.zsh" || return 90
    _sys_run_with_timeout 3 brew --prefix </dev/null
  '
  [ "$status" -eq 92 ]
  [[ ! -s "$F505_LOG" ]]
}

@test "sys planning probes: a successful invalid Homebrew prefix cannot authorize SDK self-update" {
  planning_select gcloud-brew
  export F505_PRINT_PREFIX=relative-prefix
  planning_observe
  planning_primary 1
  [[ ! -s "$F505_MUTATIONS" ]]
  planning_probe 1
}

@test "sys planning probes: a proven absent fixed-root SDK package cannot authorize self-update" {
  planning_select gcloud-apt 1
  planning_observe
  planning_primary 1
  [[ ! -s "$F505_MUTATIONS" ]]
  planning_probe 1
}

@test "sys planning probes: a documented absent fzf package preserves the independent-installation no-op" {
  planning_select fzf-apt 1
  planning_observe
  planning_primary 0
  [[ ! -s "$F505_MUTATIONS" && ! -s "$F505_CASE/stdout" ]]
  run grep -Fq 'Managed by APT' "$F505_CASE/stderr"
  [ "$status" -eq 1 ]
}

# These qualify the selected successful-inventory/status-data paths. On the
# intact base, legacy named queries do not reach these new input protocols;
# record that limitation separately instead of inventing an original red.
@test "sys planning probes: a late malformed formula record invalidates a successful inventory" {
  planning_select fzf-brew
  export F505_FORMULAS=$'fzf\ninvalid formula'
  planning_observe
  planning_primary 1
  [[ ! -s "$F505_MUTATIONS" ]]
  planning_probe 1
  run grep -E $'^dpkg(-query)?\t' "$F505_LOG"
  [ "$status" -eq 1 ]
}

@test "sys planning probes: duplicate formula records cannot prove ownership" {
  planning_select fzf-brew
  export F505_FORMULAS=$'fzf\nfzf'
  planning_observe
  planning_primary 1
  [[ ! -s "$F505_MUTATIONS" ]]
  planning_probe 1
}

@test "sys planning probes: a complete empty formula inventory permits APT fallback" {
  planning_select fzf-apt
  export F505_FORMULAS=''
  planning_observe
  planning_primary 0
  grep -Fq 'Managed by APT' "$F505_CASE/stderr"
  planning_probe 1
}

@test "sys planning probes: a successful unknown package state cannot prove fzf ownership" {
  planning_select fzf-apt
  export F505_PACKAGE_STATE=unpacked
  planning_observe
  planning_primary 1
  [[ ! -s "$F505_MUTATIONS" ]]
  planning_probe 1
}


@test "sys planning probes: a present unqualified manager is unknown rather than an absent owner" {
  local lookup="$TEST_TEMP_DIR/owner-lookup" name native mode
  mkdir -p "$lookup/base" "$lookup/absolute-manager" "$lookup/relative-manager"
  chmod -- 700 "$lookup" "$lookup/base" "$lookup/absolute-manager" "$lookup/relative-manager"
  for name in cat head mktemp wc cksum rm chmod env sed tail date id; do
    native=$(type -P "$name")
    ln -s "$native" "$lookup/base/$name"
  done
  ln -s "$TEST_MOCK_BIN/brew" "$lookup/absolute-manager/brew"
  ln -s "$TEST_MOCK_BIN/brew" "$lookup/relative-manager/brew"
  ln -s "$F505_PREFIX/Cellar/uv/1/bin/uv" "$lookup/base/uv"
  ln -s "$F505_PREFIX/Caskroom/gcloud-cli/1/bin/gcloud" "$lookup/base/gcloud"
  export F505_LOOKUP_ROOT="$lookup" F505_LOOKUP_MODE
  for mode in absolute relative absent function-only; do
    export F505_LOOKUP_MODE="$mode" F505_CASE="$lookup/$mode-results"
    export F505_LOG="$F505_CASE/producers.tsv" F505_MUTATIONS="$F505_CASE/mutations"
    export F505_TIMEOUT_LOG="$F505_CASE/timeout.tsv"
    mkdir "$F505_CASE"
    : > "$F505_LOG"
    : > "$F505_MUTATIONS"
    run run_zsh '
      source "$HOME/planning-context.zsh" || return 90
      builtin cd -q -- "$F505_LOOKUP_ROOT" || return 91
      case "$F505_LOOKUP_MODE" in
        absolute) PATH="$F505_LOOKUP_ROOT/absolute-manager:$F505_LOOKUP_ROOT/base" ;;
        relative) PATH="relative-manager:$F505_LOOKUP_ROOT/base" ;;
        absent|function-only) PATH="$F505_LOOKUP_ROOT/base" ;;
        *) return 92 ;;
      esac
      if [[ "$F505_LOOKUP_MODE" == function-only ]]; then
        brew() { print -r -- forbidden-function >> "$F505_CASE/function.calls"; return 97; }
      fi
      rehash
      local -i actual=0
      command -v brew > "$F505_CASE/command-v.stdout" 2> "$F505_CASE/command-v.stderr" || actual=$?
      print -r -- "$actual" > "$F505_CASE/command-v.status"
      actual=0
      builtin whence -p -- brew > "$F505_CASE/whence.stdout" 2> "$F505_CASE/whence.stderr" || actual=$?
      print -r -- "$actual" > "$F505_CASE/whence.status"
      local REPLY=""
      local -a reply=()
      actual=0
      _sys_tool_program brew || actual=$?
      print -r -- "$actual" > "$F505_CASE/tool.status"
      print -r -- "$REPLY" > "$F505_CASE/tool.reply"
      actual=0
      _sys_update_owner_program brew || actual=$?
      print -r -- "$actual" > "$F505_CASE/owner.status"
      print -r -- "$REPLY" > "$F505_CASE/owner.reply"
      actual=0
      update-uv-system > "$F505_CASE/uv.stdout" 2> "$F505_CASE/uv.stderr" || actual=$?
      print -r -- "$actual" > "$F505_CASE/uv.status"
      actual=0
      update-gcloud > "$F505_CASE/gcloud.stdout" 2> "$F505_CASE/gcloud.stderr" || actual=$?
      print -r -- "$actual" > "$F505_CASE/gcloud.status"
      if [[ "$F505_LOOKUP_MODE" == absolute ]]; then
        functions[_f505_lookup_command]="$functions[command]"
        command() {
          [[ "$1" != -v || "${2:-}" != brew ]] || return 1
          _f505_lookup_command "$@"
        }
        actual=0
        _sys_update_owner_program brew || actual=$?
        print -r -- "$actual" > "$F505_CASE/guarded-absence.status"
      fi
      return 0
    '
    printf '%s\n' "$status" > "$F505_CASE/wrapper.status"
    [ "$status" -eq 0 ]
  done
  # Preserve every observation before an oracle can stop this matrix.
  [ "$(cat "$lookup/absolute-results/tool.status")" = 0 ]
  [ "$(cat "$lookup/absolute-results/owner.status")" = 0 ]
  cmp "$lookup/absolute-results/tool.reply" "$lookup/absolute-results/owner.reply"
  [ "$(cat "$lookup/absolute-results/guarded-absence.status")" = 1 ]
  grep -Fxq "$(printf 'brew\tupgrade --no-ask uv')" "$lookup/absolute-results/mutations"
  for mode in absent function-only; do
    [ "$(cat "$lookup/$mode-results/whence.status")" = 1 ]
    [ "$(cat "$lookup/$mode-results/owner.status")" = 1 ]
    [ ! -s "$lookup/$mode-results/function.calls" ]
    grep -Fxq "$(printf 'uv\tself update')" "$lookup/$mode-results/mutations"
  done
  [ "$(cat "$lookup/relative-results/whence.status")" = 0 ]
  local resolved
  resolved=$(cat "$lookup/relative-results/whence.stdout")
  if [[ "$resolved" == /* ]]; then
    [ "$(cat "$lookup/relative-results/tool.status")" = 0 ]
    [ "$(cat "$lookup/relative-results/owner.status")" = 0 ]
    grep -Fxq "$(printf 'brew\tupgrade --no-ask uv')" "$lookup/relative-results/mutations"
  else
    [ "$(cat "$lookup/relative-results/owner.status")" = 2 ]
    [ "$(cat "$lookup/relative-results/uv.status")" = 1 ]
    [ "$(cat "$lookup/relative-results/gcloud.status")" = 1 ]
    [ ! -s "$lookup/relative-results/mutations" ]
  fi
}
