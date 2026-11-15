#!/usr/bin/env bats
# Shared confirmation protocol and the seven non-update consumer mappings.
# Returned stops are finite models; picker 130 denotes Esc, not SIGINT.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export F506_ROOT="$HOME/f506" F506_CASE_DIR="" NO_COLOR=1
  mkdir -p "$F506_ROOT" "$HOME/.config/zdx"
  chmod -- 700 "$HOME/.config" "$HOME/.config/zdx"
  cat > "$F506_ROOT/context.zsh" <<'ZSH'
emulate -R zsh
builtin cd -q -- "$TEST_TEMP_DIR" || return 90
source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 91
_SYS_CAPABILITIES=(os linux environment native architecture x86_64
  package_manager unavailable os_updates_backend unavailable service_manager systemd
  process_backend unavailable ports_backend unavailable privilege direct snapd available)
_SYS_CAPABILITIES_READY=1
_sys_capabilities_refresh() { return 0; }
_sys_has_systemd() { return 0; }
_sys_clean_plan() { print -r -- "npm cache|$HOME/safe-cache"; }
_sys_clean_privileged_labels() { reply=(); }
_sys_clean_run() { print -r -- cleanup >> "$F506_CASE_DIR/mutation.actual"; }
_sys_snap_ready() { return 0; }
_sys_disabled_snap_revisions() { print -r -- 'one 11'; }
_sys_remove_disabled_snap_revisions() {
  print -r -- snap >> "$F506_CASE_DIR/mutation.actual" || return 1
  reply=(1 0 0)
}
_sys_run_with_timeout() {
  [[ "$*" == '5 journalctl --disk-usage' ]] || return 97
  print -r -- 'Archived and active journals take up 1.0M in the file system.'
}
_sys_privilege_authorize() { reply=(); return 0; }
_sys_services_backend() { print -r -- systemd; }
_sys_services_state() { printf 'service\tsystemd\tdemo.service\tloaded\tactive\trunning\tenabled\n'; }
_sys_services_state_matches() { return 0; }
_sys_services_execute_systemd() { print -r -- service >> "$F506_CASE_DIR/mutation.actual"; }
_sys_processes_validate_signal_target() { [[ "$1" == 424242 ]]; }
_sys_processes_fingerprint() { printf 'process\t424242\t%s\tfixture-start\tfixture-worker\n' "$EUID"; }
_sys_processes_fingerprint_matches() { return 0; }
_sys_processes_signal_validated() { print -r -- signal >> "$F506_CASE_DIR/mutation.actual"; }
_sys_ports_record_is_current() { return 0; }
ZSH
  local tool
  for tool in snap journalctl sudo systemctl launchctl ps kill; do
    printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/$tool"
    cat >> "$TEST_MOCK_BIN/$tool" <<'MOCK'
if [[ "${0##*/}:$*" == 'journalctl:--vacuum-time=3d' ]]; then
  printf 'journal\n' >> "$F506_CASE_DIR/mutation.actual"
  exit 0
fi
printf '%s %s\n' "${0##*/}" "$*" >> "$F506_CASE_DIR/unexpected"
exit 97
MOCK
    chmod -- 700 "$TEST_MOCK_BIN/$tool"
  done
}

teardown() { cleanup_sandbox; }

f506_case() {
  export F506_CASE_DIR="$F506_ROOT/$1"
  mkdir "$F506_CASE_DIR" || return 1
  : > "$F506_CASE_DIR/unexpected" || return 2
  printf 'retained telemetry bytes\n' > "$HOME/.config/zdx/telemetry.json" || return 3
  chmod -- 600 "$HOME/.config/zdx/telemetry.json" || return 4
  cp "$HOME/.config/zdx/telemetry.json" "$F506_CASE_DIR/telemetry.before" || return 5
  file_identity "$HOME/.config/zdx/telemetry.json" > "$F506_CASE_DIR/identity.before" || return 6
}

f506_status() {
  local actual
  [[ -f "$F506_CASE_DIR/primary.status" ]] || return 1
  actual=$(cat "$F506_CASE_DIR/primary.status") || return 2
  [[ "$actual" =~ ^[0-9]+$ && "$actual" -eq "$1" ]] || return 3
  [[ -f "$F506_CASE_DIR/stdout" && ! -s "$F506_CASE_DIR/stdout" ]] || return 4
  [[ -f "$F506_CASE_DIR/stderr" ]] || return 5
  [[ -f "$F506_CASE_DIR/unexpected" && ! -s "$F506_CASE_DIR/unexpected" ]] || return 6
}

f506_pty_observe() {
  local body="$1" runner_rc=0
  export F506_PTY_PROGRAM="$F506_CASE_DIR/pty.zsh" SHELL=/bin/sh
  cat > "$F506_PTY_PROGRAM" <<'ZSH' || return 1
emulate -R zsh
export ZSH_CUSTOM="$TEST_SUITE_ROOT"
source "$TEST_SUITE_ROOT/functions.zsh" || exit 90
source "$F506_ROOT/context.zsh" || exit 91
_f506_action() {
ZSH
  printf '%s\n' "$body" >> "$F506_PTY_PROGRAM" || return 1
  cat >> "$F506_PTY_PROGRAM" <<'ZSH' || return 1
}
[[ -t 0 && -t 2 ]] || exit 93
print -r -- stdin-terminal:stderr-terminal > "$F506_CASE_DIR/terminal.actual" || exit 94
local -i primary=0
_f506_action > "$F506_CASE_DIR/stdout" || primary=$?
print -r -- "$primary" > "$F506_CASE_DIR/primary.status" || exit 92
exit 0
ZSH
  script -qefc 'exec zsh -f "$F506_PTY_PROGRAM"' \
    "$F506_CASE_DIR/pty.raw" < /dev/null \
    > "$F506_CASE_DIR/pty.wrapper.stdout" 2> "$F506_CASE_DIR/pty.wrapper.stderr" || runner_rc=$?
  printf '%s\n' "$runner_rc" > "$F506_CASE_DIR/pty.wrapper.status" || return 2
  [[ "$runner_rc" -eq 0 ]] || return 3
  [[ -f "$F506_CASE_DIR/primary.status" ]] || return 4
  tr -d '\r' < "$F506_CASE_DIR/pty.raw" > "$F506_CASE_DIR/stderr" || return 5
}


# All operations below are actual consumer functions up to the confirmation.
# Their downstream mutation boundaries are finite recorders or the private log.
f506_consumer_row() {
  local caller="$1" code="$2" expected result=0
  f506_case "$caller-$code" || return 1
  export F506_CONSUMER="$caller" F506_ASK_CODE="$code"
  expected=1
  case "$code" in 0|1) expected=0 ;; 130|143) expected="$code" ;; esac
  f506_pty_observe '
    _sys_confirm_ask() {
      print -r -- "$F506_ASK_CODE" > "$F506_CASE_DIR/ask.actual" || return 90
      print -r -- "$1" > "$F506_CASE_DIR/prompt.actual" || return 91
      return "$F506_ASK_CODE"
    }
    case "$F506_CONSUMER" in
      system) clean-system --quick ;;
      journal) clean-journal ;;
      snaps) clean-snaps ;;
      telemetry) sys-telemetry --clear ;;
      services) _sys_services_mutate start demo.service 0 ;;
      processes) _sys_processes_terminate 424242 0 0 ;;
      ports) _sys_ports_terminate_record $'\''port\ttcp\t3000\t127.0.0.1\t424242\tfixture-worker'\'' 0 0 ;;
      *) return 97 ;;
    esac
  ' || return 2
  f506_status "$expected" || return 3
  grep -Fxq "$code" "$F506_CASE_DIR/ask.actual" || return 4
  grep -Fxq stdin-terminal:stderr-terminal "$F506_CASE_DIR/terminal.actual" || return 5
  [[ -s "$F506_CASE_DIR/prompt.actual" ]] || return 6
  case "$caller" in
    snaps) grep -Fxq 'Remove 1 disabled revision?' "$F506_CASE_DIR/prompt.actual" || return 17 ;;
    telemetry) grep -Fxq 'Clear 1 log?' "$F506_CASE_DIR/prompt.actual" || return 18 ;;
  esac
  if [[ "$code" == 0 ]]; then
    if [[ "$caller" == telemetry ]]; then
      [[ -f "$HOME/.config/zdx/telemetry.json" && ! -s "$HOME/.config/zdx/telemetry.json" ]] || return 7
      file_identity "$HOME/.config/zdx/telemetry.json" > "$F506_CASE_DIR/identity.after" || return 8
      cmp "$F506_CASE_DIR/identity.before" "$F506_CASE_DIR/identity.after" && return 9
    else
      [[ -s "$F506_CASE_DIR/mutation.actual" ]] || return 10
    fi
  else
    [[ ! -e "$F506_CASE_DIR/mutation.actual" ]] || return 11
    cmp "$F506_CASE_DIR/telemetry.before" "$HOME/.config/zdx/telemetry.json" || return 12
    file_identity "$HOME/.config/zdx/telemetry.json" > "$F506_CASE_DIR/identity.after" || return 13
    cmp "$F506_CASE_DIR/identity.before" "$F506_CASE_DIR/identity.after" || return 14
    if [[ "$code" == 1 ]]; then
      grep -Eiq 'cancelled' "$F506_CASE_DIR/stderr" || return 15
      case "$caller" in
        snaps) grep -Fq 'Cancelled: nothing was removed.' "$F506_CASE_DIR/stderr" || return 19 ;;
        telemetry) grep -Fq 'Cancelled: nothing was cleared.' "$F506_CASE_DIR/stderr" || return 20 ;;
      esac
    else
      if grep -Eiq 'cancelled' "$F506_CASE_DIR/stderr"; then return 16; fi
    fi
  fi
  return 0
}

f506_consumer_matrix() {
  local caller="$1" code rc failures=0
  for code in 0 1 2 130 143; do
    if f506_consumer_row "$caller" "$code"; then rc=0
    else rc=$?; failures=$((failures+1)); fi
    printf '%s\t%s\t%s\n' "$caller" "$code" "$rc" >> "$F506_ROOT/$caller.matrix.tsv" || return 1
  done
  [[ "$(wc -l < "$F506_ROOT/$caller.matrix.tsv")" -eq 5 ]] || return 2
  [[ "$failures" -eq 0 ]] || return 3
}

@test "sys confirmation: private wrapper distinguishes decline errors and returned stops" {
  local code actual expected failures=0
  for code in 0 1 2 3 130 143; do
    f506_case "private-$code"
    export F506_ASK_CODE="$code"
    run run_zsh '
      source "$F506_ROOT/context.zsh" || exit 90
      _sys_confirm_ask() {
        print -r -- "$F506_ASK_CODE" > "$F506_CASE_DIR/ask.actual" || return 91
        return "$F506_ASK_CODE"
      }
      local -i rc=0
      _sys_confirm "Fixture confirmation?" > "$F506_CASE_DIR/stdout" \
        2> "$F506_CASE_DIR/stderr" || rc=$?
      print -r -- "$rc" > "$F506_CASE_DIR/primary.status" || exit 92
    '
    [ "$status" -eq 0 ]
    grep -Fxq "$code" "$F506_CASE_DIR/ask.actual"
    expected="$code"; [[ "$code" != 3 ]] || expected=2
    if f506_status "$expected"; then actual=0
    else actual=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$code" "$actual" >> "$F506_ROOT/private.matrix.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/private.matrix.tsv")" -eq 6 ]
  [ "$failures" -eq 0 ]
}

@test "sys confirmation: real PTY picker Yes No Esc and error retain their distinct protocol" {
  has_util_linux_script || skip 'util-linux script is required for the isolated PTY'
  local row name picker answer expected failures=0 rc
  for row in 'yes|0|Yes|0' 'no|0|No|1' 'escape|130||1' 'error|2||2'; do
    IFS='|' read -r name picker answer expected <<< "$row"
    f506_case "picker-$name"
    export F506_PICKER_CODE="$picker" F506_PICKER_ANSWER="$answer"
    printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/fzf"
    cat >> "$TEST_MOCK_BIN/fzf" <<'MOCK'
cat > "$F506_CASE_DIR/picker.stdin" || exit 90
printf '%s\0' "$@" > "$F506_CASE_DIR/picker.argv.nul" || exit 91
printf '%s\n' "$F506_PICKER_CODE" > "$F506_CASE_DIR/picker.branch" || exit 92
[[ -z "$F506_PICKER_ANSWER" ]] || printf '%s\n' "$F506_PICKER_ANSWER"
exit "$F506_PICKER_CODE"
MOCK
    chmod -- 700 "$TEST_MOCK_BIN/fzf"
    f506_pty_observe '_sys_confirm "Fixture confirmation?"'
    printf 'No\nYes\n' > "$F506_CASE_DIR/picker.expected"
    cmp "$F506_CASE_DIR/picker.expected" "$F506_CASE_DIR/picker.stdin"
    grep -Fxq "$picker" "$F506_CASE_DIR/picker.branch"
    grep -Fxq stdin-terminal:stderr-terminal "$F506_CASE_DIR/terminal.actual"
    if f506_status "$expected"; then rc=0
    else rc=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$name" "$rc" >> "$F506_ROOT/picker.matrix.tsv"
  done
  [ "$(wc -l < "$F506_ROOT/picker.matrix.tsv")" -eq 4 ]
  [ "$failures" -eq 0 ]
}

@test "sys confirmation: system consumer preserves decline errors and returned stops" {
  has_util_linux_script || skip 'util-linux script is required for the isolated terminal guard'
  f506_consumer_matrix system
}

@test "sys confirmation: journal consumer preserves decline errors and returned stops" {
  has_util_linux_script || skip 'util-linux script is required for the isolated terminal guard'
  f506_consumer_matrix journal
}

@test "sys confirmation: snaps consumer preserves decline errors and returned stops" {
  has_util_linux_script || skip 'util-linux script is required for the isolated terminal guard'
  f506_consumer_matrix snaps
}

@test "sys confirmation: telemetry consumer preserves decline errors and returned stops" {
  has_util_linux_script || skip 'util-linux script is required for the isolated terminal guard'
  f506_consumer_matrix telemetry
}

@test "sys confirmation: services consumer preserves decline errors and returned stops" {
  has_util_linux_script || skip 'util-linux script is required for the isolated terminal guard'
  f506_consumer_matrix services
}

@test "sys confirmation: processes consumer preserves decline errors and returned stops" {
  has_util_linux_script || skip 'util-linux script is required for the isolated terminal guard'
  f506_consumer_matrix processes
}

@test "sys confirmation: ports consumer preserves decline errors and returned stops" {
  has_util_linux_script || skip 'util-linux script is required for the isolated terminal guard'
  f506_consumer_matrix ports
}

@test "sys confirmation: missing terminal fails closed before asking or mutation" {
  f506_case no-terminal
  run run_zsh '
    source "$F506_ROOT/context.zsh" || exit 90
    _sys_confirm_ask() { print reached > "$F506_CASE_DIR/ask.actual"; return 0; }
    clean-snaps > "$F506_CASE_DIR/stdout" 2> "$F506_CASE_DIR/stderr"
  '
  [ "$status" -eq 1 ]
  [ -f "$F506_CASE_DIR/stdout" ]
  [ ! -s "$F506_CASE_DIR/stdout" ]
  [ ! -e "$F506_CASE_DIR/ask.actual" ]
  [ ! -e "$F506_CASE_DIR/mutation.actual" ]
  grep -Fq 'Non-interactive snap cleanup requires --yes.' "$F506_CASE_DIR/stderr"
}
