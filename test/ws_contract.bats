#!/usr/bin/env bats

setup() {
  load test_helper
  WS_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/ws-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

@test "ws contract: snapshot membership treats full rows literally" {
  run run_zsh '
    local selected="Workspace|ws-list|Paths, branches (exact)."
    local -a rows=(
      "$selected"
      "Jump|ws-jump|Other row."
    )
    _ws_array_contains_literal "$selected" "${rows[@]}" || return 1
    ! _ws_array_contains_literal \
      "${selected} forged" "${rows[@]}" || return 2
  '

  [ "$status" -eq 0 ]
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$WS_CONTRACT" | sort
}

assert_contract_matches() {
  local surface_name="$1"
  local actual="$2"
  local expected
  expected=$(contract_commands)

  if [[ "$actual" != "$expected" ]]; then
    echo "Public command drift in: $surface_name" >&2
    diff -u \
      <(printf '%s\n' "$expected") \
      <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

@test "ws contract: fixture freezes 15 unique commands and valid metadata" {
  local count=0
  local command_name module_name risk capability extra

  while IFS=$'\t' read -r command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))

    [[ "$command_name" =~ ^ws-[a-z0-9-]+$ ]]
    [[ "$module_name" =~ ^ws-[a-z0-9-]+\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive|network)$ ]]
    [[ "$capability" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
    [[ -z "$extra" ]]
    [[ -f "$TEST_SUITE_ROOT/functions/ws/$module_name" ]]
  done < "$WS_CONTRACT"

  [ "$count" -eq 15 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "ws contract: every command is defined by its declared module" {
  local command_name module_name risk capability

  while IFS=$'\t' read -r command_name module_name risk capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue

    if ! grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/ws/$module_name"; then
      echo "$command_name is not defined by $module_name" >&2
      return 1
    fi
  done < "$WS_CONTRACT"
}

@test "ws contract: every public command loads in Zsh" {
  local command_list
  command_list=$(contract_commands | tr '\n' ' ')

  run run_zsh "
    local command_name
    for command_name in $command_list; do
      typeset -f \"\$command_name\" &>/dev/null || {
        print -u2 -r -- \"Missing public function: \$command_name\"
        return 1
      }
    done
  "

  [ "$status" -eq 0 ]
}

@test "ws contract: interactive menu entries match the contract" {
  run run_zsh '
    fzf() {
      command cat >"$HOME/ws-menu.rows"
      return 130
    }
    ws-menu
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$HOME/ws-menu.rows" | sort
  '

  [ "$status" -eq 0 ]
  assert_contract_matches "interactive menu" "$output"
}

@test "ws contract: dispatcher executes every canonical command" {
  local command_list
  command_list=$(contract_commands | tr '\n' ' ')

  run run_zsh "
    _ws_verify_deps() { return 0; }

    local command_name result
    for command_name in $command_list; do
      functions[\$command_name]='print -r -- "\$0"'
      result=\$(_ws_dispatch \"\$command_name\") || return 1
      [[ \"\$result\" == \"\$command_name\" ]] || return 2
    done
  "

  [ "$status" -eq 0 ]
}

@test "ws contract: help lists exactly the canonical commands" {
  run run_zsh "ws-menu --help"
  [ "$status" -eq 0 ]

  local token
  local -a help_commands=()
  for token in $output; do
    token="${token%,}"
    [[ "$token" =~ ^ws-[a-z0-9-]+$ && "$token" != "ws-menu" ]] \
      && help_commands+=("$token")
  done

  local actual
  actual=$(printf '%s\n' "${help_commands[@]}" | sort -u)
  assert_contract_matches "--help" "$actual"
}

@test "ws contract: completion entries and bindings match the contract" {
  local completion_file="$TEST_SUITE_ROOT/completions/_ws-menu"
  [ -f "$completion_file" ]

  local entries bindings
  entries=$(sed -n '/subcmds=(/,/)/p' "$completion_file" \
    | sed -n "s/^[[:space:]]*'\\([^:]*\\):.*/\\1/p" \
    | sort)
  bindings=$(sed -n '1s/^#compdef[[:space:]]*//p' "$completion_file" \
    | tr ' ' '\n' \
    | grep -v '^ws-menu$' \
    | sort)

  assert_contract_matches "completion entries" "$entries"
  assert_contract_matches "direct completion bindings" "$bindings"
}

@test "ws contract: cancellation returns zero without dispatch" {
  run run_zsh '
    fzf() {
      command cat >/dev/null
      return 130
    }
    _ws_dispatch() {
      print -r -- "$1" >>"$HOME/ws-dispatch.log"
      return 99
    }

    ws-menu
    local rc=$?
    [[ ! -e "$HOME/ws-dispatch.log" ]] || return 1
    return $rc
  '

  [ "$status" -eq 0 ]
}

@test "ws contract: direct routing preserves arguments timing and status" {
  run run_zsh '
    _ws_timed() {
      print -r -- "$1" >"$HOME/ws-timing"
      shift
      "$@"
    }
    _ws_dispatch() {
      print -rl -- "$@" >"$HOME/ws-dispatch"
      return 17
    }

    ws-menu ws-clone "owner/repo with spaces"
  '

  [ "$status" -eq 17 ]
  [ "$(cat "$HOME/ws-timing")" = "ws:ws-clone" ]
  [ "$(cat "$HOME/ws-dispatch")" = \
    $'ws-clone\nowner/repo with spaces' ]
}
