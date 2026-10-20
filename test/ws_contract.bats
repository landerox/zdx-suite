#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  WS_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/ws-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$WS_CONTRACT" | sort
}

assert_contract_matches() {
  local actual="$1"
  local expected
  expected=$(contract_commands)
  if [[ "$actual" != "$expected" ]]; then
    diff -u \
      <(printf '%s\n' "$expected") \
      <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

@test "ws contract: fixture freezes three unique canonical commands" {
  local count=0
  local command_name module_name risk capability extra
  while IFS=$'\t' read -r command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))
    [[ "$command_name" =~ ^ws(-[a-z]+)+$ ]]
    [[ "$module_name" =~ ^ws-[a-z]+\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive|network)$ ]]
    [[ "$capability" =~ ^[a-z]+(-[a-z]+)*$ ]]
    [ -z "$extra" ]
    [ -f "$TEST_SUITE_ROOT/functions/ws/$module_name" ]
  done < "$WS_CONTRACT"
  [ "$count" -eq 3 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "ws contract: declared modules own every canonical public function" {
  local command_name module_name risk capability
  while IFS=$'\t' read -r command_name module_name risk capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/ws/$module_name"
  done < "$WS_CONTRACT"

  local command_list
  command_list=$(contract_commands | tr '\n' ' ')
  run zsh -f -c "
    source '$TEST_SUITE_ROOT/functions/ws-menu.zsh' || exit 1
    for command_name in $command_list; do
      typeset -f \"\$command_name\" >/dev/null || exit 2
    done
  "
  [ "$status" -eq 0 ]
}

@test "ws contract: menu rows, dispatcher arms, and help equal the fixture" {
  export MOCK_FZF_MODE="cancel"
  run run_zsh '
    ws-menu >/dev/null 2>&1
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE" | sort
  '
  [ "$status" -eq 0 ]
  assert_contract_matches "$output"

  local actual
  actual=$(
    sed -n '/^_ws_dispatch()/,/^}/p' "$TEST_SUITE_ROOT/functions/ws-common.zsh" \
      | sed -nE 's/^[[:space:]]*(ws(-[a-z]+)+)\)[[:space:]].*$/\1/p' \
      | sort
  )
  assert_contract_matches "$actual"

  run run_zsh 'ws-menu --help'
  [ "$status" -eq 0 ]
  actual=$(printf '%s\n' "$output" \
    | sed -nE 's/^  (ws-[a-z]+(, ws-[a-z]+)*)$/\1/p' \
    | tr ',' '\n' | tr -d ' ' | grep -vx 'ws-menu' | sort)
  assert_contract_matches "$actual"
}

@test "ws contract: completion binds the menu and exactly the direct commands" {
  local completion="$TEST_SUITE_ROOT/completions/_ws-menu"
  local compdef_line actual
  compdef_line=$(head -n 1 "$completion")
  [[ " $compdef_line " == *" ws-menu "* ]]
  actual=$(tr ' ' '\n' <<<"$compdef_line" \
    | grep -vx -e '#compdef' -e 'ws-menu' | sort)
  assert_contract_matches "$actual"
  actual=$(sed -nE "s/^  '(ws-[a-z]+):.*$/\\1/p" "$completion" | sort)
  assert_contract_matches "$actual"
  grep -q 'command_name="$service"' "$completion"
  grep -Fq -- "'--fetch[" "$completion"
  grep -Fq -- "'--json[" "$completion"
  grep -Fq -- "'--dry-run[" "$completion"
  grep -Fq -- "'--yes[" "$completion"
}

@test "ws contract: completion registers after compinit through the plugin wrapper" {
  local registration_log="$TEST_TEMP_DIR/completion-registrations"
  : > "$registration_log"
  run zsh -f -c "
    unset TEST_TEMP_DIR BATS_TEST_DIRNAME
    export HOME='$HOME' PATH='$PATH' ZDX_KEYBINDINGS=0 ZDX_LAZY_LOAD=1
    compdef() {
      print -r -- \"\$1:\${(j: :)@[2,-1]}\" >> '$registration_log'
    }
    source '$TEST_SUITE_ROOT/zdx-suite.plugin.zsh' || exit 1
  "
  [ "$status" -eq 0 ]
  grep -Fxq '_ws-menu:ws-menu ws-clone ws-jump ws-status' "$registration_log"
  grep -Eq '^_zdx-menu:' "$registration_log"
  grep -Fq "'ws:Workspace repositories'" "$TEST_SUITE_ROOT/completions/_zdx-menu"
  grep -Fq 'dev|env|file|git|py|sys|vpn|ws)' "$TEST_SUITE_ROOT/completions/_zdx-menu"
}

@test "ws contract: every direct command and the menu have cold lazy stubs" {
  local command_name
  for command_name in ws-menu $(contract_commands); do
    grep -Eq "^[[:space:]]+${command_name}[[:space:]]+ws-menu\\.zsh$" \
      "$TEST_SUITE_ROOT/functions.zsh"
  done
}

@test "ws contract: product code has no evaluator or computed dispatch" {
  run grep -REn '(^|[[:space:]])eval([[:space:]]|$)|sh -c .*\$[a-z_]*(url|path|query)' \
    "$TEST_SUITE_ROOT/functions/ws-menu.zsh" \
    "$TEST_SUITE_ROOT/functions/ws-common.zsh" \
    "$TEST_SUITE_ROOT/functions/ws"
  [ "$status" -eq 1 ]
  # The private prototype mechanism stays the only zdir registration.
  grep -Fq '_ZDX_LAZY_FILES[zdir]=zdir.zsh' "$TEST_SUITE_ROOT/functions.zsh"
  ! grep -REq 'zdir|wsj' "$TEST_SUITE_ROOT/functions/ws-menu.zsh" \
    "$TEST_SUITE_ROOT/functions/ws-common.zsh" "$TEST_SUITE_ROOT/functions/ws" \
    || false
}

@test "ws contract: documentation names the suite, its prefix, and its fixture" {
  grep -Fq '| `ws` |' "$TEST_SUITE_ROOT/docs/suites.md"
  grep -Fq '`_ws_*`' "$TEST_SUITE_ROOT/docs/suites.md"
  grep -Fq '`_ws_*`' "$TEST_SUITE_ROOT/AGENTS.md"
  grep -Fq 'docs/ws-menu.md' "$TEST_SUITE_ROOT/AGENTS.md"
  grep -Fq 'test/fixtures/ws-public-commands.tsv' \
    "$TEST_SUITE_ROOT/docs/ws-menu.md"
  local command_name
  for command_name in $(contract_commands); do
    grep -Fq "\`$command_name" "$TEST_SUITE_ROOT/docs/ws-menu.md"
    grep -Fq "\`$command_name" "$TEST_SUITE_ROOT/docs/user-guide.md"
  done
  grep -Fq 'WS_MAX_DEPTH' "$TEST_SUITE_ROOT/.config/zdx/config.zsh.example"
  grep -Fq 'WS_EXCLUDE' "$TEST_SUITE_ROOT/.config/zdx/config.zsh.example"
  grep -Fq 'WS_FETCH_JOBS' "$TEST_SUITE_ROOT/.config/zdx/config.zsh.example"
}
