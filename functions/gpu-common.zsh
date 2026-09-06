#!/usr/bin/env zsh
# =============================================================================
# GPU Common: logging, validation, menu records, and foreground selection
# =============================================================================
#
# Loaded by gpu-menu.zsh before every module under functions/gpu/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_GPU_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_gpu_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_gpu_header() {
  if _gpu_color_enabled; then
    printf "\n\033[1;36m════ %s ════\033[0m\n\n" "$1" >&2
  else
    printf "\n════ %s ════\n\n" "$1" >&2
  fi
}

_gpu_success() {
  if _gpu_color_enabled; then
    printf "\033[1;32m✔ %s\033[0m\n" "$1" >&2
  else
    printf "✔ %s\n" "$1" >&2
  fi
}

_gpu_warn() {
  if _gpu_color_enabled; then
    printf "\033[1;33m⚠ %s\033[0m\n" "$1" >&2
  else
    printf "⚠ %s\n" "$1" >&2
  fi
}

_gpu_info() {
  if _gpu_color_enabled; then
    printf "\033[0;34m➜ %s\033[0m\n" "$1" >&2
  else
    printf "➜ %s\n" "$1" >&2
  fi
}

_gpu_error() {
  if _gpu_color_enabled; then
    printf "\033[1;31m✘ %s\033[0m\n" "$1" >&2
  else
    printf "✘ %s\n" "$1" >&2
  fi
}

_gpu_dim() {
  if _gpu_color_enabled; then
    printf "\033[0;90m  %s\033[0m\n" "$1" >&2
  else
    printf "  %s\n" "$1" >&2
  fi
}

_gpu_label() {
  local label="$1"
  local value="$2"
  if _gpu_color_enabled; then
    printf "\033[1;36m%-18s\033[0m %s\n" "$label" "$value" >&2
  else
    printf "%-18s %s\n" "$label" "$value" >&2
  fi
}

# stdout: a terminal-safe visible representation of arbitrary data.
_gpu_display_escape() {
  print -r -- "${(V)1}"
}

_gpu_menu_field_safe() {
  [[ "$1" != *'|'* && "$1" != *[[:cntrl:]]* ]]
}

_gpu_system_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_gpu_validate_ancestor_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local child_path="${1:-}"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _gpu_system_root_uid || return 1
  local -i system_root_uid=$REPLY
  local parent_path=""
  local -A parent_state=()
  while [[ "$child_path" != "/" ]]; do
    parent_path="${child_path:h}"
    parent_state=()
    [[ -d "$parent_path" && ! -L "$parent_path" ]] \
      && zstat -LH parent_state -- "$parent_path" 2>/dev/null || return 1
    if (( (parent_state[uid] != system_root_uid \
        && parent_state[uid] != EUID) \
      || ((parent_state[mode] & 8#22) != 0 \
        && ! (parent_state[uid] == system_root_uid \
          && (parent_state[mode] & 8#1000) != 0 \
          && (parent_state[mode] & 8#2) != 0)) )); then
      return 1
    fi
    child_path="$parent_path"
  done
}

_gpu_validate_temp_parent() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local requested_parent="${1:-}"
  REPLY=""
  while [[ "$requested_parent" != "/" && "$requested_parent" == */ ]]; do
    requested_parent="${requested_parent%/}"
  done
  [[ -n "$requested_parent" && "$requested_parent" == /* \
    && -d "$requested_parent" && ! -L "$requested_parent" \
    && "$requested_parent" == "${requested_parent:a}" \
    && "$requested_parent" == "${requested_parent:A}" ]] || return 1

  _gpu_system_root_uid || return 1
  local -i system_root_uid=$REPLY
  local -A parent_state=()
  zstat -LH parent_state -- "$requested_parent" 2>/dev/null || return 1
  if (( parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )); then
    :
  elif (( parent_state[uid] == system_root_uid \
    && (parent_state[mode] & 8#1000) != 0 \
    && (parent_state[mode] & 8#2) != 0 )); then
    :
  else
    return 1
  fi
  _gpu_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

_gpu_menu_section() {
  local title="$1"
  local description="${2:-}"

  if ! _gpu_menu_field_safe "$title" \
    || ! _gpu_menu_field_safe "$description"; then
    _gpu_error "Invalid menu section fields."
    return 2
  fi

  printf "── %s ──|:|%s\n" "$title" "$description"
}

_gpu_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"

  if ! _gpu_menu_field_safe "$label" \
    || ! _gpu_menu_field_safe "$command_name" \
    || ! _gpu_menu_field_safe "$description"; then
    _gpu_error "Invalid menu entry fields."
    return 2
  fi
  [[ "$command_name" == ":" \
    || "$command_name" =~ '^[a-z][a-z0-9-]*$' ]] || {
    _gpu_error "Invalid GPU command token."
    return 2
  }

  printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
}

_gpu_fzf() {
  local -a fzf_options=(
    --height=80%
    --layout=reverse
    --border=rounded
    --pointer='▶'
  )

  fzf_options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')

  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option=""
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && fzf_options+=("$theme_option")
  fi

  # Compatibility settings are local to this picker and never change the shell.
  local -a terminal_options=()
  local terminal_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
  if [[ -n "${ZDX_FZF_PLAIN:-}" || "$terminal_locale" == C \
    || "$terminal_locale" == POSIX || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-unicode '--pointer=>' '--marker=+')
  fi
  if [[ -n "${NO_COLOR:-}" || -n "${ZDX_FZF_PLAIN:-}" \
    || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-color)
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh command fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

# Runs fzf synchronously in the terminal foreground.
# stdout from fzf is captured privately; REPLY contains the selection.
_gpu_fzf_capture() {
  emulate -L zsh
  REPLY=""

  zmodload zsh/stat zsh/system 2>/dev/null || {
    _gpu_error "Zsh file-descriptor support is required for GPU menus."
    return 125
  }

  _gpu_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _gpu_error "Refusing an unsafe temporary root for the GPU menu."
    return 125
  }
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-gpu-fzf.XXXXXX" 2>/dev/null) || {
    _gpu_error "Could not create a private GPU menu directory."
    return 125
  }
  command chmod 700 -- "$capture_dir" 2>/dev/null || {
    command rmdir -- "$capture_dir" 2>/dev/null
    _gpu_error "Could not protect the GPU menu directory."
    return 125
  }

  local -A directory_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || ! -d "$capture_dir" || -L "$capture_dir" ]] \
    || ! zstat -LH directory_state -- "$capture_dir" 2>/dev/null \
    || (( directory_state[uid] != EUID \
      || (directory_state[mode] & 8#77) != 0 )); then
    command rmdir -- "$capture_dir" 2>/dev/null
    _gpu_error "Refusing an unsafe GPU menu directory."
    return 125
  fi
  local directory_identity="${directory_state[device]}:${directory_state[inode]}:${directory_state[mode]}:${directory_state[uid]}"

  local capture_file=""
  local file_identity=""
  local selection=""
  local -i write_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A file_state=() current_directory_state=() current_file_state=()

  {
    capture_file=$(umask 077; command mktemp \
      "$capture_dir/.result.XXXXXX" 2>/dev/null)
    if [[ -z "$capture_file" ]]; then
      _gpu_error "Could not create a private GPU menu result."
    elif ! command chmod 600 -- "$capture_file" 2>/dev/null; then
      _gpu_error "Could not protect the GPU menu result."
    elif [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$capture_dir" \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 )); then
      _gpu_error "Refusing an unsafe GPU menu result."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$capture_file" 2>/dev/null; then
        _gpu_error "Could not open the GPU menu result safely."
      else
        _gpu_fzf "$@" 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
          || [[ "${current_directory_state[device]}:${current_directory_state[inode]}:${current_directory_state[mode]}:${current_directory_state[uid]}" \
            != "$directory_identity" ]] \
          || ! zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > 1024 * 1024 )); then
          _gpu_error "The GPU menu result changed or is oversized."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _gpu_error "Could not read the GPU menu result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          operation_rc=$fzf_rc
        fi
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    if [[ -n "$capture_file" && ( -e "$capture_file" || -L "$capture_file" ) ]]; then
      current_file_state=()
      if [[ -n "$file_identity" && -f "$capture_file" \
        && ! -L "$capture_file" && "${capture_file:h}" == "$capture_dir" ]] \
        && zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
        && [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
          == "$file_identity" ]]; then
        command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
      else
        cleanup_failed=1
      fi
    fi

    current_directory_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" ]] \
      && zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_directory_state[device]}:${current_directory_state[inode]}:${current_directory_state[mode]}:${current_directory_state[uid]}" \
        == "$directory_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi

    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_gpu_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

_gpu_trim() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  REPLY="${${1##[[:space:]]#}%%[[:space:]]#}"
}

_gpu_valid_uint() {
  local value="${1:-}"
  [[ ${#value} -le 12 \
    && ( "$value" == "0" || "$value" =~ '^[1-9][0-9]*$' ) ]]
}

_gpu_valid_decimal() {
  [[ "${1:-}" =~ '^[0-9]+([.][0-9]+)?$' && ${#1} -le 20 ]]
}

_gpu_run_probe() {
  local -i seconds="${1:-3}"
  shift

  if command -v timeout &>/dev/null; then
    command timeout -k 1s "${seconds}s" "$@"
  elif command -v gtimeout &>/dev/null; then
    command gtimeout -k 1s "${seconds}s" "$@"
  else
    _gpu_error "A bounded timeout command is required for NVIDIA probes."
    return 1
  fi
}

_gpu_terminal_is_foreground() {
  [[ -t 0 && -t 2 && -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] || return 1
  command -v ps &>/dev/null || return 1
  zmodload zsh/stat zsh/system 2>/dev/null || return 1

  local -A stdin_state=() stderr_state=()
  zstat -H stdin_state -f 0 2>/dev/null \
    && zstat -H stderr_state -f 2 2>/dev/null \
    && [[ "${stdin_state[device]}:${stdin_state[inode]}:${stdin_state[rdev]}" \
      == "${stderr_state[device]}:${stderr_state[inode]}:${stderr_state[rdev]}" ]] \
    || return 1

  local process_id="${sysparams[pid]:-}"
  _gpu_valid_uint "$process_id" || return 1
  local process_group=""
  local terminal_group=""
  process_group=$(command ps -o pgid= -p "$process_id" 2>/dev/null) \
    || return 1
  terminal_group=$(command ps -o tpgid= -p "$process_id" 2>/dev/null) \
    || return 1
  _gpu_trim "$process_group"
  process_group="$REPLY"
  _gpu_trim "$terminal_group"
  terminal_group="$REPLY"
  _gpu_valid_uint "$process_group" \
    && _gpu_valid_uint "$terminal_group" \
    && [[ "$process_group" == "$terminal_group" ]]
}

typeset -g _GPU_COMMON_SOURCED=1
