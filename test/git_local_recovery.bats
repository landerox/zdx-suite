#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  export GIT_RECOVERY_REAL_GIT
  GIT_RECOVERY_REAL_GIT="$(type -P git)"
  load test_helper
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
  export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  export GIT_RECOVERY_REPO="$HOME/repository"
  export GIT_RECOVERY_LOG="$HOME/mutation.calls"
  export GIT_RECOVERY_FAIL_ACTION="" GIT_RECOVERY_FAIL_AT=2 GIT_RECOVERY_FAIL_RC=130
  export GIT_RECOVERY_PICK_ACTION='Pick commits from another ref'
  "$GIT_RECOVERY_REAL_GIT" init -q -b main "$GIT_RECOVERY_REPO"
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" config user.name 'Recovery Test'
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" config user.email 'recovery@example.invalid'
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" config core.hooksPath /dev/null
  printf 'base a\n' > "$GIT_RECOVERY_REPO/a.txt"
  printf 'base b\n' > "$GIT_RECOVERY_REPO/b.txt"
  printf 'base c\n' > "$GIT_RECOVERY_REPO/c.txt"
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" add -- a.txt b.txt c.txt
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" commit -q -m base
  : > "$GIT_RECOVERY_LOG"

  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env zsh
typeset -a received=("$@")
typeset action=""
if (( ${received[(Ie)stash]} && ${received[(Ie)drop]} )); then
  action=drop
elif (( ${received[(Ie)restore]} )); then
  action=restore
fi
if [[ -n "$action" && "$action" == "$GIT_RECOVERY_FAIL_ACTION" ]]; then
  print -r -- "$action:${received[-1]}" >> "$GIT_RECOVERY_LOG"
  typeset -a calls=("${(@f)$(<"$GIT_RECOVERY_LOG")}")
  (( ${#calls[@]} == GIT_RECOVERY_FAIL_AT )) && exit "$GIT_RECOVERY_FAIL_RC"
fi
exec "$GIT_RECOVERY_REAL_GIT" "$@"
EOF
  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env zsh
typeset -a rows=()
typeset row="" prompt="" argument=""
while IFS= read -r row; do rows+=("$row"); done
for argument in "$@"; do
  [[ "$argument" == --prompt=* ]] && prompt="${argument#--prompt=}"
done
case "$prompt" in
  'git cherry-pick > ')
    print -r -- "$GIT_RECOVERY_PICK_ACTION"
    ;;
  'cherry-pick ref > ')
    for row in "${rows[@]}"; do
      [[ "$row" == *$'\tfeature' ]] && { print -r -- "$row"; exit 0; }
    done
    exit 97
    ;;
  'cherry-pick commits > ')
    # Reverse selection order to require the documented oldest-first plan.
    print -rl -- "${(@Oa)rows}"
    ;;
  'git discard > '|'restore files > ')
    print -rl -- "${rows[@]}"
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/git" "$TEST_MOCK_BIN/fzf"
}

teardown() {
  cleanup_sandbox
}

make_cherry_pick_topic() {
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" switch -q -c feature
  printf 'feature a\n' > "$GIT_RECOVERY_REPO/a.txt"
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" commit -qam first
  export GIT_RECOVERY_FIRST_OID
  GIT_RECOVERY_FIRST_OID="$("$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" rev-parse HEAD)"
  printf 'feature b\n' > "$GIT_RECOVERY_REPO/b.txt"
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" commit -qam second
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" switch -q main
}

make_cherry_pick_conflict() {
  make_cherry_pick_topic
  printf 'main a\n' > "$GIT_RECOVERY_REPO/a.txt"
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" commit -qam divergent
}

@test "git local recovery: multiple cherry-picks retain distinct IDs and execute oldest first" {
  make_cherry_pick_topic
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    unfunction command
    cd "$GIT_RECOVERY_REPO" || return 99
    _git_changes_authorize() { REPLY=authorized; }
    git-cherry-pick > "$HOME/operation.stdout"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$HOME/operation.stdout" ]
  [ "$("$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" log -2 --format=%s)" = $'second\nfirst' ]
  [ "$(cat "$GIT_RECOVERY_REPO/a.txt")" = 'feature a' ]
  [ "$(cat "$GIT_RECOVERY_REPO/b.txt")" = 'feature b' ]
  [ ! -d "$GIT_RECOVERY_REPO/.git/sequencer" ]
}

@test "git local recovery: a conflicting cherry-pick retains later commits for continue" {
  make_cherry_pick_conflict
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    unfunction command
    cd "$GIT_RECOVERY_REPO" || return 99
    _git_changes_authorize() { REPLY=authorized; }
    git-cherry-pick
  '
  [ "$status" -eq 1 ]
  [ -f "$GIT_RECOVERY_REPO/.git/sequencer/todo" ]
  [ "$(cat "$GIT_RECOVERY_REPO/.git/CHERRY_PICK_HEAD")" = "$GIT_RECOVERY_FIRST_OID" ]
  [ "$(cat "$GIT_RECOVERY_REPO/b.txt")" = 'base b' ]

  printf 'resolved a\n' > "$GIT_RECOVERY_REPO/a.txt"
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" add -- a.txt
  export GIT_RECOVERY_PICK_ACTION='Continue an in-progress cherry-pick'
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    unfunction command
    cd "$GIT_RECOVERY_REPO" || return 99
    git-cherry-pick
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$GIT_RECOVERY_REPO/b.txt")" = 'feature b' ]
  [ ! -d "$GIT_RECOVERY_REPO/.git/sequencer" ]
}

@test "git local recovery: abort restores the beginning of the complete cherry-pick sequence" {
  make_cherry_pick_topic
  printf 'main b\n' > "$GIT_RECOVERY_REPO/b.txt"
  "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" commit -qam divergent
  initial_head="$("$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" rev-parse HEAD)"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    unfunction command
    cd "$GIT_RECOVERY_REPO" || return 99
    _git_changes_authorize() { REPLY=authorized; }
    git-cherry-pick
  '
  [ "$status" -eq 1 ]
  [ -f "$GIT_RECOVERY_REPO/.git/sequencer/todo" ]
  [ "$(cat "$GIT_RECOVERY_REPO/a.txt")" = 'feature a' ]
  export GIT_RECOVERY_PICK_ACTION='Abort an in-progress cherry-pick'
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    unfunction command
    cd "$GIT_RECOVERY_REPO" || return 99
    _git_changes_authorize() { REPLY=authorized; }
    git-cherry-pick
  '
  [ "$status" -eq 0 ]
  [ "$("$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" rev-parse HEAD)" = "$initial_head" ]
  [ "$(cat "$GIT_RECOVERY_REPO/a.txt")" = 'base a' ]
  [ "$(cat "$GIT_RECOVERY_REPO/b.txt")" = 'main b' ]
  [ ! -d "$GIT_RECOVERY_REPO/.git/sequencer" ]
}

@test "git local recovery: declining a multi-commit plan creates no sequence or commits" {
  make_cherry_pick_topic
  initial_head="$("$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" rev-parse HEAD)"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    unfunction command
    cd "$GIT_RECOVERY_REPO" || return 99
    _git_changes_authorize() { REPLY=cancelled; }
    git-cherry-pick
  '
  [ "$status" -eq 0 ]
  [ "$("$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" rev-parse HEAD)" = "$initial_head" ]
  [ ! -d "$GIT_RECOVERY_REPO/.git/sequencer" ]
}

@test "git local recovery: stash drop interruptions retain later entries and exact status" {
  export GIT_RECOVERY_FAIL_ACTION=drop
  for interruption_status in 130 143; do
    for stash_number in 1 2 3; do
      printf 'stash %s for interruption %s\n' "$stash_number" "$interruption_status" \
        > "$GIT_RECOVERY_REPO/a.txt"
      "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" stash push \
        -qm "stash $stash_number for interruption $interruption_status"
    done
    original_oids="$("$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" stash list --format=%H)"
    : > "$GIT_RECOVERY_LOG"
    export GIT_RECOVERY_FAIL_RC="$interruption_status"
    run run_zsh '
      source "$ZSH_CUSTOM/functions/git-menu.zsh"
      unfunction command
      cd "$GIT_RECOVERY_REPO" || return 99
      git-stash drop "stash@{0}" "stash@{1}" "stash@{2}" --yes
    '
    [ "$status" -eq "$interruption_status" ]
    [ "$(wc -l < "$GIT_RECOVERY_LOG")" -eq 2 ]
    [ "$("$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" stash list --format=%H)" = "${original_oids#*$'\n'}" ]
    [[ "$output" == *'1 passed, 1 failed, 1 not run'* ]]
  done
}

@test "git local recovery: discard and restore interruptions leave later files untouched" {
  export GIT_RECOVERY_FAIL_ACTION=restore
  for operation in discard restore; do
    for interruption_status in 130 143; do
      printf 'changed a\n' > "$GIT_RECOVERY_REPO/a.txt"
      printf 'changed b\n' > "$GIT_RECOVERY_REPO/b.txt"
      printf 'changed c\n' > "$GIT_RECOVERY_REPO/c.txt"
      : > "$GIT_RECOVERY_LOG"
      export GIT_RECOVERY_FAIL_RC="$interruption_status" GIT_RECOVERY_OPERATION="$operation"
      run run_zsh '
        source "$ZSH_CUSTOM/functions/git-menu.zsh"
        unfunction command
        cd "$GIT_RECOVERY_REPO" || return 99
        if [[ "$GIT_RECOVERY_OPERATION" == discard ]]; then
          git-discard --yes
        else
          git-restore-from --source HEAD --yes
        fi
      '
      [ "$status" -eq "$interruption_status" ]
      [ "$(cat "$GIT_RECOVERY_REPO/a.txt")" = 'base a' ]
      [ "$(cat "$GIT_RECOVERY_REPO/b.txt")" = 'changed b' ]
      [ "$(cat "$GIT_RECOVERY_REPO/c.txt")" = 'changed c' ]
      [ "$(wc -l < "$GIT_RECOVERY_LOG")" -eq 2 ]
      [[ "$output" == *'1 passed, 1 failed, 1 not run'* ]]
    done
  done
}

@test "git local recovery: ordinary restore failures continue independent targets" {
  export GIT_RECOVERY_FAIL_ACTION=restore GIT_RECOVERY_FAIL_RC=23
  for operation in discard restore; do
    printf 'changed a\n' > "$GIT_RECOVERY_REPO/a.txt"
    printf 'changed b\n' > "$GIT_RECOVERY_REPO/b.txt"
    printf 'changed c\n' > "$GIT_RECOVERY_REPO/c.txt"
    : > "$GIT_RECOVERY_LOG"
    export GIT_RECOVERY_OPERATION="$operation"
    run run_zsh '
      source "$ZSH_CUSTOM/functions/git-menu.zsh"
      unfunction command
      cd "$GIT_RECOVERY_REPO" || return 99
      if [[ "$GIT_RECOVERY_OPERATION" == discard ]]; then
        git-discard --yes
      else
        git-restore-from --source HEAD --yes
      fi
    '
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$GIT_RECOVERY_LOG")" -eq 3 ]
    [ "$(cat "$GIT_RECOVERY_REPO/b.txt")" = 'changed b' ]
    [ "$(cat "$GIT_RECOVERY_REPO/c.txt")" = 'base c' ]
    [[ "$output" == *'2 passed, 1 failed'* ]]
  done
}
