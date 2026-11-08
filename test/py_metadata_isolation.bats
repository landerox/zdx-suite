#!/usr/bin/env bats

setup() {
  load test_helper
  PY_METADATA_REAL_PYTHON=$(type -P python3)
  export PY_METADATA_REAL_PYTHON
  "$PY_METADATA_REAL_PYTHON" -B -I -S -c 'import json, pathlib, tomllib'
  export PY_METADATA_HOOKS="$HOME/startup-hooks"
  export PY_METADATA_MARKER="$HOME/startup-marker"
  export PY_METADATA_FLAGS="$HOME/python-flags"
  export PY_METADATA_ARGS="$HOME/python-args"
  mkdir -p "$PY_METADATA_HOOKS" "$HOME/project" "$HOME/foreign-modules"
  cat > "$PY_METADATA_HOOKS/startup.pth" <<'PY'
import zdx_private_startup
PY
  cat > "$PY_METADATA_HOOKS/zdx_private_startup.py" <<'PY'
import os
with open(os.environ['PY_METADATA_MARKER'], 'a', encoding='utf-8') as marker:
    marker.write('private .pth executed\n')
PY
  # Model installed startup hooks with real stdlib site.addsitedir, without
  # writing an interpreter prefix or any installed site-packages directory.
  # Preserve the product's flags; -B alone prevents host/fixture bytecode writes.
  printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/python3"
  cat >> "$TEST_MOCK_BIN/python3" <<'MOCK'
set -u
[[ "$HOME" == "$TEST_TEMP_DIR/home" && -d "$PY_METADATA_HOOKS" \
  && ! -L "$PY_METADATA_HOOKS" ]] || exit 97
printf '%s\n' "$@" >> "$PY_METADATA_ARGS"
args=("$@")
for (( index=0; index<${#args[@]}; index++ )); do
  if [[ "${args[index]}" == -c ]]; then
    [[ -n "${args[index+1]:-}" ]] || exit 97
    if [[ "${PY_METADATA_READER_STATUS:-0}" != 0 \
      && ( "${PY_METADATA_STATUS_SITE:-all}" == all \
        || "${args[index+1]}" != 'import tomllib' ) ]]; then
      exit "$PY_METADATA_READER_STATUS"
    fi
    prefix=$'import os, sys\nwith open(os.environ["PY_METADATA_FLAGS"], "a", encoding="utf-8") as flags:\n    print(sys.flags.isolated, sys.flags.no_site, sys.dont_write_bytecode, file=flags)\nif not sys.flags.no_site and os.environ.get("PY_METADATA_MODEL", "on") == "on":\n    import site\n    site.addsitedir(os.environ["PY_METADATA_HOOKS"])\n'
    args[index+1]="$prefix${args[index+1]}"
    exec "$PY_METADATA_REAL_PYTHON" -B "${args[@]}"
  fi
done
exit 97
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/python3"
  printf '#!%s -f\n' "$(type -P zsh)" > "$TEST_MOCK_BIN/curl"
  cat >> "$TEST_MOCK_BIN/curl" <<'MOCK'
emulate -R zsh
[[ "$HOME" == "$TEST_TEMP_DIR/home" && "$TMPDIR" == "$TEST_TEMP_DIR/tmpdir" ]] || exit 97
print -rl -- "$@" > "$HOME/curl-args"
local -a args=("$@")
if [[ "${args[1]:-}" == -q ]]; then
  args=("${args[@]:1}")
elif [[ -f "$HOME/.curlrc" ]]; then
  print -r -- configured > "$HOME/curlrc-read"
  exit 91
fi
(( ${#args} == 17 )) || exit 97
[[ "${args[1]}" == --proto && "${args[2]}" == '=https' \
  && "${args[3]}" == --proto-redir && "${args[4]}" == '=https' \
  && "${args[5]}" == --fail && "${args[6]}" == --silent \
  && "${args[7]}" == --show-error && "${args[8]}" == --location \
  && "${args[9]}" == --connect-timeout && "${args[10]}" == 5 \
  && "${args[11]}" == --max-time && "${args[12]}" == 20 \
  && "${args[13]}" == --max-filesize && "${args[14]}" == 2097152 \
  && "${args[15]}" == --output \
  && "${args[17]}" == https://pypi.org/pypi/demo/json ]] || exit 97
local target="${args[16]}" parent="${args[16]:h}"
[[ "$parent" == "$TMPDIR"/zdx-py-pypi.* && "${parent:h}" == "$TMPDIR" \
  && "$parent" == "${parent:A}" && -d "$parent" && ! -L "$parent" \
  && "$target" == "$parent/response.json" && -f "$target" && ! -L "$target" ]] || exit 97
zmodload -F zsh/stat b:zstat || exit 97
local -A target_state=() parent_state=()
zstat -LH target_state -- "$target" && zstat -LH parent_state -- "$parent" || exit 97
(( target_state[uid] == EUID && target_state[nlink] == 1 \
  && (target_state[mode] & 8#77) == 0 && parent_state[uid] == EUID \
  && (parent_state[mode] & 8#77) == 0 )) || exit 97
print -r -- "${PY_METADATA_PAYLOAD:-{\"info\":{\"name\":\"demo\",\"version\":\"1.2.3\"}}}" > "$target"
exit "${PY_METADATA_CURL_STATUS:-0}"
MOCK
  chmod -- 700 "$TEST_MOCK_BIN/curl"
}

teardown() {
  cleanup_sandbox
}

@test "py metadata: qualification does not execute modeled private startup hooks" {
  run -0 run_zsh '_py_require_tomllib'
  [ ! -e "$PY_METADATA_MARKER" ]
  [ "$(cat "$PY_METADATA_FLAGS")" = '1 1 True' ]
  [ "$(head -n 3 "$PY_METADATA_ARGS")" = $'-B\n-I\n-S' ]
  [ -z "$(find "$PY_METADATA_HOOKS" -name '*.pyc' -print -quit)" ]
}

@test "py metadata: Poetry TOML reader excludes modeled private startup hooks" {
  printf '[tool.poetry]\nname="demo"\n' > "$HOME/project/pyproject.toml"
  run -0 run_zsh '_py_project_uses_poetry "$HOME/project/pyproject.toml"'
  [ ! -e "$PY_METADATA_MARKER" ]
  [ "$(grep -c '^1 1 True$' "$PY_METADATA_FLAGS")" -eq 2 ]
}

@test "py metadata: ancestor workspace reader excludes modeled private startup hooks" {
  mkdir -p "$HOME/project/member"
  printf '[project]\nname="parent"\n' > "$HOME/project/pyproject.toml"
  run -0 run_zsh 'cd "$HOME/project/member"; _py_assert_no_external_uv_workspace "$PWD"'
  [ ! -e "$PY_METADATA_MARKER" ]
  [ "$(grep -c '^1 1 True$' "$PY_METADATA_FLAGS")" -ge 2 ]
}

@test "py metadata: PyPI JSON reader excludes modeled private startup hooks" {
  run -0 run_zsh 'package-search demo'
  [ ! -e "$PY_METADATA_MARKER" ]
  [ "$(cat "$PY_METADATA_FLAGS")" = '1 1 True' ]
  [[ "$output" == *'1.2.3'* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "py metadata: PyPI ignores curlrc while retaining the complete HTTPS query policy" {
  printf 'insecure\nurl = "https://invalid.example/extra"\n' > "$HOME/.curlrc"
  run -0 run_zsh 'package-search demo'
  [ ! -e "$HOME/curlrc-read" ]
  [ "$(head -n 1 "$HOME/curl-args")" = -q ]
  [ "$(wc -l < "$HOME/curl-args" | tr -d ' ')" -eq 18 ]
  [[ "$output" == *'1.2.3'* ]]
}

@test "py metadata: private startup model has a live positive control and no-site control" {
  run -0 "$TEST_MOCK_BIN/python3" -I -c 'import tomllib'
  [ -f "$PY_METADATA_MARKER" ]
  [ "$(cat "$PY_METADATA_FLAGS")" = '1 0 True' ]
  rm -- "$PY_METADATA_MARKER" "$PY_METADATA_FLAGS"
  run -0 "$TEST_MOCK_BIN/python3" -B -I -S -c 'import tomllib'
  [ ! -e "$PY_METADATA_MARKER" ]
  [ "$(cat "$PY_METADATA_FLAGS")" = '1 1 True' ]
}

@test "py metadata: real cwd and PYTHONPATH modules cannot replace stdlib readers" {
  export PY_METADATA_MODEL=off
  local module directory
  for directory in "$HOME/project" "$HOME/foreign-modules"; do
    for module in tomllib json pathlib sitecustomize; do
      printf 'import os\nwith open(os.environ["PY_METADATA_MARKER"], "a") as marker:\n    marker.write("foreign module executed\\n")\nraise RuntimeError("foreign module")\n' > "$directory/$module.py"
    done
  done
  printf '[tool.poetry]\nname="demo"\n' > "$HOME/project/pyproject.toml"
  run -0 run_zsh '
    cd "$HOME/project" || return 1
    export PYTHONPATH="$HOME/foreign-modules" PYTHONHOME="$HOME/foreign-runtime" \
      PYTHONUSERBASE="$HOME/foreign-userbase" PYTHONPYCACHEPREFIX="$HOME/foreign-cache"
    _py_project_uses_poetry "$PWD/pyproject.toml" || return $?
    package-search demo
  '
  [ ! -e "$PY_METADATA_MARKER" ]
  [ ! -e "$HOME/foreign-cache" ]
  [ ! -e "$HOME/foreign-userbase" ]
  [[ "$output" == *'1.2.3'* ]]
}

@test "py metadata: actual foreign-module canary is live without product isolation" {
  export PY_METADATA_MODEL=off
  printf 'import os\nwith open(os.environ["PY_METADATA_MARKER"], "w") as marker:\n    marker.write("foreign module executed\\n")\n' > "$HOME/foreign-modules/zdx_foreign.py"
  export PYTHONPATH="$HOME/foreign-modules"
  run -0 "$TEST_MOCK_BIN/python3" -c 'import zdx_foreign'
  [ -f "$PY_METADATA_MARKER" ]
  [ "$(cat "$PY_METADATA_FLAGS")" = '0 0 True' ]
  [ -z "$(find "$HOME/foreign-modules" -name '*.pyc' -print -quit)" ]
}

@test "py metadata: Poetry detection retains found absent and malformed states" {
  export PY_METADATA_MODEL=off
  printf '[tool.poetry]\nname="demo"\n' > "$HOME/project/pyproject.toml"
  run -0 run_zsh '_py_project_uses_poetry "$HOME/project/pyproject.toml"'
  printf '[project]\nname="demo"\n' > "$HOME/project/pyproject.toml"
  run -1 run_zsh '_py_project_uses_poetry "$HOME/project/pyproject.toml"'
  printf '[broken\n' > "$HOME/project/pyproject.toml"
  run -2 run_zsh '_py_project_uses_poetry "$HOME/project/pyproject.toml"'
}

@test "py metadata: ancestor workspace found and malformed states still refuse" {
  export PY_METADATA_MODEL=off
  mkdir -p "$HOME/project/member"
  printf '[tool.uv.workspace]\nmembers=["member"]\n' > "$HOME/project/pyproject.toml"
  run -1 run_zsh 'cd "$HOME/project/member"; _py_assert_no_external_uv_workspace "$PWD"'
  [[ "$output" == *'inside an external workspace'* ]]
  printf '[broken\n' > "$HOME/project/pyproject.toml"
  run -1 run_zsh 'cd "$HOME/project/member"; _py_assert_no_external_uv_workspace "$PWD"'
  [[ "$output" == *'Could not safely parse'* ]]
}

@test "py metadata: unreadable or invalid JSON fails closed and private query files are removed" {
  export PY_METADATA_MODEL=off PY_METADATA_PAYLOAD='{"info":'
  run -1 run_zsh 'package-search demo'
  [[ "$output" == *'invalid or unreadable metadata'* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
}

@test "py metadata: transfer failures preserve statuses and do not parse partial bodies" {
  export PY_METADATA_MODEL=off
  local rc
  for rc in 22 130 143; do
    export PY_METADATA_CURL_STATUS="$rc"
    run run_zsh 'package-search demo'
    [ "$status" -eq "$rc" ]
    [ ! -e "$PY_METADATA_FLAGS" ]
    [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
  done
}

@test "py metadata: qualification preserves interpreter interruptions" {
  local rc
  local mismatch=0
  for rc in 130 143; do
    export PY_METADATA_READER_STATUS="$rc"
    run run_zsh '_py_require_tomllib'
    printf 'expected status %s; actual %s\n' "$rc" "$status"
    [ "$status" -eq "$rc" ] || mismatch=1
  done
  [ "$mismatch" -eq 0 ]
}

@test "py metadata: Poetry qualification and parsing interruptions cannot select another backend" {
  printf '[tool.poetry]\nname="demo"\n' > "$HOME/project/pyproject.toml"
  printf '#!/bin/sh\nprintf called > "$HOME/uv-called"\nexit 97\n' > "$TEST_MOCK_BIN/uv"
  chmod -- 700 "$TEST_MOCK_BIN/uv"
  local rc reader
  local mismatch=0
  for rc in 130 143; do
    for reader in all reader; do
      export PY_METADATA_READER_STATUS="$rc" PY_METADATA_STATUS_SITE="$reader"
      run run_zsh '_py_project_uses_poetry "$HOME/project/pyproject.toml"'
      printf 'expected status %s; actual %s (%s)\n' "$rc" "$status" "$reader"
      [ "$status" -eq "$rc" ] || mismatch=1
      run run_zsh 'cd "$HOME/project"; package-install demo --dry-run'
      printf 'expected package status %s; actual %s (%s)\n' "$rc" "$status" "$reader"
      [ "$status" -eq "$rc" ] || mismatch=1
      [ ! -e "$HOME/uv-called" ]
    done
  done
  [ "$mismatch" -eq 0 ]
}

@test "py metadata: ancestor qualification and parsing preserve interpreter interruptions" {
  mkdir -p "$HOME/project/member"
  printf '[project]\nname="parent"\n' > "$HOME/project/pyproject.toml"
  local rc reader
  local mismatch=0
  for rc in 130 143; do
    for reader in all reader; do
      export PY_METADATA_READER_STATUS="$rc" PY_METADATA_STATUS_SITE="$reader"
      run run_zsh 'cd "$HOME/project/member"; _py_assert_no_external_uv_workspace "$PWD"'
      printf 'expected status %s; actual %s (%s)\n' "$rc" "$status" "$reader"
      [ "$status" -eq "$rc" ] || mismatch=1
    done
  done
  [ "$mismatch" -eq 0 ]
}

@test "py metadata: JSON reader preserves interruptions and cleans private response files" {
  local rc
  local mismatch=0
  for rc in 130 143; do
    export PY_METADATA_READER_STATUS="$rc"
    run run_zsh 'package-search demo'
    printf 'expected status %s; actual %s\n' "$rc" "$status"
    [ "$status" -eq "$rc" ] || mismatch=1
    [ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]
  done
  [ "$mismatch" -eq 0 ]
}

@test "py metadata: genuine environment-picker cancellation remains successful and passive" {
  mkdir -p "$HOME/project/.venv/bin" "$HOME/project/venv/bin"
  local environment
  for environment in .venv venv; do
    printf 'version = 3.12.1\n' > "$HOME/project/$environment/pyvenv.cfg"
    printf '#!/bin/sh\nexit 97\n' > "$HOME/project/$environment/bin/python"
    chmod -- 700 "$HOME/project/$environment/bin/python"
  done
  run -0 run_zsh 'cd "$HOME/project"; package-install demo --yes'
  [[ "$output" == *'Cancelled.'* ]]
  [ ! -e "$PY_METADATA_FLAGS" ]
  [ ! -e "$HOME/curl-args" ]
}

@test "py metadata: unsupported qualification retains normal error states" {
  export PY_METADATA_READER_STATUS=1
  printf '[project]\nname="demo"\n' > "$HOME/project/pyproject.toml"
  run -1 run_zsh '_py_require_tomllib'
  [[ "$output" == *'Python 3.11 or newer is required'* ]]
  run -2 run_zsh '_py_project_uses_poetry "$HOME/project/pyproject.toml"'
  run -1 run_zsh '_py_assert_no_external_uv_workspace "$HOME/project"'
}

@test "py metadata: an earlier picker cancellation cannot mask a later reader interruption" {
  mkdir -p "$HOME/project/.venv/bin" "$HOME/project/venv/bin"
  local environment
  for environment in .venv venv; do
    printf 'version = 3.12.1\n' > "$HOME/project/$environment/pyvenv.cfg"
    printf '#!/bin/sh\nexit 97\n' > "$HOME/project/$environment/bin/python"
    chmod -- 700 "$HOME/project/$environment/bin/python"
  done
  run -130 run_zsh '
    cd "$HOME/project" || return 1
    local -i backend_rc=0
    _py_detect_package_backend || backend_rc=$?
    (( backend_rc == 130 )) && [[ "$REPLY" == cancelled ]] || return 98
    print -r -- "[project]" > pyproject.toml
    export PY_METADATA_READER_STATUS=130
    backend_rc=0
    _py_detect_package_backend || backend_rc=$?
    (( backend_rc == 130 )) && [[ "$REPLY" != cancelled ]] || return 99
    package-install demo --dry-run
  '
  [[ "$output" != *'Cancelled.'* ]]
}
