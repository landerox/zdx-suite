#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031

# Structured --json output of git-status and git-identity-check: one jq-built
# document on stdout, the same exit status as text mode, and no secrets.

setup() {
  load test_helper
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
}

teardown() {
  cleanup_sandbox
}

# Prints Zsh that creates REPO_DIR below the github/personal workspace with an
# upstream one commit behind, one staged, one unstaged, and one untracked file,
# and one stash.
status_repo() {
  cat <<'ZSH'

    REPO_DIR="$WS_BASE_DIR/github/personal/project"
    mkdir -p "$REPO_DIR" || return 81
    command git init -q -b main "$REPO_DIR" || return 82
    cd "$REPO_DIR" || return 83
    command git config user.name "Json Test"
    command git config user.email "json@example.invalid"
    print -r -- "one" > a.txt
    print -r -- "one" > b.txt
    command git add -A && command git commit -q -m "feat: one" || return 84
    command git init -q --bare -b main "$HOME/origin.git" || return 85
    command git remote add origin "$HOME/origin.git" || return 86
    command git push -q -u origin main 2>/dev/null || return 87
    print -r -- "two" > a.txt
    command git commit -q -am "feat: two" || return 88
    print -r -- "stashed" > b.txt
    command git stash push -q -m "kept" || return 89
    print -r -- "staged" > a.txt
    command git add a.txt || return 90
    print -r -- "unstaged" > b.txt
    print -r -- "new" > c.txt
ZSH
}

show_failure() {
  printf 'zsh status: %s\n%s\n' "$status" "$output" >&2
  cat "$HOME"/*.stderr >&2 2>/dev/null || true
}

@test "git json: git-status --json writes one exact zdx.git-status.v1 document" {
  run run_zsh "$(status_repo)"'
    git-status --json >"$HOME/status.stdout" 2>"$HOME/status.stderr" || return 10
    print -r -- "${REPO_DIR:A} $(command git rev-parse HEAD)"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  local repo_dir="${output%% *}" head_oid="${output#* }"
  [ "$(wc -l < "$HOME/status.stdout")" -eq 1 ]
  [ ! -s "$HOME/status.stderr" ]
  ! LC_ALL=C grep -q $'\033' "$HOME/status.stdout" || false
  [ "$(jq -r 'keys_unsorted[0]' "$HOME/status.stdout")" = "schema" ]
  jq -e --arg repo "$repo_dir" --arg head "$head_oid" '
    .schema == "zdx.git-status.v1"
    and .repository == $repo
    and .branch == "main" and .detached == false and .head == $head
    and .upstream == "origin/main" and .ahead == 1 and .behind == 0
    and .operation == null
    and .changes == {staged: 1, unstaged: 1, untracked: 1, conflicted: 0}
    and .stashes == 1
    and .workspace == {platform: "github", identity: "personal"}
    and (keys_unsorted == ["schema", "repository", "branch", "detached", "head",
      "upstream", "ahead", "behind", "operation", "changes", "stashes", "workspace"])
  ' "$HOME/status.stdout"
}

@test "git json: detached, unborn, and in-progress states use null and JSON types" {
  run run_zsh "$(status_repo)"'
    command git checkout -q --detach HEAD || return 9
    print -r -- "0000000000000000000000000000000000000000" \
      > "$(command git rev-parse --absolute-git-dir)/MERGE_HEAD"
    git-status --json >"$HOME/detached.stdout" 2>"$HOME/detached.stderr" || return 10

    command git init -q -b trunk "$HOME/unborn" || return 11
    cd "$HOME/unborn" || return 12
    git-status --json >"$HOME/unborn.stdout" 2>"$HOME/unborn.stderr" || return 13
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  jq -e '
    .branch == null and .detached == true and (.head | test("^[0-9a-f]{40}$"))
    and .upstream == null and .ahead == null and .behind == null
    and .operation == "merge"
  ' "$HOME/detached.stdout"
  jq -e '
    .branch == "trunk" and .detached == false and .head == null
    and .upstream == null and .operation == null and .stashes == 0
    and .workspace == null
    and (.changes | to_entries | all(.value == 0))
  ' "$HOME/unborn.stdout"
}

@test "git json: missing jq, invalid arguments, and no repository keep stdout empty" {
  run run_zsh '
    local -a codes=()
    cd "$HOME" || return 9
    git-status --json >"$HOME/norepo.stdout" 2>"$HOME/norepo.stderr"
    codes+=($?)
    git-status --json --json >"$HOME/usage.stdout" 2>"$HOME/usage.stderr"
    codes+=($?)
    _git_check_cmd() { [[ "$1" != jq ]] && command -v "$1" >/dev/null; }
    git-status --json >"$HOME/nojq.stdout" 2>"$HOME/nojq.stderr"
    codes+=($?)
    git-identity-check --json >>"$HOME/nojq.stdout" 2>>"$HOME/nojq.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "1,2,1,1" ]
  [ ! -s "$HOME/norepo.stdout" ]
  [ ! -s "$HOME/usage.stdout" ]
  [ ! -s "$HOME/nojq.stdout" ]
  grep -Fq "Not inside a Git worktree." "$HOME/norepo.stderr"
  grep -Fq "git-status accepts no arguments other than --json." "$HOME/usage.stderr"
  [ "$(grep -c "jq is required for --json output" "$HOME/nojq.stderr")" -eq 2 ]
}

@test "git json: the nested route keeps the document alone on stdout" {
  run run_zsh "$(status_repo)"'
    git-menu git-status --json >"$HOME/nested.stdout" 2>"$HOME/nested.stderr" ||
      return 10
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$(wc -l < "$HOME/nested.stdout")" -eq 1 ]
  jq -e '.schema == "zdx.git-status.v1"' "$HOME/nested.stdout"
  grep -Fq "completed in" "$HOME/nested.stderr"
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]
}

@test "git json: git-identity-check --json reports matches, mismatches, and not applicable" {
  run run_zsh "$(status_repo)"'
    typeset -gA ZDX_GIT_IDENTITIES=(
      personal "Name|Jane Doe;Email|jane@personal.example;SshKey|~/.ssh/id_personal"
    )
    git-identity-switcher --switch personal local >/dev/null 2>&1 || return 10
    local -a codes=()
    git-identity-check --json >"$HOME/match.stdout" 2>"$HOME/match.stderr"
    codes+=($?)
    command git config user.email jane@work.example
    command git config core.sshCommand "ssh -i ~/.ssh/id_other"
    git-identity-check --json >"$HOME/mismatch.stdout" 2>"$HOME/mismatch.stderr"
    codes+=($?)
    unset ZDX_GIT_IDENTITIES
    git-identity-check --json >"$HOME/none.stdout" 2>"$HOME/none.stderr"
    codes+=($?)
    command git init -q "$HOME/elsewhere" && cd "$HOME/elsewhere" || return 11
    git-identity-check --json >"$HOME/outside.stdout" 2>"$HOME/outside.stderr"
    codes+=($?)
    print -r -- "${(j:,:)codes}"
  '

  [ "$status" -eq 0 ] || { show_failure; false; }
  [ "$output" = "0,1,0,0" ]
  local name
  for name in match mismatch none outside; do
    [ "$(wc -l < "$HOME/$name.stdout")" -eq 1 ]
    [ ! -s "$HOME/$name.stderr" ]
    [ "$(jq -r 'keys_unsorted[0]' "$HOME/$name.stdout")" = "schema" ]
    jq -e '.schema == "zdx.git-identity-check.v1"' "$HOME/$name.stdout"
  done
  jq -e '
    .applicable == true and .reason == null and .platform == "github"
    and .identity == "personal" and .profile == "personal"
    and .matches == true and .mismatches == [] and .fix_command == null
  ' "$HOME/match.stdout"
  jq -e '
    .applicable == true and .matches == false
    and ([.mismatches[].field] == ["user.email", "core.sshCommand"])
    and (.mismatches[0].reason
      == "is jane@work.example; the profile expects jane@personal.example")
    and .fix_command == "git-identity-switcher --switch personal local"
  ' "$HOME/mismatch.stdout"
  ! grep -Eq "id_personal|id_other|\.ssh/" "$HOME/mismatch.stdout" || false
  jq -e '
    .applicable == false and .platform == "github" and .identity == "personal"
    and .profile == null and .matches == null and .mismatches == []
    and (.reason | test("no profile named personal"))
  ' "$HOME/none.stdout"
  jq -e '
    .applicable == false and .platform == null and .identity == null
    and (.reason | test("not below"))
  ' "$HOME/outside.stdout"
}
