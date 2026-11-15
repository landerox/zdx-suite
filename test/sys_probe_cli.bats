#!/usr/bin/env bats
# Selected native diagnostic probes and parse-before-probe public contracts.
# Finite returned-status models; no watchdog or native service experiment.
# BATS isolates each test and setup resets these exported fixture paths.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  unset SYS_PROBE_BOUND_SECONDS
  export SYS_PROBE_BIN="$HOME/native bin"
  export SYS_PROBE_REAL_ZSH
  SYS_PROBE_REAL_ZSH=$(type -P zsh)
  export SYS_PROBE_CALLS="$HOME/producers.tsv"
  export SYS_PROBE_CAPABILITY_CALLS="$HOME/capabilities.tsv"
  export SYS_PROBE_FUNCTION_CALLS="$HOME/functions.log"
  export SYS_PROBE_DENIED="$HOME/denied.log"
  export SYS_PROBE_OMZ="$HOME/omz tree"
  export SYS_PROBE_PRODUCER_RC=0
  mkdir -p "$SYS_PROBE_BIN" "$SYS_PROBE_OMZ" "$HOME/support bin"
  : > "$SYS_PROBE_CALLS"
  : > "$SYS_PROBE_CAPABILITY_CALLS"
  : > "$SYS_PROBE_FUNCTION_CALLS"
  : > "$SYS_PROBE_DENIED"
  printf '#!%s\n' "$BASH" > "$HOME/probe-program"
  cat >> "$HOME/probe-program" <<'MOCK'
tool=${0##*/}
# Only version invocations are modelled. The outer real Zsh remains frozen.
if [[ "$tool" == zsh && "$*" != --version ]]; then
  exec "$SYS_PROBE_REAL_ZSH" "$@"
fi
stdin_state=eof
if IFS= read -r input_line; then stdin_state=input; fi
sequence=1
while IFS= read -r previous; do sequence=$((sequence + 1)); done < "$SYS_PROBE_CALLS"
printf '%s\0' "$0" "$@" > "$SYS_PROBE_CALLS.$sequence.argv.nul"
printf '%s\t%s\t%s\t%s\t%s\n' "${LC_ALL-}" \
  "${HOMEBREW_CURL_RETRIES-}" "${HOMEBREW_NO_ANALYTICS-}" \
  "${HOMEBREW_NO_ENV_HINTS-}" "${HOMEBREW_NO_AUTO_UPDATE-}" \
  > "$SYS_PROBE_CALLS.$sequence.environment.tsv"
{
  printf '%s\t%s\t%s\t%s\t' "$tool" "$0" \
    "${SYS_PROBE_BOUND_SECONDS:-none}" "$stdin_state"
  printf '%s\t' "$@"
  printf '\n'
} >> "$SYS_PROBE_CALLS"
emit() {
  case "$tool:$*" in
    'git:--version') printf 'git version 2.46.0\n' ;;
    'git:-C '*" describe --tags") printf 'v2026-fixture\n' ;;
    'python3:--version') printf 'Python 3.13.0\n' ;;
    'uv:--version') printf 'uv 0.8.0\n' ;;
    'node:--version') printf 'v22.0.0\n' ;;
    'rustc:--version') printf 'rustc 1.89.0 (fixture)\n' ;;
    'go:version') printf 'go version go1.25.0 fixture/fixture\n' ;;
    'docker:--version') printf 'Docker version 28.0.0, build fixture\n' ;;
    'gcloud:--version') printf 'Google Cloud SDK 500.0.0\n' ;;
    'terraform:--version') printf 'Terraform v1.13.0\n' ;;
    'tofu:--version') printf 'OpenTofu v1.10.0\n' ;;
    'kubectl:version --client -o json') printf '{"clientVersion":{"gitVersion":"v1.33.0"}}\n' ;;
    'helm:version --short') printf 'v3.18.0+fixture\n' ;;
    'starship:--version') printf 'starship 1.23.0\n' ;;
    'zsh:--version') printf 'zsh 5.9 (fixture)\n' ;;
    'npm:list -g --depth=0') printf '/fixture\npackage@1.0.0\n' ;;
    'pipx:list --short') printf 'one 1.0\ntwo 2.0\n' ;;
    'uname:-s') printf 'Linux\n' ;;
    'uname:-m') printf 'x86_64\n' ;;
    'uname:-r') printf '6.0-fixture\n' ;;
    'ps:-eo pid=,uid=,pcpu=,pmem=,comm= --sort=-pcpu') printf '42 1000 0.0 0.0 fixture\n' ;;
    'ps:-p '*" -o uid= -o lstart= -o comm=") printf '1000 Fri Jul 24 12:00:00 2026 fixture\n' ;;
    'ps:-eo pid=,stat=,comm=') printf '42 Z fixture\n43 S live\n' ;;
    'sysctl:-n kern.boottime') printf '{ sec = 1700000000, usec = 0 }\n' ;;
    'sysctl:-n vm.loadavg') printf '{ 0.1 0.2 0.3 }\n' ;;
    'date:+%s') printf '1700000042\n' ;;
    'brew:list --formula') printf 'one\ntwo\n' ;;
    'brew:list --cask') printf 'three\n' ;;
    'xcode-select:-p') printf '%s\n' "$SYS_PROBE_CLT_ROOT" ;;
    'softwareupdate:--list')
      printf 'Software Update Tool\n* Label: Fixture-1.0\n    Title: Fixture, Version: 1.0, Size: 1K, Recommended: YES,\n'
      printf 'fixture list notice\n' >&2
      ;;
    *) printf '%s %s\n' "$tool" "$*" >> "$SYS_PROBE_DENIED"; return 97 ;;
  esac
  return "$SYS_PROBE_PRODUCER_RC"
}
emit "$@"
observed=$?
printf '%s\n' "$observed" > "$SYS_PROBE_CALLS.$sequence.primary.status"
exit "$observed"
MOCK
  local tool real_program
  for tool in git python3 uv node rustc go docker gcloud terraform tofu kubectl helm starship zsh npm pipx uname ps sysctl date brew xcode-select softwareupdate; do
    cp "$HOME/probe-program" "$SYS_PROBE_BIN/$tool"
    chmod -- 700 "$SYS_PROBE_BIN/$tool"
  done
  for tool in head wc cat mktemp rm awk sed chmod; do
    real_program=$(type -P "$tool")
    ln -s "$real_program" "$HOME/support bin/$tool"
  done
  cat > "$HOME/probe-context.zsh" <<'ZSH'
emulate -R zsh
source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 90
path=("$SYS_PROBE_BIN" $path)
_sys_has_capability() {
  printf 'predicate\t%s\n' "$1" >> "$SYS_PROBE_CAPABILITY_CALLS" || return 98
  return 1
}
_sys_capabilities_refresh() {
  print -r -- refresh >> "$SYS_PROBE_CAPABILITY_CALLS" || return 98
  _SYS_CAPABILITIES_READY=1
  return 0
}
_sys_capabilities_refresh_for_command() {
  print -r -- refresh-for-command >> "$SYS_PROBE_CAPABILITY_CALLS" || return 98
  return 0
}
functions[_sys_probe_original_capability_value]="${functions[_sys_capability_value]}"
_sys_capability_value() {
  printf 'value\t%s\n' "$1" >> "$SYS_PROBE_CAPABILITY_CALLS" || return 98
  _sys_probe_original_capability_value "$@"
}
# Finite callback model: it preserves ordinary function lookup, closes nothing
# itself, and only tags the supplied budget. No watchdog or signal is run.
_sys_run_with_timeout() {
  local -x SYS_PROBE_BOUND_SECONDS="$1"
  shift
  [[ "$SYS_PROBE_BOUND_SECONDS" == <-> ]] || return 98
  (( SYS_PROBE_BOUND_SECONDS > 0 && SYS_PROBE_BOUND_SECONDS <= 120 )) || return 98
  "$@"
}
_zdx_run_with_timeout() { _sys_run_with_timeout "$@"; }
ZSH
  cat > "$HOME/facts-context.zsh" <<'ZSH'
_SYS_CAPABILITIES=(os linux environment native architecture x86_64 package_manager unavailable)
_SYS_CAPABILITIES_READY=1
_sys_diag_os_name() { print -r -- 'Fixture OS'; }
_sys_diag_memory_record() { printf '1048576\t524288\t0\t0\n'; }
_sys_diag_cpu_record() { printf '2\tFixture CPU\n'; }
_sys_diag_runtime_record() { printf '42\t0.1\t0.2\t0.3\n'; }
_sys_diag_root_volume() { print -r -- /; }
_sys_diag_disk_record() { printf 'fixturefs\t100\t50\t50\t50\n'; }
_sys_diag_package_records() { return 0; }
ZSH
}

teardown() {
  cleanup_sandbox
}

# Exactly one real producer with the selected absolute mock, a short supplied
# deadline and closed stdin. A configured mock return code is not reach proof.
# Current fixed argv contain no tabs; prefix paths are supplied as awk data.
assert_sys_probe() {
  local seconds=""
  if [[ "${1:-}" == --seconds ]]; then
    seconds="$2"
    shift 2
  fi
  local tool="$1" row="" actual_status=""
  shift
  row=$(awk -F '\t' -v tool="$tool" -v candidate="$SYS_PROBE_BIN/$tool" \
    -v expected="$*" -v seconds="$seconds" '
    $1 == tool {
      argv = ""
      for (i = 5; i < NF; i++) argv = argv (i == 5 ? "" : " ") $i
      if (argv != expected) next
      reached++
      selected = NR
      if ($2 != candidate || $3 !~ /^[0-9]+$/ || $3 < 1 || $3 > 120 ||
          (seconds != "" && $3 != seconds) || $4 != "eof") bad++
    }
    END {
      if (reached != 1 || bad != 0) exit 1
      print selected
    }
  ' "$SYS_PROBE_CALLS") || return 1
  printf '%s\0' "$SYS_PROBE_BIN/$tool" "$@" \
    > "$HOME/probe-expected.argv.nul" || return 2
  [ -f "$SYS_PROBE_CALLS.$row.argv.nul" ] || return 3
  cmp "$HOME/probe-expected.argv.nul" "$SYS_PROBE_CALLS.$row.argv.nul" \
    || return 4
  [ -f "$SYS_PROBE_CALLS.$row.primary.status" ] || return 5
  IFS= read -r actual_status < "$SYS_PROBE_CALLS.$row.primary.status" || return 6
  [[ "$actual_status" =~ ^[0-9]+$ && "$actual_status" -le 255 ]] || return 7
  return 0
}

@test "sys probe CLI: recorder qualification: finite open unbounded input differs from bounded closed input" {
  # This qualifies the recorder's supplied-budget/EOF fields only. No producer
  # hangs, native deadline, watchdog, process tree or signal is exercised.
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    unset SYS_PROBE_BOUND_SECONDS
    "$SYS_PROBE_BIN/git" --version <<< "finite-open-canary" \
      > "$HOME/open.stdout" 2> "$HOME/open.stderr"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$status" > "$HOME/open.primary.status"
  [ -f "$HOME/open.stdout" ]
  grep -Fxq 'git version 2.46.0' "$HOME/open.stdout"
  [ -f "$HOME/open.stderr" ]
  [ ! -s "$HOME/open.stderr" ]
  awk -F '\t' -v candidate="$SYS_PROBE_BIN/git" '
    NR == 1 && NF == 6 && $1 == "git" && $2 == candidate &&
      $3 == "none" && $4 == "input" && $5 == "--version" { valid=1 }
    END { exit !(NR == 1 && valid) }
  ' "$SYS_PROBE_CALLS"
  run assert_sys_probe git --version
  [ "$status" -eq 1 ]
  printf '%s\n' "$status" > "$HOME/open.probe-assertion.status"
  mv "$SYS_PROBE_CALLS" "$HOME/open.calls.tsv"
  local artifact
  for artifact in "$SYS_PROBE_CALLS".1.*; do
    mv "$artifact" "$HOME/open.calls.tsv${artifact#"$SYS_PROBE_CALLS"}" || return 1
  done
  : > "$SYS_PROBE_CALLS"

  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    unset SYS_PROBE_BOUND_SECONDS
    _sys_run_bounded_probe 3 65536 "$SYS_PROBE_BIN/git" --version </dev/null \
      > "$HOME/closed.stdout" 2> "$HOME/closed.stderr"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$status" > "$HOME/closed.primary.status"
  [ -f "$HOME/closed.stdout" ]
  grep -Fxq 'git version 2.46.0' "$HOME/closed.stdout"
  [ -f "$HOME/closed.stderr" ]
  [ ! -s "$HOME/closed.stderr" ]
  awk -F '\t' -v candidate="$SYS_PROBE_BIN/git" '
    NR == 1 && NF == 6 && $1 == "git" && $2 == candidate &&
      $3 == "3" && $4 == "eof" && $5 == "--version" { valid=1 }
    END { exit !(NR == 1 && valid) }
  ' "$SYS_PROBE_CALLS"
  run assert_sys_probe git --version
  [ "$status" -eq 0 ]
  printf '%s\n' "$status" > "$HOME/closed.probe-assertion.status"
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: Git rendering uses the selected external program under shell lookup" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    git() {
      print -r -- shadow >> "$SYS_PROBE_FUNCTION_CALLS"
      print -r -- "git version 99.0.0-function"
    }
    # Establish that the planted function actually wins a bare lookup.
    git --version >"$HOME/function-control"
    [[ -s "$SYS_PROBE_FUNCTION_CALLS" ]] || exit 91
    : > "$SYS_PROBE_FUNCTION_CALLS"
    _sys_tool_program git || exit 92
    [[ "$REPLY" == "$SYS_PROBE_BIN/git" ]] || exit 93
    NO_COLOR=1 _sys_diag_render_tool Git git <<< "stdin-canary" \
      >"$HOME/out" 2>"$HOME/err"
  '
  [ "$status" -eq 0 ]
  grep -Fq 99.0.0-function "$HOME/function-control"
  [ ! -s "$HOME/out" ]
  grep -Fq 2.46.0 "$HOME/err"
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  assert_sys_probe git --version
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: npm and pipx counts use their vetted external inventories" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    npm() {
      print -r -- npm-shadow >> "$SYS_PROBE_FUNCTION_CALLS"
      printf "/shadow\na\nb\nc\n"
    }
    pipx() {
      print -r -- pipx-shadow >> "$SYS_PROBE_FUNCTION_CALLS"
      printf "a\nb\nc\n"
    }
    npm list -g --depth=0 >/dev/null
    pipx list --short >/dev/null
    local -i function_controls
    function_controls=$(command wc -l < "$SYS_PROBE_FUNCTION_CALLS") || exit 91
    (( function_controls == 2 )) || exit 91
    : > "$SYS_PROBE_FUNCTION_CALLS"
    _sys_diag_npm_global_count <<< "stdin-canary" >"$HOME/npm.out" \
      2>"$HOME/npm.err" || exit $?
    _sys_diag_pipx_count <<< "stdin-canary" >"$HOME/pipx.out" \
      2>"$HOME/pipx.err"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/npm.out")" = 1 ]
  [ "$(cat "$HOME/pipx.out")" = 2 ]
  [ ! -s "$HOME/npm.err" ]
  [ ! -s "$HOME/pipx.err" ]
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  assert_sys_probe npm list -g --depth=0
  assert_sys_probe pipx list --short
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: finite failed producers cannot publish a plausible version" {
  local producer_rc
  for producer_rc in 17 124 130 143; do
    export SYS_PROBE_PRODUCER_RC="$producer_rc"
    export SYS_PROBE_CALLS="$HOME/failure-$producer_rc.calls.tsv"
    : > "$SYS_PROBE_CALLS"
    run run_zsh '
      source "$HOME/probe-context.zsh" || exit 90
      _sys_diag_tool_version git <<< "stdin-canary" \
        >"$HOME/failure-$SYS_PROBE_PRODUCER_RC.out" \
        2>"$HOME/failure-$SYS_PROBE_PRODUCER_RC.err"
    '
    printf '%s\n' "$status" > "$HOME/failure-$producer_rc.primary.status"
  done
  for producer_rc in 17 124 130 143; do
    export SYS_PROBE_CALLS="$HOME/failure-$producer_rc.calls.tsv"
    [ "$(cat "$HOME/failure-$producer_rc.primary.status")" -eq "$producer_rc" ]
    [ ! -s "$HOME/failure-$producer_rc.out" ]
    [ ! -s "$HOME/failure-$producer_rc.err" ]
    [ "$(cat "$SYS_PROBE_CALLS.1.primary.status")" -eq "$producer_rc" ]
    assert_sys_probe git --version
  done
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: service grammar: universally malformed service IDs stop before backend selection" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    : > "$SYS_PROBE_CAPABILITY_CALLS" || exit 91
    _sys_services_backend() {
      print -r -- "$SYS_PROBE_BACKEND" >> "$HOME/backend.log" || return 98
      local service_backend
      service_backend=$(_sys_capability_value service_manager) || return $?
      [[ "$service_backend" == "$SYS_PROBE_BACKEND" ]] || return 97
      [[ "$service_backend" != unavailable ]] || return 1
      print -r -- "$service_backend"
    }
    _sys_services_state() { print -r -- state >> "$HOME/later.log"; return 97; }
    _sys_confirm() { print -r -- prompt >> "$HOME/later.log"; return 97; }
    _sys_services_execute_systemd() { print -r -- execute >> "$HOME/later.log"; return 97; }
    _sys_services_execute_launchd() { print -r -- execute >> "$HOME/later.log"; return 97; }
    local SYS_PROBE_BACKEND action service_id long_id case_number=0 rc
    printf -v long_id "%0256d" 0
    for SYS_PROBE_BACKEND in unavailable systemd launchd; do
      for action in show start stop restart enable disable; do
        for service_id in -x "a b" a/b "" "$long_id"; do
          (( case_number++ ))
          # The real lookup/ensure path must call the finite refresh if reached.
          # Invalid parsing should prevent both boundaries entirely.
          _SYS_CAPABILITIES=(service_manager "$SYS_PROBE_BACKEND")
          _SYS_CAPABILITIES_READY=0
          _SYS_DISPATCH_CAPABILITIES_FRESH=0
          _SYS_DISPATCH_CAPABILITIES_PENDING=0
          if [[ "$action" == show ]]; then
            sys-services --show "$service_id" \
              >"$HOME/service-$case_number.out" 2>"$HOME/service-$case_number.err"
          else
            sys-services "--$action" "$service_id" --yes \
              >"$HOME/service-$case_number.out" 2>"$HOME/service-$case_number.err"
          fi
          rc=$?
          print -r -- "$case_number:$rc" >> "$HOME/parser-statuses" || exit 92
        done
      done
    done
  '
  [ "$status" -eq 0 ]
  awk -F: '$2 != 2 { bad++ } END { exit !(NR == 90 && bad == 0) }' "$HOME/parser-statuses"
  local n
  for (( n=1; n<=90; n++ )); do
    [ ! -s "$HOME/service-$n.out" ]
    [ -s "$HOME/service-$n.err" ]
  done
  [ ! -e "$HOME/backend.log" ]
  [ ! -e "$HOME/later.log" ]
  [ -f "$SYS_PROBE_CAPABILITY_CALLS" ]
  [ ! -s "$SYS_PROBE_CAPABILITY_CALLS" ]
  [ ! -s "$SYS_PROBE_CALLS" ]
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: service grammar: valid IDs reach backend and state while unavailable stays operational" {
  local backend service_id
  for backend in unavailable systemd launchd; do
    export SYS_PROBE_BACKEND="$backend"
    service_id=demo.service
    [[ "$backend" != launchd ]] || service_id=com.example.demo
    export SYS_PROBE_SERVICE_ID="$service_id"
    run run_zsh '
      source "$HOME/probe-context.zsh" || exit 90
      : > "$SYS_PROBE_CAPABILITY_CALLS" || exit 91
      _SYS_CAPABILITIES=(service_manager "$SYS_PROBE_BACKEND")
      _SYS_CAPABILITIES_READY=0
      _SYS_DISPATCH_CAPABILITIES_FRESH=0
      _SYS_DISPATCH_CAPABILITIES_PENDING=0
      _sys_services_backend() {
        print -r -- reached >> "$HOME/backend-$SYS_PROBE_BACKEND.log" || return 98
        local service_backend
        service_backend=$(_sys_capability_value service_manager) || return $?
        [[ "$service_backend" == "$SYS_PROBE_BACKEND" ]] || return 97
        [[ "$service_backend" != unavailable ]] || return 1
        print -r -- "$service_backend"
      }
      _sys_services_state() {
        print -r -- "$1:$2" >> "$HOME/state-$SYS_PROBE_BACKEND.log"
        printf "service\t%s\t%s\tloaded\tactive\trunning\tenabled\n" "$1" "$2"
      }
      NO_COLOR=1 sys-services --show "$SYS_PROBE_SERVICE_ID" \
        >"$HOME/control-$SYS_PROBE_BACKEND.out" 2>"$HOME/control-$SYS_PROBE_BACKEND.err"
    '
    if [[ "$backend" == unavailable ]]; then
      [ "$status" -eq 1 ]
      [ ! -e "$HOME/state-$backend.log" ]
    else
      [ "$status" -eq 0 ]
      [ "$(cat "$HOME/state-$backend.log")" = "$backend:$service_id" ]
      grep -Fq "$service_id" "$HOME/control-$backend.err"
    fi
    [ "$(cat "$HOME/backend-$backend.log")" = reached ]
    [ ! -s "$HOME/control-$backend.out" ]
    grep -Fxq $'value\tservice_manager' "$SYS_PROBE_CAPABILITY_CALLS"
    grep -Fxq refresh "$SYS_PROBE_CAPABILITY_CALLS"
    mv "$SYS_PROBE_CAPABILITY_CALLS" "$HOME/control-$backend.capabilities.tsv"
  done
}

@test "sys probe CLI: diagnostic grammar: explicit empty operands survive direct nested and lazy forwarding" {
  local route command_name
  for route in eager-direct eager-nested lazy-direct lazy-nested lazy-master; do
    for command_name in sys-info sys-health; do
      export SYS_PROBE_ROUTE="$route" SYS_PROBE_COMMAND="$command_name"
      run run_zsh '
        # Preload only the inert capability module to keep this finite
        # recorder across subsequent public lazy loading. No host detection.
        source "$ZSH_CUSTOM/functions/sys/sys-capabilities.zsh" || exit 90
        _sys_capabilities_refresh() {
          print -r -- refresh >> "$HOME/cli-probes.log"
          return 97
        }
        [[ "$SYS_PROBE_ROUTE" != eager-* ]] \
          || source "$ZSH_CUSTOM/functions/sys-menu.zsh" || exit 91
        case "$SYS_PROBE_ROUTE" in
          *-direct) "$SYS_PROBE_COMMAND" "" ;;
          *-nested) sys-menu "$SYS_PROBE_COMMAND" "" ;;
          lazy-master) zdx sys "$SYS_PROBE_COMMAND" "" ;;
          *) exit 92 ;;
        esac >"$HOME/cli.out" 2>"$HOME/cli.err"
      '
      [ "$status" -eq 2 ]
      [ ! -s "$HOME/cli.out" ]
      [ -s "$HOME/cli.err" ]
      [ ! -e "$HOME/cli-probes.log" ]
      [ ! -s "$SYS_PROBE_CALLS" ]
    done
  done
}

@test "sys probe CLI: diagnostic grammar: help remains probe-free and zero operands reach the finite recorder" {
  local command_name
  for command_name in sys-info sys-health; do
    export SYS_PROBE_COMMAND="$command_name"
    run run_zsh '
      source "$ZSH_CUSTOM/functions/sys-menu.zsh" || exit 90
      _sys_capabilities_refresh() {
        print -r -- refresh >> "$HOME/control-probes.log"
        return 97
      }
      "$SYS_PROBE_COMMAND" --help >"$HOME/help.out" 2>"$HOME/help.err" || exit 91
      [[ ! -e "$HOME/control-probes.log" ]] || exit 92
      "$SYS_PROBE_COMMAND" >"$HOME/zero.out" 2>"$HOME/zero.err"
    '
    [ "$status" -eq 1 ]
    [ ! -s "$HOME/help.out" ]
    grep -Fq Usage: "$HOME/help.err"
    [ ! -s "$HOME/zero.out" ]
    [ -s "$HOME/zero.err" ]
    [ "$(cat "$HOME/control-probes.log")" = refresh ]
    rm -- "$HOME/control-probes.log"
  done
}

@test "sys probe CLI: native identity: all thirteen version routes bypass qualified same-name functions" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    local tool rc
    local -a tools=(git python3 uv node rustc go docker gcloud terraform tofu kubectl helm starship)
    for tool in "${tools[@]}"; do
      functions[$tool]='"'"'print -r -- shadow >> "$SYS_PROBE_FUNCTION_CALLS"; print -r -- "shadow version"'"'"'
      "$tool" --version >/dev/null || exit 91
    done
    local -i controls=$(command wc -l < "$SYS_PROBE_FUNCTION_CALLS")
    (( controls == 13 )) || exit 92
    : > "$SYS_PROBE_FUNCTION_CALLS"
    for tool in "${tools[@]}"; do
      rc=0
      _sys_diag_tool_version "$tool" <<< "finite-input" \
        >"$HOME/version-$tool.out" 2>"$HOME/version-$tool.err" || rc=$?
      print -r -- "$rc" > "$HOME/version-$tool.primary.status"
    done
  '
  [ "$status" -eq 0 ]
  local tool version args
  local -a arguments
  while IFS=$'\t' read -r tool version args; do
    [ "$(cat "$HOME/version-$tool.primary.status")" -eq 0 ]
    [ "$(cat "$HOME/version-$tool.out")" = "$version" ]
    [ ! -s "$HOME/version-$tool.err" ]
    read -r -a arguments <<< "$args"
    assert_sys_probe --seconds 3 "$tool" "${arguments[@]}"
  done <<'EXPECTED'
git	2.46.0	--version
python3	3.13.0	--version
uv	0.8.0	--version
node	v22.0.0	--version
rustc	1.89.0	--version
go	1.25.0	version
docker	28.0.0	--version
gcloud	500.0.0	--version
terraform	v1.13.0	--version
tofu	v1.10.0	--version
kubectl	v1.33.0	version --client -o json
helm	3.18.0+fixture	version --short
starship	1.23.0	--version
EXPECTED
  [ "$(wc -l < "$SYS_PROBE_CALLS")" -eq 13 ]
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: text and JSON preserve versions shell OMZ and package observations" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    source "$HOME/facts-context.zsh" || exit 91
    export ZSH="$SYS_PROBE_OMZ"
    local tool mode rc
    for tool in git python3 uv node rustc go docker gcloud terraform tofu kubectl helm starship zsh npm pipx; do
      functions[$tool]='"'"'print -r -- shadow >> "$SYS_PROBE_FUNCTION_CALLS"; print -r -- "shadow version"'"'"'
      "$tool" --version >/dev/null || exit 92
    done
    : > "$SYS_PROBE_FUNCTION_CALLS"
    for mode in text json; do
      export SYS_PROBE_CALLS="$HOME/public-$mode.calls.tsv"
      : > "$SYS_PROBE_CALLS"
      rc=0
      if [[ "$mode" == json ]]; then
        sys-info --json <<< "finite-input" >"$HOME/$mode.out" 2>"$HOME/$mode.err" || rc=$?
      else
        sys-info <<< "finite-input" >"$HOME/$mode.out" 2>"$HOME/$mode.err" || rc=$?
      fi
      print -r -- "$rc" > "$HOME/$mode.primary.status"
    done
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/text.primary.status")" -eq 0 ]
  [ "$(cat "$HOME/json.primary.status")" -eq 0 ]
  [ ! -s "$HOME/text.out" ]
  grep -Fq 'zsh 5.9' "$HOME/text.err"
  grep -Fq 'v2026-fixture' "$HOME/text.err"
  grep -Fq 'NPM global:' "$HOME/text.err"
  grep -Fq 'pipx packages:' "$HOME/text.err"
  jq -e '.schema == "zdx.sys-info.v1" and .shell.zsh_version == "5.9" and
    .oh_my_zsh == {installed:true, version:"v2026-fixture"} and
    .packages.npm_global == 1 and .packages.pipx == 2 and
    .tools == {git:"2.46.0", python:"3.13.0", uv:"0.8.0", node:"v22.0.0",
      rust:"1.89.0", go:"1.25.0", docker:"28.0.0", gcloud:"500.0.0",
      terraform:"v1.13.0", opentofu:"v1.10.0", kubectl:"v1.33.0",
      helm:"3.18.0+fixture", starship:"1.23.0"}' "$HOME/json.out" >/dev/null
  [ ! -s "$HOME/json.err" ]
  local mode
  for mode in text json; do
    export SYS_PROBE_CALLS="$HOME/public-$mode.calls.tsv"
    assert_sys_probe git --version
    assert_sys_probe --seconds 3 git -C "$SYS_PROBE_OMZ" describe --tags
    assert_sys_probe --seconds 3 zsh --version
    assert_sys_probe --seconds 5 npm list -g --depth=0
    assert_sys_probe --seconds 5 pipx list --short
  done
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: cold public refresh resolves bootstrap tools without registry recursion" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh" || exit 90
    path=("$SYS_PROBE_BIN" $path)
    source "$HOME/facts-context.zsh" || exit 91
    _SYS_CAPABILITIES=()
    _SYS_CAPABILITIES_READY=0
    # Only the WSL detector is a finite platform fixture. Registry, refresh,
    # lookup and process-backend functions remain the real source bodies.
    _sys_wsl_detect() { print -r -- detector >> "$HOME/cold.detector"; return 1; }
    _sys_run_with_timeout() {
      local -x SYS_PROBE_BOUND_SECONDS="$1"
      shift
      printf "%s\0" "$@" >> "$HOME/cold.boundaries.nul"
      "$@"
    }
    uname() { print -r -- uname-shadow >> "$SYS_PROBE_FUNCTION_CALLS"; print -r -- SHADOW; }
    env() { print -r -- env-shadow >> "$SYS_PROBE_FUNCTION_CALLS"; return 97; }
    uname -s >/dev/null
    env true || :
    local -i controls=$(command wc -l < "$SYS_PROBE_FUNCTION_CALLS")
    (( controls == 2 )) || exit 92
    : > "$SYS_PROBE_FUNCTION_CALLS"
    _sys_diag_render_tool() { return 0; }
    _sys_diag_npm_global_count() { return 3; }
    _sys_diag_pipx_count() { return 3; }
    sys-info <<< "finite-input" >"$HOME/cold.out" 2>"$HOME/cold.err"
    local rc=$?
    print -r -- "$rc" > "$HOME/cold.primary.status"
    printf "%s\t%s\t%s\t%s\n" "$_SYS_CAPABILITIES_READY" \
      "${_SYS_CAPABILITIES[os]}" "${_SYS_CAPABILITIES[architecture]}" \
      "${_SYS_CAPABILITIES[process_backend]}" > "$HOME/cold.capabilities.tsv"
    return 0
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/cold.primary.status")" -eq 0 ]
  [ "$(cat "$HOME/cold.capabilities.tsv")" = $'1\tlinux\tx86_64\tprocps' ]
  [ ! -s "$HOME/cold.out" ]
  [ -s "$HOME/cold.err" ]
  [ -s "$HOME/cold.detector" ]
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  assert_sys_probe uname -s
  assert_sys_probe uname -m
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: bootstrap PS selects the native program and keeps both bounded queries" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    _sys_wsl_detect() { return 1; }
    env() { print -r -- env-shadow >> "$SYS_PROBE_FUNCTION_CALLS"; return 97; }
    ps() { print -r -- ps-shadow >> "$SYS_PROBE_FUNCTION_CALLS"; return 97; }
    env true || :
    ps >/dev/null || :
    local -i controls=$(command wc -l < "$SYS_PROBE_FUNCTION_CALLS")
    (( controls == 2 )) || exit 91
    : > "$SYS_PROBE_FUNCTION_CALLS"
    print -r -- "$$" > "$HOME/ps.pid"
    _sys_linux_process_backend <<< "finite-input" > "$HOME/ps.out" 2> "$HOME/ps.err"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/ps.out")" = procps ]
  [ ! -s "$HOME/ps.err" ]
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  assert_sys_probe ps -eo pid=,uid=,pcpu=,pmem=,comm= --sort=-pcpu
  assert_sys_probe ps -p "$(cat "$HOME/ps.pid")" -o uid= -o lstart= -o comm=
  [ "$(wc -l < "$SYS_PROBE_CALLS")" -eq 2 ]
  [ ! -s "$SYS_PROBE_DENIED" ]
}


@test "sys probe CLI: native identity: unavailable and unsafe programs are refused before shadow functions" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    git() { print -r -- shadow >> "$SYS_PROBE_FUNCTION_CALLS"; print -r -- "git version 99"; }
    git --version >/dev/null
    [[ "$(<"$SYS_PROBE_FUNCTION_CALLS")" == shadow ]] || exit 91
    : > "$SYS_PROBE_FUNCTION_CALLS"
    local rc=0
    _sys_tool_program git || rc=$?
    printf "%s\t%s\n" "$rc" "$REPLY" > "$HOME/healthy.selection"
    chmod -- 702 "$SYS_PROBE_BIN/git" || exit 92
    rc=0
    _sys_tool_program git || rc=$?
    print -r -- "$rc" > "$HOME/unsafe.resolver.status"
    _sys_diag_render_tool Git git > "$HOME/unsafe.out" 2> "$HOME/unsafe.err"
    print -r -- "$?" > "$HOME/unsafe.primary.status"
    chmod -- 700 "$SYS_PROBE_BIN/git" || exit 93
    mv "$SYS_PROBE_BIN/git" "$SYS_PROBE_BIN/git.saved" || exit 94
    path=("$SYS_PROBE_BIN" "$HOME/support bin")
    rc=0
    _sys_tool_program git || rc=$?
    print -r -- "$rc" > "$HOME/missing.resolver.status"
    _sys_diag_render_tool Git git > "$HOME/missing.out" 2> "$HOME/missing.err"
    print -r -- "$?" > "$HOME/missing.primary.status"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/healthy.selection")" = $'0\t'"$SYS_PROBE_BIN/git" ]
  [ "$(cat "$HOME/unsafe.resolver.status")" -eq 3 ]
  [ "$(cat "$HOME/missing.resolver.status")" -eq 1 ]
  local label
  for label in unsafe missing; do
    [ "$(cat "$HOME/$label.primary.status")" -eq 0 ]
    [ ! -s "$HOME/$label.out" ]
    [ ! -s "$HOME/$label.err" ]
  done
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  [ ! -s "$SYS_PROBE_CALLS" ]
}

@test "sys probe CLI: native identity: a PATH change at execution cannot replace the vetted version program" {
  mkdir "$HOME/replacement"
  printf '#!%s\n' "$BASH" > "$HOME/replacement/git"
  cat >> "$HOME/replacement/git" <<'MOCK'
printf 'replacement\n' >> "$HOME/replacement.log"
printf 'git version 99.0.0\n'
MOCK
  chmod -- 700 "$HOME/replacement/git"
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    _sys_tool_program git || exit 91
    print -r -- "$REPLY" > "$HOME/frozen.selection"
    _sys_run_with_timeout() {
      local -x SYS_PROBE_BOUND_SECONDS="$1"
      shift
      path=("$HOME/replacement" $path)
      "$@"
    }
    _sys_diag_render_tool Git git <<< "finite-input" > "$HOME/path.out" 2> "$HOME/path.err"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/frozen.selection")" = "$SYS_PROBE_BIN/git" ]
  [ ! -s "$HOME/path.out" ]
  grep -Fq 2.46.0 "$HOME/path.err"
  [ ! -e "$HOME/replacement.log" ]
  assert_sys_probe --seconds 3 git --version
}

@test "sys probe CLI: native identity: representative adapter readers use qualified native programs" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    local tool label rc
    for tool in ps sysctl date uname; do
      functions[$tool]='"'"'print -r -- shadow >> "$SYS_PROBE_FUNCTION_CALLS"; print -r -- "shadow version"'"'"'
      "$tool" >/dev/null || exit 91
    done
    local -i controls=$(command wc -l < "$SYS_PROBE_FUNCTION_CALLS")
    (( controls == 4 )) || exit 92
    : > "$SYS_PROBE_FUNCTION_CALLS"
    for label in linux-zombies mac-runtime wsl-release; do
      export SYS_PROBE_CALLS="$HOME/adapter-$label.calls.tsv"
      : > "$SYS_PROBE_CALLS"
      rc=0
      case "$label" in
        linux-zombies) _sys_linux_diag_zombie_records ;;
        mac-runtime) _sys_macos_diag_runtime_record ;;
        wsl-release) _sys_wsl_diag_release ;;
      esac > "$HOME/adapter-$label.out" 2> "$HOME/adapter-$label.err" || rc=$?
      print -r -- "$rc" > "$HOME/adapter-$label.primary.status"
    done
  '
  [ "$status" -eq 0 ]
  local label
  for label in linux-zombies mac-runtime wsl-release; do
    [ "$(cat "$HOME/adapter-$label.primary.status")" -eq 0 ]
    [ -s "$HOME/adapter-$label.out" ]
    [ ! -s "$HOME/adapter-$label.err" ]
  done
  [ "$(cat "$HOME/adapter-linux-zombies.out")" = $'42\tfixture' ]
  [ "$(cat "$HOME/adapter-mac-runtime.out")" = $'42\t0.1\t0.2\t0.3' ]
  [ "$(cat "$HOME/adapter-wsl-release.out")" = WSL1 ]
  export SYS_PROBE_CALLS="$HOME/adapter-linux-zombies.calls.tsv"
  assert_sys_probe --seconds 5 ps -eo pid=,stat=,comm=
  export SYS_PROBE_CALLS="$HOME/adapter-mac-runtime.calls.tsv"
  assert_sys_probe --seconds 3 sysctl -n kern.boottime
  assert_sys_probe --seconds 3 date +%s
  assert_sys_probe --seconds 3 sysctl -n vm.loadavg
  export SYS_PROBE_CALLS="$HOME/adapter-wsl-release.calls.tsv"
  assert_sys_probe --seconds 3 uname -r
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: diagnostic Homebrew queries freeze the secondary program and four environment controls" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    env() { print -r -- env-shadow >> "$SYS_PROBE_FUNCTION_CALLS"; return 97; }
    brew() { print -r -- brew-shadow >> "$SYS_PROBE_FUNCTION_CALLS"; return 97; }
    env true || :
    brew list --formula || :
    local -i controls=$(command wc -l < "$SYS_PROBE_FUNCTION_CALLS")
    (( controls == 2 )) || exit 91
    : > "$SYS_PROBE_FUNCTION_CALLS"
    _sys_linux_snapd_available() { return 1; }
    local platform rc
    for platform in linux mac; do
      export SYS_PROBE_CALLS="$HOME/brew-$platform.calls.tsv"
      : > "$SYS_PROBE_CALLS"
      rc=0
      if [[ "$platform" == linux ]]; then
        _sys_linux_diag_package_records brew
      else
        _sys_macos_diag_package_records brew
      fi > "$HOME/brew-$platform.out" 2> "$HOME/brew-$platform.err" || rc=$?
      print -r -- "$rc" > "$HOME/brew-$platform.primary.status"
    done
  '
  [ "$status" -eq 0 ]
  local platform record
  for platform in linux mac; do
    [ "$(cat "$HOME/brew-$platform.primary.status")" -eq 0 ]
    [ "$(cat "$HOME/brew-$platform.out")" = $'Brew formulae\t2\nBrew casks\t1' ]
    [ ! -s "$HOME/brew-$platform.err" ]
    export SYS_PROBE_CALLS="$HOME/brew-$platform.calls.tsv"
    assert_sys_probe --seconds 5 brew list --formula
    assert_sys_probe --seconds 5 brew list --cask
    [ "$(wc -l < "$SYS_PROBE_CALLS")" -eq 2 ]
    for record in 1 2; do
      awk -F '\t' 'NR == 1 && NF == 5 && $2 == 0 && $3 == 1 && $4 == 1 && $5 == 1 { valid=1 }
        END { exit !(valid && NR == 1) }' "$SYS_PROBE_CALLS.$record.environment.tsv"
    done
  done
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: CLT qualification freezes the native xcode-select secondary probe" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    _sys_has_capability() { [[ "$1" == os:darwin ]]; }
    _sys_macos_clt_stub_dir() { REPLY="$SYS_PROBE_BIN"; }
    xcode-select() { print -r -- shadow >> "$SYS_PROBE_FUNCTION_CALLS"; print -r -- /shadow; }
    xcode-select -p >/dev/null
    [[ "$(<"$SYS_PROBE_FUNCTION_CALLS")" == shadow ]] || exit 91
    : > "$SYS_PROBE_FUNCTION_CALLS"
    local stage rc
    for stage in missing installed; do
      export SYS_PROBE_CLT_ROOT="$HOME/developer $stage"
      [[ "$stage" != installed ]] || mkdir "$SYS_PROBE_CLT_ROOT" || exit 92
      export SYS_PROBE_CALLS="$HOME/clt-$stage.calls.tsv"
      : > "$SYS_PROBE_CALLS"
      rc=0
      _sys_tool_program git > "$HOME/clt-$stage.out" 2> "$HOME/clt-$stage.err" || rc=$?
      print -r -- "$rc" > "$HOME/clt-$stage.primary.status"
      print -r -- "$REPLY" > "$HOME/clt-$stage.reply"
    done
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/clt-missing.primary.status")" -eq 3 ]
  [ "$(cat "$HOME/clt-installed.primary.status")" -eq 0 ]
  [ "$(cat "$HOME/clt-installed.reply")" = "$SYS_PROBE_BIN/git" ]
  local stage
  for stage in missing installed; do
    [ ! -s "$HOME/clt-$stage.out" ]
    [ ! -s "$HOME/clt-$stage.err" ]
    export SYS_PROBE_CALLS="$HOME/clt-$stage.calls.tsv"
    assert_sys_probe --seconds 3 xcode-select -p
  done
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: softwareupdate preserves merged output and its existing long listing budget" {
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    softwareupdate() { print -r -- shadow >> "$SYS_PROBE_FUNCTION_CALLS"; print -r -- SHADOW; }
    softwareupdate --list >/dev/null
    [[ "$(<"$SYS_PROBE_FUNCTION_CALLS")" == shadow ]] || exit 91
    : > "$SYS_PROBE_FUNCTION_CALLS"
    _sys_macos_softwareupdate_records <<< "finite-input" > "$HOME/software.out" 2> "$HOME/software.err"
  '
  [ "$status" -eq 0 ]
  grep -Fq $'Fixture-1.0\t' "$HOME/software.out"
  [ ! -s "$HOME/software.err" ]
  assert_sys_probe --seconds 120 softwareupdate --list
  [ ! -s "$SYS_PROBE_FUNCTION_CALLS" ]
  [ ! -s "$SYS_PROBE_DENIED" ]
}

@test "sys probe CLI: native identity: bootstrap rejects unsafe Linux WSL candidates while Darwin ignores inherited WSL flags" {
  mkdir -p "$HOME/interop/c/bin"
  cp "$SYS_PROBE_BIN/uname" "$HOME/interop/c/bin/uname"
  chmod -- 700 "$HOME/interop/c/bin/uname"
  run run_zsh '
    source "$HOME/probe-context.zsh" || exit 90
    # These existing consumers use only the restricted bootstrap resolver.
    _SYS_CAPABILITIES=()
    _SYS_CAPABILITIES_READY=0
    _sys_wsl_drive_root() { REPLY="$HOME/interop"; }
    _sys_wsl_detect() { return 0; }
    local stage rc
    for stage in safe unsafe linux-wsl darwin-wsl; do
      path=("$SYS_PROBE_BIN" "$HOME/support bin")
      OSTYPE=linux-gnu
      case "$stage" in
        unsafe) chmod -- 702 "$SYS_PROBE_BIN/uname" || exit 91 ;;
        linux-wsl) path=("$HOME/interop/c/bin" "$HOME/support bin") ;;
        darwin-wsl) OSTYPE=darwin; path=("$HOME/interop/c/bin" "$HOME/support bin") ;;
      esac
      export WSL_DISTRO_NAME=fixture SYS_PROBE_CALLS="$HOME/bootstrap-$stage.calls.tsv"
      : > "$SYS_PROBE_CALLS"
      rc=0
      _sys_detect_os <<< "finite-input" > "$HOME/bootstrap-$stage.out" \
        2> "$HOME/bootstrap-$stage.err" || rc=$?
      printf "%s\t%s\n" "$rc" "$_SYS_CAPABILITIES_READY" > "$HOME/bootstrap-$stage.status"
      chmod -- 700 "$SYS_PROBE_BIN/uname" || exit 92
    done
  '
  [ "$status" -eq 0 ]
  local stage
  for stage in safe unsafe linux-wsl darwin-wsl; do
    [ "$(cat "$HOME/bootstrap-$stage.status")" = $'0\t0' ]
    [ ! -s "$HOME/bootstrap-$stage.err" ]
  done
  [ "$(cat "$HOME/bootstrap-safe.out")" = linux ]
  [ "$(cat "$HOME/bootstrap-unsafe.out")" = unknown ]
  [ "$(cat "$HOME/bootstrap-linux-wsl.out")" = unknown ]
  [ "$(cat "$HOME/bootstrap-darwin-wsl.out")" = linux ]
  [ ! -s "$HOME/bootstrap-unsafe.calls.tsv" ]
  [ ! -s "$HOME/bootstrap-linux-wsl.calls.tsv" ]
  export SYS_PROBE_CALLS="$HOME/bootstrap-safe.calls.tsv"
  assert_sys_probe --seconds 3 uname -s
  export SYS_PROBE_CALLS="$HOME/bootstrap-darwin-wsl.calls.tsv"
  export SYS_PROBE_BIN="$HOME/interop/c/bin"
  assert_sys_probe --seconds 3 uname -s
  [ ! -s "$SYS_PROBE_DENIED" ]
}
