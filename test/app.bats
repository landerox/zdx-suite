#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "app: entrypoint and canonical commands load cleanly" {
  run run_zsh '
    typeset -f app-menu >/dev/null
    typeset -f app-list >/dev/null
    typeset -f app-run >/dev/null
  '
  [ "$status" -eq 0 ]
}

@test "app: help is stderr-only and documents the code trust boundary" {
  run run_zsh '
    app-menu --help >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
    grep -q "app-list" "$HOME/stderr"
    grep -q "app-run" "$HOME/stderr"
    grep -q "executable code" "$HOME/stderr"
  '
  [ "$status" -eq 0 ]
}

@test "app: an empty workspace emits no task data" {
  run run_zsh '
    cd "$HOME" || return
    app-list >"$HOME/stdout" 2>"$HOME/stderr"
    [[ ! -s "$HOME/stdout" ]]
  '
  [ "$status" -eq 0 ]
}

@test "app: discovery emits typed Just and Make records without running them" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build: # Build" > Justfile
    print -r -- "verify:" > Makefile
    app-list
  '
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == $'just\tbuild\trun\t'*$'\t'"$HOME/Justfile" ]]
  [[ "${lines[1]}" == $'make\tverify\trun\t'*$'\t'"$HOME/Makefile" ]]
}

@test "app: package discovery reports only validated script names" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- \
      "{\"scripts\":{\"start\":\"node index.js\",\"lint\":\"eslint .\"}}" \
      > package.json
    app-list
  '
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == $'npm\tstart\trun\t'* ]]
  [[ "${lines[1]}" == $'npm\tlint\trun\t'* ]]
  [[ "$output" != *"node index.js"* ]]
  [[ "$output" != *"eslint ."* ]]
}

@test "app: direct routing rejects arbitrary command text" {
  run run_zsh 'app-menu "print PWNED"'
  [ "$status" -eq 2 ]
  ! grep -Fxq -- "PWNED" <<< "$output"
  [[ "$output" == *"Unknown command"* ]]
}

@test "app: dry-run validates an exact task without executing its backend" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    just() {
      print -r -- "BACKEND_RAN"
      return 99
    }
    app-run --backend just --task build --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run"* ]]
  [[ "$output" == *"$HOME/Justfile"* ]]
  [[ "$output" != *"<descriptor>"* ]]
  [[ "$output" != *"BACKEND_RAN"* ]]
}

@test "app: non-interactive execution fails closed without --yes" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    just() { return 0; }
    app-run --backend just --task build
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a terminal"* ]]
}

@test "app: --yes runs the fixed backend with the exact task argument" {
  cat <<'EOF' > "$TEST_MOCK_BIN/just"
#!/usr/bin/env bash
printf '%s\n' "$@" > "$APP_JUST_LOG"
EOF
  chmod +x "$TEST_MOCK_BIN/just"
  export APP_JUST_LOG="$TEST_TEMP_DIR/just.log"

  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    app-run --backend just --task build --yes
  '
  [ "$status" -eq 0 ]
  grep -Fxq -- "--justfile" "$APP_JUST_LOG"
  grep -Fxq -- "$HOME/Justfile" "$APP_JUST_LOG"
  grep -Fxq -- "build" "$APP_JUST_LOG"
}

@test "app: picker cancellation is success and leaves no capture directory" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"

  run run_zsh '
    cd "$HOME" || return
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    print -r -- "build:" > Justfile
    app-menu
    local menu_rc=$?
    (( menu_rc == 0 )) || return 1
    local -a leftovers=("$TMPDIR"/zdx-app-fzf.*(N))
    (( ${#leftovers} == 0 ))
  '
  [ "$status" -eq 0 ]
}
