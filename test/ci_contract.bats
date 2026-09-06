#!/usr/bin/env bats

setup() {
  load test_helper
  CI_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/ci-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$CI_CONTRACT" | sort
}

@test "ci contract: fixture freezes eight unique public commands" {
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
    [ -f "$TEST_SUITE_ROOT/functions/ci/$module_name" ]
    grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/ci/$module_name"
  done < "$CI_CONTRACT"

  [ "$count" -eq 8 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "ci contract: menu, help, dispatcher, and completion agree" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    ci-menu >/dev/null 2>&1
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE" | sort
  '
  [ "$status" -eq 0 ]
  [ "$output" = "$(contract_commands)" ]

  while IFS=$'\t' read -r \
    command_name _module_name _risk _capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue

    run run_zsh "
      ci-menu --help >/dev/null 2>&1
      functions[$command_name]='print -r -- \"\$0\"; return 17'
      _ci_dispatch $command_name first '' --last
    "
    [ "$status" -eq 17 ]
    [ "$output" = "$command_name" ]

    run run_zsh "ci-menu --help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$command_name"* ]]
  done < "$CI_CONTRACT"

  local bindings
  bindings=$(sed -n '1s/^#compdef[[:space:]]*//p' \
    "$TEST_SUITE_ROOT/completions/_ci-menu" \
    | tr ' ' '\n' \
    | grep -v '^ci-menu$' \
    | sort)
  [ "$bindings" = "$(contract_commands)" ]
}

@test "ci contract: top-level invalid input fails with status 2 before probes" {
  run run_zsh 'ci-menu --unknown'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option"* ]]

  run run_zsh 'ci-menu unknown-command'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command"* ]]
}

@test "ci contract: every public command is registered for lazy loading" {
  while IFS=$'\t' read -r \
    command_name _module_name _risk _capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    grep -Eq "^[[:space:]]+${command_name}[[:space:]]+ci-menu[.]zsh$" \
      "$TEST_SUITE_ROOT/functions.zsh"
  done < "$CI_CONTRACT"
}

@test "ci contract: help is stderr-only and names safety flags" {
  run run_zsh '
    ci-menu --help >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q -- "--dry-run" "$HOME/stderr"
    grep -q -- "--yes" "$HOME/stderr"
    grep -q "ci-clean-notifications" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "ci contract: loading is exact, silent, idempotent, and standalone" {
  run zsh -f -c '
    source "$1/functions/ci-menu.zsh" >"$2/stdout" 2>"$2/stderr" || exit
    source "$1/functions/ci-menu.zsh" >>"$2/stdout" 2>>"$2/stderr" || exit
    [[ -n "${_CI_MENU_SOURCED:-}" ]]
    [[ ! -s "$2/stdout" && ! -s "$2/stderr" ]]
    typeset -f ci-menu ci-status ci-run ci-clean-actions >/dev/null
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
}

@test "ci contract: missing mandatory module leaves no false menu sentinel" {
  local broken_root="$TEST_TEMP_DIR/broken/functions"
  mkdir -p "$broken_root/ci"
  cp "$TEST_SUITE_ROOT/functions/ci-menu.zsh" "$broken_root/ci-menu.zsh"
  cp "$TEST_SUITE_ROOT/functions/ci-common.zsh" "$broken_root/ci-common.zsh"
  cp "$TEST_SUITE_ROOT/functions/ci/ci-actions.zsh" \
    "$broken_root/ci/ci-actions.zsh"

  run zsh -f -c '
    source "$1/ci-menu.zsh"
    loader_rc=$?
    (( loader_rc != 0 )) || exit 1
    [[ -z "${_CI_MENU_SOURCED:-}" ]]
  ' _ "$broken_root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed to load ci/ci-clean.zsh"* ]]
}

@test "ci contract: menu cancellation succeeds and removes private capture" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    ci-menu
    local menu_rc=$?
    (( menu_rc == 0 )) || return 1
    local -a leftovers=("$TMPDIR"/zdx-ci-fzf.*(N))
    (( ${#leftovers} == 0 ))
  '
  [ "$status" -eq 0 ]
}

@test "ci contract: forged menu rows are refused" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="Injected|ci-clean-actions|forged"

  run run_zsh 'ci-menu'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the menu snapshot"* ]]
}

@test "ci contract: an exact menu row dispatches without arithmetic parsing" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="  Browse Workflow Runs|ci-status|Browse recent runs and choose one to inspect its status and details."

  run run_zsh '
    ci-menu --help >/dev/null 2>&1 || return
    ci-status() {
      print -r -- "exact-ci-route"
    }
    ci-menu
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"exact-ci-route"* ]]
  [[ "$output" != *"invalid subscript"* ]]
}

@test "ci contract: multiline single-select output is an error, not cancellation" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE=$'  Browse Workflow Runs|ci-status|Browse recent runs and choose one to inspect its status and details.\n  Trigger Workflow Run|ci-run|Choose a branch and run a GitHub Actions workflow with its configured permissions.'

  run run_zsh 'ci-menu'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the menu snapshot"* ]]
}

@test "ci contract: completion declares command-specific direct bindings" {
  local completion="$TEST_SUITE_ROOT/completions/_ci-menu"
  grep -q '^#compdef ci-menu ci-status ci-run ' "$completion"
  grep -q -- '--workflow' "$completion"
  grep -q -- '\*--run' "$completion"
  grep -q -- '\*--deployment' "$completion"
  grep -q -- '\*--release' "$completion"
  grep -q -- '\*--thread' "$completion"
}
