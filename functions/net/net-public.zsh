#!/usr/bin/env zsh
# =============================================================================
# Network Public IP: bounded HTTPS exit-address and metadata discovery
# =============================================================================
#
# Loaded by net-menu.zsh after net-common.zsh.
# Safe to re-source; defines functions and fixed provider metadata only.
#

if [[ -n "${_NET_PUBLIC_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gra _NET_PUBLIC_JSON_PROVIDERS=(
  "https://ipapi.co/json"
  "https://ipinfo.io/json"
  "https://freeipapi.com/api/json"
)
typeset -gra _NET_PUBLIC_PLAIN_PROVIDERS=(
  "https://icanhazip.com"
  "https://ifconfig.me/ip"
  "https://api.ipify.org"
)
typeset -gra _NET_PUBLIC_TRACE_PROVIDERS=(
  "https://1.1.1.1/cdn-cgi/trace"
)

_net_public_ip_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  net-public-ip [--cross-check]'
  print -u2 -r -- '  net-public-ip -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Options:'
  print -u2 -r -- \
    '  --cross-check   Query every fixed provider and compare validated IPs'
  print -u2 -r -- ''
  print -u2 -r -- 'Requires curl. JSON metadata is used only when jq is installed.'
  print -u2 -r -- \
    'Requests use bounded HTTPS-only redirects and send no ZDX credentials.'
  print -u2 -r -- \
    'Cross-checking discloses the caller IP to up to seven fixed providers.'
}

_net_public_metadata_safe() {
  local value="${1:-}"
  local maximum_length="${2:-256}"
  _net_visible_value_safe "$value" "$maximum_length" \
    && [[ "$value" != *$'\t'* ]]
}

_net_public_provider_host_is_fixed() {
  local provider_host="${1:-}"
  _net_public_metadata_safe "$provider_host" 253 || return 1

  local url=""
  for url in \
    "${_NET_PUBLIC_JSON_PROVIDERS[@]}" \
    "${_NET_PUBLIC_PLAIN_PROVIDERS[@]}" \
    "${_NET_PUBLIC_TRACE_PROVIDERS[@]}"; do
    _net_provider_name "$url" || return 1
    [[ "$REPLY" == "$provider_host" ]] && return 0
  done
  return 1
}

# stdout: ip<TAB>city<TAB>region<TAB>country<TAB>organization.
_net_public_parse_json() {
  local raw="${1:-}"
  command -v jq &>/dev/null || return 1
  _net_have_timeout || return 1
  (( ${#raw} <= 131072 )) || return 125

  local parsed=""
  local -i jq_rc=0
  parsed=$(print -rn -- "$raw" | _net_run_probe 5 jq -er '
    [
      (.ip // .ipAddress // ""),
      (.city // .cityName // ""),
      (.region // .region_name // .regionName // ""),
      (.country_name // .country // .countryName // ""),
      (.org // .asn_org // .asnOrganisation // "")
    ] as $record
    | if ([$record[] | type] | all(. == "string"))
      and ([$record[]
        | (explode | all(. >= 32 and (. < 127 or . > 159)))]
        | all)
      then $record | @tsv
      else empty
      end
  ' 2>/dev/null) || jq_rc=$?
  (( jq_rc == 0 )) || {
    (( jq_rc == 124 || jq_rc == 130 || jq_rc == 143 )) && return $jq_rc
    return 1
  }
  (( ${#parsed} <= 4096 )) || return 125

  local -a fields=("${(@s:	:)parsed}")
  (( ${#fields[@]} == 5 )) || return 1
  _net_valid_ip_literal "${fields[1]}" || return 1
  _net_public_metadata_safe "${fields[2]}" 256 || return 1
  _net_public_metadata_safe "${fields[3]}" 256 || return 1
  _net_public_metadata_safe "${fields[4]}" 128 || return 1
  _net_public_metadata_safe "${fields[5]}" 512 || return 1
  printf "%s\t%s\t%s\t%s\t%s\n" "${fields[@]}"
}

# stdout: ip<TAB>country-code<TAB>edge-note.
_net_public_parse_trace() {
  local raw="${1:-}"
  (( ${#raw} <= 131072 )) || return 125

  local ip=""
  local location=""
  local edge=""
  local line=""
  local key=""
  local value=""
  local -i line_count=0
  for line in "${(@f)raw}"; do
    (( ++line_count <= 64 )) || return 125
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    value="${value//$'\r'/}"
    case "$key" in
      ip)
        [[ -z "$ip" ]] || return 1
        _net_valid_ip_literal "$value" || return 1
        ip="$value"
        ;;
      loc)
        [[ "$value" =~ '^[A-Z]{2}$' ]] && location="$value"
        ;;
      colo)
        [[ ${#value} -le 12 && "$value" =~ '^[A-Za-z0-9-]+$' ]] \
          && edge="$value"
        ;;
    esac
  done
  [[ -n "$ip" ]] || return 1

  local edge_note=""
  [[ -n "$edge" ]] && edge_note="via $edge Cloudflare edge"
  printf "%s\t%s\t%s\n" "$ip" "$location" "$edge_note"
}

# stdout: one six-field TSV record:
# ip, city, region, country, organization, provider host.
_net_public_info_record() {
  local attempt_limit="${1:-7}"
  _net_valid_uint_range "$attempt_limit" 1 7 || return 2
  command -v curl &>/dev/null || return 1

  local url=""
  local raw=""
  local parsed=""
  local provider=""
  local -a fields=()
  local -i attempts=0
  local -i fetch_rc=0
  local -i parse_rc=0
  local -i safety_failure=0
  if command -v jq &>/dev/null && _net_have_timeout; then
    for url in "${_NET_PUBLIC_JSON_PROVIDERS[@]}"; do
      (( ++attempts <= attempt_limit )) || {
        (( safety_failure == 0 )) || return 125
        return 1
      }
      _net_safe_provider_url "$url" || return 2
      fetch_rc=0
      _net_fetch_url "$url" 131072 || fetch_rc=$?
      if (( fetch_rc != 0 )); then
        (( fetch_rc != 130 && fetch_rc != 143 )) || return $fetch_rc
        (( fetch_rc == 125 )) && safety_failure=1
        (( fetch_rc == 2 )) && return 2
        continue
      fi
      raw="$REPLY"
      parse_rc=0
      parsed=$(_net_public_parse_json "$raw") || parse_rc=$?
      if (( parse_rc != 0 )); then
        (( parse_rc != 130 && parse_rc != 143 )) || return $parse_rc
        (( parse_rc == 125 )) && safety_failure=1
        continue
      fi
      _net_provider_name "$url" || return 2
      provider="$REPLY"
      printf "%s\t%s\n" "$parsed" "$provider"
      return 0
    done
  fi

  for url in "${_NET_PUBLIC_PLAIN_PROVIDERS[@]}"; do
    (( ++attempts <= attempt_limit )) || {
      (( safety_failure == 0 )) || return 125
      return 1
    }
    _net_safe_provider_url "$url" || return 2
    fetch_rc=0
    _net_fetch_url "$url" 4096 || fetch_rc=$?
    if (( fetch_rc != 0 )); then
      (( fetch_rc != 130 && fetch_rc != 143 )) || return $fetch_rc
      (( fetch_rc == 125 )) && safety_failure=1
      (( fetch_rc == 2 )) && return 2
      continue
    fi
    raw="$REPLY"
    _net_trim "$raw"
    raw="$REPLY"
    _net_valid_ip_literal "$raw" || continue
    _net_provider_name "$url" || return 2
    provider="$REPLY"
    printf "%s\t\t\t\t\t%s\n" "$raw" "$provider"
    return 0
  done

  for url in "${_NET_PUBLIC_TRACE_PROVIDERS[@]}"; do
    (( ++attempts <= attempt_limit )) || {
      (( safety_failure == 0 )) || return 125
      return 1
    }
    _net_safe_provider_url "$url" || return 2
    fetch_rc=0
    _net_fetch_url "$url" 131072 || fetch_rc=$?
    if (( fetch_rc != 0 )); then
      (( fetch_rc != 130 && fetch_rc != 143 )) || return $fetch_rc
      (( fetch_rc == 125 )) && safety_failure=1
      (( fetch_rc == 2 )) && return 2
      continue
    fi
    raw="$REPLY"
    parse_rc=0
    parsed=$(_net_public_parse_trace "$raw") || parse_rc=$?
    if (( parse_rc != 0 )); then
      (( parse_rc != 130 && parse_rc != 143 )) || return $parse_rc
      (( parse_rc == 125 )) && safety_failure=1
      continue
    fi
    fields=("${(@s:	:)parsed}")
    (( ${#fields[@]} == 3 )) || continue
    _net_provider_name "$url" || return 2
    provider="$REPLY"
    printf "%s\t\t\t%s\t%s\t%s\n" \
      "${fields[1]}" "${fields[2]}" "${fields[3]}" "$provider"
    return 0
  done

  (( safety_failure == 0 )) || return 125
  return 1
}

# stdout: provider-host<TAB>validated-IP records, at most seven.
_net_public_crosscheck_records() {
  command -v curl &>/dev/null || return 1

  local url=""
  local raw=""
  local parsed=""
  local provider=""
  local ip=""
  local -a fields=()
  local -i record_count=0
  local -i fetch_rc=0
  local -i parse_rc=0
  local -i safety_failure=0

  if command -v jq &>/dev/null && _net_have_timeout; then
    for url in "${_NET_PUBLIC_JSON_PROVIDERS[@]}"; do
      _net_safe_provider_url "$url" || return 2
      fetch_rc=0
      _net_fetch_url "$url" 131072 || fetch_rc=$?
      if (( fetch_rc != 0 )); then
        (( fetch_rc != 130 && fetch_rc != 143 )) || return $fetch_rc
        (( fetch_rc == 125 )) && safety_failure=1
        (( fetch_rc == 2 )) && return 2
        continue
      fi
      raw="$REPLY"
      parse_rc=0
      parsed=$(_net_public_parse_json "$raw") || parse_rc=$?
      if (( parse_rc != 0 )); then
        (( parse_rc != 130 && parse_rc != 143 )) || return $parse_rc
        (( parse_rc == 125 )) && safety_failure=1
        continue
      fi
      fields=("${(@s:	:)parsed}")
      ip="${fields[1]:-}"
      _net_valid_ip_literal "$ip" || continue
      _net_provider_name "$url" || return 2
      provider="$REPLY"
      printf "%s\t%s\n" "$provider" "$ip"
      (( ++record_count <= 7 )) || return 125
    done
  fi

  for url in "${_NET_PUBLIC_PLAIN_PROVIDERS[@]}"; do
    _net_safe_provider_url "$url" || return 2
    fetch_rc=0
    _net_fetch_url "$url" 4096 || fetch_rc=$?
    if (( fetch_rc != 0 )); then
      (( fetch_rc != 130 && fetch_rc != 143 )) || return $fetch_rc
      (( fetch_rc == 125 )) && safety_failure=1
      (( fetch_rc == 2 )) && return 2
      continue
    fi
    raw="$REPLY"
    _net_trim "$raw"
    ip="$REPLY"
    _net_valid_ip_literal "$ip" || continue
    _net_provider_name "$url" || return 2
    provider="$REPLY"
    printf "%s\t%s\n" "$provider" "$ip"
    (( ++record_count <= 7 )) || return 125
  done

  for url in "${_NET_PUBLIC_TRACE_PROVIDERS[@]}"; do
    _net_safe_provider_url "$url" || return 2
    fetch_rc=0
    _net_fetch_url "$url" 131072 || fetch_rc=$?
    if (( fetch_rc != 0 )); then
      (( fetch_rc != 130 && fetch_rc != 143 )) || return $fetch_rc
      (( fetch_rc == 125 )) && safety_failure=1
      (( fetch_rc == 2 )) && return 2
      continue
    fi
    raw="$REPLY"
    parse_rc=0
    parsed=$(_net_public_parse_trace "$raw") || parse_rc=$?
    if (( parse_rc != 0 )); then
      (( parse_rc != 130 && parse_rc != 143 )) || return $parse_rc
      (( parse_rc == 125 )) && safety_failure=1
      continue
    fi
    fields=("${(@s:	:)parsed}")
    ip="${fields[1]:-}"
    _net_valid_ip_literal "$ip" || continue
    _net_provider_name "$url" || return 2
    provider="$REPLY"
    printf "%s\t%s\n" "$provider" "$ip"
    (( ++record_count <= 7 )) || return 125
  done

  (( safety_failure == 0 )) || return 125
  (( record_count > 0 ))
}

net-public-ip() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    (( $# == 1 )) || {
      _net_error "--help accepts no arguments."
      return 2
    }
    _net_public_ip_usage
    return 0
  fi

  local cross_check="no"
  local end_options="no"
  while (( $# )); do
    if [[ "$end_options" == "yes" ]]; then
      _net_error "Unexpected argument: $(_net_display_escape "$1")"
      return 2
    fi
    case "$1" in
      --cross-check) cross_check="yes" ;;
      --)            end_options="yes" ;;
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

  _net_check_command curl \
    "Install curl or run 'zdx doctor' for dependency guidance." || return 1

  if [[ "$cross_check" == "yes" ]]; then
    _net_header "Multi-Provider IP Cross-Check"
    _net_info "Querying up to seven fixed HTTPS providers sequentially..."
    local records=""
    local -i cross_rc=0
    records=$(_net_public_crosscheck_records) || cross_rc=$?
    (( cross_rc != 130 && cross_rc != 143 )) || return $cross_rc
    if (( cross_rc != 0 )) || [[ -z "$records" ]]; then
      if (( cross_rc == 125 )); then
        _net_error \
          "The public-IP cross-check exceeded a response safety boundary."
        return 125
      fi
      _net_warn "No provider returned a valid cross-check record."
      return 1
    fi

    local line=""
    local cross_provider=""
    local cross_ip=""
    local -i cross_count=0
    for line in "${(@f)records}"; do
      [[ "$line" == *$'\t'* && "$line" != *$'\t'*$'\t'* ]] || {
        _net_error "The public-IP cross-check returned an invalid record."
        return 1
      }
      cross_provider="${line%%$'\t'*}"
      cross_ip="${line#*$'\t'}"
      _net_public_provider_host_is_fixed "$cross_provider" \
        && _net_valid_ip_literal "$cross_ip" || {
        _net_error "The public-IP cross-check returned invalid provider data."
        return 1
      }
      (( ++cross_count <= 7 )) || {
        _net_error "The public-IP cross-check exceeded its record limit."
        return 125
      }
      _net_label "$cross_provider" "$cross_ip"
    done
    _net_success "Public exit IP cross-check complete."
    return 0
  fi

  _net_header "Public IP and Exit Metadata"
  _net_info "Contacting a bounded HTTPS public-IP provider..."
  local info=""
  local -i info_rc=0
  info=$(_net_public_info_record) || info_rc=$?
  (( info_rc != 130 && info_rc != 143 )) || return $info_rc
  if (( info_rc != 0 )); then
    if (( info_rc == 125 )); then
      _net_error "Public-IP discovery exceeded a response safety boundary."
      return 125
    fi
    _net_error "No configured public-IP provider returned a valid response."
    return 1
  fi
  local -a fields=("${(@s:	:)info}")
  (( ${#fields[@]} == 6 )) || {
    _net_error "The public-IP response had an invalid record shape."
    return 1
  }

  local ip="${fields[1]}"
  local city="${fields[2]}"
  local region="${fields[3]}"
  local country="${fields[4]}"
  local organization="${fields[5]}"
  local provider="${fields[6]}"
  _net_valid_ip_literal "$ip" \
    && _net_public_metadata_safe "$city" 256 \
    && _net_public_metadata_safe "$region" 256 \
    && _net_public_metadata_safe "$country" 128 \
    && _net_public_metadata_safe "$organization" 512 \
    && _net_public_provider_host_is_fixed "$provider" || {
    _net_error "The public-IP response contained invalid provider data."
    return 1
  }
  local location=""
  [[ -n "$city" ]] && location="$city"
  [[ -n "$region" ]] \
    && location="${location:+$location, }$region"
  if [[ -n "$country" ]]; then
    if [[ -n "$location" ]]; then
      location+=" ($country)"
    else
      location="$country"
    fi
  fi

  _net_success "Validated public exit metadata received."
  _net_label "Public Exit IP" "$ip"
  _net_label "ASN / Operator" "${organization:-(unavailable)}"
  _net_label "Location" "${location:-(unavailable)}"
  _net_label "Provider" "$provider"
}

typeset -g _NET_PUBLIC_SOURCED=1
