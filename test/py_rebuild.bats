#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# venv-rebuild: the staged uv transaction for the project .venv, its scope,
# authorization, revalidation, and rollback. uv and every interpreter are
# PATH or file mocks; no runtime or package is downloaded.

setup() {
  load test_helper
  export PY_PROJECT="$HOME/project"
  export UV_REBUILD_LOG="$TEST_TEMP_DIR/uv-rebuild.log"
  : > "$UV_REBUILD_LOG"
  mkdir -m 700 "$PY_PROJECT"
}

teardown() {
  cleanup_sandbox
}

# write_mock_python PATH IMPLEMENTATION VERSION: an interpreter that answers
# the isolated rebuild probe.
write_mock_python() {
  cat > "$1" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == -I ]] || exit 97
printf '%s %s\n' '$2' '$3'
EOF
  chmod +x "$1"
}

# A uv project with a CPython 3.11.9 .venv and an original marker file.
write_rebuild_project() {
  cat > "$PY_PROJECT/pyproject.toml" <<'EOF'
[project]
name = "demo"
version = "1.0.0"
requires-python = ">=3.11"
EOF
  printf 'version = 1\n' > "$PY_PROJECT/uv.lock"
  mkdir -p "$PY_PROJECT/.venv/bin"
  printf 'version_info = 3.11.9\nimplementation = CPython\n' \
    > "$PY_PROJECT/.venv/pyvenv.cfg"
  write_mock_python "$PY_PROJECT/.venv/bin/python" CPython 3.11.9
  printf 'original\n' > "$PY_PROJECT/.venv/original-marker"
}

# uv receives --directory ROOT --project ROOT before its subcommand. The
# staged interpreter reports UV_STAGED_IMPLEMENTATION and UV_STAGED_VERSION.
write_rebuild_uv_mock() {
  cat > "$TEST_MOCK_BIN/uv" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --directory && "${3:-}" == --project && "$2" == "$4" ]] \
  || exit 96
root="$2"
shift 4
printf '%s\n' "$*" >> "$UV_REBUILD_LOG"
case "${1:-}" in
  venv)
    [[ "${UV_STAGE_VENV_STATUS:-0}" == 0 ]] || exit "$UV_STAGE_VENV_STATUS"
    target="${@: -1}"
    mkdir -p "$target/bin"
    printf 'version_info = %s\nimplementation = CPython\nrelocatable = true\n' \
      "${UV_STAGED_VERSION:-3.11.10}" > "$target/pyvenv.cfg"
    cat > "$target/bin/python" <<PYTHON
#!/usr/bin/env bash
[[ "\${1:-}" == -I ]] || exit 97
printf '%s %s\n' '${UV_STAGED_IMPLEMENTATION:-CPython}' '${UV_STAGED_VERSION:-3.11.10}'
PYTHON
    chmod +x "$target/bin/python"
    ;;
  sync)
    [[ "${UV_SYNC_STATUS:-0}" == 0 ]] || exit "$UV_SYNC_STATUS"
    [[ -n "${UV_PROJECT_ENVIRONMENT:-}" ]] || exit 98
    printf 'environment=%s virtual_env=%s project=%s\n' \
      "$UV_PROJECT_ENVIRONMENT" "${VIRTUAL_ENV:-unset}" "${UV_PROJECT:-unset}" \
      >> "$UV_REBUILD_LOG"
    printf 'synchronized\n' > "$UV_PROJECT_ENVIRONMENT/sync-marker"
    if [[ "${UV_MUTATE_LOCK_DURING_SYNC:-0}" == 1 ]]; then
      printf 'changed during sync\n' > "$root/uv.lock"
    fi
    if [[ "${UV_RECREATE_DURING_SYNC:-0}" == 1 ]]; then
      cp -R "$UV_PROJECT_ENVIRONMENT" "$UV_PROJECT_ENVIRONMENT.new"
      rm -rf "$UV_PROJECT_ENVIRONMENT"
      mv "$UV_PROJECT_ENVIRONMENT.new" "$UV_PROJECT_ENVIRONMENT"
    fi
    ;;
  *) exit 99 ;;
esac
EOF
  chmod +x "$TEST_MOCK_BIN/uv"
}

assert_no_rebuild_workspace() {
  [ -z "$(find "$PY_PROJECT" -maxdepth 1 -name '.zdx-py-rebuild.*' -print -quit)" ]
}

# --- Plans and authorization ------------------------------------------------

@test "py rebuild: a dry run plans the uv project rebuild without running uv" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh 'cd "$PY_PROJECT" && NO_COLOR=1 venv-rebuild --dry-run'

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  Environment: +~/project/[.]venv$'
  printf '%s\n' "$output" | grep -Eq '^  Python: +CPython 3[.]11[.]9$'
  printf '%s\n' "$output" | grep -Eq \
    '^  Replacement: +uv-managed CPython 3[.]11 from uv[.]lock$'
  [[ "$output" == *"⚠ Packages that uv.lock does not list are discarded"* ]]
  [[ "$output" == *"➜ Dry run: nothing was changed."* ]]
  [[ "$output" != *"ingerprint"* ]]
  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
  assert_no_rebuild_workspace
}

@test "py rebuild: --yes stages, synchronizes, and swaps the project .venv" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh '
    cd "$PY_PROJECT"
    export VIRTUAL_ENV="$PY_PROJECT/.venv" UV_PROJECT="$HOME/elsewhere"
    NO_COLOR=1 venv-rebuild --yes
  '

  [ "$status" -eq 0 ]
  [ ! -e "$PY_PROJECT/.venv/original-marker" ]
  [ -f "$PY_PROJECT/.venv/sync-marker" ]
  grep -qx 'relocatable = true' "$PY_PROJECT/.venv/pyvenv.cfg"
  grep -Eq \
    '^venv --clear --managed-python --no-python-downloads --python 3[.]11 --relocatable .*/project/[.]zdx-py-rebuild[.][^/]+/new-venv$' \
    "$UV_REBUILD_LOG"
  grep -qx 'sync --locked --all-groups --no-python-downloads --python 3.11' \
    "$UV_REBUILD_LOG"
  grep -Eq \
    '^environment=.*/project/[.]zdx-py-rebuild[.][^/]+/new-venv virtual_env=unset project=unset$' \
    "$UV_REBUILD_LOG"
  [ "$(wc -l < "$UV_REBUILD_LOG")" -eq 3 ]
  [[ "$output" == *'$ uv venv --clear --managed-python --no-python-downloads --python 3.11 --relocatable ~/project/.zdx-py-rebuild.'*'/new-venv  (output shown on failure)'* ]]
  [[ "$output" == *'$ UV_PROJECT_ENVIRONMENT=~/project/.zdx-py-rebuild.'*'/new-venv uv sync --locked --all-groups --no-python-downloads --python 3.11  (output shown on failure)'* ]]
  [[ "$output" == *"✔ Rebuilt ~/project/.venv: CPython 3.11.9 → 3.11.10."* ]]
  assert_no_rebuild_workspace
}

@test "py rebuild: a decline changes nothing" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh '
    cd "$PY_PROJECT"
    _py_confirm() { return 130; }
    venv-rebuild
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled: nothing was changed."* ]]
  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
  assert_no_rebuild_workspace
}

@test "py rebuild: a non-interactive run fails closed without --yes" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Confirmation is unavailable; rerun with --yes"* ]]
  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
}

@test "py rebuild: a pin change after confirmation is refused before uv runs" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh '
    cd "$PY_PROJECT"
    _py_confirm() {
      print -r -- "3.11" > "$PY_PROJECT/.python-version"
      return 0
    }
    venv-rebuild
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"the Python pin changed after review; .venv was left untouched."* ]]
  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
}

@test "py rebuild: an interpreter changed after confirmation is refused" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh '
    cd "$PY_PROJECT"
    _py_confirm() {
      # A copy renamed over the interpreter keeps its content, not its identity.
      command cp -p -- "$PY_PROJECT/.venv/bin/python" "$PY_PROJECT/python.new"
      command mv -f -- "$PY_PROJECT/python.new" "$PY_PROJECT/.venv/bin/python"
      return 0
    }
    venv-rebuild
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed after review"* ]]
  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
}

# --- Failures before publication --------------------------------------------

@test "py rebuild: a failed staged environment leaves .venv untouched" {
  write_rebuild_project
  write_rebuild_uv_mock
  export UV_STAGE_VENV_STATUS=42

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not create the replacement environment; .venv was left untouched."* ]]
  [[ "$output" == *"py-menu venv-python-install 3.11"* ]]
  [ "$(wc -l < "$UV_REBUILD_LOG")" -eq 1 ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
  assert_no_rebuild_workspace
}

@test "py rebuild: a failed locked sync leaves .venv untouched" {
  write_rebuild_project
  write_rebuild_uv_mock
  export UV_SYNC_STATUS=42

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Locked synchronization failed; .venv was left untouched."* ]]
  [[ "$output" != *"Rebuilt"* ]]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
  [ ! -e "$PY_PROJECT/.venv/sync-marker" ]
  assert_no_rebuild_workspace
}

@test "py rebuild: a lockfile change during sync blocks publication" {
  write_rebuild_project
  write_rebuild_uv_mock
  export UV_MUTATE_LOCK_DURING_SYNC=1

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"changed after review; .venv was left untouched."* ]]
  [[ "$output" != *"Rebuilt"* ]]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
  assert_no_rebuild_workspace
}

@test "py rebuild: a staged environment replaced during sync is never published" {
  write_rebuild_project
  write_rebuild_uv_mock
  export UV_RECREATE_DURING_SYNC=1

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"was replaced during synchronization; .venv was left untouched."* ]]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
  assert_no_rebuild_workspace
}

@test "py rebuild: a staged interpreter from another minor keeps the original" {
  write_rebuild_project
  write_rebuild_uv_mock
  export UV_STAGED_VERSION=3.12.1

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"The staged interpreter (CPython 3.12.1) does not match CPython 3.11"* ]]
  [[ "$output" != *"Rebuilt"* ]]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
  assert_no_rebuild_workspace
}

@test "py rebuild: a staged non-CPython interpreter keeps the original" {
  write_rebuild_project
  write_rebuild_uv_mock
  export UV_STAGED_IMPLEMENTATION=PyPy

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"The staged interpreter (PyPy 3.11.10) does not match CPython 3.11"* ]]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
  assert_no_rebuild_workspace
}

# --- Publication and rollback -----------------------------------------------

@test "py rebuild: a failed publication restores the original" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh '
    cd "$PY_PROJECT"
    command() {
      if [[ "${1:-}" == mv && "${2:-}" == -- && "${3:-}" == */new-venv \
        && "${4:-}" == "$PY_PROJECT/.venv" ]]; then
        return 42
      fi
      builtin command "$@"
    }
    venv-rebuild --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not publish the replacement environment; restoring the original."* ]]
  [[ "$output" == *"The original .venv was restored after publication failed."* ]]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
  [ ! -e "$PY_PROJECT/.venv/sync-marker" ]
  assert_no_rebuild_workspace
}

@test "py rebuild: a failed rollback keeps the original in the recovery workspace" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh '
    cd "$PY_PROJECT"
    command() {
      if [[ "${1:-}" == mv && "${2:-}" == -- \
        && ( "${3:-}" == */new-venv || "${3:-}" == */original-venv ) \
        && "${4:-}" == "$PY_PROJECT/.venv" ]]; then
        return 42
      fi
      builtin command "$@"
    }
    venv-rebuild --yes
    local -i rebuild_rc=$?
    local -a recovery_markers=(
      "$PY_PROJECT"/.zdx-py-rebuild.*/original-venv/original-marker(N)
    )
    (( ${#recovery_markers[@]} == 1 )) && print -u2 -r -- "ORIGINAL_RETAINED"
    return $rebuild_rc
  '

  [ "$status" -eq 1 ]
  [ ! -e "$PY_PROJECT/.venv" ]
  [[ "$output" == *"Automatic .venv rollback failed; the original is kept in the recovery workspace."* ]]
  [[ "$output" == *"Recovery workspace retained: ~/project/.zdx-py-rebuild."* ]]
  [[ "$output" == *"original-venv in that workspace is the previous environment"* ]]
  [[ "$output" == *"ORIGINAL_RETAINED"* ]]
}

@test "py rebuild: a rename interrupted after moving .venv keeps the original" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh '
    cd "$PY_PROJECT"
    # The first rename completes but reports failure, which is the state an
    # interrupt leaves between the rename and its bookkeeping.
    command() {
      if [[ "${1:-}" == mv && "${2:-}" == -- \
        && "${3:-}" == "$PY_PROJECT/.venv" && "${4:-}" == */original-venv ]]; then
        builtin command mv -- "$3" "$4" || return 90
        return 42
      fi
      builtin command "$@"
    }
    venv-rebuild --yes
    local -i rebuild_rc=$?
    local -a recovery_markers=(
      "$PY_PROJECT"/.zdx-py-rebuild.*/original-venv/original-marker(N)
    )
    (( ${#recovery_markers[@]} == 1 )) && print -u2 -r -- "ORIGINAL_RETAINED"
    return $rebuild_rc
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Recovery workspace retained"* ]]
  [[ "$output" == *"ORIGINAL_RETAINED"* ]]
}

# --- Python request ---------------------------------------------------------

@test "py rebuild: a pin of the current minor selects the request" {
  write_rebuild_project
  write_rebuild_uv_mock
  # As uv python pin writes it, saved with Windows line endings.
  printf '# Managed by uv\r\n3.11\r\n' > "$PY_PROJECT/.python-version"

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'
  [ "$status" -eq 0 ]
  grep -q -- '--python 3.11 --relocatable' "$UV_REBUILD_LOG"

  : > "$UV_REBUILD_LOG"
  write_rebuild_project
  printf '3.11.9\n' > "$PY_PROJECT/.python-version"
  export UV_STAGED_VERSION=3.11.9
  run run_zsh 'cd "$PY_PROJECT" && NO_COLOR=1 venv-rebuild --yes'
  [ "$status" -eq 0 ]
  grep -q -- '--python 3.11.9 --relocatable' "$UV_REBUILD_LOG"
  grep -qx 'sync --locked --all-groups --no-python-downloads --python 3.11.9' \
    "$UV_REBUILD_LOG"
  [[ "$output" == *"✔ Rebuilt ~/project/.venv with CPython 3.11.9."* ]]
}

@test "py rebuild: a pin of another minor or an ambiguous pin fails closed" {
  write_rebuild_project
  write_rebuild_uv_mock
  printf '3.12\n' > "$PY_PROJECT/.python-version"

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *".python-version selects 3.12, not the .venv minor 3.11; a rebuild keeps the current minor."* ]]
  [[ "$output" == *"Run venv-remove, then venv-create"* ]]

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: nothing was changed."* ]]

  printf '3.11\n3.12\n' > "$PY_PROJECT/.python-version"
  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *".python-version must hold exactly one Python request."* ]]

  rm "$PY_PROJECT/.python-version"
  printf '3.11\n' > "$PY_PROJECT/.python-versions"
  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *".python-versions makes the Python request ambiguous."* ]]

  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
}

# --- Scope ------------------------------------------------------------------

@test "py rebuild: other environments keep the fail-closed contract" {
  write_rebuild_project
  write_rebuild_uv_mock
  mkdir -p "$PY_PROJECT/venv"
  printf 'version = 3.11.9\n' > "$PY_PROJECT/venv/pyvenv.cfg"

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --path venv --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic rebuild supports only the project .venv."* ]]
  [[ "$output" == *"This environment cannot be rebuilt automatically."* ]]
  [[ "$output" == *"Nothing was changed. Run venv-remove, then venv-create"* ]]

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --path "$PY_PROJECT/venv" --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run: nothing was changed."* ]]

  # --path naming the project .venv is the same reviewed target.
  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --path .venv --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *"uv-managed CPython 3.11 from uv.lock"* ]]

  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/venv/pyvenv.cfg" ]
}

@test "py rebuild: without --path the project .venv is chosen without a picker" {
  write_rebuild_project
  write_rebuild_uv_mock
  mkdir -p "$PY_PROJECT/venv"
  printf 'version = 3.11.9\n' > "$PY_PROJECT/venv/pyvenv.cfg"
  printf '#!/usr/bin/env bash\ntouch "%s/fzf-called"\nexit 130\n' \
    "$TEST_TEMP_DIR" > "$TEST_MOCK_BIN/fzf"
  chmod +x "$TEST_MOCK_BIN/fzf"

  run run_zsh 'cd "$PY_PROJECT" && NO_COLOR=1 venv-rebuild --dry-run'

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^  Environment: +~/project/[.]venv$'
  [ ! -e "$TEST_TEMP_DIR/fzf-called" ]
}

@test "py rebuild: a project without uv.lock fails closed" {
  write_rebuild_project
  write_rebuild_uv_mock
  rm "$PY_PROJECT/uv.lock"

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic rebuild needs pyproject.toml and uv.lock; uv.lock is missing."* ]]

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --dry-run'
  [ "$status" -eq 0 ]
  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
}

@test "py rebuild: Poetry, non-CPython, and unusable interpreters fail closed" {
  write_rebuild_project
  write_rebuild_uv_mock
  : > "$PY_PROJECT/poetry.lock"
  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Poetry environments are never rebuilt."* ]]
  rm "$PY_PROJECT/poetry.lock"

  write_mock_python "$PY_PROJECT/.venv/bin/python" PyPy 3.11.9
  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic rebuild supports CPython only; .venv uses PyPy."* ]]

  printf '#!/usr/bin/env bash\nexit 1\n' > "$PY_PROJECT/.venv/bin/python"
  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'
  [ "$status" -eq 1 ]
  [[ "$output" == *"The .venv interpreter could not be inspected."* ]]

  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
}

@test "py rebuild: a mount below .venv is refused before any change" {
  write_rebuild_project
  write_rebuild_uv_mock

  run run_zsh '
    cd "$PY_PROJECT"
    _py_assert_no_mounts_under() {
      _py_error "Refusing an environment containing a mount or bind mount: \"$1/lib\""
      return 1
    }
    venv-rebuild --yes
  '

  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing an environment containing a mount"* ]]
  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/.venv/original-marker" ]
}

@test "py rebuild: a symlinked .venv is never adopted" {
  write_rebuild_project
  write_rebuild_uv_mock
  mv "$PY_PROJECT/.venv" "$PY_PROJECT/real-venv"
  ln -s "$PY_PROJECT/real-venv" "$PY_PROJECT/.venv"

  run run_zsh 'cd "$PY_PROJECT" && venv-rebuild --yes'

  [ "$status" -eq 1 ]
  [[ "$output" == *"No validated local virtual environment found to rebuild."* ]]
  [ ! -s "$UV_REBUILD_LOG" ]
  [ -f "$PY_PROJECT/real-venv/original-marker" ]
}
