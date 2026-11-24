#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "file: shared tree validation and discovery follow their declared module boundaries" {
  mkdir -p "$HOME/tree/sub"
  printf 'fixture\n' > "$HOME/tree/sub/.DS_Store"
  cat > "$TEST_MOCK_BIN/timeout" <<'SH'
#!/bin/sh
[ "$1" = -k ] && [ "$2" = 2s ] && [ "$3" = 10s ] || exit 97
case "${4##*/}:${5-}" in
  uname:-s) printf 'Darwin\n' ;;
  find:.) shift 3; exec "$@" ;;
  *) exit 97 ;;
esac
SH
  chmod -- 700 "$TEST_MOCK_BIN/timeout"
  run --separate-stderr zsh -f -c '
    emulate -R zsh
    source "$1/functions/file-common.zsh" || exit 90
    _file_delete_mounts_clear "$HOME/tree" || exit $?
    source "$1/functions/file/file-operations.zsh" || exit 91
    source "$1/functions/file/file-discovery.zsh" || exit 92
    source "$1/functions/file/file-discovery.zsh" || exit 93
    (( ! ${+functions[file-compress]} && ! ${+functions[file-trash]} )) || exit 94
    cd "$HOME/tree" || exit 95
    file-clean-junk --dry-run
  ' _ "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Dry run: 1 file planned; nothing was deleted."* ]]
  [ -f "$HOME/tree/sub/.DS_Store" ]
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
  [ "$status" -eq 1 ]
  [ -f "$HOME/large/victim" ]
  [[ "$output" == *"pass --yes"* ]]
}
