#!/usr/bin/env bats

setup() {
  load test_helper
  DOCKER_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/docker-public-commands.tsv"
  export TMPDIR="$HOME"
}

teardown() {
  cleanup_sandbox
}

@test "docker contract: snapshot membership treats full rows literally" {
  run run_zsh '
    local selected="Update all|docker-update|CLIs, images (latest)."
    local -a rows=(
      "$selected"
      "List|docker-list|Other row."
    )
    _docker_array_contains_literal "$selected" "${rows[@]}" || return 1
    ! _docker_array_contains_literal \
      "${selected} forged" "${rows[@]}" || return 2
  '

  [ "$status" -eq 0 ]
}

docker_contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$DOCKER_CONTRACT" | sort
}

assert_docker_contract_matches() {
  local surface_name="$1"
  local actual="$2"
  local expected
  expected=$(docker_contract_commands)
  if [[ "$actual" != "$expected" ]]; then
    printf 'Public Docker command drift in %s\n' "$surface_name" >&2
    diff -u \
      <(printf '%s\n' "$expected") \
      <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

@test "docker contract: fixture freezes eight unique valid commands" {
  local count=0 command_name module_name risk capability extra
  while IFS=$'\t' read -r \
    command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    [[ "$command_name" =~ ^docker-[a-z0-9-]+$ ]]
    [[ "$module_name" =~ ^docker-[a-z0-9-]+\.zsh$ ]]
    [[ "$risk" =~ ^(mixed|destructive|network|project-code|reversible|read-only)$ ]]
    [[ "$capability" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
    [[ -z "$extra" ]]
    [[ -f "$TEST_SUITE_ROOT/functions/docker/$module_name" ]]
    ((count += 1))
  done < "$DOCKER_CONTRACT"
  [ "$count" -eq 8 ]
  [ -z "$(docker_contract_commands | uniq -d)" ]
}

@test "docker contract: declared modules define and load every command" {
  local command_name module_name risk capability
  while IFS=$'\t' read -r \
    command_name module_name risk capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    grep -Eq "^${command_name}\\(\\)[[:space:]]*\\{" \
      "$TEST_SUITE_ROOT/functions/docker/$module_name"
  done < "$DOCKER_CONTRACT"

  local command_list
  command_list=$(docker_contract_commands | tr '\n' ' ')
  run run_zsh "
    local command_name
    for command_name in $command_list; do
      typeset -f \"\$command_name\" >/dev/null || return 1
    done
  "
  [ "$status" -eq 0 ]
}

@test "docker contract: dispatcher, help, and completion match the fixture" {
  local actual
  actual=$(
    sed -n '/^_docker_dispatch()/,/^}/p' \
      "$TEST_SUITE_ROOT/functions/docker-common.zsh" \
      | sed -nE \
        's/^[[:space:]]*(docker-[a-z0-9-]+)\)[[:space:]]+.*/\1/p' \
      | sort
  )
  assert_docker_contract_matches "dispatcher" "$actual"

  run run_zsh 'docker-menu --help'
  [ "$status" -eq 0 ]
  local token
  local -a help_commands=()
  for token in $output; do
    if [[ "$token" != "docker-menu" \
      && "$token" =~ ^docker-[a-z0-9-]+$ ]]; then
      help_commands+=("$token")
    fi
  done
  actual=$(printf '%s\n' "${help_commands[@]}" | sort -u)
  assert_docker_contract_matches "help" "$actual"

  actual=$(sed -n '1s/^#compdef[[:space:]]*//p' \
    "$TEST_SUITE_ROOT/completions/_docker-menu" \
    | tr ' ' '\n' | grep -v '^docker-menu$' | sort)
  assert_docker_contract_matches "completion bindings" "$actual"

  actual=$(sed -n '/docker_subcommands=(/,/)/p' \
    "$TEST_SUITE_ROOT/completions/_docker-menu" \
    | sed -n "s/^[[:space:]]*'\\([^:]*\\):.*/\\1/p" | sort)
  assert_docker_contract_matches "completion entries" "$actual"
}

@test "docker contract: interactive menu equals the fixture" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '
    docker-menu >/dev/null 2>&1
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE" | sort
  '
  [ "$status" -eq 0 ]
  assert_docker_contract_matches "interactive menu" "$output"
}

@test "docker contract: exact-root loader fails without sibling modules" {
  local isolated_root="$TEST_TEMP_DIR/isolated"
  mkdir -p "$isolated_root"
  cp "$TEST_SUITE_ROOT/functions/docker-menu.zsh" "$isolated_root/"
  cp "$TEST_SUITE_ROOT/functions/docker-common.zsh" "$isolated_root/"

  run env MENU_FILE="$isolated_root/docker-menu.zsh" zsh -f -c '
    source "$MENU_FILE"
    source_rc=$?
    (( source_rc != 0 )) || exit 1
    [[ -z "${_DOCKER_MENU_SOURCED:-}" ]] || exit 2
    exit 0
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed to load docker/docker-containers.zsh"* ]]
}

@test "docker contract: source is silent and idempotent" {
  run env MENU_FILE="$TEST_SUITE_ROOT/functions/docker-menu.zsh" zsh -f -c '
    source "$MENU_FILE" || exit
    source "$MENU_FILE" || exit
    print -r -- ready
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ready" ]
}

@test "docker contract: completion grammar is equal direct and nested" {
  run env COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_docker-menu" \
    zsh -f -c '
      capture_specs() {
        local -a words=("$@")
        local -i CURRENT=${#words[@]}
        _arguments() {
          if [[ "${1:-}" == "-C" ]]; then
            words=("${words[@]:1}")
            (( CURRENT-- ))
            state="docker-command-arguments"
            return 0
          fi
          print -rl -- "$@"
        }
        _describe() { return 0; }
        _files() { return 0; }
        source "$COMPLETION_FILE"
      }
      local command_name direct_specs nested_specs
      for command_name in \
        docker-containers docker-images docker-clean docker-login \
        docker-compose-up docker-compose-down \
        docker-compose-restart docker-compose-logs; do
        direct_specs=$(capture_specs "$command_name" "")
        nested_specs=$(capture_specs docker-menu "$command_name" "")
        [[ "$direct_specs" == "$nested_specs" ]] || return 1
      done
    '
  [ "$status" -eq 0 ]
}

@test "docker contract: completion flags follow the selected action" {
  run env COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_docker-menu" \
    zsh -f -c '
      capture_specs() {
        local -a words=("$@")
        local -i CURRENT=${#words[@]}
        _arguments() { print -rl -- "$@"; }
        _describe() { return 0; }
        _files() { return 0; }
        source "$COMPLETION_FILE"
      }
      local specs
      specs=$(capture_specs docker-containers --action exec "")
      [[ "$specs" == *"--shell["* \
        && "$specs" == *"--allow-remote"* \
        && "$specs" != *"--tail["* \
        && "$specs" != *"--yes["* \
        && "$specs" != *"--force["* ]] || return 1

      specs=$(capture_specs docker-containers --action remove "")
      [[ "$specs" == *"--force["* \
        && "$specs" == *"--yes["* \
        && "$specs" != *"--shell["* \
        && "$specs" != *"--tail["* ]] || return 2

      specs=$(capture_specs docker-images --action run "")
      [[ "$specs" == *"--shell["* \
        && "$specs" == *"--yes["* \
        && "$specs" != *"--force["* ]] || return 3
    '
  [ "$status" -eq 0 ]
}

@test "docker contract: completion value operands match parser grammar" {
  local completion_file="$TEST_SUITE_ROOT/completions/_docker-menu"
  local actual_options expected_options
  actual_options=$(
    sed -nE \
      "s/^[[:space:]]*'(--[a-z0-9-]+)\\[[^]]*\\]:.*/\\1/p" \
      "$completion_file" | sort -u
  )
  expected_options=$(
    printf '%s\n' \
      --action --file --id --registry --scope --shell --tail --username \
      | sort
  )
  [ "$actual_options" = "$expected_options" ]
  ! grep -Eq -- "'--[a-z0-9-]+=\\[" "$completion_file"

  run run_zsh '
    docker-menu --help >/dev/null 2>&1 || return

    local reached=""
    _docker_context_snapshot() {
      reached="context"
      return 91
    }
    _docker_compose_descriptor_snapshot() {
      reached="compose"
      return 91
    }
    _docker_require_cmd() {
      reached="registry"
      return 91
    }
    completion_arguments_reach_parser() {
      local expected_boundary="$1"
      shift
      reached=""
      "$@" >/dev/null 2>&1
      [[ "$reached" == "$expected_boundary" ]] || {
        print -u2 -r -- "Parser rejected completion-shaped arguments: $*"
        return 1
      }
    }

    local container_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local image_id="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    completion_arguments_reach_parser context \
      docker-containers --action exec --id "$container_id" \
      --shell /bin/bash --allow-remote || return
    completion_arguments_reach_parser context \
      docker-containers --action logs --id "$container_id" \
      --tail 250 --follow || return
    completion_arguments_reach_parser context \
      docker-images --action run --id "$image_id" \
      --shell /bin/sh --dry-run --yes --allow-remote || return
    completion_arguments_reach_parser context \
      docker-clean --scope dangling-images --dry-run || return
    completion_arguments_reach_parser compose \
      docker-compose-up --file compose.yaml --dry-run --yes \
      --allow-remote || return
    completion_arguments_reach_parser compose \
      docker-compose-logs --file compose.yaml --tail 500 --follow || return
    completion_arguments_reach_parser registry \
      docker-login --registry registry.example.test:5000 \
      --username tester --password-stdin || return
  '
  [ "$status" -eq 0 ]
}

@test "docker contract: lazy loader and plugin registration include all commands" {
  local command_name module_name risk capability
  while IFS=$'\t' read -r \
    command_name module_name risk capability; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    grep -Eq \
      "^[[:space:]]+${command_name}[[:space:]]+docker-menu[.]zsh$" \
      "$TEST_SUITE_ROOT/functions.zsh"
  done < "$DOCKER_CONTRACT"

  local registration_log="$TEST_TEMP_DIR/registrations"
  : > "$registration_log"
  run env REGISTRATION_LOG="$registration_log" \
    REPO_ROOT="$TEST_SUITE_ROOT" HOME="$HOME" PATH="$PATH" \
    ZDX_KEYBINDINGS=0 ZDX_LAZY_LOAD=1 zsh -f -c '
      compdef() {
        print -r -- "$1:${(j: :)argv[2,-1]}" >> "$REGISTRATION_LOG"
      }
      source "$REPO_ROOT/zdx-suite.plugin.zsh" || exit
      grep -F "_docker-menu:docker-menu docker-containers docker-images docker-clean docker-login docker-compose-up docker-compose-down docker-compose-restart docker-compose-logs" \
        "$REGISTRATION_LOG"
    '
  [ "$status" -eq 0 ]
}

@test "docker contract: registry precedes maintenance and cleanup is last" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '
    docker-menu >/dev/null 2>&1
    awk -F "|" '\''$2 != ":" && NF == 3 { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *$'docker-compose-restart\ndocker-login\ndocker-clean' ]]
}

@test "docker contract: master menu describes cleanup without prune" {
  run zsh -f -c '
    source "$1/functions/zdx-menu.zsh" || exit
    _zdx_menu_model
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  local docker_row
  docker_row=$(grep '|docker|' <<< "$output")
  [[ "$docker_row" == *"cleanup"* ]]
  [[ "$docker_row" != *"pruning"* ]]
}
