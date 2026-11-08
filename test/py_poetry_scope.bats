#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  export PY_POETRY_REAL_PYTHON
  PY_POETRY_REAL_PYTHON=$(type -P python3)
  load test_helper
  export PY_POETRY_PROJECT="$HOME/project" PY_POETRY_LOG="$TEST_TEMP_DIR/poetry.calls"
  export PY_POETRY_VERSION=1.8.5 PY_POETRY_STATUS=0 PY_POETRY_PROBE_STATUS=0
  mkdir -p "$PY_POETRY_PROJECT/.venv/bin" "$HOME/foreign/.venv/bin"
  printf '[tool.poetry]\nname = "demo"\nversion = "1.0.0"\n' >"$PY_POETRY_PROJECT/pyproject.toml"
  printf 'lock-version = "2.0"\n' >"$PY_POETRY_PROJECT/poetry.lock"
  printf 'version = 3.12.1\n' >"$PY_POETRY_PROJECT/.venv/pyvenv.cfg"
  printf '#!/usr/bin/env bash\nexit 97\n' >"$PY_POETRY_PROJECT/.venv/bin/python"
  chmod -- 755 "$PY_POETRY_PROJECT/.venv/bin/python"
  printf 'foreign environment\n' >"$HOME/foreign/.venv/marker"
  cat >"$TEST_MOCK_BIN/python3" <<'EOF'
#!/usr/bin/env bash
[[ "$HOME" == "$TEST_TEMP_DIR/home" && "${1:-}" == -B && "${2:-}" == -I \
  && "${3:-}" == -S && "${4:-}" == -c ]] || exit 97
exec "$PY_POETRY_REAL_PYTHON" "$@"
EOF
  cat >"$TEST_MOCK_BIN/poetry" <<'EOF'
#!/usr/bin/env bash
[[ "$HOME" == "$TEST_TEMP_DIR/home" ]] || exit 96
root="$PWD"
original=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-plugins|--no-interaction) shift ;;
    --directory) root="$2"; shift 2 ;;
    *) break ;;
  esac
done
case "$*" in
  --version) printf 'Poetry (version %s)\n' "$PY_POETRY_VERSION"; exit "$PY_POETRY_PROBE_STATUS" ;;
  'env info --path')
    printf observed >>"$HOME/environment-observed"
    printf '%s\n' "${PY_POETRY_SELECTED_ENV:-$root/.venv}"; exit "$PY_POETRY_PROBE_STATUS" ;;
  'add ruff'|'add --group dev ruff'|'remove ruff') ;;
  *) exit 97 ;;
esac
{
  printf 'argv'; printf '\t%s' "${original[@]}"; printf '\n'
  printf 'cwd\t%s\nroot\t%s\nvenv\t%s\n' "$PWD" "$root" "${VIRTUAL_ENV-unset}"
  printf 'active\t%s\ncreate\t%s\ninproject\t%s\n' \
    "${POETRY_ACTIVE-unset}" "${POETRY_VIRTUALENVS_CREATE-unset}" "${POETRY_VIRTUALENVS_IN_PROJECT-unset}"
  printf 'selectors\t%s\t%s\t%s\t%s\t%s\n' "${POETRY_CONFIG_DIR-unset}" \
    "${POETRY_VIRTUALENVS_PATH-unset}" "${CONDA_PREFIX-unset}" "${PYTHONHOME-unset}" \
    "${__PYVENV_LAUNCHER__-unset}"
} >>"$PY_POETRY_LOG"
exit "$PY_POETRY_STATUS"
EOF
  cat >"$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
[[ "$HOME" == "$TEST_TEMP_DIR/home" ]] || exit 96
printf '%s\n' "$*" >>"$TEST_TEMP_DIR/uv.calls"
exit 0
EOF
  chmod -- 755 "$TEST_MOCK_BIN/python3" "$TEST_MOCK_BIN/poetry" "$TEST_MOCK_BIN/uv"
}

teardown() { cleanup_sandbox; }

run_poetry_zsh() {
  run_zsh '
    source "$ZSH_CUSTOM/functions/py-menu.zsh" || return 98
    cd "$PY_POETRY_PROJECT" || return 97
  '"$1"
}

@test "py Poetry scope: mutations bind the reviewed project and local environment" {
  run run_poetry_zsh '
    export VIRTUAL_ENV="$HOME/foreign/.venv" CONDA_PREFIX="$HOME/foreign/.venv"
    export PYTHONHOME="$HOME/foreign" POETRY_ACTIVE=1
    export __PYVENV_LAUNCHER__="$HOME/foreign/python"
    export POETRY_CONFIG_DIR="$HOME/foreign" POETRY_VIRTUALENVS_PATH="$HOME/foreign"
    package-install ruff --yes
  '
  [ "$status" -eq 0 ]
  grep -Fq -- "$(printf 'argv\t--no-plugins\t--no-interaction\t--directory\t%s\tadd\truff' "$PY_POETRY_PROJECT")" "$PY_POETRY_LOG"
  grep -Fxq "$(printf 'venv\t%s/.venv' "$PY_POETRY_PROJECT")" "$PY_POETRY_LOG"
  grep -Fxq $'active\tunset' "$PY_POETRY_LOG"
  grep -Fxq $'create\tfalse' "$PY_POETRY_LOG"
  grep -Fxq $'inproject\ttrue' "$PY_POETRY_LOG"
  grep -Fxq $'selectors\tunset\tunset\tunset\tunset\tunset' "$PY_POETRY_LOG"
  [ "$(cat "$HOME/foreign/.venv/marker")" = 'foreign environment' ]
}

@test "py Poetry scope: dry run names the canonical local environment and interpreter" {
  run run_poetry_zsh 'package-install ruff --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Environment"*".venv"*"Interpreter"*"bin/python"* ]]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py Poetry scope: missing local environment never falls through to a cached or system Python" {
  rm -rf "$PY_POETRY_PROJECT/.venv"
  run run_poetry_zsh 'package-install ruff --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$PY_POETRY_LOG" ]
  [[ "$output" == *".venv"* ]]
}

@test "py Poetry scope: local configuration appearing after confirmation is refused" {
  run run_poetry_zsh '
    _py_confirm_ask() { print -r -- "[virtualenvs]" >poetry.toml; return 0; }
    package-install ruff
  '
  [ "$status" -eq 1 ]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py Poetry scope: replacing the selected interpreter after confirmation blocks mutation" {
  run run_poetry_zsh '
    _py_confirm_ask() {
      command cp .venv/bin/python .venv/bin/replacement
      command mv .venv/bin/replacement .venv/bin/python
      return 0
    }
    package-uninstall ruff
  '
  [ "$status" -eq 1 ]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py Poetry scope: late capture cwd drift cannot redirect the Poetry command" {
  run run_poetry_zsh '
    functions[_py_poetry_original_capture]=$functions[_py_run_captured]
    _py_run_captured() { builtin cd -q "$HOME/foreign" || return; _py_poetry_original_capture "$@"; }
    package-install ruff --yes
  '
  [ "$status" -eq 0 ]
  grep -Fxq "$(printf 'cwd\t%s' "$PY_POETRY_PROJECT")" "$PY_POETRY_LOG"
  grep -Fxq "$(printf 'root\t%s' "$PY_POETRY_PROJECT")" "$PY_POETRY_LOG"
}

@test "py Poetry scope: old or unparseable Poetry versions never mutate" {
  local version
  for version in 1.7.1 unknown; do
    export PY_POETRY_VERSION="$version"
    run run_poetry_zsh 'package-install ruff --yes'
    [ "$status" -eq 1 ]
    [ ! -e "$PY_POETRY_LOG" ]
  done
}

@test "py Poetry scope: a Poetry-selected foreign environment fails closed" {
  export PY_POETRY_SELECTED_ENV="$HOME/foreign/.venv"
  run run_poetry_zsh 'package-install ruff --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py Poetry scope: malformed Poetry and tool tables never select uv" {
  local metadata
  for metadata in $'[tool]\npoetry = "broken"' $'[tool]\npoetry = 1' 'tool = "broken"'; do
    printf '%s\n' "$metadata" >"$PY_POETRY_PROJECT/pyproject.toml"
    rm -f "$PY_POETRY_PROJECT/poetry.lock"
    run run_poetry_zsh 'package-install ruff --dry-run'
    [ "$status" -eq 1 ]
    [[ "$output" != *"uv project"* ]]
    [ ! -e "$TEST_TEMP_DIR/uv.calls" ]
  done
}

@test "py package names: archive operands are rejected before any backend or metadata probe" {
  run run_poetry_zsh '
    _py_check_command() { print probe >>"$HOME/name-probes"; return 99; }
    _py_detect_package_backend() { print probe >>"$HOME/name-probes"; return 99; }
    local name operand
    for name in package-install package-uninstall package-search tool-install tool-uninstall tool-upgrade; do
      for operand in demo.whl demo.zip demo.tar demo.tar.gz demo.tgz demo.tar.bz2 demo.tbz demo.tar.xz demo.txz demo.tlz demo.tar.lz demo.tar.lzma; do
        "$name" "$operand"; [[ $? == 2 ]] || return 91
      done
    done
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/name-probes" ]
}

@test "py package names: Unicode trailing separators and newlines are rejected before probes" {
  run run_poetry_zsh '
    _py_check_command() { print probe >>"$HOME/name-probes"; return 99; }
    _py_detect_package_backend() { print probe >>"$HOME/name-probes"; return 99; }
    local name operand
    for name in package-install package-uninstall package-search tool-install tool-uninstall tool-upgrade; do
      for operand in réquests ｒequests requests- requests_ requests. $'"'"'requests\n'"'"'; do
        "$name" "$operand"; [[ $? == 2 ]] || return 91
      done
    done
  '
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/name-probes" ]
}

@test "py Poetry scope: development install and uninstall keep exact argv and caller state" {
  run run_poetry_zsh '
    export VIRTUAL_ENV="$HOME/foreign/.venv" POETRY_ACTIVE=1
    package-install ruff --dev --yes >"$HOME/scope.stdout" 2>"$HOME/scope.stderr" || return
    [[ "$VIRTUAL_ENV" == "$HOME/foreign/.venv" && "$POETRY_ACTIVE" == 1 ]] || return 91
    package-uninstall ruff --yes >>"$HOME/scope.stdout" 2>>"$HOME/scope.stderr" || return
    [[ "$VIRTUAL_ENV" == "$HOME/foreign/.venv" && "$POETRY_ACTIVE" == 1 ]] || return 92
  '
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/scope.stdout" ]
  grep -Fq -- "$(printf 'argv\t--no-plugins\t--no-interaction\t--directory\t%s\tadd\t--group\tdev\truff' "$PY_POETRY_PROJECT")" "$PY_POETRY_LOG"
  grep -Fq -- "$(printf 'argv\t--no-plugins\t--no-interaction\t--directory\t%s\tremove\truff' "$PY_POETRY_PROJECT")" "$PY_POETRY_LOG"
}

@test "py Poetry scope: late metadata changes inside capture are refused before delegation" {
  run run_poetry_zsh '
    functions[_py_poetry_original_capture]=$functions[_py_run_captured]
    _py_run_captured() {
      print -r -- "# late change" >>poetry.lock
      _py_poetry_original_capture "$@"
    }
    package-install ruff --yes
  '
  [ "$status" -eq 1 ]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py Poetry scope: backend failures and readonly probe interruptions retain status" {
  local code
  for code in 7 130 143; do
    export PY_POETRY_STATUS="$code"
    run run_poetry_zsh 'package-uninstall ruff --yes'
    [ "$status" -eq "$code" ]
  done
  export PY_POETRY_STATUS=0
  for code in 130 143; do
    export PY_POETRY_PROBE_STATUS="$code"
    run run_poetry_zsh 'package-install ruff --yes'
    [ "$status" -eq "$code" ]
  done
}

@test "py Poetry scope: declined review and noninteractive execution never mutate" {
  run run_poetry_zsh '_py_confirm_ask() { return 1; }; package-install ruff'
  [ "$status" -eq 0 ]
  run run_poetry_zsh 'package-uninstall ruff'
  [ "$status" -eq 1 ]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py Poetry scope: postconfirmation environment selection drift fails closed" {
  run run_poetry_zsh '
    _py_confirm_ask() { export PY_POETRY_SELECTED_ENV="$HOME/foreign/.venv"; return 0; }
    package-install ruff
  '
  [ "$status" -eq 1 ]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py package names: ordinary ASCII names keep internal punctuation and caller locale" {
  run run_poetry_zsh '
    local original_locale="${LC_ALL-unset}" name
    MATCH=caller; MBEGIN=7; MEND=9
    for name in ruff R2 a a.b a_b a-b foo..bar; do
      _py_validate_package_name "$name" || return 91
    done
    [[ "${LC_ALL-unset}" == "$original_locale" && "$MATCH" == caller && "$MBEGIN" == 7 && "$MEND" == 9 ]] || return 92
  '
  [ "$status" -eq 0 ]
}

@test "py Poetry scope: dry run and declined review never execute environment observations" {
  run run_poetry_zsh 'package-install ruff --dry-run'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/environment-observed" ]
  run run_poetry_zsh '_py_confirm_ask() { return 1; }; package-uninstall ruff'
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/environment-observed" ]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py Poetry scope: cfg lock program and PATH changes after confirmation are refused" {
  mkdir "$HOME/shadow"
  cp "$TEST_MOCK_BIN/poetry" "$HOME/shadow/poetry"
  local change
  for change in cfg uv-lock program path; do
    export PY_POETRY_REVIEW_CHANGE="$change"
    run run_poetry_zsh '
      _py_confirm_ask() {
        case "$PY_POETRY_REVIEW_CHANGE" in
          cfg) print -r -- "version = 3.12.2" >.venv/pyvenv.cfg ;;
          uv-lock) print -r -- "version = 1" >uv.lock ;;
          program) print -r -- "# changed" >>"$TEST_MOCK_BIN/poetry" ;;
          path) path=("$HOME/shadow" "${path[@]}") ;;
        esac
        return 0
      }
      package-install ruff
    '
    [ "$status" -eq 1 ]
    [ ! -e "$PY_POETRY_LOG" ]
  done
}

@test "py Poetry scope: compatible version two retains a passive reviewed plan" {
  export PY_POETRY_VERSION=2.1.4
  run run_poetry_zsh 'package-uninstall ruff --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Poetry (version 2.1.4)"* ]]
  [ ! -e "$HOME/environment-observed" ]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py Poetry scope: valid uv project package changes retain their scoped backend" {
  printf '[project]\nname = "demo"\nversion = "1.0.0"\n' >"$PY_POETRY_PROJECT/pyproject.toml"
  rm "$PY_POETRY_PROJECT/poetry.lock"
  run run_poetry_zsh 'package-install ruff --dev --yes && package-uninstall ruff --yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TEMP_DIR/uv.calls")" = "$(printf -- '--directory %s --project %s add --dev ruff\n--directory %s --project %s remove ruff' "$PY_POETRY_PROJECT" "$PY_POETRY_PROJECT" "$PY_POETRY_PROJECT" "$PY_POETRY_PROJECT")" ]
  [ ! -e "$PY_POETRY_LOG" ]
}

@test "py Poetry scope: environment pip remains bound to its own interpreter" {
  rm "$PY_POETRY_PROJECT/pyproject.toml" "$PY_POETRY_PROJECT/poetry.lock" "$TEST_MOCK_BIN/uv"
  cat >"$PY_POETRY_PROJECT/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
[[ "$HOME" == "$TEST_TEMP_DIR/home" ]] || exit 96
case "$*" in '-I -m pip install -- ruff'|'-I -m pip uninstall -y -- ruff') ;; *) exit 97 ;; esac
printf '%s\n' "$*" >>"$TEST_TEMP_DIR/environment-pip.calls"
EOF
  chmod -- 755 "$PY_POETRY_PROJECT/.venv/bin/python"
  run run_poetry_zsh '
    local name program
    for name in bash zsh env cksum head tail cat wc date find mktemp mkdir rmdir rm mv chmod ps sleep timeout gtimeout awk sed grep tr cut sort; do
      [[ -e "$TEST_MOCK_BIN/$name" ]] && continue
      program=$(whence -p "$name" 2>/dev/null) || continue
      command ln -s "$program" "$TEST_MOCK_BIN/$name" || return 91
    done
    path=("$TEST_MOCK_BIN")
    package-install ruff --yes && package-uninstall ruff --yes
  '
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TEMP_DIR/environment-pip.calls")" = $'-I -m pip install -- ruff\n-I -m pip uninstall -y -- ruff' ]
  [ ! -e "$PY_POETRY_LOG" ]
}
