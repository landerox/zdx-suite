#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
#
# file-trash: rename-only trash, strict records, no-clobber restore, and
# purge through the quarantined File deletion engine. HOME and the trash
# stay inside the sandbox.

setup() {
  FILE_TRASH_ORIGINAL_PATH="$PATH"
  load test_helper
  export WORK="$HOME/work"
  export TRASH="$HOME/.local/share/zdx/trash"
  mkdir -p "$WORK"
}

teardown() {
  # Do not leave a cached command pointing to a mock inside the sandbox.
  PATH="$FILE_TRASH_ORIGINAL_PATH"
  hash -r
  cleanup_sandbox
}

# trash_ids: the IDs of the records in the sandbox trash, one per line.
trash_ids() {
  local record
  for record in "$TRASH"/info/*.trashinfo; do
    [[ -e "$record" ]] || continue
    record="${record##*/}"
    printf '%s\n' "${record%.trashinfo}"
  done
}

# make_trash_dirs: an empty trash with the private layout put creates.
make_trash_dirs() {
  mkdir -p "$TRASH/files" "$TRASH/info"
  chmod 700 "$HOME/.local" "$HOME/.local/share" "$HOME/.local/share/zdx" \
    "$TRASH" "$TRASH/files" "$TRASH/info"
}

# write_record ID PATH-VALUE [DATE]: a hand-made record with an item.
write_record() {
  local id="$1" path_value="$2" date="${3:-2026-01-02T03:04:05}"
  make_trash_dirs
  printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' "$path_value" "$date" \
    > "$TRASH/info/$id.trashinfo"
  chmod 600 "$TRASH/info/$id.trashinfo"
  printf 'payload\n' > "$TRASH/files/$id"
}

# mock_kernel NAME: uname -s reports NAME.
mock_kernel() {
  cat > "$TEST_MOCK_BIN/uname" <<SH
#!/usr/bin/env bash
printf '%s\n' '$1'
SH
  chmod +x "$TEST_MOCK_BIN/uname"
}

# mount_table [MOUNT-POINT...]: a Linux mount table with / and each point.
mount_table() {
  export TRASH_MOUNTINFO="$TEST_TEMP_DIR/mountinfo"
  printf '1 0 0:1 / / rw - ext4 /dev/root rw\n' > "$TRASH_MOUNTINFO"
  local index=2 mount_point
  for mount_point in "$@"; do
    printf '%s 1 0:1 / %s rw - ext4 /dev/root rw\n' "$index" "$mount_point" \
      >> "$TRASH_MOUNTINFO"
    index=$((index + 1))
  done
}

@test "file trash: help and the action grammar fail closed" {
  run run_zsh 'file-trash --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"file-trash put [--dry-run] [--yes] [--] PATH..."* ]]
  [[ "$output" == *"file-trash list [--json]"* ]]

  run run_zsh 'file-trash restore --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]

  local -a invalid=(
    "--help --yes"
    "frobnicate"
    "--force"
    "put"
    "list --dry-run"
    "list extra"
    "put --json a"
    "restore --all"
    "list --older-than 3"
    "purge --all --older-than 3"
    "purge 20260101-000000-abcdef --all"
    "purge --older-than"
    "purge --older-than abc"
    "purge --older-than 99999"
    "purge --older-than 1 --older-than 2"
    "restore not-an-id"
    "restore 20260101-000000-abcdef 20260101-000000-abcdef"
    "-- put a"
  )
  local arguments
  for arguments in "${invalid[@]}"; do
    run run_zsh "cd \"\$WORK\" && file-trash $arguments"
    [ "$status" -eq 2 ] || {
      printf 'arguments: %s\nstatus: %s\n%s\n' "$arguments" "$status" "$output"
      return 1
    }
  done
  [ ! -e "$HOME/.local/share/zdx" ]
}

@test "file trash: put, list, and restore round-trip files, directories, links, and odd names" {
  mkdir -p "$WORK/dir/nested"
  printf 'spaces\n' > "$WORK/a file.txt"
  printf 'dash\n' > "$WORK/-rf"
  printf 'inner\n' > "$WORK/dir/nested/inner"
  ln -s "a file.txt" "$WORK/link"
  local before_file before_dir
  before_file=$(file_identity "$WORK/a file.txt")
  before_dir=$(file_identity "$WORK/dir")

  run run_zsh 'cd "$WORK" && file-trash put --yes -- "a file.txt" -rf dir link'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Trashed a file.txt as "* ]]
  [[ "$output" == *"Trashed -rf as "* ]]
  [[ "$output" == *"Trash completed: 4 items moved."* ]]
  [ ! -e "$WORK/a file.txt" ] && [ ! -e "$WORK/-rf" ]
  [ ! -e "$WORK/dir" ] && [ ! -L "$WORK/link" ]
  [ "$(trash_ids | wc -l)" -eq 4 ]

  # Items moved by rename: the inode survives in the trash.
  local id original moved_link=""
  for id in $(trash_ids); do
    original=$(sed -n 's/^Path=//p' "$TRASH/info/$id.trashinfo")
    case "$original" in
      */a%20file.txt) [ "$(file_identity "$TRASH/files/$id")" = "$before_file" ] ;;
      */dir) [ "$(file_identity "$TRASH/files/$id")" = "$before_dir" ] ;;
      */link) moved_link="$TRASH/files/$id" ;;
    esac
  done
  [ -L "$moved_link" ]
  [ "$(readlink "$moved_link")" = "a file.txt" ]

  run run_zsh 'cd "$WORK" && file-trash list'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID"*"Deleted"*"Type"*"Size"*"Original path"* ]]
  [[ "$output" == *"symlink"* && "$output" == *"directory"* ]]
  [[ "$output" == *"~/work/-rf"* ]]

  run run_zsh 'file-trash restore --yes $(command ls "$TRASH/info" | command sed "s/[.]trashinfo\$//")'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore completed: 4 items restored."* ]]
  [ "$(cat "$WORK/a file.txt")" = spaces ]
  [ "$(cat "$WORK/-rf")" = dash ]
  [ "$(cat "$WORK/dir/nested/inner")" = inner ]
  [ -L "$WORK/link" ] && [ "$(readlink "$WORK/link")" = "a file.txt" ]
  [ "$(file_identity "$WORK/a file.txt")" = "$before_file" ]
  [ "$(file_identity "$WORK/dir")" = "$before_dir" ]
  [ -z "$(trash_ids)" ]
  [ -z "$(ls -A "$TRASH/files")" ] && [ -z "$(ls -A "$TRASH/info")" ]
}

@test "file trash: the trash is private and records use the freedesktop format" {
  printf 'data\n' > "$WORK/notes 100%.txt"

  run run_zsh 'cd "$WORK" && file-trash put --yes -- "notes 100%.txt"'
  [ "$status" -eq 0 ]
  [ "$(file_mode "$TRASH")" = 700 ]
  [ "$(file_mode "$TRASH/files")" = 700 ]
  [ "$(file_mode "$TRASH/info")" = 700 ]
  local id
  id=$(trash_ids)
  [[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]]
  [ "$(file_mode "$TRASH/info/$id.trashinfo")" = 600 ]
  [ "$(file_links "$TRASH/info/$id.trashinfo")" = 1 ]
  [ "$(sed -n 1p "$TRASH/info/$id.trashinfo")" = "[Trash Info]" ]
  [ "$(sed -n 2p "$TRASH/info/$id.trashinfo")" = "Path=$WORK/notes%20100%25.txt" ]
  [[ "$(sed -n 3p "$TRASH/info/$id.trashinfo")" =~ ^DeletionDate=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
  [ "$(wc -l < "$TRASH/info/$id.trashinfo")" -eq 3 ]
  # No staging file or quarantine is left behind.
  [ -z "$(find "$TRASH" -name '.*' -print)" ]
}

@test "file trash: XDG_DATA_HOME selects the trash and must be absolute" {
  printf 'data\n' > "$WORK/one"
  mkdir -m 700 "$HOME/data"
  export XDG_DATA_HOME="$HOME/data"

  run run_zsh 'cd "$WORK" && file-trash put --yes one'
  [ "$status" -eq 0 ]
  [ -d "$HOME/data/zdx/trash/files" ]
  [ ! -e "$HOME/.local/share/zdx" ]

  printf 'data\n' > "$WORK/two"
  export XDG_DATA_HOME="relative/data"
  run run_zsh 'cd "$WORK" && file-trash put --yes two'
  [ "$status" -eq 1 ]
  [[ "$output" == *"XDG_DATA_HOME must be an absolute path"* ]]
  [ -f "$WORK/two" ]

  export XDG_DATA_HOME="$HOME/data/../data"
  run run_zsh 'cd "$WORK" && file-trash list'
  [ "$status" -eq 1 ]
  [[ "$output" == *"normalized path"* ]]
}

@test "file trash: an unsafe trash directory is refused before anything moves" {
  printf 'data\n' > "$WORK/one"
  make_trash_dirs
  chmod 770 "$TRASH"

  run run_zsh 'cd "$WORK" && file-trash put --yes one'
  [ "$status" -eq 1 ]
  [[ "$output" == *"private (mode 700)"* ]]
  [ -f "$WORK/one" ]

  chmod 700 "$TRASH"
  rmdir "$TRASH/info"
  ln -s "$HOME" "$TRASH/info"
  run run_zsh 'cd "$WORK" && file-trash list --json'
  [ "$status" -eq 1 ]
  [ -f "$WORK/one" ]
}

@test "file trash: names with control characters or the plan delimiter are refused" {
  printf 'keep\n' > "$WORK/bad"$'\n'"name"
  printf 'keep\n' > "$WORK/a|b"

  run run_zsh 'cd "$WORK" && file-trash put --yes -- "bad"$'"'"'\n'"'"'"name"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrepresentable path"* ]]
  run run_zsh 'cd "$WORK" && file-trash put --yes -- "a|b"'
  [ "$status" -eq 1 ]
  [ "$(cat "$WORK/bad"$'\n'"name")" = keep ]
  [ "$(cat "$WORK/a|b")" = keep ]
  [ -z "$(trash_ids)" ]
}

@test "file trash: a link is trashed, restored, and purged as the link itself" {
  mkdir -p "$HOME/outside"
  printf 'secret\n' > "$HOME/outside/target"
  ln -s "$HOME/outside/target" "$WORK/escape"
  ln -s "$HOME/outside" "$WORK/escape-dir"

  run run_zsh 'cd "$WORK" && file-trash put --yes escape escape-dir'
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/outside/target")" = secret ]
  [ -f "$HOME/outside/target" ]
  [ ! -L "$WORK/escape" ] && [ ! -L "$WORK/escape-dir" ]

  local id escape_id=""
  for id in $(trash_ids); do
    grep -q '^Path=.*/escape$' "$TRASH/info/$id.trashinfo" && escape_id="$id"
  done
  run run_zsh "file-trash restore --yes $escape_id"
  [ "$status" -eq 0 ]
  [ -L "$WORK/escape" ]
  [ "$(readlink "$WORK/escape")" = "$HOME/outside/target" ]

  run run_zsh 'cd "$WORK" && file-trash put --yes escape'
  [ "$status" -eq 0 ]
  run run_zsh 'file-trash purge --all --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Purge completed: 2 items deleted."* ]]
  [ "$(cat "$HOME/outside/target")" = secret ]
  [ -d "$HOME/outside" ]
  [ -z "$(ls -A "$TRASH/files")" ]
}

@test "file trash: put refuses paths outside the current directory and the directory itself" {
  mkdir -p "$HOME/outside" "$WORK/sub"
  printf 'outside\n' > "$HOME/outside/file"
  printf 'inside\n' > "$WORK/sub/file"
  ln -s "$HOME/outside" "$WORK/linked"

  local target
  for target in . "$WORK" .. ../outside/file "$HOME/outside/file" \
    linked/file sub/../../outside/file "$HOME"; do
    run run_zsh "cd \"\$WORK\" && file-trash put --yes -- '$target'"
    [ "$status" -eq 1 ] || {
      printf 'target: %s\nstatus: %s\n%s\n' "$target" "$status" "$output"
      return 1
    }
  done
  [ "$(cat "$HOME/outside/file")" = outside ]
  [ "$(cat "$WORK/sub/file")" = inside ]
  [ -L "$WORK/linked" ]
  [ ! -e "$HOME/.local/share/zdx" ]
}

@test "file trash: put refuses the trash itself and a directory that holds it" {
  printf 'seed\n' > "$HOME/seed"
  run run_zsh 'cd "$HOME" && file-trash put --yes seed'
  [ "$status" -eq 0 ]

  run run_zsh 'cd "$HOME" && file-trash put --yes .local'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to move the trash into itself"* ]]
  [ -d "$TRASH/files" ]

  run run_zsh 'cd "$TRASH" && file-trash put --yes files'
  [ "$status" -eq 1 ]
  [ -d "$TRASH/files" ]
}

@test "file trash: a directory the purge engine could not delete is refused" {
  mkdir -p "$WORK/project"
  printf 'code\n' > "$WORK/project/main.zsh"
  ln -s main.zsh "$WORK/project/alias"

  run run_zsh 'cd "$WORK" && file-trash put --yes project'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Transfers refuse links and special files"* ]]
  [[ "$output" == *"so that purge can delete it later"* ]]
  [ -f "$WORK/project/main.zsh" ]
  [ -z "$(trash_ids)" ]
}

@test "file trash: a dry run and a declined or terminal-less put change nothing" {
  printf 'data\n' > "$WORK/one"

  run run_zsh 'cd "$WORK" && file-trash put --dry-run one'
  [ "$status" -eq 0 ]
  [[ "$output" == *"1  one   file"* ]]
  [[ "$output" == *"Dry run: 1 item planned; nothing was moved."* ]]
  [ -f "$WORK/one" ]
  [ ! -e "$HOME/.local/share/zdx" ]

  # run_zsh redirects stdin from /dev/null, so no terminal is attached.
  run run_zsh 'cd "$WORK" && file-trash put one'
  [ "$status" -eq 2 ]
  [[ "$output" == *"pass --yes"* ]]
  [ -f "$WORK/one" ]
  [ ! -e "$HOME/.local/share/zdx" ]

  run run_zsh '
    cd "$WORK" || return 90
    _file_confirm() { return 1; }
    file-trash put one
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled: nothing was moved."* ]]
  [ -f "$WORK/one" ]
}

@test "file trash: a target changed after confirmation is never moved" {
  printf 'first\n' > "$WORK/one"
  printf 'planned\n' > "$WORK/two"

  run run_zsh '
    cd "$WORK" || return 90
    _file_confirm_mutation() {
      command mv two two.planned || return 91
      print -r -- replacement > two
    }
    file-trash put --yes one two
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed identity before execution"* ]]
  [[ "$output" != *"Trashed"* ]]
  [ "$(cat "$WORK/one")" = first ]
  [ "$(cat "$WORK/two")" = replacement ]
  [ -z "$(trash_ids)" ]
}

@test "file trash: a failed move withdraws its record and an interruption stops the batch" {
  printf 'first\n' > "$WORK/one"
  printf 'second\n' > "$WORK/two"
  export TRASH_REAL_MV TRASH_MV_STATUS=1
  TRASH_REAL_MV=$(command -v mv)
  cat > "$TEST_MOCK_BIN/mv" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  exec "$TRASH_REAL_MV" --version
fi
exit "$TRASH_MV_STATUS"
SH
  chmod +x "$TEST_MOCK_BIN/mv"

  run run_zsh 'cd "$WORK" && file-trash put --yes one two'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not move the exact target into the trash."* ]]
  [[ "$output" == *"Trash failed: 2 of 2 items failed."* ]]
  [ -f "$WORK/one" ] && [ -f "$WORK/two" ]
  [ -z "$(trash_ids)" ]
  [ -z "$(ls -A "$TRASH/info")" ]

  export TRASH_MV_STATUS=130
  run run_zsh 'cd "$WORK" && file-trash put --yes one two'
  [ "$status" -eq 130 ]
  [[ "$output" == *"Trash interrupted; later items were not changed."* ]]
  [[ "$output" == *"Not run: 1 item"* ]]
  [ -f "$WORK/one" ] && [ -f "$WORK/two" ]
  [ -z "$(ls -A "$TRASH/info")" ]
}

@test "file trash: a record reservation never replaces an existing record" {
  make_trash_dirs
  local record="$TRASH/info/20260101-000000-abcdef.trashinfo"
  printf 'original\n' > "$record"
  chmod 600 "$record"
  local before
  before=$(file_identity "$record")

  run run_zsh '
    _file_directory_identity "$TRASH/info" || return 90
    _file_trash_write_info "$TRASH/info/20260101-000000-abcdef.trashinfo" \
      "replacement" "$REPLY"
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$record")" = original ]
  [ "$(file_identity "$record")" = "$before" ]
  [ -z "$(find "$TRASH/info" -name '.*' -print)" ]
}

@test "file trash: IDs stay unique for many items trashed in one second" {
  local index
  for index in 1 2 3 4 5 6 7 8; do
    printf '%s\n' "$index" > "$WORK/file$index"
  done

  run run_zsh 'cd "$WORK" && file-trash put --yes file1 file2 file3 file4 file5 file6 file7 file8'
  [ "$status" -eq 0 ]
  [ "$(trash_ids | wc -l)" -eq 8 ]
  [ "$(trash_ids | sort -u | wc -l)" -eq 8 ]
}

@test "file trash: a source on another device is refused, never copied" {
  mock_kernel Linux
  mount_table
  printf 'data\n' > "$WORK/one"

  run run_zsh '
    cd "$WORK" || return 90
    _file_mount_table_path() { REPLY="$TRASH_MOUNTINFO"; }
    _file_path_device() {
      zmodload -F zsh/stat b:zstat || return 1
      local -A device_state=()
      zstat -LH device_state -- "$1" || return 1
      REPLY="${device_state[device]}"
      [[ "$1" == "$WORK"/* ]] && REPLY=424242
      return 0
    }
    file-trash put --yes one
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to move across filesystems: ~/work/one"* ]]
  [[ "$output" == *"never copies them"* ]]
  [ -f "$WORK/one" ]
  [ ! -e "$HOME/.local/share/zdx" ]
}

@test "file trash: a bind mount with the same device is a different filesystem" {
  mock_kernel Linux
  mount_table "$WORK"
  printf 'data\n' > "$WORK/one"

  run run_zsh '
    cd "$WORK" || return 90
    _file_mount_table_path() { REPLY="$TRASH_MOUNTINFO"; }
    file-trash put --dry-run one
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to move across filesystems"* ]]
  [ -f "$WORK/one" ]
}

@test "file trash: restore refuses to replace a path or recreate a missing parent" {
  mkdir -p "$WORK/dir"
  printf 'original\n' > "$WORK/one"
  printf 'nested\n' > "$WORK/dir/two"
  run run_zsh 'cd "$WORK" && file-trash put --yes one dir/two'
  [ "$status" -eq 0 ]
  local one_id two_id id
  for id in $(trash_ids); do
    if grep -q '^Path=.*/one$' "$TRASH/info/$id.trashinfo"; then
      one_id="$id"
    else
      two_id="$id"
    fi
  done

  printf 'newer\n' > "$WORK/one"
  run run_zsh "file-trash restore --yes $one_id"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to replace an existing path: ~/work/one"* ]]
  [ "$(cat "$WORK/one")" = newer ]
  [ "$(cat "$TRASH/files/$one_id")" = original ]

  rmdir "$WORK/dir"
  run run_zsh "file-trash restore --yes $two_id"
  [ "$status" -eq 1 ]
  [[ "$output" == *"The original parent directory no longer exists: ~/work/dir"* ]]
  [[ "$output" == *"Recreate it, then restore again"* ]]
  [ ! -e "$WORK/dir" ]
  [ "$(cat "$TRASH/files/$two_id")" = nested ]
  [ -f "$TRASH/info/$two_id.trashinfo" ]

  # One refused item stops the whole plan before any move.
  mkdir "$WORK/dir"
  run run_zsh "file-trash restore --yes $two_id $one_id"
  [ "$status" -eq 1 ]
  [ ! -e "$WORK/dir/two" ]
}

@test "file trash: restore revalidates items after confirmation" {
  printf 'one\n' > "$WORK/one"
  printf 'two\n' > "$WORK/two"
  run run_zsh 'cd "$WORK" && file-trash put --yes one two'
  [ "$status" -eq 0 ]
  local id one_id="" two_id=""
  for id in $(trash_ids); do
    if grep -q '^Path=.*/one$' "$TRASH/info/$id.trashinfo"; then
      one_id="$id"
    else
      two_id="$id"
    fi
  done

  run run_zsh "
    _file_confirm_mutation() {
      print -r -- tampered >> \"\$TRASH/files/$two_id\"
    }
    file-trash restore --yes $one_id $two_id
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed identity before execution"* ]]
  [[ "$output" != *"Restored"* ]]
  [ ! -e "$WORK/one" ] && [ ! -e "$WORK/two" ]

  run run_zsh "
    _file_confirm_mutation() { command rm -f -- \"\$TRASH/files/$one_id\"; }
    file-trash restore --yes $one_id
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed before execution"* ]]
  [ ! -e "$WORK/one" ]

  run run_zsh "
    _file_confirm_mutation() { print -r -- squatter > \"\$WORK/two\"; }
    file-trash restore --yes $two_id
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"A path appeared at the original location"* ]]
  [ "$(cat "$WORK/two")" = squatter ]
}

@test "file trash: restore and purge dry runs and terminal-less runs change nothing" {
  printf 'one\n' > "$WORK/one"
  run run_zsh 'cd "$WORK" && file-trash put --yes one'
  [ "$status" -eq 0 ]
  local id
  id=$(trash_ids)

  run run_zsh "file-trash restore --dry-run $id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: 1 item planned; nothing was restored."* ]]
  run run_zsh "file-trash restore $id"
  [ "$status" -eq 2 ]
  [[ "$output" == *"pass --yes"* ]]
  run run_zsh "file-trash purge --dry-run $id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Purged items cannot be restored."* ]]
  [[ "$output" == *"Dry run: 1 item planned; nothing was deleted."* ]]
  run run_zsh 'file-trash purge --all'
  [ "$status" -eq 2 ]
  run run_zsh '
    _file_confirm() { return 1; }
    file-trash purge --all
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled: nothing was deleted."* ]]

  [ ! -e "$WORK/one" ]
  [ "$(cat "$TRASH/files/$id")" = one ]
  [ -f "$TRASH/info/$id.trashinfo" ]
}

@test "file trash: purge deletes through the quarantine engine and selects by age" {
  mkdir -p "$WORK/dir"
  printf 'old\n' > "$WORK/old"
  printf 'new\n' > "$WORK/new"
  printf 'tree\n' > "$WORK/dir/file"
  run run_zsh 'cd "$WORK" && file-trash put --yes old new dir'
  [ "$status" -eq 0 ]
  local id old_id="" new_id="" dir_id=""
  for id in $(trash_ids); do
    case "$(sed -n 's/^Path=//p' "$TRASH/info/$id.trashinfo")" in
      */old) old_id="$id" ;;
      */new) new_id="$id" ;;
      */dir) dir_id="$id" ;;
    esac
  done
  # Age one record by rewriting it in place, which keeps its private mode.
  sed "s/^DeletionDate=.*/DeletionDate=2001-02-03T04:05:06/" \
    "$TRASH/info/$old_id.trashinfo" > "$TEST_TEMP_DIR/record"
  cat "$TEST_TEMP_DIR/record" > "$TRASH/info/$old_id.trashinfo"

  run run_zsh 'file-trash purge --older-than 30 --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$old_id"* ]]
  [[ "$output" != *"$new_id"* && "$output" != *"$dir_id"* ]]
  [[ "$output" == *"2001-02-03 04:05"* ]]

  run run_zsh 'file-trash purge --older-than 30 --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleted $old_id"* ]]
  [[ "$output" == *"Purge completed: 1 item deleted."* ]]
  [ ! -e "$TRASH/files/$old_id" ] && [ ! -e "$TRASH/info/$old_id.trashinfo" ]
  [ -e "$TRASH/files/$new_id" ] && [ -e "$TRASH/files/$dir_id" ]

  run run_zsh 'file-trash purge --older-than 30 --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"No trashed items are older than 30 days."* ]]

  run run_zsh "file-trash purge --yes $dir_id"
  [ "$status" -eq 0 ]
  [ ! -e "$TRASH/files/$dir_id" ]
  [ -z "$(find "$TRASH" -name '.zdx-file-delete.*' -print)" ]

  run run_zsh 'file-trash purge --yes 20200101-000000-abcdef'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown trash ID: 20200101-000000-abcdef"* ]]
  [ -e "$TRASH/files/$new_id" ]
}

@test "file trash: malicious records are data and never restore outside validated paths" {
  mkdir -m 777 "$TEST_TEMP_DIR/shared"
  chmod 777 "$TEST_TEMP_DIR/shared"
  local escaped_home="${HOME// /%20}"
  write_record 20260101-000001-aaaaa1 "relative/path"
  write_record 20260101-000002-aaaaa2 "$escaped_home/work/../../escape"
  write_record 20260101-000003-aaaaa3 "$escaped_home/work/new%0Aline"
  write_record 20260101-000004-aaaaa4 "$escaped_home/work/nul%00byte"
  write_record 20260101-000005-aaaaa5 "$escaped_home/.local/share/zdx/trash/files/x"
  write_record 20260101-000006-aaaaa6 "$escaped_home/work/bad%ZZescape"
  write_record 20260101-000007-aaaaa7 "$escaped_home/work/ok" "2026-02-30T00:00:00"
  write_record 20260101-000008-aaaaa8 "$TEST_TEMP_DIR/shared/planted"
  # A raw newline splits the value into a line that is not a key.
  write_record 20260101-000009-aaaaa9 "$escaped_home/work/first"
  printf '[Trash Info]\nPath=%s/work/first\nsecond\nDeletionDate=2026-01-02T03:04:05\n' \
    "$escaped_home" > "$TRASH/info/20260101-000009-aaaaa9.trashinfo"
  # Duplicate and unknown keys, a link, and a readable record.
  write_record 20260101-000010-aaaa10 "$escaped_home/work/dup"
  printf 'Path=%s/work/dup\n' "$escaped_home" >> "$TRASH/info/20260101-000010-aaaa10.trashinfo"
  write_record 20260101-000011-aaaa11 "$escaped_home/work/key"
  printf 'Exec=rm -rf ~\n' >> "$TRASH/info/20260101-000011-aaaa11.trashinfo"
  write_record 20260101-000012-aaaa12 "$escaped_home/work/linked"
  mv "$TRASH/info/20260101-000012-aaaa12.trashinfo" "$TEST_TEMP_DIR/elsewhere.trashinfo"
  ln -s "$TEST_TEMP_DIR/elsewhere.trashinfo" "$TRASH/info/20260101-000012-aaaa12.trashinfo"
  write_record 20260101-000013-aaaa13 "$escaped_home/work/readable"
  chmod 644 "$TRASH/info/20260101-000013-aaaa13.trashinfo"

  run run_zsh 'file-trash list --json 2>/dev/null'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .item_count == 1
    and .items[0].id == "20260101-000008-aaaaa8"
    and ([.skipped[] | select(.reason == "invalid_info")] | length) == 12
  '

  local id
  for id in $(trash_ids); do
    [ "$id" = 20260101-000008-aaaaa8 ] && continue
    run run_zsh "file-trash restore --yes $id"
    [ "$status" -eq 1 ] || {
      printf 'id: %s\nstatus: %s\n%s\n' "$id" "$status" "$output"
      return 1
    }
    [[ "$output" == *"cannot be restored: invalid record."* ]]
  done

  # A well-formed record whose parent others can write is refused.
  run run_zsh 'file-trash restore --yes 20260101-000008-aaaaa8'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be owned by you and not group/world-writable"* ]]
  [ ! -e "$TEST_TEMP_DIR/shared/planted" ]
  [ ! -e "$HOME/escape" ] && [ ! -e "$TEST_TEMP_DIR/escape" ]
  [ ! -e "$WORK" ] || [ -z "$(ls -A "$WORK")" ]
  [ -f "$TEST_TEMP_DIR/elsewhere.trashinfo" ]

  # Every damaged entry can still be purged, and only the trash changes.
  run run_zsh 'file-trash purge --all --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Purge completed: 13 items deleted."* ]]
  [ -z "$(ls -A "$TRASH/files")" ] && [ -z "$(ls -A "$TRASH/info")" ]
  [ -f "$TEST_TEMP_DIR/elsewhere.trashinfo" ]
}

@test "file trash: entries without an item or record are reported and purgeable" {
  write_record 20260101-000001-bbbbb1 "${HOME// /%20}/work/gone"
  rm "$TRASH/files/20260101-000001-bbbbb1"
  write_record 20260101-000002-bbbbb2 "${HOME// /%20}/work/orphan"
  rm "$TRASH/info/20260101-000002-bbbbb2.trashinfo"
  write_record 20260101-000003-bbbbb3 "${HOME// /%20}/work/fine"

  run run_zsh 'file-trash list'
  [ "$status" -eq 0 ]
  [[ "$output" == *"20260101-000003-bbbbb3"* ]]
  [[ "$output" == *"Skipped 2 trash entries that cannot be restored"* ]]
  [[ "$output" == *"20260101-000001-bbbbb1 (record without an item)"* ]]
  [[ "$output" == *"20260101-000002-bbbbb2 (item without a record)"* ]]

  run run_zsh 'file-trash purge --yes 20260101-000001-bbbbb1 20260101-000002-bbbbb2'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Purge completed: 2 items deleted."* ]]
  [ ! -e "$TRASH/info/20260101-000001-bbbbb1.trashinfo" ]
  [ ! -e "$TRASH/files/20260101-000002-bbbbb2" ]
  [ -e "$TRASH/files/20260101-000003-bbbbb3" ]
}

@test "file trash: list --json prints only one schema document" {
  run run_zsh 'file-trash list --json 2>"$TEST_TEMP_DIR/stderr"'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    (keys_unsorted[0] == "schema") and .schema == "zdx.file-trash.v1"
    and .item_count == 0 and .items == [] and .skipped == []
  '
  [ "${#lines[@]}" -eq 1 ]
  [ ! -s "$TEST_TEMP_DIR/stderr" ]
  [ ! -e "$HOME/.local/share/zdx" ]

  mkdir -p "$WORK/dir"
  printf '12345\n' > "$WORK/dir/file"
  printf 'abc\n' > "$WORK/one"
  ln -s one "$WORK/link"
  run run_zsh 'cd "$WORK" && file-trash put --yes one dir link'
  [ "$status" -eq 0 ]

  run run_zsh 'NO_COLOR=1 file-trash list --json 2>"$TEST_TEMP_DIR/stderr"'
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e'* ]]
  printf '%s\n' "$output" | jq -e --arg work "$WORK" --arg trash "$TRASH" '
    (keys_unsorted[0] == "schema")
    and .trash_dir == $trash and .item_count == 3
    and ([.items[].type] | sort) == ["directory", "file", "symlink"]
    and ([.items[] | select(.type == "file") | .size_bytes] == [4])
    and ([.items[] | select(.type == "directory") | .size_bytes] == [6])
    and ([.items[].original_path] | sort) == ([$work + "/dir", $work + "/link", $work + "/one"] | sort)
    and all(.items[]; (.id | test("^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$"))
      and (.deleted_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
  '
  # The document is the only stdout data: one compact JSON line.
  [ "$(printf '%s\n' "$output" | jq -s 'length')" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "{"*"}" ]]
  [ ! -s "$TEST_TEMP_DIR/stderr" ]
}

@test "file trash: list --json without jq reports the capability on stderr" {
  run run_zsh 'PATH=/nonexistent file-trash list --json 2>"$TEST_TEMP_DIR/stderr"'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'jq is required' "$TEST_TEMP_DIR/stderr"
}

@test "file trash: deletion dates convert to UTC in JSON" {
  write_record 20260101-000001-ccccc1 "${HOME// /%20}/work/zone" "2026-07-01T12:00:00"
  export TZ=America/New_York
  run run_zsh 'file-trash list --json 2>/dev/null'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.items[0].deleted_at == "2026-07-01T16:00:00Z"'
  export TZ=UTC
  run run_zsh 'file-trash list --json 2>/dev/null'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.items[0].deleted_at == "2026-07-01T12:00:00Z"'
}

@test "file trash: the picker restores the selected item and cancels cleanly" {
  printf 'one\n' > "$WORK/one"
  printf 'two\n' > "$WORK/two"
  run run_zsh 'cd "$WORK" && file-trash put --yes one two'
  [ "$status" -eq 0 ]
  local id two_id=""
  for id in $(trash_ids); do
    grep -q '^Path=.*/two$' "$TRASH/info/$id.trashinfo" && two_id="$id"
  done

  run run_zsh 'file-trash'
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/one" ] && [ ! -e "$WORK/two" ]

  # The first picker selects the item row; the action dialog selects restore.
  export TRASH_PICK_ID="$two_id" TRASH_PICK_COUNT="$TEST_TEMP_DIR/picks"
  cat > "$TEST_MOCK_BIN/fzf" <<'SH'
#!/usr/bin/env bash
input=$(cat)
count=$(( $(cat "$TRASH_PICK_COUNT" 2>/dev/null || printf 0) + 1 ))
printf '%s\n' "$count" > "$TRASH_PICK_COUNT"
if (( count == 1 )); then
  printf '%s\n' "$input" | grep -F "$TRASH_PICK_ID"
else
  printf 'restore\n'
fi
SH
  chmod +x "$TEST_MOCK_BIN/fzf"
  run run_zsh 'file-trash --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore completed: 1 item restored."* ]]
  [ "$(cat "$WORK/two")" = two ]
  [ ! -e "$WORK/one" ]

  # A forged row that was never in the snapshot is refused.
  cat > "$TEST_MOCK_BIN/fzf" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '1|20200101-000000-abcdef  forged\n'
SH
  run run_zsh 'file-trash restore --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the current snapshot"* ]]
  [ ! -e "$WORK/one" ]
}

@test "file trash: an empty trash is reported without a picker or prompt" {
  run run_zsh '
    _file_fzf() { print -u2 -r -- PICKER; return 130; }
    file-trash
    file-trash restore
    file-trash purge
    file-trash list
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *PICKER* ]]
  [[ "$output" == *"The trash is empty."* ]]
  [[ "$output" == *"The trash has no items to restore."* ]]
}

@test "file trash: restore refuses a destination on another filesystem" {
  printf 'one\n' > "$WORK/one"
  run run_zsh 'cd "$WORK" && file-trash put --yes one'
  [ "$status" -eq 0 ]
  mock_kernel Linux
  mount_table
  local id
  id=$(trash_ids)

  run run_zsh "
    _file_mount_table_path() { REPLY=\"\$TRASH_MOUNTINFO\"; }
    _file_path_device() {
      zmodload -F zsh/stat b:zstat || return 1
      local -A device_state=()
      zstat -LH device_state -- \"\$1\" || return 1
      REPLY=\"\${device_state[device]}\"
      [[ \"\$1\" == \"\$WORK\" ]] && REPLY=424242
      return 0
    }
    file-trash restore --yes $id
  "
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to move across filesystems"* ]]
  [ ! -e "$WORK/one" ]
  [ "$(cat "$TRASH/files/$id")" = one ]
}

@test "file trash: trash refusals on a Windows drive explain DrvFs metadata" {
  run run_zsh '
    _file_host_is_wsl() { return 0; }
    _file_trash_private_dir /mnt/c/Users/example/trash
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"private (mode 700)"* ]]
  [[ "$output" == *"DrvFs metadata"* ]]
}

@test "file trash: the File entrypoint dispatches trash actions" {
  printf 'one\n' > "$WORK/one"

  run run_zsh 'cd "$WORK" && file-menu file-trash put --dry-run one'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: 1 item planned; nothing was moved."* ]]
  [ -f "$WORK/one" ]

  run run_zsh 'file-menu file-trash list --json 2>/dev/null'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.schema == "zdx.file-trash.v1"'
}
