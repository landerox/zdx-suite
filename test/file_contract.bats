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

@test "file contract: frozen public command fixture has five unique commands" {
  run awk -F '\t' '
    NF != 2 || seen[$1]++ { exit 1 }
    END { exit !(NR == 5) }
  ' "$TEST_SUITE_ROOT/test/fixtures/file-public-commands.tsv"
  [ "$status" -eq 0 ]
}

@test "file contract: junk cleanup is the last menu section and names every type" {
  run run_zsh '
    file-menu --help >/dev/null 2>&1
    _file_menu_rows
  '
  [ "$status" -eq 0 ]
  local -a rows
  mapfile -t rows <<< "$output"
  [ "${rows[-2]}" = "── Cleanup ──|:|Delete operating-system metadata files below the current directory." ]
  [[ "${rows[-1]}" == "  Remove Junk Files|file-clean-junk|"* ]]
  local junk_type
  for junk_type in Zone.Identifier .DS_Store '._*' Thumbs.db desktop.ini; do
    [[ "${rows[-1]#*|file-clean-junk|}" == *"$junk_type"* ]]
  done
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

@test "file contract: every frozen command has a dispatcher arm, lazy stub, help entry, and completion binding" {
  local compdef_line
  compdef_line="$(head -n 1 "$TEST_SUITE_ROOT/completions/_file-menu")"
  run run_zsh '
    file-menu --help 2>&1
    print -r -- "--- dispatcher"
    print -r -- "${functions[_file_dispatch]}"
  '
  [ "$status" -eq 0 ]
  local help_text="${output%%--- dispatcher*}"
  local dispatcher="${output#*--- dispatcher}"
  while IFS=$'\t' read -r command_name _description; do
    [[ " $compdef_line " == *" $command_name "* ]]
    [[ "$help_text" == *"$command_name"* ]]
    [[ "$dispatcher" == *"${command_name})"* ]]
    grep -Eq "^    ${command_name} file-menu[.]zsh$" "$TEST_SUITE_ROOT/functions.zsh"
  done < "$TEST_SUITE_ROOT/test/fixtures/file-public-commands.tsv"
}

@test "file contract: the trash section precedes junk cleanup and its grammar is completed" {
  run run_zsh '
    file-menu --help >/dev/null 2>&1
    _file_menu_rows
  '
  [ "$status" -eq 0 ]
  local -a rows
  mapfile -t rows <<< "$output"
  [[ "${rows[-4]}" == "── Trash ──|:|"* ]]
  [[ "${rows[-3]}" == "  Browse Trash|file-trash|"* ]]

  local completion="$TEST_SUITE_ROOT/completions/_file-menu"
  local action flag
  for action in put list restore purge; do
    grep -Fq "'1:action:(${action})'" "$completion"
  done
  for flag in --json --older-than --all --dry-run --yes; do
    grep -Fq -- "${flag}[" "$completion"
  done
  grep -Fq '_file_menu_complete_trash_ids' "$completion"
}
