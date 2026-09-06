#!/usr/bin/env zsh
# =============================================================================
# System Dotfiles: bounded backup and verified restore workflows
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh.
# Safe to re-source; defines functions and configuration defaults only.
#

if [[ -n "${_SYS_DOTS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -ga _SYS_DEFAULT_DOTFILES=(
  "$HOME/.zshrc"
  "$HOME/.zshenv"
  "$HOME/.zprofile"
  "$HOME/.gitconfig"
  "$HOME/.gitignore_global"
  "$HOME/.config/starship.toml"
  "$HOME/.config/bat"
  "$HOME/.config/delta"
  "$HOME/.config/gh/config.yml"
  "$HOME/.p10k.zsh"
  "$HOME/.tmux.conf"
  "$HOME/.config/tmux"
  "$HOME/.vimrc"
  "$HOME/.config/nvim"
  "${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}"
)

typeset -g SYS_DOTFILES_BACKUP_KEEP="${SYS_DOTFILES_BACKUP_KEEP:-10}"
typeset -g SYS_DOTFILES_BACKUP_MAX_BYTES="${SYS_DOTFILES_BACKUP_MAX_BYTES:-536870912}"
typeset -g SYS_DOTFILES_BACKUP_MAX_EXPANDED_BYTES="${SYS_DOTFILES_BACKUP_MAX_EXPANDED_BYTES:-1073741824}"
typeset -g SYS_DOTFILES_BACKUP_MAX_ENTRIES="${SYS_DOTFILES_BACKUP_MAX_ENTRIES:-100000}"
typeset -g SYS_DOTFILES_BACKUP_MAX_MANIFEST_BYTES="${SYS_DOTFILES_BACKUP_MAX_MANIFEST_BYTES:-8388608}"
typeset -g SYS_DOTFILES_BACKUP_MAX_PATH_BYTES="${SYS_DOTFILES_BACKUP_MAX_PATH_BYTES:-4096}"
typeset -g SYS_DOTFILES_RESTORE_MAX_BYTES="${SYS_DOTFILES_RESTORE_MAX_BYTES:-536870912}"
typeset -g SYS_DOTFILES_RESTORE_MAX_EXPANDED_BYTES="${SYS_DOTFILES_RESTORE_MAX_EXPANDED_BYTES:-1073741824}"
typeset -g SYS_DOTFILES_RESTORE_MAX_ENTRIES="${SYS_DOTFILES_RESTORE_MAX_ENTRIES:-100000}"
typeset -g SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES="${SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES:-8388608}"
typeset -g SYS_DOTFILES_RESTORE_MAX_PATH_BYTES="${SYS_DOTFILES_RESTORE_MAX_PATH_BYTES:-4096}"

_sys_dotfiles_usage_backup() {
  print -u2 -r -- \
    'Usage: sys-backup-dots [--dry-run] [-y|--yes] [-h|--help]'
  print -u2 -r -- ''
  print -u2 -r -- 'Creates an owner-only archive, SHA-256 file, and exact manifest.'
  print -u2 -r -- '--yes also permits pruning validated backups beyond the retention limit.'
}

_sys_dotfiles_usage_restore() {
  print -u2 -r -- \
    'Usage: sys-restore-dots [--archive FILE] [--dry-run] [-y|--yes] [-h|--help]'
  print -u2 -r -- ''
  print -u2 -r -- 'Without --archive, select a verified backup interactively with fzf.'
}

_sys_dotfiles_backup_dir() {
  local allow_mutation="${1:-0}"
  local backup_dir="${SYS_DOTFILES_BACKUP_DIR:-$HOME/.dotfiles-backups}"
  local home_abs="${HOME:A}"
  local backup_abs

  [[ "$backup_dir" != *[[:cntrl:]]* && "$backup_dir" != *'|'* ]] || {
    _sys_error "Backup directory contains unsupported characters."
    return 1
  }
  # Normalize trailing slashes so "$HOME/" cannot pass as a directory below
  # HOME, then require an absolute path before any filesystem check.
  while [[ "$backup_dir" != "/" && "$backup_dir" == */ ]]; do
    backup_dir="${backup_dir%/}"
  done
  [[ "$backup_dir" == /* ]] || {
    _sys_error "Backup directory must be an absolute path below HOME."
    return 1
  }
  local parent_abs="${backup_dir:h:A}"
  [[ "$parent_abs" == "$home_abs" || "$parent_abs" == "$home_abs"/* ]] || {
    _sys_error "Dotfile backups must remain below the user home directory."
    return 1
  }

  if [[ -e "$backup_dir" ]]; then
    [[ -d "$backup_dir" && ! -L "$backup_dir" && -O "$backup_dir" ]] || {
      _sys_error "Backup directory must be a user-owned directory, not a link."
      return 1
    }
  else
    if (( ! allow_mutation )); then
      backup_abs="${backup_dir:A}"
      [[ "$backup_abs" == "$home_abs"/* ]] || {
        _sys_error "Dotfile backups must remain below the user home directory."
        return 1
      }
      REPLY="$backup_abs"
      return 0
    fi
    local previous_umask
    previous_umask=$(umask)
    umask 077
    command mkdir -p -- "$backup_dir" 2>/dev/null
    local mkdir_rc=$?
    umask "$previous_umask"
    (( mkdir_rc == 0 )) || {
      _sys_error "Unable to create backup directory: $backup_dir"
      return 1
    }
  fi

  [[ -d "$backup_dir" && ! -L "$backup_dir" && -O "$backup_dir" ]] || {
    _sys_error "Backup directory changed or is no longer user-owned."
    return 1
  }
  if (( allow_mutation )) \
    && ! command chmod 700 -- "$backup_dir" 2>/dev/null; then
    _sys_error "Unable to restrict backup directory permissions: $backup_dir"
    return 1
  fi
  backup_abs="${backup_dir:A}"
  [[ "$backup_abs" == "$home_abs"/* ]] || {
    _sys_error "Dotfile backups must remain below the user home directory."
    return 1
  }
  REPLY="$backup_abs"
}

# Sets reply to safe, existing paths and reply_rel to paths relative to HOME.
_sys_dotfiles_collect() {
  local backup_dir="${1:-}"
  local -a configured=()
  if (( ${+SYS_DOTFILES} )) && (( ${#SYS_DOTFILES[@]} > 0 )); then
    configured=("${SYS_DOTFILES[@]}")
  else
    configured=("${_SYS_DEFAULT_DOTFILES[@]}")
  fi

  local home_abs="${HOME:A}"
  local backup_abs="${backup_dir:+${backup_dir:A}}"
  local configured_path absolute_path relative_path unsafe_path nested_path
  local existing_relative
  local -a safe_paths=() relative_paths=()
  local -a retained_paths=() retained_relative=()
  local -i covered=0 retained_index
  for configured_path in "${configured[@]}"; do
    [[ -n "$configured_path" && "$configured_path" != *[[:cntrl:]]* \
      && "$configured_path" != *'|'* ]] || {
      _sys_warn "Skipping a dotfile path containing unsupported characters."
      continue
    }
    [[ -e "$configured_path" ]] || continue
    [[ ! -L "$configured_path" ]] || {
      _sys_warn "Skipping symbolic link: ${configured_path/#$HOME/~}"
      continue
    }

    absolute_path="${configured_path:A}"
    [[ "$absolute_path" == "$home_abs"/* ]] || {
      _sys_warn "Skipping path outside HOME: $(_sys_display_escape "$configured_path")"
      continue
    }
    if [[ -n "$backup_abs" && ( "$absolute_path" == "$backup_abs" \
      || "$absolute_path" == "$backup_abs"/* \
      || "$backup_abs" == "$absolute_path"/* ) ]]; then
      _sys_warn "Skipping a dotfile root that overlaps the backup directory: ${absolute_path/#$HOME/~}"
      continue
    fi

    if [[ -d "$absolute_path" ]]; then
      unsafe_path=$(command find "$absolute_path" -type l -print -quit 2>/dev/null) \
        || unsafe_path=$'\1scan-failed'
      if [[ -z "$unsafe_path" ]]; then
        while IFS= read -r -d $'\0' nested_path; do
          if [[ "$nested_path" == *[[:cntrl:]]* \
            || "$nested_path" == *'|'* ]]; then
            unsafe_path="$nested_path"
            break
          fi
        done < <(
          command find "$absolute_path" -print0 2>/dev/null \
            || printf '%s\0' $'\1scan-failed'
        )
      fi
      if [[ -n "$unsafe_path" ]]; then
        _sys_warn "Skipping directory containing a link or unsafe filename: ${absolute_path/#$HOME/~}"
        continue
      fi
    fi

    relative_path="${absolute_path#$home_abs/}"
    [[ -n "$relative_path" && "$relative_path" != -* ]] || {
      _sys_warn "Skipping unsupported archive path: $(_sys_display_escape "$relative_path")"
      continue
    }

    covered=0
    for existing_relative in "${relative_paths[@]}"; do
      if [[ "$relative_path" == "$existing_relative" \
        || "$relative_path" == "$existing_relative"/* ]]; then
        covered=1
        break
      fi
    done
    (( covered )) && continue

    retained_paths=()
    retained_relative=()
    for (( retained_index = 1; retained_index <= ${#relative_paths[@]}; retained_index++ )); do
      [[ "${relative_paths[retained_index]}" == "$relative_path"/* ]] || {
        retained_paths+=("${safe_paths[retained_index]}")
        retained_relative+=("${relative_paths[retained_index]}")
      }
    done
    safe_paths=("${retained_paths[@]}")
    relative_paths=("${retained_relative[@]}")
    safe_paths+=("$absolute_path")
    relative_paths+=("$relative_path")
  done

  reply=("${safe_paths[@]}")
  reply_rel=("${relative_paths[@]}")
}

_sys_dotfiles_validate_backup_limits() {
  [[ "$SYS_DOTFILES_BACKUP_MAX_BYTES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_BACKUP_MAX_BYTES" != 0[0-9]* \
    && ${#SYS_DOTFILES_BACKUP_MAX_BYTES} -le 10 \
    && "$SYS_DOTFILES_BACKUP_MAX_BYTES" -gt 0 \
    && "$SYS_DOTFILES_BACKUP_MAX_EXPANDED_BYTES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_BACKUP_MAX_EXPANDED_BYTES" != 0[0-9]* \
    && ${#SYS_DOTFILES_BACKUP_MAX_EXPANDED_BYTES} -le 10 \
    && "$SYS_DOTFILES_BACKUP_MAX_EXPANDED_BYTES" -gt 0 \
    && "$SYS_DOTFILES_BACKUP_MAX_ENTRIES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_BACKUP_MAX_ENTRIES" != 0[0-9]* \
    && ${#SYS_DOTFILES_BACKUP_MAX_ENTRIES} -le 7 \
    && "$SYS_DOTFILES_BACKUP_MAX_ENTRIES" -gt 0 \
    && "$SYS_DOTFILES_BACKUP_MAX_ENTRIES" -le 1000000 \
    && "$SYS_DOTFILES_BACKUP_MAX_MANIFEST_BYTES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_BACKUP_MAX_MANIFEST_BYTES" != 0[0-9]* \
    && ${#SYS_DOTFILES_BACKUP_MAX_MANIFEST_BYTES} -le 8 \
    && "$SYS_DOTFILES_BACKUP_MAX_MANIFEST_BYTES" -gt 0 \
    && "$SYS_DOTFILES_BACKUP_MAX_MANIFEST_BYTES" -le 67108864 \
    && "$SYS_DOTFILES_BACKUP_MAX_PATH_BYTES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_BACKUP_MAX_PATH_BYTES" != 0[0-9]* \
    && ${#SYS_DOTFILES_BACKUP_MAX_PATH_BYTES} -le 5 \
    && "$SYS_DOTFILES_BACKUP_MAX_PATH_BYTES" -gt 0 \
    && "$SYS_DOTFILES_BACKUP_MAX_PATH_BYTES" -le 65535 ]] || {
    _sys_error "Dotfile backup limits must be positive bounded integers."
    return 1
  }
}

_sys_dotfiles_preflight_backup() {
  local LC_ALL=C
  local -a backup_roots=("$@")
  (( ${#backup_roots[@]} > 0 )) || return 1
  local scanned_entry relative_entry component
  local home_abs="${HOME:A}"
  local -A entry_state=()
  local -i entry_count=0 expanded_bytes=0

  while IFS= read -r -d $'\0' scanned_entry; do
    (( ++entry_count <= SYS_DOTFILES_BACKUP_MAX_ENTRIES )) || {
      _sys_error "Dotfile backup entry count exceeds its configured limit."
      return 1
    }
    [[ "$scanned_entry" == "$home_abs"/* \
      && "$scanned_entry" != *[[:cntrl:]]* \
      && "$scanned_entry" != *'|'* \
      && ! -L "$scanned_entry" && -O "$scanned_entry" ]] || {
      _sys_error "Dotfile backup contains an unsafe, linked, or non-owned entry."
      return 1
    }
    relative_entry="${scanned_entry#$home_abs/}"
    [[ -n "$relative_entry" \
      && ${#relative_entry} -le SYS_DOTFILES_BACKUP_MAX_PATH_BYTES ]] || {
      _sys_error "Dotfile backup contains an oversized path."
      return 1
    }
    for component in "${(@s:/:)relative_entry}"; do
      [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
        || return 1
    done

    if [[ -d "$scanned_entry" ]]; then
      continue
    elif [[ ! -f "$scanned_entry" ]]; then
      _sys_error "Dotfile backup contains a special file."
      return 1
    fi
    entry_state=()
    zmodload zsh/stat 2>/dev/null \
      && zstat -H entry_state "$scanned_entry" 2>/dev/null || return 1
    (( entry_state[nlink] == 1 )) || {
      _sys_error "Dotfile backup contains a multiply-linked file."
      return 1
    }
    (( entry_state[size] >= 0 \
      && entry_state[size] \
        <= SYS_DOTFILES_BACKUP_MAX_EXPANDED_BYTES - expanded_bytes )) || {
      _sys_error "Dotfile backup content exceeds its configured size limit."
      return 1
    }
    (( expanded_bytes += entry_state[size] ))
  done < <(
    command find "${backup_roots[@]}" -print0 2>/dev/null \
      || printf '%s\0' $'\1scan-failed'
  )
  (( entry_count > 0 ))
}

_sys_dotfiles_validate_member_types() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local archive="$1"
  local max_listing_bytes="${2:-${SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES:-8388608}}"
  [[ "$max_listing_bytes" =~ '^[0-9]+$' \
    && ${#max_listing_bytes} -le 8 \
    && "$max_listing_bytes" -gt 0 ]] || max_listing_bytes=8388608

  LC_ALL=C _sys_run_with_timeout 120 tar -tvzf "$archive" 2>/dev/null \
    | command awk -v max_bytes="$max_listing_bytes" '
      BEGIN { bytes = 0; entries = 0 }
      {
        bytes += length($0) + 1
        if (bytes > max_bytes) exit 42
        type = substr($0, 1, 1)
        if (type != "-" && type != "d") exit 41
        entries++
      }
      END { if (entries == 0) exit 43 }
    ' || {
      _sys_error "Archive type listing is unsafe, empty, or exceeds its limit."
      return 1
    }
}

_sys_dotfiles_create_archive() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local archive="$1"
  shift
  local -a relative_paths=("$@")
  local -a source_paths=()
  local relative_path
  for relative_path in "${relative_paths[@]}"; do
    [[ -n "$relative_path" && "$relative_path" != /* \
      && "$relative_path" != -* && "$relative_path" != *[[:cntrl:]]* \
      && "$relative_path" != *'|'* ]] || return 1
    # Preflight compares scanned entries against the canonical home, so the
    # roots must be canonical too; a HOME reached through a symbolic link
    # would otherwise fail its own safety check.
    source_paths+=("${HOME:A}/$relative_path")
  done
  _sys_dotfiles_validate_backup_limits || return 1
  _sys_dotfiles_preflight_backup "${source_paths[@]}" || return 1

  local archive_dir="${archive:h}"
  local temporary_archive
  temporary_archive=$(command mktemp "$archive_dir/.dotfiles.tar.gz.XXXXXX") \
    || return 1
  local temporary_manifest="${temporary_archive}.manifest"
  local temporary_checksum="${temporary_archive}.sha256"
  local create_rc=0 digest=""
  local previous_umask
  previous_umask=$(umask)

  {
    umask 077
    [[ ! -e "$archive" && ! -e "${archive}.manifest" \
      && ! -e "${archive}.sha256" ]] || return 1
    command tar -czf - -C "$HOME" -- "${relative_paths[@]}" 2>/dev/null \
      | command head -c "$(( SYS_DOTFILES_BACKUP_MAX_BYTES + 1 ))" \
        > "$temporary_archive"
    local archive_pipeline_rc=$?
    local archive_bytes
    archive_bytes=$(command wc -c < "$temporary_archive" 2>/dev/null) \
      || return 1
    archive_bytes="${archive_bytes//[[:space:]]/}"
    [[ "$archive_bytes" =~ '^[0-9]+$' \
      && "$archive_bytes" -le "$SYS_DOTFILES_BACKUP_MAX_BYTES" ]] || {
        _sys_error "Compressed dotfile backup exceeds its configured limit."
        return 1
      }
    (( archive_pipeline_rc == 0 )) || return 1
    command chmod 600 "$temporary_archive" 2>/dev/null || return 1
    _sys_dotfiles_validate_member_types "$temporary_archive" \
      "$SYS_DOTFILES_BACKUP_MAX_MANIFEST_BYTES" || return 1

    local REPLY
    _sys_tar_measure_expanded_bytes "$temporary_archive" \
      "$SYS_DOTFILES_BACKUP_MAX_EXPANDED_BYTES" gzip
    case $? in
      0) ;;
      2)
        _sys_error "Expanded dotfile backup exceeds its configured limit."
        return 1
        ;;
      *)
        _sys_error "Unable to inspect the expanded dotfile backup safely."
        return 1
        ;;
    esac

    LC_ALL=C _sys_run_with_timeout 120 tar -tzf "$temporary_archive" \
      2>/dev/null \
      | command awk \
        -v max_bytes="$SYS_DOTFILES_BACKUP_MAX_MANIFEST_BYTES" \
        -v max_entries="$SYS_DOTFILES_BACKUP_MAX_ENTRIES" '
          BEGIN { bytes = 0; entries = 0 }
          {
            bytes += length($0) + 1
            entries++
            if (bytes > max_bytes || entries > max_entries) exit 42
            print
          }
          END { if (entries == 0) exit 43 }
        ' > "$temporary_manifest" || {
          _sys_error "Dotfile backup manifest exceeds its configured limit."
          return 1
        }
    command chmod 600 "$temporary_manifest" 2>/dev/null || return 1
    digest=$(_sys_sha256_file "$temporary_archive") || return 1
    print -r -- "$digest" > "$temporary_checksum" || return 1
    command chmod 600 "$temporary_checksum" 2>/dev/null || return 1

    # Publish metadata first and the archive last. The archive name is the
    # transaction's visibility marker, so an interrupted publish is ignored.
    command mv "$temporary_manifest" "${archive}.manifest" 2>/dev/null \
      || return 1
    temporary_manifest=""
    command mv "$temporary_checksum" "${archive}.sha256" 2>/dev/null \
      || return 1
    temporary_checksum=""
    command mv "$temporary_archive" "$archive" 2>/dev/null || return 1
    temporary_archive=""
  } always {
    create_rc=$?
    [[ -n "$temporary_archive" && -f "$temporary_archive" ]] \
      && command rm -f "$temporary_archive" 2>/dev/null
    [[ -n "$temporary_manifest" && -f "$temporary_manifest" ]] \
      && command rm -f "$temporary_manifest" 2>/dev/null
    [[ -n "$temporary_checksum" && -f "$temporary_checksum" ]] \
      && command rm -f "$temporary_checksum" 2>/dev/null
    if (( create_rc != 0 )) && [[ ! -e "$archive" ]]; then
      command rm -f "${archive}.manifest" "${archive}.sha256" 2>/dev/null
    fi
    umask "$previous_umask"
  }

  return $create_rc
}

_sys_dotfiles_prune() {
  local backup_dir="$1"
  local assume_yes="$2"
  [[ "$SYS_DOTFILES_BACKUP_KEEP" =~ '^[0-9]+$' ]] \
    && (( SYS_DOTFILES_BACKUP_KEEP > 0 )) || {
      _sys_error "SYS_DOTFILES_BACKUP_KEEP must be a positive integer."
      return 1
    }

  local -a candidates=(
    "$backup_dir"/dotfiles_<->_<->*.tar.gz(N.om)
  )
  local -a archives=()
  local candidate
  for candidate in "${candidates[@]}"; do
    [[ "${candidate:t}" =~ '^dotfiles_[0-9]{8}_[0-9]{6}(_pre-restore)?\.tar\.gz$' ]] \
      && archives+=("$candidate")
  done
  local -i remove_count=$(( ${#archives[@]} - SYS_DOTFILES_BACKUP_KEEP ))
  (( remove_count > 0 )) || return 0
  local -a remove_archives=("${archives[@]:$SYS_DOTFILES_BACKUP_KEEP}")

  _sys_warn "Retention plan: remove $remove_count old backup(s)."
  local old_archive
  for old_archive in "${remove_archives[@]}"; do
    _sys_dim "${old_archive:t}"
  done

  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]] \
      || ! _sys_confirm "Remove these validated old backups?"; then
      _sys_info "Old backups were retained."
      return 0
    fi
  fi

  local backup_abs="${backup_dir:A}"
  local target_abs
  local -i failures=0
  for old_archive in "${remove_archives[@]}"; do
    target_abs="${old_archive:A}"
    if [[ "$target_abs" != "$backup_abs"/* || ! -f "$old_archive" \
      || -L "$old_archive" || ! -O "$old_archive" ]]; then
      _sys_error "Refusing unsafe retention target: $(_sys_display_escape "$old_archive")"
      (( failures++ ))
      continue
    fi
    command rm -f "$old_archive" "${old_archive}.manifest" \
      "${old_archive}.sha256" 2>/dev/null || (( failures++ ))
  done
  (( failures == 0 ))
}

sys-backup-dots() {
  local -i dry_run=0 assume_yes=0
  local REPLY
  local -a reply=() reply_rel=()
  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! dry_run && ! assume_yes )) || {
          _sys_error "--help does not accept additional arguments."
          return 2
        }
        _sys_dotfiles_usage_backup
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      -y|--yes)  assume_yes=1 ;;
      *)
        _sys_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  _sys_require_commands tar || return 1
  _sys_require_sha256_tool || return 1
  local backup_dir
  _sys_dotfiles_backup_dir "$(( ! dry_run ))" || return 1
  backup_dir="$REPLY"
  _sys_dotfiles_collect "$backup_dir"
  local -a existing_files=("${reply[@]}")
  local -a relative_paths=("${reply_rel[@]}")
  if (( ${#existing_files[@]} == 0 )); then
    _sys_warn "No safe dotfiles were found to back up."
    return 0
  fi
  _sys_dotfiles_validate_backup_limits || return 1
  _sys_dotfiles_preflight_backup "${existing_files[@]}" || return 1

  _sys_header "Dotfile Backup Plan"
  _sys_warn "Backups may contain credentials or authentication configuration."
  _sys_info "Destination: $backup_dir"
  _sys_info "Validated roots: ${#existing_files[@]}"
  local display_path
  for display_path in "${existing_files[@]}"; do
    _sys_dim "${display_path/#$HOME/~}"
  done
  (( dry_run )) && {
    _sys_info "Dry run complete; no archive was created."
    return 0
  }

  local timestamp
  timestamp=$(command date +%Y%m%d_%H%M%S 2>/dev/null) || return 1
  local archive="$backup_dir/dotfiles_${timestamp}.tar.gz"
  [[ ! -e "$archive" ]] || {
    _sys_error "Backup target already exists: $archive"
    return 1
  }

  _sys_dotfiles_create_archive "$archive" "${relative_paths[@]}" || {
    _sys_error "Failed to create the verified dotfile backup."
    return 1
  }
  local archive_size
  archive_size=$(command du -h "$archive" 2>/dev/null)
  archive_size="${archive_size%%[[:space:]]*}"
  _sys_success "Backup created: $archive (${archive_size:-unknown})"
  _sys_dotfiles_prune "$backup_dir" "$assume_yes" || return 1
}

_sys_dotfiles_archive_identity() {
  local archive="$1"
  local -A archive_state=()
  zmodload zsh/stat 2>/dev/null && zstat -H archive_state "$archive" 2>/dev/null \
    || return 1
  REPLY="${archive_state[device]}:${archive_state[inode]}:${archive_state[size]}:${archive_state[mtime]}"
}

_sys_dotfiles_private_file() {
  local candidate_file="$1"
  local -A file_state=()
  [[ -f "$candidate_file" && ! -L "$candidate_file" \
    && -O "$candidate_file" ]] || return 1
  zmodload zsh/stat 2>/dev/null \
    && zstat -H file_state "$candidate_file" 2>/dev/null \
    || return 1
  (( (file_state[mode] & 8#77) == 0 ))
}

_sys_dotfiles_validate_archive() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local archive="$1"
  local backup_dir="$2"
  local backup_abs="${backup_dir:A}"
  local archive_abs="${archive:A}"
  local manifest_file="${archive}.manifest"
  local checksum_file="${archive}.sha256"

  [[ "${archive:h:A}" == "$backup_abs" \
    && "${archive:t}" =~ '^dotfiles_[0-9]{8}_[0-9]{6}(_pre-restore)?\.tar\.gz$' \
    && "$archive_abs" == "$backup_abs"/* ]] \
    && _sys_dotfiles_private_file "$archive" || {
      _sys_error "Archive must be an owner-only regular file below the backup directory."
      return 1
    }
  _sys_dotfiles_private_file "$manifest_file" \
    && _sys_dotfiles_private_file "$checksum_file" || {
      _sys_error "Archive manifest or checksum is missing or unsafe."
      return 1
    }
  [[ "$SYS_DOTFILES_RESTORE_MAX_BYTES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_RESTORE_MAX_BYTES" != 0[0-9]* \
    && "$SYS_DOTFILES_RESTORE_MAX_EXPANDED_BYTES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_RESTORE_MAX_EXPANDED_BYTES" != 0[0-9]* \
    && "$SYS_DOTFILES_RESTORE_MAX_ENTRIES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_RESTORE_MAX_ENTRIES" != 0[0-9]* \
    && "$SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES" != 0[0-9]* \
    && "$SYS_DOTFILES_RESTORE_MAX_PATH_BYTES" =~ '^[0-9]+$' \
    && "$SYS_DOTFILES_RESTORE_MAX_PATH_BYTES" != 0[0-9]* \
    && ${#SYS_DOTFILES_RESTORE_MAX_BYTES} -le 10 \
    && ${#SYS_DOTFILES_RESTORE_MAX_EXPANDED_BYTES} -le 10 \
    && ${#SYS_DOTFILES_RESTORE_MAX_ENTRIES} -le 7 \
    && ${#SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES} -le 8 \
    && ${#SYS_DOTFILES_RESTORE_MAX_PATH_BYTES} -le 5 \
    && "$SYS_DOTFILES_RESTORE_MAX_BYTES" -gt 0 \
    && "$SYS_DOTFILES_RESTORE_MAX_EXPANDED_BYTES" -gt 0 \
    && "$SYS_DOTFILES_RESTORE_MAX_ENTRIES" -gt 0 \
    && "$SYS_DOTFILES_RESTORE_MAX_ENTRIES" -le 1000000 \
    && "$SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES" -gt 0 \
    && "$SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES" -le 67108864 \
    && "$SYS_DOTFILES_RESTORE_MAX_PATH_BYTES" -gt 0 \
    && "$SYS_DOTFILES_RESTORE_MAX_PATH_BYTES" -le 65535 ]] || {
      _sys_error "Dotfile restore limits must be positive integers."
      return 1
    }

  local archive_bytes
  archive_bytes=$(command wc -c < "$archive" 2>/dev/null) || return 1
  archive_bytes="${archive_bytes//[[:space:]]/}"
  [[ "$archive_bytes" =~ '^[0-9]+$' && ${#archive_bytes} -le 10 ]] \
    && (( archive_bytes <= SYS_DOTFILES_RESTORE_MAX_BYTES )) || {
      _sys_error "Archive exceeds the configured restore size limit."
      return 1
    }

  local expected_digest="" actual_digest
  # A sidecar without a trailing newline still yields its digest; read only
  # reports the missing terminator.
  read -r expected_digest < "$checksum_file" || [[ -n "$expected_digest" ]] || {
    _sys_error "Archive checksum file is unreadable."
    return 1
  }
  [[ "$expected_digest" =~ '^[[:xdigit:]]{64}$' ]] || {
    _sys_error "Archive checksum file is malformed."
    return 1
  }
  actual_digest=$(_sys_sha256_file "$archive") || return 1
  [[ "${expected_digest:l}" == "$actual_digest" ]] || {
    _sys_error "Archive checksum verification failed."
    return 1
  }

  local manifest_bytes
  manifest_bytes=$(command wc -c < "$manifest_file" 2>/dev/null) || return 1
  manifest_bytes="${manifest_bytes//[[:space:]]/}"
  [[ "$manifest_bytes" =~ '^[0-9]+$' \
    && ${#manifest_bytes} -le 8 \
    && "$manifest_bytes" -gt 0 \
    && "$manifest_bytes" -le "$SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES" ]] \
    || {
      _sys_error "Archive manifest is empty or exceeds its configured limit."
      return 1
    }

  local current_manifest
  current_manifest=$(
    command mktemp "${TMPDIR:-/tmp}/zdx-dotfiles-manifest.XXXXXX"
  ) || return 1
  command chmod 600 "$current_manifest" 2>/dev/null || {
    command rm -f "$current_manifest" 2>/dev/null
    return 1
  }
  local manifest_rc=0
  {
    LC_ALL=C _sys_run_with_timeout 120 tar -tzf "$archive" 2>/dev/null \
      | command awk -v max_bytes="$SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES" '
        BEGIN { bytes = 0 }
        {
          bytes += length($0) + 1
          if (bytes > max_bytes) exit 42
          print
        }
      ' > "$current_manifest" || {
        _sys_error "Archive listing failed or exceeds its configured limit."
        return 1
      }
    command cmp -s "$manifest_file" "$current_manifest" || {
      _sys_error "Archive contents no longer match the recorded manifest."
      return 1
    }

    local -a entries=("${(@f)$(<"$current_manifest")}")
    (( ${#entries[@]} > 0 \
      && ${#entries[@]} <= SYS_DOTFILES_RESTORE_MAX_ENTRIES )) || {
      _sys_error "Archive entry count is empty or exceeds the configured limit."
      return 1
    }

    local entry normalized component
    local -a components=()
    for entry in "${entries[@]}"; do
      normalized="${entry%/}"
      [[ -n "$normalized" && "$normalized" != /* \
        && "$normalized" != -* && "$normalized" != *[[:cntrl:]]* \
        && "$normalized" != *'|'* \
        && ${#normalized} -le SYS_DOTFILES_RESTORE_MAX_PATH_BYTES ]] || {
        _sys_error "Archive contains an unsafe path."
        return 1
      }
      components=("${(@s:/:)normalized}")
      for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
          || {
            _sys_error "Archive contains path traversal."
            return 1
          }
      done
    done

    _sys_dotfiles_validate_member_types "$archive" || return 1

    local REPLY
    _sys_tar_measure_expanded_bytes "$archive" \
      "$SYS_DOTFILES_RESTORE_MAX_EXPANDED_BYTES" gzip
    case $? in
      0) ;;
      2)
        _sys_error "Expanded archive data exceeds the configured restore limit."
        return 1
        ;;
      *)
        _sys_error "Unable to inspect the expanded archive within the time limit."
        return 1
        ;;
    esac

    reply=("${entries[@]}")
  } always {
    manifest_rc=$?
    command rm -f "$current_manifest" 2>/dev/null
  }
  return $manifest_rc
}

_sys_dotfiles_validate_destination() {
  local relative_entry="$1"
  local expected_type="${2:-either}"
  local normalized="${relative_entry%/}"
  local home_abs="${HOME:A}"
  local current="$home_abs"
  local -a components=("${(@s:/:)normalized}")
  local component
  local -i component_index

  [[ -d "$HOME" && ! -L "$HOME" && -O "$HOME" ]] || {
    _sys_error "HOME must be a user-owned directory, not a link."
    return 1
  }

  for (( component_index = 1; component_index <= ${#components[@]}; component_index++ )); do
    component="${components[component_index]}"
    current+="/$component"
    if [[ -L "$current" ]]; then
      _sys_error "Restore target crosses an existing symbolic link: ${current/#$HOME/~}"
      return 1
    fi
    [[ -e "$current" ]] || continue
    [[ -O "$current" && "${current:A}" == "$home_abs"/* ]] || {
      _sys_error "Restore target is not a user-owned path below HOME: ${current/#$HOME/~}"
      return 1
    }

    if (( component_index < ${#components[@]} )); then
      [[ -d "$current" ]] || {
        _sys_error "Restore target crosses a non-directory path: ${current/#$HOME/~}"
        return 1
      }
      continue
    fi

    case "$expected_type" in
      directory)
        [[ -d "$current" ]] || {
          _sys_error "Restore would replace a non-directory with a directory: ${current/#$HOME/~}"
          return 1
        }
        ;;
      file)
        [[ -f "$current" ]] || {
          _sys_error "Restore would replace a non-file with a file: ${current/#$HOME/~}"
          return 1
        }
        local -A destination_state=()
        zmodload zsh/stat 2>/dev/null \
          && zstat -H destination_state "$current" 2>/dev/null || return 1
        (( destination_state[nlink] == 1 )) || {
          _sys_error "Restore refuses a multiply-linked destination: ${current/#$HOME/~}"
          return 1
        }
        ;;
      either) ;;
      *) return 1 ;;
    esac
  done
}

# Inspects names and object types as they actually exist after extraction.
# Tar's textual listing escapes some control characters, so it is not a
# sufficient publication boundary by itself.
_sys_dotfiles_inspect_staging() {
  local LC_ALL=C
  local staging_dir="$1"
  local backup_dir="$2"
  shift 2
  local -a manifest_entries=("$@")
  (( ${#manifest_entries[@]} > 0 \
    && ${#manifest_entries[@]} <= SYS_DOTFILES_RESTORE_MAX_ENTRIES )) \
    || return 2
  local -A expected_paths=()
  local manifest_entry normalized_manifest parent_manifest
  local -i expected_count=0
  for manifest_entry in "${manifest_entries[@]}"; do
    normalized_manifest="${manifest_entry%/}"
    [[ -n "$normalized_manifest" ]] || return 2
    if (( ! ${+expected_paths[$normalized_manifest]} )); then
      expected_paths[$normalized_manifest]=1
      (( ++expected_count <= SYS_DOTFILES_RESTORE_MAX_ENTRIES )) || {
        _sys_error "Restore manifest and its implied directories exceed the configured entry limit."
        return 1
      }
    fi
    parent_manifest="${normalized_manifest:h}"
    while [[ "$parent_manifest" != "." ]]; do
      if (( ! ${+expected_paths[$parent_manifest]} )); then
        expected_paths[$parent_manifest]=1
        (( ++expected_count <= SYS_DOTFILES_RESTORE_MAX_ENTRIES )) || {
          _sys_error "Restore manifest and its implied directories exceed the configured entry limit."
          return 1
        }
      fi
      parent_manifest="${parent_manifest:h}"
    done
  done
  local staging_abs="${staging_dir:A}"
  local backup_abs="${backup_dir:A}"
  local home_abs="${HOME:A}"
  local inventory_file
  inventory_file=$(command mktemp "${TMPDIR:-/tmp}/zdx-dotfiles-inventory.XXXXXX") \
    || return 1
  command chmod 600 "$inventory_file" 2>/dev/null || {
    command rm -f "$inventory_file" 2>/dev/null
    return 1
  }

  local inspect_rc=0
  {
    command find "$staging_dir" -mindepth 1 -print0 > "$inventory_file" \
      2>/dev/null || {
        _sys_error "Unable to inspect the extracted restore tree."
        return 1
      }
    local inventory_bytes
    inventory_bytes=$(command wc -c < "$inventory_file" 2>/dev/null) \
      || return 1
    inventory_bytes="${inventory_bytes//[[:space:]]/}"
    [[ "$inventory_bytes" =~ '^[0-9]+$' \
      && "$inventory_bytes" -gt 0 \
      && "$inventory_bytes" -le "$SYS_DOTFILES_RESTORE_MAX_MANIFEST_BYTES" ]] \
      || {
        _sys_error "Extracted path inventory is empty or exceeds its limit."
        return 1
      }

    local -a inspected_entries=() inspected_dirs=() inspected_files=()
    local staged_entry relative_entry destination_abs component
    local -a components=()
    local -A staged_state=()
    local -i entry_count=0
    while IFS= read -r -d $'\0' staged_entry; do
      (( ++entry_count <= SYS_DOTFILES_RESTORE_MAX_ENTRIES )) || {
        _sys_error "Extracted entry count exceeds the configured limit."
        return 1
      }
      [[ "$staged_entry" == "$staging_abs"/* ]] || return 1
      relative_entry="${staged_entry#$staging_abs/}"
      [[ -n "$relative_entry" && "$relative_entry" != /* \
        && "$relative_entry" != -* \
        && "$relative_entry" != *[[:cntrl:]]* \
        && "$relative_entry" != *'|'* \
        && ${#relative_entry} -le SYS_DOTFILES_RESTORE_MAX_PATH_BYTES ]] \
        || {
          _sys_error "Extracted archive contains an unsafe filename."
          return 1
        }
      (( ${+expected_paths[$relative_entry]} )) || {
        _sys_error "Extracted archive contains an entry absent from its manifest."
        return 1
      }
      components=("${(@s:/:)relative_entry}")
      for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
          || {
            _sys_error "Extracted archive contains path traversal."
            return 1
          }
      done

      destination_abs="$home_abs/$relative_entry"
      if [[ "$destination_abs" == "$backup_abs" \
        || "$destination_abs" == "$backup_abs"/* \
        || "$backup_abs" == "$destination_abs"/* ]]; then
        _sys_error "Restore entries may not overlap the backup directory."
        return 1
      fi
      [[ ! -L "$staged_entry" && -O "$staged_entry" ]] || {
        _sys_error "Extracted archive contains a link or foreign-owned entry."
        return 1
      }
      if [[ -d "$staged_entry" ]]; then
        inspected_dirs+=("$relative_entry")
      elif [[ -f "$staged_entry" ]]; then
        staged_state=()
        zmodload zsh/stat 2>/dev/null \
          && zstat -H staged_state "$staged_entry" 2>/dev/null || return 1
        (( staged_state[nlink] == 1 )) || {
          _sys_error "Extracted archive contains a multiply-linked file."
          return 1
        }
        inspected_files+=("$relative_entry")
      else
        _sys_error "Extracted archive contains a special file."
        return 1
      fi
      inspected_entries+=("$relative_entry")
    done < "$inventory_file"

    (( entry_count == expected_count )) || {
      _sys_error \
        "Extracted entry count does not match the verified archive manifest."
      return 1
    }
    reply=("${inspected_entries[@]}")
    reply_dirs=("${inspected_dirs[@]}")
    reply_files=("${inspected_files[@]}")
  } always {
    inspect_rc=$?
    command rm -f "$inventory_file" 2>/dev/null
  }
  return $inspect_rc
}

_sys_dotfiles_prepare_home_directory() {
  local relative_dir="$1"
  local home_abs="${HOME:A}"
  local current="$home_abs"
  local component
  local -a components=()
  [[ -n "$relative_dir" && "$relative_dir" != "." ]] \
    && components=("${(@s:/:)relative_dir}")

  [[ -d "$HOME" && ! -L "$HOME" && -O "$HOME" ]] || return 1
  for component in "${components[@]}"; do
    current+="/$component"
    if [[ -e "$current" || -L "$current" ]]; then
      [[ -d "$current" && ! -L "$current" && -O "$current" \
        && "${current:A}" == "$home_abs"/* ]] || {
        _sys_error "Unsafe restore parent: ${current/#$HOME/~}"
        return 1
      }
      continue
    fi
    command mkdir -m 700 "$current" 2>/dev/null || return 1
    [[ -d "$current" && ! -L "$current" && -O "$current" \
      && "${current:A}" == "$home_abs"/* ]] || return 1
  done
}

_sys_dotfiles_publish_staging() {
  local staging_dir="$1"
  local backup_dir="$2"
  shift 2
  local -a manifest_entries=("$@")
  local -a reply=() reply_dirs=() reply_files=()
  _sys_dotfiles_inspect_staging "$staging_dir" "$backup_dir" \
    "${manifest_entries[@]}" || return 1
  local -a staged_dirs=("${reply_dirs[@]}")
  local -a staged_files=("${reply_files[@]}")
  local relative_entry parent_relative source_file destination_file
  local parent_dir temporary_file=""
  local publish_rc=0
  local -A source_before=() source_after=() temporary_state=()
  local -A published_state=()

  {
    for relative_entry in "${staged_dirs[@]}"; do
      _sys_dotfiles_prepare_home_directory "$relative_entry" || return 1
      _sys_dotfiles_validate_destination "$relative_entry" directory \
        || return 1
    done

    for relative_entry in "${staged_files[@]}"; do
      parent_relative="${relative_entry:h}"
      [[ "$parent_relative" == "." ]] && parent_relative=""
      _sys_dotfiles_prepare_home_directory "$parent_relative" || return 1
      _sys_dotfiles_validate_destination "$relative_entry" file || return 1

      source_file="$staging_dir/$relative_entry"
      parent_dir="$HOME${parent_relative:+/$parent_relative}"
      destination_file="$HOME/$relative_entry"
      [[ -f "$source_file" && ! -L "$source_file" && -O "$source_file" ]] \
        || return 1
      source_before=()
      zmodload zsh/stat 2>/dev/null \
        && zstat -H source_before "$source_file" 2>/dev/null || return 1
      (( source_before[nlink] == 1 )) || return 1
      temporary_file=$(command mktemp "$parent_dir/.zdx-restore.XXXXXX") \
        || return 1
      command chmod 600 "$temporary_file" 2>/dev/null || return 1
      command cp -p "$source_file" "$temporary_file" 2>/dev/null \
        || return 1
      [[ -f "$source_file" && ! -L "$source_file" && -O "$source_file" \
        && -f "$temporary_file" && ! -L "$temporary_file" \
        && -O "$temporary_file" ]] || return 1
      source_after=()
      temporary_state=()
      zstat -H source_after "$source_file" 2>/dev/null \
        && zstat -H temporary_state "$temporary_file" 2>/dev/null \
        || return 1
      [[ "${source_after[device]}:${source_after[inode]}:${source_after[size]}:${source_after[mtime]}:${source_after[ctime]}:${source_after[mode]}" \
        == "${source_before[device]}:${source_before[inode]}:${source_before[size]}:${source_before[mtime]}:${source_before[ctime]}:${source_before[mode]}" ]] \
        && (( source_after[nlink] == 1 && temporary_state[nlink] == 1 )) \
        && command cmp -s "$source_file" "$temporary_file" || {
          _sys_error "Restore source changed while it was being staged."
          return 1
        }

      # Revalidate after copying and immediately before the atomic rename.
      _sys_dotfiles_prepare_home_directory "$parent_relative" || return 1
      _sys_dotfiles_validate_destination "$relative_entry" file || return 1
      [[ "${parent_dir:A}" == "${HOME:A}" \
        || "${parent_dir:A}" == "${HOME:A}"/* ]] || return 1
      command mv -f "$temporary_file" "$destination_file" 2>/dev/null \
        || return 1
      temporary_file=""
      [[ -f "$destination_file" && ! -L "$destination_file" \
        && -O "$destination_file" ]] || return 1
      published_state=()
      zstat -H published_state "$destination_file" 2>/dev/null || return 1
      (( published_state[nlink] == 1 )) || return 1
    done
  } always {
    publish_rc=$?
    [[ -n "$temporary_file" \
      && ( -e "$temporary_file" || -L "$temporary_file" ) ]] \
      && command rm -f -- "$temporary_file" 2>/dev/null
  }
  return $publish_rc
}

_sys_dotfiles_select_archive() {
  local backup_dir="$1"
  command -v fzf &>/dev/null || {
    _sys_error "fzf is required when --archive is not provided."
    return 1
  }
  local -a candidates=(
    "$backup_dir"/dotfiles_<->_<->*.tar.gz(N.om)
  )
  local -a archives=()
  local candidate
  for candidate in "${candidates[@]}"; do
    [[ "${candidate:t}" =~ '^dotfiles_[0-9]{8}_[0-9]{6}(_pre-restore)?\.tar\.gz$' ]] \
      && archives+=("$candidate")
  done
  (( ${#archives[@]} > 0 )) || {
    _sys_error "No dotfile backups were found in $backup_dir."
    return 1
  }

  local archive archive_size
  local -a records=()
  for archive in "${archives[@]}"; do
    [[ -f "$archive" && ! -L "$archive" && -O "$archive" ]] || continue
    archive_size=$(command du -h "$archive" 2>/dev/null)
    archive_size="${archive_size%%[[:space:]]*}"
    records+=("${archive:t}"$'\t'"${archive_size:-unknown}")
  done
  (( ${#records[@]} > 0 )) || return 1

  local selected=""
  local -i select_rc=0
  _sys_fzf_capture \
    --delimiter=$'\t' \
    --with-nth=1,2 \
    --prompt='dotfile backup > ' \
    --header='Up/Down navigate | Type to filter | Enter select | Esc cancel' \
    --no-preview \
    < <(printf '%s\n' "${records[@]}") || select_rc=$?
  selected="$REPLY"
  if (( select_rc == 1 || select_rc == 130 )); then
    return 3
  elif (( select_rc != 0 )); then
    _sys_error \
      "fzf failed while selecting a dotfile backup (status $select_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 3
  (( ${records[(Ie)$selected]} > 0 )) || {
    _sys_error "The selected backup was not in the menu snapshot."
    return 1
  }
  local selected_name="${selected%%$'\t'*}"
  [[ "$selected_name" =~ '^dotfiles_[0-9]{8}_[0-9]{6}(_pre-restore)?\.tar\.gz$' ]] \
    || return 1
  REPLY="$backup_dir/$selected_name"
}

# Sets reply_rel to the smallest existing destination roots covered by a
# restore manifest. These roots form the mandatory pre-restore safety archive.
_sys_dotfiles_current_restore_roots() {
  local -a entries=("$@")
  local -a roots=()
  local entry normalized existing
  local -i covered

  for entry in "${entries[@]}"; do
    normalized="${entry%/}"
    [[ -e "$HOME/$normalized" ]] || continue
    covered=0
    for existing in "${roots[@]}"; do
      if [[ "$normalized" == "$existing" \
        || "$normalized" == "$existing"/* ]]; then
        covered=1
        break
      fi
    done
    (( covered )) && continue

    local -a retained=()
    for existing in "${roots[@]}"; do
      [[ "$existing" == "$normalized"/* ]] || retained+=("$existing")
    done
    roots=("${retained[@]}" "$normalized")
  done
  reply_rel=("${roots[@]}")
}

sys-restore-dots() {
  local archive=""
  local -i dry_run=0 assume_yes=0
  local REPLY
  local -a reply=() reply_rel=() reply_dirs=() reply_files=()
  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! dry_run && ! assume_yes )) \
          && [[ -z "$archive" ]] || {
          _sys_error "--help does not accept additional arguments."
          return 2
        }
        _sys_dotfiles_usage_restore
        return 0
        ;;
      --archive)
        (( $# >= 2 )) || {
          _sys_error "--archive requires a file."
          return 2
        }
        archive="$2"
        shift
        ;;
      --dry-run) dry_run=1 ;;
      -y|--yes)  assume_yes=1 ;;
      *)
        _sys_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  _sys_require_commands tar || return 1
  _sys_require_sha256_tool || return 1
  local backup_dir
  _sys_dotfiles_backup_dir 0 || return 1
  backup_dir="$REPLY"
  [[ -d "$backup_dir" ]] || {
    _sys_error "No dotfile backup directory exists at $backup_dir."
    return 1
  }
  if [[ -z "$archive" ]]; then
    _sys_dotfiles_select_archive "$backup_dir"
    local select_rc=$?
    (( select_rc == 3 )) && return 0
    (( select_rc == 0 )) || return "$select_rc"
    archive="$REPLY"
  fi

  _sys_dotfiles_validate_archive "$archive" "$backup_dir" || return 1
  local -a verified_manifest_entries=("${reply[@]}")
  local archive_identity
  _sys_dotfiles_archive_identity "$archive" || return 1
  archive_identity="$REPLY"

  local temp_root="${TMPDIR:-/tmp}"
  local staging_dir
  staging_dir=$(command mktemp -d "$temp_root/zdx-dotfiles-restore.XXXXXX") \
    || return 1
  [[ -d "$staging_dir" && ! -L "$staging_dir" \
    && "${staging_dir:h:A}" == "${temp_root:A}" \
    && "${staging_dir:t}" == zdx-dotfiles-restore.* ]] || {
      [[ -d "$staging_dir" && ! -L "$staging_dir" ]] \
        && command rm -rf "$staging_dir" 2>/dev/null
      return 1
    }
  local restore_rc=0
  local previous_umask
  previous_umask=$(umask)
  {
    umask 077
    command chmod 700 "$staging_dir" 2>/dev/null || return 1
    command tar -xzf "$archive" -C "$staging_dir" \
      --no-same-owner --no-same-permissions 2>/dev/null || return 1

    _sys_dotfiles_inspect_staging "$staging_dir" "$backup_dir" \
      "${verified_manifest_entries[@]}" || return 1
    local -a staged_entries=("${reply[@]}")
    local -a staged_dirs=("${reply_dirs[@]}")
    local -a staged_files=("${reply_files[@]}")
    local relative_entry
    for relative_entry in "${staged_dirs[@]}"; do
      _sys_dotfiles_validate_destination "$relative_entry" directory \
        || return 1
    done
    for relative_entry in "${staged_files[@]}"; do
      _sys_dotfiles_validate_destination "$relative_entry" file || return 1
    done

    _sys_header "Dotfile Restore Plan"
    _sys_warn "This operation can overwrite configuration and credential files."
    _sys_info "Verified archive: ${archive:t}"
    _sys_info "Validated entries: ${#staged_entries[@]}"
    local -i preview_count=0
    for relative_entry in "${staged_entries[@]}"; do
      _sys_dim "$relative_entry"
      (( ++preview_count >= 30 )) && break
    done
    (( ${#staged_entries[@]} > preview_count )) \
      && _sys_dim "... and $(( ${#staged_entries[@]} - preview_count )) more"

    if (( dry_run )); then
      _sys_info "Dry run complete; no dotfiles were changed."
      return 0
    fi
    if (( ! assume_yes )); then
      if [[ ! -t 0 || ! -t 2 ]]; then
        _sys_error "Non-interactive restore requires --yes."
        return 1
      fi
      _sys_confirm "Restore this exact verified archive?" || {
        _sys_info "Cancelled."
        return 0
      }
    fi

    _sys_dotfiles_archive_identity "$archive" || return 1
    [[ "$REPLY" == "$archive_identity" ]] || {
      _sys_error "Archive identity changed after confirmation."
      return 1
    }
    _sys_dotfiles_validate_archive "$archive" "$backup_dir" || return 1
    (( ${#reply[@]} == ${#verified_manifest_entries[@]} )) || return 1
    _sys_dotfiles_inspect_staging "$staging_dir" "$backup_dir" \
      "${verified_manifest_entries[@]}" || return 1
    staged_entries=("${reply[@]}")
    staged_dirs=("${reply_dirs[@]}")
    staged_files=("${reply_files[@]}")
    for relative_entry in "${staged_dirs[@]}"; do
      _sys_dotfiles_validate_destination "$relative_entry" directory \
        || return 1
    done
    for relative_entry in "${staged_files[@]}"; do
      _sys_dotfiles_validate_destination "$relative_entry" file || return 1
    done

    _sys_dotfiles_current_restore_roots "${staged_files[@]}"
    local -a current_relative=("${reply_rel[@]}")
    if (( ${#current_relative[@]} > 0 )); then
      local safety_timestamp
      safety_timestamp=$(command date +%Y%m%d_%H%M%S 2>/dev/null) || return 1
      local safety_archive="$backup_dir/dotfiles_${safety_timestamp}_pre-restore.tar.gz"
      _sys_dotfiles_create_archive "$safety_archive" "${current_relative[@]}" \
        || {
          _sys_error "Unable to create the mandatory pre-restore backup."
          return 1
        }
      _sys_info "Safety backup: $safety_archive"
    fi

    # The safety backup may take time. Revalidate both trees afterwards, then
    # publish regular files through same-directory temporaries and atomic
    # renames so final symlinks and hardlinks are never followed or truncated.
    _sys_dotfiles_inspect_staging "$staging_dir" "$backup_dir" \
      "${verified_manifest_entries[@]}" || return 1
    for relative_entry in "${reply_dirs[@]}"; do
      _sys_dotfiles_validate_destination "$relative_entry" directory \
        || return 1
    done
    for relative_entry in "${reply_files[@]}"; do
      _sys_dotfiles_validate_destination "$relative_entry" file || return 1
    done
    _sys_dotfiles_publish_staging "$staging_dir" "$backup_dir" \
      "${verified_manifest_entries[@]}" || {
      _sys_error "Restore publication failed; use the reported safety backup for recovery."
      return 1
    }
  } always {
    restore_rc=$?
    command rm -rf "$staging_dir" 2>/dev/null
    umask "$previous_umask"
  }

  (( restore_rc == 0 )) || return "$restore_rc"
  _sys_success "Dotfiles restored from the verified archive."
  _sys_info "Start a new shell to load the restored configuration."
}

typeset -g _SYS_DOTS_SOURCED=1
