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
    print -r -- "${_FILE_MENU_SOURCED}:${_FILE_COMMON_SOURCED}:${_FILE_ARCHIVE_SOURCED}:${_FILE_OPERATIONS_SOURCED}:${_FILE_DISCOVERY_SOURCED}:${_FILE_DATA_SOURCED}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"1:1:1:1:1:1"* ]]
}

@test "file: top-level help names all ten public commands" {
  run run_zsh 'file-menu --help'
  [ "$status" -eq 0 ]
  for command_name in \
    file-compress file-extract file-bulk-ops file-permissions \
    file-find-large file-find file-diff file-encode-decode \
    file-checksum file-line-endings; do
    [[ "$output" == *"$command_name"* ]]
  done
}

@test "file: unknown direct command returns usage status" {
  run run_zsh 'file-menu file-not-real'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command"* ]]
}

@test "file: delete dry-run preserves every target" {
  run run_zsh '
    cd "$HOME"
    touch one two
    file-bulk-ops delete --dry-run -- one two
    [[ -f one && -f two ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run complete"* ]]
}

@test "file: noninteractive delete fails closed without yes" {
  run run_zsh '
    cd "$HOME"
    touch victim
    file-bulk-ops delete -- victim
  '
  [ "$status" -eq 2 ]
  [ -f "$HOME/victim" ]
  [[ "$output" == *"pass --yes"* ]]
}

@test "file: direct checksum writes a SHA-256 digest" {
  run run_zsh '
    cd "$HOME"
    print -rn -- zdx > input
    file-checksum --algorithm sha256 -- input
  '
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9a-f]{64} ]]
}

@test "file: find accepts one bounded direct mode" {
  run run_zsh '
    cd "$HOME"
    touch alpha.txt beta.md
    file-find --extension txt
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha.txt"* ]]
  [[ "$output" != *"beta.md"* ]]
}

@test "file: diff forwards the standard difference status" {
  run run_zsh '
    cd "$HOME"
    print -r -- left > left
    print -r -- right > right
    file-diff -- left right
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"-left"* ]]
  [[ "$output" == *"+right"* ]]
}
