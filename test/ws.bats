#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  mkdir -p "$HOME/workspaces/github/personal/alpha/.git"
}

teardown() {
  cleanup_sandbox
}

@test "ws: standalone sourcing is silent, idempotent, and sets the sentinel last" {
  run zsh -f -c '
    source "$1/functions/ws-menu.zsh" || exit
    first_definition="${functions[ws-menu]}"
    source "$1/functions/ws-menu.zsh" || exit
    [[ -n "${_WS_MENU_SOURCED:-}" && -n "${_WS_COMMON_SOURCED:-}" \
      && -n "${_WS_JUMP_SOURCED:-}" && -n "${_WS_STATUS_SOURCED:-}" \
      && -n "${_WS_CLONE_SOURCED:-}" \
      && "${functions[ws-menu]}" == "$first_definition" ]]
    (( ! ${+functions[_ws_menu_source_module]} )) || exit 3
    (( ! ${+_ws_menu_loader_dir} )) || exit 4
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  local file
  for file in functions/ws-menu.zsh functions/ws-common.zsh \
    functions/ws/ws-jump.zsh functions/ws/ws-status.zsh \
    functions/ws/ws-clone.zsh; do
    [[ "$(awk 'NF { line=$0 } END { print line }' "$TEST_SUITE_ROOT/$file")" \
      == "typeset -g _WS_"*"_SOURCED=1" ]]
  done
}

@test "ws: sourcing performs no scan, prompt, or external command" {
  cat > "$TEST_MOCK_BIN/find" <<'EOF'
#!/usr/bin/env bash
printf 'find ran\n' >> "$TEST_TEMP_DIR/external.log"
exit 97
EOF
  cp "$TEST_MOCK_BIN/find" "$TEST_MOCK_BIN/fd"
  cp "$TEST_MOCK_BIN/find" "$TEST_MOCK_BIN/git"
  chmod +x "$TEST_MOCK_BIN/find" "$TEST_MOCK_BIN/fd" "$TEST_MOCK_BIN/git"
  run zsh -f -c '
    export PATH="$2:$PATH"
    source "$1/functions/ws-menu.zsh"
  ' _ "$TEST_SUITE_ROOT" "$TEST_MOCK_BIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TEST_TEMP_DIR/external.log" ]
}

@test "ws: a missing module fails with its name and no loaded sentinel" {
  local broken_root="$TEST_TEMP_DIR/broken"
  mkdir -p "$broken_root/ws"
  cp "$TEST_SUITE_ROOT/functions/ws-menu.zsh" \
    "$TEST_SUITE_ROOT/functions/ws-common.zsh" "$broken_root/"
  cp "$TEST_SUITE_ROOT/functions/ws/ws-jump.zsh" "$broken_root/ws/"
  run zsh -f -c '
    source "$1/ws-menu.zsh"
    (( $? != 0 )) || exit 1
    [[ -z "${_WS_MENU_SOURCED:-}" ]] || exit 2
    (( ! ${+functions[_ws_menu_source_module]} ))
  ' _ "$broken_root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ws-menu.zsh: failed to load ws-status.zsh"* ]]
}

@test "ws: help is written to stderr only for the menu and every command" {
  local command_name
  for command_name in ws-menu ws-status ws-jump ws-clone; do
    run zsh -f -c '
      source "$1/functions/ws-menu.zsh" || exit
      "$3" --help >"$2/help.stdout" 2>"$2/help.stderr" || exit
      [[ ! -s "$2/help.stdout" && -s "$2/help.stderr" ]]
    ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR" "$command_name"
    [ "$status" -eq 0 ]
    grep -q '^Usage' "$TEST_TEMP_DIR/help.stderr"
  done
  run zsh -f -c '
    source "$1/functions/ws-menu.zsh" || exit
    ws-menu --help 2>&1
  ' _ "$TEST_SUITE_ROOT"
  [[ "$output" == *"ws-status, ws-jump, ws-clone"* ]]
}

@test "ws: invalid grammar returns status 2 before any probe" {
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
printf 'git ran\n' >> "$TEST_TEMP_DIR/git.log"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/git"
  run run_zsh '
    local -a cases=(
      "ws-menu --bogus"
      "ws-menu ws-unknown"
      "ws-menu --help extra"
      "ws-status --bogus"
      "ws-status --help --json"
      "ws-jump --bogus"
      "ws-jump one two"
      "ws-clone --bogus"
      "ws-clone --platform"
      "ws-clone --identity ../x https://github.com/a/b"
      "ws-clone https://github.com/a/b https://github.com/c/d"
    )
    local test_case=""
    for test_case in "${cases[@]}"; do
      ${=test_case} >/dev/null 2>&1
      (( $? == 2 )) || { print -r -- "not 2: $test_case"; return 1; }
    done
  '
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TEMP_DIR/git.log" ]
}

@test "ws: dispatcher forwards arguments unchanged and owns only fixed arms" {
  run run_zsh '
    ws-clone() { print -r -- "clone:$#:${(j.|.)@}"; }
    ws-jump() { print -r -- "jump:$#:${(j.|.)@}"; }
    ws-status() { print -r -- "status:$#:${(j.|.)@}"; }
    _ws_dispatch ws-clone "$(print -r -- "\$(touch $HOME/evaluated)")" "two words"
    _ws_dispatch ws-jump "semi; touch $HOME/split"
    _ws_dispatch ws-status --json --fetch
    _ws_dispatch : || return 1
    _ws_dispatch _ws_dispatch >/dev/null 2>&1
    (( $? == 2 ))
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'clone:2:$(touch '*'/evaluated)|two words'* ]]
  [[ "$output" == *"jump:1:semi; touch "*"/split"* ]]
  [[ "$output" == *"status:2:--json|--fetch"* ]]
  [ ! -e "$HOME/evaluated" ]
  [ ! -e "$HOME/split" ]
}

@test "ws: menu cancellation returns 0 with empty stdout and a context header" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '
    typeset -gA ZDX_GIT_IDENTITIES=(personal "Name|Jane Doe;Email|jane@example.com")
    ws-menu >"$HOME/menu.stdout" || return
    [[ ! -s "$HOME/menu.stdout" ]]
  '
  [ "$status" -eq 0 ]
  grep -Fq -- "--prompt=ws\\ \\>\\ " "$MOCK_FZF_ARGS_FILE"
  grep -Fq 'Workspace: ~/workspaces\nRoot: present | Discovery: ' \
    "$MOCK_FZF_ARGS_FILE"
  grep -Fq '| Profiles: 1\nType to filter | Enter run | Esc cancel | Ctrl-/ details' \
    "$MOCK_FZF_ARGS_FILE"
  local -a leftovers=("$TMPDIR"/zdx-ws-*)
  [ ! -e "${leftovers[0]}" ]
}

@test "ws: a selected menu row dispatches its command in the current shell" {
  export MOCK_FZF_MODE="match"
  export MOCK_FZF_MATCH="|ws-jump|"
  run run_zsh '
    ws-jump() {
      builtin cd -- "$HOME/workspaces" || return
      print -r -- "jump:$#"
    }
    ws-menu || return
    print -r -- "pwd:$PWD"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"jump:0"* ]]
  [[ "$output" == *"pwd:$HOME/workspaces"* ]]
}

@test "ws: forged, multi-line, and failed menu selections are refused" {
  run run_zsh '
    ws-status() { print -r -- UNEXPECTED_DISPATCH; }
    _ws_fzf_capture() { REPLY="  Forged|ws-status|not from the model"; return 0; }
    ws-menu
    (( $? == 1 )) || return 1
    _ws_fzf_capture() { REPLY="  Show Workspace Status|ws-status|x"$'"'"'\n'"'"'"more"; return 0; }
    ws-menu
    (( $? == 1 )) || return 2
    _ws_fzf_capture() { REPLY=""; return 2; }
    ws-menu
    (( $? == 1 )) || return 3
    _ws_fzf_capture() { REPLY=""; return 130; }
    ws-menu
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNEXPECTED_DISPATCH"* ]]
  [[ "$output" == *"not in the menu snapshot"* ]]
}

@test "ws: menu rows mark missing Git in the canonical form" {
  run run_zsh '
    _ws_command_path() {
      [[ "$1" == git ]] && return 1
      REPLY="/usr/bin/$1"
    }
    _ws_menu_rows
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"  ○ Show Workspace Status (missing: git)|ws-status|"* ]]
  [[ "$output" == *"  ○ Clone Repository (missing: git)|ws-clone|"* ]]
  [[ "$output" == *"  Jump to Repository|ws-jump|"* ]]
}

@test "ws: row helpers reject delimiters and control characters" {
  run run_zsh '
    _ws_menu_entry "Bad|Label" ws-status "x" >/dev/null 2>&1
    (( $? == 2 )) || return 1
    _ws_menu_section "Bad"$'"'"'\n'"'"'"Title" "x" >/dev/null 2>&1
    (( $? == 2 ))
  '
  [ "$status" -eq 0 ]
}

@test "ws: zdx routes ws to the suite and reserves the name for plugins" {
  run zsh -f -c '
    source "$1/functions/zdx-menu.zsh" || exit
    ws-menu() { print -r -- "ws-menu:$#:${(j.|.)@}"; }
    zdx ws ws-status --json || exit
    _zdx_wrapper_name_reserved ws || exit 1
    typeset -ga ZDX_LOADED_PLUGINS=(ws)
    _zdx_dispatch_plugin ws >/dev/null 2>&1
    (( $? == 2 ))
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ws-menu:2:ws-status|--json"* ]]
}

@test "ws: the master catalog lists the suite first in the Projects group" {
  run zsh -f -c '
    source "$1/functions/zdx-menu.zsh" || exit
    _zdx_menu_model
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "── Projects ──|:|Work with repositories and maintain projects." ]
  [[ "${lines[1]}" == "  Navigate Workspaces (ws)|ws|"* ]]
}

@test "ws: zdx-doctor reports fd, including fdfind, as an optional capability" {
  mkdir -p "$TEST_TEMP_DIR/fd-bin" "$TEST_TEMP_DIR/empty-bin"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_TEMP_DIR/fd-bin/fdfind"
  chmod +x "$TEST_TEMP_DIR/fd-bin/fdfind"
  run zsh -f -c '
    source "$1/functions/zdx-doctor.zsh" || exit
    PATH="$2"
    _zdx_doctor_fd_command || exit 1
    print -r -- "$REPLY"
    PATH="$3"
    _zdx_doctor_fd_command && exit 2
    exit 0
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/fd-bin" "$TEST_TEMP_DIR/empty-bin"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_TEMP_DIR/fd-bin/fdfind" ]
  # A missing fd is information, never a counted issue.
  sed -n '/_zdx_doctor_fd_command; then/,/^  fi$/p' \
    "$TEST_SUITE_ROOT/functions/zdx-doctor.zsh" > "$TEST_TEMP_DIR/fd-row"
  grep -Fq 'fd/fdfind - Not found (workspace discovery uses find) [Workspaces]' \
    "$TEST_TEMP_DIR/fd-row"
  ! grep -q 'issues_count' "$TEST_TEMP_DIR/fd-row" || false
}

@test "ws: lazy stubs load the suite and ws-jump changes the calling shell" {
  mkdir -p "$HOME/workspaces/github/personal/alpha"
  run zsh -c "
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME
    export HOME='$HOME' PATH='$PATH' WS_BASE_DIR='$HOME/workspaces'
    source '$TEST_SUITE_ROOT/functions.zsh' || exit 1
    local name
    for name in ws-menu ws-jump ws-status ws-clone; do
      [[ \"\${_ZDX_LAZY_FILES[\$name]}\" == ws-menu.zsh ]] || exit 2
    done
    (( ! \${+functions[_ws_dispatch]} )) || exit 3
    ws-jump alpha 2>/dev/null || exit 4
    (( \${+functions[_ws_dispatch]} )) || exit 5
    print -r -- \"pwd:\$PWD\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"pwd:$HOME/workspaces/github/personal/alpha"* ]]
}
