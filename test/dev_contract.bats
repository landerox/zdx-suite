#!/usr/bin/env bats

setup() {
  load test_helper
  DEV_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/dev-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$DEV_CONTRACT" | sort
}

contract_commands_owned_by_dev() {
  awk -F '\t' '!/^#/ && NF && $4 == "dev" { print $1 }' "$DEV_CONTRACT" | sort
}

assert_contract_matches() {
  local surface_name="$1"
  local actual="$2"
  local expected
  expected=$(contract_commands)

  if [[ "$actual" != "$expected" ]]; then
    echo "Public command drift in: $surface_name" >&2
    diff -u \
      <(printf '%s\n' "$expected") \
      <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

@test "dev contract: fixture freezes 25 unique commands with valid metadata" {
  local count=0
  local command_name module_name risk owner extra

  while IFS=$'\t' read -r command_name module_name risk owner extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))

    [[ "$command_name" =~ ^dev-[a-z0-9-]+$ ]]
    [[ "$module_name" =~ ^dev-[a-z0-9-]+\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive)$ ]]
    [[ "$owner" == "dev" ]]
    [[ -z "$extra" ]]
    [[ -f "$TEST_SUITE_ROOT/functions/dev/$module_name" ]]
  done < "$DEV_CONTRACT"

  [ "$count" -eq 25 ]

  local duplicates
  duplicates=$(contract_commands | uniq -d)
  [ -z "$duplicates" ]
}

@test "dev contract: every dev-owned command is defined by its declared module" {
  local command_name module_name risk owner

  while IFS=$'\t' read -r command_name module_name risk owner; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    [[ "$owner" == "dev" ]] || continue

    if ! grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/dev/$module_name"; then
      echo "$command_name is not defined by $module_name" >&2
      return 1
    fi
  done < "$DEV_CONTRACT"
}

@test "dev contract: every dev-owned public function loads in Zsh" {
  local command_list
  command_list=$(contract_commands_owned_by_dev | tr '\n' ' ')

  run run_zsh "
    local command_name
    for command_name in $command_list; do
      if ! typeset -f \"\$command_name\" &>/dev/null; then
        print -u2 -r -- \"Missing public function: \$command_name\"
        return 1
      fi
    done
  "

  [ "$status" -eq 0 ]
}

@test "dev contract: interactive menu entries match the contract" {
  run run_zsh "
    local capture_file=\"\$HOME/dev-menu.rows\"
    fzf() {
      command cat > \"\$capture_file\"
      return 130
    }

    dev-menu >/dev/null 2>&1
    awk -F '|' '\$2 != \":\" && NF >= 2 { print \$2 }' \
      \"\$capture_file\" | sort
  "

  [ "$status" -eq 0 ]
  assert_contract_matches "interactive menu" "$output"
}

@test "dev contract: dispatcher executes every canonical command" {
  local command_list
  command_list=$(contract_commands | tr '\n' ' ')

  run run_zsh "
    _dev_verify_deps() { return 0; }
    _dev_dispatch_prepare() { return 0; }

    local command_name result
    for command_name in $command_list; do
      functions[\$command_name]='print -r -- \"\$0\"'
      result=\$(_dev_dispatch \"\$command_name\") || {
        print -u2 -r -- \"Dispatcher rejected: \$command_name\"
        return 1
      }
      if [[ \"\$result\" != \"\$command_name\" ]]; then
        print -u2 -r -- \"Dispatcher mismatch for \$command_name: \$result\"
        return 1
      fi
    done
  "

  [ "$status" -eq 0 ]
}

@test "dev contract: help lists exactly the canonical commands" {
  run run_zsh "dev-menu --help"
  [ "$status" -eq 0 ]

  local token
  local -a help_commands=()
  for token in $output; do
    token="${token%,}"
    if [[ "$token" =~ ^(dev|venv)-[a-z0-9-]+$ && "$token" != "dev-menu" ]]; then
      help_commands+=("$token")
    fi
  done

  local actual
  actual=$(printf '%s\n' "${help_commands[@]}" | sort -u)
  assert_contract_matches "--help" "$actual"
}

@test "dev contract: completion entries match the contract" {
  local actual
  actual=$(sed -n '/^subcmds=(/,/^)/p' \
    "$TEST_SUITE_ROOT/completions/_dev-menu" \
    | sed -n "s/^[[:space:]]*'\\([^:]*\\):.*/\\1/p" \
    | sort)

  assert_contract_matches "completion" "$actual"
}

@test "dev contract: removed commands and legacy names are neither defined nor dispatched" {
  run run_zsh '
    _dev_delegate_py() { print -r -- "UNEXPECTED_PY_DELEGATION:$*"; }
    _dev_delegate_sys() { print -r -- "UNEXPECTED_SYS_DELEGATION:$*"; }

    local -a removed_commands=(
      dev-check-licenses dev-run-ty dev-run-pyright dev-run-eslint
      dev-run-prettier dev-run-clippy dev-update-deps-dry dev-update-toolchain
      dev-export-deps dev-build-package dev-backup-pyproject
      dev-profile-run dev-profile-save dev-profile-list dev-profile-delete
      dev-clean-repo
    )
    local -a legacy_names=(
      update-all update-deps update-deps-dry update-lock update-precommit
      update-terraform update-tflint update-toolchain update-python
      check-outdated check-health check-licenses check-types
      run-hooks run-ruff run-ruff-format run-ty run-pyright run-tflint
      run-markdownlint run-eslint run-prettier run-clippy run-shellcheck
      run-all-checks run-tests run-coverage run-audit run-bandit
      clean-py clean-repo clean-terraform clean-all
      export-deps build-package backup-pyproject
      profile-save profile-list profile-delete
    )
    # Dev no longer forwards the environment commands of the Python suite or
    # the former venv-python route.
    local -a py_owned_names=(
      venv-list venv-create venv-activate venv-info venv-rebuild venv-remove
      venv-python-list venv-python-install venv-python-pin venv-python
    )

    local command_name invocation_status
    for command_name in "${removed_commands[@]}" "${legacy_names[@]}"; do
      if (( ${+functions[$command_name]} )); then
        print -u2 -r -- "Removed name is still a function: $command_name"
        return 1
      fi
    done
    for command_name in "${removed_commands[@]}" "${legacy_names[@]}" \
      "${py_owned_names[@]}"; do
      _dev_dispatch "$command_name" >/dev/null 2>&1
      invocation_status=$?
      (( invocation_status == 2 )) || {
        print -u2 -r -- \
          "Dispatcher accepted $command_name (status $invocation_status)."
        return 1
      }
    done
    (( ! ${+_DEV_DEPRECATION_SEEN} && ! ${+DEV_PROFILE_DIR} ))
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"UNEXPECTED_"* ]]

  run run_zsh "dev-menu --profile nightly"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --profile"* ]]
}

@test "dev contract: no legacy alias appears in the menu or completion" {
  local menu_hits
  menu_hits=$(grep -cE '"(update|check|run|clean|export|build|backup|profile)-[a-z-]+"' \
    "$TEST_SUITE_ROOT/functions/dev-menu.zsh" || true)
  [ "$menu_hits" -eq 0 ]

  ! grep -qE "^[[:space:]]*'(venv-init|venv-sync):" \
    "$TEST_SUITE_ROOT/completions/_dev-menu" || false
}

@test "dev contract: cancellation returns zero without dispatch" {
  run run_zsh '
    local dispatch_log="$HOME/dev-dispatch.log"
    fzf() {
      command cat >/dev/null
      return 130
    }
    _dev_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
      return 99
    }

    dev-menu
    local rc=$?
    [[ ! -e "$dispatch_log" ]] || return 1
    return $rc
  '

  [ "$status" -eq 0 ]
}

@test "dev contract: direct routing preserves timing label and status" {
  run run_zsh '
    _timed() {
      local label="$1"
      shift
      print -r -- "$label"
      "$@"
    }
    _dev_dispatch() {
      [[ "$1" == "dev-check-health" ]] || return 98
      return 7
    }

    dev-menu dev-check-health
  '

  [ "$status" -eq 7 ]
  [[ "$output" == *"dev:dev-check-health"* ]]
}

@test "dev contract: unknown dispatch token returns invalid-argument status" {
  run run_zsh "_dev_dispatch dev-phase-zero-unknown"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command"* ]]
}

@test "dev contract: unknown entrypoint option fails closed" {
  run run_zsh "dev-menu --definitely-not-a-flag"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "dev contract: argument-free commands reject malformed arity before probes" {
  run run_zsh '
    _dev_header() {
      print -u2 -r -- "OPERATIONAL_PROBE:$*"
      return 98
    }

    local command_name invocation_status
    local -a command_names=(
      dev-check-types
      dev-run-shellcheck
      dev-update-lock
      dev-update-precommit
      dev-update-terraform
      dev-update-tflint
    )

    for command_name in "${command_names[@]}"; do
      "$command_name" "" --bogus >/dev/null 2>&1
      invocation_status=$?
      (( invocation_status == 2 )) || {
        print -u2 -r -- \
          "$command_name accepted an empty first argument (status $invocation_status)."
        return 1
      }

      "$command_name" --help extra >/dev/null 2>&1
      invocation_status=$?
      (( invocation_status == 2 )) || {
        print -u2 -r -- \
          "$command_name accepted trailing help arguments (status $invocation_status)."
        return 1
      }
    done
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"OPERATIONAL_PROBE:"* ]]
}
