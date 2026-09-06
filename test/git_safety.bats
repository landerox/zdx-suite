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
      REPLY="absent"
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
