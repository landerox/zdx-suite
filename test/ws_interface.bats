#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "ws interface: help is stderr-only and performs no probes" {
  run run_zsh '
    _ws_list_workspaces() {
      print -r -- unexpected >"$HOME/ws-probe"
      return 99
    }
    ws-menu --help >"$HOME/help.stdout" 2>"$HOME/help.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/help.stdout" ]
  [ ! -e "$HOME/ws-probe" ]
  grep -q "Usage:" "$HOME/help.stderr"
}

@test "ws interface: unknown options and commands return status 2" {
  run run_zsh '
    ws-menu --unknown >"$HOME/option.stdout" 2>"$HOME/option.stderr"
    local option_rc=$?
    ws-menu ws-unknown >"$HOME/command.stdout" 2>"$HOME/command.stderr"
    local command_rc=$?
    print -r -- "$option_rc:$command_rc"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "2:2" ]
  [ ! -s "$HOME/option.stdout" ]
  [ ! -s "$HOME/command.stdout" ]
  grep -q "Unknown option" "$HOME/option.stderr"
  grep -q "Unknown workspace command" "$HOME/command.stderr"
}

@test "ws interface: ws-remove parses before checking dependencies" {
  run run_zsh '
    PATH="$HOME/no-commands"
    ws-menu ws-remove --help \
      >"$HOME/remove-help.stdout" 2>"$HOME/remove-help.stderr"
    local help_rc=$?
    ws-menu ws-remove --definitely-invalid \
      >"$HOME/remove-invalid.stdout" 2>"$HOME/remove-invalid.stderr"
    local invalid_rc=$?
    print -r -- "$help_rc:$invalid_rc"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "0:2" ]
  [ ! -s "$HOME/remove-help.stdout" ]
  [ ! -s "$HOME/remove-invalid.stdout" ]
  grep -q "Usage: ws-remove" "$HOME/remove-help.stderr"
  grep -q "Unknown option" "$HOME/remove-invalid.stderr"
  ! grep -q "Missing.*git" "$HOME/remove-help.stderr"
  ! grep -q "Missing.*git" "$HOME/remove-invalid.stderr"
}

@test "ws interface: menu rows are plain validated three-field records" {
  run run_zsh '
    _ws_menu_section "Inspect" "Read-only actions."
    _ws_menu_entry "List" "ws-list" "List workspaces."

    _ws_menu_section "bad|title" "description" >/dev/null 2>&1
    local section_rc=$?
    _ws_menu_entry "label" "ws-list" $'\''bad\ndescription'\'' \
      >/dev/null 2>&1
    local entry_rc=$?
    print -u2 -r -- "invalid:$section_rc:$entry_rc"
  '

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "── Inspect ──|:|Read-only actions." ]
  [ "${lines[1]}" = "  List|ws-list|List workspaces." ]
  [[ "$output" == *"invalid:2:2"* ]]
  [[ "$output" != *$'\033'* ]]
}

@test "ws interface: fzf receives the canonical command-menu contract" {
  run run_zsh '
    fzf() {
      local argument
      for argument in "$@"; do
        print -r -- "$argument" >>"$HOME/ws-fzf.args"
      done
      command cat >"$HOME/ws-fzf.input"
      return 130
    }

    ws-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/menu.stdout" ]
  grep -Fxq -- "--delimiter=[|]" "$HOME/ws-fzf.args"
  grep -Fxq -- "--with-nth=1" "$HOME/ws-fzf.args"
  grep -Fxq -- "--prompt=ws > " "$HOME/ws-fzf.args"
  grep -Fxq -- "--preview-window=down:4:wrap" "$HOME/ws-fzf.args"
  grep -q "Type to filter | Enter run | Esc cancel | Ctrl-/ details" \
    "$HOME/ws-fzf.args"
  awk -F "|" "NF != 3 { exit 1 }" "$HOME/ws-fzf.input"
}

@test "ws interface: fzf cancellation is zero and a real fzf failure is nonzero" {
  run run_zsh '
    fzf() {
      command cat >/dev/null
      return 130
    }
    ws-menu
  '
  [ "$status" -eq 0 ]

  run run_zsh '
    fzf() {
      command cat >/dev/null
      return 42
    }
    ws-menu
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unable to open the interactive Workspace menu"* ]]
}

@test "ws interface: foreground fzf capture preserves output status and privacy" {
  run run_zsh '
    local temp_root="$HOME/ws-fzf-temp"
    command mkdir -m 700 -- "$temp_root"
    TMPDIR="$temp_root"

    fzf() {
      zmodload zsh/stat || return 96
      local -A dir_state=() file_state=()
      zstat -LH dir_state -- "$capture_dir" || return 97
      zstat -LH file_state -- "$capture_file" || return 98
      (( dir_state[uid] == EUID \
        && (dir_state[mode] & 8#77) == 0 \
        && file_state[uid] == EUID \
        && file_state[nlink] == 1 \
        && (file_state[mode] & 8#77) == 0 )) || return 99

      local argument=""
      for argument in "$@"; do
        print -r -- "$argument" >>"$HOME/ws-helper-fzf.args"
      done
      command cat >"$HOME/ws-helper-fzf.input"
      if (( WS_HELPER_FZF_RC == 0 )); then
        printf "first\\trow\\nsecond\\trow\\n"
      fi
      return $WS_HELPER_FZF_RC
    }

    local selection=""
    local -i helper_rc=0
    local -i WS_HELPER_FZF_RC=0
    _ws_fzf_capture -m --delimiter=$'\''\t'\'' --with-nth=1,2 \
      < <(printf "first\\trow\\nsecond\\trow\\n") || helper_rc=$?
    selection="$REPLY"
    (( helper_rc == 0 )) || return 10
    [[ "$selection" == $'\''first\trow\nsecond\trow'\'' ]] || return 11
    grep -Fxq -- "-m" "$HOME/ws-helper-fzf.args" || return 12
    grep -Fxq -- $'\''--delimiter=\t'\'' \
      "$HOME/ws-helper-fzf.args" || return 13

    WS_HELPER_FZF_RC=130
    helper_rc=0
    _ws_fzf_capture < <(print -r -- ignored) || helper_rc=$?
    (( helper_rc == 130 )) || return 20
    [[ -z "$REPLY" ]] || return 21

    WS_HELPER_FZF_RC=42
    helper_rc=0
    _ws_fzf_capture < <(print -r -- ignored) || helper_rc=$?
    (( helper_rc == 42 )) || return 30
    [[ -z "$REPLY" ]] || return 31

    local -a leftovers=("$temp_root"/zdx-ws-fzf.*(DN))
    (( ${#leftovers[@]} == 0 )) || return 40
  '

  [ "$status" -eq 0 ]
}

@test "ws interface: standalone sourcing uses one exact module root" {
  run zsh -f -c '
    export HOME="$1"
    export ZSH_CUSTOM="$2"
    export WS_BASE_DIR="$HOME/workspaces"
    source "$3/functions/ws-menu.zsh" || exit 1
    typeset -f ws-menu >/dev/null || exit 2
    typeset -f ws-remove >/dev/null || exit 3
    print -r -- OK
  ' _ "$HOME" "$TEST_SUITE_ROOT" "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]

  local sentinel_line entrypoint_line
  sentinel_line=$(grep -n '^typeset -g _WS_MENU_SOURCED=1$' \
    "$TEST_SUITE_ROOT/functions/ws-menu.zsh")
  sentinel_line="${sentinel_line%%:*}"
  entrypoint_line=$(grep -n '^if \[\[ "\${zsh_eval_context\[-1\]}" == "toplevel" \]\]; then$' \
    "$TEST_SUITE_ROOT/functions/ws-menu.zsh")
  entrypoint_line="${entrypoint_line%%:*}"
  [ "$sentinel_line" -gt 260 ]
  [ "$sentinel_line" -lt "$entrypoint_line" ]
}

@test "ws interface: lazy and eager loading expose the same public surface" {
  run zsh -f -c '
    export HOME="$1"
    export ZSH_CUSTOM="$2"
    export ZDX_LAZY_LOAD="$3"
    source "$4/functions.zsh" || exit 1
    local command_name
    for command_name in ws-menu ws-create ws-list ws-remove; do
      typeset -f "$command_name" >/dev/null || exit 2
    done
  ' _ "$HOME" "$TEST_SUITE_ROOT" 1 "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]

  run zsh -f -c '
    export HOME="$1"
    export ZSH_CUSTOM="$2"
    export ZDX_EAGER_LOAD=1
    source "$3/functions.zsh" || exit 1
    local command_name
    for command_name in ws-menu ws-create ws-list ws-remove; do
      typeset -f "$command_name" >/dev/null || exit 2
    done
  ' _ "$HOME" "$TEST_SUITE_ROOT" "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "ws interface: every public command parses help before any probe" {
  local -a commands=(
    ws-auth ws-create ws-list ws-info ws-doctor ws-clone ws-clone-multi
    ws-sync ws-repos ws-migrate ws-show-key ws-rotate-key ws-test
    ws-autoclean ws-remove
  )
  local command_name
  for command_name in "${commands[@]}"; do
    run run_zsh "
      source \"\$ZSH_CUSTOM/functions/ws-menu.zsh\" || return 98
      _tk_check_deps() { print -r -- unexpected-dependency-probe; return 97 }
      _ws_check_deps() { print -r -- unexpected-dependency-probe; return 97 }
      _ws_validate_base_dir() { print -r -- unexpected-base-probe; return 97 }
      $command_name --help
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: $command_name"* ]]
    [[ "$output" != *"unexpected-dependency-probe"* ]]
    [[ "$output" != *"unexpected-base-probe"* ]]
  done
}

@test "ws interface: unknown options and unexpected operands fail closed" {
  local -a commands=(
    ws-auth ws-create ws-list ws-info ws-doctor ws-clone ws-clone-multi
    ws-sync ws-repos ws-migrate ws-show-key ws-rotate-key ws-test
    ws-autoclean ws-remove
  )
  local command_name
  for command_name in "${commands[@]}"; do
    run run_zsh "ws-menu $command_name --definitely-unknown-option"
    [ "$status" -eq 2 ]
  done

  local -a no_operand_commands=(
    ws-auth ws-create ws-list ws-info ws-doctor ws-sync ws-repos
    ws-migrate ws-show-key ws-rotate-key ws-test ws-autoclean
  )
  for command_name in "${no_operand_commands[@]}"; do
    run run_zsh "ws-menu $command_name unexpected-operand"
    [ "$status" -eq 2 ]
  done

  run run_zsh "ws-menu ws-clone owner/one owner/two"
  [ "$status" -eq 2 ]
}
