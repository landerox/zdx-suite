#!/usr/bin/env zsh
# =============================================================================
# WS Keys: rotate, show and test workspace SSH keys
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_WS_KEYS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ws_workspace_ssh_dir_safe() {
  local workspace_dir="${1:-}"
  local ssh_dir="${workspace_dir}/.ssh"
  [[ -d "$workspace_dir" && ! -L "$workspace_dir" \
    && "${workspace_dir:a}" == "${workspace_dir:A}" \
    && -d "$ssh_dir" && ! -L "$ssh_dir" && -O "$ssh_dir" \
    && "${ssh_dir:a}" == "${ssh_dir:A}" \
    && "${ssh_dir:h}" == "${workspace_dir:A}" ]]
}

_ws_keypair_is_safe() {
  local ssh_dir="${1:-}"
  local private_key="${2:-}"
  local public_key="${3:-}"
  [[ -d "$ssh_dir" && ! -L "$ssh_dir" && -O "$ssh_dir" \
    && "${ssh_dir:a}" == "${ssh_dir:A}" \
    && "${private_key:h}" == "${ssh_dir:A}" \
    && "${public_key:h}" == "${ssh_dir:A}" \
    && -f "$private_key" && ! -L "$private_key" && -O "$private_key" \
    && "${private_key:a}" == "${private_key:A}" \
    && -f "$public_key" && ! -L "$public_key" && -O "$public_key" \
    && "${public_key:a}" == "${public_key:A}" ]] || return 1

  zmodload zsh/stat 2>/dev/null || return 1
  local -A private_state=() public_state=()
  zstat -H private_state -- "$private_key" 2>/dev/null \
    && zstat -H public_state -- "$public_key" 2>/dev/null \
    && (( private_state[uid] == EUID && private_state[nlink] == 1 \
      && public_state[uid] == EUID && public_state[nlink] == 1 ))
}

# Open the fixed public-key path without following links, validate the held
# inode, and set REPLY to its single bounded line.
_ws_read_workspace_public_key() {
  emulate -L zsh

  local workspace_dir="${1:-}"
  REPLY=""
  _ws_workspace_ssh_dir_safe "$workspace_dir" || return 1

  local ssh_dir="$workspace_dir/.ssh"
  local key_path="$ssh_dir/id_ed25519.pub"
  [[ "${key_path:h}" == "${ssh_dir:A}" \
    && -f "$key_path" && ! -L "$key_path" && -O "$key_path" \
    && "${key_path:a}" == "${key_path:A}" ]] || return 1

  zmodload zsh/stat zsh/system 2>/dev/null || return 1
  local -A before_state=() fd_state=() after_state=()
  zstat -H before_state -- "$key_path" 2>/dev/null || return 1
  (( before_state[uid] == EUID \
    && before_state[nlink] == 1 \
    && before_state[size] > 0 \
    && before_state[size] <= 16384 \
    && (before_state[mode] & 8#22) == 0 )) || return 1

  local -i key_fd=-1 unsafe_content=0 first_read_rc=0
  sysopen -r -o nofollow,cloexec -u key_fd -- "$key_path" 2>/dev/null \
    || return 1
  local key_text="" extra_line=""
  {
    zstat -H fd_state -f "$key_fd" 2>/dev/null || unsafe_content=1
    if (( ! unsafe_content )); then
      IFS= read -r -u "$key_fd" key_text
      first_read_rc=$?
      (( first_read_rc == 0 )) || [[ -n "$key_text" ]] \
        || unsafe_content=1
    fi
    if (( ! unsafe_content )); then
      if IFS= read -r -u "$key_fd" extra_line || [[ -n "$extra_line" ]]; then
        unsafe_content=1
      fi
    fi
    zstat -H after_state -f "$key_fd" 2>/dev/null || unsafe_content=1
  } always {
    exec {key_fd}<&-
  }

  (( ! unsafe_content )) || return 1
  local before_identity="${before_state[device]}:${before_state[inode]}:${before_state[uid]}:${before_state[nlink]}:${before_state[size]}:${before_state[mode]}:${before_state[mtime]}:${before_state[ctime]}"
  local fd_identity="${fd_state[device]}:${fd_state[inode]}:${fd_state[uid]}:${fd_state[nlink]}:${fd_state[size]}:${fd_state[mode]}:${fd_state[mtime]}:${fd_state[ctime]}"
  local after_identity="${after_state[device]}:${after_state[inode]}:${after_state[uid]}:${after_state[nlink]}:${after_state[size]}:${after_state[mode]}:${after_state[mtime]}:${after_state[ctime]}"
  [[ "$fd_identity" == "$before_identity" \
    && "$after_identity" == "$before_identity" \
    && -n "$key_text" \
    && "$key_text" != *[[:cntrl:]]* ]] || return 1

  local -A final_state=()
  zstat -H final_state -- "$key_path" 2>/dev/null || return 1
  local final_identity="${final_state[device]}:${final_state[inode]}:${final_state[uid]}:${final_state[nlink]}:${final_state[size]}:${final_state[mode]}:${final_state[mtime]}:${final_state[ctime]}"
  [[ "$final_identity" == "$before_identity" ]] || return 1

  REPLY="$key_text"
  return 0
}

ws-rotate-key() {
  local REPLY=""
  _ws_parse_no_args ws-rotate-key \
    "Back up the current keypair, generate a replacement, and optionally prune backups." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1

  local ws=""
  _ws_capture_workspace_selection "Rotate key for" || return $?
  ws="$REPLY"
  [[ -z "$ws" ]] && return 0

  _ws_resolve_workspace "$ws" || return $?
  local ws_dir="$REPLY"
  [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
    _tk_error "Workspace not found: ${(V)ws}"
    return 1
  }
  local ssh_dir="$ws_dir/.ssh"
  [[ -d "$ssh_dir" && ! -L "$ssh_dir" \
    && "${ssh_dir:a}" == "${ssh_dir:A}" ]] || {
    _tk_error "Refusing unsafe workspace SSH directory."
    return 1
  }
  local key_path="$ssh_dir/id_ed25519"
  local public_key_path="${key_path}.pub"
  if [[ -e "$key_path" || -L "$key_path" \
    || -e "$public_key_path" || -L "$public_key_path" ]]; then
    [[ -f "$key_path" && ! -L "$key_path" && -O "$key_path" \
      && -f "$public_key_path" && ! -L "$public_key_path" \
      && -O "$public_key_path" ]] || {
      _tk_error "The current SSH keypair is incomplete or unsafe."
      return 1
    }
  fi
  local hostname=""
  hostname=$(_tk_hostname "${ws%%/*}" "$ws_dir")

  _tk_header "Rotate SSH Key: $ws"

  if [[ -f "$key_path" ]]; then
    _tk_warn "Current key fingerprint:"
    ssh-keygen -lf "$public_key_path" >&2
    print -u2 -r -- ""
  fi

  if ! _tk_confirm "Generate new key? (old key will be backed up)"; then
    _tk_info "Cancelled."
    return 0
  fi

  # Get email from gitconfig
  local email=""
  email=$(git config --file "$ws_dir/.gitconfig" user.email 2>/dev/null) \
    || email=""

  local temp_dir=""
  local new_key=""
  local new_public_key=""
  local backup=""
  local -i had_existing_key=0
  [[ -f "$key_path" ]] && had_existing_key=1

  {
    temp_dir=$(mktemp -d "$ssh_dir/.zdx-key.XXXXXX") || {
      _tk_error "Could not create a private key-generation directory."
      return 1
    }
    command chmod 700 "$temp_dir" || return 1
    new_key="$temp_dir/id_ed25519"
    new_public_key="${new_key}.pub"

    ssh-keygen -t ed25519 -C "${email:-workspace}" \
      -f "$new_key" -N "" -q || {
      _tk_error "SSH key generation failed; the current key was not changed."
      return 1
    }
    [[ -f "$new_key" && ! -L "$new_key" && -O "$new_key" \
      && -f "$new_public_key" && ! -L "$new_public_key" \
      && -O "$new_public_key" ]] || {
      _tk_error "ssh-keygen did not produce a safe keypair."
      return 1
    }
    command chmod 600 "$new_key" \
      && command chmod 644 "$new_public_key" || return 1

    _ws_resolve_workspace "$ws" || return $?
    [[ "$REPLY" == "$ws_dir" && -d "$ssh_dir" && ! -L "$ssh_dir" \
      && "${ssh_dir:a}" == "${ssh_dir:A}" ]] || {
      _tk_error "Workspace SSH target changed before key installation."
      return 1
    }

    if (( had_existing_key )); then
      [[ -f "$key_path" && ! -L "$key_path" && -O "$key_path" \
        && -f "$public_key_path" && ! -L "$public_key_path" \
        && -O "$public_key_path" ]] || {
        _tk_error "The current SSH keypair changed before backup."
        return 1
      }
      backup="${key_path}.bak.$(date +%Y%m%d%H%M%S).$$.$RANDOM"
      [[ ! -e "$backup" && ! -L "$backup" \
        && ! -e "${backup}.pub" && ! -L "${backup}.pub" ]] || {
        _tk_error "Could not allocate a unique SSH key backup name."
        return 1
      }
      command mv -- "$key_path" "$backup" || return 1
      if ! command mv -- "$public_key_path" "${backup}.pub"; then
        command mv -- "$backup" "$key_path" 2>/dev/null
        _tk_error "Could not back up the current public key."
        return 1
      fi
    fi

    if ! command mv -- "$new_key" "$key_path"; then
      if (( had_existing_key )); then
        command mv -- "$backup" "$key_path" 2>/dev/null
        command mv -- "${backup}.pub" "$public_key_path" 2>/dev/null
      fi
      _tk_error "Could not install the new private key."
      return 1
    fi
    if ! command mv -- "$new_public_key" "$public_key_path"; then
      command rm -f -- "$key_path"
      if (( had_existing_key )); then
        command mv -- "$backup" "$key_path" 2>/dev/null
        command mv -- "${backup}.pub" "$public_key_path" 2>/dev/null
      fi
      _tk_error "Could not install the new public key."
      return 1
    fi
    if ! command chmod 600 "$key_path" \
      || ! command chmod 644 "$public_key_path"; then
      command rm -f -- "$key_path" "$public_key_path"
      if (( had_existing_key )); then
        command mv -- "$backup" "$key_path" 2>/dev/null
        command mv -- "${backup}.pub" "$public_key_path" 2>/dev/null
      fi
      _tk_error "Could not apply safe permissions to the new keypair."
      return 1
    fi
  } always {
    if [[ -n "$temp_dir" && "$temp_dir" == "$ssh_dir"/.zdx-key.* \
      && -d "$temp_dir" && ! -L "$temp_dir" ]]; then
      command rm -rf -- "$temp_dir"
    fi
  }

  _tk_success "New key generated!"
  [[ -n "$backup" ]] && _tk_info "Old key backed up to: ${backup:t}"
  local new_public_key_text=""
  _ws_read_workspace_public_key "$ws_dir" || {
    _tk_error "The generated public key could not be revalidated."
    return 1
  }
  new_public_key_text="$REPLY"
  print -u2 -r -- ""
  print -u2 -r -- "  📋 New public key (copy to $hostname):"
  print -u2 -r -- ""
  print -u2 -r -- "  ${new_public_key_text}"
  print -u2 -r -- ""
  _tk_warn "Remember to update this key on $hostname!"

  # Count only complete, safe private/public backup pairs. A `.pub` companion
  # is never treated as another private backup.
  local -a safe_backups=()
  local bak="" backup_public=""
  local -i unsafe_backup_count=0
  for bak in "$ssh_dir"/id_ed25519.bak.*(N); do
    [[ "$bak" == *.pub ]] && continue
    backup_public="${bak}.pub"
    if _ws_keypair_is_safe "$ssh_dir" "$bak" "$backup_public"; then
      safe_backups+=("$bak")
    else
      (( ++unsafe_backup_count ))
    fi
  done
  local -i backup_count=${#safe_backups[@]}
  (( unsafe_backup_count > 0 )) \
    && _tk_warn \
      "Skipped $unsafe_backup_count incomplete or unsafe SSH key backup pair(s)."
  if (( backup_count > 2 )); then
    print -u2 -r -- ""
    _tk_warn "You have $backup_count old key backups in .ssh/"
    if _tk_confirm "Delete old backups? (keeps the most recent one)"; then
      safe_backups=("${(@O)safe_backups}")
      local -i backup_index=0 cleanup_failed=0
      for (( backup_index = 2; backup_index <= backup_count; ++backup_index )); do
        bak="${safe_backups[$backup_index]}"
        backup_public="${bak}.pub"
        if ! _ws_keypair_is_safe "$ssh_dir" "$bak" "$backup_public"; then
          _tk_error \
            "Backup pair changed before cleanup: ${(V)${bak:t}}"
          cleanup_failed=1
          continue
        fi
        command rm -f -- "$bak" "$backup_public" 2>/dev/null \
          || cleanup_failed=1
      done
      if (( cleanup_failed )); then
        _tk_error "One or more SSH key backup pairs could not be cleaned."
        return 1
      fi
      _tk_success "Cleaned old backups (kept the most recent pair)"
    fi
  fi

  if [[ "$hostname" == "github.com" ]]; then
    _tk_info "Go to: https://github.com/settings/keys"
  elif [[ "$hostname" == "gitlab.com" ]]; then
    _tk_info "Go to: https://gitlab.com/-/user_settings/ssh_keys"
  else
    _tk_info "Go to: https://$hostname/-/user_settings/ssh_keys"
  fi
}

ws-show-key() {
  local REPLY=""
  _ws_parse_no_args ws-show-key \
    "Display and optionally copy the selected workspace public key." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1

  local ws=""
  _ws_capture_workspace_selection "Show key for" || return $?
  ws="$REPLY"
  [[ -z "$ws" ]] && return 0

  _ws_resolve_workspace "$ws" || return $?
  local ws_dir="$REPLY"
  [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
    _tk_error "Workspace not found: ${(V)ws}"
    return 1
  }
  local public_key=""
  _ws_read_workspace_public_key "$ws_dir" || {
    _tk_error "No safe public key found for $ws"
    return 1
  }
  public_key="$REPLY"

  _tk_header "Public Key: $ws"
  print -u2 -r -- ""
  print -u2 -r -- "  ${public_key}"
  print -u2 -r -- ""
  local fingerprint=""
  fingerprint=$(print -r -- "$public_key" \
    | ssh-keygen -lf - 2>/dev/null) || fingerprint="unavailable"
  print -u2 -r -- "  Fingerprint: $fingerprint"
  print -u2 -r -- ""

  # Copy to clipboard if possible
  local clipboard_command=""
  if command -v clip.exe &>/dev/null; then
    clipboard_command="clip.exe"
  elif command -v xclip &>/dev/null; then
    clipboard_command="xclip"
  elif command -v pbcopy &>/dev/null; then
    clipboard_command="pbcopy"
  else
    _tk_info "Copy the key above manually."
    return 0
  fi

  _ws_read_workspace_public_key "$ws_dir" || {
    _tk_error "The public key changed before clipboard publication."
    return 1
  }
  [[ "$REPLY" == "$public_key" ]] || {
    _tk_error "The public key changed before clipboard publication."
    return 1
  }
  case "$clipboard_command" in
    clip.exe)
      print -r -- "$public_key" | command clip.exe || return 1
      ;;
    xclip)
      print -r -- "$public_key" \
        | command xclip -selection clipboard || return 1
      ;;
    pbcopy)
      print -r -- "$public_key" | command pbcopy || return 1
      ;;
  esac
  _tk_success "Copied to clipboard! ($clipboard_command)"
}

ws-test() {
  local REPLY=""
  _ws_parse_no_args ws-test \
    "Test one workspace SSH alias in batch mode with strict host-key checking." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen ssh fzf || return 1

  local ws=""
  _ws_capture_workspace_selection "Test connection for" || return $?
  ws="$REPLY"
  [[ -z "$ws" ]] && return 0

  local platform="${ws%%/*}"
  local identity="${ws#*/}"
  _ws_resolve_workspace "$ws" || return $?
  local ws_dir="$REPLY"
  [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
    _tk_error "Workspace not found: ${(V)ws}"
    return 1
  }
  local host_alias=""
  host_alias=$(_tk_host_alias "$platform" "$identity")
  local hostname=""
  hostname=$(_tk_hostname "$platform" "$ws_dir")

  _tk_header "Test Connection: $ws"
  _tk_info "Testing: ssh -T git@${host_alias}"
  local connect_timeout="${WS_SSH_CONNECT_TIMEOUT:-10}"
  [[ "$connect_timeout" =~ '^[1-9][0-9]*$' \
    && ${#connect_timeout} -le 2 ]] \
    && (( connect_timeout <= 60 )) || {
    _tk_error "WS_SSH_CONNECT_TIMEOUT must be between 1 and 60 seconds."
    return 2
  }

  local -i ssh_probe_rc=0
  _ws_ssh_probe "$host_alias" "$connect_timeout" \
    "$(( connect_timeout + 5 ))" || ssh_probe_rc=$?
  case "$ssh_probe_rc" in
    0)
      _tk_success "SSH authentication accepted for '$host_alias'."
      return 0
      ;;
    124)
      _tk_error "SSH connection test timed out."
      return 124
      ;;
    *)
      _tk_error "SSH authentication was not accepted for '$host_alias'."
      return $ssh_probe_rc
      ;;
  esac
}

typeset -g _WS_KEYS_SOURCED=1
