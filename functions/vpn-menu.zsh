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
# Order is explicit: state and the WSL and macOS platform primitives first,
# then the modules that consume them.

typeset _vpn_menu_module
for _vpn_menu_module in \
  vpn-state.zsh \
  vpn-wsl.zsh \
  vpn-darwin.zsh \
  vpn-preview.zsh \
  vpn-access.zsh \
  vpn-control.zsh \
  vpn-info.zsh \
  vpn-mtu.zsh \
  vpn-config.zsh \
  vpn-profile.zsh; do
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
    "  vpn-access-status, vpn-summary, vpn-details, vpn-ip-info,"
  print -u2 -r -- "  vpn-mtu-probe, vpn-report"
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
    "Profiles are edited through sudoedit, so your editor never runs as root;"
  print -u2 -r -- \
    "on macOS a profile in a directory you own is edited as a private copy."
  print -u2 -r -- \
    "Interactive mode requires fzf; tunnel actions require wireguard-tools."
  print -u2 -r -- \
    "On macOS they also need wireguard-go and Bash 4 or newer (Homebrew)."
  print -u2 -r -- \
    "Protected profiles and privileged tunnel changes additionally require sudo."
  print -u2 -r -- \
    "curl and jq enable exit-IP lookups and are required by vpn-report."
  print -u2 -r -- \
    "vpn-mtu-probe sends bounded don't-fragment pings; it never uses sudo."
  print -u2 -r -- ""
  print -u2 -r -- "Environment:"
  print -u2 -r -- \
    "  VPN_CONFIG_DIR=DIR             WireGuard profile directory"
  print -u2 -r -- \
    "  VPN_CACHE_DIR=DIR              Owner-only pointer cache"
  print -u2 -r -- \
    "  VPN_MENU_REPORT_DIR=DIR        Report output directory"
  print -u2 -r -- \
    "  VPN_MENU_WSL_IPV6_FIX=1|0      Force the IPv6 tweak on or off (Linux, WSL)"
  print -u2 -r -- \
    "  VPN_MENU_IP_CROSSCHECK=1       Cross-check the exit IP across providers"
  print -u2 -r -- \
    "  VPN_MENU_IPINFO_URLS=URL,...   JSON IP providers"
  print -u2 -r -- \
    "  VPN_MENU_IPINFO_PLAIN_URLS=... Plain-text IP providers"
  print -u2 -r -- \
    "  VPN_MENU_IPINFO_TRACE_URLS=... Trace-format providers"
  print -u2 -r -- \
    "  VPN_MENU_MTU_TARGET=HOST       Default vpn-mtu-probe target (1.1.1.1)"
  print -u2 -r -- ""
  print -u2 -r -- \
    "This suite targets Linux, WSL, and macOS. Other hosts must set VPN_CONFIG_DIR."
}

# stdout records: label|command|description|target
#
# The command set is deliberately constant so the public surface stays testable.
# Live state decorates labels and adds per-profile rows, never which commands
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

# True when a requirement is available. The menu's only availability probe,
# so tests can model a host without a tool. On macOS, "bash 4+" and
# wireguard-go name what wg-quick itself would run.
_vpn_menu_have() {
  local REPLY=""
  case "${1:-}" in
    "bash 4+") _vpn_darwin_bash4 2>/dev/null ;;
    wireguard-go)
      if _vpn_darwin_wg_quick; then
        _vpn_darwin_wireguard_go 2>/dev/null
      else
        command -v wireguard-go &>/dev/null
      fi
      ;;
    *) command -v "${1:-}" &>/dev/null ;;
  esac
}

# REPLY: the label, marked unavailable when a requirement or context is absent
# (menu-spec.md, "Unavailable actions"). The command field never changes.
# Usage: _vpn_menu_label <label> <missing> <unavailable>
_vpn_menu_label() {
  local label="$1" missing="${2:-}" unavailable="${3:-}"
  local -a facts=()
  [[ -n "$missing" ]] && facts+=("missing: $missing")
  [[ -n "$unavailable" ]] && facts+=("unavailable: $unavailable")
  if (( ${#facts[@]} > 0 )); then
    REPLY="○ $label (${(j:; :)facts})"
  else
    REPLY="$label"
  fi
}

# REPLY: the context a saved profile pointer lacks: none recorded, or a
# profile that is no longer listed. Usage: _vpn_menu_pointer_gap <name> <noun>
_vpn_menu_pointer_gap() {
  local name="${1:-}" noun="$2"
  REPLY=""
  if [[ -z "$name" ]]; then
    REPLY="$noun"
  elif (( _VPN_MENU_CONFIGS_KNOWN )) && ! _vpn_menu_profile_is_listed "$name"; then
    REPLY="profile $name"
  fi
}

_vpn_menu_rows() {
  local REPLY=""

  # Requirements: wg-quick and wg change tunnels, sudo runs every privileged
  # primitive, wg reads live state, and curl and jq look up the public exit.
  local -a tunnel_tools=() exit_tools=()
  _vpn_menu_have wg-quick || tunnel_tools+=("wg-quick")
  _vpn_menu_have wg || tunnel_tools+=("wg")
  if [[ "$_VPN_MENU_PLATFORM" == darwin ]]; then
    _vpn_menu_have wireguard-go || tunnel_tools+=("wireguard-go")
    _vpn_menu_have "bash 4+" || tunnel_tools+=("bash 4+")
  fi
  _vpn_menu_have curl || exit_tools+=("curl")
  _vpn_menu_have jq || exit_tools+=("jq")
  local sudo_missing=""
  _vpn_menu_have sudo || sudo_missing="sudo"
  local -a tunnel_requirements=("${tunnel_tools[@]}")
  [[ -n "$sudo_missing" ]] && tunnel_requirements+=("$sudo_missing")
  local tunnel_missing="${(j:, :)tunnel_requirements}"
  local exit_missing="${(j:, :)exit_tools}"
  local wg_missing=""
  _vpn_menu_have wg || wg_missing="wg"
  local ping_missing=""
  _vpn_menu_have ping || ping_missing="ping"

  # Context: a usable profile directory with profiles, live tunnels, and the
  # saved default and last-used choices. Unknown state marks nothing.
  local directory_gap="" profiles_gap=""
  case "$_VPN_MENU_CONFIG_ACCESS_STATE" in
    unsafe)  directory_gap="profile directory"; profiles_gap="$directory_gap" ;;
    missing) profiles_gap="profile directory" ;;
    *)
      (( _VPN_MENU_CONFIGS_KNOWN && ${#_VPN_MENU_CONFIGS[@]} == 0 )) \
        && profiles_gap="profiles"
      ;;
  esac
  local listing_gap=""
  [[ "$_VPN_MENU_CONFIG_ACCESS_STATE" == (missing|unsafe) ]] \
    && listing_gap="profile directory"
  local backups_gap="$profiles_gap"
  if [[ -z "$backups_gap" ]] && (( _VPN_MENU_CONFIGS_KNOWN \
    && _VPN_MENU_BACKUP_AVAILABLE_COUNT == 0 \
    && _VPN_MENU_BACKUP_UNKNOWN_COUNT == 0 )); then
    backups_gap="backups"
  fi
  local active_gap=""
  (( _VPN_MENU_ACTIVE_KNOWN && ${#_VPN_MENU_ACTIVE_IFACES[@]} == 0 )) \
    && active_gap="active tunnel"
  _vpn_menu_pointer_gap "$_VPN_MENU_DEFAULT_IFACE" "default profile"
  local default_gap="$REPLY"
  _vpn_menu_pointer_gap "$_VPN_MENU_LAST_IFACE" "last-used profile"
  local last_gap="$REPLY"
  local default_clear_gap=""
  [[ -z "$_VPN_MENU_DEFAULT_IFACE" ]] && default_clear_gap="default profile"

  _vpn_menu_section \
    "Status and Diagnostics" \
    "Read-only context, local tunnel state, and internet-exit inspection." \
    || return $?
  _vpn_menu_entry \
    "Show Access Status" "vpn-access-status" \
    "Show profile and tunnel access, platform support, and sudo availability." \
    || return $?
  _vpn_menu_entry \
    "Show Status Summary" "vpn-summary" \
    "List profiles, active tunnels, backups, and saved connection choices." \
    || return $?
  _vpn_menu_label "Show WireGuard Details" "$wg_missing"
  _vpn_menu_entry \
    "$REPLY" "vpn-details" \
    "Show detailed WireGuard state for each active tunnel." || return $?
  _vpn_menu_label "Show IP and Exit Info" "$exit_missing"
  _vpn_menu_entry \
    "$REPLY" "vpn-ip-info" \
    "Show tunnel addresses, endpoint, handshake, public exit, and DNS." \
    || return $?
  _vpn_menu_label "Probe Path MTU" "$ping_missing"
  _vpn_menu_entry \
    "$REPLY" "vpn-mtu-probe" \
    "Measure the largest unfragmented packet and suggest MTU settings." \
    || return $?
  _vpn_menu_label "Generate Diagnostic Report" "$exit_missing"
  _vpn_menu_entry \
    "$REPLY" "vpn-report" \
    "Save a private Markdown report of tunnel and network diagnostics." \
    || return $?

  _vpn_menu_section \
    "Connections" "Authenticate, connect, reconnect, and disconnect." \
    || return $?
  _vpn_menu_label "Unlock VPN Access" "$sudo_missing"
  _vpn_menu_entry \
    "$REPLY" "vpn-access-unlock" \
    "Authenticate with sudo so profiles and tunnel state become readable." \
    || return $?
  _vpn_menu_label "Lock Sudo Access" "$sudo_missing"
  _vpn_menu_entry \
    "$REPLY" "vpn-access-lock" \
    "Invalidate this session's timestamp; other sudo commands may share it." \
    || return $?
  _vpn_menu_label "Connect Profile" "$tunnel_missing" "$profiles_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-on" \
    "Pick a profile and bring its tunnel up with wg-quick." || return $?
  local pointer_label="Connect Default Profile"
  [[ -z "$default_gap" ]] && pointer_label+=" — $_VPN_MENU_DEFAULT_IFACE"
  _vpn_menu_label "$pointer_label" "$tunnel_missing" "$default_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-default-connect" \
    "Bring up the profile saved as the default target." || return $?
  pointer_label="Reconnect Last-Used Profile"
  [[ -z "$last_gap" ]] && pointer_label+=" — $_VPN_MENU_LAST_IFACE"
  _vpn_menu_label "$pointer_label" "$tunnel_missing" "$last_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-reconnect-last" \
    "Bring the last-used profile down if it is up, then back up." || return $?
  _vpn_menu_label "Disconnect Active Tunnel" "$tunnel_missing" "$active_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-off" \
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
          "Choose Show Access Status to see the exact cause." \
          || return $?
      elif (( ${#_VPN_MENU_CONFIGS[@]} == 0 )); then
        _vpn_menu_section \
          "(no profiles found)" \
          "Create a profile, or import an existing .conf file." || return $?
      else
        # Notes follow an em dash: the verb already states the tunnel state,
        # and parentheses are reserved for availability marks.
        local conf="" label="" device=""
        local -a notes=()
        for conf in "${_VPN_MENU_CONFIGS[@]}"; do
          notes=()
          # A macOS tunnel names its utun device first; the target stays the
          # profile, never the device.
          device="${_VPN_MENU_ACTIVE_DEVICES[$conf]-}"
          [[ -n "$device" && "$device" != "$conf" ]] && notes+=("$device")
          [[ "$conf" == "$_VPN_MENU_DEFAULT_IFACE" ]] && notes+=("default")
          [[ "$conf" == "$_VPN_MENU_LAST_IFACE" ]] && notes+=("last used")
          [[ "$(_vpn_state_iface_backup_state "$conf")" == "available" ]] \
            && notes+=("backup")

          if _vpn_state_iface_is_active "$conf"; then
            label="Disconnect $conf"
          else
            label="Connect $conf"
          fi
          (( ${#notes[@]} > 0 )) && label+=" — ${(j:, :)notes}"
          _vpn_menu_label "$label" "$tunnel_missing"
          if _vpn_state_iface_is_active "$conf"; then
            _vpn_menu_entry "$REPLY" "vpn-off" \
              "Disconnect this active profile." \
              "$conf" || return $?
          else
            _vpn_menu_entry "$REPLY" "vpn-on" \
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
  _vpn_menu_label "Create Profile" "$sudo_missing" "$directory_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-profile-create" \
    "Create a private WireGuard configuration template to complete before connecting." || return $?
  _vpn_menu_label "Import Profile" "$sudo_missing" "$directory_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-profile-import" \
    "Import a private WireGuard .conf file; executable hooks are not accepted." \
    || return $?
  _vpn_menu_label "Edit Profile Configuration" "$sudo_missing" "$profiles_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-config-edit" \
    "Edit one profile as your user; your editor never runs as root." \
    || return $?
  _vpn_menu_label "Set Default Profile" "" "$profiles_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-default-set" \
    "Record one profile as the default target for quick connects." || return $?
  pointer_label="Clear Default Profile"
  [[ -n "$_VPN_MENU_DEFAULT_IFACE" ]] \
    && pointer_label+=" — $_VPN_MENU_DEFAULT_IFACE"
  _vpn_menu_label "$pointer_label" "" "$default_clear_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-default-clear" \
    "Clear the default connection choice after confirmation; keep the profile." || return $?
  _vpn_menu_label "List Profile Files" "" "$listing_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-config-dir" \
    "List supported private profiles and available backups." \
    || return $?

  _vpn_menu_section \
    "Maintenance" \
    "Review profile changes, backups, disconnections, and deletions." \
    || return $?
  _vpn_menu_label "Rename Profile" "$sudo_missing" "$profiles_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-profile-rename" \
    "Rename a profile and its backup, updating saved connection choices." \
    || return $?
  _vpn_menu_label "Disconnect All Tunnels" "$tunnel_missing" \
    "${active_gap:+active tunnels}"
  _vpn_menu_entry \
    "$REPLY" "vpn-off-all" \
    "Preview and bring down every active interface after one confirmation." \
    || return $?
  _vpn_menu_label "Restore Profile Backup" "$sudo_missing" "$backups_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-config-restore" \
    "Restore a profile backup and keep a private copy of the current profile." \
    || return $?
  _vpn_menu_label "Remove Profile" "$sudo_missing" "$profiles_gap"
  _vpn_menu_entry \
    "$REPLY" "vpn-profile-remove" \
    "Preview and delete a profile; its backup is included only on request." \
    || return $?
}

# Prints the context block: the profile directory the actions affect, then one
# state line of short facts, most decision-relevant first (menu-spec.md).
_vpn_menu_context() {
  local REPLY=""
  _vpn_command_display "$(_vpn_config_dir)"
  local scope="Directory: $REPLY"

  local active_text=""
  case "$_VPN_MENU_WG_ACCESS_STATE" in
    locked) active_text="locked" ;;
    *)
      if (( ! _VPN_MENU_ACTIVE_KNOWN )); then
        active_text="unknown"
      elif (( ${#_VPN_MENU_ACTIVE_IFACES[@]} == 0 )); then
        active_text="none"
      elif (( ${#_VPN_MENU_ACTIVE_IFACES[@]} == 1 )); then
        active_text="${_VPN_MENU_ACTIVE_IFACES[1]}"
      else
        _vpn_count_noun "${#_VPN_MENU_ACTIVE_IFACES[@]}" tunnel
        active_text="$REPLY"
      fi
      ;;
  esac

  local profile_text=""
  profile_text=$(_vpn_state_profiles_text)

  local sudo_text="locked"
  if ! _vpn_menu_have sudo; then
    sudo_text="missing"
  elif (( _VPN_MENU_SUDO_UNLOCKED )); then
    sudo_text="unlocked"
  fi

  local state="Active: $active_text | Profiles: $profile_text"
  state+=" | Sudo: $sudo_text | Platform: $_VPN_MENU_PLATFORM"
  # The WSL workaround follows the platform; only an exception is shown.
  if [[ "$_VPN_MENU_PLATFORM" == wsl ]]; then
    (( _VPN_MENU_WSL_FIX )) || state+=" | WSL fix: off"
  elif (( _VPN_MENU_WSL_FIX )); then
    state+=" | WSL fix: on"
  fi

  _vpn_display_escape "$scope"
  _vpn_display_escape "$state"
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
      header+='Type to filter | Enter run | Esc cancel'
      (( preview_available )) && header+=' | Ctrl-/ details'

      local selection_file=""
      selection_file=$(umask 077; command mktemp \
        "${_VPN_PREVIEW_DIR}/.selection.XXXXXX" 2>/dev/null) || {
        _vpn_error "Could not create a private fzf result file."
        return 1
      }
      command chmod -- 600 "$selection_file" 2>/dev/null || return 1
      _vpn_state_validate_file \
        "$selection_file" "$_VPN_PREVIEW_DIR" "fzf result" \
        "$_VPN_MAX_PREVIEW_BYTES" || return 1

      local selected=""
      local -i fzf_status=0
      printf "%s\n" "${options[@]}" | _vpn_fzf \
        --prompt='vpn > ' \
        --header="$header" \
        "${preview_options[@]}" >| "$selection_file" || fzf_status=$?
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
        vpn-config-edit) ;;
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
