#!/usr/bin/env zsh
# =============================================================================
# System Processes: inspect and safely signal host processes
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, sys-capabilities.zsh, and the
# platform adapters.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_PROCESSES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_sys_processes_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  sys-processes'
  print -u2 -r -- '  sys-processes --list'
  print -u2 -r -- '  sys-processes --terminate <PID> [--force] [-y|--yes]'
  print -u2 -r -- '  sys-processes --kill <PID> [--force] [-y|--yes]  (compatibility alias)'
  print -u2 -r -- '  sys-processes -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- '--list emits TSV: process<TAB>pid<TAB>uid<TAB>cpu<TAB>memory<TAB>command.'
  print -u2 -r -- '--force sends SIGKILL instead of SIGTERM. -y/--yes bypasses only confirmation.'
}

_sys_processes_safe_text() {
  local value="${1:-}"
  value="${value[1,256]}"
  value="${value//$'\t'/ }"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  print -r -- "${(V)value}"
}

_sys_processes_normalize_pid() {
  local pid="${1:-}"
  [[ "$pid" == <-> ]] || return 2

  # Reject values outside pid_t before arithmetic so Zsh integer overflow can
  # never reinterpret an oversized user-supplied target as another PID.
  while [[ ${#pid} -gt 1 && "$pid" == 0* ]]; do
    pid="${pid#0}"
  done
  (( ${#pid} <= 10 )) || return 2
  if (( ${#pid} == 10 )) \
    && [[ "$pid" > "2147483647" ]]; then
    return 2
  fi

  local -i normalized_pid
  (( normalized_pid = 10#$pid )) 2>/dev/null || return 2
  (( normalized_pid > 0 )) || return 2
  print -r -- "$normalized_pid"
}

_sys_processes_uid_valid() {
  local process_uid="${1:-}"
  [[ "$process_uid" == <-> ]] || return 2
  while [[ ${#process_uid} -gt 1 && "$process_uid" == 0* ]]; do
    process_uid="${process_uid#0}"
  done
  (( ${#process_uid} < 10 )) && return 0
  (( ${#process_uid} == 10 )) \
    && [[ "$process_uid" < "4294967296" ]]
}

_sys_processes_validate_signal_target() {
  local pid
  pid=$(_sys_processes_normalize_pid "${1:-}") || return 2

  if (( pid == 1 || pid == $$ || pid == PPID )); then
    _sys_error "Refusing to signal protected PID $pid."
    return 1
  fi
  return 0
}

_sys_processes_backend() {
  local process_backend
  process_backend=$(_sys_capability_value process_backend) || return 1

  case "$process_backend" in
    procps|bsd-ps)
      if ! command -v ps &>/dev/null; then
        _sys_error "The selected process backend requires ps."
        return 1
      fi
      print -r -- "$process_backend"
      ;;
    unavailable)
      _sys_error "No supported process backend is available."
      return 1
      ;;
    *)
      _sys_error "Unsupported process backend: $process_backend"
      return 2
      ;;
  esac
}

# stdout TSV: process, PID, UID, CPU percent, memory percent, command name.
_sys_processes_records() {
  local process_backend
  process_backend=$(_sys_processes_backend) || return $?

  local process_output
  case "$process_backend" in
    procps)
      process_output=$(
        _sys_run_with_timeout 5 env LC_ALL=C \
          ps -eo pid=,uid=,pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null
      ) || return $?
      ;;
    bsd-ps)
      process_output=$(
        _sys_run_with_timeout 5 env LC_ALL=C \
          ps -axo pid=,uid=,%cpu=,%mem=,comm= 2>/dev/null
      ) || return $?
      ;;
  esac

  local line raw_pid process_uid cpu_percent memory_percent command_name pid
  local -a process_lines=()
  [[ -n "$process_output" ]] && process_lines=("${(@f)process_output}")
  for line in "${process_lines[@]}"; do
    read -r raw_pid process_uid cpu_percent memory_percent command_name \
      <<< "$line"
    pid=$(_sys_processes_normalize_pid "$raw_pid") || continue
    _sys_processes_uid_valid "$process_uid" || continue
    [[ "$cpu_percent" =~ '^[0-9]+([.][0-9]+)?$' ]] \
      || cpu_percent="0.0"
    [[ "$memory_percent" =~ '^[0-9]+([.][0-9]+)?$' ]] \
      || memory_percent="0.0"
    command_name=$(_sys_processes_safe_text "${command_name:-unknown}")

    printf 'process\t%s\t%s\t%s\t%s\t%s\n' \
      "$pid" "$process_uid" "$cpu_percent" "$memory_percent" "$command_name"
  done
}

# stdout TSV: process, PID, UID, stable start value, command name.
_sys_processes_fingerprint() {
  local pid
  pid=$(_sys_processes_normalize_pid "${1:-}") || return 2
  _sys_processes_backend >/dev/null || return $?

  local process_uid start_value command_name final_start
  process_uid=$(
    _sys_run_with_timeout 3 env LC_ALL=C ps -p "$pid" -o uid= 2>/dev/null
  ) || return 1
  process_uid="${process_uid//[[:space:]]/}"
  _sys_processes_uid_valid "$process_uid" || return 1

  start_value=$(
    _sys_run_with_timeout 3 env LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null
  ) || return 1
  command_name=$(
    _sys_run_with_timeout 3 env LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null
  ) || return 1
  final_start=$(
    _sys_run_with_timeout 3 env LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null
  ) || return 1

  start_value=$(_sys_processes_safe_text "$start_value")
  final_start=$(_sys_processes_safe_text "$final_start")
  command_name=$(_sys_processes_safe_text "$command_name")
  [[ -n "$start_value" && "$start_value" == "$final_start" \
    && -n "$command_name" ]] || return 1

  printf 'process\t%s\t%s\t%s\t%s\n' \
    "$pid" "$process_uid" "$start_value" "$command_name"
}

_sys_processes_validate_fingerprint() {
  local fingerprint="${1:-}"
  local -a fingerprint_fields=("${(@ps:\t:)fingerprint}")
  (( ${#fingerprint_fields[@]} == 5 )) || return 2
  [[ "${fingerprint_fields[1]}" == "process" \
    && "${fingerprint_fields[2]}" == <-> \
    && -n "${fingerprint_fields[4]}" \
    && -n "${fingerprint_fields[5]}" ]] \
    && _sys_processes_uid_valid "${fingerprint_fields[3]}"
}

_sys_processes_fingerprint_matches() {
  local expected_fingerprint="${1:-}"
  _sys_processes_validate_fingerprint "$expected_fingerprint" || return 2
  local -a fingerprint_fields=("${(@ps:\t:)expected_fingerprint}")
  local pid="${fingerprint_fields[2]}"

  local current_fingerprint
  current_fingerprint=$(_sys_processes_fingerprint "$pid") || return 1
  [[ "$current_fingerprint" == "$expected_fingerprint" ]]
}

# Execute one already-confirmed signal after checking the complete fingerprint.
_sys_processes_signal_validated() {
  local expected_fingerprint="${1:-}"
  local signal_name="${2:-TERM}"

  case "$signal_name" in
    TERM|KILL) ;;
    *) return 2 ;;
  esac
  _sys_processes_validate_fingerprint "$expected_fingerprint" || return 2
  local -a fingerprint_fields=("${(@ps:\t:)expected_fingerprint}")
  local pid="${fingerprint_fields[2]}"
  local process_uid="${fingerprint_fields[3]}"
  local start_value="${fingerprint_fields[4]}"
  local command_name="${fingerprint_fields[5]}"
  _sys_processes_validate_signal_target "$pid" || return $?

  _sys_info "Planned operation: send SIG${signal_name} to PID $pid ($command_name)."
  if (( EUID == 0 )) || [[ "$process_uid" == "$EUID" ]]; then
    _sys_processes_fingerprint_matches "$expected_fingerprint" || {
      _sys_error "Process identity changed before signaling PID $pid; no signal was sent."
      return 1
    }
    if ! kill -s "$signal_name" "$pid" 2>/dev/null; then
      _sys_error "Failed to send SIG${signal_name} to PID $pid."
      return 1
    fi
  else
    if ! _sys_has_capability "privilege:sudo" \
      || ! command -v sudo &>/dev/null; then
      _sys_error "PID $pid belongs to UID $process_uid and sudo is unavailable."
      return 1
    fi
    _sys_info "Privileged operation: sudo kill -s $signal_name $pid"
    _sys_processes_fingerprint_matches "$expected_fingerprint" || {
      _sys_error "Process identity changed before requesting privilege; no signal was sent."
      return 1
    }
    if ! sudo -v >&2; then
      _sys_error "sudo authentication failed; no signal was sent."
      return 1
    fi
    _sys_processes_fingerprint_matches "$expected_fingerprint" || {
      _sys_error "Process identity changed during authentication; no signal was sent."
      return 1
    }
    if ! sudo -n kill -s "$signal_name" "$pid" >&2; then
      _sys_error "Privileged SIG${signal_name} failed for PID $pid."
      return 1
    fi
  fi

  _sys_success "SIG${signal_name} sent to PID $pid."
  return 0
}

_sys_processes_terminate() {
  local raw_pid="${1:-}"
  local force_signal="${2:-0}"
  local assume_yes="${3:-0}"
  local pid

  pid=$(_sys_processes_normalize_pid "$raw_pid") || {
    _sys_error "PID must be a positive integer."
    return 2
  }
  _sys_processes_validate_signal_target "$pid" || return $?

  local fingerprint
  fingerprint=$(_sys_processes_fingerprint "$pid") || {
    _sys_error "PID $pid does not identify a stable running process."
    return 1
  }

  _sys_processes_validate_fingerprint "$fingerprint" || return 1
  local -a fingerprint_fields=("${(@ps:\t:)fingerprint}")
  local process_uid="${fingerprint_fields[3]}"
  local start_value="${fingerprint_fields[4]}"
  local command_name="${fingerprint_fields[5]}"
  local signal_name="TERM"
  (( force_signal )) && signal_name="KILL"

  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive process signaling requires --yes."
      return 1
    fi
    if ! _sys_confirm \
      "Send SIG${signal_name} to PID $pid ($command_name, UID $process_uid)?"; then
      _sys_info "Process signaling cancelled."
      return 0
    fi
  fi

  _sys_processes_signal_validated "$fingerprint" "$signal_name"
}

_sys_processes_interactive() {
  local REPLY
  if ! command -v fzf &>/dev/null; then
    _sys_error "fzf is required for the interactive process browser."
    return 1
  fi

  local records_output
  records_output=$(_sys_processes_records) || return $?
  local -a process_records=()
  [[ -n "$records_output" ]] && process_records=("${(@f)records_output}")
  if (( ${#process_records} == 0 )); then
    _sys_info "No processes were reported by the active backend."
    return 0
  fi

  local -a fzf_records=()
  local record record_type pid process_uid cpu_percent memory_percent command_name
  local display_label
  for record in "${process_records[@]}"; do
    IFS=$'\t' read -r \
      record_type pid process_uid cpu_percent memory_percent command_name \
      <<< "$record"
    [[ "$record_type" == "process" && "$pid" == <-> \
      && "$process_uid" == <-> ]] || continue
    printf -v display_label \
      'PID %-7s UID %-6s CPU %6s%% MEM %6s%%  %s' \
      "$pid" "$process_uid" "$cpu_percent" "$memory_percent" "$command_name"
    fzf_records+=("$display_label"$'\t'"$record")
  done

  # Run fzf synchronously in the foreground; --expect returns only an action
  # key to Zsh, where confirmation and signaling happen.
  local selected_output=""
  local -i fzf_status=0
  _sys_fzf_capture \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='sys processes > ' \
    --header='Enter inspect | Ctrl-T SIGTERM | Ctrl-K SIGKILL | Esc cancel' \
    --expect=ctrl-t,ctrl-k \
    --preview='' \
    --preview-window=hidden \
    < <(printf '%s\n' "${fzf_records[@]}") || fzf_status=$?
  selected_output="$REPLY"
  if (( fzf_status != 0 )); then
    (( fzf_status == 1 || fzf_status == 130 )) && return 0
    _sys_error \
      "Unable to open the interactive process browser (status $fzf_status)."
    return 1
  fi
  [[ -n "$selected_output" ]] || return 0

  local selected_key="" selected_record="$selected_output"
  if [[ "$selected_output" == *$'\n'* ]]; then
    selected_key="${selected_output%%$'\n'*}"
    selected_record="${selected_output#*$'\n'}"
  fi
  (( ${fzf_records[(Ie)$selected_record]} > 0 )) || {
    _sys_error "The selected process was not in the browser snapshot."
    return 1
  }
  selected_record="${selected_record#*$'\t'}"
  IFS=$'\t' read -r \
    record_type pid process_uid cpu_percent memory_percent command_name \
    <<< "$selected_record"
  [[ "$record_type" == "process" && "$pid" == <-> \
    && "$process_uid" == <-> ]] || {
    _sys_error "fzf returned an invalid process record."
    return 1
  }

  case "$selected_key" in
    ctrl-t)
      _sys_processes_terminate "$pid" 0 0
      ;;
    ctrl-k)
      _sys_processes_terminate "$pid" 1 0
      ;;
    "")
      local fingerprint
      fingerprint=$(_sys_processes_fingerprint "$pid") || {
        _sys_error "The selected process no longer exists."
        return 1
      }
      _sys_processes_validate_fingerprint "$fingerprint" || return 1
      local -a fingerprint_fields=("${(@ps:\t:)fingerprint}")
      process_uid="${fingerprint_fields[3]}"
      local start_value="${fingerprint_fields[4]}"
      command_name="${fingerprint_fields[5]}"
      _sys_header "Process Details"
      _sys_label "PID:" "$pid"
      _sys_label "UID:" "$process_uid"
      _sys_label "Started:" "$start_value"
      _sys_label "Command:" "$command_name"
      ;;
    *)
      _sys_error "fzf returned an unsupported process action."
      return 1
      ;;
  esac
}

sys-processes() {
  case "${1:-}" in
    "")
      _sys_processes_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_processes_usage
      ;;
    --list)
      (( $# == 1 )) || {
        _sys_error "--list accepts no arguments."
        return 2
      }
      local records_output
      records_output=$(_sys_processes_records) || return $?
      if [[ -n "$records_output" ]]; then
        print -r -- "$records_output"
      else
        _sys_info "No processes were reported by the active backend."
      fi
      ;;
    --terminate|--kill)
      (( $# >= 2 )) || {
        _sys_error "$1 requires a PID."
        return 2
      }
      local target_pid="$2"
      local force_signal=0 assume_yes=0
      shift 2
      while (( $# )); do
        case "$1" in
          --force) force_signal=1 ;;
          --yes|-y) assume_yes=1 ;;
          *)
            _sys_error "Unknown option: $1"
            return 2
            ;;
        esac
        shift
      done
      _sys_processes_terminate "$target_pid" "$force_signal" "$assume_yes"
      ;;
    *)
      _sys_error "Unknown option: $1"
      return 2
      ;;
  esac
}

typeset -g _SYS_PROCESSES_SOURCED=1
