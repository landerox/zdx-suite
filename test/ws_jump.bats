#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  WS="$HOME/workspaces"
  export WS
  # A repository is any directory with a .git entry; discovery needs no Git.
  mkdir -p \
    "$WS/github/personal/alpha/.git" \
    "$WS/github/personal/alpha-tools/.git" \
    "$WS/github/personal/beta/.git" \
    "$WS/github/personal/notes" \
    "$WS/github/personal/alpha/vendor/inner/.git" \
    "$WS/gitlab/work/gamma/.git" \
    "$WS/github/.hidden/secret/.git" \
    "$WS/github/personal/.cache/cached/.git" \
    "$WS/deep/a/b/c/deeprepo/.git" \
    "$WS/local/scratch/.git"
  # A linked worktree or submodule has a .git file instead of a directory.
  mkdir -p "$WS/github/personal/worktree"
  printf 'gitdir: /elsewhere\n' > "$WS/github/personal/worktree/.git"
  # Symbolic links are never followed or listed.
  ln -s "$WS/gitlab/work/gamma" "$WS/github/personal/linked"
}

teardown() {
  cleanup_sandbox
}

# The sorted relative paths that discovery reports with a forced backend.
collect_with() {
  local backend="$1"
  run run_zsh "
    _ws_discovery_backend() {
      reply=(\"\$(whence -p $backend)\" $backend)
      [[ -n \"\${reply[1]}\" ]]
    }
    _ws_collect_repositories \"\$WS\" || return
    print -rl -- \"\${reply[@]}\"
  "
}

@test "ws jump: find discovery lists repositories within the depth only" {
  collect_with find
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    github/personal/alpha \
    github/personal/alpha-tools \
    github/personal/beta \
    github/personal/worktree \
    gitlab/work/gamma \
    local/scratch)" ]
}

@test "ws jump: fd discovery matches find discovery" {
  local fd_path=""
  fd_path=$(command -v fd || command -v fdfind || true)
  [ -n "$fd_path" ] || skip "fd is not installed"
  ln -s "$fd_path" "$TEST_MOCK_BIN/fd"
  collect_with find
  local expected="$output"
  collect_with fd
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "ws jump: depth and exclusions bound the scan and are validated" {
  run run_zsh '
    WS_MAX_DEPTH=5
    WS_EXCLUDE=(gitlab github/personal/beta/ local)
    _ws_collect_repositories "$WS" || return
    print -rl -- "${reply[@]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"deep/a/b/c/deeprepo"* ]]
  [[ "$output" != *"gamma"* ]]
  [[ "$output" != *"/beta"* ]]
  [[ "$output" != *"local/scratch"* ]]
  [[ "$output" == *"github/personal/alpha-tools"* ]]

  local setting
  for setting in "WS_MAX_DEPTH=0" "WS_MAX_DEPTH=11" "WS_MAX_DEPTH=x" \
    "WS_EXCLUDE=(../outside)" "WS_EXCLUDE=(/abs)" "WS_EXCLUDE=(a/./b)"; do
    run run_zsh "$setting; _ws_collect_repositories \"\$WS\""
    [ "$status" -eq 1 ]
    [[ "$output" == *"WS_MAX_DEPTH"* || "$output" == *"WS_EXCLUDE"* ]]
  done
}

@test "ws jump: a unique query changes the shell directory and reports it" {
  run run_zsh '
    ws-jump gamma || return
    print -r -- "pwd:$PWD"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Now in ~/workspaces/gitlab/work/gamma"* ]]
  [[ "$output" == *"pwd:$WS/gitlab/work/gamma"* ]]
}

@test "ws jump: an exact name wins over partial matches" {
  run run_zsh '
    ws-jump alpha 2>/dev/null || return
    print -r -- "pwd:$PWD"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "pwd:$WS/github/personal/alpha" ]
  [ ! -s "$MOCK_FZF_ARGS_FILE" ]
}

@test "ws jump: an ambiguous query opens the picker with only its matches" {
  export MOCK_FZF_MODE="match"
  export MOCK_FZF_MATCH="alpha-tools|"
  run run_zsh '
    ws-jump ALPH 2>/dev/null || return
    print -r -- "pwd:$PWD"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "pwd:$WS/github/personal/alpha-tools" ]
  [ "$(cat "$MOCK_FZF_INPUT_FILE")" = "$(printf '%s\n' \
    'github/personal/alpha|1' 'github/personal/alpha-tools|2')" ]
  grep -Fq -- '--prompt=ws\ jump\ \>\ ' "$MOCK_FZF_ARGS_FILE"
  local -a leftovers=("$TMPDIR"/zdx-ws-*)
  [ ! -e "${leftovers[0]}" ]
}

@test "ws jump: no match, cancellation, and forged rows keep the directory" {
  run run_zsh '
    builtin cd -- "$HOME" || return
    ws-jump no-such-repository >/dev/null 2>&1
    (( $? == 1 )) || return 1
    [[ "$PWD" == "$HOME" ]] || return 2

    export MOCK_FZF_MODE=cancel MOCK_FZF_STATUS=130
    ws-jump >/dev/null 2>&1 || return 3
    [[ "$PWD" == "$HOME" ]] || return 4

    export MOCK_FZF_MODE=response MOCK_FZF_RESPONSE="github/personal/../../../etc|1"
    ws-jump >/dev/null 2>&1
    (( $? == 1 )) || return 5
    [[ "$PWD" == "$HOME" ]] || return 6

    export MOCK_FZF_MODE=response MOCK_FZF_RESPONSE="github/personal/beta|99"
    ws-jump >/dev/null 2>&1
    (( $? == 1 )) || return 7
    [[ "$PWD" == "$HOME" ]]
  '
  [ "$status" -eq 0 ]
}

@test "ws jump: a repository removed while the picker is open is refused" {
  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
rm -rf "$WS/github/personal/beta"
printf '%s\n' "$input" | grep -F 'github/personal/beta|'
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"
  run run_zsh '
    builtin cd -- "$HOME" || return
    ws-jump
    local jump_rc=$?
    print -r -- "pwd:$PWD"
    return $jump_rc
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"no longer exists"* ]]
  [[ "$output" == *"pwd:$HOME"* ]]
}

@test "ws jump: hostile directory names are listed as data or skipped" {
  local hostile="$WS/github/personal/it's \$(touch \"\$TMPDIR\"pwned) \`id\` repo"
  mkdir -p "$hostile/.git"
  mkdir -p "$WS/github/personal/pipe|name/.git"
  mkdir -p "$WS/github/personal/line"$'\n'"break/.git"
  mkdir -p "$WS/github/personal/-dash/.git"
  export MOCK_FZF_MODE="match"
  export MOCK_FZF_MATCH="it's"
  run run_zsh '
    ws-jump || return
    print -r -- "pwd:$PWD"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped 2 directories whose names cannot be shown safely."* ]]
  [[ "$output" == *"pwd:$hostile"* ]]
  [ ! -e "${TMPDIR}pwned" ]
  grep -Fq 'github/personal/-dash|' "$MOCK_FZF_INPUT_FILE"
  ! grep -Fq 'pipe' "$MOCK_FZF_INPUT_FILE" || false

  run run_zsh '
    ws-jump -- -dash 2>/dev/null || return
    print -r -- "pwd:$PWD"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "pwd:$WS/github/personal/-dash" ]
}

@test "ws jump: the preview is a constant program fed only by the row index" {
  local repo="$WS/github/personal/it's \$(touch \"\$TMPDIR\"pwned) repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.name=T -c user.email=t@example.invalid \
    commit -q --allow-empty -m "first subject"
  printf 'x\n' > "$repo/untracked"
  export PREVIEW_OUT="$TEST_TEMP_DIR/preview.out"
  # Render every row like fzf would while the snapshot exists: {n} is the
  # only placeholder and the program text never contains a selected path.
  cat > "$TEST_MOCK_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
preview=""
for argument in "$@"; do
  case "$argument" in --preview=*) preview="${argument#--preview=}" ;; esac
done
mapfile -t rows
printf '%s' "$preview" > "$PREVIEW_OUT.program"
for index in "${!rows[@]}"; do
  printf '== %s\n' "${rows[index]}" >> "$PREVIEW_OUT"
  /bin/sh -c "${preview//\{n\}/$index}" >> "$PREVIEW_OUT" 2>&1
done
exit 130
EOF
  chmod +x "$TEST_MOCK_BIN/fzf"
  run run_zsh 'ws-jump'
  [ "$status" -eq 0 ]
  [ ! -e "${TMPDIR}pwned" ]
  ! grep -Fq 'pwned' "$PREVIEW_OUT.program" || false
  ! grep -Fq 'github/personal' "$PREVIEW_OUT.program" || false
  grep -Fq '{n}' "$PREVIEW_OUT.program"
  grep -A3 -F "== github/personal/it's" "$PREVIEW_OUT" > "$TEST_TEMP_DIR/hostile.preview"
  grep -Fq 'Branch:      main' "$TEST_TEMP_DIR/hostile.preview"
  grep -Fq 'Changes:     1' "$TEST_TEMP_DIR/hostile.preview"
  grep -Eq 'Last commit: .*: first subject' "$TEST_TEMP_DIR/hostile.preview"
  local -a leftovers=("$TMPDIR"/zdx-ws-*)
  [ ! -e "${leftovers[0]}" ]
}

@test "ws jump: routed through ws-menu and zdx it still changes the shell" {
  run run_zsh '
    ws-menu ws-jump beta 2>/dev/null || return
    print -r -- "menu:$PWD"
    zdx ws ws-jump gamma 2>/dev/null || return
    print -r -- "zdx:$PWD"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"menu:$WS/github/personal/beta"* ]]
  [[ "$output" == *"zdx:$WS/gitlab/work/gamma"* ]]
}

@test "ws jump: a missing root or an empty workspace fails clearly" {
  run run_zsh 'WS_BASE_DIR="$HOME/nowhere"; ws-jump'
  [ "$status" -eq 1 ]
  [[ "$output" == *"The workspace root does not exist: ~/nowhere"* ]]

  mkdir -p "$HOME/empty"
  run run_zsh 'WS_BASE_DIR="$HOME/empty"; ws-jump'
  [ "$status" -eq 1 ]
  [[ "$output" == *"No repositories were found below ~/empty."* ]]

  run run_zsh 'WS_BASE_DIR=relative/path; ws-jump'
  [ "$status" -eq 1 ]
  [[ "$output" == *"WS_BASE_DIR must be an absolute path."* ]]
}
