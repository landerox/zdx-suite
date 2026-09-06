#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "env: loader and canonical help source without probing state" {
  run run_zsh '
    typeset -f env-menu >/dev/null
    env-menu --help
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Canonical subcommands:"* ]]
  [[ "$output" == *"env-profile-delete"* ]]
}

@test "env: passive parser loads literal ordinary values" {
  run run_zsh '
    cd "$HOME"
    cat > sample.env <<'\''EOF'\''
# passive data
KEY_ONE=value_one
KEY_TWO="value two"
KEY_THREE='\''value three'\''
KEY_FOUR=value=with=equals
LITERAL=$(touch should-not-exist)
EOF
    env-switch --yes sample.env
    print -r -- "ONE=$KEY_ONE"
    print -r -- "TWO=$KEY_TWO"
    print -r -- "THREE=$KEY_THREE"
    print -r -- "FOUR=$KEY_FOUR"
    print -r -- "LITERAL=$LITERAL"
    [[ ! -e should-not-exist ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ONE=value_one"* ]]
  [[ "$output" == *"TWO=value two"* ]]
  [[ "$output" == *"THREE=value three"* ]]
  [[ "$output" == *"FOUR=value=with=equals"* ]]
  [[ "$output" == *'LITERAL=$(touch should-not-exist)'* ]]
}

@test "env: quoted multiline data is literal and an unclosed file is atomic" {
  run run_zsh '
    cd "$HOME"
    cat > valid.env <<'\''EOF'\''
CERT="line one
line two"
EOF
    env-switch --yes valid.env
    [[ "$CERT" == $'\''line one\nline two'\'' ]] || return 1

    export PRESERVED=before
    cat > invalid.env <<'\''EOF'\''
PRESERVED=after
UNFINISHED="never closes
EOF
    env-switch --yes invalid.env
  '
  [ "$status" -ne 0 ]

  run run_zsh '
    cd "$HOME"
    export PRESERVED=before
    cat > invalid.env <<'\''EOF'\''
PRESERVED=after
UNFINISHED="never closes
EOF
    env-switch --yes invalid.env >/dev/null 2>&1 || true
    [[ "$PRESERVED" == before ]]
  '
  [ "$status" -eq 0 ]
}

@test "env: PATH inspection is read-only and dedupe is explicit" {
  run run_zsh '
    export PATH="/usr/local/bin:/usr/bin:/usr/local/bin::"
    local before="$PATH"
    env-path >/dev/null 2>&1
    [[ "$PATH" == "$before" ]] || return 1
    env-path --dedupe --dry-run >/dev/null 2>&1
    [[ "$PATH" == "$before" ]] || return 1
    env-path --dedupe --yes >/dev/null 2>&1
    print -r -- "$PATH"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/local/bin:/usr/bin:" ]
}

@test "env: create publishes an owner-only dotenv from a passive template" {
  run run_zsh '
    cd "$HOME"
    cat > .env.example <<'\''EOF'\''
APP_NAME=sample
APP_PORT=8080
EOF
    printf "custom-app\n\n" \
      | env-create --template .env.example --yes
    zmodload zsh/stat || return 1
    local -A file_state=()
    zstat -LH file_state -- "$HOME/.env" || return 1
    printf "MODE=%o\n" "$(( file_state[mode] & 8#777 ))"
    command cat "$HOME/.env"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"MODE=600"* ]]
  [[ "$output" == *"APP_NAME=custom-app"* ]]
  [[ "$output" == *"APP_PORT=8080"* ]]
}

@test "env: private profile lifecycle preserves values without sourcing code" {
  run run_zsh '
    export PROFILE_ONE=alpha
    export PROFILE_TWO='\''$(touch "$HOME/profile-executed")'\''
    env-profile-save --yes test-profile PROFILE_ONE PROFILE_TWO
    unset PROFILE_ONE PROFILE_TWO
    env-profile-load --yes test-profile
    [[ "$PROFILE_ONE" == alpha ]] || return 1
    [[ "$PROFILE_TWO" == '\''$(touch "$HOME/profile-executed")'\'' ]] \
      || return 1
    [[ ! -e "$HOME/profile-executed" ]] || return 1
    env-profile-list --list
    env-profile-delete --yes test-profile
    [[ ! -e "$HOME/.config/zdx/env-profiles/test-profile.env" ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *$'test-profile\t2'* ]]
}

@test "env: every value classification withholds the raw value" {
  run run_zsh '
    print -r -- "$(_env_value_classification MY_API_KEY)"
    print -r -- "$(_env_value_classification DB_PASSWORD)"
    print -r -- "$(_env_value_classification NORMAL_VAR)"
  '
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "********" ]
  [ "${lines[1]}" = "********" ]
  [ "${lines[2]}" = "<hidden>" ]
}
