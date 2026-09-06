#!/usr/bin/env bats

setup() {
  load test_helper

  export MOCK_LSOF_EMPTY=0
  export MOCK_PS_PID_DEAD=0

  # Clear kill history
  export KILL_HISTORY_FILE="$TEST_TEMP_DIR/kill_history"
  : > "$KILL_HISTORY_FILE"

  # Create a machine-readable lsof mock compatible with the -F contract.
  cat <<'EOF' > "$TEST_MOCK_BIN/lsof"
#!/usr/bin/env bash
if [[ "$MOCK_LSOF_EMPTY" == "1" ]]; then
  exit 1
fi

case " $* " in
  *" -iTCP "*)
    printf '%s\n' \
      p12345 cnode PTCP n127.0.0.1:3000 \
      p12346 cpostgres PTCP n127.0.0.1:5432
    ;;
  *" -iUDP "*)
    printf '%s\n' p12347 cdnsmasq PUDP n127.0.0.1:53
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/lsof"

  # Create a stable process-fingerprint ps mock.
  cat <<'EOF' > "$TEST_MOCK_BIN/ps"
#!/usr/bin/env bash
pid=""
output_field=""
while (( $# )); do
  case "$1" in
    -p)
      pid="${2:-}"
      shift 2
      ;;
    -o)
      output_field="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -n "$pid" ]]; then
  if [[ -f "$HOME/dead_$pid" || "${MOCK_PS_PID_DEAD:-}" == "1" ]]; then
    exit 1
  fi

  case "$output_field" in
    uid=)    /usr/bin/id -u ;;
    lstart=) echo "Fri Jul 24 12:00:00 2026" ;;
    comm=)   echo "node" ;;
    *)       echo "  $pid" ;;
  esac
  exit 0
fi

# Fallback
if [[ -x /usr/bin/ps ]]; then
  exec /usr/bin/ps "$@"
elif [[ -x /bin/ps ]]; then
  exec /bin/ps "$@"
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/ps"

  # Create mock kill in TEST_MOCK_BIN
  cat <<'EOF' > "$TEST_MOCK_BIN/kill"
#!/usr/bin/env bash
echo "$@" >> "$KILL_HISTORY_FILE"
has_sigkill=0
if [[ "$*" == *"-9"* ]]; then
  has_sigkill=1
fi
for arg in "$@"; do
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    if [[ "$has_sigkill" -eq 1 || -z "$MOCK_STUBBORN" ]]; then
      touch "$HOME/dead_$arg"
    fi
  fi
done
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/kill"
}

teardown() {
  cleanup_sandbox
}

@test "sys-ports: --help works" {
  run run_zsh "sys-ports --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sys-ports --list"* ]]
  [[ "$output" == *"sys-ports --kill"* ]]
}

@test "sys-ports: --list emits canonical listening-port TSV" {
  run run_zsh "sys-ports --list"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'port\tudp\t53\t127.0.0.1\t12347\tdnsmasq'* ]]
  [[ "$output" == *$'port\ttcp\t3000\t127.0.0.1\t12345\tnode'* ]]
  [[ "$output" == *$'port\ttcp\t5432\t127.0.0.1\t12346\tpostgres'* ]]
  [[ "$output" != *"COMMAND"* ]]
}

@test "sys-ports: --list handles empty ports list gracefully" {
  export MOCK_LSOF_EMPTY=1
  run run_zsh "sys-ports --list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No active listening ports were found."* ]]
}

@test "sys-ports: --kill with invalid target fails" {
  run run_zsh "sys-ports --kill abc"
  [ "$status" -eq 2 ]
  [[ "$output" == *"use pid:PID or port:PORT"* ]]
}

@test "sys-ports: --kill-port with non-existent listener fails safely" {
  run run_zsh "sys-ports --kill-port 9999 --yes"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No visible process is listening on port 9999"* ]]
}

@test "sys-ports: --kill-port sends one SIGTERM with explicit consent" {
  run run_zsh "sys-ports --kill-port 3000 --protocol tcp --yes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"send SIGTERM to PID 12345"* ]]
  [[ "$output" == *"SIGTERM sent to PID 12345"* ]]

  kill_calls=$(cat "$KILL_HISTORY_FILE")
  [ "$kill_calls" = "-s TERM 12345" ]
}

@test "sys-ports: --kill-pid --force sends SIGKILL without automatic escalation" {
  run run_zsh "sys-ports --kill-pid 12345 --force --yes"
  [ "$status" -eq 0 ]
  [[ "$output" == *"send SIGKILL to PID 12345"* ]]
  [[ "$output" == *"SIGKILL sent to PID 12345"* ]]

  kill_calls=$(cat "$KILL_HISTORY_FILE")
  [ "$kill_calls" = "-s KILL 12345" ]
}
