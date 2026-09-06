#!/usr/bin/env bats

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 -p "$TMPDIR"
  mkdir -p "$DEV_PROJECT"
}

teardown() {
  cleanup_sandbox
}

write_uv_mock() {
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  lock|sync) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
}

write_dependency_project() {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
dependencies = ["demo>=1.0.0"]
EOF
}

write_precommit_project() {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
dependencies = ["pre-commit>=1.0.0"]
EOF

  cat > "$DEV_PROJECT/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/hooks
    rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1.0.0
    hooks:
      - id: demo
EOF
}

write_python_venv_project() {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
requires-python = ">=3.11"
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"

  mkdir -p "$DEV_PROJECT/.venv/bin"
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" ]]; then
  printf 'CPython\n'
  exit 0
fi
printf 'Python 3.11.9\n'
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  printf 'original\n' > "$DEV_PROJECT/.venv/original-marker"
}

write_python_update_uv_mock() {
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_UPDATE_LOG"

case "$*" in
  "python install --upgrade 3.11")
    exit "${UV_PYTHON_INSTALL_STATUS:-0}"
    ;;
  venv\ --clear\ --managed-python\ --python\ 3.11\ *)
    target="${@: -1}"
    mkdir -p "$target/bin"
    cat > "$target/bin/python" <<'PYTHON'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" ]]; then
  printf 'CPython\n'
else
  printf 'Python 3.11.10\n'
fi
PYTHON
    chmod +x "$target/bin/python"
    ;;
  "sync --all-groups --locked")
    if [[ "${UV_SYNC_STATUS:-0}" != "0" ]]; then
      exit "$UV_SYNC_STATUS"
    fi
    [[ -n "${UV_PROJECT_ENVIRONMENT:-}" ]] || exit 98
    printf 'synchronized\n' > "$UV_PROJECT_ENVIRONMENT/sync-marker"
    if [[ "${UV_MUTATE_LOCK_DURING_SYNC:-0}" == "1" ]]; then
      printf 'changed during sync\n' > uv.lock
    fi
    ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
}

@test "dev update safety: repository hook revisions are frozen objects" {
  local config="$TEST_SUITE_ROOT/.pre-commit-config.yaml"
  [ "$(grep -Ec '^[[:space:]]+rev:' "$config")" -eq 7 ]
  [ "$(grep -Ec \
    '^[[:space:]]+rev: [0-9a-f]{40} # frozen: [^[:space:]#]+$' \
    "$config")" -eq 7 ]
}

@test "dev update safety: a mutable baseline cannot be frozen at a downgrade" {
  cat > "$DEV_PROJECT/pre-commit.original.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/hooks
    rev: v2.0.0
    hooks:
      - id: demo
EOF
  cat > "$DEV_PROJECT/pre-commit.candidate.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/hooks
    rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1.0.0
    hooks:
      - id: demo
EOF

  local before
  before=$(cat "$DEV_PROJECT/pre-commit.candidate.yaml")

  run run_zsh '
    _dev_precommit_sanitize_plan \
      "$DEV_PROJECT/pre-commit.original.yaml" \
      "$DEV_PROJECT/pre-commit.candidate.yaml"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/pre-commit.candidate.yaml")" = "$before" ]
}

@test "dev update safety: a non-version hook ref freezes only at matching provenance" {
  cat > "$DEV_PROJECT/pre-commit.original.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/hooks
    rev: stable
    hooks:
      - id: demo
EOF
  cat > "$DEV_PROJECT/pre-commit.candidate.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/hooks
    rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: stable
    hooks:
      - id: demo
EOF

  run run_zsh '
    _dev_precommit_sanitize_plan \
      "$DEV_PROJECT/pre-commit.original.yaml" \
      "$DEV_PROJECT/pre-commit.candidate.yaml"
  '

  [ "$status" -eq 0 ]
  grep -q \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: stable' \
    "$DEV_PROJECT/pre-commit.candidate.yaml"

  sed -i 's/# frozen: stable/# frozen: main/' \
    "$DEV_PROJECT/pre-commit.candidate.yaml"
  local mismatched_before=""
  mismatched_before=$(cat "$DEV_PROJECT/pre-commit.candidate.yaml")

  run run_zsh '
    _dev_precommit_sanitize_plan \
      "$DEV_PROJECT/pre-commit.original.yaml" \
      "$DEV_PROJECT/pre-commit.candidate.yaml"
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/pre-commit.candidate.yaml")" = \
    "$mismatched_before" ]
}

@test "dev update safety: full maintenance decline starts no mutation" {
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_confirm() {
      print -u2 -r -- "CONFIRM_CALLED"
      return 1
    }
    dev-update-toolchain() { print -r -- "MUTATION:toolchain"; }
    dev-update-deps() { print -r -- "MUTATION:deps"; }
    dev-update-precommit() { print -r -- "MUTATION:precommit"; }
    dev-update-terraform() { print -r -- "MUTATION:terraform"; }
    dev-update-tflint() { print -r -- "MUTATION:tflint"; }
    dev-clean-all() { print -r -- "MUTATION:clean"; }

    dev-update-all
  '

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^CONFIRM_CALLED$')" -eq 1 ]
  [[ "$output" == *"Cancelled. No maintenance step was started."* ]]
  [[ "$output" != *"MUTATION:"* ]]
}

@test "dev update safety: aggregate authorization preserves the exact cleanup prompt" {
  write_precommit_project
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_confirm() {
      print -u2 -r -- "CONFIRM_CALLED"
      return 0
    }
    dev-update-toolchain() { print -r -- "STEP:toolchain:$*"; }
    dev-update-deps() { print -r -- "STEP:deps:$*"; }
    dev-update-lock() { print -r -- "STEP:lock:$*"; }
    dev-update-precommit() { print -r -- "STEP:precommit:$*"; }
    dev-update-terraform() { print -r -- "STEP:terraform:$*"; }
    dev-update-tflint() { print -r -- "STEP:tflint:$*"; }
    dev-clean-all() { print -r -- "STEP:clean:$*"; }

    dev-update-all
  '

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^CONFIRM_CALLED$')" -eq 1 ]
  [[ "$output" == *"STEP:toolchain:"* ]]
  [[ "$output" == *"STEP:deps:--yes"* ]]
  [[ "$output" == *"STEP:lock:"* ]]
  [[ "$output" == *"STEP:precommit:"* ]]
  [[ "$output" == *"STEP:clean:"* ]]
  [[ "$output" != *"STEP:clean:--yes"* ]]
  [[ "$output" == *"Maintenance Summary"* ]]
  [[ "$output" == *"Full maintenance completed"* ]]
}

@test "dev update safety: full maintenance --yes authorizes child prompts" {
  write_precommit_project

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-toolchain() { print -r -- "STEP:toolchain"; }
    dev-update-deps() { print -r -- "STEP:deps:$*"; }
    dev-update-precommit() { print -r -- "STEP:precommit"; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { print -r -- "STEP:clean:$*"; }

    dev-update-all --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Maintenance plan:"* ]]
  [[ "$output" == *"STEP:toolchain"* ]]
  [[ "$output" == *"STEP:deps:--yes"* ]]
  [[ "$output" == *"STEP:clean:--yes"* ]]
  [[ "$output" != *"needs confirmation"* ]]
}

@test "dev update safety: full maintenance executes its advertised infrastructure set" {
  write_precommit_project
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    local -i terraform_probes=0 tflint_probes=0
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "terraform" ]]; then
        (( terraform_probes += 1 ))
        (( terraform_probes == 1 ))
        return $?
      fi
      if [[ "${1:-}" == "-v" && "${2:-}" == "tflint" ]]; then
        (( tflint_probes += 1 ))
        (( tflint_probes != 1 ))
        return $?
      fi
      builtin command "$@"
    }
    dev-update-toolchain() { print -r -- "STEP:toolchain"; }
    dev-update-deps() { print -r -- "STEP:deps"; }
    dev-update-lock() { print -r -- "STEP:lock"; }
    dev-update-precommit() { print -r -- "STEP:precommit"; }
    dev-update-terraform() { print -r -- "STEP:terraform"; }
    dev-update-tflint() { print -r -- "STEP:tflint"; }
    dev-clean-all() { print -r -- "STEP:clean"; }

    dev-update-all --yes
    local -i maintenance_status=$?
    print -u2 -r -- \
      "PROBES:terraform=${terraform_probes}:tflint=${tflint_probes}"
    return $maintenance_status
  '

  [ "$status" -eq 0 ]
  [[ "$output" == \
    *"2. Plan, back up, and update eligible dependency specifiers."* ]]
  [[ "$output" == \
    *"3. Refresh uv.lock to the newest compatible versions and sync."* ]]
  [[ "$output" == \
    *"4. Update and validate the configured pre-commit hooks."* ]]
  [[ "$output" == \
    *"5. Inspect Terraform ownership and its update workflow."* ]]
  [[ "$output" != *"Report the owning TFLint update workflow."* ]]
  [[ "$output" == *"STEP:terraform"* ]]
  [[ "$output" != *"STEP:tflint"* ]]
  [[ "$output" == *"PROBES:terraform=1:tflint=1"* ]]

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    local -i terraform_probes=0 tflint_probes=0
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "terraform" ]]; then
        (( terraform_probes += 1 ))
        (( terraform_probes != 1 ))
        return $?
      fi
      if [[ "${1:-}" == "-v" && "${2:-}" == "tflint" ]]; then
        (( tflint_probes += 1 ))
        (( tflint_probes == 1 ))
        return $?
      fi
      builtin command "$@"
    }
    dev-update-toolchain() { print -r -- "STEP:toolchain"; }
    dev-update-deps() { print -r -- "STEP:deps"; }
    dev-update-lock() { print -r -- "STEP:lock"; }
    dev-update-precommit() { print -r -- "STEP:precommit"; }
    dev-update-terraform() { print -r -- "STEP:terraform"; }
    dev-update-tflint() { print -r -- "STEP:tflint"; }
    dev-clean-all() { print -r -- "STEP:clean"; }

    dev-update-all --yes
    local -i maintenance_status=$?
    print -u2 -r -- \
      "PROBES:terraform=${terraform_probes}:tflint=${tflint_probes}"
    return $maintenance_status
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"Inspect Terraform ownership"* ]]
  [[ "$output" == *"5. Report the owning TFLint update workflow."* ]]
  [[ "$output" != *"6. Report the owning TFLint update workflow."* ]]
  [[ "$output" != *"STEP:terraform"* ]]
  [[ "$output" == *"STEP:tflint"* ]]
  [[ "$output" == *"PROBES:terraform=1:tflint=1"* ]]
}

@test "dev update safety: full maintenance freezes project-file applicability" {
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-toolchain() { print -r -- "STEP:toolchain"; }
    dev-update-deps() { print -r -- "MUTATION:deps"; }
    dev-update-lock() { print -r -- "MUTATION:lock"; }
    dev-update-precommit() { print -r -- "MUTATION:precommit"; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { print -r -- "STEP:clean"; }

    dev-update-all --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"STEP:toolchain"* ]]
  [[ "$output" == *"STEP:clean"* ]]
  [[ "$output" != *"MUTATION:"* ]]
  [[ "$output" == \
    *"Not applicable: dependency and pre-commit updates need pyproject.toml."* ]]
  [[ "$output" == *"Not applicable: the lockfile refresh needs uv.lock."* ]]
  [[ "$output" == *"Maintenance Summary"* ]]
  [[ "$output" == *"skipped (no pyproject.toml)"* ]]
  [[ "$output" == *"skipped (no uv.lock)"* ]]
  [[ "$output" == *"Full maintenance completed"* ]]

  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-toolchain() { return 0; }
    dev-update-deps() { print -r -- "STEP:deps"; }
    dev-update-lock() { print -r -- "MUTATION:lock"; }
    dev-update-precommit() { print -r -- "MUTATION:precommit"; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { return 0; }

    dev-update-all --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"STEP:deps"* ]]
  [[ "$output" != *"MUTATION:"* ]]
  [[ "$output" == \
    *"Not applicable: the pre-commit update needs .pre-commit-config.yaml."* ]]
  [[ "$output" == *"skipped (no .pre-commit-config.yaml)"* ]]
}

@test "dev update safety: full maintenance keeps pre-commit after a non-publishing dependency failure" {
  write_precommit_project

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-toolchain() { return 0; }
    dev-update-deps() {
      _DEV_UPDATE_DEPS_OUTCOME="unchanged"
      print -r -- "STEP:deps"
      return 1
    }
    dev-update-precommit() { print -r -- "STEP:precommit"; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { print -r -- "STEP:clean"; }

    dev-update-all --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"STEP:deps"* ]]
  [[ "$output" == *"STEP:precommit"* ]]
  [[ "$output" == *"STEP:clean"* ]]
  [[ "$output" != *"lockfile may be stale"* ]]
  [[ "$output" == *"Dependency specifiers"*"failed (status 1)"* ]]
  [[ "$output" == *"Pre-commit hooks"*"completed"* ]]
  [[ "$output" == *"1 step(s) had issues"* ]]
}

@test "dev update safety: full maintenance skips pre-commit only for an inconsistent lockfile" {
  write_precommit_project

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-toolchain() { return 0; }
    dev-update-deps() {
      _DEV_UPDATE_DEPS_OUTCOME="inconsistent"
      return 1
    }
    dev-update-lock() { print -r -- "MUTATION:lock"; }
    dev-update-precommit() { print -r -- "MUTATION:precommit"; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { return 0; }

    dev-update-all --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" != *"MUTATION:"* ]]
  [[ "$output" == *"dependency publication left the lockfile stale"* ]]
  [[ "$output" == *"skipped (lockfile may be stale)"* ]]

  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-toolchain() { return 0; }
    dev-update-deps() {
      _DEV_UPDATE_DEPS_OUTCOME="inconsistent"
      return 1
    }
    dev-update-lock() { print -r -- "STEP:lock"; }
    dev-update-precommit() { print -r -- "STEP:precommit"; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { return 0; }

    dev-update-all --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"STEP:lock"* ]]
  [[ "$output" == *"STEP:precommit"* ]]
  [[ "$output" != *"lockfile may be stale"* ]]
}

@test "dev update safety: full maintenance dry-run invokes previews only" {
  write_dependency_project
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_confirm() { print -u2 -r -- "PROMPTED"; return 0; }
    dev-update-deps-dry() { print -r -- "PREVIEW:deps"; }
    dev-clean-all() { print -r -- "PREVIEW:clean:$*"; }
    dev-update-toolchain() { print -r -- "MUTATION:toolchain"; }
    dev-update-deps() { print -r -- "MUTATION:deps"; }
    dev-update-precommit() { print -r -- "MUTATION:precommit"; }
    dev-update-terraform() { print -r -- "MUTATION:terraform"; }
    dev-update-tflint() { print -r -- "MUTATION:tflint"; }

    dev-update-all --dry-run
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"PREVIEW:deps"* ]]
  [[ "$output" == *"PREVIEW:clean:--dry-run"* ]]
  [[ "$output" != *"MUTATION:"* ]]
  [[ "$output" != *"PROMPTED"* ]]
}

@test "dev update safety: full maintenance blocks only specifier queries when PyPI is unreachable" {
  write_precommit_project
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() {
      _dev_error "Cannot reach PyPI (HTTP 000). Check network, DNS, or proxy."
      return 1
    }
    _dev_confirm() { print -u2 -r -- "CONFIRM_CALLED"; return 0; }
    dev-update-toolchain() { print -r -- "STEP:toolchain"; }
    dev-update-deps() { print -r -- "MUTATION:deps"; }
    dev-update-lock() { print -r -- "STEP:lock"; }
    dev-update-precommit() { print -r -- "STEP:precommit"; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { print -r -- "STEP:clean"; }

    dev-update-all
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot reach PyPI"* ]]
  [[ "$output" == *"specifier queries are blocked"* ]]
  [[ "$output" != *"2. Plan, back up"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^CONFIRM_CALLED$')" -eq 1 ]
  [[ "$output" == *"STEP:toolchain"* ]]
  [[ "$output" == *"STEP:clean"* ]]
  [[ "$output" == *"STEP:lock"* ]]
  [[ "$output" == *"STEP:precommit"* ]]
  [[ "$output" != *"MUTATION:"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'blocked (PyPI unreachable)')" -eq 1 ]
  [[ "$output" == *"1 step(s) had issues"* ]]
}

@test "dev update safety: unavailable PyPI does not replace the exact project runner requirement" {
  write_precommit_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_UPDATE_LOG"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() {
      _dev_error "Cannot reach PyPI (HTTP 000). Check network, DNS, or proxy."
      return 1
    }
    dev-update-precommit
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot reach PyPI"* ]]
  [[ "$output" == *"project pre-commit runner is unavailable"* ]]
  grep -Fxq 'sync --all-groups' "$UV_UPDATE_LOG"
}

@test "dev update safety: dependency decline leaves live pyproject untouched" {
  write_dependency_project
  write_uv_mock

  local before
  before=$(cat "$DEV_PROJECT/pyproject.toml")

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() { reply=(demo); }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }
    dev-backup-pyproject() {
      print -u2 -r -- "BACKUP_SHOULD_NOT_RUN"
      return 1
    }
    _dev_confirm() { return 1; }

    dev-update-deps
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$DEV_PROJECT/pyproject.toml")" = "$before" ]
  [[ "$output" == *"pyproject.toml was never modified"* ]]
  [[ "$output" != *"BACKUP_SHOULD_NOT_RUN"* ]]
}

@test "dev update safety: dependency success publishes only after backup" {
  write_dependency_project
  write_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() { reply=(demo); }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }
    dev-backup-pyproject() {
      local backup="$DEV_PROJECT/invocation.backup"
      command cp -- pyproject.toml "$backup" || return 1
      command chmod 600 -- "$backup" || return 1
      _DEV_LAST_BACKUP_FILE="$backup"
      print -u2 -r -- "BACKUP_READY"
    }
    _dev_restore_pyproject() {
      command cp -- "$1" pyproject.toml
    }

    dev-update-deps --yes
    local -i update_status=$?
    print -u2 -r -- "DEPS_OUTCOME:$_DEV_UPDATE_DEPS_OUTCOME"
    return $update_status
  '

  [ "$status" -eq 0 ]
  grep -q 'demo>=2.0.0' "$DEV_PROJECT/pyproject.toml"
  [[ "$output" == *"BACKUP_READY"* ]]
  [[ "$output" == *"Applied 1 dependency update(s)"* ]]
  [[ "$output" == *"DEPS_OUTCOME:applied"* ]]
}

@test "dev update safety: a mismatched invocation backup blocks publication" {
  write_dependency_project

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
echo "UV_MUTATION_SHOULD_NOT_RUN:$*" >&2
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  local before
  before=$(cat "$DEV_PROJECT/pyproject.toml")

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() { reply=(demo); }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }
    dev-backup-pyproject() {
      local backup="$DEV_PROJECT/invocation.backup"
      print -r -- "not the inspected project" > "$backup" || return 1
      command chmod 600 -- "$backup" || return 1
      _DEV_LAST_BACKUP_FILE="$backup"
    }

    dev-update-deps --yes
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/pyproject.toml")" = "$before" ]
  [[ "$output" == *"backup does not match"* ]]
  [[ "$output" != *"UV_MUTATION_SHOULD_NOT_RUN"* ]]
}

@test "dev update safety: real backup API integrates with exact rollback" {
  write_dependency_project
  chmod 640 "$DEV_PROJECT/pyproject.toml"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "lock" ]] && exit 42
[[ "${1:-}" == "sync" ]] && exit 97
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  local before
  before=$(cat "$DEV_PROJECT/pyproject.toml")

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() { reply=(demo); }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }

    dev-update-deps --yes
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/pyproject.toml")" = "$before" ]
  [ "$(python3 -c \
    'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' \
    "$DEV_PROJECT/pyproject.toml")" = "640" ]
  [ -d "$DEV_PROJECT/.dev-suite-backups" ]
  [ "$(find "$DEV_PROJECT/.dev-suite-backups" -type f | wc -l)" -eq 1 ]
  [[ "$output" == *"restored from the exact invocation backup"* ]]
}

@test "dev update safety: lock failure restores the exact invocation backup" {
  write_dependency_project

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "lock" ]]; then
  grep -q 'demo>=2.0.0' pyproject.toml \
    && echo "LOCK_SAW_APPLIED_PLAN" >&2
  exit 42
fi
if [[ "${1:-}" == "sync" ]]; then
  echo "SYNC_SHOULD_NOT_RUN" >&2
  exit 97
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  local before
  before=$(cat "$DEV_PROJECT/pyproject.toml")

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() { reply=(demo); }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }
    dev-backup-pyproject() {
      local backup="$DEV_PROJECT/invocation.backup"
      command cp -- pyproject.toml "$backup" || return 1
      command chmod 600 -- "$backup" || return 1
      _DEV_LAST_BACKUP_FILE="$backup"
    }
    _dev_restore_pyproject() {
      [[ "$1" == "$DEV_PROJECT/invocation.backup" ]] || return 1
      print -u2 -r -- "RESTORING_EXACT:$1"
      command cp -- "$1" pyproject.toml
    }

    dev-update-deps --yes
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/pyproject.toml")" = "$before" ]
  [[ "$output" == *"LOCK_SAW_APPLIED_PLAN"* ]]
  [[ "$output" == *"RESTORING_EXACT:$DEV_PROJECT/invocation.backup"* ]]
  [[ "$output" == *"restored from the exact invocation backup"* ]]
  [[ "$output" != *"SYNC_SHOULD_NOT_RUN"* ]]
}

@test "dev update safety: rollback failure is visible and never reports success" {
  write_dependency_project

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "lock" ]] && exit 42
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() { reply=(demo); }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }
    dev-backup-pyproject() {
      local backup="$DEV_PROJECT/invocation.backup"
      command cp -- pyproject.toml "$backup" || return 1
      _DEV_LAST_BACKUP_FILE="$backup"
    }
    _dev_restore_pyproject() {
      print -u2 -r -- "ROLLBACK_FAILED"
      return 1
    }

    dev-update-deps --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"ROLLBACK_FAILED"* ]]
  [[ "$output" == *"rollback also failed"* ]]
  [[ "$output" != *"synchronized the environment"* ]]
}

@test "dev update safety: changed backup fingerprint refuses dependency rollback" {
  write_dependency_project

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "lock" ]]; then
  printf 'tampered recovery data\n' > "$DEV_PROJECT/invocation.backup"
  exit 42
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() { reply=(demo); }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }
    dev-backup-pyproject() {
      local backup="$DEV_PROJECT/invocation.backup"
      command cp -- pyproject.toml "$backup" || return 1
      command chmod 600 -- "$backup" || return 1
      _DEV_LAST_BACKUP_FILE="$backup"
    }

    dev-update-deps --yes
  '

  [ "$status" -eq 1 ]
  grep -q 'demo>=2.0.0' "$DEV_PROJECT/pyproject.toml"
  [[ "$output" == *"backup changed after creation"* ]]
  [[ "$output" == *"rollback also failed"* ]]
}

@test "dev update safety: dependency filters are mutually exclusive" {
  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-deps --major-only --patch-only
  '

  [ "$status" -eq 2 ]
  [[ "$output" == *"Choose only one"* ]]
}

@test "dev update safety: summary stays off stdout with hostile typeset options" {
  run run_zsh '
    unsetopt typesetsilent
    local captured
    captured=$(_dev_print_summary_table \
      "latest|one|1.0.0|1.0.0|" \
      "latest|two|2.0.0|2.0.0|" \
      "latest|three|3.0.0|3.0.0|")
    local -i summary_status=$?
    print -u2 -r -- "CAPTURED_STDOUT=<$captured>"
    return $summary_status
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"one"* ]]
  [[ "$output" == *"two"* ]]
  [[ "$output" == *"three"* ]]
  [[ "$output" == *"CAPTURED_STDOUT=<>"* ]]
  [[ "$output" != *"label="* ]]
}

@test "dev update safety: Homebrew-owned TFLint delegates without mutation" {
  export BREW_PREFIX="$TEST_TEMP_DIR/homebrew"
  export BREW_CALL_LOG="$TEST_TEMP_DIR/brew-calls.log"
  mkdir -p "$BREW_PREFIX/Cellar/tflint/0.61.0/bin"
  cat > "$BREW_PREFIX/Cellar/tflint/0.61.0/bin/tflint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BREW_PREFIX/Cellar/tflint/0.61.0/bin/tflint"
  ln -s "$BREW_PREFIX/Cellar/tflint/0.61.0/bin/tflint" \
    "$TEST_MOCK_BIN/tflint"

  cat > "$TEST_MOCK_BIN/brew" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BREW_CALL_LOG"
if [[ "${1:-}" == "--prefix" ]]; then
  printf '%s\n' "$BREW_PREFIX"
  exit 0
fi
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/brew"

  run run_zsh 'dev-update-tflint'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Managed by Homebrew"* ]]
  [[ "$output" == *"sys-menu update-brew"* ]]
  [ "$(cat "$BREW_CALL_LOG")" = "--prefix" ]
}

@test "dev update safety: a different active TFLint is not attributed to brew" {
  export BREW_PREFIX="$TEST_TEMP_DIR/homebrew"
  export BREW_CALL_LOG="$TEST_TEMP_DIR/brew-calls.log"
  mkdir -p "$BREW_PREFIX/Cellar/tflint/0.61.0/bin"

  cat > "$TEST_MOCK_BIN/tflint" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$TEST_MOCK_BIN/brew" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BREW_CALL_LOG"
if [[ "${1:-}" == "--prefix" ]]; then
  printf '%s\n' "$BREW_PREFIX"
  exit 0
fi
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/tflint" "$TEST_MOCK_BIN/brew"

  run run_zsh 'dev-update-tflint'

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not prove that the active TFLint binary"* ]]
  [[ "$output" != *"Managed by Homebrew"* ]]
  [ "$(cat "$BREW_CALL_LOG")" = "--prefix" ]
}

@test "dev update safety: tfenv ownership inspection never installs or selects a version" {
  export TFENV_CALL_LOG="$TEST_TEMP_DIR/tfenv-calls.log"

  cat > "$TEST_MOCK_BIN/terraform" <<'EOF'
#!/usr/bin/env zsh
exit 0
EOF
  cat > "$TEST_MOCK_BIN/tfenv" <<'EOF'
#!/usr/bin/env zsh
printf '%s\n' "$*" >> "$TFENV_CALL_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/terraform" "$TEST_MOCK_BIN/tfenv"

  run run_zsh 'dev-update-terraform'

  [ "$status" -eq 0 ]
  [ ! -e "$TFENV_CALL_LOG" ]
  [[ "$output" == *"Managed by tfenv"* ]]
  [[ "$output" == \
    *"Developer suite does not install or select Terraform versions"* ]]
  [[ "$output" != *"tfenv install"* ]]
  [[ "$output" != *"tfenv use"* ]]
  [[ "$output" != *"Terraform updated"* ]]
}

@test "dev update safety: TFENV_ROOT cannot claim a mismatched active binary" {
  export TFENV_ROOT="$TEST_MOCK_BIN"
  local tfenv_bin="$TEST_TEMP_DIR/tfenv-bin"
  mkdir -p "$tfenv_bin"

  cat > "$TEST_MOCK_BIN/terraform" <<'EOF'
#!/usr/bin/env zsh
exit 0
EOF
  cat > "$tfenv_bin/tfenv" <<'EOF'
#!/usr/bin/env zsh
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/terraform" "$tfenv_bin/tfenv"

  run run_zsh "PATH='$tfenv_bin':\$PATH dev-update-terraform"

  [ "$status" -eq 0 ]
  [[ "$output" == *"appears to be installed manually"* ]]
  [[ "$output" != *"Managed by tfenv"* ]]
}

@test "dev update safety: Terraform ownership inspection enforces exact arity" {
  run run_zsh 'dev-update-terraform --help unexpected'

  [ "$status" -eq 2 ]
  [[ "$output" == *"dev-update-terraform accepts no arguments"* ]]

  run run_zsh 'dev-update-terraform ""'

  [ "$status" -eq 2 ]
  [[ "$output" == *"dev-update-terraform accepts no arguments"* ]]
}

@test "dev update safety: an installed APT package does not claim another Terraform" {
  export DPKG_QUERY_LOG="$TEST_TEMP_DIR/dpkg-query.log"
  cat > "$TEST_MOCK_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$TEST_MOCK_BIN/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DPKG_QUERY_LOG"
case "${1:-}" in
  -W) printf '%s\n' 'install ok installed' ;;
  -S) printf '%s: %s\n' "${DPKG_OWNER:-local-tools}" "${2:-}" ;;
  *) exit 97 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/terraform" "$TEST_MOCK_BIN/dpkg-query"

  run run_zsh 'dev-update-terraform'

  [ "$status" -eq 0 ]
  [[ "$output" == *"appears to be installed manually"* ]]
  [[ "$output" != *"Managed by APT"* ]]
  grep -q '^-W -f=.* terraform$' "$DPKG_QUERY_LOG"
  grep -q "^-S $TEST_MOCK_BIN/terraform$" "$DPKG_QUERY_LOG"

  export DPKG_OWNER=terraform
  run run_zsh 'dev-update-terraform'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Managed by APT"* ]]
}

@test "dev update safety: a symlinked TMPDIR is refused" {
  write_dependency_project
  write_uv_mock
  mkdir -p "$HOME/real-tmp"
  ln -s "$HOME/real-tmp" "$HOME/linked-tmp"

  run run_zsh '
    cd "$DEV_PROJECT"
    export TMPDIR="$HOME/linked-tmp"
    _dev_pypi_check_connectivity() { return 0; }

    dev-update-deps --dry-run
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"TMPDIR must name a writable, non-symlinked directory"* ]]
  [ -z "$(find "$HOME/real-tmp" -mindepth 1 -print -quit)" ]
}

@test "dev update safety: root-owned sticky TMPDIR is accepted" {
  run run_zsh '
    zstat() {
      metadata=(device 7 inode 11 mode 1023 uid 0)
    }

    _dev_update_temp_root_identity "$TMPDIR"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "7:11:1023:0" ]
}

@test "dev update safety: foreign-owned sticky TMPDIR is refused" {
  run run_zsh '
    zstat() {
      metadata=(
        device 7
        inode 11
        mode 1023
        uid $(( EUID + 1 ))
      )
    }

    _dev_update_temp_root_identity "$TMPDIR"
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"current user, or root-owned with the sticky bit"* ]]
}

@test "dev update safety: a replaced workspace is preserved and refused" {
  write_dependency_project
  write_uv_mock
  mkdir -m 700 "$HOME/update-tmp"

  run run_zsh '
    cd "$DEV_PROJECT"
    export TMPDIR="$HOME/update-tmp"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() {
      local -a active=("$TMPDIR"/zdx-dev-update.*(N))
      (( ${#active[@]} == 1 )) || return 1
      command mv -- "${active[1]}" "${active[1]}.original" || return 1
      command mkdir -m 700 -- "${active[1]}" || return 1
      print -r -- "replacement" > "${active[1]}/marker" || return 1
      reply=(demo)
    }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }

    dev-update-deps --dry-run
    local -i update_result=$?
    local -a markers=("$TMPDIR"/zdx-dev-update.*/marker(N))
    (( ${#markers[@]} == 1 )) \
      && print -u2 -r -- "REPLACEMENT_SURVIVED"
    return $update_result
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace changed during planning"* ]]
  [[ "$output" == *"refusing recursive removal"* ]]
  [[ "$output" == *"REPLACEMENT_SURVIVED"* ]]
}

@test "dev update safety: a replaced TMPDIR root is detected by identity" {
  write_dependency_project
  write_uv_mock
  mkdir -m 700 "$HOME/update-tmp"

  run run_zsh '
    cd "$DEV_PROJECT"
    export TMPDIR="$HOME/update-tmp"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() {
      command mv -- "$TMPDIR" "${TMPDIR}.original" || return 1
      command mkdir -m 700 -- "$TMPDIR" || return 1
      reply=(demo)
    }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }

    dev-update-deps --dry-run
    local -i update_result=$?
    local -a original_workspaces=(
      "${TMPDIR}.original"/zdx-dev-update.*(N)
    )
    (( ${#original_workspaces[@]} == 1 )) \
      && print -u2 -r -- "ORIGINAL_ROOT_RETAINED"
    return $update_result
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace changed during planning"* ]]
  [[ "$output" == *"TMPDIR changed"* ]]
  [[ "$output" == *"ORIGINAL_ROOT_RETAINED"* ]]
}

@test "dev update safety: workspace cleanup removes only a quarantined inode" {
  write_dependency_project
  write_uv_mock
  mkdir -m 700 "$HOME/update-tmp"
  export UPDATE_RM_LOG="$HOME/update-rm.log"

  run run_zsh '
    cd "$DEV_PROJECT"
    export TMPDIR="$HOME/update-tmp"
    export UPDATE_RM_LOG="$UPDATE_RM_LOG"
    command() {
      if [[ "${1:-}" == "rm" ]]; then
        print -r -- "$*" >> "$UPDATE_RM_LOG"
      fi
      builtin command "$@"
    }
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() { reply=(); }

    dev-update-deps --dry-run
  '

  [ "$status" -eq 0 ]
  grep -q -- "$HOME/update-tmp/.zdx-dev-update.cleanup." "$UPDATE_RM_LOG"
  [ -z "$(find "$HOME/update-tmp" -mindepth 1 -print -quit)" ]
}

@test "dev update safety: a finished plan changed after confirmation is refused" {
  write_dependency_project
  write_uv_mock

  local before
  before=$(cat "$DEV_PROJECT/pyproject.toml")

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pyproject_all_deps() { reply=(demo); }
    _dev_pypi_prefetch() { return 0; }
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_spinner_start() { return 0; }
    _dev_spinner_stop() { return 0; }
    _dev_confirm_outcome() {
      local -a plans=("${TMPDIR:-/tmp}"/zdx-dev-update.*/pyproject.toml(N))
      (( ${#plans[@]} == 1 )) || return 1
      print -r -- "# changed after review" >> "${plans[1]}" || return 1
      print -r -- "confirmed"
    }
    dev-backup-pyproject() {
      print -u2 -r -- "BACKUP_SHOULD_NOT_RUN"
      return 1
    }

    dev-update-deps
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/pyproject.toml")" = "$before" ]
  [[ "$output" == *"finished dependency update plan changed"* ]]
  [[ "$output" != *"BACKUP_SHOULD_NOT_RUN"* ]]
}

@test "dev update safety: pre-commit plans privately before backup and publish" {
  write_precommit_project
  # Pin the fixture mode the mocked backup records so the check is umask-independent.
  chmod 644 "$DEV_PROJECT/pyproject.toml"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
echo "UV_UI:$*"
if [[ "${1:-}" == "sync" ]]; then
  mkdir -p .venv/bin
  cat > .venv/bin/python <<'PYTHON'
#!/usr/bin/env bash
case "${4:-}" in
  pre_commit) exit 1 ;;
  *) exit 0 ;;
esac
PYTHON
  cat > .venv/bin/pre-commit <<'PRECOMMIT'
#!/usr/bin/env bash
echo "PRECOMMIT_UI:$*"
exit 0
PRECOMMIT
  chmod +x .venv/bin/python .venv/bin/pre-commit
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    dev-backup-pyproject() {
      command grep -q "pre-commit>=1.0.0" pyproject.toml || return 1
      print -u2 -r -- "BACKUP_SAW_ORIGINAL"
      local backup="$DEV_PROJECT/invocation.backup"
      command cp -- pyproject.toml "$backup" || return 1
      command chmod 600 -- "$backup" || return 1
      _DEV_LAST_BACKUP_FILE="$backup"
      _DEV_LAST_BACKUP_MODE="644"
    }
    _dev_restore_pyproject() {
      command cp -- "$1" pyproject.toml
    }

    _dev_pypi_check_connectivity() { return 0; }
    dev-update-precommit
  '

  [ "$status" -eq 0 ]
  grep -q 'pre-commit>=2.0.0' "$DEV_PROJECT/pyproject.toml"
  [[ "$output" == *"BACKUP_SAW_ORIGINAL"* ]]
  [[ "$output" == *"pre-commit specifier applied"* ]]
}

@test "dev update safety: frozen hook plan preserves downgrade and publishes upgrade" {
  write_precommit_project
  export PRECOMMIT_PHASE_LOG="$TEST_TEMP_DIR/precommit-phases.log"

  cat > "$DEV_PROJECT/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/guarded
    rev: 1111111111111111111111111111111111111111 # frozen: v8.30.1
    hooks:
      - id: guarded
  - repo: https://example.invalid/upgradable
    rev: 3333333333333333333333333333333333333333 # frozen: v1.0.0
    hooks:
      - id: upgradable
  - repo: https://example.invalid/retagged
    rev: 5555555555555555555555555555555555555555 # frozen: v2.0.0
    hooks:
      - id: retagged
EOF

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "sync" ]]; then
  mkdir -p .venv/bin
  cat > .venv/bin/python <<'PYTHON'
#!/usr/bin/env bash
case "${4:-}" in
  pre_commit) exit 1 ;;
  *) exit 0 ;;
esac
PYTHON
  cat > .venv/bin/pre-commit <<'PRECOMMIT'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$PRECOMMIT_PHASE_LOG"

case "${1:-}" in
  autoupdate)
    [[ "${2:-}" == "--freeze" && "${3:-}" == "--config" \
      && -n "${4:-}" && "$4" != "$PWD/.pre-commit-config.yaml" ]] \
      || exit 91
    grep -q '1111111111111111111111111111111111111111' \
      .pre-commit-config.yaml || exit 92
    cat > "$4" <<'CONFIG'
repos:
  - repo: https://example.invalid/guarded
    rev: 2222222222222222222222222222222222222222 # frozen: v8.30.0
    hooks:
      - id: guarded
  - repo: https://example.invalid/upgradable
    rev: 4444444444444444444444444444444444444444 # frozen: v1.1.0
    hooks:
      - id: upgradable
  - repo: https://example.invalid/retagged
    rev: 6666666666666666666666666666666666666666 # frozen: v2.0.0
    hooks:
      - id: retagged
CONFIG
    ;;
  validate-config)
    grep -q '1111111111111111111111111111111111111111' "$2" || exit 93
    grep -q '4444444444444444444444444444444444444444' "$2" || exit 94
    grep -q '5555555555555555555555555555555555555555' "$2" || exit 103
    grep -q '3333333333333333333333333333333333333333' \
      .pre-commit-config.yaml || exit 95
    ;;
  install-hooks)
    [[ "${2:-}" == "--config" && -n "${3:-}" ]] || exit 106
    grep -q '1111111111111111111111111111111111111111' "$3" || exit 107
    grep -q '4444444444444444444444444444444444444444' "$3" || exit 108
    grep -q '5555555555555555555555555555555555555555' "$3" || exit 109
    grep -q '3333333333333333333333333333333333333333' \
      .pre-commit-config.yaml || exit 110
    ;;
  run)
    [[ "${2:-}" == "--all-files" && "${3:-}" == "--config" \
      && "${4:-}" == "$PWD/.pre-commit-config.yaml" ]] || exit 96
    grep -q '1111111111111111111111111111111111111111' "$4" || exit 97
    grep -q '4444444444444444444444444444444444444444' "$4" || exit 98
    grep -q '5555555555555555555555555555555555555555' "$4" || exit 104
    if grep -q '3333333333333333333333333333333333333333' \
      .pre-commit-config.yaml; then
      exit 99
    fi
    ;;
  install)
    grep -q '1111111111111111111111111111111111111111' \
      .pre-commit-config.yaml || exit 100
    grep -q '4444444444444444444444444444444444444444' \
      .pre-commit-config.yaml || exit 101
    grep -q '5555555555555555555555555555555555555555' \
      .pre-commit-config.yaml || exit 105
    ;;
  *) exit 102 ;;
esac
PRECOMMIT
  chmod +x .venv/bin/python .venv/bin/pre-commit
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "1.0.0"; }
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-precommit
  '

  [ "$status" -eq 0 ]
  grep -q '1111111111111111111111111111111111111111' \
    "$DEV_PROJECT/.pre-commit-config.yaml"
  grep -q '4444444444444444444444444444444444444444' \
    "$DEV_PROJECT/.pre-commit-config.yaml"
  grep -q '5555555555555555555555555555555555555555' \
    "$DEV_PROJECT/.pre-commit-config.yaml"
  ! grep -q '2222222222222222222222222222222222222222' \
    "$DEV_PROJECT/.pre-commit-config.yaml"
  ! grep -q '6666666666666666666666666666666666666666' \
    "$DEV_PROJECT/.pre-commit-config.yaml"
  [[ "$output" == *"version downgrade"* ]]
  [[ "$output" == *"tag moved to a different object"* ]]
  [[ "$output" == *"Rejected autoupdate proposal: v8.30.0"* ]]
  grep -q '^autoupdate --freeze --config ' "$PRECOMMIT_PHASE_LOG"
  grep -q '^validate-config ' "$PRECOMMIT_PHASE_LOG"
  grep -q '^install-hooks --config ' "$PRECOMMIT_PHASE_LOG"
  grep -q '^install --install-hooks$' "$PRECOMMIT_PHASE_LOG"
  grep -q '^run --all-files --config ' "$PRECOMMIT_PHASE_LOG"
  local install_line run_line
  install_line=$(grep -n '^install --install-hooks$' "$PRECOMMIT_PHASE_LOG" \
    | cut -d: -f1)
  run_line=$(grep -n '^run --all-files --config ' "$PRECOMMIT_PHASE_LOG" \
    | cut -d: -f1)
  [ "$install_line" -lt "$run_line" ]
}

@test "dev update safety: hook findings are reported after publication and never discard it" {
  write_precommit_project
  export PRECOMMIT_PHASE_LOG="$TEST_TEMP_DIR/precommit-phases.log"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "sync" ]]; then
  mkdir -p .venv/bin
  cat > .venv/bin/python <<'PYTHON'
#!/usr/bin/env bash
case "${4:-}" in
  pre_commit) exit 1 ;;
  *) exit 0 ;;
esac
PYTHON
  cat > .venv/bin/pre-commit <<'PRECOMMIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PRECOMMIT_PHASE_LOG"
case "${1:-}" in
  autoupdate)
    cat > "$4" <<'CONFIG'
repos:
  - repo: https://example.invalid/hooks
    rev: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v1.1.0
    hooks:
      - id: demo
CONFIG
    ;;
  validate-config|install-hooks) exit 0 ;;
  install)
    grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
      .pre-commit-config.yaml || exit 100
    ;;
  run)
    [[ "${2:-}" == "--all-files" && "${3:-}" == "--config" \
      && "${4:-}" == "$PWD/.pre-commit-config.yaml" ]] || exit 96
    grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$4" || exit 97
    echo "HOOK_FINDINGS:trailing whitespace fixed" >&2
    exit 1
    ;;
  *) exit 102 ;;
esac
PRECOMMIT
  chmod +x .venv/bin/python .venv/bin/pre-commit
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "1.0.0"; }
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-precommit
  '

  [ "$status" -eq 1 ]
  grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    "$DEV_PROJECT/.pre-commit-config.yaml"
  [[ "$output" == *"Published the validated frozen hook revisions."* ]]
  [[ "$output" == *"HOOK_FINDINGS:trailing whitespace fixed"* ]]
  [[ "$output" == *"Some hooks reported issues (exit status: 1)."* ]]
  [[ "$output" == *"stay published"* ]]
  [[ "$output" == *"rerun: dev-run-hooks"* ]]
  [[ "$output" == \
    *"Pre-commit revisions were published, but the hook run reported issues."* ]]
  [[ "$output" != *"candidate was not published"* ]]
  [[ "$output" != *"private update workspace was retained"* ]]
  grep -q '^install --install-hooks$' "$PRECOMMIT_PHASE_LOG"
  grep -q '^run --all-files --config ' "$PRECOMMIT_PHASE_LOG"
}

@test "dev update safety: every hook environment installs before publication" {
  write_precommit_project
  chmod 640 "$DEV_PROJECT/.pre-commit-config.yaml"
  export PRECOMMIT_PHASE_LOG="$TEST_TEMP_DIR/precommit-phases.log"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "sync" ]]; then
  mkdir -p .venv/bin
  cat > .venv/bin/python <<'PYTHON'
#!/usr/bin/env bash
case "${4:-}" in
  pre_commit) exit 1 ;;
  *) exit 0 ;;
esac
PYTHON
  cat > .venv/bin/pre-commit <<'PRECOMMIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PRECOMMIT_PHASE_LOG"
case "${1:-}" in
  autoupdate)
    cat > "$4" <<'CONFIG'
repos:
  - repo: https://example.invalid/hooks
    rev: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v1.1.0
    hooks:
      - id: demo
CONFIG
    ;;
  validate-config) exit 0 ;;
  install-hooks)
    echo "PLANNED_ENVIRONMENT_FAILED" >&2
    exit 42
    ;;
  *)
    echo "DOWNSTREAM_SHOULD_NOT_RUN:$*" >&2
    exit 97
    ;;
esac
PRECOMMIT
  chmod +x .venv/bin/python .venv/bin/pre-commit
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  local before
  before=$(cat "$DEV_PROJECT/.pre-commit-config.yaml")

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "1.0.0"; }
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-precommit
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/.pre-commit-config.yaml")" = "$before" ]
  [ "$(python3 -c \
    'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' \
    "$DEV_PROJECT/.pre-commit-config.yaml")" = "640" ]
  [[ "$output" == *"PLANNED_ENVIRONMENT_FAILED"* ]]
  [[ "$output" == *"candidate was not published"* ]]
  grep -q '^install-hooks --config ' "$PRECOMMIT_PHASE_LOG"
  ! grep -q '^run ' "$PRECOMMIT_PHASE_LOG"
  ! grep -q '^install ' "$PRECOMMIT_PHASE_LOG"
  [[ "$output" != *"DOWNSTREAM_SHOULD_NOT_RUN"* ]]
}

@test "dev update safety: hook installation never overwrites a concurrent config edit" {
  write_precommit_project
  chmod 640 "$DEV_PROJECT/.pre-commit-config.yaml"
  export PRECOMMIT_PHASE_LOG="$TEST_TEMP_DIR/precommit-phases.log"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "sync" ]]; then
  mkdir -p .venv/bin
  cat > .venv/bin/python <<'PYTHON'
#!/usr/bin/env bash
case "${4:-}" in
  pre_commit) exit 1 ;;
  *) exit 0 ;;
esac
PYTHON
  cat > .venv/bin/pre-commit <<'PRECOMMIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PRECOMMIT_PHASE_LOG"
case "${1:-}" in
  autoupdate)
    cat > "$4" <<'CONFIG'
repos:
  - repo: https://example.invalid/hooks
    rev: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v1.1.0
    hooks:
      - id: demo
CONFIG
    ;;
  validate-config) exit 0 ;;
  install-hooks)
    printf 'concurrent: true\n' > .pre-commit-config.yaml
    chmod 600 .pre-commit-config.yaml
    exit 0
    ;;
  *)
    echo "DOWNSTREAM_SHOULD_NOT_RUN:$*" >&2
    exit 97
    ;;
esac
PRECOMMIT
  chmod +x .venv/bin/python .venv/bin/pre-commit
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "1.0.0"; }
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-precommit
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/.pre-commit-config.yaml")" = "concurrent: true" ]
  [ "$(python3 -c \
    'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' \
    "$DEV_PROJECT/.pre-commit-config.yaml")" = "600" ]
  [[ "$output" == \
    *"changed while hook environments were installed"* ]]
  [[ "$output" == *"Original snapshot retained:"* ]]
  [[ "$output" == *"private update workspace was retained"* ]]
  grep -q '^install-hooks --config ' "$PRECOMMIT_PHASE_LOG"
  ! grep -q '^run ' "$PRECOMMIT_PHASE_LOG"
  ! grep -q '^install ' "$PRECOMMIT_PHASE_LOG"
  [[ "$output" != *"DOWNSTREAM_SHOULD_NOT_RUN"* ]]
}

@test "dev update safety: mutable hook candidate is rejected before publication" {
  write_precommit_project
  export PRECOMMIT_PHASE_LOG="$TEST_TEMP_DIR/precommit-phases.log"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "sync" ]]; then
  mkdir -p .venv/bin
  cat > .venv/bin/python <<'PYTHON'
#!/usr/bin/env bash
case "${4:-}" in
  pre_commit) exit 1 ;;
  *) exit 0 ;;
esac
PYTHON
  cat > .venv/bin/pre-commit <<'PRECOMMIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PRECOMMIT_PHASE_LOG"
if [[ "${1:-}" == "autoupdate" ]]; then
  printf '%s\n' \
    'repos:' \
    '  - repo: https://example.invalid/hooks' \
    '    rev: v2.0.0' \
    '    hooks:' \
    '      - id: demo' > "$4"
  exit 0
fi
exit 97
PRECOMMIT
  chmod +x .venv/bin/python .venv/bin/pre-commit
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  local before
  before=$(cat "$DEV_PROJECT/.pre-commit-config.yaml")

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "1.0.0"; }
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-precommit
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/.pre-commit-config.yaml")" = "$before" ]
  [[ "$output" == *"private hook update plan was unsafe"* ]]
  grep -q '^autoupdate --freeze --config ' "$PRECOMMIT_PHASE_LOG"
  ! grep -q '^validate-config ' "$PRECOMMIT_PHASE_LOG"
  ! grep -q '^install ' "$PRECOMMIT_PHASE_LOG"
}

@test "dev update safety: pre-commit lock failure rolls pyproject back exactly" {
  write_precommit_project

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "lock" ]]; then
  grep -q "pre-commit>=2.0.0" pyproject.toml \
    && echo "LOCK_SAW_PRIVATE_PLAN" >&2
  exit 42
fi
echo "DOWNSTREAM_SHOULD_NOT_RUN:$*" >&2
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  local before
  before=$(cat "$DEV_PROJECT/pyproject.toml")

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "2.0.0"; }

    _dev_pypi_check_connectivity() { return 0; }
    dev-update-precommit
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/pyproject.toml")" = "$before" ]
  [[ "$output" == *"LOCK_SAW_PRIVATE_PLAN"* ]]
  [[ "$output" == *"restored from the exact invocation backup"* ]]
  [[ "$output" != *"DOWNSTREAM_SHOULD_NOT_RUN:sync"* ]]
}

@test "dev update safety: autoupdate never overwrites a changed live config" {
  write_precommit_project
  chmod 640 "$DEV_PROJECT/.pre-commit-config.yaml"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "sync" ]]; then
  mkdir -p .venv/bin
  cat > .venv/bin/python <<'PYTHON'
#!/usr/bin/env bash
case "${4:-}" in
  pre_commit) exit 1 ;;
  *) exit 0 ;;
esac
PYTHON
  cat > .venv/bin/pre-commit <<'PRECOMMIT'
#!/usr/bin/env bash
if [[ "${1:-}" == "autoupdate" ]]; then
  printf 'partial: true\n' > .pre-commit-config.yaml
  chmod 600 .pre-commit-config.yaml
  echo "AUTOUPDATE_LEFT_PARTIAL_FILE" >&2
  exit 42
fi
echo "DOWNSTREAM_SHOULD_NOT_RUN:$*" >&2
exit 97
PRECOMMIT
  chmod +x .venv/bin/python .venv/bin/pre-commit
  exit 0
fi
echo "DOWNSTREAM_SHOULD_NOT_RUN:$*" >&2
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "1.0.0"; }

    _dev_pypi_check_connectivity() { return 0; }
    dev-update-precommit
  '

  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/.pre-commit-config.yaml")" = "partial: true" ]
  [ "$(python3 -c \
    'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' \
    "$DEV_PROJECT/.pre-commit-config.yaml")" = "600" ]
  [[ "$output" == *"AUTOUPDATE_LEFT_PARTIAL_FILE"* ]]
  [[ "$output" == *"refusing to overwrite concurrent or unexpected edits"* ]]
  [[ "$output" == *"Original snapshot retained:"* ]]
  [[ "$output" == *"private update workspace was retained"* ]]
  [[ "$output" != *"DOWNSTREAM_SHOULD_NOT_RUN:install"* ]]
}

@test "dev update safety: pre-commit tool output never enters stdout data" {
  write_precommit_project

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
echo "TOOL_UI:$*"
if [[ "${1:-}" == "sync" ]]; then
  mkdir -p .venv/bin
  cat > .venv/bin/python <<'PYTHON'
#!/usr/bin/env bash
case "${4:-}" in
  pre_commit) exit 1 ;;
  *) exit 0 ;;
esac
PYTHON
  cat > .venv/bin/pre-commit <<'PRECOMMIT'
#!/usr/bin/env bash
echo "PRECOMMIT_UI:$*"
exit 0
PRECOMMIT
  chmod +x .venv/bin/python .venv/bin/pre-commit
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "1.0.0"; }

    local captured
    _dev_pypi_check_connectivity() { return 0; }
    captured=$(dev-update-precommit)
    local -i update_result=$?
    print -u2 -r -- "CAPTURED_STDOUT=<$captured>"
    return $update_result
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"TOOL_UI:sync --all-groups"* ]]
  [[ "$output" == *"PRECOMMIT_UI:autoupdate"* ]]
  [[ "$output" == *"CAPTURED_STDOUT=<>"* ]]
}

@test "dev update safety: post-sync pre-commit never falls through to PATH" {
  write_precommit_project
  export GLOBAL_PRECOMMIT_LOG="$TEST_TEMP_DIR/global-precommit.log"
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/precommit-sync.log"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_UPDATE_LOG"
exit 0
EOF
  cat > "$TEST_MOCK_BIN/pre-commit" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GLOBAL_PRECOMMIT_LOG"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/pre-commit"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "1.0.0"; }
    _dev_pypi_check_connectivity() { return 0; }
    dev-update-precommit
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"project pre-commit runner is unavailable"* ]]
  grep -Fxq 'sync --all-groups' "$UV_UPDATE_LOG"
  [ ! -e "$GLOBAL_PRECOMMIT_LOG" ]
}

@test "dev update safety: toolchain delegates uv and never invokes ambient pip" {
  export TOOLCHAIN_OWNER_LOG="$TEST_TEMP_DIR/toolchain-owner.log"
  export AMBIENT_TOOL_LOG="$TEST_TEMP_DIR/ambient-tools.log"

  cat > "$TEST_MOCK_BIN/python3" <<'EOF'
#!/usr/bin/env bash
printf 'python3:%s\n' "$*" >> "$AMBIENT_TOOL_LOG"
exit 97
EOF
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv:%s\n' "$*" >> "$AMBIENT_TOOL_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/python3" "$TEST_MOCK_BIN/uv"

  run run_zsh '
    sys-menu() {
      print -r -- "$*" >> "$TOOLCHAIN_OWNER_LOG"
      return 0
    }

    local captured
    captured=$(dev-update-toolchain)
    local -i update_status=$?
    print -u2 -r -- "CAPTURED_STDOUT=<$captured>"
    return $update_status
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$TOOLCHAIN_OWNER_LOG")" = "update-uv-system" ]
  [ ! -e "$AMBIENT_TOOL_LOG" ]
  [[ "$output" == *"Ambient Python and pip were left unchanged"* ]]
  [[ "$output" == *"CAPTURED_STDOUT=<>"* ]]
}

@test "dev update safety: toolchain reports its owning suite failure" {
  run run_zsh '
    sys-menu() {
      [[ "$1" == "update-uv-system" ]] || return 98
      print -u2 -r -- "OWNER_FAILED"
      return 42
    }

    dev-update-toolchain
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"OWNER_FAILED"* ]]
  [[ "$output" != *"Host toolchain maintenance completed"* ]]
}

@test "dev update safety: pre-commit reports missing Python before uv mutation" {
  write_precommit_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "${1:-}" == "-v" && "${2:-}" == "python3" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    _DEV_PYTHON_TOML_STATE=""

    dev-update-precommit
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Python 3.11+ with tomllib is required"* ]]
  [ ! -s "$UV_UPDATE_LOG" ]
}

@test "dev update safety: Python decline performs no uv mutation" {
  write_python_venv_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_confirm_outcome() {
      print -r -- "declined"
    }

    dev-update-python
  '

  [ "$status" -eq 0 ]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ ! -s "$UV_UPDATE_LOG" ]
  [[ "$output" == *"Python and .venv were left untouched"* ]]
}

@test "dev update safety: Python rebuild fails closed without a terminal" {
  write_python_venv_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python
  '

  [ "$status" -eq 1 ]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ ! -s "$UV_UPDATE_LOG" ]
  [[ "$output" == *"needs confirmation; pass --yes"* ]]
}

@test "dev update safety: Python rebuild stages and atomically replaces venv" {
  write_python_venv_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python --yes
  '

  [ "$status" -eq 0 ]
  [ ! -e "$DEV_PROJECT/.venv/original-marker" ]
  [ -f "$DEV_PROJECT/.venv/sync-marker" ]
  grep -qx 'python install --upgrade 3.11' "$UV_UPDATE_LOG"
  grep -q \
    '^venv --clear --managed-python --python 3.11 --relocatable .*/.zdx-dev-python\..*/new-venv$' \
    "$UV_UPDATE_LOG"
  grep -qx 'sync --all-groups --locked' "$UV_UPDATE_LOG"
  [ -z "$(find "$DEV_PROJECT" -maxdepth 1 \
    -name '.zdx-dev-python.*' -print -quit)" ]
  [[ "$output" == *"Python 3.11.9 -> Python 3.11.10"* ]]
}

@test "dev update safety: failed staged sync preserves the original venv" {
  write_python_venv_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  export UV_SYNC_STATUS=42
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ -z "$(find "$DEV_PROJECT" -maxdepth 1 \
    -name '.zdx-dev-python.*' -print -quit)" ]
  [[ "$output" == *"Environment sync failed"* ]]
  [[ "$output" == *"existing .venv was left untouched"* ]]
}

@test "dev update safety: lock change during sync blocks venv publication" {
  write_python_venv_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  export UV_MUTATE_LOCK_DURING_SYNC=1
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ -z "$(find "$DEV_PROJECT" -maxdepth 1 \
    -name '.zdx-dev-python.*' -print -quit)" ]
  [[ "$output" == *"Project inputs changed while"* ]]
  [[ "$output" != *"Python updated:"* ]]
}

@test "dev update safety: failed Python install preserves the original venv" {
  write_python_venv_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  export UV_PYTHON_INSTALL_STATUS=42
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ -z "$(find "$DEV_PROJECT" -maxdepth 1 \
    -name '.zdx-dev-python.*' -print -quit)" ]
  [ "$(wc -l < "$UV_UPDATE_LOG")" -eq 1 ]
  grep -qx 'python install --upgrade 3.11' "$UV_UPDATE_LOG"
  [[ "$output" == *"Python installation failed"* ]]
}

@test "dev update safety: failed venv publication restores the original" {
  write_python_venv_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "${1:-}" == "mv" && "${2:-}" == "--" \
        && "${3:-}" == */new-venv \
        && "${4:-}" == "$DEV_PROJECT/.venv" ]]; then
        return 42
      fi
      builtin command "$@"
    }

    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ ! -e "$DEV_PROJECT/.venv/sync-marker" ]
  [ -z "$(find "$DEV_PROJECT" -maxdepth 1 \
    -name '.zdx-dev-python.*' -print -quit)" ]
  [[ "$output" == *"original .venv was restored"* ]]
}

@test "dev update safety: failed venv rollback retains the original for recovery" {
  write_python_venv_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "${1:-}" == "mv" && "${2:-}" == "--" \
        && ( "${3:-}" == */new-venv \
          || "${3:-}" == */original-venv ) \
        && "${4:-}" == "$DEV_PROJECT/.venv" ]]; then
        return 42
      fi
      builtin command "$@"
    }

    dev-update-python --yes
    local -i update_rc=$?
    local -a recovery_markers=(
      "$DEV_PROJECT"/.zdx-dev-python.*/original-venv/original-marker(N)
    )
    (( ${#recovery_markers[@]} == 1 )) \
      && print -u2 -r -- "ORIGINAL_RETAINED"
    return $update_rc
  '

  [ "$status" -eq 1 ]
  [ ! -e "$DEV_PROJECT/.venv" ]
  [[ "$output" == *"Automatic .venv rollback failed"* ]]
  [[ "$output" == *"Python recovery workspace retained"* ]]
  [[ "$output" == *"ORIGINAL_RETAINED"* ]]
}

@test "dev update safety: symlinked venv is refused before uv mutation" {
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
EOF
  mkdir -p "$DEV_PROJECT/real-venv/bin"
  ln -s "$DEV_PROJECT/real-venv" "$DEV_PROJECT/.venv"
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [ ! -s "$UV_UPDATE_LOG" ]
  [[ "$output" == *"unsafe .venv path"* ]]
}

@test "dev update safety: exact Python pin is delegated before uv mutation" {
  write_python_venv_project
  printf '3.11.9\n' > "$DEV_PROJECT/.python-version"
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ ! -s "$UV_UPDATE_LOG" ]
  [[ "$output" == *"exact or complex Python pin"* ]]
  [[ "$output" == *"dev-menu venv-python-pin <major.minor>"* ]]
}

@test "dev update safety: Python pin change after confirmation is refused" {
  write_python_venv_project
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_confirm_outcome() {
      print -r -- "3.12" > .python-version
      print -r -- "confirmed"
    }

    dev-update-python
  '

  [ "$status" -eq 1 ]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ ! -s "$UV_UPDATE_LOG" ]
  [[ "$output" == *"version selection changed after authorization"* ]]
}

@test "dev update safety: alternative Python runtime is delegated safely" {
  write_python_venv_project
  cat > "$DEV_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-I" ]]; then
  printf 'PyPy\n'
else
  printf 'Python 3.11.9\n'
fi
EOF
  chmod +x "$DEV_PROJECT/.venv/bin/python"
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ ! -s "$UV_UPDATE_LOG" ]
  [[ "$output" == *"require a CPython .venv"* ]]
  [[ "$output" == *"dev-menu venv-python-pin <runtime>"* ]]
}

@test "dev update safety: absent venv delegates runtime ownership without local uv mutation" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
requires-python = ">=3.11"
EOF
  printf '3.11.9\n' > "$DEV_PROJECT/.python-version"
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  export PY_DELEGATE_LOG="$TEST_TEMP_DIR/py-delegate.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_delegate_py() {
      print -r -- "$*" >> "$PY_DELEGATE_LOG"
      return 0
    }
    dev-update-python
  '

  [ "$status" -eq 0 ]
  [ "$(cat "$PY_DELEGATE_LOG")" = "venv-python-install" ]
  [ ! -s "$UV_UPDATE_LOG" ]
  [[ "$output" == \
    *"runtime selection and installation are owned by py-menu"* ]]
  [[ "$output" == *"Delegating to the Python suite"* ]]
}

@test "dev update safety: absent venv forwards --yes and owner status" {
  export UV_UPDATE_LOG="$TEST_TEMP_DIR/uv-update.log"
  export PY_DELEGATE_LOG="$TEST_TEMP_DIR/py-delegate.log"
  : > "$UV_UPDATE_LOG"
  write_python_update_uv_mock

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_delegate_py() {
      print -r -- "$*" >> "$PY_DELEGATE_LOG"
      return 23
    }
    dev-update-python --yes
  '

  [ "$status" -eq 23 ]
  [ "$(cat "$PY_DELEGATE_LOG")" = "venv-python-install --yes" ]
  [ ! -s "$UV_UPDATE_LOG" ]
}
