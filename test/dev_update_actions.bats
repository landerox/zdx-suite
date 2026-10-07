#!/usr/bin/env bats
# Quoted programs execute in Zsh; each BATS test owns its exported mock state.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  REAL_GIT=$(command -v git)
  export REAL_GIT
  export DEV_PROJECT="$HOME/project"
  export ACTIONS_LOG="$TEST_TEMP_DIR/actions.log"
  export ACTIONS_TAGS="$TEST_TEMP_DIR/tags"
  export ACTIONS_GH="$TEST_TEMP_DIR/gh"
  # gh and the validators are absent unless a test exposes its mock; the host
  # may have real ones.
  export HIDE_COMMANDS="gh actionlint zizmor"
  mkdir -p "$DEV_PROJECT/.github/workflows" "$ACTIONS_TAGS" "$ACTIONS_GH"
  : > "$ACTIONS_LOG"
  write_git_mock
  write_gh_mock
  write_tag_fixtures
}

teardown() {
  cleanup_sandbox
}

# A 40-hex object ID made of digits, distinct per number.
sha() { printf '%040d' "$1"; }

write_git_mock() {
  cat > "$TEST_MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="$arg"; done
case " $* " in
  *" ls-remote "*)
    printf 'ls-remote:%s\n' "$*" >> "$ACTIONS_LOG"
    printf 'env:%s:%s:%s\n' "${GIT_TERMINAL_PROMPT-unset}" \
      "${GIT_ASKPASS-unset}" "${GIT_HTTP_LOW_SPEED_LIMIT-unset}" \
      >> "$ACTIONS_LOG"
    name="${last#https://github.com/}"
    file="$ACTIONS_TAGS/${name//\//__}"
    if [[ -f "$file.status" ]]; then
      echo "fatal: unable to access '$last': Could not resolve host: github.com" >&2
      exit "$(cat "$file.status")"
    fi
    [[ -f "$file" ]] || { echo "remote: Repository not found." >&2; exit 128; }
    cat "$file"
    exit 0
    ;;
esac
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$TEST_MOCK_BIN/git"
}

write_gh_mock() {
  cat > "$TEST_MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh:%s\n' "$*" >> "$ACTIONS_LOG"
case "${1:-}" in
  auth) exit "${GH_AUTH_STATUS:-0}" ;;
  api)
    endpoint=""
    for arg in "$@"; do
      case "$arg" in repos/*) endpoint="$arg" ;; esac
    done
    file="$ACTIONS_GH/${endpoint//\//__}"
    [[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$file"
    exit 0
    ;;
esac
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/gh"
}

write_tag_fixtures() {
  # actions/checkout: lightweight and annotated tags, a moving major tag, a
  # newer major, a prerelease, and a non-version tag.
  {
    printf '%s\trefs/tags/v4.1.0\n' "$(sha 410)"
    printf '%s\trefs/tags/v4.2.2\n' "$(sha 422)"
    printf '%s\trefs/tags/v4.3.0\n' "$(sha 9430)"
    printf '%s\trefs/tags/v4.3.0^{}\n' "$(sha 430)"
    printf '%s\trefs/tags/v4\n' "$(sha 430)"
    printf '%s\trefs/tags/v5.0.0\n' "$(sha 500)"
    printf '%s\trefs/tags/v5.1.0-rc.1\n' "$(sha 510)"
    printf '%s\trefs/tags/latest\n' "$(sha 999)"
  } > "$ACTIONS_TAGS/actions__checkout"
  # owner2/tool publishes bare X.Y.Z tags.
  {
    printf '%s\trefs/tags/1.2.0\n' "$(sha 1200)"
    printf '%s\trefs/tags/1.2.1\n' "$(sha 1210)"
    printf '%s\trefs/tags/1.3.0\n' "$(sha 1300)"
  } > "$ACTIONS_TAGS/owner2__tool"
  {
    printf '%s\trefs/tags/v2.0.0\n' "$(sha 2000)"
    printf '%s\trefs/tags/v2.1.0\n' "$(sha 2100)"
  } > "$ACTIONS_TAGS/org__shared"
}

write_ci_workflow() {
  cat > "$DEV_PROJECT/.github/workflows/ci.yml" <<EOF
name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$(sha 410) # v4.1.0
      - uses: owner2/tool@1.2.0
      - name: Local action
        uses: ./.github/actions/setup
      - uses: docker://alpine:3.20
      - run: |
          echo "uses: actions/checkout@v1"
          uses: actions/checkout@v4

          - uses: owner2/tool@1.2.1
  shared:
    uses: org/shared/.github/workflows/build.yml@main
EOF
}

# Epoch seconds <days> ago, for release-age fixtures.
days_ago() { echo $(( $(date +%s) - $1 * 86400 )); }

gh_release() {
  local owner_repo="$1" tag_name="$2" epoch="$3"
  printf '%s\n' "$epoch" \
    > "$ACTIONS_GH/repos__${owner_repo//\//__}__releases__tags__${tag_name}"
}

# Runs Zsh in the project with selected commands hidden from capability
# probes (HIDE_COMMANDS), so host tools never leak into a test.
run_actions() {
  run run_zsh '
    cd "$DEV_PROJECT" || return 1
    functions[_dev_have_command_real]="${functions[_dev_have_command]}"
    _dev_have_command() {
      [[ " ${HIDE_COMMANDS:-} " == *" ${1:-} "* ]] && return 1
      _dev_have_command_real "$@"
    }
    '"$1"'
  '
}

ls_remote_count() {
  grep -c '^ls-remote:' "$ACTIONS_LOG" || true
}

# --- Grammar ----------------------------------------------------------------

@test "dev actions: help and invalid arguments never reach the network" {
  write_ci_workflow
  run_actions 'dev-update-actions --help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: dev-update-actions [--dry-run] [--yes] [--major]"* ]]

  run_actions 'dev-menu dev-update-actions --bogus'
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --bogus"* ]]

  export DEV_ACTIONS_COOLDOWN_DAYS=91
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEV_ACTIONS_COOLDOWN_DAYS must be an integer from 0 through 90."* ]]

  export DEV_ACTIONS_COOLDOWN_DAYS=7d
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 1 ]

  [ ! -s "$ACTIONS_LOG" ]
}

@test "dev actions: a project without workflows is skipped without probes" {
  rm -rf "$DEV_PROJECT/.github"
  export HIDE_COMMANDS="git actionlint zizmor"
  run_actions 'dev-update-actions'
  [ "$status" -eq 0 ]
  [[ "$output" == *"No GitHub Actions workflows found"* ]]
  [ ! -s "$ACTIONS_LOG" ]
}

@test "dev actions: a symlinked workflow directory is refused" {
  rm -rf "$DEV_PROJECT/.github/workflows"
  mkdir -p "$TEST_TEMP_DIR/elsewhere"
  ln -s "$TEST_TEMP_DIR/elsewhere" "$DEV_PROJECT/.github/workflows"
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing a symlinked or non-directory .github/workflows"* ]]
  [ ! -s "$ACTIONS_LOG" ]
}

# --- Discovery and parsing ----------------------------------------------------

@test "dev actions: discovery covers odd workflow names and nested composite actions" {
  mkdir -p "$DEV_PROJECT/.github/actions/setup/inner"
  printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n' \
    > "$DEV_PROJECT/.github/workflows/Release Pipeline.yaml"
  printf 'jobs:\n  a:\n    steps:\n      - uses: owner2/tool@1.2.0\n' \
    > "$DEV_PROJECT/.github/workflows/.hidden.yml"
  printf 'runs:\n  using: composite\n  steps:\n    - uses: org/shared@v2.0.0\n' \
    > "$DEV_PROJECT/.github/actions/setup/inner/action.yaml"
  # Neither a non-workflow extension nor a symlinked workflow is read.
  printf 'jobs:\n  a:\n    steps:\n      - uses: never/read@v1\n' \
    > "$DEV_PROJECT/.github/workflows/notes.txt"
  printf 'jobs:\n  a:\n    steps:\n      - uses: never/linked@v1\n' \
    > "$TEST_TEMP_DIR/outside.yml"
  ln -s "$TEST_TEMP_DIR/outside.yml" "$DEV_PROJECT/.github/workflows/linked.yml"

  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scanning 2 workflow files and 1 composite action"* ]]
  [[ "$output" == *"workflows/Release Pipeline.yaml"* ]]
  [[ "$output" == *"workflows/.hidden.yml"* ]]
  [[ "$output" == *"actions/setup/inner/action.yaml"* ]]
  [[ "$output" == *"Dry run: 3 action references planned; nothing was changed."* ]]
  if grep -q 'never/' "$ACTIONS_LOG"; then return 1; fi
}

@test "dev actions: the plan covers pinned, tag, branch, reusable, local, and Docker references" {
  write_ci_workflow
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq \
    '^  1  actions/checkout +v4[.]1[.]0 +v4[.]3[.]0 +minor +workflows/ci[.]yml$'
  printf '%s\n' "$output" | grep -Eq \
    '^  2  owner2/tool +1[.]2[.]0 +1[.]3[.]0 +pin +workflows/ci[.]yml$'
  printf '%s\n' "$output" | grep -Eq \
    '^  3  org/shared/[.]github/workflows/build[.]yml +main +v2[.]1[.]0 +pin '
  printf '%s\n' "$output" | grep -Eq \
    '^  [.]/[.]github/actions/setup +- +⊘ skipped +local action'
  printf '%s\n' "$output" | grep -Eq \
    '^  docker://alpine:3[.]20 +- +⊘ skipped +Docker image'
  # Text inside a block scalar, even after a blank line, is not a reference.
  [[ "$output" == *"Dry run: 3 action references planned; nothing was changed."* ]]
  [[ "$output" != *"1.2.1"* ]]
  [[ "$output" == *"Release ages were not checked"* ]]
  [ "$(grep -c 'Release ages were not checked' <<<"$output")" -eq 1 ]
  [ "$(ls_remote_count)" -eq 3 ]
}

@test "dev actions: the release with an annotated tag is pinned to its peeled commit" {
  write_ci_workflow
  run_actions '_dev_confirm() { return 0; }; dev-update-actions'
  [ "$status" -eq 0 ]
  grep -Fq "actions/checkout@$(sha 430) # v4.3.0" \
    "$DEV_PROJECT/.github/workflows/ci.yml"
  if grep -Fq "$(sha 9430)" "$DEV_PROJECT/.github/workflows/ci.yml"; then
    return 1
  fi
  grep -Fq "owner2/tool@$(sha 1300) # 1.3.0" \
    "$DEV_PROJECT/.github/workflows/ci.yml"
  grep -Fq "org/shared/.github/workflows/build.yml@$(sha 2100) # v2.1.0" \
    "$DEV_PROJECT/.github/workflows/ci.yml"
  grep -Fq 'uses: ./.github/actions/setup' "$DEV_PROJECT/.github/workflows/ci.yml"
  grep -Fq 'uses: docker://alpine:3.20' "$DEV_PROJECT/.github/workflows/ci.yml"
  grep -Fxq '          uses: actions/checkout@v4' \
    "$DEV_PROJECT/.github/workflows/ci.yml"
  grep -Fxq '          - uses: owner2/tool@1.2.1' \
    "$DEV_PROJECT/.github/workflows/ci.yml"
  [[ "$output" == *"GitHub Actions update completed: 3 action references updated."* ]]
}

@test "dev actions: a SHA without a comment is identified by its tag and the tag object also matches" {
  cat > "$DEV_PROJECT/.github/workflows/pins.yml" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$(sha 422)
      - uses: actions/checkout@$(sha 9430) # v4.3.0
      - uses: actions/checkout@$(sha 777) # v4.2.2
      - uses: actions/checkout@$(sha 778)
      - uses: actions/checkout@abc1234
EOF
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq \
    '^  1  actions/checkout +v4[.]2[.]2 +v4[.]3[.]0 +minor '
  [[ "$output" == *"pinned SHA does not match v4.2.2"* ]]
  [[ "$output" == *"pinned SHA matches no release tag and has no version comment"* ]]
  [[ "$output" == *"abbreviated commit SHA is not resolved"* ]]
  # The tag-object pin at v4.3.0 is already the newest allowed release.
  [[ "$output" == *"1 action reference already at the newest allowed release."* ]]
}

# --- Version selection -----------------------------------------------------

@test "dev actions: updates stay in the major version unless --major is given" {
  cat > "$DEV_PROJECT/.github/workflows/ci.yml" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$(sha 422) # v4.2.2
EOF
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  1  actions/checkout +v4[.]2[.]2 +v4[.]3[.]0 +minor '
  [[ "$output" == *"v5.0.0 needs --major"* ]]

  run_actions 'dev-update-actions --dry-run --major'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  1  actions/checkout +v4[.]2[.]2 +v5[.]0[.]0 +major '
  # The prerelease above v5.0.0 is never selected.
  [[ "$output" != *"v5.1.0"* ]]
}

@test "dev actions: a patch release is a patch and nothing is ever downgraded" {
  {
    printf '%s\trefs/tags/v1.0.0\n' "$(sha 100)"
    printf '%s\trefs/tags/v1.0.1\n' "$(sha 101)"
    printf '%s\trefs/tags/v1.1.0-beta.1\n' "$(sha 111)"
  } > "$ACTIONS_TAGS/acme__patch"
  cat > "$DEV_PROJECT/.github/workflows/ci.yml" <<EOF
jobs:
  a:
    steps:
      - uses: acme/patch@$(sha 100) # v1.0.0
      - uses: actions/checkout@$(sha 500) # v5.0.0
      - uses: actions/checkout@v6
      - uses: actions/checkout@v4.3.0
      - uses: actions/checkout@v5.1.0-rc.1
EOF
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  1  acme/patch +v1[.]0[.]0 +v1[.]0[.]1 +patch '
  printf '%s\n' "$output" | grep -Eq '^  2  actions/checkout +v4[.]3[.]0 +v4[.]3[.]0 +pin '
  [[ "$output" == *"no stable release matches v6"* ]]
  printf '%s\n' "$output" | grep -Eq \
    '^  actions/checkout +v5[.]1[.]0-rc[.]1 +⊘ skipped +prerelease reference is kept '
  [[ "$output" != *"v1.1.0-beta.1"* ]]
  [[ "$output" == *"1 action reference already at the newest allowed release."* ]]
}

# --- Release-age cooldown ----------------------------------------------------

@test "dev actions: an authenticated gh holds back releases inside the cooldown" {
  cat > "$DEV_PROJECT/.github/workflows/ci.yml" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$(sha 410) # v4.1.0
EOF
  export HIDE_COMMANDS="actionlint zizmor"
  gh_release actions/checkout v4.3.0 "$(days_ago 2)"
  # v4.2.2 has no release object; its tag commit date is used instead.
  printf '%s\n' "$(days_ago 40)" \
    > "$ACTIONS_GH/repos__actions__checkout__commits__$(sha 422)"
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  1  actions/checkout +v4[.]1[.]0 +v4[.]2[.]2 +minor '
  [[ "$output" == *"v4.3.0 is 2 days old; cooldown is 7 days"* ]]
  [[ "$output" != *"Release ages were not checked"* ]]
  grep -q '^gh:auth status --hostname github.com$' "$ACTIONS_LOG"
  grep -q '^gh:api --hostname github.com repos/actions/checkout/releases/tags/v4.3.0 ' "$ACTIONS_LOG"

  export DEV_ACTIONS_COOLDOWN_DAYS=1
  : > "$ACTIONS_LOG"
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  1  actions/checkout +v4[.]1[.]0 +v4[.]3[.]0 +minor '

  export DEV_ACTIONS_COOLDOWN_DAYS=0
  : > "$ACTIONS_LOG"
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  if grep -q '^gh:' "$ACTIONS_LOG"; then return 1; fi
}

@test "dev actions: without gh the cooldown is reported once and not applied" {
  cat > "$DEV_PROJECT/.github/workflows/ci.yml" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$(sha 410) # v4.1.0
      - uses: owner2/tool@$(sha 1200) # 1.2.0
EOF
  export HIDE_COMMANDS="actionlint zizmor" GH_AUTH_STATUS=1
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Release ages were not checked' <<<"$output")" -eq 1 ]
  printf '%s\n' "$output" | grep -Eq '^  1  actions/checkout +v4[.]1[.]0 +v4[.]3[.]0 +minor '
  if grep -q '^gh:api' "$ACTIONS_LOG"; then return 1; fi

  export HIDE_COMMANDS="gh actionlint zizmor"
  : > "$ACTIONS_LOG"
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Release ages were not checked' <<<"$output")" -eq 1 ]
  if grep -q '^gh:' "$ACTIONS_LOG"; then return 1; fi
}

@test "dev actions: an unreadable release age fails that action closed" {
  cat > "$DEV_PROJECT/.github/workflows/ci.yml" <<EOF
jobs:
  a:
    steps:
      - uses: actions/checkout@$(sha 410) # v4.1.0
EOF
  export HIDE_COMMANDS="actionlint zizmor"
  local before
  before=$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")
  run_actions 'dev-update-actions --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"release age of v4.3.0 could not be checked"* ]]
  [[ "$output" == *"GitHub Actions update failed: 1 of 1 action reference failed."* ]]
  [ "$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")" = "$before" ]
}

# --- Authorization and publication ------------------------------------------

@test "dev actions: a dry run changes nothing and creates no backup" {
  write_ci_workflow
  export HIDE_COMMANDS="gh actionlint zizmor"
  local before
  before=$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")
  run_actions '_dev_confirm() { print -u2 -- CONFIRM_CALLED; return 0; }
    dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: 3 action references planned; nothing was changed."* ]]
  [[ "$output" != *"CONFIRM_CALLED"* ]]
  [ "$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")" = "$before" ]
  [ ! -e "$DEV_PROJECT/.dev-suite-backups" ]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "dev actions: a declined or unavailable confirmation changes nothing" {
  write_ci_workflow
  export HIDE_COMMANDS="gh actionlint zizmor"
  local before
  before=$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")
  run_actions '_dev_confirm() { return 1; }; dev-update-actions'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled: nothing was changed."* ]]
  [ "$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")" = "$before" ]

  run_actions 'dev-update-actions'
  [ "$status" -eq 1 ]
  [[ "$output" == *"pass --yes in a non-interactive shell"* ]]
  [ "$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")" = "$before" ]
  [ ! -e "$DEV_PROJECT/.dev-suite-backups" ]
}

@test "dev actions: --yes backs up each changed file before atomic publication" {
  write_ci_workflow
  cp "$DEV_PROJECT/.github/workflows/ci.yml" "$TEST_TEMP_DIR/ci.original"
  chmod 640 "$DEV_PROJECT/.github/workflows/ci.yml"
  run_actions 'dev-update-actions --yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflows/ci.yml: 3 references updated"* ]]
  [ "$(file_mode "$DEV_PROJECT/.github/workflows/ci.yml")" = 640 ]
  local backup
  backup=$(find "$DEV_PROJECT/.dev-suite-backups" -type f \
    -name 'github%workflows%ci.yml.*.bak')
  [ -n "$backup" ]
  [ "$(file_mode "$backup")" = 600 ]
  cmp -s "$backup" "$TEST_TEMP_DIR/ci.original"
  [ "$(file_mode "$DEV_PROJECT/.dev-suite-backups")" = 700 ]
}

@test "dev actions: formatting outside the reference and its comment is preserved byte for byte" {
  {
    printf '%s\r\n' \
      'steps:' \
      "  - uses:   'actions/checkout@$(sha 410)'   #   v4.1.0 (pinned by hand)"
    printf '  - uses: "owner2/tool@1.2.0"\t\r\n'
    printf '%s\r\n' \
      "  - uses: actions/checkout@$(sha 410) # keep: reviewed" \
      '  # uses: actions/checkout@v1 is only a comment' \
      '  - name: "Ünïcode ✓"'
    printf '  - uses: actions/checkout@v4'
  } > "$DEV_PROJECT/.github/workflows/crlf.yml"

  {
    printf '%s\r\n' \
      'steps:' \
      "  - uses:   'actions/checkout@$(sha 430)'   #   v4.3.0 (pinned by hand)"
    printf '  - uses: "owner2/tool@%s"\t# 1.3.0\r\n' "$(sha 1300)"
    printf '%s\r\n' \
      "  - uses: actions/checkout@$(sha 430) # v4.3.0 # keep: reviewed" \
      '  # uses: actions/checkout@v1 is only a comment' \
      '  - name: "Ünïcode ✓"'
    printf '  - uses: actions/checkout@%s # v4.3.0' "$(sha 430)"
  } > "$TEST_TEMP_DIR/expected.yml"

  run_actions 'dev-update-actions --yes'
  [ "$status" -eq 0 ]
  cmp "$DEV_PROJECT/.github/workflows/crlf.yml" "$TEST_TEMP_DIR/expected.yml"
}

# --- Validation and rollback -------------------------------------------------

write_validator() {
  local tool_name="$1" behavior="$2"
  cat > "$TEST_MOCK_BIN/$tool_name" <<EOF
#!/usr/bin/env bash
printf '$tool_name:%s\n' "\$*" >> "\$ACTIONS_LOG"
case "$behavior" in
  always) echo "finding: existing problem"; exit 13 ;;
  new-sha)
    for arg in "\$@"; do
      if [[ -f "\$arg" ]] && grep -q '$(sha 430)' "\$arg"; then
        echo "\$arg:7:9: input \"ref\" is not defined in the updated action"
        exit 1
      fi
    done
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$TEST_MOCK_BIN/$tool_name"
}

@test "dev actions: a validator that fails only after the update rolls every file back" {
  write_ci_workflow
  mkdir -p "$DEV_PROJECT/.github/actions/setup"
  printf 'runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@v4.1.0\n' \
    > "$DEV_PROJECT/.github/actions/setup/action.yml"
  local ci_before action_before
  ci_before=$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")
  action_before=$(sha256_file "$DEV_PROJECT/.github/actions/setup/action.yml")
  write_validator actionlint new-sha
  export HIDE_COMMANDS="gh zizmor"
  run_actions 'dev-update-actions --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not defined in the updated action"* ]]
  [[ "$output" == *"actionlint failed on the updated files; restoring the originals."* ]]
  [[ "$output" == *"zizmor is not installed; its validation was skipped."* ]]
  [ "$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")" = "$ci_before" ]
  [ "$(sha256_file "$DEV_PROJECT/.github/actions/setup/action.yml")" = "$action_before" ]
  # actionlint lints workflows only; composite action files are not passed.
  if grep '^actionlint:' "$ACTIONS_LOG" | grep -q 'action.yml'; then
    return 1
  fi
  grep -q '^actionlint:-no-color -- .github/workflows/ci.yml$' "$ACTIONS_LOG"
  [ -n "$(find "$DEV_PROJECT/.dev-suite-backups" -name '*.bak' -print -quit)" ]
}

@test "dev actions: findings that the original files already had keep the update" {
  write_ci_workflow
  write_validator zizmor always
  export HIDE_COMMANDS="gh actionlint"
  run_actions 'dev-update-actions --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"zizmor reported findings that the original files already had; the update was kept."* ]]
  grep -Fq "actions/checkout@$(sha 430) # v4.3.0" \
    "$DEV_PROJECT/.github/workflows/ci.yml"
  grep -q '^zizmor:--offline -- .github/workflows/ci.yml$' "$ACTIONS_LOG"
}

@test "dev actions: a failed publication restores the files already published" {
  write_ci_workflow
  printf 'jobs:\n  a:\n    steps:\n      - uses: owner2/tool@1.2.0\n' \
    > "$DEV_PROJECT/.github/workflows/zz-second.yml"
  local ci_before second_before
  ci_before=$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")
  second_before=$(sha256_file "$DEV_PROJECT/.github/workflows/zz-second.yml")
  run_actions '
    functions[_dev_update_publish_snapshot_real]="${functions[_dev_update_publish_snapshot]}"
    _dev_update_publish_snapshot() {
      [[ "$1" == */candidate.* && "$2" == */zz-second.yml ]] && return 1
      _dev_update_publish_snapshot_real "$@"
    }
    dev-update-actions --yes
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"workflows/ci.yml: 3 references updated"* ]]
  [[ "$output" == *"Could not publish .github/workflows/zz-second.yml atomically."* ]]
  [[ "$output" == *"Restored workflows/ci.yml."* ]]
  [ "$(sha256_file "$DEV_PROJECT/.github/workflows/ci.yml")" = "$ci_before" ]
  [ "$(sha256_file "$DEV_PROJECT/.github/workflows/zz-second.yml")" = "$second_before" ]
}

# --- Network failures and refused input ---------------------------------------

@test "dev actions: one failed tag query is reported without blocking the other actions" {
  write_ci_workflow
  printf '128\n' > "$ACTIONS_TAGS/owner2__tool.status"
  run_actions 'dev-update-actions --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not list the tags of owner2/tool (status 128)."* ]]
  [[ "$output" == *"Could not resolve host: github.com"* ]]
  [[ "$output" == *"tag query failed (status 128)"* ]]
  [[ "$output" == *"completed with partial failures: 1 of 5 action references failed."* ]]
  [[ "$output" == *"Retry after resolving the errors above: dev-menu dev-update-actions"* ]]
  grep -Fq "actions/checkout@$(sha 430) # v4.3.0" \
    "$DEV_PROJECT/.github/workflows/ci.yml"
  grep -Fq 'owner2/tool@1.2.0' "$DEV_PROJECT/.github/workflows/ci.yml"
}

@test "dev actions: a timed-out query stops later batches" {
  write_ci_workflow
  printf '124\n' > "$ACTIONS_TAGS/actions__checkout.status"
  run_actions '_DEV_ACTIONS_JOBS=1; dev-update-actions --dry-run'
  [ "$status" -eq 1 ]
  [ "$(ls_remote_count)" -eq 1 ]
  [[ "$output" == *"tag query timed out"* ]]
  [[ "$output" == *"not queried after a github.com timeout"* ]]
}

@test "dev actions: tag queries use HTTPS only without credentials or prompts" {
  write_ci_workflow
  run_actions 'dev-update-actions --dry-run'
  [ "$status" -eq 0 ]
  grep -Fxq 'ls-remote:-c credential.helper= -c core.askPass= -c protocol.allow=never -c protocol.https.allow=always ls-remote --tags -- https://github.com/actions/checkout' "$ACTIONS_LOG"
  [ "$(grep -c '^env:0::1$' "$ACTIONS_LOG")" -eq 3 ]
}

@test "dev actions: invalid owner, repository, path, or ref values are refused before any query" {
  cat > "$DEV_PROJECT/.github/workflows/bad.yml" <<'EOF'
jobs:
  a:
    steps:
      - uses: -evil/repo@v1
      - uses: owner/repo@v1;id
      - uses: owner/../repo@v1
      - uses: owner/repo@$(id)
      - uses: owner/repo
      - uses: owner/repo/../../x@v1
      - uses: owner/re po@v1
EOF
  run_actions 'dev-update-actions --yes'
  [ "$status" -eq 0 ]
  [ "$(ls_remote_count)" -eq 0 ]
  [ "$(grep -c 'invalid reference; not queried' <<<"$output")" -eq 7 ]
  [[ "$output" == *"No action reference needs an update."* ]]
  [ ! -e "$DEV_PROJECT/.dev-suite-backups" ]
}

# --- Full maintenance --------------------------------------------------------

@test "dev actions: full maintenance lists the step as not applicable without workflows" {
  rm -rf "$DEV_PROJECT/.github"
  run_actions '
    _dev_delegate_sys() { return 0; }
    dev-update-actions() { print -r -- "UNEXPECTED_ACTIONS"; }
    dev-clean-all() { return 0; }
    dev-update-all --yes
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNEXPECTED_ACTIONS"* ]]
  printf '%s\n' "$output" | grep -Eq \
    '^  ⊘  GitHub Actions +not applicable [(]no [.]github/workflows[)]$'
  printf '%s\n' "$output" | grep -Eq \
    '^  GitHub Actions +⊘ skipped +no [.]github/workflows$'
}

@test "dev actions: full maintenance runs the step after the hooks with aggregate authorization" {
  write_ci_workflow
  printf '[project]\nname = "demo"\n' > "$DEV_PROJECT/pyproject.toml"
  : > "$DEV_PROJECT/.pre-commit-config.yaml"
  run_actions '
    _dev_pypi_check_connectivity() { return 0; }
    _dev_delegate_sys() { print -r -- "STEP:toolchain"; }
    dev-update-deps() { print -r -- "STEP:deps"; }
    dev-update-precommit() { print -r -- "STEP:precommit"; }
    dev-update-actions() {
      print -r -- "STEP:actions:$*"
      _dev_report_result updated "3 action references" "unused"
    }
    dev-update-terraform() { return 0; }
    dev-update-tflint() { return 0; }
    dev-clean-all() { print -r -- "STEP:clean"; }
    dev-update-all --yes
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq \
    '^  [0-9]  GitHub Actions +Pin workflow actions to newer release SHAs in the current major[.]$'
  [[ "$output" == *"STEP:precommit"*"STEP:actions:--yes"*"STEP:clean"* ]]
  [[ "$output" == *"GitHub Actions — updated: 3 action references"* ]]
}

@test "dev actions: full maintenance reports the real step result and previews it in a dry run" {
  write_ci_workflow
  run_actions '
    _dev_delegate_sys() { return 0; }
    dev-clean-all() { return 0; }
    dev-update-all --yes
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub Actions — updated: 3 action references (actions/checkout v4.1.0 → v4.3.0"* ]]
  printf '%s\n' "$output" | grep -Eq '^  GitHub Actions +✔ updated '
  grep -Fq "owner2/tool@$(sha 1300) # 1.3.0" \
    "$DEV_PROJECT/.github/workflows/ci.yml"

  write_ci_workflow
  run_actions '
    dev-update-deps() { print -r -- "UNEXPECTED_DEPS"; }
    dev-clean-all() { return 0; }
    dev-update-all --dry-run
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNEXPECTED_DEPS"* ]]
  [[ "$output" == *"GitHub Actions preview — planned: 3 action references"* ]]
  grep -Fq 'owner2/tool@1.2.0' "$DEV_PROJECT/.github/workflows/ci.yml"
}

# --- Public surface ----------------------------------------------------------

@test "dev actions: menu, dependencies, batch eligibility, and completion agree" {
  export HIDE_COMMANDS="git"
  run_actions '
    _dev_menu_rows | grep -F "|dev-update-actions|" || return 1
    _dev_menu_batch_rows | grep -F "dev-update-actions" && return 2
    _dev_command_batch_safe dev-update-actions && return 3
    _dev_cmd_deps dev-update-actions reply
    [[ "$REPLY" == git ]] || return 4
    return 0
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"○ Update GitHub Actions (missing: git)|dev-update-actions|"* ]]

  local completion="$TEST_SUITE_ROOT/completions/_dev-menu"
  run env COMPLETION="$completion" zsh -f -c '
    typeset -a words=(dev-update-actions)
    _arguments() { print -rl -- "$@"; }
    source "$COMPLETION"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run[Show the planned action updates without writing]"* ]]
  [[ "$output" == *"--major[Also allow newer major versions]"* ]]
  [[ "$output" == *"--yes[Confirm the action updates]"* ]]
  [[ "$output" == *"--help[Show command usage]"* ]]
}
