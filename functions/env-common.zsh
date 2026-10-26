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

# Asks one yes/no question through the core _zdx_confirm_prompt, or its
# generated copy below in a shell without the core: 0 yes, 1 no, 2 no
# terminal, 3 picker failure.
_env_confirm_ask() {
  local -a zcp_options=(--style line --error _env_error)
  if (( ${+functions[_zdx_confirm_prompt]} )); then
    _zdx_confirm_prompt "${zcp_options[@]}" -- "$@"
  else
    _env_confirm_prompt "${zcp_options[@]}" -- "$@"
  fi
}

# >>> zdx-primitive confirm-prompt
# Asks one yes/no question on the terminal and returns 0 for yes, 1 for a
# decline or a cancelled picker, 2 when no terminal can answer (stdin or
# stderr is not a terminal, or input ended), and 3 when the picker failed.
# Only an exact Yes, or y or Y, confirms. --style picker offers No and Yes in
# an fzf picker through the given capture function when fzf is installed and
# otherwise asks for a line; --style line asks `? PROMPT [y/N]:` and reads a
# line; --style key reads a single key. --available names a suite function
# that replaces the terminal test. Generated copies in the suite common files
# keep a suite working without the core; `just sync-primitives` writes them.
# Usage: _env_confirm_prompt --style picker|line|key --error FUNCTION \
#          [--capture FUNCTION] [--available FUNCTION] -- PROMPT
_env_confirm_prompt() {
  emulate -L zsh
  local zcp_style="" zcp_error_function="" zcp_capture_function=""
  local zcp_available_function=""
  while (( $# > 0 )); do
    case "$1" in
      --style) zcp_style="${2-}"; shift 2 ;;
      --available) zcp_available_function="${2-}"; shift 2 ;;
      --error) zcp_error_function="${2-}"; shift 2 ;;
      --capture) zcp_capture_function="${2-}"; shift 2 ;;
      --) shift; break ;;
      *) return 3 ;;
    esac
  done
  local zcp_prompt="${1:-Proceed?}"
  [[ "$zcp_style" == (picker|line|key) \
    && "$zcp_error_function" =~ '^_[a-z0-9_]+$' ]] \
    && (( ${+functions[$zcp_error_function]} )) || return 3
  if [[ "$zcp_style" == picker ]]; then
    [[ "$zcp_capture_function" =~ '^_[a-z0-9_]+$' ]] \
      && (( ${+functions[$zcp_capture_function]} )) || return 3
  fi
  if [[ -n "$zcp_available_function" ]]; then
    [[ "$zcp_available_function" =~ '^_[a-z0-9_]+$' ]] \
      && (( ${+functions[$zcp_available_function]} )) || return 3
    "$zcp_available_function" || return 2
  else
    [[ -t 0 && -t 2 ]] || return 2
  fi

  if [[ "$zcp_style" == picker ]] && (( ${+commands[fzf]} )); then
    local REPLY="" zcp_answer=""
    local -i zcp_picker_rc=0
    "$zcp_capture_function" \
      --height=20% \
      --layout=reverse \
      --border=rounded \
      --pointer='▶' \
      --preview='' \
      --preview-window=hidden \
      --header='Up/Down navigate | Enter confirm | Esc cancel' \
      "--prompt=${(V)zcp_prompt} > " \
      < <(print -rl -- No Yes) || zcp_picker_rc=$?
    zcp_answer="$REPLY"
    if (( zcp_picker_rc == 0 )); then
      case "$zcp_answer" in
        Yes) return 0 ;;
        No|"") return 1 ;;
      esac
      "$zcp_error_function" "fzf returned an answer outside the confirmation choices."
      return 3
    fi
    (( zcp_picker_rc == 1 || zcp_picker_rc == 130 )) && return 1
    "$zcp_error_function" "fzf failed while requesting confirmation (exit $zcp_picker_rc)."
    return 3
  fi

  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb && -t 2 ]]; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)zcp_prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)zcp_prompt}" >&2
  fi
  local zcp_reply=""
  if [[ "$zcp_style" == key ]]; then
    read -r -k 1 -u 0 zcp_reply || {
      print -u2 -r -- ""
      return 2
    }
    print -u2 -r -- ""
  else
    IFS= read -r zcp_reply || return 2
  fi
  [[ "$zcp_reply" == [Yy] ]]
}
# <<< zdx-primitive confirm-prompt

_env_confirm() {
  local prompt="${1:-Proceed?}"
  local auto_yes="${2:-no}"
  [[ "$auto_yes" == "yes" ]] && return 0
  _env_confirm_ask "$prompt"
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

# Runs one Environment picker in the terminal foreground and captures its
# selection privately: REPLY is the selection and the status is the picker's
# own, or 125 when the capture failed or was refused. The core
# _zdx_picker_capture owns the implementation; _env_picker_capture below is its
# generated copy for a shell without the core.
_env_fzf_capture() {
  local -a zpc_options=(
    --max-bytes 1048576 --tag env --noun Environment --error _env_error
    --picker _env_fzf --temp-root _env_validate_temp_parent
  )
  if (( ${+functions[_zdx_picker_capture]} )); then
    _zdx_picker_capture "${zpc_options[@]}" -- "$@"
  else
    _env_picker_capture "${zpc_options[@]}" -- "$@"
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
# Usage: _env_picker_capture [--max-bytes N] [--write-limit] --tag TAG \
#          --noun TEXT --error FUNCTION --picker FUNCTION \
#          --temp-root FUNCTION -- [picker-argument...]
_env_picker_capture() {
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

_env_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

typeset -g _ENV_COMMON_SOURCED=1
