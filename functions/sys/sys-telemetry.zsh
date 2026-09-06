#!/usr/bin/env zsh
# =============================================================================
# System Telemetry: bounded and validated local history inspection
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh.
# Safe to re-source; defines functions and configuration defaults only.
#

if [[ -n "${_SYS_TELEMETRY_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g SYS_TELEMETRY_MAX_READ_BYTES="${SYS_TELEMETRY_MAX_READ_BYTES:-5242880}"

_sys_telemetry_dir_safe() {
  local target_dir="$1"
  local home_abs="${HOME:A}"
  local relative_dir="${target_dir#$HOME/}"
  local current_dir="$HOME"
  local component

  [[ "$target_dir" == "$HOME"/* && -n "$relative_dir" ]] || return 1
  for component in "${(@s:/:)relative_dir}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || return 1
    current_dir+="/$component"
    [[ ! -L "$current_dir" ]] || return 1
    if [[ -e "$current_dir" ]]; then
      [[ -d "$current_dir" && -O "$current_dir" ]] || return 1
    fi
  done
  [[ "${target_dir:A}" == "$home_abs"/* ]]
}

_sys_telemetry_format_ms() {
  local milliseconds="$1"
  if [[ ! "$milliseconds" =~ '^[0-9]+$' \
    || "$milliseconds" == 0[0-9]* \
    || ${#milliseconds} -gt 11 \
    || "$milliseconds" -gt 31536000000 ]]; then
    print -r -- "0ms"
    return 2
  fi

  if (( milliseconds < 1000 )); then
    printf '%dms' "$milliseconds"
  elif (( milliseconds < 60000 )); then
    printf '%.2fs' $(( milliseconds / 1000.0 ))
  else
    local -i total_seconds=$(( milliseconds / 1000 ))
    local -i minutes=$(( total_seconds / 60 ))
    local -i remaining_seconds=$(( total_seconds % 60 ))
    printf '%dm %ds' "$minutes" "$remaining_seconds"
  fi
}

# Status: 0 readable, 1 unsafe/unreadable, 2 invalid limit, 3 empty, 4 too large.
_sys_telemetry_validate_log() {
  local log_file="$1"
  local log_dir="${log_file:h}"
  local max_bytes="$SYS_TELEMETRY_MAX_READ_BYTES"

  [[ "$max_bytes" =~ '^[0-9]+$' \
    && "$max_bytes" != 0[0-9]* \
    && ${#max_bytes} -le 9 ]] \
    && (( max_bytes > 0 && max_bytes <= 134217728 )) || return 2
  _sys_telemetry_dir_safe "$log_dir" || return 1
  [[ -e "$log_file" ]] || return 3
  [[ -d "$log_dir" && ! -L "$log_dir" && -O "$log_dir" ]] || return 1
  [[ -f "$log_file" && ! -L "$log_file" \
    && -r "$log_file" && -O "$log_file" ]] || return 1
  [[ -s "$log_file" ]] || return 3

  local file_bytes
  file_bytes=$(command wc -c < "$log_file" 2>/dev/null) || return 1
  file_bytes="${file_bytes//[[:space:]]/}"
  [[ "$file_bytes" =~ '^[0-9]+$' && ${#file_bytes} -le 9 ]] || return 4
  (( file_bytes <= max_bytes )) || return 4
  return 0
}

_sys_telemetry_report_log_error() {
  local validation_code="$1"
  case "$validation_code" in
    1)
      _sys_error "Telemetry log must be a readable, user-owned regular file."
      ;;
    2)
      _sys_error "SYS_TELEMETRY_MAX_READ_BYTES must be a positive integer."
      ;;
    3)
      _sys_warn "No telemetry data found."
      _sys_dim "Enable telemetry with ZDX_TELEMETRY=1 in your configuration."
      ;;
    4)
      _sys_error "Telemetry log exceeds the configured read limit."
      _sys_dim "Current limit: ${SYS_TELEMETRY_MAX_READ_BYTES} bytes."
      ;;
  esac
}

# stdout TSV: timestamp, suite, command, duration-ms, exit-code.
# Malformed or unsafe records are skipped without being rendered.
_sys_telemetry_records() {
  local log_file="$1"
  _sys_telemetry_validate_log "$log_file" || return $?

  command awk '
    function key_count(key, copy) {
      copy = $0
      return gsub("\"" key "\"[[:space:]]*:", "", copy)
    }

    function string_value(key, pattern, matched) {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
      if (!match($0, pattern)) return ""
      matched = substr($0, RSTART, RLENGTH)
      sub(/^[^:]*:[[:space:]]*"/, "", matched)
      sub(/"$/, "", matched)
      return matched
    }

    function number_value(key, pattern, matched) {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*[0-9]+"
      if (!match($0, pattern)) return ""
      matched = substr($0, RSTART, RLENGTH)
      sub(/^[^:]*:[[:space:]]*/, "", matched)
      return matched
    }

    {
      if ($0 !~ /^\{.*\}$/) next
      structural = $0
      if (gsub(/\{/, "", structural) != 1) next
      structural = $0
      if (gsub(/\}/, "", structural) != 1) next
      if (key_count("suite") != 1 || key_count("command") != 1 \
          || key_count("duration_ms") != 1 || key_count("exit_code") != 1 \
          || key_count("timestamp") != 1) next
      suite = string_value("suite")
      command_name = string_value("command")
      duration = number_value("duration_ms")
      exit_code = number_value("exit_code")
      timestamp = string_value("timestamp")

      if (suite !~ /^[[:alnum:]_-]+$/ || length(suite) > 32) next
      if (command_name !~ /^[[:alnum:]_.:@+-]+$/ || length(command_name) > 96) next
      if (duration !~ /^[0-9]+$/ || duration ~ /^0[0-9]+$/ \
          || length(duration) > 11) next
      if (length(duration) == 11 && duration > 31536000000) next
      if (exit_code !~ /^[0-9]+$/ || exit_code ~ /^0[0-9]+$/ \
          || length(exit_code) > 3) next
      if (length(exit_code) == 3 && exit_code > 255) next
      if (timestamp !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) next

      printf "%s\t%s\t%s\t%s\t%s\n", \
        timestamp, suite, command_name, duration, exit_code
    }
  ' "$log_file" 2>/dev/null
}

_sys_telemetry_dashboard() {
  local log_file="$HOME/.config/zdx/telemetry.json"
  _sys_telemetry_validate_log "$log_file"
  local validation_code=$?
  if (( validation_code != 0 )); then
    _sys_telemetry_report_log_error "$validation_code"
    (( validation_code == 3 )) && return 0
    return 1
  fi

  local records_output
  records_output=$(_sys_telemetry_records "$log_file") || return 1
  local -a telemetry_records=()
  [[ -n "$records_output" ]] \
    && telemetry_records=("${(@f)records_output}")
  if (( ${#telemetry_records} == 0 )); then
    _sys_warn "No valid telemetry records found."
    return 0
  fi

  local -A suite_counts=() suite_durations=()
  local -i total_runs=0 successful_runs=0 failed_runs=0 total_duration=0
  local record_line timestamp suite_name command_name duration_ms exit_code
  for record_line in "${telemetry_records[@]}"; do
    IFS=$'\t' read -r timestamp suite_name command_name duration_ms exit_code \
      <<< "$record_line"
    (( total_runs++ ))
    (( total_duration += duration_ms ))
    if (( exit_code == 0 )); then
      (( successful_runs++ ))
    else
      (( failed_runs++ ))
    fi
    (( suite_counts[$suite_name]++ ))
    (( suite_durations[$suite_name] += duration_ms ))
  done

  local success_rate
  printf -v success_rate '%.1f' $(( successful_runs * 100.0 / total_runs ))
  local -i average_duration=$(( total_duration / total_runs ))

  _sys_header "System Telemetry Dashboard"
  _sys_info "SUMMARY STATISTICS"
  _sys_label "Total Runs:" "$total_runs"
  _sys_label "Successful:" "$successful_runs"
  _sys_label "Failed:" "$failed_runs"
  _sys_label "Success Rate:" "${success_rate}%"
  _sys_label "Total Duration:" "$(_sys_telemetry_format_ms "$total_duration")"
  _sys_label "Average:" "$(_sys_telemetry_format_ms "$average_duration")"

  _sys_blank
  _sys_info "Suite Distribution"
  local distribution_suite
  local -i suite_count suite_duration percentage bar_length=20 filled empty
  local distribution_bar
  for distribution_suite in ${(ok)suite_counts}; do
    suite_count=${suite_counts[$distribution_suite]}
    suite_duration=${suite_durations[$distribution_suite]}
    percentage=$(( suite_count * 100 / total_runs ))
    filled=$(( suite_count * bar_length / total_runs ))
    empty=$(( bar_length - filled ))
    distribution_bar="$(_sys_repeat_char '█' "$filled")$(_sys_repeat_char '░' "$empty")"
    printf '  %-12s %s %3d%% (%d runs) · %s\n' \
      "$(_sys_display_escape "$distribution_suite")" \
      "$distribution_bar" "$percentage" "$suite_count" \
      "$(_sys_telemetry_format_ms "$suite_duration")" >&2
  done

  _sys_blank
  _sys_info "Top Slowest Executions"
  local slow_output
  slow_output=$(printf '%s\n' "${telemetry_records[@]}" \
    | LC_ALL=C command sort -t $'\t' -k4,4nr \
    | command head -n 5)
  local -a slow_records=()
  [[ -n "$slow_output" ]] && slow_records=("${(@f)slow_output}")
  local -i display_index=0
  for record_line in "${slow_records[@]}"; do
    IFS=$'\t' read -r timestamp suite_name command_name duration_ms exit_code \
      <<< "$record_line"
    (( display_index++ ))
    printf '  %d. %s:%s · %s · exit %d · %s\n' \
      "$display_index" "$(_sys_display_escape "$suite_name")" \
      "$(_sys_display_escape "$command_name")" \
      "$(_sys_telemetry_format_ms "$duration_ms")" "$exit_code" \
      "$(_sys_display_escape "$timestamp")" >&2
  done

  _sys_blank
  _sys_info "Recent Executions"
  local -i record_index recent_start=$(( ${#telemetry_records} - 4 ))
  (( recent_start < 1 )) && recent_start=1
  local result_label
  for (( record_index=${#telemetry_records}; record_index>=recent_start; record_index-- )); do
    record_line="${telemetry_records[record_index]}"
    IFS=$'\t' read -r timestamp suite_name command_name duration_ms exit_code \
      <<< "$record_line"
    result_label="success"
    (( exit_code != 0 )) && result_label="failure"
    printf '  [%s] %s:%s · %s · exit %d · %s\n' \
      "$result_label" "$(_sys_display_escape "$suite_name")" \
      "$(_sys_display_escape "$command_name")" \
      "$(_sys_telemetry_format_ms "$duration_ms")" "$exit_code" \
      "$(_sys_display_escape "$timestamp")" >&2
  done
  return 0
}

_sys_telemetry_browse() {
  local REPLY
  if ! command -v fzf &>/dev/null; then
    _sys_error "fzf not found. Use 'sys-telemetry --dashboard' instead."
    return 1
  fi

  local log_file="$HOME/.config/zdx/telemetry.json"
  _sys_telemetry_validate_log "$log_file"
  local validation_code=$?
  if (( validation_code != 0 )); then
    _sys_telemetry_report_log_error "$validation_code"
    (( validation_code == 3 )) && return 0
    return 1
  fi

  local records_output
  records_output=$(_sys_telemetry_records "$log_file") || return 1
  local -a telemetry_records=()
  [[ -n "$records_output" ]] \
    && telemetry_records=("${(@f)records_output}")
  if (( ${#telemetry_records} == 0 )); then
    _sys_warn "No valid telemetry records found."
    return 0
  fi

  local -a browser_records=()
  local -i record_index
  local record_line timestamp suite_name command_name duration_ms exit_code
  local result_label duration_label display_label
  for (( record_index=${#telemetry_records}; record_index>=1; record_index-- )); do
    record_line="${telemetry_records[record_index]}"
    IFS=$'\t' read -r timestamp suite_name command_name duration_ms exit_code \
      <<< "$record_line"
    result_label="ok"
    (( exit_code != 0 )) && result_label="failed"
    duration_label=$(_sys_telemetry_format_ms "$duration_ms")
    display_label="[$result_label] $timestamp [$suite_name] $command_name ($duration_label)"
    browser_records+=(
      "$display_label"$'\t'"$timestamp"$'\t'"$suite_name"$'\t'"$command_name"$'\t'"$duration_ms"$'\t'"$exit_code"
    )
  done

  local selected_record=""
  local -i select_rc=0
  _sys_fzf_capture \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt='Telemetry history > ' \
    --header='Read-only history browser; Esc returns' \
    --preview='printf "Execution details\n\n  Timestamp: %s\n  Suite: %s\n  Command: %s\n  Duration: %s ms\n  Exit code: %s\n" {2} {3} {4} {5} {6}' \
    --preview-window='right:50%:wrap,<120(down:7:wrap)' \
    < <(printf '%s\n' "${browser_records[@]}") || select_rc=$?
  selected_record="$REPLY"
  if (( select_rc == 1 || select_rc == 130 )); then
    return 0
  elif (( select_rc != 0 )); then
    _sys_error \
      "fzf failed while browsing telemetry history (status $select_rc)."
    return 1
  fi
  [[ -n "$selected_record" ]] || return 0
  (( ${browser_records[(Ie)$selected_record]} > 0 )) || {
    _sys_error "The selected telemetry record was not in the browser snapshot."
    return 1
  }
  return 0
}

_sys_telemetry_clear() {
  local assume_yes="${1:-0}"
  local dry_run="${2:-0}"
  local log_file="$HOME/.config/zdx/telemetry.json"
  local log_dir="${log_file:h}"

  _sys_telemetry_dir_safe "$log_dir" || {
    _sys_error "Telemetry path must stay in user-owned directories without links."
    return 1
  }
  if [[ -L "$log_file" ]]; then
    _sys_error "Telemetry log must be a user-owned regular file, not a link."
    return 1
  fi
  if [[ ! -e "$log_file" ]]; then
    _sys_info "Telemetry log is already empty."
    return 0
  fi

  if [[ ! -f "$log_file" || ! -O "$log_file" ]]; then
    _sys_error "Telemetry log must be a user-owned regular file, not a link."
    return 1
  fi

  local -A before_state=()
  zmodload zsh/stat 2>/dev/null \
    && zstat -H before_state "$log_file" 2>/dev/null || {
      _sys_error "Unable to inspect the telemetry log safely."
      return 1
    }

  local file_bytes
  file_bytes=$(command wc -c < "$log_file" 2>/dev/null) || return 1
  file_bytes="${file_bytes//[[:space:]]/}"
  _sys_info "Telemetry clear plan: replace $log_file with an empty file."
  _sys_dim "Current size: ${file_bytes:-unknown} bytes."

  if (( dry_run )); then
    _sys_info "Dry run complete; no telemetry data was changed."
    return 0
  fi

  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive telemetry clearing requires --yes."
      return 1
    fi
    _sys_confirm "Clear the validated local telemetry log?" || {
      _sys_info "Cancelled."
      return 0
    }
  fi

  [[ -d "$log_dir" && ! -L "$log_dir" && -O "$log_dir" ]] || {
    _sys_error "Telemetry directory must be user-owned and must not be a link."
    return 1
  }
  local lock_dir="$log_dir/.telemetry.lock"
  local previous_umask
  previous_umask=$(umask)
  local clear_tmp=""
  local -i lock_acquired=0 clear_rc=0
  local -A current_state=()

  {
    umask 077
    command mkdir "$lock_dir" 2>/dev/null || {
      _sys_error "Telemetry is busy; try again."
      return 1
    }
    lock_acquired=1

    [[ -f "$log_file" && ! -L "$log_file" && -O "$log_file" ]] || {
      _sys_error "Telemetry log changed before it could be cleared."
      return 1
    }
    zstat -H current_state "$log_file" 2>/dev/null || return 1
    if [[ "${current_state[device]}:${current_state[inode]}" \
      != "${before_state[device]}:${before_state[inode]}" ]]; then
      _sys_error "Telemetry log identity changed; refusing to clear it."
      return 1
    fi

    clear_tmp=$(mktemp "$log_dir/.telemetry-clear.XXXXXX") || return 1
    command chmod 600 "$clear_tmp" 2>/dev/null || return 1
    command mv -f "$clear_tmp" "$log_file" 2>/dev/null || return 1
    clear_tmp=""
  } always {
    clear_rc=$?
    [[ -n "$clear_tmp" && -f "$clear_tmp" ]] \
      && command rm -f "$clear_tmp" 2>/dev/null
    (( lock_acquired )) && command rmdir "$lock_dir" 2>/dev/null
    umask "$previous_umask"
  }

  (( clear_rc == 0 )) || return "$clear_rc"
  _sys_success "Telemetry log cleared successfully."
  return 0
}

_sys_telemetry_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  sys-telemetry              Interactive dashboard, browser, and clear menu'
  print -u2 -r -- '  sys-telemetry --dashboard  Display validated local statistics'
  print -u2 -r -- '  sys-telemetry --browse     Browse validated history via fzf'
  print -u2 -r -- '  sys-telemetry --clear [--dry-run] [-y|--yes]'
  print -u2 -r -- '                              Safely replace the local log with an empty file'
  print -u2 -r -- '  sys-telemetry -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Dashboard and browse are read-only. --clear remains a confirmed mutation.'
}

# stdout records: label|command|description
_sys_telemetry_menu_rows_build() {
  _sys_menu_section \
    "Telemetry Analytics" \
    "Inspect validated local history or clear it explicitly." || return $?
  _sys_menu_entry \
    "View Dashboard" "--dashboard" \
    "Display read-only aggregate statistics." || return $?
  _sys_menu_entry \
    "Browse History" "--browse" \
    "Search validated records without exposing raw JSON." || return $?
  _sys_menu_entry \
    "Clear Log File" "--clear" \
    "Replace the validated log after explicit confirmation." || return $?
}

sys-telemetry() {
  case "${1:-}" in
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help does not accept additional arguments."
        return 2
      }
      _sys_telemetry_usage
      return 0
      ;;
    --dashboard)
      (( $# == 1 )) || {
        _sys_error "--dashboard accepts no arguments."
        return 2
      }
      _sys_telemetry_dashboard
      return $?
      ;;
    --browse)
      (( $# == 1 )) || {
        _sys_error "--browse accepts no arguments."
        return 2
      }
      _sys_telemetry_browse
      return $?
      ;;
    --clear)
      shift
      local -i assume_yes=0 dry_run=0
      while (( $# )); do
        case "$1" in
          -y|--yes)    assume_yes=1 ;;
          --dry-run)   dry_run=1 ;;
          *)
            _sys_error "Unknown option for --clear: $1"
            return 2
            ;;
        esac
        shift
      done
      _sys_telemetry_clear "$assume_yes" "$dry_run"
      return $?
      ;;
    "") ;;
    *)
      _sys_error "Unknown option: $1"
      return 2
      ;;
  esac

  if ! command -v fzf &>/dev/null; then
    _sys_error "fzf not found. Use a direct sys-telemetry flag instead."
    return 1
  fi

  local REPLY
  local rows_output=""
  local -a options=()
  local selected_record="" action_name=""
  local -i select_rc=0
  while true; do
    rows_output=$(_sys_telemetry_menu_rows_build) || return $?
    options=("${(@f)rows_output}")

    select_rc=0
    _sys_fzf_capture \
      --height=50% \
      --prompt='sys telemetry > ' \
      --header='Local command history'\
$'\n''Type to filter | Enter run | Esc cancel | Ctrl-/ details' \
      --bind='ctrl-/:toggle-preview' \
      < <(printf '%s\n' "${options[@]}") || select_rc=$?
    selected_record="$REPLY"
    if (( select_rc == 1 || select_rc == 130 )); then
      return 0
    elif (( select_rc != 0 )); then
      _sys_error \
        "fzf failed while opening the telemetry menu (status $select_rc)."
      return 1
    fi
    [[ -n "$selected_record" ]] || return 0
    (( ${options[(Ie)$selected_record]} > 0 )) || {
      _sys_error "The selected telemetry action was not in the menu snapshot."
      return 1
    }

    action_name="${${selected_record#*|}%%|*}"
    [[ "$action_name" == ":" ]] && continue

    case "$action_name" in
      --dashboard) _sys_telemetry_dashboard ;;
      --browse)    _sys_telemetry_browse ;;
      --clear)     _sys_telemetry_clear ;;
      *)
        _sys_error "Invalid telemetry action returned by fzf."
        return 1
        ;;
    esac

    [[ -t 0 ]] || return 0
    _sys_dim "Press any key to return to the Telemetry menu..."
    read -k1
  done
}

typeset -g _SYS_TELEMETRY_SOURCED=1
