#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  export COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_git-menu"
}

teardown() {
  cleanup_sandbox
}

@test "git completion: truncated inventories never establish unique remote branch names" {
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  remote) printf '%s\n' origin upstream ;;
  for-each-ref)
    limit=0
    for arg in "$@"; do
      case "$arg" in --count=*) limit=${arg#--count=} ;; esac
    done
    printf '%s\n' refs/heads/main refs/remotes/origin/shared
    for (( n=1; n<=498; n++ )); do
      printf 'refs/remotes/origin/topic%s\n' "$n"
    done
    if (( limit > 500 )); then
      printf '%s\n' refs/remotes/upstream/shared
    fi
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
  ! grep -Fxq shared "$HOME/candidates" || false
  ! grep -Fxq topic1 "$HOME/candidates" || false
}

@test "git completion: bounded CLT qualification requires an explicit valid developer directory" {
  cat >"$TEST_MOCK_BIN/xcode-select" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$HOME/developer"
exit "${CLT_RESULT:-0}"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/xcode-select"
  mkdir "$HOME/developer"
  run run_zsh '
    local -a words=(git-switch "")
    local CURRENT=2
    _arguments() { return 0; }
    _message() { return 0; }
    _describe() { return 0; }
    source "$COMPLETION_FILE"
    OSTYPE=darwin-test
    commands[git]=/usr/bin/git
    command() {
      if [[ "$1" == git || "$1" == /usr/bin/git ]]; then
        print -r -- "$*" >>"$HOME/git.calls"
        return 0
      fi
      builtin command "$@"
    }
    _zdx_run_with_timeout() {
      print -r -- "$1:$2:$3" >>"$HOME/deadlines"
      [[ "$1" == 3 && "$2" == "$TEST_MOCK_BIN/xcode-select" && "$3" == -p ]] || return 91
      shift
      "$@"
    }
    local rc
    for rc in 1 124 130 143; do
      export CLT_RESULT=$rc
      _git_menu_complete_local_branches >/dev/null
      [[ ! -e "$HOME/git.calls" ]] || return 92
    done
    export CLT_RESULT=0
    _git_menu_complete_local_branches >/dev/null
    [[ -s "$HOME/git.calls" ]] || return 93
    print -r -- "qualified=yes"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *qualified=yes* ]]
  [ "$(wc -l <"$HOME/deadlines")" -eq 5 ]
}

@test "git completion: standalone CLT qualification uses a resolved timeout backend" {
  cat >"$TEST_MOCK_BIN/xcode-select" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$HOME/developer"
MOCK
  cat >"$TEST_MOCK_BIN/timeout" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/deadlines"
[[ "$1" == -k && "$2" == 2s && "$3" == 3s ]] || exit 91
shift 3
exec "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/xcode-select" "$TEST_MOCK_BIN/timeout"
  mkdir "$HOME/developer"
  run run_zsh '
    local -a words=(git-switch "")
    local CURRENT=2
    _arguments() { return 0; }
    _message() { return 0; }
    _describe() { return 0; }
    source "$COMPLETION_FILE"
    unfunction _zdx_run_with_timeout 2>/dev/null
    unfunction _git_run_with_timeout 2>/dev/null
    OSTYPE=darwin-test
    commands[git]=/usr/bin/git
    command() {
      if [[ "$1" == git || "$1" == /usr/bin/git ]]; then
        print -r -- "$*" >>"$HOME/git.calls"
        return 0
      fi
      builtin command "$@"
    }
    _git_menu_complete_local_branches >/dev/null
    [[ -s "$HOME/git.calls" ]] || return 92
  '
  [ "$status" -eq 0 ]
  [ -s "$HOME/deadlines" ]
  grep -Fq -- '-k 2s 3s' "$HOME/deadlines"
}
