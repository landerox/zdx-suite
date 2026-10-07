#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
#
# Environment dotenv check: the data-only parser, key comparison, hygiene
# facts, refusals, JSON shape, and the guarantee that no value escapes.

setup() {
  load test_helper
  export DOTENV_PROJECT="$HOME/project"
  mkdir -p "$DOTENV_PROJECT"
  # Git must not find a repository above the sandbox.
  export GIT_CEILING_DIRECTORIES="$TEST_TEMP_DIR"
}

teardown() {
  cleanup_sandbox
}

# write_dotenv NAME LINE...: write lines to a file in the project, mode 600.
write_dotenv() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "$DOTENV_PROJECT/$name"
  chmod 600 "$DOTENV_PROJECT/$name"
}

# run_dotenv ARGS...: run env-dotenv in the project with stdout and stderr in
# separate files; $output is "rc=<status>".
run_dotenv() {
  export DOTENV_ARGS_FILE="$TEST_TEMP_DIR/dotenv-args"
  printf '%s\0' "$@" > "$DOTENV_ARGS_FILE"
  run run_zsh '
    cd "$DOTENV_PROJECT" || return 99
    local -a dotenv_args=("${(@0)$(<"$DOTENV_ARGS_FILE")}")
    dotenv_args=("${(@)dotenv_args:#}")
    NO_COLOR=1 env-dotenv "${dotenv_args[@]}" \
      >"$TEST_TEMP_DIR/dotenv.stdout" 2>"$TEST_TEMP_DIR/dotenv.stderr"
    print -r -- "rc=$?"
  '
  DOTENV_STDOUT="$(cat "$TEST_TEMP_DIR/dotenv.stdout")"
  DOTENV_STDERR="$(cat "$TEST_TEMP_DIR/dotenv.stderr")"
}

# The edge-case fixture: line numbers are fixed by position.
write_grammar_fixture() {
  write_dotenv .env \
    '# zdx-canary-comment-line' \
    '' \
    'export EXPORTED=zdx-canary-exported' \
    '  INDENTED = zdx-canary-indented' \
    "SINGLE='zdx-canary single # not a comment'" \
    'DOUBLE="zdx-canary \"escaped\" value" # trailing comment' \
    'MULTI="zdx-canary-multi-first' \
    'zdx-canary-multi-second"' \
    'EQUALS=zdx-canary=with=equals' \
    'EMPTY_PLAIN=' \
    'EMPTY_QUOTED=""' \
    'EMPTY_COMMENT= # zdx-canary-comment-only' \
    'HASH_VALUE=zdx-canary#hash' \
    '1BAD=zdx-canary-bad-key' \
    'BAD-NAME=zdx-canary-dash' \
    'no equals zdx-canary-noeq' \
    'TRAILING="zdx-canary-trailing"garbage' \
    'export' \
    'DUPLICATE=zdx-canary-dup-one' \
    'DUPLICATE=' \
    "SINGLE_MULTI='zdx-canary-sm-1" \
    "zdx-canary-sm-2'" \
    'UNCLOSED="zdx-canary-unclosed' \
    'AFTER=zdx-canary-after'
}

@test "env dotenv: the parser emits key names and line numbers only" {
  write_grammar_fixture

  run run_zsh '_env_dotenv_parse "$(<"$DOTENV_PROJECT/.env")"'

  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    $'key\tEXPORTED' $'key\tINDENTED' $'key\tSINGLE' $'key\tDOUBLE' \
    $'key\tMULTI' $'key\tEQUALS' $'key\tEMPTY_PLAIN' $'key\tEMPTY_QUOTED' \
    $'key\tEMPTY_COMMENT' $'key\tHASH_VALUE' $'key\tDUPLICATE' \
    $'key\tSINGLE_MULTI' $'key\tAFTER' \
    $'empty\tEMPTY_PLAIN' $'empty\tEMPTY_QUOTED' $'empty\tEMPTY_COMMENT' \
    $'empty\tDUPLICATE' \
    $'duplicate\tDUPLICATE\t19,20' \
    $'malformed\t14' $'malformed\t15' $'malformed\t16' $'malformed\t17' \
    $'malformed\t18' $'malformed\t23')" ]
  [[ "$output" != *zdx-canary* ]]
}

@test "env dotenv: CRLF endings, a byte-order mark, and NUL bytes are handled" {
  printf '\357\273\277FIRST=zdx-canary-bom\r\nQUOTED="zdx-canary-crlf"\r\nEMPTY=\r\nMULTI="zdx-canary-a\r\nzdx-canary-b"\r\nNUL=zdx\000canary\r\nLAST=zdx-canary-last\r\n' \
    > "$DOTENV_PROJECT/.env"
  chmod 600 "$DOTENV_PROJECT/.env"

  run_dotenv --json

  [ "$output" = "rc=1" ]
  jq -e '
    .dotenv.key_count == 5
    and .dotenv.empty == ["EMPTY"]
    and .dotenv.malformed_lines == [6]
    and .dotenv.duplicates == []
  ' <<< "$DOTENV_STDOUT"
  [[ "$DOTENV_STDOUT$DOTENV_STDERR" != *canary* ]]
}

@test "env dotenv: key length, bare keys, and colon separators are malformed" {
  local long_key
  long_key="K$(printf 'x%.0s' {1..127})"
  write_dotenv .env \
    "${long_key}=1" \
    "${long_key}X=1" \
    'export BARE' \
    'BARE' \
    'COLON: value' \
    'SPACED  =  value  # note'

  run run_zsh '_env_dotenv_parse "$(<"$DOTENV_PROJECT/.env")"'

  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' $'key\t'"$long_key" $'key\tSPACED' \
    $'malformed\t2' $'malformed\t3' $'malformed\t4' $'malformed\t5')" ]
}

@test "env dotenv: long text lists are capped and point to --json" {
  local index
  local -a example_lines=()
  for (( index = 1; index <= 51; ++index )); do
    example_lines+=("KEY_$index=")
  done
  write_dotenv .env.example "${example_lines[@]}"
  local -a dotenv_lines=()
  for (( index = 1; index <= 21; ++index )); do
    dotenv_lines+=("bad line $index")
  done
  write_dotenv .env "${dotenv_lines[@]}"

  run_dotenv

  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *$'  KEY_50\n  … and 1 more; env-dotenv --json lists them all.'* ]]
  [[ "$DOTENV_STDERR" != *"KEY_51"* ]]
  [[ "$DOTENV_STDERR" == *"  Lines 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, and 1 more"* ]]

  run_dotenv --json
  jq -e '(.missing | length) == 51 and (.dotenv.malformed_lines | length) == 21' \
    <<< "$DOTENV_STDOUT"
}

@test "env dotenv: values from both files never reach stdout or stderr" {
  write_grammar_fixture
  write_dotenv .env.example \
    '# zdx-canary-example-comment' \
    'EXPORTED=zdx-canary-example-value' \
    'MISSING="zdx-canary-example-quoted"' \
    "MULTI='zdx-canary-example-multi" \
    "zdx-canary-example-second'" \
    'broken zdx-canary-example-broken'
  chmod 644 "$DOTENV_PROJECT/.env"

  local mode
  for mode in text json; do
    if [ "$mode" = json ]; then
      run_dotenv --json
    else
      run_dotenv
    fi
    [ "$output" = "rc=1" ]
    [[ "$DOTENV_STDOUT" != *canary* ]]
    [[ "$DOTENV_STDERR" != *canary* ]]
  done

  # The interactive dispatch and the menu row carry no value either.
  export MOCK_FZF_MODE="match" MOCK_FZF_MATCH="|env-dotenv|"
  run run_zsh 'cd "$DOTENV_PROJECT" && env-menu'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Dotenv Check"* ]]
  [[ "$output" != *canary* ]]
  ! grep -Fq canary "$MOCK_FZF_INPUT_FILE" "$MOCK_FZF_ARGS_FILE" || false
}

@test "env dotenv: missing, extra, empty, duplicate, and malformed keys are reported" {
  write_dotenv .env 'SHARED=1' 'EMPTY=' 'LOCAL_ONLY=1' 'SHARED=2' 'bad line'
  write_dotenv .env.example 'SHARED=' 'EMPTY=' 'NEEDED=' 'NEEDED=' '!'

  run_dotenv

  [ "$output" = "rc=1" ]
  [ -z "$DOTENV_STDOUT" ]
  [[ "$DOTENV_STDERR" == *"Keys:              3 in .env, 3 in .env.example"* ]]
  [[ "$DOTENV_STDERR" == *$'⚠ 1 key is in .env.example but missing in .env:\n  NEEDED'* ]]
  [[ "$DOTENV_STDERR" == *$'⚠ 1 key is in .env but not in .env.example:\n  LOCAL_ONLY'* ]]
  [[ "$DOTENV_STDERR" == *$'⚠ 1 key has an empty value in .env:\n  EMPTY'* ]]
  [[ "$DOTENV_STDERR" == *$'⚠ 1 key is assigned on more than one line in .env:\n  SHARED: lines 1, 4'* ]]
  [[ "$DOTENV_STDERR" == *$'⚠ 1 line in .env could not be parsed:\n  Line 5'* ]]
  [[ "$DOTENV_STDERR" == *$'⚠ 1 key is assigned on more than one line in .env.example:\n  NEEDED: lines 3, 4'* ]]
  [[ "$DOTENV_STDERR" == *$'⚠ 1 line in .env.example could not be parsed:\n  Line 5'* ]]
  [[ "$DOTENV_STDERR" == *"Dotenv check: 7 issues found — review the output above."* ]]

  run_dotenv --json
  [ "$output" = "rc=1" ]
  jq -e '
    .missing == ["NEEDED"] and .extra == ["LOCAL_ONLY"]
    and .dotenv.empty == ["EMPTY"]
    and .dotenv.duplicates == [{"key": "SHARED", "lines": [1, 4]}]
    and .dotenv.malformed_lines == [5]
    and .example.duplicates == [{"key": "NEEDED", "lines": [3, 4]}]
    and .example.malformed_lines == [5]
    and .in_sync == false and .issue_count == 7
  ' <<< "$DOTENV_STDOUT"
}

@test "env dotenv: a matching private file passes with status 0 and empty stdout" {
  write_dotenv .env 'export A=1' 'B="two"'
  write_dotenv .env.example 'A=' 'B='

  run_dotenv

  [ "$output" = "rc=0" ]
  [ -z "$DOTENV_STDOUT" ]
  [[ "$DOTENV_STDERR" == *"✔ .env defines every key in .env.example and no others."* ]]
  [[ "$DOTENV_STDERR" == *"✔ Every key in .env has a value."* ]]
  [[ "$DOTENV_STDERR" == *"✔ No duplicate keys or malformed lines."* ]]
  [[ "$DOTENV_STDERR" == *"➜ .env is not in a Git repository."* ]]
  [[ "$DOTENV_STDERR" == *"✔ Only its owner can read or write .env (mode 0600)."* ]]
  [[ "$DOTENV_STDERR" == *"✔ Dotenv check: no issues found."* ]]
}

@test "env dotenv: JSON output is exactly one document with the documented shape" {
  write_dotenv .env 'A=1' 'B=' 'A=2' 'oops'
  write_dotenv .env.example 'A=' 'C='

  run_dotenv --json

  [ "$output" = "rc=1" ]
  [ -z "$DOTENV_STDERR" ]
  [[ "$DOTENV_STDOUT" != *$'\033'* ]]
  [ "$(jq -s length "$TEST_TEMP_DIR/dotenv.stdout")" -eq 1 ]
  # Compact output: exactly one line, ended by its newline.
  [ "$(wc -l < "$TEST_TEMP_DIR/dotenv.stdout")" -eq 1 ]
  [ "$(tail -c 1 "$TEST_TEMP_DIR/dotenv.stdout" | od -An -c | tr -d ' ')" = '\n' ]
  [[ "$DOTENV_STDOUT" == '{"schema":"zdx.env-dotenv.v1",'*'}' ]]
  jq -e '
    keys_unsorted == ["schema", "dotenv", "example", "missing", "extra",
      "in_sync", "issue_count"]
    and .schema == "zdx.env-dotenv.v1"
    and (.dotenv | keys_unsorted) == ["path", "key_count", "empty",
      "duplicates", "malformed_lines", "mode", "readable_by_others",
      "writable_by_others", "owned_by_user", "git"]
    and (.dotenv.git | keys_unsorted) == ["repository", "tracked", "ignored"]
    and (.example | keys_unsorted) == ["path", "key_count", "duplicates",
      "malformed_lines"]
    and (.dotenv.path | endswith("/project/.env"))
    and (.example.path | endswith("/project/.env.example"))
    and .dotenv.key_count == 2 and .example.key_count == 2
    and .dotenv.empty == ["B"]
    and .dotenv.duplicates == [{"key": "A", "lines": [1, 3]}]
    and .dotenv.malformed_lines == [4]
    and .dotenv.mode == "0600"
    and .dotenv.readable_by_others == false
    and .dotenv.writable_by_others == false
    and .dotenv.owned_by_user == true
    and .dotenv.git == {"repository": false, "tracked": null, "ignored": null}
    and .missing == ["C"] and .extra == ["B"]
    and .in_sync == false and .issue_count == 5
  ' "$TEST_TEMP_DIR/dotenv.stdout"
}

@test "env dotenv: without an example only the dotenv file is checked" {
  write_dotenv .env 'A=1'

  run_dotenv

  [ "$output" = "rc=0" ]
  [[ "$DOTENV_STDERR" == *"Example file:      none found"* ]]
  [[ "$DOTENV_STDERR" == *"No example file was found next to .env; missing and extra keys were not checked."* ]]
  [[ "$DOTENV_STDERR" == *"Looked for .env.example, .env.sample, .env.template, .env.dist."* ]]

  run_dotenv --json
  [ "$output" = "rc=0" ]
  jq -e '.example == null and .missing == null and .extra == null
    and .in_sync == null and .issue_count == 0' <<< "$DOTENV_STDOUT"
}

@test "env dotenv: example discovery follows the documented order" {
  write_dotenv .env 'A=1'
  local name
  for name in .env.dist .env.template .env.sample .env.example; do
    write_dotenv "$name" 'A='
    run_dotenv --json
    [ "$output" = "rc=0" ]
    jq -e --arg name "$name" '.example.path | endswith("/" + $name)' \
      <<< "$DOTENV_STDOUT"
  done

  mkdir "$DOTENV_PROJECT/config"
  write_dotenv config/.env 'A=1'
  write_dotenv config/.env.dist 'A=' 'B='
  write_dotenv other.env 'A='
  run_dotenv config/.env --json
  [ "$output" = "rc=1" ]
  jq -e '(.example.path | endswith("/config/.env.dist")) and .missing == ["B"]' \
    <<< "$DOTENV_STDOUT"

  run_dotenv config/.env --example other.env --json
  [ "$output" = "rc=0" ]
  jq -e '.example.path | endswith("/project/other.env")' <<< "$DOTENV_STDOUT"
}

@test "env dotenv: Git tracking and ignore rules are reported, never changed" {
  git -C "$DOTENV_PROJECT" -c init.defaultBranch=main init -q
  write_dotenv .env 'A=1'

  run_dotenv
  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *$'⚠ .env is not ignored by Git, so it could be committed.\n  Add it to .gitignore.'* ]]

  printf '.env\n' > "$DOTENV_PROJECT/.gitignore"
  run_dotenv --json
  [ "$output" = "rc=0" ]
  jq -e '.dotenv.git == {"repository": true, "tracked": false, "ignored": true}' \
    <<< "$DOTENV_STDOUT"
  run_dotenv
  [[ "$DOTENV_STDERR" == *"✔ .env is ignored by Git and not tracked."* ]]

  git -C "$DOTENV_PROJECT" add -f .env
  run_dotenv
  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *"⚠ .env is tracked by Git, so its values are in the repository history."* ]]
  [[ "$DOTENV_STDERR" == *"  Stop tracking it with: git rm --cached -- .env"* ]]
  [[ "$DOTENV_STDERR" == *"  Its ignore rule has no effect while it is tracked."* ]]
  [ "$(git -C "$DOTENV_PROJECT" ls-files -- .env)" = ".env" ]

  run_dotenv --json
  jq -e '.dotenv.git == {"repository": true, "tracked": true, "ignored": true}
    and .issue_count == 1' <<< "$DOTENV_STDOUT"

  mkdir "$DOTENV_PROJECT/config"
  write_dotenv config/.env 'A=1'
  git -C "$DOTENV_PROJECT" add -f config/.env
  run_dotenv config/.env
  [[ "$DOTENV_STDERR" == *"  Stop tracking it with: git -C config rm --cached -- .env"* ]]
  [ "$(git -C "$DOTENV_PROJECT" ls-files -- config/.env)" = "config/.env" ]
}

@test "env dotenv: Git repository variables cannot redirect the probes" {
  git -C "$DOTENV_PROJECT" -c init.defaultBranch=main init -q
  mkdir "$HOME/other"
  git -C "$HOME/other" -c init.defaultBranch=main init -q
  write_dotenv .env 'A=1'
  git -C "$DOTENV_PROJECT" add -f .env

  export GIT_DIR="$HOME/other/.git" GIT_WORK_TREE="$HOME/other"
  run_dotenv --json
  unset GIT_DIR GIT_WORK_TREE

  jq -e '.dotenv.git.tracked == true' <<< "$DOTENV_STDOUT"
}

@test "env dotenv: Git matches the file name literally, not as a glob" {
  git -C "$DOTENV_PROJECT" -c init.defaultBranch=main init -q
  write_dotenv xa.env 'A=1'
  write_dotenv 'x*.env' 'A=1'
  printf 'xa.env\n' > "$DOTENV_PROJECT/.gitignore"
  git -C "$DOTENV_PROJECT" add -f xa.env

  run_dotenv 'x*.env' --json

  [ "$output" = "rc=1" ]
  [ -z "$DOTENV_STDERR" ]
  jq -e '.dotenv.git == {"repository": true, "tracked": false, "ignored": false}' \
    <<< "$DOTENV_STDOUT"
}

@test "env dotenv: open permissions are reported with a chmod hint, never changed" {
  write_dotenv .env 'A=1'
  chmod 640 "$DOTENV_PROJECT/.env"

  run_dotenv
  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *"⚠ .env is readable by other users (mode 0640)."* ]]
  [[ "$DOTENV_STDERR" == *"  Restrict it with: chmod -- 600 .env"* ]]
  [ "$(file_mode "$DOTENV_PROJECT/.env")" = "640" ]

  chmod 620 "$DOTENV_PROJECT/.env"
  run_dotenv
  [[ "$DOTENV_STDERR" == *"⚠ .env is writable by other users (mode 0620)."* ]]

  chmod 666 "$DOTENV_PROJECT/.env"
  run_dotenv --json
  jq -e '.dotenv.mode == "0666" and .dotenv.readable_by_others == true
    and .dotenv.writable_by_others == true and .issue_count == 1' \
    <<< "$DOTENV_STDOUT"
  [ "$(file_mode "$DOTENV_PROJECT/.env")" = "666" ]
}

@test "env dotenv: links, non-regular files, and oversized files are refused" {
  write_dotenv real.env 'A=1'
  ln -s real.env "$DOTENV_PROJECT/.env"
  run_dotenv
  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *"Refusing the dotenv file .env: it is a symbolic link."* ]]

  rm "$DOTENV_PROJECT/.env"
  mkdir "$DOTENV_PROJECT/.env"
  run_dotenv
  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *"Refusing the dotenv file .env: it is not a regular file."* ]]

  rmdir "$DOTENV_PROJECT/.env"
  mkfifo "$DOTENV_PROJECT/.env"
  run_dotenv
  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *"it is not a regular file."* ]]

  rm "$DOTENV_PROJECT/.env"
  make_sized_file "$DOTENV_PROJECT/.env" 1048577
  run_dotenv
  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *"Refusing the dotenv file .env: it is larger than 1 MiB."* ]]

  local index
  for (( index = 1; index <= 10001; ++index )); do
    printf 'K%d=v\n' "$index"
  done > "$DOTENV_PROJECT/.env"
  run_dotenv --json
  [ "$output" = "rc=1" ]
  [ -z "$DOTENV_STDOUT" ]
  [[ "$DOTENV_STDERR" == *"Refusing the dotenv file .env: it has more than 10000 lines."* ]]

  write_dotenv .env 'A=1'
  ln -s real.env "$DOTENV_PROJECT/.env.example"
  run_dotenv
  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *"Refusing the example file .env.example: it is a symbolic link."* ]]
}

@test "env dotenv: absent files fail with a next step" {
  write_dotenv .env.example 'A='
  run_dotenv
  [ "$output" = "rc=1" ]
  [[ "$DOTENV_STDERR" == *"No dotenv file exists at .env."* ]]
  [[ "$DOTENV_STDERR" == *"Create .env from .env.example, then run env-dotenv again."* ]]

  write_dotenv .env 'A=1'
  run_dotenv --example missing.env --json
  [ "$output" = "rc=1" ]
  [ -z "$DOTENV_STDOUT" ]
  [[ "$DOTENV_STDERR" == *"No example file exists at missing.env."* ]]
}

@test "env dotenv: invalid arguments return 2 before any file is read" {
  local invalid
  for invalid in "--bogus" "a.env b.env" "--example" "--json --json" \
    "--help extra" "--example a --example b"; do
    # shellcheck disable=SC2086
    run_dotenv $invalid
    [ "$output" = "rc=2" ]
    [ -z "$DOTENV_STDOUT" ]
  done

  run run_zsh 'env-dotenv --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"env-dotenv [FILE] [--example FILE] [--json]"* ]]
  [[ "$output" == *"Exit status: 0 when no issue is found"* ]]
}

@test "env dotenv: --json without jq fails closed on stderr" {
  write_dotenv .env 'A=1'

  run run_zsh '
    cd "$DOTENV_PROJECT" || return 99
    PATH="$TEST_MOCK_BIN" env-dotenv --json >"$HOME/json.stdout"
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"jq is required for env-dotenv --json."* ]]
  [ ! -s "$HOME/json.stdout" ]
}

@test "env dotenv: unusable or slow Git leaves its facts unknown" {
  write_dotenv .env 'A=1'

  run run_zsh '
    cd "$DOTENV_PROJECT" || return 99
    PATH="$TEST_MOCK_BIN" NO_COLOR=1 env-dotenv
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"git is not available, so tracking and ignore rules were not checked."* ]]

  run run_zsh '
    cd "$DOTENV_PROJECT" || return 99
    _env_run_with_timeout() { return 124; }
    env-dotenv --json
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Git did not answer within 10s; tracking and ignore rules were not checked."* ]]
  [[ "$output" == *'"repository":null'* ]]

  # Apple's placeholder git is never run while xcode-select reports nothing.
  printf '#!/bin/sh\nexit 2\n' > "$TEST_MOCK_BIN/xcode-select"
  chmod +x "$TEST_MOCK_BIN/xcode-select"
  run run_zsh '
    cd "$DOTENV_PROJECT" || return 99
    OSTYPE=darwin24.0
    whence() {
      if [[ "$1" == -p && "$2" == git ]]; then
        print -r -- /usr/bin/git
        return 0
      fi
      builtin whence "$@"
    }
    NO_COLOR=1 env-dotenv
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"git is not available"* ]]
}

@test "env dotenv: the menu row names a missing .env and dispatches the check" {
  run run_zsh 'cd "$DOTENV_PROJECT" && _env_menu_rows'
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n  ○ Inspect Dotenv File (unavailable: .env)|env-dotenv|'* ]]

  write_dotenv .env 'A=1'
  run run_zsh 'cd "$DOTENV_PROJECT" && _env_menu_rows'
  [[ "$output" == *$'\n  Inspect Dotenv File|env-dotenv|'* ]]

  export MOCK_FZF_MODE="match" MOCK_FZF_MATCH="|env-dotenv|"
  run run_zsh 'cd "$DOTENV_PROJECT" && NO_COLOR=1 env-menu'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Executing: env-dotenv"* ]]
  [[ "$output" == *"Dotenv check: no issues found."* ]]

  run run_zsh 'cd "$DOTENV_PROJECT" && zdx env env-dotenv --json'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"schema":"zdx.env-dotenv.v1",'* ]]
}

@test "env dotenv: direct and nested completion offer the same grammar" {
  run env COMPLETION_FILE="$TEST_SUITE_ROOT/completions/_env-menu" \
    zsh -f -c '
      capture_specs() {
        local service="$1"
        shift
        local -a words=("$@")
        local -i CURRENT=${#words[@]}
        _arguments() {
          if [[ "${1:-}" == "-C" ]]; then
            words=("${words[@]:1}")
            (( CURRENT-- ))
            state="args"
            return 0
          fi
          print -rl -- "$@"
        }
        _describe() { return 0; }
        source "$COMPLETION_FILE"
      }
      local direct nested
      direct=$(capture_specs env-dotenv env-dotenv "")
      nested=$(capture_specs env-menu env-menu env-dotenv "")
      [[ "$direct" == "$nested" ]] || return 1
      [[ "$direct" == *"--example[compare with this example file]:example file:_files"* ]] \
        || return 2
      [[ "$direct" == *"--json[emit one JSON report on stdout]"* ]] || return 3
      [[ "$direct" == *"1::dotenv file:_files"* ]] || return 4
    '
  [ "$status" -eq 0 ]
}
