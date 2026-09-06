#!/usr/bin/env bats

setup() {
  load test_helper
  AI_CONTRACT="$TEST_SUITE_ROOT/test/fixtures/ai-public-commands.tsv"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 "$TMPDIR"
}

teardown() {
  cleanup_sandbox
}

contract_commands() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$AI_CONTRACT" | sort
}

assert_ai_contract_matches() {
  local surface_name="$1"
  local actual="$2"
  local expected
  expected=$(contract_commands)
  if [[ "$actual" != "$expected" ]]; then
    printf 'Public AI command drift in %s\n' "$surface_name" >&2
    diff -u \
      <(printf '%s\n' "$expected") \
      <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

@test "ai contract: fixture freezes 28 unique canonical commands" {
  local count=0 command_name module_name risk capability extra
  while IFS=$'\t' read -r \
    command_name module_name risk capability extra; do
    [[ -z "$command_name" || "$command_name" == \#* ]] && continue
    ((count += 1))
    [[ "$command_name" =~ ^(ai-[a-z0-9-]+|global-clean-[a-z0-9-]+|project-sweep-ai)$ ]]
    [[ "$module_name" =~ ^ai-[a-z0-9-]+\.zsh$ ]]
    [[ "$risk" =~ ^(local-mutation|project-code|read-only|recoverable-mutation|remote-code)$ ]]
    [[ "$capability" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
    [ -f "$TEST_SUITE_ROOT/functions/ai/$module_name" ]
    [ -z "$extra" ]
  done < "$AI_CONTRACT"
  [ "$count" -eq 28 ]
  [ -z "$(contract_commands | uniq -d)" ]
  ! contract_commands | grep -qx 'aip-menu'
}

@test "ai contract: fixture exactly matches module-owned public functions" {
  local expected actual command_name
  expected=$(
    awk -F '\t' '!/^#/ && NF { print $1 "\t" $2 }' "$AI_CONTRACT" \
      | sort
  )
  actual=$(
    local module_file
    for module_file in "$TEST_SUITE_ROOT"/functions/ai/*.zsh; do
      sed -nE \
        's/^([[:alpha:]][[:alnum:]_-]*)\(\)[[:space:]]*\{.*/\1/p' \
        "$module_file" \
        | while IFS= read -r command_name; do
          printf '%s\t%s\n' "$command_name" "${module_file##*/}"
        done
    done | sort
  )
  if [[ "$actual" != "$expected" ]]; then
    diff -u \
      <(printf '%s\n' "$expected") \
      <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi

  local command_list
  command_list=$(contract_commands | tr '\n' ' ')
  run run_zsh "
    local command_name
    for command_name in $command_list; do
      typeset -f \"\$command_name\" >/dev/null || return 1
    done
  "
  [ "$status" -eq 0 ]
}

@test "ai contract: standalone loading is silent idempotent and probe-free" {
  run zsh -f -c '
    export HOME="$2/home"
    mkdir -p "$HOME"
    cd "$2" || exit
    probe() { print -r -- "$0" >> "$2/probes"; }
    npm() { probe; }
    npx() { probe; }
    curl() { probe; }
    fzf() { probe; }
    claude() { probe; }
    local before_path="$PATH" before_pwd="$PWD" before_options
    before_options="$(setopt)"
    source "$1/functions/ai-menu.zsh" >"$2/stdout" 2>"$2/stderr" || exit
    source "$1/functions/ai-menu.zsh" >>"$2/stdout" 2>>"$2/stderr" || exit
    [[ -n "${_AI_MENU_SOURCED:-}" && -n "${_AI_COMMON_SOURCED:-}" ]]
    [[ "$PATH" == "$before_path" && "$PWD" == "$before_pwd" ]]
    [[ "$(setopt)" == "$before_options" ]]
    [[ ! -s "$2/stdout" && ! -s "$2/stderr" && ! -e "$2/probes" ]]
    typeset -f ai-menu global-clean-ai ai-update ai-mcp-list >/dev/null
    ! typeset -f _timed >/dev/null
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR"
  [ "$status" -eq 0 ]
}

@test "ai contract: missing mandatory module leaves no false menu sentinel" {
  local broken="$TEST_TEMP_DIR/broken"
  mkdir -p "$broken/ai"
  cp "$TEST_SUITE_ROOT/functions/ai-menu.zsh" "$broken/"
  cp "$TEST_SUITE_ROOT/functions/ai-common.zsh" "$broken/"
  local module
  for module in "$TEST_SUITE_ROOT"/functions/ai/*.zsh; do
    [[ "${module##*/}" == "ai-log.zsh" ]] || cp "$module" "$broken/ai/"
  done

  run zsh -f -c '
    source "$1/ai-menu.zsh"
    local load_rc=$?
    (( load_rc != 0 ))
    [[ -z "${_AI_MENU_SOURCED:-}" ]]
    ! typeset -f _ai_menu_source_module >/dev/null
    [[ -z "${_ai_menu_loader_dir:-}" ]]
  ' _ "$broken"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed to load ai-log.zsh"* ]]
}

@test "ai contract: dispatcher and direct router forward exact arguments and status" {
  run run_zsh '
    ai-log-tail() {
      print -r -- "$#"
      print -rl -- "$@"
      return 19
    }
    _ai_dispatch ai-log-tail --lines "two words" --literal
  '
  [ "$status" -eq 19 ]
  [ "$output" = $'3\n--lines\ntwo words\n--literal' ]

  run run_zsh '
    _timed() {
      print -r -- "label:$1"
      shift
      "$@"
    }
    ai-log-tail() {
      print -rl -- "$@"
      return 23
    }
    ai-menu ai-log-tail --lines 7
  '
  [ "$status" -eq 23 ]
  [ "$output" = $'label:ai:ai-log-tail\n--lines\n7' ]
}

@test "ai contract: unknown command and malformed router usage return 2" {
  run run_zsh '_ai_dispatch arbitrary-command'
  [ "$status" -eq 2 ]
  run run_zsh 'ai-menu arbitrary-command'
  [ "$status" -eq 2 ]
  run run_zsh 'ai-menu --multi extra'
  [ "$status" -eq 2 ]
  run run_zsh 'ai-menu ""'
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty command name"* ]]
}

@test "ai contract: snapshot completion lists only private valid tokens newest first" {
  local root="$HOME/.ai-suite-backups"
  mkdir -p \
    "$root/20260101T010101-1" \
    "$root/20260102T020202-22" \
    "$root/20260103T030303-3" \
    "$root/not-a-token"
  printf x > "$root/20260104T040404-4"
  ln -s "$root/20260101T010101-1" "$root/20260105T050505-5"
  chmod 700 "$root" "$root/20260101T010101-1" "$root/20260102T020202-22" \
    "$root/not-a-token"
  chmod 750 "$root/20260103T030303-3"

  run zsh -f -c '
    _arguments() { return 0; }
    _describe() {
      print -rl -- "${tokens[@]}"
    }
    source "$1"
    _ai_menu_snapshot_tokens
  ' _ "$TEST_SUITE_ROOT/completions/_ai-menu"
  [ "$status" -eq 0 ]
  [ "$output" = $'20260102T020202-22\n20260101T010101-1' ]

  chmod 750 "$root"
  run zsh -f -c '
    _arguments() { return 0; }
    _describe() {
      print -rl -- "${tokens[@]}"
    }
    source "$1"
    _ai_menu_snapshot_tokens
  ' _ "$TEST_SUITE_ROOT/completions/_ai-menu"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ai contract: dispatcher exactly matches the frozen surface" {
  local actual
  actual=$(
    sed -n '/^_ai_dispatch()/,/^}/p' \
      "$TEST_SUITE_ROOT/functions/ai-common.zsh" \
      | sed -nE \
        's/^[[:space:]]+([^[:space:])]+)\).*/\1/p' \
      | grep -Ev '^(""|\*)$' \
      | sort
  )
  assert_ai_contract_matches "dispatcher" "$actual"
}

@test "ai contract: fzf adapter preserves 130 while public menu cancels cleanly" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '_ai_fzf_capture </dev/null'
  [ "$status" -eq 130 ]
  run run_zsh 'ai-menu'
  [ "$status" -eq 0 ]
}

@test "ai contract: help and completion exactly match the frozen surface" {
  run run_zsh 'ai-menu --help'
  [ "$status" -eq 0 ]
  local actual
  actual=$(
    sed -nE \
      's/^[[:space:]]{2}([[:alpha:]][[:alnum:]_-]+)[[:space:]].*/\1/p' \
      <<< "$output" \
      | grep -v '^ai-menu$' \
      | sort -u
  )
  assert_ai_contract_matches "help" "$actual"

  actual=$(sed -n '1s/^#compdef[[:space:]]*//p' \
    "$TEST_SUITE_ROOT/completions/_ai-menu" \
    | tr ' ' '\n' \
    | grep -v '^ai-menu$' \
    | sort)
  assert_ai_contract_matches "completion bindings" "$actual"

  actual=$(
    sed -n '/^ai_subcommands=(/,/^)/p' \
      "$TEST_SUITE_ROOT/completions/_ai-menu" \
      | sed -n "s/^[[:space:]]*'\\([^:]*\\):.*/\\1/p" \
      | sort
  )
  assert_ai_contract_matches "completion subcommands" "$actual"
}

@test "ai contract: direct and nested completion grammar agree for every command" {
  run env COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_ai-menu" \
    CONTRACT_FILE="$AI_CONTRACT" zsh -f -c '
      capture_specs() {
        local -a words=("$@")
        local -i CURRENT=${#words[@]}
        _arguments() {
          if [[ "${1:-}" == "-C" ]]; then
            words=("${words[@]:1}")
            (( CURRENT-- ))
            state="ai-command-arguments"
            return 0
          fi
          print -rl -- "$@"
        }
        _describe() { return 0; }
        _directories() { return 0; }
        source "$COMPLETION_FILE"
      }

      local command_name _rest direct_specs nested_specs
      while IFS=$'\''\t'\'' read -r command_name _rest; do
        [[ -z "$command_name" || "$command_name" == \#* ]] && continue
        direct_specs=$(capture_specs "$command_name" "")
        nested_specs=$(capture_specs ai-menu "$command_name" "")
        [[ "$direct_specs" == "$nested_specs" ]] || {
          print -u2 -r -- \
            "completion grammar differs for $command_name"
          return 1
        }
        if [[ "$command_name" == ai-update* \
          && "$direct_specs" != *"--result-tsv"* ]]; then
          print -u2 -r -- \
            "result record completion is missing for $command_name"
          return 2
        fi
      done < "$CONTRACT_FILE"
    '
  [ "$status" -eq 0 ]
}

@test "ai contract: interactive menu exactly matches the frozen surface" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '
    ai-menu >/dev/null 2>&1
    awk -F "|" '\''NF == 3 && $2 != ":" { print $2 }'\'' \
      "$MOCK_FZF_INPUT_FILE" | sort
  '
  [ "$status" -eq 0 ]
  assert_ai_contract_matches "interactive menu" "$output"
}

@test "ai contract: an exact menu row dispatches without arithmetic parsing" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="  Run Diagnostics|ai-doctor|Inspect installed assistants, configuration paths, and runtime health."

  run run_zsh '
    ai-doctor() {
      print -r -- "exact-ai-route"
    }
    ai-menu
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"exact-ai-route"* ]]
  [[ "$output" != *"invalid subscript"* ]]
}

@test "ai contract: multi-select inventory contains only read-only commands" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '
    ai-menu --multi
    awk -F "|" "NF { print \$2 }" "$MOCK_FZF_INPUT_FILE"
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'ai-doctor\nai-disk-usage\nai-versions\nai-log-tail\nai-mcp-list\nai-mcp-doctor' ]
}

@test "ai contract: cold lazy stubs exactly match and hot-load the fixture" {
  run env REPO_ROOT="$TEST_SUITE_ROOT" CONTRACT_FILE="$AI_CONTRACT" \
    HOME="$HOME" PATH="$PATH" ZDX_LAZY_LOAD=1 zsh -f -c '
      unset TEST_TEMP_DIR BATS_TEST_DIRNAME ZDX_EAGER_LOAD
      source "$REPO_ROOT/functions.zsh" || exit
      (( ! ${+functions[_ai_dispatch]} )) || return 1

      local command_name _rest lazy_name
      local -A expected=()
      while IFS=$'\''\t'\'' read -r command_name _rest; do
        [[ -z "$command_name" || "$command_name" == \#* ]] && continue
        expected[$command_name]=1
        [[ "${_ZDX_LAZY_FILES[$command_name]:-}" == "ai-menu.zsh" ]] \
          || return 2
        [[ "${functions[$command_name]:-}" \
          == *"_zdx_lazy_dispatch"* ]] || return 3
      done < "$CONTRACT_FILE"

      local -i actual_count=0
      for lazy_name in ${(k)_ZDX_LAZY_FILES}; do
        [[ "${_ZDX_LAZY_FILES[$lazy_name]}" == "ai-menu.zsh" \
          && "$lazy_name" != "ai-menu" ]] || continue
        (( actual_count += 1 ))
        [[ -n "${expected[$lazy_name]:-}" ]] || return 4
      done
      (( actual_count == ${#expected} )) || return 5
      [[ "${_ZDX_LAZY_FILES[ai-menu]:-}" == "ai-menu.zsh" \
        && "${functions[ai-menu]:-}" == *"_zdx_lazy_dispatch"* ]] || return 6

      ai-menu --help >/dev/null 2>&1 || return 7
      (( ${+functions[_ai_dispatch]} )) || return 8
      for command_name in ${(k)expected}; do
        (( ${+functions[$command_name]} )) || return 9
        [[ "${functions[$command_name]}" != *"_zdx_lazy_dispatch"* ]] \
          || return 10
      done
    '
  [ "$status" -eq 0 ]
}
