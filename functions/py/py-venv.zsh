#!/usr/bin/env zsh
# =============================================================================
# Py Venv: validated local environments and uv-managed Python runtimes
# =============================================================================
#
# Sourced by py-menu.zsh. Depends on py-common.
# Idempotent and free of source-time capability probes.
#

if [[ -n "${_PY_VENV_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_py_detect_venv_backend() {
  if [[ -f "$PWD/uv.lock" ]] && command -v uv &>/dev/null; then
    print -r -- uv
  elif [[ -f "$PWD/poetry.lock" ]] && command -v poetry &>/dev/null; then
    print -r -- poetry
  elif command -v uv &>/dev/null; then
    print -r -- uv
  else
    print -r -- stdlib
  fi
}

_py_validate_project_root() {
  zmodload zsh/stat 2>/dev/null || {
    _py_error "Zsh stat support is required for environment validation."
    return 1
  }

  local root="${PWD:a}"
  local -A root_state=()
  [[ "$root" == /* && "$root" == "${root:A}" \
    && -d "$root" && ! -L "$root" \
    && "$root" != *[[:cntrl:]]* && "$root" != *'|'* ]] \
    && zstat -LH root_state -- "$root" 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 \
      && root_state[uid] == EUID \
      && (root_state[mode] & 8#22) == 0 )) || {
    _py_error "The project directory must be owned, symlink-free, and not group/world-writable."
    return 1
  }
  _py_validate_ancestor_chain "$root" || {
    _py_error "The project path contains an untrusted ancestor."
    return 1
  }
  REPLY="$root"
}

_py_fingerprint_owned_directory() {
  local directory="$1" expected="${2:-}"
  zmodload zsh/stat 2>/dev/null || return 1
  local -A directory_state=()
  [[ "$directory" == /* && "$directory" == "${directory:A}" \
    && -d "$directory" && ! -L "$directory" \
    && "$directory" != *[[:cntrl:]]* && "$directory" != *'|'* ]] \
    && zstat -LH directory_state -- "$directory" 2>/dev/null \
    && (( (directory_state[mode] & 8#170000) == 8#040000 \
      && directory_state[uid] == EUID \
      && (directory_state[mode] & 8#22) == 0 )) || {
    _py_error "Refusing an unsafe owned directory: $directory"
    return 1
  }
  _py_validate_ancestor_chain "$directory" || {
    _py_error "The directory path contains an untrusted ancestor: $directory"
    return 1
  }
  local fingerprint="${directory_state[device]}:${directory_state[inode]}:${directory_state[mode]}:${directory_state[uid]}"
  [[ -z "$expected" || "$fingerprint" == "$expected" ]] || {
    _py_error "The owned directory changed after review: $directory"
    return 1
  }
  REPLY="$fingerprint"
}

_py_venv_path_is_allowed() {
  local root="$1" candidate="$2"
  case "$candidate" in
    "$root/.venv"|"$root/venv")
      return 0
      ;;
    "$root/.virtualenvs/"*)
      local relative="${candidate#"$root/.virtualenvs/"}"
      [[ -n "$relative" && ${#relative} -le 128 \
        && "$relative" != */* \
        && "$relative" != *[[:cntrl:]]* \
        && "$relative" != *'|'* \
        && "$relative" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
      ;;
    *) return 1 ;;
  esac
}

_py_validate_venv_parent() {
  local candidate="$1" expected="${2:-}"
  _py_validate_project_root || return $?
  local root="$REPLY"
  candidate="${candidate:a}"
  _py_venv_path_is_allowed "$root" "$candidate" || {
    _py_error "Refusing a virtual-environment parent outside the project."
    return 1
  }
  local parent="${candidate:h}"
  case "$candidate" in
    "$root/.venv"|"$root/venv")
      parent="$root"
      ;;
    "$root/.virtualenvs/"*)
      parent="$root/.virtualenvs"
      ;;
    *)
      _py_error "Refusing a virtual-environment parent outside the project."
      return 1
      ;;
  esac
  _py_fingerprint_owned_directory "$parent" "$expected" || return $?
}

# Validate a local environment and return device:inode in REPLY.
_py_validate_venv_path() {
  local candidate="${1:-}" expected="${2:-}"
  _py_validate_project_root || return $?
  local root="$REPLY"
  candidate="${candidate:a}"

  _py_venv_path_is_allowed "$root" "$candidate" || {
    _py_error "Refusing a virtual environment outside the project boundary: $candidate"
    return 1
  }

  _py_validate_venv_parent "$candidate" >/dev/null || return $?
  zmodload zsh/stat 2>/dev/null || return 1
  local -A env_state=() config_state=()
  local config_file="$candidate/pyvenv.cfg"
  [[ "$candidate" == "${candidate:A}" \
    && -d "$candidate" && ! -L "$candidate" \
    && -f "$config_file" && ! -L "$config_file" ]] \
    && zstat -LH env_state -- "$candidate" 2>/dev/null \
    && zstat -LH config_state -- "$config_file" 2>/dev/null \
    && (( (env_state[mode] & 8#170000) == 8#040000 \
      && env_state[uid] == EUID \
      && (env_state[mode] & 8#22) == 0 \
      && (config_state[mode] & 8#170000) == 8#100000 \
      && config_state[uid] == EUID \
      && config_state[nlink] == 1 \
      && (config_state[mode] & 8#22) == 0 \
      && config_state[size] >= 0 \
      && config_state[size] <= 64 * 1024 )) || {
    _py_error "Refusing an untyped or unsafe virtual environment: $candidate"
    return 1
  }

  local fingerprint="${env_state[device]}:${env_state[inode]}"
  if [[ -n "$expected" && "$fingerprint" != "$expected" ]]; then
    _py_error "The selected virtual environment changed after discovery."
    return 1
  fi
  REPLY="$fingerprint"
}

# Data record: local<TAB>absolute-path<TAB>device:inode
_py_snapshot_local_venvs() {
  _py_validate_project_root || return $?
  local root="$REPLY"
  local -a candidates=("$root/.venv" "$root/venv")
  local virtualenvs_root="$root/.virtualenvs"
  if [[ -e "$virtualenvs_root" || -L "$virtualenvs_root" ]]; then
    _py_fingerprint_owned_directory "$virtualenvs_root" >/dev/null \
      || return $?
    local -a find_args=(
      find "$virtualenvs_root"
      -mindepth 1 -maxdepth 1 -type d -print
    )
    _py_timeout_prefix 10 || return $?
    find_args=("${reply[@]}" "${find_args[@]}")
    local child_output=""
    child_output=$(_py_capture_bounded_output \
      $(( 1024 * 1024 )) ".virtualenvs inventory" \
      "${find_args[@]}") || return $?
    local child_candidate=""
    local -i child_count=0
    for child_candidate in "${(@f)child_output}"; do
      (( child_count++ ))
      (( child_count <= 128 )) || {
        _py_error "Refusing more than 128 .virtualenvs children."
        return 1
      }
      _py_venv_path_is_allowed "$root" "$child_candidate" || {
        _py_error "Refusing an unsafe .virtualenvs child name."
        return 1
      }
      candidates+=("$child_candidate")
    done
  fi
  local candidate="" fingerprint=""
  local -A seen=()

  for candidate in "${candidates[@]}"; do
    [[ -d "$candidate" ]] || continue
    _py_validate_venv_path "$candidate" >/dev/null 2>&1 || continue
    fingerprint="$REPLY"
    [[ -z "${seen[$candidate]:-}" ]] || continue
    seen[$candidate]=1
    print -r -- $'local\t'"$candidate"$'\t'"$fingerprint"
  done
}

_py_venv_record_path() {
  local record="$1"
  REPLY="${${record#*$'\t'}%%$'\t'*}"
}

_py_venv_record_fingerprint() {
  local record="$1"
  REPLY="${record##*$'\t'}"
}

_py_select_venv_record() {
  local records="$1" prompt="${2:-Environment > }"
  local -a record_snapshot=("${(@f)records}")
  (( ${#record_snapshot[@]} > 0 )) || return 1

  if (( ${#record_snapshot[@]} == 1 )); then
    REPLY="${record_snapshot[1]}"
    return 0
  fi

  _py_check_command fzf || return 1
  local record="" environment_path="" row=""
  local -a rows=()
  for record in "${record_snapshot[@]}"; do
    _py_venv_record_path "$record"
    environment_path="$REPLY"
    rows+=("$environment_path|$record|Validated project-local virtual environment")
  done

  local -i picker_rc=0
  _py_fzf_capture \
    "--prompt=$prompt" \
    '--header=Select one validated project-local environment' \
    --no-preview \
    < <(print -rl -- "${rows[@]}") || picker_rc=$?
  row="$REPLY"
  if (( picker_rc != 0 )); then
    _py_fzf_rc_is_cancel "$picker_rc" && return 130
    return "$picker_rc"
  fi
  [[ -n "$row" && ${rows[(Ie)$row]} -gt 0 ]] || {
    _py_error "The selected environment was not in the discovery snapshot."
    return 1
  }
  REPLY="${${row#*|}%%|*}"
}

_py_resolve_venv_record() {
  local records="$1" requested_path="${2:-}" prompt="${3:-Environment > }"
  local -a record_snapshot=("${(@f)records}")
  local record="" environment_path=""

  if [[ -z "$requested_path" ]]; then
    _py_select_venv_record "$records" "$prompt"
    return $?
  fi

  requested_path="${requested_path:a}"
  for record in "${record_snapshot[@]}"; do
    _py_venv_record_path "$record"
    environment_path="$REPLY"
    if [[ "$environment_path" == "$requested_path" ]]; then
      REPLY="$record"
      return 0
    fi
  done
  _py_error "The requested environment was not in the validated discovery snapshot."
  return 1
}

_py_venv_config_version() {
  local env_path="$1" line="" version=unknown
  while IFS= read -r line; do
    if [[ "$line" == 'version = '* ]]; then
      version="${line#version = }"
      break
    fi
  done < "$env_path/pyvenv.cfg"
  [[ "$version" =~ ^[[:alnum:]._-]+$ ]] || version=unknown
  REPLY="$version"
}

_py_fingerprint_owned_file() {
  local file_path="$1" max_size="$2" expected="${3:-}"
  zmodload zsh/stat zsh/system 2>/dev/null || return 1
  local -A before_state=() after_state=()
  [[ "$file_path" == /* && "$file_path" == "${file_path:A}" \
    && -f "$file_path" && ! -L "$file_path" ]] \
    && zstat -LH before_state -- "$file_path" 2>/dev/null \
    && (( (before_state[mode] & 8#170000) == 8#100000 \
      && before_state[uid] == EUID \
      && before_state[nlink] == 1 \
      && (before_state[mode] & 8#22) == 0 \
      && before_state[size] >= 0 \
      && before_state[size] <= max_size )) || {
    _py_error "Refusing an unsafe file: $file_path"
    return 1
  }

  local -i read_fd=-1
  sysopen -r -o nofollow,cloexec -u read_fd -- "$file_path" 2>/dev/null || {
    _py_error "Could not open a validated file safely: $file_path"
    return 1
  }
  local checksum=""
  checksum=$(command cksum <&$(( read_fd ))) || {
    exec {read_fd}>&-
    _py_error "Could not fingerprint a validated file: $file_path"
    return 1
  }
  exec {read_fd}>&-

  zstat -LH after_state -- "$file_path" 2>/dev/null \
    && [[ "${after_state[device]}:${after_state[inode]}:${after_state[mode]}:${after_state[uid]}:${after_state[nlink]}:${after_state[size]}:${after_state[mtime]}" \
      == "${before_state[device]}:${before_state[inode]}:${before_state[mode]}:${before_state[uid]}:${before_state[nlink]}:${before_state[size]}:${before_state[mtime]}" ]] || {
    _py_error "The validated file changed while it was fingerprinted."
    return 1
  }
  local fingerprint="${before_state[device]}:${before_state[inode]}:${before_state[mode]}:${before_state[uid]}:${before_state[nlink]}:${before_state[size]}:${before_state[mtime]}:${checksum}"
  [[ -z "$expected" || "$fingerprint" == "$expected" ]] || {
    _py_error "The validated file changed after review."
    return 1
  }
  REPLY="$fingerprint"
}

# Return a descriptor path usable by child processes, or status 3 for the
# ordinary /dev/fd fallback. sysparams[pid] follows actual Zsh subshells.
_py_activation_descriptor_path() {
  local file_path="$1" descriptor="$2"
  local proc_descriptor="/proc/${sysparams[pid]}/fd/$descriptor"
  if [[ -r "$proc_descriptor" && "${proc_descriptor:A}" == "$file_path" ]]; then
    REPLY="$proc_descriptor"
    return 0
  fi
  REPLY="/dev/fd/$descriptor"
  [[ -r "$REPLY" ]] || {
    _py_error "Descriptor-backed sourcing is unavailable on this host."
    return 1
  }
  return 3
}

_py_source_fingerprinted_file() {
  local file_path="$1"
  local expected="$2"
  local -i require_stable_path=${3:-0}
  zmodload zsh/stat zsh/system 2>/dev/null || return 1

  local -i read_fd=-1 source_rc=1
  sysopen -r -o nofollow,cloexec -u read_fd -- "$file_path" 2>/dev/null || {
    _py_error "Could not open the activation script safely."
    return 1
  }
  {
    local -i descriptor_rc=0
    _py_activation_descriptor_path "$file_path" "$read_fd" || descriptor_rc=$?
    local source_path="$REPLY"
    if (( descriptor_rc == 3 && require_stable_path )); then
      _py_error "Relocatable activation requires a stable descriptor path on this host."
      _py_info "Review and source the activation script manually: ${(q)file_path}"
      return 1
    fi
    (( descriptor_rc == 0 || descriptor_rc == 3 )) || return "$descriptor_rc"
    local -A before_state=() after_state=()
    zstat -H before_state -f "$read_fd" 2>/dev/null || return 1
    local checksum=""
    checksum=$(command cksum <&$(( read_fd ))) || return 1
    sysseek -u "$read_fd" -w start 0 2>/dev/null || return 1
    zstat -H after_state -f "$read_fd" 2>/dev/null || return 1
    local opened_fingerprint="${before_state[device]}:${before_state[inode]}:${before_state[mode]}:${before_state[uid]}:${before_state[nlink]}:${before_state[size]}:${before_state[mtime]}:${checksum}"
    local after_identity="${after_state[device]}:${after_state[inode]}:${after_state[mode]}:${after_state[uid]}:${after_state[nlink]}:${after_state[size]}:${after_state[mtime]}"
    local before_identity="${before_state[device]}:${before_state[inode]}:${before_state[mode]}:${before_state[uid]}:${before_state[nlink]}:${before_state[size]}:${before_state[mtime]}"
    [[ "$opened_fingerprint" == "$expected" \
      && "$after_identity" == "$before_identity" ]] || {
      _py_error "The opened activation script did not match the reviewed file."
      return 1
    }
    builtin source "$source_path"
    source_rc=$?
  } always {
    exec {read_fd}>&-
  }
  return "$source_rc"
}

_py_fingerprint_venv_python() {
  local environment_path="$1" expected="${2:-}"
  local python_literal="$environment_path/bin/python"
  local bin_directory="$environment_path/bin"
  _py_fingerprint_owned_directory "$bin_directory" || return $?
  local bin_fingerprint="$REPLY"

  zmodload zsh/stat 2>/dev/null || return 1
  _py_system_root_uid || return 1
  local -i system_root_uid=$REPLY
  local resolved_python="${python_literal:A}"
  local -A python_state=()
  [[ "$python_literal" == "${python_literal:a}" \
    && ( -f "$python_literal" || -L "$python_literal" ) \
    && -x "$python_literal" \
    && "$resolved_python" == /* \
    && "$resolved_python" != *[[:cntrl:]]* \
    && -f "$resolved_python" && ! -L "$resolved_python" ]] \
    && zstat -LH python_state -- "$resolved_python" 2>/dev/null \
    && (( (python_state[mode] & 8#170000) == 8#100000 \
      && (python_state[uid] == EUID \
        || python_state[uid] == system_root_uid) \
      && (python_state[mode] & 8#22) == 0 \
      && python_state[size] > 0 \
      && python_state[size] <= 512 * 1024 * 1024 )) || {
    _py_error "Refusing an unsafe virtual-environment interpreter: $python_literal"
    return 1
  }

  local fingerprint="${python_literal}:${resolved_python}:${bin_fingerprint}:${python_state[device]}:${python_state[inode]}:${python_state[mode]}:${python_state[uid]}:${python_state[size]}:${python_state[mtime]}"
  [[ -z "$expected" || "$fingerprint" == "$expected" ]] || {
    _py_error "The virtual-environment interpreter changed after review."
    return 1
  }
  REPLY="$fingerprint"
}

# uv workspaces share state at their workspace root. Refuse a project nested
# below an ancestor workspace so no reviewed member operation can mutate an
# unreviewed parent lockfile or environment.
_py_assert_no_external_uv_workspace() {
  local project_root="$1"
  _py_require_tomllib || return $?

  local ancestor="${project_root:h}"
  local metadata_file="" metadata_fingerprint=""
  local -i workspace_rc=0
  while true; do
    metadata_file="$ancestor/pyproject.toml"
    if [[ -e "$metadata_file" || -L "$metadata_file" ]]; then
      _py_fingerprint_owned_file \
        "$metadata_file" $(( 2 * 1024 * 1024 )) || {
        _py_error "Refusing untrusted ancestor project metadata: $metadata_file"
        return 1
      }
      metadata_fingerprint="$REPLY"
      workspace_rc=0
      command python3 -I -c '
import pathlib
import sys
import tomllib

try:
    data = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(2)
tool = data.get("tool", {})
if not isinstance(tool, dict):
    raise SystemExit(2)
uv = tool.get("uv", {})
if not isinstance(uv, dict):
    raise SystemExit(2)
workspace = uv.get("workspace")
if workspace is None:
    raise SystemExit(1)
raise SystemExit(0 if isinstance(workspace, dict) else 2)
' "$metadata_file" </dev/null >/dev/null 2>&1 || workspace_rc=$?
      _py_fingerprint_owned_file \
        "$metadata_file" $(( 2 * 1024 * 1024 )) \
        "$metadata_fingerprint" || return $?
      case "$workspace_rc" in
        0)
          _py_error "Refusing a uv project inside an external workspace: $ancestor"
          return 1
          ;;
        1) ;;
        *)
          _py_error "Could not safely parse ancestor project metadata: $metadata_file"
          return 1
          ;;
      esac
    fi
    [[ "$ancestor" == / ]] && break
    ancestor="${ancestor:h}"
  done
}

_py_print_venv_usage() {
  local command_name="$1"
  case "$command_name" in
    venv-list)
      print -u2 -r -- "Usage: py-menu venv-list"
      ;;
    venv-create)
      print -u2 -r -- \
        "Usage: py-menu venv-create [--uv|--venv|--poetry] [--python VERSION] [--dry-run] [--yes]"
      ;;
    venv-activate)
      print -u2 -r -- \
        "Usage: py-menu venv-activate [--path PATH] [--dry-run] [--yes]"
      ;;
    venv-info)
      print -u2 -r -- "Usage: py-menu venv-info [--path PATH]"
      ;;
    venv-remove)
      print -u2 -r -- \
        "Usage: py-menu venv-remove [--path PATH] [--dry-run] [--yes]"
      ;;
    venv-rebuild)
      print -u2 -r -- \
        "Usage: py-menu venv-rebuild [--path PATH] [--dry-run] [--yes]"
      ;;
  esac
}

venv-list() {
  emulate -L zsh
  case "${1:-}" in
    "") (( $# == 0 )) || return 2 ;;
    -h|--help)
      (( $# == 1 )) || return 2
      _py_print_venv_usage venv-list
      return 0
      ;;
    *)
      _py_error "venv-list accepts no arguments."
      return 2
      ;;
  esac

  _py_header "Virtual Environments"
  local records=""
  records=$(_py_snapshot_local_venvs) || return $?
  [[ -n "$records" ]] || {
    _py_info "No validated project-local virtual environments found."
    _py_dim "Create one with: py-menu venv-create"
    return 0
  }

  local active="${VIRTUAL_ENV:-}" record="" environment_path="" fingerprint=""
  local -a record_snapshot=("${(@f)records}")
  for record in "${record_snapshot[@]}"; do
    _py_venv_record_path "$record"
    environment_path="$REPLY"
    _py_venv_record_fingerprint "$record"
    fingerprint="$REPLY"
    _py_venv_config_version "$environment_path"
    local version="$REPLY" marker=""
    [[ -n "$active" && "${active:A}" == "$environment_path" ]] \
      && marker=" (active)"
    _py_info \
      "$environment_path | Python $version | fingerprint $fingerprint$marker"
  done
}

venv-create() {
  emulate -L zsh
  local backend="" python_version=""
  local -i dry_run=0 assume_yes=0

  while (( $# > 0 )); do
    case "$1" in
      --uv|--venv|--poetry)
        [[ -z "$backend" ]] || {
          _py_error "Select only one environment backend."
          return 2
        }
        backend="${1#--}"
        [[ "$backend" == venv ]] && backend=stdlib
        ;;
      --python)
        (( $# >= 2 )) || {
          _py_error "--python requires a version."
          return 2
        }
        [[ -n "$2" ]] || {
          _py_error "--python requires a non-empty version."
          return 2
        }
        python_version="$2"
        shift
        ;;
      --python=*)
        python_version="${1#*=}"
        [[ -n "$python_version" ]] || {
          _py_error "--python requires a non-empty version."
          return 2
        }
        ;;
      --dry-run) dry_run=1 ;;
      --yes) assume_yes=1 ;;
      -h|--help)
        (( $# == 1 )) || return 2
        _py_print_venv_usage venv-create
        return 0
        ;;
      -*)
        _py_error "Unknown venv-create option: $1"
        return 2
        ;;
      *)
        _py_error "Unexpected venv-create argument: $1"
        return 2
        ;;
    esac
    shift
  done

  [[ -z "$python_version" ]] || _py_validate_python_version "$python_version" || {
    _py_error "Python versions must use X.Y or X.Y.Z."
    return 2
  }
  _py_validate_project_root || return $?
  local root="$REPLY"
  local target="$root/.venv"
  _py_fingerprint_owned_directory "$root" || return $?
  local root_fingerprint="$REPLY"
  if [[ -e "$target" || -L "$target" ]]; then
    _py_error "$target already exists; create never replaces an existing path."
    _py_info "Use venv-remove explicitly after reviewing its fingerprint."
    return 1
  fi

  [[ -n "$backend" ]] || {
    if command -v uv &>/dev/null; then
      backend=uv
    else
      backend=stdlib
    fi
  }

  if [[ "$backend" == poetry ]]; then
    _py_info "Plan: create a Poetry-managed environment for $root"
    _py_error "Poetry creation is disabled because its target path cannot be bounded before mutation."
    _py_info "No files were changed."
    return 1
  fi

  local executable=""
  local resolved_python_version=""
  case "$backend" in
    uv)
      _py_check_command uv || return 1
      executable=uv
      ;;
    stdlib)
      executable=python3
      if [[ -n "$python_version" ]]; then
        if [[ "$python_version" == *.*.* ]]; then
          executable="python${python_version%.*}"
        else
          executable="python${python_version}"
        fi
      fi
      _py_check_command "$executable" || return 1
      resolved_python_version=$(
        command "$executable" -I -c \
          'import sys; print(".".join(map(str, sys.version_info[:3])))' \
          </dev/null 2>/dev/null
      ) || {
        _py_error "Could not inspect the requested standard-library interpreter."
        return 1
      }
      _py_validate_python_version "$resolved_python_version" \
        && [[ "$resolved_python_version" != *$'\n'* \
          && ${#resolved_python_version} -le 32 ]] || {
        _py_error "The requested interpreter returned invalid version metadata."
        return 1
      }
      if [[ -n "$python_version" ]]; then
        if [[ "$python_version" == *.*.* ]]; then
          [[ "$resolved_python_version" == "$python_version" ]]
        else
          [[ "${resolved_python_version%.*}" == "$python_version" ]]
        fi || {
          _py_error \
            "$executable resolves to Python $resolved_python_version, not $python_version."
          return 1
        }
      fi
      ;;
    *)
      _py_error "Unsupported environment backend: $backend"
      return 2
      ;;
  esac

  _py_header "Create Virtual Environment"
  _py_info "Plan: create an empty environment at $target"
  _py_info "Backend: $backend${python_version:+ | Python: $python_version}"
  [[ "$backend" == stdlib ]] \
    && _py_info "Resolved interpreter: $executable ($resolved_python_version)"
  _py_warn "Dependency installation is intentionally separate from environment creation."
  (( dry_run )) && {
    _py_success "Dry run complete; no files changed."
    return 0
  }

  local -i confirm_rc=0
  local _PY_AUTO_YES=$assume_yes
  _py_confirm "Create this local virtual environment?"
  confirm_rc=$?
  case "$confirm_rc" in
    0) ;;
    130)
      _py_info "Cancelled."
      return 0
      ;;
    *) return "$confirm_rc" ;;
  esac

  _py_validate_project_root || return $?
  [[ "$REPLY" == "$root" ]] || {
    _py_error "The project boundary changed after review."
    return 1
  }
  _py_fingerprint_owned_directory "$root" "$root_fingerprint" || return $?
  [[ ! -e "$target" && ! -L "$target" ]] || {
    _py_error "The .venv target appeared after review; refusing replacement."
    return 1
  }
  if [[ "$backend" == stdlib ]]; then
    local current_python_version=""
    current_python_version=$(
      command "$executable" -I -c \
        'import sys; print(".".join(map(str, sys.version_info[:3])))' \
        </dev/null 2>/dev/null
    ) || {
      _py_error "Could not revalidate the standard-library interpreter."
      return 1
    }
    [[ "$current_python_version" == "$resolved_python_version" ]] || {
      _py_error "The standard-library interpreter changed after review."
      return 1
    }
  fi

  local -i operation_rc=0
  if [[ "$backend" == uv ]]; then
    local -a uv_args=(venv --no-python-downloads)
    [[ -n "$python_version" ]] && uv_args+=(--python "$python_version")
    _py_run_uv_scoped "${uv_args[@]}" "$target" >&2 || operation_rc=$?
  else
    command "$executable" -I -m venv "$target" >&2 || operation_rc=$?
  fi
  (( operation_rc == 0 )) || {
    _py_error "Environment creation failed (status $operation_rc)."
    return "$operation_rc"
  }
  _py_validate_venv_path "$target" || {
    _py_error "The backend returned success but the created environment failed validation."
    return 1
  }
  _py_success "Created validated environment: $target"
}

venv-activate() {
  emulate -L zsh
  local requested_path=""
  local -i dry_run=0 assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --path)
        (( $# >= 2 )) || return 2
        [[ -n "$2" ]] || {
          _py_error "--path requires a non-empty path."
          return 2
        }
        requested_path="$2"
        shift
        ;;
      --dry-run) dry_run=1 ;;
      --yes) assume_yes=1 ;;
      -h|--help)
        (( $# == 1 )) || return 2
        _py_print_venv_usage venv-activate
        return 0
        ;;
      -*)
        _py_error "Unknown venv-activate option: $1"
        return 2
        ;;
      *)
        _py_error "Unexpected venv-activate argument: $1"
        return 2
        ;;
    esac
    shift
  done

  local records=""
  records=$(_py_snapshot_local_venvs) || return $?
  [[ -n "$records" ]] || {
    _py_error "No validated local virtual environments found."
    return 1
  }
  _py_resolve_venv_record "$records" "$requested_path" "Activate > "
  local resolve_rc=$?
  (( resolve_rc == 130 )) && {
    _py_info "Cancelled."
    return 0
  }
  (( resolve_rc == 0 )) || return "$resolve_rc"
  local record="$REPLY"
  _py_venv_record_path "$record"
  local target="$REPLY"
  _py_venv_record_fingerprint "$record"
  local fingerprint="$REPLY"

  _py_validate_venv_path "$target" "$fingerprint" || return $?
  local activate_file="$target/bin/activate"
  _py_fingerprint_owned_file "$activate_file" $(( 1024 * 1024 )) || return $?
  local activate_fingerprint="$REPLY"

  _py_header "Activate Virtual Environment"
  _py_info "Plan: source executable shell code from $activate_file"
  (( dry_run )) && {
    _py_success "Dry run complete; no shell state changed."
    return 0
  }
  local _PY_AUTO_YES=$assume_yes
  _py_confirm "Trust and source this activation script?"
  local confirm_rc=$?
  case "$confirm_rc" in
    0) ;;
    130)
      _py_info "Cancelled."
      return 0
      ;;
    *) return "$confirm_rc" ;;
  esac
  _py_validate_venv_path "$target" "$fingerprint" || return $?
  _py_fingerprint_owned_file \
    "$activate_file" $(( 1024 * 1024 )) "$activate_fingerprint" || return $?

  local -i require_stable_path=0
  local config_line=""
  while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    if [[ "$config_line" =~ '^[[:space:]]*relocatable[[:space:]]*=[[:space:]]*true[[:space:]]*$' ]]; then
      require_stable_path=1
      break
    fi
  done < "$target/pyvenv.cfg"

  # Activation is authorized shell code. Restore the variables and functions
  # used by standard activation scripts on failure, without claiming rollback
  # of arbitrary filesystem or shell effects from a customized script.
  local -a activation_names=(
    PATH VIRTUAL_ENV VIRTUAL_ENV_PROMPT PYTHONHOME PS1
    _OLD_VIRTUAL_PATH _OLD_VIRTUAL_PYTHONHOME _OLD_VIRTUAL_PS1
    SCRIPT_PATH _OLD_SCRIPT_PATH
  )
  local -A activation_values=() activation_types=() activation_functions=()
  local activation_name="" activation_type=""
  for activation_name in "${activation_names[@]}"; do
    (( ${+parameters[$activation_name]} )) || continue
    activation_type="${parameters[$activation_name]}"
    [[ "$activation_type" == scalar* \
      && "$activation_type" != *readonly* && "$activation_type" != *local* ]] || {
      _py_error "Cannot safely restore protected activation parameter: $activation_name"
      return 1
    }
    activation_types[$activation_name]="$activation_type"
    activation_values[$activation_name]="${(P)activation_name}"
  done
  for activation_name in deactivate pydoc; do
    (( ${+functions[$activation_name]} )) || continue
    activation_functions[$activation_name]="${functions[$activation_name]}"
  done
  local -i had_pydoc_alias=${+aliases[pydoc]}
  local previous_pydoc_alias="${aliases[pydoc]-}"
  local -i activation_rc=1 rollback_rc=0
  {
    _py_source_fingerprinted_file \
      "$activate_file" "$activate_fingerprint" "$require_stable_path"
    activation_rc=$?
    if (( activation_rc == 0 )); then
      if [[ -z "${VIRTUAL_ENV:-}" || "${VIRTUAL_ENV:A}" != "$target" \
        || "${PATH%%:*}" != "$target/bin" \
        || "$(builtin whence -p python)" != "$target/bin/python" ]] \
        || ! _py_fingerprint_venv_python "$target"; then
        _py_error "The activation script did not select the reviewed environment."
        activation_rc=1
      fi
    else
      _py_error "Activation failed (status $activation_rc)."
    fi
  } always {
    if (( activation_rc != 0 )); then
      for activation_name in "${activation_names[@]}"; do
        if (( ${+activation_types[$activation_name]} )); then
          builtin typeset -g "$activation_name=${activation_values[$activation_name]}" \
            || rollback_rc=1
          if [[ "${activation_types[$activation_name]}" == *export* ]]; then
            builtin export "$activation_name" || rollback_rc=1
          else
            builtin typeset -g +x "$activation_name" || rollback_rc=1
          fi
        else
          builtin unset "$activation_name" || rollback_rc=1
        fi
      done
      for activation_name in deactivate pydoc; do
        if (( ${+activation_functions[$activation_name]} )); then
          functions[$activation_name]="${activation_functions[$activation_name]}"
        else
          builtin unfunction "$activation_name" 2>/dev/null || true
        fi
      done
      if (( had_pydoc_alias )); then
        aliases[pydoc]="$previous_pydoc_alias"
      else
        builtin unalias pydoc 2>/dev/null || true
      fi
      builtin rehash
      if (( rollback_rc == 0 )); then
        _py_info "Restored the previous activation state."
      else
        _py_error "Could not fully restore activation state; inspect the current shell before retrying."
      fi
    fi
  }
  (( activation_rc == 0 )) || return "$activation_rc"
  _py_success "Activated: $target"
}

venv-info() {
  emulate -L zsh
  local requested_path=""
  while (( $# > 0 )); do
    case "$1" in
      --path)
        (( $# >= 2 )) || return 2
        [[ -n "$2" ]] || {
          _py_error "--path requires a non-empty path."
          return 2
        }
        requested_path="$2"
        shift
        ;;
      -h|--help)
        (( $# == 1 )) || return 2
        _py_print_venv_usage venv-info
        return 0
        ;;
      -*)
        _py_error "Unknown venv-info option: $1"
        return 2
        ;;
      *)
        _py_error "Unexpected venv-info argument: $1"
        return 2
        ;;
    esac
    shift
  done

  local records=""
  records=$(_py_snapshot_local_venvs) || return $?
  [[ -n "$records" ]] || {
    _py_error "No validated local virtual environments found."
    return 1
  }

  if [[ -z "$requested_path" && -n "${VIRTUAL_ENV:-}" ]]; then
    requested_path="$VIRTUAL_ENV"
  fi
  _py_resolve_venv_record "$records" "$requested_path" "Inspect > "
  local resolve_rc=$?
  (( resolve_rc == 130 )) && {
    _py_info "Cancelled."
    return 0
  }
  (( resolve_rc == 0 )) || return "$resolve_rc"
  local record="$REPLY"
  _py_venv_record_path "$record"
  local target="$REPLY"
  _py_venv_record_fingerprint "$record"
  local fingerprint="$REPLY"
  _py_validate_venv_path "$target" "$fingerprint" || return $?
  _py_venv_config_version "$target"
  local version="$REPLY"

  _py_header "Environment Info"
  _py_info "Type: project-local venv"
  _py_info "Path: $target"
  _py_info "Python metadata: $version"
  _py_info "Fingerprint: $fingerprint"
  _py_info "Backend hint: $(_py_detect_venv_backend)"
  if [[ -n "${VIRTUAL_ENV:-}" && "${VIRTUAL_ENV:A}" == "$target" ]]; then
    _py_success "Status: active"
  else
    _py_info "Status: inactive"
  fi
}

_py_assert_no_mounts_under() {
  local target="$1"
  local findmnt_command=""
  findmnt_command=$(whence -p findmnt 2>/dev/null) || findmnt_command=""
  [[ -n "$findmnt_command" && -x "$findmnt_command" ]] || {
    _py_error "findmnt is required before recursive environment removal."
    return 1
  }
  local python_command=""
  python_command=$(whence -p python3 2>/dev/null) || python_command=""
  [[ -n "$python_command" && -x "$python_command" ]] || {
    _py_error "Python 3 is required to validate structured mount metadata."
    return 1
  }
  _py_timeout_prefix 15 || return $?
  local -a timeout_prefix=("${reply[@]}")

  local mount_output=""
  mount_output=$(
    "${timeout_prefix[@]}" "$python_command" -I -c '
import json
import os
import selectors
import subprocess
import sys
import time

target = os.path.normpath(os.path.abspath(sys.argv[1]))
findmnt = sys.argv[2]
maximum_bytes = 4 * 1024 * 1024
process = None

def stop_process():
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()

try:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    process = subprocess.Popen(
        [findmnt, "--json", "--list", "--output", "TARGET"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environment,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 10
    output = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(findmnt, 10)
        if not selector.select(remaining):
            raise subprocess.TimeoutExpired(findmnt, 10)
        chunk = os.read(
            process.stdout.fileno(),
            min(65536, maximum_bytes + 1 - len(output)),
        )
        if not chunk:
            break
        output.extend(chunk)
        if len(output) > maximum_bytes:
            raise ValueError("oversized findmnt output")
    return_code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
except (OSError, subprocess.TimeoutExpired, ValueError):
    stop_process()
    raise SystemExit(6)
finally:
    if process is not None and process.stdout is not None:
        process.stdout.close()
if return_code != 0:
    raise SystemExit(7)
try:
    payload = json.loads(output)
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(8)

records = payload.get("filesystems")
if not isinstance(records, list):
    raise SystemExit(8)
pending = list(records)
count = 0
while pending:
    record = pending.pop()
    if not isinstance(record, dict):
        raise SystemExit(8)
    children = record.get("children", [])
    if children is None:
        children = []
    if not isinstance(children, list):
        raise SystemExit(8)
    pending.extend(children)
    count += 1
    if count > 4096:
        raise SystemExit(9)
    mount_target = record.get("target")
    if not isinstance(mount_target, str):
        raise SystemExit(8)
    if (
        not os.path.isabs(mount_target)
        or len(mount_target) > 4096
        or any(ord(character) < 32 or ord(character) == 127 for character in mount_target)
    ):
        raise SystemExit(8)
    normalized = os.path.normpath(mount_target)
    try:
        below_target = os.path.commonpath((target, normalized)) == target
    except ValueError:
        raise SystemExit(8)
    if below_target:
        print(json.dumps(normalized, ensure_ascii=True))
        raise SystemExit(20)
' "$target" "$findmnt_command" </dev/null 2>/dev/null
  )
  local -i mount_rc=$?
  case "$mount_rc" in
    0) return 0 ;;
    20)
      _py_error \
        "Refusing an environment containing a mount or bind mount: $mount_output"
      return 1
      ;;
    124|137)
      _py_error "Mount validation exceeded its bounded deadline."
      return 1
      ;;
    *)
      _py_error "Could not validate the bounded structured mount inventory."
      return 1
      ;;
  esac
}

_py_validate_quarantined_venv() {
  local quarantine_target="$1" expected="$2"
  zmodload zsh/stat 2>/dev/null || return 1
  local -A environment_state=()
  [[ "$quarantine_target" == /* \
    && "$quarantine_target" == "${quarantine_target:A}" \
    && -d "$quarantine_target" && ! -L "$quarantine_target" ]] \
    && zstat -LH environment_state -- "$quarantine_target" 2>/dev/null \
    && (( (environment_state[mode] & 8#170000) == 8#040000 \
      && environment_state[uid] == EUID \
      && (environment_state[mode] & 8#22) == 0 )) || {
    _py_error "The quarantined environment failed directory validation."
    return 1
  }
  [[ "${environment_state[device]}:${environment_state[inode]}" \
    == "$expected" ]] || {
    _py_error "The quarantined environment identity does not match the reviewed target."
    return 1
  }
  _py_fingerprint_owned_file \
    "$quarantine_target/pyvenv.cfg" $(( 64 * 1024 )) >/dev/null \
    || return $?
}

_py_quarantine_and_remove_venv() {
  local target="$1" fingerprint="$2" parent_fingerprint="$3"
  local parent="${target:h}"
  _py_validate_venv_parent "$target" "$parent_fingerprint" || return $?
  _py_validate_venv_path "$target" "$fingerprint" || return $?
  _py_assert_no_mounts_under "$target" || return $?

  local quarantine_dir=""
  quarantine_dir=$(umask 077; command mktemp -d \
    "$parent/.zdx-py-quarantine.XXXXXX" 2>/dev/null) || {
    _py_error "Could not create a same-parent quarantine directory."
    return 1
  }
  command chmod 700 -- "$quarantine_dir" 2>/dev/null || {
    command rmdir -- "$quarantine_dir" 2>/dev/null
    _py_error "Could not protect the quarantine directory."
    return 1
  }
  _py_fingerprint_owned_directory "$quarantine_dir" || {
    command rmdir -- "$quarantine_dir" 2>/dev/null
    return 1
  }
  local quarantine_fingerprint="$REPLY"
  local quarantine_target="$quarantine_dir/environment"

  local -i validation_rc=0
  _py_validate_venv_parent "$target" "$parent_fingerprint" \
    || validation_rc=$?
  if (( validation_rc != 0 )); then
    command rmdir -- "$quarantine_dir" 2>/dev/null
    return "$validation_rc"
  fi
  _py_validate_venv_path "$target" "$fingerprint" \
    || validation_rc=$?
  if (( validation_rc != 0 )); then
    command rmdir -- "$quarantine_dir" 2>/dev/null
    return "$validation_rc"
  fi
  _py_assert_no_mounts_under "$target" || validation_rc=$?
  if (( validation_rc != 0 )); then
    command rmdir -- "$quarantine_dir" 2>/dev/null
    return "$validation_rc"
  fi
  [[ ! -e "$quarantine_target" && ! -L "$quarantine_target" ]] || {
    command rmdir -- "$quarantine_dir" 2>/dev/null
    _py_error "The quarantine target unexpectedly exists."
    return 1
  }

  command mv -- "$target" "$quarantine_target" || {
    local move_rc=$?
    command rmdir -- "$quarantine_dir" 2>/dev/null
    _py_error "Could not quarantine the environment (status $move_rc)."
    return "$move_rc"
  }
  [[ ! -e "$target" && ! -L "$target" ]] \
    && _py_fingerprint_owned_directory \
      "$quarantine_dir" "$quarantine_fingerprint" \
    && _py_validate_quarantined_venv \
      "$quarantine_target" "$fingerprint" || {
    _py_error "Quarantine validation failed; no recursive deletion was attempted."
    _py_warn "Recovery path retained: $quarantine_target"
    _py_info "Recovery: inspect that path and move it back to $target only while the target remains absent."
    return 1
  }

  _py_assert_no_mounts_under "$quarantine_target" || {
    _py_error "The quarantined environment was not deleted."
    _py_warn "Recovery path retained: $quarantine_target"
    _py_info "Recovery: inspect that path and move it back to $target only while the target remains absent."
    return 1
  }
  _py_fingerprint_owned_directory \
    "$quarantine_dir" "$quarantine_fingerprint" \
    && _py_validate_quarantined_venv \
      "$quarantine_target" "$fingerprint" || {
    _py_error "The quarantine changed immediately before deletion."
    _py_warn "Recovery path retained: $quarantine_target"
    _py_info "Recovery: inspect that path and move it back to $target only while the target remains absent."
    return 1
  }
  command rm -rf -- "$quarantine_target" || {
    local remove_rc=$?
    _py_error "Quarantined environment deletion failed (status $remove_rc)."
    _py_warn "Inspect the recovery path before restoring or deleting it: $quarantine_target"
    return "$remove_rc"
  }
  [[ ! -e "$quarantine_target" && ! -L "$quarantine_target" ]] || {
    _py_error "The quarantine still contains environment data."
    _py_warn "Recovery path retained: $quarantine_target"
    return 1
  }
  command rmdir -- "$quarantine_dir" || {
    _py_warn "The empty quarantine directory remains: $quarantine_dir"
    return 1
  }
  _py_success "Removed quarantined local environment: $target"
}

venv-remove() {
  emulate -L zsh
  local requested_path=""
  local -i dry_run=0 assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --path)
        (( $# >= 2 )) || return 2
        [[ -n "$2" ]] || {
          _py_error "--path requires a non-empty path."
          return 2
        }
        requested_path="$2"
        shift
        ;;
      --dry-run) dry_run=1 ;;
      --yes) assume_yes=1 ;;
      -h|--help)
        (( $# == 1 )) || return 2
        _py_print_venv_usage venv-remove
        return 0
        ;;
      -*)
        _py_error "Unknown venv-remove option: $1"
        return 2
        ;;
      *)
        _py_error "Unexpected venv-remove argument: $1"
        return 2
        ;;
    esac
    shift
  done

  local records=""
  records=$(_py_snapshot_local_venvs) || return $?
  [[ -n "$records" ]] || {
    if [[ -n "$requested_path" ]]; then
      _py_error \
        "The requested environment was not in the validated discovery snapshot."
      return 1
    fi
    _py_info "No validated local virtual environments found."
    return 0
  }
  _py_resolve_venv_record "$records" "$requested_path" "Remove > "
  local resolve_rc=$?
  (( resolve_rc == 130 )) && {
    _py_info "Cancelled."
    return 0
  }
  (( resolve_rc == 0 )) || return "$resolve_rc"
  local record="$REPLY"
  _py_venv_record_path "$record"
  local target="$REPLY"
  _py_venv_record_fingerprint "$record"
  local fingerprint="$REPLY"

  if [[ -n "${VIRTUAL_ENV:-}" && "${VIRTUAL_ENV:A}" == "$target" ]]; then
    _py_error "Refusing to remove the active environment; deactivate it first."
    return 1
  fi
  _py_validate_venv_path "$target" "$fingerprint" || return $?
  _py_validate_venv_parent "$target" || return $?
  local parent_fingerprint="$REPLY"
  _py_assert_no_mounts_under "$target" || return $?

  _py_header "Remove Virtual Environment"
  _py_info "Plan: remove local environment $target"
  _py_info "Validated fingerprint: $fingerprint"
  _py_info "Plan: atomically quarantine it below ${target:h}, then delete that exact identity"
  _py_warn "Only this project-local path is eligible; external environments are never removed."
  (( dry_run )) && {
    _py_success "Dry run complete; no files changed."
    return 0
  }

  local _PY_AUTO_YES=$assume_yes
  _py_confirm "Permanently remove this validated local environment?"
  local confirm_rc=$?
  case "$confirm_rc" in
    0) ;;
    130)
      _py_info "Cancelled."
      return 0
      ;;
    *) return "$confirm_rc" ;;
  esac

  _py_quarantine_and_remove_venv \
    "$target" "$fingerprint" "$parent_fingerprint"
}

venv-rebuild() {
  emulate -L zsh
  local requested_path=""
  local -i dry_run=0 assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --path)
        (( $# >= 2 )) || return 2
        [[ -n "$2" ]] || {
          _py_error "--path requires a non-empty path."
          return 2
        }
        requested_path="$2"
        shift
        ;;
      --dry-run) dry_run=1 ;;
      --yes) assume_yes=1 ;;
      -h|--help)
        (( $# == 1 )) || return 2
        _py_print_venv_usage venv-rebuild
        return 0
        ;;
      -*)
        _py_error "Unknown venv-rebuild option: $1"
        return 2
        ;;
      *)
        _py_error "Unexpected venv-rebuild argument: $1"
        return 2
        ;;
    esac
    shift
  done

  local records=""
  records=$(_py_snapshot_local_venvs) || return $?
  [[ -n "$records" ]] || {
    _py_error "No validated local virtual environment found to rebuild."
    return 1
  }
  _py_resolve_venv_record "$records" "$requested_path" "Rebuild > "
  local resolve_rc=$?
  (( resolve_rc == 130 )) && {
    _py_info "Cancelled."
    return 0
  }
  (( resolve_rc == 0 )) || return "$resolve_rc"
  local record="$REPLY"
  _py_venv_record_path "$record"
  local target="$REPLY"
  _py_venv_record_fingerprint "$record"
  local fingerprint="$REPLY"
  _py_validate_venv_path "$target" "$fingerprint" || return $?

  _py_header "Rebuild Virtual Environment"
  _py_info "Plan: replace $target while preserving rollback capability"
  _py_info "Validated fingerprint: $fingerprint"
  _py_warn "The current implementation cannot guarantee transactional replacement."
  (( dry_run )) && {
    _py_success "Dry run complete; no files changed."
    return 0
  }
  (( assume_yes )) && _py_debug "--yes cannot bypass transactional safety."
  _py_error "Automatic rebuild is disabled until atomic staging and rollback are implemented."
  _py_info "No files were changed. Remove and create explicitly if you accept that two-step workflow."
  return 1
}

_py_print_venv_python_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  py-menu venv-python-list [-h|--help]"
  print -u2 -r -- \
    "  py-menu venv-python-install [VERSION] [--dry-run] [--yes]"
  print -u2 -r -- \
    "  py-menu venv-python-pin [VERSION] [--dry-run] [--yes]"
  print -u2 -r -- ""
  print -u2 -r -- "Compatibility: venv-python <list|install|pin> [args...]"
}

_py_uv_python_inventory() {
  local mode="$1"
  local raw_output=""
  local -a producer_args=(uv python list)
  if [[ "$mode" == installed ]]; then
    producer_args+=(--only-installed --managed-python)
  fi
  _py_timeout_prefix 20 || return $?
  producer_args=("${reply[@]}" "${producer_args[@]}")
  local UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-10}"
  export UV_HTTP_TIMEOUT
  raw_output=$(_py_capture_bounded_output \
    $(( 2 * 1024 * 1024 )) "uv Python inventory" \
    "${producer_args[@]}") || return $?

  local raw_line="" first_field="" version=""
  local -i raw_count=0 result_count=0 max_results=64
  [[ "$mode" == installed ]] && max_results=128
  local -A seen=()
  for raw_line in "${(@f)raw_output}"; do
    (( raw_count++ ))
    (( raw_count <= 2048 )) || {
      _py_error "uv Python inventory exceeded 2048 records."
      return 1
    }
    first_field="${raw_line%%[[:space:]]*}"
    version="${first_field#cpython-}"
    version="${version%%-*}"
    _py_validate_python_version "$version" || continue
    [[ -z "${seen[$version]:-}" ]] || continue
    seen[$version]=1
    (( result_count++ ))
    (( result_count <= max_results )) || {
      _py_error "uv Python inventory exceeded $max_results eligible versions."
      return 1
    }
    print -r -- "$version"
  done
}

_py_select_uv_python_version() {
  local mode="$1"
  local versions=""
  versions=$(_py_uv_python_inventory "$mode") || return $?
  [[ -n "$versions" ]] || {
    _py_error "No eligible Python versions were returned by uv."
    return 1
  }
  local -a version_snapshot=("${(@f)versions}")

  _py_check_command fzf || return 1
  local -i picker_rc=0
  _py_fzf_capture \
    '--prompt=Python > ' \
    '--header=Select one validated Python version' \
    --no-preview \
    < <(print -r -- "$versions") || picker_rc=$?
  local version="$REPLY"
  if (( picker_rc != 0 )); then
    _py_fzf_rc_is_cancel "$picker_rc" && return 130
    return "$picker_rc"
  fi
  _py_validate_python_version "$version" \
    && (( ${version_snapshot[(Ie)$version]} > 0 )) || {
    _py_error "The selected Python version was not in the uv inventory snapshot."
    return 1
  }
  REPLY="$version"
}

_py_validate_python_pin_target() {
  local expected="${1:-}" expected_root="${2:-}"
  _py_validate_project_root || return $?
  local root="$REPLY"
  local pin_file="$root/.python-version"
  _py_fingerprint_owned_directory "$root" "$expected_root" || return $?
  local root_fingerprint="$REPLY"
  local fingerprint="absent"
  if [[ -e "$pin_file" || -L "$pin_file" ]]; then
    [[ "$expected" != absent ]] || {
      _py_error ".python-version appeared after the operation was reviewed."
      return 1
    }
    _py_fingerprint_owned_file "$pin_file" 4096 "$expected" || return $?
    fingerprint="$REPLY"
  elif [[ -n "$expected" && "$expected" != absent ]]; then
    _py_error ".python-version disappeared after the operation was reviewed."
    return 1
  fi
  REPLY="$pin_file"$'\t'"$fingerprint"$'\t'"$root_fingerprint"
}

_py_venv_python() {
  emulate -L zsh
  local subcommand="${1:-}"
  (( $# > 0 )) && shift
  case "$subcommand" in
    -h|--help)
      (( $# == 0 )) || return 2
      _py_print_venv_python_usage
      return 0
      ;;
    list)
      if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
        (( $# == 1 )) || return 2
        _py_print_venv_python_usage
        return 0
      fi
      (( $# == 0 )) || {
        _py_error "venv-python-list accepts no arguments."
        return 2
      }
      _py_check_command uv || return 1
      _py_header "Managed Python Versions"
      local installed_versions=""
      installed_versions=$(_py_uv_python_inventory installed) || return $?
      [[ -n "$installed_versions" ]] || {
        _py_info "No Python runtimes installed through uv."
        return 0
      }
      local installed_version=""
      for installed_version in "${(@f)installed_versions}"; do
        _py_info "$installed_version"
      done
      ;;
    install|pin)
      local version=""
      local -i dry_run=0 assume_yes=0
      while (( $# > 0 )); do
        case "$1" in
          --dry-run) dry_run=1 ;;
          --yes) assume_yes=1 ;;
          -h|--help)
            (( $# == 1 )) || return 2
            _py_print_venv_python_usage
            return 0
            ;;
          -*)
            _py_error "Unknown venv-python-$subcommand option: $1"
            return 2
            ;;
          *)
            [[ -z "$version" ]] || {
              _py_error "Only one Python version may be specified."
              return 2
            }
            [[ -n "$1" ]] || {
              _py_error "Python version operands may not be empty."
              return 2
            }
            version="$1"
            ;;
        esac
        shift
      done

      _py_check_command uv || return 1
      if [[ -z "$version" ]]; then
        if [[ "$subcommand" == pin ]]; then
          _py_select_uv_python_version installed
        else
          _py_select_uv_python_version available
        fi
        local select_rc=$?
        (( select_rc == 130 )) && {
          _py_info "Cancelled."
          return 0
        }
        (( select_rc == 0 )) || return "$select_rc"
        version="$REPLY"
      fi
      _py_validate_python_version "$version" || {
        _py_error "Python versions must use X.Y or X.Y.Z."
        return 2
      }

      local action=""
      local pin_file="" pin_fingerprint="" pin_root_fingerprint=""
      if [[ "$subcommand" == install ]]; then
        action="download and install Python $version through uv"
      else
        _py_validate_python_pin_target || return $?
        pin_file="${REPLY%%$'\t'*}"
        local pin_record="${REPLY#*$'\t'}"
        pin_fingerprint="${pin_record%%$'\t'*}"
        pin_root_fingerprint="${pin_record#*$'\t'}"
        action="write Python $version to $pin_file through uv"
      fi
      _py_header "Python ${subcommand:u}"
      _py_info "Plan: $action"
      [[ "$subcommand" == install ]] \
        && _py_warn "This operation downloads and installs executable runtime code."
      (( dry_run )) && {
        _py_success "Dry run complete; no files changed."
        return 0
      }

      local _PY_AUTO_YES=$assume_yes
      _py_confirm "Proceed with this reviewed Python $subcommand?"
      local confirm_rc=$?
      case "$confirm_rc" in
        0) ;;
        130)
          _py_info "Cancelled."
          return 0
          ;;
        *) return "$confirm_rc" ;;
      esac

      local -i operation_rc=0
      if [[ "$subcommand" == install ]]; then
        command uv python install "$version" >&2 || operation_rc=$?
      else
        _py_validate_python_pin_target \
          "$pin_fingerprint" "$pin_root_fingerprint" || return $?
        local pin_root="${pin_file:h}"
        _py_run_uv_scoped --directory "$pin_root" \
          python pin --no-project --no-python-downloads \
          "$version" >&2 || operation_rc=$?
      fi
      (( operation_rc == 0 )) || {
        _py_error "Python $subcommand failed (status $operation_rc)."
        return "$operation_rc"
      }
      if [[ "$subcommand" == pin ]]; then
        _py_validate_python_pin_target \
          "" "$pin_root_fingerprint" || return $?
        pin_file="${REPLY%%$'\t'*}"
        local pinned_version=""
        pinned_version=$(<"$pin_file") || {
          _py_error "Could not read the resulting Python pin."
          return 1
        }
        [[ "$pinned_version" == "$version" ]] || {
          _py_error "uv returned success but the resulting Python pin did not match."
          return 1
        }
      fi
      _py_success "Python $subcommand completed for $version."
      ;;
    "")
      _py_error "venv-python requires list, install, or pin."
      _py_print_venv_python_usage
      return 2
      ;;
    *)
      _py_error "Unknown venv-python subcommand: $subcommand"
      _py_print_venv_python_usage
      return 2
      ;;
  esac
}

# Compatibility entrypoint owned by the Py suite.
venv-python() {
  _py_venv_python "$@"
}

venv-python-list() {
  _py_venv_python list "$@"
}

venv-python-install() {
  _py_venv_python install "$@"
}

venv-python-pin() {
  _py_venv_python pin "$@"
}

typeset -g _PY_VENV_SOURCED=1
