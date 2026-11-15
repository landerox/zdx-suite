#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export F508_ROOT="$HOME/f508" F508_CASE="" F508_ENV=native
  export F508_CORES=2 F508_UPTIME=90061 F508_FINDINGS=0
  export F508_JQ_MODE=success F508_GIT_STAGE=ok NO_COLOR=1
  unset F508_REFRESH_FAIL
  mkdir -p "$F508_ROOT" "$F508_ROOT/wsl/etc/systemd/system/multi-user.target.wants" \
    "$F508_ROOT/wsl/proc/1" "$F508_ROOT/wsl/proc/net" \
    "$F508_ROOT/wsl/sys/class/net/eth0" || return 1
  : > "$F508_ROOT/denied" || return 2
  printf 'systemd\n' > "$F508_ROOT/wsl/proc/1/comm" || return 3
  printf 'nameserver 192.0.2.53\n' > "$F508_ROOT/wsl/etc/resolv.conf" || return 4
  printf '[boot]\nsystemd=true\n[automount]\noptions=metadata\n' > "$F508_ROOT/wsl/etc/wsl.conf" || return 5
  printf 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\neth0\t00000000\t0120A8C0\t0003\t0\t0\t0\t00000000\n' > "$F508_ROOT/wsl/proc/net/route" || return 6
  printf '1392\n' > "$F508_ROOT/wsl/sys/class/net/eth0/mtu" || return 7
  cat > "$HOME/f508-facts.zsh" <<'ZSH'
emulate -R zsh
_sys_capabilities_refresh() {
  if [[ "${F508_REFRESH_FAIL:-0}" == 1 ]]; then
    print -r -- reached > "$F508_CASE/refresh.reached"
    return 1
  fi
  _SYS_CAPABILITIES=(os linux environment "$F508_ENV" architecture x86_64
    package_manager unavailable os_updates_backend unavailable service_manager unavailable
    process_backend unavailable ports_backend unavailable privilege unavailable
    snapd unavailable wsl_interop unavailable)
  _SYS_CAPABILITIES_READY=1
}
_sys_diag_os_name() { print -r -- 'Fixture OS'; }
_sys_diag_memory_record() { printf '16777216\t8388608\t0\t0\n'; }
_sys_diag_cpu_record() {
  [[ "$F508_CORES" != absent ]] || return 1
  printf '%s\tFixture CPU\n' "$F508_CORES"
}
_sys_diag_runtime_record() {
  [[ "$F508_UPTIME" != unavailable ]] || return 1
  printf '%s\t0.1\t0.2\t0.3\n' "$F508_UPTIME"
}
_sys_diag_disk_record() { printf '/dev/fixture\t1000\t400\t600\t40\n'; }
_sys_diag_inode_percent() { print -r -- 10; }
_sys_diag_package_records() { return 3; }
_sys_diag_npm_global_count() { return 3; }
_sys_diag_pipx_count() { return 3; }
_sys_diag_zombie_records() { return 3; }
_sys_diag_failed_service_records() { return 3; }
_sys_diag_signaled_service_records() { return 3; }
_sys_diag_oom_event_count() {
  print -r -- reached > "$F508_CASE/oom.reached"
  if (( F508_FINDINGS > 0 )); then print -r -- 1; else print -r -- 0; fi
}
_sys_diag_pending_reboot() {
  print -r -- reached > "$F508_CASE/reboot.reached"
  (( F508_FINDINGS == 2 )) || return 1
  print -r -- 'fixture packages request reboot'
}
_sys_tool_available() { [[ "$1" == jq ]]; }
_sys_diag_tool_version() { return 3; }
_sys_wsl_config_root() { REPLY="$F508_ROOT/wsl"; }
_sys_wsl_interop_available() { return 1; }
_sys_wsl_diag_os_name() { print -r -- 'Fixture OS'; }
unset ZSH
ZSH
  f508_mock uname <<'MOCK' || return 8
[[ $# == 1 && "$1" == -r ]] || { printf 'unexpected uname %s\n' "$*" >> "$F508_ROOT/denied"; exit 97; }
printf '6.6.0-fixture\n'
MOCK
}

teardown() { cleanup_sandbox; }

# Finite recorders reuse the selected harness interpreter and private sandbox.
f508_mock() {
  local tool="$1" producer="$F508_ROOT/$1-producer" target="$TEST_MOCK_BIN/$1"
  printf '#!%s\n' "$BASH" > "$producer" || return 1
  cat >> "$producer" || return 2
  chmod -- 700 "$producer" || return 3
  printf '#!%s\n' "$BASH" > "$target" || return 4
  cat >> "$target" <<'MOCK' || return 5
[[ -d "$F508_CASE" ]] || exit 90
tool=${0##*/}
receipt=$(mktemp -d "$F508_CASE/receipt-$tool.XXXXXX") || exit 91
printf '%s\n' "$0" > "$receipt/selected.program" || exit 92
printf '%s\0' "$@" > "$receipt/argv.nul" || exit 93
if IFS= read -r supplied; then printf '%s\n' "$supplied" > "$receipt/stdin.read"; else printf 'closed\n' > "$receipt/stdin.closed"; fi
actual=0
"$F508_ROOT/$tool-producer" "$@" > "$receipt/producer.stdout" 2> "$receipt/producer.stderr" || actual=$?
printf '%s\n' "$actual" > "$receipt/producer.actual" || exit 94
cat "$receipt/producer.stdout" || exit 95
cat "$receipt/producer.stderr" >&2 || exit 96
exit "$actual"
MOCK
  chmod -- 700 "$target" || return 6
}

f508_observe() {
  local name="$1" body="$2" wrapper=0
  export F508_CASE="$F508_ROOT/$name"
  mkdir "$F508_CASE" || return 1
  run_zsh '
    source "$ZSH_CUSTOM/functions/sys-menu.zsh" || return 90
    source "$HOME/f508-facts.zsh" || return 91
    _sys_capabilities_refresh || return 92
    functions[_f508_native_probe]="${functions[_sys_run_native_probe]}"
    _sys_run_native_probe() {
      local -i observed=0
      _f508_native_probe "$@" || observed=$?
      printf "%s\t%s\t%s\t%s\n" "$observed" "$1" "$2" "$3" >> "$F508_CASE/native-probes.tsv" || return 95
      return "$observed"
    }
    _f508_action() {
  '"$body"'
    }
    local -i primary=0
    _f508_action > "$F508_CASE/stdout" 2> "$F508_CASE/stderr" || primary=$?
    print -r -- "$primary" > "$F508_CASE/primary.status" || return 93
    return 0
  ' > "$F508_CASE/wrapper.stdout" 2> "$F508_CASE/wrapper.stderr" || wrapper=$?
  printf '%s\n' "$wrapper" > "$F508_CASE/wrapper.status" || return 2
  [[ "$wrapper" -eq 0 ]] || return 3
}

f508_primary() {
  local expected="$1" actual wrapper bytes
  [[ -f "$F508_CASE/primary.status" ]] || return 1
  actual=$(cat "$F508_CASE/primary.status") || return 2
  [[ "$actual" =~ ^[0-9]{1,3}$ ]] || return 3
  bytes=$(file_size "$F508_CASE/primary.status") || return 4
  [[ "$bytes" -eq "${#actual}"+1 && "$actual" -le 255 && "$actual" -eq "$expected" ]] || return 5
  wrapper=$(cat "$F508_CASE/wrapper.status") || return 6
  [[ "$wrapper" == 0 ]] || return 7
  [[ -f "$F508_CASE/wrapper.stdout" && ! -s "$F508_CASE/wrapper.stdout" \
    && -f "$F508_CASE/wrapper.stderr" && ! -s "$F508_CASE/wrapper.stderr" ]] || return 10
  [[ -f "$F508_CASE/stdout" && -f "$F508_CASE/stderr" ]] || return 8
  [[ -f "$F508_ROOT/denied" && ! -s "$F508_ROOT/denied" ]] || return 9
}

f508_one_receipt() {
  local tool="$1" expected="$2" actual selected
  local -a receipts=("$F508_CASE"/receipt-"$tool".*)
  [[ "${#receipts[@]}" -eq 1 && -d "${receipts[0]}" ]] || return 1
  F508_RECEIPT="${receipts[0]}"
  selected=$(cat "$F508_RECEIPT/selected.program") || return 2
  [[ "$selected" == "$TEST_MOCK_BIN/$tool" ]] || return 3
  actual=$(cat "$F508_RECEIPT/producer.actual") || return 4
  [[ "$actual" == "$expected" ]] || return 5
  [[ -f "$F508_RECEIPT/producer.stdout" && -f "$F508_RECEIPT/producer.stderr" && -s "$F508_RECEIPT/argv.nul" ]] || return 6
}

f508_jq_install() {
  export F508_REAL_JQ
  F508_REAL_JQ=$(type -P jq) || return 1
  f508_mock jq <<'MOCK' || return 2
if [[ "$F508_JQ_MODE" == fail ]]; then
  printf '{"partial":"fixture-jq"}\n'
  printf 'finite jq generation failure\n' >&2
  exit 17
fi
exec "$F508_REAL_JQ" "$@"
MOCK
}

f508_json_assert() {
  local schema="$1" lines
  lines=$(wc -l < "$F508_CASE/stdout") || return 1
  [[ "$lines" -eq 1 ]] || return 2
  "$F508_REAL_JQ" -e -s --arg schema "$schema" '
    length == 1 and (.[0] | type == "object" and .schema == $schema
      and keys_unsorted[0] == "schema")
  ' "$F508_CASE/stdout" > "$F508_CASE/shape.check" || return 3
  "$F508_REAL_JQ" -cM . "$F508_CASE/stdout" > "$F508_CASE/canonical" || return 4
  cmp "$F508_CASE/canonical" "$F508_CASE/stdout" || return 5
}

f508_jq_options() {
  local arg compact=0 monochrome=0 null_input=0
  while IFS= read -r -d '' arg; do
    case "$arg" in
      --compact-output) compact=1 ;;
      --monochrome-output) monochrome=1 ;;
      --null-input) null_input=1 ;;
      --*) break ;;
      -[A-Za-z]*)
        [[ "$arg" != *c* ]] || compact=1
        [[ "$arg" != *M* ]] || monochrome=1
        [[ "$arg" != *n* ]] || null_input=1 ;;
      *) break ;;
    esac
  done < "$1"
  [[ "$compact" -eq 1 && "$monochrome" -eq 1 && "$null_input" -eq 1 ]] || return 1
}

f508_verdict() {
  local expected="$1"
  awk '
    NF { last = NR }
    index($0,"System health:") { print substr($0,index($0,"System health:")); count++; verdict = NR }
    END { exit !(count == 1 && verdict == last) }
  ' "$F508_CASE/stderr" > "$F508_CASE/verdict.actual" || return 1
  printf '%s\n' "$expected" > "$F508_CASE/verdict.expected" || return 2
  cmp "$F508_CASE/verdict.expected" "$F508_CASE/verdict.actual" || return 3
}

f508_json_scenes() {
  local mode="$1"
  export F508_JQ_MODE="$mode" F508_ENV=native
  f508_observe "$mode-info" 'sys-info --json' || return 1
  f508_observe "$mode-native" 'sys-wsl --json' || return 2
  export F508_ENV=wsl WSL_DISTRO_NAME=Fixture
  f508_observe "$mode-wsl" 'sys-wsl --json' || return 3
}

@test "sys output: public JSON keeps compact single-object typed documents and semantic statuses" {
  f508_jq_install
  f508_json_scenes success
  local scene schema expected
  for scene in info native wsl; do
    export F508_CASE="$F508_ROOT/success-$scene"
    expected=0; schema=zdx.sys-wsl.v1
    [[ "$scene" != native ]] || expected=1
    [[ "$scene" != info ]] || schema=zdx.sys-info.v1
    f508_primary "$expected" || return 1
    f508_json_assert "$schema" || return 2
    f508_one_receipt jq 0 || return 3
    cmp "$F508_RECEIPT/producer.stdout" "$F508_CASE/stdout" || return 4
    if [[ "$scene" == info ]]; then
      "$F508_REAL_JQ" -e --arg home "$HOME" '
        keys_unsorted == ["schema","os","wsl","memory","swap","cpu","disks","uptime_seconds","load_average","shell","oh_my_zsh","tools","packages"]
        and .os == {name:"Fixture OS",kernel:"6.6.0-fixture",architecture:"x86_64",environment:"native"}
        and .wsl == null and .memory == {total_bytes:16777216,available_bytes:8388608}
        and .swap == {total_bytes:0,free_bytes:0} and .cpu == {logical_cores:2,model:"Fixture CPU"}
        and .disks.root.path == "/" and .disks.home.path == $home
        and .disks.root.used_percent == 40 and .uptime_seconds == 90061
        and .load_average == {one:0.1,five:0.2,fifteen:0.3}
        and .oh_my_zsh == {installed:false,version:null} and .packages == {}
        and (.tools | length == 13 and all(.[]; . == null))
      ' "$F508_CASE/stdout" || return 5
      f508_one_receipt uname 0 || return 6
      printf '%s\0' -r > "$F508_CASE/uname.expected" || return 7
      cmp "$F508_CASE/uname.expected" "$F508_RECEIPT/argv.nul" || return 8
      [[ -f "$F508_RECEIPT/stdin.closed" ]] || return 9
    elif [[ "$scene" == native ]]; then
      "$F508_REAL_JQ" -e '. == {schema:"zdx.sys-wsl.v1",applicable:false,reason:"not a WSL host"}' "$F508_CASE/stdout" || return 10
      grep -Fq 'not a WSL host' "$F508_CASE/stderr" || return 11
    else
      "$F508_REAL_JQ" -e '
        keys_unsorted == ["schema","applicable","host","wsl_conf","network","windows","disk","findings"]
        and .applicable == true and .host == {generation:"WSL2",kernel:"6.6.0-fixture",distribution:"Fixture",os:"Fixture OS",pid1:"systemd",systemd_pid1:true,enabled_service_units:[]}
        and .wsl_conf.state == "present" and .wsl_conf.reason == null
        and .wsl_conf.settings.boot.systemd == true and .wsl_conf.settings.automount.metadata == true
        and .network.default_interface == "eth0" and .network.default_interface_mtu == 1392
        and .network.networking_mode == null and .network.boot_mtu_pin == null and .network.tunnel_interfaces == []
        and .windows.profile_path == null and .windows.reason == "Windows interop is unavailable"
        and .windows.wslconfig.state == "unavailable" and .disk.vhdx_size_bytes == null
        and (.disk.compaction_steps | length == 4) and .findings == []
      ' "$F508_CASE/stdout" || return 12
    fi
  done
}

@test "sys output: each public JSON generation requests compact monochrome null input" {
  f508_jq_install
  f508_json_scenes success
  local scene failed=0
  for scene in info native wsl; do
    export F508_CASE="$F508_ROOT/success-$scene"
    f508_one_receipt jq 0 || return 1
    if f508_jq_options "$F508_RECEIPT/argv.nul"; then
      printf '0\n' > "$F508_CASE/options.actual"
    else
      printf '%s\n' "$?" > "$F508_CASE/options.actual"
      failed=1
    fi
  done
  [[ "$failed" -eq 0 ]]
}

@test "sys output: failed jq producer is observed independently and no public route emits partial JSON" {
  f508_jq_install
  f508_json_scenes fail
  local scene
  for scene in info native wsl; do
    export F508_CASE="$F508_ROOT/fail-$scene"
    f508_primary 1 || return 1
    f508_one_receipt jq 17 || return 2
    printf '{"partial":"fixture-jq"}\n' > "$F508_CASE/producer.expected" || return 3
    cmp "$F508_CASE/producer.expected" "$F508_RECEIPT/producer.stdout" || return 4
    grep -Fxq 'finite jq generation failure' "$F508_RECEIPT/producer.stderr" || return 5
    [[ ! -s "$F508_CASE/stdout" ]] || return 6
  done
}

@test "sys output: CPU uses singular and plural while partial and absent observations stay unavailable" {
  local cores expected failed=0
  f508_jq_install || return 6
  for cores in 1 2 unknown absent 999999999999999999 1000000000000000000; do
    export F508_CORES="$cores"
    f508_observe "cpu-$cores" 'sys-info' || return 1
  done
  # Private formatter-protocol model; real CPU adapters cap counts at 1048576.
  for cores in 999999999999999999 1000000000000000000; do
    export F508_CORES="$cores"
    f508_observe "cpu-noun-$cores" '
      local REPLY="seeded"
      local -i actual=0
      _sys_count_noun "$F508_CORES" "logical core" || actual=$?
      print -rn -- "$REPLY" > "$F508_CASE/noun.reply" || return 94
      return "$actual"
    ' || return 7
  done
  f508_observe cpu-large-json 'sys-info --json' || return 8
  for cores in 1 2 unknown absent 999999999999999999 1000000000000000000; do
    export F508_CASE="$F508_ROOT/cpu-$cores"
    f508_primary 0 || return 2
    [[ ! -s "$F508_CASE/stdout" ]] || return 3
    case "$cores" in
      1) expected='1 logical core — Fixture CPU' ;;
      2) expected='2 logical cores — Fixture CPU' ;;
      unknown) expected='logical cores unavailable — Fixture CPU' ;;
      absent) expected='unavailable' ;;
      999999999999999999) expected='999999999999999999 logical cores — Fixture CPU' ;;
      1000000000000000000) expected='logical cores unavailable — Fixture CPU' ;;
    esac
    if grep -Eq "^ *CPU: +$expected$" "$F508_CASE/stderr"; then printf '0\n' > "$F508_CASE/cpu.status"; else
      printf '%s\n' "$?" > "$F508_CASE/cpu.status"; failed=1
    fi
    f508_one_receipt uname 0 || return 5
  done
  export F508_CASE="$F508_ROOT/cpu-noun-999999999999999999"
  f508_primary 0 || return 9
  printf '%s' '999999999999999999 logical cores' > "$F508_CASE/reply.expected" || return 10
  cmp "$F508_CASE/reply.expected" "$F508_CASE/noun.reply" || return 11
  export F508_CASE="$F508_ROOT/cpu-noun-1000000000000000000"
  f508_primary 2 || return 12
  [[ -f "$F508_CASE/noun.reply" && ! -s "$F508_CASE/noun.reply" ]] || return 13
  export F508_CASE="$F508_ROOT/cpu-large-json"
  f508_primary 0 || return 14
  f508_json_assert zdx.sys-info.v1 || return 15
  f508_one_receipt jq 0 || return 16
  "$F508_REAL_JQ" -e '.cpu == {logical_cores:1000000000000000000,model:"Fixture CPU"}' "$F508_CASE/stdout" || return 17
  [[ "$failed" -eq 0 ]]
}

@test "sys output: uptime delegates core rounding and keeps numeric JSON and unavailable facts" {
  local row seconds expected failed=0
  f508_jq_install || return 24
  for row in '59|59s' '60|1m 00s' '3600|1h 00m' '86370|1d 00h' '88200|1d 01h' '90061|1d 01h' '171000|2d 00h' '1000000000|11574d 02h'; do
    IFS='|' read -r seconds expected <<< "$row" || return 1
    export F508_UPTIME="$seconds"
    f508_observe "uptime-$seconds" '
      local value
      value=$(_sys_diag_format_uptime "$F508_UPTIME") || return $?
      print -r -- "$value"
    ' || return 2
  done
  export F508_UPTIME=90061
  f508_observe uptime-public 'sys-info' || return 3
  export F508_UPTIME=unavailable
  f508_observe uptime-unavailable 'sys-info' || return 4
  f508_observe uptime-invalid '_sys_diag_format_uptime invalid' || return 5
  f508_observe uptime-standalone '
    unfunction _zdx_format_duration
    local value
    value=$(_sys_diag_format_uptime 90061) || return $?
    print -r -- "$value"
  ' || return 6
  f508_observe uptime-display-limit-helper '_sys_diag_format_uptime 1000000001' || return 25
  f508_observe uptime-display-limit-public 'F508_UPTIME=1000000001 sys-info' || return 26
  f508_observe uptime-display-limit-json 'F508_UPTIME=1000000001 sys-info --json' || return 27
  for row in '59|59s' '60|1m 00s' '3600|1h 00m' '86370|1d 00h' '88200|1d 01h' '90061|1d 01h' '171000|2d 00h' '1000000000|11574d 02h'; do
    IFS='|' read -r seconds expected <<< "$row" || return 7
    export F508_CASE="$F508_ROOT/uptime-$seconds"
    f508_primary 0 || return 8
    printf '%s\n' "$expected" > "$F508_CASE/expected" || return 9
    if cmp "$F508_CASE/expected" "$F508_CASE/stdout"; then printf '0\n' > "$F508_CASE/duration.status"; else
      printf '%s\n' "$?" > "$F508_CASE/duration.status"; failed=1
    fi
  done
  export F508_CASE="$F508_ROOT/uptime-public"
  f508_primary 0 || return 11
  if grep -Eq '^ *Uptime: +1d 01h$' "$F508_CASE/stderr"; then :; else failed=1; fi
  export F508_CASE="$F508_ROOT/uptime-unavailable"
  f508_primary 0 || return 13
  grep -Eq '^ *Uptime: +unavailable$' "$F508_CASE/stderr" || return 14
  export F508_CASE="$F508_ROOT/uptime-invalid"
  f508_primary 2 || return 15
  grep -Fxq unknown "$F508_CASE/stdout" || return 16
  export F508_CASE="$F508_ROOT/uptime-standalone"
  f508_primary 0 || return 17
  if grep -Fxq 90061s "$F508_CASE/stdout"; then :; else failed=1; fi
  export F508_CASE="$F508_ROOT/uptime-display-limit-helper"
  f508_primary 2 || failed=1
  [[ ! -s "$F508_CASE/stdout" ]] || failed=1
  export F508_CASE="$F508_ROOT/uptime-display-limit-public"
  f508_primary 0 || return 28
  if grep -Eq '^ *Uptime: +unavailable$' "$F508_CASE/stderr"; then printf '0\n' > "$F508_CASE/display-limit.status"; else
    printf '%s\n' "$?" > "$F508_CASE/display-limit.status"; failed=1
  fi
  [[ ! -s "$F508_CASE/stdout" ]] || return 29
  export F508_CASE="$F508_ROOT/uptime-display-limit-json"
  f508_primary 0 || return 30
  f508_json_assert zdx.sys-info.v1 || return 31
  f508_one_receipt jq 0 || return 32
  "$F508_REAL_JQ" -e '.uptime_seconds == 1000000001' "$F508_CASE/stdout" || return 33
  [[ "$failed" -eq 0 ]]
}

@test "sys output: health emits one full counted verdict and preserves findings versus failure" {
  local findings expected failed=0
  for findings in 0 1 2; do
    export F508_FINDINGS="$findings"
    f508_observe "health-$findings" 'sys-health' || return 1
  done
  f508_observe health-operational 'F508_REFRESH_FAIL=1 sys-health' || return 2
  for findings in 0 1 2; do
    export F508_CASE="$F508_ROOT/health-$findings"
    f508_primary 0 || return 3
    [[ ! -s "$F508_CASE/stdout" && -s "$F508_CASE/oom.reached" && -s "$F508_CASE/reboot.reached" ]] || return 4
    grep -Fq 'Zombie process check unavailable' "$F508_CASE/stderr" || return 5
    case "$findings" in
      0) expected='System health: all available checks passed.' ;;
      1) expected='System health: 1 issue found — review the output above.' ;;
      2) expected='System health: 2 issues found — review the output above.' ;;
    esac
    if f508_verdict "$expected"; then printf '0\n' > "$F508_CASE/verdict.status"; else
      printf '%s\n' "$?" > "$F508_CASE/verdict.status"; failed=1
    fi
  done
  export F508_CASE="$F508_ROOT/health-operational"
  f508_primary 1 || return 6
  [[ -s "$F508_CASE/refresh.reached" && ! -e "$F508_CASE/oom.reached" && ! -s "$F508_CASE/stdout" ]] || return 7
  if grep -Fq 'System health:' "$F508_CASE/stderr"; then return 8; fi
  [[ "$failed" -eq 0 ]]
}

f508_git_install() {
  f508_mock git <<'MOCK'
[[ $# -ge 3 && "$1" == -C ]] || { printf 'unexpected git %s\n' "$*" >> "$F508_ROOT/denied"; exit 97; }
repository=$2
shift 2
case "$*" in
  'rev-parse --show-toplevel')
    [[ "$F508_GIT_STAGE" != top-fail ]] || exit 17
    printf '%s\n' "$repository" ;;
  'config --local --null --get-all remote.origin.url') printf 'https://example.invalid/fixture.git\0' ;;
  'rev-parse --verify HEAD^{commit}') printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
  *) printf 'unexpected git %s\n' "$*" >> "$F508_ROOT/denied"; exit 97 ;;
esac
MOCK
}

@test "sys output: checkout refusals abbreviate only HOME boundaries and preserve escaped literal paths" {
  f508_git_install
  mkdir "$HOME/checkout" "$HOME/verified" "$HOME/verified/.git" "$HOME-neighbor" || return 1
  export F508_CHECKOUT="$HOME/checkout"
  f508_observe checkout-metadata '_sys_update_git_fingerprint "$HOME" "$F508_CHECKOUT"' || return 2
  export F508_CHECKOUT="$HOME"
  f508_observe checkout-home '_sys_update_git_fingerprint "$HOME" "$F508_CHECKOUT"' || return 3
  export F508_CHECKOUT="$HOME-neighbor"
  f508_observe checkout-neighbor '_sys_update_git_fingerprint "$HOME" "$F508_CHECKOUT"' || return 4
  export F508_CHECKOUT="$HOME/line"$'\t'"profile"
  f508_observe checkout-control '_sys_update_git_fingerprint "$HOME" "$F508_CHECKOUT"' || return 5
  export F508_CHECKOUT="$HOME/literal\profile"
  f508_observe checkout-backslash '_sys_update_git_fingerprint "$HOME" "$F508_CHECKOUT"' || return 20
  export F508_CHECKOUT="$HOME/checkout"
  f508_observe checkout-trailing 'local original="$HOME"; HOME="$original///" _sys_update_git_fingerprint "$original" "$F508_CHECKOUT"' || return 21
  f508_observe checkout-empty 'local original="$HOME"; HOME="" _sys_update_git_fingerprint "$original" "$F508_CHECKOUT"' || return 22
  f508_observe checkout-root 'local original="$HOME"; HOME=/ _sys_update_git_fingerprint "$original" "$F508_CHECKOUT"' || return 23
  export F508_CHECKOUT="$HOME/verified" F508_GIT_STAGE=top-fail
  f508_observe checkout-reader 'ZSH="$F508_CHECKOUT" update-omz --dry-run' || return 6
  export F508_GIT_STAGE=ok
  f508_observe checkout-positive '
    local -a reply=()
    _sys_update_git_fingerprint "$HOME" "$F508_CHECKOUT" || return $?
    print -r -- "${reply[1]}"
  ' || return 7
  local scene failed=0 expected
  for scene in metadata home neighbor control backslash trailing empty root reader; do
    export F508_CASE="$F508_ROOT/checkout-$scene"
    f508_primary 1 || return 8
    [[ ! -s "$F508_CASE/stdout" ]] || return 9
    case "$scene" in
      metadata) expected='Git metadata is not an owned, symlink-free directory: ~/checkout/.git' ;;
      home) expected='Git checkout is not an owned, symlink-free child of HOME: ~' ;;
      neighbor) expected="Git checkout is not an owned, symlink-free child of HOME: $HOME-neighbor" ;;
      control) expected='Git checkout is not an owned, symlink-free child of HOME: ~/line\tprofile' ;;
      backslash) expected='Git checkout is not an owned, symlink-free child of HOME: ~/literal\profile' ;;
      trailing) expected='Git metadata is not an owned, symlink-free directory: ~/checkout/.git' ;;
      empty|root) expected="Git metadata is not an owned, symlink-free directory: $HOME/checkout/.git" ;;
      reader) expected='Unable to verify Git checkout: ~/verified' ;;
    esac
    if grep -Fxq -- "✘ $expected" "$F508_CASE/stderr"; then printf '0\n' > "$F508_CASE/path.status"; else
      printf '%s\n' "$?" > "$F508_CASE/path.status"; failed=1
    fi
    if [[ "$scene" == reader ]]; then
      f508_one_receipt git 17 || return 10
      printf '%s\0' -C "$HOME/verified" rev-parse --show-toplevel > "$F508_CASE/argv.expected" || return 11
      cmp "$F508_CASE/argv.expected" "$F508_RECEIPT/argv.nul" || return 12
    else
      local -a absent=("$F508_CASE"/receipt-git.*)
      [[ ! -d "${absent[0]}" ]] || return 13
    fi
  done
  export F508_CASE="$F508_ROOT/checkout-positive"
  f508_primary 0 || return 14
  grep -Fxq -- "$HOME/verified" "$F508_CASE/stdout" || return 15
  local -a reached=("$F508_CASE"/receipt-git.*)
  [[ "${#reached[@]}" -eq 3 ]] || return 16
  local receipt actual selected
  for receipt in "${reached[@]}"; do
    actual=$(cat "$receipt/producer.actual") || return 17
    selected=$(cat "$receipt/selected.program") || return 18
    [[ "$actual" == 0 && "$selected" == "$TEST_MOCK_BIN/git" ]] || return 19
  done
  [[ "$failed" -eq 0 ]]
}
