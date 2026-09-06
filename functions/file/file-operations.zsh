#!/usr/bin/env zsh
# =============================================================================
# File Operations: bounded bulk mutations, permissions, and line endings
# =============================================================================
#
# Loaded by file-menu.zsh after file-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_FILE_OPERATIONS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_file_bulk_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  file-bulk-ops OPERATION [operation options] [safety options] -- PATH..."
  print -u2 -r -- "  file-bulk-ops"
  print -u2 -r -- ""
  print -u2 -r -- "Operations:"
  print -u2 -r -- "  copy|move --destination DIRECTORY"
  print -u2 -r -- "  delete"
  print -u2 -r -- "  rename --search TEXT --replace TEXT"
  print -u2 -r -- "  duplicate"
  print -u2 -r -- ""
  print -u2 -r -- "Safety options: --dry-run, --yes"
}

_file_permissions_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  file-permissions --mode MODE [--dry-run] [--yes] -- PATH..."
  print -u2 -r -- "  file-permissions"
  print -u2 -r -- ""
  print -u2 -r -- "MODE is +x, -x, or a three/four-digit octal mode."
}

_file_line_endings_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  file-line-endings --to lf|crlf [--dry-run] [--yes] -- FILE..."
  print -u2 -r -- "  file-line-endings"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Files are converted through same-directory staging and atomically replaced."
}

_file_validate_tree_for_transfer() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local tree_root="$1"
  [[ ( -f "$tree_root" || -d "$tree_root" ) && ! -L "$tree_root" ]] \
    || return 1
  _file_require_cmd head "bounded tree inventory" || return 1
  _file_require_cmd findmnt "recursive mount-boundary validation" || return 1
  _file_archive_stage_dir "${TMPDIR:-/tmp}" || return 1
  local inventory_dir="${reply[1]}"
  local inventory_identity="${reply[2]}"
  local inventory_file="${inventory_dir}/tree"
  local entry=""
  local -i entry_count=0 scan_rc=1 producer_rc=1 cleanup_rc=0
  {
    setopt local_options pipefail
    command find "$tree_root" -mindepth 1 -print0 2>/dev/null \
      | command head -c "$(( _FILE_MAX_PICKER_BYTES + 1 ))" \
        > "$inventory_file"
    producer_rc=$?
    local -A inventory_state=()
    zmodload zsh/stat 2>/dev/null \
      && zstat -LH inventory_state -- "$inventory_file" 2>/dev/null \
      || return 1
    (( inventory_state[size] <= _FILE_MAX_PICKER_BYTES )) || {
      _file_error "Transfer inventory exceeds the byte limit: $tree_root"
      return 1
    }
    (( producer_rc == 0 )) || {
      _file_error "Could not inventory transfer target: $tree_root"
      return 1
    }
    local -a inspected_entries=("$tree_root")
    while IFS= read -r -d '' entry; do
      (( ++entry_count <= _FILE_MAX_CANDIDATES )) || {
        _file_error "Transfer inventory exceeds the entry limit: $tree_root"
        return 1
      }
      if [[ -L "$entry" \
        || ( ! -f "$entry" && ! -d "$entry" ) ]]; then
        _file_error "Transfers refuse links and special files: $entry"
        return 1
      fi
      inspected_entries+=("$entry")
    done < "$inventory_file"
    local inspected_entry=""
    local -A entry_state=()
    for inspected_entry in "${inspected_entries[@]}"; do
      _file_path_is_displayable "$inspected_entry" \
        && [[ "$inspected_entry" != *'|'* ]] || {
        _file_error "Transfers refuse unrepresentable tree names."
        return 1
      }
      entry_state=()
      zstat -LH entry_state -- "$inspected_entry" 2>/dev/null || return 1
      (( entry_state[uid] == EUID \
        && (entry_state[mode] & 8#22) == 0 )) || {
        _file_error \
          "Transfers require owned, non-writable tree entries: $inspected_entry"
        return 1
      }
      if [[ -f "$inspected_entry" ]] && (( entry_state[nlink] != 1 )); then
        _file_error \
          "Transfers refuse hard-linked regular files: $inspected_entry"
        return 1
      fi
      _file_mountpoint_clear "$inspected_entry" || return 1
    done
    scan_rc=0
  } always {
    _file_archive_cleanup_stage "$inventory_dir" "$inventory_identity" \
      || cleanup_rc=$?
    (( cleanup_rc == 0 )) || scan_rc=1
  }
  return $scan_rc
}

_file_quarantine_delete() {
  emulate -L zsh
  local target="$1"
  local expected_identity="$2"
  _file_revalidate_mutation_target "$target" "$expected_identity" || return 1
  _file_delete_mounts_clear "$target" || return 1

  local parent="${target:h}"
  _file_node_identity "$parent" || return 1
  local parent_identity="$REPLY"
  local quarantine=""
  local -i attempt=0 operation_rc=1
  while (( ++attempt <= 128 )); do
    quarantine="${parent}/.zdx-file-delete.${EPOCHREALTIME//./-}.${RANDOM}.${attempt}"
    [[ ! -e "$quarantine" && ! -L "$quarantine" ]] && break
    quarantine=""
  done
  [[ -n "$quarantine" ]] || {
    _file_error "Could not reserve a bounded deletion quarantine name."
    return 1
  }

  {
    _file_revalidate_mutation_target "$target" "$expected_identity" || return 1
    _file_delete_mounts_clear "$target" || return 1
    _file_node_identity "$parent" || return 1
    [[ "$REPLY" == "$parent_identity" ]] || {
      _file_error "The deletion parent changed after authorization."
      return 1
    }
    command mv -T -n -- "$target" "$quarantine" 2>/dev/null || {
      operation_rc=$?
      _file_error "Could not quarantine the exact deletion target."
      return $operation_rc
    }
    [[ ! -e "$target" && ! -L "$target" ]] || {
      _file_error "The deletion target remained after quarantine."
      return 1
    }
    _file_fingerprint_node_identity "$expected_identity" || return 1
    local expected_node_identity="$REPLY"
    _file_node_identity "$quarantine" || return 1
    [[ "$REPLY" == "$expected_node_identity" ]] || {
      _file_error "The quarantined deletion target changed identity."
      return 1
    }
    command rm -rf -- "$quarantine" 2>/dev/null || return $?
    [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || return 1
    operation_rc=0
  } always {
    if (( operation_rc != 0 )) \
      && [[ -e "$quarantine" || -L "$quarantine" ]]; then
      _file_error "Deletion was incomplete; recovery data was retained."
      _file_dim "Recovery path: $quarantine"
    fi
  }
  return $operation_rc
}

_file_bulk_plan_targets() {
  local base_dir="$1"
  shift
  local allow_writable="${1:-no}"
  [[ "$allow_writable" == "yes" || "$allow_writable" == "no" ]] || return 2
  shift
  reply=()
  (( $# <= _FILE_MAX_CANDIDATES )) || {
    _file_error \
      "Bulk plans accept at most $_FILE_MAX_CANDIDATES explicit targets."
    return 2
  }
  local -a identities=()
  local requested=""
  local validation=""
  local absolute=""
  for requested in "$@"; do
    _file_validate_mutation_target \
      "$requested" "$base_dir" "$allow_writable" || return 1
    validation="$REPLY"
    absolute="${validation%%|*}"
    if _file_array_contains_literal "$absolute" "${reply[@]}"; then
      _file_error "Duplicate target in plan: $requested"
      return 1
    fi
    local existing=""
    for existing in "${reply[@]}"; do
      if [[ "$absolute" == "$existing"/* || "$existing" == "$absolute"/* ]]; then
        _file_error "Bulk targets may not contain one another."
        return 1
      fi
    done
    reply+=("$absolute")
    identities+=("${validation#*|}")
  done
  (( ${#reply[@]} > 0 )) || {
    _file_error "At least one target is required."
    return 2
  }
  REPLY="${(F)identities}"
}

_file_bulk_revalidate() {
  local targets_name="$1"
  local identities_text="$2"
  local -a targets=("${(@P)targets_name}")
  local -a identities=("${(@f)identities_text}")
  (( ${#targets[@]} == ${#identities[@]} )) || return 1
  local -i index=1
  while (( index <= ${#targets[@]} )); do
    _file_revalidate_mutation_target \
      "${targets[index]}" "${identities[index]}" || return 1
    (( ++index ))
  done
}

_file_literal_replace_all() {
  local value="$1"
  local needle="$2"
  local replacement="$3"
  [[ -n "$needle" ]] || return 1

  local result=""
  local remaining="$value"
  local prefix=""
  while [[ "$remaining" == *"$needle"* ]]; do
    prefix="${remaining%%"$needle"*}"
    result+="${prefix}${replacement}"
    remaining="${remaining#*"$needle"}"
  done
  REPLY="${result}${remaining}"
}

_file_bulk_destination_dir() {
  local requested="$1"
  local base_dir="$2"
  REPLY=""
  [[ -n "$requested" && "$requested" != *[[:cntrl:]]* \
    && "$requested" != *'|'* ]] || {
    _file_error "A destination directory is required."
    return 2
  }
  local destination="${requested:a}"
  [[ "$destination" == "$base_dir"/* \
    && "$destination" != "$base_dir" \
    && "$destination" != "$_FILE_SUITE_ROOT" ]] || {
    _file_error "The destination must be a child of the operation base."
    return 1
  }
  [[ -d "$destination" && ! -L "$destination" \
    && "$destination" == "${destination:A}" ]] || {
    _file_error "The destination must already be a real, symlink-free directory."
    return 1
  }
  _file_node_identity "$destination" || return 1
  local destination_identity="$REPLY"
  local -A destination_state=()
  zmodload zsh/stat 2>/dev/null \
    && zstat -LH destination_state -- "$destination" 2>/dev/null || return 1
  (( destination_state[uid] == EUID \
    && (destination_state[mode] & 8#22) == 0 )) || {
    _file_error \
      "The destination must be owned and not group/world-writable."
    return 1
  }
  reply=("$destination" "$destination_identity")
  REPLY="$destination"
}

_file_publish_copied_path() {
  local staged_node="$1"
  local destination="$2"
  local parent_identity="$3"
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  _file_node_identity "$staged_node" || return 1
  local staged_identity="$REPLY"
  _file_revalidate_parent "$destination" "$parent_identity" || return 1
  if [[ -f "$staged_node" && ! -L "$staged_node" ]]; then
    command ln -- "$staged_node" "$destination" 2>/dev/null || return $?
    command rm -f -- "$staged_node" 2>/dev/null || return $?
  elif [[ -d "$staged_node" && ! -L "$staged_node" ]]; then
    command mv -T -n -- "$staged_node" "$destination" 2>/dev/null || return $?
  else
    return 1
  fi
  [[ ! -e "$staged_node" && ! -L "$staged_node" \
    && ( -f "$destination" || -d "$destination" ) \
    && ! -L "$destination" ]] || return 1
  _file_node_identity "$destination" || return 1
  [[ "$REPLY" == "$staged_identity" ]] || return 1
  _file_revalidate_parent "$destination" "$parent_identity"
}

_file_bulk_execute() {
  local operation="$1"
  local destination_arg="$2"
  local search_text="$3"
  local replacement_text="$4"
  local dry_run="$5"
  local auto_yes="$6"
  shift 6
  local -a requested_targets=("$@")

  case "$operation" in
    copy|move|delete|rename|duplicate) ;;
    *)
      _file_error "Unknown bulk operation: $operation"
      return 2
      ;;
  esac

  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"
  _file_bulk_plan_targets \
    "$base_dir" no "${requested_targets[@]}" || return $?
  local -a targets=("${reply[@]}")
  local identities_text="$REPLY"

  local destination_dir=""
  local destination_identity=""
  local target=""
  local planned_destination=""
  local parent_plan_identity=""
  local -a planned_destinations=()
  local -a planned_parent_identities=()
  case "$operation" in
    copy|move)
      _file_bulk_destination_dir "$destination_arg" "$base_dir" || return $?
      destination_dir="$REPLY"
      destination_identity="${reply[2]}"
      _file_mountpoint_clear "$destination_dir" || return 1
      for target in "${targets[@]}"; do
        [[ "$destination_dir" != "$target" \
          && "$destination_dir" != "$target"/* ]] || {
          _file_error "A destination cannot be inside a selected target."
          return 1
        }
        planned_destination="${destination_dir}/${target:t}"
        [[ ! -e "$planned_destination" && ! -L "$planned_destination" ]] || {
          _file_error "Destination already exists: $planned_destination"
          return 1
        }
        if _file_array_contains_literal \
          "$planned_destination" "${planned_destinations[@]}"; then
          _file_error "Multiple targets map to: $planned_destination"
          return 1
        fi
        _file_validate_destination_parent \
          "$planned_destination" "$base_dir" || return 1
        parent_plan_identity="${reply[2]}"
        _file_validate_tree_for_transfer "$target" || return 1
        if [[ "$operation" == "move" ]]; then
          _file_path_fingerprint "$target" || return 1
          [[ "${REPLY%%:*}" == "${destination_identity%%:*}" ]] || {
            _file_error \
              "Move requires source and destination on the same filesystem."
            return 1
          }
        fi
        planned_destinations+=("$planned_destination")
        planned_parent_identities+=("$parent_plan_identity")
      done
      ;;
    delete)
      for target in "${targets[@]}"; do
        _file_delete_mounts_clear "$target" || return 1
      done
      ;;
    rename)
      [[ -n "$search_text" \
        && "$search_text" != */* \
        && "$replacement_text" != */* \
        && "$search_text" != *[[:cntrl:]]* \
        && "$replacement_text" != *[[:cntrl:]]* ]] || {
        _file_error "Rename text must be non-empty and contain no slash or controls."
        return 2
      }
      for target in "${targets[@]}"; do
        _file_delete_mounts_clear "$target" || return 1
        [[ "${target:t}" == *"$search_text"* ]] || {
          _file_error "Rename search text does not match: $target"
          return 1
        }
        _file_literal_replace_all \
          "${target:t}" "$search_text" "$replacement_text" || return 1
        [[ -n "$REPLY" && "$REPLY" != "." && "$REPLY" != ".." ]] || {
          _file_error "Rename would produce an invalid filename."
          return 1
        }
        planned_destination="${target:h}/${REPLY}"
        [[ "$planned_destination" != "$target" \
          && ! -e "$planned_destination" \
          && ! -L "$planned_destination" ]] || {
          _file_error "Rename destination is unchanged or already exists: $planned_destination"
          return 1
        }
        if _file_array_contains_literal \
          "$planned_destination" "${planned_destinations[@]}"; then
          _file_error "Multiple targets map to: $planned_destination"
          return 1
        fi
        _file_validate_destination_parent \
          "$planned_destination" "$base_dir" || return 1
        parent_plan_identity="${reply[2]}"
        planned_destinations+=("$planned_destination")
        planned_parent_identities+=("$parent_plan_identity")
      done
      ;;
    duplicate)
      local extension=""
      local base_name=""
      local -i suffix=0
      for target in "${targets[@]}"; do
        _file_validate_tree_for_transfer "$target" || return 1
        extension="${target:e}"
        base_name="${target:r}"
        if [[ -n "$extension" ]]; then
          planned_destination="${base_name}.bak.${extension}"
        else
          planned_destination="${target}.bak"
        fi
        suffix=1
        while [[ -e "$planned_destination" || -L "$planned_destination" ]] \
          || _file_array_contains_literal \
            "$planned_destination" "${planned_destinations[@]}"; do
          if [[ -n "$extension" ]]; then
            planned_destination="${base_name}.bak${suffix}.${extension}"
          else
            planned_destination="${target}.bak${suffix}"
          fi
          (( ++suffix ))
          (( suffix <= _FILE_MAX_CANDIDATES )) || {
            _file_error "Could not find a bounded duplicate filename."
            return 1
          }
        done
        _file_validate_destination_parent \
          "$planned_destination" "$base_dir" || return 1
        parent_plan_identity="${reply[2]}"
        planned_destinations+=("$planned_destination")
        planned_parent_identities+=("$parent_plan_identity")
      done
      ;;
  esac

  _file_header "Bulk Operation Plan"
  _file_info "Operation: $operation"
  _file_info "Targets: ${#targets[@]}"
  local -i index=1
  while (( index <= ${#targets[@]} )); do
    if (( index <= ${#planned_destinations[@]} )); then
      _file_dim "${targets[index]} -> ${planned_destinations[index]}"
    else
      _file_dim "${targets[index]}"
    fi
    (( ++index ))
  done
  if [[ "$dry_run" == "yes" ]]; then
    _file_success "Dry run complete; no files were changed."
    return 0
  fi

  _file_confirm_mutation "Execute this exact bulk plan?" "$auto_yes"
  local -i confirm_rc=$?
  (( confirm_rc == 0 )) || {
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  _file_bulk_revalidate targets "$identities_text" || return 1

  if [[ "$operation" == "copy" || "$operation" == "move" ]]; then
    _file_node_identity "$destination_dir" || return 1
    [[ "$REPLY" == "$destination_identity" ]] || {
      _file_error "The destination changed after planning."
      return 1
    }
  fi

  local -a identities=("${(@f)identities_text}")
  local -i failures=0
  local -i action_rc=0 cleanup_rc=0
  local stage_dir="" stage_identity="" staged_node=""
  index=1
  while (( index <= ${#targets[@]} )); do
    target="${targets[index]}"
    _file_revalidate_mutation_target "$target" "${identities[index]}" || {
      (( ++failures ))
      (( ++index ))
      continue
    }
    planned_destination="${planned_destinations[index]:-}"
    local planned_parent_identity="${planned_parent_identities[index]:-}"
    if [[ -n "$planned_destination" ]]; then
      _file_revalidate_parent \
        "$planned_destination" "$planned_parent_identity" || {
        (( ++failures ))
        (( ++index ))
        continue
      }
    fi
    if [[ -n "$planned_destination" \
      && ( -e "$planned_destination" || -L "$planned_destination" ) ]]; then
      _file_error "Planned destination appeared: $planned_destination"
      (( ++failures ))
      (( ++index ))
      continue
    fi

    action_rc=0
    case "$operation" in
      copy|duplicate)
        _file_validate_tree_for_transfer "$target" || action_rc=1
        (( action_rc == 0 )) || {
          (( ++failures ))
          (( ++index ))
          continue
        }
        _file_archive_stage_dir "${planned_destination:h}" || action_rc=1
        if (( action_rc == 0 )); then
          stage_dir="${reply[1]}"
          stage_identity="${reply[2]}"
          staged_node="${stage_dir}/${planned_destination:t}"
          cleanup_rc=0
          {
            command cp -R -- "$target" "$staged_node" 2>/dev/null \
              || action_rc=$?
            if (( action_rc == 0 )); then
              _file_validate_tree_for_transfer "$staged_node" || action_rc=1
            fi
            if (( action_rc == 0 )); then
              _file_revalidate_mutation_target \
                "$target" "${identities[index]}" || action_rc=1
            fi
            if (( action_rc == 0 )); then
              [[ ! -e "$planned_destination" \
                && ! -L "$planned_destination" ]] || action_rc=1
            fi
            if (( action_rc == 0 )); then
              _file_publish_copied_path \
                "$staged_node" "$planned_destination" \
                "$planned_parent_identity" || action_rc=$?
            fi
          } always {
            _file_archive_cleanup_stage "$stage_dir" "$stage_identity" \
              || cleanup_rc=$?
            if (( cleanup_rc != 0 && action_rc != 130 && action_rc != 143 )); then
              action_rc=$cleanup_rc
            fi
          }
        fi
        ;;
      move|rename)
        _file_delete_mounts_clear "$target" || action_rc=1
        if (( action_rc == 0 )); then
          command mv -T -n -- "$target" "$planned_destination" 2>/dev/null \
            || action_rc=$?
        fi
        if (( action_rc == 0 )) \
          && [[ -e "$target" || -L "$target" ]]; then
          _file_error "The source remained after the planned move."
          action_rc=1
        fi
        if (( action_rc == 0 )); then
          _file_fingerprint_node_identity \
            "${identities[index]}" || action_rc=1
          local expected_node_identity="$REPLY"
          _file_node_identity "$planned_destination" || action_rc=1
          [[ "$REPLY" == "$expected_node_identity" ]] || action_rc=1
        fi
        if (( action_rc == 0 )); then
          _file_revalidate_parent \
            "$planned_destination" "$planned_parent_identity" || action_rc=1
        fi
        ;;
      delete)
        _file_quarantine_delete "$target" "${identities[index]}" \
          || action_rc=$?
        ;;
    esac
    if (( action_rc == 0 )); then
      _file_success "Completed: $target"
    else
      _file_error "Failed (status $action_rc): $target"
      (( ++failures ))
      if (( action_rc == 130 || action_rc == 143 )); then
        _file_warn "Bulk operation interrupted; later targets were not changed."
        _file_info "Targets not run: $(( ${#targets[@]} - index ))"
        return $action_rc
      fi
    fi
    (( ++index ))
  done

  (( failures == 0 )) || {
    _file_error "$failures of ${#targets[@]} operation(s) failed."
    return 1
  }
  return 0
}

file-bulk-ops() {
  emulate -L zsh
  _file_header "Bulk File Operations"

  if (( $# == 0 )); then
    _file_select_paths "Select files for bulk operations" yes all
    local -i select_rc=$?
    if (( select_rc != 0 )); then
      (( select_rc == 130 )) && return 0
      return $select_rc
    fi
    local -a interactive_targets=("${reply[@]}")
    _file_choose_fixed "Bulk operation" \
      "copy" "move" "delete" "rename" "duplicate"
    local -i operation_rc=$?
    if (( operation_rc != 0 )); then
      (( operation_rc == 130 )) && return 0
      return $operation_rc
    fi
    local operation="$REPLY"
    local destination="" search_text="" replacement_text=""
    if [[ "$operation" == "copy" || "$operation" == "move" ]]; then
      _file_read_line "Destination directory" || return $?
      destination="$REPLY"
    elif [[ "$operation" == "rename" ]]; then
      _file_read_line "Search text" || return $?
      search_text="$REPLY"
      _file_read_line "Replacement text" || return $?
      replacement_text="$REPLY"
    fi
    _file_bulk_execute \
      "$operation" "$destination" "$search_text" "$replacement_text" \
      no no "${interactive_targets[@]}"
    return $?
  fi

  local operation=""
  local destination="" search_text="" replacement_text=""
  local dry_run=no auto_yes=no
  local -a targets=()
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _file_bulk_usage
        return 0
        ;;
      --destination)
        (( $# >= 2 )) || return 2
        destination="$2"
        shift 2
        ;;
      --search)
        (( $# >= 2 )) || return 2
        search_text="$2"
        shift 2
        ;;
      --replace)
        (( $# >= 2 )) || return 2
        replacement_text="$2"
        shift 2
        ;;
      --dry-run) dry_run=yes; shift ;;
      --yes) auto_yes=yes; shift ;;
      --)
        shift
        targets+=("$@")
        break
        ;;
      -*)
        _file_error "Unknown option: $1"
        return 2
        ;;
      *)
        if [[ -z "$operation" ]]; then
          operation="$1"
        else
          targets+=("$1")
        fi
        shift
        ;;
    esac
  done
  [[ -n "$operation" && ${#targets[@]} -gt 0 ]] || {
    _file_error "An operation and at least one target are required."
    return 2
  }
  _file_bulk_execute \
    "$operation" "$destination" "$search_text" "$replacement_text" \
    "$dry_run" "$auto_yes" "${targets[@]}"
}

_file_permissions_execute() {
  local mode="$1"
  local dry_run="$2"
  local auto_yes="$3"
  shift 3
  local -a requested_targets=("$@")

  [[ "$mode" == "+x" || "$mode" == "-x" \
    || "$mode" == [0-7][0-7][0-7] \
    || "$mode" == [0-7][0-7][0-7][0-7] ]] || {
    _file_error "Invalid chmod mode: $mode"
    return 2
  }
  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"
  _file_bulk_plan_targets \
    "$base_dir" yes "${requested_targets[@]}" || return $?
  local -a targets=("${reply[@]}")
  local identities_text="$REPLY"

  _file_header "Permission Change Plan"
  _file_info "Mode: $mode"
  local target=""
  for target in "${targets[@]}"; do
    _file_dim "$target"
  done
  if [[ "$dry_run" == "yes" ]]; then
    _file_success "Dry run complete; no permissions were changed."
    return 0
  fi
  _file_confirm_mutation "Apply this permission plan?" "$auto_yes"
  local -i confirm_rc=$?
  (( confirm_rc == 0 )) || {
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  _file_bulk_revalidate targets "$identities_text" || return 1

  local -a identities=("${(@f)identities_text}")
  local -i index=1 failures=0 action_rc=0
  while (( index <= ${#targets[@]} )); do
    _file_revalidate_mutation_target \
      "${targets[index]}" "${identities[index]}" || {
      (( ++failures ))
      (( ++index ))
      continue
    }
    action_rc=0
    command chmod "$mode" -- "${targets[index]}" 2>/dev/null \
      || action_rc=$?
    if (( action_rc != 0 )); then
      (( ++failures ))
      _file_error "Permission change failed (status $action_rc): ${targets[index]}"
      if (( action_rc == 130 || action_rc == 143 )); then
        _file_warn "Permission changes interrupted; later targets were not changed."
        return $action_rc
      fi
    fi
    (( ++index ))
  done
  (( failures == 0 )) || {
    _file_error "$failures permission change(s) failed."
    return 1
  }
  _file_success "Changed permissions on ${#targets[@]} target(s)."
}

file-permissions() {
  emulate -L zsh
  _file_header "File Permissions Manager"

  if (( $# == 0 )); then
    _file_select_paths "Select permission targets" yes all
    local -i select_rc=$?
    if (( select_rc != 0 )); then
      (( select_rc == 130 )) && return 0
      return $select_rc
    fi
    local -a interactive_targets=("${reply[@]}")
    _file_choose_fixed "Permission mode" "+x" "-x" "600" "644" "755" "custom"
    local -i mode_rc=$?
    if (( mode_rc != 0 )); then
      (( mode_rc == 130 )) && return 0
      return $mode_rc
    fi
    local mode="$REPLY"
    if [[ "$mode" == "custom" ]]; then
      _file_read_line "Octal mode" || return $?
      mode="$REPLY"
    fi
    _file_permissions_execute "$mode" no no "${interactive_targets[@]}"
    return $?
  fi

  local mode="" dry_run=no auto_yes=no
  local -a targets=()
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _file_permissions_usage
        return 0
        ;;
      --mode)
        (( $# >= 2 )) || return 2
        mode="$2"
        shift 2
        ;;
      --dry-run) dry_run=yes; shift ;;
      --yes) auto_yes=yes; shift ;;
      --)
        shift
        targets+=("$@")
        break
        ;;
      -*)
        _file_error "Unknown option: $1"
        return 2
        ;;
      *)
        targets+=("$1")
        shift
        ;;
    esac
  done
  [[ -n "$mode" && ${#targets[@]} -gt 0 ]] || {
    _file_error "--mode and at least one target are required."
    return 2
  }
  _file_permissions_execute \
    "$mode" "$dry_run" "$auto_yes" "${targets[@]}"
}

_file_text_file_check() {
  local input_file="$1"
  [[ -f "$input_file" && ! -L "$input_file" ]] || return 1
  [[ ! -s "$input_file" ]] && return 0
  _file_require_cmd grep "binary-file detection" || return 1
  LC_ALL=C command grep -Iq -- '' "$input_file"
}

_file_copy_mode() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local source_file="$1"
  local destination_file="$2"
  local -A state=()
  zstat -LH state -- "$source_file" 2>/dev/null || return 1
  local mode_text=""
  printf -v mode_text '%o' "$(( state[mode] & 8#7777 ))"
  command chmod "$mode_text" -- "$destination_file" 2>/dev/null
}

_file_line_endings_execute() {
  local direction="$1"
  local dry_run="$2"
  local auto_yes="$3"
  shift 3
  local -a requested_targets=("$@")
  [[ "$direction" == "lf" || "$direction" == "crlf" ]] || {
    _file_error "--to must be lf or crlf."
    return 2
  }
  _file_require_cmd sed "line-ending conversion" || return 1
  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"
  _file_bulk_plan_targets \
    "$base_dir" no "${requested_targets[@]}" || return $?
  local -a targets=("${reply[@]}")
  local identities_text="$REPLY"
  local target=""
  for target in "${targets[@]}"; do
    [[ -f "$target" ]] || {
      _file_error "Line-ending targets must be regular files: $target"
      return 1
    }
    _file_text_file_check "$target" || {
      _file_error "Refusing a binary or unreadable file: $target"
      return 1
    }
  done

  _file_header "Line Ending Conversion Plan"
  _file_info "Target format: ${direction:u}"
  for target in "${targets[@]}"; do
    _file_dim "$target"
  done
  if [[ "$dry_run" == "yes" ]]; then
    _file_success "Dry run complete; no files were changed."
    return 0
  fi
  _file_confirm_mutation "Convert these files atomically?" "$auto_yes"
  local -i confirm_rc=$?
  (( confirm_rc == 0 )) || {
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  _file_bulk_revalidate targets "$identities_text" || return 1

  local -a identities=("${(@f)identities_text}")
  local -i index=1 failures=0 conversion_rc=0 cleanup_rc=0
  local -a conversion_statuses=()
  local -i stage_rc=0
  local staged_file=""
  while (( index <= ${#targets[@]} )); do
    target="${targets[index]}"
    _file_revalidate_mutation_target "$target" "${identities[index]}" || {
      (( ++failures ))
      (( ++index ))
      continue
    }
    _file_make_sibling_temp "$target" || {
      (( ++failures ))
      (( ++index ))
      continue
    }
    staged_file="$REPLY"
    _file_directory_identity "${target:h}" || {
      command rm -f -- "$staged_file" 2>/dev/null
      (( ++failures ))
      (( ++index ))
      continue
    }
    local target_parent_identity="$REPLY"
    _file_sha256_digest "$target" || {
      command rm -f -- "$staged_file" 2>/dev/null
      (( ++failures ))
      (( ++index ))
      continue
    }
    local original_digest="$REPLY"
    conversion_rc=0
    cleanup_rc=0
    {
      if [[ "$direction" == "lf" ]]; then
        command sed 's/\r$//' -- "$target" > "$staged_file"
        conversion_rc=$?
      else
        setopt localoptions pipefail
        command sed 's/\r$//' -- "$target" \
          | command sed 's/$/\r/' > "$staged_file"
        conversion_statuses=("${pipestatus[@]}")
        for stage_rc in "${conversion_statuses[@]}"; do
          (( stage_rc == 0 )) && continue
          conversion_rc=$stage_rc
          (( stage_rc == 130 || stage_rc == 143 )) && break
        done
      fi
      if (( conversion_rc != 0 )); then
        _file_error "Conversion failed before publication: $target"
      else
        _file_copy_mode "$target" "$staged_file" || conversion_rc=$?
      fi
      if (( conversion_rc == 0 )); then
        _file_revalidate_mutation_target \
          "$target" "${identities[index]}" || conversion_rc=1
      fi
      if (( conversion_rc == 0 )); then
        _file_sha256_digest "$target" || conversion_rc=1
        [[ "$REPLY" == "$original_digest" ]] || conversion_rc=1
      fi
      if (( conversion_rc == 0 )); then
        local target_output_state="file|${identities[index]}|${original_digest}"
        _file_publish_staged_file \
          "$staged_file" "$target" "$target_output_state" \
          "$target_parent_identity" || conversion_rc=$?
      fi
      (( conversion_rc != 0 )) || staged_file=""
    } always {
      if [[ -n "$staged_file" && -f "$staged_file" && ! -L "$staged_file" \
        && "${staged_file:h}" == "${target:h}" \
        && "${staged_file:t}" == ".${target:t}.zdx."* ]]; then
        command rm -f -- "$staged_file" 2>/dev/null || cleanup_rc=$?
      fi
    }
    if (( conversion_rc == 130 || conversion_rc == 143 )); then
      _file_warn "Conversion interrupted; later files were not changed."
      return $conversion_rc
    fi
    if (( cleanup_rc == 130 || cleanup_rc == 143 )); then
      _file_warn "Staging cleanup interrupted; later files were not changed."
      return $cleanup_rc
    fi
    if (( conversion_rc != 0 || cleanup_rc != 0 )); then
      (( ++failures ))
    else
      _file_success "Converted: $target"
    fi
    (( ++index ))
  done
  (( failures == 0 )) || {
    _file_error "$failures line-ending conversion(s) failed."
    return 1
  }
}

file-line-endings() {
  emulate -L zsh
  _file_header "Line Ending Converter"

  if (( $# == 0 )); then
    _file_select_paths "Select files to convert" yes files
    local -i select_rc=$?
    if (( select_rc != 0 )); then
      (( select_rc == 130 )) && return 0
      return $select_rc
    fi
    local -a interactive_targets=("${reply[@]}")
    _file_choose_fixed "Line ending target" "lf" "crlf"
    local -i direction_rc=$?
    if (( direction_rc != 0 )); then
      (( direction_rc == 130 )) && return 0
      return $direction_rc
    fi
    _file_line_endings_execute "$REPLY" no no "${interactive_targets[@]}"
    return $?
  fi

  local direction="" dry_run=no auto_yes=no
  local -a targets=()
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _file_line_endings_usage
        return 0
        ;;
      --to)
        (( $# >= 2 )) || return 2
        direction="${2:l}"
        shift 2
        ;;
      --dry-run) dry_run=yes; shift ;;
      --yes) auto_yes=yes; shift ;;
      --)
        shift
        targets+=("$@")
        break
        ;;
      -*)
        _file_error "Unknown option: $1"
        return 2
        ;;
      *)
        targets+=("$1")
        shift
        ;;
    esac
  done
  [[ -n "$direction" && ${#targets[@]} -gt 0 ]] || {
    _file_error "--to and at least one file are required."
    return 2
  }
  _file_line_endings_execute \
    "$direction" "$dry_run" "$auto_yes" "${targets[@]}"
}

typeset -g _FILE_OPERATIONS_SOURCED=1
