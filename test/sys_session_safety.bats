#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  cat > "$TEST_MOCK_BIN/ss" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'tcp LISTEN 0 511 127.0.0.1:3000 0.0.0.0:* users:(("node",pid=4242,fd=3))'
MOCK
  cat > "$TEST_MOCK_BIN/ps" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '4242 1000 1.5 0.2 node'
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/ss" "$TEST_MOCK_BIN/ps"
  mkdir -m 700 "$HOME/locks" "$HOME/.config" "$HOME/.config/zdx"
  printf '%s\n' \
    '{"suite":"sys","command":"sys-info","duration_ms":10,"exit_code":0,"timestamp":"2026-10-25T10:00:00Z"}' \
    > "$HOME/.config/zdx/telemetry.json"
  chmod -- 600 "$HOME/.config/zdx/telemetry.json"
  cat > "$HOME/session-probes.zsh" <<'ZSH'
_sys_capability_value() {
  case "$1" in
    ports_backend) print -r -- ss ;;
    processes_backend) print -r -- procps ;;
    *) return 91 ;;
  esac
}
_sys_processes_backend() { print -r -- procps; }
_session_regex_probe() {
  local selected="$1"
  case "$selected" in
    capture) _sys_capture_max_bytes ;;
    milliseconds) _sys_telemetry_format_ms 1000 ;;
    log) _sys_telemetry_validate_log "$HOME/.config/zdx/telemetry.json" ;;
    service) _sys_services_validate_id systemd demo.service ;;
    keepalive) _sys_update_stop_sudo_keepalive zdx-sudo-keepalive-999999-1000000-1-1 ;;
    wsl-secret) _sys_wsl_value_sensitive https://user:canary@example.invalid ;;
    wsl-mtu) _sys_wsl_boot_mtu_pin 'ip link set dev eth0 mtu 1392' ;;
    wsl-compaction) _sys_wsl_compaction_steps Ubuntu ;;
  esac
}
ZSH
}

teardown() {
  cleanup_sandbox
}

@test "sys session safety: public commands and dispatcher isolate options at entry" {
  run run_zsh '
    local command_name="" module risk capability body
    local -a owned=(sys-menu _sys_dispatch)
    while IFS=$'"'"'\t'"'"' read -r command_name module risk capability; do
      [[ "$command_name" == \#* || -z "$command_name" ]] && continue
      owned+=("$command_name")
    done < "$ZSH_CUSTOM/test/fixtures/sys-public-commands.tsv"
    (( ${#owned} == 27 )) || exit 80
    for command_name in "${owned[@]}"; do
      body="${functions[$command_name]}"
      [[ "${${(f)body}[1]}" == *"emulate -L zsh"* ]] \
        || { print -r -- "$command_name lacks entry option isolation"; exit 81; }
    done
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "sys session safety: caller array and splitting options preserve resource records" {
  run run_zsh '
    source "$HOME/session-probes.zsh" || exit 80
    setopt KSH_ARRAYS SH_WORD_SPLIT
    sys-ports --list >"$HOME/ports.stdout" 2>"$HOME/ports.stderr" || exit 81
    [[ -o KSH_ARRAYS && -o SH_WORD_SPLIT ]] || exit 82
    sys-processes --list >"$HOME/processes.stdout" 2>"$HOME/processes.stderr" || exit 83
    [[ -o KSH_ARRAYS && -o SH_WORD_SPLIT ]] || exit 84
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  grep -Fxq $'port\ttcp\t3000\t127.0.0.1\t4242\tnode' "$HOME/ports.stdout"
  grep -Fxq $'process\t4242\t1000\t1.5\t0.2\tnode' "$HOME/processes.stdout"
  [ ! -s "$HOME/ports.stderr" ]
  [ ! -s "$HOME/processes.stderr" ]
}

@test "sys session safety: nested resource routing keeps records and caller options" {
  run run_zsh '
    source "$HOME/session-probes.zsh" || exit 80
    _sys_dispatch_prepare() { return 0; }
    setopt KSH_ARRAYS SH_WORD_SPLIT
    sys-menu sys-processes --list >"$HOME/nested.stdout" 2>"$HOME/nested.stderr"
    local rc=$?
    [[ -o KSH_ARRAYS && -o SH_WORD_SPLIT ]] || exit 81
    (( rc == 0 )) || exit 82
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  grep -Fxq $'process\t4242\t1000\t1.5\t0.2\tnode' "$HOME/nested.stdout"
}

@test "sys session safety: helpers leave seeded regex state unchanged" {
  run run_zsh '
    source "$HOME/session-probes.zsh" || exit 80
    local selected="" rc=0 failures=0
    for selected in capture milliseconds log service keepalive wsl-secret wsl-mtu wsl-compaction; do
      MATCH=sentinel MBEGIN=71 MEND=79
      match=(first second) mbegin=(11 21) mend=(15 25)
      _session_regex_probe "$selected" >/dev/null 2>/dev/null
      rc=$?
      if (( rc != 0 )); then
        [[ "$selected" == keepalive && "$rc" == 2 ]] || exit 81
      fi
      if [[ "$MATCH:$MBEGIN:$MEND" != sentinel:71:79 \
        || "${(j:,:)match}" != first,second \
        || "${(j:,:)mbegin}" != 11,21 || "${(j:,:)mend}" != 15,25 ]]; then
        print -r -- "$selected changed seeded regex state"
        (( ++failures ))
      fi
    done
    (( failures == 0 )) || exit 82
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "sys session safety: helpers preserve initially unset regex parameters" {
  run run_zsh '
    source "$HOME/session-probes.zsh" || exit 80
    local selected="" rc=0 failures=0
    for selected in capture milliseconds log service keepalive wsl-secret wsl-mtu wsl-compaction; do
      unset MATCH MBEGIN MEND match mbegin mend
      _session_regex_probe "$selected" >/dev/null 2>/dev/null
      rc=$?
      if (( rc != 0 )); then
        [[ "$selected" == keepalive && "$rc" == 2 ]] || exit 81
      fi
      if [[ "${+MATCH}${+MBEGIN}${+MEND}${+match}${+mbegin}${+mend}" != 000000 ]]; then
        print -r -- "$selected created regex state"
        (( ++failures ))
      fi
    done
    (( failures == 0 )) || exit 82
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "sys session safety: telemetry dashboard leaves regex state unset" {
  run run_zsh '
    unset MATCH MBEGIN MEND match mbegin mend
    sys-telemetry --dashboard >"$HOME/dashboard.stdout" 2>"$HOME/dashboard.stderr" \
      || exit 80
    [[ "${+MATCH}${+MBEGIN}${+MEND}${+match}${+mbegin}${+mend}" == 000000 ]] \
      || exit 81
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/dashboard.stdout" ]
  grep -Fq sys-info "$HOME/dashboard.stderr"
}

@test "sys session safety: failed lock unlock fallback preserves stderr and clears ownership" {
  run run_zsh '
    {
    _sys_update_acquire_lock "$HOME/locks/update.lock" || exit 80
    local owned_fd="$REPLY"
    zsystem() {
      if [[ "$1" == flock && "$2" == -u ]]; then return 1; fi
      builtin zsystem "$@"
    }
    _sys_update_release_lock "$owned_fd" || exit 81
    print -u2 -r -- AFTER-RELEASE-STDERR
    [[ "$_SYS_UPDATE_LOCK_HELD" == 0 && -z "$_SYS_UPDATE_LOCK_HELD_FD" ]] || exit 82
    zmodload -F zsh/stat b:zstat || exit 83
    local -A state=()
    zstat -H state -f "$owned_fd" 2>/dev/null && exit 84
    print -r -- released
    } >"$HOME/release.stdout" 2>"$HOME/release.stderr"
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -Fxq AFTER-RELEASE-STDERR "$HOME/release.stderr"
  [ "$(cat "$HOME/release.stdout")" = released ]
}
