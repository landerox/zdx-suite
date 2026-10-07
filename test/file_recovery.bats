#!/usr/bin/env bats

setup() {
  FILE_RECOVERY_ORIGINAL_PATH="$PATH"
  load test_helper
}

teardown() {
  # BATS also removes capture files after teardown. Do not leave a cached
  # command pointing to a mock executable inside the deleted sandbox.
  PATH="$FILE_RECOVERY_ORIGINAL_PATH"
  hash -r
  cleanup_sandbox
}

# file_gnu_tar_name: the command name (tar or gtar) under which the host
# provides GNU tar, which hardened extraction requires; status 1 without it.
file_gnu_tar_name() {
  local name version
  for name in tar gtar; do
    command -v "$name" >/dev/null 2>&1 || continue
    version=$("$name" --version 2>/dev/null | head -n 1) || continue
    if [[ "$version" == *"GNU tar"* ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

@test "file recovery: large-file deletion executes a real multiple-target plan" {
  run run_zsh '
    mkdir "$HOME/large" && cd "$HOME/large" || return
    print -r -- first > one.txt
    print -r -- second > two.txt
    mkdir nested || return
    print -r -- third > nested/three.txt
    : > empty.txt
    file-find-large --min-size 1 --delete --yes || return
    [[ ! -e one.txt && ! -e two.txt && ! -e nested/three.txt ]] || return 1
    [[ -f empty.txt && -d nested ]] || return 1
    recovery=(.zdx-file-delete.*(N) nested/.zdx-file-delete.*(N))
    (( ${#recovery} == 0 ))
  '
  [ "$status" -eq 0 ]
}

@test "file recovery: a real multi-input TAR round trip preserves both inputs" {
  file_gnu_tar_name >/dev/null \
    || skip "hardened extraction requires GNU tar, installed as tar or gtar"
  run run_zsh '
    unfunction command
    cd "$HOME" || return
    print -r -- first > one
    print -r -- second > two
    file-compress --format tar.gz --output bundle.tar.gz --yes -- one two || return
    file-extract --destination restored --yes -- bundle.tar.gz || return
    [[ "$(<restored/one)" == first && "$(<restored/two)" == second ]]
  '
  [ "$status" -eq 0 ]
}

@test "file recovery: a changed second target rejects the whole deletion plan before mutation" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- first > one
    print -r -- second > two
    _file_collect_paths() { reply=(one two); return 0; }
    _file_confirm_mutation() { print -r -- replacement > two; }
    file-find-large --min-size 1 --delete --yes
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/one")" = first ]
  [ "$(cat "$HOME/two")" = replacement ]
}

@test "file recovery: interrupted large-file deletion retains quarantine and leaves later targets untouched" {
  export FILE_REAL_RM
  FILE_REAL_RM=$(command -v rm)
  cat <<'EOF' > "$TEST_MOCK_BIN/rm"
#!/usr/bin/env bash
for operand in "$@"; do
  if [[ "$operand" == "$HOME"/.zdx-file-delete.* ]]; then
    exit "$FILE_DELETE_STATUS"
  fi
done
exec "$FILE_REAL_RM" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/rm"
  for interrupt_status in 130 143; do
    export FILE_DELETE_STATUS="$interrupt_status"
    run run_zsh '
      cd "$HOME" || return
      print -r -- first > one
      print -r -- second > two
      _file_collect_paths() { reply=(one two); return 0; }
      file-find-large --min-size 1 --delete --yes
    '
    [ "$status" -eq "$interrupt_status" ]
    [ ! -e "$HOME/one" ]
    [ "$(cat "$HOME/two")" = second ]
    [[ "$output" == *"Recovery path:"* ]]
    run run_zsh '
      recovery=("$HOME"/.zdx-file-delete.*(N))
      (( ${#recovery} == 1 )) && [[ "$(<${recovery[1]})" == first ]] || return 1
      "$FILE_REAL_RM" -- "${recovery[1]}"
    '
    [ "$status" -eq 0 ]
  done
}

@test "file recovery: unexpected mktemp results are never modified or removed" {
  cat <<'EOF' > "$TEST_MOCK_BIN/mktemp"
#!/usr/bin/env bash
printf '%s\n' "$FILE_TEMP_RESULT"
EOF
  chmod +x "$TEST_MOCK_BIN/mktemp"
  export FILE_TEMP_RESULT="$HOME/victim"
  printf preserved > "$FILE_TEMP_RESULT"
  chmod 644 "$FILE_TEMP_RESULT"
  for temp_kind in sibling archive; do
    export FILE_TEMP_KIND="$temp_kind"
    run run_zsh '
      cd "$HOME" || return
      case "$FILE_TEMP_KIND" in
        sibling) _file_make_sibling_temp "$HOME/output" ;;
        archive) _file_archive_stage_dir "$HOME" ;;
      esac
    '
    [ "$status" -ne 0 ]
    [ "$(cat "$FILE_TEMP_RESULT")" = preserved ]
    [ "$(file_mode "$FILE_TEMP_RESULT")" = 644 ]
  done
  rm -f "$FILE_TEMP_RESULT"
  mkdir "$FILE_TEMP_RESULT"
  chmod 755 "$FILE_TEMP_RESULT"
  run run_zsh '_file_archive_stage_dir "$HOME"'
  [ "$status" -ne 0 ]
  [ -d "$FILE_TEMP_RESULT" ]
  [ "$(file_mode "$FILE_TEMP_RESULT")" = 755 ]
  rm -f "$TEST_MOCK_BIN/mktemp"
}

@test "file recovery: interrupted archive creation preserves existing output and cleans staging" {
  # Both names, so neither a host gtar nor the host tar creates the archive.
  cat <<'EOF' > "$TEST_MOCK_BIN/tar"
#!/usr/bin/env bash
exit "$FILE_ARCHIVE_STATUS"
EOF
  cp "$TEST_MOCK_BIN/tar" "$TEST_MOCK_BIN/gtar"
  chmod +x "$TEST_MOCK_BIN/tar" "$TEST_MOCK_BIN/gtar"
  for interrupt_status in 130 143; do
    export FILE_ARCHIVE_STATUS="$interrupt_status"
    run run_zsh '
      cd "$HOME" || return
      print -r -- first > one
      print -r -- second > two
      print -r -- preserved > archive.tar.gz
      file-compress --format tar.gz --output archive.tar.gz --overwrite --yes -- one two
    '
    [ "$status" -eq "$interrupt_status" ]
    [ "$(cat "$HOME/archive.tar.gz")" = preserved ]
    [ -z "$(find "$HOME" -name '.zdx-file-archive.*' -print)" ]
  done
}

@test "file recovery: interrupted extraction publishes no directory and cleans private snapshots" {
  local gnu_tar_name
  gnu_tar_name=$(file_gnu_tar_name) \
    || skip "hardened extraction requires GNU tar, installed as tar or gtar"
  export FILE_REAL_TAR
  FILE_REAL_TAR=$(command -v "$gnu_tar_name")
  # Interrupt the GNU tar that File resolves, whether it is tar or gtar.
  cat <<'EOF' > "$TEST_MOCK_BIN/$gnu_tar_name"
#!/usr/bin/env bash
if [[ "$1" == --extract ]]; then
  exit "$FILE_EXTRACT_STATUS"
fi
exec "$FILE_REAL_TAR" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/$gnu_tar_name"
  for interrupt_status in 130 143; do
    export FILE_EXTRACT_STATUS="$interrupt_status"
    run run_zsh '
      unfunction command
      cd "$HOME" || return
      print -r -- first > one
      "$FILE_REAL_TAR" -czf archive.tar.gz -- one || return
      file-extract --destination restored --yes -- archive.tar.gz
    '
    [ "$status" -eq "$interrupt_status" ]
    [ ! -e "$HOME/restored" ]
    [ "$(cat "$HOME/one")" = first ]
    [ -z "$(find "$HOME" \( -name '.zdx-file-archive.*' -o -name '*.zdx.*' \) -print)" ]
  done
}

@test "file recovery: interrupted archive publication preserves existing output" {
  cat <<'EOF' > "$TEST_MOCK_BIN/mv"
#!/usr/bin/env bash
exit "$FILE_PUBLISH_STATUS"
EOF
  chmod +x "$TEST_MOCK_BIN/mv"
  for interrupt_status in 130 143; do
    export FILE_PUBLISH_STATUS="$interrupt_status"
    run run_zsh '
      unfunction command
      cd "$HOME" || return
      print -r -- first > one
      print -r -- preserved > archive.tar.gz
      file-compress --format tar.gz --output archive.tar.gz --overwrite --yes -- one
    '
    [ "$status" -eq "$interrupt_status" ]
    [ "$(cat "$HOME/archive.tar.gz")" = preserved ]
    [ -z "$(find "$HOME" -name '.zdx-file-archive.*' -print)" ]
  done
}
