#!/usr/bin/env zsh
# =============================================================================
# Dev Export: dependency export and package build
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh and dev-state.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_EXPORT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_dev_export_deps_usage() {
  print -u2 -r -- "Usage: dev-export-deps [options]"
  print -u2 -r -- "  --dev            Include the dev dependency group."
  print -u2 -r -- "  --all            Include every dependency group."
  print -u2 -r -- "  --output=FILE    Write to FILE (default requirements.txt)."
  print -u2 -r -- "  -o FILE          Same as --output=FILE."
  print -u2 -r -- "  --yes            Overwrite an existing file without asking."
}

# Validates a caller-provided output path. The file must land inside the
# project or the user's home, and no existing path component may be a symlink.
_dev_export_resolve_output() {
  local requested="$1"

  if [[ -z "$requested" ]]; then
    _dev_error "An output filename is required."
    return 1
  fi

  local literal="${requested:a}"
  local resolved="${requested:A}"
  if [[ "$literal" != "$resolved" || -L "$literal" ]]; then
    _dev_error "Refusing a symlinked output path: $literal"
    return 1
  fi
  if [[ -d "$literal" ]]; then
    _dev_error "Output path is a directory: $literal"
    return 1
  fi
  if [[ -e "$literal" && ! -f "$literal" ]]; then
    _dev_error "Output path is not a regular file: $literal"
    return 1
  fi

  if ! _dev_within_root "${PWD:A}" "$literal" \
    && ! _dev_within_root "${HOME:A}" "$literal"; then
    _dev_error "Output path must be inside the project or your home: $literal"
    return 1
  fi

  local parent="${literal:h}"
  if [[ "${parent:a}" != "${parent:A}" || ! -d "$parent" || -L "$parent" ]]; then
    _dev_error "Output directory does not exist: $parent"
    return 1
  fi

  print -r -- "$literal"
}

# stdout: "absent" or a stable identity for the current destination.
_dev_export_destination_identity() {
  local target_path="$1"

  if [[ ! -e "$target_path" && ! -L "$target_path" ]]; then
    print -r -- "absent"
    return 0
  fi

  if [[ -L "$target_path" || ! -f "$target_path" \
    || "${target_path:a}" != "${target_path:A}" ]]; then
    _dev_error "Refusing an unsafe export destination: $target_path"
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || {
    _dev_error "The zsh/stat module is required to validate export identity."
    return 1
  }
  local -A before=() after=()
  zstat -H before -- "$target_path" 2>/dev/null || {
    _dev_error "Could not inspect the export destination: $target_path"
    return 1
  }
  if (( before[uid] != EUID )); then
    _dev_error "Refusing to replace an export not owned by the current user."
    return 1
  fi

  local checksum=""
  checksum=$(command cksum < "$target_path" 2>/dev/null) || return 1
  zstat -H after -- "$target_path" 2>/dev/null || return 1
  local before_identity="${before[device]}:${before[inode]}:${before[mode]}:${before[nlink]}:${before[size]}:${before[mtime]}:${before[ctime]}"
  local after_identity="${after[device]}:${after[inode]}:${after[mode]}:${after[nlink]}:${after[size]}:${after[mtime]}:${after[ctime]}"
  if [[ "$after_identity" != "$before_identity" ]]; then
    _dev_error "The export destination changed while it was inspected."
    return 1
  fi

  local -a checksum_fields=(${=checksum})
  (( ${#checksum_fields[@]} == 2 )) \
    && [[ "${checksum_fields[1]}" == <-> \
      && "${checksum_fields[2]}" == <-> ]] || return 1
  print -r -- \
    "${after_identity}:${checksum_fields[1]}:${checksum_fields[2]}"
}

# stdout: the identity of the inode held open by a read-only descriptor. Keeping
# the descriptor open prevents an unlinked destination inode from being reused
# while the overwrite confirmation is pending.
_dev_export_fd_identity() {
  local descriptor="$(( $1 ))"
  zmodload zsh/stat zsh/system 2>/dev/null || return 1
  local -A before=() after=()
  zstat -H before -f "$descriptor" 2>/dev/null || return 1
  (( before[uid] == EUID )) || return 1

  sysseek -u "$descriptor" -w start 0 2>/dev/null || return 1
  local checksum=""
  checksum=$(command cksum <&$descriptor 2>/dev/null)
  local -i checksum_status=$?
  sysseek -u "$descriptor" -w start 0 2>/dev/null || return 1
  (( checksum_status == 0 )) || return $checksum_status

  zstat -H after -f "$descriptor" 2>/dev/null || return 1
  local before_identity="${before[device]}:${before[inode]}:${before[mode]}:${before[nlink]}:${before[size]}:${before[mtime]}:${before[ctime]}"
  local after_identity="${after[device]}:${after[inode]}:${after[mode]}:${after[nlink]}:${after[size]}:${after[mtime]}:${after[ctime]}"
  [[ "$after_identity" == "$before_identity" ]] || return 1

  local -a checksum_fields=(${=checksum})
  (( ${#checksum_fields[@]} == 2 )) \
    && [[ "${checksum_fields[1]}" == <-> \
      && "${checksum_fields[2]}" == <-> ]] || return 1
  print -r -- \
    "${after_identity}:${checksum_fields[1]}:${checksum_fields[2]}"
}

_dev_export_validate_temp() {
  local target_path="$1"
  local parent="$2"

  if [[ "${target_path:a}" != "${target_path:A}" \
    || "${target_path:h}" != "${parent:A}" \
    || ! -f "$target_path" || -L "$target_path" ]]; then
    _dev_error "Refusing an unsafe temporary export file."
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$target_path" 2>/dev/null || return 1
  if (( metadata[uid] != EUID || metadata[nlink] != 1 \
    || (metadata[mode] & 8#77) != 0 )); then
    _dev_error "The temporary export file is not private and owner-controlled."
    return 1
  fi
}

# dev-export-deps
#   Arguments: --dev | --all | --output=FILE | -o FILE | --yes | --help
#   stdout:    none. Progress and results go to stderr.
#   Effects:   creates or overwrites the requested export file.
#   Requires:  uv.
#   Status:    0 on success, 1 on failure, 2 on invalid arguments.
dev-export-deps() {
  emulate -L zsh

  local include_dev=0
  local all_groups=0
  local output_file="requirements.txt"
  local -i auto_yes=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) _dev_export_deps_usage; return 0 ;;
      --dev)     include_dev=1 ;;
      --all)     all_groups=1 ;;
      --yes|-y)  auto_yes=1 ;;
      --output=*)
        output_file="${1#*=}"
        if [[ -z "$output_file" ]]; then
          _dev_error "--output requires a filename."
          return 2
        fi
        ;;
      -o)
        shift
        if (( $# == 0 )) || [[ -z "$1" ]]; then
          _dev_error "-o requires a filename."
          return 2
        fi
        output_file="$1"
        ;;
      *)
        _dev_error "Unknown option: $1"
        _dev_export_deps_usage
        return 2
        ;;
    esac
    shift
  done

  if (( include_dev && all_groups )); then
    _dev_error "--dev and --all are mutually exclusive."
    return 2
  fi

  _dev_header "Exporting Dependencies"
  _dev_require_command uv || return 1
  _dev_require_file "pyproject.toml" || return 1

  local resolved_output output_parent parent_identity destination_identity
  resolved_output=$(_dev_export_resolve_output "$output_file") || return 1
  output_parent="${resolved_output:h}"
  parent_identity=$(
    _dev_write_directory_identity "$output_parent" "export directory"
  ) || return 1
  destination_identity=$(
    _dev_export_destination_identity "$resolved_output"
  ) || return 1

  local -i destination_fd=-1
  local destination_fd_identity=""
  if [[ "$destination_identity" != "absent" ]]; then
    zmodload zsh/system 2>/dev/null || {
      _dev_error "The zsh/system module is required for safe overwrite locking."
      return 1
    }
    sysopen -r -o nofollow,cloexec -u destination_fd \
      -- "$resolved_output" 2>/dev/null \
      || {
        _dev_error "Could not hold the existing export open for revalidation."
        return 1
      }
    destination_fd_identity=$(
      _dev_export_fd_identity "$destination_fd"
    ) || {
      exec {destination_fd}<&-
      return 1
    }
    if [[ "$destination_fd_identity" != "$destination_identity" ]]; then
      _dev_error "The export destination changed before authorization."
      exec {destination_fd}<&-
      return 1
    fi
  fi

  {
    if [[ "$destination_identity" != "absent" ]] && (( ! auto_yes )); then
      local overwrite_outcome
      overwrite_outcome=$(_dev_confirm_outcome \
        "Overwrite existing $resolved_output?")
      case "$overwrite_outcome" in
        confirmed) ;;
        unavailable)
          _dev_error \
            "$resolved_output already exists; pass --yes to overwrite it non-interactively."
          return 1
          ;;
        *)
          _dev_info "Cancelled. No file was written."
          return 0
          ;;
      esac
    fi

    # A dependency export must never refresh uv.lock as a hidden side effect.
    # A stale lock is an explicit failure instead of an implicit update.
    local -a export_args=(--locked --format requirements.txt --no-hashes)
    if (( all_groups )); then
      export_args+=(--all-groups)
      _dev_info "Exporting every dependency group..."
    elif (( include_dev )); then
      export_args+=(--no-default-groups --group dev)
      _dev_info "Exporting with dev dependencies..."
    else
      export_args+=(--no-default-groups)
      _dev_info "Exporting production dependencies only..."
    fi

    # Write through a same-directory temporary so a failed export never leaves
    # a truncated requirements file in place of a working one.
    local temp_output=""
    local -i temp_fd=-1
    local temp_descriptor=""
    temp_output=$(command mktemp \
      "${output_parent}/.${resolved_output:t}.XXXXXX" 2>/dev/null) || {
      _dev_error "Could not create a temporary export file."
      return 1
    }

    {
      command chmod 600 -- "$temp_output" 2>/dev/null || {
        _dev_error "Could not make the temporary export owner-only."
        return 1
      }
      _dev_export_validate_temp "$temp_output" "$output_parent" || return 1

      zmodload zsh/system 2>/dev/null || {
        _dev_error "The zsh/system module is required for safe export staging."
        return 1
      }
      sysopen -rw -o nofollow,cloexec -u temp_fd \
        -- "$temp_output" 2>/dev/null || {
        _dev_error "Could not hold the temporary export open safely."
        return 1
      }
      # sysopen may assign an octal-rendered integer (for example 8#17).
      # Redirections treat that rendering as a filename, so normalize it to a
      # plain decimal scalar before duplicating the descriptor.
      temp_descriptor="$(( temp_fd ))"
      local initial_temp_path_identity initial_temp_fd_identity
      initial_temp_path_identity=$(
        _dev_export_destination_identity "$temp_output"
      ) || return 1
      initial_temp_fd_identity=$(
        _dev_export_fd_identity "$temp_descriptor"
      ) || return 1
      if [[ "$initial_temp_fd_identity" != "$initial_temp_path_identity" ]]; then
        _dev_error "The temporary export changed before generation."
        return 1
      fi

      if ! command uv export "${export_args[@]}" >&$temp_descriptor; then
        _dev_error "uv could not export the project dependencies."
        return 1
      fi

      local generated_temp_path_identity generated_temp_fd_identity
      generated_temp_path_identity=$(
        _dev_export_destination_identity "$temp_output"
      ) || return 1
      generated_temp_fd_identity=$(
        _dev_export_fd_identity "$temp_descriptor"
      ) || return 1
      if [[ "$generated_temp_fd_identity" != "$generated_temp_path_identity" ]]; then
        _dev_error "The temporary export changed during generation."
        return 1
      fi
      if [[ ! -s "$temp_output" ]]; then
        _dev_error "uv produced an empty dependency export."
        return 1
      fi

      local -i count
      count=$(command grep -cvE \
        '^[[:space:]]*($|#)' "$temp_output" 2>/dev/null) || count=0

      local current_parent_identity current_destination_identity
      current_parent_identity=$(
        _dev_write_directory_identity "$output_parent" "export directory"
      ) || return 1
      if [[ "$current_parent_identity" != "$parent_identity" ]]; then
        _dev_error "The export directory changed during the operation."
        return 1
      fi

      current_destination_identity=$(
        _dev_export_destination_identity "$resolved_output"
      ) || return 1
      if [[ "$current_destination_identity" != "$destination_identity" ]]; then
        _dev_error "The export destination changed after authorization."
        return 1
      fi
      if (( destination_fd >= 0 )); then
        local current_fd_identity
        current_fd_identity=$(
          _dev_export_fd_identity "$destination_fd"
        ) || return 1
        if [[ "$current_fd_identity" != "$destination_fd_identity" ]]; then
          _dev_error "The authorized export inode changed before publication."
          return 1
        fi
      fi
      _dev_export_validate_temp "$temp_output" "$output_parent" || return 1
      local final_temp_path_identity final_temp_fd_identity
      final_temp_path_identity=$(
        _dev_export_destination_identity "$temp_output"
      ) || return 1
      final_temp_fd_identity=$(
        _dev_export_fd_identity "$temp_descriptor"
      ) || return 1
      if [[ "$final_temp_fd_identity" != "$final_temp_path_identity" \
        || "$final_temp_fd_identity" != "$generated_temp_fd_identity" ]]; then
        _dev_error "The generated export changed before publication."
        return 1
      fi

      if [[ "$destination_identity" == "absent" ]]; then
        command ln -- "$temp_output" "$resolved_output" 2>/dev/null || {
          _dev_error \
            "The export destination appeared before publication; nothing was overwritten."
          return 1
        }
        command rm -f -- "$temp_output" || {
          _dev_error "Could not finalize the dependency export."
          return 1
        }
        temp_output=""
      else
        command mv -f -- "$temp_output" "$resolved_output" || {
          _dev_error "Could not publish the export to $resolved_output"
          return 1
        }
        temp_output=""
      fi
      _dev_success "Exported $count package(s) to $resolved_output"
    } always {
      (( temp_fd >= 0 )) && exec {temp_fd}>&-
      [[ -n "$temp_output" && -e "$temp_output" ]] \
        && command rm -f -- "$temp_output"
    }
  } always {
    (( destination_fd >= 0 )) && exec {destination_fd}<&-
  }
}

# dev-build-package
#   Arguments: --help only.
#   stdout:    none. Build tool output is UI and goes to stderr.
#   Effects:   creates dist/ artifacts through uv build or isolated Python.
#   Status:    the build tool's status, 1 when no backend exists, 2 on bad args.
dev-build-package() {
  emulate -L zsh

  local REPLY
  _dev_parse_no_arguments dev-build-package "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-build-package"
    print -u2 -r -- \
      "  Build a wheel and sdist with uv build, or python3 -I -m build."
    print -u2 -r -- \
      "  The selected project build backend may execute code and resolve dependencies."
    return 0
  fi

  _dev_header "Building Package"
  _dev_require_file "pyproject.toml" || return 1

  local -i exit_code=0
  if command -v uv &>/dev/null; then
    _dev_info "Building package via uv build..."
    command uv build >&2
    exit_code=$?
  elif command -v python3 &>/dev/null \
    && command python3 -I -c 'import build' &>/dev/null; then
    _dev_info "Building package via python3 -I -m build..."
    command python3 -I -m build >&2
    exit_code=$?
  else
    _dev_error "Neither 'uv' nor the Python 'build' module is available."
    _dev_info "Install one of them: uv, or python3 -I -m pip install build"
    return 1
  fi

  if (( exit_code == 0 )); then
    _dev_success "Package built successfully."
  else
    _dev_error "Package build failed (exit status: $exit_code)."
  fi
  return $exit_code
}

typeset -g _DEV_EXPORT_SOURCED=1
