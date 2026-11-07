#!/usr/bin/env bats
# Programs below run in the isolated Zsh child; mock state is per test.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  _zdx_test_dev_preview_private_python || return 1
  export DEV_PROJECT="$HOME/project"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  export TRUST_LOG="$HOME/trust.log"
  mkdir -m 700 "$DEV_PROJECT" "$TMPDIR" "$HOME/hook-cache"
  printf 'keep\n' > "$HOME/hook-cache/canary"
  export PRE_COMMIT_HOME="$HOME/hook-cache"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "trust-fixture"
dependencies = ["pre-commit>=1.0.0"]
EOF
  printf 'version = 1\n' > "$DEV_PROJECT/uv.lock"
  cat > "$DEV_PROJECT/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/reviewed-hooks
    rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1.0.0
    hooks:
      - id: fixture
EOF
  cp "$DEV_PROJECT/pyproject.toml" "$HOME/original.pyproject"
  cp "$DEV_PROJECT/.pre-commit-config.yaml" "$HOME/original.hooks"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv:%s\n' "$*" >> "$TRUST_LOG"
case "$1" in lock|sync) exit 0 ;; *) exit 97 ;; esac
EOF
  cat > "$TEST_MOCK_BIN/pre-commit" <<'EOF'
#!/usr/bin/env bash
printf 'hooks:%s\n' "$*" >> "$TRUST_LOG"
case "$1" in
  autoupdate)
    [[ "$2" == --freeze && "$3" == --config && "$4" != "$PWD/.pre-commit-config.yaml" ]] || exit 91
    if [[ "${EXPECT_PRIVATE_CACHE:-0}" == 1 ]]; then
      [[ "$PRE_COMMIT_HOME" == "$TMPDIR"/zdx-dev-update.*/pre-commit-cache ]] || exit 92
      [[ -d "$PRE_COMMIT_HOME" && ! -L "$PRE_COMMIT_HOME" ]] || exit 93
      printf 'cached\n' > "$PRE_COMMIT_HOME/cache-entry"
    fi
    perl -pi -e 's/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1\.0\.0/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v1.1.0/' "$4"
    if [[ "${UNSAFE_CANDIDATE:-0}" == 1 ]]; then
      printf 'fail_fast: true\n' >> "$4"
    fi
    ;;
  validate-config|install-hooks|install|run) ;;
  *) exit 94 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv" "$TEST_MOCK_BIN/pre-commit"
}

teardown() {
  _zdx_test_dev_preview_diagnostic_dump
  cleanup_sandbox
}

run_trust() {
  local diagnostic
  diagnostic=$(_zdx_test_dev_preview_diagnostic_program)
  run_zsh '
    source "$ZSH_CUSTOM/functions/dev-menu.zsh"
    '"$diagnostic"'
    cd "$DEV_PROJECT"
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pypi_latest() { print -r -- "1.0.0"; }
    # Exact project-runner provenance has dedicated integration coverage.
    # Here only private updater/uv executables are reachable.
    _dev_exact_project_python_tool_runner() {
      [[ "${NO_INSTALLED_RUNNER:-0}" == 0 ]] || return 1
      reply=("$TEST_MOCK_BIN/pre-commit")
    }
  '"$1"
}

assert_originals() {
  cmp "$HOME/original.pyproject" "$DEV_PROJECT/pyproject.toml"
  cmp "$HOME/original.hooks" "$DEV_PROJECT/.pre-commit-config.yaml"
}

assert_no_execution() {
  if [[ -e "$TRUST_LOG" ]]; then
    ! grep -Eq '^(uv:|hooks:)' "$TRUST_LOG" || return 1
  fi
}

@test "dev hook trust: nonterminal direct update refuses before new code or publication" {
  run run_trust 'dev-update-precommit > "$HOME/out" 2> "$HOME/err"'
  [ "$status" -eq 1 ]
  [ ! -s "$HOME/out" ]
  grep -q -- '--yes' "$HOME/err"
  assert_no_execution
  assert_originals
}

@test "dev hook trust: dispatched nonterminal update has the same refusal" {
  run run_trust 'dev-menu dev-update-precommit'
  [ "$status" -eq 1 ]
  assert_no_execution
  assert_originals
}

@test "dev hook trust: dry run resolves a private candidate without lasting changes" {
  export EXPECT_PRIVATE_CACHE=1
  run run_trust 'dev-update-precommit --dry-run > "$HOME/out" 2> "$HOME/err"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/out" ]
  grep -q '^hooks:autoupdate --freeze --config ' "$TRUST_LOG"
  ! grep -Eq '^(uv:|hooks:(install|install-hooks|run) )' "$TRUST_LOG" || return 1
  grep -q 'v1.1.0' "$HOME/err"
  grep -q 'dynamic upstream' "$HOME/err"
  grep -q 'installed pre-commit' "$HOME/err"
  assert_originals
  [ "$(cat "$HOME/hook-cache/canary")" = keep ]
  [ "$(ls -A "$HOME/hook-cache")" = canary ]
  [ -z "$(ls -A "$TMPDIR")" ]
  [ ! -e "$DEV_PROJECT/.dev-suite-backups" ]
}

@test "dev hook trust: yes cannot turn a dispatched dry run into execution" {
  export EXPECT_PRIVATE_CACHE=1
  run run_trust 'dev-menu dev-update-precommit --yes --dry-run'
  [ "$status" -eq 0 ]
  grep -q '^hooks:autoupdate ' "$TRUST_LOG"
  ! grep -Eq '^(uv:|hooks:(install|install-hooks|run) )' "$TRUST_LOG" || return 1
  assert_originals
}

@test "dev hook trust: dry run never installs an absent preview runner" {
  export NO_INSTALLED_RUNNER=1
  run run_trust 'dev-update-precommit --dry-run'
  [ "$status" -eq 1 ]
  [[ "$output" == *"already-installed"* ]]
  assert_no_execution
  assert_originals
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "dev hook trust: yes authorizes normal guarded installation and hook execution" {
  run run_trust 'dev-update-precommit --yes > "$HOME/out" 2> "$HOME/err"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/out" ]
  grep -q '^uv:sync --all-groups$' "$TRUST_LOG"
  grep -q '^hooks:install-hooks --config ' "$TRUST_LOG"
  grep -q '^hooks:install --install-hooks$' "$TRUST_LOG"
  grep -q '^hooks:run --all-files --config ' "$TRUST_LOG"
  grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$DEV_PROJECT/.pre-commit-config.yaml"
}

@test "dev hook trust: explicit trust decision precedes lock and environment work" {
  run run_trust '
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    _dev_confirm_ask() { print -r -- "confirmed:$*" >> "$TRUST_LOG"; return 0; }
    dev-update-precommit
  '
  [ "$status" -eq 0 ]
  [[ "$(head -n 1 "$TRUST_LOG")" == confirmed:* ]]
  grep -q '^uv:lock --upgrade-package pre-commit$' "$TRUST_LOG"
  grep -q 'pre-commit>=2.0.0' "$DEV_PROJECT/pyproject.toml"
}

@test "dev hook trust: decline leaves files and updater untouched" {
  run run_trust '
    _dev_confirm_ask() { return 1; }
    dev-update-precommit
  '
  [ "$status" -eq 0 ]
  assert_no_execution
  assert_originals
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "dev hook trust: configuration edited during consent blocks execution" {
  run run_trust '
    _dev_confirm_ask() { print -r -- "# concurrent edit" >> .pre-commit-config.yaml; return 0; }
    dev-update-precommit
  '
  [ "$status" -eq 1 ]
  assert_no_execution
  grep -q '# concurrent edit' "$DEV_PROJECT/.pre-commit-config.yaml"
}

@test "dev hook trust: pyproject edited during consent blocks execution" {
  run run_trust '
    _dev_confirm_ask() { print -r -- "# concurrent edit" >> pyproject.toml; return 0; }
    dev-update-precommit
  '
  [ "$status" -eq 1 ]
  assert_no_execution
  grep -q '# concurrent edit' "$DEV_PROJECT/pyproject.toml"
}

@test "dev hook trust: yes preserves unsafe-candidate refusal" {
  export UNSAFE_CANDIDATE=1
  run run_trust 'dev-update-precommit --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"plan was unsafe"* ]]
  ! grep -Eq '^hooks:(install-hooks|install|run) ' "$TRUST_LOG" || return 1
  assert_originals
}

@test "dev hook trust: help and malformed grammar are passive direct and dispatched" {
  run run_trust '
    _dev_header() { print -u2 -- UNEXPECTED_PROBE; return 97; }
    local -a bad=("" --bogus operand)
    local item rc
    for item in "${bad[@]}"; do
      dev-update-precommit "$item" > "$HOME/out" 2> "$HOME/err"
      rc=$?
      (( rc == 2 )) || return 91
      dev-menu dev-update-precommit "$item" > "$HOME/out" 2> "$HOME/err"
      rc=$?
      (( rc == 2 )) || return 92
    done
    dev-update-precommit --help extra > "$HOME/out" 2> "$HOME/err"
    (( $? == 2 )) || return 93
    dev-update-precommit --help > "$HOME/out" 2> "$HOME/err" || return 94
    [[ ! -s "$HOME/out" ]] || return 95
    command grep -q -- "--dry-run" "$HOME/err" || return 96
    dev-menu dev-update-precommit --help
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"--yes"* && "$output" == *"--dry-run"* ]]
  [[ "$output" != *UNEXPECTED_PROBE* ]]
  assert_no_execution
}

@test "dev hook trust: aggregate forwards yes only after aggregate authorization" {
  run run_trust '
    _dev_confirm_ask() { print -r -- confirmed >> "$TRUST_LOG"; return 0; }
    _dev_delegate_sys() { return 0; }
    dev-update-deps() { return 0; }
    dev-update-lock() { return 0; }
    dev-update-precommit() { print -r -- "child:$*" >> "$TRUST_LOG"; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { return 0; }
    dev-update-all
  '
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$TRUST_LOG")" = confirmed ]
  grep -q '^child:--yes$' "$TRUST_LOG"
  [[ "$output" == *"dynamic upstream"* && "$output" == *"execute"* ]]
}

@test "dev hook trust: aggregate dry run forwards only passive hook preview" {
  run run_trust '
    _dev_delegate_sys() { print -u2 -- UNEXPECTED_MUTATION; return 97; }
    dev-update-deps() { return 0; }
    dev-update-lock() { print -u2 -- UNEXPECTED_MUTATION; return 97; }
    dev-update-precommit() { print -r -- "child:$*" >> "$TRUST_LOG"; }
    dev-clean-all() { return 0; }
    dev-update-all --dry-run
  '
  [ "$status" -eq 0 ]
  grep -q '^child:--dry-run$' "$TRUST_LOG"
  [[ "$output" != *UNEXPECTED_MUTATION* ]]
}

@test "dev hook trust: completion exposes flags directly and under dev-menu" {
  export COMPLETION="$TEST_SUITE_ROOT/completions/_dev-menu"
  run env COMPLETION="$COMPLETION" zsh -f -c '
    emulate -R zsh
    local route
    for route in direct nested; do
      () {
        local -a words=(dev-update-precommit)
        [[ "$route" == nested ]] && words=(dev-menu dev-update-precommit "")
        _arguments() {
          if [[ "$1" == -C ]]; then
            state=arguments
            line=(dev-update-precommit)
          else
            print -rl -- "$@"
          fi
        }
        source "$COMPLETION"
      }
    done
  '
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c -- '--dry-run\[')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c -- '--yes\[')" -eq 2 ]
}

@test "dev hook trust: menu advertises trust and command remains excluded from batch" {
  run run_trust '
    _dev_menu_rows | command grep -F "|dev-update-precommit|" || return 1
    _dev_command_batch_safe dev-update-precommit && return 2
    return 0
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"trust"* && "$output" == *"execute"* ]]
  grep -q $'^dev-update-precommit\tdev-update-precommit.zsh\tremote-code\tdev$' \
    "$TEST_SUITE_ROOT/test/fixtures/dev-public-commands.tsv"
}

@test "dev hook trust control: existing help stays passive without a backend" {
  run run_trust '
    _dev_header() { print -u2 -- UNEXPECTED_PROBE; return 97; }
    dev-menu dev-update-precommit --help
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: dev-update-precommit"* ]]
  [[ "$output" != *UNEXPECTED_PROBE* ]]
  assert_no_execution
  assert_originals
}

@test "dev hook trust control: malformed arguments stay rejected before probes" {
  run run_trust '
    _dev_header() { print -u2 -- UNEXPECTED_PROBE; return 97; }
    dev-menu dev-update-precommit "" --bogus
  '
  [ "$status" -eq 2 ]
  [[ "$output" != *UNEXPECTED_PROBE* ]]
  assert_no_execution
  assert_originals
}

@test "dev hook trust: preview never displays hook URL credentials or query fragments" {
  perl -pi -e 's{https://example.invalid/reviewed-hooks}{https://private-user:private-password\@example.invalid/reviewed-hooks?private-query=secret#private-fragment}' \
    "$DEV_PROJECT/.pre-commit-config.yaml"
  run run_trust 'dev-update-precommit --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"example.invalid/reviewed-hooks"* ]]
  [[ "$output" != *private-user* && "$output" != *private-password* ]]
  [[ "$output" != *private-query* && "$output" != *private-fragment* ]]
}

@test "dev hook trust: passive package bump planning cannot publish or lock" {
  export EXPECT_PRIVATE_CACHE=1
  run run_trust '
    _dev_pypi_latest() { print -r -- "2.0.0"; }
    dev-update-precommit --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.0.0 → 2.0.0"* ]]
  ! grep -Eq '^(uv:|hooks:(install|install-hooks|run) )' "$TRUST_LOG" || return 1
  assert_originals
  [ ! -e "$DEV_PROJECT/.dev-suite-backups" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "dev hook trust: passive runner writable by others is refused before execution" {
  chmod 777 "$TEST_MOCK_BIN/pre-commit"
  run run_trust 'dev-update-precommit --dry-run'
  [ "$status" -eq 1 ]
  [[ "$output" == *"runner is not trusted"* ]]
  assert_no_execution
  assert_originals
}

@test "dev hook trust: documented short yes alias authorizes the same transaction" {
  run run_trust 'dev-menu dev-update-precommit -y'
  [ "$status" -eq 0 ]
  grep -q '^hooks:install-hooks --config ' "$TRUST_LOG"
  grep -q '^hooks:run --all-files --config ' "$TRUST_LOG"
}

@test "dev hook trust: input hash and dynamic execution scope are visible before consent" {
  export CONFIG_DIGEST
  CONFIG_DIGEST=$(sha256_file "$DEV_PROJECT/.pre-commit-config.yaml")
  run run_trust '
    _dev_confirm_ask() {
      command grep -Fq -- "$CONFIG_DIGEST" "$HOME/err" || return 2
      command grep -Fq -- "dynamic upstream" "$HOME/err" || return 2
      command grep -Fq -- "uv sync --all-groups" "$HOME/err" || return 2
      command grep -Fq -- "install-hooks --config" "$HOME/err" || return 2
      command grep -Fq -- "run --all-files --config" "$HOME/err" || return 2
      print -r -- reviewed > "$HOME/decision"
      return 1
    }
    dev-update-precommit > "$HOME/out" 2> "$HOME/err"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/decision")" = reviewed ]
  [ ! -s "$HOME/out" ]
  assert_no_execution
  assert_originals
}

@test "dev hook trust: aggregate displays the configuration hash before consent" {
  export CONFIG_DIGEST
  CONFIG_DIGEST=$(sha256_file "$DEV_PROJECT/.pre-commit-config.yaml")
  run run_trust '
    _dev_confirm_ask() {
      command grep -Fq -- "$CONFIG_DIGEST" "$HOME/err" || return 2
      command grep -Fq -- "$DEV_PROJECT/.pre-commit-config.yaml" "$HOME/err" || return 2
      print -r -- reviewed > "$HOME/decision"
      return 1
    }
    dev-update-all > "$HOME/out" 2> "$HOME/err"
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/decision")" = reviewed ]
  assert_no_execution
  assert_originals
}

@test "dev hook trust: an earlier aggregate step cannot change the approved configuration" {
  run run_trust '
    _dev_delegate_sys() { return 0; }
    dev-update-deps() { return 0; }
    dev-update-lock() { print -r -- "# changed after approval" >> .pre-commit-config.yaml; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { print -r -- continued > "$HOME/cleanup"; }
    dev-update-all --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"authorized aggregate plan"* && "$output" == *"new invocation"* ]]
  assert_no_execution
  grep -q '# changed after approval' "$DEV_PROJECT/.pre-commit-config.yaml"
  [ "$(cat "$HOME/cleanup")" = continued ]
}

@test "dev hook trust: unknown aggregate configuration hash blocks only the hook step" {
  run run_trust '
    functions[_dev_fixture_file_fingerprint]="${functions[_dev_update_file_fingerprint]}"
    _dev_update_file_fingerprint() {
      [[ "$1" != "$DEV_PROJECT/.pre-commit-config.yaml" ]] || return 1
      _dev_fixture_file_fingerprint "$@"
    }
    _dev_delegate_sys() { print -r -- continued > "$HOME/host"; }
    dev-update-deps() { return 0; }
    dev-update-lock() { return 0; }
    dev-update-precommit() { print -r -- unexpected >> "$TRUST_LOG"; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { print -r -- continued > "$HOME/cleanup"; }
    dev-update-all --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"Pre-commit hooks"*"blocked"* ]]
  [ ! -e "$TRUST_LOG" ]
  [ "$(cat "$HOME/host")" = continued ]
  [ "$(cat "$HOME/cleanup")" = continued ]
  assert_originals
}

@test "dev hook trust: unchanged aggregate configuration executes with invocation-local approval" {
  run run_trust '
    _dev_delegate_sys() { return 0; }
    dev-update-deps() { return 0; }
    dev-update-lock() { return 0; }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { return 0; }
    dev-update-all --yes || return $?
    (( ! ${+_DEV_PRECOMMIT_REVIEW_CONFIG_PATH} \
      && ! ${+_DEV_PRECOMMIT_REVIEW_CONFIG_FINGERPRINT} ))
  '
  [ "$status" -eq 0 ]
  grep -q '^hooks:install-hooks --config ' "$TRUST_LOG"
  grep -q '^hooks:run --all-files --config ' "$TRUST_LOG"
}
