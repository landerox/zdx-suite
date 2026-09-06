#!/usr/bin/env zsh
# =============================================================================
# VPN Control: connect and disconnect tunnels, defaults, last-used profile
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh, vpn-state.zsh, and vpn-wsl.zsh.
# Safe to re-source; defines functions only.
#
# Every privileged step follows the same sequence: announce the operation,
# authenticate with `sudo -v`, revalidate the target, then run exactly one
# command with `sudo -n`. Revalidating after authentication is what keeps a
# profile that disappeared, or was replaced while the prompt was open, from
# being acted on.
#

if [[ -n "${_VPN_CONTROL_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Shared option parsing --------------------------------------------------

# Sets the caller's _vpn_opt_iface.
# Status: 0 parsed, 2 invalid arguments, 3 help was printed.
_vpn_parse_iface_options() {
  local command_name="$1"
  local usage_extra="$2"
  shift 2

  _vpn_opt_iface=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: $command_name [PROFILE]"
        [[ -n "$usage_extra" ]] && print -u2 -r -- "$usage_extra"
        return 3
        ;;
      --)
        shift
        break
        ;;
      -*)
        _vpn_error "Unknown option: $1"
        return 2
        ;;
      *)
        if [[ -n "$_vpn_opt_iface" ]]; then
          _vpn_error "$command_name accepts a single profile name."
          return 2
        fi
        _vpn_opt_iface="$1"
        ;;
    esac
    shift
  done

  # Anything after `--` stays data, so a name beginning with a dash is still
  # rejected by validation rather than parsed as an option.
  while (( $# > 0 )); do
    if [[ -n "$_vpn_opt_iface" ]]; then
      _vpn_error "$command_name accepts a single profile name."
      return 2
    fi
    _vpn_opt_iface="$1"
    shift
  done

  if [[ -n "$_vpn_opt_iface" ]] \
    && ! _vpn_validate_iface_name "$_vpn_opt_iface"; then
    _vpn_error "Invalid profile name: $_vpn_opt_iface"
    _vpn_info \
      "Names must start with a letter or digit and may contain . _ - only."
    return 2
  fi
  return 0
}

# --- Privileged tunnel transitions ------------------------------------------

_vpn_tunnel_up() {
  local iface="$1"
  _vpn_validate_iface_name "$iface" || return 2
  _vpn_check_wg_quick || return 1

  local conf_file directory_identity profile_fingerprint
  conf_file=$(_vpn_conf_path "$iface") || return 1
  directory_identity=$(_vpn_config_dir_identity) || return 1
  profile_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
  ) || return $?

  _vpn_announce_privileged "wg-quick up ${(q)conf_file}"
  _vpn_ensure_sudo_access "Bringing up the $iface tunnel" || return $?

  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  local current_fingerprint
  current_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
  ) || {
    local -i fingerprint_rc=$?
    if (( fingerprint_rc == 130 || fingerprint_rc == 143 )); then
      _vpn_warn "Profile inspection was interrupted; the tunnel command was not run."
      return "$fingerprint_rc"
    fi
    _vpn_error \
      "Profile $iface disappeared or became unsafe after authentication — aborting."
    return "$fingerprint_rc"
  }
  if [[ "$current_fingerprint" != "$profile_fingerprint" ]]; then
    _vpn_error "Profile $iface changed during authentication — aborting."
    return 1
  fi

  _vpn_info "Bringing up $iface..."
  local -i transition_rc=0
  _vpn_sudo_exec wg-quick up "$conf_file" || transition_rc=$?
  if (( transition_rc == 0 )); then
    _vpn_remember_iface "$iface" \
      || _vpn_warn "Connected, but could not record $iface as last used."
    _vpn_success "VPN ($iface) is now ON."
    return 0
  fi

  if (( transition_rc == 130 || transition_rc == 143 )); then
    _vpn_warn "Starting VPN ($iface) was interrupted; inspect its state before retrying."
    return "$transition_rc"
  fi
  _vpn_error "Failed to start VPN ($iface). Is it already running?"
  return 1
}

_vpn_tunnel_down() {
  local iface="$1"
  _vpn_validate_iface_name "$iface" || return 2
  _vpn_check_wg_quick || return 1

  local conf_file directory_identity profile_fingerprint
  conf_file=$(_vpn_conf_path "$iface") || return 1
  directory_identity=$(_vpn_config_dir_identity) || return 1
  _vpn_announce_privileged "wg-quick down ${(q)conf_file}"
  _vpn_ensure_profile_access || return $?
  profile_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
  ) || return $?
  _vpn_ensure_sudo_access "Bringing down the $iface tunnel" || return $?

  local -a reply=()
  local -i probe_rc=0
  _vpn_active_interfaces || probe_rc=$?
  if (( probe_rc != 0 )); then
    _vpn_error "Could not revalidate the active tunnel list."
    return "$probe_rc"
  fi
  if [[ " ${reply[*]} " != *" $iface "* ]]; then
    _vpn_error "Tunnel $iface is no longer active; no command was run."
    return 1
  fi

  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  local current_fingerprint
  current_fingerprint=$(
    _vpn_profile_file_fingerprint "$conf_file" "$iface profile"
  ) || {
    local -i fingerprint_rc=$?
    if (( fingerprint_rc == 130 || fingerprint_rc == 143 )); then
      _vpn_warn "Profile inspection was interrupted; the tunnel command was not run."
      return "$fingerprint_rc"
    fi
    _vpn_error \
      "Profile $iface disappeared or became unsafe after authentication — aborting."
    return "$fingerprint_rc"
  }
  if [[ "$current_fingerprint" != "$profile_fingerprint" ]]; then
    _vpn_error "Profile $iface changed during authentication — aborting."
    return 1
  fi

  _vpn_info "Bringing down $iface..."
  local -i transition_rc=0
  _vpn_sudo_exec wg-quick down "$conf_file" || transition_rc=$?
  if (( transition_rc == 0 )); then
    _vpn_success "VPN ($iface) is now OFF."
    return 0
  fi

  if (( transition_rc == 130 || transition_rc == 143 )); then
    _vpn_warn "Stopping VPN ($iface) was interrupted; inspect its state before retrying."
    return "$transition_rc"
  fi
  _vpn_error "Failed to stop VPN ($iface). Is it already stopped?"
  return 1
}

# Sets `reply` to the active interfaces. Returns 1 when the live state cannot be
# read at all, which is different from "no tunnel is up". INT/TERM statuses
# remain distinct so callers stop before a subsequent mutation.
_vpn_active_interfaces() {
  reply=()
  local raw
  local -i probe_rc=0
  raw=$(_vpn_get_active_interfaces 2>/dev/null) || probe_rc=$?
  if (( probe_rc != 0 )); then
    (( probe_rc == 130 || probe_rc == 143 )) && return "$probe_rc"
    return 1
  fi

  local -A seen=()
  local iface
  for iface in ${=raw}; do
    _vpn_validate_iface_name "$iface" || return 1
    [[ -n "${seen[$iface]-}" ]] && continue
    seen[$iface]=1
    reply+=("$iface")
    (( ${#reply[@]} <= _VPN_MAX_ACTIVE_INTERFACES )) || {
      reply=()
      return 1
    }
  done
  return 0
}

# --- Public commands --------------------------------------------------------

# vpn-on
#   Arguments: [PROFILE] | --help
#   stdout:    none. Progress goes to stderr.
#   Effects:   applies the WSL tweak when applicable, brings the tunnel up, and
#              records it as the last-used profile.
#   Status:    0 on success or cancellation, 1 on failure, 2 on bad arguments;
#              interrupted operations preserve 130 (INT) or 143 (TERM).
vpn-on() {
  local _vpn_opt_iface=""
  local -i parse_status=0

  _vpn_parse_iface_options vpn-on \
    "  PROFILE     Profile to connect; omitted opens a picker." "$@" \
    || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  _vpn_require_platform || return 1

  local iface="$_vpn_opt_iface"
  if [[ -z "$iface" ]]; then
    local picked
    local -i pick_status=0
    picked=$(_vpn_pick_profile "Connect VPN profile") || pick_status=$?
    (( pick_status == 130 )) && return 0
    (( pick_status != 0 )) && return 1
    iface="$picked"
  fi

  _vpn_ensure_profile_access || return $?

  local -i profile_rc=0
  _vpn_config_exists "$iface" || profile_rc=$?
  if (( profile_rc != 0 )); then
    (( profile_rc == 130 || profile_rc == 143 )) && return "$profile_rc"
    _vpn_error "VPN profile not found: $iface"
    _vpn_info "Expected: $(_vpn_conf_path "$iface")"
    return 1
  fi

  # Dependency discovery follows parsing and target validation, but precedes
  # the WSL profile transformations so a host that cannot connect never
  # mutates a profile as a side effect of the failed attempt.
  _vpn_check_wg_quick || return 1

  _vpn_header "Start VPN ($iface)"

  if _vpn_should_apply_wsl_ipv6_fix; then
    _vpn_info "Applying WSL IPv6 compatibility tweaks to $iface..."
    _vpn_fix_ipv6_config "$iface" || {
      _vpn_error \
        "The required WSL IPv6 compatibility tweak failed; the tunnel was not started."
      return 1
    }
  fi

  _vpn_tunnel_up "$iface" || return $?
  _vpn_blank
  local -i details_rc=0
  vpn-details || details_rc=$?
  if (( details_rc != 0 )); then
    (( details_rc == 130 || details_rc == 143 )) && return "$details_rc"
    _vpn_warn "The tunnel started, but its detailed state could not be displayed."
  fi
  return 0
}

# vpn-off
#   Arguments: [PROFILE] | --help
#   Effects:   brings one tunnel down. With no argument and one active tunnel it
#              acts on that one; with several it opens a picker.
vpn-off() {
  local _vpn_opt_iface=""
  local -i parse_status=0

  _vpn_parse_iface_options vpn-off \
    "  PROFILE     Interface to disconnect; omitted picks from active ones." \
    "$@" || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  local iface="$_vpn_opt_iface"

  if [[ -z "$iface" ]]; then
    _vpn_ensure_wg_access || return $?

    local -a reply=()
    local -i probe_rc=0
    _vpn_active_interfaces || {
      probe_rc=$?
      _vpn_error "Could not read the active tunnel list."
      return "$probe_rc"
    }
    local -a active=("${reply[@]}")

    if (( ${#active[@]} == 0 )); then
      _vpn_info "No VPN interfaces are currently active."
      return 0
    fi

    if (( ${#active[@]} == 1 )); then
      iface="${active[1]}"
    else
      local picked
      local -i pick_status=0
      picked=$(_vpn_pick_from_list "Disconnect VPN" "${active[@]}") \
        || pick_status=$?
      (( pick_status == 130 )) && return 0
      (( pick_status != 0 )) && return 1
      iface=$(_vpn_sanitize_iface_capture "$picked") || {
        _vpn_error "Could not determine which interface to disconnect."
        return 1
      }
    fi
  fi

  _vpn_header "Stop VPN ($iface)"
  _vpn_tunnel_down "$iface" || return $?
  _vpn_blank
  local -i details_rc=0
  vpn-details || details_rc=$?
  if (( details_rc != 0 )); then
    (( details_rc == 130 || details_rc == 143 )) && return "$details_rc"
    _vpn_warn "The tunnel stopped, but the remaining state could not be displayed."
  fi
  return 0
}

# vpn-off-all
#   Arguments: --yes | --help
#   Effects:   brings down every active interface after one confirmation.
#   Status:    0 on success or cancellation, 1 when any interface failed or no
#              confirmation could be obtained without --yes; interruption
#              preserves 130/143 and leaves remaining interfaces unattempted.
vpn-off-all() {
  local -i auto_yes=0 dry_run=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: vpn-off-all [--dry-run] [--yes]"
        print -u2 -r -- "  Bring down every active WireGuard interface."
        print -u2 -r -- "  --dry-run   Show the exact plan and stop."
        print -u2 -r -- \
          "  --yes, -y   Skip the confirmation prompt; validation still runs."
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      --yes|-y) auto_yes=1 ;;
      *) _vpn_error "Unknown option: $1"; return 2 ;;
    esac
    shift
  done

  _vpn_ensure_wg_access || return $?

  local -a reply=()
  local -i probe_rc=0
  _vpn_active_interfaces || {
    probe_rc=$?
    _vpn_error "Could not read the active tunnel list."
    return "$probe_rc"
  }
  local -a active=("${reply[@]}")

  if (( ${#active[@]} == 0 )); then
    _vpn_info "No VPN interfaces are currently active."
    return 0
  fi

  _vpn_header "Stop All VPN Interfaces"
  _vpn_info "Plan: bring down ${#active[@]} interface(s): ${active[*]}"

  if (( dry_run )); then
    _vpn_warn "DRY-RUN — no interface was disconnected."
    return 0
  fi

  local -i previous_auto_yes=$_VPN_AUTO_YES
  local outcome="declined"
  {
    (( auto_yes )) && _VPN_AUTO_YES=1
    outcome=$(_vpn_confirm_outcome \
      "Bring down all ${#active[@]} active interface(s)?")
  } always {
    _VPN_AUTO_YES=$previous_auto_yes
  }

  case "$outcome" in
    confirmed) ;;
    unavailable)
      _vpn_error \
        "Interactive confirmation requires a terminal; pass --yes to disconnect all."
      return 1
      ;;
    *)
      _vpn_info "Cancelled. No interface was disconnected."
      return 0
      ;;
  esac

  local -i failures=0 attempted=0
  local iface
  for iface in "${active[@]}"; do
    attempted=$(( attempted + 1 ))
    if ! _vpn_validate_iface_name "$iface"; then
      _vpn_warn \
        "Skipping unexpected interface name: $(_vpn_display_escape "$iface")"
      failures=$(( failures + 1 ))
      continue
    fi
    local -i transition_rc=0
    _vpn_tunnel_down "$iface" || transition_rc=$?
    if (( transition_rc == 130 || transition_rc == 143 )); then
      _vpn_warn "Disconnect interrupted at $iface; remaining interfaces were not attempted."
      local pending_iface=""
      for pending_iface in "${(@)active[$(( attempted + 1 )),-1]}"; do
        _vpn_info "Not attempted: $pending_iface"
      done
      return "$transition_rc"
    fi
    (( transition_rc == 0 )) || failures=$(( failures + 1 ))
  done

  _vpn_blank
  if (( failures == 0 )); then
    _vpn_success "All ${#active[@]} interface(s) disconnected."
    local -i details_rc=0
    vpn-details || details_rc=$?
    if (( details_rc != 0 )); then
      (( details_rc == 130 || details_rc == 143 )) && return "$details_rc"
      _vpn_warn "All tunnels stopped, but final details could not be displayed."
    fi
    return 0
  fi

  _vpn_error "$failures of ${#active[@]} interface(s) failed to disconnect."
  return 1
}

# vpn-reconnect-last
#   Arguments: --help only.
#   Effects:   brings the recorded last-used profile down, if up, then up again.
vpn-reconnect-last() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-reconnect-last"
      print -u2 -r -- "  Reconnect the profile recorded as last used."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-reconnect-last accepts no arguments."; return 2 ;;
  esac

  _vpn_require_platform || return 1

  local last
  local -i pointer_rc=0
  last=$(_vpn_read_last_iface 2>/dev/null) || pointer_rc=$?
  (( pointer_rc == 130 || pointer_rc == 143 )) && return "$pointer_rc"
  (( pointer_rc == 0 )) || last=""
  if [[ -z "$last" ]]; then
    _vpn_warn "No last-used VPN profile is recorded."
    _vpn_info "Connect a profile once with 'vpn-on' to record it."
    return 0
  fi

  _vpn_ensure_wg_access || return $?
  local -a reply=()
  local -i probe_rc=0
  _vpn_active_interfaces || probe_rc=$?
  if (( probe_rc != 0 )); then
    _vpn_error "Could not read the active tunnel list; the last-used profile was not restarted."
    return "$probe_rc"
  fi
  local iface
  for iface in "${reply[@]}"; do
    if [[ "$iface" == "$last" ]]; then
      _vpn_info "Reconnecting the last-used profile: $last"
      _vpn_tunnel_down "$last" || return $?
      break
    fi
  done

  vpn-on "$last"
}

# vpn-default-connect
#   Arguments: --help only.
#   Effects:   brings the configured default profile up, or reports that it is
#              already active.
vpn-default-connect() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-default-connect"
      print -u2 -r -- "  Bring up the configured default profile."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-default-connect accepts no arguments."; return 2 ;;
  esac

  _vpn_require_platform || return 1

  local iface
  local -i pointer_rc=0
  iface=$(_vpn_effective_default_iface) || pointer_rc=$?
  (( pointer_rc == 130 || pointer_rc == 143 )) && return "$pointer_rc"
  (( pointer_rc == 0 )) || iface=""
  if [[ -z "$iface" ]]; then
    _vpn_warn "No default VPN profile is configured."
    _vpn_info "Choose one with 'vpn-default-set'."
    return 1
  fi

  _vpn_ensure_wg_access || return $?
  local -a reply=()
  local -i probe_rc=0
  _vpn_active_interfaces || probe_rc=$?
  if (( probe_rc != 0 )); then
    _vpn_error "Could not read the active tunnel list; the default profile was not started."
    return "$probe_rc"
  fi
  local current
  for current in "${reply[@]}"; do
    if [[ "$current" == "$iface" ]]; then
      _vpn_info "The default VPN profile is already active: $iface"
      return 0
    fi
  done

  _vpn_info "Connecting the default VPN profile: $iface"
  vpn-on "$iface"
}

# vpn-default-set
#   Arguments: [PROFILE] | --help
#   Effects:   records one profile as the default in the owner-only cache.
vpn-default-set() {
  local _vpn_opt_iface=""
  local -i parse_status=0

  _vpn_parse_iface_options vpn-default-set \
    "  PROFILE     Profile to save as default; omitted opens a picker." "$@" \
    || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  _vpn_require_platform || return 1
  _vpn_ensure_profile_access || return 1

  local iface="$_vpn_opt_iface"
  if [[ -z "$iface" ]]; then
    local picked
    local -i pick_status=0
    picked=$(_vpn_pick_profile "Set default VPN profile") || pick_status=$?
    (( pick_status == 130 )) && return 0
    (( pick_status != 0 )) && return 1
    iface="$picked"
  fi

  if ! _vpn_config_exists "$iface"; then
    _vpn_error "Profile not found: $iface"
    return 1
  fi

  if _vpn_set_default_iface "$iface"; then
    _vpn_success "Default VPN profile: $iface"
    return 0
  fi

  _vpn_error "Could not save the default VPN profile."
  return 1
}

# vpn-default-clear
#   Arguments: --yes | --help
#   Effects:   removes the saved default profile pointer after confirmation.
vpn-default-clear() {
  local -i auto_yes=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: vpn-default-clear [--yes]"
        print -u2 -r -- "  Remove the saved default profile pointer."
        print -u2 -r -- "  --yes, -y   Skip the confirmation prompt."
        return 0
        ;;
      --yes|-y) auto_yes=1 ;;
      *) _vpn_error "Unknown option: $1"; return 2 ;;
    esac
    shift
  done

  local iface default_file
  iface=$(_vpn_effective_default_iface) || iface=""
  default_file=$(_vpn_cache_file_existing "default-iface") || default_file=""

  if [[ -z "$iface" && ( -z "$default_file" || ! -f "$default_file" ) ]]; then
    _vpn_info "No default VPN profile is configured."
    return 0
  fi

  if [[ -n "$iface" ]]; then
    local -i previous_auto_yes=$_VPN_AUTO_YES
    local outcome="declined"
    {
      (( auto_yes )) && _VPN_AUTO_YES=1
      outcome=$(_vpn_confirm_outcome "Clear the default VPN profile ($iface)?")
    } always {
      _VPN_AUTO_YES=$previous_auto_yes
    }

    case "$outcome" in
      confirmed) ;;
      unavailable)
        _vpn_error \
          "Clearing the default needs confirmation; pass --yes in a non-interactive shell."
        return 1
        ;;
      *)
        _vpn_info "Cancelled. The default profile was kept."
        return 0
        ;;
    esac
  fi

  if _vpn_clear_default_iface; then
    if [[ -n "$iface" ]]; then
      _vpn_success "Cleared the default VPN profile ($iface)."
    else
      _vpn_success "Cleared stale default VPN profile state."
    fi
    return 0
  fi

  _vpn_error "Could not clear the default VPN profile."
  return 1
}

# vpn-refresh
#   Arguments: --help only.
#   stdout:    none. The state block is UI and goes to stderr.
#   Effects:   read-only. Re-reads access, profile, tunnel, and cache state.
#   Status:    0 always.
#
#   This is a real command so the menu's refresh row maps to a working direct
#   call rather than being a menu-only pseudo-action.
vpn-refresh() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-refresh"
      print -u2 -r -- \
        "  Re-read access, profile, tunnel, and cached-pointer state."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-refresh accepts no arguments."; return 2 ;;
  esac

  _vpn_state_load

  _vpn_label "Profile access" \
    "$(_vpn_access_label "$_VPN_MENU_CONFIG_ACCESS_STATE")"
  _vpn_label "Tunnel access" \
    "$(_vpn_access_label "$_VPN_MENU_WG_ACCESS_STATE")"
  if (( _VPN_MENU_CONFIGS_KNOWN )); then
    _vpn_label "Profiles" "${#_VPN_MENU_CONFIGS[@]}"
  else
    _vpn_label "Profiles" "unknown"
  fi
  if (( _VPN_MENU_ACTIVE_KNOWN )); then
    _vpn_label "Active" "${#_VPN_MENU_ACTIVE_IFACES[@]}"
  else
    _vpn_label "Active" "unknown"
  fi
  _vpn_label "Default" "${_VPN_MENU_DEFAULT_IFACE:-(none)}"
  _vpn_label "Last used" "${_VPN_MENU_LAST_IFACE:-(none)}"
  return 0
}

typeset -g _VPN_CONTROL_SOURCED=1
