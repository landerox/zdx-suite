#!/usr/bin/env bats
# ZLE insert widgets: candidate sources, the shared picker, quoting into
# LBUFFER, cancellation, missing tools, lazy loading, and the unbound-only
# key binding rule. Widget bodies run outside ZLE with `zle` replaced by a
# recorder; LBUFFER is then an ordinary parameter. The Ctrl-G cases press
# the chord in a real ZLE on a pseudo-terminal.
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
    emulate -R zsh
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

# widget_pty WAIT SEND...: an interactive `zsh -f -i` on a pseudo-terminal
# loads the plugin with git-menu replaced by a probe, then takes each WAIT
# SEND pair in turn: once the output since the previous pair matches the
# pattern WAIT, it types SEND. The probe records whether its standard input
# and error are terminals, asks one line confirmation, and asks one vared
# text prompt prefilled with a subject, like the amend prompt. Every
# confirmation is answered y and every probe text prompt Z, each followed by
# Enter (a CR), as a user does. ^Xm opens a read-from-minibuffer prompt.
# Prints the pairs completed, then each record the shell printed, in order.
widget_pty() {
  local setup_file="$TEST_TEMP_DIR/pty-setup.zsh"
  cat > "$setup_file" <<'SETUP'
emulate -R zsh
unset -m 'ZDX_*'
bindkey -e
setopt hist_ignore_space
PS1='ZDXREADY> '
source "$WIDGET_ROOT/zdx-suite.plugin.zsh" || print -r -- "setup: the plugin failed to load"
_probe_error() { print -u2 -r -- "probe: $*"; }
git-menu() {
  local stdin_state=NOT stderr_state=NOT text="the prefilled subject line"
  local -i confirm_rc=0 vared_rc=0
  [[ -t 0 ]] && stdin_state=TTY
  [[ -t 2 ]] && stderr_state=TTY
  _zdx_confirm_prompt --style line --error _probe_error -- "Proceed?" \
    || confirm_rc=$?
  print -r -- "ASK-TEXT"
  vared -p "Text: " text || vared_rc=$?
  print -r -- "RESULT-${1-}:stdin=${stdin_state}:stderr=${stderr_state}:confirm=${confirm_rc}:VARED=${vared_rc}:${text}:END"
}
probe_kept() { print -r -- "KEPT:$*"; }
probe_history() { print -r -- "HISTORY=${#${(@M)${(@v)history}:#( |)git-menu}}"; }
probe_vared() { local value=""; vared -p "Value: " value; print -r -- "VALUE=[${value}]"; }
autoload -Uz read-from-minibuffer
probe_minibuffer() { read-from-minibuffer 'Mini: '; zle -M "MINI=[$REPLY]"; }
zle -N probe_minibuffer
bindkey '^Xm' probe_minibuffer
print -r -- "binding:$(bindkey -M main -- '^G')"
SETUP
  WIDGET_PTY_SETUP="$setup_file" zsh -f -c '
    emulate -R zsh
    zmodload zsh/zpty || exit 80
    zmodload zsh/datetime || exit 79
    local enter="${(#):-13}" out="" chunk=""
    local records="(binding:\"[^\"]*\" [a-z-]+|RESULT-[a-z]*:stdin=[A-Z]+:stderr=[A-Z]+:confirm=[0-9]+:VARED=[0-9]+:[A-Za-z ]*:END|KEPT:[a-z ]+|HISTORY=[0-9]+|VALUE=\[[^]]*]|LOOP-[0-9]+|MINI=\[[^]]*])"
    local -i pairs=$(( $# / 2 )) completed=0 mark=1 confirm_mark=1 text_mark=1
    zpty ZDXPTY env -u TEST_TEMP_DIR -u BATS_TEST_DIRNAME -u EDITOR -u VISUAL \
      TERM=xterm LC_ALL=C NO_COLOR=1 zsh -f -i || exit 81
    {
      zpty -w ZDXPTY "source \"\$WIDGET_PTY_SETUP\""
      # A wall-clock bound sized for slow hosted runners; the loop ends as
      # soon as the last pair has been typed.
      local -F deadline=$(( EPOCHREALTIME + 30 ))
      while (( completed < pairs && EPOCHREALTIME < deadline )); do
        if zpty -r -t ZDXPTY chunk 2>/dev/null; then
          out+="$chunk"
        else
          command sleep 0.01
        fi
        # Each prompt is answered once, after it appears.
        if [[ "${out[confirm_mark,-1]}" == *"[y/N]"* ]]; then
          zpty -n -w ZDXPTY "y$enter"
          confirm_mark=$(( ${#out} + 1 ))
        fi
        if [[ "${out[text_mark,-1]}" == *ASK-TEXT*"Text: "* ]]; then
          zpty -n -w ZDXPTY "Z$enter"
          text_mark=$(( ${#out} + 1 ))
        fi
        [[ "${out[mark,-1]}" == ${~1} ]] || continue
        [[ -n "$2" ]] && zpty -n -w ZDXPTY "$2"
        shift 2
        (( ++completed ))
        mark=$(( ${#out} + 1 ))
      done
    } always {
      zpty -d ZDXPTY 2>/dev/null
    }
    print -r -- "pairs=$completed/$pairs"
    local rest="$out"
    while [[ "$rest" =~ $records ]]; do
      print -r -- "$MATCH"
      rest="${rest[MEND+1,-1]}"
    done
    (( completed == pairs )) || print -r -- "transcript: ${(V)out[-800,-1]}"
    return 0
  ' _ "$@"
}

@test "widgets: the module loads silently, idempotently, and only edits LBUFFER" {
  run zsh -f -c '
    emulate -R zsh
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
  run -1 grep -c 'zle -M' "$WIDGET_ZLE_LOG"
  [ "$output" -eq 0 ]

  # Locals come first, the current branch is marked, origin/HEAD is skipped.
  run -0 awk -F '\t' '{ print $2 }' "$WIDGET_FZF_INPUT"
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
      run -1 grep -c 'zle -M' "$WIDGET_ZLE_LOG"
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
  run -0 widget_zsh '
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
  run -0 widget_zsh '
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
    run -0 widget_zsh '
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
  run -0 awk -F '\t' '{ print $2 }' "$WIDGET_FZF_INPUT"
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
  run -0 widget_zsh '
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
  run -0 awk -F '\t' '{ print $2 }' "$WIDGET_FZF_INPUT"
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
  run -0 awk -F '\t' '{ print $2 }' "$WIDGET_FZF_INPUT"
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

# The plugin binds its chords only in an interactive shell ([[ -o interactive ]]),
# so the binding tests start `zsh -f -i`; -f skips every startup file but the
# system zshenv.
@test "widgets: chords bind only while unbound and follow the override variables" {
  run zsh -f -i -c '
    emulate -R zsh
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
    emulate -R zsh
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
    emulate -R zsh
    source "$1/zdx-suite.plugin.zsh" || exit 90
    (( ! ${+functions[_zdx_insert_widget]} ))
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
}

@test "widgets: ZDX_KEY_GIT moves the git-menu chord and an empty value unbinds it" {
  run zsh -f -i -c '
    emulate -R zsh
    source "$1/zdx-suite.plugin.zsh" || exit 90
    print -r -- "default:$(bindkey -M main -- "^G")"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'default:"^G" git-menu-widget'* ]]

  run zsh -f -i -c '
    emulate -R zsh
    export ZDX_KEY_GIT="^[g"
    source "$1/zdx-suite.plugin.zsh" || exit 90
    print -r -- "moved:$(bindkey -M main -- "^[g")"
    print -r -- "previous:$(bindkey -M main -- "^G")"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'moved:"^[g" git-menu-widget'* ]]
  [[ "$output" != *'previous:"^G" git-menu-widget'* ]]

  run zsh -f -i -c '
    emulate -R zsh
    export ZDX_KEY_GIT=""
    source "$1/zdx-suite.plugin.zsh" || exit 90
    print -r -- "empty:$(bindkey -M main -- "^G")"
    print -r -- "git-widget:${widgets[git-menu-widget]-missing}"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *'empty:"^G" git-menu-widget'* ]]
  [[ "$output" == *"git-widget:user:_zdx_git_menu_widget"* ]]
}

@test "widgets: Ctrl-G runs git-menu as a command line that can prompt and restores the edited line" {
  # ZLE runs a widget with standard input from /dev/null and cannot reenter
  # itself for vared, so the chord must run git-menu as a typed command. The
  # direct call is the control. Then the chord on a half-typed line shorter
  # than the prefilled answer, and on an empty line: each time the probe must
  # see the terminal and get both answers with Z appended at the end of the
  # prefill, the half-typed line must come back and run, and
  # HIST_IGNORE_SPACE must drop both calls.
  local answered="confirm=0:VARED=0:the prefilled subject lineZ:END"
  run widget_pty \
    '*binding:*ZDXREADY> *' $'git-menu direct\r' \
    '*RESULT-direct:*:END*ZDXREADY> *' $'probe_kept one two\a' \
    '*RESULT-:*:END*ZDXREADY> *' $'\r' \
    '*KEPT:*ZDXREADY> *' $'\a' \
    '*RESULT-:*:END*ZDXREADY> *' $'probe_history\r' \
    '*HISTORY=*ZDXREADY> *' ''
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'binding:"^G" git-menu-widget' ]
  [ "${lines[2]}" = "RESULT-direct:stdin=TTY:stderr=TTY:$answered" ]
  [ "${lines[3]}" = "RESULT-:stdin=TTY:stderr=TTY:$answered" ]
  [ "${lines[4]}" = "KEPT:one two" ]
  [ "${lines[5]}" = "RESULT-:stdin=TTY:stderr=TTY:$answered" ]
  [ "${lines[6]}" = "HISTORY=0" ]
  [ "${lines[0]}" = "pairs=6/6" ]
  [ "${#lines[@]}" -eq 7 ]
}

@test "widgets: Ctrl-G does nothing in vared, a continuation line, or a recursive edit" {
  # There accept-line would hand ' git-menu' to that read instead of running
  # the menu, so the chord must do nothing, and the text typed next must reach
  # the same read. No probe record may appear.
  run widget_pty \
    '*binding:*ZDXREADY> *' $'probe_vared\r' \
    '*Value: *' $'\aok\r' \
    '*VALUE=*ZDXREADY> *' $'for i in 1; do\r' \
    '*for> *' $'\aprint -r -- LOOP-$i; done\r' \
    '*LOOP-1*ZDXREADY> *' $'\x18m' \
    '*Mini: *' $'\aok\r' \
    '*MINI=*' ''
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = 'binding:"^G" git-menu-widget' ]
  [ "${lines[2]}" = "VALUE=[ok]" ]
  [ "${lines[3]}" = "LOOP-1" ]
  [ "${lines[4]}" = "MINI=[ok]" ]
  [ "${lines[0]}" = "pairs=7/7" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "widgets: lazy mode loads the widget module only on first use" {
  local project="$TEST_TEMP_DIR/project"
  mkdir -p "$project/.venv"
  : > "$project/.venv/pyvenv.cfg"

  export WIDGET_FZF_MATCH=.venv
  run zsh -f -i -c '
    emulate -R zsh
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

# The actual collectors parse mock gh/ss output. A successful populated result
# proves that each regex branch ran before caller-state preservation is checked.
f304_module_widget_state() {
  export F304_WIDGET_KIND="$1" F304_WIDGET_STATE="$2"
  case "$F304_WIDGET_KIND" in
    pr)
      [ -n "$WIDGET_REAL_JQ" ] || skip "jq is not installed"
      cat > "$TEST_MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == 'pr list --state open --limit 200 --json number,title,headRefName' ]] || exit 97
printf 'pr fixture\n' >> "$WIDGET_PROBE_LOG"
printf '%s\n' '[{"number":42,"title":"Fixture title","headRefName":"feature/fixture"}]'
MOCK
      chmod -- 755 "$TEST_MOCK_BIN/gh"
      ;;
    ss)
      cat > "$TEST_MOCK_BIN/ss" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == '-l -t -n -p' ]] || exit 97
printf 'ss fixture\n' >> "$WIDGET_PROBE_LOG"
printf '%s\n' 'LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:(("fixture",pid=777,fd=5))'
MOCK
      chmod -- 755 "$TEST_MOCK_BIN/ss"
      ;;
    *) return 98 ;;
  esac
  run widget_zsh '
    source "$WIDGET_ROOT/functions/zdx-widgets.zsh" || exit 80
    local -a widget_values=() widget_alternates=() widget_labels=()
    if [[ "$F304_WIDGET_STATE" == seeded ]]; then
      MATCH=caller MBEGIN=7 MEND=12
      match=(captured other) mbegin=(2 5) mend=(8 11)
    else
      unset MATCH MBEGIN MEND match mbegin mend
    fi
    case "$F304_WIDGET_KIND" in
      pr) _zdx_widget_pr_candidates ;;
      ss) OSTYPE=linux-gnu _zdx_widget_port_candidates ;;
      *) exit 81 ;;
    esac > "$HOME/candidate.stdout" 2> "$HOME/candidate.stderr"
    local candidate_rc=$?
    [[ "$candidate_rc" == 0 && ! -s "$HOME/candidate.stdout" \
      && ! -s "$HOME/candidate.stderr" && ${#widget_values} == 1 ]] || exit 82
    case "$F304_WIDGET_KIND" in
      pr)
        [[ "${widget_values[1]}" == 42 && -z "${widget_alternates[1]}" \
          && "${widget_labels[1]}" == "#42  feature/fixture  Fixture title" ]] || exit 83
        ;;
      ss)
        [[ "${widget_values[1]}" == 777 && "${widget_alternates[1]}" == 8080 \
          && "${widget_labels[1]}" == ":8080  fixture  pid 777  127.0.0.1:8080" ]] || exit 84
        ;;
    esac
    if [[ "$F304_WIDGET_STATE" == seeded ]]; then
      [[ "$MATCH" == caller && "$MBEGIN" == 7 && "$MEND" == 12 \
        && "${(j:,:)match}" == captured,other && "${(j:,:)mbegin}" == 2,5 \
        && "${(j:,:)mend}" == 8,11 ]] || exit 85
    else
      (( ! ${+MATCH} && ! ${+MBEGIN} && ! ${+MEND} \
        && ! ${+match} && ! ${+mbegin} && ! ${+mend} )) || exit 86
    fi
    print -r -- widget-state-kept
  ' "$HOME"
  [ "$status" -eq 0 ]
  [ "$output" = widget-state-kept ]
  [ "$(cat "$WIDGET_PROBE_LOG")" = "$F304_WIDGET_KIND fixture" ]
  [ ! -s "$WIDGET_FZF_INPUT" ]
}

@test "F3-04 module regex: widget PR parsing preserves seeded caller state" {
  f304_module_widget_state pr seeded
}

@test "F3-04 module regex: widget PR parsing preserves unset caller state" {
  f304_module_widget_state pr unset
}

@test "F3-04 module regex: widget ss parsing preserves seeded caller state" {
  f304_module_widget_state ss seeded
}

@test "F3-04 module regex: widget ss parsing preserves unset caller state" {
  f304_module_widget_state ss unset
}
