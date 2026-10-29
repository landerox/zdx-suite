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

file_fixture_unique() {
  awk -F '\t' '
    NF != 2 || seen[$1]++ { bad = 1 }
    END { exit (bad || NR != 5) }
  ' "$1"
}

@test "file contract: frozen public command fixture has five unique commands" {
  run file_fixture_unique "$TEST_SUITE_ROOT/test/fixtures/file-public-commands.tsv"
  [ "$status" -eq 0 ]
}

@test "file contract: a duplicate or malformed last fixture row is rejected" {
  local fixture="$TEST_SUITE_ROOT/test/fixtures/file-public-commands.tsv"
  head -n 4 "$fixture" > "$HOME/duplicate.tsv"
  head -n 1 "$fixture" >> "$HOME/duplicate.tsv"
  run file_fixture_unique "$HOME/duplicate.tsv"
  [ "$status" -eq 1 ]

  head -n 4 "$fixture" > "$HOME/malformed.tsv"
  printf 'missing-column\n' >> "$HOME/malformed.tsv"
  run file_fixture_unique "$HOME/malformed.tsv"
  [ "$status" -eq 1 ]
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
    grep -Eq "^[[:space:]]+${command_name}[[:space:]]+file-menu[.]zsh$" "$TEST_SUITE_ROOT/functions.zsh"
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

@test "file contract: archive formats and the extraction limit agree across surfaces" {
  run run_zsh '
    file-compress --help 2>&1
    print -r -- "--- extract"
    file-extract --help 2>&1
    print -r -- "--- formats"
    local format=""
    for format in tar.gz tar.xz tar.bz2 tar.zst zip 7z \
      tgz txz tbz tbz2 tzst .tar.zst rar; do
      if _file_archive_normalize_format "$format" 2>/dev/null; then
        print -r -- "$format=$REPLY"
      else
        print -r -- "$format=refused"
      fi
    done
  '
  [ "$status" -eq 0 ]
  local compress_help="${output%%--- extract*}"
  local extract_help="${output#*--- extract}"
  extract_help="${extract_help%%--- formats*}"
  local normalized="${output#*--- formats}"
  [[ "$normalized" == *$'\ntzst=tar.zst\n'* ]]
  [[ "$normalized" == *$'\n.tar.zst=tar.zst\n'* ]]
  [[ "$normalized" == *$'\nrar=refused'* ]]

  # The help's format list is the completion's, in the same order.
  local formats_line
  formats_line=$(printf '%s\n' "$compress_help" | grep '^Formats: ')
  local help_formats="${formats_line#Formats: }"
  help_formats="${help_formats//, / }"
  [ "$help_formats" = "tar.gz tar.xz tar.bz2 tar.zst zip 7z" ]
  local completion="$TEST_SUITE_ROOT/completions/_file-menu"
  grep -Fq "'--format[archive format]:format:(${help_formats})'" "$completion"
  local format
  for format in $help_formats; do
    [[ "$normalized" == *$'\n'"${format}=${format}"$'\n'* ]]
    grep -Fq "\`$format\`" "$TEST_SUITE_ROOT/docs/file-menu.md"
  done

  # Every extension the extractor accepts is completed and documented.
  local extension
  for extension in .tar .tar.gz .tgz .tar.xz .tar.bz2 .tar.zst .tzst; do
    [[ "$extract_help" == *"$extension"* ]]
    grep -Fq "\`$extension\`" "$TEST_SUITE_ROOT/docs/file-menu.md"
  done
  grep -Fq '_files -g "*.(tar|tar.gz|tgz|tar.xz|tar.bz2|tar.zst|tzst)"' "$completion"

  # The extraction limit is documented wherever settings are.
  [[ "$extract_help" == *"FILE_EXTRACT_MAX_GIB (1-64, default 1)"* ]]
  grep -Fq '# FILE_EXTRACT_MAX_GIB=1' \
    "$TEST_SUITE_ROOT/.config/zdx/config.zsh.example"
  grep -Fq '`FILE_EXTRACT_MAX_GIB`' "$TEST_SUITE_ROOT/docs/file-menu.md"
  grep -Fq '`FILE_EXTRACT_MAX_GIB`' "$TEST_SUITE_ROOT/docs/user-guide.md"
}
