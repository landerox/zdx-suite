#!/usr/bin/env zsh
# =============================================================================
# Dev Update Python: runtime patch upgrade and delegation to py-menu
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-state.zsh and dev-pypi.zsh.
# Safe to re-source; defines functions only.
#
# The Python suite owns the .venv lifecycle. This module upgrades only the
# uv-managed runtime of the project's Python minor, then hands the
# environment rebuild to py-menu venv-rebuild, which owns the staged
# transaction and its rollback. Without .venv it hands runtime selection and
# installation to py-menu venv-python-install.
#

if [[ -n "${_DEV_UPDATE_PYTHON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Python runtime ---------------------------------------------------------

# REPLY: the X.Y minor of a "Python X.Y.Z" or "X.Y.Z" version string.
_dev_update_python_minor() {
  local version_token="${1#Python }"
  REPLY=""
  [[ "$version_token" == *.* ]] || return 1
  local major_version="${version_token%%.*}"
  local remaining_version="${version_token#*.}"
  local minor_version="${remaining_version%%.*}"
  [[ "$major_version" == <-> && "$minor_version" == <-> ]] || return 1
  REPLY="${major_version}.${minor_version}"
}

# Sets REPLY to one minor-version request safe for `uv python install
# --upgrade`. Exact and multi-version pins are owned by py-menu and must be
# changed explicitly instead of being silently overridden here.
_dev_update_python_request() {
  local current_version="$1"
  REPLY=""

  local -a pin_files=()
  local candidate
  for candidate in ".python-version" ".python-versions"; do
    [[ -e "$candidate" || -L "$candidate" ]] && pin_files+=("$candidate")
  done

  if (( ${#pin_files[@]} > 1 )); then
    _dev_error \
      "Both .python-version and .python-versions exist; Python selection is ambiguous."
    return 1
  fi

  if (( ${#pin_files[@]} == 1 )); then
    local pin_file="${pin_files[1]}"
    _dev_owned_file_identity "$pin_file" "Python version pin" \
      >/dev/null || return 1

    # The health check's parser: comment lines and a CRLF ending are read as
    # uv reads them, so a pin written on Windows or by `uv python pin` works.
    if ! _dev_read_python_pin "$pin_file"; then
      _dev_info \
        "Choose the new runtime explicitly with: py-menu venv-python-pin <major.minor>"
      return 1
    fi
    if [[ "$REPLY" != <->.<-> ]]; then
      REPLY=""
      _dev_error \
        "An exact or complex Python pin cannot be upgraded implicitly."
      _dev_info \
        "Choose the new runtime explicitly with: py-menu venv-python-pin <major.minor>"
      return 1
    fi
    return 0
  fi

  if ! _dev_update_python_minor "$current_version"; then
    _dev_error \
      "Could not determine the current .venv Python minor version."
    _dev_info \
      "Choose it explicitly with: py-menu venv-python-pin <major.minor>"
    return 1
  fi
}

_dev_update_python_inputs_validate() {
  local project_root="$1"
  local expected_pyproject_fingerprint="$2"
  local expected_lock_fingerprint="$3"

  local current_pyproject_fingerprint
  current_pyproject_fingerprint=$(
    _dev_owned_file_fingerprint \
      "${project_root}/pyproject.toml" "pyproject.toml"
  ) || return 1
  local current_lock_fingerprint
  current_lock_fingerprint=$(
    _dev_owned_file_fingerprint "${project_root}/uv.lock" "uv.lock"
  ) || return 1

  if [[ "$current_pyproject_fingerprint" != \
      "$expected_pyproject_fingerprint" \
    || "$current_lock_fingerprint" != "$expected_lock_fingerprint" ]]; then
    _dev_error \
      "pyproject.toml or uv.lock changed during the Python update."
    return 1
  fi
}

# dev-update-python
#   Arguments: --dry-run | --yes | --help
#   Effects:   delegates runtime installation to py-menu when .venv is absent;
#              otherwise, after confirmation, upgrades the uv-managed runtime
#              of the .venv minor and delegates the rebuild to
#              py-menu venv-rebuild --yes. --dry-run runs neither uv nor
#              py-menu.
dev-update-python() {
  emulate -L zsh

  local -i auto_yes=0 dry_run=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-update-python [--dry-run] [--yes]"
        print -u2 -r -- \
          "  Upgrade the uv-managed Python patch release and rebuild .venv through"
        print -u2 -r -- \
          "  py-menu, or delegate runtime selection and installation without .venv."
        print -u2 -r -- \
          "  --dry-run  Show the plan; run neither uv nor py-menu."
        print -u2 -r -- \
          "  --yes      Skip confirmation; delegated version selection may still prompt."
        print -u2 -r -- \
          "  For unattended installation: py-menu venv-python-install VERSION --yes"
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      --yes|-y) auto_yes=1 ;;
      *) _dev_error "Unknown option: $1"; return 2 ;;
    esac
    shift
  done

  _dev_header "Maintaining Project Python"

  local project_root="${PWD:A}"
  local venv_path="${project_root}/.venv"
  if [[ -e "$venv_path" || -L "$venv_path" ]]; then
    if [[ ! -d "$venv_path" || -L "$venv_path" \
      || "${venv_path:a}" != "${venv_path:A}" ]]; then
      _dev_error "Refusing to replace an unsafe .venv path."
      return 1
    fi
  fi

  if [[ ! -d "$venv_path" ]]; then
    local -a delegate_arguments=(venv-python-install)
    (( auto_yes )) && delegate_arguments+=(--yes)
    _dev_info \
      "No .venv exists; Python runtime selection and installation are owned by py-menu."
    if (( dry_run )); then
      _dev_info "Planned delegation: py-menu ${(j: :)delegate_arguments}"
      _dev_info "Dry run: nothing was changed."
      _dev_dim "Preview the installation with: py-menu venv-python-install --dry-run"
      return 0
    fi
    _dev_info "Delegating to the Python suite..."
    _dev_delegate_py "${delegate_arguments[@]}"
    return $?
  fi

  _dev_require_command uv || return 1

  local current_version=""
  local current_implementation=""
  current_version=$(
    command "${venv_path}/bin/python" --version 2>/dev/null
  )
  current_implementation=$(
    command "${venv_path}/bin/python" -I -c \
      'import platform; print(platform.python_implementation())' 2>/dev/null
  )
  _dev_info "Current venv Python: ${current_version:-unknown}"

  local requires_python
  requires_python=$(_dev_pyproject_requires_python 2>/dev/null) \
    && [[ -n "$requires_python" ]] \
    && _dev_info "pyproject.toml requires-python: $requires_python"

  _dev_require_file "pyproject.toml" || return 1
  _dev_require_file "uv.lock" || {
    _dev_info "Create or refresh it first with: dev-update-lock"
    return 1
  }
  if [[ "$current_implementation" != "CPython" ]]; then
    _dev_error \
      "Automatic patch upgrades currently require a CPython .venv."
    _dev_info \
      "Choose an alternative runtime explicitly with: py-menu venv-python-pin <runtime>"
    return 1
  fi

  local pyproject_fingerprint
  pyproject_fingerprint=$(
    _dev_owned_file_fingerprint \
      "${project_root}/pyproject.toml" "pyproject.toml"
  ) || return 1
  local lock_fingerprint
  lock_fingerprint=$(
    _dev_owned_file_fingerprint "${project_root}/uv.lock" "uv.lock"
  ) || return 1

  local project_identity
  project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || return 1
  local venv_identity
  venv_identity=$(
    _dev_directory_identity "$venv_path" "existing Python environment"
  ) || return 1
  _dev_update_python_request "$current_version" || return 1
  local python_request="$REPLY"
  _dev_info "Python minor selected for patch upgrade: $python_request"

  # py-menu venv-rebuild keeps the environment's minor, so a pin that selects
  # another minor needs a new environment rather than a patch upgrade.
  _dev_update_python_minor "$current_version"
  if [[ "$REPLY" != "$python_request" ]]; then
    _dev_error \
      "The project pin selects Python $python_request, but .venv uses ${REPLY:-another minor}; the rebuild keeps the environment's minor."
    _dev_info \
      "Recreate it explicitly with: py-menu venv-remove, then py-menu venv-create --python $python_request"
    return 1
  fi
  if ! _dev_delegate_py_available; then
    _dev_error \
      "py-menu is unavailable; the .venv rebuild cannot be delegated."
    return 1
  fi

  _dev_table $'#\tStep\tCommand' \
    "1"$'\t'"Upgrade the uv-managed runtime"$'\t'"uv python install --upgrade $python_request" \
    "2"$'\t'"Rebuild .venv in the Python suite"$'\t'"py-menu venv-rebuild --yes"
  _dev_warn \
    "Replacing .venv discards packages not represented by the current lockfile."
  _dev_dim \
    "The runtime upgrade changes uv's user-wide Python installations and cannot be rolled back."
  _dev_dim \
    "The Python suite builds and synchronizes the replacement privately before swapping .venv."
  if (( dry_run )); then
    _dev_info "Dry run: nothing was changed."
    _dev_dim "Preview the rebuild with: py-menu venv-rebuild --dry-run"
    return 0
  fi

  local -i previous_auto_yes=$_DEV_AUTO_YES
  local rebuild_outcome="declined"
  {
    (( auto_yes )) && _DEV_AUTO_YES=1
    rebuild_outcome=$(_dev_confirm_outcome \
      "Upgrade Python $python_request and rebuild .venv?")
  } always {
    _DEV_AUTO_YES=$previous_auto_yes
  }

  case "$rebuild_outcome" in
    confirmed) ;;
    unavailable)
      _dev_error \
        "Rebuilding .venv needs confirmation; pass --yes in a non-interactive shell."
      return 1
      ;;
    *)
      _dev_info "Cancelled. Python and .venv were left untouched."
      return 0
      ;;
  esac

  local current_project_identity
  current_project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || return 1
  local current_venv_identity
  current_venv_identity=$(
    _dev_directory_identity "$venv_path" "existing Python environment"
  ) || return 1
  local authorized_version
  authorized_version=$(
    command "${venv_path}/bin/python" --version 2>/dev/null
  )
  local authorized_implementation
  authorized_implementation=$(
    command "${venv_path}/bin/python" -I -c \
      'import platform; print(platform.python_implementation())' 2>/dev/null
  )
  if [[ "$current_project_identity" != "$project_identity" \
    || "$current_venv_identity" != "$venv_identity" \
    || "$authorized_version" != "$current_version" \
    || "$authorized_implementation" != "$current_implementation" \
    || "${PWD:A}" != "$project_root" ]]; then
    _dev_error \
      "The project or .venv changed after authorization; refusing to continue."
    return 1
  fi

  _dev_update_python_request "$authorized_version" || return 1
  if [[ "$REPLY" != "$python_request" ]]; then
    _dev_error \
      "The Python version selection changed after authorization."
    return 1
  fi
  _dev_update_python_inputs_validate \
    "$project_root" "$pyproject_fingerprint" "$lock_fingerprint" || {
    _dev_error \
      "Project inputs changed after authorization; refusing to continue."
    return 1
  }

  _dev_info "Upgrading uv-managed Python $python_request patch releases..."
  if ! command uv python install --upgrade "$python_request" >&2; then
    _dev_error \
      "Python installation failed. The existing .venv was left untouched."
    return 1
  fi
  _dev_update_python_inputs_validate \
    "$project_root" "$pyproject_fingerprint" "$lock_fingerprint" || {
    _dev_error \
      "Project inputs changed during the runtime upgrade; .venv was left untouched."
    return 1
  }

  # One authorization covers both steps; the owner still shows, freezes, and
  # revalidates its own plan before it changes .venv.
  _dev_info "Delegating the .venv rebuild to the Python suite..."
  _dev_delegate_py venv-rebuild --yes
}

typeset -g _DEV_UPDATE_PYTHON_SOURCED=1
