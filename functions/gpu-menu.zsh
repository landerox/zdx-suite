#!/usr/bin/env zsh
# =============================================================================
# GPU Menu: public loader and command router for NVIDIA telemetry
# =============================================================================
#
# Public loader and command router for GPU monitoring workflows.
# Usage: gpu-menu [subcommand]
#

if [[ -n "${_GPU_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _gpu_loader_dir="${${(%):-%x}:A:h}"

_gpu_source_module() {
  local relative_name="$1"
  local module_path="${_gpu_loader_dir}/${relative_name}"
  [[ -f "$module_path" && ! -L "$module_path" && -r "$module_path" ]] \
    || return 1
  [[ "${module_path:A}" == "$module_path" \
    && "${module_path:A:h}" == "${module_path:h}" ]] || return 1
  builtin source "$module_path"
}

typeset -i _gpu_source_rc=0
typeset _gpu_failed_module="gpu-common.zsh"
_gpu_source_module "$_gpu_failed_module" || _gpu_source_rc=$?
if (( _gpu_source_rc == 0 )); then
  _gpu_failed_module="gpu/gpu-visualizer.zsh"
  _gpu_source_module "$_gpu_failed_module" || _gpu_source_rc=$?
fi
if (( _gpu_source_rc != 0 )); then
  print -u2 -r -- \
    "gpu-menu.zsh: failed to load $_gpu_failed_module (status $_gpu_source_rc)"
  unset -f _gpu_source_module
  unset _gpu_loader_dir _gpu_failed_module
  {
    return $_gpu_source_rc 2>/dev/null || exit $_gpu_source_rc
  } always {
    unset _gpu_source_rc
  }
fi

unset -f _gpu_source_module
unset _gpu_loader_dir _gpu_failed_module _gpu_source_rc

_gpu_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  gpu-menu'
  print -u2 -r -- '  gpu-menu gpu-visualizer [--once] [--simulate] [--gpu INDEX]'
  print -u2 -r -- '  gpu-menu -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Direct command:'
  print -u2 -r -- '  gpu-visualizer [--once] [--simulate] [--gpu INDEX]'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Hardware mode requires working nvidia-smi and timeout/gtimeout capabilities.'
  print -u2 -r -- 'Simulation is never selected automatically; use --simulate explicitly.'
}

_gpu_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    gpu-visualizer) gpu-visualizer "$@" ;;
    :)              return 0 ;;
    *)
      _gpu_error "Unknown command: $(_gpu_display_escape "$command_name")"
      return 2
      ;;
  esac
}

_gpu_interactive() {
  command -v fzf &>/dev/null || {
    _gpu_error "Interactive GPU menus require fzf."
    _gpu_dim "Run 'gpu-visualizer --once' directly or install fzf."
    return 1
  }

  local -a menu_rows=()
  local row=""
  row=$(_gpu_menu_entry \
    "Monitor NVIDIA GPU" \
    "gpu-visualizer" \
    "Show NVIDIA utilization, temperature, memory, power, and running processes.") \
    || return
  menu_rows+=("$row")

  local -i fzf_rc=0
  _gpu_fzf_capture \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='gpu > ' \
    --header='Type to filter | Enter run | Esc cancel | Ctrl-/ details' \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    --bind='ctrl-/:toggle-preview' \
    < <(printf "%s\n" "${menu_rows[@]}") || fzf_rc=$?
  local selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _gpu_fzf_rc_is_cancel "$fzf_rc" && return 0
    _gpu_error "Unable to open the GPU menu (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  local snapshot_row=""
  local -i selected_in_snapshot=0
  for snapshot_row in "${menu_rows[@]}"; do
    if [[ "$selected" == "$snapshot_row" ]]; then
      selected_in_snapshot=1
      break
    fi
  done
  (( selected_in_snapshot )) || {
    _gpu_error "The selected GPU action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  if typeset -f _timed &>/dev/null; then
    _timed "gpu:$command_name" _gpu_dispatch "$command_name"
  else
    _gpu_dispatch "$command_name"
  fi
}

gpu-menu() {
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _gpu_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _gpu_error "--help accepts no arguments."
        return 2
      }
      _gpu_usage
      ;;
    -*)
      _gpu_error "Unknown option: $(_gpu_display_escape "$1")"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      if typeset -f _timed &>/dev/null; then
        _timed "gpu:$command_name" _gpu_dispatch "$command_name" "$@"
      else
        _gpu_dispatch "$command_name" "$@"
      fi
      ;;
  esac
}

typeset -g _GPU_MENU_SOURCED=1
