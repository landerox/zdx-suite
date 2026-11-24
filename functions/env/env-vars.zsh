#!/usr/bin/env zsh
# =============================================================================
# Env Vars: masked export inspection and active-shell PATH deduplication
# =============================================================================
#
# Loaded by env-menu.zsh after env-common.zsh.
# Safe to re-source; defines functions and snapshot arrays.
#
# The picker displays masked names and classifications. Explicit copy sends
# the selected value to the clipboard backend.
#

if [[ -n "${_ENV_VARS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_env_exported_keys() {
  emulate -L zsh
  local -a exported_keys=()
  local key="" parameter_type=""
  for key in ${(k)_env_export_snapshot}; do
    [[ "$key" == type:* ]] || continue
    key="${key#type:}"
    _env_is_export_name "$key" || continue
    parameter_type="${_env_export_snapshot[type:$key]-}"
    _env_export_type_is_scalar "$parameter_type" || continue
    exported_keys+=("$key")
    (( ${#exported_keys[@]} <= _ENV_MAX_RECORDS * 8 )) || {
      _env_error "The exported-variable inventory exceeds its safe limit."
      return 1
    }
  done
  reply=("${(@on)exported_keys}")
}

_env_list_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  env-list"
  print -u2 -r -- "  env-list --list"
  print -u2 -r -- "  env-list --copy VARIABLE"
  print -u2 -r -- ""
  print -u2 -r -- \
    "--list emits NAME<TAB>CLASSIFICATION records; raw values stay hidden."
  print -u2 -r -- \
    "--copy sends the exact current value to a clipboard backend without printing it."
}

_env_copy_exported_variable() {
  local key="$1"
  _env_is_export_name "$key" && [[ -n "${_env_export_snapshot[type:$key]-}" ]] || {
    _env_error "No exported scalar variable named '$key' exists."
    return 1
  }
  local parameter_type="${_env_export_snapshot[type:$key]-}"
  _env_export_type_is_scalar "$parameter_type" || {
    _env_error "No exported scalar variable named '$key' exists."
    return 1
  }
  local value="${_env_export_snapshot[value:$key]}"
  local -i copy_rc=0
  _env_copy_to_clipboard "$value" || copy_rc=$?
  if (( copy_rc == 0 )); then
    _env_success "Copied '$key' to the clipboard."
  elif (( copy_rc == 1 )); then
    _env_error \
      "No supported clipboard backend is available; the value was not printed."
    return 1
  else
    _env_error "The clipboard backend failed; the value was not printed."
    return 1
  fi
}

# Decide only whether the existing grammar needs an export snapshot. The
# implementation remains responsible for help and usage diagnostics.
_env_list_requires_snapshot() {
  case "${1:-}" in
    "") (( $# == 0 )) ;;
    --list) (( $# == 1 )) ;;
    --copy) (( $# == 2 )) && _env_is_export_name "$2" ;;
    *) return 1 ;;
  esac
}

# Capture before implementation locals; help and invalid grammar stay probe-free.
env-list() {
  emulate -L zsh
  if _env_list_requires_snapshot "$@"; then
    _env_with_export_snapshot _env_list_execute "$@"
  else
    _env_list_execute "$@"
  fi
}

_env_list_execute() {
  emulate -L zsh
  _env_record_export_shadows _env_list_execute list_mode copy_key \
    exported_keys key display_value snapshot_values snapshot_types rows index \
    selected fzf_rc selected_row_position selected_index copy_rc REPLY reply \
    MATCH MBEGIN MEND match mbegin mend
  local REPLY="" MATCH="" MBEGIN=0 MEND=0
  local -a reply=() match=() mbegin=() mend=()
  local list_mode="no"
  local copy_key=""
  case "${1:-}" in
    "")
      (( $# == 0 )) || {
        _env_error "Invalid env-list argument. The first operand is empty."
        return 2
      }
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _env_error "--help accepts no additional arguments."
        return 2
      }
      _env_list_usage
      return 0
      ;;
    --list)
      (( $# == 1 )) || {
        _env_error "--list accepts no additional arguments."
        return 2
      }
      list_mode="yes"
      ;;
    --copy)
      (( $# == 2 )) && _env_is_export_name "$2" || {
        _env_error "--copy requires exactly one valid shell variable name."
        return 2
      }
      copy_key="$2"
      ;;
    *)
      _env_error "Unknown env-list argument: $1"
      return 2
      ;;
  esac

  [[ -z "$copy_key" ]] || {
    _env_copy_exported_variable "$copy_key"
    return $?
  }

  _env_exported_keys || return 1
  local -a exported_keys=("${reply[@]}")
  local key="" display_value=""

  if [[ "$list_mode" == "yes" ]]; then
    for key in "${exported_keys[@]}"; do
      display_value=$(_env_value_classification "$key")
      printf '%s\t%s\n' "$key" "$display_value"
    done
    return 0
  fi

  local -A snapshot_values=() snapshot_types=()
  for key in "${exported_keys[@]}"; do
    snapshot_types[$key]="${_env_export_snapshot[type:$key]}"
    snapshot_values[$key]="${_env_export_snapshot[value:$key]}"
  done

  _env_require_cmd fzf "interactive environment-variable selection" \
    || return 1
  local -a rows=()
  local -i index=1
  for key in "${exported_keys[@]}"; do
    display_value=$(_env_value_classification "$key")
    rows+=("${index}|${key}|${display_value}")
    (( ++index ))
  done

  local selected=""
  local -i fzf_rc=0
  _env_fzf_capture \
    --height='70%' \
    --delimiter='[|]' \
    --with-nth=2,3 \
    --prompt='environment > ' \
    --header='Enter copy exact value | Esc cancel | secret values stay masked' \
    --preview='printf "Raw values never enter the picker or its preview.\\n"' \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    if _env_fzf_rc_is_cancel "$fzf_rc" && [[ -z "$selected" ]]; then
      return 0
    fi
    _env_error "The environment-variable picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 0
  [[ "$selected" != *$'\n'* && "$selected" != *$'\r'* ]] || {
    _env_error "Refusing malformed environment-variable picker output."
    return 1
  }
  local -i selected_row_position=0
  selected_row_position="${rows[(Ie)$selected]}"
  (( selected_row_position > 0 )) || {
    _env_error "The selected variable was not in the current snapshot."
    return 1
  }
  local selected_index="${selected%%|*}"
  [[ "$selected_index" == <-> \
    && selected_index -ge 1 \
    && selected_index -le ${#exported_keys[@]} ]] || return 1
  key="${exported_keys[selected_index]}"

  if _env_export_snapshot_matches "$key" "${snapshot_types[$key]}" \
    "${snapshot_values[$key]}"; then
    :
  else
    case $? in
      2) _env_error "The selected export could not be revalidated after the picker closed." ;;
      3) _env_error "The exported-variable snapshot was lost; no value was copied." ;;
      *) _env_error "The selected variable changed while the picker was open." ;;
    esac
    _env_dim "Use env-list --copy $key for a direct copy of the current export."
    return 1
  fi
  local -i copy_rc=0
  _env_copy_to_clipboard "${snapshot_values[$key]}" || copy_rc=$?
  if (( copy_rc == 0 )); then
    _env_success "Copied '$key' to the clipboard."
  elif (( copy_rc == 1 )); then
    _env_error \
      "No supported clipboard backend is available; the value was not printed."
    return 1
  else
    _env_error "The clipboard backend failed; the value was not printed."
    return 1
  fi
}

_env_path_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  env-path"
  print -u2 -r -- "  env-path --list"
  print -u2 -r -- "  env-path --dedupe [--dry-run] [--yes]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "--list emits INDEX<TAB>ENTRY<TAB>STATE<TAB>WRITABLE<TAB>DUPLICATE."
}

_env_path_snapshot() {
  emulate -L zsh
  local raw_path="$PATH"
  (( ${#raw_path} <= _ENV_MAX_FILE_BYTES )) || {
    _env_error "PATH exceeds the Environment inspection size limit."
    return 1
  }
  local -a path_entries=("${(@s/:/)raw_path}")
  (( ${#path_entries[@]} > 0 )) || path_entries=("")
  (( ${#path_entries[@]} <= _ENV_MAX_RECORDS )) || {
    _env_error "PATH exceeds the Environment entry limit."
    return 1
  }

  # Entries are compared without trailing slashes, so /x/ duplicates /x.
  # Map keys carry a "=" prefix so the empty entry is never an empty key.
  # Entries that differ only by letter case name one directory on a
  # case-insensitive filesystem, such as macOS's default or a Windows drive,
  # but two on Linux; they are reported and kept.
  local -a unique_entries=() duplicate_entries=() duplicate_matches=()
  local -a case_variants=() case_matches=()
  local -a entry_states=() entry_writable=() entry_duplicates=()
  local -A first_by_key=() first_by_folded_key=()
  local entry="" entry_state="" writable_state="" entry_key=""
  local duplicate_state=""
  for entry in "${path_entries[@]}"; do
    entry_key="$entry"
    while [[ "$entry_key" == */ && "$entry_key" != / ]]; do
      entry_key="${entry_key%/}"
    done
    if (( ${+first_by_key[=$entry_key]} )); then
      duplicate_state="yes"
      duplicate_entries+=("$entry")
      duplicate_matches+=("${first_by_key[=$entry_key]}")
    else
      duplicate_state="no"
      unique_entries+=("$entry")
      first_by_key[=$entry_key]="$entry"
      if [[ -n "$entry_key" ]]; then
        if (( ${+first_by_folded_key[=${(L)entry_key}]} )); then
          case_variants+=("$entry")
          case_matches+=("${first_by_folded_key[=${(L)entry_key}]}")
        else
          first_by_folded_key[=${(L)entry_key}]="$entry"
        fi
      fi
    fi

    if [[ -z "$entry" ]]; then
      entry_state="current-directory"
      [[ -w . ]] && writable_state="yes" || writable_state="no"
    elif [[ -d "$entry" ]]; then
      entry_state="exists"
      [[ -w "$entry" ]] && writable_state="yes" || writable_state="no"
    else
      entry_state="missing"
      writable_state="n/a"
    fi
    [[ -n "$entry" && "$entry" != /* ]] && entry_state="relative"
    entry_states+=("$entry_state")
    entry_writable+=("$writable_state")
    entry_duplicates+=("$duplicate_state")
  done

  _ENV_PATH_ENTRIES=("${path_entries[@]}")
  _ENV_PATH_UNIQUE=("${unique_entries[@]}")
  _ENV_PATH_DUPLICATES=("${duplicate_entries[@]}")
  _ENV_PATH_DUPLICATE_MATCHES=("${duplicate_matches[@]}")
  _ENV_PATH_CASE_VARIANTS=("${case_variants[@]}")
  _ENV_PATH_CASE_MATCHES=("${case_matches[@]}")
  _ENV_PATH_STATES=("${entry_states[@]}")
  _ENV_PATH_WRITABLE=("${entry_writable[@]}")
  _ENV_PATH_DUPLICATE_FLAGS=("${entry_duplicates[@]}")
}

typeset -ga _ENV_PATH_ENTRIES=()
typeset -ga _ENV_PATH_UNIQUE=()
typeset -ga _ENV_PATH_DUPLICATES=()
typeset -ga _ENV_PATH_DUPLICATE_MATCHES=()
typeset -ga _ENV_PATH_CASE_VARIANTS=()
typeset -ga _ENV_PATH_CASE_MATCHES=()
typeset -ga _ENV_PATH_STATES=()
typeset -ga _ENV_PATH_WRITABLE=()
typeset -ga _ENV_PATH_DUPLICATE_FLAGS=()

_env_clear_path_snapshot() {
  _ENV_PATH_ENTRIES=()
  _ENV_PATH_UNIQUE=()
  _ENV_PATH_DUPLICATES=()
  _ENV_PATH_DUPLICATE_MATCHES=()
  _ENV_PATH_CASE_VARIANTS=()
  _ENV_PATH_CASE_MATCHES=()
  _ENV_PATH_STATES=()
  _ENV_PATH_WRITABLE=()
  _ENV_PATH_DUPLICATE_FLAGS=()
}

# REPLY is a PATH entry as shown to a person: escaped, with an empty entry
# named as the current directory.
_env_path_display() {
  if [[ -z "${1-}" ]]; then
    REPLY="<current-directory>"
  else
    _env_visible_field "$1"
  fi
}

# Reports the snapshot's entries that differ from an earlier entry only by
# letter case. Deduplication never removes them.
_env_path_report_case_variants() {
  local -i count=${#_ENV_PATH_CASE_VARIANTS[@]} index=1
  (( count > 0 )) || return 0
  local variant_display=""
  if (( count == 1 )); then
    _env_warn \
      "1 PATH entry differs from an earlier entry only by letter case; deduplication keeps it."
  else
    _env_warn \
      "$count PATH entries differ from earlier entries only by letter case; deduplication keeps them."
  fi
  for (( index = 1; index <= count; ++index )); do
    _env_path_display "${_ENV_PATH_CASE_VARIANTS[index]}"
    variant_display="$REPLY"
    _env_path_display "${_ENV_PATH_CASE_MATCHES[index]}"
    _env_dim "$variant_display matches $REPLY"
  done
}

_env_path_report_relative_entries() {
  local -i count=0
  local entry_state=""
  for entry_state in "${_ENV_PATH_STATES[@]}"; do
    case "$entry_state" in
      relative|current-directory) (( ++count )) ;;
    esac
  done
  (( count > 0 )) || return 0
  _env_count_noun "$count" "PATH entry" "PATH entries"
  _env_warn "Detected $REPLY resolved from the current directory."
}

env-path() {
  emulate -L zsh
  if (( $# == 1 )) && [[ "$1" == (-h|--help) ]]; then
    _env_path_usage
    return 0
  fi
  local list_mode="no"
  local dedupe="no"
  local dry_run="no"
  local auto_yes="no"

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        _env_error "--help accepts no additional arguments."
        return 2
        ;;
      --list) list_mode="yes" ;;
      --dedupe) dedupe="yes" ;;
      --dry-run) dry_run="yes" ;;
      --yes) auto_yes="yes" ;;
      *)
        _env_error "Unknown env-path option: $1"
        return 2
        ;;
    esac
    shift
  done
  [[ "$list_mode" == "no" || "$dedupe" == "no" ]] || {
    _env_error "--list and --dedupe are separate modes."
    return 2
  }
  [[ "$dedupe" == "yes" \
    || ( "$dry_run" == "no" && "$auto_yes" == "no" ) ]] || {
    _env_error "--dry-run and --yes require --dedupe."
    return 2
  }

  local original_path="$PATH"
  _env_path_snapshot || return 1
  local -i index=1
  local entry="" display_entry=""

  if [[ "$list_mode" == "yes" ]]; then
    for (( index = 1; index <= ${#_ENV_PATH_ENTRIES[@]}; ++index )); do
      entry="${_ENV_PATH_ENTRIES[index]}"
      if [[ -z "$entry" ]]; then
        display_entry="<current-directory>"
      else
        display_entry="${(V)entry}"
      fi
      printf '%d\t%s\t%s\t%s\t%s\n' \
        "$index" "$display_entry" \
        "${_ENV_PATH_STATES[index]}" \
        "${_ENV_PATH_WRITABLE[index]}" \
        "${_ENV_PATH_DUPLICATE_FLAGS[index]}"
    done
    _env_path_report_relative_entries
    _env_clear_path_snapshot
    return 0
  fi

  if [[ "$dedupe" == "no" ]]; then
    _env_header "PATH Inspection"
    local -a rows=()
    local row=""
    for (( index = 1; index <= ${#_ENV_PATH_ENTRIES[@]}; ++index )); do
      entry="${_ENV_PATH_ENTRIES[index]}"
      _env_path_display "$entry"
      row="$index"$'\t'"$REPLY"$'\t'"${_ENV_PATH_STATES[index]}"
      row+=$'\t'"${_ENV_PATH_WRITABLE[index]}"$'\t'"${_ENV_PATH_DUPLICATE_FLAGS[index]}"
      rows+=("$row")
    done
    _env_table $'#\tEntry\tState\tWritable\tDuplicate' "${rows[@]}"
    _env_path_report_relative_entries
    if (( ${#_ENV_PATH_DUPLICATES[@]} > 0 )); then
      _env_count_noun "${#_ENV_PATH_DUPLICATES[@]}" \
        "duplicate PATH entry" "duplicate PATH entries"
      _env_warn "Detected $REPLY."
      _env_info "Review removal with: env-path --dedupe --dry-run"
    else
      _env_success "No duplicate PATH entries were detected."
    fi
    _env_path_report_case_variants
    _env_clear_path_snapshot
    return 0
  fi

  _env_header "PATH Deduplication Plan"
  _env_label "Entries before" "${#_ENV_PATH_ENTRIES[@]}"
  _env_label "Entries after" "${#_ENV_PATH_UNIQUE[@]}"
  _env_path_report_relative_entries
  if (( ${#_ENV_PATH_DUPLICATES[@]} == 0 )); then
    _env_path_report_case_variants
    _env_success "PATH is already deduplicated."
    _env_clear_path_snapshot
    return 0
  fi
  local match_display=""
  for (( index = 1; index <= ${#_ENV_PATH_DUPLICATES[@]}; ++index )); do
    entry="${_ENV_PATH_DUPLICATES[index]}"
    _env_path_display "$entry"
    display_entry="$REPLY"
    if [[ "$entry" == "${_ENV_PATH_DUPLICATE_MATCHES[index]}" ]]; then
      _env_dim "remove later duplicate: $display_entry"
    else
      _env_path_display "${_ENV_PATH_DUPLICATE_MATCHES[index]}"
      match_display="$REPLY"
      _env_dim "remove later duplicate: $display_entry (same as $match_display)"
    fi
  done
  _env_path_report_case_variants
  if [[ "$dry_run" == "yes" ]]; then
    _env_info "Dry run only; PATH was not changed."
    _env_clear_path_snapshot
    return 0
  fi
  local REPLY=""
  _env_confirm_mutation \
    "Apply this exact PATH deduplication plan?" "$auto_yes" || {
    local -i confirm_rc=$?
    _env_clear_path_snapshot
    return $confirm_rc
  }
  if [[ "$REPLY" != confirmed ]]; then
    _env_clear_path_snapshot
    [[ "$REPLY" == declined ]] && return 0
    _env_error "Could not verify the PATH confirmation result."
    return 1
  fi
  [[ "$PATH" == "$original_path" ]] || {
    _env_error "PATH changed after review; refusing to apply a stale plan."
    _env_clear_path_snapshot
    return 1
  }
  export PATH="${(j/:/)_ENV_PATH_UNIQUE}"
  _env_clear_path_snapshot
  _env_success "PATH was deduplicated in the active shell."
}

typeset -g _ENV_VARS_SOURCED=1
