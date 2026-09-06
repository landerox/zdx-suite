#!/usr/bin/env zsh
# =============================================================================
# Network Diagnostics: bounded ICMP latency and DNS resolution probes
# =============================================================================
#
# Loaded by net-menu.zsh after net-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_NET_DIAGNOSTICS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_net_ping_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  net-ping [--count PACKETS] [TARGET]'
  print -u2 -r -- '  net-ping -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Defaults: TARGET=1.1.1.1, PACKETS=5.'
  print -u2 -r -- 'PACKETS must be a decimal integer from 1 through 20.'
  print -u2 -r -- 'Requires ping plus timeout or gtimeout.'
}

_net_dns_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  net-dns [DOMAIN]'
  print -u2 -r -- '  net-dns -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Defaults: DOMAIN=cloudflare.com.'
  print -u2 -r -- 'Queries bounded A, AAAA, and MX records.'
  print -u2 -r -- 'Requires dig or host plus timeout or gtimeout.'
}

# stdout: transmitted, received, loss, min, average, max, deviation as TSV.
_net_ping_summary_record() {
  local output="${1:-}"
  (( ${#output} <= 262144 )) || return 125

  local transmitted=""
  local received=""
  local loss=""
  local minimum=""
  local average=""
  local maximum=""
  local deviation=""
  local line=""
  local rhs=""
  local values=""
  local candidate_transmitted=""
  local candidate_received=""
  local -a timings=()
  local -i line_count=0

  for line in "${(@f)output}"; do
    (( ++line_count <= 512 )) || return 125
    if [[ -z "$transmitted" \
      && "$line" =~ '([0-9]+)[[:space:]]+packets transmitted,[[:space:]]+([0-9]+)[[:space:]]+(packets[[:space:]]+)?received,' ]]; then
      candidate_transmitted="${match[1]}"
      candidate_received="${match[2]}"
      if [[ "$line" =~ '([0-9.]+)%[[:space:]]+packet loss' ]]; then
        transmitted="$candidate_transmitted"
        received="$candidate_received"
        loss="${match[1]}"
      fi
    fi

    if [[ -z "$average" && "$line" == *"min/avg/max"* && "$line" == *=* ]]; then
      rhs="${line#*=}"
      _net_trim "$rhs"
      rhs="$REPLY"
      values="${rhs%%[[:space:]]*}"
      timings=("${(@s:/:)values}")
      if (( ${#timings[@]} >= 3 && ${#timings[@]} <= 4 )); then
        minimum="${timings[1]}"
        average="${timings[2]}"
        maximum="${timings[3]}"
        deviation="${timings[4]:-}"
      fi
    fi
  done

  _net_valid_uint_range "$transmitted" 1 20 || return 1
  _net_valid_uint_range "$received" 0 20 || return 1
  _net_valid_decimal "$loss" || return 1
  if [[ -n "$average" ]]; then
    _net_valid_decimal "$minimum" || return 1
    _net_valid_decimal "$average" || return 1
    _net_valid_decimal "$maximum" || return 1
    [[ -z "$deviation" ]] || _net_valid_decimal "$deviation" || return 1
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$transmitted" "$received" "$loss" \
    "$minimum" "$average" "$maximum" "$deviation"
}

# stdout: one validated ping-summary TSV record.
_net_ping_probe_record() {
  local target="${1:-}"
  local count="${2:-}"
  _net_valid_target "$target" || return 2
  _net_valid_uint_range "$count" 1 20 || return 2
  command -v ping &>/dev/null || return 1
  _net_have_timeout || return 1

  local -i deadline=$(( count * 3 + 3 ))
  (( deadline > 63 )) && deadline=63
  _net_capture_probe 262144 "$deadline" \
    ping -c "$count" "$target"
  local -i ping_rc=$?
  local ping_output="$REPLY"
  (( ping_rc != 124 && ping_rc != 125 \
    && ping_rc != 130 && ping_rc != 143 )) || return $ping_rc

  local summary=""
  local -i summary_rc=0
  summary=$(_net_ping_summary_record "$ping_output") || summary_rc=$?
  (( summary_rc == 0 )) || {
    (( ping_rc == 0 )) && return 1
    return $ping_rc
  }
  local -a fields=("${(@s:	:)summary}")
  (( ${#fields[@]} == 7 )) \
    && [[ "${fields[1]}" == "$count" ]] || return 1
  print -r -- "$summary"
  return $ping_rc
}

net-ping() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    (( $# == 1 )) || {
      _net_error "--help accepts no arguments."
      return 2
    }
    _net_ping_usage
    return 0
  fi

  local count="5"
  local end_options="no"
  local -a operands=()
  while (( $# )); do
    if [[ "$end_options" == "yes" ]]; then
      operands+=("$1")
      shift
      continue
    fi
    case "$1" in
      --count)
        (( $# >= 2 )) || {
          _net_error "--count requires a value."
          return 2
        }
        count="$2"
        shift
        ;;
      --) end_options="yes" ;;
      -*)
        _net_error "Unknown option: $(_net_display_escape "$1")"
        return 2
        ;;
      *) operands+=("$1") ;;
    esac
    shift
  done
  (( ${#operands[@]} <= 1 )) || {
    _net_error "net-ping accepts at most one target."
    return 2
  }

  local target="${operands[1]:-1.1.1.1}"
  _net_valid_uint_range "$count" 1 20 || {
    _net_error "Packet count must be a decimal integer from 1 through 20."
    return 2
  }
  _net_valid_target "$target" || {
    _net_error "Invalid ping target: $(_net_display_escape "$target")"
    return 2
  }

  _net_check_command ping \
    "Install your platform's ping utility and retry." || return 1
  _net_have_timeout || {
    _net_error "net-ping requires timeout or gtimeout."
    _net_dim "Install GNU coreutils and retry."
    return 1
  }

  _net_header "Ping Latency"
  _net_info "Sending $count bounded ICMP packet(s) to $target..."
  local summary=""
  local -i ping_rc=0
  summary=$(_net_ping_probe_record "$target" "$count") || ping_rc=$?
  (( ping_rc != 130 && ping_rc != 143 )) || return $ping_rc
  if (( ping_rc != 0 )); then
    if (( ping_rc == 124 )); then
      _net_error "The ping probe timed out."
      return 124
    elif (( ping_rc == 125 )); then
      _net_error "The ping probe exceeded its capture safety boundary."
      return 125
    fi
    if [[ -z "$summary" ]]; then
      _net_error "The ping probe failed or returned an invalid summary."
      return 1
    fi
  fi

  local -a fields=("${(@s:	:)summary}")
  (( ${#fields[@]} == 7 )) || {
    _net_error "The ping summary had an invalid record shape."
    return 1
  }
  if (( ping_rc == 0 )); then
    _net_success "Ping probe completed."
  else
    _net_warn "Ping returned a failure; the available packet summary follows."
  fi
  _net_label "Target" "$target"
  _net_label "Transmitted" "${fields[1]} packets"
  _net_label "Received" "${fields[2]} packets"
  _net_label "Packet Loss" "${fields[3]}%"
  if [[ -n "${fields[5]}" ]]; then
    _net_label "Minimum Latency" "${fields[4]} ms"
    _net_label "Average Latency" "${fields[5]} ms"
    _net_label "Maximum Latency" "${fields[6]} ms"
    _net_label "Deviation" "${fields[7]:-(unavailable)} ms"
  fi
  (( ping_rc == 0 ))
}

# stdout: record-type<TAB>validated-value records.
_net_dns_query_type() {
  local backend="$1"
  local record_type="$2"
  local domain="$3"
  [[ "$backend" == "dig" || "$backend" == "host" ]] || return 2
  [[ "$record_type" == "A" || "$record_type" == "AAAA" \
    || "$record_type" == "MX" ]] || return 2
  _net_valid_dns_name "$domain" || return 2

  local output=""
  local -i query_rc=0
  if [[ "$backend" == "dig" ]]; then
    _net_capture_probe 131072 8 \
      dig +time=2 +tries=1 +short "$record_type" "$domain" || query_rc=$?
  else
    _net_capture_probe 131072 8 \
      host -W 2 -R 1 -t "$record_type" "$domain" || query_rc=$?
  fi
  output="$REPLY"
  (( query_rc == 0 )) || return $query_rc

  local line=""
  local value=""
  local priority=""
  local exchange=""
  local -a words=()
  local -i record_count=0
  for line in "${(@f)output}"; do
    _net_trim "$line"
    line="$REPLY"
    [[ -n "$line" ]] || continue

    if [[ "$backend" == "dig" ]]; then
      case "$record_type" in
        A)
          _net_valid_ipv4 "$line" || continue
          value="$line"
          ;;
        AAAA)
          _net_valid_ipv6 "$line" || continue
          value="$line"
          ;;
        MX)
          _net_split_words "$line"
          words=("${reply[@]}")
          (( ${#words[@]} == 2 )) || continue
          priority="${words[1]}"
          exchange="${words[2]}"
          _net_valid_uint_range "$priority" 0 65535 || continue
          _net_valid_dns_name "$exchange" || continue
          value="$priority $exchange"
          ;;
      esac
    else
      _net_split_words "$line"
      words=("${reply[@]}")
      case "$record_type" in
        A)
          [[ "$line" == *" has address "* ]] || continue
          value="${words[-1]:-}"
          _net_valid_ipv4 "$value" || continue
          ;;
        AAAA)
          [[ "$line" == *" has IPv6 address "* ]] || continue
          value="${words[-1]:-}"
          _net_valid_ipv6 "$value" || continue
          ;;
        MX)
          [[ "$line" == *" mail is handled by "* \
            && ${#words[@]} -ge 7 ]] || continue
          priority="${words[-2]}"
          exchange="${words[-1]}"
          _net_valid_uint_range "$priority" 0 65535 || continue
          _net_valid_dns_name "$exchange" || continue
          value="$priority $exchange"
          ;;
      esac
    fi

    printf "%s\t%s\n" "$record_type" "$value"
    (( ++record_count <= 64 )) || return 125
  done
}

# stdout: all validated A, AAAA, and MX records.
_net_dns_records() {
  local domain="${1:-}"
  _net_valid_dns_name "$domain" || return 2
  _net_have_timeout || return 1

  local backend=""
  if command -v dig &>/dev/null; then
    backend="dig"
  elif command -v host &>/dev/null; then
    backend="host"
  else
    return 1
  fi

  local record_type=""
  local records=""
  local -i query_rc=0
  for record_type in A AAAA MX; do
    records=$(_net_dns_query_type "$backend" "$record_type" "$domain") \
      || query_rc=$?
    (( query_rc == 0 )) || return $query_rc
    [[ -n "$records" ]] && print -r -- "$records"
  done
  return 0
}

# stdout: one validated address for dashboard use.
_net_resolve_one() {
  local domain="${1:-}"
  _net_valid_dns_name "$domain" || return 2
  _net_have_timeout || return 1

  local output=""
  local -i lookup_rc=0
  if command -v getent &>/dev/null; then
    _net_capture_probe 65536 8 getent ahosts "$domain" || lookup_rc=$?
    output="$REPLY"
    (( lookup_rc != 130 && lookup_rc != 143 )) || return $lookup_rc
    if (( lookup_rc == 0 )); then
      local line=""
      local address=""
      for line in "${(@f)output}"; do
        address="${line%%[[:space:]]*}"
        if _net_valid_ip_literal "$address"; then
          print -r -- "$address"
          return 0
        fi
      done
    fi
  fi

  local backend=""
  if command -v dig &>/dev/null; then
    backend="dig"
  elif command -v host &>/dev/null; then
    backend="host"
  else
    return 1
  fi

  local line=""
  local record_type=""
  local value=""
  local records=""
  for record_type in A AAAA; do
    records=$(_net_dns_query_type "$backend" "$record_type" "$domain") \
      || return $?
    for line in "${(@f)records}"; do
      value="${line#*$'\t'}"
      if _net_valid_ip_literal "$value"; then
        print -r -- "$value"
        return 0
      fi
    done
  done
  return 1
}

_net_resolver_label() {
  REPLY="Default system resolver"
  zmodload zsh/stat 2>/dev/null || return 0
  local -A resolver_state=()
  [[ -f /etc/resolv.conf && -r /etc/resolv.conf ]] \
    && zstat -LH resolver_state -- /etc/resolv.conf 2>/dev/null \
    && (( resolver_state[size] >= 0 \
      && resolver_state[size] <= 65536 )) || return 0

  local line=""
  local candidate=""
  local -i lines_read=0
  while IFS= read -r line; do
    (( ++lines_read <= 64 )) || break
    (( ${#line} <= 4096 )) || return 0
    [[ "$line" == nameserver[[:space:]]* ]] || continue
    candidate="${line#nameserver}"
    _net_trim "$candidate"
    candidate="$REPLY"
    if _net_valid_ip_literal "$candidate"; then
      REPLY="Nameserver $candidate"
      return 0
    fi
  done < /etc/resolv.conf
}

net-dns() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    (( $# == 1 )) || {
      _net_error "--help accepts no arguments."
      return 2
    }
    _net_dns_usage
    return 0
  fi

  local end_options="no"
  local -a operands=()
  while (( $# )); do
    if [[ "$end_options" == "yes" ]]; then
      operands+=("$1")
    else
      case "$1" in
        --) end_options="yes" ;;
        -*)
          _net_error "Unknown option: $(_net_display_escape "$1")"
          return 2
          ;;
        *) operands+=("$1") ;;
      esac
    fi
    shift
  done
  (( ${#operands[@]} <= 1 )) || {
    _net_error "net-dns accepts at most one domain."
    return 2
  }

  local domain="${operands[1]:-cloudflare.com}"
  _net_valid_dns_name "$domain" || {
    _net_error "Invalid DNS domain: $(_net_display_escape "$domain")"
    return 2
  }
  if ! command -v dig &>/dev/null && ! command -v host &>/dev/null; then
    _net_error "net-dns requires either dig or host."
    _net_dim "Install your platform's DNS utilities and retry."
    return 1
  fi
  _net_have_timeout || {
    _net_error "net-dns requires timeout or gtimeout."
    _net_dim "Install GNU coreutils and retry."
    return 1
  }

  _net_header "DNS Resolution"
  _net_info "Querying bounded A, AAAA, and MX records for $domain..."
  local start_ms=""
  local end_ms=""
  _net_now_ms && start_ms="$REPLY"

  local records=""
  local -i dns_rc=0
  records=$(_net_dns_records "$domain") || dns_rc=$?
  _net_now_ms && end_ms="$REPLY"
  (( dns_rc != 130 && dns_rc != 143 )) || return $dns_rc
  if (( dns_rc != 0 )); then
    if (( dns_rc == 124 )); then
      _net_error "The DNS probe timed out."
      return 124
    elif (( dns_rc == 125 )); then
      _net_error "The DNS probe exceeded its capture safety boundary."
      return 125
    fi
    _net_error "The DNS backend failed or returned an oversized response."
    return 1
  fi

  local -a a_records=()
  local -a aaaa_records=()
  local -a mx_records=()
  local line=""
  local record_type=""
  local value=""
  for line in "${(@f)records}"; do
    [[ "$line" == *$'\t'* ]] || {
      _net_error "The DNS response had an invalid record shape."
      return 1
    }
    record_type="${line%%$'\t'*}"
    value="${line#*$'\t'}"
    case "$record_type" in
      A)    a_records+=("$value") ;;
      AAAA) aaaa_records+=("$value") ;;
      MX)   mx_records+=("$value") ;;
      *)
        _net_error "The DNS response contained an unknown record type."
        return 1
        ;;
    esac
  done

  _net_resolver_label
  local resolver="$REPLY"
  local elapsed="unavailable"
  if [[ "$start_ms" =~ '^[0-9]{1,16}$' \
    && "$end_ms" =~ '^[0-9]{1,16}$' ]] \
    && (( end_ms >= start_ms )); then
    elapsed="$(( end_ms - start_ms )) ms"
  fi

  local a_display="${(j:, :)a_records}"
  local aaaa_display="${(j:, :)aaaa_records}"
  local mx_display="${(j:, :)mx_records}"
  [[ -n "$a_display" ]] || a_display="(none)"
  [[ -n "$aaaa_display" ]] || aaaa_display="(none)"
  [[ -n "$mx_display" ]] || mx_display="(none)"

  _net_success "DNS query completed."
  _net_label "Target" "$domain"
  _net_label "Resolver" "$resolver"
  _net_label "Elapsed" "$elapsed"
  _net_label "A Records" "$a_display"
  _net_label "AAAA Records" "$aaaa_display"
  _net_label "MX Records" "$mx_display"
}

typeset -g _NET_DIAGNOSTICS_SOURCED=1
