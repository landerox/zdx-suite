#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

# --- Source safety ----------------------------------------------------------

@test "dev interface: sourcing twice is silent and defines no duplicate state" {
  local stdout_file="$TEST_TEMP_DIR/stdout"
  local stderr_file="$TEST_TEMP_DIR/stderr"

  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    source '$TEST_SUITE_ROOT/functions/dev-menu.zsh'
    source '$TEST_SUITE_ROOT/functions/dev-menu.zsh'
    typeset -f dev-menu >/dev/null || exit 1
  " >"$stdout_file" 2>"$stderr_file"

  [ "$status" -eq 0 ]
  [ ! -s "$stdout_file" ]
  [ ! -s "$stderr_file" ]
}

@test "dev interface: standalone sourcing works without the core runtime" {
  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    source '$TEST_SUITE_ROOT/functions/dev-menu.zsh' || exit 1

    # _timed belongs to the core runtime and must not be required here.
    typeset -f _timed >/dev/null && exit 1

    # The suite must not define a competing global _timed either.
    _dev_timed 'dev:probe' true || exit 1
    typeset -f _dev_fzf >/dev/null || exit 1
    print -r -- OK
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "dev interface: sourcing opens no fzf and reads no stdin" {
  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    fzf() { print -u2 -r -- 'FZF WAS OPENED'; return 1; }
    source '$TEST_SUITE_ROOT/functions/dev-menu.zsh'
    print -r -- DONE
  " < /dev/null

  [ "$status" -eq 0 ]
  [[ "$output" != *"FZF WAS OPENED"* ]]
  [[ "$output" == *"DONE"* ]]
}

@test "dev interface: no global fzf option array is built at source time" {
  ! grep -q '_DEV_FZF_OPTS' "$TEST_SUITE_ROOT/functions/dev-common.zsh"

  run run_zsh 'typeset -p _DEV_FZF_OPTS 2>/dev/null && return 1; return 0'
  [ "$status" -eq 0 ]
}

@test "dev interface: a failed mandatory module leaves no loaded sentinel" {
  local broken_root="$TEST_TEMP_DIR/broken"
  mkdir -p "$broken_root/dev"
  cp "$TEST_SUITE_ROOT/functions/dev-menu.zsh" "$broken_root/"
  cp "$TEST_SUITE_ROOT/functions/dev-common.zsh" "$broken_root/"
  local module
  for module in "$TEST_SUITE_ROOT"/functions/dev/*.zsh; do
    cp "$module" "$broken_root/dev/"
  done
  printf 'if true; then\n' > "$broken_root/dev/dev-clean.zsh"

  run zsh -c "
    export HOME='$HOME'
    export PATH='$PATH'
    source '$broken_root/dev-menu.zsh'
    local rc=\$?
    [[ -n \"\${_DEV_MENU_SOURCED:-}\" ]] && exit 1
    exit \$(( rc == 0 ? 1 : 0 ))
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"failed to load dev-clean.zsh"* ]]
}

# --- Stream contract --------------------------------------------------------

@test "dev interface: help goes to stderr, never stdout" {
  local stdout_file="$TEST_TEMP_DIR/help.out"
  local stderr_file="$TEST_TEMP_DIR/help.err"

  run run_zsh "dev-menu --help >'$stdout_file' 2>'$stderr_file'"

  [ "$status" -eq 0 ]
  [ ! -s "$stdout_file" ]
  grep -q 'Usage:' "$stderr_file"
}

@test "dev interface: logging helpers write only to stderr" {
  local stdout_file="$TEST_TEMP_DIR/log.out"
  local stderr_file="$TEST_TEMP_DIR/log.err"

  run run_zsh "
    {
      _dev_header 'Header'
      _dev_success 'Success'
      _dev_warn 'Warn'
      _dev_info 'Info'
      _dev_error 'Error'
      _dev_dim 'Dim'
      _dev_blank
    } >'$stdout_file' 2>'$stderr_file'
  "

  [ "$status" -eq 0 ]
  [ ! -s "$stdout_file" ]
  grep -q 'Header' "$stderr_file"
  grep -q 'Error' "$stderr_file"
}

@test "dev interface: menu row builders write records only to stdout" {
  local stdout_file="$TEST_TEMP_DIR/rows.out"
  local stderr_file="$TEST_TEMP_DIR/rows.err"

  run run_zsh "_dev_menu_rows >'$stdout_file' 2>'$stderr_file'"

  [ "$status" -eq 0 ]
  [ ! -s "$stderr_file" ]
  grep -q '^  [^|]*|dev-check-health|' "$stdout_file"
}

@test "dev interface: NO_COLOR suppresses ANSI without changing status" {
  local stderr_file="$TEST_TEMP_DIR/nocolor.err"

  run run_zsh "
    export NO_COLOR=1
    _dev_info 'plain message' 2>'$stderr_file'
  "

  [ "$status" -eq 0 ]
  grep -q 'plain message' "$stderr_file"
  ! grep -q $'\033' "$stderr_file"
}

@test "dev interface: no-argument parser accepts only empty or help grammar" {
  run run_zsh '
    local REPLY

    _dev_parse_no_arguments demo || return 1
    [[ "$REPLY" == "run" ]] || return 2

    _dev_parse_no_arguments demo --help || return 3
    [[ "$REPLY" == "help" ]] || return 4

    _dev_parse_no_arguments demo -h || return 5
    [[ "$REPLY" == "help" ]] || return 6

    _dev_parse_no_arguments demo "" >/dev/null 2>&1
    (( $? == 2 )) || return 7
    _dev_parse_no_arguments demo --help extra >/dev/null 2>&1
    (( $? == 2 )) || return 8
  '

  [ "$status" -eq 0 ]
}

# --- Menu record validation -------------------------------------------------

@test "dev interface: menu rows carry exactly three fields and no ANSI" {
  run run_zsh "_dev_menu_rows"
  [ "$status" -eq 0 ]

  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local field_count
    field_count=$(awk -F '|' '{ print NF }' <<< "$line")
    if [[ "$field_count" -ne 3 ]]; then
      echo "Row does not have three fields: $line" >&2
      return 1
    fi
    if [[ "$line" == *$'\033'* ]]; then
      echo "Row contains a raw escape sequence: $line" >&2
      return 1
    fi
  done <<< "$output"
}

@test "dev interface: row helpers reject delimiter, newline, and NUL injection" {
  run run_zsh "_dev_menu_entry 'Bad|Label' 'dev-check-health' 'Description.'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"pipe, newline, and NUL"* ]]

  run run_zsh "_dev_menu_section 'Bad|Title'"
  [ "$status" -eq 2 ]

  run run_zsh \
    "_dev_menu_entry \$'Bad\\0Label' 'dev-check-health' 'Description.'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"NUL"* ]]

  run run_zsh "_dev_menu_entry 'Label' 'dev-check-health'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"label, command, and description"* ]]
}

@test "dev interface: a missing dependency is named in the row label" {
  run run_zsh "
    command() {
      if [[ \"\$1\" == '-v' && \"\$2\" == 'tflint' ]]; then
        return 1
      fi
      builtin command \"\$@\"
    }
    _dev_menu_entry 'Lint Terraform' 'dev-run-tflint' 'Lint the project.'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"(missing: tflint)"* ]]
  [[ "$output" == *"|dev-run-tflint|"* ]]
}

@test "dev interface: delegated environment rows advertise only real prerequisites" {
  run run_zsh '
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "uv" ]]; then
        return 1
      fi
      if [[ "${1:-}" == "-v" && "${2:-}" == "python3" ]]; then
        return 0
      fi
      if [[ "${1:-}" == "python3" ]]; then
        return 1
      fi
      builtin command "$@"
    }

    local command_name REPLY
    local -a stdlib_commands=(
      venv-list venv-create venv-activate venv-info venv-rebuild venv-remove
    )
    local -a uv_commands=(
      venv-python-list venv-python-install venv-python-pin
    )

    for command_name in "${stdlib_commands[@]}"; do
      _dev_menu_missing_requirements "$command_name" reply || return 1
      print -r -- "$command_name:${REPLY:-ready}"
    done
    for command_name in "${uv_commands[@]}"; do
      _dev_menu_missing_requirements "$command_name" reply || return 1
      print -r -- "$command_name:${REPLY:-ready}"
    done
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"venv-list:ready"* ]]
  [[ "$output" == *"venv-create:ready"* ]]
  [[ "$output" == *"venv-activate:ready"* ]]
  [[ "$output" == *"venv-info:ready"* ]]
  [[ "$output" == *"venv-rebuild:ready"* ]]
  [[ "$output" == *"venv-remove:ready"* ]]
  [[ "$output" == *"venv-python-list:uv"* ]]
  [[ "$output" == *"venv-python-install:uv"* ]]
  [[ "$output" == *"venv-python-pin:uv"* ]]
  [[ "$output" != *"tomllib"* ]]
}

@test "dev interface: Python ephemeral availability requires uvx, not uv" {
  run run_zsh '
    DEV_ALLOW_EPHEMERAL=1
    _dev_pyproject_has_dep() { return 1; }
    command() {
      case "${1:-}:${2:-}" in
        -v:ruff|-v:uvx) return 1 ;;
        -v:uv) return 0 ;;
      esac
      builtin command "$@"
    }

    local -a reply=()
    _dev_python_tool_runner ruff
    local -i runtime_status=$?
    print -r -- "runtime:${runtime_status}:${(j: :)reply}"

    local REPLY
    _dev_menu_missing_requirements dev-run-ruff reply || return 1
    print -r -- "advisory:$REPLY"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime:1:"* ]]
  [[ "$output" == *"uvx runner was not found"* ]]
  [[ "$output" != *"ephemeral execution is disabled"* ]]
  [[ "$output" == \
    *"advisory:ruff (project/local or ephemeral opt-in)"* ]]
}

@test "dev interface: one render caches shallow probes without running Python" {
  run run_zsh '
    typeset -gi uv_probes=0
    typeset -gi ruff_path_probes=0
    typeset -gi pytest_path_probes=0
    typeset -gi python_processes=0
    typeset -gi deep_probes=0

    command() {
      if [[ "${1:-}" == "-v" ]]; then
        [[ "${2:-}" == "uv" ]] && (( uv_probes += 1 ))
        return 0
      fi
      if [[ "${1:-}" == "python3" ]]; then
        (( python_processes += 1 ))
        return 0
      fi
      builtin command "$@"
    }
    _dev_menu_probe_project_executable() {
      [[ "${1:-}" == "ruff" ]] && (( ruff_path_probes += 1 ))
      [[ "${1:-}" == "pytest" ]] && (( pytest_path_probes += 1 ))
      return 0
    }
    _dev_python_tool_available() {
      (( deep_probes += 1 ))
      return 0
    }
    _dev_exact_project_python_tool_runner() {
      (( deep_probes += 1 ))
      return 0
    }
    _dev_project_python_tool_available() {
      (( deep_probes += 1 ))
      return 0
    }
    _dev_project_python_module_available() {
      (( deep_probes += 1 ))
      return 0
    }
    _dev_pyproject_has_dep() {
      (( deep_probes += 1 ))
      return 1
    }
    _dev_node_tool_available() { return 0; }

    _dev_menu_rows >/dev/null || return 1
    _dev_menu_rows >/dev/null || return 1
    print -r -- \
      "uv=$uv_probes ruff=$ruff_path_probes pytest=$pytest_path_probes python=$python_processes deep=$deep_probes"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"uv=2 ruff=2 pytest=2 python=0 deep=0"* ]]
}

@test "dev interface: shallow project executables stay inside a real venv" {
  local project="$TEST_TEMP_DIR/shallow-project"
  mkdir -p "$project/.venv/bin" "$project/outside"
  printf '#!/usr/bin/env zsh\nexit 0\n' > "$project/.venv/bin/ruff"
  printf '#!/usr/bin/env zsh\nexit 0\n' > "$project/outside/bandit"
  chmod +x "$project/.venv/bin/ruff" "$project/outside/bandit"
  ln -s "$project/outside/bandit" "$project/.venv/bin/bandit"

  run run_zsh "cd '$project' && _dev_menu_project_executable_available ruff"
  [ "$status" -eq 0 ]

  run run_zsh "cd '$project' && _dev_menu_project_executable_available bandit"
  [ "$status" -eq 1 ]

  mkdir -p "$project/linked-project"
  ln -s "$project/.venv" "$project/linked-project/.venv"
  run run_zsh \
    "cd '$project/linked-project' && _dev_menu_project_executable_available ruff"
  [ "$status" -eq 1 ]
}

@test "dev interface: Python update needs uv only for an existing real venv" {
  run run_zsh '
    command mkdir -p "$HOME/project"
    cd "$HOME/project" || return 1
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "uv" ]]; then
        return 1
      fi
      builtin command "$@"
    }

    _dev_menu_entry \
      "Update Python Without Venv" "dev-update-python" "Delegate installation."
    command mkdir .venv
    _dev_menu_entry \
      "Update Python With Venv" "dev-update-python" "Replace environment."
  '

  [ "$status" -eq 0 ]
  [[ "$output" == \
    *"Update Python Without Venv|dev-update-python|Delegate installation."* ]]
  [[ "$output" != *"Update Python Without Venv (missing:"* ]]
  [[ "$output" == \
    *"Update Python With Venv (missing: uv)|dev-update-python|"* ]]
}

@test "dev interface: coverage annotation includes its project backend" {
  run run_zsh '
    _dev_menu_project_executable_available() {
      [[ "${1:-}" == "pytest" ]]
    }

    local REPLY
    _dev_menu_missing_requirements dev-run-coverage reply || return 1
    print -r -- "$REPLY"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"pytest-cov or coverage (installed in .venv)"* ]]
  [[ "$output" != *"pytest (installed in .venv)"* ]]
}

@test "dev interface: the header advertises only bindings that are active" {
  run run_zsh "
    fzf() {
      command cat >/dev/null
      printf 'fzf %s\n' \"\$*\" >&2
      return 130
    }
    dev-menu 2>&1
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"Type to filter | Enter run | Esc cancel | Ctrl-/ details"* ]]
  [[ "$output" == *"--bind=ctrl-/:toggle-preview"* ]]
  [[ "$output" != *"Tab mark"* ]]
  [[ "$output" != *"Tab] Search"* ]]
}

@test "dev interface: multi-select advertises Tab and enables --multi" {
  run run_zsh "
    fzf() {
      command cat >/dev/null
      printf 'fzf %s\n' \"\$*\" >&2
      return 130
    }
    dev-menu --multi 2>&1
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"--multi"* ]]
  [[ "$output" == *"Tab mark"* ]]
}

@test "dev interface: fzf receives a pipe delimiter and a single visible field" {
  run run_zsh "
    fzf() {
      command cat >/dev/null
      printf '%s\n' \"\$@\" >&2
      return 130
    }
    dev-menu 2>&1
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"--delimiter=[|]"* ]]
  [[ "$output" == *"--with-nth=1"* ]]
}

# --- Selection and dispatch -------------------------------------------------

@test "dev interface: selecting a section row dispatches nothing" {
  run run_zsh '
    local dispatch_log="$HOME/dispatch.log"
    fzf() {
      command cat >/dev/null
      print -r -- "── Inspection ──|:|Read-only project diagnostics."
      return 0
    }
    _dev_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
      return 0
    }

    dev-menu
    local rc=$?
    [[ ! -e "$dispatch_log" ]] || return 1
    return $rc
  '

  [ "$status" -eq 0 ]
}

@test "dev interface: selecting an action dispatches the canonical token once" {
  run run_zsh '
    # The mock returns the exact rendered row so the snapshot check passes.
    fzf() {
      local -a rows=("${(@f)$(command cat)}")
      local row
      for row in "${rows[@]}"; do
        [[ "$row" == *"|dev-check-health|"* ]] || continue
        print -r -- "$row"
        break
      done
      return 0
    }
    _dev_dispatch() {
      print -r -- "dispatched:$1"
      return 0
    }

    dev-menu
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched:dev-check-health"* ]]
  [ "$(grep -c 'dispatched:' <<< "$output")" -eq 1 ]
}

@test "dev interface: a selection outside the menu snapshot is refused" {
  run run_zsh '
    local dispatch_log="$HOME/dispatch.log"
    fzf() {
      command cat >/dev/null
      print -r -- "  Check Python/uv Health|dev-check-health|Forged row."
      return 0
    }
    _dev_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
      return 0
    }

    dev-menu
    local rc=$?
    [[ ! -e "$dispatch_log" ]] || return 99
    return $rc
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"was not in the menu snapshot"* ]]
}

@test "dev interface: a failed picker carrying data is not a selection" {
  run run_zsh '
    local dispatch_log="$HOME/dispatch.log"
    fzf() {
      local -a rows=("${(@f)$(command cat)}")
      local row
      for row in "${rows[@]}"; do
        [[ "$row" == *"|dev-check-health|"* ]] || continue
        print -r -- "$row"
        break
      done
      return 2
    }
    _dev_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
      return 0
    }

    dev-menu
    local rc=$?
    [[ ! -e "$dispatch_log" ]] || return 99
    return $rc
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"returned unexpected data"* ]]
}

@test "dev interface: the private picker result is removed after the menu" {
  run run_zsh '
    export TMPDIR="$HOME/picker-tmp"
    command mkdir -p "$TMPDIR"
    command chmod 700 "$TMPDIR"
    fzf() {
      command cat >/dev/null
      return 130
    }

    dev-menu
    local rc=$?
    local -a leftovers=("$TMPDIR"/zdx-dev-fzf.*(N))
    (( ${#leftovers[@]} == 0 )) || return 99
    return $rc
  '

  [ "$status" -eq 0 ]
}

@test "dev interface: picker output is capped while fzf is writing" {
  run run_zsh '
    export TMPDIR="$HOME/picker-tmp"
    command mkdir -p "$TMPDIR"
    command chmod 700 "$TMPDIR"
    fzf() {
      limit -s filesize unlimited 2>/dev/null || :
      local payload="${(l:1024::x:)}"
      repeat 128 print -rn -- "$payload"
    }

    _dev_fzf_capture
    local -i picker_status=$?
    local -i expected_status=$(( 128 + $(kill -l XFSZ) ))
    local -a leftovers=("$TMPDIR"/zdx-dev-fzf.*(N))
    (( ${#leftovers[@]} == 0 )) || return 99
    print -r -- \
      "picker-status=$picker_status expected-status=$expected_status"
    (( picker_status == expected_status )) || return 98
    return $picker_status
  '

  [ "$status" -eq $(( 128 + $(kill -l XFSZ) )) ]
  [[ "$output" == *"picker-status=$status expected-status=$status"* ]]
}

@test "dev interface: multi-select runs every marked action in order" {
  run run_zsh '
    # The mock marks the exact rendered rows so the snapshot check passes.
    fzf() {
      local -a rows=("${(@f)$(command cat)}")
      local row
      for row in "${rows[@]}"; do
        [[ "$row" == *"|dev-run-ruff|"* || "$row" == *"|dev-run-tests|"* ]] \
          && print -r -- "$row"
      done
      return 0
    }
    _dev_dispatch() {
      print -r -- "ran:$1"
      return 0
    }

    dev-menu --multi
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"ran:dev-run-ruff"* ]]
  [[ "$output" == *"ran:dev-run-tests"* ]]
  [[ "$output" == *"All 2 task(s) completed"* ]]
}

@test "dev interface: multi-select reports a partial failure with non-zero status" {
  run run_zsh '
    fzf() {
      local -a rows=("${(@f)$(command cat)}")
      local row
      for row in "${rows[@]}"; do
        [[ "$row" == *"|dev-run-ruff|"* || "$row" == *"|dev-run-tests|"* ]] \
          && print -r -- "$row"
      done
      return 0
    }
    _dev_dispatch() {
      [[ "$1" == "dev-run-tests" ]] && return 3
      return 0
    }

    dev-menu --multi
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"1 of 2 task(s) failed"* ]]
}

@test "dev interface: multi-select skips a batch-eligible row outside the snapshot" {
  run run_zsh '
    local dispatch_log="$HOME/dispatch.log"
    fzf() {
      command cat >/dev/null
      print -r -- "  Forged Row|dev-run-ruff|Forged description."
      return 0
    }
    _dev_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
      return 0
    }

    dev-menu --multi
    local rc=$?
    [[ ! -e "$dispatch_log" ]] || return 99
    return $rc
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"outside the menu snapshot"* ]]
  [[ "$output" == *"No runnable tasks were selected"* ]]
}

@test "dev interface: direct invocation forwards arguments unchanged" {
  run run_zsh '
    dev-clean-py() {
      print -r -- "args:$*"
      return 0
    }
    _dev_verify_deps() { return 0; }

    dev-menu dev-clean-py --dry-run --keep-build
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"args:--dry-run --keep-build"* ]]
}

@test "dev interface: an argument beginning with a dash stays data" {
  run run_zsh '
    dev-profile-run() {
      print -r -- "count:$#"
      print -r -- "first:$1"
      return 0
    }
    _dev_verify_deps() { return 0; }

    dev-menu dev-profile-run -- --weird-name
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"count:2"* ]]
}

@test "dev interface: --help reaches a command whose dependency is missing" {
  run run_zsh '
    _dev_cmd_deps() { print -r -- "definitely-not-installed"; }
    dev-menu dev-run-tflint --help
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: dev-run-tflint"* ]]
  [[ "$output" != *"Missing required dependency"* ]]
}

@test "dev interface: a missing dependency fails closed without prompting" {
  run run_zsh '
    _dev_cmd_deps() { print -r -- "definitely-not-installed"; }
    _dev_project_has_files() { return 0; }
    _dev_confirm() { print -u2 -r -- "PROMPTED"; return 0; }

    dev-menu dev-run-tflint
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required dependency"* ]]
  [[ "$output" != *"PROMPTED"* ]]
}

@test "dev interface: --multi and --profile reject extra arguments" {
  run run_zsh "dev-menu --multi extra"
  [ "$status" -eq 2 ]

  run run_zsh "dev-menu --profile one two"
  [ "$status" -eq 2 ]

  run run_zsh "dev-menu --help extra"
  [ "$status" -eq 2 ]
}

@test "dev interface: lazy and eager loading expose the same public surface" {
  local eager_file="$TEST_TEMP_DIR/eager.txt"
  local lazy_file="$TEST_TEMP_DIR/lazy.txt"

  run zsh -c "
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'
    export ZDX_EAGER_LOAD=1
    source \$ZSH_CUSTOM/functions.zsh
    source \$ZSH_CUSTOM/functions/dev-menu.zsh
    print -rl -- \${(ok)functions[(I)dev-*]} > '$eager_file'
  "
  [ "$status" -eq 0 ]

  run zsh -c "
    export ZSH_CUSTOM='$TEST_SUITE_ROOT'
    export HOME='$HOME'
    export PATH='$PATH'
    source \$ZSH_CUSTOM/functions.zsh
    dev-menu --help >/dev/null 2>&1
    print -rl -- \${(ok)functions[(I)dev-*]} > '$lazy_file'
  "
  [ "$status" -eq 0 ]

  run diff -u "$eager_file" "$lazy_file"
  [ "$status" -eq 0 ]
}
