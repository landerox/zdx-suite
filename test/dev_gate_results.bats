#!/usr/bin/env bats
# Developer gate status, no-work outcomes and reachable timer regressions.
# All backends below are private finite mocks.
# shellcheck disable=SC2016

setup() {
  load test_helper
  export F514_BASH="$BASH"
  export F514_ZSH
  F514_ZSH=$(type -P zsh) || return 1
  export F514_RESULTS="$HOME/gate-results"
  mkdir -m 700 "$F514_RESULTS" || return 1
  unset F514_CELL F514_CHILD_ONLY
  export DEV_ALLOW_EPHEMERAL=0 NO_COLOR=1
  local tool
  for tool in shellcheck markdownlint bandit ruff tflint; do
    f514_write_backend "$TEST_MOCK_BIN/$tool" || return 1
  done
}

teardown() {
  cleanup_sandbox
}

f514_write_script() {
  local target="$1"
  { printf '#!%s\n' "$BASH" || return 1; cat || return 1; } \
    > "$target" || return 1
  chmod -- 755 "$target" || return 1
}

f514_write_backend() {
  f514_write_script "$1" <<'BASH'
set -u
tool=${0##*/}
dir="$F514_CELL/receipts/$tool"
mkdir -p "$dir" || exit 96
count=0
[[ ! -f "$dir/count" ]] || read -r count < "$dir/count"
count=$((count + 1))
printf '%s\n' "$count" > "$dir/count"
printf '%s\0' "$0" "$@" > "$dir/$count.argv"
code=0
if [[ -f "$F514_CELL/$tool.sequence" ]]; then
  mapfile -t codes < "$F514_CELL/$tool.sequence"
  code=${codes[$((count - 1))]:-${codes[${#codes[@]}-1]}}
fi
"$F514_BASH" "$F514_CELL/leaf.bash" "$tool" "$count" "$code" "$@"
actual=$?
# This is observed AFTER the finite leaf returned, unlike leaf.reached-code.
printf '%s\n' "$actual" > "$dir/$count.producer.status"
exit "$actual"
BASH
}

f514_cell() {
  export F514_CELL="$F514_RESULTS/$1"
  mkdir -m 700 "$F514_CELL" || return 1
  mkdir -p "$F514_CELL/project" "$F514_CELL/receipts" || return 1
  printf 'FINITE_OPEN_STDIN_CANARY\n' > "$F514_CELL/input.txt" || return 1
  f514_write_script "$F514_CELL/leaf.bash" <<'BASH' || return 1
set -u
tool=$1 call=$2 code=$3
shift 3
dir="$F514_CELL/receipts/$tool"
printf '%s\n' "$code" > "$dir/$call.leaf.reached-code"
if [[ -f "$F514_CELL/observe-stdin" ]]; then
  IFS= read -r input
  read_status=$?
  printf '%s\n' "$read_status" > "$dir/$call.stdin.status"
  printf '%s' "${input:-}" > "$dir/$call.stdin.bytes"
fi
if [[ -f "$F514_CELL/tail-payload" && "$tool" == shellcheck ]]; then
  for ((n=1; n<=120; n++)); do printf 'FINITE_TAIL_%03d\n' "$n"; done
  printf 'token=FINITE_SECRET_DO_NOT_REPLAY\n'
  printf '\033[31mFINITE_COLORED_END\033[0m\n'
else
  if [[ "$tool" != bandit || -f "$F514_CELL/direct-report" ]]; then
    printf 'FINITE_%s_STDOUT\n' "$tool"
  fi
  printf 'FINITE_%s_STDERR\n' "$tool" >&2
fi
exit "$code"
BASH
  cat > "$F514_CELL/program.zsh" <<'ZSH'
emulate -R zsh
source "$TEST_SUITE_ROOT/functions/dev-menu.zsh" || return 90
builtin cd -- "$F514_CELL/project" || return 91
print -r -- "${+functions[_zdx_run_captured]}:${+functions[_timed]}" \
  > "$F514_CELL/capture-and-timer.services"
f514_before_pwd="$PWD"
f514_before_options="${options[shwordsplit]}:${options[nomatch]}"
f514_before_env="${F514_CHILD_ONLY-unset}"
if [[ -f "$F514_CELL/isolation" ]]; then
  functions[f514_original_shellcheck]="${functions[dev-run-shellcheck]}"
  dev-run-shellcheck() {
    f514_original_shellcheck "$@"
    local f514_gate_rc=$?
    print -r -- 'reached' > "$F514_CELL/isolation.reached"
    setopt SH_WORD_SPLIT
    unsetopt NOMATCH
    export F514_CHILD_ONLY=mutated
    builtin cd -- "$HOME" || return 92
    return "$f514_gate_rc"
  }
fi
f514_call() {
  case "$F514_ACTION" in
    direct-shell) dev-run-shellcheck ;;
    direct-bandit) dev-run-bandit ;;
    explicit-tests) dev-run-tests test_selected.py ;;
    aggregate) dev-menu dev-run-all-checks ;;
    verbose) dev-menu dev-run-all-checks --verbose ;;
    multi) _dev_menu_execute_batch "$F514_TASK" ;;
    *) return 93 ;;
  esac
}
f514_call < "$F514_CELL/input.txt" \
  > "$F514_CELL/primary.stdout" 2> "$F514_CELL/primary.stderr"
f514_primary_rc=$?
print -r -- "$f514_primary_rc" > "$F514_CELL/primary.status"
print -r -- "$PWD" > "$F514_CELL/after.pwd"
print -r -- "${options[shwordsplit]}:${options[nomatch]}" > "$F514_CELL/after.options"
print -r -- "${F514_CHILD_ONLY-unset}" > "$F514_CELL/after.env"
print -r -- "$f514_before_pwd" > "$F514_CELL/before.pwd"
print -r -- "$f514_before_options" > "$F514_CELL/before.options"
print -r -- "$f514_before_env" > "$F514_CELL/before.env"
return 0
ZSH
}

f514_project_python() {
  mkdir -p "$F514_CELL/project/.venv/bin" || return 1
  f514_write_script "$F514_CELL/project/.venv/bin/python" <<'BASH' || return 1
set -u
mkdir -p "$F514_CELL/receipts/python" || exit 96
if [[ ${1:-} == -I && ${2:-} == -c && $# == 4 \
  && $3 == *sys.base_prefix* && $4 == "$F514_CELL/project/.venv" ]]; then
  printf '%s\0' "$0" "$@" >> "$F514_CELL/receipts/python/prefix.argv"
  [[ ! -f "$F514_CELL/refuse-prefix" ]]
  code=$?
  printf '%s\n' "$code" >> "$F514_CELL/receipts/python/prefix.status"
  exit "$code"
fi
if [[ ${1:-} == -I && ${2:-} == -c && $# == 5 \
  && $3 == *importlib.util.find_spec* && $4 == pytest \
  && $5 == "$F514_CELL/project/.venv" ]]; then
  printf '%s\0' "$0" "$@" >> "$F514_CELL/receipts/python/module.argv"
  printf '0\n' >> "$F514_CELL/receipts/python/module.status"
  exit 0
fi
if [[ ${1:-} == -I && ${2:-} == -m && ${3:-} == pytest ]]; then
  printf '%s\0' "$0" "$@" > "$F514_CELL/receipts/python/run.argv"
  shift 3
  "$TEST_MOCK_BIN/pytest" "$@"
  actual=$?
  printf '%s\n' "$actual" > "$F514_CELL/receipts/python/run.status"
  exit "$actual"
fi
printf '%s\0' "$0" "$@" > "$F514_CELL/receipts/python/refused.argv"
exit 97
BASH
  f514_write_backend "$TEST_MOCK_BIN/pytest" || return 1
}

f514_collect() {
  export F514_ACTION="$1" F514_TASK="${2:-}"
  local wrapper_rc=0
  # Every independent cell runs before its test starts asserting outcomes.
  if [[ "${3:-core}" == standalone ]]; then
    ZSH_CUSTOM="$TEST_SUITE_ROOT" "$F514_ZSH" -f "$F514_CELL/program.zsh" \
      > "$F514_CELL/wrapper.stdout" 2> "$F514_CELL/wrapper.stderr" \
      < /dev/null || wrapper_rc=$?
  else
    run_zsh 'source "$F514_CELL/program.zsh"' \
      > "$F514_CELL/wrapper.stdout" 2> "$F514_CELL/wrapper.stderr" \
      || wrapper_rc=$?
  fi
  printf '%s\n' "$wrapper_rc" > "$F514_CELL/wrapper.status"
}

f514_scalar() {
  local target="$1" expected="$2"
  [[ -f "$target" && ! -L "$target" ]] || return 80
  printf '%s\n' "$expected" > "$target.expected" || return 80
  cmp "$target.expected" "$target" || return 80
}

f514_empty_file() {
  [[ -f "$1" && ! -L "$1" && ! -s "$1" ]] || return 80
}

f514_primary() {
  local cell="$F514_RESULTS/$1" expected="$2"
  [[ -f "$cell/wrapper.status" && ! -L "$cell/wrapper.status" ]] || return 81
  f514_scalar "$cell/wrapper.status" 0 || return 82
  [[ -f "$cell/wrapper.stdout" && ! -s "$cell/wrapper.stdout" ]] || return 83
  [[ -f "$cell/wrapper.stderr" && ! -s "$cell/wrapper.stderr" ]] || return 84
  [[ -f "$cell/primary.status" && ! -L "$cell/primary.status" ]] || return 85
  f514_scalar "$cell/primary.status" "$expected" || return 86
  [[ -f "$cell/primary.stdout" && ! -s "$cell/primary.stdout" ]] || return 87
  [[ -f "$cell/primary.stderr" && -s "$cell/primary.stderr" ]] || return 88
}

f514_producer() {
  local cell="$F514_RESULTS/$1" tool="$2" call="$3" expected="$4"
  local path="$cell/receipts/$tool/$call.producer.status" executable=""
  [[ -f "$path" && ! -L "$path" ]] || return 89
  f514_scalar "$path" "$expected" || return 90
  [[ -s "$cell/receipts/$tool/$call.argv" ]] || return 91
  IFS= read -r -d '' executable < "$cell/receipts/$tool/$call.argv" || return 92
  [[ "$executable" == "$TEST_MOCK_BIN/$tool" ]] || return 93
}

f514_result() {
  local cell="$F514_RESULTS/$1" label="$2" outcome="$3" mode="${4:-core}"
  # Preserve the two existing renderers; neither a banner nor table is a result.
  awk -v label="$label" -v outcome="$outcome" -v mode="$mode" '
    {
      prefix = mode == "core" ? "] " label " — " outcome : label ": " outcome
      start = index($0, prefix)
      following = substr($0, start + length(prefix), 1)
      shape = mode == "core" ? $0 ~ /\[[0-9]+\/[0-9]+\]/ : $0 ~ /^[[:space:]]/
      if (start && shape && (following == "" || following ~ /[[:space:]:]/)) n++
    }
    END {exit n != 1}
  ' "$cell/primary.stderr" || return 92
}

f514_count() {
  local path="$F514_RESULTS/$1/receipts/$2/count" expected="$3"
  if [[ "$expected" == 0 ]]; then
    [[ ! -e "$path" && ! -L "$path" ]] || return 93
  else
    f514_scalar "$path" "$expected" || return 94
  fi
}

@test "dev gate results: actual ShellCheck stops keep 130 and 143 before later aggregate work" {
  local code
  for code in 0 1 130 143; do
    f514_cell "shell-$code" || return 1
    : > "$F514_CELL/project/tool.sh"
    printf '%s\n' "$code" > "$F514_CELL/shellcheck.sequence"
    f514_collect direct-shell
  done
  for code in 0 130 143; do
    f514_cell "shell-all-$code" || return 1
    : > "$F514_CELL/project/tool.sh"
    : > "$F514_CELL/project/README.md"
    printf '%s\n' "$code" > "$F514_CELL/shellcheck.sequence"
    f514_collect aggregate
  done
  for code in 0 1 130 143; do
    f514_primary "shell-$code" "$code" || return 1
    f514_producer "shell-$code" shellcheck 1 "$code" || return 1
    printf '%s\0' "$TEST_MOCK_BIN/shellcheck" -- ./tool.sh \
      > "$F514_RESULTS/shell-$code/expected.argv"
    cmp "$F514_RESULTS/shell-$code/expected.argv" \
      "$F514_RESULTS/shell-$code/receipts/shellcheck/1.argv" || return 1
  done
  f514_primary shell-all-0 0 || return 1
  f514_producer shell-all-0 markdownlint 1 0 || return 1
  for code in 130 143; do
    f514_primary "shell-all-$code" "$code" || return 1
    f514_producer "shell-all-$code" shellcheck 1 "$code" || return 1
    f514_count "shell-all-$code" markdownlint 0 || return 1
    awk '/^[[:space:]]*Markdownlint[[:space:]]+– not run[[:space:]]+checks interrupted[[:space:]]*$/ {n++} END {exit n != 1}' \
      "$F514_RESULTS/shell-all-$code/primary.stderr" || return 1
  done
}

@test "dev gate results: Bandit batches stop on an actual later or first interruption" {
  local name first later count i expected calls
  local -a scenes=('late-int 1 130 65 130 2' 'late-term 1 143 65 143 2'
    'first-int 130 0 65 130 1' 'first-term 143 0 65 143 1'
    'control266 130 0 1 130 1' 'findings 1 0 65 1 2' 'clean 0 0 65 0 2')
  for name in "${scenes[@]}"; do
    read -r name first later count expected calls <<< "$name"
    f514_cell "bandit-$name" || return 1
    : > "$F514_CELL/direct-report"
    for ((i=1; i<=count; i++)); do : > "$F514_CELL/project/module-$i.py"; done
    printf '%s\n%s\n' "$first" "$later" > "$F514_CELL/bandit.sequence"
    f514_collect direct-bandit
  done
  for name in "${scenes[@]}"; do
    read -r name first later count expected calls <<< "$name"
    # Bandit's documented report is data stdout; this fixture emits report
    # text, so inspect the observed primary separately from UI-only gates.
    local cell="$F514_RESULTS/bandit-$name"
    f514_scalar "$cell/wrapper.status" 0 || return 1
    [[ -f "$cell/wrapper.stdout" && ! -s "$cell/wrapper.stdout" \
      && -f "$cell/wrapper.stderr" && ! -s "$cell/wrapper.stderr" ]] || return 1
    f514_scalar "$cell/primary.status" "$expected" || return 1
    f514_count "bandit-$name" bandit "$calls" || return 1
    f514_producer "bandit-$name" bandit 1 "$first" || return 1
    if [[ "$calls" == 2 ]]; then
      f514_producer "bandit-$name" bandit 2 "$later" || return 1
    fi
    grep -Fq FINITE_bandit_STDOUT "$cell/primary.stdout" || return 1
    grep -Fq FINITE_bandit_STDERR "$cell/primary.stderr" || return 1
    local call argument path_count
    for ((call=1; call<=calls; call++)); do
      local -a arguments=()
      while IFS= read -r -d '' argument; do arguments+=("$argument"); done \
        < "$cell/receipts/bandit/$call.argv"
      [[ "${arguments[0]}" == "$TEST_MOCK_BIN/bandit" \
        && "${arguments[1]}" == -l && "${arguments[2]}" == -i \
        && "${arguments[3]}" == --format && "${arguments[4]}" == txt \
        && "${arguments[5]}" == -- ]] || return 1
      path_count=64
      [[ "$count" != 1 && "$call" != 2 ]] || path_count=1
      [[ "${#arguments[@]}" -eq $((path_count + 6)) ]] || return 1
      for argument in "${arguments[@]:6}"; do
        [[ "$argument" == ./module-*.py && -f "$cell/project/$argument" ]] || return 1
      done
    done
  done
}

@test "dev gate results: every empty-source multi gate is skipped and has a reached healthy control" {
  local task tool file kind
  local -a gates=('dev-run-ruff ruff app.py' 'dev-run-shellcheck shellcheck tool.sh'
    'dev-run-markdownlint markdownlint README.md' 'dev-run-tflint tflint main.tf'
    'dev-run-tests pytest pytest.ini' 'dev-run-bandit bandit app.py')
  for kind in empty healthy; do
    for task in "${gates[@]}"; do
      read -r task tool file <<< "$task"
      f514_cell "$kind-$tool" || return 1
      if [[ "$kind" == healthy ]]; then
        : > "$F514_CELL/project/$file"
        [[ "$tool" != pytest ]] || f514_project_python || return 1
      fi
      f514_collect multi "$task"
    done
  done
  for task in "${gates[@]}"; do
    read -r task tool file <<< "$task"
    f514_primary "empty-$tool" 0 || return 1
    f514_result "empty-$tool" "$task" skipped || return 1
    awk '/(^|[[:space:]])1 task skipped[.][[:space:]]*$/ {n++} END {exit n != 1}' \
      "$F514_RESULTS/empty-$tool/primary.stderr" || return 1
    if grep -Fq 'The only task completed successfully.' \
      "$F514_RESULTS/empty-$tool/primary.stderr"; then return 1; fi
    f514_count "empty-$tool" "$tool" 0 || return 1
    f514_primary "healthy-$tool" 0 || return 1
    f514_result "healthy-$tool" "$task" passed || return 1
    f514_producer "healthy-$tool" "$tool" 1 0 || return 1
  done
}

@test "dev gate results: captured pytest no-collection is skipped but explicit status 5 is an error" {
  local name code action
  for name in 'implicit-five 5 aggregate' 'implicit-zero 0 aggregate' \
    'explicit-five 5 explicit-tests' 'bad-prefix 0 aggregate'; do
    read -r name code action <<< "$name"
    f514_cell "$name" || return 1
    printf '[pytest]\n' > "$F514_CELL/project/pytest.ini"
    f514_project_python || return 1
    printf '%s\n' "$code" > "$F514_CELL/pytest.sequence"
    [[ "$name" != bad-prefix ]] || : > "$F514_CELL/refuse-prefix"
    f514_collect "$action"
  done
  f514_primary implicit-five 0 || return 1
  f514_result implicit-five 'Tests (pytest)' skipped || return 1
  f514_primary implicit-zero 0 || return 1
  f514_result implicit-zero 'Tests (pytest)' passed || return 1
  f514_primary explicit-five 5 || return 1
  f514_primary bad-prefix 1 || return 1
  f514_count bad-prefix pytest 0 || return 1
  f514_scalar "$F514_RESULTS/bad-prefix/receipts/python/prefix.status" 1 || return 1
  for name in implicit-five implicit-zero explicit-five; do
    code=5; [[ "$name" != implicit-zero ]] || code=0
    f514_producer "$name" pytest 1 "$code" || return 1
    f514_scalar "$F514_RESULTS/$name/receipts/python/run.status" "$code" || return 1
    [[ ! -e "$F514_RESULTS/$name/receipts/python/refused.argv" ]] || return 1
    local -a expected=("$F514_RESULTS/$name/project/.venv/bin/python" -I -m pytest)
    [[ "$name" != explicit-five ]] || expected+=(test_selected.py)
    printf '%s\0' "${expected[@]}" > "$F514_RESULTS/$name/expected.argv"
    cmp "$F514_RESULTS/$name/expected.argv" \
      "$F514_RESULTS/$name/receipts/python/run.argv" || return 1
  done
}

@test "dev gate results: only an actual passed and failed mix marks the reachable outer timer partial" {
  local name sc md pytest action expected
  local -a scenes=('mixed 1 0 none aggregate 1' 'failed-skipped 1 none 5 aggregate 1'
    'all-skipped none none 5 aggregate 0' 'all-failed 1 1 none aggregate 1'
    'all-passed 0 0 none aggregate 0' 'interrupted 143 0 none aggregate 143'
    'verbose-mixed 1 0 none verbose 1')
  for name in "${scenes[@]}"; do
    read -r name sc md pytest action expected <<< "$name"
    f514_cell "$name" || return 1
    if [[ "$sc" != none ]]; then
      : > "$F514_CELL/project/tool.sh"
      printf '%s\n' "$sc" > "$F514_CELL/shellcheck.sequence"
    fi
    if [[ "$md" != none ]]; then
      : > "$F514_CELL/project/README.md"
      printf '%s\n' "$md" > "$F514_CELL/markdownlint.sequence"
    fi
    if [[ "$pytest" != none ]]; then
      printf '[pytest]\n' > "$F514_CELL/project/pytest.ini"
      f514_project_python || return 1
      printf '%s\n' "$pytest" > "$F514_CELL/pytest.sequence"
    fi
    f514_collect "$action"
  done
  for name in "${scenes[@]}"; do
    read -r name sc md pytest action expected <<< "$name"
    f514_primary "$name" "$expected" || return 1
    f514_scalar "$F514_RESULTS/$name/capture-and-timer.services" 1:1 || return 1
    if [[ "$sc" != none ]]; then
      f514_producer "$name" shellcheck 1 "$sc" || return 1
    fi
    if [[ "$md" != none && "$name" != interrupted ]]; then
      f514_producer "$name" markdownlint 1 "$md" || return 1
    fi
    if [[ "$pytest" != none ]]; then
      f514_producer "$name" pytest 1 "$pytest" || return 1
      f514_result "$name" 'Tests (pytest)' skipped || return 1
    fi
    case "$name" in
      mixed|verbose-mixed)
        grep -Fq 'dev:dev-run-all-checks completed with partial failures' \
          "$F514_RESULTS/$name/primary.stderr" || return 1 ;;
      *)
        if grep -Fq 'completed with partial failures' "$F514_RESULTS/$name/primary.stderr"; then
          return 1
        fi ;;
    esac
  done
  f514_count interrupted markdownlint 0 || return 1
  f514_result all-passed ShellCheck passed || return 1
  f514_result all-passed Markdownlint passed || return 1
  f514_result all-failed ShellCheck failed || return 1
  f514_result all-failed Markdownlint failed || return 1
  f514_result mixed ShellCheck failed || return 1
  f514_result mixed Markdownlint passed || return 1
  f514_result failed-skipped ShellCheck failed || return 1
  awk '/(^|[[:space:]])1 check skipped[.][[:space:]]*$/ {n++} END {exit n != 1}' \
    "$F514_RESULTS/all-skipped/primary.stderr" || return 1
  if grep -Eq 'The only check passed|All .*checks passed' \
    "$F514_RESULTS/all-skipped/primary.stderr"; then return 1; fi
}

@test "dev gate results: core capture retains closed input isolation and bounded redacted failure replay" {
  local name action
  f514_cell capture-input-control || return 1
  : > "$F514_CELL/project/tool.sh"
  : > "$F514_CELL/observe-stdin"
  f514_collect direct-shell
  for name in normal verbose; do
    f514_cell "capture-$name" || return 1
    : > "$F514_CELL/project/tool.sh"
    : > "$F514_CELL/project/README.md"
    : > "$F514_CELL/isolation"
    : > "$F514_CELL/observe-stdin"
    printf '1\n' > "$F514_CELL/shellcheck.sequence"
    [[ "$name" != normal ]] || : > "$F514_CELL/tail-payload"
    action=aggregate; [[ "$name" != verbose ]] || action=verbose
    f514_collect "$action"
  done
  f514_primary capture-input-control 0 || return 1
  f514_producer capture-input-control shellcheck 1 0 || return 1
  f514_scalar "$F514_RESULTS/capture-input-control/receipts/shellcheck/1.stdin.status" 0 || return 1
  local input_receipt="$F514_RESULTS/capture-input-control/receipts/shellcheck/1.stdin.bytes"
  [[ -f "$input_receipt" && ! -L "$input_receipt" ]] || return 1
  printf '%s' FINITE_OPEN_STDIN_CANARY > "$input_receipt.expected" || return 1
  cmp "$input_receipt.expected" "$input_receipt" || return 1
  for name in normal verbose; do
    local cell="$F514_RESULTS/capture-$name"
    f514_primary "capture-$name" 1 || return 1
    f514_producer "capture-$name" shellcheck 1 1 || return 1
    f514_producer "capture-$name" markdownlint 1 0 || return 1
    f514_scalar "$cell/receipts/shellcheck/1.stdin.status" 1 || return 1
    f514_empty_file "$cell/receipts/shellcheck/1.stdin.bytes" || return 1
    [[ -s "$cell/isolation.reached" ]] || return 1
    cmp "$cell/before.pwd" "$cell/after.pwd" || return 1
    cmp "$cell/before.options" "$cell/after.options" || return 1
    cmp "$cell/before.env" "$cell/after.env" || return 1
  done
  local stderr="$F514_RESULTS/capture-normal/primary.stderr"
  grep -Fq FINITE_TAIL_120 "$stderr" || return 1
  grep -Fq '[redacted potentially sensitive output]' "$stderr" || return 1
  grep -Fq FINITE_COLORED_END "$stderr" || return 1
  if grep -Eq 'FINITE_TAIL_001|FINITE_SECRET_DO_NOT_REPLAY' "$stderr"; then return 1; fi
  if LC_ALL=C grep -q $'\033' "$stderr"; then return 1; fi
  grep -Fq FINITE_shellcheck_STDOUT "$F514_RESULTS/capture-verbose/primary.stderr" || return 1
}

@test "dev gate results: truly standalone fallback distinguishes skipped captured tests and selected tasks" {
  f514_cell standalone-tests || return 1
  printf '[pytest]\n' > "$F514_CELL/project/pytest.ini"
  f514_project_python || return 1
  printf '5\n' > "$F514_CELL/pytest.sequence"
  f514_collect aggregate '' standalone
  f514_cell standalone-empty || return 1
  f514_collect multi dev-run-shellcheck standalone
  f514_cell standalone-pass || return 1
  : > "$F514_CELL/project/tool.sh"
  f514_collect multi dev-run-shellcheck standalone
  f514_primary standalone-tests 0 || return 1
  f514_scalar "$F514_RESULTS/standalone-tests/capture-and-timer.services" 0:0 || return 1
  f514_producer standalone-tests pytest 1 5 || return 1
  f514_result standalone-tests 'Tests (pytest)' skipped standalone || return 1
  f514_primary standalone-empty 0 || return 1
  f514_scalar "$F514_RESULTS/standalone-empty/capture-and-timer.services" 0:0 || return 1
  f514_result standalone-empty dev-run-shellcheck skipped standalone || return 1
  f514_count standalone-empty shellcheck 0 || return 1
  f514_primary standalone-pass 0 || return 1
  f514_scalar "$F514_RESULTS/standalone-pass/capture-and-timer.services" 0:0 || return 1
  f514_result standalone-pass dev-run-shellcheck passed standalone || return 1
  f514_producer standalone-pass shellcheck 1 0 || return 1
}

# Finite completed-result transport controls.

f514_sidecar_cell() {
  f514_cell "$1" || return 1
  export F514_SIDECAR_MODE="$2" F514_SIDECAR_CODE="${3:-0}"
  cat > "$F514_CELL/program.zsh" <<'ZSH'
emulate -R zsh
builtin source "$TEST_SUITE_ROOT/functions/dev-menu.zsh" || return 90
builtin cd -- "$F514_CELL/project" || return 91
print -r -- "${+functions[_zdx_run_captured]}" > "$F514_CELL/core.service"
if (( ! ${+functions[_dev_check_run_captured]} )); then
  print -r -- UNREACHED_NEW_PRIVATE_HELPER_ABSENT > "$F514_CELL/companion.admission"
  return 95
fi
print -r -- CANDIDATE_PRIVATE_PROTOCOL > "$F514_CELL/companion.admission"
print -r -- KEEP_UNRELATED > "$F514_CELL/unrelated.canary"
functions[f514_sidecar_writer_original]="${functions[_dev_check_result_write]}"
_dev_check_result_write() {
  f514_sidecar_writer_original "$@"
  local -i writer_rc=$?
  print -r -- "$writer_rc" > "$F514_CELL/writer.post-return"
  (( writer_rc == 0 )) || return $writer_rc
  case "$F514_SIDECAR_MODE" in
    missing) command rm -- "$1" || return 96 ;;
    malformed) print -rn -- 'not-a-completed-frame' >| "$1" || return 96 ;;
    extra) print -rn -- $'completed\tnone\t-\ncompleted\tnone\t-\n' >| "$1" || return 96 ;;
    oversize) builtin printf '%513s' '' >| "$1" || return 96 ;;
    inode)
      print -r -- "$2" > "$F514_CELL/original.result.identity"
      command mv -- "$1" "$1.original" || return 96
      (umask 077; print -rn -- $'completed\tnone\t-\n' > "$1") || return 96
      local -A replaced=()
      zstat -LH replaced -- "$1" || return 96
      print -r -- "${replaced[device]}:${replaced[inode]}" > "$F514_CELL/replacement.result.identity"
      ;;
    workspace)
      local workspace_path="$5"
      [[ "$workspace_path" == /* && "$1" == "$workspace_path/result" ]] || return 96
      command mv -- "$workspace_path" "$workspace_path.original" || return 96
      command mkdir -- "$workspace_path" || return 96
      command chmod -- 700 "$workspace_path" || return 96
      (umask 077; print -r -- KEEP_FOREIGN_WORKSPACE > "$workspace_path/foreign.canary") || return 96
      print -r -- "$workspace_path" > "$F514_CELL/foreign.workspace"
      local -A foreign=()
      zstat -LH foreign -- "$workspace_path/foreign.canary" || return 96
      print -r -- "${foreign[device]}:${foreign[inode]}" > "$F514_CELL/foreign.before.identity"
      ;;
  esac
  # A bounded snapshot of the owned sidecar, never Core's private capture log.
  if [[ -f "$1" && ! -L "$1" ]]; then
    command cp -- "$1" "$F514_CELL/frame.after-write" || return 96
  fi
  print -r -- "$F514_SIDECAR_MODE" > "$F514_CELL/mutation.reached"
  return 0
}
functions[f514_sidecar_cleanup_original]="${functions[_dev_update_workspace_cleanup]}"
_dev_update_workspace_cleanup() {
  f514_sidecar_cleanup_original "$@"
  local -i cleanup_rc=$?
  print -r -- "$cleanup_rc" > "$F514_CELL/cleanup.post-return"
  (( cleanup_rc == 0 )) || return $cleanup_rc
  if [[ "$F514_SIDECAR_MODE" == cleanup-failure || "$F514_SIDECAR_MODE" == aggregate-stop ]]; then
    print -r -- MODELED_CLEANUP_RETURN_17 > "$F514_CELL/cleanup.configured-site"
    return 17
  fi
  return 0
}
f514_sidecar_payload() {
  print -r -- PAYLOAD_REACHED > "$F514_CELL/payload.reached"
  if [[ "$F514_SIDECAR_MODE" == skipped ]]; then
    _dev_report_result skipped 'finite no-work reason' || return 96
  fi
  return "$F514_SIDECAR_CODE"
}
f514_sidecar_leaf() {
  f514_sidecar_payload
  local -i payload_rc=$?
  print -r -- "$payload_rc" > "$F514_CELL/payload.post-return"
  return $payload_rc
}
f514_sidecar_call() {
  # This test-owned heading permits reuse of the existing strict primary helper;
  # it is not evidence of a product verdict or result line.
  _dev_header 'Finite sidecar protocol companion'
  if [[ "$F514_SIDECAR_MODE" == aggregate-stop ]]; then
    dev-run-ruff() { f514_sidecar_leaf; }
    dev-run-bandit() { print -r -- FORBIDDEN_LATER_GATE > "$F514_CELL/later.reached"; return 0; }
    dev-run-all-checks
    return $?
  fi
  local -a reply=()
  local -i observed=0
  _dev_step_exec _dev_check_run_captured 'finite private check' f514_sidecar_leaf || observed=$?
  print -rl -- "${reply[@]}" > "$F514_CELL/step.reply"
  return $observed
}
f514_sidecar_call > "$F514_CELL/primary.stdout" 2> "$F514_CELL/primary.stderr"
f514_sidecar_rc=$?
print -r -- "$f514_sidecar_rc" > "$F514_CELL/primary.status"
if [[ -f "$F514_CELL/foreign.workspace" ]]; then
  local foreign_workspace="$(<"$F514_CELL/foreign.workspace")"
  if [[ -f "$foreign_workspace/foreign.canary" && ! -L "$foreign_workspace/foreign.canary" ]]; then
    local -A after=()
    zstat -LH after -- "$foreign_workspace/foreign.canary" || return 97
    print -r -- "${after[device]}:${after[inode]}" > "$F514_CELL/foreign.after.identity"
    command cp -- "$foreign_workspace/foreign.canary" "$F514_CELL/foreign.after.bytes" || return 97
  fi
fi
return 0
ZSH
}

@test "dev sidecar companions: real captures retain none and skipped outcomes with core and standalone" {
  local engine outcome name expected observed
  for engine in core standalone; do
    for outcome in none skipped; do
      name="sidecar-$engine-$outcome"
      f514_sidecar_cell "$name" "$outcome" 0 || return 1
      f514_collect aggregate '' "$engine"
    done
  done
  for engine in core standalone; do
    for outcome in none skipped; do
      name="sidecar-$engine-$outcome"
      f514_primary "$name" 0 || return 1
      f514_scalar "$F514_RESULTS/$name/payload.post-return" 0 || return 1
      f514_scalar "$F514_RESULTS/$name/writer.post-return" 0 || return 1
      f514_scalar "$F514_RESULTS/$name/cleanup.post-return" 0 || return 1
      if [[ "$engine" == core ]]; then expected=1; else expected=0; fi
      f514_scalar "$F514_RESULTS/$name/core.service" "$expected" || return 1
      if [[ "$outcome" == none ]]; then
        printf 'completed\tnone\t-\n' > "$F514_RESULTS/$name/frame.expected"
        IFS= read -r observed < "$F514_RESULTS/$name/step.reply" || return 1
        [[ "$observed" == done ]] || return 1
      else
        printf 'completed\tskipped\tfinite no-work reason\n' > "$F514_RESULTS/$name/frame.expected"
        IFS= read -r observed < "$F514_RESULTS/$name/step.reply" || return 1
        [[ "$observed" == skipped ]] || return 1
        grep -Fxq 'finite no-work reason' "$F514_RESULTS/$name/step.reply" || return 1
      fi
      cmp "$F514_RESULTS/$name/frame.expected" "$F514_RESULTS/$name/frame.after-write" || return 1
    done
  done
}

@test "dev sidecar companions: invalid or missing completed frames cannot become successful checks" {
  local mode name observed
  for mode in missing malformed extra oversize; do
    name="sidecar-frame-$mode"
    f514_sidecar_cell "$name" "$mode" 0 || return 1
    f514_collect aggregate
  done
  for mode in missing malformed extra oversize; do
    name="sidecar-frame-$mode"
    f514_primary "$name" 1 || return 1
    f514_scalar "$F514_RESULTS/$name/payload.post-return" 0 || return 1
    f514_scalar "$F514_RESULTS/$name/writer.post-return" 0 || return 1
    f514_scalar "$F514_RESULTS/$name/cleanup.post-return" 0 || return 1
    grep -Fxq "$mode" "$F514_RESULTS/$name/mutation.reached" || return 1
    grep -Fq 'Could not validate the completed check result.' "$F514_RESULTS/$name/primary.stderr" || return 1
    IFS= read -r observed < "$F514_RESULTS/$name/step.reply" || return 1
    [[ "$observed" == failed ]] || return 1
  done
  [[ "$(file_size "$F514_RESULTS/sidecar-frame-oversize/frame.after-write")" == 513 ]] || return 1
}

@test "dev sidecar companions: changed result and workspace identities are refused without deleting foreign data" {
  local mode name
  for mode in inode workspace; do
    name="sidecar-replaced-$mode"
    f514_sidecar_cell "$name" "$mode" 0 || return 1
    f514_collect aggregate
  done
  for mode in inode workspace; do
    name="sidecar-replaced-$mode"
    f514_primary "$name" 1 || return 1
    f514_scalar "$F514_RESULTS/$name/writer.post-return" 0 || return 1
    printf 'KEEP_UNRELATED\n' > "$F514_RESULTS/$name/unrelated.expected"
    cmp "$F514_RESULTS/$name/unrelated.expected" "$F514_RESULTS/$name/unrelated.canary" || return 1
  done
  f514_scalar "$F514_RESULTS/sidecar-replaced-inode/cleanup.post-return" 0 || return 1
  local identity_compare_status=0
  cmp "$F514_RESULTS/sidecar-replaced-inode/original.result.identity" "$F514_RESULTS/sidecar-replaced-inode/replacement.result.identity" || identity_compare_status=$?
  [[ "$identity_compare_status" == 1 ]] || return 1
  f514_scalar "$F514_RESULTS/sidecar-replaced-workspace/cleanup.post-return" 1 || return 1
  cmp "$F514_RESULTS/sidecar-replaced-workspace/foreign.before.identity" "$F514_RESULTS/sidecar-replaced-workspace/foreign.after.identity" || return 1
  printf 'KEEP_FOREIGN_WORKSPACE\n' > "$F514_RESULTS/sidecar-replaced-workspace/foreign.expected"
  cmp "$F514_RESULTS/sidecar-replaced-workspace/foreign.expected" "$F514_RESULTS/sidecar-replaced-workspace/foreign.after.bytes" || return 1
}

@test "dev sidecar companions: cleanup faults preserve primary stops and interruptions prevent later gates" {
  local code name expected
  for code in 0 17 124 130 143; do
    name="sidecar-cleanup-$code"
    f514_sidecar_cell "$name" cleanup-failure "$code" || return 1
    f514_collect aggregate
  done
  for code in 130 143; do
    name="sidecar-stop-$code"
    f514_sidecar_cell "$name" aggregate-stop "$code" || return 1
    : > "$F514_CELL/project/app.py"
    f514_collect aggregate
  done
  for code in 0 17 124 130 143; do
    name="sidecar-cleanup-$code"
    if [[ "$code" == 0 ]]; then expected=1; else expected="$code"; fi
    f514_primary "$name" "$expected" || return 1
    f514_scalar "$F514_RESULTS/$name/payload.post-return" "$code" || return 1
    f514_scalar "$F514_RESULTS/$name/writer.post-return" 0 || return 1
    f514_scalar "$F514_RESULTS/$name/cleanup.post-return" 0 || return 1
    grep -Fxq MODELED_CLEANUP_RETURN_17 "$F514_RESULTS/$name/cleanup.configured-site" || return 1
  done
  for code in 130 143; do
    name="sidecar-stop-$code"
    f514_primary "$name" "$code" || return 1
    f514_scalar "$F514_RESULTS/$name/payload.post-return" "$code" || return 1
    [[ ! -e "$F514_RESULTS/$name/later.reached" && ! -L "$F514_RESULTS/$name/later.reached" ]] || return 1
    grep -Fq 'not run' "$F514_RESULTS/$name/primary.stderr" || return 1
  done
}
