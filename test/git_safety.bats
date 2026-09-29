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
  ! grep -Fq "alice" "$HOME/auth.stderr"
  ! grep -Fq "secret" "$HOME/auth.stderr"
  ! grep -Fq "token=value" "$HOME/auth.stderr"
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
    command git switch -q -c topic
    print -r -- "topic" >> tracked.txt
    command git commit -qam "topic"
    local topic_oid
    topic_oid=$(command git rev-parse HEAD)
    command git switch -q main
    local main_oid
    main_oid=$(command git rev-parse HEAD)

    git-merge topic >"$HOME/merge.stdout" 2>"$HOME/merge.stderr"
    local -i refused_rc=$?
    local after_refusal
    after_refusal=$(command git rev-parse HEAD)

    git-merge topic --yes \
      >"$HOME/authorized.stdout" 2>"$HOME/authorized.stderr"
    local -i authorized_rc=$?
    local after_authorization
    after_authorization=$(command git rev-parse HEAD)

    [[ "$refused_rc" -eq 1 \
      && "$after_refusal" == "$main_oid" \
      && "$authorized_rc" -eq 0 \
      && "$after_authorization" == "$topic_oid" ]]
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/merge.stdout" ]
  [ ! -s "$HOME/authorized.stdout" ]
  grep -Fq -- "--yes" "$HOME/merge.stderr"
}

@test "git safety: in-progress rebase actions require authorization" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q -b main "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Safety Test"
    command git config user.email "safety@example.invalid"
    print -r -- "base" > tracked.txt
    command git add tracked.txt
    command git commit -q -m "base"
    command git switch -q -c topic
    print -r -- "topic" > tracked.txt
    command git commit -qam "topic"
    local topic_oid
    topic_oid=$(command git rev-parse HEAD)
    command git switch -q main
    print -r -- "main" > tracked.txt
    command git commit -qam "main"
    command git switch -q topic
    command git rebase main >/dev/null 2>&1 && return 2

    git-rebase --abort \
      >"$HOME/rebase-refused.stdout" 2>"$HOME/rebase-refused.stderr"
    local -i refused_rc=$?
    [[ -d .git/rebase-merge || -d .git/rebase-apply ]] || return 3

    git-rebase --abort --yes \
      >"$HOME/rebase-abort.stdout" 2>"$HOME/rebase-abort.stderr"
    local -i abort_rc=$?
    local after_abort
    after_abort=$(command git rev-parse HEAD)

    [[ "$refused_rc" -eq 1 \
      && "$abort_rc" -eq 0 \
      && "$after_abort" == "$topic_oid" \
      && ! -d .git/rebase-merge \
      && ! -d .git/rebase-apply ]]
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/rebase-refused.stdout" ]
  [ ! -s "$HOME/rebase-abort.stdout" ]
  grep -Fq -- "--yes" "$HOME/rebase-refused.stderr"
  grep -Fq "Rebase abort completed" "$HOME/rebase-abort.stderr"
}

@test "git safety: configuration plan is unchanged when authorization is unavailable" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Original Name"
    command git config user.email "original@example.invalid"

    git-config-edit --name "Changed Name" \
      >"$HOME/config.stdout" 2>"$HOME/config.stderr"
    local -i edit_rc=$?
    local actual_name
    actual_name=$(command git config --local --get user.name)

    [[ "$edit_rc" -eq 1 && "$actual_name" == "Original Name" ]]
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/config.stdout" ]
  grep -Fq -- "--yes" "$HOME/config.stderr"
}

@test "git safety: configuration changes are revalidated after review" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Original Name"
    command git config user.email "original@example.invalid"

    _git_authorize() {
      command git config --local --replace-all user.name "External Change"
      REPLY="authorized"
      return 0
    }

    git-config-edit --name "Planned Name" --yes \
      >"$HOME/config.stdout" 2>"$HOME/config.stderr"
    local -i edit_rc=$?
    local actual_name
    actual_name=$(command git config --local --get user.name)

    [[ "$edit_rc" -eq 1 && "$actual_name" == "External Change" ]]
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/config.stdout" ]
  grep -Fq "changed after planning" "$HOME/config.stderr"
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
    git-stage >"$HOME/stage.stdout" 2>"$HOME/stage.stderr" || return 1

    local staged_name
    staged_name=$(command git diff --cached --name-only)
    [[ "$staged_name" == ":(glob)*" ]] || return 2

    command git --literal-pathspecs restore --staged -- ":(glob)*"
    git-discard --yes \
      >"$HOME/discard.stdout" 2>"$HOME/discard.stderr" || return 3

    local magic_content="" safe_content=""
    IFS= read -r magic_content < ":(glob)*"
    IFS= read -r safe_content < safe.txt
    [[ "$magic_content" == "base magic" ]] || return 4
    [[ "$safe_content" == "changed safe" ]] || return 5
  '

  if [ "$status" -ne 0 ]; then
    echo "zsh status: $status" >&2
    echo "$output" >&2
    [ ! -f "$HOME/stage.stderr" ] || cat "$HOME/stage.stderr" >&2
    [ ! -f "$HOME/discard.stderr" ] || cat "$HOME/discard.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stage.stdout" ]
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

@test "git safety: file history resolves the name before a rename" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q -b main "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Safety Test"
    command git config user.email "safety@example.invalid"

    print -r -- "base" > "old name.txt"
    command git add "old name.txt"
    command git commit -q -m "base"
    local oldest_oid
    oldest_oid=$(command git rev-parse HEAD)

    command git mv "old name.txt" "new name.txt"
    command git commit -q -m "rename"
    print -r -- "new" >> "new name.txt"
    command git commit -qam "new content"

    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 2
    local -a commit_fields=()
    local -a reply=()
    _git_history_collect_commits \
      log -z --follow -n 200 --format="%H%x09%h%x09%s" \
      -- "new name.txt" || return 3
    commit_fields=("${reply[@]}")

    _git_history_path_at_commit \
      "new name.txt" "$oldest_oid" commit_fields || return 4
    [[ "$REPLY" == "old name.txt" ]]
  '

  [ "$status" -eq 0 ]
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

    export MOCK_FZF_MATCH=$'"'"'\tsub/a.txt'"'"'
    git-stage >"$HOME/stage.stdout" 2>"$HOME/stage.stderr" || return 13
    [[ "$(command git diff --cached --name-only)" == sub/a.txt ]] || return 14
    git-unstage >"$HOME/unstage.stdout" 2>"$HOME/unstage.stderr" || return 15
    [[ -z "$(command git diff --cached --name-only)" ]] || return 16

    command git -C "$repo_dir" checkout -q -- sub/a.txt || return 17
    command git -C "$repo_dir" rm -q -- data.txt || return 18
    command git -C "$repo_dir" commit -q -m "remove data" || return 19
    print -r -- precious-untracked > "$repo_dir/data.txt"
    git-undo-commit --hard --yes \
      >"$HOME/undo.stdout" 2>"$HOME/undo.stderr" && return 20
    [[ "$(<"$repo_dir/data.txt")" == precious-untracked ]] || return 21
  '

  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    cat "$HOME"/*.stderr >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/discard.stdout" ]
  grep -Fq "Protected untracked hard-reset obstacles" "$HOME/undo.stderr"
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
    _git_changes_authorize() { command git switch -q main; REPLY=authorized; }
    git-undo-commit --soft >"$HOME/undo.stdout" 2>"$HOME/undo.stderr" && return 10
    [[ "$(command git log -1 --format=%s main)" == two ]] || return 11
    [[ "$(command git log -1 --format=%s feature)" == two ]] || return 12
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME/undo.stderr" >&2; false; }
  grep -Fq "Branch: feature" "$HOME/undo.stderr"
  grep -Fq "refusing to reset" "$HOME/undo.stderr"
}

@test "git safety: git-switch binds an existing local branch and reports unknown names" {
  run run_zsh "$(git_safety_init_repo)"'
    local remote_dir="$HOME/remote.git"
    command git init -q --bare -b main "$remote_dir" || return 1
    print -r -- base > a.txt
    command git add a.txt && command git commit -q -m base || return 2
    command git remote add origin "$remote_dir"
    command git push -q origin main 2>/dev/null || return 3
    command git switch -q -c feat || return 4
    command git push -q -u origin feat 2>/dev/null || return 5
    print -r -- local > b.txt
    command git add b.txt && command git commit -q -m "local only" || return 6
    local feat_oid="$(command git rev-parse feat)"
    command git switch -q main || return 7

    _git_require_interactive() { return 0; }
    export MOCK_FZF_MODE=match MOCK_FZF_MATCH="origin/feat|"
    git-switch >"$HOME/switch.stdout" 2>"$HOME/switch.stderr" || return 10
    [[ "$(command git symbolic-ref --short HEAD)" == feat ]] || return 11
    [[ "$(command git rev-parse HEAD)" == "$feat_oid" ]] || return 12

    git-switch nosuch >"$HOME/missing.stdout" 2>"$HOME/missing.stderr" && return 13
    return 0
  '

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; cat "$HOME"/*.stderr >&2; false; }
  [ ! -s "$HOME/switch.stdout" ]
  grep -Fq "Local feat exists at" "$HOME/switch.stderr"
  grep -Fq "is neither local nor uniquely available on a remote" "$HOME/missing.stderr"
}

@test "git safety: untracked stashes skip nested repositories and diffs use stdout" {
  run run_zsh "$(git_safety_init_repo)"'
    print -r -- base > a.txt
    command git add a.txt && command git commit -q -m base || return 1
    command git init -q vendor/lib || return 2
    print -r -- nested > vendor/lib/x.txt
    print -r -- new-file > untracked.txt
    print -r -- edited > a.txt

    git-stash create --include-untracked --dry-run \
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
  grep -Fq "+edited" "$HOME/diff.stdout"
  grep -Fq "+new-file" "$HOME/diff.stdout"
  ! grep -Fq "diff --git" "$HOME/diff.stderr" || false
  ! grep -q $'\033' "$HOME/diff.stdout" || false
}

@test "git safety: unstage offers both sides of a staged rename" {
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
