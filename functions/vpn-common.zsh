#!/usr/bin/env zsh
# =============================================================================
# VPN Common: shared UI, platform, privilege, access, and routing helpers
# =============================================================================
#
# Loaded by vpn-menu.zsh before every module under functions/vpn/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_VPN_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Configuration ----------------------------------------------------------
# Source time performs parameter expansion only: no external commands, no
# filesystem scans, and no network access.

# WireGuard profile directory. Linux and WSL default to /etc/wireguard. On
# macOS an unset value selects the directory at call time (_vpn_config_dir);
# other hosts must point this at their own installation prefix.
typeset -gi _VPN_CONFIG_DIR_DEFAULTED=0
[[ -n "${VPN_CONFIG_DIR:-}" ]] || _VPN_CONFIG_DIR_DEFAULTED=1
typeset -g VPN_CONFIG_DIR="${VPN_CONFIG_DIR:-/etc/wireguard}"

typeset -g VPN_CACHE_DIR="${VPN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zdx/vpn}"
typeset -g VPN_MENU_REPORT_DIR="${VPN_MENU_REPORT_DIR:-$HOME/vpn-stats}"

typeset -g VPN_BACKUP_SUFFIX=".bak-vpn-menu"

# Resource bounds. These are intentionally fixed suite limits rather than
# environment knobs: callers must not be able to turn a diagnostic or menu
# render into unbounded memory consumption.
typeset -gi _VPN_MAX_PROFILES=256
typeset -gi _VPN_MAX_ACTIVE_INTERFACES=128
typeset -gi _VPN_MAX_PROFILE_BYTES=1048576
typeset -gi _VPN_MAX_NETWORK_BYTES=262144
typeset -gi _VPN_MAX_PREVIEW_BYTES=65536
typeset -gi _VPN_MAX_CACHE_BYTES=128
typeset -gi _VPN_MAX_REPORT_BYTES=1048576
typeset -gi _VPN_MAX_DIRECTORY_ROWS=200

# Per-invocation confirmation bypass. Public commands set this only from their
# own documented --yes flag and always restore it before returning.
typeset -g _VPN_AUTO_YES=0

# --- Logging primitives -----------------------------------------------------

_vpn_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

# Top-level heading; the core service omits or demotes it inside a step.
_vpn_header() {
  if (( ${+functions[_zdx_ui_heading]} )); then
    _zdx_ui_heading "${1:-}"
    return
  fi
  if _vpn_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}

_vpn_success() {
  if _vpn_color_enabled; then
    printf '\033[1;32m✔ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✔ %s\n' "${(V)1}" >&2
  fi
}

_vpn_warn() {
  if _vpn_color_enabled; then
    printf '\033[1;33m⚠ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⚠ %s\n' "${(V)1}" >&2
  fi
}

_vpn_info() {
  if _vpn_color_enabled; then
    printf '\033[0;36m➜ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '➜ %s\n' "${(V)1}" >&2
  fi
}

_vpn_error() {
  if _vpn_color_enabled; then
    printf '\033[1;31m✘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✘ %s\n' "${(V)1}" >&2
  fi
}

_vpn_dim() {
  if _vpn_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
}

# Label/value pair. Both operands are rendered with ${(V)} so a backslash or
# control character in external data is displayed, never interpreted. The
# core service owns the shared key width (docs/output-spec.md).
_vpn_label() {
  if (( ${+functions[_zdx_ui_label]} )); then
    _zdx_ui_label "${1-}" "${2-}"
    return
  fi
  if _vpn_color_enabled; then
    printf '  \033[1m%-18s\033[0m %s\n' "${(V)1}:" "${(V)2}" >&2
  else
    printf '  %-18s %s\n' "${(V)1}:" "${(V)2}" >&2
  fi
}

_vpn_blank() { print -u2 -r -- ""; }

# --- Command output services -------------------------------------------------
# docs/output-spec.md owns the vocabulary and rendering. Each wrapper checks
# the core service at call time and keeps a plain fallback, so a standalone
# source of this suite still works without functions.zsh.

# Report sub-heading. Usage: _vpn_section [--first] <title>
_vpn_section() {
  if (( ${+functions[_zdx_ui_section]} )); then
    _zdx_ui_section "$@"
    return
  fi
  local gap=$'\n'
  if [[ "${1:-}" == --first ]]; then
    gap=""
    shift
  fi
  printf '%s▸ %s\n' "$gap" "${(V)${1:-}}" >&2
}

# Aligned columns from TAB-separated rows; plain lines when a row is rejected.
# Usage: _vpn_table [--outcome-column N] <header-tsv> [row-tsv...]
_vpn_table() {
  if (( ${+functions[_zdx_ui_table]} )); then
    _zdx_ui_table "$@" && return 0
  fi
  [[ "${1:-}" == --outcome-column ]] && shift 2
  local table_row=""
  for table_row in "$@"; do
    _vpn_dim "${table_row//$'\t'/  }"
  done
}

# REPLY: "<count> <noun>". Usage: _vpn_count_noun <count> <singular> [plural]
_vpn_count_noun() {
  if (( ${+functions[_zdx_count_noun]} )); then
    _zdx_count_noun "$@"
    return
  fi
  local count="${1:-}" singular="${2:-}" plural="${3:-${2:-}s}"
  [[ "$count" == <-> && -n "$singular" ]] || return 2
  if (( count == 1 )); then REPLY="1 $singular"; else REPLY="$count $plural"; fi
}

# REPLY: one display duration. Usage: _vpn_duration_label <seconds>
_vpn_duration_label() {
  if (( ${+functions[_zdx_format_duration]} )); then
    _zdx_format_duration "${1:-0}"
    return
  fi
  local -i seconds="${${1:-0}%%.*}"
  REPLY="${seconds}s"
}

# REPLY: a display-only path or command with HOME shown as ~.
# Usage: _vpn_command_display <argv...>
_vpn_command_display() {
  if (( ${+functions[_zdx_ui_command_display]} )); then
    _zdx_ui_command_display "$@"
    return
  fi
  REPLY="${(j: :)@}"
}

# One target result line, "<glyph> <label> — <outcome>[: <detail>]", in the
# outcome's own glyph and color.
# Usage: _vpn_outcome_line <label> <outcome> [detail]
_vpn_outcome_line() {
  local label="${(V)1}" outcome="$2" detail="${(V)${3:-}}" REPLY=""
  if ! (( ${+functions[_zdx_ui_outcome]} )) || ! _zdx_ui_outcome "$outcome"; then
    print -u2 -r -- "$label — $outcome${detail:+: $detail}"
    return 0
  fi
  local text="${REPLY%% *} $label — ${REPLY#* }${detail:+: $detail}"
  if _vpn_color_enabled && _zdx_ui_outcome_sgr "$outcome"; then
    printf '\033[%sm%s\033[0m\n' "$REPLY" "$text" >&2
  else
    print -u2 -r -- "$text"
  fi
}

# Runs a chatty privileged tool with its output captured privately and
# replayed only on failure. Usage: _vpn_run_captured <display> <command...>
_vpn_run_captured() {
  local display="$1"
  shift
  if (( ${+functions[_zdx_run_captured]} )); then
    _zdx_run_captured "$display" 262144 40 "$@"
    return
  fi
  "$@" </dev/null >&2
}

# Partial-success timing for a batch that ends with mixed results.
_vpn_mark_partial() {
  (( ${+functions[_zdx_timed_mark_partial]} )) || return 0
  _zdx_timed_mark_partial || true
}

# Render control characters visibly before including external data in UI text.
_vpn_display_escape() {
  print -r -- "${(V)1}"
}

# --- Timing -----------------------------------------------------------------

_vpn_timed() {
  local label="$1"
  shift

  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

# --- Prompts ----------------------------------------------------------------

# Confirmation gate for mutating work.
#
# Status:
#   0  confirmed, or _VPN_AUTO_YES is set from a documented --yes flag
#   1  the user declined; a decline is a cancellation, not an error
#   2  no terminal is attached, so no confirmation can be obtained
#
# Callers MUST distinguish 1 from 2: a decline returns 0 from the public
# command, while "cannot prompt" fails closed and names the flag to pass.
_vpn_confirm() {
  local prompt="${1:-Proceed?}"

  if (( _VPN_AUTO_YES )); then
    return 0
  fi

  if [[ ! -t 0 || ! -t 2 ]]; then
    return 2
  fi

  # `reply` is declared local so the prompt never clobbers the caller's REPLY,
  # which read -q would otherwise overwrite in the global scope.
  local reply
  if _vpn_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi
  read -r reply
  print -u2 -r -- ""
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Reports the confirmation outcome as one word on stdout so every call site
# makes the same three-way decision: confirmed, declined, or unavailable.
_vpn_confirm_outcome() {
  local prompt="$1"
  local -i confirm_status=0

  _vpn_confirm "$prompt" || confirm_status=$?

  case "$confirm_status" in
    0) print -r -- "confirmed" ;;
    2) print -r -- "unavailable" ;;
    *) print -r -- "declined" ;;
  esac
  return 0
}

# Reads one line of input. Data goes to stdout; the prompt to stderr.
# Status 1 for an empty answer or end of input (a cancellation), 3 when no
# terminal is available to ask.
_vpn_read_line() {
  local prompt="$1"
  local default_value="${2:-}"
  [[ -t 0 && -t 2 ]] || return 3

  if [[ -n "$default_value" ]]; then
    printf '  %s [%s]: ' "${(V)prompt}" "${(V)default_value}" >&2
  else
    printf '  %s: ' "${(V)prompt}" >&2
  fi

  local reply
  read -r reply || return 1
  reply="${reply:-$default_value}"
  [[ -n "$reply" ]] || return 1
  print -r -- "$reply"
}

# --- Dependencies -----------------------------------------------------------

_vpn_check_cmd() {
  command -v "$1" &>/dev/null
}

_vpn_check_wg_quick() {
  if ! _vpn_check_cmd wg-quick; then
    _vpn_error "WireGuard (wg-quick) is not installed."
    _vpn_wireguard_install_hint
    return 1
  fi
  return 0
}

_vpn_check_wg() {
  if ! _vpn_check_cmd wg; then
    _vpn_error "WireGuard (wg) is not installed."
    _vpn_wireguard_install_hint
    return 1
  fi
  return 0
}

_vpn_wireguard_install_hint() {
  if _vpn_platform_is darwin; then
    _vpn_info "Install it with: brew install wireguard-tools"
  else
    _vpn_info "Install the wireguard-tools package for this host."
  fi
}

_vpn_have_ip_stack() {
  _vpn_check_cmd jq && _vpn_check_cmd curl
}

_vpn_check_ip_stack() {
  if ! _vpn_check_cmd jq; then
    _vpn_error "jq is not installed. It is required to parse IP provider JSON."
    return 1
  fi
  if ! _vpn_check_cmd curl; then
    _vpn_error "curl is not installed. It is required for network lookups."
    return 1
  fi
  return 0
}

# --- Bounded execution ------------------------------------------------------

# Runs one external program with a deadline: status 124 on timeout, 2 for
# invalid arguments, and 127 when the program is not on PATH. The program is
# resolved to its absolute path, so a shell function or alias of the same name
# never runs. The core _zdx_run_with_timeout owns the portable implementation,
# including a Zsh watchdog for hosts without timeout, such as stock macOS.
# When this suite is sourced without the core, timeout or gtimeout is
# required: check _vpn_bounded_ready first.
# Usage: _vpn_run_with_timeout <seconds> <program> [argument...]
_vpn_run_with_timeout() {
  local seconds="${1-}"
  shift 2>/dev/null
  [[ "$seconds" == <1-600> && ${#seconds} -le 3 ]] && (( $# > 0 )) \
    || return 2
  local program="$1"
  shift
  if [[ "$program" != /* ]]; then
    program=$(whence -p -- "$program" 2>/dev/null) || program=""
  fi
  [[ "$program" == /* && -x "$program" ]] || return 127

  if (( ${+functions[_zdx_run_with_timeout]} )); then
    _zdx_run_with_timeout "$seconds" "$program" "$@"
    return
  fi
  local candidate="" timeout_command=""
  for candidate in timeout gtimeout; do
    timeout_command=$(whence -p -- "$candidate" 2>/dev/null) \
      || timeout_command=""
    [[ "$timeout_command" == /* && -x "$timeout_command" ]] || continue
    command "$timeout_command" -k 2s "${seconds}s" "$program" "$@"
    return
  done
  return 1
}

# Status 0 when bounded programs can run: always with the core loaded, and
# otherwise when timeout or gtimeout exists. Prints the refusal otherwise.
_vpn_bounded_ready() {
  (( ${+functions[_zdx_run_with_timeout]} )) && return 0
  if _vpn_check_cmd timeout || _vpn_check_cmd gtimeout; then
    return 0
  fi
  _vpn_error \
    "Bounded VPN probes need timeout or gtimeout when the ZDX core is not loaded."
  return 1
}

# --- Platform contract ------------------------------------------------------
# Support is command-specific and capability based. The suite supports Linux,
# WSL, and macOS with Homebrew wireguard-tools. Linux and WSL use
# /etc/wireguard, iproute2, and Linux file attributes for the WSL resolver pin;
# macOS uses wg-quick's userspace utun devices, BSD networking tools, and
# scutil, implemented in vpn/vpn-darwin.zsh and chosen at call time. Other
# hosts must opt in by pointing VPN_CONFIG_DIR at their own WireGuard
# directory.

typeset -g _VPN_PLATFORM=""

_vpn_platform() {
  if [[ -z "$_VPN_PLATFORM" ]]; then
    local kernel
    kernel=$(command uname -s 2>/dev/null)
    case "$kernel" in
      Linux)
        if _vpn_is_wsl; then
          _VPN_PLATFORM="wsl"
        else
          _VPN_PLATFORM="linux"
        fi
        ;;
      Darwin) _VPN_PLATFORM="darwin" ;;
      *)      _VPN_PLATFORM="other" ;;
    esac
  fi
  print -r -- "$_VPN_PLATFORM"
}

# Caches the platform in the current shell, so callers that branch often do
# not fork. A replaced _vpn_platform is honored on first use.
_vpn_platform_load() {
  [[ -n "$_VPN_PLATFORM" ]] || _VPN_PLATFORM=$(_vpn_platform)
}

# True when the host is the named platform: linux, wsl, darwin, or other.
_vpn_platform_is() {
  _vpn_platform_load
  [[ "$_VPN_PLATFORM" == "${1:-}" ]]
}

# The one WSL detector. The platform check, the IPv6 compatibility rewrite,
# DNS hardening, and the report all use it through _vpn_platform, so they
# cannot disagree about the host.
_vpn_is_wsl() {
  [[ -n "${WSL_DISTRO_NAME-}" ]] && return 0
  command grep -qi microsoft /proc/version 2>/dev/null
}

# True when VPN_CONFIG_DIR still holds the Linux default, meaning the user has
# not told the suite where WireGuard lives on this host.
_vpn_config_dir_is_default() {
  [[ "$VPN_CONFIG_DIR" == "/etc/wireguard" ]]
}

# True when the macOS directory policy chooses the profile directory: the
# variable was unset when the suite loaded and still holds the default.
_vpn_config_dir_is_selected() {
  (( _VPN_CONFIG_DIR_DEFAULTED )) && _vpn_config_dir_is_default \
    && _vpn_platform_is darwin
}

# Caches the platform and, for the macOS directory policy, the Homebrew
# prefix in the current shell, so a command's subshells ask neither again.
_vpn_platform_prepare() {
  _vpn_platform_load
  _vpn_config_dir_is_selected || return 0
  local REPLY=""
  _vpn_darwin_brew_prefix >/dev/null 2>&1 || true
}

# Gate for every command that reads or writes the profile directory. An
# unsupported host returns promptly and clearly instead of emitting a cascade
# of command-not-found and permission errors.
_vpn_require_platform() {
  _vpn_platform_prepare
  case "$_VPN_PLATFORM" in
    linux|wsl|darwin) ;;
    *)
      if _vpn_config_dir_is_default; then
        _vpn_error "The VPN suite targets Linux, WSL, and macOS."
        _vpn_info \
          "Set VPN_CONFIG_DIR to the WireGuard directory for this host to continue."
        _vpn_dim "For example: VPN_CONFIG_DIR=/usr/local/etc/wireguard"
        return 1
      fi
      ;;
  esac

  _vpn_config_dir_resolve >/dev/null
}

# --- Profile directory and identifiers --------------------------------------

# stdout: the configured profile directory without trailing slashes. On macOS,
# an unset VPN_CONFIG_DIR selects /private/etc/wireguard when it exists, else
# a Homebrew etc/wireguard that already holds profiles, else the system path,
# which profile creation makes root-owned and private.
_vpn_config_dir() {
  local dir="${VPN_CONFIG_DIR:-}"
  if _vpn_config_dir_is_selected; then
    local REPLY=""
    _vpn_darwin_default_config_dir && dir="$REPLY"
  fi
  while [[ "$dir" != "/" && "$dir" == */ ]]; do
    dir="${dir%/}"
  done
  print -r -- "$dir"
}

# REPLY: the canonical directory for an absolute, normalized literal path.
# A symbolic link component is accepted only when root owns the link and its
# directory, which group and other users cannot write: a system alias such as
# macOS /etc -> private/etc. Every other link is refused.
_vpn_config_dir_canonical() {
  emulate -L zsh
  REPLY=""
  local literal="${1:-}"
  [[ "$literal" == /* ]] || return 1
  local resolved="${literal:A}"
  [[ "$resolved" == /* ]] || return 1
  if [[ "$literal" == "$resolved" ]]; then
    REPLY="$literal"
    return 0
  fi

  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -a components=("${(@s:/:)literal}")
  local prefix="" component=""
  local -A link_state=() parent_state=()
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    prefix+="/$component"
    [[ -L "$prefix" ]] || continue
    link_state=()
    parent_state=()
    zstat -LH link_state -- "$prefix" 2>/dev/null || return 1
    zstat -H parent_state -- "${prefix:h}" 2>/dev/null || return 1
    (( link_state[uid] == 0 && parent_state[uid] == 0 \
      && (parent_state[mode] & 8#22) == 0 )) || return 1
  done
  REPLY="$resolved"
}

# stdout: the canonical profile directory after rejecting traversal, protected
# roots, control characters, and every symlink component other than a
# root-owned system alias.
_vpn_config_dir_resolve() {
  local configured
  configured=$(_vpn_config_dir)

  if [[ -z "$configured" || "$configured" != /* ]]; then
    _vpn_error "VPN_CONFIG_DIR must be an absolute path."
    return 1
  fi
  if [[ "$configured" == ".." || "$configured" == ../* \
    || "$configured" == */../* || "$configured" == */.. ]]; then
    _vpn_error "VPN_CONFIG_DIR must not contain '..' path segments."
    return 1
  fi
  if [[ "$configured" == *$'\n'* || "$configured" == *$'\r'* \
    || "$configured" == *$'\0'* ]]; then
    _vpn_error "VPN_CONFIG_DIR contains unsupported control characters."
    return 1
  fi

  local literal="${configured:a}"
  local home_root="${HOME:A}"
  if [[ -z "$literal" || "$literal" == "/" || "$literal" == "$home_root" ]]; then
    _vpn_error "Refusing a protected VPN_CONFIG_DIR: ${literal:-<empty>}"
    return 1
  fi
  local REPLY=""
  if ! _vpn_config_dir_canonical "$literal"; then
    _vpn_error "Refusing a VPN_CONFIG_DIR with symlink components: $literal"
    return 1
  fi
  if [[ "$REPLY" == "/" || "$REPLY" == "$home_root" ]]; then
    _vpn_error "Refusing a protected VPN_CONFIG_DIR: $REPLY"
    return 1
  fi

  print -r -- "$REPLY"
}

# An interface name becomes a filename, a `wg-quick` argument, and a network
# device name. Requiring a leading alphanumeric is what keeps a name from being
# parsed as an option by any of them.
_vpn_validate_iface_name() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 1
  (( ${#iface} <= 64 )) || return 1
  # Bracket globs compare code points; =~ ranges follow locale collation.
  [[ "$iface" == [A-Za-z0-9]* && "$iface" != *[^A-Za-z0-9._-]* ]]
}

# A name for a new or renamed profile must also fit wg-quick's 15-character
# interface limit; longer existing names stay listed so they can be renamed or
# removed.
_vpn_validate_new_iface_name() {
  _vpn_validate_iface_name "${1:-}" && (( ${#1} <= 15 ))
}

_vpn_conf_path() {
  local iface="${1:-}"
  _vpn_validate_iface_name "$iface" || return 1
  local dir
  dir=$(_vpn_config_dir_resolve) || return 1
  print -r -- "${dir}/${iface}.conf"
}

_vpn_backup_path() {
  local iface="${1:-}"
  local conf_file
  conf_file=$(_vpn_conf_path "$iface") || return 1
  print -r -- "${conf_file}${VPN_BACKUP_SUFFIX}"
}

# stdout: a stable device:inode:owner:mode identity for the profile directory.
# The directory may be owned by root (the Linux default) or by the invoking
# user (an explicit unprivileged override), but it must never be writable by
# another account.
_vpn_config_dir_identity() {
  local dir
  dir=$(_vpn_config_dir_resolve) || return 1
  [[ -d "$dir" && ! -L "$dir" ]] || {
    _vpn_error "WireGuard profile directory is missing: $dir"
    return 1
  }

  zmodload -F zsh/stat b:zstat 2>/dev/null || {
    _vpn_error "The zsh/stat module is required to validate VPN paths."
    return 1
  }
  local -A metadata=()
  zstat -H metadata -- "$dir" 2>/dev/null || {
    _vpn_error "Could not inspect the WireGuard profile directory: $dir"
    return 1
  }
  if (( metadata[uid] != 0 && metadata[uid] != EUID )); then
    _vpn_error "Refusing a VPN_CONFIG_DIR owned by another account: $dir"
    return 1
  fi
  if (( (metadata[mode] & 8#22) != 0 )); then
    _vpn_error "VPN_CONFIG_DIR must not be group/world writable: $dir"
    return 1
  fi

  print -r -- \
    "${metadata[device]}:${metadata[inode]}:${metadata[uid]}:${metadata[mode]}"
}

# stdout: root or user, the owner class of the existing profile directory.
_vpn_config_dir_owner_kind() {
  local identity
  identity=$(_vpn_config_dir_identity 2>/dev/null) || return 1
  local -a fields=("${(@s.:.)identity}")
  if (( fields[3] == 0 )); then
    print -r -- "root"
  else
    print -r -- "user"
  fi
}

_vpn_assert_config_dir_identity() {
  local expected="$1"
  local current
  current=$(_vpn_config_dir_identity) || return 1
  if [[ "$current" != "$expected" ]]; then
    _vpn_error \
      "VPN_CONFIG_DIR changed during the operation; refusing to continue."
    return 1
  fi
}

# --- Trusted executables ----------------------------------------------------
# Root runs these files, so no account other than root (and, with --user, the
# invoking user) may be able to change them.

# True when a file or directory's owner and write bits keep it under the
# control of root or, with allow_user, the current user. Other users may never
# write it, except a root-owned sticky directory such as /tmp, where another
# account cannot rename or remove an entry it does not own. With allow_user on
# macOS, group write is accepted for wheel (0) and admin (80): Homebrew makes
# its prefix directories group-writable by admin, whose members can already
# use sudo. Usage: _vpn_trusted_owner_mode <uid> <gid> <mode> <allow_user>
_vpn_trusted_owner_mode() {
  local -i owner="$1" group="$2" file_mode="$3" allow_user="$4"
  (( owner == 0 || (allow_user && owner == EUID) )) || return 1
  if (( owner == 0 && (file_mode & 8#1000) != 0 )); then
    return 0
  fi
  (( (file_mode & 8#002) == 0 )) || return 1
  (( (file_mode & 8#020) == 0 )) && return 0
  (( allow_user && (group == 0 || group == 80) )) && _vpn_platform_is darwin
}

# True when DIR and every ancestor up to / is a real directory that passes
# _vpn_trusted_owner_mode. Usage: _vpn_trusted_dir_chain [--user] <canonical-dir>
_vpn_trusted_dir_chain() {
  emulate -L zsh
  local -i allow_user=0
  if [[ "${1:-}" == --user ]]; then
    allow_user=1
    shift
  fi
  local dir="${1:-}"
  [[ "$dir" == /* ]] || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A state=()
  while true; do
    state=()
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    zstat -LH state -- "$dir" 2>/dev/null || return 1
    _vpn_trusted_owner_mode \
      "${state[uid]}" "${state[gid]}" "${state[mode]}" "$allow_user" || return 1
    [[ "$dir" == / ]] && return 0
    dir="${dir:h}"
  done
}

# True when an absolute executable is controlled only by root or, with
# --user, by root and the current user: the canonical file, every directory
# above it, and every symbolic link on the literal path with its directory.
# Usage: _vpn_trusted_executable [--user] <absolute-path>
_vpn_trusted_executable() {
  emulate -L zsh
  local -a owner_flag=()
  local -i allow_user=0
  if [[ "${1:-}" == --user ]]; then
    owner_flag=(--user)
    allow_user=1
    shift
  fi
  local literal="${1:-}"
  [[ "$literal" == /* && "$literal" == "${literal:a}" ]] || return 1
  [[ "$literal" != *[[:cntrl:]]* ]] || return 1
  local canonical="${literal:A}"
  [[ -f "$canonical" && -x "$canonical" ]] || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1

  local -A state=()
  local -a components=("${(@s:/:)literal}")
  local prefix="" component=""
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    prefix+="/$component"
    [[ -L "$prefix" ]] || continue
    state=()
    zstat -LH state -- "$prefix" 2>/dev/null || return 1
    (( state[uid] == 0 || (allow_user && state[uid] == EUID) )) || return 1
    _vpn_trusted_dir_chain "${owner_flag[@]}" "${prefix:h:A}" || return 1
  done

  state=()
  zstat -H state -- "$canonical" 2>/dev/null || return 1
  (( (state[mode] & 8#1000) == 0 )) || return 1
  _vpn_trusted_owner_mode \
    "${state[uid]}" "${state[gid]}" "${state[mode]}" "$allow_user" || return 1
  _vpn_trusted_dir_chain "${owner_flag[@]}" "${canonical:h}"
}

# REPLY: a root-controlled zsh for the fixed privileged metadata probe. A
# user-owned shell is never run as root, so a host whose only zsh is owned by
# the user reports protected profiles as unknown instead.
_vpn_trusted_zsh() {
  REPLY=""
  local candidate=""
  local -a candidates=(/bin/zsh /usr/bin/zsh /usr/local/bin/zsh)
  candidate=$(whence -p zsh 2>/dev/null) && candidates+=("$candidate")
  for candidate in "${candidates[@]}"; do
    [[ -e "$candidate" ]] || continue
    _vpn_trusted_executable "$candidate" || continue
    REPLY="${candidate:A}"
    return 0
  done
  return 1
}

# --- Privileged metadata probe ----------------------------------------------
# Protected profile metadata is read by this fixed program, run by a trusted
# root zsh. The path is a positional argument, never program text. The record
# has exactly the format of the unprivileged fingerprint fields, so both paths
# compare equal on every platform; the program reads a link itself (lstat).

typeset -g _VPN_STAT_PROBE_PROGRAM='zmodload -F zsh/stat b:zstat || exit 2
(( $# == 1 )) || exit 2
typeset -A s
zstat -L -H s -- "$1" || exit 1
print -r -- "${s[device]}:${s[inode]}:${s[uid]}:${s[mode]}:${s[nlink]}:${s[size]}:${s[mtime]}:${s[ctime]}"'

# True when a metadata record has eight unsigned integer fields.
_vpn_stat_record_valid() {
  local record="${1:-}"
  [[ -n "$record" && "$record" != *$'\n'* ]] || return 1
  local -a fields=("${(@s.:.)record}")
  (( ${#fields[@]} == 8 )) || return 1
  local field
  for field in "${fields[@]}"; do
    [[ "$field" == <-> ]] || return 1
  done
}

# True when a record describes a usable profile: a private, singly linked
# regular file owned by root or the current user, within the size cap.
_vpn_stat_record_safe() {
  _vpn_stat_record_valid "${1:-}" || return 1
  local -a fields=("${(@s.:.)1}")
  local -i owner=${fields[3]} file_mode=${fields[4]} links=${fields[5]}
  local -i bytes=${fields[6]}
  (( (file_mode & 8#170000) == 8#100000 && links == 1 \
    && (owner == 0 || owner == EUID) && (file_mode & 8#77) == 0 \
    && bytes <= _VPN_MAX_PROFILE_BYTES ))
}

# stdout: device:inode:uid:mode:nlink:size:mtime:ctime for one absolute path,
# read through non-interactive sudo. Status: 0 printed, 1 unavailable, and
# 130/143 when interrupted.
_vpn_privileged_stat() {
  local target_path="${1:-}"
  [[ "$target_path" == /* ]] || return 1
  local REPLY=""
  _vpn_trusted_zsh || return 1
  local record=""
  local -i probe_status=0
  record=$(_vpn_sudo_probe "$REPLY" -f -c "$_VPN_STAT_PROBE_PROGRAM" \
    zdx-vpn-stat "$target_path") || probe_status=$?
  (( probe_status == 0 )) || return "$probe_status"
  _vpn_stat_record_valid "$record" || return 1
  print -r -- "$record"
}

# Checks existence without treating an interrupted probe as a missing target.
_vpn_profile_probe_exists() {
  local -i probe_status=0
  _vpn_sudo_probe test -e "$1" || probe_status=$?
  if (( probe_status == 0 || probe_status == 130 || probe_status == 143 )); then
    return "$probe_status"
  fi
  probe_status=0
  _vpn_sudo_probe test -L "$1" || probe_status=$?
  if (( probe_status == 0 || probe_status == 130 || probe_status == 143 )); then
    return "$probe_status"
  fi
  return 1
}

# stdout: safe, missing, locked, or unsafe. A usable profile/backup is a
# private, singly linked regular file owned by root or by the invoking user.
_vpn_profile_path_state() {
  local target_path="${1:-}"
  [[ -n "$target_path" ]] || {
    print -r -- "unsafe"
    return 1
  }

  if [[ ! -e "$target_path" && ! -L "$target_path" ]]; then
    local parent_dir="${target_path:h}"
    if [[ -d "$parent_dir" && -r "$parent_dir" && -x "$parent_dir" ]]; then
      print -r -- "missing"
      return 0
    elif _vpn_have_sudo_cache; then
      if _vpn_profile_probe_exists "$target_path"; then
        :
      else
        local -i probe_status=$?
        (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
        print -r -- "missing"
        return 0
      fi
    else
      local -i cache_status=$?
      (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
      print -r -- "locked"
      return 0
    fi
  fi

  local literal="${target_path:a}"
  local resolved="${target_path:A}"
  if [[ "$literal" != "$resolved" || -L "$literal" ]]; then
    print -r -- "unsafe"
    return 0
  fi

  zmodload -F zsh/stat b:zstat 2>/dev/null || {
    print -r -- "unsafe"
    return 1
  }
  local -A metadata=()
  if zstat -H metadata -- "$literal" 2>/dev/null; then
    if [[ -f "$literal" ]] \
      && (( metadata[nlink] == 1 \
        && (metadata[uid] == 0 || metadata[uid] == EUID) \
        && (metadata[mode] & 8#77) == 0 \
        && metadata[size] <= _VPN_MAX_PROFILE_BYTES )); then
      print -r -- "safe"
    else
      print -r -- "unsafe"
    fi
    return 0
  fi

  _vpn_have_sudo_cache || {
    local -i cache_status=$?
    (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
    print -r -- "locked"
    return 0
  }

  local record=""
  local -i probe_status=0
  record=$(_vpn_privileged_stat "$literal") || probe_status=$?
  (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
  if (( probe_status == 0 )); then
    if _vpn_stat_record_safe "$record"; then
      print -r -- "safe"
    else
      print -r -- "unsafe"
    fi
    return 0
  fi
  if _vpn_profile_probe_exists "$literal"; then
    print -r -- "unsafe"
  else
    probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    print -r -- "missing"
  fi
}

# stdout: a stable metadata-and-content fingerprint for a safe profile path.
# A checksum catches in-place edits that preserve the inode.
_vpn_profile_file_fingerprint() {
  local target_path="$1"
  local label="${2:-profile}"
  local path_state=""
  local -i probe_status=0
  path_state=$(_vpn_profile_path_state "$target_path") || probe_status=$?
  (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
  [[ "$path_state" == "safe" && "$probe_status" == 0 ]] || {
    _vpn_error "Refusing an unsafe or unreadable $label: $target_path"
    return 1
  }

  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A before=() after=()
  local checksum=""
  if [[ -r "$target_path" ]] && zstat -H before -- "$target_path" 2>/dev/null; then
    checksum=$(command cksum < "$target_path" 2>/dev/null) || {
      probe_status=$?
      (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
      return 1
    }
    zstat -H after -- "$target_path" 2>/dev/null || return 1

    local before_id="${before[device]}:${before[inode]}:${before[uid]}:${before[mode]}:${before[nlink]}:${before[size]}:${before[mtime]}:${before[ctime]}"
    local after_id="${after[device]}:${after[inode]}:${after[uid]}:${after[mode]}:${after[nlink]}:${after[size]}:${after[mtime]}:${after[ctime]}"
    [[ "$before_id" == "$after_id" ]] || {
      _vpn_error "$label changed while it was inspected."
      return 1
    }
    local -a checksum_fields=(${=checksum})
    (( ${#checksum_fields[@]} == 2 )) \
      && [[ "${checksum_fields[1]}" == <-> \
        && "${checksum_fields[2]}" == <-> ]] || return 1
    print -r -- "${after_id}:${checksum_fields[1]}:${checksum_fields[2]}"
    return 0
  fi

  _vpn_have_sudo_cache || {
    probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    return 1
  }
  # The privileged records use the unprivileged format above, so a profile
  # fingerprinted directly and through sudo compares equal.
  local before_id after_id
  before_id=$(_vpn_privileged_stat "$target_path") || {
    probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    return 1
  }
  checksum=$(_vpn_sudo_probe cksum -- "$target_path") || {
    probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    return 1
  }
  after_id=$(_vpn_privileged_stat "$target_path") || {
    probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    return 1
  }
  [[ -n "$before_id" && "$before_id" == "$after_id" ]] || {
    _vpn_error "$label changed while it was inspected."
    return 1
  }
  _vpn_stat_record_safe "$after_id" || {
    _vpn_error "Refusing an unsafe or unreadable $label: $target_path"
    return 1
  }
  local -a checksum_fields=(${=checksum})
  (( ${#checksum_fields[@]} >= 2 )) \
    && [[ "${checksum_fields[1]}" == <-> \
      && "${checksum_fields[2]}" == <-> ]] || return 1
  print -r -- "${after_id}:${checksum_fields[1]}:${checksum_fields[2]}"
}

# stdout: a stable fingerprint for a private regular file owned by this user.
_vpn_user_file_fingerprint() {
  local target_path="$1"
  local label="${2:-file}"
  local literal="${target_path:a}"
  local resolved="${target_path:A}"

  if [[ "$literal" != "$resolved" || ! -f "$literal" || -L "$literal" ]]; then
    _vpn_error "Refusing an unsafe $label: $literal"
    return 1
  fi

  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A before=() after=()
  zstat -H before -- "$literal" 2>/dev/null || return 1
  if (( before[uid] != EUID || before[nlink] != 1 \
    || (before[mode] & 8#77) != 0 \
    || before[size] > _VPN_MAX_PROFILE_BYTES )); then
    _vpn_error \
      "The $label must be owner-only, singly linked, and at most $_VPN_MAX_PROFILE_BYTES bytes."
    return 1
  fi

  local checksum
  checksum=$(command cksum < "$literal" 2>/dev/null) || return 1
  zstat -H after -- "$literal" 2>/dev/null || return 1
  local before_id="${before[device]}:${before[inode]}:${before[uid]}:${before[mode]}:${before[nlink]}:${before[size]}:${before[mtime]}:${before[ctime]}"
  local after_id="${after[device]}:${after[inode]}:${after[uid]}:${after[mode]}:${after[nlink]}:${after[size]}:${after[mtime]}:${after[ctime]}"
  [[ "$before_id" == "$after_id" ]] || {
    _vpn_error "$label changed while it was inspected."
    return 1
  }
  local -a checksum_fields=(${=checksum})
  (( ${#checksum_fields[@]} == 2 )) \
    && [[ "${checksum_fields[1]}" == <-> \
      && "${checksum_fields[2]}" == <-> ]] || return 1
  print -r -- "${after_id}:${checksum_fields[1]}:${checksum_fields[2]}"
}

# stdout: device:inode for an owner-only directory owned by this user.
_vpn_private_dir_identity() {
  local target_path="$1"
  local label="${2:-temporary directory}"
  local literal="${target_path:a}"
  local resolved="${target_path:A}"
  if [[ "$literal" != "$resolved" || ! -d "$literal" || -L "$literal" ]]; then
    _vpn_error "Refusing an unsafe $label: $literal"
    return 1
  fi
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$literal" 2>/dev/null || return 1
  if (( metadata[uid] != EUID || (metadata[mode] & 8#77) != 0 )); then
    _vpn_error "The $label must be owned by the current user and mode 700."
    return 1
  fi
  print -r -- "${metadata[device]}:${metadata[inode]}"
}

_vpn_assert_private_dir_identity() {
  local target_path="$1"
  local label="$2"
  local expected="$3"
  local current
  current=$(_vpn_private_dir_identity "$target_path" "$label") || return 1
  [[ "$current" == "$expected" ]] || {
    _vpn_error "$label changed during the operation."
    return 1
  }
}

# REPLY is the canonical directory for an absolute, already-normalized path.
# A symbolic link on the literal path is accepted only as a root-owned system
# alias, such as macOS /var and /tmp, or above the final component when the
# current user owns it inside a directory owned by root or the current user
# that group and other users cannot write. This mirrors the core
# _zdx_resolve_trusted_dir so the suite stays sourceable on its own.
_vpn_resolve_trusted_dir() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local requested="${1-}"
  REPLY=""
  while [[ "$requested" != / && "$requested" == */ ]]; do
    requested="${requested%/}"
  done
  [[ -n "$requested" && "$requested" == /* \
    && "$requested" == "${requested:a}" ]] || return 1

  local -A root_state=() link_state=() parent_state=()
  zstat -LH root_state -- / 2>/dev/null || return 1
  local -a components=("${(@s:/:)requested}")
  local prefix="" component=""
  local -i index=0 last=${#components}
  for component in "${components[@]}"; do
    (( ++index ))
    [[ -n "$component" ]] || continue
    prefix+="/$component"
    [[ -L "$prefix" ]] || continue
    link_state=()
    zstat -LH link_state -- "$prefix" 2>/dev/null || return 1
    (( link_state[uid] == root_state[uid] )) && continue
    (( index < last && link_state[uid] == EUID )) || return 1
    parent_state=()
    zstat -H parent_state -- "${prefix:h}" 2>/dev/null || return 1
    (( parent_state[uid] == root_state[uid] || parent_state[uid] == EUID )) \
      && (( (parent_state[mode] & 8#22) == 0 )) || return 1
  done
  local resolved="${requested:A}"
  [[ "$resolved" == /* && -d "$resolved" && ! -L "$resolved" ]] || return 1
  REPLY="$resolved"
}

# Shared temporary roots must either be owned privately by this user or be a
# root-owned sticky directory such as /tmp. Some containers expose a foreign-
# owned /tmp; in that case prefer the standard per-user runtime directory
# instead of weakening the ownership rule. A candidate may be reached through
# a trusted alias (macOS /var/folders, /tmp); stdout is the canonical root.
_vpn_temp_root_candidate() {
  local configured="${1:-}"
  [[ -n "$configured" && "$configured" == /* ]] || return 1

  local REPLY=""
  _vpn_resolve_trusted_dir "$configured" || return 1
  local literal="$REPLY"
  [[ -d "$literal" && ! -L "$literal" \
    && -w "$literal" && -x "$literal" ]] || return 1

  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$literal" 2>/dev/null || return 1
  if (( metadata[uid] == EUID )); then
    (( (metadata[mode] & 8#22) == 0 \
      || (metadata[mode] & 8#1000) != 0 )) || return 1
  elif (( metadata[uid] == 0 && (metadata[mode] & 8#1000) != 0 )); then
    :
  else
    return 1
  fi
  print -r -- "$literal"
}

_vpn_temp_root() {
  local candidate=""

  if [[ -n "${TMPDIR:-}" ]]; then
    candidate=$(_vpn_temp_root_candidate "$TMPDIR") || {
      _vpn_error "TMPDIR is not a safe temporary root: $(_vpn_display_escape "$TMPDIR")"
      return 1
    }
    print -r -- "$candidate"
    return 0
  fi

  local -a candidates=()
  [[ -n "${XDG_RUNTIME_DIR:-}" ]] && candidates+=("$XDG_RUNTIME_DIR")
  [[ -n "${XDG_CACHE_HOME:-}" ]] && candidates+=("$XDG_CACHE_HOME")
  [[ -n "${HOME:-}" ]] && candidates+=("$HOME/.cache" "$HOME")
  candidates+=("/run/user/$EUID" "/tmp")

  local configured
  for configured in "${candidates[@]}"; do
    candidate=$(_vpn_temp_root_candidate "$configured" 2>/dev/null) || continue
    print -r -- "$candidate"
    return 0
  done

  _vpn_error \
    "No owner-controlled runtime directory or root-owned sticky /tmp is available."
  return 1
}

_vpn_make_private_temp_dir() {
  local prefix="${1:-zdx-vpn}"
  [[ "$prefix" =~ '^zdx-vpn-[A-Za-z0-9-]{1,32}$' ]] || return 1
  local temp_root
  temp_root=$(_vpn_temp_root) || return 1

  local created
  created=$(umask 077; command mktemp -d \
    "${temp_root}/${prefix}.XXXXXX" 2>/dev/null) || return 1
  command chmod -- 700 "$created" 2>/dev/null || {
    command rmdir -- "$created" 2>/dev/null
    return 1
  }
  _vpn_private_dir_identity "$created" "$prefix directory" >/dev/null || {
    command rmdir -- "$created" 2>/dev/null
    return 1
  }
  print -r -- "$created"
}

# Extracts the single valid interface name from captured picker output. Picker
# output is data: it is validated here rather than trusted.
_vpn_sanitize_iface_capture() {
  # The `##` repetition operator below requires extended globbing, scoped to
  # this function so the caller's options are untouched.
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local raw="${1:-}"
  local line iface=""
  local -i seen=0

  [[ -n "$raw" ]] || return 1

  for line in "${(@f)raw}"; do
    line="${line%$'\r'}"
    line="${line##[[:space:]]##}"
    line="${line%%[[:space:]]##}"
    [[ -n "$line" ]] || continue
    (( ++seen == 1 )) || return 1
    _vpn_validate_iface_name "$line" || return 1
    iface="$line"
  done

  (( seen == 1 )) || return 1
  print -r -- "$iface"
}

# --- Privilege model --------------------------------------------------------
# Least privilege: selection, parsing, and preview never run as root. Only the
# final validated operation crosses the boundary, and it uses a non-interactive
# sudo so the caller can revalidate its target after authentication.

# Fixed system locations for the privileged file primitives on macOS, whose
# default sudoers keeps the caller's PATH instead of a secure_path. Linux and
# WSL rely on sudo's secure_path and pass the names unchanged.
typeset -gA _VPN_DARWIN_SYSTEM_TOOLS=(
  cat /bin/cat
  cksum /usr/bin/cksum
  find /usr/bin/find
  head /usr/bin/head
  install /usr/bin/install
  ln /bin/ln
  mktemp /usr/bin/mktemp
  mv /bin/mv
  rm /bin/rm
  test /bin/test
  true /usr/bin/true
)

# reply: the exact argv sudo receives. On macOS a bare name must be one of the
# fixed primitives above; anything else must already be a validated absolute
# path. Status 1 refuses an unknown bare name there.
_vpn_privileged_argv() {
  reply=("$@")
  (( $# > 0 )) || return 2
  _vpn_platform_is darwin || return 0
  [[ "$1" == /* ]] && return 0
  [[ -n "${_VPN_DARWIN_SYSTEM_TOOLS[$1]-}" ]] || return 1
  reply[1]="${_VPN_DARWIN_SYSTEM_TOOLS[$1]}"
}

_vpn_have_sudo_cache() {
  command -v sudo &>/dev/null || return 1
  local -a reply=()
  _vpn_privileged_argv true || return 1
  command sudo -n "${reply[@]}" &>/dev/null
}

# Authenticates once, interactively, after printing why it is needed.
_vpn_ensure_sudo_access() {
  local reason="${1:-VPN access}"

  if ! command -v sudo &>/dev/null; then
    _vpn_error "sudo is not installed; privileged VPN actions are unavailable."
    return 1
  fi

  if _vpn_have_sudo_cache; then
    return 0
  else
    local -i cache_status=$?
    (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
  fi

  _vpn_info "$reason requires sudo authentication."
  if command sudo -v; then
    _vpn_success "VPN access unlocked."
    return 0
  else
    local -i auth_status=$?
    if (( auth_status == 130 || auth_status == 143 )); then
      _vpn_warn "VPN authentication interrupted."
      return "$auth_status"
    fi
  fi

  _vpn_error "Could not unlock sudo access."
  return 1
}

# Runs one already-authorized privileged command. Requires non-interactive sudo
# access (a warm timestamp or NOPASSWD policy), so it never prompts. That lets a
# caller revalidate its target between authentication and mutation.
_vpn_sudo_exec() {
  (( $# > 0 )) || return 2
  local -a reply=()
  _vpn_privileged_argv "$@" || {
    _vpn_error "Refusing an unpinned privileged command: ${(V)1}"
    return 1
  }
  local -a privileged_argv=("${reply[@]}")
  _vpn_have_sudo_cache || {
    local -i cache_status=$?
    (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
    return 1
  }
  command sudo -n -- "${privileged_argv[@]}"
}

# Read-only privileged probe. Failure is expected and silent: callers fall back
# to reporting an unknown state rather than escalating.
_vpn_sudo_probe() {
  (( $# > 0 )) || return 2
  local -a reply=()
  _vpn_privileged_argv "$@" || return 1
  local -a privileged_argv=("${reply[@]}")
  _vpn_have_sudo_cache || {
    local -i cache_status=$?
    (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
    return 1
  }
  command sudo -n -- "${privileged_argv[@]}" 2>/dev/null
}

# Announces the exact privileged operation before credentials are requested.
_vpn_announce_privileged() {
  _vpn_info "Privileged operation: $1"
}

# Creates a mode-600 root/user-owned temporary immediately below an already
# validated profile directory. The privileged command's stdout is treated as
# untrusted data and must resolve to exactly one expected pathname.
_vpn_privileged_temp_create() {
  local dir="$1"
  local purpose="$2"
  [[ "$purpose" =~ '^[a-z][a-z0-9-]{0,23}$' ]] || return 1

  local temp_file
  temp_file=$(
    _vpn_sudo_exec mktemp "${dir}/.zdx-vpn-${purpose}.XXXXXX"
  ) || return 1
  temp_file="${temp_file%$'\r'}"
  local -a temp_lines=("${(@f)temp_file}")
  (( ${#temp_lines[@]} == 1 )) \
    && [[ "${temp_file:a:h}" == "${dir:A}" \
      && "${temp_file:t}" == ".zdx-vpn-${purpose}."* \
      && "${temp_file:a}" == "${temp_file:A}" \
      && "$(_vpn_profile_path_state "$temp_file")" == "safe" ]] || {
    _vpn_error "The privileged temporary path was invalid."
    return 1
  }
  print -r -- "$temp_file"
}

_vpn_privileged_temp_cleanup() {
  local temp_file="${1:-}"
  [[ -n "$temp_file" ]] || return 0
  case "$(_vpn_profile_path_state "$temp_file")" in
    missing) return 0 ;;
    safe) _vpn_sudo_exec rm -- "$temp_file" >/dev/null 2>&1 ;;
    *)
      _vpn_warn "A privileged temporary changed identity; refusing cleanup."
      return 1
      ;;
  esac
}

# Atomically publishes one private staged file to a profile pathname. The
# caller captures all identities before authentication and passes them here
# after non-interactive sudo access is available.
_vpn_atomic_install_staged() {
  local staged="$1"
  local target="$2"
  local expected_staged="$3"
  local expected_target="$4"
  local directory_identity="$5"
  local purpose="${6:-install}"

  _vpn_assert_config_dir_identity "$directory_identity" || return 1
  local current_staged
  current_staged=$(
    _vpn_user_file_fingerprint "$staged" "staged profile"
  ) || return 1
  [[ "$current_staged" == "$expected_staged" ]] || {
    _vpn_error "The staged profile changed during authentication."
    return 1
  }

  local current_target
  if [[ "$expected_target" == "missing" ]]; then
    [[ "$(_vpn_profile_path_state "$target")" == "missing" ]] || {
      _vpn_error "The profile target appeared before publication."
      return 1
    }
  else
    current_target=$(
      _vpn_profile_file_fingerprint "$target" "profile target"
    ) || return 1
    [[ "$current_target" == "$expected_target" ]] || {
      _vpn_error "The profile target changed before publication."
      return 1
    }
  fi

  local dir="${target:h}"
  local temp_file=""
  temp_file=$(_vpn_privileged_temp_create "$dir" "$purpose") || return 1
  {
    # Numeric owner and group: macOS has no group named root.
    _vpn_sudo_exec install -m 600 -o 0 -g 0 -- \
      "$staged" "$temp_file" || return 1
    current_staged=$(
      _vpn_user_file_fingerprint "$staged" "staged profile"
    ) || return 1
    [[ "$current_staged" == "$expected_staged" ]] || {
      _vpn_error "The staged profile changed while it was copied."
      return 1
    }
    [[ "$(_vpn_profile_path_state "$temp_file")" == "safe" ]] || return 1
    _vpn_assert_config_dir_identity "$directory_identity" || return 1

    if [[ "$expected_target" == "missing" ]]; then
      [[ "$(_vpn_profile_path_state "$target")" == "missing" ]] || return 1
      _vpn_sudo_exec ln -- "$temp_file" "$target" || return 1
      _vpn_sudo_exec rm -- "$temp_file" || {
        _vpn_sudo_exec rm -- "$target" >/dev/null 2>&1
        return 1
      }
    else
      current_target=$(
        _vpn_profile_file_fingerprint "$target" "profile target"
      ) || return 1
      [[ "$current_target" == "$expected_target" ]] || return 1
      _vpn_sudo_exec mv -f -- "$temp_file" "$target" || return 1
    fi
    temp_file=""

    local published
    published=$(
      _vpn_profile_file_fingerprint "$target" "published profile"
    ) || return 1
    local expected_crc="${${expected_staged%:*}##*:}"
    local expected_size="${expected_staged##*:}"
    local published_crc="${${published%:*}##*:}"
    local published_size="${published##*:}"
    [[ "$published_crc" == "$expected_crc" \
      && "$published_size" == "$expected_size" ]] || {
      _vpn_error "The published profile content did not match its staging file."
      return 1
    }
    return 0
  } always {
    _vpn_privileged_temp_cleanup "$temp_file" || true
  }
}

# --- Access state -----------------------------------------------------------

_vpn_configs_access_state() {
  local dir
  dir=$(_vpn_config_dir_resolve 2>/dev/null) || {
    print -r -- "unsafe"
    return 0
  }

  if [[ ! -d "$dir" ]]; then
    print -r -- "missing"
    return 0
  fi

  # Direct access also requires readable profiles: a user-owned directory may
  # hold root-owned mode-600 profiles, as the suite's own installer creates.
  local profile_path=""
  local -i profiles_readable=1
  if [[ -r "$dir" && -x "$dir" ]]; then
    for profile_path in "$dir"/*.conf(N); do
      [[ -r "$profile_path" ]] || { profiles_readable=0; break; }
    done
    if (( profiles_readable )); then
      print -r -- "direct"
      return 0
    fi
  fi

  if _vpn_have_sudo_cache; then
    print -r -- "sudo"
    return 0
  else
    local -i cache_status=$?
    (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
  fi

  print -r -- "locked"
}

_vpn_wg_access_state() {
  command -v wg &>/dev/null || {
    print -r -- "missing"
    return 0
  }

  # macOS lists devices without privileges; only an ambiguous profile pairing
  # needs a privileged read (vpn/vpn-darwin.zsh).
  if _vpn_platform_is darwin; then
    _vpn_darwin_wg_access_state
    return
  fi

  if command wg show interfaces >/dev/null 2>&1; then
    print -r -- "direct"
    return 0
  else
    local -i probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
  fi

  if _vpn_have_sudo_cache; then
    print -r -- "sudo"
    return 0
  else
    local -i cache_status=$?
    (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
  fi

  print -r -- "locked"
}

_vpn_access_label() {
  case "${1:-unknown}" in
    direct)  print -r -- "direct" ;;
    sudo)    print -r -- "unlocked via sudo" ;;
    locked)  print -r -- "locked" ;;
    missing) print -r -- "missing" ;;
    unsafe)  print -r -- "unsafe path" ;;
    *)       print -r -- "unknown" ;;
  esac
}

_vpn_ensure_profile_access() {
  _vpn_require_platform || return 1

  local state
  state=$(_vpn_configs_access_state) || return $?
  case "$state" in
    direct|sudo) return 0 ;;
    missing)
      _vpn_warn "WireGuard profile directory is missing: $(_vpn_config_dir)"
      return 1
      ;;
    locked)
      _vpn_warn "WireGuard profiles are locked behind sudo."
      _vpn_ensure_sudo_access "Loading VPN profiles" || return $?
      return 0
      ;;
    unsafe)
      _vpn_error "VPN_CONFIG_DIR is unsafe; no profile access was attempted."
      return 1
      ;;
  esac

  _vpn_warn "Could not determine access to WireGuard profiles."
  return 1
}

_vpn_ensure_profile_dir() {
  _vpn_require_platform || return 1

  local dir state
  dir=$(_vpn_config_dir_resolve) || return 1
  state=$(_vpn_configs_access_state)

  case "$state" in
    direct|sudo) return 0 ;;
    locked)
      _vpn_warn "WireGuard profiles are locked behind sudo."
      _vpn_ensure_sudo_access "Managing VPN profiles" || return 1
      return 0
      ;;
    missing)
      _vpn_warn "WireGuard profile directory is missing: $dir"

      local outcome
      outcome=$(_vpn_confirm_outcome "Create ${dir} now?")
      case "$outcome" in
        confirmed) ;;
        unavailable)
          _vpn_error \
            "Creating $dir needs confirmation; pass --yes in a non-interactive shell."
          return 1
          ;;
        *)
          _vpn_info "Cancelled."
          return 1
          ;;
      esac

      _vpn_announce_privileged "install -d -m 700 -o 0 -g 0 -- $dir"
      _vpn_ensure_sudo_access "Creating the VPN profile directory" || return 1
      if _vpn_sudo_exec install -d -m 700 -o 0 -g 0 -- "$dir"; then
        _vpn_config_dir_identity >/dev/null || {
          _vpn_error "Created $dir, but its ownership or permissions are unsafe."
          return 1
        }
        _vpn_success "Created $dir."
        return 0
      fi
      _vpn_error "Failed to create $dir."
      return 1
      ;;
    unsafe)
      _vpn_error "VPN_CONFIG_DIR is unsafe; refusing to create or modify it."
      return 1
      ;;
  esac

  _vpn_warn "Could not determine access to WireGuard profiles."
  return 1
}

_vpn_test_write_access() {
  local dir
  dir=$(_vpn_config_dir_resolve) || return 1

  if [[ ! -d "$dir" ]]; then
    _vpn_error "WireGuard profile directory $dir does not exist."
    return 1
  fi

  [[ -w "$dir" ]] && return 0
  _vpn_sudo_probe test -w "$dir" && return 0

  _vpn_error "No write access to $dir. Profiles cannot be managed."
  return 1
}

_vpn_ensure_wg_access() {
  local state
  state=$(_vpn_wg_access_state) || return $?
  case "$state" in
    direct|sudo) return 0 ;;
    missing)
      _vpn_warn "Live tunnel state is unavailable because 'wg' is not installed."
      return 1
      ;;
    locked)
      _vpn_warn "Live tunnel state is locked behind sudo."
      _vpn_ensure_sudo_access "Reading active VPN state" || return $?
      return 0
      ;;
  esac

  _vpn_warn "Could not determine access to live VPN state."
  return 1
}

# --- WireGuard introspection ------------------------------------------------

# Runs `wg` unprivileged first and only falls back to an already-warm sudo
# cache. It never triggers an authentication prompt from a read path.
_vpn_run_wg() {
  command -v wg &>/dev/null || return 1

  if command wg "$@" 2>/dev/null; then
    return 0
  else
    local -i probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
  fi

  # macOS keeps the caller's PATH under sudo, so root runs only a validated
  # absolute wg there.
  if _vpn_platform_is darwin; then
    local REPLY=""
    _vpn_darwin_wg_tool 2>/dev/null || return 1
    _vpn_sudo_probe "$REPLY" "$@"
    return
  fi
  _vpn_sudo_probe wg "$@"
}

_vpn_get_active_interfaces() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local captured
  captured=$(
    _vpn_run_wg show interfaces 2>/dev/null \
      | command head -c "$(( _VPN_MAX_PREVIEW_BYTES + 1 ))"
  ) || {
    local -i capture_status=$?
    (( capture_status == 130 || capture_status == 143 )) && return "$capture_status"
    return 1
  }
  (( ${#captured} <= _VPN_MAX_PREVIEW_BYTES )) || return 1
  print -r -- "$captured"
}

# Live tunnel state from the most recent _vpn_active_interfaces in this shell:
# the device behind each active profile, the identity of the wg-quick runtime
# record that paired them on macOS, and devices no profile owns.
typeset -gA _VPN_ACTIVE_DEVICES=()
typeset -gA _VPN_ACTIVE_NAME_IDS=()
typeset -ga _VPN_UNMANAGED_DEVICES=()

# Sets `reply` to the active profiles and _VPN_ACTIVE_DEVICES to their devices.
# Linux and WSL name each device after its profile; macOS pairs utun devices
# with profiles through the wg-quick runtime directory. Returns 1 when the live
# state cannot be read at all, which is different from "no tunnel is up", 4 on
# macOS when an ambiguous pairing needs sudo, and preserves 130 and 143 so
# callers stop before a subsequent mutation.
_vpn_active_interfaces() {
  reply=()
  _VPN_ACTIVE_DEVICES=()
  _VPN_ACTIVE_NAME_IDS=()
  _VPN_UNMANAGED_DEVICES=()
  local raw
  local -i probe_rc=0
  raw=$(_vpn_get_active_interfaces 2>/dev/null) || probe_rc=$?
  if (( probe_rc != 0 )); then
    (( probe_rc == 130 || probe_rc == 143 )) && return "$probe_rc"
    return 1
  fi

  local -A seen=()
  local -a live=()
  local iface
  for iface in ${=raw}; do
    _vpn_validate_iface_name "$iface" || return 1
    [[ -n "${seen[$iface]-}" ]] && continue
    seen[$iface]=1
    live+=("$iface")
    (( ${#live[@]} <= _VPN_MAX_ACTIVE_INTERFACES )) || return 1
  done

  if _vpn_platform_is darwin; then
    _vpn_darwin_map_tunnels "${live[@]}"
    return
  fi
  reply=("${live[@]}")
  for iface in "${live[@]}"; do
    _VPN_ACTIVE_DEVICES[$iface]="$iface"
  done
  return 0
}

# REPLY: the live device of an active profile. Linux and WSL name the device
# after the profile; macOS uses the pairing from the last live-state query.
_vpn_tunnel_device() {
  local iface="${1:-}"
  REPLY=""
  _vpn_validate_iface_name "$iface" || return 1
  if _vpn_platform_is darwin; then
    REPLY="${_VPN_ACTIVE_DEVICES[$iface]-}"
    [[ -n "$REPLY" ]]
    return
  fi
  REPLY="$iface"
}

_vpn_get_iface_details() {
  local iface="${1:-}" REPLY=""
  _vpn_tunnel_device "$iface" || return 1
  _vpn_run_wg show "$REPLY"
}

# stdout: one profile name per line.
_vpn_get_configs() {
  local dir
  dir=$(_vpn_config_dir_resolve) || return 1

  [[ -d "$dir" ]] || return 0

  local candidate name state
  local -i count=0
  if [[ -r "$dir" && -x "$dir" ]]; then
    local -a files=("$dir"/*.conf(N.on))
    for candidate in "${files[@]}"; do
      name="${${candidate:t}%.conf}"
      _vpn_validate_iface_name "$name" || continue
      state=$(_vpn_profile_path_state "$candidate")
      [[ "$state" == "safe" ]] || continue
      (( ++count <= _VPN_MAX_PROFILES )) || {
        _vpn_error \
          "Profile inventory exceeds the safety limit ($_VPN_MAX_PROFILES)."
        return 1
      }
      print -r -- "$name"
    done
    return 0
  fi

  _vpn_have_sudo_cache || return 1

  local listing
  listing=$(_vpn_sudo_probe find "$dir" -maxdepth 1 -type f -name '*.conf' \
    -print) || return 1

  local -a names=()
  for candidate in "${(@f)listing}"; do
    [[ -n "$candidate" ]] || continue
    name="${${candidate:t}%.conf}"
    _vpn_validate_iface_name "$name" || continue
    state=$(_vpn_profile_path_state "$candidate")
    [[ "$state" == "safe" ]] || continue
    (( ++count <= _VPN_MAX_PROFILES )) || {
      _vpn_error \
        "Profile inventory exceeds the safety limit ($_VPN_MAX_PROFILES)."
      return 1
    }
    names+=("$name")
  done
  # An empty but readable inventory is a successful result, not a failure.
  (( ${#names[@]} > 0 )) && print -rl -- "${(on)names[@]}"
  return 0
}

_vpn_config_exists() {
  local iface="${1:-}"
  local conf_file
  conf_file=$(_vpn_conf_path "$iface") || return 1

  local path_state=""
  path_state=$(_vpn_profile_path_state "$conf_file") || return $?
  [[ "$path_state" == "safe" ]]
}

_vpn_backup_state() {
  local iface="${1:-}"
  local bak_file
  bak_file=$(_vpn_backup_path "$iface") || {
    print -r -- "missing"
    return 1
  }

  local path_state
  path_state=$(_vpn_profile_path_state "$bak_file")
  case "$path_state" in
    safe) print -r -- "available"; return 0 ;;
    unsafe) print -r -- "unsafe"; return 0 ;;
    locked) print -r -- "unknown"; return 0 ;;
  esac

  local dir
  dir=$(_vpn_config_dir)
  if [[ -r "$dir" && -x "$dir" ]]; then
    print -r -- "missing"
    return 0
  fi

  if _vpn_have_sudo_cache; then
    path_state=$(_vpn_profile_path_state "$bak_file")
    [[ "$path_state" == "safe" ]] \
      && print -r -- "available" \
      || print -r -- "${path_state/locked/unknown}"
    return 0
  fi

  print -r -- "unknown"
}

# Reports a profile's .conf.pre-restore undo copy. The undo file never enters
# the *.conf inventory, so this state is its only visibility surface.
_vpn_pre_restore_state() {
  local iface="${1:-}"
  local conf_file undo_file
  conf_file=$(_vpn_conf_path "$iface") || {
    print -r -- "none"
    return 1
  }
  undo_file="${conf_file}.pre-restore"

  local path_state
  path_state=$(_vpn_profile_path_state "$undo_file")
  case "$path_state" in
    safe) print -r -- "kept"; return 0 ;;
    unsafe) print -r -- "unsafe"; return 0 ;;
    locked) print -r -- "unknown"; return 0 ;;
  esac

  local dir
  dir=$(_vpn_config_dir)
  if [[ -r "$dir" && -x "$dir" ]]; then
    print -r -- "none"
    return 0
  fi

  if _vpn_have_sudo_cache; then
    path_state=$(_vpn_profile_path_state "$undo_file")
    case "$path_state" in
      safe) print -r -- "kept" ;;
      unsafe) print -r -- "unsafe" ;;
      locked) print -r -- "unknown" ;;
      *) print -r -- "none" ;;
    esac
    return 0
  fi

  print -r -- "unknown"
}

# Secrets are removed before any excerpt reaches the terminal, a preview, or a
# report. The line cap bounds output from an arbitrarily large file.
_vpn_redact_stream() {
  command head -c "$_VPN_MAX_PREVIEW_BYTES" \
    | command awk '
      NR > 35 { exit }
      {
        # wireguard-tools removes all whitespace before matching keys, so
        # "Private Key = ..." is still a secret.
        lowered = tolower($0)
        gsub(/[[:space:]]/, "", lowered)
        if (lowered !~ /^(privatekey|presharedkey)=/) {
          print
        }
      }'
}

_vpn_redacted_config_excerpt() {
  local iface="${1:-}"
  local conf_file
  conf_file=$(_vpn_conf_path "$iface") || return 1

  if [[ -r "$conf_file" ]]; then
    _vpn_redact_stream < "$conf_file"
    return 0
  fi

  _vpn_sudo_probe cat -- "$conf_file" | _vpn_redact_stream
}

_vpn_redacted_backup_excerpt() {
  local iface="${1:-}"
  local bak_file
  bak_file=$(_vpn_backup_path "$iface") || return 1

  if [[ -r "$bak_file" ]]; then
    _vpn_redact_stream < "$bak_file"
    return 0
  fi

  _vpn_sudo_probe cat -- "$bak_file" | _vpn_redact_stream
}

_vpn_dns_from_conf() {
  local iface="${1:-}"
  local conf_file
  conf_file=$(_vpn_conf_path "$iface") || return 1

  if [[ -r "$conf_file" ]]; then
    command head -c "$_VPN_MAX_PROFILE_BYTES" -- "$conf_file" 2>/dev/null \
      | command sed -n 's/^[[:space:]]*DNS[[:space:]]*=[[:space:]]*//p' \
      | command head -1
    return 0
  fi

  _vpn_sudo_probe head -c "$_VPN_MAX_PROFILE_BYTES" -- "$conf_file" \
    | command sed -n 's/^[[:space:]]*DNS[[:space:]]*=[[:space:]]*//p' \
    | command head -1
}

# --- Tunnel metrics ---------------------------------------------------------

# Collectors take a profile name and read its live device. Linux and WSL use
# iproute2 and /etc/resolv.conf; macOS uses ifconfig, route, and scutil
# (vpn/vpn-darwin.zsh). The branch is chosen at call time.
_vpn_iface_internal_addrs() {
  local iface="${1:-}" REPLY=""
  _vpn_tunnel_device "$iface" || return 1
  if _vpn_platform_is darwin; then
    _vpn_darwin_iface_addrs "$REPLY"
    return
  fi
  command -v ip &>/dev/null || return 1
  command ip -o addr show dev "$REPLY" 2>/dev/null | command awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "inet" || $i == "inet6") {
          print $(i + 1)
        }
      }
    }'
}

_vpn_iface_endpoint() {
  local iface="${1:-}" REPLY=""
  _vpn_tunnel_device "$iface" || return 1
  _vpn_run_wg show "$REPLY" endpoints 2>/dev/null \
    | command awk 'NF >= 2 && $2 != "(none)" { print $2; exit }'
}

_vpn_iface_latest_handshake() {
  local iface="${1:-}" REPLY=""
  _vpn_tunnel_device "$iface" || return 1
  _vpn_run_wg show "$REPLY" latest-handshakes 2>/dev/null \
    | command awk '{ if ($2 + 0 > max) max = $2 + 0 } END { print max + 0 }'
}

_vpn_iface_transfer() {
  local iface="${1:-}" REPLY=""
  _vpn_tunnel_device "$iface" || return 1
  _vpn_run_wg show "$REPLY" transfer 2>/dev/null \
    | command awk '{ rx += $2; tx += $3 } END { printf "%d\t%d\n", rx + 0, tx + 0 }'
}

_vpn_default_route() {
  if _vpn_platform_is darwin; then
    _vpn_darwin_route_summary 1.1.1.1
    return
  fi
  command -v ip &>/dev/null || return 1
  command ip route get 1.1.1.1 2>/dev/null | command head -1
}

# stdout: one system resolver address per line.
_vpn_dns_resolvers() {
  if _vpn_platform_is darwin; then
    _vpn_darwin_dns_resolvers
    return
  fi
  [[ -r /etc/resolv.conf ]] || return 1
  command awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null
}

# stdout: where the system resolvers come from, for reports and hints.
_vpn_dns_source_label() {
  if _vpn_platform_is darwin; then
    print -r -- "scutil --dns"
  else
    print -r -- "/etc/resolv.conf"
  fi
}

# --- Human formatting -------------------------------------------------------

_vpn_human_bytes() {
  local bytes=${1:-0}
  local -F result
  if (( bytes < 1024 )); then
    printf "%d B" "$bytes"
  elif (( bytes < 1048576 )); then
    result=$(( bytes / 1024.0 ))
    printf "%.1f KiB" "$result"
  elif (( bytes < 1073741824 )); then
    result=$(( bytes / 1048576.0 ))
    printf "%.1f MiB" "$result"
  else
    result=$(( bytes / 1073741824.0 ))
    printf "%.2f GiB" "$result"
  fi
}

_vpn_human_age() {
  local ts=${1:-0}
  local now age
  now=$(command date +%s 2>/dev/null) || {
    print -r -- "(unknown)"
    return 0
  }
  if (( ts == 0 )); then
    print -r -- "(never)"
    return 0
  fi
  age=$(( now - ts ))
  if (( age < 0 )); then
    print -r -- "(clock skew?)"
  elif (( age < 60 )); then
    printf "%ds ago" "$age"
  elif (( age < 3600 )); then
    printf "%dm %ds ago" "$(( age / 60 ))" "$(( age % 60 ))"
  elif (( age < 86400 )); then
    printf "%dh %dm ago" "$(( age / 3600 ))" "$(( (age % 3600) / 60 ))"
  else
    printf "%dd ago" "$(( age / 86400 ))"
  fi
}

# --- Menu record helpers ----------------------------------------------------
# The dev and sys suites use `label|command|description`. This suite documents a
# fourth field because several actions target one specific profile. Carrying the
# target as its own opaque field, instead of encoding it into the command token,
# is what lets the dispatcher revalidate it before a mutation.
#
#   label|command|description|target
#
# `target` is empty for actions that pick their own target.

_vpn_menu_validate_fields() {
  local field
  for field in "$@"; do
    if [[ "$field" == *'|'* || "$field" == *$'\n'* \
      || "$field" == *$'\r'* || "$field" == *$'\0'* ]]; then
      _vpn_error \
        "Invalid menu field: delimiters and control characters are not allowed."
      return 2
    fi
  done
}

_vpn_menu_section() {
  (( $# >= 1 && $# <= 2 )) || {
    _vpn_error "A menu section requires a title and optional description."
    return 2
  }

  local title="${1:-}"
  local description="${2:-}"
  [[ -n "$title" ]] || {
    _vpn_error "A menu section title cannot be empty."
    return 2
  }
  _vpn_menu_validate_fields "$title" "$description" || return $?

  printf "── %s ──|:|%s|\n" "$title" "$description"
}

_vpn_menu_entry() {
  (( $# >= 3 && $# <= 4 )) || {
    _vpn_error \
      "A menu entry requires label, command, description, and optional target."
    return 2
  }

  local label="${1:-}"
  local command_name="${2:-}"
  local description="${3:-}"
  local target="${4:-}"

  if [[ -z "$label" || -z "$command_name" || -z "$description" ]]; then
    _vpn_error "Menu entry label, command, and description cannot be empty."
    return 2
  fi
  _vpn_menu_validate_fields "$label" "$command_name" "$description" "$target" \
    || return $?

  if [[ -n "$target" ]] && ! _vpn_validate_iface_name "$target"; then
    _vpn_error "Invalid menu entry target: $target"
    return 2
  fi

  printf "  %s|%s|%s|%s\n" "$label" "$command_name" "$description" "$target"
}

# --- fzf preset for the vpn suite -------------------------------------------
# Options are constructed at invocation time so a standalone source never
# evaluates the core theme helper and configuration stays live.

_vpn_fzf() {
  local -a options=(
    --height=80%
    --layout=reverse
    --border=rounded
    --delimiter='[|]'
    --with-nth=1
    --pointer='▶'
  )

  options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow')

  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && options+=("$theme_option")
  fi

  # Compatibility settings are local to this picker and never change the shell.
  local -a terminal_options=()
  local terminal_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
  if [[ -n "${ZDX_FZF_PLAIN:-}" || "$terminal_locale" == C \
    || "$terminal_locale" == POSIX || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-unicode '--pointer=>' '--marker=+')
  fi
  if [[ -n "${NO_COLOR:-}" || -n "${ZDX_FZF_PLAIN:-}" \
    || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-color)
  fi

  # fzf with templates hides the delimiter that trails a single shown field.
  local REPLY=""
  if typeset -f _tk_fzf_nth_template_option &>/dev/null \
    && _tk_fzf_nth_template_option "${options[@]}" "$@"; then
    terminal_options+=("$REPLY")
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh fzf "${options[@]}" "$@" "${terminal_options[@]}"
}

# Single-column picker for profile and interface selection. It shares the suite
# theme instead of building a bare fzf call per call site.
_vpn_pick_from_list() {
  local prompt="$1"
  shift
  local -a items=("$@")

  (( ${#items[@]} > 0 )) || return 1
  _vpn_check_cmd fzf || {
    _vpn_error "fzf is required for interactive selection."
    return 1
  }

  local selected
  local -i fzf_status=0
  selected=$(printf "%s\n" "${items[@]}" | _vpn_fzf \
    --height=40% \
    --prompt="${prompt} > " \
    --header='Up/Down navigate | Enter select | Esc cancel') || fzf_status=$?

  if (( fzf_status != 0 )); then
    (( fzf_status == 1 || fzf_status == 130 )) && return 3
    return 1
  fi

  [[ -n "$selected" ]] || return 3
  print -r -- "$selected"
}

# Resolves the profile a command should act on. Returns 3 when the user
# cancels, so callers can treat cancellation as success without mutating,
# and preserves 130/143 when authentication is interrupted.
_vpn_pick_profile() {
  local prompt="${1:-Select VPN profile}"

  _vpn_ensure_profile_access || return $?

  local configs_raw
  configs_raw=$(_vpn_get_configs 2>/dev/null) || return 1

  local -a configs=()
  [[ -n "$configs_raw" ]] && configs=("${(@f)configs_raw}")
  configs=("${(@)configs:#}")

  if (( ${#configs[@]} == 0 )); then
    _vpn_info "No VPN profiles found in $(_vpn_config_dir)."
    return 1
  fi

  if (( ${#configs[@]} == 1 )); then
    print -r -- "${configs[1]}"
    return 0
  fi

  local picked
  picked=$(_vpn_pick_from_list "$prompt" "${configs[@]}") || return $?
  _vpn_sanitize_iface_capture "$picked"
}

# --- WSL hardening validation -----------------------------------------------

# A DNS value read from a profile is written into a root-executed PostUp hook.
# It is therefore validated as a strict comma-separated list of IP literals: a
# value carrying shell metacharacters is rejected, not escaped.
_vpn_validate_ip_literal() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local address="${1:-}"
  [[ -n "$address" ]] || return 1

  if [[ "$address" =~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' ]]; then
    local -a octets=("${(@s:.:)address}")
    (( ${#octets[@]} == 4 )) || return 1
    local octet
    for octet in "${octets[@]}"; do
      [[ "$octet" == <-> ]] || return 1
      (( 10#$octet <= 255 )) || return 1
    done
    return 0
  fi

  [[ "$address" =~ '^[0-9A-Fa-f:]{2,45}$' ]] || return 1
  [[ "$address" == *:* && "$address" != *:::* ]] || return 1

  local compressed=0 left="$address" right=""
  if [[ "$address" == *::* ]]; then
    compressed=1
    left="${address%%::*}"
    right="${address#*::}"
    [[ "$right" != *::* ]] || return 1
  else
    [[ "$address" != :* && "$address" != *: ]] || return 1
  fi

  local -a groups=()
  [[ -n "$left" ]] && groups+=("${(@s.:.)left}")
  [[ -n "$right" ]] && groups+=("${(@s.:.)right}")
  local group
  for group in "${groups[@]}"; do
    [[ "$group" =~ '^[0-9A-Fa-f]{1,4}$' ]] || return 1
  done
  if (( compressed )); then
    (( ${#groups[@]} < 8 )) || return 1
  else
    (( ${#groups[@]} == 8 )) || return 1
  fi
  return 0
}

_vpn_validate_dns_list() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local raw="${1:-}"
  [[ -n "$raw" ]] || return 1
  (( ${#raw} <= 256 )) || return 1

  local -a entries=("${(@s:,:)raw}")
  (( ${#entries[@]} > 0 && ${#entries[@]} <= 8 )) || return 1

  local entry
  for entry in "${entries[@]}"; do
    entry="${entry##[[:space:]]##}"
    entry="${entry%%[[:space:]]##}"
    _vpn_validate_ip_literal "$entry" || return 1
  done
  return 0
}

# Validates an HTTPS provider URL before curl sees it. Provider overrides are
# data, never additional curl options or local-file schemes.
_vpn_validate_provider_url() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local url="${1:-}"
  [[ ${#url} -le 2048 && "$url" == https://* ]] || return 1
  if [[ "$url" == *$'\n'* || "$url" == *$'\r'* || "$url" == *$'\0'* \
    || "$url" == *[[:space:]]* ]]; then
    return 1
  fi

  local rest="${url#https://}"
  local authority="${rest%%[/?\\#]*}"
  [[ -n "$authority" && ${#authority} -le 320 \
    && "$authority" != *'@'* ]] || return 1

  local host="$authority"
  local port=""
  if [[ "$authority" == \[* ]]; then
    [[ "$authority" == *\] || "$authority" == *\]:<-> ]] || return 1
    host="${authority#\[}"
    host="${host%%\]*}"
    local suffix="${authority#*\]}"
    [[ -z "$suffix" || "$suffix" == :<-> ]] || return 1
    [[ -z "$suffix" ]] || port="${suffix#:}"
    _vpn_validate_ip_literal "$host" || return 1
  else
    if [[ "$authority" == *:* ]]; then
      [[ "$authority" != *:*:* ]] || return 1
      host="${authority%:*}"
      port="${authority##*:}"
    fi

    [[ -n "$host" && ${#host} -le 253 \
      && "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    local -a labels=("${(@s:.:)host}")
    local label
    for label in "${labels[@]}"; do
      (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
      [[ "$label" =~ \
        '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' ]] || return 1
    done
  fi

  if [[ -n "$port" ]]; then
    [[ "$port" == <-> ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  fi
  return 0
}

# stdout: the first DNS entry, normalized, when the whole list is safe.
_vpn_first_dns_entry() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local raw="${1:-}"
  _vpn_validate_dns_list "$raw" || return 1

  local first="${raw%%,*}"
  first="${first##[[:space:]]##}"
  first="${first%%[[:space:]]##}"
  [[ -n "$first" ]] || return 1
  print -r -- "$first"
}

# --- Dispatch (case-based; arms ARE the allowlist) --------------------------

_vpn_dispatch_prepare() {
  # Public functions own parsing and perform their capability probes only
  # after syntax is known to be valid. Keeping this hook as a no-op preserves
  # one explicit dispatch shape without reintroducing parser-before-probe bugs.
  (( $# >= 1 )) || return 2
  return 0
}

_vpn_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    # --- Access -------------------------------------------------------------
    vpn-access-unlock)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-access-unlock "$@" ;;
    vpn-access-lock)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-access-lock "$@" ;;
    vpn-access-status)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-access-status "$@" ;;

    # --- Connection control -------------------------------------------------
    vpn-on)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-on "$@" ;;
    vpn-off)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-off "$@" ;;
    vpn-off-all)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-off-all "$@" ;;
    vpn-reconnect-last)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-reconnect-last "$@" ;;
    vpn-default-connect)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-default-connect "$@" ;;
    vpn-default-set)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-default-set "$@" ;;
    vpn-default-clear)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-default-clear "$@" ;;

    # --- Diagnostics --------------------------------------------------------
    vpn-summary)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-summary "$@" ;;
    vpn-details)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-details "$@" ;;
    vpn-ip-info)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-ip-info "$@" ;;
    vpn-mtu-probe)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-mtu-probe "$@" ;;
    vpn-report)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-report "$@" ;;

    # --- Profile management -------------------------------------------------
    vpn-profile-create)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-profile-create "$@" ;;
    vpn-profile-import)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-profile-import "$@" ;;
    vpn-profile-rename)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-profile-rename "$@" ;;
    vpn-config-edit)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-config-edit "$@" ;;
    vpn-config-dir)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-config-dir "$@" ;;

    # --- Destructive maintenance --------------------------------------------
    vpn-config-restore)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-config-restore "$@" ;;
    vpn-profile-remove)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-profile-remove "$@" ;;

    :) return 0 ;;
    *)
      _vpn_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

typeset -g _VPN_COMMON_SOURCED=1
