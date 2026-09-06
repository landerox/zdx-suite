#!/usr/bin/env zsh
# =============================================================================
# Network Interfaces: bounded local adapter, address, and route inspection
# =============================================================================
#
# Loaded by net-menu.zsh after net-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_NET_INTERFACES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_net_interfaces_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  net-interfaces'
  print -u2 -r -- '  net-interfaces -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Lists at most 256 validated interfaces from Linux sysfs or ifconfig.'
  print -u2 -r -- \
    'Address and route subprocesses require timeout or gtimeout.'
}

_net_valid_counter() {
  local value="${1:-}"
  [[ ${#value} -ge 1 && ${#value} -le 20 \
    && "$value" =~ '^[0-9]+$' ]]
}

_net_human_bytes() {
  local value="${1:-}"
  _net_valid_counter "$value" || return 1

  local -a units=(B KiB MiB GiB TiB PiB)
  local -F 2 amount="$value"
  local -i unit_index=1
  while (( amount >= 1024.0 && unit_index < ${#units[@]} )); do
    amount=$(( amount / 1024.0 ))
    (( unit_index++ ))
  done
  REPLY="$(printf '%.2f %s' "$amount" "${units[$unit_index]}")"
}

_net_read_sysfs_value() {
  local file_name="${1:-}"
  local maximum_length="${2:-128}"
  [[ "$file_name" == /sys/class/net/* \
    && -r "$file_name" && ! -d "$file_name" ]] || return 1

  local value=""
  IFS= read -r value < "$file_name" || return 1
  _net_visible_value_safe "$value" "$maximum_length" || return 1
  REPLY="$value"
}

_net_emit_interface_record() {
  local interface_name="$1"
  local state="$2"
  local mtu="$3"
  local mac="$4"
  local ipv4="$5"
  local ipv6="$6"
  local received="$7"
  local transmitted="$8"

  _net_valid_interface_name "$interface_name" || return 1
  [[ "$state" =~ '^[A-Z-]{1,16}$' ]] || return 1
  [[ "$mtu" == "unknown" ]] \
    || _net_valid_uint_range "$mtu" 0 4294967295 || return 1
  [[ "$mac" == "unknown" \
    || "$mac" =~ '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' ]] || return 1
  _net_visible_value_safe "$ipv4" 4096 || return 1
  _net_visible_value_safe "$ipv6" 4096 || return 1
  [[ -z "$received" ]] || _net_valid_counter "$received" || return 1
  [[ -z "$transmitted" ]] || _net_valid_counter "$transmitted" || return 1

  [[ -n "$ipv4" ]] || ipv4="-"
  [[ -n "$ipv6" ]] || ipv6="-"
  [[ -n "$received" ]] || received="-"
  [[ -n "$transmitted" ]] || transmitted="-"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$interface_name" "$state" "$mtu" "$mac" \
    "$ipv4" "$ipv6" "$received" "$transmitted"
}

_net_collect_ip_address_maps() {
  reply=()
  _net_have_timeout || return 1
  command -v ip &>/dev/null || return 1

  local ipv4_output=""
  local ipv6_output=""
  _net_capture_probe 262144 5 ip -o -4 addr show || return $?
  ipv4_output="$REPLY"
  _net_capture_probe 262144 5 ip -o -6 addr show || return $?
  ipv6_output="$REPLY"
  reply=("$ipv4_output" "$ipv6_output")
}

# stdout: eight-field TSV interface records, at most 256.
_net_linux_interface_inventory() {
  [[ -d /sys/class/net && ! -L /sys/class/net ]] || return 1

  local -A ipv4_by_name=()
  local -A ipv6_by_name=()
  local -a address_outputs=()
  local -i address_rc=0
  _net_collect_ip_address_maps || address_rc=$?
  (( address_rc != 130 && address_rc != 143 )) || return $address_rc
  if (( address_rc == 0 )); then
    address_outputs=("${reply[@]}")
    local family=""
    local output=""
    local line=""
    local interface_name=""
    local address=""
    local -a words=()
    local -i family_index=0
    for output in "${address_outputs[@]}"; do
      (( family_index++ ))
      if (( family_index == 1 )); then
        family="A"
      else
        family="AAAA"
      fi
      for line in "${(@f)output}"; do
        _net_split_words "$line"
        words=("${reply[@]}")
        (( ${#words[@]} >= 4 )) || continue
        interface_name="${words[2]%%@*}"
        address="${words[4]}"
        _net_valid_interface_name "$interface_name" || continue
        _net_valid_ip_cidr "$address" || continue
        if [[ "$family" == "A" ]]; then
          ipv4_by_name[$interface_name]="${ipv4_by_name[$interface_name]:+${ipv4_by_name[$interface_name]}, }$address"
        else
          ipv6_by_name[$interface_name]="${ipv6_by_name[$interface_name]:+${ipv6_by_name[$interface_name]}, }$address"
        fi
      done
    done
  elif (( address_rc == 125 )); then
    return 125
  fi

  local -a interface_paths=(/sys/class/net/*(N))
  (( ${#interface_paths[@]} <= 256 )) || return 125
  local interface_path=""
  local interface_name=""
  local state="UNKNOWN"
  local mtu="unknown"
  local mac="unknown"
  local received=""
  local transmitted=""
  for interface_path in "${interface_paths[@]}"; do
    interface_name="${interface_path:t}"
    _net_valid_interface_name "$interface_name" || continue

    state="UNKNOWN"
    if _net_read_sysfs_value "$interface_path/operstate" 16; then
      state="${(U)REPLY}"
      [[ "$state" =~ '^[A-Z-]{1,16}$' ]] || state="UNKNOWN"
    fi

    mtu="unknown"
    if _net_read_sysfs_value "$interface_path/mtu" 16 \
      && _net_valid_uint_range "$REPLY" 0 4294967295; then
      mtu="$REPLY"
    fi

    mac="unknown"
    if _net_read_sysfs_value "$interface_path/address" 32 \
      && [[ "$REPLY" =~ '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' ]]; then
      mac="$REPLY"
    fi

    received=""
    if _net_read_sysfs_value "$interface_path/statistics/rx_bytes" 32 \
      && _net_valid_counter "$REPLY"; then
      received="$REPLY"
    fi
    transmitted=""
    if _net_read_sysfs_value "$interface_path/statistics/tx_bytes" 32 \
      && _net_valid_counter "$REPLY"; then
      transmitted="$REPLY"
    fi

    _net_emit_interface_record \
      "$interface_name" "$state" "$mtu" "$mac" \
      "${ipv4_by_name[$interface_name]:-}" \
      "${ipv6_by_name[$interface_name]:-}" \
      "$received" "$transmitted" || return 1
  done
}

# stdout: portable eight-field TSV interface records.
_net_ifconfig_interface_inventory() {
  command -v ifconfig &>/dev/null || return 1
  _net_have_timeout || return 1
  _net_capture_probe 524288 8 ifconfig -a || return $?
  local output="$REPLY"

  local interface_name=""
  local state="DOWN"
  local mtu="unknown"
  local mac="unknown"
  local ipv4=""
  local ipv6=""
  local line=""
  local trimmed=""
  local value=""
  local -a words=()
  local -i record_count=0

  for line in "${(@f)output}"; do
    if [[ "$line" != [[:space:]]* && "$line" == *:* ]]; then
      if [[ -n "$interface_name" ]]; then
        _net_emit_interface_record \
          "$interface_name" "$state" "$mtu" "$mac" \
          "$ipv4" "$ipv6" "" "" || return 1
      fi
      (( ++record_count <= 256 )) || return 125
      interface_name="${line%%:*}"
      _net_valid_interface_name "$interface_name" || {
        interface_name=""
        continue
      }
      state="DOWN"
      [[ "$line" == *"<"*UP*">"* ]] && state="UP"
      mtu="unknown"
      if [[ "$line" =~ 'mtu[[:space:]]+([0-9]+)' ]] \
        && _net_valid_uint_range "${match[1]}" 0 4294967295; then
        mtu="${match[1]}"
      fi
      mac="unknown"
      ipv4=""
      ipv6=""
      continue
    fi

    [[ -n "$interface_name" ]] || continue
    _net_trim "$line"
    trimmed="$REPLY"
    _net_split_words "$trimmed"
    words=("${reply[@]}")
    case "$trimmed" in
      inet\ *)
        value="${words[2]:-}"
        if _net_valid_ipv4 "$value"; then
          ipv4="${ipv4:+$ipv4, }$value"
        fi
        ;;
      inet6\ *)
        value="${words[2]:-}"
        value="${value%%%*}"
        if _net_valid_ipv6 "$value"; then
          ipv6="${ipv6:+$ipv6, }$value"
        fi
        ;;
      ether\ *)
        value="${words[2]:-}"
        if [[ "$value" =~ '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' ]]; then
          mac="$value"
        fi
        ;;
    esac
  done

  if [[ -n "$interface_name" ]]; then
    _net_emit_interface_record \
      "$interface_name" "$state" "$mtu" "$mac" \
      "$ipv4" "$ipv6" "" "" || return 1
  fi
  (( record_count > 0 ))
}

# stdout: eight-field TSV interface records.
_net_interface_inventory() {
  if [[ -d /sys/class/net && ! -L /sys/class/net ]]; then
    _net_linux_interface_inventory
  else
    _net_ifconfig_interface_inventory
  fi
}

# stdout: default-interface<TAB>gateway.
_net_primary_route_record() {
  _net_have_timeout || return 1
  local output=""
  local line=""
  local interface_name=""
  local gateway=""
  local -a words=()
  local -i index=1

  if command -v ip &>/dev/null; then
    _net_capture_probe 65536 5 ip route show default || return $?
    output="$REPLY"
    for line in "${(@f)output}"; do
      [[ "$line" == default* ]] || continue
      interface_name=""
      gateway=""
      _net_split_words "$line"
      words=("${reply[@]}")
      index=1
      while (( index <= ${#words[@]} )); do
        case "${words[$index]}" in
          dev)
            (( index < ${#words[@]} )) \
              && interface_name="${words[$(( index + 1 ))]}"
            ;;
          via)
            (( index < ${#words[@]} )) \
              && gateway="${words[$(( index + 1 ))]}"
            ;;
        esac
        (( index++ ))
      done
      _net_valid_interface_name "$interface_name" || continue
      [[ -z "$gateway" ]] || _net_valid_ip_literal "$gateway" || continue
      printf "%s\t%s\n" "$interface_name" "$gateway"
      return 0
    done
  fi

  command -v route &>/dev/null || return 1
  interface_name=""
  gateway=""
  local -i route_rc=0
  _net_capture_probe 65536 5 route -n get default || route_rc=$?
  output="$REPLY"
  (( route_rc != 130 && route_rc != 143 )) || return $route_rc
  if (( route_rc == 0 )); then
    for line in "${(@f)output}"; do
      _net_trim "$line"
      line="$REPLY"
      case "$line" in
        interface:*)
          interface_name="${line#interface:}"
          _net_trim "$interface_name"
          interface_name="$REPLY"
          ;;
        gateway:*)
          gateway="${line#gateway:}"
          _net_trim "$gateway"
          gateway="$REPLY"
          ;;
      esac
    done
    if _net_valid_interface_name "$interface_name" \
      && _net_valid_ip_literal "$gateway"; then
      printf "%s\t%s\n" "$interface_name" "$gateway"
      return 0
    fi
  fi
  return 1
}

net-interfaces() {
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _net_error "--help accepts no arguments."
        return 2
      }
      _net_interfaces_usage
      return 0
      ;;
    -*)
      _net_error "Unknown option: $(_net_display_escape "$1")"
      return 2
      ;;
    *)
      _net_error "Unexpected argument: $(_net_display_escape "$1")"
      return 2
      ;;
  esac

  _net_header "Local Network Interfaces"
  local inventory=""
  local -i inventory_rc=0
  inventory=$(_net_interface_inventory) || inventory_rc=$?
  (( inventory_rc != 130 && inventory_rc != 143 )) || return $inventory_rc
  if (( inventory_rc != 0 )) || [[ -z "$inventory" ]]; then
    if (( inventory_rc == 125 )); then
      _net_error "The interface inventory exceeded its safety limits."
      return 125
    fi
    _net_error "No supported local interface inventory was available."
    return 1
  fi

  local line=""
  local -a fields=()
  local received_display=""
  local transmitted_display=""
  for line in "${(@f)inventory}"; do
    fields=("${(@s:	:)line}")
    (( ${#fields[@]} == 8 )) || {
      _net_error "The interface inventory contained an invalid record."
      return 1
    }
    _net_info "${fields[1]} — state ${fields[2]}, MTU ${fields[3]}"
    _net_dim "MAC: ${fields[4]}"
    [[ "${fields[5]}" != "-" ]] && _net_dim "IPv4: ${fields[5]}"
    [[ "${fields[6]}" != "-" ]] && _net_dim "IPv6: ${fields[6]}"
    if [[ "${fields[7]}" != "-" || "${fields[8]}" != "-" ]]; then
      received_display="unavailable"
      transmitted_display="unavailable"
      if [[ "${fields[7]}" != "-" ]] && _net_human_bytes "${fields[7]}"; then
        received_display="$REPLY"
      fi
      if [[ "${fields[8]}" != "-" ]] && _net_human_bytes "${fields[8]}"; then
        transmitted_display="$REPLY"
      fi
      _net_dim "Counters: received $received_display, transmitted $transmitted_display"
    fi
  done
}

typeset -g _NET_INTERFACES_SOURCED=1
