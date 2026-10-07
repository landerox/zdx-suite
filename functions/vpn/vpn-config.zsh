#!/usr/bin/env zsh
# =============================================================================
# VPN Config: edit, restore, and inspect WireGuard profile files
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh and vpn-state.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_VPN_CONFIG_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Privileged editing -----------------------------------------------------

# Opens a root-owned profile through sudoedit, which copies the file, runs the
# editor as the invoking user, and reinstalls the result as root. Running the
# editor itself as root would hand a shell escape (`:!sh`) full privileges.
_vpn_edit_privileged() {
  local conf_file="$1"
  local expected_fingerprint="$2"
  local directory_identity="$3"

  if ! command -v sudoedit &>/dev/null && ! command -v sudo &>/dev/null; then
    _vpn_error "Neither sudoedit nor sudo is available on this host."
    return 1
  fi

  _vpn_announce_privileged "sudoedit -- $conf_file"
  _vpn_ensure_sudo_access "Editing the VPN profile" || return 1
  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  local current_fingerprint
  current_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "profile selected for editing"
  ) || return 1
  if [[ "$current_fingerprint" != "$expected_fingerprint" ]]; then
    _vpn_error "The profile changed after confirmation; the editor was not opened."
    return 1
  fi

  _vpn_info "Your editor runs as your own user; sudo reinstalls the result."
  _vpn_dim "sudoedit honors SUDO_EDITOR, then VISUAL, then EDITOR."

  local -i edit_status=0
  if command -v sudoedit &>/dev/null; then
    command sudoedit -n -- "$conf_file" || edit_status=$?
  else
    command sudo -n -e -- "$conf_file" || edit_status=$?
  fi

  if (( edit_status != 0 )); then
    _vpn_error "sudoedit exited with status $edit_status; the profile is unchanged."
    _vpn_info "If sudoers forbids sudoedit, edit the file manually as root."
    return 1
  fi
  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  [[ "$(_vpn_profile_path_state "$conf_file")" == "safe" ]] || {
    _vpn_error "The edited profile no longer satisfies owner/mode safety checks."
    return 1
  }
  return 0
}

# --- Editing in a directory the user owns -----------------------------------
# sudoedit refuses a file in a directory the invoking user can write, which is
# the normal state of Homebrew's etc/wireguard on macOS. There the editor runs
# as the user on a private copy, and only a changed, validated copy is
# published atomically. A root-owned profile is read and reinstalled through
# the announced sudo path; a profile the user owns needs no privilege at all.

# reply: the user's editor argv, chosen in sudoedit's order (SUDO_EDITOR,
# VISUAL, EDITOR) and split on whitespace as sudoedit splits it. It runs as the
# user, never through sudo.
_vpn_editor_argv() {
  local editor="${SUDO_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"
  reply=(${=editor})
  (( ${#reply[@]} > 0 )) || reply=(vi)
}

# Publishes an edited copy over a profile the user owns, through a private
# same-directory temporary and an atomic rename. Both the copy and the target
# must still match the fingerprints taken before editing.
_vpn_user_profile_replace() {
  local staged="$1"
  local target="$2"
  local expected_staged="$3"
  local expected_target="$4"
  local directory_identity="$5"
  local dir="${target:h}"
  local temp_file="" current=""

  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  temp_file=$(umask 077; command mktemp "${dir}/.zdx-vpn-edit.XXXXXX" \
    2>/dev/null) || return 1
  {
    command cat -- "$staged" >| "$temp_file" 2>/dev/null || return 1
    command chmod -- 600 "$temp_file" 2>/dev/null || return 1
    current=$(_vpn_user_file_fingerprint "$temp_file" "edited profile") \
      || return 1
    [[ "${${current%:*}##*:}" == "${${expected_staged%:*}##*:}" \
      && "${current##*:}" == "${expected_staged##*:}" ]] || {
      _vpn_error "The edited copy changed while it was staged."
      return 1
    }
    current=$(_vpn_user_file_fingerprint "$staged" "edited copy") || return 1
    [[ "$current" == "$expected_staged" ]] || {
      _vpn_error "The edited copy changed before publication."
      return 1
    }
    _vpn_assert_config_dir_identity "$directory_identity" || return 1
    current=$(
      _vpn_profile_file_fingerprint "$target" "profile selected for editing"
    ) || return 1
    [[ "$current" == "$expected_target" ]] || {
      _vpn_error "The profile changed while it was edited; it was not replaced."
      return 1
    }
    command mv -f -- "$temp_file" "$target" 2>/dev/null || return 1
    temp_file=""
    [[ "$(_vpn_profile_path_state "$target")" == "safe" ]] || {
      _vpn_error "The edited profile failed its final safety check."
      return 1
    }
  } always {
    if [[ -n "$temp_file" && -f "$temp_file" && ! -L "$temp_file" ]]; then
      command rm -f -- "$temp_file" 2>/dev/null
    fi
  }
}

# Edits a profile in a user-owned directory without sudoedit.
_vpn_edit_staged() {
  local conf_file="$1"
  local expected_fingerprint="$2"
  local directory_identity="$3"
  local iface="${${conf_file:t}%.conf}"
  local -i protected=0
  [[ -r "$conf_file" ]] || protected=1

  # The editor runs in this terminal; without one it could wait forever.
  if [[ ! -t 0 ]]; then
    _vpn_error "Editing a profile requires an interactive terminal."
    return 1
  fi

  if (( protected )); then
    _vpn_announce_privileged \
      "read $conf_file, then install -m 600 -o 0 -g 0 -- <edited copy> $conf_file"
    _vpn_ensure_sudo_access "Editing the VPN profile" || return $?
  fi
  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  local current=""
  current=$(
    _vpn_profile_file_fingerprint "$conf_file" "profile selected for editing"
  ) || return 1
  if [[ "$current" != "$expected_fingerprint" ]]; then
    _vpn_error "The profile changed after confirmation; the editor was not opened."
    return 1
  fi

  local stage_dir="" stage_identity="" staged=""
  local -i keep_copy=0
  stage_dir=$(_vpn_make_private_temp_dir "zdx-vpn-edit") || {
    _vpn_error "Could not create a private editing directory."
    return 1
  }
  stage_identity=$(
    _vpn_private_dir_identity "$stage_dir" "editing directory"
  ) || return 1
  staged="${stage_dir}/${iface}.conf"

  {
    if (( protected )); then
      _vpn_sudo_probe head -c "$_VPN_MAX_PROFILE_BYTES" -- "$conf_file" \
        >| "$staged" || {
        _vpn_error "Could not read $conf_file."
        return 1
      }
    else
      command head -c "$_VPN_MAX_PROFILE_BYTES" -- "$conf_file" \
        >| "$staged" 2>/dev/null || return 1
    fi
    command chmod -- 600 "$staged" 2>/dev/null || return 1
    current=$(
      _vpn_profile_file_fingerprint "$conf_file" "profile selected for editing"
    ) || return 1
    [[ "$current" == "$expected_fingerprint" ]] || {
      _vpn_error "The profile changed while it was copied for editing."
      return 1
    }
    local before="" after=""
    before=$(_vpn_user_file_fingerprint "$staged" "editing copy") || return 1

    _vpn_info "Your editor runs as your own user on a private copy."
    _vpn_dim "The editor comes from SUDO_EDITOR, then VISUAL, then EDITOR."
    local -a reply=()
    _vpn_editor_argv
    local -i edit_status=0
    "${reply[@]}" "$staged" || edit_status=$?
    if (( edit_status != 0 )); then
      _vpn_error "The editor exited with status $edit_status; the profile is unchanged."
      return 1
    fi
    after=$(_vpn_user_file_fingerprint "$staged" "edited copy") || {
      _vpn_error "The edited copy must stay a private regular file of at most $_VPN_MAX_PROFILE_BYTES bytes."
      return 1
    }
    if [[ "${${after%:*}##*:}" == "${${before%:*}##*:}" \
      && "${after##*:}" == "${before##*:}" ]]; then
      _vpn_info "No changes were made; ${conf_file:t} is unchanged."
      return 0
    fi

    # Publication fails closed; the edited copy is kept so no work is lost.
    keep_copy=1
    if (( protected )); then
      _vpn_ensure_sudo_access "Saving the edited VPN profile" || return $?
      _vpn_atomic_install_staged "$staged" "$conf_file" "$after" \
        "$expected_fingerprint" "$directory_identity" "edit" || return 1
    else
      _vpn_user_profile_replace "$staged" "$conf_file" "$after" \
        "$expected_fingerprint" "$directory_identity" || return 1
    fi
    keep_copy=0
    _vpn_success "Saved ${conf_file:t}."
    return 0
  } always {
    if (( keep_copy )); then
      local REPLY=""
      _vpn_command_display "$staged"
      _vpn_warn "The edited copy was kept at $REPLY."
    elif _vpn_assert_private_dir_identity \
      "$stage_dir" "editing directory" "$stage_identity" 2>/dev/null; then
      [[ -f "$staged" && ! -L "$staged" ]] \
        && command rm -f -- "$staged" 2>/dev/null
      command rmdir -- "$stage_dir" 2>/dev/null
    else
      _vpn_warn "The editing directory changed; refusing automatic cleanup."
    fi
  }
}

# --- Backup restore ---------------------------------------------------------

# stdout: a root-created, same-directory temporary path. The returned pathname
# is validated as data before any later privileged command receives it.
_vpn_config_temp_create() {
  _vpn_privileged_temp_create "$1" "$2"
}

_vpn_config_temp_cleanup() {
  _vpn_privileged_temp_cleanup "${1:-}"
}

# Replaces a live profile with its backup through a same-directory temporary.
# The previous profile is atomically published as one bounded undo copy.
_vpn_restore_backup() {
  local iface="$1"
  local expected_conf="${2:-}"
  local expected_backup="${3:-}"
  local expected_undo="${4:-}"
  local directory_identity="${5:-}"
  local conf_file bak_file
  conf_file=$(_vpn_conf_path "$iface") || return 1
  bak_file=$(_vpn_backup_path "$iface") || return 1
  local undo_file="${conf_file}.pre-restore"

  [[ -n "$directory_identity" ]] \
    || directory_identity=$(_vpn_config_dir_identity) || return 1
  [[ -n "$expected_backup" ]] \
    || expected_backup=$(
      _vpn_profile_file_fingerprint "$bak_file" "$iface backup"
    ) || return 1
  if [[ -z "$expected_conf" ]]; then
    if [[ "$(_vpn_profile_path_state "$conf_file")" == "safe" ]]; then
      expected_conf=$(
        _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
      ) || return 1
    else
      expected_conf="missing"
    fi
  fi
  if [[ -z "$expected_undo" ]]; then
    if [[ "$(_vpn_profile_path_state "$undo_file")" == "safe" ]]; then
      expected_undo=$(
        _vpn_profile_file_fingerprint "$undo_file" "$iface undo profile"
      ) || return 1
    else
      expected_undo="missing"
    fi
  fi

  _vpn_announce_privileged \
    "atomically install $bak_file as $conf_file (undo: $undo_file)"
  _vpn_ensure_sudo_access "Restoring the $iface profile" || return 1

  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  local current
  current=$(
    _vpn_profile_file_fingerprint "$bak_file" "$iface backup"
  ) || {
    _vpn_error \
      "Backup for $iface disappeared or became unsafe after authentication."
    return 1
  }
  if [[ "$current" != "$expected_backup" ]]; then
    _vpn_error "Backup for $iface changed after planning — aborting."
    return 1
  fi
  if [[ "$expected_conf" == "missing" ]]; then
    [[ "$(_vpn_profile_path_state "$conf_file")" == "missing" ]] || {
      _vpn_error "The profile target appeared after planning — aborting."
      return 1
    }
  else
    current=$(
      _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
    ) || return 1
    [[ "$current" == "$expected_conf" ]] || {
      _vpn_error "The profile changed after planning — aborting."
      return 1
    }
  fi
  if [[ "$expected_undo" == "missing" ]]; then
    [[ "$(_vpn_profile_path_state "$undo_file")" == "missing" ]] || {
      _vpn_error "The undo target appeared after planning — aborting."
      return 1
    }
  else
    current=$(
      _vpn_profile_file_fingerprint "$undo_file" "$iface undo profile"
    ) || return 1
    [[ "$current" == "$expected_undo" ]] || {
      _vpn_error "The undo target changed after planning — aborting."
      return 1
    }
  fi

  local dir restore_temp="" undo_temp=""
  dir=$(_vpn_config_dir_resolve) || return 1
  {
    restore_temp=$(_vpn_config_temp_create "$dir" "restore") || {
      _vpn_error "Could not allocate a restore temporary."
      return 1
    }
    _vpn_sudo_exec install -m 600 -o 0 -g 0 -- \
      "$bak_file" "$restore_temp" || return 1
    current=$(
      _vpn_profile_file_fingerprint "$bak_file" "$iface backup"
    ) || return 1
    [[ "$current" == "$expected_backup" ]] || {
      _vpn_error "The backup changed while it was copied."
      return 1
    }
    [[ "$(_vpn_profile_path_state "$restore_temp")" == "safe" ]] || return 1

    if [[ "$expected_conf" != "missing" ]]; then
      undo_temp=$(_vpn_config_temp_create "$dir" "undo") || return 1
      _vpn_sudo_exec install -m 600 -o 0 -g 0 -- \
        "$conf_file" "$undo_temp" || return 1
      current=$(
        _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
      ) || return 1
      [[ "$current" == "$expected_conf" ]] || {
        _vpn_error "The profile changed while its undo copy was staged."
        return 1
      }

      if [[ "$expected_undo" == "missing" ]]; then
        _vpn_sudo_exec ln -- "$undo_temp" "$undo_file" || {
          _vpn_error "Could not publish the undo copy without clobbering."
          return 1
        }
        _vpn_sudo_exec rm -- "$undo_temp" || return 1
      else
        _vpn_sudo_exec mv -f -- "$undo_temp" "$undo_file" || return 1
      fi
      undo_temp=""
      _vpn_dim "Previous profile kept at ${undo_file}."
    fi

    _vpn_assert_config_dir_identity "$directory_identity" || return 1
    if [[ "$expected_conf" == "missing" ]]; then
      _vpn_sudo_exec ln -- "$restore_temp" "$conf_file" || {
        _vpn_error "The profile target appeared before publication."
        return 1
      }
      _vpn_sudo_exec rm -- "$restore_temp" || return 1
    else
      _vpn_sudo_exec mv -f -- "$restore_temp" "$conf_file" || return 1
    fi
    restore_temp=""
    [[ "$(_vpn_profile_path_state "$conf_file")" == "safe" ]] || {
      _vpn_error "The restored profile failed its final safety check."
      return 1
    }
    return 0
  } always {
    _vpn_config_temp_cleanup "$restore_temp" || true
    _vpn_config_temp_cleanup "$undo_temp" || true
  }
}

# --- Public commands --------------------------------------------------------

# vpn-config-edit
#   Arguments: [PROFILE] | --help
#   stdout:    none.
#   Effects:   opens the profile through sudoedit; the editor is unprivileged.
#   Status:    0 on success or cancellation, 1 on failure, 2 on bad arguments.
vpn-config-edit() {
  local -a positional=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: vpn-config-edit [PROFILE]"
        print -u2 -r -- \
          "  Edit a profile through sudoedit; omitted opens a picker."
        print -u2 -r -- \
          "  On macOS, a profile in a directory you own is edited as a private copy."
        print -u2 -r -- \
          "  The editor runs as your user, never as root."
        return 0
        ;;
      --) shift; positional+=("$@"); break ;;
      -*) _vpn_error "Unknown option: $1"; return 2 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  if (( ${#positional[@]} > 1 )); then
    _vpn_error "vpn-config-edit accepts a single profile name."
    return 2
  fi
  local iface="${positional[1]:-}"

  _vpn_require_platform || return 1

  if [[ -n "$iface" ]] && ! _vpn_validate_iface_name "$iface"; then
    _vpn_error "Invalid profile name: $iface"
    return 2
  fi

  if [[ -z "$iface" ]]; then
    local picked
    local -i pick_status=0
    picked=$(_vpn_pick_profile "Edit VPN profile") || pick_status=$?
    (( pick_status == 3 )) && return 0
    (( pick_status == 130 || pick_status == 143 )) && return "$pick_status"
    (( pick_status != 0 )) && return 1
    iface="$picked"
  fi

  local conf_file
  conf_file=$(_vpn_conf_path "$iface") || return 1

  if ! _vpn_config_exists "$iface"; then
    _vpn_error "VPN profile is missing or unsafe: $iface"
    _vpn_info "Expected: $conf_file"
    return 1
  fi

  local directory_identity profile_fingerprint
  directory_identity=$(_vpn_config_dir_identity) || return 1
  profile_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
  ) || return 1

  _vpn_header "Edit VPN Configuration ($iface)"

  local outcome
  outcome=$(_vpn_confirm_outcome "Open ${iface}.conf in your editor?")
  case "$outcome" in
    confirmed) ;;
    unavailable)
      _vpn_error "Editing a profile requires an interactive terminal."
      return 1
      ;;
    *)
      _vpn_info "Cancelled."
      return 0
      ;;
  esac

  # sudoedit refuses a directory the user can write; on macOS such a
  # directory (Homebrew's etc/wireguard) is edited through a private copy.
  if _vpn_platform_is darwin \
    && [[ "$(_vpn_config_dir_owner_kind)" == user ]]; then
    _vpn_edit_staged \
      "$conf_file" "$profile_fingerprint" "$directory_identity"
    return
  fi
  _vpn_edit_privileged \
    "$conf_file" "$profile_fingerprint" "$directory_identity"
}

# vpn-config-restore
#   Arguments: [PROFILE] | --dry-run | --yes | --help
#   stdout:    none. The plan and excerpt go to stderr.
#   Effects:   overwrites a live profile with its .bak-vpn-menu backup, keeping
#              the previous profile as <name>.conf.pre-restore.
#   Status:    0 on success or cancellation, 1 on failure, 2 on bad arguments.
vpn-config-restore() {
  local -a positional=()
  local -i dry_run=0 auto_yes=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: vpn-config-restore [PROFILE] [--dry-run] [--yes]"
        print -u2 -r -- \
          "  Restore a profile from its ${VPN_BACKUP_SUFFIX} backup."
        print -u2 -r -- \
          "  --dry-run   Show the plan and the backup excerpt, then stop."
        print -u2 -r -- "  --yes, -y   Skip the confirmation prompt."
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      --yes|-y)  auto_yes=1 ;;
      --) shift; positional+=("$@"); break ;;
      -*) _vpn_error "Unknown option: $1"; return 2 ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  if (( ${#positional[@]} > 1 )); then
    _vpn_error "vpn-config-restore accepts a single profile name."
    return 2
  fi
  local iface="${positional[1]:-}"

  _vpn_require_platform || return 1

  if [[ -n "$iface" ]] && ! _vpn_validate_iface_name "$iface"; then
    _vpn_error "Invalid profile name: $iface"
    return 2
  fi

  _vpn_state_load

  if [[ -z "$iface" ]]; then
    if (( ! _VPN_MENU_CONFIGS_KNOWN )); then
      _vpn_warn "Profiles cannot be inspected without readable access."
      _vpn_info "Run 'vpn-access-unlock' first, or pass a profile name."
      return 1
    fi

    local -a candidates=()
    local conf
    for conf in "${_VPN_MENU_CONFIGS[@]}"; do
      [[ "$(_vpn_state_iface_backup_state "$conf")" == "available" ]] \
        && candidates+=("$conf")
    done

    if (( ${#candidates[@]} == 0 )); then
      _vpn_info "No ${VPN_BACKUP_SUFFIX} backups are available."
      (( _VPN_MENU_BACKUP_UNKNOWN_COUNT > 0 )) && _vpn_dim \
        "Some backup states stay unknown until VPN access is unlocked."
      return 0
    fi

    if (( ${#candidates[@]} == 1 )); then
      iface="${candidates[1]}"
    else
      local picked
      local -i pick_status=0
      picked=$(_vpn_pick_from_list "Restore backup for" "${candidates[@]}") \
        || pick_status=$?
      (( pick_status == 3 )) && return 0
      (( pick_status == 130 || pick_status == 143 )) && return "$pick_status"
      (( pick_status != 0 )) && return 1
      iface=$(_vpn_sanitize_iface_capture "$picked") || {
        _vpn_error "Could not determine which profile to restore."
        return 1
      }
    fi
  fi

  local backup_state
  backup_state=$(_vpn_backup_state "$iface")
  case "$backup_state" in
    available) ;;
    missing)
      _vpn_error "No backup found for $iface."
      _vpn_info "Expected: $(_vpn_backup_path "$iface")"
      return 1
      ;;
    unsafe)
      _vpn_error "The backup for $iface is not a safe private regular file."
      return 1
      ;;
    *)
      _vpn_warn "Backup availability for $iface is unknown without access."
      _vpn_info "Run 'vpn-access-unlock' and retry."
      return 1
      ;;
  esac

  local conf_file bak_file undo_file directory_identity
  local conf_fingerprint backup_fingerprint undo_fingerprint
  conf_file=$(_vpn_conf_path "$iface") || return 1
  bak_file=$(_vpn_backup_path "$iface") || return 1
  undo_file="${conf_file}.pre-restore"
  directory_identity=$(_vpn_config_dir_identity) || return 1
  backup_fingerprint=$(
    _vpn_profile_file_fingerprint "$bak_file" "$iface backup"
  ) || return 1

  case "$(_vpn_profile_path_state "$conf_file")" in
    safe)
      conf_fingerprint=$(
        _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
      ) || return 1
      ;;
    missing) conf_fingerprint="missing" ;;
    *)
      _vpn_error "The live profile target is unsafe or unreadable."
      return 1
      ;;
  esac
  case "$(_vpn_profile_path_state "$undo_file")" in
    safe)
      undo_fingerprint=$(
        _vpn_profile_file_fingerprint "$undo_file" "$iface undo profile"
      ) || return 1
      ;;
    missing) undo_fingerprint="missing" ;;
    *)
      _vpn_error "The pre-restore undo target is unsafe or unreadable."
      return 1
      ;;
  esac

  _vpn_header "Restore VPN Backup ($iface)"
  local REPLY=""
  local -a plan_rows=()
  _vpn_command_display "${conf_file:h}"
  _vpn_label "Directory" "$REPLY"
  if [[ "$conf_fingerprint" != "missing" ]]; then
    plan_rows+=("1"$'\t'"save"$'\t'"${conf_file:t}"$'\t'"${undo_file:t}")
  fi
  plan_rows+=("$(( ${#plan_rows[@]} + 1 ))"$'\t'"restore"$'\t'"${bak_file:t}"$'\t'"${conf_file:t}")
  # The action column appears only when the plan mixes actions.
  local plan_header=$'#\tAction\tFrom\tTo' tab=$'\t'
  if [[ "$conf_fingerprint" == "missing" ]]; then
    plan_header=$'#\tFrom\tTo'
    plan_rows=("${(@)plan_rows/${tab}restore${tab}/${tab}}")
  fi
  _vpn_blank
  _vpn_table "$plan_header" "${plan_rows[@]}"

  if _vpn_state_iface_is_active "$iface"; then
    _vpn_warn "$iface is currently active; reconnect it after restoring."
  elif (( ! _VPN_MENU_ACTIVE_KNOWN )); then
    _vpn_dim "Tunnel activity for $iface is unknown without readable wg state."
  fi

  local excerpt
  excerpt=$(_vpn_redacted_backup_excerpt "$iface" 2>/dev/null)
  if [[ -n "$excerpt" ]]; then
    _vpn_blank
    _vpn_info "Backup excerpt (secrets removed):"
    local line
    for line in "${(@f)excerpt}"; do
      _vpn_dim "│ $line"
    done
  fi

  if (( dry_run )); then
    _vpn_blank
    _vpn_info "Dry run: 1 profile planned; nothing was restored."
    return 0
  fi

  local -i previous_auto_yes=$_VPN_AUTO_YES
  local outcome="declined"
  {
    (( auto_yes )) && _VPN_AUTO_YES=1
    outcome=$(_vpn_confirm_outcome "Restore the backup for ${iface}?")
  } always {
    _VPN_AUTO_YES=$previous_auto_yes
  }

  case "$outcome" in
    confirmed) ;;
    unavailable)
      _vpn_error \
        "Interactive confirmation requires a terminal; pass --yes to restore."
      return 1
      ;;
    *)
      _vpn_info "Cancelled: nothing was restored."
      return 0
      ;;
  esac
  _vpn_blank

  if _vpn_restore_backup "$iface" \
    "$conf_fingerprint" "$backup_fingerprint" "$undo_fingerprint" \
    "$directory_identity"; then
    _vpn_success "Restore completed: 1 profile restored."
    _vpn_dim "Reconnect $iface to apply the restored configuration."
    return 0
  fi

  _vpn_error "Failed to restore the backup for $iface."
  return 1
}

# vpn-config-dir
#   Arguments: --help only.
#   stdout:    none. The listing is UI and goes to stderr.
#   Effects:   read-only.
vpn-config-dir() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-config-dir"
      print -u2 -r -- \
        "  List the bounded inventory of safe WireGuard profiles, backups, and pre-restore undo copies."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-config-dir accepts no arguments."; return 2 ;;
  esac

  _vpn_require_platform || return 1

  local dir REPLY=""
  dir=$(_vpn_config_dir)
  _vpn_header "WireGuard Profile Directory"
  _vpn_command_display "$dir"
  _vpn_label "Directory" "$REPLY"

  if [[ ! -d "$dir" ]]; then
    _vpn_warn "$dir does not exist."
    return 1
  fi

  _vpn_ensure_profile_access || return 1
  local raw
  raw=$(_vpn_get_configs 2>/dev/null) || {
    _vpn_warn "Could not build a safe bounded profile inventory."
    return 1
  }
  local -a profiles=()
  [[ -n "$raw" ]] && profiles=("${(@f)raw}")
  if (( ${#profiles[@]} == 0 )); then
    _vpn_info "No private, singly linked .conf profiles were found."
    return 0
  fi

  # The undo column appears only when some profile has a pre-restore copy.
  local profile backup_state undo_state
  local -a rows=() undo_states=()
  local -i with_undo=0
  for profile in "${profiles[@]}"; do
    backup_state=$(_vpn_backup_state "$profile")
    undo_state=$(_vpn_pre_restore_state "$profile")
    [[ "$undo_state" == "none" ]] && undo_state="" || with_undo=1
    rows+=("${profile}.conf"$'\t'"$backup_state")
    undo_states+=("$undo_state")
  done
  _vpn_blank
  if (( with_undo )); then
    local -i row_index=0
    for (( row_index = 1; row_index <= ${#rows[@]}; row_index++ )); do
      rows[row_index]+=$'\t'"${undo_states[row_index]}"
    done
    _vpn_table $'Profile\tBackup\tPre-restore copy' "${rows[@]}"
  else
    _vpn_table $'Profile\tBackup' "${rows[@]}"
  fi
  return 0
}

typeset -g _VPN_CONFIG_SOURCED=1
