#!/usr/bin/env zsh
# =============================================================================
# App Suite: private UI, task-record, path, and selection primitives
# =============================================================================
#
# Loaded by app-menu.zsh before every module under functions/app/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_APP_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _APP_MAX_DESCRIPTOR_BYTES=2097152
typeset -gi _APP_MAX_TASKS=512
typeset -gi _APP_MAX_TASK_TOKEN=128
typeset -gi _APP_MAX_PICKER_BYTES=1048576

_app_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

_app_header() {
  if _app_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}

_app_success() {
  if _app_color_enabled; then
    printf '\033[1;32m✔ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✔ %s\n' "${(V)1}" >&2
  fi
}

_app_warn() {
  if _app_color_enabled; then
    printf '\033[1;33m⚠ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⚠ %s\n' "${(V)1}" >&2
  fi
}

_app_info() {
  if _app_color_enabled; then
    printf '\033[0;36m➜ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '➜ %s\n' "${(V)1}" >&2
  fi
}

_app_error() {
  if _app_color_enabled; then
    printf '\033[1;31m✘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✘ %s\n' "${(V)1}" >&2
  fi
}

_app_timed() {
  local label="$1"
  shift

  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

_app_require_cmd() {
  local command_name="$1"
  local purpose="${2:-this operation}"
  command -v "$command_name" &>/dev/null && return 0
  _app_error "$command_name is required for $purpose."
  return 1
}

_app_visible_field_safe() {
  local value="${1:-}"
  local -i maximum_length="${2:-1024}"
  (( maximum_length >= 1 && maximum_length <= 65536 )) || return 1
  (( ${#value} <= maximum_length )) \
    && [[ "$value" != *[[:cntrl:]]* ]]
}

_app_system_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_app_validate_ancestor_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local child_path="${1:-}"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _app_system_root_uid || return 1
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

_app_validate_temp_parent() {
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

  _app_system_root_uid || return 1
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
  _app_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

_app_validate_workspace() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local requested_workspace="${1:-}"
  REPLY=""

  [[ -n "$requested_workspace" && "$requested_workspace" == /* \
    && "$requested_workspace" == "${requested_workspace:a}" \
    && "$requested_workspace" == "${requested_workspace:A}" \
    && -d "$requested_workspace" && ! -L "$requested_workspace" ]] || {
    _app_error "The workspace must be an absolute, canonical real directory."
    return 1
  }
  _app_visible_field_safe "$requested_workspace" 4096 || {
    _app_error "The workspace path contains unsupported characters."
    return 1
  }

  _app_system_root_uid || return 1
  local -i system_root_uid=$REPLY
  local -A workspace_state=()
  zstat -LH workspace_state -- "$requested_workspace" 2>/dev/null || return 1
  (( (workspace_state[uid] == EUID \
      || workspace_state[uid] == system_root_uid) \
    && (workspace_state[mode] & 8#22) == 0 \
    && (workspace_state[mode] & 8#170000) == 8#040000 )) || {
    _app_error "The workspace has unsafe ownership or permissions."
    return 1
  }
  _app_validate_ancestor_chain "$requested_workspace" || {
    _app_error "A workspace ancestor is not trusted against replacement."
    return 1
  }
  REPLY="$requested_workspace"
}

_app_sha256_digest() {
  local input_file="${1:-}"
  REPLY=""
  local digest_output=""
  local -i digest_rc=1

  if command -v sha256sum &>/dev/null; then
    digest_output=$(command sha256sum -- "$input_file")
    digest_rc=$?
  elif command -v shasum &>/dev/null; then
    digest_output=$(command shasum -a 256 -- "$input_file")
    digest_rc=$?
  else
    _app_error "sha256sum or shasum is required for task revalidation."
    return 1
  fi
  (( digest_rc == 0 )) || return $digest_rc

  local digest="${digest_output%%[[:space:]]*}"
  digest="${digest:l}"
  [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || return 1
  REPLY="$digest"
}

_app_fingerprint_descriptor() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local workspace="${1:-}"
  local descriptor="${2:-}"
  REPLY=""

  _app_validate_workspace "$workspace" || return 1
  workspace="$REPLY"
  [[ -n "$descriptor" && "$descriptor" == /* \
    && "${descriptor:h}" == "$workspace" \
    && "$descriptor" == "${descriptor:a}" \
    && "$descriptor" == "${descriptor:A}" \
    && -f "$descriptor" && ! -L "$descriptor" ]] || {
    _app_error "The task descriptor must be a real direct child of the workspace."
    return 1
  }

  local -A descriptor_state=()
  zstat -LH descriptor_state -- "$descriptor" 2>/dev/null || return 1
  (( descriptor_state[uid] == EUID \
    && descriptor_state[nlink] == 1 \
    && (descriptor_state[mode] & 8#22) == 0 \
    && (descriptor_state[mode] & 8#170000) == 8#100000 \
    && descriptor_state[size] >= 0 \
    && descriptor_state[size] <= _APP_MAX_DESCRIPTOR_BYTES )) || {
    _app_error "The task descriptor has unsafe ownership, links, mode, or size."
    return 1
  }

  _app_sha256_digest "$descriptor" || return $?
  local digest="$REPLY"
  REPLY="${descriptor_state[device]}:${descriptor_state[inode]}:"\
"${descriptor_state[size]}:${descriptor_state[mtime]}:"\
"${descriptor_state[mode]}:${descriptor_state[uid]}:"\
"${descriptor_state[nlink]}:${digest}"
}

_app_validate_task_token() {
  local task_name="${1:-}"
  (( ${#task_name} >= 1 && ${#task_name} <= _APP_MAX_TASK_TOKEN )) \
    && [[ "$task_name" =~ '^[A-Za-z0-9][A-Za-z0-9_.:@/+:-]*$' ]]
}

_app_validate_backend() {
  case "${1:-}" in
    just|npm|pnpm|yarn|bun|make|compose) return 0 ;;
    *) return 1 ;;
  esac
}

_app_validate_action() {
  case "${1:-}" in
    run|up|down|ps|up-service|restart-service|logs-service) return 0 ;;
    *) return 1 ;;
  esac
}

_app_validate_backend_action() {
  local backend="${1:-}"
  local task_name="${2:-}"
  local action="${3:-}"

  case "$backend:$action" in
    just:run|npm:run|pnpm:run|yarn:run|bun:run|make:run)
      return 0
      ;;
    compose:up|compose:down|compose:ps)
      [[ "$task_name" == "all" ]]
      ;;
    compose:up-service|compose:restart-service|compose:logs-service)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# stdout record:
# backend<TAB>workspace<TAB>descriptor<TAB>task<TAB>action<TAB>fingerprint
_app_task_record() {
  local backend="$1"
  local workspace="$2"
  local descriptor="$3"
  local task_name="$4"
  local action="$5"
  local fingerprint="$6"

  _app_validate_backend "$backend" \
    && _app_validate_task_token "$task_name" \
    && _app_validate_action "$action" \
    && _app_validate_backend_action "$backend" "$task_name" "$action" \
    && _app_visible_field_safe "$workspace" 4096 \
    && _app_visible_field_safe "$descriptor" 4096 \
    && _app_visible_field_safe "$fingerprint" 1024 || {
    _app_error "Refusing an invalid task record."
    return 2
  }

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$backend" "$workspace" "$descriptor" "$task_name" "$action" "$fingerprint"
}

_app_parse_task_record() {
  local record="${1:-}"
  local backend="" workspace="" descriptor="" task_name="" action=""
  local fingerprint="" extra=""
  reply=()

  [[ -n "$record" && "$record" != *$'\n'* && "$record" != *$'\r'* ]] \
    || return 1
  IFS=$'\t' read -r backend workspace descriptor task_name action \
    fingerprint extra <<< "$record"
  [[ -z "$extra" ]] || return 1
  _app_validate_backend "$backend" \
    && _app_validate_task_token "$task_name" \
    && _app_validate_action "$action" \
    && _app_validate_backend_action "$backend" "$task_name" "$action" \
    && _app_visible_field_safe "$workspace" 4096 \
    && _app_visible_field_safe "$descriptor" 4096 \
    && _app_visible_field_safe "$fingerprint" 1024 || return 1
  reply=("$backend" "$workspace" "$descriptor" "$task_name" "$action" \
    "$fingerprint")
}

# stdout record: label|app-run|description|one-based task index
_app_task_menu_row() {
  local label="$1"
  local description="$2"
  local task_index="$3"

  _app_visible_field_safe "$label" 256 \
    && _app_visible_field_safe "$description" 1024 \
    && [[ "$label" != *'|'* && "$description" != *'|'* \
      && "$task_index" =~ '^[1-9][0-9]*$' ]] || {
    _app_error "Refusing an invalid App menu row."
    return 2
  }
  printf '  %s|app-run|%s|%s\n' "$label" "$description" "$task_index"
}

_app_fzf() {
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

# Runs fzf synchronously in the terminal foreground and returns its selection
# in REPLY. The result file is private, bounded, and removed by exact identity.
_app_fzf_capture() {
  emulate -L zsh
  REPLY=""

  zmodload zsh/stat zsh/system 2>/dev/null || {
    _app_error "Zsh file-descriptor support is required for App menus."
    return 125
  }
  _app_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _app_error "Refusing an unsafe temporary root for the App menu."
    return 125
  }
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-app-fzf.XXXXXX" 2>/dev/null) || {
    _app_error "Could not create a private App menu directory."
    return 125
  }

  local -A directory_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || "${capture_dir:h}" != "$temp_root" \
    || "${capture_dir:t}" != zdx-app-fzf.* \
    || ! -d "$capture_dir" || -L "$capture_dir" ]] \
    || ! zstat -LH directory_state -- "$capture_dir" 2>/dev/null \
    || (( directory_state[uid] != EUID \
      || (directory_state[mode] & 8#77) != 0 \
      || (directory_state[mode] & 8#170000) != 8#040000 )); then
    _app_error "Refusing an unsafe App menu directory."
    return 125
  fi
  local directory_identity="${directory_state[device]}:"\
"${directory_state[inode]}:${directory_state[mode]}:${directory_state[uid]}"

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
      _app_error "Could not create a private App menu result."
    elif [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$capture_dir" \
      || "${capture_file:t}" != .result.* \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 )); then
      _app_error "Refusing an unsafe App menu result."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:"\
"${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$capture_file" 2>/dev/null; then
        _app_error "Could not open the App menu result safely."
      else
        _app_fzf "$@" 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
          || [[ "${current_directory_state[device]}:"\
"${current_directory_state[inode]}:${current_directory_state[mode]}:"\
"${current_directory_state[uid]}" != "$directory_identity" ]] \
          || ! zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:${current_file_state[inode]}:"\
"${current_file_state[mode]}:${current_file_state[uid]}:"\
"${current_file_state[nlink]}" != "$file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > _APP_MAX_PICKER_BYTES )); then
          _app_error "The App menu result changed or is oversized."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _app_error "Could not read the App menu result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _app_error "The cancelled App menu returned unexpected data."
            selection=""
            operation_rc=125
          else
            operation_rc=$fzf_rc
          fi
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
        && [[ "${current_file_state[device]}:${current_file_state[inode]}:"\
"${current_file_state[mode]}:${current_file_state[uid]}:"\
"${current_file_state[nlink]}" == "$file_identity" ]]; then
        command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
      else
        cleanup_failed=1
      fi
    fi

    current_directory_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" ]] \
      && zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_directory_state[device]}:"\
"${current_directory_state[inode]}:${current_directory_state[mode]}:"\
"${current_directory_state[uid]}" == "$directory_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_app_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

_app_confirm() {
  local message="${1:-Run the selected project task?}"
  [[ -t 0 && -t 2 ]] || return 2

  if _app_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)message}" >&2
  else
    printf '? %s [y/N]: ' "${(V)message}" >&2
  fi
  local answer=""
  IFS= read -r answer || return 2
  print -u2 -r -- ""
  [[ "$answer" =~ ^[Yy]$ ]] && return 0
  return 130
}

_app_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    app-list) app-list "$@" ;;
    app-run)  app-run "$@" ;;
    :)        return 0 ;;
    "")
      _app_error "A command is required."
      return 2
      ;;
    *)
      _app_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

typeset -g _APP_COMMON_SOURCED=1
