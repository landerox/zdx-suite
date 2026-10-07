#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper

  export LC_ALL=C
  export TERM=dumb
  export NO_COLOR=1
  export PAGER=cat
  export GIT_PAGER=cat
  export GIT_TERMINAL_PROMPT=0
  export GIT_ALLOW_PROTOCOL=file
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_AUTHOR_NAME="Remote Test"
  export GIT_AUTHOR_EMAIL="remote-test@example.invalid"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
}

teardown() {
  cleanup_sandbox
}

init_bare_remote() {
  export REMOTE_REPO="$HOME/remote.git"
  git init -q --bare "$REMOTE_REPO"
  git -C "$REMOTE_REPO" symbolic-ref HEAD refs/heads/main
}

init_empty_remote_worktree() {
  init_bare_remote

  export WORK_REPO="$HOME/work"
  git init -q "$WORK_REPO"
  git -C "$WORK_REPO" symbolic-ref HEAD refs/heads/main
  printf '%s\n' "base" > "$WORK_REPO/tracked.txt"
  git -C "$WORK_REPO" add -- tracked.txt
  git -C "$WORK_REPO" commit -q -m "base"
  git -C "$WORK_REPO" remote add origin "$REMOTE_REPO"
}

init_seeded_remote_worktree() {
  init_bare_remote

  export SEED_REPO="$HOME/seed"
  git init -q "$SEED_REPO"
  git -C "$SEED_REPO" symbolic-ref HEAD refs/heads/main
  printf '%s\n' "base" > "$SEED_REPO/tracked.txt"
  git -C "$SEED_REPO" add -- tracked.txt
  git -C "$SEED_REPO" commit -q -m "base"
  git -C "$SEED_REPO" remote add origin "$REMOTE_REPO"
  git -C "$SEED_REPO" push -q origin refs/heads/main:refs/heads/main

  export WORK_REPO="$HOME/work"
  git clone -q "$REMOTE_REPO" "$WORK_REPO"
}

@test "git-push: dry run is inert and authorized push updates the exact ref" {
  init_empty_remote_worktree

  run run_zsh '
    cd "$WORK_REPO" || return 90

    git-push \
      --remote origin \
      --ref refs/heads/main \
      --set-upstream \
      --dry-run \
      >"$HOME/push-dry.stdout" 2>"$HOME/push-dry.stderr" \
      || return 10

    command git --git-dir="$REMOTE_REPO" show-ref \
      --verify --quiet refs/heads/main && return 11
    command git config --get branch.main.remote >/dev/null 2>&1 \
      && return 12

    git-push \
      --remote origin \
      --ref refs/heads/main \
      --set-upstream \
      --yes \
      >"$HOME/push.stdout" 2>"$HOME/push.stderr" \
      || return 13
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/push-dry.stderr" ] || cat "$HOME/push-dry.stderr" >&2
    [ ! -f "$HOME/push.stderr" ] || cat "$HOME/push.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/push-dry.stdout" ]
  [ ! -s "$HOME/push.stdout" ]
  grep -Fq "DRY-RUN" "$HOME/push-dry.stderr"

  local local_oid remote_oid
  local_oid=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  remote_oid=$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)
  [ "$remote_oid" = "$local_oid" ]
  [ "$(git -C "$WORK_REPO" config --get branch.main.remote)" = "origin" ]
  [ "$(git -C "$WORK_REPO" config --get branch.main.merge)" = \
    "refs/heads/main" ]
  [ "$(git --git-dir="$REMOTE_REPO" for-each-ref \
    --format='%(refname)' refs/heads)" = "refs/heads/main" ]
}

@test "git-push: multiple push URLs are rejected before planning" {
  init_empty_remote_worktree
  local second_remote="$HOME/second.git"
  git init -q --bare "$second_remote"
  git -C "$WORK_REPO" config --add remote.origin.pushurl "$REMOTE_REPO"
  git -C "$WORK_REPO" config --add remote.origin.pushurl "$second_remote"

  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --remote origin --ref refs/heads/main --dry-run \
      >"$HOME/multi-push.stdout" 2>"$HOME/multi-push.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -s "$HOME/multi-push.stdout" ]
  grep -Fq "exactly one push URL" "$HOME/multi-push.stderr"
  ! git --git-dir="$REMOTE_REPO" show-ref \
    --verify --quiet refs/heads/main || false
  ! git --git-dir="$second_remote" show-ref \
    --verify --quiet refs/heads/main || false
}

@test "git-push: normal mode refuses a non-fast-forward remote tip" {
  init_seeded_remote_worktree

  printf '%s\n' "remote divergence" > "$SEED_REPO/tracked.txt"
  git -C "$SEED_REPO" commit -qam "remote divergence"
  git -C "$SEED_REPO" push -q origin refs/heads/main:refs/heads/main
  local expected_remote
  expected_remote=$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)

  printf '%s\n' "local divergence" > "$WORK_REPO/local.txt"
  git -C "$WORK_REPO" add -- local.txt
  git -C "$WORK_REPO" commit -q -m "local divergence"

  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --remote origin --ref refs/heads/main --yes \
      >"$HOME/non-ff.stdout" 2>"$HOME/non-ff.stderr"
  '

  [ "$status" -eq 1 ]
  [ ! -s "$HOME/non-ff.stdout" ]
  grep -Eq "Cannot prove a fast-forward|Refusing non-fast-forward" \
    "$HOME/non-ff.stderr"
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" = \
    "$expected_remote" ]
}

@test "git-pull: dry run fetches nothing and ff-only applies the frozen tip" {
  init_seeded_remote_worktree

  printf '%s\n' "remote update" > "$SEED_REPO/tracked.txt"
  git -C "$SEED_REPO" commit -qam "remote update"
  git -C "$SEED_REPO" push -q origin refs/heads/main:refs/heads/main

  export EXPECTED_BEFORE
  EXPECTED_BEFORE=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  export EXPECTED_AFTER
  EXPECTED_AFTER=$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)
  [ "$EXPECTED_BEFORE" != "$EXPECTED_AFTER" ]

  run run_zsh '
    cd "$WORK_REPO" || return 90

    git-pull \
      --remote origin \
      --ref refs/heads/main \
      --ff-only \
      --dry-run \
      >"$HOME/pull-dry.stdout" 2>"$HOME/pull-dry.stderr" \
      || return 20

    [[ "$(command git rev-parse HEAD)" == "$EXPECTED_BEFORE" ]] \
      || return 21
    [[ "$(command git rev-parse refs/remotes/origin/main)" \
      == "$EXPECTED_BEFORE" ]] || return 22
    command git cat-file -e "${EXPECTED_AFTER}^{commit}" 2>/dev/null \
      && return 23

    git-pull \
      --remote origin \
      --ref refs/heads/main \
      --ff-only \
      --yes \
      >"$HOME/pull.stdout" 2>"$HOME/pull.stderr" \
      || return 24
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/pull-dry.stderr" ] || cat "$HOME/pull-dry.stderr" >&2
    [ ! -f "$HOME/pull.stderr" ] || cat "$HOME/pull.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/pull-dry.stdout" ]
  [ ! -s "$HOME/pull.stdout" ]
  grep -Fq "DRY-RUN" "$HOME/pull-dry.stderr"
  [ "$(git -C "$WORK_REPO" rev-parse HEAD)" = "$EXPECTED_AFTER" ]
  [ "$(git -C "$WORK_REPO" rev-parse refs/remotes/origin/main)" = \
    "$EXPECTED_AFTER" ]
  [ "$(cat "$WORK_REPO/tracked.txt")" = "remote update" ]
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" = \
    "$EXPECTED_AFTER" ]
  [ -z "$(git -C "$WORK_REPO" for-each-ref \
    --format='%(refname)' refs/zdx-suite)" ]
}

@test "git-pull: fetch-prune dry run preserves tracking refs and real run converges" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch stale main
  git -C "$SEED_REPO" push -q origin refs/heads/stale:refs/heads/stale
  git -C "$WORK_REPO" fetch -q origin

  git -C "$SEED_REPO" push -q origin :refs/heads/stale
  git -C "$SEED_REPO" switch -q -c fresh main
  printf '%s\n' "fresh" > "$SEED_REPO/fresh.txt"
  git -C "$SEED_REPO" add -- fresh.txt
  git -C "$SEED_REPO" commit -q -m "fresh"
  git -C "$SEED_REPO" push -q origin refs/heads/fresh:refs/heads/fresh
  git -C "$SEED_REPO" switch -q main

  export EXPECTED_HEAD
  EXPECTED_HEAD=$(git -C "$WORK_REPO" rev-parse HEAD)
  export EXPECTED_FRESH
  EXPECTED_FRESH=$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/fresh)

  run run_zsh '
    cd "$WORK_REPO" || return 90

    git-pull \
      --remote origin \
      --fetch-prune \
      --dry-run \
      >"$HOME/prune-dry.stdout" 2>"$HOME/prune-dry.stderr" \
      || return 30

    command git show-ref --verify --quiet refs/remotes/origin/stale \
      || return 31
    command git show-ref --verify --quiet refs/remotes/origin/fresh \
      && return 32
    [[ "$(command git rev-parse HEAD)" == "$EXPECTED_HEAD" ]] \
      || return 33
    [[ -z "$(command git for-each-ref \
      --format="%(refname)" refs/zdx-suite)" ]] || return 34

    git-pull \
      --remote origin \
      --fetch-prune \
      --yes \
      >"$HOME/prune.stdout" 2>"$HOME/prune.stderr" \
      || return 35
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/prune-dry.stderr" ] || cat "$HOME/prune-dry.stderr" >&2
    [ ! -f "$HOME/prune.stderr" ] || cat "$HOME/prune.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/prune-dry.stdout" ]
  [ ! -s "$HOME/prune.stdout" ]
  grep -Fq "DRY-RUN" "$HOME/prune-dry.stderr"
  if git -C "$WORK_REPO" show-ref --verify --quiet \
    refs/remotes/origin/stale; then
    printf '%s\n' "stale tracking ref survived fetch-prune" >&2
    return 1
  fi
  [ "$(git -C "$WORK_REPO" rev-parse refs/remotes/origin/fresh)" = \
    "$EXPECTED_FRESH" ]
  [ "$(git -C "$WORK_REPO" rev-parse HEAD)" = "$EXPECTED_HEAD" ]
  [ -z "$(git -C "$WORK_REPO" for-each-ref \
    --format='%(refname)' refs/zdx-suite)" ]
}

@test "git-tag-create: dry run is inert and creates the exact annotated tag" {
  init_seeded_remote_worktree

  export EXPECTED_TARGET
  EXPECTED_TARGET=$(git -C "$WORK_REPO" rev-parse HEAD)

  run run_zsh '
    cd "$WORK_REPO" || return 90

    git-tag-create \
      --name release-create \
      --annotated \
      --message "Release create" \
      --dry-run \
      >"$HOME/tag-create-dry.stdout" \
      2>"$HOME/tag-create-dry.stderr" \
      || return 40

    command git show-ref --verify --quiet refs/tags/release-create \
      && return 41

    git-tag-create \
      --name release-create \
      --annotated \
      --message "Release create" \
      --yes \
      >"$HOME/tag-create.stdout" 2>"$HOME/tag-create.stderr" \
      || return 42

    git-tag-verify release-create \
      >"$HOME/tag-verify.stdout" 2>"$HOME/tag-verify.stderr"
    local -i verify_rc=$?
    (( verify_rc != 0 )) || return 43
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/tag-create-dry.stderr" ] \
      || cat "$HOME/tag-create-dry.stderr" >&2
    [ ! -f "$HOME/tag-create.stderr" ] \
      || cat "$HOME/tag-create.stderr" >&2
    [ ! -f "$HOME/tag-verify.stderr" ] \
      || cat "$HOME/tag-verify.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/tag-create-dry.stdout" ]
  [ ! -s "$HOME/tag-create.stdout" ]
  [ ! -s "$HOME/tag-verify.stdout" ]
  grep -Fq "DRY-RUN" "$HOME/tag-create-dry.stderr"
  grep -Fq "signature verification failed" "$HOME/tag-verify.stderr"
  [ "$(git -C "$WORK_REPO" cat-file -t refs/tags/release-create)" = \
    "tag" ]
  [ "$(git -C "$WORK_REPO" for-each-ref \
    --format='%(contents:subject)' refs/tags/release-create)" = \
    "Release create" ]
  [ "$(git -C "$WORK_REPO" rev-parse refs/tags/release-create^{})" = \
    "$EXPECTED_TARGET" ]
  if git --git-dir="$REMOTE_REPO" show-ref --verify --quiet \
    refs/tags/release-create; then
    printf '%s\n' "local-only tag creation changed the remote" >&2
    return 1
  fi
}

@test "git-tag push and delete: exact selected refs change locally and remotely" {
  init_seeded_remote_worktree

  git -C "$WORK_REPO" tag release-a
  git -C "$WORK_REPO" tag release-b
  export RELEASE_A_OID
  RELEASE_A_OID=$(git -C "$WORK_REPO" rev-parse refs/tags/release-a)
  export RELEASE_B_OID
  RELEASE_B_OID=$(git -C "$WORK_REPO" rev-parse refs/tags/release-b)

  run run_zsh '
    cd "$WORK_REPO" || return 90

    git-tag-push \
      --remote origin \
      --dry-run \
      release-a \
      >"$HOME/tag-push-dry.stdout" 2>"$HOME/tag-push-dry.stderr" \
      || return 50
    command git --git-dir="$REMOTE_REPO" show-ref \
      --verify --quiet refs/tags/release-a && return 51
    command git --git-dir="$REMOTE_REPO" show-ref \
      --verify --quiet refs/tags/release-b && return 52

    git-tag-push \
      --remote origin \
      --yes \
      release-a release-b \
      >"$HOME/tag-push.stdout" 2>"$HOME/tag-push.stderr" \
      || return 53
    [[ "$(command git --git-dir="$REMOTE_REPO" \
      rev-parse refs/tags/release-a)" == "$RELEASE_A_OID" ]] \
      || return 54
    [[ "$(command git --git-dir="$REMOTE_REPO" \
      rev-parse refs/tags/release-b)" == "$RELEASE_B_OID" ]] \
      || return 55

    git-tag-delete \
      --delete-remote \
      --remote origin \
      --dry-run \
      release-a \
      >"$HOME/tag-delete-dry.stdout" 2>"$HOME/tag-delete-dry.stderr" \
      || return 56
    [[ "$(command git rev-parse refs/tags/release-a)" \
      == "$RELEASE_A_OID" ]] || return 57
    [[ "$(command git --git-dir="$REMOTE_REPO" \
      rev-parse refs/tags/release-a)" == "$RELEASE_A_OID" ]] \
      || return 58

    git-tag-delete \
      --delete-remote \
      --remote origin \
      --yes \
      release-a \
      >"$HOME/tag-delete.stdout" 2>"$HOME/tag-delete.stderr" \
      || return 59
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/tag-push-dry.stderr" ] \
      || cat "$HOME/tag-push-dry.stderr" >&2
    [ ! -f "$HOME/tag-push.stderr" ] || cat "$HOME/tag-push.stderr" >&2
    [ ! -f "$HOME/tag-delete-dry.stderr" ] \
      || cat "$HOME/tag-delete-dry.stderr" >&2
    [ ! -f "$HOME/tag-delete.stderr" ] \
      || cat "$HOME/tag-delete.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/tag-push-dry.stdout" ]
  [ ! -s "$HOME/tag-push.stdout" ]
  [ ! -s "$HOME/tag-delete-dry.stdout" ]
  [ ! -s "$HOME/tag-delete.stdout" ]
  if ! grep -Fq "DRY-RUN" "$HOME/tag-push-dry.stderr"; then
    printf '%s\n' "tag push dry-run diagnostic was missing" >&2
    cat "$HOME/tag-push-dry.stderr" >&2
    return 1
  fi
  grep -Fq "DRY-RUN" "$HOME/tag-delete-dry.stderr"

  if git -C "$WORK_REPO" show-ref --verify --quiet \
    refs/tags/release-a; then
    printf '%s\n' "selected local tag survived deletion" >&2
    return 1
  fi
  if git --git-dir="$REMOTE_REPO" show-ref --verify --quiet \
    refs/tags/release-a; then
    printf '%s\n' "selected remote tag survived deletion" >&2
    return 1
  fi
  [ "$(git -C "$WORK_REPO" rev-parse refs/tags/release-b)" = \
    "$RELEASE_B_OID" ]
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/tags/release-b)" = \
    "$RELEASE_B_OID" ]
}

@test "clean-branches: dry run preserves and authorized cleanup deletes only merged target" {
  init_seeded_remote_worktree

  git -C "$WORK_REPO" branch merged-local main
  git -C "$WORK_REPO" config branch.merged-local.remote origin
  git -C "$WORK_REPO" config branch.merged-local.merge refs/heads/merged-local
  git -C "$WORK_REPO" switch -q -c unmerged-local main
  printf '%s\n' "unmerged" > "$WORK_REPO/unmerged.txt"
  git -C "$WORK_REPO" add -- unmerged.txt
  git -C "$WORK_REPO" commit -q -m "unmerged local"
  git -C "$WORK_REPO" switch -q main
  export MERGED_LOCAL_OID
  MERGED_LOCAL_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/merged-local)
  export UNMERGED_LOCAL_OID
  UNMERGED_LOCAL_OID=$(git -C "$WORK_REPO" \
    rev-parse refs/heads/unmerged-local)

  run run_zsh '
    cd "$WORK_REPO" || return 90

    clean-branches \
      --dry-run \
      merged-local \
      >"$HOME/clean-local-dry.stdout" \
      2>"$HOME/clean-local-dry.stderr" \
      || return 60
    [[ "$(command git rev-parse refs/heads/merged-local)" \
      == "$MERGED_LOCAL_OID" ]] || return 61
    [[ "$(command git rev-parse refs/heads/unmerged-local)" \
      == "$UNMERGED_LOCAL_OID" ]] || return 62

    clean-branches \
      --yes \
      merged-local \
      >"$HOME/clean-local.stdout" 2>"$HOME/clean-local.stderr" \
      || return 63
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/clean-local-dry.stderr" ] \
      || cat "$HOME/clean-local-dry.stderr" >&2
    [ ! -f "$HOME/clean-local.stderr" ] \
      || cat "$HOME/clean-local.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/clean-local-dry.stdout" ]
  [ ! -s "$HOME/clean-local.stdout" ]
  if ! grep -Fq "DRY-RUN" "$HOME/clean-local-dry.stderr"; then
    printf '%s\n' "local clean dry-run diagnostic was missing" >&2
    cat "$HOME/clean-local-dry.stderr" >&2
    return 1
  fi
  if git -C "$WORK_REPO" show-ref --verify --quiet \
    refs/heads/merged-local; then
    printf '%s\n' "merged local target survived cleanup" >&2
    return 1
  fi
  git -C "$WORK_REPO" show-ref --verify --quiet refs/heads/main
  [ "$(git -C "$WORK_REPO" rev-parse refs/heads/unmerged-local)" = \
    "$UNMERGED_LOCAL_OID" ]
  # Like git branch -d, a recreated branch must not inherit the old upstream.
  [ -z "$(git -C "$WORK_REPO" config --get-regexp '^branch\.merged-local\.' || true)" ]
}

@test "clean-remote-merged: dry run is inert and leased cleanup deletes only merged remote target" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-remote main
  git -C "$SEED_REPO" push -q \
    origin refs/heads/merged-remote:refs/heads/merged-remote
  git -C "$SEED_REPO" switch -q -c unmerged-remote main
  printf '%s\n' "unmerged remote" > "$SEED_REPO/unmerged-remote.txt"
  git -C "$SEED_REPO" add -- unmerged-remote.txt
  git -C "$SEED_REPO" commit -q -m "unmerged remote"
  git -C "$SEED_REPO" push -q \
    origin refs/heads/unmerged-remote:refs/heads/unmerged-remote
  git -C "$SEED_REPO" switch -q main
  git -C "$WORK_REPO" fetch -q origin

  export MERGED_REMOTE_OID
  MERGED_REMOTE_OID=$(git --git-dir="$REMOTE_REPO" \
    rev-parse refs/heads/merged-remote)
  export UNMERGED_REMOTE_OID
  UNMERGED_REMOTE_OID=$(git --git-dir="$REMOTE_REPO" \
    rev-parse refs/heads/unmerged-remote)
  export MAIN_REMOTE_OID
  MAIN_REMOTE_OID=$(git --git-dir="$REMOTE_REPO" \
    rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90

    clean-remote-merged \
      --remote origin \
      --dry-run \
      merged-remote \
      >"$HOME/clean-remote-dry.stdout" \
      2>"$HOME/clean-remote-dry.stderr" \
      || return 70
    [[ "$(command git --git-dir="$REMOTE_REPO" \
      rev-parse refs/heads/merged-remote)" == "$MERGED_REMOTE_OID" ]] \
      || return 71
    [[ "$(command git rev-parse refs/remotes/origin/merged-remote)" \
      == "$MERGED_REMOTE_OID" ]] || return 72
    [[ "$(command git --git-dir="$REMOTE_REPO" \
      rev-parse refs/heads/unmerged-remote)" == "$UNMERGED_REMOTE_OID" ]] \
      || return 73
    [[ "$(command git --git-dir="$REMOTE_REPO" \
      rev-parse refs/heads/main)" == "$MAIN_REMOTE_OID" ]] || return 74

    clean-remote-merged \
      --remote origin \
      --yes \
      merged-remote \
      >"$HOME/clean-remote.stdout" 2>"$HOME/clean-remote.stderr" \
      || return 75
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/clean-remote-dry.stderr" ] \
      || cat "$HOME/clean-remote-dry.stderr" >&2
    [ ! -f "$HOME/clean-remote.stderr" ] \
      || cat "$HOME/clean-remote.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/clean-remote-dry.stdout" ]
  [ ! -s "$HOME/clean-remote.stdout" ]
  if ! grep -Fq "DRY-RUN" "$HOME/clean-remote-dry.stderr"; then
    printf '%s\n' "remote clean dry-run diagnostic was missing" >&2
    cat "$HOME/clean-remote-dry.stderr" >&2
    return 1
  fi
  if git --git-dir="$REMOTE_REPO" show-ref --verify --quiet \
    refs/heads/merged-remote; then
    printf '%s\n' "merged remote target survived cleanup" >&2
    return 1
  fi
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" = \
    "$MAIN_REMOTE_OID" ]
  [ "$(git --git-dir="$REMOTE_REPO" \
    rev-parse refs/heads/unmerged-remote)" = "$UNMERGED_REMOTE_OID" ]
  [ "$(git --git-dir="$REMOTE_REPO" for-each-ref \
    --format='%(refname)' refs/heads)" = \
    $'refs/heads/main\nrefs/heads/unmerged-remote' ]
  # The URL push bypasses the fetch refspec; the stale tracking ref must go.
  ! git -C "$WORK_REPO" show-ref --verify --quiet \
    refs/remotes/origin/merged-remote || false
  git -C "$WORK_REPO" show-ref --verify --quiet \
    refs/remotes/origin/unmerged-remote
}

@test "git-push: exact plans ignore push.followTags and keep stdout empty across refs" {
  init_empty_remote_worktree
  git -C "$WORK_REPO" config push.followTags true
  git -C "$WORK_REPO" config push.recurseSubmodules check
  git -C "$WORK_REPO" tag -a -m unreleased unreleased-v9

  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --remote origin --ref refs/heads/main --yes \
      >"$HOME/branch.stdout" 2>"$HOME/branch.stderr" || return 10
    command git branch b1 && command git branch b2 \
      && command git branch b3 || return 11
    git-push --remote origin --all --yes \
      >"$HOME/all.stdout" 2>"$HOME/all.stderr" || return 12
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    cat "$HOME/branch.stderr" "$HOME/all.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/branch.stdout" ]
  [ ! -s "$HOME/all.stdout" ]
  grep -Fq "Push complete: 3 ref update(s)." "$HOME/all.stderr"
  [ "$(git --git-dir="$REMOTE_REPO" for-each-ref --format='%(refname)')" = \
    $'refs/heads/b1\nrefs/heads/b2\nrefs/heads/b3\nrefs/heads/main' ]
}

@test "git-tag-push: an exact tag push ignores push.followTags" {
  init_empty_remote_worktree
  git -C "$WORK_REPO" push -q origin refs/heads/main:refs/heads/main
  git -C "$WORK_REPO" config push.followTags true
  git -C "$WORK_REPO" tag -a -m internal internal-rc
  git -C "$WORK_REPO" tag v1

  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-push --remote origin --yes v1 \
      >"$HOME/tag.stdout" 2>"$HOME/tag.stderr"
  '

  [ "$status" -eq 0 ] || { cat "$HOME/tag.stderr" >&2; false; }
  [ ! -s "$HOME/tag.stdout" ]
  [ "$(git --git-dir="$REMOTE_REPO" for-each-ref --format='%(refname)')" = \
    $'refs/heads/main\nrefs/tags/v1' ]
}

@test "git remote snapshots ignore ls-remote tail matches outside the namespace" {
  init_empty_remote_worktree
  git -C "$WORK_REPO" push -q origin \
    refs/heads/main:refs/heads/main \
    refs/heads/main:refs/heads/ci/refs/tags/nightly \
    refs/heads/main:refs/tags/rel/refs/heads/x
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" tag v1

  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-push --remote origin --dry-run v1 \
      >"$HOME/tag.stdout" 2>"$HOME/tag.stderr" || return 10
    git-pull --fetch-prune --yes \
      >"$HOME/prune.stdout" 2>"$HOME/prune.stderr" || return 11
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    cat "$HOME/tag.stderr" "$HOME/prune.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  grep -Fq "refs/tags/v1 @" "$HOME/tag.stderr"
  ! grep -Fq "refs/heads/ci/refs/tags/nightly" "$HOME/tag.stderr" || false
  ! grep -Fq "refs/remotes/origin/refs/" "$HOME/prune.stderr" || false
  git -C "$WORK_REPO" show-ref --verify --quiet \
    refs/remotes/origin/ci/refs/tags/nightly
}

@test "git-push: upstream configuration uses the full tracking ref" {
  init_empty_remote_worktree
  # A local branch named origin/main makes the short upstream name ambiguous.
  git -C "$WORK_REPO" branch origin/main

  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --remote origin --set-upstream --yes \
      >"$HOME/push.stdout" 2>"$HOME/push.stderr"
  '

  [ "$status" -eq 0 ] || { cat "$HOME/push.stderr" >&2; false; }
  [ ! -s "$HOME/push.stdout" ]
  [ "$(git -C "$WORK_REPO" config branch.main.remote)" = origin ]
  [ "$(git -C "$WORK_REPO" config branch.main.merge)" = refs/heads/main ]
}
