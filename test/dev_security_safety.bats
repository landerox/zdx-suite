#!/usr/bin/env bats

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  mkdir -p "$DEV_PROJECT"

  export AUDIT_LOG="$TEST_TEMP_DIR/audit.log"
  export AUDIT_STDOUT="$TEST_TEMP_DIR/audit.stdout"
  export AUDIT_STDERR="$TEST_TEMP_DIR/audit.stderr"
  : > "$AUDIT_LOG"
}

teardown() {
  cleanup_sandbox
}

write_project_audit_backend() {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
set -u

if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  printf 'probe:pip_audit\n' >> "$AUDIT_LOG"
  exit "${AUDIT_PROBE_STATUS:-0}"
fi

{
  printf 'run'
  printf ' <%s>' "$@"
  printf '\n'
} >> "$AUDIT_LOG"
printf 'audit-backend-report\n'
exit "${AUDIT_EXIT_STATUS:-0}"
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"

  cat > "$TEST_MOCK_BIN/pip-audit" <<'EOF'
#!/usr/bin/env bash
printf 'global-pip-audit-must-not-run\n' >> "$AUDIT_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/pip-audit"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv-audit-must-not-run\n' >> "$AUDIT_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
}

write_bandit_backend() {
  export BANDIT_LOG="$TEST_TEMP_DIR/bandit.log"
  export BANDIT_STDOUT="$TEST_TEMP_DIR/bandit.stdout"
  export BANDIT_STDERR="$TEST_TEMP_DIR/bandit.stderr"

  cat > "$TEST_MOCK_BIN/bandit" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BANDIT_LOG"
printf 'bandit-backend-report\n'
exit "${BANDIT_EXIT_STATUS:-0}"
EOF
  chmod +x "$TEST_MOCK_BIN/bandit"
}

@test "dev security: audit uses only the isolated project backend and keeps UI on stderr" {
  write_project_audit_backend

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-audit >"$AUDIT_STDOUT" 2>"$AUDIT_STDERR"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$AUDIT_STDOUT")" = "audit-backend-report" ]
  grep -q "Running Dependency Security Audit" "$AUDIT_STDERR"
  grep -q "No known vulnerabilities found" "$AUDIT_STDERR"
  grep -q '^run <-I> <-m> <pip_audit>$' "$AUDIT_LOG"
  ! grep -q 'global-pip-audit-must-not-run' "$AUDIT_LOG"
  ! grep -q 'uv-audit-must-not-run' "$AUDIT_LOG"
}

@test "dev security: declining audit remediation starts no mutating backend" {
  write_project_audit_backend

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_confirm() {
      print -u2 -r -- "DECLINED"
      return 1
    }
    dev-run-audit --fix
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled. The project virtual environment was left unchanged."* ]]
  grep -q '^probe:pip_audit$' "$AUDIT_LOG"
  ! grep -q '^run' "$AUDIT_LOG"
}

@test "dev security: non-interactive audit remediation fails closed without --yes" {
  write_project_audit_backend

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-audit --fix'

  [ "$status" -eq 1 ]
  [[ "$output" == *"pass --yes with --fix"* ]]
  ! grep -q '^run' "$AUDIT_LOG"
}

@test "dev security: authorized audit remediation forwards --fix and restores confirmation state" {
  write_project_audit_backend

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-audit --yes --fix || return 1
    (( _DEV_AUTO_YES == 0 ))
  '

  [ "$status" -eq 0 ]
  grep -q '^run <-I> <-m> <pip_audit> <--fix>$' "$AUDIT_LOG"
}

@test "dev security: --yes without --fix is invalid and performs no probe" {
  write_project_audit_backend

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-audit --yes'

  [ "$status" -eq 2 ]
  [[ "$output" == *"--yes is valid only together with --fix"* ]]
  [ ! -s "$AUDIT_LOG" ]
}

@test "dev security: Bandit scans only bounded project files with exact arguments" {
  write_bandit_backend
  mkdir -p \
    "$DEV_PROJECT/src" \
    "$DEV_PROJECT/.venv" \
    "$DEV_PROJECT/.git" \
    "$DEV_PROJECT/node_modules" \
    "$DEV_PROJECT/vendor" \
    "$DEV_PROJECT/vendored" \
    "$DEV_PROJECT/build" \
    "$DEV_PROJECT/dist" \
    "$DEV_PROJECT/third-party/.git"

  : > "$DEV_PROJECT/src/app.py"
  : > "$DEV_PROJECT/src/name with space.py"
  : > "$DEV_PROJECT/.venv/excluded.py"
  : > "$DEV_PROJECT/.git/excluded.py"
  : > "$DEV_PROJECT/node_modules/excluded.py"
  : > "$DEV_PROJECT/vendor/excluded.py"
  : > "$DEV_PROJECT/vendored/excluded.py"
  : > "$DEV_PROJECT/build/excluded.py"
  : > "$DEV_PROJECT/dist/excluded.py"
  : > "$DEV_PROJECT/third-party/excluded.py"

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_SCAN_DEPTH=4
    dev-run-bandit --high-only >"$BANDIT_STDOUT" 2>"$BANDIT_STDERR"
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$BANDIT_STDOUT")" = "bandit-backend-report" ]
  grep -q "Scanning 2 Python file(s)" "$BANDIT_STDERR"
  grep -Fxq -- '-lll' "$BANDIT_LOG"
  grep -Fxq -- '-iii' "$BANDIT_LOG"
  grep -Fxq -- '--format' "$BANDIT_LOG"
  grep -Fxq -- 'txt' "$BANDIT_LOG"
  grep -Fxq -- '--' "$BANDIT_LOG"
  grep -Fxq -- './src/app.py' "$BANDIT_LOG"
  grep -Fxq -- './src/name with space.py' "$BANDIT_LOG"
  ! grep -q 'excluded.py' "$BANDIT_LOG"
}

@test "dev security: Bandit refuses an oversized file inventory before execution" {
  write_bandit_backend
  mkdir -p "$DEV_PROJECT/src"

  local index=1
  while (( index <= 513 )); do
    : > "$DEV_PROJECT/src/file-${index}.py"
    index=$((index + 1))
  done

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-bandit'

  [ "$status" -eq 1 ]
  [[ "$output" == *"safe limit of 512 entries"* ]]
  [ ! -e "$BANDIT_LOG" ]
}

@test "dev security: Bandit batches the bounded inventory" {
  mkdir -p "$DEV_PROJECT/src"
  local index=1
  while (( index <= 65 )); do
    : > "$DEV_PROJECT/src/file-${index}.py"
    index=$((index + 1))
  done
  export BANDIT_BATCH_LOG="$TEST_TEMP_DIR/bandit-batches.log"
  : > "$BANDIT_BATCH_LOG"

  cat > "$TEST_MOCK_BIN/bandit" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >> "$BANDIT_BATCH_LOG"
EOF
  chmod +x "$TEST_MOCK_BIN/bandit"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-bandit'

  [ "$status" -eq 0 ]
  [ "$(grep -c '^call$' "$BANDIT_BATCH_LOG")" -eq 2 ]
}

@test "dev security: Bandit propagates discovery failures before execution" {
  write_bandit_backend

  cat > "$TEST_MOCK_BIN/find" <<'EOF'
#!/usr/bin/env bash
exit 73
EOF
  chmod +x "$TEST_MOCK_BIN/find"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-bandit'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not discover nested repository boundaries"* ]]
  [ ! -e "$BANDIT_LOG" ]
}

@test "dev security: Bandit rejects unknown arguments before discovery" {
  write_bandit_backend

  cat > "$TEST_MOCK_BIN/find" <<'EOF'
#!/usr/bin/env bash
printf 'find-must-not-run\n' >&2
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/find"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-bandit --recursive'

  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --recursive"* ]]
  [[ "$output" != *"find-must-not-run"* ]]
  [ ! -e "$BANDIT_LOG" ]
}
