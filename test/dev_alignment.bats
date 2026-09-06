#!/usr/bin/env bats

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  mkdir -p "$DEV_PROJECT"
}

teardown() {
  cleanup_sandbox
}

capture_completion_arguments() {
  local completion_file="$1"
  local command_name="$2"
  local nested_dev_menu="${3:-0}"

  COMPLETION_FILE="$completion_file" \
    COMPLETION_COMMAND="$command_name" \
    NESTED_DEV_MENU="$nested_dev_menu" \
    zsh -f -c '
      typeset -a words=()
      typeset service=""
      if [[ "$NESTED_DEV_MENU" == "1" ]]; then
        words=(dev-menu "$COMPLETION_COMMAND")
        service=dev-menu
        integer CURRENT=3
      else
        words=("$COMPLETION_COMMAND")
        service="$COMPLETION_COMMAND"
      fi

      _arguments() {
        if [[ "$NESTED_DEV_MENU" == "1" && "${1:-}" == "-C" ]]; then
          state=arguments
          line=("$COMPLETION_COMMAND")
          return 0
        fi

        local completion_argument
        for completion_argument in "$@"; do
          print -r -- "${(qqq)completion_argument}"
        done
      }
      _message() {
        print -r -- "__message__:${(j: :)@}"
      }
      _describe() {
        print -r -- "__describe__:${(j: :)@}"
      }

      source "$COMPLETION_FILE"
    '
}

@test "dev alignment: public parsers reject arguments before dependency probes" {
  run run_zsh '
    _dev_cmd_deps() { print -r -- "definitely-not-installed"; }
    dev-menu dev-update-lock --unknown
  '

  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --unknown"* ]]
  [[ "$output" != *"Missing required dependency"* ]]
}

@test "dev alignment: profile parsers reject arguments before state or UI probes" {
  run run_zsh '
    DEV_PROFILE_DIR=""
    fzf() {
      print -r -- called > "$HOME/profile-fzf-called"
    }
    dev-profile-save --unknown
    result=$?
    [[ ! -e "$HOME/profile-fzf-called" ]] || return 99
    return $result
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --unknown"* ]]
  [[ "$output" != *"profile directory is not configured"* ]]

  run run_zsh '
    fzf() {
      print -r -- called > "$HOME/profile-fzf-called"
    }
    dev-profile-save ../escape
    result=$?
    [[ ! -e "$HOME/profile-fzf-called" ]] || return 99
    return $result
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"Profile names must start"* ]]

  run run_zsh 'dev-profile-save ""'
  [ "$status" -eq 2 ]
  [[ "$output" == *"A profile name is required"* ]]

  run run_zsh '
    DEV_PROFILE_DIR=""
    dev-profile-run first second
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"accepts a single profile name"* ]]
  [[ "$output" != *"profile directory is not configured"* ]]

  run run_zsh '
    DEV_PROFILE_DIR=""
    dev-profile-delete first second
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"accepts a single profile name"* ]]
  [[ "$output" != *"profile directory is not configured"* ]]

  run run_zsh '
    DEV_PROFILE_DIR=""
    dev-profile-list extra
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: extra"* ]]
  [[ "$output" != *"profile directory is not configured"* ]]
}

@test "dev alignment: ty and pyright use project-aware runners" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
case "${4:-}" in
  ty|pyright) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  cat > "$DEV_PROJECT/.venv/bin/ty" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  cat > "$DEV_PROJECT/.venv/bin/pyright" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod +x \
    "$DEV_PROJECT/.venv/bin/python" \
    "$DEV_PROJECT/.venv/bin/ty" \
    "$DEV_PROJECT/.venv/bin/pyright"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pyproject_has_dep() { return 0; }

    local -a reply=()
    _dev_python_tool_runner ty || return 1
    print -r -- "ty:${(j: :)reply}"

    reply=()
    _dev_python_tool_runner pyright || return 1
    print -r -- "pyright:${(j: :)reply}"

    [[ -z "$(_dev_cmd_deps dev-run-ty)" ]]
    [[ -z "$(_dev_cmd_deps dev-run-pyright)" ]]
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"ty:$DEV_PROJECT/.venv/bin/ty"* ]]
  [[ "$output" == *"pyright:$DEV_PROJECT/.venv/bin/pyright"* ]]
}

@test "dev alignment: declared Python tools never fall through to global runners" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["ruff>=1"]
EOF
  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
case "${4:-}" in
  ruff) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  export PROJECT_RUNNER_LOG="$TEST_TEMP_DIR/project-runner.log"

  for tool_name in ruff uv uvx; do
    cat > "$TEST_MOCK_BIN/$tool_name" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$PROJECT_RUNNER_LOG"
exit 0
EOF
    chmod +x "$TEST_MOCK_BIN/$tool_name"
  done

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_ALLOW_EPHEMERAL=1
    local -a reply=()
    _dev_python_tool_runner ruff
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"declared but is not installed"* ]]
  [[ "$output" == *"uv sync --all-groups"* ]]
  [ ! -e "$PROJECT_RUNNER_LOG" ]
}

@test "dev alignment: inventory runners require the project virtual environment" {
  mkdir -p "$DEV_PROJECT/venv-case/.venv/bin"
  cat > "$DEV_PROJECT/venv-case/.venv/bin/python" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod +x "$DEV_PROJECT/venv-case/.venv/bin/python"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  cat > "$TEST_MOCK_BIN/pip-licenses" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/pip-licenses"

  mkdir -p \
    "$DEV_PROJECT/declared-case/.venv/bin" \
    "$DEV_PROJECT/ephemeral-case/.venv/bin" \
    "$DEV_PROJECT/global-case/.venv/bin"
  cat > "$DEV_PROJECT/declared-case/pyproject.toml" <<'EOF'
[project]
dependencies = ["pip-licenses>=5"]
EOF
  local case_name
  for case_name in declared-case ephemeral-case global-case; do
    cat > "$DEV_PROJECT/$case_name/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
case "${4:-}" in
  piplicenses) exit 1 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$DEV_PROJECT/$case_name/.venv/bin/python"
  done

  run run_zsh '
    cd "$DEV_PROJECT/venv-case"
    local -a reply=()
    DEV_ALLOW_EPHEMERAL=0
    _dev_project_python_tool_runner pip-licenses piplicenses
    print -r -- "runner:${(j: :)reply}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.venv/bin/python -I -m piplicenses"* ]]

  run run_zsh '
    cd "$DEV_PROJECT/declared-case"
    local -a reply=()
    DEV_ALLOW_EPHEMERAL=1
    _dev_project_python_tool_runner pip-licenses piplicenses
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"declared but is not importable"* ]]
  [[ "$output" == *"uv sync --all-groups"* ]]

  run run_zsh '
    cd "$DEV_PROJECT/ephemeral-case"
    local -a reply=()
    DEV_ALLOW_EPHEMERAL=1
    _dev_project_python_tool_runner pip-licenses piplicenses
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed in the project virtual environment"* ]]
  [[ "$output" == *"Ephemeral runners are disabled"* ]]
  [[ "$output" != *"downloads and executes remote code"* ]]

  run run_zsh '
    cd "$DEV_PROJECT/global-case"
    local -a reply=()
    DEV_ALLOW_EPHEMERAL=0
    _dev_project_python_tool_runner pip-licenses piplicenses
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed in the project virtual environment"* ]]
  [[ "$output" != *"Using the installed pip-licenses binary"* ]]
}

@test "dev alignment: Node menu availability mirrors the runtime runner" {
  mkdir -p "$DEV_PROJECT/node_modules/.bin"
  : > "$DEV_PROJECT/node_modules/.bin/eslint"
  chmod +x "$DEV_PROJECT/node_modules/.bin/eslint"
  : > "$DEV_PROJECT/.pre-commit-config.yaml"

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_ALLOW_EPHEMERAL=0
    _dev_node_tool_available eslint || return 1

    command() {
      if [[ "$1" == "-v" && "$2" == (markdownlint|npx) ]]; then
        return 1
      fi
      builtin command "$@"
    }
    _dev_menu_missing_requirements dev-run-markdownlint
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"markdownlint (project/local or ephemeral opt-in)"* ]]

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "$1" == "-v" && "$2" == "prettier" ]]; then
        return 1
      fi
      if [[ "$1" == "-v" && "$2" == "npx" ]]; then
        return 0
      fi
      builtin command "$@"
    }

    DEV_ALLOW_EPHEMERAL=0
    _dev_node_tool_available prettier && return 1
    DEV_ALLOW_EPHEMERAL=1
    _dev_node_tool_available prettier
  '

  [ "$status" -eq 0 ]
}

@test "dev alignment: batch metadata exposes only independent safe tasks" {
  run run_zsh '_dev_menu_batch_rows'

  [ "$status" -eq 0 ]
  [[ "$output" == *"|dev-run-ruff|"* ]]
  [[ "$output" == *"|dev-run-tests|"* ]]
  [[ "$output" == *"|dev-update-deps-dry|"* ]]
  [[ "$output" != *"|dev-run-all-checks|"* ]]
  [[ "$output" != *"|dev-run-ruff-format|"* ]]
  [[ "$output" != *"|dev-profile-"* ]]
  [[ "$output" != *"|dev-clean-"* ]]
  [[ "$output" != *"|venv-"* ]]
}

@test "dev alignment: multi-select rejects an injected unsafe row" {
  run run_zsh '
    local dispatch_log="$HOME/dispatched"
    fzf() {
      command cat >/dev/null
      print -r -- \
        "  Clean Everything|dev-clean-all|Injected destructive action."
      return 0
    }
    _dev_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
    }

    dev-menu --multi
    [[ ! -e "$dispatch_log" ]]
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping non-batch-eligible task"* ]]
  [[ "$output" == *"No runnable tasks were selected"* ]]
}

@test "dev alignment: profile saving receives the batch-eligible menu model" {
  run run_zsh '
    cd "$DEV_PROJECT"
    fzf() {
      command cat > "$HOME/profile-picker-input"
      return 130
    }

    dev-profile-save nightly
    command grep -q "|dev-run-tests|" "$HOME/profile-picker-input"
    ! command grep -qE \
      "\|(dev-clean-|dev-profile-|venv-|dev-run-ruff-format)" \
      "$HOME/profile-picker-input"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled"* ]]
}

@test "dev alignment: fzf failures are not reported as cancellation" {
  run run_zsh '
    fzf() {
      command cat >/dev/null
      return 2
    }
    dev-menu
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Unable to open the interactive Dev menu"* ]]

  mkdir -p "$DEV_PROJECT/.dev-suite-profiles"
  chmod 700 "$DEV_PROJECT/.dev-suite-profiles"
  printf 'dev-run-tests\n' \
    > "$DEV_PROJECT/.dev-suite-profiles/nightly.profile"
  chmod 600 "$DEV_PROJECT/.dev-suite-profiles/nightly.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    fzf() {
      command cat >/dev/null
      return 2
    }
    dev-profile-run
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Profile selection failed"* ]]
  [[ "$output" != *"Cancelled"* ]]
}

@test "dev alignment: invalid profile configuration is not a no-op" {
  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_PROFILE_DIR=""
    dev-profile-list
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"profile directory is not configured"* ]]
  [[ "$output" != *"No profiles saved"* ]]
}

@test "dev alignment: profiles reject symlinks hard links and public modes" {
  local symlink_dir="$DEV_PROJECT/profiles-symlink"
  mkdir -p "$symlink_dir"
  chmod 700 "$symlink_dir"
  printf 'dev-run-tests\n' > "$DEV_PROJECT/symlink-target.profile"
  chmod 600 "$DEV_PROJECT/symlink-target.profile"
  ln -s "$DEV_PROJECT/symlink-target.profile" "$symlink_dir/linked.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_PROFILE_DIR="$DEV_PROJECT/profiles-symlink"
    dev-profile-list
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing an unsafe profile"* ]]

  local hardlink_dir="$DEV_PROJECT/profiles-hardlink"
  mkdir -p "$hardlink_dir"
  chmod 700 "$hardlink_dir"
  printf 'dev-run-tests\n' > "$hardlink_dir/first.profile"
  chmod 600 "$hardlink_dir/first.profile"
  ln "$hardlink_dir/first.profile" "$hardlink_dir/second.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_PROFILE_DIR="$DEV_PROJECT/profiles-hardlink"
    dev-profile-list
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"multiply linked"* ]]

  local public_dir="$DEV_PROJECT/profiles-public"
  mkdir -p "$public_dir"
  chmod 700 "$public_dir"
  printf 'dev-run-tests\n' > "$public_dir/public.profile"
  chmod 644 "$public_dir/public.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_PROFILE_DIR="$DEV_PROJECT/profiles-public"
    dev-profile-list
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-private"* ]]
}

@test "dev alignment: profile inventory content and size are bounded" {
  local inventory_dir="$DEV_PROJECT/profiles-inventory"
  mkdir -p "$inventory_dir"
  chmod 700 "$inventory_dir"
  local index
  for index in $(seq 1 101); do
    printf 'dev-run-tests\n' > "$inventory_dir/profile-${index}.profile"
    chmod 600 "$inventory_dir/profile-${index}.profile"
  done

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_PROFILE_DIR="$DEV_PROJECT/profiles-inventory"
    dev-profile-list
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"100-file safety limit"* ]]

  local size_dir="$DEV_PROJECT/profiles-size"
  mkdir -p "$size_dir"
  chmod 700 "$size_dir"
  head -c 8193 /dev/zero | tr '\0' x > "$size_dir/large.profile"
  chmod 600 "$size_dir/large.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_PROFILE_DIR="$DEV_PROJECT/profiles-size"
    dev-profile-list
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"8192-byte safety limit"* ]]

  local tasks_dir="$DEV_PROJECT/profiles-tasks"
  mkdir -p "$tasks_dir"
  chmod 700 "$tasks_dir"
  for index in $(seq 1 65); do
    printf 'dev-run-tests\n' >> "$tasks_dir/many.profile"
  done
  chmod 600 "$tasks_dir/many.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_PROFILE_DIR="$DEV_PROJECT/profiles-tasks"
    dev-profile-run many
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"64-task safety limit"* ]]
}

@test "dev alignment: stored profiles cannot dispatch destructive tasks" {
  local profile_dir="$DEV_PROJECT/.dev-suite-profiles"
  mkdir -p "$profile_dir"
  chmod 700 "$profile_dir"
  printf 'dev-clean-all\n' > "$profile_dir/unsafe.profile"
  chmod 600 "$profile_dir/unsafe.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    local dispatch_log="$HOME/profile-dispatch"
    _dev_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
    }
    dev-profile-run unsafe
    result=$?
    [[ ! -e "$dispatch_log" ]] || return 99
    return $result
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-batch-eligible task: dev-clean-all"* ]]
}

@test "dev alignment: profile deletion revalidates identity after confirmation" {
  local profile_dir="$DEV_PROJECT/.dev-suite-profiles"
  mkdir -p "$profile_dir"
  chmod 700 "$profile_dir"
  printf 'dev-run-tests\n' > "$profile_dir/nightly.profile"
  chmod 600 "$profile_dir/nightly.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    local expected_profile="$DEV_PROJECT/.dev-suite-profiles/nightly.profile"
    _dev_confirm() {
      command rm -- "$profile_path"
      print -r -- "dev-check-health" > "$profile_path"
      command chmod 600 -- "$profile_path"
      return 0
    }
    dev-profile-delete nightly
    result=$?
    [[ -f "$expected_profile" ]] || return 99
    command grep -qx "dev-check-health" "$expected_profile" || return 98
    return $result
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed during confirmation"* ]]
}

@test "dev alignment: profile overwrite revalidates identity before publication" {
  local profile_dir="$DEV_PROJECT/.dev-suite-profiles"
  mkdir -p "$profile_dir"
  chmod 700 "$profile_dir"
  printf 'dev-run-tests\n' > "$profile_dir/nightly.profile"
  chmod 600 "$profile_dir/nightly.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    local expected_profile="$DEV_PROJECT/.dev-suite-profiles/nightly.profile"
    fzf() {
      local -a rows=("${(@f)$(command cat)}")
      local row
      for row in "${rows[@]}"; do
        [[ "$row" == *"|dev-run-tests|"* ]] || continue
        print -r -- "$row"
        break
      done
      return 0
    }
    _dev_confirm() {
      command rm -- "$profile_path"
      print -r -- "dev-check-health" > "$profile_path"
      command chmod 600 -- "$profile_path"
      return 0
    }
    dev-profile-save nightly
    result=$?
    command grep -qx "dev-check-health" "$expected_profile" || return 98
    return $result
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed during confirmation"* ]]
}

@test "dev alignment: profile saving refuses a selection outside its snapshot" {
  run run_zsh '
    cd "$DEV_PROJECT"
    fzf() {
      command cat >/dev/null
      print -r -- "  Forged Row|dev-run-tests|Forged description."
      return 0
    }
    dev-profile-save nightly
    result=$?
    [[ ! -e "$DEV_PROJECT/.dev-suite-profiles/nightly.profile" ]] \
      || return 98
    return $result
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"outside the task snapshot"* ]]
  [[ "$output" == *"No runnable tasks were selected"* ]]
}

@test "dev alignment: nested deprecated aliases warn and still forward" {
  run run_zsh '
    dev-check-health() {
      print -r -- "canonical:$*"
    }
    _dev_dispatch check-health --report
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"'check-health' is deprecated"* ]]
  [[ "$output" == *"canonical:--report"* ]]
}

@test "dev alignment: venv-python compatibility wrapper delegates coherently" {
  run env \
    HOME="$HOME" \
    ZDX_TEST_ROOT="$TEST_SUITE_ROOT" \
    zsh -f -c '
      source "$ZDX_TEST_ROOT/functions/dev-menu.zsh" || exit
      typeset -f venv-python >/dev/null || exit 1
      _dev_delegate_py() {
        print -r -- "delegated:$*"
      }
      venv-python install 3.13
    '

  [ "$status" -eq 0 ]
  [[ "$output" == *"'venv-python' is deprecated"* ]]
  [[ "$output" == *"delegated:venv-python install 3.13"* ]]
}

@test "dev alignment: bounded configuration rejects invalid values" {
  run run_zsh '
    DEV_SCAN_DEPTH=0
    _dev_validate_scan_depth
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_SCAN_DEPTH"* ]]

  run run_zsh '
    DEV_BACKUP_RETENTION=101
    _dev_validate_backup_retention
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_BACKUP_RETENTION"* ]]

  run run_zsh '
    DEV_ALLOW_EPHEMERAL=true
    _dev_validate_allow_ephemeral
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"either 0 or 1"* ]]
}

@test "dev alignment: the tomllib capability probe follows PATH changes" {
  export TOML_PROBE_MARKER="$TEST_TEMP_DIR/tomllib-ready"
  cat > "$TEST_MOCK_BIN/python3" <<'EOF'
#!/usr/bin/env bash
if [[ -e "$TOML_PROBE_MARKER" ]]; then
  exit 0
fi
: > "$TOML_PROBE_MARKER"
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/python3"

  run env ZSH_CUSTOM="$TEST_SUITE_ROOT" NO_COLOR=1 TERM=dumb \
    zsh -f -c '
    source "$ZSH_CUSTOM/functions/dev-menu.zsh" || exit
    _dev_require_python_toml
    local -i first_status=$?
    _dev_require_python_toml
    local -i second_status=$?
    (( first_status == 1 && second_status == 0 ))
  '

  [ "$status" -eq 0 ]
}

@test "dev alignment: invalid context configuration stops before fzf" {
  run run_zsh '
    DEV_SCAN_DEPTH=0
    fzf() {
      print -r -- "CALLED" >> "$HOME/fzf-called"
    }
    dev-menu
    result=$?
    [[ ! -e "$HOME/fzf-called" ]] || return 99
    return $result
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_SCAN_DEPTH"* ]]

  run run_zsh '
    DEV_ALLOW_EPHEMERAL=true
    fzf() {
      print -r -- "CALLED" >> "$HOME/fzf-called"
    }
    dev-menu
    result=$?
    [[ ! -e "$HOME/fzf-called" ]] || return 99
    return $result
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_ALLOW_EPHEMERAL"* ]]
}

@test "dev alignment: project probes prune generated and nested repositories" {
  mkdir -p \
    "$DEV_PROJECT/vendor/library" \
    "$DEV_PROJECT/build/generated" \
    "$DEV_PROJECT/nested/.git"
  : > "$DEV_PROJECT/vendor/library/vendor.py"
  : > "$DEV_PROJECT/build/generated/built.py"
  : > "$DEV_PROJECT/nested/.git/HEAD"
  : > "$DEV_PROJECT/nested/source.py"

  run run_zsh '
    cd "$DEV_PROJECT"
    ! _dev_project_has_files "*.py"
  '
  [ "$status" -eq 0 ]

  : > "$DEV_PROJECT/source.py"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_project_has_files "*.py"
  '
  [ "$status" -eq 0 ]
}

@test "dev alignment: test discovery prunes generated trees and nested repositories" {
  mkdir -p \
    "$DEV_PROJECT/build/generated" \
    "$DEV_PROJECT/node_modules/dependency" \
    "$DEV_PROJECT/nested/.git"
  : > "$DEV_PROJECT/build/generated/test_built.py"
  : > "$DEV_PROJECT/node_modules/dependency/test_dependency.py"
  : > "$DEV_PROJECT/nested/.git/HEAD"
  : > "$DEV_PROJECT/nested/test_nested.py"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_has_tests
    print -r -- "probe=$?"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"probe=1"* ]]

  mkdir -p "$DEV_PROJECT/tests"
  : > "$DEV_PROJECT/tests/test_project.py"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_has_tests
    print -r -- "probe=$?"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"probe=0"* ]]
}

@test "dev alignment: root pytest configuration activates test discovery precisely" {
  printf '[metadata]\nname = demo\n' > "$DEV_PROJECT/setup.cfg"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_has_tests
    print -r -- "generic-setup=$?"
    print -r -- "[tool:pytest]" >> setup.cfg
    _dev_has_tests
    print -r -- "pytest-setup=$?"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"generic-setup=1"* ]]
  [[ "$output" == *"pytest-setup=0"* ]]

  command rm -f -- "$DEV_PROJECT/setup.cfg"
  printf '[pytest]\n' > "$DEV_PROJECT/tox.ini"
  run run_zsh 'cd "$DEV_PROJECT" && _dev_has_tests'
  [ "$status" -eq 0 ]

  command rm -f -- "$DEV_PROJECT/tox.ini"
  printf '[tool.pytest.ini_options]\naddopts = "-q"\n' \
    > "$DEV_PROJECT/pyproject.toml"
  run run_zsh 'cd "$DEV_PROJECT" && _dev_has_tests'
  [ "$status" -eq 0 ]

  command rm -f -- "$DEV_PROJECT/pyproject.toml"
  : > "$DEV_PROJECT/pytest.ini"
  run run_zsh 'cd "$DEV_PROJECT" && _dev_has_tests'
  [ "$status" -eq 0 ]

  command rm -f -- "$DEV_PROJECT/pytest.ini"
  printf '[pytest]\npython_files = ["specs_*.py"]\n' \
    > "$DEV_PROJECT/pytest.toml"
  run run_zsh 'cd "$DEV_PROJECT" && _dev_has_tests'
  [ "$status" -eq 0 ]

  command rm -f -- "$DEV_PROJECT/pytest.toml"
  printf '[pytest]\npython_files = specs_*.py\n' \
    > "$DEV_PROJECT/.pytest.ini"
  : > "$DEV_PROJECT/specs_demo.py"
  run run_zsh 'cd "$DEV_PROJECT" && _dev_has_tests'
  [ "$status" -eq 0 ]

  command rm -f -- "$DEV_PROJECT/.pytest.ini"
  : > "$DEV_PROJECT/.pytest.toml"
  run run_zsh 'cd "$DEV_PROJECT" && _dev_has_tests'
  [ "$status" -eq 0 ]
}

@test "dev alignment: test discovery errors propagate instead of becoming no-tests" {
  mkdir -p "$DEV_PROJECT/.venv"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_project_has_files() {
      _dev_error "Synthetic project discovery failure."
      return 2
    }
    _dev_has_tests
    print -r -- "internal=$?"
    dev-run-tests
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"internal=2"* ]]
  [[ "$output" == *"Synthetic project discovery failure."* ]]
  [[ "$output" != *"No test files or pytest configuration found"* ]]
}

@test "dev alignment: explicitly empty state overrides survive source time" {
  run env \
    HOME="$HOME" \
    DEV_PROFILE_DIR="" \
    ZDX_TEST_ROOT="$TEST_SUITE_ROOT" \
    zsh -f -c '
      source "$ZDX_TEST_ROOT/functions/dev-menu.zsh" || exit
      print -r -- "profile-dir=<$DEV_PROFILE_DIR>"
    '

  [ "$status" -eq 0 ]
  [ "$output" = "profile-dir=<>" ]
}

@test "dev alignment: diff rendering keeps UI off stdout" {
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env sh
if [ "${1:-}" = "diff" ]; then
  printf '%s\n' 'diff --git a/demo b/demo' '-old' '+new'
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/git"

  run run_zsh '
    _dev_show_diff demo > "$HOME/diff-data" 2> "$HOME/diff-ui"
    [[ ! -s "$HOME/diff-data" ]]
    [[ -s "$HOME/diff-ui" ]]
  '

  [ "$status" -eq 0 ]
}

@test "dev alignment: loader refuses a symlinked mandatory module" {
  local copied_root="$TEST_TEMP_DIR/copied"
  mkdir -p "$copied_root/functions"
  cp "$TEST_SUITE_ROOT/functions/dev-menu.zsh" \
    "$copied_root/functions/dev-menu.zsh"
  ln -s "$TEST_SUITE_ROOT/functions/dev-common.zsh" \
    "$copied_root/functions/dev-common.zsh"

  run env COPIED_ROOT="$copied_root" zsh -f -c '
    source "$COPIED_ROOT/functions/dev-menu.zsh"
    source_status=$?
    (( ! ${+_DEV_MENU_SOURCED} )) || exit 99
    exit $source_status
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to load dev-common.zsh"* ]]
}

@test "dev alignment: completion covers direct and nested command options" {
  local completion="$TEST_SUITE_ROOT/completions/_dev-menu"

  grep -q '^#compdef dev-menu dev-check-health ' "$completion"
  grep -q 'dev-profile-delete dev-clean-py' "$completion"
  grep -q '::profile:_dev_menu_profiles' "$completion"
  grep -Fq 'words[1]' "$completion"
  grep -q '== "dev-menu"' "$completion"
  grep -q -- '--fail-under=' "$completion"
  grep -q -- '--major-only' "$completion"
  grep -q -- '--keep-build' "$completion"
  grep -q -- '--python=' "$completion"
  grep -q -- '--init' "$completion"
  grep -Fq '${words[(I)--fix]}' "$completion"
  grep -q 'Confirm automatic remediation' "$completion"

  run env COMPLETION="$completion" zsh -f -c '
    typeset -a words=(dev-run-audit)
    _arguments() { print -rl -- "$@"; }
    source "$COMPLETION"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"--fix[Upgrade vulnerable direct dependencies]"* ]]
  [[ "$output" != *"Confirm automatic remediation"* ]]

  run env COMPLETION="$completion" zsh -f -c '
    typeset -a words=(dev-run-audit --fix)
    _arguments() { print -rl -- "$@"; }
    source "$COMPLETION"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"--yes[Confirm automatic remediation]"* ]]

  run env COMPLETION="$completion" zsh -f -c '
    typeset -a words=(dev-menu dev-export-deps --)
    integer CURRENT=3
    _arguments() {
      if [[ "${1:-}" == "-C" ]]; then
        state=arguments
        line=(dev-export-deps --)
        return 0
      fi
      print -rl -- "$@"
    }
    source "$COMPLETION"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dev[Include the dev dependency group]"* ]]
  [[ "$output" == *"--output="* ]]
}

@test "dev alignment: delegated venv completions match the Python owner" {
  local dev_completion="$TEST_SUITE_ROOT/completions/_dev-menu"
  local py_completion="$TEST_SUITE_ROOT/completions/_py-menu"
  local -a delegated_commands=(
    venv-list
    venv-create
    venv-activate
    venv-info
    venv-rebuild
    venv-remove
    venv-python-list
    venv-python-install
    venv-python-pin
  )

  local command_name
  local dev_direct_specs dev_nested_specs py_specs
  local dev_direct_status dev_nested_status py_status
  for command_name in "${delegated_commands[@]}"; do
    dev_direct_specs=$(capture_completion_arguments \
      "$dev_completion" "$command_name")
    dev_direct_status=$?
    dev_nested_specs=$(capture_completion_arguments \
      "$dev_completion" "$command_name" 1)
    dev_nested_status=$?
    py_specs=$(capture_completion_arguments \
      "$py_completion" "$command_name")
    py_status=$?

    if [[ "$dev_direct_status" -ne 0 || "$dev_nested_status" -ne 0 \
      || "$py_status" -ne 0 ]]; then
      printf \
        'Could not capture completion grammar for %s (direct=%d, nested=%d, py=%d)\n' \
        "$command_name" "$dev_direct_status" "$dev_nested_status" \
        "$py_status" >&2
      return 1
    fi

    if [[ "$dev_direct_specs" != "$py_specs" \
      || "$dev_nested_specs" != "$py_specs" ]]; then
      printf 'Delegated completion drift for %s\n' "$command_name" >&2
      diff -u \
        <(printf '%s\n' "$py_specs") \
        <(printf '%s\n' "$dev_direct_specs") >&2 || true
      diff -u \
        <(printf '%s\n' "$py_specs") \
        <(printf '%s\n' "$dev_nested_specs") >&2 || true
      return 1
    fi
  done
}

@test "dev alignment: dependency detection parses TOML and normalizes names" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = 'demo'
description = 'ruff>=1 is mentioned here but is not a dependency'
dependencies = ['Requests(>=2)']

[project.optional-dependencies]
types = ['Py_Right>=1']

[dependency-groups]
test = ['pytest_cov>=5', { include-group = 'types' }]

[tool.demo]
example = 'coverage>=7 is also only prose'

# dependencies = ['ruff>=1', 'coverage>=7']
EOF

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pyproject_has_dep requests || return 1
    _dev_pyproject_has_dep py-right || return 2
    _dev_pyproject_has_dep pytest-cov || return 3
    _dev_pyproject_has_dep ruff && return 91
    _dev_pyproject_has_dep coverage && return 92
    _dev_pyproject_has_dep pytest && return 93
    local -a reply=()
    _dev_pyproject_all_deps || return 4
    (( ${reply[(Ie)Requests]} )) || return 5
    return 0
  '

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dev alignment: malformed TOML blocks Python runner fallback" {
  printf '%s\n' '[project' 'dependencies = ["ruff>=1"]' \
    > "$DEV_PROJECT/pyproject.toml"
  export PYTHON_RUNNER_LOG="$TEST_TEMP_DIR/python-runner.log"

  for tool_name in ruff uv uvx; do
    cat > "$TEST_MOCK_BIN/$tool_name" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$PYTHON_RUNNER_LOG"
exit 0
EOF
    chmod +x "$TEST_MOCK_BIN/$tool_name"
  done

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_ALLOW_EPHEMERAL=1
    local -a reply=()
    _dev_python_tool_runner ruff
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse dependency metadata"* ]]
  [ ! -e "$PYTHON_RUNNER_LOG" ]

  local parser_stdout="$TEST_TEMP_DIR/parser.stdout"
  local parser_stderr="$TEST_TEMP_DIR/parser.stderr"
  run run_zsh \
    "cd '$DEV_PROJECT' && _dev_pyproject_main_deps >'$parser_stdout' 2>'$parser_stderr'"

  [ "$status" -eq 1 ]
  [ ! -s "$parser_stdout" ]
  grep -Fq 'Could not parse pyproject.toml safely.' "$parser_stderr"

  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = "ruff>=1"
EOF
  : > "$parser_stdout"
  : > "$parser_stderr"

  run run_zsh \
    "cd '$DEV_PROJECT' && _dev_pyproject_main_deps >'$parser_stdout' 2>'$parser_stderr'"

  [ "$status" -eq 1 ]
  [ ! -s "$parser_stdout" ]
  grep -Fq 'Could not parse pyproject.toml safely.' "$parser_stderr"
}

@test "dev alignment: coverage selection honors normalized TOML dependencies" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  : > "$DEV_PROJECT/test_demo.py"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = 'demo'
dependencies = []

[dependency-groups]
test = ['pytest_cov>=5']
EOF
  export COVERAGE_RUNNER_LOG="$TEST_TEMP_DIR/coverage-runner.log"

  cat > "$DEV_PROJECT/.venv/bin/pytest" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COVERAGE_RUNNER_LOG"
exit 0
EOF
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  exit 0
fi
if [[ "${1:-}" == "-I" && "${2:-}" == "-m" \
  && "${3:-}" == "pytest" ]]; then
  shift 3
  printf '%s\n' "$*" >> "$COVERAGE_RUNNER_LOG"
  exit 0
fi
exit 97
EOF
  chmod +x \
    "$DEV_PROJECT/.venv/bin/pytest" "$DEV_PROJECT/.venv/bin/python"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-coverage'

  [ "$status" -eq 0 ]
  grep -Fq -- \
    '--cov --cov-report=term-missing' "$COVERAGE_RUNNER_LOG"
  ! grep -Fq 'coverage run' "$COVERAGE_RUNNER_LOG"
}

@test "dev alignment: host Python metadata parsers ignore project shadow modules" {
  export SHADOW_IMPORT_LOG="$TEST_TEMP_DIR/python-shadow-imports.log"
  export TMPDIR="$TEST_TEMP_DIR/python-cache"
  mkdir -m 700 "$TMPDIR"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
dependencies = ["requests>=2"]
EOF

  local module_name
  for module_name in tomllib pathlib json; do
    cat > "$DEV_PROJECT/${module_name}.py" <<EOF
with open("$SHADOW_IMPORT_LOG", "a", encoding="utf-8") as marker:
    marker.write("$module_name\n")
raise RuntimeError("project shadow module executed")
EOF
  done

  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u
output_file=""
while (( $# > 0 )); do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$output_file" ]] || exit 97
printf '%s\n' '{"info":{"version":"3.2.1"}}' > "$output_file"
EOF
  chmod +x "$TEST_MOCK_BIN/curl"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_require_python_toml || return 1
    _dev_pyproject_has_dep requests || return 2
    local dependencies
    dependencies=$(_dev_pyproject_main_deps) || return 3
    [[ "$dependencies" == "requests" ]] || return 4

    local latest=""
    {
      latest=$(_dev_pypi_latest requests) || return 5
    } always {
      _dev_pypi_cache_cleanup
    }
    [[ "$latest" == "3.2.1" ]]
  '

  [ "$status" -eq 0 ]
  [ ! -e "$SHADOW_IMPORT_LOG" ]
}

@test "dev alignment: health ignores project packaging and fails closed without it" {
  export SHADOW_PACKAGING_LOG="$TEST_TEMP_DIR/packaging-shadow.log"
  cat > "$DEV_PROJECT/packaging.py" <<EOF
with open("$SHADOW_PACKAGING_LOG", "w", encoding="utf-8") as marker:
    marker.write("executed\n")
raise RuntimeError("project packaging module executed")
EOF
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
requires-python = ">=3.0"
dependencies = []
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' 'Python 3.12.1'
elif [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  if [[ "${3:-}" == *'sys.implementation.name'* ]]; then
    printf '%s\n' 'cpython|3.12.1'
  fi
elif [[ "${1:-}" == "-I" && "${2:-}" == "-" ]]; then
  printf '%s\n' 'unknown'
elif [[ "${1:-}" == "-" ]]; then
  printf '%s\n' 'executed' > "$SHADOW_PACKAGING_LOG"
  printf '%s\n' 'yes'
else
  exit 98
fi
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'uv 0.0.0-test'
EOF
  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' '200'
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/curl"

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-health'

  [ "$status" -eq 1 ]
  [ ! -e "$SHADOW_PACKAGING_LOG" ]
  [[ "$output" == *"Could not validate requires-python inside the isolated .venv."* ]]
}

@test "dev alignment: health fails closed on invalid or oversized TOML" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  ln -s "$(command -v python3)" "$DEV_PROJECT/.venv/bin/python"
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'uv 0.0.0-test'
EOF
  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' '200'
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/curl"

  printf '%s\n' '[project' 'name = "broken"' \
    > "$DEV_PROJECT/pyproject.toml"
  touch "$DEV_PROJECT/uv.lock"

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-health'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse pyproject.toml safely."* ]]
  [[ "$output" == *"pyproject.toml is present but could not be parsed safely."* ]]
  [[ "$output" != *"✔ pyproject.toml found."* ]]

  command truncate -s 2097153 "$DEV_PROJECT/pyproject.toml"
  touch "$DEV_PROJECT/uv.lock"

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-health'

  [ "$status" -eq 1 ]
  [[ "$output" == *"larger than 2 MiB"* ]]
  [[ "$output" == *"pyproject.toml is present but could not be parsed safely."* ]]
  [[ "$output" != *"✔ pyproject.toml found."* ]]
}

@test "dev alignment: health verifies lock freshness offline" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = []
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'Python 3.12.10' ;;
  -I) printf '%s\n' 'cpython|3.12.10' ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  export UV_HEALTH_LOG="$TEST_TEMP_DIR/uv-health.log"
  export UV_LOCK_STATUS=0

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_HEALTH_LOG"
case "$*" in
  "lock --check --offline --no-cache") exit "${UV_LOCK_STATUS:-0}" ;;
  "--version") printf '%s\n' 'uv 0.0.0-test' ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 0 ]
  grep -Fxq 'lock --check --offline --no-cache' "$UV_HEALTH_LOG"
  [[ "$output" == *"verified offline without cache writes"* ]]

  export UV_LOCK_STATUS=9
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"uv.lock failed the offline freshness check"* ]]

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "uv" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"uv is required to validate uv.lock."* ]]
}

@test "dev alignment: health treats unknown requires-python validation as an issue" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
requires-python = ">=3.12"
dependencies = []
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  mkdir -p "$DEV_PROJECT/.venv/bin"
  export VENV_COMPATIBILITY=yes

  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    printf '%s\n' 'Python 3.12.10'
    ;;
  -I)
    if [[ "${2:-}" == "-c" ]]; then
      printf '%s\n' 'cpython|3.12.10'
    elif [[ "${2:-}" == "-" ]]; then
      printf '%s\n' "${VENV_COMPATIBILITY:-unknown}"
    else
      exit 97
    fi
    ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "lock --check --offline --no-cache") exit 0 ;;
  "--version") printf '%s\n' 'uv 0.0.0-test' ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"satisfies requires-python"* ]]

  export VENV_COMPATIBILITY=unknown
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not validate requires-python inside the isolated .venv."* ]]
}

@test "dev alignment: health compares uv Python pins by exact components" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = []
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  mkdir -p "$DEV_PROJECT/.venv/bin"

  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'Python 3.12.10' ;;
  -I) printf '%s\n' 'cpython|3.12.10' ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "lock --check --offline --no-cache") exit 0 ;;
  "--version") printf '%s\n' 'uv 0.0.0-test' ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  printf '3.12.1\n' > "$DEV_PROJECT/.python-version"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match the venv (3.12.10)"* ]]

  printf 'cpython-3.12\n' > "$DEV_PROJECT/.python-version"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *".python-version (cpython-3.12) matches"* ]]

  printf '3.12\n3.13\n' > "$DEV_PROJECT/.python-version"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"must contain exactly one Python request"* ]]
}

@test "dev alignment: health rejects a symlinked venv without execution" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = []
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  export EXTERNAL_VENV_LOG="$TEST_TEMP_DIR/external-venv.log"
  mkdir -p "$TEST_TEMP_DIR/external-venv/bin"
  cat > "$TEST_TEMP_DIR/external-venv/bin/python" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$EXTERNAL_VENV_LOG"
printf '%s\n' 'cpython|3.12.10'
EOF
  chmod +x "$TEST_TEMP_DIR/external-venv/bin/python"
  ln -s "$TEST_TEMP_DIR/external-venv" "$DEV_PROJECT/.venv"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "lock --check --offline --no-cache") exit 0 ;;
  "--version") printf '%s\n' 'uv 0.0.0-test' ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *".venv exists but is unsafe"* ]]
  [ ! -e "$EXTERNAL_VENV_LOG" ]

  rm "$DEV_PROJECT/.venv"
  ln -s "$TEST_TEMP_DIR/missing-venv" "$DEV_PROJECT/.venv"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *".venv exists but is unsafe"* ]]
  [ ! -e "$EXTERNAL_VENV_LOG" ]
}

@test "dev alignment: health fails closed on unsafe marker path types" {
  ln -s "$DEV_PROJECT/missing-pyproject" "$DEV_PROJECT/pyproject.toml"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"pyproject.toml must be a readable, non-symlinked regular file"* ]]
  [[ "$output" != *"health check is not applicable"* ]]

  rm "$DEV_PROJECT/pyproject.toml"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = []
EOF
  mkfifo "$DEV_PROJECT/uv.lock"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"uv.lock must be a readable, non-symlinked regular file"* ]]

  rm "$DEV_PROJECT/uv.lock" "$DEV_PROJECT/pyproject.toml"
  mkdir "$DEV_PROJECT/.python-version"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *".python-version must be a readable, non-symlinked regular file"* ]]
  [[ "$output" != *"health check is not applicable"* ]]
}

@test "dev alignment: metadata failures stop detection commands before backends" {
  printf '%s\n' '[project' 'dependencies = ["ty", "pytest-cov"]' \
    > "$DEV_PROJECT/pyproject.toml"
  mkdir -p "$DEV_PROJECT/.venv/bin"
  ln -s "$(command -v python3)" "$DEV_PROJECT/.venv/bin/python"
  : > "$DEV_PROJECT/source.py"
  : > "$DEV_PROJECT/test_demo.py"
  export DETECTION_BACKEND_LOG="$TEST_TEMP_DIR/detection-backends.log"

  local tool_name
  for tool_name in uv ruff ty pyright; do
    cat > "$TEST_MOCK_BIN/$tool_name" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$DETECTION_BACKEND_LOG"
exit 0
EOF
    chmod +x "$TEST_MOCK_BIN/$tool_name"
  done

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-types'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse dependency metadata"* ]]
  [ ! -e "$DETECTION_BACKEND_LOG" ]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-coverage'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse dependency metadata"* ]]
  [ ! -e "$DETECTION_BACKEND_LOG" ]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-all-checks'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse dependency metadata"* ]]
  [ ! -e "$DETECTION_BACKEND_LOG" ]
}
