#!/usr/bin/env bats

setup() {
  load test_helper
  ENV_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/env-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

@test "env contract: bad arguments are diagnosed before an export snapshot or picker" {
  run run_zsh '
    _env_with_export_snapshot() { print -r -- snapshot >>"$HOME/unexpected"; return 97; }
    fzf() { print -r -- picker >>"$HOME/unexpected"; return 97; }
    forged-env-action() { print -r -- dispatch >>"$HOME/unexpected"; }
    _env_timed() { print -r -- "$1" >>"$HOME/timing"; shift; "$@"; }
    typeset -i failures=0
    invalid_env_case() {
      local expected="$1"
      shift
      local -i actual=0
      "$@" >"$HOME/stdout" 2>"$HOME/stderr" || actual=$?
      if (( actual != 2 )) || [[ -s "$HOME/stdout" ]] \
        || ! command grep -Fq -- "$expected" "$HOME/stderr"; then
        print -r -- "status $actual for ${(q)@}"
        command cat "$HOME/stderr"
        (( ++failures ))
      fi
    }
    invalid_env_case "Invalid command argument" env-menu "" extra
    invalid_env_case "Invalid command argument" env-menu :
    invalid_env_case "Unknown Environment command" env-menu forged-env-action
    _env_dispatch : || return 91
    [[ ! -e "$HOME/timing" ]] || (( ++failures ))
    invalid_env_case "--list accepts no additional arguments" env-list --list extra
    invalid_env_case "--help accepts no additional arguments" env-list -h extra
    invalid_env_case "Invalid env-list argument" env-list "" extra
    invalid_env_case "--copy requires exactly one valid shell variable name" env-menu env-list --copy ""
    invalid_env_case "--copy requires exactly one valid shell variable name" env-menu env-list --copy bad-name
    invalid_env_case "--help accepts no additional arguments" env-path --help --list
    invalid_env_case "--help accepts no additional arguments" env-path --list --help
    invalid_env_case "--help accepts no additional arguments" env-menu env-path --dedupe --help
    [[ ! -e "$HOME/unexpected" ]] || (( ++failures ))
    (( failures == 0 ))
  '
  [ "$status" -eq 0 ]
}

@test "env contract: direct and nested PATH completion share the mode exclusions" {
  local service
  for service in env-path env-menu; do
    export ENV_COMPLETION_SERVICE="$service"
    run run_zsh '
      service="$ENV_COMPLETION_SERVICE"
      words=(env-path)
      _arguments() {
        if [[ "$1" == -C ]]; then
          state=args
          return 0
        fi
        print -rl -- "$@"
      }
      source "$TEST_SUITE_ROOT/completions/_env-menu"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"(--dedupe --dry-run --yes)--list["* ]]
    [[ "$output" == *"(--list)--dedupe["* ]]
    [[ "$output" == *"(--list)--dry-run["* ]]
    [[ "$output" == *"(--list)--yes["* ]]
  done
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$ENV_CONTRACT" | sort
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

@test "env contract: fixture freezes three unique canonical commands" {
  local count=0
  local command_name module_name risk capability extra
  while IFS=$'\t' read -r \
    command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))
    [[ "$command_name" =~ ^env(-[a-z]+)+$ ]]
    [[ "$module_name" =~ ^env-[a-z]+\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive)$ ]]
    [[ "$capability" =~ ^[a-z]+(-[a-z]+)*$ ]]
    [ -z "$extra" ]
    [ -f "$TEST_SUITE_ROOT/functions/env/$module_name" ]
  done < "$ENV_CONTRACT"
  [ "$count" -eq 3 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "env contract: every canonical command is a real public function" {
  local command_list
  command_list=$(contract_commands | tr '\n' ' ')
  run run_zsh "
    local command_name
    for command_name in $command_list; do
      typeset -f \"\$command_name\" >/dev/null || {
        print -u2 -r -- \"Missing public function: \$command_name\"
        return 1
      }
    done
  "
  [ "$status" -eq 0 ]
}

@test "env contract: declared modules own every canonical function" {
  local command_name module_name risk capability
  while IFS=$'\t' read -r \
    command_name module_name risk capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/env/$module_name"
  done < "$ENV_CONTRACT"
}

@test "env contract: menu rows equal the frozen public surface" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '
    env-menu >/dev/null 2>&1
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE" | sort
  '
  [ "$status" -eq 0 ]
  assert_contract_matches "$output"
}

@test "env contract: dispatcher forwards arguments unchanged" {
  run run_zsh '
    env-list() {
      print -r -- "list:$#:${(j.:.)@}"
    }
    env-path() {
      print -r -- "path:$#:${(j.:.)@}"
    }
    env-dotenv() {
      print -r -- "dotenv:$#:${(j.:.)@}"
    }
    _env_dispatch env-list --copy "API TOKEN"
    _env_dispatch env-path --dedupe --dry-run --yes
    _env_dispatch env-dotenv "my file.env" --example "" --json
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"list:2:--copy:API TOKEN"* ]]
  [[ "$output" == *"path:3:--dedupe:--dry-run:--yes"* ]]
  [[ "$output" == *"dotenv:4:my file.env:--example::--json"* ]]
}

@test "env contract: every command owns direct help" {
  local command_name
  while IFS= read -r command_name; do
    run run_zsh "$command_name --help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  done < <(contract_commands)
}

@test "env contract: completion binds menu and every direct command" {
  local compdef_line
  compdef_line=$(head -n 1 "$TEST_SUITE_ROOT/completions/_env-menu")
  local command_name
  while IFS= read -r command_name; do
    [[ " $compdef_line " == *" $command_name "* ]]
  done < <(contract_commands)
  [[ " $compdef_line " == *" env-menu "* ]]
  grep -q 'case "$service"' "$TEST_SUITE_ROOT/completions/_env-menu"
}

@test "env contract: every direct command has a cold lazy stub" {
  local command_name
  while IFS= read -r command_name; do
    grep -Eq "^[[:space:]]+${command_name}[[:space:]]+env-menu\\.zsh$" \
      "$TEST_SUITE_ROOT/functions.zsh"
  done < <(contract_commands)
}

@test "env contract: eager source has no automatic chpwd mutation hook" {
  run run_zsh '
    typeset -f _env_chpwd_autoload_hook >/dev/null && return 1
    (( ! ${+chpwd_functions} )) \
      || (( ${chpwd_functions[(Ie)_env_chpwd_autoload_hook]} == 0 ))
  '
  [ "$status" -eq 0 ]
  ! grep -q 'add-zsh-hook chpwd' \
    "$TEST_SUITE_ROOT/functions/env-menu.zsh" || false
}

@test "env contract: documented stdout modes stay explicit" {
  grep -q 'env-list --list' "$TEST_SUITE_ROOT/docs/env-menu.md"
  grep -q 'env-path --list' "$TEST_SUITE_ROOT/docs/env-menu.md"
  grep -q 'env-dotenv --json' "$TEST_SUITE_ROOT/docs/env-menu.md"
  ! grep -R -Eq '(^|[[:space:]])(eval|source)[[:space:]].*(env|profile)' \
    "$TEST_SUITE_ROOT/functions/env" || false
}
