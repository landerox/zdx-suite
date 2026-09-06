#!/usr/bin/env zsh
# =============================================================================
# Git Common: shared UI, repository context, safety, and routing helpers
# =============================================================================
#
# Loaded by git-menu.zsh before every module under functions/git/.
# Private Git helpers plus temporary `_tk_*` Workspace compatibility adapters.
#

if [[ -n "${_GIT_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g WS_BASE_DIR="${WS_BASE_DIR-$HOME/workspaces}"
typeset -gA _GIT_CONTEXT=()
typeset -gA _GIT_AUTH=()

# --- UI primitives -----------------------------------------------------------

_git_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

_git_header() {
  if _git_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}

_git_success() {
  if _git_color_enabled; then
    printf '\033[1;32m✔ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✔ %s\n' "${(V)1}" >&2
  fi
}

_git_warn() {
  if _git_color_enabled; then
    printf '\033[1;33m⚠ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⚠ %s\n' "${(V)1}" >&2
  fi
}

_git_info() {
  if _git_color_enabled; then
    printf '\033[0;36m➜ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '➜ %s\n' "${(V)1}" >&2
  fi
}

_git_error() {
  if _git_color_enabled; then
    printf '\033[1;31m✘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✘ %s\n' "${(V)1}" >&2
  fi
}

_git_dim() {
  if _git_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
}

_git_label() {
  if _git_color_enabled; then
    printf '\033[1;37m  %-16s\033[0m %s\n' \
      "${(V)1}" "${(V)2}" >&2
  else
    printf '  %-16s %s\n' "${(V)1}" "${(V)2}" >&2
  fi
}

_git_blank() {
  print -u2 -r -- ""
}

_git_display_escape() {
  print -r -- "${(V)1}"
}

# Command-menu records use `|`; external values are display-only and must not
# be able to create fields or physical records.
_git_record_escape() {
  local value="${(V)1}"
  value="${value//|/\\x7c}"
  print -r -- "$value"
}

_git_redact_remote_url() {
  local remote_url="${1:-}"
  local suffix=""
  if [[ "$remote_url" == *[\?\#]* ]]; then
    suffix=" (query or fragment redacted)"
    remote_url="${remote_url%%[\?\#]*}"
  fi
  if [[ "$remote_url" == *://*'@'* ]]; then
    local scheme="${remote_url%%://*}"
    local remainder="${remote_url#*://}"
    remainder="${remainder##*@}"
    print -r -- "${scheme}://***@${remainder}${suffix}"
  elif [[ "$remote_url" == *@*:* ]]; then
    print -r -- "***@${remote_url##*@}${suffix}"
  else
    print -r -- "${remote_url}${suffix}"
  fi
}

# --- Runtime integration -----------------------------------------------------

_git_timed() {
  local label="$1"
  shift
  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

# stdin is Git data. Use a pager only for a terminal destination.
_git_page() {
  if [[ -t 1 ]] && command -v less &>/dev/null; then
    LESS="${LESS:-FRX}" command less -R
  else
    command cat
  fi
}

_git_fzf() {
  local -a options=(
    --height=70%
    --layout=reverse
    --border=rounded
    --pointer='▶'
  )

  options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')

  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && options+=("$theme_option")
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
    SHELL=/bin/sh command fzf "${options[@]}" "$@" "${terminal_options[@]}"
}

_git_temp_parent_safe() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local temp_parent="${1:-}"
  REPLY=""

  while [[ "$temp_parent" != "/" && "$temp_parent" == */ ]]; do
    temp_parent="${temp_parent%/}"
  done
  [[ -n "$temp_parent" && "$temp_parent" == /* \
    && "$temp_parent" == "${temp_parent:a}" \
    && "$temp_parent" == "${temp_parent:A}" \
    && -d "$temp_parent" && ! -L "$temp_parent" ]] || return 1

  local -A root_state=() parent_state=()
  zstat -LH root_state -- / 2>/dev/null \
    && zstat -LH parent_state -- "$temp_parent" 2>/dev/null || return 1
  if (( parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )); then
    :
  elif (( parent_state[uid] == root_state[uid] \
    && (parent_state[mode] & 8#1000) != 0 \
    && (parent_state[mode] & 8#2) != 0 )); then
    :
  else
    return 1
  fi
  REPLY="$temp_parent"
}

# Run fzf synchronously in the terminal foreground and capture only its
# selection stdout in one private, bounded, invocation-owned result file.
_git_fzf_capture() {
  emulate -L zsh
  REPLY=""
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _git_error "Zsh file-descriptor support is required for Git pickers."
    return 125
  }
  _git_temp_parent_safe "${TMPDIR:-/tmp}" || {
    _git_error "Refusing an unsafe temporary root for Git pickers."
    return 125
  }
  local temp_parent="$REPLY"
  REPLY=""

  local picker_result_file=""
  picker_result_file=$(umask 077; command mktemp \
    "${temp_parent%/}/zdx-git-fzf.XXXXXX" 2>/dev/null) || {
    _git_error "Could not create a private Git picker result."
    return 125
  }

  local selection="" file_identity=""
  local -i write_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0 read_rc=0
  local -A file_state=() current_file_state=()

  {
    if [[ "$picker_result_file" != "${picker_result_file:a}" \
      || "$picker_result_file" != "${picker_result_file:A}" \
      || "${picker_result_file:h}" != "$temp_parent" \
      || "${picker_result_file:t}" != zdx-git-fzf.* \
      || ! -f "$picker_result_file" || -L "$picker_result_file" ]] \
      || ! zstat -LH file_state -- "$picker_result_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 \
        || (file_state[mode] & 8#170000) != 8#100000 \
        || file_state[size] != 0 )); then
      _git_error "Refusing an unsafe Git picker result."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:"\
"${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$picker_result_file" 2>/dev/null; then
        _git_error "Could not open the Git picker result safely."
      else
        _git_fzf "$@" 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_file_state -- "$picker_result_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:"\
"${current_file_state[inode]}:${current_file_state[mode]}:"\
"${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > 65536 )); then
          _git_error "The Git picker result changed or exceeded its limit."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$picker_result_file" 2>/dev/null; then
          _git_error "Could not read the Git picker result safely."
        else
          selection=$(<&$(( read_fd ))) || read_rc=$?
          exec {read_fd}>&-
          read_fd=-1
          if (( read_rc != 0 )); then
            _git_error "Could not read the Git picker result."
            selection=""
          elif (( fzf_rc != 0 && current_file_state[size] > 0 )); then
            _git_error "A failed Git picker returned unexpected data."
            selection=""
          else
            operation_rc=$fzf_rc
          fi
        fi
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    current_file_state=()
    if [[ -n "$file_identity" \
      && -f "$picker_result_file" && ! -L "$picker_result_file" \
      && "${picker_result_file:h}" == "$temp_parent" ]] \
      && zstat -LH current_file_state -- "$picker_result_file" 2>/dev/null \
      && [[ "${current_file_state[device]}:"\
"${current_file_state[inode]}:${current_file_state[mode]}:"\
"${current_file_state[uid]}:${current_file_state[nlink]}" \
        == "$file_identity" ]]; then
      command rm -f -- "$picker_result_file" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_git_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

# --- Prompts and authorization ----------------------------------------------

_git_confirm_outcome() {
  emulate -L zsh

  local prompt="${1:-Proceed?}"
  REPLY=""
  if [[ ! -t 0 || ! -t 2 ]]; then
    REPLY="unavailable"
    return 0
  fi

  if command -v fzf &>/dev/null; then
    local selected=""
    local -i fzf_rc=0
    selected=$(printf 'No\nYes\n' | _git_fzf \
      --height=20% \
      --preview='' \
      --preview-window=hidden \
      --header='Up/Down navigate | Enter confirm | Esc cancel' \
      --prompt="${prompt} > ") || fzf_rc=$?
    if (( fzf_rc == 0 )); then
      [[ "$selected" == "Yes" ]] \
        && REPLY="confirmed" \
        || REPLY="cancelled"
      return 0
    fi
    if _git_fzf_rc_is_cancel "$fzf_rc"; then
      REPLY="cancelled"
      return 0
    fi
    _git_error "fzf failed while requesting confirmation (exit $fzf_rc)."
    REPLY="error"
    return 1
  fi

  local answer=""
  if _git_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi
  IFS= read -r answer || {
    _git_error "Unable to read confirmation."
    REPLY="error"
    return 1
  }
  [[ "$answer" == [Yy] ]] \
    && REPLY="confirmed" \
    || REPLY="cancelled"
  return 0
}

_git_confirm() {
  local REPLY=""
  _git_confirm_outcome "${1:-Proceed?}" || return 1
  [[ "$REPLY" == "confirmed" ]]
}

_git_authorize() {
  emulate -L zsh

  local -i assume_yes="${1:-0}"
  local prompt="${2:-Proceed?}"
  REPLY="error"
  if (( assume_yes )); then
    REPLY="authorized"
    return 0
  fi

  _git_confirm_outcome "$prompt" || return 1
  case "$REPLY" in
    confirmed)
      REPLY="authorized"
      return 0
      ;;
    cancelled)
      _git_info "Cancelled. No changes were made."
      return 3
      ;;
    unavailable)
      _git_error \
        "Interactive confirmation requires a terminal; pass --yes after reviewing the plan."
      REPLY="error"
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

_git_confirm_count() {
  local count="${1:-0}"
  local target="${2:-item(s)}"
  _git_confirm "Apply this operation to $count $target?"
}

_git_require_interactive() {
  [[ -t 0 && -t 2 ]] || {
    _git_error "This mode requires an interactive terminal."
    return 1
  }
  _git_check_cmd fzf || {
    _git_error "fzf is required for this interactive workflow."
    return 1
  }
}

# --- Dependencies ------------------------------------------------------------

_git_check_cmd() {
  command -v "$1" &>/dev/null
}

_git_check_deps() {
  local -a missing=()
  local dependency
  for dependency in "$@"; do
    _git_check_cmd "$dependency" || missing+=("$dependency")
  done
  if (( ${#missing[@]} > 0 )); then
    _git_error "Missing dependencies: ${(j:, :)missing}"
    return 1
  fi
  return 0
}

_git_check_gh() {
  _git_check_cmd gh || {
    _git_error "GitHub CLI (gh) is required."
    _git_info "Install gh with your platform package manager."
    return 1
  }
  command gh auth status &>/dev/null || {
    _git_error "GitHub CLI is not authenticated."
    _git_info "Run 'gh auth login' explicitly, then retry."
    return 1
  }
}

_git_cmd_deps() {
  case "${1:-}" in
    git-issues|git-prs|git-pr-create|git-pr-checkout|git-repo-create)
      print -r -- "git,gh"
      ;;
    git-*|clean-branches|clean-remote-merged)
      print -r -- "git"
      ;;
    *)
      print -r -- ""
      ;;
  esac
}

_git_verify_deps() {
  local command_name="${1:-}"
  local dependencies
  dependencies=$(_git_cmd_deps "$command_name") || return 1
  [[ -z "$dependencies" ]] && return 0

  local -a missing=()
  local dependency
  for dependency in ${(s:,:)dependencies}; do
    _git_check_cmd "$dependency" || missing+=("$dependency")
  done
  if (( ${#missing[@]} > 0 )); then
    _git_error \
      "Missing ${(j:, :)missing} required by '$command_name'."
    return 1
  fi
  return 0
}

# --- Repository and ref context ---------------------------------------------

_git_require_git() {
  _git_check_cmd git || {
    _git_error "Git is required for this command."
    _git_info "Install Git with your platform package manager."
    return 1
  }
}

_git_require_repo() {
  _git_require_git || return 1
  local inside_worktree=""
  inside_worktree=$(command git rev-parse \
    --is-inside-work-tree 2>/dev/null) || inside_worktree=""
  [[ "$inside_worktree" == "true" ]] || {
    _git_error "Not inside a Git worktree."
    return 1
  }
}

_git_repo_fingerprint() {
  _git_require_repo >/dev/null 2>&1 || return 1
  local root head branch upstream remote remote_url
  root=$(command git rev-parse --show-toplevel 2>/dev/null) || return 1
  head=$(command git rev-parse --verify HEAD 2>/dev/null) || head="unborn"
  branch=$(command git symbolic-ref --quiet HEAD 2>/dev/null) \
    || branch="detached"
  upstream=$(command git rev-parse --symbolic-full-name \
    '@{upstream}' 2>/dev/null) || upstream=""
  remote=$(_git_current_remote 2>/dev/null) || remote=""
  [[ -n "$remote" ]] \
    && remote_url=$(command git remote get-url --push "$remote" 2>/dev/null) \
    || remote_url=""

  {
    print -rn -- \
      "$root"$'\0'"$head"$'\0'"$branch"$'\0'"$upstream"$'\0'
    print -rn -- "$remote"$'\0'"$remote_url"$'\0'
    command git status --porcelain=v2 -z --untracked-files=all 2>/dev/null
  } | command git hash-object --stdin 2>/dev/null
  local -a pipeline_rc=("${pipestatus[@]}")
  (( pipeline_rc[1] == 0 && pipeline_rc[2] == 0 ))
}

_git_context_refresh() {
  _git_require_repo || return 1

  local root git_dir common_dir head branch upstream remote remote_url
  local fingerprint
  root=$(command git rev-parse --show-toplevel 2>/dev/null) || return 1
  git_dir=$(command git rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common_dir=$(command git rev-parse --git-common-dir 2>/dev/null) || return 1
  [[ "$common_dir" == /* ]] || common_dir="$root/$common_dir"
  common_dir="${common_dir:A}"
  head=$(command git rev-parse --verify HEAD 2>/dev/null) || head="unborn"
  branch=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || branch="detached"
  upstream=$(command git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) \
    || upstream=""
  remote=$(_git_current_remote 2>/dev/null) || remote=""
  [[ -n "$remote" ]] \
    && remote_url=$(command git remote get-url --push "$remote" 2>/dev/null) \
    || remote_url=""
  fingerprint=$(_git_repo_fingerprint) || return 1

  _GIT_CONTEXT=(
    root "$root"
    git_dir "$git_dir"
    common_dir "$common_dir"
    head "$head"
    branch "$branch"
    upstream "$upstream"
    remote "$remote"
    remote_url "$remote_url"
    fingerprint "$fingerprint"
  )
}

_git_context_matches() {
  local expected_root="${1:-}"
  local expected_head="${2:-}"
  local expected_fingerprint="${3:-}"
  _git_context_refresh || return 1
  [[ "${_GIT_CONTEXT[root]}" == "$expected_root" \
    && "${_GIT_CONTEXT[head]}" == "$expected_head" \
    && "${_GIT_CONTEXT[fingerprint]}" == "$expected_fingerprint" ]]
}

_git_require_same_context() {
  _git_context_matches "$@" && return 0
  _git_error \
    "Repository state changed after selection; review the plan and retry."
  return 1
}

_git_current_remote() {
  local branch remote
  branch=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || return 1
  remote=$(command git config --get \
    "branch.${branch}.pushRemote" 2>/dev/null)
  if [[ -n "$remote" && "$remote" != "." ]]; then
    print -r -- "$remote"
    return 0
  fi
  remote=$(command git config --get remote.pushDefault 2>/dev/null)
  if [[ -n "$remote" && "$remote" != "." ]]; then
    print -r -- "$remote"
    return 0
  fi
  remote=$(command git config --get "branch.${branch}.remote" 2>/dev/null)
  if [[ -n "$remote" && "$remote" != "." ]]; then
    print -r -- "$remote"
    return 0
  fi
  if command git remote get-url origin &>/dev/null; then
    print -r -- "origin"
    return 0
  fi
  local -a remotes=("${(@f)$(command git remote 2>/dev/null)}")
  (( ${#remotes[@]} == 1 )) || return 1
  print -r -- "${remotes[1]}"
}

# Sets REPLY to one exact push destination. Mutating callers must use this URL
# for both remote snapshots and execution, rather than the multi-target alias.
_git_remote_push_url() {
  local remote="$1"
  REPLY=""
  _git_validate_remote_token "$remote" || {
    _git_error "Invalid remote name."
    return 2
  }
  local output=""
  output=$(command git remote get-url --push --all "$remote" 2>/dev/null) || {
    _git_error "Unable to resolve the push URL for '$(_git_display_escape "$remote")'."
    return 1
  }
  local -a urls=()
  [[ -n "$output" ]] && urls=("${(@f)output}")
  if (( ${#urls[@]} != 1 )); then
    _git_error "Remote '$(_git_display_escape "$remote")' must have exactly one push URL."
    return 1
  fi
  [[ -n "${urls[1]}" && "${urls[1]}" != *$'\r'* \
    && "${urls[1]}" != *$'\n'* && "${urls[1]}" != *$'\t'* ]] || {
    _git_error "The configured push URL contains unsupported control characters."
    return 1
  }
  REPLY="${urls[1]}"
  return 0
}

_git_get_default_branch() {
  local remote="${1:-}"
  [[ -n "$remote" ]] || remote=$(_git_current_remote 2>/dev/null)

  local default_branch
  if [[ -n "$remote" ]]; then
    default_branch=$(command git symbolic-ref --quiet --short \
      "refs/remotes/${remote}/HEAD" 2>/dev/null)
    default_branch="${default_branch#${remote}/}"
    if [[ -n "$default_branch" ]]; then
      print -r -- "$default_branch"
      return 0
    fi
  fi

  local candidate
  for candidate in main master; do
    if command git show-ref --verify --quiet "refs/heads/$candidate"; then
      print -r -- "$candidate"
      return 0
    fi
  done
  default_branch=$(command git config --get init.defaultBranch 2>/dev/null)
  if [[ -n "$default_branch" ]]; then
    print -r -- "$default_branch"
    return 0
  fi
  command git symbolic-ref --quiet --short HEAD 2>/dev/null
}

_git_validate_oid() {
  local oid="${1:-}"
  [[ "$oid" =~ '^[0-9a-fA-F]+$' \
    && ( ${#oid} -eq 40 || ${#oid} -eq 64 ) ]]
}

_git_validate_short_oid() {
  local oid="${1:-}"
  [[ "$oid" =~ '^[0-9a-fA-F]+$' \
    && ${#oid} -ge 7 && ${#oid} -le 64 ]]
}

_git_validate_full_ref() {
  local ref="${1:-}"
  [[ -n "$ref" && "$ref" != -* ]] || return 2
  command git check-ref-format "$ref" &>/dev/null
}

_git_validate_branch_name() {
  local branch="${1:-}"
  [[ -n "$branch" && "$branch" != -* ]] || return 2
  command git check-ref-format --branch "$branch" &>/dev/null
}

_git_validate_remote_token() {
  local remote="${1:-}"
  [[ "$remote" =~ '^[A-Za-z0-9][A-Za-z0-9._/-]*$' \
    && "$remote" != "." \
    && "$remote" != */ \
    && "$remote" != *..* \
    && "$remote" != *//* \
    && "$remote" != *'.lock' ]]
}

_git_run_report() {
  local success_message="$1"
  local failure_message="$2"
  shift 2
  "$@" >&2
  local -i command_rc=$?
  if (( command_rc == 0 )); then
    _git_success "$success_message"
  else
    _git_error "$failure_message (exit $command_rc)"
  fi
  return $command_rc
}

# --- Workspace compatibility and safe auth display --------------------------

_git_host_alias() {
  print -r -- "${1:-unknown}-${2:-unknown}"
}

_git_hostname() {
  local platform="${1:-}"
  local workspace_dir="${2:-}"
  local hostname
  if [[ "$platform" == "github" ]]; then
    hostname="github.com"
  elif [[ -f "$workspace_dir/.ws-hostname" \
    && ! -L "$workspace_dir/.ws-hostname" ]]; then
    IFS= read -r hostname < "$workspace_dir/.ws-hostname"
  else
    hostname="gitlab.com"
  fi
  [[ "$hostname" =~ '^[A-Za-z0-9.-]+$' ]] || hostname="unknown"
  print -r -- "$hostname"
}

_git_detect_workspace() {
  local base="${WS_BASE_DIR:A}"
  local cwd="${PWD:A}"
  [[ "$cwd" == "$base"/* ]] || return 1

  local relative="${cwd#$base/}"
  local platform="${relative%%/*}"
  local remainder="${relative#*/}"
  local identity="${remainder%%/*}"
  [[ -n "$platform" && -n "$identity" \
    && -d "$base/$platform/$identity" ]] || return 1
  print -r -- "$platform/$identity"
}

_git_remote_hostname() {
  local remote_url="${1:-}"
  local hostname=""
  if [[ "$remote_url" == *://* ]]; then
    local remainder="${remote_url#*://}"
    remainder="${remainder##*@}"
    hostname="${remainder%%/*}"
    hostname="${hostname%%:*}"
  elif [[ "$remote_url" == *@*:* ]]; then
    hostname="${remote_url#*@}"
    hostname="${hostname%%:*}"
  fi
  [[ "$hostname" =~ '^[A-Za-z0-9.-]+$' ]] || hostname="unknown"
  print -r -- "$hostname"
}

_git_auth_collect() {
  _git_require_repo || return 1

  local root remote remote_url workspace platform identity workspace_dir
  local hostname host_alias ssh_key_path ssh_key_fingerprint
  local git_name git_email gh_state="unavailable"

  root=$(command git rev-parse --show-toplevel 2>/dev/null) || return 1
  remote=$(_git_current_remote 2>/dev/null) || remote=""
  [[ -n "$remote" ]] \
    && remote_url=$(command git remote get-url --push "$remote" 2>/dev/null) \
    || remote_url=""
  workspace=$(_git_detect_workspace 2>/dev/null) || workspace=""
  platform="${workspace%%/*}"
  identity="${workspace#*/}"
  [[ "$workspace" == */* ]] || {
    platform=""
    identity=""
  }

  if [[ -n "$workspace" ]]; then
    workspace_dir="$WS_BASE_DIR/$workspace"
    host_alias=$(_git_host_alias "$platform" "$identity")
    hostname=$(_git_hostname "$platform" "$workspace_dir")
    ssh_key_path="$workspace_dir/.ssh/id_ed25519"
    if [[ -f "${ssh_key_path}.pub" && ! -L "${ssh_key_path}.pub" ]] \
      && _git_check_cmd ssh-keygen; then
      ssh_key_fingerprint=$(command ssh-keygen -lf "${ssh_key_path}.pub" \
        2>/dev/null | command awk 'NR == 1 { print $2 }')
    fi
  else
    workspace_dir=""
    host_alias=""
    ssh_key_path=""
    ssh_key_fingerprint=""
    hostname=$(_git_remote_hostname "$remote_url")
  fi

  git_name=$(command git config --get user.name 2>/dev/null)
  git_email=$(command git config --get user.email 2>/dev/null)
  if _git_check_cmd gh; then
    if [[ "$hostname" != "unknown" ]] \
      && command gh auth status --hostname "$hostname" &>/dev/null; then
      gh_state="authenticated"
    else
      gh_state="not authenticated"
    fi
  fi

  _GIT_AUTH=(
    repo "${root:t}"
    root "$root"
    remote "$remote"
    remote_url "$remote_url"
    workspace "$workspace"
    platform "$platform"
    identity "$identity"
    hostname "$hostname"
    host_alias "$host_alias"
    git_name "$git_name"
    git_email "$git_email"
    ssh_key_path "$ssh_key_path"
    ssh_key_fingerprint "$ssh_key_fingerprint"
    gh_state "$gh_state"
  )
}

_git_auth_usage() {
  print -u2 -r -- "Usage: git-auth"
  print -u2 -r -- "       git-auth --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Show the effective repository identity, redacted remote, workspace SSH routing, and GitHub CLI state."
}

git-auth() {
  emulate -L zsh

  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _git_error "--help accepts no additional arguments."
        return 2
      }
      _git_auth_usage
      return 0
      ;;
    *)
      _git_error "Unknown argument for git-auth: $1"
      return 2
      ;;
  esac

  _git_auth_collect || return 1
  _git_header "Repository Authentication"
  _git_label "Repository:" "${_GIT_AUTH[repo]}"
  _git_label "Remote:" "${_GIT_AUTH[remote]:-(none)}"
  _git_label "URL:" \
    "$(_git_redact_remote_url "${_GIT_AUTH[remote_url]:-(none)}")"
  _git_label "Host:" "${_GIT_AUTH[hostname]}"
  _git_blank
  _git_label "Git name:" "${_GIT_AUTH[git_name]:-(not set)}"
  _git_label "Git email:" "${_GIT_AUTH[git_email]:-(not set)}"
  _git_label "Workspace:" "${_GIT_AUTH[workspace]:-(none)}"
  [[ -n "${_GIT_AUTH[host_alias]}" ]] \
    && _git_label "SSH alias:" "${_GIT_AUTH[host_alias]}"
  if [[ -n "${_GIT_AUTH[ssh_key_fingerprint]}" ]]; then
    _git_label "SSH key:" "${_GIT_AUTH[ssh_key_fingerprint]}"
  elif [[ -n "${_GIT_AUTH[ssh_key_path]}" ]]; then
    _git_label "SSH key:" "(missing)"
  fi
  _git_label "GitHub CLI:" "${_GIT_AUTH[gh_state]}"
  return 0
}

_git_auth_badge() {
  local identity="(not set)"
  if command git config --get user.email &>/dev/null \
    || command git config --get user.name &>/dev/null; then
    identity="configured"
  fi

  local inside_worktree=""
  inside_worktree=$(command git rev-parse \
    --is-inside-work-tree 2>/dev/null) || inside_worktree=""
  if [[ "$inside_worktree" != "true" ]]; then
    print -r -- "Repository: none"
    print -r -- \
      "Identity: $(_git_record_escape "$identity") | Remote: none"
    return 0
  fi

  local root branch remote status_output
  local -i changed_count=0
  root=$(command git rev-parse --show-toplevel 2>/dev/null) || return 1
  branch=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || branch="detached"
  remote=$(_git_current_remote 2>/dev/null) || remote="(none)"
  status_output=$(command git status \
    --porcelain=v1 --untracked-files=all 2>/dev/null) || return 1
  if [[ -n "$status_output" ]]; then
    local -a change_lines=("${(@f)status_output}")
    changed_count=${#change_lines[@]}
  fi
  local repository_line=""
  local identity_line=""
  repository_line="Repository: $(_git_record_escape "${root:t}")"
  repository_line+=" | Branch: $(_git_record_escape "$branch")"
  repository_line+=" | Changes: $changed_count"
  identity_line="Identity: $(_git_record_escape "$identity")"
  identity_line+=" | Remote: $(_git_record_escape "$remote")"
  print -r -- "$repository_line"
  print -r -- "$identity_line"
}

# --- Menu records ------------------------------------------------------------

_git_menu_validate_fields() {
  local value
  for value in "$@"; do
    [[ "$value" != *'|'* \
      && "$value" != *$'\n'* \
      && "$value" != *$'\r'* \
      && "$value" != *$'\0'* ]] || {
      _git_error "Menu fields cannot contain record delimiters or controls."
      return 2
    }
  done
}

_git_menu_section() {
  (( $# >= 1 && $# <= 2 )) || {
    _git_error "A menu section requires a title and optional description."
    return 2
  }
  local title="${1:-}"
  local description="${2:-}"
  [[ -n "$title" ]] || {
    _git_error "A menu section title cannot be empty."
    return 2
  }
  _git_menu_validate_fields "$title" "$description" || return $?
  printf '── %s ──|:|%s\n' "$title" "$description"
}

_git_command_requires_repo() {
  case "${1:-}" in
    git-repo-create|git-identity-switcher)
      return 1
      ;;
    git-*|clean-branches|clean-remote-merged)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_git_menu_entry() {
  (( $# == 3 )) || {
    _git_error "A menu entry requires label, command, and description fields."
    return 2
  }
  local label="${1:-}"
  local command_name="${2:-}"
  local description="${3:-}"
  [[ -n "$label" && -n "$command_name" && -n "$description" ]] || {
    _git_error "Menu entry fields cannot be empty."
    return 2
  }
  [[ "$command_name" =~ '^[a-z][a-z0-9-]*$' ]] || {
    _git_error "Invalid menu command token."
    return 2
  }
  _git_menu_validate_fields "$label" "$command_name" "$description" \
    || return $?

  local dependencies
  dependencies=$(_git_cmd_deps "$command_name") || return 1
  local -a missing=()
  local dependency
  for dependency in ${(s:,:)dependencies}; do
    [[ -n "$dependency" ]] || continue
    _git_check_cmd "$dependency" || missing+=("$dependency")
  done

  local -a availability=()
  (( ${#missing[@]} > 0 )) \
    && availability+=("missing: ${(j:, :)missing}")
  if (( ${_GIT_MENU_CONTEXTUAL_ROWS:-0} )) \
    && (( ! ${_GIT_MENU_HAS_REPO:-0} )) \
    && _git_command_requires_repo "$command_name"; then
    availability+=("unavailable: repository")
  fi

  (( ${#availability[@]} > 0 )) \
    && label+=" (${(j:; :)availability})"
  printf '  %s|%s|%s\n' "$label" "$command_name" "$description"
}

# --- Dispatch ---------------------------------------------------------------

_git_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true
  case "$command_name" in
    git-auth)
      git-auth "$@" ;;
    git-status)
      git-status "$@" ;;
    git-switch)
      git-switch "$@" ;;
    git-branch-create)
      git-branch-create "$@" ;;
    git-branch-rename)
      git-branch-rename "$@" ;;
    git-stage)
      git-stage "$@" ;;
    git-staged)
      git-staged "$@" ;;
    git-unstage)
      git-unstage "$@" ;;
    git-discard)
      git-discard "$@" ;;
    git-restore-from)
      git-restore-from "$@" ;;
    git-commit)
      git-commit "$@" ;;
    git-commit-verify)
      git-commit-verify "$@" ;;
    git-amend)
      git-amend "$@" ;;
    git-undo-commit)
      git-undo-commit "$@" ;;
    git-cherry-pick)
      git-cherry-pick "$@" ;;
    git-merge)
      git-merge "$@" ;;
    git-rebase)
      git-rebase "$@" ;;
    git-diff)
      git-diff "$@" ;;
    git-blame)
      git-blame "$@" ;;
    git-stash)
      git-stash "$@" ;;
    git-push)
      git-push "$@" ;;
    git-pull)
      git-pull "$@" ;;
    git-log-search)
      git-log-search "$@" ;;
    git-reflog)
      git-reflog "$@" ;;
    git-file-history)
      git-file-history "$@" ;;
    clean-branches)
      clean-branches "$@" ;;
    clean-remote-merged)
      clean-remote-merged "$@" ;;
    git-tag-create)
      git-tag-create "$@" ;;
    git-tag-list)
      git-tag-list "$@" ;;
    git-tag-verify)
      git-tag-verify "$@" ;;
    git-tag-push)
      git-tag-push "$@" ;;
    git-tag-delete)
      git-tag-delete "$@" ;;
    git-issues)
      git-issues "$@" ;;
    git-prs)
      git-prs "$@" ;;
    git-pr-create)
      git-pr-create "$@" ;;
    git-pr-checkout)
      git-pr-checkout "$@" ;;
    git-repo-create)
      git-repo-create "$@" ;;
    git-identity-switcher)
      git-identity-switcher "$@" ;;
    git-config-edit)
      git-config-edit "$@" ;;
    :)
      return 0
      ;;
    "")
      _git_error "A Git command is required."
      return 2
      ;;
    *)
      _git_error "Unknown Git command: $command_name"
      return 2
      ;;
  esac
}

# --- Temporary Workspace compatibility adapters -----------------------------

_tk_header()        { _git_header "$@"; }
_tk_success()       { _git_success "$@"; }
_tk_warn()          { _git_warn "$@"; }
_tk_info()          { _git_info "$@"; }
_tk_error()         { _git_error "$@"; }
_tk_dim()           { _git_dim "$@"; }
_tk_label()         { _git_label "$@"; }
_tk_check_deps()    { _git_check_deps "$@"; }
_tk_check_gh()      { _git_check_gh "$@"; }
_tk_require_git_repo() { _git_require_repo "$@"; }
_tk_confirm_count() {
  local count="${1:-0}"
  local target="${2:-item(s)}"
  _tk_confirm "Apply this operation to $count $target?"
}
_tk_get_default_branch() { _git_get_default_branch "$@"; }
_tk_host_alias()    { _git_host_alias "$@"; }
_tk_hostname()      { _git_hostname "$@"; }
_tk_detect_workspace() { _git_detect_workspace "$@"; }
_tk_cmd_deps()      { _git_cmd_deps "$@"; }
_tk_verify_deps()   { _git_verify_deps "$@"; }
_tk_auth_badge()    { _git_auth_badge "$@"; }

if ! typeset -f _tk_check_cmd &>/dev/null; then
  _tk_check_cmd() { _git_check_cmd "$@"; }
fi

if ! typeset -f _tk_fzf &>/dev/null; then
  _tk_fzf() { _git_fzf "$@"; }
fi

# Keep the legacy prompt behavior for the ignored Workspace implementation.
# Git commands exclusively use the fail-closed `_git_confirm`.
_tk_confirm() {
  if [[ -t 0 && -t 2 ]]; then
    _git_confirm "$@"
    return $?
  fi
  local prompt="${1:-Proceed?}"
  local REPLY
  print -u2 -r -- ""
  read -q "REPLY?$prompt [y/N] "
  print -u2 -r -- ""
  [[ "$REPLY" == "y" ]]
}

_tk_diff_viewer() {
  if command -v delta &>/dev/null; then
    print -r -- " | delta --paging=never"
  elif command -v diff-so-fancy &>/dev/null; then
    print -r -- " | diff-so-fancy"
  else
    print -r -- ""
  fi
}

_tk_file_perms() {
  local file="${1:-}"
  if command stat --version &>/dev/null 2>&1; then
    command stat -c '%a' "$file" 2>/dev/null
  else
    command stat -f '%Lp' "$file" 2>/dev/null
  fi
}

_tk_fzf_menu() {
  local prompt="${1:-menu}"
  local header="${2:-}"
  shift 2
  local -a options=("$@")
  local full_header="${header}"$'\n''Up/Down navigate | Enter run | Esc cancel'
  printf '%s\n' "${options[@]}" | _git_fzf \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt="${prompt} > " \
    --header="$full_header" \
    --preview='printf "Command: %s\n\n%s\n" {2} {3}' \
    --preview-window='down:4:wrap'
}

typeset -g _TK_LOADED_COMMON=1
typeset -g _GIT_COMMON_SOURCED=1
