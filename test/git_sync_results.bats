#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export SYNC_RESULTS_GIT
  SYNC_RESULTS_GIT=$(type -P git)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
  export GIT_ALLOW_PROTOCOL=file GIT_PAGER=cat PAGER=cat TERM=dumb NO_COLOR=1
  export GIT_AUTHOR_NAME='Sync Results Test'
  export GIT_AUTHOR_EMAIL='sync-results@example.invalid'
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  unset SYNC_RESULTS_FAIL_AT SYNC_RESULTS_FAIL_RC SYNC_RESULTS_PROBE_FAILURE
  unset SYNC_RESULTS_NATIVE_PUSH SYNC_RESULTS_CAS_RACE SYNC_RESULTS_AFTER_AUTH
  unset SYNC_RESULTS_FORCE_PROBE_FAILURE
  unset SYNC_RESULTS_PROMOTE_RC
  unset SYNC_RESULTS_POST_PUSH_STAGE SYNC_RESULTS_POST_PUSH_RC
}

teardown() {
  cleanup_sandbox
}

# Real Git commands are limited to the current test's disposable file remote.
sync_results_pair() {
  export SYNC_RESULTS_CASE="$HOME/$1"
  export SYNC_RESULTS_REMOTE="$SYNC_RESULTS_CASE/remote.git"
  export SYNC_RESULTS_WORK="$SYNC_RESULTS_CASE/work"
  mkdir -p "$SYNC_RESULTS_CASE"
  "$SYNC_RESULTS_GIT" init -q --bare -b main "$SYNC_RESULTS_REMOTE"
  "$SYNC_RESULTS_GIT" init -q -b main "$SYNC_RESULTS_WORK"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config core.hooksPath /dev/null
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config commit.gpgSign false
  printf 'base\n' >"$SYNC_RESULTS_WORK/tracked.txt"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" add -- tracked.txt
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" commit -q -m base
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" remote add origin "$SYNC_RESULTS_REMOTE"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" push -qu origin main
  "$SYNC_RESULTS_GIT" --git-dir="$SYNC_RESULTS_REMOTE" for-each-ref \
    --format='%(objectname)%09%(refname)' >"$SYNC_RESULTS_CASE/remote.before"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD \
    >"$SYNC_RESULTS_CASE/head.before"
}

sync_results_prune_fixture() {
  sync_results_pair "$1"
  local peer="$SYNC_RESULTS_CASE/peer"
  "$SYNC_RESULTS_GIT" clone -q "$SYNC_RESULTS_REMOTE" "$peer"
  "$SYNC_RESULTS_GIT" -C "$peer" config core.hooksPath /dev/null
  "$SYNC_RESULTS_GIT" -C "$peer" config commit.gpgSign false
  printf 'remote change\n' >"$peer/tracked.txt"
  "$SYNC_RESULTS_GIT" -C "$peer" commit -qam 'remote change'
  "$SYNC_RESULTS_GIT" -C "$peer" push -q origin \
    main main:refs/heads/b1 main:refs/heads/b2
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" for-each-ref \
    --format='%(objectname)%09%(refname)' refs/remotes/origin \
    >"$SYNC_RESULTS_CASE/tracking.before"
}

sync_results_record_tracking_after() {
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" for-each-ref \
    --format='%(objectname)%09%(refname)' refs/remotes/origin \
    >"$SYNC_RESULTS_CASE/tracking.after"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" for-each-ref \
    --format='%(objectname)%09%(refname)' refs/zdx-suite/fetch \
    >"$SYNC_RESULTS_CASE/fetch.refs.after"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD \
    >"$SYNC_RESULTS_CASE/head.after"
}

# This sender signals only its still-waiting owned Zsh parent, synchronously
# after real local Git wrote the temporary refs. It creates no background job.
sync_results_install_fetch_interrupt() {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == fetch ]]; then
  "$SYNC_RESULTS_GIT" "$@" || exit "$?"
  "$SYNC_RESULTS_GIT" for-each-ref --format='%(objectname)%09%(refname)' \
    refs/zdx-suite/fetch >"$SYNC_RESULTS_CASE/fetch.refs.before-interrupt" || exit 96
  printf '%s\n' "$SYNC_RESULTS_SIGNAL:$SYNC_RESULTS_FAIL_RC" \
    >"$SYNC_RESULTS_CASE/fetch.interrupt.reached"
  if [[ "$SYNC_RESULTS_SIGNAL" != returned ]]; then
    kill "-$SYNC_RESULTS_SIGNAL" "$SYNC_RESULTS_SHELL_PID" || exit 95
  fi
  exit "$SYNC_RESULTS_FAIL_RC"
fi
exec "$SYNC_RESULTS_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}

sync_results_assert_fetch_interrupt() {
  export SYNC_RESULTS_FETCH_MODE="$1" SYNC_RESULTS_SIGNAL="$2"
  export SYNC_RESULTS_FAIL_RC="$3"
  sync_results_prune_fixture "fetch-$1-$2"
  sync_results_install_fetch_interrupt
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$SYNC_RESULTS_WORK" || return 91
    export SYNC_RESULTS_SHELL_PID=$$
    local -a action=(git-pull --remote origin --yes)
    if [[ "$SYNC_RESULTS_FETCH_MODE" == prune ]]; then
      action+=(--fetch-prune)
    else
      action+=(--ref refs/heads/main --fetch)
    fi
    "${action[@]}" >"$SYNC_RESULTS_CASE/command.stdout" \
      2>"$SYNC_RESULTS_CASE/command.stderr"
    local -i result=$?
    print -r -- "$result" >"$SYNC_RESULTS_CASE/command.primary.status"
    return "$result"
  '
  local actual_status="$status"
  printf '%s\n' "$actual_status" >"$SYNC_RESULTS_CASE/zsh.status"
  sync_results_record_tracking_after
  [ "$actual_status" -eq "$SYNC_RESULTS_FAIL_RC" ] || return 11
  [ "$(cat "$SYNC_RESULTS_CASE/fetch.interrupt.reached")" = \
    "$SYNC_RESULTS_SIGNAL:$SYNC_RESULTS_FAIL_RC" ] || return 12
  local expected_refs=1
  [[ "$SYNC_RESULTS_FETCH_MODE" == prune ]] && expected_refs=3
  [ "$(wc -l <"$SYNC_RESULTS_CASE/fetch.refs.before-interrupt")" -eq "$expected_refs" ] || return 13
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ] || return 14
  cmp "$SYNC_RESULTS_CASE/tracking.before" "$SYNC_RESULTS_CASE/tracking.after" || return 15
  cmp "$SYNC_RESULTS_CASE/head.before" "$SYNC_RESULTS_CASE/head.after" || return 16
  [ ! -s "$SYNC_RESULTS_CASE/fetch.refs.after" ] || return 17
}

@test "git sync results: fetch-prune cleans owned refs after synchronous INT" {
  sync_results_assert_fetch_interrupt prune INT 130
}

@test "git sync results: fetch-prune cleans owned refs after synchronous TERM" {
  sync_results_assert_fetch_interrupt prune TERM 143
}

@test "git sync results: a returned fetch-prune interruption already cleans owned refs" {
  sync_results_assert_fetch_interrupt prune returned 130
}

@test "git sync results: exact fetch retains its existing INT cleanup" {
  sync_results_assert_fetch_interrupt exact INT 130
}

@test "git sync results: exact fetch retains its existing TERM cleanup" {
  sync_results_assert_fetch_interrupt exact TERM 143
}

sync_results_install_push_recorder() {
  export SYNC_RESULTS_PUSH_LOG="$SYNC_RESULTS_CASE/push.calls"
  : >"$SYNC_RESULTS_PUSH_LOG"
  : >"$SYNC_RESULTS_CASE/push.args.nul"
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "${SYNC_RESULTS_POST_PUSH_STAGE:-}" && -s "$SYNC_RESULTS_PUSH_LOG" ]]; then
  matched=0
  case "$SYNC_RESULTS_POST_PUSH_STAGE" in
    local-ref)
      [[ "${1:-}" == rev-parse && "${2:-}" == --verify \
        && "${3:-}" == 'refs/heads/main^{object}' ]] && matched=1
      ;;
    push-url)
      [[ "${1:-}" == remote && "${2:-}" == get-url \
        && "${3:-}" == --push && "${4:-}" == --all ]] && matched=1
      ;;
    tracking-ref)
      if [[ "${1:-}" == for-each-ref ]]; then
        for argument in "$@"; do
          [[ "$argument" == refs/remotes/origin/main ]] && matched=1
        done
      fi
      ;;
    configuration)
      if [[ "${1:-}" == branch ]]; then
        for argument in "$@"; do
          if [[ "$argument" == --set-upstream-to=* ]]; then
            printf '%s\n' "$argument" >>"$SYNC_RESULTS_CASE/upstream.config.calls"
            matched=1
          fi
        done
      fi
      ;;
  esac
  if [[ "$matched" == 1 ]]; then
    printf '%s\n' "$SYNC_RESULTS_POST_PUSH_STAGE:$SYNC_RESULTS_POST_PUSH_RC" \
      >"$SYNC_RESULTS_CASE/post-push.failure.reached"
    exit "$SYNC_RESULTS_POST_PUSH_RC"
  fi
fi
if [[ "${1:-}" == push ]]; then
  printf '%s\n' "${!#}" >>"$SYNC_RESULTS_PUSH_LOG"
  printf '%s\0' "$@" >>"$SYNC_RESULTS_CASE/push.args.nul"
  count=0
  while IFS= read -r record; do (( count += 1 )); done <"$SYNC_RESULTS_PUSH_LOG"
  if [[ "$count" -eq "${SYNC_RESULTS_FAIL_AT:-0}" ]]; then
    printf '%s\n' "$count:$SYNC_RESULTS_FAIL_RC" \
      >"$SYNC_RESULTS_CASE/push.failure.reached"
    if [[ "${SYNC_RESULTS_NATIVE_PUSH:-}" == INT || "${SYNC_RESULTS_NATIVE_PUSH:-}" == TERM ]]; then
      kill "-$SYNC_RESULTS_NATIVE_PUSH" "$SYNC_RESULTS_SHELL_PID" || exit 95
    fi
    exit "$SYNC_RESULTS_FAIL_RC"
  fi
elif [[ "${1:-}" == ls-remote && "${!#}" == refs/heads/b2 \
  && "${SYNC_RESULTS_PROBE_FAILURE:-0}" == 1 && -s "$SYNC_RESULTS_PUSH_LOG" ]]; then
  printf '%s\n' "refs/heads/b2:$SYNC_RESULTS_FAIL_RC" \
    >"$SYNC_RESULTS_CASE/probe.failure.reached"
  exit "$SYNC_RESULTS_FAIL_RC"
elif [[ "${1:-}" == update-ref && "${2:-}" == --no-deref \
  && "${SYNC_RESULTS_CAS_RACE:-0}" == 1 ]]; then
  for argument in "$@"; do
    if [[ "$argument" == refs/remotes/origin/main ]]; then
      "$SYNC_RESULTS_GIT" update-ref --no-deref refs/remotes/origin/main \
        "$SYNC_RESULTS_OTHER_OID" || exit 94
      printf '%s\n' "$SYNC_RESULTS_OTHER_OID" >"$SYNC_RESULTS_CASE/cas.race.reached"
      break
    fi
  done
elif [[ "${1:-}" == update-ref && "${2:-}" == --no-deref \
  && "${SYNC_RESULTS_PROMOTE_RC:-0}" != 0 ]]; then
  for argument in "$@"; do
    if [[ "$argument" == refs/remotes/origin/main ]]; then
      printf '%s\n' "$SYNC_RESULTS_PROMOTE_RC" >"$SYNC_RESULTS_CASE/promotion.failure.reached"
      exit "$SYNC_RESULTS_PROMOTE_RC"
    fi
  done
elif [[ "${1:-}" == --no-replace-objects && "${2:-}" == merge-base \
  && "${SYNC_RESULTS_FORCE_PROBE_FAILURE:-0}" == 1 && -s "$SYNC_RESULTS_PUSH_LOG" ]]; then
  printf '%s\n' 'merge-base:124' >"$SYNC_RESULTS_CASE/force.probe.failure.reached"
  exit 124
elif [[ "${1:-}" == branch ]]; then
  for argument in "$@"; do
    if [[ "$argument" == --set-upstream-to=* ]]; then
      printf '%s\n' "$argument" >>"$SYNC_RESULTS_CASE/upstream.config.calls"
    fi
  done
fi
exec "$SYNC_RESULTS_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}

sync_results_run_push() {
  export SYNC_RESULTS_PUSH_MODE="$1"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$SYNC_RESULTS_WORK" || return 91
    export SYNC_RESULTS_SHELL_PID=$$
    if [[ -n "${SYNC_RESULTS_AFTER_AUTH:-}" ]]; then
      _git_sync_authorize() {
        (( $1 )) || return 93
        case "$SYNC_RESULTS_AFTER_AUTH" in
          tracking)
            command git update-ref --no-deref refs/remotes/origin/main "$SYNC_RESULTS_OTHER_OID" || return 94
            ;;
          symbolic)
            command git symbolic-ref refs/remotes/origin/main refs/remotes/origin/other || return 94
            ;;
          url)
            command git remote set-url --push origin "$SYNC_RESULTS_CASE/alternate.git" || return 94
            ;;
          oid)
            command git update-ref refs/heads/main "$SYNC_RESULTS_OTHER_OID" || return 94
            ;;
          root)
            cd "$SYNC_RESULTS_CASE/other" || return 94
            ;;
          *) return 95 ;;
        esac
        print -r -- "$SYNC_RESULTS_AFTER_AUTH" >"$SYNC_RESULTS_CASE/authorization.changed.reached"
        return 0
      }
    fi
    local -a action=(git-push --remote origin)
    case "$SYNC_RESULTS_PUSH_MODE" in
      dry) action+=(--dry-run) ;;
      yes) action+=(--yes) ;;
      force) action+=(--force-with-lease --yes) ;;
      upstream-dry) action+=(--set-upstream --dry-run) ;;
      upstream) action+=(--set-upstream --yes) ;;
      all|timed-all) action+=(--all --yes) ;;
      *) return 92 ;;
    esac
    if [[ "$SYNC_RESULTS_PUSH_MODE" == timed-all ]]; then
      _timed "git:git-push" "${action[@]}" \
        >"$SYNC_RESULTS_CASE/command.stdout" 2>"$SYNC_RESULTS_CASE/command.stderr"
    else
      "${action[@]}" >"$SYNC_RESULTS_CASE/command.stdout" \
        2>"$SYNC_RESULTS_CASE/command.stderr"
    fi
    local -i result=$?
    print -r -- "$result" >"$SYNC_RESULTS_CASE/command.primary.status"
    return "$result"
  '
  printf '%s\n' "$status" >"$SYNC_RESULTS_CASE/zsh.status"
}

sync_results_record_remote_after() {
  "$SYNC_RESULTS_GIT" --git-dir="$SYNC_RESULTS_REMOTE" for-each-ref \
    --format='%(objectname)%09%(refname)' >"$SYNC_RESULTS_CASE/remote.after"
}

sync_results_assert_equal_push() {
  sync_results_pair "equal-$1"
  sync_results_install_push_recorder
  sync_results_run_push "$1"
  local actual_status="$status"
  printf '%s\n' "$actual_status" >"$SYNC_RESULTS_CASE/zsh.status"
  sync_results_record_remote_after
  [ "$actual_status" -eq 0 ] || return 11
  [ "$(cat "$SYNC_RESULTS_CASE/command.primary.status")" -eq 0 ] || return 12
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ] || return 13
  cmp "$SYNC_RESULTS_CASE/remote.before" "$SYNC_RESULTS_CASE/remote.after" || return 14
  [ ! -s "$SYNC_RESULTS_PUSH_LOG" ] || return 15
  ! grep -Eq 'Ref updates:[[:space:]]*1|1 ref update' \
    "$SYNC_RESULTS_CASE/command.stderr" || return 16
}

@test "git sync results: an equal current-branch dry run plans no ref update" {
  sync_results_assert_equal_push dry
}

@test "git sync results: an equal current branch is current without a push" {
  sync_results_assert_equal_push yes
}

@test "git sync results: an equal force-with-lease branch is current without a push" {
  sync_results_assert_equal_push force
}

@test "git sync results: an equal all-branches push already has an empty plan" {
  sync_results_assert_equal_push all
}

sync_results_upstream_fixture() {
  sync_results_pair "$1"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --remove-section branch.main
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --local --list \
    >"$SYNC_RESULTS_CASE/config.before"
  sync_results_install_push_recorder
}

@test "git sync results: equal-ref upstream dry run plans configuration honestly" {
  sync_results_upstream_fixture upstream-dry
  sync_results_run_push upstream-dry
  [ "$status" -eq 0 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --local --list \
    >"$SYNC_RESULTS_CASE/config.after"
  cmp "$SYNC_RESULTS_CASE/config.before" "$SYNC_RESULTS_CASE/config.after"
  [ ! -s "$SYNC_RESULTS_PUSH_LOG" ]
  ! grep -Eq 'Ref updates:[[:space:]]*1|1 ref update' \
    "$SYNC_RESULTS_CASE/command.stderr" || false
  grep -Eiq 'upstream (configuration|setting)|configure.*upstream' \
    "$SYNC_RESULTS_CASE/command.stderr"
}

@test "git sync results: equal-ref upstream execution configures without claiming a ref update" {
  sync_results_upstream_fixture upstream-yes
  sync_results_run_push upstream
  local actual_status="$status"
  sync_results_record_remote_after
  [ "$actual_status" -eq 0 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.remote)" = origin ]
  [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.merge)" = refs/heads/main ]
  cmp "$SYNC_RESULTS_CASE/remote.before" "$SYNC_RESULTS_CASE/remote.after"
  ! grep -Eq 'Ref updates:[[:space:]]*1|1 ref update' \
    "$SYNC_RESULTS_CASE/command.stderr" || false
  grep -Eiq 'upstream (configuration|configured|setting)|configured.*upstream' \
    "$SYNC_RESULTS_CASE/command.stderr"
}

@test "git sync results: a changed current branch still publishes its exact ref" {
  sync_results_pair changed
  printf 'local change\n' >"$SYNC_RESULTS_WORK/tracked.txt"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" commit -qam 'local change'
  sync_results_install_push_recorder
  sync_results_run_push yes
  [ "$status" -eq 0 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  [ "$(wc -l <"$SYNC_RESULTS_PUSH_LOG")" -eq 1 ]
  [ "$("$SYNC_RESULTS_GIT" --git-dir="$SYNC_RESULTS_REMOTE" rev-parse refs/heads/main)" = \
    "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)" ]
  grep -Eq 'Ref updates:[[:space:]]*1' "$SYNC_RESULTS_CASE/command.stderr"
  grep -Fq 'Push complete: 1 ref update.' "$SYNC_RESULTS_CASE/command.stderr"
}

sync_results_batch_fixture() {
  sync_results_pair "$1"
  local target
  for target in b1 b2 b3; do
    "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" branch "$target"
  done
  sync_results_install_push_recorder
}

# External return statuses are injected; these cases do not claim native
# signal delivery. The call log and remote refs prove which writes ran.
sync_results_assert_push_interruption() {
  export SYNC_RESULTS_FAIL_RC="$1" SYNC_RESULTS_FAIL_AT="$2"
  export SYNC_RESULTS_PROBE_FAILURE="${3:-0}"
  sync_results_batch_fixture "batch-$1-$2-$SYNC_RESULTS_PROBE_FAILURE"
  sync_results_run_push all
  local actual_status="$status"
  printf '%s\n' "$actual_status" >"$SYNC_RESULTS_CASE/zsh.status"
  sync_results_record_remote_after
  [ "$actual_status" -eq "$SYNC_RESULTS_FAIL_RC" ] || return 11
  if [[ -z "${SYNC_RESULTS_NATIVE_PUSH:-}" || -e "$SYNC_RESULTS_CASE/command.primary.status" ]]; then
    [ "$(cat "$SYNC_RESULTS_CASE/command.primary.status")" -eq "$SYNC_RESULTS_FAIL_RC" ] || return 12
  fi
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ] || return 13
  local expected_calls="$SYNC_RESULTS_FAIL_AT" first_unrun
  if [[ "$SYNC_RESULTS_PROBE_FAILURE" == 1 ]]; then
    expected_calls=1
    first_unrun=2
    [ "$(cat "$SYNC_RESULTS_CASE/probe.failure.reached")" = \
      "refs/heads/b2:$SYNC_RESULTS_FAIL_RC" ] || return 14
  else
    first_unrun=$(( SYNC_RESULTS_FAIL_AT + 1 ))
    [ "$(cat "$SYNC_RESULTS_CASE/push.failure.reached")" = \
      "$SYNC_RESULTS_FAIL_AT:$SYNC_RESULTS_FAIL_RC" ] || return 15
  fi
  [ "$(wc -l <"$SYNC_RESULTS_PUSH_LOG")" -eq "$expected_calls" ] || return 16
  local index remote_oid
  for index in 1 2 3; do
    remote_oid=$("$SYNC_RESULTS_GIT" --git-dir="$SYNC_RESULTS_REMOTE" \
      for-each-ref --format='%(objectname)' "refs/heads/b$index")
    if (( index < first_unrun && (SYNC_RESULTS_PROBE_FAILURE == 1 || index < SYNC_RESULTS_FAIL_AT) )); then
      [ -n "$remote_oid" ] || return 17
    else
      [ -z "$remote_oid" ] || return 18
    fi
  done
  for (( index=first_unrun; index<=3; index++ )); do
    grep -Eq "refs/heads/b${index}.*not run|not run.*refs/heads/b${index}" \
      "$SYNC_RESULTS_CASE/command.stderr" || return 19
  done
}

@test "git sync results: first push returning 130 lists later exact refs" {
  sync_results_assert_push_interruption 130 1
}

@test "git sync results: second push returning 130 lists later exact refs" {
  sync_results_assert_push_interruption 130 2
}

@test "git sync results: first push returning 143 lists later exact refs" {
  sync_results_assert_push_interruption 143 1
}

@test "git sync results: second push returning 143 lists later exact refs" {
  sync_results_assert_push_interruption 143 2
}

@test "git sync results: interrupted remote revalidation lists the current and later unrun refs" {
  sync_results_assert_push_interruption 130 0 1
}

@test "git sync results: terminated remote revalidation lists the current and later unrun refs" {
  sync_results_assert_push_interruption 143 0 1
}

@test "git sync results: mixed push outcomes mark the timer as partial failure" {
  export SYNC_RESULTS_FAIL_RC=23 SYNC_RESULTS_FAIL_AT=2
  sync_results_batch_fixture mixed
  sync_results_run_push timed-all
  local actual_status="$status"
  sync_results_record_remote_after
  [ "$actual_status" -eq 1 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  [ "$(wc -l <"$SYNC_RESULTS_PUSH_LOG")" -eq 3 ]
  grep -q 'refs/heads/b1$' "$SYNC_RESULTS_CASE/remote.after"
  grep -q 'refs/heads/b3$' "$SYNC_RESULTS_CASE/remote.after"
  ! grep -q 'refs/heads/b2$' "$SYNC_RESULTS_CASE/remote.after" || false
  grep -Fq 'completed with partial failures' "$SYNC_RESULTS_CASE/command.stderr"
}

@test "git sync results: fetch-prune dry run counts all three tracking changes" {
  sync_results_prune_fixture prune-count
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$SYNC_RESULTS_WORK" || return 91
    git-pull --remote origin --fetch-prune --dry-run \
      >"$SYNC_RESULTS_CASE/command.stdout" 2>"$SYNC_RESULTS_CASE/command.stderr"
    local -i result=$?
    print -r -- "$result" >"$SYNC_RESULTS_CASE/command.primary.status"
    return "$result"
  '
  local actual_status="$status"
  printf '%s\n' "$actual_status" >"$SYNC_RESULTS_CASE/zsh.status"
  sync_results_record_tracking_after
  [ "$actual_status" -eq 0 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  cmp "$SYNC_RESULTS_CASE/tracking.before" "$SYNC_RESULTS_CASE/tracking.after"
  cmp "$SYNC_RESULTS_CASE/head.before" "$SYNC_RESULTS_CASE/head.after"
  [ ! -s "$SYNC_RESULTS_CASE/fetch.refs.after" ]
  grep -Eq 'Tracking changes:[[:space:]]*3' "$SYNC_RESULTS_CASE/command.stderr"
  grep -Eq 'Dry run: 3 .* planned; nothing was ' "$SYNC_RESULTS_CASE/command.stderr"
}

@test "git sync results: push repository facts abbreviate fixture HOME" {
  sync_results_pair push-path
  printf 'local change\n' >"$SYNC_RESULTS_WORK/tracked.txt"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" commit -qam 'local change'
  sync_results_install_push_recorder
  sync_results_run_push dry
  [ "$status" -eq 0 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  grep -Eq 'Repository:[[:space:]]+~/push-path/work$' "$SYNC_RESULTS_CASE/command.stderr"
}

@test "git sync results: fetch repository facts abbreviate fixture HOME" {
  sync_results_pair pull-path
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$SYNC_RESULTS_WORK" || return 91
    git-pull --remote origin --fetch --dry-run \
      >"$SYNC_RESULTS_CASE/command.stdout" 2>"$SYNC_RESULTS_CASE/command.stderr"
    local -i result=$?
    print -r -- "$result" >"$SYNC_RESULTS_CASE/command.primary.status"
    return "$result"
  '
  printf '%s\n' "$status" >"$SYNC_RESULTS_CASE/zsh.status"
  [ "$status" -eq 0 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  grep -Eq 'Repository:[[:space:]]+~/pull-path/work$' "$SYNC_RESULTS_CASE/command.stderr"
}

sync_results_upstream_tracking_fixture() {
  local state="$1"
  sync_results_upstream_fixture "upstream-tracking-$state"
  export SYNC_RESULTS_OLD_TRACKING
  SYNC_RESULTS_OLD_TRACKING=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  case "$state" in
    absent)
      "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" update-ref -d refs/remotes/origin/main
      SYNC_RESULTS_OLD_TRACKING=absent
      ;;
    stale)
      printf 'another local change\n' >"$SYNC_RESULTS_WORK/tracked.txt"
      "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" commit -qam 'another local change'
      "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" push -q origin main
      "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" update-ref \
        refs/remotes/origin/main "$SYNC_RESULTS_OLD_TRACKING"
      ;;
    *) return 81 ;;
  esac
  "$SYNC_RESULTS_GIT" --git-dir="$SYNC_RESULTS_REMOTE" for-each-ref \
    --format='%(objectname)%09%(refname)' >"$SYNC_RESULTS_CASE/remote.before"
}

sync_results_assert_tracking_promotion() {
  sync_results_upstream_tracking_fixture "$1"
  local wanted_oid
  wanted_oid=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  sync_results_run_push upstream
  local actual_status="$status"
  sync_results_record_remote_after
  [ "$actual_status" -eq 0 ] || return 11
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ] || return 12
  [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse refs/remotes/origin/main)" = "$wanted_oid" ] || return 13
  [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.remote)" = origin ] || return 14
  [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.merge)" = refs/heads/main ] || return 15
  cmp "$SYNC_RESULTS_CASE/remote.before" "$SYNC_RESULTS_CASE/remote.after" || return 16
  grep -Fq "Local tracking ref refs/remotes/origin/main: $SYNC_RESULTS_OLD_TRACKING -> $wanted_oid" \
    "$SYNC_RESULTS_CASE/command.stderr" || return 17
  [ ! -s "$SYNC_RESULTS_PUSH_LOG" ] || return 18
}

@test "git sync results: upstream-only plans and creates an absent tracking ref" {
  sync_results_assert_tracking_promotion absent
}

@test "git sync results: upstream-only plans and leases a stale tracking ref" {
  sync_results_assert_tracking_promotion stale
}

sync_results_other_oid() {
  local current_oid tree_oid
  current_oid=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  tree_oid=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse 'HEAD^{tree}')
  export SYNC_RESULTS_OTHER_OID
  SYNC_RESULTS_OTHER_OID=$(printf 'fixture callback commit\n' | \
    "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" commit-tree "$tree_oid" -p "$current_oid")
}

@test "git sync results: a concurrent tracking change wins against the upstream promotion lease" {
  sync_results_upstream_tracking_fixture stale
  sync_results_other_oid
  export SYNC_RESULTS_CAS_RACE=1
  sync_results_run_push upstream
  local actual_status="$status"
  sync_results_record_remote_after
  [ "$actual_status" -eq 1 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  [ "$(cat "$SYNC_RESULTS_CASE/cas.race.reached")" = "$SYNC_RESULTS_OTHER_OID" ]
  [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse refs/remotes/origin/main)" = "$SYNC_RESULTS_OTHER_OID" ]
  cmp "$SYNC_RESULTS_CASE/remote.before" "$SYNC_RESULTS_CASE/remote.after"
  run "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.remote
  [ "$status" -eq 1 ]
}

@test "git sync results: upstream-only refuses an initially symbolic tracking ref" {
  sync_results_upstream_fixture upstream-initial-alias
  local original_oid
  original_oid=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" update-ref refs/remotes/origin/other "$original_oid"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" symbolic-ref \
    refs/remotes/origin/main refs/remotes/origin/other
  sync_results_run_push upstream
  [ "$status" -eq 1 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  [ ! -s "$SYNC_RESULTS_PUSH_LOG" ]
  [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" symbolic-ref refs/remotes/origin/main)" = refs/remotes/origin/other ]
  [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse refs/remotes/origin/other)" = "$original_oid" ]
  run "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.remote
  [ "$status" -eq 1 ]
}

sync_results_assert_upstream_after_auth_change() {
  export SYNC_RESULTS_AFTER_AUTH="$1"
  sync_results_upstream_fixture "upstream-after-auth-$1"
  sync_results_other_oid
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" update-ref \
    refs/remotes/origin/other "$SYNC_RESULTS_OTHER_OID"
  if [[ "$1" == root ]]; then
    "$SYNC_RESULTS_GIT" init -q -b main "$SYNC_RESULTS_CASE/other"
    "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_CASE/other" config core.hooksPath /dev/null
    "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_CASE/other" config commit.gpgSign false
    "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_CASE/other" commit -q --allow-empty -m other
  fi
  sync_results_run_push upstream
  local actual_status="$status"
  sync_results_record_remote_after
  [ "$actual_status" -eq 1 ] || return 11
  [ "$(cat "$SYNC_RESULTS_CASE/authorization.changed.reached")" = "$1" ] || return 12
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ] || return 13
  [ ! -s "$SYNC_RESULTS_PUSH_LOG" ] || return 14
  cmp "$SYNC_RESULTS_CASE/remote.before" "$SYNC_RESULTS_CASE/remote.after" || return 15
  case "$1" in
    tracking)
      [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse refs/remotes/origin/main)" = "$SYNC_RESULTS_OTHER_OID" ] || return 16
      ;;
    symbolic)
      [ "$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" symbolic-ref refs/remotes/origin/main)" = refs/remotes/origin/other ] || return 17
      ;;
  esac
  run "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.remote
  [ "$status" -eq 1 ] || return 18
}

@test "git sync results: upstream-only keeps a tracking OID changed after authorization" {
  sync_results_assert_upstream_after_auth_change tracking
}

@test "git sync results: upstream-only keeps a tracking alias installed after authorization" {
  sync_results_assert_upstream_after_auth_change symbolic
}

@test "git sync results: upstream-only refuses a push URL changed after authorization" {
  sync_results_assert_upstream_after_auth_change url
}

@test "git sync results: upstream-only refuses a local OID changed after authorization" {
  sync_results_assert_upstream_after_auth_change oid
}

@test "git sync results: upstream-only refuses a repository changed after authorization" {
  sync_results_assert_upstream_after_auth_change root
}

@test "git sync results: native INT during the first push lists later exact refs" {
  export SYNC_RESULTS_NATIVE_PUSH=INT
  sync_results_assert_push_interruption 130 1
}

@test "git sync results: native TERM during the second push lists later exact refs" {
  export SYNC_RESULTS_NATIVE_PUSH=TERM
  sync_results_assert_push_interruption 143 2
}

@test "git sync results: a timed-out remote revalidation preserves 124 and stops later pushes" {
  export SYNC_RESULTS_FAIL_RC=124 SYNC_RESULTS_FAIL_AT=0 SYNC_RESULTS_PROBE_FAILURE=1
  sync_results_batch_fixture timeout-revalidation
  sync_results_run_push all
  local actual_status="$status"
  sync_results_record_remote_after
  [ "$actual_status" -eq 124 ]
  [ "$(cat "$SYNC_RESULTS_CASE/command.primary.status")" -eq 124 ]
  [ "$(cat "$SYNC_RESULTS_CASE/probe.failure.reached")" = refs/heads/b2:124 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  [ "$(wc -l <"$SYNC_RESULTS_PUSH_LOG")" -eq 1 ]
  grep -q 'refs/heads/b1$' "$SYNC_RESULTS_CASE/remote.after"
  ! grep -Eq 'refs/heads/b[23]$' "$SYNC_RESULTS_CASE/remote.after" || false
}

@test "git sync results: a force-lease ancestry timeout preserves 124 after completed work" {
  sync_results_pair force-ancestry-timeout
  export SYNC_RESULTS_BEFORE_OID SYNC_RESULTS_DESIRED_OID
  SYNC_RESULTS_BEFORE_OID=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" push -q origin \
    main:refs/heads/b1 main:refs/heads/b2
  printf 'local change\n' >"$SYNC_RESULTS_WORK/tracked.txt"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" commit -qam 'local change'
  SYNC_RESULTS_DESIRED_OID=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" branch b1
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" branch b2
  export SYNC_RESULTS_FORCE_PROBE_FAILURE=1
  sync_results_install_push_recorder
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$SYNC_RESULTS_WORK" || return 91
    local first_record="refs/heads/b1"$'"'"'\t'"'"'"$SYNC_RESULTS_DESIRED_OID"$'"'"'\t'"'"'"refs/heads/b1"$'"'"'\t'"'"'"$SYNC_RESULTS_BEFORE_OID"
    local second_record="refs/heads/b2"$'"'"'\t'"'"'"$SYNC_RESULTS_DESIRED_OID"$'"'"'\t'"'"'"refs/heads/b2"$'"'"'\t'"'"'"$SYNC_RESULTS_BEFORE_OID"
    _git_push_apply_plan force origin "$SYNC_RESULTS_REMOTE" "$first_record" "$second_record" \
      >"$SYNC_RESULTS_CASE/command.stdout" 2>"$SYNC_RESULTS_CASE/command.stderr"
    local -i result=$?
    print -r -- "$result" >"$SYNC_RESULTS_CASE/command.primary.status"
    return "$result"
  '
  printf '%s\n' "$status" >"$SYNC_RESULTS_CASE/zsh.status"
  [ "$status" -eq 124 ]
  [ "$(cat "$SYNC_RESULTS_CASE/command.primary.status")" -eq 124 ]
  [ "$(cat "$SYNC_RESULTS_CASE/force.probe.failure.reached")" = merge-base:124 ]
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ]
  [ "$(wc -l <"$SYNC_RESULTS_PUSH_LOG")" -eq 1 ]
  [ "$("$SYNC_RESULTS_GIT" --git-dir="$SYNC_RESULTS_REMOTE" rev-parse refs/heads/b1)" = "$SYNC_RESULTS_DESIRED_OID" ]
  [ "$("$SYNC_RESULTS_GIT" --git-dir="$SYNC_RESULTS_REMOTE" rev-parse refs/heads/b2)" = "$SYNC_RESULTS_BEFORE_OID" ]
  grep -Fq 'Push stopped (exit 124): 1 ref update completed.' "$SYNC_RESULTS_CASE/command.stderr"
  ! grep -Fq 'remote query timed out' "$SYNC_RESULTS_CASE/command.stderr" || false
}

sync_results_assert_upstream_promotion_interrupted() {
  sync_results_upstream_tracking_fixture "$1"
  export SYNC_RESULTS_PROMOTE_RC="$2"
  sync_results_run_push upstream
  local actual_status="$status"
  [ "$actual_status" -eq "$SYNC_RESULTS_PROMOTE_RC" ] || return 11
  [ "$(cat "$SYNC_RESULTS_CASE/command.primary.status")" -eq "$SYNC_RESULTS_PROMOTE_RC" ] || return 12
  [ "$(cat "$SYNC_RESULTS_CASE/promotion.failure.reached")" -eq "$SYNC_RESULTS_PROMOTE_RC" ] || return 13
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ] || return 14
  [ ! -e "$SYNC_RESULTS_CASE/upstream.config.calls" ] || return 15
  [ ! -s "$SYNC_RESULTS_PUSH_LOG" ] || return 16
  grep -Fq "Tracking-ref promotion stopped (exit $SYNC_RESULTS_PROMOTE_RC)." \
    "$SYNC_RESULTS_CASE/command.stderr" || return 20
  ! grep -Fq 'The tracking ref changed' "$SYNC_RESULTS_CASE/command.stderr" || return 21
  local actual_tracking
  actual_tracking=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" for-each-ref \
    --format='%(objectname)' refs/remotes/origin/main)
  if [[ "$SYNC_RESULTS_OLD_TRACKING" == absent ]]; then
    [ -z "$actual_tracking" ] || return 17
  else
    [ "$actual_tracking" = "$SYNC_RESULTS_OLD_TRACKING" ] || return 18
  fi
  run "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.remote
  [ "$status" -eq 1 ] || return 19
}

@test "git sync results: interrupted absent tracking promotion preserves 130 without configuring upstream" {
  sync_results_assert_upstream_promotion_interrupted absent 130
}

@test "git sync results: terminated stale tracking promotion preserves 143 without configuring upstream" {
  sync_results_assert_upstream_promotion_interrupted stale 143
}

# This is the public changed-branch path: a real push succeeds before the
# auxiliary promotion reports its configured backend status. The return and
# remote/configuration observations are saved independently of that value.
sync_results_assert_published_upstream_promotion_failure() {
  local injected_status="$1" expected_status="$2"
  sync_results_upstream_fixture "published-upstream-$injected_status"
  local before_oid desired_oid
  before_oid=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  printf 'published local change\n' >"$SYNC_RESULTS_WORK/tracked.txt"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" commit -qam 'published local change'
  desired_oid=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  export SYNC_RESULTS_PROMOTE_RC="$injected_status"
  sync_results_run_push upstream
  local actual_status="$status"
  sync_results_record_remote_after
  "$SYNC_RESULTS_GIT" --git-dir="$SYNC_RESULTS_REMOTE" rev-parse refs/heads/main \
    >"$SYNC_RESULTS_CASE/published.oid"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --local --list \
    >"$SYNC_RESULTS_CASE/config.after"
  [ "$actual_status" -eq "$expected_status" ] || return 11
  [ "$(cat "$SYNC_RESULTS_CASE/command.primary.status")" -eq "$expected_status" ] || return 12
  [ "$(cat "$SYNC_RESULTS_CASE/promotion.failure.reached")" -eq "$injected_status" ] || return 13
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ] || return 14
  [ "$(wc -l <"$SYNC_RESULTS_PUSH_LOG")" -eq 1 ] || return 15
  [ "$before_oid" != "$desired_oid" ] || return 16
  [ "$(cat "$SYNC_RESULTS_CASE/published.oid")" = "$desired_oid" ] || return 17
  [ ! -e "$SYNC_RESULTS_CASE/upstream.config.calls" ] || return 18
  run "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.remote
  [ "$status" -eq 1 ] || return 19
  ! grep -Eq 'The tracking ref changed|the tracking ref changed locally' \
    "$SYNC_RESULTS_CASE/command.stderr" || return 20
  ! grep -Fq 'remote query timed out' "$SYNC_RESULTS_CASE/command.stderr" || return 23
  if [[ "$injected_status" == 17 ]]; then
    grep -Fq 'Remote push succeeded, but promotion failed.' \
      "$SYNC_RESULTS_CASE/command.stderr" || return 21
  else
    grep -Fq "Remote push succeeded, but promotion stopped (exit $injected_status)." \
      "$SYNC_RESULTS_CASE/command.stderr" || return 22
  fi
}

@test "git sync results: published upstream promotion preserves backend 124" {
  sync_results_assert_published_upstream_promotion_failure 124 124
}

@test "git sync results: published upstream promotion preserves backend 130" {
  sync_results_assert_published_upstream_promotion_failure 130 130
}

@test "git sync results: published upstream promotion preserves backend 143" {
  sync_results_assert_published_upstream_promotion_failure 143 143
}

@test "git sync results: published upstream promotion maps ordinary backend 17 to 1 honestly" {
  sync_results_assert_published_upstream_promotion_failure 17 1
}

sync_results_assert_post_push_boundary() {
  local stage="$1" injected_status="$2" expected_status="$3"
  sync_results_upstream_fixture "post-push-$stage-$injected_status"
  local before_oid desired_oid stage_label=""
  before_oid=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  printf 'post-push boundary change\n' >"$SYNC_RESULTS_WORK/tracked.txt"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" commit -qam 'post-push boundary change'
  desired_oid=$("$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" rev-parse HEAD)
  export SYNC_RESULTS_POST_PUSH_STAGE="$stage" SYNC_RESULTS_POST_PUSH_RC="$injected_status"
  sync_results_run_push upstream
  local actual_status="$status"
  sync_results_record_remote_after
  "$SYNC_RESULTS_GIT" --git-dir="$SYNC_RESULTS_REMOTE" rev-parse refs/heads/main \
    >"$SYNC_RESULTS_CASE/published.oid"
  "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --local --list \
    >"$SYNC_RESULTS_CASE/config.after"
  [ "$actual_status" -eq "$expected_status" ] || return 11
  [ "$(cat "$SYNC_RESULTS_CASE/command.primary.status")" -eq "$expected_status" ] || return 12
  [ "$(cat "$SYNC_RESULTS_CASE/post-push.failure.reached")" = "$stage:$injected_status" ] || return 13
  [ ! -s "$SYNC_RESULTS_CASE/command.stdout" ] || return 14
  [ "$(wc -l <"$SYNC_RESULTS_PUSH_LOG")" -eq 1 ] || return 15
  [ "$before_oid" != "$desired_oid" ] || return 16
  [ "$(cat "$SYNC_RESULTS_CASE/published.oid")" = "$desired_oid" ] || return 17
  if [[ "$stage" == configuration ]]; then
    [ "$(wc -l <"$SYNC_RESULTS_CASE/upstream.config.calls")" -eq 1 ] || return 18
  else
    [ ! -e "$SYNC_RESULTS_CASE/upstream.config.calls" ] || return 19
  fi
  run "$SYNC_RESULTS_GIT" -C "$SYNC_RESULTS_WORK" config --get branch.main.remote
  [ "$status" -eq 1 ] || return 20
  ! grep -Eq 'the local branch moved|the push URL changed|the tracking ref changed|remote query timed out' \
    "$SYNC_RESULTS_CASE/command.stderr" || return 21
  case "$stage" in
    local-ref) stage_label='local branch inspection' ;;
    push-url) stage_label='push URL inspection' ;;
    tracking-ref) stage_label='tracking-ref inspection' ;;
    configuration) stage_label='upstream configuration' ;;
    *) return 81 ;;
  esac
  if [[ "$injected_status" == 17 ]]; then
    if [[ "$stage" == tracking-ref ]]; then
      grep -Fq 'Remote push succeeded, but the tracking ref could not be inspected.' \
        "$SYNC_RESULTS_CASE/command.stderr" || return 22
    else
      grep -Fq "Remote push succeeded, but $stage_label failed." \
        "$SYNC_RESULTS_CASE/command.stderr" || return 23
    fi
  else
    grep -Fq "Remote push succeeded, but $stage_label stopped (exit $injected_status)." \
      "$SYNC_RESULTS_CASE/command.stderr" || return 24
  fi
}

@test "git sync results: published upstream local-ref inspection preserves 124" {
  sync_results_assert_post_push_boundary local-ref 124 124
}

@test "git sync results: published upstream local-ref inspection preserves 130" {
  sync_results_assert_post_push_boundary local-ref 130 130
}

@test "git sync results: published upstream local-ref inspection preserves 143" {
  sync_results_assert_post_push_boundary local-ref 143 143
}

@test "git sync results: published upstream local-ref inspection maps ordinary 17 honestly" {
  sync_results_assert_post_push_boundary local-ref 17 1
}

@test "git sync results: published upstream push-url inspection preserves 124" {
  sync_results_assert_post_push_boundary push-url 124 124
}

@test "git sync results: published upstream push-url inspection preserves 130" {
  sync_results_assert_post_push_boundary push-url 130 130
}

@test "git sync results: published upstream push-url inspection preserves 143" {
  sync_results_assert_post_push_boundary push-url 143 143
}

@test "git sync results: published upstream push-url inspection maps ordinary 17 honestly" {
  sync_results_assert_post_push_boundary push-url 17 1
}

@test "git sync results: published upstream tracking-ref inspection preserves 124" {
  sync_results_assert_post_push_boundary tracking-ref 124 124
}

@test "git sync results: published upstream tracking-ref inspection preserves 130" {
  sync_results_assert_post_push_boundary tracking-ref 130 130
}

@test "git sync results: published upstream tracking-ref inspection preserves 143" {
  sync_results_assert_post_push_boundary tracking-ref 143 143
}

@test "git sync results: published upstream tracking-ref inspection retains ordinary failure 1" {
  sync_results_assert_post_push_boundary tracking-ref 17 1
}

@test "git sync results: published upstream configuration preserves 124" {
  sync_results_assert_post_push_boundary configuration 124 124
}

@test "git sync results: published upstream configuration preserves 130" {
  sync_results_assert_post_push_boundary configuration 130 130
}

@test "git sync results: published upstream configuration preserves 143" {
  sync_results_assert_post_push_boundary configuration 143 143
}

@test "git sync results: published upstream configuration retains ordinary failure 1" {
  sync_results_assert_post_push_boundary configuration 17 1
}
