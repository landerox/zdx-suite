#!/usr/bin/env bats

setup() {
  load test_helper
  VPN_MENU_FILE="$TEST_SUITE_ROOT/functions/vpn-menu.zsh"
  VPN_COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_vpn-menu"
  VPN_GRAMMAR_MARKER="$TEST_TEMP_DIR/vpn-grammar-runtime"
}

teardown() {
  cleanup_sandbox
}

capture_completion_specs() {
  local command_name="$1"

  run zsh -f -c '
    typeset -g _vpn_probe_command="$1"
    typeset -gi _vpn_arguments_call=0

    _arguments() {
      (( _vpn_arguments_call++ ))
      if (( _vpn_arguments_call == 1 )); then
        state=arguments
        words=("$_vpn_probe_command")
        return 0
      fi
      print -rl -- "$@"
    }
    _describe() { return 0; }
    _files() { return 0; }

    source "$2"
  ' _ "$command_name" "$VPN_COMPLETION_FILE"
}

assert_completion_has() {
  local expected="$1"
  if [[ "$output" != *"$expected"* ]]; then
    printf 'Missing completion spec: %s\nCaptured specs:\n%s\n' \
      "$expected" "$output" >&2
    return 1
  fi
}

assert_completion_lacks() {
  local unexpected="$1"
  if [[ "$output" == *"$unexpected"* ]]; then
    printf 'Unexpected completion spec: %s\nCaptured specs:\n%s\n' \
      "$unexpected" "$output" >&2
    return 1
  fi
}

run_vpn_grammar() {
  local command_name="$1"
  shift
  rm -f "$VPN_GRAMMAR_MARKER"

  run zsh -f -c '
    export HOME="$1"
    export PATH="$2"
    source "$3" || exit 1

    typeset -g _vpn_grammar_marker="$4"
    local command_name="$5"
    shift 5

    _vpn_grammar_reached_runtime() {
      print -r -- "$1" > "$_vpn_grammar_marker"
    }
    _vpn_require_platform() {
      _vpn_grammar_reached_runtime require-platform
      return 91
    }
    _vpn_ensure_wg_access() {
      _vpn_grammar_reached_runtime ensure-wg-access
      return 91
    }
    _vpn_tunnel_down() {
      _vpn_grammar_reached_runtime tunnel-down
      return 91
    }

    "$command_name" "$@"
  ' _ "$HOME" "$PATH" "$VPN_MENU_FILE" "$VPN_GRAMMAR_MARKER" \
    "$command_name" "$@"
}

assert_grammar_accepts() {
  local invocation="$*"
  run_vpn_grammar "$@"

  if [[ "$status" -eq 2 || ! -f "$VPN_GRAMMAR_MARKER" ]]; then
    printf 'Expected grammar to accept: %s\nstatus=%s\noutput=%s\n' \
      "$invocation" "$status" "$output" >&2
    return 1
  fi
}

assert_grammar_rejects() {
  local invocation="$*"
  run_vpn_grammar "$@"

  if [[ "$status" -ne 2 || -e "$VPN_GRAMMAR_MARKER" ]]; then
    printf 'Expected grammar to reject before runtime: %s\nstatus=%s\noutput=%s\n' \
      "$invocation" "$status" "$output" >&2
    return 1
  fi
}

@test "vpn grammar: profile connection completions expose one profile and no mutation flags" {
  local command_name
  for command_name in vpn-on vpn-off vpn-default-set; do
    capture_completion_specs "$command_name"
    [ "$status" -eq 0 ]
    assert_completion_has "1:profile:_vpn_menu_profiles"
    assert_completion_lacks "--yes"
    assert_completion_lacks "--dry-run"
    assert_completion_lacks "--with-backup"
    assert_completion_lacks "*:profile:"
  done
}

@test "vpn grammar: destructive completions expose only their own flags and operands" {
  capture_completion_specs vpn-off-all
  [ "$status" -eq 0 ]
  assert_completion_has "--dry-run"
  assert_completion_has "--yes"
  assert_completion_lacks "--with-backup"
  assert_completion_lacks ":profile:"

  capture_completion_specs vpn-profile-rename
  [ "$status" -eq 0 ]
  assert_completion_has "--dry-run"
  assert_completion_has "--yes"
  assert_completion_lacks "--with-backup"
  assert_completion_has "1:current profile:_vpn_menu_profiles"
  assert_completion_has "2:new profile name:"

  capture_completion_specs vpn-config-restore
  [ "$status" -eq 0 ]
  assert_completion_has "--dry-run"
  assert_completion_has "--yes"
  assert_completion_lacks "--with-backup"
  assert_completion_has "1:profile:_vpn_menu_profiles"

  capture_completion_specs vpn-profile-remove
  [ "$status" -eq 0 ]
  assert_completion_has "--dry-run"
  assert_completion_has "--yes"
  assert_completion_has "--with-backup"
  assert_completion_has "1:profile:_vpn_menu_profiles"
}

@test "vpn grammar: create import and edit completions expose one exact operand" {
  capture_completion_specs vpn-profile-create
  [ "$status" -eq 0 ]
  assert_completion_has "1:new profile name:"
  assert_completion_lacks "*:new profile name:"
  assert_completion_lacks "--yes"
  assert_completion_lacks "--dry-run"

  capture_completion_specs vpn-profile-import
  [ "$status" -eq 0 ]
  assert_completion_has '1:configuration file:_files -g "*.conf"'
  assert_completion_lacks '*:configuration file:'
  assert_completion_lacks "--yes"
  assert_completion_lacks "--dry-run"

  capture_completion_specs vpn-config-edit
  [ "$status" -eq 0 ]
  assert_completion_has "1:profile:_vpn_menu_profiles"
  assert_completion_lacks "*:profile:"
  assert_completion_lacks "--yes"
  assert_completion_lacks "--dry-run"
}

@test "vpn grammar: profile completion excludes names the runtime rejects" {
  local profile_dir="$TEST_TEMP_DIR/profiles"
  local long_name
  long_name=$(printf 'a%.0s' {1..65})
  mkdir -p "$profile_dir"
  touch \
    "$profile_dir/alpha_beta-1.conf" \
    "$profile_dir/office.conf" \
    "$profile_dir/-dash.conf" \
    "$profile_dir/bad name.conf" \
    "$profile_dir/bad|pipe.conf" \
    "$profile_dir/${long_name}.conf"
  chmod 700 "$profile_dir"
  chmod 600 "$profile_dir"/*.conf

  run zsh -f -c '
    _arguments() { return 0; }
    _describe() {
      print -rl -- "${profiles[@]}"
    }

    source "$1"
    VPN_CONFIG_DIR="$2"
    _vpn_menu_profiles
  ' _ "$VPN_COMPLETION_FILE" "$profile_dir"

  [ "$status" -eq 0 ]
  [ "$output" = $'alpha_beta-1\noffice' ]
}

@test "vpn grammar: connection commands reject flags and surplus profiles before runtime" {
  local command_name
  for command_name in vpn-on vpn-off vpn-default-set; do
    assert_grammar_accepts "$command_name" wg0
    assert_grammar_accepts "$command_name" -- wg0

    assert_grammar_rejects "$command_name" --yes
    assert_grammar_rejects "$command_name" --dry-run
    assert_grammar_rejects "$command_name" --with-backup
    assert_grammar_rejects "$command_name" wg0 extra
    assert_grammar_rejects "$command_name" -- wg0 extra
  done
}

@test "vpn grammar: off-all accepts dry-run and yes but no positional target" {
  assert_grammar_accepts vpn-off-all
  assert_grammar_accepts vpn-off-all --dry-run
  assert_grammar_accepts vpn-off-all --yes
  assert_grammar_accepts vpn-off-all --dry-run --yes

  assert_grammar_rejects vpn-off-all wg0
  assert_grammar_rejects vpn-off-all --with-backup
  assert_grammar_rejects vpn-off-all -- wg0
}

@test "vpn grammar: rename restore and remove enforce exact flags and cardinality" {
  assert_grammar_accepts vpn-profile-rename old-name new-name
  assert_grammar_accepts vpn-profile-rename --dry-run old-name new-name
  assert_grammar_accepts vpn-profile-rename old-name new-name --yes
  assert_grammar_accepts vpn-profile-rename -- old-name new-name
  assert_grammar_rejects vpn-profile-rename old-name new-name extra
  assert_grammar_rejects vpn-profile-rename -- old-name new-name extra
  assert_grammar_rejects vpn-profile-rename --with-backup old-name new-name

  assert_grammar_accepts vpn-config-restore wg0 --dry-run --yes
  assert_grammar_accepts vpn-config-restore -- wg0
  assert_grammar_rejects vpn-config-restore wg0 extra
  assert_grammar_rejects vpn-config-restore -- wg0 extra
  assert_grammar_rejects vpn-config-restore wg0 --with-backup

  assert_grammar_accepts vpn-profile-remove wg0 --dry-run --yes --with-backup
  assert_grammar_accepts vpn-profile-remove -- wg0
  assert_grammar_rejects vpn-profile-remove wg0 extra
  assert_grammar_rejects vpn-profile-remove -- wg0 extra
}

@test "vpn grammar: create import and edit reject surplus operands after option terminator" {
  assert_grammar_accepts vpn-profile-create
  assert_grammar_accepts vpn-profile-create new-profile
  assert_grammar_accepts vpn-profile-create -- new-profile
  assert_grammar_rejects vpn-profile-create one two
  assert_grammar_rejects vpn-profile-create -- one two
  assert_grammar_rejects vpn-profile-create --yes

  assert_grammar_accepts vpn-profile-import
  assert_grammar_accepts vpn-profile-import /tmp/client.conf
  assert_grammar_accepts vpn-profile-import -- -client.conf
  assert_grammar_rejects vpn-profile-import one.conf two.conf
  assert_grammar_rejects vpn-profile-import -- one.conf two.conf
  assert_grammar_rejects vpn-profile-import --dry-run

  assert_grammar_accepts vpn-config-edit
  assert_grammar_accepts vpn-config-edit wg0
  assert_grammar_accepts vpn-config-edit -- wg0
  assert_grammar_rejects vpn-config-edit wg0 extra
  assert_grammar_rejects vpn-config-edit -- wg0 extra
  assert_grammar_rejects vpn-config-edit --yes
}

@test "vpn grammar: help advertises the same safety flags as completion" {
  run_vpn_grammar vpn-on --help
  [ "$status" -eq 0 ]
  [[ "$output" != *"--yes"* ]]
  [ ! -e "$VPN_GRAMMAR_MARKER" ]

  run_vpn_grammar vpn-off-all --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--yes"* ]]
  [ ! -e "$VPN_GRAMMAR_MARKER" ]

  run_vpn_grammar vpn-profile-rename --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" != *"--with-backup"* ]]
  [ ! -e "$VPN_GRAMMAR_MARKER" ]

  run_vpn_grammar vpn-config-restore --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" != *"--with-backup"* ]]

  run_vpn_grammar vpn-profile-remove --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"--with-backup"* ]]
}
