#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

# Git output adoption: context-aware headings, exact undo plans, untouched
# submodules, and complete JSON publication through the isolated harness.

setup() {
  load test_helper
  export OUTPUT_REAL_GIT OUTPUT_REAL_JQ
  OUTPUT_REAL_GIT=$(type -P git)
  OUTPUT_REAL_JQ=$(type -P jq)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
  export GIT_ALLOW_PROTOCOL=file GIT_PAGER=cat PAGER=cat
  export GIT_AUTHOR_NAME='Output Test' GIT_AUTHOR_EMAIL='output@example.invalid'
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export NO_COLOR=1
}

teardown() {
  cleanup_sandbox
}

output_repo() {
  export OUTPUT_REPO="$HOME/repository"
  "$OUTPUT_REAL_GIT" init -q -b main "$OUTPUT_REPO"
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" config core.hooksPath /dev/null
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" config commit.gpgSign false
  printf 'base\n' >"$OUTPUT_REPO/tracked.txt"
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" add -- tracked.txt
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" commit -q -m base
}

output_status_context() {
  export OUTPUT_HEADING_CONTEXT="$1"
  output_repo
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$OUTPUT_REPO" || return 91
    case "$OUTPUT_HEADING_CONTEXT" in
      direct) git-status ;;
      step) _zdx_step_exec git-status ;;
      verbose) ZDX_VERBOSE=1 _zdx_step_exec git-status ;;
      delegated) _zdx_delegate git-status ;;
      *) return 92 ;;
    esac >"$HOME/status.stdout" 2>"$HOME/status.stderr"
    local command_rc=$?
    print -r -- "$command_rc" >"$HOME/status.rc"
    return "$command_rc"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/status.rc")" -eq 0 ]
  [ ! -s "$HOME/status.stdout" ]
  ! LC_ALL=C grep -q $'\033' "$HOME/status.stderr" || false
  grep -Eq '^  Branch: +main$' "$HOME/status.stderr"
}

@test "git output: direct status keeps one framed heading and UI off stdout" {
  output_status_context direct
  [ "$(grep -Fc '════ Repository Status ════' "$HOME/status.stderr")" -eq 1 ]
}

@test "git output: status inside a core step suppresses its child heading" {
  output_status_context step
  ! grep -Fq 'Repository Status' "$HOME/status.stderr" || false
  ! grep -Fq '════' "$HOME/status.stderr" || false
}

@test "git output: verbose status inside a core step demotes its heading" {
  output_status_context verbose
  grep -Fxq '  ▸ Repository Status' "$HOME/status.stderr"
  ! grep -Fq '════' "$HOME/status.stderr" || false
}

@test "git output: privately delegated status has one demoted heading" {
  output_status_context delegated
  [ "$(grep -Fxc '  ▸ Repository Status' "$HOME/status.stderr")" -eq 1 ]
  ! grep -Fq '════' "$HOME/status.stderr" || false
}

@test "git output: both standalone heading entrypoints have a nonrecursive fallback" {
  run zsh -f -c '
    emulate -R zsh
    source "$TEST_SUITE_ROOT/functions/git-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_ui_heading]} )) || exit 91
    _git_header "Standalone Header" >"$HOME/header.stdout" 2>"$HOME/header.stderr" || exit 92
    _git_ui_heading "Standalone UI" >"$HOME/ui.stdout" 2>"$HOME/ui.stderr" || exit 93
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/header.stdout" ]
  [ ! -s "$HOME/ui.stdout" ]
  [ "$(grep -Fxc '════ Standalone Header ════' "$HOME/header.stderr")" -eq 1 ]
  [ "$(grep -Fxc '════ Standalone UI ════' "$HOME/ui.stderr")" -eq 1 ]
}

@test "git output: human path facts abbreviate HOME while JSON keeps the absolute root" {
  output_repo
  run run_zsh '
    cd "$OUTPUT_REPO" || return 90
    git-status >"$HOME/path.stdout" 2>"$HOME/path.stderr" || return 91
    git-status --json >"$HOME/path.json" 2>"$HOME/path-json.stderr"
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/path.stdout" ]
  "$OUTPUT_REAL_JQ" -e --arg root "$OUTPUT_REPO" '.repository == $root' "$HOME/path.json"
  grep -Eq '^  Path: +~/repository$' "$HOME/path.stderr"
  ! grep -Fq "$HOME" "$HOME/path.stderr" || false
}

output_undo_fixture() {
  output_repo
  printf 'changed\n' >"$OUTPUT_REPO/tracked.txt"
  printf 'new\n' >"$OUTPUT_REPO/new.txt"
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" add -- tracked.txt new.txt
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" commit -q -m second
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" rev-parse HEAD >"$HOME/undo.head.before"
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" write-tree >"$HOME/undo.index.before"
}

output_undo_unchanged() {
  [ "$("$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" rev-parse HEAD)" = "$(cat "$HOME/undo.head.before")" ]
  [ "$("$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" write-tree)" = "$(cat "$HOME/undo.index.before")" ]
  [ "$(cat "$OUTPUT_REPO/tracked.txt")" = changed ]
  [ "$(cat "$OUTPUT_REPO/new.txt")" = new ]
}

output_undo_plan() {
  export OUTPUT_UNDO_MODE="$1"
  output_undo_fixture
  run run_zsh '
    cd "$OUTPUT_REPO" || return 90
    git-undo-commit "--$OUTPUT_UNDO_MODE" --dry-run >"$HOME/undo.stdout" 2>"$HOME/undo.stderr"
    local command_rc=$?
    print -r -- "$command_rc" >"$HOME/undo.rc"
    return "$command_rc"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/undo.rc")" -eq 0 ]
  [ ! -s "$HOME/undo.stdout" ]
  output_undo_unchanged
  [ "$(grep -c '════' "$HOME/undo.stderr")" -eq 1 ]
  grep -Eq '^  Branch: +main$' "$HOME/undo.stderr"
  grep -Eq '^  Current HEAD: +[0-9a-f]+$' "$HOME/undo.stderr"
  grep -Eq '^  Reset target: +[0-9a-f]+$' "$HOME/undo.stderr"
  grep -Eq "^  Mode: +$OUTPUT_UNDO_MODE$" "$HOME/undo.stderr"
  [ "$(grep -Ec '^ *[12] +.*(tracked[.]txt|new[.]txt)' "$HOME/undo.stderr")" -eq 2 ]
  grep -Eq '^ *[12] +.*tracked[.]txt' "$HOME/undo.stderr"
  grep -Eq '^ *[12] +.*new[.]txt' "$HOME/undo.stderr"
  grep -Fq 'Dry run: 2 files planned; nothing was reset.' "$HOME/undo.stderr"
}

@test "git output: hard undo has one heading and a numbered two-file dry-run plan" {
  output_undo_plan hard
}

@test "git output: mixed undo has one heading and a numbered two-file dry-run plan" {
  output_undo_plan mixed
}

@test "git output: declining undo returns success and names the unchanged action" {
  output_undo_fixture
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$OUTPUT_REPO" || return 91
    _git_confirm_outcome() { print -r -- reached >"$HOME/confirm.calls"; REPLY=cancelled; return 0; }
    git-undo-commit --hard >"$HOME/undo.stdout" 2>"$HOME/undo.stderr"
    local command_rc=$?
    print -r -- "$command_rc" >"$HOME/undo.rc"
    return "$command_rc"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/undo.rc")" -eq 0 ]
  [ "$(cat "$HOME/confirm.calls")" = reached ]
  [ ! -s "$HOME/undo.stdout" ]
  output_undo_unchanged
  grep -Fq 'Cancelled: nothing was reset.' "$HOME/undo.stderr"
}

@test "git output: pull-request dry run counts the planned creation without writing" {
  output_repo
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" remote add origin https://github.com/example/repository.git
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" config branch.main.remote origin
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" config branch.main.merge refs/heads/main
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" rev-parse HEAD >"$HOME/pr.head.before"
  cat >"$TEST_MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/gh.calls"
if [[ "$*" == 'repo view --repo github.com/example/repository --json defaultBranchRef --template {{.defaultBranchRef.name}}' ]]; then
  printf 'main\n'
  exit 0
fi
printf 'unexpected gh invocation\n' >&2
exit 97
MOCK
  cat >"$TEST_MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  push|update-ref|ls-remote)
    printf '%s\n' "$*" >>"$HOME/forbidden-git.calls"
    exit 97
    ;;
esac
exec "$OUTPUT_REAL_GIT" "$@"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/gh" "$TEST_MOCK_BIN/git"
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 90
    cd "$OUTPUT_REPO" || return 91
    _git_gh_repo_context() {
      typeset -gA _GIT_GH_REPO=(target github.com/example/repository id R_test host github.com name example/repository url https://github.com/example/repository)
    }
    _git_gh_base_oid() { REPLY=$(command git rev-parse HEAD); }
    _git_gh_remote_head_oid() { REPLY=$(command git rev-parse HEAD); }
    git-pr-create --base main --fill --dry-run >"$HOME/pr.stdout" 2>"$HOME/pr.stderr"
    local command_rc=$?
    print -r -- "$command_rc" >"$HOME/pr.rc"
    return "$command_rc"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/pr.rc")" -eq 0 ]
  [ ! -s "$HOME/pr.stdout" ]
  [ "$(wc -l <"$HOME/gh.calls")" -eq 1 ]
  [ ! -e "$HOME/forbidden-git.calls" ]
  [ "$("$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" rev-parse HEAD)" = "$(cat "$HOME/pr.head.before")" ]
  grep -Fq 'Dry run: 1 pull request planned; nothing was created.' "$HOME/pr.stderr"
}

output_submodule_fixture() {
  output_repo
  export OUTPUT_LIBRARY="$HOME/library"
  "$OUTPUT_REAL_GIT" init -q -b main "$OUTPUT_LIBRARY"
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_LIBRARY" config core.hooksPath /dev/null
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_LIBRARY" config commit.gpgSign false
  printf 'library\n' >"$OUTPUT_LIBRARY/lib.txt"
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_LIBRARY" add -- lib.txt
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_LIBRARY" commit -q -m library
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" -c protocol.file.allow=always submodule add -q "$OUTPUT_LIBRARY" sub
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" commit -qam 'add submodule'
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO/sub" config core.hooksPath /dev/null
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO/sub" config commit.gpgSign false
  printf 'library change\n' >"$OUTPUT_REPO/sub/lib.txt"
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO/sub" commit -qam 'library change'
  "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO/sub" rev-parse HEAD >"$HOME/sub.head.before"
  printf 'ordinary edit\n' >"$OUTPUT_REPO/tracked.txt"
  cat >"$TEST_MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
cat >"$HOME/discard.rows"
while IFS= read -r row; do
  [[ "$row" == *$'\tfile\ttracked.txt' ]] && printf '%s\n' "$row"
done <"$HOME/discard.rows"
exit 0
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/fzf"
}

output_discard_ordinary() {
  output_submodule_fixture
  run run_zsh '
    cd "$OUTPUT_REPO" || return 90
    git-discard --yes >"$HOME/discard.stdout" 2>"$HOME/discard.stderr"
    local command_rc=$?
    print -r -- "$command_rc" >"$HOME/discard.rc"
    return "$command_rc"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/discard.rc")" -eq 0 ]
  [ ! -s "$HOME/discard.stdout" ]
  grep -Fq $'\tfile\ttracked.txt' "$HOME/discard.rows"
  grep -Fq 'Discarded: tracked.txt' "$HOME/discard.stderr"
  [ "$(cat "$OUTPUT_REPO/tracked.txt")" = base ]
  [ "$(cat "$OUTPUT_REPO/sub/lib.txt")" = 'library change' ]
  [ "$("$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO/sub" rev-parse HEAD)" = "$(cat "$HOME/sub.head.before")" ]
  run "$OUTPUT_REAL_GIT" -C "$OUTPUT_REPO" status --porcelain=v1 --untracked-files=no
  [ "$status" -eq 0 ]
  [ "$output" = ' M sub' ]
}

@test "git output: per-file discard omits a modified submodule from selection" {
  output_discard_ordinary
  ! grep -Fq $'\tfile\tsub' "$HOME/discard.rows" || false
  ! grep -Fq 'Discarded: sub' "$HOME/discard.stderr" || false
}

@test "git output: an ordinary tracked file restores while a submodule stays modified" {
  output_discard_ordinary
}

output_failed_json() {
  export OUTPUT_JSON_COMMAND="$1"
  output_repo
  cat >"$TEST_MOCK_BIN/jq" <<'MOCK'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$HOME/jq.args"
printf 'reached\n' >>"$HOME/jq.calls"
printf '{"schema":'
printf 'fixture jq producer failed\n' >&2
exit 17
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/jq"
  run run_zsh '
    cd "$OUTPUT_REPO" || return 90
    "$OUTPUT_JSON_COMMAND" --json >"$HOME/json.stdout" 2>"$HOME/json.stderr"
    local command_rc=$?
    print -r -- "$command_rc" >"$HOME/json.rc"
    return 0
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/json.rc")" -eq 1 ]
  [ "$(cat "$HOME/jq.calls")" = reached ]
  [ -s "$HOME/jq.args" ]
  grep -Fq 'fixture jq producer failed' "$HOME/json.stderr"
  [ ! -s "$HOME/json.stdout" ]
}

@test "git output: failed jq status producer publishes no JSON prefix" {
  output_failed_json git-status
}

@test "git output: failed jq identity producer publishes no JSON prefix" {
  output_failed_json git-identity-check
}

@test "git output: successful JSON keeps schema types compactness and text status" {
  output_repo
  run run_zsh '
    cd "$OUTPUT_REPO" || return 90
    local cmd text_rc json_rc
    for cmd in git-status git-identity-check; do
      "$cmd" >"$HOME/$cmd.text.stdout" 2>"$HOME/$cmd.text.stderr"
      text_rc=$?
      "$cmd" --json >"$HOME/$cmd.json.stdout" 2>"$HOME/$cmd.json.stderr"
      json_rc=$?
      print -r -- "$text_rc:$json_rc" >"$HOME/$cmd.rc"
      (( text_rc == 0 && json_rc == text_rc )) || return 91
    done
  '
  [ "$status" -eq 0 ]
  local cmd
  for cmd in git-status git-identity-check; do
    [ "$(cat "$HOME/$cmd.rc")" = '0:0' ]
    [ ! -s "$HOME/$cmd.text.stdout" ]
    [ ! -s "$HOME/$cmd.json.stderr" ]
    [ "$(wc -l <"$HOME/$cmd.json.stdout")" -eq 1 ]
    ! LC_ALL=C grep -q $'\033' "$HOME/$cmd.json.stdout" || false
    "$OUTPUT_REAL_JQ" -e -s 'length == 1 and (.[0] | keys_unsorted[0]) == "schema"' "$HOME/$cmd.json.stdout"
  done
  "$OUTPUT_REAL_JQ" -e --arg root "$OUTPUT_REPO" '
    .schema == "zdx.git-status.v1" and .repository == $root
    and .branch == "main" and .detached == false and .upstream == null
    and .changes == {staged: 0, unstaged: 0, untracked: 0, conflicted: 0}
    and .stashes == 0 and .workspace == null
  ' "$HOME/git-status.json.stdout"
  "$OUTPUT_REAL_JQ" -e --arg root "$OUTPUT_REPO" '
    .schema == "zdx.git-identity-check.v1" and .repository == $root
    and .applicable == false and (.reason | type) == "string"
    and .matches == null and .mismatches == [] and .fix_command == null
  ' "$HOME/git-identity-check.json.stdout"
}

@test "git output: path display keeps literal data and respects HOME boundaries" {
  # Coverage for the new shared display helper. Its absence on the old base
  # is not a separate defect; the human-path command test is the regression.
  run run_zsh '
    source "$ZSH_CUSTOM/functions/git-menu.zsh" || return 89
    cd "$HOME" || return 88
    if (( ! ${+functions[_git_path_display]} )); then
      print -r -- 90 >"$HOME/path-helper.rc"
      return 90
    fi
    local original_home="$HOME"
    {
      _git_path_display "$HOME" || return 91
      [[ "$REPLY" == "~" ]] || return 92
      _git_path_display "$HOME/child" || return 93
      [[ "$REPLY" == "~/child" ]] || return 94
      _git_path_display "$HOME-neighbor/child" || return 95
      [[ "$REPLY" == "$HOME-neighbor/child" ]] || return 96
      local literal=$'"'"'a [*]? $(touch not-executed) "quote"\tline\nbreak'"'"'
      _git_path_display "$HOME/$literal" || return 97
      [[ "$REPLY" == "~/$literal" ]] || return 98
      _git_path_display "relative/a b" || return 99
      [[ "$REPLY" == "relative/a b" ]] || return 100
      HOME="$original_home/home[*]?"
      _git_path_display "$HOME/literal" || return 101
      [[ "$REPLY" == "~/literal" ]] || return 102
      HOME=/
      _git_path_display "/child" || return 103
      [[ "$REPLY" == "/child" ]] || return 104
      HOME=""
      _git_path_display "/child" || return 105
      [[ "$REPLY" == "/child" ]] || return 106
      HOME="$original_home"
      print -r -- 0 >"$HOME/path-helper.rc"
    } >"$original_home/path-helper.stdout" 2>"$original_home/path-helper.stderr"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/path-helper.rc")" -eq 0 ]
  [ ! -s "$HOME/path-helper.stdout" ]
  [ ! -s "$HOME/path-helper.stderr" ]
  [ ! -e "$HOME/not-executed" ]
}
