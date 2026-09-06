#!/usr/bin/env zsh
# =============================================================================
# System Ports: inspect listeners and safely signal their owning processes
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, sys-capabilities.zsh, and the
# platform adapters.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_PORTS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_sys_ports_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  sys-ports'
  print -u2 -r -- '  sys-ports --list'
  print -u2 -r -- '  sys-ports --kill-pid <PID> [--force] [-y|--yes]'
  print -u2 -r -- '  sys-ports --kill-port <PORT> [--protocol tcp|udp] [--force] [-y|--yes]'
  print -u2 -r -- \
    '  sys-ports --kill pid:PID [--force] [-y|--yes]'
  print -u2 -r -- \
    '  sys-ports --kill port:PORT [--protocol tcp|udp] [--force] [-y|--yes]'
  print -u2 -r -- '  sys-ports -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- '--list emits TSV: port<TAB>protocol<TAB>port<TAB>address<TAB>pid<TAB>command.'
  print -u2 -r -- 'A port target must resolve to exactly one visible PID immediately before signaling.'
  print -u2 -r -- '--force sends SIGKILL instead of SIGTERM. -y/--yes bypasses only confirmation.'
}

_sys_ports_safe_text() {
  local value="${1:-}"
  value="${value[1,256]}"
  value="${value//$'\t'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  print -r -- "${(V)value}"
}

_sys_ports_normalize_port() {
  local port_number="${1:-}"
  [[ "$port_number" == <-> ]] || return 2

  # Bound the decimal string before arithmetic so oversized input cannot wrap
  # into a valid port number in Zsh's fixed-width integer representation.
  while [[ ${#port_number} -gt 1 && "$port_number" == 0* ]]; do
    port_number="${port_number#0}"
  done
  (( ${#port_number} <= 5 )) || return 2

  local -i normalized_port
  (( normalized_port = 10#$port_number )) 2>/dev/null || return 2
  (( normalized_port >= 1 && normalized_port <= 65535 )) || return 2
  print -r -- "$normalized_port"
}

_sys_ports_backend() {
  local ports_backend
  ports_backend=$(_sys_capability_value ports_backend) || return 1

  case "$ports_backend" in
    lsof|ss)
      if ! command -v "$ports_backend" &>/dev/null; then
        _sys_error "The selected port backend requires $ports_backend."
        return 1
      fi
      print -r -- "$ports_backend"
      ;;
    unavailable)
      _sys_error "No supported listening-port backend is available."
      return 1
      ;;
    *)
      _sys_error "Unsupported listening-port backend: $ports_backend"
      return 2
      ;;
  esac
}

_sys_ports_lsof_output() {
  local tcp_output="" udp_output=""
  local tcp_rc=0 udp_rc=0

  tcp_output=$(
    _sys_run_with_timeout 5 \
      lsof -nP -iTCP -sTCP:LISTEN -FpcfPn 2>/dev/null
  ) || tcp_rc=$?
  udp_output=$(
    _sys_run_with_timeout 5 \
      lsof -nP -iUDP -FpcfPn 2>/dev/null
  ) || udp_rc=$?

  (( tcp_rc == 0 || tcp_rc == 1 )) || return "$tcp_rc"
  (( udp_rc == 0 || udp_rc == 1 )) || return "$udp_rc"
  [[ -n "$tcp_output" ]] && print -r -- "$tcp_output"
  [[ -n "$udp_output" ]] && print -r -- "$udp_output"
  return 0
}

# stdout TSV: port, protocol, port number, local address, PID, command name.
_sys_ports_lsof_records() {
  local lsof_output
  lsof_output=$(_sys_ports_lsof_output) || return $?

  local current_pid="" current_command="unknown" current_protocol=""
  local line field_value endpoint address port_number
  local -a lsof_lines=()
  [[ -n "$lsof_output" ]] && lsof_lines=("${(@f)lsof_output}")
  for line in "${lsof_lines[@]}"; do
    [[ -n "$line" ]] || continue
    field_value="${line[2,-1]}"
    case "${line[1]}" in
      p)
        current_pid=""
        current_command="unknown"
        current_protocol=""
        [[ "$field_value" == <-> ]] && current_pid="$field_value"
        ;;
      c)
        current_command=$(_sys_ports_safe_text "$field_value")
        ;;
      P)
        case "${field_value:l}" in
          tcp|udp) current_protocol="${field_value:l}" ;;
          *)       current_protocol="" ;;
        esac
        ;;
      f)
        current_protocol=""
        ;;
      n)
        endpoint="$field_value"
        [[ "$endpoint" == *'->'* ]] && continue
        [[ -n "$current_pid" && -n "$current_protocol" ]] || continue
        if [[ "$endpoint" =~ ':([0-9]+)$' ]]; then
          port_number=$(_sys_ports_normalize_port "${match[1]}") || continue
          address="${endpoint%:*}"
          address=$(_sys_ports_safe_text "${address:-*}")
          printf 'port\t%s\t%s\t%s\t%s\t%s\n' \
            "$current_protocol" "$port_number" "$address" \
            "$current_pid" "$current_command"
        fi
        ;;
    esac
  done
}

# stdout TSV: port, protocol, port number, local address, PID or -, command.
_sys_ports_ss_records() {
  local ss_output
  ss_output=$(
    _sys_run_with_timeout 5 env LC_ALL=C ss -H -lntup 2>/dev/null
  ) || return $?

  local line protocol state recv_queue send_queue local_endpoint
  local peer_endpoint process_data address port_number process_pid command_name
  local remaining_process_data
  local -a ss_lines=()
  [[ -n "$ss_output" ]] && ss_lines=("${(@f)ss_output}")
  for line in "${ss_lines[@]}"; do
    command_name="unknown"
    read -r protocol state recv_queue send_queue \
      local_endpoint peer_endpoint process_data <<< "$line"
    protocol="${protocol:l}"
    [[ "$protocol" == "tcp" || "$protocol" == "udp" ]] || continue
    if [[ "$local_endpoint" =~ ':([0-9]+)$' ]]; then
      port_number=$(_sys_ports_normalize_port "${match[1]}") || continue
    else
      continue
    fi

    address="${local_endpoint%:*}"
    address=$(_sys_ports_safe_text "${address:-*}")
    local -A visible_pids=() pid_commands=()
    remaining_process_data="$line"
    while [[ "$remaining_process_data" =~ '"([^"]+)"[^)]*pid=([0-9]+)' ]]; do
      command_name=$(_sys_ports_safe_text "${match[1]}")
      process_pid="${match[2]}"
      visible_pids[$process_pid]=1
      pid_commands[$process_pid]="$command_name"
      remaining_process_data="${remaining_process_data[$(( MEND + 1 )),-1]}"
    done

    # A future ss format may expose a PID outside the familiar users tuple.
    # Retain it as an unknown owner rather than silently losing ambiguity.
    remaining_process_data="$line"
    while [[ "$remaining_process_data" =~ 'pid=([0-9]+)' ]]; do
      process_pid="${match[1]}"
      visible_pids[$process_pid]=1
      (( ${+pid_commands[$process_pid]} )) \
        || pid_commands[$process_pid]="unknown"
      remaining_process_data="${remaining_process_data[$(( MEND + 1 )),-1]}"
    done
    if (( ${#visible_pids[@]} == 0 )); then
      printf 'port\t%s\t%s\t%s\t-\t%s\n' \
        "$protocol" "$port_number" "$address" "$command_name"
      continue
    fi
    for process_pid in ${(onk)visible_pids}; do
      printf 'port\t%s\t%s\t%s\t%s\t%s\n' \
        "$protocol" "$port_number" "$address" "$process_pid" \
        "${pid_commands[$process_pid]}"
    done
  done
}

_sys_ports_records() {
  local ports_backend
  ports_backend=$(_sys_ports_backend) || return $?

  local records_output
  case "$ports_backend" in
    lsof) records_output=$(_sys_ports_lsof_records) || return $? ;;
    ss)   records_output=$(_sys_ports_ss_records) || return $? ;;
  esac

  [[ -n "$records_output" ]] || return 0
  print -r -- "$records_output" \
    | env LC_ALL=C sort -t $'\t' -k3,3n -k2,2 -k5,5n
}

_sys_ports_validate_record() {
  local record="${1:-}"
  local -a record_fields=("${(@ps:\t:)record}")
  (( ${#record_fields[@]} == 6 )) || return 2

  local record_type="${record_fields[1]}"
  local protocol="${record_fields[2]}"
  local port_number="${record_fields[3]}"
  local address="${record_fields[4]}"
  local process_pid="${record_fields[5]}"
  local command_name="${record_fields[6]}"
  [[ "$record_type" == "port" \
    && ( "$protocol" == "tcp" || "$protocol" == "udp" ) \
    && -n "$address" && -n "$command_name" ]] || return 2
  _sys_ports_normalize_port "$port_number" >/dev/null || return 2
  [[ "$process_pid" == "-" || "$process_pid" == <-> ]]
}

_sys_ports_record_is_current() {
  local expected_record="${1:-}"
  _sys_ports_validate_record "$expected_record" || return 2
  local -a expected_fields=("${(@ps:\t:)expected_record}")

  local records_output
  records_output=$(_sys_ports_records) || return 1
  local current_record
  local -a current_records=()
  [[ -n "$records_output" ]] && current_records=("${(@f)records_output}")
  for current_record in "${current_records[@]}"; do
    _sys_ports_validate_record "$current_record" || continue
    local -a current_fields=("${(@ps:\t:)current_record}")
    if [[ "${current_fields[2]}" == "${expected_fields[2]}" \
      && "${current_fields[3]}" == "${expected_fields[3]}" \
      && "${current_fields[4]}" == "${expected_fields[4]}" \
      && "${current_fields[5]}" == "${expected_fields[5]}" ]]; then
      return 0
    fi
  done
  return 1
}

# Resolve a port to one exact listener record. Multiple or hidden owners fail.
_sys_ports_resolve_port() {
  local raw_port="${1:-}"
  local requested_protocol="${2:-}"
  local port_number
  port_number=$(_sys_ports_normalize_port "$raw_port") || {
    _sys_error "Port must be an integer between 1 and 65535."
    return 2
  }

  if [[ -n "$requested_protocol" ]]; then
    requested_protocol="${requested_protocol:l}"
    [[ "$requested_protocol" == "tcp" || "$requested_protocol" == "udp" ]] || {
      _sys_error "Protocol must be tcp or udp."
      return 2
    }
  fi

  local records_output
  records_output=$(_sys_ports_records) || return $?
  local -A matching_pids=()
  local matched_record="" hidden_owner=0
  local record
  local -a records=()
  [[ -n "$records_output" ]] && records=("${(@f)records_output}")
  for record in "${records[@]}"; do
    _sys_ports_validate_record "$record" || continue
    local -a fields=("${(@ps:\t:)record}")
    [[ "${fields[3]}" == "$port_number" ]] || continue
    [[ -z "$requested_protocol" \
      || "${fields[2]}" == "$requested_protocol" ]] || continue
    if [[ "${fields[5]}" == "-" ]]; then
      hidden_owner=1
      continue
    fi
    matching_pids[${fields[5]}]=1
    [[ -z "$matched_record" ]] && matched_record="$record"
  done

  if (( hidden_owner )); then
    _sys_error "Port $port_number has a listener whose PID is not visible; refusing to signal."
    return 1
  fi
  if (( ${#matching_pids[@]} == 0 )); then
    _sys_error "No visible process is listening on port $port_number."
    return 1
  fi
  if (( ${#matching_pids[@]} > 1 )); then
    _sys_error "Port $port_number belongs to multiple PIDs; use --kill-pid with an exact PID."
    return 1
  fi

  print -r -- "$matched_record"
}

_sys_ports_terminate_record() {
  local listener_record="${1:-}"
  local force_signal="${2:-0}"
  local assume_yes="${3:-0}"
  _sys_ports_validate_record "$listener_record" || {
    _sys_error "Invalid listener record."
    return 2
  }
  local -a fields=("${(@ps:\t:)listener_record}")
  local protocol="${fields[2]}"
  local port_number="${fields[3]}"
  local address="${fields[4]}"
  local process_pid="${fields[5]}"
  local command_name="${fields[6]}"
  [[ "$process_pid" == <-> ]] || {
    _sys_error "The listener does not expose a PID and cannot be signaled safely."
    return 1
  }

  if ! typeset -f _sys_processes_fingerprint &>/dev/null \
    || ! typeset -f _sys_processes_signal_validated &>/dev/null \
    || ! typeset -f _sys_processes_validate_signal_target &>/dev/null; then
    _sys_error "Process safety helpers are unavailable."
    return 1
  fi
  _sys_processes_validate_signal_target "$process_pid" || return $?

  local fingerprint
  fingerprint=$(_sys_processes_fingerprint "$process_pid") || {
    _sys_error "PID $process_pid does not identify a stable running process."
    return 1
  }
  local signal_name="TERM"
  (( force_signal )) && signal_name="KILL"

  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive listener signaling requires --yes."
      return 1
    fi
    if ! _sys_confirm \
      "Send SIG${signal_name} to PID $process_pid ($command_name) on ${protocol}:${port_number}?"; then
      _sys_info "Listener signaling cancelled."
      return 0
    fi
  fi

  _sys_ports_record_is_current "$listener_record" || {
    _sys_error "The selected ${protocol}:${port_number} listener changed; no signal was sent."
    return 1
  }
  _sys_processes_fingerprint_matches "$fingerprint" || {
    _sys_error "Process identity changed for PID $process_pid; no signal was sent."
    return 1
  }
  _sys_processes_signal_validated "$fingerprint" "$signal_name"
}

_sys_ports_interactive() {
  local REPLY
  if ! command -v fzf &>/dev/null; then
    _sys_error "fzf is required for the interactive listening-port browser."
    return 1
  fi

  local records_output
  records_output=$(_sys_ports_records) || return $?
  local -a listener_records=()
  [[ -n "$records_output" ]] && listener_records=("${(@f)records_output}")
  if (( ${#listener_records} == 0 )); then
    _sys_info "No active listening ports were found."
    return 0
  fi

  local -a fzf_records=()
  local record display_label
  for record in "${listener_records[@]}"; do
    _sys_ports_validate_record "$record" || continue
    local -a fields=("${(@ps:\t:)record}")
    printf -v display_label '%-3s %-5s %-24s PID %-7s %s' \
      "${fields[2]:u}" "${fields[3]}" "${fields[4]}" \
      "${fields[5]}" "${fields[6]}"
    fzf_records+=("$display_label"$'\t'"$record")
  done

  # Run fzf synchronously in the foreground; --expect returns only an action
  # key to Zsh, where confirmation and signaling happen.
  local selected_output=""
  local -i fzf_status=0
  _sys_fzf_capture \
    --height=75% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='sys ports > ' \
    --header='Enter inspect | Ctrl-T SIGTERM | Ctrl-K SIGKILL | Esc cancel' \
    --expect=ctrl-t,ctrl-k \
    --preview='' \
    --preview-window=hidden \
    < <(printf '%s\n' "${fzf_records[@]}") || fzf_status=$?
  selected_output="$REPLY"
  if (( fzf_status != 0 )); then
    (( fzf_status == 1 || fzf_status == 130 )) && return 0
    _sys_error \
      "Unable to open the interactive listener browser (status $fzf_status)."
    return 1
  fi
  [[ -n "$selected_output" ]] || return 0

  local selected_key="" selected_record="$selected_output"
  if [[ "$selected_output" == *$'\n'* ]]; then
    selected_key="${selected_output%%$'\n'*}"
    selected_record="${selected_output#*$'\n'}"
  fi
  (( ${fzf_records[(Ie)$selected_record]} > 0 )) || {
    _sys_error "The selected listener was not in the browser snapshot."
    return 1
  }
  selected_record="${selected_record#*$'\t'}"
  _sys_ports_validate_record "$selected_record" || {
    _sys_error "fzf returned an invalid listener record."
    return 1
  }
  local -a fields=("${(@ps:\t:)selected_record}")

  case "$selected_key" in
    ctrl-t)
      _sys_ports_terminate_record "$selected_record" 0 0
      ;;
    ctrl-k)
      _sys_ports_terminate_record "$selected_record" 1 0
      ;;
    "")
      _sys_header "Listener Details"
      _sys_label "Protocol:" "${fields[2]:u}"
      _sys_label "Address:" "${fields[4]}"
      _sys_label "Port:" "${fields[3]}"
      _sys_label "PID:" "${fields[5]}"
      _sys_label "Command:" "${fields[6]}"
      ;;
    *)
      _sys_error "fzf returned an unsupported listener action."
      return 1
      ;;
  esac
}

_sys_ports_parse_mutation() {
  local target_kind="$1"
  local target_value="$2"
  shift 2
  local force_signal=0 assume_yes=0 requested_protocol=""

  while (( $# )); do
    case "$1" in
      --force) force_signal=1 ;;
      --yes|-y) assume_yes=1 ;;
      --protocol)
        (( $# >= 2 )) || {
          _sys_error "--protocol requires tcp or udp."
          return 2
        }
        requested_protocol="${2:l}"
        shift
        ;;
      *)
        _sys_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  case "$target_kind" in
    pid)
      [[ -z "$requested_protocol" ]] || {
        _sys_error "--protocol is valid only with a port target."
        return 2
      }
      if ! typeset -f _sys_processes_terminate &>/dev/null; then
        _sys_error "Process safety helpers are unavailable."
        return 1
      fi
      _sys_processes_terminate "$target_value" "$force_signal" "$assume_yes"
      ;;
    port)
      local listener_record
      listener_record=$(
        _sys_ports_resolve_port "$target_value" "$requested_protocol"
      ) || return $?
      _sys_ports_terminate_record \
        "$listener_record" "$force_signal" "$assume_yes"
      ;;
    *)
      return 2
      ;;
  esac
}

sys-ports() {
  case "${1:-}" in
    "")
      _sys_ports_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_ports_usage
      ;;
    --list)
      (( $# == 1 )) || {
        _sys_error "--list accepts no arguments."
        return 2
      }
      local records_output
      records_output=$(_sys_ports_records) || return $?
      if [[ -n "$records_output" ]]; then
        print -r -- "$records_output"
      else
        _sys_info "No active listening ports were found."
      fi
      ;;
    --kill-pid)
      (( $# >= 2 )) || {
        _sys_error "--kill-pid requires a PID."
        return 2
      }
      local target_pid="$2"
      shift 2
      _sys_ports_parse_mutation pid "$target_pid" "$@"
      ;;
    --kill-port)
      (( $# >= 2 )) || {
        _sys_error "--kill-port requires a port number."
        return 2
      }
      local target_port="$2"
      shift 2
      _sys_ports_parse_mutation port "$target_port" "$@"
      ;;
    --kill)
      (( $# >= 2 )) || {
        _sys_error "--kill requires pid:PID or port:PORT."
        return 2
      }
      local typed_target="$2"
      shift 2
      case "$typed_target" in
        pid:*)
          _sys_ports_parse_mutation pid "${typed_target#pid:}" "$@"
          ;;
        port:*)
          _sys_ports_parse_mutation port "${typed_target#port:}" "$@"
          ;;
        *)
          _sys_error "Ambiguous target '$typed_target'; use pid:PID or port:PORT."
          return 2
          ;;
      esac
      ;;
    *)
      _sys_error "Unknown option: $1"
      return 2
      ;;
  esac
}

typeset -g _SYS_PORTS_SOURCED=1
