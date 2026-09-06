#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export LC_ALL=C TERM=dumb NO_COLOR=1 GIT_TERMINAL_PROMPT=0
  export GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_AUTHOR_NAME="Sync Recovery Test"
  export GIT_AUTHOR_EMAIL="sync-recovery@example.invalid"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export REMOTE_REPO="$HOME/remote.git" WORK_REPO="$HOME/work"
  export SECOND_REMOTE="$HOME/second.git" SEED_REPO="$HOME/seed"
  git init -q --bare "$REMOTE_REPO"
  git -C "$REMOTE_REPO" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$SECOND_REMOTE"
  git init -q "$SEED_REPO"
  git -C "$SEED_REPO" symbolic-ref HEAD refs/heads/main
  git -C "$SEED_REPO" commit -q --allow-empty -m "fixture base"
  git -C "$SEED_REPO" push -q "$REMOTE_REPO" HEAD:refs/heads/main
  git clone -q "$REMOTE_REPO" "$WORK_REPO"
  git -C "$SEED_REPO" commit -q --allow-empty -m "fixture update"
  git -C "$SEED_REPO" push -q "$REMOTE_REPO" HEAD:refs/heads/main
  git -C "$WORK_REPO" config --add remote.origin.pushurl "$REMOTE_REPO"
  git -C "$WORK_REPO" config --add remote.origin.pushurl "$SECOND_REMOTE"
}

teardown() {
  cleanup_sandbox
}

@test "git-pull recovery: multiple push destinations do not block dry-run fetch" {
  local before
  before=$(git -C "$WORK_REPO" rev-parse refs/remotes/origin/main)
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-pull --remote origin --fetch --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [ "$(git -C "$WORK_REPO" rev-parse refs/remotes/origin/main)" = "$before" ]
  [ -z "$(git -C "$WORK_REPO" for-each-ref refs/zdx-suite/fetch)" ]
}

@test "git-pull recovery: exact fetch and ff-only use the fetch destination" {
  local before expected
  before=$(git -C "$WORK_REPO" rev-parse HEAD)
  expected=$(git -C "$REMOTE_REPO" rev-parse refs/heads/main)
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-pull --remote origin --fetch --yes || return
    [[ $(command git rev-parse HEAD) != $(command git rev-parse origin/main) ]] || return 91
    git-pull --remote origin --ff-only --yes
  '
  [ "$status" -eq 0 ]
  [ "$before" != "$expected" ]
  [ "$(git -C "$WORK_REPO" rev-parse HEAD)" = "$expected" ]
  [ -z "$(git -C "$SECOND_REMOTE" for-each-ref)" ]
  [ -z "$(git -C "$WORK_REPO" for-each-ref refs/zdx-suite/fetch)" ]
}

@test "git-pull recovery: fetch-prune works with multiple push destinations" {
  git -C "$WORK_REPO" update-ref refs/remotes/origin/stale HEAD
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-pull --remote origin --fetch-prune --yes
  '
  [ "$status" -eq 0 ]
  run git -C "$WORK_REPO" show-ref --verify --quiet refs/remotes/origin/stale
  [ "$status" -eq 1 ]
  [ "$(git -C "$WORK_REPO" rev-parse origin/main)" = \
    "$(git -C "$REMOTE_REPO" rev-parse refs/heads/main)" ]
  [ -z "$(git -C "$SECOND_REMOTE" for-each-ref)" ]
}

@test "git sync recovery: pushes and remote cleanup reject multiple destinations" {
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" branch merged origin/main
  git -C "$WORK_REPO" push -q "$REMOTE_REPO" merged:refs/heads/merged
  git -C "$WORK_REPO" push -q "$SECOND_REMOTE" merged:refs/heads/merged
  git -C "$WORK_REPO" fetch -q origin
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --remote origin --yes
    [[ $? == 1 ]] || return 91
    clean-remote-merged --remote origin --yes merged
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly one push URL"* ]]
  git -C "$REMOTE_REPO" show-ref --verify --quiet refs/heads/merged
  git -C "$SECOND_REMOTE" show-ref --verify --quiet refs/heads/merged
}
