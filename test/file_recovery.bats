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

# file_zstd_tar_available: true when that GNU tar accepts --zstd and zstd is
# installed, which zstd TAR archives require.
file_zstd_tar_available() {
  local name
  name=$(file_gnu_tar_name) || return 1
  "$name" --zstd --version >/dev/null 2>&1 || return 1
  command -v zstd >/dev/null 2>&1
}

# The default-option variables that the archive backends read from the
# environment: GNU tar and bsdtar, Info-ZIP zip and the unzip (with its
# zipinfo mode) that zip can run, and the gzip, xz, bzip2, lbzip2, lzop, and
# zstd filters that tar runs.
FILE_ARCHIVE_OPTION_NAMES='TAR_OPTIONS TAR_READER_OPTIONS TAR_WRITER_OPTIONS TAPE ZIPOPT ZIP UNZIP UNZIPOPT ZIPINFO ZIPINFOOPT GZIP XZ_DEFAULTS XZ_OPT BZIP2 BZIP LBZIP2 LZOP ZSTD_CLEVEL ZSTD_NBTHREADS'

# A Zsh line that exports a hostile default for each of them: GNU tar's
# --remove-files and zip's -m delete the inputs once they are archived.
FILE_HOSTILE_OPTIONS='export TAR_OPTIONS=--remove-files TAR_READER_OPTIONS=hdrcharset=BINARY TAR_WRITER_OPTIONS=gzip:compression-level=1 TAPE=/dev/null ZIPOPT=-m ZIP=-m UNZIP=-o UNZIPOPT=-o ZIPINFO=-l ZIPINFOOPT=-l GZIP=-9 XZ_DEFAULTS=-9 XZ_OPT=-9 BZIP2=-1 BZIP=-1 LBZIP2=-1 LZOP=-9 ZSTD_CLEVEL=19 ZSTD_NBTHREADS=2'

# file_work_dir: an empty work directory, exported as WORK for Zsh programs.
file_work_dir() {
  export WORK="$HOME/work"
  mkdir -p "$WORK"
}

# file_mock_archive_backend NAME: a tar (identifying as GNU tar), zip, or 7z
# that records which default-option variables it received, one line each, in
# FILE_BACKEND_ENV_LOG, and writes the archive its arguments name with one
# "member <operand>[: <content>]" line per input. Like the real tools, tar
# removes its inputs when TAR_OPTIONS asks for --remove-files, and zip when
# ZIPOPT or ZIP asks for -m; FILE_MOCK_REMOVE_INPUTS=yes makes any of them
# remove the inputs, as inputs that change during creation.
file_mock_archive_backend() {
  export FILE_ARCHIVE_OPTION_NAMES
  export FILE_BACKEND_ENV_LOG="$TEST_TEMP_DIR/backend-env"
  cat > "$TEST_MOCK_BIN/$1" <<'SH'
#!/usr/bin/env bash
tool="${0##*/}"
if [[ "$tool" == tar && "${1:-}" == --version ]]; then
  printf 'tar (GNU tar) 1.35\n'
  exit 0
fi
# 7-Zip's capability probe runs its info command.
[[ "$tool" == 7z && "${1:-}" == i ]] && exit 0
for name in $FILE_ARCHIVE_OPTION_NAMES; do
  if [[ -n "${!name+set}" ]]; then
    printf '%s %s=%s\n' "$tool" "$name" "${!name}"
  else
    printf '%s %s unset\n' "$tool" "$name"
  fi
done >> "$FILE_BACKEND_ENV_LOG"
archive="" previous="" remove="${FILE_MOCK_REMOVE_INPUTS:-no}"
operands=()
case "$tool" in
  tar)
    # [OPTION...] -c?f ARCHIVE -- INPUT...
    while (( $# > 0 )); do
      if [[ "$1" == -- ]]; then
        shift
        operands=("$@")
        break
      fi
      [[ "$previous" == -c*f ]] && archive="$1"
      previous="$1"
      shift
    done
    [[ " ${TAR_OPTIONS:-} " == *" --remove-files "* ]] && remove=yes
    ;;
  zip)
    # [OPTION...] ARCHIVE -- INPUT...
    while [[ "${1:-}" == -* && "$1" != -- ]]; do shift; done
    archive="${1:-}"
    shift
    [[ "${1:-}" == -- ]] && shift
    operands=("$@")
    [[ " ${ZIPOPT:-} ${ZIP:-} " == *" -m "* ]] && remove=yes
    ;;
  7z)
    # a [SWITCH...] -- ARCHIVE INPUT...
    [[ "${1:-}" == a ]] || exit 7
    shift
    while (( $# > 0 )) && [[ "$1" != -- ]]; do shift; done
    shift
    archive="${1:-}"
    shift
    operands=("$@")
    ;;
esac
[[ -n "$archive" && ${#operands[@]} -gt 0 ]] || exit 2
for operand in "${operands[@]}"; do
  if [[ -f "$operand" ]]; then
    printf 'member %s: %s\n' "$operand" "$(cat -- "$operand")"
  else
    printf 'member %s\n' "$operand"
  fi
done > "$archive" || exit 2
if [[ "$remove" == yes ]]; then
  rm -rf -- "${operands[@]}"
fi
exit 0
SH
  chmod +x "$TEST_MOCK_BIN/$1"
}

# file_backend_saw_no_options TOOL: the TOOL mock ran exactly once, and none
# of the default-option variables reached it.
file_backend_saw_no_options() {
  local expected="" name
  for name in $FILE_ARCHIVE_OPTION_NAMES; do
    expected+="$1 $name unset"$'\n'
  done
  [ "$(cat "$FILE_BACKEND_ENV_LOG")" = "${expected%$'\n'}" ]
}

# file_record_gzip_env: a gzip first on PATH that appends the GZIP value it
# received to FILE_GZIP_ENV_LOG, then runs the host's gzip.
file_record_gzip_env() {
  export FILE_REAL_GZIP FILE_GZIP_ENV_LOG="$TEST_TEMP_DIR/gzip-env"
  FILE_REAL_GZIP=$(command -v gzip)
  cat > "$TEST_MOCK_BIN/gzip" <<'SH'
#!/usr/bin/env bash
printf 'GZIP=%s\n' "${GZIP-<unset>}" >> "$FILE_GZIP_ENV_LOG"
exec "$FILE_REAL_GZIP" "$@"
SH
  chmod +x "$TEST_MOCK_BIN/gzip"
}

# file_gzip_saw_no_options: gzip ran at least once, never with a GZIP value.
file_gzip_saw_no_options() {
  grep -q -x 'GZIP=<unset>' "$FILE_GZIP_ENV_LOG"
  [ "$(grep -c -v -x 'GZIP=<unset>' "$FILE_GZIP_ENV_LOG")" -eq 0 ]
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

@test "file recovery: a real zstd TAR round trip preserves both inputs" {
  file_zstd_tar_available \
    || skip "zstd TAR archives require GNU tar with --zstd and zstd"
  run run_zsh '
    unfunction command
    cd "$HOME" || return
    print -r -- first > one
    print -r -- second > two
    file-compress --format tar.zst --output bundle.tar.zst --yes -- one two \
      || return 91
    file-extract --destination restored --yes -- bundle.tar.zst || return 92
    [[ "$(<restored/one)" == first && "$(<restored/two)" == second ]] \
      || return 93
    file-compress --format tzst --output again.TZST --yes -- restored \
      || return 94
    file-extract --destination again --yes -- again.TZST || return 95
    [[ "$(<again/restored/one)" == first ]]
  '
  [ "$status" -eq 0 ]
  # Both outputs are zstd frames, whose magic number is 28 b5 2f fd.
  [ "$(head -c 4 "$HOME/bundle.tar.zst" | od -An -tx1 | tr -d ' \n')" = 28b52ffd ]
  run zstd -q -t -- "$HOME/again.TZST"
  [ "$status" -eq 0 ]
  [ -z "$(find "$HOME" \( -name '.zdx-file-archive.*' -o -name '*.zdx.*' \) -print)" ]
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

@test "file recovery: inherited default options never reach tar archive creation" {
  file_work_dir
  file_mock_archive_backend tar
  mkdir "$WORK/tree"
  printf 'important\n' > "$WORK/important.txt"
  printf 'nested\n' > "$WORK/tree/nested.txt"

  # The shell keeps its own values afterwards, still exported to children.
  run run_zsh "$FILE_HOSTILE_OPTIONS"'
    cd "$WORK" || exit 90
    file-compress --format tar.gz --output backup.tar.gz --yes \
      -- important.txt tree || exit 91
    [[ "$TAR_OPTIONS" == --remove-files && "$GZIP" == -9 ]] || exit 92
    [[ "$(command printenv TAR_OPTIONS)" == --remove-files \
      && "$(command printenv LZOP)" == -9 ]] || exit 93
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/important.txt")" = important ]
  [ "$(cat "$WORK/tree/nested.txt")" = nested ]
  [ "$(cat "$WORK/backup.tar.gz")" = "$(printf '%s\n' 'member ./important.txt: important' 'member ./tree')" ]
  file_backend_saw_no_options tar
  [ -z "$(find "$WORK" -name '.zdx-file-archive.*' -print)" ]
}

@test "file recovery: inherited default options never reach zip or 7z archive creation" {
  file_work_dir
  file_mock_archive_backend zip
  file_mock_archive_backend 7z
  printf 'zipped\n' > "$WORK/zipped.txt"
  local format
  for format in zip 7z; do
    : > "$FILE_BACKEND_ENV_LOG"
    export FILE_TEST_FORMAT="$format"
    run run_zsh "$FILE_HOSTILE_OPTIONS"'
      cd "$WORK" || exit 90
      file-compress --format "$FILE_TEST_FORMAT" \
        --output "bundle.$FILE_TEST_FORMAT" --yes -- zipped.txt
    '
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/zipped.txt")" = zipped ]
    [ "$(cat "$WORK/bundle.$format")" = 'member ./zipped.txt: zipped' ]
    file_backend_saw_no_options "$format"
  done
}

@test "file recovery: a read-only inherited default option never reaches the archive backend either" {
  file_work_dir
  file_mock_archive_backend tar
  printf 'important\n' > "$WORK/important.txt"

  # The shell keeps its own read-only, exported value afterwards.
  run run_zsh '
    typeset -rx TAR_OPTIONS=--remove-files
    cd "$WORK" || exit 90
    file-compress --format tar.gz --output backup.tar.gz --yes -- important.txt \
      || exit 91
    [[ "$TAR_OPTIONS" == --remove-files \
      && "${(t)TAR_OPTIONS}" == *readonly*export* ]] || exit 92
    [[ "$(command printenv TAR_OPTIONS)" == --remove-files ]] || exit 93
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/important.txt")" = important ]
  [ "$(cat "$WORK/backup.tar.gz")" = 'member ./important.txt: important' ]
  file_backend_saw_no_options tar
}

@test "file recovery: real GNU tar creation keeps its inputs under inherited TAR_OPTIONS and GZIP" {
  local gnu_tar_name gnu_tar
  gnu_tar_name=$(file_gnu_tar_name) \
    || skip "needs GNU tar, installed as tar or gtar"
  command -v gzip >/dev/null 2>&1 || skip "needs gzip"
  gnu_tar=$(command -v "$gnu_tar_name")
  # shellcheck disable=SC2086
  unset $FILE_ARCHIVE_OPTION_NAMES
  file_work_dir
  file_record_gzip_env
  mkdir "$WORK/tree"
  printf 'important\n' > "$WORK/important.txt"
  printf 'nested\n' > "$WORK/tree/nested.txt"

  run run_zsh '
    unfunction command
    cd "$WORK" || exit 90
    export TAR_OPTIONS=--remove-files GZIP=-9
    file-compress --format tar.gz --output backup.tar.gz --yes -- important.txt tree
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/important.txt")" = important ]
  [ "$(cat "$WORK/tree/nested.txt")" = nested ]
  file_gzip_saw_no_options
  rm -f "$TEST_MOCK_BIN/gzip"
  hash -r
  # The archive holds exactly the planned members with their bytes.
  run "$gnu_tar" -tzf "$WORK/backup.tar.gz"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort)" = "$(printf '%s\n' ./important.txt ./tree/ ./tree/nested.txt)" ]
  run "$gnu_tar" -xzOf "$WORK/backup.tar.gz" ./important.txt
  [ "$output" = important ]
  run "$gnu_tar" -xzOf "$WORK/backup.tar.gz" ./tree/nested.txt
  [ "$output" = nested ]
}

@test "file recovery: real GNU tar extraction keeps every member under inherited TAR_OPTIONS and GZIP" {
  local gnu_tar_name gnu_tar
  gnu_tar_name=$(file_gnu_tar_name) \
    || skip "hardened extraction requires GNU tar, installed as tar or gtar"
  command -v gzip >/dev/null 2>&1 || skip "needs gzip"
  gnu_tar=$(command -v "$gnu_tar_name")
  # shellcheck disable=SC2086
  unset $FILE_ARCHIVE_OPTION_NAMES
  file_work_dir
  mkdir "$WORK/source"
  printf 'keep\n' > "$WORK/source/keep.txt"
  printf 'secret\n' > "$WORK/source/secret.txt"
  "$gnu_tar" -czf "$WORK/pack.tar.gz" -C "$WORK/source" keep.txt secret.txt
  rm -rf "$WORK/source"
  file_record_gzip_env

  # An inherited exclusion would narrow the reviewed listing and the
  # extraction alike, so the tree check alone could not notice it.
  run run_zsh '
    unfunction command
    cd "$WORK" || exit 90
    export TAR_OPTIONS=--exclude=secret.txt GZIP=-9
    file-extract --destination restored --yes -- pack.tar.gz || exit 91
    [[ "$(command printenv TAR_OPTIONS)" == --exclude=secret.txt ]] || exit 93
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Members: 2"* ]]
  [ "$(cat "$WORK/restored/keep.txt")" = keep ]
  [ "$(cat "$WORK/restored/secret.txt")" = secret ]
  file_gzip_saw_no_options
}

@test "file recovery: inherited bsdtar writer options neither mislead its metadata probe nor reach creation" {
  file_work_dir
  export FILE_TAR_LOG="$TEST_TEMP_DIR/tar-log"
  # tar identifies as bsdtar and, like libarchive, refuses an undefined
  # default writer option; gtar is not GNU tar.
  cat > "$TEST_MOCK_BIN/tar" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'bsdtar 3.7.4 - libarchive 3.7.4 zlib/1.2.13\n'
  exit 0
fi
if [[ -n "${TAR_WRITER_OPTIONS+set}" ]]; then
  printf 'tar: Undefined option: %s\n' "$TAR_WRITER_OPTIONS" >&2
  exit 1
fi
printf '%s\n' "$*" >> "$FILE_TAR_LOG"
previous=""
for argument in "$@"; do
  if [[ "$previous" == -c*f && "$argument" != /dev/null ]]; then
    printf 'archive\n' > "$argument"
  fi
  previous="$argument"
done
exit 0
SH
  chmod +x "$TEST_MOCK_BIN/tar"
  printf '#!/bin/sh\nexit 1\n' > "$TEST_MOCK_BIN/gtar"
  chmod +x "$TEST_MOCK_BIN/gtar"
  printf '%s\n' data > "$WORK/one"

  run run_zsh '
    export TAR_WRITER_OPTIONS=zdx-undefined
    cd "$WORK" || exit 90
    file-compress --format tar.gz --output one.tar.gz --yes -- one || exit 91
    [[ "$(command printenv TAR_WRITER_OPTIONS)" == zdx-undefined ]] || exit 93
  '

  [ "$status" -eq 0 ]
  [ -f "$WORK/one.tar.gz" ]
  [ "$(cat "$WORK/one")" = data ]
  grep -q -- '^--no-mac-metadata --no-xattrs -czf .*/one[.]tar[.]gz -- [.]/one$' "$FILE_TAR_LOG"
}

@test "file recovery: inputs that change during creation retain and report the unpublished archive" {
  file_work_dir
  file_mock_archive_backend tar
  # The backend removes its inputs after writing the archive, so the staged
  # archive holds the only copy of their data.
  export FILE_MOCK_REMOVE_INPUTS=yes
  printf 'important\n' > "$WORK/important.txt"

  run run_zsh '
    cd "$WORK" || exit 90
    file-compress --format tar.gz --output backup.tar.gz --yes -- important.txt
  '

  [ "$status" -eq 1 ]
  [ ! -e "$WORK/backup.tar.gz" ]
  [ ! -e "$WORK/important.txt" ]
  [[ "$output" == *"Archive inputs changed during creation"* ]]
  local -a stages=("$WORK"/.zdx-file-archive.*)
  [ "${#stages[@]}" -eq 1 ]
  [ -d "${stages[0]}" ]
  [ "$(file_mode "${stages[0]}")" = 700 ]
  local kept="${stages[0]}/backup.tar.gz"
  [ "$(file_mode "$kept")" = 600 ]
  [ "$(cat "$kept")" = 'member ./important.txt: important' ]
  # The kept archive is a key-value fact (docs/output-spec.md).
  printf '%s\n' "$output" | grep -q -x -F -- "  Recovery path:     $kept"
}

@test "file recovery: the bounded zstd probe never receives inherited default options, through timeout or the watchdog" {
  file_work_dir
  export FILE_ARCHIVE_OPTION_NAMES
  export FILE_PROBE_ENV_LOG="$TEST_TEMP_DIR/probe-env"
  export FILE_TIMEOUT_LOG="$TEST_TEMP_DIR/timeout-log"
  # tar is GNU tar with --zstd and records the option variables that reach
  # its probe; any other use fails.
  cat > "$TEST_MOCK_BIN/tar" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --zstd && "${2:-}" == --version ]]; then
  for name in $FILE_ARCHIVE_OPTION_NAMES; do
    if [[ -n "${!name+set}" ]]; then
      printf '%s=%s\n' "$name" "${!name}"
    else
      printf '%s unset\n' "$name"
    fi
  done >> "$FILE_PROBE_ENV_LOG"
  printf 'tar (GNU tar) 1.35\n'
  exit 0
fi
if [[ "${1:-}" == --version ]]; then
  printf 'tar (GNU tar) 1.35\n'
  exit 0
fi
exit 2
SH
  chmod +x "$TEST_MOCK_BIN/tar"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_MOCK_BIN/zstd"
  chmod +x "$TEST_MOCK_BIN/zstd"
  # A timeout that records its use, then runs the command without a deadline.
  cat > "$TEST_MOCK_BIN/timeout" <<'SH'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >> "$FILE_TIMEOUT_LOG"
while [[ "${1:-}" == -* ]]; do
  if [[ "$1" == -k ]]; then shift 2; else shift; fi
done
shift
exec "$@"
SH
  chmod +x "$TEST_MOCK_BIN/timeout"
  printf '%s\n' data > "$WORK/one"
  local expected="" name mode
  for name in $FILE_ARCHIVE_OPTION_NAMES; do
    expected+="$name unset"$'\n'
  done

  for mode in timeout watchdog; do
    : > "$FILE_PROBE_ENV_LOG"
    : > "$FILE_TIMEOUT_LOG"
    export FILE_TEST_TIMEOUT_MODE="$mode"
    run run_zsh "$FILE_HOSTILE_OPTIONS"'
      if [[ "$FILE_TEST_TIMEOUT_MODE" == watchdog ]]; then
        # Without timeout or gtimeout, the core runs its Zsh watchdog.
        command() {
          [[ "$1" == -v && ( "$2" == timeout || "$2" == gtimeout ) ]] \
            && return 1
          builtin command "$@"
        }
      fi
      cd "$WORK" || exit 90
      file-compress --format tar.zst --output one.tar.zst --dry-run -- one \
        || exit 91
      # The probe ran in this shell, which still exports its own values.
      [[ "$(command printenv TAR_OPTIONS)" == --remove-files \
        && "$(command printenv LZOP)" == -9 ]] || exit 93
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry run complete; no archive was created."* ]]
    # The dry run probes once, and the probe saw none of the variables.
    [ "$(cat "$FILE_PROBE_ENV_LOG")" = "${expected%$'\n'}" ]
    if [[ "$mode" == timeout ]]; then
      grep -q -- '^timeout -k 2s 10s .*/tar --zstd --version$' "$FILE_TIMEOUT_LOG"
    else
      [ ! -s "$FILE_TIMEOUT_LOG" ]
    fi
  done
  [ ! -e "$WORK/one.tar.zst" ]
}

@test "file recovery: the archive tool runner refuses an empty or invalid timeout without running the tool" {
  file_work_dir

  run run_zsh '
    file-menu --help >/dev/null 2>&1
    local value=""
    for value in "" 0 601 1x; do
      _file_run_archive_tool --timeout "$value" touch "$WORK/ran-$value"
      (( $? == 2 )) || exit 91
    done
    _file_run_archive_tool --timeout
    (( $? == 2 )) || exit 92
    _file_run_archive_tool
    (( $? == 2 )) || exit 93
  '

  [ "$status" -eq 0 ]
  [ -z "$(find "$WORK" -name 'ran-*' -print)" ]
}
