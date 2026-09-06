#!/usr/bin/env zsh
# =============================================================================
# File Suite: private UI, selection, path, and dispatch primitives
# =============================================================================
#
# Loaded by file-menu.zsh before every module under functions/file/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_FILE_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _FILE_MAX_MENU_ROWS=64
typeset -gi _FILE_MAX_PICKER_BYTES=1048576
typeset -gi _FILE_MAX_CANDIDATES=4096
typeset -gi _FILE_MAX_ARCHIVE_ENTRIES=4096
typeset -gi _FILE_MAX_ARCHIVE_BYTES=1073741824
typeset -gi _FILE_MAX_TEXT_BYTES=1048576
typeset -g _FILE_SUITE_ROOT="${${(%):-%x}:A:h:h}"

# --- UI --------------------------------------------------------------------

_file_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

_file_header() {
  if _file_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}

_file_success() {
  if _file_color_enabled; then
    printf '\033[1;32m✔ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✔ %s\n' "${(V)1}" >&2
  fi
}

_file_warn() {
  if _file_color_enabled; then
    printf '\033[1;33m⚠ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⚠ %s\n' "${(V)1}" >&2
  fi
}

_file_info() {
  if _file_color_enabled; then
    printf '\033[0;36m➜ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '➜ %s\n' "${(V)1}" >&2
  fi
}

_file_error() {
  if _file_color_enabled; then
    printf '\033[1;31m✘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✘ %s\n' "${(V)1}" >&2
  fi
}

_file_dim() {
  if _file_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
}

_file_timed() {
  local label="$1"
  shift

  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

_file_require_cmd() {
  local command_name="$1"
  local purpose="${2:-this operation}"
  command -v "$command_name" &>/dev/null && return 0
  _file_error "$command_name is required for $purpose."
  return 1
}

_file_system_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_file_validate_temp_parent() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local requested_parent="${1:-}"
  local purpose="${2:-temporary files}"
  REPLY=""

  while [[ "$requested_parent" != "/" && "$requested_parent" == */ ]]; do
    requested_parent="${requested_parent%/}"
  done
  [[ -n "$requested_parent" && "$requested_parent" == /* \
    && -d "$requested_parent" && ! -L "$requested_parent" \
    && "$requested_parent" == "${requested_parent:a}" \
    && "$requested_parent" == "${requested_parent:A}" ]] || {
    _file_error "The temporary parent for $purpose is not a real directory."
    return 1
  }

  _file_system_root_uid || return 1
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
    _file_error \
      "The temporary parent for $purpose has unsafe ownership or permissions."
    return 1
  fi
  _file_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

_file_validate_ancestor_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local child_path="$1"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _file_system_root_uid || return 1
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
      _file_error \
        "A parent directory is not trusted against replacement: $parent_path"
      return 1
    fi
    child_path="$parent_path"
  done
}

_file_sha256_digest() {
  local input_file="$1"
  REPLY=""
  local raw_output=""
  local -i digest_rc=1
  if command -v sha256sum &>/dev/null; then
    raw_output=$(command sha256sum -- "$input_file")
    digest_rc=$?
  elif command -v shasum &>/dev/null; then
    raw_output=$(command shasum -a 256 -- "$input_file")
    digest_rc=$?
  else
    _file_error "sha256sum or shasum is required for content revalidation."
    return 1
  fi
  (( digest_rc == 0 )) || return 1
  local digest="${raw_output%%[[:space:]]*}"
  digest="${digest:l}"
  [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || return 1
  REPLY="$digest"
}

_file_confirm() {
  local prompt="${1:-Proceed?}"
  local auto_yes="${2:-no}"

  [[ "$auto_yes" == "yes" ]] && return 0
  [[ -t 0 && -t 2 ]] || return 2

  local response=""
  if _file_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi
  read -r response || return 2
  print -u2 -r -- ""
  [[ "$response" =~ ^[Yy]$ ]]
}

_file_confirm_mutation() {
  local prompt="$1"
  local auto_yes="${2:-no}"
  local -i confirm_rc=0

  _file_confirm "$prompt" "$auto_yes" || confirm_rc=$?
  case "$confirm_rc" in
    0) return 0 ;;
    1)
      _file_info "Cancelled."
      return 130
      ;;
    *)
      _file_error "Confirmation requires a terminal; pass --yes to proceed."
      return "$confirm_rc"
      ;;
  esac
}

_file_read_line() {
  local prompt="$1"
  local default_value="${2:-}"
  [[ -t 0 && -t 2 ]] || {
    _file_error "Interactive input requires a terminal."
    return 1
  }

  if [[ -n "$default_value" ]]; then
    printf '? %s [%s]: ' "${(V)prompt}" "${(V)default_value}" >&2
  else
    printf '? %s: ' "${(V)prompt}" >&2
  fi
  local response=""
  read -r response || return 1
  response="${response:-$default_value}"
  REPLY="$response"
}

# --- Canonical menu rows ----------------------------------------------------

_file_menu_section() {
  local title="$1"
  local description="${2:-}"

  if [[ "$title" == *'|'* || "$title" == *$'\n'* \
    || "$description" == *'|'* || "$description" == *$'\n'* ]]; then
    _file_error "Invalid menu section fields."
    return 2
  fi

  printf "── %s ──|:|%s\n" "$title" "$description"
}

_file_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"

  if [[ "$label" == *'|'* || "$label" == *$'\n'* \
    || "$command_name" == *'|'* || "$command_name" == *$'\n'* \
    || "$description" == *'|'* || "$description" == *$'\n'* ]]; then
    _file_error "Invalid menu entry fields."
    return 2
  fi

  printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
}

_file_array_contains_literal() {
  local needle="${1-}" candidate=""
  shift 2>/dev/null || return 2
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

# --- Foreground fzf capture -------------------------------------------------

_file_fzf() {
  local -a fzf_options=(
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
    SHELL=/bin/sh fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

_file_fzf_capture() {
  emulate -L zsh

  REPLY=""
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _file_error "Zsh file-descriptor support is required for File pickers."
    return 125
  }

  _file_validate_temp_parent "${TMPDIR:-/tmp}" "the File picker" || return 125
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-file-fzf.XXXXXX" 2>/dev/null) || {
    _file_error "Could not create a private File picker directory."
    return 125
  }
  command chmod 700 -- "$capture_dir" 2>/dev/null || {
    command rmdir -- "$capture_dir" 2>/dev/null
    _file_error "Could not protect the File picker directory."
    return 125
  }

  local -A capture_dir_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || ! -d "$capture_dir" || -L "$capture_dir" \
    || "${capture_dir:t}" != zdx-file-fzf.* ]] \
    || ! zstat -LH capture_dir_state -- "$capture_dir" 2>/dev/null \
    || (( (capture_dir_state[mode] & 8#170000) != 8#040000 \
      || capture_dir_state[uid] != EUID \
      || (capture_dir_state[mode] & 8#77) != 0 )); then
    command rmdir -- "$capture_dir" 2>/dev/null
    _file_error "Refusing an unsafe File picker directory."
    return 125
  fi
  local capture_dir_identity="${capture_dir_state[device]}:${capture_dir_state[inode]}:${capture_dir_state[mode]}:${capture_dir_state[uid]}"

  local capture_file=""
  local capture_file_identity=""
  local selection=""
  local -i capture_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A capture_file_state=() current_dir_state=() current_file_state=()

  {
    capture_file=$(umask 077; command mktemp \
      "$capture_dir/.result.XXXXXX" 2>/dev/null)
    if [[ -z "$capture_file" ]]; then
      _file_error "Could not create a private File picker result."
    elif ! command chmod 600 -- "$capture_file" 2>/dev/null; then
      _file_error "Could not protect the File picker result."
    elif [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$capture_dir" \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH capture_file_state -- "$capture_file" 2>/dev/null \
      || (( (capture_file_state[mode] & 8#170000) != 8#100000 \
        || capture_file_state[uid] != EUID \
        || capture_file_state[nlink] != 1 \
        || (capture_file_state[mode] & 8#77) != 0 )); then
      _file_error "Refusing an unsafe File picker result."
    else
      capture_file_identity="${capture_file_state[device]}:${capture_file_state[inode]}:${capture_file_state[mode]}:${capture_file_state[uid]}:${capture_file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u capture_fd \
        -- "$capture_file" 2>/dev/null; then
        _file_error "Could not open the File picker result safely."
      else
        _file_fzf "$@" 1>&$(( capture_fd ))
        fzf_rc=$?
        exec {capture_fd}>&-
        capture_fd=-1

        if ! zstat -LH current_dir_state -- "$capture_dir" 2>/dev/null \
          || [[ "${current_dir_state[device]}:${current_dir_state[inode]}:${current_dir_state[mode]}:${current_dir_state[uid]}" \
            != "$capture_dir_identity" ]] \
          || ! zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$capture_file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > _FILE_MAX_PICKER_BYTES )); then
          _file_error "The File picker result changed or is oversized."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _file_error "Could not read the File picker result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          operation_rc=$fzf_rc
        fi
      fi
    fi
  } always {
    (( capture_fd >= 0 )) && exec {capture_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    if [[ -n "$capture_file" && ( -e "$capture_file" || -L "$capture_file" ) ]]; then
      current_file_state=()
      if [[ -n "$capture_file_identity" \
        && -f "$capture_file" && ! -L "$capture_file" \
        && "${capture_file:a}" == "$capture_file" \
        && "${capture_file:A}" == "$capture_file" \
        && "${capture_file:h}" == "$capture_dir" ]] \
        && zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
        && [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
          == "$capture_file_identity" ]]; then
        command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
      else
        _file_warn "The File picker result changed; refusing cleanup."
        cleanup_failed=1
      fi
    fi

    current_dir_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" \
      && "${capture_dir:a}" == "$capture_dir" \
      && "${capture_dir:A}" == "$capture_dir" \
      && "${capture_dir:t}" == zdx-file-fzf.* ]] \
      && zstat -LH current_dir_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_dir_state[device]}:${current_dir_state[inode]}:${current_dir_state[mode]}:${current_dir_state[uid]}" \
        == "$capture_dir_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      _file_warn "The File picker directory changed; refusing cleanup."
      cleanup_failed=1
    fi

    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_file_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

_file_choose_fixed() {
  local prompt="$1"
  shift
  local -a choices=("$@")
  local selected=""
  local -i fzf_rc=0

  _file_fzf_capture \
    --height='50%' \
    --prompt="${prompt} > " \
    < <(print -rl -- "${choices[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _file_fzf_rc_is_cancel "$fzf_rc" && return 130
    _file_error "The File picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 130
  _file_array_contains_literal "$selected" "${choices[@]}" || {
    _file_error "The selection was not in the current snapshot."
    return 1
  }
  REPLY="$selected"
}

# --- Path inventory and selection ------------------------------------------

_file_path_is_displayable() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *[[:cntrl:]]* ]]
}

_file_collect_paths() {
  emulate -L zsh
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _file_error "Zsh file-descriptor support is required for path scans."
    return 1
  }
  _file_require_cmd head "bounded path scanning" || return 1
  local mode="$1"
  local scan_root="${2:-.}"
  reply=()

  local -a find_command=(command find "$scan_root")
  local node_filter="all"
  case "$mode" in
    immediate)
      find_command+=(-mindepth 1 -maxdepth 1)
      ;;
    directories)
      find_command+=(-mindepth 1 -maxdepth 1)
      node_filter="directory"
      ;;
    recursive-directories)
      find_command+=(-mindepth 1 -maxdepth 5)
      node_filter="directory"
      ;;
    files)
      find_command+=(-mindepth 1 -maxdepth 5)
      node_filter="file"
      ;;
    recursive)
      find_command+=(-mindepth 1 -maxdepth 5)
      ;;
    *)
      _file_error "Unknown inventory mode: $mode"
      return 2
      ;;
  esac
  find_command+=(
    \(
      -name .git
      -o -name node_modules
      -o -name .venv
      -o -name .tmp
    \)
    -prune
    -o
  )
  [[ "$node_filter" == "directory" ]] && find_command+=(-type d)
  [[ "$node_filter" == "file" ]] && find_command+=(-type f)
  find_command+=(-print0)

  _file_validate_temp_parent "${TMPDIR:-/tmp}" "path scanning" || return 1
  local temp_root="$REPLY"
  local inventory_file=""
  inventory_file=$(umask 077; command mktemp \
    "$temp_root/zdx-file-scan.XXXXXX" 2>/dev/null) || {
    _file_error "Could not create a private path inventory."
    return 1
  }
  command chmod 600 -- "$inventory_file" 2>/dev/null || {
    command rm -f -- "$inventory_file" 2>/dev/null
    return 1
  }
  local -A initial_state=() current_state=()
  if [[ ! -f "$inventory_file" || -L "$inventory_file" \
    || "$inventory_file" != "${inventory_file:a}" \
    || "$inventory_file" != "${inventory_file:A}" ]] \
    || ! zstat -LH initial_state -- "$inventory_file" 2>/dev/null \
    || (( initial_state[uid] != EUID \
      || initial_state[nlink] != 1 \
      || (initial_state[mode] & 8#77) != 0 )); then
    command rm -f -- "$inventory_file" 2>/dev/null
    _file_error "Refusing an unsafe path inventory."
    return 1
  fi
  local inventory_identity="${initial_state[device]}:${initial_state[inode]}:${initial_state[mode]}:${initial_state[uid]}:${initial_state[nlink]}"

  local candidate=""
  local -a scanned_paths=()
  local -i count=0 scan_rc=1 cleanup_rc=0
  local -i write_fd=-1 read_fd=-1
  {
    if ! sysopen -w -o nofollow,cloexec -u write_fd \
      -- "$inventory_file" 2>/dev/null; then
      _file_error "Could not open the path inventory safely."
      return 1
    fi
    setopt local_options pipefail
    "${find_command[@]}" 2>/dev/null \
      | command head -c "$(( _FILE_MAX_PICKER_BYTES + 1 ))" \
        1>&$(( write_fd ))
    scan_rc=$?
    exec {write_fd}>&-
    write_fd=-1

    current_state=()
    zstat -LH current_state -- "$inventory_file" 2>/dev/null || return 1
    [[ "${current_state[device]}:${current_state[inode]}:${current_state[mode]}:${current_state[uid]}:${current_state[nlink]}" \
      == "$inventory_identity" ]] || {
      _file_error "The path inventory changed unexpectedly."
      return 1
    }
    (( current_state[size] <= _FILE_MAX_PICKER_BYTES )) || {
      _file_error \
        "Candidate inventory exceeds the $_FILE_MAX_PICKER_BYTES byte limit."
      return 1
    }
    (( scan_rc == 0 )) || {
      _file_error "Could not scan candidate paths."
      return 1
    }
    if ! sysopen -r -o nofollow,cloexec -u read_fd \
      -- "$inventory_file" 2>/dev/null; then
      return 1
    fi
    while IFS= read -r -d '' candidate <&$(( read_fd )); do
      [[ "$candidate" == */.git || "$candidate" == */.git/* \
        || "$candidate" == */node_modules || "$candidate" == */node_modules/* \
        || "$candidate" == */.venv || "$candidate" == */.venv/* \
        || "$candidate" == */.tmp || "$candidate" == */.tmp/* ]] && continue
      candidate="${candidate#./}"
      _file_path_is_displayable "$candidate" || {
        _file_warn "Excluded a path that cannot be represented safely in fzf."
        continue
      }
      scanned_paths+=("$candidate")
      (( ++count <= _FILE_MAX_CANDIDATES )) || {
        _file_error \
          "Candidate inventory exceeds the $_FILE_MAX_CANDIDATES entry limit."
        return 1
      }
    done
    exec {read_fd}>&-
    read_fd=-1
    reply=("${scanned_paths[@]}")
    scan_rc=0
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-
    current_state=()
    if [[ -f "$inventory_file" && ! -L "$inventory_file" ]] \
      && zstat -LH current_state -- "$inventory_file" 2>/dev/null \
      && [[ "${current_state[device]}:${current_state[inode]}:${current_state[mode]}:${current_state[uid]}:${current_state[nlink]}" \
        == "$inventory_identity" ]]; then
      command rm -f -- "$inventory_file" 2>/dev/null || cleanup_rc=1
    else
      _file_warn "The path inventory changed; refusing cleanup."
      cleanup_rc=1
    fi
    (( cleanup_rc == 0 )) || scan_rc=1
  }
  return $scan_rc
}

_file_select_from_snapshot() {
  local prompt="$1"
  local multi_select="$2"
  local paths_name="$3"
  local -a paths=("${(@P)paths_name}")
  reply=()
  (( ${#paths[@]} > 0 )) || return 130

  local -a rows=()
  local -i index=1
  local item=""
  for item in "${paths[@]}"; do
    rows+=("${index}|${(V)item}")
    (( ++index ))
  done

  local -a fzf_options=(
    --height='75%'
    --delimiter='[|]'
    --with-nth=2
    --prompt="${prompt} > "
  )
  [[ "$multi_select" == "yes" ]] && fzf_options+=(
    --multi
    --header='Tab select multiple | Enter confirm | Esc cancel'
  )

  local selected=""
  local -i fzf_rc=0
  _file_fzf_capture "${fzf_options[@]}" \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _file_fzf_rc_is_cancel "$fzf_rc" && return 130
    _file_error "The File picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 130

  local -a selected_rows=("${(@f)selected}")
  local selected_row=""
  local selected_index=""
  for selected_row in "${selected_rows[@]}"; do
    _file_array_contains_literal "$selected_row" "${rows[@]}" || {
      _file_error "A selected path was not in the current snapshot."
      return 1
    }
    selected_index="${selected_row%%|*}"
    [[ "$selected_index" == <-> \
      && selected_index -ge 1 \
      && selected_index -le ${#paths[@]} ]] || {
      _file_error "A selected path index is invalid."
      return 1
    }
    reply+=("${paths[selected_index]}")
  done
}

_file_select_paths() {
  local prompt="$1"
  local multi_select="${2:-yes}"
  local kind="${3:-all}"
  reply=()

  _file_require_cmd fzf "interactive path selection" || return 1
  local inventory_mode="immediate"
  case "$kind" in
    files) inventory_mode="files" ;;
    directories) inventory_mode="directories" ;;
    all) inventory_mode="immediate" ;;
    *)
      _file_error "Unknown path selection kind: $kind"
      return 2
      ;;
  esac

  _file_collect_paths "$inventory_mode" "." || return $?
  local -a candidates=("${reply[@]}")
  if (( ${#candidates[@]} == 0 )); then
    _file_warn "No matching files or directories were found."
    return 130
  fi
  _file_select_from_snapshot "$prompt" "$multi_select" candidates
}

# Compatibility data helper used by older callers. New suite code consumes the
# `reply` array directly so formatted rows never become mutation targets.
_file_select_candidates() {
  local prompt="$1"
  local multi="${2:-true}"
  local multi_select="yes"
  [[ "$multi" == "false" ]] && multi_select="no"
  _file_select_paths "$prompt" "$multi_select" all || return $?
  print -rl -- "${reply[@]}"
}

# --- Mutation boundaries ---------------------------------------------------

_file_validate_base() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local candidate="${1:-$PWD}"
  REPLY=""
  local lexical="${candidate:a}"
  local resolved="${candidate:A}"
  [[ -d "$lexical" && ! -L "$lexical" && "$lexical" == "$resolved" ]] || {
    _file_error "The operation base must be a real, symlink-free directory."
    return 1
  }
  [[ "$lexical" != "/" ]] || {
    _file_error "The filesystem root cannot be an operation base."
    return 1
  }
  local -A base_state=()
  zstat -LH base_state -- "$lexical" 2>/dev/null || return 1
  (( base_state[uid] == EUID && (base_state[mode] & 8#22) == 0 )) || {
    _file_error \
      "The operation base must be owned and not group/world-writable."
    return 1
  }
  _file_validate_ancestor_chain "$lexical" || return 1
  REPLY="$lexical"
}

_file_path_fingerprint() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local target="$1"
  local -A state=()
  zstat -LH state -- "$target" 2>/dev/null || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}:${state[nlink]}:${state[size]}:${state[mtime]}:${state[ctime]}"
}

_file_fingerprint_node_identity() {
  local fingerprint="$1"
  local -a fields=("${(@s/:/)fingerprint}")
  (( ${#fields[@]} == 8 )) || return 1
  REPLY="${(j/:/)fields[1,5]}"
}

_file_directory_identity() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local directory="$1"
  local -A state=()
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  zstat -LH state -- "$directory" 2>/dev/null || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}"
}

_file_node_identity() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local node="$1"
  local -A state=()
  [[ ( -e "$node" || -L "$node" ) && ! -L "$node" ]] || return 1
  zstat -LH state -- "$node" 2>/dev/null || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}:${state[nlink]}"
}

_file_mountpoint_clear() {
  local node="$1"
  _file_require_cmd findmnt "recursive mount-boundary validation" || return 1
  local mount_output=""
  local -i findmnt_rc=0
  mount_output=$(command findmnt -rn --mountpoint "$node" \
    -o TARGET 2>/dev/null) || findmnt_rc=$?
  case "$findmnt_rc" in
    0)
      _file_error "Refusing a recursive operation across a mount: $node"
      return 1
      ;;
    1)
      [[ -z "$mount_output" ]] || return 1
      return 0
      ;;
    *)
      _file_error "Could not verify a recursive mount boundary."
      return 1
      ;;
  esac
}

_file_delete_mounts_clear() {
  local target="$1"
  if [[ -d "$target" ]]; then
    _file_validate_tree_for_transfer "$target"
  else
    _file_mountpoint_clear "$target"
  fi
}

_file_validate_mutation_target() {
  local target="$1"
  local base="$2"
  local allow_writable="${3:-no}"
  REPLY=""
  [[ "$allow_writable" == "yes" || "$allow_writable" == "no" ]] || return 2
  [[ -n "$target" && "$target" != *[[:cntrl:]]* \
    && "$target" != *'|'* ]] || {
    _file_error "Refusing an empty or unrepresentable path."
    return 1
  }
  local lexical="${target:a}"
  [[ "$lexical" == "$base"/* ]] || {
    _file_error "Refusing a target outside the operation base: $target"
    return 1
  }
  [[ "$lexical" != "$base" \
    && "$lexical" != "/" \
    && "$lexical" != "${HOME:A}" \
    && "$lexical" != "$_FILE_SUITE_ROOT" ]] || {
    _file_error "Refusing a protected target: $target"
    return 1
  }
  [[ ( -f "$lexical" || -d "$lexical" ) \
    && ! -L "$lexical" \
    && "$lexical" == "${lexical:A}" ]] || {
    _file_error "Mutation targets must exist and contain no symbolic links: $target"
    return 1
  }
  _file_validate_ancestor_chain "$lexical" || return 1
  local -A target_state=()
  zmodload zsh/stat 2>/dev/null \
    && zstat -LH target_state -- "$lexical" 2>/dev/null || {
    _file_error "Could not inspect mutation target: $target"
    return 1
  }
  if ! (( target_state[uid] == EUID && target_state[nlink] >= 1 )) \
    || { [[ "$allow_writable" != "yes" ]] \
      && (( (target_state[mode] & 8#22) != 0 )); }; then
    _file_error "Mutation target ownership or permissions are unsafe: $target"
    return 1
  fi
  if [[ -f "$lexical" ]] && (( target_state[nlink] != 1 )); then
    _file_error "Mutation targets may not be hard-linked files: $target"
    return 1
  fi
  _file_path_fingerprint "$lexical" || {
    _file_error "Could not fingerprint mutation target: $target"
    return 1
  }
  local identity="$REPLY"
  REPLY="${lexical}|${identity}"
}

_file_revalidate_mutation_target() {
  local target="$1"
  local expected_identity="$2"
  [[ -e "$target" && ! -L "$target" && "$target" == "${target:A}" ]] || {
    _file_error "A planned target changed before execution: $target"
    return 1
  }
  _file_path_fingerprint "$target" || return 1
  [[ "$REPLY" == "$expected_identity" ]] || {
    _file_error "A planned target changed identity before execution: $target"
    return 1
  }
}

_file_validate_destination_parent() {
  local destination="$1"
  local base_dir="${2:-${PWD:A}}"
  REPLY=""
  reply=()
  [[ -n "$destination" && "$destination" != *[[:cntrl:]]* \
    && "$destination" != *'|'* ]] || return 1
  local absolute="${destination:a}"
  local parent="${absolute:h}"
  [[ "$base_dir" == "${base_dir:A}" \
    && "$absolute" == "$base_dir"/* \
    && "$absolute" != "$base_dir" ]] || {
    _file_error "The destination must be a child of the current operation base."
    return 1
  }
  [[ -d "$parent" && ! -L "$parent" && "$parent" == "${parent:A}" ]] || {
    _file_error "The destination parent must be a real, symlink-free directory."
    return 1
  }
  [[ ! -L "$absolute" ]] || {
    _file_error "Refusing a symbolic-link destination: $destination"
    return 1
  }
  _file_directory_identity "$parent" || return 1
  local parent_identity="$REPLY"
  local -A parent_state=()
  zmodload zsh/stat 2>/dev/null \
    && zstat -LH parent_state -- "$parent" 2>/dev/null || return 1
  (( parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )) || {
    _file_error \
      "The destination parent must be owned and not group/world-writable."
    return 1
  }
  _file_validate_ancestor_chain "$parent" || return 1
  reply=("$absolute" "$parent_identity")
  REPLY="$absolute"
}

_file_revalidate_parent() {
  local destination="$1"
  local expected_identity="$2"
  local parent="${destination:h}"
  [[ -d "$parent" && ! -L "$parent" && "$parent" == "${parent:A}" ]] \
    || return 1
  _file_directory_identity "$parent" || return 1
  [[ "$REPLY" == "$expected_identity" ]] || {
    _file_error "The destination parent changed after planning."
    return 1
  }
}

_file_validate_private_temp() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local candidate="$1" parent="$2" prefix="$3" kind="$4"
  [[ -n "$candidate" && "$candidate" == "${candidate:a}" \
    && "$candidate" == "${candidate:A}" \
    && "${candidate:h}" == "$parent" \
    && "${candidate:t}" == "$prefix"?????? \
    && ! -L "$candidate" ]] || return 1
  local -A state=()
  zstat -LH state -- "$candidate" 2>/dev/null || return 1
  (( state[uid] == EUID && (state[mode] & 8#77) == 0 )) || return 1
  case "$kind" in
    file)
      [[ -f "$candidate" ]] \
        && (( (state[mode] & 8#170000) == 8#100000 \
          && state[nlink] == 1 && state[size] == 0 ))
      ;;
    directory)
      [[ -d "$candidate" ]] \
        && (( (state[mode] & 8#170000) == 8#040000 ))
      ;;
    *) return 2 ;;
  esac
}

_file_make_sibling_temp() {
  local destination="$1"
  REPLY=""
  local parent="${destination:h}"
  _file_validate_temp_parent "$parent" "same-directory staging" || return 1
  parent="$REPLY"
  local name="${destination:t}"
  local temp_file=""
  temp_file=$(umask 077; command mktemp \
    "${parent}/.${name}.zdx.XXXXXX" 2>/dev/null) || {
    _file_error "Could not create a private staging file."
    return 1
  }
  _file_validate_private_temp \
    "$temp_file" "$parent" ".${name}.zdx." file || {
    _file_error "Refusing an unsafe staging file."
    return 1
  }
  REPLY="$temp_file"
}

_file_output_snapshot() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local destination="$1"
  REPLY="absent"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" \
      && "$destination" == "${destination:A}" ]] || {
      _file_error "An existing output must be a real regular file."
      return 1
    }
    _file_path_fingerprint "$destination" || return 1
    local output_identity="$REPLY"
    local -A output_state=()
    zstat -LH output_state -- "$destination" 2>/dev/null || return 1
    (( output_state[uid] == EUID && output_state[nlink] == 1 \
      && (output_state[mode] & 8#22) == 0 )) || {
      _file_error \
        "An existing output must be owned, protected, and singly linked."
      return 1
    }
    _file_sha256_digest "$destination" || return 1
    local output_digest="$REPLY"
    _file_path_fingerprint "$destination" || return 1
    [[ "$REPLY" == "$output_identity" ]] || {
      _file_error "The existing output changed while it was inspected."
      return 1
    }
    REPLY="file|${output_identity}|${output_digest}"
  fi
}

_file_revalidate_output_snapshot() {
  local destination="$1"
  local expected_state="$2"
  if [[ "$expected_state" == "absent" ]]; then
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
      _file_error "The output appeared after planning: $destination"
      return 1
    }
    return 0
  fi

  [[ "$expected_state" == file\|*\|* \
    && -f "$destination" && ! -L "$destination" \
    && "$destination" == "${destination:A}" ]] || {
    _file_error "The output changed type after planning: $destination"
    return 1
  }
  local snapshot_body="${expected_state#file|}"
  local expected_identity="${snapshot_body%|*}"
  local expected_digest="${snapshot_body##*|}"
  _file_path_fingerprint "$destination" || return 1
  [[ "$REPLY" == "$expected_identity" ]] || {
    _file_error "The output changed identity after planning: $destination"
    return 1
  }
  _file_sha256_digest "$destination" || return 1
  [[ "$REPLY" == "$expected_digest" ]] || {
    _file_error "The output content changed after planning: $destination"
    return 1
  }
  _file_path_fingerprint "$destination" || return 1
  [[ "$REPLY" == "$expected_identity" ]] || {
    _file_error "The output changed while it was revalidated: $destination"
    return 1
  }
}

_file_publish_staged_file() {
  local staged_file="$1"
  local destination="$2"
  local expected_state="$3"
  local parent_identity="${4:-}"
  local -i publish_rc=0
  [[ -f "$staged_file" && ! -L "$staged_file" ]] || return 1
  _file_path_fingerprint "$staged_file" || return 1
  _file_fingerprint_node_identity "$REPLY" || return 1
  local staged_node_identity="$REPLY"
  _file_sha256_digest "$staged_file" || return 1
  local staged_digest="$REPLY"
  [[ -z "$parent_identity" ]] \
    || _file_revalidate_parent "$destination" "$parent_identity" || return 1
  _file_revalidate_output_snapshot "$destination" "$expected_state" || return 1

  if [[ "$expected_state" == "absent" ]]; then
    command ln -- "$staged_file" "$destination" 2>/dev/null || {
      publish_rc=$?
      _file_error "Could not publish the output without clobbering."
      return $publish_rc
    }
    command rm -f -- "$staged_file" 2>/dev/null || {
      publish_rc=$?
      _file_warn "Published output, but could not remove its staging link."
      return $publish_rc
    }
  else
    command mv -f -- "$staged_file" "$destination" 2>/dev/null || {
      publish_rc=$?
      _file_error "Could not publish the staged output."
      return $publish_rc
    }
  fi

  [[ ! -e "$staged_file" && ! -L "$staged_file" \
    && -f "$destination" && ! -L "$destination" ]] || {
    _file_error "The staged output did not publish atomically."
    return 1
  }
  _file_sha256_digest "$destination" || return 1
  [[ "$REPLY" == "$staged_digest" ]] || {
    _file_error "The published output does not match staging."
    return 1
  }
  _file_node_identity "$destination" || return 1
  [[ "$REPLY" == "$staged_node_identity" ]] || {
    _file_error "The published output identity does not match staging."
    return 1
  }
  local -A published_state=()
  zmodload zsh/stat 2>/dev/null \
    && zstat -LH published_state -- "$destination" 2>/dev/null || return 1
  (( published_state[uid] == EUID && published_state[nlink] == 1 )) || {
    _file_error "The published output has an unsafe link or owner state."
    return 1
  }
  [[ -z "$parent_identity" ]] \
    || _file_revalidate_parent "$destination" "$parent_identity" || return 1
}

# --- Dispatcher -------------------------------------------------------------

_file_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    file-compress)      file-compress "$@" ;;
    file-extract)       file-extract "$@" ;;
    file-bulk-ops)      file-bulk-ops "$@" ;;
    file-permissions)   file-permissions "$@" ;;
    file-find-large)    file-find-large "$@" ;;
    file-find)          file-find "$@" ;;
    file-diff)          file-diff "$@" ;;
    file-encode-decode) file-encode-decode "$@" ;;
    file-checksum)      file-checksum "$@" ;;
    file-line-endings)  file-line-endings "$@" ;;
    :)                  return 0 ;;
    *)
      _file_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

typeset -g _FILE_COMMON_SOURCED=1
