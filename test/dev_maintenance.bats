#!/usr/bin/env bats

setup() {
  load test_helper
  export DEV_PROJECT="$HOME/project"
  mkdir -p "$DEV_PROJECT"
}

teardown() {
  cleanup_sandbox
}

# --- Cleanup planning and boundaries ----------------------------------------

@test "dev cleanup: --dry-run prints the plan and removes nothing" {
  mkdir -p "$DEV_PROJECT/pkg/__pycache__" "$DEV_PROJECT/.pytest_cache"
  : > "$DEV_PROJECT/pkg/__pycache__/module.pyc"
  : > "$DEV_PROJECT/pkg/stale.pyc"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-py --dry-run'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Removal plan"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
  [ -d "$DEV_PROJECT/pkg/__pycache__" ]
  [ -d "$DEV_PROJECT/.pytest_cache" ]
  [ -f "$DEV_PROJECT/pkg/stale.pyc" ]
}

@test "dev cleanup: a declined confirmation removes nothing and returns zero" {
  mkdir -p "$DEV_PROJECT/pkg/__pycache__"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_confirm() { return 1; }
    dev-clean-py
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled"* ]]
  [ -d "$DEV_PROJECT/pkg/__pycache__" ]
}

@test "dev cleanup: --yes bypasses only the prompt and removes the plan" {
  mkdir -p "$DEV_PROJECT/pkg/__pycache__" "$DEV_PROJECT/.ruff_cache"
  : > "$DEV_PROJECT/pkg/stale.pyc"
  : > "$DEV_PROJECT/pkg/keep.py"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-py --yes'

  [ "$status" -eq 0 ]
  [ ! -d "$DEV_PROJECT/pkg/__pycache__" ]
  [ ! -d "$DEV_PROJECT/.ruff_cache" ]
  [ ! -f "$DEV_PROJECT/pkg/stale.pyc" ]
  [ -f "$DEV_PROJECT/pkg/keep.py" ]
}

@test "dev cleanup: non-interactive invocation without --yes fails closed" {
  mkdir -p "$DEV_PROJECT/pkg/__pycache__"

  # run_zsh redirects stdin from /dev/null, so no terminal is attached.
  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-py'

  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a terminal"* ]]
  [ -d "$DEV_PROJECT/pkg/__pycache__" ]
}

@test "dev cleanup: build and dist are removed only at the project root" {
  mkdir -p "$DEV_PROJECT/build" "$DEV_PROJECT/dist"
  mkdir -p "$DEV_PROJECT/vendor/thing/build"
  : > "$DEV_PROJECT/vendor/thing/build/keep.txt"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-py --yes'

  [ "$status" -eq 0 ]
  [ ! -d "$DEV_PROJECT/build" ]
  [ ! -d "$DEV_PROJECT/dist" ]
  [ -f "$DEV_PROJECT/vendor/thing/build/keep.txt" ]
}

@test "dev cleanup: --keep-build preserves the root build artifacts" {
  mkdir -p \
    "$DEV_PROJECT/build" \
    "$DEV_PROJECT/dist" \
    "$DEV_PROJECT/target" \
    "$DEV_PROJECT/pkg/__pycache__"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-all --keep-build --yes'

  [ "$status" -eq 0 ]
  [ -d "$DEV_PROJECT/build" ]
  [ -d "$DEV_PROJECT/dist" ]
  [ -d "$DEV_PROJECT/target" ]
  [ ! -d "$DEV_PROJECT/pkg/__pycache__" ]
}

@test "dev cleanup: generated coverage and root Cargo artifacts are removed" {
  mkdir -p "$DEV_PROJECT/htmlcov" "$DEV_PROJECT/target"
  printf '%s\n' "coverage" > "$DEV_PROJECT/.coverage"
  printf '%s\n' "parallel coverage" > "$DEV_PROJECT/.coverage.worker"
  printf '%s\n' "report" > "$DEV_PROJECT/htmlcov/index.html"
  printf '%s\n' "binary" > "$DEV_PROJECT/target/debug-output"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-all --yes'

  [ "$status" -eq 0 ]
  [ ! -f "$DEV_PROJECT/.coverage" ]
  [ ! -f "$DEV_PROJECT/.coverage.worker" ]
  [ ! -d "$DEV_PROJECT/htmlcov" ]
  [ ! -d "$DEV_PROJECT/target" ]
}

@test "dev cleanup: the .git directory is never traversed" {
  mkdir -p "$DEV_PROJECT/.git/objects/__pycache__"
  : > "$DEV_PROJECT/.git/.DS_Store"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-all --yes'

  [ "$status" -eq 0 ]
  [ -d "$DEV_PROJECT/.git/objects/__pycache__" ]
  [ -f "$DEV_PROJECT/.git/.DS_Store" ]
}

@test "dev cleanup: filenames with spaces and newlines survive as data" {
  mkdir -p "$DEV_PROJECT/pkg"
  printf 'x' > "$DEV_PROJECT/pkg/a file.pyc"
  printf 'x' > "$DEV_PROJECT/pkg/keep me.py"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-py --yes'

  [ "$status" -eq 0 ]
  [ ! -f "$DEV_PROJECT/pkg/a file.pyc" ]
  [ -f "$DEV_PROJECT/pkg/keep me.py" ]
}

@test "dev cleanup: the home directory is refused as a cleanup root" {
  run run_zsh 'cd "$HOME" && dev-clean-py --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"home directory"* ]]
}

@test "dev cleanup: the filesystem root is refused" {
  run run_zsh 'cd / && dev-clean-repo --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"filesystem root"* ]]
}

@test "dev cleanup: repo junk is removed and Terraform lock metadata is kept" {
  : > "$DEV_PROJECT/.DS_Store"
  : > "$DEV_PROJECT/notes.txt:Zone.Identifier"
  : > "$DEV_PROJECT/Thumbs.db"
  : > "$DEV_PROJECT/main.tf"
  : > "$DEV_PROJECT/.terraform.lock.hcl"
  : > "$DEV_PROJECT/plan.tfplan"
  mkdir -p "$DEV_PROJECT/.terraform/providers"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-all --yes'

  [ "$status" -eq 0 ]
  [ ! -f "$DEV_PROJECT/.DS_Store" ]
  [ ! -f "$DEV_PROJECT/notes.txt:Zone.Identifier" ]
  [ ! -f "$DEV_PROJECT/Thumbs.db" ]
  [ ! -f "$DEV_PROJECT/plan.tfplan" ]
  [ ! -d "$DEV_PROJECT/.terraform" ]
  [ -f "$DEV_PROJECT/.terraform.lock.hcl" ]
  [ -f "$DEV_PROJECT/main.tf" ]
}

@test "dev cleanup: nothing to clean reports success without a prompt" {
  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_confirm() { print -u2 -r -- "PROMPTED"; return 0; }
    dev-clean-py
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to clean"* ]]
  [[ "$output" != *"PROMPTED"* ]]
}

@test "dev cleanup: a partial failure is reported with non-zero status" {
  mkdir -p "$DEV_PROJECT/pkg/__pycache__" "$DEV_PROJECT/.ruff_cache"
  # A read-only parent makes the nested target genuinely unremovable. Mocking
  # `rm` would prove nothing: the suite calls `command rm` on purpose.
  chmod 500 "$DEV_PROJECT/pkg"

  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-py --yes'

  chmod 700 "$DEV_PROJECT/pkg"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not remove directory"* ]]
  [[ "$output" == *"failed"* ]]
  # The reachable target was still removed, and the failure was not silent.
  [ ! -d "$DEV_PROJECT/.ruff_cache" ]
}

@test "dev cleanup: dev-clean-repo rejects an unknown option" {
  run run_zsh 'cd "$DEV_PROJECT" && dev-clean-repo --keep-build'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "dev cleanup: dev-update-all fails closed without --yes when non-interactive" {
  run run_zsh 'cd "$DEV_PROJECT" && dev-update-all'

  [ "$status" -eq 1 ]
  [[ "$output" == *"--yes"* ]]
}

# --- Remote code policy -----------------------------------------------------

@test "dev remote: uv update never pipes an installer to a shell" {
  ! grep -qE 'curl[^|]*\|[[:space:]]*(sh|bash|zsh)' \
    "$TEST_SUITE_ROOT/functions/dev/dev-update.zsh"
  ! grep -qE 'astral\.sh/uv/install\.sh' \
    "$TEST_SUITE_ROOT/functions/dev/dev-update.zsh"
}

@test "dev remote: unavailable sys owner never falls back to a uv installer" {
  export UV_FALLBACK_LOG="$TEST_TEMP_DIR/uv-fallback.log"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_FALLBACK_LOG"
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh '
    cd "$DEV_PROJECT"
    unfunction sys-menu
    dev-update-toolchain
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"sys-menu is unavailable"* ]]
  [ ! -e "$UV_FALLBACK_LOG" ]
}

@test "dev remote: tflint update refuses the upstream shell installer" {
  cat > "$TEST_MOCK_BIN/tflint" <<'EOF'
#!/usr/bin/env bash
echo "TFLint version 0.50.0"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/tflint"

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "$1" == "-v" && "$2" == "brew" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    dev-update-tflint
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to pipe an unverified remote installer"* ]]
  [[ "$output" == *"terraform-linters/tflint/releases"* ]]
}

@test "dev remote: ephemeral runners are refused unless explicitly enabled" {
  : > "$DEV_PROJECT/module.py"

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "$1" == "-v" && "$2" == "ruff" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    dev-run-ruff
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"ephemeral execution is disabled"* ]]
  [[ "$output" == *"DEV_ALLOW_EPHEMERAL=1"* ]]
}

@test "dev remote: DEV_ALLOW_EPHEMERAL=1 permits uvx with a warning" {
  : > "$DEV_PROJECT/module.py"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
  cat > "$TEST_MOCK_BIN/uvx" <<'EOF'
#!/usr/bin/env bash
echo "uvx invoked: $*"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uvx"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_ALLOW_EPHEMERAL=1
    command() {
      if [[ "$1" == "-v" && "$2" == "ruff" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    dev-run-ruff
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"downloads remote code"* ]]
  [[ "$output" == *"uvx invoked: ruff check --no-fix --no-cache ."* ]]
}

@test "dev remote: a node tool in node_modules is used without npx" {
  : > "$DEV_PROJECT/package.json"
  mkdir -p "$DEV_PROJECT/node_modules/.bin"
  cat > "$DEV_PROJECT/node_modules/.bin/eslint" <<'EOF'
#!/usr/bin/env bash
echo "local eslint: $*"
exit 0
EOF
  chmod +x "$DEV_PROJECT/node_modules/.bin/eslint"

  cat > "$TEST_MOCK_BIN/npx" <<'EOF'
#!/usr/bin/env bash
echo "NPX SHOULD NOT RUN" >&2
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/npx"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-eslint'

  [ "$status" -eq 0 ]
  [[ "$output" == *"local eslint"* ]]
  [[ "$output" != *"NPX SHOULD NOT RUN"* ]]
}

@test "dev remote: markdownlint does not rewrite files without --fix" {
  : > "$DEV_PROJECT/README.md"
  mkdir -p "$DEV_PROJECT/node_modules/.bin"
  cat > "$DEV_PROJECT/node_modules/.bin/markdownlint" <<'EOF'
#!/usr/bin/env bash
echo "markdownlint args: $*"
exit 0
EOF
  chmod +x "$DEV_PROJECT/node_modules/.bin/markdownlint"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-markdownlint'
  [ "$status" -eq 0 ]
  [[ "$output" != *"--fix"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-markdownlint --fix'
  [ "$status" -eq 0 ]
  [[ "$output" == *"--fix"* ]]
  [[ "$output" == *"rewrites Markdown files in place"* ]]
}

@test "dev remote: markdownlint uses the centralized project config" {
  : > "$DEV_PROJECT/README.md"
  mkdir -p "$DEV_PROJECT/.config" "$DEV_PROJECT/node_modules/.bin"
  : > "$DEV_PROJECT/.config/markdownlint.yaml"
  cat > "$DEV_PROJECT/node_modules/.bin/markdownlint" <<'EOF'
#!/usr/bin/env bash
echo "markdownlint args: $*"
exit 0
EOF
  chmod +x "$DEV_PROJECT/node_modules/.bin/markdownlint"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-markdownlint'

  [ "$status" -eq 0 ]
  [[ "$output" == \
    *"markdownlint args: --config .config/markdownlint.yaml **/*.md"* ]]
}

# --- Persisted state --------------------------------------------------------

@test "dev state: pyproject backups are owner-only and pruned to the retention" {
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_BACKUP_RETENTION=2
    local index
    for index in 1 2 3 4; do
      # date resolution is one second, so stamp names deterministically.
      dev-backup-pyproject >/dev/null 2>&1
      command mv "$DEV_BACKUP_DIR"/pyproject.toml.*.bak \
        "$DEV_BACKUP_DIR/pyproject.toml.2026010${index}_000000.bak" 2>/dev/null
    done
    dev-backup-pyproject
    [[ -f "$_DEV_LAST_BACKUP_FILE" ]]
  '

  [ "$status" -eq 0 ]

  local backup_dir="$DEV_PROJECT/.dev-suite-backups"
  [ -d "$backup_dir" ]
  [ "$(stat -c '%a' "$backup_dir")" = "700" ]

  local count
  count=$(find "$backup_dir" -name 'pyproject.toml.*.bak' | wc -l)
  [ "$count" -eq 2 ]

  local backup_file
  backup_file=$(find "$backup_dir" -name 'pyproject.toml.*.bak' | head -1)
  [ "$(stat -c '%a' "$backup_file")" = "600" ]
}

@test "dev state: legacy world-readable backups are pruned without failing the update" {
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  local backup_dir="$DEV_PROJECT/.dev-suite-backups"
  mkdir -m 700 -p "$backup_dir"
  local index
  for index in 1 2 3; do
    printf 'legacy %s\n' "$index" \
      > "$backup_dir/pyproject.toml.2026010${index}_000000.bak"
    chmod 644 "$backup_dir/pyproject.toml.2026010${index}_000000.bak"
  done

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_BACKUP_RETENTION=2
    dev-backup-pyproject
    local -i backup_status=$?
    print -u2 -r -- "LAST_BACKUP:${_DEV_LAST_BACKUP_FILE:t}"
    return $backup_status
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Backup saved:"* ]]
  [[ "$output" == *"LAST_BACKUP:pyproject.toml."* ]]
  [[ "$output" != *"Left an unverified stale backup"* ]]
  [ ! -e "$backup_dir/pyproject.toml.20260101_000000.bak" ]
  [ ! -e "$backup_dir/pyproject.toml.20260102_000000.bak" ]
  [ -f "$backup_dir/pyproject.toml.20260103_000000.bak" ]
  [ "$(find "$backup_dir" -name 'pyproject.toml.*.bak' | wc -l)" -eq 2 ]
}

@test "dev state: an unprunable stale backup is retained without failing the update" {
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  local backup_dir="$DEV_PROJECT/.dev-suite-backups"
  mkdir -m 700 -p "$backup_dir"
  printf 'linked\n' > "$backup_dir/pyproject.toml.20260101_000000.bak"
  chmod 600 "$backup_dir/pyproject.toml.20260101_000000.bak"
  ln "$backup_dir/pyproject.toml.20260101_000000.bak" "$DEV_PROJECT/second-name"
  printf 'newer\n' > "$backup_dir/pyproject.toml.20260102_000000.bak"
  chmod 600 "$backup_dir/pyproject.toml.20260102_000000.bak"

  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_BACKUP_RETENTION=1
    dev-backup-pyproject
    local -i backup_status=$?
    [[ -f "$_DEV_LAST_BACKUP_FILE" ]] || return 1
    return $backup_status
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Backup saved:"* ]]
  [[ "$output" == *"Left an unverified stale backup in place:"* ]]
  [[ "$output" == *"Review 1 retained backup(s) manually under:"* ]]
  [ -f "$backup_dir/pyproject.toml.20260101_000000.bak" ]
  [ "$(cat "$DEV_PROJECT/second-name")" = "linked" ]
  [ ! -e "$backup_dir/pyproject.toml.20260102_000000.bak" ]
}

write_probe_curl_mock() {
  cat > "$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Emulates the PyPI probe: honors -w for the write-out and exits with the
# configured curl status. CURL_MOCK_WRITE mimics the probe write-out:
# "%{http_code} %{time_connect} %{num_connects} %{remote_ip}".
write_format=""
while (( $# > 0 )); do
  case "$1" in
    -w) write_format="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$write_format" ]] && printf '%s' "${CURL_MOCK_WRITE:-000 0.000 0 }"
exit "${CURL_MOCK_STATUS:-28}"
EOF
  chmod +x "$TEST_MOCK_BIN/curl"
}

@test "dev PyPI: a stalled TLS exchange is diagnosed with the WSL2 MTU hint" {
  write_probe_curl_mock

  run run_zsh '
    export CURL_MOCK_STATUS=28 CURL_MOCK_WRITE="000 0.000 1 151.101.0.223"
    _dev_pypi_host_is_wsl() { return 0; }
    _dev_pypi_check_connectivity
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot reach PyPI (HTTP 000)"* ]]
  [[ "$output" == *"accepted the TCP connection"* ]]
  [[ "$output" == *"smaller MTU"* ]]
  [[ "$output" == *"sudo ip link set dev eth0 mtu 1392"* ]]

  run run_zsh '
    export CURL_MOCK_STATUS=28 CURL_MOCK_WRITE="000 0.000 1 151.101.0.223"
    _dev_pypi_host_is_wsl() { return 1; }
    _dev_pypi_check_connectivity
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"accepted the TCP connection"* ]]
  [[ "$output" != *"eth0"* ]]
}

@test "dev PyPI: probe failures before TCP connect name the layer that failed" {
  write_probe_curl_mock

  run run_zsh '
    export CURL_MOCK_STATUS=28 CURL_MOCK_WRITE="000 0.000 0 "
    _dev_pypi_check_connectivity
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out before TCP connected"* ]]
  [[ "$output" != *"accepted the TCP connection"* ]]

  run run_zsh '
    export CURL_MOCK_STATUS=6 CURL_MOCK_WRITE="000 0.000 0 "
    _dev_pypi_check_connectivity
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"DNS could not resolve pypi.org"* ]]

  run run_zsh '
    export CURL_MOCK_STATUS=0 CURL_MOCK_WRITE="403 0.101 1 151.101.0.223"
    _dev_pypi_check_connectivity
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot reach PyPI (HTTP 403)"* ]]
  [[ "$output" == *"PyPI answered HTTP 403 instead of 200"* ]]

  run run_zsh '
    export CURL_MOCK_STATUS=0 CURL_MOCK_WRITE="200 0.101 1 151.101.0.223"
    _dev_pypi_check_connectivity
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"Cannot reach PyPI"* ]]
}

@test "dev state: a traversal override is refused" {
  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_BACKUP_DIR="../../escape"
    printf "[project]\n" > pyproject.toml
    dev-backup-pyproject
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *".."* ]]
  [ ! -d "$HOME/../escape" ]
}

@test "dev state: a state directory outside the project and home is refused" {
  run run_zsh '
    cd "$DEV_PROJECT"
    export DEV_REPORT_DIR="/tmp/zdx-dev-should-not-exist"
    _dev_report_dir_path
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"inside the project or your home"* ]]
  [ ! -d "/tmp/zdx-dev-should-not-exist" ]
}

@test "dev state: a symlinked state directory is refused" {
  mkdir -p "$HOME/elsewhere"
  ln -s "$HOME/elsewhere" "$DEV_PROJECT/.dev-suite-backups"
  printf '[project]\n' > "$DEV_PROJECT/pyproject.toml"

  run run_zsh 'cd "$DEV_PROJECT" && dev-backup-pyproject'

  [ "$status" -eq 1 ]
  [[ "$output" == *"symlinked"* ]]
  [ -z "$(ls -A "$HOME/elsewhere")" ]
}

@test "dev state: readers require exact mode 700 and writers repair owned state" {
  mkdir -p "$DEV_PROJECT/.dev-suite-profiles"
  chmod 1500 "$DEV_PROJECT/.dev-suite-profiles"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_state_existing "$DEV_PROFILE_DIR" profile
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be private (mode 700)"* ]]
  [ "$(stat -c '%a' "$DEV_PROJECT/.dev-suite-profiles")" = "1500" ]

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_profile_dir_path >/dev/null
  '

  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$DEV_PROJECT/.dev-suite-profiles")" = "700" ]
}

@test "dev state: reports render without echo -e and stay owner-only" {
  ! grep -q 'echo -e' "$TEST_SUITE_ROOT/functions/dev/dev-report.zsh"

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_report_init "Demo Report"
    _dev_report_section "Findings"
    _dev_report_status ok "everything fine"
    _dev_report_save "demo.md"
  '

  [ "$status" -eq 0 ]

  local report_file
  report_file=$(find "$DEV_PROJECT/dev-suite-reports" -name '*_demo.md' | head -1)
  [ -n "$report_file" ]
  [ "$(stat -c '%a' "$report_file")" = "600" ]
  grep -q '^# Demo Report$' "$report_file"
  grep -q '^- OK — everything fine$' "$report_file"
  ! grep -q '\\n' "$report_file"
}

# --- Profiles ---------------------------------------------------------------

@test "dev profiles: an invalid profile name is refused" {
  run run_zsh 'cd "$DEV_PROJECT" && dev-profile-run "../escape"'
  [ "$status" -eq 2 ]

  run run_zsh 'cd "$DEV_PROJECT" && dev-profile-delete "-weird"'
  [ "$status" -eq 2 ]

  run run_zsh 'cd "$DEV_PROJECT" && dev-profile-run "has space"'
  [ "$status" -eq 2 ]
}

@test "dev profiles: the complete task list is validated before dispatch" {
  mkdir -p "$DEV_PROJECT/.dev-suite-profiles"
  printf 'dev-check-health\nnot-a-real-command\n' \
    > "$DEV_PROJECT/.dev-suite-profiles/nightly.profile"
  chmod 700 "$DEV_PROJECT/.dev-suite-profiles"
  chmod 600 "$DEV_PROJECT/.dev-suite-profiles/nightly.profile"

  run run_zsh '
    cd "$DEV_PROJECT"
    local dispatch_log="$HOME/profile-dispatch"
    _dev_dispatch() {
      print -r -- "$1" >> "$dispatch_log"
    }
    dev-profile-run nightly
    result=$?
    [[ ! -e "$dispatch_log" ]] || return 99
    return $result
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"non-batch-eligible task: not-a-real-command"* ]]
}

@test "dev profiles: listing with no profiles is a documented no-op" {
  run run_zsh 'cd "$DEV_PROJECT" && dev-profile-list'
  [ "$status" -eq 0 ]
  [[ "$output" == *"No profiles saved yet"* ]]
}

@test "dev profiles: an explicit missing profile is an operational failure" {
  run run_zsh 'cd "$DEV_PROJECT" && dev-profile-run nightly'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Profile 'nightly' not found"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-profile-delete nightly --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Profile 'nightly' not found"* ]]
}

@test "dev profiles: saved profiles are owner-only and drawn from the menu model" {
  run run_zsh '
    cd "$DEV_PROJECT"
    # The mock marks the exact rendered rows so the snapshot check passes.
    fzf() {
      local -a rows=("${(@f)$(command cat)}")
      local row
      for row in "${rows[@]}"; do
        [[ "$row" == *"|dev-run-ruff|"* || "$row" == *"|dev-run-tests|"* ]] \
          && print -r -- "$row"
      done
      return 0
    }
    dev-profile-save nightly
  '

  [ "$status" -eq 0 ]

  local profile_file="$DEV_PROJECT/.dev-suite-profiles/nightly.profile"
  [ -f "$profile_file" ]
  [ "$(stat -c '%a' "$profile_file")" = "600" ]
  [ "$(cat "$profile_file")" = "dev-run-ruff
dev-run-tests" ]
}

# --- PyPI helpers -----------------------------------------------------------

@test "dev pypi: PEP 503 normalization collapses separators" {
  run run_zsh '
    _dev_normalize_pkg_name "pip_audit"
    _dev_normalize_pkg_name "Zope.Interface"
    _dev_normalize_pkg_name "ruamel--yaml__clib"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"pip-audit"* ]]
  [[ "$output" == *"zope-interface"* ]]
  [[ "$output" == *"ruamel-yaml-clib"* ]]
}

@test "dev pypi: the cache directory is removed on every exit path" {
  mkdir -p "$HOME/private-tmp"
  chmod 700 "$HOME/private-tmp"

  run run_zsh '
    TMPDIR="$HOME/private-tmp"
    _dev_pypi_cache_init || return 1
    local cache_dir="$_DEV_PYPI_CACHE_DIR"
    [[ -d "$cache_dir" ]] || return 1
    _dev_pypi_cache_cleanup
    [[ ! -d "$cache_dir" ]] || return 1
    [[ -z "$_DEV_PYPI_CACHE_DIR" ]] || return 1
    print -r -- OK
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "dev pypi: a specifier bump rewrites only the matched line" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
dependencies = [
  "requests>=2.31.0",
  "urllib3>=1.26.0,<2.0.0",
  "pinned==1.0.0",
]
EOF

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() {
      case "$1" in
        requests) print -r -- "2.32.3" ;;
        *) return 1 ;;
      esac
    }

    _dev_update_specifier requests 0 all
    print -r -- "result:$_DEV_UPDATE_RESULT"
    _dev_update_specifier urllib3 0 all
    print -r -- "compound:$_DEV_UPDATE_RESULT"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"result:updated|requests|2.31.0|2.32.3|"* ]]
  [[ "$output" == *"compound:skipped|urllib3"* ]]
  [[ "$output" == *"user-pinned"* ]]

  grep -q 'requests>=2.32.3' "$DEV_PROJECT/pyproject.toml"
  grep -q 'urllib3>=1.26.0,<2.0.0' "$DEV_PROJECT/pyproject.toml"
  grep -q 'pinned==1.0.0' "$DEV_PROJECT/pyproject.toml"
}

@test "dev pypi: a dry-run specifier bump leaves the file untouched" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["requests>=2.31.0"]
EOF
  local before
  before=$(cat "$DEV_PROJECT/pyproject.toml")

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "2.32.3"; }
    _dev_update_specifier requests 1 all
    print -r -- "result:$_DEV_UPDATE_RESULT"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"result:updated|requests|2.31.0|2.32.3|"* ]]
  [ "$(cat "$DEV_PROJECT/pyproject.toml")" = "$before" ]
}

@test "dev pypi: version tokens are treated as data, not a regular expression" {
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
dependencies = ["demo>=1.0.0+local.1"]
EOF

  run run_zsh '
    cd "$DEV_PROJECT"
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_update_specifier demo 0 all
  '

  [ "$status" -eq 0 ]
  grep -q 'demo>=2.0.0' "$DEV_PROJECT/pyproject.toml"
}

# --- Export -----------------------------------------------------------------

@test "dev export: -o accepts a filename and a failed export keeps the old file" {
  printf '[project]\n' > "$DEV_PROJECT/pyproject.toml"
  printf 'previous==1.0.0\n' > "$DEV_PROJECT/requirements.txt"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "export" ]]; then
  printf 'exported==2.0.0\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'cd "$DEV_PROJECT" && dev-export-deps -o custom.txt'
  [ "$status" -eq 0 ]
  grep -q 'exported==2.0.0' "$DEV_PROJECT/custom.txt"

  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'cd "$DEV_PROJECT" && dev-export-deps --yes'
  [ "$status" -eq 1 ]
  [ "$(cat "$DEV_PROJECT/requirements.txt")" = "previous==1.0.0" ]
}

@test "dev export: -o without a value returns invalid-argument status" {
  printf '[project]\n' > "$DEV_PROJECT/pyproject.toml"

  run run_zsh 'cd "$DEV_PROJECT" && dev-export-deps -o'
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires a filename"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-export-deps -o ""'
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires a filename"* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-export-deps --output='
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires a filename"* ]]
}

@test "dev export: an output path outside the project and home is refused" {
  printf '[project]\n' > "$DEV_PROJECT/pyproject.toml"

  run run_zsh \
    'cd "$DEV_PROJECT" && dev-export-deps --output=/tmp/zdx-dev-escape.txt'

  [ "$status" -eq 1 ]
  [[ "$output" == *"inside the project or your home"* ]]
  [ ! -f "/tmp/zdx-dev-escape.txt" ]
}

# --- Aggregate checks -------------------------------------------------------

@test "dev checks: run-all-checks leaves no helper function in the shell" {
  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-all-checks >/dev/null 2>&1
    typeset -f _run_check &>/dev/null && return 1
    (( ${#_DEV_CHECK_RESULTS[@]} == 0 )) || return 1
    print -r -- OK
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "dev checks: run-all-checks reports a failing gate with non-zero status" {
  : > "$DEV_PROJECT/module.py"

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-ruff() { return 1; }
    dev-run-bandit() { return 0; }
    dev-run-audit() { return 0; }
    dev-run-markdownlint() { return 0; }
    dev-run-all-checks
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Ruff (lint)"* ]]
  [[ "$output" == *"failed"* ]]
}

@test "dev checks: run-all-checks executes pytest when project tests exist" {
  mkdir -p "$DEV_PROJECT/.venv"
  : > "$DEV_PROJECT/test_module.py"

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-ruff() { return 0; }
    dev-run-audit() { return 0; }
    dev-run-bandit() { return 0; }
    dev-run-tests() {
      print -r -- called > "$HOME/pytest-called"
      return 0
    }
    dev-run-all-checks
  '

  [ "$status" -eq 0 ]
  [ -f "$HOME/pytest-called" ]
  [[ "$output" == *"Tests (pytest)"* ]]
  [[ "$output" == *"passed"* ]]
}

@test "dev checks: a pytest failure fails the aggregate summary" {
  mkdir -p "$DEV_PROJECT/.venv"
  : > "$DEV_PROJECT/test_module.py"

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-ruff() { return 0; }
    dev-run-audit() { return 0; }
    dev-run-bandit() { return 0; }
    dev-run-tests() { return 7; }
    dev-run-all-checks
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Tests (pytest)"* ]]
  [[ "$output" == *"failed"* ]]
}

@test "dev checks: run-all-checks skips pytest when no tests exist" {
  : > "$DEV_PROJECT/module.py"

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-ruff() { return 0; }
    dev-run-bandit() { return 0; }
    dev-run-tests() {
      print -r -- called > "$HOME/pytest-called"
      return 99
    }
    dev-run-all-checks
  '

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/pytest-called" ]
  [[ "$output" != *"Tests (pytest)"* ]]
}

@test "dev checks: configured gates fail visibly when their backends are missing" {
  : > "$DEV_PROJECT/.pre-commit-config.yaml"
  : > "$DEV_PROJECT/main.tf"
  : > "$DEV_PROJECT/Cargo.toml"

  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "$1" == "-v" && "$2" == (uv|tflint|cargo) ]]; then
        return 1
      fi
      builtin command "$@"
    }
    dev-run-all-checks
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Pre-commit hooks"* ]]
  [[ "$output" == *"TFLint"* ]]
  [[ "$output" == *"Cargo Clippy"* ]]
  [ "$(grep -c 'failed' <<< "$output")" -ge 3 ]
}

@test "dev checks: shellcheck counts exactly the files it analyzes" {
  mkdir -p "$DEV_PROJECT/scripts" "$DEV_PROJECT/node_modules"
  : > "$DEV_PROJECT/scripts/one.sh"
  : > "$DEV_PROJECT/scripts/two.bash"
  printf 'print -r -- ok\n' > "$DEV_PROJECT/scripts/three.zsh"
  : > "$DEV_PROJECT/node_modules/excluded.sh"

  cat > "$TEST_MOCK_BIN/shellcheck" <<'EOF'
#!/usr/bin/env bash
count=0
for arg in "$@"; do
  [[ "$arg" == "--" ]] && continue
  count=$((count + 1))
done
echo "shellcheck received $count file(s)"
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/shellcheck"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-shellcheck'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Analyzing 2 shell file(s)"* ]]
  [[ "$output" == *"shellcheck received 2 file(s)"* ]]
  [[ "$output" == *"Parsing 1 Zsh file(s)"* ]]
}

@test "dev checks: a Zsh parse failure fails the shell gate" {
  : > "$DEV_PROJECT/ok.sh"
  printf 'if true; then\n' > "$DEV_PROJECT/broken.zsh"

  cat > "$TEST_MOCK_BIN/shellcheck" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/shellcheck"

  run run_zsh 'cd "$DEV_PROJECT" && dev-run-shellcheck'

  [ "$status" -eq 1 ]
  [[ "$output" == *"parse check reported issues"* ]]
}

@test "dev checks: health check returns non-zero when issues are found" {
  run run_zsh '
    cd "$DEV_PROJECT"
    : > example.py
    _dev_pypi_check_connectivity() { return 0; }
    dev-check-health
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"pyproject.toml not found"* ]]
  [[ "$output" == *"issue(s) found"* ]]
}

@test "dev checks: health check has no dead dependency-graph probe" {
  ! grep -q 'circular' "$TEST_SUITE_ROOT/functions/dev/dev-checks.zsh"
  ! grep -q 'main_deps' "$TEST_SUITE_ROOT/functions/dev/dev-checks.zsh"
}
