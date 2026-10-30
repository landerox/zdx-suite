#!/usr/bin/env zsh
# =============================================================================
# ZDX Common: master-menu UI, capture, and fixed dispatch helpers
# =============================================================================
#
# Loaded by zdx-menu.zsh before defining the public ZDX wrapper.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_ZDX_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Private Logging & UI Helpers ---------------------------------------------

_zdx_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_zdx_header() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)message}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)message}" >&2
  fi
}

_zdx_info() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[1;34mℹ [info]\033[0m %s\n' "${(V)message}" >&2
  else
    printf 'ℹ [info] %s\n' "${(V)message}" >&2
  fi
}

_zdx_success() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[1;32m✔ [success]\033[0m %s\n' "${(V)message}" >&2
  else
    printf '✔ [success] %s\n' "${(V)message}" >&2
  fi
}

_zdx_warn() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[1;33m⚠ [warning]\033[0m %s\n' "${(V)message}" >&2
  else
    printf '⚠ [warning] %s\n' "${(V)message}" >&2
  fi
}

_zdx_error() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[1;31m✘ [error]\033[0m %s\n' "${(V)message}" >&2
  else
    printf '✘ [error] %s\n' "${(V)message}" >&2
  fi
}

_zdx_dim() {
  local message="${1:-}"
  if _zdx_color_enabled; then
    printf '\033[0;90m%s\033[0m\n' "${(V)message}" >&2
  else
    printf '%s\n' "${(V)message}" >&2
  fi
}

_zdx_menu_field_safe() {
  local value="${1:-}"
  local -i maximum_length="${2:-2048}"

  (( maximum_length >= 1 && maximum_length <= 65536 \
    && ${#value} <= maximum_length )) \
    && [[ "$value" != *'|'* \
      && "$value" != *$'\n'* \
      && "$value" != *$'\0'* ]]
}

_zdx_plugin_name_valid() {
  local plugin_name="${1:-}"
  (( ${#plugin_name} >= 1 && ${#plugin_name} <= 128 )) \
    && [[ "$plugin_name" =~ '^[a-z0-9_-]+$' ]]
}

_zdx_wrapper_name_reserved() {
  case "${1:-}" in
    dev|env|file|git|plugins|py|sys|vpn|ws|doctor|status|help|version)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# True when NAME is a plugin the core loaded or, in a lazy shell, discovered
# and registered a menu stub for.
_zdx_plugin_loaded() {
  local plugin_name="${1:-}"
  _zdx_plugin_name_valid "$plugin_name" || return 1

  local loaded_name=""
  for loaded_name in "${ZDX_LOADED_PLUGINS[@]}" "${ZDX_DISCOVERED_PLUGINS[@]}"; do
    [[ "$loaded_name" == "$plugin_name" ]] && return 0
  done
  return 1
}

_zdx_menu_section() {
  local title="${1:-}"
  local description="${2:-}"

  if ! _zdx_menu_field_safe "$title" 256 \
    || ! _zdx_menu_field_safe "$description" 2048; then
    _zdx_error "Invalid menu section fields."
    return 2
  fi

  printf '── %s ──|:|%s\n' "$title" "$description"
}

_zdx_menu_entry() {
  local label="${1:-}"
  local command_name="${2:-}"
  local description="${3:-}"

  if ! _zdx_menu_field_safe "$label" 256 \
    || ! _zdx_menu_field_safe "$command_name" 128 \
    || ! _zdx_menu_field_safe "$description" 2048 \
    || [[ ! "$command_name" =~ '^[a-z0-9_-]+$' ]]; then
    _zdx_error "Invalid menu entry fields."
    return 2
  fi

  printf '  %s|%s|%s\n' "$label" "$command_name" "$description"
}

_zdx_fzf() {
  local -a fzf_options=(
    --height=80%
    --layout=reverse
    --border=rounded
    --delimiter='[|]'
    --with-nth=1
    --pointer='▶'
  )

  fzf_options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow')

  if typeset -f _zdx_fzf_color_opts &>/dev/null; then
    local theme_option=""
    theme_option=$(_zdx_fzf_color_opts)
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

  # fzf with templates hides the delimiter that trails a single shown field.
  local REPLY=""
  if typeset -f _zdx_fzf_nth_template_option &>/dev/null \
    && _zdx_fzf_nth_template_option "${fzf_options[@]}" "$@"; then
    terminal_options+=("$REPLY")
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh command fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

_zdx_root_uid() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1

  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

# Standalone fallback for the core trusted-directory resolver; functions.zsh
# defines the same function first in a normal shell (see its docblock). A
# test compares both definitions so the copies cannot drift.
if (( ! ${+functions[_zdx_resolve_trusted_dir]} )); then
  _zdx_resolve_trusted_dir() {
    emulate -L zsh
    zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
    local requested="${1-}"
    REPLY=""
    while [[ "$requested" != / && "$requested" == */ ]]; do
      requested="${requested%/}"
    done
    [[ -n "$requested" && "$requested" == /* \
      && "$requested" == "${requested:a}" ]] || return 1

    local -A root_state=() link_state=() parent_state=()
    zstat -LH root_state -- / 2>/dev/null || return 1
    local -a components=("${(@s:/:)requested}")
    local prefix="" component=""
    local -i index=0 last=${#components}
    for component in "${components[@]}"; do
      (( ++index ))
      [[ -n "$component" ]] || continue
      prefix+="/$component"
      [[ -L "$prefix" ]] || continue
      link_state=()
      zstat -LH link_state -- "$prefix" 2>/dev/null || return 1
      (( link_state[uid] == root_state[uid] )) && continue
      (( index < last && link_state[uid] == EUID )) || return 1
      parent_state=()
      zstat -H parent_state -- "${prefix:h}" 2>/dev/null || return 1
      (( parent_state[uid] == root_state[uid] || parent_state[uid] == EUID )) \
        && (( (parent_state[mode] & 8#22) == 0 )) || return 1
    done
    local resolved="${requested:A}"
    [[ "$resolved" == /* && -d "$resolved" && ! -L "$resolved" ]] || return 1
    REPLY="$resolved"
  }
fi

# Standalone copy of the core canonical ancestor policy. Normal loading
# keeps the core definition; platform_paths.bats compares both bodies.
if (( ! ${+functions[_zdx_ancestors_trusted]} )); then
_zdx_ancestors_trusted() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local child_path="${1-}" parent_path=""
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1
  local -A root_state=() parent_state=()
  zstat -LH root_state -- / 2>/dev/null || return 1
  while [[ "$child_path" != / ]]; do
    parent_path="${child_path:h}"
    parent_state=()
    [[ -d "$parent_path" && ! -L "$parent_path" ]] \
      && zstat -LH parent_state -- "$parent_path" 2>/dev/null || return 1
    if (( (parent_state[uid] != root_state[uid] \
        && parent_state[uid] != EUID) \
      || ((parent_state[mode] & 8#22) != 0 \
        && ! (parent_state[uid] == root_state[uid] \
          && (parent_state[mode] & 8#1000) != 0 \
          && (parent_state[mode] & 8#2) != 0)) )); then
      return 1
    fi
    child_path="$parent_path"
  done
}
fi

# REPLY is the canonical temporary root. TMPDIR may be reached through a
# trusted alias, such as macOS /var/folders or /tmp; the ownership and sticky
# checks apply to the canonical directory.
_zdx_temp_parent_safe() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local temp_parent="${1:-}"
  REPLY=""

  _zdx_resolve_trusted_dir "$temp_parent" || return 1
  temp_parent="$REPLY"
  REPLY=""
  [[ -n "$temp_parent" && "$temp_parent" == /* \
    && "$temp_parent" == "${temp_parent:a}" \
    && "$temp_parent" == "${temp_parent:A}" \
    && -d "$temp_parent" && ! -L "$temp_parent" ]] || return 1

  _zdx_root_uid || return 1
  local -i root_uid=$REPLY
  REPLY=""
  local -A parent_state=()
  zstat -LH parent_state -- "$temp_parent" 2>/dev/null || return 1
  if (( parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )); then
    :
  elif (( parent_state[uid] == root_uid \
    && (parent_state[mode] & 8#1000) != 0 \
    && (parent_state[mode] & 8#2) != 0 )); then
    :
  else
    return 1
  fi
  _zdx_ancestors_trusted "$temp_parent" || return 1
  REPLY="$temp_parent"
}

# Runs one ZDX picker in the terminal foreground and captures its
# selection privately: REPLY is the selection and the status is the picker's
# own, or 125 when the capture failed or was refused. The core
# _zdx_picker_capture owns the implementation; _zdx_menu_picker_capture below is its
# generated copy for a shell without the core.
_zdx_fzf_capture() {
  local -a zpc_options=(
    --max-bytes 65536 --tag zdx --noun ZDX --error _zdx_error
    --picker _zdx_fzf --temp-root _zdx_temp_parent_safe
  )
  if (( ${+functions[_zdx_picker_capture]} )); then
    _zdx_picker_capture "${zpc_options[@]}" -- "$@"
  else
    _zdx_menu_picker_capture "${zpc_options[@]}" -- "$@"
  fi
}

# >>> zdx-primitive picker-capture
# Runs one picker synchronously in the terminal foreground and captures only
# its selection stdout. The result file lives in a private mode-700
# directory below the validated temporary root, is opened without following
# links, and must keep its identity (device, inode, mode, owner, and one
# link) and stay within the byte limit. REPLY is the selection and the
# status is the picker's own. Status 125 means the capture failed or was
# refused: a private directory or file could not be created or verified, the
# result changed or grew past the limit, it could not be read, cleanup could
# not prove it removed only its own files, or a failed picker returned data.
# The one exception is the --expect key line that fzf prints when nothing
# matches (status 1): it carries no selection, so REPLY stays empty and the
# status stays 1. --write-limit also caps the file while the picker writes:
# the picker then runs in a synchronous foreground subshell whose soft and
# hard file-size limits are lowered to the byte limit, and a picker stopped
# by SIGXFSZ keeps that exact status with an empty REPLY. Generated copies in
# the suite common files keep a suite working without the core;
# `just sync-primitives` writes them.
# Usage: _zdx_menu_picker_capture [--max-bytes N] [--write-limit] --tag TAG \
#          --noun TEXT --error FUNCTION --picker FUNCTION \
#          --temp-root FUNCTION -- [picker-argument...]
_zdx_menu_picker_capture() {
  emulate -L zsh
  REPLY=""
  local zpc_tag="" zpc_noun="" zpc_error_function="" zpc_picker_function=""
  local zpc_temp_root_function=""
  local -i zpc_max_bytes=65536 zpc_write_limit=0
  while (( $# > 0 )); do
    case "$1" in
      --write-limit) zpc_write_limit=1; shift ;;
      --max-bytes)
        [[ "${2-}" == <1-16777216> ]] || return 2
        zpc_max_bytes="$2"
        shift 2
        ;;
      --tag) zpc_tag="${2-}"; shift 2 ;;
      --noun) zpc_noun="${2-}"; shift 2 ;;
      --error) zpc_error_function="${2-}"; shift 2 ;;
      --picker) zpc_picker_function="${2-}"; shift 2 ;;
      --temp-root) zpc_temp_root_function="${2-}"; shift 2 ;;
      --) shift; break ;;
      *) return 2 ;;
    esac
  done
  [[ "$zpc_tag" =~ '^[a-z0-9]+(-[a-z0-9]+)*$' \
    && -n "$zpc_noun" && "$zpc_noun" != *[[:cntrl:]]* \
    && "$zpc_error_function" =~ '^_[a-z0-9_]+$' \
    && "$zpc_picker_function" =~ '^_[a-z0-9_]+$' \
    && "$zpc_temp_root_function" =~ '^_[a-z0-9_]+$' ]] \
    && (( ${+functions[$zpc_error_function]} && ${+functions[$zpc_picker_function]} \
      && ${+functions[$zpc_temp_root_function]} )) || return 2

  local -i zpc_expect_key=0
  local zpc_picker_argument=""
  for zpc_picker_argument in "$@"; do
    [[ "$zpc_picker_argument" == (--expect|--expect=*) ]] && zpc_expect_key=1
  done

  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
    "$zpc_error_function" "Zsh file-descriptor support is required for $zpc_noun pickers."
    return 125
  }
  "$zpc_temp_root_function" "${TMPDIR:-/tmp}" 2>/dev/null || {
    "$zpc_error_function" "Refusing an unsafe temporary root for $zpc_noun pickers."
    return 125
  }
  local zpc_temp_root="${REPLY%/}"
  REPLY=""
  [[ -n "$zpc_temp_root" && "$zpc_temp_root" == /* ]] || {
    "$zpc_error_function" "Refusing an unsafe temporary root for $zpc_noun pickers."
    return 125
  }

  local zpc_capture_dir="" zpc_capture_file="" zpc_selection="" zpc_chunk=""
  local zpc_directory_identity="" zpc_file_identity=""
  local -i zpc_write_fd=-1 zpc_read_fd=-1 zpc_picker_rc=125 zpc_operation_rc=125
  local -i zpc_read_rc=0 zpc_read_bytes=0 zpc_chunk_bytes=0 zpc_cleanup_failed=0
  local -A zpc_directory_state=() zpc_file_state=()

  zpc_capture_dir=$(umask 077; command mktemp -d \
    "$zpc_temp_root/zdx-${zpc_tag}-fzf.XXXXXX" 2>/dev/null) || {
    "$zpc_error_function" "Could not create a private $zpc_noun picker directory."
    return 125
  }
  {
    if [[ "$zpc_capture_dir" != "${zpc_capture_dir:a}" \
      || "$zpc_capture_dir" != "${zpc_capture_dir:A}" \
      || "${zpc_capture_dir:h}" != "$zpc_temp_root" \
      || "${zpc_capture_dir:t}" != zdx-${zpc_tag}-fzf.?????? \
      || ! -d "$zpc_capture_dir" || -L "$zpc_capture_dir" ]] \
      || ! zstat -LH zpc_directory_state -- "$zpc_capture_dir" 2>/dev/null \
      || (( (zpc_directory_state[mode] & 8#170000) != 8#040000 \
        || zpc_directory_state[uid] != EUID \
        || (zpc_directory_state[mode] & 8#777) != 8#700 )); then
      "$zpc_error_function" "Refusing an unsafe $zpc_noun picker directory."
      return 125
    fi
    zpc_directory_identity="${zpc_directory_state[device]}:${zpc_directory_state[inode]}:"\
"${zpc_directory_state[mode]}:${zpc_directory_state[uid]}"

    zpc_capture_file=$(umask 077; command mktemp \
      "$zpc_capture_dir/result.XXXXXX" 2>/dev/null) || {
      "$zpc_error_function" "Could not create a private $zpc_noun picker result."
      return 125
    }
    if [[ "$zpc_capture_file" != "${zpc_capture_file:a}" \
      || "$zpc_capture_file" != "${zpc_capture_file:A}" \
      || "${zpc_capture_file:h}" != "$zpc_capture_dir" \
      || "${zpc_capture_file:t}" != result.?????? \
      || ! -f "$zpc_capture_file" || -L "$zpc_capture_file" ]] \
      || ! zstat -LH zpc_file_state -- "$zpc_capture_file" 2>/dev/null \
      || (( (zpc_file_state[mode] & 8#170000) != 8#100000 \
        || zpc_file_state[uid] != EUID || zpc_file_state[nlink] != 1 \
        || (zpc_file_state[mode] & 8#777) != 8#600 || zpc_file_state[size] != 0 )); then
      "$zpc_error_function" "Refusing an unsafe $zpc_noun picker result."
      return 125
    fi
    zpc_file_identity="${zpc_file_state[device]}:${zpc_file_state[inode]}:"\
"${zpc_file_state[mode]}:${zpc_file_state[uid]}:${zpc_file_state[nlink]}"

    if ! sysopen -w -o nofollow,cloexec -u zpc_write_fd \
      -- "$zpc_capture_file" 2>/dev/null; then
      "$zpc_error_function" "Could not open the $zpc_noun picker result safely."
      return 125
    fi
    if (( zpc_write_limit )); then
      (
        limit -s filesize "$(( (zpc_max_bytes + 1023) / 1024 ))k" || exit 125
        limit -hs filesize "$(( (zpc_max_bytes + 1023) / 1024 ))k" || exit 125
        "$zpc_picker_function" "$@"
      ) 1>&$(( zpc_write_fd ))
    else
      "$zpc_picker_function" "$@" 1>&$(( zpc_write_fd ))
    fi
    zpc_picker_rc=$?
    exec {zpc_write_fd}>&-
    zpc_write_fd=-1

    zpc_directory_state=()
    zpc_file_state=()
    if ! zstat -LH zpc_directory_state -- "$zpc_capture_dir" 2>/dev/null \
      || [[ "${zpc_directory_state[device]}:${zpc_directory_state[inode]}:"\
"${zpc_directory_state[mode]}:${zpc_directory_state[uid]}" != "$zpc_directory_identity" ]] \
      || ! zstat -LH zpc_file_state -- "$zpc_capture_file" 2>/dev/null \
      || [[ "${zpc_file_state[device]}:${zpc_file_state[inode]}:${zpc_file_state[mode]}:"\
"${zpc_file_state[uid]}:${zpc_file_state[nlink]}" != "$zpc_file_identity" ]] \
      || (( zpc_file_state[size] < 0 || zpc_file_state[size] > zpc_max_bytes )); then
      "$zpc_error_function" "The $zpc_noun picker result changed or exceeded its limit."
      return 125
    fi
    if ! sysopen -r -o nofollow,cloexec -u zpc_read_fd \
      -- "$zpc_capture_file" 2>/dev/null; then
      "$zpc_error_function" "Could not read the $zpc_noun picker result safely."
      return 125
    fi
    # The sysread builtin reads the result: $(<&fd) would run the host's
    # external cat, and not every cat reports a failed read. Status 5 marks
    # the end of the file. No read asks for more than one byte past the size
    # checked above, and a result of any other size counts as a failed read.
    while (( zpc_read_rc == 0 )); do
      zpc_chunk=""
      zpc_chunk_bytes=0
      sysread -c zpc_chunk_bytes -i "$zpc_read_fd" \
        -s "$(( zpc_file_state[size] - zpc_read_bytes + 1 ))" \
        zpc_chunk 2>/dev/null || zpc_read_rc=$?
      if (( zpc_read_rc == 0 )); then
        zpc_read_bytes+=zpc_chunk_bytes
        zpc_selection+="$zpc_chunk"
        (( zpc_chunk_bytes > 0 && zpc_read_bytes <= zpc_file_state[size] )) \
          || zpc_read_rc=1
      fi
    done
    (( zpc_read_rc == 5 && zpc_read_bytes == zpc_file_state[size] )) && zpc_read_rc=0
    exec {zpc_read_fd}>&-
    zpc_read_fd=-1
    if (( zpc_read_rc == 0 )); then
      # Remove every trailing newline, as command substitution does.
      () {
        setopt LOCAL_OPTIONS EXTENDED_GLOB NO_MULTIBYTE
        local -a match=() mbegin=() mend=()
        if [[ "$zpc_selection" == (#b)(*[^$'\n'])$'\n'# ]]; then
          zpc_selection="${match[1]}"
        else
          zpc_selection=""
        fi
      }
    fi
    if (( zpc_read_rc != 0 )); then
      "$zpc_error_function" "Could not read the $zpc_noun picker result."
      zpc_selection=""
    elif (( zpc_write_limit && zpc_picker_rc == 128 + $(kill -l XFSZ) )); then
      "$zpc_error_function" "The $zpc_noun picker output exceeded $zpc_max_bytes bytes."
      zpc_selection=""
      zpc_operation_rc=$zpc_picker_rc
    elif (( zpc_picker_rc == 1 && zpc_expect_key \
      && zpc_file_state[size] > 0 )) && [[ "$zpc_selection" != *$'\n'* ]]; then
      zpc_selection=""
      zpc_operation_rc=1
    elif (( zpc_picker_rc != 0 && zpc_file_state[size] > 0 )); then
      "$zpc_error_function" "A failed $zpc_noun picker returned unexpected data."
      zpc_selection=""
    else
      zpc_operation_rc=$zpc_picker_rc
    fi
  } always {
    (( zpc_write_fd >= 0 )) && exec {zpc_write_fd}>&-
    (( zpc_read_fd >= 0 )) && exec {zpc_read_fd}>&-
    if [[ -n "$zpc_file_identity" ]]; then
      zpc_file_state=()
      if [[ -f "$zpc_capture_file" && ! -L "$zpc_capture_file" ]] \
        && zstat -LH zpc_file_state -- "$zpc_capture_file" 2>/dev/null \
        && [[ "${zpc_file_state[device]}:${zpc_file_state[inode]}:${zpc_file_state[mode]}:"\
"${zpc_file_state[uid]}:${zpc_file_state[nlink]}" == "$zpc_file_identity" ]]; then
        command rm -f -- "$zpc_capture_file" 2>/dev/null || zpc_cleanup_failed=1
      else
        zpc_cleanup_failed=1
      fi
    elif [[ -n "$zpc_capture_file" ]]; then
      zpc_cleanup_failed=1
    fi
    if [[ -n "$zpc_directory_identity" ]]; then
      zpc_directory_state=()
      if [[ -d "$zpc_capture_dir" && ! -L "$zpc_capture_dir" ]] \
        && zstat -LH zpc_directory_state -- "$zpc_capture_dir" 2>/dev/null \
        && [[ "${zpc_directory_state[device]}:${zpc_directory_state[inode]}:"\
"${zpc_directory_state[mode]}:${zpc_directory_state[uid]}" == "$zpc_directory_identity" ]]; then
        command rmdir -- "$zpc_capture_dir" 2>/dev/null || zpc_cleanup_failed=1
      else
        zpc_cleanup_failed=1
      fi
    else
      zpc_cleanup_failed=1
    fi
    (( zpc_cleanup_failed == 0 )) || zpc_operation_rc=125
  }

  REPLY="$zpc_selection"
  return $zpc_operation_rc
}
# <<< zdx-primitive picker-capture

_zdx_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

# --- Fixed Suite & Plugin Dispatch -------------------------------------------

_zdx_dispatch_plugin() {
  local plugin_name="${1:-}"
  shift 2>/dev/null || true

  _zdx_plugin_name_valid "$plugin_name" || {
    _zdx_error "Invalid custom plugin identifier: '$plugin_name'."
    return 2
  }
  _zdx_wrapper_name_reserved "$plugin_name" && {
    _zdx_error "Custom plugin name '$plugin_name' is reserved by ZDX."
    return 2
  }
  _zdx_plugin_loaded "$plugin_name" || {
    _zdx_error "Unknown suite or command: '$plugin_name'."
    return 2
  }

  local plugin_function="${plugin_name}-menu"
  (( ${+functions[$plugin_function]} )) || {
    _zdx_error \
      "Loaded plugin '$plugin_name' no longer defines '$plugin_function'."
    return 1
  }

  # The function name is derived only after identifier and exact-membership
  # validation. Arguments remain individual literal array elements.
  local -a literal_arguments=("$@")
  "$plugin_function" "${literal_arguments[@]}"
}

_zdx_require_suite_function() {
  local function_name="${1:-}"
  (( ${+functions[$function_name]} )) && return 0
  _zdx_error \
    "Suite entrypoint '$function_name' is unavailable in this shell."
  return 1
}

_zdx_dispatch_suite() {
  local suite_name="${1:-}"
  shift 2>/dev/null || true

  case "$suite_name" in
    dev)
      _zdx_require_suite_function dev-menu || return
      dev-menu "$@"
      ;;
    env)
      _zdx_require_suite_function env-menu || return
      env-menu "$@"
      ;;
    file)
      _zdx_require_suite_function file-menu || return
      file-menu "$@"
      ;;
    git)
      _zdx_require_suite_function git-menu || return
      git-menu "$@"
      ;;
    plugins)
      _zdx_require_suite_function zdx-plugins || return
      zdx-plugins "$@"
      ;;
    py)
      _zdx_require_suite_function py-menu || return
      py-menu "$@"
      ;;
    sys)
      _zdx_require_suite_function sys-menu || return
      sys-menu "$@"
      ;;
    vpn)
      _zdx_require_suite_function vpn-menu || return
      vpn-menu "$@"
      ;;
    ws)
      _zdx_require_suite_function ws-menu || return
      ws-menu "$@"
      ;;
    doctor)
      _zdx_require_suite_function zdx-doctor || return
      zdx-doctor "$@"
      ;;
    status)
      _zdx_require_suite_function zdx-status || return
      zdx-status "$@"
      ;;
    :)       return 0 ;;
    *)       _zdx_dispatch_plugin "$suite_name" "$@" ;;
  esac
}

# --- Menu Model ---------------------------------------------------------------

_zdx_menu_model() {
  local -a definitions=(
    $'section\tProjects\tWork with repositories and maintain projects.'
    $'entry\tNavigate Workspaces (ws)\tws\tJump between repositories, clone into the workspace layout, and review status across them.'
    $'entry\tManage Git Repositories (git)\tgit\tStash, unstage, or amend local work, sync remotes, and manage tags, pull requests, and branches.'
    $'entry\tMaintain Projects (dev)\tdev\tUpdate project dependencies, run quality checks, inspect security, and clean caches.'

    $'section\tFiles and Environments\tManage local files, environment settings, and project Python environments.'
    $'entry\tManage Files and Archives (file)\tfile\tCreate archives, extract TAR archives, find large files, and manage trash and junk files.'
    $'entry\tInspect Shell Environment (env)\tenv\tBrowse exported variables with masked values and review or deduplicate PATH.'
    $'entry\tManage Python Environments (py)\tpy\tCreate project environments and manage Python packages, runtimes, and tools.'

    $'section\tSystem and VPN\tMaintain host tools and manage VPN connections.'
    $'entry\tMaintain System Tools (sys)\tsys\tInspect services, ports, and processes; update host tools and clean system caches.'
    $'entry\tManage WireGuard VPN (vpn)\tvpn\tInspect tunnel status, connect saved profiles, and manage WSL DNS protection.'

    $'section\tZDX Tools\tShow a status summary, check suite dependencies, and manage custom plugins.'
    $'entry\tShow Status Dashboard (status)\tstatus\tSummarize the repository, project, VPN, host, and ZDX settings on one read-only screen.'
    $'entry\tCheck Dependencies (doctor)\tdoctor\tInspect missing dependencies and choose whether to install supported packages.'
    $'entry\tManage Custom Plugins (plugins)\tplugins\tList, install, update, or remove custom ZDX plugins.'
  )

  local -a menu_rows=()
  local definition=""
  local row_kind="" label="" command_name="" description="" extra="" row=""
  for definition in "${definitions[@]}"; do
    row_kind=""
    label=""
    command_name=""
    description=""
    extra=""
    IFS=$'\t' read -r \
      row_kind label command_name description extra <<< "$definition"
    [[ -z "$extra" ]] || {
      _zdx_error "Invalid internal ZDX menu definition."
      return 1
    }

    case "$row_kind" in
      section)
        row=$(_zdx_menu_section "$label" "$command_name") || return
        ;;
      entry)
        row=$(_zdx_menu_entry \
          "$label" "$command_name" "$description") || return
        ;;
      *)
        _zdx_error "Invalid internal ZDX menu definition type."
        return 1
        ;;
    esac
    menu_rows+=("$row")
  done

  local -a loaded_plugins=()
  (( ${+ZDX_LOADED_PLUGINS} )) && loaded_plugins=("${ZDX_LOADED_PLUGINS[@]}")
  (( ${+ZDX_DISCOVERED_PLUGINS} )) \
    && loaded_plugins+=("${ZDX_DISCOVERED_PLUGINS[@]}")
  if (( ${#loaded_plugins[@]} > 0 )); then
    local plugin_name=""
    local -a included_plugins=() plugin_rows=()
    for plugin_name in "${loaded_plugins[@]}"; do
      if ! _zdx_plugin_name_valid "$plugin_name"; then
        _zdx_warn "Skipping invalid loaded plugin identifier: '$plugin_name'."
        continue
      fi
      if _zdx_wrapper_name_reserved "$plugin_name"; then
        _zdx_warn "Skipping loaded plugin with reserved name: '$plugin_name'."
        continue
      fi
      if (( ${included_plugins[(Ie)$plugin_name]} )); then
        continue
      fi
      if (( ! ${+functions[${plugin_name}-menu]} )); then
        _zdx_warn \
          "Skipping loaded plugin '$plugin_name' because its menu is unavailable."
        continue
      fi
      row=$(_zdx_menu_entry \
        "Open $plugin_name" "$plugin_name" \
        "Loaded in this shell. Open the custom plugin menu.") || return
      plugin_rows+=("$row")
      included_plugins+=("$plugin_name")
    done

    if (( ${#plugin_rows[@]} > 0 )); then
      row=$(_zdx_menu_section \
        "Custom Plugins" "Open custom suites loaded in this shell.") || return
      menu_rows+=("$row" "${plugin_rows[@]}")
    fi
  fi

  printf '%s\n' "${menu_rows[@]}"
}

_zdx_selected_row_in_snapshot() {
  local selected="${1:-}"
  shift 2>/dev/null || true

  local snapshot_row=""
  for snapshot_row in "$@"; do
    [[ "$selected" == "$snapshot_row" ]] && return 0
  done
  return 1
}

_zdx_interactive() {
  command -v fzf &>/dev/null || {
    _zdx_error \
      "fzf is required for the interactive menu; use 'zdx <suite>' directly."
    return 1
  }

  local menu_data=""
  menu_data=$(_zdx_menu_model) || return
  local -a menu_rows=("${(@f)menu_data}")
  (( ${#menu_rows[@]} > 0 )) || {
    _zdx_error "The ZDX menu model is empty."
    return 1
  }

  local selected=""
  local -i fzf_rc=0
  local menu_header="Directory: ${(V)${(D)PWD}}"$'\n'\
'Type to filter | Enter open | Esc cancel | Ctrl-/ details'
  _zdx_fzf_capture \
    --prompt='zdx > ' \
    --header="$menu_header" \
    --bind='ctrl-/:toggle-preview' \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: zdx %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    < <(printf '%s\n' "${menu_rows[@]}") || fzf_rc=$?
  selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _zdx_fzf_rc_is_cancel "$fzf_rc" && return 0
    _zdx_error "Unable to open the ZDX menu (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  _zdx_selected_row_in_snapshot "$selected" "${menu_rows[@]}" || {
    _zdx_error "The selected suite was not in the ZDX menu snapshot."
    return 1
  }

  local selected_fields="${selected#*|}"
  local suite_name="${selected_fields%%|*}"
  [[ "$suite_name" == ":" ]] && return 0
  _zdx_dispatch_suite "$suite_name"
}

typeset -g _ZDX_COMMON_SOURCED=1
