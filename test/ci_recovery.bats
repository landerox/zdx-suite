#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  cp "$TEST_SUITE_ROOT/test/fixtures/ci-gh-mock.sh" "$TEST_MOCK_BIN/gh"
  chmod +x "$TEST_MOCK_BIN/gh"
  export MOCK_CI_GH_LOG="$TEST_TEMP_DIR/ci-gh-calls"
  : > "$MOCK_CI_GH_LOG"
  export CI_TEST_REPO="$HOME/repository"
  mkdir "$CI_TEST_REPO"
  git -C "$CI_TEST_REPO" init -q -b main
  git -C "$CI_TEST_REPO" config user.name 'Jane Doe'
  git -C "$CI_TEST_REPO" config user.email 'jane@example.test'
  printf 'fixture\n' > "$CI_TEST_REPO/README.md"
  git -C "$CI_TEST_REPO" add README.md
  git -C "$CI_TEST_REPO" commit -q -m 'test: initialize fixture'
  export MOCK_CI_REF_OID
  MOCK_CI_REF_OID=$(git -C "$CI_TEST_REPO" rev-parse HEAD)
}

teardown() { cleanup_sandbox; }

@test "ci recovery: an explicit historical run uses a repository-bound exact lookup" {
  run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ci-status --run 9001 --limit 1'
  [ "$status" -eq 0 ]
  [[ "$output" == *'Run details for 9001'* ]]
  grep -q 'repos/acme/project/actions/runs/9001' "$MOCK_CI_GH_LOG"
  ! grep -q 'per_page' "$MOCK_CI_GH_LOG" || return 1
}

@test "ci recovery: an explicit unavailable run fails even when recent inventory is empty" {
  export MOCK_CI_RUNS_RESPONSE_FILE="$TEST_TEMP_DIR/runs.json"
  printf '{"workflow_runs":[]}\n' > "$MOCK_CI_RUNS_RESPONSE_FILE"
  export MOCK_CI_EXACT_ERROR=1
  run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ci-status --run 9001'
  [ "$status" -eq 1 ]
  ! grep -q 'gh run view' "$MOCK_CI_GH_LOG" || return 1
}

@test "ci recovery: exact run identity rejects another run or repository" {
  for mismatch in id repository name; do
    unset MOCK_CI_EXACT_ID MOCK_CI_EXACT_REPO_ID MOCK_CI_EXACT_REPO_NAME
    case "$mismatch" in
      id) export MOCK_CI_EXACT_ID=9002 ;;
      repository) export MOCK_CI_EXACT_REPO_ID=OTHER ;;
      name) export MOCK_CI_EXACT_REPO_NAME=other/project ;;
    esac
    : > "$MOCK_CI_GH_LOG"
    run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ci-status --run 9001'
    [ "$status" -eq 1 ]
    ! grep -q 'gh run view' "$MOCK_CI_GH_LOG" || return 1
  done
}

@test "ci recovery: all cleanup mutations preserve interruption without reporting success" {
  for MOCK_CI_MUTATION_RC in 130 143; do
    export MOCK_CI_MUTATION_RC
    for action in runs deployments releases notifications; do
      case "$action" in
        runs) export MOCK_CI_MUTATION_FAIL='actions/runs/1001'; invocation='ci-clean-actions --run 1001' ;;
        deployments) export MOCK_CI_MUTATION_FAIL='deployments/3001/statuses'; invocation='ci-clean-deployments --deployment 3001' ;;
        releases) export MOCK_CI_MUTATION_FAIL='releases/4001'; invocation='ci-clean-releases --release 4001' ;;
        notifications) export MOCK_CI_MUTATION_FAIL='notifications/threads/5001'; invocation='ci-clean-notifications --thread 5001' ;;
      esac
      export CI_RECOVERY_COMMAND="$invocation"
      : > "$MOCK_CI_GH_LOG"
      run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ${=CI_RECOVERY_COMMAND} --yes >"$HOME/out"'
      [ "$status" -eq "$MOCK_CI_MUTATION_RC" ]
      [[ "$output" == *'interrupted'* ]]
      [ ! -s "$HOME/out" ]
      if [[ "$action" == deployments ]]; then
        ! grep -q 'gh api --method DELETE' "$MOCK_CI_GH_LOG" || return 1
      fi
    done
  done
}

@test "ci recovery: an interrupted cleanup stops before the next selected run" {
  gh api 'repos/acme/project/actions/runs?per_page=40' > "$TEST_TEMP_DIR/original.json"
  export MOCK_CI_RUNS_RESPONSE_FILE="$TEST_TEMP_DIR/runs.json"
  python3 - "$TEST_TEMP_DIR/original.json" "$MOCK_CI_RUNS_RESPONSE_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
older = dict(payload["workflow_runs"][1], id=1000, created_at="2026-07-24T10:00:00Z")
payload["workflow_runs"].append(older)
with open(sys.argv[2], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
  export MOCK_CI_MUTATION_FAIL='actions/runs/1001' MOCK_CI_MUTATION_RC=130
  : > "$MOCK_CI_GH_LOG"
  run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ci-clean-actions --run 1001 --run 1000 --yes'
  [ "$status" -eq 130 ]
  [ "$(grep -c 'gh api --method DELETE' "$MOCK_CI_GH_LOG")" -eq 1 ]
  [[ "$output" == *'not attempted: 1'* ]]

  export MOCK_CI_MUTATION_RC=9
  : > "$MOCK_CI_GH_LOG"
  run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ci-clean-actions --run 1001 --run 1000 --yes'
  [ "$status" -eq 1 ]
  [ "$(grep -c 'gh api --method DELETE' "$MOCK_CI_GH_LOG")" -eq 2 ]
}

@test "ci recovery: workflow dispatch interruption is not reported as definite rejection" {
  export MOCK_CI_MUTATION_FAIL='dispatches' MOCK_CI_MUTATION_RC=143
  run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ci-run --workflow 501 --ref main --yes'
  [ "$status" -eq 143 ]
  [[ "$output" == *'acceptance could not be confirmed'* ]]
  [[ "$output" != *'rejected'* ]]
}

@test "ci recovery: interrupted deployment deletion reports the already completed deactivation" {
  export MOCK_CI_MUTATION_FAIL='DELETE:repos/acme/project/deployments/3001'
  export MOCK_CI_MUTATION_RC=130
  run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ci-clean-deployments --deployment 3001 --yes'
  [ "$status" -eq 130 ]
  grep -q 'gh api --method POST.*deployments/3001/statuses' "$MOCK_CI_GH_LOG"
  grep -q 'gh api --method DELETE.*deployments/3001' "$MOCK_CI_GH_LOG"
  [[ "$output" == *'deactivated'* ]]
}

@test "ci recovery: interrupted schema revalidation stops every cleanup before mutation" {
  export CI_RECOVERY_REAL_PYTHON
  CI_RECOVERY_REAL_PYTHON=$(command -v python3)
  export CI_RECOVERY_PARSE_COUNT="$TEST_TEMP_DIR/parse-count"
  cat > "$TEST_MOCK_BIN/python3" <<'MOCK'
#!/usr/bin/env bash
count=$(<"$CI_RECOVERY_PARSE_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CI_RECOVERY_PARSE_COUNT"
if (( count == 2 )); then
  printf 'Authorization Bearer private-parser-output\n'
  exit "$MOCK_CI_PARSER_RC"
fi
exec "$CI_RECOVERY_REAL_PYTHON" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/python3"
  for MOCK_CI_PARSER_RC in 130 143; do
    export MOCK_CI_PARSER_RC
    for CI_RECOVERY_COMMAND in \
      'ci-clean-actions --run 1001' \
      'ci-clean-deployments --deployment 3001' \
      'ci-clean-releases --release 4001' \
      'ci-clean-notifications --thread 5001'; do
      export CI_RECOVERY_COMMAND
      printf '0\n' > "$CI_RECOVERY_PARSE_COUNT"
      : > "$MOCK_CI_GH_LOG"
      run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ${=CI_RECOVERY_COMMAND} --yes'
      [ "$status" -eq "$MOCK_CI_PARSER_RC" ]
      ! grep -q 'gh api --method' "$MOCK_CI_GH_LOG" || return 1
      [[ "$output" != *'private-parser-output'* ]]
    done
  done
}

@test "ci recovery: exact status lookup preserves interruption without displaying raw API data" {
  for MOCK_CI_EXACT_ERROR in 130 143; do
    export MOCK_CI_EXACT_ERROR
    : > "$MOCK_CI_GH_LOG"
    run run_zsh 'unfunction command
cd "$CI_TEST_REPO" && ci-status --run 9001'
    [ "$status" -eq "$MOCK_CI_EXACT_ERROR" ]
    ! grep -q 'gh run view' "$MOCK_CI_GH_LOG" || return 1
  done
}
