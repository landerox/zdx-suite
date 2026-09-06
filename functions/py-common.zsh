#!/usr/bin/env zsh
# =============================================================================
# Py Common: shared UI, validation, confirmation, and picker helpers
# =============================================================================
#
# Sourced by py-menu.zsh before loading modules under py/.
# Idempotent and free of source-time capability probes.
#

if [[ -n "${_PY_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_py_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb && -t 2 ]]
}

_py_log() {
  local plain_prefix="$1" color="$2" message="$3"
  if _py_color_enabled; then
    print -u2 -r -- "${color}${plain_prefix} ${message}"$'\e[0m'
  else
    print -u2 -r -- "${plain_prefix} ${message}"
  fi
}

_py_header() {
  print -u2 -r -- ""
  if _py_color_enabled; then
    print -u2 -r -- $'\e[1;34m'"════ $1 ════"$'\e[0m'
  else
    print -u2 -r -- "════ $1 ════"
  fi
  print -u2 -r -- ""
}

_py_success() { _py_log "✔" $'\e[1;32m' "$1"; }
_py_warn()    { _py_log "⚠" $'\e[1;33m' "$1"; }
_py_info()    { _py_log "➜" $'\e[0;36m' "$1"; }
_py_error()   { _py_log "✘" $'\e[1;31m' "$1"; }
_py_dim()     { _py_log " " $'\e[0;90m' "$1"; }

_py_debug() {
  [[ "${PY_SUITE_DEBUG:-0}" == 1 ]] \
    && _py_log " " $'\e[0;90m' "[debug] $1"
  return 0
}

_py_check_command() {
  local command_name="${1:-}"
  [[ -n "$command_name" ]] || {
    _py_error "Internal error: a command name is required."
    return 2
  }
  command -v "$command_name" &>/dev/null || {
    _py_error "$command_name not found."
    return 1
  }
}

# Sets reply to a bounded external-command prefix. Py read-only inventories
# fail closed when neither GNU timeout nor gtimeout is available.
_py_timeout_prefix() {
  emulate -L zsh
  reply=()

  local -i seconds=${1:-0}
  (( seconds >= 1 && seconds <= 60 )) || {
    _py_error "Internal error: invalid Py probe deadline."
    return 2
  }

  local candidate="" resolved_command=""
  for candidate in timeout gtimeout; do
    resolved_command=$(whence -p "$candidate" 2>/dev/null) \
      || resolved_command=""
    [[ -n "$resolved_command" && -x "$resolved_command" ]] || continue
    reply=("$resolved_command" -k 2s "${seconds}s")
    return 0
  done

  _py_error "Py inventories require timeout or gtimeout."
  return 1
}

# Run uv without environment variables that can redirect project discovery or
# the project environment away from the path reviewed by this suite.
_py_run_uv_scoped() {
  emulate -L zsh
  local uv_command="" env_command=""
  uv_command=$(whence -p uv 2>/dev/null) || uv_command=""
  env_command=$(whence -p env 2>/dev/null) || env_command=""
  [[ -n "$uv_command" && -x "$uv_command" ]] || {
    _py_error "uv not found."
    return 1
  }
  [[ -n "$env_command" && -x "$env_command" ]] || {
    _py_error "env is required for target-bound uv execution."
    return 1
  }
  command "$env_command" \
    -u UV_PROJECT \
    -u UV_PROJECT_ENVIRONMENT \
    -u UV_WORKING_DIR \
    "$uv_command" "$@"
}

_py_require_tomllib() {
  _py_check_command python3 || return $?
  command python3 -I -c 'import tomllib' </dev/null >/dev/null 2>&1 || {
    _py_error "Python 3.11 or newer is required for project metadata."
    return 1
  }
}

_py_timed() {
  local label="$1"
  shift
  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

_py_confirmation_available() {
  [[ -t 0 && -t 2 ]]
}

# Return 0 for yes, 130 for a user decline, and 1 when no TTY is available.
_py_confirm() {
  local message="${1:-Proceed?}"
  if [[ "${_PY_AUTO_YES:-0}" == 1 ]]; then
    _py_debug "Auto-confirmed: $message"
    return 0
  fi
  _py_confirmation_available || {
    _py_error "Confirmation is unavailable; rerun with --yes after reviewing the plan."
    return 1
  }

  local reply=""
  if _py_color_enabled; then
    print -nu2 -r -- $'\e[1;33m'"? $message [y/N]: "$'\e[0m'
  else
    print -nu2 -r -- "? $message [y/N]: "
  fi
  read -r -k 1 reply
  local read_rc=$?
  print -u2 -r -- ""
  (( read_rc == 0 )) || return 130
  [[ "$reply" == [Yy] ]] || return 130
  return 0
}

_py_confirm_or_cancel() {
  _py_confirm "$1"
  local confirm_rc=$?
  case "$confirm_rc" in
    0) return 0 ;;
    130)
      _py_info "Cancelled."
      return 130
      ;;
    *) return "$confirm_rc" ;;
  esac
}

_py_value_is_safe() {
  local value="${1:-}"
  [[ "$value" != *[[:cntrl:]]* && "$value" != *'|'* ]]
}

_py_system_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_py_validate_ancestor_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local child_path="${1:-}"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _py_system_root_uid || return 1
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

_py_validate_temp_parent() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local requested_parent="${1:-}"
  REPLY=""
  while [[ "$requested_parent" != / && "$requested_parent" == */ ]]; do
    requested_parent="${requested_parent%/}"
  done
  [[ -n "$requested_parent" && "$requested_parent" == /* \
    && -d "$requested_parent" && ! -L "$requested_parent" \
    && "$requested_parent" == "${requested_parent:a}" \
    && "$requested_parent" == "${requested_parent:A}" ]] || return 1

  _py_system_root_uid || return 1
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
  _py_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

_py_menu_section() {
  local title="${1:-}" description="${2:-}"
  _py_value_is_safe "$title" && _py_value_is_safe "$description" || {
    _py_error "Refusing an unsafe Py menu section."
    return 1
  }
  print -r -- "── $title ──|:|$description"
}

_py_menu_entry() {
  local label="${1:-}" command_name="${2:-}" description="${3:-}"
  _py_value_is_safe "$label" \
    && _py_value_is_safe "$command_name" \
    && _py_value_is_safe "$description" || {
    _py_error "Refusing an unsafe Py menu entry."
    return 1
  }
  [[ -n "$label" && -n "$command_name" ]] || {
    _py_error "Refusing an incomplete Py menu entry."
    return 1
  }
  print -r -- "  ● $label|$command_name|$description"
}

_py_array_contains_literal() {
  local needle="${1-}" candidate=""
  shift 2>/dev/null || return 2
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

_py_fzf() {
  local -a fzf_options=(
    --height=80%
    --layout=reverse
    --border=rounded
    '--delimiter=[|]'
    --with-nth=1
    '--pointer=▶'
  )
  fzf_options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')

  if [[ -z "${NO_COLOR:-}" ]] && typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option=""
    theme_option=$(_tk_fzf_color_opts 2>/dev/null) || theme_option=""
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
    SHELL=/bin/sh fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

_py_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

# Execute one read-only producer, bound its stdout, and emit the captured data.
_py_capture_bounded_output() {
  emulate -L zsh
  local -i max_bytes=${1:-0}
  local label="${2:-command}"
  shift 2
  (( max_bytes > 0 && max_bytes <= 64 * 1024 * 1024 && $# > 0 )) || {
    _py_error "Internal error: invalid bounded-output request."
    return 1
  }
  local head_command=""
  head_command=$(whence -p head 2>/dev/null) || head_command=""
  [[ -n "$head_command" && -x "$head_command" ]] || {
    _py_error "head is required for byte-bounded Py inventories."
    return 1
  }

  zmodload zsh/stat 2>/dev/null || {
    _py_error "Zsh stat support is required for bounded command output."
    return 1
  }
  _py_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _py_error "Refusing an unsafe temporary root for $label."
    return 1
  }
  local temp_root="$REPLY"

  local capture_file=""
  capture_file=$(umask 077; command mktemp \
    "$temp_root/zdx-py-output.XXXXXX" 2>/dev/null) || {
    _py_error "Could not create private output storage for $label."
    return 1
  }
  command chmod 600 -- "$capture_file" 2>/dev/null || {
    command rm -f -- "$capture_file" 2>/dev/null
    _py_error "Could not protect private output storage for $label."
    return 1
  }

  local -A initial_state=() current_state=()
  [[ "$capture_file" == "${capture_file:a}" \
    && "$capture_file" == "${capture_file:A}" \
    && -f "$capture_file" && ! -L "$capture_file" ]] \
    && zstat -LH initial_state -- "$capture_file" 2>/dev/null \
    && (( (initial_state[mode] & 8#170000) == 8#100000 \
      && initial_state[uid] == EUID \
      && initial_state[nlink] == 1 \
      && (initial_state[mode] & 8#77) == 0 )) || {
    command rm -f -- "$capture_file" 2>/dev/null
    _py_error "Refusing unsafe output storage for $label."
    return 1
  }
  local identity="${initial_state[device]}:${initial_state[inode]}:${initial_state[uid]}:${initial_state[nlink]}"
  local output=""
  local -a pipeline_rcs=()
  local -i producer_rc=1 limiter_rc=1 operation_rc=1 cleanup_failed=0

  {
    command "$@" \
      | command "$head_command" -c "$(( max_bytes + 1 ))" \
        >"$capture_file"
    pipeline_rcs=("${pipestatus[@]}")
    producer_rc=${pipeline_rcs[1]:-1}
    limiter_rc=${pipeline_rcs[2]:-1}

    current_state=()
    if ! zstat -LH current_state -- "$capture_file" 2>/dev/null \
      || [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
        != "$identity" ]] \
      || (( (current_state[mode] & 8#170000) != 8#100000 \
        || (current_state[mode] & 8#77) != 0 \
        || current_state[size] < 0 \
        || current_state[size] > max_bytes + 1 )); then
      _py_error "$label output storage changed unexpectedly."
      operation_rc=1
    elif (( current_state[size] > max_bytes )); then
      _py_error "$label output exceeded ${max_bytes} bytes."
      operation_rc=1
    elif (( limiter_rc != 0 )); then
      _py_error "$label output limiter failed (status $limiter_rc)."
      operation_rc=$limiter_rc
    elif (( producer_rc != 0 )); then
      _py_error "$label failed (status $producer_rc)."
      operation_rc=$producer_rc
    else
      output=$(<"$capture_file")
      operation_rc=0
    fi
  } always {
    current_state=()
    if [[ -f "$capture_file" && ! -L "$capture_file" ]] \
      && zstat -LH current_state -- "$capture_file" 2>/dev/null \
      && [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
        == "$identity" ]]; then
      command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
    else
      _py_warn "$label output changed; refusing cleanup."
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=1
  }

  (( operation_rc == 0 )) || return "$operation_rc"
  [[ -n "$output" ]] && print -r -- "$output"
  return 0
}

# Run fzf in the foreground and return its bounded result in REPLY.
_py_fzf_capture() {
  emulate -L zsh
  setopt local_options local_traps
  REPLY=""

  zmodload zsh/stat zsh/system 2>/dev/null || {
    _py_error "Zsh file-descriptor support is required for Py pickers."
    return 1
  }

  _py_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _py_error "Refusing an unsafe temporary root for the Py picker."
    return 1
  }
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-py-fzf.XXXXXX" 2>/dev/null) || {
    _py_error "Could not create a private Py picker directory."
    return 1
  }
  command chmod 700 -- "$capture_dir" 2>/dev/null || {
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Could not protect the Py picker directory."
    return 1
  }

  local -A dir_state=() file_state=() current_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || ! -d "$capture_dir" || -L "$capture_dir" \
    || "${capture_dir:t}" != zdx-py-fzf.* ]] \
    || ! zstat -LH dir_state -- "$capture_dir" 2>/dev/null \
    || (( (dir_state[mode] & 8#170000) != 8#040000 \
      || dir_state[uid] != EUID \
      || (dir_state[mode] & 8#77) != 0 )); then
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Refusing an unsafe Py picker directory."
    return 1
  fi
  local dir_identity="${dir_state[device]}:${dir_state[inode]}:${dir_state[uid]}"

  local capture_file=""
  capture_file=$(umask 077; command mktemp \
    "$capture_dir/.result.XXXXXX" 2>/dev/null) || {
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Could not create a private Py picker result."
    return 1
  }
  command chmod 600 -- "$capture_file" 2>/dev/null || {
    command rm -f -- "$capture_file" 2>/dev/null
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Could not protect the Py picker result."
    return 1
  }

  if [[ "$capture_file" != "${capture_file:a}" \
    || "$capture_file" != "${capture_file:A}" \
    || "${capture_file:h}" != "$capture_dir" \
    || ! -f "$capture_file" || -L "$capture_file" ]] \
    || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
    || (( (file_state[mode] & 8#170000) != 8#100000 \
      || file_state[uid] != EUID || file_state[nlink] != 1 \
      || (file_state[mode] & 8#77) != 0 )); then
    command rm -f -- "$capture_file" 2>/dev/null
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Refusing an unsafe Py picker result."
    return 1
  fi

  local file_identity="${file_state[device]}:${file_state[inode]}:${file_state[uid]}:${file_state[nlink]}"
  local -i capture_fd=-1 read_fd=-1 picker_rc=1 operation_rc=1
  local -i cleanup_failed=0
  local selection=""

  {
    trap 'operation_rc=130; return 130' INT
    trap 'operation_rc=143; return 143' TERM HUP

    if sysopen -w -o nofollow,cloexec -u capture_fd \
      -- "$capture_file" 2>/dev/null; then
      _py_fzf "$@" 1>&$(( capture_fd ))
      picker_rc=$?
      exec {capture_fd}>&-
      capture_fd=-1

      dir_state=()
      current_state=()
      if zstat -LH dir_state -- "$capture_dir" 2>/dev/null \
        && [[ "${dir_state[device]}:${dir_state[inode]}:${dir_state[uid]}" \
          == "$dir_identity" ]] \
        && zstat -LH current_state -- "$capture_file" 2>/dev/null \
        && [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
          == "$file_identity" ]] \
        && (( current_state[size] >= 0 \
          && current_state[size] <= 4 * 1024 * 1024 )) \
        && sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
        selection=$(<&$(( read_fd )))
        exec {read_fd}>&-
        read_fd=-1
        operation_rc=$picker_rc
      else
        _py_error "The Py picker result changed or is oversized."
      fi
    else
      _py_error "Could not open the Py picker result safely."
    fi
  } always {
    trap - INT TERM HUP
    (( capture_fd >= 0 )) && exec {capture_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    current_state=()
    if [[ -f "$capture_file" && ! -L "$capture_file" \
      && "${capture_file:a}" == "$capture_file" \
      && "${capture_file:A}" == "$capture_file" \
      && "${capture_file:h}" == "$capture_dir" ]] \
      && zstat -LH current_state -- "$capture_file" 2>/dev/null \
      && [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
        == "$file_identity" ]]; then
      command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
    else
      _py_warn "The Py picker result changed; refusing cleanup."
      cleanup_failed=1
    fi

    dir_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" \
      && "${capture_dir:a}" == "$capture_dir" \
      && "${capture_dir:A}" == "$capture_dir" \
      && "${capture_dir:t}" == zdx-py-fzf.* ]] \
      && zstat -LH dir_state -- "$capture_dir" 2>/dev/null \
      && [[ "${dir_state[device]}:${dir_state[inode]}:${dir_state[uid]}" \
        == "$dir_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      _py_warn "The Py picker directory changed; refusing cleanup."
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=1
  }

  REPLY="$selection"
  return "$operation_rc"
}

_py_validate_package_name() {
  local package_name="${1:-}"
  [[ -n "$package_name" && ${#package_name} -le 128 \
    && "$package_name" != -* ]] \
    && [[ "$package_name" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]
}

_py_validate_python_version() {
  local version="${1:-}"
  [[ "$version" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]]
}

typeset -g _PY_COMMON_SOURCED=1
