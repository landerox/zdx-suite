#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

# Exports REAL_GIT, the git executable that a test wrapper delegates to.
export_real_git() {
  export REAL_GIT
  REAL_GIT=$(command -v git)
}

@test "git safety: remote display removes credentials and URL secrets" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git remote add origin \
      "https://alice:secret@example.invalid/org/repo.git?token=value#fragment"

    git-auth >"$HOME/auth.stdout" 2>"$HOME/auth.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/auth.stdout" ]
  grep -Fq "https://***@example.invalid/org/repo.git" "$HOME/auth.stderr"
  grep -Fq "query or fragment redacted" "$HOME/auth.stderr"
  ! grep -Fq "alice" "$HOME/auth.stderr" || false
  ! grep -Fq "secret" "$HOME/auth.stderr" || false
  ! grep -Fq "token=value" "$HOME/auth.stderr" || false
}

@test "git safety: direct mutation without a TTY fails closed unless yes is explicit" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q -b main "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Safety Test"
    command git config user.email "safety@example.invalid"
    print -r -- "base" > tracked.txt
    command git add tracked.txt
    command git commit -q -m "base"
    local base_oid
    base_oid=$(command git rev-parse HEAD)
    print -r -- "topic" >> tracked.txt
    command git commit -qam "topic"
    local topic_oid
    topic_oid=$(command git rev-parse HEAD)
    command git tag release

    # Undo uses the local-change authorization path.
    git-undo-commit --soft >"$HOME/undo.stdout" 2>"$HOME/undo.stderr"
    local -i undo_refused_rc=$?
    local after_undo_refusal
    after_undo_refusal=$(command git rev-parse HEAD)

    git-undo-commit --soft --yes \
      >"$HOME/undo-authorized.stdout" 2>"$HOME/undo-authorized.stderr"
    local -i undo_authorized_rc=$?
    local after_undo_authorization
    after_undo_authorization=$(command git rev-parse HEAD)

    # Tag deletion uses the shared confirmation outcome.
    git-tag-delete --local-only release \
      >"$HOME/tag.stdout" 2>"$HOME/tag.stderr"
    local -i tag_refused_rc=$?
    local -i tag_kept=0
    command git show-ref --verify --quiet refs/tags/release && tag_kept=1

    git-tag-delete --local-only --yes release \
      >"$HOME/tag-authorized.stdout" 2>"$HOME/tag-authorized.stderr"
    local -i tag_authorized_rc=$?
    local -i tag_deleted=1
    command git show-ref --verify --quiet refs/tags/release && tag_deleted=0

    [[ "$undo_refused_rc" -eq 1 \
      && "$after_undo_refusal" == "$topic_oid" \
      && "$undo_authorized_rc" -eq 0 \
      && "$after_undo_authorization" == "$base_oid" \
      && "$tag_refused_rc" -eq 1 \
      && "$tag_kept" -eq 1 \
      && "$tag_authorized_rc" -eq 0 \
      && "$tag_deleted" -eq 1 ]]
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/undo.stdout" ]
  [ ! -s "$HOME/undo-authorized.stdout" ]
  [ ! -s "$HOME/tag.stdout" ]
  [ ! -s "$HOME/tag-authorized.stdout" ]
  grep -Fq -- "--yes" "$HOME/undo.stderr"
  grep -Fq -- "--yes" "$HOME/tag.stderr"
}

@test "git safety: literal pathspecs isolate adversarial file names" {
  export MOCK_FZF_MODE=match
  export MOCK_FZF_MATCH=':(glob)*'

  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Safety Test"
    command git config user.email "safety@example.invalid"
    print -r -- "base magic" > ":(glob)*"
    print -r -- "base safe" > safe.txt
    command git --literal-pathspecs add -- ":(glob)*" safe.txt
    command git commit -q -m "base"

    print -r -- "changed magic" > ":(glob)*"
    print -r -- "changed safe" > safe.txt
    git-discard --yes \
      >"$HOME/discard.stdout" 2>"$HOME/discard.stderr" || return 1

    local magic_content="" safe_content=""
    IFS= read -r magic_content < ":(glob)*"
    IFS= read -r safe_content < safe.txt
    [[ "$magic_content" == "base magic" ]] || return 2
    [[ "$safe_content" == "changed safe" ]] || return 3
  '

  if [ "$status" -ne 0 ]; then
    echo "zsh status: $status" >&2
    echo "$output" >&2
    [ ! -f "$HOME/discard.stderr" ] || cat "$HOME/discard.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/discard.stdout" ]
}

@test "git safety: identity profile data cannot execute shell syntax" {
  run run_zsh '
    typeset -gA ZDX_GIT_IDENTITIES
    ZDX_GIT_IDENTITIES=(
      guarded
      "Name|Guarded User;Email|guarded@example.invalid;SshKey|$HOME/key \$(touch $HOME/executed)"
    )

    git-identity-switcher --switch guarded global \
      >"$HOME/identity.stdout" 2>"$HOME/identity.stderr" || return 1
    local ssh_command
    ssh_command=$(command git config --global --get core.sshCommand)
    print -r -- "$ssh_command" > "$HOME/ssh-command"

    [[ ! -e "$HOME/executed" ]]
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/identity.stdout" ]
  [ ! -e "$HOME/executed" ]
  local expected
  expected="ssh -i '$HOME/key \$(touch $HOME/executed)' -o IdentitiesOnly=yes"
  [ "$(cat "$HOME/ssh-command")" = "$expected" ]
}

@test "git safety: PR creation compares object IDs as strings" {
  command cp \
    "$TEST_SUITE_ROOT/test/fixtures/git-gh-default-branch" \
    "$TEST_MOCK_BIN/gh"
  command chmod +x "$TEST_MOCK_BIN/gh"

  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q -b main "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Safety Test"
    command git config user.email "safety@example.invalid"
    print -r -- "base" > tracked.txt
    command git add tracked.txt
    command git commit -q -m "base"
    command git remote add origin \
      "https://github.com/example/repository.git"
    command git config branch.main.remote origin
    command git config branch.main.merge refs/heads/main

    _git_gh_repo_context() {
      typeset -gA _GIT_GH_REPO=(
        target "github.com/example/repository"
        id "R_test"
        host "github.com"
        name "example/repository"
        url "https://github.com/example/repository"
      )
    }
    _git_gh_base_oid() {
      REPLY="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
    _git_gh_remote_head_oid() {
      REPLY=""
    }

    git-pr-create --base main --fill --dry-run \
      >"$HOME/pr.stdout" 2>"$HOME/pr.stderr"
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/pr.stderr" ] || cat "$HOME/pr.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/pr.stdout" ]
  grep -Fq "Publish required:" "$HOME/pr.stderr"
  grep -Eq "Publish required:[[:space:]]+1$" "$HOME/pr.stderr"
}

git_safety_init_repo() {
  cat <<'ZSH'
    local repo_dir="$HOME/repository"
    command git init -q -b main "$repo_dir" || return 81
    cd "$repo_dir" || return 82
    command git config user.name "Safety Test"
    command git config user.email "safety@example.invalid"
    command git config core.hooksPath /dev/null
ZSH
}

@test "git safety: path commands resolve selections from a subdirectory" {
  run run_zsh "$(git_safety_init_repo)"'
    mkdir sub
    print -r -- root-base > a.txt
    print -r -- sub-base > sub/a.txt
    print -r -- data > data.txt
    command git add -A && command git commit -q -m base || return 1
    print -r -- root-edit > a.txt
    print -r -- sub-precious > sub/a.txt

    cd sub || return 2
    export MOCK_FZF_MODE=match MOCK_FZF_MATCH=$'"'"'\ta.txt'"'"'
    git-discard --yes >"$HOME/discard.stdout" 2>"$HOME/discard.stderr" || return 10
    [[ "$(<"$repo_dir/a.txt")" == root-base ]] || return 11
    [[ "$(<"$repo_dir/sub/a.txt")" == sub-precious ]] || return 12

    command git -C "$repo_dir" checkout -q -- sub/a.txt || return 13
    command git -C "$repo_dir" rm -q -- data.txt || return 14
    command git -C "$repo_dir" commit -q -m "remove data" || return 15
    print -r -- precious-untracked > "$repo_dir/data.txt"
    git-undo-commit --hard --yes \
      >"$HOME/undo.stdout" 2>"$HOME/undo.stderr" && return 16
    [[ "$(<"$repo_dir/data.txt")" == precious-untracked ]] || return 17
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    cat "$HOME"/*.stderr >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/discard.stdout" ]
  grep -Fq "Protected untracked hard-reset obstacles" "$HOME/undo.stderr"
}

@test "git safety: unstage and stash run from the repository root in a subdirectory" {
  # shellcheck disable=SC2016
  run run_zsh "$(git_safety_init_repo)"'
    mkdir sub
    print -r -- root-base > a.txt
    print -r -- sub-base > sub/a.txt
    command git add -A && command git commit -q -m base || return 1
    print -r -- root-staged > a.txt
    print -r -- sub-staged > sub/a.txt
    command git add -A || return 2

    cd sub || return 3
    export MOCK_FZF_MODE=match MOCK_FZF_MATCH=$'"'"'\tfile\tsub/a.txt'"'"'
    git-unstage >"$HOME/unstage.stdout" 2>"$HOME/unstage.stderr" || return 10
    [[ "$(command git -C "$repo_dir" diff --cached --name-only)" == a.txt ]] || return 11

    git-stash save --yes >"$HOME/stash.stdout" 2>"$HOME/stash.stderr" || return 12
    [[ "$(<"$repo_dir/a.txt")" == root-base ]] || return 13
    [[ "$(<"$repo_dir/sub/a.txt")" == sub-base ]] || return 14
    [[ "$PWD" == "$repo_dir/sub" ]] || return 15
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    cat "$HOME"/*.stderr >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/unstage.stdout" ]
  [ ! -s "$HOME/stash.stdout" ]
  grep -Fq "Unstaged: sub/a.txt" "$HOME/unstage.stderr"
  grep -Fq "Stash saved: 2 files stored as stash@{0}" "$HOME/stash.stderr"
}

@test "git safety: untracked stashes skip nested repositories and diffs use stdout" {
  # shellcheck disable=SC2016
  run run_zsh "$(git_safety_init_repo)"'
    print -r -- base > a.txt
    command git add a.txt && command git commit -q -m base || return 1
    command git init -q vendor/lib || return 2
    print -r -- nested > vendor/lib/x.txt
    print -r -- new-file > untracked.txt
    print -r -- edited > a.txt

    git-stash save --include-untracked --dry-run \
      >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    git-stash create --include-untracked --yes \
      >"$HOME/create.stdout" 2>"$HOME/create.stderr" || return 11
    [[ -f vendor/lib/x.txt && ! -e untracked.txt ]] || return 12

    local stash_oid="$(command git rev-parse "stash@{0}")"
    _git_stash_page_full "$stash_oid" \
      >"$HOME/diff.stdout" 2>"$HOME/diff.stderr" || return 13
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME"/*.stderr >&2; false; }
  grep -Fq "untracked.txt" "$HOME/dry.stderr"
  ! grep -Fq "vendor/lib" "$HOME/dry.stderr" || false
  [ ! -s "$HOME/create.stdout" ]
  grep -Fq "+edited" "$HOME/diff.stdout"
  grep -Fq "+new-file" "$HOME/diff.stdout"
  ! grep -Fq "diff --git" "$HOME/diff.stderr" || false
  ! grep -q $'\033' "$HOME/diff.stdout" || false
}

@test "git safety: unstage offers both sides of a staged rename" {
  # shellcheck disable=SC2016
  run run_zsh "$(git_safety_init_repo)"'
    print -r -- content > old.txt
    command git add old.txt && command git commit -q -m base || return 1
    command git mv old.txt new.txt || return 2

    export MOCK_FZF_MODE=match MOCK_FZF_MATCH=$'"'"'\told.txt'"'"'
    git-unstage >"$HOME/old.stdout" 2>"$HOME/old.stderr" || return 10
    export MOCK_FZF_MATCH=$'"'"'\tnew.txt'"'"'
    git-unstage >"$HOME/new.stdout" 2>"$HOME/new.stderr" || return 11
    [[ -z "$(command git diff --cached --name-only)" ]] || return 12
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME"/*.stderr >&2; false; }
  grep -Fq "Unstaged: old.txt" "$HOME/old.stderr"
  grep -Fq "Unstaged: new.txt" "$HOME/new.stderr"
}

@test "git safety: discard refuses to replace an untracked directory obstacle" {
  run run_zsh "$(git_safety_init_repo)"'
    print -r -- old > build
    print -r -- keep > keep.txt
    command git add -A && command git commit -q -m base || return 1
    command rm -- build && mkdir build || return 2
    print -r -- precious > build/notes.txt

    export MOCK_FZF_MODE=match MOCK_FZF_MATCH=$'"'"'\tbuild'"'"'
    git-discard --yes >"$HOME/discard.stdout" 2>"$HOME/discard.stderr" && return 10
    [[ "$(<build/notes.txt)" == precious ]] || return 11
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME/discard.stderr" >&2; false; }
  [ ! -s "$HOME/discard.stdout" ]
  grep -Fq "Refusing to overwrite or remove untracked or ignored paths." \
    "$HOME/discard.stderr"
}

@test "git safety: undo-commit binds its plan to the current branch" {
  run run_zsh "$(git_safety_init_repo)"'
    print -r -- one > a.txt
    command git add a.txt && command git commit -q -m one || return 1
    print -r -- two > a.txt
    command git commit -q -am two || return 2
    command git switch -q -c feature || return 3

    # A concurrent switch to another branch at the same commit.
    _git_confirm_outcome() { command git switch -q main; REPLY=confirmed; }
    git-undo-commit --soft >"$HOME/undo.stdout" 2>"$HOME/undo.stderr" && return 10
    [[ "$(command git log -1 --format=%s main)" == two ]] || return 11
    [[ "$(command git log -1 --format=%s feature)" == two ]] || return 12
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME/undo.stderr" >&2; false; }
  grep -Fq "Branch: feature" "$HOME/undo.stderr"
  grep -Fq "refusing to reset" "$HOME/undo.stderr"
}

@test "git safety: PR creation resolves SSH host aliases to their HostName" {
  command cp \
    "$TEST_SUITE_ROOT/test/fixtures/git-gh-default-branch" \
    "$TEST_MOCK_BIN/gh"
  command chmod +x "$TEST_MOCK_BIN/gh"
  # OpenSSH reads the account home, not HOME, so the alias map is mocked.
  cat > "$TEST_MOCK_BIN/ssh" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-G" ]] || exit 97
[[ "${2:-}" == "--" ]] && shift
case "${2:-}" in
  github-personal) printf 'user git\nhostname github.com\nport 22\n' ;;
  *) printf 'user git\nhostname %s\nport 22\n' "${2:-}" ;;
esac
MOCK
  command chmod +x "$TEST_MOCK_BIN/ssh"

  run run_zsh "$(git_safety_init_repo)"'
    print -r -- base > tracked.txt
    command git add tracked.txt && command git commit -q -m base || return 1
    command git remote add origin "git@github-personal:example/repository.git"
    command git config branch.main.remote origin
    command git config branch.main.merge refs/heads/main

    _git_gh_repo_context() {
      typeset -gA _GIT_GH_REPO=(
        target "github.com/example/repository"
        id "R_test"
        host "github.com"
        name "example/repository"
        url "https://github.com/example/repository"
      )
    }
    _git_gh_base_oid() { REPLY="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; }
    _git_gh_remote_head_oid() { REPLY=""; }

    git-pr-create --base main --fill --dry-run \
      >"$HOME/pr.stdout" 2>"$HOME/pr.stderr"
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME/pr.stderr" >&2; false; }
  [ ! -s "$HOME/pr.stdout" ]
  ! grep -Fq "targets github-personal" "$HOME/pr.stderr" || false
}

# Creates PR_REPO on main (BASE_OID) whose origin names github.com/user/repo,
# while url.<base>.insteadOf makes Git fetch it from the local bare repository
# PR_REMOTE. That remote's refs/pull/123/head is PR_HEAD, one commit on top of
# main that adds FILE (default pr.txt) with CONTENT.
# Usage: pr_checkout_fixture [FILE CONTENT]
pr_checkout_fixture() {
  export PR_REPO="$HOME/pr-repository" PR_REMOTE="$HOME/pr-remote.git"
  export PR_HEAD BASE_OID
  git init -q -b main "$PR_REPO"
  git -C "$PR_REPO" config user.name "PR Test"
  git -C "$PR_REPO" config user.email "pr@example.invalid"
  git -C "$PR_REPO" config core.hooksPath /dev/null
  git -C "$PR_REPO" config commit.gpgSign false
  printf '%s\n' "base" > "$PR_REPO/base.txt"
  git -C "$PR_REPO" add base.txt
  git -C "$PR_REPO" commit -q -m "base"
  BASE_OID=$(git -C "$PR_REPO" rev-parse HEAD)
  git init -q --bare "$PR_REMOTE"
  git -C "$PR_REPO" remote add origin git@github.com:user/repo.git
  git -C "$PR_REPO" config "url.$PR_REMOTE.insteadOf" \
    git@github.com:user/repo.git
  git -C "$PR_REPO" switch -q -c pr-branch
  printf '%s\n' "${2:-pr change}" > "$PR_REPO/${1:-pr.txt}"
  git -C "$PR_REPO" add -- "${1:-pr.txt}"
  git -C "$PR_REPO" commit -q -m "pr head"
  PR_HEAD=$(git -C "$PR_REPO" rev-parse HEAD)
  git -C "$PR_REPO" switch -q main
  git -C "$PR_REPO" push -q origin "$PR_HEAD:refs/pull/123/head"
  git -C "$PR_REPO" branch -q -D pr-branch
}

# A deny-by-default gh that resolves github.com/user/repo and reports PR 123
# open at PR_HEAD. `pr checkout` does what gh pr checkout --detach does, so a
# test can show that git-pr-checkout no longer delegates to it. Every call is
# recorded in $HOME/gh.calls.
install_pr_gh_mock() {
  cat > "$TEST_MOCK_BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/gh.calls"
if [[ "${1:-} ${2:-}" == "auth status" ]]; then
  exit 0
elif [[ "${1:-} ${2:-}" == "repo view" && "$*" == *"id,nameWithOwner,url"* ]]; then
  printf 'R_repo_id\tuser/repo\thttps://github.com/user/repo\n'
  exit 0
elif [[ "${1:-} ${2:-}" == "repo view" && "$*" == *"--json id"* ]]; then
  printf 'R_repo_id\n'
  exit 0
elif [[ "${1:-} ${2:-} ${3:-}" == "pr view 123" ]]; then
  printf 'PR_node_id\tOPEN\t%s\n' "$PR_HEAD"
  exit 0
elif [[ "${1:-} ${2:-} ${3:-}" == "pr checkout 123" ]]; then
  git fetch -q origin refs/pull/123/head && git checkout -q --detach FETCH_HEAD
  exit $?
fi
printf 'mock gh denied: %s\n' "$*" >&2
exit 97
MOCKGH
  chmod +x "$TEST_MOCK_BIN/gh"
}

@test "git safety: git-pr-checkout fixes repository and PR head identity" {
  pr_checkout_fixture
  install_pr_gh_mock

  run run_zsh '
    cd "$PR_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr" \
      || return 10
    [[ "$(command git rev-parse HEAD)" == "$PR_HEAD" ]] || return 11
    command git symbolic-ref -q HEAD >/dev/null && return 12
    [[ -z "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 13
    return 0
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" >&2
    false
  }
  [ ! -s "$HOME/checkout.stdout" ]
  grep -Fq "detached mode" "$HOME/checkout.stderr"
  # gh only reads the repository and the PR; the suite fetches and checks out.
  run grep -F "pr checkout" "$HOME/gh.calls"
  [ "$status" -eq 1 ]
}

@test "git safety: git-pr-checkout refuses an ignored file that the PR head tracks" {
  pr_checkout_fixture local.env "from-pr"
  install_pr_gh_mock
  printf '%s\n' "local.env" >> "$PR_REPO/.git/info/exclude"
  printf '%s\n' "local secret" > "$PR_REPO/local.env"

  run run_zsh '
    cd "$PR_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(<local.env)" == "local secret" ]] || return 10
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 11
    [[ "$(command git rev-parse HEAD)" == "$BASE_OID" ]] || return 12
    [[ -z "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 13
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" >&2
    false
  }
  [ "$output" = "1" ]
  [ ! -s "$HOME/checkout.stdout" ]
  grep -Fq "local.env" "$HOME/checkout.stderr"
  grep -Fq "Refusing to check out PR #123; move or remove these paths first." \
    "$HOME/checkout.stderr"
}

@test "git safety: git-pr-checkout refuses a PR head that moved after review" {
  pr_checkout_fixture
  install_pr_gh_mock
  # gh reported PR_HEAD; the PR ref then moved to another commit.
  git -C "$PR_REPO" switch -q --detach "$PR_HEAD"
  printf '%s\n' "force-pushed" > "$PR_REPO/moved.txt"
  git -C "$PR_REPO" add moved.txt
  git -C "$PR_REPO" commit -q -m "moved head"
  export MOVED_OID
  MOVED_OID=$(git -C "$PR_REPO" rev-parse HEAD)
  git -C "$PR_REPO" switch -q main
  git -C "$PR_REPO" push -q -f origin "$MOVED_OID:refs/pull/123/head"
  # A post-checkout hook records every commit the worktree is checked out at.
  mkdir -p "$HOME/hooks"
  printf '%s\n' '#!/bin/sh' 'git rev-parse HEAD >> "$HOME/checkouts.log"' \
    > "$HOME/hooks/post-checkout"
  chmod +x "$HOME/hooks/post-checkout"
  git -C "$PR_REPO" config core.hooksPath "$HOME/hooks"

  run run_zsh '
    cd "$PR_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ -z "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 11
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" "$HOME/checkouts.log" >&2 2>/dev/null
    false
  }
  [ "$output" = "1" ]
  [ ! -s "$HOME/checkout.stdout" ]
  grep -Fq "moved after review" "$HOME/checkout.stderr"
  # Nothing was checked out, so no hook ran for the moved head.
  [ ! -s "$HOME/checkouts.log" ]
}

@test "git safety: an interrupted git-pr-checkout fetch leaves no temporary ref" {
  pr_checkout_fixture
  install_pr_gh_mock
  export_real_git
  # Ctrl-C reaches the fetch and the shell that waits for it, after the fetch
  # wrote its temporary ref.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == fetch && " $* " == *" refs/pull/123/head:"* ]]; then
  "$REAL_GIT" "$@" || exit
  "$REAL_GIT" for-each-ref --format='%(refname)' refs/zdx-suite \
    > "$HOME/temp-refs-during-fetch"
  kill -INT "$PPID"
  exit 130
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$PR_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ -z "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 11
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" >&2
    false
  }
  [ "$output" = "130" ]
  # The fetch had written its temporary ref before the interruption.
  [ -s "$HOME/temp-refs-during-fetch" ]
  grep -Fq "interrupted" "$HOME/checkout.stderr"
}

@test "git safety: an interrupt after the PR fetch keeps its status and leaves no temporary ref" {
  pr_checkout_fixture
  install_pr_gh_mock
  export_real_git
  # Ctrl-C reaches the shell while it reads the fetched temporary ref; the
  # read runs in a command substitution, so the wrapper signals the shell.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == for-each-ref && " $* " == *" refs/zdx-suite/fetch/"* \
  && " $* " != *" --count=1 "* && ! -e "$HOME/.read-interrupted" ]]; then
  : > "$HOME/.read-interrupted"
  kill -INT "$ZDX_TEST_SHELL_PID"
  exit 130
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$PR_REPO" || return 90
    export ZDX_TEST_SHELL_PID=$$
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" >&2
    false
  }
  [ -e "$HOME/.read-interrupted" ]
  [ "$output" = "130" ]
  [ -z "$("$REAL_GIT" -C "$PR_REPO" for-each-ref --format='%(refname)' \
    refs/zdx-suite)" ]
}

@test "git safety: an interrupted PR checkout switch keeps its status and restores the branch" {
  pr_checkout_fixture
  install_pr_gh_mock
  export_real_git
  # Ctrl-C arrives while git switch runs, after it moved HEAD.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == switch && " $* " == *" --detach "* \
  && ! -e "$HOME/.switch-interrupted" ]]; then
  : > "$HOME/.switch-interrupted"
  "$REAL_GIT" "$@"
  kill -INT "$PPID"
  exit 130
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$PR_REPO" || return 90
    # The harness wraps the command builtin in a function, which would absorb
    # a return from the INT trap; an interactive shell runs the builtin.
    unfunction command 2>/dev/null
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ "$(command git rev-parse HEAD)" == "$BASE_OID" ]] || return 11
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" >&2
    false
  }
  [ -e "$HOME/.switch-interrupted" ]
  [ "$output" = "130" ]
  grep -Fq "The original worktree state was restored." "$HOME/checkout.stderr"
  [ -z "$("$REAL_GIT" -C "$PR_REPO" for-each-ref --format='%(refname)' \
    refs/zdx-suite)" ]
}

@test "git safety: a PR checkout restore never overwrites an ignored file that appeared meanwhile" {
  pr_checkout_fixture
  install_pr_gh_mock
  export_real_git
  # main tracks build.cfg, which the PR head lacks, and ignores it otherwise.
  printf '%s\n' "tracked config" > "$PR_REPO/build.cfg"
  git -C "$PR_REPO" add -- build.cfg
  git -C "$PR_REPO" commit -q -m "add build.cfg"
  printf '%s\n' "build.cfg" >> "$PR_REPO/.git/info/exclude"
  # The switch reaches the PR head, a hook writes an ignored build.cfg, and
  # Ctrl-C arrives, so the command restores main over that file.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == switch && " $* " == *" --detach "* \
  && ! -e "$HOME/.switch-interrupted" ]]; then
  : > "$HOME/.switch-interrupted"
  "$REAL_GIT" "$@"
  printf '%s\n' "generated by a hook" > "$PWD/build.cfg"
  kill -INT "$PPID"
  exit 130
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$PR_REPO" || return 90
    unfunction command 2>/dev/null
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(<build.cfg)" == "generated by a hook" ]] || return 10
    # The restore was refused, so HEAD stays at the PR head for inspection.
    [[ "$(command git rev-parse HEAD)" == "$PR_HEAD" ]] || return 11
    command git symbolic-ref --quiet HEAD >/dev/null && return 12
    [[ -z "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 13
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" >&2
    false
  }
  [ -e "$HOME/.switch-interrupted" ]
  [ "$output" = "130" ]
  grep -Fxq "  build.cfg" "$HOME/checkout.stderr"
  grep -Fq "Refusing to restore the prior state; move or remove these paths first." \
    "$HOME/checkout.stderr"
  grep -Fq "The original worktree state could not be restored; inspect HEAD." \
    "$HOME/checkout.stderr"
}

@test "git safety: git-pr-checkout fails when its temporary ref cannot be removed" {
  pr_checkout_fixture
  install_pr_gh_mock
  export_real_git
  # The cleanup transaction of the temporary ref fails.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == update-ref && " $* " == *" --stdin "* \
  && "$*" == *"temporary fetch cleanup"* ]]; then
  cat >/dev/null
  exit 1
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$PR_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(command git rev-parse HEAD)" == "$PR_HEAD" ]] || return 10
    [[ -n "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 11
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" >&2
    false
  }
  [ "$output" = "1" ]
  grep -Fq "Remove the temporary refs below 'refs/zdx-suite/" \
    "$HOME/checkout.stderr"
  grep -Fq "Checked out pull request #123 at ${PR_HEAD:0:12}, but its temporary refs could not be removed." \
    "$HOME/checkout.stderr"
  run grep -Fq "Checked out pull request #123 in detached mode" \
    "$HOME/checkout.stderr"
  [ "$status" -eq 1 ]
}

@test "git safety: git-pr-checkout refuses when no remote names the reviewed repository" {
  pr_checkout_fixture
  install_pr_gh_mock
  git -C "$PR_REPO" remote set-url origin git@github.com:someone/elsewhere.git

  run run_zsh '
    cd "$PR_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ "$output" = "1" ]
  grep -Fq "No configured remote URL names github.com/user/repo; add one with 'git remote add <name> <url>', then retry." \
    "$HOME/checkout.stderr"
}

@test "git safety: git-pr-checkout fetches from the base remote in a fork layout" {
  pr_checkout_fixture
  install_pr_gh_mock
  # origin is the user's fork, which has no pull refs; upstream is the base.
  git init -q --bare "$HOME/fork.git"
  git -C "$PR_REPO" remote rename origin upstream
  git -C "$PR_REPO" remote add origin git@github.com:me/repo.git
  git -C "$PR_REPO" config "url.$HOME/fork.git.insteadOf" \
    git@github.com:me/repo.git

  run run_zsh '
    cd "$PR_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr" \
      || return 10
    [[ "$(command git rev-parse HEAD)" == "$PR_HEAD" ]] || return 11
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" >&2
    false
  }
  grep -Fq "from 'upstream'" "$HOME/checkout.stderr"
}

@test "git safety: git-pr-checkout selects a remote by the first URL, which git fetch uses" {
  pr_checkout_fixture
  install_pr_gh_mock
  # origin fetches from its first URL, an empty mirror; only its second URL
  # names the repository. upstream's first URL names it.
  git init -q --bare "$HOME/mirror.git"
  git -C "$PR_REPO" config "url.$HOME/mirror.git.insteadOf" \
    https://github.com/someone/mirror.git
  git -C "$PR_REPO" remote set-url origin \
    https://github.com/someone/mirror.git
  git -C "$PR_REPO" config --add remote.origin.url \
    git@github.com:user/repo.git
  git -C "$PR_REPO" remote add upstream git@github.com:user/repo.git
  # GitHub's SSH over port 443 maps github.com to HostName ssh.github.com, so
  # upstream matches by the host as written.
  cat > "$TEST_MOCK_BIN/ssh" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-G" ]] || exit 97
[[ "${2:-}" == "--" ]] && shift
case "${2:-}" in
  github.com) printf 'user git\nhostname ssh.github.com\nport 443\n' ;;
  *) printf 'user git\nhostname %s\nport 22\n' "${2:-}" ;;
esac
MOCK
  chmod +x "$TEST_MOCK_BIN/ssh"

  run run_zsh '
    cd "$PR_REPO" || return 90
    local -a codes=()
    git-pr-checkout 123 >"$HOME/upstream.stdout" 2>"$HOME/upstream.stderr"
    codes+=($?)
    [[ "$(command git rev-parse HEAD)" == "$PR_HEAD" ]] || return 10

    # Without upstream, no remote fetches from a URL that names it.
    command git switch -q main || return 11
    command git remote remove upstream || return 12
    git-pr-checkout 123 >"$HOME/none.stdout" 2>"$HOME/none.stderr"
    codes+=($?)
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 13
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/upstream.stderr" "$HOME/none.stderr" >&2 2>/dev/null
    false
  }
  [ "$output" = "0,1" ]
  grep -Fq "from 'upstream'" "$HOME/upstream.stderr"
  grep -Fq "No configured remote URL names github.com/user/repo" \
    "$HOME/none.stderr"
  run grep -Fq "Fetching PR #123" "$HOME/none.stderr"
  [ "$status" -eq 1 ]
}

@test "git safety: git-pr-checkout skips a remote without a usable fetch URL" {
  pr_checkout_fixture
  install_pr_gh_mock
  git -C "$PR_REPO" remote add upstream git@github.com:user/repo.git
  # A trailing empty value resets origin's URL list, so Git cannot fetch
  # from origin at all.
  git -C "$PR_REPO" config --add remote.origin.url ""
  export_real_git
  # With $HOME/.get-url-fails, git remote get-url origin fails.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ -e "$HOME/.get-url-fails" && "$*" == "remote get-url origin" ]]; then
  printf '%s\n' "error: unable to read the URL" >&2
  exit 2
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$PR_REPO" || return 90
    local -a codes=()
    git-pr-checkout 123 >"$HOME/empty.stdout" 2>"$HOME/empty.stderr"
    codes+=($?)
    [[ "$(command git rev-parse HEAD)" == "$PR_HEAD" ]] || return 10

    # origin has a URL again, but git remote get-url cannot report it.
    command git switch -q main || return 11
    command git config --unset-all remote.origin.url || return 12
    command git config remote.origin.url git@github.com:user/repo.git \
      || return 13
    : >"$HOME/.get-url-fails"
    git-pr-checkout 123 >"$HOME/geturl.stdout" 2>"$HOME/geturl.stderr"
    codes+=($?)
    [[ "$(command git rev-parse HEAD)" == "$PR_HEAD" ]] || return 14
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/empty.stderr" "$HOME/geturl.stderr" >&2 2>/dev/null
    false
  }
  [ "$output" = "0,0" ]
  grep -Fq "from 'upstream'" "$HOME/empty.stderr"
  grep -Fq "from 'upstream'" "$HOME/geturl.stderr"
}

@test "git safety: an interrupted remote URL read stops git-pr-checkout" {
  pr_checkout_fixture
  install_pr_gh_mock
  git -C "$PR_REPO" remote add upstream git@github.com:user/repo.git
  export_real_git
  # With $HOME/.interrupt-get-url, Ctrl-C arrives while git remote get-url
  # reads origin's URL.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ -e "$HOME/.interrupt-get-url" && "$*" == "remote get-url origin" ]]; then
  exit 130
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"
  # The query for the HostName of the alias gh-alias is interrupted too.
  cat > "$TEST_MOCK_BIN/ssh" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-G" ]] || exit 97
[[ "${2:-}" == "--" ]] && shift
[[ "${2:-}" == gh-alias ]] && exit 130
printf 'user git\nhostname %s\nport 22\n' "${2:-}"
MOCK
  chmod +x "$TEST_MOCK_BIN/ssh"

  run run_zsh '
    cd "$PR_REPO" || return 90
    local -a codes=()
    : >"$HOME/.interrupt-get-url"
    git-pr-checkout 123 >"$HOME/geturl.stdout" 2>"$HOME/geturl.stderr"
    codes+=($?)
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10

    # origin names the repository only through an SSH alias.
    command rm -f -- "$HOME/.interrupt-get-url"
    command git remote set-url origin git@gh-alias:user/repo.git || return 11
    git-pr-checkout 123 >"$HOME/ssh.stdout" 2>"$HOME/ssh.stderr"
    codes+=($?)
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 12
    [[ -z "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 13
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/geturl.stderr" "$HOME/ssh.stderr" >&2 2>/dev/null
    false
  }
  [ "$output" = "130,130" ]
  grep -Fq "Choosing the remote for PR #123 was interrupted (exit 130); nothing was fetched or checked out." \
    "$HOME/geturl.stderr"
  grep -Fq "Choosing the remote for PR #123 was interrupted (exit 130)" \
    "$HOME/ssh.stderr"
  run grep -Fq "Fetching PR #123" "$HOME/geturl.stderr" "$HOME/ssh.stderr"
  [ "$status" -eq 1 ]
}

@test "git safety: an interrupted SSH configuration read stops git-pr-checkout" {
  pr_checkout_fixture
  install_pr_gh_mock
  git -C "$PR_REPO" remote add upstream git@github.com:user/repo.git
  # origin names the repository only through the SSH alias gh-alias, so
  # choosing it reads the SSH configuration.
  git -C "$PR_REPO" remote set-url origin git@gh-alias:user/repo.git
  export_real_git
  # Ctrl-C arrives while core.sshCommand, then ssh.variant, is read.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ -e "$HOME/.interrupt-ssh-command" \
  && "$*" == "config --get core.sshCommand" ]]; then
  exit 130
fi
if [[ -e "$HOME/.interrupt-ssh-variant" \
  && "$*" == "config --get ssh.variant" ]]; then
  exit 130
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"
  cat > "$TEST_MOCK_BIN/ssh" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-G" ]] || exit 97
[[ "${2:-}" == "--" ]] && shift
case "${2:-}" in
  gh-alias) printf 'user git\nhostname github.com\nport 22\n' ;;
  *) printf 'user git\nhostname %s\nport 22\n' "${2:-}" ;;
esac
MOCK
  chmod +x "$TEST_MOCK_BIN/ssh"

  run run_zsh '
    cd "$PR_REPO" || return 90
    local -a codes=()
    local marker=""
    for marker in .interrupt-ssh-command .interrupt-ssh-variant; do
      : >"$HOME/$marker"
      git-pr-checkout 123 >"$HOME/$marker.stdout" 2>"$HOME/$marker.stderr"
      codes+=($?)
      command rm -f -- "$HOME/$marker"
      [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    done
    [[ -z "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 11
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME"/.interrupt-*.stderr >&2 2>/dev/null
    false
  }
  [ "$output" = "130,130" ]
  grep -Fq "Choosing the remote for PR #123 was interrupted (exit 130)" \
    "$HOME/.interrupt-ssh-command.stderr"
  grep -Fq "Choosing the remote for PR #123 was interrupted (exit 130)" \
    "$HOME/.interrupt-ssh-variant.stderr"
  run grep -Fq "Fetching PR #123" "$HOME/.interrupt-ssh-command.stderr" \
    "$HOME/.interrupt-ssh-variant.stderr"
  [ "$status" -eq 1 ]
}

@test "git safety: a failed PR fetch checks out nothing and leaves no temporary ref" {
  pr_checkout_fixture
  install_pr_gh_mock
  # The remote no longer has the pull ref.
  git --git-dir="$PR_REMOTE" update-ref -d refs/pull/123/head

  run run_zsh '
    cd "$PR_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ -z "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 11
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ "$output" = "1" ]
  grep -Fq "Unable to fetch PR #123 from 'origin'" "$HOME/checkout.stderr"
}

@test "git safety: git-pr-checkout never overwrites an ignored file that appears after the check" {
  pr_checkout_fixture local.env "from-pr"
  install_pr_gh_mock
  printf '%s\n' "local.env" >> "$PR_REPO/.git/info/exclude"
  export_real_git
  # The ignored file appears just before git switch runs, after the obstacle
  # check; --no-overwrite-ignore makes the switch refuse it.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == switch && " $* " == *" --detach "* \
  && ! -e "$HOME/.late-ignored" ]]; then
  : > "$HOME/.late-ignored"
  printf '%s\n' "local secret" > local.env
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    cd "$PR_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local -i checkout_rc=$?
    [[ "$(<local.env)" == "local secret" ]] || return 10
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 11
    print -r -- "$checkout_rc"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/checkout.stderr" >&2
    false
  }
  [ -e "$HOME/.late-ignored" ]
  [ "$output" = "1" ]
  grep -Fq "local.env" "$HOME/checkout.stderr"
}
