#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  mkdir -m 700 "$HOME/repository" "$HOME/shared" "$HOME/shared/private"
  export GIT_UNSAFE_TEMP="$HOME/shared/private"
  cat > "$HOME/temp-fixture.zsh" <<'ZSH'
command git init -q -b main "$HOME/repository" || return 81
cd "$HOME/repository" || return 82
command git config user.name "Temporary Test" || return 83
command git config user.email "temporary@example.invalid" || return 84
command git config core.hooksPath /dev/null || return 85
command git config commit.gpgSign false || return 86
print -r -- base > tracked
command git add tracked || return 87
command git commit -qm base || return 88
print -r -- changed > tracked
command git stash push -qm saved || return 89
typeset stash_oid=""
stash_oid=$(command git rev-parse refs/stash) || return 90
ZSH
}

teardown() {
  cleanup_sandbox
}

_git_temp_refusal_case() {
  local mode="$1" target="$2"
  chmod -- "$mode" "$target"
  run run_zsh '
    source "$HOME/temp-fixture.zsh" || exit 80
    export TMPDIR="$GIT_UNSAFE_TEMP"
    local operation="" rc=0 failures=0
    local -a reply=()
    for operation in records diff path stash-state stash-page; do
      rc=0
      case "$operation" in
        records) _git_capture_nul ls-files -z ;;
        diff) _git_changes_diff_fingerprint ;;
        path) _git_changes_path_fingerprint tracked ;;
        stash-state) _git_stash_state_fingerprint "$PWD" tracked ;;
        stash-page) _git_stash_page_full "$stash_oid" ;;
      esac >/dev/null 2>"$HOME/$operation.stderr" || rc=$?
      print -r -- "$operation=$rc"
      (( rc == 1 )) || (( ++failures ))
    done
    [[ -z "$(command ls -A "$TMPDIR")" ]] || exit 92
    (( failures == 0 )) || exit 91
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "git temporary safety: every local record and fingerprint rejects an unsafe leaf" {
  _git_temp_refusal_case 777 "$GIT_UNSAFE_TEMP"
}

@test "git temporary safety: every local record and fingerprint rejects a group-writable ancestor" {
  _git_temp_refusal_case 770 "$HOME/shared"
}

@test "git temporary safety: every local record and fingerprint rejects a non-sticky writable ancestor" {
  _git_temp_refusal_case 777 "$HOME/shared"
}

@test "git temporary safety: canonical trusted aliases work and allocations are cleaned" {
  ln -s "$HOME/shared" "$HOME/alias"
  run run_zsh '
    source "$HOME/temp-fixture.zsh" || exit 80
    export TMPDIR="$HOME/alias/private"
    local -a reply=()
    _git_capture_nul ls-files -z || exit 91
    [[ "${reply[*]}" == tracked ]] || exit 92
    _git_changes_diff_fingerprint || exit 93
    _git_changes_path_fingerprint tracked || exit 94
    _git_stash_state_fingerprint "$PWD" tracked || exit 95
    _git_stash_page_full "$stash_oid" >/dev/null 2>/dev/null || exit 96
    [[ -z "$(command ls -A "$TMPDIR")" ]] || exit 97
  '
  [ "$status" -eq 0 ]
}

@test "git temporary safety: amend rechecks its message root after confirmation" {
  run run_zsh '
    source "$HOME/temp-fixture.zsh" || exit 80
    local before=$(command git rev-parse HEAD)
    _git_confirm_plan() {
      command chmod -- 770 "$HOME/shared" || return 1
      export TMPDIR="$GIT_UNSAFE_TEMP"
      # Isolate message staging from earlier snapshot allocations, which the
      # helper matrix covers separately.
      _git_changes_snapshot_matches() { return 0; }
      REPLY=confirmed
    }
    git-amend --message revised >"$HOME/amend.stdout" 2>"$HOME/amend.stderr"
    local rc=$?
    (( rc == 1 )) || { print -r -- "amend=$rc"; exit 91; }
    [[ "$(command git rev-parse HEAD)" == "$before" ]] || exit 92
    [[ -z "$(command ls -A "$TMPDIR")" ]] || exit 93
  '
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "git temporary safety: standalone git validates temporary ancestors" {
  chmod -- 770 "$HOME/shared"
  run zsh -f -c '
    emulate -R zsh
    source "$1/functions/git-menu.zsh" || exit 80
    _git_temp_parent_safe "$GIT_UNSAFE_TEMP"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 1 ] || { printf 'status=%s %s\n' "$status" "$output" >&2; false; }
}
