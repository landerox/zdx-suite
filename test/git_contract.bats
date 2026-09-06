#!/usr/bin/env bats

setup() {
  load test_helper
  GIT_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/git-public-commands.tsv"
}

teardown() {
  cleanup_sandbox
}

git_contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$GIT_CONTRACT" | sort
}

git_contract_module_path() {
  local module_name="$1"
  if [[ "$module_name" == "git-common.zsh" ]]; then
    printf '%s\n' "$TEST_SUITE_ROOT/functions/$module_name"
  else
    printf '%s\n' "$TEST_SUITE_ROOT/functions/git/$module_name"
  fi
}

assert_git_contract_matches() {
  local surface_name="$1"
  local actual="$2"
  local expected
  expected=$(git_contract_commands)

  if [[ "$actual" != "$expected" ]]; then
    echo "Public Git command drift in: $surface_name" >&2
    diff -u \
      <(printf '%s\n' "$expected") \
      <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

@test "git contract: fixture freezes 39 unique commands and valid metadata" {
  local count=0
  local command_name module_name risk capability extra module_path

  while IFS=$'\t' read -r \
    command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))

    [[ "$command_name" =~ ^[a-z][a-z0-9-]*$ ]]
    [[ "$module_name" =~ ^git(-[a-z0-9-]+)?\.zsh$ ]]
    [[ "$risk" =~ ^(read-only|mutating|destructive|remote-code)$ ]]
    [[ "$capability" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
    [[ -z "$extra" ]]

    module_path=$(git_contract_module_path "$module_name")
    [[ -f "$module_path" ]]
  done < "$GIT_CONTRACT"

  [ "$count" -eq 39 ]

  local duplicates
  duplicates=$(git_contract_commands | uniq -d)
  [ -z "$duplicates" ]
}

@test "git contract: every command is defined by its declared module" {
  local command_name module_name risk capability module_path

  while IFS=$'\t' read -r \
    command_name module_name risk capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    module_path=$(git_contract_module_path "$module_name")

    if ! grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" "$module_path"; then
      echo "$command_name is not defined by $module_name" >&2
      return 1
    fi
  done < "$GIT_CONTRACT"
}

@test "git contract: public function definitions match the contract" {
  local actual
  actual=$(
    grep -hE \
      '^(clean|git)-[a-z0-9-]+\(\)[[:space:]]*\{' \
      "$TEST_SUITE_ROOT/functions/git-common.zsh" \
      "$TEST_SUITE_ROOT"/functions/git/*.zsh \
      | sed -E 's/\(\)[[:space:]]*\{.*$//' \
      | sort
  )

  assert_git_contract_matches "public function definitions" "$actual"
}

@test "git contract: every public function loads in Zsh" {
  local command_list
  command_list=$(git_contract_commands | tr '\n' ' ')

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

@test "git contract: every public function establishes Zsh emulation" {
  local command_list
  command_list=$(git_contract_commands | tr '\n' ' ')

  run run_zsh "
    local command_name function_body
    for command_name in $command_list; do
      function_body=\"\${functions[\$command_name]}\"
      [[ \"\$function_body\" == *\"emulate -L zsh\"* ]] || {
        print -u2 -r -- \
          \"Public command does not establish Zsh emulation: \$command_name\"
        return 1
      }
    done
  "

  [ "$status" -eq 0 ]
}

@test "git contract: interactive menu entries match the contract" {
  run run_zsh '
    local repo_dir="$HOME/repository"
    command git init -q "$repo_dir" || return 1
    cd "$repo_dir" || return 1
    command git config user.name "Contract Test"
    command git config user.email "contract@example.invalid"

    export MOCK_FZF_MODE=cancel
    export MOCK_FZF_STATUS=130
    _tk_auth_badge() { print -r -- "Contract Test"; }

    git-menu >/dev/null 2>/dev/null
    awk -F "|" '\''$2 != ":" && NF >= 2 { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE" | sort
  '

  [ "$status" -eq 0 ]
  assert_git_contract_matches "interactive menu" "$output"
}

@test "git contract: dispatcher executes every canonical command" {
  local command_list
  command_list=$(git_contract_commands | tr '\n' ' ')

  run run_zsh "
    _git_verify_deps() { return 0; }
    _tk_verify_deps() { return 0; }

    local command_name result
    for command_name in $command_list; do
      functions[\$command_name]='print -r -- \"\$0\"'
      result=\$(_git_dispatch \"\$command_name\") || {
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

@test "git contract: dispatcher arms match the contract" {
  local actual
  actual=$(
    sed -n '/^_git_dispatch()/,/^}/p' \
      "$TEST_SUITE_ROOT/functions/git-common.zsh" \
      | sed -nE \
        's/^[[:space:]]*((clean|git)-[a-z0-9-]+)\)$/\1/p' \
      | sort
  )

  assert_git_contract_matches "dispatcher arms" "$actual"
}

@test "git contract: help lists exactly the canonical commands" {
  run run_zsh "git-menu --help"
  [ "$status" -eq 0 ]

  local token
  local -a help_commands=()
  for token in $output; do
    token="${token%,}"
    if [[ "$token" != "git-menu" \
      && "$token" =~ ^(clean|git)-[a-z0-9-]+$ ]]; then
      help_commands+=("$token")
    fi
  done

  local actual
  actual=$(printf '%s\n' "${help_commands[@]}" | sort -u)
  assert_git_contract_matches "--help" "$actual"
}

@test "git contract: completion entries match the contract" {
  local actual
  actual=$(sed -n '/subcmds=(/,/)/p' \
    "$TEST_SUITE_ROOT/completions/_git-menu" \
    | sed -n "s/^[[:space:]]*'\\([^:]*\\):.*/\\1/p" \
    | sort)

  assert_git_contract_matches "completion" "$actual"
}

@test "git contract: every command has a direct completion binding" {
  local actual
  actual=$(sed -n '1s/^#compdef[[:space:]]*//p' \
    "$TEST_SUITE_ROOT/completions/_git-menu" \
    | tr ' ' '\n' \
    | grep -v '^git-menu$' \
    | sort)

  assert_git_contract_matches "direct completion bindings" "$actual"
}

@test "git contract: contextual completion supports direct and nested grammar" {
  run env COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_git-menu" \
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

      local direct_specs nested_specs identity_specs switch_specs
      local checkout_specs destructive_specs confirmation_specs help_specs
      local command_name

      direct_specs=$(capture_specs git-identity-switcher "")
      nested_specs=$(capture_specs git-menu git-identity-switcher "")
      [[ "$direct_specs" == "$nested_specs" ]] || return 1

      identity_specs="$direct_specs"
      [[ "$identity_specs" == *"--status"* \
        && "$identity_specs" == *"--switch"* ]] || return 2

      switch_specs=$(capture_specs \
        git-identity-switcher --switch personal "")
      [[ "$switch_specs" == *"local global"* ]] || return 3

      direct_specs=$(capture_specs git-pr-checkout "")
      nested_specs=$(capture_specs git-menu git-pr-checkout "")
      [[ "$direct_specs" == "$nested_specs" ]] || return 4
      checkout_specs="$direct_specs"
      [[ "$checkout_specs" == *"pull request number"* ]] || return 5

      for command_name in \
        clean-branches \
        clean-remote-merged \
        git-config-edit \
        git-discard \
        git-pr-create \
        git-pull \
        git-push \
        git-repo-create \
        git-restore-from \
        git-stash \
        git-tag-create \
        git-tag-delete \
        git-tag-push \
        git-undo-commit; do
        direct_specs=$(capture_specs "$command_name" "")
        nested_specs=$(capture_specs git-menu "$command_name" "")
        [[ "$direct_specs" == "$nested_specs" ]] || return 6
        destructive_specs="$direct_specs"
        [[ "$destructive_specs" == *"--dry-run"* \
          && "$destructive_specs" == *"--yes"* ]] || return 7
      done

      for command_name in \
        clean-branches \
        clean-remote-merged \
        git-config-edit \
        git-pr-create \
        git-pull \
        git-push \
        git-repo-create \
        git-tag-create \
        git-tag-delete \
        git-tag-push; do
        direct_specs=$(capture_specs "$command_name" "")
        [[ "$direct_specs" == \
          *"(-h --help --dry-run -y --yes)-y["* ]] \
          || return 8
      done

      for command_name in git-merge git-rebase; do
        direct_specs=$(capture_specs "$command_name" "")
        nested_specs=$(capture_specs git-menu "$command_name" "")
        [[ "$direct_specs" == "$nested_specs" ]] || return 9
        confirmation_specs="$direct_specs"
        [[ "$confirmation_specs" == *"--yes"* \
          && "$confirmation_specs" != *"--dry-run"* ]] || return 10
      done

      help_specs=$(capture_specs \
        git-identity-switcher --switch personal --help "")
      [[ "$help_specs" == "MESSAGE:no additional arguments" ]] || return 11
    '

  if [ "$status" -ne 0 ]; then
    echo "Git contextual completion probe failed with status $status" >&2
    echo "$output" >&2
  fi
  [ "$status" -eq 0 ]
}
