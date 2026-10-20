#!/usr/bin/env zsh
# =============================================================================
# File Operations: transfer-tree validation and quarantined deletion
# =============================================================================
#
# Loaded by file-menu.zsh after file-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_FILE_OPERATIONS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Validates every node of a recursive transfer or deletion target: owned, not
# group/world-writable, singly linked when a regular file, representable, and
# free of links, special files, and mounts. The mount checks share the
# caller's pass snapshot when one is declared (see _file_mount_snapshot).
_file_validate_tree_for_transfer() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local tree_root="$1"
  [[ ( -f "$tree_root" || -d "$tree_root" ) && ! -L "$tree_root" ]] \
    || return 1
  _file_require_cmd head "bounded tree inventory" || return 1
  if (( ! ${+_file_mount_mode} )); then
    local _file_mount_mode=""
    local -A _file_mount_targets=()
  fi
  if [[ -z "$_file_mount_mode" ]]; then
    _file_mount_snapshot || return 1
  fi
  # The staging helper returns through reply; callers such as
  # _file_archive_inputs_plan accumulate their own results in reply.
  local -a reply=()
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
    zmodload -F zsh/stat b:zstat 2>/dev/null \
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
    _file_mount_table_clear_below "$tree_root" || return 1
    scan_rc=0
  } always {
    _file_archive_cleanup_stage "$inventory_dir" "$inventory_identity" \
      || cleanup_rc=$?
    (( cleanup_rc == 0 )) || scan_rc=1
  }
  return $scan_rc
}

# Deletes one reviewed target through a same-directory quarantine.
# Usage: _file_quarantine_delete <target> <identity> [mv-command...]
# The optional mv command comes from _file_mv_no_clobber_command, so a batch
# probes mv once. A file shares the caller's mount snapshot; a directory,
# which is removed recursively, always takes a fresh one. A target reviewed
# as a symbolic link, which only a trash purge passes, is removed as the
# link itself and never followed.
_file_quarantine_delete() {
  emulate -L zsh
  local target="$1"
  local expected_identity="$2"
  shift 2
  local -a mv_command=("$@")
  if (( ${#mv_command[@]} == 0 )); then
    local -a reply=()
    _file_mv_no_clobber_command || return 1
    mv_command=("${reply[@]}")
  fi
  if [[ -d "$target" && ! -L "$target" ]]; then
    local _file_mount_mode=""
    local -A _file_mount_targets=()
  fi
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
    # A directory's second check must not reuse the first snapshot.
    [[ -d "$target" && ! -L "$target" ]] && _file_mount_mode=""
    _file_delete_mounts_clear "$target" || return 1
    _file_node_identity "$parent" || return 1
    [[ "$REPLY" == "$parent_identity" ]] || {
      _file_error "The deletion parent changed after authorization."
      return 1
    }
    command "${mv_command[@]}" -- "$target" "$quarantine" 2>/dev/null || {
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
    # The type is part of the node identity, so a quarantine that is not the
    # reviewed file, directory, or link never matches.
    _file_path_fingerprint "$quarantine" || return 1
    _file_fingerprint_node_identity "$REPLY" || return 1
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

# Plans exact deletion targets below one operation base. Prints nothing on
# stdout; reply holds canonical targets and REPLY their newline-joined
# fingerprints in the same order.
_file_delete_plan_targets() {
  local base_dir="$1"
  shift
  reply=()
  (( $# <= _FILE_MAX_CANDIDATES )) || {
    _file_error \
      "Deletion plans accept at most $_FILE_MAX_CANDIDATES targets."
    return 2
  }
  local -a identities=() target_ancestors=()
  # Planned targets and every directory between each target and the base,
  # so duplicate and containment checks stay linear in the plan size.
  local -A planned_targets=() planned_ancestors=()
  local requested=""
  local validation=""
  local absolute=""
  local ancestor=""
  for requested in "$@"; do
    _file_validate_mutation_target "$requested" "$base_dir" || return 1
    validation="$REPLY"
    absolute="${validation%%|*}"
    if (( ${+planned_targets[$absolute]} )); then
      _file_error "Duplicate target in plan: $requested"
      return 1
    fi
    target_ancestors=()
    ancestor="${absolute:h}"
    while [[ "$ancestor" == "$base_dir"/* ]]; do
      target_ancestors+=("$ancestor")
      ancestor="${ancestor:h}"
    done
    if (( ${+planned_ancestors[$absolute]} )); then
      _file_error "Deletion targets may not contain one another."
      return 1
    fi
    for ancestor in "${target_ancestors[@]}"; do
      if (( ${+planned_targets[$ancestor]} )); then
        _file_error "Deletion targets may not contain one another."
        return 1
      fi
    done
    planned_targets[$absolute]=1
    for ancestor in "${target_ancestors[@]}"; do
      planned_ancestors[$ancestor]=1
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

_file_delete_revalidate() {
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

# Deletes an exact reviewed target set from the current operation base.
# Usage: _file_delete_execute [--warn TEXT | --note TEXT]...
#          DRY_RUN AUTO_YES TARGET...
# DRY_RUN and AUTO_YES are yes or no. Warnings and notes are disclosures
# printed under the plan in the given order. Every target is revalidated after
# authorization and before the first mutation; each deletion goes through a
# same-directory quarantine. Status: 0 deleted, dry run, or declined;
# 1 refused or failed; 2 invalid plan or no terminal without --yes;
# 130/143 interrupted.
_file_delete_execute() {
  local -a disclosures=()
  while [[ "${1-}" == "--warn" || "${1-}" == "--note" ]]; do
    (( $# >= 2 )) || return 2
    disclosures+=("$1" "$2")
    shift 2
  done
  local dry_run="$1"
  local auto_yes="$2"
  shift 2
  local -a requested_targets=("$@")

  _file_validate_base "$PWD" || return 1
  local base_dir="$REPLY"
  _file_delete_plan_targets "$base_dir" "${requested_targets[@]}" \
    || return $?
  local -a targets=("${reply[@]}")
  local identities_text="$REPLY"
  local target=""
  local noun="file" plural="files"
  # One mount snapshot serves the plan; execution takes a fresh one.
  local _file_mount_mode=""
  local -A _file_mount_targets=()
  for target in "${targets[@]}"; do
    _file_delete_mounts_clear "$target" || return 1
    [[ -d "$target" ]] && noun="target" plural="targets"
  done

  # Targets are shown relative to the base directory named above them.
  local -a plan_rows=()
  local -i index=1
  for target in "${targets[@]}"; do
    plan_rows+=("${index}"$'\t'"${target#"$base_dir"/}")
    (( ++index ))
  done
  _file_path_display "$base_dir"
  _file_label "Directory" "$REPLY"
  print -u2 -r -- ""
  _file_table $'#\tPath' "${plan_rows[@]}"
  _file_print_disclosures "${disclosures[@]}"
  _file_count_noun "${#targets[@]}" "$noun" "$plural"
  local planned="$REPLY"
  if [[ "$dry_run" == "yes" ]]; then
    _file_info "Dry run: $planned planned; nothing was deleted."
    return 0
  fi

  _file_confirm_mutation "Delete ${planned}?" "$auto_yes" \
    "Cancelled: nothing was deleted."
  local -i confirm_rc=$?
  (( confirm_rc == 0 )) || {
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  _file_delete_revalidate targets "$identities_text" || return 1
  _file_mount_mode=""
  local -a mv_command=()
  _file_mv_no_clobber_command || return 1
  mv_command=("${reply[@]}")

  local -a identities=("${(@f)identities_text}")
  local display=""
  local -i failures=0 action_rc=0
  index=1
  while (( index <= ${#targets[@]} )); do
    target="${targets[index]}"
    display="${target#"$base_dir"/}"
    action_rc=0
    _file_quarantine_delete "$target" "${identities[index]}" \
      "${mv_command[@]}" || action_rc=$?
    if (( action_rc == 0 )); then
      _file_success "Deleted $display"
    else
      _file_error "Failed (status $action_rc): $display"
      (( ++failures ))
      if (( action_rc == 130 || action_rc == 143 )); then
        _file_warn "Deletion interrupted; later ${plural} were not changed."
        if (( index < ${#targets[@]} )); then
          _file_count_noun "$(( ${#targets[@]} - index ))" "$noun" "$plural"
          _file_info "Not run: $REPLY"
        fi
        return $action_rc
      fi
    fi
    (( ++index ))
  done

  if (( failures == 0 )); then
    _file_success "Deletion completed: $planned deleted."
    return 0
  fi
  if (( failures < ${#targets[@]} )); then
    _file_error \
      "Deletion completed with partial failures: $failures of $planned failed."
    _file_mark_partial
  else
    _file_error "Deletion failed: $failures of $planned failed."
  fi
  return 1
}

typeset -g _FILE_OPERATIONS_SOURCED=1
