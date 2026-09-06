#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  export WS_CLONE_REAL_GIT
  WS_CLONE_REAL_GIT="$(type -P git)"
  load test_helper
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  export WS_CLONE_WORKSPACE="$HOME/workspaces/github/test"
  export WS_CLONE_SOURCE="$HOME/source" WS_CLONE_LOG="$HOME/clone.calls"
  export WS_CLONE_MODE=partial WS_CLONE_STATUS=47
  mkdir -p "$WS_CLONE_WORKSPACE"
  chmod 700 "$WS_CLONE_WORKSPACE"
  printf 'original workspace\n' > "$WS_CLONE_WORKSPACE/identity-marker"
  : > "$WS_CLONE_LOG"
  "$WS_CLONE_REAL_GIT" init -q -b main "$WS_CLONE_SOURCE"
  "$WS_CLONE_REAL_GIT" -C "$WS_CLONE_SOURCE" config user.name 'Clone Test'
  "$WS_CLONE_REAL_GIT" -C "$WS_CLONE_SOURCE" config user.email 'clone@example.invalid'
  "$WS_CLONE_REAL_GIT" -C "$WS_CLONE_SOURCE" config core.hooksPath /dev/null
  printf 'local clone fixture\n' > "$WS_CLONE_SOURCE/content.txt"
  "$WS_CLONE_REAL_GIT" -C "$WS_CLONE_SOURCE" add -- content.txt
  "$WS_CLONE_REAL_GIT" -C "$WS_CLONE_SOURCE" commit -q -m fixture

  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env zsh
if [[ "${1:-}" != clone ]]; then
  exec "$WS_CLONE_REAL_GIT" "$@"
fi
typeset destination="${3:-}"
typeset repository_name="${destination:t}"
print -r -- "$repository_name" >> "$WS_CLONE_LOG"
if [[ "$repository_name" == broken ]]; then
  case "$WS_CLONE_MODE" in
    partial)
      command mkdir -- "$destination" || exit 97
      print -r -- 'incomplete clone data' > "$destination/recovery-marker"
      exit "$WS_CLONE_STATUS"
      ;;
    no-directory) exit "$WS_CLONE_STATUS" ;;
    replacement-failure|replacement-success)
      command mv -- "$WS_CLONE_WORKSPACE" "$WS_CLONE_WORKSPACE.previous" || exit 97
      command mkdir -m 700 -- "$WS_CLONE_WORKSPACE" || exit 97
      if [[ "$WS_CLONE_MODE" == replacement-failure ]]; then
        command mkdir -- "$destination" || exit 97
        exit "$WS_CLONE_STATUS"
      fi
      ;;
    changed-mode)
      command chmod 755 -- "$WS_CLONE_WORKSPACE" || exit 97
      ;;
  esac
fi
# Every successful mocked transport clones this disposable local repository.
exec "$WS_CLONE_REAL_GIT" clone --local -- "$WS_CLONE_SOURCE" "$destination"
EOF
  chmod +x "$TEST_MOCK_BIN/git"
  export WS_CLONE_SETUP="$HOME/clone-setup.zsh"
  cat > "$WS_CLONE_SETUP" <<'EOF'
source "$ZSH_CUSTOM/functions/ws-menu.zsh"
unfunction command
_tk_detect_workspace() { print -r -- github/test; }
_ws_clone_confirmation_available() { return 0; }
_tk_confirm() { [[ "$1" == Clone\ * ]]; }
EOF
}

teardown() {
  cleanup_sandbox
}

@test "ws clone recovery: a retained partial clone does not block later independent repositories" {
  run run_zsh '
    source "$WS_CLONE_SETUP"
    ws-clone-multi owner/first owner/broken owner/last > "$HOME/clone.stdout"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$WS_CLONE_LOG")" = $'first\nbroken\nlast' ]
  [ "$(cat "$WS_CLONE_WORKSPACE/broken/recovery-marker")" = 'incomplete clone data' ]
  [ "$(cat "$WS_CLONE_WORKSPACE/last/content.txt")" = 'local clone fixture' ]
  [ ! -s "$HOME/clone.stdout" ]
  [[ "$output" == *'Partial destination retained'* ]]
}

@test "ws clone recovery: a clone failure without a destination still permits later work" {
  export WS_CLONE_MODE=no-directory
  run run_zsh 'source "$WS_CLONE_SETUP"; ws-clone-multi owner/broken owner/last'

  [ "$status" -eq 1 ]
  [ "$(cat "$WS_CLONE_LOG")" = $'broken\nlast' ]
  [ ! -e "$WS_CLONE_WORKSPACE/broken" ]
  [ -f "$WS_CLONE_WORKSPACE/last/content.txt" ]
}

@test "ws clone recovery: workspace replacement after failure stops the batch without adopting it" {
  export WS_CLONE_MODE=replacement-failure
  run run_zsh 'source "$WS_CLONE_SETUP"; ws-clone-multi owner/broken owner/last'

  [ "$status" -eq 1 ]
  [ "$(cat "$WS_CLONE_LOG")" = broken ]
  [ -f "$WS_CLONE_WORKSPACE.previous/identity-marker" ]
  [ ! -e "$WS_CLONE_WORKSPACE/last" ]
  [[ "$output" == *'Workspace changed after cloning'* ]]
  [[ "$output" == *'Not run'* ]]
}

@test "ws clone recovery: successful transport cannot authorize a replacement workspace" {
  export WS_CLONE_MODE=replacement-success
  run run_zsh 'source "$WS_CLONE_SETUP"; ws-clone-multi owner/broken owner/last'

  [ "$status" -eq 1 ]
  [ "$(cat "$WS_CLONE_LOG")" = broken ]
  [ -f "$WS_CLONE_WORKSPACE.previous/identity-marker" ]
  [ -f "$WS_CLONE_WORKSPACE/broken/content.txt" ]
  [ ! -e "$WS_CLONE_WORKSPACE/last" ]
  [[ "$output" == *'Workspace changed after cloning'* ]]
}

@test "ws clone recovery: a mode change cannot be absorbed into the next workspace fingerprint" {
  export WS_CLONE_MODE=changed-mode
  run run_zsh 'source "$WS_CLONE_SETUP"; ws-clone-multi owner/broken owner/last'

  [ "$status" -eq 1 ]
  [ "$(cat "$WS_CLONE_LOG")" = broken ]
  [ ! -e "$WS_CLONE_WORKSPACE/last" ]
  [[ "$output" == *'Workspace changed after cloning'* ]]
}

@test "ws clone recovery: changes between clone attempts still invalidate the full workspace fingerprint" {
  run run_zsh '
    source "$WS_CLONE_SETUP"
    _tk_success() {
      if [[ "$1" == first ]]; then
        command mkdir -- "$WS_CLONE_WORKSPACE/concurrent-directory"
      fi
    }
    ws-clone-multi owner/first owner/last
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$WS_CLONE_LOG")" = first ]
  [ -f "$WS_CLONE_WORKSPACE/first/content.txt" ]
  [ ! -e "$WS_CLONE_WORKSPACE/last" ]
  [[ "$output" == *'Workspace or destination changed before cloning last'* ]]
}

@test "ws clone recovery: batch interruption preserves status, partial destination, and remaining targets" {
  for interruption_status in 130 143; do
    export WS_CLONE_STATUS="$interruption_status"
    run run_zsh '
      source "$WS_CLONE_SETUP"
      ws-clone-multi "owner/first-$WS_CLONE_STATUS" owner/broken owner/last
    '

    [ "$status" -eq "$interruption_status" ]
    [ "$(cat "$WS_CLONE_LOG")" = "first-$interruption_status"$'\nbroken' ]
    [ -f "$WS_CLONE_WORKSPACE/first-$interruption_status/content.txt" ]
    [ -f "$WS_CLONE_WORKSPACE/broken/recovery-marker" ]
    [ ! -e "$WS_CLONE_WORKSPACE/last" ]
    [[ "$output" == *'Batch cloning interrupted'* ]]
    [[ "$output" == *'Not run'* ]]
    mv "$WS_CLONE_WORKSPACE/broken" "$WS_CLONE_WORKSPACE/interrupted-$interruption_status"
    : > "$WS_CLONE_LOG"
  done
}

@test "ws clone recovery: single-clone interruption preserves its status" {
  for interruption_status in 130 143; do
    export WS_CLONE_STATUS="$interruption_status"
    run run_zsh 'source "$WS_CLONE_SETUP"; ws-clone owner/broken'

    [ "$status" -eq "$interruption_status" ]
    [ -f "$WS_CLONE_WORKSPACE/broken/recovery-marker" ]
    mv "$WS_CLONE_WORKSPACE/broken" "$WS_CLONE_WORKSPACE/interrupted-$interruption_status"
  done
}

@test "ws clone recovery: existing destinations remain untouched while a fresh clone succeeds" {
  mkdir "$WS_CLONE_WORKSPACE/existing"
  printf 'keep existing\n' > "$WS_CLONE_WORKSPACE/existing/marker"
  run run_zsh 'source "$WS_CLONE_SETUP"; ws-clone-multi owner/existing owner/last'

  [ "$status" -eq 0 ]
  [ "$(cat "$WS_CLONE_LOG")" = last ]
  [ "$(cat "$WS_CLONE_WORKSPACE/existing/marker")" = 'keep existing' ]
  [ -f "$WS_CLONE_WORKSPACE/last/content.txt" ]
}

@test "ws clone recovery: colliding destination names fail before any clone" {
  run run_zsh 'source "$WS_CLONE_SETUP"; ws-clone-multi alice/shared bob/shared'

  [ "$status" -eq 2 ]
  [ ! -s "$WS_CLONE_LOG" ]
  [ ! -e "$WS_CLONE_WORKSPACE/shared" ]
}
