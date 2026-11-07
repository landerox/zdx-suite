#!/usr/bin/env bats
# Actual resolver coverage; synthetic environments and code stay under HOME.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  _zdx_test_dev_preview_private_python || return 1
  export DEV_PROJECT="$HOME/project" TRUST_LOG="$HOME/preview.log"
  export TMPDIR="$TEST_TEMP_DIR/tmp" PREVIEW_MARKER="$HOME/untrusted-ran"
  mkdir -m 700 "$DEV_PROJECT" "$TMPDIR"
  cat > "$DEV_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "preview-fixture"
dependencies = ["pre-commit>=1.0.0"]
EOF
  cat > "$DEV_PROJECT/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://example.invalid/hooks
    rev: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1.0.0
    hooks:
      - id: fixture
EOF
  cp "$DEV_PROJECT/pyproject.toml" "$HOME/original.pyproject"
  cp "$DEV_PROJECT/.pre-commit-config.yaml" "$HOME/original.hooks"
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv:%s\n' "$*" >> "$TRUST_LOG"
if [[ "$*" == 'python find --system --no-project --no-python-downloads --offline >=3.11' \
  && "${PREVIEW_UV_FIND:-0}" == 1 ]]; then
  printf '%s\n' "$REAL_PREVIEW_PYTHON"
  exit 0
fi
exit 97
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
  # A regression must never delegate a real upstream fetch or install.
  local program
  for program in git curl; do
    printf '#!%s\nexit 97\n' "$BASH" > "$TEST_MOCK_BIN/$program"
    chmod +x "$TEST_MOCK_BIN/$program"
  done
}

teardown() {
  _zdx_test_dev_preview_diagnostic_dump
  cleanup_sandbox
}

preview_environment() {
  export PREVIEW_KIND="$1"
  local version
  version=$("$REAL_PREVIEW_PYTHON" -B -I -S -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")') || return 1
  [[ ! -e "$DEV_PROJECT/.venv" && ! -L "$DEV_PROJECT/.venv" ]] || return 1
  mkdir -p "$DEV_PROJECT/.venv/bin" || return 1
  # Preserve the builder's real base home; Meta/bin is not the base stdlib home.
  cp "$PREVIEW_PYTHON_CONFIG" "$DEV_PROJECT/.venv/pyvenv.cfg" || return 1
  # Keep a genuine link outside this venv: canonicalizing argv loses project prefix.
  ln -s "$REAL_PREVIEW_PYTHON" "$DEV_PROJECT/.venv/bin/python" || return 1
  cat > "$HOME/preview-main.py" <<'EOF' || return 1
from pathlib import Path
import os
import sys

project = Path(os.environ["DEV_PROJECT"])
assert Path(sys.prefix).resolve() == project / ".venv"
args = sys.argv[1:]
assert args[:3] == ["autoupdate", "--freeze", "--config"]
assert len(args) == 4
candidate = Path(args[3])
assert candidate != project / ".pre-commit-config.yaml"
cache = Path(os.environ["PRE_COMMIT_HOME"])
assert cache.is_dir() and str(cache).startswith(os.environ["TMPDIR"] + "/")
(cache / "fixture-cache").write_text("private\n")
with Path(os.environ["TRUST_LOG"]).open("a") as log:
    log.write("qualified-prefix:" + str(Path(sys.prefix).resolve()) + "\n")
    log.write("fixture-autoupdate\n")
candidate.write_text(candidate.read_text().replace(
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # frozen: v1.0.0",
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # frozen: v1.1.0",
))
EOF
  if [[ "$PREVIEW_KIND" == module ]]; then
    local package="$DEV_PROJECT/.venv/lib/python$version/site-packages/pre_commit"
    mkdir -p "$package" || return 1
    : > "$package/__init__.py" || return 1
    cp "$HOME/preview-main.py" "$package/__main__.py" || return 1
  else
    printf '#!%s\n' "$DEV_PROJECT/.venv/bin/python" > "$DEV_PROJECT/.venv/bin/pre-commit" || return 1
    cat "$HOME/preview-main.py" >> "$DEV_PROJECT/.venv/bin/pre-commit" || return 1
    chmod -- 755 "$DEV_PROJECT/.venv/bin/pre-commit" || return 1
  fi
}

preview_unsafe_program() {
  local destination="$1"
  printf '#!%s\nprintf "executed\\n" > "$PREVIEW_MARKER"\nexit 1\n' "$BASH" \
    > "$destination"
  chmod 777 "$destination"
}

run_actual_preview() {
  local diagnostic
  diagnostic=$(_zdx_test_dev_preview_diagnostic_program)
  run_zsh '
    source "$ZSH_CUSTOM/functions/dev-menu.zsh" || return
    '"$diagnostic"'
    builtin cd -- "$DEV_PROJECT" || return
    _dev_pypi_check_connectivity() { return 0; }
    _dev_pypi_latest() { print -r -- 1.0.0; }
    # Containment only: refuse delegation outside this synthetic environment.
    # The resolver and safe project Python/module/script execute normally.
    functions[_preview_captured]="${functions[_dev_run_captured]}"
    _dev_run_captured() {
      if [[ "$1" == "pre-commit autoupdate --freeze" \
        && "$2" != "$DEV_PROJECT/.venv/bin/python" \
        && "$2" != "$DEV_PROJECT/.venv/bin/pre-commit" ]]; then
        _dev_error "Fixture refused delegation outside the project environment."
        return 96
      fi
      _preview_captured "$@"
    }
  '"$1"
}

preview_hide_path_python() {
  # This fixed Zsh fragment changes capability lookup, never executes a tool.
  printf '%s\n' '
    functions[_preview_have]="${functions[_dev_have_command]}"
    _dev_have_command() {
      case "$1" in python3|python3.14|python3.13|python3.12|python3.11) return 1 ;; esac
      _preview_have "$@"
    }
  '
}

assert_preview_originals() {
  cmp "$HOME/original.pyproject" "$DEV_PROJECT/pyproject.toml"
  cmp "$HOME/original.hooks" "$DEV_PROJECT/.pre-commit-config.yaml"
  [ ! -e "$DEV_PROJECT/.dev-suite-backups" ]
}

assert_actual_preview() {
  [ "$status" -eq 0 ]
  grep -Fq "qualified-prefix:$DEV_PROJECT/.venv" "$TRUST_LOG"
  grep -q '^fixture-autoupdate$' "$TRUST_LOG"
  ! grep -Eq '^uv:(run|lock|sync|add|tool|python install)' "$TRUST_LOG" || return 1
  assert_preview_originals
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "dev preview trust: unsafe project Python cannot execute during real resolver qualification" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  preview_unsafe_program "$DEV_PROJECT/.venv/bin/python"
  run run_actual_preview 'dev-update-precommit --dry-run'
  [ "$status" -eq 1 ]
  [ ! -e "$PREVIEW_MARKER" ]
  assert_preview_originals
}

@test "dev preview trust: unsafe metadata fallback Python is refused before its prefix probe" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  preview_unsafe_program "$DEV_PROJECT/.venv/bin/python"
  local hidden
  hidden=$(preview_hide_path_python)
  run run_actual_preview "$hidden"'dev-update-precommit --dry-run'
  [ "$status" -eq 1 ]
  [ ! -e "$PREVIEW_MARKER" ]
  assert_preview_originals
}

@test "dev preview trust: unsafe PATH metadata Python never executes before a safe candidate" {
  preview_environment script
  ln -s "$REAL_PREVIEW_PYTHON" "$TEST_MOCK_BIN/python3.14"
  preview_unsafe_program "$TEST_MOCK_BIN/python3"
  run run_actual_preview 'dev-update-precommit --dry-run'
  [ "$status" -eq 0 ]
  [ ! -e "$PREVIEW_MARKER" ]
  assert_actual_preview
}

@test "dev preview trust: a legitimate interpreter symlink keeps real module and project prefix" {
  preview_environment module
  run run_actual_preview 'dev-update-precommit --dry-run'
  assert_actual_preview
}

@test "dev preview trust control: a legitimate installed script keeps real interpreter provenance" {
  preview_environment script
  run run_actual_preview 'dev-update-precommit --dry-run'
  assert_actual_preview
}

@test "dev preview trust: installed uv metadata discovery is trusted offline and download-free" {
  preview_environment script
  export PREVIEW_UV_FIND=1
  local hidden
  hidden=$(preview_hide_path_python)
  run run_actual_preview "$hidden"'dev-update-precommit --dry-run'
  assert_actual_preview
  grep -Fxq 'uv:python find --system --no-project --no-python-downloads --offline >=3.11' "$TRUST_LOG"
}

@test "dev preview trust: unsafe uv cannot execute before an installed metadata fallback" {
  preview_environment script
  preview_unsafe_program "$TEST_MOCK_BIN/uv"
  local hidden
  hidden=$(preview_hide_path_python)
  run run_actual_preview "$hidden"'dev-update-precommit --dry-run'
  [ "$status" -eq 0 ]
  [ ! -e "$PREVIEW_MARKER" ]
  assert_actual_preview
}

@test "dev preview trust: writable project interpreter directory cannot run a prefix probe" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  preview_unsafe_program "$DEV_PROJECT/.venv/bin/python"
  chmod 755 "$DEV_PROJECT/.venv/bin/python"
  chmod 777 "$DEV_PROJECT/.venv/bin"
  run run_actual_preview 'dev-update-precommit --dry-run'
  [ "$status" -eq 1 ]
  [ ! -e "$PREVIEW_MARKER" ]
  assert_preview_originals
}

@test "dev preview trust control: an unrelated script shebang never proves project installation" {
  preview_environment script
  printf '#!/usr/bin/env python3\nraise SystemExit(97)\n' > "$DEV_PROJECT/.venv/bin/pre-commit"
  run run_actual_preview 'dev-update-precommit --dry-run'
  [ "$status" -eq 1 ]
  ! grep -q '^fixture-autoupdate$' "$TRUST_LOG" 2>/dev/null || return 1
  assert_preview_originals
}

@test "dev preview trust control: a launcher symlink outside the environment stays refused" {
  preview_environment script
  mv "$DEV_PROJECT/.venv/bin/pre-commit" "$HOME/external-pre-commit"
  ln -s "$HOME/external-pre-commit" "$DEV_PROJECT/.venv/bin/pre-commit"
  run run_actual_preview 'dev-update-precommit --dry-run'
  [ "$status" -eq 1 ]
  ! grep -q '^fixture-autoupdate$' "$TRUST_LOG" 2>/dev/null || return 1
  assert_preview_originals
}

@test "dev preview trust: a cached unsafe metadata interpreter is rechecked without execution" {
  mkdir -p "$DEV_PROJECT/.venv/bin"
  preview_unsafe_program "$DEV_PROJECT/.venv/bin/python"
  run run_actual_preview '
    local _DEV_RUN_PYTHON="$DEV_PROJECT/.venv/bin/python"
    dev-update-precommit --dry-run
  '
  [ "$status" -eq 1 ]
  [ ! -e "$PREVIEW_MARKER" ]
  assert_preview_originals
}

@test "dev preview trust: replacement of a qualified interpreter link stops the next qualification" {
  preview_environment module
  preview_unsafe_program "$HOME/second-python"
  chmod 755 "$HOME/second-python"
  run run_actual_preview '
    functions[_preview_venv]="${functions[_dev_require_venv]}"
    _dev_require_venv() {
      _preview_venv "$@" || return
      command rm -- "$DEV_PROJECT/.venv/bin/python" || return
      command ln -s -- "$HOME/second-python" "$DEV_PROJECT/.venv/bin/python"
    }
    dev-update-precommit --dry-run
  '
  [ "$status" -eq 1 ]
  [ ! -e "$PREVIEW_MARKER" ]
  assert_preview_originals
}

@test "dev preview trust: changed bytes of a qualified interpreter stop the next qualification" {
  preview_environment module
  rm "$DEV_PROJECT/.venv/bin/python"
  cp "$REAL_PREVIEW_PYTHON" "$DEV_PROJECT/.venv/bin/python"
  chmod 755 "$DEV_PROJECT/.venv/bin/python"
  preview_unsafe_program "$HOME/second-python"
  chmod 755 "$HOME/second-python"
  run run_actual_preview '
    functions[_preview_venv]="${functions[_dev_require_venv]}"
    _dev_require_venv() {
      _preview_venv "$@" || return
      command cat -- "$HOME/second-python" > "$DEV_PROJECT/.venv/bin/python"
    }
    dev-update-precommit --dry-run
  '
  [ "$status" -eq 1 ]
  [ ! -e "$PREVIEW_MARKER" ]
  assert_preview_originals
}

@test "dev preview trust: aggregate policy guards metadata before the dependency preview" {
  preview_unsafe_program "$TEST_MOCK_BIN/python3"
  run run_actual_preview '
    dev-update-deps() {
      print -r -- dependency-preview >> "$TRUST_LOG"
      _dev_require_python_toml
    }
    dev-update-precommit() { return 0; }
    dev-clean-all() { return 0; }
    dev-update-all --dry-run
  '
  [ "$status" -eq 0 ]
  grep -q '^dependency-preview$' "$TRUST_LOG"
  [ ! -e "$PREVIEW_MARKER" ]
  assert_preview_originals
}

@test "dev preview trust: a known CLT placeholder prevents uv discovery without an installed fallback" {
  preview_unsafe_program "$TEST_MOCK_BIN/uv"
  chmod 755 "$TEST_MOCK_BIN/uv"
  local hidden
  hidden=$(preview_hide_path_python)
  run run_actual_preview "$hidden"'
    _dev_clt_placeholder() { [[ "$1" == python3 ]]; }
    dev-update-precommit --dry-run
  '
  [ "$status" -eq 1 ]
  [ ! -e "$PREVIEW_MARKER" ]
  assert_preview_originals
}

@test "dev preview trust: a known CLT placeholder keeps the validated private venv fallback" {
  preview_environment script
  preview_unsafe_program "$TEST_MOCK_BIN/uv"
  chmod 755 "$TEST_MOCK_BIN/uv"
  local hidden
  hidden=$(preview_hide_path_python)
  run run_actual_preview "$hidden"'
    _dev_clt_placeholder() { [[ "$1" == python3 ]]; }
    dev-update-precommit --dry-run
  '
  assert_actual_preview
  [ ! -e "$PREVIEW_MARKER" ]
}
