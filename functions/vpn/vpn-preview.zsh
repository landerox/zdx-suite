#!/usr/bin/env zsh
# =============================================================================
# VPN Preview: precomputed, read-only preview panes for the interactive menu
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh and vpn-state.zsh.
# Safe to re-source; defines functions only.
#
# The previous implementation passed a large POSIX script to `fzf --preview`
# with `cmd={2}` at the top, so fzf substituted the selected record into shell
# program text, and the script itself called sudo. Both are forbidden by the
# menu specification.
#
# Instead, every pane is rendered here in Zsh, using the already-loaded state
# snapshot, and written to one file per row inside a private directory. The
# preview command then references only fzf's integer row index `{n}`, so no
# untrusted value ever reaches a shell program and no preview process needs
# privileges.
#

if [[ -n "${_VPN_PREVIEW_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g _VPN_PREVIEW_DIR=""
typeset -g _VPN_PREVIEW_DIR_IDENTITY=""

_vpn_preview_dir_init() {
  if [[ -n "$_VPN_PREVIEW_DIR" ]]; then
    if [[ -d "$_VPN_PREVIEW_DIR" \
      && "$(_vpn_private_dir_identity \
        "$_VPN_PREVIEW_DIR" "preview directory" 2>/dev/null)" \
        == "$_VPN_PREVIEW_DIR_IDENTITY" ]]; then
      return 0
    fi
    _VPN_PREVIEW_DIR=""
    _VPN_PREVIEW_DIR_IDENTITY=""
  fi

  _VPN_PREVIEW_DIR=$(
    _vpn_make_private_temp_dir "zdx-vpn-preview"
  ) || {
    _VPN_PREVIEW_DIR=""
    return 1
  }
  _VPN_PREVIEW_DIR_IDENTITY=$(
    _vpn_private_dir_identity "$_VPN_PREVIEW_DIR" "preview directory"
  ) || {
    command rmdir -- "$_VPN_PREVIEW_DIR" 2>/dev/null
    _VPN_PREVIEW_DIR=""
    return 1
  }
  return 0
}

_vpn_preview_dir_cleanup() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  [[ -n "$_VPN_PREVIEW_DIR" ]] || return 0

  local current_identity=""
  current_identity=$(
    _vpn_private_dir_identity "$_VPN_PREVIEW_DIR" "preview directory"
  ) 2>/dev/null
  if [[ -n "$current_identity" \
    && "$current_identity" == "$_VPN_PREVIEW_DIR_IDENTITY" \
    && "${_VPN_PREVIEW_DIR:t}" == zdx-vpn-preview.* ]]; then
    local entry
    local -a entries=("$_VPN_PREVIEW_DIR"/*(DN))
    for entry in "${entries[@]}"; do
      if [[ ( "${entry:t}" == <-> \
          || "${entry:t}" == .selection.[A-Za-z0-9]## ) \
        && -f "$entry" && ! -L "$entry" ]]; then
        command rm -f -- "$entry" 2>/dev/null
      else
        _vpn_warn \
          "Unexpected preview entry; refusing recursive cleanup: $entry"
      fi
    done
    command rmdir -- "$_VPN_PREVIEW_DIR" 2>/dev/null
  elif [[ -e "$_VPN_PREVIEW_DIR" || -L "$_VPN_PREVIEW_DIR" ]]; then
    _vpn_warn "The preview directory changed identity; refusing cleanup."
  fi
  _VPN_PREVIEW_DIR=""
  _VPN_PREVIEW_DIR_IDENTITY=""
  return 0
}

# --- Pane content -----------------------------------------------------------

_vpn_preview_kv() {
  printf '%-16s %s\n' "${1}:" "${(V)2}"
}

# Renders the pane for one menu row. stdout is the pane text.
_vpn_preview_render() {
  local command_name="$1"
  local description="$2"
  local target="$3"

  printf 'Command: %s\n' "$command_name"
  [[ -n "$target" ]] && printf 'Profile: %s\n' "${(V)target}"
  print -r -- ""

  local profile_state tunnel_state
  profile_state=$(_vpn_access_label "$_VPN_MENU_CONFIG_ACCESS_STATE")
  tunnel_state=$(_vpn_access_label "$_VPN_MENU_WG_ACCESS_STATE")

  case "$command_name" in
    :)
      print -r -- "${(V)description}"
      return 0
      ;;

    vpn-access-unlock|vpn-access-lock)
      _vpn_preview_kv "Non-interactive sudo" \
        "$( (( _VPN_MENU_SUDO_UNLOCKED )) \
          && print -n available || print -n unavailable )"
      _vpn_preview_kv "Profiles" "$profile_state"
      _vpn_preview_kv "Tunnels" "$tunnel_state"
      ;;

    vpn-access-status|vpn-refresh|vpn-summary)
      _vpn_preview_kv "Platform" "$_VPN_MENU_PLATFORM"
      _vpn_preview_kv "Profiles" "$profile_state"
      _vpn_preview_kv "Tunnels" "$tunnel_state"
      if (( _VPN_MENU_CONFIGS_KNOWN )); then
        _vpn_preview_kv "Profile count" "${#_VPN_MENU_CONFIGS[@]}"
      else
        _vpn_preview_kv "Profile count" "unknown"
      fi
      _vpn_preview_kv "Default" "${_VPN_MENU_DEFAULT_IFACE:-(none)}"
      _vpn_preview_kv "Last used" "${_VPN_MENU_LAST_IFACE:-(none)}"
      ;;

    vpn-on)
      _vpn_preview_kv "Profiles" "$profile_state"
      _vpn_preview_kv "Last used" "${_VPN_MENU_LAST_IFACE:-(none)}"
      _vpn_preview_kv "Flow" "pick a profile, then wg-quick up runs"
      ;;

    vpn-off|vpn-off-all)
      print -r -- "Active interfaces:"
      if (( _VPN_MENU_ACTIVE_KNOWN )); then
        if (( ${#_VPN_MENU_ACTIVE_IFACES[@]} > 0 )); then
          local active
          for active in "${_VPN_MENU_ACTIVE_IFACES[@]}"; do
            print -r -- "  ${(V)active}"
          done
        else
          print -r -- "  (none)"
        fi
      else
        print -r -- "  (locked or unavailable)"
      fi
      ;;

    vpn-reconnect-last)
      _vpn_preview_kv "Last used" "${_VPN_MENU_LAST_IFACE:-(none)}"
      _vpn_preview_kv "Flow" "brings it down if up, then back up"
      ;;

    vpn-default-connect|vpn-default-set|vpn-default-clear)
      _vpn_preview_kv "Default" "${_VPN_MENU_DEFAULT_IFACE:-(none)}"
      _vpn_preview_kv "Profiles" "$profile_state"
      ;;

    vpn-details)
      _vpn_preview_kv "Tunnels" "$tunnel_state"
      _vpn_preview_kv "Active" "${#_VPN_MENU_ACTIVE_IFACES[@]}"
      ;;

    vpn-ip-info)
      _vpn_preview_kv "curl" \
        "$(command -v curl &>/dev/null && print -n yes || print -n no)"
      _vpn_preview_kv "jq" \
        "$(command -v jq &>/dev/null && print -n yes || print -n no)"
      _vpn_preview_kv "Cross-check" "${VPN_MENU_IP_CROSSCHECK:-off}"
      _vpn_preview_kv "Network" "outbound lookups run only on execution"
      ;;

    vpn-report)
      _vpn_preview_kv "Target dir" "$VPN_MENU_REPORT_DIR"
      _vpn_preview_kv "Format" "Markdown, mode 600"
      _vpn_preview_kv "Network" "runs live IP lookups; may take seconds"
      ;;

    vpn-config-dir)
      _vpn_preview_kv "Directory" "$(_vpn_config_dir)"
      _vpn_preview_kv "Access" "$profile_state"
      ;;

    vpn-profile-create)
      _vpn_preview_kv "Target dir" "$(_vpn_config_dir)"
      _vpn_preview_kv "Creates" "[Interface] and [Peer] skeleton, mode 600"
      ;;

    vpn-profile-import)
      _vpn_preview_kv "Target dir" "$(_vpn_config_dir)"
      _vpn_preview_kv "Validates" "[Interface] and [Peer] sections"
      _vpn_preview_kv "Permissions" "installs mode 600, owned by root"
      if (( _VPN_MENU_WSL_FIX )); then
        _vpn_preview_kv "WSL" "offers DNS leak hardening after import"
      fi
      ;;

    vpn-profile-rename)
      _vpn_preview_kv "Renames" "the .conf and its matching backup"
      _vpn_preview_kv "Safety" "disconnects an active profile first"
      ;;

    vpn-config-edit)
      _vpn_preview_kv "Editor" "runs as your user through sudoedit"
      _vpn_preview_kv "Secrets" "not displayed by this pane"
      ;;

    vpn-config-restore)
      _vpn_preview_kv "Source" "*.conf${VPN_BACKUP_SUFFIX}"
      _vpn_preview_kv "Target" "*.conf"
      _vpn_preview_kv "Undo" "previous profile kept as .conf.pre-restore"
      ;;

    vpn-profile-remove)
      _vpn_preview_kv "Removes" "the profile, and its backup on request"
      _vpn_preview_kv "Safety" "plan, confirmation, and --dry-run"
      ;;
  esac

  # Per-profile rows add live detail for their own target.
  if [[ -n "$target" ]]; then
    print -r -- ""
    _vpn_preview_kv "Backup" "$(_vpn_state_iface_backup_state "$target")"
    if _vpn_state_iface_is_active "$target"; then
      _vpn_preview_kv "State" "active"
      local details
      details=$(
        _vpn_get_iface_details "$target" 2>/dev/null \
          | command head -c "$_VPN_MAX_PREVIEW_BYTES"
      )
      if [[ -n "$details" ]]; then
        print -r -- ""
        local line
        for line in "${(@f)details}"; do
          print -r -- "${(V)line}"
        done
      fi
    else
      _vpn_preview_kv "State" "inactive"
      local excerpt
      excerpt=$(_vpn_redacted_config_excerpt "$target" 2>/dev/null)
      if [[ -n "$excerpt" ]]; then
        print -r -- ""
        print -r -- "Profile excerpt (secrets removed):"
        local line
        for line in "${(@f)excerpt}"; do
          print -r -- "${(V)line}"
        done
      else
        print -r -- ""
        print -r -- "(profile excerpt unavailable without readable access)"
      fi
    fi
  fi

  print -r -- ""
  print -r -- "${(V)description}"
}

# Writes one pane file per record, named by its zero-based row index so the
# preview command can reference fzf's `{n}` placeholder and nothing else.
#
#   Arguments: the complete menu records, in the order given to fzf.
#   stdout:    nothing. The directory is published in _VPN_PREVIEW_DIR.
#   Status:    0 on success, 1 when the directory cannot be created.
#
#   The path is deliberately NOT returned on stdout: a caller writing
#   `dir=$(_vpn_preview_build ...)` would run this in a subshell, leaving the
#   parent's _VPN_PREVIEW_DIR empty and the directory unreachable by cleanup.
_vpn_preview_build() {
  setopt LOCAL_OPTIONS PIPE_FAIL

  _vpn_preview_dir_init || return 1
  (( $# <= _VPN_MAX_PROFILES + 64 )) || {
    _vpn_error "The VPN menu exceeds the preview row safety limit."
    _vpn_preview_dir_cleanup
    return 1
  }

  local -i index=0
  local record command_name description target pane_file
  for record in "$@"; do
    command_name="${${record#*|}%%|*}"
    description="${${record#*|*|}%%|*}"
    target="${record##*|}"

    pane_file="${_VPN_PREVIEW_DIR}/${index}"
    if ! _vpn_preview_render "$command_name" "$description" "$target" \
      2>/dev/null | command head -c "$_VPN_MAX_PREVIEW_BYTES" \
      > "$pane_file"; then
      _vpn_error "Could not render VPN preview row $index."
      _vpn_preview_dir_cleanup
      return 1
    fi
    command chmod 600 -- "$pane_file" 2>/dev/null || {
      _vpn_error "Could not restrict VPN preview row $index."
      _vpn_preview_dir_cleanup
      return 1
    }
    _vpn_state_validate_file \
      "$pane_file" "$_VPN_PREVIEW_DIR" "preview pane" \
      "$_VPN_MAX_PREVIEW_BYTES" || {
      _vpn_preview_dir_cleanup
      return 1
    }
    index=$(( index + 1 ))
  done

  return 0
}

typeset -g _VPN_PREVIEW_SOURCED=1
