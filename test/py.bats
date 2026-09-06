#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "py: sourcing twice is silent and performs no capability probes" {
  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    fzf() { print -r -- fzf >>'$HOME/probes'; }
    uv() { print -r -- uv >>'$HOME/probes'; }
    pipx() { print -r -- pipx >>'$HOME/probes'; }
    curl() { print -r -- curl >>'$HOME/probes'; }
    python3() { print -r -- python3 >>'$HOME/probes'; }
    source '$TEST_SUITE_ROOT/functions/py-menu.zsh' || exit 1
    source '$TEST_SUITE_ROOT/functions/py-menu.zsh' || exit 1
    [[ ! -e '$HOME/probes' ]]
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "py: a failed mandatory module leaves no menu sentinel" {
  local broken_root="$TEST_TEMP_DIR/broken"
  mkdir -p "$broken_root/py"
  cp "$TEST_SUITE_ROOT/functions/py-menu.zsh" "$broken_root/"
  cp "$TEST_SUITE_ROOT/functions/py-common.zsh" "$broken_root/"
  cp "$TEST_SUITE_ROOT/functions/py/"*.zsh "$broken_root/py/"
  printf 'if true; then\n' > "$broken_root/py/py-pypi.zsh"

  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    source '$broken_root/py-menu.zsh'
    rc=\$?
    [[ -z \"\${_PY_MENU_SOURCED:-}\" ]]
    [[ \$rc -ne 0 ]]
  "

  [ "$status" -eq 0 ]
}

@test "py: help is stderr-only and unknown interface input returns 2" {
  run run_zsh '
    py-menu --help >"$HOME/help.stdout" 2>"$HOME/help.stderr"
    local help_rc=$?
    py-menu --unknown >"$HOME/option.stdout" 2>"$HOME/option.stderr"
    local option_rc=$?
    py-menu unknown-command >"$HOME/command.stdout" 2>"$HOME/command.stderr"
    local command_rc=$?
    print -r -- "$help_rc:$option_rc:$command_rc"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "0:2:2" ]
  [ ! -s "$HOME/help.stdout" ]
  [ ! -s "$HOME/option.stdout" ]
  [ ! -s "$HOME/command.stdout" ]
  grep -q "Canonical commands:" "$HOME/help.stderr"
}

@test "py: logging is stderr-only and honors NO_COLOR" {
  run run_zsh '
    export NO_COLOR=1
    {
      _py_header "Header"
      _py_success "Success"
      _py_warn "Warning"
      _py_info "Info"
      _py_error "Error"
      _py_dim "Dim"
    } >"$HOME/log.stdout" 2>"$HOME/log.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/log.stdout" ]
  grep -q "Header" "$HOME/log.stderr"
  ! grep -q $'\033' "$HOME/log.stderr"
}

@test "py: menu rows reject delimiters and control characters" {
  run run_zsh '
    _py_menu_entry "List" "venv-list" "Safe description"
    _py_menu_entry $'\''bad\tlabel'\'' "venv-list" "description" \
      >/dev/null 2>&1
    local tab_rc=$?
    _py_menu_entry "bad|label" "venv-list" "description" \
      >/dev/null 2>&1
    local pipe_rc=$?
    _py_menu_entry $'\''bad\eheader'\'' "venv-list" "description" \
      >/dev/null 2>&1
    local escape_rc=$?
    print -u2 -r -- "invalid:$tab_rc:$pipe_rc:$escape_rc"
  '

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "  ● List|venv-list|Safe description" ]
  [[ "$output" == *"invalid:1:1:1"* ]]
}

@test "py: multi-select contains only non-interactive read-only commands" {
  run run_zsh '
    fzf() {
      command cat >"$HOME/multi.rows"
      command awk -F "|" '\''$2 != ":" { print }'\'' "$HOME/multi.rows"
      return 0
    }
    venv-list() { print -u2 -r -- venv-list-ran; }
    venv-python-list() { print -u2 -r -- venv-python-list-ran; }
    tool-list() { print -u2 -r -- tool-list-ran; }
    py-menu --multi >"$HOME/multi.stdout" 2>"$HOME/multi.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/multi.stdout" ]
  awk -F "|" '$2 != ":" { print $2 }' "$HOME/multi.rows" \
    | sort > "$TEST_TEMP_DIR/actual"
  printf '%s\n' tool-list venv-list venv-python-list \
    | sort > "$TEST_TEMP_DIR/expected"
  diff -u "$TEST_TEMP_DIR/expected" "$TEST_TEMP_DIR/actual"
  grep -q \
    "Batch summary: passed=3 failed=0 skipped=0 cancelled=0" \
    "$HOME/multi.stderr"
}

@test "py: picker cancellation is success and reports a cancelled batch" {
  run run_zsh '
    fzf() {
      command cat >/dev/null
      return 130
    }
    py-menu --multi >"$HOME/menu.stdout" 2>"$HOME/menu.stderr"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/menu.stdout" ]
  grep -q \
    "Batch summary: passed=0 failed=0 skipped=0 cancelled=1" \
    "$HOME/menu.stderr"
}

@test "py: foreground picker capture preserves status and bounded selection" {
  run run_zsh '
    local private_tmp="$HOME/py-picker"
    command mkdir -m 700 -- "$private_tmp"
    TMPDIR="$private_tmp"
    fzf() {
      command cat >/dev/null
      printf "first|venv-list|one\nsecond|tool-list|two\n"
      return 0
    }
    _py_fzf_capture < <(print -r -- ignored)
    local picker_rc=$?
    [[ "$REPLY" == $'\''first|venv-list|one\nsecond|tool-list|two'\'' ]]
    [[ -z "$(command find "$private_tmp" -mindepth 1 -print -quit)" ]]
    return $picker_rc
  '

  [ "$status" -eq 0 ]
}
