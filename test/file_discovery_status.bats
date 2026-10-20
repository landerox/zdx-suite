#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "file discovery: large-file results survive a final smaller candidate" {
  run run_zsh '
    file-menu --help >/dev/null 2>&1 || exit
    cd "$HOME" || exit
    print -rn -- larger > match.txt
    print -rn -- x > last.md
    _file_collect_paths() { reply=(match.txt last.md); return 0; }
    file-find-large --min-size 4 > "$TEST_TEMP_DIR/results" || exit
    [[ "$(<"$TEST_TEMP_DIR/results")" == match.txt ]] || exit 91
    file-find-large --min-size 100 > "$TEST_TEMP_DIR/results" || exit
    [[ -z "$(<"$TEST_TEMP_DIR/results")" ]]
  '
  [ "$status" -eq 0 ]
}

@test "file discovery: inventory failures preserve status and suppress partial paths" {
  run run_zsh '
    file-menu --help >/dev/null 2>&1 || exit
    cd "$HOME" || exit
    print -r -- partial > match.txt
    _file_collect_paths() { reply=(match.txt); return "$scan_rc"; }
    for scan_rc in 1 42 130 143; do
      file-find-large --min-size 1 > "$TEST_TEMP_DIR/results"
      actual_rc=$?
      (( actual_rc == scan_rc )) || exit 91
      [[ ! -s "$TEST_TEMP_DIR/results" ]] || exit 92
    done
  '
  [ "$status" -eq 0 ]
}
