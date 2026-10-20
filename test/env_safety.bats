#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "env safety: PATH replacement after authorization is refused" {
  run run_zsh '
    export PATH="/usr/bin:/usr/bin"
    _env_confirm_mutation() {
      export PATH="/usr/local/bin:/usr/bin:/usr/bin"
      return 0
    }
    env-path --dedupe
    local -i dedupe_rc=$?
    print -r -- "PATH=$PATH"
    return $dedupe_rc
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"PATH changed after review"* ]]
  [[ "$output" == *"PATH=/usr/local/bin:/usr/bin:/usr/bin"* ]]
}

@test "env safety: non-interactive PATH deduplication requires --yes" {
  run run_zsh '
    export PATH="/usr/bin:/usr/bin"
    env-path --dedupe
    local -i dedupe_rc=$?
    [[ "$PATH" == "/usr/bin:/usr/bin" ]] || return 99
    return $dedupe_rc
  '
  [ "$status" -eq 2 ]
  [[ "$output" == *"pass --yes"* ]]
}

@test "env safety: deliberate mutation decline is successful cancellation" {
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
  ! grep -Fq "needle-that-must-not-leak" "$MOCK_FZF_INPUT_FILE" || false
  ! grep -Fq "needle-that-must-not-leak" "$MOCK_FZF_ARGS_FILE" || false
  grep -Fq "SUPER_SECRET_TOKEN" "$MOCK_FZF_INPUT_FILE"
  grep -Fq "********" "$MOCK_FZF_INPUT_FILE"
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
  [ "$(file_mode "$victim")" = "755" ]
}

@test "env safety: default diagnostics reserve stdout for documented data" {
  export MOCK_FZF_MODE="cancel"
  export MOCK_FZF_STATUS="130"
  run run_zsh '
    env-path >"$HOME/path.stdout"
    env-list >"$HOME/list.stdout"
    [[ ! -s "$HOME/path.stdout" \
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
    "$TEST_SUITE_ROOT/functions/env" || false
  grep -q '^_env_fzf_capture()' \
    "$TEST_SUITE_ROOT/functions/env-common.zsh"
}
