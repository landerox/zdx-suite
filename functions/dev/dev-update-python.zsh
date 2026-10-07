#!/usr/bin/env zsh
# =============================================================================
# Dev Update Python: staged .venv replacement or delegation to py-menu
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-state.zsh, dev-pypi.zsh, and
# dev-update-transaction.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_UPDATE_PYTHON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Python runtime ---------------------------------------------------------

# Creates a private, same-filesystem workspace below the project root.
# Sets reply=(workspace directory_identity).
_dev_update_python_workspace_create() {
  local project_root="$1"
  local expected_project_identity="$2"
  reply=()

  local current_project_identity
  current_project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || return 1
  [[ "$current_project_identity" == "$expected_project_identity" ]] || {
    _dev_error "The project directory changed before Python staging."
    return 1
  }

  local workspace_dir
  workspace_dir=$(command mktemp -d \
    "${project_root}/.zdx-dev-python.XXXXXX" 2>/dev/null) || {
    _dev_error "Could not create a private Python update workspace."
    return 1
  }

  command chmod -- 700 "$workspace_dir" 2>/dev/null || {
    _dev_error "Could not restrict the Python update workspace."
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  }

  current_project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || {
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  }
  if [[ "$current_project_identity" != "$expected_project_identity" ]]; then
    _dev_error "The project directory changed during Python staging."
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  fi

  local workspace_identity
  workspace_identity=$(
    _dev_update_workspace_identity "$workspace_dir" "$project_root"
  ) || {
    _dev_error "Could not validate the private Python update workspace."
    _dev_drvfs_mode_hint "$workspace_dir"
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  }

  reply=("$workspace_dir" "$workspace_identity")
}

_dev_update_python_workspace_validate() {
  local project_root="$1"
  local expected_project_identity="$2"
  local workspace_dir="$3"
  local expected_workspace_identity="$4"

  local current_project_identity
  current_project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || return 1
  [[ "$current_project_identity" == "$expected_project_identity" ]] || return 1

  local current_workspace_identity
  current_workspace_identity=$(
    _dev_update_workspace_identity "$workspace_dir" "$project_root"
  ) || return 1
  [[ "$current_workspace_identity" == "$expected_workspace_identity" ]]
}

# Quarantines the proven project-local workspace before recursive removal.
_dev_update_python_workspace_cleanup() {
  local project_root="$1"
  local project_identity="$2"
  local workspace_dir="$3"
  local workspace_identity="$4"

  [[ -n "$workspace_dir" ]] || return 0
  if [[ ! -e "$workspace_dir" && ! -L "$workspace_dir" ]]; then
    local current_project_identity
    current_project_identity=$(
      _dev_write_directory_identity \
        "$project_root" "Python update project directory"
    ) || return 1
    [[ "$current_project_identity" == "$project_identity" ]]
    return $?
  fi

  if ! _dev_update_python_workspace_validate \
    "$project_root" "$project_identity" \
    "$workspace_dir" "$workspace_identity"; then
    _dev_error \
      "The Python update workspace changed identity; refusing recursive removal."
    return 1
  fi

  local quarantine="${project_root}/.zdx-dev-python.cleanup.${$}.${RANDOM}.${RANDOM}"
  if [[ -e "$quarantine" || -L "$quarantine" ]] \
    || ! command mv -- "$workspace_dir" "$quarantine" 2>/dev/null; then
    _dev_error "Could not quarantine the Python update workspace."
    return 1
  fi

  if ! _dev_update_python_workspace_validate \
    "$project_root" "$project_identity" \
    "$quarantine" "$workspace_identity"; then
    _dev_error "The quarantined Python update workspace is no longer safe."
    return 1
  fi

  command rm -rf -- "$quarantine" 2>/dev/null
  local -i remove_rc=$?
  if (( remove_rc != 0 )) || [[ -e "$quarantine" || -L "$quarantine" ]]; then
    _dev_error "Could not remove the quarantined Python update workspace."
    return 1
  fi
  return 0
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

  local version_token="${current_version#Python }"
  local major_version="${version_token%%.*}"
  local remaining_version="${version_token#*.}"
  local minor_version="${remaining_version%%.*}"
  if [[ "$major_version" != <-> || "$minor_version" != <-> ]]; then
    _dev_error \
      "Could not determine the current .venv Python minor version."
    _dev_info \
      "Choose it explicitly with: py-menu venv-python-pin <major.minor>"
    return 1
  fi

  REPLY="${major_version}.${minor_version}"
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

# Builds and synchronizes a replacement environment privately, then swaps it
# into place only after the original environment is revalidated.
_dev_update_python_rebuild() {
  local project_root="$1"
  local project_identity="$2"
  local expected_venv_identity="$3"
  local current_version="$4"
  local python_request="$5"
  local expected_pyproject_fingerprint="$6"
  local expected_lock_fingerprint="$7"

  local -a reply=()
  _dev_update_python_workspace_create \
    "$project_root" "$project_identity" || return 1
  local workspace_dir="${reply[1]}"
  local workspace_identity="${reply[2]}"
  local staged_venv="${workspace_dir}/new-venv"
  local original_venv="${workspace_dir}/original-venv"
  local -i preserve_workspace=0
  local -i original_moved=0
  local -i operation_rc=1
  local new_version=""

  {
    _dev_info "Upgrading uv-managed Python patch releases..."
    if ! _dev_update_python_inputs_validate \
      "$project_root" "$expected_pyproject_fingerprint" \
      "$expected_lock_fingerprint"; then
      _dev_error \
        "Project inputs changed before the Python upgrade could start."
    elif ! command uv python install --upgrade "$python_request" >&2; then
      _dev_error \
        "Python installation failed. The existing .venv was left untouched."
    else
      _dev_info "Building a replacement environment privately..."
      # Both activation and installed console scripts must survive the rename
      # from the private workspace to .venv and the later workspace removal.
      if ! command uv venv --clear --managed-python \
        --python "$python_request" --relocatable "$staged_venv" >&2; then
        _dev_error \
          "Could not create the replacement environment; .venv was left untouched."
      else
        local staged_venv_identity
        staged_venv_identity=$(
          _dev_directory_identity \
            "$staged_venv" "staged Python environment"
        )
        if [[ -z "$staged_venv_identity" \
          || ! -x "${staged_venv}/bin/python" ]]; then
          _dev_error \
            "The replacement environment did not contain a usable Python."
        else
          _dev_info \
            "Synchronizing the replacement environment from the current lockfile..."
          if ! _dev_update_python_inputs_validate \
            "$project_root" "$expected_pyproject_fingerprint" \
            "$expected_lock_fingerprint"; then
            _dev_error \
              "Project inputs changed before environment synchronization."
          elif ! UV_PROJECT_ENVIRONMENT="$staged_venv" \
            command uv sync --all-groups --locked >&2; then
            _dev_error \
              "Environment sync failed. Run dev-update-lock first if uv.lock is stale or missing."
            _dev_info "The existing .venv was left untouched."
          else
            local current_staged_identity
            current_staged_identity=$(
              _dev_directory_identity \
                "$staged_venv" "staged Python environment"
            )
            local current_project_identity
            current_project_identity=$(
              _dev_write_directory_identity \
                "$project_root" "Python update project directory"
            )
            local current_venv_identity
            current_venv_identity=$(
              _dev_directory_identity \
                "${project_root}/.venv" "existing Python environment"
            )

            if ! _dev_update_python_inputs_validate \
              "$project_root" "$expected_pyproject_fingerprint" \
              "$expected_lock_fingerprint"; then
              _dev_error \
                "Project inputs changed while the environment was synchronized."
            elif [[ "$current_staged_identity" != "$staged_venv_identity" \
              || "$current_project_identity" != "$project_identity" \
              || "$current_venv_identity" != "$expected_venv_identity" \
              || "${PWD:A}" != "$project_root" ]]; then
              _dev_error \
                "The project or environment changed during Python staging."
            else
              new_version=$(
                command "${staged_venv}/bin/python" --version 2>/dev/null
              ) || new_version=""
              local staged_implementation=""
              staged_implementation=$(
                command "${staged_venv}/bin/python" -I -c \
                  'import platform; print(platform.python_implementation())' \
                  2>/dev/null
              ) || staged_implementation=""
              if [[ -z "$new_version" ]]; then
                _dev_error \
                  "Could not verify the staged Python interpreter."
              elif [[ "$new_version" != "Python ${python_request}."<-> \
                || "$staged_implementation" != "CPython" ]]; then
                _dev_error \
                  "The staged interpreter does not match CPython $python_request; .venv was left untouched."
              elif ! command mv -- \
                "${project_root}/.venv" "$original_venv"; then
                _dev_error \
                  "Could not preserve the existing .venv before publication."
              else
                original_moved=1
                local moved_original_identity
                moved_original_identity=$(
                  _dev_directory_identity \
                    "$original_venv" "preserved Python environment"
                )
                if [[ "$moved_original_identity" != \
                  "$expected_venv_identity" ]]; then
                  preserve_workspace=1
                  _dev_error \
                    "The preserved environment changed identity; automatic publication was refused."
                elif command mv -- \
                  "$staged_venv" "${project_root}/.venv"; then
                  local published_venv_identity
                  published_venv_identity=$(
                    _dev_directory_identity \
                      "${project_root}/.venv" "published Python environment"
                  )
                  if [[ "$published_venv_identity" == \
                    "$staged_venv_identity" ]]; then
                    operation_rc=0
                  else
                    preserve_workspace=1
                    _dev_error \
                      "The published environment could not be verified."
                  fi
                else
                  _dev_error \
                    "Could not publish the replacement environment; restoring the original."
                  if [[ ! -e "${project_root}/.venv" \
                    && ! -L "${project_root}/.venv" ]] \
                    && command mv -- \
                      "$original_venv" "${project_root}/.venv"; then
                    local restored_venv_identity
                    restored_venv_identity=$(
                      _dev_directory_identity \
                        "${project_root}/.venv" "restored Python environment"
                    )
                    if [[ "$restored_venv_identity" == \
                      "$expected_venv_identity" ]]; then
                      original_moved=0
                      _dev_warn \
                        "The original .venv was restored after publication failed."
                    else
                      preserve_workspace=1
                      _dev_error \
                        "The restored environment could not be verified."
                    fi
                  else
                    preserve_workspace=1
                    _dev_error \
                      "Automatic .venv rollback failed; the original is retained in the recovery workspace."
                  fi
                fi
              fi
            fi
          fi
        fi
      fi
    fi
  } always {
    # An interrupt between the two directory renames must never make cleanup
    # delete the only preserved copy of the original environment. The flag is
    # set only after mv returns, so the filesystem decides as well.
    (( original_moved && operation_rc != 0 )) && preserve_workspace=1
    if (( operation_rc != 0 )) && [[ -n "${original_venv:-}" ]] \
      && [[ -e "$original_venv" || -L "$original_venv" ]]; then
      preserve_workspace=1
    fi

    if (( preserve_workspace )); then
      _dev_warn \
        "Python recovery workspace retained: $workspace_dir"
    elif ! _dev_update_python_workspace_cleanup \
      "$project_root" "$project_identity" \
      "$workspace_dir" "$workspace_identity"; then
      operation_rc=1
      preserve_workspace=1
      _dev_warn \
        "Python recovery workspace retained: $workspace_dir"
    fi
  }

  (( operation_rc == 0 )) || return 1
  _dev_success \
    "Python updated: ${current_version:-unknown} -> ${new_version:-unknown}"
  return 0
}

# dev-update-python
#   Arguments: --yes | --help
#   Effects:   delegates runtime installation to py-menu when .venv is absent;
#              otherwise upgrades uv-managed Python installations and, after
#              confirmation, stages and replaces the existing .venv.
dev-update-python() {
  emulate -L zsh

  local -i auto_yes=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-update-python [--yes]"
        print -u2 -r -- \
          "  Delegate runtime selection and installation, or safely replace .venv."
        print -u2 -r -- \
          "  --yes   Skip confirmation; delegated version selection may still prompt."
        print -u2 -r -- \
          "  For unattended installation: py-menu venv-python-install VERSION --yes"
        return 0
        ;;
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
    _dev_info "Delegating to the Python suite..."
    _dev_delegate_py "${delegate_arguments[@]}"
    return $?
  fi

  _dev_require_command uv || return 1

  local current_version=""
  local current_implementation=""
  if [[ -d "$venv_path" ]]; then
    current_version=$(
      command "${venv_path}/bin/python" --version 2>/dev/null
    )
    current_implementation=$(
      command "${venv_path}/bin/python" -I -c \
        'import platform; print(platform.python_implementation())' 2>/dev/null
    )
    _dev_info "Current venv Python: ${current_version:-unknown}"
  fi

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

  local -i previous_auto_yes=$_DEV_AUTO_YES
  local rebuild_outcome="declined"
  {
    (( auto_yes )) && _DEV_AUTO_YES=1
    _dev_warn \
      "Replacing .venv discards packages not represented by the current lockfile."
    _dev_info \
      "The replacement will be built and synchronized before .venv is swapped."
    rebuild_outcome=$(_dev_confirm_outcome \
      "Upgrade Python and replace .venv?")
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

  _dev_update_python_rebuild \
    "$project_root" "$project_identity" "$venv_identity" \
    "$current_version" "$python_request" \
    "$pyproject_fingerprint" "$lock_fingerprint"
}

typeset -g _DEV_UPDATE_PYTHON_SOURCED=1
