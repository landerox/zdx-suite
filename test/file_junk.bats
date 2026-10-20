#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  FILE_JUNK_ORIGINAL_PATH="$PATH"
  load test_helper
  export JUNK_BASE="$HOME/tree"
  mkdir -p "$JUNK_BASE"
}

teardown() {
  # Do not leave a cached command pointing to a mock inside the sandbox.
  PATH="$FILE_JUNK_ORIGINAL_PATH"
  hash -r
  cleanup_sandbox
}

@test "file junk: an empty result reports the clean state without a prompt" {
  : > "$JUNK_BASE/notes.txt"

  run run_zsh '
    cd "$JUNK_BASE" || return 90
    _file_confirm_mutation() { print -u2 -r -- PROMPTED; return 0; }
    file-clean-junk
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"No junk files found."* ]]
  [[ "$output" != *"PROMPTED"* ]]
  [ -f "$JUNK_BASE/notes.txt" ]
}

@test "file junk: a dry run prints the exact plan and deletes nothing" {
  mkdir -p "$JUNK_BASE/docs"
  : > "$JUNK_BASE/.DS_Store"
  : > "$JUNK_BASE/docs/report.pdf:Zone.Identifier"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --dry-run'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Directory:"*"~/tree"* ]]
  [[ "$output" == *"1  .DS_Store"* ]]
  [[ "$output" == *"2  docs/report.pdf:Zone.Identifier"* ]]
  [[ "$output" == *"Dry run: 2 files planned; nothing was deleted."* ]]
  [ -f "$JUNK_BASE/.DS_Store" ]
  [ -f "$JUNK_BASE/docs/report.pdf:Zone.Identifier" ]
  [ -z "$(find "$JUNK_BASE" -name '.zdx-file-delete.*' -print)" ]
}

@test "file junk: a non-interactive run without --yes fails closed" {
  : > "$JUNK_BASE/.DS_Store"

  # run_zsh redirects stdin from /dev/null, so no terminal is attached.
  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk'

  [ "$status" -eq 2 ]
  [[ "$output" == *"pass --yes"* ]]
  [ -f "$JUNK_BASE/.DS_Store" ]
}

@test "file junk: a declined confirmation deletes nothing and returns zero" {
  : > "$JUNK_BASE/Thumbs.db"

  run run_zsh '
    cd "$JUNK_BASE" || return 90
    _file_confirm() { return 1; }
    file-clean-junk
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled: nothing was deleted."* ]]
  [ -f "$JUNK_BASE/Thumbs.db" ]
}

@test "file junk: only exact junk names are deleted and names stay data" {
  # The lowercase thumbs.db lives in its own directory so that a
  # case-insensitive volume (APFS, DrvFs) keeps it distinct from Thumbs.db.
  mkdir -p "$JUNK_BASE/src" "$JUNK_BASE/case"
  local junk
  for junk in \
    .DS_Store Thumbs.db desktop.ini src/._photo.jpg \
    'src/report.pdf:Zone.Identifier' '-rf:Zone.Identifier'; do
    printf '%s\n' junk > "$JUNK_BASE/$junk"
  done
  local similar
  for similar in \
    notes.DS_Store.txt DS_Store .DS_Store.bak Thumbs.db.old case/thumbs.db \
    my-desktop.ini Zone.Identifier 'report:Zone.Identifier.txt' src/_photo.jpg; do
    printf '%s\n' keep > "$JUNK_BASE/$similar"
  done

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes 2>/dev/null'

  [ "$status" -eq 0 ]
  # The command writes no data to stdout.
  [ -z "$output" ]
  for junk in \
    .DS_Store Thumbs.db desktop.ini src/._photo.jpg \
    'src/report.pdf:Zone.Identifier' '-rf:Zone.Identifier'; do
    [ ! -e "$JUNK_BASE/$junk" ]
  done
  for similar in \
    notes.DS_Store.txt DS_Store .DS_Store.bak Thumbs.db.old case/thumbs.db \
    my-desktop.ini Zone.Identifier 'report:Zone.Identifier.txt' src/_photo.jpg; do
    [ "$(cat "$JUNK_BASE/$similar")" = keep ]
  done
  [ -z "$(find "$JUNK_BASE" -name '.zdx-file-delete.*' -print)" ]
}

@test "file junk: names the plan cannot represent are skipped with a warning" {
  printf '%s\n' keep > "$JUNK_BASE/a|b:Zone.Identifier"
  printf '%s\n' keep > "$JUNK_BASE/bad"$'\n'"name:Zone.Identifier"
  : > "$JUNK_BASE/.DS_Store"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped a junk file whose name contains '|': a|b:Zone.Identifier"* ]]
  [[ "$output" == *"Skipped a path whose name contains control characters."* ]]
  [[ "$output" == *"Deletion completed: 1 file deleted."* ]]
  [ ! -e "$JUNK_BASE/.DS_Store" ]
  [ "$(cat "$JUNK_BASE/a|b:Zone.Identifier")" = keep ]
  [ "$(cat "$JUNK_BASE/bad"$'\n'"name:Zone.Identifier")" = keep ]
}

@test "file junk: results and the verdict count every deletion" {
  : > "$JUNK_BASE/.DS_Store"
  : > "$JUNK_BASE/desktop.ini"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleted .DS_Store"* ]]
  [[ "$output" == *"Deleted desktop.ini"* ]]
  [[ "$output" == *"Deletion completed: 2 files deleted."* ]]
}

@test "file junk: a partial failure is counted and marks the timing as partial" {
  [ "$(id -u)" -ne 0 ] || skip "root can rename inside a read-only directory"
  mkdir -p "$JUNK_BASE/locked"
  : > "$JUNK_BASE/.DS_Store"
  printf '%s\n' keep > "$JUNK_BASE/locked/Thumbs.db"
  chmod 500 "$JUNK_BASE/locked"

  run run_zsh 'cd "$JUNK_BASE" && file-menu file-clean-junk --yes'
  chmod 700 "$JUNK_BASE/locked"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Deleted .DS_Store"* ]]
  [[ "$output" == *"Failed (status 1): locked/Thumbs.db"* ]]
  [[ "$output" == *"Deletion completed with partial failures: 1 of 2 files failed."* ]]
  [[ "$output" == *"file:file-clean-junk completed with partial failures"* ]]
  [ ! -e "$JUNK_BASE/.DS_Store" ]
  [ "$(cat "$JUNK_BASE/locked/Thumbs.db")" = keep ]
}

@test "file junk: links and directories with junk names are never followed or deleted" {
  local outside="$HOME/outside"
  mkdir -p "$outside" "$JUNK_BASE/desktop.ini"
  printf '%s\n' keep > "$outside/.DS_Store"
  printf '%s\n' data > "$JUNK_BASE/real.txt"
  ln -s real.txt "$JUNK_BASE/.DS_Store"
  ln -s ../outside/.DS_Store "$JUNK_BASE/Thumbs.db"
  ln -s ../outside "$JUNK_BASE/linked-dir"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'

  [ "$status" -eq 0 ]
  [[ "$output" == *"No junk files found."* ]]
  [ -L "$JUNK_BASE/.DS_Store" ]
  [ -L "$JUNK_BASE/Thumbs.db" ]
  [ -L "$JUNK_BASE/linked-dir" ]
  [ -d "$JUNK_BASE/desktop.ini" ]
  [ "$(cat "$JUNK_BASE/real.txt")" = data ]
  [ "$(cat "$outside/.DS_Store")" = keep ]
}

@test "file junk: Git metadata, generated, and vendored trees are never entered" {
  local pruned
  for pruned in \
    .git/objects node_modules/pkg .venv/lib vendor/x src/vendored/y \
    lib/site-packages/p lib/dist-packages/p .tox/py .nox/session \
    archive.git/objects .tmp/scratch nested/repo/.git/objects; do
    mkdir -p "$JUNK_BASE/$pruned"
  done
  local -a kept=(
    .git/.DS_Store .git/objects/.DS_Store node_modules/pkg/.DS_Store
    .venv/lib/Thumbs.db vendor/x/.DS_Store src/vendored/y/desktop.ini
    lib/site-packages/p/._module.py lib/dist-packages/p/.DS_Store
    .tox/py/.DS_Store .nox/session/.DS_Store archive.git/objects/.DS_Store
    .tmp/scratch/.DS_Store nested/repo/.git/.DS_Store
    nested/repo/.git/objects/Thumbs.db
  )
  for pruned in "${kept[@]}"; do
    printf '%s\n' keep > "$JUNK_BASE/$pruned"
  done
  : > "$JUNK_BASE/.DS_Store"
  : > "$JUNK_BASE/src/Thumbs.db"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Deletion completed: 2 files deleted."* ]]
  [ ! -e "$JUNK_BASE/.DS_Store" ]
  [ ! -e "$JUNK_BASE/src/Thumbs.db" ]
  for pruned in "${kept[@]}"; do
    [ "$(cat "$JUNK_BASE/$pruned")" = keep ]
  done
}

@test "file junk: a folder of repositories plans the junk in every worktree" {
  # Run from a folder such as ~/workspaces: a repository, a linked worktree
  # whose .git is a file, and a repository nested inside another.
  mkdir -p \
    "$JUNK_BASE/app/.git/objects" "$JUNK_BASE/app/docs" \
    "$JUNK_BASE/app/vendor-src/lib/.git" "$JUNK_BASE/feature"
  printf '%s\n' "gitdir: ../app/.git/worktrees/feature" \
    > "$JUNK_BASE/feature/.git"
  : > "$JUNK_BASE/app/docs/report.pdf:Zone.Identifier"
  : > "$JUNK_BASE/app/vendor-src/lib/.DS_Store"
  : > "$JUNK_BASE/feature/Thumbs.db"
  printf '%s\n' keep > "$JUNK_BASE/app/.git/.DS_Store"
  printf '%s\n' keep > "$JUNK_BASE/app/.git/objects/._pack"
  printf '%s\n' keep > "$JUNK_BASE/app/vendor-src/lib/.git/desktop.ini"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --dry-run'

  [ "$status" -eq 0 ]
  [[ "$output" == *"1  app/docs/report.pdf:Zone.Identifier"* ]]
  [[ "$output" == *"2  app/vendor-src/lib/.DS_Store"* ]]
  [[ "$output" == *"3  feature/Thumbs.db"* ]]
  [[ "$output" == *"Dry run: 3 files planned; nothing was deleted."* ]]
  [[ "$output" != *"Skipped"* ]]

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'

  [ "$status" -eq 0 ]
  [ ! -e "$JUNK_BASE/app/docs/report.pdf:Zone.Identifier" ]
  [ ! -e "$JUNK_BASE/app/vendor-src/lib/.DS_Store" ]
  [ ! -e "$JUNK_BASE/feature/Thumbs.db" ]
  [ "$(cat "$JUNK_BASE/app/.git/.DS_Store")" = keep ]
  [ "$(cat "$JUNK_BASE/app/.git/objects/._pack")" = keep ]
  [ "$(cat "$JUNK_BASE/app/vendor-src/lib/.git/desktop.ini")" = keep ]
  [ -f "$JUNK_BASE/feature/.git" ]
}

@test "file junk: unsafe junk files are skipped with a counted warning" {
  printf '%s\n' keep > "$JUNK_BASE/.DS_Store"
  chmod 664 "$JUNK_BASE/.DS_Store"
  printf '%s\n' keep > "$JUNK_BASE/desktop.ini"
  ln "$JUNK_BASE/desktop.ini" "$HOME/desktop.ini.link"
  : > "$JUNK_BASE/Thumbs.db"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'

  [ "$status" -eq 0 ]
  [[ "$output" == *"1  Thumbs.db"* ]]
  [[ "$output" == *"Skipped 2 junk files that cannot be deleted safely: 1 writable by group or others, 1 hard-linked."* ]]
  [[ "$output" == *".DS_Store (writable by group or others)"* ]]
  [[ "$output" == *"desktop.ini (hard-linked)"* ]]
  [[ "$output" == *"Deletion completed: 1 file deleted."* ]]
  [[ "$output" != *"Deleted .DS_Store"* && "$output" != *"Deleted desktop.ini"* ]]
  [ ! -e "$JUNK_BASE/Thumbs.db" ]
  [ "$(cat "$JUNK_BASE/.DS_Store")" = keep ]
  [ "$(cat "$JUNK_BASE/desktop.ini")" = keep ]
}

@test "file junk: many skipped files are listed only under verbosity" {
  mkdir -p "$JUNK_BASE/docs"
  local junk
  for junk in .DS_Store Thumbs.db desktop.ini docs/._notes; do
    : > "$JUNK_BASE/$junk"
    chmod 666 "$JUNK_BASE/$junk"
  done
  : > "$JUNK_BASE/docs/.DS_Store"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --dry-run'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped 4 junk files that cannot be deleted safely: 4 writable by group or others."* ]]
  [[ "$output" == *"Set ZDX_VERBOSE=1 to list them."* ]]
  [[ "$output" != *"(writable by group or others)"* ]]
  [[ "$output" == *"Dry run: 1 file planned; nothing was deleted."* ]]

  run run_zsh 'cd "$JUNK_BASE" && ZDX_VERBOSE=1 file-clean-junk --dry-run'

  [ "$status" -eq 0 ]
  for junk in .DS_Store Thumbs.db desktop.ini docs/._notes; do
    [[ "$output" == *"  $junk (writable by group or others)"* ]]
  done
  [[ "$output" != *"Set ZDX_VERBOSE=1"* ]]
}

@test "file junk: a file owned by another user is skipped and nothing else is a no-op" {
  printf '%s\n' keep > "$JUNK_BASE/.DS_Store"

  # Report another owner for this one file without needing root.
  run run_zsh '
    cd "$JUNK_BASE" || return 90
    zstat() {
      builtin zstat "$@" || return
      [[ "${@[-1]}" == "$JUNK_BASE/.DS_Store" ]] && eval "${2}[uid]=4242"
      return 0
    }
    _file_confirm_mutation() { print -u2 -r -- PROMPTED; return 0; }
    file-clean-junk --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped 1 junk file that cannot be deleted safely: 1 owned by another user."* ]]
  [[ "$output" == *".DS_Store (owned by another user)"* ]]
  [[ "$output" == *"No junk files can be deleted safely."* ]]
  [[ "$output" != *"PROMPTED"* ]]
  [ "$(cat "$JUNK_BASE/.DS_Store")" = keep ]
}

@test "file junk: an unsafe directory above any junk file refuses the whole run" {
  mkdir -p "$JUNK_BASE/shared"
  printf '%s\n' keep > "$JUNK_BASE/shared/.DS_Store"
  printf '%s\n' keep > "$JUNK_BASE/Thumbs.db"
  chmod 777 "$JUNK_BASE/shared"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'
  chmod 755 "$JUNK_BASE/shared"

  [ "$status" -eq 1 ]
  [[ "$output" == *"A parent directory is not trusted against replacement"* ]]
  [[ "$output" == *"a directory above shared/.DS_Store is unsafe or changed"* ]]
  [[ "$output" != *"Deleted"* ]]
  [ "$(cat "$JUNK_BASE/shared/.DS_Store")" = keep ]
  [ "$(cat "$JUNK_BASE/Thumbs.db")" = keep ]
}

@test "file junk: discovery depth is bounded" {
  local deep="$JUNK_BASE/a/b/c/d/e/f/g/h/i/j/k"
  mkdir -p "$deep/l"
  : > "$deep/.DS_Store"
  : > "$deep/l/.DS_Store"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'

  [ "$status" -eq 0 ]
  [ ! -e "$deep/.DS_Store" ]
  [ -f "$deep/l/.DS_Store" ]
}

@test "file junk: an unreadable directory is skipped with a warning" {
  [ "$(id -u)" -ne 0 ] || skip "root can read every directory"
  mkdir -p "$JUNK_BASE/locked" "$JUNK_BASE/src"
  : > "$JUNK_BASE/src/.DS_Store"
  chmod 000 "$JUNK_BASE/locked"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'
  chmod 700 "$JUNK_BASE/locked"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped a directory that cannot be read: locked"* ]]
  [ ! -e "$JUNK_BASE/src/.DS_Store" ]
}

@test "file junk: inventory failures preserve status and plan nothing" {
  : > "$JUNK_BASE/.DS_Store"

  run run_zsh '
    cd "$JUNK_BASE" || exit 90
    file-menu --help >/dev/null 2>&1 || exit 91
    _file_collect_paths() { reply=(.DS_Store); return "$scan_rc"; }
    for scan_rc in 1 42 130 143; do
      file-clean-junk --yes 2>"$TEST_TEMP_DIR/stderr"
      actual_rc=$?
      (( actual_rc == scan_rc )) || exit 92
      [[ "$(<"$TEST_TEMP_DIR/stderr")" != *"Deleted"* ]] || exit 93
    done
  '

  [ "$status" -eq 0 ]
  [ -f "$JUNK_BASE/.DS_Store" ]
}

@test "file junk: an unsafe operation base is refused before discovery" {
  : > "$JUNK_BASE/.DS_Store"
  chmod 775 "$JUNK_BASE"

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'
  chmod 700 "$JUNK_BASE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"group/world-writable"* ]]
  [ -f "$JUNK_BASE/.DS_Store" ]
}

@test "file junk: a target changed after confirmation rejects the whole plan" {
  printf '%s\n' first > "$JUNK_BASE/.DS_Store"
  printf '%s\n' planned > "$JUNK_BASE/Thumbs.db"

  run run_zsh '
    cd "$JUNK_BASE" || return 90
    _file_confirm_mutation() {
      command mv Thumbs.db Thumbs.db.planned || return 91
      print -r -- replacement > Thumbs.db
    }
    file-clean-junk --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed identity before execution"* ]]
  [[ "$output" != *"Deleted"* ]]
  [ "$(cat "$JUNK_BASE/.DS_Store")" = first ]
  [ "$(cat "$JUNK_BASE/Thumbs.db")" = replacement ]
  [ "$(cat "$JUNK_BASE/Thumbs.db.planned")" = planned ]
}

@test "file junk: a base swapped during confirmation changes nothing" {
  local moved="$HOME/tree-moved" victim="$HOME/victim"
  mkdir -p "$victim"
  printf '%s\n' project > "$JUNK_BASE/.DS_Store"
  printf '%s\n' victim > "$victim/.DS_Store"
  export JUNK_MOVED="$moved" JUNK_VICTIM="$victim"

  run run_zsh '
    cd "$JUNK_BASE" || return 90
    _file_confirm_mutation() {
      command mv "$JUNK_BASE" "$JUNK_MOVED" || return 91
      command ln -s "$JUNK_VICTIM" "$JUNK_BASE" || return 92
    }
    file-clean-junk --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed before execution"* ]]
  [ -L "$JUNK_BASE" ]
  [ "$(cat "$moved/.DS_Store")" = project ]
  [ "$(cat "$victim/.DS_Store")" = victim ]
}

@test "file junk: an interrupted deletion retains its quarantine and leaves later targets" {
  export FILE_REAL_RM
  FILE_REAL_RM=$(command -v rm)
  cat <<'EOF' > "$TEST_MOCK_BIN/rm"
#!/usr/bin/env bash
for operand in "$@"; do
  if [[ "$operand" == "$JUNK_BASE"/.zdx-file-delete.* ]]; then
    exit "$FILE_DELETE_STATUS"
  fi
done
exec "$FILE_REAL_RM" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/rm"
  for interrupt_status in 130 143; do
    export FILE_DELETE_STATUS="$interrupt_status"
    printf '%s\n' first > "$JUNK_BASE/.DS_Store"
    printf '%s\n' second > "$JUNK_BASE/Thumbs.db"
    run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --yes'
    [ "$status" -eq "$interrupt_status" ]
    [ ! -e "$JUNK_BASE/.DS_Store" ]
    [ "$(cat "$JUNK_BASE/Thumbs.db")" = second ]
    [[ "$output" == *"Recovery path:"* ]]
    [[ "$output" == *"Deletion interrupted"* ]]
    [[ "$output" == *"Not run: 1 file"* ]]
    run run_zsh '
      recovery=("$JUNK_BASE"/.zdx-file-delete.*(N))
      (( ${#recovery} == 1 )) && [[ "$(<${recovery[1]})" == first ]] || return 1
      "$FILE_REAL_RM" -- "${recovery[1]}"
    '
    [ "$status" -eq 0 ]
  done
}

@test "file junk: the command grammar fails closed" {
  run run_zsh 'file-clean-junk --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"*:Zone.Identifier, .DS_Store, ._* (AppleDouble), Thumbs.db, desktop.ini"* ]]

  run run_zsh 'file-clean-junk --help --yes'
  [ "$status" -eq 2 ]

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk --force'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --force"* ]]

  run run_zsh 'cd "$JUNK_BASE" && file-clean-junk .'
  [ "$status" -eq 2 ]
}

@test "file junk: the File entrypoint dispatches the dry run" {
  : > "$JUNK_BASE/._notes.txt"

  run run_zsh 'cd "$JUNK_BASE" && file-menu file-clean-junk --dry-run'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: 1 file planned; nothing was deleted."* ]]
  [ -f "$JUNK_BASE/._notes.txt" ]
}
