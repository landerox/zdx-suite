#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "env safety: invalid records fail before any variable is exported" {
  run run_zsh '
    cd "$HOME"
    export PRESERVED=before
    cat > invalid.env <<'\''EOF'\''
PRESERVED=after
BAD-NAME=value
EOF
    env-switch --yes invalid.env >/dev/null 2>&1 || true
    [[ "$PRESERVED" == before && ${+BROKEN} -eq 0 ]]
  '
  [ "$status" -eq 0 ]
}

@test "env safety: dotenv symlinks and group-writable files are refused" {
  run run_zsh '
    cd "$HOME"
    print -r -- "SAFE=value" > real.env
    ln -s real.env linked.env
    env-switch --yes linked.env
  '
  [ "$status" -ne 0 ]

  run run_zsh '
    cd "$HOME"
    print -r -- "SAFE=value" > writable.env
    chmod 620 writable.env
    env-switch --yes writable.env
  '
  [ "$status" -ne 0 ]
}

@test "env safety: dotenv replacement after authorization is refused" {
  run run_zsh '
    cd "$HOME"
    print -r -- "FROZEN=original" > frozen.env
    _env_confirm_mutation() {
      print -r -- "FROZEN=replaced" > frozen.new
      mv frozen.new frozen.env
      return 0
    }
    env-switch frozen.env
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed after authorization"* ]]
}

@test "env safety: non-interactive session mutation requires --yes" {
  run run_zsh '
    cd "$HOME"
    print -r -- "NEEDS_CONFIRMATION=value" > guarded.env
    env-switch guarded.env
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"pass --yes"* ]]
}

@test "env safety: deliberate mutation decline is successful cancellation" {
  run run_zsh '
    cd "$HOME"
    print -r -- "DECLINED=value" > declined.env
    _env_confirm_mutation() { return 130; }
    env-switch declined.env
    [[ ${+DECLINED} -eq 0 ]]
  '
  [ "$status" -eq 0 ]

  run run_zsh '
    export PATH="/usr/bin:/usr/bin"
    local before="$PATH"
    _env_confirm_mutation() { return 130; }
    env-path --dedupe
    [[ "$PATH" == "$before" ]]
  '
  [ "$status" -eq 0 ]
}

@test "env safety: secret values never enter picker rows or previews" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '
    export SUPER_SECRET_TOKEN=needle-that-must-not-leak
    env-list >/dev/null 2>/dev/null
  '
  [ "$status" -eq 0 ]
  ! grep -Fq "needle-that-must-not-leak" "$MOCK_FZF_INPUT_FILE"
  ! grep -Fq "needle-that-must-not-leak" "$MOCK_FZF_ARGS_FILE"
  grep -Fq "SUPER_SECRET_TOKEN" "$MOCK_FZF_INPUT_FILE"
  grep -Fq "********" "$MOCK_FZF_INPUT_FILE"
}

@test "env safety: interactive value collection disables terminal echo" {
  grep -Eq 'IFS= read -r -s input_value' \
    "$TEST_SUITE_ROOT/functions/env/env-dotenv.zsh"
  ! grep -Eq 'IFS= read -r input_value' \
    "$TEST_SUITE_ROOT/functions/env/env-dotenv.zsh"
}

@test "env safety: list data withholds every raw value" {
  run run_zsh '
    export ACCESS_TOKEN=raw-secret
    export ORDINARY_VALUE=$'\''line-one\nline-two'\''
    env-list --list
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ACCESS_TOKEN\t********'* ]]
  [[ "$output" != *"raw-secret"* ]]
  [[ "$output" == *$'ORDINARY_VALUE\t<hidden>'* ]]
  [[ "$output" != *"line-one"* ]]
}

@test "env safety: forged picker output is rejected by snapshot membership" {
  export MOCK_FZF_MODE="response"
  export MOCK_FZF_RESPONSE="999|FORGED|********"
  export MOCK_FZF_STATUS="0"
  run run_zsh '
    export REAL_TOKEN=secret
    env-list
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in the current snapshot"* ]]
  [[ "$output" != *"secret"* ]]
}

@test "env safety: membership treats picker and PATH values as exact strings" {
  run run_zsh '
    export REAL_VALUE=hidden
    _env_fzf_capture() {
      REPLY="1]|FORGED|<hidden>"
      return 0
    }
    env-list
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in the current snapshot"* ]]
  [[ "$output" != *"invalid subscript"* ]]

  run run_zsh '
    export PATH="/tmp/zdx[1]:/tmp/zdx[1]:/tmp/zdx value:/tmp/zdx value"
    env-path --list
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *$'2\t/tmp/zdx[1]\tmissing\tn/a\tyes'* ]]
  [[ "$output" == *$'4\t/tmp/zdx value\tmissing\tn/a\tyes'* ]]
  [[ "$output" != *"invalid subscript"* ]]
}

@test "env safety: forged multi-row output is not treated as cancellation" {
  run run_zsh '
    export FIRST_VALUE=one SECOND_VALUE=two
    _env_fzf_capture() {
      REPLY=$'\''1|FIRST_VALUE|<hidden>\n2|SECOND_VALUE|<hidden>'\''
      return 0
    }
    env-list
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed environment-variable picker output"* ]]
  [[ "$output" != *"one"* && "$output" != *"two"* ]]
}

@test "env safety: nonempty failed picker output is not clean cancellation" {
  run run_zsh '
    export FIRST_VALUE=one SECOND_VALUE=two
    _env_fzf_capture() {
      REPLY=$'\''1|FIRST_VALUE|<hidden>\n2|SECOND_VALUE|<hidden>'\''
      return 130
    }
    env-list
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"picker failed (status 130)"* ]]
  [[ "$output" != *"one"* && "$output" != *"two"* ]]
}

@test "env safety: untrusted mktemp output is rejected before chmod" {
  local fake_bin="$TEST_TEMP_DIR/fake-mktemp-bin"
  local victim="$HOME/not-a-temp-child"
  local chmod_log="$TEST_TEMP_DIR/chmod.log"
  mkdir -p "$fake_bin" "$victim"
  : > "$chmod_log"
  cat > "$fake_bin/mktemp" <<'EOF'
#!/bin/sh
printf '%s\n' "$ENV_MKTEMP_OUTPUT"
EOF
  cat > "$fake_bin/chmod" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ENV_CHMOD_LOG"
exit 0
EOF
  chmod +x "$fake_bin/mktemp" "$fake_bin/chmod"

  ENV_MKTEMP_OUTPUT="$victim" \
    ENV_CHMOD_LOG="$chmod_log" \
    PATH="$fake_bin:$PATH" \
    run run_zsh '_env_fzf_capture </dev/null'

  [ "$status" -eq 125 ]
  [ ! -s "$chmod_log" ]
  [ -d "$victim" ]
}

@test "env safety: same-parent mktemp output requires private mode before cleanup" {
  local fake_bin="$TEST_TEMP_DIR/fake-private-mktemp-bin"
  local temp_root="$HOME/tmp"
  local victim="$temp_root/zdx-env-fzf.attacker"
  local mutation_log="$TEST_TEMP_DIR/temp-mutations.log"
  mkdir -p "$fake_bin" "$temp_root" "$victim"
  chmod 700 "$temp_root"
  chmod 755 "$victim"
  : > "$mutation_log"
  cat > "$fake_bin/mktemp" <<'EOF'
#!/bin/sh
printf '%s\n' "$ENV_MKTEMP_OUTPUT"
EOF
  cat > "$fake_bin/chmod" <<'EOF'
#!/bin/sh
printf 'chmod %s\n' "$*" >> "$ENV_MUTATION_LOG"
exit 0
EOF
  cat > "$fake_bin/rmdir" <<'EOF'
#!/bin/sh
printf 'rmdir %s\n' "$*" >> "$ENV_MUTATION_LOG"
exit 0
EOF
  chmod +x "$fake_bin/mktemp" "$fake_bin/chmod" "$fake_bin/rmdir"

  TMPDIR="$temp_root" \
    ENV_MKTEMP_OUTPUT="$victim" \
    ENV_MUTATION_LOG="$mutation_log" \
    PATH="$fake_bin:$PATH" \
    run run_zsh '_env_fzf_capture </dev/null'

  [ "$status" -eq 125 ]
  [ ! -s "$mutation_log" ]
  [ -d "$victim" ]
  [ "$(stat -c '%a' "$victim")" = "755" ]
}

@test "env safety: dry runs do not initialize or change filesystem state" {
  run run_zsh '
    cd "$HOME"
    print -r -- "DEFAULT=value" > .env.example
    env-create --template .env.example --dry-run
    [[ ! -e .env ]] || return 1

    export SNAPSHOT_VAR=value
    env-profile-save --dry-run planned SNAPSHOT_VAR
    [[ ! -e "$HOME/.config" ]]
  '
  [ "$status" -eq 0 ]
}

@test "env safety: profile save rejects variable changes after review" {
  run run_zsh '
    export SNAPSHOT_VAR=before
    _env_confirm_mutation() {
      export SNAPSHOT_VAR=after
      return 0
    }
    env-profile-save planned SNAPSHOT_VAR
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed after review"* ]]
  [ ! -e "$HOME/.config" ]
}

@test "env safety: profile state requires directory 700 and file 600" {
  run run_zsh '
    local profile_root="$HOME/.config/zdx/env-profiles"
    mkdir -p "$profile_root"
    chmod 755 "$profile_root"
    print -r -- "VALUE=unsafe" > "$profile_root/unsafe.env"
    chmod 600 "$profile_root/unsafe.env"
    env-profile-load --yes unsafe
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode 700"* ]]

  run run_zsh '
    local profile_root="$HOME/.config/zdx/env-profiles"
    mkdir -p "$profile_root"
    chmod 700 "$profile_root"
    print -r -- "VALUE=unsafe" > "$profile_root/unsafe.env"
    chmod 644 "$profile_root/unsafe.env"
    env-profile-load --yes unsafe
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"private file must have mode 600"* ]]
}

@test "env safety: profile state overrides must be absolute children of HOME" {
  run run_zsh '
    export SNAPSHOT_VAR=value
    ZDX_ENV_PROFILES_DIR=.profiles \
      env-profile-save --dry-run planned SNAPSHOT_VAR
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an absolute path below HOME"* ]]

  run run_zsh '
    export SNAPSHOT_VAR=value
    ZDX_ENV_PROFILES_DIR=/tmp/zdx-outside-home \
      env-profile-save --dry-run planned SNAPSHOT_VAR
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"child of HOME"* ]]
}

@test "env safety: profiles require the exact suite header and canonical keys" {
  run run_zsh '
    local profile_root="$HOME/.config/zdx/env-profiles"
    mkdir -p "$profile_root"
    chmod 700 "$HOME/.config" "$HOME/.config/zdx" "$profile_root"
    print -r -- "VALUE=data" > "$profile_root/missing-header.env"
    chmod 600 "$profile_root/missing-header.env"
    env-profile-load --yes missing-header
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"No safe environment profiles exist."* ]]

  run run_zsh '
    local profile_root="$HOME/.config/zdx/env-profiles"
    mkdir -p "$profile_root"
    chmod 700 "$HOME/.config" "$HOME/.config/zdx" "$profile_root"
    cat > "$profile_root/noncanonical.env" <<'\''EOF'\''
# zdx-environment-profile-v1
 VALUE=data
EOF
    chmod 600 "$profile_root/noncanonical.env"
    env-profile-load --yes noncanonical
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"No safe environment profiles exist."* ]]
}

@test "env safety: profile delete rejects replacement after confirmation" {
  run run_zsh '
    export PROFILE_VALUE=original
    env-profile-save --yes guarded PROFILE_VALUE
    local profile_file="$HOME/.config/zdx/env-profiles/guarded.env"
    _env_confirm_mutation() {
      print -r -- "# zdx-environment-profile-v1" > "$profile_file.new"
      print -r -- "PROFILE_VALUE=replaced" >> "$profile_file.new"
      chmod 600 "$profile_file.new"
      mv "$profile_file.new" "$profile_file"
      return 0
    }
    env-profile-delete guarded
  '
  [ "$status" -ne 0 ]
  [ -f "$HOME/.config/zdx/env-profiles/guarded.env" ]
}

@test "env safety: default diagnostics reserve stdout for documented data" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '
    env-path >"$HOME/path.stdout"
    env-profile-list >"$HOME/profiles.stdout"
    env-list >"$HOME/list.stdout"
    [[ ! -s "$HOME/path.stdout" \
      && ! -s "$HOME/profiles.stdout" \
      && ! -s "$HOME/list.stdout" ]]
  '
  [ "$status" -eq 0 ]
}

@test "env safety: menu helpers reject delimiters and controls" {
  run run_zsh '_env_menu_entry "bad|label" env-list description'
  [ "$status" -eq 2 ]

  run run_zsh '_env_menu_section "bad'$'\t''title" description'
  [ "$status" -eq 2 ]
}

@test "env safety: fzf is never captured through command substitution" {
  ! grep -R -Eq \
    '(selected|selection|template|profile)[[:space:]]*=[[:space:]]*\\$\\([^)]*fzf' \
    "$TEST_SUITE_ROOT/functions/env-menu.zsh" \
    "$TEST_SUITE_ROOT/functions/env-common.zsh" \
    "$TEST_SUITE_ROOT/functions/env"
  grep -q '^_env_fzf_capture()' \
    "$TEST_SUITE_ROOT/functions/env-common.zsh"
}
