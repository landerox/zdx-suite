#!/usr/bin/env zsh
# =============================================================================
# VPN Suite: public loader and command router
# =============================================================================
#
# Public loader and command router for WireGuard tunnel workflows.
# Usage: vpn-menu [subcommand]
#

if [[ -n "${_VPN_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _vpn_menu_loader_dir="${${(%):-%x}:A:h}"

_vpn_menu_source_module() {
  local module_name="$1"
  local candidate
  local -a candidates=(
    "${_vpn_menu_loader_dir}/${module_name}"
    "${_vpn_menu_loader_dir}/vpn/${module_name}"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" && -r "$candidate" ]]; then
      source "$candidate"
      return $?
    fi
  done

  return 1
}

# --- Load common helpers first ----------------------------------------------

typeset -i _vpn_menu_load_rc=0
_vpn_menu_source_module "vpn-common.zsh" || _vpn_menu_load_rc=$?
if (( _vpn_menu_load_rc != 0 )); then
  print -u2 -r -- "vpn-menu.zsh: failed to load vpn-common.zsh"
  {
    return $_vpn_menu_load_rc 2>/dev/null || exit $_vpn_menu_load_rc
  } always {
    unset -f _vpn_menu_source_module
    unset _vpn_menu_load_rc _vpn_menu_loader_dir
  }
fi

# --- Load feature modules ---------------------------------------------------
# Order is explicit: state and WSL primitives first, then the modules that
# consume them, and finally the deprecated compatibility wrappers.

typeset _vpn_menu_module
for _vpn_menu_module in \
  vpn-state.zsh \
  vpn-wsl.zsh \
  vpn-preview.zsh \
  vpn-access.zsh \
  vpn-control.zsh \
  vpn-info.zsh \
  vpn-config.zsh \
  vpn-profile.zsh \
  vpn-compat.zsh; do
  _vpn_menu_load_rc=0
  _vpn_menu_source_module "$_vpn_menu_module" || _vpn_menu_load_rc=$?
  if (( _vpn_menu_load_rc != 0 )); then
    print -u2 -r -- "vpn-menu.zsh: failed to load ${_vpn_menu_module}"
    {
      return $_vpn_menu_load_rc 2>/dev/null || exit $_vpn_menu_load_rc
    } always {
      unset -f _vpn_menu_source_module
      unset _vpn_menu_load_rc _vpn_menu_loader_dir _vpn_menu_module
    }
  fi
done

unset -f _vpn_menu_source_module
unset _vpn_menu_load_rc _vpn_menu_module _vpn_menu_loader_dir

# =============================================================================
# VPN MENU
# =============================================================================

_vpn_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  vpn-menu"
  print -u2 -r -- "  vpn-menu <subcommand> [arguments...]"
  print -u2 -r -- "  vpn-menu --help"
  print -u2 -r -- ""
  print -u2 -r -- "Status and diagnostics:"
  print -u2 -r -- \
    "  vpn-refresh, vpn-access-status, vpn-summary, vpn-details,"
  print -u2 -r -- "  vpn-ip-info, vpn-report"
  print -u2 -r -- ""
  print -u2 -r -- "Connection control:"
  print -u2 -r -- \
    "  vpn-access-unlock, vpn-access-lock, vpn-on, vpn-off,"
  print -u2 -r -- \
    "  vpn-reconnect-last, vpn-default-connect, vpn-default-set,"
  print -u2 -r -- "  vpn-default-clear"
  print -u2 -r -- ""
  print -u2 -r -- "Profile management:"
  print -u2 -r -- \
    "  vpn-profile-create, vpn-profile-import, vpn-profile-rename,"
  print -u2 -r -- "  vpn-config-edit, vpn-config-dir"
  print -u2 -r -- ""
  print -u2 -r -- "Destructive maintenance:"
  print -u2 -r -- \
    "  vpn-off-all, vpn-config-restore, vpn-profile-remove"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Arguments after a subcommand are forwarded unchanged to that command."
  print -u2 -r -- \
    "Use '<subcommand> --help' for command-specific modes and safety flags."
  print -u2 -r -- \
    "vpn-off-all, vpn-profile-rename, vpn-config-restore, and"
  print -u2 -r -- \
    "vpn-profile-remove support --dry-run and --yes."
  print -u2 -r -- \
    "vpn-profile-remove also accepts --with-backup; --yes never implies it."
  print -u2 -r -- \
    "Confirmed workflows fail closed without a terminal unless --yes is given."
  print -u2 -r -- \
    "Profiles are edited through sudoedit, so your editor never runs as root."
  print -u2 -r -- \
    "Interactive mode requires fzf; tunnel actions require wireguard-tools."
  print -u2 -r -- \
    "Protected profiles and privileged tunnel changes additionally require sudo."
  print -u2 -r -- \
    "curl and jq enable exit-IP lookups and are required by vpn-report."
  print -u2 -r -- ""
  print -u2 -r -- "Environment:"
  print -u2 -r -- \
    "  VPN_CONFIG_DIR=DIR             WireGuard profile directory"
  print -u2 -r -- \
    "  VPN_CACHE_DIR=DIR              Owner-only pointer cache"
  print -u2 -r -- \
    "  VPN_MENU_REPORT_DIR=DIR        Report output directory"
  print -u2 -r -- \
    "  VPN_MENU_WSL_IPV6_FIX=1        Apply the IPv6 tweak outside WSL"
  print -u2 -r -- \
    "  VPN_MENU_IP_CROSSCHECK=1       Cross-check the exit IP across providers"
  print -u2 -r -- \
    "  VPN_MENU_IPINFO_URLS=URL,...   JSON IP providers"
  print -u2 -r -- \
    "  VPN_MENU_IPINFO_PLAIN_URLS=... Plain-text IP providers"
  print -u2 -r -- \
    "  VPN_MENU_IPINFO_TRACE_URLS=... Trace-format providers"
  print -u2 -r -- ""
  print -u2 -r -- \
    "This suite targets Linux and WSL. Other hosts must set VPN_CONFIG_DIR."
}

# stdout records: label|command|description|target
#
# The command set is deliberately constant so the public surface stays testable.
# Live state changes labels and adds per-profile rows, never which commands
# exist.
_vpn_menu_profile_is_listed() {
  local wanted="${1:-}"
  [[ -n "$wanted" ]] || return 1

  local profile_candidate
  for profile_candidate in "${_VPN_MENU_CONFIGS[@]}"; do
    [[ "$profile_candidate" == "$wanted" ]] && return 0
  done
  return 1
}

_vpn_menu_rows() {
  local sudo_label
  if ! command -v sudo &>/dev/null; then
    sudo_label="missing: sudo"
  elif (( _VPN_MENU_SUDO_UNLOCKED )); then
    sudo_label="non-interactive access available"
  else
    sudo_label="authentication required"
  fi

  local -a tunnel_missing=()
  command -v wg-quick &>/dev/null || tunnel_missing+=("wg-quick")
  command -v wg &>/dev/null || tunnel_missing+=("wg")
  local tunnel_suffix=""
  (( ${#tunnel_missing[@]} > 0 )) \
    && tunnel_suffix=" (missing: ${(j:, :)tunnel_missing})"

  local -a lookup_missing=()
  command -v curl &>/dev/null || lookup_missing+=("curl")
  command -v jq &>/dev/null || lookup_missing+=("jq")

  local -a ip_missing=()
  command -v wg &>/dev/null || ip_missing+=("wg")
  ip_missing+=("${lookup_missing[@]}")
  local ip_suffix=""
  (( ${#ip_missing[@]} > 0 )) \
    && ip_suffix=" (limited: missing ${(j:, :)ip_missing})"

  local details_suffix=""
  command -v wg &>/dev/null || details_suffix=" (unavailable: missing wg)"

  local summary_suffix=""
  command -v wg &>/dev/null || summary_suffix=" (limited: missing wg)"

  local report_suffix=""
  if (( ${#lookup_missing[@]} > 0 )); then
    report_suffix=" (unavailable: missing ${(j:, :)lookup_missing})"
  elif ! command -v wg &>/dev/null; then
    report_suffix=" (limited: missing wg)"
  fi

  local default_text="${_VPN_MENU_DEFAULT_IFACE:-none set}"
  local last_text="${_VPN_MENU_LAST_IFACE:-none recorded}"
  if (( _VPN_MENU_CONFIGS_KNOWN )); then
    if [[ -n "$_VPN_MENU_DEFAULT_IFACE" ]] \
      && ! _vpn_menu_profile_is_listed "$_VPN_MENU_DEFAULT_IFACE"; then
      default_text+="; stale"
    fi
    if [[ -n "$_VPN_MENU_LAST_IFACE" ]] \
      && ! _vpn_menu_profile_is_listed "$_VPN_MENU_LAST_IFACE"; then
      last_text+="; stale"
    fi
  fi

  _vpn_menu_section \
    "Status and Diagnostics" \
    "Read-only context, local tunnel state, and internet-exit inspection." \
    || return $?
  _vpn_menu_entry \
    "Refresh State" "vpn-refresh" \
    "Refresh profile availability, active tunnels, and saved connection choices." || return $?
  _vpn_menu_entry \
    "Show Access Status" "vpn-access-status" \
    "Show profile and tunnel access, platform support, and sudo availability." \
    || return $?
  _vpn_menu_entry \
    "Show Status Summary${summary_suffix}" "vpn-summary" \
    "List profiles, active tunnels, backups, and saved connection choices." \
    || return $?
  _vpn_menu_entry \
    "Show WireGuard Details${details_suffix}" "vpn-details" \
    "Show detailed WireGuard state for each active tunnel." || return $?
  _vpn_menu_entry \
    "Show IP and Exit Info${ip_suffix}" "vpn-ip-info" \
    "Show tunnel addresses, endpoint, handshake, public exit, and DNS." \
    || return $?
  _vpn_menu_entry \
    "Generate Diagnostic Report${report_suffix}" "vpn-report" \
    "Save a private Markdown report of tunnel and network diagnostics." \
    || return $?

  _vpn_menu_section \
    "Connections" "Authenticate, connect, reconnect, and disconnect." \
    || return $?
  _vpn_menu_entry \
    "Unlock VPN Access ($sudo_label)" "vpn-access-unlock" \
    "Authenticate with sudo so profiles and tunnel state become readable." \
    || return $?
  _vpn_menu_entry \
    "Lock Sudo Access ($sudo_label)" "vpn-access-lock" \
    "Invalidate this session's timestamp; other sudo commands may share it." \
    || return $?
  _vpn_menu_entry \
    "Connect Profile${tunnel_suffix}" "vpn-on" \
    "Pick a profile and bring its tunnel up with wg-quick." || return $?
  _vpn_menu_entry \
    "Connect Default Profile (${default_text})${tunnel_suffix}" \
    "vpn-default-connect" \
    "Bring up the profile saved as the default target." || return $?
  _vpn_menu_entry \
    "Reconnect Last-Used Profile (${last_text})${tunnel_suffix}" \
    "vpn-reconnect-last" \
    "Bring the last-used profile down if it is up, then back up." || return $?
  _vpn_menu_entry \
    "Disconnect Active Tunnel${tunnel_suffix}" "vpn-off" \
    "Disconnect one active tunnel; prompts when several are up." || return $?

  # --- Per-profile rows -----------------------------------------------------
  # Enter toggles the profile: an active one is disconnected, an inactive one is
  # connected. The profile name travels in the target field, never inside the
  # command token.
  _vpn_menu_section \
    "Profiles" "Enter connects an inactive profile or disconnects an active one." \
    || return $?

  case "$_VPN_MENU_CONFIG_ACCESS_STATE" in
    missing)
      _vpn_menu_section \
        "(profile directory missing)" \
        "Create or import a profile to initialize the configured directory." \
        || return $?
      ;;
    unsafe)
      _vpn_menu_section \
        "(profile directory unsafe)" \
        "Review VPN_CONFIG_DIR; profile workflows will fail closed." \
        || return $?
      ;;
    locked)
      _vpn_menu_section \
        "(profiles locked)" \
        "Choose Unlock VPN Access to list the available profiles." || return $?
      ;;
    *)
      if (( ! _VPN_MENU_CONFIGS_KNOWN )); then
        _vpn_menu_section \
          "(profiles unavailable)" \
          "Refresh state or inspect access status for the exact cause." \
          || return $?
      elif (( ${#_VPN_MENU_CONFIGS[@]} == 0 )); then
        _vpn_menu_section \
          "(no profiles found)" \
          "Create a profile, or import an existing .conf file." || return $?
      else
        local conf label suffix backup_state
        for conf in "${_VPN_MENU_CONFIGS[@]}"; do
          suffix=""
          _vpn_state_iface_is_active "$conf" && suffix="active"
          [[ "$conf" == "$_VPN_MENU_DEFAULT_IFACE" ]] \
            && suffix="${suffix:+$suffix, }default"
          [[ "$conf" == "$_VPN_MENU_LAST_IFACE" ]] \
            && suffix="${suffix:+$suffix, }last used"
          backup_state=$(_vpn_state_iface_backup_state "$conf")
          [[ "$backup_state" == "available" ]] \
            && suffix="${suffix:+$suffix, }backup"

          if _vpn_state_iface_is_active "$conf"; then
            label="Disconnect $conf"
            [[ -n "$suffix" ]] && label+=" ($suffix)"
            label+="$tunnel_suffix"
            _vpn_menu_entry "$label" "vpn-off" \
              "Disconnect this active profile." \
              "$conf" || return $?
          else
            label="Connect $conf"
            [[ -n "$suffix" ]] && label+=" ($suffix)"
            label+="$tunnel_suffix"
            _vpn_menu_entry "$label" "vpn-on" \
              "Connect this profile with WireGuard." \
              "$conf" || return $?
          fi
        done
      fi
      ;;
  esac

  _vpn_menu_section \
    "Profile Management" "Create, import, edit, and organize WireGuard profiles." \
    || return $?
  _vpn_menu_entry \
    "Create Profile" "vpn-profile-create" \
    "Create a private WireGuard configuration template to complete before connecting." || return $?
  _vpn_menu_entry \
    "Import Profile" "vpn-profile-import" \
    "Import a private WireGuard .conf file; executable hooks are not accepted." \
    || return $?
  _vpn_menu_entry \
    "Edit Profile Configuration" "vpn-config-edit" \
    "Edit one profile through sudoedit; your editor never runs as root." \
    || return $?
  _vpn_menu_entry \
    "Set Default Profile" "vpn-default-set" \
    "Record one profile as the default target for quick connects." || return $?
  _vpn_menu_entry \
    "Clear Default Profile (${default_text})" \
    "vpn-default-clear" \
    "Clear the default connection choice after confirmation; keep the profile." || return $?
  _vpn_menu_entry \
    "List Profile Files" "vpn-config-dir" \
    "List supported private profiles and available backups." \
    || return $?

  _vpn_menu_section \
    "Maintenance" \
    "Review profile changes, backups, disconnections, and deletions." \
    || return $?
  _vpn_menu_entry \
    "Rename Profile" "vpn-profile-rename" \
    "Rename a profile and its backup, updating saved connection choices." \
    || return $?
  _vpn_menu_entry \
    "Disconnect All Tunnels${tunnel_suffix}" "vpn-off-all" \
    "Preview and bring down every active interface after one confirmation." \
    || return $?
  _vpn_menu_entry \
    "Restore Profile Backup" "vpn-config-restore" \
    "Restore a profile backup and keep a private copy of the current profile." \
    || return $?
  _vpn_menu_entry \
    "Remove Profile" "vpn-profile-remove" \
    "Preview and delete a profile; its backup is included only on request." \
    || return $?
}

_vpn_menu_context() {
  local tunnel_text profile_text backup_text access_text

  case "$_VPN_MENU_WG_ACCESS_STATE" in
    locked)  tunnel_text="tunnels locked" ;;
    missing) tunnel_text="wg missing" ;;
    *)
      if (( _VPN_MENU_ACTIVE_KNOWN )); then
        if (( ${#_VPN_MENU_ACTIVE_IFACES[@]} > 0 )); then
          tunnel_text="${#_VPN_MENU_ACTIVE_IFACES[@]} active: ${_VPN_MENU_ACTIVE_IFACES[*]}"
        else
          tunnel_text="disconnected"
        fi
      else
        tunnel_text="tunnel state unknown"
      fi
      ;;
  esac

  case "$_VPN_MENU_CONFIG_ACCESS_STATE" in
    missing) profile_text="profile dir missing" ;;
    locked)  profile_text="profiles locked" ;;
    unsafe)  profile_text="profile dir unsafe" ;;
    *)
      if (( _VPN_MENU_CONFIGS_KNOWN )); then
        profile_text="${#_VPN_MENU_CONFIGS[@]} profiles"
      else
        profile_text="profiles unknown"
      fi
      ;;
  esac

  if (( _VPN_MENU_CONFIGS_KNOWN )); then
    if (( _VPN_MENU_BACKUP_UNKNOWN_COUNT > 0 )); then
      backup_text="${_VPN_MENU_BACKUP_AVAILABLE_COUNT} backups, ${_VPN_MENU_BACKUP_UNKNOWN_COUNT} unknown"
    else
      backup_text="${_VPN_MENU_BACKUP_AVAILABLE_COUNT} backups"
    fi
  else
    backup_text="backups unknown"
  fi

  if ! command -v sudo &>/dev/null; then
    access_text="sudo unavailable"
  elif (( _VPN_MENU_SUDO_UNLOCKED )); then
    access_text="non-interactive sudo available"
  else
    access_text="sudo authentication required"
  fi

  local context="Platform: $_VPN_MENU_PLATFORM | $tunnel_text"
  context+=" | $profile_text | $backup_text | $access_text"
  if [[ -n "$_VPN_MENU_DEFAULT_IFACE" ]]; then
    local default_context="$_VPN_MENU_DEFAULT_IFACE"
    if (( _VPN_MENU_CONFIGS_KNOWN )) \
      && ! _vpn_menu_profile_is_listed "$_VPN_MENU_DEFAULT_IFACE"; then
      default_context+=" (stale)"
    fi
    context+=" | default: $default_context"
  fi
  (( _VPN_MENU_WSL_FIX )) && context+=" | WSL fix on"

  _vpn_display_escape "$context"
}

_vpn_menu_capabilities() {
  local -a tunnel_missing=() exit_missing=()
  command -v wg-quick &>/dev/null || tunnel_missing+=("wg-quick")
  command -v wg &>/dev/null || tunnel_missing+=("wg")
  command -v curl &>/dev/null || exit_missing+=("curl")
  command -v jq &>/dev/null || exit_missing+=("jq")

  local tunnel_text="ready"
  local exit_text="ready"
  (( ${#tunnel_missing[@]} > 0 )) \
    && tunnel_text="missing ${(j:, :)tunnel_missing}"
  (( ${#exit_missing[@]} > 0 )) \
    && exit_text="missing ${(j:, :)exit_missing}"

  print -r -- \
    "Capabilities: tunnel tools $tunnel_text | exit lookup $exit_text"
}

# Returns to the menu after an action so its result stays visible. Prompts go to
# stderr, never stdout.
_vpn_menu_pause() {
  [[ -t 0 && -t 2 ]] || return 0
  printf '\n  Press Enter to return to the VPN menu...' >&2
  local reply
  read -r reply
  return 0
}

# The VPN menu is a stateful manager: connection state changes as a direct
# result of the selected action, so the loop refreshes discovery after every
# mutation. Esc returns to the shell.
_vpn_interactive() {
  setopt LOCAL_OPTIONS LOCAL_TRAPS
  local -i _vpn_interrupted_status=0
  trap '_vpn_interrupted_status=130; _vpn_preview_dir_cleanup; return 130' INT
  trap '_vpn_interrupted_status=129; _vpn_preview_dir_cleanup; return 129' HUP
  trap '_vpn_interrupted_status=143; _vpn_preview_dir_cleanup; return 143' TERM

  if ! command -v fzf &>/dev/null; then
    _vpn_error "fzf is required for the interactive VPN menu."
    _vpn_info \
      "Install fzf with your platform package manager, or run a direct subcommand."
    return 1
  fi
  {
    while true; do
      (( _vpn_interrupted_status == 0 )) || return $_vpn_interrupted_status
      _vpn_state_load

      # In-loop locals keep an initializer: re-declaring an existing local
      # without one makes zsh print the variable on every later iteration.
      local rows_output=""
      rows_output=$(_vpn_menu_rows) || return $?
      local -a options=("${(@f)rows_output}")

      # Panes are rendered here, so the preview command references only fzf's
      # integer row index and never a value taken from a record.
      #
      # _vpn_preview_build is called as a plain command, not through command
      # substitution: a subshell would set _VPN_PREVIEW_DIR only inside itself
      # and leave the always block below with nothing to clean up.
      local -a preview_options=()
      local -i preview_available=0
      if _vpn_preview_build "${options[@]}"; then
        preview_available=1
        preview_options=(
          --preview="command cat -- ${(qq)_VPN_PREVIEW_DIR}/{n}"
          --preview-window='right:50%:wrap,<120(down:10:wrap)'
          --bind='ctrl-/:toggle-preview'
        )
      else
        preview_options=(--preview-window=hidden)
      fi
      _vpn_preview_dir_init || {
        _vpn_error "Could not create a private menu state directory."
        return 1
      }

      local header=""
      header="$(_vpn_menu_context)"$'\n'
      header+="$(_vpn_menu_capabilities)"$'\n'
      header+='Type to filter | Enter run | Esc cancel'
      (( preview_available )) && header+=' | Ctrl-/ details'

      local selection_file=""
      selection_file=$(umask 077; command mktemp \
        "${_VPN_PREVIEW_DIR}/.selection.XXXXXX" 2>/dev/null) || {
        _vpn_error "Could not create a private fzf result file."
        return 1
      }
      command chmod 600 -- "$selection_file" 2>/dev/null || return 1
      _vpn_state_validate_file \
        "$selection_file" "$_VPN_PREVIEW_DIR" "fzf result" \
        "$_VPN_MAX_PREVIEW_BYTES" || return 1

      local selected=""
      local -i fzf_status=0
      printf "%s\n" "${options[@]}" | _vpn_fzf \
        --prompt='vpn > ' \
        --header="$header" \
        "${preview_options[@]}" > "$selection_file" || fzf_status=$?
      (( _vpn_interrupted_status == 0 )) || return $_vpn_interrupted_status

      _vpn_state_validate_file \
        "$selection_file" "$_VPN_PREVIEW_DIR" "fzf result" \
        "$_VPN_MAX_PREVIEW_BYTES" || return 1
      selected=$(<"$selection_file")
      command rm -- "$selection_file" 2>/dev/null || {
        _vpn_error "Could not remove the private fzf result file."
        return 1
      }
      selection_file=""

      if (( fzf_status != 0 )); then
        (( fzf_status == 1 || fzf_status == 130 )) && return 0
        _vpn_error "Unable to open the interactive VPN menu."
        return 1
      fi

      [[ -n "$selected" ]] || return 0
      if [[ "$selected" == *$'\n'* || "$selected" == *$'\r'* \
        || "$selected" == *$'\0'* ]]; then
        _vpn_error "Refusing malformed fzf output."
        return 1
      fi

      local command_name="${${selected#*|}%%|*}"
      [[ "$command_name" == ":" ]] && continue

      local target="${selected##*|}"

      # The target was carried as an opaque field, so it is validated again
      # here, immediately before dispatch.
      if [[ -n "$target" ]] && ! _vpn_validate_iface_name "$target"; then
        _vpn_error "Refusing an invalid selection target."
        _vpn_menu_pause
        continue
      fi

      local option_record=""
      local -i selection_known=0
      for option_record in "${options[@]}"; do
        if [[ "$selected" == "$option_record" ]]; then
          selection_known=1
          break
        fi
      done
      if (( ! selection_known )); then
        _vpn_error "Refusing a selection outside the current VPN menu snapshot."
        return 1
      fi

      _vpn_info "Executing: $command_name${target:+ $target}"
      local -i action_status=0
      if [[ -n "$target" ]]; then
        _vpn_timed "vpn:$command_name" _vpn_dispatch "$command_name" "$target" \
          || action_status=$?
      else
        _vpn_timed "vpn:$command_name" _vpn_dispatch "$command_name" \
          || action_status=$?
      fi
      (( action_status == 130 || action_status == 143 )) && return "$action_status"

      case "$command_name" in
        vpn-refresh|vpn-config-edit) ;;
        *) _vpn_menu_pause ;;
      esac
    done
  } always {
    _vpn_preview_dir_cleanup
  }
}

vpn-menu() {
  case "${1:-}" in
    "")
      _vpn_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _vpn_error "--help accepts no arguments."
        return 2
      }
      _vpn_usage
      ;;
    -*)
      _vpn_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _vpn_timed "vpn:$command_name" \
        _vpn_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _VPN_MENU_SOURCED=1
