#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  export GIT_ALLOW_PROTOCOL=file
  export GIT_AUTHOR_NAME="Remote Proof Test"
  export GIT_AUTHOR_EMAIL="proof@example.invalid"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export REAL_GIT
  REAL_GIT=$(command -v git)
}

teardown() {
  cleanup_sandbox
}

proof_commit() {
  printf '%s\n' "$2" > "$1/$2.txt"
  "$REAL_GIT" -C "$1" add -- "$2.txt"
  "$REAL_GIT" -C "$1" commit -q -m "$2"
}

proof_remote_pair() {
  export REMOTE_REPO="$HOME/remote.git" WORK_REPO="$HOME/work" PEER_REPO="$HOME/peer"
  "$REAL_GIT" init -q --bare "$REMOTE_REPO"
  "$REAL_GIT" -C "$REMOTE_REPO" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" init -q -b main "$PEER_REPO"
  proof_commit "$PEER_REPO" base
  "$REAL_GIT" -C "$PEER_REPO" remote add origin "$REMOTE_REPO"
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  "$REAL_GIT" clone -q "$REMOTE_REPO" "$WORK_REPO"
}

proof_pr_context() {
  cat > "$HOME/pr-context.zsh" <<'ZSH'
_git_gh_repo_context() {
  typeset -gA _GIT_GH_REPO=(target github.com/example/repository id R_proof
    host github.com name example/repository url https://github.com/example/repository)
}
_git_gh_remote_identity() {
  reply=(github.com/example/repository "$REMOTE_REPO" example)
}
_git_gh_base_oid() { REPLY=$(command git rev-parse refs/heads/main); }
_git_gh_require_same_repo() { return 0; }
ZSH
  cat > "$TEST_MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == 'repo view --repo github.com/example/repository --json defaultBranchRef --template {{.defaultBranchRef.name}}' ]]; then
  printf 'main\n'
  exit 0
fi
printf 'denied unexpected gh call: %s\n' "$*" >&2
exit 97
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/gh"
}

proof_dump_failure() {
  if [ "$status" -ne "$1" ]; then
    printf 'status=%s output=%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/result.stderr" ] || cat "$HOME/result.stderr" >&2
    false
  fi
}

@test "remote proofs: replacement refs cannot authorize non-fast-forward PR publication" {
  proof_remote_pair
  "$REAL_GIT" -C "$PEER_REPO" switch -q -c feature
  proof_commit "$PEER_REPO" peer
  "$REAL_GIT" -C "$PEER_REPO" push -q origin feature
  "$REAL_GIT" -C "$WORK_REPO" fetch -q origin
  "$REAL_GIT" -C "$WORK_REPO" switch -q -c feature main
  proof_commit "$WORK_REPO" local
  local remote_oid local_oid
  remote_oid=$("$REAL_GIT" -C "$PEER_REPO" rev-parse HEAD)
  local_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$WORK_REPO" replace --graft "$local_oid" "$remote_oid"
  proof_pr_context

  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
    source "$HOME/pr-context.zsh" || return 92
    git-pr-create --base main --fill --dry-run >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/result.stdout" ]
  grep -Fq 'is not an ancestor of HEAD' "$HOME/result.stderr"
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/feature)" = "$remote_oid" ]
}

proof_grafted_cleanup() {
  proof_remote_pair
  "$REAL_GIT" -C "$PEER_REPO" switch -q -c topic
  proof_commit "$PEER_REPO" unmerged
  "$REAL_GIT" -C "$PEER_REPO" push -q origin topic
  "$REAL_GIT" -C "$PEER_REPO" switch -q main
  proof_commit "$PEER_REPO" main-only
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  "$REAL_GIT" -C "$WORK_REPO" fetch -q origin
  "$REAL_GIT" -C "$WORK_REPO" merge -q --ff-only origin/main
  "$REAL_GIT" -C "$WORK_REPO" branch topic origin/topic >/dev/null
  "$REAL_GIT" -C "$WORK_REPO" replace --graft refs/heads/main refs/heads/topic
  export TOPIC_OID
  TOPIC_OID=$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/heads/topic)
}

@test "remote proofs: replacement refs cannot make local cleanup delete unmerged work" {
  proof_grafted_cleanup
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 0
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse --verify refs/heads/topic)" = "$TOPIC_OID" ]
  [ ! -s "$HOME/result.stdout" ]
}

@test "remote proofs: replacement refs cannot make remote cleanup delete unmerged work" {
  proof_grafted_cleanup
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-remote-merged --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 0
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse --verify refs/heads/topic)" = "$TOPIC_OID" ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse --verify refs/remotes/origin/topic)" = "$TOPIC_OID" ]
  [ ! -s "$HOME/result.stdout" ]
}

@test "remote proofs: rebase preserves stacked branches outside its reviewed plan" {
  proof_remote_pair
  proof_commit "$PEER_REPO" peer
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  proof_commit "$WORK_REPO" local-one
  "$REAL_GIT" -C "$WORK_REPO" branch stack
  proof_commit "$WORK_REPO" local-two
  "$REAL_GIT" -C "$WORK_REPO" config rebase.updateRefs true
  local stack_before remote_oid
  stack_before=$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/heads/stack)
  remote_oid=$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-pull --rebase --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 0
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/heads/stack)" = "$stack_before" ]
  "$REAL_GIT" -C "$WORK_REPO" merge-base --is-ancestor "$remote_oid" refs/heads/main
  [ ! -s "$HOME/result.stdout" ]
}

proof_unintegrated_remote() {
  proof_remote_pair
  proof_commit "$PEER_REPO" peer
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  "$REAL_GIT" -C "$WORK_REPO" fetch -q origin
  proof_commit "$WORK_REPO" rewrite
  export PEER_OID
  PEER_OID=$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)
}

@test "remote proofs: force push refuses a fetched tip never integrated into the local branch" {
  proof_unintegrated_remote
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --force-with-lease --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$PEER_OID" ]
  grep -Fq 'was never integrated' "$HOME/result.stderr"
  [ ! -s "$HOME/result.stdout" ]
}

@test "remote proofs: force push ancestry ignores grafts of a never-integrated tip" {
  proof_unintegrated_remote
  "$REAL_GIT" -C "$WORK_REPO" replace --graft refs/heads/main "$PEER_OID"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --force-with-lease --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$PEER_OID" ]
}

@test "remote proofs: force push accepts a tip integrated by an earlier branch reflog entry" {
  proof_remote_pair
  local base_oid
  base_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  proof_commit "$PEER_REPO" peer
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  "$REAL_GIT" -C "$WORK_REPO" fetch -q origin
  "$REAL_GIT" -C "$WORK_REPO" merge -q --ff-only origin/main
  "$REAL_GIT" -C "$WORK_REPO" reset -q --hard "$base_oid"
  proof_commit "$WORK_REPO" rewrite
  local desired_oid
  desired_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --force-with-lease --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 0
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$desired_oid" ]
  [ ! -s "$HOME/result.stdout" ]
}

@test "remote proofs: PR remote URL follows the ls-remote option terminator" {
  proof_remote_pair
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == ls-remote ]]; then
  printf '%s\n' "$@" > "$HOME/remote.argv"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
    _git_gh_remote_head_oid "$REMOTE_REPO" main
  '
  [ "$status" -eq 0 ]
  mapfile -t argv < "$HOME/remote.argv"
  [ "${argv[3]}" = -- ]
  [ "${argv[4]}" = "$REMOTE_REPO" ]
  [ "${argv[5]}" = refs/heads/main ]
}

@test "remote proofs: a symbolic branch on the server is refused before a normal push" {
  proof_remote_pair
  "$REAL_GIT" -C "$REMOTE_REPO" symbolic-ref refs/heads/alias refs/heads/main
  "$REAL_GIT" -C "$WORK_REPO" switch -q -c alias
  proof_commit "$WORK_REPO" local
  local protected_oid
  protected_oid=$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --remote origin --ref refs/heads/alias --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$protected_oid" ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" symbolic-ref refs/heads/alias)" = refs/heads/main ]
  grep -Fq 'symbolic' "$HOME/result.stderr"
}

@test "remote proofs: a server branch that becomes symbolic after confirmation is refused" {
  proof_remote_pair
  "$REAL_GIT" -C "$REMOTE_REPO" branch protected main
  proof_commit "$WORK_REPO" local
  local protected_oid
  protected_oid=$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/protected)
  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
    _git_sync_confirm_outcome() {
      command git -C "$REMOTE_REPO" symbolic-ref refs/heads/main refs/heads/protected || return 92
      REPLY=confirmed
    }
    git-push --remote origin --ref refs/heads/main >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/protected)" = "$protected_oid" ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" symbolic-ref refs/heads/main)" = refs/heads/protected ]
  grep -Fq 'symbolic' "$HOME/result.stderr"
}

@test "remote proofs: branch publication fails closed when the server does not answer in protocol v2" {
  proof_remote_pair
  proof_commit "$WORK_REPO" local
  local remote_before
  remote_before=$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-} ${3:-}" == '-c protocol.version=2 ls-remote' ]]; then
  shift 2
  exec "$REAL_GIT" -c protocol.version=0 "$@"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$remote_before" ]
  grep -Fq 'did not answer with protocol v2' "$HOME/result.stderr"
  grep -Fq 'AcceptEnv GIT_PROTOCOL' "$HOME/result.stderr"
}

@test "remote proofs: an interrupted branch alias query preserves 130 and 143 without pushing" {
  proof_remote_pair
  proof_commit "$WORK_REPO" local
  local remote_before signal_status
  remote_before=$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-} ${3:-}" == '-c protocol.version=2 ls-remote' ]]; then
  exit "$MOCK_SYMREF_STATUS"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  for signal_status in 130 143; do
    export MOCK_SYMREF_STATUS="$signal_status"
    run run_zsh '
      cd "$WORK_REPO" || return 90
      git-push --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    '
    proof_dump_failure "$signal_status"
    [ "$status" -eq "$signal_status" ]
    [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$remote_before" ]
    [ ! -s "$HOME/result.stdout" ]
  done
}

@test "remote proofs: PR publication refuses a remote alias of the base branch" {
  proof_remote_pair
  "$REAL_GIT" -C "$WORK_REPO" switch -q -c feature
  proof_commit "$WORK_REPO" local
  "$REAL_GIT" -C "$REMOTE_REPO" symbolic-ref refs/heads/feature refs/heads/main
  local protected_oid
  protected_oid=$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)
  proof_pr_context
  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
    source "$HOME/pr-context.zsh" || return 92
    git-pr-create --base main --fill --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$protected_oid" ]
  grep -Fq 'symbolic' "$HOME/result.stderr"
}

@test "remote proofs: force-lease integration is revalidated after confirmation" {
  proof_remote_pair
  local base_oid peer_oid
  base_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  proof_commit "$PEER_REPO" peer
  "$REAL_GIT" -C "$PEER_REPO" push -q origin main
  "$REAL_GIT" -C "$WORK_REPO" fetch -q origin
  "$REAL_GIT" -C "$WORK_REPO" merge -q --ff-only origin/main
  "$REAL_GIT" -C "$WORK_REPO" reset -q --hard "$base_oid"
  proof_commit "$WORK_REPO" rewrite
  peer_oid=$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)
  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
    _git_sync_confirm_outcome() {
      command git reflog expire --expire=all refs/heads/main || return 92
      REPLY=confirmed
    }
    git-push --force-with-lease >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$peer_oid" ]
  grep -Fq 'was never integrated' "$HOME/result.stderr"
}

@test "remote proofs: PR publication rechecks a server alias created after confirmation" {
  proof_remote_pair
  "$REAL_GIT" -C "$REMOTE_REPO" branch feature main
  "$REAL_GIT" -C "$WORK_REPO" switch -q -c feature
  proof_commit "$WORK_REPO" local
  local protected_oid
  protected_oid=$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)
  proof_pr_context
  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 91
    source "$HOME/pr-context.zsh" || return 92
    _git_confirm_outcome() {
      command git -C "$REMOTE_REPO" symbolic-ref refs/heads/feature refs/heads/main || return 93
      REPLY=confirmed
    }
    git-pr-create --base main --fill >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$protected_oid" ]
  grep -Fq 'symbolic' "$HOME/result.stderr"
}

@test "remote proofs: legacy graft files cannot authorize normal or forced publication" {
  proof_unintegrated_remote
  local local_oid mode
  local_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  printf '%s %s\n' "$local_oid" "$PEER_OID" > "$WORK_REPO/.git/info/grafts"
  for mode in normal force; do
    export PROOF_PUSH_MODE="$mode"
    run run_zsh '
      cd "$WORK_REPO" || return 90
      local -a flags=(--dry-run)
      [[ "$PROOF_PUSH_MODE" == force ]] && flags+=(--force-with-lease)
      git-push "${flags[@]}" >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    '
    proof_dump_failure 1
    [ "$status" -eq 1 ]
    [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$PEER_OID" ]
    [ ! -s "$HOME/result.stdout" ]
  done
}

@test "remote proofs: inherited graft files cannot authorize force integration" {
  proof_unintegrated_remote
  local local_oid
  local_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  printf '%s %s\n' "$local_oid" "$PEER_OID" > "$HOME/alternate-grafts"
  export GIT_GRAFT_FILE="$HOME/alternate-grafts"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --force-with-lease --dry-run >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  grep -Fq 'was never integrated' "$HOME/result.stderr"
}

@test "remote proofs: legacy graft files cannot authorize PR publication" {
  proof_unintegrated_remote
  "$REAL_GIT" -C "$WORK_REPO" branch feature
  "$REAL_GIT" -C "$WORK_REPO" switch -q feature
  "$REAL_GIT" -C "$REMOTE_REPO" update-ref refs/heads/feature "$PEER_OID"
  local local_oid
  local_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  printf '%s %s\n' "$local_oid" "$PEER_OID" > "$WORK_REPO/.git/info/grafts"
  proof_pr_context
  run run_zsh '
    cd "$WORK_REPO" || return 90
    source "$HOME/pr-context.zsh" || return 91
    git-pr-create --base main --fill --dry-run >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  grep -Fq 'is not an ancestor of HEAD' "$HOME/result.stderr"
}

@test "remote proofs: legacy graft files cannot authorize local cleanup" {
  proof_grafted_cleanup
  "$REAL_GIT" -C "$WORK_REPO" replace -d main >/dev/null
  local main_oid
  main_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/heads/main)
  printf '%s %s\n' "$main_oid" "$TOPIC_OID" > "$WORK_REPO/.git/info/grafts"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 0
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/heads/topic)" = "$TOPIC_OID" ]
}

@test "remote proofs: legacy graft files cannot authorize remote cleanup" {
  proof_grafted_cleanup
  "$REAL_GIT" -C "$WORK_REPO" replace -d main >/dev/null
  local main_oid
  main_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/heads/main)
  printf '%s %s\n' "$main_oid" "$TOPIC_OID" > "$WORK_REPO/.git/info/grafts"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-remote-merged --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 0
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/topic)" = "$TOPIC_OID" ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse refs/remotes/origin/topic)" = "$TOPIC_OID" ]
}

@test "remote proofs: interrupted force-lease revalidation reports completed updates" {
  proof_remote_pair
  local before_oid desired_oid signal_status
  before_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  proof_commit "$WORK_REPO" local
  desired_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$WORK_REPO" branch first
  "$REAL_GIT" -C "$WORK_REPO" branch second
  "$REAL_GIT" -C "$REMOTE_REPO" update-ref refs/heads/second "$before_oid"
  export PROOF_BEFORE_OID="$before_oid" PROOF_DESIRED_OID="$desired_oid"
  for signal_status in 130 143; do
    "$REAL_GIT" -C "$REMOTE_REPO" update-ref refs/heads/first "$before_oid"
    export PROOF_SIGNAL_STATUS="$signal_status"
    run run_zsh '
      cd "$WORK_REPO" || return 90
      local -i proof_calls=0
      _git_push_require_integrated_lease() {
        (( ++proof_calls ))
        (( proof_calls == 1 )) && return 0
        return "$PROOF_SIGNAL_STATUS"
      }
      local first_record="refs/heads/first"$'"'"'\t'"'"'"$PROOF_DESIRED_OID"$'"'"'\t'"'"'"refs/heads/first"$'"'"'\t'"'"'"$PROOF_BEFORE_OID"
      local second_record="refs/heads/second"$'"'"'\t'"'"'"$PROOF_DESIRED_OID"$'"'"'\t'"'"'"refs/heads/second"$'"'"'\t'"'"'"$PROOF_BEFORE_OID"
      _git_push_apply_plan force origin "$REMOTE_REPO" "$first_record" "$second_record" \
        >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    '
    proof_dump_failure "$signal_status"
    [ "$status" -eq "$signal_status" ]
    [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/first)" = "$desired_oid" ]
    [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/second)" = "$before_oid" ]
    grep -Fq 'Push interrupted: 1 ref update completed before the interruption.' "$HOME/result.stderr"
    [ ! -s "$HOME/result.stdout" ]
  done
}

@test "remote proofs: a long reflog uses one reachability traversal" {
  proof_unintegrated_remote
  local number
  for number in 1 2 3 4 5 6 7 8; do
    proof_commit "$WORK_REPO" "local-$number"
  done
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == merge-base ]]; then
    printf 'merge-base\n' >> "$HOME/history-processes"
  elif [[ "$arg" == rev-list ]]; then
    printf 'rev-list\n' >> "$HOME/history-processes"
  fi
done
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    local local_oid=$(command git rev-parse HEAD)
    _git_push_require_integrated_lease refs/heads/main "$local_oid" "$PEER_OID" \
      >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  [ "$status" -eq 1 ]
  local traversals
  traversals=$(wc -l < "$HOME/history-processes")
  [ "$traversals" -le 3 ]
  grep -Fq 'was never integrated' "$HOME/result.stderr"
}

@test "remote proofs: a merged reflog entry proves integration before a later rewrite" {
  proof_unintegrated_remote
  local before_oid desired_oid
  before_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$WORK_REPO" merge -q --no-edit origin/main
  "$REAL_GIT" -C "$WORK_REPO" reset -q --hard "$before_oid"
  proof_commit "$WORK_REPO" rewrite-after-merge
  desired_oid=$("$REAL_GIT" -C "$WORK_REPO" rev-parse HEAD)
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --force-with-lease --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 0
  [ "$status" -eq 0 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$desired_oid" ]
}

@test "remote proofs: an unrelated root tip is not integrated by other branch histories" {
  proof_remote_pair
  "$REAL_GIT" -C "$PEER_REPO" switch -q --orphan unrelated
  proof_commit "$PEER_REPO" unrelated
  local unrelated_oid
  unrelated_oid=$("$REAL_GIT" -C "$PEER_REPO" rev-parse HEAD)
  "$REAL_GIT" -C "$PEER_REPO" push -q --force origin HEAD:refs/heads/main
  "$REAL_GIT" -C "$WORK_REPO" fetch -q origin
  proof_commit "$WORK_REPO" local
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --force-with-lease --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$unrelated_oid" ]
  grep -Fq 'was never integrated' "$HOME/result.stderr"
}

@test "remote proofs: reachability count failures and interruptions never authorize publication" {
  proof_unintegrated_remote
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ " $* " == *' rev-list --count --stdin '* ]]; then
  cat >/dev/null
  printf '%s\n' "$PROOF_COUNT_OUTPUT"
  exit "$PROOF_COUNT_STATUS"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  local wanted_status
  export PROOF_COUNT_OUTPUT=malformed
  for wanted_status in 0 42 130 143; do
    export PROOF_COUNT_STATUS="$wanted_status"
    run run_zsh '
      cd "$WORK_REPO" || return 90
      git-push --force-with-lease --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
    '
    if [ "$wanted_status" -eq 130 ] || [ "$wanted_status" -eq 143 ]; then
      [ "$status" -eq "$wanted_status" ]
    else
      proof_dump_failure 1
      [ "$status" -eq 1 ]
      grep -Fq 'Unable to verify the force-lease branch reflog history.' "$HOME/result.stderr"
    fi
    [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$PEER_OID" ]
    [ ! -s "$HOME/result.stdout" ]
  done
}

@test "remote proofs: an empty successful reflog observation refuses without traversing remote history" {
  proof_unintegrated_remote
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ " $* " == *' rev-list --walk-reflogs '* ]]; then
  exit 0
elif [[ " $* " == *' rev-list --count --stdin '* ]]; then
  cat >/dev/null
  : > "$HOME/unnecessary-history-walk"
  printf '1\n'
  exit 0
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --force-with-lease --yes >"$HOME/result.stdout" 2>"$HOME/result.stderr"
  '
  proof_dump_failure 1
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/unnecessary-history-walk" ]
  [ "$("$REAL_GIT" -C "$REMOTE_REPO" rev-parse refs/heads/main)" = "$PEER_OID" ]
  grep -Fq 'was never integrated' "$HOME/result.stderr"
}
