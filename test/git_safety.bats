#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
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

@test "git safety: git-pr-checkout fixes repository and PR head identity" {
  cat > "$TEST_MOCK_BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
if [[ "$*" == *"repo view"* && "$*" == *"id,nameWithOwner,url"* ]]; then
  printf 'R_repo_id\tuser/repo\thttps://github.com/user/repo\n'
  exit 0
elif [[ "$*" == *"repo view"* && "$*" == *"--json id"* ]]; then
  printf 'R_repo_id\n'
  exit 0
elif [[ "$*" == *"pr view 123"* ]]; then
  printf 'PR_node_id\tOPEN\t%s\n' "$PR_HEAD"
  exit 0
elif [[ "$*" == *"pr checkout"* ]]; then
  printf 'checked out exact PR head\n'
  exit 0
fi
exit 0
MOCKGH
  chmod +x "$TEST_MOCK_BIN/gh"

  run run_zsh '
    local repo_dir="$HOME/pr-repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Test User"
    command git config user.email "test@example.com"
    : > tracked.txt
    command git add tracked.txt
    command git commit -qm "test head"
    command git remote add origin git@github.com:user/repo.git
    export PR_HEAD=$(command git rev-parse HEAD)

    git-pr-checkout 123
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked out exact PR head"* ]]
  [[ "$output" == *"detached mode"* ]]
}
