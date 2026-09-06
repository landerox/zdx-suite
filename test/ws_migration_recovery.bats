#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export WS_RECOVERY_SOURCE="$HOME/source repos"
  export WS_RECOVERY_DEST="$HOME/workspaces/github/test"
  export WS_RECOVERY_REAL_GIT
  WS_RECOVERY_REAL_GIT=$(command -v git)
  mkdir -p "$WS_RECOVERY_SOURCE" "$WS_RECOVERY_DEST/.ssh"
  : > "$WS_RECOVERY_DEST/.gitconfig"
  "$WS_RECOVERY_REAL_GIT" init -q "$WS_RECOVERY_SOURCE/repository"
  "$WS_RECOVERY_REAL_GIT" -C "$WS_RECOVERY_SOURCE/repository" \
    remote add origin https://github.com/example/repository.git
  export WS_RECOVERY_MODE=normal
  export WS_RECOVERY_SELECTED=repository
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -C && "${2:-}" == "$WS_RECOVERY_DEST/repository" && "${3:-}" == remote ]]; then
  printf '%s\n' "${*:3}" >> "$HOME/migration-remote-calls"
  case "$WS_RECOVERY_MODE:${4:-}" in
    list-failure:) exit 42 ;;
    get-failure:get-url) exit 42 ;;
    silent-set:set-url) exit 0 ;;
    interrupt-set:set-url) exit "$WS_RECOVERY_INTERRUPT" ;;
    interrupt-get:get-url) exit "$WS_RECOVERY_INTERRUPT" ;;
  esac
fi
exec "$WS_RECOVERY_REAL_GIT" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/git"
}

teardown() {
  cleanup_sandbox
}

run_migration() {
  run run_zsh '
    _ws_migrate_interactive_available() { return 0; }
    read() { source_dir="$WS_RECOVERY_SOURCE"; }
    _ws_capture_workspace_selection() { REPLY="github/test"; }
    _ws_fzf_capture() { REPLY="$WS_RECOVERY_SELECTED"; }
    _tk_confirm() { [[ "$1" != *"now empty"* ]]; }
    ws-migrate > "$HOME/migration-stdout"
  '
}

@test "ws migration recovery: unreadable origin is a partial failure after the move" {
  export WS_RECOVERY_MODE=get-failure
  run_migration
  [ "$status" -eq 1 ]
  [ -d "$WS_RECOVERY_DEST/repository/.git" ]
  [ ! -e "$WS_RECOVERY_SOURCE/repository" ]
  [ ! -s "$HOME/migration-stdout" ]
  [[ "$output" == *"could not inspect its origin"* ]]
  [[ "$output" != *"Migration complete!"* ]]
  run "$WS_RECOVERY_REAL_GIT" -C "$WS_RECOVERY_DEST/repository" remote get-url origin
  [ "$status" -eq 0 ]
  [ "$output" = https://github.com/example/repository.git ]
}

@test "ws migration recovery: failed remote enumeration is not absence" {
  export WS_RECOVERY_MODE=list-failure
  run_migration
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not inspect its origin"* ]]
  [[ "$output" != *"Migration complete!"* ]]
}

@test "ws migration recovery: confirmed absent origin needs no rewrite" {
  "$WS_RECOVERY_REAL_GIT" -C "$WS_RECOVERY_SOURCE/repository" remote remove origin
  run_migration
  [ "$status" -eq 0 ]
  [ -d "$WS_RECOVERY_DEST/repository/.git" ]
  [[ "$output" == *"Migration complete!"* ]]
  [ "$(cat "$HOME/migration-remote-calls")" = remote ]
}

@test "ws migration recovery: a successful setter must actually update origin" {
  export WS_RECOVERY_MODE=silent-set
  run_migration
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not verify its updated origin"* ]]
  [[ "$output" != *"Migration complete!"* ]]
}

@test "ws migration recovery: a verified rewrite reports success" {
  run_migration
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/migration-stdout" ]
  [[ "$output" == *"Migration complete!"* ]]
  run "$WS_RECOVERY_REAL_GIT" -C "$WS_RECOVERY_DEST/repository" remote get-url origin
  [ "$status" -eq 0 ]
  [ "$output" = git@github-test:example/repository.git ]
}

@test "ws migration recovery: origin inspection and rewrite interruptions stop later moves" {
  "$WS_RECOVERY_REAL_GIT" init -q "$WS_RECOVERY_SOURCE/second"
  export WS_RECOVERY_SELECTED=$'repository\nsecond'
  local mode code
  for mode in interrupt-get interrupt-set; do
    for code in 130 143; do
      export WS_RECOVERY_MODE="$mode" WS_RECOVERY_INTERRUPT="$code"
      run_migration
      [ "$status" -eq "$code" ]
      [ -d "$WS_RECOVERY_SOURCE/second/.git" ]
      [ ! -e "$WS_RECOVERY_DEST/second" ]
      [[ "$output" == *"remaining repositories were not attempted"* ]]
      mv "$WS_RECOVERY_DEST/repository" "$WS_RECOVERY_SOURCE/repository"
    done
  done
}

@test "ws migration recovery: an ordinary origin failure permits independent later moves" {
  "$WS_RECOVERY_REAL_GIT" init -q "$WS_RECOVERY_SOURCE/second"
  export WS_RECOVERY_SELECTED=$'repository\nsecond'
  export WS_RECOVERY_MODE=get-failure
  run_migration
  [ "$status" -eq 1 ]
  [ -d "$WS_RECOVERY_DEST/repository/.git" ]
  [ -d "$WS_RECOVERY_DEST/second/.git" ]
  [[ "$output" == *"Migrated second"* ]]
  [[ "$output" == *"1 partial failure(s)"* ]]
  [[ "$output" != *"Migration complete!"* ]]
}
