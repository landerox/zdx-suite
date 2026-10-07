#!/usr/bin/env zsh
# =============================================================================
# Env Suite: private UI, confirmation, masking, and picker primitives
# =============================================================================
#
# Loaded by env-menu.zsh before every module under functions/env/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_ENV_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _ENV_MAX_FILE_BYTES=1048576
typeset -gi _ENV_MAX_RECORDS=512
typeset -gi _ENV_MAX_PICKER_BYTES=1048576
typeset -gi _ENV_MAX_MENU_ROWS=32

# --- UI --------------------------------------------------------------------

_env_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

_env_header() {
  if _env_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}

_env_success() {
  if _env_color_enabled; then
    printf '\033[1;32m✔ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✔ %s\n' "${(V)1}" >&2
  fi
}

_env_warn() {
  if _env_color_enabled; then
    printf '\033[1;33m⚠ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⚠ %s\n' "${(V)1}" >&2
  fi
}

_env_info() {
  if _env_color_enabled; then
    printf '\033[0;36m➜ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '➜ %s\n' "${(V)1}" >&2
  fi
}

_env_error() {
  if _env_color_enabled; then
    printf '\033[1;31m✘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✘ %s\n' "${(V)1}" >&2
  fi
}

_env_dim() {
  if _env_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
}

# One key-value line through the core service, padded to its width alone.
# Usage: _env_label <key> <value>
_env_label() {
  if (( ${+functions[_zdx_ui_label]} )); then
    _zdx_ui_label "${1-}" "${2-}"
    return
  fi
  printf '  %-18s %s\n' "${(V)${1-}%:}:" "${(V)2-}" >&2
}

# A report sub-heading through the core service.
# Usage: _env_section [--first] <title>
_env_section() {
  if (( ${+functions[_zdx_ui_section]} )); then
    _zdx_ui_section "$@"
    return
  fi
  local gap=$'\n'
  if [[ "${1:-}" == --first ]]; then
    gap=""
    shift
  fi
  printf '%s▸ %s\n' "$gap" "${(V)${1:-}}" >&2
}

# REPLY: a display-only command line with HOME shown as ~; never executed.
# Usage: _env_command_display <argv...>
_env_command_display() {
  if (( ${+functions[_zdx_ui_command_display]} )); then
    _zdx_ui_command_display "$@"
    return
  fi
  REPLY="${(j: :)${(@q-)@}}"
}

# REPLY: "<count> <noun>". Usage: _env_count_noun <count> <singular> [plural]
_env_count_noun() {
  if (( ${+functions[_zdx_count_noun]} )); then
    _zdx_count_noun "$@"
    return
  fi
  local count="${1:-}" singular="${2:-}" plural="${3:-${2:-}s}"
  [[ "$count" == <-> && -n "$singular" ]] || return 2
  if (( count == 1 )); then REPLY="1 $singular"; else REPLY="$count $plural"; fi
}

_env_timed() {
  local label="$1"
  shift
  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

_env_require_cmd() {
  local command_name="$1"
  local purpose="${2:-this operation}"
  command -v "$command_name" &>/dev/null && return 0
  _env_error "$command_name is required for $purpose."
  return 1
}

# --- Confirmation -----------------------------------------------------------

_env_confirm() {
  local prompt="${1:-Proceed?}"
  local auto_yes="${2:-no}"

  [[ "$auto_yes" == "yes" ]] && return 0
  [[ -t 0 && -t 2 ]] || return 2

  local answer=""
  if _env_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi
  read -r answer || return 2
  print -u2 -r -- ""
  [[ "$answer" =~ ^[Yy]$ ]]
}

_env_confirm_mutation() {
  local prompt="$1"
  local auto_yes="${2:-no}"
  local -i confirm_rc=0

  _env_confirm "$prompt" "$auto_yes" || confirm_rc=$?
  case "$confirm_rc" in
    0) return 0 ;;
    1)
      _env_info "Cancelled."
      return 130
      ;;
    *)
      _env_error "Confirmation requires a terminal; pass --yes to proceed."
      return "$confirm_rc"
      ;;
  esac
}

# --- Menu rows --------------------------------------------------------------

_env_menu_field_safe() {
  [[ "$1" != *'|'* && "$1" != *$'\n'* && "$1" != *$'\r'* \
    && "$1" != *[[:cntrl:]]* ]]
}

_env_menu_section() {
  local title="$1"
  local description="${2:-}"
  _env_menu_field_safe "$title" && _env_menu_field_safe "$description" || {
    _env_error "Invalid Environment menu section fields."
    return 2
  }
  printf '── %s ──|:|%s\n' "$title" "$description"
}

_env_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"
  _env_menu_field_safe "$label" \
    && _env_menu_field_safe "$command_name" \
    && _env_menu_field_safe "$description" || {
    _env_error "Invalid Environment menu entry fields."
    return 2
  }
  printf '  %s|%s|%s\n' "$label" "$command_name" "$description"
}

# --- Secret-safe display ----------------------------------------------------

_env_key_is_sensitive() {
  local key_lower="${1:l}"
  [[ "$key_lower" == *(api_key|apikey|secret|password|passwd|token|auth|credential|jwt|private|ssh_key|passphrase|cookie|session)* ]]
}

_env_value_classification() {
  if _env_key_is_sensitive "${1:-}"; then
    print -r -- "********"
  else
    print -r -- "<hidden>"
  fi
}

_env_visible_field() {
  local value="${(V)1}"
  value="${value//|/¦}"
  if (( ${#value} > 256 )); then
    value="${value[1,253]}..."
  fi
  REPLY="$value"
}

# True when Linux runs under WSL: its session variables, its interop
# registration (WSLInterop, or WSLInterop-late on newer releases), or a
# Microsoft kernel release. The optional argument replaces /proc for fixtures.
_env_host_is_wsl() {
  local proc_root="${1:-/proc}" kernel_release=""
  [[ "${OSTYPE:-}" == linux* ]] || return 1
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  [[ -e "$proc_root/sys/fs/binfmt_misc/WSLInterop" \
    || -e "$proc_root/sys/fs/binfmt_misc/WSLInterop-late" ]] && return 0
  [[ -f "$proc_root/sys/kernel/osrelease" \
    && -r "$proc_root/sys/kernel/osrelease" ]] || return 1
  kernel_release=$(<"$proc_root/sys/kernel/osrelease") 2>/dev/null || return 1
  [[ "${kernel_release:l}" == *microsoft* ]]
}

# REPLY is the Windows clipboard program under its default WSL automount.
_env_wsl_windows_clip_path() {
  REPLY=/mnt/c/Windows/System32/clip.exe
}

# REPLY is the clip.exe to use on Linux: the one on PATH, or under WSL the
# Windows system copy, which stays reachable when appendWindowsPath=false
# removes the Windows directories from PATH.
_env_clip_exe_command() {
  REPLY=""
  [[ "${OSTYPE:-}" == linux* ]] || return 1
  local resolved=""
  resolved=$(whence -p clip.exe 2>/dev/null) || resolved=""
  if [[ "$resolved" == /* && -x "$resolved" ]]; then
    REPLY="$resolved"
    return 0
  fi
  _env_host_is_wsl || return 1
  _env_wsl_windows_clip_path
  resolved="$REPLY"
  REPLY=""
  [[ "$resolved" == /* && -f "$resolved" && -x "$resolved" ]] || return 1
  REPLY="$resolved"
}

# Sends text to clip.exe, which reads UTF-16LE when the input starts with its
# byte-order mark and the console code page otherwise. The value is
# converted completely before anything reaches clip.exe, so invalid UTF-8
# never sets a partial clipboard. Without iconv, only ASCII text is sent.
# Usage: _env_copy_to_clip_exe <clip.exe> <value>
_env_copy_to_clip_exe() {
  emulate -L zsh
  setopt local_options pipefail
  local clip_command="$1" value="$2" iconv_command=""
  iconv_command=$(whence -p iconv 2>/dev/null) || iconv_command=""
  if [[ "$iconv_command" == /* && -x "$iconv_command" ]]; then
    printf '%s' "$value" \
      | command "$iconv_command" -f UTF-8 -t UTF-16LE >/dev/null 2>&1 || {
      _env_error "The value is not valid UTF-8 text for the Windows clipboard."
      return 2
    }
    {
      printf '\377\376'
      printf '%s' "$value" \
        | command "$iconv_command" -f UTF-8 -t UTF-16LE 2>/dev/null
    } | command "$clip_command" 2>/dev/null || return 2
  elif [[ "$value" != *[^[:ascii:]]* ]]; then
    printf '%s' "$value" | command "$clip_command" 2>/dev/null || return 2
  else
    _env_error "iconv is required to copy non-ASCII text to the Windows clipboard."
    return 2
  fi
}

# Copies one value to the first supported clipboard backend through stdin.
# Status 1 means no backend is available and 2 that the backend failed.
# Callers must never fall back to printing the raw value.
_env_copy_to_clipboard() {
  emulate -L zsh
  local value="$1" REPLY=""

  if [[ "${OSTYPE:-}" == darwin* ]] && command -v pbcopy &>/dev/null; then
    # pbcopy decodes its input with the locale's encoding; a C or POSIX
    # locale would turn UTF-8 text into MacRoman.
    local locale_name="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    if [[ "${locale_name:l}" == *utf-8* || "${locale_name:l}" == *utf8* ]]; then
      printf '%s' "$value" | command pbcopy 2>/dev/null || return 2
    else
      printf '%s' "$value" \
        | LC_ALL=en_US.UTF-8 command pbcopy 2>/dev/null || return 2
    fi
  elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy &>/dev/null; then
    printf '%s' "$value" | command wl-copy 2>/dev/null || return 2
  elif [[ -n "${DISPLAY:-}" ]] && command -v xclip &>/dev/null; then
    printf '%s' "$value" \
      | command xclip -selection clipboard 2>/dev/null || return 2
  elif [[ -n "${DISPLAY:-}" ]] && command -v xsel &>/dev/null; then
    printf '%s' "$value" \
      | command xsel --clipboard --input 2>/dev/null || return 2
  elif _env_clip_exe_command; then
    _env_copy_to_clip_exe "$REPLY" "$value"
  else
    return 1
  fi
}

# --- Filesystem trust helpers ----------------------------------------------

_env_system_root_uid() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_env_validate_ancestor_chain() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local child_path="$1"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _env_system_root_uid || return 1
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
      _env_error \
        "A parent directory is not trusted against replacement: $parent_path"
      return 1
    fi
    child_path="$parent_path"
  done
}

# REPLY is the canonical directory for an absolute, already-normalized path.
# A symbolic link on the literal path is accepted only as a root-owned system
# alias, such as macOS /var and /tmp, or above the final component when the
# current user owns it inside a directory owned by root or the current user
# that group and other users cannot write. This mirrors the core
# _zdx_resolve_trusted_dir so the suite stays sourceable on its own.
_env_resolve_trusted_dir() {
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

# REPLY is the canonical temporary parent. The ownership, sticky-bit, and
# ancestor checks apply to the canonical directory.
_env_validate_temp_parent() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local requested_parent="${1:-}"
  REPLY=""
  _env_resolve_trusted_dir "$requested_parent" || {
    _env_error "The temporary parent is not a real directory."
    return 1
  }
  requested_parent="$REPLY"
  REPLY=""
  [[ -n "$requested_parent" && "$requested_parent" == /* \
    && -d "$requested_parent" && ! -L "$requested_parent" \
    && "$requested_parent" == "${requested_parent:a}" \
    && "$requested_parent" == "${requested_parent:A}" ]] || {
    _env_error "The temporary parent is not a real directory."
    return 1
  }

  _env_system_root_uid || return 1
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
    _env_error "The temporary parent has unsafe ownership or permissions."
    return 1
  fi
  _env_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

# --- Foreground fzf capture -------------------------------------------------

_env_fzf() {
  local -a fzf_options=(
    --layout=reverse
    --border=rounded
    --pointer='▶'
  )
  fzf_options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow')

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

  # fzf with templates hides the delimiter that trails a single shown field.
  local REPLY=""
  if typeset -f _tk_fzf_nth_template_option &>/dev/null \
    && _tk_fzf_nth_template_option "${fzf_options[@]}" "$@"; then
    terminal_options+=("$REPLY")
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh command fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

_env_fzf_capture() {
  emulate -L zsh
  REPLY=""
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
    _env_error "Zsh file-descriptor support is required for Environment pickers."
    return 125
  }
  _env_validate_temp_parent "${TMPDIR:-/tmp}" || return 125
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-env-fzf.XXXXXX" 2>/dev/null) || {
    _env_error "Could not create a private Environment picker directory."
    return 125
  }
  local -A directory_state=() file_state=() current_directory_state=()
  local -A current_file_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || "${capture_dir:h}" != "$temp_root" \
    || "${capture_dir:t}" != zdx-env-fzf.* \
    || ! -d "$capture_dir" || -L "$capture_dir" ]] \
    || ! zstat -LH directory_state -- "$capture_dir" 2>/dev/null \
    || (( (directory_state[mode] & 8#170000) != 8#040000 \
      || directory_state[uid] != EUID \
      || (directory_state[mode] & 8#777) != 8#700 )); then
    _env_error "Refusing an unsafe Environment picker directory."
    return 125
  fi
  local directory_identity="${directory_state[device]}:${directory_state[inode]}:${directory_state[mode]}:${directory_state[uid]}"

  local capture_file=""
  capture_file=$(umask 077; command mktemp \
    "$capture_dir/.result.XXXXXX" 2>/dev/null) || {
    current_directory_state=()
    if zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_directory_state[device]}:${current_directory_state[inode]}:${current_directory_state[mode]}:${current_directory_state[uid]}" \
        == "$directory_identity" ]]; then
      command rmdir "$capture_dir" 2>/dev/null
    fi
    return 125
  }
  if [[ "$capture_file" != "${capture_file:a}" \
    || "$capture_file" != "${capture_file:A}" \
    || "${capture_file:h}" != "$capture_dir" \
    || "${capture_file:t}" != .result.* \
    || ! -f "$capture_file" || -L "$capture_file" ]] \
    || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
    || (( (file_state[mode] & 8#170000) != 8#100000 \
      || file_state[uid] != EUID \
      || file_state[nlink] != 1 \
      || (file_state[mode] & 8#777) != 8#600 )); then
    current_directory_state=()
    if zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_directory_state[device]}:${current_directory_state[inode]}:${current_directory_state[mode]}:${current_directory_state[uid]}" \
        == "$directory_identity" ]]; then
      command rmdir "$capture_dir" 2>/dev/null
    fi
    _env_error "Refusing an unsafe Environment picker result."
    return 125
  fi
  local file_identity="${file_state[device]}:${file_state[inode]}:${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"

  local selection=""
  local -i write_fd=-1 read_fd=-1 fzf_rc=125 operation_rc=125 cleanup_rc=0
  {
    if ! sysopen -w -o nofollow,cloexec -u write_fd \
      -- "$capture_file" 2>/dev/null; then
      _env_error "Could not open the Environment picker result safely."
    else
      _env_fzf "$@" 1>&$(( write_fd ))
      fzf_rc=$?
      exec {write_fd}>&-
      write_fd=-1

      current_directory_state=()
      current_file_state=()
      if ! zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
        || [[ "${current_directory_state[device]}:${current_directory_state[inode]}:${current_directory_state[mode]}:${current_directory_state[uid]}" \
          != "$directory_identity" ]] \
        || ! zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
        || [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
          != "$file_identity" ]] \
        || (( current_file_state[size] < 0 \
          || current_file_state[size] > _ENV_MAX_PICKER_BYTES )); then
        _env_error "The Environment picker result changed or is oversized."
      elif ! sysopen -r -o nofollow,cloexec -u read_fd \
        -- "$capture_file" 2>/dev/null; then
        _env_error "Could not read the Environment picker result safely."
      else
        selection=$(<&$(( read_fd )))
        exec {read_fd}>&-
        read_fd=-1
        operation_rc=$fzf_rc
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    current_file_state=()
    if [[ -f "$capture_file" && ! -L "$capture_file" ]] \
      && zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
      && [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
        == "$file_identity" ]]; then
      command rm -f "$capture_file" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi

    current_directory_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" ]] \
      && zstat -LH current_directory_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_directory_state[device]}:${current_directory_state[inode]}:${current_directory_state[mode]}:${current_directory_state[uid]}" \
        == "$directory_identity" ]]; then
      command rmdir "$capture_dir" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    (( cleanup_rc == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_env_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

typeset -g _ENV_COMMON_SOURCED=1
