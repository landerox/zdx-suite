#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  export GIT_RECOVERY_REAL_GIT
  GIT_RECOVERY_REAL_GIT="$(type -P git)"
  load test_helper
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  export GIT_RECOVERY_REPO="$HOME/repository"
  export GIT_RECOVERY_LOG="$HOME/mutation.calls"
  export GIT_RECOVERY_FAIL_ACTION="" GIT_RECOVERY_FAIL_AT=2 GIT_RECOVERY_FAIL_RC=130
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
elif (( ${received[(Ie)clean]} )); then
  action=clean
fi
if [[ -n "$action" && "$action" == "$GIT_RECOVERY_FAIL_ACTION" ]]; then
  print -r -- "$action:${received[-1]}" >> "$GIT_RECOVERY_LOG"
  typeset -a calls=("${(@f)$(<"$GIT_RECOVERY_LOG")}")
  (( ${#calls[@]} == GIT_RECOVERY_FAIL_AT )) && exit "$GIT_RECOVERY_FAIL_RC"
fi
exec "$GIT_RECOVERY_REAL_GIT" "$@"
EOF
  # The discard picker lists the all-changes rows first; these tests select
  # every file row so they exercise the per-file restore batch.
  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env zsh
typeset -a rows=()
typeset row="" prompt="" argument=""
while IFS= read -r row; do rows+=("$row"); done
for argument in "$@"; do
  [[ "$argument" == --prompt=* ]] && prompt="${argument#--prompt=}"
done
case "$prompt" in
  'git discard > ')
    for row in "${rows[@]}"; do
      [[ "$row" == *$'\t'"Discard all changes"* ]] || print -r -- "$row"
    done
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/git" "$TEST_MOCK_BIN/fzf"
}

teardown() {
  cleanup_sandbox
}

@test "git local recovery: discard interruptions leave later files untouched" {
  export GIT_RECOVERY_FAIL_ACTION=restore
  for interruption_status in 130 143; do
    printf 'changed a\n' > "$GIT_RECOVERY_REPO/a.txt"
    printf 'changed b\n' > "$GIT_RECOVERY_REPO/b.txt"
    printf 'changed c\n' > "$GIT_RECOVERY_REPO/c.txt"
    : > "$GIT_RECOVERY_LOG"
    export GIT_RECOVERY_FAIL_RC="$interruption_status"
    run run_zsh '
      source "$ZSH_CUSTOM/functions/git-menu.zsh"
      unfunction command
      cd "$GIT_RECOVERY_REPO" || return 99
      git-discard --yes
    '
    [ "$status" -eq "$interruption_status" ]
    [ "$(cat "$GIT_RECOVERY_REPO/a.txt")" = 'base a' ]
    [ "$(cat "$GIT_RECOVERY_REPO/b.txt")" = 'changed b' ]
    [ "$(cat "$GIT_RECOVERY_REPO/c.txt")" = 'changed c' ]
    [ "$(wc -l < "$GIT_RECOVERY_LOG")" -eq 2 ]
    [[ "$output" == *'Discard File Changes'* ]]
    [[ "$output" == *'– c.txt — not run'* ]]
    [[ "$output" == *'Discard interrupted: 1 discarded, 1 failed, 1 not run.'* ]]
  done
}

@test "git local recovery: ordinary discard failures continue independent targets" {
  export GIT_RECOVERY_FAIL_ACTION=restore GIT_RECOVERY_FAIL_RC=23
  printf 'changed a\n' > "$GIT_RECOVERY_REPO/a.txt"
  printf 'changed b\n' > "$GIT_RECOVERY_REPO/b.txt"
  printf 'changed c\n' > "$GIT_RECOVERY_REPO/c.txt"
  : > "$GIT_RECOVERY_LOG"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    unfunction command
    cd "$GIT_RECOVERY_REPO" || return 99
    git-discard --yes
  '
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$GIT_RECOVERY_LOG")" -eq 3 ]
  [ "$(cat "$GIT_RECOVERY_REPO/b.txt")" = 'changed b' ]
  [ "$(cat "$GIT_RECOVERY_REPO/c.txt")" = 'base c' ]
  [[ "$output" == *'Discard completed with partial failures: 1 of 3 files failed.'* ]]
}

@test "git local recovery: an interrupted all-changes discard stops before later files" {
  export GIT_RECOVERY_FAIL_ACTION=restore
  for interruption_status in 130 143; do
    printf 'changed a\n' > "$GIT_RECOVERY_REPO/a.txt"
    printf 'staged b\n' > "$GIT_RECOVERY_REPO/b.txt"
    "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" add -- b.txt
    printf 'changed c\n' > "$GIT_RECOVERY_REPO/c.txt"
    printf 'keep me\n' > "$GIT_RECOVERY_REPO/untracked.txt"
    : > "$GIT_RECOVERY_LOG"
    export GIT_RECOVERY_FAIL_RC="$interruption_status"
    run run_zsh '
      source "$ZSH_CUSTOM/functions/git-menu.zsh"
      unfunction command
      cd "$GIT_RECOVERY_REPO" || return 99
      git-discard --all --include-untracked --yes
    '
    [ "$status" -eq "$interruption_status" ]
    [ "$(cat "$GIT_RECOVERY_REPO/a.txt")" = 'base a' ]
    [ "$(cat "$GIT_RECOVERY_REPO/b.txt")" = 'staged b' ]
    [ "$("$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" diff --cached --name-only)" = 'b.txt' ]
    [ "$(cat "$GIT_RECOVERY_REPO/c.txt")" = 'changed c' ]
    [ "$(cat "$GIT_RECOVERY_REPO/untracked.txt")" = 'keep me' ]
    [ "$(wc -l < "$GIT_RECOVERY_LOG")" -eq 2 ]
    [[ "$output" == *'– c.txt — not run'* ]]
    [[ "$output" == *'– untracked.txt — not run'* ]]
    [[ "$output" == *'Discard interrupted: 1 discarded, 1 failed, 2 not run.'* ]]
    "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" reset -q --hard
    rm -f -- "$GIT_RECOVERY_REPO/untracked.txt"
  done
}

@test "git local recovery: an interrupted untracked deletion keeps later untracked files" {
  export GIT_RECOVERY_FAIL_ACTION=clean GIT_RECOVERY_FAIL_RC=130
  printf 'changed a\n' > "$GIT_RECOVERY_REPO/a.txt"
  printf 'one\n' > "$GIT_RECOVERY_REPO/u1.txt"
  printf 'two\n' > "$GIT_RECOVERY_REPO/u2.txt"
  printf 'three\n' > "$GIT_RECOVERY_REPO/u3.txt"
  : > "$GIT_RECOVERY_LOG"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh"
    unfunction command
    cd "$GIT_RECOVERY_REPO" || return 99
    git-discard --all --include-untracked --yes
  '
  [ "$status" -eq 130 ]
  [ "$(cat "$GIT_RECOVERY_REPO/a.txt")" = 'base a' ]
  [ ! -e "$GIT_RECOVERY_REPO/u1.txt" ]
  [ "$(cat "$GIT_RECOVERY_REPO/u2.txt")" = 'two' ]
  [ "$(cat "$GIT_RECOVERY_REPO/u3.txt")" = 'three' ]
  [[ "$output" == *'– u3.txt — not run'* ]]
  [[ "$output" == *'Discard interrupted: 2 discarded, 1 failed, 1 not run.'* ]]
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
    [[ "$output" == *'— not run'* ]]
    [[ "$output" == *'Drop interrupted: 1 dropped, 1 failed, 1 not run.'* ]]
    "$GIT_RECOVERY_REAL_GIT" -C "$GIT_RECOVERY_REPO" stash clear
  done
}
