#!/usr/bin/env zsh
# =============================================================================
# AI Common: shared helpers for the AI suite
# =============================================================================
#
# Loaded by ai-menu.zsh before every module under functions/ai/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_AI_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Logging primitives (suite-owned) ---------------------------------------

_ai_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

_ai_header() {
  if _ai_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}

_ai_log_line() {
  local level="$1" color="$2" marker="$3" message="$4"
  if _ai_color_enabled; then
    printf '\033[%sm%s %s\033[0m\n' "$color" "$marker" "${(V)message}" >&2
  else
    printf '%s %s\n' "$marker" "${(V)message}" >&2
  fi
}

_ai_success() { _ai_log_line success '1;32' '✔' "$1"; }
_ai_warn()    { _ai_log_line warn '1;33' '⚠' "$1"; }
_ai_info()    { _ai_log_line info '0;36' '➜' "$1"; }
_ai_error()   { _ai_log_line error '1;31' '✘' "$1"; }
_ai_dim() {
  if _ai_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
}
_ai_label() { printf '  %-18s %s\n' "${(V)1}" "${(V)2}" >&2; }

# --- Flag State --------------------------------------------------------------
# Parsed once per entry-point function, inherited by sub-calls.
# Entry points: global-clean-ai, project-sweep-ai, ai-update, ai-doctor, etc.
# Internal helpers read these but never reset them.

typeset -g _AI_DRY_RUN=0
typeset -g _AI_YES=0
typeset -g _AI_VERBOSE=0
typeset -g _AI_SWEEP_ROOT="$HOME"
typeset -g _AI_SWEEP_DEPTH=5
typeset -g _AI_SWEEP_XDEV=0
typeset -g _AI_REPORT=0
typeset -g _AI_JSON=0
typeset -g _AI_HELP_ONLY=0

_ai_parse_flags() {
  local profile="${1:-}"
  local command_name="${2:-}"
  shift 2 2>/dev/null || {
    _ai_error "An internal flag profile is required."
    return 2
  }
  case "$profile" in
    clean|sweep|config-backup|config-restore|doctor|disk|versions) ;;
    *)
      _ai_error "Unknown internal flag profile: $profile"
      return 2
      ;;
  esac

  _AI_DRY_RUN=0; _AI_YES=0; _AI_VERBOSE=0
  _AI_SWEEP_ROOT="$HOME"; _AI_SWEEP_DEPTH=5; _AI_SWEEP_XDEV=0
  _AI_REPORT=0; _AI_JSON=0; _AI_HELP_ONLY=0

  while (( $# )); do
    case "$1" in
      --dry-run)
        [[ "$profile" == clean || "$profile" == sweep \
          || "$profile" == config-backup || "$profile" == config-restore ]] \
          || {
          _ai_error "Option not supported by $profile: $1"
          return 2
        }
        _AI_DRY_RUN=1
        ;;
      --yes|-y)
        [[ "$profile" == clean || "$profile" == sweep \
          || "$profile" == config-backup || "$profile" == config-restore ]] \
          || {
          _ai_error "Option not supported by $profile: $1"
          return 2
        }
        _AI_YES=1
        ;;
      --verbose|-v)
        _AI_VERBOSE=1
        ;;
      --report)
        [[ "$profile" == doctor ]] || {
          _ai_error "Option not supported by $profile: $1"
          return 2
        }
        _AI_REPORT=1
        ;;
      --json)
        [[ "$profile" == versions ]] || {
          _ai_error "Option not supported by $profile: $1"
          return 2
        }
        _AI_JSON=1
        ;;
      --xdev)
        [[ "$profile" == sweep ]] || {
          _ai_error "Option not supported by $profile: $1"
          return 2
        }
        _AI_SWEEP_XDEV=1
        ;;
      --root)
        [[ "$profile" == sweep ]] || {
          _ai_error "Option not supported by $profile: $1"
          return 2
        }
        (( $# >= 2 )) && [[ -n "$2" ]] || {
          _ai_error "--root requires a path."
          return 2
        }
        _AI_SWEEP_ROOT="$2"
        shift
        ;;
      --depth)
        [[ "$profile" == sweep ]] || {
          _ai_error "Option not supported by $profile: $1"
          return 2
        }
        (( $# >= 2 )) && [[ "$2" =~ '^[1-9][0-9]*$' ]] || {
          _ai_error "--depth requires an integer from 1 to 8."
          return 2
        }
        (( $2 <= 8 )) || {
          _ai_error "--depth must not exceed 8."
          return 2
        }
        _AI_SWEEP_DEPTH="$2"
        shift
        ;;
      --help|-h)
        _ai_usage_common "$profile" "$command_name"
        _AI_HELP_ONLY=1
        ;;
      --)
        shift
        (( $# == 0 )) || {
          _ai_error "Unexpected operand: $1"
          return 2
        }
        break
        ;;
      -*)
        _ai_error "Unknown option: $1"
        return 2
        ;;
      *)
        _ai_error "Unexpected operand: $1"
        return 2
        ;;
    esac
    shift
  done
  return 0
}

_ai_usage_common() {
  local profile="${1:-}"
  local command_name="${2:-}"
  case "$profile" in
    clean) print -u2 -r -- "Usage: $command_name [--dry-run] [--yes] [--verbose]" ;;
    sweep) print -u2 -r -- \
      "Usage: $command_name [--root PATH] [--depth N] [--xdev] [--dry-run] [--yes] [--verbose]" ;;
    config-backup) print -u2 -r -- \
      "Usage: $command_name [--dry-run] [--yes] [--verbose]" ;;
    config-restore) print -u2 -r -- \
      "Usage: $command_name [SNAPSHOT] [--dry-run] [--yes] [--verbose]" ;;
    doctor) print -u2 -r -- "Usage: $command_name [--report] [--verbose]" ;;
    disk) print -u2 -r -- "Usage: $command_name [--verbose]" ;;
    versions) print -u2 -r -- "Usage: $command_name [--json] [--verbose]" ;;
  esac
  print -u2 -r -- ""
  print -u2 -r -- "Flags:"
  case "$profile" in
    clean)
      print -u2 -r -- "  --dry-run       Preview without modifying anything"
      print -u2 -r -- "  --yes, -y       Skip the confirmation prompt"
      print -u2 -r -- "  --verbose, -v   Show additional diagnostics"
      ;;
    sweep)
      print -u2 -r -- "  --dry-run       Preview without modifying anything"
      print -u2 -r -- "  --yes, -y       Skip the confirmation prompt"
      print -u2 -r -- "  --root PATH     Root for project sweep (default: HOME)"
      print -u2 -r -- "  --depth N       Maximum discovery depth (1-8)"
      print -u2 -r -- "  --xdev          Keep discovery on the root filesystem"
      print -u2 -r -- "  --verbose, -v   Show additional diagnostics"
      ;;
    config-backup)
      print -u2 -r -- "  --dry-run       Validate and preview without mutation"
      print -u2 -r -- "  --yes, -y       Skip the confirmation prompt"
      print -u2 -r -- "  --verbose, -v   Show additional diagnostics"
      ;;
    config-restore)
      print -u2 -r -- "  SNAPSHOT        Validated token; omit it to pick one with fzf"
      print -u2 -r -- "  --dry-run       Validate and preview without mutation"
      print -u2 -r -- "  --yes, -y       Skip the confirmation prompt"
      print -u2 -r -- "  --verbose, -v   Show additional diagnostics"
      ;;
    doctor)
      print -u2 -r -- "  --report        Save a bounded markdown report"
      print -u2 -r -- "  --verbose, -v   Show additional diagnostics"
      ;;
    disk)
      print -u2 -r -- "  --verbose, -v   Show additional diagnostics"
      ;;
    versions)
      print -u2 -r -- "  --json          Emit machine-readable JSON"
      print -u2 -r -- "  --verbose, -v   Show additional diagnostics"
      ;;
  esac
  print -u2 -r -- "  --help, -h      Show this help"
}

# --- Helpers -----------------------------------------------------------------

_ai_vlog() { (( _AI_VERBOSE )) && _ai_info "$1"; }

# OpenCode honors the XDG base directories. Resolve them in one place so the
# cleanup, disk, doctor, and log inventories agree on the same roots. A
# relative or empty override falls back to the HOME-derived default, and the
# result is canonical so path-boundary checks compare like with like.
_ai_opencode_config_dir() {
  local base="${XDG_CONFIG_HOME:-}"
  [[ "$base" == /* ]] || base="${HOME:A}/.config"
  print -r -- "${${base%/}:A}/opencode"
}

_ai_opencode_data_dir() {
  local base="${XDG_DATA_HOME:-}"
  [[ "$base" == /* ]] || base="${HOME:A}/.local/share"
  print -r -- "${${base%/}:A}/opencode"
}

# Bounded disk-usage probe. Diagnostics fail closed when no timeout utility is
# available instead of risking an unbounded filesystem traversal.
_ai_du() {
  emulate -L zsh
  setopt local_options pipefail
  local target="${1:-}" timeout_bin="" output=""
  [[ -n "$target" && ( -e "$target" || -L "$target" ) ]] || {
    print -r -- "not found"
    return 1
  }
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="$(command -v gtimeout)"
  else
    print -r -- "unavailable (timeout required)"
    return 1
  fi
  output=$(
    command "$timeout_bin" --foreground --kill-after=1s 3s \
      du -sh -- "$target" 2>/dev/null | command head -c 256
  ) || {
    print -r -- "unavailable"
    return 1
  }
  output="${output%%$'\n'*}"
  output="${output%%[[:space:]]*}"
  [[ -n "$output" && ${#output} -le 64 ]] || {
    print -r -- "unavailable"
    return 1
  }
  print -r -- "${(V)output}"
}

# Confirm (respects --yes)
_ai_confirm() {
  local prompt="${1:-Continue?}"
  if (( _AI_YES )); then
    _ai_vlog "Auto-confirmed: $prompt"
    return 0
  fi
  [[ -t 0 && -t 2 ]] || return 2
  local reply=""
  if _ai_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi
  IFS= read -r reply || return 2
  print -u2 -r -- ""
  [[ "$reply" =~ '^[Yy]$' ]] && return 0
  return 130
}

_ai_authorize() {
  local prompt="${1:-Continue?}"
  (( _AI_DRY_RUN || _AI_YES )) && return 0
  local -i confirm_rc=0
  _ai_confirm "$prompt" || confirm_rc=$?
  case "$confirm_rc" in
    0) return 0 ;;
    130)
      _ai_info "Cancelled."
      return 130
      ;;
    *)
      _ai_error "Confirmation requires a terminal; use --yes explicitly."
      return 1
      ;;
  esac
}

# Trash directory
_ai_trash_dir() { print -r -- "${HOME:A}/.local/share/zdx/ai-trash"; }

_ai_trash_chain_check() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local home_root="${HOME:A}"
  [[ "$HOME" == "$home_root" && -d "$home_root" && ! -L "$home_root" \
    && -O "$home_root" ]] || return 1

  local current="$home_root" component="" chain=""
  local -A state=()
  for component in "" .local share zdx ai-trash; do
    [[ -z "$component" ]] || current="$current/$component"
    [[ -d "$current" && ! -L "$current" && -O "$current" \
      && "$current" == "${current:A}" ]] || return 1
    state=()
    zstat -LH state -- "$current" 2>/dev/null || return 1
    (( state[uid] == EUID && (state[mode] & 8#170000) == 8#040000 \
      && (state[mode] & 8#022) == 0 )) || return 1
    if [[ "$component" == ai-trash ]]; then
      (( (state[mode] & 8#077) == 0 )) || return 1
    fi
    chain+="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]};"
  done
  REPLY="$chain"
}

_ai_trash_prepare() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local home_root="${HOME:A}"
  [[ "$HOME" == "$home_root" && -d "$home_root" && ! -L "$home_root" \
    && -O "$home_root" ]] || return 1
  local -A home_state=()
  zstat -LH home_state -- "$home_root" 2>/dev/null || return 1
  (( (home_state[mode] & 8#022) == 0 )) || return 1

  local current="$home_root" component=""
  for component in .local share zdx ai-trash; do
    current="$current/$component"
    if [[ -e "$current" || -L "$current" ]]; then
      [[ -d "$current" && ! -L "$current" && -O "$current" \
        && "$current" == "${current:A}" ]] || return 1
      local -A existing_state=()
      zstat -LH existing_state -- "$current" 2>/dev/null || return 1
      (( (existing_state[mode] & 8#022) == 0 )) || return 1
      if [[ "$component" == ai-trash ]]; then
        (( (existing_state[mode] & 8#077) == 0 )) || return 1
      fi
    else
      (umask 077; command mkdir -m 700 -- "$current") || return 1
      local -A created_state=()
      [[ -d "$current" && ! -L "$current" && -O "$current" \
        && "$current" == "${current:A}" ]] \
        && zstat -LH created_state -- "$current" 2>/dev/null || return 1
      (( created_state[uid] == EUID \
        && (created_state[mode] & 8#170000) == 8#040000 \
        && (created_state[mode] & 8#077) == 0 )) || return 1
    fi
  done
  _ai_trash_chain_check
}

# Move to an invocation-owned directory below the validated private trash.
_ai_move_to_trash() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local target="$1" label="${2:-$1}" expected_fingerprint="${3:-}"
  [[ -n "$expected_fingerprint" ]] || {
    _ai_error "Refusing quarantine without a reviewed target identity."
    return 1
  }
  [[ ! -e "$target" ]] && return 0

  _ai_trash_prepare || {
    _ai_error "Refusing an unsafe private trash path."
    return 1
  }
  local trash_identity="$REPLY"
  local tdir="$(_ai_trash_dir)"

  local entry_dir=""
  entry_dir=$(umask 077; command mktemp -d \
    "$tdir/zdx-ai-trash.XXXXXX" 2>/dev/null) || return 1
  local -A entry_state=()
  [[ "$entry_dir" == "${entry_dir:A}" && "${entry_dir:h}" == "$tdir" \
    && "${entry_dir:t}" == zdx-ai-trash.* \
    && -d "$entry_dir" && ! -L "$entry_dir" && -O "$entry_dir" ]] \
    && zstat -LH entry_state -- "$entry_dir" 2>/dev/null \
    && (( entry_state[uid] == EUID \
      && (entry_state[mode] & 8#170000) == 8#040000 \
      && entry_state[nlink] == 2 \
      && (entry_state[mode] & 8#077) == 0 )) || {
    _ai_error "Refusing an unsafe trash reservation."
    return 1
  }
  _ai_trash_chain_check && [[ "$REPLY" == "$trash_identity" ]] || {
    _ai_error "Trash path changed while reserving a destination."
    command rmdir -- "$entry_dir" 2>/dev/null || true
    return 1
  }

  local origin_file="$entry_dir/.zdx-origin"
  (
    setopt local_options noclobber
    umask 077
    print -r -- "$target" > "$origin_file"
  ) 2>/dev/null || {
    command rmdir -- "$entry_dir" 2>/dev/null || true
    return 1
  }
  local -A origin_state=()
  [[ -f "$origin_file" && ! -L "$origin_file" && -O "$origin_file" ]] \
    && zstat -LH origin_state -- "$origin_file" 2>/dev/null \
    && (( origin_state[uid] == EUID && origin_state[nlink] == 1 \
      && (origin_state[mode] & 8#170000) == 8#100000 \
      && (origin_state[mode] & 8#077) == 0 \
      && origin_state[size] > 0 && origin_state[size] <= 4096 )) || {
    _ai_error "Could not publish private quarantine recovery metadata."
    return 1
  }

  local dest="$entry_dir/${target:t}"
  local -A target_state=() entry_current=()
  zstat -LH target_state -- "$target" 2>/dev/null \
    && zstat -LH entry_current -- "$entry_dir" 2>/dev/null \
    && (( target_state[device] == entry_current[device] )) || {
    _ai_error "Refusing cross-filesystem quarantine for: $target"
    command rm -f -- "$origin_file" 2>/dev/null || true
    command rmdir -- "$entry_dir" 2>/dev/null || true
    return 1
  }

  # The caller freezes identity before review and after mount inspection. Do
  # the final comparison inside the relocation helper, after all destination
  # preparation, so none of that work opens an unchecked replacement window.
  _ai_trash_chain_check && [[ "$REPLY" == "$trash_identity" ]] \
    && _ai_clean_target_matches "$target" "$expected_fingerprint" || {
    _ai_error "Cleanup target changed immediately before quarantine: $target"
    command rm -f -- "$origin_file" 2>/dev/null || true
    command rmdir -- "$entry_dir" 2>/dev/null || true
    return 1
  }
  if command mv -- "$target" "$dest" 2>/dev/null; then
    _ai_success "$label → trash ($dest)"
    return 0
  fi
  command rm -f -- "$origin_file" 2>/dev/null || true
  command rmdir -- "$entry_dir" 2>/dev/null || true
  _ai_error "$label — failed to move to trash"
  return 1
}

_ai_no_nested_mounts() {
  emulate -L zsh
  local target="${1:-}" timeout_bin="" mounts="" mount_path=""
  [[ -n "$target" && "$target" == /* ]] || return 1
  [[ -d "$target" ]] || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="$(command -v gtimeout)"
  else
    _ai_error "A timeout utility is required to check mount boundaries."
    return 1
  fi
  command -v findmnt >/dev/null 2>&1 || {
    _ai_error "findmnt is required before relocating a directory cleanup target."
    return 1
  }
  mounts=$(command "$timeout_bin" --foreground --kill-after=1s 3s \
    findmnt -rn -o TARGET 2>/dev/null) || {
    _ai_error "Could not complete the bounded mount-boundary check."
    return 1
  }
  (( ${#mounts} <= 1048576 )) || {
    _ai_error "Mount inventory exceeded its byte bound."
    return 1
  }
  while IFS= read -r mount_path; do
    mount_path="${mount_path//\\040/ }"
    mount_path="${mount_path//\\011/$'\t'}"
    mount_path="${mount_path//\\012/$'\n'}"
    mount_path="${mount_path//\\134/\\}"
    if [[ "$mount_path" == "$target" || "$mount_path" == "$target"/* ]]; then
      _ai_error "Refusing a cleanup tree that contains a mount: $mount_path"
      return 1
    fi
  done <<< "$mounts"
  return 0
}

_ai_temp_parent_check() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local temp_parent="${1:-}"
  REPLY=""
  [[ -n "$temp_parent" && "$temp_parent" == /* \
    && "$temp_parent" == "${temp_parent:A}" \
    && -d "$temp_parent" && ! -L "$temp_parent" ]] || return 1
  local -A state=()
  zstat -LH state -- "$temp_parent" 2>/dev/null || return 1
  if (( state[uid] == EUID )); then
    (( (state[mode] & 8#022) == 0 || (state[mode] & 8#1000) != 0 )) \
      || return 1
  else
    local -A root_state=()
    zstat -LH root_state -- / 2>/dev/null || return 1
    (( state[uid] == root_state[uid] \
      && (state[mode] & 8#1000) != 0 )) || return 1
  fi
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}"
}

# Resolve a supported CLI from the strict standard NVM default layout without
# loading nvm shell code. This is used only when the executable is absent from
# PATH, as happens with a lazy NVM alias in a fresh interactive shell.
typeset -g _AI_RESOLVED_PATH_PREFIX=""
typeset -g _AI_RESOLVED_NODE=""
_ai_resolve_nvm_default_cli() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local cmd="${1:-}" home_root="${HOME:A}"
  local nvm_root="${NVM_DIR:-$home_root/.nvm}"
  local default_file="" default_version="" version_dir="" bin_dir=""
  local candidate="" canonical="" node_bin="" node_canonical="" checked_dir=""
  local -a checked_dirs=()
  local -A state=() launch_state=() target_state=() default_state=()
  local -A node_state=()

  case "$cmd" in
    claude|codex|opencode|copilot|amp|node|npm) ;;
    *) return 1 ;;
  esac

  [[ "$HOME" == "$home_root" && "$nvm_root" == "$home_root/.nvm" ]] \
    || return 1
  checked_dirs=(
    "$home_root"
    "$nvm_root"
    "$nvm_root/alias"
    "$nvm_root/versions"
    "$nvm_root/versions/node"
  )
  for checked_dir in "${checked_dirs[@]}"; do
    state=()
    [[ "$checked_dir" == "${checked_dir:A}" \
      && -d "$checked_dir" && ! -L "$checked_dir" ]] \
      && zstat -LH state -- "$checked_dir" 2>/dev/null \
      && (( state[uid] == EUID \
        && (state[mode] & 8#170000) == 8#040000 \
        && (state[mode] & 8#022) == 0 )) || return 1
  done

  default_file="$nvm_root/alias/default"
  [[ -f "$default_file" && ! -L "$default_file" ]] \
    && zstat -LH default_state -- "$default_file" 2>/dev/null \
    && (( default_state[uid] == EUID \
      && (default_state[mode] & 8#170000) == 8#100000 \
      && (default_state[mode] & 8#022) == 0 \
      && default_state[nlink] == 1 \
      && default_state[size] > 0 && default_state[size] <= 64 )) || return 1
  default_version=$(<"$default_file")
  [[ "$default_version" =~ '^v[0-9]+[.][0-9]+[.][0-9]+$' ]] || return 1

  version_dir="$nvm_root/versions/node/$default_version"
  bin_dir="$version_dir/bin"
  for checked_dir in "$version_dir" "$bin_dir"; do
    state=()
    [[ "$checked_dir" == "${checked_dir:A}" \
      && -d "$checked_dir" && ! -L "$checked_dir" ]] \
      && zstat -LH state -- "$checked_dir" 2>/dev/null \
      && (( state[uid] == EUID \
        && (state[mode] & 8#170000) == 8#040000 \
        && (state[mode] & 8#022) == 0 )) || return 1
  done

  candidate="$bin_dir/$cmd"
  canonical="${candidate:A}"
  node_bin="$bin_dir/node"
  node_canonical="${node_bin:A}"
  [[ "$canonical" == "$version_dir"/* \
    && "$node_canonical" == "$version_dir"/* \
    && -f "$candidate" && -x "$candidate" \
    && -f "$node_bin" && -x "$node_bin" ]] \
    && zstat -LH launch_state -- "$candidate" 2>/dev/null \
    && zstat -H target_state -- "$canonical" 2>/dev/null \
    && zstat -H node_state -- "$node_canonical" 2>/dev/null \
    && (( (launch_state[mode] & 8#170000) == 8#100000 \
        || (launch_state[mode] & 8#170000) == 8#120000 )) \
    && (( launch_state[uid] == EUID \
      && target_state[uid] == EUID \
      && (target_state[mode] & 8#170000) == 8#100000 \
      && (target_state[mode] & 8#022) == 0 \
      && node_state[uid] == EUID \
      && (node_state[mode] & 8#170000) == 8#100000 \
      && (node_state[mode] & 8#022) == 0 \
      && node_state[size] > 0 \
      && node_state[size] <= 536870912 )) || return 1

  REPLY="$candidate"
  _AI_RESOLVED_PATH_PREFIX="$bin_dir"
  _AI_RESOLVED_NODE="$node_bin"
}

# Resolve an external CLI without accepting aliases, functions, shell wrappers,
# or stale command-hash entries as executable identities. REPLY contains the
# absolute launch path. A validated NVM bin prefix is exposed separately for
# an env-based Node shebang and never mutates the caller's PATH.
_ai_resolve_cli() {
  emulate -L zsh
  local cmd="${1:-}" search_dir="" candidate=""
  REPLY=""
  _AI_RESOLVED_PATH_PREFIX=""
  _AI_RESOLVED_NODE=""
  [[ "$cmd" =~ '^[a-zA-Z0-9._+-]+$' ]] || return 1
  for search_dir in "${path[@]}"; do
    [[ -n "$search_dir" && "$search_dir" == /* \
      && "$search_dir" != *'|'* \
      && "$search_dir" != *[[:cntrl:]]* ]] || continue
    candidate="${search_dir%/}/$cmd"
    candidate="${candidate:a}"
    [[ "$candidate" == /* && "$candidate" != *'|'* \
      && "$candidate" != *[[:cntrl:]]* \
      && -f "$candidate" && -x "$candidate" ]] || continue
    if [[ "$candidate" == "$HOME/.nvm/versions/node/"*"/bin/$cmd" ]]; then
      local path_candidate="$candidate"
      if _ai_resolve_nvm_default_cli "$cmd" \
        && [[ "$REPLY" == "$path_candidate" ]]; then
        return 0
      fi
      _AI_RESOLVED_PATH_PREFIX=""
      _AI_RESOLVED_NODE=""
    fi
    REPLY="$candidate"
    return 0
  done
  _ai_resolve_nvm_default_cli "$cmd"
}

# Probe a CLI's --version output. Distinguishes three states:
#   rc=0  → working external executable; stdout has the version line
#   rc=1  → no external executable is installed
#   rc=2  → a shell wrapper exists, or the bounded external probe failed
# stderr is captured privately and never forwarded to the terminal.
typeset -g _AI_PROBE_ERR=""
typeset -gri _AI_PROBE_FILE_LIMIT_BLOCKS=256
# Amp's Bun runtime materializes a native module before handling --version.
# Keep that incidental file bounded to 16 MiB without constraining stdout or
# stderr beyond their independent 64 KiB post-probe validation.
typeset -gri _AI_AMP_PROBE_FILE_LIMIT_BLOCKS=32768
_ai_probe_cli() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 2
  local cmd="${1:-}"
  local -a version_args=(--version)
  _AI_PROBE_ERR=""
  [[ "$cmd" =~ '^[a-zA-Z0-9._+-]+$' ]] || return 2
  local cli_bin="" cli_path_prefix=""
  if _ai_resolve_cli "$cmd"; then
    cli_bin="$REPLY"
    cli_path_prefix="$_AI_RESOLVED_PATH_PREFIX"
  elif command -v -- "$cmd" >/dev/null 2>&1; then
    _AI_PROBE_ERR="A shell wrapper exists, but no external executable could be resolved."
    return 2
  else
    return 1
  fi

  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="$(command -v gtimeout)"
  else
    _AI_PROBE_ERR="A timeout utility is required for bounded probes."
    return 2
  fi

  local temp_parent="${TMPDIR:-/tmp}"
  [[ "$temp_parent" == /* ]] || return 2
  temp_parent="${temp_parent:A}"
  _ai_temp_parent_check "$temp_parent" || {
    _AI_PROBE_ERR="Unsafe temporary root."
    return 2
  }
  local probe_dir=""
  probe_dir=$(umask 077; command mktemp -d \
    "$temp_parent/zdx-ai-probe.XXXXXX" 2>/dev/null) || return 2
  local stdout_file="$probe_dir/stdout" stderr_file="$probe_dir/stderr"
  local cache_dir="$probe_dir/cache"
  local -A dir_before=() dir_after=()
  local -A out_before=() out_after=() err_before=() err_after=()
  local -A cache_before=() cache_after=()
  local -i private_cache=0
  [[ "$cmd" == amp || "$cmd" == cursor-agent ]] && private_cache=1
  local -i probe_file_limit=$_AI_PROBE_FILE_LIMIT_BLOCKS
  [[ "$cmd" == amp ]] \
    && probe_file_limit=$_AI_AMP_PROBE_FILE_LIMIT_BLOCKS
  local -i probe_rc=2 operation_rc=2 cleanup_rc=0
  local output=""

  {
    [[ "$probe_dir" == "${probe_dir:A}" && "${probe_dir:h}" == "$temp_parent" \
      && "${probe_dir:t}" == zdx-ai-probe.* \
      && -d "$probe_dir" && ! -L "$probe_dir" && -O "$probe_dir" ]] \
      && zstat -LH dir_before -- "$probe_dir" 2>/dev/null \
      && (( dir_before[uid] == EUID && dir_before[nlink] == 2 \
        && (dir_before[mode] & 8#170000) == 8#040000 \
        && (dir_before[mode] & 8#077) == 0 )) || return 2
    (umask 077; : > "$stdout_file" && : > "$stderr_file") || return 2
    zstat -LH out_before -- "$stdout_file" 2>/dev/null \
      && zstat -LH err_before -- "$stderr_file" 2>/dev/null || return 2
    if (( private_cache )); then
      (umask 077; command mkdir -m 700 -- "$cache_dir") 2>/dev/null \
        || return 2
      zstat -LH cache_before -- "$cache_dir" 2>/dev/null \
        && (( (cache_before[mode] & 8#170000) == 8#040000 \
          && cache_before[uid] == EUID \
          && (cache_before[mode] & 8#077) == 0 )) || return 2
    fi

    (
      ulimit -f "$probe_file_limit" 2>/dev/null || exit 1
      (( private_cache )) && export XDG_CACHE_HOME="$cache_dir"
      # Hermes prints its version before an ancillary upstream-status check.
      # Flush that header even when the later check reaches our deadline.
      [[ "$cmd" == hermes ]] && export PYTHONUNBUFFERED=1
      [[ -n "$cli_path_prefix" ]] \
        && export PATH="$cli_path_prefix:$PATH"
      command "$timeout_bin" --kill-after=1s 5s \
        "$cli_bin" "${version_args[@]}" \
        </dev/null > "$stdout_file" 2> "$stderr_file"
    )
    probe_rc=$?
    zstat -LH out_after -- "$stdout_file" 2>/dev/null \
      && zstat -LH err_after -- "$stderr_file" 2>/dev/null \
      && [[ "${out_before[device]}:${out_before[inode]}:${out_before[uid]}:"\
"${out_before[nlink]}" == "${out_after[device]}:${out_after[inode]}:"\
"${out_after[uid]}:${out_after[nlink]}" \
        && "${err_before[device]}:${err_before[inode]}:${err_before[uid]}:"\
"${err_before[nlink]}" == "${err_after[device]}:${err_after[inode]}:"\
"${err_after[uid]}:${err_after[nlink]}" ]] \
      && (( out_after[size] >= 0 && out_after[size] <= 65536 \
        && err_after[size] >= 0 && err_after[size] <= 65536 )) || return 2
    output=$(<"$stdout_file")
    _AI_PROBE_ERR=$(<"$stderr_file")
    output="${output%%$'\n'*}"
    if [[ "$cmd" == hermes ]]; then
      # Only Hermes' complete, typed version header can survive a timeout of
      # its subsequent update-status lookup. Other failures remain failures;
      # neither that lookup nor this probe certifies the latest release.
      if (( probe_rc == 0 || probe_rc == 124 )) \
        && [[ "$output" != *[[:cntrl:]]* \
          && "$output" =~ '^Hermes Agent v[0-9]+[.][0-9]+[.][0-9]+([[:space:]].*)?$' ]]; then
        operation_rc=0
      else
        operation_rc=2
      fi
    elif (( probe_rc == 0 )) && [[ -n "$output" \
      && "$output" != *"command not found"* ]]; then
      operation_rc=0
    else
      operation_rc=2
    fi
  } always {
    if [[ -f "$stdout_file" && ! -L "$stdout_file" ]] \
      && zstat -LH out_after -- "$stdout_file" 2>/dev/null \
      && [[ "${out_before[device]}:${out_before[inode]}:${out_before[uid]}:"\
"${out_before[nlink]}" == "${out_after[device]}:${out_after[inode]}:"\
"${out_after[uid]}:${out_after[nlink]}" ]]; then
      command rm -f -- "$stdout_file" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    if [[ -f "$stderr_file" && ! -L "$stderr_file" ]] \
      && zstat -LH err_after -- "$stderr_file" 2>/dev/null \
      && [[ "${err_before[device]}:${err_before[inode]}:${err_before[uid]}:"\
"${err_before[nlink]}" == "${err_after[device]}:${err_after[inode]}:"\
"${err_after[uid]}:${err_after[nlink]}" ]]; then
      command rm -f -- "$stderr_file" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    if (( private_cache )); then
      if [[ -d "$cache_dir" && ! -L "$cache_dir" ]] \
        && zstat -LH cache_after -- "$cache_dir" 2>/dev/null \
        && [[ "${cache_before[device]}:${cache_before[inode]}:"\
"${cache_before[uid]}" == "${cache_after[device]}:${cache_after[inode]}:"\
"${cache_after[uid]}" ]] \
        && (( (cache_after[mode] & 8#170000) == 8#040000 )); then
        command rm -rf -- "$cache_dir" 2>/dev/null || cleanup_rc=1
      else
        cleanup_rc=1
      fi
    fi
    if [[ -d "$probe_dir" && ! -L "$probe_dir" ]] \
      && zstat -LH dir_after -- "$probe_dir" 2>/dev/null \
      && [[ "${dir_before[device]}:${dir_before[inode]}:${dir_before[uid]}" \
        == "${dir_after[device]}:${dir_after[inode]}:${dir_after[uid]}" ]]; then
      command rmdir -- "$probe_dir" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    (( cleanup_rc == 0 )) || operation_rc=2
  }

  (( operation_rc == 0 )) || return 2
  print -r -- "$output"
}

# --- Timing ------------------------------------------------------------------

_ai_timed() {
  local label="$1"
  shift
  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

# --- Report Helpers ----------------------------------------------------------
# Markdown report generation for ai-doctor --report.

typeset -g _AI_REPORT_BUF=""
typeset -gi _AI_REPORT_OVERFLOW=0
typeset -gi _AI_REPORT_MAX_BYTES=1048576

_ai_report_append() {
  local addition="$1"
  (( ${#_AI_REPORT_BUF} + ${#addition} <= _AI_REPORT_MAX_BYTES )) || {
    _AI_REPORT_OVERFLOW=1
    return 1
  }
  _AI_REPORT_BUF+="$addition"
}

_ai_report_init() {
  _AI_REPORT_BUF=""
  _AI_REPORT_OVERFLOW=0
  _ai_report_append \
    "# ${(V)1}"$'\n\n'"_Generated: $(date '+%Y-%m-%d %H:%M:%S')_"$'\n\n'
}
_ai_report_section() { _ai_report_append "## ${(V)1}"$'\n\n'; }
_ai_report_status() {
  case "$1" in
    ok)   _ai_report_append "- OK: ${(V)2}"$'\n' ;;
    warn) _ai_report_append "- WARNING: ${(V)2}"$'\n' ;;
    fail) _ai_report_append "- FAILED: ${(V)2}"$'\n' ;;
    info) _ai_report_append "- INFO: ${(V)2}"$'\n' ;;
  esac
}
_ai_report_save() {
  emulate -L zsh
  (( !_AI_REPORT_OVERFLOW && ${#_AI_REPORT_BUF} <= _AI_REPORT_MAX_BYTES )) \
    || {
    _ai_error "Diagnostic report exceeded its byte bound and was not saved."
    return 1
  }
  local base="${PWD:A}"
  local dir="$base/ai-suite-reports"
  [[ "$PWD" == "$base" && -d "$base" && ! -L "$base" && -O "$base" ]] || {
    _ai_error "Refusing an unsafe report working directory."
    return 1
  }
  if [[ -e "$dir" || -L "$dir" ]]; then
    [[ -d "$dir" && ! -L "$dir" && -O "$dir" && "$dir" == "${dir:A}" ]] \
      || {
      _ai_error "Refusing an unsafe report directory."
      return 1
    }
  else
    (umask 077; command mkdir -m 700 -- "$dir") || return 1
  fi
  command chmod 700 -- "$dir" 2>/dev/null || return 1
  local report_name="$(date +%Y%m%dT%H%M%S)-$RANDOM-${1:-report.md}"
  [[ "$report_name" =~ '^[A-Za-z0-9._-]+$' ]] || return 1
  local report_path="$dir/$report_name"
  (
    setopt local_options noclobber
    umask 077
    print -r -- "$_AI_REPORT_BUF" > "$report_path"
  ) 2>/dev/null || {
    _ai_error "Could not publish the report without clobbering a file."
    return 1
  }
  [[ -f "$report_path" && ! -L "$report_path" && -O "$report_path" ]] || {
    _ai_error "Published report failed validation."
    return 1
  }
  _ai_success "Report saved: $report_path"
  _AI_REPORT_BUF=""
}

# --- Menu Helpers (canonical: args = output positions) ----------------------

# Advisory menu decoration only; each public command repeats its own check.
_ai_cmd_deps() {
  case "$1" in
    ai-mcp-list|ai-mcp-doctor|ai-mcp-update) print -r -- "jq" ;;
    *)                                       print -r -- "" ;;
  esac
}

_ai_menu_entry() {
  local label="$1" command_name="$2" description="$3"
  if [[ -z "$label" || -z "$command_name" || -z "$description" \
    || "$label" == *'|'* || "$command_name" == *'|'* \
    || "$description" == *'|'* \
    || "$label" == *[[:cntrl:]]* || "$command_name" == *[[:cntrl:]]* \
    || "$description" == *[[:cntrl:]]* \
    || ! "$command_name" =~ '^[a-z][a-z0-9-]*$' ]]; then
    _ai_error "Invalid AI menu entry fields."
    return 2
  fi
  local deps
  deps=$(_ai_cmd_deps "$command_name")
  local missing=""
  if [[ -n "$deps" ]]; then
    local dep
    for dep in ${(s:,:)deps}; do
      if ! command -v "$dep" &>/dev/null; then
        missing="${missing:+$missing,}$dep"
      fi
    done
  fi

  if [[ -n "$missing" ]]; then
    printf "  ○ %s (missing: %s)|%s|%s\n" \
      "$label" "$missing" "$command_name" "$description"
  else
    printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
  fi
}

_ai_menu_section() {
  local title="$1" description="${2:-}"
  if [[ -z "$title" || "$title" == *'|'* || "$description" == *'|'* \
    || "$title" == *[[:cntrl:]]* || "$description" == *[[:cntrl:]]* ]]; then
    _ai_error "Invalid AI menu section fields."
    return 2
  fi
  printf '── %s ──|:|%s\n' "$title" "$description"
}

# --- fzf adapter --------------------------------------------------------------

_ai_fzf() {
  local -a fzf_options=(
    --height=80%
    --layout=reverse
    --border=rounded
    --delimiter='[|]'
    --with-nth=1
    --pointer='▶'
  )
  fzf_options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')

  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option=""
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && fzf_options+=("$theme_option")
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
    SHELL=/bin/sh command fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

_ai_fzf_capture() {
  emulate -L zsh
  REPLY=""
  zmodload zsh/stat 2>/dev/null || return 125

  local temp_parent="${TMPDIR:-/tmp}"
  [[ "$temp_parent" == /* ]] || return 125
  temp_parent="${temp_parent:A}"
  _ai_temp_parent_check "$temp_parent" || {
    _ai_error "Refusing an unsafe temporary root for the AI menu."
    return 125
  }
  local temp_parent_identity="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_parent/zdx-ai-fzf.XXXXXX" 2>/dev/null) || {
    _ai_error "Could not create a private AI menu directory."
    return 125
  }
  local capture_file="$capture_dir/result"
  local selection=""
  local -i fzf_rc=125 operation_rc=125 cleanup_rc=0
  local -A dir_before=() dir_after=()
  local -A before=() after=() cleanup_state=()

  {
    [[ "$capture_dir" == "${capture_dir:A}" \
      && "${capture_dir:h}" == "$temp_parent" \
      && "${capture_dir:t}" == zdx-ai-fzf.* \
      && -d "$capture_dir" && ! -L "$capture_dir" && -O "$capture_dir" ]] \
      && zstat -LH dir_before -- "$capture_dir" 2>/dev/null \
      && (( dir_before[uid] == EUID && dir_before[nlink] == 2 \
        && (dir_before[mode] & 8#170000) == 8#040000 \
        && (dir_before[mode] & 8#077) == 0 )) || {
      _ai_error "Refusing an unsafe private AI menu directory."
      return 125
    }
    (umask 077; : > "$capture_file") || {
      _ai_error "Could not create the AI menu result."
      return 125
    }
    [[ -f "$capture_file" && ! -L "$capture_file" && -O "$capture_file" ]] \
      && zstat -LH before -- "$capture_file" 2>/dev/null || {
      _ai_error "Refusing an unsafe AI menu result."
      return 125
    }

    _ai_fzf "$@" > "$capture_file"
    fzf_rc=$?

    zstat -LH after -- "$capture_file" 2>/dev/null \
      && [[ "${before[device]}:${before[inode]}:${before[uid]}:${before[nlink]}" \
        == "${after[device]}:${after[inode]}:${after[uid]}:${after[nlink]}" ]] \
      && (( after[size] >= 0 && after[size] <= 1048576 )) || {
      _ai_error "The AI menu result changed or is oversized."
      return 125
    }
    selection=$(<"$capture_file")
    if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
      _ai_error "A cancelled AI menu returned unexpected data."
      return 125
    fi
    operation_rc=$fzf_rc
  } always {
    if [[ -f "$capture_file" && ! -L "$capture_file" ]] \
      && zstat -LH cleanup_state -- "$capture_file" 2>/dev/null \
      && [[ "${before[device]}:${before[inode]}:${before[uid]}:${before[nlink]}" \
        == "${cleanup_state[device]}:${cleanup_state[inode]}:"\
"${cleanup_state[uid]}:${cleanup_state[nlink]}" ]]; then
      command rm -f -- "$capture_file" 2>/dev/null || cleanup_rc=1
    elif [[ -e "$capture_file" || -L "$capture_file" ]]; then
      cleanup_rc=1
    fi
    if [[ -d "$capture_dir" && ! -L "$capture_dir" ]] \
      && zstat -LH dir_after -- "$capture_dir" 2>/dev/null \
      && [[ "${dir_before[device]}:${dir_before[inode]}:${dir_before[uid]}" \
        == "${dir_after[device]}:${dir_after[inode]}:${dir_after[uid]}" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_rc=1
    elif [[ -e "$capture_dir" || -L "$capture_dir" ]]; then
      cleanup_rc=1
    fi
    _ai_temp_parent_check "$temp_parent" \
      && [[ "$REPLY" == "$temp_parent_identity" ]] || cleanup_rc=1
    (( cleanup_rc == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_ai_fzf_cancelled() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

_ai_multi_safe_command() {
  case "${1:-}" in
    ai-doctor|ai-disk-usage|ai-versions|ai-log-tail|ai-mcp-list|ai-mcp-doctor)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# --- Dispatch (case-based; arms ARE the allowlist) --------------------------

_ai_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true
  case "$command_name" in
    global-clean-ai)           global-clean-ai "$@" ;;
    global-clean-claude)       global-clean-claude "$@" ;;
    global-clean-codex)        global-clean-codex "$@" ;;
    global-clean-antigravity)  global-clean-antigravity "$@" ;;
    global-clean-opencode)     global-clean-opencode "$@" ;;
    global-clean-copilot)      global-clean-copilot "$@" ;;
    global-clean-cursor)       global-clean-cursor "$@" ;;
    global-clean-amp)          global-clean-amp "$@" ;;
    project-sweep-ai)          project-sweep-ai "$@" ;;
    ai-init-agents)            ai-init-agents "$@" ;;
    ai-update)                 ai-update "$@" ;;
    ai-update-claude)          ai-update-claude "$@" ;;
    ai-update-codex)           ai-update-codex "$@" ;;
    ai-update-antigravity)     ai-update-antigravity "$@" ;;
    ai-update-opencode)        ai-update-opencode "$@" ;;
    ai-update-cursor)          ai-update-cursor "$@" ;;
    ai-update-copilot)         ai-update-copilot "$@" ;;
    ai-update-amp)             ai-update-amp "$@" ;;
    ai-update-hermes)          ai-update-hermes "$@" ;;
    ai-mcp-list)               ai-mcp-list "$@" ;;
    ai-mcp-doctor)             ai-mcp-doctor "$@" ;;
    ai-mcp-update)             ai-mcp-update "$@" ;;
    ai-config-backup)          ai-config-backup "$@" ;;
    ai-config-restore)         ai-config-restore "$@" ;;
    ai-doctor)                 ai-doctor "$@" ;;
    ai-disk-usage)             ai-disk-usage "$@" ;;
    ai-versions)               ai-versions "$@" ;;
    ai-log-tail)               ai-log-tail "$@" ;;
    "")
      _ai_error "A command is required."
      return 2
      ;;
    *)
      _ai_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

typeset -g _AI_COMMON_SOURCED=1
