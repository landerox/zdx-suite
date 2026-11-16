#!/usr/bin/env bats
# Finite metadata and installed-package inventory controls.
# shellcheck disable=SC2016

setup() {
  load test_helper
  export F514M_ROOT="$HOME/f514-metadata"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  mkdir -m 700 -p "$F514M_ROOT" "$TMPDIR"
  unset F514M_REAL_PYTHON F514M_PARSER_MODE F514M_UV_RETURN
  {
    printf '#!%s\n' "$BASH"
    cat <<'SH'
printf '%s\0' "$0" "$@" >> "$F514M_SCENE/uv-denied.argv.nul"
printf 'UNEXPECTED_UV_FINDER_DENIED\n' >> "$F514M_SCENE/uv-denied.configured-site"
exit 97
SH
  } > "$TEST_MOCK_BIN/uv"
  chmod -- 700 "$TEST_MOCK_BIN/uv"
  export F514M_COMMON="$F514M_ROOT/common.zsh"
  cat > "$F514M_COMMON" <<'ZSH'
builtin source "$TEST_SUITE_ROOT/functions/dev-menu.zsh" || return 95
builtin cd -- "$F514M_SCENE/project" || return 95
# Preserve the harness command wrapper before real metadata qualification.
# -B is a harness-only addition; original and forwarded argv stay distinct.
functions[_f514m_command]="${functions[command]}"
command() {
  local program_name="${${1-}:t}"
  if [[ "$program_name" == python3 || "$program_name" == python3.<-> ]]; then
    builtin printf '%s\0' "$@" >> "$F514M_SCENE/qualification.original.argv.nul"
    local -a forwarded=("$1" -B "${@:2}")
    builtin printf '%s\0' "${forwarded[@]}" >> "$F514M_SCENE/qualification.forwarded.argv.nul"
    _f514m_command "${forwarded[@]}"
    local -i observed=$?
    print -r -- "$observed" >> "$F514M_SCENE/qualification.post-return"
    return $observed
  fi
  if [[ "${1-}" == uv ]]; then
    _f514m_command "$@"
    local -i observed=$?
    print -r -- "$observed" >> "$F514M_SCENE/uv.post-return"
    return $observed
  fi
  _f514m_command "$@"
}
_dev_python_toml_resolve || return 96
export F514M_REAL_PYTHON="$REPLY"
print -r -- "$F514M_REAL_PYTHON" > "$F514M_SCENE/metadata.selected"
_dev_python_toml_resolve() { REPLY="$F514M_ROOT/metadata-python"; return 0; }
ZSH
  {
    printf '#!%s\n' "$BASH"
    cat <<'SH'
printf '%s\0' "$0" "$@" > "$F514M_SCENE/metadata.argv.nul"
[[ $# -ge 3 && "$1" == -I && "$2" == -S && "$3" == -c ]] || exit 97
if [[ "${F514M_PARSER_MODE-}" == swap ]]; then
  [[ "$PWD" == "$F514M_SCENE/project" && -f pyproject.toml && ! -L pyproject.toml ]] || exit 98
  mv -- pyproject.toml original.toml || exit 98
  ln -s ../shared.toml pyproject.toml || exit 98
  printf 'SYMLINK_REPLACEMENT_BEFORE_READER\n' > "$F514M_SCENE/replacement.reached"
fi
# -B is harness-only: product argv above remains the exact -I -S request.
"$F514M_REAL_PYTHON" -B "$@"
observed=$?
printf '%s\n' "$observed" > "$F514M_SCENE/metadata.post-return"
exit "$observed"
SH
  } > "$F514M_ROOT/metadata-python"
  chmod -- 700 "$F514M_ROOT/metadata-python"
  {
    printf '#!%s\n' "$BASH"
    cat <<'SH'
[[ $# == 1 && "$1" == unconventional.py ]] || exit 97
printf '%s\0' "$0" "$@" > "$F514M_SCENE/pytest.argv.nul"
printf 'EXPLICIT_PYTEST_MODEL_REACHED\n' > "$F514M_SCENE/pytest.configured-site"
exit 0
SH
  } > "$F514M_ROOT/pytest-leaf"
  chmod -- 700 "$F514M_ROOT/pytest-leaf"
}

teardown() {
  cleanup_sandbox
}

f514m_scene() {
  export F514M_SCENE="$F514M_ROOT/$1"
  mkdir -m 700 -p "$F514M_SCENE/project"
}

f514m_launch() {
  run_zsh '
    _f514m_action() {
      builtin source "$F514M_COMMON" || return $?
      builtin source "$F514M_SCENE/action.zsh"
    }
    _f514m_action > "$F514M_SCENE/primary.stdout" 2> "$F514M_SCENE/primary.stderr"
    local -i observed=$?
    print -r -- "$observed" > "$F514M_SCENE/primary.status"
    return 0
  ' > "$F514M_SCENE/wrapper.stdout" 2> "$F514M_SCENE/wrapper.stderr"
}

f514m_observe() {
  local program="$1"
  printf '%s\n' "$program" > "$F514M_SCENE/action.zsh"
  run f514m_launch
  printf '%s\n' "$status" > "$F514M_SCENE/wrapper.status"
  printf '%s' "$output" > "$F514M_SCENE/wrapper.output"
}

f514m_scalar() {
  local target="$1" expected="$2"
  [[ -f "$target" && ! -L "$target" ]] || return 80
  printf '%s\n' "$expected" > "$target.expected" || return 80
  cmp "$target.expected" "$target" || return 80
}

f514m_primary() {
  local scene="$F514M_ROOT/$1" expected="$2"
  [[ -f "$scene/primary.status" && -f "$scene/primary.stdout" && -f "$scene/primary.stderr" ]] || return 81
  [[ -f "$scene/wrapper.status" && -f "$scene/wrapper.output" ]] || return 82
  [[ -f "$scene/wrapper.stdout" && -f "$scene/wrapper.stderr" ]] || return 83
  f514m_scalar "$scene/wrapper.status" 0 || return 83
  [[ ! -s "$scene/wrapper.output" && ! -s "$scene/wrapper.stdout" && ! -s "$scene/wrapper.stderr" ]] || return 83
  f514m_scalar "$scene/primary.status" "$expected" || return 84
}

f514m_no_stdout() {
  [[ -f "$F514M_ROOT/$1/primary.stdout" && ! -s "$F514M_ROOT/$1/primary.stdout" ]] || return 85
}

f514m_type_context() {
  : > "$F514M_SCENE/project/app.py"
  {
    printf '#!%s\n' "$BASH"
    cat <<'SH'
printf '%s\0' "$0" "$@" > "$F514M_SCENE/checker.argv.nul"
[[ ( $# == 1 && "$1" == pyright ) || ( $# == 2 && "$1" == ty && "$2" == check ) ]] || exit 97
printf '%s\n' "$1" >> "$F514M_SCENE/checker.reached"
printf 'PRIVATE_CHECKER_OUTPUT\n'
exit 0
SH
  } > "$F514M_SCENE/checker"
  chmod -- 700 "$F514M_SCENE/checker"
  cat > "$F514M_SCENE/types.zsh" <<'ZSH'
_dev_python_tool_runner() {
  [[ "${1-}" == (ty|pyright) ]] || return 97
  reply=("$F514M_SCENE/checker" "$1")
  return 0
}
dev-run-ruff() { print -r -- ruff >> "$F514M_SCENE/gates.reached"; return 0; }
dev-run-bandit() { print -r -- bandit >> "$F514M_SCENE/gates.reached"; return 0; }
# The fallback availability decision is a finite model; no ambient checker runs.
functions[_f514m_have]="${functions[_dev_have_command]}"
_dev_have_command() {
  [[ "${1-}" != (ty|pyright) ]] || return 1
  _f514m_have "$@"
}
ZSH
}

@test "dev metadata: config-only Pyright participates in direct and aggregate plans" {
  local kind route name
  for kind in config linked-config absent declared malformed; do
    for route in direct aggregate; do
      name="types-$kind-$route"
      f514m_scene "$name"
      f514m_type_context
      case "$kind" in
        config) printf '{}\n' > "$F514M_SCENE/project/pyrightconfig.json" ;;
        linked-config)
          printf '{}\n' > "$F514M_SCENE/shared-pyright.json"
          ln -s ../shared-pyright.json "$F514M_SCENE/project/pyrightconfig.json"
          ;;
        declared) printf '[project]\ndependencies = ["ty"]\n' > "$F514M_SCENE/project/pyproject.toml" ;;
        malformed) printf '[project\n' > "$F514M_SCENE/project/pyproject.toml" ;;
      esac
      export F514M_ROUTE="$route" F514M_TYPE_KIND="$kind"
      f514m_observe '
        builtin source "$F514M_SCENE/types.zsh" || return $?
        if [[ "$F514M_ROUTE" == direct ]]; then dev-check-types; else dev-run-all-checks; fi
      '
    done
  done
  # All ten actions complete before the first expected regression assertion.
  for route in direct aggregate; do
    f514m_primary "types-config-$route" 0 || return $?
    f514m_no_stdout "types-config-$route" || return $?
    grep -Fxq pyright "$F514M_ROOT/types-config-$route/checker.reached" || return 86
    printf '%s\0' "$F514M_ROOT/types-config-$route/checker" pyright > "$F514M_ROOT/types-config-$route/checker.expected.nul"
    cmp "$F514M_ROOT/types-config-$route/checker.expected.nul" "$F514M_ROOT/types-config-$route/checker.argv.nul" || return 86
    f514m_primary "types-declared-$route" 0 || return $?
    grep -Fxq ty "$F514M_ROOT/types-declared-$route/checker.reached" || return 87
    printf '%s\0' "$F514M_ROOT/types-declared-$route/checker" ty check > "$F514M_ROOT/types-declared-$route/checker.expected.nul"
    cmp "$F514M_ROOT/types-declared-$route/checker.expected.nul" "$F514M_ROOT/types-declared-$route/checker.argv.nul" || return 87
    f514m_primary "types-malformed-$route" 1 || return $?
    f514m_scalar "$F514M_ROOT/types-malformed-$route/metadata.post-return" 2 || return 88
    [[ ! -e "$F514M_ROOT/types-malformed-$route/checker.reached" ]] || return 88
  done
  # Approved non-link policy companions, not original planner witnesses.
  f514m_primary types-linked-config-direct 1 || return $?
  f514m_primary types-linked-config-aggregate 0 || return $?
  for route in direct aggregate; do
    f514m_no_stdout "types-linked-config-$route" || return $?
    [[ ! -e "$F514M_ROOT/types-linked-config-$route/checker.reached" && ! -L "$F514M_ROOT/types-linked-config-$route/checker.reached" ]] || return 91
  done
  printf 'ruff\nbandit\n' > "$F514M_ROOT/types-linked-config-aggregate/gates.expected"
  cmp "$F514M_ROOT/types-linked-config-aggregate/gates.expected" "$F514M_ROOT/types-linked-config-aggregate/gates.reached" || return 91
  local type_heading_status=0
  grep -Fq 'Type checker' "$F514M_ROOT/types-linked-config-aggregate/primary.stderr" || type_heading_status=$?
  [[ "$type_heading_status" == 1 ]] || return 92
  f514m_primary types-absent-direct 1 || return $?
  f514m_primary types-absent-aggregate 0 || return $?
  for kind in config absent declared; do
    grep -Fxq ruff "$F514M_ROOT/types-$kind-aggregate/gates.reached" || return 89
    grep -Fxq bandit "$F514M_ROOT/types-$kind-aggregate/gates.reached" || return 90
  done
  [[ ! -e "$F514M_ROOT/types-absent-aggregate/checker.reached" ]] || return 91
  grep -Fq 'Type checker' "$F514M_ROOT/types-config-aggregate/primary.stderr" || return 92
}

@test "dev metadata: pytest configuration inspection refuses links and bounded read substitutions" {
  local kind expected
  for kind in absent ini linked-ini toml linked-toml dangling directory malformed precedence exact-limit over-limit swapped healthy-forward explicit-target; do
    f514m_scene "pytest-$kind"
    case "$kind" in
      ini) printf '[pytest]\n' > "$F514M_SCENE/project/pytest.ini" ;;
      linked-ini) printf '[pytest]\n' > "$F514M_SCENE/shared.ini"; ln -s ../shared.ini "$F514M_SCENE/project/pytest.ini" ;;
      toml|healthy-forward|swapped) printf '[tool.pytest.ini_options]\naddopts = "-q"\n' > "$F514M_SCENE/project/pyproject.toml" ;;
      linked-toml) printf '[project]\ndependencies = ["ty"]\n[tool.pytest.ini_options]\n' > "$F514M_SCENE/shared.toml"; ln -s ../shared.toml "$F514M_SCENE/project/pyproject.toml" ;;
      dangling) ln -s ../missing.ini "$F514M_SCENE/project/pytest.ini" ;;
      directory) mkdir "$F514M_SCENE/project/pytest.ini" ;;
      malformed) printf '[invalid\n' > "$F514M_SCENE/project/pyproject.toml" ;;
      precedence) printf '[pytest]\n' > "$F514M_SCENE/project/pytest.ini"; printf '[invalid\n' > "$F514M_SCENE/project/pyproject.toml" ;;
      exact-limit) make_sized_file "$F514M_SCENE/project/pytest.ini" 2097152 ;;
      over-limit) make_sized_file "$F514M_SCENE/project/pytest.ini" 2097153 ;;
      explicit-target) printf '[pytest]\n' > "$F514M_SCENE/shared.ini"; ln -s ../shared.ini "$F514M_SCENE/project/pytest.ini" ;;
    esac
    if [[ "$kind" == swapped ]]; then
      printf '[tool.pytest.ini_options]\naddopts = "-x"\n' > "$F514M_SCENE/shared.toml"
      file_identity "$F514M_SCENE/project/pyproject.toml" > "$F514M_SCENE/before.identity"
      sha256_file "$F514M_SCENE/project/pyproject.toml" > "$F514M_SCENE/before.sha256"
      sha256_file "$F514M_SCENE/shared.toml" > "$F514M_SCENE/shared.before.sha256"
      export F514M_PARSER_MODE=swap
    else
      unset F514M_PARSER_MODE
    fi
    export F514M_PYTEST_KIND="$kind"
    f514m_observe '
      if [[ "$F514M_PYTEST_KIND" == explicit-target ]]; then
        _dev_has_tests() { print -r -- FORBIDDEN_DISCOVERY > "$F514M_SCENE/discovery.reached"; return 2; }
        _dev_exact_project_python_tool_runner() { reply=("$F514M_ROOT/pytest-leaf"); return 0; }
        dev-run-tests unconventional.py
      else
        if [[ "$F514M_PYTEST_KIND" == linked-toml ]]; then
          _dev_pyproject_has_dep ty
          print -r -- "$?" > "$F514M_SCENE/dependency.primary.status"
        fi
        _dev_has_pytest_config
      fi
    '
  done
  # Observe replacement preservation before any expected baseline assertion.
  if [[ -f "$F514M_ROOT/pytest-swapped/project/original.toml" && ! -L "$F514M_ROOT/pytest-swapped/project/original.toml" ]]; then
    file_identity "$F514M_ROOT/pytest-swapped/project/original.toml" > "$F514M_ROOT/pytest-swapped/original.after.identity"
    sha256_file "$F514M_ROOT/pytest-swapped/project/original.toml" > "$F514M_ROOT/pytest-swapped/original.after.sha256"
    sha256_file "$F514M_ROOT/pytest-swapped/shared.toml" > "$F514M_ROOT/pytest-swapped/shared.after.sha256"
  fi
  for kind in absent ini toml healthy-forward precedence exact-limit linked-ini linked-toml dangling directory malformed over-limit swapped; do
    case "$kind" in absent) expected=1 ;; ini|toml|healthy-forward|precedence|exact-limit) expected=0 ;; *) expected=2 ;; esac
    f514m_primary "pytest-$kind" "$expected" || return $?
    f514m_no_stdout "pytest-$kind" || return $?
  done
  f514m_scalar "$F514M_ROOT/pytest-linked-toml/dependency.primary.status" 2 || return 93
  [[ ! -e "$F514M_ROOT/pytest-precedence/metadata.argv.nul" ]] || return 93
  f514m_primary pytest-explicit-target 0 || return $?
  printf '%s\0' "$F514M_ROOT/pytest-leaf" unconventional.py > "$F514M_ROOT/pytest-explicit-target/pytest.expected.nul"
  cmp "$F514M_ROOT/pytest-explicit-target/pytest.expected.nul" "$F514M_ROOT/pytest-explicit-target/pytest.argv.nul" || return 93
  [[ ! -e "$F514M_ROOT/pytest-explicit-target/discovery.reached" ]] || return 93
  [[ -f "$F514M_ROOT/pytest-swapped/replacement.reached" && -L "$F514M_ROOT/pytest-swapped/project/pyproject.toml" ]] || return 94
  cmp "$F514M_ROOT/pytest-swapped/before.identity" "$F514M_ROOT/pytest-swapped/original.after.identity" || return 95
  cmp "$F514M_ROOT/pytest-swapped/before.sha256" "$F514M_ROOT/pytest-swapped/original.after.sha256" || return 95
  cmp "$F514M_ROOT/pytest-swapped/shared.before.sha256" "$F514M_ROOT/pytest-swapped/shared.after.sha256" || return 95
  f514m_scalar "$F514M_ROOT/pytest-swapped/metadata.post-return" 2 || return 95
  f514m_scalar "$F514M_ROOT/pytest-healthy-forward/metadata.post-return" 0 || return 96
}

f514m_outdated_context() {
  mkdir -p "$F514M_SCENE/project/.venv/bin"
  printf '[project]\nname = "metadata-fixture"\ndependencies = ["package>=1", "requests>=2"]\n' > "$F514M_SCENE/project/pyproject.toml"
  {
    printf '#!%s\n' "$BASH"
    cat <<'SH'
printf '%s\0' "$0" "$@" > "$F514M_SCENE/project-python.argv.nul"
[[ $# == 4 && "$1" == -I && "$2" == -c && "$4" == "$F514M_SCENE/project/.venv" ]] || exit 97
[[ "$3" == *sys.prefix* && "$3" == *sys.base_prefix* ]] || exit 97
printf 'PREFIX_PROTOCOL_MODEL_REACHED\n' > "$F514M_SCENE/project-python.configured-site"
exit 0
SH
  } > "$F514M_SCENE/project/.venv/bin/python"
  chmod -- 700 "$F514M_SCENE/project/.venv/bin/python"
  {
    printf '#!%s\n' "$BASH"
    cat <<'SH'
printf '%s\0' "$0" "$@" > "$F514M_SCENE/uv.argv.nul"
printf '%s\n' "${UV_SYSTEM_PYTHON-unset}" > "$F514M_SCENE/uv.system-python"
# Exact six arguments; reject joined, missing, additional or selected-neighbor paths.
[[ $# == 6 && "$1" == pip && "$2" == list && "$3" == --python && "$4" == "$F514M_SCENE/project/.venv/bin/python" && "$5" == --outdated && "$6" == --format=columns && "${UV_SYSTEM_PYTHON-}" == 0 ]] || exit 97
cat -- "$F514M_SCENE/uv.data" || exit 97
printf 'UV_CONFIGURED_RETURN_SITE_%s\n' "${F514M_UV_RETURN:-0}" > "$F514M_SCENE/uv.configured-site"
exit "${F514M_UV_RETURN:-0}"
SH
  } > "$TEST_MOCK_BIN/uv"
  chmod -- 700 "$TEST_MOCK_BIN/uv"
}

@test "dev metadata: outdated columns exclude headers while retaining a distribution named package" {
  local kind expected
  for kind in header-only requests real-package empty failed-empty failed-partial report-failure; do
    f514m_scene "outdated-$kind"
    f514m_outdated_context
    case "$kind" in
      header-only|report-failure) printf 'Package Version Latest Type\n------- ------- ------ ----\n' > "$F514M_SCENE/uv.data" ;;
      requests|failed-partial) printf 'Package Version Latest Type\n------- ------- ------ ----\nrequests 2.0 3.0 wheel\n' > "$F514M_SCENE/uv.data" ;;
      real-package) printf 'Package Version Latest Type\n------- ------- ------ ----\npackage 1.0 2.0 wheel\nrequests 2.0 3.0 wheel\n' > "$F514M_SCENE/uv.data" ;;
      empty|failed-empty) : > "$F514M_SCENE/uv.data" ;;
    esac
    if [[ "$kind" == failed-* ]]; then export F514M_UV_RETURN=17; else unset F514M_UV_RETURN; fi
    export F514M_OUTDATED_KIND="$kind"
    f514m_observe '
      _dev_require_venv
      local -i qualification=$?
      print -r -- "$qualification" > "$F514M_SCENE/project-python.qualification.status"
      (( qualification == 0 )) || return $qualification
      if [[ "$F514M_OUTDATED_KIND" == report-failure ]]; then
        _dev_report_save() { print -r -- REPORT_SAVE_REACHED > "$F514M_SCENE/report.reached"; return 1; }
        dev-check-outdated --report
      else
        dev-check-outdated
      fi
    '
  done
  for kind in header-only requests real-package empty failed-empty failed-partial report-failure; do
    case "$kind" in failed-empty|failed-partial|report-failure) expected=1 ;; *) expected=0 ;; esac
    f514m_primary "outdated-$kind" "$expected" || return $?
    [[ -f "$F514M_ROOT/outdated-$kind/project-python.configured-site" ]] || return 97
    f514m_scalar "$F514M_ROOT/outdated-$kind/project-python.qualification.status" 0 || return 97
    printf '%s\0' "$TEST_MOCK_BIN/uv" pip list --python "$F514M_ROOT/outdated-$kind/project/.venv/bin/python" --outdated --format=columns > "$F514M_ROOT/outdated-$kind/uv.expected.nul"
    cmp "$F514M_ROOT/outdated-$kind/uv.expected.nul" "$F514M_ROOT/outdated-$kind/uv.argv.nul" || return 97
    [[ "$(cat "$F514M_ROOT/outdated-$kind/uv.system-python")" == 0 ]] || return 98
    if [[ "$kind" == failed-* ]]; then expected=17; else expected=0; fi
    f514m_scalar "$F514M_ROOT/outdated-$kind/uv.post-return" "$expected" || return 99
  done
  f514m_no_stdout outdated-header-only || return $?
  f514m_no_stdout outdated-empty || return $?
  f514m_no_stdout outdated-failed-empty || return $?
  f514m_no_stdout outdated-failed-partial || return $?
  printf 'requests 2.0 3.0 wheel\n' > "$F514M_ROOT/requests.expected"
  cmp "$F514M_ROOT/requests.expected" "$F514M_ROOT/outdated-requests/primary.stdout" || return 100
  printf 'package 1.0 2.0 wheel\nrequests 2.0 3.0 wheel\n' > "$F514M_ROOT/package.expected"
  cmp "$F514M_ROOT/package.expected" "$F514M_ROOT/outdated-real-package/primary.stdout" || return 101
  grep -Fq '1 direct dependency has newer versions' "$F514M_ROOT/outdated-requests/primary.stderr" || return 102
  grep -Fq '2 direct dependencies have newer versions' "$F514M_ROOT/outdated-real-package/primary.stderr" || return 103
  [[ -f "$F514M_ROOT/outdated-report-failure/report.reached" ]] || return 104
}
