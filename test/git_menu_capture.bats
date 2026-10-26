#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() { load test_helper; }
teardown() { cleanup_sandbox; }

@test "git menu capture: a forged label cannot dispatch a valid command token" {
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
printf 'Forged action|git-status|A row that was never shown.\n'
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    _git_dispatch() { print called >"$HOME/dispatched"; }
    git-menu
  '
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/dispatched" ]
  [[ "$output" == *"snapshot"* ]]
}

@test "git menu capture: cancellation carrying a genuine row is rejected" {
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
rows=$(cat)
printf '%s\n' "$rows" | sed -n '2p'
exit 130
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
  run run_zsh 'git-menu'
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed Git picker returned unexpected data"* ]]
}

@test "git menu capture: owned private results are cleaned and exact statuses survive" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    command mkdir -m 700 "$HOME/picker-root"
    local TMPDIR="$HOME/picker-root"
    _git_fzf() {
      local -a capture_dirs=("$TMPDIR"/zdx-git-fzf.*(N/))
      (( ${#capture_dirs} == 1 )) || return 91
      local -a result_files=("${capture_dirs[1]}"/result.*(N.))
      (( ${#result_files} == 1 )) || return 91
      local -A state=() directory_state=()
      zstat -LH state -- "${result_files[1]}" || return 92
      zstat -LH directory_state -- "${capture_dirs[1]}" || return 92
      (( (state[mode] & 8#777) == 8#600 \
        && (directory_state[mode] & 8#777) == 8#700 )) || return 93
      [[ "$ZSH_SUBSHELL" == 0 ]] || return 94
      return "$1"
    }
    for code in 0 1 2 130 143; do
      _git_fzf_capture "$code"
      rc=$?
      [[ "$rc" == "$code" && -z "$REPLY" ]] || return 95
      local -a remaining=("$TMPDIR"/zdx-git-fzf.*(N))
      (( ${#remaining} == 0 )) || return 96
    done
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "git menu capture: replacement and oversized selections are refused" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    command mkdir -m 700 "$HOME/picker-root"
    local TMPDIR="$HOME/picker-root"
    _git_fzf() {
      local -a result_files=("$TMPDIR"/zdx-git-fzf.*(N))
      command mv -- "${result_files[1]}" "$HOME/original-result" || return 91
      print replacement >"${result_files[1]}"
    }
    _git_fzf_capture 2>/dev/null
    [[ $? == 125 && -z "$REPLY" ]] || return 92
    local -a remaining=("$TMPDIR"/zdx-git-fzf.*(N))
    (( ${#remaining} == 1 )) || return 93
    [[ "$(<"${remaining[1]}")" == replacement ]] || return 94
    command rm -- "${remaining[1]}"
    _git_fzf() { printf "%70000s" x; }
    _git_fzf_capture 2>/dev/null
    [[ $? == 125 && -z "$REPLY" ]] || return 95
    remaining=("$TMPDIR"/zdx-git-fzf.*(N))
    (( ${#remaining} == 0 ))
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "git menu capture: a failed descriptor read cannot become a successful selection" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    command mkdir -m 700 "$HOME/picker-root"
    local TMPDIR="$HOME/picker-root"
    _git_fzf() { print -r -- selected; }
    sysopen() {
      if [[ "$1" == -r ]]; then
        builtin sysopen -w "${@[2,-1]}"
      else
        builtin sysopen "$@"
      fi
    }
    _git_fzf_capture 2>/dev/null
    [[ $? == 125 && -z "$REPLY" ]] || return 91
    local -a remaining=("$TMPDIR"/zdx-git-fzf.*(N))
    (( ${#remaining} == 0 ))
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# On Ubuntu 26.04, whose coreutils are uutils, cat reported a write-only
# descriptor as an empty, successful read. This stub prints nothing and exits
# 0 for every input, and records that it ran, so a capture that still reads
# through an external cat fails on any host, whatever cat the host has.
make_silent_cat_stub() {
  export SILENT_CAT_DIR="$TEST_TEMP_DIR/silent-cat"
  mkdir -p "$SILENT_CAT_DIR"
  cat > "$SILENT_CAT_DIR/cat" <<MOCK
#!/bin/sh
: > '$TEST_TEMP_DIR/cat-called'
exit 0
MOCK
  chmod +x "$SILENT_CAT_DIR/cat"
}

@test "git menu capture: a failed descriptor read stays a failure when cat reports success" {
  make_silent_cat_stub
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    command mkdir -m 700 "$HOME/picker-root"
    local TMPDIR="$HOME/picker-root"
    path=("$SILENT_CAT_DIR" $path)
    _git_fzf() { print -r -- selected; }
    sysopen() {
      if [[ "$1" == -r ]]; then
        builtin sysopen -w "${@[2,-1]}"
      else
        builtin sysopen "$@"
      fi
    }
    local -a remaining=()
    for copy in core git; do
      [[ "$copy" == git ]] && unset -f _zdx_picker_capture
      _git_fzf_capture 2>/dev/null
      [[ $? == 125 && -z "$REPLY" ]] || return 91
      remaining=("$TMPDIR"/zdx-git-fzf.*(N))
      (( ${#remaining} == 0 )) || return 92
    done
    [[ ! -e "$TEST_TEMP_DIR/cat-called" ]] || return 93
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Captures each payload through the Git wrapper, first with the core and then
# with the Git copy, and compares REPLY with what command substitution makes
# of the same bytes: every trailing newline removed, all other bytes kept.
round_trip_program() {
  cat <<'ZSH'
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 80
    command mkdir -m 700 "$HOME/picker-root" || return 81
    local TMPDIR="$HOME/picker-root"
    path=("$SILENT_CAT_DIR" $path)
    local -a payloads=(
      $'row\n'
      $'first row\nsecond row\nthird row\n'
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
    _git_fzf() { print -rn -- "$GIT_PAYLOAD"; }
    local copy="" expected="" GIT_PAYLOAD=""
    local -i index=0 rc=0
    for copy in core git; do
      [[ "$copy" == git ]] && unset -f _zdx_picker_capture
      for index in {1..${#payloads}}; do
        GIT_PAYLOAD="${payloads[index]}"
        expected=$(print -rn -- "$GIT_PAYLOAD")
        _git_fzf_capture </dev/null
        rc=$?
        if (( rc != 0 )) || [[ "$REPLY" != "$expected" ]]; then
          print -r -- "$copy payload $index: status $rc, ${(q+)REPLY} for ${(q+)expected}"
          return 91
        fi
      done
      print -r -- "$copy: ${#payloads} selections kept"
    done
    local -a remaining=("$TMPDIR"/zdx-git-fzf.*(N))
    (( ${#remaining} == 0 )) || return 92
    [[ ! -e "$TEST_TEMP_DIR/cat-called" ]] || return 93
ZSH
}

@test "git menu capture: selections round-trip byte for byte without an external cat" {
  make_silent_cat_stub
  run run_zsh "$(round_trip_program)"
  [ "$status" -eq 0 ]
  [ "$output" = $'core: 11 selections kept\ngit: 11 selections kept' ]
}

@test "git menu capture: failed temporary creation leaves no directory in REPLY" {
  cat > "$TEST_MOCK_BIN/mktemp" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/mktemp"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    _git_fzf() { print called >"$HOME/picker-called"; }
    REPLY=stale
    _git_fzf_capture 2>/dev/null
    [[ $? == 125 && -z "$REPLY" ]]
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$HOME/picker-called" ]
}

@test "git menu capture: failed selections containing only newlines are rejected" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    command mkdir -m 700 "$HOME/picker-root"
    local TMPDIR="$HOME/picker-root"
    _git_fzf() { print; return "$1"; }
    for code in 1 130 143; do
      _git_fzf_capture "$code" 2>/dev/null
      [[ $? == 125 && -z "$REPLY" ]] || return 91
      local -a remaining=("$TMPDIR"/zdx-git-fzf.*(N))
      (( ${#remaining} == 0 )) || return 92
    done
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "git menu capture: the top-level picker owns the foreground terminal group" {
  export GIT_MENU_PTY_RC="$TEST_TEMP_DIR/pty-rc"
  export GIT_MENU_PTY_CHILD="$TEST_TEMP_DIR/pty-child.zsh"
  cat > "$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
own_group=$(ps -o pgid= -p "$$" | tr -d '[:space:]')
terminal_group=$(ps -o tpgid= -p "$$" | tr -d '[:space:]')
[[ -n "$own_group" && "$own_group" == "$terminal_group" ]] || exit 97
exit 130
MOCK
  chmod +x "$TEST_MOCK_BIN/fzf"
  cat > "$GIT_MENU_PTY_CHILD" <<'CHILD'
emulate -R zsh
setopt MONITOR
source "$ZSH_CUSTOM/functions/git-menu.zsh" || exit 91
git-menu
print -r -- "$?" > "$GIT_MENU_PTY_RC"
CHILD
  run run_zsh '
    zmodload zsh/zpty || return 80
    zmodload zsh/datetime || return 79
    # Job control needs an interactive shell (-i) that owns the pseudo-terminal;
    # -d and -f skip every startup file except the system zshenv.
    zpty -b git-menu-foreground zsh -dfi "$GIT_MENU_PTY_CHILD" || return 81
    {
      # A wall-clock bound sized for slow hosted runners; the loop still ends
      # as soon as the menu records its status.
      local -F deadline=$(( EPOCHREALTIME + 30 ))
      local chunk=""
      while [[ ! -s "$GIT_MENU_PTY_RC" ]] && (( EPOCHREALTIME < deadline )); do
        zpty -r -t git-menu-foreground chunk 2>/dev/null || true
        command sleep 0.01
      done
      [[ -s "$GIT_MENU_PTY_RC" && "$(<"$GIT_MENU_PTY_RC")" == 0 ]]
    } always {
      zpty -d git-menu-foreground 2>/dev/null || true
    }
  '
  [ "$status" -eq 0 ]
}

# Nested pickers run in the foreground through the private capture file: a
# replaced _git_fzf proves it runs in the main shell, prints the row a fake
# picker would return, and exits with GIT_FAKE_RC.
nested_picker_stub() {
  cat <<'ZSH'
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 80
    _git_require_interactive() { return 0; }
    _git_fzf() {
      [[ "$ZSH_SUBSHELL" == 0 ]] || return 94
      command cat >/dev/null
      print -r -- "$GIT_FAKE_ROW"
      return "${GIT_FAKE_RC:-0}"
    }
    fake() { GIT_FAKE_ROW="$1"; GIT_FAKE_RC="${2:-0}"; }
ZSH
}

@test "git nested capture: fixed-option pickers accept only snapshot rows" {
  run run_zsh "$(nested_picker_stub)"'
    fake forged; _git_sync_select_fixed Sync pull fetch 2>/dev/null
    print -r -- "sync-forged=$? [${REPLY}]"
    fake fetch 130; _git_sync_select_fixed Sync pull fetch 2>/dev/null
    print -r -- "sync-cancel-row=$? [${REPLY}]"
    fake fetch; _git_sync_select_fixed Sync pull fetch
    print -r -- "sync-genuine=$? [${REPLY}]"
    fake forged; _git_tag_select_action Tag create delete 2>/dev/null
    print -r -- "tag-forged=$? [${REPLY}]"
    fake delete 1; _git_tag_select_action Tag create delete 2>/dev/null
    print -r -- "tag-cancel-row=$? [${REPLY}]"
    fake delete; _git_tag_select_action Tag create delete
    print -r -- "tag-genuine=$? [${REPLY}]"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "sync-forged=1 []" ]
  [ "${lines[1]}" = "sync-cancel-row=125 []" ]
  [ "${lines[2]}" = "sync-genuine=0 [fetch]" ]
  [ "${lines[3]}" = "tag-forged=1 []" ]
  [ "${lines[4]}" = "tag-cancel-row=125 []" ]
  [ "${lines[5]}" = "tag-genuine=0 [delete]" ]
}

@test "git nested capture: record pickers accept only snapshot records" {
  run run_zsh "$(nested_picker_stub)"'
    local -a records=($'"'"'main\tmain\tmerged'"'"' $'"'"'topic\ttopic\tmerged'"'"')
    fake $'"'"'forged\tforged\tmerged'"'"'
    _git_clean_select_records Branches 0 "${records[@]}" 2>/dev/null
    print -r -- "clean-forged=$? [${(j:,:)${reply[@]%%$'"'"'\t'"'"'*}}]"
    fake "${records[2]}" 130
    _git_clean_select_records Branches 0 "${records[@]}" 2>/dev/null
    print -r -- "clean-cancel-row=$? [${(j:,:)${reply[@]%%$'"'"'\t'"'"'*}}]"
    fake "${records[2]}"
    _git_clean_select_records Branches 0 "${records[@]}"
    print -r -- "clean-genuine=$? [${(j:,:)${reply[@]%%$'"'"'\t'"'"'*}}]"
    fake $'"'"'v9\tv9\tforged'"'"'
    _git_tag_select_records Tags 1 "${records[@]}" 2>/dev/null
    print -r -- "tags-forged=$? [${#reply}]"
    fake "${records[1]}" 130
    _git_tag_select_records Tags 1 "${records[@]}" 2>/dev/null
    print -r -- "tags-cancel-row=$? [${#reply}]"
    fake "${records[1]}"
    _git_tag_select_records Tags 1 "${records[@]}"
    print -r -- "tags-genuine=$? [${reply[1]%%$'"'"'\t'"'"'*}]"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "clean-forged=1 []" ]
  [ "${lines[1]}" = "clean-cancel-row=125 []" ]
  [ "${lines[2]}" = "clean-genuine=0 [topic]" ]
  [ "${lines[3]}" = "tags-forged=1 [0]" ]
  [ "${lines[4]}" = "tags-cancel-row=125 [0]" ]
  [ "${lines[5]}" = "tags-genuine=0 [main]" ]
}

@test "git nested capture: identity and scope pickers never apply a forged row" {
  run run_zsh "$(nested_picker_stub)"'
    typeset -gA ZDX_GIT_IDENTITIES=(
      personal "Name|Jane Doe;Email|jane@personal.example"
    )
    _git_identity_apply() { print -r -- "applied:$*"; }
    fake "personal|2|Jane Doe <jane@personal.example>"
    _git_identity_menu 2>/dev/null
    print -r -- "identity-forged=$?"
    fake "personal|1|Jane Doe <jane@personal.example>" 130
    _git_identity_menu 2>/dev/null
    print -r -- "identity-cancel-row=$?"
    _git_fzf() {
      [[ "$ZSH_SUBSHELL" == 0 ]] || return 94
      local rows=""
      rows=$(command cat)
      if [[ "$rows" == *"|1|"* ]]; then
        print -r -- "${rows%%$'"'"'\n'"'"'*}"
      else
        print -r -- system
      fi
    }
    cd "$HOME" && command git init -q repo && cd repo || return 81
    _git_identity_menu 2>/dev/null
    print -r -- "scope-forged=$?"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "identity-forged=1" ]
  [ "${lines[1]}" = "identity-cancel-row=1" ]
  [ "${lines[2]}" = "scope-forged=1" ]
  [[ "$output" != *"applied:"* ]]
}

@test "git nested capture: the pull request picker returns only a listed record" {
  local oid=0123456789abcdef0123456789abcdef01234567
  cat > "$TEST_MOCK_BIN/gh" <<MOCK
#!/usr/bin/env bash
printf 'PR_1\t7\tOPEN\thttps://github.com/o/r/pull/7\t$oid\tfeature\tAdd feature\n'
MOCK
  chmod +x "$TEST_MOCK_BIN/gh"
  run run_zsh "$(nested_picker_stub)"'
    typeset -gA _GIT_GH_REPO=(target o/r)
    fake "#7 Add feature|1|forged · main · 000000000000"
    _git_gh_pick_pr open 2>/dev/null
    print -r -- "pr-forged=$? [${reply[2]}]"
    fake "#7 Add feature|1|open · feature · 0123456789ab" 130
    _git_gh_pick_pr open 2>/dev/null
    print -r -- "pr-cancel-row=$? [${reply[2]}]"
    fake "#7 Add feature|1|open · feature · 0123456789ab"
    _git_gh_pick_pr open
    print -r -- "pr-genuine=$? [${reply[2]}]"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "pr-forged=1 []" ]
  [ "${lines[1]}" = "pr-cancel-row=1 []" ]
  [ "${lines[2]}" = "pr-genuine=0 [7]" ]
}

@test "git nested capture: undo-commit resets only with a listed mode" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/fzf"
  chmod +x "$TEST_MOCK_BIN/fzf"
  run run_zsh "$(nested_picker_stub)"'
    cd "$HOME" && command git init -q -b main repo && cd repo || return 81
    command git -c user.name=T -c user.email=t@example.invalid \
      commit -q --allow-empty -m one || return 82
    command git -c user.name=T -c user.email=t@example.invalid \
      commit -q --allow-empty -m two || return 83
    local before=$(command git rev-parse HEAD)
    fake $'"'"'keep\tKeep everything'"'"'
    git-undo-commit 2>/dev/null
    print -r -- "mode-forged=$? $([[ $(command git rev-parse HEAD) == $before ]] && print kept)"
    fake $'"'"'soft\tKeep index and worktree'"'"' 130
    git-undo-commit 2>/dev/null
    print -r -- "mode-cancel-row=$? $([[ $(command git rev-parse HEAD) == $before ]] && print kept)"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "mode-forged=1 kept" ]
  [ "${lines[1]}" = "mode-cancel-row=1 kept" ]
}

@test "git nested capture: confirmations accept only Yes or No from the foreground" {
  export GIT_CONFIRM_RESULT="$TEST_TEMP_DIR/confirm-result"
  export GIT_CONFIRM_CHILD="$TEST_TEMP_DIR/confirm-child.zsh"
  cat > "$GIT_CONFIRM_CHILD" <<'CHILD'
emulate -R zsh
source "$ZSH_CUSTOM/functions/git-menu.zsh" || exit 91
_git_fzf() {
  [[ "$ZSH_SUBSHELL" == 0 ]] || return 94
  command cat >/dev/null
  print -r -- "$GIT_FAKE_ROW"
  return "${GIT_FAKE_RC:-0}"
}
{
  GIT_FAKE_ROW=Maybe GIT_FAKE_RC=0
  _git_confirm_outcome "Proceed?"; print -r -- "forged=$? $REPLY"
  GIT_FAKE_ROW=Yes GIT_FAKE_RC=130
  _git_confirm_outcome "Proceed?"; print -r -- "cancel-row=$? $REPLY"
  GIT_FAKE_ROW=No GIT_FAKE_RC=0
  _git_confirm_outcome "Proceed?"; print -r -- "no=$? $REPLY"
  GIT_FAKE_ROW=Yes GIT_FAKE_RC=0
  _git_confirm_outcome "Proceed?"; print -r -- "yes=$? $REPLY"
} > "$GIT_CONFIRM_RESULT.tmp"
command mv -- "$GIT_CONFIRM_RESULT.tmp" "$GIT_CONFIRM_RESULT"
CHILD
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_MOCK_BIN/fzf"
  chmod +x "$TEST_MOCK_BIN/fzf"
  run run_zsh '
    zmodload zsh/zpty || return 80
    zmodload zsh/datetime || return 79
    # The confirmation needs a terminal on standard input and error, which the
    # pseudo-terminal provides; -i makes the shell interactive, like the shell
    # a person types in. -d and -f skip every startup file except the system
    # zshenv.
    zpty -b git-confirm zsh -dfi "$GIT_CONFIRM_CHILD" || return 81
    {
      local -F deadline=$(( EPOCHREALTIME + 30 ))
      local chunk=""
      while [[ ! -s "$GIT_CONFIRM_RESULT" ]] && (( EPOCHREALTIME < deadline )); do
        zpty -r -t git-confirm chunk 2>/dev/null || true
        command sleep 0.01
      done
    } always {
      zpty -d git-confirm 2>/dev/null || true
    }
    command cat "$GIT_CONFIRM_RESULT"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "forged=1 error" ]
  [ "${lines[1]}" = "cancel-row=1 error" ]
  [ "${lines[2]}" = "no=0 cancelled" ]
  [ "${lines[3]}" = "yes=0 confirmed" ]
}
