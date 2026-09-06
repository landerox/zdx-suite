#!/usr/bin/env bats

setup() {
  load test_helper
  PY_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/py-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

@test "py contract: snapshot membership treats full rows literally" {
  run run_zsh '
    local selected="Upgrade|tool-upgrade|Tools, packages (latest)."
    local -a rows=(
      "$selected"
      "List|tool-list|Other row."
    )
    _py_array_contains_literal "$selected" "${rows[@]}" || return 1
    ! _py_array_contains_literal \
      "${selected} forged" "${rows[@]}" || return 2
  '

  [ "$status" -eq 0 ]
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$PY_CONTRACT" | sort
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

@test "py contract: fixture freezes 16 unique canonical commands" {
  local count=0
  local command_name module_name risk capability extra

  while IFS=$'\t' read -r command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))
    [[ "$command_name" =~ ^[a-z]+(-[a-z]+)+$ ]]
    [[ "$module_name" =~ ^py-[a-z]+\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive|network)$ ]]
    [[ "$capability" =~ ^[a-z]+(-[a-z]+)*$ ]]
    [[ -z "$extra" ]]
    [[ -f "$TEST_SUITE_ROOT/functions/py/$module_name" ]]
  done < "$PY_CONTRACT"

  [ "$count" -eq 16 ]
  [ -z "$(contract_commands | uniq -d)" ]
}

@test "py contract: every canonical command is a real public function" {
  local command_list
  command_list=$(contract_commands | tr '\n' ' ')

  run run_zsh "
    source '$TEST_SUITE_ROOT/functions/py-menu.zsh' || return 1
    local command_name
    for command_name in $command_list; do
      typeset -f \"\$command_name\" &>/dev/null || {
        print -u2 -r -- \"Missing public function: \$command_name\"
        return 1
      }
    done
  "

  [ "$status" -eq 0 ]
}

@test "py contract: declared modules own every canonical function" {
  local command_name module_name risk capability
  while IFS=$'\t' read -r command_name module_name risk capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/py/$module_name"
  done < "$PY_CONTRACT"
}

@test "py contract: the normal interactive menu matches the fixture" {
  run run_zsh '
    fzf() {
      command cat >"$HOME/py-menu.rows"
      return 130
    }
    py-menu >"$HOME/menu.stdout" 2>"$HOME/menu.stderr"
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$HOME/py-menu.rows" | sort
  '

  [ "$status" -eq 0 ]
  assert_contract_matches "$output"
}

@test "py contract: dispatcher forwards arguments to representative owners" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/py-menu.zsh" || return 1
    venv-create() {
      print -r -- "venv:$#:${(j.:.)@}"
    }
    package-install() {
      print -r -- "package:$#:${(j.:.)@}"
    }
    tool-upgrade() {
      print -r -- "tool:$#:${(j.:.)@}"
    }
    _py_dispatch venv-create --python 3.12 --dry-run
    _py_dispatch package-install ruff --dev --yes
    _py_dispatch tool-upgrade --all --backend uv
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"venv:3:--python:3.12:--dry-run"* ]]
  [[ "$output" == *"package:3:ruff:--dev:--yes"* ]]
  [[ "$output" == *"tool:3:--all:--backend:uv"* ]]
}

@test "py contract: venv-python is compatibility-only and delegates to Py" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/py-menu.zsh" || return 1
    _py_venv_python() {
      print -r -- "compat:${(j.:.)@}"
    }
    venv-python pin 3.12 --dry-run
    py-menu --help 2>"$HOME/help"
    grep -q "Compatibility command:" "$HOME/help"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"compat:pin:3.12:--dry-run"* ]]
  ! contract_commands | grep -Fxq venv-python
}

@test "py contract: completion covers menu, direct commands, and compatibility" {
  local compdef_line
  compdef_line=$(head -n 1 "$TEST_SUITE_ROOT/completions/_py-menu")
  local command_name
  while IFS= read -r command_name; do
    [[ " $compdef_line " == *" $command_name "* ]]
  done < <(contract_commands)
  [[ " $compdef_line " == *" py-menu "* ]]
  [[ " $compdef_line " == *" venv-python "* ]]
  grep -q 'command_name="$service"' \
    "$TEST_SUITE_ROOT/completions/_py-menu"
  ! grep -q -- "'--path=" "$TEST_SUITE_ROOT/completions/_py-menu"
}
