#!/usr/bin/env bats

setup() {
  TX_ORIGINAL_PATH="$PATH"
  load test_helper
  export TX_ROOT="$HOME/trash-tx" TX_WORK="$HOME/trash-tx/work"
  export TX_BIN="$HOME/trash-tx/bin" XDG_DATA_HOME="$HOME/trash-tx/state"
  export TX_TRASH="$XDG_DATA_HOME/zdx/trash" TMPDIR="$HOME/trash-tx/tmp"
  export TX_REAL_MV TX_REAL_RM TX_REAL_LN TX_ZSH
  TX_REAL_MV=$(type -P mv)
  TX_REAL_RM=$(type -P rm)
  TX_REAL_LN=$(type -P ln)
  TX_ZSH=$(type -P zsh)
  mkdir -p "$TX_WORK" "$TX_BIN" "$TMPDIR" "$TX_ROOT/victim"
  chmod -- 700 "$TX_ROOT" "$TX_WORK" "$TX_BIN" "$TMPDIR" "$TX_ROOT/victim"
  printf 'unrelated\n' > "$TX_ROOT/victim/canary"
  cat > "$TX_ROOT/second-purge.zsh" <<'SECOND_PURGE'
emulate -R zsh
source "$TEST_SUITE_ROOT/functions.zsh" || exit 91
file-trash purge --all --yes
SECOND_PURGE
  local tool
  for tool in mv rm ln; do
    printf '#!%s -f\n' "$TX_ZSH" > "$TX_BIN/$tool"
    cat >> "$TX_BIN/$tool" <<'MOCK'
emulate -R zsh
[[ "$TX_ROOT" == "$HOME/trash-tx" && -d "$TX_ROOT" && ! -L "$TX_ROOT" ]] || exit 97
local tool="${0:t}" argument=""
if [[ "$tool" == mv && $# == 1 && "$1" == --version ]]; then
  exec "$TX_REAL_MV" --version
fi
local -a paths=()
for argument in "$@"; do
  case "$argument" in
    --|-T|-n|-f|-rf|-s) continue ;;
  esac
  [[ "/$argument/" != */../* && "$argument" == "$TX_ROOT"/* \
    && "${argument:A}" == "$TX_ROOT"/* ]] || exit 97
  paths+=("$argument")
done
if [[ "$tool" == rm ]]; then
  (( ${#paths} == 1 )) || exit 97
else
  (( ${#paths} == 2 )) || exit 97
fi
print -r -- "$tool:${(j: :)@}" >> "$TX_ROOT/operations"
case "$tool" in
  ln)
    if [[ "${paths[2]}" == "$TX_TRASH/info/"*.trashinfo \
      && -n "${TX_PUBLISH_STATUS:-}" && ! -e "$TX_ROOT/publish-injected" ]]; then
      print -r -- injected > "$TX_ROOT/publish-injected"
      exit "$TX_PUBLISH_STATUS"
    fi
    exec "$TX_REAL_LN" "$@"
    ;;
  rm)
    if [[ "${paths[1]:h}" == "$TX_TRASH/files" \
      && "${paths[1]:t}" == .zdx-file-delete.* \
      && ! -e "$TX_ROOT/payload-rm-injected" ]]; then
      if [[ "${TX_QUAR_REPLACE:-}" == yes ]]; then
        print -r -- injected > "$TX_ROOT/payload-rm-injected"
        "$TX_REAL_MV" -- "${paths[1]}" "$TX_ROOT/original-quarantine" || exit 97
        print -r -- replacement > "${paths[1]}"
        print -r -- "${paths[1]}" > "$TX_ROOT/replacement-path"
        exit 1
      fi
      if [[ -n "${TX_PAYLOAD_RM_STATUS:-}" ]]; then
        print -r -- injected > "$TX_ROOT/payload-rm-injected"
        exit "$TX_PAYLOAD_RM_STATUS"
      fi
    fi
    if [[ "${paths[1]:h}" == "$TX_TRASH/info" \
      && "${paths[1]:t}" == .zdx-file-delete.* \
      && -n "${TX_RECORD_RM_STATUS:-}" && ! -e "$TX_ROOT/record-rm-injected" ]]; then
      print -r -- injected > "$TX_ROOT/record-rm-injected"
      exit "$TX_RECORD_RM_STATUS"
    fi
    if [[ "${paths[1]}" == "$TX_TRASH/info/"*.trashinfo \
      && -n "${TX_DISCARD_STATUS:-}" && -e "$TX_ROOT/move-injected" \
      && ! -e "$TX_ROOT/discard-injected" ]]; then
      print -r -- injected > "$TX_ROOT/discard-injected"
      exit "$TX_DISCARD_STATUS"
    fi
    exec "$TX_REAL_RM" "$@"
    ;;
  mv)
    if [[ "${paths[1]}" == "$TX_WORK/one" && "${paths[2]:h}" == "$TX_TRASH/files" \
      && "${TX_MOVE_FAIL:-}" == yes && ! -e "$TX_ROOT/move-injected" ]]; then
      print -r -- injected > "$TX_ROOT/move-injected"
      exit 1
    fi
    if [[ "${paths[1]:h}" == "$TX_TRASH/files" && "${paths[2]}" == "$TX_WORK/one" \
      && -n "${TX_COMPENSATE_STATUS:-}" ]]; then
      exit "$TX_COMPENSATE_STATUS"
    fi
    if [[ "${paths[1]:h}" == "$TX_TRASH/files" && "${paths[2]}" == "$TX_WORK/one" \
      && "${TX_COMPENSATE_NEST:-}" == yes ]]; then
      command mkdir -m 700 -- "${paths[2]}" || exit 97
      "$TX_REAL_MV" -n -- "${paths[1]}" "${paths[2]}"
      exit $?
    fi
    "$TX_REAL_MV" "$@"
    local -i rc=$?
    if (( rc == 0 )) && [[ "${paths[1]}" == "$TX_WORK/one" \
      && "${paths[2]:h}" == "$TX_TRASH/files" && "${TX_POST_DROP:-}" == yes ]]; then
      "$TX_REAL_RM" -f -- "$TX_TRASH/info/${paths[2]:t}.trashinfo" || exit 97
      if [[ "${TX_POST_CONFLICT:-}" == yes ]]; then
        [[ -d "$TX_WORK" && ! -L "$TX_WORK" ]] || exit 97
        print -r -- squatter > "$TX_WORK/one"
      fi
    fi
    exit "$rc"
    ;;
esac
exit 97
MOCK
    chmod -- 700 "$TX_BIN/$tool"
  done
}

teardown() {
  local parent sealed
  shopt -s nullglob
  for parent in "$TX_WORK"/tree "$TX_TRASH/files"/* "$TX_TRASH/files"/.zdx-file-delete.*; do
    [[ -d "$parent" && ! -L "$parent" ]] || continue
    sealed="$parent/sealed"
    [[ ! -d "$sealed" || -L "$sealed" ]] || chmod -- 700 "$sealed"
  done
  PATH="$TX_ORIGINAL_PATH"
  hash -r
  cleanup_sandbox
}

run_tx() {
  run_zsh 'export PATH="$TX_BIN:$PATH"; builtin cd -- "$TX_WORK" || return 90; '"$1"
}

tx_id() {
  local record
  for record in "$TX_TRASH"/info/*.trashinfo; do
    [[ -f "$record" ]] || continue
    if grep -Fq -- "Path=$TX_WORK/$1" "$record"; then
      record="${record##*/}"
      printf '%s\n' "${record%.trashinfo}"
      return 0
    fi
  done
  return 1
}

tx_pair() {
  printf 'first\n' > "$TX_WORK/one"
  printf 'second\n' > "$TX_WORK/two"
  run run_tx 'file-trash put --yes one two'
  [ "$status" -eq 0 ]
  export TX_ONE_ID TX_TWO_ID
  TX_ONE_ID=$(tx_id one)
  TX_TWO_ID=$(tx_id two)
}

tx_recovery() {
  mkdir -p "$TX_TRASH/files" "$TX_TRASH/info"
  chmod -- 700 "$TX_ROOT/state" "$TX_ROOT/state/zdx" "$TX_TRASH" "$TX_TRASH/files" "$TX_TRASH/info"
  export TX_RECOVERY="$TX_TRASH/files/.zdx-file-delete.1700000000-123456.123.1"
  mkdir -m 700 "$TX_RECOVERY"
  printf 'retained\n' > "$TX_RECOVERY/data"
  chmod -- 600 "$TX_RECOVERY/data"
}

@test "file trash transactions: a real second purge cannot steal a pending put reservation" {
  printf 'first\n' > "$TX_WORK/one"
  run run_tx '
    functions[_tx_same_fs]="${functions[_file_trash_same_filesystem]}"
    _file_trash_same_filesystem() {
      _tx_same_fs "$@" || return $?
      local -a records=("$TX_TRASH/info/"*.trashinfo(N))
      if [[ "$1" == "$TX_WORK/one" && "$2" == "$TX_TRASH/files" \
        && ${#records} == 1 && ! -e "$TX_ROOT/second-started" ]]; then
        print -r -- started > "$TX_ROOT/second-started"
        _file_run_with_timeout 15 "$TX_ZSH" -f "$TX_ROOT/second-purge.zsh" \
          >"$TX_ROOT/second.log" 2>&1 || return 92
      fi
      return 0
    }
    file-trash put --yes one
  '
  [ -f "$TX_ROOT/second-started" ]
  grep -Fq -- 'Purge completed' "$TX_ROOT/second.log"
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [ -z "$(find "$TX_TRASH/files" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "file trash transactions: a lost post-move reservation compensates to the original path" {
  printf 'first\n' > "$TX_WORK/one"
  export TX_POST_DROP=yes
  run run_tx 'file-trash put --yes one'
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [[ "$output" != *'Trashed one as'* ]]
  [ -z "$(find "$TX_TRASH/files" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "file trash transactions: compensation never replaces a conflicting original path" {
  printf 'first\n' > "$TX_WORK/one"
  export TX_POST_DROP=yes TX_POST_CONFLICT=yes
  run run_tx 'file-trash put --yes one'
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_WORK/one")" = squatter ]
  local -a items=("$TX_TRASH/files"/*)
  [ "${#items[@]}" -eq 1 ]
  [ "$(cat "${items[0]}")" = first ]
  [[ "$output" == *'Recovery path:'* && "$output" == *'Original path:'* ]]
  [[ "$output" != *'Trashed one as'* ]]
}

tx_compensation_interruption() {
  printf 'first\n' > "$TX_WORK/one"
  printf 'second\n' > "$TX_WORK/two"
  export TX_POST_DROP=yes TX_COMPENSATE_STATUS="$1"
  run run_tx 'file-trash put --yes one two'
  [ "$status" -eq "$1" ]
  [ ! -e "$TX_WORK/one" ]
  [ "$(cat "$TX_WORK/two")" = second ]
  [[ "$output" == *'Recovery path:'* && "$output" == *'Not run: 1 item'* ]]
}

@test "file trash transactions: compensation130 stops the put batch" { tx_compensation_interruption 130; }
@test "file trash transactions: compensation143 stops the put batch" { tx_compensation_interruption 143; }

tx_publish_interruption() {
  printf 'first\n' > "$TX_WORK/one"
  printf 'second\n' > "$TX_WORK/two"
  export TX_PUBLISH_STATUS="$1"
  run run_tx 'file-trash put --yes one two'
  [ "$status" -eq "$1" ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [ "$(cat "$TX_WORK/two")" = second ]
  [[ "$output" == *'Not run: 1 item'* ]]
}

@test "file trash transactions: record publication130 stops the put batch" { tx_publish_interruption 130; }
@test "file trash transactions: record publication143 stops the put batch" { tx_publish_interruption 143; }

tx_discard_interruption() {
  printf 'first\n' > "$TX_WORK/one"
  printf 'second\n' > "$TX_WORK/two"
  export TX_MOVE_FAIL=yes TX_DISCARD_STATUS="$1"
  run run_tx 'file-trash put --yes one two'
  [ "$status" -eq "$1" ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [ "$(cat "$TX_WORK/two")" = second ]
}

@test "file trash transactions: reservation withdrawal130 stops the put batch" { tx_discard_interruption 130; }
@test "file trash transactions: reservation withdrawal143 stops the put batch" { tx_discard_interruption 143; }

tx_restore_interruption() {
  tx_pair
  export TX_RECORD_RM_STATUS="$1"
  run run_tx 'file-trash restore --yes "$TX_ONE_ID" "$TX_TWO_ID"'
  [ "$status" -eq "$1" ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [ ! -e "$TX_WORK/two" ]
  [ "$(cat "$TX_TRASH/files/$TX_TWO_ID")" = second ]
  [[ "$output" == *'Restored '* && "$output" == *'Not run: 1 item'* ]]
}

@test "file trash transactions: record cleanup130 stops after the restored first item" { tx_restore_interruption 130; }
@test "file trash transactions: record cleanup143 stops after the restored first item" { tx_restore_interruption 143; }

@test "file trash transactions: ordinary record publication failure still permits later items" {
  printf 'first\n' > "$TX_WORK/one"
  printf 'second\n' > "$TX_WORK/two"
  export TX_PUBLISH_STATUS=1
  run run_tx 'file-trash put --yes one two'
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [ ! -e "$TX_WORK/two" ]
  [ "$(cat "$TX_TRASH/files/$(tx_id two)")" = second ]
}

@test "file trash transactions: a replaced files-directory symlink is refused before move" {
  printf 'first\n' > "$TX_WORK/one"
  run run_tx '
    functions[_tx_same_fs]="${functions[_file_trash_same_filesystem]}"
    _file_trash_same_filesystem() {
      _tx_same_fs "$@" || return $?
      local -a records=("$TX_TRASH/info/"*.trashinfo(N))
      if [[ "$1" == "$TX_WORK/one" && "$2" == "$TX_TRASH/files" && ${#records} == 1 ]]; then
        command mv -- "$TX_TRASH/files" "$TX_TRASH/files-original" || return 91
        command ln -s -- "$TX_ROOT/victim" "$TX_TRASH/files" || return 92
      fi
      return 0
    }
    file-trash put --yes one
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [ "$(cat "$TX_ROOT/victim/canary")" = unrelated ]
  [ "$(find "$TX_ROOT/victim" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1 ]
}

@test "file trash transactions: read-only descendant directories are refused before put" {
  mkdir -p "$TX_WORK/tree/sealed"
  printf 'data\n' > "$TX_WORK/tree/sealed/data"
  chmod -- 555 "$TX_WORK/tree/sealed"
  run run_tx 'file-trash put --dry-run --yes tree'
  [ "$status" -eq 1 ]
  [ -f "$TX_WORK/tree/sealed/data" ]
  [[ "$output" == *'chmod u+rwx'* && "$output" == *'sealed'* ]]
  [ ! -e "$TX_TRASH" ]
}

tx_bad_tree_pair() {
  printf 'first\n' > "$TX_WORK/one"
  mkdir -p "$TX_WORK/tree/nested"
  printf 'data\n' > "$TX_WORK/tree/nested/data"
  run run_tx 'file-trash put --yes one tree'
  [ "$status" -eq 0 ]
  export TX_ONE_ID TX_TREE_ID
  TX_ONE_ID=$(tx_id one)
  TX_TREE_ID=$(tx_id tree)
}

@test "file trash transactions: purge dry-run validates every selected tree" {
  tx_bad_tree_pair
  ln -s "$TX_ROOT/victim" "$TX_TRASH/files/$TX_TREE_ID/nested/added"
  run run_tx 'file-trash purge --dry-run --yes "$TX_ONE_ID" "$TX_TREE_ID"'
  [ "$status" -eq 1 ]
  [ -f "$TX_TRASH/files/$TX_ONE_ID" ]
  [ -L "$TX_TRASH/files/$TX_TREE_ID/nested/added" ]
}

@test "file trash transactions: an invalid later tree keeps the earlier selected item" {
  tx_bad_tree_pair
  ln -s "$TX_ROOT/victim" "$TX_TRASH/files/$TX_TREE_ID/nested/added"
  run run_tx 'file-trash purge --yes "$TX_ONE_ID" "$TX_TREE_ID"'
  [ "$status" -eq 1 ]
  [ -f "$TX_TRASH/files/$TX_ONE_ID" ]
  [ -f "$TX_TRASH/info/$TX_ONE_ID.trashinfo" ]
}

@test "file trash transactions: all trees are revalidated after purge confirmation" {
  tx_bad_tree_pair
  run run_tx '
    _file_confirm_mutation() { command ln -s -- "$TX_ROOT/victim" "$TX_TRASH/files/$TX_TREE_ID/nested/added"; }
    file-trash purge --yes "$TX_ONE_ID" "$TX_TREE_ID"
  '
  [ "$status" -eq 1 ]
  [ -f "$TX_TRASH/files/$TX_ONE_ID" ]
  [ -f "$TX_TRASH/info/$TX_ONE_ID.trashinfo" ]
}

@test "file trash transactions: list reports retained quarantine without changing JSON entries" {
  tx_recovery
  run run_tx 'file-trash list --json >"$TX_ROOT/document" 2>"$TX_ROOT/ui"'
  [ "$status" -eq 0 ]
  jq -e '.schema == "zdx.file-trash.v1" and .items == [] and .skipped == []
    and .item_count == 0' "$TX_ROOT/document"
  grep -Fq -- '.zdx-file-delete.1700000000-123456.123.1' "$TX_ROOT/ui"
  [ "$(cat "$TX_RECOVERY/data")" = retained ]
}

@test "file trash transactions: purge all can finish a safe retained quarantine" {
  tx_recovery
  run run_tx 'file-trash purge --all --dry-run --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *'.zdx-file-delete.1700000000-123456.123.1'* ]]
  [ -f "$TX_RECOVERY/data" ]
  run run_tx 'file-trash purge --all --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$TX_RECOVERY" ]
  [ -z "$(find "$TX_TRASH/files" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "file trash transactions: unsafe retained trees refuse before ordinary records disappear" {
  tx_recovery
  mkdir "$TX_RECOVERY/sealed"
  printf 'blocked\n' > "$TX_RECOVERY/sealed/data"
  chmod -- 555 "$TX_RECOVERY/sealed"
  printf '[Trash Info]\nPath=%s\nDeletionDate=2001-02-03T04:05:06\n' "$TX_WORK/gone" \
    > "$TX_TRASH/info/20010203-040506-abcdef.trashinfo"
  chmod -- 600 "$TX_TRASH/info/20010203-040506-abcdef.trashinfo"
  run run_tx 'file-trash purge --all --yes'
  [ "$status" -eq 1 ]
  [ -f "$TX_TRASH/info/20010203-040506-abcdef.trashinfo" ]
  [ -f "$TX_RECOVERY/sealed/data" ]
  [[ "$output" == *'chmod u+rwx'* ]]
  chmod -- 700 "$TX_RECOVERY/sealed"
  run run_tx 'file-trash purge --all --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$TX_RECOVERY" ]
  [ ! -e "$TX_TRASH/info/20010203-040506-abcdef.trashinfo" ]
}

@test "file trash transactions: a quarantine replaced after confirmation is kept" {
  tx_recovery
  run run_tx '
    _file_confirm_mutation() {
      command mv -- "$TX_RECOVERY" "$TX_ROOT/original-recovery" || return 91
      command mkdir -- "$TX_RECOVERY" || return 92
      print -r -- replacement > "$TX_RECOVERY/data"
    }
    file-trash purge --all --yes
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_RECOVERY/data")" = replacement ]
  [ "$(cat "$TX_ROOT/original-recovery/data")" = retained ]
}

@test "file trash transactions: put renews owner permissions inside every directory after consent" {
  mkdir -p "$TX_WORK/tree/sealed"
  printf 'data\n' > "$TX_WORK/tree/sealed/data"
  run run_tx '
    _file_confirm_mutation() { command chmod -- 555 "$TX_WORK/tree/sealed"; }
    file-trash put --yes tree
  '
  [ "$status" -eq 1 ]
  [ -f "$TX_WORK/tree/sealed/data" ]
  [[ "$output" == *'chmod u+rwx'* ]]
  [ ! -e "$TX_TRASH" ]
}

@test "file trash transactions: replacing files with another real directory does not adopt its inode" {
  printf 'first\n' > "$TX_WORK/one"
  run run_tx '
    functions[_tx_same_fs]="${functions[_file_trash_same_filesystem]}"
    _file_trash_same_filesystem() {
      _tx_same_fs "$@" || return $?
      local -a records=("$TX_TRASH/info/"*.trashinfo(N))
      if [[ "$1" == "$TX_WORK/one" && "$2" == "$TX_TRASH/files" && ${#records} == 1 ]]; then
        command mv -- "$TX_TRASH/files" "$TX_TRASH/files-original" || return 91
        command mkdir -- "$TX_TRASH/files" || return 92
        command chmod -- 700 "$TX_TRASH/files" || return 93
      fi
      return 0
    }
    file-trash put --yes one
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [ -z "$(find "$TX_TRASH/files" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "file trash transactions: an unrecognized recovery filename is never deleted" {
  tx_recovery
  mv "$TX_RECOVERY" "$TX_TRASH/files/.zdx-file-delete.unrecognized"
  run run_tx 'file-trash purge --all --yes'
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_TRASH/files/.zdx-file-delete.unrecognized/data")" = retained ]
}

@test "file trash transactions: a hard-linked recovery file refuses the plan" {
  tx_recovery
  rmdir "$TX_RECOVERY" 2>/dev/null || rm -rf "$TX_RECOVERY"
  ln "$TX_ROOT/victim/canary" "$TX_RECOVERY"
  run run_tx 'file-trash purge --all --yes'
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_ROOT/victim/canary")" = unrelated ]
  [ "$(file_links "$TX_RECOVERY")" -eq 2 ]
}

@test "file trash transactions: a retained symlink is purged as the link itself" {
  tx_recovery
  rm -rf "$TX_RECOVERY"
  ln -s "$TX_ROOT/victim" "$TX_RECOVERY"
  run run_tx 'file-trash purge --all --yes'
  [ "$status" -eq 0 ]
  [ ! -L "$TX_RECOVERY" ]
  [ "$(cat "$TX_ROOT/victim/canary")" = unrelated ]
}

@test "file trash transactions: purge all also finishes retained record quarantines" {
  tx_recovery
  rm -rf "$TX_RECOVERY"
  export TX_INFO_RECOVERY="$TX_TRASH/info/.zdx-file-delete.1700000000-123456.123.1"
  printf 'private record\n' > "$TX_INFO_RECOVERY"
  chmod -- 600 "$TX_INFO_RECOVERY"
  run run_tx 'file-trash purge --all --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$TX_INFO_RECOVERY" ]
}

# Faults are armed only after the real same-filesystem check sees a published
# reservation; publication's own digest checks therefore remain unmodified.
tx_validation_interruption() {
  printf 'first\n' > "$TX_WORK/one"
  printf 'second\n' > "$TX_WORK/two"
  export TX_VALIDATION_STATUS="$1" TX_VALIDATION_PHASE="$2"
  run run_tx '
    functions[_tx_same_fs]="${functions[_file_trash_same_filesystem]}"
    functions[_tx_sha]="${functions[_file_sha256_digest]}"
    _file_trash_same_filesystem() {
      _tx_same_fs "$@" || return $?
      local -a records=("$TX_TRASH/info/"*.trashinfo(N))
      if [[ "$1" == "$TX_WORK/one" && ${#records} == 1 ]]; then
        print -r -- armed > "$TX_ROOT/validation-armed"
      fi
      return 0
    }
    _file_sha256_digest() {
      if [[ "$1" == "$TX_TRASH/info/"*.trashinfo \
        && -e "$TX_ROOT/validation-armed" && ! -e "$TX_ROOT/validation-injected" \
        && ( "$TX_VALIDATION_PHASE" == before || ! -e "$TX_WORK/one" ) ]]; then
        print -r -- injected > "$TX_ROOT/validation-injected"
        return "$TX_VALIDATION_STATUS"
      fi
      _tx_sha "$@"
    }
    file-trash put --yes one two
  '
  [ "$status" -eq "$1" ]
  [ -f "$TX_ROOT/validation-injected" ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [ "$(cat "$TX_WORK/two")" = second ]
  [[ "$output" == *'Not run: 1 item'* ]]
}

@test "file trash transactions: reservation validation130 before move stops the batch" { tx_validation_interruption 130 before; }
@test "file trash transactions: reservation validation143 before move stops the batch" { tx_validation_interruption 143 before; }
@test "file trash transactions: reservation validation130 after move compensates and stops" { tx_validation_interruption 130 after; }
@test "file trash transactions: reservation validation143 after move compensates and stops" { tx_validation_interruption 143 after; }

@test "file trash transactions: a failed purge quarantine is found and finished by the next all" {
  printf 'first\n' > "$TX_WORK/one"
  run run_tx 'file-trash put --yes one'
  [ "$status" -eq 0 ]
  export TX_ONE_ID
  TX_ONE_ID=$(tx_id one)
  export TX_PAYLOAD_RM_STATUS=1
  run run_tx 'file-trash purge --yes "$TX_ONE_ID"'
  [ "$status" -eq 1 ]
  [[ "$output" == *'Recovery path:'* ]]
  [ -f "$TX_TRASH/info/$TX_ONE_ID.trashinfo" ]
  run run_tx 'file-trash purge --all --yes'
  [ "$status" -eq 0 ]
  [ -z "$(find "$TX_TRASH/files" -mindepth 1 -maxdepth 1 -print -quit)" ]
  [ -z "$(find "$TX_TRASH/info" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "file trash transactions: replacement during purge cleanup is kept and named unverified" {
  printf 'first\n' > "$TX_WORK/one"
  run run_tx 'file-trash put --yes one'
  [ "$status" -eq 0 ]
  export TX_ONE_ID
  TX_ONE_ID=$(tx_id one)
  export TX_QUAR_REPLACE=yes
  run run_tx 'file-trash purge --yes "$TX_ONE_ID"'
  [ "$status" -eq 1 ]
  local replacement
  replacement=$(cat "$TX_ROOT/replacement-path")
  [ "$(cat "$replacement")" = replacement ]
  [ "$(cat "$TX_ROOT/original-quarantine")" = first ]
  [[ "$output" == *'Unverified path:'* && "$output" != *'Recovery path:'* ]]
}

@test "file trash transactions: a 0644 payload keeps its mode through put and restore" {
  printf 'first\n' > "$TX_WORK/one"
  chmod -- 644 "$TX_WORK/one"
  run run_tx 'file-trash put --yes one'
  [ "$status" -eq 0 ]
  export TX_ONE_ID
  TX_ONE_ID=$(tx_id one)
  [ "$(file_mode "$TX_TRASH/files/$TX_ONE_ID")" = 644 ]
  run run_tx 'file-trash restore --yes "$TX_ONE_ID"'
  [ "$status" -eq 0 ]
  [ "$(file_mode "$TX_WORK/one")" = 644 ]
}

@test "file trash transactions: read-only compression directories retain their existing policy" {
  mkdir "$TX_WORK/tree"
  printf 'first\n' > "$TX_WORK/tree/data"
  chmod -- 555 "$TX_WORK/tree"
  run run_tx 'file-compress --format tar.gz --output saved.tar.gz --dry-run --yes -- tree'
  [ "$status" -eq 0 ]
  [ "$(file_mode "$TX_WORK/tree")" = 555 ]
  chmod -- 700 "$TX_WORK/tree"
  [ ! -e "$TX_WORK/saved.tar.gz" ]
}

@test "file trash transactions: a replacement record before first reservation check is refused" {
  printf 'first\n' > "$TX_WORK/one"
  run run_tx '
    functions[_tx_write_info]="${functions[_file_trash_write_info]}"
    _file_trash_write_info() {
      _tx_write_info "$@" || return $?
      local published_identity="$REPLY" saved_content="$(<"$1")"
      command mv -- "$1" "$TX_ROOT/original-record" || return 91
      print -r -- "$saved_content" > "$1"
      command chmod -- 600 "$1" || return 92
      REPLY="$published_identity"
    }
    file-trash put --yes one
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$TX_WORK/one")" = first ]
  [ -f "$TX_ROOT/original-record" ]
  [ -z "$(find "$TX_TRASH/files" -mindepth 1 -maxdepth 1 -print -quit)" ]
  [ -n "$(find "$TX_TRASH/info" -name '*.trashinfo' -print -quit)" ]
}

@test "file trash transactions: compensation reports an item received by a new destination directory" {
  printf 'first\n' > "$TX_WORK/one"
  export TX_POST_DROP=yes TX_COMPENSATE_NEST=yes
  run run_tx 'file-trash put --yes one'
  [ "$status" -eq 1 ]
  [ -d "$TX_WORK/one" ]
  local nested
  nested=$(find "$TX_WORK/one" -mindepth 1 -maxdepth 1 -type f -print -quit)
  [ -n "$nested" ]
  [ "$(cat "$nested")" = first ]
  [[ "$output" == *'Recovery path:'* && "$output" == *"${nested#"$HOME"}"* ]]
}

@test "file trash transactions: standalone quarantine names and retries need no preloaded datetime" {
  printf 'first\n' > "$TX_WORK/one"
  export TX_PAYLOAD_RM_STATUS=1
  run "$TX_ZSH" -f -c 'emulate -R zsh
    export PATH="$TX_BIN:$PATH"
    source "$TEST_SUITE_ROOT/functions/file-menu.zsh" || exit 91
    builtin cd -- "$TX_WORK" || exit 92
    file-trash put --yes one || exit 93
    local -a records=("$TX_TRASH/info/"*.trashinfo(N))
    (( ${#records} == 1 )) || exit 94
    local id="${${records[1]:t}%.trashinfo}"
    file-trash purge --yes "$id"'
  [ "$status" -eq 1 ]
  local retained
  retained=$(find "$TX_TRASH/files" -name '.zdx-file-delete.*' -print -quit)
  [ -n "$retained" ]
  [ "$(cat "$retained")" = first ]
  # The old standalone generator produced an empty timestamp here.
  [[ "${retained##*/}" =~ ^\.zdx-file-delete\.[0-9]+-[0-9]+\.[0-9]+\.[0-9]+$ ]]
  run "$TX_ZSH" -f -c 'emulate -R zsh
    export PATH="$TX_BIN:$PATH"
    source "$TEST_SUITE_ROOT/functions/file-menu.zsh" || exit 91
    builtin cd -- "$TX_WORK" || exit 92
    file-trash purge --all --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$retained" ]
  [ -z "$(find "$TX_TRASH/info" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "file trash transactions: the historical empty-timestamp quarantine can be finished" {
  tx_recovery
  local legacy="$TX_TRASH/files/.zdx-file-delete..123.1"
  mv "$TX_RECOVERY" "$legacy"
  run run_tx 'file-trash purge --all --dry-run --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *'.zdx-file-delete..123.1'* ]]
  [ "$(cat "$legacy/data")" = retained ]
  run run_tx 'file-trash purge --all --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$legacy" ]
}

@test "file trash transactions: an unreadable descendant is refused with the owner-access remedy" {
  mkdir -p "$TX_WORK/tree/sealed"
  printf 'kept\n' > "$TX_WORK/tree/sealed/data"
  chmod -- 000 "$TX_WORK/tree/sealed"
  run run_tx 'file-trash put --dry-run --yes tree'
  [ "$status" -eq 1 ]
  [ -d "$TX_WORK/tree/sealed" ]
  [ "$(file_mode "$TX_WORK/tree/sealed")" = 0 ]
  [[ "$output" == *'chmod u+rwx'* ]]
  chmod -- 700 "$TX_WORK/tree/sealed"
  [ "$(cat "$TX_WORK/tree/sealed/data")" = kept ]
  [ ! -e "$TX_TRASH" ]
}
