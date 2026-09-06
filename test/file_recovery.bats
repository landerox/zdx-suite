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

@test "file recovery: every bulk operation executes a real multiple-target plan" {
  run run_zsh '
    cd "$HOME" || return
    for operation in copy move delete rename duplicate; do
      mkdir "$operation" || return
      cd "$operation" || return
      print -r -- first > one.txt
      print -r -- second > two.txt
      mkdir destination || return
      case "$operation" in
        copy|move)
          file-bulk-ops "$operation" --destination destination --yes -- one.txt two.txt || return
          [[ "$(<destination/one.txt)" == first && "$(<destination/two.txt)" == second ]] || return 1
          ;;
        delete)
          file-bulk-ops delete --yes -- one.txt two.txt || return
          [[ ! -e one.txt && ! -e two.txt ]] || return 1
          ;;
        rename)
          file-bulk-ops rename --search .txt --replace .log --yes -- one.txt two.txt || return
          [[ "$(<one.log)" == first && "$(<two.log)" == second ]] || return 1
          ;;
        duplicate)
          file-bulk-ops duplicate --yes -- one.txt two.txt || return
          [[ "$(<one.bak.txt)" == first && "$(<two.bak.txt)" == second ]] || return 1
          ;;
      esac
      cd .. || return
    done
  '
  [ "$status" -eq 0 ]
}

@test "file recovery: permission and line-ending plans update every selected file" {
  run run_zsh '
    unfunction command
    cd "$HOME" || return
    printf "one\r\n" > one
    printf "two\r\n" > two
    file-permissions --mode 600 --yes -- one two || return
    [[ "$(command stat -c %a one)" == 600 && "$(command stat -c %a two)" == 600 ]] || return 1
    file-line-endings --to lf --yes -- one two || return
    [[ "$(<one)" == one && "$(<two)" == two ]] || return 1
    file-line-endings --to crlf --yes -- one two || return
    [[ "$(<one)" == $'"'"'one\r'"'"' && "$(<two)" == $'"'"'two\r'"'"' ]]
  '
  [ "$status" -eq 0 ]
}

@test "file recovery: a real multi-input TAR round trip preserves both inputs" {
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

@test "file recovery: a changed second target rejects the whole plan before mutation" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- first > one
    print -r -- second > two
    _file_confirm_mutation() { print -r -- replacement > two; }
    file-bulk-ops delete --yes -- one two
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/one")" = first ]
  [ "$(cat "$HOME/two")" = replacement ]
}

@test "file recovery: interrupted copies stop while ordinary failures allow later targets" {
  export FILE_REAL_CP
  FILE_REAL_CP=$(command -v cp)
  cat <<'EOF' > "$TEST_MOCK_BIN/cp"
#!/usr/bin/env bash
for operand in "$@"; do
  if [[ "$operand" == "$HOME/one" ]]; then
    exit "$FILE_COPY_STATUS"
  fi
done
exec "$FILE_REAL_CP" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/cp"
  for copy_status in 130 143 7; do
    export FILE_COPY_STATUS="$copy_status"
    rm -rf "$HOME/destination"
    run run_zsh '
      cd "$HOME" || return
      print -r -- first > one
      print -r -- second > two
      mkdir destination || return
      file-bulk-ops copy --destination destination --yes -- one two
    '
    if [ "$copy_status" -eq 7 ]; then
      [ "$status" -eq 1 ]
      [ "$(cat "$HOME/destination/two")" = second ]
    else
      [ "$status" -eq "$copy_status" ]
      [ ! -e "$HOME/destination/two" ]
    fi
    [ ! -e "$HOME/destination/one" ]
    [ "$(cat "$HOME/one")" = first ]
    [ -z "$(find "$HOME/destination" -name '.zdx-file-archive.*' -print)" ]
  done
}

@test "file recovery: interrupted deletion retains quarantine and leaves later targets untouched" {
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
      file-bulk-ops delete --yes -- one two
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

@test "file recovery: interrupted line conversion preserves both originals and cleans staging" {
  cat <<'EOF' > "$TEST_MOCK_BIN/sed"
#!/usr/bin/env bash
exit "$FILE_CONVERT_STATUS"
EOF
  chmod +x "$TEST_MOCK_BIN/sed"
  for interrupt_status in 130 143; do
    export FILE_CONVERT_STATUS="$interrupt_status"
    run run_zsh '
      unfunction command
      cd "$HOME" || return
      printf "first\r\n" > one
      printf "second\r\n" > two
      file-line-endings --to lf --yes -- one two
    '
    [ "$status" -eq "$interrupt_status" ]
    [ "$(cat "$HOME/one")" = $'first\r' ]
    [ "$(cat "$HOME/two")" = $'second\r' ]
    [ -z "$(find "$HOME" -name '*.zdx.*' -print)" ]
  done
}

@test "file recovery: interrupted chmod does not change a later target" {
  export FILE_REAL_CHMOD
  FILE_REAL_CHMOD=$(command -v chmod)
  cat <<'EOF' > "$TEST_MOCK_BIN/chmod"
#!/usr/bin/env bash
for operand in "$@"; do
  if [[ "$operand" == "$HOME/one" ]]; then
    exit "$FILE_MODE_STATUS"
  fi
done
exec "$FILE_REAL_CHMOD" "$@"
EOF
  "$FILE_REAL_CHMOD" +x "$TEST_MOCK_BIN/chmod"
  for interrupt_status in 130 143; do
    export FILE_MODE_STATUS="$interrupt_status"
    run run_zsh '
      cd "$HOME" || return
      touch one two
      "$FILE_REAL_CHMOD" 644 one two || return
      file-permissions --mode 600 --yes -- one two
    '
    [ "$status" -eq "$interrupt_status" ]
    [ "$(stat -c %a "$HOME/two")" = 644 ]
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
  for temp_kind in sibling data archive; do
    export FILE_TEMP_KIND="$temp_kind"
    run run_zsh '
      cd "$HOME" || return
      case "$FILE_TEMP_KIND" in
        sibling) _file_make_sibling_temp "$HOME/output" ;;
        data) _file_data_temp_file ;;
        archive) _file_archive_stage_dir "$HOME" ;;
      esac
    '
    [ "$status" -ne 0 ]
    [ "$(cat "$FILE_TEMP_RESULT")" = preserved ]
    [ "$(stat -c %a "$FILE_TEMP_RESULT")" = 644 ]
  done
  rm -f "$FILE_TEMP_RESULT"
  mkdir "$FILE_TEMP_RESULT"
  chmod 755 "$FILE_TEMP_RESULT"
  run run_zsh '_file_archive_stage_dir "$HOME"'
  [ "$status" -ne 0 ]
  [ -d "$FILE_TEMP_RESULT" ]
  [ "$(stat -c %a "$FILE_TEMP_RESULT")" = 755 ]
  rm -f "$TEST_MOCK_BIN/mktemp"
}

@test "file recovery: interrupted Base64 decoding does not retry or replace existing output" {
  export FILE_BASE64_LOG="$TEST_TEMP_DIR/base64.log"
  cat <<'EOF' > "$TEST_MOCK_BIN/base64"
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FILE_BASE64_LOG"
exit "$FILE_DECODE_STATUS"
EOF
  chmod +x "$TEST_MOCK_BIN/base64"
  for interrupt_status in 130 143; do
    export FILE_DECODE_STATUS="$interrupt_status"
    : > "$FILE_BASE64_LOG"
    run run_zsh '
      cd "$HOME" || return
      print -r -- Zmlyc3Q= > encoded
      print -r -- preserved > output
      file-encode-decode --decode-file encoded --output output --overwrite --yes
    '
    [ "$status" -eq "$interrupt_status" ]
    [ "$(cat "$FILE_BASE64_LOG")" = --decode ]
    [ "$(cat "$HOME/output")" = preserved ]
    [ -z "$(find "$HOME" -name '*.zdx.*' -print)" ]
  done
}

@test "file recovery: interrupted archive creation preserves existing output and cleans staging" {
  cat <<'EOF' > "$TEST_MOCK_BIN/tar"
#!/usr/bin/env bash
exit "$FILE_ARCHIVE_STATUS"
EOF
  chmod +x "$TEST_MOCK_BIN/tar"
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
  export FILE_REAL_TAR
  FILE_REAL_TAR=$(command -v tar)
  cat <<'EOF' > "$TEST_MOCK_BIN/tar"
#!/usr/bin/env bash
if [[ "$1" == --extract ]]; then
  exit "$FILE_EXTRACT_STATUS"
fi
exec "$FILE_REAL_TAR" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/tar"
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

@test "file recovery: an interrupted CRLF stage takes precedence over ordinary downstream failure" {
  cat <<'EOF' > "$TEST_MOCK_BIN/sed"
#!/usr/bin/env bash
if (( $# > 1 )); then
  exit "$FILE_PIPE_STATUS"
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/sed"
  for interrupt_status in 130 143; do
    export FILE_PIPE_STATUS="$interrupt_status"
    run run_zsh '
      unfunction command
      cd "$HOME" || return
      print -r -- first > one
      print -r -- second > two
      file-line-endings --to crlf --yes -- one two
    '
    [ "$status" -eq "$interrupt_status" ]
    [ "$(cat "$HOME/one")" = first ]
    [ "$(cat "$HOME/two")" = second ]
    [ -z "$(find "$HOME" -name '*.zdx.*' -print)" ]
  done
}
