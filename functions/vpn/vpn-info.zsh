#!/usr/bin/env zsh
# =============================================================================
# VPN Info: summary, details, IP info and Markdown report
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh and vpn-state.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_VPN_INFO_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Report writers --------------------------------------------------------
# These were previously defined inside vpn-report, so nine unprefixed functions
# survived in the user's shell after a single report. They now live at file
# scope and append to the path vpn-report publishes in _VPN_REPORT_TARGET.

typeset -g _VPN_REPORT_TARGET=""
typeset -gi _VPN_REPORT_WRITE_FAILED=0

_vpn_rpt() {
  [[ -n "$_VPN_REPORT_TARGET" ]] || return 1
  print -r -- "$1" >> "$_VPN_REPORT_TARGET" || {
    _VPN_REPORT_WRITE_FAILED=1
    return 1
  }
}
_vpn_rpt_escape() {
  local value="${(V)1}"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  value="${value//\`/\\\`}"
  value="${value//\*/\\\*}"
  value="${value//_/\\_}"
  value="${value//\[/\\\[}"
  value="${value//\]/\\\]}"
  value="${value//</\\<}"
  value="${value//>/\\>}"
  print -r -- "$value"
}
_vpn_rpt_blank()       { _vpn_rpt ""; }
_vpn_rpt_h1()          { _vpn_rpt "# $1"; _vpn_rpt_blank; }
_vpn_rpt_h2()          { _vpn_rpt_blank; _vpn_rpt "## $1"; _vpn_rpt_blank; }
_vpn_rpt_h3()          { _vpn_rpt_blank; _vpn_rpt "### $1"; _vpn_rpt_blank; }
_vpn_rpt_kv()          {
  _vpn_rpt "- **$(_vpn_rpt_escape "$1"):** $(_vpn_rpt_escape "$2")"
}
_vpn_rpt_bullet()      { _vpn_rpt "- $(_vpn_rpt_escape "$1")"; }

# Captures a read-only collector without allowing hostile or broken tooling to
# make a diagnostic unbounded. stdout remains data for the caller.
_vpn_info_capture_bounded() {
  setopt LOCAL_OPTIONS PIPE_FAIL

  local -i max_bytes="${1:-0}"
  shift
  (( max_bytes > 0 && $# > 0 )) || return 2

  local captured
  captured=$(
    "$@" 2>/dev/null | command head -c "$(( max_bytes + 1 ))"
  ) || return 1
  (( ${#captured} <= max_bytes )) || return 1
  print -r -- "$captured"
}

# Writes external command output as indented Markdown code. Prefixing every
# visible line prevents an injected backtick fence from escaping the block.
_vpn_rpt_code_block() {
  local content="$1"
  local -a lines=("${(@f)content}")
  local line
  for line in "${lines[@]}"; do
    _vpn_rpt "    ${(V)line}" || return 1
  done
}

# vpn-summary
#   Arguments: --help only.
#   stdout:    none. The summary is UI and goes to stderr.
#   Effects:   read-only.
#   Status:    0 on success, 1 when the platform or WireGuard is unavailable.
vpn-summary() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-summary"
      print -u2 -r -- \
        "  Show access state, profiles, active tunnels, and cached pointers."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-summary accepts no arguments."; return 2 ;;
  esac

  _vpn_header "VPN Summary"
  _vpn_require_platform || return 1

  _vpn_state_load

  local REPLY=""
  _vpn_command_display "$(_vpn_config_dir)"
  _vpn_label "Directory" "$REPLY"
  _vpn_label "Profile access" "$(_vpn_access_label "$_VPN_MENU_CONFIG_ACCESS_STATE")"
  _vpn_label "Tunnel access" "$(_vpn_access_label "$_VPN_MENU_WG_ACCESS_STATE")"
  local sudo_text="locked"
  if ! command -v sudo &>/dev/null; then
    sudo_text="missing"
  elif (( _VPN_MENU_SUDO_UNLOCKED )); then
    sudo_text="unlocked"
  fi
  _vpn_label "Sudo" "$sudo_text"

  local active_text="locked" active_iface=""
  local -a active_items=()
  if [[ "$_VPN_MENU_WG_ACCESS_STATE" == "missing" ]]; then
    active_text="unknown (wg missing)"
  elif (( _VPN_MENU_ACTIVE_KNOWN )); then
    # macOS shows each tunnel's utun device beside its profile.
    for active_iface in "${_VPN_MENU_ACTIVE_IFACES[@]}"; do
      if _vpn_state_iface_device "$active_iface"; then
        active_items+=("$active_iface ($REPLY)")
      else
        active_items+=("$active_iface")
      fi
    done
    active_text="${(j:, :)active_items}"
    [[ -n "$active_text" ]] || active_text="none"
  fi
  REPLY=""
  _vpn_label "Active" "$active_text"
  (( ${#_VPN_MENU_UNMANAGED_DEVICES[@]} > 0 )) \
    && _vpn_label "Unmanaged" "${(j:, :)_VPN_MENU_UNMANAGED_DEVICES}"
  _vpn_label "Default" "$(_vpn_pointer_text "$_VPN_MENU_DEFAULT_IFACE")"
  _vpn_label "Last used" "$(_vpn_pointer_text "$_VPN_MENU_LAST_IFACE")"
  # The WSL workaround is reported where it can apply: on WSL, or where it was
  # forced on.
  if [[ "$_VPN_MENU_PLATFORM" == wsl ]] || (( _VPN_MENU_WSL_FIX )); then
    if (( _VPN_MENU_WSL_FIX )); then
      _vpn_label "WSL fix" "on"
    else
      _vpn_label "WSL fix" "off"
    fi
  fi

  case "$_VPN_MENU_CONFIG_ACCESS_STATE" in
    locked)
      _vpn_blank
      _vpn_dim "Profiles are locked; run 'vpn-access-unlock' to list them."
      return 0
      ;;
    missing)
      _vpn_blank
      _vpn_dim "The profile directory does not exist; create or import a profile to start."
      return 0
      ;;
  esac
  if (( ! _VPN_MENU_CONFIGS_KNOWN )); then
    _vpn_blank
    _vpn_dim "Profiles could not be listed; run 'vpn-access-status' for the cause."
    return 0
  fi
  if (( ${#_VPN_MENU_CONFIGS[@]} == 0 )); then
    _vpn_blank
    _vpn_info "No WireGuard profiles found."
    return 0
  fi

  # `status` is a read-only Zsh special parameter. The notes column appears
  # only when a profile is the default or the last used, and the device column
  # only when an active device differs from its profile name (macOS).
  local conf="" row_state="" backup_state="" row="" header="Profile"$'\t'"State"
  local -a notes=() rows=()
  local -i with_notes=0 with_device=0
  [[ -n "$_VPN_MENU_DEFAULT_IFACE$_VPN_MENU_LAST_IFACE" ]] && with_notes=1
  for conf in "${_VPN_MENU_CONFIGS[@]}"; do
    _vpn_state_iface_device "$conf" && with_device=1
  done
  for conf in "${_VPN_MENU_CONFIGS[@]}"; do
    row_state="inactive"
    if _vpn_state_iface_is_active "$conf"; then
      row_state="active"
    elif (( ! _VPN_MENU_ACTIVE_KNOWN )); then
      row_state="unknown"
    fi
    backup_state=$(_vpn_state_iface_backup_state "$conf")
    notes=()
    [[ "$conf" == "$_VPN_MENU_DEFAULT_IFACE" ]] && notes+=("default")
    [[ "$conf" == "$_VPN_MENU_LAST_IFACE" ]] && notes+=("last used")
    row="$conf"$'\t'"$row_state"
    if (( with_device )); then
      REPLY=""
      _vpn_state_iface_device "$conf" || true
      row+=$'\t'"$REPLY"
    fi
    row+=$'\t'"$backup_state"
    (( with_notes )) && row+=$'\t'"${(j:, :)notes}"
    rows+=("$row")
  done
  (( with_device )) && header+=$'\t'"Device"
  header+=$'\t'"Backup"
  (( with_notes )) && header+=$'\t'"Notes"
  _vpn_blank
  _vpn_table "$header" "${rows[@]}"
}

# Prints one report section per active tunnel with its bounded `wg show`
# excerpt, or one line when no tunnel is up. vpn-details and the tunnel
# commands share it so a tunnel change shows its resulting state under the
# command's own heading. --first marks a call that directly follows a heading.
# Status: 0 when shown or inaccessible, 1 when wg is missing, 130 or 143 when
# authentication is interrupted.
_vpn_details_sections() {
  local first_flag=""
  [[ "${1:-}" == --first ]] && first_flag="--first"
  _vpn_check_wg || return 1

  local -a reply=()
  local -a active_ifaces=()
  local -i active_known=0
  if _vpn_active_interfaces; then
    active_known=1
    active_ifaces=("${reply[@]}")
  elif [[ "$(_vpn_wg_access_state)" == "locked" ]]; then
    first_flag=""
    local -i access_rc=0
    _vpn_ensure_wg_access || access_rc=$?
    (( access_rc == 130 || access_rc == 143 )) && return "$access_rc"
    if (( access_rc == 0 )); then
      reply=()
      if _vpn_active_interfaces; then
        active_known=1
        active_ifaces=("${reply[@]}")
      fi
    fi
  fi

  if (( ! active_known )); then
    _vpn_warn "WireGuard details unavailable without readable wg state."
    _vpn_dim "Use 'vpn-access-unlock' and retry to inspect active interfaces."
    return 0
  fi
  local -a unmanaged=("${_VPN_UNMANAGED_DEVICES[@]}")
  if (( ${#active_ifaces[@]} == 0 )); then
    _vpn_info "No active WireGuard tunnels."
    (( ${#unmanaged[@]} > 0 )) && _vpn_dim \
      "Devices without a wg-quick profile are not managed here: ${(j:, :)unmanaged}."
    return 0
  fi

  # Per-interface 'wg show <device>' often needs root even when the bare
  # 'wg show interfaces' listing succeeds (common on WSL, always on macOS).
  # Unlock sudo best-effort so detailed state is available when the user
  # authenticates; do not abort the whole command if the prompt is declined.
  local REPLY=""
  _vpn_tunnel_device "${active_ifaces[1]}" || REPLY="${active_ifaces[1]}"
  if ! _vpn_run_wg show "$REPLY" &>/dev/null \
    && ! _vpn_have_sudo_cache; then
    first_flag=""
    _vpn_warn "Detailed interface state requires sudo."
    local -i sudo_rc=0
    _vpn_ensure_sudo_access "Reading WireGuard interface details" || sudo_rc=$?
    (( sudo_rc == 130 || sudo_rc == 143 )) && return "$sudo_rc"
  fi

  local iface="" details="" line=""
  for iface in "${active_ifaces[@]}"; do
    _vpn_section $first_flag "$iface"
    first_flag=""
    if _vpn_tunnel_device "$iface" && [[ "$REPLY" != "$iface" ]]; then
      _vpn_label "Device" "$REPLY"
    fi
    if ! details=$(
      _vpn_info_capture_bounded \
        "$_VPN_MAX_PREVIEW_BYTES" _vpn_get_iface_details "$iface"
    ); then
      _vpn_warn "Could not read detailed state for $iface."
      _vpn_dim \
        "The state was inaccessible or exceeded the diagnostic safety limit."
    elif [[ -n "$details" ]]; then
      for line in "${(@f)details}"; do
        _vpn_dim "│ $line"
      done
    fi
  done
  if (( ${#unmanaged[@]} > 0 )); then
    _vpn_blank
    _vpn_dim \
      "Devices without a wg-quick profile are not managed here: ${(j:, :)unmanaged}."
  fi
  return 0
}

# vpn-details
#   Arguments: --help only.
#   stdout:    none. Interface state is UI and goes to stderr.
#   Effects:   read-only. May request sudo once to read per-interface state.
#   Status:    0 on success or inaccessible live state, 1 when wg is missing,
#              130 or 143 when authentication is interrupted.
vpn-details() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-details"
      print -u2 -r -- "  Show detailed WireGuard state for each active tunnel."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-details accepts no arguments."; return 2 ;;
  esac

  _vpn_header "VPN Details"
  _vpn_details_sections --first
}

# vpn-ip-info
#   Arguments: --help only.
#   stdout:    none. All findings are UI and go to stderr.
#   Effects:   read-only, but performs outbound network lookups.
#   Requires:  curl and jq for the public exit section.
#   Status:    0 after a best-effort diagnostic, 2 on bad arguments.
vpn-ip-info() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-ip-info"
      print -u2 -r -- \
        "  Show tunnel addresses, endpoint, handshake, public exit, and DNS."
      print -u2 -r -- \
        "  Set VPN_MENU_IP_CROSSCHECK=1 to compare the exit IP across providers."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-ip-info accepts no arguments."; return 2 ;;
  esac

  _vpn_header "VPN IP & Exit Info"

  local -a reply=()
  local -a active_ifaces=()
  local -i active_known=0
  if command -v wg &>/dev/null; then
    if _vpn_active_interfaces; then
      active_known=1
      active_ifaces=("${reply[@]}")
    else
      _vpn_warn "Live WireGuard state is locked or unavailable."
    fi
  else
    _vpn_warn "WireGuard (wg) is not installed; tunnel state is unavailable."
  fi

  # Per-tunnel details may need sudo even when the device listing works.
  # Prompt best-effort so the tunnel section is useful.
  local first_flag="--first" REPLY=""
  if [[ ${#active_ifaces[@]} -gt 0 ]]; then
    _vpn_tunnel_device "${active_ifaces[1]}" || REPLY="${active_ifaces[1]}"
    if ! _vpn_run_wg show "$REPLY" &>/dev/null && ! _vpn_have_sudo_cache; then
      first_flag=""
      _vpn_warn "Detailed tunnel state requires sudo."
      _vpn_ensure_sudo_access "Reading WireGuard tunnel state" || true
    fi
  fi

  # --- Tunnel section ------------------------------------------------------
  if (( ! active_known )); then
    _vpn_warn "Could not determine whether a WireGuard interface is active."
    _vpn_dim "The public exit and DNS sections remain available."
  elif [[ ${#active_ifaces[@]} -eq 0 ]]; then
    _vpn_warn "No active WireGuard interfaces detected."
    _vpn_dim "Traffic exits through the host network stack."
  else
    local iface addr_lines addr_joined endpoint hs_ts rx_tx rx tx dns_line
    local -a addr_array
    for iface in "${active_ifaces[@]}"; do
      _vpn_section $first_flag "$iface"
      first_flag=""
      addr_lines=$(_vpn_iface_internal_addrs "$iface" 2>/dev/null)
      addr_array=(${(@f)addr_lines})
      addr_joined="${(j:, :)addr_array}"
      endpoint=$(_vpn_iface_endpoint "$iface" 2>/dev/null)
      hs_ts=$(_vpn_iface_latest_handshake "$iface" 2>/dev/null)
      rx_tx=$(_vpn_iface_transfer "$iface" 2>/dev/null)
      rx="${rx_tx%%$'\t'*}"
      tx="${rx_tx##*$'\t'}"
      dns_line=$(_vpn_dns_from_conf "$iface" 2>/dev/null)

      if _vpn_tunnel_device "$iface" && [[ "$REPLY" != "$iface" ]]; then
        _vpn_label "Device" "$REPLY"
      fi
      _vpn_label "Internal IP" "${addr_joined:-(unknown)}"
      _vpn_label "Endpoint" "${endpoint:-(unknown)}"
      _vpn_label "Handshake" "$(_vpn_human_age "${hs_ts:-0}")"
      _vpn_label "Transfer" "↓ $(_vpn_human_bytes "${rx:-0}")  ↑ $(_vpn_human_bytes "${tx:-0}")"
      [[ -n "$dns_line" ]] && _vpn_label "Tunnel DNS" "$dns_line"
    done
  fi

  # --- Public exit section -------------------------------------------------
  _vpn_section "Public exit"
  if (( ${#active_ifaces[@]} > 0 )); then
    local route route_tool="ip"
    _vpn_platform_is darwin && route_tool="route"
    route=$(_vpn_default_route 2>/dev/null)
    route="${route%"${route##*[^[:space:]]}"}"
    _vpn_label "Default route" "${route:-unknown ($route_tool unavailable)}"
  fi

  if ! _vpn_have_ip_stack; then
    _vpn_warn "jq or curl not available; skipping public IP lookup."
    return 0
  fi

  _vpn_info "Querying public IP providers..."

  local info ip city region country org provider
  info=$(_vpn_get_ip_info)
  if [[ -z "$info" ]]; then
    _vpn_warn "Could not fetch public IP from any provider."
    _vpn_dim "JSON tried:  $(_vpn_ipinfo_json_providers)"
    _vpn_dim "Plain tried: $(_vpn_ipinfo_plain_providers)"
    _vpn_dim "Trace tried: $(_vpn_ipinfo_trace_providers)"
    _vpn_dim "Override via VPN_MENU_IPINFO_URLS / VPN_MENU_IPINFO_PLAIN_URLS / VPN_MENU_IPINFO_TRACE_URLS."
    return 0
  fi

  # zsh's `read` collapses consecutive whitespace IFS chars, losing empty
  # TSV fields. Use the (@s) splitting operator, which preserves them.
  local -a info_fields
  info_fields=("${(@s:	:)info}")
  ip="${info_fields[1]:-}"
  city="${info_fields[2]:-}"
  region="${info_fields[3]:-}"
  country="${info_fields[4]:-}"
  org="${info_fields[5]:-}"
  provider="${info_fields[6]:-}"

  _vpn_label "IP" "${ip:-(unknown)}"

  local -a loc_parts=()
  [[ -n "$city" ]] && loc_parts+=("$city")
  [[ -n "$region" && "$region" != "$city" ]] && loc_parts+=("$region")
  [[ -n "$country" ]] && loc_parts+=("$country")
  if (( ${#loc_parts[@]} > 0 )); then
    _vpn_label "Location" "${(j:, :)loc_parts}"
  else
    _vpn_label "Location" "(not reported)"
  fi

  [[ -n "$org" ]] && _vpn_label "ISP / org" "$org"
  _vpn_label "Provider" "$provider"

  # --- Cross-check (opt-in) ------------------------------------------------
  if [[ "${VPN_MENU_IP_CROSSCHECK:-0}" == 1 ]]; then
    _vpn_info "Cross-checking the exit IP across providers..."
    local cc_raw p_host p_ip marker
    local -a cc_rows=()
    local -i differs=0
    cc_raw=$(_vpn_get_ip_crosscheck)
    while IFS=$'\t' read -r p_host p_ip; do
      [[ -n "$p_ip" ]] || continue
      if [[ "$p_ip" == "$ip" ]]; then
        marker="match"
      else
        marker="differs"
        (( differs += 1 ))
      fi
      cc_rows+=("$p_host"$'\t'"$p_ip"$'\t'"$marker")
    done <<< "$cc_raw"
    if (( ${#cc_rows[@]} == 0 )); then
      _vpn_warn "Cross-check: no providers answered."
    else
      _vpn_blank
      _vpn_table $'Provider\tIP\tResult' "${cc_rows[@]}"
      if (( differs > 0 )); then
        local REPLY=""
        _vpn_count_noun "$differs" provider
        _vpn_warn "Cross-check: $REPLY reported a different exit IP."
      fi
    fi
  else
    _vpn_dim "Cross-check off. Set VPN_MENU_IP_CROSSCHECK=1 to verify the IP against all providers."
  fi

  # --- DNS resolvers -------------------------------------------------------
  _vpn_section "DNS resolvers"
  local resolvers r dns_count=0
  resolvers=$(
    _vpn_info_capture_bounded \
      "$_VPN_MAX_PREVIEW_BYTES" _vpn_dns_resolvers
  ) || resolvers=""
  if [[ -n "$resolvers" ]]; then
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      _vpn_label "Nameserver" "$r"
      dns_count=$(( dns_count + 1 ))
    done <<< "$resolvers"
  fi
  local dns_source
  dns_source=$(_vpn_dns_source_label)
  (( dns_count == 0 )) && _vpn_dim "No $dns_source nameservers detected."

  # --- DNS leak heuristic --------------------------------------------------
  # Compares each active tunnel's configured DNS with the system resolvers
  # (/etc/resolv.conf, or scutil --dns on macOS). The likely cause differs by
  # platform: a Windows relay on WSL, a local stub resolver such as
  # systemd-resolved on Linux, and the resolver order on macOS. Non-blocking
  # hint only.
  if [[ ${#active_ifaces[@]} -gt 0 && -n "$resolvers" ]]; then
    local iface_leak tunnel_dns tunnel_dns_tok leak_tok leaks_seen=0
    local -a tunnel_dns_list resolver_list
    resolver_list=(${(@f)resolvers})
    for iface_leak in "${active_ifaces[@]}"; do
      tunnel_dns=$(_vpn_dns_from_conf "$iface_leak" 2>/dev/null)
      [[ -n "$tunnel_dns" ]] || continue
      # Split on comma and whitespace; keep only non-empty tokens.
      tunnel_dns_list=(${=${tunnel_dns//,/ }})
      [[ ${#tunnel_dns_list[@]} -gt 0 ]] || continue
      local any_match=0
      for tunnel_dns_tok in "${tunnel_dns_list[@]}"; do
        [[ -n "$tunnel_dns_tok" ]] || continue
        for leak_tok in "${resolver_list[@]}"; do
          [[ "$tunnel_dns_tok" == "$leak_tok" ]] && { any_match=1; break; }
        done
        (( any_match )) && break
      done
      if (( !any_match )); then
        leaks_seen=1
        _vpn_warn "Tunnel DNS for $iface_leak ($tunnel_dns) not present in $dns_source."
      fi
    done
    if (( leaks_seen )); then
      _vpn_dns_leak_hint
    fi
  fi

  _vpn_blank
  _vpn_dim "Use 'vpn-report' to persist a full diagnostic Markdown under ~/vpn-stats."
}

# One platform-specific explanation for a tunnel DNS that the system
# resolvers do not list.
_vpn_dns_leak_hint() {
  case "$(_vpn_platform)" in
    wsl)
      _vpn_dim "Possible DNS leak — WSL typically routes DNS via a Windows relay."
      ;;
    darwin)
      _vpn_dim "Possible DNS leak — macOS is not resolving through the tunnel DNS; check 'scutil --dns'."
      ;;
    *)
      _vpn_dim "Possible DNS leak — or a local stub resolver such as systemd-resolved; check 'resolvectl dns'."
      ;;
  esac
}

# vpn-report
#   Arguments: --help only.
#   stdout:    none. The report path is reported on stderr.
#   Effects:   writes one owner-only Markdown report under $VPN_MENU_REPORT_DIR
#              and performs live network lookups.
#   Requires:  curl and jq.
#   Status:    0 on success, 1 on failure.
vpn-report() {
  case "${1:-}" in
    -h|--help)
      print -u2 -r -- "Usage: vpn-report"
      print -u2 -r -- \
        "  Write a Markdown diagnostic report under \$VPN_MENU_REPORT_DIR."
      print -u2 -r -- \
        "  The report contains the public exit IP, geolocation, and resolvers,"
      print -u2 -r -- "  so it is created mode 600 in an owner-only directory."
      return 0
      ;;
    "") ;;
    *) _vpn_error "vpn-report accepts no arguments."; return 2 ;;
  esac

  _vpn_header "VPN Diagnostic Report"
  local REPLY
  _vpn_report_retention_value || return 2
  _vpn_require_platform || return 1
  _vpn_check_ip_stack || return 1

  local report_temp
  report_temp=$(_vpn_report_temp_create) || {
    _vpn_error "Could not create a private report temporary."
    _vpn_info "Set VPN_MENU_REPORT_DIR to a writable directory inside your home."
    return 1
  }

  local report_dir="${report_temp:h}"
  local report_file="$report_temp"
  local _VPN_REPORT_TARGET="$report_temp"
  local -i _VPN_REPORT_WRITE_FAILED=0

  _vpn_command_display "$report_dir"
  _vpn_label "Report directory" "$REPLY"

  {

  # --- Header --------------------------------------------------------------
  local host_full user kernel is_wsl platform
  host_full=$(
    _vpn_info_capture_bounded 512 command hostname
  ) || host_full="unknown"
  user="${USER:-}"
  if [[ -z "$user" ]]; then
    user=$(_vpn_info_capture_bounded 256 command id -un) || user="unknown"
  fi
  kernel=$(
    _vpn_info_capture_bounded 512 command uname -sr
  ) || kernel="unknown"
  # The report uses the suite's one WSL detector, as the platform gate does.
  platform=$(_vpn_platform)
  if [[ "$platform" == wsl ]]; then
    is_wsl="yes${WSL_DISTRO_NAME:+ (${WSL_DISTRO_NAME})}"
  else
    is_wsl="no"
  fi

  _vpn_rpt_h1 "VPN Diagnostic Report" || {
    _vpn_error "Could not initialize the report content."
    return 1
  }
  _vpn_rpt_kv "Generated" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  _vpn_rpt_kv "Host" "$host_full"
  _vpn_rpt_kv "User" "$user"
  _vpn_rpt_kv "Kernel" "$kernel"
  _vpn_rpt_kv "Platform" "$platform"
  _vpn_rpt_kv "WSL" "$is_wsl"

  # --- Environment ---------------------------------------------------------
  _vpn_info "Collecting environment..."

  local wg_ver wgquick_ver curl_ver jq_ver py_ver
  wg_ver=$(_vpn_info_capture_bounded 1024 command wg --version) || wg_ver=""
  wg_ver="${wg_ver%%$'\n'*}"
  wgquick_ver=$(
    _vpn_info_capture_bounded 1024 command wg-quick --version
  ) || wgquick_ver=""
  wgquick_ver="${wgquick_ver%%$'\n'*}"
  curl_ver=$(
    _vpn_info_capture_bounded 1024 command curl --version
  ) || curl_ver=""
  curl_ver="${curl_ver%%$'\n'*}"
  jq_ver=$(_vpn_info_capture_bounded 1024 command jq --version) || jq_ver=""
  jq_ver="${jq_ver%%$'\n'*}"
  py_ver=$(
    _vpn_info_capture_bounded 1024 command python3 --version
  ) || py_ver=""
  py_ver="${py_ver%%$'\n'*}"

  _vpn_rpt_h2 "Environment"
  _vpn_rpt_kv "wg" "${wg_ver:-(not installed)}"
  _vpn_rpt_kv "wg-quick" "${wgquick_ver:-(not installed)}"
  _vpn_rpt_kv "curl" "${curl_ver:-(not installed)}"
  _vpn_rpt_kv "jq" "${jq_ver:-(not installed)}"
  _vpn_rpt_kv "python3" "${py_ver:-(not installed)}"
  _vpn_rpt_kv "Non-interactive sudo" \
    "$(_vpn_have_sudo_cache \
      && print -r -- available || print -r -- unavailable)"
  _vpn_rpt_kv "Profile access" "$(_vpn_configs_access_state)"
  _vpn_rpt_kv "Tunnel access" "$(_vpn_wg_access_state)"
  if [[ "$platform" == wsl ]]; then
    _vpn_rpt_kv "WSL networking" "$(_vpn_wsl_networking_mode)"
  fi
  _vpn_should_apply_wsl_ipv6_fix && _vpn_rpt_kv "WSL IPv6 fix" "enabled"
  if [[ "$platform" == darwin ]]; then
    # wg-quick on macOS runs through an explicit Bash 4 or newer.
    local bash_used="(missing: Bash 4 or newer)"
    if _vpn_darwin_bash4; then
      bash_used="$REPLY"
      _vpn_darwin_bash_version && bash_used+=" (major $REPLY)"
    fi
    _vpn_rpt_kv "Bash for wg-quick" "$bash_used"
  fi

  # --- Profiles ------------------------------------------------------------
  _vpn_info "Collecting profile inventory..."

  _vpn_rpt_h2 "Profiles"
  _vpn_state_load
  if [[ "$_VPN_MENU_CONFIG_ACCESS_STATE" == "missing" ]]; then
    _vpn_rpt_bullet "WireGuard profile directory is missing: $(_vpn_config_dir)"
  elif (( !_VPN_MENU_CONFIGS_KNOWN )); then
    _vpn_rpt_bullet "Profile directory locked; run 'sudo -v' and retry to inventory."
  elif [[ ${#_VPN_MENU_CONFIGS[@]} -eq 0 ]]; then
    _vpn_rpt_bullet "No profiles found in $(_vpn_config_dir)."
  else
    _vpn_rpt_kv "Profile dir" "$(_vpn_config_dir)"
    _vpn_rpt_kv "Total" "${#_VPN_MENU_CONFIGS[@]}"
    [[ -n "$_VPN_MENU_DEFAULT_IFACE" ]] && _vpn_rpt_kv "Default" "$_VPN_MENU_DEFAULT_IFACE"
    [[ -n "$_VPN_MENU_LAST_IFACE" ]] && _vpn_rpt_kv "Last used" "$_VPN_MENU_LAST_IFACE"
    _vpn_rpt_blank
    _vpn_rpt "| Profile | State | Backup | Notes |"
    _vpn_rpt "|---------|-------|--------|-------|"
    local conf state backup notes
    for conf in "${_VPN_MENU_CONFIGS[@]}"; do
      state="inactive"
      _vpn_state_iface_is_active "$conf" && state="active"
      backup=$(_vpn_state_iface_backup_state "$conf")
      notes=""
      [[ "$conf" == "$_VPN_MENU_DEFAULT_IFACE" ]] && notes+="default "
      [[ "$conf" == "$_VPN_MENU_LAST_IFACE" ]] && notes+="last-used "
      [[ -z "$notes" ]] && notes="—"
      _vpn_rpt "| $conf | $state | $backup | ${notes% } |"
    done
  fi

  # --- Active interfaces ---------------------------------------------------
  _vpn_info "Collecting active interface details..."

  _vpn_rpt_h2 "Active interfaces"

  local -a active_list=()
  local -a reply=()
  if _vpn_active_interfaces; then
    active_list=("${reply[@]}")
  fi

  if [[ ${#active_list[@]} -eq 0 ]]; then
    if [[ "$(_vpn_wg_access_state)" == "locked" ]]; then
      _vpn_rpt_bullet "Tunnel state is locked behind sudo."
    else
      _vpn_rpt_bullet "No active WireGuard tunnels."
    fi
  else
    _vpn_rpt_kv "Active count" "${#active_list[@]}"
    local iface addr_lines addr_joined endpoint hs_ts rx_tx rx tx dns_line wg_out
    local -a addr_arr
    for iface in "${active_list[@]}"; do
      _vpn_rpt_h3 "Interface: \`$iface\`"
      if _vpn_tunnel_device "$iface" && [[ "$REPLY" != "$iface" ]]; then
        _vpn_rpt_kv "Device" "$REPLY"
      fi
      addr_lines=$(_vpn_iface_internal_addrs "$iface" 2>/dev/null)
      addr_arr=(${(@f)addr_lines})
      addr_joined="${(j:, :)addr_arr}"
      endpoint=$(_vpn_iface_endpoint "$iface" 2>/dev/null)
      hs_ts=$(_vpn_iface_latest_handshake "$iface" 2>/dev/null)
      rx_tx=$(_vpn_iface_transfer "$iface" 2>/dev/null)
      rx="${rx_tx%%$'\t'*}"
      tx="${rx_tx##*$'\t'}"
      dns_line=$(_vpn_dns_from_conf "$iface" 2>/dev/null)

      _vpn_rpt_kv "Internal IP" "${addr_joined:-(unknown)}"
      _vpn_rpt_kv "Endpoint" "${endpoint:-(unknown)}"
      _vpn_rpt_kv "Last handshake" "$(_vpn_human_age "${hs_ts:-0}")"
      _vpn_rpt_kv "Transfer" "↓ $(_vpn_human_bytes "${rx:-0}") / ↑ $(_vpn_human_bytes "${tx:-0}")"
      [[ -n "$dns_line" ]] && _vpn_rpt_kv "Tunnel DNS" "$dns_line"

      wg_out=$(
        _vpn_info_capture_bounded \
          "$_VPN_MAX_PREVIEW_BYTES" _vpn_get_iface_details "$iface"
      ) || wg_out=""
      if [[ -n "$wg_out" ]]; then
        _vpn_rpt_blank
        REPLY="$iface"
        _vpn_tunnel_device "$iface" || REPLY="$iface"
        _vpn_rpt "**wg show \`$REPLY\`:**"
        _vpn_rpt_blank
        _vpn_rpt_code_block "$wg_out" || _VPN_REPORT_WRITE_FAILED=1
      fi
    done
  fi

  # --- Routing -------------------------------------------------------------
  _vpn_info "Collecting routing snapshot..."

  _vpn_rpt_h2 "Routing"
  if [[ "$platform" == darwin ]]; then
    _vpn_report_darwin_routing
  elif command -v ip &>/dev/null; then
    local route_cf route_goog default_routes
    route_cf=$(
      _vpn_info_capture_bounded \
        "$_VPN_MAX_PREVIEW_BYTES" command ip route get 1.1.1.1
    ) || route_cf=""
    route_goog=$(
      _vpn_info_capture_bounded \
        "$_VPN_MAX_PREVIEW_BYTES" command ip route get 8.8.8.8
    ) || route_goog=""
    default_routes=$(
      _vpn_info_capture_bounded \
        "$_VPN_MAX_PREVIEW_BYTES" command ip route show default
    ) || default_routes=""

    if [[ -n "$default_routes" ]]; then
      _vpn_rpt "**Default routes:**"
      _vpn_rpt_blank
      _vpn_rpt_code_block "$default_routes" || _VPN_REPORT_WRITE_FAILED=1
    fi
    if [[ -n "$route_cf" ]]; then
      _vpn_rpt_blank
      _vpn_rpt "**ip route get 1.1.1.1:**"
      _vpn_rpt_blank
      _vpn_rpt_code_block "$route_cf" || _VPN_REPORT_WRITE_FAILED=1
    fi
    if [[ -n "$route_goog" ]]; then
      _vpn_rpt_blank
      _vpn_rpt "**ip route get 8.8.8.8:**"
      _vpn_rpt_blank
      _vpn_rpt_code_block "$route_goog" || _VPN_REPORT_WRITE_FAILED=1
    fi
  else
    _vpn_rpt_bullet "\`ip\` command not available."
  fi

  # --- DNS -----------------------------------------------------------------
  _vpn_rpt_h2 "DNS resolvers"
  local resolvers r
  resolvers=$(
    _vpn_info_capture_bounded \
      "$_VPN_MAX_PREVIEW_BYTES" _vpn_dns_resolvers
  ) || resolvers=""
  local dns_source
  dns_source=$(_vpn_dns_source_label)
  if [[ -n "$resolvers" ]]; then
    _vpn_rpt "**$dns_source:**"
    _vpn_rpt_blank
    while IFS= read -r r; do
      [[ -n "$r" ]] && _vpn_rpt_bullet "$r"
    done <<< "$resolvers"
  else
    _vpn_rpt_bullet "No $dns_source nameservers detected."
  fi
  if command -v resolvectl &>/dev/null; then
    local resolvectl_out
    resolvectl_out=$(
      _vpn_info_capture_bounded \
        "$_VPN_MAX_PREVIEW_BYTES" command resolvectl dns
    ) || resolvectl_out=""
    if [[ -n "$resolvectl_out" ]]; then
      _vpn_rpt_blank
      _vpn_rpt "**resolvectl dns:**"
      _vpn_rpt_blank
      _vpn_rpt_code_block "$resolvectl_out" || _VPN_REPORT_WRITE_FAILED=1
    fi
  fi

  # --- Public exit ---------------------------------------------------------
  _vpn_info "Querying public IP providers..."

  _vpn_rpt_h2 "Public exit"
  local info ip city region country org provider
  info=$(_vpn_get_ip_info)
  if [[ -z "$info" ]]; then
    _vpn_rpt_bullet "Could not fetch public IP from any provider."
    _vpn_rpt_bullet "JSON tried: $(_vpn_ipinfo_json_providers)"
    _vpn_rpt_bullet "Plain tried: $(_vpn_ipinfo_plain_providers)"
    _vpn_rpt_bullet "Trace tried: $(_vpn_ipinfo_trace_providers)"
  else
    local -a info_fields
    info_fields=("${(@s:	:)info}")
    ip="${info_fields[1]:-}"
    city="${info_fields[2]:-}"
    region="${info_fields[3]:-}"
    country="${info_fields[4]:-}"
    org="${info_fields[5]:-}"
    provider="${info_fields[6]:-}"

    _vpn_rpt_kv "IP" "${ip:-(unknown)}"
    local -a loc_parts=()
    [[ -n "$city" ]] && loc_parts+=("$city")
    [[ -n "$region" && "$region" != "$city" ]] && loc_parts+=("$region")
    [[ -n "$country" ]] && loc_parts+=("$country")
    if (( ${#loc_parts[@]} > 0 )); then
      _vpn_rpt_kv "Location" "${(j:, :)loc_parts}"
    fi
    [[ -n "$org" ]] && _vpn_rpt_kv "ISP / org" "$org"
    _vpn_rpt_kv "Provider" "$provider"
  fi

  # Cross-check is always on in reports — thoroughness wins over speed here.
  _vpn_info "Cross-checking IP across all providers..."

  _vpn_rpt_h3 "Cross-check (all providers)"
  local cc_raw
  cc_raw=$(_vpn_get_ip_crosscheck)
  if [[ -n "$cc_raw" ]]; then
    _vpn_rpt "| Provider | IP |"
    _vpn_rpt "|----------|-----|"
    local p_host p_ip
    while IFS=$'\t' read -r p_host p_ip; do
      [[ -n "$p_ip" ]] || continue
      _vpn_rpt "| $p_host | $p_ip |"
    done <<< "$cc_raw"
  else
    _vpn_rpt_bullet "No providers answered the cross-check."
  fi

  # --- Closing -------------------------------------------------------------
  _vpn_rpt_h2 "Closing"
  _vpn_rpt_kv "Finished" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  _vpn_rpt_bullet "Host: **$host_full**"
  [[ "$platform" == wsl && -n "${WSL_DISTRO_NAME-}" ]] \
    && _vpn_rpt_bullet "WSL distro: **${WSL_DISTRO_NAME}**"

  if (( _VPN_REPORT_WRITE_FAILED )); then
    _vpn_error "The report could not be written completely."
    return 1
  fi

  _vpn_report_publish "$report_temp" "vpn-report" "md" || {
    _vpn_error "Could not publish the completed report."
    return 1
  }
  report_file="$REPLY"
  report_temp=""
  _VPN_REPORT_TARGET=""

  _vpn_success "Report written."
  _vpn_command_display "$report_file"
  _vpn_label "File" "$REPLY"
  _vpn_label "View" "$(_vpn_report_view_hint "$REPLY")"
  _vpn_report_prune "$report_file" "vpn-report" "md" || _vpn_warn \
    "Old-report retention did not complete; existing reports were kept."
  return 0
  } always {
    _VPN_REPORT_TARGET=""
    if [[ -n "$report_temp" && -e "$report_temp" && ! -L "$report_temp" ]] \
      && _vpn_state_validate_file \
        "$report_temp" "$report_dir" "report temporary cleanup" \
        "$_VPN_MAX_REPORT_BYTES" 2>/dev/null; then
      command rm -f -- "$report_temp" 2>/dev/null
    fi
  }
}

# Appends the macOS routing snapshot: the effective routes for two public
# addresses, which wg-quick's 0/1 and 128/1 halves decide, and the bounded
# IPv4 and IPv6 routing tables.
_vpn_report_darwin_routing() {
  local target="" captured=""
  local -i written=0
  if command -v route &>/dev/null; then
    for target in 1.1.1.1 8.8.8.8; do
      captured=$(
        _vpn_info_capture_bounded \
          "$_VPN_MAX_PREVIEW_BYTES" command route -n get "$target"
      ) || captured=""
      [[ -n "$captured" ]] || continue
      (( written )) && _vpn_rpt_blank
      _vpn_rpt "**route -n get $target:**"
      _vpn_rpt_blank
      _vpn_rpt_code_block "$captured" || _VPN_REPORT_WRITE_FAILED=1
      written=1
    done
  fi
  if command -v netstat &>/dev/null; then
    local family=""
    for family in inet inet6; do
      captured=$(
        _vpn_info_capture_bounded \
          "$_VPN_MAX_PREVIEW_BYTES" command netstat -rn -f "$family"
      ) || captured=""
      [[ -n "$captured" ]] || continue
      (( written )) && _vpn_rpt_blank
      _vpn_rpt "**netstat -rn -f $family:**"
      _vpn_rpt_blank
      _vpn_rpt_code_block "$captured" || _VPN_REPORT_WRITE_FAILED=1
      written=1
    done
  fi
  (( written )) || _vpn_rpt_bullet "\`route\` and \`netstat\` returned no routing data."
}

_vpn_ipinfo_json_providers() {
  if [[ -n "${VPN_MENU_IPINFO_URLS:-}" ]]; then
    print -r -- "${VPN_MENU_IPINFO_URLS//,/ }"
  elif [[ -n "${VPN_MENU_IPINFO_URL:-}" ]]; then
    print -r -- "$VPN_MENU_IPINFO_URL"
  else
    print -r -- "https://ipinfo.io/json https://ifconfig.co/json https://ipapi.co/json"
  fi
}

_vpn_ipinfo_plain_providers() {
  if [[ -v VPN_MENU_IPINFO_PLAIN_URLS ]]; then
    print -r -- "${VPN_MENU_IPINFO_PLAIN_URLS//,/ }"
  else
    print -r -- "https://icanhazip.com https://ifconfig.me"
  fi
}

# Trace-format providers are hit by IP-direct URLs when possible, bypassing
# DNS. Useful when WSL's /etc/resolv.conf points outside the tunnel and all
# hostname-based providers fail. Cloudflare's trace endpoint returns
# key=value lines with at least ip=, loc= (country code) and colo= (edge).
_vpn_ipinfo_trace_providers() {
  if [[ -v VPN_MENU_IPINFO_TRACE_URLS ]]; then
    print -r -- "${VPN_MENU_IPINFO_TRACE_URLS//,/ }"
  else
    print -r -- "https://1.1.1.1/cdn-cgi/trace"
  fi
}

_vpn_load_provider_urls() {
  local provider_function="$1"
  reply=()

  local raw
  raw=$("$provider_function") || return 1
  (( ${#raw} <= 16384 )) || {
    _vpn_warn "VPN provider configuration exceeds the safety limit."
    return 1
  }

  local url
  for url in ${=raw}; do
    if ! _vpn_validate_provider_url "$url"; then
      _vpn_warn "Ignoring an invalid HTTPS provider URL."
      continue
    fi
    reply+=("$url")
    (( ${#reply[@]} <= 8 )) || {
      _vpn_warn "VPN provider configuration exceeds eight URLs."
      reply=()
      return 1
    }
  done
  (( ${#reply[@]} > 0 ))
}

_vpn_curl_bounded() {
  local url="$1"
  local max_time="${2:-5}"
  local connect_timeout="${3:-3}"
  _vpn_validate_provider_url "$url" || return 1

  command curl -fsS \
    --proto '=https' \
    --proto-redir '=https' \
    --max-filesize "$_VPN_MAX_NETWORK_BYTES" \
    --max-time "$max_time" \
    --connect-timeout "$connect_timeout" \
    -- "$url"
}

# stdout: the validated URL authority only, without a path, query, or fragment.
# Provider URLs may carry sensitive query parameters, so display and report
# labels must never derive the host with a slash-only suffix trim.
_vpn_provider_authority() {
  local url="${1:-}"
  _vpn_validate_provider_url "$url" || return 1

  local authority="${url#https://}"
  authority="${authority%%/*}"
  authority="${authority%%\?*}"
  authority="${authority%%\#*}"
  [[ -n "$authority" ]] || return 1
  print -r -- "$authority"
}

# Cascades through JSON providers, then plain-text providers, then trace
# providers (IP-direct, DNS-free), returning the first successful response.
# Output format (TSV, one line):
#   ip \t city \t region \t country \t org \t provider_host
_vpn_get_ip_info() {
  local url raw parsed host
  local -a json_providers plain_providers trace_providers
  local -a reply=()
  _vpn_load_provider_urls _vpn_ipinfo_json_providers \
    && json_providers=("${reply[@]}")
  reply=()
  _vpn_load_provider_urls _vpn_ipinfo_plain_providers \
    && plain_providers=("${reply[@]}")
  reply=()
  _vpn_load_provider_urls _vpn_ipinfo_trace_providers \
    && trace_providers=("${reply[@]}")

  for url in "${json_providers[@]}"; do
    raw=$(_vpn_curl_bounded "$url" 5 3 2>/dev/null) || continue
    [[ -n "$raw" ]] || continue
    # A missing field must stay an empty column: `empty` would shift every
    # later value into the wrong position.
    parsed=$(print -r -- "$raw" | jq -r '
      [
        .ip // "",
        .city // "",
        (.region // .region_name // ""),
        (.country_name // .country // ""),
        (.org // .asn_org // "")
      ] | @tsv
    ' 2>/dev/null) || continue
    [[ -n "${parsed%%$'\t'*}" ]] || continue
    _vpn_validate_ip_literal "${parsed%%$'\t'*}" || continue
    host=$(_vpn_provider_authority "$url") || continue
    printf '%s\t%s\n' "$parsed" "$host"
    return 0
  done

  for url in "${plain_providers[@]}"; do
    raw=$(_vpn_curl_bounded "$url" 4 2 2>/dev/null) || continue
    raw="${raw//$'\n'/}"
    raw="${raw//$'\r'/}"
    raw="${raw//[[:space:]]/}"
    _vpn_validate_ip_literal "$raw" || continue
    host=$(_vpn_provider_authority "$url") || continue
    printf '%s\t\t\t\t\t%s\n' "$raw" "$host"
    return 0
  done

  local trace_ip trace_loc trace_colo org_note
  for url in "${trace_providers[@]}"; do
    raw=$(_vpn_curl_bounded "$url" 4 2 2>/dev/null) || continue
    [[ -n "$raw" ]] || continue
    trace_ip=$(print -r -- "$raw" | awk -F= '$1 == "ip" { print $2; exit }')
    trace_ip="${trace_ip//$'\r'/}"
    trace_ip="${trace_ip//[[:space:]]/}"
    _vpn_validate_ip_literal "$trace_ip" || continue
    trace_loc=$(print -r -- "$raw" | awk -F= '$1 == "loc" { print $2; exit }')
    trace_loc="${trace_loc//$'\r'/}"
    trace_loc="${trace_loc//[[:space:]]/}"
    trace_colo=$(print -r -- "$raw" | awk -F= '$1 == "colo" { print $2; exit }')
    trace_colo="${trace_colo//$'\r'/}"
    trace_colo="${trace_colo//[[:space:]]/}"
    org_note=""
    [[ -n "$trace_colo" ]] && org_note="via ${trace_colo} Cloudflare edge"
    host=$(_vpn_provider_authority "$url") || continue
    printf '%s\t\t\t%s\t%s\t%s\n' "$trace_ip" "${trace_loc:-}" "$org_note" "$host"
    return 0
  done

  return 1
}

# Queries one provider according to its declared response type.
# stdout: provider_authority<TAB>validated_ip.
_vpn_crosscheck_provider() {
  local provider_type="$1"
  local url="$2"
  local raw ip host

  raw=$(_vpn_curl_bounded "$url" 4 2 2>/dev/null) || return 1
  [[ -n "$raw" ]] || return 1

  case "$provider_type" in
    json)
      ip=$(print -r -- "$raw" | jq -r '.ip // empty' 2>/dev/null) \
        || return 1
      ;;
    plain)
      ip="${raw//$'\n'/}"
      ip="${ip//$'\r'/}"
      ip="${ip//[[:space:]]/}"
      ;;
    trace)
      ip=$(print -r -- "$raw" \
        | command awk -F= '$1 == "ip" { print $2; exit }')
      ip="${ip//$'\r'/}"
      ip="${ip//[[:space:]]/}"
      ;;
    *) return 2 ;;
  esac

  _vpn_validate_ip_literal "$ip" || return 1
  host=$(_vpn_provider_authority "$url") || return 1
  printf '%s\t%s\n' "$host" "$ip"
}

# Queries every configured provider (JSON + plain + trace) best-effort and
# returns one row per provider that answered. Output format (TSV, one per line):
#   provider_host \t ip
# Does not fail if some providers time out.
_vpn_get_ip_crosscheck() {
  local provider_type url
  local -a json_providers=() plain_providers=() trace_providers=()
  local -a reply=()
  _vpn_load_provider_urls _vpn_ipinfo_json_providers \
    && json_providers=("${reply[@]}")
  reply=()
  _vpn_load_provider_urls _vpn_ipinfo_plain_providers \
    && plain_providers=("${reply[@]}")
  reply=()
  _vpn_load_provider_urls _vpn_ipinfo_trace_providers \
    && trace_providers=("${reply[@]}")

  for provider_type in json plain trace; do
    local -a providers=()
    case "$provider_type" in
      json)  providers=("${json_providers[@]}") ;;
      plain) providers=("${plain_providers[@]}") ;;
      trace) providers=("${trace_providers[@]}") ;;
    esac
    for url in "${providers[@]}"; do
      _vpn_crosscheck_provider "$provider_type" "$url" || continue
    done
  done
}

typeset -g _VPN_INFO_SOURCED=1
