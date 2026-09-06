#!/usr/bin/env bats

setup() {
  load test_helper

  export RESOURCE_LOG="$TEST_TEMP_DIR/resources.log"
  export FZF_LOG="$TEST_TEMP_DIR/fzf.log"
  export PS_START_COUNT_FILE="$TEST_TEMP_DIR/ps-start-count"
  export LSOF_COUNT_FILE="$TEST_TEMP_DIR/lsof-count"
  export SYSTEMCTL_COUNT_FILE="$TEST_TEMP_DIR/systemctl-count"
  export LAUNCHCTL_COUNT_FILE="$TEST_TEMP_DIR/launchctl-count"
  export SUDO_AUTH_MARKER="$TEST_TEMP_DIR/sudo-authenticated"
  export MOCK_PROCESS_UID
  MOCK_PROCESS_UID="$(id -u)"
  : > "$RESOURCE_LOG"
  : > "$FZF_LOG"

  cat <<'EOF' > "$TEST_MOCK_BIN/ps"
#!/usr/bin/env bash
set -u

args=" $* "
if [[ "$args" == *" -eo "* ]]; then
  printf '%s\n' \
    "4242 ${MOCK_PROCESS_UID} 1.5 0.2 node" \
    "4343 ${MOCK_PROCESS_UID} 0.5 0.1 worker"
  exit 0
fi
if [[ "$args" == *" -axo "* ]]; then
  printf '%s\n' \
    "4242 ${MOCK_PROCESS_UID} 1.5 0.2 node" \
    "4343 ${MOCK_PROCESS_UID} 0.5 0.1 worker"
  exit 0
fi
if [[ "$args" != *" -p "* || "${MOCK_PROCESS_MISSING:-0}" == "1" ]]; then
  exit 1
fi

case "$args" in
  *" -o uid="*)
    printf '%s\n' "${MOCK_PROCESS_UID}"
    ;;
  *" -o comm="*)
    printf '%s\n' "${MOCK_PROCESS_COMMAND:-node}"
    ;;
  *" -o lstart="*)
    count=0
    [[ -f "$PS_START_COUNT_FILE" ]] && count=$(<"$PS_START_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" > "$PS_START_COUNT_FILE"
    if [[ "${MOCK_PS_CHANGE_AFTER_SUDO_AUTH:-0}" == "1" \
      && -e "$SUDO_AUTH_MARKER" ]]; then
      printf '%s\n' 'Fri Jul 24 12:00:01 2026'
    elif [[ "${MOCK_PS_CHANGE_AFTER_FINGERPRINT:-0}" == "1" \
      && "$count" -gt 2 ]]; then
      printf '%s\n' 'Fri Jul 24 12:00:01 2026'
    else
      printf '%s\n' 'Fri Jul 24 12:00:00 2026'
    fi
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/ps"

  cat <<'EOF' > "$TEST_MOCK_BIN/lsof"
#!/usr/bin/env bash
set -u

if [[ " $* " == *" -iUDP "* ]]; then
  exit 1
fi
if [[ " $* " != *" -iTCP "* ]]; then
  exit 1
fi

count=0
[[ -f "$LSOF_COUNT_FILE" ]] && count=$(<"$LSOF_COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" > "$LSOF_COUNT_FILE"

pid=4242
if [[ "${MOCK_LSOF_CHANGE_AFTER_SCAN:-0}" == "1" && "$count" -gt 1 ]]; then
  pid=4343
fi
printf 'p%s\ncnode\nPTCP\nn127.0.0.1:3000\n' "$pid"
if [[ "${MOCK_LSOF_MULTIPLE:-0}" == "1" ]]; then
  printf 'p4343\ncworker\nPTCP\nn127.0.0.1:3000\n'
fi
EOF
  chmod +x "$TEST_MOCK_BIN/lsof"

  cat <<'EOF' > "$TEST_MOCK_BIN/ss"
#!/usr/bin/env bash
if [[ "${MOCK_SS_MULTIPLE:-0}" == "1" ]]; then
  printf '%s\n' \
    'tcp LISTEN 0 511 127.0.0.1:3000 0.0.0.0:* users:(("a",pid=111,fd=3),("b",pid=222,fd=4))'
  exit 0
fi
printf '%s\n' \
  'tcp LISTEN 0 511 127.0.0.1:3000 0.0.0.0:* users:(("node",pid=4242,fd=3))' \
  'udp UNCONN 0 0 127.0.0.1:5353 0.0.0.0:* users:(("mdns",pid=4343,fd=4))'
EOF
  chmod +x "$TEST_MOCK_BIN/ss"

  cat <<'EOF' > "$TEST_MOCK_BIN/systemctl"
#!/usr/bin/env bash
set -u

case "${1:-}" in
  list-units)
    printf '%s\n' \
      'demo.service loaded active running Demo service' \
      'idle.service loaded inactive dead Idle service'
    exit 0
    ;;
  show)
    count=0
    [[ -f "$SYSTEMCTL_COUNT_FILE" ]] && count=$(<"$SYSTEMCTL_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" > "$SYSTEMCTL_COUNT_FILE"
    active=active
    sub=running
    if [[ "${MOCK_SYSTEMD_CHANGE_AFTER_SUDO_AUTH:-0}" == "1" \
      && -e "$SUDO_AUTH_MARKER" ]]; then
      active=inactive
      sub=dead
    elif [[ "${MOCK_SYSTEMD_STATE_CHANGE:-0}" == "1" && "$count" -gt 1 ]]; then
      active=inactive
      sub=dead
    fi
    printf 'LoadState=loaded\nActiveState=%s\nSubState=%s\nUnitFileState=enabled\n' \
      "$active" "$sub"
    exit 0
    ;;
esac

printf 'systemctl %s\n' "$*" >> "$RESOURCE_LOG"
[[ "${MOCK_SYSTEMCTL_FAIL:-0}" != "1" ]]
EOF
  chmod +x "$TEST_MOCK_BIN/systemctl"

  cat <<'EOF' > "$TEST_MOCK_BIN/launchctl"
#!/usr/bin/env bash
set -u

if [[ "${1:-}" == "list" ]]; then
  count=0
  [[ -f "$LAUNCHCTL_COUNT_FILE" ]] && count=$(<"$LAUNCHCTL_COUNT_FILE")
  count=$((count + 1))
  printf '%s\n' "$count" > "$LAUNCHCTL_COUNT_FILE"
  pid=777
  if [[ "${MOCK_LAUNCHD_STATE_CHANGE:-0}" == "1" && "$count" -gt 1 ]]; then
    pid=778
  fi
  printf 'PID Status Label\n%s 0 com.example.demo\n' "$pid"
  exit 0
fi
if [[ "${1:-}" == "print" ]]; then
  [[ "${2:-}" == gui/* ]]
  exit $?
fi

printf 'launchctl %s\n' "$*" >> "$RESOURCE_LOG"
[[ "${MOCK_LAUNCHCTL_FAIL:-0}" != "1" ]]
EOF
  chmod +x "$TEST_MOCK_BIN/launchctl"

cat <<'EOF' > "$TEST_MOCK_BIN/sudo"
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$RESOURCE_LOG"
if [[ "${1:-}" == "-v" ]]; then
  : > "$SUDO_AUTH_MARKER"
fi
[[ "${MOCK_SUDO_FAIL:-0}" != "1" ]]
EOF
  chmod +x "$TEST_MOCK_BIN/sudo"

  cat <<'EOF' > "$TEST_MOCK_BIN/fzf"
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FZF_LOG"
input=$(cat)
if [[ "${MOCK_FZF_CANCEL:-0}" == "1" ]]; then
  exit 130
fi
selected=$(printf '%s\n' "$input" | head -n 1)
printf '%s\n' "${MOCK_FZF_KEY:-}"
printf '%s\n' "$selected"
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"
}

teardown() {
  cleanup_sandbox
}

run_resources_zsh() {
  local command_text="$1"
  local ports_backend="${2:-lsof}"
  local service_backend="${3:-systemd}"
  local process_backend="${4:-procps}"
  local privilege_backend="${5:-sudo}"

  run_zsh "
    _SYS_CAPABILITIES=(
      architecture x86_64
      environment native
      fonts_backend unavailable
      os linux
      package_manager unavailable
      ports_backend '$ports_backend'
      privilege '$privilege_backend'
      process_backend '$process_backend'
      service_manager '$service_backend'
      snapd unavailable
      wsl_interop unavailable
    )
    _SYS_CAPABILITIES_READY=1
    kill() {
      print -r -- \"\$*\" >> \"\$RESOURCE_LOG\"
      return \${MOCK_KILL_FAIL:-0}
    }
    $command_text
  "
}

@test "sys resources: help is stderr-only and unknown options return 2" {
  local command_name
  for command_name in sys-ports sys-processes sys-services; do
    run run_resources_zsh \
      "$command_name --help >'$TEST_TEMP_DIR/stdout' 2>'$TEST_TEMP_DIR/stderr'"
    [ "$status" -eq 0 ]
    [ ! -s "$TEST_TEMP_DIR/stdout" ]
    grep -q 'Usage:' "$TEST_TEMP_DIR/stderr"

    run run_resources_zsh "$command_name --unknown"
    [ "$status" -eq 2 ]
  done

  run run_resources_zsh "sys-processes --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--kill <PID>"*"(compatibility alias)"* ]]
}

@test "sys resources: missing mutation arguments return 2" {
  run run_resources_zsh "sys-processes --terminate"
  [ "$status" -eq 2 ]

  run run_resources_zsh "sys-ports --kill-port"
  [ "$status" -eq 2 ]

  run run_resources_zsh "sys-services --restart"
  [ "$status" -eq 2 ]
}

@test "sys resources: stale capability entries repeat dependency checks" {
  run run_resources_zsh \
    "command() {
       [[ \"\$1\" == -v && \"\$2\" == ps ]] && return 1
       builtin command \"\$@\"
     }
     sys-processes --list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires ps"* ]]

  run run_resources_zsh \
    "command() {
       [[ \"\$1\" == -v && \"\$2\" == lsof ]] && return 1
       builtin command \"\$@\"
     }
     sys-ports --list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires lsof"* ]]

  run run_resources_zsh \
    "command() {
       [[ \"\$1\" == -v && \"\$2\" == systemctl ]] && return 1
       builtin command \"\$@\"
     }
     sys-services --list"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires systemctl"* ]]
}

@test "sys-processes: procps list emits only validated TSV" {
  run run_resources_zsh \
    "sys-processes --list >'$TEST_TEMP_DIR/stdout' 2>'$TEST_TEMP_DIR/stderr'"
  [ "$status" -eq 0 ]
  [ ! -s "$TEST_TEMP_DIR/stderr" ]
  [ "$(sed -n '1p' "$TEST_TEMP_DIR/stdout")" = \
    $'process\t4242\t'"$MOCK_PROCESS_UID"$'\t1.5\t0.2\tnode' ]
  [ "$(awk -F '\t' 'NF != 6 { print }' "$TEST_TEMP_DIR/stdout")" = "" ]
}

@test "sys-processes: bsd-ps list uses the portable backend" {
  run run_resources_zsh "sys-processes --list" lsof systemd bsd-ps
  [ "$status" -eq 0 ]
  [[ "$output" == *$'process\t4343\t'"$MOCK_PROCESS_UID"$'\t0.5\t0.1\tworker'* ]]
}

@test "sys-processes: protected PIDs never reach kill" {
  run run_resources_zsh "sys-processes --terminate 1 --yes"
  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"protected PID 1"* ]]
}

@test "sys resources: oversized numeric targets cannot wrap" {
  run run_resources_zsh \
    "sys-processes --terminate 18446744073709551617 --yes"
  [ "$status" -eq 2 ]
  [ ! -s "$RESOURCE_LOG" ]

  run run_resources_zsh \
    "sys-ports --kill-port 18446744073709551617 --yes"
  [ "$status" -eq 2 ]
  [ ! -s "$RESOURCE_LOG" ]
}

@test "sys-processes: non-interactive mutation fails closed without --yes" {
  run run_resources_zsh "sys-processes --terminate 4242"
  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"requires --yes"* ]]
}

@test "sys-processes: TERM is default and KILL requires --force" {
  run run_resources_zsh "sys-processes --terminate 4242 --yes"
  [ "$status" -eq 0 ] || {
    printf 'status=%s output=%s\n' "$status" "$output"
    false
  }
  [ "$(cat "$RESOURCE_LOG")" = "-s TERM 4242" ]

  : > "$RESOURCE_LOG"
  : > "$PS_START_COUNT_FILE"
  run run_resources_zsh "sys-processes --terminate 4242 --force --yes"
  [ "$status" -eq 0 ]
  [ "$(cat "$RESOURCE_LOG")" = "-s KILL 4242" ]
}

@test "sys-processes: fingerprint change aborts before signaling" {
  export MOCK_PS_CHANGE_AFTER_FINGERPRINT=1
  run run_resources_zsh "sys-processes --terminate 4242 --yes"
  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"identity changed"* ]]
}

@test "sys-processes: signal failure is reported and returned" {
  export MOCK_KILL_FAIL=1
  run run_resources_zsh "sys-processes --terminate 4242 --yes"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to send SIGTERM"* ]]
}

@test "sys-processes: a foreign UID is revalidated before minimal sudo" {
  MOCK_PROCESS_UID="$(($(id -u) + 1))"
  export MOCK_PROCESS_UID
  run run_resources_zsh "sys-processes --terminate 4242 --yes"
  [ "$status" -eq 0 ]
  [ "$(cat "$RESOURCE_LOG")" = \
    $'sudo -v\nsudo -n kill -s TERM 4242' ]
}

@test "sys-processes: identity change during sudo authentication aborts" {
  MOCK_PROCESS_UID="$(($(id -u) + 1))"
  export MOCK_PROCESS_UID
  export MOCK_PS_CHANGE_AFTER_SUDO_AUTH=1

  run run_resources_zsh "sys-processes --terminate 4242 --yes"

  [ "$status" -eq 1 ]
  [ "$(cat "$RESOURCE_LOG")" = "sudo -v" ]
  [[ "$output" == *"identity changed during authentication"* ]]
}

@test "sys-ports: lsof and ss collectors emit the same typed schema" {
  run run_resources_zsh "sys-ports --list" lsof
  [ "$status" -eq 0 ]
  [[ "$output" == *$'port\ttcp\t3000\t127.0.0.1\t4242\tnode'* ]]

  run run_resources_zsh "sys-ports --list" ss
  [ "$status" -eq 0 ]
  [[ "$output" == *$'port\ttcp\t3000\t127.0.0.1\t4242\tnode'* ]]
  [[ "$output" == *$'port\tudp\t5353\t127.0.0.1\t4343\tmdns'* ]]
}

@test "sys-ports: a bare numeric kill target is rejected as ambiguous" {
  run run_resources_zsh "sys-ports --kill 3000 --yes"
  [ "$status" -eq 2 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"Ambiguous target"* ]]
}

@test "sys-ports: an exact port resolves and revalidates one PID" {
  run run_resources_zsh "sys-ports --kill-port 3000 --protocol tcp --yes"
  [ "$status" -eq 0 ]
  [ "$(cat "$RESOURCE_LOG")" = "-s TERM 4242" ]
}

@test "sys-ports: non-interactive listener mutation requires --yes" {
  run run_resources_zsh "sys-ports --kill-port 3000"
  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"requires --yes"* ]]
}

@test "sys-ports: multiple PIDs on one port fail closed" {
  export MOCK_LSOF_MULTIPLE=1
  run run_resources_zsh "sys-ports --kill-port 3000 --yes"
  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"multiple PIDs"* ]]
}

@test "sys-ports: ss multi-owner rows emit each PID and fail closed" {
  export MOCK_SS_MULTIPLE=1

  run run_resources_zsh "_sys_ports_ss_records" ss

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = $'port\ttcp\t3000\t127.0.0.1\t111\ta' ]
  [ "${lines[1]}" = $'port\ttcp\t3000\t127.0.0.1\t222\tb' ]

  run run_resources_zsh \
    "sys-ports --kill-port 3000 --protocol tcp --yes" ss

  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"multiple PIDs"* ]]
}

@test "sys-ports: changed port ownership aborts before signaling" {
  export MOCK_LSOF_CHANGE_AFTER_SCAN=1
  run run_resources_zsh "sys-ports --kill-port 3000 --yes"
  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"listener changed"* ]]
}

@test "sys-services: systemd and launchd lists emit typed TSV" {
  run run_resources_zsh "sys-services --list" lsof systemd
  [ "$status" -eq 0 ]
  [[ "$output" == *$'service\tsystemd\tdemo.service\tactive\trunning\tDemo service'* ]]

  run run_resources_zsh "sys-services --list" lsof launchd
  [ "$status" -eq 0 ]
  [[ "$output" == *$'service\tlaunchd\tcom.example.demo\tactive\tpid=777, last-exit=0'* ]]
}

@test "sys-services: non-interactive mutation fails closed without --yes" {
  run run_resources_zsh "sys-services --restart demo.service"
  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"requires --yes"* ]]
}

@test "sys-services: systemd revalidates state and checks sudo status" {
  run run_resources_zsh "sys-services --restart demo.service --yes"
  [ "$status" -eq 0 ]
  [ "$(cat "$RESOURCE_LOG")" = \
    $'sudo -v\nsudo -n systemctl restart -- demo.service' ]

  : > "$RESOURCE_LOG"
  : > "$SYSTEMCTL_COUNT_FILE"
  export MOCK_SUDO_FAIL=1
  run run_resources_zsh "sys-services --restart demo.service --yes"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed"* ]]
}

@test "sys-services: state change during sudo authentication aborts" {
  export MOCK_SYSTEMD_CHANGE_AFTER_SUDO_AUTH=1

  run run_resources_zsh "sys-services --restart demo.service --yes"

  [ "$status" -eq 1 ]
  [ "$(cat "$RESOURCE_LOG")" = "sudo -v" ]
  [[ "$output" == *"state changed during authentication"* ]]
}

@test "sys-services: changed systemd state aborts before sudo" {
  export MOCK_SYSTEMD_STATE_CHANGE=1
  run run_resources_zsh "sys-services --stop demo.service --yes"
  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"state changed"* ]]
}

@test "sys-services: launchd actions target the current GUI domain" {
  run run_resources_zsh \
    "sys-services --restart com.example.demo --yes" lsof launchd
  [ "$status" -eq 0 ]
  [ "$(cat "$RESOURCE_LOG")" = \
    "launchctl kickstart -k gui/$(id -u)/com.example.demo" ]
}

@test "sys-services: launchd revalidation and command failures are visible" {
  export MOCK_LAUNCHD_STATE_CHANGE=1
  run run_resources_zsh \
    "sys-services --stop com.example.demo --yes" lsof launchd
  [ "$status" -eq 1 ]
  [ ! -s "$RESOURCE_LOG" ]
  [[ "$output" == *"state changed"* ]]

  unset MOCK_LAUNCHD_STATE_CHANGE
  : > "$LAUNCHCTL_COUNT_FILE"
  export MOCK_LAUNCHCTL_FAIL=1
  run run_resources_zsh \
    "sys-services --stop com.example.demo --yes" lsof launchd
  [ "$status" -eq 1 ]
  [[ "$output" == *"launchctl stop failed"* ]]
}

@test "sys resources: interactive fzf is read-only and legends match bindings" {
  export MOCK_FZF_CANCEL=1
  local command_name
  for command_name in sys-ports sys-processes sys-services; do
    : > "$FZF_LOG"
    run run_resources_zsh \
      "$command_name >'$TEST_TEMP_DIR/stdout' 2>'$TEST_TEMP_DIR/stderr'"
    [ "$status" -eq 0 ]
    [ ! -s "$TEST_TEMP_DIR/stdout" ]
    ! grep -Eq -- '--bind|execute\\(' "$FZF_LOG"
    grep -q -- '--expect=' "$FZF_LOG"
    grep -q -- 'Esc cancel' "$FZF_LOG"
  done
}
