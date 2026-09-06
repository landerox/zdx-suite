#!/usr/bin/env bats
# Literal Zsh programs and per-test exported controls are intentional.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export PR_REVIEWED_HEAD=1111111111111111111111111111111111111111
  export PR_MERGE_RC=0 PR_FINAL_STATE=MERGED PR_FINAL_HEAD="$PR_REVIEWED_HEAD"
  export PR_READ_RC=0 PR_ALLOW=0
  cat > "$TEST_MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env zsh
case "$1 $2" in
  'pr view')
    if [[ -e "$HOME/merge.called" ]]; then
      print -r -- post-query >> "$HOME/post.queries"
      (( PR_READ_RC == 0 )) || exit "$PR_READ_RC"
      printf 'PR_test\t%s\t%s\n' "$PR_FINAL_STATE" "$PR_FINAL_HEAD"
    else
      printf 'PR_test\tOPEN\t%s\n' "$PR_REVIEWED_HEAD"
    fi
    ;;
  'pr merge')
    print -r -- "$*" > "$HOME/merge.called"
    exit "$PR_MERGE_RC"
    ;;
  *) print -u2 -r -- "Unexpected gh action: $1 $2"; exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/gh"
}

teardown() {
  cleanup_sandbox
}

run_merge() {
  run_zsh '
    _git_require_interactive() { return 0; }
    _git_gh_repo_context() {
      typeset -gA _GIT_GH_REPO=(target github.example.invalid/team/repo id R_test)
    }
    _git_gh_require_same_repo() { return 0; }
    _git_gh_pick_state() { REPLY=open; }
    _git_gh_pick_pr() {
      reply=(PR_test 17 open https://github.example.invalid/team/repo/pull/17
        "$PR_REVIEWED_HEAD" topic "Reviewed title")
    }
    _git_fzf() {
      local offered="$(command cat)"
      if [[ "$offered" == *"Merge pull request"* ]]; then
        print -r -- "Merge pull request"
      else
        print -r -- squash
      fi
    }
    _git_authorize() { return "$PR_ALLOW"; }
    git-prs > "$HOME/merge.stdout"
  '
}

@test "git PR merge recovery: success requires a verified merged state" {
  run run_merge
  [ "$status" -eq 0 ]
  [ -f "$HOME/post.queries" ]
  [ ! -s "$HOME/merge.stdout" ]
  [[ "$output" == *"Merged pull request #17."* ]]
  grep -Fxq "pr merge 17 --repo github.example.invalid/team/repo --squash --match-head-commit $PR_REVIEWED_HEAD" "$HOME/merge.called"
}

@test "git PR merge recovery: an accepted pending request is not reported as merged" {
  export PR_FINAL_STATE=OPEN
  run run_merge
  [ "$status" -eq 0 ]
  [[ "$output" == *"Merge request accepted for PR #17; it is still open."* ]]
  [[ "$output" != *"Merged pull request"* ]]
}

@test "git PR merge recovery: a closed unmerged result remains a failure" {
  export PR_FINAL_STATE=CLOSED
  run run_merge
  [ "$status" -eq 1 ]
  [[ "$output" != *"Merged pull request"* ]]
}

@test "git PR merge recovery: a failed post-query cannot claim a completed merge" {
  export PR_READ_RC=42
  run run_merge
  [ "$status" -eq 1 ]
  [ -f "$HOME/merge.called" ]
  [[ "$output" == *"could not verify its final state"* ]]
  [[ "$output" != *"Merged pull request"* ]]
}

@test "git PR merge recovery: a different resulting head is not accepted" {
  export PR_FINAL_HEAD=2222222222222222222222222222222222222222
  run run_merge
  [ "$status" -eq 1 ]
  [[ "$output" != *"Merged pull request"* ]]
}

@test "git PR merge recovery: backend failure preserves status without another query" {
  export PR_MERGE_RC=42
  run run_merge
  [ "$status" -eq 42 ]
  [ ! -e "$HOME/post.queries" ]
  [[ "$output" != *"Merged pull request"* ]]
}

@test "git PR merge recovery: a declined plan never submits a merge" {
  export PR_ALLOW=3
  run run_merge
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/merge.called" ]
  [ ! -e "$HOME/post.queries" ]
}
