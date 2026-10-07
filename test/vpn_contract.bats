#!/usr/bin/env bats

setup() {
  load test_helper
  load vpn_test_helper
  # A Linux kernel unless a test pins another; a WSL host still reads as WSL.
  vpn_pin_kernel Linux
  VPN_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/vpn-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$VPN_CONTRACT" | sort
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

@test "vpn contract: fixture freezes 22 unique commands with valid metadata" {
  local count=0
  local command_name module_name risk privilege extra

  while IFS=$'\t' read -r command_name module_name risk privilege extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))

    [[ "$command_name" =~ ^vpn-[a-z0-9-]+$ ]]
    [[ "$module_name" =~ ^vpn-[a-z0-9-]+\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive)$ ]]
    [[ "$privilege" =~ ^(privileged|unprivileged)$ ]]
    [[ -z "$extra" ]]
    [[ -f "$TEST_SUITE_ROOT/functions/vpn/$module_name" ]]
  done < "$VPN_CONTRACT"

  [ "$count" -eq 22 ]

  local duplicates
  duplicates=$(contract_commands | uniq -d)
  [ -z "$duplicates" ]
}

@test "vpn contract: every command is defined by its declared module" {
  local command_name module_name risk privilege

  while IFS=$'\t' read -r command_name module_name risk privilege; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue

    if ! grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/vpn/$module_name"; then
      echo "$command_name is not defined by $module_name" >&2
      return 1
    fi
  done < "$VPN_CONTRACT"
}

@test "vpn contract: every public function loads in Zsh" {
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

@test "vpn contract: interactive menu entries match the contract" {
  run run_zsh "
    local capture_file=\"\$HOME/vpn-menu.rows\"
    fzf() {
      command cat > \"\$capture_file\"
      return 130
    }

    vpn-menu >/dev/null 2>&1
    awk -F '|' '\$2 != \":\" && NF >= 2 { print \$2 }' \
      \"\$capture_file\" | sort -u
  "

  [ "$status" -eq 0 ]
  assert_contract_matches "interactive menu" "$output"
}

@test "vpn contract: the menu command set does not depend on host state" {
  # Labels and per-profile rows vary with live state; which commands exist must
  # not. Two very different hosts must render the same command set.
  run run_zsh '
    fzf() { command cat > "$HOME/rows.locked"; return 130; }
    _vpn_configs_access_state() { print -r -- "locked"; }
    _vpn_wg_access_state() { print -r -- "locked"; }
    _vpn_get_configs() { return 1; }
    _vpn_get_active_interfaces() { return 1; }
    vpn-menu >/dev/null 2>&1

    fzf() { command cat > "$HOME/rows.rich"; return 130; }
    _vpn_configs_access_state() { print -r -- "direct"; }
    _vpn_wg_access_state() { print -r -- "direct"; }
    _vpn_get_configs() { print -rl -- alpha bravo; }
    _vpn_get_active_interfaces() { print -r -- "alpha"; }
    _vpn_backup_state() { print -r -- "available"; }
    _vpn_effective_default_iface() { print -r -- "alpha"; }
    _vpn_effective_last_iface() { print -r -- "bravo"; }
    vpn-menu >/dev/null 2>&1

    extract() {
      command awk -F "|" "\$2 != \":\" && NF >= 2 { print \$2 }" "$1" \
        | command sort -u
    }
    if [[ "$(extract "$HOME/rows.locked")" != "$(extract "$HOME/rows.rich")" ]]; then
      print -u2 -r -- "Command set differs between hosts:"
      command diff -u \
        <(extract "$HOME/rows.locked") <(extract "$HOME/rows.rich") >&2
      return 1
    fi
    # The rich host must still add per-profile rows.
    command grep -q "|vpn-off|.*|alpha$" "$HOME/rows.rich" || return 1
    command grep -q "|vpn-on|.*|bravo$" "$HOME/rows.rich" || return 1
  '

  [ "$status" -eq 0 ]
}

@test "vpn contract: dispatcher executes every canonical command" {
  local command_list
  command_list=$(contract_commands | tr '\n' ' ')

  run run_zsh "
    _vpn_dispatch_prepare() { return 0; }

    local command_name result
    for command_name in $command_list; do
      functions[\$command_name]='print -r -- \$0'
      result=\$(_vpn_dispatch \"\$command_name\") || {
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

@test "vpn contract: help lists exactly the canonical commands" {
  run run_zsh "vpn-menu --help"
  [ "$status" -eq 0 ]

  local token
  local -a help_commands=()
  for token in $output; do
    token="${token%,}"
    if [[ "$token" =~ ^vpn-[a-z0-9-]+$ && "$token" != "vpn-menu" ]]; then
      help_commands+=("$token")
    fi
  done

  local actual
  actual=$(printf '%s\n' "${help_commands[@]}" | sort -u)
  assert_contract_matches "--help" "$actual"
}

@test "vpn contract: completion entries match the contract" {
  local actual
  actual=$(sed -n '/^subcmds=(/,/^)/p' \
    "$TEST_SUITE_ROOT/completions/_vpn-menu" \
    | sed -n "s/^[[:space:]]*'\\([^:]*\\):.*/\\1/p" \
    | sort)

  assert_contract_matches "completion" "$actual"
}

@test "vpn contract: dispatcher arms match the contract" {
  local actual
  actual=$(
    sed -n '/^_vpn_dispatch()/,/^}/p' \
      "$TEST_SUITE_ROOT/functions/vpn-common.zsh" \
      | sed -nE 's/^[[:space:]]*(vpn-[a-z0-9-]+)\)$/\1/p' \
      | sort
  )

  assert_contract_matches "dispatcher arms" "$actual"
}

@test "vpn contract: cancellation returns zero without dispatch" {
  run run_zsh '
    local dispatch_log="$HOME/vpn-dispatch.log"
    fzf() {
      command cat >/dev/null
      return 130
    }
    _vpn_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
      return 99
    }

    vpn-menu
    local rc=$?
    [[ ! -e "$dispatch_log" ]] || return 1
    return $rc
  '

  [ "$status" -eq 0 ]
}

@test "vpn contract: direct routing preserves timing label and status" {
  run run_zsh '
    _timed() {
      local label="$1"
      shift
      print -r -- "$label"
      "$@"
    }
    _vpn_dispatch() {
      [[ "$1" == "vpn-summary" ]] || return 98
      return 7
    }

    vpn-menu vpn-summary
  '

  [ "$status" -eq 7 ]
  [[ "$output" == *"vpn:vpn-summary"* ]]
}

@test "vpn contract: direct invocation forwards arguments unchanged" {
  run run_zsh '
    vpn-profile-remove() { print -r -- "args:$*"; return 0; }
    _vpn_dispatch_prepare() { return 0; }

    vpn-menu vpn-profile-remove wg0 --dry-run --with-backup
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"args:wg0 --dry-run --with-backup"* ]]
}

@test "vpn contract: unknown dispatch token returns invalid-argument status" {
  run run_zsh "_vpn_dispatch vpn-not-a-command"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown command"* ]]
}

@test "vpn contract: unknown entrypoint option fails closed" {
  run run_zsh "vpn-menu --definitely-not-a-flag"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option"* ]]

  run run_zsh "vpn-menu --help extra"
  [ "$status" -eq 2 ]
}
