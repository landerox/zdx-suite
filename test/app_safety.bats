#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "app safety: a symbolic-link descriptor is refused before discovery" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > real-justfile
    ln -s real-justfile Justfile
    app-list
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"descriptor"* ]]
}

@test "app safety: package script bodies never become discovery output or shell text" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- \
      "{\"scripts\":{\"safe\":\"touch $HOME/should-not-exist\"}}" \
      > package.json
    app-list >"$HOME/tasks"
    [[ ! -e "$HOME/should-not-exist" ]]
    ! grep -q "touch" "$HOME/tasks"
    grep -q "$(printf "^npm\tsafe\t")" "$HOME/tasks"
  '
  [ "$status" -eq 0 ]
}

@test "app safety: option-like and shell-bearing task names fail closed" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- \
      "{\"scripts\":{\"-unsafe\":\"true\",\"bad;touch-pwn\":\"true\"}}" \
      > package.json
    app-list
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse"* ]]
  [ ! -e "$HOME/pwn" ]
}

@test "app safety: multiple package-manager lock families fail closed" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "{\"scripts\":{\"build\":\"true\"}}" > package.json
    : > pnpm-lock.yaml
    : > yarn.lock
    app-list
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous"* ]]
}

@test "app safety: descriptor replacement after authorization prevents execution" {
  cat <<'EOF' > "$TEST_MOCK_BIN/just"
#!/usr/bin/env bash
printf 'ran\n' >> "$APP_BACKEND_LOG"
EOF
  chmod +x "$TEST_MOCK_BIN/just"
  export APP_BACKEND_LOG="$TEST_TEMP_DIR/backend.log"

  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    _app_confirm() {
      print -r -- "changed:" > Justfile
      return 0
    }
    app-run --backend just --task build
  '
  [ "$status" -eq 1 ]
  [ ! -e "$APP_BACKEND_LOG" ]
  [[ "$output" == *"changed after discovery"* ]]
}

@test "app safety: a picker row outside the current snapshot is rejected" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="Injected|app-run|forged|99"

  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    app-menu
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the App menu snapshot"* ]]
}

@test "app safety: malformed direct grammar fails before backend probes" {
  run run_zsh '
    _app_require_cmd() {
      print -r -- "PROBED:$*" >&2
      return 99
    }
    app-run --backend just --task
  '
  [ "$status" -eq 2 ]
  [[ "$output" != *"PROBED:"* ]]

  run run_zsh 'app-run --backend compose --task all'
  [ "$status" -eq 2 ]
  [[ "$output" == *"explicit compose --action"* ]]

  run run_zsh \
    'app-run --backend compose --task web --action up --dry-run'
  [ "$status" -eq 2 ]
  [[ "$output" == *"require --task all"* ]]
}

@test "app safety: dry-run does not require or invoke the selected backend" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    unfunction just 2>/dev/null || true
    app-run --backend just --task build --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run"* ]]
}

@test "app safety: byte accounting and typed backend actions fail closed" {
  run run_zsh '
    _app_record_byte_count "é"
    print -r -- "$REPLY"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  run run_zsh '_app_validate_backend_action just build up'
  [ "$status" -eq 1 ]

  run run_zsh '_app_validate_backend_action compose all down'
  [ "$status" -eq 0 ]
}

@test "app safety: an untrusted mktemp result is never chmodded or removed" {
  export APP_MKTEMP_VICTIM="$HOME/tmp/not-an-app-capture"
  mkdir -p "$APP_MKTEMP_VICTIM"
  printf 'keep\n' > "$APP_MKTEMP_VICTIM/keep"
  chmod 700 "$APP_MKTEMP_VICTIM"

  cat <<'EOF' > "$TEST_MOCK_BIN/mktemp"
#!/usr/bin/env bash
printf '%s\n' "$APP_MKTEMP_VICTIM"
EOF
  chmod +x "$TEST_MOCK_BIN/mktemp"

  run run_zsh '
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    zmodload zsh/stat || return
    local -A before_state=() after_state=()
    zstat -LH before_state -- "$APP_MKTEMP_VICTIM" || return
    _app_fzf_capture </dev/null
    local capture_rc=$?
    zstat -LH after_state -- "$APP_MKTEMP_VICTIM" || return
    (( capture_rc == 125 )) || return 1
    [[ "${before_state[mode]}" == "${after_state[mode]}" ]]
    [[ -f "$APP_MKTEMP_VICTIM/keep" ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsafe App menu directory"* ]]
}

@test "app safety: single-select rejects multiple returned snapshot rows" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    print -r -- "verify:" > Makefile
    _app_fzf_capture() {
      local picker_input=""
      picker_input=$(<&0)
      local -a picker_rows=("${(@f)picker_input}")
      REPLY="${picker_rows[1]}
${picker_rows[2]}"
      return 0
    }
    _app_confirm() {
      print -r -- "UNEXPECTED_CONFIRMATION"
      return 0
    }
    app-menu
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"single-select App menu returned multiple"* ]]
  [[ "$output" != *"UNEXPECTED_CONFIRMATION"* ]]
}

@test "app safety: an exact snapshot row resolves without arithmetic evaluation" {
  run run_zsh '
    cd "$HOME" || return
    print -r -- "build:" > Justfile
    _app_fzf_capture() {
      local picker_input=""
      picker_input=$(<&0)
      local -a picker_rows=("${(@f)picker_input}")
      REPLY="${picker_rows[1]}"
      return 0
    }
    _app_execute_task_records() {
      (( $# == 3 )) || return 1
      [[ "$1" == "no" && "$2" == "no" ]] || return 1
      local -a task_fields=()
      _app_parse_task_record "$3" || return 1
      task_fields=("${reply[@]}")
      [[ "${task_fields[1]}" == "just" \
        && "${task_fields[4]}" == "build" ]]
    }
    app-menu
  '
  [ "$status" -eq 0 ]
}

@test "app safety: cancellation cannot carry a forged selection" {
  run run_zsh '
    export TMPDIR="$HOME/tmp"
    mkdir -p "$TMPDIR"
    _app_fzf() {
      print -r -- "forged"
      return 130
    }
    _app_fzf_capture </dev/null
  '
  [ "$status" -eq 125 ]
  [[ "$output" == *"cancelled App menu returned unexpected data"* ]]
}
