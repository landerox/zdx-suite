#!/usr/bin/env zsh
# =============================================================================
# VPN Compat: deprecated command names, scheduled for removal
# =============================================================================
#
# Loaded by vpn-menu.zsh after every other module under functions/vpn/.
# Safe to re-source; defines functions only.
#
# These names predate the current surface. Each forwards to its canonical owner
# and emits one deprecation notice per shell session. They are deliberately
# absent from the menu, help, and completion, and are scheduled for removal in
# v0.3.0.
#

if [[ -n "${_VPN_COMPAT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# vpn-public-ip — superseded by the richer vpn-ip-info view.
vpn-public-ip() {
  _vpn_deprecated_alias vpn-public-ip vpn-ip-info
  vpn-ip-info "$@"
}

# vpn-status — ran vpn-details followed by the public exit lookup.
vpn-status() {
  _vpn_deprecated_alias vpn-status "vpn-details and vpn-ip-info"
  vpn-details "$@" || return $?
  _vpn_blank
  vpn-ip-info
}

# vpn-disconnect-active — vpn-off with no argument already picks among the
# active tunnels, so this was a second implementation of the same action.
vpn-disconnect-active() {
  _vpn_deprecated_alias vpn-disconnect-active vpn-off
  vpn-off "$@"
}

typeset -g _VPN_COMPAT_SOURCED=1
