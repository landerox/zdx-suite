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

# Exports REAL_GIT, the git executable that a test wrapper delegates to.
export_real_git() {
  export REAL_GIT
  REAL_GIT=$(command -v git)
}

# Installs a git wrapper that turns the ref named by the first `update-ref -d`
# into a symbolic ref to TARGET just before Git deletes it, as a concurrent
# writer could after the plan was reviewed and revalidated. Bats-side checks
# that run after it use $REAL_GIT.
install_symref_swap_before_delete() {
  export SWAP_TARGET="$1" REAL_GIT
  REAL_GIT=$(command -v git)
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == update-ref && ! -e "$HOME/.symref-swap.done" ]]; then
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == -d ]]; then
      : >"$HOME/.symref-swap.done"
      "$REAL_GIT" symbolic-ref "$argument" "$SWAP_TARGET" || exit 97
      break
    fi
    previous="$argument"
  done
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"
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
  grep -Fq "Dry run: " "$HOME/push-dry.stderr"

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
  grep -Fq "Dry run: " "$HOME/pull-dry.stderr"
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
  grep -Fq "Dry run: " "$HOME/prune-dry.stderr"
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

@test "git-pull: fetch-prune and temporary-ref transactions never dereference a symbolic ref" {
  init_seeded_remote_worktree

  export TAB=$'\t' LEASE_OID MOVED_OID
  LEASE_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  MOVED_OID=$(git -C "$WORK_REPO" commit-tree -p "$LEASE_OID" -m moved \
    "${LEASE_OID}^{tree}")
  git -C "$WORK_REPO" branch keep main
  git -C "$WORK_REPO" branch hold main
  # Planned refs that became symbolic aliases of protected branches after the
  # plan was frozen. `option no-deref` covers only the next command, so each
  # alias follows a direct ref in its transaction.
  git -C "$WORK_REPO" update-ref refs/remotes/origin/aa-stale "$LEASE_OID"
  git -C "$WORK_REPO" symbolic-ref refs/remotes/origin/zz-moved refs/heads/keep
  git -C "$WORK_REPO" symbolic-ref refs/remotes/origin/zz-stale refs/heads/main
  git -C "$WORK_REPO" update-ref refs/zdx-suite/fetch/probe/aa "$LEASE_OID"
  git -C "$WORK_REPO" symbolic-ref refs/zdx-suite/fetch/probe/zz refs/heads/hold

  run run_zsh '
    cd "$WORK_REPO" || return 90

    _git_pull_apply_prune_plan origin \
      "refs/remotes/origin/aa-stale${TAB}${LEASE_OID}${TAB}absent${TAB}absent" \
      "refs/remotes/origin/zz-moved${TAB}${LEASE_OID}${TAB}refs/heads/zz-moved${TAB}${MOVED_OID}" \
      "refs/remotes/origin/zz-stale${TAB}${LEASE_OID}${TAB}absent${TAB}absent" \
      >"$HOME/prune.stdout" 2>"$HOME/prune.stderr" || return 40
    _git_sync_cleanup_temp_refs refs/zdx-suite/fetch/probe \
      "${LEASE_OID}${TAB}refs/zdx-suite/fetch/probe/aa" \
      "${LEASE_OID}${TAB}refs/zdx-suite/fetch/probe/zz" \
      >"$HOME/cleanup.stdout" 2>"$HOME/cleanup.stderr" || return 41
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/prune.stderr" ] || cat "$HOME/prune.stderr" >&2
    [ ! -f "$HOME/cleanup.stderr" ] || cat "$HOME/cleanup.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/prune.stdout" ]
  [ ! -s "$HOME/cleanup.stdout" ]

  local problems="" branch
  for branch in main keep hold; do
    [ "$(git -C "$WORK_REPO" rev-parse --verify --quiet "refs/heads/$branch")" \
      = "$LEASE_OID" ] || problems+=" refs/heads/$branch-changed-through-an-alias"
  done
  printf 'problems:%s\n' "${problems:- none}" >&2
  [ -z "$problems" ]

  # Only the planned names changed: the deleted aliases are gone, and the
  # updated alias is now a direct ref at the fetched commit.
  [ "$(git -C "$WORK_REPO" rev-parse refs/remotes/origin/zz-moved)" = \
    "$MOVED_OID" ]
  [ -z "$(git -C "$WORK_REPO" for-each-ref --format='%(symref)' \
    refs/remotes/origin/zz-moved)" ]
  [ -z "$(git -C "$WORK_REPO" for-each-ref --format='%(refname)' \
    refs/remotes/origin/aa-stale refs/remotes/origin/zz-stale refs/zdx-suite)" ]
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
  grep -Fq "Dry run: " "$HOME/tag-create-dry.stderr"
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
  if ! grep -Fq "Dry run: " "$HOME/tag-push-dry.stderr"; then
    printf '%s\n' "tag push dry-run diagnostic was missing" >&2
    cat "$HOME/tag-push-dry.stderr" >&2
    return 1
  fi
  grep -Fq "Dry run: " "$HOME/tag-delete-dry.stderr"

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
  if ! grep -Fq "Dry run: " "$HOME/clean-local-dry.stderr"; then
    printf '%s\n' "local clean dry-run diagnostic was missing" >&2
    cat "$HOME/clean-local-dry.stderr" >&2
    return 1
  fi
  grep -Fq "Dry run: 1 merged local branch planned; nothing was deleted." \
    "$HOME/clean-local-dry.stderr"
  grep -Eq '^ +Branch +Ref +Commit$' "$HOME/clean-local-dry.stderr"
  grep -Fq "refs/heads/merged-local — done: deleted at" "$HOME/clean-local.stderr"
  grep -Fq "Local cleanup complete: 1 branch deleted." "$HOME/clean-local.stderr"
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
  if ! grep -Fq "Dry run: " "$HOME/clean-remote-dry.stderr"; then
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

@test "clean-branches: a symbolic branch alias is never planned and main survives" {
  init_seeded_remote_worktree

  git -C "$WORK_REPO" branch merged-local main
  # A master -> main migration alias resolves to the current and default
  # branch, so a deletion through it would delete main.
  git -C "$WORK_REPO" symbolic-ref refs/heads/master refs/heads/main
  export ALIAS_MAIN_OID
  ALIAS_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90

    clean-branches --dry-run \
      >"$HOME/alias-dry.stdout" 2>"$HOME/alias-dry.stderr" || return 80
    [[ "$(<"$HOME/alias-dry.stderr")" != *refs/heads/master* ]] || return 81

    clean-branches --yes master \
      >"$HOME/alias-named.stdout" 2>"$HOME/alias-named.stderr"
    named_rc=$?
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$ALIAS_MAIN_OID" ]] || return 82
    (( named_rc == 1 )) || return 83

    clean-branches --yes \
      >"$HOME/alias.stdout" 2>"$HOME/alias.stderr" || return 84
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/alias-dry.stderr" ] || cat "$HOME/alias-dry.stderr" >&2
    [ ! -f "$HOME/alias-named.stderr" ] \
      || cat "$HOME/alias-named.stderr" >&2
    [ ! -f "$HOME/alias.stderr" ] || cat "$HOME/alias.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/alias-dry.stdout" ]
  [ ! -s "$HOME/alias-named.stdout" ]
  [ ! -s "$HOME/alias.stdout" ]
  grep -Fq "Dry run: 1 merged local branch planned; nothing was deleted." \
    "$HOME/alias-dry.stderr"
  grep -Fq \
    "Branch 'master' is protected, symbolic, checked out, unmerged, or absent." \
    "$HOME/alias-named.stderr"
  grep -Fq "refs/heads/merged-local — done: deleted at" "$HOME/alias.stderr"
  grep -Fq "Local cleanup complete: 1 branch deleted." "$HOME/alias.stderr"
  [ "$(git -C "$WORK_REPO" rev-parse refs/heads/main)" = "$ALIAS_MAIN_OID" ]
  [ "$(git -C "$WORK_REPO" symbolic-ref refs/heads/master)" = \
    refs/heads/main ]
  run git -C "$WORK_REPO" show-ref --verify --quiet refs/heads/merged-local
  [ "$status" -eq 1 ]
}

@test "clean-branches: deletion removes a branch swapped to a symbolic alias, never its target" {
  init_seeded_remote_worktree

  git -C "$WORK_REPO" branch merged-local main
  export SWAP_MAIN_OID
  SWAP_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  install_symref_swap_before_delete refs/heads/main

  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-branches --yes merged-local \
      >"$HOME/swap.stdout" 2>"$HOME/swap.stderr"
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/swap.stderr" ] || cat "$HOME/swap.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/swap.stdout" ]
  [ -e "$HOME/.symref-swap.done" ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse --verify --quiet \
    refs/heads/main)" = "$SWAP_MAIN_OID" ]
  grep -Fq "refs/heads/merged-local — done: deleted at $SWAP_MAIN_OID" \
    "$HOME/swap.stderr"
  [ -z "$("$REAL_GIT" -C "$WORK_REPO" for-each-ref --format='%(refname)' \
    refs/heads/merged-local)" ]
}

@test "clean-remote-merged: a symbolic tracking ref is never planned and main survives" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-remote main
  git -C "$SEED_REPO" branch alias-branch main
  git -C "$SEED_REPO" push -q origin \
    refs/heads/merged-remote:refs/heads/merged-remote \
    refs/heads/alias-branch:refs/heads/alias-branch
  git -C "$WORK_REPO" fetch -q origin
  # A tracking alias that resolves to the local current and default branch.
  git -C "$WORK_REPO" symbolic-ref refs/remotes/origin/alias-branch \
    refs/heads/main
  export TRACKING_ALIAS_MAIN_OID
  TRACKING_ALIAS_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90

    clean-remote-merged --remote origin --dry-run \
      >"$HOME/alias-dry.stdout" 2>"$HOME/alias-dry.stderr" || return 85
    [[ "$(<"$HOME/alias-dry.stderr")" != *alias-branch* ]] || return 86

    clean-remote-merged --remote origin --yes alias-branch \
      >"$HOME/alias-named.stdout" 2>"$HOME/alias-named.stderr"
    named_rc=$?
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$TRACKING_ALIAS_MAIN_OID" ]] || return 87
    (( named_rc == 1 )) || return 88

    clean-remote-merged --remote origin --yes \
      >"$HOME/alias.stdout" 2>"$HOME/alias.stderr" || return 89
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/alias-dry.stderr" ] || cat "$HOME/alias-dry.stderr" >&2
    [ ! -f "$HOME/alias-named.stderr" ] \
      || cat "$HOME/alias-named.stderr" >&2
    [ ! -f "$HOME/alias.stderr" ] || cat "$HOME/alias.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/alias-dry.stdout" ]
  [ ! -s "$HOME/alias-named.stdout" ]
  [ ! -s "$HOME/alias.stdout" ]
  grep -Fq "Dry run: 1 merged branch planned on 'origin'; nothing was deleted." \
    "$HOME/alias-dry.stderr"
  grep -Fq \
    "Branch 'alias-branch' is protected, symbolic, checked out, unmerged, or absent." \
    "$HOME/alias-named.stderr"
  grep -Fq "Remote cleanup complete: 1 branch deleted." "$HOME/alias.stderr"
  [ "$(git -C "$WORK_REPO" rev-parse refs/heads/main)" = "$TRACKING_ALIAS_MAIN_OID" ]
  [ "$(git -C "$WORK_REPO" symbolic-ref refs/remotes/origin/alias-branch)" = \
    refs/heads/main ]
  [ "$(git --git-dir="$REMOTE_REPO" for-each-ref \
    --format='%(refname)' refs/heads)" = \
    $'refs/heads/alias-branch\nrefs/heads/main' ]
}

@test "clean-remote-merged: tracking-ref removal cannot dereference a ref swapped after review" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-remote main
  git -C "$SEED_REPO" push -q \
    origin refs/heads/merged-remote:refs/heads/merged-remote
  git -C "$WORK_REPO" fetch -q origin
  export TRACKING_SWAP_MAIN_OID
  TRACKING_SWAP_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  install_symref_swap_before_delete refs/heads/main

  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-remote-merged --remote origin --yes merged-remote \
      >"$HOME/swap.stdout" 2>"$HOME/swap.stderr"
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/swap.stderr" ] || cat "$HOME/swap.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/swap.stdout" ]
  [ -e "$HOME/.symref-swap.done" ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse --verify --quiet \
    refs/heads/main)" = "$TRACKING_SWAP_MAIN_OID" ]
  grep -Fq "Remote cleanup complete: 1 branch deleted." "$HOME/swap.stderr"
  [ -z "$("$REAL_GIT" -C "$WORK_REPO" for-each-ref --format='%(refname)' \
    refs/remotes/origin/merged-remote)" ]
  run grep -Fq "was kept" "$HOME/swap.stderr"
  [ "$status" -eq 1 ]
  run "$REAL_GIT" --git-dir="$REMOTE_REPO" show-ref --verify --quiet \
    refs/heads/merged-remote
  [ "$status" -eq 1 ]
}

@test "clean-remote-merged: a symbolic branch on the remote is never planned and the remote main survives" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-remote main
  git -C "$SEED_REPO" push -q \
    origin refs/heads/merged-remote:refs/heads/merged-remote
  # A server-side alias: the server deletes the target of a symbolic ref
  # that a push deletes.
  git --git-dir="$REMOTE_REPO" symbolic-ref refs/heads/alias refs/heads/main
  git -C "$WORK_REPO" fetch -q origin
  export REMOTE_ALIAS_MAIN_OID
  REMOTE_ALIAS_MAIN_OID=$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90

    clean-remote-merged --remote origin --dry-run \
      >"$HOME/alias-dry.stdout" 2>"$HOME/alias-dry.stderr" || return 20
    [[ "$(<"$HOME/alias-dry.stderr")" != *refs/heads/alias* ]] || return 21

    clean-remote-merged --remote origin --yes alias \
      >"$HOME/alias-named.stdout" 2>"$HOME/alias-named.stderr"
    named_rc=$?
    [[ "$(command git --git-dir="$REMOTE_REPO" rev-parse --verify --quiet \
      refs/heads/main)" == "$REMOTE_ALIAS_MAIN_OID" ]] || return 22
    (( named_rc == 1 )) || return 23

    clean-remote-merged --remote origin --yes \
      >"$HOME/alias.stdout" 2>"$HOME/alias.stderr" || return 24
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/alias-dry.stderr" ] || cat "$HOME/alias-dry.stderr" >&2
    [ ! -f "$HOME/alias-named.stderr" ] \
      || cat "$HOME/alias-named.stderr" >&2
    [ ! -f "$HOME/alias.stderr" ] || cat "$HOME/alias.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/alias-dry.stdout" ]
  [ ! -s "$HOME/alias-named.stdout" ]
  [ ! -s "$HOME/alias.stdout" ]
  grep -Fq "Dry run: 1 merged branch planned on 'origin'; nothing was deleted." \
    "$HOME/alias-dry.stderr"
  grep -Fq \
    "Branch 'alias' is protected, symbolic, checked out, unmerged, or absent." \
    "$HOME/alias-named.stderr"
  grep -Fq "Remote cleanup complete: 1 branch deleted." "$HOME/alias.stderr"
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" = \
    "$REMOTE_ALIAS_MAIN_OID" ]
  [ "$(git --git-dir="$REMOTE_REPO" symbolic-ref refs/heads/alias)" = \
    refs/heads/main ]
  [ "$(git --git-dir="$REMOTE_REPO" for-each-ref \
    --format='%(refname)' refs/heads)" = \
    $'refs/heads/alias\nrefs/heads/main' ]
}

@test "clean-remote-merged: a tracking ref that turns symbolic after confirmation is never pushed" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-remote main
  git -C "$SEED_REPO" push -q \
    origin refs/heads/merged-remote:refs/heads/merged-remote
  git -C "$WORK_REPO" fetch -q origin
  export LATE_TRACKING_MAIN_OID LATE_TRACKING_REMOTE_OID
  LATE_TRACKING_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  LATE_TRACKING_REMOTE_OID=$(git --git-dir="$REMOTE_REPO" \
    rev-parse refs/heads/merged-remote)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    # Git updates the tracking ref of a URL push itself, through any alias.
    _git_clean_confirm_outcome() {
      command git symbolic-ref refs/remotes/origin/merged-remote \
        refs/heads/main || return 1
      REPLY=confirmed
    }
    clean-remote-merged --remote origin merged-remote \
      >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    print -r -- "$?"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1" ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/late.stderr" ] || cat "$HOME/late.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ ! -s "$HOME/late.stdout" ]
  grep -Fq "the tracking ref origin/merged-remote is now symbolic" "$HOME/late.stderr"
  [ "$(git -C "$WORK_REPO" rev-parse --verify --quiet refs/heads/main)" = \
    "$LATE_TRACKING_MAIN_OID" ]
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse --verify --quiet \
    refs/heads/merged-remote)" = "$LATE_TRACKING_REMOTE_OID" ]
}

@test "git-tag-delete: a symbolic tag on the remote is refused and the remote main survives" {
  init_seeded_remote_worktree

  # A server-side tag alias of main, fetched as an ordinary local tag.
  git --git-dir="$REMOTE_REPO" symbolic-ref refs/tags/rel refs/heads/main
  git -C "$WORK_REPO" fetch -q origin 'refs/tags/*:refs/tags/*'
  export REMOTE_TAG_MAIN_OID
  REMOTE_TAG_MAIN_OID=$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    git-tag-delete rel --remote origin --dry-run \
      >"$HOME/tag-dry.stdout" 2>"$HOME/tag-dry.stderr"
    codes+=($?)
    git-tag-delete rel --remote origin --yes \
      >"$HOME/tag.stdout" 2>"$HOME/tag.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    [ ! -f "$HOME/tag-dry.stderr" ] || cat "$HOME/tag-dry.stderr" >&2
    [ ! -f "$HOME/tag.stderr" ] || cat "$HOME/tag.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  [ ! -s "$HOME/tag-dry.stdout" ]
  [ ! -s "$HOME/tag.stdout" ]
  grep -Fq "Remote tag 'rel' is a symbolic ref on the remote" \
    "$HOME/tag-dry.stderr"
  grep -Fq "Remote tag 'rel' is a symbolic ref on the remote" \
    "$HOME/tag.stderr"
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse --verify --quiet \
    refs/heads/main)" = "$REMOTE_TAG_MAIN_OID" ]
  [ "$(git --git-dir="$REMOTE_REPO" symbolic-ref refs/tags/rel)" = \
    refs/heads/main ]
  git -C "$WORK_REPO" show-ref --verify --quiet refs/tags/rel
}

@test "git-push: a symbolic remote-tracking ref is refused and the branch it names never moves" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" switch -q -c feature
  printf '%s\n' "feature" > "$SEED_REPO/feature.txt"
  git -C "$SEED_REPO" add -- feature.txt
  git -C "$SEED_REPO" commit -q -m "feature"
  git -C "$SEED_REPO" push -q origin refs/heads/feature:refs/heads/feature
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" switch -q -c feature --track origin/feature
  printf '%s\n' "local feature" >> "$WORK_REPO/feature.txt"
  git -C "$WORK_REPO" commit -qam "local feature"
  export PUSH_ALIAS_MAIN_OID PUSH_ALIAS_REMOTE_OID
  PUSH_ALIAS_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  PUSH_ALIAS_REMOTE_OID=$(git --git-dir="$REMOTE_REPO" \
    rev-parse refs/heads/feature)
  # A push to the remote URL updates the matching tracking ref itself, and
  # Git follows this alias to local main.
  git -C "$WORK_REPO" symbolic-ref refs/remotes/origin/feature refs/heads/main

  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --yes >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    plan_rc=$?
    [[ "$(command git rev-parse refs/heads/main)" == "$PUSH_ALIAS_MAIN_OID" ]] \
      || return 10
    [[ "$(command git --git-dir="$REMOTE_REPO" rev-parse refs/heads/feature)" \
      == "$PUSH_ALIAS_REMOTE_OID" ]] || return 11

    # An alias that appears after confirmation is refused right before the
    # push. From main, the context fingerprint does not cover this ref.
    command git update-ref --no-deref refs/remotes/origin/feature \
      "$PUSH_ALIAS_REMOTE_OID" || return 12
    command git switch -q main || return 12
    _git_sync_confirm_outcome() {
      command git symbolic-ref refs/remotes/origin/feature refs/heads/main \
        || return 1
      REPLY=confirmed
    }
    git-push --all >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    late_rc=$?
    [[ "$(command git rev-parse refs/heads/main)" == "$PUSH_ALIAS_MAIN_OID" ]] \
      || return 13
    [[ "$(command git --git-dir="$REMOTE_REPO" rev-parse refs/heads/feature)" \
      == "$PUSH_ALIAS_REMOTE_OID" ]] || return 14
    print -r -- "$plan_rc:$late_rc"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1:1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    [ ! -f "$HOME/plan.stderr" ] || cat "$HOME/plan.stderr" >&2
    [ ! -f "$HOME/late.stderr" ] || cat "$HOME/late.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1:1" ]
  [ ! -s "$HOME/plan.stdout" ]
  [ ! -s "$HOME/late.stdout" ]
  grep -Fq "Remote-tracking ref 'origin/feature' is a symbolic ref" \
    "$HOME/plan.stderr"
  grep -Fq "Remote-tracking ref 'origin/feature' is a symbolic ref" \
    "$HOME/late.stderr"
}

@test "clean-remote-merged: a remote branch that turns symbolic between targets is never pushed" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-a main
  git -C "$SEED_REPO" branch merged-b main
  git -C "$SEED_REPO" push -q origin \
    refs/heads/merged-a:refs/heads/merged-a \
    refs/heads/merged-b:refs/heads/merged-b
  git -C "$WORK_REPO" fetch -q origin
  export BETWEEN_MAIN_OID
  BETWEEN_MAIN_OID=$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)
  export_real_git
  # After the first target's push the server turns the second target into an
  # alias of main, so deleting it there would delete main.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == push && " $* " == *" :refs/heads/merged-a "* ]]; then
  "$REAL_GIT" "$@"
  push_rc=$?
  "$REAL_GIT" --git-dir="$REMOTE_REPO" symbolic-ref refs/heads/merged-b \
    refs/heads/main || exit 97
  exit "$push_rc"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$WORK_REPO" || return 90
    clean-remote-merged --remote origin --yes \
      >"$HOME/between.stdout" 2>"$HOME/between.stderr"
    print -r -- "$?"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1" ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/between.stderr" ] || cat "$HOME/between.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ ! -s "$HOME/between.stdout" ]
  grep -Fq "the remote branch is now symbolic" "$HOME/between.stderr"
  [ "$("$REAL_GIT" --git-dir="$REMOTE_REPO" rev-parse --verify --quiet \
    refs/heads/main)" = "$BETWEEN_MAIN_OID" ]
  run "$REAL_GIT" --git-dir="$REMOTE_REPO" show-ref --verify --quiet \
    refs/heads/merged-a
  [ "$status" -eq 1 ]
}

@test "clean-remote-merged: a tracking ref that cannot be inspected before its push is never pushed" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-remote main
  git -C "$SEED_REPO" push -q \
    origin refs/heads/merged-remote:refs/heads/merged-remote
  git -C "$WORK_REPO" fetch -q origin
  export UNREADABLE_REMOTE_OID
  UNREADABLE_REMOTE_OID=$(git --git-dir="$REMOTE_REPO" \
    rev-parse refs/heads/merged-remote)
  export_real_git
  # git symbolic-ref fails for the tracking ref, as it does for a corrupt ref,
  # while $HOME/.unreadable exists.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == symbolic-ref && -e "$HOME/.unreadable" \
  && " $* " == *" refs/remotes/origin/merged-remote "* ]]; then
  printf '%s\n' "fatal: unable to read the ref" >&2
  exit 128
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    : >"$HOME/.unreadable"
    clean-remote-merged --remote origin --yes merged-remote \
      >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    codes+=($?)

    # The ref becomes unreadable only after confirmation.
    command rm -f -- "$HOME/.unreadable"
    _git_clean_confirm_outcome() {
      : >"$HOME/.unreadable"
      REPLY=confirmed
    }
    clean-remote-merged --remote origin merged-remote \
      >"$HOME/unreadable.stdout" 2>"$HOME/unreadable.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    cat "$HOME/plan.stderr" "$HOME/unreadable.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  grep -Fq "Unable to inspect the remote-tracking ref 'origin/merged-remote'." \
    "$HOME/plan.stderr"
  grep -Fq "the tracking ref origin/merged-remote could not be inspected" \
    "$HOME/unreadable.stderr"
  [ "$("$REAL_GIT" --git-dir="$REMOTE_REPO" rev-parse --verify --quiet \
    refs/heads/merged-remote)" = "$UNREADABLE_REMOTE_OID" ]
}

@test "remote deletions refuse when the remote does not answer with protocol v2" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-remote main
  git -C "$SEED_REPO" push -q \
    origin refs/heads/merged-remote:refs/heads/merged-remote
  # Server-side aliases of main, which only protocol v2 reports.
  git --git-dir="$REMOTE_REPO" symbolic-ref refs/heads/alias refs/heads/main
  git --git-dir="$REMOTE_REPO" symbolic-ref refs/tags/rel refs/heads/main
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" fetch -q origin 'refs/tags/*:refs/tags/*'
  export NO_V2_MAIN_OID
  NO_V2_MAIN_OID=$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)
  export_real_git
  # A server that never answers in protocol v2.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-} ${3:-}" == "-c protocol.version=2 ls-remote" ]]; then
  shift 2
  exec "$REAL_GIT" -c protocol.version=0 "$@"
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    clean-remote-merged --remote origin --yes \
      >"$HOME/clean.stdout" 2>"$HOME/clean.stderr"
    codes+=($?)
    git-tag-delete rel --remote origin --yes \
      >"$HOME/tag.stdout" 2>"$HOME/tag.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/clean.stderr" "$HOME/tag.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  grep -Fq "did not answer with protocol v2" "$HOME/clean.stderr"
  grep -Fq "AcceptEnv GIT_PROTOCOL" "$HOME/clean.stderr"
  grep -Fq "did not answer with protocol v2" "$HOME/tag.stderr"
  # Nothing was deleted on the server, and the local tag is kept.
  [ "$("$REAL_GIT" --git-dir="$REMOTE_REPO" for-each-ref \
    --format='%(refname)' refs/heads refs/tags)" = \
    $'refs/heads/alias\nrefs/heads/main\nrefs/heads/merged-remote\nrefs/tags/rel' ]
  [ "$("$REAL_GIT" --git-dir="$REMOTE_REPO" rev-parse refs/heads/main)" = \
    "$NO_V2_MAIN_OID" ]
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/rel
}

@test "remote deletions block a target when the remote stops answering with protocol v2" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-remote main
  git -C "$SEED_REPO" push -q \
    origin refs/heads/merged-remote:refs/heads/merged-remote
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" tag release
  git -C "$WORK_REPO" push -q origin refs/tags/release
  export STOP_V2_MERGED_OID
  STOP_V2_MERGED_OID=$(git --git-dir="$REMOTE_REPO" \
    rev-parse refs/heads/merged-remote)
  export_real_git
  # The planning query answers in protocol v2; every later one does not.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-} ${3:-}" == "-c protocol.version=2 ls-remote" ]]; then
  count=$(cat "$HOME/.probe-count" 2>/dev/null || printf '0')
  printf '%s\n' "$(( count + 1 ))" > "$HOME/.probe-count"
  if (( count >= 1 )); then
    shift 2
    exec "$REAL_GIT" -c protocol.version=0 "$@"
  fi
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    clean-remote-merged --remote origin --yes merged-remote \
      >"$HOME/clean.stdout" 2>"$HOME/clean.stderr"
    codes+=($?)
    command rm -f -- "$HOME/.probe-count"
    git-tag-delete release --remote origin --yes \
      >"$HOME/tag.stdout" 2>"$HOME/tag.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/clean.stderr" "$HOME/tag.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  grep -Fq "did not answer with protocol v2" "$HOME/clean.stderr"
  grep -Fq "did not answer with protocol v2" "$HOME/tag.stderr"
  [ "$("$REAL_GIT" --git-dir="$REMOTE_REPO" rev-parse refs/heads/merged-remote)" \
    = "$STOP_V2_MERGED_OID" ]
  "$REAL_GIT" --git-dir="$REMOTE_REPO" show-ref --verify --quiet \
    refs/tags/release
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
}

@test "remote deletions stop at an interrupted symbolic-ref query" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-a main
  git -C "$SEED_REPO" branch merged-b main
  git -C "$SEED_REPO" push -q origin \
    refs/heads/merged-a:refs/heads/merged-a \
    refs/heads/merged-b:refs/heads/merged-b
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" tag tag-a
  git -C "$WORK_REPO" tag tag-b
  git -C "$WORK_REPO" push -q origin refs/tags/tag-a refs/tags/tag-b
  export_real_git
  # The first query that names one ref is interrupted, as by Ctrl-C.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-} ${3:-}" == "-c protocol.version=2 ls-remote" \
  && "${!#}" != *'*' && ! -e "$HOME/.probe-interrupted" ]]; then
  : > "$HOME/.probe-interrupted"
  exit 130
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    clean-remote-merged --remote origin --yes \
      >"$HOME/clean.stdout" 2>"$HOME/clean.stderr"
    codes+=($?)
    command rm -f -- "$HOME/.probe-interrupted"
    git-tag-delete tag-a tag-b --remote origin --yes \
      >"$HOME/tag.stdout" 2>"$HOME/tag.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "130,130" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/clean.stderr" "$HOME/tag.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "130,130" ]
  # The interrupt stopped the whole run: no later target was deleted.
  [ "$("$REAL_GIT" --git-dir="$REMOTE_REPO" for-each-ref \
    --format='%(refname)' refs/heads refs/tags)" = \
    $'refs/heads/main\nrefs/heads/merged-a\nrefs/heads/merged-b\nrefs/tags/tag-a\nrefs/tags/tag-b' ]
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/tag-a
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/tag-b
}

@test "git-push: a symbolic ref that a custom fetch refspec maps the branch to is refused" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" switch -q -c feature
  printf '%s\n' "feature" > "$SEED_REPO/feature.txt"
  git -C "$SEED_REPO" add -- feature.txt
  git -C "$SEED_REPO" commit -q -m "feature"
  git -C "$SEED_REPO" push -q origin refs/heads/feature:refs/heads/feature
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" switch -q -c feature --track origin/feature
  printf '%s\n' "local feature" >> "$WORK_REPO/feature.txt"
  git -C "$WORK_REPO" commit -qam "local feature"
  # The remote's fetch refspec stores its branches below refs/remotes/cache/,
  # and the push would update cache/feature, an alias of local main.
  git -C "$WORK_REPO" config --replace-all remote.origin.fetch \
    '+refs/heads/*:refs/remotes/cache/*'
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" symbolic-ref refs/remotes/cache/feature refs/heads/main
  export REFSPEC_MAIN_OID REFSPEC_LOCAL_OID
  REFSPEC_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  REFSPEC_LOCAL_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/feature)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-push --yes >"$HOME/refspec.stdout" 2>"$HOME/refspec.stderr"
    refspec_rc=$?
    [[ "$(command git rev-parse refs/heads/main)" == "$REFSPEC_MAIN_OID" ]] \
      || return 10

    # A negative refspec does not stop Git from updating cache/feature after
    # the push, so the push stays refused.
    command git config --add remote.origin.fetch "^refs/heads/feature" \
      || return 11
    git-push --yes >"$HOME/negative.stdout" 2>"$HOME/negative.stderr"
    negative_rc=$?
    [[ "$(command git rev-parse refs/heads/main)" == "$REFSPEC_MAIN_OID" ]] \
      || return 12

    # With a direct ref there, the push goes ahead and Git updates that ref.
    command git update-ref --no-deref refs/remotes/cache/feature \
      "$REFSPEC_MAIN_OID" || return 13
    git-push --yes >"$HOME/direct.stdout" 2>"$HOME/direct.stderr"
    direct_rc=$?
    [[ "$(command git rev-parse refs/heads/main)" == "$REFSPEC_MAIN_OID" ]] \
      || return 14
    [[ "$(command git --git-dir="$REMOTE_REPO" rev-parse refs/heads/feature)" \
      == "$REFSPEC_LOCAL_OID" ]] || return 15
    [[ "$(command git rev-parse refs/remotes/cache/feature)" \
      == "$REFSPEC_LOCAL_OID" ]] || return 16
    print -r -- "$refspec_rc:$negative_rc:$direct_rc"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1:1:0" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/refspec.stderr" "$HOME/negative.stderr" \
      "$HOME/direct.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1:1:0" ]
  grep -Fq "Remote-tracking ref 'cache/feature' is a symbolic ref" \
    "$HOME/refspec.stderr"
  grep -Fq "Remote-tracking ref 'cache/feature' is a symbolic ref" \
    "$HOME/negative.stderr"
}

@test "fetch-refspec mapping refuses a mapped name that is not a valid ref" {
  init_seeded_remote_worktree
  git -C "$WORK_REPO" config --add remote.origin.fetch \
    '+refs/heads/*:refs/remotes/mirror/*.lock'

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local REPLY=""
    local -i direct_rc=0
    _git_tracking_refs_direct origin refs/heads/feature || direct_rc=$?
    print -r -- "$direct_rc:$REPLY"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "2:refs/remotes/mirror/feature.lock" ]
}

@test "clean-remote-merged: a symbolic ref that a fetch refspec maps the branch to is never planned or pushed" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-remote main
  git -C "$SEED_REPO" branch merged-other main
  git -C "$SEED_REPO" push -q origin \
    refs/heads/merged-remote:refs/heads/merged-remote \
    refs/heads/merged-other:refs/heads/merged-other
  # Git applies the first matching fetch refspec after a push to the remote
  # URL, so deleting merged-remote there would delete
  # refs/remotes/cache/merged-remote, an alias of local main, and main with it.
  git -C "$WORK_REPO" config --replace-all remote.origin.fetch \
    '+refs/heads/*:refs/remotes/cache/*'
  git -C "$WORK_REPO" config --add remote.origin.fetch \
    '+refs/heads/*:refs/remotes/origin/*'
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" symbolic-ref refs/remotes/cache/merged-remote \
    refs/heads/main
  export CACHE_MAIN_OID CACHE_REMOTE_OID
  CACHE_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  CACHE_REMOTE_OID=$(git --git-dir="$REMOTE_REPO" \
    rev-parse refs/heads/merged-remote)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    clean-remote-merged --remote origin --yes merged-remote \
      >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    codes+=($?)
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$CACHE_MAIN_OID" ]] || return 10

    # An alias that appears only after confirmation is refused before the push.
    command git update-ref --no-deref refs/remotes/cache/merged-remote \
      "$CACHE_REMOTE_OID" || return 11
    _git_clean_confirm_outcome() {
      command git symbolic-ref refs/remotes/cache/merged-remote \
        refs/heads/main || return 1
      REPLY=confirmed
    }
    clean-remote-merged --remote origin merged-remote \
      >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    codes+=($?)
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$CACHE_MAIN_OID" ]] || return 12
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/plan.stderr" "$HOME/late.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  [ ! -s "$HOME/plan.stdout" ]
  [ ! -s "$HOME/late.stdout" ]
  grep -Fq \
    "Branch 'merged-remote' is protected, symbolic, checked out, unmerged, or absent." \
    "$HOME/plan.stderr"
  grep -Fq "the tracking ref cache/merged-remote is now symbolic" \
    "$HOME/late.stderr"
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/merged-remote)" = \
    "$CACHE_REMOTE_OID" ]
  [ "$(git -C "$WORK_REPO" rev-parse refs/heads/main)" = "$CACHE_MAIN_OID" ]
}

@test "git-tag-delete: a symbolic ref that a fetch refspec maps the tag to is refused" {
  init_seeded_remote_worktree

  git -C "$WORK_REPO" tag release
  git -C "$WORK_REPO" push -q origin refs/tags/release
  # This fetch refspec copies the remote tags below refs/remotes/origin-tags/,
  # so deleting release there would delete origin-tags/release, an alias of
  # local main, and main with it.
  git -C "$WORK_REPO" config --add remote.origin.fetch \
    '+refs/tags/*:refs/remotes/origin-tags/*'
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" symbolic-ref refs/remotes/origin-tags/release \
    refs/heads/main
  export TAGMAP_MAIN_OID TAGMAP_TAG_OID
  TAGMAP_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  TAGMAP_TAG_OID=$(git -C "$WORK_REPO" rev-parse refs/tags/release)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    git-tag-delete release --remote origin --yes \
      >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    codes+=($?)
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$TAGMAP_MAIN_OID" ]] || return 10

    # An alias that appears only after confirmation is refused before the push.
    command git update-ref --no-deref refs/remotes/origin-tags/release \
      "$TAGMAP_TAG_OID" || return 11
    _git_tag_confirm_outcome() {
      command git symbolic-ref refs/remotes/origin-tags/release \
        refs/heads/main || return 1
      REPLY=confirmed
    }
    git-tag-delete release --remote origin \
      >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    codes+=($?)
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$TAGMAP_MAIN_OID" ]] || return 12
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/plan.stderr" "$HOME/late.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  [ ! -s "$HOME/plan.stdout" ]
  [ ! -s "$HOME/late.stdout" ]
  grep -Fq "Remote-tracking ref 'origin-tags/release' is a symbolic ref" \
    "$HOME/plan.stderr"
  grep -Fq "Remote-tracking ref 'origin-tags/release' is a symbolic ref" \
    "$HOME/late.stderr"
  grep -Fq "Tag deletion incomplete: 0 deleted, 1 failed." "$HOME/late.stderr"
  git --git-dir="$REMOTE_REPO" show-ref --verify --quiet refs/tags/release
  [ "$(git -C "$WORK_REPO" rev-parse refs/tags/release)" = "$TAGMAP_TAG_OID" ]
  [ "$(git -C "$WORK_REPO" rev-parse refs/heads/main)" = "$TAGMAP_MAIN_OID" ]
}

@test "clean-remote-merged: a fetch refspec that maps the branch outside refs/remotes is refused" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged main
  git -C "$SEED_REPO" branch merged-other main
  git -C "$SEED_REPO" push -q origin \
    refs/heads/merged:refs/heads/merged \
    refs/heads/merged-other:refs/heads/merged-other
  git -C "$WORK_REPO" fetch -q origin
  # Git applies the first matching fetch refspec after a push to the remote
  # URL, so deleting merged there would also delete local main.
  git -C "$WORK_REPO" config --replace-all remote.origin.fetch \
    '+refs/heads/merged:refs/heads/main'
  git -C "$WORK_REPO" config --add remote.origin.fetch \
    '+refs/heads/*:refs/remotes/origin/*'
  export OUTSIDE_MAIN_OID OUTSIDE_REMOTE_OID
  OUTSIDE_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  OUTSIDE_REMOTE_OID=$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/merged)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    clean-remote-merged --remote origin --yes merged \
      >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    codes+=($?)
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$OUTSIDE_MAIN_OID" ]] || return 10

    # A mapping that appears only after confirmation is refused before the
    # push.
    command git config --replace-all remote.origin.fetch \
      "+refs/heads/*:refs/remotes/origin/*" || return 11
    _git_clean_confirm_outcome() {
      command git config --add remote.origin.fetch \
        "+refs/heads/merged:refs/heads/main" || return 1
      REPLY=confirmed
    }
    clean-remote-merged --remote origin merged \
      >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    codes+=($?)
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$OUTSIDE_MAIN_OID" ]] || return 12
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/plan.stderr" "$HOME/late.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  grep -Fq "The fetch refspec of 'origin' maps refs/heads/merged to refs/heads/main, which is not a remote-tracking ref" \
    "$HOME/plan.stderr"
  grep -Fq "the fetch refspec maps it to refs/heads/main, outside refs/remotes/" \
    "$HOME/late.stderr"
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/heads/merged)" = \
    "$OUTSIDE_REMOTE_OID" ]
  [ "$(git -C "$WORK_REPO" rev-parse refs/heads/main)" = "$OUTSIDE_MAIN_OID" ]
}

@test "git-tag-delete: a fetch refspec that maps the tag outside refs/remotes is refused" {
  init_seeded_remote_worktree

  git -C "$WORK_REPO" tag release
  git -C "$WORK_REPO" push -q origin refs/tags/release
  # Deleting release on the remote would also delete local main.
  git -C "$WORK_REPO" config --replace-all remote.origin.fetch \
    '+refs/tags/release:refs/heads/main'
  git -C "$WORK_REPO" config --add remote.origin.fetch \
    '+refs/heads/*:refs/remotes/origin/*'
  export OUTSIDE_TAG_MAIN_OID
  OUTSIDE_TAG_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    git-tag-delete release --remote origin --yes \
      >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    codes+=($?)
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$OUTSIDE_TAG_MAIN_OID" ]] || return 10

    command git config --replace-all remote.origin.fetch \
      "+refs/heads/*:refs/remotes/origin/*" || return 11
    _git_tag_confirm_outcome() {
      command git config --add remote.origin.fetch \
        "+refs/tags/release:refs/heads/main" || return 1
      REPLY=confirmed
    }
    git-tag-delete release --remote origin \
      >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    codes+=($?)
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$OUTSIDE_TAG_MAIN_OID" ]] || return 12
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/plan.stderr" "$HOME/late.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  grep -Fq "The fetch refspec of 'origin' maps refs/tags/release to refs/heads/main, which is not a remote-tracking ref" \
    "$HOME/plan.stderr"
  grep -Fq "The fetch refspec of 'origin' maps refs/tags/release to refs/heads/main, which is not a remote-tracking ref" \
    "$HOME/late.stderr"
  grep -Fq "Tag deletion incomplete: 0 deleted, 1 failed." "$HOME/late.stderr"
  git --git-dir="$REMOTE_REPO" show-ref --verify --quiet refs/tags/release
  git -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
  [ "$(git -C "$WORK_REPO" rev-parse refs/heads/main)" = "$OUTSIDE_TAG_MAIN_OID" ]
}

@test "tag publication allows a fetch refspec that maps each tag to itself, and tag deletion refuses it" {
  init_seeded_remote_worktree

  git -C "$WORK_REPO" tag release
  # After the push Git writes the pushed value to the local tag itself, which
  # is a no-op for publication but would delete the local tag on a remote
  # deletion.
  git -C "$WORK_REPO" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
  export SELFMAP_RELEASE_OID SELFMAP_MAIN_OID
  SELFMAP_RELEASE_OID=$(git -C "$WORK_REPO" rev-parse refs/tags/release)
  SELFMAP_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    git-tag-push release --remote origin --yes \
      >"$HOME/push.stdout" 2>"$HOME/push.stderr"
    codes+=($?)
    git-tag-create --name v9 --lightweight --push --remote origin --yes \
      >"$HOME/create.stdout" 2>"$HOME/create.stderr"
    codes+=($?)
    git-tag-delete release --remote origin --yes \
      >"$HOME/delete.stdout" 2>"$HOME/delete.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "0,0,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/push.stderr" "$HOME/create.stderr" "$HOME/delete.stderr" \
      >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "0,0,1" ]
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/tags/release)" = \
    "$SELFMAP_RELEASE_OID" ]
  [ "$(git --git-dir="$REMOTE_REPO" rev-parse refs/tags/v9)" = \
    "$SELFMAP_MAIN_OID" ]
  [ "$(git -C "$WORK_REPO" rev-parse refs/tags/release)" = \
    "$SELFMAP_RELEASE_OID" ]
  [ "$(git -C "$WORK_REPO" rev-parse refs/tags/v9)" = "$SELFMAP_MAIN_OID" ]
  grep -Fq "The fetch refspec of 'origin' maps refs/tags/release to refs/tags/release, which is not a remote-tracking ref" \
    "$HOME/delete.stderr"
  git --git-dir="$REMOTE_REPO" show-ref --verify --quiet refs/tags/release
}

@test "git-tag-push: a symbolic ref that a fetch refspec maps the tag to is refused" {
  init_seeded_remote_worktree

  # release names a commit that main does not. This fetch refspec copies the
  # remote tags below refs/remotes/origin-tags/, so publishing release would
  # update origin-tags/release, an alias of local main, and move main.
  git -C "$WORK_REPO" switch -q -c side
  printf '%s\n' "side" > "$WORK_REPO/side.txt"
  git -C "$WORK_REPO" add -- side.txt
  git -C "$WORK_REPO" commit -q -m "side"
  git -C "$WORK_REPO" tag release
  git -C "$WORK_REPO" switch -q main
  git -C "$WORK_REPO" config --add remote.origin.fetch \
    '+refs/tags/*:refs/remotes/origin-tags/*'
  git -C "$WORK_REPO" symbolic-ref refs/remotes/origin-tags/release \
    refs/heads/main
  export TAGPUSH_MAIN_OID
  TAGPUSH_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    git-tag-push release --remote origin --yes \
      >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    codes+=($?)
    [[ "$(command git rev-parse refs/heads/main)" == "$TAGPUSH_MAIN_OID" ]] \
      || return 10

    # An alias that appears only after confirmation is refused before the push.
    command git symbolic-ref --delete refs/remotes/origin-tags/release \
      || return 11
    _git_tag_confirm_outcome() {
      command git symbolic-ref refs/remotes/origin-tags/release \
        refs/heads/main || return 1
      REPLY=confirmed
    }
    git-tag-push release --remote origin \
      >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    codes+=($?)
    [[ "$(command git rev-parse refs/heads/main)" == "$TAGPUSH_MAIN_OID" ]] \
      || return 12
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/plan.stderr" "$HOME/late.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  [ ! -s "$HOME/plan.stdout" ]
  [ ! -s "$HOME/late.stdout" ]
  grep -Fq "Remote-tracking ref 'origin-tags/release' is a symbolic ref" \
    "$HOME/plan.stderr"
  grep -Fq "Remote-tracking ref 'origin-tags/release' is a symbolic ref" \
    "$HOME/late.stderr"
  grep -Fq "Tag push incomplete: 0 succeeded, 1 failed." "$HOME/late.stderr"
  run git --git-dir="$REMOTE_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  [ "$(git -C "$WORK_REPO" rev-parse refs/heads/main)" = "$TAGPUSH_MAIN_OID" ]
}

@test "git-tag-create --push: a symbolic ref that a fetch refspec maps the new tag to is refused" {
  init_seeded_remote_worktree

  git -C "$WORK_REPO" switch -q -c side
  printf '%s\n' "side" > "$WORK_REPO/side.txt"
  git -C "$WORK_REPO" add -- side.txt
  git -C "$WORK_REPO" commit -q -m "side"
  git -C "$WORK_REPO" switch -q main
  # Publishing v9 would update origin-tags/v9, an alias of local main.
  git -C "$WORK_REPO" config --add remote.origin.fetch \
    '+refs/tags/*:refs/remotes/origin-tags/*'
  git -C "$WORK_REPO" symbolic-ref refs/remotes/origin-tags/v9 refs/heads/main
  export TAGCREATE_MAIN_OID
  TAGCREATE_MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    git-tag-create --name v9 --target side --lightweight --push \
      --remote origin --yes >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    codes+=($?)
    command git show-ref --verify --quiet refs/tags/v9 && return 10
    [[ "$(command git rev-parse refs/heads/main)" == "$TAGCREATE_MAIN_OID" ]] \
      || return 11

    # An alias that appears only after confirmation stops the push; the new
    # local tag stays.
    command git symbolic-ref --delete refs/remotes/origin-tags/v9 || return 12
    _git_tag_confirm_outcome() {
      command git symbolic-ref refs/remotes/origin-tags/v9 refs/heads/main \
        || return 1
      REPLY=confirmed
    }
    git-tag-create --name v9 --target side --lightweight --push \
      --remote origin >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    codes+=($?)
    [[ "$(command git rev-parse refs/heads/main)" == "$TAGCREATE_MAIN_OID" ]] \
      || return 13
    command git show-ref --verify --quiet refs/tags/v9 || return 14
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/plan.stderr" "$HOME/late.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1" ]
  grep -Fq "Remote-tracking ref 'origin-tags/v9' is a symbolic ref" \
    "$HOME/plan.stderr"
  grep -Fq "Remote-tracking ref 'origin-tags/v9' is a symbolic ref" \
    "$HOME/late.stderr"
  grep -Fq "The local tag remains available at" "$HOME/late.stderr"
  run git --git-dir="$REMOTE_REPO" show-ref --verify --quiet refs/tags/v9
  [ "$status" -eq 1 ]
}

@test "remote deletions stop at an interrupted local tracking-ref probe" {
  init_seeded_remote_worktree

  git -C "$SEED_REPO" branch merged-a main
  git -C "$SEED_REPO" branch merged-b main
  git -C "$SEED_REPO" push -q origin \
    refs/heads/merged-a:refs/heads/merged-a \
    refs/heads/merged-b:refs/heads/merged-b
  git -C "$WORK_REPO" fetch -q origin
  git -C "$WORK_REPO" tag tag-a
  git -C "$WORK_REPO" tag tag-b
  git -C "$WORK_REPO" push -q origin refs/tags/tag-a refs/tags/tag-b
  # Tag deletions probe the refs this refspec maps the tags to.
  git -C "$WORK_REPO" config --add remote.origin.fetch \
    '+refs/tags/*:refs/remotes/origin-tags/*'
  export_real_git
  # After confirmation, the first local probe of a remote-tracking ref is
  # interrupted, as by Ctrl-C.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == symbolic-ref && -e "$HOME/.interrupt-probe" \
  && " $* " == *" refs/remotes/"* ]]; then
  rm -f -- "$HOME/.interrupt-probe"
  exit 130
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    _git_clean_confirm_outcome() {
      : >"$HOME/.interrupt-probe"
      REPLY=confirmed
    }
    clean-remote-merged --remote origin merged-a merged-b \
      >"$HOME/clean.stdout" 2>"$HOME/clean.stderr"
    codes+=($?)
    _git_tag_confirm_outcome() {
      : >"$HOME/.interrupt-probe"
      REPLY=confirmed
    }
    git-tag-delete tag-a tag-b --remote origin \
      >"$HOME/tag.stdout" 2>"$HOME/tag.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "130,130" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/clean.stderr" "$HOME/tag.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "130,130" ]
  grep -Fq "Remote cleanup interrupted: 0 branches deleted before the interruption." \
    "$HOME/clean.stderr"
  grep -Fq "Tag deletion interrupted: 0 tags deleted" "$HOME/tag.stderr"
  # The interrupt stopped the whole run: nothing was deleted.
  [ "$("$REAL_GIT" --git-dir="$REMOTE_REPO" for-each-ref \
    --format='%(refname)' refs/heads refs/tags)" = \
    $'refs/heads/main\nrefs/heads/merged-a\nrefs/heads/merged-b\nrefs/tags/tag-a\nrefs/tags/tag-b' ]
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/tag-a
  "$REAL_GIT" -C "$WORK_REPO" show-ref --verify --quiet refs/tags/tag-b
}

@test "pushes stop at an interrupted local tracking-ref probe" {
  init_seeded_remote_worktree

  git -C "$WORK_REPO" branch b1
  git -C "$WORK_REPO" branch b2
  git -C "$WORK_REPO" tag tag-a
  git -C "$WORK_REPO" tag tag-b
  git -C "$WORK_REPO" config --add remote.origin.fetch \
    '+refs/tags/*:refs/remotes/origin-tags/*'
  export_real_git
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == symbolic-ref && -e "$HOME/.interrupt-probe" \
  && " $* " == *" refs/remotes/"* ]]; then
  rm -f -- "$HOME/.interrupt-probe"
  exit 130
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    _git_sync_confirm_outcome() {
      : >"$HOME/.interrupt-probe"
      REPLY=confirmed
    }
    git-push --remote origin --all \
      >"$HOME/push.stdout" 2>"$HOME/push.stderr"
    codes+=($?)
    _git_tag_confirm_outcome() {
      : >"$HOME/.interrupt-probe"
      REPLY=confirmed
    }
    git-tag-push tag-a tag-b --remote origin \
      >"$HOME/tag.stdout" 2>"$HOME/tag.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  if [ "$status" -ne 0 ] || [ "$output" != "130,130" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/push.stderr" "$HOME/tag.stderr" >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "130,130" ]
  grep -Fq "Push interrupted: 0 ref updates completed before the interruption." \
    "$HOME/push.stderr"
  grep -Fq "Tag push interrupted: 0 tags pushed before the interruption." \
    "$HOME/tag.stderr"
  # Nothing was published after the interrupt.
  [ "$("$REAL_GIT" --git-dir="$REMOTE_REPO" for-each-ref \
    --format='%(refname)' refs/heads refs/tags)" = 'refs/heads/main' ]
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
  grep -Fq "Push complete: 3 ref updates." "$HOME/all.stderr"
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
