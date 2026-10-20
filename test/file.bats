#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "file: loader sources all split modules" {
  run run_zsh '
    file-menu --help
    print -r -- "${_FILE_MENU_SOURCED}:${_FILE_COMMON_SOURCED}:${_FILE_ARCHIVE_SOURCED}:${_FILE_OPERATIONS_SOURCED}:${_FILE_DISCOVERY_SOURCED}:${_FILE_TRASH_SOURCED}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"1:1:1:1:1:1"* ]]
}

@test "file: top-level help names all five public commands" {
  run run_zsh 'file-menu --help'
  [ "$status" -eq 0 ]
  for command_name in file-compress file-extract file-find-large file-trash file-clean-junk; do
    [[ "$output" == *"$command_name"* ]]
  done
}

@test "file: unknown direct command returns usage status" {
  run run_zsh 'file-menu file-not-real'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command"* ]]
}

@test "file: large-file deletion dry-run preserves every target" {
  run run_zsh '
    mkdir "$HOME/large" && cd "$HOME/large" || return
    print -r -- first > one
    print -r -- second > two
    file-find-large --min-size 1 --delete --dry-run || return
    [[ -f one && -f two ]]
  '
  [ "$status" -eq 0 ]
  # Large-file plans keep discovery order, so match the rows in either order.
  [[ "$output" == *[12]"  one"* && "$output" == *[12]"  two"* ]]
  [[ "$output" == *"Dry run: 2 files planned; nothing was deleted."* ]]
}

@test "file: noninteractive large-file deletion fails closed without yes" {
  run run_zsh '
    mkdir "$HOME/large" && cd "$HOME/large" || return
    print -r -- data > victim
    file-find-large --min-size 1 --delete
  '
  [ "$status" -eq 2 ]
  [ -f "$HOME/large/victim" ]
  [[ "$output" == *"pass --yes"* ]]
}
