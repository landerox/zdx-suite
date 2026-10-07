#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "env: loader and canonical help source without probing state" {
  run run_zsh '
    typeset -f env-menu >/dev/null
    env-menu --help
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Canonical subcommands:"* ]]
  [[ "$output" == *"env-list, env-path, env-dotenv"* ]]
}

@test "env: PATH inspection is read-only and dedupe is explicit" {
  run run_zsh '
    export PATH="/usr/local/bin:/usr/bin:/usr/local/bin::"
    local before="$PATH"
    env-path >/dev/null 2>&1
    [[ "$PATH" == "$before" ]] || return 1
    env-path --dedupe --dry-run >/dev/null 2>&1
    [[ "$PATH" == "$before" ]] || return 1
    env-path --dedupe --yes >/dev/null 2>&1
    print -r -- "$PATH"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/local/bin:/usr/bin:" ]
}

@test "env: every value classification withholds the raw value" {
  run run_zsh '
    print -r -- "$(_env_value_classification MY_API_KEY)"
    print -r -- "$(_env_value_classification DB_PASSWORD)"
    print -r -- "$(_env_value_classification NORMAL_VAR)"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "********" ]
  [ "${lines[1]}" = "********" ]
  [ "${lines[2]}" = "<hidden>" ]
}
