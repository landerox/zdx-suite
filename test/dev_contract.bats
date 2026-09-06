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

@test "dev contract: fixture freezes 49 unique commands with valid metadata" {
  local count=0
  local command_name module_name risk owner extra

  while IFS=$'\t' read -r command_name module_name risk owner extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))

    [[ "$command_name" =~ ^[a-z][a-z0-9-]*$ ]]
    [[ "$module_name" =~ ^dev-[a-z0-9-]+\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive|delegated)$ ]]
    [[ "$owner" =~ ^(dev|py)$ ]]
    [[ -z "$extra" ]]

    if [[ "$owner" == "dev" ]]; then
      [[ -f "$TEST_SUITE_ROOT/functions/dev/$module_name" ]]
    else
      [[ -f "$TEST_SUITE_ROOT/functions/$module_name" ]]
    fi
  done < "$DEV_CONTRACT"

  [ "$count" -eq 49 ]

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
    _dev_delegate_py() { print -r -- \"\$1\"; }

    local command_name result
    for command_name in $command_list; do
      case \"\$command_name\" in
        venv-*) ;;
        *) functions[\$command_name]='print -r -- \"\$0\"' ;;
      esac
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

@test "dev contract: every deprecated alias forwards to a canonical command" {
  run run_zsh '
    _dev_verify_deps() { return 0; }
    _dev_dispatch_prepare() { return 0; }
    _dev_delegate_py() { print -r -- "py:$1"; }
    _dev_delegate_docker() { print -r -- "docker:$1"; }

    # "aliases" is a special Zsh parameter (the alias table); using it here
    # would silently clobber the shell state under test.
    typeset -A alias_map=(
      update-all dev-update-all
      update-deps dev-update-deps
      update-deps-dry dev-update-deps-dry
      update-lock dev-update-lock
      update-precommit dev-update-precommit
      update-terraform dev-update-terraform
      update-tflint dev-update-tflint
      update-toolchain dev-update-toolchain
      update-python dev-update-python
      check-outdated dev-check-outdated
      check-health dev-check-health
      check-licenses dev-check-licenses
      check-types dev-check-types
      run-hooks dev-run-hooks
      run-ruff dev-run-ruff
      run-ruff-format dev-run-ruff-format
      run-ty dev-run-ty
      run-pyright dev-run-pyright
      run-tflint dev-run-tflint
      run-markdownlint dev-run-markdownlint
      run-eslint dev-run-eslint
      run-prettier dev-run-prettier
      run-clippy dev-run-clippy
      run-shellcheck dev-run-shellcheck
      run-all-checks dev-run-all-checks
      run-tests dev-run-tests
      run-coverage dev-run-coverage
      run-audit dev-run-audit
      run-bandit dev-run-bandit
      clean-py dev-clean-py
      clean-repo dev-clean-repo
      clean-terraform dev-clean-terraform
      clean-all dev-clean-all
      export-deps dev-export-deps
      build-package dev-build-package
      backup-pyproject dev-backup-pyproject
      profile-save dev-profile-save
      profile-list dev-profile-list
      profile-delete dev-profile-delete
    )

    local old_name canonical result
    for old_name in "${(k)alias_map[@]}"; do
      canonical="${alias_map[$old_name]}"
      functions[$canonical]="print -r -- \$0"

      # The deprecated global function must exist and forward.
      if ! typeset -f "$old_name" &>/dev/null; then
        print -u2 -r -- "Missing deprecated alias function: $old_name"
        return 1
      fi

      # The dispatcher must accept the deprecated token too.
      result=$(_dev_dispatch "$old_name" 2>/dev/null) || {
        print -u2 -r -- "Dispatcher rejected deprecated token: $old_name"
        return 1
      }
      if [[ "$result" != "$canonical" ]]; then
        print -u2 -r -- "Alias $old_name reached $result, expected $canonical"
        return 1
      fi
    done

    # Docker tokens must delegate to the owning suite, not run locally.
    result=$(_dev_dispatch clean-docker 2>/dev/null)
    [[ "$result" == "docker:clean-docker" ]] || return 1
    result=$(_dev_dispatch docker-prune-all 2>/dev/null)
    [[ "$result" == "docker:docker-prune-all" ]] || return 1
  '

  [ "$status" -eq 0 ]
}

@test "dev contract: no deprecated alias appears in the menu or completion" {
  local menu_hits
  menu_hits=$(grep -cE '"(update|check|run|clean|export|build|backup|profile)-[a-z-]+"' \
    "$TEST_SUITE_ROOT/functions/dev-menu.zsh" || true)
  [ "$menu_hits" -eq 0 ]

  ! grep -qE "^[[:space:]]*'(clean-docker|docker-prune-all|venv-init|venv-sync):" \
    "$TEST_SUITE_ROOT/completions/_dev-menu"
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
      dev-backup-pyproject
      dev-build-package
      dev-check-types
      dev-profile-list
      dev-run-shellcheck
      dev-update-lock
      dev-update-precommit
      dev-update-terraform
      dev-update-tflint
      dev-update-toolchain
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
