#!/usr/bin/env bats

# Real fixture construction must not inherit options that production masks.
extract_fixture_tar() {
  env -u TAR_OPTIONS -u TAR_READER_OPTIONS -u TAR_WRITER_OPTIONS -u TAPE \
    -u GZIP -u XZ_DEFAULTS -u XZ_OPT -u BZIP2 -u BZIP -u LBZIP2 -u LZOP \
    -u ZSTD_CLEVEL -u ZSTD_NBTHREADS "$@"
}

setup() {
  EXTRACT_ORIGINAL_PATH="$PATH"
  load test_helper
  export EXTRACT_ROOT="$HOME/extraction" EXTRACT_WORK="$HOME/extraction/work"
  export EXTRACT_REAL_TAR="" EXTRACT_REAL_RM EXTRACT_REAL_GZIP
  EXTRACT_REAL_RM=$(type -P rm)
  EXTRACT_REAL_GZIP=$(type -P gzip)
  local candidate version
  for candidate in tar gtar; do
    candidate=$(type -P "$candidate") || continue
    version=$(extract_fixture_tar "$candidate" --version) || continue
    if [[ "$version" == *'GNU tar'* ]]; then EXTRACT_REAL_TAR="$candidate"; break; fi
  done
  [[ -n "$EXTRACT_REAL_TAR" ]] || skip 'hardened extraction requires GNU tar'
  mkdir -p "$EXTRACT_WORK" "$EXTRACT_ROOT/tmp"
  export TMPDIR="$EXTRACT_ROOT/tmp" EXTRACT_TAR_LOG="$EXTRACT_ROOT/tar.log"
  export EXTRACT_CODEC_LOG="$EXTRACT_ROOT/codec.log"
  chmod -- 700 "$EXTRACT_ROOT" "$EXTRACT_WORK" "$TMPDIR"
  command python3 -B -I -S - "$EXTRACT_WORK" <<'PY'
import bz2
import gzip
import io
import lzma
from pathlib import Path
import sys
import tarfile

root = Path(sys.argv[1])
for name, directory, mode in [("plain.tar", None, 0), ("root-dot.tar", "./", 0o755),
                               ("root-repeat.tar", "././", 0o755), ("locked.tar", "locked/", 0)]:
    with tarfile.open(root / name, "w", format=tarfile.GNU_FORMAT) as archive:
        if directory is not None:
            entry = tarfile.TarInfo(directory)
            entry.type = tarfile.DIRTYPE
            entry.mode = mode
            archive.addfile(entry)
        data = b"payload\n"
        entry = tarfile.TarInfo("locked/data" if directory == "locked/" else "data")
        entry.mode = 0o600
        entry.size = len(data)
        archive.addfile(entry, io.BytesIO(data))
with tarfile.open(root / "root-file.tar", "w", format=tarfile.GNU_FORMAT) as archive:
    entry = tarfile.TarInfo(".")
    entry.mode = 0o600
    entry.size = 8
    archive.addfile(entry, io.BytesIO(b"payload\n"))
with tarfile.open(root / "root-duplicate.tar", "w", format=tarfile.GNU_FORMAT) as archive:
    for name in ["./", "././"]:
        entry = tarfile.TarInfo(name)
        entry.type = tarfile.DIRTYPE
        entry.mode = 0o755
        archive.addfile(entry)
plain = (root / "plain.tar").read_bytes()
(root / "gzip.tar.gz").write_bytes(gzip.compress(plain))
(root / "gzip-disguised.tar").write_bytes(gzip.compress(plain))
(root / "plain-disguised.tar.gz").write_bytes(plain)
(root / "xz.tar.xz").write_bytes(lzma.compress(plain))
(root / "bzip.tar.bz2").write_bytes(bz2.compress(plain))
(root / "lzop.tar").write_bytes(b"\x89LZO\x00\r\n\x1a\n0123456789abcdef")
PY
  if type -P zstd >/dev/null; then
    env -u ZSTD_CLEVEL -u ZSTD_NBTHREADS zstd -q -T1 -c "$EXTRACT_WORK/plain.tar" \
      > "$EXTRACT_WORK/zstd.tar.zst"
  fi
  printf '#!%s -f\n' "$(type -P zsh)" > "$TEST_MOCK_BIN/tar"
  cat >> "$TEST_MOCK_BIN/tar" <<'MOCK'
emulate -R zsh
[[ "$EXTRACT_ROOT" == "$HOME/extraction" && -d "$EXTRACT_ROOT" && ! -L "$EXTRACT_ROOT" ]] || exit 97
if [[ $# == 1 && "$1" == --version ]] \
  || [[ $# == 2 && "$1" == --zstd && "$2" == --version ]]; then
  exec "$EXTRACT_REAL_TAR" "$@"
fi
local argument="" source_file="" directory="" action="" codec="none" verbose=0
for argument in "$@"; do
  case "$argument" in
    --list) [[ -z "$action" ]] || exit 97; action=list ;;
    --extract) [[ -z "$action" ]] || exit 97; action=extract ;;
    --verbose) verbose=1 ;;
    --file=*) source_file="${argument#--file=}" ;;
    --directory=*) directory="${argument#--directory=}" ;;
    -z|-J|-j|--zstd) [[ "$codec" == none ]] || exit 97; codec="$argument" ;;
    --numeric-owner|--quoting-style=escape|--no-same-owner|--no-same-permissions|--no-overwrite-dir) ;;
    *) exit 97 ;;
  esac
done
[[ "$action" == list || "$action" == extract ]] || exit 97
if [[ "$source_file" != - ]]; then
  [[ "$source_file" == "$EXTRACT_WORK"/* && "$source_file" == "${source_file:A}" \
    && -f "$source_file" && ! -L "$source_file" ]] || exit 97
fi
if [[ "$action" == extract ]]; then
  [[ "${directory:h}" == "$EXTRACT_WORK" && "${directory:t}" == .zdx-file-archive.?????? \
    && "$directory" == "${directory:A}" && -d "$directory" && ! -L "$directory" ]] || exit 97
fi
print -r -- "$action:$verbose:$codec:$source_file" >> "$EXTRACT_TAR_LOG"
"$EXTRACT_REAL_TAR" "$@"
local -i child_rc=$?
if [[ "$action" == extract && $child_rc == 0 ]]; then
  zmodload -F zsh/stat b:zstat || exit 97
  local -A state=()
  zstat -LH state -- "$directory" || exit 97
  printf 'mode:%o\n' "$(( state[mode] & 8#777 ))" >> "$EXTRACT_TAR_LOG"
  [[ -z "${EXTRACT_FORCE_FAILURE:-}" ]] || exit "$EXTRACT_FORCE_FAILURE"
fi
exit "$child_rc"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/tar"
  printf '#!%s -f\n' "$(type -P zsh)" > "$TEST_MOCK_BIN/rm"
  cat >> "$TEST_MOCK_BIN/rm" <<'MOCK'
emulate -R zsh
[[ $# == 3 && ( "$1" == -f || "$1" == -rf ) && "$2" == -- ]] || exit 97
local target="$3"
[[ "$EXTRACT_ROOT" == "$HOME/extraction" && -d "$EXTRACT_ROOT" && ! -L "$EXTRACT_ROOT" \
  && "/$target/" != */../* && "$target" == "$EXTRACT_ROOT"/* \
  && "$target" == "${target:A}" ]] || exit 97
if [[ "${target:h}" == "$EXTRACT_WORK" && "${target:t}" == .zdx-file-archive.* ]]; then
  [[ "${EXTRACT_REFUSE_CLEANUP:-}" != yes ]] || exit 71
  [[ "${EXTRACT_NOOP_CLEANUP:-}" != yes ]] || exit 0
  if [[ "${EXTRACT_HIDE_PARENT_AFTER_REMOVE:-}" == yes ]]; then
    "$EXTRACT_REAL_RM" "$@" || exit $?
    chmod -- 000 "$EXTRACT_WORK" || exit 98
    exit 0
  fi
fi
exec "$EXTRACT_REAL_RM" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/rm"
  printf '#!%s -f\n' "$(type -P zsh)" > "$TEST_MOCK_BIN/gzip"
  cat >> "$TEST_MOCK_BIN/gzip" <<'MOCK'
emulate -R zsh
[[ "$EXTRACT_ROOT" == "$HOME/extraction" && -d "$EXTRACT_ROOT" && ! -L "$EXTRACT_ROOT" \
  && $# == 1 && "$1" == -d ]] || exit 97
print -r -- gzip >> "$EXTRACT_CODEC_LOG"
exec "$EXTRACT_REAL_GZIP" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/gzip"
  printf '#!%s -f\n' "$(type -P zsh)" > "$TEST_MOCK_BIN/lzop"
  cat >> "$TEST_MOCK_BIN/lzop" <<'MOCK'
emulate -R zsh
[[ "$EXTRACT_ROOT" == "$HOME/extraction" && -d "$EXTRACT_ROOT" && ! -L "$EXTRACT_ROOT" \
  && $# == 1 && "$1" == -d ]] || exit 97
print -r -- lzop >> "$EXTRACT_CODEC_LOG"
exit 87
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/lzop"
}

teardown() {
  local stage
  shopt -s nullglob
  for stage in "$EXTRACT_WORK"/.zdx-file-archive.*; do
    [[ -d "$stage" && ! -L "$stage" ]] || continue
    [[ ! -d "$stage/locked" || -L "$stage/locked" ]] \
      || chmod -- 700 "$stage/locked"
  done
  PATH="$EXTRACT_ORIGINAL_PATH"
  hash -r
  cleanup_sandbox
}

run_extract_scope() {
  run_zsh 'builtin cd -- "$EXTRACT_WORK" || return 90; '"$1"
}

assert_root_archive_private() {
  export EXTRACT_INPUT="$1"
  run run_extract_scope 'file-extract --destination result --yes -- "$EXTRACT_INPUT"'
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    [[ ! -f "$EXTRACT_TAR_LOG" ]] || cat "$EXTRACT_TAR_LOG" >&2
    false
  fi
  [ "$(cat "$EXTRACT_WORK/result/data")" = payload ]
  [ "$(file_mode "$EXTRACT_WORK/result")" = 700 ]
  grep -Fxq -- mode:700 "$EXTRACT_TAR_LOG"
}

@test "file extraction scope: a standard root directory member stays private" { assert_root_archive_private root-dot.tar; }
@test "file extraction scope: repeated root dot components stay private" { assert_root_archive_private root-repeat.tar; }

@test "file extraction scope: a failed cleanup reports the exact retained extraction" {
  export EXTRACT_REFUSE_CLEANUP=yes EXTRACT_FORCE_FAILURE=65
  run run_extract_scope 'file-extract --destination result --yes -- plain.tar >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui"'
  [ "$status" -ne 0 ]
  [ ! -s "$EXTRACT_ROOT/data.out" ]
  local -a stages=("$EXTRACT_WORK"/.zdx-file-archive.*)
  [ "${#stages[@]}" -eq 1 ]
  [ "$(cat "${stages[0]}/data")" = payload ]
  grep -Fq -- "~${stages[0]#"$HOME"}" "$EXTRACT_ROOT/ui"
  grep -Fq -- 'Recovery path:' "$EXTRACT_ROOT/ui"
  grep -Eq 'incomplete|unvalidated' "$EXTRACT_ROOT/ui"
}

@test "file extraction scope: a mode-changed original staging object is named without deletion" {
  run run_extract_scope '
    _file_archive_stage_dir "$EXTRACT_WORK" || return 91
    local stage="${reply[1]}" identity="${reply[2]}"
    print -r -- kept > "$stage/data"
    command chmod -- 755 "$stage" || return 92
    _file_archive_cleanup_stage "$stage" "$identity" >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui"
  '
  [ "$status" -eq 1 ]
  [ ! -s "$EXTRACT_ROOT/data.out" ]
  local -a stages=("$EXTRACT_WORK"/.zdx-file-archive.*)
  [ "$(cat "${stages[0]}/data")" = kept ]
  grep -Fq -- 'Recovery path:' "$EXTRACT_ROOT/ui"
  grep -Fq -- "~${stages[0]#"$HOME"}" "$EXTRACT_ROOT/ui"
}

@test "file extraction scope: a replacement staging inode is never claimed as recovered data" {
  run run_extract_scope '
    _file_archive_stage_dir "$EXTRACT_WORK" || return 91
    local stage="${reply[1]}" identity="${reply[2]}"
    command mv -- "$stage" "$EXTRACT_ROOT/original" || return 92
    command mkdir -- "$stage" || return 93
    print -r -- replacement > "$stage/data"
    _file_archive_cleanup_stage "$stage" "$identity" >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui"
  '
  [ "$status" -eq 1 ]
  local -a stages=("$EXTRACT_WORK"/.zdx-file-archive.*)
  [ "$(cat "${stages[0]}/data")" = replacement ]
  [ -d "$EXTRACT_ROOT/original" ]
  run grep -Fq -- 'Recovery path:' "$EXTRACT_ROOT/ui"
  [ "$status" -eq 1 ]
  grep -Fq -- 'Unverified path:' "$EXTRACT_ROOT/ui"
}

@test "file extraction scope: a successful no-op remover cannot hide retained staging" {
  export EXTRACT_NOOP_CLEANUP=yes
  run run_extract_scope '
    _file_archive_stage_dir "$EXTRACT_WORK" || return 91
    local stage="${reply[1]}" identity="${reply[2]}"
    print -r -- kept > "$stage/data"
    _file_archive_cleanup_stage "$stage" "$identity" >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui"
  '
  [ "$status" -eq 1 ]
  local -a stages=("$EXTRACT_WORK"/.zdx-file-archive.*)
  [ "$(cat "${stages[0]}/data")" = kept ]
  grep -Fq -- 'Recovery path:' "$EXTRACT_ROOT/ui"
}

@test "file extraction scope: absent staging creates no recovery claim" {
  run run_extract_scope '
    _file_archive_stage_dir "$EXTRACT_WORK" || return 91
    local stage="${reply[1]}" identity="${reply[2]}"
    "$EXTRACT_REAL_RM" -rf -- "$stage" || return 92
    _file_archive_cleanup_stage "$stage" "$identity" >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui"
  '
  [ "$status" -eq 1 ]
  run grep -Fq -- 'Recovery path:' "$EXTRACT_ROOT/ui"
  [ "$status" -eq 1 ]
}

@test "file extraction scope: an unreadable extracted directory remains visible on cleanup failure" {
  [[ "$EUID" -ne 0 ]] || skip 'permission denial requires a non-root fixture process'
  run run_extract_scope 'file-extract --destination result --yes -- locked.tar >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui"'
  [ "$status" -eq 1 ]
  [ ! -s "$EXTRACT_ROOT/data.out" ]
  local -a stages=("$EXTRACT_WORK"/.zdx-file-archive.*)
  [ "${#stages[@]}" -eq 1 ]
  [ "$(file_mode "${stages[0]}/locked")" = 0 ]
  grep -Fq -- 'Recovery path:' "$EXTRACT_ROOT/ui"
  grep -Fq -- "~${stages[0]#"$HOME"}" "$EXTRACT_ROOT/ui"
}

@test "file extraction scope: gzip data named tar never reaches a decompressor" {
  run run_extract_scope 'file-extract --destination result --dry-run -- gzip-disguised.tar'
  [ "$status" -eq 1 ]
  [ ! -s "$EXTRACT_CODEC_LOG" ]
  [ ! -e "$EXTRACT_WORK/result" ]
}

@test "file extraction scope: lzop data named tar never reaches a decompressor" {
  run run_extract_scope 'file-extract --destination result --dry-run -- lzop.tar'
  [ "$status" -eq 1 ]
  [ ! -s "$EXTRACT_CODEC_LOG" ]
  [ ! -e "$EXTRACT_WORK/result" ]
}

@test "file extraction scope: a gzip extension cannot select plain tar content" {
  run run_extract_scope 'file-extract --destination result --dry-run -- plain-disguised.tar.gz'
  [ "$status" -eq 1 ]
  [ ! -e "$EXTRACT_WORK/result" ]
}

assert_codec_roundtrip() {
  export EXTRACT_INPUT="$1"
  run run_extract_scope 'file-extract --destination result --yes -- "$EXTRACT_INPUT"'
  [ "$status" -eq 0 ]
  [ "$(cat "$EXTRACT_WORK/result/data")" = payload ]
  grep -Eq "^list:0:$2:" "$EXTRACT_TAR_LOG"
  grep -Eq "^list:1:$2:" "$EXTRACT_TAR_LOG"
  grep -Eq "^extract:0:$2:" "$EXTRACT_TAR_LOG"
}

@test "file extraction scope: plain tar has one uncompressed read policy" { assert_codec_roundtrip plain.tar none; }
@test "file extraction scope: gzip is explicit for both inventories and extraction" { assert_codec_roundtrip gzip.tar.gz -z; }
@test "file extraction scope: xz is explicit for both inventories and extraction" { assert_codec_roundtrip xz.tar.xz -J; }
@test "file extraction scope: bzip2 is explicit for both inventories and extraction" { assert_codec_roundtrip bzip.tar.bz2 -j; }
@test "file extraction scope: zstd is explicit for both inventories and extraction" {
  [[ -f "$EXTRACT_WORK/zstd.tar.zst" ]] || skip 'zstd roundtrip requires the installed codec'
  assert_codec_roundtrip zstd.tar.zst --zstd
}

@test "file extraction scope: a tar-C-tree-dot archive retains its ordinary root member" {
  mkdir -p "$EXTRACT_ROOT/tree"
  printf 'payload\n' > "$EXTRACT_ROOT/tree/data"
  export TAR_OPTIONS=--remove-files
  extract_fixture_tar "$EXTRACT_REAL_TAR" --create --file="$EXTRACT_WORK/generated.tar" --directory="$EXTRACT_ROOT/tree" .
  assert_root_archive_private generated.tar
  [ "$(cat "$EXTRACT_ROOT/tree/data")" = payload ]
}

@test "file extraction scope: a root member cannot be a regular file" {
  run run_extract_scope 'file-extract --destination result --dry-run -- root-file.tar'
  [ "$status" -eq 1 ]
  [ ! -e "$EXTRACT_WORK/result" ]
}

@test "file extraction scope: equivalent root entries remain duplicate members" {
  run run_extract_scope 'file-extract --destination result --dry-run -- root-duplicate.tar'
  [ "$status" -eq 1 ]
  [ ! -e "$EXTRACT_WORK/result" ]
}

@test "file extraction scope: public extraction reports replacement by a regular file as unverified" {
  run run_extract_scope '
    functions[_file_peer_archive_tool]="${functions[_file_run_archive_tool]}"
    _file_run_archive_tool() {
      _file_peer_archive_tool "$@" || return $?
      if [[ "$*" == *--extract* ]]; then
        local item="" stage=""
        for item in "$@"; do
          [[ "$item" != --directory=* ]] || stage="${item#--directory=}"
        done
        [[ "${stage:h}" == "$EXTRACT_WORK" && "${stage:t}" == .zdx-file-archive.?????? \
          && "$stage" == "${stage:A}" && -d "$stage" && ! -L "$stage" ]] || return 97
        command mv -- "$stage" "$EXTRACT_ROOT/original-stage" || return 98
        print -r -- replacement > "$stage"
        print -r -- "$stage" > "$EXTRACT_ROOT/replaced-stage-path"
        return 65
      fi
    }
    file-extract --destination result --yes -- plain.tar >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui"
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$EXTRACT_ROOT/original-stage/data")" = payload ]
  local stage
  stage=$(cat "$EXTRACT_ROOT/replaced-stage-path")
  [ "$(cat "$stage")" = replacement ]
  grep -Fq -- 'Unverified path:' "$EXTRACT_ROOT/ui"
}

@test "file extraction scope: inaccessible parent produces an unverified staging path instead of apparent absence" {
  [[ "$EUID" -ne 0 ]] || skip 'permission denial requires a non-root fixture process'
  run run_extract_scope '
    _file_archive_stage_dir "$EXTRACT_WORK" || return 91
    local stage="${reply[1]}" identity="${reply[2]}" cleanup_rc=0
    print -r -- kept > "$stage/data"
    command chmod -- 000 "$EXTRACT_WORK" || return 92
    _file_archive_cleanup_stage "$stage" "$identity" >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui" || cleanup_rc=$?
    command chmod -- 700 "$EXTRACT_WORK" || return 93
    [[ -f "$stage/data" && "$(<"$stage/data")" == kept ]] || return 94
    print -r -- "$stage" > "$EXTRACT_ROOT/inaccessible-stage-path"
    return "$cleanup_rc"
  '
  chmod -- 700 "$EXTRACT_WORK"
  [ "$status" -eq 1 ]
  local stage
  stage=$(cat "$EXTRACT_ROOT/inaccessible-stage-path")
  [ "$(cat "$stage/data")" = kept ]
  grep -Fq -- 'Unverified path:' "$EXTRACT_ROOT/ui"
}

@test "file extraction scope: compression reports a regular replacement without removing it" {
  run run_extract_scope '
    functions[_file_scope_archive_tool]="${functions[_file_run_archive_tool]}"
    _file_run_archive_tool() {
      if [[ "$*" != *-czf* ]]; then
        _file_scope_archive_tool "$@"
        return $?
      fi
      local argument="" staged="" previous=""
      for argument in "$@"; do
        [[ "$previous" != -czf ]] || staged="$argument"
        previous="$argument"
      done
      local stage="${staged:h}"
      [[ "${stage:h}" == "$EXTRACT_WORK" && "${stage:t}" == .zdx-file-archive.?????? \
        && "$stage" == "${stage:A}" && -d "$stage" && ! -L "$stage" ]] || return 97
      print -r -- unpublished > "$staged"
      command mv -- "$stage" "$EXTRACT_ROOT/compression-original" || return 98
      print -r -- replacement > "$stage"
      print -r -- "$stage" > "$EXTRACT_ROOT/compression-stage-path"
      return 65
    }
    file-compress --format tar.gz --output output.tar.gz --yes -- plain.tar \
      >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui"
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$EXTRACT_ROOT/compression-original/output.tar.gz")" = unpublished ]
  local stage
  stage=$(cat "$EXTRACT_ROOT/compression-stage-path")
  [ "$(cat "$stage")" = replacement ]
  [ -f "$EXTRACT_WORK/plain.tar" ]
  [ ! -e "$EXTRACT_WORK/output.tar.gz" ]
  grep -Fq -- 'Unverified path:' "$EXTRACT_ROOT/ui"
}

@test "file extraction scope: cleanup cannot claim success through a newly inaccessible parent" {
  [[ "$EUID" -ne 0 ]] || skip 'permission denial requires a non-root fixture process'
  export EXTRACT_HIDE_PARENT_AFTER_REMOVE=yes
  run run_extract_scope '
    _file_archive_stage_dir "$EXTRACT_WORK" || return 91
    local stage="${reply[1]}" identity="${reply[2]}" cleanup_rc=0
    print -r -- kept > "$stage/data"
    _file_archive_cleanup_stage "$stage" "$identity" \
      >"$EXTRACT_ROOT/data.out" 2>"$EXTRACT_ROOT/ui" || cleanup_rc=$?
    command chmod -- 700 "$EXTRACT_WORK" || return 93
    [[ ! -e "$stage" && ! -L "$stage" ]] || return 94
    return "$cleanup_rc"
  '
  chmod -- 700 "$EXTRACT_WORK"
  [ "$status" -eq 1 ]
  grep -Fq -- 'Unverified path:' "$EXTRACT_ROOT/ui"
  run grep -Fq -- 'Recovery path:' "$EXTRACT_ROOT/ui"
  [ "$status" -eq 1 ]
}
