#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REAL_GIT=$(command -v git)
  export REAL_GIT
  load test_helper
  WS="$HOME/workspaces"
  export WS
  git config --global user.name "Jane Doe"
  git config --global user.email "jane@example.com"
  git config --global init.defaultBranch main
  export MOCK_GIT_LOG="$TEST_TEMP_DIR/git.log"
  : > "$MOCK_GIT_LOG"
  build_workspace
}

teardown() {
  cleanup_sandbox
}

# Repositories in every state ws-status reports, with upstreams in local
# bare remotes so ahead/behind come from local refs only.
build_workspace() {
  local remotes="$TEST_TEMP_DIR/remotes"
  mkdir -p "$remotes" "$WS/github/personal" "$WS/gitlab/work" "$WS/local"
  local name
  for name in clean dirty diverged; do
    git init -q --bare "$remotes/$name.git"
    git init -q "$WS/github/personal/$name"
    git -C "$WS/github/personal/$name" commit -q --allow-empty -m "initial $name"
    git -C "$WS/github/personal/$name" remote add origin "$remotes/$name.git"
    git -C "$WS/github/personal/$name" push -q -u origin main 2>/dev/null
  done
  printf 'changed\n' > "$WS/github/personal/dirty/tracked"
  git -C "$WS/github/personal/dirty" add tracked
  git -C "$WS/github/personal/dirty" commit -q -m "track a file"
  git -C "$WS/github/personal/dirty" push -q 2>/dev/null
  printf 'edited\n' > "$WS/github/personal/dirty/tracked"
  printf 'new\n' > "$WS/github/personal/dirty/untracked"

  # One commit only on the remote and one only local: ahead 1, behind 1.
  git clone -q "$remotes/diverged.git" "$TEST_TEMP_DIR/other" 2>/dev/null
  git -C "$TEST_TEMP_DIR/other" commit -q --allow-empty -m "remote work"
  git -C "$TEST_TEMP_DIR/other" push -q 2>/dev/null
  git -C "$WS/github/personal/diverged" commit -q --allow-empty -m "local work"
  git -C "$WS/github/personal/diverged" fetch -q 2>/dev/null

  git init -q "$WS/gitlab/work/detached"
  git -C "$WS/gitlab/work/detached" commit -q --allow-empty -m one
  git -C "$WS/gitlab/work/detached" commit -q --allow-empty -m two
  git -C "$WS/gitlab/work/detached" checkout -q --detach HEAD~1

  git init -q "$WS/gitlab/work/stashed"
  printf 'base\n' > "$WS/gitlab/work/stashed/file"
  git -C "$WS/gitlab/work/stashed" add file
  git -C "$WS/gitlab/work/stashed" commit -q -m base
  printf 'saved\n' > "$WS/gitlab/work/stashed/file"
  git -C "$WS/gitlab/work/stashed" stash -q

  # Depth two, no commits, and no upstream.
  git init -q "$WS/local/scratch"
}

# A git that records fetches and runs every other command with the real Git.
install_fetch_mock() {
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
arguments=("$@")
directory="$PWD"
index=0
while (( index < ${#arguments[@]} )); do
  case "${arguments[index]}" in
    -C) directory="${arguments[index + 1]}"; ((index += 2)) ;;
    -c) ((index += 2)) ;;
    -*) ((index += 1)) ;;
    *) break ;;
  esac
done
if [[ "${arguments[index]:-}" == fetch ]]; then
  marker="$MOCK_FETCH_DIR/running.$$"
  : > "$marker"
  running=$(find "$MOCK_FETCH_DIR" -name 'running.*' | wc -l | tr -d ' ')
  printf 'fetch|%s|%s|prompt=%s|running=%s\n' "${directory##*/}" \
    "${arguments[*]:index}" "${GIT_TERMINAL_PROMPT:-unset}" "$running" \
    >> "$MOCK_GIT_LOG"
  sleep "${MOCK_FETCH_SLEEP:-0.3}"
  rm -f "$marker"
  case ",${MOCK_FETCH_FAIL:-}," in
    *",${directory##*/},"*) exit 128 ;;
  esac
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/git"
  export MOCK_FETCH_DIR="$TEST_TEMP_DIR/fetches"
  mkdir -p "$MOCK_FETCH_DIR"
}

@test "ws status: text report lists every state with attention first" {
  install_fetch_mock
  run run_zsh 'NO_COLOR=1 ws-status 2>&1 >"$HOME/status.stdout"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/status.stdout" ]
  [[ "$output" == *"════ Workspace Status ════"* ]]
  [[ "$output" == *"Workspace root:"*"~/workspaces"* ]]
  [[ "$output" == *"Repositories:"*"6"* ]]
  [[ "$output" == *"4 of 6 repositories need attention."* ]]
  local table
  table=$(printf '%s\n' "$output" | grep -E '^  (Workspace +Repository|github|gitlab|local)')
  [[ "$(printf '%s\n' "$table" | head -n 1)" == "  Workspace "*"Repository"*"Last commit" ]]
  # Repositories that need nothing come last, in path order.
  [[ "$(printf '%s\n' "$table" | tail -n 2 | head -n 1)" == "  github/personal"*"clean"*"main"*"clean"*"up to date"*"0"*"just now" ]]
  printf '%s\n' "$table" | grep -Eq 'dirty +main +2 +up to date'
  printf '%s\n' "$table" | grep -Eq 'diverged +main +clean +ahead 1, behind 1'
  printf '%s\n' "$table" | grep -Eq 'detached +detached at [0-9a-f]{7} +clean +no upstream'
  printf '%s\n' "$table" | grep -Eq 'stashed +main +clean +no upstream +1 '
  printf '%s\n' "$table" | grep -Eq '^  local +scratch +main +clean +no upstream +0 +none$'
  # Without --fetch, no network command runs.
  ! grep -q '^fetch' "$MOCK_GIT_LOG" || false
}

@test "ws status: JSON is one document with the documented shape" {
  run run_zsh 'ws-status --json 2>/dev/null >"$HOME/status.json"; print -r -- "rc=$?"'
  [ "$output" = "rc=0" ]
  # Exactly one compact document: one line ending in a newline.
  [ "$(wc -l < "$HOME/status.json")" -eq 1 ]
  [ "$(tail -c 1 "$HOME/status.json" | od -An -c | tr -d ' ')" = '\n' ]
  output=$(cat "$HOME/status.json")
  printf '%s\n' "$output" | jq -e 'type == "object"' >/dev/null
  [ "$(printf '%s\n' "$output" | jq -s 'length')" -eq 1 ]
  [[ "$output" != *$'\033'* ]]
  printf '%s\n' "$output" | jq -e --arg base "$WS" '
    (keys_unsorted[0] == "schema")
    and .schema == "zdx.ws-status.v1"
    and .base == $base
    and .fetched == false
    and .counts == {repositories: 6, attention: 4, errors: 0}
    and (.repositories | length) == 6
    and (.repositories[-2:] | map(.repository)) == ["clean", "scratch"]
    and ([.repositories[] | select(.attention)] | length) == 4
    and (.repositories | map(.attention) | . == (sort | reverse))
  ' >/dev/null
  printf '%s\n' "$output" | jq -e '
    def repo($n): .repositories[] | select(.repository == $n);
    (repo("clean") | .branch == "main" and .upstream == "origin/main"
      and .upstream_state == "tracking" and .ahead == 0 and .behind == 0
      and .changes == 0 and .stashes == 0 and .attention == false
      and .attention_reasons == [] and .platform == "github"
      and .identity == "personal" and .workspace == "github/personal"
      and .relative_path == "github/personal/clean" and .fetch == null
      and .error == null and (.head | test("^[0-9a-f]{7}$"))
      and (.last_commit_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
    and (repo("dirty") | .changes == 2 and .attention_reasons == ["changes"])
    and (repo("diverged") | .ahead == 1 and .behind == 1
      and .attention_reasons == ["ahead", "behind"])
    and (repo("detached") | .detached == true and .branch == null
      and .upstream == null and .ahead == null
      and .attention_reasons == ["detached"])
    and (repo("stashed") | .stashes == 1 and .attention_reasons == ["stashes"])
    and (repo("scratch") | .workspace == "local" and .platform == null
      and .head == null and .last_commit_at == null and .changes == 0
      and .attention == false)
  ' >/dev/null
}

@test "ws status: --fetch is disclosed, bounded, prompt-free, and skips repositories without remotes" {
  install_fetch_mock
  export WS_FETCH_JOBS=2
  # More fetchable repositories than jobs, so the bound is exercised.
  local name
  for name in one two three; do
    git clone -q "$TEST_TEMP_DIR/remotes/clean.git" "$WS/github/personal/extra-$name" 2>/dev/null
  done
  run run_zsh 'NO_COLOR=1 ws-status --fetch 2>&1 >/dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ Fetching 6 repositories over the network with git fetch --prune (at most 2 at a time, 60s each)."* ]]
  [[ "$output" == *"✔ Fetched 6 repositories."* ]]
  [ "$(grep -c '^fetch|' "$MOCK_GIT_LOG")" -eq 6 ]
  ! grep -q '^fetch|detached|\|^fetch|stashed|\|^fetch|scratch|' "$MOCK_GIT_LOG" || false
  ! grep -v '|fetch --prune --quiet|' <(grep '^fetch|' "$MOCK_GIT_LOG") || false
  ! grep -v '|prompt=0|' <(grep '^fetch|' "$MOCK_GIT_LOG") || false
  local running
  for running in $(sed -nE 's/.*\|running=([0-9]+)$/\1/p' "$MOCK_GIT_LOG"); do
    [ "$running" -le 2 ]
  done
  local -a leftovers=("$TMPDIR"/zdx-ws-*)
  [ ! -e "${leftovers[0]}" ]
}

@test "ws status: failed and timed-out fetches are reported and return 1" {
  install_fetch_mock
  export MOCK_FETCH_FAIL="dirty"
  run run_zsh 'NO_COLOR=1 ws-status --fetch --json 2>"$HOME/stderr"'
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | jq -e '
    .fetched == true
    and ([.repositories[] | select(.repository == "dirty")][0]
      | .fetch == "failed" and (.attention_reasons | index("fetch-failed")))
    and ([.repositories[] | select(.repository == "clean")][0] | .fetch == "ok")
    and ([.repositories[] | select(.repository == "scratch")][0] | .fetch == "skipped")
  ' >/dev/null
  grep -Fq '⚠ Fetch failed: github/personal/dirty (status 128)' "$HOME/stderr"
  grep -Fq '⚠ Fetched 2 of 3 repositories; 1 failed.' "$HOME/stderr"

  export MOCK_FETCH_FAIL="" MOCK_FETCH_SLEEP=5
  run run_zsh '_WS_FETCH_TIMEOUT=1; NO_COLOR=1 ws-status --fetch 2>&1 >/dev/null'
  [ "$status" -eq 1 ]
  [[ "$output" == *"⚠ Fetch timed out: github/personal/clean"* ]]
  [[ "$output" == *"(fetch failed)"* ]]
}

@test "ws status: an unreadable repository is an error row and status 1" {
  printf 'garbage\n' > "$WS/gitlab/work/stashed/.git/HEAD"
  run run_zsh 'NO_COLOR=1 ws-status 2>&1'
  [ "$status" -eq 1 ]
  [[ "$output" == *"✘ gitlab/work/stashed: git status failed (status 128)"* ]]
  run run_zsh 'ws-status --json 2>/dev/null'
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | jq -e '
    .counts.errors == 1
    and ([.repositories[] | select(.repository == "stashed")][0]
      | .error == "git status failed (status 128)" and .attention_reasons == ["error"])
  ' >/dev/null
}

@test "ws status: an empty workspace and a missing jq are handled" {
  mkdir -p "$HOME/empty"
  run run_zsh 'WS_BASE_DIR="$HOME/empty"; ws-status --json 2>/dev/null'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  printf '%s\n' "$output" | jq -e '.repositories == [] and .counts.repositories == 0' >/dev/null

  run run_zsh 'WS_BASE_DIR="$HOME/empty"; NO_COLOR=1 ws-status 2>&1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"No repositories were found below ~/empty."* ]]

  run run_zsh '
    functions[_ws_test_command_path]="${functions[_ws_command_path]}"
    _ws_command_path() {
      [[ "${1-}" == jq ]] && return 1
      _ws_test_command_path "$@"
    }
    ws-status --json 2>"$HOME/stderr"
  '
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -Fq 'jq is required for ws-status --json' "$HOME/stderr"
}
