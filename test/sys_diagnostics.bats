#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "sys diagnostics: capability routing selects Linux, WSL, and macOS collectors" {
  run run_zsh '
    _sys_linux_diag_memory_record() { print -r -- "linux"; }
    _sys_wsl_diag_memory_record() { print -r -- "wsl"; }
    _sys_macos_diag_memory_record() { print -r -- "macos"; }

    _SYS_CAPABILITIES=(os linux environment native)
    _SYS_CAPABILITIES_READY=1
    print -r -- "$(_sys_diag_memory_record)"

    _SYS_CAPABILITIES[environment]="wsl"
    print -r -- "$(_sys_diag_memory_record)"

    _SYS_CAPABILITIES[os]="darwin"
    _SYS_CAPABILITIES[environment]="native"
    print -r -- "$(_sys_diag_memory_record)"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'linux\nwsl\nmacos' ]
}

@test "sys diagnostics: Linux collectors emit typed TSV records" {
  skip_on_darwin "the Linux collectors read /proc/meminfo, /proc/cpuinfo, and /proc/uptime"
  run run_zsh '
    [[ "$(_sys_detect_os)" == "linux" ]] || return 0

    local memory_record cpu_record runtime_record
    local total_bytes available_bytes swap_total_bytes swap_free_bytes
    local core_count cpu_model uptime_seconds load_one load_five load_fifteen

    memory_record=$(_sys_linux_diag_memory_record) || return 1
    IFS=$'\''\t'\'' read -r total_bytes available_bytes \
      swap_total_bytes swap_free_bytes <<< "$memory_record"
    [[ "$total_bytes" =~ ^[0-9]+$ && "$available_bytes" =~ ^[0-9]+$ ]]
    [[ "$swap_total_bytes" =~ ^[0-9]+$ && "$swap_free_bytes" =~ ^[0-9]+$ ]]

    cpu_record=$(_sys_linux_diag_cpu_record) || return 2
    IFS=$'\''\t'\'' read -r core_count cpu_model <<< "$cpu_record"
    [[ "$core_count" =~ ^[0-9]+$ && -n "$cpu_model" ]]

    runtime_record=$(_sys_linux_diag_runtime_record) || return 3
    IFS=$'\''\t'\'' read -r uptime_seconds load_one load_five load_fifteen \
      <<< "$runtime_record"
    [[ "$uptime_seconds" =~ ^[0-9]+$ ]]
    [[ -n "$load_one" && -n "$load_five" && -n "$load_fifteen" ]]
  '

  [ "$status" -eq 0 ]
}

@test "sys diagnostics: disk collection has a hard deadline" {
  cat > "$TEST_MOCK_BIN/df" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
  chmod +x "$TEST_MOCK_BIN/df"

  run run_zsh '_sys_diag_disk_record /'

  [ "$status" -eq 124 ]
  [ -z "$output" ]
}

@test "sys diagnostics: macOS collectors parse Darwin command output" {
  cat > "$TEST_MOCK_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-n hw.memsize") echo "17179869184" ;;
  "-n vm.swapusage") echo "total = 2048.00M  used = 1024.00M  free = 1024.00M" ;;
  "-n hw.logicalcpu") echo "8" ;;
  "-n machdep.cpu.brand_string") echo "Apple M2" ;;
  "-n kern.boottime") echo "{ sec = 1000, usec = 0 }" ;;
  "-n vm.loadavg") echo "{ 1.00 2.00 3.00 }" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$TEST_MOCK_BIN/vm_stat" <<'EOF'
#!/usr/bin/env bash
echo "Mach Virtual Memory Statistics: (page size of 4096 bytes)"
echo "Pages free:                              10."
echo "Pages inactive:                          20."
echo "Pages speculative:                        5."
EOF
  cat > "$TEST_MOCK_BIN/sw_vers" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -productName) echo "macOS" ;;
  -productVersion) echo "15.5" ;;
  -buildVersion) echo "24F74" ;;
esac
EOF
  cat > "$TEST_MOCK_BIN/pkgutil" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "com.example.one" "com.example.two"
EOF
  chmod +x "$TEST_MOCK_BIN/sysctl" "$TEST_MOCK_BIN/vm_stat" \
    "$TEST_MOCK_BIN/sw_vers" "$TEST_MOCK_BIN/pkgutil"

  run run_zsh '
    _sys_macos_diag_os_name
    _sys_macos_diag_memory_record
    _sys_macos_diag_cpu_record
    _sys_macos_diag_runtime_record
    _sys_macos_diag_package_records softwareupdate
  '

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" = "macOS 15.5 (24F74)" ]]
  [[ "${lines[1]}" = $'17179869184\t143360\t2147483648\t1073741824' ]]
  [[ "${lines[2]}" = $'8\tApple M2' ]]
  [[ "${lines[3]}" =~ ^[0-9]+$'\t1.00\t2.00\t3.00' ]]
  [[ "${lines[4]}" = $'Installer packages\t2' ]]
}

@test "sys diagnostics: sys-info renders WSL data only on stderr" {
  local stdout_file="$TEST_TEMP_DIR/sys-info.stdout"
  local stderr_file="$TEST_TEMP_DIR/sys-info.stderr"

  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os linux environment wsl architecture x86_64
        package_manager apt service_manager unavailable
        process_backend procps ports_backend ss privilege sudo
        snapd unavailable wsl_interop available
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_diag_os_name() { print -r -- "Test Linux"; }
    _sys_wsl_diag_release() { print -r -- "WSL2"; }
    _sys_wsl_diag_windows_version() { print -r -- "10.0.26100.1"; }
    _sys_diag_memory_record() { printf "17179869184\t8589934592\t2147483648\t1073741824\n"; }
    _sys_diag_cpu_record() { printf "8\tTest CPU\n"; }
    _sys_diag_runtime_record() { printf "90061\t1.0\t2.0\t3.0\n"; }
    _sys_diag_disk_record() { printf "/dev/test\t100000\t50000\t50000\t50\n"; }
    _sys_diag_render_tool() { return 0; }
    _sys_diag_render_package_records() { _sys_label "APT packages:" "42"; }

    sys-info >"$HOME/sys-info.stdout" 2>"$HOME/sys-info.stderr"
  '

  [ "$status" -eq 0 ]
  cp "$HOME/sys-info.stdout" "$stdout_file"
  cp "$HOME/sys-info.stderr" "$stderr_file"
  [ ! -s "$stdout_file" ]
  grep -q "Test Linux" "$stderr_file"
  grep -q "WSL2" "$stderr_file"
  grep -q "10.0.26100.1" "$stderr_file"
  grep -q "8 logical cores" "$stderr_file"
}

# Zsh code with one deterministic WSL host for the sys-info output tests.
# shellcheck disable=SC2016  # Zsh expands this code, not Bash.
SYS_INFO_HOST='
  _sys_capabilities_refresh() {
    _SYS_CAPABILITIES=(
      os linux environment wsl architecture x86_64
      package_manager apt service_manager unavailable
      process_backend procps ports_backend ss privilege sudo
      snapd unavailable wsl_interop available
    )
    _SYS_CAPABILITIES_READY=1
  }
  _sys_diag_os_name() { print -r -- "Test Linux"; }
  _sys_wsl_diag_release() { print -r -- "WSL2"; }
  _sys_wsl_diag_windows_version() { print -r -- "10.0.26100.1"; }
  _sys_diag_memory_record() { printf "17179869184\t8589934592\t2147483648\t1073741824\n"; }
  _sys_diag_cpu_record() { printf "8\tTest CPU\n"; }
  _sys_diag_runtime_record() { printf "90061\t1.00\t2.50\t3\n"; }
  _sys_diag_disk_record() { printf "/dev/test\t100000\t50000\t50000\t50\n"; }
  _sys_diag_package_records() { printf "APT packages\t42\nSnap packages\t3\n"; }
  _sys_tool_available() { [[ "$1" == (git|jq|npm|pipx) ]]; }
  _sys_diag_tool_version() { [[ "$1" == git ]] && print -r -- "2.45.0"; }
  unset ZSH
  export SHELL=/bin/zsh
'

write_sys_info_tool_mocks() {
  cat > "$TEST_MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -r) echo "6.6.0-test" ;;
  -m) echo "x86_64" ;;
  *) echo "Linux" ;;
esac
EOF
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" /usr/lib "├── a@1" "└── b@2"\n' \
    > "$TEST_MOCK_BIN/npm"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_MOCK_BIN/pipx"
  chmod +x "$TEST_MOCK_BIN/uname" "$TEST_MOCK_BIN/npm" "$TEST_MOCK_BIN/pipx"
}

@test "sys diagnostics: sys-info text output keeps its layout" {
  write_sys_info_tool_mocks
  run run_zsh "$SYS_INFO_HOST"'
    NO_COLOR=1 sys-info >"$HOME/out" 2>"$HOME/err"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/out" ]
  local expected="$TEST_TEMP_DIR/sys-info.expected"
  {
    printf '\n════ System Information ════\n\n'
    printf '  %-19s%s\n' \
      "OS:" "Test Linux" \
      "Kernel:" "6.6.0-test" \
      "Architecture:" "x86_64" \
      "Environment:" "WSL" \
      "WSL:" "WSL2" \
      "Windows:" "10.0.26100.1" \
      "Memory:" "16.0 GiB total, 8.0 GiB available" \
      "Swap:" "2.0 GiB total, 1.0 GiB free" \
      "CPU:" "8 logical cores — Test CPU" \
      "Disk (/):" "48.8 MiB used of 97.7 MiB (50%)" \
      "Disk (HOME):" "48.8 MiB used of 97.7 MiB (50%)" \
      "Uptime:" "1d 1h 1m" \
      "Load:" "1.00 2.50 3 (1m 5m 15m)"
    printf '\n\n'
    printf '  %-19s%s\n' "Git:" "2.45.0"
    printf '\n'
    printf '  %-19s%s\n' \
      "APT packages:" "42" \
      "Snap packages:" "3" \
      "NPM global:" "2" \
      "pipx packages:" "0"
  } > "$expected"
  # The shell line carries the host's own zsh version.
  grep -Eq '^  Shell: +/bin/zsh \(zsh [0-9]' "$HOME/err"
  grep -v '^  Shell:' "$HOME/err" > "$TEST_TEMP_DIR/sys-info.actual"
  diff -u "$expected" "$TEST_TEMP_DIR/sys-info.actual"
}

@test "sys diagnostics: sys-info --json maps the typed host facts" {
  command -v jq >/dev/null || skip "jq is not installed"
  write_sys_info_tool_mocks
  run run_zsh "$SYS_INFO_HOST"'
    sys-info --json >"$HOME/wsl.json" 2>"$HOME/wsl.err" || exit 1
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os linux environment native architecture x86_64
        package_manager apt service_manager systemd
        process_backend procps ports_backend ss privilege sudo
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_wsl_diag_windows_version() { print -r -- called > "$HOME/interop"; }
    sys-info --json >"$HOME/native.json" 2>/dev/null
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/wsl.err" ]
  [ "$(wc -l < "$HOME/wsl.json")" -eq 1 ]
  ! grep -q $'\033' "$HOME/wsl.json" || false
  jq -e --arg home "$HOME" '
    (keys_unsorted == ["schema", "os", "wsl", "memory", "swap", "cpu",
      "disks", "uptime_seconds", "load_average", "shell", "oh_my_zsh",
      "tools", "packages"])
    and .schema == "zdx.sys-info.v1"
    and .os == {name: "Test Linux", kernel: "6.6.0-test",
      architecture: "x86_64", environment: "wsl"}
    and .wsl == {generation: "WSL2", windows_version: "10.0.26100.1"}
    and .memory == {total_bytes: 17179869184, available_bytes: 8589934592}
    and .swap == {total_bytes: 2147483648, free_bytes: 1073741824}
    and .cpu == {logical_cores: 8, model: "Test CPU"}
    and .disks.root == {path: "/", filesystem: "/dev/test",
      total_bytes: 102400000, used_bytes: 51200000,
      available_bytes: 51200000, used_percent: 50}
    and .disks.home.path == $home
    and .uptime_seconds == 90061
    and .load_average == {one: 1, five: 2.5, fifteen: 3}
    and .shell.path == "/bin/zsh" and (.shell.zsh_version | type) == "string"
    and .oh_my_zsh == {installed: false, version: null}
    and .tools == {starship: null, git: "2.45.0", python: null, uv: null,
      node: null, rust: null, go: null, docker: null, gcloud: null,
      terraform: null, kubectl: null, helm: null}
    and .packages == {apt: 42, snap: 3, npm_global: 2, pipx: null}
  ' "$HOME/wsl.json"
  jq -e '.wsl == null and .os.environment == "native"' "$HOME/native.json"
  [ ! -e "$HOME/interop" ]
}

@test "sys diagnostics: sys-info --json rejects extra arguments and needs jq" {
  local arguments
  for arguments in '--json extra' '--json --json' '--help --json' 'extra'; do
    run run_zsh "sys-info $arguments >\"\$HOME/out\" 2>/dev/null"
    [ "$status" -eq 2 ]
    [ ! -s "$HOME/out" ]
  done

  run run_zsh "$SYS_INFO_HOST"'
    _sys_tool_available() { [[ "$1" == git ]]; }
    _sys_diag_memory_record() { print -r -- probed > "$HOME/touched"; }
    sys-info --json >"$HOME/out" 2>"$HOME/err"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/out" ]
  [ ! -e "$HOME/touched" ]
  grep -Fq -- '--json requires jq' "$HOME/err"
}

@test "sys diagnostics: sys-health uses launchd without Linux guidance" {
  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os darwin environment native architecture arm64
        package_manager brew service_manager launchd
        process_backend bsd-ps ports_backend lsof privilege sudo
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_diag_disk_record() { printf "/dev/disk3\t100000\t40000\t60000\t40\n"; }
    _sys_diag_inode_percent() { print -r -- "20"; }
    _sys_diag_memory_record() { printf "1000\t700\t0\t0\n"; }
    _sys_diag_zombie_records() { return 0; }
    _sys_diag_failed_service_records() { return 0; }
    _sys_diag_signaled_service_records() { return 0; }
    _sys_diag_oom_event_count() { return 3; }
    _sys_diag_pending_reboot() { return 1; }

    sys-health >"$HOME/health.stdout" 2>"$HOME/health.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/health.stdout" ]
  grep -q "Checking launchd services" "$HOME/health.stderr"
  grep -q "Kernel OOM log: not applicable on this platform" \
    "$HOME/health.stderr"
  ! grep -q "WSL systemd" "$HOME/health.stderr" || false
  grep -q "all available checks passed" "$HOME/health.stderr"
}

@test "sys diagnostics: launchd health counts only failed exits outside Apple jobs" {
  cat <<'EOF' > "$TEST_MOCK_BIN/launchctl"
#!/usr/bin/env bash
[[ "$*" == list ]] || exit 97
printf 'PID\tStatus\tLabel\n'
printf '%s\t%s\t%s\n' \
  - 0 com.example.idle \
  - 78 com.example.failed \
  512 1 com.example.running-after-a-failure \
  - -9 com.example.killed \
  - 3 com.apple.failed \
  - -15 com.apple.terminated
EOF
  chmod +x "$TEST_MOCK_BIN/launchctl"

  local health_setup='
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os darwin environment native architecture arm64
        package_manager brew service_manager launchd
        process_backend bsd-ps ports_backend lsof privilege sudo
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_diag_disk_record() { printf "/dev/disk3s5\t100000\t40000\t60000\t40\n"; }
    _sys_diag_inode_percent() { print -r -- "20"; }
    _sys_diag_memory_record() { printf "1000\t700\t0\t0\n"; }
    _sys_diag_zombie_records() { return 0; }
    _sys_diag_pending_reboot() { return 1; }
  '

  run run_zsh "$health_setup"'
    sys-health 2>&1
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ 1 failed service"* ]]
  [[ "$output" == *"com.example.failed: last-exit=78"* ]]
  [[ "$output" == *"1 job last ended by a signal (advisory, not counted as an issue):"* ]]
  [[ "$output" == *"com.example.killed: signal 9 (SIGKILL)"* ]]
  [[ "$output" != *"com.apple."* ]]
  [[ "$output" != *"com.example.running-after-a-failure"* ]]
  [[ "$output" != *"com.example.idle"* ]]
  [[ "$output" == *"System health: 1 issue found"* ]]
  [[ "$output" != *"(s)"* ]]

  run run_zsh "$health_setup"'
    SYS_HEALTH_INCLUDE_APPLE_JOBS=1 sys-health 2>&1
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ 2 failed services"* ]]
  [[ "$output" == *"com.apple.failed: last-exit=3"* ]]
  [[ "$output" == *"com.apple.terminated: signal 15 (SIGTERM)"* ]]
  [[ "$output" == *"System health: 1 issue found"* ]]
}

@test "sys diagnostics: macOS reports the Data volume and no kernel OOM log" {
  export DATA_VOLUME="$TEST_TEMP_DIR/System/Volumes/Data"
  export DISK_PATHS_LOG="$TEST_TEMP_DIR/disk-paths.log"
  mkdir -p "$DATA_VOLUME"

  # shellcheck disable=SC2016  # Zsh expands this code, not Bash.
  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os darwin environment native architecture arm64
        package_manager brew service_manager launchd
        process_backend bsd-ps ports_backend lsof privilege sudo
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_macos_data_volume_path() { REPLY="$DATA_VOLUME"; }
    _sys_diag_disk_record() {
      print -r -- "disk:$1" >> "$DISK_PATHS_LOG"
      printf "/dev/disk3s5\t100000\t40000\t60000\t40\n"
    }
    _sys_diag_inode_percent() {
      print -r -- "inode:$1" >> "$DISK_PATHS_LOG"
      print -r -- "20"
    }
    _sys_diag_memory_record() { printf "1000\t700\t0\t0\n"; }
    _sys_diag_cpu_record() { printf "8\tApple M2\n"; }
    _sys_diag_runtime_record() { printf "90061\t1.0\t2.0\t3.0\n"; }
    _sys_diag_os_name() { print -r -- "macOS 15.5 (24F74)"; }
    _sys_diag_zombie_records() { return 0; }
    _sys_diag_failed_service_records() { return 0; }
    _sys_diag_signaled_service_records() { return 0; }
    _sys_diag_pending_reboot() { return 1; }
    _sys_diag_render_tool() { return 0; }
    _sys_diag_render_package_records() { return 0; }
    sys-info 2>&1
    sys-health 2>&1
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Disk (Data):"*"(40%)"* ]]
  [[ "$output" != *"Disk (/):"* ]]
  [[ "$output" == *"Data disk at 40%"* ]]
  [[ "$output" == *"⊘ Kernel OOM log: not applicable on this platform"* ]]
  [[ "$output" != *"unavailable without additional access"* ]]
  [ "$(grep -c -- "^disk:$DATA_VOLUME\$" "$DISK_PATHS_LOG")" -eq 2 ]
  grep -Fxq -- "inode:$DATA_VOLUME" "$DISK_PATHS_LOG"
  ! grep -Fxq -- "disk:/" "$DISK_PATHS_LOG" || false
}

@test "sys diagnostics: macOS memory prefers the kernel memorystatus level" {
  export VM_STAT_LOG="$TEST_TEMP_DIR/vm-stat.log"
  cat > "$TEST_MOCK_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-n hw.memsize") echo "17179869184" ;;
  "-n kern.memorystatus_level") echo "${MOCK_MEMORYSTATUS_LEVEL:-37}" ;;
  "-n vm.swapusage") echo "total = 0.00M  used = 0.00M  free = 0.00M" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$TEST_MOCK_BIN/vm_stat" <<'EOF'
#!/usr/bin/env bash
echo vm_stat >> "$VM_STAT_LOG"
echo "Mach Virtual Memory Statistics: (page size of 4096 bytes)"
echo "Pages free:                              10."
echo "Pages inactive:                          20."
echo "Pages speculative:                        5."
EOF
  chmod +x "$TEST_MOCK_BIN/sysctl" "$TEST_MOCK_BIN/vm_stat"

  run run_zsh '_sys_macos_diag_memory_record'

  [ "$status" -eq 0 ]
  [ "$output" = $'17179869184\t6356551598\t0\t0' ]
  [ ! -e "$VM_STAT_LOG" ]

  # An out-of-range level falls back to the page counts.
  export MOCK_MEMORYSTATUS_LEVEL=150
  run run_zsh '_sys_macos_diag_memory_record'

  [ "$status" -eq 0 ]
  [ "$output" = $'17179869184\t143360\t0\t0' ]
  [ "$(cat "$VM_STAT_LOG")" = vm_stat ]
}

@test "sys diagnostics: sys-info skips Command Line Tools placeholders and Windows tools" {
  export CLT_DIR="$TEST_TEMP_DIR/clt"
  export TOOL_RUN_LOG="$TEST_TEMP_DIR/tool-runs.log"
  mkdir -p "$CLT_DIR"
  cat > "$CLT_DIR/git" <<'EOF'
#!/usr/bin/env bash
echo "placeholder git $*" >> "$TOOL_RUN_LOG"
echo "git version 2.39.5 (Apple Git-154)"
EOF
  cat > "$CLT_DIR/python3" <<'EOF'
#!/usr/bin/env bash
echo "placeholder python3 $*" >> "$TOOL_RUN_LOG"
echo "Python 3.9.6"
EOF
  cat > "$TEST_MOCK_BIN/xcode-select" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-p" ]] || exit 97
if [[ -n "${MOCK_DEVELOPER_DIR:-}" ]]; then
  printf '%s\n' "$MOCK_DEVELOPER_DIR"
  exit 0
fi
printf '%s\n' "xcode-select: error: unable to get active developer directory" >&2
exit 2
EOF
  chmod +x "$CLT_DIR/git" "$CLT_DIR/python3" "$TEST_MOCK_BIN/xcode-select"

  # shellcheck disable=SC2016  # Zsh expands this code, not Bash.
  local info_setup='
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os darwin environment native architecture arm64
        package_manager brew service_manager launchd
        process_backend bsd-ps ports_backend lsof privilege sudo
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_macos_clt_stub_dir() { REPLY="$CLT_DIR"; }
    _sys_diag_os_name() { print -r -- "macOS 15.5 (24F74)"; }
    _sys_diag_memory_record() { printf "1000\t700\t0\t0\n"; }
    _sys_diag_cpu_record() { printf "8\tApple M2\n"; }
    _sys_diag_runtime_record() { printf "90061\t1.0\t2.0\t3.0\n"; }
    _sys_diag_disk_record() { printf "/dev/disk3s5\t100000\t40000\t60000\t40\n"; }
    _sys_diag_render_package_records() { return 0; }
    unset ZSH
    PATH="$CLT_DIR:$TEST_MOCK_BIN:/usr/bin:/bin"
  '

  run run_zsh "$info_setup"'sys-info 2>&1'

  [ "$status" -eq 0 ]
  [[ "$output" != *"Git:"* ]]
  [[ "$output" != *"Python:"* ]]
  [ ! -e "$TOOL_RUN_LOG" ]

  export MOCK_DEVELOPER_DIR="$TEST_TEMP_DIR"
  run run_zsh "$info_setup"'sys-info 2>&1'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Git:"*"2.39.5"* ]]
  [[ "$output" == *"Python:"*"3.9.6"* ]]

  # On WSL a tool that resolves to a Windows drive is not this host's tool.
  : > "$TOOL_RUN_LOG"
  export WINDOWS_BIN="$TEST_TEMP_DIR/mnt/c/Program Files/Tools"
  mkdir -p "$WINDOWS_BIN"
  local windows_tool
  for windows_tool in gcloud npm docker; do
    # shellcheck disable=SC2016  # Zsh expands this code, not Bash.
    printf '#!/usr/bin/env bash\necho "windows %s $*" >> "$TOOL_RUN_LOG"\necho "%s 1.0.0"\n' \
      "$windows_tool" "$windows_tool" > "$WINDOWS_BIN/$windows_tool"
    chmod 777 "$WINDOWS_BIN/$windows_tool"
    rm -f "${TEST_MOCK_BIN:?}/${windows_tool:?}"
  done
  # shellcheck disable=SC2016  # Zsh expands this code, not Bash.
  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os linux environment wsl architecture x86_64
        package_manager apt service_manager unavailable
        process_backend procps ports_backend ss privilege sudo
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_wsl_drive_root() { REPLY="$TEST_TEMP_DIR/mnt"; }
    _sys_diag_os_name() { print -r -- "Test Linux"; }
    _sys_diag_memory_record() { printf "1000\t700\t0\t0\n"; }
    _sys_diag_cpu_record() { printf "8\tTest CPU\n"; }
    _sys_diag_runtime_record() { printf "90061\t1.0\t2.0\t3.0\n"; }
    _sys_diag_disk_record() { printf "/dev/sdc\t100000\t40000\t60000\t40\n"; }
    _sys_diag_package_records() { return 3; }
    unset ZSH
    PATH="$TEST_MOCK_BIN:$WINDOWS_BIN:/usr/bin:/bin"
    sys-info 2>&1
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"gcloud:"* ]]
  [[ "$output" != *"Docker:"* ]]
  [[ "$output" != *"NPM global:"* ]]
  [ ! -s "$TOOL_RUN_LOG" ]
}

@test "sys diagnostics: sys-health reports every simulated issue and stays read-only" {
  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os linux environment native architecture x86_64
        package_manager apt service_manager systemd
        process_backend procps ports_backend ss privilege sudo
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_diag_disk_record() { printf "/dev/root\t100000\t91000\t9000\t91\n"; }
    _sys_diag_inode_percent() { print -r -- "85"; }
    _sys_diag_memory_record() { printf "100\t5\t100\t10\n"; }
    _sys_diag_zombie_records() { printf "123\tzombie-test\n"; }
    _sys_diag_failed_service_records() { printf "broken.service\tfailed/failed\n"; }
    _sys_diag_oom_event_count() { print -r -- "2"; }
    _sys_diag_journal_size() { print -r -- "50M"; }
    _sys_diag_pending_reboot() { print -r -- "kernel-test"; return 0; }

    sys-health >"$HOME/health.stdout" 2>"$HOME/health.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/health.stdout" ]
  grep -q "System health: 8 issues found" "$HOME/health.stderr"
  grep -q "1 zombie process found" "$HOME/health.stderr"
  grep -q "1 failed service" "$HOME/health.stderr"
  grep -q "2 OOM events in the available kernel log" "$HOME/health.stderr"
  ! grep -q "(s)\|(es)" "$HOME/health.stderr" || false
  grep -q "broken.service" "$HOME/health.stderr"
  grep -q "kernel-test" "$HOME/health.stderr"
}

@test "sys diagnostics: impossible and oversized memory records fail closed" {
  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os linux environment native architecture x86_64
        package_manager unavailable service_manager unavailable
        process_backend unavailable ports_backend unavailable privilege sudo
        snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_diag_disk_record() { printf "/dev/root\t100\t50\t50\t50\n"; }
    _sys_diag_inode_percent() {
      print -r -- "999999999999999999999999"
    }
    _sys_diag_memory_record() {
      printf "100\t200\t100\t200\n"
    }
    _sys_diag_zombie_records() { return 3; }
    _sys_diag_oom_event_count() { return 3; }
    _sys_diag_pending_reboot() { return 1; }

    sys-health >"$HOME/health.stdout" 2>"$HOME/health.stderr"
    _sys_diag_usage_percent 100000000000000000 1 \
      >"$HOME/percentage"
    _sys_diag_format_bytes 999999999999999999999999 \
      >"$HOME/bytes"
    local format_rc=$?
    [[ "$(<"$HOME/percentage")" == "100" && "$format_rc" -eq 2 ]]
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/health.stdout" ]
  grep -q "Memory usage unavailable" "$HOME/health.stderr"
  grep -q "Swap usage unavailable" "$HOME/health.stderr"
  grep -q "Inode usage unavailable" "$HOME/health.stderr"
  ! grep -q -- "-[0-9][0-9]*%" "$HOME/health.stderr" || false
  [ "$(cat "$HOME/bytes")" = "unknown" ]
}

@test "sys diagnostics: startup benchmark uses portable measurements and stderr UI" {
  run run_zsh '
    _sys_diag_measure_startup_once() { print -r -- "125"; }
    _sys_diag_profile_startup() { return 3; }
    _sys_diag_render_startup_hints() { return 0; }

    sys-startup >"$HOME/startup.stdout" 2>"$HOME/startup.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/startup.stdout" ]
  grep -q "125ms" "$HOME/startup.stderr"
  grep -q "10/10" "$HOME/startup.stderr"
  grep -q "external side effects" "$HOME/startup.stderr"
}

@test "sys diagnostics: startup measurement returns real numeric milliseconds" {
  run run_zsh '
    local measured_ms
    local -i measure_rc
    measured_ms=$(_sys_diag_measure_startup_once)
    measure_rc=$?
    (( measure_rc == 0 )) || {
      print -r -- "measurement returned status $measure_rc"
      return 1
    }
    [[ "$measured_ms" =~ ^[0-9]+$ ]] || {
      print -r -- "measurement was not numeric: $measured_ms"
      return 2
    }
    print -r -- "$measured_ms"
  '

  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "sys diagnostics: startup measurement rejects a regressing fallback clock" {
  run run_zsh '
    local -i clock_call=0
    _sys_diag_clock_seconds() {
      (( clock_call++ ))
      if (( clock_call == 1 )); then
        REPLY="10.5"
      else
        REPLY="9.5"
      fi
      return 0
    }
    _sys_run_with_timeout() { return 0; }

    _sys_diag_measure_startup_once
  '

  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "sys diagnostics: startup measurement preserves the timeout status" {
  run run_zsh '
    local -i clock_calls=0
    _sys_diag_clock_seconds() {
      (( clock_calls++ ))
      REPLY="10.5"
      (( clock_calls == 1 ))
    }
    _sys_run_with_timeout() { return 124; }

    _sys_diag_measure_startup_once
  '

  [ "$status" -eq 124 ]
  [ -z "$output" ]
}

@test "sys diagnostics: zprof runs in an isolated explicit zshrc subprocess" {
  cat > "$HOME/.zshrc" <<'EOF'
phase2-profile-work() {
  local value
  for value in {1..1000}; do
    :
  done
}
phase2-profile-work
EOF

  run run_zsh '_sys_diag_profile_startup'

  [ "$status" -eq 0 ]
  [[ "$output" == *"phase2-profile-work"* ]]
}

@test "sys diagnostics: startup returns failure when every sample times out" {
  run run_zsh '
    _sys_diag_measure_startup_once() { return 124; }
    sys-startup >"$HOME/startup.stdout" 2>"$HOME/startup.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -s "$HOME/startup.stdout" ]
  grep -q "Unable to complete any startup measurements" "$HOME/startup.stderr"
}

@test "sys diagnostics: native timeout fallback terminates a slow probe" {
  run run_zsh '
    TMPDIR="$HOME/timeouts"
    mkdir -p "$TMPDIR"
    command() {
      if [[ "$1" == "-v" && ( "$2" == "timeout" || "$2" == "gtimeout" ) ]]; then
        return 1
      fi
      builtin command "$@"
    }

    _sys_run_with_timeout 1 zsh -c "sleep 5"
    local timeout_rc=$?
    local -a marker_files=("$TMPDIR"/zdx-timeout.*(N))
    (( ${#marker_files} == 0 )) || return 99
    return $timeout_rc
  '

  [ "$status" -eq 124 ]
}

@test "sys diagnostics: native timeout fallback terminates descendants" {
  run run_zsh '
    TMPDIR="$HOME/timeouts"
    mkdir -p "$TMPDIR"
    command() {
      if [[ "$1" == "-v" && ( "$2" == "timeout" || "$2" == "gtimeout" ) ]]; then
        return 1
      fi
      builtin command "$@"
    }

    _sys_run_with_timeout 1 zsh -c \
      "sleep 20 & print -r -- \$! > '$HOME/descendant.pid'; wait"
    local timeout_rc=$?
    local descendant_pid
    descendant_pid=$(<"$HOME/descendant.pid") || return 98
    if builtin kill -0 "$descendant_pid" 2>/dev/null; then
      builtin kill -KILL "$descendant_pid" 2>/dev/null
      return 99
    fi
    return $timeout_rc
  '

  [ "$status" -eq 124 ]
}

@test "sys diagnostics: telemetry parser skips malformed and unsafe records" {
  mkdir -p "$HOME/.config/zdx"
  cat > "$HOME/.config/zdx/telemetry.json" <<'EOF'
{"suite": "sys", "command": "valid-command", "duration_ms": 25, "exit_code": 0, "timestamp": "2026-07-11T12:00:00Z"}
{"suite": "sys|evil", "command": "bad", "duration_ms": 1, "exit_code": 0, "timestamp": "2026-07-11T12:00:01Z"}
{"suite": "sys", "command": "bad command", "duration_ms": 1, "exit_code": 0, "timestamp": "2026-07-11T12:00:02Z"}
{"suite": "sys"
EOF

  run run_zsh '
    _sys_telemetry_records "$HOME/.config/zdx/telemetry.json" \
      >"$HOME/records.stdout" 2>"$HOME/records.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/records.stderr" ]
  [ "$(cat "$HOME/records.stdout")" = $'2026-07-11T12:00:00Z\tsys\tvalid-command\t25\t0' ]
}

@test "sys diagnostics: telemetry dashboard keeps UI off stdout" {
  mkdir -p "$HOME/.config/zdx"
  cat > "$HOME/.config/zdx/telemetry.json" <<'EOF'
{"suite": "sys", "command": "one", "duration_ms": 10, "exit_code": 0, "timestamp": "2026-07-11T12:00:00Z"}
{"suite": "vpn", "command": "two", "duration_ms": 20, "exit_code": 1, "timestamp": "2026-07-11T12:00:01Z"}
malformed final record
EOF

  run run_zsh '
    sys-telemetry --dashboard \
      >"$HOME/dashboard.stdout" 2>"$HOME/dashboard.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/dashboard.stdout" ]
  grep -q "SUMMARY STATISTICS" "$HOME/dashboard.stderr"
  grep -q "Total Runs:.*2" "$HOME/dashboard.stderr"
  grep -q "Successful:.*1" "$HOME/dashboard.stderr"
  grep -q "Failed:.*1" "$HOME/dashboard.stderr"
}

@test "sys diagnostics: telemetry reader rejects symbolic links" {
  mkdir -p "$HOME/.config/zdx"
  printf '%s\n' '{"suite":"sys"}' > "$HOME/telemetry-target"
  ln -s "$HOME/telemetry-target" "$HOME/.config/zdx/telemetry.json"

  run run_zsh '
    sys-telemetry --dashboard \
      >"$HOME/dashboard.stdout" 2>"$HOME/dashboard.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -s "$HOME/dashboard.stdout" ]
  grep -q "user-owned regular file" "$HOME/dashboard.stderr"
}

@test "sys diagnostics: telemetry reader enforces its configured size bound" {
  mkdir -p "$HOME/.config/zdx"
  printf '%s\n' \
    '{"suite":"sys","command":"one","duration_ms":1,"exit_code":0,"timestamp":"2026-07-11T12:00:00Z"}' \
    > "$HOME/.config/zdx/telemetry.json"

  run run_zsh '
    SYS_TELEMETRY_MAX_READ_BYTES=10
    sys-telemetry --dashboard \
      >"$HOME/dashboard.stdout" 2>"$HOME/dashboard.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -s "$HOME/dashboard.stdout" ]
  grep -q "exceeds the configured read limit" "$HOME/dashboard.stderr"
}

@test "sys diagnostics: telemetry browser never passes raw JSON to fzf" {
  mkdir -p "$HOME/.config/zdx"
  printf '%s\n' \
    '{"suite":"sys","command":"safe","duration_ms":5,"exit_code":0,"timestamp":"2026-07-11T12:00:00Z","secret":"do-not-copy"}' \
    > "$HOME/.config/zdx/telemetry.json"

  run run_zsh '
    fzf() {
      command cat >"$HOME/fzf-input"
      return 130
    }
    sys-telemetry --browse \
      >"$HOME/browser.stdout" 2>"$HOME/browser.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/browser.stdout" ]
  grep -q $'\tsys\tsafe\t5\t0' "$HOME/fzf-input"
  ! grep -q '{' "$HOME/fzf-input" || false
  ! grep -q 'do-not-copy' "$HOME/fzf-input" || false
}

@test "sys diagnostics: public commands reject unknown options with status 2" {
  run run_zsh 'sys-info --unknown'
  [ "$status" -eq 2 ]

  run run_zsh 'sys-health --unknown'
  [ "$status" -eq 2 ]

  run run_zsh 'sys-startup --unknown'
  [ "$status" -eq 2 ]

  run run_zsh 'sys-telemetry --unknown'
  [ "$status" -eq 2 ]
}

@test "sys diagnostics: Homebrew package counts work through GNU timeout" {
  command -v timeout >/dev/null 2>&1 || skip "GNU timeout is unavailable"
  cat <<'MOCK' > "$TEST_MOCK_BIN/brew"
#!/usr/bin/env bash
[[ "${HOMEBREW_NO_ANALYTICS:-}" == 1 && "${HOMEBREW_CURL_RETRIES:-}" == 0 ]] \
  || exit 97
case "$*" in
  "list --formula") printf '%s\n' git jq zsh ;;
  "list --cask") printf '%s\n' iterm2 ;;
  *) exit 98 ;;
esac
MOCK
  chmod +x "$TEST_MOCK_BIN/brew"

  run run_zsh '
    _sys_linux_diag_package_records brew || exit 11
    _sys_macos_diag_package_records brew
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *$'Brew formulae\t3'* ]]
  [[ "$output" == *$'Brew casks\t1'* ]]
}

@test "sys diagnostics: startup hints count single-line and multi-line plugin arrays" {
  printf '%s\n' '# plugins=(a b c d e f g h i j k l m n o p)' 'plugins=(git)' \
    '' 'foo() {' '}' > "$HOME/.zshrc"

  run run_zsh '_sys_diag_render_startup_hints'

  [ "$status" -eq 0 ]
  [[ "$output" == *"1 Oh My Zsh plugins detected"* ]]
  [[ "$output" != *"consider reducing"* ]]

  printf '%s\n' 'plugins=(' '  git # vcs' '  docker' '  fzf' ')' ')' \
    > "$HOME/.zshrc"
  run run_zsh '_sys_diag_render_startup_hints'

  [ "$status" -eq 0 ]
  [[ "$output" == *"3 Oh My Zsh plugins detected"* ]]
}
