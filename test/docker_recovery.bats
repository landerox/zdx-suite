#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export MOCK_DOCKER_LOG="$TEST_TEMP_DIR/docker-calls"
  export MOCK_DOCKER_RC=0 MOCK_DOCKER_INSPECT_RC=0
  export MOCK_DOCKER_FIRST_ID MOCK_DOCKER_SECOND_ID
  printf -v MOCK_DOCKER_FIRST_ID 'a%.0s' {1..64}
  printf -v MOCK_DOCKER_SECOND_ID 'b%.0s' {1..64}
  mkdir "$HOME/.docker"
  chmod 700 "$HOME/.docker"
  : > "$MOCK_DOCKER_LOG"
  cat > "$TEST_MOCK_BIN/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
while [[ "${1:-}" == --config || "${1:-}" == --context ]]; do shift 2; done
case "$1:${2:-}" in
  context:show) printf 'local-test\n' ;;
  context:inspect) printf 'unix:///var/run/docker.sock\n' ;;
  info:*) printf 'daemon-one\n' ;;
  version:*) printf '26.1.0\n' ;;
  container:ls)
    printf '%s|first|exited|alpine:3.20\n' "$MOCK_DOCKER_FIRST_ID"
    printf '%s|second|exited|alpine:3.20\n' "$MOCK_DOCKER_SECOND_ID"
    ;;
  container:inspect)
    [[ "$MOCK_DOCKER_INSPECT_RC" == 0 ]] || exit "$MOCK_DOCKER_INSPECT_RC"
    case "${!#}" in
      "$MOCK_DOCKER_FIRST_ID") printf '%s|/first|exited|alpine:3.20\n' "${!#}" ;;
      "$MOCK_DOCKER_SECOND_ID") printf '%s|/second|exited|alpine:3.20\n' "${!#}" ;;
      *) exit 97 ;;
    esac
    ;;
  container:rm)
    [[ "$3" == -- && "$#" == 4 ]] || exit 97
    case "$4" in
      "$MOCK_DOCKER_FIRST_ID") exit "$MOCK_DOCKER_RC" ;;
      "$MOCK_DOCKER_SECOND_ID") exit 0 ;;
      *) exit 97 ;;
    esac
    ;;
  *) exit 97 ;;
esac
MOCK
  chmod +x "$TEST_MOCK_BIN/docker"
}

teardown() { cleanup_sandbox; }

@test "docker recovery: cleanup stops after an interrupted removal" {
  for MOCK_DOCKER_RC in 130 143; do
    export MOCK_DOCKER_RC
    : > "$MOCK_DOCKER_LOG"
    run run_zsh 'unfunction command
docker-clean --scope stopped-containers --yes'
    [ "$status" -eq "$MOCK_DOCKER_RC" ]
    [ "$(grep -c 'container rm' "$MOCK_DOCKER_LOG")" -eq 1 ]
    [[ "$output" == *"not attempted: 1"* ]]
    [[ "$output" != *"cleanup completed"* ]]
  done
}

@test "docker recovery: ordinary removal failure continues the reviewed batch" {
  export MOCK_DOCKER_RC=9
  run run_zsh 'unfunction command
docker-clean --scope stopped-containers --yes >"$HOME/out"'
  [ "$status" -eq 1 ]
  [ "$(grep -c 'container rm' "$MOCK_DOCKER_LOG")" -eq 2 ]
  [[ "$output" == *"removed 1, failed 1"* ]]
  [ ! -s "$HOME/out" ]
}

@test "docker recovery: interrupted per-target inspection stops the batch" {
  for MOCK_DOCKER_INSPECT_RC in 130 143; do
    export MOCK_DOCKER_INSPECT_RC
    : > "$MOCK_DOCKER_LOG"
    run run_zsh 'unfunction command
docker-clean --scope stopped-containers --yes'
    [ "$status" -eq "$MOCK_DOCKER_INSPECT_RC" ]
    [ "$(grep -c 'container inspect' "$MOCK_DOCKER_LOG")" -eq 1 ]
    ! grep -q 'container rm' "$MOCK_DOCKER_LOG" || return 1
  done
}

@test "docker recovery: both bounded capture streams preserve interruption and discard data" {
  run run_zsh 'unfunction command

    for helper in _docker_capture_probe_bounded _docker_capture_probe_stderr_bounded; do
      for code in 130 143; do
        REPLY=stale
        "$helper" 32 1 zsh -fc '\''print private; print -u2 private; exit "$1"'\'' probe "$code" 2>/dev/null
        rc=$?
        [[ $rc == $code && -z "$REPLY" ]] || return 1
      done
    done
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "docker recovery: a probe ignoring TERM is killed after the grace interval" {
  # The finite fallback bounds a broken implementation without orphaning a job.
  run run_zsh 'unfunction command

    _docker_run_probe 1 zsh -fc '\''trap "" TERM; sleep 5'\''
  '
  [ "$status" -eq 137 ]
}

@test "docker recovery: dry run never removes a reviewed container" {
  run run_zsh 'unfunction command
docker-clean --scope stopped-containers --dry-run'
  [ "$status" -eq 0 ]
  ! grep -q 'container rm' "$MOCK_DOCKER_LOG" || return 1
}

@test "docker recovery: client configuration validation captures only parser diagnostics" {
  printf '{}\n' > "$HOME/.docker/config.json"
  chmod 600 "$HOME/.docker/config.json"
  run run_zsh 'unfunction command
docker-clean --scope stopped-containers --dry-run'
  [ "$status" -eq 0 ]
  ! grep -q 'container rm' "$MOCK_DOCKER_LOG" || return 1
}

@test "docker recovery: interrupted byte guard stops before any target is removed" {
  export DOCKER_RECOVERY_REAL_HEAD
  DOCKER_RECOVERY_REAL_HEAD=$(command -v head)
  cat > "$TEST_MOCK_BIN/head" <<'MOCK'
#!/usr/bin/env bash
payload=$("$DOCKER_RECOVERY_REAL_HEAD" "$@") || exit "$?"
printf '%s' "$payload"
if [[ "$payload" == *'|/first|'* ]]; then
  exit "$MOCK_DOCKER_HEAD_RC"
fi
MOCK
  chmod +x "$TEST_MOCK_BIN/head"
  for MOCK_DOCKER_HEAD_RC in 130 143; do
    export MOCK_DOCKER_HEAD_RC
    : > "$MOCK_DOCKER_LOG"
    run run_zsh 'unfunction command
docker-clean --scope stopped-containers --yes'
    [ "$status" -eq "$MOCK_DOCKER_HEAD_RC" ]
    ! grep -q 'container rm' "$MOCK_DOCKER_LOG" || return 1
    [ "$(grep -c 'container inspect' "$MOCK_DOCKER_LOG")" -eq 1 ]
  done
}
