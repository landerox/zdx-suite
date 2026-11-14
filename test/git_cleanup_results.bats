#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export GIT_ALLOW_PROTOCOL=file
  export GIT_AUTHOR_NAME='Cleanup Test' GIT_AUTHOR_EMAIL=cleanup@example.invalid
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export CLEANUP_REAL_GIT
  CLEANUP_REAL_GIT=$(command -v git)
  export NO_COLOR=1
  CLEANUP_FAILURES=0
}

teardown() { cleanup_sandbox; }

# Keep the complete matrix observable even when the first assertion is red.
cleanup_check() {
  if "$@"; then return 0; fi
  printf 'Assertion failed:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  CLEANUP_FAILURES=$((CLEANUP_FAILURES + 1))
}

cleanup_reject() {
  if ! "$@"; then return 0; fi
  printf 'Unexpected match:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  CLEANUP_FAILURES=$((CLEANUP_FAILURES + 1))
}

cleanup_absent() {
  local observed_status=0
  "$@" 2>>"$CLEANUP_CASE/ref-observations.stderr" || observed_status=$?
  printf '%s: %s\n' "$*" "$observed_status" >>"$CLEANUP_CASE/ref-observations.status"
  cleanup_check test "$observed_status" -eq 1
}

cleanup_pair() {
  local name="${1:-pair}"
  export CLEANUP_REPO="$HOME/$name/repo" CLEANUP_REMOTE="$HOME/$name/remote.git"
  mkdir -p "$HOME/$name"
  "$CLEANUP_REAL_GIT" init -q --bare "$CLEANUP_REMOTE"
  "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" symbolic-ref HEAD refs/heads/main
  "$CLEANUP_REAL_GIT" init -q -b main "$CLEANUP_REPO"
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config commit.gpgSign false
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config core.hooksPath /dev/null
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" commit -q --allow-empty -m base
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" remote add origin "$CLEANUP_REMOTE"
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" push -q origin refs/heads/main
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" symbolic-ref \
    refs/remotes/origin/HEAD refs/remotes/origin/main
  export CLEANUP_CASE="$HOME/$name"
}

cleanup_status() {
  printf '%s\n' "$status" >"$CLEANUP_CASE/$1.status"
  printf '%s:%s\n' "$1" "$status" >&2
  cleanup_check test ! -s "$CLEANUP_CASE/$1.stdout"
}

cleanup_deny_mutation() {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  push|verify-tag|update-ref)
    printf '%s\n' "$*" >>"$CLEANUP_CASE/unexpected-mutation"
    exit 97 ;;
esac
exec "$CLEANUP_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}

@test "git cleanup results: explicit missing targets fail with empty and populated inventories" {
  cleanup_deny_mutation
  local population action
  for population in empty populated; do
    cleanup_pair "$population"
    if [[ "$population" == populated ]]; then
      "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch eligible
      "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" tag existing
      "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" push -q origin refs/heads/eligible
    fi
    for action in verify push delete local remote; do
      export CLEANUP_ACTION="$action"
      run run_zsh '
        cd "$CLEANUP_REPO" || return 90
        case "$CLEANUP_ACTION" in
          verify) git-tag-verify missing ;;
          push) git-tag-push --yes missing ;;
          delete) git-tag-delete --local-only --yes missing ;;
          local) clean-branches --yes missing ;;
          remote) clean-remote-merged --remote origin --yes missing ;;
        esac >"$CLEANUP_CASE/$CLEANUP_ACTION.stdout" 2>"$CLEANUP_CASE/$CLEANUP_ACTION.stderr"
      '
      cleanup_status "$action"
      cleanup_check test "$status" -eq 1
      cleanup_check grep -Fq missing "$CLEANUP_CASE/$action.stderr"
    done
    cleanup_check test ! -e "$CLEANUP_CASE/unexpected-mutation"
  done
  cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/existing
  cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet refs/heads/eligible
  cleanup_check test ! -s "$MOCK_FZF_ARGS_FILE"
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: unnamed empty inventories are successful without a picker or mutation" {
  cleanup_pair
  cleanup_deny_mutation
  local action
  for action in verify push delete local remote; do
    export CLEANUP_ACTION="$action"
    run run_zsh '
      cd "$CLEANUP_REPO" || return 90
      case "$CLEANUP_ACTION" in
        verify) git-tag-verify ;;
        push) git-tag-push --yes ;;
        delete) git-tag-delete --local-only --yes ;;
        local) clean-branches --yes ;;
        remote) clean-remote-merged --remote origin --yes ;;
      esac >"$CLEANUP_CASE/$CLEANUP_ACTION.stdout" 2>"$CLEANUP_CASE/$CLEANUP_ACTION.stderr"
    '
    cleanup_status "$action"
    cleanup_check test "$status" -eq 0
    cleanup_check grep -Eiq 'no (local tags|eligible merged)' "$CLEANUP_CASE/$action.stderr"
  done
  cleanup_check test ! -e "$CLEANUP_CASE/unexpected-mutation"
  cleanup_check test ! -s "$MOCK_FZF_ARGS_FILE"
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: retained branch configuration warns on target and verdict with status zero" {
  cleanup_pair
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch eligible
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config branch.eligible.merge refs/heads/eligible
  : >"$CLEANUP_REPO/.git/config.lock"
  run run_zsh '
    cd "$CLEANUP_REPO" || return 90
    clean-branches eligible --yes >"$CLEANUP_CASE/config.stdout" 2>"$CLEANUP_CASE/config.stderr"
  '
  cleanup_status config
  cleanup_check test "$status" -eq 0
  cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/eligible
  cleanup_check test "$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config --get branch.eligible.merge)" = refs/heads/eligible
  cleanup_check grep -Ei 'refs/heads/eligible.*(config|section).*(retain|warn|fail)' "$CLEANUP_CASE/config.stderr"
  cleanup_check grep -Ei 'Local cleanup.*(warning|configuration|section)' "$CLEANUP_CASE/config.stderr"
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: absent branch configuration is a quiet successful deletion" {
  cleanup_pair
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch eligible
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config branch.eligible.neighbor.description neighbor-config-canary
  run run_zsh '
    cd "$CLEANUP_REPO" || return 90
    clean-branches eligible --yes >"$CLEANUP_CASE/absent.stdout" 2>"$CLEANUP_CASE/absent.stderr"
  '
  cleanup_status absent
  cleanup_check test "$status" -eq 0
  cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/eligible
  cleanup_reject grep -Ei '(config|section).*(retain|warn|fail)' "$CLEANUP_CASE/absent.stderr"
  cleanup_check test "$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config --get branch.eligible.neighbor.description)" = neighbor-config-canary
  cleanup_reject grep -Fq neighbor-config-canary "$CLEANUP_CASE/absent.stderr"
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: failed configuration inspection is not a proven absent section" {
  cleanup_pair
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch eligible
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config branch.eligible.merge refs/heads/eligible
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == update-ref && "$*" == *' -d refs/heads/eligible '* ]]; then
  "$CLEANUP_REAL_GIT" "$@" || exit "$?"
  : >"$CLEANUP_CASE/branch-deleted"
  exit 0
fi
if [[ -e "$CLEANUP_CASE/branch-deleted" && "$1" == config ]]; then
  printf '%s\n' "$*" >>"$CLEANUP_CASE/config.calls"
  printf 'fatal: fixture configuration could not be read\n' >&2
  exit 17
fi
exec "$CLEANUP_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$CLEANUP_REPO" || return 90
    clean-branches eligible --yes >"$CLEANUP_CASE/config.stdout" 2>"$CLEANUP_CASE/config.stderr"
  '
  cleanup_status config
  cleanup_check test "$status" -eq 0
  cleanup_check test -e "$CLEANUP_CASE/branch-deleted"
  cleanup_check test -s "$CLEANUP_CASE/config.calls"
  cleanup_check test "$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config --get branch.eligible.merge)" = refs/heads/eligible
  cleanup_check grep -Ei 'refs/heads/eligible.*(config|section).*(unknown|inspect|read|verif|retain|warn|fail)' "$CLEANUP_CASE/config.stderr"
  cleanup_check grep -Ei 'Local cleanup.*(warning|configuration|section)' "$CLEANUP_CASE/config.stderr"
  cleanup_reject grep -Ei '(^|[[:space:]])(no|absent|missing)[[:space:]].*(config|section)' "$CLEANUP_CASE/config.stderr"
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: stopped branch configuration cleanup preserves status and lists later branches" {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == update-ref && "$*" == *' -d refs/heads/'* ]]; then
  printf '%s\n' "$*" >>"$CLEANUP_CASE/branch-delete.calls"
fi
if [[ "$1" == config && "$*" == *'--remove-section branch.one'* ]]; then
  printf '%s\n' "$*" >>"$CLEANUP_CASE/config.calls"
  printf 'fixture configuration removal stopped\n' >&2
  exit "$CLEANUP_CONFIG_STATUS"
fi
exec "$CLEANUP_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  local code
  for code in 124 130 143; do
    cleanup_pair "config-$code"
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch one
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch two
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch three
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config branch.one.description retained-config-canary
    export CLEANUP_CONFIG_STATUS="$code"
    run run_zsh '
      cd "$CLEANUP_REPO" || return 90
      clean-branches one two three --yes >"$CLEANUP_CASE/config.stdout" 2>"$CLEANUP_CASE/config.stderr"
    '
    cleanup_status config
    cleanup_check test "$status" -eq "$code"
    cleanup_check test "$(wc -l <"$CLEANUP_CASE/branch-delete.calls")" -eq 1
    cleanup_check test -s "$CLEANUP_CASE/config.calls"
    cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/one
    cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/two
    cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/three
    cleanup_check test "$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config --get branch.one.description)" = retained-config-canary
    cleanup_check grep -Ei '(refs/heads/two.*not run|not run.*refs/heads/two)' "$CLEANUP_CASE/config.stderr"
    cleanup_check grep -Ei '(refs/heads/three.*not run|not run.*refs/heads/three)' "$CLEANUP_CASE/config.stderr"
    cleanup_reject grep -Fq retained-config-canary "$CLEANUP_CASE/config.stderr"
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

# Every actual push uses the disposable file remote. Only one chosen push is
# replaced by a real external failure; completed pushes retain their effects.
cleanup_push_mock() {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == push ]]; then
  printf '%s\n' "$*" >>"$CLEANUP_CASE/push.calls"
  count=$(wc -l <"$CLEANUP_CASE/push.calls")
  if [[ "$count" -eq "$CLEANUP_STOP_AT" ]]; then
    printf 'fixture push stopped at target %s\n' "$count" >&2
    exit "$CLEANUP_PUSH_STATUS"
  fi
fi
exec "$CLEANUP_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}

cleanup_batch_fixture() {
  local action="$1" name="$2"
  cleanup_pair "$name"
  if [[ "$action" == remote || "$action" == local ]]; then
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch one
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch two
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch three
    if [[ "$action" == remote ]]; then
      "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" push -q origin refs/heads/one refs/heads/two refs/heads/three
    fi
  else
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" tag one
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" tag two
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" tag three
    if [[ "$action" == delete ]]; then
      "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" push -q origin refs/tags/one refs/tags/two refs/tags/three
    fi
  fi
  export CLEANUP_ACTION="$action"
}

cleanup_batch_run() {
  run run_zsh '
    cd "$CLEANUP_REPO" || return 90
    case "$CLEANUP_ACTION" in
      push) git-tag-push one two three --remote origin --yes ;;
      delete) git-tag-delete one two three --remote origin --delete-remote --yes ;;
      remote) clean-remote-merged one two three --remote origin --yes ;;
      local) clean-branches one two three --yes ;;
    esac >"$CLEANUP_CASE/batch.stdout" 2>"$CLEANUP_CASE/batch.stderr"
  '
  cleanup_status batch
}

cleanup_batch_interruptions() {
  local action="$1" code position ref_prefix pending
  if [[ "$action" == remote ]]; then ref_prefix=refs/heads; else ref_prefix=refs/tags; fi
  cleanup_push_mock
  for code in 130 143; do
    for position in 1 2; do
      cleanup_batch_fixture "$action" "$action-$code-$position"
      export CLEANUP_PUSH_STATUS="$code" CLEANUP_STOP_AT="$position"
      cleanup_batch_run
      cleanup_check test "$status" -eq "$code"
      cleanup_check test "$(wc -l <"$CLEANUP_CASE/push.calls")" -eq "$position"
      cleanup_check grep -Fq 'fixture push stopped' "$CLEANUP_CASE/batch.stderr"
      cleanup_check grep -Ei '(three.*not run|not run.*three)' "$CLEANUP_CASE/batch.stderr"
      if [[ "$position" == 1 ]]; then
        cleanup_check grep -Ei '(two.*not run|not run.*two)' "$CLEANUP_CASE/batch.stderr"
      else
        cleanup_check grep -Ei '(one.*(done|[Dd]eleted|[Pp]ushed)|(done|[Dd]eleted|[Pp]ushed).*one)' "$CLEANUP_CASE/batch.stderr"
      fi
      for pending in two three; do
        if [[ "$action" == push ]]; then
          cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$ref_prefix/$pending"
        else
          cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$ref_prefix/$pending"
        fi
        if [[ "$action" == delete ]]; then
          cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet "refs/tags/$pending"
        fi
      done
      if [[ "$action" == push && "$position" == 2 ]]; then
        cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$ref_prefix/one"
      elif [[ "$action" == push || "$position" == 2 ]]; then
        cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$ref_prefix/one"
      else
        cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$ref_prefix/one"
      fi
      if [[ "$action" == delete ]]; then
        if [[ "$position" == 2 ]]; then
          cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/one
        else
          cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/one
        fi
      fi
    done
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: interrupted tag publication lists every later target at 130 and 143" {
  cleanup_batch_interruptions push
}

@test "git cleanup results: interrupted remote tag deletion lists every later target at 130 and 143" {
  cleanup_batch_interruptions delete
}

@test "git cleanup results: interrupted remote branch cleanup lists every later target at 130 and 143" {
  cleanup_batch_interruptions remote
}

@test "git cleanup results: per-target observation failures preserve status and distinguish later not-run targets" {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
case " $* " in
  *' ls-remote '*refs/tags/two*|*' ls-remote '*refs/heads/two*)
    printf '%s\n' "$*" >>"$CLEANUP_CASE/observation.calls"
    printf 'fixture exact remote observation failed\n' >&2
    exit "$CLEANUP_OBSERVATION_STATUS" ;;
esac
if [[ "$1" == push ]]; then
  printf '%s\n' "$*" >>"$CLEANUP_CASE/push.calls"
fi
exec "$CLEANUP_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  local action code prefix
  for action in push delete remote; do
    if [[ "$action" == remote ]]; then prefix=refs/heads; else prefix=refs/tags; fi
    for code in 17 124 130 143; do
      cleanup_batch_fixture "$action" "observation-$action-$code"
      export CLEANUP_OBSERVATION_STATUS="$code"
      cleanup_batch_run
      cleanup_check test -s "$CLEANUP_CASE/observation.calls"
      if [[ "$code" == 17 ]]; then
        cleanup_check test "$status" -eq 1
        cleanup_check test "$(wc -l <"$CLEANUP_CASE/push.calls")" -eq 2
        cleanup_reject grep -Ei '(three.*not run|not run.*three)' "$CLEANUP_CASE/batch.stderr"
      else
        cleanup_check test "$status" -eq "$code"
        cleanup_check test "$(wc -l <"$CLEANUP_CASE/push.calls")" -eq 1
        cleanup_check grep -Ei '(two.*mutation not run|mutation not run.*two)' "$CLEANUP_CASE/batch.stderr"
        cleanup_check grep -Ei '(three.*not run|not run.*three)' "$CLEANUP_CASE/batch.stderr"
      fi
      if [[ "$action" == push ]]; then
        cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/one"
        cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/two"
      else
        cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/one"
        cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/two"
      fi
      if [[ "$code" != 17 ]]; then
        if [[ "$action" == push ]]; then
          cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/three"
        else
          cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/three"
        fi
      fi
    done
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: mixed tag batches mark partial failure and retain exact successful effects" {
  cleanup_push_mock
  local action
  for action in push delete; do
    cleanup_batch_fixture "$action" "partial-$action"
    export CLEANUP_PUSH_STATUS=17 CLEANUP_STOP_AT=2
    run run_zsh '
      cd "$CLEANUP_REPO" || return 90
      source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
      _git_mark_partial() { print -r -- marked >>"$CLEANUP_CASE/partial.calls"; }
      case "$CLEANUP_ACTION" in
        push) git-tag-push one two three --remote origin --yes ;;
        delete) git-tag-delete one two three --remote origin --delete-remote --yes ;;
      esac >"$CLEANUP_CASE/batch.stdout" 2>"$CLEANUP_CASE/batch.stderr"
    '
    cleanup_status batch
    cleanup_check test "$status" -eq 1
    cleanup_check test "$(wc -l <"$CLEANUP_CASE/push.calls")" -eq 3
    cleanup_check test -s "$CLEANUP_CASE/partial.calls"
    cleanup_check grep -Ei 'completed with partial failures.*1 of 3' "$CLEANUP_CASE/batch.stderr"
    if [[ "$action" == push ]]; then
      cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet refs/tags/one
      cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet refs/tags/two
      cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet refs/tags/three
    else
      cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet refs/tags/one
      cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet refs/tags/two
      cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet refs/tags/three
      cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/two
    fi
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

# Normalize the state left by a successful URL push, rather than assuming a
# particular Git version's fetch-refspec side effect. All state stays sandboxed.
cleanup_tracking_mock() {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == push ]]; then
  printf '%s\n' "$*" >>"$CLEANUP_CASE/push.calls"
  "$CLEANUP_REAL_GIT" "$@" || exit "$?"
  case "$CLEANUP_TRACKING_STATE" in
    absent) "$CLEANUP_REAL_GIT" update-ref --no-deref -d refs/remotes/origin/eligible || exit "$?" ;;
    matching) "$CLEANUP_REAL_GIT" update-ref --no-deref refs/remotes/origin/eligible "$CLEANUP_ELIGIBLE_OID" || exit "$?" ;;
    moved) "$CLEANUP_REAL_GIT" update-ref --no-deref refs/remotes/origin/eligible "$CLEANUP_MAIN_OID" || exit "$?" ;;
    symbolic) "$CLEANUP_REAL_GIT" symbolic-ref refs/remotes/origin/eligible refs/heads/main || exit "$?" ;;
    dangling) "$CLEANUP_REAL_GIT" symbolic-ref refs/remotes/origin/eligible refs/heads/protected-absent || exit "$?" ;;
    *) exit 96 ;;
  esac
  : >"$CLEANUP_CASE/push-complete"
  exit 0
fi
if [[ -e "$CLEANUP_CASE/push-complete" && "$*" == *refs/remotes/origin/eligible* ]]; then
  case "$1" in
    update-ref)
      printf '%s\n' "$*" >>"$CLEANUP_CASE/tracking-delete.calls"
      if [[ "$CLEANUP_TRACKING_DELETE_STATUS" != 0 ]]; then exit "$CLEANUP_TRACKING_DELETE_STATUS"; fi ;;
    show-ref|rev-parse|for-each-ref|symbolic-ref)
      printf '%s\n' "$*" >>"$CLEANUP_CASE/tracking-read.calls"
      if [[ "$CLEANUP_TRACKING_READ_STATUS" != 0 ]]; then
        printf 'fixture tracking observation failed\n' >&2
        exit "$CLEANUP_TRACKING_READ_STATUS"
      fi ;;
  esac
fi
exec "$CLEANUP_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}

cleanup_tracking_fixture() {
  cleanup_pair "$1"
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch eligible
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" push -q origin refs/heads/eligible
  export CLEANUP_ELIGIBLE_OID CLEANUP_MAIN_OID
  CLEANUP_ELIGIBLE_OID=$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" rev-parse HEAD)
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" commit -q --allow-empty -m next
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" push -q origin refs/heads/main
  CLEANUP_MAIN_OID=$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" rev-parse HEAD)
}

cleanup_tracking_run() {
  run run_zsh '
    cd "$CLEANUP_REPO" || return 90
    clean-remote-merged eligible --remote origin --yes >"$CLEANUP_CASE/tracking.stdout" 2>"$CLEANUP_CASE/tracking.stderr"
  '
  cleanup_status tracking
  cleanup_check test "$(wc -l <"$CLEANUP_CASE/push.calls")" -eq 1
  cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet refs/heads/eligible
  cleanup_check test "$("$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" rev-parse refs/heads/main)" = "$CLEANUP_MAIN_OID"
}

@test "git cleanup results: an already absent tracking ref is never reported as retained" {
  cleanup_tracking_fixture absent
  export CLEANUP_TRACKING_STATE=absent CLEANUP_TRACKING_DELETE_STATUS=17 CLEANUP_TRACKING_READ_STATUS=0
  cleanup_tracking_mock
  cleanup_tracking_run
  cleanup_check test "$status" -eq 0
  cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/remotes/origin/eligible
  cleanup_reject grep -Ei '(tracking ref.*(kept|retain)|kept.*tracking ref)' "$CLEANUP_CASE/tracking.stderr"
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: matching and moved tracking refs retain truthful leased housekeeping" {
  cleanup_tracking_mock
  local state delete_status expected_oid
  for state in matching moved; do
    for delete_status in 0 17; do
      cleanup_tracking_fixture "$state-$delete_status"
      export CLEANUP_TRACKING_STATE="$state" CLEANUP_TRACKING_DELETE_STATUS="$delete_status" CLEANUP_TRACKING_READ_STATUS=0
      cleanup_tracking_run
      cleanup_check test "$status" -eq 0
      if [[ "$state" == matching && "$delete_status" == 0 ]]; then
        cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/remotes/origin/eligible
        cleanup_reject grep -Ei 'tracking ref.*(kept|retain)' "$CLEANUP_CASE/tracking.stderr"
      else
        expected_oid="$CLEANUP_ELIGIBLE_OID"
        [[ "$state" != moved ]] || expected_oid="$CLEANUP_MAIN_OID"
        cleanup_check test "$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" rev-parse refs/remotes/origin/eligible)" = "$expected_oid"
        cleanup_check grep -Ei 'refs/remotes/origin/eligible.*(kept|retain|mov|chang)' "$CLEANUP_CASE/tracking.stderr"
      fi
      if [[ -f "$CLEANUP_CASE/tracking-delete.calls" ]]; then
        cleanup_check grep -Fq "update-ref --no-deref -d refs/remotes/origin/eligible $CLEANUP_ELIGIBLE_OID" "$CLEANUP_CASE/tracking-delete.calls"
      fi
    done
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: post-push symbolic and dangling tracking refs are retained without housekeeping" {
  cleanup_tracking_mock
  local state target_ref
  for state in symbolic dangling; do
    cleanup_tracking_fixture "$state"
    export CLEANUP_TRACKING_STATE="$state" CLEANUP_TRACKING_DELETE_STATUS=17 CLEANUP_TRACKING_READ_STATUS=0
    cleanup_tracking_run
    cleanup_check test "$status" -eq 0
    cleanup_check test -s "$CLEANUP_CASE/tracking-read.calls"
    cleanup_check test ! -e "$CLEANUP_CASE/tracking-delete.calls"
    target_ref=refs/heads/main
    [[ "$state" != dangling ]] || target_ref=refs/heads/protected-absent
    cleanup_check test "$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" symbolic-ref refs/remotes/origin/eligible)" = "$target_ref"
    cleanup_check test "$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" rev-parse refs/heads/main)" = "$CLEANUP_MAIN_OID"
    cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/protected-absent
    cleanup_check grep -Ei 'refs/remotes/origin/eligible.*(kept|retain)' "$CLEANUP_CASE/tracking.stderr"
    cleanup_reject grep -Ei 'tracking ref.*(was removed|already absent)' "$CLEANUP_CASE/tracking.stderr"
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: a failed tracking observation cannot claim absence or retention" {
  cleanup_tracking_fixture unreadable
  export CLEANUP_TRACKING_STATE=absent CLEANUP_TRACKING_DELETE_STATUS=17 CLEANUP_TRACKING_READ_STATUS=17
  cleanup_tracking_mock
  cleanup_tracking_run
  cleanup_check test "$status" -eq 0
  cleanup_check test -s "$CLEANUP_CASE/tracking-read.calls"
  cleanup_check grep -Ei '(tracking|refs/remotes/origin/eligible).*(unknown|inspect|read|verif|observ)' "$CLEANUP_CASE/tracking.stderr"
  cleanup_reject grep -Ei 'tracking ref.*(kept|retain|already absent|was removed)' "$CLEANUP_CASE/tracking.stderr"
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: stopped tracking observations preserve 124, 130 and 143 after remote deletion" {
  cleanup_tracking_mock
  local code
  for code in 124 130 143; do
    cleanup_tracking_fixture "read-$code"
    export CLEANUP_TRACKING_STATE=matching CLEANUP_TRACKING_DELETE_STATUS=17 CLEANUP_TRACKING_READ_STATUS="$code"
    cleanup_tracking_run
    cleanup_check test "$status" -eq "$code"
    cleanup_check test -s "$CLEANUP_CASE/tracking-read.calls"
    cleanup_check test "$("$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" rev-parse refs/remotes/origin/eligible)" = "$CLEANUP_ELIGIBLE_OID"
    cleanup_reject grep -Ei 'tracking ref.*(kept|retain|absent|removed)' "$CLEANUP_CASE/tracking.stderr"
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: tag and cleanup plan repository facts abbreviate HOME without changing data" {
  cleanup_pair
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" tag existing
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" branch eligible
  "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" push -q origin refs/heads/eligible
  local action
  for action in create push delete local remote; do
    export CLEANUP_ACTION="$action"
    run run_zsh '
      cd "$CLEANUP_REPO" || return 90
      case "$CLEANUP_ACTION" in
        create) git-tag-create --name planned --lightweight --dry-run ;;
        push) git-tag-push existing --remote origin --dry-run ;;
        delete) git-tag-delete existing --local-only --dry-run ;;
        local) clean-branches eligible --dry-run ;;
        remote) clean-remote-merged eligible --remote origin --dry-run ;;
      esac >"$CLEANUP_CASE/$CLEANUP_ACTION.stdout" 2>"$CLEANUP_CASE/$CLEANUP_ACTION.stderr"
    '
    cleanup_status "$action"
    cleanup_check test "$status" -eq 0
    cleanup_check grep -Eq 'Repository:.*~/pair/repo' "$CLEANUP_CASE/$action.stderr"
    cleanup_reject grep -F "Repository: $CLEANUP_REPO" "$CLEANUP_CASE/$action.stderr"
  done
  cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/planned
  cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/existing
  cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/eligible
  cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet refs/heads/eligible
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

# Stop a real external read only after the first planned mutation completed.
# The ordinary failure is one-shot so the independent third target can run.
cleanup_local_read_mock() {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
selected=0
if [[ -e "$CLEANUP_CASE/first-mutation-complete" && ! -e "$CLEANUP_CASE/local-read.status" ]]; then
  case "$CLEANUP_LOCAL_READER" in
    ancestry)
      [[ " $* " != *' merge-base --is-ancestor '* ]] || selected=1 ;;
    oid)
      if [[ "$1" == rev-parse ]]; then
        if [[ "$CLEANUP_ACTION" == local && "$*" == *'refs/heads/two^{commit}'* ]] \
          || [[ "$CLEANUP_ACTION" != local && "$*" == *'refs/tags/two^{object}'* ]]; then selected=1; fi
      fi ;;
    url)
      [[ "$1 $2" != 'remote get-url' || "$*" != *'--push --all'* ]] || selected=1 ;;
    remote-list)
      [[ "$1" != remote || "$#" -ne 1 ]] || selected=1 ;;
    worktree-list)
      [[ "$1 $2" != 'worktree list' ]] || selected=1 ;;
    worktree-hash)
      [[ "$1" != hash-object ]] || selected=1 ;;
    worktree-ref)
      [[ "$1" != check-ref-format || "$2" == --branch ]] || selected=1 ;;
    eligibility)
      [[ " $* " != *' for-each-ref '* || " $* " != *' --merged '* ]] || selected=1 ;;
    eligibility-ref)
      [[ ! -e "$CLEANUP_CASE/eligibility-read-complete" || "$1" != check-ref-format ]] || selected=1 ;;
    eligibility-branch)
      [[ ! -e "$CLEANUP_CASE/eligibility-read-complete" || "$1 $2" != 'check-ref-format --branch' ]] || selected=1 ;;
    eligibility-branch-ref)
      [[ ! -e "$CLEANUP_CASE/branch-name-read-complete" || "$1" != check-ref-format || "$2" == --branch ]] || selected=1 ;;
    default-config)
      [[ "$1 $2 $3" != 'config --get init.defaultBranch' ]] || selected=1 ;;
    default-name)
      [[ "$1 $2" != 'check-ref-format --branch' ]] || selected=1 ;;
    default-ref)
      [[ "$1" != show-ref || "$*" != *refs/heads/main* ]] || selected=1 ;;
    selected-config)
      [[ "$1 $2 $3" != 'config --get branch.main.pushRemote' ]] || selected=1 ;;
    selected-origin)
      [[ "$*" != 'remote get-url origin' ]] || selected=1 ;;
    *) exit 96 ;;
  esac
fi
if [[ "$selected" == 1 ]]; then
  observed_rc=0
  (exit "$CLEANUP_LOCAL_READ_STATUS") || observed_rc=$?
  printf '%s\n' "$observed_rc" >"$CLEANUP_CASE/local-read.status"
  printf '%s\0' "$@" >"$CLEANUP_CASE/local-read.args.nul"
  printf 'fixture local read stopped with %s\n' "$observed_rc" >&2
  exit "$observed_rc"
fi
if [[ -e "$CLEANUP_CASE/first-mutation-complete" && "$CLEANUP_LOCAL_READER" == eligibility-* ]]; then
  if [[ " $* " == *' for-each-ref '* && " $* " == *' --merged '* ]]; then
    "$CLEANUP_REAL_GIT" "$@" || exit "$?"
    : >"$CLEANUP_CASE/eligibility-read-complete"
    exit 0
  fi
  if [[ "$CLEANUP_LOCAL_READER" == eligibility-branch-ref && -e "$CLEANUP_CASE/eligibility-read-complete" && "$1 $2" == 'check-ref-format --branch' ]]; then
    "$CLEANUP_REAL_GIT" "$@" || exit "$?"
    : >"$CLEANUP_CASE/branch-name-read-complete"
    exit 0
  fi
fi
if [[ "$1" == push ]]; then
  printf '%s\n' "$*" >>"$CLEANUP_CASE/push.calls"
  "$CLEANUP_REAL_GIT" "$@" || exit "$?"
  : >"$CLEANUP_CASE/first-mutation-complete"
  exit 0
fi
if [[ "$1" == update-ref && "$*" == *' -d refs/heads/'* && "$CLEANUP_ACTION" == local ]]; then
  printf '%s\n' "$*" >>"$CLEANUP_CASE/branch-delete.calls"
  "$CLEANUP_REAL_GIT" "$@" || exit "$?"
  : >"$CLEANUP_CASE/first-mutation-complete"
  exit 0
fi
if [[ "$1" == update-ref && "$*" == *' -d refs/tags/'* ]]; then
  printf '%s\n' "$*" >>"$CLEANUP_CASE/tag-delete.calls"
fi
exec "$CLEANUP_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}

cleanup_local_read_case() {
  local action="$1" reader="$2" code="$3" mutation_log prefix actual_code=missing
  cleanup_batch_fixture "$action" "local-read-$action-$reader-$code"
  if [[ "$reader" == default-name || "$reader" == default-ref ]]; then
    "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" config init.defaultBranch main
  fi
  export CLEANUP_LOCAL_READER="$reader" CLEANUP_LOCAL_READ_STATUS="$code"
  cleanup_batch_run
  cleanup_check test -e "$CLEANUP_CASE/first-mutation-complete"
  cleanup_check test -s "$CLEANUP_CASE/local-read.status"
  cleanup_check test -s "$CLEANUP_CASE/local-read.args.nul"
  [[ ! -f "$CLEANUP_CASE/local-read.status" ]] || actual_code=$(cat "$CLEANUP_CASE/local-read.status")
  cleanup_check test "$actual_code" = "$code"
  mutation_log="$CLEANUP_CASE/push.calls"
  [[ "$action" != local ]] || mutation_log="$CLEANUP_CASE/branch-delete.calls"
  if [[ "$code" == 17 ]]; then
    cleanup_check test "$status" -eq 1
    cleanup_check test "$(wc -l <"$mutation_log")" -eq 2
    cleanup_reject grep -Ei '(three.*not run|not run.*three)' "$CLEANUP_CASE/batch.stderr"
  else
    cleanup_check test "$status" -eq "$code"
    cleanup_check test "$(wc -l <"$mutation_log")" -eq 1
    cleanup_check grep -Ei '(two.*mutation not run|mutation not run.*two)' "$CLEANUP_CASE/batch.stderr"
    cleanup_check grep -Ei '(three.*not run|not run.*three)' "$CLEANUP_CASE/batch.stderr"
  fi
  if [[ "$action" == local ]]; then
    cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/one
    cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/two
    if [[ "$code" == 17 ]]; then
      cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/three
    else
      cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/heads/three
    fi
  else
    prefix=refs/tags
    [[ "$action" != remote ]] || prefix=refs/heads
    if [[ "$action" == push ]]; then
      cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/one"
      cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/two"
      if [[ "$code" == 17 ]]; then
        cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/three"
      else
        cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/three"
      fi
    else
      cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/one"
      cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/two"
      if [[ "$code" == 17 ]]; then
        cleanup_absent "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/three"
      else
        cleanup_check "$CLEANUP_REAL_GIT" --git-dir="$CLEANUP_REMOTE" show-ref --verify --quiet "$prefix/three"
      fi
    fi
    if [[ "$action" == delete ]]; then
      cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/one
      cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/two
      if [[ "$code" == 17 ]]; then
        cleanup_absent "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/three
      else
        cleanup_check "$CLEANUP_REAL_GIT" -C "$CLEANUP_REPO" show-ref --verify --quiet refs/tags/three
      fi
    fi
  fi
}

@test "git cleanup results: stopped local branch inspections leave later branches not run" {
  cleanup_local_read_mock
  local reader code
  for reader in oid ancestry worktree-list worktree-hash worktree-ref eligibility eligibility-ref default-config default-name default-ref selected-config selected-origin; do
    for code in 17 124 130 143; do cleanup_local_read_case local "$reader" "$code"; done
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: stopped remote branch inspections leave later branches not run" {
  cleanup_local_read_mock
  local reader code
  for reader in ancestry eligibility eligibility-ref eligibility-branch eligibility-branch-ref default-config; do
    for code in 17 124 130 143; do cleanup_local_read_case remote "$reader" "$code"; done
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: stopped tag publication OID reads leave later tags not run" {
  cleanup_local_read_mock
  local code
  for code in 17 124 130 143; do cleanup_local_read_case push oid "$code"; done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: stopped tag deletion OID reads leave later tags not run" {
  cleanup_local_read_mock
  local code
  for code in 17 124 130 143; do cleanup_local_read_case delete oid "$code"; done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}

@test "git cleanup results: stopped per-target URL and remote-name reads leave later refs not run" {
  cleanup_local_read_mock
  local action reader code
  for action in push delete remote; do
    for reader in url remote-list; do
      [[ "$action" != remote || "$reader" != remote-list ]] || continue
      for code in 17 124 130 143; do cleanup_local_read_case "$action" "$reader" "$code"; done
    done
  done
  [ "$CLEANUP_FAILURES" -eq 0 ]
}
