#!/usr/bin/env bats
#
# venv-rebuild with the real installed uv, offline: a local wheel exercises
# console-script installation, locked synchronization, and relocation of the
# staged environment into .venv without downloading a runtime or package.

setup() {
  export PY_RELOCATION_UV
  export PY_RELOCATION_PYTHON
  PY_RELOCATION_UV=$(command -v uv) || skip "uv is required for offline relocation coverage"
  PY_RELOCATION_PYTHON=$(command -v python3) || skip "Python 3 is required"
  PY_RELOCATION_PYTHON=$("$PY_RELOCATION_PYTHON" -I -c 'import sys; print(sys.executable)')
  load test_helper

  export PY_PROJECT="$HOME/project with spaces"
  export UV_CACHE_DIR="$TEST_TEMP_DIR/uv-cache"
  export UV_OFFLINE=1
  export UV_PYTHON_DOWNLOADS=never
  unset UV_PROJECT UV_WORKING_DIR UV_PROJECT_ENVIRONMENT UV_PYTHON
  unset VIRTUAL_ENV UV_VENV_RELOCATABLE
  mkdir -m 700 "$PY_PROJECT"

  # A local wheel exercises uv's real console-script installation without
  # downloading packages or executing a build backend.
  "$PY_RELOCATION_PYTHON" -I - <<'PY'
import os
import zipfile
from pathlib import Path

project = Path(os.environ["PY_PROJECT"])
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

  "$PY_RELOCATION_UV" venv --no-managed-python \
    --python "$PY_RELOCATION_PYTHON" "$PY_PROJECT/.venv" >/dev/null 2>&1
  "$PY_RELOCATION_UV" lock --directory "$PY_PROJECT" \
    --python "$PY_RELOCATION_PYTHON" >/dev/null 2>&1
  printf 'original\n' > "$PY_PROJECT/.venv/original-marker"

  # The local interpreter stands in for a uv-managed runtime. Environment
  # creation and locked synchronization use the real installed uv.
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env zsh
local -a args=()
while (( $# )); do
  case "$1" in
    --managed-python) args+=(--no-managed-python) ;;
    --python)
      if (( ${args[(Ie)venv]} )); then
        args+=(--python "$PY_RELOCATION_PYTHON")
      else
        args+=(--python "$2")
      fi
      shift
      ;;
    *) args+=("$1") ;;
  esac
  shift
done
(( ${args[(Ie)venv]} || ${args[(Ie)sync]} )) || exit 99
exec "$PY_RELOCATION_UV" "${args[@]}"
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
}

teardown() {
  [[ -z "${TEST_TEMP_DIR:-}" ]] || cleanup_sandbox
}

@test "py rebuild relocation: console scripts survive publication and workspace removal" {
  # shellcheck disable=SC2016
  run run_zsh '
    cd "$PY_PROJECT"
    venv-rebuild --yes || return $?
    [[ "$("$PY_PROJECT/.venv/bin/relocation-probe")" == "$PY_PROJECT/.venv" ]]
  '

  [ "$status" -eq 0 ]
  [ ! -f "$PY_PROJECT/.venv/original-marker" ]
  grep -q '^relocatable = true$' "$PY_PROJECT/.venv/pyvenv.cfg"
  [ -z "$(find "$PY_PROJECT" -maxdepth 1 -name '.zdx-py-rebuild.*' -print -quit)" ]
}

@test "py rebuild relocation: activation resolves the published environment in Zsh" {
  # shellcheck disable=SC2016
  run run_zsh '
    cd "$PY_PROJECT"
    venv-rebuild --yes || return $?
    source "$PY_PROJECT/.venv/bin/activate"
    [[ "$VIRTUAL_ENV" == "$PY_PROJECT/.venv" ]] || return 91
    [[ "${path[1]}" == "$PY_PROJECT/.venv/bin" ]] || return 92
    [[ "$(relocation-probe)" == "$PY_PROJECT/.venv" ]] || return 93
  '

  [ "$status" -eq 0 ]
  [ -z "$(find "$PY_PROJECT" -maxdepth 1 -name '.zdx-py-rebuild.*' -print -quit)" ]
}

@test "py rebuild relocation: a pin of the current minor keeps the staged environment" {
  local minor
  minor=$("$PY_RELOCATION_PYTHON" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  printf '%s\n' "$minor" > "$PY_PROJECT/.python-version"

  # shellcheck disable=SC2016
  run run_zsh '
    cd "$PY_PROJECT"
    venv-rebuild --yes || return $?
    [[ "$("$PY_PROJECT/.venv/bin/relocation-probe")" == "$PY_PROJECT/.venv" ]]
  '

  [ "$status" -eq 0 ]
  [ ! -f "$PY_PROJECT/.venv/original-marker" ]
  [[ "$output" != *"replaced during synchronization"* ]]
}
