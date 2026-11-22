#!/usr/bin/env bats
# Developer-owned state discovery, current-shell consent and retained diff argv.
# All updater, linter and formatter backends are finite private fixtures.
# shellcheck disable=SC2016

setup() {
  load test_helper
  _zdx_test_dev_preview_private_python || return 1
  export F515_BASH="$BASH" F515_RESULTS="$HOME/state-prompt-results"
  export DEV_ALLOW_EPHEMERAL=0 DEV_ACTIONS_COOLDOWN_DAYS=0 NO_COLOR=1
  unset F515_CELL F515_KIND F515_OP F515_MODE F515_ASK_CODE
  unset F515_MUTATE_CONFIG F515_INITIAL_AUTO_YES DEV_REPORT_DIR DEV_BACKUP_DIR
  mkdir -m 700 "$F515_RESULTS" || return 1
  local tool
  for tool in markdownlint tflint git uv pre-commit delta bat; do
    f515_backend "$TEST_MOCK_BIN/$tool" || return 1
  done
}

teardown() {
  cleanup_sandbox
}

f515_script() {
  local target="$1"
  { printf '#!%s\n' "$BASH" || return 1; cat || return 1; } > "$target" || return 1
  chmod -- 755 "$target" || return 1
}

f515_backend() {
  f515_script "$1" <<'SH'
set -u
tool=${0##*/}
dir="$F515_CELL/receipts/$tool"
mkdir -p "$dir" || exit 96
count=0
[[ ! -f "$dir/count" ]] || read -r count < "$dir/count"
count=$((count + 1))
printf '%s\n' "$count" > "$dir/count" || exit 96
printf '%s\0' "$0" "$@" > "$dir/$count.argv" || exit 96
"$F515_BASH" "$F515_CELL/leaf.bash" "$tool" "$@"
actual=$?
# This records a returned child status, not only its configured return site.
printf '%s\n' "$actual" > "$dir/$count.producer.status" || exit 96
exit "$actual"
SH
}

f515_cell() {
  export F515_CELL="$F515_RESULTS/$1"
  mkdir -m 700 "$F515_CELL" || return 1
  mkdir -m 700 "$F515_CELL/project" "$F515_CELL/receipts" || return 1
  printf 'README.md\n.dev-suite-backups\ndev-suite-reports\n' \
    > "$F515_CELL/watch.paths" || return 1
  f515_script "$F515_CELL/leaf.bash" <<'SH' || return 1
set -u
tool=$1
shift
case "$tool" in
  markdownlint)
    fix=0
    [[ ${1:-} != --fix ]] || { fix=1; shift; }
    [[ $# -gt 0 ]] || exit 97
    for target in "$@"; do
      [[ "$target" == ./*.md && "$target" != *'/../'* \
        && -f "$target" && ! -L "$target" ]] || exit 97
      if [[ "$fix" == 1 ]]; then
        printf 'FINITE_MARKDOWN_FIX\n' >> "$target" || exit 96
      fi
    done
    printf 'FINITE_MARKDOWN_OUTPUT\n'
    ;;
  tflint)
    [[ $# == 1 && ( "$1" == --init || "$1" == --recursive ) ]] || exit 97
    printf 'FINITE_TFLINT_OUTPUT\n'
    ;;
  git)
    if [[ "$F515_KIND" == diff ]]; then
      [[ ${1:-} != --no-pager ]] || shift
      [[ $# == 4 && "$1" == diff && "$2" == --no-color \
        && "$3" == -- && "$4" == 'literal [x].toml' ]] || exit 97
      printf 'FINITE_GIT_DIFF\n'
    else
      found=0
      for argument in "$@"; do [[ "$argument" != ls-remote ]] || found=1; done
      [[ "$found" == 1 && ${!#} == https://github.com/actions/checkout ]] || exit 97
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v4.1.0\n'
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v4.2.0\n'
    fi
    ;;
  uv)
    case "${1:-}" in lock|sync) ;; *) exit 97 ;; esac
    ;;
  pre-commit)
    case "${1:-}" in
      autoupdate)
        [[ $# == 4 && "$2" == --freeze && "$3" == --config \
          && "$4" == "$TMPDIR"/zdx-dev-update.*/pre-commit-config.candidate \
          && -f "$4" && ! -L "$4" ]] || exit 97
        while IFS= read -r line || [[ -n "$line" ]]; do
          line=${line//aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}
          line=${line//# frozen: v1.0.0/# frozen: v1.1.0}
          printf '%s\n' "$line"
        done < "$4" > "$F515_CELL/hook-candidate.bytes" || exit 96
        cat "$F515_CELL/hook-candidate.bytes" > "$4" || exit 96
        ;;
      validate-config|install-hooks|install|run) ;;
      *) exit 97 ;;
    esac
    ;;
  python)
    if [[ $# == 1 && "$1" == --version ]]; then
      printf 'Python 3.11.9\n'
    elif [[ ${1:-} == -I && ${2:-} == -c \
      && ${3:-} == *platform.python_implementation* && $# == 3 ]]; then
      printf 'CPython\n'
    elif [[ ${1:-} == -I && ${2:-} == -c \
      && ${3:-} == *sys.base_prefix* && $# == 4 \
      && "$4" == "$F515_CELL/project/.venv" ]]; then
      :
    elif [[ ${1:-} == -I && ${2:-} == -c \
      && ${3:-} == *importlib.util.find_spec* && $# == 5 \
      && "$4" == pip_audit && "$5" == "$F515_CELL/project/.venv" ]]; then
      :
    elif [[ ${1:-} == -I && ${2:-} == -m && ${3:-} == pip_audit \
      && ( $# == 3 || ( $# == 4 && "$4" == --fix ) ) ]]; then
      printf 'reached audit execution\n' > "$F515_CELL/audit.executed" || exit 96
      printf 'FINITE_AUDIT_DATA\n'
    else
      exit 97
    fi
    ;;
  delta|bat)
    if [[ "$tool" == delta ]]; then
      [[ $# == 1 && "$1" == --paging=never ]] || exit 97
    else
      [[ $# == 4 && "$1" == -l && "$2" == diff \
        && "$3" == --plain && "$4" == --paging=never ]] || exit 97
    fi
    cat
    ;;
  *) exit 97 ;;
esac
exit 0
SH
  cat > "$F515_CELL/program.zsh" <<'ZSH'
emulate -R zsh
source "$TEST_SUITE_ROOT/functions/dev-menu.zsh" || return 90
builtin cd -- "$F515_CELL/project" || return 91
typeset -g _F515_ASK_SHELL_STATE=0
_DEV_AUTO_YES=${F515_INITIAL_AUTO_YES:-0}
print -r -- "$ZSH_SUBSHELL" > "$F515_CELL/entry.subshell"
print -r -- "$_DEV_AUTO_YES" > "$F515_CELL/auto.before"
functions[f515_original_have]="${functions[_dev_have_command]}"
_dev_have_command() {
  case "$1" in
    gh|actionlint|zizmor|terraform) return 1 ;;
    delta) [[ "$F515_KIND" == diff && "$F515_MODE" == delta ]] ;;
    bat) [[ "$F515_KIND" == diff && "$F515_MODE" == bat ]] ;;
    *) f515_original_have "$@" ;;
  esac
}
# Standard updater-fixture seams: no network or installed hook code is used.
_dev_pypi_check_connectivity() { return 0; }
_dev_pypi_prefetch() { return 0; }
_dev_pypi_latest() {
  printf '%s\0' _dev_pypi_latest "$@" >> "$F515_CELL/pypi-model.argv"
  print -r -- 2.0.0
}
_dev_exact_project_python_tool_runner() {
  [[ "$1" == pre-commit && "$2" == pre_commit ]] || return 97
  reply=("$TEST_MOCK_BIN/pre-commit")
}
_dev_delegate_py_available() { return 0; }
_dev_delegate_py() {
  printf '%s\0' _dev_delegate_py "$@" >> "$F515_CELL/delegation.argv"
  return 0
}
_dev_delegate_sys() {
  printf '%s\0' _dev_delegate_sys "$@" >> "$F515_CELL/delegation.argv"
  return 0
}
functions[f515_original_ask]="${functions[_dev_confirm_ask]}"
f515_ask_leaf() {
  print -r -- "$ZSH_SUBSHELL" > "$F515_CELL/ask.subshell"
  printf '%s\0' "$@" > "$F515_CELL/ask.argv"
  _F515_ASK_SHELL_STATE=1
  command cat "$F515_CELL/primary.stderr" > "$F515_CELL/at-consent.stderr" || return 96
  if [[ "$F515_MODE" == nontty ]]; then
    f515_original_ask "$@"
    return $?
  fi
  if [[ "${F515_MUTATE_CONFIG:-0}" == 1 ]]; then
    print -r -- '# fixture edit during consent' >> .pre-commit-config.yaml
  fi
  return "${F515_ASK_CODE:-1}"
}
_dev_confirm_ask() {
  local rc=0
  f515_ask_leaf "$@" || rc=$?
  print -r -- "$rc" > "$F515_CELL/ask.producer.status"
  return "$rc"
}
f515_call() {
  case "$F515_KIND" in
    lint) dev-run-markdownlint --fix ;;
    all-checks) dev-run-all-checks ;;
    inventory)
      local probe_rc=0 inventory_rc=0
      _dev_project_has_files '*.md' || probe_rc=$?
      print -r -- "$probe_rc" > "$F515_CELL/probe.status"
      local -a reply=()
      _dev_project_files 512 '*.md' || inventory_rc=$?
      print -r -- "$inventory_rc" > "$F515_CELL/inventory.status"
      : > "$F515_CELL/inventory.nul"
      (( inventory_rc != 0 || ${#reply[@]} == 0 )) \
        || printf '%s\0' "${reply[@]}" > "$F515_CELL/inventory.nul"
      dev-run-markdownlint
      ;;
    report)
      _DEV_REPORT_ACTIVE=1
      _DEV_REPORT_LINES=()
      _dev_report_status info first || return $?
      _dev_report_section Summary || return $?
      _dev_report_line detail || return $?
      _dev_report_section Next || return $?
      _dev_report_section Third || return $?
      printf '%s\n' "${_DEV_REPORT_LINES[@]}" > "$F515_CELL/report.actual"
      ;;
    confirm)
      local -a args=()
      [[ "$F515_MODE" != yes ]] || args=(--yes)
      case "$F515_OP" in
        cleanup) dev-clean-py "${args[@]}" ;;
        deps) dev-update-deps "${args[@]}" ;;
        actions) dev-update-actions "${args[@]}" ;;
        python) dev-update-python "${args[@]}" ;;
        all) dev-update-all "${args[@]}" ;;
        audit) dev-run-audit --fix "${args[@]}" ;;
        tflint) dev-run-tflint --init "${args[@]}" ;;
        precommit) dev-update-precommit "${args[@]}" ;;
        *) return 92 ;;
      esac
      ;;
    diff) _dev_show_diff 'literal [x].toml' ;;
    *) return 93 ;;
  esac
}
f515_call > "$F515_CELL/primary.stdout" 2> "$F515_CELL/primary.stderr"
f515_rc=$?
print -r -- "$f515_rc" > "$F515_CELL/primary.status"
print -r -- "$_DEV_AUTO_YES" > "$F515_CELL/auto.after"
print -r -- "$_F515_ASK_SHELL_STATE" > "$F515_CELL/ask.shell-state.after"
return 0
ZSH
}

f515_confirm_project() {
  mkdir -p "$F515_CELL/project/.venv/bin" "$F515_CELL/project/pkg/__pycache__" \
    "$F515_CELL/project/.github/workflows" || return 1
  cat > "$F515_CELL/project/pyproject.toml" <<'TOML' || return 1
[project]
name = "consent-fixture"
requires-python = ">=3.11"
dependencies = ["demo>=1.0.0", "pre-commit>=1.0.0"]
TOML
  printf 'version = 1\n' > "$F515_CELL/project/uv.lock" || return 1
  cp "$F515_CELL/project/pyproject.toml" "$F515_CELL/original.pyproject" || return 1
  cp "$F515_CELL/project/uv.lock" "$F515_CELL/original.lock" || return 1
  cat > "$F515_CELL/project/.pre-commit-config.yaml" <<'YAML' || return 1
repos:
  - repo: https://example.invalid/reviewed-hooks
    rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1.0.0
    hooks:
      - id: fixture
YAML
  cat > "$F515_CELL/project/.github/workflows/ci.yml" <<'YAML' || return 1
name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4.1.0
YAML
  printf 'version_info = 3.11.9\nimplementation = CPython\n' \
    > "$F515_CELL/project/.venv/pyvenv.cfg" || return 1
  printf 'environment canary\n' > "$F515_CELL/project/.venv/original-marker" || return 1
  printf 'cache canary\n' > "$F515_CELL/project/pkg/__pycache__/keep.pyc" || return 1
  printf 'resource "finite" "fixture" {}\n' > "$F515_CELL/project/main.tf" || return 1
  f515_backend "$F515_CELL/project/.venv/bin/python" || return 1
  printf '%s\n' pyproject.toml uv.lock .pre-commit-config.yaml \
    .github/workflows/ci.yml .venv/original-marker .venv/pyvenv.cfg \
    pkg/__pycache__/keep.pyc >> "$F515_CELL/watch.paths" || return 1
}

f515_snapshot() {
  local when="$1" path target identity mode content owner links
  : > "$F515_CELL/state.$when" || return 1
  while IFS= read -r path; do
    if [[ "$path" == /* ]]; then
      [[ "$path" == "$HOME/"* && "$path" != *'/../'* ]] || return 1
      target="$path"
    else
      target="$F515_CELL/project/$path"
    fi
    if [[ -L "$target" ]]; then
      content=$(readlink "$target") || return 1
      identity=$(file_identity "$target") || return 1
      mode=$(file_mode "$target") || return 1
      owner=$(file_owner_uid "$target") || return 1
      links=$(file_links "$target") || return 1
      printf '%s\tlink\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$identity" "$mode" "$owner" "$links" "$content" \
        >> "$F515_CELL/state.$when" || return 1
    elif [[ -f "$target" || -d "$target" ]]; then
      identity=$(file_identity "$target") || return 1
      mode=$(file_mode "$target") || return 1
      owner=$(file_owner_uid "$target") || return 1
      links=$(file_links "$target") || return 1
      content=directory
      [[ ! -f "$target" ]] || content=$(sha256_file "$target") || return 1
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$identity" "$mode" "$owner" "$links" "$content" \
        >> "$F515_CELL/state.$when" || return 1
    elif [[ ! -e "$target" ]]; then
      printf '%s\tabsent\n' "$path" >> "$F515_CELL/state.$when" || return 1
    else
      return 1
    fi
  done < "$F515_CELL/watch.paths"
}

f515_collect() {
  export F515_KIND="$1" F515_OP="${2:-}" F515_MODE="${3:-plain}"
  export F515_ASK_CODE="${4:-1}"
  local rc=0
  f515_snapshot before || return 1
  run_zsh 'source "$F515_CELL/program.zsh"' \
    > "$F515_CELL/wrapper.stdout" 2> "$F515_CELL/wrapper.stderr" || rc=$?
  printf '%s\n' "$rc" > "$F515_CELL/wrapper.status" || return 1
  f515_snapshot after || return 1
}

f515_scalar() {
  [[ -f "$1" && ! -L "$1" ]] || return 80
  printf '%s\n' "$2" > "$1.expected" || return 80
  cmp "$1.expected" "$1" || return 80
}

f515_empty() {
  [[ -f "$1" && ! -L "$1" && ! -s "$1" ]] || return 81
}

f515_primary() {
  local cell="$F515_RESULTS/$1" expected="$2" data="${3:-}"
  f515_scalar "$cell/wrapper.status" 0 || return 82
  f515_empty "$cell/wrapper.stdout" || return 83
  f515_empty "$cell/wrapper.stderr" || return 84
  f515_scalar "$cell/primary.status" "$expected" || return 85
  [[ -f "$cell/primary.stderr" && ! -L "$cell/primary.stderr" ]] || return 86
  if [[ -z "$data" ]]; then
    f515_empty "$cell/primary.stdout" || return 87
  else
    f515_scalar "$cell/primary.stdout" "$data" || return 88
  fi
}

f515_argv() {
  local path="$1"
  shift
  [[ -f "$path" && ! -L "$path" ]] || return 89
  printf '%s\0' "$@" > "$path.expected" || return 89
  cmp "$path.expected" "$path" || return 89
}

f515_count() {
  local path="$F515_RESULTS/$1/receipts/$2/count"
  if [[ "$3" == 0 ]]; then
    [[ ! -e "$path" && ! -L "$path" ]] || return 90
  else
    f515_scalar "$path" "$3" || return 90
  fi
}

f515_producer() {
  local cell="$F515_RESULTS/$1" tool="$2" call="$3" rc="$4" program="${5:-$TEST_MOCK_BIN/$2}"
  f515_scalar "$cell/receipts/$tool/$call.producer.status" "$rc" || return 91
  local actual=""
  [[ -f "$cell/receipts/$tool/$call.argv" && ! -L "$cell/receipts/$tool/$call.argv" ]] || return 92
  IFS= read -r -d '' actual < "$cell/receipts/$tool/$call.argv" || return 92
  [[ "$actual" == "$program" ]] || return 92
}

f515_unchanged() {
  local cell="$F515_RESULTS/$1"
  cmp "$cell/state.before" "$cell/state.after" || return 93
}

f515_paths() {
  local cell="$F515_RESULTS/$1" entry wanted found
  shift
  local -a actual=()
  [[ -f "$cell/inventory.nul" && ! -L "$cell/inventory.nul" ]] || return 94
  entry=""
  while IFS= read -r -d '' entry; do
    [[ -n "$entry" ]] || return 94
    actual+=("$entry")
  done < "$cell/inventory.nul"
  [[ -z "$entry" && ${#actual[@]} -eq $# ]] || return 94
  for wanted in "$@"; do
    found=0
    for entry in "${actual[@]}"; do
      [[ "$entry" != "$wanted" ]] || found=$((found + 1))
    done
    [[ "$found" == 1 ]] || return 94
  done
}

@test "dev state: own reports never select or feed Markdown gates and README remains eligible" {
  local kind name
  for kind in lint all-checks; do
    for name in only-state with-readme; do
      f515_cell "$kind-$name" || return 1
      mkdir "$F515_CELL/project/dev-suite-reports" "$F515_CELL/project/.dev-suite-backups" || return 1
      chmod -- 700 "$F515_CELL/project/dev-suite-reports" \
        "$F515_CELL/project/.dev-suite-backups" || return 1
      printf 'private report canary\n' > "$F515_CELL/project/dev-suite-reports/health.md"
      printf 'private backup canary\n' > "$F515_CELL/project/.dev-suite-backups/recovery.md"
      printf '%s\n' dev-suite-reports/health.md .dev-suite-backups/recovery.md \
        >> "$F515_CELL/watch.paths"
      [[ "$name" != with-readme ]] || printf 'project README\n' > "$F515_CELL/project/README.md"
      f515_collect "$kind" || return 1
    done
  done
  for kind in lint all-checks; do
    f515_primary "$kind-only-state" 0 || return 1
    f515_count "$kind-only-state" markdownlint 0 || return 1
    f515_unchanged "$kind-only-state" || return 1
    f515_primary "$kind-with-readme" 0 || return 1
    f515_count "$kind-with-readme" markdownlint 1 || return 1
    f515_producer "$kind-with-readme" markdownlint 1 0 || return 1
    if [[ "$kind" == lint ]]; then
      f515_argv "$F515_RESULTS/$kind-with-readme/receipts/markdownlint/1.argv" \
        "$TEST_MOCK_BIN/markdownlint" --fix ./README.md || return 1
      grep -Fxq FINITE_MARKDOWN_FIX "$F515_RESULTS/$kind-with-readme/project/README.md" || return 1
    else
      f515_argv "$F515_RESULTS/$kind-with-readme/receipts/markdownlint/1.argv" \
        "$TEST_MOCK_BIN/markdownlint" ./README.md || return 1
      f515_unchanged "$kind-with-readme" || return 1
    fi
    f515_scalar "$F515_RESULTS/$kind-with-readme/project/dev-suite-reports/health.md" \
      'private report canary' || return 1
    f515_scalar "$F515_RESULTS/$kind-with-readme/project/.dev-suite-backups/recovery.md" \
      'private backup canary' || return 1
  done
}

@test "dev state: custom pruning is literal and discovery neither prepares nor repairs state" {
  local model
  for model in literal outside invalid absent; do
    f515_cell "inventory-$model" || return 1
    printf 'project README\n' > "$F515_CELL/project/README.md"
    case "$model" in
      literal)
        export DEV_REPORT_DIR='state[ab]' DEV_BACKUP_DIR='backups?'
        mkdir "$F515_CELL/project/state[ab]" "$F515_CELL/project/statea" \
          "$F515_CELL/project/backups?" "$F515_CELL/project/backupsX" || return 1
        chmod -- 700 "$F515_CELL/project/state[ab]" "$F515_CELL/project/backups?" || return 1
        printf 'private report\n' > "$F515_CELL/project/state[ab]/private.md"
        printf 'private backup\n' > "$F515_CELL/project/backups?/private.md"
        printf 'literal neighbor\n' > "$F515_CELL/project/statea/neighbor.md"
        printf 'question-mark neighbor\n' > "$F515_CELL/project/backupsX/neighbor.md"
        printf '%s\n' 'state[ab]' 'state[ab]/private.md' 'state[ab]/.gitignore' \
          'backups?' 'backups?/private.md' 'backups?/.gitignore' \
          statea/neighbor.md backupsX/neighbor.md >> "$F515_CELL/watch.paths"
        ;;
      outside)
        export DEV_REPORT_DIR="$F515_RESULTS/external-report" DEV_BACKUP_DIR="$F515_RESULTS/external-backup"
        mkdir -m 700 "$DEV_REPORT_DIR" "$DEV_BACKUP_DIR" || return 1
        printf 'outside state canary\n' > "$DEV_REPORT_DIR/keep.md" || return 1
        printf '%s\n' "$DEV_REPORT_DIR" "$DEV_BACKUP_DIR" \
          "$DEV_REPORT_DIR/keep.md" "$DEV_REPORT_DIR/.gitignore" \
          "$DEV_BACKUP_DIR/.gitignore" >> "$F515_CELL/watch.paths" || return 1
        ;;
      invalid)
        export DEV_REPORT_DIR='../invalid-unused' DEV_BACKUP_DIR='.'
        ;;
      absent)
        export DEV_REPORT_DIR='missing[state]' DEV_BACKUP_DIR='missing-backup'
        printf '%s\n' 'missing[state]' missing-backup >> "$F515_CELL/watch.paths"
        mkdir "$F515_CELL/project/dev-suite-reports" || return 1
        chmod -- 755 "$F515_CELL/project/dev-suite-reports" || return 1
        printf 'default state\n' > "$F515_CELL/project/dev-suite-reports/default.md"
        printf '%s\n' dev-suite-reports/default.md dev-suite-reports/.gitignore \
          >> "$F515_CELL/watch.paths"
        ;;
    esac
    f515_collect inventory || return 1
  done
  unset DEV_REPORT_DIR DEV_BACKUP_DIR
  for model in literal outside invalid absent; do
    f515_primary "inventory-$model" 0 || return 1
    f515_scalar "$F515_RESULTS/inventory-$model/probe.status" 0 || return 1
    f515_scalar "$F515_RESULTS/inventory-$model/inventory.status" 0 || return 1
    f515_unchanged "inventory-$model" || return 1
    if [[ "$model" == literal ]]; then
      f515_paths "inventory-$model" ./README.md ./statea/neighbor.md ./backupsX/neighbor.md || return 1
    else
      f515_paths "inventory-$model" ./README.md || return 1
    fi
    f515_count "inventory-$model" markdownlint 1 || return 1
    f515_producer "inventory-$model" markdownlint 1 0 || return 1
  done
}

@test "dev reports: each buffered section has one separating blank line" {
  f515_cell report-sections || return 1
  f515_collect report || return 1
  f515_primary report-sections 0 || return 1
  cat > "$F515_RESULTS/report-sections/report.expected" <<'REPORT'
- INFO — first

## Summary

detail

## Next

## Third

REPORT
  cmp "$F515_RESULTS/report-sections/report.expected" \
    "$F515_RESULTS/report-sections/report.actual" || return 1
}

@test "dev consent: every public confirmation consumer asks in the current shell" {
  local op
  for op in cleanup deps actions python all audit tflint precommit; do
    f515_cell "decline-$op" || return 1
    f515_confirm_project || return 1
    f515_collect confirm "$op" decline 1 || return 1
  done
  for op in cleanup deps actions python all audit tflint precommit; do
    f515_primary "decline-$op" 0 || return 1
    f515_scalar "$F515_RESULTS/decline-$op/ask.producer.status" 1 || return 1
    cmp "$F515_RESULTS/decline-$op/entry.subshell" \
      "$F515_RESULTS/decline-$op/ask.subshell" || return 1
    f515_scalar "$F515_RESULTS/decline-$op/ask.shell-state.after" 1 || return 1
    cmp "$F515_RESULTS/decline-$op/auto.before" \
      "$F515_RESULTS/decline-$op/auto.after" || return 1
    f515_unchanged "decline-$op" || return 1
    f515_count "decline-$op" uv 0 || return 1
    f515_count "decline-$op" pre-commit 0 || return 1
    [[ ! -e "$F515_RESULTS/decline-$op/delegation.argv" \
      && ! -L "$F515_RESULTS/decline-$op/delegation.argv" ]] || return 1
  done
}

@test "dev consent: accept decline unavailable and yes retain their public policies" {
  local mode code op
  for mode in accept decline unavailable yes nontty; do
    code=0
    [[ "$mode" != decline ]] || code=1
    [[ "$mode" != unavailable ]] || code=2
    f515_cell "policy-tflint-$mode" || return 1
    f515_confirm_project || return 1
    f515_collect confirm tflint "$mode" "$code" || return 1
  done
  for mode in accept yes unavailable; do
    f515_cell "policy-audit-$mode" || return 1
    f515_confirm_project || return 1
    code=0
    [[ "$mode" != unavailable ]] || code=2
    f515_collect confirm audit "$mode" "$code" || return 1
  done
  for op in tflint audit; do
    for mode in accept yes unavailable; do
      code=0
      [[ "$mode" != unavailable ]] || code=1
      if [[ "$op" == audit && "$code" == 0 ]]; then
        f515_primary "policy-$op-$mode" "$code" FINITE_AUDIT_DATA || return 1
      else
        f515_primary "policy-$op-$mode" "$code" || return 1
      fi
      cmp "$F515_RESULTS/policy-$op-$mode/auto.before" \
        "$F515_RESULTS/policy-$op-$mode/auto.after" || return 1
      if [[ "$mode" == yes ]]; then
        [[ ! -e "$F515_RESULTS/policy-$op-$mode/ask.producer.status" \
          && ! -L "$F515_RESULTS/policy-$op-$mode/ask.producer.status" ]] || return 1
      else
        [[ "$mode" != accept ]] || f515_scalar \
          "$F515_RESULTS/policy-$op-$mode/ask.producer.status" 0 || return 1
        [[ "$mode" != unavailable ]] || f515_scalar \
          "$F515_RESULTS/policy-$op-$mode/ask.producer.status" 2 || return 1
      fi
    done
  done
  for mode in accept yes; do
    f515_count "policy-tflint-$mode" tflint 2 || return 1
    f515_producer "policy-tflint-$mode" tflint 1 0 || return 1
    f515_producer "policy-tflint-$mode" tflint 2 0 || return 1
    f515_argv "$F515_RESULTS/policy-tflint-$mode/receipts/tflint/1.argv" \
      "$TEST_MOCK_BIN/tflint" --init || return 1
    f515_argv "$F515_RESULTS/policy-tflint-$mode/receipts/tflint/2.argv" \
      "$TEST_MOCK_BIN/tflint" --recursive || return 1
  done
  for mode in decline unavailable nontty; do
    f515_primary "policy-tflint-$mode" "$([[ "$mode" == decline ]] && echo 0 || echo 1)" || return 1
    f515_count "policy-tflint-$mode" tflint 0 || return 1
    f515_unchanged "policy-tflint-$mode" || return 1
  done
  f515_scalar "$F515_RESULTS/policy-tflint-nontty/ask.producer.status" 2 || return 1
  grep -Fq -- '--yes' "$F515_RESULTS/policy-tflint-nontty/primary.stderr" || return 1
  for mode in accept yes; do
    local cell="$F515_RESULTS/policy-audit-$mode" call=""
    [[ -f "$cell/receipts/python/count" && ! -L "$cell/receipts/python/count" ]] || return 1
    IFS= read -r call < "$cell/receipts/python/count" || return 1
    [[ "$call" =~ ^[1-9][0-9]*$ ]] || return 1
    f515_scalar "$cell/receipts/python/count" "$call" || return 1
    f515_producer "policy-audit-$mode" python "$call" 0 "$cell/project/.venv/bin/python" || return 1
    f515_argv "$cell/receipts/python/$call.argv" \
      "$cell/project/.venv/bin/python" -I -m pip_audit --fix || return 1
    f515_scalar "$cell/audit.executed" 'reached audit execution' || return 1
  done
  [[ ! -e "$F515_RESULTS/policy-audit-unavailable/audit.executed" \
    && ! -L "$F515_RESULTS/policy-audit-unavailable/audit.executed" ]] || return 1
}

@test "dev consent: hook trust remains disclosed and bound to unchanged inputs" {
  local mode
  for mode in changed yes unsafe; do
    f515_cell "trust-$mode" || return 1
    f515_confirm_project || return 1
    if [[ "$mode" == changed ]]; then
      export F515_MUTATE_CONFIG=1 F515_INITIAL_AUTO_YES=0
      f515_collect confirm precommit accept 0 || return 1
    elif [[ "$mode" == yes ]]; then
      export F515_MUTATE_CONFIG=0 F515_INITIAL_AUTO_YES=1
      f515_collect confirm precommit yes 0 || return 1
    else
      export F515_MUTATE_CONFIG=0 F515_INITIAL_AUTO_YES=0
      mv "$F515_CELL/project/.pre-commit-config.yaml" "$F515_CELL/config.target" || return 1
      ln -s "$F515_CELL/config.target" "$F515_CELL/project/.pre-commit-config.yaml" || return 1
      f515_collect confirm precommit yes 0 || return 1
    fi
  done
  unset F515_MUTATE_CONFIG F515_INITIAL_AUTO_YES
  f515_primary trust-changed 1 || return 1
  grep -Fq 'Trust scope:' "$F515_RESULTS/trust-changed/at-consent.stderr" || return 1
  grep -Fq 'hooks may rewrite project files' "$F515_RESULTS/trust-changed/at-consent.stderr" || return 1
  grep -Fq '.pre-commit-config.yaml changed during trust review.' "$F515_RESULTS/trust-changed/primary.stderr" || return 1
  f515_count trust-changed uv 0 || return 1
  f515_count trust-changed pre-commit 0 || return 1
  cmp "$F515_RESULTS/trust-changed/original.pyproject" \
    "$F515_RESULTS/trust-changed/project/pyproject.toml" || return 1
  cmp "$F515_RESULTS/trust-changed/original.lock" \
    "$F515_RESULTS/trust-changed/project/uv.lock" || return 1
  f515_scalar "$F515_RESULTS/trust-changed/project/.venv/original-marker" \
    'environment canary' || return 1
  f515_primary trust-yes 0 || return 1
  f515_producer trust-yes uv 1 0 || return 1
  f515_producer trust-yes pre-commit 1 0 || return 1
  f515_argv "$F515_RESULTS/trust-yes/receipts/uv/1.argv" \
    "$TEST_MOCK_BIN/uv" lock --upgrade-package pre-commit || return 1
  f515_scalar "$F515_RESULTS/trust-yes/auto.after" 1 || return 1
  f515_primary trust-unsafe 1 || return 1
  f515_unchanged trust-unsafe || return 1
  f515_count trust-unsafe uv 0 || return 1
  f515_count trust-unsafe pre-commit 0 || return 1
}

@test "dev diff control: retained private renderer disables Git paging in all branches" {
  local branch
  # Current public updaters use private snapshot previews, not this legacy helper.
  for branch in plain delta bat; do
    f515_cell "diff-$branch" || return 1
    f515_collect diff "" "$branch" || return 1
  done
  for branch in plain delta bat; do
    f515_primary "diff-$branch" 0 || return 1
    f515_count "diff-$branch" git 1 || return 1
    f515_producer "diff-$branch" git 1 0 || return 1
    f515_argv "$F515_RESULTS/diff-$branch/receipts/git/1.argv" \
      "$TEST_MOCK_BIN/git" --no-pager diff --no-color -- 'literal [x].toml' || return 1
    grep -Fxq FINITE_GIT_DIFF "$F515_RESULTS/diff-$branch/primary.stderr" || return 1
    if [[ "$branch" == plain ]]; then
      f515_count "diff-$branch" delta 0 || return 1
      f515_count "diff-$branch" bat 0 || return 1
    else
      f515_count "diff-$branch" "$branch" 1 || return 1
      f515_producer "diff-$branch" "$branch" 1 0 || return 1
    fi
  done
}
