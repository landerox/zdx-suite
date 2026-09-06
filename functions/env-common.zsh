#!/usr/bin/env zsh
# =============================================================================
# Env Suite: private UI, selection, filesystem, and mutation primitives
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
typeset -gi _ENV_MAX_CANDIDATES=512
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

_env_debug() {
  [[ "${ENV_SUITE_DEBUG:-0}" == "1" ]] || return 0
  if _env_color_enabled; then
    printf '\033[0;90m  [debug] %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  [debug] %s\n' "${(V)1}" >&2
  fi
}

_env_dim() {
  if _env_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
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

# Clipboard backends receive the value on stdin. Callers must never fall back
# to printing the raw value when no backend is available.
_env_copy_to_clipboard() {
  local value="$1"

  if [[ "$OSTYPE" == darwin* ]] && command -v pbcopy &>/dev/null; then
    printf '%s' "$value" | command pbcopy 2>/dev/null
  elif [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy &>/dev/null; then
    printf '%s' "$value" | command wl-copy 2>/dev/null
  elif [[ -n "${DISPLAY:-}" ]] && command -v xclip &>/dev/null; then
    printf '%s' "$value" | command xclip -selection clipboard 2>/dev/null
  elif [[ -n "${DISPLAY:-}" ]] && command -v xsel &>/dev/null; then
    printf '%s' "$value" | command xsel --clipboard --input 2>/dev/null
  elif [[ "$OSTYPE" == linux* ]] && command -v clip.exe &>/dev/null; then
    printf '%s' "$value" | command clip.exe 2>/dev/null
  else
    return 1
  fi
}

# --- Filesystem trust helpers ----------------------------------------------

_env_system_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_env_validate_ancestor_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
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

_env_validate_temp_parent() {
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

_env_validate_operation_root() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local candidate_root="${1:-$PWD}"
  local lexical_root="${candidate_root:a}"
  local resolved_root="${candidate_root:A}"
  REPLY=""

  [[ "$lexical_root" == "$resolved_root" \
    && "$lexical_root" != "/" \
    && -d "$lexical_root" && ! -L "$lexical_root" ]] || {
    _env_error "The Environment operation root must be a real directory."
    return 1
  }
  local -A root_state=()
  zstat -LH root_state -- "$lexical_root" 2>/dev/null || return 1
  (( (root_state[mode] & 8#170000) == 8#040000 \
    && root_state[uid] == EUID \
    && (root_state[mode] & 8#22) == 0 )) || {
    _env_error \
      "The Environment operation root must be owned and not group/world-writable."
    return 1
  }
  _env_validate_ancestor_chain "$lexical_root" || return 1
  REPLY="$lexical_root"
}

_env_sha256_digest() {
  local input_file="$1"
  local digest_output=""
  local -i digest_rc=1
  REPLY=""
  if command -v sha256sum &>/dev/null; then
    digest_output=$(command sha256sum -- "$input_file")
    digest_rc=$?
  elif command -v shasum &>/dev/null; then
    digest_output=$(command shasum -a 256 -- "$input_file")
    digest_rc=$?
  else
    _env_error "sha256sum or shasum is required for file revalidation."
    return 1
  fi
  (( digest_rc == 0 )) || return 1
  local digest="${digest_output%%[[:space:]]*}"
  digest="${digest:l}"
  [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || return 1
  REPLY="$digest"
}

_env_file_fingerprint() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local target_file="$1"
  local -A file_state=()
  [[ -f "$target_file" && ! -L "$target_file" ]] \
    && zstat -LH file_state -- "$target_file" 2>/dev/null || return 1
  _env_sha256_digest "$target_file" || return 1
  local content_digest="$REPLY"
  REPLY="${file_state[device]}:${file_state[inode]}:${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}:${file_state[size]}:${file_state[mtime]}:${file_state[ctime]}:${content_digest}"
}

# A reviewed rename can change ctime while preserving the exact file and data.
# Accept that one transition, then return the complete new fingerprint so later
# validation remains sensitive to every field, including ctime.
_env_revalidate_moved_file() {
  emulate -L zsh
  local moved_file="$1" expected_fingerprint="$2"
  _env_file_fingerprint "$moved_file" || return 1
  local moved_fingerprint="$REPLY"
  local -a expected_fields=("${(@s/:/)expected_fingerprint}")
  local -a moved_fields=("${(@s/:/)moved_fingerprint}")
  (( ${#expected_fields[@]} == 9 && ${#moved_fields[@]} == 9 )) || return 1
  moved_fields[8]="${expected_fields[8]}"
  [[ "${(j/:/)moved_fields}" == "$expected_fingerprint" ]] || return 1
  REPLY="$moved_fingerprint"
}

_env_validate_regular_file() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local candidate_file="$1"
  local scope_root="$2"
  local protection="${3:-data}"
  local quiet="${4:-no}"
  REPLY=""

  local lexical_file="${candidate_file:a}"
  local resolved_file="${candidate_file:A}"
  [[ "$lexical_file" == "$resolved_file" \
    && "$lexical_file" == "$scope_root"/* \
    && "$lexical_file" != *$'\n'* \
    && "$lexical_file" != *$'\r'* \
    && "$lexical_file" != *[[:cntrl:]]* \
    && "$lexical_file" != *'|'* \
    && -f "$lexical_file" && ! -L "$lexical_file" ]] || {
    [[ "$quiet" == "yes" ]] \
      || _env_error "Refusing a non-regular, linked, or out-of-scope file."
    return 1
  }

  local -A file_state=()
  zstat -LH file_state -- "$lexical_file" 2>/dev/null || return 1
  if (( (file_state[mode] & 8#170000) != 8#100000 \
    || file_state[uid] != EUID \
    || file_state[nlink] != 1 \
    || (file_state[mode] & 8#22) != 0 \
    || file_state[size] < 0 \
    || file_state[size] > _ENV_MAX_FILE_BYTES )); then
    [[ "$quiet" == "yes" ]] \
      || _env_error "The file has unsafe ownership, links, permissions, or size."
    return 1
  fi
  if [[ "$protection" == "private" ]] \
    && (( (file_state[mode] & 8#777) != 8#600 )); then
    [[ "$quiet" == "yes" ]] \
      || _env_error "The private file must have mode 600."
    return 1
  fi

  _env_validate_ancestor_chain "$lexical_file" || return 1
  REPLY="$lexical_file"
}

_env_output_path() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local requested_path="$1"
  local scope_root="$2"
  local lexical_path="${requested_path:a}"
  local parent_dir="${lexical_path:h}"
  REPLY=""

  [[ "$lexical_path" == "$scope_root"/* \
    && "$lexical_path" != *$'\n'* \
    && "$lexical_path" != *$'\r'* \
    && "$lexical_path" != *[[:cntrl:]]* \
    && -d "$parent_dir" && ! -L "$parent_dir" \
    && "$parent_dir" == "${parent_dir:A}" ]] || {
    _env_error "The output must stay below the trusted operation root."
    return 1
  }
  local -A parent_state=()
  zstat -LH parent_state -- "$parent_dir" 2>/dev/null || return 1
  (( (parent_state[mode] & 8#170000) == 8#040000 \
    && parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )) || {
    _env_error "The output parent has unsafe ownership or permissions."
    return 1
  }
  _env_validate_ancestor_chain "$parent_dir" || return 1
  REPLY="$lexical_path"
}

# --- Foreground fzf capture -------------------------------------------------

_env_fzf() {
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
    SHELL=/bin/sh command fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

_env_fzf_capture() {
  emulate -L zsh
  REPLY=""
  zmodload zsh/stat zsh/system 2>/dev/null || {
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

# --- Atomic private-file publication ---------------------------------------

_env_atomic_publish_lines() {
  emulate -L zsh
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _env_error "Zsh file-descriptor support is required for safe publication."
    return 1
  }
  local output_file="$1"
  local overwrite="$2"
  local expected_fingerprint="$3"
  local lines_name="$4"
  local -a content_lines=("${(@P)lines_name}")
  local parent_dir="${output_file:h}"
  local -A parent_state=() current_parent_state=()
  [[ -d "$parent_dir" && ! -L "$parent_dir" \
    && "$parent_dir" == "${parent_dir:a}" \
    && "$parent_dir" == "${parent_dir:A}" ]] \
    && zstat -LH parent_state -- "$parent_dir" 2>/dev/null \
    && (( (parent_state[mode] & 8#170000) == 8#040000 \
      && parent_state[uid] == EUID \
      && (parent_state[mode] & 8#22) == 0 )) || {
    _env_error "The publication parent is unsafe."
    return 1
  }
  local parent_identity="${parent_state[device]}:${parent_state[inode]}:${parent_state[mode]}:${parent_state[uid]}"

  local staging_dir=""
  staging_dir=$(umask 077; command mktemp -d \
    "$parent_dir/.zdx-env-write.XXXXXX" 2>/dev/null) || {
    _env_error "Could not create a private staging directory."
    return 1
  }
  local -A staging_state=() current_staging_state=()
  if [[ "$staging_dir" != "${staging_dir:a}" \
    || "$staging_dir" != "${staging_dir:A}" \
    || "${staging_dir:h}" != "$parent_dir" \
    || "${staging_dir:t}" != .zdx-env-write.* \
    || ! -d "$staging_dir" || -L "$staging_dir" ]] \
    || ! zstat -LH staging_state -- "$staging_dir" 2>/dev/null \
    || (( (staging_state[mode] & 8#170000) != 8#040000 \
      || staging_state[uid] != EUID \
      || (staging_state[mode] & 8#777) != 8#700 )); then
    _env_error "Refusing an unsafe Environment staging directory."
    return 1
  fi
  local staging_identity="${staging_state[device]}:${staging_state[inode]}:${staging_state[mode]}:${staging_state[uid]}"

  local staged_file="$staging_dir/content"
  local original_file="$staging_dir/original"
  local original_fingerprint=""
  local staged_node_identity=""
  local -i write_fd=-1 operation_rc=1 retain_recovery=0
  local -i original_quarantined=0 published=0
  local content_line=""
  {
    umask 077
    if ! sysopen -w -o creat,excl,nofollow,cloexec -u write_fd \
      -- "$staged_file" 2>/dev/null; then
      _env_error "Could not create the staged Environment file."
      return 1
    fi
    for content_line in "${content_lines[@]}"; do
      print -u $write_fd -r -- "$content_line" || return 1
    done
    exec {write_fd}>&-
    write_fd=-1

    _env_file_fingerprint "$staged_file" || return 1
    local staged_fingerprint="$REPLY"
    local -a staged_fields=("${(@s/:/)staged_fingerprint}")
    (( (staged_fields[3] & 8#170000) == 8#100000 \
      && staged_fields[4] == EUID \
      && staged_fields[5] == 1 \
      && (staged_fields[3] & 8#777) == 8#600 \
      && staged_fields[6] <= _ENV_MAX_FILE_BYTES )) || {
      _env_error "The staged Environment file failed safety validation."
      return 1
    }
    staged_node_identity="${staged_fields[1]}:${staged_fields[2]}:${staged_fields[3]}:${staged_fields[4]}"

    current_parent_state=()
    zstat -LH current_parent_state -- "$parent_dir" 2>/dev/null \
      && [[ "${current_parent_state[device]}:${current_parent_state[inode]}:${current_parent_state[mode]}:${current_parent_state[uid]}" \
        == "$parent_identity" ]] || {
      _env_error "The publication parent changed before publication."
      return 1
    }

    if [[ "$overwrite" == "yes" ]]; then
      _env_file_fingerprint "$output_file" || {
        _env_error "The reviewed output disappeared before publication."
        return 1
      }
      [[ "$REPLY" == "$expected_fingerprint" ]] || {
        _env_error "The reviewed output changed before publication."
        return 1
      }
      command mv "$output_file" "$original_file" || return 1
      original_quarantined=1
      if ! _env_revalidate_moved_file "$original_file" "$expected_fingerprint"; then
        _env_error "The quarantined output did not match the reviewed file."
        return 1
      fi
      original_fingerprint="$REPLY"
    elif [[ -e "$output_file" || -L "$output_file" ]]; then
      _env_error "The output appeared before publication; refusing to clobber it."
      return 1
    fi

    if ! command ln "$staged_file" "$output_file" 2>/dev/null; then
      _env_error "Could not publish the Environment file without clobbering."
      return 1
    fi
    published=1
    local -A published_state=()
    [[ -f "$output_file" && ! -L "$output_file" ]] \
      && zstat -LH published_state -- "$output_file" 2>/dev/null \
      && [[ "${published_state[device]}:${published_state[inode]}:${published_state[mode]}:${published_state[uid]}" \
        == "$staged_node_identity" ]] \
      && (( published_state[nlink] == 2 )) || {
      _env_error "The published Environment file failed identity validation."
      return 1
    }
    command rm -f "$staged_file" 2>/dev/null || return 1
    published_state=()
    zstat -LH published_state -- "$output_file" 2>/dev/null \
      && [[ "${published_state[device]}:${published_state[inode]}:${published_state[mode]}:${published_state[uid]}" \
        == "$staged_node_identity" ]] \
      && (( published_state[nlink] == 1 )) || {
      _env_error "The published Environment file has an unexpected link count."
      return 1
    }

    if [[ "$overwrite" == "yes" ]]; then
      _env_file_fingerprint "$original_file" || return 1
      [[ "$REPLY" == "$original_fingerprint" ]] || {
        retain_recovery=1
        _env_error "The quarantined original changed; retaining recovery data."
        return 1
      }
      command rm -f "$original_file" 2>/dev/null || {
        retain_recovery=1
        _env_error "Could not remove the quarantined original."
        return 1
      }
      original_quarantined=0
    fi
    operation_rc=0
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    if (( operation_rc != 0 && published == 1 )); then
      local -A failed_output_state=()
      if [[ -n "$staged_node_identity" \
        && -f "$output_file" && ! -L "$output_file" ]] \
        && zstat -LH failed_output_state -- "$output_file" 2>/dev/null \
        && [[ "${failed_output_state[device]}:${failed_output_state[inode]}:${failed_output_state[mode]}:${failed_output_state[uid]}" \
          == "$staged_node_identity" ]] \
        && command rm -f "$output_file" 2>/dev/null; then
        published=0
        retain_recovery=0
      else
        retain_recovery=1
      fi
    fi
    if (( original_quarantined == 1 && published == 0 )); then
      if _env_file_fingerprint "$original_file" \
        && [[ -n "$original_fingerprint" && "$REPLY" == "$original_fingerprint" \
          && ! -e "$output_file" && ! -L "$output_file" ]] \
        && command mv "$original_file" "$output_file" 2>/dev/null; then
        original_quarantined=0
      else
        retain_recovery=1
      fi
    elif (( original_quarantined == 1 )); then
      retain_recovery=1
    fi
    if (( retain_recovery == 0 )); then
      if [[ -e "$staged_file" || -L "$staged_file" ]]; then
        local -a cleanup_staged_fields=()
        if [[ -n "$staged_node_identity" ]] \
          && _env_file_fingerprint "$staged_file"; then
          cleanup_staged_fields=("${(@s/:/)REPLY}")
        fi
        if (( ${#cleanup_staged_fields[@]} >= 5 )) \
          && [[ "${cleanup_staged_fields[1]}:${cleanup_staged_fields[2]}:${cleanup_staged_fields[3]}:${cleanup_staged_fields[4]}" \
            == "$staged_node_identity" ]] \
          && (( cleanup_staged_fields[5] == 1 )) \
          && command rm -f "$staged_file" 2>/dev/null; then
          :
        else
          retain_recovery=1
          operation_rc=1
        fi
      fi
    fi
    if (( retain_recovery == 0 )); then
      current_staging_state=()
      if [[ -d "$staging_dir" && ! -L "$staging_dir" ]] \
        && zstat -LH current_staging_state -- "$staging_dir" 2>/dev/null \
        && [[ "${current_staging_state[device]}:${current_staging_state[inode]}:${current_staging_state[mode]}:${current_staging_state[uid]}" \
          == "$staging_identity" ]]; then
        command rmdir "$staging_dir" 2>/dev/null || operation_rc=1
      else
        _env_warn "The staging directory changed; refusing cleanup."
        operation_rc=1
      fi
    else
      _env_warn "Recovery data was retained at: $staging_dir"
    fi
  }
  return $operation_rc
}

typeset -g _ENV_COMMON_SOURCED=1
