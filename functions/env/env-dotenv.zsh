#!/usr/bin/env zsh
# =============================================================================
# Env Suite: passive dotenv parsing, loading, discovery, and creation
# =============================================================================
#
# Loaded by env-menu.zsh. Dotenv and profile files are passive data: this
# module never evaluates, sources, or expands their contents.
#

if [[ -n "${_ENV_DOTENV_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -ga _ENV_PARSED_KEYS=()
typeset -ga _ENV_PARSED_VALUES=()
typeset -g _ENV_PARSED_FILE=""
typeset -g _ENV_PARSED_FINGERPRINT=""

_env_clear_parsed() {
  _ENV_PARSED_KEYS=()
  _ENV_PARSED_VALUES=()
  _ENV_PARSED_FILE=""
  _ENV_PARSED_FINGERPRINT=""
}

_env_key_valid() {
  local key="$1"
  [[ "$key" =~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$' ]] || return 1
  case "$key" in
    IFS|ENV|BASH_ENV|SHELLOPTS|ZDOTDIR|ZSH_EVAL_CONTEXT|HISTCHARS|\
    NULLCMD|READNULLCMD|status|pipestatus|path|fpath|cdpath|manpath|\
    module_path|signals|funcstack|functrace|options|commands|functions|\
    parameters|widgets|jobstates|jobtexts|history)
      return 1
      ;;
  esac
}

_env_value_persistable() {
  local value="$1"
  (( ${#value} <= 65536 )) \
    && [[ "$value" != *$'\n'* \
      && "$value" != *$'\r'* \
      && "$value" != *[[:cntrl:]]* \
      && "$value" != [[:space:]]* \
      && "$value" != *[[:space:]] ]]
}

_env_trim_horizontal() {
  local value="$1"
  value="${value#"${value%%[![:blank:]]*}"}"
  value="${value%"${value##*[![:blank:]]}"}"
  REPLY="$value"
}

# Populates _ENV_PARSED_KEYS and _ENV_PARSED_VALUES. Supported modes:
# dotenv/template: literal dotenv records with optional export and literal
#                  single/double quoted multiline values.
# profile:         suite-owned KEY=value records with values kept literally.
_env_parse_file() {
  emulate -L zsh
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _env_error "Zsh file-descriptor support is required for passive parsing."
    return 1
  }
  local requested_file="$1"
  local parse_mode="$2"
  local scope_root="$3"
  local protection="data"
  [[ "$parse_mode" == "profile" ]] && protection="private"
  case "$parse_mode" in
    dotenv|template|profile) ;;
    *)
      _env_error "Unknown Environment data format."
      return 2
      ;;
  esac

  _env_clear_parsed
  _env_validate_regular_file \
    "$requested_file" "$scope_root" "$protection" || return 1
  local input_file="$REPLY"
  _env_file_fingerprint "$input_file" || return 1
  local initial_fingerprint="$REPLY"
  if [[ "$parse_mode" == "dotenv" ]]; then
    local -a fingerprint_fields=("${(@s/:/)initial_fingerprint}")
    if (( (fingerprint_fields[3] & 8#44) != 0 )); then
      _env_warn \
        "The dotenv file is readable by other accounts; mode 600 is recommended."
    fi
  fi

  local -a parsed_keys=() parsed_values=()
  local -A seen_keys=()
  local line="" trimmed_line="" key="" value=""
  local multiline_key="" multiline_value="" quote_character=""
  local -i input_fd=-1 line_number=0 in_multiline=0 parse_rc=1
  local -i profile_header_seen=0

  {
    if ! sysopen -r -o nofollow,cloexec -u input_fd \
      -- "$input_file" 2>/dev/null; then
      _env_error "Could not open the Environment data file safely."
      return 1
    fi

    while IFS= read -r line <&$(( input_fd )) || [[ -n "$line" ]]; do
      (( ++line_number ))
      line="${line%$'\r'}"

      if [[ "$parse_mode" == "profile" && line_number -eq 1 ]]; then
        [[ "$line" == "# zdx-environment-profile-v1" ]] || {
          _env_error "The profile format header is missing or invalid."
          return 1
        }
        profile_header_seen=1
        continue
      fi

      if (( in_multiline )); then
        if [[ "$line" == *"$quote_character" ]]; then
          multiline_value+=$'\n'"${line[1,-2]}"
          parsed_keys+=("$multiline_key")
          parsed_values+=("$multiline_value")
          in_multiline=0
          multiline_key=""
          multiline_value=""
          quote_character=""
        else
          multiline_value+=$'\n'"$line"
        fi
        (( ${#multiline_value} <= _ENV_MAX_FILE_BYTES )) || {
          _env_error "A multiline value exceeds the parser limit."
          return 1
        }
        continue
      fi

      _env_trim_horizontal "$line"
      trimmed_line="$REPLY"
      [[ -z "$trimmed_line" || "$trimmed_line" == \#* ]] && continue

      if [[ "$parse_mode" == "profile" ]]; then
        trimmed_line="$line"
      elif [[ "$trimmed_line" == export[[:blank:]]* ]]; then
        trimmed_line="${trimmed_line#export}"
        _env_trim_horizontal "$trimmed_line"
        trimmed_line="$REPLY"
      fi

      [[ "$trimmed_line" == *=* ]] || {
        _env_error "Invalid record at line $line_number."
        return 1
      }
      key="${trimmed_line%%=*}"
      value="${trimmed_line#*=}"
      if [[ "$parse_mode" != "profile" ]]; then
        _env_trim_horizontal "$key"
        key="$REPLY"
      fi
      _env_key_valid "$key" || {
        _env_error "Invalid or protected variable name at line $line_number."
        return 1
      }
      (( ! ${+seen_keys[$key]} )) || {
        _env_error "Duplicate variable '$key' at line $line_number."
        return 1
      }
      seen_keys[$key]=1
      (( ${#parsed_keys[@]} < _ENV_MAX_RECORDS )) || {
        _env_error "The data file exceeds the $_ENV_MAX_RECORDS record limit."
        return 1
      }

      if [[ "$parse_mode" == "profile" ]]; then
        _env_value_persistable "$value" || {
          _env_error "A profile value is not representable safely."
          return 1
        }
        parsed_keys+=("$key")
        parsed_values+=("$value")
        continue
      fi

      _env_trim_horizontal "$value"
      value="$REPLY"
      if [[ "$value" == \"* || "$value" == \'* ]]; then
        quote_character="${value[1]}"
        if (( ${#value} >= 2 )) \
          && [[ "${value[-1]}" == "$quote_character" ]]; then
          parsed_keys+=("$key")
          parsed_values+=("${value[2,-2]}")
          quote_character=""
        else
          in_multiline=1
          multiline_key="$key"
          multiline_value="${value[2,-1]}"
        fi
      else
        parsed_keys+=("$key")
        parsed_values+=("$value")
      fi
    done
    exec {input_fd}>&-
    input_fd=-1

    (( in_multiline == 0 )) || {
      _env_error \
        "Unclosed quoted value beginning at or before line $line_number."
      return 1
    }
    [[ "$parse_mode" != "profile" || "$profile_header_seen" -eq 1 ]] || {
      _env_error "The profile format header is missing or invalid."
      return 1
    }
    (( ${#parsed_keys[@]} > 0 )) || {
      _env_error "The Environment data file contains no variable records."
      return 1
    }
    _env_file_fingerprint "$input_file" || return 1
    [[ "$REPLY" == "$initial_fingerprint" ]] || {
      _env_error "The Environment data file changed while it was parsed."
      return 1
    }

    _ENV_PARSED_KEYS=("${parsed_keys[@]}")
    _ENV_PARSED_VALUES=("${parsed_values[@]}")
    _ENV_PARSED_FILE="$input_file"
    _ENV_PARSED_FINGERPRINT="$initial_fingerprint"
    parse_rc=0
  } always {
    (( input_fd >= 0 )) && exec {input_fd}>&-
    (( parse_rc == 0 )) || _env_clear_parsed
  }
  return $parse_rc
}

_env_apply_parsed() {
  emulate -L zsh
  local source_label="$1"
  local dry_run="$2"
  local auto_yes="$3"
  (( ${#_ENV_PARSED_KEYS[@]} > 0 \
    && ${#_ENV_PARSED_KEYS[@]} == ${#_ENV_PARSED_VALUES[@]} )) || {
    _env_error "No validated Environment snapshot is available."
    return 1
  }

  local key="" parameter_type="" action=""
  local -i index=1
  _env_header "Environment Mutation Plan"
  _env_info "Source: $source_label"
  _env_info "Variables: ${#_ENV_PARSED_KEYS[@]}"
  for key in "${_ENV_PARSED_KEYS[@]}"; do
    if (( ${+parameters[$key]} )); then
      parameter_type="${parameters[$key]}"
      [[ "$parameter_type" == scalar* \
        && "$parameter_type" == *export* \
        && "$parameter_type" != *special* \
        && "$parameter_type" != *local* \
        && "$parameter_type" != *readonly* ]] || {
        _env_error \
          "Refusing to replace protected or non-scalar parameter '$key'."
        _env_clear_parsed
        return 1
      }
      action="replace"
    else
      action="set"
    fi
    if _env_key_is_sensitive "$key"; then
      _env_dim "$action $key [secret value hidden]"
    else
      _env_dim "$action $key [value hidden]"
    fi
  done

  if [[ "$dry_run" == "yes" ]]; then
    _env_info "Dry run only; the active environment was not changed."
    _env_clear_parsed
    return 0
  fi

  _env_file_fingerprint "$_ENV_PARSED_FILE" || {
    _env_clear_parsed
    return 1
  }
  [[ "$REPLY" == "$_ENV_PARSED_FINGERPRINT" ]] || {
    _env_error "The reviewed Environment data file changed before loading."
    _env_clear_parsed
    return 1
  }
  _env_confirm_mutation \
    "Apply this exact environment mutation plan?" "$auto_yes" || {
    local -i confirm_rc=$?
    _env_clear_parsed
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }
  _env_file_fingerprint "$_ENV_PARSED_FILE" || {
    _env_clear_parsed
    return 1
  }
  [[ "$REPLY" == "$_ENV_PARSED_FINGERPRINT" ]] || {
    _env_error \
      "The reviewed Environment data file changed after authorization."
    _env_clear_parsed
    return 1
  }

  local -A old_present=() old_values=()
  local -a applied_keys=()
  local value=""
  for key in "${_ENV_PARSED_KEYS[@]}"; do
    if (( ${+parameters[$key]} )); then
      old_present[$key]=yes
      old_values[$key]="${(P)key}"
    else
      old_present[$key]=no
      old_values[$key]=""
    fi
  done

  for (( index = 1; index <= ${#_ENV_PARSED_KEYS[@]}; ++index )); do
    key="${_ENV_PARSED_KEYS[index]}"
    value="${_ENV_PARSED_VALUES[index]}"
    if ! export "$key=$value"; then
      _env_error "Could not apply variable '$key'; rolling back."
      local rollback_key=""
      local -i rollback_index=0
      for (( rollback_index = ${#applied_keys[@]}; \
        rollback_index >= 1; --rollback_index )); do
        rollback_key="${applied_keys[rollback_index]}"
        if [[ "${old_present[$rollback_key]}" == "yes" ]]; then
          export "$rollback_key=${old_values[$rollback_key]}"
        else
          unset "$rollback_key"
        fi
      done
      _env_clear_parsed
      return 1
    fi
    applied_keys+=("$key")
  done

  local applied_count=${#applied_keys[@]}
  _env_clear_parsed
  _env_success "Applied $applied_count environment variable(s)."
}

_env_load_file() {
  emulate -L zsh
  local requested_file="${1:-}"
  [[ -n "$requested_file" ]] || {
    _env_error "A dotenv file is required."
    return 2
  }
  shift
  local dry_run="no"
  local auto_yes="no"
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) dry_run="yes" ;;
      --yes) auto_yes="yes" ;;
      *)
        _env_error "Unknown dotenv load option: $1"
        return 2
        ;;
    esac
    shift
  done

  _env_validate_operation_root "$PWD" || return 1
  local operation_root="$REPLY"
  _env_parse_file "$requested_file" dotenv "$operation_root" || return 1
  _env_apply_parsed "$_ENV_PARSED_FILE" "$dry_run" "$auto_yes"
}

_env_dotenv_name_matches() {
  local base_name="$1"
  [[ "$base_name" == .env \
    || "$base_name" == .env.* \
    || "$base_name" == *.env \
    || "$base_name" == *.env.* \
    || "$base_name" == env.* ]]
}

_env_collect_dotenv_candidates() {
  emulate -L zsh
  zmodload zsh/stat zsh/system 2>/dev/null || return 1
  local operation_root="$1"
  reply=()
  _env_require_cmd find "bounded dotenv discovery" || return 1
  _env_require_cmd head "bounded dotenv discovery" || return 1
  _env_validate_temp_parent "${TMPDIR:-/tmp}" || return 1
  local temp_root="$REPLY"

  local inventory_file=""
  inventory_file=$(umask 077; command mktemp \
    "$temp_root/zdx-env-scan.XXXXXX" 2>/dev/null) || {
    _env_error "Could not create a private dotenv inventory."
    return 1
  }
  local -A initial_state=() current_state=()
  if [[ "$inventory_file" != "${inventory_file:a}" \
    || "$inventory_file" != "${inventory_file:A}" \
    || "${inventory_file:h}" != "$temp_root" \
    || "${inventory_file:t}" != zdx-env-scan.* \
    || ! -f "$inventory_file" || -L "$inventory_file" ]] \
    || ! zstat -LH initial_state -- "$inventory_file" 2>/dev/null \
    || (( (initial_state[mode] & 8#170000) != 8#100000 \
      || initial_state[uid] != EUID \
      || initial_state[nlink] != 1 \
      || (initial_state[mode] & 8#777) != 8#600 )); then
    _env_error "Refusing an unsafe dotenv inventory."
    return 1
  fi
  local inventory_identity="${initial_state[device]}:${initial_state[inode]}:${initial_state[mode]}:${initial_state[uid]}:${initial_state[nlink]}"

  local -a find_command=(
    command find "$operation_root"
    -mindepth 1
    -maxdepth 3
    \(
      -name .git
      -o -name .hg
      -o -name .svn
      -o -name node_modules
      -o -name .venv
      -o -name .tmp
    \)
    -prune
    -o
    -print0
  )
  local -a candidates=()
  local candidate_path="" base_name=""
  local -i write_fd=-1 read_fd=-1 scan_rc=1 operation_rc=1 cleanup_rc=0
  local -i visited=0
  {
    if ! sysopen -w -o nofollow,cloexec -u write_fd \
      -- "$inventory_file" 2>/dev/null; then
      _env_error "Could not open the dotenv inventory safely."
      return 1
    fi
    setopt local_options pipefail
    "${find_command[@]}" 2>/dev/null \
      | command head -c "$(( _ENV_MAX_PICKER_BYTES + 1 ))" \
        1>&$(( write_fd ))
    scan_rc=$?
    exec {write_fd}>&-
    write_fd=-1

    current_state=()
    zstat -LH current_state -- "$inventory_file" 2>/dev/null || return 1
    [[ "${current_state[device]}:${current_state[inode]}:${current_state[mode]}:${current_state[uid]}:${current_state[nlink]}" \
      == "$inventory_identity" ]] || {
      _env_error "The dotenv inventory changed unexpectedly."
      return 1
    }
    (( current_state[size] <= _ENV_MAX_PICKER_BYTES )) || {
      _env_error "The dotenv inventory exceeds its byte limit."
      return 1
    }
    (( scan_rc == 0 )) || {
      _env_error "Could not complete the bounded dotenv scan."
      return 1
    }
    if ! sysopen -r -o nofollow,cloexec -u read_fd \
      -- "$inventory_file" 2>/dev/null; then
      return 1
    fi
    while IFS= read -r -d '' candidate_path <&$(( read_fd )); do
      (( ++visited <= 4096 )) || {
        _env_error "The dotenv scan exceeded 4096 visited nodes."
        return 1
      }
      [[ -f "$candidate_path" && ! -L "$candidate_path" ]] || continue
      base_name="${candidate_path:t}"
      _env_dotenv_name_matches "$base_name" || continue
      _env_validate_regular_file \
        "$candidate_path" "$operation_root" data yes || continue
      candidates+=("$REPLY")
      (( ${#candidates[@]} <= _ENV_MAX_CANDIDATES )) || {
        _env_error \
          "The dotenv scan exceeds the $_ENV_MAX_CANDIDATES candidate limit."
        return 1
      }
    done
    exec {read_fd}>&-
    read_fd=-1
    reply=("${(@on)candidates}")
    operation_rc=0
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-
    current_state=()
    if [[ -f "$inventory_file" && ! -L "$inventory_file" ]] \
      && zstat -LH current_state -- "$inventory_file" 2>/dev/null \
      && [[ "${current_state[device]}:${current_state[inode]}:${current_state[mode]}:${current_state[uid]}:${current_state[nlink]}" \
        == "$inventory_identity" ]]; then
      command rm -f "$inventory_file" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    (( cleanup_rc == 0 )) || operation_rc=1
  }
  return $operation_rc
}

_env_select_dotenv_file() {
  local operation_root="$1"
  _env_require_cmd fzf "interactive dotenv selection" || return 1
  _env_collect_dotenv_candidates "$operation_root" || return 1
  local -a candidates=("${reply[@]}")
  (( ${#candidates[@]} > 0 )) || {
    _env_warn "No safe dotenv files were found below the current directory."
    return 130
  }

  local -a rows=()
  local -i index=1
  local candidate_file="" relative_file=""
  for candidate_file in "${candidates[@]}"; do
    relative_file="${candidate_file#$operation_root/}"
    _env_visible_field "$relative_file"
    rows+=("${index}|${REPLY}|contents hidden")
    (( ++index ))
  done

  local selected=""
  local -i fzf_rc=0
  _env_fzf_capture \
    --height='55%' \
    --delimiter='[|]' \
    --with-nth=2 \
    --prompt='dotenv > ' \
    --header='Enter review load plan | Esc cancel | file contents stay hidden' \
    --preview='printf "Dotenv contents are intentionally hidden.\\n"' \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    if _env_fzf_rc_is_cancel "$fzf_rc" && [[ -z "$selected" ]]; then
      return 130
    fi
    _env_error "The dotenv picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 130
  [[ "$selected" != *$'\n'* && "$selected" != *$'\r'* ]] || {
    _env_error "Refusing malformed dotenv picker output."
    return 1
  }
  local -i selected_row_position=0
  selected_row_position="${rows[(Ie)$selected]}"
  (( selected_row_position > 0 )) || {
    _env_error "The dotenv selection was not in the current snapshot."
    return 1
  }
  local selected_index="${selected%%|*}"
  [[ "$selected_index" == <-> \
    && selected_index -ge 1 \
    && selected_index -le ${#candidates[@]} ]] || return 1
  REPLY="${candidates[selected_index]}"
}

_env_switch_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  env-switch [--dry-run] [--yes] [--] [DOTENV_FILE]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Without DOTENV_FILE, select a bounded safe candidate interactively."
  print -u2 -r -- \
    "Values are parsed literally; shell expansion and command execution are disabled."
}

env-switch() {
  emulate -L zsh
  local dry_run="no"
  local auto_yes="no"
  local requested_file=""
  local operands_only="no"

  while (( $# > 0 )); do
    if [[ "$operands_only" == "yes" ]]; then
      [[ -z "$requested_file" ]] || {
        _env_error "env-switch accepts at most one file."
        return 2
      }
      requested_file="$1"
      shift
      continue
    fi
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _env_switch_usage
        return 0
        ;;
      --dry-run) dry_run="yes" ;;
      --yes) auto_yes="yes" ;;
      --) operands_only="yes" ;;
      -*)
        _env_error "Unknown env-switch option: $1"
        return 2
        ;;
      *)
        [[ -z "$requested_file" ]] || {
          _env_error "env-switch accepts at most one file."
          return 2
        }
        requested_file="$1"
        ;;
    esac
    shift
  done

  _env_validate_operation_root "$PWD" || return 1
  local operation_root="$REPLY"
  if [[ -z "$requested_file" ]]; then
    _env_select_dotenv_file "$operation_root" || {
      local -i select_rc=$?
      (( select_rc == 130 )) && return 0
      return $select_rc
    }
    requested_file="$REPLY"
  fi

  _env_parse_file "$requested_file" dotenv "$operation_root" || return 1
  _env_apply_parsed "$_ENV_PARSED_FILE" "$dry_run" "$auto_yes"
}

_env_create_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  env-create [--template FILE] [--output FILE] [--overwrite]"
  print -u2 -r -- \
    "             [--dry-run] [--yes]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "The output defaults to .env and is published atomically with mode 600."
}

_env_select_template() {
  local operation_root="$1"
  local -a candidates=()
  local candidate_name=""
  for candidate_name in .env.example .env.tpl env.example; do
    [[ -e "$operation_root/$candidate_name" \
      || -L "$operation_root/$candidate_name" ]] || continue
    _env_validate_regular_file \
      "$operation_root/$candidate_name" "$operation_root" data yes \
      || continue
    candidates+=("$REPLY")
  done

  if (( ${#candidates[@]} == 0 )); then
    REPLY=""
    return 0
  elif (( ${#candidates[@]} == 1 )); then
    REPLY="${candidates[1]}"
    return 0
  fi

  _env_require_cmd fzf "interactive template selection" || return 1
  local -a rows=()
  local -i index=1
  local candidate_file=""
  for candidate_file in "${candidates[@]}"; do
    rows+=("${index}|${candidate_file:t}")
    (( ++index ))
  done
  local selected=""
  local -i fzf_rc=0
  _env_fzf_capture \
    --height='35%' \
    --delimiter='[|]' \
    --with-nth=2 \
    --prompt='template > ' \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    if _env_fzf_rc_is_cancel "$fzf_rc" && [[ -z "$selected" ]]; then
      return 130
    fi
    _env_error "The template picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 130
  [[ "$selected" != *$'\n'* && "$selected" != *$'\r'* ]] || {
    _env_error "Refusing malformed template picker output."
    return 1
  }
  local -i selected_row_position=0
  selected_row_position="${rows[(Ie)$selected]}"
  (( selected_row_position > 0 )) || {
    _env_error "The selected template was not in the current snapshot."
    return 1
  }
  local selected_index="${selected%%|*}"
  [[ "$selected_index" == <-> \
    && selected_index -ge 1 \
    && selected_index -le ${#candidates[@]} ]] || return 1
  REPLY="${candidates[selected_index]}"
}

env-create() {
  emulate -L zsh
  local template_file=""
  local requested_output=".env"
  local overwrite="no"
  local dry_run="no"
  local auto_yes="no"

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || return 2
        _env_create_usage
        return 0
        ;;
      --template|--output)
        local flag_name="$1"
        shift
        (( $# > 0 )) || {
          _env_error "$flag_name requires a value."
          return 2
        }
        if [[ "$flag_name" == "--template" ]]; then
          template_file="$1"
        else
          requested_output="$1"
        fi
        ;;
      --overwrite) overwrite="yes" ;;
      --dry-run) dry_run="yes" ;;
      --yes) auto_yes="yes" ;;
      *)
        _env_error "Unknown env-create argument: $1"
        return 2
        ;;
    esac
    shift
  done

  _env_validate_operation_root "$PWD" || return 1
  local operation_root="$REPLY"
  _env_output_path "$requested_output" "$operation_root" || return 1
  local output_file="$REPLY"

  local expected_fingerprint=""
  if [[ -e "$output_file" || -L "$output_file" ]]; then
    [[ "$overwrite" == "yes" ]] || {
      _env_error "The output exists; pass --overwrite to review replacement."
      return 1
    }
    _env_validate_regular_file \
      "$output_file" "$operation_root" data || return 1
    _env_file_fingerprint "$output_file" || return 1
    expected_fingerprint="$REPLY"
  elif [[ "$overwrite" == "yes" ]]; then
    _env_error "--overwrite requires an existing regular output file."
    return 2
  fi

  if [[ -n "$template_file" ]]; then
    _env_validate_regular_file \
      "$template_file" "$operation_root" data || return 1
    template_file="$REPLY"
  else
    _env_select_template "$operation_root" || {
      local -i template_rc=$?
      (( template_rc == 130 )) && return 0
      return $template_rc
    }
    template_file="$REPLY"
  fi

  local -a keys=() values=()
  if [[ -n "$template_file" ]]; then
    _env_parse_file "$template_file" template "$operation_root" || return 1
    keys=("${_ENV_PARSED_KEYS[@]}")
    values=("${_ENV_PARSED_VALUES[@]}")
    _env_clear_parsed
  fi

  if [[ "$dry_run" != "yes" ]]; then
    local key="" default_value="" input_value=""
    local -A seen_keys=()
    local -i index=1
    if (( ${#keys[@]} > 0 )); then
      for (( index = 1; index <= ${#keys[@]}; ++index )); do
        key="${keys[index]}"
        default_value="${values[index]}"
        printf '? Value for %s [default retained if empty; hidden]: ' \
          "$key" >&2
        IFS= read -r -s input_value || {
          print -u2 -r -- ""
          _env_info "Cancelled before any file was changed."
          return 0
        }
        print -u2 -r -- ""
        [[ -n "$input_value" ]] || input_value="$default_value"
        _env_value_persistable "$input_value" || {
          _env_error "The value for '$key' contains unsupported controls."
          return 1
        }
        values[index]="$input_value"
      done
    else
      while true; do
        printf '? Variable name (empty finishes): ' >&2
        IFS= read -r key || {
          _env_info "Cancelled before any file was changed."
          return 0
        }
        [[ -n "$key" ]] || break
        _env_key_valid "$key" || {
          _env_error "Invalid or protected variable name."
          return 1
        }
        (( ! ${+seen_keys[$key]} )) || {
          _env_error "Duplicate variable '$key'."
          return 1
        }
        seen_keys[$key]=1
        (( ${#keys[@]} < _ENV_MAX_RECORDS )) || return 1
        printf '? Value for %s [hidden]: ' "$key" >&2
        IFS= read -r -s input_value || {
          print -u2 -r -- ""
          _env_info "Cancelled before any file was changed."
          return 0
        }
        print -u2 -r -- ""
        _env_value_persistable "$input_value" || {
          _env_error "The value for '$key' contains unsupported controls."
          return 1
        }
        keys+=("$key")
        values+=("$input_value")
      done
    fi
  fi

  _env_header "Dotenv Creation Plan"
  _env_info "Output: $output_file"
  _env_info "Publication: $([[ "$overwrite" == yes ]] && print replace || print create)"
  _env_info "Mode: 600"
  _env_info "Variables: ${#keys[@]}"
  local key=""
  for key in "${keys[@]}"; do
    _env_key_is_sensitive "$key" \
      && _env_dim "$key [secret value hidden]" \
      || _env_dim "$key [value hidden]"
  done
  if [[ "$dry_run" == "yes" ]]; then
    _env_info "Dry run only; no file was written."
    return 0
  fi
  _env_confirm_mutation \
    "Publish this exact private dotenv file?" "$auto_yes" || {
    local -i confirm_rc=$?
    (( confirm_rc == 130 )) && return 0
    return $confirm_rc
  }

  local -a content_lines=("# Generated by zdx env-create")
  local -i index=1
  local serialized_value=""
  for (( index = 1; index <= ${#keys[@]}; ++index )); do
    serialized_value="${values[index]}"
    # The passive parser treats leading quotes as delimiters. Add one literal
    # outer pair so quotes belonging to the value survive a later load.
    if [[ "$serialized_value" == \"* || "$serialized_value" == \'* ]]; then
      serialized_value="'${serialized_value}'"
    fi
    content_lines+=("${keys[index]}=$serialized_value")
  done
  _env_atomic_publish_lines \
    "$output_file" "$overwrite" "$expected_fingerprint" content_lines \
    || return 1
  _env_success "Published private dotenv file: $output_file"
}

typeset -g _ENV_DOTENV_SOURCED=1
