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

# REPLY is the canonical project root. The working directory may be reached
# through trusted aliases (_py_resolve_trusted_dir), such as macOS /tmp or a
# root-owned /home link; the ownership, mode, and ancestor checks apply to
# the canonical directory.
_py_validate_project_root() {
  zmodload -F zsh/stat b:zstat 2>/dev/null || {
    _py_error "Zsh stat support is required for environment validation."
    return 1
  }

  local root=""
  if _py_resolve_trusted_dir "${PWD:a}"; then
    root="$REPLY"
  fi
  REPLY=""
  local -A root_state=()
  [[ "$root" == /* && "$root" == "${root:A}" \
    && -d "$root" && ! -L "$root" \
    && "$root" != *[[:cntrl:]]* && "$root" != *'|'* ]] \
    && zstat -LH root_state -- "$root" 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 \
      && root_state[uid] == EUID \
      && (root_state[mode] & 8#22) == 0 )) || {
    _py_error "The project directory must be owned, reached without untrusted symbolic links, and not group/world-writable."
    _py_wsl_drive_hint "${root:-${PWD:a}}"
    return 1
  }
  _py_validate_ancestor_chain "$root" || {
    _py_error "The project path contains an untrusted ancestor."
    _py_wsl_drive_hint "$root"
    return 1
  }
  REPLY="$root"
}

# REPLY is a requested environment path in the canonical project's terms: a
# relative path is joined to the canonical root, and an absolute path through
# a trusted alias of its parent maps to the canonical parent. Discovery
# records are canonical, so the result is compared with them literally.
# Usage: _py_project_path <path> <canonical-root>
_py_project_path() {
  local requested="${1-}" root="${2-}" absolute=""
  if [[ "$requested" == /* ]]; then
    absolute="${requested:a}"
  else
    absolute="${root}/${requested}"
    absolute="${absolute:a}"
  fi
  if [[ "$requested" == /* && "$absolute" != "$root"/* \
    && "$absolute" != / ]] \
    && _py_resolve_trusted_dir "${absolute:h}"; then
    absolute="${REPLY%/}/${absolute:t}"
  fi
  REPLY="$absolute"
}

_py_fingerprint_owned_directory() {
  local directory="$1" expected="${2:-}"
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
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
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
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
    local child_output=""
    child_output=$(_py_capture_bounded_output \
      $(( 1024 * 1024 )) ".virtualenvs inventory" 10 \
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
    _py_error "The Py picker failed (status $picker_rc)."
    return 1
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

  _py_validate_project_root || return $?
  _py_project_path "$requested_path" "$REPLY"
  requested_path="$REPLY"
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

# REPLY: the Python version recorded in pyvenv.cfg, or "unknown". The
# standard-library venv module writes "version"; uv writes "version_info".
_py_venv_config_version() {
  emulate -L zsh
  local env_path="$1" line="" version=unknown
  local -a match=() mbegin=() mend=()
  while IFS= read -r line; do
    if [[ "$line" =~ '^(version|version_info)[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$' ]]; then
      version="${match[2]}"
      break
    fi
  done < "$env_path/pyvenv.cfg"
  [[ "$version" =~ ^[[:alnum:]._-]+$ ]] || version=unknown
  REPLY="$version"
}

_py_fingerprint_owned_file() {
  local file_path="$1" max_size="$2" expected="${3:-}"
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || return 1
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

# True when this shell can name its descriptors under /proc/<pid>/fd, which
# Linux and WSL provide and macOS does not.
_py_proc_descriptors_available() {
  zmodload zsh/system 2>/dev/null || return 1
  [[ -d "/proc/${sysparams[pid]}/fd" ]]
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
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || return 1

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
      _py_error "Relocatable environments cannot be activated on this host: activation needs a stable descriptor path from /proc/<pid>/fd, and this host has none (macOS has no /proc)."
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

# reply is (framework owner admin-gid) for python.org's macOS installer, which
# installs root-owned files in group admin (gid 80 on every macOS release).
_py_python_org_framework() {
  reply=()
  local REPLY=""
  _py_system_root_uid || return 1
  reply=(/Library/Frameworks/Python.framework "$REPLY" 80)
}

# True when a group-writable interpreter belongs to python.org's macOS
# framework build. Its installer leaves the framework writable by group
# admin, the macOS administrators, who can already act as root, so that one
# group is accepted there and nowhere else: only on Darwin, only for a file
# in Versions/<version>/bin, only when the file and every directory up to
# the framework are owned by root, never world-writable, and group-writable
# only by admin, and only below ancestors that pass the ordinary rule.
# Usage: _py_python_org_interpreter_trusted <canonical-interpreter>
_py_python_org_interpreter_trusted() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local interpreter="${1-}" REPLY=""
  _py_host_kernel && [[ "$REPLY" == Darwin ]] || return 1
  local -a reply=()
  _py_python_org_framework || return 1
  local framework="${reply[1]-}" owner="${reply[2]-}" admin_gid="${reply[3]-}"
  [[ "$framework" == /?* && "$framework" == "${framework:A}" \
    && "$owner" == <-> && "$admin_gid" == <-> ]] || return 1
  [[ "$interpreter" == "$framework"/Versions/* \
    && "$interpreter" == "${interpreter:A}" ]] || return 1
  local -a relative=("${(@s:/:)${interpreter#$framework/Versions/}}")
  (( ${#relative[@]} == 3 )) && [[ -n "${relative[1]}" \
    && "${relative[2]}" == bin && -n "${relative[3]}" ]] || return 1

  local node="$interpreter"
  local -A node_state=()
  while true; do
    node_state=()
    [[ ! -L "$node" ]] && zstat -LH node_state -- "$node" 2>/dev/null \
      || return 1
    (( node_state[uid] == owner && (node_state[mode] & 8#2) == 0 )) \
      || return 1
    (( (node_state[mode] & 8#20) == 0 || node_state[gid] == admin_gid )) \
      || return 1
    [[ "$node" == "$framework" ]] && break
    [[ "$node" != / ]] || return 1
    node="${node:h}"
  done
  _py_validate_ancestor_chain "$framework"
}

_py_fingerprint_venv_python() {
  local environment_path="$1" expected="${2:-}"
  local python_literal="$environment_path/bin/python"
  local bin_directory="$environment_path/bin"
  _py_fingerprint_owned_directory "$bin_directory" || return $?
  local bin_fingerprint="$REPLY"

  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
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
      && (python_state[mode] & 8#2) == 0 \
      && python_state[size] > 0 \
      && python_state[size] <= 512 * 1024 * 1024 )) \
    && { (( (python_state[mode] & 8#20) == 0 )) \
      || _py_python_org_interpreter_trusted "$resolved_python"; } || {
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

  local active="${VIRTUAL_ENV:-}" record="" environment_path="" project_root=""
  local version="" state="" REPLY
  local -a record_snapshot=("${(@f)records}") rows=()
  _py_validate_project_root 2>/dev/null && project_root="$REPLY"
  for record in "${record_snapshot[@]}"; do
    _py_venv_record_path "$record"
    environment_path="$REPLY"
    _py_venv_config_version "$environment_path"
    version="$REPLY"
    state=inactive
    [[ -n "$active" && "${active:A}" == "$environment_path" ]] && state=active
    if [[ -n "$project_root" && "$environment_path" == "$project_root"/* ]]; then
      rows+=("${environment_path#"$project_root"/}"$'\t'"$version"$'\t'"$state")
    else
      _py_command_display "$environment_path"
      rows+=("$REPLY"$'\t'"$version"$'\t'"$state")
    fi
  done
  if [[ -n "$project_root" ]]; then
    _py_command_display "$project_root"
    _py_label "Project" "$REPLY"
    print -u2 -r -- ""
  fi
  _py_table $'Environment\tPython\tState' "${rows[@]}"
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
    local REPLY
    _py_command_display "$target"
    _py_error "$REPLY already exists; venv-create never replaces it."
    _py_info "Review it with venv-info, then remove it with venv-remove if needed."
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
    _py_error "Poetry environment creation is disabled: its target path cannot be bounded before mutation."
    _py_dim "Nothing was created; use --uv or --venv instead."
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
  local REPLY target_display=""
  _py_command_display "$target"
  target_display="$REPLY"
  _py_label "Environment" "$target_display"
  _py_label "Backend" "$backend"
  if [[ "$backend" == stdlib ]]; then
    _py_label "Python" "$resolved_python_version ($executable)"
  else
    _py_label "Python" "${python_version:-project or uv default}"
  fi
  _py_dim "Packages are installed separately; the new environment starts empty."
  (( dry_run )) && {
    _py_info "Dry run: nothing was created."
    return 0
  }

  local -i confirm_rc=0
  local _PY_AUTO_YES=$assume_yes
  _py_confirm "Create ${target:t} with $backend?"
  confirm_rc=$?
  case "$confirm_rc" in
    0) ;;
    130)
      _py_info "Cancelled: nothing was created."
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
    _py_command_display uv "${uv_args[@]}" "$target"
    _py_run_captured "$REPLY" \
      _py_run_uv_scoped "${uv_args[@]}" "$target" || operation_rc=$?
  else
    _py_command_display "$executable" -m venv "$target"
    _py_run_captured "$REPLY" \
      command "$executable" -I -m venv "$target" || operation_rc=$?
  fi
  (( operation_rc == 0 )) || {
    _py_error "Environment creation failed (status $operation_rc)."
    return "$operation_rc"
  }
  _py_validate_venv_path "$target" || {
    _py_error "The backend returned success but the created environment failed validation."
    return 1
  }
  _py_venv_config_version "$target"
  _py_success "Created $target_display (Python $REPLY)."
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

  # A relocatable script finds its environment from its own path, which
  # only /proc/<pid>/fd keeps stable when it is sourced from a descriptor.
  local -i require_stable_path=0
  local config_line=""
  while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    if [[ "$config_line" =~ '^[[:space:]]*relocatable[[:space:]]*=[[:space:]]*true[[:space:]]*$' ]]; then
      require_stable_path=1
      break
    fi
  done < "$target/pyvenv.cfg"
  if (( require_stable_path )) && ! _py_proc_descriptors_available; then
    _py_error "Relocatable environments cannot be activated on this host: activation needs a stable descriptor path from /proc/<pid>/fd, and this host has none (macOS has no /proc)."
    local script_display=""
    _py_command_display "$activate_file"
    script_display="$REPLY"
    _py_info "Nothing was changed. Review the script, then source it yourself: source $script_display"
    return 1
  fi

  _py_header "Activate Virtual Environment"
  local target_display=""
  _py_command_display "$target"
  target_display="$REPLY"
  _py_label "Environment" "$target_display"
  _py_command_display "$activate_file"
  _py_label "Script" "$REPLY"
  _py_warn "Activation runs this script's shell code in the current shell."
  (( dry_run )) && {
    _py_info "Dry run: the shell was not changed."
    return 0
  }
  local _PY_AUTO_YES=$assume_yes
  _py_confirm "Trust and source this activation script?"
  local confirm_rc=$?
  case "$confirm_rc" in
    0) ;;
    130)
      _py_info "Cancelled: the shell was not changed."
      return 0
      ;;
    *) return "$confirm_rc" ;;
  esac
  _py_validate_venv_path "$target" "$fingerprint" || return $?
  _py_fingerprint_owned_file \
    "$activate_file" $(( 1024 * 1024 )) "$activate_fingerprint" || return $?

  # Read the flag again: the reviewed configuration decides how to source.
  require_stable_path=0
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
  _py_venv_config_version "$target"
  _py_success "Activated: $target_display (Python $REPLY)."
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
  _py_command_display "$target"
  _py_label "Environment" "$REPLY"
  _py_label "Python" "$version"
  _py_label "Backend" "$(_py_detect_venv_backend)"
  if [[ -n "${VIRTUAL_ENV:-}" && "${VIRTUAL_ENV:A}" == "$target" ]]; then
    _py_label "State" "active"
  else
    _py_label "State" "inactive"
  fi
}

# REPLY is the Linux mount table read by _py_assert_no_mounts_under.
_py_mount_table_path() {
  REPLY=/proc/self/mountinfo
}

# Refuses an environment with a mount at or below it before recursive
# removal. Linux and WSL read one bounded snapshot of the kernel mount table
# (/proc/self/mountinfo, the table findmnt reads), which also lists bind
# mounts. macOS has no bind mounts, so a walk that compares each node's
# device with the environment's (lstat, links not followed) finds every mount
# point. Other kernels fail closed. Python 3 parses the table or walks the
# tree under a 15-second deadline.
_py_assert_no_mounts_under() {
  local target="$1"
  local python_command=""
  python_command=$(whence -p python3 2>/dev/null) || python_command=""
  [[ -n "$python_command" && -x "$python_command" ]] || {
    _py_error "Python 3 is required to validate the mount boundary."
    return 1
  }
  local REPLY="" mount_mode=""
  _py_host_kernel || {
    _py_error "Could not identify the host kernel for mount-boundary validation."
    return 1
  }
  # Never an empty argument: the device walk reads no table.
  local table_path=-
  case "$REPLY" in
    Darwin) mount_mode=device ;;
    Linux)
      mount_mode=table
      _py_mount_table_path
      table_path="$REPLY"
      ;;
    *)
      _py_error "Recursive environment removal is not supported on ${REPLY}."
      return 1
      ;;
  esac
  # The validator's stderr is discarded, so refuse a missing bound visibly.
  _py_standalone_timeout_command || return 1

  local mount_output=""
  mount_output=$(
    _py_run_with_timeout 15 "$python_command" -I -c '
import json
import os
import re
import stat
import sys

target = os.path.normpath(os.path.abspath(sys.argv[1]))
mode = sys.argv[2]
table_path = sys.argv[3]
maximum_bytes = 4 * 1024 * 1024
maximum_records = 16384
maximum_nodes = 2000000


def refuse(path):
    print(json.dumps(os.fsdecode(path), ensure_ascii=True))
    raise SystemExit(20)


def unescape(match):
    value = int(match.group(1), 8)
    if value > 255:
        raise SystemExit(8)
    return bytes([value])


if mode == "table":
    target_bytes = os.fsencode(target)
    try:
        with open(table_path, "rb") as handle:
            data = handle.read(maximum_bytes + 1)
    except OSError:
        raise SystemExit(6)
    if len(data) > maximum_bytes:
        raise SystemExit(9)
    count = 0
    for line in data.split(b"\n"):
        if not line:
            continue
        count += 1
        if count > maximum_records:
            raise SystemExit(9)
        fields = line.split(b" ")
        if len(fields) < 5:
            raise SystemExit(8)
        raw = fields[4]
        if not raw.startswith(b"/") or b"\\" in re.sub(rb"\\[0-7]{3}", b"", raw):
            raise SystemExit(8)
        mount_point = os.path.normpath(re.sub(rb"\\([0-7]{3})", unescape, raw))
        if mount_point == target_bytes or mount_point.startswith(target_bytes + b"/"):
            refuse(mount_point)
    if count == 0:
        raise SystemExit(8)
elif mode == "device":
    try:
        device = os.lstat(target).st_dev
        if os.lstat(os.path.dirname(target)).st_dev != device:
            refuse(target)
        pending = [target]
        nodes = 0
        while pending:
            with os.scandir(pending.pop()) as entries:
                for entry in entries:
                    nodes += 1
                    if nodes > maximum_nodes:
                        raise SystemExit(9)
                    info = entry.stat(follow_symlinks=False)
                    if info.st_dev != device:
                        refuse(entry.path)
                    if stat.S_ISDIR(info.st_mode):
                        pending.append(entry.path)
    except OSError:
        raise SystemExit(6)
else:
    raise SystemExit(2)
' "$target" "$mount_mode" "$table_path" </dev/null 2>/dev/null
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
      _py_error "Could not validate the mount boundary below the environment."
      return 1
      ;;
  esac
}

_py_validate_quarantined_venv() {
  local quarantine_target="$1" expected="$2"
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
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
  command chmod -- 700 "$quarantine_dir" 2>/dev/null || {
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
  local REPLY
  _py_command_display "$target"
  _py_success "Removed $REPLY."
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
  local REPLY
  _py_command_display "$target"
  _py_label "Environment" "$REPLY"
  _py_venv_config_version "$target"
  _py_label "Python" "$REPLY"
  _py_warn "The environment is deleted permanently, not quarantined for recovery."
  _py_dim "It is first moved to a private sibling, then that exact copy is deleted."
  (( dry_run )) && {
    _py_info "Dry run: nothing was removed."
    return 0
  }

  local _PY_AUTO_YES=$assume_yes
  _py_confirm "Permanently remove ${target:t}?"
  local confirm_rc=$?
  case "$confirm_rc" in
    0) ;;
    130)
      _py_info "Cancelled: nothing was removed."
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
  local REPLY
  _py_command_display "$target"
  _py_label "Environment" "$REPLY"
  _py_warn "Rebuild cannot yet replace an environment transactionally."
  (( dry_run )) && {
    _py_info "Dry run: nothing was changed."
    return 0
  }
  (( assume_yes )) && _py_debug "--yes cannot bypass transactional safety."
  _py_error "Automatic rebuild is disabled until atomic staging and rollback are implemented."
  _py_info "Nothing was changed. Run venv-remove, then venv-create, if you accept that two-step workflow."
  return 1
}

_py_print_venv_python_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  py-menu venv-python-list [-h|--help]"
  print -u2 -r -- \
    "  py-menu venv-python-install [VERSION] [--dry-run] [--yes]"
  print -u2 -r -- \
    "  py-menu venv-python-pin [VERSION] [--dry-run] [--yes]"
}

# Prints one validated version per line. The "installed-paths" mode lists
# uv-managed runtimes as "version<TAB>interpreter" for display.
_py_uv_python_inventory() {
  local mode="$1"
  local raw_output=""
  local -a producer_args=(uv python list)
  if [[ "$mode" == installed || "$mode" == installed-paths ]]; then
    producer_args+=(--only-installed --managed-python)
  fi
  local UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-10}"
  export UV_HTTP_TIMEOUT
  raw_output=$(_py_capture_bounded_output \
    $(( 2 * 1024 * 1024 )) "uv Python inventory" 20 \
    "${producer_args[@]}") || return $?

  local raw_line="" first_field="" version=""
  local -i raw_count=0 result_count=0 max_results=64
  [[ "$mode" == installed* ]] && max_results=128
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
    if [[ "$mode" == installed-paths ]]; then
      local interpreter="${raw_line#"$first_field"}"
      interpreter="${interpreter#"${interpreter%%[^[:space:]]*}"}"
      interpreter="${interpreter%% -> *}"
      [[ "$interpreter" == /* && "$interpreter" != *[[:cntrl:]]* ]] \
        || interpreter=""
      print -r -- "$version"$'\t'"$interpreter"
    else
      print -r -- "$version"
    fi
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
    _py_error "The Py picker failed (status $picker_rc)."
    return 1
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

# Shared implementation of venv-python-list, venv-python-install, and
# venv-python-pin. The first argument is the fixed action each command passes.
_py_venv_python() {
  emulate -L zsh
  local subcommand="${1:-}"
  (( $# > 0 )) && shift
  case "$subcommand" in
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
      installed_versions=$(_py_uv_python_inventory installed-paths) \
        || return $?
      [[ -n "$installed_versions" ]] || {
        _py_info "No Python runtimes installed through uv."
        return 0
      }
      local installed_version="" REPLY
      local -a version_rows=()
      for installed_version in "${(@f)installed_versions}"; do
        REPLY="—"
        [[ -n "${installed_version#*$'\t'}" ]] \
          && _py_command_display "${installed_version#*$'\t'}"
        version_rows+=("${installed_version%%$'\t'*}"$'\t'"$REPLY")
      done
      _py_table $'Version\tInterpreter' "${version_rows[@]}"
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

      local pin_file="" pin_fingerprint="" pin_root_fingerprint=""
      local nothing_changed="nothing was installed."
      if [[ "$subcommand" == install ]]; then
        _py_header "Install Python Runtime"
        _py_label "Version" "$version"
        _py_label "Source" "uv-managed Python download"
        _py_warn "This operation downloads and installs executable runtime code."
      else
        _py_validate_python_pin_target || return $?
        pin_file="${REPLY%%$'\t'*}"
        local pin_record="${REPLY#*$'\t'}"
        pin_fingerprint="${pin_record%%$'\t'*}"
        pin_root_fingerprint="${pin_record#*$'\t'}"
        nothing_changed="nothing was written."
        _py_header "Pin Python Version"
        _py_label "Version" "$version"
        _py_command_display "$pin_file"
        _py_label "Pin file" "$REPLY"
      fi
      (( dry_run )) && {
        _py_info "Dry run: $nothing_changed"
        return 0
      }

      local _PY_AUTO_YES=$assume_yes
      if [[ "$subcommand" == install ]]; then
        _py_confirm "Install Python $version through uv?"
      else
        _py_confirm "Pin Python $version for this project?"
      fi
      local confirm_rc=$?
      case "$confirm_rc" in
        0) ;;
        130)
          _py_info "Cancelled: $nothing_changed"
          return 0
          ;;
        *) return "$confirm_rc" ;;
      esac

      # Installed versions before and after are the install's evidence.
      local -a installed_before=()
      if [[ "$subcommand" == install ]]; then
        installed_before=(${(f)"$(_py_uv_python_inventory installed 2>/dev/null)"})
      fi
      local -i operation_rc=0
      if [[ "$subcommand" == install ]]; then
        _py_run_captured "uv python install $version" \
          command uv python install "$version" || operation_rc=$?
      else
        _py_validate_python_pin_target \
          "$pin_fingerprint" "$pin_root_fingerprint" || return $?
        local pin_root="${pin_file:h}"
        _py_run_captured "uv python pin $version" \
          _py_run_uv_scoped --directory "$pin_root" \
          python pin --no-project --no-python-downloads \
          "$version" || operation_rc=$?
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
        _py_command_display "$pin_file"
        _py_success "Pinned Python $version in $REPLY."
        return 0
      fi
      local installed_version="" new_version=""
      local -a installed_after=(
        ${(f)"$(_py_uv_python_inventory installed 2>/dev/null)"}
      )
      for installed_version in "${installed_after[@]}"; do
        [[ "$installed_version" == "$version" \
          || "$installed_version" == "$version".* ]] || continue
        (( ${installed_before[(Ie)$installed_version]} )) && continue
        new_version="$installed_version"
        break
      done
      if [[ -n "$new_version" ]]; then
        _py_success "Installed Python $new_version."
      elif (( ${#installed_after[@]} > 0 )) \
        && (( ${installed_after[(I)$version|$version.*]} )); then
        _py_success "Python $version was already installed."
      else
        _py_success "uv completed the Python $version installation."
      fi
      ;;
    *)
      _py_error "Unknown Python runtime action: $subcommand"
      return 2
      ;;
  esac
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
