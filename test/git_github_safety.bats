#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

# Keep GitHub identity resolution real, but route the exact fixture URL's
# transport to a disposable bare repository. No network protocol is allowed.
github_write_fixture() {
  export GH_REPO="$HOME/github-work" GH_REMOTE="$HOME/github-remote.git"
  export GH_HEAD GH_BASE GH_REAL_GIT
  GH_REAL_GIT=$(command -v git)
  export GIT_ALLOW_PROTOCOL=file
  git init -q --bare "$GH_REMOTE"
  git init -q -b main "$GH_REPO"
  git -C "$GH_REPO" config user.name "GitHub Test"
  git -C "$GH_REPO" config user.email "github-test@example.invalid"
  git -C "$GH_REPO" config core.hooksPath /dev/null
  git -C "$GH_REPO" config commit.gpgSign false
  printf '%s\n' base > "$GH_REPO/base.txt"
  git -C "$GH_REPO" add base.txt
  git -C "$GH_REPO" commit -q -m base
  GH_BASE=$(git -C "$GH_REPO" rev-parse HEAD)
  git -C "$GH_REPO" push -q "$GH_REMOTE" HEAD:refs/heads/main
  git -C "$GH_REPO" remote add origin git@github.com:user/repo.git
  git -C "$GH_REPO" switch -q -c feature
  printf '%s\n' feature > "$GH_REPO/feature.txt"
  git -C "$GH_REPO" add feature.txt
  git -C "$GH_REPO" commit -q -m feature
  GH_HEAD=$(git -C "$GH_REPO" rev-parse HEAD)

  cat > "$TEST_MOCK_BIN/git" <<'MOCKGIT'
#!/usr/bin/env bash
args=("$@")
transport=""
for arg in "$@"; do
  case "$arg" in push|fetch|ls-remote) transport="$arg"; break ;; esac
done
if [[ -n "$transport" ]]; then
  if [[ "$transport" == push ]]; then
    printf '%s\0' "$@" >> "$HOME/push.args"
    printf '%q ' "$@" >> "$HOME/push.calls"
    printf '\n' >> "$HOME/push.calls"
  fi
  for (( i=0; i<${#args[@]}; i++ )); do
    case "${args[i]}" in
      origin|git@github.com:user/repo.git) args[i]="$GH_REMOTE" ;;
    esac
  done
fi
exec "$GH_REAL_GIT" "${args[@]}"
MOCKGIT
  chmod -- 755 "$TEST_MOCK_BIN/git"
}

# Every received argument is retained as NUL-delimited data. Each supported
# request must match its complete argv, including the read-only queries.
install_github_write_recorder() {
  cat > "$TEST_MOCK_BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
argv=("$@")
printf '<call>\0' >> "$HOME/github.args"
printf '%s\0' "$@" >> "$HOME/github.args"
printf '%q ' "$@" >> "$HOME/github.calls"
printf '\n' >> "$HOME/github.calls"
same_args() {
  [[ "$#" -eq "${#argv[@]}" ]] || return 1
  local i=0 arg
  for arg in "$@"; do
    [[ "${argv[i]}" == "$arg" ]] || return 1
    (( i += 1 ))
  done
}
if same_args auth status; then
  exit 0
elif same_args repo view --json id,nameWithOwner,url \
  --template '{{.id}}{{"\t"}}{{.nameWithOwner}}{{"\t"}}{{.url}}'; then
  printf 'R_repo\tuser/repo\thttps://github.com/user/repo\n'
  exit 0
elif same_args repo view --repo github.com/user/repo --json id \
  --template '{{.id}}'; then
  if [[ -e "$HOME/github-repository-changed" ]]; then
    printf 'R_other\n'
  else
    printf 'R_repo\n'
  fi
  exit 0
elif same_args repo view --repo github.com/user/repo \
  --json defaultBranchRef --template '{{.defaultBranchRef.name}}'; then
  printf 'main\n'
  exit 0
elif same_args api graphql --hostname github.com \
  -f 'query=query($owner:String!,$repo:String!,$expression:String!){repository(owner:$owner,name:$repo){object(expression:$expression){... on Commit{oid}}}}' \
  -f owner=user -f repo=repo -f expression=refs/heads/main \
  --jq '.data.repository.object.oid'; then
  printf '%s\n' "$GH_BASE"
  exit 0
elif same_args pr create --repo github.com/user/repo --head feature \
  --base main --fill; then
  # The external write must follow publication of the exact reviewed head.
  published=$("$GH_REAL_GIT" --git-dir="$GH_REMOTE" rev-parse refs/heads/feature) \
    || exit 96
  [[ "$published" == "$GH_HEAD" ]] || exit 96
  if [[ "${GH_CREATE_STATUS:-0}" != 0 ]]; then
    printf 'fixture PR creation failed\n' >&2
    exit "$GH_CREATE_STATUS"
  fi
  printf 'https://github.com/user/repo/pull/123\n'
  exit 0
elif same_args pr view 123 --repo github.com/user/repo \
  --json id,state,url,headRefName,headRefOid,baseRefName,baseRefOid \
  --template '{{.id}}{{"\t"}}{{.state}}{{"\t"}}{{.url}}{{"\t"}}{{.headRefName}}{{"\t"}}{{.headRefOid}}{{"\t"}}{{.baseRefName}}{{"\t"}}{{.baseRefOid}}'; then
  printf 'PR_123\tOPEN\thttps://github.com/user/repo/pull/123\tfeature\t%s\tmain\t%s\n' \
    "${GH_VERIFIED_HEAD:-$GH_HEAD}" "$GH_BASE"
  exit 0
elif same_args pr view 123 --repo github.com/user/repo \
  --json id,state,headRefOid \
  --template '{{.id}}{{"\t"}}{{.state}}{{"\t"}}{{.headRefOid}}'; then
  printf 'PR_123\tOPEN\t%s\n' "$GH_HEAD"
  exit 0
fi
printf '%q ' "$@" >> "$HOME/github.denied"
printf '\n' >> "$HOME/github.denied"
printf 'mock gh denied unexpected argv\n' >&2
exit 97
MOCKGH
  chmod -- 755 "$TEST_MOCK_BIN/gh"
}

assert_github_no_unexpected_calls() {
  [ ! -e "$HOME/github.denied" ]
  [ -s "$HOME/github.args" ]
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

@test "git GitHub safety: the recorder rejects unexpected writes and preserves argument boundaries" {
  github_write_fixture
  install_github_write_recorder

  run gh pr create --repo github.com/user/repo --head feature --base main \
    --title $'unreviewed title\nwith another line'
  [ "$status" -eq 97 ]
  [ -s "$HOME/github.denied" ]
  printf '%s\0' '<call>' pr create --repo github.com/user/repo --head feature \
    --base main --title $'unreviewed title\nwith another line' > "$HOME/expected.args"
  cmp "$HOME/expected.args" "$HOME/github.args"
  run "$GH_REAL_GIT" --git-dir="$GH_REMOTE" show-ref --verify --quiet refs/heads/feature
  [ "$status" -eq 1 ]
}

@test "git GitHub safety: PR creation publishes an exact leased head before the recorded GitHub write" {
  github_write_fixture
  install_github_write_recorder

  run run_zsh '
    cd "$GH_REPO" || return 90
    git-pr-create --base main --fill --yes \
      >"$HOME/create.stdout" 2>"$HOME/create.stderr"
  '
  [ "$status" -eq 0 ] || {
    cat "$HOME/create.stderr" >&2
    false
  }
  [ ! -s "$HOME/create.stdout" ]
  grep -Fq "Pull request #123 created and verified." "$HOME/create.stderr"
  grep -Fq 'pr create --repo github.com/user/repo --head feature --base main --fill' \
    "$HOME/github.calls"
  grep -Fq 'pr view 123 --repo github.com/user/repo' "$HOME/github.calls"
  assert_github_no_unexpected_calls
  printf '%s\0' push --no-follow-tags --recurse-submodules=no \
    --force-with-lease=refs/heads/feature: -- git@github.com:user/repo.git \
    "$GH_HEAD:refs/heads/feature" > "$HOME/expected-push.args"
  cmp "$HOME/expected-push.args" "$HOME/push.args"
  [ "$("$GH_REAL_GIT" --git-dir="$GH_REMOTE" rev-parse refs/heads/feature)" = "$GH_HEAD" ]
  [ "$("$GH_REAL_GIT" --git-dir="$GH_REMOTE" rev-parse refs/heads/main)" = "$GH_BASE" ]
}

@test "git GitHub safety: failed PR creation retains the published head and the child status" {
  github_write_fixture
  install_github_write_recorder
  export GH_CREATE_STATUS=42

  run run_zsh '
    cd "$GH_REPO" || return 90
    git-pr-create --base main --fill --yes \
      >"$HOME/create.stdout" 2>"$HOME/create.stderr"
  '
  [ "$status" -eq 42 ]
  [ ! -s "$HOME/create.stdout" ]
  grep -Fq 'Unable to create the pull request (exit 42).' "$HOME/create.stderr"
  grep -Fq 'Partial result: the reviewed head remains published at feature.' \
    "$HOME/create.stderr"
  assert_github_no_unexpected_calls
  [ "$("$GH_REAL_GIT" --git-dir="$GH_REMOTE" rev-parse refs/heads/feature)" = "$GH_HEAD" ]
  run grep -F 'pr view' "$HOME/github.calls"
  [ "$status" -eq 1 ]
}

@test "git GitHub safety: repository identity changed after review prevents both publication and PR creation" {
  github_write_fixture
  install_github_write_recorder

  run run_zsh '
    cd "$GH_REPO" || return 90
    _git_confirm_outcome() {
      : > "$HOME/github-repository-changed"
      REPLY=confirmed
    }
    git-pr-create --base main --fill \
      >"$HOME/create.stdout" 2>"$HOME/create.stderr"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/create.stdout" ]
  grep -Fq 'The GitHub repository identity changed; retry.' "$HOME/create.stderr"
  assert_github_no_unexpected_calls
  [ ! -e "$HOME/push.args" ]
  run grep -F 'pr create' "$HOME/github.calls"
  [ "$status" -eq 1 ]
  run "$GH_REAL_GIT" --git-dir="$GH_REMOTE" show-ref --verify --quiet refs/heads/feature
  [ "$status" -eq 1 ]
}

@test "git GitHub safety: a created PR with a different head is reported as an unverified partial result" {
  github_write_fixture
  install_github_write_recorder
  export GH_VERIFIED_HEAD="$GH_BASE"

  run run_zsh '
    cd "$GH_REPO" || return 90
    git-pr-create --base main --fill --yes \
      >"$HOME/create.stdout" 2>"$HOME/create.stderr"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/create.stdout" ]
  grep -Fq 'The created pull request does not match the reviewed repository, base, and head.' \
    "$HOME/create.stderr"
  grep -Fq 'Partial result: inspect PR #123' "$HOME/create.stderr"
  assert_github_no_unexpected_calls
  [ "$("$GH_REAL_GIT" --git-dir="$GH_REMOTE" rev-parse refs/heads/feature)" = "$GH_HEAD" ]
}

@test "git GitHub safety: dry run, nonterminal refusal, and cancellation never publish or create a PR" {
  github_write_fixture
  install_github_write_recorder

  run run_zsh '
    cd "$GH_REPO" || return 90
    git-pr-create --base main --fill --dry-run \
      >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 91
    git-pr-create --base main --fill \
      >"$HOME/nonterminal.stdout" 2>"$HOME/nonterminal.stderr"
    [[ $? == 1 ]] || return 92
    _git_confirm_outcome() { REPLY=cancelled; }
    git-pr-create --base main --fill \
      >"$HOME/cancel.stdout" 2>"$HOME/cancel.stderr"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/dry.stdout" ]
  [ ! -s "$HOME/nonterminal.stdout" ]
  [ ! -s "$HOME/cancel.stdout" ]
  grep -Fq 'Dry run complete; no branch or pull request was changed.' "$HOME/dry.stderr"
  grep -Fq 'Interactive confirmation requires a terminal' "$HOME/nonterminal.stderr"
  grep -Fq 'Cancelled. No changes were made.' "$HOME/cancel.stderr"
  assert_github_no_unexpected_calls
  [ ! -e "$HOME/push.args" ]
  run grep -F 'pr create' "$HOME/github.calls"
  [ "$status" -eq 1 ]
  run "$GH_REAL_GIT" --git-dir="$GH_REMOTE" show-ref --verify --quiet refs/heads/feature
  [ "$status" -eq 1 ]
}

@test "git GitHub safety: strict GitHub reads lead to the distinct pinned PR head without gh checkout" {
  github_write_fixture
  "$GH_REAL_GIT" -C "$GH_REPO" push -q "$GH_REMOTE" "$GH_HEAD:refs/pull/123/head"
  "$GH_REAL_GIT" -C "$GH_REPO" switch -q main
  install_github_write_recorder
  [ "$GH_HEAD" != "$GH_BASE" ]

  run run_zsh '
    cd "$GH_REPO" || return 90
    git-pr-checkout 123 >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr" \
      || return 91
    [[ "$(command git rev-parse HEAD)" == "$GH_HEAD" ]] || return 92
    command git symbolic-ref -q HEAD >/dev/null && return 93
    [[ -z "$(command git for-each-ref --format="%(refname)" refs/zdx-suite)" ]] \
      || return 94
    return 0
  '
  [ "$status" -eq 0 ] || {
    cat "$HOME/checkout.stderr" >&2
    false
  }
  [ ! -s "$HOME/checkout.stdout" ]
  grep -Fq 'detached mode' "$HOME/checkout.stderr"
  assert_github_no_unexpected_calls
  run grep -F 'pr checkout' "$HOME/github.calls"
  [ "$status" -eq 1 ]
  run grep -F 'pr create' "$HOME/github.calls"
  [ "$status" -eq 1 ]
}
