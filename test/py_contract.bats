#!/usr/bin/env bats

setup() {
  load test_helper
  PY_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/py-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

@test "py contract: snapshot membership treats full rows literally" {
  run run_zsh '
    local selected="Upgrade|tool-upgrade|Tools, packages (latest)."
    local -a rows=(
      "$selected"
      "List|tool-list|Other row."
    )
    _py_array_contains_literal "$selected" "${rows[@]}" || return 1
    ! _py_array_contains_literal \
      "${selected} forged" "${rows[@]}" || return 2
  '

  [ "$status" -eq 0 ]
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$PY_CONTRACT" | sort
}

assert_contract_matches() {
  local actual="$1"
  local expected
  expected=$(contract_commands)
  if [[ "$actual" != "$expected" ]]; then
    diff -u \
      <(printf '%s\n' "$expected") \
      <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

@test "py contract: fixture freezes 16 unique canonical commands" {
  local count=0
  local command_name module_name risk capability extra

  while IFS=$'\t' read -r command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))
    [[ "$command_name" =~ ^[a-z]+(-[a-z]+)+$ ]]
    [[ "$module_name" =~ ^py-[a-z]+\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive|network)$ ]]
    [[ "$capability" =~ ^[a-z]+(-[a-z]+)*$ ]]
    [[ -z "$extra" ]]
    [[ -f "$TEST_SUITE_ROOT/functions/py/$module_name" ]]
  done < "$PY_CONTRACT"

  [ "$count" -eq 16 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "py contract: every canonical command is a real public function" {
  local command_list
  command_list=$(contract_commands | tr '\n' ' ')

  run run_zsh "
    source '$TEST_SUITE_ROOT/functions/py-menu.zsh' || return 1
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

@test "py contract: declared modules own every canonical function" {
  local command_name module_name risk capability
  while IFS=$'\t' read -r command_name module_name risk capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/py/$module_name"
  done < "$PY_CONTRACT"
}

@test "py contract: the normal interactive menu matches the fixture" {
  run run_zsh '
    fzf() {
      command cat >"$HOME/py-menu.rows"
      return 130
    }
    py-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr"
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$HOME/py-menu.rows" | sort
  '

  [ "$status" -eq 0 ]
  assert_contract_matches "$output"
}

@test "py contract: dispatcher forwards arguments to representative owners" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/py-menu.zsh" || return 1
    venv-create() {
      print -r -- "venv:$#:${(j.:.)@}"
    }
    package-install() {
      print -r -- "package:$#:${(j.:.)@}"
    }
    tool-upgrade() {
      print -r -- "tool:$#:${(j.:.)@}"
    }
    _py_dispatch venv-create --python 3.12 --dry-run
    _py_dispatch package-install ruff --dev --yes
    _py_dispatch tool-upgrade --all --backend uv
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"venv:3:--python:3.12:--dry-run"* ]]
  [[ "$output" == *"package:3:ruff:--dev:--yes"* ]]
  [[ "$output" == *"tool:3:--all:--backend:uv"* ]]
}

@test "py contract: help and dispatcher arms match the fixture" {
  local actual
  actual=$(
    sed -n '/^_py_dispatch()/,/^}/p' "$TEST_SUITE_ROOT/functions/py-menu.zsh" \
      | sed -nE 's/^[[:space:]]*([a-z]+(-[a-z]+)+)\)([[:space:]].*)?$/\1/p' \
      | sort
  )
  assert_contract_matches "$actual"

  run run_zsh 'py-menu --help'
  [ "$status" -eq 0 ]
  actual=$(printf '%s\n' "$output" \
    | sed -nE 's/^  ([a-z]+(-[a-z]+)+)( .*)?$/\1/p' \
    | grep -vx 'py-menu' | sort)
  assert_contract_matches "$actual"
}

@test "py contract: completion covers the menu and exactly the direct commands" {
  local compdef_line actual
  compdef_line=$(head -n 1 "$TEST_SUITE_ROOT/completions/_py-menu")
  [[ " $compdef_line " == *" py-menu "* ]]
  actual=$(tr ' ' '\n' <<<"$compdef_line" \
    | grep -vx -e '#compdef' -e 'py-menu' | sort)
  assert_contract_matches "$actual"
  grep -q 'command_name="$service"' \
    "$TEST_SUITE_ROOT/completions/_py-menu"
  ! grep -q -- "'--path=" "$TEST_SUITE_ROOT/completions/_py-menu" || false
}

@test "py contract: only canonical actions reach the timer" {
  run run_zsh '
    _py_timed() { print -r -- "$1 $2" >>"$HOME/timing"; shift; "$@"; }
    forged-action() { print -r -- reached >>"$HOME/unexpected"; }
    fzf() { print -r -- reached >>"$HOME/unexpected"; return 130; }
    venv-list() { print -r -- "$#:$1"; return 3; }
    typeset -i rc=0
    for token in "" : forged-action; do
      rc=0
      py-menu "$token" >"$HOME/stdout" 2>"$HOME/stderr" || rc=$?
      [[ "$rc" == 2 && ! -s "$HOME/stdout" && -s "$HOME/stderr" ]] || return 1
    done
    _py_dispatch : || return 1
    [[ ! -e "$HOME/timing" && ! -e "$HOME/unexpected" ]] || return 1
    setopt shwordsplit ksharrays
    _py_dispatch venv-list "two words" || rc=$?
    [[ "$rc" == 3 && -o shwordsplit && -o ksharrays ]] || return 1
    command cat "$HOME/timing"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'1:two words\npy:venv-list venv-list' ]
}

@test "py contract: one interactive selection preserves each action status" {
  run run_zsh '
    fzf() {
      command awk -F "|" '\''$2 == "venv-list" { print }'\''
    }
    _py_timed() { print -r -- "$1 $2" >>"$HOME/timing"; shift; "$@"; }
    venv-list() { return "$expected"; }
    typeset -i expected=0 actual=0 failures=0
    for expected in 0 2 3 124 130 143; do
      actual=0
      py-menu >"$HOME/stdout" 2>"$HOME/stderr" || actual=$?
      if (( actual != expected )) || [[ -s "$HOME/stdout" ]]; then
        print -r -- "selection: expected $expected, got $actual"
        (( ++failures ))
      fi
    done
    (( failures == 0 )) || return 1
    command cat "$HOME/timing"
  '

  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  [ "$(printf '%s\n' "${lines[@]}" | sort -u)" = "py:venv-list venv-list" ]
}

@test "py contract: invalid operands and help tails are diagnosed before dependency work" {
  export PY_CONTRACT
  run run_zsh '
    unexpected() { print -r -- "$*" >>"$HOME/unexpected"; return 1; }
    _py_prompt_package_name() { unexpected name; }
    _py_validate_project_root() { unexpected project; }
    _py_check_command() { unexpected dependency "$@"; }
    _py_tool_inventory() { unexpected inventory "$@"; }
    _py_resolve_python() { unexpected interpreter "$@"; }
    fzf() { unexpected picker; }
    typeset -i failures=0 help_cases=0
    check_bad_cli() {
      local expected_message="$1"
      shift
      local -i actual_rc=0
      "$@" >"$HOME/stdout" 2>"$HOME/stderr" || actual_rc=$?
      if (( actual_rc != 2 )) || [[ -s "$HOME/stdout" ]] \
        || ! command grep -Fq -- "$expected_message" "$HOME/stderr"; then
        print -r -- "status $actual_rc for ${(q)@}"
        command cat "$HOME/stderr"
        (( ++failures ))
      fi
    }
    check_bad_cli "Invalid command argument" py-menu ""
    for action in venv-remove venv-activate venv-info venv-rebuild; do
      check_bad_cli "--path requires a directory" "$action" --path
      check_bad_cli "--path requires a directory" "$action" --path ""
    done
    for action in tool-uninstall tool-upgrade; do
      check_bad_cli "--backend requires uv or pipx" "$action" --backend
      check_bad_cli "Only one tool" "$action" a b
    done
    check_bad_cli "Invalid venv-list argument" venv-list ""
    check_bad_cli "Invalid tool-list argument" tool-list ""
    check_bad_cli "Tool backend must be uv or pipx" tool-install --backend invalid
    check_bad_cli "Tool backend must be uv or pipx" tool-install --backend=invalid
    while IFS=$'\''\t'\'' read -r action rest; do
      [[ -n "$action" && "$action" != \#* ]] || continue
      (( ++help_cases ))
      check_bad_cli "Help does not accept additional arguments." "$action" --help extra
    done <"$PY_CONTRACT" || return 1
    if [[ -e "$HOME/unexpected" ]]; then
      command cat "$HOME/unexpected"
      (( ++failures ))
    fi
    (( failures == 0 && help_cases == 16 ))
  '

  [ "$status" -eq 0 ]
}

@test "py contract: top-level help documents aliases and command flags" {
  run run_zsh 'py-menu --help'

  [ "$status" -eq 0 ]
  [[ "$output" == *"-m|--multi"* ]]
  [[ "$output" == *"selected read-only tasks"* ]]
  [[ "$output" == *"py-menu <command> --help"* ]]
  [[ "$output" == *"--dry-run"* && "$output" == *"--yes"* ]]
  [[ "$output" == *"--path"* && "$output" == *"--backend"* ]]
}
