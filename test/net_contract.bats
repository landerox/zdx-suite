#!/usr/bin/env bats

setup() {
  load test_helper
  NET_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/net-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

contract_commands() {
  awk -F '\t' 'NF { print $1 }' "$NET_CONTRACT" | sort
}

@test "net contract: fixture freezes six unique canonical commands" {
  local count=0
  local command_name module_name effect capability extra

  while IFS=$'\t' read -r \
    command_name module_name effect capability extra; do
    [ -n "$command_name" ]
    [ -n "$module_name" ]
    [ -n "$effect" ]
    [ -n "$capability" ]
    [ -z "$extra" ]
    [ -f "$TEST_SUITE_ROOT/functions/net/$module_name" ]
    grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/net/$module_name"
    ((count += 1))
  done < "$NET_CONTRACT"

  [ "$count" -eq 6 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "net contract: menu rows equal the frozen fixture" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    net-menu >/dev/null 2>&1
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE" | sort
  '
  [ "$status" -eq 0 ]
  [ "$output" = "$(contract_commands)" ]
}

@test "net contract: dispatcher and help expose every frozen command" {
  local command_name module_name effect capability
  while IFS=$'\t' read -r \
    command_name module_name effect capability; do
    run run_zsh "
      net-menu --help >/dev/null 2>&1
      functions[$command_name]='print -r -- \"\$0\"; return 17'
      _net_dispatch $command_name
    "
    [ "$status" -eq 17 ]
    [ "$output" = "$command_name" ]

    run run_zsh "net-menu $command_name --help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]

    run run_zsh "net-menu --help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$command_name"* ]]
  done < "$NET_CONTRACT"
}

@test "net contract: completion entries and direct bindings match the fixture" {
  local completion_file="$TEST_SUITE_ROOT/completions/_net-menu"
  [ -f "$completion_file" ]

  local bindings
  bindings=$(sed -n '1s/^#compdef[[:space:]]*//p' "$completion_file" \
    | tr ' ' '\n' \
    | grep -v '^net-menu$' \
    | sort)
  [ "$bindings" = "$(contract_commands)" ]

  local entries
  entries=$(sed -n '/net_commands=(/,/)/p' "$completion_file" \
    | sed -n "s/^[[:space:]]*'\\([^:]*\\):.*/\\1/p" \
    | sort)
  [ "$entries" = "$(contract_commands)" ]
}

@test "net contract: completion keeps direct and nested command grammar equal" {
  run env COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_net-menu" \
    zsh -f -c '
      capture_specs() {
        local -a words=("$@")
        local -i CURRENT=${#words[@]}
        local service="${words[1]}"

        _arguments() {
          if [[ "${1:-}" == "-C" ]]; then
            words=("${words[@]:1}")
            (( CURRENT-- ))
            state="args"
            return 0
          fi
          print -rl -- "$@"
        }
        _describe() { return 0; }

        source "$COMPLETION_FILE"
      }

      local command_name=""
      local direct_specs=""
      local nested_specs=""
      for command_name in \
        net-dashboard net-public-ip net-interfaces \
        net-ping net-dns net-speedtest; do
        direct_specs=$(capture_specs "$command_name" "")
        nested_specs=$(capture_specs net-menu "$command_name" "")
        [[ "$direct_specs" == "$nested_specs" ]] || return 1
      done
      [[ "$(capture_specs net-ping "")" == *"--count"* ]] || return 2
      [[ "$(capture_specs net-speedtest "")" == *"--dry-run"* ]] || return 3
    '
  [ "$status" -eq 0 ]
}

@test "net contract: every command has an exact lazy-loader registration" {
  local command_name module_name effect capability
  while IFS=$'\t' read -r \
    command_name module_name effect capability; do
    grep -Eq "^[[:space:]]+${command_name}[[:space:]]+net-menu[.]zsh$" \
      "$TEST_SUITE_ROOT/functions.zsh"
  done < "$NET_CONTRACT"
}

@test "net contract: fixed menu records reject controls and delimiters" {
  run run_zsh '
    net-menu --help >/dev/null
    _net_menu_entry "bad|label" net-ping description
  '
  [ "$status" -eq 2 ]

  run run_zsh '
    net-menu --help >/dev/null
    _net_menu_section "bad'$'\t''title" description
  '
  [ "$status" -eq 2 ]
}
