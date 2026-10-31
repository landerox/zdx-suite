#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# Current-shell boundaries beyond the main core-options regression matrix.

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "core options boundaries: cold VPN help retains KSH_ARRAYS without invoking a VPN action" {
  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME ZDX_LAZY_LOAD=1 ZDX_EAGER_LOAD=0 \
    zsh -f -c '
      emulate -R zsh
      cd "$HOME" || exit 80
      source "$1/functions.zsh" || exit 81
      (( ! ${+functions[_vpn_dispatch]} )) || exit 82
      setopt ksh_arrays
      local before="$(setopt)"
      vpn-menu --help > "$HOME/help.stdout" 2> "$HOME/help.stderr" || exit 83
      [[ "$(setopt)" == "$before" && -o ksh_arrays ]] || exit 84
      (( ${+functions[_vpn_dispatch]} )) || exit 85
      [[ ! -s "$HOME/help.stdout" ]] || exit 86
      print -r -- cold-help
    ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = cold-help ]
  grep -Fq -- 'vpn-menu' "$HOME/help.stderr"
  grep -Fq -- 'Usage:' "$HOME/help.stderr"
}

@test "core options boundaries: cold VPN help retains emulate sh options without invoking a VPN action" {
  run env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME ZDX_LAZY_LOAD=1 ZDX_EAGER_LOAD=0 \
    zsh -f -c '
      emulate -R zsh
      cd "$HOME" || exit 80
      source "$1/functions.zsh" || exit 81
      (( ! ${+functions[_vpn_dispatch]} )) || exit 82
      emulate sh
      local before="$(setopt)"
      vpn-menu --help > "$HOME/help.stdout" 2> "$HOME/help.stderr" || exit 83
      [[ "$(setopt)" == "$before" ]] || exit 84
      (( ${+functions[_vpn_dispatch]} )) || exit 85
      [[ ! -s "$HOME/help.stdout" ]] || exit 86
      print -r -- cold-help
    ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = cold-help ]
  grep -Fq -- 'vpn-menu' "$HOME/help.stderr"
  grep -Fq -- 'Usage:' "$HOME/help.stderr"
}

@test "core options boundaries: the identity hook preserves direct public override session effects" {
  mkdir -p "$HOME/workspaces/github/personal/repository/.git"
  # Interactive mode installs the identity hook; -f and the sandbox HOME
  # keep this fixture independent of the owner's startup files.
  run env HOME="$HOME" ZDX_KEYBINDINGS=0 ZDX_GIT_IDENTITY_GUARD=1 \
    WS_BASE_DIR="$HOME/workspaces" zsh -f -i -c '
      emulate -R zsh
      cd "$HOME" || exit 80
      source "$1/zdx-suite.plugin.zsh" || exit 81
      git-identity-check() {
        [[ "$*" == --quiet && -o sh_word_split ]] || return 82
        setopt null_glob
        typeset -g F304_GUARD_EFFECT=visible
        [[ cbtext =~ "(cb)(text)" ]] || return 83
        return 7
      }
      setopt sh_word_split
      unsetopt null_glob
      cd "$WS_BASE_DIR/github/personal/repository" > "$HOME/guard.stdout" \
        2> "$HOME/guard.stderr" || exit 84
      [[ -o sh_word_split && -o null_glob && "$F304_GUARD_EFFECT" == visible ]] || exit 85
      [[ "$MATCH" == cbtext && "$MBEGIN" == 1 && "$MEND" == 6 ]] || exit 86
      [[ "${(j:,:)match}" == cb,text && "${(j:,:)mbegin}" == 1,3 \
        && "${(j:,:)mend}" == 2,6 ]] || exit 87
      [[ ! -s "$HOME/guard.stdout" && ! -s "$HOME/guard.stderr" ]] || exit 88
      print -r -- guard-preserved
    ' _ "$TEST_SUITE_ROOT" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = guard-preserved ]
}

@test "core options boundaries: identity-hook menu loading returns before an override executes" {
  mkdir -p "$HOME/workspaces/github/personal/repository/.git"
  # Interactive mode installs the identity hook; -f and the sandbox HOME
  # keep this fixture independent of the owner's startup files.
  run env HOME="$HOME" ZDX_KEYBINDINGS=0 ZDX_GIT_IDENTITY_GUARD=1 \
    WS_BASE_DIR="$HOME/workspaces" zsh -f -i -c '
      emulate -R zsh
      cd "$HOME" || exit 80
      source "$1/zdx-suite.plugin.zsh" || exit 81
      unfunction git-identity-check || exit 82
      git-menu() {
        [[ "$*" == --help && -o sh_word_split ]] || return 83
        setopt null_glob
        typeset -g F304_GUARD_HELP_EFFECT=visible
        git-identity-check() {
          [[ "$*" == --quiet && -o sh_word_split && -o null_glob ]] || return 84
          setopt glob_dots
          typeset -g F304_GUARD_CHECK_EFFECT=visible
          return 7
        }
      }
      setopt sh_word_split
      unsetopt null_glob glob_dots
      cd "$WS_BASE_DIR/github/personal/repository" > "$HOME/guard.stdout" \
        2> "$HOME/guard.stderr" || exit 85
      [[ -o sh_word_split && -o null_glob && -o glob_dots ]] || exit 86
      [[ "$F304_GUARD_HELP_EFFECT" == visible && "$F304_GUARD_CHECK_EFFECT" == visible ]] || exit 87
      [[ ! -s "$HOME/guard.stdout" && ! -s "$HOME/guard.stderr" ]] || exit 88
      print -r -- guard-preserved
    ' _ "$TEST_SUITE_ROOT" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = guard-preserved ]
}
