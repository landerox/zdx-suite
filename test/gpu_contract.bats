#!/usr/bin/env bats

setup() {
  load test_helper
  GPU_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/gpu-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$GPU_CONTRACT" | sort
}

@test "gpu contract: fixture freezes the single canonical command" {
  local count=0
  local command_name module_name risk capability extra

  while IFS=$'\t' read -r \
    command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))

    [ "$command_name" = "gpu-visualizer" ]
    [ "$module_name" = "gpu-visualizer.zsh" ]
    [ "$risk" = "read-only" ]
    [ "$capability" = "nvidia-or-explicit-simulation" ]
    [ -z "$extra" ]
    [ -f "$TEST_SUITE_ROOT/functions/gpu/$module_name" ]
  done < "$GPU_CONTRACT"

  [ "$count" -eq 1 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "gpu contract: the declared module owns and loads the public command" {
  grep -Eq '^gpu-visualizer\(\)[[:space:]]*\{' \
    "$TEST_SUITE_ROOT/functions/gpu/gpu-visualizer.zsh"

  run run_zsh 'typeset -f gpu-visualizer >/dev/null'
  [ "$status" -eq 0 ]
}

@test "gpu contract: menu, dispatcher, help, and completion agree" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    gpu-menu >/dev/null 2>&1
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE" | sort
  '
  [ "$status" -eq 0 ]
  [ "$output" = "$(contract_commands)" ]

  run run_zsh '
    functions[gpu-visualizer]='\''print -r -- "$0"; return 17'\''
    _gpu_dispatch gpu-visualizer
  '
  [ "$status" -eq 17 ]
  [ "$output" = "gpu-visualizer" ]

  run run_zsh 'gpu-menu --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"gpu-visualizer"* ]]

  local bindings
  bindings=$(sed -n '1s/^#compdef[[:space:]]*//p' \
    "$TEST_SUITE_ROOT/completions/_gpu-menu" \
    | tr ' ' '\n' \
    | grep -v '^gpu-menu$' \
    | sort)
  [ "$bindings" = "$(contract_commands)" ]
}

@test "gpu contract: probe timeout and precondition statuses are preserved" {
  run run_zsh '
    _gpu_query_hardware() { return 124; }
    gpu-visualizer --once
  '
  [ "$status" -eq 124 ]

  run run_zsh '
    _gpu_query_hardware() { return 125; }
    gpu-visualizer --once
  '
  [ "$status" -eq 125 ]
}

@test "gpu contract: menu records reject every control character" {
  run run_zsh '_gpu_menu_entry "bad'$'\t''label" gpu-visualizer description'
  [ "$status" -eq 2 ]

  run run_zsh '_gpu_menu_section "bad'$'\a''title" description'
  [ "$status" -eq 2 ]
}
