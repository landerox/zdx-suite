#!/usr/bin/env zsh
# =============================================================================
# AI Config: private, manifest-backed configuration snapshots
# =============================================================================
#
# Loaded by ai-menu.zsh after ai-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_AI_CONFIG_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _AI_CONFIG_MAX_FILES=1024
typeset -gi _AI_CONFIG_MAX_FILE_BYTES=16777216
typeset -gi _AI_CONFIG_MAX_MANIFEST_BYTES=1048576
typeset -gi _AI_CONFIG_MAX_SNAPSHOTS=256

_ai_config_token_valid() {
  [[ "${1:-}" =~ '^[0-9]{8}T[0-9]{6}-[0-9]{1,5}$' ]]
}

_ai_config_relative_valid() {
  local relative="${1:-}"
  [[ -n "$relative" && "$relative" != /* && "$relative" != "." \
    && "$relative" != ".." && "$relative" != ../* && "$relative" != */../* \
    && "$relative" != */.. && "$relative" != *'//'* \
    && "$relative" != *'|'* \
    && "$relative" != *$'\t'* && "$relative" != *$'\n'* \
    && "$relative" != *$'\r'* && "$relative" != *[[:cntrl:]]* ]]
}

_ai_config_allowed_relative() {
  local relative="${1:-}"
  _ai_config_relative_valid "$relative" || return 1
  case "$relative" in
    .claude.json|.claude/settings.json|.claude/settings.local.json|\
    .codex/config.toml|.codex/auth.json|\
    .gemini/antigravity-cli/settings.json|.gemini/config/mcp_config.json|\
    .config/opencode/opencode.json|.config/opencode/config.json|\
    .copilot/config.json|\
    .cursor/mcp.json|.cursor/settings.json|.cursor/blocklist|\
    .local/share/amp/settings.json)
      return 0
      ;;
  esac
  return 1
}

_ai_config_digest() {
  local file="${1:-}" output="" checksum="" bytes="" extra=""
  output=$(command cksum < "$file" 2>/dev/null) || return 1
  read -r checksum bytes extra <<< "$output"
  [[ "$checksum" == <-> && "$bytes" == <-> && -z "$extra" ]] || return 1
  REPLY="$checksum:$bytes"
}

_ai_config_capture_source() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local source_file="${1:-}" home_root="${HOME:A}"
  REPLY=""

  [[ -n "$source_file" && "$source_file" == /* \
    && "$source_file" == "$home_root"/* && "$source_file" == "${source_file:A}" \
    && -f "$source_file" && ! -L "$source_file" && -O "$source_file" ]] || {
    _ai_error "Refusing an unsafe configuration source: $source_file"
    return 1
  }
  local relative="${source_file#$home_root/}"
  _ai_config_allowed_relative "$relative" || {
    _ai_error "Configuration source is outside the backup allowlist: $relative"
    return 1
  }

  local -A state=()
  zstat -LH state -- "$source_file" 2>/dev/null || return 1
  local -i object_type=$(( state[mode] & 8#170000 ))
  (( object_type == 8#100000 && state[nlink] == 1 \
    && state[size] >= 0 && state[size] <= _AI_CONFIG_MAX_FILE_BYTES )) || {
    _ai_error "Configuration source is linked, non-regular, or oversized: $relative"
    return 1
  }
  _ai_config_digest "$source_file" || return 1
  local digest="$REPLY"
  REPLY="$relative|${state[device]}:${state[inode]}:${state[mode]}:"\
"${state[uid]}:${state[nlink]}:${state[size]}:${state[mtime]}|$digest"
}

_ai_config_source_matches() {
  local source_file="$1" expected_record="$2"
  _ai_config_capture_source "$source_file" || return 1
  [[ "$REPLY" == "$expected_record" ]]
}

_ai_config_collect_sources() {
  emulate -L zsh
  setopt local_options extended_glob
  reply=()
  local home_root="${HOME:A}"
  local opencode_root="$home_root/.config/opencode"
  local -a candidates=(
    "$home_root/.claude.json"(N.)
    "$home_root/.claude/settings.json"(N.)
    "$home_root/.claude/settings.local.json"(N.)
    "$home_root/.codex/config.toml"(N.)
    "$home_root/.codex/auth.json"(N.)
    "$home_root/.gemini/antigravity-cli/settings.json"(N.)
    "$home_root/.gemini/config/mcp_config.json"(N.)
    "$opencode_root/opencode.json"(N.)
    "$opencode_root/config.json"(N.)
    "$home_root/.copilot/config.json"(N.)
    "$home_root/.cursor/mcp.json"(N.)
    "$home_root/.cursor/settings.json"(N.)
    "$home_root/.cursor/blocklist"(N.)
    "$home_root/.local/share/amp/settings.json"(N.)
  )
  local source_file="" record=""
  local -A seen=()
  for source_file in "${candidates[@]}"; do
    [[ -z "${seen[$source_file]:-}" ]] || continue
    _ai_config_capture_source "$source_file" || return 1
    record="$REPLY"
    seen[$source_file]=1
    reply+=("$source_file|$record")
    (( ${#reply[@]} <= _AI_CONFIG_MAX_FILES )) || {
      _ai_error "Configuration snapshot exceeds $_AI_CONFIG_MAX_FILES files."
      return 1
    }
  done
}

_ai_config_backup_root_check() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local backup_root="${1:-}"
  [[ "$backup_root" == "${HOME:A}/.ai-suite-backups" ]] || return 1
  [[ -d "$backup_root" && ! -L "$backup_root" && -O "$backup_root" \
    && "$backup_root" == "${backup_root:A}" ]] || return 1
  local -A state=()
  zstat -LH state -- "$backup_root" 2>/dev/null || return 1
  (( (state[mode] & 8#077) == 0 )) || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}"
}

_ai_config_snapshot_check() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local backup_root="$1" token="$2"
  _ai_config_token_valid "$token" || return 1
  local snapshot="$backup_root/$token"
  [[ -d "$snapshot" && ! -L "$snapshot" && -O "$snapshot" \
    && "$snapshot" == "${snapshot:A}" ]] || return 1
  local -A state=()
  zstat -LH state -- "$snapshot" 2>/dev/null || return 1
  (( (state[mode] & 8#077) == 0 )) || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}"
}

_ai_config_remove_private_tree() {
  local backup_root="$1" target="$2" kind="${3:-staging}"
  [[ -d "$backup_root" && ! -L "$backup_root" \
    && -d "$target" && ! -L "$target" && -O "$target" \
    && "${target:h}" == "$backup_root" ]] || return 1
  case "$kind:${target:t}" in
    staging:.staging-*) ;;
    snapshot:*)
      _ai_config_token_valid "${target:t}" || return 1
      ;;
    *) return 1 ;;
  esac
  command rm -rf -- "$target" 2>/dev/null
}

ai-config-backup() {
  emulate -L zsh
  _ai_parse_flags config-backup "ai-config-backup" "$@" || return $?
  if (( _AI_HELP_ONLY )); then
    return 0
  fi

  _ai_config_collect_sources || return 1
  local -a plan=("${reply[@]}")
  if (( ${#plan[@]} == 0 )); then
    _ai_info "No allowlisted AI configuration files were found."
    return 0
  fi

  local token="$(date +%Y%m%dT%H%M%S)-$RANDOM"
  _ai_config_token_valid "$token" || {
    _ai_error "Could not generate a valid snapshot token."
    return 1
  }
  local backup_root="${HOME:A}/.ai-suite-backups"
  local final_snapshot="$backup_root/$token"

  _ai_header "AI Configuration Backup Plan"
  _ai_info "Snapshot: $token"
  local entry="" source_file="" rest="" relative=""
  for entry in "${plan[@]}"; do
    source_file="${entry%%|*}"
    rest="${entry#*|}"
    relative="${rest%%|*}"
    _ai_info "$source_file -> files/$relative"
  done
  if (( _AI_DRY_RUN )); then
    _ai_info "Dry run: no backup directory or file was created."
    return 0
  fi
  _ai_authorize "Create this ${#plan[@]}-file private snapshot?"
  local authorize_rc=$?
  (( authorize_rc == 130 )) && return 0
  (( authorize_rc == 0 )) || return $authorize_rc

  if [[ -e "$backup_root" || -L "$backup_root" ]]; then
    _ai_config_backup_root_check "$backup_root" || {
      _ai_error "Backup root is not a private owned directory: $backup_root"
      return 1
    }
  else
    (umask 077; command mkdir -m 700 -- "$backup_root") || return 1
    _ai_config_backup_root_check "$backup_root" || return 1
  fi
  local backup_root_identity="$REPLY"
  [[ ! -e "$final_snapshot" && ! -L "$final_snapshot" ]] || {
    _ai_error "Snapshot token collision: $token"
    return 1
  }

  local staging="$final_snapshot"
  local files_root="$final_snapshot/files"
  local manifest="$final_snapshot/manifest.tsv"
  local -i operation_rc=1 cleanup_staging=1 reserved_snapshot=0
  {
    (umask 077; command mkdir -m 700 -- "$final_snapshot") || {
      _ai_error "Could not reserve the snapshot token without clobbering."
      return 1
    }
    [[ -d "$final_snapshot" && ! -L "$final_snapshot" \
      && -O "$final_snapshot" && "$final_snapshot" == "${final_snapshot:A}" ]] \
      || return 1
    reserved_snapshot=1
    (umask 077; command mkdir -m 700 -- "$files_root") || return 1
    (umask 077; : > "$manifest") || return 1
    command chmod 600 -- "$manifest" || return 1

    local expected="" digest="" bytes="" destination=""
    for entry in "${plan[@]}"; do
      source_file="${entry%%|*}"
      expected="${entry#*|}"
      relative="${expected%%|*}"
      _ai_config_source_matches "$source_file" "$expected" || {
        _ai_error "Configuration source changed after review: $source_file"
        return 1
      }
      digest="${expected##*|}"
      bytes="${digest#*:}"
      destination="$files_root/$relative"
      (umask 077; command mkdir -p -- "${destination:h}") || return 1
      command cp -p -- "$source_file" "$destination" 2>/dev/null || return 1
      command chmod 600 -- "$destination" || return 1
      [[ -f "$destination" && ! -L "$destination" && -O "$destination" ]] \
        || return 1
      _ai_config_digest "$destination" && [[ "$REPLY" == "$digest" ]] || {
        _ai_error "Snapshot verification failed for: $relative"
        return 1
      }
      printf '%s\t%s\t%s\n' "$relative" "$bytes" "${digest%%:*}" \
        >> "$manifest" || return 1
    done

    _ai_config_backup_root_check "$backup_root" \
      && [[ "$REPLY" == "$backup_root_identity" ]] || {
      _ai_error "Backup root changed while the snapshot was built."
      return 1
    }
    _ai_config_snapshot_check "$backup_root" "$token" || return 1
    cleanup_staging=0
    operation_rc=0
  } always {
    if (( cleanup_staging && reserved_snapshot )) && [[ -e "$staging" ]]; then
      _ai_config_remove_private_tree "$backup_root" "$staging" snapshot \
        || operation_rc=1
    fi
  }
  (( operation_rc == 0 )) || {
    _ai_error "Configuration snapshot failed and was not published."
    return 1
  }

  _ai_success "Private snapshot created: $final_snapshot"
}

# reply holds the validated token, or an empty string when none was given so
# the caller can offer the private snapshot picker.
_ai_config_restore_parse() {
  reply=()
  local token="" arg=""
  local -a flags=()
  while (( $# )); do
    arg="$1"
    case "$arg" in
      --dry-run|--yes|-y|--verbose|-v|--help|-h)
        flags+=("$arg")
        ;;
      --)
        shift
        (( $# <= 1 )) && [[ $# -eq 0 || -z "$token" ]] || {
          _ai_error "Restore accepts at most one snapshot token."
          return 2
        }
        (( $# == 1 )) && token="$1"
        break
        ;;
      -*)
        _ai_error "Unknown restore option: $arg"
        return 2
        ;;
      *)
        [[ -z "$token" ]] || {
          _ai_error "Restore accepts at most one snapshot token."
          return 2
        }
        token="$arg"
        ;;
    esac
    shift
  done
  _ai_parse_flags config-restore "ai-config-restore" "${flags[@]}" || return $?
  if (( _AI_HELP_ONLY )); then
    return 64
  fi
  if [[ -n "$token" ]]; then
    _ai_config_token_valid "$token" || {
      _ai_error "Invalid snapshot token: $token"
      return 2
    }
  fi
  reply=("$token")
}

# Inventory of restorable snapshot tokens below the private backup root,
# newest first. reply holds only tokens whose directories pass the same
# owner-only checks as restore itself. Returns 1 when the root is absent and
# 2 when it exists but is unsafe; an empty inventory is a successful result.
_ai_config_snapshot_tokens() {
  emulate -L zsh
  setopt local_options extended_glob
  reply=()
  local backup_root="${HOME:A}/.ai-suite-backups"
  [[ -e "$backup_root" || -L "$backup_root" ]] || return 1
  _ai_config_backup_root_check "$backup_root" || return 2
  local candidate="" token=""
  local -a candidates=(
    "$backup_root"/[0-9](#c8)T[0-9](#c6)-[0-9](#c1,5)(N/On)
  )
  for candidate in "${candidates[@]}"; do
    token="${candidate:t}"
    _ai_config_token_valid "$token" || continue
    _ai_config_snapshot_check "$backup_root" "$token" || continue
    reply+=("$token")
    (( ${#reply[@]} < _AI_CONFIG_MAX_SNAPSHOTS )) || break
  done
  return 0
}

# Lightweight picker label: the manifest record count, without verifying the
# snapshot content. The restore path performs the full validation afterwards.
_ai_config_snapshot_summary() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local manifest="${1:-}/manifest.tsv" count=""
  local -A state=()
  REPLY="manifest unavailable"
  [[ -f "$manifest" && ! -L "$manifest" && -O "$manifest" ]] \
    && zstat -LH state -- "$manifest" 2>/dev/null \
    && (( state[nlink] == 1 && state[size] >= 0 \
      && state[size] <= _AI_CONFIG_MAX_MANIFEST_BYTES )) || return 0
  count=$(command wc -l < "$manifest" 2>/dev/null) || return 0
  count="${count//[[:space:]]/}"
  [[ "$count" == <-> ]] || return 0
  if (( count == 1 )); then
    REPLY="1 file"
  else
    REPLY="$count files"
  fi
}

_ai_config_print_available() {
  _ai_config_snapshot_tokens || return 0
  (( ${#reply[@]} > 0 )) || return 0
  local token=""
  _ai_info "Available snapshots (newest first):"
  for token in "${reply[@]}"; do
    _ai_dim "$token"
  done
}

# Choose one restorable snapshot with the private foreground picker. REPLY
# holds the validated token on success. Returns 130 on cancellation, 3 when
# no restorable snapshot exists, 2 when fzf is unavailable, and 1 for an
# unsafe backup root, a picker failure, or a selection outside the rendered
# inventory (each already reported).
_ai_config_pick_snapshot() {
  emulate -L zsh
  REPLY=""
  local backup_root="${HOME:A}/.ai-suite-backups"
  local -i inventory_rc=0
  _ai_config_snapshot_tokens || inventory_rc=$?
  case "$inventory_rc" in
    0) ;;
    1) return 3 ;;
    *)
      _ai_error "Backup root is not a private owned directory: $backup_root"
      return 1
      ;;
  esac
  local -a tokens=("${reply[@]}")
  (( ${#tokens[@]} > 0 )) || return 3
  command -v fzf >/dev/null 2>&1 || {
    _ai_error "Selecting a snapshot interactively requires fzf."
    return 2
  }

  local -a rows=()
  local token="" row="" selection=""
  for token in "${tokens[@]}"; do
    _ai_config_snapshot_summary "$backup_root/$token"
    rows+=("$token  ($REPLY)|$token|Private snapshot below ~/.ai-suite-backups. Restore stages each file and keeps a rollback copy.")
  done

  local -i fzf_rc=0
  _ai_fzf_capture \
    --prompt='ai snapshots > ' \
    --header='Up/Down navigate | Enter select snapshot | Esc cancel' \
    --preview='printf "Snapshot: %s\n\n%s\n" {2} {3}' \
    --preview-window='down:4:wrap' \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selection="$REPLY"
  REPLY=""
  if (( fzf_rc != 0 )); then
    _ai_fzf_cancelled "$fzf_rc" && return 130
    _ai_error "Unable to open the snapshot picker (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selection" ]] || return 130

  local -i snapshot_match=0
  for row in "${rows[@]}"; do
    if [[ "$row" == "$selection" ]]; then
      snapshot_match=1
      break
    fi
  done
  (( snapshot_match )) || {
    _ai_error "The selected snapshot was not in the picker inventory."
    return 1
  }
  token="${${selection#*|}%%|*}"
  _ai_config_token_valid "$token" || return 1
  REPLY="$token"
}

_ai_config_manifest_plan() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local snapshot="$1"
  reply=()
  local manifest="$snapshot/manifest.tsv"
  [[ -f "$manifest" && ! -L "$manifest" && -O "$manifest" \
    && "$manifest" == "${manifest:A}" ]] || {
    _ai_error "Snapshot manifest is missing or unsafe."
    return 1
  }
  local -A manifest_state=()
  zstat -LH manifest_state -- "$manifest" 2>/dev/null || return 1
  (( manifest_state[nlink] == 1 && manifest_state[size] >= 0 \
    && manifest_state[size] <= _AI_CONFIG_MAX_MANIFEST_BYTES )) || {
    _ai_error "Snapshot manifest is linked or oversized."
    return 1
  }

  local relative="" bytes="" checksum="" extra="" source_file="" digest=""
  local -A seen=()
  while IFS=$'\t' read -r relative bytes checksum extra; do
    [[ -z "$extra" && "$bytes" == <-> && "$checksum" == <-> \
      && "$bytes" -le _AI_CONFIG_MAX_FILE_BYTES ]] || {
      _ai_error "Snapshot manifest contains an invalid record."
      return 1
    }
    _ai_config_allowed_relative "$relative" || {
      _ai_error "Snapshot manifest contains a disallowed path: $relative"
      return 1
    }
    [[ -z "${seen[$relative]:-}" ]] || {
      _ai_error "Snapshot manifest contains a duplicate path: $relative"
      return 1
    }
    source_file="$snapshot/files/$relative"
    [[ "$source_file" == "${source_file:A}" && -f "$source_file" \
      && ! -L "$source_file" && -O "$source_file" ]] || {
      _ai_error "Snapshot file is missing or unsafe: $relative"
      return 1
    }
    local -A source_state=()
    zstat -LH source_state -- "$source_file" 2>/dev/null || return 1
    (( source_state[nlink] == 1 && source_state[size] == bytes )) || {
      _ai_error "Snapshot file metadata does not match: $relative"
      return 1
    }
    _ai_config_digest "$source_file" || return 1
    digest="$REPLY"
    [[ "$digest" == "$checksum:$bytes" ]] || {
      _ai_error "Snapshot checksum mismatch: $relative"
      return 1
    }
    seen[$relative]=1
    reply+=("$relative|${source_state[device]}:${source_state[inode]}:"\
"${source_state[mode]}:${source_state[uid]}:${source_state[nlink]}:"\
"${source_state[size]}:${source_state[mtime]}|$digest")
    (( ${#reply[@]} <= _AI_CONFIG_MAX_FILES )) || {
      _ai_error "Snapshot manifest exceeds $_AI_CONFIG_MAX_FILES files."
      return 1
    }
  done < "$manifest"
  (( ${#reply[@]} > 0 )) || {
    _ai_error "Snapshot manifest is empty."
    return 1
  }
}

_ai_config_snapshot_source_matches() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local source_file="$1" expected="$2"
  [[ -f "$source_file" && ! -L "$source_file" && -O "$source_file" ]] \
    || return 1
  local -A state=()
  zstat -LH state -- "$source_file" 2>/dev/null || return 1
  _ai_config_digest "$source_file" || return 1
  [[ "${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}:"\
"${state[nlink]}:${state[size]}:${state[mtime]}|$REPLY" == "$expected" ]]
}

_ai_config_live_capture() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local destination="$1"
  REPLY="absent"
  [[ ! -L "$destination" ]] || return 1
  [[ -e "$destination" ]] || return 0
  [[ -f "$destination" && -O "$destination" ]] || return 1
  local -A state=()
  zstat -LH state -- "$destination" 2>/dev/null || return 1
  (( state[nlink] == 1 && state[size] >= 0 \
    && state[size] <= _AI_CONFIG_MAX_FILE_BYTES )) || return 1
  _ai_config_digest "$destination" || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}:"\
"${state[nlink]}:${state[size]}:${state[mtime]}|$REPLY"
}

_ai_config_live_matches() {
  local destination="$1" expected="$2"
  _ai_config_live_capture "$destination" || return 1
  [[ "$REPLY" == "$expected" ]]
}

_ai_config_parent_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local parent="$1" home_root="${HOME:A}"
  [[ "$parent" == "$home_root" || "$parent" == "$home_root"/* ]] || return 1
  local relative="${parent#$home_root/}"
  local current="$home_root" component="" chain=""
  local -a components=()
  [[ "$parent" != "$home_root" ]] && components=(${(s:/:)relative})
  components=("" "${components[@]}")
  local -A state=()
  for component in "${components[@]}"; do
    [[ -z "$component" ]] || current="$current/$component"
    if [[ -e "$current" || -L "$current" ]]; then
      [[ -d "$current" && ! -L "$current" && -O "$current" \
        && "$current" == "${current:A}" ]] || return 1
      state=()
      zstat -LH state -- "$current" 2>/dev/null || return 1
      (( (state[mode] & 8#022) == 0 )) || return 1
      chain+="${#current}:$current=${state[device]}:${state[inode]}:"\
"${state[mode]}:${state[uid]};"
    else
      chain+="${#current}:$current=absent;"
    fi
  done
  REPLY="$chain"
}

_ai_config_prepare_parent() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local parent="$1" home_root="${HOME:A}"
  [[ "$parent" == "$home_root" || "$parent" == "$home_root"/* ]] || return 1
  local relative="${parent#$home_root/}"
  local current="$home_root" component=""
  [[ "$parent" == "$home_root" ]] && return 0
  for component in ${(s:/:)relative}; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || return 1
    current="$current/$component"
    if [[ -e "$current" || -L "$current" ]]; then
      [[ -d "$current" && ! -L "$current" && -O "$current" ]] || return 1
      local -A state=()
      zstat -LH state -- "$current" 2>/dev/null || return 1
      (( (state[mode] & 8#022) == 0 )) || return 1
    else
      (umask 077; command mkdir -m 700 -- "$current") || return 1
    fi
  done
}

ai-config-restore() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  _ai_config_restore_parse "$@"
  local parse_rc=$?
  (( parse_rc == 64 )) && return 0
  (( parse_rc == 0 )) || return $parse_rc
  local token="${reply[1]:-}"
  local backup_root="${HOME:A}/.ai-suite-backups"

  if [[ -z "$token" ]]; then
    local -i pick_rc=0
    _ai_config_pick_snapshot || pick_rc=$?
    case "$pick_rc" in
      0)
        token="$REPLY"
        ;;
      130)
        _ai_info "Cancelled."
        return 0
        ;;
      3)
        _ai_error "No restorable snapshot was found under $backup_root."
        return 1
        ;;
      2)
        _ai_error "A snapshot token is required."
        _ai_config_print_available
        return 2
        ;;
      *)
        return 1
        ;;
    esac
  fi

  _ai_config_backup_root_check "$backup_root" || {
    _ai_error "Backup root is missing, unsafe, or not private: $backup_root"
    return 1
  }
  local root_identity="$REPLY"
  _ai_config_snapshot_check "$backup_root" "$token" || {
    _ai_error "Snapshot is missing, unsafe, or not private: $token"
    return 1
  }
  local snapshot_identity="$REPLY"
  local snapshot="$backup_root/$token"
  _ai_config_manifest_plan "$snapshot" || return 1
  local -a manifest_plan=("${reply[@]}")

  local -a restore_plan=()
  local record="" relative="" expected_source="" destination="" live_state=""
  local parent_state=""
  for record in "${manifest_plan[@]}"; do
    relative="${record%%|*}"
    expected_source="${record#*|}"
    destination="${HOME:A}/$relative"
    [[ "$destination" == "${destination:A}" ]] || {
      _ai_error "Restore destination is not canonical: $relative"
      return 1
    }
    _ai_config_live_capture "$destination" || {
      _ai_error "Restore destination is unsafe: $destination"
      return 1
    }
    live_state="$REPLY"
    _ai_config_parent_chain "${destination:h}" || {
      _ai_error "Restore parent chain is unsafe: ${destination:h}"
      return 1
    }
    parent_state="$REPLY"
    [[ ! -e "$destination.bak.$token" && ! -L "$destination.bak.$token" ]] || {
      _ai_error "Rollback path already exists: $destination.bak.$token"
      return 1
    }
    restore_plan+=("$relative"$'\t'"$expected_source"$'\t'"$live_state"$'\t'"$parent_state")
  done

  _ai_header "AI Configuration Restore Plan"
  _ai_info "Snapshot: $token"
  for record in "${restore_plan[@]}"; do
    IFS=$'\t' read -r relative expected_source live_state parent_state <<< "$record"
    _ai_info "files/$relative -> ${HOME:A}/$relative"
  done
  if (( _AI_DRY_RUN )); then
    _ai_info "Dry run: no live configuration was changed."
    return 0
  fi
  _ai_authorize "Restore these ${#restore_plan[@]} configuration file(s)?"
  local authorize_rc=$?
  (( authorize_rc == 130 )) && return 0
  (( authorize_rc == 0 )) || return $authorize_rc

  _ai_config_backup_root_check "$backup_root" \
    && [[ "$REPLY" == "$root_identity" ]] \
    && _ai_config_snapshot_check "$backup_root" "$token" \
    && [[ "$REPLY" == "$snapshot_identity" ]] || {
    _ai_error "Snapshot identity changed after review."
    return 1
  }

  # Validate every reviewed parent before creating any missing directory.
  for record in "${restore_plan[@]}"; do
    IFS=$'\t' read -r relative expected_source live_state parent_state <<< "$record"
    destination="${HOME:A}/$relative"
    _ai_config_parent_chain "${destination:h}" \
      && [[ "$REPLY" == "$parent_state" ]] || {
      _ai_error "Restore parent chain changed after review: ${destination:h}"
      return 1
    }
  done
  for record in "${restore_plan[@]}"; do
    IFS=$'\t' read -r relative expected_source live_state parent_state <<< "$record"
    destination="${HOME:A}/$relative"
    _ai_config_prepare_parent "${destination:h}" || {
      _ai_error "Could not prepare a safe destination parent: ${destination:h}"
      return 1
    }
  done
  local -A prepared_parents=()
  for record in "${restore_plan[@]}"; do
    IFS=$'\t' read -r relative expected_source live_state parent_state <<< "$record"
    destination="${HOME:A}/$relative"
    _ai_config_parent_chain "${destination:h}" || return 1
    prepared_parents[$relative]="$REPLY"
  done

  local -i restored=0 failures=0
  local source_file="" new_file="" rollback_file="" expected_live=""
  for record in "${restore_plan[@]}"; do
    IFS=$'\t' read -r relative expected_source expected_live parent_state <<< "$record"
    source_file="$snapshot/files/$relative"
    destination="${HOME:A}/$relative"
    rollback_file="$destination.bak.$token"
    new_file=""

    _ai_config_snapshot_source_matches "$source_file" "$expected_source" \
      && _ai_config_live_matches "$destination" "$expected_live" \
      && _ai_config_parent_chain "${destination:h}" \
      && [[ "$REPLY" == "${prepared_parents[$relative]}" ]] || {
      _ai_error "Restore source or destination changed after review: $relative"
      (( failures += 1 ))
      continue
    }
    new_file=$(umask 077; command mktemp \
      "${destination:h}/.zdx-ai-restore-${token}.XXXXXX" 2>/dev/null) || {
      _ai_error "Could not reserve private restore staging: $relative"
      (( failures += 1 ))
      continue
    }
    local -A staged_before=() staged_after=()
    [[ "$new_file" == "${new_file:A}" && "${new_file:h}" == "${destination:h}" \
      && "${new_file:t}" == .zdx-ai-restore-${token}.* \
      && -f "$new_file" && ! -L "$new_file" && -O "$new_file" ]] \
      && zstat -LH staged_before -- "$new_file" 2>/dev/null \
      && (( staged_before[uid] == EUID && staged_before[nlink] == 1 \
        && (staged_before[mode] & 8#170000) == 8#100000 \
        && (staged_before[mode] & 8#077) == 0 )) || {
      _ai_error "Refusing unsafe restore staging: $relative"
      (( failures += 1 ))
      continue
    }
    command cp -- "$source_file" "$new_file" || {
      _ai_error "Could not stage restored content: $relative"
      command rm -f -- "$new_file" 2>/dev/null || true
      (( failures += 1 ))
      continue
    }
    command chmod 600 -- "$new_file" 2>/dev/null || {
      command rm -f -- "$new_file" 2>/dev/null
      (( failures += 1 ))
      continue
    }
    zstat -LH staged_after -- "$new_file" 2>/dev/null \
      && [[ "${staged_before[device]}:${staged_before[inode]}:"\
"${staged_before[uid]}:${staged_before[nlink]}" \
        == "${staged_after[device]}:${staged_after[inode]}:"\
"${staged_after[uid]}:${staged_after[nlink]}" ]] || {
      _ai_error "Restore staging identity changed: $relative"
      (( failures += 1 ))
      continue
    }
    _ai_config_digest "$new_file"
    local staged_digest="$REPLY"
    [[ "$staged_digest" == "${expected_source##*|}" ]] || {
      _ai_error "Staged restore verification failed: $relative"
      command rm -f -- "$new_file" 2>/dev/null
      (( failures += 1 ))
      continue
    }
    _ai_config_live_matches "$destination" "$expected_live" || {
      _ai_error "Destination changed immediately before replacement: $relative"
      command rm -f -- "$new_file" 2>/dev/null
      (( failures += 1 ))
      continue
    }
    _ai_config_parent_chain "${destination:h}" \
      && [[ "$REPLY" == "${prepared_parents[$relative]}" ]] || {
      _ai_error "Destination parent changed immediately before replacement."
      command rm -f -- "$new_file" 2>/dev/null
      (( failures += 1 ))
      continue
    }

    if [[ "$expected_live" != "absent" ]]; then
      [[ ! -e "$rollback_file" && ! -L "$rollback_file" ]] \
        && command ln -- "$destination" "$rollback_file" 2>/dev/null || {
        _ai_error "Could not create rollback file: $rollback_file"
        command rm -f -- "$new_file" 2>/dev/null
        (( failures += 1 ))
        continue
      }
      if _ai_config_replace_file "$new_file" "$destination" \
        && _ai_config_digest "$destination" \
        && [[ "$REPLY" == "${expected_source##*|}" ]]; then
        _ai_success "Restored $relative"
        _ai_info "Rollback copy: $rollback_file"
        (( restored += 1 ))
      else
        _ai_error "Replacement failed; preserving rollback: $relative"
        command rm -f -- "$new_file" 2>/dev/null || true
        if [[ ! -e "$destination" && ! -L "$destination" ]]; then
          command ln -- "$rollback_file" "$destination" 2>/dev/null || true
        fi
        (( failures += 1 ))
      fi
    else
      if command ln -- "$new_file" "$destination" 2>/dev/null \
        && command rm -f -- "$new_file" 2>/dev/null \
        && _ai_config_digest "$destination" \
        && [[ "$REPLY" == "${expected_source##*|}" ]]; then
        _ai_success "Restored $relative"
        (( restored += 1 ))
      else
        _ai_error "No-clobber publication failed: $relative"
        if [[ -f "$new_file" && ! -L "$new_file" ]]; then
          command rm -f -- "$new_file" 2>/dev/null || true
        fi
        (( failures += 1 ))
      fi
    fi
  done

  _ai_info "Restore completed for $restored of ${#restore_plan[@]} file(s)."
  (( failures == 0 ))
}

# Atomically replace an existing regular-file destination with its staged
# same-directory sibling. GNU and BusyBox `mv -T` refuse at rename(2) level
# to descend into a directory that raced into place; where the host mv lacks
# `-T` (BSD and macOS), fall back to Zsh's rename builtin behind an explicit
# directory recheck. The remaining same-EUID window matches the repository's
# portable-path limit, and the caller's digest postcondition still rejects a
# misdirected publication.
_ai_config_replace_file() {
  local staged="${1:-}" destination="${2:-}"
  [[ -n "$staged" && -f "$staged" && ! -L "$staged" \
    && -n "$destination" ]] || return 1

  # Probe -T support per invocation: PATH and the mv implementation can
  # change during a long-lived shell, so the result is never cached globally.
  local probe_dir=""
  probe_dir=$(umask 077; command mktemp -d \
    "${TMPDIR:-/tmp}/zdx-ai-mvprobe.XXXXXX" 2>/dev/null) || return 1
  local -i mv_t_supported=0
  if : > "$probe_dir/a" 2>/dev/null && : > "$probe_dir/b" 2>/dev/null \
    && command mv -T -- "$probe_dir/a" "$probe_dir/b" 2>/dev/null; then
    mv_t_supported=1
  fi
  command rm -rf -- "$probe_dir" 2>/dev/null

  if (( mv_t_supported )); then
    command mv -T -- "$staged" "$destination" 2>/dev/null
    return $?
  fi

  zmodload -F zsh/files b:zf_mv 2>/dev/null || return 1
  [[ -d "$destination" ]] && return 1
  zf_mv -f -- "$staged" "$destination" 2>/dev/null || return 1
  if [[ -d "$destination" ]]; then
    # A directory raced into place and the rename descended into it; contain
    # the misplaced staged file and report failure so rollback is preserved.
    command rm -f -- "$destination/${staged:t}" 2>/dev/null
    return 1
  fi
  [[ -f "$destination" && ! -L "$destination" ]]
}

typeset -g _AI_CONFIG_SOURCED=1
