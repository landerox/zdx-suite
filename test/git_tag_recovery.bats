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

@test "git tags recovery: dry runs inspect the push target without mutation" {
  git -C "$WORK_REPO" push -q "$FETCH_REPO" refs/tags/release
  run run_zsh '
    cd "$WORK_REPO" || return 90
    git-tag-push release --remote origin --dry-run || return
    git-tag-delete release --remote origin --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
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
