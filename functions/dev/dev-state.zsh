#!/usr/bin/env zsh
# =============================================================================
# Dev State: validated state directories, pyproject backups, and restore
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_STATE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g _DEV_LAST_BACKUP_FILE=""
typeset -g _DEV_LAST_BACKUP_MODE=""

# --- Filesystem identity helpers -------------------------------------------

# stdout: device:inode for an owner-controlled, non-symlinked directory.
_dev_directory_identity() {
  local target_path="$1"
  local label="${2:-directory}"
  local literal="${target_path:a}"
  local resolved="${target_path:A}"

  if [[ -z "$literal" || "$literal" != "$resolved" \
    || ! -d "$literal" || -L "$literal" ]]; then
    _dev_error "Refusing to use a missing or symlinked $label: $literal"
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || {
    _dev_error "The zsh/stat module is required to validate $label identity."
    return 1
  }

  local -A metadata=()
  zstat -H metadata -- "$literal" 2>/dev/null || {
    _dev_error "Could not inspect $label: $literal"
    return 1
  }

  if (( metadata[uid] != EUID )); then
    _dev_error "Refusing a $label not owned by the current user: $literal"
    return 1
  fi

  print -r -- "${metadata[device]}:${metadata[inode]}"
}

# stdout: device:inode for an owner-controlled directory that is safe for
# pathname-based temporary publication. Other users must not be able to
# replace entries between validation and the final same-directory rename.
_dev_write_directory_identity() {
  local target_path="$1"
  local label="${2:-write directory}"
  local identity
  identity=$(_dev_directory_identity "$target_path" "$label") || return 1

  zmodload zsh/stat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$target_path" 2>/dev/null || return 1
  if (( (metadata[mode] & 8#22) != 0 \
    && (metadata[mode] & 8#1000) == 0 )); then
    _dev_error \
      "Refusing a group/world-writable $label without sticky-bit protection: ${target_path:a}"
    return 1
  fi

  print -r -- "$identity"
}

# stdout: "absent" or a stable identity for an owner-controlled regular file.
_dev_owned_file_identity() {
  local target_path="$1"
  local label="${2:-file}"

  if [[ ! -e "$target_path" && ! -L "$target_path" ]]; then
    print -r -- "absent"
    return 0
  fi

  if [[ "${target_path:a}" != "${target_path:A}" \
    || ! -f "$target_path" || -L "$target_path" ]]; then
    _dev_error "Refusing an unsafe $label: ${target_path:a}"
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$target_path" 2>/dev/null || return 1
  if (( metadata[uid] != EUID )); then
    _dev_error \
      "Refusing a $label not owned by the current user: ${target_path:a}"
    return 1
  fi

  print -r -- \
    "${metadata[device]}:${metadata[inode]}:${metadata[mode]}:${metadata[nlink]}"
}

# stdout: "absent" or a stable identity plus checksum for one owner-controlled
# regular file. This detects in-place edits that preserve the inode and mode.
_dev_owned_file_fingerprint() {
  local target_path="$1"
  local label="${2:-file}"

  if [[ ! -e "$target_path" && ! -L "$target_path" ]]; then
    print -r -- "absent"
    return 0
  fi

  _dev_owned_file_identity "$target_path" "$label" >/dev/null || return 1
  zmodload zsh/stat 2>/dev/null || return 1

  local -A before=() after=()
  zstat -H before -- "$target_path" 2>/dev/null || return 1
  local checksum=""
  checksum=$(command cksum < "$target_path" 2>/dev/null) || return 1
  zstat -H after -- "$target_path" 2>/dev/null || return 1

  local before_identity="${before[device]}:${before[inode]}:${before[mode]}:${before[nlink]}:${before[size]}:${before[mtime]}:${before[ctime]}"
  local after_identity="${after[device]}:${after[inode]}:${after[mode]}:${after[nlink]}:${after[size]}:${after[mtime]}:${after[ctime]}"
  if [[ "$after_identity" != "$before_identity" ]]; then
    _dev_error "$label changed while its content was inspected."
    return 1
  fi

  local -a checksum_fields=(${=checksum})
  if (( ${#checksum_fields[@]} != 2 )) \
    || [[ "${checksum_fields[1]}" != <-> \
      || "${checksum_fields[2]}" != <-> ]]; then
    _dev_error "Could not fingerprint $label."
    return 1
  fi
  print -r -- \
    "${after_identity}:${checksum_fields[1]}:${checksum_fields[2]}"
}

# stdout: device:inode for a private state directory.
_dev_state_directory_identity() {
  local target_path="$1"
  local label="$2"
  local identity
  identity=$(
    _dev_directory_identity "$target_path" "$label directory"
  ) || return 1

  zmodload zsh/stat 2>/dev/null || {
    _dev_error "The zsh/stat module is required to validate state permissions."
    return 1
  }
  local -A metadata=()
  zstat -H metadata -- "$target_path" 2>/dev/null || {
    _dev_error "Could not inspect the $label directory: $target_path"
    return 1
  }

  if (( (metadata[mode] & 8#7777) != 8#700 )); then
    _dev_error \
      "The $label directory must be private (mode 700): $target_path"
    return 1
  fi

  print -r -- "$identity"
}

_dev_state_assert_directory_identity() {
  local target_path="$1"
  local label="$2"
  local expected="$3"
  local current
  current=$(
    _dev_state_directory_identity "$target_path" "$label"
  ) || return 1

  if [[ "$current" != "$expected" ]]; then
    _dev_error "The $label directory changed during the operation; refusing to continue."
    return 1
  fi
}

# Validates an existing owner-only regular file immediately below a state
# directory. Hard links are refused so a state write or prune cannot affect a
# second filesystem name.
#
# The optional fourth argument selects the permission policy: `private` (the
# default) requires no group or other bits; `legacy` additionally accepts a
# world-readable file created before state files were hardened. Only pruning
# uses `legacy`, because removing an owned stale copy discloses nothing, while
# reading or restoring one still requires the private mode.
_dev_state_validate_file() {
  local target_path="$1"
  local state_dir="$2"
  local label="${3:-state file}"
  local mode_policy="${4:-private}"
  local literal="${target_path:a}"
  local resolved="${target_path:A}"

  if [[ "$mode_policy" != "private" && "$mode_policy" != "legacy" ]]; then
    _dev_error "Unknown state file permission policy: $mode_policy"
    return 1
  fi

  if [[ "$literal" != "$resolved" || "${literal:h}" != "${state_dir:A}" \
    || ! -f "$literal" || -L "$literal" ]]; then
    _dev_error "Refusing an unsafe $label: $literal"
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$literal" 2>/dev/null || {
    _dev_error "Could not inspect $label: $literal"
    return 1
  }

  local -i mode_accepted=1
  if [[ "$mode_policy" == "private" ]]; then
    (( (metadata[mode] & 8#77) == 0 )) || mode_accepted=0
  fi
  if (( metadata[uid] != EUID || metadata[nlink] != 1 || ! mode_accepted )); then
    _dev_error \
      "Refusing a non-private, multiply linked, or foreign-owned $label: $literal"
    return 1
  fi
}

# Sets REPLY to a stable identity and checksum for one validated state file.
_dev_state_file_fingerprint() {
  local target_path="$1"
  local state_dir="$2"
  local label="${3:-state file}"
  REPLY=""

  _dev_state_validate_file "$target_path" "$state_dir" "$label" || return 1
  zmodload zsh/stat 2>/dev/null || return 1

  local -A before=() after=()
  zstat -H before -- "$target_path" 2>/dev/null || return 1
  local checksum=""
  checksum=$(command cksum < "$target_path" 2>/dev/null) || return 1
  zstat -H after -- "$target_path" 2>/dev/null || return 1

  local before_identity="${before[device]}:${before[inode]}:${before[mode]}:${before[nlink]}:${before[size]}:${before[mtime]}:${before[ctime]}"
  local after_identity="${after[device]}:${after[inode]}:${after[mode]}:${after[nlink]}:${after[size]}:${after[mtime]}:${after[ctime]}"
  [[ "$after_identity" == "$before_identity" ]] || return 1

  local -a checksum_fields=(${=checksum})
  (( ${#checksum_fields[@]} == 2 )) \
    && [[ "${checksum_fields[1]}" == <-> \
      && "${checksum_fields[2]}" == <-> ]] || return 1
  REPLY="${after_identity}:${checksum_fields[1]}:${checksum_fields[2]}"
}

# stdout: device:inode for a private, singly linked regular temporary directly
# below an already validated write directory.
_dev_temporary_file_identity() {
  local target_path="$1"
  local parent_dir="$2"
  local label="${3:-temporary file}"
  local -i require_private="${4:-1}"

  if [[ "${target_path:a}" != "${target_path:A}" \
    || "${target_path:h}" != "${parent_dir:A}" \
    || ! -f "$target_path" || -L "$target_path" ]]; then
    _dev_error "Refusing an unsafe $label: ${target_path:a}"
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$target_path" 2>/dev/null || return 1
  if (( metadata[uid] != EUID || metadata[nlink] != 1 \
    || (require_private && (metadata[mode] & 8#77) != 0) )); then
    _dev_error \
      "Refusing a non-private, multiply linked, or foreign-owned $label."
    return 1
  fi
  print -r -- "${metadata[device]}:${metadata[inode]}"
}

# --- State directory resolution -------------------------------------------

# Emits the validated absolute path on stdout. A configured directory must stay
# inside the project or the user's home so a stray override cannot direct
# writes at a system location.
_dev_state_resolve() {
  local configured="$1"
  local label="$2"

  if [[ -z "$configured" ]]; then
    _dev_error "$label directory is not configured."
    return 1
  fi

  if [[ "$configured" == ".." || "$configured" == ../* \
    || "$configured" == */../* || "$configured" == */.. ]]; then
    _dev_error "$label directory must not contain '..' segments: $configured"
    return 1
  fi

  local literal="${configured:a}"
  local resolved="${configured:A}"
  local project_root="${PWD:A}"
  local home_root="${HOME:A}"

  if [[ -z "$resolved" || "$resolved" == "/" ]]; then
    _dev_error "Refusing to use the filesystem root as the $label directory."
    return 1
  fi

  if [[ "$literal" != "$resolved" ]]; then
    _dev_error "Refusing to use a symlinked $label directory: $literal"
    return 1
  fi

  if [[ "$resolved" == "$project_root" || "$resolved" == "$home_root" ]]; then
    _dev_error \
      "$label directory must be a dedicated subdirectory, not $resolved"
    return 1
  fi

  if ! _dev_within_root "$project_root" "$resolved" \
    && ! _dev_within_root "$home_root" "$resolved"; then
    _dev_error \
      "$label directory must live inside the project or your home: $resolved"
    return 1
  fi

  print -r -- "$resolved"
}

# Resolves, creates, and restricts a state directory. Backups, profiles, and
# reports can contain project metadata, so every component must remain
# owner-controlled and the final directory is fail-closed at mode 700.
_dev_state_prepare() {
  local configured="$1"
  local label="$2"
  local resolved
  resolved=$(_dev_state_resolve "$configured" "$label") || return 1

  if [[ ! -d "$resolved" ]]; then
    ( umask 077; command mkdir -p -- "$resolved" ) 2>/dev/null || {
      _dev_error "Could not create the $label directory: $resolved"
      return 1
    }
  fi

  local identity_before_chmod
  identity_before_chmod=$(
    _dev_directory_identity "$resolved" "$label directory"
  ) || return 1
  command chmod 700 -- "$resolved" 2>/dev/null || {
    _dev_error "Could not restrict permissions on $resolved"
    return 1
  }

  local identity_after_chmod
  identity_after_chmod=$(
    _dev_state_directory_identity "$resolved" "$label"
  ) || return 1
  if [[ "$identity_after_chmod" != "$identity_before_chmod" ]]; then
    _dev_error "The $label directory changed while permissions were applied."
    return 1
  fi
  print -r -- "$resolved"
}

_dev_backup_dir_path() {
  _dev_state_prepare "$DEV_BACKUP_DIR" "backup"
}

_dev_profile_dir_path() {
  _dev_state_prepare "$DEV_PROFILE_DIR" "profile"
}

_dev_report_dir_path() {
  _dev_state_prepare "$DEV_REPORT_DIR" "report"
}

# stdout: a filesystem-safe timestamp in YYYYMMDD_HHMMSS form. Output from an
# external date command is data and must be validated before path composition.
_dev_state_timestamp() {
  local timestamp
  timestamp=$(command date +%Y%m%d_%H%M%S 2>/dev/null) || {
    _dev_error "Could not generate a state timestamp."
    return 1
  }

  local date_part="${timestamp%%_*}"
  local time_part="${timestamp#*_}"
  if [[ ${#timestamp} -ne 15 \
    || ${#date_part} -ne 8 || "$date_part" != <-> \
    || ${#time_part} -ne 6 || "$time_part" != <-> ]]; then
    _dev_error "The generated state timestamp has an invalid format."
    return 1
  fi

  print -r -- "$timestamp"
}

# Read-only lookup for list and restore paths. A missing directory is a normal
# status-1 absence; an unsafe existing path is diagnosed and refused.
_dev_state_existing() {
  local configured="$1"
  local label="$2"
  local resolved
  resolved=$(_dev_state_resolve "$configured" "$label") || return 1

  [[ -e "$resolved" || -L "$resolved" ]] || return 1
  _dev_state_directory_identity "$resolved" "$label" >/dev/null || return 1
  print -r -- "$resolved"
}

# --- pyproject.toml backup and restore -------------------------------------

# dev-backup-pyproject
#   Arguments: none.
#   stdout:    none. Progress and results go to stderr.
#   Effects:   creates DEV_BACKUP_DIR (mode 700) and one unique, atomically
#              published pyproject.toml copy, then prunes old private copies.
#   Status:    0 on success, 1 when input/state is unusable, 2 on bad arguments.
dev-backup-pyproject() {
  emulate -L zsh

  local REPLY
  _dev_parse_no_arguments dev-backup-pyproject "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-backup-pyproject"
    print -u2 -r -- \
      "  Save a timestamped pyproject.toml backup under \$DEV_BACKUP_DIR."
    print -u2 -r -- \
      "  Retains the newest \$DEV_BACKUP_RETENTION copies (default 5)."
    return 0
  fi

  _DEV_LAST_BACKUP_FILE=""
  _DEV_LAST_BACKUP_MODE=""
  _dev_require_file "pyproject.toml" || return 1
  if [[ -L "${PWD:A}/pyproject.toml" ]]; then
    _dev_error "Refusing to back up a symlinked pyproject.toml."
    return 1
  fi
  _dev_owned_file_identity \
    "${PWD:A}/pyproject.toml" "pyproject.toml" >/dev/null || return 1

  zmodload zsh/stat 2>/dev/null || return 1
  local -A source_metadata=()
  zstat -H source_metadata -- "${PWD:A}/pyproject.toml" 2>/dev/null || return 1
  local source_mode
  source_mode=$(printf '%o' $(( source_metadata[mode] & 8#777 )))

  local retention="$DEV_BACKUP_RETENTION"
  if [[ "$retention" != <-> ]] || (( retention < 1 || retention > 100 )); then
    _dev_error "DEV_BACKUP_RETENTION must be an integer between 1 and 100."
    return 1
  fi

  local backup_dir directory_identity
  backup_dir=$(_dev_backup_dir_path) || return 1
  directory_identity=$(
    _dev_state_directory_identity "$backup_dir" "backup"
  ) || return 1

  local timestamp
  timestamp=$(_dev_state_timestamp) || {
    _dev_error "Could not generate a backup timestamp."
    return 1
  }

  local temp_file=""
  temp_file=$(command mktemp \
    "${backup_dir}/.pyproject.toml.XXXXXX" 2>/dev/null) || {
    _dev_error "Could not create a temporary backup."
    return 1
  }

  local published_file=""
  local temp_identity=""
  local -i temp_validated=0
  {
    temp_identity=$(
      _dev_temporary_file_identity \
        "$temp_file" "$backup_dir" "new backup temporary"
    ) || return 1
    temp_validated=1
    _dev_state_assert_directory_identity \
      "$backup_dir" "backup" "$directory_identity" || return 1
    command chmod 600 -- "$temp_file" 2>/dev/null || {
      _dev_error "Could not make the temporary backup owner-only."
      return 1
    }
    local source_identity_before source_identity_after
    source_identity_before=$(
      _dev_owned_file_identity \
        "${PWD:A}/pyproject.toml" "pyproject.toml"
    ) || return 1
    command cp -- pyproject.toml "$temp_file" 2>/dev/null || {
      _dev_error "Could not copy pyproject.toml into the backup directory."
      return 1
    }
    source_identity_after=$(
      _dev_owned_file_identity \
        "${PWD:A}/pyproject.toml" "pyproject.toml"
    ) || return 1
    if [[ "$source_identity_after" != "$source_identity_before" ]] \
      || ! command cmp -s -- pyproject.toml "$temp_file"; then
      _dev_error "pyproject.toml changed while its backup was being created."
      return 1
    fi
    _dev_state_validate_file \
      "$temp_file" "$backup_dir" "temporary backup" || return 1
    local current_temp_identity
    current_temp_identity=$(
      _dev_temporary_file_identity \
        "$temp_file" "$backup_dir" "temporary backup"
    ) || return 1
    if [[ "$current_temp_identity" != "$temp_identity" ]]; then
      _dev_error "The temporary backup changed while it was being created."
      return 1
    fi
    _dev_state_assert_directory_identity \
      "$backup_dir" "backup" "$directory_identity" || return 1

    local -i suffix=0 published=0
    while (( suffix < 1000 )); do
      if (( suffix == 0 )); then
        published_file="${backup_dir}/pyproject.toml.${timestamp}.bak"
      else
        published_file="${backup_dir}/pyproject.toml.${timestamp}.${suffix}.bak"
      fi

      if command ln -- "$temp_file" "$published_file" 2>/dev/null; then
        command rm -f -- "$temp_file" || {
          _dev_error "Could not finalize the backup publication."
          return 1
        }
        temp_file=""
        published=1
        break
      fi
      suffix=$(( suffix + 1 ))
    done

    if (( ! published )); then
      _dev_error "Could not allocate a unique backup filename."
      return 1
    fi

    _dev_state_assert_directory_identity \
      "$backup_dir" "backup" "$directory_identity" || return 1
    _dev_state_validate_file \
      "$published_file" "$backup_dir" "published backup" || return 1

    # The backup created by this invocation must survive pruning regardless of
    # clock skew or manipulated mtimes. Retention keeps it plus the newest
    # retention-1 pre-existing backups.
    #
    # Pruning is best effort. The invocation backup is already published and
    # validated above, so a stale copy that cannot be proven prunable is left
    # in place with a warning instead of failing the update that depends on
    # the new backup. World-readable copies written before state files were
    # hardened remain prunable: they are owned, singly linked, and regular.
    local -a backups=("${backup_dir}"/pyproject.toml.*.bak(N.om.))
    local -a previous_backups=()
    local candidate
    for candidate in "${backups[@]}"; do
      [[ "$candidate" == "$published_file" ]] \
        || previous_backups+=("$candidate")
    done
    local -i keep_previous=$(( retention - 1 ))
    if (( ${#previous_backups[@]} > keep_previous )); then
      local -a stale=("${previous_backups[@]:$keep_previous}")
      local -i pruned=0 retained=0
      for candidate in "${stale[@]}"; do
        _dev_state_assert_directory_identity \
          "$backup_dir" "backup" "$directory_identity" || return 1
        if ! _dev_state_validate_file \
          "$candidate" "$backup_dir" "backup selected for pruning" legacy \
          2>/dev/null; then
          retained=$(( retained + 1 ))
          _dev_warn "Left an unverified stale backup in place: $candidate"
          continue
        fi
        if ! command rm -f -- "$candidate" 2>/dev/null; then
          retained=$(( retained + 1 ))
          _dev_warn "Could not prune old backup: $candidate"
          continue
        fi
        pruned=$(( pruned + 1 ))
      done
      _dev_debug "Pruned $pruned old backup(s)."
      (( retained == 0 )) || _dev_info \
        "Review $retained retained backup(s) manually under: $backup_dir"
    fi

    _dev_state_assert_directory_identity \
      "$backup_dir" "backup" "$directory_identity" || return 1
    _dev_state_validate_file \
      "$published_file" "$backup_dir" "invocation backup" || return 1
    _DEV_LAST_BACKUP_FILE="$published_file"
    _DEV_LAST_BACKUP_MODE="$source_mode"
    _dev_success "Backup saved: $published_file"
  } always {
    if (( temp_validated )) \
      && [[ -n "$temp_file" && -e "$temp_file" ]]; then
      local cleanup_identity=""
      cleanup_identity=$(
        _dev_temporary_file_identity \
          "$temp_file" "$backup_dir" "backup temporary cleanup"
      ) 2>/dev/null
      if [[ -n "$cleanup_identity" \
        && "$cleanup_identity" == "$temp_identity" ]]; then
        command rm -f -- "$temp_file" 2>/dev/null
      else
        _dev_warn \
          "The backup temporary changed; refusing automatic cleanup: $temp_file"
      fi
    fi
  }
}

# Restores one exact invocation-owned backup. Selecting "the newest" backup is
# intentionally forbidden because concurrent update commands may share a state
# directory.
_dev_restore_pyproject() {
  emulate -L zsh

  local backup_file="${1:-}"
  if [[ -z "$backup_file" ]]; then
    _dev_error "An exact pyproject.toml backup is required for rollback."
    return 1
  fi

  local backup_dir directory_identity
  backup_dir=$(_dev_state_existing "$DEV_BACKUP_DIR" "backup") || {
    _dev_error "The backup directory is unavailable for rollback."
    return 1
  }
  directory_identity=$(
    _dev_state_directory_identity "$backup_dir" "backup"
  ) || return 1
  _dev_state_validate_file \
    "$backup_file" "$backup_dir" "rollback backup" || return 1
  _dev_state_file_fingerprint \
    "$backup_file" "$backup_dir" "rollback backup" || return 1
  local backup_fingerprint="$REPLY"

  local project_root="${PWD:A}"
  local project_identity
  project_identity=$(
    _dev_write_directory_identity "$project_root" "project directory"
  ) || return 1

  local destination="${project_root}/pyproject.toml"
  local destination_identity
  destination_identity=$(
    _dev_owned_file_fingerprint "$destination" "pyproject.toml destination"
  ) || return 1
  local restore_mode="600"
  if [[ "$backup_file" == "$_DEV_LAST_BACKUP_FILE" \
    && "$_DEV_LAST_BACKUP_MODE" == <-> ]]; then
    restore_mode="$_DEV_LAST_BACKUP_MODE"
  elif [[ "$destination_identity" != "absent" ]]; then
    zmodload zsh/stat 2>/dev/null || return 1
    local -A destination_metadata=()
    zstat -H destination_metadata -- "$destination" 2>/dev/null || return 1
    restore_mode=$(printf '%o' $(( destination_metadata[mode] & 8#777 )))
  fi

  local temp_file=""
  temp_file=$(command mktemp \
    "${project_root}/.pyproject.toml.rollback.XXXXXX" 2>/dev/null) || {
    _dev_error "Could not create a temporary rollback file."
    return 1
  }
  local temp_identity=""
  {
    temp_identity=$(
      _dev_temporary_file_identity \
        "$temp_file" "$project_root" "rollback temporary"
    ) || return 1
    command cp -- "$backup_file" "$temp_file" 2>/dev/null || {
      _dev_error "Could not stage pyproject.toml from $backup_file"
      return 1
    }
    local current_project_identity
    current_project_identity=$(
      _dev_write_directory_identity "$project_root" "project directory"
    ) || return 1
    if [[ "$current_project_identity" != "$project_identity" ]]; then
      _dev_error "The project directory changed during rollback."
      return 1
    fi
    _dev_state_assert_directory_identity \
      "$backup_dir" "backup" "$directory_identity" || return 1
    _dev_state_validate_file \
      "$backup_file" "$backup_dir" "rollback backup" || return 1
    _dev_state_file_fingerprint \
      "$backup_file" "$backup_dir" "rollback backup" || return 1
    if [[ "$REPLY" != "$backup_fingerprint" ]]; then
      _dev_error "The rollback backup changed while it was being staged."
      return 1
    fi
    if ! command cmp -s -- "$backup_file" "$temp_file"; then
      _dev_error "The rollback backup changed while it was being staged."
      return 1
    fi
    local current_temp_identity
    current_temp_identity=$(
      _dev_temporary_file_identity \
        "$temp_file" "$project_root" "rollback temporary"
    ) || return 1
    if [[ "$current_temp_identity" != "$temp_identity" ]]; then
      _dev_error "The rollback temporary changed while it was being staged."
      return 1
    fi
    local current_destination_identity
    current_destination_identity=$(
      _dev_owned_file_fingerprint "$destination" "pyproject.toml destination"
    ) || return 1
    if [[ "$current_destination_identity" != "$destination_identity" ]]; then
      _dev_error "pyproject.toml changed while rollback was being staged."
      return 1
    fi

    command chmod "$restore_mode" -- "$temp_file" 2>/dev/null || {
      _dev_error "Could not restore pyproject.toml permissions."
      return 1
    }
    current_temp_identity=$(
      _dev_temporary_file_identity \
        "$temp_file" "$project_root" "rollback temporary" 0
    ) || return 1
    if [[ "$current_temp_identity" != "$temp_identity" ]]; then
      _dev_error "The rollback temporary changed while permissions were applied."
      return 1
    fi

    command mv -f -- "$temp_file" "$destination" 2>/dev/null || {
      _dev_error "Could not restore pyproject.toml from $backup_file"
      return 1
    }
    temp_file=""
    _dev_info "Restored from: $backup_file"
  } always {
    if [[ -n "$temp_file" && ( -e "$temp_file" || -L "$temp_file" ) ]]; then
      local cleanup_identity=""
      cleanup_identity=$(
        _dev_temporary_file_identity \
          "$temp_file" "$project_root" "rollback temporary" 0 2>/dev/null
      )
      if [[ -n "$cleanup_identity" \
        && "$cleanup_identity" == "$temp_identity" ]]; then
        command rm -f -- "$temp_file" 2>/dev/null
      else
        _dev_error \
          "The rollback temporary changed identity; refusing removal."
      fi
    fi
  }
}

typeset -g _DEV_STATE_SOURCED=1
