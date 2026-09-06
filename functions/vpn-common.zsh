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

# WireGuard profile directory. The default targets Linux and WSL; other hosts
# must point this at their own installation prefix.
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

_vpn_header() {
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
# control character in external data is displayed, never interpreted.
_vpn_label() {
  if _vpn_color_enabled; then
    printf '  \033[1m%-18s\033[0m %s\n' "${(V)1}:" "${(V)2}" >&2
  else
    printf '  %-18s %s\n' "${(V)1}:" "${(V)2}" >&2
  fi
}

_vpn_blank() { print -u2 -r -- ""; }

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
_vpn_read_line() {
  local prompt="$1"
  local default_value="${2:-}"
  [[ -t 0 && -t 2 ]] || return 1

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
    _vpn_info "Install the wireguard-tools package for this host."
    return 1
  fi
  return 0
}

_vpn_check_wg() {
  if ! _vpn_check_cmd wg; then
    _vpn_error "WireGuard (wg) is not installed."
    _vpn_info "Install the wireguard-tools package for this host."
    return 1
  fi
  return 0
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

_vpn_check_deps() {
  _vpn_check_wg_quick || return 1
  _vpn_check_ip_stack || return 1
}

# --- Platform contract ------------------------------------------------------
# Support is command-specific and capability based. The suite targets Linux and
# WSL: it depends on /etc/wireguard conventions, iproute2, and Linux file
# attributes. Other hosts must opt in by pointing VPN_CONFIG_DIR at their own
# WireGuard directory.

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

_vpn_is_wsl() {
  [[ -n "${WSL_DISTRO_NAME-}" ]] && return 0
  command grep -qi microsoft /proc/version 2>/dev/null
}

# True when VPN_CONFIG_DIR still holds the Linux default, meaning the user has
# not told the suite where WireGuard lives on this host.
_vpn_config_dir_is_default() {
  [[ "$VPN_CONFIG_DIR" == "/etc/wireguard" ]]
}

# Gate for every command that reads or writes the profile directory. An
# unsupported host returns promptly and clearly instead of emitting a cascade
# of command-not-found and permission errors.
_vpn_require_platform() {
  local platform
  platform=$(_vpn_platform)

  case "$platform" in
    linux|wsl) ;;
    *)
      if _vpn_config_dir_is_default; then
        _vpn_error "The VPN suite targets Linux and WSL."
        _vpn_info \
          "Set VPN_CONFIG_DIR to the WireGuard directory for this host to continue."
        _vpn_dim "For example: VPN_CONFIG_DIR=/opt/homebrew/etc/wireguard"
        return 1
      fi
      ;;
  esac

  _vpn_config_dir_resolve >/dev/null
}

# --- Profile directory and identifiers --------------------------------------

_vpn_config_dir() {
  local dir="${VPN_CONFIG_DIR:-}"
  while [[ "$dir" != "/" && "$dir" == */ ]]; do
    dir="${dir%/}"
  done
  print -r -- "$dir"
}

# stdout: the literal, normalized profile directory after rejecting traversal,
# protected roots, control characters, and every symlink component.
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
  local resolved="${configured:A}"
  local home_root="${HOME:A}"
  if [[ -z "$literal" || "$literal" == "/" || "$literal" == "$home_root" ]]; then
    _vpn_error "Refusing a protected VPN_CONFIG_DIR: ${literal:-<empty>}"
    return 1
  fi
  if [[ "$literal" != "$resolved" ]]; then
    _vpn_error "Refusing a VPN_CONFIG_DIR with symlink components: $literal"
    return 1
  fi

  print -r -- "$literal"
}

# An interface name becomes a filename, a `wg-quick` argument, and a network
# device name. Requiring a leading alphanumeric is what keeps a name from being
# parsed as an option by any of them.
_vpn_validate_iface_name() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 1
  (( ${#iface} <= 64 )) || return 1
  [[ "$iface" == [A-Za-z0-9]* ]] || return 1
  [[ "$iface" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]]
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

  zmodload zsh/stat 2>/dev/null || {
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

  zmodload zsh/stat 2>/dev/null || {
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

  local matched=""
  matched=$(_vpn_sudo_probe find "$literal" -prune -type f -links 1 \
    \( -uid 0 -o -uid "$EUID" \) ! -perm /077 \
    -size "-$(( _VPN_MAX_PROFILE_BYTES + 1 ))c" -print) || {
    local -i probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    matched=""
  }
  if [[ "$matched" == "$literal" ]]; then
    print -r -- "safe"
  elif _vpn_profile_probe_exists "$literal"; then
    print -r -- "unsafe"
  else
    local -i probe_status=$?
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

  zmodload zsh/stat 2>/dev/null || return 1
  local -A before=() after=()
  local checksum=""
  if zstat -H before -- "$target_path" 2>/dev/null; then
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
  local before_id after_id
  before_id=$(_vpn_sudo_probe find "$target_path" -prune -type f -links 1 \
    -printf '%D:%i:%U:%m:%n:%s:%T@:%C@\n') || {
    probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    return 1
  }
  checksum=$(_vpn_sudo_probe cksum -- "$target_path") || {
    probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    return 1
  }
  after_id=$(_vpn_sudo_probe find "$target_path" -prune -type f -links 1 \
    -printf '%D:%i:%U:%m:%n:%s:%T@:%C@\n') || {
    probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    return 1
  }
  [[ -n "$before_id" && "$before_id" == "$after_id" ]] || {
    _vpn_error "$label changed while it was inspected."
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

  zmodload zsh/stat 2>/dev/null || return 1
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
  zmodload zsh/stat 2>/dev/null || return 1
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

# Shared temporary roots must either be owned privately by this user or be a
# root-owned sticky directory such as /tmp. Some containers expose a foreign-
# owned /tmp; in that case prefer the standard per-user runtime directory
# instead of weakening the ownership rule.
_vpn_temp_root_candidate() {
  local configured="${1:-}"
  [[ -n "$configured" && "$configured" == /* ]] || return 1

  local literal="${configured:a}"
  local resolved="${configured:A}"
  [[ "$literal" == "$resolved" && -d "$literal" && ! -L "$literal" \
    && -w "$literal" && -x "$literal" ]] || return 1

  zmodload zsh/stat 2>/dev/null || return 1
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
  command chmod 700 -- "$created" 2>/dev/null || {
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

_vpn_have_sudo_cache() {
  command -v sudo &>/dev/null && command sudo -n true &>/dev/null
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
  _vpn_have_sudo_cache || {
    local -i cache_status=$?
    (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
    return 1
  }
  command sudo -n -- "$@"
}

# Read-only privileged probe. Failure is expected and silent: callers fall back
# to reporting an unknown state rather than escalating.
_vpn_sudo_probe() {
  (( $# > 0 )) || return 2
  _vpn_have_sudo_cache || {
    local -i cache_status=$?
    (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
    return 1
  }
  command sudo -n -- "$@" 2>/dev/null
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
    _vpn_sudo_exec install -m 600 -o root -g root -- \
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

  if [[ -r "$dir" && -x "$dir" ]]; then
    print -r -- "direct"
    return 0
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

      _vpn_announce_privileged "install -d -m 700 -- $dir"
      _vpn_ensure_sudo_access "Creating the VPN profile directory" || return 1
      if _vpn_sudo_exec install -d -m 700 -- "$dir"; then
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

_vpn_get_iface_details() {
  local iface="${1:-}"
  _vpn_validate_iface_name "$iface" || return 1
  _vpn_run_wg show "$iface"
}

_vpn_is_active() {
  local iface="${1:-}"
  if [[ -n "$iface" ]]; then
    _vpn_get_iface_details "$iface" &>/dev/null
  else
    local active
    active=$(_vpn_get_active_interfaces 2>/dev/null) || return 1
    [[ -n "$active" ]]
  fi
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
  (( ${#names[@]} > 0 )) && print -rl -- "${(on)names[@]}"
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

_vpn_backup_exists() {
  [[ "$(_vpn_backup_state "$1")" == "available" ]]
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
        lowered = tolower($0)
        if (lowered !~ /^[[:space:]]*(privatekey|presharedkey)[[:space:]]*=/) {
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

_vpn_iface_internal_addrs() {
  local iface="${1:-}"
  _vpn_validate_iface_name "$iface" || return 1
  command -v ip &>/dev/null || return 1
  command ip -o addr show dev "$iface" 2>/dev/null | command awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "inet" || $i == "inet6") {
          print $(i + 1)
        }
      }
    }'
}

_vpn_iface_endpoint() {
  local iface="${1:-}"
  _vpn_validate_iface_name "$iface" || return 1
  _vpn_run_wg show "$iface" endpoints 2>/dev/null \
    | command awk 'NF >= 2 && $2 != "(none)" { print $2; exit }'
}

_vpn_iface_latest_handshake() {
  local iface="${1:-}"
  _vpn_validate_iface_name "$iface" || return 1
  _vpn_run_wg show "$iface" latest-handshakes 2>/dev/null \
    | command awk '{ if ($2 + 0 > max) max = $2 + 0 } END { print max + 0 }'
}

_vpn_iface_transfer() {
  local iface="${1:-}"
  _vpn_validate_iface_name "$iface" || return 1
  _vpn_run_wg show "$iface" transfer 2>/dev/null \
    | command awk '{ rx += $2; tx += $3 } END { printf "%d\t%d\n", rx + 0, tx + 0 }'
}

_vpn_default_route() {
  command -v ip &>/dev/null || return 1
  command ip route get 1.1.1.1 2>/dev/null | command head -1
}

_vpn_dns_resolvers() {
  [[ -r /etc/resolv.conf ]] || return 1
  command awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null
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

  options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')

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
    (( fzf_status == 1 || fzf_status == 130 )) && return 130
    return 1
  fi

  [[ -n "$selected" ]] || return 130
  print -r -- "$selected"
}

# Resolves the profile a command should act on. Returns 130 when the user
# cancels, so callers can treat cancellation as success without mutating.
_vpn_pick_profile() {
  local prompt="${1:-Select VPN profile}"

  _vpn_ensure_profile_access || return 1

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
    vpn-refresh)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-refresh "$@" ;;
    vpn-summary)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-summary "$@" ;;
    vpn-details)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-details "$@" ;;
    vpn-ip-info)
      _vpn_dispatch_prepare "$command_name" "$@" && vpn-ip-info "$@" ;;
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

    # --- Deprecated compatibility tokens ------------------------------------
    # Not part of the menu, help, or completion surfaces. Scheduled for removal
    # in v0.3.0.
    # vpn-off with no argument already picks among the active tunnels, so
    # vpn-disconnect-active was a second implementation of the same action.
    vpn-disconnect-active)
      _vpn_deprecated_alias vpn-disconnect-active vpn-off
      _vpn_dispatch vpn-off "$@"
      ;;
    vpn-status)
      _vpn_deprecated_alias vpn-status vpn-details
      _vpn_dispatch vpn-details "$@" && _vpn_dispatch vpn-ip-info
      ;;
    vpn-public-ip)
      _vpn_deprecated_alias vpn-public-ip vpn-ip-info
      _vpn_dispatch vpn-ip-info "$@"
      ;;

    :) return 0 ;;
    *)
      _vpn_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

# Emits a single deprecation notice per shell session per alias.
typeset -gA _VPN_DEPRECATION_SEEN=()

_vpn_deprecated_alias() {
  local old_name="$1"
  local new_name="$2"

  if [[ -z "${_VPN_DEPRECATION_SEEN[$old_name]:-}" ]]; then
    _VPN_DEPRECATION_SEEN[$old_name]=1
    _vpn_warn "'$old_name' is deprecated; use '$new_name' instead."
  fi
  return 0
}

typeset -g _VPN_COMMON_SOURCED=1
