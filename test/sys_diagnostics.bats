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
        fonts_backend fontconfig snapd unavailable wsl_interop available
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

@test "sys diagnostics: sys-health uses launchd without Linux guidance" {
  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os darwin environment native architecture arm64
        package_manager brew service_manager launchd
        process_backend bsd-ps ports_backend lsof privilege sudo
        fonts_backend macos-user-fonts snapd unavailable wsl_interop unavailable
      )
      _SYS_CAPABILITIES_READY=1
    }
    _sys_diag_disk_record() { printf "/dev/disk3\t100000\t40000\t60000\t40\n"; }
    _sys_diag_inode_percent() { print -r -- "20"; }
    _sys_diag_memory_record() { printf "1000\t700\t0\t0\n"; }
    _sys_diag_zombie_records() { return 0; }
    _sys_diag_failed_service_records() { return 0; }
    _sys_diag_oom_event_count() { return 3; }
    _sys_diag_pending_reboot() { return 1; }

    sys-health >"$HOME/health.stdout" 2>"$HOME/health.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/health.stdout" ]
  grep -q "Checking launchd services" "$HOME/health.stderr"
  ! grep -q "WSL systemd" "$HOME/health.stderr"
  grep -q "all available checks passed" "$HOME/health.stderr"
}

@test "sys diagnostics: sys-health reports every simulated issue and stays read-only" {
  run run_zsh '
    _sys_capabilities_refresh() {
      _SYS_CAPABILITIES=(
        os linux environment native architecture x86_64
        package_manager apt service_manager systemd
        process_backend procps ports_backend ss privilege sudo
        fonts_backend fontconfig snapd unavailable wsl_interop unavailable
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
  grep -q "8 issue(s) found" "$HOME/health.stderr"
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
        fonts_backend unavailable snapd unavailable wsl_interop unavailable
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
  ! grep -q -- "-[0-9][0-9]*%" "$HOME/health.stderr"
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

@test "sys diagnostics: PATH inspection never mutates zshrc or prompts" {
  printf '%s\n' 'export PHASE2_SENTINEL=unchanged' > "$HOME/.zshrc"
  local original_zshrc
  original_zshrc=$(cat "$HOME/.zshrc")

  run run_zsh '
    _sys_confirm() {
      print -r -- "unexpected prompt" >"$HOME/confirm-called"
      return 0
    }
    PATH="/bin:$HOME/missing:/bin::/usr/bin"
    sys-path >"$HOME/path.stdout" 2>"$HOME/path.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/path.stdout" ]
  [ ! -e "$HOME/confirm-called" ]
  [ "$(cat "$HOME/.zshrc")" = "$original_zshrc" ]
  grep -q "duplicate" "$HOME/path.stderr"
  grep -q "missing" "$HOME/path.stderr"
  grep -q "current directory" "$HOME/path.stderr"
}

@test "sys diagnostics: symbol list mode emits names-only TSV data" {
  run run_zsh '
    alias phase2alias="print safe"
    phase2function() { return 0; }
    _phase2private() { return 0; }

    sys-aliases --list all >"$HOME/symbols.stdout" 2>"$HOME/symbols.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/symbols.stderr" ]
  grep -Fxq $'alias\tphase2alias' "$HOME/symbols.stdout"
  grep -Fxq $'function\tphase2function' "$HOME/symbols.stdout"
  ! grep -q '_phase2private' "$HOME/symbols.stdout"
  awk -F '\t' 'NF != 2 { exit 1 }' "$HOME/symbols.stdout"
}

@test "sys diagnostics: sensitive symbol definitions are not rendered" {
  run run_zsh '
    alias "api-token=print super-secret-value"
    fzf() {
      command awk -F "\t" '\''$2 == "api-token" { print; exit }'\''
    }

    sys-aliases aliases >"$HOME/alias.stdout" 2>"$HOME/alias.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/alias.stdout" ]
  grep -q "Definition hidden" "$HOME/alias.stderr"
  ! grep -q "super-secret-value" "$HOME/alias.stderr"
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
  ! grep -q '{' "$HOME/fzf-input"
  ! grep -q 'do-not-copy' "$HOME/fzf-input"
}

@test "sys diagnostics: public commands reject unknown options with status 2" {
  run run_zsh 'sys-info --unknown'
  [ "$status" -eq 2 ]

  run run_zsh 'sys-health --unknown'
  [ "$status" -eq 2 ]

  run run_zsh 'sys-startup --unknown'
  [ "$status" -eq 2 ]

  run run_zsh 'sys-path --unknown'
  [ "$status" -eq 2 ]

  run run_zsh 'sys-aliases --unknown'
  [ "$status" -eq 2 ]

  run run_zsh 'sys-telemetry --unknown'
  [ "$status" -eq 2 ]
}
