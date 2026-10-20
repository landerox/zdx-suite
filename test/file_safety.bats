#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

# file_zstd_tar_available: true when the host's GNU tar (tar or gtar) accepts
# --zstd and zstd is installed, which zstd TAR archives require.
file_zstd_tar_available() {
  local name version
  command -v zstd >/dev/null 2>&1 || return 1
  for name in tar gtar; do
    command -v "$name" >/dev/null 2>&1 || continue
    version=$("$name" --version 2>/dev/null | head -n 1) || continue
    [[ "$version" == *"GNU tar"* ]] || continue
    "$name" --zstd --version >/dev/null 2>&1
    return
  done
  return 1
}

# mock_gnu_tar_listing SIZE: tar and gtar identify as GNU tar and list one
# regular member, big, that declares SIZE bytes. Other uses are logged to
# FILE_TAR_LOG, when set, and fail.
mock_gnu_tar_listing() {
  export FILE_TAR_MEMBER_SIZE="$1"
  cat > "$TEST_MOCK_BIN/tar" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --version "*)
    printf 'tar (GNU tar) 1.35\n'
    exit 0
    ;;
  *" --list --verbose "*)
    printf -- '-rw-r--r-- 0/0 %s 2026-10-18 00:00 big\n' "$FILE_TAR_MEMBER_SIZE"
    exit 0
    ;;
  *" --list "*)
    printf 'big\n'
    exit 0
    ;;
esac
[[ -z "${FILE_TAR_LOG:-}" ]] || printf '%s\n' "$*" >> "$FILE_TAR_LOG"
exit 2
SH
  chmod +x "$TEST_MOCK_BIN/tar"
  cp "$TEST_MOCK_BIN/tar" "$TEST_MOCK_BIN/gtar"
}

@test "file safety: a leading-dash large-file target remains data" {
  run run_zsh '
    mkdir "$HOME/large" && cd "$HOME/large" || return
    print -r -- data > ./-victim
    file-find-large --min-size 1 --delete --yes || return
    [[ ! -e ./-victim ]]
  '
  [ "$status" -eq 0 ]
}

@test "file safety: large-file deletion still refuses the whole plan for an unsafe target" {
  # shellcheck disable=SC2016
  run run_zsh '
    mkdir "$HOME/large" && cd "$HOME/large" || return
    print -r -- data > safe
    print -r -- data > shared
    chmod 664 shared
    file-find-large --min-size 1 --delete --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ownership or permissions are unsafe"* ]]
  [[ "$output" != *"Deleted"* ]]
  [ -f "$HOME/large/safe" ]
  [ -f "$HOME/large/shared" ]
}

@test "file safety: extractor rejects an unvalidated backend" {
  run run_zsh '
    cd "$HOME"
    touch archive.zip
    file-extract --destination extracted --yes -- archive.zip
  '
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/extracted" ]
  [[ "$output" == *"only TAR archives"* ]]
}

@test "file safety: deletion targets cannot contain one another" {
  run run_zsh '
    cd "$HOME"
    mkdir -p parent/child
    _file_collect_paths() { reply=(parent parent/child); return 0; }
    file-find-large --min-size 1 --delete --dry-run
  '
  [ "$status" -ne 0 ]
  [ -d "$HOME/parent/child" ]
  [[ "$output" == *"may not contain one another"* ]]
}

@test "file safety: archive outputs remain inside the current base" {
  run run_zsh '
    cd "$HOME"
    print -r -- content > input
    file-compress --format tar.gz --output ../escape.tar.gz --yes -- input
  '
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TEMP_DIR/escape.tar.gz" ]
}

@test "file safety: a directory archive input plans exactly that directory" {
  # shellcheck disable=SC2016
  run run_zsh '
    mkdir -p "$HOME/work/tree/nested" && cd "$HOME/work" || return
    print -r -- data > tree/nested/file
    file-compress --format tar.gz --output tree.tar.gz --yes -- tree
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Inputs: 1"* ]]
  [[ "$output" != *".zdx-file-archive."* ]]
  [ -f "$HOME/work/tree.tar.gz" ]
  run tar -tzf "$HOME/work/tree.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"./tree/nested/file"* ]]
}

@test "file safety: zstd archives meet the same preflight refusals as every TAR" {
  file_zstd_tar_available \
    || skip "zstd TAR archives require GNU tar with --zstd and zstd"
  python3 - "$HOME" <<'PY'
import io
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])


def add_file(archive, name):
    data = b"payload\n"
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o644
    archive.addfile(info, io.BytesIO(data))


with tarfile.open(root / "traversal.tar", "w", format=tarfile.GNU_FORMAT) as archive:
    add_file(archive, "safe.txt")
    add_file(archive, "../escape.txt")
with tarfile.open(root / "link.tar", "w", format=tarfile.GNU_FORMAT) as archive:
    add_file(archive, "safe.txt")
    info = tarfile.TarInfo("pointer")
    info.type = tarfile.SYMTYPE
    info.linkname = "/etc/passwd"
    archive.addfile(info)
PY
  zstd -q --rm -o "$HOME/traversal.tar.zst" "$HOME/traversal.tar"
  zstd -q --rm -o "$HOME/link.tzst" "$HOME/link.tar"

  run run_zsh '
    unfunction command
    cd "$HOME" && file-extract --destination out --yes -- traversal.tar.zst
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Archive contains a parent-directory traversal."* ]]
  [[ "$output" != *"Archive Extraction Plan"* ]]

  run run_zsh '
    unfunction command
    cd "$HOME" && file-extract --destination out --yes -- link.tzst
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Archive links and special files are not accepted."* ]]
  [[ "$output" != *"Archive Extraction Plan"* ]]

  [ ! -e "$HOME/out" ]
  [ ! -e "$HOME/escape.txt" ]
  [ ! -e "$TEST_TEMP_DIR/escape.txt" ]
  [ -z "$(find "$HOME" \( -name '.zdx-file-archive.*' -o -name '*.zdx.*' \) -print)" ]
}

@test "file safety: FILE_EXTRACT_MAX_GIB bounds the declared expansion from 1 to 64 GiB" {
  unset FILE_EXTRACT_MAX_GIB
  : > "$HOME/big.tar"

  # The default is 1 GiB, so one byte more is refused before any extraction.
  mock_gnu_tar_listing 1073741825
  run run_zsh 'cd "$HOME" && file-extract --destination out --dry-run -- big.tar'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Archive exceeds the 1 GiB expanded-size limit (FILE_EXTRACT_MAX_GIB)."* ]]

  export FILE_EXTRACT_MAX_GIB=2
  run run_zsh 'cd "$HOME" && file-extract --destination out --dry-run -- big.tar'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Declared bytes: 1073741825"* ]]

  # 64 GiB is the upper bound; its 11-digit size still parses.
  export FILE_EXTRACT_MAX_GIB=64
  mock_gnu_tar_listing 68719476736
  run run_zsh 'cd "$HOME" && file-extract --destination out --dry-run -- big.tar'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Declared bytes: 68719476736"* ]]
  mock_gnu_tar_listing 68719476737
  run run_zsh 'cd "$HOME" && file-extract --destination out --dry-run -- big.tar'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Archive exceeds the 64 GiB expanded-size limit (FILE_EXTRACT_MAX_GIB)."* ]]
  [ ! -e "$HOME/out" ]

  unset FILE_EXTRACT_MAX_GIB
  run run_zsh '
    file-menu --help >/dev/null 2>&1
    print -r -- "default=$FILE_EXTRACT_MAX_GIB"
    _file_extract_max_bytes || return 91
    print -r -- "$REPLY"
    FILE_EXTRACT_MAX_GIB=01
    _file_extract_max_bytes || return 92
    print -r -- "$REPLY"
    FILE_EXTRACT_MAX_GIB=64
    _file_extract_max_bytes || return 93
    print -r -- "$REPLY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'default=1\n1073741824\n1073741824\n68719476736' ]
}

@test "file safety: an invalid FILE_EXTRACT_MAX_GIB fails closed before the archive is read" {
  export FILE_TAR_LOG="$TEST_TEMP_DIR/tar-log"
  mock_gnu_tar_listing 1
  : > "$HOME/archive.tar"
  local value
  for value in 0 65 '' abc 1.5 -1 ' 1' 007 1e1; do
    export FILE_EXTRACT_MAX_GIB="$value"
    run run_zsh 'cd "$HOME" && file-extract --destination out --dry-run -- archive.tar'
    [ "$status" -eq 1 ]
    [[ "$output" == *"FILE_EXTRACT_MAX_GIB must be an integer from 1 to 64."* ]]
    [[ "$output" != *"Archive Extraction Plan"* ]]
  done
  [ ! -e "$FILE_TAR_LOG" ]
  [ ! -e "$HOME/out" ]
  [ -z "$(find "$HOME" -name '*.zdx.*' -print)" ]
}
