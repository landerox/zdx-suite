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

@test "primitive sync: the canonical confirmation accepts only an explicit yes" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/fzf"
  chmod +x "$TEST_MOCK_BIN/fzf"
  run zsh -f -c '
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
