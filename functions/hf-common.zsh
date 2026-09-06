#!/usr/bin/env zsh
# =============================================================================
# Hugging Face Common: validation, backend, UI, and foreground selection
# =============================================================================
#
# Loaded by hf-menu.zsh before every module under functions/hf/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_HF_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_hf_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_hf_header() {
  if _hf_color_enabled; then
    printf "\n\033[1;35m════ %s ════\033[0m\n\n" "$1" >&2
  else
    printf "\n════ %s ════\n\n" "$1" >&2
  fi
}

_hf_success() {
  if _hf_color_enabled; then
    printf "\033[1;32m✔ %s\033[0m\n" "$1" >&2
  else
    printf "✔ %s\n" "$1" >&2
  fi
}

_hf_warn() {
  if _hf_color_enabled; then
    printf "\033[1;33m⚠ %s\033[0m\n" "$1" >&2
  else
    printf "⚠ %s\n" "$1" >&2
  fi
}

_hf_info() {
  if _hf_color_enabled; then
    printf "\033[0;34m➜ %s\033[0m\n" "$1" >&2
  else
    printf "➜ %s\n" "$1" >&2
  fi
}

_hf_error() {
  if _hf_color_enabled; then
    printf "\033[1;31m✘ %s\033[0m\n" "$1" >&2
  else
    printf "✘ %s\n" "$1" >&2
  fi
}

_hf_dim() {
  if _hf_color_enabled; then
    printf "\033[0;90m  %s\033[0m\n" "$1" >&2
  else
    printf "  %s\n" "$1" >&2
  fi
}

_hf_label() {
  local label="$1"
  local value="$2"
  if _hf_color_enabled; then
    printf "\033[1;35m%-22s\033[0m %s\n" "$label" "$value" >&2
  else
    printf "%-22s %s\n" "$label" "$value" >&2
  fi
}

# stdout: a terminal-safe visible representation of arbitrary data.
_hf_display_escape() {
  print -r -- "${(V)1}"
}

_hf_visible_value_safe() {
  local value="${1:-}"
  local -i maximum_length="${2:-4096}"
  (( maximum_length >= 1 && maximum_length <= 65536 )) || return 1
  (( ${#value} <= maximum_length )) \
    && [[ "$value" != *[[:cntrl:]]* ]]
}

_hf_system_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_hf_validate_ancestor_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local child_path="${1:-}"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _hf_system_root_uid || return 1
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

_hf_validate_temp_parent() {
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

  _hf_system_root_uid || return 1
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
  _hf_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

_hf_menu_section() {
  local title="$1"
  local description="${2:-}"

  if [[ "$title" == *'|'* || "$description" == *'|'* ]] \
    || ! _hf_visible_value_safe "$title" 256 \
    || ! _hf_visible_value_safe "$description" 1024; then
    _hf_error "Invalid menu section fields."
    return 2
  fi

  printf "── %s ──|:|%s\n" "$title" "$description"
}

_hf_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"

  if [[ "$label" == *'|'* || "$command_name" == *'|'* \
    || "$description" == *'|'* ]] \
    || ! _hf_visible_value_safe "$label" 256 \
    || ! _hf_visible_value_safe "$command_name" 128 \
    || ! _hf_visible_value_safe "$description" 1024; then
    _hf_error "Invalid menu entry fields."
    return 2
  fi
  [[ "$command_name" == ":" \
    || "$command_name" =~ '^[a-z][a-z0-9-]*$' ]] || {
    _hf_error "Invalid Hugging Face command token."
    return 2
  }

  printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
}

_hf_array_contains_literal() {
  local needle="${1-}" candidate=""
  shift 2>/dev/null || return 2
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

_hf_fzf() {
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
_hf_fzf_capture() {
  emulate -L zsh
  REPLY=""

  zmodload zsh/stat zsh/system 2>/dev/null || {
    _hf_error "Zsh file-descriptor support is required for Hugging Face menus."
    return 125
  }

  _hf_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _hf_error "Refusing an unsafe temporary root for the Hugging Face menu."
    return 125
  }
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-hf-fzf.XXXXXX" 2>/dev/null) || {
    _hf_error "Could not create a private Hugging Face menu directory."
    return 125
  }
  command chmod 700 -- "$capture_dir" 2>/dev/null || {
    command rmdir -- "$capture_dir" 2>/dev/null
    _hf_error "Could not protect the Hugging Face menu directory."
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
    _hf_error "Refusing an unsafe Hugging Face menu directory."
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
      _hf_error "Could not create a private Hugging Face menu result."
    elif ! command chmod 600 -- "$capture_file" 2>/dev/null; then
      _hf_error "Could not protect the Hugging Face menu result."
    elif [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$capture_dir" \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 )); then
      _hf_error "Refusing an unsafe Hugging Face menu result."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$capture_file" 2>/dev/null; then
        _hf_error "Could not open the Hugging Face menu result safely."
      else
        _hf_fzf "$@" 1>&$(( write_fd ))
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
          _hf_error "The Hugging Face menu result changed or is oversized."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _hf_error "Could not read the Hugging Face menu result safely."
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

_hf_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

_hf_prompt() {
  local label="$1"
  local default="${2:-}"
  REPLY="$default"

  [[ -t 0 && -t 2 ]] || return 1
  if _hf_color_enabled; then
    printf "\033[1;35m%s\033[0m [%s]: " "$label" "$default" >&2
  else
    printf "%s [%s]: " "$label" "$default" >&2
  fi
  local entered=""
  IFS= read -r entered || return 130
  [[ -n "$entered" ]] && REPLY="$entered"
}

_hf_confirm() {
  local message="${1:-Proceed?}"
  [[ -t 0 && -t 2 ]] || return 1

  if command -v fzf &>/dev/null; then
    local -a choices=("No" "Yes")
    local -i fzf_rc=0
    _hf_fzf_capture \
      --height=20% \
      --prompt="$(_hf_display_escape "$message") > " \
      --header='Up/Down choose | Enter confirm | Esc cancel' \
      < <(printf "%s\n" "${choices[@]}") || fzf_rc=$?
    local selected="$REPLY"
    if (( fzf_rc != 0 )); then
      _hf_fzf_rc_is_cancel "$fzf_rc" && return 130
      return 1
    fi
    _hf_array_contains_literal "$selected" "${choices[@]}" || return 1
    [[ "$selected" == "Yes" ]] && return 0
    return 130
  fi

  printf "%s [y/N]: " "$(_hf_display_escape "$message")" >&2
  local answer=""
  read -q answer
  local -i read_rc=$?
  print -u2 -r -- ""
  (( read_rc == 0 )) && return 0
  return 130
}

_hf_pick_repo_type() {
  local prompt_label="${1:-Select repository type}"
  REPLY=""

  command -v fzf &>/dev/null || {
    _hf_error "Selecting a repository type interactively requires fzf."
    return 1
  }

  local -a choices=("Model"$'\t'"model" "Dataset"$'\t'"dataset")
  local -i fzf_rc=0
  _hf_fzf_capture \
    --height=20% \
    --delimiter=$'\t' \
    --with-nth=1 \
    --prompt="$prompt_label > " \
    --header='Up/Down choose | Enter select | Esc cancel' \
    < <(printf "%s\n" "${choices[@]}") || fzf_rc=$?
  local selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _hf_fzf_rc_is_cancel "$fzf_rc" && return 130
    return 1
  fi
  _hf_array_contains_literal "$selected" "${choices[@]}" || return 1
  REPLY="${selected#*$'\t'}"
}

_hf_validate_repo_type() {
  [[ "${1:-}" == "model" || "${1:-}" == "dataset" ]]
}

_hf_validate_repo_id() {
  local repo_id="${1:-}"
  (( ${#repo_id} >= 1 && ${#repo_id} <= 193 )) || return 1
  [[ "$repo_id" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}(/[A-Za-z0-9][A-Za-z0-9._-]{0,95})?$' ]]
}

_hf_validate_query() {
  local query="${1:-}"
  (( ${#query} >= 1 && ${#query} <= 256 )) || return 1
  [[ "$query" != *[[:cntrl:]]* ]]
}

_hf_validate_limit() {
  local limit="${1:-}"
  [[ "$limit" =~ '^[1-9][0-9]{0,2}$' ]] || return 1
  local -i decimal_limit=$(( 10#$limit ))
  (( decimal_limit >= 1 && decimal_limit <= 100 ))
}

_hf_validate_uint() {
  local value="${1:-}"
  local -i maximum_digits="${2:-16}"
  (( maximum_digits >= 1 && maximum_digits <= 19 \
    && ${#value} <= maximum_digits )) || return 1
  [[ "$value" == "0" || "$value" =~ '^[1-9][0-9]*$' ]]
}

_hf_validate_filename() {
  local filename="${1:-}"
  (( ${#filename} >= 1 && ${#filename} <= 1024 )) || return 1
  [[ "$filename" != /* && "$filename" != *[[:cntrl:]]* ]] || return 1
  local component=""
  for component in "${(@s:/:)filename}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || return 1
  done
}

_hf_run_probe() {
  local -i seconds="${1:-15}"
  shift

  if command -v timeout &>/dev/null; then
    command timeout -k 2s "${seconds}s" "$@"
  elif command -v gtimeout &>/dev/null; then
    command gtimeout -k 2s "${seconds}s" "$@"
  else
    _hf_error "A bounded timeout command is required for Hub metadata probes."
    return 1
  fi
}

# Sets reply to an isolated Python command with an already-installed,
# API-compatible huggingface_hub module. No package is installed here.
_hf_backend_command() {
  reply=()

  local -a candidates=()
  if [[ -n "${HF_PYTHON:-}" ]]; then
    candidates=("$HF_PYTHON")
  else
    candidates=(python3 python)
  fi

  local candidate resolved version=""
  local -i candidate_rc=0
  for candidate in "${candidates[@]}"; do
    resolved=$(command -v "$candidate" 2>/dev/null) || continue
    [[ -n "$resolved" && -x "$resolved" ]] || continue
    version=$(_hf_run_probe 15 "$resolved" -I -c '
import re
import sys
import huggingface_hub
version = getattr(huggingface_hub, "__version__", "")
match = re.match(r"^([0-9]+)[.]([0-9]+)(?:[.]([0-9]+))?", version)
if not match:
    sys.exit(2)
major, minor = int(match.group(1)), int(match.group(2))
if not ((major == 0 and minor >= 23) or major == 1):
    sys.exit(3)
print(version)
' 2>/dev/null) || candidate_rc=$?
    (( candidate_rc != 130 && candidate_rc != 143 )) || return $candidate_rc
    if (( candidate_rc == 0 )) \
      && [[ "$version" =~ '^[0-9]+[.][0-9]+([.][0-9]+)?' ]]; then
      reply=("$resolved" -I)
      return 0
    fi
    candidate_rc=0
  done

  _hf_error "No supported installed huggingface_hub Python backend was found."
  _hf_dim "Install huggingface_hub 0.23+ and below 2.0, or set HF_PYTHON."
  _hf_dim "ZDX does not download or execute a Python package implicitly."
  return 1
}

typeset -g _HF_COMMON_SOURCED=1
