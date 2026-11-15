#!/usr/bin/env bats
# Finite native platform facts; no host package, kernel-log or proc-file reads.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export F507_ROOT="$HOME/platform-facts" F507_CASE="" F507_OS=linux F507_ENV=native
  export F507_KERNEL=6.6-fixture F507_KERNEL_RC=0 F507_MODE=known
  export F507_CORE_FIRST=8 F507_CORE_FIRST_RC=0 F507_CORE_SECOND=4 F507_CORE_SECOND_RC=0
  export F507_PROC_CORES=8 F507_PROC_RC=0
  export F507_REAL_AWK F507_REAL_ZSH
  F507_REAL_AWK=$(type -P awk)
  F507_REAL_ZSH=$(type -P zsh)
  mkdir -p "$F507_ROOT/backends"
  cat > "$F507_ROOT/context.zsh" <<'ZSH'
emulate -R zsh
builtin cd -q -- "$TEST_TEMP_DIR" || return 90
source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 91
_SYS_CAPABILITIES=(os "$F507_OS" environment "$F507_ENV" architecture x86_64
  package_manager unavailable os_updates_backend unavailable service_manager unavailable
  process_backend unavailable ports_backend unavailable privilege unavailable
  snapd unavailable wsl_interop unavailable)
_SYS_CAPABILITIES_READY=1
_sys_capabilities_refresh() { return 97; }
_sys_linux_snapd_available() { return 1; }
# Finite callback model: ordinary function lookup remains; the owner must
# supply a vetted absolute program and close stdin itself. No signal runs.
_sys_run_with_timeout() {
  local -x F507_BOUND_SECONDS="$1"
  shift
  [[ "$F507_BOUND_SECONDS" == <-> ]] || return 96
  (( F507_BOUND_SECONDS > 0 && F507_BOUND_SECONDS <= 10 )) || return 96
  "$@"
}
ZSH
  f507_mock uname <<'MOCK'
[[ "$*" == -r ]] || exit 97
printf '%s\n' "$F507_KERNEL"
exit "$F507_KERNEL_RC"
MOCK
  f507_mock sysctl <<'MOCK'
case "$*" in
  '-n hw.memsize')
    [[ "$F507_MODE" != required-failed ]] || exit 17
    printf '16777216\n' ;;
  '-n kern.memorystatus_level') printf '50\n' ;;
  '-n vm.swapusage')
    case "$F507_MODE" in
      zero) printf 'total = 0.00M used = 0.00M free = 0.00M\n' ;;
      failed) printf 'total = 8.00M used = 4.00M free = 4.00M\n'; exit 17 ;;
      timeout) printf 'total = 8.00M used = 4.00M free = 4.00M\n'; exit 124 ;;
      malformed) printf 'not a swap record\n' ;;
      incomplete) printf 'total = 8.00M\n' ;;
      range) printf 'total = 8.00M used = 0.00M free = 16.00M\n' ;;
      *) printf 'total = 8.00M used = 4.00M free = 4.00M\n' ;;
    esac ;;
  '-n hw.logicalcpu')
    case "$F507_MODE" in
      failed) printf '8\n'; exit 17 ;;
      timeout) printf '8\n'; exit 124 ;;
      malformed|incomplete|range) printf 'not-a-core-count\n' ;;
      zero-core) printf '0\n' ;;
      *) printf '8\n' ;;
    esac ;;
  '-n machdep.cpu.brand_string'|'-n hw.model') printf 'Fixture CPU\n' ;;
  *) exit 97 ;;
esac
MOCK
  f507_mock vm_stat <<'MOCK'
exit 97
MOCK
  f507_mock getconf <<'MOCK'
[[ "$*" == _NPROCESSORS_ONLN ]] || exit 97
printf '%s\n' "$F507_CORE_FIRST"
exit "$F507_CORE_FIRST_RC"
MOCK
  f507_mock nproc <<'MOCK'
[[ $# -eq 0 ]] || exit 97
printf '%s\n' "$F507_CORE_SECOND"
exit "$F507_CORE_SECOND_RC"
MOCK
  f507_mock dmesg <<'MOCK'
[[ $# -eq 0 ]] || exit 97
cat "$F507_CASE/dmesg.fixture" || exit 98
exit "$F507_DMESG_RC"
MOCK
  f507_mock dpkg-query <<'MOCK'
[[ $# -eq 2 && "$1" == -W ]] || exit 97
case "$2" in
  '-f=${binary:Package}\n') mode=name ;;
  '-f=${db:Status-Status}\n') mode=status ;;
  *) exit 97 ;;
esac
if [[ "$F507_DPKG_MODE" == overflow ]]; then
  cat "$F507_CASE/overflow.fixture" || exit 98
  exit 0
fi
while IFS='|' read -r name want flag state; do
  [[ -n "$name" ]] || continue
  if [[ "$mode" == name ]]; then printf '%s\n' "$name"
  else printf '%s\n' "$state"; fi
done < "$F507_CASE/packages.fixture"
exit "$F507_DPKG_RC"
MOCK
  # Only the exact proc boundary is intercepted; ordinary awk assertions and
  # data parsing use the frozen harness executable, never host CPU contents.
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/awk"
  cat >> "$TEST_MOCK_BIN/awk" <<'MOCK'
for word in "$@"; do
  if [[ "$word" == /proc/cpuinfo ]]; then
    printf '%s\0' "$@" >> "$F507_CASE/proc.argv.nul"
    if [[ "$*" == *'count + 0'* ]]; then
      printf '%s\n' "$F507_PROC_CORES"
      exit "$F507_PROC_RC"
    fi
    printf 'Fixture CPU\n'
    exit 0
  fi
done
exec "$F507_REAL_AWK" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/awk"
}

teardown() {
  cleanup_sandbox
}

# One selected native launcher, one finite child, actual returned primary and
# raw argv/EOF/budget observations. A configured status is never reach proof.
f507_mock() {
  local tool="$1"
  printf '#!%s\n' "$BASH" > "$F507_ROOT/backends/$tool" || return 1
  cat >> "$F507_ROOT/backends/$tool" || return 2
  chmod -- 700 "$F507_ROOT/backends/$tool" || return 3
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/$tool" || return 4
  cat >> "$TEST_MOCK_BIN/$tool" <<'MOCK'
tool=${0##*/}
sequence=1
while IFS= read -r previous; do sequence=$((sequence+1)); done < "$F507_CASE/calls.tsv"
printf '%s\0' "$0" "$@" > "$F507_CASE/call-$sequence.argv.nul" || exit 90
stdin_state=eof
if IFS= read -r input_line; then stdin_state=input; fi
printf '%s\t%s\t%s\t%s\n' "$tool" "$0" "${F507_BOUND_SECONDS:-none}" "$stdin_state" >> "$F507_CASE/calls.tsv" || exit 91
rc=0
"$F507_ROOT/backends/$tool" "$@" || rc=$?
printf '%s\n' "$rc" > "$F507_CASE/call-$sequence.primary.status" || exit 92
exit "$rc"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/$tool" || return 5
}

f507_case() {
  export F507_CASE="$F507_ROOT/$1"
  mkdir "$F507_CASE" || return 1
  : > "$F507_CASE/calls.tsv" || return 2
}

f507_observe() {
  local body="$1" wrapper=0
  run_zsh '
    source "$F507_ROOT/context.zsh" || return 90
    _f507_action() {
  '"$body"'
    }
    local -i rc=0
    _f507_action > "$F507_CASE/stdout" 2> "$F507_CASE/stderr" || rc=$?
    print -r -- "$rc" > "$F507_CASE/primary.status" || return 91
  ' > "$F507_CASE/wrapper.stdout" 2> "$F507_CASE/wrapper.stderr" || wrapper=$?
  printf '%s\n' "$wrapper" > "$F507_CASE/wrapper.status" || return 1
  [[ "$wrapper" -eq 0 ]] || return 2
}

f507_primary() {
  local primary
  [[ -f "$F507_CASE/primary.status" && -f "$F507_CASE/stdout" && -f "$F507_CASE/stderr" ]] || return 1
  primary=$(cat "$F507_CASE/primary.status") || return 2
  [[ "$primary" =~ ^[0-9]+$ && "$primary" -eq "$1" ]] || return 3
  [[ ! -s "$F507_CASE/stderr" ]] || return 4
}

f507_producer() {
  local row="$1" tool="$2" seconds="$3" expected_status="$4" actual
  shift 4
  printf '%s\0' "$TEST_MOCK_BIN/$tool" "$@" > "$F507_CASE/expected.argv.nul" || return 1
  [[ -f "$F507_CASE/call-$row.argv.nul" && -f "$F507_CASE/call-$row.primary.status" ]] || return 2
  cmp "$F507_CASE/expected.argv.nul" "$F507_CASE/call-$row.argv.nul" || return 3
  awk -F '\t' -v row="$row" -v tool="$tool" -v selected="$TEST_MOCK_BIN/$tool" -v seconds="$seconds" '
    NR == row { found++; if (NF != 4 || $1 != tool || $2 != selected || $3 != seconds || $4 != "eof") bad++ }
    END { exit !(found == 1 && bad == 0) }
  ' "$F507_CASE/calls.tsv" || return 4
  actual=$(cat "$F507_CASE/call-$row.primary.status") || return 5
  [[ "$actual" =~ ^[0-9]+$ && "$actual" -eq "$expected_status" ]] || return 6
}

@test "sys platform facts: recorder distinguishes open unbounded input from selected bounded closed input" {
  f507_case recorder
  export F507_KERNEL_RC=0
  run run_zsh '
    source "$F507_ROOT/context.zsh" || exit 90
    unset F507_BOUND_SECONDS
    "$TEST_MOCK_BIN/uname" -r <<< "finite-input" > "$F507_CASE/open.stdout"
    _sys_wsl_diag_release > "$F507_CASE/closed.stdout"
  '
  [ "$status" -eq 0 ]
  run f507_producer 1 uname 3 0 -r
  [ "$status" -ne 0 ]
  f507_producer 2 uname 3 0 -r
  [ "$(wc -l < "$F507_CASE/calls.tsv")" -eq 2 ]
}

@test "sys platform facts: WSL generation follows successful case-sensitive Microsoft suffix and custom kernels" {
  export F507_ENV=wsl
  local row name kernel expected rc failures=0
  for row in 'legacy|4.4.0-19041-Microsoft|WSL1' 'standard|5.15.0-microsoft-standard-WSL2|WSL2' 'custom|6.6.36-custom|WSL2' 'lowercase|6.6.0-microsoft|WSL2' 'spaced|6.6 custom|WSL2'; do
    IFS='|' read -r name kernel expected <<< "$row"
    f507_case "generation-$name"
    export F507_KERNEL="$kernel"
    f507_observe '_sys_wsl_diag_release'
    f507_primary 0
    f507_producer 1 uname 3 0 -r
    printf '%s\n' "$expected" > "$F507_CASE/expected"
    if cmp "$F507_CASE/expected" "$F507_CASE/stdout"; then rc=0
    else rc=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$name" "$rc" >> "$F507_ROOT/generation.matrix.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/generation.matrix.tsv")" -eq 5 ]
  [ "$failures" -eq 0 ]
}

@test "sys platform facts: failed or empty kernel observations do not publish a known WSL generation" {
  local mode code expected failures=0 rc
  for mode in failed timeout empty blank control multiline; do
    f507_case "kernel-failure-$mode"
    code=0; expected=1
    export F507_KERNEL=6.6.36-custom
    case "$mode" in
      failed) code=17; expected=17 ;;
      timeout) code=124; expected=124 ;;
      empty) export F507_KERNEL="" ;;
      blank) export F507_KERNEL="   " ;;
      control) export F507_KERNEL=$'6.6\tcustom' ;;
      multiline) export F507_KERNEL=$'6.6\ncustom' ;;
    esac
    export F507_KERNEL_RC="$code"
    f507_observe '_sys_wsl_diag_release'
    f507_producer 1 uname 3 "$code" -r
    if f507_primary "$expected" && [[ ! -s "$F507_CASE/stdout" ]]; then rc=0
    else rc=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$rc" >> "$F507_ROOT/kernel-failure.matrix.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/kernel-failure.matrix.tsv")" -eq 6 ]
  [ "$failures" -eq 0 ]
}

f507_darwin_row() {
  local mode="$1" primary memory_status cpu_status swap_kind core_kind
  f507_case "darwin-$mode" || return 1
  export F507_OS=darwin F507_MODE="$mode"
  f507_observe '
    local -i rc=0
    _sys_macos_diag_memory_record > "$F507_CASE/memory.stdout" 2> "$F507_CASE/memory.stderr" || rc=$?
    print -r -- "$rc" > "$F507_CASE/memory.primary.status" || return 90
    rc=0
    _sys_macos_diag_cpu_record > "$F507_CASE/cpu.stdout" 2> "$F507_CASE/cpu.stderr" || rc=$?
    print -r -- "$rc" > "$F507_CASE/cpu.primary.status" || return 91
  ' || return 2
  f507_primary 0 || return 3
  memory_status=$(cat "$F507_CASE/memory.primary.status") || return 4
  cpu_status=$(cat "$F507_CASE/cpu.primary.status") || return 5
  [[ "$memory_status" == 0 && "$cpu_status" == 0 ]] || return 6
  [[ -f "$F507_CASE/memory.stderr" && ! -s "$F507_CASE/memory.stderr" \
    && -f "$F507_CASE/cpu.stderr" && ! -s "$F507_CASE/cpu.stderr" ]] || return 7
  primary=0
  [[ "$mode" != failed ]] || primary=17
  [[ "$mode" != timeout ]] || primary=124
  f507_producer 1 sysctl 3 0 -n hw.memsize || return 8
  f507_producer 2 sysctl 3 0 -n kern.memorystatus_level || return 9
  f507_producer 3 sysctl 3 "$primary" -n vm.swapusage || return 10
  f507_producer 4 sysctl 3 "$primary" -n hw.logicalcpu || return 11
  f507_producer 5 sysctl 3 0 -n machdep.cpu.brand_string || return 12
  swap_kind=known; core_kind=known
  case "$mode" in
    zero) swap_kind=zero ;;
    failed|timeout|malformed|incomplete|range) swap_kind=unknown; core_kind=unknown ;;
    zero-core) core_kind=unknown ;;
  esac
  awk -F '\t' -v kind="$swap_kind" '
    NR == 1 {
      if (NF != 4 || $1 != "16777216" || $2 != "8388608") exit 1
      if (kind == "zero") valid=($3 == "0" && $4 == "0")
      else if (kind == "known") valid=($3 == "8388608" && $4 == "4194304")
      else valid=($3 != "" && $4 != "" && $3 !~ /^[0-9]+$/ && $4 !~ /^[0-9]+$/)
    }
    END { exit !(NR == 1 && valid) }
  ' "$F507_CASE/memory.stdout" || return 13
  awk -F '\t' -v kind="$core_kind" '
    NR == 1 && NF == 2 && $2 == "Fixture CPU" {
      if (kind == "known") valid=($1 == "8")
      else valid=($1 != "" && $1 !~ /^[0-9]+$/)
    }
    END { exit !(NR == 1 && valid) }
  ' "$F507_CASE/cpu.stdout" || return 14
  return 0
}

@test "sys platform facts: Darwin preserves independent memory and model facts across optional unknown numerics" {
  local mode rc failures=0
  for mode in zero known failed timeout malformed incomplete range zero-core; do
    if f507_darwin_row "$mode"; then rc=0
    else rc=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$rc" >> "$F507_ROOT/darwin.matrix.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/darwin.matrix.tsv")" -eq 8 ]
  [ "$failures" -eq 0 ]
}

@test "sys platform facts: failed mandatory Darwin memory observation remains failed without a record" {
  f507_case darwin-required-failed
  export F507_OS=darwin F507_MODE=required-failed
  f507_observe '_sys_macos_diag_memory_record'
  f507_primary 1
  [ ! -s "$F507_CASE/stdout" ]
  f507_producer 1 sysctl 3 17 -n hw.memsize
  [ "$(wc -l < "$F507_CASE/calls.tsv")" -eq 1 ]
}

f507_linux_core_row() {
  local mode="$1" expected first_status=0 second_status=0
  f507_case "linux-core-$mode" || return 1
  export F507_OS=linux F507_ENV=native F507_CORE_FIRST=8 F507_CORE_SECOND=4
  export F507_CORE_FIRST_RC=0 F507_CORE_SECOND_RC=0 F507_PROC_CORES=0 F507_PROC_RC=17
  expected=8
  case "$mode" in
    failed-first) export F507_CORE_FIRST_RC=17; first_status=17; expected=4 ;;
    unknown) export F507_CORE_FIRST_RC=17 F507_CORE_SECOND_RC=17; first_status=17; second_status=17; expected=unknown ;;
    nonpositive) export F507_CORE_FIRST=0 F507_CORE_SECOND=0 F507_PROC_RC=0; expected=unknown ;;
  esac
  f507_observe '_sys_linux_diag_cpu_record' || return 2
  f507_primary 0 || return 3
  f507_producer 1 getconf 3 "$first_status" _NPROCESSORS_ONLN || return 4
  awk -F '\t' -v expected="$expected" '
    NR == 1 && NF == 2 && $2 != "" {
      if (expected == "unknown") valid=($1 != "" && $1 !~ /^[0-9]+$/)
      else valid=($1 == expected)
    }
    END { exit !(NR == 1 && valid) }
  ' "$F507_CASE/stdout" || return 5
  if [[ "$mode" != known ]]; then
    f507_producer 2 nproc 3 "$second_status" || return 6
  fi
  # Host /proc availability controls only whether the finite interception is
  # reached. It never authorizes reading the host's actual CPU contents.
  if [[ -s "$F507_CASE/proc.argv.nul" ]]; then
    grep -Fq 'Fixture CPU' "$F507_CASE/stdout" || return 7
  fi
  return 0
}

@test "sys platform facts: Linux core fallback discards failed producers and never invents zero cores" {
  local mode rc failures=0
  for mode in known failed-first unknown nonpositive; do
    if f507_linux_core_row "$mode"; then rc=0
    else rc=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$rc" >> "$F507_ROOT/linux-core.matrix.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/linux-core.matrix.tsv")" -eq 4 ]
  [ "$failures" -eq 0 ]
}

f507_oom_row() {
  local mode="$1" expected=0 code=0
  f507_case "oom-$mode" || return 1
  export F507_DMESG_RC=0
  case "$mode" in
    unrelated) printf 'usb: fixture device connected\n' > "$F507_CASE/dmesg.fixture" ;;
    headers) printf 'worker invoked oom-killer: order=0\noom-kill:constraint=MEMCG\n' > "$F507_CASE/dmesg.fixture" ;;
    one) printf 'worker invoked oom-killer: order=0\nCPU: 2 PID: 12\nOut of memory: Killed process 12 (worker) total-vm:100kB\n' > "$F507_CASE/dmesg.fixture"; expected=1 ;;
    memcg) printf 'Memory cgroup out of memory: Killed process 12 (worker) total-vm:100kB\n' > "$F507_CASE/dmesg.fixture"; expected=1 ;;
    two) printf 'worker invoked oom-killer: order=0\nOut of memory: Killed process 12 (worker) total-vm:100kB\nMemory cgroup out of memory: Killed process 13 (other) total-vm:100kB\n' > "$F507_CASE/dmesg.fixture"; expected=2 ;;
    failed) printf 'Out of memory: Killed process 12 (worker) total-vm:100kB\n' > "$F507_CASE/dmesg.fixture"; export F507_DMESG_RC=17; code=17 ;;
  esac
  f507_observe '_sys_linux_diag_oom_event_count' || return 2
  f507_primary "$code" || return 3
  f507_producer 1 dmesg 5 "$code" || return 4
  if [[ "$code" -eq 0 ]]; then
    printf '%s\n' "$expected" > "$F507_CASE/expected" || return 5
    cmp "$F507_CASE/expected" "$F507_CASE/stdout" || return 6
  fi
  return 0
}

@test "sys platform facts: OOM counts completed killed-task records and retains actual producer failures" {
  local mode rc failures=0
  for mode in unrelated headers one memcg two failed; do
    if f507_oom_row "$mode"; then rc=0
    else rc=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$rc" >> "$F507_ROOT/oom.matrix.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/oom.matrix.tsv")" -eq 6 ]
  [ "$failures" -eq 0 ]
}

f507_dpkg_row() {
  local mode="$1" code=0 count=0 format item
  local -a argv=()
  f507_case "apt-$mode" || return 1
  export F507_DPKG_MODE="$mode" F507_DPKG_RC=0
  case "$mode" in
    empty) : > "$F507_CASE/packages.fixture" ;;
    mixed) printf 'one|install|ok|installed\ntwo|install|ok|installed\nold|deinstall|ok|config-files\n' > "$F507_CASE/packages.fixture"; count=2 ;;
    selected) printf 'held|hold|ok|installed\nremoved|deinstall|ok|installed\npurged|purge|ok|installed\nflagged|install|reinstreq|installed\nold|deinstall|ok|config-files\n' > "$F507_CASE/packages.fixture"; count=4 ;;
    other-states) printf 'n|unknown|ok|not-installed\nc|deinstall|ok|config-files\nh|install|reinstreq|half-installed\nu|install|ok|unpacked\nf|install|ok|half-configured\nw|install|ok|triggers-awaited\nt|install|ok|triggers-pending\ni|install|ok|installed\n' > "$F507_CASE/packages.fixture"; count=1 ;;
    malformed) printf 'one|install|ok|not-a-state\n' > "$F507_CASE/packages.fixture"; code=1 ;;
    failed|timeout) printf 'one|install|ok|installed\n' > "$F507_CASE/packages.fixture"; code=1; export F507_DPKG_RC=17; [[ "$mode" != timeout ]] || export F507_DPKG_RC=124 ;;
    overflow) make_sized_file "$F507_CASE/overflow.fixture" 1048577 || return 2; code=1 ;;
  esac
  f507_observe '_sys_linux_diag_package_records apt' || return 3
  # Qualify the actual old or adopted field query before the count witness.
  # Both finite formats are real supported producer branches, not deny stubs.
  [[ -f "$F507_CASE/call-1.argv.nul" ]] || return 4
  while IFS= read -r -d '' item; do argv+=("$item"); done < "$F507_CASE/call-1.argv.nul"
  [[ ${#argv[@]} -eq 3 && "${argv[1]}" == -W ]] || return 5
  format="${argv[2]}"
  [[ "$format" == '-f=${binary:Package}\n' || "$format" == '-f=${db:Status-Status}\n' ]] || return 6
  f507_producer 1 dpkg-query 5 "$F507_DPKG_RC" -W "$format" || return 7
  printf '%s\n' "$format" > "$F507_CASE/observed-format" || return 8
  f507_primary "$code" || return 9
  if [[ "$code" -eq 0 ]]; then
    printf 'APT packages\t%s\n' "$count" > "$F507_CASE/expected" || return 10
    cmp "$F507_CASE/expected" "$F507_CASE/stdout" || return 11
  else
    [[ ! -s "$F507_CASE/stdout" ]] || return 12
  fi
  return 0
}

@test "sys platform facts: APT counts current installed state independently from selection and error flags" {
  local mode rc failures=0
  for mode in empty mixed selected other-states malformed failed timeout overflow; do
    if f507_dpkg_row "$mode"; then rc=0
    else rc=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$rc" >> "$F507_ROOT/apt.matrix.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/apt.matrix.tsv")" -eq 8 ]
  [ "$failures" -eq 0 ]
}
