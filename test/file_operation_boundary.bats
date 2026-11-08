#!/usr/bin/env bats

setup() {
  load test_helper
  export FILE_BOUNDARY_ROOT="$HOME/fixture"
  export FILE_BOUNDARY_WORK="$FILE_BOUNDARY_ROOT/work"
  export FILE_BOUNDARY_BIN="$FILE_BOUNDARY_ROOT/bin"
  export FILE_BOUNDARY_SETUP="$FILE_BOUNDARY_ROOT/setup.zsh"
  export FILE_BOUNDARY_REAL_MV FILE_BOUNDARY_REAL_RM FILE_BOUNDARY_REAL_CHMOD
  export FILE_BOUNDARY_REAL_MKTEMP FILE_BOUNDARY_REAL_FIND
  FILE_BOUNDARY_REAL_MV=$(type -P mv)
  FILE_BOUNDARY_REAL_RM=$(type -P rm)
  FILE_BOUNDARY_REAL_CHMOD=$(type -P chmod)
  FILE_BOUNDARY_REAL_MKTEMP=$(type -P mktemp)
  FILE_BOUNDARY_REAL_FIND=$(type -P find)
  mkdir -p "$FILE_BOUNDARY_WORK" "$FILE_BOUNDARY_BIN" "$FILE_BOUNDARY_ROOT/tmp" \
    "$FILE_BOUNDARY_ROOT/state" "$FILE_BOUNDARY_ROOT/outside/sub" "$FILE_BOUNDARY_ROOT/outside/dir"
  export TMPDIR="$FILE_BOUNDARY_ROOT/tmp" XDG_DATA_HOME="$FILE_BOUNDARY_ROOT/state"
  chmod -- 700 "$FILE_BOUNDARY_ROOT" "$FILE_BOUNDARY_WORK" "$TMPDIR" "$XDG_DATA_HOME"
  printf 'unrelated canary\n' > "$FILE_BOUNDARY_ROOT/outside/canary"
  local tool
  for tool in mv rm chmod; do
    printf '#!%s -f\n' "$(type -P zsh)" > "$FILE_BOUNDARY_BIN/$tool"
    cat >> "$FILE_BOUNDARY_BIN/$tool" <<'MOCK'
emulate -R zsh
[[ "$FILE_BOUNDARY_ROOT" == "$HOME/fixture" && -d "$FILE_BOUNDARY_ROOT" \
  && ! -L "$FILE_BOUNDARY_ROOT" ]] || exit 97
local tool="${0:t}" argument="" checked=0
if [[ "$tool" == mv && "$*" == --version ]]; then
  exec "$FILE_BOUNDARY_REAL_MV" --version
fi
for argument in "$@"; do
  case "$argument" in
    --|-T|-n|-f|-r|-rf|-fr) continue ;;
  esac
  [[ "$tool" == chmod && "$argument" == [0-7][0-7][0-7] ]] && continue
  [[ "$argument" == "$FILE_BOUNDARY_ROOT"/* \
    && "${argument:A}" == "$FILE_BOUNDARY_ROOT"/* ]] || exit 97
  (( ++checked ))
done
(( checked > 0 )) || exit 97
print -r -- "$tool:${(j: :)@}" >> "$FILE_BOUNDARY_ROOT/mutations"
case "$tool" in
  mv) exec "$FILE_BOUNDARY_REAL_MV" "$@" ;;
  rm) exec "$FILE_BOUNDARY_REAL_RM" "$@" ;;
  chmod) exec "$FILE_BOUNDARY_REAL_CHMOD" "$@" ;;
esac
MOCK
    chmod -- 700 "$FILE_BOUNDARY_BIN/$tool"
  done
  printf '#!%s -f\n' "$(type -P zsh)" > "$FILE_BOUNDARY_BIN/mktemp"
  cat >> "$FILE_BOUNDARY_BIN/mktemp" <<'MOCK'
emulate -R zsh
local template="${@[-1]}"
[[ "$FILE_BOUNDARY_ROOT" == "$HOME/fixture" && -d "$FILE_BOUNDARY_ROOT" \
  && ! -L "$FILE_BOUNDARY_ROOT" ]] || exit 97
[[ $# == 1 || ( $# == 2 && "$1" == -d ) ]] || exit 97
[[ "/$template/" != */../* && "${template:h}" == "$FILE_BOUNDARY_ROOT"/* \
  && "${template:h}" == "${template:h:A}" && -d "${template:h}" \
  && ! -L "${template:h}" && -O "${template:h}" ]] || exit 97
if [[ "${template:t}" == zdx-file-scan.XXXXXX \
  && -n "${FILE_BOUNDARY_TEMP_RESULT:-}" ]]; then
  print -r -- "$FILE_BOUNDARY_TEMP_RESULT"
  exit 0
fi
exec "$FILE_BOUNDARY_REAL_MKTEMP" "$@"
MOCK
  chmod -- 700 "$FILE_BOUNDARY_BIN/mktemp"
  cat > "$FILE_BOUNDARY_SETUP" <<'ZSH'
emulate -R zsh
source "$TEST_SUITE_ROOT/functions/file-menu.zsh" || return $?
export PATH="$FILE_BOUNDARY_BIN:$PATH"
cd -q -- "$FILE_BOUNDARY_WORK" || return 1
ZSH
}

teardown() {
  cleanup_sandbox
}

make_stale_directory() {
  cat > "$FILE_BOUNDARY_ROOT/stale.zsh" <<'ZSH'
emulate -R zsh
source "$FILE_BOUNDARY_SETUP" || return $?
printf '%4096s' x > large
print -r -- old > .DS_Store
print -r -- original > item
command mv -- "$FILE_BOUNDARY_WORK" "$FILE_BOUNDARY_ROOT/previous" || return $?
command mkdir -- "$FILE_BOUNDARY_WORK" || return $?
print -r -- small > "$FILE_BOUNDARY_WORK/large"
print -r -- replacement > "$FILE_BOUNDARY_WORK/.DS_Store"
print -r -- replacement > "$FILE_BOUNDARY_WORK/item"
ZSH
}

@test "file boundary: stale PWD cannot publish large-file results for another directory" {
  make_stale_directory
  run -1 run_zsh 'source "$FILE_BOUNDARY_ROOT/stale.zsh"; file-find-large --min-size 1000 > "$FILE_BOUNDARY_ROOT/results"'
  [ ! -s "$FILE_BOUNDARY_ROOT/results" ]
}

@test "file boundary: stale PWD cannot delete a replacement below the requested size" {
  make_stale_directory
  run -1 run_zsh 'source "$FILE_BOUNDARY_ROOT/stale.zsh"; file-find-large --min-size 1000 --delete --yes'
  [ "$(cat "$FILE_BOUNDARY_WORK/large")" = small ]
  [ "$(file_size "$FILE_BOUNDARY_ROOT/previous/large")" -eq 4096 ]
}

@test "file boundary: stale PWD cannot select replacement junk for deletion" {
  make_stale_directory
  run -1 run_zsh 'source "$FILE_BOUNDARY_ROOT/stale.zsh"; file-clean-junk --yes'
  [ "$(cat "$FILE_BOUNDARY_WORK/.DS_Store")" = replacement ]
  [ -f "$FILE_BOUNDARY_ROOT/previous/.DS_Store" ]
}

@test "file boundary: stale PWD cannot move a relative replacement to trash" {
  make_stale_directory
  run -1 run_zsh 'source "$FILE_BOUNDARY_ROOT/stale.zsh"; file-trash put --yes item'
  [ "$(cat "$FILE_BOUNDARY_WORK/item")" = replacement ]
  [ -f "$FILE_BOUNDARY_ROOT/previous/item" ]
}

prepare_dotdot_operand() {
  mkdir -p "$FILE_BOUNDARY_WORK/sub"
  printf 'inside\n' > "$FILE_BOUNDARY_WORK/sub/item"
  printf 'outside\n' > "$FILE_BOUNDARY_ROOT/outside/sub/item"
  ln -s "$FILE_BOUNDARY_ROOT/outside/dir" "$FILE_BOUNDARY_WORK/link"
}

@test "file boundary: trash refuses raw dot-dot crossing a symbolic link" {
  prepare_dotdot_operand
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-trash put --dry-run -- link/../sub/item'
  [ "$(cat "$FILE_BOUNDARY_WORK/sub/item")" = inside ]
  [ "$(cat "$FILE_BOUNDARY_ROOT/outside/sub/item")" = outside ]
}

@test "file boundary: archive inputs refuse raw dot-dot crossing a symbolic link" {
  prepare_dotdot_operand
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-compress --format tar.gz --output safe.tar.gz --dry-run -- link/../sub/item'
  [ ! -e "$FILE_BOUNDARY_WORK/safe.tar.gz" ]
  [ "$(cat "$FILE_BOUNDARY_WORK/sub/item")" = inside ]
}

@test "file boundary: extraction destination validation refuses a hidden link before normalization" {
  prepare_dotdot_operand
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; _file_validate_destination_parent link/../output "$FILE_BOUNDARY_WORK"'
  [ ! -e "$FILE_BOUNDARY_WORK/output" ]
}

@test "file boundary: deletion rechecks higher ancestor trust after confirmation" {
  mkdir -p "$FILE_BOUNDARY_WORK/deep/leaf"
  printf 'junk\n' > "$FILE_BOUNDARY_WORK/deep/leaf/.DS_Store"
  run -1 run_zsh '
    source "$FILE_BOUNDARY_SETUP" || return $?
    _file_confirm_mutation() { command chmod -- 777 "$FILE_BOUNDARY_WORK/deep"; }
    file-clean-junk --yes
  '
  [ -f "$FILE_BOUNDARY_WORK/deep/leaf/.DS_Store" ]
}

@test "file boundary: trash put rechecks higher ancestor trust after confirmation" {
  mkdir -p "$FILE_BOUNDARY_WORK/deep/leaf"
  printf 'preserved\n' > "$FILE_BOUNDARY_WORK/deep/leaf/item"
  run -1 run_zsh '
    source "$FILE_BOUNDARY_SETUP" || return $?
    _file_confirm_mutation() { command chmod -- 777 "$FILE_BOUNDARY_WORK/deep"; }
    file-trash put --yes deep/leaf/item
  '
  [ -f "$FILE_BOUNDARY_WORK/deep/leaf/item" ]
}

@test "file boundary: trash restore rechecks higher destination ancestors after confirmation" {
  mkdir -p "$FILE_BOUNDARY_WORK/deep/leaf"
  printf 'preserved\n' > "$FILE_BOUNDARY_WORK/deep/leaf/item"
  run -1 run_zsh '
    source "$FILE_BOUNDARY_SETUP" || return $?
    file-trash put --yes deep/leaf/item || return $?
    local -a infos=("$XDG_DATA_HOME/zdx/trash/info/"*.trashinfo(N))
    (( ${#infos} == 1 )) || return 98
    local id="${infos[1]:t:r}"
    _file_confirm_mutation() { command chmod -- 777 "$FILE_BOUNDARY_WORK/deep"; }
    file-trash restore --yes "$id"
  '
  [ ! -e "$FILE_BOUNDARY_WORK/deep/leaf/item" ]
  [ -n "$(find "$XDG_DATA_HOME/zdx/trash/files" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "file boundary: an unexpected scan path is never chmodded written or removed" {
  export FILE_BOUNDARY_TEMP_RESULT="$FILE_BOUNDARY_ROOT/victim"
  printf 'preserved\n' > "$FILE_BOUNDARY_TEMP_RESULT"
  chmod -- 644 "$FILE_BOUNDARY_TEMP_RESULT"
  printf 'candidate\n' > "$FILE_BOUNDARY_WORK/item"
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-find-large --min-size 1'
  [ "$(cat "$FILE_BOUNDARY_TEMP_RESULT")" = preserved ]
  [ "$(file_mode "$FILE_BOUNDARY_TEMP_RESULT")" = 644 ]
}

@test "file boundary: a nonempty scan-name file is refused without changing its data" {
  export FILE_BOUNDARY_TEMP_RESULT="$TMPDIR/zdx-file-scan.ABCDEF"
  printf 'preserved\n' > "$FILE_BOUNDARY_TEMP_RESULT"
  chmod -- 600 "$FILE_BOUNDARY_TEMP_RESULT"
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; _file_collect_paths files .'
  [ "$(cat "$FILE_BOUNDARY_TEMP_RESULT")" = preserved ]
}

@test "file boundary: a symlink scan result and its target stay unchanged" {
  printf 'preserved\n' > "$FILE_BOUNDARY_ROOT/victim"
  chmod -- 644 "$FILE_BOUNDARY_ROOT/victim"
  export FILE_BOUNDARY_TEMP_RESULT="$TMPDIR/zdx-file-scan.ABCDEF"
  ln -s "$FILE_BOUNDARY_ROOT/victim" "$FILE_BOUNDARY_TEMP_RESULT"
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; _file_collect_paths files .'
  [ -L "$FILE_BOUNDARY_TEMP_RESULT" ]
  [ "$(file_mode "$FILE_BOUNDARY_ROOT/victim")" = 644 ]
  [ "$(cat "$FILE_BOUNDARY_ROOT/victim")" = preserved ]
}

@test "file boundary: a hard-linked scan result is refused before writing or unlinking" {
  printf 'preserved\n' > "$FILE_BOUNDARY_ROOT/victim"
  chmod -- 600 "$FILE_BOUNDARY_ROOT/victim"
  export FILE_BOUNDARY_TEMP_RESULT="$TMPDIR/zdx-file-scan.ABCDEF"
  ln "$FILE_BOUNDARY_ROOT/victim" "$FILE_BOUNDARY_TEMP_RESULT"
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; _file_collect_paths files .'
  [ -f "$FILE_BOUNDARY_TEMP_RESULT" ]
  [ "$(file_links "$FILE_BOUNDARY_ROOT/victim")" -eq 2 ]
  [ "$(cat "$FILE_BOUNDARY_ROOT/victim")" = preserved ]
}

@test "file boundary: an unterminated inventory record cannot publish a partial list" {
  printf '#!%s -f\n' "$(type -P zsh)" > "$FILE_BOUNDARY_BIN/find"
  cat >> "$FILE_BOUNDARY_BIN/find" <<'MOCK'
emulate -R zsh
[[ "$PWD" == "$FILE_BOUNDARY_WORK" ]] || exit 97
print -rn -- "$FILE_BOUNDARY_WORK/item"$'\0'"$FILE_BOUNDARY_WORK/incomplete"
MOCK
  chmod -- 700 "$FILE_BOUNDARY_BIN/find"
  printf 'candidate\n' > "$FILE_BOUNDARY_WORK/item"
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-find-large --min-size 1 > "$FILE_BOUNDARY_ROOT/results"'
  [ ! -s "$FILE_BOUNDARY_ROOT/results" ]
}

@test "file boundary: the opened scan descriptor must match the reviewed empty file" {
  printf 'preserved\n' > "$FILE_BOUNDARY_ROOT/victim"
  chmod -- 600 "$FILE_BOUNDARY_ROOT/victim"
  printf 'candidate\n' > "$FILE_BOUNDARY_WORK/item"
  run -1 run_zsh '
    source "$FILE_BOUNDARY_SETUP" || return $?
    sysopen() {
      local scan_file="${@[-1]}"
      if [[ "$*" == *-w* && "${scan_file:t}" == zdx-file-scan.* ]]; then
        command mv -- "$scan_file" "$FILE_BOUNDARY_ROOT/original-scan" || return $?
        command ln -- "$FILE_BOUNDARY_ROOT/victim" "$scan_file" || return $?
      fi
      builtin sysopen "$@"
    }
    _file_collect_paths files .
  '
  [ "$(cat "$FILE_BOUNDARY_ROOT/victim")" = preserved ]
}

@test "file boundary: a large file that shrinks before planning is never deleted" {
  run -1 run_zsh '
    source "$FILE_BOUNDARY_SETUP" || return $?
    printf "%4096s" x > item
    functions[_file_boundary_original_large]="${functions[_file_large_inventory]}"
    _file_large_inventory() {
      _file_boundary_original_large "$@" || return $?
      print -r -- small > "$FILE_BOUNDARY_WORK/item"
      return 0
    }
    file-find-large --min-size 1000 --delete --yes
  '
  [ "$(cat "$FILE_BOUNDARY_WORK/item")" = small ]
}

@test "file boundary: a junk producer cannot nominate an ordinary file" {
  printf 'ordinary\n' > "$FILE_BOUNDARY_WORK/item"
  printf '#!%s -f\n' "$(type -P zsh)" > "$FILE_BOUNDARY_BIN/find"
  cat >> "$FILE_BOUNDARY_BIN/find" <<'MOCK'
emulate -R zsh
[[ "$PWD" == "$FILE_BOUNDARY_WORK" ]] || exit 97
[[ "$*" != *-maxdepth\ 0* ]] || exit 0
local root="$1"
[[ "$root" == . || "$root" == "$FILE_BOUNDARY_WORK" ]] || exit 97
print -rn -- "${root%/}/item"$'\0'
MOCK
  chmod -- 700 "$FILE_BOUNDARY_BIN/find"
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-clean-junk --yes'
  [ "$(cat "$FILE_BOUNDARY_WORK/item")" = ordinary ]
}

@test "file boundary: a directory replaced during collection publishes no paths" {
  printf 'original\n' > "$FILE_BOUNDARY_WORK/item"
  printf '#!%s -f\n' "$(type -P zsh)" > "$FILE_BOUNDARY_BIN/find"
  cat >> "$FILE_BOUNDARY_BIN/find" <<'MOCK'
emulate -R zsh
[[ "$PWD" == "$FILE_BOUNDARY_WORK" ]] || exit 97
"$FILE_BOUNDARY_REAL_MV" -- "$FILE_BOUNDARY_WORK" "$FILE_BOUNDARY_ROOT/previous" || exit $?
command mkdir -- "$FILE_BOUNDARY_WORK" || exit $?
print -r -- replacement > "$FILE_BOUNDARY_WORK/item"
print -rn -- "$FILE_BOUNDARY_WORK/item"$'\0'
MOCK
  chmod -- 700 "$FILE_BOUNDARY_BIN/find"
  run -1 run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-find-large --min-size 1 > "$FILE_BOUNDARY_ROOT/results"'
  [ ! -s "$FILE_BOUNDARY_ROOT/results" ]
  [ "$(cat "$FILE_BOUNDARY_WORK/item")" = replacement ]
  [ "$(cat "$FILE_BOUNDARY_ROOT/previous/item")" = original ]
}

@test "file boundary: read-only inspection retains access to an unprotected current directory" {
  printf 'candidate\n' > "$FILE_BOUNDARY_WORK/item"
  chmod -- 777 "$FILE_BOUNDARY_WORK"
  run -0 run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-find-large --min-size 1 > "$FILE_BOUNDARY_ROOT/results"'
  [ "$(cat "$FILE_BOUNDARY_ROOT/results")" = item ]
  [ -f "$FILE_BOUNDARY_WORK/item" ]
}

@test "file boundary: ordinary inspection keeps relative literal path rows" {
  printf 'candidate\n' > "$FILE_BOUNDARY_WORK/-leading:literal"
  run -0 run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-find-large --min-size 1 > "$FILE_BOUNDARY_ROOT/results"'
  [ "$(cat "$FILE_BOUNDARY_ROOT/results")" = '-leading:literal' ]
}

@test "file boundary: a validated archive operand with dot components remains accepted" {
  mkdir -p "$FILE_BOUNDARY_WORK/sub"
  printf 'candidate\n' > "$FILE_BOUNDARY_WORK/sub/item"
  run -0 run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-compress --format tar.gz --output safe.tar.gz --dry-run -- ./sub/./item'
  [[ "$output" == *'Dry run complete'* ]]
  [ ! -e "$FILE_BOUNDARY_WORK/safe.tar.gz" ]
}

@test "file boundary: a failed external producer cannot publish a partial list or delete data" {
  printf 'candidate\n' > "$FILE_BOUNDARY_WORK/item"
  printf '#!%s -f\n' "$(type -P zsh)" > "$FILE_BOUNDARY_BIN/find"
  cat >> "$FILE_BOUNDARY_BIN/find" <<'MOCK'
emulate -R zsh
[[ "$PWD" == "$FILE_BOUNDARY_WORK" ]] || exit 97
print -rn -- "$FILE_BOUNDARY_WORK/item"$'\0'
exit 42
MOCK
  chmod -- 700 "$FILE_BOUNDARY_BIN/find"
  run run_zsh 'source "$FILE_BOUNDARY_SETUP"; file-find-large --min-size 1 --delete --yes > "$FILE_BOUNDARY_ROOT/results"'
  [ "$status" -ne 0 ]
  [ ! -s "$FILE_BOUNDARY_ROOT/results" ]
  [ -f "$FILE_BOUNDARY_WORK/item" ]
}

@test "file boundary: archive execution rechecks its scope after an execution callback" {
  mkdir -p "$FILE_BOUNDARY_ROOT/foreign"
  printf 'reviewed\n' > "$FILE_BOUNDARY_WORK/item"
  printf 'foreign\n' > "$FILE_BOUNDARY_ROOT/foreign/item"
  printf '#!%s -f\n' "$(type -P zsh)" > "$FILE_BOUNDARY_BIN/tar"
  cat >> "$FILE_BOUNDARY_BIN/tar" <<'MOCK'
emulate -R zsh
if (( $# == 1 )) && [[ "$1" == --version ]]; then
  print -r -- 'tar (GNU tar) 1.35'
  exit 0
fi
(( $# == 4 )) && [[ "$1" == -czf && "$3" == -- && "$4" == ./item ]] || exit 97
local destination="$2" parent="${2:h}"
[[ "${parent:h}" == "$FILE_BOUNDARY_WORK" \
  && "${parent:t}" == .zdx-file-archive.?????? \
  && "$parent" == "${parent:A}" && -d "$parent" && ! -L "$parent" \
  && "$destination" == "$parent/safe.tar.gz" \
  && ! -e "$destination" && ! -L "$destination" \
  && ( "$PWD" == "$FILE_BOUNDARY_WORK" || "$PWD" == "$FILE_BOUNDARY_ROOT/foreign" ) ]] || exit 97
zmodload -F zsh/stat b:zstat || exit 97
local -A state=()
zstat -LH state -- "$parent" || exit 97
(( state[uid] == EUID && (state[mode] & 8#77) == 0 )) || exit 97
print -r -- "$PWD" > "$FILE_BOUNDARY_ROOT/archive-called"
(umask 077; print -r -- "$(<./item)" > "$destination")
MOCK
  chmod -- 700 "$FILE_BOUNDARY_BIN/tar"
  run -1 run_zsh '
    source "$FILE_BOUNDARY_SETUP" || return $?
    functions[_file_boundary_archive_runner]="${functions[_file_run_archive_tool]}"
    _file_run_archive_tool() {
      [[ "${(j: :)@}" != *-czf* ]] || builtin cd -- "$FILE_BOUNDARY_ROOT/foreign" || return $?
      _file_boundary_archive_runner "$@"
    }
    file-compress --format tar.gz --output safe.tar.gz --yes -- item
  '
  [ ! -e "$FILE_BOUNDARY_ROOT/archive-called" ]
  [ ! -e "$FILE_BOUNDARY_WORK/safe.tar.gz" ]
  [ "$(cat "$FILE_BOUNDARY_WORK/item")" = reviewed ]
  [ "$(cat "$FILE_BOUNDARY_ROOT/foreign/item")" = foreign ]
}

@test "file boundary fixture: mktemp refuses a raw escape from its private root" {
  mkdir -p "$HOME/unrelated"
  run "$FILE_BOUNDARY_BIN/mktemp" "$FILE_BOUNDARY_ROOT/../unrelated/escape.XXXXXX"
  [ "$status" -eq 97 ]
  [ -z "$(find "$HOME/unrelated" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "file boundary fixture: mktemp refuses unsupported backend options" {
  run "$FILE_BOUNDARY_BIN/mktemp" -u "$FILE_BOUNDARY_ROOT/tmp/uncreated.XXXXXX"
  [ "$status" -eq 97 ]
  [ -z "$(find "$FILE_BOUNDARY_ROOT/tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]
}
