#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "file contract: snapshot membership treats full rows literally" {
  run run_zsh '
    local selected="Archive|file-archive|Files, folders (bounded)."
    local -a rows=(
      "$selected"
      "Inspect|file-inspect|Other row."
    )
    _file_array_contains_literal "$selected" "${rows[@]}" || return 1
    ! _file_array_contains_literal \
      "${selected} forged" "${rows[@]}" || return 2
  '

  [ "$status" -eq 0 ]
}

@test "file contract: frozen public command fixture has ten unique commands" {
  run awk -F '\t' '
    NF != 2 || seen[$1]++ { exit 1 }
    END { exit !(NR == 10) }
  ' "$TEST_SUITE_ROOT/test/fixtures/file-public-commands.tsv"
  [ "$status" -eq 0 ]
}

@test "file contract: menu rows equal the frozen public command fixture" {
  run run_zsh '
    file-menu --help >/dev/null
    _file_menu_rows | command cut -d "|" -f 2 | command grep "^file-"
  '
  [ "$status" -eq 0 ]
  actual="$(printf '%s\n' "$output" | grep '^file-' | sort)"
  expected="$(cut -f1 "$TEST_SUITE_ROOT/test/fixtures/file-public-commands.tsv" | sort)"
  [ "$actual" = "$expected" ]
}

@test "file contract: completion exposes every frozen command" {
  while IFS=$'\t' read -r command_name _description; do
    grep -Fq "'${command_name}:" \
      "$TEST_SUITE_ROOT/completions/_file-menu"
  done < "$TEST_SUITE_ROOT/test/fixtures/file-public-commands.tsv"
}

@test "file contract: direct dispatcher forwards help to every command" {
  while IFS=$'\t' read -r command_name _description; do
    run run_zsh "file-menu $command_name --help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  done < "$TEST_SUITE_ROOT/test/fixtures/file-public-commands.tsv"
}
