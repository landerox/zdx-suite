#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REAL_GIT=$(command -v git)
  export REAL_GIT
  load test_helper || return "$?"
  ws_portability_trace_setup || return 1
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
# Each fetch line names the repository-local variables that reached it and,
# when WS_STATUS_SHELL_PID names the ws-status shell, how many processes
# separate the fetch from that shell.
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
  inherited=""
  for name in $("$REAL_GIT" rev-parse --local-env-vars) GIT_NAMESPACE; do
    [[ -n "${!name+set}" ]] && inherited+="${inherited:+,}$name"
  done
  depth=unknown
  if [[ "${WS_STATUS_SHELL_PID:-}" =~ ^[0-9]+$ ]]; then
    ps_program=/bin/ps
    [[ -x "$ps_program" ]] || ps_program=/usr/bin/ps
    depth=0
    ancestor="$PPID"
    while [[ "$ancestor" =~ ^[0-9]+$ && "$ancestor" != "$WS_STATUS_SHELL_PID" ]] \
      && (( ancestor > 1 && depth < 8 )); do
      depth=$((depth + 1))
      ancestor=$("$ps_program" -o ppid= -p "$ancestor" | tr -d ' ')
    done
    [[ "$ancestor" == "$WS_STATUS_SHELL_PID" ]] || depth=lost
  fi
  printf 'fetch|%s|%s|prompt=%s|inherited=%s|depth=%s|running=%s\n' \
    "${directory##*/}" "${arguments[*]:index}" "${GIT_TERMINAL_PROMPT:-unset}" \
    "${inherited:-none}" "$depth" "$running" >> "$MOCK_GIT_LOG"
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

# A repository outside the workspace on another branch: an inherited GIT_DIR
# or GIT_WORK_TREE would make Git describe it instead of the one named by -C.
make_outside_repository() {
  export WS_OUTSIDE="$TEST_TEMP_DIR/outside"
  git init -q -b elsewhere "$WS_OUTSIDE"
  git -C "$WS_OUTSIDE" commit -q --allow-empty -m outside
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
  run -0 run_zsh 'ws-status --json 2>/dev/null >"$HOME/status.json"; print -r -- "rc=$?"'
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
  require_ws_fetch_gnu
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
  ! grep -Eq '^fetch[|](detached|stashed|scratch)[|]' "$MOCK_GIT_LOG" || false
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
  require_ws_fetch_gnu
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

@test "ws status: an inherited GIT_DIR, GIT_WORK_TREE, or GIT_CONFIG_PARAMETERS never redirects the probes" {
  # Git exports these to its hooks and to git rebase --exec, and vcsh and
  # yadm export them in their shells; Git then ignores -C <repository>.
  make_outside_repository
  mkdir -p "$TEST_TEMP_DIR/foreign-tree"
  printf 'foreign\n' > "$TEST_TEMP_DIR/foreign-tree/foreign"
  printf '*\n' > "$TEST_TEMP_DIR/ignore-everything"
  run run_zsh 'ws-status --json 2>/dev/null'
  [ "$status" -eq 0 ]
  local expected="$output"
  printf '%s\n' "$expected" | jq -e '
    .counts == {repositories: 6, attention: 4, errors: 0}
    and ([.repositories[] | select(.branch == "elsewhere")] | length) == 0
  ' >/dev/null
  WS_DIRTY_STATUS=$(git --no-optional-locks -C "$WS/github/personal/dirty" status --porcelain)
  export WS_DIRTY_STATUS
  local name value mismatches=""
  for name in GIT_DIR GIT_WORK_TREE GIT_CONFIG_PARAMETERS; do
    case "$name" in
      GIT_DIR) value="$WS_OUTSIDE/.git" ;;
      GIT_WORK_TREE) value="$TEST_TEMP_DIR/foreign-tree" ;;
      GIT_CONFIG_PARAMETERS) value="'core.excludesFile=$TEST_TEMP_DIR/ignore-everything'" ;;
    esac
    export WS_INHERITED_NAME="$name" WS_INHERITED_VALUE="$value"
    run run_zsh '
      typeset -gx "$WS_INHERITED_NAME=$WS_INHERITED_VALUE" || exit 3
      # The value is hostile: it changes what a plain Git call reports.
      [[ "$(command git --no-optional-locks -C "$WS/github/personal/dirty" \
        status --porcelain 2>&1)" != "$WS_DIRTY_STATUS" ]] || exit 4
      ws-status --json 2>/dev/null
    '
    printf '%s: status=%s %s\n' "$name" "$status" "$output" >&2
    [[ "$status" -eq 0 && "$output" == "$expected" ]] || mismatches+=" $name"
  done
  printf 'mismatches:%s\n' "$mismatches" >&2
  [ -z "$mismatches" ]
}

@test "ws status: --fetch lists and fetches each repository, not an inherited one" {
  require_ws_fetch_gnu
  install_fetch_mock
  make_outside_repository
  # An inherited -c option can also name a remote no repository has.
  export WS_INJECTED_REMOTE="'remote.injected.url=https://example.invalid/injected.git'"
  run run_zsh '
    export WS_STATUS_SHELL_PID=$$
    export GIT_DIR="$WS_OUTSIDE/.git" GIT_WORK_TREE="$WS_OUTSIDE"
    export GIT_CONFIG_PARAMETERS="$WS_INJECTED_REMOTE"
    NO_COLOR=1 ws-status --fetch --json 2>"$HOME/stderr"
  '
  sed 's/^/stderr: /' "$HOME/stderr" >&2
  sed 's/^/log: /' "$MOCK_GIT_LOG" >&2
  [ "$status" -eq 0 ]
  grep -Fq '⚠ Fetching 3 repositories over the network' "$HOME/stderr"
  [ "$(grep '^fetch|' "$MOCK_GIT_LOG" | cut -d '|' -f 2 | sort | tr '\n' ' ')" = "clean dirty diverged " ]
  ! grep '^fetch|' "$MOCK_GIT_LOG" | grep -vF '|inherited=none|' || false
  # The status shell owns a fresh OWNER, which owns GNU timeout. Its fixed
  # guardian is the recorder parent, so these three ancestors precede the shell.
  if command -v timeout >/dev/null || command -v gtimeout >/dev/null; then
    ! grep '^fetch|' "$MOCK_GIT_LOG" | grep -vF '|depth=3|' || false
  fi
  printf '%s\n' "$output" | jq -e '
    [.repositories[] | {repository, branch, fetch}] | sort_by(.repository)
    == [
      {repository: "clean", branch: "main", fetch: "ok"},
      {repository: "detached", branch: null, fetch: "skipped"},
      {repository: "dirty", branch: "main", fetch: "ok"},
      {repository: "diverged", branch: "main", fetch: "ok"},
      {repository: "scratch", branch: "main", fetch: "skipped"},
      {repository: "stashed", branch: "main", fetch: "skipped"}
    ]
  ' >/dev/null
}

@test "ws status: a read-only repository variable refuses fetch before starting the batch" {
  install_fetch_mock
  make_outside_repository
  run run_zsh '
    typeset -rx GIT_DIR="$WS_OUTSIDE/.git"
    # Permit discovery only; the read-only carrier must fail preflight before
    # any capability owner, fetch job or private endpoint set starts.
    functions[_ws_test_git_command]="${functions[_ws_git_command]}"
    _ws_git_command() {
      [[ "${@[-1]}" == remote ]] && { print -r -- origin; return 0; }
      _ws_test_git_command "$@"
    }
    NO_COLOR=1 ws-status --fetch --json 2>"$HOME/stderr"
  '
  sed 's/^/stderr: /' "$HOME/stderr" >&2
  sed 's/^/log: /' "$MOCK_GIT_LOG" >&2
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -Fq 'Read-only repository variables prevent safe --fetch.' "$HOME/stderr"
  ! grep -Eq 'Fetching |Fetched |retained|unverified' "$HOME/stderr" || false
  ! grep -q '^fetch|' "$MOCK_GIT_LOG" || false
  local leftovers=("$TMPDIR"/zdx-ws-fetch.*)
  [ ! -e "${leftovers[0]}" ]
}

@test "ws status: a read-only inherited GIT_DIR fails closed instead of redirecting" {
  make_outside_repository
  run run_zsh '
    typeset -rx GIT_DIR="$WS_OUTSIDE/.git"
    ws-status --json 2>/dev/null
  '
  printf 'status=%s %s\n' "$status" "$output" >&2
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | jq -e '
    .counts.errors == 6
    and ([.repositories[] | select(.error == null or .branch == "elsewhere")]
      | length) == 0
  ' >/dev/null
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

# Published fixture traces always belong to the current test sandbox.
ws_portability_trace_setup() {
  case "${BATS_TEST_NUMBER-}" in ''|*[!0-9]*) return 1 ;; esac
  [[ -n "${TEST_TEMP_DIR-}" && "$TEST_TEMP_DIR" == "${_ZDX_TEST_SANDBOX_ROOT-}" \
    && -d "$TEST_TEMP_DIR" && ! -L "$TEST_TEMP_DIR" ]] || return 1
  WSP_TRACE_ROOT="$TEST_TEMP_DIR/ws-portability-traces"
  mkdir -m 700 "$WSP_TRACE_ROOT" || return 1
  WSP_TRACE_CASE="$BATS_TEST_NUMBER"
  WSP_TRACE_NAME="${BATS_TEST_DESCRIPTION-}"
  [[ -n "$WSP_TRACE_NAME" ]] || return 1
  export WSP_TRACE_ROOT WSP_TRACE_CASE WSP_TRACE_NAME
}

ws_portability_common_prelude() {
  cat <<'WSP_COMMON_PROGRAM'
source "$ZSH_CUSTOM/functions/ws-menu.zsh" || exit 90
_ws_fetch_load_helpers || exit 91
# Private test support. Definitions only; execution needs separate approval.
typeset -g _wsp_trace_base="" _wsp_trace_fault=0

_wsp_trace_begin() {
  emulate -L zsh
  unsetopt MULTIBYTE
  local kind="$1" root="${WSP_TRACE_ROOT-}" name="${WSP_TRACE_NAME-}"
  local -A info=()
  local -i serial=0 fd=-1 count=0
  [[ "$kind" == (controlled|absence|capability|model) \
    && "${WSP_TRACE_CASE-}" == <1-> && -n "$name" \
    && "$name" != *[[:cntrl:]]* && "$root" == /* \
    && "$root" == "${root:A}" && -d "$root" && ! -L "$root" ]] || return 1
  zstat -LH info -- "$root" 2>/dev/null \
    && (( info[uid] == EUID && (info[mode] & 8#777) == 8#700 )) || return 1
  local trace_path="" record=$'BEGIN\t'"$kind"$'\t'"$name"$'\n'
  for serial in {1..8}; do
    trace_path="$root/case-$WSP_TRACE_CASE.call-$serial.begin.trace"
    if sysopen -w -o creat,excl,nofollow,cloexec -m 600 -u fd -- "$trace_path" 2>/dev/null; then
      _wsp_trace_base="${trace_path%.begin.trace}"
      syswrite -o "$fd" -c count -- "$record" 2>/dev/null
      local -i rc=$?
      exec {fd}>&-
      (( rc == 0 && count == ${#record} )) || { _wsp_trace_fault=1; return 1; }
      return 0
    fi
    [[ -f "$trace_path" && ! -L "$trace_path" ]] || return 1
  done
  return 1
}

_wsp_trace_event() {
  emulate -L zsh
  unsetopt MULTIBYTE
  local event="$1" detail="${2-}" fd=""
  local -i count=0 rc=0
  [[ -n "$_wsp_trace_base" && "$event" == \
    (fuses|missing-timeout|missing-gtimeout|pair|launch|result|capability) \
    && "$detail" != *$'\n'* && ${#detail} -le 4096 ]] || {
    _wsp_trace_fault=1; return 1
  }
  local record="$event"$'\t'"$detail"$'\n'
  sysopen -w -o creat,excl,nofollow,cloexec -m 600 -u fd \
    -- "$_wsp_trace_base.$event.trace" 2>/dev/null || {
    _wsp_trace_fault=1; return 1
  }
  syswrite -o "$fd" -c count -- "$record" 2>/dev/null || rc=$?
  exec {fd}>&-
  (( rc == 0 && count == ${#record} )) || { _wsp_trace_fault=1; return 1; }
}

WSP_COMMON_PROGRAM
}

ws_portability_capability_program() {
  ws_portability_common_prelude || return 1
  cat <<'WSP_CAPABILITY_PROGRAM'
# Private test-only predicate: 0 AVAILABLE, 1 ABSENT, 2 CHECK_ERROR.
# The real caller loads ws-menu/fetch helpers and starts a trace first.
_wsp_timeout_resolve() {
  builtin whence -p -- "$1" 2>/dev/null
}

_wsp_cap_finish() {
  emulate -L zsh
  local kind="$1" detail="${2-}" header="${3-}"
  local -i rc=2
  case "$kind" in AVAILABLE) rc=0 ;; ABSENT) rc=1 ;; CHECK_ERROR) rc=2 ;; *) return 2 ;; esac
  _wsp_trace_event capability "$kind"$'\t'"$detail"$'\t'"$header"$'\t'"${_wsp_cap_observations-}" || return 2
  print -r -- "$kind"$'\t'"$detail"
  return "$rc"
}

_wsp_gnu_capability() {
  emulate -L zsh
  unsetopt MULTIBYTE
  local token="" found="" program="" version="" header="" REPLY=""
  local _wsp_cap_observations=""
  local -i resolve_rc=0 probe_rc=0
  (( ${+functions[_zdx_timeout_watchdog]} )) || {
    _wsp_cap_finish CHECK_ERROR missing-core-watchdog; return $?
  }
  for token in timeout gtimeout; do
    resolve_rc=0
    found=$(_wsp_timeout_resolve "$token") || resolve_rc=$?
    if (( resolve_rc == 1 )); then
      _wsp_cap_observations+="$token=missing;"
      continue
    fi
    if (( resolve_rc != 0 )) || [[ "$found" != /* || "$found" == *[[:cntrl:]]* ]]; then
      _wsp_cap_finish CHECK_ERROR discovery; return $?
    fi
    _ws_fetch_native_path "$token" || {
      _wsp_cap_observations+="$token=qualification-rejected;"
      _wsp_cap_finish CHECK_ERROR native-qualification; return $?
    }
    program="$REPLY"
    if [[ "$program" != /* || "$program" != "${found:A}" ]]; then
      _wsp_cap_finish CHECK_ERROR changed-qualified-path; return $?
    fi
    _wsp_cap_observations+="$token:path=$program;"
    probe_rc=0
    version=$(_zdx_timeout_watchdog 2 "$program" --version </dev/null 2>/dev/null) || probe_rc=$?
    _wsp_cap_observations+="status=$probe_rc,bytes=${#version};"
    if (( probe_rc != 0 )); then
      _wsp_cap_finish CHECK_ERROR "version-status-$probe_rc"; return $?
    fi
    if (( ${#version} == 0 || ${#version} > 4096 )); then
      _wsp_cap_finish CHECK_ERROR version-size; return $?
    fi
    header="${version%%$'\n'*}"
    if [[ -z "$header" || "$header" == *[[:cntrl:]]* ]]; then
      _wsp_cap_finish CHECK_ERROR version-header; return $?
    fi
    if [[ "$header" == (timeout|gtimeout)' (GNU coreutils) '* ]]; then
      _wsp_cap_finish AVAILABLE "$program" "$header"; return $?
    fi
    # Only an observed version-shaped non-GNU response is definite absence.
    if [[ "$header" != (timeout|gtimeout)' ('*') '?* ]]; then
      _wsp_cap_finish CHECK_ERROR malformed-non-GNU-header; return $?
    fi
    _wsp_cap_observations+="non-GNU=${header[1,256]};"
  done
  _wsp_cap_finish ABSENT no-qualified-native-GNU
}

_wsp_trace_begin capability || exit 98
_wsp_gnu_capability

_wsp_program_status=$?
_wsp_trace_event result "$_wsp_program_status" || exit 98
(( _wsp_trace_fault == 0 )) || exit 98
exit "$_wsp_program_status"
WSP_CAPABILITY_PROGRAM
}

require_ws_fetch_gnu() {
  local program=""
  program=$(ws_portability_capability_program) || return 1
  run run_zsh "$program"
  local check_status="$status" check_output="$output"
  case "$check_status" in
    0)
      [[ "$check_output" == AVAILABLE$'\t'/* ]] || {
        printf 'GNU capability observation malformed: %s\n' "$check_output" >&2
        return 1
      }
      ;;
    1)
      [[ "$check_output" == ABSENT$'\t'no-qualified-native-GNU ]] || {
        printf 'GNU absence observation malformed: %s\n' "$check_output" >&2
        return 1
      }
      skip "requires qualified native GNU timeout/gtimeout for real fetch coverage"
      ;;
    *)
      printf 'GNU capability CHECK ERROR (status %s): %s\n' "$check_status" "$check_output" >&2
      return 1
      ;;
  esac
}

ws_status_no_gnu_prelude() {
  ws_portability_common_prelude || return 1
  cat <<'WSP_NO_GNU_PROGRAM'
_wsp_trace_begin "${WSP_TRACE_KIND:-absence}" || exit 98
functions[_wsp_original_native_path]="${functions[_ws_fetch_native_path]}"
_ws_fetch_native_path() {
  case "${1-}" in
    timeout|gtimeout)
      _wsp_trace_event "missing-$1" refused || return 1
      return 1 ;;
    *) _wsp_original_native_path "$@" ;;
  esac
}
_ws_fetch_pair() {
  _wsp_trace_event pair unexpected || :
  return 1
}
_ws_fetch_launch() {
  _wsp_trace_event launch unexpected || :
  return 1
}
_wsp_trace_event fuses installed || exit 98
WSP_NO_GNU_PROGRAM
}

run_ws_status_without_gnu() {
  local body="$1" prelude="" postlude=""
  prelude=$(ws_status_no_gnu_prelude) || return 98
  postlude=$(cat <<'WSP_POSTLUDE'

_wsp_program_status=$?
_wsp_trace_event result "$_wsp_program_status" || exit 98
(( _wsp_trace_fault == 0 )) || exit 98
exit "$_wsp_program_status"
WSP_POSTLUDE
  ) || return 98
  run_zsh "$prelude
$body
$postlude"
}

@test "ws status: fetch without GNU refuses before any owner or job" {
  install_fetch_mock
  export WSP_TRACE_KIND=absence
  run run_ws_status_without_gnu 'ws-status --fetch --json >"$HOME/no-gnu.data" 2>"$HOME/no-gnu.ui"'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ ! -s "$HOME/no-gnu.data" ]
  grep -Fq 'Safe --fetch requires GNU timeout or gtimeout; install coreutils and retry.' "$HOME/no-gnu.ui"
  ! grep -Eq 'Fetching |Fetched ' "$HOME/no-gnu.ui" || false
  ! grep -q '^fetch|' "$MOCK_GIT_LOG" || false
  local leftovers=("$TMPDIR"/zdx-ws-fetch.*)
  [ ! -e "${leftovers[0]}" ]
  local begins=("$WSP_TRACE_ROOT"/case-"$BATS_TEST_NUMBER".call-*.begin.trace)
  [ "${#begins[@]}" -eq 1 ]
  [ -f "${begins[0]}" ]
  local prefix="${begins[0]%.begin.trace}"
  [ "$(cat "$prefix.fuses.trace")" = $'fuses\tinstalled' ]
  [ "$(cat "$prefix.missing-timeout.trace")" = $'missing-timeout\trefused' ]
  [ "$(cat "$prefix.missing-gtimeout.trace")" = $'missing-gtimeout\trefused' ]
  [ ! -e "$prefix.pair.trace" ]
  [ ! -e "$prefix.launch.trace" ]
  [ "$(cat "$prefix.result.trace")" = $'result\t1' ]
}
