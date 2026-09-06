#!/usr/bin/env zsh
# =============================================================================
# GPU Visualizer: validated NVIDIA metrics and explicit simulation
# =============================================================================
#
# Loaded by gpu-menu.zsh after gpu-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GPU_VISUALIZER_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_gpu_visualizer_usage() {
  print -u2 -r -- \
    'Usage: gpu-visualizer [--once] [--simulate] [--gpu INDEX]'
  print -u2 -r -- \
    'Display validated NVIDIA telemetry; --simulate uses synthetic data explicitly.'
  print -u2 -r -- \
    'Hardware probes require timeout or gtimeout and fail closed when neither exists.'
}

_gpu_query_hardware() {
  local gpu_index="$1"
  if ! command -v nvidia-smi &>/dev/null; then
    _gpu_error "nvidia-smi is required for hardware telemetry."
    _gpu_dim "Use '--simulate' only when synthetic telemetry is intended."
    return 1
  fi
  if ! command -v timeout &>/dev/null \
    && ! command -v gtimeout &>/dev/null; then
    _gpu_error "Hardware telemetry requires timeout or gtimeout."
    return 1
  fi

  local output=""
  local -i query_rc=0

  output=$(LC_ALL=C _gpu_run_probe 3 nvidia-smi \
    --id="$gpu_index" \
    --query-gpu=temperature.gpu,fan.speed,memory.used,memory.total,utilization.gpu,power.draw,name,driver_version \
    --format=csv,noheader,nounits 2>/dev/null) || query_rc=$?
  (( query_rc == 0 )) || return $query_rc
  [[ -n "$output" && "$output" != *$'\n'* && ${#output} -le 4096 ]] \
    || return 1

  local -a fields=("${(@s:,:)output}")
  (( ${#fields} >= 8 )) || return 1

  local temp fan mem_used mem_total utilization power gpu_name driver
  _gpu_trim "${fields[1]}"; temp="$REPLY"
  _gpu_trim "${fields[2]}"; fan="$REPLY"
  _gpu_trim "${fields[3]}"; mem_used="$REPLY"
  _gpu_trim "${fields[4]}"; mem_total="$REPLY"
  _gpu_trim "${fields[5]}"; utilization="$REPLY"
  _gpu_trim "${fields[6]}"; power="$REPLY"
  gpu_name="${(j:,:)fields[7,-2]}"
  _gpu_trim "$gpu_name"; gpu_name="$REPLY"
  _gpu_trim "${fields[-1]}"; driver="$REPLY"

  if [[ "$temp" != "N/A" && "$temp" != "[Not Supported]" ]]; then
    _gpu_valid_uint "$temp" && (( ${#temp} <= 3 )) || return 1
    temp="$(( 10#$temp ))"
    (( temp <= 200 )) || return 1
  fi
  if [[ "$fan" != "N/A" && "$fan" != "[Not Supported]" ]]; then
    _gpu_valid_uint "$fan" && (( ${#fan} <= 3 )) || return 1
    fan="$(( 10#$fan ))"
    (( fan <= 100 )) || return 1
  fi
  _gpu_valid_uint "$mem_used" || return 1
  _gpu_valid_uint "$mem_total" || return 1
  _gpu_valid_uint "$utilization" || return 1
  mem_used="$(( 10#$mem_used ))"
  mem_total="$(( 10#$mem_total ))"
  utilization="$(( 10#$utilization ))"
  (( mem_total > 0 && mem_used <= mem_total && utilization <= 100 )) \
    || return 1
  [[ "$power" == "N/A" || "$power" == "[Not Supported]" ]] \
    || _gpu_valid_decimal "$power" || return 1
  [[ -n "$gpu_name" && ${#gpu_name} -le 256 \
    && "$gpu_name" != *[[:cntrl:]]* ]] || return 1
  [[ -n "$driver" && ${#driver} -le 64 \
    && "$driver" != *[[:cntrl:]]* ]] || return 1

  reply=(
    "$temp"
    "$fan"
    "$mem_used"
    "$mem_total"
    "$utilization"
    "$power"
    "$gpu_name"
    "$driver"
  )
}

_gpu_query_processes() {
  local gpu_index="$1"
  reply=()

  local output=""
  local -i query_rc=0
  output=$(LC_ALL=C _gpu_run_probe 3 nvidia-smi \
    --id="$gpu_index" \
    --query-compute-apps=pid,process_name,used_memory \
    --format=csv,noheader,nounits 2>/dev/null) || query_rc=$?
  (( query_rc == 0 )) || return $query_rc
  [[ ${#output} -le 262144 ]] || return 1
  [[ -z "$output" ]] && return 0

  local -a lines=("${(@f)output}")
  (( ${#lines} <= 256 )) || return 1

  local line pid process_name memory
  local -a fields=()
  for line in "${lines[@]}"; do
    fields=("${(@s:,:)line}")
    (( ${#fields} >= 3 )) || return 1
    _gpu_trim "${fields[1]}"; pid="$REPLY"
    _gpu_trim "${fields[-1]}"; memory="$REPLY"
    process_name="${(j:,:)fields[2,-2]}"
    _gpu_trim "$process_name"; process_name="$REPLY"

    _gpu_valid_uint "$pid" || return 1
    pid="$(( 10#$pid ))"
    [[ "$memory" == "N/A" || "$memory" == "[Not Supported]" ]] \
      || _gpu_valid_uint "$memory" || return 1
    if [[ "$memory" != "N/A" && "$memory" != "[Not Supported]" ]]; then
      memory="$(( 10#$memory ))"
    fi
    [[ -n "$process_name" && ${#process_name} -le 1024 \
      && "$process_name" != *[[:cntrl:]]* ]] || return 1
    reply+=("$pid"$'\t'"$process_name"$'\t'"$memory")
  done
}

_gpu_draw_bar() {
  local -i percentage="$1"
  local -i width="${2:-30}"
  (( percentage < 0 )) && percentage=0
  (( percentage > 100 )) && percentage=100
  (( width >= 1 && width <= 80 )) || width=30

  local -i filled=$(( percentage * width / 100 ))
  local -i empty=$(( width - filled ))
  local full_bar="${(l:$filled::█:)}"
  local empty_bar="${(l:$empty::░:)}"

  if _gpu_color_enabled; then
    local color=$'\033[1;32m'
    (( percentage > 85 )) && color=$'\033[1;31m'
    (( percentage > 65 && percentage <= 85 )) && color=$'\033[1;33m'
    printf "%s%s\033[0;90m%s\033[0m" \
      "$color" "$full_bar" "$empty_bar" >&2
  else
    printf "%s%s" "$full_bar" "$empty_bar" >&2
  fi
}

_gpu_format_temperature() {
  local temperature="$1"
  if [[ "$temperature" == "N/A" || "$temperature" == "[Not Supported]" ]]; then
    print -r -- "N/A"
    return 0
  fi

  local label="COOL"
  local color=$'\033[1;32m'
  if (( temperature >= 80 )); then
    label="CRITICAL"
    color=$'\033[1;31m'
  elif (( temperature >= 70 )); then
    label="WARM"
    color=$'\033[1;33m'
  fi

  if _gpu_color_enabled; then
    printf "%s%s°C (%s)\033[0m\n" "$color" "$temperature" "$label"
  else
    printf "%s°C (%s)\n" "$temperature" "$label"
  fi
}

_gpu_render_frame() {
  local -i simulated="$1"
  local gpu_index="$2"
  shift 2
  local temp="$1" fan="$2" mem_used="$3" mem_total="$4"
  local utilization="$5" power="$6" gpu_name="$7" driver="$8"

  local safe_name="$(_gpu_display_escape "$gpu_name")"
  local safe_driver="$(_gpu_display_escape "$driver")"
  local -i memory_percentage=$(( mem_used * 100 / mem_total ))

  _gpu_header "NVIDIA Visual Monitor"
  _gpu_label "GPU Index" "$gpu_index"
  _gpu_label "GPU Model" "$safe_name"
  _gpu_label "NVIDIA Driver" "v$safe_driver"
  (( simulated )) && _gpu_warn "Synthetic simulation was explicitly requested."
  print -u2 -r -- ""

  _gpu_label "GPU Temp" "$(_gpu_format_temperature "$temp")"
  if [[ "$fan" == "N/A" || "$fan" == "[Not Supported]" ]]; then
    _gpu_label "Fan Speed" "N/A"
  else
    _gpu_label "Fan Speed" "${fan}%"
  fi
  if [[ "$power" == "N/A" || "$power" == "[Not Supported]" ]]; then
    _gpu_label "Power Draw" "N/A"
  else
    _gpu_label "Power Draw" "${power} Watts"
  fi
  print -u2 -r -- ""

  if _gpu_color_enabled; then
    printf "\033[1;36m%-18s\033[0m " "GPU Utilization" >&2
  else
    printf "%-18s " "GPU Utilization" >&2
  fi
  _gpu_draw_bar "$utilization" 30
  printf " %s%%\n" "$utilization" >&2

  if _gpu_color_enabled; then
    printf "\033[1;36m%-18s\033[0m " "VRAM Footprint" >&2
  else
    printf "%-18s " "VRAM Footprint" >&2
  fi
  _gpu_draw_bar "$memory_percentage" 30
  printf " %s%% (%s / %s MiB)\n\n" \
    "$memory_percentage" "$mem_used" "$mem_total" >&2
}

_gpu_render_processes() {
  local -a process_records=("$@")
  _gpu_info "GPU Active Process Occupancy:"
  print -u2 -r -- ""

  if (( ${#process_records} == 0 )); then
    _gpu_dim "No processes currently consuming hardware compute."
    return 0
  fi

  printf "  %-8s  %-40s  %-12s\n" \
    "PID" "PROCESS CONTEXT" "VRAM ALLOC" >&2
  _gpu_dim "  ----------------------------------------------------------------"

  local record pid process_name memory
  for record in "${process_records[@]}"; do
    IFS=$'\t' read -r pid process_name memory <<< "$record"
    process_name=$(_gpu_display_escape "$process_name")
    (( ${#process_name} > 40 )) && process_name="${process_name[1,37]}..."
    [[ "$memory" == "N/A" || "$memory" == "[Not Supported]" ]] \
      && memory="N/A" \
      || memory="${memory} MiB"
    printf "  %-8s  %-40s  %-12s\n" \
      "$pid" "$process_name" "$memory" >&2
  done
}

gpu-visualizer() {
  emulate -L zsh
  setopt local_traps
  # Interactive job-control shells reserve TTIN/TTOU until MONITOR is disabled.
  # LOCAL_OPTIONS restores the caller's job-control setting on return.
  unsetopt monitor
  trap '' TTIN TTOU

  local -i once=0 simulate=0
  local gpu_index="0"

  while (( $# > 0 )); do
    case "$1" in
      --once)
        once=1
        ;;
      --simulate)
        simulate=1
        ;;
      --gpu)
        shift
        _gpu_valid_uint "${1:-}" \
          && (( ${#1} <= 3 && 10#$1 <= 255 )) || {
          _gpu_error "--gpu requires an index between 0 and 255."
          return 2
        }
        gpu_index="$(( 10#$1 ))"
        ;;
      -h|--help)
        (( $# == 1 )) || {
          _gpu_error "--help accepts no arguments."
          return 2
        }
        _gpu_visualizer_usage
        return 0
        ;;
      -*)
        _gpu_error "Unknown option: $(_gpu_display_escape "$1")"
        return 2
        ;;
      *)
        _gpu_error "Unexpected argument: $(_gpu_display_escape "$1")"
        return 2
        ;;
    esac
    shift
  done

  if (( ! once )) && ! _gpu_terminal_is_foreground; then
    _gpu_warn \
      "Continuous mode requires a foreground terminal; rendering one frame."
    once=1
  fi
  local -i continuous_mode=$(( ! once ))

  local -a metrics=() process_records=()
  local -i frame_rc=0
  while true; do
    frame_rc=0
    if (( continuous_mode )) && _gpu_terminal_is_foreground; then
      printf "\033[H\033[2J" >&2
    elif (( continuous_mode )); then
      return 0
    fi

    if (( simulate )); then
      local -i utilization=$(( RANDOM % 100 ))
      local -i memory_total=24576
      local -i memory_used=$(( utilization * memory_total / 100 + RANDOM % 800 ))
      (( memory_used > memory_total )) && memory_used=$memory_total
      metrics=(
        "$(( 45 + RANDOM % 32 ))"
        "$(( 10 + RANDOM % 75 ))"
        "$memory_used"
        "$memory_total"
        "$utilization"
        "$(( 45 + RANDOM % 275 )).$(( RANDOM % 10 ))"
        "Synthetic NVIDIA GPU"
        "simulation"
      )
      process_records=(
        "1214"$'\t'"/usr/lib/xorg/Xorg"$'\t'"256"
        "3455"$'\t'"/usr/bin/gnome-shell"$'\t'"384"
        "15432"$'\t'"python3 training.py"$'\t'"$(( 2000 + RANDOM % 16000 ))"
      )
    else
      local -i hardware_rc=0
      _gpu_query_hardware "$gpu_index" || hardware_rc=$?
      if (( hardware_rc != 0 )); then
        _gpu_error "Could not obtain valid NVIDIA metrics for GPU $gpu_index."
        return $hardware_rc
      fi
      metrics=("${reply[@]}")
      local -i processes_rc=0
      _gpu_query_processes "$gpu_index" || processes_rc=$?
      (( processes_rc != 130 && processes_rc != 143 )) || return $processes_rc
      frame_rc=$processes_rc
      process_records=()
      (( processes_rc == 0 )) && process_records=("${reply[@]}")
    fi

    if (( continuous_mode )) && ! _gpu_terminal_is_foreground; then
      return 0
    fi
    _gpu_render_frame "$simulate" "$gpu_index" "${metrics[@]}"
    if (( continuous_mode )) && ! _gpu_terminal_is_foreground; then
      return 0
    fi
    if (( frame_rc == 0 )); then
      _gpu_render_processes "${process_records[@]}"
    else
      _gpu_warn "Process inventory unavailable (status $frame_rc); GPU metrics remain valid."
    fi
    (( once )) && break

    _gpu_terminal_is_foreground || return 0
    print -u2 -r -- ""
    _gpu_dim "Refreshing in 1 second... (q exits; Ctrl-C interrupts)"
    _gpu_terminal_is_foreground || return 0
    local key=""
    if read -k 1 -t 1 key 2>/dev/null \
      && [[ "$key" == "q" || "$key" == "Q" ]]; then
      if (( frame_rc == 0 )); then
        _gpu_success "Visual monitoring ended cleanly."
      else
        _gpu_info "Visual monitoring ended with unavailable process data."
      fi
      break
    fi
  done
  return $frame_rc
}

typeset -g _GPU_VISUALIZER_SOURCED=1
