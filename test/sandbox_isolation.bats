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
      leaked=$(env | grep -cE "^GIT_(DIR|WORK_TREE|INDEX_FILE|COMMON_DIR)=")
      rm -rf -- "$TEST_TEMP_DIR"
      [[ "$leaked" == 0 ]] || exit 93
    ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ "$(git -C "$guarded_repo" config user.name)" = "Guarded Owner" ]
  [ "$(git -C "$guarded_repo" config --get core.bare)" = "false" ]
}

@test "sandbox isolation: a symlinked TMPDIR parent still yields a canonical sandbox" {
  # Model macOS, whose per-user TMPDIR is reached through /var -> private/var.
  local real_parent="$TEST_TEMP_DIR/private/var/folders/zz/T"
  mkdir -p "$real_parent"
  ln -s private/var "$TEST_TEMP_DIR/var"

  run env TMPDIR="$TEST_TEMP_DIR/var/folders/zz/T/" bash -c '
    source "$1/test/test_helper.bash" || exit 90
    canonical=$(cd "$TEST_TEMP_DIR" && pwd -P) || exit 91
    [[ "$TEST_TEMP_DIR" == "$canonical" ]] || exit 92
    [[ "$TEST_TEMP_DIR" == "$2"/zdx-tests.* ]] || exit 93
    [[ "$HOME" == "$TEST_TEMP_DIR/home" ]] || exit 94
    [[ "$TMPDIR" == "$TEST_TEMP_DIR/tmpdir" ]] || exit 95
    [[ "$(file_mode "$TMPDIR")" == 700 ]] || exit 96
    cleanup_sandbox || exit 97
    [[ ! -e "$canonical" ]] || exit 98
  ' _ "$TEST_SUITE_ROOT" "$real_parent"

  [ "$status" -eq 0 ]
}

@test "sandbox isolation: tests get a private TMPDIR and no host Git or SSH configuration" {
  [ "$TEST_TEMP_DIR" = "$(cd "$TEST_TEMP_DIR" && pwd -P)" ]
  [ "$TMPDIR" = "$TEST_TEMP_DIR/tmpdir" ]
  [ "$(file_mode "$TMPDIR")" = 700 ]
  [ "$GIT_CONFIG_NOSYSTEM" = 1 ]

  run ssh -G -- github-alias
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nhostname github-alias\n'* ]]

  run ssh -o BatchMode=yes git@github.com
  [ "$status" -eq 97 ]
}

@test "sandbox isolation: portable metadata helpers describe the path itself" {
  local file="$TEST_TEMP_DIR/metadata"
  printf 'abc' > "$file"
  chmod 640 "$file"
  [ "$(file_mode "$file")" = 640 ]
  [ "$(file_size "$file")" = 3 ]
  [ "$(file_links "$file")" = 1 ]
  [ "$(file_owner_uid "$file")" = "$(id -u)" ]
  [ "$(file_identity "$file")" = "$(file_stat "$file" device inode)" ]
  [ "$(file_inode "$file")" = "$(file_stat "$file" inode)" ]
  [ "$(file_stat "$file" mode size)" = "640:3" ]

  ln "$file" "$file.hardlink"
  [ "$(file_links "$file")" = 2 ]
  [ "$(file_identity "$file.hardlink")" = "$(file_identity "$file")" ]
  ln -s "$file" "$file.symlink"
  [ "$(file_identity "$file.symlink")" != "$(file_identity "$file")" ]

  mkdir "$TEST_TEMP_DIR/sticky"
  chmod 1700 "$TEST_TEMP_DIR/sticky"
  [ "$(file_mode "$TEST_TEMP_DIR/sticky")" = 1700 ]
  run file_mode "$TEST_TEMP_DIR/missing"
  [ "$status" -ne 0 ]
  [[ "$output" != [0-7]* ]]
}

@test "sandbox isolation: portable content helpers replace sha256sum and truncate" {
  local file="$TEST_TEMP_DIR/content"
  printf 'abc' > "$file"
  [ "$(sha256_file "$file")" = \
    ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]

  make_sized_file "$file" 5
  [ "$(file_size "$file")" = 5 ]
  [ "$(head -c 3 "$file")" = abc ]
  make_sized_file "$file" 2
  [ "$(cat "$file")" = ab ]
  make_sized_file "$TEST_TEMP_DIR/created" 1048577
  [ "$(file_size "$TEST_TEMP_DIR/created")" = 1048577 ]
}
