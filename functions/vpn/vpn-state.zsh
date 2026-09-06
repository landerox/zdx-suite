#!/usr/bin/env zsh
# =============================================================================
# VPN State: validated cache directories, remembered profiles, state snapshot
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh.
# Safe to re-source; defines functions only.
#
# The snapshot helpers used to live in vpn-menu.zsh while feature modules called
# them, which inverted the dependency direction. They belong here so any module
# can read suite state without requiring the entrypoint.
#

if [[ -n "${_VPN_STATE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Cache directory --------------------------------------------------------
# The cache records which profile was used last and which one is the default.
# Those names reveal usage patterns, so the directory is owner-only.

# Validates a configured state directory. Every symlink component is refused:
# these paths hold privacy-sensitive usage and network metadata.
_vpn_state_resolve() {
  local configured="$1"
  local label="$2"

  if [[ -z "$configured" ]]; then
    _vpn_error "$label directory is not configured."
    return 1
  fi

  if [[ "$configured" == ".." || "$configured" == ../* \
    || "$configured" == */../* || "$configured" == */.. ]]; then
    _vpn_error "$label directory must not contain '..': $configured"
    return 1
  fi

  [[ "$configured" == /* ]] || {
    _vpn_error "$label directory must be an absolute path."
    return 1
  }
  if [[ "$configured" == *$'\n'* || "$configured" == *$'\r'* \
    || "$configured" == *$'\0'* ]]; then
    _vpn_error "$label directory contains unsupported control characters."
    return 1
  fi

  local literal="${configured:a}"
  local resolved="${configured:A}"
  local home_root="${HOME:A}"

  if [[ -z "$resolved" || "$resolved" == "/" ]]; then
    _vpn_error "Refusing to use the filesystem root as the $label directory."
    return 1
  fi

  if [[ "$resolved" == "$home_root" ]]; then
    _vpn_error "$label directory must be a dedicated subdirectory, not $resolved"
    return 1
  fi

  if [[ "$resolved" != "$home_root"/* ]]; then
    _vpn_error "$label directory must live inside your home: $resolved"
    return 1
  fi

  if [[ "$literal" != "$resolved" ]]; then
    _vpn_error "Refusing a symlinked $label directory component: $literal"
    return 1
  fi

  print -r -- "$literal"
}

_vpn_state_prepare() {
  local configured="$1"
  local label="$2"

  local resolved
  resolved=$(_vpn_state_resolve "$configured" "$label") || return 1

  if [[ ! -d "$resolved" ]]; then
    ( umask 077; command mkdir -p -- "$resolved" ) 2>/dev/null || {
      _vpn_error "Could not create the $label directory: $resolved"
      return 1
    }
  fi

  local identity_before
  identity_before=$(
    _vpn_private_dir_identity "$resolved" "$label directory"
  ) 2>/dev/null
  if [[ -z "$identity_before" ]]; then
    zmodload zsh/stat 2>/dev/null || return 1
    local -A metadata=()
    zstat -H metadata -- "$resolved" 2>/dev/null || return 1
    if (( metadata[uid] != EUID )); then
      _vpn_error "Refusing a $label directory owned by another account."
      return 1
    fi
    identity_before="${metadata[device]}:${metadata[inode]}"
  fi

  command chmod 700 -- "$resolved" 2>/dev/null || {
    _vpn_error "Could not restrict permissions on $resolved"
    return 1
  }
  local identity_after
  identity_after=$(
    _vpn_private_dir_identity "$resolved" "$label directory"
  ) || return 1
  [[ "$identity_after" == "$identity_before" ]] || {
    _vpn_error "$label directory changed while permissions were applied."
    return 1
  }

  print -r -- "$resolved"
}

_vpn_cache_dir() {
  _vpn_state_prepare "$VPN_CACHE_DIR" "cache"
}

# Read-only lookup: resolves without creating anything.
_vpn_cache_dir_existing() {
  local resolved
  resolved=$(_vpn_state_resolve "$VPN_CACHE_DIR" "cache") || return 1
  _vpn_private_dir_identity "$resolved" "cache directory" >/dev/null \
    || return 1
  print -r -- "$resolved"
}

# Cache entry names are a fixed internal set, never user input.
_vpn_cache_file() {
  local name="${1:-}"
  case "$name" in
    last-iface|default-iface|test-key) ;;
    *)
      _vpn_error "Unknown VPN cache entry: $name"
      return 1
      ;;
  esac

  local dir
  dir=$(_vpn_cache_dir) || return 1
  print -r -- "$dir/$name"
}

_vpn_cache_file_existing() {
  local name="${1:-}"
  case "$name" in
    last-iface|default-iface|test-key) ;;
    *) return 1 ;;
  esac

  local dir
  dir=$(_vpn_cache_dir_existing) || return 1
  print -r -- "$dir/$name"
}

_vpn_state_validate_file() {
  local file="$1"
  local dir="$2"
  local label="${3:-state file}"
  local -i max_bytes="${4:-0}"
  local literal="${file:a}"
  local resolved="${file:A}"
  if [[ "$literal" != "$resolved" || "${literal:h}" != "${dir:A}" \
    || ! -f "$literal" || -L "$literal" ]]; then
    _vpn_error "Refusing an unsafe $label: $literal"
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$literal" 2>/dev/null || return 1
  if (( metadata[uid] != EUID || metadata[nlink] != 1 \
    || (metadata[mode] & 8#77) != 0 )); then
    _vpn_error \
      "Refusing a non-private, multiply linked, or foreign-owned $label."
    return 1
  fi
  if (( max_bytes > 0 && metadata[size] > max_bytes )); then
    _vpn_error "Refusing an oversized $label."
    return 1
  fi
}

# stdout: metadata plus checksum, detecting both replacement and in-place edit.
_vpn_state_file_fingerprint() {
  local file="$1"
  local dir="$2"
  local label="${3:-state file}"
  local -i max_bytes="${4:-0}"
  _vpn_state_validate_file "$file" "$dir" "$label" "$max_bytes" || return 1

  zmodload zsh/stat 2>/dev/null || return 1
  local -A before=() after=()
  zstat -H before -- "$file" 2>/dev/null || return 1
  local checksum
  checksum=$(command cksum < "$file" 2>/dev/null) || return 1
  zstat -H after -- "$file" 2>/dev/null || return 1
  local before_id="${before[device]}:${before[inode]}:${before[mode]}:${before[nlink]}:${before[size]}:${before[mtime]}:${before[ctime]}"
  local after_id="${after[device]}:${after[inode]}:${after[mode]}:${after[nlink]}:${after[size]}:${after[mtime]}:${after[ctime]}"
  [[ "$before_id" == "$after_id" ]] || return 1
  local -a checksum_fields=(${=checksum})
  (( ${#checksum_fields[@]} == 2 )) \
    && [[ "${checksum_fields[1]}" == <-> \
      && "${checksum_fields[2]}" == <-> ]] || return 1
  print -r -- "${after_id}:${checksum_fields[1]}:${checksum_fields[2]}"
}

_vpn_write_cached_iface() {
  local name="${1:-}"
  local iface="${2:-}"
  case "$name" in
    last-iface|default-iface|test-key) ;;
    *)
      _vpn_error "Unknown VPN cache entry: $name"
      return 1
      ;;
  esac
  _vpn_validate_iface_name "$iface" || return 1

  local dir file directory_identity existing_fingerprint="missing"
  dir=$(_vpn_cache_dir) || return 1
  file="$dir/$name"
  directory_identity=$(
    _vpn_private_dir_identity "$dir" "cache directory"
  ) || return 1

  if [[ -e "$file" || -L "$file" ]]; then
    existing_fingerprint=$(
      _vpn_state_file_fingerprint \
        "$file" "$dir" "cache entry" "$_VPN_MAX_CACHE_BYTES"
    ) || return 1
  fi

  local temp_file=""
  temp_file=$(umask 077; command mktemp \
    "${dir}/.${name}.XXXXXX" 2>/dev/null) || return 1
  {
    _vpn_state_validate_file \
      "$temp_file" "$dir" "cache temporary" "$_VPN_MAX_CACHE_BYTES" \
      || return 1
    print -r -- "$iface" > "$temp_file" 2>/dev/null || return 1
    command chmod 600 -- "$temp_file" 2>/dev/null || return 1
    _vpn_state_validate_file \
      "$temp_file" "$dir" "cache temporary" "$_VPN_MAX_CACHE_BYTES" \
      || return 1
    _vpn_assert_private_dir_identity \
      "$dir" "cache directory" "$directory_identity" || return 1

    if [[ "$existing_fingerprint" == "missing" ]]; then
      [[ ! -e "$file" && ! -L "$file" ]] || return 1
      command ln -- "$temp_file" "$file" 2>/dev/null || return 1
      if ! command rm -- "$temp_file" 2>/dev/null; then
        zmodload zsh/stat 2>/dev/null || return 1
        local -A temp_metadata=() file_metadata=()
        if zstat -H temp_metadata -- "$temp_file" 2>/dev/null \
          && zstat -H file_metadata -- "$file" 2>/dev/null \
          && [[ "${temp_metadata[device]}:${temp_metadata[inode]}" \
            == "${file_metadata[device]}:${file_metadata[inode]}" ]]; then
          command rm -- "$file" 2>/dev/null \
            || _vpn_warn "Could not roll back a partially published cache entry."
        fi
        return 1
      fi
    else
      local current_fingerprint
      current_fingerprint=$(
        _vpn_state_file_fingerprint \
          "$file" "$dir" "cache entry" "$_VPN_MAX_CACHE_BYTES"
      ) || return 1
      [[ "$current_fingerprint" == "$existing_fingerprint" ]] || {
        _vpn_error "Cache entry changed during publication."
        return 1
      }
      command mv -f -- "$temp_file" "$file" 2>/dev/null || return 1
    fi
    temp_file=""

    _vpn_state_validate_file \
      "$file" "$dir" "published cache entry" "$_VPN_MAX_CACHE_BYTES" \
      || return 1
    local stored
    { read -r stored < "$file"; } 2>/dev/null || return 1
    [[ "$stored" == "$iface" ]] || return 1
    return 0
  } always {
    if [[ -n "$temp_file" && -e "$temp_file" && ! -L "$temp_file" ]] \
      && _vpn_state_validate_file \
        "$temp_file" "$dir" "cache temporary cleanup" \
        "$_VPN_MAX_CACHE_BYTES" 2>/dev/null; then
      command rm -f -- "$temp_file" 2>/dev/null
    fi
  }
}

# Reads a remembered profile and confirms it still exists on disk.
_vpn_read_cached_iface() {
  local iface
  iface=$(_vpn_peek_cached_iface "$1") || return 1
  _vpn_config_exists "$iface" || return $?
  print -r -- "$iface"
}

# Reads a remembered profile without checking whether it still exists. Used by
# the menu so a stale pointer can be displayed and cleared.
_vpn_peek_cached_iface() {
  local file iface dir fingerprint_before fingerprint_after
  file=$(_vpn_cache_file_existing "$1") || return 1
  dir="${file:h}"
  fingerprint_before=$(
    _vpn_state_file_fingerprint \
      "$file" "$dir" "cache entry" "$_VPN_MAX_CACHE_BYTES"
  ) || return 1
  { read -r iface < "$file"; } 2>/dev/null || return 1
  fingerprint_after=$(
    _vpn_state_file_fingerprint \
      "$file" "$dir" "cache entry" "$_VPN_MAX_CACHE_BYTES"
  ) || return 1
  [[ "$fingerprint_after" == "$fingerprint_before" ]] || return 1
  _vpn_validate_iface_name "$iface" || return 1
  print -r -- "$iface"
}

_vpn_clear_cached_iface() {
  local file dir directory_identity fingerprint current
  file=$(_vpn_cache_file_existing "$1") || return 0
  dir="${file:h}"
  directory_identity=$(
    _vpn_private_dir_identity "$dir" "cache directory"
  ) || return 1
  fingerprint=$(
    _vpn_state_file_fingerprint \
      "$file" "$dir" "cache entry" "$_VPN_MAX_CACHE_BYTES"
  ) || return 1
  _vpn_assert_private_dir_identity \
    "$dir" "cache directory" "$directory_identity" || return 1
  current=$(
    _vpn_state_file_fingerprint \
      "$file" "$dir" "cache entry" "$_VPN_MAX_CACHE_BYTES"
  ) || return 1
  [[ "$current" == "$fingerprint" ]] || {
    _vpn_error "Cache entry changed before removal."
    return 1
  }
  command rm -- "$file" 2>/dev/null
}

_vpn_remember_iface()      { _vpn_write_cached_iface "last-iface" "$1" }
_vpn_read_last_iface()     { _vpn_read_cached_iface "last-iface" }
_vpn_peek_last_iface()     { _vpn_peek_cached_iface "last-iface" }
_vpn_clear_last_iface()    { _vpn_clear_cached_iface "last-iface" }
_vpn_last_iface_file()     { _vpn_cache_file "last-iface" }

_vpn_set_default_iface()   { _vpn_write_cached_iface "default-iface" "$1" }
_vpn_read_default_iface()  { _vpn_read_cached_iface "default-iface" }
_vpn_peek_default_iface()  { _vpn_peek_cached_iface "default-iface" }
_vpn_clear_default_iface() { _vpn_clear_cached_iface "default-iface" }
_vpn_default_iface_file()  { _vpn_cache_file "default-iface" }

# Convenience readers that fall back from "exists on disk" to "recorded".
_vpn_effective_default_iface() {
  local -i read_status=0
  _vpn_read_default_iface 2>/dev/null && return 0
  read_status=$?
  (( read_status == 130 || read_status == 143 )) && return "$read_status"
  _vpn_peek_default_iface 2>/dev/null
}

_vpn_effective_last_iface() {
  local -i read_status=0
  _vpn_read_last_iface 2>/dev/null && return 0
  read_status=$?
  (( read_status == 130 || read_status == 143 )) && return "$read_status"
  _vpn_peek_last_iface 2>/dev/null
}

# --- Report directory -------------------------------------------------------
# A diagnostic report contains the public exit IP, geolocation, endpoints, the
# hostname, and resolver addresses, so both the directory and the file are
# owner-only.

_vpn_report_root() {
  _vpn_state_prepare "$VPN_MENU_REPORT_DIR" "report"
}

_vpn_state_timestamp() {
  local timestamp
  timestamp=$(command date +"%Y-%m-%d_%H%M%S" 2>/dev/null) || {
    _vpn_error "Could not generate a report timestamp."
    return 1
  }
  if [[ ${#timestamp} -ne 17 \
    || "$timestamp" != <->-<->-<->_<-> ]]; then
    _vpn_error "The generated report timestamp has an invalid format."
    return 1
  fi
  print -r -- "$timestamp"
}

_vpn_report_path() {
  local prefix="${1:-vpn-report}"
  local extension="${2:-md}"
  [[ "$prefix" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$' \
    && "$extension" =~ '^[A-Za-z0-9]{1,8}$' ]] || return 1

  local dir
  dir=$(_vpn_report_root) || return 1

  local timestamp host
  timestamp=$(_vpn_state_timestamp) || return 1
  host=$(command hostname -s 2>/dev/null || command hostname 2>/dev/null) \
    || host="host"
  host="${host//[^A-Za-z0-9._-]/_}"
  host="${host[1,64]}"
  [[ -n "$host" ]] || host="host"

  print -r -- "${dir}/${prefix}-${timestamp}-${host}.${extension}"
}

_vpn_report_temp_create() {
  local dir
  dir=$(_vpn_report_root) || return 1
  local temp_file
  temp_file=$(umask 077; command mktemp \
    "${dir}/.vpn-report.XXXXXX" 2>/dev/null) || return 1
  command chmod 600 -- "$temp_file" 2>/dev/null || {
    command rm -f -- "$temp_file" 2>/dev/null
    return 1
  }
  _vpn_state_validate_file \
    "$temp_file" "$dir" "report temporary" "$_VPN_MAX_REPORT_BYTES" \
    || return 1
  print -r -- "$temp_file"
}

# Publishes one staged report under a unique no-clobber name. Sets REPLY to the
# final pathname and removes the temporary name on success.
_vpn_report_publish() {
  local temp_file="$1"
  local prefix="${2:-vpn-report}"
  local extension="${3:-md}"
  REPLY=""

  local dir="${temp_file:h}"
  local directory_identity
  directory_identity=$(
    _vpn_private_dir_identity "$dir" "report directory"
  ) || return 1
  _vpn_state_validate_file \
    "$temp_file" "$dir" "report temporary" "$_VPN_MAX_REPORT_BYTES" \
    || return 1
  local temp_fingerprint
  temp_fingerprint=$(
    _vpn_state_file_fingerprint \
      "$temp_file" "$dir" "report temporary" "$_VPN_MAX_REPORT_BYTES"
  ) || return 1

  local base candidate
  base=$(_vpn_report_path "$prefix" "$extension") || return 1
  local stem="${base%.$extension}"
  local -i suffix=0
  while (( suffix < 1000 )); do
    if (( suffix == 0 )); then
      candidate="$base"
    else
      candidate="${stem}.${suffix}.${extension}"
    fi

    _vpn_assert_private_dir_identity \
      "$dir" "report directory" "$directory_identity" || return 1
    local current_fingerprint
    current_fingerprint=$(
      _vpn_state_file_fingerprint \
        "$temp_file" "$dir" "report temporary" "$_VPN_MAX_REPORT_BYTES"
    ) || return 1
    [[ "$current_fingerprint" == "$temp_fingerprint" ]] || {
      _vpn_error "The staged report changed before publication."
      return 1
    }

    if command ln -- "$temp_file" "$candidate" 2>/dev/null; then
      if ! command rm -- "$temp_file" 2>/dev/null; then
        command rm -f -- "$candidate" 2>/dev/null
        return 1
      fi
      _vpn_state_validate_file \
        "$candidate" "$dir" "published report" "$_VPN_MAX_REPORT_BYTES" \
        || return 1
      REPLY="$candidate"
      return 0
    fi
    (( ++suffix ))
  done

  _vpn_error "Could not allocate a unique report filename."
  return 1
}

# Validated VPN_MENU_REPORT_RETENTION. Sets REPLY to the keep-newest count;
# 0 disables pruning entirely. Invalid configuration fails closed.
_vpn_report_retention_value() {
  local raw="${VPN_MENU_REPORT_RETENTION:-20}"
  REPLY=""
  if [[ "$raw" != <-> || ${#raw} -gt 4 ]] || (( raw > 1000 )); then
    _vpn_error \
      "VPN_MENU_REPORT_RETENTION must be an integer from 0 through 1000."
    return 2
  fi
  REPLY="$raw"
}

# Bounded retention after a successful publication: keep the report that was
# just published plus the newest retention-1 prior reports for the same
# prefix. Entries that fail owner-only validation are never deleted, and the
# published report itself is always protected regardless of its sort order.
_vpn_report_prune() {
  local published="${1:-}"
  local prefix="${2:-vpn-report}"
  local extension="${3:-md}"
  local REPLY
  _vpn_report_retention_value || return 2
  local -i retention=$REPLY
  (( retention == 0 )) && return 0
  [[ -n "$published" ]] || return 1

  local dir
  dir=$(_vpn_report_root) || return 1
  local -a candidates=("$dir"/${prefix}-*.${extension}(N.))
  (( ${#candidates[@]} <= 4096 )) || {
    _vpn_warn \
      "Report inventory is unexpectedly large; retention was skipped."
    return 1
  }

  # Timestamped names are zero-padded, so a lexicographic sort is
  # chronological per prefix even when file mtimes were manipulated.
  local -a prunable=()
  local candidate
  for candidate in "${(on)candidates[@]}"; do
    [[ "$candidate" == "$published" ]] && continue
    _vpn_state_validate_file \
      "$candidate" "$dir" "published report" "$_VPN_MAX_REPORT_BYTES" \
      2>/dev/null || continue
    prunable+=("$candidate")
  done

  local -i keep_others=$(( retention - 1 ))
  (( ${#prunable[@]} > keep_others )) || return 0
  local -i remove_count=$(( ${#prunable[@]} - keep_others ))
  local -i removed=0 failures=0 index=0
  for (( index = 1; index <= remove_count; index++ )); do
    candidate="${prunable[index]}"
    _vpn_state_validate_file \
      "$candidate" "$dir" "published report" "$_VPN_MAX_REPORT_BYTES" \
      2>/dev/null || {
      (( ++failures ))
      continue
    }
    if command rm -f -- "$candidate" 2>/dev/null; then
      (( ++removed ))
    else
      (( ++failures ))
    fi
  done
  (( removed > 0 )) && _vpn_dim \
    "Report retention removed $removed old report(s); keeping the newest $retention."
  (( failures == 0 ))
}

# stdout: a human-readable hint, not a command to evaluate.
_vpn_report_view_hint() {
  local file="$1"
  if command -v batcat &>/dev/null; then
    print -r -- "batcat --style=plain ${(q)file}"
  elif command -v bat &>/dev/null; then
    print -r -- "bat --style=plain ${(q)file}"
  else
    print -r -- "cat ${(q)file}"
  fi
}

# --- Suite state snapshot ---------------------------------------------------
# One pass over access state, profiles, active tunnels, and backups. Every
# module reads the snapshot instead of probing the host repeatedly.

typeset -ga _VPN_MENU_CONFIGS=()
typeset -ga _VPN_MENU_ACTIVE_IFACES=()
typeset -gA _VPN_MENU_BACKUP_STATE=()
typeset -gi _VPN_MENU_CONFIGS_KNOWN=0
typeset -gi _VPN_MENU_ACTIVE_KNOWN=0
typeset -gi _VPN_MENU_BACKUP_AVAILABLE_COUNT=0
typeset -gi _VPN_MENU_BACKUP_UNKNOWN_COUNT=0
typeset -gi _VPN_MENU_SUDO_UNLOCKED=0
typeset -gi _VPN_MENU_WSL_FIX=0
typeset -g _VPN_MENU_CONFIG_ACCESS_STATE=""
typeset -g _VPN_MENU_WG_ACCESS_STATE=""
typeset -g _VPN_MENU_DEFAULT_IFACE=""
typeset -g _VPN_MENU_LAST_IFACE=""
typeset -g _VPN_MENU_PLATFORM=""

_vpn_state_load() {
  _VPN_MENU_CONFIGS=()
  _VPN_MENU_ACTIVE_IFACES=()
  _VPN_MENU_BACKUP_STATE=()
  _VPN_MENU_CONFIGS_KNOWN=0
  _VPN_MENU_ACTIVE_KNOWN=0
  _VPN_MENU_BACKUP_AVAILABLE_COUNT=0
  _VPN_MENU_BACKUP_UNKNOWN_COUNT=0
  _VPN_MENU_SUDO_UNLOCKED=0
  _VPN_MENU_WSL_FIX=0
  _VPN_MENU_DEFAULT_IFACE=""
  _VPN_MENU_LAST_IFACE=""

  _VPN_MENU_PLATFORM=$(_vpn_platform)
  _VPN_MENU_CONFIG_ACCESS_STATE=$(_vpn_configs_access_state)
  _VPN_MENU_WG_ACCESS_STATE=$(_vpn_wg_access_state)
  _vpn_have_sudo_cache && _VPN_MENU_SUDO_UNLOCKED=1
  _vpn_should_apply_wsl_ipv6_fix && _VPN_MENU_WSL_FIX=1

  local raw
  if raw=$(_vpn_get_configs 2>/dev/null); then
    _VPN_MENU_CONFIGS_KNOWN=1
    if [[ -n "$raw" ]]; then
      _VPN_MENU_CONFIGS=("${(@f)raw}")
      _VPN_MENU_CONFIGS=("${(@)_VPN_MENU_CONFIGS:#}")
    fi
  fi

  if raw=$(_vpn_get_active_interfaces 2>/dev/null); then
    local -A seen_active=()
    local active_candidate
    local -i active_valid=1
    for active_candidate in ${=raw}; do
      if ! _vpn_validate_iface_name "$active_candidate"; then
        active_valid=0
        _VPN_MENU_ACTIVE_IFACES=()
        break
      fi
      [[ -n "${seen_active[$active_candidate]-}" ]] && continue
      if (( ${#_VPN_MENU_ACTIVE_IFACES[@]} >= _VPN_MAX_ACTIVE_INTERFACES )); then
        active_valid=0
        _VPN_MENU_ACTIVE_IFACES=()
        break
      fi
      seen_active[$active_candidate]=1
      _VPN_MENU_ACTIVE_IFACES+=("$active_candidate")
    done
    (( active_valid )) && _VPN_MENU_ACTIVE_KNOWN=1
  fi

  _VPN_MENU_DEFAULT_IFACE=$(_vpn_effective_default_iface) \
    || _VPN_MENU_DEFAULT_IFACE=""
  _VPN_MENU_LAST_IFACE=$(_vpn_effective_last_iface) || _VPN_MENU_LAST_IFACE=""

  local conf state
  if (( _VPN_MENU_CONFIGS_KNOWN )); then
    for conf in "${_VPN_MENU_CONFIGS[@]}"; do
      state=$(_vpn_backup_state "$conf")
      _VPN_MENU_BACKUP_STATE["$conf"]="$state"
      case "$state" in
        available) (( _VPN_MENU_BACKUP_AVAILABLE_COUNT++ )) ;;
        unknown)   (( _VPN_MENU_BACKUP_UNKNOWN_COUNT++ )) ;;
      esac
    done
  fi
  return 0
}

_vpn_state_iface_is_active() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 1

  local active
  for active in "${_VPN_MENU_ACTIVE_IFACES[@]}"; do
    [[ "$active" == "$iface" ]] && return 0
  done
  return 1
}

_vpn_state_iface_backup_state() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || {
    print -r -- "unknown"
    return 1
  }

  if [[ -n "${_VPN_MENU_BACKUP_STATE[$iface]-}" ]]; then
    print -r -- "${_VPN_MENU_BACKUP_STATE[$iface]}"
    return 0
  fi

  _vpn_backup_state "$iface"
}

typeset -g _VPN_STATE_SOURCED=1
