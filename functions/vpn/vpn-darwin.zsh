#!/usr/bin/env zsh
# =============================================================================
# VPN macOS: Homebrew wireguard-tools runtime, tunnel mapping, and collectors
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh.
# Safe to re-source; defines functions only.
#
# On macOS, wg-quick runs one userspace wireguard-go per tunnel on a utunN
# device, so a profile name never becomes a device name. wireguard-go records
# the device in /var/run/wireguard/<profile>.name (root, mode 0400) and serves
# /var/run/wireguard/<device>.sock. wg-quick pairs the two by the recorded name
# and by modification times less than two seconds apart; this module applies
# the same rule, without privileges whenever the times are unambiguous.
#
# vpn-common.zsh calls these helpers only after _vpn_platform_is darwin, so
# Linux and WSL never reach them.
#

if [[ -n "${_VPN_DARWIN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Private locations. Tests point them at sandbox fixtures after sourcing; they
# are not configuration and are never read from the environment.
typeset -g _VPN_DARWIN_RUN_DIR=/private/var/run/wireguard
typeset -g _VPN_DARWIN_SYSTEM_CONFIG_DIR=/private/etc/wireguard

# Shell-lifetime cache of the Homebrew prefix, which does not change.
typeset -g _VPN_DARWIN_BREW_PREFIX=""

# Set by _vpn_darwin_map_tunnels when a privileged read resolved a pairing.
typeset -gi _VPN_DARWIN_MAP_PRIVILEGED=0

# The fixed program a Bash candidate runs to report its major version.
typeset -g _VPN_DARWIN_BASH_PROBE='printf "%s\n" "${BASH_VERSINFO[0]}"'

# --- Bounded collection -----------------------------------------------------

# stdout: the output of one read-only collector, or status 1 when it fails or
# exceeds max_bytes. Usage: _vpn_darwin_capture <max_bytes> <command...>
_vpn_darwin_capture() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local -i max_bytes="${1:-0}"
  shift
  (( max_bytes > 0 && $# > 0 )) || return 2
  local captured
  captured=$(
    "$@" 2>/dev/null </dev/null | command head -c "$(( max_bytes + 1 ))"
  ) || return 1
  (( ${#captured} <= max_bytes )) || return 1
  print -r -- "$captured"
}

# --- Homebrew and the profile directory -------------------------------------

# REPLY: the Homebrew prefix. `brew --prefix` without a formula answers without
# starting Ruby; without brew on PATH the standard prefixes are tried.
_vpn_darwin_brew_prefix() {
  REPLY=""
  if [[ -n "$_VPN_DARWIN_BREW_PREFIX" ]]; then
    REPLY="$_VPN_DARWIN_BREW_PREFIX"
    return 0
  fi

  local prefix="" brew_path=""
  if brew_path=$(whence -p brew 2>/dev/null) && [[ "$brew_path" == /* ]]; then
    prefix=$(_vpn_darwin_capture 1024 "$brew_path" --prefix) || prefix=""
    prefix="${prefix%%$'\n'*}"
  fi
  if [[ "$prefix" != /* || "$prefix" == *[[:cntrl:]]* || ! -d "$prefix" ]]; then
    prefix=""
    local candidate
    for candidate in /opt/homebrew /usr/local; do
      if [[ -x "$candidate/bin/brew" ]]; then
        prefix="$candidate"
        break
      fi
    done
  fi
  [[ -n "$prefix" ]] || return 1
  _VPN_DARWIN_BREW_PREFIX="$prefix"
  REPLY="$prefix"
}

# REPLY: the profile directory when VPN_CONFIG_DIR is unset. The system
# directory wins when it exists; otherwise Homebrew's etc/wireguard is used
# only when it already holds profiles; otherwise the system directory, which
# profile creation makes root-owned and mode 700.
_vpn_darwin_default_config_dir() {
  local system_dir="$_VPN_DARWIN_SYSTEM_CONFIG_DIR"
  REPLY="$system_dir"
  [[ -e "$system_dir" || -L "$system_dir" ]] && return 0

  _vpn_darwin_brew_prefix 2>/dev/null || {
    REPLY="$system_dir"
    return 0
  }
  local brew_dir="$REPLY/etc/wireguard"
  REPLY="$system_dir"
  [[ -d "$brew_dir" && ! -L "$brew_dir" && -r "$brew_dir" && -x "$brew_dir" ]] \
    || return 0
  local -a profiles=("$brew_dir"/*.conf(N))
  (( ${#profiles[@]} > 0 )) && REPLY="$brew_dir"
  return 0
}

# --- Tunnel tools -----------------------------------------------------------

# Refuses a tool that root would run when another account could change it.
# Homebrew files are owned by the user, which is the documented trust boundary.
_vpn_darwin_require_trusted() {
  local label="$1"
  local tool_path="$2"
  _vpn_trusted_executable --user "$tool_path" && return 0
  _vpn_error "Refusing $label at $(_vpn_display_escape "$tool_path"): another account could change what root runs."
  _vpn_info "Make it, its links, and every directory above it owned by root or you, and writable by no other user or group except admin."
  return 1
}

# REPLY: the absolute wg-quick on PATH.
_vpn_darwin_wg_quick() {
  REPLY=""
  local found=""
  found=$(whence -p wg-quick 2>/dev/null) || return 1
  [[ "$found" == /* ]] || return 1
  REPLY="$found"
}

# REPLY: an executable Bash 4 or newer for wg-quick; macOS /bin/bash is 3.2.
# Candidates, in order: bash on PATH (what wg-quick's env shebang selects), the
# bash beside wg-quick, and the one in Homebrew's prefix.
_vpn_darwin_bash4() {
  REPLY=""
  local candidate="" major="" wg_quick=""
  local -a candidates=()
  candidate=$(whence -p bash 2>/dev/null) && candidates+=("$candidate")
  wg_quick=$(whence -p wg-quick 2>/dev/null) \
    && candidates+=("${wg_quick:h:A}/bash")
  _vpn_darwin_brew_prefix 2>/dev/null && candidates+=("$REPLY/bin/bash")
  REPLY=""

  local -A tried=()
  for candidate in "${candidates[@]}"; do
    [[ "$candidate" == /* && -f "$candidate" && -x "$candidate" ]] || continue
    [[ -z "${tried[${candidate:A}]-}" ]] || continue
    tried[${candidate:A}]=1
    major=$(_vpn_darwin_capture 16 "$candidate" -c "$_VPN_DARWIN_BASH_PROBE") \
      || continue
    major="${major%%$'\n'*}"
    [[ "$major" == <-> ]] && (( major >= 4 )) || continue
    REPLY="$candidate"
    return 0
  done
  return 1
}

# REPLY: the major version of the Bash that wg-quick would use, or empty.
_vpn_darwin_bash_version() {
  local found=""
  _vpn_darwin_bash4 || {
    REPLY=""
    return 1
  }
  found="$REPLY"
  REPLY=$(_vpn_darwin_capture 16 "$found" -c "$_VPN_DARWIN_BASH_PROBE") \
    || REPLY=""
  REPLY="${REPLY%%$'\n'*}"
  [[ -n "$REPLY" ]]
}

# REPLY: the wireguard-go that wg-quick will run: the one beside it, because
# wg-quick prepends its own directory to PATH. Status 1 when it is absent.
_vpn_darwin_wireguard_go() {
  REPLY=""
  _vpn_darwin_wg_quick || return 1
  local candidate="${REPLY:h:A}/wireguard-go"
  REPLY=""
  [[ -f "$candidate" && -x "$candidate" ]] || return 1
  REPLY="$candidate"
}

# REPLY: a validated absolute wg for privileged state reads.
_vpn_darwin_wg_tool() {
  REPLY=""
  local found=""
  found=$(whence -p wg 2>/dev/null) || return 1
  [[ "$found" == /* ]] || return 1
  _vpn_darwin_require_trusted wg "$found" || return 1
  REPLY="$found"
}

# reply=(bash wg-quick): the validated interpreter and script for a tunnel
# transition. wg-quick prepends its own directory to PATH, so the wg and
# wireguard-go that root runs are the ones beside it, and they are validated
# as well.
_vpn_darwin_tunnel_tools() {
  reply=()
  local REPLY="" wg_quick="" tool_dir="" bash4="" tool_name=""
  if ! _vpn_darwin_wg_quick; then
    _vpn_error "WireGuard (wg-quick) is not installed."
    _vpn_info "Install it with: brew install wireguard-tools"
    return 1
  fi
  wg_quick="$REPLY"
  _vpn_darwin_require_trusted wg-quick "$wg_quick" || return 1

  tool_dir="${wg_quick:h:A}"
  for tool_name in wg wireguard-go; do
    if [[ ! -f "$tool_dir/$tool_name" || ! -x "$tool_dir/$tool_name" ]]; then
      _vpn_error "$tool_name is missing beside wg-quick in $(_vpn_display_escape "$tool_dir")."
      _vpn_info "Install it with: brew install $tool_name"
      return 1
    fi
    _vpn_darwin_require_trusted "$tool_name" "$tool_dir/$tool_name" || return 1
  done

  if ! _vpn_darwin_bash4; then
    _vpn_error "wg-quick on macOS needs Bash 4 or newer; /bin/bash is 3.2."
    _vpn_info "Install it with: brew install bash"
    return 1
  fi
  bash4="$REPLY"
  _vpn_darwin_require_trusted bash "$bash4" || return 1

  reply=("$bash4" "$wg_quick")
}

# --- Profile-to-device mapping ----------------------------------------------

# True when the wg-quick runtime directory is a real directory that no
# account other than root (or the user, for test fixtures) can write.
_vpn_darwin_run_dir_safe() {
  local run_dir="$_VPN_DARWIN_RUN_DIR"
  [[ "$run_dir" == /* && -d "$run_dir" && ! -L "$run_dir" ]] || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A state=()
  zstat -LH state -- "$run_dir" 2>/dev/null || return 1
  (( (state[uid] == 0 || state[uid] == EUID) && (state[mode] & 8#22) == 0 ))
}

# Pairs live utun devices with wg-quick profiles.
#   Arguments: the live devices that `wg show interfaces` listed.
#   Sets:      reply (active profiles, sorted), _VPN_ACTIVE_DEVICES (profile
#              -> device), _VPN_ACTIVE_NAME_IDS (profile -> identity of its
#              .name record), _VPN_UNMANAGED_DEVICES (devices without a
#              wg-quick profile, never targeted), _VPN_DARWIN_MAP_PRIVILEGED.
#   Status:    0 mapped; 1 unavailable or inconsistent; 4 locked, when an
#              ambiguous pairing needs a privileged read and no warm sudo
#              timestamp exists; 130 or 143 when interrupted.
_vpn_darwin_map_tunnels() {
  reply=()
  _VPN_ACTIVE_DEVICES=()
  _VPN_ACTIVE_NAME_IDS=()
  _VPN_UNMANAGED_DEVICES=()
  _VPN_DARWIN_MAP_PRIVILEGED=0

  local device=""
  local -a devices=()
  for device in "$@"; do
    # wireguard-go names macOS devices utunN; anything else is not a tunnel
    # this suite can pair, so it is reported as unmanaged.
    if [[ "$device" =~ '^utun[0-9]{1,4}$' ]]; then
      devices+=("$device")
    elif _vpn_validate_iface_name "$device"; then
      _VPN_UNMANAGED_DEVICES+=("$device")
    fi
  done
  (( ${#devices[@]} > 0 )) || return 0

  _vpn_darwin_run_dir_safe || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local run_dir="$_VPN_DARWIN_RUN_DIR"
  local -A state=() socket_time=()
  for device in "${devices[@]}"; do
    state=()
    if zstat -LH state -- "$run_dir/$device.sock" 2>/dev/null \
      && (( (state[mode] & 8#170000) == 8#140000 )); then
      socket_time[$device]="${state[mtime]}"
    fi
  done

  local name_file="" profile=""
  local -A name_time=() name_id=()
  local -a name_files=("$run_dir"/*.name(N))
  (( ${#name_files[@]} <= 4 * _VPN_MAX_ACTIVE_INTERFACES )) || return 1
  for name_file in "${name_files[@]}"; do
    profile="${${name_file:t}%.name}"
    _vpn_validate_iface_name "$profile" || continue
    state=()
    zstat -LH state -- "$name_file" 2>/dev/null || continue
    (( (state[mode] & 8#170000) == 8#100000 )) || continue
    name_time[$profile]="${state[mtime]}"
    name_id[$profile]="${state[device]}:${state[inode]}:${state[mtime]}:${state[size]}"
  done

  # wg-quick accepts a pairing only when the times differ by under 2 seconds.
  local -A profile_candidates=() device_candidates=()
  local -i time_diff=0
  for profile in "${(@k)name_time}"; do
    for device in "${(@k)socket_time}"; do
      time_diff=$(( socket_time[$device] - name_time[$profile] ))
      (( time_diff > -2 && time_diff < 2 )) || continue
      profile_candidates[$profile]+="$device "
      device_candidates[$device]+="$profile "
    done
  done

  local -A paired=() claimed=()
  local -a pending=() candidates=()
  for profile in "${(@ko)profile_candidates}"; do
    candidates=(${=profile_candidates[$profile]})
    if (( ${#candidates[@]} == 1 )) \
      && [[ "${device_candidates[${candidates[1]}]}" == "$profile " ]]; then
      paired[$profile]="${candidates[1]}"
      claimed[${candidates[1]}]="$profile"
    else
      pending+=("$profile")
    fi
  done

  # An ambiguous pairing is settled the way wg-quick settles it: by the device
  # recorded in the root-only .name file, read through non-interactive sudo.
  if (( ${#pending[@]} > 0 )); then
    _vpn_have_sudo_cache || {
      local -i cache_status=$?
      (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
      return 4
    }
    local recorded=""
    local -i read_status=0
    for profile in "${pending[@]}"; do
      read_status=0
      recorded=$(
        _vpn_sudo_probe head -c 32 -- "$run_dir/$profile.name"
      ) || read_status=$?
      (( read_status == 130 || read_status == 143 )) && return "$read_status"
      (( read_status == 0 )) || return 1
      recorded="${recorded%%$'\n'*}"
      [[ "$recorded" =~ '^utun[0-9]{1,4}$' ]] || return 1
      # A recorded device that is gone, or whose socket is older or newer by
      # two seconds or more, belongs to a stale record: wg-quick ignores it.
      [[ -n "${socket_time[$recorded]-}" ]] || continue
      time_diff=$(( socket_time[$recorded] - name_time[$profile] ))
      (( time_diff > -2 && time_diff < 2 )) || continue
      [[ -z "${claimed[$recorded]-}" ]] || return 1
      paired[$profile]="$recorded"
      claimed[$recorded]="$profile"
    done
    _VPN_DARWIN_MAP_PRIVILEGED=1
  fi

  for profile in "${(@ko)paired}"; do
    reply+=("$profile")
    _VPN_ACTIVE_DEVICES[$profile]="${paired[$profile]}"
    _VPN_ACTIVE_NAME_IDS[$profile]="${name_id[$profile]}"
  done
  for device in "${devices[@]}"; do
    [[ -n "${claimed[$device]-}" ]] || _VPN_UNMANAGED_DEVICES+=("$device")
  done
  return 0
}

# stdout: direct, sudo, or locked for live tunnel state on macOS. Listing
# devices needs no privilege; only an ambiguous pairing does.
_vpn_darwin_wg_access_state() {
  local -a reply=()
  local -i map_status=0
  _vpn_active_interfaces || map_status=$?
  case "$map_status" in
    0)
      if (( _VPN_DARWIN_MAP_PRIVILEGED )); then
        print -r -- "sudo"
      else
        print -r -- "direct"
      fi
      return 0
      ;;
    4)
      print -r -- "locked"
      return 0
      ;;
    130|143) return "$map_status" ;;
  esac

  if _vpn_have_sudo_cache; then
    print -r -- "sudo"
    return 0
  else
    local -i cache_status=$?
    (( cache_status == 130 || cache_status == 143 )) && return "$cache_status"
  fi
  print -r -- "locked"
}

# --- Network collectors -----------------------------------------------------

# stdout: the device's addresses as address/prefix, one per line, from
# ifconfig. IPv6 link-local addresses are omitted, as iproute2 omits them for
# Linux WireGuard devices.
_vpn_darwin_iface_addrs() {
  local device="${1:-}"
  [[ "$device" =~ '^utun[0-9]{1,4}$' ]] || return 1
  command -v ifconfig &>/dev/null || return 1
  local output
  output=$(
    _vpn_darwin_capture "$_VPN_MAX_PREVIEW_BYTES" command ifconfig "$device"
  ) || return 1
  print -r -- "$output" | command awk '
    function prefix_bits(mask,   hex, bits, i, value) {
      hex = tolower(mask)
      sub(/^0x/, "", hex)
      if (hex !~ /^[0-9a-f]+$/) return ""
      bits = 0
      for (i = 1; i <= length(hex); i++) {
        value = index("0123456789abcdef", substr(hex, i, 1)) - 1
        bits += (value >= 8) + (value % 8 >= 4) + (value % 4 >= 2) + (value % 2)
      }
      return bits
    }
    $1 == "inet" {
      bits = ""
      for (i = 3; i < NF; i++) if ($i == "netmask") bits = prefix_bits($(i + 1))
      print (bits == "" ? $2 : $2 "/" bits)
    }
    $1 == "inet6" {
      address = $2
      sub(/%.*/, "", address)
      if (tolower(address) ~ /^fe80:/) next
      bits = ""
      for (i = 3; i < NF; i++) if ($i == "prefixlen") bits = $(i + 1)
      print (bits == "" ? address : address "/" bits)
    }'
}

# stdout: "<address> [via <gateway>] dev <device>" for the route macOS would
# use, from route -n get. wg-quick installs 0/1 and 128/1 halves, so the
# effective route is asked for rather than read from the default entry.
_vpn_darwin_route_summary() {
  local address="${1:-}"
  _vpn_validate_ip_literal "$address" || return 1
  command -v route &>/dev/null || return 1
  local output
  output=$(_vpn_darwin_capture 16384 command route -n get "$address") || return 1
  print -r -- "$output" | command awk -v target="$address" '
    $1 == "gateway:" { gateway = $2 }
    $1 == "interface:" { device = $2 }
    END {
      if (device == "") exit 1
      line = target
      if (gateway != "") line = line " via " gateway
      print line " dev " device
    }'
}

# stdout: unique resolver addresses from scutil --dns: the default resolver #1
# first, then every scoped resolver. wg-quick sets tunnel DNS per network
# service, which scutil reports as the default resolver.
_vpn_darwin_dns_resolvers() {
  command -v scutil &>/dev/null || return 1
  local output
  output=$(
    _vpn_darwin_capture "$_VPN_MAX_PREVIEW_BYTES" command scutil --dns
  ) || return 1
  local listed=""
  listed=$(print -r -- "$output" | command awk '
    /^DNS configuration \(for scoped queries\)/ { scoped = 1; next }
    /^DNS configuration/ { scoped = 0; next }
    /^resolver #/ { resolver = $2; next }
    $1 ~ /^nameserver\[[0-9]+\]$/ && $2 == ":" {
      if (scoped || resolver == "#1") print $3
    }') || return 1

  local candidate="" address=""
  local -A seen=()
  for candidate in "${(@f)listed}"; do
    address="${candidate%%\%*}"
    _vpn_validate_ip_literal "$address" || continue
    [[ -z "${seen[$address]-}" ]] || continue
    seen[$address]=1
    print -r -- "$address"
  done
  return 0
}

typeset -g _VPN_DARWIN_SOURCED=1
