#!/usr/bin/env bats

setup() {
  load test_helper
  APP_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/app-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$APP_CONTRACT" | sort
}

@test "app contract: fixture freezes two unique canonical commands" {
  local count=0
  local command_name module_name risk capability extra

  while IFS=$'\t' read -r \
    command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))
    [ "$module_name" = "app-tasks.zsh" ]
    [[ "$risk" = "read-only" || "$risk" = "project-code" ]]
    [ -n "$capability" ]
    [ -z "$extra" ]
    [ -f "$TEST_SUITE_ROOT/functions/app/$module_name" ]
  done < "$APP_CONTRACT"

  [ "$count" -eq 2 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "app contract: the declared module owns every canonical function" {
  local command_name
  while read -r command_name; do
    grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/app/app-tasks.zsh"
  done < <(contract_commands)

  run run_zsh '
    typeset -f app-list >/dev/null
    typeset -f app-run >/dev/null
  '
  [ "$status" -eq 0 ]
}

@test "app contract: standalone loading is silent idempotent and probe-free" {
  run zsh -f -c '
    fzf() { print -r -- fzf >>"$2/probes"; }
    git() { print -r -- git >>"$2/probes"; }
    python3() { print -r -- python3 >>"$2/probes"; }
    sha256sum() { print -r -- sha256sum >>"$2/probes"; }
    source "$1/functions/app-menu.zsh" >"$2/stdout" 2>"$2/stderr" || exit
    source "$1/functions/app-menu.zsh" >>"$2/stdout" 2>>"$2/stderr" || exit
    [[ -n "${_APP_MENU_SOURCED:-}" ]]
    [[ ! -s "$2/stdout" && ! -s "$2/stderr" && ! -e "$2/probes" ]]
    typeset -f app-menu app-list app-run >/dev/null
    ! typeset -f _timed >/dev/null
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
}

@test "app contract: a missing mandatory module leaves no false menu sentinel" {
  local broken_root="$TEST_TEMP_DIR/broken/functions"
  mkdir -p "$broken_root/app"
  cp "$TEST_SUITE_ROOT/functions/app-menu.zsh" "$broken_root/app-menu.zsh"
  cp "$TEST_SUITE_ROOT/functions/app-common.zsh" "$broken_root/app-common.zsh"

  run zsh -f -c '
    source "$1/app-menu.zsh"
    local load_rc=$?
    (( load_rc != 0 ))
    [[ -z "${_APP_MENU_SOURCED:-}" ]]
    ! typeset -f _app_menu_source_module >/dev/null
    [[ -z "${_app_menu_loader_dir:-}" ]]
  ' _ "$broken_root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed to load app-tasks.zsh"* ]]
}

@test "app contract: dispatcher forwards arguments through fixed arms" {
  run run_zsh '
    app-list() { print -r -- "list:$#"; return 17; }
    _app_dispatch app-list
  '
  [ "$status" -eq 17 ]
  [ "$output" = "list:0" ]

  run run_zsh '
    app-run() { print -r -- "run:$*"; return 19; }
    _app_dispatch app-run --backend just --task build
  '
  [ "$status" -eq 19 ]
  [ "$output" = "run:--backend just --task build" ]

  run run_zsh '_app_dispatch arbitrary-command'
  [ "$status" -eq 2 ]
}

@test "app contract: help and completion contain the frozen surface" {
  run run_zsh 'app-menu --help'
  [ "$status" -eq 0 ]
  local command_name
  while read -r command_name; do
    [[ "$output" == *"$command_name"* ]]
  done < <(contract_commands)

  local bindings
  bindings=$(sed -n '1s/^#compdef[[:space:]]*//p' \
    "$TEST_SUITE_ROOT/completions/_app-menu" \
    | tr ' ' '\n' \
    | grep -v '^app-menu$' \
    | sort)
  [ "$bindings" = "$(contract_commands)" ]
}

@test "app contract: dynamic browser rows carry only app-run plus an index" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    app-menu
    awk -F "|" \
      '\''NF { print $2 "\t" $4 }'\'' "$MOCK_FZF_INPUT_FILE"
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'app-run\t1' ]
}

@test "app contract: direct routing preserves timing label and status" {
  run run_zsh '
    _timed() {
      print -r -- "label:$1"
      shift
      "$@"
    }
    app-list() { return 23; }
    app-menu app-list
  '
  [ "$status" -eq 23 ]
  [ "$output" = "label:app:app-list" ]
}
