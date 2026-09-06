#!/usr/bin/env bats

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  mkdir -p "$DEV_PROJECT"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -p "$TMPDIR"
  chmod 700 "$TMPDIR"
}

teardown() {
  cleanup_sandbox
}

@test "dev state: same-second backups are unique and rollback preserves mode" {
  cat > "$TEST_MOCK_BIN/date" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  +%Y%m%d_%H%M%S) printf '%s\n' '20260725_120000' ;;
  *) printf '%s\n' '2026-07-25 12:00:00' ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/date"

  printf '[project]\nname = "before"\n' > "$DEV_PROJECT/pyproject.toml"
  chmod 644 "$DEV_PROJECT/pyproject.toml"

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-backup-pyproject || return 1
    local first="$_DEV_LAST_BACKUP_FILE"
    dev-backup-pyproject || return 1
    local second="$_DEV_LAST_BACKUP_FILE"
    [[ "$first" != "$second" && -f "$first" && -f "$second" ]] || return 1

    print "[project]\nname = \"changed\"" > pyproject.toml
    chmod 600 pyproject.toml
    _dev_restore_pyproject "$second" || return 1
    [[ "$(zstat +mode pyproject.toml)" -eq 33188 ]] || return 1
    command grep -q "before" pyproject.toml
  '

  [ "$status" -eq 0 ]
  [ "$(find "$DEV_PROJECT/.dev-suite-backups" -type f | wc -l)" -eq 2 ]
}

@test "dev state: retention always preserves the invocation backup" {
  printf '[project]\nname = "before"\n' > "$DEV_PROJECT/pyproject.toml"

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_BACKUP_RETENTION=1
    dev-backup-pyproject || return 1
    local previous="$_DEV_LAST_BACKUP_FILE"
    command touch -t 203701010000 -- "$previous" || return 1

    print -r -- "[project]" "name = \"current\"" > pyproject.toml
    dev-backup-pyproject || return 1
    [[ -f "$_DEV_LAST_BACKUP_FILE" \
      && "$_DEV_LAST_BACKUP_FILE" != "$previous" \
      && ! -e "$previous" ]]
  '

  [ "$status" -eq 0 ]
  [ "$(find "$DEV_PROJECT/.dev-suite-backups" -type f | wc -l)" -eq 1 ]
  grep -q 'name = "current"' \
    "$DEV_PROJECT"/.dev-suite-backups/pyproject.toml.*.bak
}

@test "dev state: rollback requires an exact backup and never falls back to git" {
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_restore_pyproject
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"exact pyproject.toml backup"* ]]
  ! grep -q 'git checkout' "$TEST_SUITE_ROOT/functions/dev/dev-state.zsh"
}

@test "dev state: rollback refuses a staged copy that differs from its backup" {
  printf '[project]\nname = "original"\n' > "$DEV_PROJECT/pyproject.toml"
  run run_zsh 'cd "$DEV_PROJECT" && dev-backup-pyproject'
  [ "$status" -eq 0 ]

  local backup_file
  backup_file=$(find "$DEV_PROJECT/.dev-suite-backups" -type f -name '*.bak')
  printf '[project]\nname = "live"\n' > "$DEV_PROJECT/pyproject.toml"

  cat > "$TEST_MOCK_BIN/cmp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/cmp"

  run run_zsh \
    "cd '$DEV_PROJECT' && _dev_restore_pyproject '$backup_file'"

  [ "$status" -eq 1 ]
  [[ "$output" == *"backup changed while it was being staged"* ]]
  grep -q 'name = "live"' "$DEV_PROJECT/pyproject.toml"
}

@test "dev state: rollback refuses an in-place destination edit" {
  printf '[project]\nname = "original"\n' > "$DEV_PROJECT/pyproject.toml"
  run run_zsh 'cd "$DEV_PROJECT" && dev-backup-pyproject'
  [ "$status" -eq 0 ]

  local backup_file
  backup_file=$(find "$DEV_PROJECT/.dev-suite-backups" -type f -name '*.bak')
  printf '[project]\nname = "live"\n' > "$DEV_PROJECT/pyproject.toml"

  run run_zsh "
    cd '$DEV_PROJECT'
    functions[_test_owned_file_fingerprint]=\
\"\$functions[_dev_owned_file_fingerprint]\"
    _dev_owned_file_fingerprint() {
      if [[ \"\${1:t}\" == 'pyproject.toml' ]]; then
        if [[ -e '$TEST_TEMP_DIR/destination-read' ]]; then
          print -r -- '[project]' 'name = \"concurrent\"' > \"\$1\"
        else
          : > '$TEST_TEMP_DIR/destination-read'
        fi
      fi
      _test_owned_file_fingerprint \"\$@\"
    }
    _dev_restore_pyproject '$backup_file'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed while rollback was being staged"* ]]
  grep -q 'name = "concurrent"' "$DEV_PROJECT/pyproject.toml"
}

@test "dev reports: same-second saves publish unique private files" {
  cat > "$TEST_MOCK_BIN/date" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  +%Y%m%d_%H%M%S) printf '%s\n' '20260725_120000' ;;
  *) printf '%s\n' '2026-07-25 12:00:00' ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/date"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_report_init "First"
    _dev_report_line "one"
    _dev_report_save "audit.md" || return 1
    _dev_report_init "Second"
    _dev_report_line "two"
    _dev_report_save "audit.md" || return 1
  '

  [ "$status" -eq 0 ]
  [ "$(find "$DEV_PROJECT/dev-suite-reports" -type f | wc -l)" -eq 2 ]
  while IFS= read -r report_file; do
    [ "$(stat -c '%a' "$report_file")" = "600" ]
  done < <(find "$DEV_PROJECT/dev-suite-reports" -type f)
}

@test "dev state: untrusted date output is never used as a path component" {
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  cat > "$TEST_MOCK_BIN/date" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '../../escaped'
EOF
  chmod +x "$TEST_MOCK_BIN/date"

  run run_zsh 'cd "$DEV_PROJECT" && dev-backup-pyproject'
  [ "$status" -eq 1 ]
  [[ "$output" == *"timestamp has an invalid format"* ]]

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_report_init "Unsafe Timestamp"
    _dev_report_line "must stay private"
    _dev_report_save "unsafe.md"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"timestamp has an invalid format"* ]]
  [ -z "$(find "$HOME" -maxdepth 2 -type f -name '*escaped*' -print)" ]
  [ -z "$(find "$DEV_PROJECT/.dev-suite-backups" \
    -type f -print 2>/dev/null)" ]
  [ -z "$(find "$DEV_PROJECT/dev-suite-reports" \
    -type f -print 2>/dev/null)" ]
}

@test "dev state: an untrusted mktemp path is neither written nor removed" {
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  export MKTEMP_VICTIM="$HOME/mktemp-victim"
  printf '%s\n' "preserve" > "$MKTEMP_VICTIM"
  chmod 600 "$MKTEMP_VICTIM"

  cat > "$TEST_MOCK_BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$MKTEMP_VICTIM"
EOF
  chmod +x "$TEST_MOCK_BIN/mktemp"

  run run_zsh 'cd "$DEV_PROJECT" && dev-backup-pyproject'
  [ "$status" -eq 1 ]
  [ "$(cat "$MKTEMP_VICTIM")" = "preserve" ]

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_report_init "Unsafe Temporary"
    _dev_report_line "must not escape"
    _dev_report_save "unsafe.md"
  '
  [ "$status" -eq 1 ]
  [ "$(cat "$MKTEMP_VICTIM")" = "preserve" ]
}

@test "dev export: final and parent symlinks are refused before uv runs" {
  printf '[project]\nname = "demo"\nversion = "1.0.0"\n' \
    > "$DEV_PROJECT/pyproject.toml"
  mkdir -p "$DEV_PROJECT/real"
  printf 'keep\n' > "$DEV_PROJECT/real/target.txt"
  ln -s "$DEV_PROJECT/real/target.txt" "$DEV_PROJECT/output.txt"
  ln -s "$DEV_PROJECT/real" "$DEV_PROJECT/linked-parent"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'UV MUST NOT RUN\n' >&2
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'cd "$DEV_PROJECT" && dev-export-deps -o output.txt --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlinked output path"* ]]
  [[ "$output" != *"UV MUST NOT RUN"* ]]
  [ "$(cat "$DEV_PROJECT/real/target.txt")" = "keep" ]

  run run_zsh \
    'cd "$DEV_PROJECT" && dev-export-deps -o linked-parent/new.txt --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlinked output path"* ]]
  [[ "$output" != *"UV MUST NOT RUN"* ]]
  [ ! -f "$DEV_PROJECT/real/new.txt" ]
}

@test "dev export: a destination changed after confirmation is not overwritten" {
  printf '[project]\nname = "demo"\nversion = "1.0.0"\n' \
    > "$DEV_PROJECT/pyproject.toml"
  printf 'original\n' > "$DEV_PROJECT/requirements.txt"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "export" ]]; then
  printf 'new==2.0.0\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_confirm_outcome() {
      command rm -f -- requirements.txt
      print -r -- "concurrent" > requirements.txt
      print -r -- "confirmed"
    }
    dev-export-deps
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed after authorization"* ]]
  [ "$(cat "$DEV_PROJECT/requirements.txt")" = "concurrent" ]
}

@test "dev export: an in-place destination edit after confirmation is detected" {
  printf '[project]\nname = "demo"\nversion = "1.0.0"\n' \
    > "$DEV_PROJECT/pyproject.toml"
  printf 'original\n' > "$DEV_PROJECT/requirements.txt"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'new==2.0.0\n'
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_confirm_outcome() {
      print -r -- "concurrent in-place edit" > requirements.txt
      print -r -- "confirmed"
    }
    dev-export-deps
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed after authorization"* ]]
  [ "$(cat "$DEV_PROJECT/requirements.txt")" = "concurrent in-place edit" ]
}

@test "dev export: a destination created at publication is not overwritten" {
  printf '[project]\nname = "demo"\nversion = "1.0.0"\n' \
    > "$DEV_PROJECT/pyproject.toml"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'new==2.0.0\n'
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    functions[_test_export_destination_identity]=\
"$functions[_dev_export_destination_identity]"
    _dev_export_destination_identity() {
      if [[ "${1:t}" != "requirements.txt" ]]; then
        _test_export_destination_identity "$@"
        return
      fi
      if [[ ! -e .identity-checked ]]; then
        : > .identity-checked
      else
        print -r -- "concurrent" > requirements.txt
      fi
      print -r -- "absent"
    }
    dev-export-deps
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"appeared before publication"* ]]
  [ "$(cat "$DEV_PROJECT/requirements.txt")" = "concurrent" ]
}

@test "dev export: requires a current lock and never refreshes it implicitly" {
  printf '[project]\nname = "demo"\nversion = "1.0.0"\n' \
    > "$DEV_PROJECT/pyproject.toml"
  printf 'sentinel\n' > "$DEV_PROJECT/uv.lock"
  export UV_LOG="$TEST_TEMP_DIR/uv-export.log"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$UV_LOG"
printf 'demo==1.0.0\n'
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'cd "$DEV_PROJECT" && dev-export-deps'

  [ "$status" -eq 0 ]
  grep -q \
    '^export --locked --format requirements.txt --no-hashes --no-default-groups$' \
    "$UV_LOG"
  [ "$(cat "$DEV_PROJECT/uv.lock")" = "sentinel" ]

  run run_zsh 'cd "$DEV_PROJECT" && dev-export-deps --dev --yes'
  [ "$status" -eq 0 ]
  grep -q \
    '^export --locked --format requirements.txt --no-hashes --no-default-groups --group dev$' \
    "$UV_LOG"

  run run_zsh 'cd "$DEV_PROJECT" && dev-export-deps --all --yes'
  [ "$status" -eq 0 ]
  grep -q \
    '^export --locked --format requirements.txt --no-hashes --all-groups$' \
    "$UV_LOG"
  [ "$(cat "$DEV_PROJECT/uv.lock")" = "sentinel" ]
}

@test "dev build: backend output is UI on stderr" {
  printf '[project]\nname = "demo"\nversion = "1.0.0"\n' \
    > "$DEV_PROJECT/pyproject.toml"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'backend stdout\n'
printf 'backend stderr\n' >&2
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  local stdout_file="$TEST_TEMP_DIR/build.out"
  local stderr_file="$TEST_TEMP_DIR/build.err"
  run run_zsh \
    "cd '$DEV_PROJECT' && dev-build-package >'$stdout_file' 2>'$stderr_file'"

  [ "$status" -eq 0 ]
  [ ! -s "$stdout_file" ]
  grep -q 'backend stdout' "$stderr_file"
  grep -q 'backend stderr' "$stderr_file"
}

@test "dev checks: outdated query failures and report-save failures propagate" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  case "${4:-}" in
    pytest|coverage) exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 97
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = ["requests>=2"]
EOF

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-outdated'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not query"* ]]

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_report_save() { return 1; }
    dev-check-outdated --report
  '
  [ "$status" -eq 1 ]
}

@test "dev checks: an empty dependency set still produces the requested report" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = []
EOF
  export UV_LOG="$TEST_TEMP_DIR/uv-outdated.log"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$UV_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    DEV_REPORT_DIR=reports
    dev-check-outdated --report
  '

  [ "$status" -eq 0 ]
  [ ! -e "$UV_LOG" ]
  local report_file
  report_file=$(find "$DEV_PROJECT/reports" -type f -name '*_outdated.md')
  [ -n "$report_file" ]
  grep -q 'No direct dependencies are declared' "$report_file"
}

@test "dev health: a broken virtual environment is reported as an error" {
  mkdir -p "$DEV_PROJECT/.venv"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = []
EOF
  : > "$DEV_PROJECT/uv.lock"

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-health'

  [ "$status" -eq 1 ]
  [[ "$output" == *".venv exists but is unsafe, incomplete, or has no usable Python interpreter"* ]]
  [[ "$output" != *".venv exists (unknown)"* ]]
}

@test "dev health: a non-Python project is a documented clean no-op" {
  printf '{"name":"node-only"}\n' > "$DEV_PROJECT/package.json"

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-health'

  [ "$status" -eq 0 ]
  [[ "$output" == *"not applicable"* ]]
  [[ "$output" != *"pyproject.toml not found"* ]]
  [[ "$output" != *"PyPI"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-health --report'

  [ "$status" -eq 0 ]
  local report_file
  report_file=$(find "$DEV_PROJECT/dev-suite-reports" -maxdepth 1 \
    -type f -name '*_health.md' -print -quit)
  [ -n "$report_file" ]
  grep -Fq 'Not applicable: no Python or uv project markers found' "$report_file"
}

@test "dev health: pre-commit resolves the effective worktree hook and requires executable mode" {
  local main_repo="$HOME/main-repository"
  rmdir "$DEV_PROJECT"
  git init -q "$main_repo"
  git -C "$main_repo" config user.name "ZDX Test"
  git -C "$main_repo" config user.email "zdx@example.invalid"
  : > "$main_repo/tracked"
  git -C "$main_repo" add tracked
  git -C "$main_repo" commit -qm "initial"
  git -C "$main_repo" worktree add -q -b linked "$DEV_PROJECT"

  local hook_file
  hook_file=$(
    git -C "$DEV_PROJECT" rev-parse --git-path hooks/pre-commit
  )
  [[ "$hook_file" == "$main_repo/"* ]]
  printf '#!/bin/sh\nexit 0\n' > "$hook_file"
  chmod 755 "$hook_file"

  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env sh
case "${1:-}" in
  --version) printf '%s\n' 'Python 3.12.1' ;;
  -I) printf '%s\n' 'cpython|3.12.1' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "worktree-health"
version = "1.0.0"
dependencies = []
EOF
  : > "$DEV_PROJECT/uv.lock"
  : > "$DEV_PROJECT/.pre-commit-config.yaml"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' 'uv 0.8.0'
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Pre-commit hooks installed."* ]]
  [[ "$output" != *"hooks are not installed"* ]]

  chmod 644 "$hook_file"
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"hooks are not installed"* ]]
  [[ "$output" != *"Pre-commit hooks installed."* ]]
}

@test "dev checks: coverage report and HTML failures are not masked" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  : > "$DEV_PROJECT/test_demo.py"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = []
[dependency-groups]
dev = ["coverage>=7"]
EOF

  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  case "${4:-}" in
    pytest|coverage) exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 97
EOF
  cat > "$DEV_PROJECT/.venv/bin/pytest" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$DEV_PROJECT/.venv/bin/coverage" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "run -m pytest"*) exit 0 ;;
  "report -m") exit 9 ;;
  "html") exit 8 ;;
esac
exit 97
EOF
  chmod +x \
    "$DEV_PROJECT/.venv/bin/python" \
    "$DEV_PROJECT/.venv/bin/pytest" \
    "$DEV_PROJECT/.venv/bin/coverage"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-coverage --html'

  [ "$status" -eq 9 ]
  [[ "$output" == *"Coverage report generation failed"* ]]
  [[ "$output" == *"HTML coverage generation failed"* ]]
}

@test "dev checks: project test and hook runners never consult uv or global PATH" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  : > "$DEV_PROJECT/test_demo.py"
  : > "$DEV_PROJECT/.pre-commit-config.yaml"
  export PROJECT_RUNNER_LOG="$TEST_TEMP_DIR/check-project-runners.log"
  export GLOBAL_RUNNER_LOG="$TEST_TEMP_DIR/check-global-runners.log"

  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  exit 0
fi
if [[ "${1:-}" == "-I" && "${2:-}" == "-m" ]]; then
  local_module="${3:-}"
  shift 3
  case "$local_module" in
    pytest) printf 'pytest:%s\n' "$*" >> "$PROJECT_RUNNER_LOG" ;;
    pre_commit) printf 'pre-commit:%s\n' "$*" >> "$PROJECT_RUNNER_LOG" ;;
    *) exit 97 ;;
  esac
  exit 0
fi
exit 97
EOF
  cat > "$DEV_PROJECT/.venv/bin/pytest" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected-wrapper:pytest:%s\n' "$*" >> "$GLOBAL_RUNNER_LOG"
exit 97
EOF
  cat > "$DEV_PROJECT/.venv/bin/pre-commit" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected-wrapper:pre-commit:%s\n' "$*" >> "$GLOBAL_RUNNER_LOG"
exit 97
EOF
  chmod +x \
    "$DEV_PROJECT/.venv/bin/python" \
    "$DEV_PROJECT/.venv/bin/pytest" \
    "$DEV_PROJECT/.venv/bin/pre-commit"

  local tool_name
  for tool_name in uv pytest pre-commit; do
    cat > "$TEST_MOCK_BIN/$tool_name" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$GLOBAL_RUNNER_LOG"
exit 97
EOF
    chmod +x "$TEST_MOCK_BIN/$tool_name"
  done

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-tests || return 1
    dev-run-hooks || return 1
  '

  [ "$status" -eq 0 ]
  grep -Fxq 'pytest:' "$PROJECT_RUNNER_LOG"
  grep -Fxq 'pre-commit:run --all-files' "$PROJECT_RUNNER_LOG"
  [ ! -e "$GLOBAL_RUNNER_LOG" ]
}

@test "dev checks: missing project runners cannot produce global false successes" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  : > "$DEV_PROJECT/test_demo.py"
  : > "$DEV_PROJECT/.pre-commit-config.yaml"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["pytest", "coverage", "pre-commit"]
EOF
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  case "${4:-}" in
    pytest|pytest_cov|coverage|pre_commit) exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 97
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  export GLOBAL_RUNNER_LOG="$TEST_TEMP_DIR/missing-project-global.log"

  local tool_name
  for tool_name in uv uvx pytest coverage pre-commit; do
    cat > "$TEST_MOCK_BIN/$tool_name" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$GLOBAL_RUNNER_LOG"
exit 0
EOF
    chmod +x "$TEST_MOCK_BIN/$tool_name"
  done

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tests'
  [ "$status" -eq 1 ]
  [[ "$output" == *"pytest is configured but is not installed"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-coverage'
  [ "$status" -eq 1 ]
  [[ "$output" == *"coverage is declared but is not installed"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-hooks'
  [ "$status" -eq 1 ]
  [[ "$output" == *"pre-commit is configured but is not installed"* ]]

  [ ! -e "$GLOBAL_RUNNER_LOG" ]
}

@test "dev checks: coverage options cannot succeed without a project backend" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  : > "$DEV_PROJECT/test_demo.py"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["pytest"]
EOF
  export COVERAGE_FALLBACK_LOG="$TEST_TEMP_DIR/coverage-fallback.log"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  case "${4:-}" in
    pytest_cov|coverage) exit 1 ;;
    *) exit 0 ;;
  esac
fi
if [[ "${1:-}" == "-I" && "${2:-}" == "-m" \
  && "${3:-}" == "pytest" ]]; then
  printf 'pytest-ran\n' >> "$COVERAGE_FALLBACK_LOG"
  exit 0
fi
exit 97
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"

  local tool_name
  for tool_name in pytest coverage; do
    cat > "$TEST_MOCK_BIN/$tool_name" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$COVERAGE_FALLBACK_LOG"
exit 0
EOF
    chmod +x "$TEST_MOCK_BIN/$tool_name"
  done

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-coverage --html'
  [ "$status" -eq 1 ]
  [[ "$output" == *"No coverage backend is installed"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-coverage --fail-under=80'
  [ "$status" -eq 1 ]
  [[ "$output" == *"No coverage backend is installed"* ]]

  [ ! -e "$COVERAGE_FALLBACK_LOG" ]
}

@test "dev checks: repeated coverage thresholds never leak parser state" {
  run run_zsh '
    unsetopt typesetsilent
    cd "$DEV_PROJECT"
    local captured
    captured=$(dev-run-coverage --fail-under=70 --fail-under=80)
    local -i coverage_status=$?
    print -u2 -r -- "CAPTURED_STDOUT=<$captured>"
    return $coverage_status
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"No test files or pytest configuration found"* ]]
  [[ "$output" == *"CAPTURED_STDOUT=<>"* ]]
  [[ "$output" != *"requested="* ]]
}

@test "dev checks: a symlinked project venv is refused before every backend" {
  local external_venv="$TEST_TEMP_DIR/external-venv"
  mkdir -p "$external_venv/bin"
  export EXTERNAL_RUNNER_LOG="$TEST_TEMP_DIR/external-venv.log"
  cat > "$external_venv/bin/python" <<'EOF'
#!/usr/bin/env bash
printf 'python:%s\n' "$*" >> "$EXTERNAL_RUNNER_LOG"
exit 0
EOF
  cat > "$external_venv/bin/pytest" <<'EOF'
#!/usr/bin/env bash
printf 'pytest:%s\n' "$*" >> "$EXTERNAL_RUNNER_LOG"
exit 0
EOF
  chmod +x "$external_venv/bin/python" "$external_venv/bin/pytest"
  ln -s "$external_venv" "$DEV_PROJECT/.venv"
  : > "$DEV_PROJECT/test_demo.py"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["requests>=2"]
EOF
  export UV_LOG="$TEST_TEMP_DIR/symlinked-venv-uv.log"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_LOG"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tests'
  [ "$status" -eq 1 ]
  [[ "$output" == *".venv must be a real directory"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-outdated'
  [ "$status" -eq 1 ]
  [[ "$output" == *".venv must be a real directory"* ]]

  [ ! -e "$EXTERNAL_RUNNER_LOG" ]
  [ ! -e "$UV_LOG" ]

  rm "$DEV_PROJECT/.venv"
  mkdir -p "$DEV_PROJECT/.venv/bin"
  ln -s "$(command -v python3)" "$DEV_PROJECT/.venv/bin/python"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tests test_demo.py'
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable .venv/bin/python"* ]]
  [ ! -e "$EXTERNAL_RUNNER_LOG" ]
}

@test "dev checks: a project wrapper with a PATH shebang is not trusted" {
  command python3 -m venv --without-pip "$DEV_PROJECT/.venv"
  : > "$DEV_PROJECT/test_demo.py"
  export HOSTILE_WRAPPER_LOG="$TEST_TEMP_DIR/hostile-wrapper.log"
  cat > "$DEV_PROJECT/.venv/bin/pytest" <<'EOF'
#!/usr/bin/env python3
from pathlib import Path
import os

Path(os.environ["HOSTILE_WRAPPER_LOG"]).write_text("executed\n")
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/pytest"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tests'

  [ "$status" -eq 1 ]
  [[ "$output" == *"pytest is configured but is not installed"* ]]
  [ ! -e "$HOSTILE_WRAPPER_LOG" ]
}

@test "dev checks: pytest status five is a no-op only without explicit arguments" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["pytest"]

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  case "${4:-}" in
    pytest) exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 97
EOF
  cat > "$DEV_PROJECT/.venv/bin/pytest" <<'EOF'
#!/usr/bin/env bash
exit 5
EOF
  chmod +x \
    "$DEV_PROJECT/.venv/bin/python" "$DEV_PROJECT/.venv/bin/pytest"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tests'
  [ "$status" -eq 0 ]
  [[ "$output" == *"collected no tests; nothing to run"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tests tests/missing.py'
  [ "$status" -eq 5 ]
  [[ "$output" == *"Tests failed (exit status: 5)"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-coverage'
  [ "$status" -eq 0 ]
  [[ "$output" == *"collected no tests; no coverage report was generated"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-coverage tests/missing.py'
  [ "$status" -eq 5 ]
  [[ "$output" == *"Tests failed (exit status: 5)"* ]]
}

@test "dev checks: explicit pytest targets bypass conventional-name discovery" {
  mkdir -p "$DEV_PROJECT/.venv/bin" "$DEV_PROJECT/scenarios"
  : > "$DEV_PROJECT/scenarios/unconventional.py"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "explicit-test-target"
version = "1.0.0"
dependencies = []

[dependency-groups]
dev = ["pytest-cov>=5"]
EOF
  export PYTEST_RUNNER_LOG="$TEST_TEMP_DIR/explicit-pytest-runner.log"

  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" ]]; then
  exit 0
fi
if [[ "${1:-}" == "-I" && "${2:-}" == "-m" \
  && "${3:-}" == "pytest" ]]; then
  shift 3
  printf '%s\n' "$*" >> "$PYTEST_RUNNER_LOG"
  exit 0
fi
exit 97
EOF
  cat > "$DEV_PROJECT/.venv/bin/pytest" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PYTEST_RUNNER_LOG"
exit 0
EOF
  chmod +x \
    "$DEV_PROJECT/.venv/bin/python" "$DEV_PROJECT/.venv/bin/pytest"

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-tests scenarios/unconventional.py::scenario || return 1
    dev-run-coverage scenarios/unconventional.py::scenario
  '

  [ "$status" -eq 0 ]
  grep -Fxq \
    'scenarios/unconventional.py::scenario' \
    "$PYTEST_RUNNER_LOG"
  grep -Fxq -- \
    '--cov --cov-report=term-missing scenarios/unconventional.py::scenario' \
    "$PYTEST_RUNNER_LOG"
}

@test "dev checks: read-only runners reject state-writing passthrough flags" {
  run run_zsh 'cd "$DEV_PROJECT" && dev-run-ruff --fix'
  [ "$status" -eq 2 ]
  [[ "$output" == *"read-only"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-eslint --cache'
  [ "$status" -eq 2 ]
  [[ "$output" == *"read-only"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-prettier --write'
  [ "$status" -eq 2 ]
  [[ "$output" == *"read-only"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-clippy --fix'
  [ "$status" -eq 2 ]
  [[ "$output" == *"source-rewriting"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tflint --fix'
  [ "$status" -eq 2 ]
  [[ "$output" == *"read-only"* ]]
}

@test "dev checks: ESLint refuses output and suppression state before running" {
  : > "$DEV_PROJECT/package.json"
  mkdir -p "$DEV_PROJECT/node_modules/.bin"
  export ESLINT_LOG="$TEST_TEMP_DIR/eslint.log"

  cat > "$DEV_PROJECT/node_modules/.bin/eslint" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ESLINT_LOG"
exit 99
EOF
  chmod +x "$DEV_PROJECT/node_modules/.bin/eslint"

  run run_zsh '
    cd "$DEV_PROJECT" || return 1
    local -a blocked_options=(
      "-o=$DEV_PROJECT/eslint-report.txt"
      --suppress-all
      --suppress-rule=no-console
      --prune-suppressions
      "--suppressions-location=$DEV_PROJECT/eslint-suppressions.json"
      "--cache-file=$DEV_PROJECT/eslint.cache"
      --init=true
    )
    local option
    local -i exit_code=0
    for option in "${blocked_options[@]}"; do
      dev-run-eslint "$option"
      exit_code=$?
      (( exit_code == 2 )) || return 1
    done
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"read-only"* ]]
  [[ "$output" == *"-o="* ]]
  [[ "$output" == *"--suppress-all"* ]]
  [[ "$output" == *"--cache-file="* ]]
  [ ! -e "$ESLINT_LOG" ]
}

@test "dev checks: Ruff lint overrides a mutating project default" {
  : > "$DEV_PROJECT/example.py"
  export RUFF_LOG="$TEST_TEMP_DIR/ruff.log"

  cat > "$TEST_MOCK_BIN/ruff" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$RUFF_LOG"
EOF
  chmod +x "$TEST_MOCK_BIN/ruff"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-ruff'

  [ "$status" -eq 0 ]
  grep -q '^check --no-fix --no-cache ' "$RUFF_LOG"
}

@test "dev checks: Ruff lint neutralizes an inherited output-file setting" {
  : > "$DEV_PROJECT/example.py"
  export RUFF_OUTPUT_FILE="$DEV_PROJECT/ruff-output.txt"
  export RUFF_ENV_LOG="$TEST_TEMP_DIR/ruff-env.log"

  cat > "$TEST_MOCK_BIN/ruff" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${RUFF_OUTPUT_FILE-unset}" > "$RUFF_ENV_LOG"
EOF
  chmod +x "$TEST_MOCK_BIN/ruff"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-ruff'

  [ "$status" -eq 0 ]
  [ "$(cat "$RUFF_ENV_LOG")" = "unset" ]
  [ ! -e "$DEV_PROJECT/ruff-output.txt" ]
}

@test "dev checks: outdated inventory is pinned to the project interpreter" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  : > "$DEV_PROJECT/.venv/bin/python"
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = ["requests>=2"]
EOF
  export UV_LOG="$TEST_TEMP_DIR/outdated-uv.log"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'UV_SYSTEM_PYTHON=%s\n' "${UV_SYSTEM_PYTHON-unset}" > "$UV_LOG"
printf 'args=%s\n' "$*" >> "$UV_LOG"
printf 'Package Version Latest Type\nrequests 2.0 3.0 wheel\n'
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-outdated'

  [ "$status" -eq 0 ]
  grep -Fxq 'UV_SYSTEM_PYTHON=0' "$UV_LOG"
  grep -Fq \
    "args=pip list --python $DEV_PROJECT/.venv/bin/python --outdated --format=columns" \
    "$UV_LOG"
}

@test "dev checks: license policy classifies only structured License fields" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  export REAL_PYTHON
  REAL_PYTHON=$(command -v python3)
  export LICENSE_MODE="restrictive"

  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" \
  && "${4:-}" == "$DEV_PROJECT/.venv" ]]; then
  exit 0
fi
if [[ "${1:-}" == "-I" && "${2:-}" == "-c" \
  && "${4:-}" == "piplicenses" ]]; then
  exit 0
fi
if [[ "$*" == *"-I -m piplicenses"* ]]; then
  if [[ "$*" == *"--format=table"* ]]; then
    printf '%s\n' \
      'Name Version License Author' \
      'safe 1.0 MIT GPL Foundation' \
      'weak 1.0 LGPL-3.0-only Example' \
      'dual 1.0 GPL-3.0-only OR LGPL-3.0-only Example'
  elif [[ "$LICENSE_MODE" == "restrictive" ]]; then
    printf '%s\n' \
      '[{"Name":"safe","Version":"1.0","License":"MIT","Author":"GPL Foundation"},' \
      '{"Name":"weak","Version":"1.0","License":"LGPL-3.0-only","Author":"Example"},' \
      '{"Name":"dual","Version":"1.0","License":"GPL-3.0-only OR LGPL-3.0-only","Author":"Example"}]'
  elif [[ "$LICENSE_MODE" == "safe" ]]; then
    printf '%s\n' \
      '[{"Name":"safe","Version":"1.0","License":"MIT","Author":"GPL Foundation"},' \
      '{"Name":"weak","Version":"1.0","License":"LGPL-3.0-only","Author":"Example"}]'
  elif [[ "$LICENSE_MODE" == "controls" ]]; then
    printf '%s\n' \
      '[{"Name":"evil\u001b[31m","Version":"1.0\rspoof",' \
      '"License":"GPL-3.0-only\u202e```","Author":"Example"}]'
  elif [[ "$LICENSE_MODE" == "oversized" ]]; then
    command head -c 10485762 /dev/zero | command tr '\0' x
  else
    printf '%s\n' '[{}]'
  fi
  exit 0
fi
exec "$REAL_PYTHON" "$@"
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"

  local stdout_file="$TEST_TEMP_DIR/licenses.out"
  local stderr_file="$TEST_TEMP_DIR/licenses.err"
  run run_zsh \
    "cd '$DEV_PROJECT' && dev-check-licenses >'$stdout_file' 2>'$stderr_file'"

  [ "$status" -eq 0 ]
  grep -q '^safe 1.0 MIT GPL Foundation$' "$stdout_file"
  grep -q '^dual | 1.0 | GPL-3.0-only OR LGPL-3.0-only$' "$stderr_file"
  ! grep -q '^safe |' "$stderr_file"
  ! grep -q '^weak |' "$stderr_file"

  run run_zsh 'cd "$DEV_PROJECT" && dev-check-licenses --strict'
  [ "$status" -eq 1 ]

  export LICENSE_MODE="safe"
  run run_zsh 'cd "$DEV_PROJECT" && dev-check-licenses --strict'
  [ "$status" -eq 0 ]
  [[ "$output" != *"Potentially restrictive"* ]]

  export LICENSE_MODE="malformed"
  run run_zsh 'cd "$DEV_PROJECT" && dev-check-licenses --strict'
  [ "$status" -eq 1 ]
  [[ "$output" == *"structured license inventory is invalid"* ]]

  export LICENSE_MODE="controls"
  run run_zsh 'cd "$DEV_PROJECT" && dev-check-licenses --strict --report'
  [ "$status" -eq 1 ]
  [[ "$output" == *"evil [31m | 1.0 spoof | GPL-3.0-only"* ]]
  [[ "$output" != *$'\e'* ]]
  [[ "$output" != *$'\u202e'* ]]

  local report_file
  report_file=$(find "$DEV_PROJECT/dev-suite-reports" \
    -type f -name '*_licenses.md' -print -quit)
  [ -n "$report_file" ]
  ! grep -q $'\e' "$report_file"
  ! grep -q $'\u202e' "$report_file"
  ! grep -q '^```' "$report_file"

  export LICENSE_MODE="oversized"
  run run_zsh 'cd "$DEV_PROJECT" && dev-check-licenses --strict'
  [ "$status" -eq 1 ]
  [[ "$output" == *"exceeds the 10 MiB safety limit"* ]]
}

@test "dev checks: environment inventories never use global tool binaries" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  export INVENTORY_LOG="$TEST_TEMP_DIR/inventory.log"
  export GLOBAL_TOOL_LOG="$TEST_TEMP_DIR/global-tool.log"

  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then
  exit 0
fi
printf '%s\n' "$*" >> "$INVENTORY_LOG"
case "$*" in
  *piplicenses*)
    printf 'Name Version License\nsafe 1.0 MIT\n'
    ;;
esac
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"

  for tool_name in pip-licenses pip-audit; do
    cat > "$TEST_MOCK_BIN/$tool_name" <<'EOF'
#!/usr/bin/env bash
printf 'used\n' >> "$GLOBAL_TOOL_LOG"
exit 97
EOF
    chmod +x "$TEST_MOCK_BIN/$tool_name"
  done

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-check-licenses || return 1
    dev-run-audit
  '

  [ "$status" -eq 0 ]
  grep -q -- '-I -m piplicenses' "$INVENTORY_LOG"
  grep -q -- '-I -m pip_audit' "$INVENTORY_LOG"
  [ ! -e "$GLOBAL_TOOL_LOG" ]
}

@test "dev checks: Pyright stub generation and ShellCheck arguments fail closed" {
  run run_zsh 'cd "$DEV_PROJECT" && dev-run-pyright --createstub demo'
  [ "$status" -eq 2 ]
  [[ "$output" == *"read-only"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-shellcheck --severity=warning'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "dev checks: Zsh parsing does not require ShellCheck" {
  : > "$DEV_PROJECT/example.zsh"
  export SHELLCHECK_LOG="$TEST_TEMP_DIR/shellcheck.log"

  cat > "$TEST_MOCK_BIN/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected\n' > "$SHELLCHECK_LOG"
exit 99
EOF
  chmod +x "$TEST_MOCK_BIN/shellcheck"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-shellcheck'

  [ "$status" -eq 0 ]
  [ ! -e "$SHELLCHECK_LOG" ]
}

@test "dev checks: ShellCheck batches a bounded project inventory" {
  mkdir -p "$DEV_PROJECT/scripts"
  local index=1
  while (( index <= 65 )); do
    : > "$DEV_PROJECT/scripts/check-${index}.sh"
    index=$((index + 1))
  done
  export SHELLCHECK_LOG="$TEST_TEMP_DIR/shellcheck-batches.log"
  : > "$SHELLCHECK_LOG"

  cat > "$TEST_MOCK_BIN/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >> "$SHELLCHECK_LOG"
EOF
  chmod +x "$TEST_MOCK_BIN/shellcheck"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-shellcheck'

  [ "$status" -eq 0 ]
  [ "$(grep -c '^call$' "$SHELLCHECK_LOG")" -eq 2 ]
}

@test "dev checks: TFLint init is explicit, confirmed, and status-checked" {
  : > "$DEV_PROJECT/main.tf"
  export TFLINT_LOG="$TEST_TEMP_DIR/tflint.log"
  : > "$TFLINT_LOG"

  cat > "$TEST_MOCK_BIN/tflint" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TFLINT_LOG"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/tflint"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tflint'
  [ "$status" -eq 0 ]
  ! grep -q '^--init$' "$TFLINT_LOG"
  grep -q '^--recursive$' "$TFLINT_LOG"

  : > "$TFLINT_LOG"
  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tflint --init'
  [ "$status" -eq 1 ]
  [[ "$output" == *"pass --yes"* ]]
  [ ! -s "$TFLINT_LOG" ]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-tflint --init --yes'
  [ "$status" -eq 0 ]
  grep -q '^--init$' "$TFLINT_LOG"
  grep -q '^--recursive$' "$TFLINT_LOG"
}

@test "dev checks: TFLint is not required outside a Terraform project" {
  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "tflint" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    dev-run-tflint
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"No Terraform files found"* ]]
  [[ "$output" != *"tflint not found"* ]]
}

@test "dev PyPI: curl ignores user config and permits HTTPS only" {
  export CURL_ARGV_LOG="$TEST_TEMP_DIR/curl-argv.log"
  export TMPDIR="$TEST_TEMP_DIR/pypi-tmp"
  mkdir -m 700 "$TMPDIR"

  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u
first="${1:-}"
url="${!#}"
[[ "$first" == "-q" ]] || exit 91
shift

proto=0
proto_redir=0
output_file=""
while (( $# > 0 )); do
  case "$1" in
    --proto)
      [[ "${2:-}" == "=https" ]] || exit 92
      proto=1
      shift 2
      ;;
    --proto-redir)
      [[ "${2:-}" == "=https" ]] || exit 93
      proto_redir=1
      shift 2
      ;;
    -o)
      output_file="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
(( proto && proto_redir )) || exit 94
printf 'first=%s proto=%d redir=%d url=%s\n' \
  "$first" "$proto" "$proto_redir" "$url" >> "$CURL_ARGV_LOG"

if [[ "$url" == "https://pypi.org/simple/" ]]; then
  printf '%s' '200'
else
  [[ -n "$output_file" && "$output_file" != "/dev/null" ]] || exit 95
  printf '%s\n' '{"info":{"version":"4.5.6"}}' > "$output_file"
fi
EOF
  chmod +x "$TEST_MOCK_BIN/curl"

  run run_zsh '
    _dev_pypi_check_connectivity || return 1
    local latest=""
    {
      latest=$(_dev_pypi_latest demo) || return 2
    } always {
      _dev_pypi_cache_cleanup
    }
    [[ "$latest" == "4.5.6" ]]
  '

  [ "$status" -eq 0 ]
  [ "$(grep -c '^first=-q proto=1 redir=1 url=https://pypi.org/' "$CURL_ARGV_LOG")" -eq 2 ]
}

@test "dev PyPI: invalid numeric configuration fails closed" {
  run run_zsh '
    export DEV_PYPI_TIMEOUT="1+1"
    _dev_pypi_cache_init
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_PYPI_TIMEOUT"* ]]
}

@test "dev temporary workspaces reject writable non-sticky roots" {
  local unsafe_tmp="$TEST_TEMP_DIR/unsafe-tmp"
  mkdir -p "$unsafe_tmp"
  chmod 777 "$unsafe_tmp"

  run run_zsh '
    export TMPDIR="'"$unsafe_tmp"'"
    _dev_pypi_cache_init
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"sticky bit"* ]]

  run run_zsh '
    export TMPDIR="'"$unsafe_tmp"'"
    _dev_update_workspace_create
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"sticky bit"* ]]
}

@test "dev PyPI: a cache read failure is preserved" {
  cat > "$TEST_MOCK_BIN/cat" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
  chmod +x "$TEST_MOCK_BIN/cat"

  run run_zsh '
    _dev_pypi_cache_init || return 1
    print -r -- "1.2.3" > "$_DEV_PYPI_CACHE_DIR/demo"
    chmod 600 "$_DEV_PYPI_CACHE_DIR/demo"
    _dev_pypi_latest demo
  '

  [ "$status" -eq 9 ]
}

@test "dev PyPI: direct URL dependencies retain only their distribution name" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
dependencies = [
  "main-pkg@https://example.invalid/main.whl",
  "Paren.Main(>=1)",
]

[dependency-groups]
dev = [
  "dev_pkg @ https://example.invalid/dev.whl",
  "Paren_Dev (>=2)",
]

[project.optional-dependencies]
docs = [
  "Docs.Pkg[theme] @ https://example.invalid/docs.whl",
  "Paren.Optional(>=3)",
]
EOF

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pyproject_all_deps || return 1
    print -rl -- "${reply[@]}"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *$'main-pkg\nParen.Main\ndev_pkg\nParen_Dev\nDocs.Pkg\nParen.Optional'* ]]
}

@test "dev PyPI: oversized project metadata is rejected before parsing" {
  command truncate -s 2097153 "$DEV_PROJECT/pyproject.toml"

  run run_zsh 'cd "$DEV_PROJECT" && _dev_pyproject_all_deps'

  [ "$status" -eq 1 ]
  [[ "$output" == *"larger than 2 MiB"* ]]
}

@test "dev PyPI: cleanup refuses a cache path swapped to a symlink" {
  mkdir -p "$DEV_PROJECT/victim"
  printf 'keep\n' > "$DEV_PROJECT/victim/marker"

  run run_zsh '
    _dev_pypi_cache_init || return 1
    local cache_dir="$_DEV_PYPI_CACHE_DIR"
    command mv -- "$cache_dir" "${cache_dir}.saved" || return 1
    command ln -s -- "$DEV_PROJECT/victim" "$cache_dir" || return 1
    _dev_pypi_cache_cleanup
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed identity"* ]]
  [ -f "$DEV_PROJECT/victim/marker" ]
}

@test "dev PyPI: pyproject parsers reject a symlinked metadata file" {
  cat > "$TEST_TEMP_DIR/external-pyproject.toml" <<'EOF'
[project]
dependencies = ["requests>=2"]
EOF
  ln -s "$TEST_TEMP_DIR/external-pyproject.toml" \
    "$DEV_PROJECT/pyproject.toml"

  run run_zsh 'cd "$DEV_PROJECT" && _dev_pyproject_has_dep requests'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Could not parse dependency metadata"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && _dev_pyproject_main_deps'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse pyproject.toml safely"* ]]
}

@test "dev PyPI: a replaced response body is never parsed" {
  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u
output_file=""
while (( $# > 0 )); do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$output_file" ]] || exit 97
mv -- "$output_file" "${output_file}.original"
printf '%s\n' '{"info":{"version":"9.9.9"}}' > "$output_file"
chmod 600 "$output_file"
EOF
  chmod +x "$TEST_MOCK_BIN/curl"

  run run_zsh '
    DEV_PYPI_RETRIES=0
    {
      _dev_pypi_latest demo
    } always {
      _dev_pypi_cache_cleanup
    }
  '

  [ "$status" -eq 1 ]
  [[ "$output" != *"9.9.9"* ]]
}
