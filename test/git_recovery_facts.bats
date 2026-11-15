#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export RECOVERY_FACTS_GIT
  RECOVERY_FACTS_GIT=$(type -P git)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
  export GIT_ALLOW_PROTOCOL=file GIT_PAGER=cat PAGER=cat TERM=dumb NO_COLOR=1
  export GIT_AUTHOR_NAME='Recovery Facts Test' GIT_AUTHOR_EMAIL='recovery-facts@example.invalid'
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  unset RECOVERY_FACTS_STACK_MODE RECOVERY_FACTS_FSCK_MODE RECOVERY_FACTS_LIMIT
  export RECOVERY_FACTS_CASE="$HOME/case"
  mkdir -p "$RECOVERY_FACTS_CASE"
}

teardown() {
  cleanup_sandbox
}

recovery_facts_repo() {
  export RECOVERY_FACTS_WORK="$1"
  "$RECOVERY_FACTS_GIT" init -q -b main "$RECOVERY_FACTS_WORK"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" config core.hooksPath /dev/null
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" config commit.gpgSign false
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" config gc.auto 0
  printf 'base\n' >"$RECOVERY_FACTS_WORK/base.txt"
  printf 'before\n' >"$RECOVERY_FACTS_WORK/a.txt"
  printf 'before\n' >"$RECOVERY_FACTS_WORK/b.txt"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" add -A
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" commit -q -m base
}

recovery_facts_git_capture() {
  local label="$1" result=0
  shift
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" "$@" \
    >"$RECOVERY_FACTS_CASE/$label.stdout" 2>"$RECOVERY_FACTS_CASE/$label.stderr" || result=$?
  printf '%s\n' "$result" >"$RECOVERY_FACTS_CASE/$label.status"
}

recovery_facts_unborn_fixture() {
  recovery_facts_repo "$RECOVERY_FACTS_CASE/seed"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" rev-parse HEAD >"$RECOVERY_FACTS_CASE/seed.oid"
  "$RECOVERY_FACTS_GIT" init -q --bare -b main "$RECOVERY_FACTS_CASE/remote.git"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" remote add origin "$RECOVERY_FACTS_CASE/remote.git"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" push -q origin main
  export RECOVERY_FACTS_WORK="$RECOVERY_FACTS_CASE/work"
  "$RECOVERY_FACTS_GIT" init -q -b main "$RECOVERY_FACTS_WORK"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" config core.hooksPath /dev/null
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" config commit.gpgSign false
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" remote add origin "$RECOVERY_FACTS_CASE/remote.git"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" fetch -q origin
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" config branch.main.remote origin
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" config branch.main.merge refs/heads/main
  recovery_facts_git_capture absent-head rev-parse --verify --quiet 'HEAD^{commit}'
  recovery_facts_git_capture absent-main show-ref --verify --quiet refs/heads/main
  recovery_facts_git_capture symbolic-head symbolic-ref --quiet HEAD
  recovery_facts_git_capture fetched-upstream rev-parse --verify 'refs/remotes/origin/main^{commit}'
  recovery_facts_git_capture upstream-name rev-parse --abbrev-ref '@{upstream}'
  [ "$(cat "$RECOVERY_FACTS_CASE/absent-head.status")" -eq 1 ]
  [ ! -s "$RECOVERY_FACTS_CASE/absent-head.stdout" ]
  [ ! -s "$RECOVERY_FACTS_CASE/absent-head.stderr" ]
  [ "$(cat "$RECOVERY_FACTS_CASE/absent-main.status")" -eq 1 ]
  [ "$(cat "$RECOVERY_FACTS_CASE/symbolic-head.status")" -eq 0 ]
  [ "$(cat "$RECOVERY_FACTS_CASE/symbolic-head.stdout")" = refs/heads/main ]
  [ "$(cat "$RECOVERY_FACTS_CASE/fetched-upstream.status")" -eq 0 ]
  cmp "$RECOVERY_FACTS_CASE/seed.oid" "$RECOVERY_FACTS_CASE/fetched-upstream.stdout"
  [ "$(cat "$RECOVERY_FACTS_CASE/upstream-name.status")" -eq 0 ]
  [ "$(cat "$RECOVERY_FACTS_CASE/upstream-name.stdout")" = origin/main ]
}

recovery_facts_status_modes() {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$RECOVERY_FACTS_WORK" || return 91
    git-status >"$RECOVERY_FACTS_CASE/text.stdout" 2>"$RECOVERY_FACTS_CASE/text.stderr"
    print -r -- "$?" >"$RECOVERY_FACTS_CASE/text.primary.status"
    git-status --json >"$RECOVERY_FACTS_CASE/json.stdout" 2>"$RECOVERY_FACTS_CASE/json.stderr"
    print -r -- "$?" >"$RECOVERY_FACTS_CASE/json.primary.status"
    return 0
  '
}

@test "git recovery facts: unborn HEAD with a fetched upstream succeeds in text and JSON" {
  recovery_facts_unborn_fixture
  recovery_facts_status_modes
  [ "$status" -eq 0 ]
  [ "$(cat "$RECOVERY_FACTS_CASE/json.primary.status")" -eq 0 ]
  jq -e '.schema == "zdx.git-status.v1" and .branch == "main" and .head == null
    and .detached == false and .upstream == "origin/main"
    and .ahead == null and .behind == null' "$RECOVERY_FACTS_CASE/json.stdout"
  [ ! -s "$RECOVERY_FACTS_CASE/text.stdout" ]
  [ "$(cat "$RECOVERY_FACTS_CASE/text.primary.status")" -eq 0 ]
  ! grep -Fq 'Unable to compare HEAD with its upstream.' "$RECOVERY_FACTS_CASE/text.stderr" || false
}

@test "git recovery facts: born HEAD still compares the fetched upstream" {
  recovery_facts_unborn_fixture
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" reset -q --hard refs/remotes/origin/main
  recovery_facts_status_modes
  [ "$status" -eq 0 ]
  [ "$(cat "$RECOVERY_FACTS_CASE/text.primary.status")" -eq 0 ]
  [ "$(cat "$RECOVERY_FACTS_CASE/json.primary.status")" -eq 0 ]
  [ ! -s "$RECOVERY_FACTS_CASE/text.stdout" ]
  jq -e '.head != null and .upstream == "origin/main" and .ahead == 0 and .behind == 0' \
    "$RECOVERY_FACTS_CASE/json.stdout"
}

recovery_facts_snapshot() {
  local label="$1"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" rev-parse HEAD >"$RECOVERY_FACTS_CASE/head.$label"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" symbolic-ref --quiet HEAD >"$RECOVERY_FACTS_CASE/symbolic.$label"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" for-each-ref --format='%(objectname)%09%(refname)' \
    >"$RECOVERY_FACTS_CASE/refs.$label"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" stash list --format=%H >"$RECOVERY_FACTS_CASE/stashes.$label"
}

recovery_facts_lost_commit() {
  printf 'ordinary lost work\n' >"$RECOVERY_FACTS_WORK/lost.txt"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" add -- lost.txt
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" commit -q -m 'ordinary lost work'
  export RECOVERY_FACTS_LOST_OID
  RECOVERY_FACTS_LOST_OID=$("$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" rev-parse HEAD)
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" reset -q --hard HEAD~1
}

recovery_facts_live_fixture() {
  recovery_facts_repo "$RECOVERY_FACTS_CASE/repository"
  # The legitimate lost commit is older than the visited live objects, so a
  # small existing list cap exposes filtering performed after truncation.
  recovery_facts_lost_commit
  local generation path root index_oid untracked_oid base_oid actual_root actual_base actual_index actual_untracked extra
  base_oid=$("$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" rev-parse HEAD)
  : >"$RECOVERY_FACTS_CASE/live-oids.expected"
  : >"$RECOVERY_FACTS_CASE/live-roots.expected"
  for generation in older newer; do
    path=a.txt
    [[ "$generation" == newer ]] && path=b.txt
    printf '%s staged\n' "$generation" >"$RECOVERY_FACTS_WORK/$path"
    "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" add -- "$path"
    printf '%s worktree\n' "$generation" >"$RECOVERY_FACTS_WORK/$path"
    printf '%s untracked\n' "$generation" >"$RECOVERY_FACTS_WORK/untracked-$generation"
    "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" stash push -qu -m "live $generation"
    root=$("$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" rev-parse refs/stash)
    index_oid=$("$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" rev-parse 'refs/stash^2')
    untracked_oid=$("$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" rev-parse 'refs/stash^3')
    printf '%s\n' "$root" >>"$RECOVERY_FACTS_CASE/live-roots.expected"
    printf '%s\n' "$root" "$index_oid" "$untracked_oid" >>"$RECOVERY_FACTS_CASE/live-oids.expected"
    "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" rev-list --parents -n 1 "$root" \
      >"$RECOVERY_FACTS_CASE/$generation.parents"
    read -r actual_root actual_base actual_index actual_untracked extra <"$RECOVERY_FACTS_CASE/$generation.parents"
    [ "$actual_root" = "$root" ]
    [ "$actual_base" = "$base_oid" ]
    [ "$actual_index" = "$index_oid" ]
    [ "$actual_untracked" = "$untracked_oid" ]
    [ -z "$extra" ]
  done
  local -A seen=()
  local oid
  while IFS= read -r oid; do
    [ -z "${seen[$oid]+present}" ]
    seen[$oid]=1
    [ "$("$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" cat-file -t "$oid")" = commit ]
    "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" switch -q --detach "$oid"
    "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" switch -q main
  done <"$RECOVERY_FACTS_CASE/live-oids.expected"
  [ "${#seen[@]}" -eq 6 ]
  printf 'dropped stash work\n' >"$RECOVERY_FACTS_WORK/a.txt"
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" stash push -q -m 'dropped recovery control'
  export RECOVERY_FACTS_DROPPED_OID RECOVERY_FACTS_PARTIAL_OID
  RECOVERY_FACTS_DROPPED_OID=$("$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" rev-parse refs/stash)
  "$RECOVERY_FACTS_GIT" -C "$RECOVERY_FACTS_WORK" stash drop -q 'stash@{0}'
  recovery_facts_git_capture reflog-before log --walk-reflogs --format=%H HEAD
  [ "$(cat "$RECOVERY_FACTS_CASE/reflog-before.status")" -eq 0 ]
  while IFS= read -r oid; do
    grep -Fxq "$oid" "$RECOVERY_FACTS_CASE/reflog-before.stdout"
    [ "$oid" != "$RECOVERY_FACTS_DROPPED_OID" ]
  done <"$RECOVERY_FACTS_CASE/live-oids.expected"
  grep -Fxq "$RECOVERY_FACTS_LOST_OID" "$RECOVERY_FACTS_CASE/reflog-before.stdout"
  ! grep -Fxq "$RECOVERY_FACTS_DROPPED_OID" "$RECOVERY_FACTS_CASE/reflog-before.stdout" || false
  recovery_facts_git_capture fsck-preflight fsck --connectivity-only --no-progress
  [ "$(cat "$RECOVERY_FACTS_CASE/fsck-preflight.status")" -eq 0 ]
  grep -Fxq "dangling commit $RECOVERY_FACTS_DROPPED_OID" "$RECOVERY_FACTS_CASE/fsck-preflight.stdout"
  recovery_facts_snapshot before
  [ "$(wc -l <"$RECOVERY_FACTS_CASE/stashes.before")" -eq 2 ]
  local older_root newer_root
  older_root=$(sed -n '1p' "$RECOVERY_FACTS_CASE/live-roots.expected")
  newer_root=$(sed -n '2p' "$RECOVERY_FACTS_CASE/live-roots.expected")
  [ "$(sed -n '1p' "$RECOVERY_FACTS_CASE/stashes.before")" = "$newer_root" ]
  [ "$(sed -n '2p' "$RECOVERY_FACTS_CASE/stashes.before")" = "$older_root" ]
  RECOVERY_FACTS_PARTIAL_OID="$newer_root"
}

# Actual collector stdout, stderr, backend status and returned producer status
# are retained separately. Failure modes never contact a remote or the host.
recovery_facts_install_recorders() {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == stash && "${2:-}" == list ]]; then
  printf '%s\0' "$@" >"$RECOVERY_FACTS_CASE/stack.args.nul"
  : >"$RECOVERY_FACTS_CASE/stack.stderr"
  result=0
  case "${RECOVERY_FACTS_STACK_MODE:-normal}" in
    partial-failure)
      printf '%s\n' "$RECOVERY_FACTS_PARTIAL_OID" >"$RECOVERY_FACTS_CASE/stack.stdout"
      printf 'injected stack enumeration failure\n' >"$RECOVERY_FACTS_CASE/stack.stderr"
      result=17
      ;;
    invalid-success) printf 'not-an-object-id\n' >"$RECOVERY_FACTS_CASE/stack.stdout" ;;
    normal)
      "$RECOVERY_FACTS_GIT" "$@" >"$RECOVERY_FACTS_CASE/stack.stdout" \
        2>"$RECOVERY_FACTS_CASE/stack.stderr" || result=$?
      ;;
    *) exit 96 ;;
  esac
  printf '%s\n' "$result" >"$RECOVERY_FACTS_CASE/stack.producer.status"
  printf 'reached\n' >"$RECOVERY_FACTS_CASE/stack.reached"
  cat "$RECOVERY_FACTS_CASE/stack.stdout"
  cat "$RECOVERY_FACTS_CASE/stack.stderr" >&2
  exit "$result"
fi
if [[ "${1:-}" == fsck ]]; then
  printf '%s\0' "$@" >"$RECOVERY_FACTS_CASE/fsck.args.nul"
  result=0
  "$RECOVERY_FACTS_GIT" "$@" >"$RECOVERY_FACTS_CASE/fsck.stdout" \
    2>"$RECOVERY_FACTS_CASE/fsck.stderr" || result=$?
  printf '%s\n' "$result" >"$RECOVERY_FACTS_CASE/fsck.backend.status"
  [[ "${RECOVERY_FACTS_FSCK_MODE:-normal}" == returned-failure ]] && result=17
  printf '%s\n' "$result" >"$RECOVERY_FACTS_CASE/fsck.producer.status"
  printf 'reached\n' >"$RECOVERY_FACTS_CASE/fsck.reached"
  cat "$RECOVERY_FACTS_CASE/fsck.stdout"
  cat "$RECOVERY_FACTS_CASE/fsck.stderr" >&2
  exit "$result"
fi
exec "$RECOVERY_FACTS_GIT" "$@"
MOCK
  cat >"$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
cat >"$RECOVERY_FACTS_CASE/recover.rows.tsv"
printf 'reached\n' >"$RECOVERY_FACTS_CASE/picker.reached"
exit 130
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git" "$TEST_MOCK_BIN/fzf"
}

recovery_facts_run_public() {
  export RECOVERY_FACTS_MODE="$1"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$RECOVERY_FACTS_WORK" || return 91
    _git_require_interactive() { return 0; }
    if [[ -n "${RECOVERY_FACTS_LIMIT:-}" ]]; then
      _GIT_BRANCH_LIST_LIMIT="$RECOVERY_FACTS_LIMIT"
    fi
    if [[ "$RECOVERY_FACTS_MODE" == deep ]]; then
      git-recover --deep
    else
      git-recover
    fi >"$RECOVERY_FACTS_CASE/command.stdout" 2>"$RECOVERY_FACTS_CASE/command.stderr"
    local -i result=$?
    print -r -- "$result" >"$RECOVERY_FACTS_CASE/command.primary.status"
    return "$result"
  '
  printf '%s\n' "$status" >"$RECOVERY_FACTS_CASE/zsh.status"
  recovery_facts_snapshot after
}

recovery_facts_rows_have() {
  grep -Fq $'\t'"$1"$'\t' "$RECOVERY_FACTS_CASE/recover.rows.tsv"
}

# Collect every exclusion outcome before asserting the aggregate. A missing
# row file is unrendered evidence, never proof that a live object was excluded.
recovery_facts_collect_rows() {
  local offered=0 oid state
  : >"$RECOVERY_FACTS_CASE/live-exclusion.results"
  if [[ ! -f "$RECOVERY_FACTS_CASE/recover.rows.tsv" ]]; then
    printf 'UNREACHED\n' >"$RECOVERY_FACTS_CASE/rows.status"
    return 0
  fi
  printf 'rendered\n' >"$RECOVERY_FACTS_CASE/rows.status"
  while IFS= read -r oid; do
    state=excluded
    if recovery_facts_rows_have "$oid"; then
      state=offered
      (( offered += 1 ))
    fi
    printf '%s\t%s\n' "$oid" "$state" >>"$RECOVERY_FACTS_CASE/live-exclusion.results"
  done <"$RECOVERY_FACTS_CASE/live-oids.expected"
  printf '%s\n' "$offered" >"$RECOVERY_FACTS_CASE/live.offered.count"
}

recovery_facts_assert_state() {
  cmp "$RECOVERY_FACTS_CASE/head.before" "$RECOVERY_FACTS_CASE/head.after" || return 1
  cmp "$RECOVERY_FACTS_CASE/symbolic.before" "$RECOVERY_FACTS_CASE/symbolic.after" || return 2
  cmp "$RECOVERY_FACTS_CASE/refs.before" "$RECOVERY_FACTS_CASE/refs.after" || return 3
  cmp "$RECOVERY_FACTS_CASE/stashes.before" "$RECOVERY_FACTS_CASE/stashes.after" || return 4
}

recovery_facts_assert_fsck() {
  local expected_producer_status="$1" value
  local backend_status producer_status argument_bytes recorded_bytes=0
  backend_status=$(cat "$RECOVERY_FACTS_CASE/fsck.backend.status") || return 1
  [ "$backend_status" -eq 0 ] || return 2
  producer_status=$(cat "$RECOVERY_FACTS_CASE/fsck.producer.status") || return 3
  [ "$producer_status" -eq "$expected_producer_status" ] || return 4
  local -a arguments=()
  while IFS= read -r -d '' value; do
    arguments+=("$value")
    (( recorded_bytes += ${#value} + 1 ))
  done <"$RECOVERY_FACTS_CASE/fsck.args.nul" || return 5
  [ -z "$value" ] || return 6
  argument_bytes=$(file_size "$RECOVERY_FACTS_CASE/fsck.args.nul") || return 7
  [ "$recorded_bytes" -eq "$argument_bytes" ] || return 8
  [ "${#arguments[@]}" -eq 3 ] || return 9
  [ "${arguments[0]}" = fsck ] || return 10
  [ "${arguments[1]}" = --connectivity-only ] || return 11
  [ "${arguments[2]}" = --no-progress ] || return 12
  grep -Fxq "dangling commit $RECOVERY_FACTS_DROPPED_OID" "$RECOVERY_FACTS_CASE/fsck.stdout" || return 13
}

recovery_facts_assert_live_excluded() {
  local mode="$1"
  recovery_facts_live_fixture
  recovery_facts_install_recorders
  recovery_facts_run_public "$mode"
  recovery_facts_collect_rows
  [ "$(cat "$RECOVERY_FACTS_CASE/zsh.status")" -eq 0 ] || return 11
  [ "$(cat "$RECOVERY_FACTS_CASE/command.primary.status")" -eq 0 ] || return 12
  [ ! -s "$RECOVERY_FACTS_CASE/command.stdout" ] || return 13
  [ -s "$RECOVERY_FACTS_CASE/picker.reached" ] || return 14
  recovery_facts_assert_state || return 15
  if [[ "$mode" == deep ]]; then
    recovery_facts_assert_fsck 0 || return 16
    recovery_facts_rows_have "$RECOVERY_FACTS_DROPPED_OID" || return 17
  fi
  recovery_facts_rows_have "$RECOVERY_FACTS_LOST_OID" || return 18
  [ "$(wc -l <"$RECOVERY_FACTS_CASE/live-exclusion.results")" -eq 6 ] || return 19
  [ "$(cat "$RECOVERY_FACTS_CASE/live.offered.count")" -eq 0 ] || return 20
  # This new producer is intentionally checked after the existing behavioral
  # oracle: the unmodified base never calls it and must not get a fake red.
  [ "$(cat "$RECOVERY_FACTS_CASE/stack.producer.status")" -eq 0 ] || return 21
  cmp "$RECOVERY_FACTS_CASE/stashes.before" "$RECOVERY_FACTS_CASE/stack.stdout" || return 22
}

@test "git recovery facts: normal recovery excludes six visited live stash objects" {
  recovery_facts_assert_live_excluded plain
}

@test "git recovery facts: deep recovery excludes live objects while retaining lost and dropped work" {
  recovery_facts_assert_live_excluded deep
}

@test "git recovery facts: live exclusions precede the candidate limit" {
  export RECOVERY_FACTS_LIMIT=2
  recovery_facts_assert_live_excluded plain
  [ "$(wc -l <"$RECOVERY_FACTS_CASE/recover.rows.tsv")" -le 2 ]
}

@test "git recovery facts: a healthy empty stash stack retains ordinary lost work" {
  recovery_facts_repo "$RECOVERY_FACTS_CASE/repository"
  recovery_facts_lost_commit
  recovery_facts_snapshot before
  [ ! -s "$RECOVERY_FACTS_CASE/stashes.before" ]
  recovery_facts_git_capture absent-stash show-ref --verify --quiet refs/stash
  [ "$(cat "$RECOVERY_FACTS_CASE/absent-stash.status")" -eq 1 ]
  recovery_facts_install_recorders
  recovery_facts_run_public plain
  [ "$(cat "$RECOVERY_FACTS_CASE/zsh.status")" -eq 0 ]
  [ "$(cat "$RECOVERY_FACTS_CASE/command.primary.status")" -eq 0 ]
  [ ! -s "$RECOVERY_FACTS_CASE/command.stdout" ]
  recovery_facts_rows_have "$RECOVERY_FACTS_LOST_OID"
  recovery_facts_assert_state
  if [[ -e "$RECOVERY_FACTS_CASE/stack.producer.status" ]]; then
    [ "$(cat "$RECOVERY_FACTS_CASE/stack.producer.status")" -eq 0 ]
    [ ! -s "$RECOVERY_FACTS_CASE/stack.stdout" ]
  fi
}

@test "git recovery facts: failed deep collection warns and retains the reflog control" {
  recovery_facts_live_fixture
  export RECOVERY_FACTS_FSCK_MODE=returned-failure
  recovery_facts_install_recorders
  recovery_facts_run_public deep
  [ "$(cat "$RECOVERY_FACTS_CASE/zsh.status")" -eq 0 ]
  [ "$(cat "$RECOVERY_FACTS_CASE/command.primary.status")" -eq 0 ]
  recovery_facts_assert_fsck 17
  recovery_facts_rows_have "$RECOVERY_FACTS_LOST_OID"
  grep -Fq 'git fsck reported problems (exit 17)' "$RECOVERY_FACTS_CASE/command.stderr"
  recovery_facts_assert_state
}

recovery_facts_assert_stack_refusal() {
  local mode="$1" producer_status="$2"
  recovery_facts_live_fixture
  export RECOVERY_FACTS_STACK_MODE="$mode"
  recovery_facts_install_recorders
  recovery_facts_run_public deep
  [ "$(cat "$RECOVERY_FACTS_CASE/zsh.status")" -eq 1 ] || return 11
  [ "$(cat "$RECOVERY_FACTS_CASE/command.primary.status")" -eq 1 ] || return 12
  [ "$(cat "$RECOVERY_FACTS_CASE/stack.producer.status")" -eq "$producer_status" ] || return 13
  [ -s "$RECOVERY_FACTS_CASE/stack.reached" ] || return 14
  [ ! -e "$RECOVERY_FACTS_CASE/picker.reached" ] || return 15
  [ ! -s "$RECOVERY_FACTS_CASE/command.stdout" ] || return 16
  recovery_facts_assert_state || return 17
}

@test "git recovery facts: a failed partial live-stack enumeration refuses candidates" {
  recovery_facts_assert_stack_refusal partial-failure 17
}

@test "git recovery facts: malformed successful live-stack data refuses candidates" {
  recovery_facts_assert_stack_refusal invalid-success 0
}
