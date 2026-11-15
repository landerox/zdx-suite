#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export PREVIEW_REAL_GIT
  PREVIEW_REAL_GIT=$(type -P git)
  export PREVIEW_REAL_MKTEMP
  PREVIEW_REAL_MKTEMP=$(type -P mktemp)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0
  export GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat
  export GIT_AUTHOR_NAME='Preview Test' GIT_AUTHOR_EMAIL=preview@example.invalid
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export TERM=dumb NO_COLOR=1
  unset PREVIEW_FORCE_CANCEL PREVIEW_SIGNAL_OWNER _ZDX_GIT_PREVIEW_PATH_DIR
  export PREVIEW_CASE="$HOME/preview"
  mkdir -p "$PREVIEW_CASE"
  PREVIEW_FAILURES=0
}

teardown() { cleanup_sandbox; }

preview_check() {
  if "$@"; then return 0; fi
  printf 'Assertion failed:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  PREVIEW_FAILURES=$((PREVIEW_FAILURES + 1))
}

preview_reject() {
  if ! "$@"; then return 0; fi
  printf 'Unexpected match:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  PREVIEW_FAILURES=$((PREVIEW_FAILURES + 1))
}

preview_canary() {
  case "$1" in
    $'A\nB') printf NEWLINE ;;
    'A\nB') printf BACKSLASH ;;
    $'B\tC') printf TAB ;;
    'Café.txt') printf UNICODE ;;
    $'Ttail\n') printf TRAILING ;;
    Zplain.txt) printf PLAIN ;;
    $'U\nuntracked\n') printf UNTRACKED ;;
    *) return 97 ;;
  esac
}

preview_record_tempdirs() {
  cat >"$TEST_MOCK_BIN/mktemp" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *zdx-git-preview-paths.XXXXXX*)
    created=$("$PREVIEW_REAL_MKTEMP" "$@") || exit "$?"
    printf '%s\0' "$created" >>"$PREVIEW_CASE/directories.nul"
    printf '%s\n' "$created"
    ;;
  *) exec "$PREVIEW_REAL_MKTEMP" "$@" ;;
esac
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/mktemp"
}

preview_assert_cleaned() {
  local directory
  preview_check test -s "$PREVIEW_CASE/directories.nul"
  [[ -f "$PREVIEW_CASE/directories.nul" ]] || return 0
  while IFS= read -r -d '' directory; do
    preview_check test ! -e "$directory"
    preview_check test ! -L "$directory"
  done <"$PREVIEW_CASE/directories.nul"
}

# Keep the literal selected row; parse a copy only for preview arguments.
# Each program runs through the same fixed POSIX shell while the picker is live.
preview_recorder() {
  cat >"$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
cat >"$PREVIEW_CASE/rows.tsv"
preview=''
next_preview=0
for argument in "$@"; do
  if [[ "$next_preview" == 1 ]]; then preview="$argument"; next_preview=0; fi
  case "$argument" in
    --preview) next_preview=1 ;;
    --preview=*) preview="${argument#--preview=}" ;;
  esac
done
[[ -n "$preview" ]] || exit 96
printf '%s\n' "$preview" >"$PREVIEW_CASE/program"
exec 3<"$PREVIEW_CASE/raw-records.nul"
ordinal=0
selected=''
while IFS= read -r row; do
  IFS=$'\t' read -r id kind label extra <<<"$row"
  [[ "$id" -eq $((ordinal + 1)) ]] || exit 96
  case "$kind" in
    file|tracked|untracked)
      IFS= read -r -d '' expected_kind <&3 || exit 96
      IFS= read -r -d '' raw_path <&3 || exit 96
      [[ "$kind" == "$expected_kind" ]] || exit 96
      printf '%s\0%s\0' "$id" "$raw_path" >>"$PREVIEW_CASE/id-paths.nul"
      program="$preview"
      program=${program//\{1\}/'"$1"'}
      program=${program//\{2\}/'"$2"'}
      program=${program//\{3\}/'"$3"'}
      program=${program//\{4\}/'"$4"'}
      program=${program//\{n\}/'"$5"'}
      unsupported='\{[0-9nqfsr+][^}]*\}'
      [[ ! "$program" =~ $unsupported ]] || exit 96
      printf '%s\n' "$id:$kind" >>"$PREVIEW_CASE/reached"
      PREVIEW_IN_PROGRAM=1 /bin/sh -c "$program" preview "$id" "$kind" "$label" "$extra" "$ordinal" \
        >"$PREVIEW_CASE/row-$id.stdout" 2>"$PREVIEW_CASE/row-$id.stderr"
      printf '%s\n' "$?" >"$PREVIEW_CASE/row-$id.status"
      [[ "$raw_path" != $'A\nB' ]] || selected="$row"
      ;;
  esac
  ordinal=$((ordinal + 1))
done <"$PREVIEW_CASE/rows.tsv"
if IFS= read -r -d '' unexpected <&3; then exit 96; fi
exec 3<&-
printf '%s\n' complete >"$PREVIEW_CASE/raw-order.checked"
[[ "$PREVIEW_ACTION" != stash && "${PREVIEW_FORCE_CANCEL:-0}" != 1 ]] || exit 130
[[ -n "$selected" ]] || exit 95
printf '%s\n' "$selected" >"$PREVIEW_CASE/selected.row"
printf '%s\n' "$selected"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/fzf"
}

preview_fixture() {
  export PREVIEW_WORK="$PREVIEW_CASE/repository"
  "$PREVIEW_REAL_GIT" init -q -b main "$PREVIEW_WORK" || return 81
  "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" config core.hooksPath /dev/null || return 82
  "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" config commit.gpgSign false || return 83
  local -a paths=($'A\nB' 'A\nB' $'B\tC' 'Café.txt' $'Ttail\n' Zplain.txt)
  local path canary
  for path in "${paths[@]}"; do printf 'before\n' >"$PREVIEW_WORK/$path" || return 84; done
  "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" add -A || return 85
  "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" commit -q -m 'preview baseline' || return 86
  for path in "${paths[@]}"; do
    canary=$(preview_canary "$path") || return 87
    printf 'PREVIEW_%s\n' "$canary" >"$PREVIEW_WORK/$path" || return 88
  done
  local -i inventory_rc=0
  case "$PREVIEW_ACTION" in
    unstage)
      "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" add -A || return 89
      "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" diff --cached --name-only --no-renames -z -- \
        >"$PREVIEW_CASE/raw-tracked.nul" 2>"$PREVIEW_CASE/raw-tracked.stderr" || inventory_rc=$?
      ;;
    discard)
      "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" diff --name-only --no-renames -z --ignore-submodules=all -- \
        >"$PREVIEW_CASE/raw-tracked.nul" 2>"$PREVIEW_CASE/raw-tracked.stderr" || inventory_rc=$?
      ;;
    stash)
      printf 'PREVIEW_UNTRACKED\n' >"$PREVIEW_WORK/U"$'\n'untracked$'\n' || return 90
      "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" stash push -qu -m 'preview stash' || return 91
      export PREVIEW_STASH_OID
      PREVIEW_STASH_OID=$("$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" rev-parse refs/stash) || return 92
      "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" diff --name-only --no-renames -z \
        "$PREVIEW_STASH_OID^1" "$PREVIEW_STASH_OID" -- \
        >"$PREVIEW_CASE/raw-tracked.nul" 2>"$PREVIEW_CASE/raw-tracked.stderr" || inventory_rc=$?
      "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" ls-tree -r -z --name-only "$PREVIEW_STASH_OID^3" \
        >"$PREVIEW_CASE/raw-untracked.nul" 2>"$PREVIEW_CASE/raw-untracked.stderr" || return 93
      printf '%s\0' $'U\nuntracked\n' >"$PREVIEW_CASE/expected-untracked.nul"
      cmp "$PREVIEW_CASE/raw-untracked.nul" "$PREVIEW_CASE/expected-untracked.nul" || return 94
      ;;
    *) return 95 ;;
  esac
  printf '%s\n' "$inventory_rc" >"$PREVIEW_CASE/raw-tracked.status"
  [[ "$inventory_rc" == 0 ]] || return 96
  printf '%s\0' "${paths[@]}" >"$PREVIEW_CASE/expected-tracked.nul"
  cmp "$PREVIEW_CASE/raw-tracked.nul" "$PREVIEW_CASE/expected-tracked.nul" || return 97
  : >"$PREVIEW_CASE/raw-records.nul"
  local kind=file
  [[ "$PREVIEW_ACTION" != stash ]] || kind=tracked
  while IFS= read -r -d '' path; do
    printf '%s\0%s\0' "$kind" "$path" >>"$PREVIEW_CASE/raw-records.nul"
  done <"$PREVIEW_CASE/raw-tracked.nul"
  if [[ "$PREVIEW_ACTION" == stash ]]; then
    while IFS= read -r -d '' path; do
      printf '%s\0%s\0' untracked "$path" >>"$PREVIEW_CASE/raw-records.nul"
    done <"$PREVIEW_CASE/raw-untracked.nul"
  fi
  "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" for-each-ref --format='%(objectname)%09%(refname)' >"$PREVIEW_CASE/refs.before" || return 98
  "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" symbolic-ref HEAD >"$PREVIEW_CASE/head.before" || return 99
  "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" status --porcelain=v2 -z >"$PREVIEW_CASE/status.before.nul" || return 100
  preview_record_tempdirs
  preview_recorder
}

preview_assert() {
  export PREVIEW_ACTION="$1" PREVIEW_LOCALE="$2"
  preview_fixture || return 101
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$PREVIEW_WORK" || return 91
    [[ "$PREVIEW_LOCALE" != C ]] || export LC_ALL=C
    _git_require_interactive() { return 0; }
    case "$PREVIEW_ACTION" in
      unstage) git-unstage --yes ;;
      discard) git-discard --yes ;;
      stash) _git_stash_browse_files "$PREVIEW_STASH_OID" "stash@{0}" ;;
    esac >"$PREVIEW_CASE/command.stdout" 2>"$PREVIEW_CASE/command.stderr"
    local -i command_rc=$?
    print -r -- "$command_rc" >"$PREVIEW_CASE/command.primary.status"
    return $command_rc
  '
  local public_status="$status"
  printf 'public:%s\n' "$public_status" >&2
  preview_check test "$public_status" -eq 0
  preview_check test "$(cat "$PREVIEW_CASE/command.primary.status")" -eq 0
  preview_check test ! -s "$PREVIEW_CASE/command.stdout"
  preview_check test -s "$PREVIEW_CASE/raw-order.checked"
  preview_check test -s "$PREVIEW_CASE/reached"
  # Assert every producer and content oracle; an early collision cannot hide
  # the ordinary ASCII positive or the trailing-newline/untracked results.
  local id path canary actual_rc other
  while IFS= read -r -d '' id && IFS= read -r -d '' path; do
    canary=$(preview_canary "$path") || return 102
    actual_rc=$(cat "$PREVIEW_CASE/row-$id.status")
    printf '%s:%s:%s\n' "$id" "$canary" "$actual_rc" >>"$PREVIEW_CASE/oracles.status"
    printf 'preview:%s:%s:%s\n' "$id" "$canary" "$actual_rc" >&2
    preview_check test "$actual_rc" -eq 0
    preview_check grep -Fq "+PREVIEW_$canary" "$PREVIEW_CASE/row-$id.stdout"
    for other in NEWLINE BACKSLASH TAB UNICODE TRAILING PLAIN UNTRACKED; do
      [[ "$other" == "$canary" ]] || preview_reject grep -Fq "+PREVIEW_$other" "$PREVIEW_CASE/row-$id.stdout"
    done
  done <"$PREVIEW_CASE/id-paths.nul"
  if [[ "$PREVIEW_ACTION" == unstage ]]; then
    while IFS= read -r -d '' path; do
      run "$PREVIEW_REAL_GIT" --literal-pathspecs -C "$PREVIEW_WORK" diff --cached --quiet -- "$path"
      if [[ "$path" == $'A\nB' ]]; then preview_check test "$status" -eq 0; else preview_check test "$status" -eq 1; fi
    done <"$PREVIEW_CASE/raw-tracked.nul"
  elif [[ "$PREVIEW_ACTION" == discard ]]; then
    while IFS= read -r -d '' path; do
      canary=$(preview_canary "$path") || return 103
      if [[ "$path" == $'A\nB' ]]; then
        preview_check test "$(cat "$PREVIEW_WORK/$path")" = before
      else
        preview_check test "$(cat "$PREVIEW_WORK/$path")" = "PREVIEW_$canary"
      fi
    done <"$PREVIEW_CASE/raw-tracked.nul"
  else
    "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" status --porcelain=v2 -z >"$PREVIEW_CASE/status.after.nul" || return 104
    preview_check cmp "$PREVIEW_CASE/status.before.nul" "$PREVIEW_CASE/status.after.nul"
  fi
  "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" for-each-ref --format='%(objectname)%09%(refname)' >"$PREVIEW_CASE/refs.after" || return 105
  "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" symbolic-ref HEAD >"$PREVIEW_CASE/head.after" || return 106
  preview_check cmp "$PREVIEW_CASE/refs.before" "$PREVIEW_CASE/refs.after"
  preview_check cmp "$PREVIEW_CASE/head.before" "$PREVIEW_CASE/head.after"
  preview_assert_cleaned
  [ "$PREVIEW_FAILURES" -eq 0 ]
}

@test "git preview paths: unstage preserves raw paths and content in UTF-8" {
  preview_assert unstage UTF8
}
@test "git preview paths: discard preserves raw paths and content in UTF-8" {
  preview_assert discard UTF8
}
@test "git preview paths: stash preserves raw paths and content in UTF-8" {
  preview_assert stash UTF8
}
@test "git preview paths: unstage preserves raw paths and content under C" {
  preview_assert unstage C
}
@test "git preview paths: discard preserves raw paths and content under C" {
  preview_assert discard C
}
@test "git preview paths: stash preserves raw paths and content under C" {
  preview_assert stash C
}

@test "git preview paths: trusted temporary root placeholders remain literal data" {
  local literal_root="$HOME/tmp {3} 'quoted space"
  mkdir -m 700 "$literal_root"
  export TMPDIR="$literal_root"
  preview_assert discard UTF8
}

preview_create_handle() {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    local -a _git_preview_paths_handle=()
    local old_mask=$(umask)
    _git_preview_paths_create _git_preview_paths_handle 7 "Ttail"$'"'"'\n'"'"' 9 plain
    local -i create_rc=$?
    print -r -- "$create_rc" >"$PREVIEW_CASE/create.status"
    (( create_rc == 0 )) || return $create_rc
    [[ "$(umask)" == "$old_mask" ]] || return 91
    printf "%s\0" "${_git_preview_paths_handle[@]}" >"$PREVIEW_CASE/handle.nul"
    local -x _ZDX_GIT_PREVIEW_PATH_DIR="${_git_preview_paths_handle[1]}"
    _git_preview_paths_read_program "${_git_preview_paths_handle[1]}" "${_git_preview_paths_handle[2]}" || return 92
    print -r -- "$REPLY" >"$PREVIEW_CASE/reader.program"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$PREVIEW_CASE/create.status")" -eq 0 ]
  local field
  PREVIEW_HANDLE=()
  while IFS= read -r -d '' field; do PREVIEW_HANDLE+=("$field"); done <"$PREVIEW_CASE/handle.nul"
  PREVIEW_DIRECTORY="${PREVIEW_HANDLE[0]}"
}

preview_cleanup_handle() {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    local -a handle=()
    local field=""
    while IFS= read -r -d "" field; do handle+=("$field"); done <"$PREVIEW_CASE/handle.nul"
    _git_preview_paths_cleanup "${handle[@]}" >"$PREVIEW_CASE/cleanup.stdout" 2>"$PREVIEW_CASE/cleanup.stderr"
    local -i cleanup_rc=$?
    print -r -- "$cleanup_rc" >"$PREVIEW_CASE/cleanup.status"
    return $cleanup_rc
  '
}

@test "git preview paths: private modes and exact trailing-newline round trip survive quoted temporary roots" {
  local quoted_root="$HOME/tmp 'quoted"$'\n'" root"
  mkdir -m 700 "$quoted_root"
  export TMPDIR="$quoted_root"
  preview_record_tempdirs
  preview_create_handle
  [ "$(file_mode "$PREVIEW_DIRECTORY")" = 700 ]
  [ "$(file_owner_uid "$PREVIEW_DIRECTORY")" -eq "$EUID" ]
  local id
  for id in 7 9; do
    [ "$(file_mode "$PREVIEW_DIRECTORY/$id")" = 600 ]
    [ "$(file_owner_uid "$PREVIEW_DIRECTORY/$id")" -eq "$EUID" ]
    [ "$(file_links "$PREVIEW_DIRECTORY/$id")" -eq 1 ]
  done
  printf '%s' $'Ttail\n' >"$PREVIEW_CASE/expected.raw"
  cmp "$PREVIEW_DIRECTORY/7" "$PREVIEW_CASE/expected.raw"
  local program
  program=$(cat "$PREVIEW_CASE/reader.program")
  program=${program//\{1\}/'"$1"'}
  export _ZDX_GIT_PREVIEW_PATH_DIR="$PREVIEW_DIRECTORY"
  # Compare literal bytes because command substitution would strip newlines
  # and BATS output cannot retain the terminating NUL.
  local read_rc=0
  /bin/sh -c "$program"'printf "%s\0" "$path"' preview 7 \
    >"$PREVIEW_CASE/read.nul" 2>"$PREVIEW_CASE/read.stderr" || read_rc=$?
  printf '%s\n' "$read_rc" >"$PREVIEW_CASE/read.status"
  [ "$read_rc" -eq 0 ]
  printf '%s\0' $'Ttail\n' >"$PREVIEW_CASE/expected.nul"
  cmp "$PREVIEW_CASE/read.nul" "$PREVIEW_CASE/expected.nul"
  printf 'FOREIGN\n' >"$quoted_root/escape"
  local bad_id
  for bad_id in '' 0 007 '../escape' '1;false'; do
    run /bin/sh -c "$program"'printf "%s" "$path"' preview "$bad_id"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
  preview_cleanup_handle
  [ "$status" -eq 0 ]
  [ ! -e "$PREVIEW_DIRECTORY" ]
  [ "$(cat "$quoted_root/escape")" = FOREIGN ]
  [ ! -s "$PREVIEW_CASE/cleanup.stdout" ]
}

@test "git preview paths: cleanup refuses substituted file and directory identities" {
  local variant old_case="$PREVIEW_CASE"
  for variant in file directory; do
    export PREVIEW_CASE="$old_case/$variant"
    mkdir -p "$PREVIEW_CASE"
    preview_create_handle
    if [[ "$variant" == file ]]; then
      mv "$PREVIEW_DIRECTORY/7" "$PREVIEW_DIRECTORY/7.original"
      (umask 077; printf 'FOREIGN\n' >"$PREVIEW_DIRECTORY/7")
    else
      mv "$PREVIEW_DIRECTORY" "$PREVIEW_DIRECTORY.original"
      mkdir -m 700 "$PREVIEW_DIRECTORY"
      printf 'FOREIGN\n' >"$PREVIEW_DIRECTORY/7"
    fi
    preview_cleanup_handle
    preview_check test "$status" -eq 1
    preview_check test "$(cat "$PREVIEW_DIRECTORY/7")" = FOREIGN
    preview_check test ! -s "$PREVIEW_CASE/cleanup.stdout"
    if [[ "$variant" == file ]]; then
      preview_check test -e "$PREVIEW_DIRECTORY/7.original"
    else
      preview_check test -e "$PREVIEW_DIRECTORY.original/7"
      preview_check test -e "$PREVIEW_DIRECTORY.original/9"
    fi
  done
  [ "$PREVIEW_FAILURES" -eq 0 ]
}

@test "git preview paths: unsafe temporary parent refuses allocation" {
  mkdir -m 777 "$HOME/unsafe"
  chmod -- 777 "$HOME/unsafe"
  preview_record_tempdirs
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    local -a _git_preview_paths_handle=()
    TMPDIR="$HOME/unsafe"
    _git_preview_paths_create _git_preview_paths_handle 1 plain >"$PREVIEW_CASE/create.stdout" 2>"$PREVIEW_CASE/create.stderr"
    local -i create_rc=$?
    print -r -- "$create_rc" >"$PREVIEW_CASE/create.status"
    (( ${#_git_preview_paths_handle[@]} == 0 )) || return 91
    return $create_rc
  '
  [ "$status" -eq 1 ]
  [ ! -e "$PREVIEW_CASE/directories.nul" ]
  [ ! -s "$PREVIEW_CASE/create.stdout" ]
}

@test "git preview paths: confined native interruptions clean all three owning caller lifetimes" {
  local action signal expected_rc
  for action in unstage discard stash; do
    for signal in INT TERM; do
      export PREVIEW_ACTION="$action" PREVIEW_SIGNAL="$signal"
      export PREVIEW_CASE="$HOME/native-$action-$signal"
      mkdir -p "$PREVIEW_CASE"
      preview_fixture
      run run_zsh '
        source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
        cd "$PREVIEW_WORK" || return 91
        _git_require_interactive() { return 0; }
        functions[_preview_observed_create]="${functions[_git_preview_paths_create]}"
        _git_preview_paths_create() {
          _preview_observed_create "$@"
          local -i observed_create_rc=$?
          builtin printf "%s:%s\n" "$observed_create_rc" "${_git_preview_paths_operation_rc-unset}" >"$PREVIEW_CASE/create.observed"
          return $observed_create_rc
        }
        print() {
          builtin print "$@"
          if [[ "${3-}" == $'"'"'A\nB'"'"' && ${#_git_preview_paths_handle[@]} -ge 3 \
            && ! -e "$PREVIEW_CASE/unwind.reached" ]]; then
            builtin printf "%s\0" "${_git_preview_paths_handle[@]}" >"$PREVIEW_CASE/unwind.handle.nul"
            builtin print -r -- "$$" >"$PREVIEW_CASE/unwind.reached"
            builtin kill -"$PREVIEW_SIGNAL" "$$"
          fi
        }
        trap - INT TERM HUP
        trap >"$PREVIEW_CASE/traps.before"
        local old_mask="$(umask)"
        case "$PREVIEW_ACTION" in
          unstage) git-unstage --yes ;;
          discard) git-discard --yes ;;
          stash) _git_stash_browse_files "$PREVIEW_STASH_OID" "stash@{0}" ;;
        esac >"$PREVIEW_CASE/command.stdout" 2>"$PREVIEW_CASE/command.stderr"
        local -i command_rc=$?
        builtin print -r -- "$command_rc" >"$PREVIEW_CASE/command.primary.status"
        trap >"$PREVIEW_CASE/traps.after"
        command cmp "$PREVIEW_CASE/traps.before" "$PREVIEW_CASE/traps.after" || return 92
        [[ "$(umask)" == "$old_mask" ]] || return 93
        return $command_rc
      '
      expected_rc=130
      [[ "$signal" != TERM ]] || expected_rc=143
      printf 'native:%s:%s:%s\n' "$action" "$signal" "$status" >&2
      preview_check test "$status" -eq "$expected_rc"
      preview_check test -e "$PREVIEW_CASE/unwind.reached"
      preview_check test "$(cat "$PREVIEW_CASE/create.observed")" = "$expected_rc:$expected_rc"
      preview_check test ! -e "$PREVIEW_CASE/reached"
      preview_check test ! -s "$PREVIEW_CASE/command.stdout"
      preview_assert_cleaned
      "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" status --porcelain=v2 -z >"$PREVIEW_CASE/status.after.nul"
      preview_check cmp "$PREVIEW_CASE/status.before.nul" "$PREVIEW_CASE/status.after.nul"
    done
  done
  [ "$PREVIEW_FAILURES" -eq 0 ]
}

preview_cancel_recorder() {
  cat >"$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
cat >"$PREVIEW_CASE/cancel.rows.tsv"
while IFS= read -r -d '' directory; do
  [[ -d "$directory" && ! -L "$directory" ]] || exit 96
  printf 'alive\n' >>"$PREVIEW_CASE/alive"
done <"$PREVIEW_CASE/directories.nul"
printf '%s\n' "$PREVIEW_PICKER_STATUS" >"$PREVIEW_CASE/picker.status"
if [[ "${PREVIEW_SIGNAL_OWNER:-0}" == 1 ]]; then
  printf '%s\n' "$PREVIEW_OWNER_PID" >"$PREVIEW_CASE/owner.target"
  kill -INT "$PREVIEW_OWNER_PID" || exit 96
  printf 'sent\n' >"$PREVIEW_CASE/owner.signalled"
fi
exit "$PREVIEW_PICKER_STATUS"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/fzf"
}

preview_capture_cancel() {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$PREVIEW_WORK" || return 91
    _git_require_interactive() { return 0; }
    export PREVIEW_OWNER_PID=$$
    print -r -- "$PREVIEW_OWNER_PID" >"$PREVIEW_CASE/owner.pid"
    trap "print -r -- inherited >\"\$PREVIEW_CASE/inherited-signal\"" INT TERM HUP
    trap >"$PREVIEW_CASE/traps.before"
    local -x _ZDX_GIT_PREVIEW_PATH_DIR=outer-value
    case "$PREVIEW_ACTION" in
      unstage) git-unstage --yes ;;
      discard) git-discard --yes ;;
      stash) _git_stash_browse_files "$PREVIEW_STASH_OID" "stash@{0}" ;;
    esac >"$PREVIEW_CASE/command.stdout" 2>"$PREVIEW_CASE/command.stderr"
    local -i command_rc=$?
    print -r -- "$command_rc" >"$PREVIEW_CASE/command.primary.status"
    trap >"$PREVIEW_CASE/traps.after"
    command cmp "$PREVIEW_CASE/traps.before" "$PREVIEW_CASE/traps.after" || return 92
    [[ "$_ZDX_GIT_PREVIEW_PATH_DIR" == outer-value ]] || return 93
    return $command_rc
  '
}

@test "git preview paths: cancellation and picker errors clean resources and restore inherited handlers" {
  local action code expected_rc
  for action in unstage discard stash; do
    for code in 130 143 2; do
      export PREVIEW_ACTION="$action" PREVIEW_PICKER_STATUS="$code"
      export PREVIEW_CASE="$HOME/picker-$action-$code"
      mkdir -p "$PREVIEW_CASE"
      preview_fixture
      preview_cancel_recorder
      preview_capture_cancel
      expected_rc=1
      [[ "$code" != 130 ]] || expected_rc=0
      printf 'picker:%s:%s:%s\n' "$action" "$code" "$status" >&2
      preview_check test "$status" -eq "$expected_rc"
      preview_check test -s "$PREVIEW_CASE/alive"
      preview_check test "$(cat "$PREVIEW_CASE/picker.status")" -eq "$code"
      preview_check test ! -e "$PREVIEW_CASE/inherited-signal"
      preview_check test ! -s "$PREVIEW_CASE/command.stdout"
      preview_assert_cleaned
      "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" status --porcelain=v2 -z >"$PREVIEW_CASE/status.after.nul"
      preview_check cmp "$PREVIEW_CASE/status.before.nul" "$PREVIEW_CASE/status.after.nul"
    done
  done
  [ "$PREVIEW_FAILURES" -eq 0 ]
}

@test "git preview paths: empty picker cancellation remains zero when its owning Zsh receives INT" {
  local action
  for action in unstage discard stash; do
    export PREVIEW_ACTION="$action" PREVIEW_PICKER_STATUS=130 PREVIEW_SIGNAL_OWNER=1
    export PREVIEW_CASE="$HOME/picker-native-$action"
    mkdir -p "$PREVIEW_CASE"
    preview_fixture
    preview_cancel_recorder
    run run_zsh '
      source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
      cd "$PREVIEW_WORK" || return 91
      _git_require_interactive() { return 0; }
      export PREVIEW_OWNER_PID=$$
      print -r -- "$PREVIEW_OWNER_PID" >"$PREVIEW_CASE/owner.pid"
      functions[_preview_observed_capture]="${functions[_git_fzf_capture]}"
      _git_fzf_capture() {
        _preview_observed_capture "$@"
        local -i capture_rc=$?
        print -r -- "$capture_rc" >"$PREVIEW_CASE/capture.status"
        print -rn -- "$REPLY" >"$PREVIEW_CASE/capture.data"
        return $capture_rc
      }
      case "$PREVIEW_ACTION" in
        unstage) git-unstage --yes ;;
        discard) git-discard --yes ;;
        stash) _git_stash_browse_files "$PREVIEW_STASH_OID" "stash@{0}" ;;
      esac >"$PREVIEW_CASE/command.stdout" 2>"$PREVIEW_CASE/command.stderr"
      local -i command_rc=$?
      print -r -- "$command_rc" >"$PREVIEW_CASE/command.primary.status"
      return $command_rc
    '
    printf 'picker owner INT:%s:%s\n' "$action" "$status" >&2
    preview_check test "$status" -eq 0
    preview_check test -s "$PREVIEW_CASE/owner.signalled"
    preview_check cmp "$PREVIEW_CASE/owner.pid" "$PREVIEW_CASE/owner.target"
    preview_check test "$(cat "$PREVIEW_CASE/capture.status")" -eq 130
    preview_check test ! -s "$PREVIEW_CASE/capture.data"
    preview_check test ! -s "$PREVIEW_CASE/command.stdout"
    preview_assert_cleaned
    "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" status --porcelain=v2 -z >"$PREVIEW_CASE/status.after.nul"
    preview_check cmp "$PREVIEW_CASE/status.before.nul" "$PREVIEW_CASE/status.after.nul"
  done
  [ "$PREVIEW_FAILURES" -eq 0 ]
}

@test "git preview paths: failed raw-path reads stop the actual preview before any Git fallback" {
  export PREVIEW_REAL_CAT
  PREVIEW_REAL_CAT=$(type -P cat)
  local action id path
  for action in unstage discard stash; do
    export PREVIEW_ACTION="$action" PREVIEW_FORCE_CANCEL=1
    export PREVIEW_CASE="$HOME/read-failure-$action"
    mkdir -p "$PREVIEW_CASE"
    preview_fixture
    "$PREVIEW_REAL_CAT" >"$TEST_MOCK_BIN/cat" <<'MOCK'
#!/usr/bin/env bash
if [[ "${PREVIEW_IN_PROGRAM:-0}" == 1 && "$*" == *zdx-git-preview-paths.* ]]; then
  printf '17\n' >>"$PREVIEW_CASE/cat.status"
  printf 'fixture raw path read failed\n' >&2
  exit 17
fi
exec "$PREVIEW_REAL_CAT" "$@"
MOCK
    "$PREVIEW_REAL_CAT" >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${PREVIEW_IN_PROGRAM:-0}" == 1 ]]; then
  printf '%s\0' "$@" >>"$PREVIEW_CASE/program-git.args.nul"
fi
exec "$PREVIEW_REAL_GIT" "$@"
MOCK
    chmod -- 700 "$TEST_MOCK_BIN/cat" "$TEST_MOCK_BIN/git"
    preview_capture_cancel
    preview_check test "$status" -eq 0
    preview_check test -s "$PREVIEW_CASE/cat.status"
    preview_check test ! -e "$PREVIEW_CASE/program-git.args.nul"
    while IFS= read -r -d '' id && IFS= read -r -d '' path; do
      preview_check test "$(cat "$PREVIEW_CASE/row-$id.status")" -eq 17
      preview_check test ! -s "$PREVIEW_CASE/row-$id.stdout"
    done <"$PREVIEW_CASE/id-paths.nul"
    preview_assert_cleaned
    "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" status --porcelain=v2 -z >"$PREVIEW_CASE/status.after.nul"
    preview_check cmp "$PREVIEW_CASE/status.before.nul" "$PREVIEW_CASE/status.after.nul"
  done
  [ "$PREVIEW_FAILURES" -eq 0 ]
}

@test "git preview paths: action-only discard rows remain available with an empty path index" {
  local variant action_row action_id action_kind action_label action_extra expected_kind
  local -a action_rows=()
  for variant in staged untracked; do
    export PREVIEW_ACTION=discard PREVIEW_PICKER_STATUS=130
    export PREVIEW_CASE="$HOME/action-only-$variant"
    mkdir -p "$PREVIEW_CASE"
    preview_fixture
    "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" reset -q --hard HEAD
    if [[ "$variant" == staged ]]; then
      printf 'staged only\n' >"$PREVIEW_WORK/Zplain.txt"
      "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" add -- Zplain.txt
    else
      printf 'untracked only\n' >"$PREVIEW_WORK/only-untracked"
    fi
    "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" status --porcelain=v2 -z >"$PREVIEW_CASE/status.before.nul"
    preview_cancel_recorder
    preview_capture_cancel
    preview_check test "$status" -eq 0
    preview_check test -s "$PREVIEW_CASE/alive"
    action_rows=()
    while IFS= read -r action_row; do
      action_rows+=("$action_row")
    done <"$PREVIEW_CASE/cancel.rows.tsv"
    preview_check test "${#action_rows[@]}" -eq 1
    IFS=$'\t' read -r action_id action_kind action_label action_extra <<<"${action_rows[0]-}"
    expected_kind=all
    [[ "$variant" != untracked ]] || expected_kind=all-untracked
    preview_check test "$action_id" = 1
    preview_check test "$action_kind" = "$expected_kind"
    preview_check test -n "$action_label"
    preview_check test -z "$action_extra"
    preview_reject grep -Eq $'\tfile\t' "$PREVIEW_CASE/cancel.rows.tsv"
    preview_assert_cleaned
    "$PREVIEW_REAL_GIT" -C "$PREVIEW_WORK" status --porcelain=v2 -z >"$PREVIEW_CASE/status.after.nul"
    preview_check cmp "$PREVIEW_CASE/status.before.nul" "$PREVIEW_CASE/status.after.nul"
  done
  [ "$PREVIEW_FAILURES" -eq 0 ]
}
