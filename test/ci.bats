#!/usr/bin/env bats

setup() {
  load test_helper

  cp "$TEST_SUITE_ROOT/test/fixtures/ci-gh-mock.sh" "$TEST_MOCK_BIN/gh"
  chmod +x "$TEST_MOCK_BIN/gh"
  export MOCK_CI_GH_LOG="$TEST_TEMP_DIR/ci-gh-calls"
  export MOCK_CI_RUNS_COUNT_FILE="$TEST_TEMP_DIR/ci-runs-count"
  : > "$MOCK_CI_GH_LOG"
  printf '%s\n' "0" > "$MOCK_CI_RUNS_COUNT_FILE"

  export CI_TEST_REPO="$HOME/repository"
  mkdir -p "$CI_TEST_REPO"
  git -C "$CI_TEST_REPO" init -q -b main
  git -C "$CI_TEST_REPO" config user.name "Jane Doe"
  git -C "$CI_TEST_REPO" config user.email "jane@example.test"
  printf '%s\n' "fixture" > "$CI_TEST_REPO/README.md"
  git -C "$CI_TEST_REPO" add README.md
  git -C "$CI_TEST_REPO" commit -q -m "test: initialize fixture"
  export MOCK_CI_REF_OID
  MOCK_CI_REF_OID=$(git -C "$CI_TEST_REPO" rev-parse HEAD)
}

teardown() {
  cleanup_sandbox
}

@test "ci: status list emits validated TSV data without UI stdout" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-status --limit 3 --list >"$HOME/stdout" 2>"$HOME/stderr"
    [[ "$(<"$HOME/stdout")" == \
      $'\''2001\t102\tin_progress\tDocs\tmain\t2026-07-26T11:00:00Z\tworkflow_dispatch\tdocs\n1002\t101\tsuccess\tBuild\tmain\t2026-07-26T10:00:00Z\tpush\tlatest build\n1001\t101\tfailure\tBuild\tfeature\t2026-07-25T10:00:00Z\tpull_request\tolder build'\'' ]]
  '
  [ "$status" -eq 0 ]
}

@test "ci: explicit status run is resolved through a repository-bound lookup" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-status --limit 3 --run 1001
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run details for 1001"* ]]
  grep -q 'gh run view 1001 --repo github.com/acme/project' \
    "$MOCK_CI_GH_LOG"
}

@test "ci: workflow dry run shows an exact plan and performs no write" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    NO_COLOR=1 ci-run \
      --workflow .github/workflows/ci.yml \
      --ref main \
      --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow ID: 501"* ]]
  [[ "$output" == *"Branch: main"* ]]
  ! grep -q 'gh api --method POST' "$MOCK_CI_GH_LOG"
}

@test "ci: authorized workflow dispatch uses the frozen numeric workflow ID" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-run --workflow 501 --ref main --yes
  '
  [ "$status" -eq 0 ]
  grep -q \
    'gh api --method POST --hostname github.com repos/acme/project/actions/workflows/501/dispatches -f ref=main' \
    "$MOCK_CI_GH_LOG"
}

@test "ci: disabled workflows fail before a dispatch mutation" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-run --workflow 502 --ref main --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"not active"* ]]
  ! grep -q 'gh api --method POST' "$MOCK_CI_GH_LOG"
}

@test "ci: action cleanup dry run preserves newest workflow runs" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-actions --run 1001 --limit 3 --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run record: D"* ]]
  ! grep -q 'gh api --method DELETE' "$MOCK_CI_GH_LOG"

  : > "$MOCK_CI_GH_LOG"
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-actions --run 1002 --limit 3 --dry-run
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected"* ]]
  ! grep -q 'gh api --method DELETE' "$MOCK_CI_GH_LOG"
}

@test "ci: deployment, release, and notification dry runs are exact" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-deployments --deployment 3001 --dry-run
    ci-clean-releases --release 4001 --dry-run
    ci-clean-notifications --thread 5001 --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deployment record: D"* ]]
  [[ "$output" == *"Release record: D"* ]]
  [[ "$output" == *"Thread record: 5001"* ]]
  ! grep -Eq 'gh api --method (POST|PATCH|DELETE)' "$MOCK_CI_GH_LOG"
}

@test "ci: compatibility adapters delegate to public Git owners" {
  run run_zsh '
    ci-menu --help >/dev/null
    git-menu() {
      print -r -- "${(j:|:)@}"
      return 19
    }
    ci-clean-tags
  '
  [ "$status" -eq 19 ]
  [[ "$output" == *"git-tag-list"* ]]

  run run_zsh '
    ci-menu --help >/dev/null
    git-menu() {
      print -r -- "${(j:|:)@}"
      return 23
    }
    ci-clean-issues
  '
  [ "$status" -eq 23 ]
  [[ "$output" == *"git-issues"* ]]
}

@test "ci: command parsers reject invalid input before GitHub probes" {
  run run_zsh '
    ci-menu --help >/dev/null
    ci-run --workflow ../evil --yes
  '
  [ "$status" -eq 2 ]

  run run_zsh '
    ci-menu --help >/dev/null
    ci-clean-actions --run -1 --yes
  '
  [ "$status" -eq 2 ]

  run run_zsh '
    ci-menu --help >/dev/null
    ci-clean-releases --release 4001 --dry-run --yes
  '
  [ "$status" -eq 2 ]

  [ ! -s "$MOCK_CI_GH_LOG" ]
}

@test "ci: menus use foreground capture with no data-derived preview program" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    cd "$CI_TEST_REPO" || return
    ci-clean-actions
    local cleanup_rc=$?
    (( cleanup_rc == 0 )) || return 1
    local -a leftovers=("$TMPDIR"/zdx-ci-fzf.*(N))
    (( ${#leftovers} == 0 ))
  '
  [ "$status" -eq 0 ]
  grep -q -- '--preview=' "$MOCK_FZF_ARGS_FILE"
  ! grep -q 'gh ' "$MOCK_FZF_ARGS_FILE"
}
