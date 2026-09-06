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

@test "ci safety: noninteractive destructive commands fail closed without yes" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-actions --run 1001 --limit 3
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a terminal"* ]]
  ! grep -q 'gh api --method DELETE' "$MOCK_CI_GH_LOG"

  : > "$MOCK_CI_GH_LOG"
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-notifications --thread 5001
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a terminal"* ]]
  ! grep -q 'gh api --method PATCH' "$MOCK_CI_GH_LOG"
}

@test "ci safety: yes bypasses only confirmation for exact run deletion" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-actions --run 1001 --limit 3 --yes
  '
  [ "$status" -eq 0 ]
  grep -q \
    'gh api --method DELETE --hostname github.com repos/acme/project/actions/runs/1001' \
    "$MOCK_CI_GH_LOG"
}

@test "ci safety: selected run replacement is refused after authorization" {
  export MOCK_CI_RUNS_CHANGED="1"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-actions --run 1001 --limit 3 --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed or became protected"* ]]
  ! grep -q 'gh api --method DELETE' "$MOCK_CI_GH_LOG"
}

@test "ci safety: redacted run changes remain detectable after authorization" {
  export MOCK_CI_SECRET_CHANGED="1"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-actions --run 1001 --limit 2 --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed or became protected"* ]]
  [[ "$output" != *"example-value"* ]]
  [[ "$output" != *"replacement-value"* ]]
  ! grep -q 'gh api --method DELETE' "$MOCK_CI_GH_LOG"
}

@test "ci safety: repository identity is revalidated before remote writes" {
  export MOCK_CI_REPO_ID_CHANGED="1"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-releases --release 4001 --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"repository identity changed"* ]]
  ! grep -q 'gh api --method DELETE' "$MOCK_CI_GH_LOG"
}

@test "ci safety: workflow dispatch refuses a mismatched GitHub branch" {
  export MOCK_CI_REF_OID="0000000000000000000000000000000000000000"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-run --workflow 501 --ref main --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"branch commits differ"* ]]
  ! grep -q 'gh api --method POST' "$MOCK_CI_GH_LOG"
}

@test "ci safety: deployment partial failure is visible and nonzero" {
  export MOCK_CI_MUTATION_FAIL="DELETE:repos/acme/project/deployments/3001"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-deployments --deployment 3001 --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"deactivated but could not be deleted"* ]]
  grep -q \
    'gh api --method POST --hostname github.com repos/acme/project/deployments/3001/statuses -f state=inactive' \
    "$MOCK_CI_GH_LOG"
  grep -q \
    'gh api --method DELETE --hostname github.com repos/acme/project/deployments/3001' \
    "$MOCK_CI_GH_LOG"
}

@test "ci safety: release cleanup never widens into tag deletion" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-releases --release 4001 --yes
  '
  [ "$status" -eq 0 ]
  grep -q \
    'gh api --method DELETE --hostname github.com repos/acme/project/releases/4001' \
    "$MOCK_CI_GH_LOG"
  ! grep -Eq 'git push|refs/tags|cleanup-tag' "$MOCK_CI_GH_LOG"
}

@test "ci safety: notification updates remain repository-bound and exact" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-notifications --thread 5001 --yes
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme/project"* ]]
  grep -q \
    'gh api --method PATCH --hostname github.com notifications/threads/5001' \
    "$MOCK_CI_GH_LOG"
}

@test "ci safety: notification records repeat the frozen repository identity" {
  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-menu --help >/dev/null 2>&1 || return
    _ci_require_python || return
    _ci_repo_context || return
    local inventory=""
    inventory=$(_ci_notifications_inventory) || return
    local visible_record="${inventory%$'\''\t'\''*}"
    [[ "${visible_record##*$'\''\t'\''}" == "acme/project" ]]
  '
  [ "$status" -eq 0 ]
}

@test "ci safety: mismatched notification repositories fail closed" {
  export MOCK_CI_WRONG_NOTIFICATION_REPO="1"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-notifications --thread 5001 --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid notification inventory"* ]]
  ! grep -q 'gh api --method PATCH' "$MOCK_CI_GH_LOG"
}

@test "ci safety: malformed GitHub records fail closed before mutation" {
  export MOCK_CI_INVALID_RESPONSE="1"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-actions --run 1001 --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid workflow-run inventory"* ]]
  ! grep -q 'gh api --method DELETE' "$MOCK_CI_GH_LOG"
}

@test "ci safety: duplicate remote resource IDs fail closed" {
  export MOCK_CI_DUPLICATE_RUN_ID="1"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-actions --run 1001 --limit 2 --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid workflow-run inventory"* ]]
  ! grep -q 'gh api --method DELETE' "$MOCK_CI_GH_LOG"
}

@test "ci safety: duplicate direct targets fail before GitHub probes" {
  run run_zsh '
    ci-menu --help >/dev/null
    ci-clean-actions --run 1001 --run 1001 --yes
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"Duplicate requested target"* ]]
  [ ! -s "$MOCK_CI_GH_LOG" ]
}

@test "ci safety: read-only responses are byte-bounded before shell capture" {
  grep -Fq 'head -c "$(( maximum_bytes + 1 ))"' \
    "$TEST_SUITE_ROOT/functions/ci-common.zsh"

  run run_zsh '
    ci-menu --help >/dev/null 2>&1 || return
    _ci_run_probe() {
      printf "1234"
    }
    _ci_capture_probe 4 ignored || return
    [[ "$REPLY" == "1234" ]]
  '
  [ "$status" -eq 0 ]

  run run_zsh '
    ci-menu --help >/dev/null 2>&1 || return
    _ci_run_probe() {
      printf "123\n"
    }
    _ci_capture_probe 4 ignored || return
    [[ "$REPLY" == "123" ]]
  '
  [ "$status" -eq 0 ]

  run run_zsh '
    ci-menu --help >/dev/null 2>&1 || return
    _ci_run_probe() {
      printf "123"
      return 19
    }
    _ci_capture_probe 4 ignored
  '
  [ "$status" -eq 19 ]

  run run_zsh '
    ci-menu --help >/dev/null 2>&1 || return
    _ci_run_probe() {
      printf "1234\n"
    }
    _ci_capture_probe 4 ignored
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"oversized response"* ]]
}

@test "ci safety: an untrusted mktemp result is never chmodded or removed" {
  export CI_MKTEMP_VICTIM="$HOME/tmp/not-a-ci-capture"
  mkdir -p "$CI_MKTEMP_VICTIM"
  printf '%s\n' "keep" > "$CI_MKTEMP_VICTIM/keep"
  chmod 700 "$CI_MKTEMP_VICTIM"

  cat <<'EOF' > "$TEST_MOCK_BIN/mktemp"
#!/usr/bin/env bash
printf '%s\n' "$CI_MKTEMP_VICTIM"
EOF
  chmod +x "$TEST_MOCK_BIN/mktemp"

  run run_zsh '
    ci-menu --help >/dev/null 2>&1 || return
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    zmodload zsh/stat || return
    local -A before_state=() after_state=()
    zstat -LH before_state -- "$CI_MKTEMP_VICTIM" || return
    _ci_fzf_capture </dev/null
    local capture_rc=$?
    zstat -LH after_state -- "$CI_MKTEMP_VICTIM" || return
    (( capture_rc == 125 )) || return 1
    [[ "${before_state[mode]}" == "${after_state[mode]}" ]]
    [[ -f "$CI_MKTEMP_VICTIM/keep" ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsafe CI menu directory"* ]]
}

@test "ci safety: cancellation cannot carry a forged picker record" {
  run run_zsh '
    ci-menu --help >/dev/null 2>&1 || return
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    _ci_fzf() {
      print -r -- "forged"
      return 130
    }
    _ci_fzf_capture </dev/null
  '
  [ "$status" -eq 125 ]
  [[ "$output" == *"cancelled CI picker returned unexpected data"* ]]
}

@test "ci safety: exact record membership treats record text only as data" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE=$'D\t1001\tname[index]\tfeature+branch'

  run run_zsh '
    ci-menu --help >/dev/null 2>&1 || return
    local record=$'\''D\t1001\tname[index]\tfeature+branch'\''
    _ci_select_records "ci records" "select exact record" "$record" || return
    (( ${#reply[@]} == 1 )) || return 1
    [[ "${reply[1]}" == "$record" ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"invalid subscript"* ]]
}

@test "ci safety: exact absent targets are errors rather than empty no-ops" {
  export MOCK_CI_EMPTY_DEPLOYMENTS="1"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-clean-deployments --deployment 3001 --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in the bounded inventory"* ]]
  ! grep -q 'gh api --method \(POST\|DELETE\)' "$MOCK_CI_GH_LOG"
}

@test "ci safety: sensitive-looking remote display fields are redacted" {
  export MOCK_CI_SECRET_RESPONSE="1"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-status --list
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[redacted]"* ]]
  [[ "$output" != *"example-value"* ]]
}

@test "ci safety: native run view failures do not expose raw remote errors" {
  export MOCK_CI_RUN_VIEW_ERROR="1"

  run run_zsh '
    cd "$CI_TEST_REPO" || return
    ci-status --limit 3 --run 1001
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unable to view workflow run 1001"* ]]
  [[ "$output" != *"raw-run-view-error"* ]]
  [[ "$output" != *"Authorization"* ]]
}

@test "ci safety: unauthorized mutation shapes are denied by the gh fixture" {
  run "$TEST_MOCK_BIN/gh" api \
    --method DELETE \
    --hostname github.com \
    repos/acme/project/actions/runs/9999
  [ "$status" -eq 97 ]
  [[ "$output" == *"denied mutation"* ]]
}

@test "ci safety: direct help and invalid grammar do not require a repository" {
  run run_zsh 'ci-run --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"--workflow"* ]]

  run run_zsh 'ci-clean-deployments --deployment nope --yes'
  [ "$status" -eq 2 ]
  [[ "$output" == *"positive numeric"* ]]
}
