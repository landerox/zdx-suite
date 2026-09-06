#!/usr/bin/env bats
# BATS runs every test with a fresh setup in its own process.
# shellcheck disable=SC2030,SC2031

setup() {
  load test_helper
  export APP_TASK_LOG="$TEST_TEMP_DIR/tasks.log"
  cat <<'EOF' > "$TEST_MOCK_BIN/just"
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >> "$APP_TASK_LOG"
if [[ "${@: -1}" == first ]]; then
  exit "${APP_FIRST_STATUS:-0}"
fi
EOF
  chmod +x "$TEST_MOCK_BIN/just"
}

teardown() {
  cleanup_sandbox
}

@test "app recovery: direct Just execution is independent of an invalid Node descriptor" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    print -r -- "invalid JSON" > package.json
    app-run --backend just --task build --yes
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$APP_TASK_LOG")" = build ]
}

@test "app recovery: complete listing still refuses an invalid descriptor" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    print -r -- "invalid JSON" > package.json
    app-list > "$HOME/inventory"
  '
  [ "$status" -ne 0 ]
  [ ! -s "$HOME/inventory" ]
  [ ! -e "$APP_TASK_LOG" ]
}

@test "app recovery: a Node task still refuses conflicting lockfile owners" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "{\"scripts\":{\"build\":\"echo build\"}}" > package.json
    touch package-lock.json yarn.lock
    app-run --backend npm --task build --dry-run
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"Multiple package-manager"* ]]
}

@test "app recovery: interrupted task batches stop and preserve signal status" {
  for interrupt_status in 130 143; do
    export APP_FIRST_STATUS="$interrupt_status"
    rm -f "$APP_TASK_LOG"
    run run_zsh '
      cd "$HOME" || return
      printf "first:\nsecond:\n" > Justfile
      inventory=$(_app_discover_tasks "$PWD") || return
      records=("${(@f)inventory}")
      _app_execute_task_records no yes "${records[@]}"
    '
    [ "$status" -eq "$interrupt_status" ]
    [ "$(cat "$APP_TASK_LOG")" = first ]
    [[ "$output" == *"Tasks not run: 1"* ]]
  done
}

@test "app recovery: ordinary task failure continues and identifies the failed invocation" {
  export APP_FIRST_STATUS=7
  run run_zsh '
    cd "$HOME" || return
    printf "first:\nsecond:\n" > Justfile
    inventory=$(_app_discover_tasks "$PWD") || return
    records=("${(@f)inventory}")
    _app_execute_task_records no yes "${records[@]}"
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$APP_TASK_LOG")" = $'first\nsecond' ]
  [[ "$output" == *"Failed (status 7):"*"first"* ]]
  [[ "$output" == *"Tasks completed: 1 / 2"* ]]
}

@test "app recovery: a direct descriptor probe interruption keeps its status" {
  cat <<'EOF' > "$TEST_MOCK_BIN/sha256sum"
#!/usr/bin/env bash
exit "$APP_PROBE_STATUS"
EOF
  chmod +x "$TEST_MOCK_BIN/sha256sum"
  for interrupt_status in 130 143; do
    export APP_PROBE_STATUS="$interrupt_status"
    run run_zsh '
      cd "$HOME" || return
      print -r -- "build:" > Justfile
      app-run --backend just --task build --yes
    '
    [ "$status" -eq "$interrupt_status" ]
    [ ! -e "$APP_TASK_LOG" ]
  done
}
