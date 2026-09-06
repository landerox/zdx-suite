#!/usr/bin/env zsh
# =============================================================================
# System Services: inspect and safely control systemd or launchd services
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, sys-capabilities.zsh, and the
# platform adapters.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_SERVICES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_sys_services_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  sys-services'
  print -u2 -r -- '  sys-services --list'
  print -u2 -r -- '  sys-services --show <SERVICE>'
  print -u2 -r -- '  sys-services --start <SERVICE> [-y|--yes]'
  print -u2 -r -- '  sys-services --stop <SERVICE> [-y|--yes]'
  print -u2 -r -- '  sys-services --restart <SERVICE> [-y|--yes]'
  print -u2 -r -- '  sys-services --enable <SERVICE> [-y|--yes]'
  print -u2 -r -- '  sys-services --disable <SERVICE> [-y|--yes]'
  print -u2 -r -- '  sys-services -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- '--list emits TSV: service<TAB>backend<TAB>id<TAB>state<TAB>detail<TAB>description.'
  print -u2 -r -- 'systemd actions use least-privilege sudo; launchd actions target the current user domain.'
  print -u2 -r -- '-y/--yes bypasses only confirmation; validation and state revalidation always run.'
}

_sys_services_safe_text() {
  local value="${1:-}"
  value="${value[1,512]}"
  value="${value//$'\t'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  print -r -- "${(V)value}"
}

_sys_services_backend() {
  local service_backend
  service_backend=$(_sys_capability_value service_manager) || return 1

  case "$service_backend" in
    systemd)
      if ! command -v systemctl &>/dev/null; then
        _sys_error "The systemd backend requires systemctl."
        return 1
      fi
      print -r -- "$service_backend"
      ;;
    launchd)
      if ! command -v launchctl &>/dev/null; then
        _sys_error "The launchd backend requires launchctl."
        return 1
      fi
      print -r -- "$service_backend"
      ;;
    unavailable)
      _sys_error "No supported service manager is available."
      return 1
      ;;
    *)
      _sys_error "Unsupported service manager: $service_backend"
      return 2
      ;;
  esac
}

_sys_services_validate_id() {
  local service_backend="${1:-}"
  local service_id="${2:-}"
  [[ -n "$service_id" && ${#service_id} -le 255 && "$service_id" != -* \
    && "$service_id" != *[[:space:]/]* ]] || return 2

  case "$service_backend" in
    systemd)
      [[ "$service_id" =~ '^[A-Za-z0-9_.@:+-]+[.]service$' ]]
      ;;
    launchd)
      [[ "$service_id" =~ '^[A-Za-z0-9][A-Za-z0-9_.:@+-]*$' ]]
      ;;
    *)
      return 2
      ;;
  esac
}

# stdout TSV: service, systemd, ID, active state, sub-state, description.
_sys_services_systemd_records() {
  local service_output
  service_output=$(
    _sys_run_with_timeout 5 \
      systemctl list-units --type=service --all --plain \
      --no-legend --no-pager 2>/dev/null
  ) || return $?

  local line service_id load_state active_state sub_state description
  local -a service_lines=()
  [[ -n "$service_output" ]] && service_lines=("${(@f)service_output}")
  for line in "${service_lines[@]}"; do
    read -r service_id load_state active_state sub_state description <<< "$line"
    _sys_services_validate_id systemd "$service_id" || continue
    [[ "$load_state" != "not-found" ]] || continue
    active_state=$(_sys_services_safe_text "${active_state:-unknown}")
    sub_state=$(_sys_services_safe_text "${sub_state:-unknown}")
    description=$(_sys_services_safe_text "${description:-No description}")
    printf 'service\tsystemd\t%s\t%s\t%s\t%s\n' \
      "$service_id" "$active_state" "$sub_state" "$description"
  done
}

# stdout TSV: service, launchd, label, active state, PID/exit detail, label.
_sys_services_launchd_records() {
  local service_output
  service_output=$(
    _sys_run_with_timeout 5 launchctl list 2>/dev/null
  ) || return $?

  local line process_pid exit_code service_id active_state detail
  local -a service_lines=()
  [[ -n "$service_output" ]] && service_lines=("${(@f)service_output}")
  for line in "${service_lines[@]}"; do
    read -r process_pid exit_code service_id <<< "$line"
    _sys_services_validate_id launchd "$service_id" || continue
    [[ "$process_pid" == "-" || "$process_pid" == <-> ]] || continue
    [[ "$exit_code" =~ '^-?[0-9]+$' ]] || continue
    active_state="inactive"
    [[ "$process_pid" == <-> ]] && active_state="active"
    detail="pid=${process_pid}, last-exit=${exit_code}"
    printf 'service\tlaunchd\t%s\t%s\t%s\t%s\n' \
      "$service_id" "$active_state" "$detail" "$service_id"
  done
}

_sys_services_launchd_domain() {
  local domain_name
  for domain_name in "gui/${EUID}" "user/${EUID}"; do
    if _sys_run_with_timeout 3 \
      launchctl print "$domain_name" >/dev/null 2>&1; then
      print -r -- "$domain_name"
      return 0
    fi
  done
  _sys_error "No launchd user domain is available for UID $EUID."
  return 1
}

_sys_services_records() {
  local service_backend
  service_backend=$(_sys_services_backend) || return $?
  case "$service_backend" in
    systemd) _sys_services_systemd_records ;;
    launchd) _sys_services_launchd_records ;;
  esac
}

_sys_services_validate_record() {
  local record="${1:-}"
  local -a record_fields=("${(@ps:\t:)record}")
  (( ${#record_fields[@]} == 6 )) || return 2
  [[ "${record_fields[1]}" == "service" \
    && ( "${record_fields[2]}" == "systemd" \
      || "${record_fields[2]}" == "launchd" ) \
    && -n "${record_fields[4]}" \
    && -n "${record_fields[5]}" \
    && -n "${record_fields[6]}" ]] || return 2
  _sys_services_validate_id "${record_fields[2]}" "${record_fields[3]}"
}

# stdout TSV: service-state, backend, ID, load, active, sub/detail, enabled.
_sys_services_state() {
  local service_backend="${1:-}"
  local service_id="${2:-}"
  _sys_services_validate_id "$service_backend" "$service_id" || return 2

  case "$service_backend" in
    systemd)
      local state_output
      state_output=$(
        _sys_run_with_timeout 5 systemctl show --no-pager \
          --property=LoadState \
          --property=ActiveState \
          --property=SubState \
          --property=UnitFileState \
          -- "$service_id" 2>/dev/null
      ) || return 1

      local load_state="" active_state="" sub_state="" enabled_state=""
      local state_line
      local -a state_lines=()
      [[ -n "$state_output" ]] && state_lines=("${(@f)state_output}")
      for state_line in "${state_lines[@]}"; do
        case "$state_line" in
          LoadState=*)     load_state="${state_line#LoadState=}" ;;
          ActiveState=*)   active_state="${state_line#ActiveState=}" ;;
          SubState=*)      sub_state="${state_line#SubState=}" ;;
          UnitFileState=*) enabled_state="${state_line#UnitFileState=}" ;;
        esac
      done
      [[ -n "$load_state" && "$load_state" != "not-found" \
        && -n "$active_state" && -n "$sub_state" ]] || return 1
      load_state=$(_sys_services_safe_text "$load_state")
      active_state=$(_sys_services_safe_text "$active_state")
      sub_state=$(_sys_services_safe_text "$sub_state")
      enabled_state=$(_sys_services_safe_text "${enabled_state:-unknown}")
      printf 'service-state\tsystemd\t%s\t%s\t%s\t%s\t%s\n' \
        "$service_id" "$load_state" "$active_state" \
        "$sub_state" "$enabled_state"
      ;;
    launchd)
      local launchd_domain
      launchd_domain=$(_sys_services_launchd_domain) || return 1
      local records_output
      records_output=$(_sys_services_launchd_records) || return 1
      local record
      local -a service_records=()
      [[ -n "$records_output" ]] && service_records=("${(@f)records_output}")
      for record in "${service_records[@]}"; do
        _sys_services_validate_record "$record" || continue
        local -a fields=("${(@ps:\t:)record}")
        if [[ "${fields[3]}" == "$service_id" ]]; then
          printf 'service-state\tlaunchd\t%s\tloaded\t%s\t%s\t%s\n' \
            "$service_id" "${fields[4]}" "${fields[5]}" "$launchd_domain"
          return 0
        fi
      done
      return 1
      ;;
  esac
}

_sys_services_validate_state() {
  local state_record="${1:-}"
  local -a state_fields=("${(@ps:\t:)state_record}")
  (( ${#state_fields[@]} == 7 )) || return 2
  [[ "${state_fields[1]}" == "service-state" \
    && ( "${state_fields[2]}" == "systemd" \
      || "${state_fields[2]}" == "launchd" ) \
    && -n "${state_fields[4]}" \
    && -n "${state_fields[5]}" \
    && -n "${state_fields[6]}" \
    && -n "${state_fields[7]}" ]] || return 2
  _sys_services_validate_id "${state_fields[2]}" "${state_fields[3]}"
}

_sys_services_state_matches() {
  local expected_state="${1:-}"
  _sys_services_validate_state "$expected_state" || return 2
  local -a state_fields=("${(@ps:\t:)expected_state}")

  local current_state
  current_state=$(
    _sys_services_state "${state_fields[2]}" "${state_fields[3]}"
  ) || return 1
  [[ "$current_state" == "$expected_state" ]]
}

_sys_services_show() {
  local service_id="${1:-}"
  local service_backend
  service_backend=$(_sys_services_backend) || return $?
  _sys_services_validate_id "$service_backend" "$service_id" || {
    _sys_error "Invalid $service_backend service identifier: $service_id"
    return 2
  }

  local state_record
  state_record=$(_sys_services_state "$service_backend" "$service_id") || {
    _sys_error "Service '$service_id' is unavailable in the $service_backend backend."
    return 1
  }
  local -a fields=("${(@ps:\t:)state_record}")
  _sys_header "Service Details"
  _sys_label "Backend:" "${fields[2]}"
  _sys_label "Service:" "${fields[3]}"
  _sys_label "Load:" "${fields[4]}"
  _sys_label "State:" "${fields[5]}"
  _sys_label "Detail:" "${fields[6]}"
  if [[ "$service_backend" == "systemd" ]]; then
    _sys_label "Enabled:" "${fields[7]}"
  else
    _sys_label "Domain:" "${fields[7]}"
  fi
}

_sys_services_execute_systemd() {
  local action_name="$1"
  local service_id="$2"
  local expected_state="$3"

  if (( EUID == 0 )); then
    _sys_info "Operation: systemctl $action_name -- $service_id"
    _sys_services_state_matches "$expected_state" || {
      _sys_error "Service state changed before execution; no action was run."
      return 1
    }
    if ! systemctl "$action_name" -- "$service_id" >&2; then
      _sys_error "systemctl $action_name failed for $service_id."
      return 1
    fi
  else
    if ! _sys_has_capability "privilege:sudo" \
      || ! command -v sudo &>/dev/null; then
      _sys_error "sudo is required to control systemd service $service_id."
      return 1
    fi
    _sys_info "Privileged operation: sudo systemctl $action_name -- $service_id"
    _sys_services_state_matches "$expected_state" || {
      _sys_error "Service state changed before requesting privilege; no action was run."
      return 1
    }
    if ! sudo -v >&2; then
      _sys_error "sudo authentication failed; no service action was run."
      return 1
    fi
    _sys_services_state_matches "$expected_state" || {
      _sys_error "Service state changed during authentication; no action was run."
      return 1
    }
    if ! sudo -n systemctl "$action_name" -- "$service_id" >&2; then
      _sys_error "Privileged systemctl $action_name failed for $service_id."
      return 1
    fi
  fi
  return 0
}

_sys_services_execute_launchd() {
  local action_name="$1"
  local service_id="$2"
  local expected_state="$3"
  _sys_services_validate_state "$expected_state" || return 2
  local -a state_fields=("${(@ps:\t:)expected_state}")
  local service_target="${state_fields[7]}/${service_id}"
  local -a launchctl_command=()
  case "$action_name" in
    start)   launchctl_command=(kickstart "$service_target") ;;
    stop)    launchctl_command=(bootout "$service_target") ;;
    restart) launchctl_command=(kickstart -k "$service_target") ;;
    enable)  launchctl_command=(enable "$service_target") ;;
    disable) launchctl_command=(disable "$service_target") ;;
    *)       return 2 ;;
  esac

  _sys_info "Operation: launchctl ${(j: :)launchctl_command}"
  _sys_services_state_matches "$expected_state" || {
    _sys_error "Service state changed before launchctl execution; no action was run."
    return 1
  }

  launchctl "${launchctl_command[@]}" >&2
}

_sys_services_mutate() {
  local action_name="${1:-}"
  local service_id="${2:-}"
  local assume_yes="${3:-0}"
  case "$action_name" in
    start|stop|restart|enable|disable) ;;
    *) return 2 ;;
  esac

  local service_backend
  service_backend=$(_sys_services_backend) || return $?
  _sys_services_validate_id "$service_backend" "$service_id" || {
    _sys_error "Invalid $service_backend service identifier: $service_id"
    return 2
  }

  local initial_state
  initial_state=$(_sys_services_state "$service_backend" "$service_id") || {
    _sys_error "Service '$service_id' is unavailable in the $service_backend backend."
    return 1
  }
  _sys_info "Planned operation: $action_name $service_backend service $service_id."

  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive service mutation requires --yes."
      return 1
    fi
    if ! _sys_confirm \
      "${action_name:u} $service_backend service '$service_id'?"; then
      _sys_info "Service action cancelled."
      return 0
    fi
  fi

  _sys_services_state_matches "$initial_state" || {
    _sys_error "Service state changed after confirmation; no action was run."
    return 1
  }

  case "$service_backend" in
    systemd)
      _sys_services_execute_systemd \
        "$action_name" "$service_id" "$initial_state" || return $?
      ;;
    launchd)
      _sys_services_execute_launchd \
        "$action_name" "$service_id" "$initial_state" || {
          _sys_error "launchctl $action_name failed for $service_id."
          return 1
        }
      ;;
  esac

  _sys_success "${action_name:u} completed for $service_id."
}

_sys_services_interactive() {
  local REPLY
  if ! command -v fzf &>/dev/null; then
    _sys_error "fzf is required for the interactive service browser."
    return 1
  fi

  local service_backend
  service_backend=$(_sys_services_backend) || return $?
  local records_output
  records_output=$(_sys_services_records) || return $?
  local -a service_records=()
  [[ -n "$records_output" ]] && service_records=("${(@f)records_output}")
  if (( ${#service_records} == 0 )); then
    _sys_info "No services were reported by $service_backend."
    return 0
  fi

  local -a fzf_records=()
  local record display_label
  for record in "${service_records[@]}"; do
    _sys_services_validate_record "$record" || continue
    local -a fields=("${(@ps:\t:)record}")
    printf -v display_label '%-9s %-48s %-12s %s' \
      "${fields[2]}" "${fields[3]}" "${fields[4]}" "${fields[6]}"
    fzf_records+=("$display_label"$'\t'"$record")
  done

  # Run fzf synchronously in the foreground; --expect returns only an action
  # key to Zsh, where confirmation and the service mutation happen.
  local selected_output=""
  local -i fzf_status=0
  _sys_fzf_capture \
    --height=75% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt="sys ${service_backend} services > " \
    --header='Enter inspect | Ctrl-S start | Ctrl-X stop | Ctrl-R restart | Ctrl-E enable | Ctrl-D disable | Esc cancel' \
    --expect=ctrl-s,ctrl-x,ctrl-r,ctrl-e,ctrl-d \
    --preview='' \
    --preview-window=hidden \
    < <(printf '%s\n' "${fzf_records[@]}") || fzf_status=$?
  selected_output="$REPLY"
  if (( fzf_status != 0 )); then
    (( fzf_status == 1 || fzf_status == 130 )) && return 0
    _sys_error \
      "Unable to open the interactive service browser (status $fzf_status)."
    return 1
  fi
  [[ -n "$selected_output" ]] || return 0

  local selected_key="" selected_record="$selected_output"
  if [[ "$selected_output" == *$'\n'* ]]; then
    selected_key="${selected_output%%$'\n'*}"
    selected_record="${selected_output#*$'\n'}"
  fi
  (( ${fzf_records[(Ie)$selected_record]} > 0 )) || {
    _sys_error "The selected service was not in the browser snapshot."
    return 1
  }
  selected_record="${selected_record#*$'\t'}"
  _sys_services_validate_record "$selected_record" || {
    _sys_error "fzf returned an invalid service record."
    return 1
  }
  local -a fields=("${(@ps:\t:)selected_record}")
  local service_id="${fields[3]}"

  case "$selected_key" in
    ctrl-s) _sys_services_mutate start "$service_id" 0 ;;
    ctrl-x) _sys_services_mutate stop "$service_id" 0 ;;
    ctrl-r) _sys_services_mutate restart "$service_id" 0 ;;
    ctrl-e) _sys_services_mutate enable "$service_id" 0 ;;
    ctrl-d) _sys_services_mutate disable "$service_id" 0 ;;
    "")     _sys_services_show "$service_id" ;;
    *)
      _sys_error "fzf returned an unsupported service action."
      return 1
      ;;
  esac
}

sys-services() {
  case "${1:-}" in
    "")
      _sys_services_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_services_usage
      ;;
    --list)
      (( $# == 1 )) || {
        _sys_error "--list accepts no arguments."
        return 2
      }
      local records_output
      records_output=$(_sys_services_records) || return $?
      if [[ -n "$records_output" ]]; then
        print -r -- "$records_output"
      else
        _sys_info "No services were reported by the active backend."
      fi
      ;;
    --show)
      (( $# == 2 )) || {
        _sys_error "--show requires exactly one service identifier."
        return 2
      }
      _sys_services_show "$2"
      ;;
    --start|--stop|--restart|--enable|--disable)
      (( $# >= 2 )) || {
        _sys_error "$1 requires a service identifier."
        return 2
      }
      local action_name="${1#--}"
      local service_id="$2"
      local assume_yes=0
      shift 2
      while (( $# )); do
        case "$1" in
          --yes|-y) assume_yes=1 ;;
          *)
            _sys_error "Unknown option: $1"
            return 2
            ;;
        esac
        shift
      done
      _sys_services_mutate "$action_name" "$service_id" "$assume_yes"
      ;;
    *)
      _sys_error "Unknown option: $1"
      return 2
      ;;
  esac
}

typeset -g _SYS_SERVICES_SOURCED=1
