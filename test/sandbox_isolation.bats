#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "sandbox isolation: inherited Git hook variables never reach fixture repositories" {
  local guarded_repo="$TEST_TEMP_DIR/guarded"
  git init -q -b main "$guarded_repo"
  git -C "$guarded_repo" config user.name "Guarded Owner"

  # Model a pre-push hook in a linked worktree, which exports GIT_DIR and
  # friends; loading the helper must clear every repository-local variable.
  run env \
    GIT_DIR="$guarded_repo/.git" \
    GIT_WORK_TREE="$guarded_repo" \
    GIT_INDEX_FILE="$guarded_repo/.git/index" \
    GIT_COMMON_DIR="$guarded_repo/.git" \
    bash -c '
      source "$1/test/test_helper.bash" || exit 90
      fixture="$TEST_TEMP_DIR/fixture"
      git init -q -b main "$fixture" || exit 91
      git -C "$fixture" config user.name "Fixture User" || exit 92
      leaked=$(env | grep -c "^GIT_\(DIR\|WORK_TREE\|INDEX_FILE\|COMMON_DIR\)=")
      rm -rf -- "$TEST_TEMP_DIR"
      [[ "$leaked" == 0 ]] || exit 93
    ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ "$(git -C "$guarded_repo" config user.name)" = "Guarded Owner" ]
  [ "$(git -C "$guarded_repo" config --get core.bare)" = "false" ]
}
