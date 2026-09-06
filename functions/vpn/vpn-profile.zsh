#!/usr/bin/env zsh
# =============================================================================
# VPN Profile: create, import, rename, and remove WireGuard profiles
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh, vpn-state.zsh, and vpn-wsl.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_VPN_PROFILE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Profile content helpers ------------------------------------------------

_vpn_profile_template() {
  print -r -- "[Interface]"
  print -r -- "PrivateKey ="
  print -r -- "Address ="
  print -r -- "DNS ="
  print -r -- ""
  print -r -- "[Peer]"
  print -r -- "PublicKey ="
  print -r -- "AllowedIPs = 0.0.0.0/0"
  print -r -- "Endpoint ="
  print -r -- "PersistentKeepalive = 25"
}

_vpn_validate_profile_file() {
  local src="${1:-}"
  _vpn_user_file_fingerprint "$src" "profile source" >/dev/null || return 1

  # Imported hooks would be executed as root by wg-quick. The suite never
  # imports them from an untrusted file; trusted WSL hooks are generated later
  # from validated literals by vpn-wsl.zsh.
  if command head -c "$_VPN_MAX_PROFILE_BYTES" -- "$src" 2>/dev/null \
    | command grep -Eiq \
      '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown)[[:space:]]*='; then
    _vpn_error \
      "Imported profiles must not contain PreUp/PostUp/PreDown/PostDown hooks."
    _vpn_info \
      "Import the profile without hooks, then add reviewed commands with vpn-config-edit."
    return 1
  fi

  command head -c "$_VPN_MAX_PROFILE_BYTES" -- "$src" 2>/dev/null \
    | command grep -q '^\[Interface\]' \
    && command head -c "$_VPN_MAX_PROFILE_BYTES" -- "$src" 2>/dev/null \
      | command grep -q '^\[Peer\]'
}

_vpn_expand_import_path() {
  local source_path="${1:-}"
  [[ -n "$source_path" ]] || return 1

  case "$source_path" in
    "~")   source_path="$HOME" ;;
    "~/"*) source_path="$HOME/${source_path#~/}" ;;
    "~"*)  _vpn_error "Only '~' for the current user is supported."; return 1 ;;
  esac

  print -r -- "${source_path:a}"
}

# Prompts for a profile name and validates it before returning.
# stdout: the validated name. Status 1 when cancelled or invalid.
_vpn_prompt_profile_name() {
  local prompt="${1:-Profile name}"
  local default_name="${2:-}"

  local name
  name=$(_vpn_read_line "$prompt" "$default_name") || return 1

  if ! _vpn_validate_iface_name "$name"; then
    _vpn_error "Invalid profile name: $name"
    _vpn_info \
      "Names must start with a letter or digit and may contain . _ - only."
    return 1
  fi
  print -r -- "$name"
}

_vpn_offer_set_default_profile() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 0

  # Only offer when nothing is configured yet, so an existing choice is never
  # silently replaced.
  _vpn_read_default_iface >/dev/null 2>&1 && return 0

  local outcome
  outcome=$(_vpn_confirm_outcome "Set ${iface} as the default VPN profile?")
  [[ "$outcome" == "confirmed" ]] || return 0

  if _vpn_set_default_iface "$iface"; then
    _vpn_success "Default VPN profile: $iface"
  else
    _vpn_warn "Saved the profile, but could not record it as the default."
  fi
  return 0
}

# Installs staged content as a root-owned mode-600 profile. The target is
# revalidated after authentication so an existing profile is never clobbered.
_vpn_profile_install() {
  local staged="$1"
  local conf_file="$2"
  local staged_fingerprint directory_identity

  staged_fingerprint=$(
    _vpn_user_file_fingerprint "$staged" "staged profile"
  ) || return 1
  directory_identity=$(_vpn_config_dir_identity) || return 1
  [[ "$(_vpn_profile_path_state "$conf_file")" == "missing" ]] || {
    _vpn_error "Refusing to replace an existing or unsafe profile: $conf_file"
    return 1
  }

  _vpn_announce_privileged "install -m 600 -- <staged profile> $conf_file"
  _vpn_ensure_sudo_access "Writing the VPN profile" || return 1

  _vpn_atomic_install_staged "$staged" "$conf_file" \
    "$staged_fingerprint" "missing" "$directory_identity" "profile-install"
}

# --- Public commands --------------------------------------------------------

# vpn-profile-create
#   Arguments: [PROFILE] | --help
#   stdout:    none.
#   Effects:   writes a mode-600 skeleton profile owned by root.
#   Status:    0 on success or cancellation, 1 on failure, 2 on bad arguments.
vpn-profile-create() {
  local -a positional=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: vpn-profile-create [PROFILE]"
        print -u2 -r -- \
          "  Create a skeleton profile; the name is prompted when omitted."
        return 0
        ;;
      --) shift; positional+=("$@"); break ;;
      -*) _vpn_error "Unknown option: $1"; return 2 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  if (( ${#positional[@]} > 1 )); then
    _vpn_error "vpn-profile-create accepts a single profile name."
    return 2
  fi
  local iface="${positional[1]:-}"

  _vpn_require_platform || return 1
  _vpn_ensure_profile_dir || return 1

  if [[ -n "$iface" ]] && ! _vpn_validate_iface_name "$iface"; then
    _vpn_error "Invalid profile name: $iface"
    return 2
  fi

  if [[ -z "$iface" ]]; then
    iface=$(_vpn_prompt_profile_name "New VPN profile name") || {
      _vpn_info "Cancelled."
      return 0
    }
  fi

  local conf_file
  conf_file=$(_vpn_conf_path "$iface") || {
    _vpn_error "Invalid profile name: $iface"
    return 1
  }

  if _vpn_config_exists "$iface" || _vpn_sudo_probe test -e "$conf_file"; then
    _vpn_error "Profile already exists: $iface"
    return 1
  fi

  _vpn_header "Create VPN Profile ($iface)"

  # Stage in a private directory rather than a shared temporary path.
  local stage_dir
  stage_dir=$(_vpn_make_private_temp_dir "zdx-vpn-stage") || {
    _vpn_error "Could not create a temporary staging directory."
    return 1
  }
  local stage_identity
  stage_identity=$(
    _vpn_private_dir_identity "$stage_dir" "profile staging directory"
  ) || return 1

  {
    local staged="${stage_dir}/${iface}.conf"
    _vpn_profile_template > "$staged" || {
      _vpn_error "Could not stage the profile template."
      return 1
    }
    command chmod 600 -- "$staged" 2>/dev/null || {
      _vpn_error "Could not make the staged profile owner-only."
      return 1
    }

    _vpn_profile_install "$staged" "$conf_file" || {
      _vpn_error "Failed to create profile: $iface"
      return 1
    }
  } always {
    if _vpn_assert_private_dir_identity \
      "$stage_dir" "profile staging directory" "$stage_identity" 2>/dev/null; then
      local cleanup_entry
      for cleanup_entry in "$stage_dir"/*(DN); do
        [[ -f "$cleanup_entry" && ! -L "$cleanup_entry" ]] \
          && command rm -f -- "$cleanup_entry" 2>/dev/null
      done
      command rmdir -- "$stage_dir" 2>/dev/null
    else
      _vpn_warn "The staging directory changed; refusing automatic cleanup."
    fi
  }

  _vpn_success "Created profile: $iface"
  _vpn_dim "Profile names come from the .conf filename (${iface}.conf -> ${iface})."

  _vpn_offer_set_default_profile "$iface"

  local outcome
  outcome=$(_vpn_confirm_outcome "Open ${iface}.conf now?")
  [[ "$outcome" == "confirmed" ]] && vpn-config-edit "$iface"
  return 0
}

# vpn-profile-import
#   Arguments: [PATH] | --help
#   stdout:    none.
#   Effects:   installs an existing .conf as a mode-600 root-owned profile and,
#              under WSL, offers DNS leak hardening.
#   Status:    0 on success or cancellation, 1 on failure, 2 on bad arguments.
vpn-profile-import() {
  local -a positional=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: vpn-profile-import [PATH]"
        print -u2 -r -- \
          "  Import a .conf file; the path is prompted when omitted."
        return 0
        ;;
      --) shift; positional+=("$@"); break ;;
      -*) _vpn_error "Unknown option: $1"; return 2 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  if (( ${#positional[@]} > 1 )); then
    _vpn_error "vpn-profile-import accepts a single path."
    return 2
  fi
  local source_path="${positional[1]:-}"
  local -i hardening_failed=0

  _vpn_require_platform || return 1
  _vpn_ensure_profile_dir || return 1

  if [[ -z "$source_path" ]]; then
    source_path=$(_vpn_read_line "Path to the .conf file") || {
      _vpn_info "Cancelled."
      return 0
    }
  fi

  local resolved
  resolved=$(_vpn_expand_import_path "$source_path") || return 1

  if [[ ! -f "$resolved" || -L "$resolved" ]]; then
    _vpn_error "Profile source file not found: $resolved"
    return 1
  fi

  local source_fingerprint
  source_fingerprint=$(
    _vpn_user_file_fingerprint "$resolved" "profile source"
  ) || return 1

  if ! _vpn_validate_profile_file "$resolved"; then
    _vpn_error "That file does not look like a WireGuard profile."
    _vpn_info \
      "It must be owner-only, at most $_VPN_MAX_PROFILE_BYTES bytes, contain"
    _vpn_info \
      "[Interface] and [Peer], and contain no root-executed lifecycle hooks."
    return 1
  fi

  local default_name="${${resolved:t}%.conf}"
  local iface
  iface=$(_vpn_prompt_profile_name "Import profile as" "$default_name") || {
    _vpn_info "Cancelled."
    return 0
  }

  local conf_file
  conf_file=$(_vpn_conf_path "$iface") || {
    _vpn_error "Invalid profile name: $iface"
    return 1
  }

  if _vpn_config_exists "$iface" || _vpn_sudo_probe test -e "$conf_file"; then
    _vpn_error "Profile already exists: $iface"
    _vpn_info "Choose another name, or remove the existing profile first."
    return 1
  fi

  _vpn_header "Import VPN Profile ($iface)"
  _vpn_info "Plan: install $resolved as $conf_file (mode 600, owned by root)"

  local stage_dir stage_identity staged
  stage_dir=$(_vpn_make_private_temp_dir "zdx-vpn-import") || {
    _vpn_error "Could not create a private import staging directory."
    return 1
  }
  stage_identity=$(
    _vpn_private_dir_identity "$stage_dir" "import staging directory"
  ) || return 1
  staged="${stage_dir}/${iface}.conf"

  {
    command cp -- "$resolved" "$staged" 2>/dev/null || {
      _vpn_error "Could not stage the profile source."
      return 1
    }
    command chmod 600 -- "$staged" 2>/dev/null || return 1

    local current_source_fingerprint
    current_source_fingerprint=$(
      _vpn_user_file_fingerprint "$resolved" "profile source"
    ) || return 1
    if [[ "$current_source_fingerprint" != "$source_fingerprint" ]]; then
      _vpn_error "The profile source changed while it was staged."
      return 1
    fi
    _vpn_validate_profile_file "$staged" || {
      _vpn_error "The staged profile failed validation."
      return 1
    }

    _vpn_profile_install "$staged" "$conf_file" || {
      _vpn_error "Failed to import profile: $iface"
      return 1
    }
  } always {
    if _vpn_assert_private_dir_identity \
      "$stage_dir" "import staging directory" "$stage_identity" 2>/dev/null; then
      [[ -f "$staged" && ! -L "$staged" ]] \
        && command rm -f -- "$staged" 2>/dev/null
      command rmdir -- "$stage_dir" 2>/dev/null
    else
      _vpn_warn \
        "The import staging directory changed; refusing automatic cleanup."
    fi
  }

  _vpn_success "Imported profile: $iface"
  _vpn_dim "Profile names come from the .conf filename (${iface}.conf -> ${iface})."

  if _vpn_is_wsl; then
    _vpn_blank
    _vpn_info "WSL detected — WireGuard normally leaks DNS via the Windows relay."
    _vpn_dim \
      "Hardening pins /etc/resolv.conf to the tunnel resolver while up and to"
    _vpn_dim \
      "public fallbacks (${VPN_DNS_FALLBACK_PRIMARY}, ${VPN_DNS_FALLBACK_SECONDARY}) while down."
    _vpn_dim \
      "The hooks run as root, so the profile's DNS value must be plain IPs."

    local outcome
    outcome=$(_vpn_confirm_outcome "Apply WSL DNS hardening to ${iface}?")
    if [[ "$outcome" == "confirmed" ]]; then
      if _vpn_apply_wsl_dns_hooks "$conf_file"; then
        _vpn_success "Applied WSL DNS hardening to ${iface}."
      else
        _vpn_error "Could not apply the requested WSL DNS hardening."
        _vpn_warn "The profile was imported unchanged and should be reviewed."
        hardening_failed=1
      fi
    fi
  fi

  _vpn_offer_set_default_profile "$iface"

  local edit_outcome
  edit_outcome=$(_vpn_confirm_outcome "Open ${iface}.conf now?")
  [[ "$edit_outcome" == "confirmed" ]] && vpn-config-edit "$iface"
  (( hardening_failed == 0 ))
}

# vpn-profile-rename
#   Arguments: [OLD] [NEW] | --dry-run | --yes | --help
#   Effects:   renames the profile and its backup, and follows the default and
#              last-used pointers.
#   Status:    0 on success or cancellation, 1 on failure, 2 on bad arguments.
vpn-profile-rename() {
  local old_iface="" new_iface=""
  local -i auto_yes=0 dry_run=0
  local -a positional=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- \
          "Usage: vpn-profile-rename [OLD] [NEW] [--dry-run] [--yes]"
        print -u2 -r -- "  Rename a profile by changing its .conf filename."
        print -u2 -r -- "  --dry-run   Show the complete plan and stop."
        print -u2 -r -- "  --yes, -y   Skip the confirmation prompts."
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      --yes|-y) auto_yes=1 ;;
      --) shift; positional+=("$@"); break ;;
      -*) _vpn_error "Unknown option: $1"; return 2 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done

  if (( ${#positional[@]} > 2 )); then
    _vpn_error "vpn-profile-rename accepts at most two profile names."
    return 2
  fi
  old_iface="${positional[1]:-}"
  new_iface="${positional[2]:-}"

  _vpn_require_platform || return 1
  _vpn_ensure_profile_access || return 1

  local name
  for name in "$old_iface" "$new_iface"; do
    if [[ -n "$name" ]] && ! _vpn_validate_iface_name "$name"; then
      _vpn_error "Invalid profile name: $name"
      return 2
    fi
  done

  if [[ -z "$old_iface" ]]; then
    local picked
    local -i pick_status=0
    picked=$(_vpn_pick_profile "Rename VPN profile") || pick_status=$?
    (( pick_status == 130 )) && return 0
    (( pick_status != 0 )) && return 1
    old_iface="$picked"
  fi

  if [[ -z "$new_iface" ]]; then
    new_iface=$(_vpn_prompt_profile_name "Rename profile as" "$old_iface") || {
      _vpn_info "Cancelled."
      return 0
    }
  fi

  if [[ "$old_iface" == "$new_iface" ]]; then
    _vpn_info "The profile name is unchanged."
    return 0
  fi

  local old_conf new_conf old_backup new_backup
  old_conf=$(_vpn_conf_path "$old_iface") || return 1
  new_conf=$(_vpn_conf_path "$new_iface") || return 1
  old_backup=$(_vpn_backup_path "$old_iface") || return 1
  new_backup=$(_vpn_backup_path "$new_iface") || return 1

  local directory_identity old_fingerprint old_backup_fingerprint=""
  local old_state new_state old_backup_state new_backup_state
  directory_identity=$(_vpn_config_dir_identity) || return 1
  old_state=$(_vpn_profile_path_state "$old_conf")
  new_state=$(_vpn_profile_path_state "$new_conf")
  old_backup_state=$(_vpn_profile_path_state "$old_backup")
  new_backup_state=$(_vpn_profile_path_state "$new_backup")

  [[ "$old_state" == "safe" ]] || {
    _vpn_error "Profile is missing or unsafe: $old_iface"
    return 1
  }
  [[ "$new_state" == "missing" ]] || {
    _vpn_error "Target profile already exists or is unsafe: $new_iface"
    return 1
  }
  case "$old_backup_state" in
    safe)
      old_backup_fingerprint=$(
        _vpn_profile_file_fingerprint "$old_backup" "$old_iface backup"
      ) || return 1
      ;;
    missing) ;;
    *)
      _vpn_error "The backup for $old_iface is unsafe or unreadable."
      return 1
      ;;
  esac
  [[ "$new_backup_state" == "missing" ]] || {
    _vpn_error "A backup target for $new_iface already exists or is unsafe."
    return 1
  }
  old_fingerprint=$(
    _vpn_profile_file_fingerprint "$old_conf" "$old_iface profile"
  ) || return 1

  local last_before default_before
  last_before=$(_vpn_read_last_iface 2>/dev/null) || last_before=""
  default_before=$(_vpn_read_default_iface 2>/dev/null) || default_before=""

  local -i active_known=0 old_active=0
  local -a reply=()
  if _vpn_active_interfaces; then
    active_known=1
    [[ " ${reply[*]} " == *" $old_iface "* ]] && old_active=1
  fi

  _vpn_header "Rename VPN Profile ($old_iface -> $new_iface)"
  _vpn_info "Plan: move $old_conf to $new_conf"
  [[ "$old_backup_state" == "safe" ]] \
    && _vpn_info "      move $old_backup to $new_backup"
  (( old_active )) \
    && _vpn_info "      disconnect $old_iface before moving its profile"
  (( !active_known )) \
    && _vpn_warn "Tunnel activity is unknown; the profile may still be active."

  if (( dry_run )); then
    _vpn_warn "DRY-RUN — nothing was disconnected or renamed."
    return 0
  fi

  local -i previous_auto_yes=$_VPN_AUTO_YES
  {
    (( auto_yes )) && _VPN_AUTO_YES=1

    local outcome
    outcome=$(_vpn_confirm_outcome "Rename ${old_iface} to ${new_iface}?")
    case "$outcome" in
      confirmed) ;;
      unavailable)
        _vpn_error \
          "Interactive confirmation requires a terminal; pass --yes to rename."
        return 1
        ;;
      *)
        _vpn_info "Cancelled. Nothing was renamed."
        return 0
        ;;
    esac

    if (( old_active )); then
      local down_outcome
      down_outcome=$(_vpn_confirm_outcome \
        "Disconnect ${old_iface} before renaming it?")
      if [[ "$down_outcome" != "confirmed" ]]; then
        _vpn_info "Cancelled. Nothing was disconnected or renamed."
        return 0
      fi
    elif (( !active_known )); then
      local continue_outcome
      continue_outcome=$(_vpn_confirm_outcome \
        "Continue while tunnel activity is unknown?")
      if [[ "$continue_outcome" != "confirmed" ]]; then
        _vpn_info "Cancelled. Nothing was renamed."
        return 0
      fi
    fi
  } always {
    _VPN_AUTO_YES=$previous_auto_yes
  }

  if (( old_active )); then
    _vpn_tunnel_down "$old_iface" || return 1
  fi

  _vpn_announce_privileged "mv -- $old_conf $new_conf"
  _vpn_ensure_sudo_access "Renaming the VPN profile" || return 1

  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  local current_fingerprint
  current_fingerprint=$(
    _vpn_profile_file_fingerprint "$old_conf" "$old_iface profile"
  ) || return 1
  if [[ "$current_fingerprint" != "$old_fingerprint" ]]; then
    _vpn_error "$old_conf changed after planning — aborting."
    return 1
  fi
  if [[ "$(_vpn_profile_path_state "$new_conf")" != "missing" ]]; then
    _vpn_error "$new_conf appeared after authentication — aborting."
    return 1
  fi
  if [[ "$old_backup_state" == "safe" ]]; then
    current_fingerprint=$(
      _vpn_profile_file_fingerprint "$old_backup" "$old_iface backup"
    ) || return 1
    [[ "$current_fingerprint" == "$old_backup_fingerprint" ]] || {
      _vpn_error "$old_backup changed after planning — aborting."
      return 1
    }
  elif [[ "$(_vpn_profile_path_state "$old_backup")" != "missing" ]]; then
    _vpn_error "$old_backup appeared after planning — aborting."
    return 1
  fi
  [[ "$(_vpn_profile_path_state "$new_backup")" == "missing" ]] || {
    _vpn_error "$new_backup appeared after planning — aborting."
    return 1
  }

  if ! _vpn_sudo_exec mv -- "$old_conf" "$new_conf"; then
    _vpn_error "Failed to rename the profile."
    return 1
  fi

  if [[ "$old_backup_state" == "safe" ]] \
    && ! _vpn_sudo_exec mv -- "$old_backup" "$new_backup"; then
    _vpn_error "Could not rename the backup; rolling the profile name back."
    if _vpn_sudo_exec mv -- "$new_conf" "$old_conf"; then
      _vpn_info "Rollback completed; nothing remains renamed."
    else
      _vpn_error "Rollback failed; the profile remains at $new_conf."
    fi
    return 1
  fi

  local -i state_failures=0
  if [[ "$last_before" == "$old_iface" ]] \
    && ! _vpn_remember_iface "$new_iface"; then
    _vpn_warn "Renamed the profile, but could not update last-used state."
    (( ++state_failures ))
  fi
  if [[ "$default_before" == "$old_iface" ]]; then
    if ! _vpn_set_default_iface "$new_iface"; then
      _vpn_warn "Renamed the profile, but could not update the default."
      (( ++state_failures ))
    fi
  fi

  _vpn_success "Renamed profile: $old_iface -> $new_iface"
  (( state_failures == 0 )) || {
    _vpn_error \
      "The profile rename succeeded, but $state_failures cached pointer update(s) failed."
    return 1
  }
  return 0
}

# vpn-profile-remove
#   Arguments: [PROFILE] | --dry-run | --yes | --with-backup | --help
#   Effects:   deletes the profile and, when requested, its backup.
#   Status:    0 on success or cancellation, 1 on failure, 2 on bad arguments.
vpn-profile-remove() {
  local -a positional=()
  local -i dry_run=0 auto_yes=0 with_backup=0 backup_flag_given=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- \
          "Usage: vpn-profile-remove [PROFILE] [--with-backup] [--dry-run] [--yes]"
        print -u2 -r -- "  Remove a profile after confirmation."
        print -u2 -r -- \
          "  --with-backup   Also remove ${VPN_BACKUP_SUFFIX} for that profile."
        print -u2 -r -- "  --dry-run       Show the plan and stop."
        print -u2 -r -- \
          "  --yes, -y       Skip the confirmation prompts. The backup is kept"
        print -u2 -r -- \
          "                  unless --with-backup is also given."
        return 0
        ;;
      --dry-run)     dry_run=1 ;;
      --yes|-y)      auto_yes=1 ;;
      --with-backup) with_backup=1; backup_flag_given=1 ;;
      --) shift; positional+=("$@"); break ;;
      -*) _vpn_error "Unknown option: $1"; return 2 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  if (( ${#positional[@]} > 1 )); then
    _vpn_error "vpn-profile-remove accepts a single profile name."
    return 2
  fi
  local iface="${positional[1]:-}"

  _vpn_require_platform || return 1
  _vpn_ensure_profile_access || return 1

  if [[ -n "$iface" ]] && ! _vpn_validate_iface_name "$iface"; then
    _vpn_error "Invalid profile name: $iface"
    return 2
  fi

  if [[ -z "$iface" ]]; then
    local picked
    local -i pick_status=0
    picked=$(_vpn_pick_profile "Remove VPN profile") || pick_status=$?
    (( pick_status == 130 )) && return 0
    (( pick_status != 0 )) && return 1
    iface="$picked"
  fi

  local conf_file bak_file
  conf_file=$(_vpn_conf_path "$iface") || return 1
  bak_file=$(_vpn_backup_path "$iface") || return 1

  local directory_identity profile_fingerprint backup_fingerprint=""
  local profile_state backup_path_state
  directory_identity=$(_vpn_config_dir_identity) || return 1
  profile_state=$(_vpn_profile_path_state "$conf_file")
  [[ "$profile_state" == "safe" ]] || {
    _vpn_error "Profile is missing or unsafe: $iface"
    return 1
  }
  profile_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
  ) || return 1

  backup_path_state=$(_vpn_profile_path_state "$bak_file")
  local -i backup_present=0
  case "$backup_path_state" in
    safe)
      backup_present=1
      backup_fingerprint=$(
        _vpn_profile_file_fingerprint "$bak_file" "$iface backup"
      ) || return 1
      ;;
    missing) ;;
    *)
      _vpn_error "The backup path for $iface is unsafe or unreadable."
      return 1
      ;;
  esac

  local last_before default_before
  last_before=$(_vpn_read_last_iface 2>/dev/null) || last_before=""
  default_before=$(_vpn_read_default_iface 2>/dev/null) || default_before=""

  local -i previous_auto_yes=$_VPN_AUTO_YES
  {
    (( auto_yes )) && _VPN_AUTO_YES=1

    # Ask about the backup only when the caller neither decided on the command
    # line nor passed --yes. Letting --yes answer this question would widen the
    # target set, and --yes may bypass a prompt but never the plan.
    if (( backup_present && ! backup_flag_given && ! auto_yes && !dry_run )); then
      local backup_outcome
      backup_outcome=$(
        _vpn_confirm_outcome "Include ${bak_file:t} in the removal plan?"
      )
      [[ "$backup_outcome" == "confirmed" ]] && with_backup=1
    fi
  } always {
    _VPN_AUTO_YES=$previous_auto_yes
  }

  local -i active_known=0 profile_active=0
  local -a reply=()
  if _vpn_active_interfaces; then
    active_known=1
    [[ " ${reply[*]} " == *" $iface "* ]] && profile_active=1
  fi

  _vpn_header "Remove VPN Profile ($iface)"
  _vpn_info "Plan: delete $conf_file"
  (( backup_present && with_backup )) \
    && _vpn_info "      delete $bak_file"
  (( backup_present && !with_backup )) \
    && _vpn_dim "      keep   $bak_file"
  (( profile_active )) \
    && _vpn_info "      disconnect $iface before deleting its profile"
  (( !active_known )) \
    && _vpn_warn "Tunnel activity is unknown; $iface may still be active."

  if (( dry_run )); then
    _vpn_warn "DRY-RUN — nothing was disconnected or removed."
    return 0
  fi

  previous_auto_yes=$_VPN_AUTO_YES
  {
    (( auto_yes )) && _VPN_AUTO_YES=1
    local outcome
    outcome=$(_vpn_confirm_outcome "Remove VPN profile ${iface}?")
    case "$outcome" in
      confirmed) ;;
      unavailable)
        _vpn_error \
          "Interactive confirmation requires a terminal; pass --yes to remove."
        return 1
        ;;
      *)
        _vpn_info "Cancelled. Nothing was removed."
        return 0
        ;;
    esac
  } always {
    _VPN_AUTO_YES=$previous_auto_yes
  }

  if (( profile_active )); then
    _vpn_tunnel_down "$iface" || return 1
  fi

  _vpn_announce_privileged "rm -f -- $conf_file"
  _vpn_ensure_sudo_access "Removing the VPN profile" || return 1

  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  local current_fingerprint
  current_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
  ) || return 1
  if [[ "$current_fingerprint" != "$profile_fingerprint" ]]; then
    _vpn_error "$conf_file changed after planning — aborting."
    return 1
  fi
  if (( with_backup && backup_present )); then
    current_fingerprint=$(
      _vpn_profile_file_fingerprint "$bak_file" "$iface backup"
    ) || return 1
    [[ "$current_fingerprint" == "$backup_fingerprint" ]] || {
      _vpn_error "$bak_file changed after planning — aborting."
      return 1
    }
  fi

  local -i failures=0
  if ! _vpn_sudo_exec rm -- "$conf_file"; then
    _vpn_error "Could not remove $conf_file; cached pointers were preserved."
    return 1
  fi
  if (( with_backup && backup_present )) \
    && ! _vpn_sudo_exec rm -- "$bak_file"; then
    (( ++failures ))
  fi

  if [[ "$last_before" == "$iface" ]] && ! _vpn_clear_last_iface; then
    _vpn_warn "Removed the profile, but could not clear last-used state."
    (( ++failures ))
  fi
  if [[ "$default_before" == "$iface" ]]; then
    if ! _vpn_clear_default_iface; then
      _vpn_warn "Removed the profile, but could not clear the default."
      (( ++failures ))
    fi
  fi

  if (( failures > 0 )); then
    _vpn_error "Removal of $iface was incomplete ($failures step(s) failed)."
    return 1
  fi

  _vpn_success "Removed profile: $iface"
  return 0
}

typeset -g _VPN_PROFILE_SOURCED=1
