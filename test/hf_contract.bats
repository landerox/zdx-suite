#!/usr/bin/env bats

setup() {
  load test_helper
  HF_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/hf-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

@test "hf contract: snapshot membership treats full rows literally" {
  run run_zsh '
    local selected="Repo (downloads: 42, likes: 7)	1"
    local -a rows=(
      "$selected"
      "Other (downloads: 1, likes: 0)	2"
    )
    _hf_array_contains_literal "$selected" "${rows[@]}" || return 1
    ! _hf_array_contains_literal \
      "${selected} forged" "${rows[@]}" || return 2
  '

  [ "$status" -eq 0 ]
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$HF_CONTRACT" | sort
}

@test "hf contract: fixture freezes five unique canonical commands" {
  local count=0
  local command_name module_name risk capability extra

  while IFS=$'\t' read -r \
    command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))
    [ -n "$module_name" ]
    [ -n "$risk" ]
    [ -n "$capability" ]
    [ -z "$extra" ]
    [ -f "$TEST_SUITE_ROOT/functions/hf/$module_name" ]
    grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/hf/$module_name"
  done < "$HF_CONTRACT"

  [ "$count" -eq 5 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "hf contract: menu, help, dispatcher, and completion agree" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    hf-menu >/dev/null 2>&1
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE" | sort
  '
  [ "$status" -eq 0 ]
  [ "$output" = "$(contract_commands)" ]

  while IFS=$'\t' read -r \
    command_name _module_name _risk _capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue

    run run_zsh "
      functions[$command_name]='print -r -- \"\$0\"; return 17'
      _hf_dispatch $command_name
    "
    [ "$status" -eq 17 ]
    [ "$output" = "$command_name" ]

    run run_zsh "hf-menu --help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$command_name"* ]]
  done < "$HF_CONTRACT"

  local bindings
  bindings=$(sed -n '1s/^#compdef[[:space:]]*//p' \
    "$TEST_SUITE_ROOT/completions/_hf-menu" \
    | tr ' ' '\n' \
    | grep -v '^hf-menu$' \
    | sort)
  [ "$bindings" = "$(contract_commands)" ]
}

@test "hf contract: every canonical command is registered for lazy loading" {
  while IFS=$'\t' read -r \
    command_name _module_name _risk _capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    grep -Eq "^[[:space:]]+${command_name}[[:space:]]+hf-menu[.]zsh$" \
      "$TEST_SUITE_ROOT/functions.zsh"
  done < "$HF_CONTRACT"
}
