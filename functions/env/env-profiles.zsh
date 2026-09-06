#!/usr/bin/env zsh
# =============================================================================
# Env Suite: private environment-profile state and transactions
# =============================================================================
#
# Loaded by env-menu.zsh. Profiles are passive owner-only data below HOME.
# Values never enter interactive rows, previews, plans, or diagnostic output.
#

if [[ -n "${_ENV_PROFILES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -ga _ENV_PROFILE_NAMES=()
typeset -ga _ENV_PROFILE_FILES=()
typeset -ga _ENV_PROFILE_COUNTS=()
typeset -ga _ENV_PROFILE_FINGERPRINTS=()

_env_clear_profile_inventory() {
  _ENV_PROFILE_NAMES=()
  _ENV_PROFILE_FILES=()
  _ENV_PROFILE_COUNTS=()
  _ENV_PROFILE_FINGERPRINTS=()
}

_env_profile_name_valid() {
  [[ "$1" =~ '^[a-z0-9][a-z0-9_-]{0,63}$' ]]
}

_env_profile_dir() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local access_mode="${1:-read}"
  case "$access_mode" in
    read|plan|create) ;;
    *) return 2 ;;
  esac

  local home_root="${HOME:a}"
  [[ -n "${HOME:-}" \
    && "$home_root" == "${HOME:A}" \
    && "$home_root" != "/" \
    && -d "$home_root" && ! -L "$home_root" ]] || {
    _env_error "HOME is not a trusted real directory."
    return 1
  }
  local -A home_state=()
  zstat -LH home_state -- "$home_root" 2>/dev/null || return 1
  (( (home_state[mode] & 8#170000) == 8#040000 \
    && home_state[uid] == EUID \
    && (home_state[mode] & 8#22) == 0 )) || {
    _env_error "HOME has unsafe ownership or permissions."
    return 1
  }
  _env_validate_ancestor_chain "$home_root" || return 1

  local configured_root="${ZDX_ENV_PROFILES_DIR:-}"
  if [[ -z "$configured_root" ]]; then
    local config_root="${XDG_CONFIG_HOME:-$home_root/.config}"
    [[ "$config_root" == /* ]] || {
      _env_error "XDG_CONFIG_HOME must be absolute when it selects profile state."
      return 1
    }
    configured_root="$config_root/zdx/env-profiles"
  elif [[ "$configured_root" != /* ]]; then
    _env_error "ZDX_ENV_PROFILES_DIR must be an absolute path below HOME."
    return 1
  fi
  local profile_root="${configured_root:a}"
  [[ "$profile_root" == "$home_root"/* \
    && "$profile_root" == "${profile_root:A}" \
    && "$profile_root" != *$'\n'* \
    && "$profile_root" != *$'\r'* \
    && "$profile_root" != *[[:cntrl:]]* ]] || {
    _env_error "The profile directory must be a displayable child of HOME."
    return 1
  }

  if [[ "$access_mode" == "plan" \
    && ! -e "$profile_root" && ! -L "$profile_root" ]]; then
    local relative_plan="${profile_root#$home_root/}"
    local -a plan_components=("${(@s:/:)relative_plan}")
    local plan_component="" plan_dir="$home_root"
    local -A plan_state=()
    for plan_component in "${plan_components[@]}"; do
      plan_dir="$plan_dir/$plan_component"
      [[ -e "$plan_dir" || -L "$plan_dir" ]] || break
      plan_state=()
      [[ -d "$plan_dir" && ! -L "$plan_dir" \
        && "$plan_dir" == "${plan_dir:A}" ]] \
        && zstat -LH plan_state -- "$plan_dir" 2>/dev/null \
        && (( (plan_state[mode] & 8#170000) == 8#040000 \
          && plan_state[uid] == EUID \
          && (plan_state[mode] & 8#22) == 0 )) || {
        _env_error "A planned profile directory component is unsafe."
        return 1
      }
    done
    REPLY="$profile_root"
    return 0
  fi
  if [[ "$access_mode" == "read" \
    && ! -e "$profile_root" && ! -L "$profile_root" ]]; then
    REPLY="$profile_root"
    return 3
  fi

  if [[ "$access_mode" == "create" ]]; then
    local relative_root="${profile_root#$home_root/}"
    local -a components=("${(@s:/:)relative_root}")
    local component="" current_dir="$home_root"
    local -A component_state=()
    for component in "${components[@]}"; do
      [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
        || return 1
      current_dir="$current_dir/$component"
      if [[ ! -e "$current_dir" && ! -L "$current_dir" ]]; then
        command mkdir -m 700 "$current_dir" 2>/dev/null || {
          _env_error "Could not create the private profile directory."
          return 1
        }
      fi
      component_state=()
      [[ -d "$current_dir" && ! -L "$current_dir" \
        && "$current_dir" == "${current_dir:A}" ]] \
        && zstat -LH component_state -- "$current_dir" 2>/dev/null \
        && (( (component_state[mode] & 8#170000) == 8#040000 \
          && component_state[uid] == EUID \
          && (component_state[mode] & 8#22) == 0 )) || {
        _env_error "A profile state directory component is unsafe."
        return 1
      }
    done
  fi

  local -A profile_state=()
  [[ -d "$profile_root" && ! -L "$profile_root" \
    && "$profile_root" == "${profile_root:A}" ]] \
    && zstat -LH profile_state -- "$profile_root" 2>/dev/null \
    && (( (profile_state[mode] & 8#170000) == 8#040000 \
      && profile_state[uid] == EUID \
      && (profile_state[mode] & 8#777) == 8#700 )) || {
    _env_error \
      "The profile directory must be owned, symlink-free, and mode 700."
    return 1
  }
  _env_validate_ancestor_chain "$profile_root" || return 1
  REPLY="$profile_root"
}

_env_profile_inventory() {
  emulate -L zsh
  local profile_root="$1"
  _env_clear_profile_inventory
  local -a profile_files=("$profile_root"/*.env(N))
  local profile_file="" profile_name=""
  for profile_file in "${profile_files[@]}"; do
    profile_name="${profile_file:t:r}"
    _env_profile_name_valid "$profile_name" || {
      _env_warn "Excluded a profile with an invalid name."
      continue
    }
    _env_parse_file "$profile_file" profile "$profile_root" || {
      _env_warn "Excluded unsafe or invalid profile '$profile_name'."
      continue
    }
    _ENV_PROFILE_NAMES+=("$profile_name")
    _ENV_PROFILE_FILES+=("$_ENV_PARSED_FILE")
    _ENV_PROFILE_COUNTS+=("${#_ENV_PARSED_KEYS[@]}")
    _ENV_PROFILE_FINGERPRINTS+=("$_ENV_PARSED_FINGERPRINT")
    _env_clear_parsed
    (( ${#_ENV_PROFILE_NAMES[@]} <= _ENV_MAX_CANDIDATES )) || {
      _env_error "The profile inventory exceeds its safe limit."
      _env_clear_profile_inventory
      return 1
    }
  done
}

_env_select_profile() {
  local prompt="$1"
  (( ${#_ENV_PROFILE_NAMES[@]} > 0 )) || return 130
  _env_require_cmd fzf "interactive profile selection" || return 1
  local -a rows=()
  local -i index=1
  for (( index = 1; index <= ${#_ENV_PROFILE_NAMES[@]}; ++index )); do
    rows+=("${index}|${_ENV_PROFILE_NAMES[index]}|${_ENV_PROFILE_COUNTS[index]} variables")
  done

  local selected=""
  local -i fzf_rc=0
  _env_fzf_capture \
    --height='50%' \
    --delimiter='[|]' \
    --with-nth=2,3 \
    --prompt="${prompt} > " \
    --header='Enter review exact plan | Esc cancel | values stay hidden' \
    --preview='printf "Profile values are intentionally hidden.\\n"' \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    if _env_fzf_rc_is_cancel "$fzf_rc" && [[ -z "$selected" ]]; then
      return 130
    fi
    _env_error "The profile picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 130
  [[ "$selected" != *$'\n'* && "$selected" != *$'\r'* ]] || {
    _env_error "Refusing malformed profile picker output."
    return 1
  }
  local -i selected_row_position=0
  selected_row_position="${rows[(Ie)$selected]}"
  (( selected_row_position > 0 )) || {
    _env_error "The selected profile was not in the current snapshot."
    return 1
  }
  local selected_index="${selected%%|*}"
  [[ "$selected_index" == <-> \
    && selected_index -ge 1 \
    && selected_index -le ${#_ENV_PROFILE_NAMES[@]} ]] || return 1
  REPLY="$selected_index"
}

_env_profile_save_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  env-profile-save [--overwrite] [--dry-run] [--yes]"
  print -u2 -r -- \
    "                   [--] [PROFILE [VARIABLE...]]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Omitted operands are collected interactively. Profiles use mode 600."
}

_env_select_profile_variables() {
  _env_exported_keys || return 1
  local -a exported_keys=("${reply[@]}")
  _env_require_cmd fzf "interactive profile-variable selection" || return 1

  local -a rows=()
  local -a eligible_keys=()
  local -i index=1
  local key="" classification="" parameter_type=""
  for key in "${exported_keys[@]}"; do
    parameter_type="${parameters[$key]}"
    _env_key_valid "$key" \
      && [[ "$parameter_type" == scalar* \
        && "$parameter_type" == *export* \
        && "$parameter_type" != *special* \
        && "$parameter_type" != *local* \
        && "$parameter_type" != *readonly* ]] || continue
    _env_key_is_sensitive "$key" \
      && classification="secret value hidden" \
      || classification="value hidden"
    eligible_keys+=("$key")
    rows+=("${index}|${key}|${classification}")
    (( ++index ))
  done

  local selected=""
  local -i fzf_rc=0
  _env_fzf_capture \
    --height='70%' \
    --multi \
    --delimiter='[|]' \
    --with-nth=2,3 \
    --prompt='profile variables > ' \
    --header='Tab select multiple | Enter confirm | values stay hidden' \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    if _env_fzf_rc_is_cancel "$fzf_rc" && [[ -z "$selected" ]]; then
      return 130
    fi
    _env_error "The profile-variable picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 130

  local -a selected_rows=("${(@f)selected}")
  local -a selected_keys=()
  local selected_row="" selected_index=""
  local -i selected_row_position=0
  for selected_row in "${selected_rows[@]}"; do
    selected_row_position="${rows[(Ie)$selected_row]}"
    (( selected_row_position > 0 )) || {
      _env_error "A selected variable was not in the current snapshot."
      return 1
    }
    selected_index="${selected_row%%|*}"
    [[ "$selected_index" == <-> \
      && selected_index -ge 1 \
      && selected_index -le ${#eligible_keys[@]} ]] || return 1
    selected_keys+=("${eligible_keys[selected_index]}")
  done
  reply=("${selected_keys[@]}")
}

env-profile-save() {
  emulate -L zsh
  local overwrite="no"
  local dry_run="no"
  local auto_yes="no"
  local operands_only="no"
  local -a operands=()

  while (( $# > 0 )); do
    if [[ "$operands_only" == "yes" ]]; then
      operands+=("$1")
      shift
      continue
    fi
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _env_profile_save_usage
        return 0
        ;;
      --overwrite) overwrite="yes" ;;
      --dry-run) dry_run="yes" ;;
      --yes) auto_yes="yes" ;;
      --) operands_only="yes" ;;
      -*)
        _env_error "Unknown env-profile-save option: $1"
        return 2
        ;;
      *) operands+=("$1") ;;
    esac
    shift
  done

  local profile_name="${operands[1]:-}"
  local -a variable_names=()
  (( ${#operands[@]} >= 2 )) \
    && variable_names=("${(@)operands[2,-1]}")
  if [[ -z "$profile_name" ]]; then
    [[ -t 0 && -t 2 ]] || {
      _env_error "A profile name is required outside a terminal."
      return 2
    }
    printf '? Profile name: ' >&2
    IFS= read -r profile_name || {
      _env_info "Cancelled before any profile state was changed."
      return 0
    }
  fi
  _env_profile_name_valid "$profile_name" || {
    _env_error \
      "Profile names must match [a-z0-9][a-z0-9_-]{0,63}."
    return 2
  }

  if (( ${#variable_names[@]} == 0 )); then
    _env_select_profile_variables || {
      local -i select_rc=$?
      (( select_rc == 130 )) && return 0
      return $select_rc
    }
    variable_names=("${reply[@]}")
  fi
  (( ${#variable_names[@]} > 0 \
    && ${#variable_names[@]} <= _ENV_MAX_RECORDS )) || {
    _env_error "Select between 1 and $_ENV_MAX_RECORDS variables."
    return 2
  }

  local -A seen_variables=()
  local -a captured_values=() captured_types=()
  local key="" parameter_type="" value=""
  for key in "${variable_names[@]}"; do
    _env_key_valid "$key" && (( ${+parameters[$key]} )) || {
      _env_error "No exported scalar variable named '$key' exists."
      return 1
    }
    parameter_type="${parameters[$key]}"
    [[ "$parameter_type" == scalar* \
      && "$parameter_type" == *export* \
      && "$parameter_type" != *special* \
      && "$parameter_type" != *local* \
      && "$parameter_type" != *readonly* ]] || {
      _env_error "Variable '$key' cannot be restored safely from a profile."
      return 1
    }
    (( ! ${+seen_variables[$key]} )) || {
      _env_error "Duplicate variable '$key' in the profile plan."
      return 2
    }
    seen_variables[$key]=1
    value="${(P)key}"
    _env_value_persistable "$value" || {
      _env_error \
        "Variable '$key' contains controls or edge whitespace unsupported by profiles."
      return 1
    }
    captured_values+=("$value")
    captured_types+=("$parameter_type")
  done

  _env_profile_dir plan || return 1
  local planned_root="$REPLY"
  local profile_file="$planned_root/$profile_name.env"
  local expected_fingerprint=""
  if [[ -e "$profile_file" || -L "$profile_file" ]]; then
    [[ "$overwrite" == "yes" ]] || {
      _env_error "Profile '$profile_name' exists; pass --overwrite to review replacement."
      return 1
    }
    _env_validate_regular_file \
      "$profile_file" "$planned_root" private || return 1
    _env_file_fingerprint "$profile_file" || return 1
    expected_fingerprint="$REPLY"
  elif [[ "$overwrite" == "yes" ]]; then
    _env_error "--overwrite requires an existing safe profile."
    return 2
  fi

  _env_header "Profile Save Plan"
  _env_info "Profile: $profile_name"
  _env_info "File: $profile_file"
  _env_info "Publication: $([[ "$overwrite" == yes ]] && print replace || print create)"
  _env_info "Mode: directory 700, file 600"
  for key in "${variable_names[@]}"; do
    _env_key_is_sensitive "$key" \
      && _env_dim "$key [secret value hidden]" \
      || _env_dim "$key [value hidden]"
  done
  if [[ "$dry_run" == "yes" ]]; then
    _env_info "Dry run only; no profile state was created or changed."
    return 0
  fi
  _env_confirm_mutation \
    "Persist this exact private profile?" "$auto_yes" || {
    local -i confirm_rc=$?
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }

  local -i index=1
  for (( index = 1; index <= ${#variable_names[@]}; ++index )); do
    key="${variable_names[index]}"
    if (( ! ${+parameters[$key]} )) \
      || [[ "${parameters[$key]}" != "${captured_types[index]}" \
        || "${(P)key}" != "${captured_values[index]}" ]]; then
      _env_error \
        "Variable '$key' changed after review; refusing a stale profile plan."
      return 1
    fi
  done

  _env_profile_dir create || return 1
  local profile_root="$REPLY"
  [[ "$profile_root" == "$planned_root" ]] || {
    _env_error "The profile root changed after review."
    return 1
  }
  local -a content_lines=("# zdx-environment-profile-v1")
  for (( index = 1; index <= ${#variable_names[@]}; ++index )); do
    content_lines+=("${variable_names[index]}=${captured_values[index]}")
  done
  _env_atomic_publish_lines \
    "$profile_file" "$overwrite" "$expected_fingerprint" content_lines \
    || return 1
  _env_success "Saved private environment profile '$profile_name'."
}

_env_profile_list_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  env-profile-list [--list]"
  print -u2 -r -- ""
  print -u2 -r -- "--list emits PROFILE<TAB>VARIABLE_COUNT records."
}

env-profile-list() {
  emulate -L zsh
  local list_mode="no"
  case "${1:-}" in
    "") (( $# == 0 )) || return 2 ;;
    -h|--help)
      (( $# == 1 )) || return 2
      _env_profile_list_usage
      return 0
      ;;
    --list)
      (( $# == 1 )) || return 2
      list_mode="yes"
      ;;
    *)
      _env_error "Unknown env-profile-list argument: $1"
      return 2
      ;;
  esac

  local -i profile_dir_rc=0
  _env_profile_dir read || profile_dir_rc=$?
  if (( profile_dir_rc == 3 )); then
    [[ "$list_mode" == "yes" ]] \
      || _env_info "No environment profiles exist."
    return 0
  elif (( profile_dir_rc != 0 )); then
    return $profile_dir_rc
  fi
  local profile_root="$REPLY"
  _env_profile_inventory "$profile_root" || return 1

  local -i index=1
  if [[ "$list_mode" == "yes" ]]; then
    for (( index = 1; index <= ${#_ENV_PROFILE_NAMES[@]}; ++index )); do
      printf '%s\t%s\n' \
        "${_ENV_PROFILE_NAMES[index]}" "${_ENV_PROFILE_COUNTS[index]}"
    done
    _env_clear_profile_inventory
    return 0
  fi
  _env_header "Environment Profiles"
  if (( ${#_ENV_PROFILE_NAMES[@]} == 0 )); then
    _env_info "No safe environment profiles exist."
  else
    for (( index = 1; index <= ${#_ENV_PROFILE_NAMES[@]}; ++index )); do
      _env_dim \
        "${_ENV_PROFILE_NAMES[index]} | ${_ENV_PROFILE_COUNTS[index]} variable(s)"
    done
  fi
  _env_clear_profile_inventory
}

_env_profile_load_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  env-profile-load [--dry-run] [--yes] [--] [PROFILE]"
}

env-profile-load() {
  emulate -L zsh
  local dry_run="no"
  local auto_yes="no"
  local profile_name=""
  local operands_only="no"

  while (( $# > 0 )); do
    if [[ "$operands_only" == "yes" ]]; then
      [[ -z "$profile_name" ]] || return 2
      profile_name="$1"
      shift
      continue
    fi
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _env_profile_load_usage
        return 0
        ;;
      --dry-run) dry_run="yes" ;;
      --yes) auto_yes="yes" ;;
      --) operands_only="yes" ;;
      -*)
        _env_error "Unknown env-profile-load option: $1"
        return 2
        ;;
      *)
        [[ -z "$profile_name" ]] || return 2
        profile_name="$1"
        ;;
    esac
    shift
  done
  [[ -z "$profile_name" ]] || _env_profile_name_valid "$profile_name" || {
    _env_error "Invalid profile name."
    return 2
  }

  _env_profile_dir read || {
    local -i profile_dir_rc=$?
    (( profile_dir_rc == 3 )) \
      && _env_error "No environment profiles exist."
    return 1
  }
  local profile_root="$REPLY"
  _env_profile_inventory "$profile_root" || return 1
  (( ${#_ENV_PROFILE_NAMES[@]} > 0 )) || {
    _env_error "No safe environment profiles exist."
    return 1
  }

  local -i selected_index=0
  if [[ -z "$profile_name" ]]; then
    _env_select_profile "load profile" || {
      local -i select_rc=$?
      _env_clear_profile_inventory
      (( select_rc == 130 )) && return 0
      return $select_rc
    }
    selected_index=$REPLY
  else
    selected_index=${_ENV_PROFILE_NAMES[(Ie)$profile_name]}
    (( selected_index > 0 )) || {
      _env_clear_profile_inventory
      _env_error "No safe profile named '$profile_name' exists."
      return 1
    }
  fi
  local profile_file="${_ENV_PROFILE_FILES[selected_index]}"
  _env_clear_profile_inventory
  _env_parse_file "$profile_file" profile "$profile_root" || return 1
  _env_apply_parsed "$profile_file" "$dry_run" "$auto_yes"
}

_env_profile_delete_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  env-profile-delete [--dry-run] [--yes] [--] [PROFILE]"
}

_env_delete_profile_file() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local profile_file="$1"
  local expected_fingerprint="$2"
  local profile_root="${profile_file:h}"
  _env_profile_dir read || return 1
  [[ "$REPLY" == "$profile_root" ]] || {
    _env_error "The profile root changed after authorization."
    return 1
  }
  local quarantine_dir=""
  quarantine_dir=$(umask 077; command mktemp -d \
    "$profile_root/.zdx-env-delete.XXXXXX" 2>/dev/null) || {
    _env_error "Could not create a private profile quarantine."
    return 1
  }
  local -A quarantine_state=() current_quarantine_state=()
  if [[ "$quarantine_dir" != "${quarantine_dir:a}" \
    || "$quarantine_dir" != "${quarantine_dir:A}" \
    || "${quarantine_dir:h}" != "$profile_root" \
    || "${quarantine_dir:t}" != .zdx-env-delete.* \
    || ! -d "$quarantine_dir" || -L "$quarantine_dir" ]] \
    || ! zstat -LH quarantine_state -- "$quarantine_dir" 2>/dev/null \
    || (( (quarantine_state[mode] & 8#170000) != 8#040000 \
      || quarantine_state[uid] != EUID \
      || (quarantine_state[mode] & 8#777) != 8#700 )); then
    _env_error "Refusing an unsafe profile quarantine."
    return 1
  fi
  local quarantine_identity="${quarantine_state[device]}:${quarantine_state[inode]}:${quarantine_state[mode]}:${quarantine_state[uid]}"
  local quarantined_file="$quarantine_dir/profile.env"
  local quarantined_fingerprint=""
  local -i delete_rc=1 retain_recovery=0 moved=0
  {
    _env_file_fingerprint "$profile_file" || return 1
    [[ "$REPLY" == "$expected_fingerprint" ]] || {
      _env_error "The reviewed profile changed before deletion."
      return 1
    }
    command mv "$profile_file" "$quarantined_file" || return 1
    moved=1
    _env_revalidate_moved_file "$quarantined_file" "$expected_fingerprint" || {
      retain_recovery=1
      _env_error "The quarantined profile did not match the reviewed file."
      return 1
    }
    quarantined_fingerprint="$REPLY"
    command rm -f "$quarantined_file" 2>/dev/null || {
      retain_recovery=1
      _env_error "Could not remove the quarantined profile."
      return 1
    }
    moved=0
    delete_rc=0
  } always {
    if (( moved == 1 && retain_recovery == 0 )); then
      if _env_file_fingerprint "$quarantined_file" \
        && [[ -n "$quarantined_fingerprint" && "$REPLY" == "$quarantined_fingerprint" \
          && ! -e "$profile_file" && ! -L "$profile_file" ]] \
        && command mv "$quarantined_file" "$profile_file" 2>/dev/null; then
        moved=0
      else
        retain_recovery=1
      fi
    fi
    if (( retain_recovery == 0 )); then
      current_quarantine_state=()
      if [[ -d "$quarantine_dir" && ! -L "$quarantine_dir" ]] \
        && zstat -LH current_quarantine_state \
          -- "$quarantine_dir" 2>/dev/null \
        && [[ "${current_quarantine_state[device]}:${current_quarantine_state[inode]}:${current_quarantine_state[mode]}:${current_quarantine_state[uid]}" \
          == "$quarantine_identity" ]]; then
        command rmdir "$quarantine_dir" 2>/dev/null || delete_rc=1
      else
        _env_warn "The profile quarantine changed; refusing cleanup."
        delete_rc=1
      fi
    else
      _env_warn "Profile recovery data was retained at: $quarantine_dir"
    fi
  }
  return $delete_rc
}

env-profile-delete() {
  emulate -L zsh
  local dry_run="no"
  local auto_yes="no"
  local profile_name=""
  local operands_only="no"

  while (( $# > 0 )); do
    if [[ "$operands_only" == "yes" ]]; then
      [[ -z "$profile_name" ]] || return 2
      profile_name="$1"
      shift
      continue
    fi
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _env_profile_delete_usage
        return 0
        ;;
      --dry-run) dry_run="yes" ;;
      --yes) auto_yes="yes" ;;
      --) operands_only="yes" ;;
      -*)
        _env_error "Unknown env-profile-delete option: $1"
        return 2
        ;;
      *)
        [[ -z "$profile_name" ]] || return 2
        profile_name="$1"
        ;;
    esac
    shift
  done
  [[ -z "$profile_name" ]] || _env_profile_name_valid "$profile_name" || {
    _env_error "Invalid profile name."
    return 2
  }

  _env_profile_dir read || {
    _env_error "No safe environment profile directory exists."
    return 1
  }
  local profile_root="$REPLY"
  _env_profile_inventory "$profile_root" || return 1
  (( ${#_ENV_PROFILE_NAMES[@]} > 0 )) || {
    _env_error "No safe environment profiles exist."
    return 1
  }

  local -i selected_index=0
  if [[ -z "$profile_name" ]]; then
    _env_select_profile "delete profile" || {
      local -i select_rc=$?
      _env_clear_profile_inventory
      (( select_rc == 130 )) && return 0
      return $select_rc
    }
    selected_index=$REPLY
  else
    selected_index=${_ENV_PROFILE_NAMES[(Ie)$profile_name]}
    (( selected_index > 0 )) || {
      _env_clear_profile_inventory
      _env_error "No safe profile named '$profile_name' exists."
      return 1
    }
  fi
  local profile_file="${_ENV_PROFILE_FILES[selected_index]}"
  local expected_fingerprint="${_ENV_PROFILE_FINGERPRINTS[selected_index]}"
  profile_name="${_ENV_PROFILE_NAMES[selected_index]}"
  _env_clear_profile_inventory

  _env_header "Profile Deletion Plan"
  _env_info "Profile: $profile_name"
  _env_dim "delete exact file: $profile_file"
  if [[ "$dry_run" == "yes" ]]; then
    _env_info "Dry run only; no profile was deleted."
    return 0
  fi
  _env_confirm_mutation \
    "Delete this exact private profile?" "$auto_yes" || {
    local -i confirm_rc=$?
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  _env_delete_profile_file "$profile_file" "$expected_fingerprint" \
    || return 1
  _env_success "Deleted environment profile '$profile_name'."
}

typeset -g _ENV_PROFILES_SOURCED=1
