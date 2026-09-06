#!/usr/bin/env zsh
# =============================================================================
# Network Dashboard: bounded aggregate connectivity and local-state snapshot
# =============================================================================
#
# Loaded by net-menu.zsh after net-public.zsh, net-diagnostics.zsh, and
# net-interfaces.zsh. Safe to re-source; defines functions only.
#

if [[ -n "${_NET_DASHBOARD_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_net_dashboard_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  net-dashboard [--local-only]'
  print -u2 -r -- '  net-dashboard -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- \
    'By default, performs bounded ICMP, DNS, and public-IP probes.'
  print -u2 -r -- \
    '--local-only skips all remote probes and displays routes and interfaces only.'
  print -u2 -r -- \
    'Unavailable sections are reported without hiding the remaining snapshot.'
}

net-dashboard() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    (( $# == 1 )) || {
      _net_error "--help accepts no arguments."
      return 2
    }
    _net_dashboard_usage
    return 0
  fi

  local local_only="no"
  local end_options="no"
  while (( $# )); do
    if [[ "$end_options" == "yes" ]]; then
      _net_error "Unexpected argument: $(_net_display_escape "$1")"
      return 2
    fi
    case "$1" in
      --local-only) local_only="yes" ;;
      --)           end_options="yes" ;;
      -*)
        _net_error "Unknown option: $(_net_display_escape "$1")"
        return 2
        ;;
      *)
        _net_error "Unexpected argument: $(_net_display_escape "$1")"
        return 2
        ;;
    esac
    shift
  done

  _net_header "Network Diagnostics Dashboard"

  if [[ "$local_only" == "yes" ]]; then
    _net_info "Local-only mode: remote ICMP, DNS, and public-IP probes are disabled."
  else
    _net_info "Checking bounded public reachability..."
    local ping_summary=""
    local ping_target=""
    local candidate_target=""
    local -a ping_fields=()
    local -i ping_rc=0
    local -i ping_timed_out=0
    for candidate_target in 1.1.1.1 8.8.8.8; do
      ping_rc=0
      ping_summary=$(_net_ping_probe_record "$candidate_target" 1) \
        || ping_rc=$?
      (( ping_rc != 130 && ping_rc != 143 )) || return $ping_rc
      if (( ping_rc == 124 )); then
        ping_timed_out=1
        continue
      fi
      (( ping_rc == 0 )) || continue
      ping_fields=("${(@s:	:)ping_summary}")
      if (( ${#ping_fields[@]} == 7 )) \
        && _net_valid_uint_range "${ping_fields[2]}" 1 20; then
        ping_target="$candidate_target"
        break
      fi
      ping_rc=1
    done
    if [[ -n "$ping_target" ]]; then
      _net_success "Internet Route: reachable"
      _net_label "Probe Target" "$ping_target"
      _net_label "Average Latency" "${ping_fields[5]:-(unavailable)} ms"
    elif (( ping_timed_out )); then
      _net_warn "Internet reachability timed out."
    else
      _net_warn "Internet reachability is unavailable or offline."
    fi

    _net_info "Resolving bounded public exit metadata..."
    local public_record=""
    local -i public_rc=0
    public_record=$(_net_public_info_record 2) || public_rc=$?
    (( public_rc != 130 && public_rc != 143 )) || return $public_rc
    if (( public_rc == 0 )) && [[ -n "$public_record" ]]; then
      local -a public_fields=("${(@s:	:)public_record}")
      if (( ${#public_fields[@]} == 6 )); then
        local location=""
        [[ -n "${public_fields[2]}" ]] && location="${public_fields[2]}"
        [[ -n "${public_fields[3]}" ]] \
          && location="${location:+$location, }${public_fields[3]}"
        if [[ -n "${public_fields[4]}" ]]; then
          if [[ -n "$location" ]]; then
            location+=" (${public_fields[4]})"
          else
            location="${public_fields[4]}"
          fi
        fi
        _net_label "Public Exit IP" "${public_fields[1]}"
        _net_label "Operator" "${public_fields[5]:-(unavailable)}"
        _net_label "Location" "${location:-(unavailable)}"
        _net_label "IP Provider" "${public_fields[6]}"
      else
        _net_warn "Public-IP discovery returned an invalid record."
      fi
    else
      _net_warn "Public-IP metadata is unavailable."
    fi

    _net_info "Testing bounded DNS resolution..."
    local dns_start=""
    local dns_end=""
    local resolved_address=""
    local -i dns_rc=0
    _net_now_ms && dns_start="$REPLY"
    resolved_address=$(_net_resolve_one "cloudflare.com") || dns_rc=$?
    _net_now_ms && dns_end="$REPLY"
    (( dns_rc != 130 && dns_rc != 143 )) || return $dns_rc
    if (( dns_rc == 0 )) && _net_valid_ip_literal "$resolved_address"; then
      local elapsed="unavailable"
      if [[ "$dns_start" =~ '^[0-9]{1,16}$' \
        && "$dns_end" =~ '^[0-9]{1,16}$' ]] \
        && (( dns_end >= dns_start )); then
        elapsed="$(( dns_end - dns_start )) ms"
      fi
      _net_label "DNS Target" "cloudflare.com"
      _net_label "Resolved Address" "$resolved_address"
      _net_label "Resolution Time" "$elapsed"
    elif (( dns_rc == 124 )); then
      _net_warn "DNS resolution timed out."
    else
      _net_warn "DNS resolution is unavailable."
    fi
  fi

  _net_info "Inspecting the default route..."
  local route_record=""
  local -i route_rc=0
  route_record=$(_net_primary_route_record) || route_rc=$?
  (( route_rc != 130 && route_rc != 143 )) || return $route_rc
  if (( route_rc == 0 )) && [[ "$route_record" == *$'\t'* ]]; then
    local route_interface="${route_record%%$'\t'*}"
    local route_gateway="${route_record#*$'\t'}"
    _net_label "Default Interface" "$route_interface"
    _net_label "Default Gateway" "${route_gateway:-(direct route)}"
  else
    _net_warn "No validated default route was available."
  fi

  _net_info "Inspecting bounded local interface state..."
  local inventory=""
  local -i inventory_rc=0
  inventory=$(_net_interface_inventory) || inventory_rc=$?
  (( inventory_rc != 130 && inventory_rc != 143 )) || return $inventory_rc
  if (( inventory_rc == 0 )) && [[ -n "$inventory" ]]; then
    local -a inventory_lines=("${(@f)inventory}")
    local line=""
    local -a fields=()
    local interface_ipv4=""
    local -i shown=0
    for line in "${inventory_lines[@]}"; do
      fields=("${(@s:	:)line}")
      (( ${#fields[@]} == 8 )) || continue
      interface_ipv4="${fields[5]}"
      [[ "$interface_ipv4" != "-" ]] || interface_ipv4="(none)"
      _net_dim "${fields[1]}: state ${fields[2]}, IPv4 $interface_ipv4"
      (( ++shown >= 8 )) && break
    done
    (( shown > 0 )) || _net_warn "No validated interface record was available."
    if (( ${#inventory_lines[@]} > shown )); then
      _net_dim "Additional interfaces omitted; run net-interfaces for the full snapshot."
    fi
  elif (( inventory_rc == 125 )); then
    _net_warn "The local interface inventory exceeded its safety limits."
  else
    _net_warn "Local interface state is unavailable."
  fi

  _net_success "Network snapshot complete."
}

typeset -g _NET_DASHBOARD_SOURCED=1
