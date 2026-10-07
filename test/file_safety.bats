#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "file safety: a leading-dash large-file target remains data" {
  run run_zsh '
    mkdir "$HOME/large" && cd "$HOME/large" || return
    print -r -- data > ./-victim
    file-find-large --min-size 1 --delete --yes || return
    [[ ! -e ./-victim ]]
  '
  [ "$status" -eq 0 ]
}

@test "file safety: large-file deletion still refuses the whole plan for an unsafe target" {
  # shellcheck disable=SC2016
  run run_zsh '
    mkdir "$HOME/large" && cd "$HOME/large" || return
    print -r -- data > safe
    print -r -- data > shared
    chmod 664 shared
    file-find-large --min-size 1 --delete --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ownership or permissions are unsafe"* ]]
  [[ "$output" != *"Deleted"* ]]
  [ -f "$HOME/large/safe" ]
  [ -f "$HOME/large/shared" ]
}

@test "file safety: extractor rejects an unvalidated backend" {
  run run_zsh '
    cd "$HOME"
    touch archive.zip
    file-extract --destination extracted --yes -- archive.zip
  '
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/extracted" ]
  [[ "$output" == *"only TAR archives"* ]]
}

@test "file safety: deletion targets cannot contain one another" {
  run run_zsh '
    cd "$HOME"
    mkdir -p parent/child
    _file_collect_paths() { reply=(parent parent/child); return 0; }
    file-find-large --min-size 1 --delete --dry-run
  '
  [ "$status" -ne 0 ]
  [ -d "$HOME/parent/child" ]
  [[ "$output" == *"may not contain one another"* ]]
}

@test "file safety: archive outputs remain inside the current base" {
  run run_zsh '
    cd "$HOME"
    print -r -- content > input
    file-compress --format tar.gz --output ../escape.tar.gz --yes -- input
  '
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TEMP_DIR/escape.tar.gz" ]
}

@test "file safety: a directory archive input plans exactly that directory" {
  # shellcheck disable=SC2016
  run run_zsh '
    mkdir -p "$HOME/work/tree/nested" && cd "$HOME/work" || return
    print -r -- data > tree/nested/file
    file-compress --format tar.gz --output tree.tar.gz --yes -- tree
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Inputs: 1"* ]]
  [[ "$output" != *".zdx-file-archive."* ]]
  [ -f "$HOME/work/tree.tar.gz" ]
  run tar -tzf "$HOME/work/tree.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"./tree/nested/file"* ]]
}
