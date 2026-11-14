#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "git probes: public PR commands preserve failed authentication probes before other work" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    _git_require_repo() { return 0; }
    _zdx_run_with_timeout() {
      print -r -- "$1:${2:t}" >>"$HOME/probes"
      return "$probe_rc"
    }
    local probe_rc cmd rc
    local -i failures=0
    for probe_rc in 124 130 143 17; do
      for cmd in git-pr-create git-pr-checkout; do
        if [[ "$cmd" == git-pr-create ]]; then
          "$cmd" --dry-run >"$HOME/$cmd.$probe_rc.stdout" 2>"$HOME/$cmd.$probe_rc.stderr"
        else
          "$cmd" 1 >"$HOME/$cmd.$probe_rc.stdout" 2>"$HOME/$cmd.$probe_rc.stderr"
        fi
        rc=$?
        print -r -- "$cmd:$probe_rc:$rc"
        (( rc == probe_rc )) || (( failures++ ))
      done
    done
    (( failures == 0 ))
  '
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$HOME/probes")" -eq 8 ]
  local file
  for file in "$HOME"/*.stdout; do
    [ ! -s "$file" ]
  done
}

@test "git probes: authentication report distinguishes failed probes from unauthenticated state" {
  git init -q "$HOME/repo"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$HOME/repo" || return 91
    command git remote add origin https://github.com/example/project.git || return 92
    _zdx_run_with_timeout() { return "$probe_rc"; }
    local probe_rc rc
    local -i failures=0
    for probe_rc in 124 130 143 17; do
      git-auth >"$HOME/auth.$probe_rc.stdout" 2>"$HOME/auth.$probe_rc.stderr"
      rc=$?
      print -r -- "$probe_rc:$rc"
      (( rc == probe_rc )) || (( failures++ ))
    done
    (( failures == 0 ))
  '
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  local probe_rc
  for probe_rc in 124 130 143 17; do
    [ ! -s "$HOME/auth.$probe_rc.stdout" ]
    [ -s "$HOME/auth.$probe_rc.stderr" ]
    ! grep -Fq 'not authenticated' "$HOME/auth.$probe_rc.stderr" || false
  done
}

@test "git probes: branch and tag batches stop after a timed out or interrupted revalidation" {
  git init -q --bare "$HOME/remote.git"
  git init -q -b main "$HOME/repo"
  git -C "$HOME/repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgSign=false commit -q --allow-empty -m base
  git -C "$HOME/repo" branch topic
  git -C "$HOME/repo" tag first
  git -C "$HOME/repo" tag second
  git -C "$HOME/repo" remote add origin "$HOME/remote.git"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$HOME/repo" || return 91
    _git_sync_remote_snapshot() {
      reply=()
      print -r -- "$*" >>"$HOME/snapshots"
      if [[ -e "$HOME/observed" ]]; then
        return "$probe_rc"
      fi
      : >"$HOME/observed"
      return 0
    }
    _git_tag_remote_snapshot() { _git_sync_remote_snapshot "$@"; }
    local probe_rc cmd rc
    local -i failures=0
    for probe_rc in 124 130 143; do
      for cmd in git-push git-tag-push; do
        command rm -f "$HOME/observed" "$HOME/snapshots"
        if [[ "$cmd" == git-push ]]; then
          "$cmd" --all --yes >"$HOME/$cmd.$probe_rc.stdout" 2>"$HOME/$cmd.$probe_rc.stderr"
        else
          "$cmd" --yes >"$HOME/$cmd.$probe_rc.stdout" 2>"$HOME/$cmd.$probe_rc.stderr"
        fi
        rc=$?
        print -r -- "$cmd:$probe_rc:$rc:$(command wc -l <"$HOME/snapshots")"
        (( rc == probe_rc )) || (( failures++ ))
        [[ $(command wc -l <"$HOME/snapshots") -eq 2 ]] || (( failures++ ))
      done
    done
    (( failures == 0 ))
  '
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  run git --git-dir="$HOME/remote.git" for-each-ref
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  local file
  for file in "$HOME"/*.stdout; do
    [ ! -s "$file" ]
  done
}

@test "git probes: successful GitHub observations use frozen external binaries and closed stdin" {
  cat >"$TEST_MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s:%s:%s:%s\n' "$GIT_TERMINAL_PROMPT" "$GCM_INTERACTIVE" "$GH_PROMPT_DISABLED" "$GIT_ASKPASS" >>"$HOME/environment"
if IFS= read -r unexpected; then exit 96; fi
case "$1 $2" in
  'auth status') exit 0 ;;
  'repo view') printf 'fixture-id\tfixture/repo\thttps://github.com/fixture/repo\n' ;;
  *) exit 97 ;;
esac
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/gh"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    _git_require_repo() { return 0; }
    gh() { print -r -- shadowed >>"$HOME/shadowed"; return 98; }
    _zdx_run_with_timeout() {
      [[ "$1" == 30 && "$2" == /* && -f "$2" && -x "$2" ]] || return 99
      shift
      "$@"
    }
    _git_gh_repo_context < <(print -r -- caller-data)
    local rc=$?
    (( rc == 0 )) || return 91
    [[ "${_GIT_GH_REPO[id]}" == fixture-id ]] || return 92
    [[ "${_GIT_GH_REPO[target]}" == github.com/fixture/repo ]] || return 93
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/shadowed" ]
  [ "$(wc -l <"$HOME/environment")" -eq 2 ]
  [ "$(sort -u "$HOME/environment")" = '0:never:1:' ]
}

probe_pr_picker_fixture() {
  git init -q -b main "$HOME/repo"
  git -C "$HOME/repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgSign=false commit -q --allow-empty -m base
  export GH_PICKER_HEAD
  GH_PICKER_HEAD=$(git -C "$HOME/repo" rev-parse HEAD)
  cat >"$TEST_MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/github.calls"
[[ "$1 $2" == 'pr list' ]] || exit 97
if [[ "$GH_PICKER_STATUS" != 0 ]]; then exit "$GH_PICKER_STATUS"; fi
printf 'PR_fixture\t1\tOPEN\thttps://github.com/fixture/repo/pull/1\t%s\tfeature\tFixture PR\n' "$GH_PICKER_HEAD"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/gh"
}

run_probe_pr_picker() {
  run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$HOME/repo" || return 91
    _git_gh_repo_context() {
      _GIT_GH_REPO=(target github.com/fixture/repo)
    }
    # Enter the interactive adapter without claiming native terminal evidence.
    _git_require_interactive() { return 0; }
    _git_fzf_capture() {
      print -r -- called >>"$HOME/fzf.calls"
      REPLY=""
      return 130
    }
    _git_gh_pr_current() { print -r -- reached >>"$HOME/checkout.calls"; return 97; }
    _git_gh_fetch_remote() { print -r -- reached >>"$HOME/checkout.calls"; return 97; }
    git-pr-checkout >"$HOME/checkout.stdout" 2>"$HOME/checkout.stderr"
    local rc=$?
    print -r -- "checkout:$rc"
    return $rc
  '
}

@test "git probes: PR list producer status 3 is an operational failure before selection" {
  probe_pr_picker_fixture
  export GH_PICKER_STATUS=3
  run run_probe_pr_picker
  printf '%s\n' "$output" >&2
  [ "$status" -eq 1 ]
  [ "$output" = checkout:1 ]
  grep -Fq 'pr list' "$HOME/github.calls"
  grep -Fq 'Pull request listing failed (exit 3)' "$HOME/checkout.stderr"
  [ ! -s "$HOME/checkout.stdout" ]
  [ ! -e "$HOME/fzf.calls" ]
  [ ! -e "$HOME/checkout.calls" ]
}

@test "git probes: deliberate PR picker cancellation remains a successful no-op" {
  probe_pr_picker_fixture
  export GH_PICKER_STATUS=0
  run run_probe_pr_picker
  [ "$status" -eq 0 ]
  [ "$output" = checkout:0 ]
  grep -Fq 'pr list' "$HOME/github.calls"
  [ "$(wc -l <"$HOME/fzf.calls")" -eq 1 ]
  [ ! -s "$HOME/checkout.stdout" ]
  [ ! -e "$HOME/checkout.calls" ]
}

probe_remote_fixture() {
  git init -q --bare "$HOME/remote.git"
  git --git-dir="$HOME/remote.git" symbolic-ref HEAD refs/heads/main
  git init -q -b main "$HOME/repo"
  git -C "$HOME/repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgSign=false commit -q --allow-empty -m base
  git -C "$HOME/repo" branch topic1
  git -C "$HOME/repo" branch topic2
  git -C "$HOME/repo" tag first
  git -C "$HOME/repo" tag second
  git -C "$HOME/repo" remote add origin "$HOME/remote.git"
  git -C "$HOME/repo" push -q --all origin
  git -C "$HOME/repo" push -q --tags origin
  git -C "$HOME/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  export PROBE_REAL_GIT
  PROBE_REAL_GIT=$(command -v git)
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == push ]]; then
  printf '%s\n' "$*" >>"$HOME/push.calls"
  exit 97
fi
exec "$PROBE_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/git"
}

@test "git probes: remote tag deletion stops after revalidation timeout before later targets" {
  probe_remote_fixture
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$HOME/repo" || return 91
    functions[_git_probe_tag_snapshot_saved]="$functions[_git_tag_remote_snapshot]"
    _git_tag_remote_snapshot() {
      print -r -- "$*" >>"$HOME/snapshots"
      [[ ! -e "$HOME/observed" ]] || return "$expected_probe_status"
      : >"$HOME/observed"
      _git_probe_tag_snapshot_saved "$@"
    }
    local expected_probe_status rc
    local -i failures=0
    for expected_probe_status in 124 130 143; do
      command rm -f "$HOME/observed" "$HOME/snapshots"
      git-tag-delete --remote origin --yes first second >"$HOME/delete.$expected_probe_status.stdout" 2>"$HOME/delete.$expected_probe_status.stderr"
      rc=$?
      print -r -- "$expected_probe_status:$rc:$(command wc -l <"$HOME/snapshots")"
      (( rc == expected_probe_status )) || (( failures++ ))
      [[ $(command wc -l <"$HOME/snapshots") -eq 2 ]] || (( failures++ ))
    done
    (( failures == 0 ))
  '
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/push.calls" ]
  git -C "$HOME/repo" show-ref --verify --quiet refs/tags/first
  git -C "$HOME/repo" show-ref --verify --quiet refs/tags/second
  git --git-dir="$HOME/remote.git" show-ref --verify --quiet refs/tags/first
  git --git-dir="$HOME/remote.git" show-ref --verify --quiet refs/tags/second
}

@test "git probes: local branch cleanup preserves default-query timeout before and after review" {
  probe_remote_fixture
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$HOME/repo" || return 91
    _git_get_default_branch() {
      print -r -- called >>"$HOME/default.calls"
      if [[ "$probe_phase" == initial || -e "$HOME/authorized" ]]; then
        return 124
      fi
      print -r -- main
    }
    _git_clean_authorize_plan() { : >"$HOME/authorized"; return 0; }
    local probe_phase rc
    local -i failures=0
    for probe_phase in initial recheck; do
      command rm -f "$HOME/authorized" "$HOME/default.calls"
      clean-branches topic1 --yes >"$HOME/local.$probe_phase.stdout" 2>"$HOME/local.$probe_phase.stderr"
      rc=$?
      print -r -- "$probe_phase:$rc:$(command wc -l <"$HOME/default.calls")"
      (( rc == 124 )) || (( failures++ ))
    done
    (( failures == 0 ))
  '
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/push.calls" ]
  git -C "$HOME/repo" show-ref --verify --quiet refs/heads/topic1
}

@test "git probes: remote cleanup preserves symbolic-ref and default-query timeouts after review" {
  probe_remote_fixture
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$HOME/repo" || return 91
    functions[_git_probe_symrefs_saved]="$functions[_git_remote_symbolic_refs]"
    functions[_git_probe_default_saved]="$functions[_git_clean_remote_default_ref]"
    _git_clean_authorize_plan() { : >"$HOME/authorized"; return 0; }
    _git_remote_symbolic_refs() {
      if [[ -e "$HOME/authorized" && "$probe_kind" == symbolic ]]; then
        print -r -- called >>"$HOME/rechecks"
        return 124
      fi
      _git_probe_symrefs_saved "$@"
    }
    _git_clean_remote_default_ref() {
      if [[ -e "$HOME/authorized" && "$probe_kind" == default ]]; then
        print -r -- called >>"$HOME/rechecks"
        return 124
      fi
      _git_probe_default_saved "$@"
    }
    local probe_kind rc
    local -i failures=0
    for probe_kind in symbolic default; do
      command rm -f "$HOME/authorized" "$HOME/rechecks"
      clean-remote-merged --remote origin --yes topic1 topic2 >"$HOME/remote.$probe_kind.stdout" 2>"$HOME/remote.$probe_kind.stderr"
      rc=$?
      print -r -- "$probe_kind:$rc:$(command wc -l <"$HOME/rechecks")"
      (( rc == 124 )) || (( failures++ ))
      [[ $(command wc -l <"$HOME/rechecks") -eq 1 ]] || (( failures++ ))
    done
    (( failures == 0 ))
  '
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/push.calls" ]
  git --git-dir="$HOME/remote.git" show-ref --verify --quiet refs/heads/topic1
  git --git-dir="$HOME/remote.git" show-ref --verify --quiet refs/heads/topic2
}

@test "git probes: branch push preserves symbolic-ref timeout immediately before publication" {
  probe_remote_fixture
  git -C "$HOME/repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgSign=false commit -q --allow-empty -m next
  git -C "$HOME/repo" branch -f topic1 HEAD
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$HOME/repo" || return 91
    functions[_git_probe_symrefs_saved]="$functions[_git_remote_symbolic_refs]"
    _git_sync_authorize() { : >"$HOME/authorized"; return 0; }
    _git_remote_symbolic_refs() {
      if [[ -e "$HOME/authorized" ]]; then
        print -r -- called >>"$HOME/rechecks"
        return 124
      fi
      _git_probe_symrefs_saved "$@"
    }
    git-push --all --yes >"$HOME/push.stdout" 2>"$HOME/push.stderr"
    local rc=$?
    print -r -- "push:$rc:$(command wc -l <"$HOME/rechecks")"
    (( rc == 124 )) || return 92
    [[ $(command wc -l <"$HOME/rechecks") -eq 1 ]] || return 93
  '
  printf '%s\n' "$output" >&2
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/push.calls" ]
  [ ! -s "$HOME/push.stdout" ]
}
