#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "git CLI: root-relative commands parse help and invalid input before any git invocation" {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/git.calls"
exit 97
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    local cmd rc
    for cmd in git-unstage git-discard git-stash git-undo-commit; do
      "$cmd" --help >"$HOME/$cmd.stdout" 2>"$HOME/$cmd.stderr"
      rc=$?
      print -r -- "$cmd help:$rc"
      (( rc == 0 )) || return 91
      "$cmd" --invalid >"$HOME/$cmd.invalid.stdout" 2>"$HOME/$cmd.invalid.stderr"
      rc=$?
      print -r -- "$cmd invalid:$rc"
      (( rc == 2 )) || return 92
    done
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/git.calls" ]
  local cmd
  for cmd in git-unstage git-discard git-stash git-undo-commit; do
    [ ! -s "$HOME/$cmd.stdout" ]
    [ ! -s "$HOME/$cmd.invalid.stdout" ]
    grep -Fq 'Usage:' "$HOME/$cmd.stderr"
    [ -s "$HOME/$cmd.invalid.stderr" ]
  done
}

@test "git CLI: tag message and type conflicts are rejected before repository probes" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    _git_require_repo() { print -r -- probe >>"$HOME/probes"; return 97; }
    local mode rc
    for mode in annotated signed; do
      git-tag-create --name v1 "--$mode" >"$HOME/$mode.stdout" 2>"$HOME/$mode.stderr"
      rc=$?
      print -r -- "$mode:$rc"
      (( rc == 2 )) || return 91
    done
    git-tag-create --name v1 --lightweight --message text >"$HOME/light.stdout" 2>"$HOME/light.stderr"
    rc=$?
    print -r -- "lightweight:$rc"
    (( rc == 2 )) || return 92
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/probes" ]
  local mode
  for mode in annotated signed light; do
    [ ! -s "$HOME/$mode.stdout" ]
    [ -s "$HOME/$mode.stderr" ]
  done
}

@test "git CLI: empty arguments explain status 2 on stderr" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    local cmd rc
    for cmd in git-auth git-tag-verify git-identity-switcher; do
      "$cmd" "" >"$HOME/$cmd.stdout" 2>"$HOME/$cmd.stderr"
      rc=$?
      print -r -- "$cmd:$rc"
      (( rc == 2 )) || return 91
    done
  '
  [ "$status" -eq 0 ]
  local cmd
  for cmd in git-auth git-tag-verify git-identity-switcher; do
    [ ! -s "$HOME/$cmd.stdout" ]
    [ -s "$HOME/$cmd.stderr" ]
  done
}

@test "git CLI: dispatcher isolates inherited options and restores them after dispatch" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    git-status() { [[ -o nomatch ]] || return 91; return 7; }
    unsetopt nomatch
    _git_dispatch git-status
    local rc=$?
    print -r -- "status:$rc"
    (( rc == 7 )) || return 92
    [[ ! -o nomatch ]] || return 93
  '
  [ "$status" -eq 0 ]
}

@test "git probes: snapshots use a fixed 30 second deadline and preserve timeout and interruptions" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    _zdx_run_with_timeout() {
      print -r -- "$1:${2:t}:${GIT_TERMINAL_PROMPT:-unset}:${GIT_ASKPASS:-unset}:${GCM_INTERACTIVE:-unset}" >>"$HOME/deadlines"
      [[ "$1" == 30 && "$GIT_TERMINAL_PROMPT" == 0 && "$GCM_INTERACTIVE" == never ]] || return 98
      return "$probe_status"
    }
    local helper probe_status rc
    local -i failures=0
    for probe_status in 124 130 143 17; do
      for helper in _git_sync_remote_snapshot _git_tag_remote_snapshot; do
        "$helper" origin "refs/heads/*" >"$HOME/$helper.$probe_status.stdout" 2>"$HOME/$helper.$probe_status.stderr"
        rc=$?
        print -r -- "$helper:$probe_status:$rc"
        (( rc == probe_status )) || (( failures++ ))
      done
      _git_clean_remote_snapshot origin fixture-url >"$HOME/clean.$probe_status.stdout" 2>"$HOME/clean.$probe_status.stderr"
      rc=$?
      print -r -- "clean:$probe_status:$rc"
      (( rc == probe_status )) || (( failures++ ))
      _git_gh_remote_head_oid fixture-url main >"$HOME/head.$probe_status.stdout" 2>"$HOME/head.$probe_status.stderr"
      rc=$?
      print -r -- "head:$probe_status:$rc"
      (( rc == probe_status )) || (( failures++ ))
    done
    (( failures == 0 ))
  '
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$HOME/deadlines")" -eq 16 ]
}

@test "git probes: github reads use deadlines and retain producer failures" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    _git_require_repo() { return 0; }
    _git_check_gh() { return 0; }
    _GIT_GH_REPO=(id fixture-id name fixture/repo host github.com target github.com/fixture/repo)
    _zdx_run_with_timeout() {
      print -r -- "$1:${2:t}" >>"$HOME/deadlines"
      [[ "$1" == 30 && "${2:t}" == gh ]] || return 98
      return "$probe_status"
    }
    local probe_status helper rc
    local -i failures=0
    for probe_status in 124 130 143 17; do
      for helper in _git_gh_repo_context _git_gh_require_same_repo _git_gh_pick_pr _git_gh_pr_current _git_gh_created_pr_current _git_gh_base_oid; do
        "$helper" 1 >"$HOME/$helper.$probe_status.stdout" 2>"$HOME/$helper.$probe_status.stderr"
        rc=$?
        print -r -- "$helper:$probe_status:$rc"
        (( rc == probe_status )) || (( failures++ ))
      done
    done
    (( failures == 0 ))
  '
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$HOME/deadlines")" -eq 24 ]
}

@test "git completion: switch candidates exclude ambiguous bare names and preserve slash remotes" {
  export COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_git-menu"
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  remote) printf '%s\n' origin vendor/team ;;
  for-each-ref)
    printf '%s\n' refs/heads/main refs/heads/local refs/remotes/origin/shared refs/remotes/vendor/team/shared refs/remotes/vendor/team/unique refs/remotes/origin/local
    ;;
  *) exit 97 ;;
esac
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
  run run_zsh '
    local -a words=(git-switch "")
    local CURRENT=2
    _arguments() { return 0; }
    _message() { return 0; }
    _describe() { print -rl -- "${(@P)4}"; }
    source "$COMPLETION_FILE"
    _git_menu_complete_switch_branches >"$HOME/candidates"
  '
  [ "$status" -eq 0 ]
  grep -Fxq main "$HOME/candidates"
  grep -Fxq local "$HOME/candidates"
  grep -Fxq unique "$HOME/candidates"
  ! grep -Fxq shared "$HOME/candidates" || false
  ! grep -Fxq team/unique "$HOME/candidates" || false
}

@test "git completion: standalone helpers never run the macOS placeholder when CLT is unavailable" {
  export COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_git-menu"
  run run_zsh '
    local -a words=(git-switch "")
    local CURRENT=2
    _arguments() { return 0; }
    _message() { return 0; }
    _describe() { return 0; }
    source "$COMPLETION_FILE"
    unfunction _zdx_run_with_timeout 2>/dev/null
    OSTYPE=darwin-test
    commands[git]=/usr/bin/git
    command() {
      if [[ "$1" == git || "$1" == /usr/bin/git ]]; then
        print -r -- "$*" >>"$HOME/git.calls"
        return 97
      fi
      builtin command "$@"
    }
    local helper
    for helper in local_branches switch_branches remote_branches revisions full_branch_refs tags stashes remotes pr_number; do
      "_git_menu_complete_$helper" >"$HOME/$helper.stdout" 2>"$HOME/$helper.stderr"
    done
    return 0
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/git.calls" ]
}
