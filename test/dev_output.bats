#!/usr/bin/env bats
# Developer suite output on the shared step services (docs/output-spec.md).
# Quoted programs are passed literally to the isolated Zsh process.
# shellcheck disable=SC2016

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

@test "dev output: a failing check replays its captured tail and names its retry" {
  : > "$DEV_PROJECT/example.py"

  run run_zsh '
    cd "$DEV_PROJECT"
    dev-run-ruff() {
      print -r -- "example.py:1:1: F401 unused import"
      return 1
    }
    dev-run-bandit() {
      print -r -- "BANDIT_SUCCESS_OUTPUT"
      return 0
    }
    dev-run-all-checks
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"── [1/2] Ruff (lint)"* ]]
  [[ "$output" == *"│ example.py:1:1: F401 unused import"* ]]
  [[ "$output" == *"✘ [1/2] Ruff (lint) — failed: status 1"* ]]
  [[ "$output" == *"✔ [2/2] Bandit (SAST) — passed"* ]]
  [[ "$output" != *"BANDIT_SUCCESS_OUTPUT"* ]]
  [[ "$output" == *"1 of 2 checks failed."* ]]
  [[ "$output" == *"dev-menu dev-run-ruff"* ]]
}

@test "dev output: the uv.lock refresh reports the locked versions it changed" {
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  cat > "$DEV_PROJECT/uv.lock" <<'EOF'
version = 1

[[package]]
name = "alpha"
version = "1.0.0"

[[package]]
name = "beta"
version = "2.0.0"
EOF
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
# The first refresh upgrades alpha and adds gamma; a later one changes nothing.
if [[ "$*" == "lock --upgrade" ]] && ! grep -q '^name = "gamma"$' uv.lock; then
  printf 'UV_LOCK_OUTPUT\n'
  sed -i 's/^version = "1.0.0"$/version = "1.1.0"/' uv.lock
  printf '\n[[package]]\nname = "gamma"\nversion = "0.1.0"\n' >> uv.lock
fi
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/uv"

  run run_zsh 'cd "$DEV_PROJECT" && dev-update-lock'

  [ "$status" -eq 0 ]
  [[ "$output" == *'$ uv lock --upgrade  (output shown on failure)'* ]]
  [[ "$output" != *"UV_LOCK_OUTPUT"* ]]
  printf '%s\n' "$output" | grep -Eq '^  alpha +1[.]0[.]0 +1[.]1[.]0$'
  printf '%s\n' "$output" | grep -Eq '^  gamma +— +0[.]1[.]0$'
  [[ "$output" != *"  beta "* ]]
  [[ "$output" == *"uv.lock updated: 2 packages changed; the environment was synced."* ]]

  run run_zsh 'cd "$DEV_PROJECT" && dev-update-lock'

  [ "$status" -eq 0 ]
  [[ "$output" == *"uv.lock is already current; the environment was synced."* ]]
}

@test "dev output: the hook revision guard reports every remote revision" {
  cat > "$DEV_PROJECT/pre-commit.original.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/current
    rev: 1111111111111111111111111111111111111111 # frozen: v1.0.0
    hooks:
      - id: current
  - repo: https://example.invalid/updated
    rev: 2222222222222222222222222222222222222222 # frozen: v2.0.0
    hooks:
      - id: updated
  - repo: https://example.invalid/downgraded
    rev: 3333333333333333333333333333333333333333 # frozen: v3.1.0
    hooks:
      - id: downgraded
EOF
  cat > "$DEV_PROJECT/pre-commit.candidate.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/current
    rev: 1111111111111111111111111111111111111111 # frozen: v1.0.0
    hooks:
      - id: current
  - repo: https://example.invalid/updated
    rev: 4444444444444444444444444444444444444444 # frozen: v2.1.0
    hooks:
      - id: updated
  - repo: https://example.invalid/downgraded
    rev: 5555555555555555555555555555555555555555 # frozen: v3.0.0
    hooks:
      - id: downgraded
EOF

  run run_zsh '
    _dev_precommit_sanitize_plan \
      "$DEV_PROJECT/pre-commit.original.yaml" \
      "$DEV_PROJECT/pre-commit.candidate.yaml"
  '

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'current\thttps://example.invalid/current\tv1.0.0\tv1.0.0\t-' ]
  [ "${lines[1]}" = $'updated\thttps://example.invalid/updated\tv2.0.0\tv2.1.0\t-' ]
  [ "${lines[2]}" = $'kept\thttps://example.invalid/downgraded\tv3.1.0\tv3.1.0\tv3.0.0: version downgrade' ]
  grep -q '3333333333333333333333333333333333333333 # frozen: v3.1.0' \
    "$DEV_PROJECT/pre-commit.candidate.yaml"
}

@test "dev output: the installed hook types come from a flow-style default list" {
  printf 'default_install_hook_types: [pre-commit, commit-msg, pre-push]\nrepos: []\n' \
    > "$DEV_PROJECT/flow.yaml"
  printf 'repos: []\n' > "$DEV_PROJECT/default.yaml"
  printf 'default_install_hook_types:\n  - pre-commit\n' > "$DEV_PROJECT/block.yaml"

  run run_zsh '
    _dev_precommit_hook_types "$DEV_PROJECT/flow.yaml"; print -r -- "flow:$REPLY"
    _dev_precommit_hook_types "$DEV_PROJECT/default.yaml"; print -r -- "default:$REPLY"
    _dev_precommit_hook_types "$DEV_PROJECT/block.yaml"; print -r -- "block:$REPLY"
  '

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "flow:pre-commit, commit-msg, pre-push" ]
  [ "${lines[1]}" = "default:pre-commit" ]
  [ "${lines[2]}" = "block:" ]
}

@test "dev output: a delegated toolchain step keeps the System owner's result" {
  run run_zsh '
    sys-menu() {
      [[ "$1" == "update-uv-system" ]] || return 97
      _sys_report_result current "0.12.22" "uv is already up to date (0.12.22)."
    }
    local -a reply=()
    _dev_step_exec dev-update-toolchain || return 1
    print -r -- "RESULT:${reply[1]}:${reply[2]}"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT:current:0.12.22"* ]]
  [[ "$output" != *"Host toolchain maintenance completed"* ]]
  [[ "$output" != *"Ambient Python and pip were left unchanged"* ]]
}

@test "dev output: full maintenance verbose mode adds policy notes" {
  run run_zsh '
    cd "$DEV_PROJECT"
    sys-menu() { return 0; }
    dev-clean-all() { return 0; }
    dev-update-all --yes --verbose
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Ambient Python and pip were left unchanged"* ]]
  [[ "$output" == *"Full maintenance completed: "*" succeeded."* ]]

  run run_zsh '
    cd "$DEV_PROJECT"
    sys-menu() { return 0; }
    dev-clean-all() { return 0; }
    dev-update-all --yes
  '

  [ "$status" -eq 0 ]
  [[ "$output" != *"Ambient Python and pip were left unchanged"* ]]
}
