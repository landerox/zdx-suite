#!/usr/bin/env zsh
# =============================================================================
# CI Common: validation, GitHub context, UI, and foreground selection
# =============================================================================
#
# Loaded by ci-menu.zsh before every module under functions/ci/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_CI_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gA _CI_REPO=()

_ci_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_ci_header() {
  if _ci_color_enabled; then
    printf "\n\033[1;35m════ %s ════\033[0m\n\n" "${(V)1}" >&2
  else
    printf "\n════ %s ════\n\n" "${(V)1}" >&2
  fi
}

_ci_success() {
  if _ci_color_enabled; then
    printf "\033[1;32m✔ %s\033[0m\n" "${(V)1}" >&2
  else
    printf "✔ %s\n" "${(V)1}" >&2
  fi
}

_ci_warn() {
  if _ci_color_enabled; then
    printf "\033[1;33m⚠ %s\033[0m\n" "${(V)1}" >&2
  else
    printf "⚠ %s\n" "${(V)1}" >&2
  fi
}

_ci_info() {
  if _ci_color_enabled; then
    printf "\033[0;34m➜ %s\033[0m\n" "${(V)1}" >&2
  else
    printf "➜ %s\n" "${(V)1}" >&2
  fi
}

_ci_error() {
  if _ci_color_enabled; then
    printf "\033[1;31m✘ %s\033[0m\n" "${(V)1}" >&2
  else
    printf "✘ %s\n" "${(V)1}" >&2
  fi
}

_ci_dim() {
  if _ci_color_enabled; then
    printf "\033[0;90m  %s\033[0m\n" "${(V)1}" >&2
  else
    printf "  %s\n" "${(V)1}" >&2
  fi
}

# stdout: a terminal-safe visible representation of arbitrary data.
_ci_display_escape() {
  print -r -- "${(V)1}"
}

_ci_visible_value_safe() {
  local value="${1:-}"
  local -i maximum_length="${2:-4096}"
  (( maximum_length >= 1 && maximum_length <= 65536 )) || return 1
  (( ${#value} <= maximum_length )) \
    && [[ "$value" != *[[:cntrl:]]* ]]
}

_ci_validate_uint() {
  local value="${1:-}"
  local -i maximum_digits="${2:-20}"
  (( maximum_digits >= 1 && maximum_digits <= 20 \
    && ${#value} <= maximum_digits )) || return 1
  [[ "$value" == "0" || "$value" =~ '^[1-9][0-9]*$' ]]
}

_ci_validate_limit() {
  local value="${1:-}"
  _ci_validate_uint "$value" 3 || return 1
  local -i decimal_value=$(( 10#$value ))
  (( decimal_value >= 1 && decimal_value <= 100 ))
}

_ci_validate_repo_name() {
  local repo_name="${1:-}"
  (( ${#repo_name} >= 3 && ${#repo_name} <= 201 )) \
    && [[ "$repo_name" =~ \
      '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || return 1
  local owner_name="${repo_name%%/*}"
  local repository_name="${repo_name#*/}"
  [[ "$owner_name" != "." && "$owner_name" != ".." \
    && "$repository_name" != "." && "$repository_name" != ".." ]]
}

_ci_validate_host() {
  local host_name="${1:-}"
  (( ${#host_name} >= 1 && ${#host_name} <= 253 )) \
    && [[ "$host_name" =~ \
      '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' ]]
}

_ci_validate_ref() {
  local ref_name="${1:-}"
  (( ${#ref_name} >= 1 && ${#ref_name} <= 255 )) \
    && [[ "$ref_name" =~ \
      '^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$' \
      && "$ref_name" != *'..'* ]]
}

_ci_validate_workflow_target() {
  local workflow_target="${1:-}"
  if _ci_validate_api_id "$workflow_target"; then
    return 0
  fi
  (( ${#workflow_target} >= 1 && ${#workflow_target} <= 256 )) \
    && [[ "$workflow_target" != -* \
      && "$workflow_target" != /* \
      && "$workflow_target" != *[[:cntrl:]]* \
      && "$workflow_target" != *'..'* \
      && "$workflow_target" =~ \
        '^[.]github/workflows/[^/[:cntrl:]]+[.](yml|yaml)$' ]]
}

_ci_validate_api_id() {
  local value="${1:-}"
  _ci_validate_uint "$value" 20 && [[ "$value" != "0" ]]
}

_ci_menu_section() {
  local title="$1"
  local description="${2:-}"

  if [[ "$title" == *'|'* || "$description" == *'|'* ]] \
    || ! _ci_visible_value_safe "$title" 256 \
    || ! _ci_visible_value_safe "$description" 1024; then
    _ci_error "Invalid CI menu section fields."
    return 2
  fi

  printf "── %s ──|:|%s\n" "$title" "$description"
}

_ci_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"

  if [[ "$label" == *'|'* || "$command_name" == *'|'* \
    || "$description" == *'|'* ]] \
    || ! _ci_visible_value_safe "$label" 256 \
    || ! _ci_visible_value_safe "$command_name" 128 \
    || ! _ci_visible_value_safe "$description" 1024; then
    _ci_error "Invalid CI menu entry fields."
    return 2
  fi
  [[ "$command_name" == ":" \
    || "$command_name" =~ '^[a-z][a-z0-9-]*$' ]] || {
    _ci_error "Invalid CI command token."
    return 2
  }

  printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
}

_ci_fzf() {
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

_ci_system_root_uid() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_ci_validate_ancestor_chain() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local child_path="${1:-}"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _ci_system_root_uid || return 1
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

_ci_validate_temp_parent() {
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

  _ci_system_root_uid || return 1
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
  _ci_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

# Runs fzf synchronously and captures its bounded result in an invocation-owned
# file. REPLY contains the complete selected record or records.
_ci_fzf_capture() {
  emulate -L zsh
  REPLY=""

  zmodload zsh/stat zsh/system 2>/dev/null || {
    _ci_error "Zsh file-descriptor support is required for CI menus."
    return 125
  }
  _ci_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _ci_error "Refusing an unsafe temporary root for the CI menu."
    return 125
  }
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-ci-fzf.XXXXXX" 2>/dev/null) || {
    _ci_error "Could not create a private CI menu directory."
    return 125
  }

  local -A directory_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || "${capture_dir:h}" != "$temp_root" \
    || "${capture_dir:t}" != zdx-ci-fzf.* \
    || ! -d "$capture_dir" || -L "$capture_dir" ]] \
    || ! zstat -LH directory_state -- "$capture_dir" 2>/dev/null \
    || (( directory_state[uid] != EUID \
      || (directory_state[mode] & 8#77) != 0 )); then
    _ci_error "Refusing an unsafe CI menu directory."
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
      _ci_error "Could not create a private CI menu result."
    elif [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$capture_dir" \
      || "${capture_file:t}" != .result.* \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 )); then
      _ci_error "Refusing an unsafe CI menu result."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$capture_file" 2>/dev/null; then
        _ci_error "Could not open the CI menu result safely."
      else
        _ci_fzf "$@" 1>&$(( write_fd ))
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
          _ci_error "The CI menu result changed or is oversized."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _ci_error "Could not read the CI menu result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _ci_error "The cancelled CI picker returned unexpected data."
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

_ci_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

_ci_confirm_outcome() {
  emulate -L zsh
  local prompt="${1:-Proceed?}"
  REPLY=""

  if [[ ! -t 0 || ! -t 2 ]]; then
    REPLY="unavailable"
    return 0
  fi

  if command -v fzf &>/dev/null; then
    local -a choices=("No" "Yes")
    local -i fzf_rc=0
    _ci_fzf_capture \
      --height=20% \
      --prompt="$(_ci_display_escape "$prompt") > " \
      --header='Up/Down choose | Enter confirm | Esc cancel' \
      --preview='' \
      --preview-window=hidden \
      < <(printf "%s\n" "${choices[@]}") || fzf_rc=$?
    local selected="$REPLY"
    if (( fzf_rc != 0 )); then
      if _ci_fzf_rc_is_cancel "$fzf_rc"; then
        REPLY="cancelled"
        return 0
      fi
      REPLY="error"
      return 1
    fi
    (( ${choices[(Ie)$selected]} > 0 )) || {
      REPLY="error"
      return 1
    }
    [[ "$selected" == "Yes" ]] \
      && REPLY="confirmed" \
      || REPLY="cancelled"
    return 0
  fi

  printf "? %s [y/N]: " "$(_ci_display_escape "$prompt")" >&2
  local answer=""
  IFS= read -r answer || {
    REPLY="error"
    return 1
  }
  [[ "$answer" == [Yy] ]] \
    && REPLY="confirmed" \
    || REPLY="cancelled"
}

_ci_authorize() {
  emulate -L zsh
  local -i assume_yes="${1:-0}"
  local prompt="${2:-Proceed?}"
  REPLY="error"

  if (( assume_yes )); then
    REPLY="authorized"
    return 0
  fi
  _ci_confirm_outcome "$prompt" || return 1
  case "$REPLY" in
    confirmed)
      REPLY="authorized"
      return 0
      ;;
    cancelled)
      _ci_info "Cancelled. No remote state was changed."
      return 3
      ;;
    unavailable)
      _ci_error \
        "Interactive confirmation requires a terminal; pass --yes after reviewing the plan."
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

_ci_timed() {
  local label="$1"
  shift
  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

_ci_require_fzf() {
  command -v fzf &>/dev/null || {
    _ci_error "Interactive CI selection requires fzf."
    _ci_dim "Use a complete direct command or install fzf."
    return 1
  }
}

_ci_require_git() {
  command -v git &>/dev/null || {
    _ci_error "Git is required for CI repository context."
    return 1
  }
}

_ci_require_repo() {
  _ci_require_git || return 1
  local inside_worktree=""
  inside_worktree=$(command git rev-parse \
    --is-inside-work-tree 2>/dev/null) || inside_worktree=""
  [[ "$inside_worktree" == "true" ]] || {
    _ci_error "Not inside a Git worktree."
    return 1
  }
}

_ci_require_gh() {
  command -v gh &>/dev/null || {
    _ci_error "GitHub CLI (gh) is required for this command."
    _ci_dim "Install gh through your platform package manager, then authenticate it."
    return 1
  }
}

_ci_require_python() {
  command -v python3 &>/dev/null || {
    _ci_error "Python 3 is required to validate bounded GitHub responses."
    return 1
  }
}

_ci_run_probe() {
  local -i seconds="${1:-20}"
  shift

  if command -v timeout &>/dev/null; then
    command timeout -k 2s "${seconds}s" "$@"
  elif command -v gtimeout &>/dev/null; then
    command gtimeout -k 2s "${seconds}s" "$@"
  else
    _ci_error "timeout or gtimeout is required for bounded GitHub probes."
    return 1
  fi
}

# Captures a bounded, read-only command response. Mutating transactions never
# use this helper because they must run to their reported result.
_ci_capture_probe() {
  local -i maximum_bytes="${1:-2097152}"
  shift
  REPLY=""
  (( maximum_bytes >= 1 && maximum_bytes <= 8388608 )) || return 2
  command -v head &>/dev/null || {
    _ci_error "head is required for bounded GitHub response capture."
    return 1
  }

  # Zsh counts characters under a multibyte locale. This scope makes the
  # response ceiling a byte ceiling without changing the caller's locale.
  local LC_ALL=C
  local output=""
  local -i probe_rc=0
  output=$(
    setopt LOCAL_OPTIONS PIPE_FAIL
    _ci_run_probe 20 "$@" 2>/dev/null \
      | command head -c "$(( maximum_bytes + 1 ))"
    local -i bounded_rc=$?
    # Preserve trailing response newlines across command substitution so they
    # still count toward the byte ceiling.
    print -nr -- $'\x1e'
    return $bounded_rc
  ) || probe_rc=$?
  [[ "$output" == *$'\x1e' ]] || {
    _ci_error "Could not delimit the bounded GitHub response."
    return 1
  }
  output="${output%$'\x1e'}"
  (( ${#output} <= maximum_bytes )) || {
    _ci_error "GitHub returned an oversized response."
    return 1
  }
  (( probe_rc == 0 )) || return $probe_rc
  # Match ordinary command-substitution semantics for downstream parsers only
  # after the raw response, including trailing newlines, passed the byte cap.
  local trailing_newlines="${output##*[!$'\n']}"
  output="${output%$trailing_newlines}"
  REPLY="$output"
}

_ci_repo_context() {
  _CI_REPO=()
  _ci_require_repo || return 1
  _ci_require_gh || return 1

  _ci_capture_probe 8192 gh repo view \
    --json id,nameWithOwner,url \
    --template '{{.id}}{{"\t"}}{{.nameWithOwner}}{{"\t"}}{{.url}}' || {
    local -i repo_rc=$?
    _ci_error "Unable to resolve the GitHub repository."
    (( repo_rc == 124 || repo_rc == 130 || repo_rc == 143 )) \
      && return $repo_rc
    return 1
  }
  local repo_output="$REPLY"
  local repo_id="${repo_output%%$'\t'*}"
  local remainder="${repo_output#*$'\t'}"
  local repo_name="${remainder%%$'\t'*}"
  local repo_url="${remainder#*$'\t'}"
  local url_remainder="${repo_url#https://}"
  local host_name="${url_remainder%%/*}"
  local url_repo_name="${url_remainder#*/}"

  [[ "$repo_output" == *$'\t'*$'\t'* \
    && "$repo_output" != *$'\n'* \
    && ${#repo_id} -ge 1 && ${#repo_id} -le 128 \
    && "$repo_id" != *[[:cntrl:]]* \
    && "$repo_url" == https://*/*/* \
    && "$url_repo_name" == "$repo_name" ]] \
    && _ci_validate_repo_name "$repo_name" \
    && _ci_validate_host "$host_name" \
    && _ci_visible_value_safe "$repo_url" 2048 || {
    _ci_error "GitHub returned an invalid repository identity."
    return 1
  }

  _ci_capture_probe 4096 gh auth status \
    --active --hostname "$host_name" || {
    local -i auth_rc=$?
    _ci_error "GitHub CLI is not authenticated for $(_ci_display_escape "$host_name")."
    (( auth_rc == 124 || auth_rc == 130 || auth_rc == 143 )) \
      && return $auth_rc
    return 1
  }

  local git_root=""
  git_root=$(command git rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ "$git_root" == /* && "$git_root" == "${git_root:A}" ]] || {
    _ci_error "Unable to establish a canonical Git repository root."
    return 1
  }

  _CI_REPO=(
    id "$repo_id"
    name "$repo_name"
    host "$host_name"
    target "$host_name/$repo_name"
    root "$git_root"
  )
}

_ci_require_same_repo() {
  local current_root=""
  current_root=$(command git rev-parse --show-toplevel 2>/dev/null) || {
    _ci_error "Unable to revalidate the local Git repository."
    return 1
  }
  [[ "$current_root" == "${_CI_REPO[root]}" ]] || {
    _ci_error "The local repository changed after review; retry."
    return 1
  }

  _ci_capture_probe 4096 gh repo view \
    --repo "${_CI_REPO[target]}" \
    --json id --template '{{.id}}' || {
    local -i repo_rc=$?
    _ci_error "Unable to revalidate the GitHub repository."
    (( repo_rc == 130 || repo_rc == 143 )) && return $repo_rc
    return 1
  }
  [[ "$REPLY" == "${_CI_REPO[id]}" ]] || {
    _ci_error "The GitHub repository identity changed after review; retry."
    return 1
  }
}

_ci_api_probe() {
  local endpoint="$1"
  local -i maximum_bytes="${2:-2097152}"
  _ci_capture_probe "$maximum_bytes" gh api \
    --hostname "${_CI_REPO[host]}" "$endpoint"
}

_ci_api_mutate() {
  local method="$1"
  local endpoint="$2"
  shift 2
  command gh api --method "$method" \
    --hostname "${_CI_REPO[host]}" "$endpoint" "$@"
}

_ci_select_records() {
  emulate -L zsh
  local prompt_label="$1"
  local header_text="$2"
  shift 2
  local -a records=("$@")
  reply=()
  (( ${#records[@]} > 0 )) || return 0
  _ci_require_fzf || return 1

  local -i fzf_rc=0
  _ci_fzf_capture \
    --multi \
    --delimiter=$'\t' \
    --with-nth='1..-2' \
    --bind='ctrl-a:select-all,ctrl-d:deselect-all' \
    --prompt="$prompt_label > " \
    --header="$header_text" \
    --preview='' \
    --preview-window=hidden \
    < <(printf "%s\n" "${records[@]}") || fzf_rc=$?
  local selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _ci_fzf_rc_is_cancel "$fzf_rc" && return 3
    _ci_error "Unable to open the CI picker (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 3

  local -a selected_records=("${(@f)selected}")
  local -a seen_records=()
  local selected_record=""
  for selected_record in "${selected_records[@]}"; do
    (( ${records[(Ie)$selected_record]} > 0 )) || {
      _ci_error "A selected CI record was not in the reviewed snapshot."
      return 1
    }
    (( ${seen_records[(Ie)$selected_record]} == 0 )) || {
      _ci_error "The CI picker returned a duplicate record."
      return 1
    }
    seen_records+=("$selected_record")
  done
  reply=("${selected_records[@]}")
}

_ci_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    ci-status)              ci-status "$@" ;;
    ci-run)                 ci-run "$@" ;;
    ci-clean-actions)       ci-clean-actions "$@" ;;
    ci-clean-deployments)   ci-clean-deployments "$@" ;;
    ci-clean-releases)      ci-clean-releases "$@" ;;
    ci-clean-notifications) ci-clean-notifications "$@" ;;
    ci-clean-tags)          ci-clean-tags "$@" ;;
    ci-clean-issues)        ci-clean-issues "$@" ;;
    :)                      return 0 ;;
    *)
      _ci_error "Unknown command: $(_ci_display_escape "$command_name")"
      return 2
      ;;
  esac
}

typeset -g _CI_COMMON_SOURCED=1
