#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

# Local-change workflows: unstage, stash, amend, and discard of every change.
# Each test uses a disposable repository inside the sandbox.

setup() {
  load test_helper
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
}

teardown() {
  cleanup_sandbox
}

# Prints Zsh that creates a repository with one commit whose message has a
# body and a sign-off trailer.
local_repo() {
  cat <<'ZSH'

    local repo_dir="$HOME/repository"
    command git init -q -b main "$repo_dir" || return 81
    cd "$repo_dir" || return 82
    command git config user.name "Local Test"
    command git config user.email "local@example.invalid"
    command git config core.hooksPath /dev/null
    command git config commit.gpgSign false
    print -r -- "base a" > a.txt
    print -r -- "base b" > b.txt
    print -r -- "base c" > c.txt
    print -r -- "*.log" > .gitignore
    command git add -A || return 83
    command git commit -q -m "feat: base" -m "Body line." \
      -m "Signed-off-by: Local Test <local@example.invalid>" || return 84
ZSH
}

# Prints Zsh that adds an unstaged edit, a staged edit, a staged new file, an
# untracked file in a new directory, and an ignored file.
local_changes() {
  cat <<'ZSH'

    print -r -- "edited a" > a.txt
    print -r -- "staged b" > b.txt
    command git add b.txt || return 85
    print -r -- "new file" > new.txt
    command git add new.txt || return 86
    mkdir -p scratch/deep
    print -r -- "untracked" > scratch/deep/notes.txt
    print -r -- "ignored" > debug.log
ZSH
}

show_failure() {
  printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
  cat "$HOME"/*.stderr >&2 2>/dev/null || true
}

# --- Discard all changes ---------------------------------------------------------

@test "git local changes: discard --all dry run lists every tracked change and stays inert" {
  run run_zsh "$(local_repo)$(local_changes)"'
    local before
    before=$(command git status --porcelain=v1 --untracked-files=all --ignored)
    git-discard --all --dry-run >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    [[ "$(command git status --porcelain=v1 --untracked-files=all --ignored)" == "$before" ]] \
      || return 11
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/dry.stdout" ]
  grep -Fq "Discard All Changes" "$HOME/dry.stderr"
  grep -Eq '1 +modified +restore +a\.txt' "$HOME/dry.stderr"
  grep -Eq '2 +staged +restore +b\.txt' "$HOME/dry.stderr"
  grep -Eq '3 +added +delete +new\.txt' "$HOME/dry.stderr"
  grep -Fq "Not included: 1 untracked file; --include-untracked deletes them." \
    "$HOME/dry.stderr"
  grep -Fq "Dry run: 3 files planned; nothing was discarded." "$HOME/dry.stderr"
  ! grep -Fq "debug.log" "$HOME/dry.stderr" || false
}

@test "git local changes: discard --all resets staged and unstaged changes and keeps untracked and ignored files" {
  run run_zsh "$(local_repo)$(local_changes)"'
    git-discard --all --yes >"$HOME/all.stdout" 2>"$HOME/all.stderr" || return 10
    [[ "$(<a.txt)" == "base a" && "$(<b.txt)" == "base b" ]] || return 11
    [[ ! -e new.txt ]] || return 12
    [[ -z "$(command git diff --cached --name-only)" ]] || return 13
    [[ -z "$(command git diff --name-only)" ]] || return 14
    [[ "$(<scratch/deep/notes.txt)" == "untracked" ]] || return 15
    [[ "$(<debug.log)" == "ignored" ]] || return 16
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/all.stdout" ]
  grep -Fq "Restored: a.txt" "$HOME/all.stderr"
  grep -Fq "Deleted: new.txt" "$HOME/all.stderr"
  grep -Fq "Discard completed: 3 files discarded." "$HOME/all.stderr"
}

@test "git local changes: discard --all --include-untracked deletes untracked files but never ignored files or nested repositories" {
  run run_zsh "$(local_repo)$(local_changes)"'
    mkdir -p mixed
    print -r -- "untracked" > mixed/plain.txt
    print -r -- "ignored" > mixed/kept.log
    command git init -q vendor/lib || return 9
    print -r -- "nested" > vendor/lib/file.txt

    git-discard --all --include-untracked --dry-run \
      >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    git-discard --all --include-untracked --yes \
      >"$HOME/all.stdout" 2>"$HOME/all.stderr" || return 11

    [[ ! -e scratch ]] || return 12
    [[ ! -e mixed/plain.txt && -d mixed ]] || return 13
    [[ "$(<mixed/kept.log)" == "ignored" ]] || return 14
    [[ "$(<debug.log)" == "ignored" ]] || return 15
    [[ "$(<vendor/lib/file.txt)" == "nested" ]] || return 16
    [[ -z "$(command git status --porcelain=v1 --untracked-files=no)" ]] || return 17
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/dry.stdout" ]
  [ ! -s "$HOME/all.stdout" ]
  grep -Eq 'untracked +delete +scratch/deep/notes\.txt' "$HOME/dry.stderr"
  grep -Eq 'untracked +delete +mixed/plain\.txt' "$HOME/dry.stderr"
  grep -Fq "Kept: 1 nested repository." "$HOME/dry.stderr"
  grep -Fq "Ignored files are kept; directories left empty are removed." \
    "$HOME/dry.stderr"
  ! grep -Fq "kept.log" "$HOME/dry.stderr" || false
  ! grep -Fq "vendor/lib" "$HOME/dry.stderr" || false
  grep -Fq "Dry run: 5 files planned; nothing was discarded." "$HOME/dry.stderr"
  grep -Fq "Deleted: scratch/deep/notes.txt" "$HOME/all.stderr"
  grep -Fq "Discard completed: 5 files discarded." "$HOME/all.stderr"
}

@test "git local changes: discard --all fails closed without a terminal and honors a declined confirmation" {
  run run_zsh "$(local_repo)$(local_changes)"'
    local before
    before=$(command git status --porcelain=v1 --untracked-files=all)

    git-discard --all >"$HOME/refused.stdout" 2>"$HOME/refused.stderr"
    local -i refused_rc=$?
    [[ "$(command git status --porcelain=v1 --untracked-files=all)" == "$before" ]] \
      || return 10

    _git_confirm_outcome() { REPLY=cancelled; }
    git-discard --all --include-untracked \
      >"$HOME/cancel.stdout" 2>"$HOME/cancel.stderr"
    local -i cancel_rc=$?
    [[ "$(command git status --porcelain=v1 --untracked-files=all)" == "$before" ]] \
      || return 11

    print -r -- "$refused_rc:$cancel_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:0" ]
  [ ! -s "$HOME/refused.stdout" ]
  [ ! -s "$HOME/cancel.stdout" ]
  grep -Fq -- "--yes" "$HOME/refused.stderr"
  grep -Fq "Cancelled: nothing was discarded." "$HOME/cancel.stderr"
}

@test "git local changes: discard --all refuses when the repository changes after confirmation" {
  run run_zsh "$(local_repo)$(local_changes)"'
    _git_confirm_outcome() {
      print -r -- "edited again" > a.txt
      REPLY=confirmed
    }
    git-discard --all >"$HOME/tracked.stdout" 2>"$HOME/tracked.stderr" && return 10
    [[ "$(<a.txt)" == "edited again" && "$(<b.txt)" == "staged b" ]] || return 11
    [[ -e new.txt ]] || return 12

    _git_confirm_outcome() {
      print -r -- "rewritten during review" > scratch/deep/notes.txt
      REPLY=confirmed
    }
    git-discard --all --include-untracked \
      >"$HOME/untracked.stdout" 2>"$HOME/untracked.stderr" && return 13
    [[ "$(<scratch/deep/notes.txt)" == "rewritten during review" ]] || return 14
    [[ "$(<a.txt)" == "edited again" ]] || return 15
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Repository changed after review; nothing was discarded." \
    "$HOME/tracked.stderr"
  grep -Fq "Repository changed after review; nothing was discarded." \
    "$HOME/untracked.stderr"
}

@test "git local changes: discard --all refuses an operation in progress, an unborn HEAD, and invalid flags" {
  run run_zsh "$(local_repo)"'
    command git switch -q -c topic || return 9
    print -r -- "topic a" > a.txt
    command git commit -qam "topic" || return 10
    command git switch -q main || return 11
    print -r -- "main a" > a.txt
    command git commit -qam "main" || return 12
    command git merge -q topic >/dev/null 2>&1 && return 13

    git-discard --all --yes >"$HOME/merge.stdout" 2>"$HOME/merge.stderr"
    local -i merge_rc=$?
    [[ -f .git/MERGE_HEAD ]] || return 14

    git-discard --include-untracked >"$HOME/flags.stdout" 2>"$HOME/flags.stderr"
    local -i flags_rc=$?
    git-discard --all --dry-run --yes >>"$HOME/flags.stdout" 2>>"$HOME/flags.stderr"
    local -i combined_rc=$?

    command git init -q -b main "$HOME/unborn" || return 15
    cd "$HOME/unborn" || return 16
    print -r -- "new" > staged.txt
    command git add staged.txt || return 17
    git-discard --all --yes >"$HOME/unborn.stdout" 2>"$HOME/unborn.stderr"
    local -i unborn_rc=$?
    [[ -n "$(command git diff --cached --name-only)" ]] || return 18

    print -r -- "$merge_rc:$flags_rc:$combined_rc:$unborn_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:2:2:1" ]
  grep -Fq "A merge is in progress; finish or abort it before discarding all changes." \
    "$HOME/merge.stderr"
  grep -Fq -- "--include-untracked requires --all." "$HOME/flags.stderr"
  grep -Fq "there is no last commit to reset to" "$HOME/unborn.stderr"
}

@test "git local changes: discard --all refuses to overwrite an untracked file at a tracked path" {
  run run_zsh "$(local_repo)"'
    command git rm -q --cached c.txt || return 9
    print -r -- "precious local copy" > c.txt
    git-discard --all --yes >"$HOME/all.stdout" 2>"$HOME/all.stderr" && return 10
    [[ "$(<c.txt)" == "precious local copy" ]] || return 11
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Refusing to overwrite or remove untracked or ignored paths." \
    "$HOME/all.stderr"
}

@test "git local changes: the discard picker offers all-changes rows before file rows" {
  export MOCK_FZF_MODE=match
  export MOCK_FZF_MATCH=$'\tall-untracked\t'
  run run_zsh "$(local_repo)$(local_changes)"'
    git-discard --yes >"$HOME/picker.stdout" 2>"$HOME/picker.stderr" || return 10
    [[ "$(<a.txt)" == "base a" && ! -e new.txt && ! -e scratch ]] || return 11
    [[ "$(<debug.log)" == "ignored" ]] || return 12
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/picker.stdout" ]
  [ "$(sed -n 1p "$MOCK_FZF_INPUT_FILE")" = \
    $'1\tall\tDiscard all changes (3 tracked files)' ]
  [ "$(sed -n 2p "$MOCK_FZF_INPUT_FILE")" = \
    $'2\tall-untracked\tDiscard all changes and delete untracked files (1 untracked file)' ]
  [ "$(sed -n 3p "$MOCK_FZF_INPUT_FILE")" = $'3\tfile\ta.txt' ]
  grep -Fq -- "--multi" "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Tab mark several files" "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Discard All Changes" "$HOME/picker.stderr"
}

# --- Unstage -------------------------------------------------------------------

@test "git local changes: unstage --all dry run is inert and a safe batch needs no confirmation" {
  run run_zsh "$(local_repo)"'
    print -r -- "staged b" > b.txt
    print -r -- "new file" > new.txt
    command git add b.txt new.txt || return 9

    git-unstage --all --dry-run >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    [[ "$(command git diff --cached --name-only)" == $'"'"'b.txt\nnew.txt'"'"' ]] || return 11

    git-unstage --all >"$HOME/all.stdout" 2>"$HOME/all.stderr" || return 12
    [[ -z "$(command git diff --cached --name-only)" ]] || return 13
    [[ "$(<b.txt)" == "staged b" && "$(<new.txt)" == "new file" ]] || return 14
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/dry.stdout" ]
  [ ! -s "$HOME/all.stdout" ]
  grep -Fq "Unstage Files" "$HOME/dry.stderr"
  grep -Eq '1 +staged +b\.txt' "$HOME/dry.stderr"
  grep -Eq '2 +added +new\.txt' "$HOME/dry.stderr"
  grep -Fq "Dry run: 2 files planned; nothing was unstaged." "$HOME/dry.stderr"
  grep -Fq "Unstaged: new.txt" "$HOME/all.stderr"
  grep -Fq "Unstage completed: 2 files unstaged." "$HOME/all.stderr"
}

@test "git local changes: unstage requires --yes to drop a staged version missing from the working tree" {
  run run_zsh "$(local_repo)"'
    print -r -- "staged b" > b.txt
    command git add b.txt || return 9
    print -r -- "edited after staging" > b.txt
    print -r -- "gone soon" > gone.txt
    command git add gone.txt || return 10
    rm -f gone.txt

    git-unstage --all >"$HOME/refused.stdout" 2>"$HOME/refused.stderr"
    local -i refused_rc=$?
    [[ "$(command git diff --cached --name-only)" == $'"'"'b.txt\ngone.txt'"'"' ]] || return 11

    _git_confirm_outcome() { REPLY=cancelled; }
    git-unstage --all >"$HOME/cancel.stdout" 2>"$HOME/cancel.stderr"
    local -i cancel_rc=$?
    [[ -n "$(command git diff --cached --name-only)" ]] || return 12
    unfunction _git_confirm_outcome

    git-unstage --all --yes >"$HOME/yes.stdout" 2>"$HOME/yes.stderr" || return 13
    [[ -z "$(command git diff --cached --name-only)" ]] || return 14
    [[ "$(<b.txt)" == "edited after staging" ]] || return 15

    print -r -- "$refused_rc:$cancel_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:0" ]
  grep -Fq "Unstaging loses the staged content of 2 files because it differs from the working tree:" \
    "$HOME/refused.stderr"
  grep -Fq -- "--yes" "$HOME/refused.stderr"
  grep -Fq "Cancelled: nothing was unstaged." "$HOME/cancel.stderr"
  grep -Fq "Unstage completed: 2 files unstaged." "$HOME/yes.stderr"
}

@test "git local changes: unstage picker selects every file or exactly one file" {
  export MOCK_FZF_MODE=match
  export MOCK_FZF_MATCH=$'\tfile\tb.txt'
  run run_zsh "$(local_repo)"'
    print -r -- "staged a" > a.txt
    print -r -- "staged b" > b.txt
    command git add a.txt b.txt || return 9

    git-unstage >"$HOME/one.stdout" 2>"$HOME/one.stderr" || return 10
    [[ "$(command git diff --cached --name-only)" == "a.txt" ]] || return 11

    command git add b.txt || return 12
    export MOCK_FZF_MATCH=$'"'"'\tall\t'"'"'
    git-unstage >"$HOME/all.stdout" 2>"$HOME/all.stderr" || return 13
    [[ -z "$(command git diff --cached --name-only)" ]] || return 14
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/one.stdout" ]
  [ ! -s "$HOME/all.stdout" ]
  [ "$(sed -n 1p "$MOCK_FZF_INPUT_FILE")" = $'1\tall\tAll staged files (2 files)' ]
  grep -Fq "Unstaged: b.txt" "$HOME/one.stderr"
  ! grep -Fq "Unstaged: a.txt" "$HOME/one.stderr" || false
  grep -Fq "Unstage completed: 2 files unstaged." "$HOME/all.stderr"
}

@test "git local changes: unstage works in a repository without commits" {
  run run_zsh '
    command git init -q -b main "$HOME/unborn" || return 9
    cd "$HOME/unborn" || return 10
    print -r -- "first" > first.txt
    command git add first.txt || return 11
    git-unstage --all >"$HOME/unborn.stdout" 2>"$HOME/unborn.stderr" || return 12
    [[ -z "$(command git diff --cached --name-only)" ]] || return 13
    [[ "$(<first.txt)" == "first" ]] || return 14
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/unborn.stdout" ]
  grep -Fq "Unstaged: first.txt" "$HOME/unborn.stderr"
}

@test "git local changes: unstage refuses when the index changes after confirmation" {
  run run_zsh "$(local_repo)"'
    print -r -- "staged b" > b.txt
    command git add b.txt || return 9
    print -r -- "edited after staging" > b.txt
    _git_confirm_outcome() {
      print -r -- "staged c" > c.txt
      command git add c.txt
      REPLY=confirmed
    }
    git-unstage --all >"$HOME/changed.stdout" 2>"$HOME/changed.stderr" && return 10
    [[ "$(command git diff --cached --name-only)" == $'"'"'b.txt\nc.txt'"'"' ]] || return 11
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Repository state changed after review; nothing was unstaged." \
    "$HOME/changed.stderr"
}

# --- Amend the last commit ----------------------------------------------------

@test "git local changes: amend --message dry run is inert and shows the kept body" {
  run run_zsh "$(local_repo)"'
    local before
    before=$(command git rev-parse HEAD)
    git-amend --message "fix: clearer subject" --dry-run \
      >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    [[ "$(command git rev-parse HEAD)" == "$before" ]] || return 11
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/dry.stdout" ]
  grep -Eq 'Subject: +feat: base' "$HOME/dry.stderr"
  grep -Eq 'New subject: +fix: clearer subject' "$HOME/dry.stderr"
  grep -Eq 'Body: +kept \(3 lines\)' "$HOME/dry.stderr"
  grep -Fq "Dry run: 1 commit planned; nothing was amended." "$HOME/dry.stderr"
}

@test "git local changes: amend --message replaces only the subject and keeps body, trailers, author, and tree" {
  run run_zsh "$(local_repo)"'
    local old_head old_tree old_author
    old_head=$(command git rev-parse HEAD)
    old_tree=$(command git rev-parse "HEAD^{tree}")
    old_author=$(command git log -1 --format="%an <%ae> %at")
    print -r -- "staged b" > b.txt
    command git add b.txt || return 9

    git-amend -m "fix: clearer subject" --yes \
      >"$HOME/amend.stdout" 2>"$HOME/amend.stderr" || return 10

    [[ "$(command git rev-parse HEAD)" != "$old_head" ]] || return 11
    [[ "$(command git rev-parse "HEAD^{tree}")" == "$old_tree" ]] || return 12
    [[ "$(command git log -1 --format="%an <%ae> %at")" == "$old_author" ]] || return 13
    [[ "$(command git diff --cached --name-only)" == "b.txt" ]] || return 14
    command git log -1 --format=%B > "$HOME/message"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/amend.stdout" ]
  [ "$(cat "$HOME/message")" = $'fix: clearer subject\n\nBody line.\n\nSigned-off-by: Local Test <local@example.invalid>' ]
  grep -Fq "Amended main:" "$HOME/amend.stderr"
  ! grep -Fq "force-with-lease" "$HOME/amend.stderr" || false
}

@test "git local changes: amend fails closed without a terminal and honors a declined confirmation" {
  run run_zsh "$(local_repo)"'
    local before
    before=$(command git rev-parse HEAD)
    git-amend --message "fix: refused" >"$HOME/refused.stdout" 2>"$HOME/refused.stderr"
    local -i refused_rc=$?
    _git_confirm_outcome() { REPLY=cancelled; }
    git-amend --message "fix: cancelled" >"$HOME/cancel.stdout" 2>"$HOME/cancel.stderr"
    local -i cancel_rc=$?
    [[ "$(command git rev-parse HEAD)" == "$before" ]] || return 10
    print -r -- "$refused_rc:$cancel_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:0" ]
  grep -Fq -- "--yes" "$HOME/refused.stderr"
  grep -Fq "Cancelled: nothing was amended." "$HOME/cancel.stderr"
}

@test "git local changes: amend refuses when HEAD changes after confirmation" {
  run run_zsh "$(local_repo)"'
    command git branch other || return 9
    _git_confirm_outcome() { command git switch -q other; REPLY=confirmed; }
    git-amend --message "fix: moved" >"$HOME/moved.stdout" 2>"$HOME/moved.stderr" && return 10
    [[ "$(command git log -1 --format=%s main)" == "feat: base" ]] || return 11
    [[ "$(command git log -1 --format=%s other)" == "feat: base" ]] || return 12
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Repository HEAD or diff changed after review; nothing was amended." \
    "$HOME/moved.stderr"
}

@test "git local changes: amend --staged and --reset-author rewrite only what they name" {
  run run_zsh "$(local_repo)"'
    print -r -- "staged b" > b.txt
    print -r -- "unstaged c" > c.txt
    command git add b.txt || return 9
    git-amend --staged --yes >"$HOME/staged.stdout" 2>"$HOME/staged.stderr" || return 10
    [[ "$(command git show HEAD:b.txt)" == "staged b" ]] || return 11
    [[ "$(command git show HEAD:c.txt)" == "base c" ]] || return 12
    [[ "$(command git log -1 --format=%s)" == "feat: base" ]] || return 13
    [[ -z "$(command git diff --cached --name-only)" ]] || return 14

    git-amend --staged --yes >"$HOME/empty.stdout" 2>"$HOME/empty.stderr"
    local -i empty_rc=$?

    command git config user.name "Renamed Author"
    git-amend --reset-author --yes >"$HOME/author.stdout" 2>"$HOME/author.stderr" || return 15
    [[ "$(command git log -1 --format=%an)" == "Renamed Author" ]] || return 16
    [[ "$(command git log -1 --format=%s)" == "feat: base" ]] || return 17
    print -r -- "$empty_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1" ]
  grep -Eq '1 +staged +b\.txt' "$HOME/staged.stderr"
  grep -Fq "Nothing is staged" "$HOME/empty.stderr"
  grep -Eq 'New author: +Renamed Author <local@example.invalid>' "$HOME/author.stderr"
}

@test "git local changes: amend discloses a commit that is already on a remote branch" {
  run run_zsh "$(local_repo)"'
    command git init -q --bare "$HOME/remote.git" || return 9
    command git remote add origin "$HOME/remote.git" || return 10
    command git push -q origin main 2>/dev/null || return 11
    git-amend --message "fix: published" --yes \
      >"$HOME/published.stdout" 2>"$HOME/published.stderr" || return 12
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "The commit is already on origin/main; publishing the rewrite needs git-push --force-with-lease." \
    "$HOME/published.stderr"
  grep -Fq "Publish the rewrite with: git-push --force-with-lease" \
    "$HOME/published.stderr"
}

@test "git local changes: the amend picker offers Change Message first and applies it" {
  export MOCK_FZF_MODE=match
  export MOCK_FZF_MATCH=$'\tmessage\t'
  run run_zsh "$(local_repo)"'
    _git_read_line() { REPLY="fix: chosen in the picker"; }
    git-amend --yes >"$HOME/picker.stdout" 2>"$HOME/picker.stderr" || return 10
    [[ "$(command git log -1 --format=%s)" == "fix: chosen in the picker" ]] || return 11
    [[ "$(command git log -1 --format=%b)" == *"Signed-off-by: Local Test"* ]] || return 12
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/picker.stdout" ]
  [ "$(sed -n 1p "$MOCK_FZF_INPUT_FILE" | cut -f1-2)" = $'Change Message\tmessage' ]
  [ "$(sed -n 2p "$MOCK_FZF_INPUT_FILE" | cut -f2)" = "edit" ]
  grep -Fq "Add Staged Changes (unavailable: nothing staged)" "$MOCK_FZF_INPUT_FILE"
  grep -Fq "Published: no" "$MOCK_FZF_ARGS_FILE"
}

@test "git local changes: the amend editor action edits the full message" {
  export MOCK_FZF_MODE=match
  export MOCK_FZF_MATCH=$'\tedit\t'
  cat > "$HOME/editor.sh" <<'EOF'
#!/bin/sh
printf 'docs: edited in the editor\n\nNew body.\n' > "$1"
EOF
  chmod +x "$HOME/editor.sh"
  export GIT_EDITOR="$HOME/editor.sh"
  run run_zsh "$(local_repo)"'
    git-amend --yes >"$HOME/editor.stdout" 2>"$HOME/editor.stderr" || return 10
    [[ "$(command git log -1 --format=%B)" == $'"'"'docs: edited in the editor\n\nNew body.'"'"' ]] || return 11
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/editor.stdout" ]
  grep -Eq 'Message: +edited in your Git editor after confirmation' "$HOME/editor.stderr"
}

@test "git local changes: amend rejects invalid messages and a missing commit" {
  run run_zsh '
    git-amend --message "" >/dev/null 2>"$HOME/empty.stderr"
    local -i empty_rc=$?
    git-amend --message $'"'"'one\ntwo'"'"' >/dev/null 2>"$HOME/multi.stderr"
    local -i multi_rc=$?
    git-amend -m one --message two >/dev/null 2>"$HOME/dup.stderr"
    local -i duplicate_rc=$?
    command git init -q -b main "$HOME/unborn" || return 9
    cd "$HOME/unborn" || return 10
    git-amend --message "fix: none" --yes >/dev/null 2>"$HOME/unborn.stderr"
    local -i unborn_rc=$?
    print -r -- "$empty_rc:$multi_rc:$duplicate_rc:$unborn_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "2:2:2:1" ]
  grep -Fq -- "--message requires one non-empty line" "$HOME/multi.stderr"
  grep -Fq "Duplicate option: --message" "$HOME/dup.stderr"
  grep -Fq "No commit is available to amend." "$HOME/unborn.stderr"
}

# --- Stashes ------------------------------------------------------------------

@test "git local changes: stash save dry run is inert and save stores tracked changes only" {
  run run_zsh "$(local_repo)$(local_changes)"'
    local before
    before=$(command git status --porcelain=v1 --untracked-files=all)
    git-stash save --dry-run >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    [[ "$(command git status --porcelain=v1 --untracked-files=all)" == "$before" ]] || return 11
    [[ -z "$(command git stash list)" ]] || return 12

    git-stash save --yes >"$HOME/save.stdout" 2>"$HOME/save.stderr" || return 13
    [[ "$(command git stash list | wc -l)" -eq 1 ]] || return 14
    [[ "$(<a.txt)" == "base a" && ! -e new.txt ]] || return 15
    [[ "$(<scratch/deep/notes.txt)" == "untracked" ]] || return 16
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/dry.stdout" ]
  [ ! -s "$HOME/save.stdout" ]
  grep -Fq "Save Changes to a Stash" "$HOME/dry.stderr"
  grep -Eq '1 +modified +a\.txt' "$HOME/dry.stderr"
  grep -Eq '3 +added +new\.txt' "$HOME/dry.stderr"
  ! grep -Fq "notes.txt" "$HOME/dry.stderr" || false
  grep -Fq "Dry run: 3 files planned; nothing was stashed." "$HOME/dry.stderr"
  grep -Fq "Stash saved: 3 files stored as stash@{0}" "$HOME/save.stderr"
}

@test "git local changes: stash save -u records the message and untracked files" {
  run run_zsh "$(local_repo)$(local_changes)"'
    git-stash save -u -m "wip: parser" --yes >"$HOME/save.stdout" 2>"$HOME/save.stderr" || return 10
    [[ "$(command git stash list --format=%s)" == "On main: wip: parser" ]] || return 11
    [[ ! -e scratch/deep/notes.txt && "$(<debug.log)" == "ignored" ]] || return 12
    [[ "$(command git ls-tree -r --name-only "stash@{0}^3")" == "scratch/deep/notes.txt" ]] \
      || return 13
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/save.stdout" ]
  grep -Eq 'Message: +wip: parser' "$HOME/save.stderr"
  grep -Eq '4 +untracked +scratch/deep/notes\.txt' "$HOME/save.stderr"
}

@test "git local changes: stash save reports untracked-only changes without saving them" {
  run run_zsh "$(local_repo)"'
    print -r -- "untracked" > notes.txt
    git-stash save --yes >"$HOME/save.stdout" 2>"$HOME/save.stderr" || return 10
    [[ -z "$(command git stash list)" && -e notes.txt ]] || return 11
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Nothing to save without untracked files; --include-untracked saves 1 untracked file." \
    "$HOME/save.stderr"
}

@test "git local changes: stash apply and pop default to the newest stash" {
  run run_zsh "$(local_repo)"'
    print -r -- "first" > a.txt
    command git stash push -q -m first || return 9
    print -r -- "second" > a.txt
    command git stash push -q -m second || return 10

    git-stash apply --yes >"$HOME/apply.stdout" 2>"$HOME/apply.stderr" || return 11
    [[ "$(<a.txt)" == "second" ]] || return 12
    [[ "$(command git stash list | wc -l)" -eq 2 ]] || return 13
    command git checkout -q -- a.txt || return 14

    git-stash pop "stash@{1}" --dry-run >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 15
    [[ "$(command git stash list | wc -l)" -eq 2 && "$(<a.txt)" == "base a" ]] || return 16

    git-stash pop --yes >"$HOME/pop.stdout" 2>"$HOME/pop.stderr" || return 17
    [[ "$(<a.txt)" == "second" ]] || return 18
    [[ "$(command git stash list --format=%s)" == "On main: first" ]] || return 19
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/apply.stdout" ]
  [ ! -s "$HOME/pop.stdout" ]
  grep -Eq 'Stash: +stash@\{0\}' "$HOME/apply.stderr"
  grep -Fq "the stash is kept." "$HOME/apply.stderr"
  grep -Eq 'Stash: +stash@\{1\}' "$HOME/dry.stderr"
  grep -Fq "Dry run: 1 file planned; nothing was applied." "$HOME/dry.stderr"
  grep -Fq "Popped stash@{0}" "$HOME/pop.stderr"
}

@test "git local changes: stash drop removes exactly the named stashes" {
  run run_zsh "$(local_repo)"'
    local -i stash_number=0
    for stash_number in 1 2 3; do
      print -r -- "change $stash_number" > a.txt
      command git stash push -q -m "stash $stash_number" || return 9
    done

    git-stash drop "stash@{0}" "stash@{2}" --dry-run \
      >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    [[ "$(command git stash list | wc -l)" -eq 3 ]] || return 11

    git-stash drop "stash@{0}" "stash@{2}" --yes \
      >"$HOME/drop.stdout" 2>"$HOME/drop.stderr" || return 12
    [[ "$(command git stash list --format=%s)" == "On main: stash 2" ]] || return 13
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/drop.stdout" ]
  grep -Fq "Drop Stashes" "$HOME/dry.stderr"
  grep -Fq "Dry run: 2 stashes planned; nothing was dropped." "$HOME/dry.stderr"
  grep -Fq "Drop completed: 2 stashes dropped." "$HOME/drop.stderr"
}

@test "git local changes: stash branch checks out a new branch and drops the stash" {
  run run_zsh "$(local_repo)"'
    print -r -- "branch work" > a.txt
    command git stash push -q -m work || return 9
    git-stash branch "stash@{0}" feature/from-stash --yes \
      >"$HOME/branch.stdout" 2>"$HOME/branch.stderr" || return 10
    [[ "$(command git symbolic-ref --short HEAD)" == "feature/from-stash" ]] || return 11
    [[ "$(<a.txt)" == "branch work" && -z "$(command git stash list)" ]] || return 12

    git-stash branch "stash@{0}" "bad..name" >/dev/null 2>"$HOME/invalid.stderr"
    print -r -- "$?"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "2" ]
  [ ! -s "$HOME/branch.stdout" ]
  grep -Fq "Created and checked out feature/from-stash" "$HOME/branch.stderr"
  grep -Fq "Invalid Git branch name." "$HOME/invalid.stderr"
}

@test "git local changes: stash mutations fail closed without a terminal and honor a declined confirmation" {
  run run_zsh "$(local_repo)"'
    print -r -- "kept" > a.txt
    command git stash push -q -m kept || return 9
    print -r -- "local edit" > b.txt

    git-stash save >/dev/null 2>"$HOME/save.stderr"
    local -i save_rc=$?
    git-stash pop >/dev/null 2>"$HOME/pop.stderr"
    local -i pop_rc=$?
    git-stash drop "stash@{0}" >/dev/null 2>"$HOME/drop.stderr"
    local -i drop_rc=$?

    _git_confirm_outcome() { REPLY=cancelled; }
    git-stash save >/dev/null 2>"$HOME/save-cancel.stderr"
    local -i save_cancel_rc=$?
    git-stash drop "stash@{0}" >/dev/null 2>"$HOME/drop-cancel.stderr"
    local -i drop_cancel_rc=$?

    [[ "$(command git stash list | wc -l)" -eq 1 && "$(<b.txt)" == "local edit" ]] || return 10
    print -r -- "$save_rc:$pop_rc:$drop_rc:$save_cancel_rc:$drop_cancel_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1:1:1:0:0" ]
  grep -Fq -- "--yes" "$HOME/save.stderr"
  grep -Fq -- "--yes" "$HOME/drop.stderr"
  grep -Fq "Cancelled: nothing was stashed." "$HOME/save-cancel.stderr"
  grep -Fq "Cancelled: nothing was dropped." "$HOME/drop-cancel.stderr"
}

@test "git local changes: stash save and drop refuse changes made after confirmation" {
  run run_zsh "$(local_repo)"'
    print -r -- "local edit" > a.txt
    _git_confirm_outcome() {
      print -r -- "edited during review" > a.txt
      REPLY=confirmed
    }
    git-stash save >"$HOME/save.stdout" 2>"$HOME/save.stderr" && return 10
    [[ -z "$(command git stash list)" && "$(<a.txt)" == "edited during review" ]] || return 11

    command git stash push -q -m existing || return 12
    _git_confirm_outcome() {
      print -r -- "another" > b.txt
      command git stash push -q -m "added during review"
      REPLY=confirmed
    }
    git-stash drop "stash@{0}" >"$HOME/drop.stdout" 2>"$HOME/drop.stderr" && return 13
    [[ "$(command git stash list | wc -l)" -eq 2 ]] || return 14
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Repository or stash state changed after review; nothing was changed." \
    "$HOME/save.stderr"
  grep -Fq "Repository or stash state changed after review; nothing was changed." \
    "$HOME/drop.stderr"
}

@test "git local changes: stash apply refuses untracked path collisions" {
  run run_zsh "$(local_repo)"'
    print -r -- "stashed new" > new.txt
    command git stash push -q -u -m untracked || return 9
    print -r -- "local new" > new.txt
    git-stash apply --yes >"$HOME/apply.stdout" 2>"$HOME/apply.stderr" && return 10
    [[ "$(<new.txt)" == "local new" ]] || return 11
    [[ "$(command git stash list | wc -l)" -eq 1 ]] || return 12
    return 0
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  grep -Fq "Refusing to apply a stash across untracked or ignored path collisions." \
    "$HOME/apply.stderr"
}

@test "git local changes: the stash manager saves from its first row" {
  export MOCK_FZF_MODE=match
  export MOCK_FZF_MATCH=$'\tsave\t'
  run run_zsh "$(local_repo)$(local_changes)"'
    _git_read_line() { REPLY="from the manager"; }
    _git_confirm_outcome() { print -r -- "$1" >> "$HOME/questions"; REPLY=confirmed; }
    git-stash --yes >"$HOME/manager.stdout" 2>"$HOME/manager.stderr" || return 10
    [[ "$(command git stash list --format=%s)" == "On main: from the manager" ]] || return 11
    [[ ! -e scratch/deep/notes.txt ]] || return 12
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/manager.stdout" ]
  [ "$(sed -n 1p "$MOCK_FZF_INPUT_FILE")" = $'1\tsave\tSave current changes (4 files)' ]
  [ "$(cat "$HOME/questions")" = "Include 1 untracked file?" ]
  grep -Fq "Tab mark several stashes to drop them together" \
    "$MOCK_FZF_ARGS_FILE"
  grep -Fq "Stash saved: 4 files stored as stash@{0}" "$HOME/manager.stderr"
}

@test "git local changes: the stash manager pops through its action picker and drops marked stashes" {
  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env zsh
typeset -a rows=()
typeset row="" prompt="" argument=""
while IFS= read -r row; do rows+=("$row"); done
for argument in "$@"; do
  [[ "$argument" == --prompt=* ]] && prompt="${argument#--prompt=}"
done
print -r -- "$prompt" >> "$HOME/fzf.prompts"
(( $(wc -l < "$HOME/fzf.prompts") <= 8 )) || exit 130
case "$prompt" in
  'git stash > ')
    for row in "${rows[@]}"; do
      case "$STASH_TEST_PICK" in
        pop) [[ "$row" == *$'\t'"stash@{0}  "* ]] && { print -r -- "$row"; exit 0; } ;;
        drop) [[ "$row" == *$'\t'"stash@{"* ]] && print -r -- "$row" ;;
      esac
    done
    ;;
  'stash@{0} > ')
    for row in "${rows[@]}"; do
      [[ "$row" == *$'\t'"pop"$'\t'* ]] && { print -r -- "$row"; exit 0; }
    done
    exit 97
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"

  run run_zsh "$(local_repo)"'
    print -r -- "older" > a.txt
    command git stash push -q -m older || return 9
    print -r -- "newer" > a.txt
    command git stash push -q -m newer || return 10

    export STASH_TEST_PICK=pop
    git-stash --yes >"$HOME/pop.stdout" 2>"$HOME/pop.stderr" || return 11
    [[ "$(<a.txt)" == "newer" ]] || return 12
    [[ "$(command git stash list --format=%s)" == "On main: older" ]] || return 13
    command git checkout -q -- a.txt || return 14

    print -r -- "third" > c.txt
    command git stash push -q -m third || return 15
    : > "$HOME/fzf.prompts"
    export STASH_TEST_PICK=drop
    git-stash --yes >"$HOME/drop.stdout" 2>"$HOME/drop.stderr" || return 16
    [[ -z "$(command git stash list)" ]] || return 17
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -s "$HOME/pop.stdout" ]
  [ ! -s "$HOME/drop.stdout" ]
  grep -Fq "Popped stash@{0}" "$HOME/pop.stderr"
  grep -Fq "Drop completed: 2 stashes dropped." "$HOME/drop.stderr"
  [ "$(cat "$HOME/fzf.prompts")" = $'git stash > \ngit stash > ' ]
}

@test "git local changes: picker previews are constant read-only programs" {
  run run_zsh "$(local_repo)$(local_changes)"'
    command git stash push -q -m previewed || return 9
    print -r -- "edited a" > a.txt
    print -r -- "staged b" > b.txt
    command git add b.txt || return 10

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
    git-stash >/dev/null 2>&1 || return 11
    git-discard >/dev/null 2>&1 || return 12
    git-unstage >/dev/null 2>&1 || return 13

    local -a programs=("${(@0)$(<"$HOME/previews")}")
    programs=("${(@)programs:#}")
    (( ${#programs[@]} == 3 )) || return 14
    local hostile="\$(touch $HOME/executed)\`touch $HOME/executed\`"
    local program="" rendered="" key=""
    for program in "${programs[@]}"; do
      [[ "$program" != *"$HOME"* && "$program" != *previewed* ]] || return 15
      for key in save all all-untracked file "$hostile"; do
        rendered="${program//\{2\}/${(qq)key}}"
        rendered="${rendered//\{3\}/${(qq)hostile}}"
        sh -c "$rendered" >/dev/null 2>&1
        [[ ! -e "$HOME/executed" ]] || return 16
      done
    done
    [[ "$(command git stash list | wc -l)" -eq 1 ]] || return 17
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ ! -e "$HOME/executed" ]
}

@test "git local changes: stash grammar rejects misplaced options and accepts create as save" {
  run run_zsh "$(local_repo)"'
    print -r -- "edited" > a.txt
    git-stash create --dry-run >"$HOME/create.stdout" 2>"$HOME/create.stderr" || return 11

    _git_stash_probe() { print -r -- "$1" >> "$HOME/stash.probes"; return 99; }
    _git_require_repo() { _git_stash_probe repository; }

    git-stash apply -m text >/dev/null 2>"$HOME/misplaced.stderr"
    local -i misplaced_rc=$?
    git-stash -u >/dev/null 2>"$HOME/bare.stderr"
    local -i bare_rc=$?
    git-stash save -u --keep-index >/dev/null 2>/dev/null
    local -i exclusive_rc=$?
    git-stash pop one two >/dev/null 2>/dev/null
    local -i pop_rc=$?
    git-stash save --dry-run --yes >/dev/null 2>/dev/null
    local -i combined_rc=$?
    [[ ! -e "$HOME/stash.probes" ]] || return 10

    print -r -- "$misplaced_rc:$bare_rc:$exclusive_rc:$pop_rc:$combined_rc"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "2:2:2:2:2" ]
  grep -Fq "Save options are valid only with 'git-stash save'." "$HOME/misplaced.stderr"
  grep -Fq "Save options require the explicit 'save' action." "$HOME/bare.stderr"
  grep -Fq "Save Changes to a Stash" "$HOME/create.stderr"
}
