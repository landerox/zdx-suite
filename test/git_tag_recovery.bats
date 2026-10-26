#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export LC_ALL=C TERM=dumb NO_COLOR=1 GIT_TERMINAL_PROMPT=0
  export GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_AUTHOR_NAME="Tag Recovery Test"
  export GIT_AUTHOR_EMAIL="tag-recovery@example.invalid"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export FETCH_REPO="$HOME/fetch.git" PUSH_REPO="$HOME/push.git"
  export WORK_REPO="$HOME/work" REAL_GIT
  REAL_GIT=$(command -v git)
  git init -q --bare "$FETCH_REPO"
  git -C "$FETCH_REPO" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$PUSH_REPO"
  git init -q "$WORK_REPO"
  git -C "$WORK_REPO" symbolic-ref HEAD refs/heads/main
  git -C "$WORK_REPO" commit -q --allow-empty -m "fixture base"
  git -C "$WORK_REPO" remote add origin "$FETCH_REPO"
  git -C "$WORK_REPO" config remote.origin.pushurl "$PUSH_REPO"
  git -C "$WORK_REPO" push -q "$FETCH_REPO" HEAD:refs/heads/main
  git -C "$WORK_REPO" tag release
}

teardown() {
  cleanup_sandbox
}

@test "git-tag-push recovery: a matching fetch tag does not hide an absent push tag" {
  git -C "$WORK_REPO" push -q "$FETCH_REPO" refs/tags/release
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-push release --remote origin --yes >"$HOME/stdout"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  [ "$(git -C "$PUSH_REPO" rev-parse refs/tags/release)" = \
    "$(git -C "$WORK_REPO" rev-parse refs/tags/release)" ]
}

@test "git-tag-create recovery: an existing fetch tag does not block a distinct push target" {
  git -C "$WORK_REPO" push -q "$FETCH_REPO" refs/tags/release
  git -C "$WORK_REPO" tag -d release >/dev/null
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-create --name release --lightweight --push --remote origin --yes
  '
  [ "$status" -eq 0 ]
  [ "$(git -C "$PUSH_REPO" rev-parse refs/tags/release)" = \
    "$(git -C "$WORK_REPO" rev-parse refs/tags/release)" ]
}

@test "git-tag-delete recovery: removes the tag from the planned push destination" {
  git -C "$WORK_REPO" push -q "$PUSH_REPO" refs/tags/release
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-delete release --remote origin --yes
  '
  [ "$status" -eq 0 ]
  run git -C "$PUSH_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  run git -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
}

@test "git-tag-delete recovery: a symbolic tag is never planned and main survives" {
  export MAIN_OID
  MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  # A symbolic tag that resolves to the current and default branch, so a
  # deletion through it would delete main.
  git -C "$WORK_REPO" symbolic-ref refs/tags/alias refs/heads/main
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-delete --local-only --dry-run \
      >"$HOME/dry.stdout" 2>"$HOME/dry.stderr" || return 10
    [[ "$(<"$HOME/dry.stderr")" != *refs/tags/alias* ]] || return 11

    git-tag-delete alias --local-only --yes \
      >"$HOME/named.stdout" 2>"$HOME/named.stderr"
    named_rc=$?
    [[ "$(command git rev-parse --verify --quiet refs/heads/main)" \
      == "$MAIN_OID" ]] || return 12
    (( named_rc == 1 )) || return 13

    git-tag-delete --local-only --yes \
      >"$HOME/all.stdout" 2>"$HOME/all.stderr" || return 14
  '
  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/dry.stderr" ] || cat "$HOME/dry.stderr" >&2
    [ ! -f "$HOME/named.stderr" ] || cat "$HOME/named.stderr" >&2
    [ ! -f "$HOME/all.stderr" ] || cat "$HOME/all.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/dry.stdout" ]
  [ ! -s "$HOME/named.stdout" ]
  [ ! -s "$HOME/all.stdout" ]
  grep -Fq "Dry run: 1 tag deletion planned; nothing was deleted." \
    "$HOME/dry.stderr"
  grep -Fq "Local tag 'alias' does not exist or is a symbolic ref." \
    "$HOME/named.stderr"
  grep -Fq "Tag deletion complete: 1 local tag." "$HOME/all.stderr"
  [ "$(git -C "$WORK_REPO" rev-parse refs/heads/main)" = "$MAIN_OID" ]
  [ "$(git -C "$WORK_REPO" symbolic-ref refs/tags/alias)" = refs/heads/main ]
  run git -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
}

@test "git-tag-delete recovery: local deletion cannot dereference a tag swapped after review" {
  export MAIN_OID SWAP_TARGET=refs/heads/main
  MAIN_OID=$(git -C "$WORK_REPO" rev-parse refs/heads/main)
  # As a concurrent writer could after revalidation, the reviewed tag becomes
  # a symbolic ref to main just before Git deletes it.
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
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-delete release --local-only --yes \
      >"$HOME/stdout" 2>"$HOME/stderr"
  '
  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/stderr" ] || cat "$HOME/stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  [ -e "$HOME/.symref-swap.done" ]
  [ "$("$REAL_GIT" -C "$WORK_REPO" rev-parse --verify --quiet \
    refs/heads/main)" = "$MAIN_OID" ]
  grep -Fq "Deleted local refs/tags/release at $MAIN_OID." "$HOME/stderr"
  [ -z "$("$REAL_GIT" -C "$WORK_REPO" for-each-ref --format='%(refname)' \
    refs/tags/release)" ]
}

@test "git tags recovery: every tag command refuses a named symbolic tag with one message" {
  git -C "$WORK_REPO" symbolic-ref refs/tags/alias refs/heads/main
  run run_zsh '
    cd "$WORK_REPO" || return 90
    local -a codes=()
    git-tag-verify alias >"$HOME/verify.stdout" 2>"$HOME/verify.stderr"
    codes+=($?)
    git-tag-push alias --remote origin --dry-run \
      >"$HOME/push.stdout" 2>"$HOME/push.stderr"
    codes+=($?)
    git-tag-delete alias --local-only --dry-run \
      >"$HOME/delete.stdout" 2>"$HOME/delete.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '
  if [ "$status" -ne 0 ] || [ "$output" != "1,1,1" ]; then
    printf 'zsh status: %s\ncodes: %s\n' "$status" "$output" >&2
    cat "$HOME/verify.stderr" "$HOME/push.stderr" "$HOME/delete.stderr" \
      >&2 2>/dev/null || true
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "1,1,1" ]
  local command_name
  for command_name in verify push delete; do
    [ ! -s "$HOME/$command_name.stdout" ]
    grep -Fq "Local tag 'alias' does not exist or is a symbolic ref." \
      "$HOME/$command_name.stderr"
  done
  run git -C "$PUSH_REPO" show-ref --verify --quiet refs/tags/alias
  [ "$status" -eq 1 ]
  [ "$(git -C "$WORK_REPO" symbolic-ref refs/tags/alias)" = refs/heads/main ]
}

@test "git-tag-create recovery: a name that a dangling symbolic tag holds is refused" {
  # show-ref skips a dangling symbolic tag, and `git tag` would write the new
  # tag through it, creating the branch refs/heads/missing.
  git -C "$WORK_REPO" symbolic-ref refs/tags/alias refs/heads/missing
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-create --name alias --yes \
      >"$HOME/alias.stdout" 2>"$HOME/alias.stderr"
    alias_rc=$?
    command git show-ref --verify --quiet refs/heads/missing && return 10
    [[ "$(command git symbolic-ref --quiet refs/tags/alias)" \
      == refs/heads/missing ]] || return 11
    (( alias_rc == 1 )) || return 12

    # A free name still becomes a direct tag at HEAD.
    git-tag-create --name fresh --yes \
      >"$HOME/fresh.stdout" 2>"$HOME/fresh.stderr" || return 13
    [[ "$(command git rev-parse --verify --quiet refs/tags/fresh)" \
      == "$(command git rev-parse HEAD)" ]] || return 14
    [[ -z "$(command git for-each-ref --format="%(symref)" \
      refs/tags/fresh)" ]] || return 15
    command git show-ref --verify --quiet refs/heads/missing && return 16
    return 0
  '
  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/alias.stderr" ] || cat "$HOME/alias.stderr" >&2
    [ ! -f "$HOME/fresh.stderr" ] || cat "$HOME/fresh.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/alias.stdout" ]
  [ ! -s "$HOME/fresh.stdout" ]
  grep -Fq "Local tag 'alias' already exists as a symbolic ref." \
    "$HOME/alias.stderr"
}

@test "git-tag-create recovery: a symbolic tag that appears after confirmation is refused" {
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_tag_confirm_outcome() {
      command git symbolic-ref refs/tags/late refs/heads/missing || return
      REPLY=confirmed
    }
    git-tag-create --name late >"$HOME/late.stdout" 2>"$HOME/late.stderr"
    late_rc=$?
    command git show-ref --verify --quiet refs/heads/missing && return 10
    [[ "$(command git symbolic-ref --quiet refs/tags/late)" \
      == refs/heads/missing ]] || return 11
    (( late_rc == 1 )) || return 12
    return 0
  '
  if [ "$status" -ne 0 ]; then
    printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
    [ ! -f "$HOME/late.stderr" ] || cat "$HOME/late.stderr" >&2
  fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/late.stdout" ]
  grep -Fq "Local tag 'late' already exists as a symbolic ref." \
    "$HOME/late.stderr"
}

@test "git tags recovery: dry runs inspect the push target without mutation" {
  git -C "$WORK_REPO" push -q "$FETCH_REPO" refs/tags/release
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-push release --remote origin --dry-run || return
    git-tag-delete release --remote origin --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: "* ]]
  [[ "$output" == *"Tag updates:"* ]]
  run git -C "$PUSH_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  git -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
}

@test "git tags recovery: all remote mutations refuse multiple push URLs" {
  git -C "$WORK_REPO" config --add remote.origin.pushurl "$FETCH_REPO"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-push release --remote origin --yes
    [[ $? == 1 ]] || return 91
    git-tag-create --name new-release --lightweight --push --remote origin --yes
    [[ $? == 1 ]] || return 92
    git-tag-delete release --remote origin --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly one push URL"* ]]
  run git -C "$PUSH_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  run git -C "$FETCH_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  run git -C "$WORK_REPO" show-ref --verify --quiet refs/tags/new-release
  [ "$status" -eq 1 ]
  git -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
}

@test "git-tag-push recovery: remote ref uses the frozen OID when the local tag moves" {
  export FROZEN_OID MOVED_OID
  FROZEN_OID=$(git -C "$WORK_REPO" rev-parse HEAD)
  git -C "$WORK_REPO" commit -q --allow-empty -m "fixture later commit"
  MOVED_OID=$(git -C "$WORK_REPO" rev-parse HEAD)
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == push ]]; then
  "$REAL_GIT" update-ref refs/tags/release "$MOVED_OID" "$FROZEN_OID" || exit
fi
exec "$REAL_GIT" "$@"
MOCK
  chmod +x "$TEST_MOCK_BIN/git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-push release --remote origin --yes
  '
  [ "$status" -eq 0 ]
  [ "$(git -C "$PUSH_REPO" rev-parse refs/tags/release)" = "$FROZEN_OID" ]
  [ "$(git -C "$WORK_REPO" rev-parse refs/tags/release)" = "$MOVED_OID" ]
}

@test "git tags recovery: refusal and cancellation preserve both targets" {
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-push release --remote origin
    [[ $? == 1 ]] || return 91
    _git_tag_confirm_outcome() { REPLY=cancelled; }
    git-tag-push release --remote origin
  '
  [ "$status" -eq 0 ]
  run git -C "$PUSH_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  git -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
}

@test "git tags recovery: adding a push destination after confirmation is refused" {
  run run_zsh '
    cd "$WORK_REPO" || return 90
    _git_tag_confirm_outcome() {
      command git config --add remote.origin.pushurl "$FETCH_REPO" || return
      REPLY=confirmed
    }
    git-tag-push release --remote origin
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly one push URL"* ]]
  run git -C "$PUSH_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  run git -C "$FETCH_REPO" show-ref --verify --quiet refs/tags/release
  [ "$status" -eq 1 ]
  git -C "$WORK_REPO" show-ref --verify --quiet refs/tags/release
}

@test "git-tag-push recovery: a matching push target is a no-op without fetch access" {
  git -C "$WORK_REPO" push -q "$PUSH_REPO" refs/tags/release
  git -C "$WORK_REPO" config remote.origin.url "$HOME/unavailable.git"
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-push release --remote origin --yes >"$HOME/stdout"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Every selected tag already matches"* ]]
  [ ! -s "$HOME/stdout" ]
}
