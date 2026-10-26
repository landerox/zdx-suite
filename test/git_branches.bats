#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

# Branch workflows: git-switch and git-recover against disposable
# repositories and local bare remotes inside the sandbox.

setup() {
  load test_helper
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
}

teardown() {
  cleanup_sandbox
}

# Prints Zsh that creates a repository whose main branch has a.txt and b.txt
# and whose topic branch changes b.txt and adds topic.txt; main is checked out.
branch_repo() {
  cat <<'ZSH'

    local repo_dir="$HOME/repository"
    command git init -q -b main "$repo_dir" || return 81
    cd "$repo_dir" || return 82
    command git config user.name "Branch Test"
    command git config user.email "branch@example.invalid"
    command git config core.hooksPath /dev/null
    command git config commit.gpgSign false
    print -r -- "base a" > a.txt
    print -r -- "base b" > b.txt
    print -r -- "*.log" > .gitignore
    command git add -A || return 83
    command git commit -q -m "feat: base" || return 84
    command git switch -q -c topic || return 85
    print -r -- "topic b" > b.txt
    print -r -- "topic" > topic.txt
    command git add -A || return 86
    command git commit -q -m "feat: topic" || return 87
    command git switch -q main || return 88
ZSH
}

# Prints Zsh that publishes main and a feature branch to a bare origin, then
# deletes the local feature branch so it exists only as origin/feature.
branch_remote() {
  cat <<'ZSH'

    command git init -q --bare -b main "$HOME/origin.git" || return 91
    command git remote add origin "$HOME/origin.git" || return 92
    command git push -q -u origin main 2>/dev/null || return 93
    command git switch -q -c feature || return 94
    print -r -- "feature" > feature.txt
    command git add feature.txt || return 95
    command git commit -q -m "feat: feature" || return 96
    command git push -q origin feature 2>/dev/null || return 97
    command git switch -q main || return 98
    command git branch -q -D feature || return 99
ZSH
}

# Prints Zsh that commits "feat: lost work" on main and resets it away, so
# only the HEAD and main reflogs still name the commit, kept in LOST_OID.
lost_commit() {
  cat <<'ZSH'

    print -r -- "lost work" > lost.txt
    command git add lost.txt || return 71
    command git commit -q -m "feat: lost work" || return 72
    LOST_OID=$(command git rev-parse HEAD) || return 73
    command git reset -q --hard HEAD~1 || return 74
ZSH
}

# Prints Zsh that records every ref with its object ID in REFS_BEFORE.
refs_snapshot() {
  cat <<'ZSH'

    REFS_BEFORE=$(command git for-each-ref --format='%(refname) %(objectname)')
ZSH
}

# Prints Zsh that fails with status 60 when a ref in REFS_BEFORE moved or
# disappeared.
refs_unchanged() {
  cat <<'ZSH'

    local ref_line=""
    for ref_line in "${(@f)REFS_BEFORE}"; do
      [[ "$(command git rev-parse --verify --quiet "${ref_line%% *}")" \
        == "${ref_line#* }" ]] || return 60
    done
ZSH
}

show_failure() {
  printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
  cat "$HOME"/*.stderr >&2 2>/dev/null || true
}

# Wraps the standard fzf mock. A picker call that finds the fixture
# $HOME/picker-side-effect renames it and runs it once with /bin/sh, as if an
# editor or another tool changed the repository while the picker was open,
# and then answers like the standard mock.
wrap_fzf_with_side_effect() {
  mv "$TEST_MOCK_BIN/fzf" "$TEST_MOCK_BIN/fzf-standard"
  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
side_effect="$HOME/picker-side-effect"
if [[ -f "$side_effect" ]]; then
  mv -f -- "$side_effect" "$side_effect.ran" || exit 96
  /bin/sh "$side_effect.ran" </dev/null >&2 || exit 95
fi
exec "$TEST_MOCK_BIN/fzf-standard" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"
}

# --- git-switch ----------------------------------------------------------------

@test "git branches: a clean switch moves at once and needs no terminal" {
  run run_zsh "$(branch_repo)"'
    git-switch topic >"$HOME/topic.stdout" 2>"$HOME/topic.stderr" || return 10
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/topic ]] || return 11
    [[ "$(<b.txt)" == "topic b" ]] || return 12
    git-switch - >"$HOME/back.stdout" 2>"$HOME/back.stderr" || return 13
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 14
    git-switch main >"$HOME/same.stdout" 2>"$HOME/same.stderr" || return 15
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/topic.stdout" ]
  [ ! -s "$HOME/back.stdout" ]
  [ ! -s "$HOME/same.stdout" ]
  grep -Fq "Switch Branch" "$HOME/topic.stderr"
  grep -Fq "Switched to topic from main." "$HOME/topic.stderr"
  grep -Fq "Switched to main from topic." "$HOME/back.stderr"
  grep -Fq "Already on main; nothing to switch." "$HOME/same.stderr"
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]
}

@test "git branches: a remote-only branch creates just its tracking branch at the reviewed commit" {
  run run_zsh "$(branch_repo)$(branch_remote)$(refs_snapshot)"'
    local remote_oid=""
    remote_oid=$(command git rev-parse refs/remotes/origin/feature) || return 9
    git-switch feature --dry-run >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    [[ "$(command git for-each-ref --format="%(refname) %(objectname)")" \
      == "$REFS_BEFORE" ]] || return 11
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 12

    git-switch feature >"$HOME/create.stdout" 2>"$HOME/create.stderr" || return 13
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/feature ]] || return 14
    [[ "$(command git rev-parse HEAD)" == "$remote_oid" ]] || return 15
    [[ "$(command git for-each-ref --format="%(upstream)" refs/heads/feature)" \
      == refs/remotes/origin/feature ]] || return 16
    '"$(refs_unchanged)"'
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/dry.stdout" ]
  [ ! -s "$HOME/create.stdout" ]
  grep -Fq "feature (new local branch tracking origin/feature)" "$HOME/dry.stderr"
  grep -Eq "1 +Create feature at [0-9a-f]{12} and switch to it" "$HOME/dry.stderr"
  grep -Eq "2 +Track origin/feature" "$HOME/dry.stderr"
  grep -Fq "Dry run: 1 branch switch planned; nothing was changed." "$HOME/dry.stderr"
  grep -Fq "Track origin/feature — done" "$HOME/create.stderr"
  grep -Fq "Switched to feature from main." "$HOME/create.stderr"
}

@test "git branches: switch refuses unknown, ambiguous, invalid, and differing branch names" {
  run run_zsh "$(branch_repo)$(branch_remote)"'
    command git init -q --bare -b main "$HOME/upstream.git" || return 9
    command git remote add upstream "$HOME/upstream.git" || return 9
    command git push -q upstream refs/remotes/origin/feature:refs/heads/feature \
      2>/dev/null || return 9
    command git fetch -q upstream 2>/dev/null || return 9
    command git branch -q other main || return 9

    local -a codes=()
    git-switch nothing >"$HOME/unknown.stdout" 2>"$HOME/unknown.stderr"
    codes+=($?)
    git-switch feature >"$HOME/ambiguous.stdout" 2>"$HOME/ambiguous.stderr"
    codes+=($?)
    git-switch "bad..name" >"$HOME/invalid.stdout" 2>"$HOME/invalid.stderr"
    codes+=($?)
    git-switch "@{-1}" >>"$HOME/invalid.stdout" 2>>"$HOME/invalid.stderr"
    codes+=($?)
    command git branch -q feature main || return 10
    git-switch origin/feature >"$HOME/differs.stdout" 2>"$HOME/differs.stderr"
    codes+=($?)
    [[ "$(command git rev-parse feature)" == "$(command git rev-parse main)" ]] ||
      return 11
    git-switch topic other >"$HOME/usage.stdout" 2>"$HOME/usage.stderr"
    codes+=($?)
    git-switch topic --stash --carry >>"$HOME/usage.stdout" 2>>"$HOME/usage.stderr"
    codes+=($?)
    git-switch topic --dry-run --yes >>"$HOME/usage.stdout" 2>>"$HOME/usage.stderr"
    codes+=($?)
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 12
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1,1,2,2,1,2,2,2" ]
  grep -Fq "No local or remote-tracking branch is named nothing." "$HOME/unknown.stderr"
  grep -Fq "feature matches several remote-tracking branches:" "$HOME/ambiguous.stderr"
  grep -Fq "origin/feature" "$HOME/ambiguous.stderr"
  grep -Fq "upstream/feature" "$HOME/ambiguous.stderr"
  grep -Fq "Invalid branch name: bad..name" "$HOME/invalid.stderr"
  grep -Fq "Local branch feature already exists and differs from origin/feature." \
    "$HOME/differs.stderr"
  grep -Fq "git-switch accepts at most one BRANCH." "$HOME/usage.stderr"
  grep -Fq -- "--stash and --carry cannot be combined." "$HOME/usage.stderr"
  grep -Fq -- "--dry-run and --yes cannot be combined." "$HOME/usage.stderr"
  for name in unknown ambiguous invalid differs usage; do
    [ ! -s "$HOME/$name.stdout" ]
  done
}

@test "git branches: switch refuses during a merge, rebase, cherry-pick, revert, or bisect" {
  run run_zsh "$(branch_repo)"'
    local git_dir="" marker="" results=""
    git_dir=$(command git rev-parse --absolute-git-dir) || return 9
    for marker in MERGE_HEAD rebase-merge CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
      if [[ "$marker" == rebase-merge ]]; then
        mkdir -- "$git_dir/$marker" || return 10
      else
        print -r -- "0000000000000000000000000000000000000000" \
          > "$git_dir/$marker" || return 10
      fi
      git-switch topic --yes >>"$HOME/op.stdout" 2>>"$HOME/op.stderr"
      results+="$?,"
      [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 11
      if [[ "$marker" == rebase-merge ]]; then
        rmdir -- "$git_dir/$marker" || return 12
      else
        command rm -f -- "$git_dir/$marker" || return 12
      fi
    done
    print -r -- "$results"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1,1,1,1,1," ]
  [ ! -s "$HOME/op.stdout" ]
  local operation
  for operation in merge rebase cherry-pick revert bisect; do
    grep -Fq "A $operation is in progress; finish or abort it before switching branches." \
      "$HOME/op.stderr"
  done
}

@test "git branches: switch refuses a branch checked out in another worktree and names it" {
  run run_zsh "$(branch_repo)"'
    command git worktree add -q "$HOME/topic-tree" topic 2>/dev/null || return 9
    git-switch topic >"$HOME/tree.stdout" 2>"$HOME/tree.stderr"
    local -i tree_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    print -r -- "$tree_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  [ ! -s "$HOME/tree.stdout" ]
  grep -Fq "topic is checked out in another worktree: $HOME/topic-tree" \
    "$HOME/tree.stderr"
}

@test "git branches: a dirty switch shows its plan and fails closed without a choice or terminal" {
  run run_zsh "$(branch_repo)"'
    print -r -- "edited a" > a.txt
    print -r -- "staged b" > b.txt
    command git add b.txt || return 9
    local before=""
    before=$(command git status --porcelain=v1) || return 9

    git-switch topic >"$HOME/plain.stdout" 2>"$HOME/plain.stderr"
    local -i plain_rc=$?
    git-switch topic --yes >"$HOME/yes.stdout" 2>"$HOME/yes.stderr"
    local -i yes_rc=$?
    git-switch topic --stash >"$HOME/stash.stdout" 2>"$HOME/stash.stderr"
    local -i stash_rc=$?

    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ "$(command git status --porcelain=v1)" == "$before" ]] || return 11
    [[ -z "$(command git stash list)" ]] || return 12
    print -r -- "$plain_rc:$yes_rc:$stash_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:1:1" ]
  [ ! -s "$HOME/plain.stdout" ]
  [ ! -s "$HOME/yes.stdout" ]
  [ ! -s "$HOME/stash.stdout" ]
  grep -Eq "Staged: +1 file" "$HOME/plain.stderr"
  grep -Eq "Unstaged: +1 file" "$HOME/plain.stderr"
  grep -Eq "1 +modified +a\.txt" "$HOME/plain.stderr"
  grep -Eq "2 +staged +b\.txt" "$HOME/plain.stderr"
  # topic changes b.txt, so only stashing is offered.
  grep -Fq "Carrying is not possible: topic also changes these files:" \
    "$HOME/plain.stderr"
  grep -Fq "zdx git-switch: main -> topic" "$HOME/plain.stderr"
  grep -Fq "needs a terminal and fzf; pass --carry or --stash" "$HOME/plain.stderr"
  grep -Fq -- "--yes needs --carry or --stash" "$HOME/yes.stderr"
  grep -Fq "Refusing to continue without a terminal; pass --yes after reviewing the plan." \
    "$HOME/stash.stderr"
}

@test "git branches: --carry keeps untouched changes and refuses changes the target rewrites" {
  run run_zsh "$(branch_repo)"'
    print -r -- "edited b" > b.txt
    git-switch topic --carry --yes >"$HOME/blocked.stdout" 2>"$HOME/blocked.stderr"
    local -i blocked_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ "$(<b.txt)" == "edited b" ]] || return 11
    command git checkout -q -- b.txt || return 12

    print -r -- "edited a" > a.txt
    git-switch topic --carry --yes >"$HOME/carry.stdout" 2>"$HOME/carry.stderr" ||
      return 13
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/topic ]] || return 14
    [[ "$(<a.txt)" == "edited a" && "$(<b.txt)" == "topic b" ]] || return 15
    [[ -z "$(command git stash list)" ]] || return 16
    print -r -- "$blocked_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  [ ! -s "$HOME/blocked.stdout" ]
  [ ! -s "$HOME/carry.stdout" ]
  grep -Fq "Refusing to carry changes that topic would overwrite; use --stash." \
    "$HOME/blocked.stderr"
  grep -Eq "1 +Switch to topic, carrying the 1 changed file" "$HOME/carry.stderr"
  grep -Fq "Switched to topic from main, carrying 1 changed file." "$HOME/carry.stderr"
}

@test "git branches: --stash saves the changes with a named stash and then switches" {
  run run_zsh "$(branch_repo)"'
    print -r -- "edited a" > a.txt
    print -r -- "staged b" > b.txt
    command git add b.txt || return 9
    git-switch topic --stash --yes >"$HOME/stash.stdout" 2>"$HOME/stash.stderr" ||
      return 10
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/topic ]] || return 11
    [[ -z "$(command git status --porcelain=v1 --untracked-files=no)" ]] || return 12
    [[ "$(command git stash list --format=%gs)" \
      == "On main: zdx git-switch: main -> topic" ]] || return 13
    command git stash show -p "stash@{0}" | command grep -Fq "edited a" || return 14
    command git stash show -p "stash@{0}" | command grep -Fq "staged b" || return 15
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/stash.stdout" ]
  grep -Eq "1 +Stash the 2 changed files as 'zdx git-switch: main -> topic'" \
    "$HOME/stash.stderr"
  grep -Fq "Stash the changes — done: stash@{0}" "$HOME/stash.stderr"
  grep -Fq "Switch to topic — done" "$HOME/stash.stderr"
  grep -Fq "Switched to topic from main; the changes are in stash@{0}." \
    "$HOME/stash.stderr"
  grep -Fq "Restore them with: git-stash pop " "$HOME/stash.stderr"
}

@test "git branches: a switch that fails after stashing keeps the stash and names it" {
  run run_zsh "$(branch_repo)"'
    print -r -- "edited a" > a.txt
    local lock_file=""
    lock_file="$(command git rev-parse --absolute-git-dir)/index.lock" || return 9
    # A lock taken after the stash, just before git switch, makes it fail.
    functions[_git_test_run_captured]=$functions[_git_run_captured]
    _git_run_captured() {
      [[ "$1" == "git switch "* ]] && : > "$lock_file"
      _git_test_run_captured "$@"
    }
    git-switch topic --stash --yes >"$HOME/fail.stdout" 2>"$HOME/fail.stderr"
    local -i fail_rc=$?
    command rm -f -- "$lock_file"
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ "$(command git stash list --format=%gs)" \
      == "On main: zdx git-switch: main -> topic" ]] || return 11
    command git stash show -p "stash@{0}" | command grep -Fq "edited a" || return 12
    print -r -- "$fail_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" -ne 0 ]
  [ ! -s "$HOME/fail.stdout" ]
  grep -Fq "Stash the changes — done" "$HOME/fail.stderr"
  grep -Fq "Switch to topic — failed" "$HOME/fail.stderr"
  grep -Fq "The switch did not reach the reviewed state; HEAD is on main." \
    "$HOME/fail.stderr"
  grep -Fq "Restore them here with: git-stash pop " "$HOME/fail.stderr"
}

@test "git branches: dry runs and a declined confirmation change nothing" {
  run run_zsh "$(branch_repo)$(refs_snapshot)"'
    print -r -- "edited a" > a.txt
    local before=""
    before=$(command git status --porcelain=v1) || return 9
    git-switch topic --stash --dry-run >"$HOME/stash-dry.stdout" \
      2>"$HOME/stash-dry.stderr" || return 10
    git-switch topic --carry --dry-run >"$HOME/carry-dry.stdout" \
      2>"$HOME/carry-dry.stderr" || return 11
    git-switch topic --dry-run >"$HOME/choice-dry.stdout" \
      2>"$HOME/choice-dry.stderr" || return 12
    _git_confirm_outcome() { REPLY=cancelled; }
    git-switch topic --stash >"$HOME/declined.stdout" 2>"$HOME/declined.stderr" ||
      return 13
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 14
    [[ "$(command git status --porcelain=v1)" == "$before" ]] || return 15
    [[ -z "$(command git stash list)" ]] || return 16
    '"$(refs_unchanged)"'
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  local name
  for name in stash-dry carry-dry choice-dry declined; do
    [ ! -s "$HOME/$name.stdout" ]
  done
  grep -Eq "1 +Stash the 1 changed file as 'zdx git-switch: main -> topic'" \
    "$HOME/stash-dry.stderr"
  grep -Eq "2 +Switch to topic" "$HOME/stash-dry.stderr"
  grep -Fq "Dry run: 1 branch switch planned; nothing was changed." \
    "$HOME/stash-dry.stderr"
  grep -Fq "Dry run: 1 branch switch planned; nothing was changed." \
    "$HOME/carry-dry.stderr"
  grep -Eq "carry +keep the 1 changed file in the working tree on topic" \
    "$HOME/choice-dry.stderr"
  grep -Eq "stash +save them as 'zdx git-switch: main -> topic', then switch" \
    "$HOME/choice-dry.stderr"
  grep -Fq "Cancelled: nothing was switched." "$HOME/declined.stderr"
}

@test "git branches: switch revalidates the tree and the target ref after confirmation" {
  run run_zsh "$(branch_repo)"'
    print -r -- "edited a" > a.txt
    _git_confirm_outcome() {
      print -r -- "edited again" > a.txt
      REPLY=confirmed
    }
    git-switch topic --carry >"$HOME/tree.stdout" 2>"$HOME/tree.stderr"
    local -i tree_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ "$(<a.txt)" == "edited again" ]] || return 11

    local topic_oid=""
    topic_oid=$(command git rev-parse topic) || return 12
    _git_confirm_outcome() {
      command git update-ref refs/heads/topic "$(command git rev-parse main)"
      REPLY=confirmed
    }
    git-switch topic --stash >"$HOME/ref.stdout" 2>"$HOME/ref.stderr"
    local -i ref_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 13
    [[ -z "$(command git stash list)" ]] || return 14
    [[ "$(<a.txt)" == "edited again" ]] || return 15
    print -r -- "$tree_rc:$ref_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:1" ]
  grep -Fq "Repository state changed after review; nothing was switched." \
    "$HOME/tree.stderr"
  grep -Fq "Repository state changed after review; nothing was switched." \
    "$HOME/ref.stderr"
}

@test "git branches: the change dialog offers only possible choices and its choice runs the plan" {
  run run_zsh "$(branch_repo)"'
    _git_require_interactive() { return 0; }
    _git_select_action() {
      shift 2
      print -rl -- "${@%%$'\''\t'\''*}" >"$HOME/choices"
      REPLY="$_test_choice"
    }

    print -r -- "edited b" > b.txt
    local _test_choice=cancel
    git-switch topic >"$HOME/cancel.stdout" 2>"$HOME/cancel.stderr" || return 10
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 11
    [[ "$(<"$HOME/choices")" == $'\''Stash Changes and Switch\nCancel'\'' ]] || return 12

    _test_choice=stash
    git-switch topic >"$HOME/stash.stdout" 2>"$HOME/stash.stderr" || return 13
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/topic ]] || return 14
    [[ "$(command git stash list --format=%gs)" \
      == "On main: zdx git-switch: main -> topic" ]] || return 15

    print -r -- "edited a" > a.txt
    _test_choice=carry
    git-switch main >"$HOME/carry.stdout" 2>"$HOME/carry.stderr" || return 16
    [[ "$(<"$HOME/choices")" \
      == $'\''Carry Changes\nStash Changes and Switch\nCancel'\'' ]] || return 17
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 18
    [[ "$(<a.txt)" == "edited a" ]] || return 19
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Cancelled: nothing was switched." "$HOME/cancel.stderr"
  grep -Fq "Switched to topic from main; the changes are in stash@{0}." \
    "$HOME/stash.stderr"
  grep -Fq "Switched to main from topic, carrying 1 changed file." \
    "$HOME/carry.stderr"
}

@test "git branches: switch refuses untracked or ignored files the target would overwrite" {
  run run_zsh "$(branch_repo)"'
    command git switch -q topic || return 9
    print -r -- "tracked log" > build.log
    command git add -f build.log || return 9
    mkdir -p notes
    print -r -- "planned" > notes/plan.txt
    command git add notes/plan.txt || return 9
    command git commit -q -m "feat: tracked log" || return 9
    command git switch -q main || return 9

    print -r -- "local topic" > topic.txt
    git-switch topic >"$HOME/untracked.stdout" 2>"$HOME/untracked.stderr"
    local -i untracked_rc=$?
    [[ "$(<topic.txt)" == "local topic" ]] || return 10
    command rm -f -- topic.txt

    print -r -- "local secret" > build.log
    git-switch topic >"$HOME/ignored.stdout" 2>"$HOME/ignored.stderr"
    local -i ignored_rc=$?
    [[ "$(<build.log)" == "local secret" ]] || return 11
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 12
    command rm -f -- build.log

    # An untracked directory may receive new files that do not exist yet.
    mkdir -p notes
    print -r -- "mine" > notes/mine.txt
    git-switch topic >"$HOME/directory.stdout" 2>"$HOME/directory.stderr" ||
      return 13
    [[ "$(<notes/mine.txt)" == "mine" && "$(<notes/plan.txt)" == "planned" ]] ||
      return 14
    print -r -- "$untracked_rc:$ignored_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:1" ]
  grep -Fq "would overwrite or remove these untracked or ignored paths:" \
    "$HOME/untracked.stderr"
  grep -Fq "topic.txt" "$HOME/untracked.stderr"
  grep -Fq "build.log" "$HOME/ignored.stderr"
  grep -Fq "Refusing to switch; move or remove these paths first." \
    "$HOME/ignored.stderr"
}

@test "git branches: switch refuses to create a tracking branch at a name a dangling alias holds" {
  run run_zsh "$(branch_repo)$(branch_remote)"'
    # for-each-ref and show-ref skip a dangling alias, and git switch -c would
    # create refs/heads/missing through it instead of the planned branch.
    command git symbolic-ref refs/heads/feature refs/heads/missing || return 9
    git-switch feature >"$HOME/plan.stdout" 2>"$HOME/plan.stderr"
    local -i plan_rc=$?
    command git show-ref --verify --quiet refs/heads/missing && return 10
    [[ "$(command git symbolic-ref --quiet refs/heads/feature)" \
      == refs/heads/missing ]] || return 11
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 12

    # An alias that appears after confirmation is refused before the switch.
    command git symbolic-ref --delete refs/heads/feature || return 13
    print -r -- "edited a" > a.txt
    _git_confirm_outcome() {
      command git symbolic-ref refs/heads/feature refs/heads/missing || return 1
      REPLY=confirmed
    }
    git-switch feature --carry >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    local -i late_rc=$?
    command git show-ref --verify --quiet refs/heads/missing && return 14
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 15
    [[ "$(<a.txt)" == "edited a" ]] || return 16
    print -r -- "$plan_rc:$late_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:1" ]
  [ ! -s "$HOME/plan.stdout" ]
  [ ! -s "$HOME/late.stdout" ]
  grep -Fq "Local branch 'feature' already exists as a symbolic ref." \
    "$HOME/plan.stderr"
  grep -Fq "Local branch 'feature' already exists as a symbolic ref." \
    "$HOME/late.stderr"
}

@test "git branches: the picker lists local branches before remote-only ones with a constant preview" {
  export MOCK_FZF_MODE=match
  export MOCK_FZF_MATCH=$'\tremote\t'
  run run_zsh "$(branch_repo)$(branch_remote)"'
    _git_require_interactive() { return 0; }
    git-switch >"$HOME/picker.stdout" 2>"$HOME/picker.stderr" || return 10
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/feature ]] || return 11
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/picker.stdout" ]
  [ "$(cut -f2 "$MOCK_FZF_INPUT_FILE")" = $'local\nremote' ]
  awk -F '\t' 'NF != 4 || $3 !~ /^[0-9a-f]{40}$/ { exit 1 }' "$MOCK_FZF_INPUT_FILE"
  grep -Eq $'^1\tlocal\t[0-9a-f]{40}\ttopic +.* no upstream$' "$MOCK_FZF_INPUT_FILE"
  grep -Eq $'^2\tremote\t[0-9a-f]{40}\torigin/feature +.* remote only; creates local feature$' \
    "$MOCK_FZF_INPUT_FILE"
  ! grep -Fq "origin/main" "$MOCK_FZF_INPUT_FILE" || false
  # The preview reads only the object ID field (printf %q escapes braces).
  grep -Fq 'oid=\{3\}' "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Repository: repository | Branch: main | Changes: 0" "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Type to filter | Enter switch | Esc cancel | Ctrl-/ details" \
    "$MOCK_FZF_ARGS_FILE"
}

@test "git branches: a cancelled picker changes nothing and returns zero" {
  run run_zsh "$(branch_repo)"'
    _git_require_interactive() { return 0; }
    git-switch >"$HOME/cancel.stdout" 2>"$HOME/cancel.stderr" || return 10
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 11
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/cancel.stdout" ]
}

@test "git branches: a change made while the switch picker is open refuses the switch" {
  wrap_fzf_with_side_effect
  # The picker showed a clean tree, so the switch would take the path that
  # asks no question and carry the new edit without a reviewed plan.
  cat > "$HOME/picker-side-effect" <<'EOF'
cd "$HOME/repository" || exit 1
printf '%s\n' "edited while the picker was open" > a.txt
EOF
  export MOCK_FZF_MODE=match
  export MOCK_FZF_MATCH=$'\tlocal\t'
  run run_zsh "$(branch_repo)"'
    _git_require_interactive() { return 0; }
    git-switch >"$HOME/race.stdout" 2>"$HOME/race.stderr"
    local -i race_rc=$?
    [[ -e "$HOME/picker-side-effect.ran" ]] || return 9
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ "$(<a.txt)" == "edited while the picker was open" ]] || return 11
    print -r -- "$race_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  [ ! -s "$HOME/race.stdout" ]
  grep -Fq "Repository state changed while the picker was open; nothing was switched. Run git-switch again." \
    "$HOME/race.stderr"
}

@test "git branches: a clean switch never overwrites an ignored file that appears after review" {
  export REAL_GIT
  REAL_GIT=$(command -v git)
  # As an editor or a build could after the plan, an ignored file appears at
  # a path the target tracks just before git switch runs.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == switch && " $* " == *" --no-guess "* \
  && ! -e "$HOME/.ignored-appeared" ]]; then
  : > "$HOME/.ignored-appeared"
  printf '%s\n' "local secret" > build.log
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"
  run run_zsh "$(branch_repo)"'
    command git switch -q topic || return 9
    print -r -- "tracked log" > build.log
    command git add -f build.log || return 9
    command git commit -q -m "feat: tracked log" || return 9
    command git switch -q main || return 9

    git-switch topic >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    local -i late_rc=$?
    [[ -e "$HOME/.ignored-appeared" ]] || return 10
    [[ "$(<build.log)" == "local secret" ]] || return 11
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 12
    print -r -- "$late_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  [ ! -s "$HOME/late.stdout" ]
  # Git names the path it refused to overwrite.
  grep -Fq "build.log" "$HOME/late.stderr"
}

@test "git branches: creating a tracking branch never overwrites an ignored file that appears after review" {
  export REAL_GIT
  REAL_GIT=$(command -v git)
  # The ignored file appears just before git switch -c runs, after the
  # obstacle check; --no-overwrite-ignore makes the switch refuse it.
  cat > "$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == switch && " $* " == *" --no-guess "* && " $* " == *" -c "* \
  && ! -e "$HOME/.ignored-appeared" ]]; then
  : > "$HOME/.ignored-appeared"
  printf '%s\n' "local secret" > build.log
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"
  run run_zsh "$(branch_repo)$(branch_remote)"'
    # A branch that exists only on the remote and tracks an ignored path.
    command git switch -q -c logs || return 9
    print -r -- "tracked log" > build.log
    command git add -f build.log || return 9
    command git commit -q -m "feat: tracked log" || return 9
    command git push -q origin logs 2>/dev/null || return 9
    command git switch -q main || return 9
    command git branch -q -D logs || return 9
    command rm -f -- build.log

    git-switch logs >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    local -i late_rc=$?
    [[ -e "$HOME/.ignored-appeared" ]] || return 10
    [[ "$(<build.log)" == "local secret" ]] || return 11
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 12
    command git show-ref --verify --quiet refs/heads/logs && return 13
    print -r -- "$late_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  [ ! -s "$HOME/late.stdout" ]
  grep -Fq "build.log" "$HOME/late.stderr"
}

@test "git branches: a switch plan run from a subdirectory with diff.relative lists every changed path" {
  run run_zsh "$(branch_repo)"'
    mkdir -p sub || return 9
    print -r -- "base s" > sub/s.txt
    command git add sub/s.txt || return 9
    command git commit -q -m "feat: sub" || return 9
    command git switch -q -c other || return 9
    print -r -- "other" > other.txt
    command git add other.txt || return 9
    command git commit -q -m "feat: other" || return 9
    command git switch -q main || return 9
    command git config diff.relative true || return 9
    print -r -- "edited a" > a.txt
    print -r -- "edited s" > sub/s.txt
    cd sub || return 9
    git-switch other --carry --dry-run \
      >"$HOME/relative.stdout" 2>"$HOME/relative.stderr" || return 10
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/relative.stdout" ]
  grep -Eq "Unstaged: +2 files" "$HOME/relative.stderr"
  # The table names the same repository-wide paths as the counts.
  grep -Eq '^ +1 +modified +a\.txt$' "$HOME/relative.stderr"
  grep -Eq '^ +2 +modified +sub/s\.txt$' "$HOME/relative.stderr"
}

@test "git branches: a tracking branch that differs only in letter case is refused" {
  run run_zsh "$(branch_repo)$(branch_remote)"'
    command git config core.ignorecase true || return 9
    command git branch -q Feature main || return 9
    git-switch feature >"$HOME/case.stdout" 2>"$HOME/case.stderr"
    local -i case_rc=$?
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 10
    [[ "$(command git for-each-ref --format="%(refname)" refs/heads)" \
      != *refs/heads/feature* ]] || return 11
    print -r -- "$case_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  grep -Fq "collide on this case-insensitive file system" "$HOME/case.stderr"
  grep -Fq "refs/heads/feature and refs/heads/Feature" "$HOME/case.stderr"
}

# --- git-recover -----------------------------------------------------------------

@test "git branches: recover restores a lost commit only as a new branch" {
  export MOCK_FZF_MODE=first
  run run_zsh "$(branch_repo)$(lost_commit)$(refs_snapshot)"'
    _git_require_interactive() { return 0; }
    _git_read_line() { REPLY=""; }
    local head_before=""
    head_before=$(command git rev-parse HEAD) || return 9
    git-recover --yes >"$HOME/recover.stdout" 2>"$HOME/recover.stderr" || return 10
    local short_oid=""
    short_oid=$(command git rev-parse --short "$LOST_OID") || return 11
    [[ "$(command git rev-parse "refs/heads/recover/$short_oid")" == "$LOST_OID" ]] ||
      return 12
    [[ "$(command git rev-parse HEAD)" == "$head_before" ]] || return 13
    [[ "$(command git symbolic-ref HEAD)" == refs/heads/main ]] || return 14
    '"$(refs_unchanged)"'
    local -a refs_after=("${(@f)$(command git for-each-ref --format="%(refname)")}")
    (( ${#refs_after[@]} == ${#${(@f)REFS_BEFORE}} + 1 )) || return 15
    print -r -- "$short_oid ${LOST_OID[1,12]}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  local short_oid="${output%% *}" long_oid="${output#* }"
  [ ! -s "$HOME/recover.stdout" ]
  grep -Fq "Recover Commit" "$HOME/recover.stderr"
  grep -Fq "Created branch recover/$short_oid at $long_oid." "$HOME/recover.stderr"
  grep -Fq "Switch to it with: git-switch recover/$short_oid" "$HOME/recover.stderr"
  [ "$(wc -l < "$MOCK_FZF_INPUT_FILE")" -eq 1 ]
  grep -Eq $'^1\t[0-9a-f]{40}\t.*feat: lost work +\\((HEAD|main)@\\{[0-9]+\\}\\)$' \
    "$MOCK_FZF_INPUT_FILE"
  grep -Fq 'oid=\{2\}' "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Type to filter | Enter recover | Esc cancel | Ctrl-/ details" \
    "$MOCK_FZF_ARGS_FILE"
}

@test "git branches: switch and recover previews are constant read-only programs" {
  run run_zsh "$(branch_repo)$(lost_commit)"'
    _git_require_interactive() { return 0; }
    _git_select_ids() {
      local -a picker_options=("${(@P)6}")
      local picker_option=""
      for picker_option in "${picker_options[@]}"; do
        [[ "$picker_option" == --preview=* ]] \
          && print -r -- "${picker_option#--preview=}" >> "$HOME/previews"
      done
      print -rn -- $'"'"'\0'"'"' >> "$HOME/previews"
      reply=()
    }
    git-switch >/dev/null 2>&1 || return 10
    git-recover >/dev/null 2>&1 || return 11

    local -a programs=("${(@0)$(<"$HOME/previews")}")
    programs=("${(@)programs:#}")
    (( ${#programs[@]} == 2 )) || return 12
    local hostile="\$(touch $HOME/executed)\`touch $HOME/executed\`"
    local program="" rendered="" value=""
    for program in "${programs[@]}"; do
      [[ "$program" != *"$HOME"* && "$program" != *topic* \
        && "$program" != *"$LOST_OID"* ]] || return 13
      for value in "$hostile" "$LOST_OID"; do
        rendered="${program//\{2\}/${(qq)value}}"
        rendered="${rendered//\{3\}/${(qq)value}}"
        sh -c "$rendered" >"$HOME/rendered" 2>&1
        [[ ! -e "$HOME/executed" ]] || return 14
      done
      # A valid object ID renders that commit.
      command grep -Fq "feat: lost work" "$HOME/rendered" || return 15
    done
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -e "$HOME/executed" ]
}

@test "git branches: recover dry runs, declines, and non-terminal confirmations create nothing" {
  export MOCK_FZF_MODE=first
  run run_zsh "$(branch_repo)$(lost_commit)$(refs_snapshot)"'
    _git_require_interactive() { return 0; }
    _git_read_line() { REPLY="rescued/work"; }
    git-recover --dry-run >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    git-recover >"$HOME/refused.stdout" 2>"$HOME/refused.stderr"
    local -i refused_rc=$?
    _git_confirm_outcome() { REPLY=cancelled; }
    git-recover >"$HOME/declined.stdout" 2>"$HOME/declined.stderr" || return 11
    [[ "$(command git for-each-ref --format="%(refname) %(objectname)")" \
      == "$REFS_BEFORE" ]] || return 12
    print -r -- "$refused_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  grep -Eq "New branch: +rescued/work" "$HOME/dry.stderr"
  grep -Fq "no existing branch is moved or deleted" "$HOME/dry.stderr"
  grep -Fq "Dry run: 1 branch planned; nothing was created." "$HOME/dry.stderr"
  grep -Fq "Refusing to continue without a terminal; pass --yes after reviewing the plan." \
    "$HOME/refused.stderr"
  grep -Fq "Cancelled: nothing was created." "$HOME/declined.stderr"
}

@test "git branches: recover refuses taken, conflicting, and case-colliding names" {
  export MOCK_FZF_MODE=first
  run run_zsh "$(branch_repo)$(lost_commit)"'
    _git_require_interactive() { return 0; }
    command git branch -q rescue main || return 9
    command git branch -q Saved main || return 9
    command git config core.ignorecase true || return 9
    '"$(refs_snapshot)"'
    local -a codes=()
    _git_read_line() { REPLY="topic"; }
    git-recover --yes >"$HOME/taken.stdout" 2>"$HOME/taken.stderr"
    codes+=($?)
    _git_read_line() { REPLY="rescue/work"; }
    git-recover --yes >"$HOME/nested.stdout" 2>"$HOME/nested.stderr"
    codes+=($?)
    _git_read_line() { REPLY="saved"; }
    git-recover --yes >"$HOME/case.stdout" 2>"$HOME/case.stderr"
    codes+=($?)
    _git_read_line() { REPLY="bad..name"; }
    git-recover --yes >"$HOME/invalid.stdout" 2>"$HOME/invalid.stderr"
    codes+=($?)
    '"$(refs_unchanged)"'
    [[ "$(command git for-each-ref --format="%(refname) %(objectname)")" \
      == "$REFS_BEFORE" ]] || return 12
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1,1,1,2" ]
  grep -Fq "Local branch already exists: topic" "$HOME/taken.stderr"
  grep -Fq "rescue/work conflicts with the existing branch rescue." "$HOME/nested.stderr"
  grep -Fq "refs/heads/saved and refs/heads/Saved" "$HOME/case.stderr"
  grep -Fq "Invalid branch name: bad..name" "$HOME/invalid.stderr"
}

@test "git branches: recover refuses a name that a dangling symbolic ref holds" {
  export MOCK_FZF_MODE=first
  run run_zsh "$(branch_repo)$(lost_commit)"'
    _git_require_interactive() { return 0; }
    # for-each-ref and show-ref skip a dangling alias, and a write through it
    # would create refs/heads/missing instead of the planned branch.
    command git symbolic-ref refs/heads/alias refs/heads/missing || return 9
    '"$(refs_snapshot)"'
    _git_read_line() { REPLY="alias"; }
    git-recover --yes >"$HOME/alias.stdout" 2>"$HOME/alias.stderr"
    local -i alias_rc=$?
    command git show-ref --verify --quiet refs/heads/missing && return 10
    [[ "$(command git symbolic-ref --quiet refs/heads/alias)" \
      == refs/heads/missing ]] || return 11
    '"$(refs_unchanged)"'
    [[ "$(command git for-each-ref --format="%(refname) %(objectname)")" \
      == "$REFS_BEFORE" ]] || return 12

    # A free name is still recovered as a direct branch.
    _git_read_line() { REPLY="restored"; }
    git-recover --yes >"$HOME/restored.stdout" 2>"$HOME/restored.stderr" \
      || return 13
    [[ "$(command git rev-parse --verify --quiet refs/heads/restored)" \
      == "$LOST_OID" ]] || return 14
    [[ -z "$(command git for-each-ref --format="%(symref)" \
      refs/heads/restored)" ]] || return 15
    command git show-ref --verify --quiet refs/heads/missing && return 16
    [[ "$(command git symbolic-ref --quiet refs/heads/alias)" \
      == refs/heads/missing ]] || return 17
    print -r -- "$alias_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  [ ! -s "$HOME/alias.stdout" ]
  [ ! -s "$HOME/restored.stdout" ]
  grep -Fq "Local branch 'alias' already exists as a symbolic ref." \
    "$HOME/alias.stderr"
  grep -Fq "Created branch restored at" "$HOME/restored.stderr"
}

@test "git branches: recover writes only the planned name when an alias appears after review" {
  export MOCK_FZF_MODE=first REAL_GIT
  REAL_GIT=$(command -v git)
  # As a concurrent writer could after the final free-name check, the planned
  # name becomes a dangling alias just before Git creates the branch.
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == update-ref && ! -e "$HOME/.alias-swap.done" ]]; then
  : >"$HOME/.alias-swap.done"
  "$REAL_GIT" symbolic-ref refs/heads/late-alias refs/heads/missing || exit 97
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"
  run run_zsh "$(branch_repo)$(lost_commit)"'
    _git_require_interactive() { return 0; }
    _git_read_line() { REPLY="late-alias"; }
    git-recover --yes >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    local -i late_rc=$?
    # The write never lands on the alias target.
    command git show-ref --verify --quiet refs/heads/missing && return 10
    if (( late_rc == 0 )); then
      # Older Git replaces the alias with the planned direct branch.
      [[ -z "$(command git for-each-ref --format="%(symref)" \
        refs/heads/late-alias)" ]] || return 11
      [[ "$(command git rev-parse --verify --quiet refs/heads/late-alias)" \
        == "$LOST_OID" ]] || return 12
    else
      # Newer Git refuses to create over a dangling symbolic ref.
      [[ "$(command git symbolic-ref --quiet refs/heads/late-alias)" \
        == refs/heads/missing ]] || return 13
    fi
    print -r -- "$late_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ -e "$HOME/.alias-swap.done" ]
  [ ! -s "$HOME/late.stdout" ]
  if [ "$output" = "0" ]; then
    grep -Fq "Created branch late-alias at" "$HOME/late.stderr"
  else
    grep -Fq "The branch was not created (exit $output); nothing else changed." \
      "$HOME/late.stderr"
  fi
}

@test "git branches: recover revalidates the name and the commit after confirmation" {
  export MOCK_FZF_MODE=first
  run run_zsh "$(branch_repo)$(lost_commit)"'
    _git_require_interactive() { return 0; }
    _git_read_line() { REPLY="late/name"; }
    local main_oid=""
    main_oid=$(command git rev-parse main) || return 9
    _git_confirm_outcome() {
      command git branch -q late/name main
      REPLY=confirmed
    }
    git-recover >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    local -i late_rc=$?
    # The branch that appeared after review is not moved.
    [[ "$(command git rev-parse late/name)" == "$main_oid" ]] || return 10

    _git_read_line() { REPLY="pruned"; }
    _git_confirm_outcome() {
      command git reflog expire --expire=now --all
      command git gc -q --prune=now 2>/dev/null
      REPLY=confirmed
    }
    git-recover >"$HOME/pruned.stdout" 2>"$HOME/pruned.stderr"
    local -i pruned_rc=$?
    command git show-ref --verify --quiet refs/heads/pruned && return 11
    print -r -- "$late_rc:$pruned_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:1" ]
  grep -Fq "Local branch already exists: late/name" "$HOME/late.stderr"
  grep -Fq "Repository state changed after review; nothing was created." \
    "$HOME/pruned.stderr"
}

@test "git branches: recover --deep adds dropped stashes but never live ones" {
  run run_zsh "$(branch_repo)"'
    _git_require_interactive() { return 0; }
    print -r -- "kept change" > a.txt
    command git stash push -q -m "kept stash" || return 9
    print -r -- "dropped change" > b.txt
    command git stash push -q -m "dropped stash" || return 9
    command git stash drop -q "stash@{0}" || return 9

    git-recover >"$HOME/plain.stdout" 2>"$HOME/plain.stderr" || return 10
    git-recover --deep >"$HOME/deep.stdout" 2>"$HOME/deep.stderr" || return 11
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "No unreachable commits were found in the HEAD and branch reflogs." \
    "$HOME/plain.stderr"
  grep -Fq "git-recover --deep also searches dangling commits." "$HOME/plain.stderr"
  grep -Fq "Searching for dangling commits" "$HOME/deep.stderr"
  grep -Fq "On main: dropped stash  (dangling commit)" "$MOCK_FZF_INPUT_FILE"
  ! grep -Fq "kept stash" "$MOCK_FZF_INPUT_FILE" || false
}

@test "git branches: recover parses its grammar first and needs a terminal" {
  run run_zsh "$(branch_repo)"'
    local -a codes=()
    git-recover --bogus >"$HOME/usage.stdout" 2>"$HOME/usage.stderr"
    codes+=($?)
    git-recover --dry-run --yes >>"$HOME/usage.stdout" 2>>"$HOME/usage.stderr"
    codes+=($?)
    git-recover extra >>"$HOME/usage.stdout" 2>>"$HOME/usage.stderr"
    codes+=($?)
    git-recover >"$HOME/terminal.stdout" 2>"$HOME/terminal.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "2,2,2,1" ]
  [ ! -s "$HOME/usage.stdout" ]
  grep -Fq "Unknown argument for git-recover: --bogus" "$HOME/usage.stderr"
  grep -Fq "This mode requires an interactive terminal." "$HOME/terminal.stderr"
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]
}
