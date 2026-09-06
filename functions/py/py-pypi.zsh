#!/usr/bin/env zsh
# =============================================================================
# Py PyPI: bounded metadata inspection and environment-scoped package changes
# =============================================================================
#
# Sourced by py-menu.zsh. Depends on py-common and py-venv.
# Idempotent and free of source-time capability probes.
#

if [[ -n "${_PY_PYPI_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_py_prompt_package_name() {
  local purpose="${1:-Package}"
  [[ -t 0 && -t 2 ]] || {
    _py_error "A package name is required in non-interactive mode."
    return 1
  }
  print -nu2 -r -- "$purpose name: "
  local package_name=""
  IFS= read -r package_name
  local -i read_rc=$?
  if (( read_rc != 0 )); then
    print -u2 -r -- ""
    _py_info "Cancelled."
    return 130
  fi
  _py_validate_package_name "$package_name" || {
    _py_error "Package names may contain only letters, digits, dot, underscore, and hyphen."
    return 2
  }
  REPLY="$package_name"
}

_py_validate_project_file() {
  local file_path="${1:-}"
  zmodload zsh/stat 2>/dev/null || return 1
  local -A file_state=()
  [[ "$file_path" == /* && "$file_path" == "${file_path:A}" \
    && -f "$file_path" && ! -L "$file_path" ]] \
    && zstat -LH file_state -- "$file_path" 2>/dev/null \
    && (( (file_state[mode] & 8#170000) == 8#100000 \
      && file_state[uid] == EUID \
      && file_state[nlink] == 1 \
      && (file_state[mode] & 8#22) == 0 \
      && file_state[size] >= 0 \
      && file_state[size] <= 2 * 1024 * 1024 )) || {
    _py_error "Refusing an unsafe project metadata file: $file_path"
    return 1
  }
}

_py_project_uses_poetry() {
  local pyproject="$1"
  _py_require_tomllib || return 2
  command python3 -I -c '
import pathlib
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
try:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if isinstance(data.get("tool", {}).get("poetry"), dict) else 1)
' "$pyproject" </dev/null >/dev/null 2>&1
}

_py_snapshot_optional_project_file() {
  local file_path="$1" expected="${2:-}"
  _py_validate_project_root || return $?
  local root="$REPLY"
  [[ "${file_path:h}" == "$root" ]] || {
    _py_error "Refusing a project state file outside the project root."
    return 1
  }
  _py_fingerprint_owned_directory "$root" || return $?
  local root_fingerprint="$REPLY"
  local state="absent:${root_fingerprint}"

  if [[ -e "$file_path" || -L "$file_path" ]]; then
    [[ "$expected" != absent:* ]] || {
      _py_error "${file_path:t} appeared after the package plan was reviewed."
      return 1
    }
    _py_fingerprint_owned_file \
      "$file_path" $(( 16 * 1024 * 1024 )) \
      "${expected#present:}" || return $?
    state="present:${REPLY}"
  elif [[ -n "$expected" && "$expected" != absent:* ]]; then
    _py_error "${file_path:t} disappeared after the package plan was reviewed."
    return 1
  elif [[ -n "$expected" && "$state" != "$expected" ]]; then
    _py_error "The project root changed after the package plan was reviewed."
    return 1
  fi
  REPLY="$state"
}

# Return backend, target, target/root fingerprints, lock path/state,
# interpreter fingerprint, and all optional project-file states as one
# tab-delimited record.
_py_detect_package_backend() {
  _py_validate_project_root || return $?
  local root="$REPLY"
  _py_fingerprint_owned_directory "$root" || return $?
  local root_fingerprint="$REPLY"
  local pyproject="$root/pyproject.toml"

  if [[ ! -e "$pyproject" && ! -L "$pyproject" ]]; then
    local orphan_lock=""
    for orphan_lock in "$root/poetry.lock" "$root/uv.lock"; do
      if [[ -e "$orphan_lock" || -L "$orphan_lock" ]]; then
        _py_error \
          "${orphan_lock:t} exists without pyproject.toml; package backend selection failed closed."
        return 1
      fi
    done
  fi

  if [[ -e "$pyproject" || -L "$pyproject" ]]; then
    _py_validate_project_file "$pyproject" || return $?
    _py_fingerprint_owned_file "$pyproject" $(( 2 * 1024 * 1024 )) \
      || return $?
    local project_fingerprint="$REPLY"
    local -i poetry_marker_rc=0
    _py_project_uses_poetry "$pyproject" || poetry_marker_rc=$?
    if (( poetry_marker_rc > 1 )); then
      _py_error "Could not safely parse pyproject.toml; package backend selection failed closed."
      return 1
    fi

    local poetry_lock="$root/poetry.lock"
    local uv_lock="$root/uv.lock"
    if (( poetry_marker_rc == 0 )) \
      || [[ -e "$poetry_lock" || -L "$poetry_lock" ]]; then
      (( poetry_marker_rc == 0 )) || {
        _py_error "poetry.lock exists but pyproject.toml has no valid Poetry marker."
        return 1
      }
      _py_check_command poetry || {
        _py_error "This is a Poetry project; refusing fallback to another backend."
        return 1
      }
      _py_fingerprint_owned_file \
        "$pyproject" $(( 2 * 1024 * 1024 )) "$project_fingerprint" \
        || return $?
      _py_snapshot_optional_project_file "$poetry_lock" || return $?
      local poetry_lock_state="$REPLY"
      _py_fingerprint_owned_directory \
        "$root" "$root_fingerprint" || return $?
      REPLY=$'poetry-project\t'"$root"$'\t'"$project_fingerprint"$'\t'"$root_fingerprint"$'\t'"$poetry_lock"$'\t'"$poetry_lock_state"$'\t-\t-\t-\t-'
      return 0
    fi

    if [[ -e "$uv_lock" || -L "$uv_lock" ]]; then
      _py_check_command uv || {
        _py_error "uv.lock exists but uv is unavailable; refusing backend fallback."
        return 1
      }
    fi
    if command -v uv &>/dev/null; then
      _py_assert_no_external_uv_workspace "$root" || return $?
      _py_fingerprint_owned_file \
        "$pyproject" $(( 2 * 1024 * 1024 )) "$project_fingerprint" \
        || return $?
      _py_snapshot_optional_project_file "$uv_lock" || return $?
      local uv_lock_state="$REPLY"
      _py_fingerprint_owned_directory \
        "$root" "$root_fingerprint" || return $?
      REPLY=$'uv-project\t'"$root"$'\t'"$project_fingerprint"$'\t'"$root_fingerprint"$'\t'"$uv_lock"$'\t'"$uv_lock_state"$'\t-\t-\t-\t-'
      return 0
    fi
  fi

  local records=""
  records=$(_py_snapshot_local_venvs) || return $?
  [[ -n "$records" ]] || {
    _py_error "No validated project backend or local virtual environment was found."
    _py_info "Create .venv first; ambient pip installation is never used."
    return 1
  }

  local -a record_snapshot=("${(@f)records}")
  local record="${record_snapshot[1]}" environment_path=""
  if (( ${#record_snapshot[@]} > 1 )); then
    _py_select_venv_record "$records" "Package env > "
    local select_rc=$?
    (( select_rc == 130 )) && return 130
    (( select_rc == 0 )) || return "$select_rc"
    record="$REPLY"
  fi
  _py_venv_record_path "$record"
  environment_path="$REPLY"
  _py_venv_record_fingerprint "$record"
  local environment_fingerprint="$REPLY"
  _py_validate_venv_path "$environment_path" "$environment_fingerprint" \
    || return $?
  _py_fingerprint_venv_python "$environment_path" || return $?
  local python_fingerprint="$REPLY"

  _py_snapshot_optional_project_file "$pyproject" || return $?
  local pyproject_state="$REPLY"
  _py_snapshot_optional_project_file "$root/poetry.lock" || return $?
  local poetry_lock_state="$REPLY"
  _py_snapshot_optional_project_file "$root/uv.lock" || return $?
  local uv_lock_state="$REPLY"
  _py_fingerprint_owned_directory "$root" "$root_fingerprint" || return $?

  if command -v uv &>/dev/null; then
    REPLY=$'uv-environment\t'"$environment_path"$'\t'"$environment_fingerprint"$'\t'"$root_fingerprint"$'\t-\t-\t'"$python_fingerprint"$'\t'"$pyproject_state"$'\t'"$poetry_lock_state"$'\t'"$uv_lock_state"
    return 0
  fi
  [[ -x "$environment_path/bin/python" ]] || {
    _py_error "The validated environment has no executable Python interpreter."
    return 1
  }
  REPLY=$'python-environment\t'"$environment_path"$'\t'"$environment_fingerprint"$'\t'"$root_fingerprint"$'\t-\t-\t'"$python_fingerprint"$'\t'"$pyproject_state"$'\t'"$poetry_lock_state"$'\t'"$uv_lock_state"
}

_py_package_usage() {
  case "$1" in
    package-search)
      print -u2 -r -- "Usage: py-menu package-search [PACKAGE]"
      ;;
    package-install)
      print -u2 -r -- \
        "Usage: py-menu package-install [PACKAGE] [--dev] [--dry-run] [--yes]"
      ;;
    package-uninstall)
      print -u2 -r -- \
        "Usage: py-menu package-uninstall [PACKAGE] [--dry-run] [--yes]"
      ;;
  esac
}

_py_fetch_package_metadata() {
  local package_name="$1"
  _py_check_command curl || return 1
  _py_require_tomllib || return $?

  _py_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _py_error "Refusing an unsafe temporary root for the PyPI query."
    return 1
  }
  local temp_root="$REPLY"
  local query_dir=""
  query_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-py-pypi.XXXXXX" 2>/dev/null) || {
    _py_error "Could not create a private PyPI query directory."
    return 1
  }
  command chmod 700 -- "$query_dir" 2>/dev/null || {
    command rmdir -- "$query_dir" 2>/dev/null
    _py_error "Could not protect the PyPI query directory."
    return 1
  }
  zmodload zsh/stat 2>/dev/null || {
    command rmdir -- "$query_dir" 2>/dev/null
    _py_error "Zsh stat support is required for PyPI queries."
    return 1
  }
  local -A query_dir_state=() response_state=() current_state=()
  [[ "$query_dir" == "${query_dir:a}" \
    && "$query_dir" == "${query_dir:A}" \
    && -d "$query_dir" && ! -L "$query_dir" \
    && "${query_dir:t}" == zdx-py-pypi.* ]] \
    && zstat -LH query_dir_state -- "$query_dir" 2>/dev/null \
    && (( (query_dir_state[mode] & 8#170000) == 8#040000 \
      && query_dir_state[uid] == EUID \
      && (query_dir_state[mode] & 8#77) == 0 )) || {
    command rmdir -- "$query_dir" 2>/dev/null
    _py_error "Refusing an unsafe PyPI query directory."
    return 1
  }
  local query_dir_identity="${query_dir_state[device]}:${query_dir_state[inode]}:${query_dir_state[uid]}"
  local response_file="$query_dir/response.json"
  local -i query_rc=0 parse_rc=0
  local response_identity=""

  {
    umask 077
    command : > "$response_file" || {
      _py_error "Could not create a private PyPI response file."
      query_rc=1
    }
    command chmod 600 -- "$response_file" 2>/dev/null || query_rc=1
    if (( query_rc == 0 )); then
      [[ "$response_file" == "${response_file:a}" \
        && "$response_file" == "${response_file:A}" \
        && "${response_file:h}" == "$query_dir" \
        && -f "$response_file" && ! -L "$response_file" ]] \
        && zstat -LH response_state -- "$response_file" 2>/dev/null \
        && (( (response_state[mode] & 8#170000) == 8#100000 \
          && response_state[uid] == EUID \
          && response_state[nlink] == 1 \
          && (response_state[mode] & 8#77) == 0 )) || {
        _py_error "Refusing an unsafe PyPI response file."
        query_rc=1
      }
      response_identity="${response_state[device]}:${response_state[inode]}:${response_state[uid]}:${response_state[nlink]}"
    fi
    if (( query_rc == 0 )); then
      command curl \
        --proto '=https' \
        --proto-redir '=https' \
        --fail \
        --silent \
        --show-error \
        --location \
        --connect-timeout 5 \
        --max-time 20 \
        --max-filesize 2097152 \
        --output "$response_file" \
        "https://pypi.org/pypi/${package_name}/json" >&2 \
        || query_rc=$?
    fi
    if (( query_rc == 0 )); then
      current_state=()
      zstat -LH current_state -- "$response_file" 2>/dev/null \
        && [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
          == "$response_identity" ]] \
        && (( (current_state[mode] & 8#170000) == 8#100000 \
          && (current_state[mode] & 8#77) == 0 \
          && current_state[size] > 0 \
          && current_state[size] <= 2 * 1024 * 1024 )) || {
        _py_error "The PyPI response changed or exceeded the size limit."
        query_rc=1
      }
    fi
    if (( query_rc == 0 )); then
      command python3 -I -c '
import json
import pathlib
import sys

def safe(value, limit):
    text = str(value or "")[:limit]
    return "".join(
        char if char.isprintable() and char not in "\r\n\t" else
        "\\x%02x" % ord(char)
        for char in text
    )

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
info = payload.get("info") or {}
for label, key, limit in (
    ("Name", "name", 128),
    ("Version", "version", 128),
    ("Summary", "summary", 500),
    ("Python", "requires_python", 128),
    ("Project", "project_url", 500),
):
    print(f"{label}: {safe(info.get(key), limit)}", file=sys.stderr)
' "$response_file" </dev/null || parse_rc=$?
    fi
  } always {
    if [[ -f "$response_file" && ! -L "$response_file" \
      && "${response_file:a}" == "$response_file" \
      && "${response_file:A}" == "$response_file" \
      && "${response_file:h}" == "$query_dir" ]]; then
      current_state=()
      if [[ -n "$response_identity" ]] \
        && zstat -LH current_state -- "$response_file" 2>/dev/null \
        && [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
          == "$response_identity" ]]; then
        command rm -f -- "$response_file" 2>/dev/null || parse_rc=1
      else
        _py_warn "The PyPI response changed; refusing cleanup."
        parse_rc=1
      fi
    fi
    if [[ -d "$query_dir" && ! -L "$query_dir" \
      && "${query_dir:a}" == "$query_dir" \
      && "${query_dir:A}" == "$query_dir" \
      && "${query_dir:t}" == zdx-py-pypi.* ]]; then
      current_state=()
      if zstat -LH current_state -- "$query_dir" 2>/dev/null \
        && [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}" \
          == "$query_dir_identity" ]]; then
        command rmdir -- "$query_dir" 2>/dev/null || parse_rc=1
      else
        _py_warn "The PyPI query directory changed; refusing cleanup."
        parse_rc=1
      fi
    fi
  }

  (( query_rc == 0 )) || {
    _py_error "PyPI metadata request failed (status $query_rc)."
    return "$query_rc"
  }
  (( parse_rc == 0 )) || {
    _py_error "PyPI returned invalid or unreadable metadata."
    return 1
  }
}

package-search() {
  emulate -L zsh
  local package_name=""
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _py_package_usage package-search
        return 0
        ;;
      -*)
        _py_error "Unknown package-search option: $1"
        return 2
        ;;
      *)
        [[ -z "$package_name" ]] || {
          _py_error "Only one package may be inspected."
          return 2
        }
        [[ -n "$1" ]] || {
          _py_error "Package operands may not be empty."
          return 2
        }
        package_name="$1"
        ;;
    esac
    shift
  done

  if [[ -z "$package_name" ]]; then
    _py_prompt_package_name "PyPI package"
    local prompt_rc=$?
    (( prompt_rc == 130 )) && return 0
    (( prompt_rc == 0 )) || return "$prompt_rc"
    package_name="$REPLY"
  fi
  _py_validate_package_name "$package_name" || {
    _py_error "Invalid package name."
    return 2
  }
  _py_header "PyPI Package Metadata"
  _py_info "Fetching bounded metadata for $package_name..."
  _py_fetch_package_metadata "$package_name"
}

_py_run_package_change() {
  local operation="$1" backend="$2" target="$3"
  local package_name="$4"
  local -i development=${5:-0}
  local -i operation_rc=0

  case "$backend:$operation" in
    uv-project:install)
      local -a uv_args=(add)
      (( development )) && uv_args+=(--dev)
      _py_run_uv_scoped --directory "$target" --project "$target" \
        "${uv_args[@]}" "$package_name" >&2 || operation_rc=$?
      ;;
    uv-project:uninstall)
      _py_run_uv_scoped --directory "$target" --project "$target" \
        remove "$package_name" >&2 || operation_rc=$?
      ;;
    poetry-project:install)
      local -a poetry_args=(add)
      (( development )) && poetry_args+=(--group dev)
      command poetry "${poetry_args[@]}" "$package_name" >&2 \
        || operation_rc=$?
      ;;
    poetry-project:uninstall)
      command poetry remove "$package_name" >&2 || operation_rc=$?
      ;;
    uv-environment:install)
      _py_run_uv_scoped pip install --python "$target/bin/python" \
        "$package_name" >&2 || operation_rc=$?
      ;;
    uv-environment:uninstall)
      _py_run_uv_scoped pip uninstall --python "$target/bin/python" \
        "$package_name" >&2 || operation_rc=$?
      ;;
    python-environment:install)
      command "$target/bin/python" -I -m pip install -- \
        "$package_name" >&2 || operation_rc=$?
      ;;
    python-environment:uninstall)
      command "$target/bin/python" -I -m pip uninstall -y -- \
        "$package_name" >&2 || operation_rc=$?
      ;;
    *)
      _py_error "Unsupported package transaction: $backend/$operation"
      return 1
      ;;
  esac
  return "$operation_rc"
}

_py_package_change() {
  emulate -L zsh
  local operation="$1"
  shift
  local package_name=""
  local -i development=0 dry_run=0 assume_yes=0

  while (( $# > 0 )); do
    case "$1" in
      --dev)
        [[ "$operation" == install ]] || {
          _py_error "--dev is only valid for package-install."
          return 2
        }
        development=1
        ;;
      --dry-run) dry_run=1 ;;
      --yes) assume_yes=1 ;;
      -h|--help)
        (( $# == 1 )) || return 2
        _py_package_usage "package-$operation"
        return 0
        ;;
      -*)
        _py_error "Unknown package-$operation option: $1"
        return 2
        ;;
      *)
        [[ -z "$package_name" ]] || {
          _py_error "Only one package may be changed."
          return 2
        }
        [[ -n "$1" ]] || {
          _py_error "Package operands may not be empty."
          return 2
        }
        package_name="$1"
        ;;
    esac
    shift
  done

  if [[ -z "$package_name" ]]; then
    _py_prompt_package_name "Package to $operation"
    local prompt_rc=$?
    (( prompt_rc == 130 )) && return 0
    (( prompt_rc == 0 )) || return "$prompt_rc"
    package_name="$REPLY"
  fi
  _py_validate_package_name "$package_name" || {
    _py_error "Invalid package name."
    return 2
  }

  _py_detect_package_backend
  local backend_rc=$?
  (( backend_rc == 130 )) && {
    _py_info "Cancelled."
    return 0
  }
  (( backend_rc == 0 )) || return "$backend_rc"
  local backend_plan="$REPLY"
  local backend="${REPLY%%$'\t'*}"
  local backend_record="${REPLY#*$'\t'}"
  local target="${backend_record%%$'\t'*}"
  backend_record="${backend_record#*$'\t'}"
  local target_fingerprint="${backend_record%%$'\t'*}"
  backend_record="${backend_record#*$'\t'}"
  local root_fingerprint="${backend_record%%$'\t'*}"
  backend_record="${backend_record#*$'\t'}"
  local lock_file="${backend_record%%$'\t'*}"
  backend_record="${backend_record#*$'\t'}"
  local lock_state="${backend_record%%$'\t'*}"
  backend_record="${backend_record#*$'\t'}"
  local python_fingerprint="${backend_record%%$'\t'*}"
  backend_record="${backend_record#*$'\t'}"
  local pyproject_state="${backend_record%%$'\t'*}"
  backend_record="${backend_record#*$'\t'}"
  local poetry_lock_state="${backend_record%%$'\t'*}"
  local uv_lock_state="${backend_record#*$'\t'}"

  _py_header "Package ${operation:u}"
  _py_info "Plan: $operation $package_name with $backend"
  _py_info "Target: $target"
  _py_info "Frozen project root identity: $root_fingerprint"
  [[ "$lock_file" == - ]] \
    || _py_info "Frozen lock state: ${lock_file:t} (${lock_state%%:*})"
  [[ "$python_fingerprint" == - ]] \
    || _py_info "Frozen environment interpreter: $target/bin/python"
  if [[ "$pyproject_state" != - ]]; then
    _py_info "Frozen project metadata state: pyproject.toml (${pyproject_state%%:*})"
    _py_info "Frozen project metadata state: poetry.lock (${poetry_lock_state%%:*})"
    _py_info "Frozen project metadata state: uv.lock (${uv_lock_state%%:*})"
  fi
  [[ "$operation" == install ]] \
    && _py_warn "Installation resolves and executes code obtained from package indexes."
  _py_warn "Ambient or user-level pip is never used."
  (( dry_run )) && {
    _py_success "Dry run complete; no package state changed."
    return 0
  }

  local _PY_AUTO_YES=$assume_yes
  _py_confirm "Proceed with this reviewed package $operation?"
  local confirm_rc=$?
  case "$confirm_rc" in
    0) ;;
    130)
      _py_info "Cancelled."
      return 0
      ;;
    *) return "$confirm_rc" ;;
  esac

  case "$backend" in
    uv-project|poetry-project)
      _py_validate_project_root || return $?
      [[ "$REPLY" == "$target" ]] || {
        _py_error "The package project boundary changed after review."
        return 1
      }
      _py_fingerprint_owned_directory \
        "$target" "$root_fingerprint" || return $?
      _py_detect_package_backend || return $?
      [[ "$REPLY" == "$backend_plan" ]] || {
        _py_error "The package backend or reviewed lock state changed after review."
        return 1
      }
      _py_fingerprint_owned_file \
        "$target/pyproject.toml" $(( 2 * 1024 * 1024 )) \
        "$target_fingerprint" || return $?
      _py_snapshot_optional_project_file \
        "$lock_file" "$lock_state" || return $?
      if [[ "$backend" == poetry-project ]]; then
        _py_check_command poetry || return 1
        _py_project_uses_poetry "$target/pyproject.toml" || {
          _py_error "The Poetry project marker changed after review."
          return 1
        }
      else
        _py_check_command uv || return 1
      fi
      ;;
    uv-environment|python-environment)
      _py_validate_venv_path "$target" "$target_fingerprint" || return $?
      _py_fingerprint_venv_python \
        "$target" "$python_fingerprint" || return $?
      _py_validate_project_root || return $?
      local environment_root="$REPLY"
      _py_fingerprint_owned_directory \
        "$environment_root" "$root_fingerprint" || return $?
      _py_snapshot_optional_project_file \
        "$environment_root/pyproject.toml" "$pyproject_state" || return $?
      _py_snapshot_optional_project_file \
        "$environment_root/poetry.lock" "$poetry_lock_state" || return $?
      _py_snapshot_optional_project_file \
        "$environment_root/uv.lock" "$uv_lock_state" || return $?
      if [[ "$backend" == uv-environment ]]; then
        _py_check_command uv || return 1
      elif command -v uv &>/dev/null; then
        _py_error "uv appeared after review; refusing to change the selected environment backend."
        return 1
      fi
      ;;
  esac

  _py_run_package_change \
    "$operation" "$backend" "$target" "$package_name" "$development"
  local operation_rc=$?
  (( operation_rc == 0 )) || {
    _py_error "Package $operation failed (status $operation_rc)."
    return "$operation_rc"
  }
  _py_success "Package $operation completed: $package_name"
}

package-install() {
  _py_package_change install "$@"
}

package-uninstall() {
  _py_package_change uninstall "$@"
}

typeset -g _PY_PYPI_SOURCED=1
