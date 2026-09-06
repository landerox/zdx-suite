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
      local -a result_files=("$TMPDIR"/zdx-git-fzf.*(N))
      (( ${#result_files} == 1 )) || return 91
      local -A state=()
      zstat -LH state -- "${result_files[1]}" || return 92
      (( (state[mode] & 8#777) == 8#600 )) || return 93
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
setopt MONITOR
source "$ZSH_CUSTOM/functions/git-menu.zsh" || exit 91
git-menu
print -r -- "$?" > "$GIT_MENU_PTY_RC"
CHILD
  run run_zsh '
    zmodload zsh/zpty || return 80
    zpty -b git-menu-foreground zsh -dfi "$GIT_MENU_PTY_CHILD" || return 81
    {
      local -i attempt=0
      local chunk=""
      while [[ ! -s "$GIT_MENU_PTY_RC" ]] && (( ++attempt <= 200 )); do
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
