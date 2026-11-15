#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export F507_ROOT="$HOME/f507" F507_CASE="" F507_OS=linux F507_ENV=native
  export F507_MEMORY=fixed F507_CPU=fixed F507_COUNTS=0 F507_DF_REAL=0 F507_OOM_REAL=0
  export NO_COLOR=1
  unset F507_LIST_RETURN F507_PACKAGE_COUNT F507_DF_RETURN F507_OPTIONAL F507_EMPTY_MARKER
  export F507_KERNEL=6.6.0-fixture F507_UNAME_RETURN=0
  mkdir -p "$F507_ROOT" || return 1
  : > "$F507_ROOT/denied" || return 2
  cat > "$HOME/f507-facts.zsh" <<'ZSH'
emulate -R zsh
# Same deterministic fact-boundary style as test/sys_diagnostics.bats.
_sys_capabilities_refresh() {
  _SYS_CAPABILITIES=(os "$F507_OS" environment "$F507_ENV" architecture x86_64
    package_manager unavailable os_updates_backend unavailable
    service_manager unavailable process_backend unavailable ports_backend unavailable
    privilege unavailable snapd unavailable wsl_interop unavailable)
  _SYS_CAPABILITIES_READY=1
}
_sys_diag_os_name() { print -r -- 'Fixture OS'; }
_sys_diag_memory_record() {
  [[ "$F507_MEMORY" != darwin ]] || { _sys_macos_diag_memory_record; return $?; }
  printf '16777216\t8388608\t0\t0\n'
}
_sys_diag_cpu_record() {
  case "$F507_CPU" in
    darwin) _sys_macos_diag_cpu_record ;;
    linux) _sys_linux_diag_cpu_record ;;
    *) printf '8\tFixture CPU\n' ;;
  esac
}
_sys_diag_runtime_record() { printf '1000\t0.1\t0.2\t0.3\n'; }
functions[_f507_inode_percent]="${functions[_sys_diag_inode_percent]}"
functions[_f507_disk_record]="${functions[_sys_diag_disk_record]}"
_sys_diag_disk_record() {
  [[ "$F507_DF_REAL" != 1 ]] || { _f507_disk_record "$@"; return $?; }
  printf '/dev/fixture\t1000\t400\t600\t40\n'
}
_sys_diag_inode_percent() {
  [[ "$F507_DF_REAL" != 1 ]] || { _f507_inode_percent "$@"; return $?; }
  print -r -- 10
}
_sys_diag_root_volume() { print -r -- /; }
_sys_diag_package_records() { return 3; }
_sys_diag_zombie_records() { return 3; }
_sys_diag_failed_service_records() { return 3; }
_sys_diag_signaled_service_records() { return 3; }
_sys_diag_oom_event_count() {
  [[ "$F507_OOM_REAL" != 1 ]] || { _sys_linux_diag_oom_event_count; return $?; }
  print -r -- 0
}
_sys_diag_pending_reboot() { return 1; }
_sys_wsl_diag_windows_version() { return 3; }
_sys_diag_tool_version() { return 3; }
functions[_f507_tool_available]="${functions[_sys_tool_available]}"
_sys_tool_available() {
  case "$1" in
    jq) command -v jq >/dev/null ;;
    npm|pipx) [[ "$F507_COUNTS" == 1 ]] && _f507_tool_available "$1" ;;
    *) return 1 ;;
  esac
}
unset ZSH
ZSH
  f507_mock uname <<'MOCK' || return 3
[[ $# == 1 && "$1" == -r ]] || { printf 'uname %s\n' "$*" >> "$F507_ROOT/denied"; exit 97; }
printf '%s\n' "$F507_KERNEL"
exit "$F507_UNAME_RETURN"
MOCK
}

teardown() { cleanup_sandbox; }

# Only a small executable writer; the sandbox/interpreter/metadata services
# remain the existing harness. Every body below is a finite fixed fixture.
f507_mock() {
  local tool="$1" destination="$TEST_MOCK_BIN/$1" producer="$F507_ROOT/$1-producer"
  printf '#!%s\n' "$BASH" > "$producer" || return 1
  cat >> "$producer" || return 2
  chmod -- 700 "$producer" || return 3
  printf '#!%s\n' "$BASH" > "$destination" || return 4
  cat >> "$destination" <<'WRAPPER' || return 5
[[ -n "$F507_CASE" && -d "$F507_CASE" ]] || { printf 'unreached case for %s\n' "$0" >> "$F507_ROOT/denied"; exit 97; }
tool=${0##*/}
receipt=$(mktemp -d "$F507_CASE/receipt-$tool.XXXXXX") || exit 90
printf '%s\n' "$0" > "$receipt/selected.program" || exit 91
printf '%s\0' "$@" > "$receipt/argv.nul" || exit 92
if IFS= read -r supplied_input; then
  printf '%s\n' "$supplied_input" > "$receipt/stdin.read" || exit 93
else
  printf '%s\n' closed > "$receipt/stdin.closed" || exit 94
fi
actual=0
"$F507_ROOT/$tool-producer" "$@" > "$receipt/producer.stdout" 2> "$receipt/producer.stderr" || actual=$?
printf '%s\n' "$actual" > "$receipt/producer.actual" || exit 95
cat "$receipt/producer.stdout" || exit 96
cat "$receipt/producer.stderr" >&2 || exit 96
exit "$actual"
WRAPPER
  chmod -- 700 "$destination" || return 6
}

f507_observe() {
  local name="$1" body="$2" wrapper=0
  export F507_CASE="$F507_ROOT/$name"
  mkdir "$F507_CASE" || return 1
  run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 90
    _SYS_CAPABILITIES=(os "$F507_OS" environment "$F507_ENV" architecture x86_64
      package_manager unavailable os_updates_backend unavailable service_manager unavailable
      process_backend unavailable ports_backend unavailable privilege unavailable
      snapd unavailable wsl_interop unavailable)
    _SYS_CAPABILITIES_READY=1
    _sys_capabilities_refresh() { _SYS_CAPABILITIES_READY=1; return 0; }
    functions[_f507_native_probe]="${functions[_sys_run_native_probe]}"
    _sys_run_native_probe() {
      local -i observed=0
      _f507_native_probe "$@" || observed=$?
      printf "%s\t%s\t%s\t%s\n" "$observed" "$1" "$2" "$3" >> "$F507_CASE/native-probes.tsv" || return 95
      return "$observed"
    }
    _f507_action() {
  '"$body"'
    }
    local -i primary=0
    _f507_action > "$F507_CASE/stdout" 2> "$F507_CASE/stderr" || primary=$?
    print -r -- "$primary" > "$F507_CASE/primary.status" || return 91
    return 0
  ' > "$F507_CASE/wrapper.stdout" 2> "$F507_CASE/wrapper.stderr" || wrapper=$?
  printf '%s\n' "$wrapper" > "$F507_CASE/wrapper.status" || return 2
  [[ "$wrapper" -eq 0 ]] || return 3
}

f507_primary() {
  local actual
  actual=$(cat "$F507_CASE/primary.status") || return 1
  [[ "$actual" =~ ^[0-9]+$ ]] || return 2
  [[ "$actual" -eq "$1" ]] || return 3
  [[ -f "$F507_CASE/stdout" && -f "$F507_CASE/stderr" ]] || return 4
  [[ -f "$F507_ROOT/denied" && ! -s "$F507_ROOT/denied" ]] || return 5
}

# Actual public primaries and streams are independent from the observer's.
f507_info_pair_program() {
  cat <<'ZSH'
source "$HOME/f507-facts.zsh" || return 92
local -i rc=0
sys-info > "$F507_CASE/text.stdout" 2> "$F507_CASE/text.stderr" || rc=$?
print -r -- "$rc" > "$F507_CASE/text.primary.status" || return 93
rc=0
sys-info --json > "$F507_CASE/json.stdout" 2> "$F507_CASE/json.stderr" || rc=$?
print -r -- "$rc" > "$F507_CASE/json.primary.status" || return 94
return 0
ZSH
}

f507_info_pair_assert() {
  local mode primary lines
  f507_primary 0 || return 1
  for mode in text json; do
    primary=$(cat "$F507_CASE/$mode.primary.status") || return 2
    [[ "$primary" =~ ^[0-9]+$ ]] || return 10
    [[ "$primary" -eq 0 ]] || return 3
    [[ -f "$F507_CASE/$mode.stdout" && -f "$F507_CASE/$mode.stderr" ]] || return 4
  done
  [[ ! -s "$F507_CASE/text.stdout" ]] || return 5
  [[ -s "$F507_CASE/json.stdout" ]] || return 6
  lines=$(wc -l < "$F507_CASE/json.stdout") || return 8
  [[ "$lines" -eq 1 ]] || return 9
  jq -se 'length == 1 and (.[0] | type == "object" and .schema == "zdx.sys-info.v1")' "$F507_CASE/json.stdout" >/dev/null || return 7
}


# Qualify the whole selected executable, actual child result and literal argv;
# this does not infer producer success from a constructed mock return value.
f507_receipts() {
  local tool="$1" expected_status="$2" minimum="$3" expected_count=0 directory actual
  shift 3
  for directory in "$F507_CASE"/receipt-"$tool".*; do
    [[ -d "$directory" ]] || continue
    expected_count=$((expected_count+1))
    [[ "$(cat "$directory/selected.program")" == "$TEST_MOCK_BIN/$tool" ]] || return 1
    printf '%s\0' "$@" > "$directory/expected.argv.nul" || return 2
    cmp "$directory/expected.argv.nul" "$directory/argv.nul" || return 3
    actual=$(cat "$directory/producer.actual") || return 4
    [[ "$actual" =~ ^[0-9]+$ && "$actual" -eq "$expected_status" ]] || return 5
    grep -Fxq closed "$directory/stdin.closed" || return 6
    [[ ! -e "$directory/stdin.read" ]] || return 7
    [[ -f "$directory/producer.stdout" && -f "$directory/producer.stderr" ]] || return 8
  done
  [[ "$expected_count" -ge "$minimum" ]] || return 9
}

f507_package_mocks() {
  f507_mock npm <<'MOCK' || return 1
[[ $# == 3 && "$1" == list && "$2" == -g && "$3" == --depth=0 ]] || exit 97
if [[ "${F507_PACKAGE_COUNT:-0}" == empty-stdout ]]; then exit "$F507_LIST_RETURN"; fi
if [[ "${F507_PACKAGE_COUNT:-0}" == overflow ]]; then
  cat "$F507_ROOT/oversized-output"
  exit "$F507_LIST_RETURN"
fi
printf '/fixture\n'
if [[ "$F507_PACKAGE_COUNT" == 0 ]]; then
  printf '%s\n' "${F507_EMPTY_MARKER:-└── (empty)}"
else
  for ((i=1;i<=F507_PACKAGE_COUNT;++i)); do printf '├── package%d@1.0.0\n' "$i"; done
fi
exit "$F507_LIST_RETURN"
MOCK
  f507_mock pipx <<'MOCK' || return 2
[[ $# == 2 && "$1" == list && "$2" == --short ]] || exit 97
if [[ "${F507_PACKAGE_COUNT:-0}" == overflow ]]; then
  cat "$F507_ROOT/oversized-output"
  exit "$F507_LIST_RETURN"
fi
if [[ "${F507_PACKAGE_COUNT:-0}" != empty-stdout ]]; then
  for ((i=1;i<=F507_PACKAGE_COUNT;++i)); do printf 'package%d 1.0\n' "$i"; done
fi
exit "$F507_LIST_RETURN"
MOCK
}

f507_package_row() {
  local label="$1" count="$2" code="$3" kind="$4"
  export F507_COUNTS=1 F507_PACKAGE_COUNT="$count" F507_LIST_RETURN="$code"
  f507_observe "$label" "$(f507_info_pair_program)" || return 1
  # Both report modes must have actually reached the selected finite producers.
  f507_receipts npm "$code" 2 list -g --depth=0 || return 2
  f507_receipts pipx "$code" 2 list --short || return 3
  f507_receipts uname 0 2 -r || return 4
  f507_info_pair_assert || return 5
  if [[ "$kind" == unavailable ]]; then
    grep -Eq '^ *NPM global:.*unavailable' "$F507_CASE/text.stderr" || return 6
    grep -Eq '^ *pipx packages:.*unavailable' "$F507_CASE/text.stderr" || return 7
    jq -e '(.packages|has("npm_global") and has("pipx"))
      and .packages.npm_global == null and .packages.pipx == null' "$F507_CASE/json.stdout" >/dev/null || return 8
  else
    jq -e --argjson n "$kind" '.packages.npm_global == $n and .packages.pipx == $n' "$F507_CASE/json.stdout" >/dev/null || return 9
    grep -Eq "^ *NPM global: +$kind$" "$F507_CASE/text.stderr" || return 10
    grep -Eq "^ *pipx packages: +$kind$" "$F507_CASE/text.stderr" || return 11
  fi
}

@test "sys diagnostic facts: observed failed package listings remain unavailable rather than zero" {
  command -v jq >/dev/null || skip 'jq is required for JSON assertions'
  f507_package_mocks
  local code result failures=0
  for code in 17 124; do
    if f507_package_row "package-failure-$code" 2 "$code" unavailable; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$code" "$result" >> "$F507_ROOT/package-failures.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/package-failures.tsv")" -eq 2 ]
  [ "$failures" -eq 0 ]
}

@test "sys diagnostic facts: empty stdout empty tree and real package counts stay distinct from failure" {
  command -v jq >/dev/null || skip 'jq is required for JSON assertions'
  f507_package_mocks
  local row count expected result failures=0
  for row in '2|2' '1|1' 'empty-stdout|0' '0|0'; do
    IFS='|' read -r count expected <<< "$row"
    if f507_package_row "package-count-$count" "$count" 0 "$expected"; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$count" "$result" >> "$F507_ROOT/package-counts.tsv"
  done
  export F507_EMPTY_MARKER='`-- (empty)'
  if f507_package_row package-ascii-empty 0 0 0; then result=0
  else result=$?; failures=$((failures+1)); fi
  printf 'ascii-empty\t%s\n' "$result" >> "$F507_ROOT/package-counts.tsv"
  [ "$(wc -l < "$F507_ROOT/package-counts.tsv")" -eq 5 ]
  [ "$failures" -eq 0 ]
}


@test "sys diagnostic facts: unavailable predicates and refused tools omit package keys while bounded failure stays unknown" {
  command -v jq >/dev/null || skip 'jq is required for JSON assertions'
  f507_package_mocks
  export F507_COUNTS=0 F507_PACKAGE_COUNT=1 F507_LIST_RETURN=0
  f507_observe package-absent "$(f507_info_pair_program)"
  f507_info_pair_assert
  jq -e '(.packages|has("npm_global")|not) and (.packages|has("pipx")|not)' "$F507_CASE/json.stdout" >/dev/null
  local receipt
  for receipt in "$F507_CASE"/receipt-npm.* "$F507_CASE"/receipt-pipx.*; do
    [ ! -e "$receipt" ] || return 1
  done
  # Actual metadata refusal, unlike the declared absent-predicate control.
  chmod -- 777 "$TEST_MOCK_BIN/npm" "$TEST_MOCK_BIN/pipx"
  export F507_COUNTS=1
  f507_observe package-refused "$(f507_info_pair_program)"
  f507_info_pair_assert
  jq -e '(.packages|has("npm_global")|not) and (.packages|has("pipx")|not)' "$F507_CASE/json.stdout" >/dev/null
  for receipt in "$F507_CASE"/receipt-npm.* "$F507_CASE"/receipt-pipx.*; do
    [ ! -e "$receipt" ] || return 1
  done
  chmod -- 700 "$TEST_MOCK_BIN/npm" "$TEST_MOCK_BIN/pipx"
  make_sized_file "$F507_ROOT/oversized-output" 1048577
  f507_package_row package-overflow overflow 0 unavailable
}

f507_df_mock() {
  f507_mock df <<'MOCK' || return 1
[[ $# == 2 ]] || { printf 'df arity %s\n' "$*" >> "$F507_ROOT/denied"; exit 97; }
[[ "$2" == / || "$2" == "$HOME" || "$2" == "$HOME/path with spaces" ]] \
  || { printf 'df operand %s\n' "$*" >> "$F507_ROOT/denied"; exit 97; }
case "$1" in
  -Pk) cat "$F507_ROOT/disk.fixture" ;;
  -Pki) cat "$F507_ROOT/inode.fixture" ;;
  *) printf 'df options %s\n' "$*" >> "$F507_ROOT/denied"; exit 97 ;;
esac
exit "$F507_DF_RETURN"
MOCK
}

f507_df_input() {
  local mode="$1" destination="$F507_ROOT/disk.fixture" header row
  export F507_DF_RETURN=0
  header='Filesystem 1024-blocks Used Available Capacity Mounted on'
  row='/dev/root 1000 400 600 40% /'
  case "$mode" in
    ordinary) ;;
    spaces) row='/dev/Data Set 1000 400 600 40% /media/My Disk' ;;
    repeated) row='/dev/Data  Set 1000 400 600 40% /media/My  Disk' ;;
    numeric-name) row='/dev/7 8 9 10% suffix 1000 400 600 40% /media/My Disk 55% 7 tail' ;;
    alternate-header) header='Filesystem 1K-blocks Used Available Use% Mounted on' ;;
    tabs) row=$'/dev/root\t1000\t400\t600\t40%\t/media/My Disk' ;;
    percent-limit) row='/dev/root 1000 400 600 1000% /' ;;
    integer-limit) row='/dev/root 9007199254740991 400 600 40% /' ;;
    gnu-inode)
      destination="$F507_ROOT/inode.fixture"
      header='Filesystem Inodes IUsed IFree IUse% Mounted on'
      row='server:/Data Set 2000 500 1500 25% /Volumes/My Disk' ;;
    bsd-inode)
      destination="$F507_ROOT/inode.fixture"
      header='Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on'
      row='/dev/Data Set 1000 400 600 40% 500 1500 25% /Volumes/My Disk' ;;
    bsd-inode-ordinary)
      destination="$F507_ROOT/inode.fixture"
      header='Filesystem 1K-blocks Used Available Use% iused ifree %iused Mounted on'
      row='/dev/data 1000 400 600 40% 500 1500 25% /Volumes/Data' ;;
    bsd-inode-unknown)
      destination="$F507_ROOT/inode.fixture"
      header='Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on'
      row='/dev/data 1000 400 600 40% 500 1500 - /Volumes/Data' ;;
    ambiguous) row='/dev/root 1000 400 600 40% /media/name 2000 500 1500 25% /other' ;;
    negative) row='/dev/root 1000 400 -1 40% /' ;;
    integer-overflow) row='/dev/root 9007199254740992 400 600 40% /' ;;
    decimal) row='/dev/root 1000.0 400 600 40% /' ;;
    percent-overflow) row='/dev/root 1000 400 600 1001% /' ;;
    percent-malformed) row='/dev/root 1000 400 600 40x% /' ;;
    bad-header) header='Filesystem data words Capacity Mounted on' ;;
    control) row=$'/dev/Bad\033Name 1000 400 600 40% /' ;;
    tab-in-filesystem) row=$'/dev/Data\tSet 1000 400 600 40% /' ;;
    no-row) printf '%s\n' "$header" > "$destination"; return $? ;;
    two-rows) printf '%s\n%s\n%s\n' "$header" "$row" "$row" > "$destination"; return $? ;;
    returned-17|returned-124|returned-130|returned-143) export F507_DF_RETURN="${mode#returned-}" ;;
    *) return 98 ;;
  esac
  printf '%s\n%s\n' "$header" "$row" > "$destination" || return 1
}

f507_df_row() {
  local mode="$1" flag="$2" expectation="$3" expected_primary="${4:-0}" actual
  f507_df_input "$mode" || return 1
  local body='_sys_diag_disk_record "$HOME/path with spaces"'
  [[ "$flag" != -Pki ]] || body='_sys_diag_inode_percent "$HOME/path with spaces"'
  f507_observe "df-$mode" "$body" || return 2
  f507_receipts df "$F507_DF_RETURN" 1 "$flag" "$HOME/path with spaces" || return 3
  printf '%s\t5\t65536\tdf\n' "$F507_DF_RETURN" > "$F507_CASE/native.expected.tsv" || return 11
  cmp "$F507_CASE/native.expected.tsv" "$F507_CASE/native-probes.tsv" || return 12
  # The observation status is independent of the finite producer status.
  actual=$(cat "$F507_CASE/primary.status") || return 4
  printf '%s\t%s\t%s\n' "$mode" "$F507_DF_RETURN" "$actual" >> "$F507_ROOT/df-observations.tsv" || return 5
  if [[ "$expectation" == unavailable ]]; then
    f507_primary "$actual" || return 10
    [[ "$actual" =~ ^[0-9]+$ && "$actual" -ne 0 ]] || return 6
    [[ ! -s "$F507_CASE/stdout" ]] || return 7
  else
    f507_primary "$expected_primary" || return 8
    case "$mode" in
      spaces) printf '/dev/Data Set\t1000\t400\t600\t40\n' > "$F507_CASE/expected" ;;
      repeated) printf '/dev/Data  Set\t1000\t400\t600\t40\n' > "$F507_CASE/expected" ;;
      numeric-name) printf '/dev/7 8 9 10%% suffix\t1000\t400\t600\t40\n' > "$F507_CASE/expected" ;;
      percent-limit) printf '/dev/root\t1000\t400\t600\t1000\n' > "$F507_CASE/expected" ;;
      integer-limit) printf '/dev/root\t9007199254740991\t400\t600\t40\n' > "$F507_CASE/expected" ;;
      gnu-inode|bsd-inode|bsd-inode-ordinary) printf '25\n' > "$F507_CASE/expected" ;;
      *) printf '/dev/root\t1000\t400\t600\t40\n' > "$F507_CASE/expected" ;;
    esac
    cmp "$F507_CASE/expected" "$F507_CASE/stdout" || return 9
  fi
}

@test "sys diagnostic facts: block records preserve internal spaces and unique complete numeric boundaries" {
  f507_df_mock
  local mode result failures=0
  for mode in ordinary spaces repeated numeric-name alternate-header tabs percent-limit integer-limit; do
    if f507_df_row "$mode" -Pk known; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$result" >> "$F507_ROOT/df-blocks.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/df-blocks.tsv")" -eq 8 ]
  [ "$failures" -eq 0 ]
}

@test "sys diagnostic facts: GNU inode-only and genuine BSD dual-capacity records select inode usage" {
  f507_df_mock
  local mode result failures=0
  for mode in gnu-inode bsd-inode bsd-inode-ordinary; do
    if f507_df_row "$mode" -Pki known; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$result" >> "$F507_ROOT/df-inodes.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/df-inodes.tsv")" -eq 3 ]
  [ "$failures" -eq 0 ]
}

@test "sys diagnostic facts: ambiguous malformed and unknown df records publish no partial fact" {
  f507_df_mock
  local mode flag result failures=0
  for mode in ambiguous negative integer-overflow decimal percent-overflow percent-malformed \
    bad-header control tab-in-filesystem no-row two-rows bsd-inode-unknown; do
    flag=-Pk
    [[ "$mode" != bsd-inode-unknown ]] || flag=-Pki
    if f507_df_row "$mode" "$flag" unavailable; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$result" >> "$F507_ROOT/df-refusals.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/df-refusals.tsv")" -eq 12 ]
  [ "$failures" -eq 0 ]
}

@test "sys diagnostic facts: partial failed df observations preserve the actual native status" {
  f507_df_mock
  local code result failures=0
  for code in 17 124 130 143; do
    if f507_df_row "returned-$code" -Pk unavailable "$code"; then result=0
    else result=$?; failures=$((failures+1)); fi
    # No valid-looking partial row may survive any failure.
    [[ "$(cat "$F507_CASE/primary.status")" -eq "$code" ]] || failures=$((failures+1))
    printf '%s\t%s\n' "$code" "$result" >> "$F507_ROOT/df-statuses.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/df-statuses.tsv")" -eq 4 ]
  [ "$failures" -eq 0 ]
}


f507_health_program() {
  cat <<'ZSH'
local -i health_rc=0
sys-health > "$F507_CASE/health.stdout" 2> "$F507_CASE/health.stderr" || health_rc=$?
print -r -- "$health_rc" > "$F507_CASE/health.primary.status" || return 96
return 0
ZSH
}

f507_df_public_row() {
  local mode="$1"
  export F507_DF_REAL=1
  f507_df_input bsd-inode || return 1
  case "$mode" in
    healthy) f507_df_input spaces || return 2 ;;
    ambiguous) f507_df_input ambiguous || return 3 ;;
    failed) f507_df_input returned-17 || return 4 ;;
    *) return 98 ;;
  esac
  local program
  program=$(f507_info_pair_program) || return 5
  program="${program%return 0}$(f507_health_program)"
  f507_observe "df-public-$mode" "$program" || return 6
  f507_info_pair_assert || return 7
  [[ "$(cat "$F507_CASE/health.primary.status")" == 0 ]] || return 8
  [[ -f "$F507_CASE/health.stdout" && ! -s "$F507_CASE/health.stdout" ]] || return 9
  f507_receipts uname 0 2 -r || return 10
  # Every df receipt must retain one literal operand and an observed producer;
  # the two public disk paths and inode flag are checked independently below.
  local receipt count=0 flag target code
  for receipt in "$F507_CASE"/receipt-df.*; do
    [[ -d "$receipt" ]] || continue
    count=$((count+1))
    [[ "$(cat "$receipt/selected.program")" == "$TEST_MOCK_BIN/df" ]] || return 11
    code=$(cat "$receipt/producer.actual") || return 12
    [[ "$code" == "$F507_DF_RETURN" ]] || return 13
    IFS= read -r -d '' flag < "$receipt/argv.nul" || return 14
    case "$flag" in -Pk|-Pki) ;; *) return 15 ;; esac
    # Match a complete expected NUL sequence, including the final terminator.
    for target in / "$HOME"; do
      printf '%s\0' "$flag" "$target" > "$receipt/argv.expected.nul" || return 16
      if cmp -s "$receipt/argv.expected.nul" "$receipt/argv.nul"; then break; fi
    done
    cmp "$receipt/argv.expected.nul" "$receipt/argv.nul" || return 17
    grep -Fxq closed "$receipt/stdin.closed" || return 18
  done
  [[ "$count" -eq 7 ]] || return 19
  if [[ "$mode" == healthy ]]; then
    jq -e --arg home "$HOME" '.disks.root == {path:"/",filesystem:"/dev/Data Set",total_bytes:1024000,used_bytes:409600,available_bytes:614400,used_percent:40}
      and .disks.home == {path:$home,filesystem:"/dev/Data Set",total_bytes:1024000,used_bytes:409600,available_bytes:614400,used_percent:40}' "$F507_CASE/json.stdout" >/dev/null || return 20
    grep -Eq '^ *Disk \(/\):.*\(40%\)' "$F507_CASE/text.stderr" || return 21
    grep -Fq 'Inodes at 25%' "$F507_CASE/health.stderr" || return 22
  else
    jq -e --arg home "$HOME" '.disks.root == {path:"/",filesystem:null,total_bytes:null,used_bytes:null,available_bytes:null,used_percent:null}
      and .disks.home == {path:$home,filesystem:null,total_bytes:null,used_bytes:null,available_bytes:null,used_percent:null}' "$F507_CASE/json.stdout" >/dev/null || return 23
    grep -Eq '^ *Disk \(/\):.*unavailable' "$F507_CASE/text.stderr" || return 24
    grep -Fq 'Root disk usage unavailable' "$F507_CASE/health.stderr" || return 25
  fi
}

@test "sys diagnostic facts: disk text JSON and health consume the same complete observations" {
  command -v jq >/dev/null || skip 'jq is required for JSON assertions'
  f507_df_mock
  local mode result failures=0
  for mode in healthy ambiguous failed; do
    if f507_df_public_row "$mode"; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$result" >> "$F507_ROOT/df-public.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/df-public.tsv")" -eq 3 ]
  [ "$failures" -eq 0 ]
}

f507_darwin_mock() {
  f507_mock sysctl <<'MOCK' || return 1
[[ $# == 2 && "$1" == -n ]] || exit 97
case "$2" in
  hw.memsize) printf '16777216\n' ;;
  kern.memorystatus_level) printf '50\n' ;;
  vm.swapusage)
    case "$F507_OPTIONAL" in
      failed) printf 'total = 8.00M used = 4.00M free = 4.00M\n'; exit 17 ;;
      malformed) printf 'not a swap record\n' ;;
      zero) printf 'total = 0.00M used = 0.00M free = 0.00M\n' ;;
      known) printf 'total = 8.00M used = 4.00M free = 4.00M\n' ;;
      *) exit 97 ;;
    esac ;;
  hw.logicalcpu)
    case "$F507_OPTIONAL" in
      failed) printf '8\n'; exit 17 ;;
      malformed) printf 'not-a-count\n' ;;
      zero|known) printf '8\n' ;;
      *) exit 97 ;;
    esac ;;
  machdep.cpu.brand_string|hw.model) printf 'Fixture CPU\n' ;;
  *) printf 'sysctl %s\n' "$*" >> "$F507_ROOT/denied"; exit 97 ;;
esac
MOCK
}

f507_darwin_public_row() {
  local mode="$1" program receipt query actual count=0 seen_swap=0 seen_core=0
  export F507_OS=darwin F507_MEMORY=darwin F507_CPU=darwin F507_OPTIONAL="$mode"
  program=$(f507_info_pair_program) || return 1
  program="${program%return 0}$(f507_health_program)"
  f507_observe "darwin-public-$mode" "$program" || return 2
  # Qualify each intended syscall producer, not merely unavailable output.
  for receipt in "$F507_CASE"/receipt-sysctl.*; do
    [[ -d "$receipt" ]] || continue
    count=$((count+1))
    [[ "$(cat "$receipt/selected.program")" == "$TEST_MOCK_BIN/sysctl" ]] || return 3
    local valid=0 expected=0
    for query in hw.memsize kern.memorystatus_level vm.swapusage hw.logicalcpu machdep.cpu.brand_string hw.model; do
      printf '%s\0' -n "$query" > "$receipt/argv.expected.nul" || return 4
      if cmp -s "$receipt/argv.expected.nul" "$receipt/argv.nul"; then valid=1; break; fi
    done
    [[ "$valid" -eq 1 ]] || return 5
    [[ "$query" != vm.swapusage ]] || seen_swap=$((seen_swap+1))
    [[ "$query" != hw.logicalcpu ]] || seen_core=$((seen_core+1))
    if [[ "$mode" == failed && ( "$query" == vm.swapusage || "$query" == hw.logicalcpu ) ]]; then expected=17; fi
    actual=$(cat "$receipt/producer.actual") || return 6
    [[ "$actual" =~ ^[0-9]+$ && "$actual" -eq "$expected" ]] || return 7
    grep -Fxq closed "$receipt/stdin.closed" || return 8
  done
  [[ "$count" -ge 12 && "$seen_swap" -eq 3 && "$seen_core" -eq 2 ]] || return 9
  f507_info_pair_assert || return 10
  [[ "$(cat "$F507_CASE/health.primary.status")" == 0 ]] || return 11
  [[ -f "$F507_CASE/health.stdout" && ! -s "$F507_CASE/health.stdout" ]] || return 12
  if [[ "$mode" == zero ]]; then
    jq -e '.memory == {total_bytes:16777216,available_bytes:8388608}
      and .swap == {total_bytes:0,free_bytes:0} and .cpu == {logical_cores:8,model:"Fixture CPU"}' "$F507_CASE/json.stdout" >/dev/null || return 13
    grep -Fq 'No swap configured' "$F507_CASE/health.stderr" || return 14
  elif [[ "$mode" == known ]]; then
    jq -e '.memory == {total_bytes:16777216,available_bytes:8388608}
      and .swap == {total_bytes:8388608,free_bytes:4194304}
      and .cpu == {logical_cores:8,model:"Fixture CPU"}' "$F507_CASE/json.stdout" >/dev/null || return 15
    grep -Fq 'Swap at 50%' "$F507_CASE/health.stderr" || return 16
  else
    jq -e '.memory == {total_bytes:16777216,available_bytes:8388608}
      and .swap == {total_bytes:null,free_bytes:null}
      and .cpu == {logical_cores:null,model:"Fixture CPU"}' "$F507_CASE/json.stdout" >/dev/null || return 17
    grep -Eq '^ *Swap:.*unavailable' "$F507_CASE/text.stderr" || return 18
    grep -Eq '^ *CPU:.*unavailable.*Fixture CPU' "$F507_CASE/text.stderr" || return 19
    grep -Fq 'Swap usage unavailable' "$F507_CASE/health.stderr" || return 20
    local grep_rc=0
    grep -Fq 'No swap configured' "$F507_CASE/health.stderr" || grep_rc=$?
    [[ "$grep_rc" -eq 1 ]] || return 21
  fi
}

@test "sys diagnostic facts: Darwin partial observations retain memory and model while unknown numerics stay null" {
  command -v jq >/dev/null || skip 'jq is required for JSON assertions'
  f507_darwin_mock
  local mode result failures=0
  for mode in zero known failed malformed; do
    if f507_darwin_public_row "$mode"; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$mode" "$result" >> "$F507_ROOT/darwin-public.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/darwin-public.tsv")" -eq 4 ]
  [ "$failures" -eq 0 ]
}

f507_wsl_public_row() {
  local label="$1" release="$2" code="$3" expected="$4"
  export F507_ENV=wsl F507_KERNEL="$release" F507_UNAME_RETURN="$code"
  f507_observe "wsl-public-$label" "$(f507_info_pair_program)" || return 1
  f507_receipts uname "$code" 4 -r || return 2
  f507_info_pair_assert || return 3
  if [[ "$expected" == null ]]; then
    jq -e '.wsl.generation == null and .os.kernel == null' "$F507_CASE/json.stdout" >/dev/null || return 4
    grep -Eq '^ *WSL:.*unavailable' "$F507_CASE/text.stderr" || return 5
  else
    jq -e --arg generation "$expected" '.wsl.generation == $generation' "$F507_CASE/json.stdout" >/dev/null || return 6
    grep -Eq "^ *WSL: +$expected$" "$F507_CASE/text.stderr" || return 7
  fi
}

@test "sys diagnostic facts: sys-info distinguishes established WSL generations from a failed kernel read" {
  command -v jq >/dev/null || skip 'jq is required for JSON assertions'
  local row label release code expected result failures=0
  for row in 'legacy|4.4.0-19041-Microsoft|0|WSL1' \
    'standard|5.15.153.1-microsoft-standard-WSL2|0|WSL2' \
    'custom|6.6.36-custom|0|WSL2' 'failed|partial-fixture|17|null'; do
    IFS='|' read -r label release code expected <<< "$row"
    if f507_wsl_public_row "$label" "$release" "$code" "$expected"; then result=0
    else result=$?; failures=$((failures+1)); fi
    printf '%s\t%s\n' "$label" "$result" >> "$F507_ROOT/wsl-public.tsv"
  done
  [ "$(wc -l < "$F507_ROOT/wsl-public.tsv")" -eq 4 ]
  [ "$failures" -eq 0 ]
}

@test "sys diagnostic facts: observation oracles reject missing malformed and wrong same-count evidence" {
  f507_df_mock
  f507_df_input ordinary
  f507_observe oracle-qualification '_sys_diag_disk_record "$HOME/path with spaces"'
  f507_primary 0
  f507_receipts df 0 1 -Pk "$HOME/path with spaces"
  local receipt=("$F507_CASE"/receipt-df.*) scenario actual failures=0
  local directory="${receipt[0]}"
  cp "$directory/argv.nul" "$directory/argv.original.nul"
  for scenario in nonnumeric-primary missing-stderr wrong-same-count-argv missing-producer wrong-selected-program; do
    printf '0\n' > "$F507_CASE/primary.status"
    : > "$F507_CASE/stderr"
    cp "$directory/argv.original.nul" "$directory/argv.nul"
    printf '0\n' > "$directory/producer.actual"
    printf '%s\n' "$TEST_MOCK_BIN/df" > "$directory/selected.program"
    case "$scenario" in
      nonnumeric-primary) printf 'not-a-status\n' > "$F507_CASE/primary.status" ;;
      missing-stderr) rm "$F507_CASE/stderr" ;;
      wrong-same-count-argv) printf '%s\0' -Pki "$HOME/path with spaces" > "$directory/argv.nul" ;;
      missing-producer) rm "$directory/producer.actual" ;;
      wrong-selected-program) printf '%s\n' "$TEST_MOCK_BIN/other-df" > "$directory/selected.program" ;;
    esac
    actual=0
    case "$scenario" in
      nonnumeric-primary|missing-stderr) f507_primary 0 || actual=$? ;;
      *) f507_receipts df 0 1 -Pk "$HOME/path with spaces" || actual=$? ;;
    esac
    printf '%s\t%s\n' "$scenario" "$actual" >> "$F507_ROOT/oracle-qualification.tsv"
    [[ "$actual" -ne 0 ]] || failures=$((failures+1))
  done
  [ "$(wc -l < "$F507_ROOT/oracle-qualification.tsv")" -eq 5 ]
  [ "$failures" -eq 0 ]
}
