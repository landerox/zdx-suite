#!/usr/bin/env bats
# Public Actions updates distinguish reference positions from nested input data.
# shellcheck disable=SC2016

setup() {
  load test_helper
  unset "${!F515A_@}" _DEV_RUN_PYTHON _DEV_PREVIEW_EXEC_TRUST
  _zdx_test_dev_preview_private_python || return 1
  export F515A_ROOT="$HOME/f515-actions"
  export F515A_LEAF="$F515A_ROOT/tag-leaf"
  export DEV_ACTIONS_COOLDOWN_DAYS=0 DEV_ACTIONS_TIMEOUT=3
  mkdir -m 700 "$F515A_ROOT" || return 1

  f515a_script "$F515A_LEAF" <<'BASH' || return 1
[[ $# == 2 && ( "$1" == real || "$1" == decoy ) \
  && ( "$2" == 0 || "$2" == 17 ) ]] || exit 97
dir="$F515A_SCENE/queries/$1"
printf '%s\0' "$0" "$@" > "$dir/leaf.argv.nul" || exit 98
printf '%040d\trefs/tags/v1.0.0\n%040d\trefs/tags/v1.1.0\n' 100 110
[[ "$2" != 17 ]] || printf 'FINITE_TAG_QUERY_FAILURE\n' >&2
exit "$2"
BASH

  f515a_script "$TEST_MOCK_BIN/git" <<'BASH' || return 1
[[ $# == 15 ]] || exit 97
case "${15}" in
  https://github.com/org/real) key=real ;;
  https://github.com/decoy/input) key=decoy ;;
  *) exit 97 ;;
esac
dir="$F515A_SCENE/queries/$key"
# One query per repository per public action; duplicates cannot overwrite evidence.
mkdir -m 700 "$dir" || exit 98
printf '%s\0' "$0" "$@" > "$dir/argv.nul" || exit 98
printf '%s\n' "$PWD" > "$dir/cwd" || exit 98
printf '%s\0' "$HOME" "${XDG_CONFIG_HOME-}" \
  "${GIT_CONFIG_NOSYSTEM-}" "${GIT_CONFIG_SYSTEM-}" \
  "${GIT_CONFIG_GLOBAL-}" "${GIT_TERMINAL_PROMPT-}" \
  "${GIT_ASKPASS-unset}" "${GCM_INTERACTIVE-}" \
  "${GIT_HTTP_LOW_SPEED_LIMIT-}" "${GIT_HTTP_LOW_SPEED_TIME-}" \
  > "$dir/environment.nul" || exit 98
input=""
if IFS= read -r -n 1 input || [[ -n "$input" ]]; then
  printf 'DATA\n' > "$dir/stdin" || exit 98
  exit 97
fi
printf 'EOF\n' > "$dir/stdin" || exit 98
"$F515A_LEAF" "$key" "$F515A_QUERY_STATUS" \
  > "$dir/producer.stdout" 2> "$dir/producer.stderr"
observed=$?
# This records the finite child's return AFTER it finished, not a configured marker.
printf '%s\n' "$observed" > "$dir/producer.status" || exit 98
cat "$dir/producer.stdout" || exit 98
cat "$dir/producer.stderr" >&2 || exit 98
exit "$observed"
BASH

  {
    printf '%s\n' 'builtin source "$TEST_SUITE_ROOT/functions/dev-menu.zsh" || return 95'
    _zdx_test_dev_preview_diagnostic_program
    cat <<'ZSH'
builtin cd -- "$F515A_SCENE/project" || return 95
functions[_f515a_have_command]="${functions[_dev_have_command]}"
_dev_have_command() {
  case "${1-}" in gh|actionlint|zizmor|uv) return 1 ;; esac
  _f515a_have_command "$@"
}
case "$F515A_MODE" in
  dry)
    _dev_confirm_ask() {
      print -r -- 'UNEXPECTED_DRY_RUN_ASK' > "$F515A_SCENE/ask.reached"
      return 17
    }
    dev-update-actions --dry-run
    ;;
  decline)
    _dev_confirm_ask() {
      print -r -- 'DECLINED' > "$F515A_SCENE/ask.reached"
      return 1
    }
    dev-update-actions
    ;;
  unavailable) dev-update-actions ;;
  apply) dev-update-actions --yes ;;
  *) return 96 ;;
esac
ZSH
  } > "$F515A_ROOT/action.zsh" || return 1
}

teardown() {
  _zdx_test_dev_preview_diagnostic_dump
  cleanup_sandbox
}

f515a_script() {
  { printf '#!%s\n' "$BASH" || return 1; cat || return 1; } > "$1" || return 1
  chmod -- 700 "$1"
}

# The reference and version parameters affect ONLY the genuine job/step rows.
# Nested data deliberately stays byte-identical even when it names that same repo.
f515a_workflow() {
  local target="$1" reference="$2" version="$3" ending="$4" line
  local -a lines=(
    'jobs:'
    '  reused:'
    "    uses: org/real/.github/workflows/reuse.yml@$reference # $version (job)"
    '    with:'
    '      uses: org/real@v1.0.0'
    '  build:'
    '    runs-on: ubuntu-latest'
    '    env:'
    '      uses: org/real@v1.0.0'
    '    steps:'
    '      - name: Genuine step'
    "        uses:   'org/real@$reference'   #   $version (step)"
    '        with:'
    '          uses: org/real@v1.0.0'
    '        env:'
    '          uses: decoy/input@v1.0.0'
    '      - name: Literal script'
    '        run: |-'
    '          uses: org/real@v1.0.0'
    ''
    '          - uses: decoy/input@v1.0.0'
    '      - name: After the scalar'
    '        run: echo finite'
    'name: context'
    'on: push'
    'env:'
    '  uses: decoy/input@v1.0.0'
  )
  {
    if [[ "$ending" == $'\r\n' ]]; then printf '\357\273\277'; fi
    for line in "${lines[@]}"; do printf '%s%s' "$line" "$ending"; done
  } > "$target"
}

f515a_composite() {
  local target="$1" reference="$2" version="$3" ending="$4" line
  local -a lines=(
    'name: private composite'
    'description: finite context fixture'
    'inputs:'
    '  uses:'
    '    description: a literal input name'
    '    default: decoy/input@v1.0.0'
    'runs:'
    '  using: composite'
    '  steps:'
    '    - shell: bash'
    '      run: >-'
    '        uses: decoy/input@v1.0.0'
    '    - name: Genuine composite step'
    "      uses: \"org/real@$reference\" # tag=$version (composite)"
    '      with:'
    '        uses: org/real@v1.0.0'
    '      env:'
    '        uses: decoy/input@v1.0.0'
  )
  for line in "${lines[@]}"; do printf '%s%s' "$line" "$ending"; done > "$target"
}

f515a_scene() {
  export F515A_SCENE="$F515A_ROOT/$1" F515A_MODE="$2" F515A_QUERY_STATUS="${4:-0}"
  local ending="$3" pinned
  printf -v pinned '%040d' 110
  mkdir -m 700 "$F515A_SCENE" || return 1
  mkdir -p "$F515A_SCENE/project/.github/workflows" \
    "$F515A_SCENE/project/.github/actions/private" \
    "$F515A_SCENE/queries" "$F515A_SCENE/original" "$F515A_SCENE/expected" || return 1
  f515a_workflow "$F515A_SCENE/project/.github/workflows/ci.yml" \
    v1.0.0 v1.0.0 "$ending" || return 1
  f515a_composite "$F515A_SCENE/project/.github/actions/private/action.yml" \
    v1.0.0 v1.0.0 "$ending" || return 1
  f515a_workflow "$F515A_SCENE/expected/workflow" \
    "$pinned" v1.1.0 "$ending" || return 1
  f515a_composite "$F515A_SCENE/expected/composite" \
    "$pinned" v1.1.0 "$ending" || return 1
  chmod -- 640 "$F515A_SCENE/project/.github/workflows/ci.yml" \
    "$F515A_SCENE/project/.github/actions/private/action.yml" || return 1
  cp "$F515A_SCENE/project/.github/workflows/ci.yml" "$F515A_SCENE/original/workflow" || return 1
  cp "$F515A_SCENE/project/.github/actions/private/action.yml" "$F515A_SCENE/original/composite" || return 1
  printf 'PROTECTED_PRIVATE_CANARY\nuses: decoy/input@v1.0.0\n' \
    > "$F515A_SCENE/project/protected.txt" || return 1
  chmod -- 600 "$F515A_SCENE/project/protected.txt" || return 1
  cp "$F515A_SCENE/project/protected.txt" "$F515A_SCENE/original/canary" || return 1
  file_identity "$F515A_SCENE/project/protected.txt" > "$F515A_SCENE/original/canary.identity"
}

f515a_launch() {
  local wrapper_status=0
  run_zsh '
    _f515a_action() { builtin source "$F515A_ROOT/action.zsh"; }
    _f515a_action > "$F515A_SCENE/primary.stdout" 2> "$F515A_SCENE/primary.stderr"
    local -i observed=$?
    print -r -- "$observed" > "$F515A_SCENE/primary.status" || return 98
    return 0
  ' > "$F515A_SCENE/wrapper.stdout" 2> "$F515A_SCENE/wrapper.stderr" || wrapper_status=$?
  printf '%s\n' "$wrapper_status" > "$F515A_SCENE/wrapper.status"
}

f515a_scalar() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  printf '%s\n' "$2" > "$F515A_ROOT/scalar.expected" || return 1
  cmp -s "$1" "$F515A_ROOT/scalar.expected"
}

f515a_primary() {
  local scene="$F515A_ROOT/$1" expected_status="$2" identity
  f515a_scalar "$scene/wrapper.status" 0 || return 1
  [[ -f "$scene/wrapper.stdout" && ! -L "$scene/wrapper.stdout" \
    && ! -s "$scene/wrapper.stdout" && -f "$scene/wrapper.stderr" \
    && ! -L "$scene/wrapper.stderr" && ! -s "$scene/wrapper.stderr" ]] || return 1
  f515a_scalar "$scene/primary.status" "$expected_status" || return 1
  [[ -f "$scene/primary.stdout" && ! -L "$scene/primary.stdout" \
    && ! -s "$scene/primary.stdout" && -f "$scene/primary.stderr" \
    && ! -L "$scene/primary.stderr" && -s "$scene/primary.stderr" ]] || return 1
  [[ -f "$scene/project/protected.txt" && ! -L "$scene/project/protected.txt" ]] || return 1
  cmp -s "$scene/project/protected.txt" "$scene/original/canary" || return 1
  identity=$(file_identity "$scene/project/protected.txt") || return 1
  f515a_scalar "$scene/original/canary.identity" "$identity" || return 1
  [[ "$(file_mode "$scene/project/protected.txt")" == 600 ]] || return 1
  [[ "$(file_mode "$scene/project/.github/workflows/ci.yml")" == 640 \
    && "$(file_mode "$scene/project/.github/actions/private/action.yml")" == 640 ]]
}

f515a_files() {
  local scene="$F515A_ROOT/$1" expected="$2"
  [[ -f "$scene/project/.github/workflows/ci.yml" \
    && ! -L "$scene/project/.github/workflows/ci.yml" \
    && -f "$scene/project/.github/actions/private/action.yml" \
    && ! -L "$scene/project/.github/actions/private/action.yml" ]] || return 1
  cmp -s "$scene/project/.github/workflows/ci.yml" "$scene/$expected/workflow" || return 1
  cmp -s "$scene/project/.github/actions/private/action.yml" "$scene/$expected/composite"
}

f515a_query() {
  local scene="$F515A_ROOT/$1" expected_status="$2" dir query_cwd entry count=0
  dir="$scene/queries/real"
  for entry in "$scene/queries/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ -d "$entry" && ! -L "$entry" && "$entry" == "$dir" ]] || return 1
    count=$((count + 1))
  done
  [[ "$count" == 1 ]] || return 1
  printf '%s\0' "$TEST_MOCK_BIN/git" --no-pager \
    -c credential.helper= -c core.askPass= -c http.extraHeader= \
    -c protocol.allow=never -c protocol.https.allow=always \
    ls-remote --tags -- https://github.com/org/real > "$scene/expected/query.argv.nul" || return 1
  [[ -f "$dir/argv.nul" && ! -L "$dir/argv.nul" ]] || return 1
  cmp -s "$dir/argv.nul" "$scene/expected/query.argv.nul" || return 1
  printf '%s\0' "$F515A_LEAF" real "$expected_status" > "$scene/expected/leaf.argv.nul" || return 1
  [[ -f "$dir/leaf.argv.nul" && ! -L "$dir/leaf.argv.nul" ]] || return 1
  cmp -s "$dir/leaf.argv.nul" "$scene/expected/leaf.argv.nul" || return 1
  f515a_scalar "$dir/producer.status" "$expected_status" || return 1
  f515a_scalar "$dir/stdin" EOF || return 1
  [[ -f "$dir/cwd" && ! -L "$dir/cwd" ]] || return 1
  IFS= read -r query_cwd < "$dir/cwd" || return 1
  [[ "$query_cwd" == "$TMPDIR/"* && "$query_cwd" != *'/../'* ]] || return 1
  printf '%s\0' "$query_cwd" "$query_cwd" 1 /dev/null /dev/null 0 '' never 1 3 \
    > "$scene/expected/environment.nul" || return 1
  [[ -f "$dir/environment.nul" && ! -L "$dir/environment.nul" ]] || return 1
  cmp -s "$dir/environment.nul" "$scene/expected/environment.nul" || return 1
  printf '%040d\trefs/tags/v1.0.0\n%040d\trefs/tags/v1.1.0\n' 100 110 \
    > "$scene/expected/tags" || return 1
  [[ -f "$dir/producer.stdout" && ! -L "$dir/producer.stdout" \
    && -f "$dir/producer.stderr" && ! -L "$dir/producer.stderr" ]] || return 1
  cmp -s "$dir/producer.stdout" "$scene/expected/tags" || return 1
  if [[ "$expected_status" == 17 ]]; then
    f515a_scalar "$dir/producer.stderr" FINITE_TAG_QUERY_FAILURE
  else
    [[ ! -s "$dir/producer.stderr" ]]
  fi
}

f515a_no_backup() {
  [[ ! -e "$F515A_ROOT/$1/project/.dev-suite-backups" \
    && ! -L "$F515A_ROOT/$1/project/.dev-suite-backups" ]]
}

@test "dev action context: public updates preserve nested data with LF and CRLF" {
  f515a_scene lf apply $'\n'
  f515a_launch
  f515a_scene crlf apply $'\r\n'
  f515a_launch

  local scene
  for scene in lf crlf; do
    f515a_primary "$scene" 0
    f515a_files "$scene" expected
    f515a_query "$scene" 0
    grep -Fq 'GitHub Actions update completed: 3 action references updated.' \
      "$F515A_ROOT/$scene/primary.stderr"
  done
}

@test "dev action context: dry run decline and unavailable keep both files unchanged" {
  f515a_scene dry dry $'\n'
  f515a_launch
  f515a_scene decline decline $'\n'
  f515a_launch
  f515a_scene unavailable unavailable $'\n'
  f515a_launch

  local scene
  for scene in dry decline unavailable; do
    if [[ "$scene" == unavailable ]]; then f515a_primary "$scene" 1
    else f515a_primary "$scene" 0; fi
    f515a_files "$scene" original
    f515a_query "$scene" 0
    f515a_no_backup "$scene"
  done
  [[ ! -e "$F515A_ROOT/dry/ask.reached" && ! -L "$F515A_ROOT/dry/ask.reached" ]]
  f515a_scalar "$F515A_ROOT/decline/ask.reached" DECLINED
  grep -Fq 'Dry run: 3 action references planned; nothing was changed.' \
    "$F515A_ROOT/dry/primary.stderr"
  grep -Fq 'Cancelled: nothing was changed.' "$F515A_ROOT/decline/primary.stderr"
  grep -Fq 'pass --yes in a non-interactive shell' "$F515A_ROOT/unavailable/primary.stderr"
}

@test "dev action context: data-only workflows and composites do not query tags" {
  f515a_scene data-only apply $'\n'
  cat > "$F515A_SCENE/project/.github/workflows/ci.yml" <<'YAML'
env:
  uses: org/real@v1.0.0
jobs:
  only:
    runs-on: ubuntu-latest
    env:
      uses: decoy/input@v1.0.0
    steps:
      - run: |
          uses: org/real@v1.0.0
YAML
  cat > "$F515A_SCENE/project/.github/actions/private/action.yml" <<'YAML'
name: data only
description: finite data-only fixture
runs:
  using: composite
  steps:
    - shell: bash
      env:
        uses: org/real@v1.0.0
      run: echo finite
YAML
  cp "$F515A_SCENE/project/.github/workflows/ci.yml" "$F515A_SCENE/original/workflow"
  cp "$F515A_SCENE/project/.github/actions/private/action.yml" "$F515A_SCENE/original/composite"
  f515a_launch

  f515a_primary data-only 0
  f515a_files data-only original
  f515a_no_backup data-only
  local entry
  for entry in "$F515A_SCENE/queries/"*; do
    [[ ! -e "$entry" && ! -L "$entry" ]]
  done
  grep -Fq 'The workflow files reference no actions.' "$F515A_SCENE/primary.stderr"
}

@test "dev action context: failed finite tag queries retain complete original files" {
  f515a_scene query-failure apply $'\n' 17
  f515a_launch

  f515a_primary query-failure 1
  f515a_files query-failure original
  f515a_query query-failure 17
  f515a_no_backup query-failure
}
