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
_vpn_rpt_fence_open()  { _vpn_rpt '```'; }
_vpn_rpt_fence_close() { _vpn_rpt '```'; }

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

  _vpn_label "Profile access" "$(_vpn_access_label "$_VPN_MENU_CONFIG_ACCESS_STATE")"
  _vpn_label "Tunnel access" "$(_vpn_access_label "$_VPN_MENU_WG_ACCESS_STATE")"
  _vpn_label "Non-interactive sudo" \
    "$([[ "$_VPN_MENU_SUDO_UNLOCKED" == 1 ]] \
      && print -r -- available || print -r -- unavailable)"

  case "$_VPN_MENU_CONFIG_ACCESS_STATE" in
    missing) _vpn_label "Profiles" "directory missing" ;;
    *)
      if (( _VPN_MENU_CONFIGS_KNOWN )); then
        _vpn_label "Profiles" "${#_VPN_MENU_CONFIGS[@]}"
      else
        _vpn_label "Profiles" "locked"
      fi
      ;;
  esac

  case "$_VPN_MENU_WG_ACCESS_STATE" in
    missing) _vpn_label "Active" "wg missing" ;;
    *)
      if (( _VPN_MENU_ACTIVE_KNOWN )); then
        if [[ ${#_VPN_MENU_ACTIVE_IFACES[@]} -gt 0 ]]; then
          _vpn_label "Active" "${#_VPN_MENU_ACTIVE_IFACES[@]} (${_VPN_MENU_ACTIVE_IFACES[*]})"
        else
          _vpn_label "Active" "0"
        fi
      else
        _vpn_label "Active" "locked"
      fi
      ;;
  esac

  if (( _VPN_MENU_CONFIGS_KNOWN )); then
    if (( _VPN_MENU_BACKUP_UNKNOWN_COUNT > 0 )); then
      _vpn_label "Backups" "${_VPN_MENU_BACKUP_AVAILABLE_COUNT} available, ${_VPN_MENU_BACKUP_UNKNOWN_COUNT} unknown"
    else
      _vpn_label "Backups" "${_VPN_MENU_BACKUP_AVAILABLE_COUNT} available"
    fi
  else
    _vpn_label "Backups" "unknown"
  fi

  _vpn_label "Default" "${_VPN_MENU_DEFAULT_IFACE:-(none)}"
  _vpn_label "Last used" "${_VPN_MENU_LAST_IFACE:-(none)}"

  if (( _VPN_MENU_WSL_FIX )); then
    _vpn_label "WSL fix" "enabled"
  else
    _vpn_label "WSL fix" "off"
  fi

  if [[ "$_VPN_MENU_CONFIG_ACCESS_STATE" == "locked" ]]; then
    _vpn_blank
    _vpn_dim "$(_vpn_config_dir) exists but is locked; use 'Unlock VPN access' to load profiles."
    return 0
  fi

  if [[ "$_VPN_MENU_CONFIG_ACCESS_STATE" == "missing" ]]; then
    _vpn_blank
    _vpn_dim "Create or import a profile to start using WireGuard."
    return 0
  fi

  if [[ ${#_VPN_MENU_CONFIGS[@]} -eq 0 ]]; then
    _vpn_blank
    _vpn_info "No WireGuard configs found in $(_vpn_config_dir)."
    return 0
  fi

  _vpn_blank
  _vpn_info "Profiles:"
  local conf status backup_state
  for conf in "${_VPN_MENU_CONFIGS[@]}"; do
    status="inactive"
    if _vpn_state_iface_is_active "$conf"; then
      status="active"
    elif (( !_VPN_MENU_ACTIVE_KNOWN )); then
      status="unknown"
    fi

    if [[ -n "$_VPN_MENU_LAST_IFACE" && "$conf" == "$_VPN_MENU_LAST_IFACE" ]]; then
      status="$status, last used"
    fi

    backup_state=$(_vpn_state_iface_backup_state "$conf")
    case "$backup_state" in
      available) status="$status, backup available" ;;
      unknown) status="$status, backup unknown" ;;
    esac
    _vpn_label "$conf" "$status"
  done
}

# vpn-details
#   Arguments: --help only.
#   stdout:    none. Interface state is UI and goes to stderr.
#   Effects:   read-only. May request sudo once to read per-interface state.
#   Status:    0 on success or inaccessible live state, 1 when wg is missing.
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
  _vpn_check_wg || return 1

  _vpn_info "WireGuard status:"
  local -a reply=()
  local -a active_ifaces=()
  local -i active_known=0
  if _vpn_active_interfaces; then
    active_known=1
    active_ifaces=("${reply[@]}")
  elif [[ "$(_vpn_wg_access_state)" == "locked" ]]; then
    if _vpn_ensure_wg_access; then
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

  # Per-interface 'wg show <iface>' often needs root even when the bare
  # 'wg show interfaces' listing succeeds (common on WSL). Unlock sudo
  # best-effort so detailed state is available when the user authenticates;
  # do not abort the whole command if the prompt is declined.
  if [[ ${#active_ifaces[@]} -gt 0 ]] && \
     ! _vpn_run_wg show "${active_ifaces[1]}" &>/dev/null && \
     ! _vpn_have_sudo_cache; then
    _vpn_warn "Detailed interface state requires sudo."
    _vpn_ensure_sudo_access "Reading WireGuard interface details" || true
  fi

  local iface
  if [[ ${#active_ifaces[@]} -gt 0 ]]; then
    for iface in "${active_ifaces[@]}"; do
      _vpn_header "Interface: $iface"
      local details
      if ! details=$(
        _vpn_info_capture_bounded \
          "$_VPN_MAX_PREVIEW_BYTES" _vpn_get_iface_details "$iface"
      ); then
        _vpn_warn "Could not read detailed state for $iface."
        _vpn_dim \
          "The state was inaccessible or exceeded the diagnostic safety limit."
      elif [[ -n "$details" ]]; then
        local line
        for line in "${(@f)details}"; do
          print -u2 -r -- "${(V)line}"
        done
      fi
      _vpn_blank
    done
    _vpn_success "WireGuard: ${#active_ifaces[@]} active interface(s) (${active_ifaces[*]})."
  else
    _vpn_warn "WireGuard: no active tunnel interfaces."
    _vpn_blank
  fi
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

  # Per-iface details may need sudo even when the interface listing works.
  # Prompt best-effort so the tunnel section is useful.
  if [[ ${#active_ifaces[@]} -gt 0 ]] && \
     ! _vpn_run_wg show "${active_ifaces[1]}" &>/dev/null && \
     ! _vpn_have_sudo_cache; then
    _vpn_warn "Detailed tunnel state requires sudo."
    _vpn_ensure_sudo_access "Reading WireGuard tunnel state" || true
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
      _vpn_header "Interface: $iface"
      addr_lines=$(_vpn_iface_internal_addrs "$iface" 2>/dev/null)
      addr_array=(${(@f)addr_lines})
      addr_joined="${(j:, :)addr_array}"
      endpoint=$(_vpn_iface_endpoint "$iface" 2>/dev/null)
      hs_ts=$(_vpn_iface_latest_handshake "$iface" 2>/dev/null)
      rx_tx=$(_vpn_iface_transfer "$iface" 2>/dev/null)
      rx="${rx_tx%%$'\t'*}"
      tx="${rx_tx##*$'\t'}"
      dns_line=$(_vpn_dns_from_conf "$iface" 2>/dev/null)

      _vpn_label "Internal IP" "${addr_joined:-(unknown)}"
      _vpn_label "Endpoint" "${endpoint:-(unknown)}"
      _vpn_label "Handshake" "$(_vpn_human_age "${hs_ts:-0}")"
      _vpn_label "Transfer" "↓ $(_vpn_human_bytes "${rx:-0}")  ↑ $(_vpn_human_bytes "${tx:-0}")"
      [[ -n "$dns_line" ]] && _vpn_label "Tunnel DNS" "$dns_line"
    done

    _vpn_blank
    local route
    route=$(_vpn_default_route 2>/dev/null)
    if [[ -n "$route" ]]; then
      _vpn_label "Default route" "$route"
    else
      _vpn_label "Default route" "(ip command unavailable)"
    fi
  fi

  # --- Public exit section -------------------------------------------------
  _vpn_blank
  _vpn_header "Public exit"

  if ! _vpn_have_ip_stack; then
    _vpn_warn "jq or curl not available; skipping public IP lookup."
    return 0
  fi

  _vpn_info "Querying public IP providers (fast fallback cascade)..."

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
    _vpn_blank
    _vpn_info "Cross-checking IP across providers..."
    local cc_raw p_host p_ip marker any=0
    cc_raw=$(_vpn_get_ip_crosscheck)
    if [[ -n "$cc_raw" ]]; then
      while IFS=$'\t' read -r p_host p_ip; do
        [[ -n "$p_ip" ]] || continue
        any=1
        if [[ "$p_ip" == "$ip" ]]; then
          marker="match"
        else
          marker="DIFFERS"
        fi
        _vpn_label "$p_host" "$p_ip ($marker)"
      done <<< "$cc_raw"
      (( any == 0 )) && _vpn_warn "Cross-check: no providers answered."
    else
      _vpn_warn "Cross-check: no providers answered."
    fi
  else
    _vpn_blank
    _vpn_dim "Cross-check off. Set VPN_MENU_IP_CROSSCHECK=1 to verify the IP against all providers."
  fi

  # --- DNS resolvers -------------------------------------------------------
  _vpn_blank
  _vpn_header "DNS resolvers"
  local resolvers r dns_count=0
  resolvers=$(
    _vpn_info_capture_bounded \
      "$_VPN_MAX_PREVIEW_BYTES" _vpn_dns_resolvers
  ) || resolvers=""
  if [[ -n "$resolvers" ]]; then
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      _vpn_label "nameserver" "$r"
      dns_count=$(( dns_count + 1 ))
    done <<< "$resolvers"
  fi
  (( dns_count == 0 )) && _vpn_dim "No /etc/resolv.conf nameservers detected."

  # --- DNS leak heuristic --------------------------------------------------
  # Compares each active iface's configured Tunnel DNS against the resolvers
  # currently in /etc/resolv.conf. On WSL the resolv.conf typically points at
  # a Windows host relay, so the tunnel DNS is not actually being used even
  # when the profile declares it. Non-blocking hint only.
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
        (( leaks_seen == 0 )) && _vpn_blank
        leaks_seen=1
        _vpn_warn "Tunnel DNS for $iface_leak ($tunnel_dns) not present in /etc/resolv.conf."
      fi
    done
    if (( leaks_seen )); then
      _vpn_dim "Possible DNS leak — WSL typically routes DNS via a Windows relay."
    fi
  fi

  _vpn_blank
  _vpn_dim "Use 'vpn-report' to persist a full diagnostic Markdown under ~/vpn-stats."
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

  _vpn_info "Preparing an owner-only report under: $report_dir"
  _vpn_blank

  {

  # --- Header --------------------------------------------------------------
  local host_full user kernel is_wsl
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
  if [[ -n "${WSL_DISTRO_NAME-}" ]]; then
    is_wsl="yes (${WSL_DISTRO_NAME})"
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
  _vpn_should_apply_wsl_ipv6_fix && _vpn_rpt_kv "WSL IPv6 fix" "enabled"

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
        _vpn_rpt "**wg show \`$iface\`:**"
        _vpn_rpt_blank
        _vpn_rpt_code_block "$wg_out" || _VPN_REPORT_WRITE_FAILED=1
      fi
    done
  fi

  # --- Routing -------------------------------------------------------------
  _vpn_info "Collecting routing snapshot..."

  _vpn_rpt_h2 "Routing"
  if command -v ip &>/dev/null; then
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
  if [[ -n "$resolvers" ]]; then
    _vpn_rpt "**/etc/resolv.conf:**"
    _vpn_rpt_blank
    while IFS= read -r r; do
      [[ -n "$r" ]] && _vpn_rpt_bullet "$r"
    done <<< "$resolvers"
  else
    _vpn_rpt_bullet "No /etc/resolv.conf nameservers detected."
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
  [[ -n "${WSL_DISTRO_NAME-}" ]] && _vpn_rpt_bullet "WSL distro: **${WSL_DISTRO_NAME}**"

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

  _vpn_blank
  _vpn_header "VPN Report Completed"
  _vpn_success "Report written."
  _vpn_label "File" "$report_file"
  _vpn_dim "View: $(_vpn_report_view_hint "$report_file")"
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
    parsed=$(print -r -- "$raw" | jq -r '
      [
        .ip // empty,
        .city // empty,
        (.region // .region_name // empty),
        (.country_name // .country // empty),
        (.org // .asn_org // empty)
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
