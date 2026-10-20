#!/usr/bin/env bats

setup() {
  load test_helper
  SYS_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/sys-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$SYS_CONTRACT" | sort
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

@test "sys contract: fixture freezes 25 unique commands and valid metadata" {
  local count=0
  local command_name module_name risk capability extra

  while IFS=$'\t' read -r command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))

    [[ "$command_name" =~ ^[a-z][a-z0-9-]*$ ]]
    [[ "$module_name" =~ ^sys-[a-z0-9-]+\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive|privileged|remote-code)$ ]]
    [[ "$capability" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
    [[ -z "$extra" ]]
    [[ -f "$TEST_SUITE_ROOT/functions/sys/$module_name" ]]
  done < "$SYS_CONTRACT"

  [ "$count" -eq 25 ]

  local duplicates
  duplicates=$(contract_commands | uniq -d)
  [ -z "$duplicates" ]
}

@test "sys contract: every command is defined by its declared module" {
  local command_name module_name risk capability

  while IFS=$'\t' read -r command_name module_name risk capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue

    if ! grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/sys/$module_name"; then
      echo "$command_name is not defined by $module_name" >&2
      return 1
    fi
  done < "$SYS_CONTRACT"
}

@test "sys contract: every public function loads in Zsh" {
  local command_list
  command_list=$(contract_commands | tr '\n' ' ')

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

@test "sys contract: interactive menu entries match the contract" {
  run run_zsh "
    local capture_file=\"\$HOME/sys-menu.rows\"
    fzf() {
      command cat > \"\$capture_file\"
      return 130
    }

    sys-menu >/dev/null 2>&1
    awk -F '|' '\$2 != \":\" && NF >= 2 { print \$2 }' \
      \"\$capture_file\" | sort
  "

  [ "$status" -eq 0 ]
  assert_contract_matches "interactive menu" "$output"
}

@test "sys contract: dispatcher executes every canonical command" {
  local command_list
  command_list=$(contract_commands | tr '\n' ' ')

  run run_zsh "
    _sys_dispatch_prepare() { return 0; }

    local command_name result
    for command_name in $command_list; do
      functions[\$command_name]='print -r -- "\$0"'
      result=\$(_sys_dispatch \"\$command_name\") || {
        print -u2 -r -- \"Dispatcher rejected: \$command_name\"
        return 1
      }
      if [[ \"\$result\" != \"\$command_name\" ]]; then
        print -u2 -r -- \
          \"Dispatcher mismatch for \$command_name: \$result\"
        return 1
      fi
    done
  "

  [ "$status" -eq 0 ]
}

@test "sys contract: help lists exactly the canonical commands" {
  run run_zsh "sys-menu --help"
  [ "$status" -eq 0 ]

  local token
  local -a help_commands=()
  for token in $output; do
    token="${token%,}"
    if [[ "$token" != "sys-menu" \
      && "$token" =~ ^(clean|sys|update)-[a-z0-9-]+$ ]]; then
      help_commands+=("$token")
    fi
  done

  local actual
  actual=$(printf '%s\n' "${help_commands[@]}" | sort -u)
  assert_contract_matches "--help" "$actual"
}

@test "sys contract: completion entries match the contract" {
  local actual
  actual=$(sed -n '/subcmds=(/,/)/p' \
    "$TEST_SUITE_ROOT/completions/_sys-menu" \
    | sed -n "s/^[[:space:]]*'\\([^:]*\\):.*/\\1/p" \
    | sort)

  assert_contract_matches "completion" "$actual"
}

@test "sys contract: every command has a direct completion binding" {
  local actual
  actual=$(sed -n '1s/^#compdef[[:space:]]*//p' \
    "$TEST_SUITE_ROOT/completions/_sys-menu" \
    | tr ' ' '\n' \
    | grep -v '^sys-menu$' \
    | sort)

  assert_contract_matches "direct completion bindings" "$actual"
}

@test "sys contract: contextual completions exclude invalid mode combinations" {
  run env COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_sys-menu" \
    zsh -f -c '
      capture_specs() {
        local -a words=("$@")
        local -i CURRENT=${#words[@]}

        _arguments() {
          if [[ "${1:-}" == "-C" ]]; then
            words=("${words[@]:1}")
            (( CURRENT-- ))
            state="arguments"
            return 0
          fi
          print -rl -- "$@"
        }
        _describe() { return 0; }
        _message() { print -r -- "MESSAGE:${(j: :)@}"; }

        source "$COMPLETION_FILE"
      }

      local direct_specs nested_specs target_specs pid_specs port_specs
      local ports_specs processes_specs typed_targets
      direct_specs=$(capture_specs \
        sys-ports --kill port:8080 "")
      nested_specs=$(capture_specs \
        sys-menu sys-ports --kill port:8080 "")
      [[ "$direct_specs" == "$nested_specs" ]] || {
        print -r -- "direct=$direct_specs"
        print -r -- "nested=$nested_specs"
        return 1
      }

      target_specs=$(capture_specs sys-ports --kill "")
      pid_specs=$(capture_specs sys-ports --kill pid:123 "")
      port_specs="$direct_specs"
      [[ "$target_specs" == *"_sys_menu_complete_typed_target"* ]] \
        || return 2
      [[ "$pid_specs" != *"--protocol"* && "$pid_specs" != *"--force"* ]] || {
        print -r -- "pid=$pid_specs"
        return 3
      }
      [[ "$port_specs" == *"--protocol"* && "$port_specs" == *"--force"* ]] || {
        print -r -- "port=$port_specs"
        return 4
      }
      typed_targets=$(
        compadd() { print -r -- "${(j: :)@}"; }
        capture_specs sys-ports --kill "" >/dev/null
        _sys_menu_complete_typed_target
      )
      [[ "$typed_targets" == "-S  -- port:" ]] || {
        print -r -- "typed-targets=$typed_targets"
        return 5
      }

      ports_specs=$(capture_specs sys-ports "")
      processes_specs=$(capture_specs sys-processes "")
      [[ "$ports_specs" != *"--kill-pid"* \
        && "$processes_specs" == *"--terminate"* \
        && "$processes_specs" != *"--kill"* ]] || {
        print -r -- "ports=$ports_specs"
        print -r -- "processes=$processes_specs"
        return 6
      }

      local update_system_specs update_apt_specs
      update_system_specs=$(capture_specs update-system "")
      update_apt_specs=$(capture_specs update-apt "")
      [[ "$update_system_specs" == *"--verbose"* \
        && "$update_apt_specs" == *"--verbose"* ]] || return 7

      local clean_help_specs port_help_specs
      clean_help_specs=$(capture_specs \
        clean-system --quick --help "")
      port_help_specs=$(capture_specs \
        sys-ports --kill port:8080 --help "")
      [[ "$clean_help_specs" == "MESSAGE:no additional arguments" \
        && "$port_help_specs" == "MESSAGE:no additional arguments" ]] \
        || return 8
    '

  if [ "$status" -ne 0 ]; then
    echo "contextual completion probe failed with status $status" >&2
    echo "$output" >&2
  fi
  [ "$status" -eq 0 ]

  local help_spec
  while IFS= read -r help_spec; do
    [[ "$help_spec" == *"'(- *)'"* ]]
  done < <(
    grep -F "{-h,--help}'[Show" \
      "$TEST_SUITE_ROOT/completions/_sys-menu"
  )
}

@test "sys contract: cancellation returns zero without dispatch" {
  run run_zsh '
    local dispatch_log="$HOME/sys-dispatch.log"
    fzf() {
      command cat >/dev/null
      return 130
    }
    _sys_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
      return 99
    }

    sys-menu
    local rc=$?
    [[ ! -e "$dispatch_log" ]] || return 1
    return $rc
  '

  [ "$status" -eq 0 ]
}

@test "sys contract: picker runs in foreground with private bounded capture" {
  run run_zsh '
    local picker_root="$HOME/sys-picker"
    local dispatch_log="$HOME/sys-dispatch.log"
    command mkdir -m 700 -- "$picker_root"
    fzf() {
      print -r -- "$ZSH_SUBSHELL" > "$HOME/fzf-subshell"
      local row="" command_name=""
      while IFS= read -r row; do
        command_name="${${row#*|}%%|*}"
        if [[ "$command_name" != ":" ]]; then
          print -r -- "$row"
          return 0
        fi
      done
      return 1
    }
    _sys_dispatch() {
      print -r -- "$1" > "$dispatch_log"
    }

    TMPDIR="$picker_root" sys-menu
    [[ "$(<"$HOME/fzf-subshell")" == "0" ]]
    [[ -s "$dispatch_log" ]]
    [[ -z "$(command find "$picker_root" -mindepth 1 -print -quit)" ]]
  '

  [ "$status" -eq 0 ]
}

@test "sys contract: picker rejects a row outside the menu snapshot" {
  run run_zsh '
    local dispatch_log="$HOME/sys-dispatch.log"
    fzf() {
      command cat >/dev/null
      print -r -- "forged|sys-info|not in the reviewed snapshot"
    }
    _sys_dispatch() {
      print -r -- "$1" > "$dispatch_log"
    }

    sys-menu
    local menu_rc=$?
    [[ ! -e "$dispatch_log" ]] || return 99
    return $menu_rc
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the menu snapshot"* ]]
}

@test "sys contract: direct routing preserves timing label and status" {
  run run_zsh '
    _timed() {
      local label="$1"
      shift
      print -r -- "$label"
      "$@"
    }
    _sys_dispatch() {
      [[ "$1" == "sys-info" ]] || return 98
      return 7
    }

    sys-menu sys-info
  '

  [ "$status" -eq 7 ]
  [[ "$output" == *"sys:sys-info"* ]]
}

@test "sys contract: unknown dispatch token returns invalid-argument status" {
  run run_zsh "_sys_dispatch phase-zero-unknown"

  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command: phase-zero-unknown"* ]]
}

@test "sys contract: re-sourcing the suite is silent and idempotent" {
  run run_zsh "
    source \"\$ZSH_CUSTOM/functions/sys-menu.zsh\"
    source \"\$ZSH_CUSTOM/functions/sys-menu.zsh\"
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
