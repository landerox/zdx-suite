#!/usr/bin/env zsh
# =============================================================================
# VPN Access: authenticate, invalidate sudo timestamps, and report access state
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh and vpn-state.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_VPN_ACCESS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# vpn-access-unlock
#   Arguments: --help only.
#   stdout:    none. Progress goes to stderr.
#   Effects:   authenticates with sudo so later reads need no prompt.
#   Status:    0 when unlocked, 1 when authentication failed.
vpn-access-unlock() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-access-unlock"
      print -u2 -r -- \
        "  Authenticate with sudo so profiles and live tunnel state are readable."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-access-unlock accepts no arguments."; return 2 ;;
  esac

  _vpn_header "Unlock VPN Access"

  if _vpn_have_sudo_cache; then
    _vpn_success "Non-interactive sudo access is already available."
    return 0
  fi

  _vpn_ensure_sudo_access "Reading VPN profiles and live tunnel state"
}

# vpn-access-lock
#   Arguments: --help only.
#   Effects:   invalidates the sudo timestamp associated with this session.
#              Other commands sharing that sudo timestamp are affected too.
#   Status:    0 on success, 1 when sudo is unavailable or invalidation fails.
vpn-access-lock() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-access-lock"
      print -u2 -r -- \
        "  Invalidate this session's sudo timestamp with 'sudo -k'."
      print -u2 -r -- \
        "  This can affect other commands that share the same sudo timestamp."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-access-lock accepts no arguments."; return 2 ;;
  esac

  _vpn_header "Lock VPN Access"

  if ! command -v sudo &>/dev/null; then
    _vpn_warn "sudo is not installed; there is no credential cache to clear."
    return 1
  fi

  if ! command sudo -k; then
    _vpn_error "sudo could not invalidate the current session timestamp."
    return 1
  fi

  if _vpn_have_sudo_cache; then
    _vpn_warn \
      "The sudo timestamp was invalidated, but non-interactive sudo remains available."
    _vpn_dim "A NOPASSWD rule or host sudo policy may provide access without a timestamp."
  else
    _vpn_success "Invalidated the current session's sudo timestamp."
  fi
  return 0
}

# vpn-access-status
#   Arguments: --help only.
#   stdout:    none. The report is UI and goes to stderr.
#   Effects:   read-only.
#   Status:    0 always.
vpn-access-status() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-access-status"
      print -u2 -r -- \
        "  Explain whether profiles and live tunnel state are readable."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-access-status accepts no arguments."; return 2 ;;
  esac

  _vpn_header "VPN Access Status"

  local dir platform
  dir=$(_vpn_config_dir)
  platform=$(_vpn_platform)

  local dir_meta=""
  if [[ -d "$dir" ]]; then
    dir_meta=$(command stat -c '%A %a %U %G' "$dir" 2>/dev/null) \
      || dir_meta=$(command stat -f '%Sp %Lp %Su %Sg' "$dir" 2>/dev/null)
  fi

  _vpn_label "Platform" "$platform"
  _vpn_label "Profile dir" "$dir"
  _vpn_label "Directory mode" "${dir_meta:-missing}"
  _vpn_label "Profile access" \
    "$(_vpn_access_label "$(_vpn_configs_access_state)")"
  _vpn_label "Tunnel state" "$(_vpn_access_label "$(_vpn_wg_access_state)")"

  if _vpn_have_sudo_cache; then
    _vpn_label "Non-interactive sudo" "available"
  else
    _vpn_label "Non-interactive sudo" "unavailable"
  fi

  local default_iface last_iface
  default_iface=$(_vpn_effective_default_iface) || default_iface=""
  last_iface=$(_vpn_effective_last_iface) || last_iface=""
  _vpn_label "Default" "${default_iface:-(none)}"
  _vpn_label "Last used" "${last_iface:-(none)}"

  case "$platform" in
    linux|wsl) ;;
    *)
      _vpn_blank
      if _vpn_config_dir_is_default; then
        _vpn_dim \
          "This suite targets Linux and WSL. Set VPN_CONFIG_DIR for this host."
      else
        _vpn_dim "Using the configured VPN_CONFIG_DIR override for this host."
      fi
      ;;
  esac

  if [[ -d "$dir" && ! -r "$dir" ]] && ! _vpn_have_sudo_cache; then
    _vpn_blank
    _vpn_dim \
      "$dir exists but is unreadable without sudo, so profiles cannot be listed."
  fi
  return 0
}

typeset -g _VPN_ACCESS_SOURCED=1
