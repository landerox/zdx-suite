#!/usr/bin/env zsh
# =============================================================================
# Env Suite: active-variable inspection and PATH diagnostics
# =============================================================================
#
# Loaded by env-menu.zsh. Raw secret values never enter menu rows, previews,
# logs, warnings, or fallback output.
#

if [[ -n "${_ENV_VARS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_env_exported_keys() {
  emulate -L zsh
  local -a exported_keys=()
  local key="" parameter_type=""
  for key in ${(k)parameters}; do
    [[ "$key" =~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$' ]] || continue
    parameter_type="${parameters[$key]}"
    [[ "$parameter_type" == scalar* \
      && "$parameter_type" == *export* ]] || continue
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
  [[ "$key" =~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$' \
    && ${+parameters[$key]} -eq 1 ]] || {
    _env_error "No exported scalar variable named '$key' exists."
    return 1
  }
  local parameter_type="${parameters[$key]}"
  [[ "$parameter_type" == scalar* \
    && "$parameter_type" == *export* ]] || {
    _env_error "No exported scalar variable named '$key' exists."
    return 1
  }
  local value="${(P)key}"
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

env-list() {
  emulate -L zsh
  local list_mode="no"
  local copy_key=""
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      ;;
    -h|--help)
      (( $# == 1 )) || return 2
      _env_list_usage
      return 0
      ;;
    --list)
      (( $# == 1 )) || return 2
      list_mode="yes"
      ;;
    --copy)
      (( $# == 2 )) || {
        _env_error "--copy requires exactly one variable name."
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
    snapshot_types[$key]="${parameters[$key]}"
    snapshot_values[$key]="${(P)key}"
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

  [[ ${+parameters[$key]} -eq 1 \
    && "${parameters[$key]}" == "${snapshot_types[$key]}" \
    && "${(P)key}" == "${snapshot_values[$key]}" ]] || {
    _env_error "The selected variable changed while the picker was open."
    return 1
  }
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
      [[ -w "$PWD" ]] && writable_state="yes" || writable_state="no"
    elif [[ -d "$entry" ]]; then
      entry_state="exists"
      [[ -w "$entry" ]] && writable_state="yes" || writable_state="no"
    else
      entry_state="missing"
      writable_state="n/a"
    fi
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

env-path() {
  emulate -L zsh
  local list_mode="no"
  local dedupe="no"
  local dry_run="no"
  local auto_yes="no"

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _env_path_usage
        return 0
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
        _env_visible_field "$entry"
        display_entry="$REPLY"
      fi
      printf '%d\t%s\t%s\t%s\t%s\n' \
        "$index" "$display_entry" \
        "${_ENV_PATH_STATES[index]}" \
        "${_ENV_PATH_WRITABLE[index]}" \
        "${_ENV_PATH_DUPLICATE_FLAGS[index]}"
    done
    _env_clear_path_snapshot
    return 0
  fi

  if [[ "$dedupe" == "no" ]]; then
    _env_header "PATH Inspection"
    for (( index = 1; index <= ${#_ENV_PATH_ENTRIES[@]}; ++index )); do
      entry="${_ENV_PATH_ENTRIES[index]}"
      if [[ -z "$entry" ]]; then
        display_entry="<current-directory>"
      else
        _env_visible_field "$entry"
        display_entry="$REPLY"
      fi
      _env_dim \
        "$index. $display_entry | ${_ENV_PATH_STATES[index]} | writable=${_ENV_PATH_WRITABLE[index]} | duplicate=${_ENV_PATH_DUPLICATE_FLAGS[index]}"
    done
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
  _env_info "Entries before: ${#_ENV_PATH_ENTRIES[@]}"
  _env_info "Entries after: ${#_ENV_PATH_UNIQUE[@]}"
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
  _env_confirm_mutation \
    "Apply this exact PATH deduplication plan?" "$auto_yes" || {
    local -i confirm_rc=$?
    _env_clear_path_snapshot
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
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
