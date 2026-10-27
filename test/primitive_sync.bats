#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# The canonical core primitives and their generated suite copies.

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "primitive sync: every suite copy equals the canonical primitive" {
  run zsh -f "$TEST_SUITE_ROOT/scripts/sync-primitives.zsh" --check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "primitive sync: a drifted copy is reported and rewritten" {
  local copy="$TEST_TEMP_DIR/repo"
  mkdir -p "$copy"
  cp -R "$TEST_SUITE_ROOT/functions" "$TEST_SUITE_ROOT/functions.zsh" \
    "$TEST_SUITE_ROOT/scripts" "$copy/"
  perl -0pi -e 's/(# >>> zdx-primitive picker-capture\n)/$1# drift\n/' \
    "$copy/functions/git-common.zsh"
  run zsh -f "$copy/scripts/sync-primitives.zsh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"functions/git-common.zsh differs from the canonical picker-capture"* ]]
  run zsh -f "$copy/scripts/sync-primitives.zsh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated picker-capture in functions/git-common.zsh"* ]]
  run zsh -f "$copy/scripts/sync-primitives.zsh" --check
  [ "$status" -eq 0 ]
  run zsh -n "$copy/functions/git-common.zsh"
  [ "$status" -eq 0 ]
}

# Runs the canonical capture with a fixture picker; the fixture prints
# PICK_OUTPUT and exits with PICK_STATUS.
capture_fixture() {
  cat <<'ZSH'
    emulate -R zsh
    source "$1/functions.zsh" 2>/dev/null || exit 90
    command mkdir -m 700 "$HOME/picker-root"
    export TMPDIR="$HOME/picker-root"
    _fixture_error() { print -u2 -r -- "error: $1"; }
    _fixture_picker() {
      command cat >/dev/null
      [[ -n "${PICK_OUTPUT-}" ]] && print -rn -- "$PICK_OUTPUT"
      return "${PICK_STATUS:-0}"
    }
    capture() {
      _zdx_picker_capture --tag fixture --noun Fixture --error _fixture_error \
        --picker _fixture_picker --temp-root _zdx_capture_parent_safe "$@" \
        </dev/null
    }
ZSH
}

@test "primitive sync: the canonical capture keeps statuses and refuses data from failed pickers" {
  run zsh -f -c "$(capture_fixture)"'
    PICK_OUTPUT=$'"'"'row\n'"'"' PICK_STATUS=0 capture --; print -r -- "selected=$? [$REPLY]"
    PICK_OUTPUT="" PICK_STATUS=130 capture --; print -r -- "cancelled=$? [$REPLY]"
    PICK_OUTPUT=$'"'"'row\n'"'"' PICK_STATUS=130 capture -- 2>/dev/null; print -r -- "data-on-failure=$? [$REPLY]"
    PICK_OUTPUT=$'"'"'ctrl-x\n'"'"' PICK_STATUS=1 capture -- --expect=ctrl-x; print -r -- "expect-key=$? [$REPLY]"
    PICK_OUTPUT=$'"'"'ctrl-x\nrow\n'"'"' PICK_STATUS=1 capture -- --expect=ctrl-x 2>/dev/null; print -r -- "expect-row=$? [$REPLY]"
    PICK_OUTPUT=$'"'"'\n'"'"' PICK_STATUS=1 capture -- 2>/dev/null; print -r -- "newline=$? [$REPLY]"
    PICK_OUTPUT="${(l:200::x:)}" PICK_STATUS=0 capture --max-bytes 100 -- 2>/dev/null; print -r -- "oversized=$? [$REPLY]"
    capture --bogus -- ; print -r -- "usage=$?"
    local -a leftovers=("$TMPDIR"/*(N))
    print -r -- "leftovers=${#leftovers}"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "selected=0 [row]" ]
  [ "${lines[1]}" = "cancelled=130 []" ]
  [ "${lines[2]}" = "data-on-failure=125 []" ]
  [ "${lines[3]}" = "expect-key=1 []" ]
  [ "${lines[4]}" = "expect-row=125 []" ]
  [ "${lines[5]}" = "newline=125 []" ]
  [ "${lines[6]}" = "oversized=125 []" ]
  [ "${lines[7]}" = "usage=2" ]
  [ "${lines[8]}" = "leftovers=0" ]
}

@test "primitive sync: the write limit stops a runaway picker with its own status" {
  run zsh -f -c "$(capture_fixture)"'
    _fixture_picker() {
      limit -s filesize unlimited 2>/dev/null || :
      repeat 64 print -rn -- "${(l:1024::x:)}"
    }
    capture --max-bytes 4096 --write-limit -- 2>/dev/null
    print -r -- "status=$? [$REPLY]"
    local -a leftovers=("$TMPDIR"/*(N))
    print -r -- "leftovers=${#leftovers}"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "status=$(( 128 + $(kill -l XFSZ) )) []" ]
  [ "${lines[1]}" = "leftovers=0" ]
}

@test "primitive sync: the canonical capture refuses a result that changes size before it is read" {
  run zsh -f -c "$(capture_fixture)"'
    sysopen() {
      if [[ "$1" == -r ]]; then
        case "${CHANGE-}" in
          grow) print -rn -- late >> "${@[-1]}" ;;
          shrink) : > "${@[-1]}" ;;
        esac
      fi
      builtin sysopen "$@"
    }
    CHANGE=grow PICK_OUTPUT=$'"'"'row\n'"'"' capture --; print -r -- "grown=$? [$REPLY]"
    CHANGE=shrink PICK_OUTPUT=$'"'"'row\n'"'"' capture --; print -r -- "shrunk=$? [$REPLY]"
    CHANGE="" PICK_OUTPUT=$'"'"'row\n'"'"' capture --; print -r -- "unchanged=$? [$REPLY]"
    local -a leftovers=("$TMPDIR"/*(N))
    print -r -- "leftovers=${#leftovers}"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "error: Could not read the Fixture picker result.
grown=125 []
error: Could not read the Fixture picker result.
shrunk=125 []
unchanged=0 [row]
leftovers=0" ]
}

# Runs the canonical capture and every generated copy with a stub cat first on
# PATH. The stub prints nothing and exits 0 for every input, as the uutils cat
# of Ubuntu 26.04 did for a write-only descriptor, and records that it ran.
# For each capture, every payload must come back as command substitution
# makes it (all trailing newlines removed, every other byte kept), and a
# result opened write-only must fail with 125 and the read error.
builtin_read_fixture() {
  cat <<'ZSH'
    emulate -R zsh
    source "$1/functions.zsh" 2>/dev/null || exit 90
    local suite=""
    for suite in git sys dev py ws env file zdx; do
      source "$1/functions/$suite-common.zsh" 2>/dev/null || exit 91
    done
    command mkdir -m 700 "$HOME/picker-root" || exit 92
    export TMPDIR="$HOME/picker-root"
    path=("$2" $path)
    local errors="$HOME/capture-errors"
    _fixture_error() { print -r -- "$1" >> "$errors"; }
    _fixture_picker() { print -rn -- "$FIXTURE_PAYLOAD"; }
    local -a payloads=(
      $'row\n'
      $'first row\nsecond row\n'
      $'kept\n\ninner\n\n\n'
      'no trailing newline'
      $'\n\nleading\n'
      $'carriage\r\n'
      $'caf\xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x93\x81\n'
      $'raw \x80\x83\x9f\xa0\xfe\xff bytes\n'
      $'nul\0inside\n'
      $'\n\n\n'
      ''
    )
    local capture="" expected="" FIXTURE_PAYLOAD="" read_result=""
    local -i index=0 rc=0 kept=0
    local -a leftovers=()
    for capture in _zdx_picker_capture _git_picker_capture _sys_picker_capture \
      _dev_picker_capture _py_picker_capture _ws_picker_capture \
      _env_picker_capture _file_picker_capture _zdx_menu_picker_capture; do
      (( ${+functions[$capture]} )) || exit 93
      kept=0
      for index in {1..${#payloads}}; do
        FIXTURE_PAYLOAD="${payloads[index]}"
        expected=$(print -rn -- "$FIXTURE_PAYLOAD")
        "$capture" --tag fixture --noun Fixture --error _fixture_error \
          --picker _fixture_picker --temp-root _zdx_capture_parent_safe -- </dev/null
        rc=$?
        (( rc == 0 )) && [[ "$REPLY" == "$expected" ]] && kept+=1
      done
      sysopen() {
        if [[ "$1" == -r ]]; then
          builtin sysopen -w "${@[2,-1]}"
        else
          builtin sysopen "$@"
        fi
      }
      FIXTURE_PAYLOAD=$'selected\n'
      "$capture" --tag fixture --noun Fixture --error _fixture_error \
        --picker _fixture_picker --temp-root _zdx_capture_parent_safe -- </dev/null
      rc=$?
      unfunction sysopen
      read_result="$rc [$REPLY]"
      if [[ -f "$errors" ]]; then
        read_result+=" ${(j:|:)${(@f)$(<"$errors")}}"
        command rm -f -- "$errors"
      fi
      leftovers=("$TMPDIR"/*(N))
      print -r -- "$capture: kept=$kept/${#payloads} failed-read=$read_result leftovers=${#leftovers}"
    done
    [[ ! -e "$HOME/cat-called" ]] || print -r -- "an external cat ran"
ZSH
}

@test "primitive sync: every capture copy reads its result without an external cat" {
  local stub_dir="$TEST_TEMP_DIR/silent-cat"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/cat" <<MOCK
#!/bin/sh
: > '$HOME/cat-called'
exit 0
MOCK
  chmod +x "$stub_dir/cat"
  run zsh -f -c "$(builtin_read_fixture)" _ "$TEST_SUITE_ROOT" "$stub_dir"
  [ "$status" -eq 0 ]
  local capture expected=""
  for capture in _zdx_picker_capture _git_picker_capture _sys_picker_capture \
    _dev_picker_capture _py_picker_capture _ws_picker_capture \
    _env_picker_capture _file_picker_capture _zdx_menu_picker_capture; do
    expected+="$capture: kept=11/11 failed-read=125 [] Could not read the Fixture picker result. leftovers=0"$'\n'
  done
  [ "$output" = "${expected%$'\n'}" ]
}

@test "primitive sync: the canonical confirmation accepts only an explicit yes" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/fzf"
  chmod +x "$TEST_MOCK_BIN/fzf"
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" 2>/dev/null || exit 90
    _fixture_error() { print -u2 -r -- "error: $1"; }
    _fixture_terminal() { return 0; }
    _fixture_no_terminal() { return 1; }
    _fixture_capture() { REPLY="$FIXTURE_ANSWER"; return "${FIXTURE_STATUS:-0}"; }
    ask() {
      _zdx_confirm_prompt --error _fixture_error --available _fixture_terminal "$@"
    }
    ask --style line -- "Proceed?" <<< "y" 2>/dev/null; print -r -- "line-y=$?"
    ask --style line -- "Proceed?" <<< "yes" 2>/dev/null; print -r -- "line-yes=$?"
    ask --style line -- "Proceed?" < /dev/null 2>/dev/null; print -r -- "line-eof=$?"
    ask --style key -- "Proceed?" <<< "Y" 2>/dev/null; print -r -- "key-Y=$?"
    _zdx_confirm_prompt --style line --error _fixture_error \
      --available _fixture_no_terminal -- "Proceed?" <<< "y"; print -r -- "no-terminal=$?"
    FIXTURE_ANSWER=Yes ask --style picker --capture _fixture_capture -- "Go?"; print -r -- "picker-yes=$?"
    FIXTURE_ANSWER=No ask --style picker --capture _fixture_capture -- "Go?"; print -r -- "picker-no=$?"
    FIXTURE_ANSWER=Maybe ask --style picker --capture _fixture_capture -- "Go?" 2>/dev/null; print -r -- "picker-forged=$?"
    FIXTURE_ANSWER="" FIXTURE_STATUS=130 ask --style picker --capture _fixture_capture -- "Go?"; print -r -- "picker-cancel=$?"
    FIXTURE_ANSWER="" FIXTURE_STATUS=125 ask --style picker --capture _fixture_capture -- "Go?" 2>/dev/null; print -r -- "picker-failed=$?"
    ask --style shout -- "Go?"; print -r -- "usage=$?"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = $'line-y=0\nline-yes=1\nline-eof=2\nkey-Y=0\nno-terminal=2\npicker-yes=0\npicker-no=1\npicker-forged=3\npicker-cancel=1\npicker-failed=3\nusage=3' ]
}

@test "primitive sync: the earlier tk names only wrap the zdx helpers" {
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions.zsh" 2>/dev/null || exit 90
    [[ "$(_tk_fzf_color_opts)" == "$(_zdx_fzf_color_opts)" ]] || exit 91
    ZDX_FZF_TEMPLATES=1 _tk_fzf_nth_template_option --with-nth=2 || exit 92
    print -r -- "$REPLY"
    (( ! ${+functions[_tk_check_cmd]} && ! ${+functions[_tk_date_iso8601]} )) || exit 93
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "--with-nth={2}" ]
  run grep -rn --include='*.zsh' '_tk_' "$TEST_SUITE_ROOT/functions"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^_tk_' "$TEST_SUITE_ROOT/functions.zsh")" -eq 4 ]
}
