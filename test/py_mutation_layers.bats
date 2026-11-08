#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  PY_LAYER_ORIGINAL_PATH="$PATH"
  export PY_LAYER_REAL_PYTHON
  PY_LAYER_REAL_PYTHON=$(type -P python3)
  load test_helper
  export PY_LAYER_PROJECT="$HOME/project"
  export PY_LAYER_LOG="$HOME/backend.calls" PY_LAYER_ENV="$HOME/backend.environment"
  export PY_LAYER_STATUS=0 PY_LAYER_INVENTORY_STATUS=0 PY_LAYER_PIN_WRITE=1
  export PY_LAYER_INVENTORY_PARTIAL=0
  export PY_LAYER_NETWORK_MODE=valid
  mkdir -m 700 "$PY_LAYER_PROJECT" "$HOME/unrelated-environment" "$HOME/tools"
  printf 'preserve environment\n' >"$HOME/unrelated-environment/marker"
  mkdir "$HOME/tools/uv" "$HOME/tools/pipx"
  printf 'ruff\n' >"$HOME/tools/uv/ruff"
  printf 'ruff\n' >"$HOME/tools/pipx/ruff"
  printf 'preserve tool\n' >"$HOME/tools/uv/other"
  printf 'preserve tool\n' >"$HOME/tools/pipx/other"
  : >"$PY_LAYER_LOG"
  # run_py_layer_zsh uses only this directory. Absent managers cannot fall
  # through to the host; ordinary read-only filesystem tools remain real.
  local name resolved
  for name in bash zsh env uname hostname head tail cat wc cut tr sort find \
    date mktemp mkdir rmdir rm chmod mv cp ln touch awk sed grep id ps sleep \
    timeout gtimeout sha256sum shasum cksum basename dirname realpath; do
    [[ ! -e "$TEST_MOCK_BIN/$name" ]] || continue
    resolved=$(type -P "$name" || true)
    [[ -z "$resolved" ]] || ln -s "$resolved" "$TEST_MOCK_BIN/$name"
  done
  cat >"$TEST_MOCK_BIN/python3" <<'EOF'
#!/usr/bin/env bash
[[ "$HOME" == "$TEST_TEMP_DIR/home" ]] || exit 96
[[ "${1:-}" == -I && "${2:-}" == -c ]] || {
  printf 'refused ambient Python invocation\n' >>"$HOME/ambient-python"
  exit 97
}
exec "$PY_LAYER_REAL_PYTHON" -B -I "$@"
EOF
  chmod -- 755 "$TEST_MOCK_BIN/python3"
  export PY_LAYER_MODEL="$TEST_TEMP_DIR/backend-model"
  cat >"$PY_LAYER_MODEL" <<'EOF'
#!/usr/bin/env bash
backend="${0##*/}"
root="$PWD"
original=("$@")
[[ "$HOME" == "$TEST_TEMP_DIR/home" ]] || exit 96
{
  printf '%s' "$backend"
  printf '\t%s' "$@"
  printf '\n'
} >>"$HOME/backend.invocations"
if [[ "$backend" == uv && "${1:-}" == --directory ]]; then
  root="$2"; shift 2
  if [[ "${1:-}" == --project ]]; then
    [[ "$2" == "$root" ]] || exit 96
    shift 2
  fi
fi
if [[ "$backend" == poetry ]]; then
  [[ $# -ge 5 && "$1" == --no-plugins && "$2" == --no-interaction \
    && "$3" == --directory && "$4" == "$PY_LAYER_PROJECT" ]] || exit 96
  root="$4"; shift 4
  [[ "$PWD" == "$root" && "${VIRTUAL_ENV-unset}" == "$root/.venv" \
    && "${POETRY_VIRTUALENVS_CREATE-unset}" == false \
    && "${POETRY_VIRTUALENVS_IN_PROJECT-unset}" == true ]] || exit 96
  [[ "${POETRY_ACTIVE+x}" != x && "${POETRY_VIRTUALENVS_PATH+x}" != x \
    && "${POETRY_CONFIG_DIR+x}" != x && "${POETRY_CACHE_DIR+x}" != x \
    && "${POETRY_DATA_DIR+x}" != x && "${POETRY_HOME+x}" != x \
    && "${POETRY_PYTHON_INSTALLATION_DIR+x}" != x && "${CONDA_PREFIX+x}" != x \
    && "${CONDA_DEFAULT_ENV+x}" != x && "${PYTHONHOME+x}" != x \
    && "${PYTHONPATH+x}" != x && "${PYTHONUSERBASE+x}" != x \
    && "${__PYVENV_LAUNCHER__+x}" != x ]] || exit 96
fi
[[ "$root" == "$PY_LAYER_PROJECT" && "$HOME" == "$TEST_TEMP_DIR/home" ]] \
  || exit 96
[[ -d "$HOME" && ! -L "$HOME" && -O "$HOME" \
  && -d "$root" && ! -L "$root" && -O "$root" ]] || exit 96
safe_marker() {
  [[ ! -L "$1" ]] || return 1
  [[ -e "$1" ]] || return 0
  [[ -f "$1" && -O "$1" ]] || return 1
  zsh -f -c '
    emulate -R zsh
    zmodload -F zsh/stat b:zstat || exit 1
    local -A state=()
    zstat -LH state -- "$1" || exit 1
    (( state[uid] == EUID && state[nlink] == 1 ))
  ' _ "$1"
}
case "$backend:$*" in
  'poetry:--version') printf 'Poetry (version 1.8.5)\n'; exit 0 ;;
  'poetry:env info --path') printf '%s\n' "$root/.venv"; exit 0 ;;
  'uv:tool list'|'pipx:list --short')
    if [[ "$PY_LAYER_INVENTORY_PARTIAL" == 1 ]]; then
      printf 'ruff v1.0.0\n- ruff\n'
    fi
    [[ "$PY_LAYER_INVENTORY_STATUS" == 0 ]] || exit "$PY_LAYER_INVENTORY_STATUS"
    for tool in ruff other; do
      [[ -e "$HOME/tools/$backend/$tool" ]] || continue
      if [[ "$backend" == uv ]]; then
        printf '%s v1.0.0\n- %s\n' "$tool" "$tool"
      else
        printf '%s 1.0.0\n' "$tool"
      fi
    done
    exit 0 ;;
  'uv:python list '*) printf '[]\n'; exit 0 ;;
  'uv:python pin --no-project --no-python-downloads 3.12')
    safe_marker "$root/.python-version" || exit 96 ;;
  'uv:add ruff'|'uv:add --dev ruff'|'uv:remove ruff'|\
  "uv:pip install --python $PY_LAYER_PROJECT/.venv/bin/python ruff"|\
  "uv:pip uninstall --python $PY_LAYER_PROJECT/.venv/bin/python ruff"|\
  'poetry:add ruff'|'poetry:add --group dev ruff'|'poetry:remove ruff'|\
  'python:-I -m pip install -- ruff'|'python:-I -m pip uninstall -y -- ruff') ;;
  'uv:tool install ruff'|'uv:tool uninstall ruff'|'pipx:install ruff'|'pipx:uninstall ruff')
    for directory in "$HOME/tools" "$HOME/tools/$backend"; do
      [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || exit 96
    done
    safe_marker "$HOME/tools/$backend/ruff" || exit 96 ;;
  *) printf 'unexpected %s argv: %s\n' "$backend" "$*" >&2; exit 97 ;;
esac
{
  printf '%s' "$backend"
  printf '\t%s' "${original[@]}"
  printf '\n'
} >>"$PY_LAYER_LOG"
printf '%s|%s|%s|%s\n' "$PWD" "${UV_PROJECT-unset}" \
  "${UV_PROJECT_ENVIRONMENT-unset}" "${UV_WORKING_DIR-unset}" >>"$PY_LAYER_ENV"
[[ "$PY_LAYER_STATUS" == 0 ]] || exit "$PY_LAYER_STATUS"
case "$backend:$*" in
  'uv:python pin '*)
    [[ "$PY_LAYER_PIN_WRITE" == 1 ]] && printf '%s\n' "${!#}" >"$root/.python-version" ;;
  'uv:tool uninstall '*|'pipx:uninstall '*) rm -f "$HOME/tools/$backend/${!#}" ;;
  'uv:tool install '*|'pipx:install '*) printf 'installed\n' >"$HOME/tools/$backend/${!#}" ;;
esac
exit 0
EOF
  for name in uv poetry pipx; do
    cp "$PY_LAYER_MODEL" "$TEST_MOCK_BIN/$name"
    chmod -- 755 "$TEST_MOCK_BIN/$name"
  done
  cat >"$TEST_MOCK_BIN/pip" <<'EOF'
#!/usr/bin/env bash
[[ "$HOME" == "$TEST_TEMP_DIR/home" ]] || exit 96
printf 'ambient pip reached\n' >>"$HOME/ambient-pip"
exit 98
EOF
  cat >"$TEST_MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
previous=""; output=""
for argument in "$@"; do
  [[ "$previous" == --output ]] && output="$argument"
  previous="$argument"
done
[[ -n "$output" ]] || exit 97
[[ "$HOME" == "$TEST_TEMP_DIR/home" \
  && "$TMPDIR" == "$TEST_TEMP_DIR/tmpdir" \
  && "$output" == "$TMPDIR"/zdx-py-pypi.*/response.json ]] || exit 96
response_parent="${output%/*}"
response_component="${response_parent#"$TMPDIR/"}"
[[ "$response_component" == zdx-py-pypi.* && "$response_component" != */* \
  && -d "$response_parent" && ! -L "$response_parent" && -O "$response_parent" \
  && -f "$output" && ! -L "$output" && -O "$output" \
  && "${!#}" == https://pypi.org/pypi/demo/json ]] || exit 96
zsh -f -c '
  emulate -R zsh
  zmodload -F zsh/stat b:zstat || exit 1
  local -A directory=() response=()
  zstat -LH directory -- "$1" && zstat -LH response -- "$2" || exit 1
  (( directory[uid] == EUID && (directory[mode] & 8#77) == 0 \
    && response[uid] == EUID && response[nlink] == 1 \
    && (response[mode] & 8#77) == 0 ))
' _ "$response_parent" "$output" || exit 96
printf '%s\n' "$*" >>"$HOME/curl.calls"
case "$PY_LAYER_NETWORK_MODE" in
  valid) printf '{"info":{"name":"demo","version":"1.2.3","summary":"fixture"}}' >"$output" ;;
  malformed) printf '{"info":' >"$output" ;;
  oversized) cat "$HOME/oversized-response" >"$output" ;;
  offline) printf 'partial body' >"$output"; exit 6 ;;
  http) printf 'partial body' >"$output"; exit 22 ;;
  timeout) printf 'partial body' >"$output"; exit 28 ;;
  *) exit 97 ;;
esac
EOF
  chmod -- 755 "$TEST_MOCK_BIN/pip" "$TEST_MOCK_BIN/curl"
}

teardown() {
  PATH="$PY_LAYER_ORIGINAL_PATH"
  hash -r
  cleanup_sandbox
}

run_py_layer_zsh() {
  run_zsh '
    path=("$TEST_MOCK_BIN")
    unfunction command
    source "$ZSH_CUSTOM/functions/py-menu.zsh" || return 98
    cd "$PY_LAYER_PROJECT" || return 97
  '"$1"
}

make_package_layer() {
  rm -f "$PY_LAYER_PROJECT/pyproject.toml" "$PY_LAYER_PROJECT/uv.lock" \
    "$PY_LAYER_PROJECT/poetry.lock"
  case "$1" in
    uv-project)
      printf '[project]\nname = "demo"\nversion = "1.0.0"\n' >"$PY_LAYER_PROJECT/pyproject.toml"
      printf 'version = 1\n' >"$PY_LAYER_PROJECT/uv.lock" ;;
    poetry-project)
      printf '[tool.poetry]\nname = "demo"\nversion = "1.0.0"\n' >"$PY_LAYER_PROJECT/pyproject.toml"
      printf 'lock-version = "2.0"\n' >"$PY_LAYER_PROJECT/poetry.lock"
      mkdir -p "$PY_LAYER_PROJECT/.venv/bin"
      printf 'version = 3.12.1\n' >"$PY_LAYER_PROJECT/.venv/pyvenv.cfg"
      cp "$PY_LAYER_MODEL" "$PY_LAYER_PROJECT/.venv/bin/python"
      chmod -- 755 "$PY_LAYER_PROJECT/.venv/bin/python" ;;
    uv-environment|python-environment)
      mkdir -p "$PY_LAYER_PROJECT/.venv/bin"
      printf 'version = 3.12.1\n' >"$PY_LAYER_PROJECT/.venv/pyvenv.cfg"
      cp "$PY_LAYER_MODEL" "$PY_LAYER_PROJECT/.venv/bin/python"
      chmod -- 755 "$PY_LAYER_PROJECT/.venv/bin/python"
      [[ "$1" != python-environment ]] || rm "$TEST_MOCK_BIN/uv" ;;
  esac
}

assert_unrelated_preserved() {
  [ "$(cat "$HOME/unrelated-environment/marker")" = 'preserve environment' ]
  [ "$(cat "$HOME/tools/uv/other")" = 'preserve tool' ]
  [ "$(cat "$HOME/tools/pipx/other")" = 'preserve tool' ]
  [ ! -e "$HOME/ambient-pip" ]
  [ ! -e "$HOME/ambient-python" ]
}

@test "py layers: pin success uses the reviewed root and disables uv discovery" {
  run run_py_layer_zsh '
    export UV_PROJECT="$HOME/elsewhere" UV_PROJECT_ENVIRONMENT="$HOME/elsewhere/.venv" UV_WORKING_DIR="$HOME/elsewhere"
    venv-python-pin 3.12 --yes >"$HOME/stdout" 2>"$HOME/stderr"
  '
  if [ "$status" -ne 0 ]; then cat "$HOME/stderr"; fi
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/stdout" ]
  [ "$(cat "$PY_LAYER_PROJECT/.python-version")" = 3.12 ]
  [ "$(cat "$PY_LAYER_LOG")" = "$(printf 'uv\t--directory\t%s\tpython\tpin\t--no-project\t--no-python-downloads\t3.12' "$PY_LAYER_PROJECT")" ]
  [ "$(cat "$PY_LAYER_ENV")" = "$PY_LAYER_PROJECT|unset|unset|unset" ]
  grep -q 'Pinned Python 3.12' "$HOME/stderr"
  assert_unrelated_preserved
}

@test "py layers: pin dry run shows the exact target without writing" {
  run run_py_layer_zsh 'venv-python-pin 3.12 --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pin file"*".python-version"* ]]
  [ ! -e "$PY_LAYER_PROJECT/.python-version" ]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: pin decline and noninteractive refusal preserve the target" {
  run run_py_layer_zsh '_py_confirm_ask() { return 1; }; venv-python-pin 3.12'
  [ "$status" -eq 0 ]
  [ ! -s "$PY_LAYER_LOG" ]
  run run_py_layer_zsh 'venv-python-pin 3.12'
  [ "$status" -eq 1 ]
  [ ! -e "$PY_LAYER_PROJECT/.python-version" ]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: pin revalidates content changed after confirmation" {
  printf '3.11\n' >"$PY_LAYER_PROJECT/.python-version"
  run run_py_layer_zsh '
    _py_confirm_ask() { print -r -- 3.10 >.python-version; return 0; }
    venv-python-pin 3.12
  '
  [ "$status" -eq 1 ]
  [ ! -s "$PY_LAYER_LOG" ]
  [ "$(cat "$PY_LAYER_PROJECT/.python-version")" = 3.10 ]
}

@test "py layers: pin preserves backend failure and detects a successful no-op" {
  export PY_LAYER_STATUS=7
  run run_py_layer_zsh 'venv-python-pin 3.12 --yes'
  [ "$status" -eq 7 ]
  export PY_LAYER_STATUS=0 PY_LAYER_PIN_WRITE=0
  run run_py_layer_zsh 'venv-python-pin 3.12 --yes'
  [ "$status" -eq 1 ]
  [ ! -e "$PY_LAYER_PROJECT/.python-version" ]
}

@test "py layers: uv project install and uninstall use exact scoped argv" {
  make_package_layer uv-project
  run run_py_layer_zsh 'package-install ruff --dev --yes && package-uninstall ruff --yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$PY_LAYER_LOG")" = "$(printf 'uv\t--directory\t%s\t--project\t%s\tadd\t--dev\truff\nuv\t--directory\t%s\t--project\t%s\tremove\truff' "$PY_LAYER_PROJECT" "$PY_LAYER_PROJECT" "$PY_LAYER_PROJECT" "$PY_LAYER_PROJECT")" ]
  assert_unrelated_preserved
}

@test "py layers: Poetry install and uninstall select the marked project" {
  make_package_layer poetry-project
  run run_py_layer_zsh 'package-install ruff --dev --yes && package-uninstall ruff --yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$PY_LAYER_LOG")" = "$(printf 'poetry\t--no-plugins\t--no-interaction\t--directory\t%s\tadd\t--group\tdev\truff\npoetry\t--no-plugins\t--no-interaction\t--directory\t%s\tremove\truff' "$PY_LAYER_PROJECT" "$PY_LAYER_PROJECT")" ]
  [ "$(cat "$PY_LAYER_ENV")" = "$(printf '%s|unset|unset|unset\n%s|unset|unset|unset' "$PY_LAYER_PROJECT" "$PY_LAYER_PROJECT")" ]
  assert_unrelated_preserved
}

@test "py layers: uv environment package changes select the exact interpreter" {
  make_package_layer uv-environment
  run run_py_layer_zsh 'package-install ruff --yes && package-uninstall ruff --yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$PY_LAYER_LOG")" = "$(printf 'uv\tpip\tinstall\t--python\t%s/.venv/bin/python\truff\nuv\tpip\tuninstall\t--python\t%s/.venv/bin/python\truff' "$PY_LAYER_PROJECT" "$PY_LAYER_PROJECT")" ]
  assert_unrelated_preserved
}

@test "py layers: environment pip runs only its own isolated Python" {
  make_package_layer python-environment
  run run_py_layer_zsh 'package-install ruff --yes && package-uninstall ruff --yes'
  [ "$status" -eq 0 ]
  [ "$(cat "$PY_LAYER_LOG")" = $'python\t-I\t-m\tpip\tinstall\t--\truff\npython\t-I\t-m\tpip\tuninstall\t-y\t--\truff' ]
  assert_unrelated_preserved
}

@test "py layers: package dry runs cover install and uninstall without mutation" {
  make_package_layer uv-project
  run run_py_layer_zsh 'package-install ruff --dry-run && package-uninstall ruff --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Package"*"ruff"*"Project"*"project"* ]]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: package decline and noninteractive calls never reach a backend" {
  make_package_layer uv-project
  run run_py_layer_zsh '
    _py_confirm_ask() { return 1; }
    package-install ruff && package-uninstall ruff
  '
  [ "$status" -eq 0 ]
  run run_py_layer_zsh 'package-install ruff'
  [ "$status" -eq 1 ]
  run run_py_layer_zsh 'package-uninstall ruff'
  [ "$status" -eq 1 ]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: package backend failures retain exact statuses for both operations" {
  local operation backend
  export PY_LAYER_STATUS=7
  for backend in uv-project poetry-project uv-environment python-environment; do
    make_package_layer "$backend"
    for operation in install uninstall; do
      run run_py_layer_zsh "package-$operation ruff --yes"
      [ "$status" -eq 7 ]
    done
  done
  assert_unrelated_preserved
}

@test "py layers: package metadata and lock changes after confirmation are refused" {
  make_package_layer uv-project
  run run_py_layer_zsh '
    _py_confirm_ask() { print reached >"$HOME/confirmation"; print -r -- "# changed" >>pyproject.toml; return 0; }
    package-install ruff
  '
  [ "$status" -eq 1 ]
  [ -e "$HOME/confirmation" ]
  [ ! -s "$PY_LAYER_LOG" ]
  rm "$HOME/confirmation"
  run run_py_layer_zsh '
    _py_confirm_ask() { print reached >"$HOME/confirmation"; print -r -- "# changed" >>uv.lock; return 0; }
    package-uninstall ruff
  '
  [ "$status" -eq 1 ]
  [ -e "$HOME/confirmation" ]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: replacing the environment interpreter after confirmation is refused" {
  make_package_layer uv-environment
  run run_py_layer_zsh '
    _py_confirm_ask() {
      print reached >"$HOME/confirmation"
      command cp .venv/bin/python .venv/bin/replacement
      command mv .venv/bin/replacement .venv/bin/python
      return 0
    }
    package-install ruff
  '
  [ "$status" -eq 1 ]
  [ -e "$HOME/confirmation" ]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: external uv workspaces and unavailable Poetry fail closed" {
  make_package_layer uv-project
  printf '[tool.uv.workspace]\nmembers = ["project"]\n' >"$HOME/pyproject.toml"
  run run_py_layer_zsh 'package-install ruff --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"external workspace"* ]]
  [ ! -s "$PY_LAYER_LOG" ]
  rm "$HOME/pyproject.toml"
  make_package_layer poetry-project
  rm "$TEST_MOCK_BIN/poetry"
  run run_py_layer_zsh 'package-install ruff --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing fallback"* ]]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: tool install and uninstall isolate uv and pipx targets" {
  local backend
  for backend in uv pipx; do
    : >"$PY_LAYER_LOG"
    run run_py_layer_zsh "tool-install ruff --backend $backend --yes && tool-uninstall ruff --backend $backend --yes"
    [ "$status" -eq 0 ]
    if [[ "$backend" == uv ]]; then
      [ "$(cat "$PY_LAYER_LOG")" = $'uv\ttool\tinstall\truff\nuv\ttool\tuninstall\truff' ]
    else
      [ "$(cat "$PY_LAYER_LOG")" = $'pipx\tinstall\truff\npipx\tuninstall\truff' ]
    fi
    [ ! -e "$HOME/tools/$backend/ruff" ]
    assert_unrelated_preserved
  done
}

@test "py layers: tool plans decline and noninteractive refusal are passive" {
  run run_py_layer_zsh 'tool-install ruff --backend uv --dry-run && tool-uninstall ruff --backend uv --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tool"*"ruff"*"Backend"*"uv"* ]]
  run run_py_layer_zsh '_py_confirm_ask() { return 1; }; tool-install ruff --backend uv && tool-uninstall ruff --backend uv'
  [ "$status" -eq 0 ]
  run run_py_layer_zsh 'tool-install ruff --backend uv'
  [ "$status" -eq 1 ]
  run run_py_layer_zsh 'tool-uninstall ruff --backend uv'
  [ "$status" -eq 1 ]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: tool uninstall rejects ambiguous and changed inventory records" {
  run run_py_layer_zsh 'tool-uninstall ruff --yes'
  [ "$status" -eq 2 ]
  run run_py_layer_zsh '
    _py_confirm_ask() { command rm "$HOME/tools/uv/ruff"; return 0; }
    tool-uninstall ruff --backend uv
  '
  [ "$status" -eq 1 ]
  [ ! -s "$PY_LAYER_LOG" ]
  [ -e "$HOME/tools/pipx/ruff" ]
}

@test "py layers: tool backend failures preserve returned statuses" {
  local operation backend
  export PY_LAYER_STATUS=7
  for backend in uv pipx; do
    for operation in install uninstall; do
      run run_py_layer_zsh "tool-$operation ruff --backend $backend --yes"
      [ "$status" -eq 7 ]
    done
  done
  assert_unrelated_preserved
}

@test "py layers: virtualenvs discovery accepts a real owned child and ignores an unrelated neighbor" {
  mkdir -p "$PY_LAYER_PROJECT/.virtualenvs/alpha" "$PY_LAYER_PROJECT/.virtualenvs/neighbor"
  printf 'version = 3.12.1\n' >"$PY_LAYER_PROJECT/.virtualenvs/alpha/pyvenv.cfg"
  # Enumeration order is an explicit producer fixture, not a filesystem
  # assumption. Both listed directories remain real owned objects.
  rm "$TEST_MOCK_BIN/find"
  cat >"$TEST_MOCK_BIN/find" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "$PY_LAYER_PROJECT/.virtualenvs" ]] || exit 97
printf '%s\n' "$*" >>"$HOME/find.calls"
printf '%s\n' "$1/alpha" "$1/neighbor"
EOF
  chmod -- 755 "$TEST_MOCK_BIN/find"
  run run_py_layer_zsh 'venv-list >"$HOME/list.stdout" 2>"$HOME/list.stderr"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/list.stdout" ]
  grep -q 'alpha' "$HOME/list.stderr"
  if grep -q 'neighbor' "$HOME/list.stderr"; then return 1; fi
  [ ! -s "$PY_LAYER_LOG" ]
  [ -s "$HOME/find.calls" ]
}

@test "py layers: valid PyPI metadata is UI with bounded HTTPS request arguments" {
  run run_py_layer_zsh 'package-search demo >"$HOME/search.stdout" 2>"$HOME/search.stderr"'
  [ "$status" -eq 0 ]
  [ ! -s "$HOME/search.stdout" ]
  grep -q '1.2.3' "$HOME/search.stderr"
  grep -Fq -- '--proto =https' "$HOME/curl.calls"
  grep -Fq -- '--proto-redir =https' "$HOME/curl.calls"
  grep -Fq -- '--max-time 20' "$HOME/curl.calls"
  grep -Fq -- '--max-filesize 2097152' "$HOME/curl.calls"
  grep -Fq 'https://pypi.org/pypi/demo/json' "$HOME/curl.calls"
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "py layers: PyPI malformed and oversized responses fail and clean private state" {
  local mode
  make_sized_file "$HOME/oversized-response" 2097153
  for mode in malformed oversized; do
    export PY_LAYER_NETWORK_MODE="$mode"
    run run_py_layer_zsh 'package-search demo'
    [ "$status" -eq 1 ]
    if [[ "$mode" == oversized ]]; then
      [[ "$output" == *"exceeded the size limit"* ]]
    else
      [[ "$output" == *"invalid or unreadable metadata"* ]]
    fi
    [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
  done
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: PyPI offline HTTP and timeout failures preserve status and clean partial bodies" {
  local pair mode expected
  for pair in offline:6 http:22 timeout:28; do
    mode="${pair%:*}"; expected="${pair#*:}"
    export PY_LAYER_NETWORK_MODE="$mode"
    run run_py_layer_zsh 'package-search demo'
    [ "$status" -eq "$expected" ]
    [[ "$output" == *"PyPI metadata request failed"* ]]
    [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
  done
}

@test "py layers: missing operands dependencies and malformed names never mutate" {
  local name
  for name in package-install package-uninstall tool-install; do
    run run_py_layer_zsh "$name"
    [ "$status" -eq 1 ]
    run run_py_layer_zsh "$name --unexpected"
    [ "$status" -eq 2 ]
  done
  rm "$TEST_MOCK_BIN/uv"
  run run_py_layer_zsh 'venv-python-pin 3.12 --yes'
  [ "$status" -eq 1 ]
  run run_py_layer_zsh 'tool-install ruff --backend uv --yes'
  [ "$status" -eq 1 ]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: backend interruption statuses are preserved by individual mutation commands" {
  make_package_layer uv-project
  local signal_rc
  for signal_rc in 130 143; do
    export PY_LAYER_STATUS="$signal_rc"
    run run_py_layer_zsh 'venv-python-pin 3.12 --yes'
    [ "$status" -eq "$signal_rc" ]
    run run_py_layer_zsh 'package-install ruff --yes'
    [ "$status" -eq "$signal_rc" ]
    run run_py_layer_zsh 'package-uninstall ruff --yes'
    [ "$status" -eq "$signal_rc" ]
    run run_py_layer_zsh 'tool-install ruff --backend uv --yes'
    [ "$status" -eq "$signal_rc" ]
    run run_py_layer_zsh 'tool-uninstall ruff --backend uv --yes'
    [ "$status" -eq "$signal_rc" ]
  done
  assert_unrelated_preserved
}

@test "py layers: runtime and tool selection cancellation reaches no mutation" {
  run run_py_layer_zsh '
    _py_select_uv_python_version() { return 130; }
    venv-python-pin
  '
  [ "$status" -eq 0 ]
  run run_py_layer_zsh '
    _py_fzf_capture() { REPLY=""; return 130; }
    tool-uninstall
  '
  [ "$status" -eq 0 ]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: help and invalid flags bypass all backend operations" {
  local name
  for name in venv-python-pin package-install package-uninstall tool-install tool-uninstall; do
    export PY_LAYER_COMMAND="$name"
    run run_py_layer_zsh '"$PY_LAYER_COMMAND" --help >"$HOME/help.stdout" 2>"$HOME/help.stderr"'
    [ "$status" -eq 0 ]
    [ ! -s "$HOME/help.stdout" ]
    grep -Fq 'Usage:' "$HOME/help.stderr"
    run run_py_layer_zsh '"$PY_LAYER_COMMAND" --unknown-option'
    [ "$status" -eq 2 ]
  done
  [ ! -e "$HOME/backend.invocations" ]
  [ ! -s "$PY_LAYER_LOG" ]
}

@test "py layers: a failed partial tool inventory never authorizes uninstall" {
  export PY_LAYER_INVENTORY_PARTIAL=1 PY_LAYER_INVENTORY_STATUS=7
  run run_py_layer_zsh 'tool-uninstall ruff --backend uv --yes'
  [ "$status" -eq 7 ]
  [ ! -s "$PY_LAYER_LOG" ]
  [ -e "$HOME/tools/uv/ruff" ]
  [ -e "$HOME/tools/pipx/ruff" ]
}

@test "py fixture: tool recorders refuse escaped operands and linked markers" {
  printf 'untouched\n' >"$HOME/outside-tool-canary"
  local operation
  for operation in install uninstall; do
    export PY_LAYER_FIXTURE_OPERATION="$operation"
    run run_py_layer_zsh 'command uv tool "$PY_LAYER_FIXTURE_OPERATION" ../../outside-tool-canary'
    [ "$status" -ne 0 ]
    [ "$(cat "$HOME/outside-tool-canary")" = untouched ]
  done
  rm "$HOME/tools/uv/ruff"
  ln -s "$HOME/outside-tool-canary" "$HOME/tools/uv/ruff"
  run run_py_layer_zsh 'command uv tool install ruff'
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/outside-tool-canary")" = untouched ]
  rm "$HOME/tools/uv/ruff"
  ln "$HOME/outside-tool-canary" "$HOME/tools/uv/ruff"
  run run_py_layer_zsh 'command uv tool install ruff'
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/outside-tool-canary")" = untouched ]
}

@test "py fixture: curl recorder refuses traversal and linked response files" {
  printf 'untouched\n' >"$HOME/outside-response-canary"
  mkdir -m 700 "$TMPDIR/zdx-py-pypi.fixture"
  run run_py_layer_zsh '
    command curl --output "$TMPDIR/zdx-py-pypi.fixture/../../home/outside-response-canary" https://pypi.org/pypi/demo/json
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/outside-response-canary")" = untouched ]
  ln -s "$HOME/outside-response-canary" "$TMPDIR/zdx-py-pypi.fixture/response.json"
  run run_py_layer_zsh '
    command curl --output "$TMPDIR/zdx-py-pypi.fixture/response.json" https://pypi.org/pypi/demo/json
  '
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/outside-response-canary")" = untouched ]
}
