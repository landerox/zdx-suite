#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "git GitHub safety: PR publishing honors pushRemote and local branch" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q -b topic "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git remote add tracking \
      "https://github.example.invalid/team/tracking.git"
    command git remote add publish \
      "https://github.example.invalid/team/publish.git"
    command git config branch.topic.remote tracking
    command git config branch.topic.merge refs/heads/different-destination
    command git config branch.topic.pushRemote publish

    _git_gh_push_remote topic || return 1
    [[ "$REPLY" == "publish" ]] || return 1
    local -a reply=()
    _git_gh_remote_identity "$REPLY" || return 1
    [[ "${reply[2]}" == \
      "https://github.example.invalid/team/publish.git" ]]
  '

  [ "$status" -eq 0 ]
}

@test "git GitHub safety: PR publishing rejects multiple push URLs" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q -b topic "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git remote add publish \
      "https://github.example.invalid/team/repository.git"
    command git remote set-url --add --push publish \
      "https://github.example.invalid/team/first.git"
    command git remote set-url --add --push publish \
      "https://github.example.invalid/team/second.git"

    local -a reply=()
    _git_gh_remote_identity publish
  '

  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one push URL"* ]]
}

@test "git GitHub safety: PR publishing refuses a symbolic remote-tracking ref and the branch it names never moves" {
  # Deny-by-default gh: only the default-branch query is answered.
  cat > "$TEST_MOCK_BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
if [[ "$*" == *"defaultBranchRef"* ]]; then
  printf 'main\n'
  exit 0
fi
printf 'mock gh denied: %s\n' "$*" >&2
exit 97
MOCKGH
  chmod +x "$TEST_MOCK_BIN/gh"

  run run_zsh '
    local repo_dir="$HOME/repository" remote_dir="$HOME/remote.git"
    command git init -q --bare "$remote_dir" || return 1
    command git init -q -b main "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "PR Test"
    command git config user.email "pr@example.invalid"
    command git config core.hooksPath /dev/null
    command git config commit.gpgSign false
    print -r -- base > base.txt
    command git add base.txt && command git commit -q -m base || return 1
    command git remote add origin "$remote_dir" || return 1
    command git push -q origin main || return 1
    command git switch -q -c feature || return 1
    print -r -- feature > feature.txt
    command git add feature.txt && command git commit -q -m feature || return 1
    local main_oid=""
    main_oid=$(command git rev-parse refs/heads/main) || return 1
    # The publication push goes to the remote URL, so Git updates this
    # tracking ref itself and would follow the alias to main.
    command git symbolic-ref refs/remotes/origin/feature refs/heads/main \
      || return 1

    _git_gh_repo_context() {
      typeset -gA _GIT_GH_REPO=(
        target "github.com/user/repo"
        id "R_test"
        host "github.com"
        name "user/repo"
        url "https://github.com/user/repo"
      )
    }
    _git_gh_remote_identity() {
      reply=("github.com/user/repo" "$HOME/remote.git" "user")
    }
    _git_gh_base_oid() { REPLY=$(command git rev-parse refs/heads/main); }
    _git_gh_remote_head_oid() { REPLY=""; }
    _git_gh_require_same_repo() { return 0; }

    local -a codes=()
    git-pr-create --base main --fill --yes \
      >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    codes+=($?)
    [[ "$(command git rev-parse refs/heads/main)" == "$main_oid" ]] || return 10
    command git --git-dir="$remote_dir" show-ref --verify --quiet \
      refs/heads/feature && return 11

    # An alias that appears after confirmation is refused before the push.
    command git symbolic-ref --delete refs/remotes/origin/feature || return 12
    _git_confirm_outcome() {
      command git symbolic-ref refs/remotes/origin/feature refs/heads/main \
        || return 1
      REPLY=confirmed
    }
    git-pr-create --base main --fill \
      >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    codes+=($?)
    [[ "$(command git rev-parse refs/heads/main)" == "$main_oid" ]] || return 13
    command git --git-dir="$remote_dir" show-ref --verify --quiet \
      refs/heads/feature && return 14
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/plan.stderr" "$HOME/late.stderr" >&2 2>/dev/null
    false
  }
  [ "$output" = "1,1" ]
  grep -Fq "Remote-tracking ref 'origin/feature' is a symbolic ref" \
    "$HOME/plan.stderr"
  grep -Fq "Remote-tracking ref 'origin/feature' is a symbolic ref" \
    "$HOME/late.stderr"
}

@test "git GitHub safety: PR publishing refuses a symbolic ref that a custom fetch refspec maps the head to" {
  cat > "$TEST_MOCK_BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
if [[ "$*" == *"defaultBranchRef"* ]]; then
  printf 'main\n'
  exit 0
fi
printf 'mock gh denied: %s\n' "$*" >&2
exit 97
MOCKGH
  chmod +x "$TEST_MOCK_BIN/gh"

  run run_zsh '
    local repo_dir="$HOME/repository" remote_dir="$HOME/remote.git"
    command git init -q --bare "$remote_dir" || return 1
    command git init -q -b main "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "PR Test"
    command git config user.email "pr@example.invalid"
    command git config core.hooksPath /dev/null
    command git config commit.gpgSign false
    print -r -- base > base.txt
    command git add base.txt && command git commit -q -m base || return 1
    command git remote add origin "$remote_dir" || return 1
    # The fetch refspec stores the remote branches below refs/remotes/cache/,
    # so the publication would update cache/feature, an alias of main.
    command git config --replace-all remote.origin.fetch \
      "+refs/heads/*:refs/remotes/cache/*" || return 1
    command git switch -q -c feature || return 1
    print -r -- feature > feature.txt
    command git add feature.txt && command git commit -q -m feature || return 1
    local main_oid=""
    main_oid=$(command git rev-parse refs/heads/main) || return 1
    command git symbolic-ref refs/remotes/cache/feature refs/heads/main \
      || return 1

    _git_gh_repo_context() {
      typeset -gA _GIT_GH_REPO=(
        target "github.com/user/repo"
        id "R_test"
        host "github.com"
        name "user/repo"
        url "https://github.com/user/repo"
      )
    }
    _git_gh_remote_identity() {
      reply=("github.com/user/repo" "$HOME/remote.git" "user")
    }
    _git_gh_base_oid() { REPLY=$(command git rev-parse refs/heads/main); }
    _git_gh_remote_head_oid() { REPLY=""; }
    _git_gh_require_same_repo() { return 0; }

    git-pr-create --base main --fill --yes \
      >"$HOME/refspec.stdout" 2>"$HOME/refspec.stderr"
    local -i refspec_rc=$?
    [[ "$(command git rev-parse refs/heads/main)" == "$main_oid" ]] || return 10
    command git --git-dir="$remote_dir" show-ref --verify --quiet \
      refs/heads/feature && return 11
    print -r -- "$refspec_rc"
  '

  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output" >&2
    cat "$HOME/refspec.stderr" >&2 2>/dev/null
    false
  }
  [ "$output" = "1" ]
  grep -Fq "Remote-tracking ref 'cache/feature' is a symbolic ref" \
    "$HOME/refspec.stderr"
}
