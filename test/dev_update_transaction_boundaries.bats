#!/usr/bin/env bats
# Isolated Zsh programs own their signal target and every external executable.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export REAL_GIT
  REAL_GIT=$(command -v git)
  export DEV_PROJECT="$HOME/project"
  export TX_LOG="$HOME/transaction.log"
  export TX_OBSERVATIONS="$HOME/observations"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 "$DEV_PROJECT" "$TX_OBSERVATIONS" "$TMPDIR"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "transaction-fixture"
dependencies = ["pre-commit>=1.0.0"]
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  cat > "$DEV_PROJECT/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/hooks
    rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1.0.0
    hooks:
      - id: fixture
EOF
  cp "$DEV_PROJECT/.pre-commit-config.yaml" "$HOME/original.hooks"
  chmod 640 "$DEV_PROJECT/pyproject.toml"
  cp "$DEV_PROJECT/pyproject.toml" "$HOME/original.pyproject"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv:%s\n' "$*" >> "$TX_LOG"
if [[ "$1" == lock ]]; then
  case "${TX_LOCK_MODE:-success}" in
    INT|TERM)
      # This PID belongs to this test's private Zsh child, never a group.
      kill -s "$TX_LOCK_MODE" "$TX_TEST_SHELL_PID"
      [[ "$TX_LOCK_MODE" == INT ]] && exit 130
      exit 143
      ;;
    return130) exit 130 ;;
    return143) exit 143 ;;
    fail) exit 1 ;;
    require-diff)
      grep -q '^.*-dependencies = \["pre-commit>=1.0.0"\]' "$TX_OBSERVATIONS/stderr" || exit 96
      grep -q '^.*+dependencies = \["pre-commit>=2.0.0"\]' "$TX_OBSERVATIONS/stderr" || exit 97
      ;;
  esac
fi
exit 0
EOF
  cat > "$TEST_MOCK_BIN/pre-commit" <<'EOF'
#!/usr/bin/env bash
printf 'hooks:%s\n' "$*" >> "$TX_LOG"
case "$1" in
  install-hooks)
    case "${TX_HOOK_INTERRUPT_STATUS:-0}" in
      130|143)
        printf '# changed during hook installation\n' >> .pre-commit-config.yaml
        exit "$TX_HOOK_INTERRUPT_STATUS"
        ;;
    esac
    exit 0
    ;;
  autoupdate|validate-config|install|run) exit 0 ;;
  *) exit 98 ;;
esac
EOF
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
printf 'git:%s\n' "$*" >> "$TX_LOG"
# This fixture never permits an ordinary Git transport or external diff.
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/pre-commit" "$TEST_MOCK_BIN/git"
}

teardown() {
  cleanup_sandbox
}

run_transaction() {
  run_zsh '
    source "$ZSH_CUSTOM/functions/dev-menu.zsh"
    cd "$DEV_PROJECT"
    export TX_TEST_SHELL_PID=$$
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }
    # Consent is simulated only for the later F4-23 integration seam; no real
    # terminal, upstream package or hook code is used by this fixture.
    _dev_confirm_ask() { return 0; }
    _dev_exact_project_python_tool_runner() { reply=("$TEST_MOCK_BIN/pre-commit"); }
  '"$1"
}

assert_exact_original() {
  cmp "$HOME/original.pyproject" "$DEV_PROJECT/pyproject.toml"
  [ "$(file_mode "$DEV_PROJECT/pyproject.toml")" = 640 ]
}

assert_lock_stopped() {
  grep -q '^uv:lock --upgrade-package pre-commit$' "$TX_LOG"
  ! grep -Eq '^(uv:sync|hooks:)' "$TX_LOG" || return 1
}

assert_planned_diff_private() {
  run run_transaction '
    _dev_update_file_fingerprint "$HOME/private-original" || return 91
    local original_id="$REPLY"
    _dev_update_file_fingerprint "$HOME/private-candidate" || return 92
    local candidate_id="$REPLY"
    _dev_update_show_planned_diff "$HOME/private-original" "$original_id" \
      "$HOME/private-candidate" "$candidate_id" \
      > "$TX_OBSERVATIONS/diff-data" 2> "$TX_OBSERVATIONS/diff-ui"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$TX_OBSERVATIONS/diff-data" ]
  grep -Fq -- '@@' "$TX_OBSERVATIONS/diff-ui"
  run grep -Eq -- 'ZdxOpaqueAlpha42|ZdxOpaqueBeta73' "$TX_OBSERVATIONS/diff-ui"
  [ "$status" -eq 1 ]
  grep -Fq -- '[redacted potentially sensitive diff line]' "$TX_OBSERVATIONS/diff-ui"
}

@test "dev transactions: planned diff withholds credential-bearing unchanged context" {
  cat > "$HOME/private-original" <<'TOML'
[project]
name = "demo"
dependencies = ["demo>=1.0.0"]
[tool.uv]
index-url = "https://fixture:ZdxOpaqueAlpha42@packages.example.invalid/simple?token=ZdxOpaqueBeta73"
TOML
  sed 's/demo>=1.0.0/demo>=2.0.0/' "$HOME/private-original" > "$HOME/private-candidate"
  chmod -- 600 "$HOME/private-original" "$HOME/private-candidate"
  assert_planned_diff_private
  grep -Fq -- 'demo>=1.0.0' "$TX_OBSERVATIONS/diff-ui"
  grep -Fq -- 'demo>=2.0.0' "$TX_OBSERVATIONS/diff-ui"
}

@test "dev transactions: planned diff withholds opaque URL credentials on changed lines" {
  cat > "$HOME/private-original" <<'TOML'
[project]
name = "demo"
dependencies = ["demo>=1.0.0", "other @ https://ZdxOpaqueAlpha42@packages.example.invalid/a.whl?x=ZdxOpaqueBeta73"]
TOML
  sed 's/demo>=1.0.0/demo>=2.0.0/' "$HOME/private-original" > "$HOME/private-candidate"
  chmod -- 600 "$HOME/private-original" "$HOME/private-candidate"
  assert_planned_diff_private
}

@test "dev transactions: actual INT during pre-commit locking restores the exact original" {
  export TX_LOCK_MODE=INT
  run run_transaction 'dev-update-precommit'
  [ "$status" -eq 130 ]
  assert_lock_stopped
  assert_exact_original
}

@test "dev transactions: actual TERM during pre-commit locking restores the exact original" {
  export TX_LOCK_MODE=TERM
  run run_transaction 'dev-update-precommit'
  [ "$status" -eq 143 ]
  assert_lock_stopped
  assert_exact_original
}

@test "dev transactions: a returned 130 from the lock preserves interruption and rollback" {
  export TX_LOCK_MODE=return130
  run run_transaction 'dev-update-precommit'
  [ "$status" -eq 130 ]
  assert_lock_stopped
  assert_exact_original
}

@test "dev transactions: a returned 143 from the lock preserves interruption and rollback" {
  export TX_LOCK_MODE=return143
  run run_transaction 'dev-update-precommit'
  [ "$status" -eq 143 ]
  assert_lock_stopped
  assert_exact_original
}

@test "dev transactions control: an ordinary failed lock keeps its existing exact rollback" {
  export TX_LOCK_MODE=fail
  run run_transaction 'dev-update-precommit'
  [ "$status" -eq 1 ]
  assert_lock_stopped
  assert_exact_original
}

@test "dev transactions: interruption remains visible when exact rollback fails" {
  export TX_LOCK_MODE=return143
  run run_transaction '
    _dev_update_rollback_pyproject() { return 1; }
    dev-update-precommit
  '
  [ "$status" -eq 143 ]
  [[ "$output" == *"rollback also failed"* ]]
  assert_lock_stopped
  grep -q 'pre-commit>=2.0.0' "$DEV_PROJECT/pyproject.toml"
}

@test "dev transactions: dependency preview shows the exact private diff outside Git" {
  run run_transaction 'dev-update-deps --dry-run > "$TX_OBSERVATIONS/stdout" 2> "$TX_OBSERVATIONS/stderr"'
  [ "$status" -eq 0 ]
  [ ! -s "$TX_OBSERVATIONS/stdout" ]
  grep -q -- '-dependencies = \["pre-commit>=1.0.0"\]' "$TX_OBSERVATIONS/stderr"
  grep -q -- '+dependencies = \["pre-commit>=2.0.0"\]' "$TX_OBSERVATIONS/stderr"
  assert_exact_original
  [ ! -e "$DEV_PROJECT/.dev-suite-backups" ]
  [ ! -e "$TX_LOG" ]
}

@test "dev transactions: dependency diff precedes consent and decline is passive" {
  run run_transaction '
    _dev_confirm_ask() {
      command grep -q -- "+dependencies =" "$TX_OBSERVATIONS/stderr" || return 2
      print -r -- reviewed > "$TX_OBSERVATIONS/decision"
      return 1
    }
    dev-update-deps > "$TX_OBSERVATIONS/stdout" 2> "$TX_OBSERVATIONS/stderr"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$TX_OBSERVATIONS/decision")" = reviewed ]
  assert_exact_original
  [ ! -e "$TX_LOG" ]
}

@test "dev transactions: the planned diff excludes unrelated index-to-worktree edits" {
  "$REAL_GIT" init --quiet "$DEV_PROJECT"
  "$REAL_GIT" -C "$DEV_PROJECT" add pyproject.toml
  perl -pi -e 's/transaction-fixture/already-edited/' "$DEV_PROJECT/pyproject.toml"
  run run_transaction 'dev-update-deps --yes > "$TX_OBSERVATIONS/stdout" 2> "$TX_OBSERVATIONS/stderr"'
  [ "$status" -eq 0 ]
  grep -q -- '+dependencies =' "$TX_OBSERVATIONS/stderr"
  ! grep -Eq '^[[:space:]]*[-+]name =' "$TX_OBSERVATIONS/stderr" || return 1
  ! grep -q '^git:' "$TX_LOG" || return 1
  grep -q 'name = "already-edited"' "$DEV_PROJECT/pyproject.toml"
}

@test "dev transactions: pre-commit package diff is visible before lock and publication" {
  export TX_LOCK_MODE=require-diff
  run run_transaction 'dev-update-precommit > "$TX_OBSERVATIONS/stdout" 2> "$TX_OBSERVATIONS/stderr"'
  [ "$status" -eq 0 ]
  [ ! -s "$TX_OBSERVATIONS/stdout" ]
  grep -q -- '+dependencies =' "$TX_OBSERVATIONS/stderr"
  ! grep -q '^git:' "$TX_LOG" || return 1
  grep -q 'pre-commit>=2.0.0' "$DEV_PROJECT/pyproject.toml"
}

write_git_inspector() {
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
prefix=()
while (($#)); do
  case "$1" in
    -c|-C|--git-dir|--work-tree) prefix+=("$1" "$2"); shift 2 ;;
    --no-pager) prefix+=("$1"); shift ;;
    ls-remote) shift; break ;;
    *) exit 95 ;;
  esac
done
[[ "${1:-}" == --tags && "${2:-}" == -- && $# == 3 ]] || exit 96
url="$3"
printf 'query:%s\n' "$url" >> "$TX_LOG"
"$REAL_GIT" "${prefix[@]}" config --get-urlmatch http.extraheader "$url" > "$TX_OBSERVATIONS/headers" 2> "$TX_OBSERVATIONS/config.err" || true
"$REAL_GIT" "${prefix[@]}" ls-remote --get-url -- "$url" > "$TX_OBSERVATIONS/url" 2> "$TX_OBSERVATIONS/url.err" || exit 97
printf '%040d\trefs/tags/v1.0.0\n' 1
EOF
  chmod +x "$TEST_MOCK_BIN/git"
}

assert_isolated_query() {
  [ "$(cat "$TX_OBSERVATIONS/url")" = https://github.com/actions/checkout ]
  ! grep -q '[^[:space:]]' "$TX_OBSERVATIONS/headers" || return 1
  grep -q 'refs/tags/v1.0.0' "$TX_OBSERVATIONS/tags"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "dev transactions: tag query ignores project headers and HTTPS rewrite rules offline" {
  write_git_inspector
  "$REAL_GIT" init --quiet "$DEV_PROJECT"
  "$REAL_GIT" -C "$DEV_PROJECT" config http.https://github.com/.extraheader 'AUTHORIZATION: fixture-local'
  "$REAL_GIT" -C "$DEV_PROJECT" config url.https://local-mirror.invalid/.insteadOf https://github.com/
  run run_transaction '_dev_actions_list_tags actions checkout "$TX_OBSERVATIONS/tags" "$TX_OBSERVATIONS/query.err"'
  [ "$status" -eq 0 ]
  assert_isolated_query
}

@test "dev transactions: tag query ignores HOME config includes and system configuration offline" {
  write_git_inspector
  "$REAL_GIT" config --file "$HOME/included.config" http.extraHeader 'AUTHORIZATION: fixture-global'
  "$REAL_GIT" config --file "$HOME/included.config" url.https://global-mirror.invalid/.insteadOf https://github.com/
  "$REAL_GIT" config --file "$HOME/.gitconfig" include.path "$HOME/included.config"
  export TX_SYSTEM_CONFIG="$HOME/included.config"
  run run_transaction '
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    export GIT_CONFIG_SYSTEM="$TX_SYSTEM_CONFIG" GIT_CONFIG_NOSYSTEM=0
    _dev_actions_list_tags actions checkout "$TX_OBSERVATIONS/tags" "$TX_OBSERVATIONS/query.err"
  '
  [ "$status" -eq 0 ]
  assert_isolated_query
}

@test "dev transactions: tag query clears injected Git environment configuration offline" {
  write_git_inspector
  "$REAL_GIT" init --quiet "$DEV_PROJECT"
  run run_transaction '
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="AUTHORIZATION: fixture-env"
    export GIT_CONFIG_KEY_1=url.https://environment-mirror.invalid/.insteadOf
    export GIT_CONFIG_VALUE_1=https://github.com/
    export GIT_DIR="$DEV_PROJECT/.git" GIT_WORK_TREE="$DEV_PROJECT"
    _dev_actions_list_tags actions checkout "$TX_OBSERVATIONS/tags" "$TX_OBSERVATIONS/query.err"
  '
  [ "$status" -eq 0 ]
  assert_isolated_query
}

@test "dev transactions: a readonly inherited Git configuration cannot authorize a query" {
  write_git_inspector
  run run_transaction '
    export GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="AUTHORIZATION: fixture-readonly"
    typeset -rx GIT_CONFIG_COUNT=1
    _dev_actions_list_tags actions checkout "$TX_OBSERVATIONS/tags" "$TX_OBSERVATIONS/query.err"
  '
  [ "$status" -eq 1 ]
  [ ! -e "$TX_LOG" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "dev transactions control: an ordinary public tag query stays usable and restores caller HOME" {
  write_git_inspector
  run run_transaction '
    local original_home="$HOME"
    _dev_actions_list_tags actions checkout "$TX_OBSERVATIONS/tags" "$TX_OBSERVATIONS/query.err" || return $?
    [[ "$HOME" == "$original_home" ]]
  '
  [ "$status" -eq 0 ]
  assert_isolated_query
}

@test "dev transactions: workspace revalidation refuses a newly writable ancestor" {
  mkdir -m 700 "$HOME/ancestor" "$HOME/ancestor/tmp"
  export TMPDIR="$HOME/ancestor/tmp"
  run run_transaction '
    _dev_update_workspace_create || return 90
    local -a frozen=("${reply[@]}")
    command chmod -- 777 "$HOME/ancestor" || return 91
    _dev_update_workspace_validate "${frozen[@]}"
  '
  [ "$status" -eq 1 ]
}

@test "dev transactions: PyPI cache revalidation refuses a newly writable ancestor" {
  mkdir -m 700 "$HOME/ancestor" "$HOME/ancestor/tmp"
  export TMPDIR="$HOME/ancestor/tmp"
  run run_transaction '
    _dev_pypi_cache_init || return 90
    command chmod -- 777 "$HOME/ancestor" || return 91
    _dev_pypi_cache_validate
  '
  [ "$status" -eq 1 ]
}

@test "dev transactions control: a trusted canonical temporary root remains usable" {
  run run_transaction '
    _dev_update_workspace_create || return 90
    local -a frozen=("${reply[@]}")
    _dev_update_workspace_validate "${frozen[@]}" || return 91
    _dev_update_workspace_cleanup "${frozen[@]}" || return 92
    _dev_pypi_cache_init || return 93
    _dev_pypi_cache_validate || return 94
    _dev_pypi_cache_cleanup
  '
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "dev transactions: tag query clears legacy Git configuration parameters offline" {
  write_git_inspector
  export GIT_CONFIG_PARAMETERS="'http.extraheader=AUTHORIZATION: fixture-parameters' 'url.https://parameters-mirror.invalid/.insteadOf=https://github.com/'"
  run run_transaction '_dev_actions_list_tags actions checkout "$TX_OBSERVATIONS/tags" "$TX_OBSERVATIONS/query.err"'
  [ "$status" -eq 0 ]
  assert_isolated_query
}

@test "dev transactions: tag query cannot write an inherited Git trace file" {
  write_git_inspector
  export GIT_TRACE2_EVENT="$HOME/ambient-trace.json"
  run run_transaction '_dev_actions_list_tags actions checkout "$TX_OBSERVATIONS/tags" "$TX_OBSERVATIONS/query.err"'
  [ "$status" -eq 0 ]
  assert_isolated_query
  [ ! -e "$HOME/ambient-trace.json" ]
}

assert_interrupted_config_preserved() {
  local snapshot
  snapshot=$(find "$TMPDIR" -type f -name pre-commit-config.original)
  [ -n "$snapshot" ]
  cmp "$HOME/original.hooks" "$snapshot"
  grep -q '# changed during hook installation' "$DEV_PROJECT/.pre-commit-config.yaml"
  ! grep -Eq '^hooks:(install --install-hooks|run )' "$TX_LOG" || return 1
}

@test "dev transactions: interrupted 130 hook installation retains concurrent-edit recovery" {
  export TX_HOOK_INTERRUPT_STATUS=130
  run run_transaction 'dev-update-precommit'
  [ "$status" -eq 130 ]
  assert_interrupted_config_preserved
}

@test "dev transactions: interrupted 143 hook installation retains concurrent-edit recovery" {
  export TX_HOOK_INTERRUPT_STATUS=143
  run run_transaction 'dev-update-precommit'
  [ "$status" -eq 143 ]
  assert_interrupted_config_preserved
}

@test "dev transactions: concurrent tag-query cleanup keeps distinct owned quarantines" {
  write_git_inspector
  export REAL_MV
  REAL_MV=$(command -v mv)
  printf 'unrelated private canary\n' > "$TMPDIR/untouched-canary"
  chmod 600 "$TMPDIR/untouched-canary"
  local canary_identity
  canary_identity=$(file_identity "$TMPDIR/untouched-canary")
  cat > "$TEST_MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
shopt -s nullglob
[[ $# == 3 && "$1" == -- && "$2" == "$TMPDIR"/zdx-dev-update.* \
  && "$3" == "$TMPDIR"/.zdx-dev-update.cleanup.* && -d "$2" && ! -L "$2" ]] || exit 99
name="${2##*/}"
printf '%s\n' "$3" >> "$TX_OBSERVATIONS/quarantine.targets"
: > "$TX_OBSERVATIONS/ready.$name"
wait_for_two() {
  local phase="$1" attempt
  local -a records
  for ((attempt=0; attempt<1000; attempt++)); do
    records=("$TX_OBSERVATIONS/$phase."*)
    ((${#records[@]} >= 2)) && return 0
    sleep 0.01
  done
  return 98
}
wait_for_two ready || exit $?
"$REAL_MV" "$@" || exit $?
: > "$TX_OBSERVATIONS/moved.$name"
wait_for_two moved
EOF
  chmod +x "$TEST_MOCK_BIN/mv"
  run run_transaction '
    local -a query_pids=()
    local query_index query_rc
    for query_index in a b; do
      (
        RANDOM=1729
        query_rc=0
        _dev_actions_list_tags actions checkout \
          "$TX_OBSERVATIONS/tags.$query_index" "$TX_OBSERVATIONS/err.$query_index" \
          || query_rc=$?
        print -r -- "$query_rc" > "$TX_OBSERVATIONS/status.$query_index"
      ) &
      query_pids+=($!)
    done
    for query_index in "${query_pids[@]}"; do
      wait "$query_index" || return $?
    done
  '
  [ "$status" -eq 0 ]
  [ "$(file_identity "$TMPDIR/untouched-canary")" = "$canary_identity" ]
  [ "$(file_mode "$TMPDIR/untouched-canary")" = 600 ]
  [ "$(cat "$TMPDIR/untouched-canary")" = 'unrelated private canary' ]
  printf 'Unrelated private canary identity preserved: %s\n' "$canary_identity"
  [ "$(cat "$TX_OBSERVATIONS/status.a")" = 0 ]
  [ "$(cat "$TX_OBSERVATIONS/status.b")" = 0 ]
  [ "$(sort -u "$TX_OBSERVATIONS/quarantine.targets" | wc -l | tr -d ' ')" = 2 ]
}
