#!/usr/bin/env bats
# Quoted programs execute in Zsh; each BATS test owns its exported mock state.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  export UPDATE_LOG="$TEST_TEMP_DIR/update.log"
  mkdir -m 700 "$DEV_PROJECT" "$TMPDIR"
}

teardown() {
  cleanup_sandbox
}

write_hook_project() {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
dependencies = ["pre-commit>=1.0.0"]
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  cat > "$DEV_PROJECT/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/available
    rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1.0.0
    hooks:
      - id: available
  - repo: https://example.invalid/unavailable
    rev: cccccccccccccccccccccccccccccccccccccccc # frozen: v1.0.0
    hooks:
      - id: unavailable
EOF
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv:%s\n' "$*" >> "$UPDATE_LOG"
exit 0
EOF
  cat > "$TEST_MOCK_BIN/pre-commit" <<'EOF'
#!/usr/bin/env bash
printf 'hooks:%s\n' "$*" >> "$UPDATE_LOG"
printf 'network:%s:%s\n' "${GIT_HTTP_LOW_SPEED_LIMIT:-}" \
  "${GIT_HTTP_LOW_SPEED_TIME:-}" >> "$UPDATE_LOG"
case "$1" in
  autoupdate)
    sed -i 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1.0.0/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v1.1.0/' "$4"
    if [[ "${UNSAFE_PLAN:-0}" == 1 ]]; then
      printf 'fail_fast: true\n' >> "$4"
    fi
    exit "${AUTOUPDATE_STATUS:-0}"
    ;;
  install-hooks) exit "${INSTALL_STATUS:-0}" ;;
  validate-config|install|run) exit 0 ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/pre-commit"
}

run_hook_update() {
  run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() {
      print -r -- "probe" >> "$UPDATE_LOG"
      return "${PYPI_STATUS:-0}"
    }
    _dev_pypi_latest() {
      print -r -- "query" >> "$UPDATE_LOG"
      print -r -- "1.0.0"
    }
    # Runner provenance has dedicated integration coverage; this fixture
    # isolates the external updater behavior and publication transaction.
    _dev_exact_project_python_tool_runner() {
      reply=("$TEST_MOCK_BIN/pre-commit")
    }
    if [[ "${AGGREGATE_UPDATE:-0}" == 1 ]]; then
      dev-update-toolchain() { return 0; }
      dev-update-deps() { _dev_update_pypi_ready; }
      dev-update-lock() { return 0; }
      dev-update-terraform() { return 0; }
      dev-update-tflint() { return 0; }
      dev-clean-all() { return 0; }
      dev-menu dev-update-all --yes
    else
      dev-update-precommit
    fi
  '
}

@test "dev recovery: safe partial autoupdate survives one incompatible hook repository" {
  write_hook_project
  export AUTOUPDATE_STATUS=1
  run run_hook_update
  [ "$status" -eq 1 ]
  grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$DEV_PROJECT/.pre-commit-config.yaml"
  grep -q 'cccccccccccccccccccccccccccccccccccccccc' "$DEV_PROJECT/.pre-commit-config.yaml"
  grep -q '^hooks:install-hooks ' "$UPDATE_LOG"
  grep -q '^hooks:run --all-files ' "$UPDATE_LOG"
  [[ "$output" == *"autoupdate was incomplete"* ]]
  [[ "$output" == *"dev-menu dev-update-precommit"* ]]
}

@test "dev recovery: partial autoupdate still refuses unsafe changes and failed environments" {
  write_hook_project
  local original
  original=$(cat "$DEV_PROJECT/.pre-commit-config.yaml")
  export AUTOUPDATE_STATUS=1 UNSAFE_PLAN=1
  run run_hook_update
  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/.pre-commit-config.yaml")" = "$original" ]
  if grep -q '^hooks:install ' "$UPDATE_LOG"; then return 1; fi

  export UNSAFE_PLAN=0 INSTALL_STATUS=42
  run run_hook_update
  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/.pre-commit-config.yaml")" = "$original" ]
  [[ "$output" == *"candidate was not published"* ]]
}

@test "dev recovery: PyPI failure leaves hook backends usable with bounded Git HTTP stalls" {
  write_hook_project
  export PYPI_STATUS=1 DEV_PYPI_TIMEOUT=7
  run run_hook_update
  [ "$status" -eq 1 ]
  grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$DEV_PROJECT/.pre-commit-config.yaml"
  grep -q '^uv:sync --all-groups' "$UPDATE_LOG"
  grep -q '^network:1:7$' "$UPDATE_LOG"
  if grep -q '^query$' "$UPDATE_LOG"; then return 1; fi
  [[ "$output" == *"continuing with the lockfile"* ]]
}

@test "dev recovery: aggregate shares one PyPI probe with its child updates" {
  write_hook_project
  export AGGREGATE_UPDATE=1
  run run_hook_update
  [ "$status" -eq 0 ]
  [ "$(grep -c '^probe$' "$UPDATE_LOG")" -eq 1 ]
  grep -q '^hooks:autoupdate ' "$UPDATE_LOG"
}

@test "dev recovery: an interrupted hook update never publishes a partial candidate" {
  write_hook_project
  export AUTOUPDATE_STATUS=130
  run run_hook_update
  [ "$status" -eq 130 ]
  grep -q 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$DEV_PROJECT/.pre-commit-config.yaml"
  if grep -q '^hooks:install-hooks ' "$UPDATE_LOG"; then return 1; fi
}

@test "dev recovery: Git HTTP stall controls do not leak into the caller" {
  write_hook_project
  run run_zsh '
    cd "$DEV_PROJECT"
    export GIT_HTTP_LOW_SPEED_LIMIT=17 GIT_HTTP_LOW_SPEED_TIME=23
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pypi_latest() { print -r -- "1.0.0"; }
    _dev_exact_project_python_tool_runner() {
      reply=("$TEST_MOCK_BIN/pre-commit")
    }
    dev-update-precommit || return $?
    [[ "$GIT_HTTP_LOW_SPEED_LIMIT:$GIT_HTTP_LOW_SPEED_TIME" == 17:23 ]]
  '
  [ "$status" -eq 0 ]
}

@test "dev recovery: dry-run skips Python preview in a non-Python project" {
  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-deps-dry() { print -u2 -- UNEXPECTED_PYTHON; return 1; }
    dev-menu dev-update-all --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNEXPECTED_PYTHON"* ]]
  [[ "$output" == *"skipped (no pyproject.toml)"* ]]
  [[ "$output" == *"Cleanup preview"*"completed"* ]]
}

@test "dev recovery: failed cleanup previews keep dry-run in their retry command" {
  run run_zsh '
    cd "$DEV_PROJECT"
    dev-clean-all() { return 42; }
    dev-menu dev-update-all --dry-run
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"dev-menu dev-clean-all --dry-run"* ]]
}

@test "dev recovery: aggregate continues independent backends and lists exact retries" {
  write_hook_project
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { print -u2 -- PROBE; return 1; }
    dev-update-toolchain() { return 42; }
    dev-update-deps() { print -u2 -- UNEXPECTED_QUERY; return 97; }
    dev-update-lock() { print -u2 -- LOCK_COMPLETED; }
    dev-update-precommit() { print -u2 -- HOOKS_COMPLETED; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { return 0; }
    _timed dev:dev-update-all dev-update-all --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"LOCK_COMPLETED"* ]]
  [[ "$output" == *"HOOKS_COMPLETED"* ]]
  [[ "$output" != *"UNEXPECTED_QUERY"* ]]
  [[ "$output" == *"dev-menu dev-update-toolchain"* ]]
  [[ "$output" == *"dev-menu dev-update-deps"* ]]
  [[ "$output" == *"completed with partial failures"* ]]
}
