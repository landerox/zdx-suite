#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
#
# File portability: macOS, WSL, and BSD-userland branches reproduced on any
# host through uname mocks, PATH shims, function overrides, and fixtures.

setup() {
  FILE_PLATFORM_ORIGINAL_PATH="$PATH"
  load test_helper
  export WORK="$HOME/work"
  mkdir -p "$WORK"
}

teardown() {
  # Do not leave a cached command pointing to a mock inside the sandbox.
  PATH="$FILE_PLATFORM_ORIGINAL_PATH"
  hash -r
  cleanup_sandbox
}

# mock_kernel NAME [RELEASE]: uname -s reports NAME and uname -r RELEASE.
mock_kernel() {
  cat > "$TEST_MOCK_BIN/uname" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  -r) printf '%s\n' '${2:-1.0}' ;;
  *) printf '%s\n' '$1' ;;
esac
SH
  chmod +x "$TEST_MOCK_BIN/uname"
}

# file_gnu_tar_path: the host's GNU tar, found as tar or gtar, or status 1.
file_gnu_tar_path() {
  local name candidate version
  for name in tar gtar; do
    candidate=$(command -v "$name" 2>/dev/null) || continue
    version=$("$candidate" --version 2>/dev/null | head -n 1) || continue
    if [[ "$version" == *"GNU tar"* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# mock_bsd_tar LOG: a tar that identifies as bsdtar, accepts the macOS
# metadata options, records each creation, and writes the archive it names.
mock_bsd_tar() {
  export FILE_TAR_LOG="$1"
  cat > "$TEST_MOCK_BIN/tar" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3\n'
  exit 0
fi
printf 'COPYFILE_DISABLE=%s %s\n' "${COPYFILE_DISABLE:-unset}" "$*" >> "$FILE_TAR_LOG"
previous=""
for argument in "$@"; do
  case "$previous" in
    -c*f) [[ "$argument" == /dev/null ]] || printf 'archive\n' > "$argument" ;;
  esac
  previous="$argument"
done
exit 0
SH
  chmod +x "$TEST_MOCK_BIN/tar"
}

# mock_bsd_find: a find without the GNU predicates junk discovery uses.
mock_bsd_find() {
  export FILE_REAL_FIND
  FILE_REAL_FIND=$(command -v find)
  cat > "$TEST_MOCK_BIN/find" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    -readable|-executable|-printf|-fprintf)
      printf 'find: %s: unknown primary or operator\n' "$argument" >&2
      exit 1
      ;;
  esac
done
exec "$FILE_REAL_FIND" "$@"
SH
  chmod +x "$TEST_MOCK_BIN/find"
}

@test "file platform: macOS deletion compares devices and reads no mount table" {
  mock_kernel Darwin
  printf '%s\n' first > "$WORK/one.txt"
  printf '%s\n' second > "$WORK/two.txt"

  run run_zsh '
    _file_mount_table_path() {
      print -r -- read >> "$HOME/table-reads"
      REPLY=/nonexistent/mountinfo
    }
    cd "$WORK" || return 90
    file-find-large --min-size 1 --delete --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Deletion completed: 2 files deleted."* ]]
  [ ! -e "$WORK/one.txt" ]
  [ ! -e "$WORK/two.txt" ]
  [ ! -e "$HOME/table-reads" ]
}

@test "file platform: macOS refuses a node whose device differs from its parent" {
  mock_kernel Darwin
  mkdir -p "$WORK/tree/volume"
  printf '%s\n' data > "$WORK/tree/volume/file"

  run run_zsh '
    cd "$WORK" || return 90
    _file_path_device() {
      zmodload -F zsh/stat b:zstat || return 1
      local -A device_state=()
      zstat -LH device_state -- "$1" || return 1
      REPLY="${device_state[device]}"
      [[ "$1" == "$WORK/tree/volume" ]] && REPLY=424242
      return 0
    }
    file-compress --format tar.gz --output tree.tar.gz --dry-run -- tree
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing a recursive operation across a mount: $WORK/tree/volume"* ]]
  [ ! -e "$WORK/tree.tar.gz" ]

  # A real mount point: /dev has its own device on Linux and macOS.
  run run_zsh '_file_mountpoint_clear /dev'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing a recursive operation across a mount: /dev"* ]]
}

@test "file platform: Linux reads one mount-table snapshot per pass" {
  mock_kernel Linux
  mkdir -p "$WORK/many"
  local index
  for index in 1 2 3 4 5 6 7 8; do
    printf '%s\n' "$index" > "$WORK/many/file-$index"
  done
  printf '%s\n' '22 1 8:1 / / rw,relatime - ext4 /dev/root rw' \
    > "$TEST_TEMP_DIR/mountinfo"

  run run_zsh '
    _file_mount_table_path() {
      print -r -- read >> "$HOME/table-reads"
      REPLY="$TEST_TEMP_DIR/mountinfo"
    }
    cd "$WORK/many" || return 90
    file-find-large --min-size 1 --delete --dry-run || return 91
    print -r -- "dry-run=$(command grep -c read "$HOME/table-reads")"
    file-find-large --min-size 1 --delete --yes >/dev/null 2>&1 || return 92
    print -r -- "deleted=$(command grep -c read "$HOME/table-reads")"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: 8 files planned; nothing was deleted."* ]]
  # One snapshot for the dry-run plan, then one for the plan and one for the
  # execution pass of the real deletion: three in total, not one per file.
  [[ "$output" == *"dry-run=1"* ]]
  [[ "$output" == *"deleted=3"* ]]
  [ -z "$(ls -A "$WORK/many")" ]
}

@test "file platform: Linux refuses escaped bind mounts below a directory input" {
  mock_kernel Linux
  mkdir -p "$WORK/tree/bound dir" "$WORK/tree/plain"
  printf '%s\n' data > "$WORK/tree/plain/file"
  printf '%s\n' data > "$WORK/single"
  printf '%s\n' \
    '22 1 8:1 / / rw,relatime - ext4 /dev/root rw' \
    "45 22 8:1 /elsewhere $WORK/tree/bound\\040dir rw,relatime - ext4 /dev/root rw" \
    "46 22 8:1 /file $WORK/single rw,relatime - ext4 /dev/root rw" \
    > "$TEST_TEMP_DIR/mountinfo"

  run run_zsh '
    _file_mount_table_path() { REPLY="$TEST_TEMP_DIR/mountinfo"; }
    cd "$WORK" || return 90
    file-compress --format tar.gz --output tree.tar.gz --dry-run -- tree
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing a recursive operation across a mount: $WORK/tree/bound dir"* ]]

  run run_zsh '
    _file_mount_table_path() { REPLY="$TEST_TEMP_DIR/mountinfo"; }
    cd "$WORK" || return 90
    file-find-large --min-size 1 --delete --dry-run
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing a recursive operation across a mount: $WORK/single"* ]]
  [ -f "$WORK/single" ]

  printf '%s\n' '22 1 8:1 / / rw - ext4 /dev/root rw' '23 22 8:1 / /x\q rw - ext4 /dev/root rw' \
    > "$TEST_TEMP_DIR/mountinfo"
  run run_zsh '
    _file_mount_table_path() { REPLY="$TEST_TEMP_DIR/mountinfo"; }
    cd "$WORK" || return 90
    file-find-large --min-size 1 --delete --dry-run
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse the mount table."* ]]
}

@test "file platform: recursive operations fail closed on other kernels" {
  mock_kernel FreeBSD
  printf '%s\n' data > "$WORK/file"

  run run_zsh 'cd "$WORK" && file-find-large --min-size 1 --delete --dry-run'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Recursive mount-boundary validation is not supported on FreeBSD."* ]]
  [ -f "$WORK/file" ]
}

@test "file platform: mv takes -T -n only for GNU and uutils implementations" {
  local version_text expected
  for version_text in "mv (GNU coreutils) 9.4" "mv (uutils coreutils) 0.0.28" ""; do
    if [ -n "$version_text" ]; then
      printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$version_text" > "$TEST_MOCK_BIN/mv"
      expected="-T -n"
    else
      printf '#!/bin/sh\necho "mv: illegal option -- -" >&2\nexit 64\n' > "$TEST_MOCK_BIN/mv"
      expected="-n"
    fi
    chmod +x "$TEST_MOCK_BIN/mv"
    run run_zsh '
      local -a reply=()
      _file_mv_no_clobber_command || return 91
      [[ "${reply[1]}" == "$TEST_MOCK_BIN/mv" ]] || return 92
      print -r -- "${reply[2,-1]}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
  done
}

@test "file platform: deletion works with a BSD mv and keeps identity checks" {
  export FILE_REAL_MV
  FILE_REAL_MV=$(command -v mv)
  cat > "$TEST_MOCK_BIN/mv" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  [[ "$argument" == -- ]] && break
  case "$argument" in
    --*) printf 'mv: illegal option -- -\n' >&2; exit 64 ;;
    -*T*) printf 'mv: illegal option -- T\n' >&2; exit 64 ;;
  esac
done
exec "$FILE_REAL_MV" "$@"
SH
  chmod +x "$TEST_MOCK_BIN/mv"
  printf '%s\n' first > "$WORK/one"
  printf '%s\n' second > "$WORK/two"

  run run_zsh 'cd "$WORK" && file-find-large --min-size 1 --delete --yes'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Deletion completed: 2 files deleted."* ]]
  [ ! -e "$WORK/one" ]
  [ ! -e "$WORK/two" ]
  [ -z "$(find "$WORK" -name '.zdx-file-delete.*' -print)" ]
}

@test "file platform: extraction resolves GNU tar as gtar when tar is bsdtar" {
  local gnu_tar
  gnu_tar=$(file_gnu_tar_path) || skip "requires GNU tar, installed as tar or gtar"
  export FILE_REAL_MV FILE_TAR_CALLS="$TEST_TEMP_DIR/tar-calls"
  FILE_REAL_MV=$(command -v mv)
  printf '%s\n' first > "$WORK/one"
  printf '%s\n' second > "$WORK/two"
  (cd "$WORK" && "$gnu_tar" -czf bundle.TAR.GZ -- one two)
  rm -f "$WORK/one" "$WORK/two"
  # tar identifies as bsdtar and records every other use; gtar is GNU tar.
  cat > "$TEST_MOCK_BIN/tar" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'bsdtar 3.5.3 - libarchive 3.7.4\n'
  exit 0
fi
printf '%s\n' "$*" >> "$FILE_TAR_CALLS"
exit 2
SH
  chmod +x "$TEST_MOCK_BIN/tar"
  ln -s "$gnu_tar" "$TEST_MOCK_BIN/gtar"
  # BSD mv publishes the extraction without -T.
  cat > "$TEST_MOCK_BIN/mv" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  [[ "$argument" == -- ]] && break
  case "$argument" in
    --*|-*T*) printf 'mv: illegal option\n' >&2; exit 64 ;;
  esac
done
exec "$FILE_REAL_MV" "$@"
SH
  chmod +x "$TEST_MOCK_BIN/mv"

  run run_zsh '
    cd "$WORK" || return 90
    file-extract --destination restored --yes -- bundle.TAR.GZ || return 91
    [[ "$(<restored/one)" == first && "$(<restored/two)" == second ]] || return 92
    file-compress --format tar.gz --output again.tar.gz --yes -- restored
  '

  [ "$status" -eq 0 ]
  [ -f "$WORK/again.tar.gz" ]
  [ ! -e "$FILE_TAR_CALLS" ]
  run "$gnu_tar" -tzf "$WORK/again.tar.gz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restored/one"* ]]
}

@test "file platform: bsdtar archives omit macOS metadata and GNU tar is preferred" {
  mock_bsd_tar "$TEST_TEMP_DIR/tar-log"
  # Shadow any host gtar with one that is not GNU tar.
  printf '#!/bin/sh\nexit 1\n' > "$TEST_MOCK_BIN/gtar"
  chmod +x "$TEST_MOCK_BIN/gtar"
  printf '%s\n' data > "$WORK/one"

  run run_zsh 'cd "$WORK" && file-compress --format tar.gz --output one.tar.gz --yes -- one'

  [ "$status" -eq 0 ]
  [ -f "$WORK/one.tar.gz" ]
  grep -q '^COPYFILE_DISABLE=1 --no-mac-metadata --no-xattrs -czf .* -- ./one$' \
    "$TEST_TEMP_DIR/tar-log"

  # With GNU tar available as gtar, it creates the archive without them.
  rm -f "$WORK/one.tar.gz" "$TEST_TEMP_DIR/tar-log"
  cat > "$TEST_MOCK_BIN/gtar" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'tar (GNU tar) 1.35\n'
  exit 0
fi
printf 'gtar %s\n' "$*" >> "$FILE_TAR_LOG"
previous=""
for argument in "$@"; do
  [[ "$previous" == -c*f ]] && printf 'archive\n' > "$argument"
  previous="$argument"
done
SH
  chmod +x "$TEST_MOCK_BIN/gtar"

  run run_zsh 'cd "$WORK" && file-compress --format tar.xz --output one.tar.xz --yes -- one'

  [ "$status" -eq 0 ]
  [ -f "$WORK/one.tar.xz" ]
  grep -q '^gtar -cJf .*/one[.]tar[.]xz -- [.]/one$' "$TEST_TEMP_DIR/tar-log"
  [ "$(grep -c . "$TEST_TEMP_DIR/tar-log")" -eq 1 ]
}

@test "file platform: 7z archives use 7zz when 7z is absent" {
  export FILE_7Z_LOG="$TEST_TEMP_DIR/7z-log"
  cat > "$TEST_MOCK_BIN/7zz" <<'SH'
#!/usr/bin/env bash
printf '7zz %s\n' "$*" >> "$FILE_7Z_LOG"
[[ "$1" == a && "$2" == -- ]] || exit 7
printf 'archive\n' > "$3"
SH
  chmod +x "$TEST_MOCK_BIN/7zz"
  printf '%s\n' data > "$WORK/one"

  run run_zsh '
    whence() {
      if [[ "$1" == -p && ( "$2" == 7z || "$2" == 7za ) ]]; then
        return 1
      fi
      builtin whence "$@"
    }
    cd "$WORK" && file-compress --format 7z --output one.7z --yes -- one
  '

  [ "$status" -eq 0 ]
  [ -f "$WORK/one.7z" ]
  grep -q '^7zz a -- .*/one.7z ./one$' "$FILE_7Z_LOG"
}

@test "file platform: content digests hash stdin, so names with a backslash work" {
  printf '%s\n' data > "$WORK/back\\slash.bin"
  mkfifo "$WORK/pipe"

  run run_zsh '
    _file_sha256_digest "$WORK/back\\slash.bin" || return 91
    print -r -- "$REPLY"
    _file_sha256_digest "$WORK/pipe" && return 92
    return 0
  '

  [ "$status" -eq 0 ]
  [ "$output" = "$(sha256_file "$WORK/back\\slash.bin")" ]

  printf '%s\n' old > "$WORK/out\\name.tar.gz"
  run run_zsh '
    cd "$WORK" || return 90
    file-compress --format tar.gz --output "out\\name.tar.gz" --overwrite --yes -- "back\\slash.bin"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/out\\name.tar.gz")" != old ]
}

@test "file platform: macOS refuses archive names that differ only by letter case" {
  file_gnu_tar_path >/dev/null || skip "requires GNU tar, installed as tar or gtar"
  python3 - "$WORK" <<'PY'
import io
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
for archive_name, members in (
    ("mixed.tar", ("pkg/README", "pkg/readme")),
    ("parents.tar", ("Docs/", "docs/guide.txt")),
    ("UPPER.TAR.GZ", ("pkg/README", "pkg/notes")),
):
    mode = "w:gz" if archive_name.endswith(".GZ") else "w"
    with tarfile.open(root / archive_name, mode, format=tarfile.GNU_FORMAT) as archive:
        for name in members:
            info = tarfile.TarInfo(name.rstrip("/"))
            if name.endswith("/"):
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                archive.addfile(info)
            else:
                data = name.encode()
                info.size = len(data)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))
PY

  mock_kernel Darwin
  run run_zsh 'cd "$WORK" && file-extract --destination out --dry-run -- mixed.tar'
  [ "$status" -eq 1 ]
  [[ "$output" == *"differ only by letter case"*"pkg/readme"* ]]
  run run_zsh 'cd "$WORK" && file-extract --destination out --dry-run -- parents.tar'
  [ "$status" -eq 1 ]
  [[ "$output" == *"differ only by letter case"*"docs"* ]]
  run run_zsh 'cd "$WORK" && file-extract --destination out --dry-run -- UPPER.TAR.GZ'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run complete; no files were extracted."* ]]

  mock_kernel Linux
  run run_zsh 'cd "$WORK" && file-extract --destination out --dry-run -- mixed.tar'
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/out" ]
}

@test "file platform: WSL drive refusals explain DrvFs metadata" {
  run run_zsh '
    _file_host_is_wsl() { return 0; }
    _file_wsl_drive_hint /mnt/c/Users/me/project
    _file_wsl_drive_hint /mnt/d
    _file_wsl_drive_hint /home/me/project
    _file_wsl_drive_hint /mnt/wsl/shared
    _file_host_is_wsl() { return 1; }
    _file_wsl_drive_hint /mnt/c/Users/me/project
  '

  [ "$status" -eq 0 ]
  [ "$(grep -c 'DrvFs metadata' <<< "$output")" -eq 2 ]
  [[ "$output" == *'[automount] options="metadata,umask=22,fmask=11"'*'/etc/wsl.conf'* ]]
}

@test "file platform: WSL is detected from interop, late interop, or the kernel release" {
  mock_kernel Linux
  run run_zsh '
    unset WSL_DISTRO_NAME WSL_INTEROP
    local case_name fixture release
    for case_name in interop late kernel native; do
      fixture="$HOME/proc-$case_name"
      command mkdir -p "$fixture/sys/fs/binfmt_misc" "$fixture/sys/kernel"
      release="6.8.0-generic"
      case "$case_name" in
        interop) : > "$fixture/sys/fs/binfmt_misc/WSLInterop" ;;
        late) : > "$fixture/sys/fs/binfmt_misc/WSLInterop-late" ;;
        kernel) release="5.15.167.4-microsoft-standard-WSL2" ;;
      esac
      print -r -- "$release" > "$fixture/sys/kernel/osrelease"
      if _file_host_is_wsl "$fixture"; then
        print -r -- "$case_name=WSL"
      else
        print -r -- "$case_name=Linux"
      fi
    done
    WSL_DISTRO_NAME=Ubuntu _file_host_is_wsl "$HOME/proc-native" \
      && print -r -- "variable=WSL"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'interop=WSL\nlate=WSL\nkernel=WSL\nnative=Linux\nvariable=WSL' ]

  mock_kernel Darwin
  run run_zsh 'WSL_DISTRO_NAME=Ubuntu _file_host_is_wsl'
  [ "$status" -eq 1 ]
}

@test "file platform: junk discovery without GNU find matches the documented scan" {
  mock_bsd_find
  # The lowercase thumbs.db lives in its own directory so that a
  # case-insensitive volume keeps it distinct from the Thumbs.db link below.
  mkdir -p "$WORK/case" "$WORK/src/deep" "$WORK/desktop.ini" "$WORK/.git/objects" \
    "$WORK/node_modules/pkg" "$WORK/lib/site-packages/p" "$WORK/repo/.git" \
    "$WORK/a/b/c/d/e/f/g/h/i/j/k/l"
  local junk
  for junk in .DS_Store src/Thumbs.db 'src/report.pdf:Zone.Identifier' \
    src/deep/._notes repo/desktop.ini a/b/c/d/e/f/g/h/i/j/k/.DS_Store; do
    printf '%s\n' junk > "$WORK/$junk"
  done
  for junk in case/thumbs.db notes.DS_Store.txt .git/.DS_Store \
    node_modules/pkg/.DS_Store lib/site-packages/p/._x repo/.git/Thumbs.db \
    a/b/c/d/e/f/g/h/i/j/k/l/.DS_Store; do
    printf '%s\n' keep > "$WORK/$junk"
  done
  ln -s src/Thumbs.db "$WORK/Thumbs.db"
  ln -s src "$WORK/linked"
  if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "$WORK/locked"
    chmod 000 "$WORK/locked"
  fi

  run run_zsh '
    cd "$WORK" || return 90
    _file_find_has_gnu_predicates && return 91
    file-clean-junk --dry-run
  '
  [ -d "$WORK/locked" ] && chmod 700 "$WORK/locked"

  [ "$status" -eq 0 ]
  [[ "$output" == *"1  .DS_Store"* ]]
  [[ "$output" == *"2  a/b/c/d/e/f/g/h/i/j/k/.DS_Store"* ]]
  [[ "$output" == *"3  repo/desktop.ini"* ]]
  [[ "$output" == *"4  src/Thumbs.db"* ]]
  [[ "$output" == *"5  src/deep/._notes"* ]]
  [[ "$output" == *"6  src/report.pdf:Zone.Identifier"* ]]
  [[ "$output" == *"Dry run: 6 files planned; nothing was deleted."* ]]
  if [ "$(id -u)" -ne 0 ]; then
    [[ "$output" == *"Skipped a directory that cannot be read: locked"* ]]
  fi
  [[ "$output" != *"linked"* && "$output" != *"thumbs.db"* ]]
}

@test "file platform: the menu marks extraction unavailable without GNU tar" {
  mock_bsd_tar "$TEST_TEMP_DIR/tar-log"
  printf '#!/bin/sh\nexit 1\n' > "$TEST_MOCK_BIN/gtar"
  chmod +x "$TEST_MOCK_BIN/gtar"

  run run_zsh 'file-menu --help >/dev/null 2>&1; _file_menu_rows'

  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n  ○ Extract TAR Archive (missing: GNU tar)|file-extract|'* ]]
  [[ "$output" == *$'\n  Compress Files|file-compress|'* ]]
  [[ "$output" == *$'\n  Remove Junk Files|file-clean-junk|'* ]]

  cat > "$TEST_MOCK_BIN/gtar" <<'SH'
#!/bin/sh
printf 'tar (GNU tar) 1.35\n'
SH
  run run_zsh 'file-menu --help >/dev/null 2>&1; _file_menu_rows'

  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n  Extract TAR Archive|file-extract|'* ]]
  [[ "$output" != *"missing:"* ]]
}
