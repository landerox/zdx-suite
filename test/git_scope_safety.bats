#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export GIT_ALLOW_PROTOCOL=file
  export GIT_AUTHOR_NAME="Scope Test" GIT_AUTHOR_EMAIL="scope@example.invalid"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export REAL_GIT
  REAL_GIT=$(command -v git)
}

teardown() { cleanup_sandbox; }

scope_tracking_head_case() {
  export TRACK_HEAD_STATUS="$1"
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == 'symbolic-ref --quiet --short refs/remotes/origin/HEAD' ]]; then
  exit "$TRACK_HEAD_STATUS"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches topic --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    local actual_rc=$?
    print -r -- "cleanup=$actual_rc"
    if [[ "$TRACK_HEAD_STATUS" == 1 ]]; then
      command git show-ref --verify --quiet refs/heads/topic && return 92
      (( actual_rc == 0 )) || return 93
    else
      command git show-ref --verify --quiet refs/heads/topic || return 92
      if [[ "$TRACK_HEAD_STATUS" == (130|143) ]]; then
        (( actual_rc == TRACK_HEAD_STATUS )) || return 93
      else
        (( actual_rc == 1 )) || return 94
      fi
    fi
    return 0
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "git scope: tracking HEAD read interruption 130 stops cleanup" {
  scope_tracking_head_case 130
}

@test "git scope: tracking HEAD read interruption 143 stops cleanup" {
  scope_tracking_head_case 143
}

@test "git scope: failed tracking HEAD observation is not absence" {
  scope_tracking_head_case 7
}

@test "git scope: absent tracking HEAD permits actual remote default fallback" {
  scope_tracking_head_case 1
}

@test "git scope: revalidate configured default after confirmation" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_clean_confirm_outcome() {
      command git config init.defaultBranch topic || return 91
      REPLY=confirmed
    }
    clean-branches topic >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    local code=$?
    command git show-ref --verify --quiet refs/heads/topic || return 92
    (( code != 0 )) || return 93
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "git scope: revalidate tracking of remote default after confirmation" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_clean_confirm_outcome() {
      command git branch --set-upstream-to=origin/main topic || return 91
      REPLY=confirmed
    }
    clean-branches topic >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    local code=$?
    command git show-ref --verify --quiet refs/heads/topic || return 92
    (( code != 0 )) || return 93
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

scope_pair() {
  export REMOTE_REPO="$HOME/remote.git" WORK_REPO="$HOME/work" PEER_REPO="$HOME/peer"
  "$REAL_GIT" init -q --bare "$REMOTE_REPO"
  "$REAL_GIT" -C "$REMOTE_REPO" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" init -q -b main "$PEER_REPO"
  printf 'base\n' > "$PEER_REPO/base.txt"
  "$REAL_GIT" -C "$PEER_REPO" add -- base.txt
  "$REAL_GIT" -C "$PEER_REPO" commit -q -m base
  "$REAL_GIT" -C "$PEER_REPO" remote add origin "$REMOTE_REPO"
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  "$REAL_GIT" clone -q "$REMOTE_REPO" "$WORK_REPO"
}

scope_develop_default() {
  scope_pair
  "$REAL_GIT" -C "$PEER_REPO" branch develop
  "$REAL_GIT" -C "$PEER_REPO" push -q origin develop
  "$REAL_GIT" -C "$REMOTE_REPO" symbolic-ref HEAD refs/heads/develop
  "$REAL_GIT" -C "$WORK_REPO" fetch -q origin
  "$REAL_GIT" -C "$WORK_REPO" branch develop origin/develop >/dev/null
  "$REAL_GIT" -C "$WORK_REPO" switch -q develop
  "$REAL_GIT" -C "$WORK_REPO" remote set-head origin -a >/dev/null
}

scope_assert_status() {
  if [ "$status" -ne "$1" ]; then
    printf 'status=%s output=%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/result.stderr" ] || cat "$HOME/result.stderr" >&2
    false
  fi
}

@test "git scope: local-only tag flag suppresses the remote scope dialog and preserves the remote tag" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" tag release
  "$REAL_GIT" -C "$WORK_REPO" push -q origin refs/tags/release
  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
    _git_tag_select_records() { shift 2; reply=("$1"); }
    _git_tag_select_action() { print -r -- "$1" >>"$HOME/dialogs"; REPLY="Delete remote tags, then local tags"; }
    _git_confirm_outcome() { REPLY=confirmed; }
    git-tag-delete --local-only >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 0
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/dialogs" ]
  "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/tags/release
  run "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  grep -Fq 'remote not-requested' "$HOME/result.stderr"
}

@test "git scope: an explicit remote tag flag suppresses the scope dialog and names the remote at confirmation" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" tag release
  "$REAL_GIT" -C "$WORK_REPO" push -q origin refs/tags/release
  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
    _git_tag_select_records() { shift 2; reply=("$1"); }
    _git_tag_select_action() { print -r -- "$1" >>"$HOME/dialogs"; REPLY="Delete local tags only"; }
    _git_confirm_outcome() { print -r -- "$1" >"$HOME/confirmation"; REPLY=confirmed; }
    git-tag-delete --remote origin >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 0
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/dialogs" ]
  grep -Fq origin "$HOME/confirmation"
  run "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  run "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
}

@test "git scope: missing origin HEAD never turns the current feature into the default" {
  scope_develop_default
  "$REAL_GIT" -C "$WORK_REPO" branch -D main >/dev/null
  "$REAL_GIT" -C "$WORK_REPO" switch -q -c feature
  "$REAL_GIT" -C "$WORK_REPO" remote set-head origin -d
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches --dry-run >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 0
  [ "$status" -eq 0 ]
  run grep -Fq refs/heads/feature "$HOME/result.stderr"
  [ "$status" -eq 1 ]
  run grep -Fq refs/heads/develop "$HOME/result.stderr"
  [ "$status" -eq 1 ]
}

@test "git scope: a repository with no identifiable default fails closed instead of using its current branch" {
  "$REAL_GIT" init -q -b feature "$HOME/repo"
  printf 'base\n' > "$HOME/repo/base.txt"
  "$REAL_GIT" -C "$HOME/repo" add -- base.txt
  "$REAL_GIT" -C "$HOME/repo" commit -q -m base
  "$REAL_GIT" -C "$HOME/repo" branch trunk
  run run_zsh '
    cd "$HOME/repo" || return 90
    clean-branches --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 1
  [ "$status" -eq 1 ]
  "$REAL_GIT" -C "$HOME/repo" show-ref --verify --quiet refs/heads/trunk
  grep -Fq 'Unable to determine the default branch' "$HOME/result.stderr"
}

@test "git scope: main master and local aliases tracking the remote default survive local cleanup" {
  scope_develop_default
  "$REAL_GIT" -C "$WORK_REPO" branch master
  "$REAL_GIT" -C "$WORK_REPO" branch default-alias origin/develop >/dev/null
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 0
  [ "$status" -eq 0 ]
  local ref
  for ref in main master default-alias develop; do
    "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet "refs/heads/$ref"
  done
  run "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/topic
  [ "$status" -eq 1 ]
}

@test "git scope: main and master survive remote cleanup when develop is the default" {
  scope_develop_default
  "$REAL_GIT" -C "$PEER_REPO" branch master
  "$REAL_GIT" -C "$PEER_REPO" branch topic
  "$REAL_GIT" -C "$PEER_REPO" push -q origin master topic
  "$REAL_GIT" -C "$WORK_REPO" fetch -q origin
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-remote-merged --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 0
  [ "$status" -eq 0 ]
  "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/heads/main
  "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/heads/master
  run "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/heads/topic
  [ "$status" -eq 1 ]
}

@test "git scope: an existing configured local default is protected beside the remote default" {
  scope_develop_default
  "$REAL_GIT" -C "$WORK_REPO" branch stable
  "$REAL_GIT" -C "$WORK_REPO" config init.defaultBranch stable
  "$REAL_GIT" -C "$WORK_REPO" push -q origin stable
  "$REAL_GIT" -C "$WORK_REPO" fetch -q origin
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr" || return 91
    clean-remote-merged --yes >>"$HOME/result.stdout" 2>>"$HOME/result.stderr"
  '
  scope_assert_status 0
  [ "$status" -eq 0 ]
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/stable
  "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/heads/stable
}

@test "git scope: local cleanup refuses a default binding changed after confirmation" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
    _git_clean_confirm_outcome() {
      command git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/topic || return 92
      REPLY=confirmed
    }
    clean-branches topic >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 1
  [ "$status" -eq 1 ]
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/topic
}

scope_interrupt_delete_mock() {
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == update-ref && "$*" == *' -d '* ]]; then
  printf '%s\n' "$*" >> "$HOME/delete-calls"
  if [[ ! -e "$HOME/first-delete" ]]; then
    : > "$HOME/first-delete"
    exit "$MOCK_DELETE_STATUS"
  fi
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}

@test "git scope: interrupted local tag deletion retains later tags and reports them not run" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" tag one
  "$REAL_GIT" -C "$WORK_REPO" tag two
  scope_interrupt_delete_mock
  local code
  for code in 130 143; do
    export MOCK_DELETE_STATUS="$code"
    command rm -f -- "$HOME/first-delete" "$HOME/delete-calls"
    run run_zsh '
      cd "$WORK_REPO" || return 90
      git-tag-delete one two --local-only --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    '
    scope_assert_status "$code"
    [ "$status" -eq "$code" ]
    [ "$(wc -l < "$HOME/delete-calls")" -eq 1 ]
    "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/one
    "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/two
    grep -Fq 'not run' "$HOME/result.stderr"
    grep -Fq refs/tags/two "$HOME/result.stderr"
  done
}

@test "git scope: interrupted local branch deletion retains later branches and reports them not run" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch alpha
  "$REAL_GIT" -C "$WORK_REPO" branch beta
  scope_interrupt_delete_mock
  local code
  for code in 130 143; do
    export MOCK_DELETE_STATUS="$code"
    command rm -f -- "$HOME/first-delete" "$HOME/delete-calls"
    run run_zsh '
      cd "$WORK_REPO" || return 90
      clean-branches alpha beta --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    '
    scope_assert_status "$code"
    [ "$status" -eq "$code" ]
    [ "$(wc -l < "$HOME/delete-calls")" -eq 1 ]
    "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/alpha
    "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/beta
    grep -Fq 'not run' "$HOME/result.stderr"
    grep -Fq refs/heads/beta "$HOME/result.stderr"
  done
}

scope_file_directory_conflict() {
  scope_pair
  printf 'file\n' > "$WORK_REPO/p"
  "$REAL_GIT" -C "$WORK_REPO" add -- p
  "$REAL_GIT" -C "$WORK_REPO" commit -q -m 'local file'
  mkdir "$PEER_REPO/p"
  printf 'directory child\n' > "$PEER_REPO/p/x"
  "$REAL_GIT" -C "$PEER_REPO" add -- p/x
  "$REAL_GIT" -C "$PEER_REPO" commit -q -m 'remote directory'
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  export CONFLICT_HEAD CONFLICT_TRACKING
  CONFLICT_HEAD=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  CONFLICT_TRACKING=$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/remotes/origin/main)
}

@test "git scope: rebase refuses an unprovable file-directory side file before changing the worktree" {
  scope_file_directory_conflict
  local label
  label=$("$REAL_GIT" -C "$WORK_REPO" show -s --format='%h (%s)' HEAD)
  export SIDE_FILE="p~$label"
  printf '%s\n' "$SIDE_FILE" >> "$WORK_REPO/.git/info/exclude"
  printf 'precious\n' > "$WORK_REPO/$SIDE_FILE"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-pull --rebase --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 1
  [ "$status" -eq 1 ]
  [ "$(cat "$WORK_REPO/$SIDE_FILE")" = precious ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)" = "$CONFLICT_HEAD" ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/remotes/origin/main)" = "$CONFLICT_TRACKING" ]
  [ -z "$("$REAL_GIT" -C "$WORK_REPO" for-each-ref --format='%(refname)' refs/zdx-suite)" ]
  [ ! -d "$WORK_REPO/.git/rebase-merge" ]
}

@test "git scope: old merge-tree fallback refuses file-directory conflicts before side-file overwrite" {
  scope_file_directory_conflict
  printf 'p~HEAD\n' >> "$WORK_REPO/.git/info/exclude"
  printf 'precious\n' > "$WORK_REPO/p~HEAD"
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" != merge-tree ]] || exit 129
done
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-pull --merge --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 1
  [ "$status" -eq 1 ]
  [ "$(cat "$WORK_REPO/p~HEAD")" = precious ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)" = "$CONFLICT_HEAD" ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/remotes/origin/main)" = "$CONFLICT_TRACKING" ]
  [ -z "$("$REAL_GIT" -C "$WORK_REPO" for-each-ref --format='%(refname)' refs/zdx-suite)" ]
  [ ! -f "$WORK_REPO/.git/MERGE_HEAD" ]
}

@test "git scope: an intentional tracked hash-suffixed filename is not a synthetic rebase side file" {
  scope_pair
  printf 'remote\n' > "$PEER_REPO/remote.txt"
  "$REAL_GIT" -C "$PEER_REPO" add -- remote.txt
  "$REAL_GIT" -C "$PEER_REPO" commit -q -m remote
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  local upstream_tree
  upstream_tree=$("$REAL_GIT" -C "$PEER_REPO" rev-parse 'HEAD^{tree}')
  export INTENTIONAL_FILE="note~$upstream_tree"
  printf 'tracked data\n' > "$WORK_REPO/$INTENTIONAL_FILE"
  "$REAL_GIT" -C "$WORK_REPO" add -- "$INTENTIONAL_FILE"
  "$REAL_GIT" -C "$WORK_REPO" commit -q -m 'intentional filename'
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-pull --rebase --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 0
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK_REPO/$INTENTIONAL_FILE")" = 'tracked data' ]
  [ -f "$WORK_REPO/remote.txt" ]
}

@test "git scope: old merge fallback allows an unchanged file to become a directory cleanly" {
  scope_pair
  printf 'old\n' > "$WORK_REPO/p"
  "$REAL_GIT" -C "$WORK_REPO" add -- p
  "$REAL_GIT" -C "$WORK_REPO" commit -q -m 'base file'
  "$REAL_GIT" -C "$WORK_REPO" push -q origin main
  "$REAL_GIT" -C "$PEER_REPO" pull -q --ff-only origin main
  "$REAL_GIT" -C "$PEER_REPO" rm -q -- p
  mkdir "$PEER_REPO/p"
  printf 'new\n' > "$PEER_REPO/p/x"
  "$REAL_GIT" -C "$PEER_REPO" add -- p/x
  "$REAL_GIT" -C "$PEER_REPO" commit -q -m 'replace file with directory'
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  printf 'local\n' > "$WORK_REPO/local.txt"
  "$REAL_GIT" -C "$WORK_REPO" add -- local.txt
  "$REAL_GIT" -C "$WORK_REPO" commit -q -m 'unrelated local work'
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" != merge-tree ]] || exit 129
done
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-pull --merge --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 0
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK_REPO/p/x")" = new ]
  [ -f "$WORK_REPO/local.txt" ]
}

@test "git scope: remote cleanup revalidates configured local default" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  "$REAL_GIT" -C "$WORK_REPO" push -q origin topic
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_clean_confirm_outcome() {
      command git config init.defaultBranch topic || return 91
      REPLY=confirmed
    }
    clean-remote-merged topic >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    local code=$?
    print -r -- "cleanup=$code"
    command git --git-dir="$REMOTE_REPO" show-ref --verify --quiet refs/heads/topic || return 92
    (( code != 0 )) || return 93
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME/result.stderr" >&2; false; }
}
@test "git scope: remote cleanup revalidates server default" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  "$REAL_GIT" -C "$WORK_REPO" push -q origin topic
  run run_zsh '
    cd "$WORK_REPO" || return 90
    command git --git-dir="$REMOTE_REPO" config receive.denyDeleteCurrent ignore || return 94
    _git_clean_confirm_outcome() {
      command git --git-dir="$REMOTE_REPO" symbolic-ref HEAD refs/heads/topic || return 91
      REPLY=confirmed
    }
    clean-remote-merged topic >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    local code=$?
    print -r -- "cleanup=$code"
    command git --git-dir="$REMOTE_REPO" show-ref --verify --quiet refs/heads/topic || return 92
    (( code != 0 )) || return 93
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME/result.stderr" >&2; false; }
}

scope_collect_failure_mock() {
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
has_list=0 has_merged=0
for arg in "$@"; do
  [[ "$arg" != for-each-ref ]] || has_list=1
  [[ "$arg" != --merged ]] || has_merged=1
done
if (( has_list && has_merged )); then
  count=0
  [[ ! -e "$HOME/collect-count" ]] || read -r count < "$HOME/collect-count"
  (( count += 1 ))
  printf '%s\n' "$count" > "$HOME/collect-count"
  (( count != ${MOCK_COLLECT_FAIL_AT:-2} )) || exit "$MOCK_PROBE_STATUS"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}
@test "git scope: interrupted local eligibility collection stops later branches" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch alpha
  "$REAL_GIT" -C "$WORK_REPO" branch beta
  export MOCK_PROBE_STATUS=130
  scope_collect_failure_mock
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches alpha beta --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  [ "$status" -eq 130 ] || { printf 'status=%s\n%s\n' "$status" "$output" >&2; cat "$HOME/result.stderr" >&2; false; }
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/alpha
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/beta
}
@test "git scope: interrupted remote eligibility collection stops later branches" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch alpha
  "$REAL_GIT" -C "$WORK_REPO" branch beta
  "$REAL_GIT" -C "$WORK_REPO" push -q origin alpha beta
  export MOCK_PROBE_STATUS=143
  scope_collect_failure_mock
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-remote-merged alpha beta --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  [ "$status" -eq 143 ] || { printf 'status=%s\n%s\n' "$status" "$output" >&2; cat "$HOME/result.stderr" >&2; false; }
  "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/heads/alpha
  "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/heads/beta
}
@test "git scope: failed protected-default config read refuses deletion" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == 'config --get init.defaultBranch' && -e "$HOME/fail-protection-read" ]]; then
  exit 7
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_clean_confirm_outcome() {
      command git config init.defaultBranch topic || return 91
      : > "$HOME/fail-protection-read"
      REPLY=confirmed
    }
    clean-branches topic >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    local code=$?
    print -r -- "cleanup=$code"
    command git show-ref --verify --quiet refs/heads/topic || return 92
    (( code != 0 )) || return 93
  '
  [ "$status" -eq 0 ] || { printf 'status=%s\n%s\n' "$status" "$output" >&2; cat "$HOME/result.stderr" >&2; false; }
}

@test "git scope: interrupted eligibility collection reports prior deletions and all remaining refs" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch beta
  "$REAL_GIT" -C "$WORK_REPO" branch gamma
  export MOCK_COLLECT_FAIL_AT=3
  scope_collect_failure_mock
  local code
  for code in 130 143; do
    "$REAL_GIT" -C "$WORK_REPO" branch alpha
    command rm -f -- "$HOME/collect-count"
    export MOCK_PROBE_STATUS="$code"
    run run_zsh '
      cd "$WORK_REPO" || return 90
      clean-branches alpha beta gamma --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    '
    scope_assert_status "$code"
    [ "$status" -eq "$code" ]
    run "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/alpha
    [ "$status" -eq 1 ]
    "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/beta
    "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/gamma
    grep -Fq 'Local cleanup interrupted: 1 branch deleted before the interruption.' "$HOME/result.stderr"
    grep -Fq 'refs/heads/beta' "$HOME/result.stderr"
    grep -Fq 'refs/heads/gamma' "$HOME/result.stderr"
    [ "$(grep -Fc 'not run after interruption' "$HOME/result.stderr")" -eq 2 ]
    [ ! -s "$HOME/result.stdout" ]
  done
}

@test "git scope: failed configured-default ref inspection blocks remote cleanup" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch stable
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  "$REAL_GIT" -C "$WORK_REPO" config init.defaultBranch stable
  "$REAL_GIT" -C "$WORK_REPO" push -q origin topic
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == 'show-ref --verify --quiet refs/heads/stable' && -e "$HOME/fail-protection-read" ]]; then
  exit 7
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_clean_confirm_outcome() { : > "$HOME/fail-protection-read"; REPLY=confirmed; }
    clean-remote-merged topic >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 1
  [ "$status" -eq 1 ]
  "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/heads/topic
  grep -Fq 'Unable to inspect the configured local default branch ref.' "$HOME/result.stderr"
}

@test "git scope: an invalid configured local default cannot authorize cleanup" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_clean_confirm_outcome() {
      command git config init.defaultBranch ../invalid || return 91
      REPLY=confirmed
    }
    clean-branches topic >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 1
  [ "$status" -eq 1 ]
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/topic
  grep -Fq 'The configured local default branch is invalid.' "$HOME/result.stderr"
}

@test "git scope: absent configuration and absent configured refs stay benign but failed reads do not" {
  scope_pair
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == 'config --get init.defaultBranch' ]]; then
  printf '%s' "$MOCK_CONFIG_VALUE"
  exit "$MOCK_CONFIG_STATUS"
elif [[ "$*" == 'show-ref --verify --quiet refs/heads/stable' ]]; then
  exit "$MOCK_SHOW_REF_STATUS"
elif [[ "$*" == 'check-ref-format --branch stable' ]]; then
  exit "${MOCK_BRANCH_STATUS:-0}"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  export MOCK_CONFIG_STATUS=1 MOCK_CONFIG_VALUE='' MOCK_SHOW_REF_STATUS=0
  run run_zsh '_git_clean_configured_default; local code=$?; print -r -- "$code:$REPLY"'
  [ "$status" -eq 0 ]
  [ "$output" = 0: ]
  export MOCK_CONFIG_STATUS=0 MOCK_CONFIG_VALUE=stable MOCK_SHOW_REF_STATUS=1
  run run_zsh '_git_clean_configured_default; local code=$?; print -r -- "$code:$REPLY"'
  [ "$status" -eq 0 ]
  [ "$output" = 0: ]
  local code
  for code in 7 130 143; do
    export MOCK_CONFIG_STATUS="$code"
    run run_zsh '_git_clean_configured_default >"$HOME/default.stdout" 2>"$HOME/default.stderr"'
    if [ "$code" -eq 7 ]; then [ "$status" -eq 1 ]; else [ "$status" -eq "$code" ]; fi
    [ ! -s "$HOME/default.stdout" ]
    export MOCK_CONFIG_STATUS=0 MOCK_SHOW_REF_STATUS="$code"
    run run_zsh '_git_clean_configured_default >"$HOME/default.stdout" 2>"$HOME/default.stderr"'
    if [ "$code" -eq 7 ]; then [ "$status" -eq 1 ]; else [ "$status" -eq "$code" ]; fi
    [ ! -s "$HOME/default.stdout" ]
  done
  export MOCK_CONFIG_STATUS=0 MOCK_SHOW_REF_STATUS=0
  for code in 130 143; do
    export MOCK_BRANCH_STATUS="$code"
    run run_zsh '_git_clean_configured_default >"$HOME/default.stdout" 2>"$HOME/default.stderr"'
    [ "$status" -eq "$code" ]
    [ ! -s "$HOME/default.stdout" ]
  done
}

@test "git scope: failed selected-remote observations cannot hide a newly protected upstream" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
has_list=0 has_merged=0
for arg in "$@"; do
  [[ "$arg" != for-each-ref ]] || has_list=1
  [[ "$arg" != --merged ]] || has_merged=1
done
if (( has_list && has_merged )); then
  count=0
  [[ ! -e "$HOME/eligibility-count" ]] || read -r count < "$HOME/eligibility-count"
  (( count += 1 ))
  printf '%s\n' "$count" > "$HOME/eligibility-count"
  (( count != 2 )) || : > "$HOME/fail-selected-remote"
fi
if [[ -e "$HOME/fail-selected-remote" ]]; then
  case "$*" in
    'config --get branch.main.pushRemote'|'config --get remote.pushDefault'|'config --get branch.main.remote'|'remote get-url origin'|'remote')
      exit 7 ;;
  esac
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_clean_confirm_outcome() {
      command git branch --set-upstream-to=origin/main topic || return 91
      REPLY=confirmed
    }
    clean-branches topic >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    local code=$?
    command git show-ref --verify --quiet refs/heads/topic || return 92
    (( code != 0 )) || return 93
  '
  [ "$status" -eq 0 ] || { printf 'status=%s\n%s\n' "$status" "$output" >&2; cat "$HOME/result.stderr" >&2; false; }
}

@test "git scope: strict cleanup remote selection retains precedence and benign absence" {
  scope_pair
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_clean_selected_remote refs/heads/main || return 91
    [[ "$REPLY" == origin ]] || return 92
    command git config remote.pushDefault publish || return 93
    _git_clean_selected_remote refs/heads/main || return 94
    [[ "$REPLY" == publish ]] || return 95
    command git config branch.main.pushRemote override || return 96
    _git_clean_selected_remote refs/heads/main || return 97
    [[ "$REPLY" == override ]] || return 98
    command git config --unset branch.main.pushRemote || return 99
    command git config --unset remote.pushDefault || return 100
    command git remote rename origin mirror || return 101
    command git config --unset branch.main.remote || return 102
    _git_clean_selected_remote refs/heads/main || return 103
    [[ "$REPLY" == mirror ]] || return 104
    command git remote remove mirror || return 105
    _git_clean_selected_remote refs/heads/main || return 106
    [[ -z "$REPLY" ]] || return 107
    command git remote add first "$REMOTE_REPO" || return 108
    command git remote add second "$REMOTE_REPO" || return 109
    _git_clean_selected_remote refs/heads/main || return 110
    [[ -z "$REPLY" ]] || return 111
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "git scope: strict cleanup remote observations preserve failure and interruption statuses" {
  scope_pair
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  'config --get branch.main.pushRemote'|'config --get remote.pushDefault'|'config --get branch.main.remote')
    if [[ "$MOCK_REMOTE_STAGE" == config ]]; then exit "$MOCK_REMOTE_STATUS"; fi
    exit 1 ;;
  'remote get-url origin')
    if [[ "$MOCK_REMOTE_STAGE" == origin ]]; then exit "$MOCK_REMOTE_STATUS"; fi
    exit 2 ;;
  remote) exit "$MOCK_REMOTE_STATUS" ;;
esac
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  local stage code
  for stage in config origin list; do
    export MOCK_REMOTE_STAGE="$stage"
    for code in 7 130 143; do
      export MOCK_REMOTE_STATUS="$code"
      run run_zsh '_git_clean_selected_remote refs/heads/main >"$HOME/remote.stdout" 2>"$HOME/remote.stderr"'
      if [ "$code" -eq 7 ]; then [ "$status" -eq 1 ]; else [ "$status" -eq "$code" ]; fi
      [ ! -s "$HOME/remote.stdout" ]
    done
  done
}

@test "git scope: detached selected origin default aliases remain protected" {
  scope_pair
  "$REAL_GIT" -C "$WORK_REPO" branch default-alias origin/main >/dev/null
  "$REAL_GIT" -C "$WORK_REPO" switch -q --detach main
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    local code=$?
    print -r -- "cleanup=$code"
    command git show-ref --verify --quiet refs/heads/default-alias || return 92
  '
  [ "$status" -eq 0 ] || { printf 'status=%s\n%s\n' "$status" "$output" >&2; cat "$HOME/result.stderr" >&2; false; }
}

@test "git scope: detached cleanup resolves the selected remote default before a local fallback" {
  scope_develop_default
  "$REAL_GIT" -C "$WORK_REPO" branch default-alias origin/develop >/dev/null
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  "$REAL_GIT" -C "$WORK_REPO" switch -q --detach develop
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  scope_assert_status 0
  [ "$status" -eq 0 ]
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/default-alias
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/develop
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/main
  run "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/topic
  [ "$status" -eq 1 ]
}

scope_default_validation_case() {
  export VALIDATION_MODE="$1" VALIDATION_CODE="$2"
  export REMOTE_REPO="$HOME/remote.git" WORK_REPO="$HOME/work" PEER_REPO="$HOME/peer"
  "$REAL_GIT" init -q --bare "$REMOTE_REPO"
  "$REAL_GIT" -C "$REMOTE_REPO" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" init -q -b main "$PEER_REPO"
  printf 'base\n' > "$PEER_REPO/base.txt"
  "$REAL_GIT" -C "$PEER_REPO" add -- base.txt
  "$REAL_GIT" -C "$PEER_REPO" commit -q -m base
  "$REAL_GIT" -C "$PEER_REPO" remote add origin "$REMOTE_REPO"
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  "$REAL_GIT" clone -q "$REMOTE_REPO" "$WORK_REPO"
  "$REAL_GIT" -C "$WORK_REPO" branch topic
  "$REAL_GIT" -C "$WORK_REPO" push -q origin topic
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$VALIDATION_MODE" == local && "$*" == 'symbolic-ref --quiet --short refs/remotes/origin/HEAD' ]]; then
  exit 1
fi
if [[ "${1:-}" == ls-remote && "${2:-}" == --symref && "${*: -1}" == HEAD ]]; then
  : > "$HOME/default-observed"
fi
if [[ -e "$HOME/default-observed" && "$*" == 'check-ref-format refs/heads/main' ]]; then
  printf '%s\n' "$* -> $VALIDATION_CODE" >> "$HOME/validation.calls"
  exit "$VALIDATION_CODE"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    if [[ "$VALIDATION_MODE" == local ]]; then
      clean-branches topic --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    else
      clean-remote-merged topic --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    fi
  '
  if [ "$status" -ne "$VALIDATION_CODE" ]; then
    printf 'expected=%s actual=%s\n' "$VALIDATION_CODE" "$status" >&2
    cat "$HOME/validation.calls" "$HOME/result.stderr" >&2
    false
  fi
  [ -s "$HOME/validation.calls" ]
  [ ! -s "$HOME/result.stdout" ]
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/heads/topic
  "$REAL_GIT" -C "$REMOTE_REPO" show-ref --verify --quiet refs/heads/topic
}

@test "git scope: local default validator retains130 after remote fallback" {
  scope_default_validation_case local 130
}

@test "git scope: local default validator retains143 after remote fallback" {
  scope_default_validation_case local 143
}

@test "git scope: remote default validator retains130" {
  scope_default_validation_case remote 130
}

@test "git scope: remote default validator retains143" {
  scope_default_validation_case remote 143
}
