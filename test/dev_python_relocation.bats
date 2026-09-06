#!/usr/bin/env bats

setup() {
  export DEV_RELOCATION_UV
  export DEV_RELOCATION_PYTHON
  DEV_RELOCATION_UV=$(command -v uv) || skip "uv is required for offline relocation coverage"
  DEV_RELOCATION_PYTHON=$(command -v python3) || skip "Python 3 is required"
  DEV_RELOCATION_PYTHON=$("$DEV_RELOCATION_PYTHON" -I -c 'import sys; print(sys.executable)')
  load test_helper

  export DEV_PROJECT="$HOME/project with spaces"
  export TMPDIR="$TEST_TEMP_DIR/tmp"
  export UV_CACHE_DIR="$TEST_TEMP_DIR/uv-cache"
  export UV_OFFLINE=1
  export UV_PYTHON_DOWNLOADS=never
  unset UV_PROJECT UV_WORKING_DIR UV_PROJECT_ENVIRONMENT UV_PYTHON
  unset VIRTUAL_ENV UV_VENV_RELOCATABLE
  mkdir -m 700 "$DEV_PROJECT" "$TMPDIR"

  # A local wheel exercises uv's real console-script installation without
  # downloading packages or executing a build backend.
  "$DEV_RELOCATION_PYTHON" -I - <<'PY'
import os
import zipfile
from pathlib import Path

project = Path(os.environ["DEV_PROJECT"])
dist = "relocation_probe-1.0.0.dist-info"
files = {
    "relocation_probe.py": "import sys\ndef main():\n    print(sys.prefix)\n",
    f"{dist}/METADATA": "Metadata-Version: 2.1\nName: relocation-probe\nVersion: 1.0.0\n",
    f"{dist}/WHEEL": "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    f"{dist}/entry_points.txt": "[console_scripts]\nrelocation-probe = relocation_probe:main\n",
}
files[f"{dist}/RECORD"] = "".join(f"{name},,\n" for name in files)
wheel = "relocation_probe-1.0.0-py3-none-any.whl"
with zipfile.ZipFile(project / wheel, "w") as archive:
    for name, contents in files.items():
        archive.writestr(name, contents)
(project / "pyproject.toml").write_text(
    '[project]\nname = "demo"\nversion = "1.0.0"\n'
    'requires-python = ">=3.11"\ndependencies = ["relocation-probe"]\n'
    '[tool.uv.sources]\nrelocation-probe = { path = "' + wheel + '" }\n'
)
PY

  "$DEV_RELOCATION_UV" venv --no-managed-python \
    --python "$DEV_RELOCATION_PYTHON" "$DEV_PROJECT/.venv" >/dev/null 2>&1
  "$DEV_RELOCATION_UV" lock --directory "$DEV_PROJECT" \
    --python "$DEV_RELOCATION_PYTHON" >/dev/null 2>&1
  printf 'original\n' > "$DEV_PROJECT/.venv/original-marker"

  # Runtime downloading is replaced with a no-op. Environment creation and
  # locked synchronization use the real installed uv and local interpreter.
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env zsh
case "$1" in
  python)
    [[ "$2 $3" == "install --upgrade" ]] || exit 98
    ;;
  venv)
    local -a args=()
    while (( $# )); do
      case "$1" in
        --managed-python) args+=(--no-managed-python) ;;
        --python) args+=(--python "$DEV_RELOCATION_PYTHON"); shift ;;
        *) args+=("$1") ;;
      esac
      shift
    done
    exec "$DEV_RELOCATION_UV" "${args[@]}"
    ;;
  sync)
    exec "$DEV_RELOCATION_UV" "$@"
    ;;
  *) exit 99 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
}

teardown() {
  [[ -z "${TEST_TEMP_DIR:-}" ]] || cleanup_sandbox
}

@test "dev Python update: installed console scripts survive publication and workspace removal" {
  # shellcheck disable=SC2016
  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python --yes || return $?
    [[ "$("$DEV_PROJECT/.venv/bin/relocation-probe")" == "$DEV_PROJECT/.venv" ]]
  '

  [ "$status" -eq 0 ]
  [ ! -f "$DEV_PROJECT/.venv/original-marker" ]
  [ -z "$(find "$DEV_PROJECT" -maxdepth 1 -name '.zdx-dev-python.*' -print -quit)" ]
}

@test "dev Python update: activation resolves the published environment in Zsh" {
  # shellcheck disable=SC2016
  run run_zsh '
    cd "$DEV_PROJECT"
    dev-update-python --yes || return $?
    source "$DEV_PROJECT/.venv/bin/activate"
    [[ "$VIRTUAL_ENV" == "$DEV_PROJECT/.venv" ]] || return 91
    [[ "${path[1]}" == "$DEV_PROJECT/.venv/bin" ]] || return 92
    [[ "$(relocation-probe)" == "$DEV_PROJECT/.venv" ]] || return 93
  '

  [ "$status" -eq 0 ]
  [ -z "$(find "$DEV_PROJECT" -maxdepth 1 -name '.zdx-dev-python.*' -print -quit)" ]
}

@test "dev Python update: a staged interpreter from another minor preserves the original" {
  # shellcheck disable=SC2016
  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "$1" == */new-venv/bin/python && "${2:-}" == --version ]]; then
        print -r -- "Python 0.0.1"
        return 0
      fi
      builtin command "$@"
    }
    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"staged interpreter does not match CPython"* ]]
  [[ "$output" != *"Python updated:"* ]]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ -z "$(find "$DEV_PROJECT" -maxdepth 1 -name '.zdx-dev-python.*' -print -quit)" ]
}

@test "dev Python update: a staged non-CPython interpreter preserves the original" {
  # shellcheck disable=SC2016
  run run_zsh '
    cd "$DEV_PROJECT"
    command() {
      if [[ "$1" == */new-venv/bin/python && "${2:-}" == -I ]]; then
        print -r -- "PyPy"
        return 0
      fi
      builtin command "$@"
    }
    dev-update-python --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"staged interpreter does not match CPython"* ]]
  [[ "$output" != *"Python updated:"* ]]
  [ -f "$DEV_PROJECT/.venv/original-marker" ]
  [ -z "$(find "$DEV_PROJECT" -maxdepth 1 -name '.zdx-dev-python.*' -print -quit)" ]
}
