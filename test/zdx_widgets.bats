#!/usr/bin/env bats
# ZLE insert widgets: candidate sources, the shared picker, quoting into
# LBUFFER, cancellation, missing tools, lazy loading, and the unbound-only
# key binding rule. Widget bodies run outside ZLE with `zle` replaced by a
# recorder; LBUFFER is then an ordinary parameter.
# shellcheck disable=SC2016

setup() {
  load test_helper
  export WIDGET_ROOT="$TEST_SUITE_ROOT"
  export WIDGET_ZLE_LOG="$TEST_TEMP_DIR/zle.log"
  export WIDGET_FZF_ARGS="$TEST_TEMP_DIR/fzf.args"
  export WIDGET_FZF_INPUT="$TEST_TEMP_DIR/fzf.input"
  export WIDGET_PROBE_LOG="$TEST_TEMP_DIR/probes"
  export GIT_CEILING_DIRECTORIES="$TEST_TEMP_DIR"
  : > "$WIDGET_ZLE_LOG"
  : > "$WIDGET_FZF_ARGS"
  : > "$WIDGET_FZF_INPUT"
  : > "$WIDGET_PROBE_LOG"
  WIDGET_REAL_JQ=$(command -v jq || true)
  export WIDGET_REAL_JQ

  # Selects the first row containing WIDGET_FZF_MATCH and, like fzf, prints
  # the --expect key line (empty for Enter) before the row.
  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$WIDGET_FZF_ARGS"
printf 'FZF_DEFAULT_OPTS=%s\n' "${FZF_DEFAULT_OPTS-}" >> "$WIDGET_FZF_ARGS"
cat > "$WIDGET_FZF_INPUT"
case "${WIDGET_FZF_MODE:-select}" in
  cancel) exit 130 ;;
  fail) exit 2 ;;
  forged) printf '%s\n' "$WIDGET_FZF_FORGED"; exit 0 ;;
esac
expect=0
for argument in "$@"; do
  [[ "$argument" == --expect=* ]] && expect=1
done
row=$(awk -v needle="${WIDGET_FZF_MATCH:-}" \
  'index($0, needle) { print; exit }' "$WIDGET_FZF_INPUT")
[[ -n "$row" ]] || exit 1
(( expect )) && printf '%s\n' "${WIDGET_FZF_KEY:-}"
printf '%s\n' "$row"
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"
}

teardown() {
  cleanup_sandbox
}

# Runs the program given first from the directory given second, with the
# core loaded and `zle` recorded. Inside the program that directory is $1,
# and further arguments are $2 and later.
widget_zsh() {
  local program="$1"
  shift
  zsh -f -c '
    source "$WIDGET_ROOT/functions.zsh" || exit 90
    cd "$1" || exit 91
    zle() { print -r -- "zle $*" >> "$WIDGET_ZLE_LOG"; }
    '"$program"'
  ' zdx-widget-test "$@"
}

# A PATH directory holding only the named commands: mocks from TEST_MOCK_BIN
# win over host tools of the same name.
limited_path() {
  local directory="$TEST_TEMP_DIR/limited-bin" tool="" source_path=""
  mkdir -p "$directory"
  for tool in "$@"; do
    if [[ -x "$TEST_MOCK_BIN/$tool" ]]; then
      source_path="$TEST_MOCK_BIN/$tool"
    else
      source_path=$(command -v "$tool") || continue
    fi
    ln -sf "$source_path" "$directory/$tool"
  done
  printf '%s\n' "$directory"
}

make_branch_repo() {
  local remote="$TEST_TEMP_DIR/remote.git" seed="$TEST_TEMP_DIR/seed"
  git init -q --bare -b main "$remote"
  git init -q -b main "$seed"
  git -C "$seed" config user.email "jane@example.com"
  git -C "$seed" config user.name "Jane Doe"
  printf 'one\n' > "$seed/file.txt"
  git -C "$seed" add file.txt
  git -C "$seed" commit -q -m one
  git -C "$seed" push -q "$remote" main 2>/dev/null
  git clone -q "$remote" "$1" 2>/dev/null
  git -C "$1" config user.email "jane@example.com"
  git -C "$1" config user.name "Jane Doe"
}

@test "widgets: the module loads silently, idempotently, and only edits LBUFFER" {
  run zsh -f -c '
    source "$1/functions/zdx-widgets.zsh" || exit
    first_definition="${functions[_zdx_widget_insert]}"
    source "$1/functions/zdx-widgets.zsh" || exit
    [[ -n "${_ZDX_WIDGETS_SOURCED:-}" \
      && "${functions[_zdx_widget_insert]}" == "$first_definition" ]]
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  local module="$TEST_SUITE_ROOT/functions/zdx-widgets.zsh"
  [ "$(awk 'NF { line=$0 } END { print line }' "$module")" \
    = "typeset -g _ZDX_WIDGETS_SOURCED=1" ]
  run grep -Eq '(^|[[:space:]])eval([[:space:]]|$)|accept-line|(^|[^L])BUFFER=|-common[.]zsh' \
    "$module"
  [ "$status" -eq 1 ]
  [ "$(grep -v '^[[:space:]]*#' "$module" | grep -c 'LBUFFER')" -eq 1 ]
  grep -Fq 'LBUFFER+="${(q)value}"' "$module"
}

@test "widgets: branch inserts a quoted hostile name and lists locals before remotes" {
  local repo="$TEST_TEMP_DIR/repo"
  local hostile='feat/$(>pwned);"q'"'"'s|`id`'
  make_branch_repo "$repo"
  git -C "$repo" branch "$hostile"
  git -C "$repo" branch topic

  export WIDGET_FZF_MATCH='pwned'
  run widget_zsh '
    LBUFFER="git switch "
    _zdx_widget_insert branch || exit
    print -r -- "LBUFFER=$LBUFFER"
    [[ "$LBUFFER" == "git switch ${(q)2}" \
      && "${(Q)LBUFFER#git switch }" == "$2" ]]
  ' "$repo" "$hostile"
  [ "$status" -eq 0 ]
  [ ! -e "$repo/pwned" ]
  grep -Fxq 'zle reset-prompt' "$WIDGET_ZLE_LOG"
  run grep -c 'zle -M' "$WIDGET_ZLE_LOG"
  [ "$output" -eq 0 ]

  # Locals come first, the current branch is marked, origin/HEAD is skipped.
  run awk -F '\t' '{ print $2 }' "$WIDGET_FZF_INPUT"
  [[ "$output" == *"local  * main"* ]]
  [[ "$output" == *"remote   origin/main"* ]]
  [[ "$output" != *"origin/HEAD"* && "$output" != *$'\n'"remote   origin"$'\n'* ]]
  [ "$(awk -F '\t' '/^[0-9]+\tremote/ { print NR; exit }' "$WIDGET_FZF_INPUT")" -gt \
    "$(awk -F '\t' '/^[0-9]+\tlocal/ { line=NR } END { print line }' "$WIDGET_FZF_INPUT")" ]
  grep -Fxq -- '--height=40%' "$WIDGET_FZF_ARGS"
  grep -Fxq -- '--prompt=branch > ' "$WIDGET_FZF_ARGS"
  grep -Fxq 'FZF_DEFAULT_OPTS=' "$WIDGET_FZF_ARGS"
}

@test "widgets: Esc, no match, a failed picker, and a forged row leave the buffer untouched" {
  local repo="$TEST_TEMP_DIR/repo"
  make_branch_repo "$repo"

  local mode
  for mode in cancel nomatch fail; do
    : > "$WIDGET_ZLE_LOG"
    export WIDGET_FZF_MODE=select WIDGET_FZF_MATCH='no such branch'
    [[ "$mode" == nomatch ]] || export WIDGET_FZF_MODE="$mode"
    run widget_zsh '
      LBUFFER="git switch "
      _zdx_widget_insert branch
      rc=$?
      print -r -- "rc=$rc LBUFFER=[$LBUFFER]"
    ' "$repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LBUFFER=[git switch ]"* ]]
    grep -Fxq 'zle reset-prompt' "$WIDGET_ZLE_LOG"
    if [[ "$mode" == fail ]]; then
      [[ "$output" == *"rc=1"* ]]
      grep -Fq 'zle -M zdx: fzf failed (status 2)' "$WIDGET_ZLE_LOG"
    else
      [[ "$output" == *"rc=0"* ]]
      run grep -c 'zle -M' "$WIDGET_ZLE_LOG"
      [ "$output" -eq 0 ]
    fi
  done

  local forged
  for forged in $'1\tlocal    forged' $'1+1\tlocal' $'a[$(>evaluated)]\tlocal' $'9\tlocal'; do
    : > "$WIDGET_ZLE_LOG"
    export WIDGET_FZF_MODE=forged WIDGET_FZF_FORGED="$forged"
    run widget_zsh '
      LBUFFER="git switch "
      _zdx_widget_insert branch
      print -r -- "rc=$? LBUFFER=[$LBUFFER]"
    ' "$repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=1 LBUFFER=[git switch ]"* ]]
    grep -Fq 'not in the picker snapshot' "$WIDGET_ZLE_LOG"
  done
  [ ! -e "$repo/evaluated" ]
}

@test "widgets: a missing tool or repository shows one message without opening fzf" {
  mkdir -p "$TEST_TEMP_DIR/plain"
  run widget_zsh '
    LBUFFER="git switch "
    _zdx_widget_insert branch
    print -r -- "rc=$? LBUFFER=[$LBUFFER]"
  ' "$TEST_TEMP_DIR/plain"
  [[ "$output" == *"rc=1 LBUFFER=[git switch ]"* ]]
  grep -Fxq 'zle -M zdx: not inside a Git repository' "$WIDGET_ZLE_LOG"
  [ ! -s "$WIDGET_FZF_ARGS" ]

  local only_git
  only_git=$(limited_path git timeout gtimeout)
  : > "$WIDGET_ZLE_LOG"
  run widget_zsh '
    path=("$2")
    _zdx_widget_insert branch
    print -r -- "rc=$?"
  ' "$TEST_TEMP_DIR/plain" "$only_git"
  [[ "$output" == *"rc=1"* ]]
  grep -Fxq 'zle -M zdx: fzf is required for insert pickers' "$WIDGET_ZLE_LOG"

  local no_gh
  no_gh=$(limited_path fzf)
  : > "$WIDGET_ZLE_LOG"
  run widget_zsh '
    path=("$2")
    _zdx_widget_insert pr
  ' "$TEST_TEMP_DIR/plain" "$no_gh"
  [ "$status" -eq 1 ]
  grep -Fq 'zle -M zdx: gh is not installed' "$WIDGET_ZLE_LOG"
  [ "$(wc -l < "$WIDGET_ZLE_LOG")" -eq 1 ]

  run widget_zsh '_zdx_widget_insert unknown' "$TEST_TEMP_DIR/plain"
  [ "$status" -eq 1 ]
  grep -Fq 'zle -M zdx: unknown insert picker' "$WIDGET_ZLE_LOG"
  [ ! -s "$WIDGET_FZF_ARGS" ]
}

@test "widgets: pr inserts the number from gh and reports missing authentication" {
  [ -n "$WIDGET_REAL_JQ" ] || skip "jq is not installed"
  cat > "$TEST_MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s|%s\n' "$*" "${GH_PROMPT_DISABLED-}" >> "$WIDGET_PROBE_LOG"
case "${WIDGET_GH_MODE:-ok}" in
  auth) exit 4 ;;
  fail) exit 1 ;;
esac
printf '%s\n' '[{"number":42,"title":"Fix\tit $(>pwned)\nnow","headRefName":"fix/it"},{"number":7,"title":"Docs","headRefName":"docs"}]'
EOF
  chmod +x "$TEST_MOCK_BIN/gh"
  mkdir -p "$TEST_TEMP_DIR/plain"

  export WIDGET_FZF_MATCH='#42'
  run widget_zsh '
    LBUFFER="gh pr checkout "
    _zdx_widget_insert pr || exit
    print -r -- "LBUFFER=[$LBUFFER]"
  ' "$TEST_TEMP_DIR/plain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LBUFFER=[gh pr checkout 42]"* ]]
  grep -Fxq 'gh pr list --state open --limit 200 --json number,title,headRefName|1' \
    "$WIDGET_PROBE_LOG"
  grep -Fq 'zle -R zdx: loading open pull requests...' "$WIDGET_ZLE_LOG"
  [ "$(wc -l < "$WIDGET_FZF_INPUT")" -eq 2 ]
  grep -Fq '#42  fix/it  Fix\tit $(>pwned)\nnow' "$WIDGET_FZF_INPUT"
  [ ! -e "$TEST_TEMP_DIR/plain/pwned" ]

  local mode expected
  for mode in auth fail; do
    : > "$WIDGET_ZLE_LOG"
    : > "$WIDGET_FZF_ARGS"
    export WIDGET_GH_MODE="$mode"
    run widget_zsh '
      LBUFFER="gh pr checkout "
      _zdx_widget_insert pr
      print -r -- "rc=$? LBUFFER=[$LBUFFER]"
    ' "$TEST_TEMP_DIR/plain"
    [[ "$output" == *"rc=1 LBUFFER=[gh pr checkout ]"* ]]
    expected='gh is not authenticated; run gh auth login'
    [[ "$mode" == fail ]] && expected='gh pr list failed (status 1)'
    grep -Fq "zle -M zdx: $expected" "$WIDGET_ZLE_LOG"
    [ ! -s "$WIDGET_FZF_ARGS" ]
  done
}

@test "widgets: port inserts the PID on Enter and the port on Ctrl-O through ss" {
  cat > "$TEST_MOCK_BIN/ss" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-l -t -n -p" ]] || exit 9
cat <<'ROWS'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:5432     0.0.0.0:*         users:(("postgres",pid=4242,fd=5))
LISTEN 0      4096   [::1]:5432         [::]:*            users:(("postgres",pid=4242,fd=6))
LISTEN 0      128    0.0.0.0:22         0.0.0.0:*
LISTEN 0      511    *:8080             *:*               users:(("node",pid=777,fd=20),("node",pid=778,fd=20))
ROWS
EOF
  chmod +x "$TEST_MOCK_BIN/ss"
  mkdir -p "$TEST_TEMP_DIR/plain"

  export WIDGET_FZF_MATCH=':5432'
  run widget_zsh '
    OSTYPE=linux-gnu
    LBUFFER="kill "
    _zdx_widget_insert port || exit
    print -r -- "LBUFFER=[$LBUFFER]"
  ' "$TEST_TEMP_DIR/plain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LBUFFER=[kill 4242]"* ]]
  grep -Fxq -- '--expect=ctrl-o' "$WIDGET_FZF_ARGS"
  grep -Fxq -- '--header=Enter insert PID | Ctrl-O insert port | Esc cancel' \
    "$WIDGET_FZF_ARGS"
  run awk -F '\t' '{ print $2 }' "$WIDGET_FZF_INPUT"
  [ "${lines[0]}" = ":22  (process not visible)  0.0.0.0:22" ]
  [ "${lines[1]}" = ":5432  postgres  pid 4242  127.0.0.1:5432" ]
  [ "${lines[2]}" = ":8080  node  pid 777  *:8080" ]
  [ "${#lines[@]}" -eq 3 ]

  export WIDGET_FZF_MATCH=':8080' WIDGET_FZF_KEY=ctrl-o
  run widget_zsh '
    OSTYPE=linux-gnu
    LBUFFER="curl localhost:"
    _zdx_widget_insert port || exit
    print -r -- "LBUFFER=[$LBUFFER]"
  ' "$TEST_TEMP_DIR/plain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LBUFFER=[curl localhost:8080]"* ]]

  export WIDGET_FZF_MATCH=':22' WIDGET_FZF_KEY=
  : > "$WIDGET_ZLE_LOG"
  run widget_zsh '
    OSTYPE=linux-gnu
    LBUFFER="kill "
    _zdx_widget_insert port
    print -r -- "rc=$? LBUFFER=[$LBUFFER]"
  ' "$TEST_TEMP_DIR/plain"
  [[ "$output" == *"rc=1 LBUFFER=[kill ]"* ]]
  grep -Fq 'the process on port 22 is not visible; press Ctrl-O to insert the port' \
    "$WIDGET_ZLE_LOG"
}

@test "widgets: port reads lsof field output on macOS" {
  cat > "$TEST_MOCK_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-nP -iTCP -sTCP:LISTEN -Fpcn" ]] || exit 9
printf '%s\n' p501 cnginx f6 'n*:80' f7 'n[::]:80' p88 credis-server f6 \
  n127.0.0.1:6379
EOF
  chmod +x "$TEST_MOCK_BIN/lsof"
  mkdir -p "$TEST_TEMP_DIR/plain"

  export WIDGET_FZF_MATCH=':6379' WIDGET_FZF_KEY=ctrl-o
  run widget_zsh '
    OSTYPE=darwin23
    LBUFFER="redis-cli -p "
    _zdx_widget_insert port || exit
    print -r -- "LBUFFER=[$LBUFFER]"
  ' "$TEST_TEMP_DIR/plain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LBUFFER=[redis-cli -p 6379]"* ]]
  run awk -F '\t' '{ print $2 }' "$WIDGET_FZF_INPUT"
  [ "${lines[0]}" = ":80  nginx  pid 501  *:80" ]
  [ "${lines[1]}" = ":6379  redis-server  pid 88  127.0.0.1:6379" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "widgets: venv lists project ancestors and WORKON_HOME and quotes the path" {
  local project="$TEST_TEMP_DIR/proj 'q' \$(>pwned)"
  local workon="$TEST_TEMP_DIR/workon"
  mkdir -p "$project/.venv" "$project/sub/venv" "$project/sub/deeper" \
    "$workon/env one/bin" "$workon/not-an-env"
  : > "$project/.venv/pyvenv.cfg"
  : > "$project/sub/venv/pyvenv.cfg"
  : > "$workon/env one/bin/activate"

  export WIDGET_FZF_MATCH="/.venv"
  run widget_zsh '
    export WORKON_HOME="$2" VIRTUAL_ENV="$3/sub/venv"
    LBUFFER="source "
    _zdx_widget_insert venv || exit
    print -r -- "LBUFFER=[$LBUFFER]"
    [[ "$LBUFFER" == "source ${(q)${:-$3/.venv}}" \
      && "${(Q)LBUFFER#source }" == "$3/.venv" ]]
  ' "$project/sub/deeper" "$workon" "$project"
  [ "$status" -eq 0 ]
  [ ! -e "$project/sub/deeper/pwned" ]
  run awk -F '\t' '{ print $2 }' "$WIDGET_FZF_INPUT"
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "project $project/sub/venv  (active)" ]]
  [[ "${lines[1]}" == "project $project/.venv" ]]
  [[ "${lines[2]}" == "workon  $workon/env one" ]]

  mkdir -p "$TEST_TEMP_DIR/empty"
  : > "$WIDGET_ZLE_LOG"
  run widget_zsh '
    unset WORKON_HOME
    _zdx_widget_insert venv
  ' "$TEST_TEMP_DIR/empty"
  [ "$status" -eq 1 ]
  grep -Fq 'zle -M zdx: no virtual environment here' "$WIDGET_ZLE_LOG"
}

@test "widgets: probes are bounded and the picker honors plain mode" {
  local repo="$TEST_TEMP_DIR/repo"
  make_branch_repo "$repo"
  cat > "$TEST_MOCK_BIN/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 1 127.0.0.1:631 0.0.0.0:* users:(("cupsd",pid=9,fd=7))\n'
EOF
  chmod +x "$TEST_MOCK_BIN/ss"

  export WIDGET_FZF_MATCH=':631'
  run widget_zsh '
    _zdx_run_with_timeout() {
      print -r -- "$1 $2" >> "$WIDGET_PROBE_LOG"
      shift
      "$@"
    }
    OSTYPE=linux-gnu
    NO_COLOR=1
    _zdx_widget_insert port || exit 1
    WIDGET_FZF_MATCH=main _zdx_widget_insert branch || exit 2
    print -r -- "LBUFFER=[$LBUFFER]"
  ' "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LBUFFER=[9main]"* ]]
  grep -Fxq '5 ss' "$WIDGET_PROBE_LOG"
  grep -Fxq '5 git' "$WIDGET_PROBE_LOG"
  grep -Fxq -- '--no-color' "$WIDGET_FZF_ARGS"
  [ ! -s "$MOCK_SUDO_LOG" ]
}

@test "widgets: chords bind only while unbound and follow the override variables" {
  run zsh -f -i -c '
    bindkey -M main "^Xp" backward-word
    export ZDX_KEY_INSERT_PORT="^[o"
    export ZDX_KEY_INSERT_VENV=""
    source "$1/zdx-suite.plugin.zsh" || exit 90
    local chord=""
    for chord in "^Xb" "^Xp" "^Xo" "^[o" "^Xv"; do
      print -r -- "binding:$(bindkey -M main -- "$chord")"
    done
    print -r -- "venv-widget:${widgets[zdx-insert-venv]-missing}"
    print -r -- "pr-widget:${widgets[zdx-insert-pr]-missing}"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'binding:"^Xb" zdx-insert-branch'* ]]
  [[ "$output" == *'binding:"^Xp" backward-word'* ]]
  [[ "$output" == *'binding:"^Xo" undefined-key'* ]]
  [[ "$output" == *'binding:"^[o" zdx-insert-port'* ]]
  [[ "$output" == *'binding:"^Xv" undefined-key'* ]]
  [[ "$output" == *"venv-widget:user:_zdx_insert_venv_widget"* ]]
  [[ "$output" == *"pr-widget:user:_zdx_insert_pr_widget"* ]]

  run zsh -f -i -c '
    export ZDX_KEYBINDINGS=0
    source "$1/zdx-suite.plugin.zsh" || exit 90
    print -r -- "branch-widget:${widgets[zdx-insert-branch]-missing}"
    print -r -- "binding:$(bindkey -M main -- "^Xb")"
    print -r -- "git-widget:${widgets[git-menu-widget]-missing}"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch-widget:missing"* ]]
  [[ "$output" == *'binding:"^Xb" undefined-key'* ]]
  [[ "$output" == *"git-widget:missing"* ]]

  run zsh -f -c '
    source "$1/zdx-suite.plugin.zsh" || exit 90
    (( ! ${+functions[_zdx_insert_widget]} ))
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "widgets: lazy mode loads the widget module only on first use" {
  local project="$TEST_TEMP_DIR/project"
  mkdir -p "$project/.venv"
  : > "$project/.venv/pyvenv.cfg"

  export WIDGET_FZF_MATCH=.venv
  run zsh -f -i -c '
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME
    source "$1/zdx-suite.plugin.zsh" || exit 90
    (( ! ${+functions[_zdx_widget_insert]} )) || exit 1
    (( ${+functions[_zdx_insert_venv_widget]} )) || exit 2
    zle() { print -r -- "zle $*" >> "$WIDGET_ZLE_LOG"; }
    cd "$2" || exit 3
    LBUFFER="source "
    _zdx_insert_venv_widget || exit 4
    (( ${+functions[_zdx_widget_insert]} )) || exit 5
    print -r -- "LBUFFER=[$LBUFFER]"
  ' _ "$TEST_SUITE_ROOT" "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LBUFFER=[source $project/.venv]"* ]]
}
