#!/usr/bin/env zsh
# =============================================================================
# Git Common: shared UI, repository context, safety, and routing helpers
# =============================================================================
#
# Loaded by git-menu.zsh before every module under functions/git/.
# Private Git helpers shared by the Git modules.
#

if [[ -n "${_GIT_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# The canonical HOME keeps the default valid when HOME traverses a symlink.
typeset -g WS_BASE_DIR="${WS_BASE_DIR-${HOME:A}/workspaces}"
typeset -gA _GIT_CONTEXT=()
typeset -gA _GIT_AUTH=()

# The oldest supported Git release. Fetch transactions use --atomic,
# --no-write-fetch-head, and --no-auto-maintenance; repository paths use
# rev-parse --path-format; force pushes use --force-if-includes; and identity
# planning uses config --show-scope. Each needs Git 2.31.
typeset -g _GIT_MINIMUM_VERSION="2.31"
# Resolved git executables already proven new enough, mapped to their file
# identity at that time, so a replaced or upgraded binary is checked again.
typeset -gA _GIT_VERIFIED_BINARIES=()

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

# --- Command output services (docs/output-spec.md) ---------------------------
# Thin wrappers over the optional core services. Each keeps a plain fallback so
# the suite still works when it is sourced without the core runtime.

# REPLY: "<count> <noun>". Usage: _git_count_noun <count> <singular> [plural]
_git_count_noun() {
  if (( ${+functions[_zdx_count_noun]} )); then
    _zdx_count_noun "$@"
    return
  fi
  local count="${1:-}" singular="${2:-}" plural="${3:-${2:-}s}"
  REPLY=""
  [[ "$count" == <-> && -n "$singular" ]] || return 2
  if (( count == 1 )); then
    REPLY="1 $singular"
  else
    REPLY="$count $plural"
  fi
}

# Aligned TAB-separated table on stderr.
# Usage: _git_table <header-tsv> [row-tsv...]
_git_table() {
  if (( ${+functions[_zdx_ui_table]} )); then
    _zdx_ui_table "$@" && return 0
  fi
  local table_row=""
  for table_row in "$@"; do
    _git_dim "${table_row//$'\t'/  }"
  done
}

# One target result line, "<glyph> <label> — <outcome>[: <detail>]".
# Usage: _git_outcome_line <label> <outcome> [detail]
_git_outcome_line() {
  local label="${(V)1}" outcome="$2" detail="${(V)${3:-}}" REPLY=""
  if ! (( ${+functions[_zdx_ui_outcome]} )) || ! _zdx_ui_outcome "$outcome"; then
    print -u2 -r -- "$label — $outcome${detail:+: $detail}"
    return 0
  fi
  local text="${REPLY%% *} $label — ${REPLY#* }${detail:+: $detail}"
  if _git_color_enabled && _zdx_ui_outcome_sgr "$outcome"; then
    printf '\033[%sm%s\033[0m\n' "$REPLY" "$text" >&2
  else
    print -u2 -r -- "$text"
  fi
}

# Runs a chatty Git command with its output captured privately and replayed
# only on failure. Usage: _git_run_captured <display> <command...>
_git_run_captured() {
  local display="$1"
  shift
  if (( ${+functions[_zdx_run_captured]} )); then
    _zdx_run_captured "$display" 262144 40 "$@"
    return
  fi
  "$@" </dev/null >&2
}

# Partial-success timing for a batch that ends with mixed results.
_git_mark_partial() {
  (( ${+functions[_zdx_timed_mark_partial]} )) || return 0
  _zdx_timed_mark_partial || true
}

# A command heading through the core service, which also omits or demotes it
# inside an aggregate step. Usage: _git_ui_heading <title>
_git_ui_heading() {
  if (( ${+functions[_zdx_ui_heading]} )); then
    _zdx_ui_heading "$@"
    return
  fi
  _git_header "$1"
}

# One key-value line with the shared 18-column key. Usage: _git_ui_label <key> <value>
_git_ui_label() {
  if (( ${+functions[_zdx_ui_label]} )); then
    _zdx_ui_label "$@"
    return
  fi
  local key="${1%:}"
  [[ -n "$key" ]] || return 2
  printf '  %-18s %s\n' "${(V)key}:" "${(V)${2-}}" >&2
}

# Bounds a read-only probe with the core timeout service; it returns 124 on
# timeout. Sourced without the core runtime, the probe runs unbounded. The
# command must be an executable, not a shell word such as `command`.
# Usage: _git_run_with_timeout <seconds> <command...>
_git_run_with_timeout() {
  if (( ${+functions[_zdx_run_with_timeout]} )); then
    _zdx_run_with_timeout "$@"
    return
  fi
  shift
  "$@"
}

# JSON output is built only with jq, which every --json mode checks after its
# arguments are parsed.
_git_require_jq() {
  _git_check_cmd jq && return 0
  _git_error "jq is required for --json output; install jq or omit --json."
  return 1
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

# Runs a Git command that may sign with GnuPG, such as git tag -s or a commit
# with commit.gpgSign. When GPG_TTY is unset and stdin is a terminal, the
# command gets GPG_TTY set to that terminal so pinentry can prompt there;
# otherwise the environment is unchanged. Usage: _git_run_with_gpg_tty CMD...
_git_run_with_gpg_tty() {
  local terminal_name=""
  if [[ -z "${GPG_TTY:-}" && -t 0 ]]; then
    terminal_name=$(command tty 2>/dev/null) || terminal_name=""
    [[ "$terminal_name" == /dev/?* ]] || terminal_name="${TTY:-}"
    if [[ "$terminal_name" == /dev/?* ]]; then
      GPG_TTY="$terminal_name" "$@"
      return
    fi
  fi
  "$@"
}

_git_fzf() {
  local -a options=(
    --height=70%
    --layout=reverse
    --border=rounded
    --pointer='▶'
  )

  options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow')

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

  # fzf with templates hides the delimiter that trails a single shown field.
  local REPLY=""
  if typeset -f _tk_fzf_nth_template_option &>/dev/null \
    && _tk_fzf_nth_template_option "${options[@]}" "$@"; then
    terminal_options+=("$REPLY")
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh command fzf "${options[@]}" "$@" "${terminal_options[@]}"
}

# REPLY is the canonical directory for an absolute, already-normalized path.
# A symbolic link on the literal path is accepted only as a root-owned system
# alias, such as macOS /var and /tmp, or above the final component when the
# current user owns it inside a directory owned by root or the current user
# that group and other users cannot write. This mirrors the core
# _zdx_resolve_trusted_dir so the suite stays sourceable on its own.
_git_resolve_trusted_dir() {
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

# REPLY is the canonical temporary root; the ownership and sticky checks
# apply to the canonical directory.
_git_temp_parent_safe() {
  emulate -L zsh
  # Only zstat: the plain module would replace the shell's stat command.
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local temp_parent="${1:-}"
  REPLY=""

  _git_resolve_trusted_dir "$temp_parent" || return 1
  temp_parent="$REPLY"
  REPLY=""
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
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
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

# Sets REPLY to the repository root and returns 0 when the current directory
# is inside the work tree but is not its root. Path-oriented commands then run
# themselves again from the root in a subshell, so the caller's directory is
# unchanged. Returns 1 at the root or outside a repository.
# git ls-remote matches patterns against the tail of each ref, so refs such as
# refs/heads/ci/refs/tags/v1 also match refs/tags/*. Accept only refs that match
# from the start: an exact ref, or a literal prefix followed by a trailing *.
_git_ls_remote_ref_matches() {
  local pattern="$1"
  local ref="$2"
  if [[ "$pattern" == *'*' ]]; then
    [[ "$ref" == "${pattern%'*'}"* ]]
  else
    [[ "$ref" == "$pattern" ]]
  fi
}

_git_path_command_needs_root() {
  REPLY=""
  # This runs before argument parsing; the macOS placeholder would open an
  # installation dialog, so leave it to the command's own Git check.
  _git_clt_placeholder "${commands[git]-}" && return 1
  local repo_root=""
  repo_root=$(command git rev-parse --path-format=absolute --show-toplevel \
    2>/dev/null) || return 1
  [[ -n "$repo_root" && -d "$repo_root" \
    && "${PWD:A}" != "${repo_root:A}" ]] || return 1
  REPLY="$repo_root"
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

# Authorizes a reviewed local-change plan. ASSUME_YES=yes (--yes) bypasses
# only the question. REPLY becomes "authorized" or "cancelled", and a declined
# question prints CANCEL_TEXT. Without a terminal or --yes it fails closed.
# Usage: _git_confirm_plan ASSUME_YES PROMPT CANCEL_TEXT
_git_confirm_plan() {
  emulate -L zsh

  local assume_yes="${1:-no}"
  local prompt_text="${2:-Proceed?}"
  local cancel_text="${3:-Cancelled.}"
  REPLY="error"
  if [[ "$assume_yes" == "yes" ]]; then
    REPLY="authorized"
    return 0
  fi

  _git_confirm_outcome "$prompt_text" || {
    REPLY="error"
    return 1
  }
  case "$REPLY" in
    confirmed)
      REPLY="authorized"
      return 0
      ;;
    cancelled)
      _git_info "$cancel_text"
      return 0
      ;;
    unavailable)
      _git_error \
        "Refusing to continue without a terminal; pass --yes after reviewing the plan."
      REPLY="error"
      return 1
      ;;
    *)
      REPLY="error"
      return 1
      ;;
  esac
}

# Reads one line of text from the terminal into REPLY. INITIAL prefills an
# editable value when the Zsh line editor is available in this shell; a
# subshell falls back to a plain prompt. Returns 1 without a terminal.
# Usage: _git_read_line PROMPT [INITIAL]
_git_read_line() {
  emulate -L zsh

  local prompt_text="${1:-}"
  local edited_text="${2:-}"
  REPLY=""
  if [[ ! -t 0 || ! -t 2 ]]; then
    _git_error "Interactive text input requires a terminal."
    return 1
  fi

  if [[ -o zle ]] && (( ZSH_SUBSHELL == 0 )); then
    vared -p "${prompt_text//\%/%%}" edited_text || return 1
    REPLY="$edited_text"
    return 0
  fi

  print -u2 -n -r -- "$prompt_text"
  local answer=""
  IFS= read -r answer || {
    _git_error "Unable to read the answer."
    return 1
  }
  REPLY="$answer"
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

# --- Content pickers ---------------------------------------------------------

# Single-select action dialog over "label<TAB>action<TAB>description" rows.
# REPLY is the fixed action token of the chosen row, or empty after a
# cancellation. The chosen row must be one of the supplied rows.
# Usage: _git_select_action PROMPT CONTEXT ROW...
_git_select_action() {
  emulate -L zsh

  local prompt_text="$1"
  local context_text="$2"
  shift 2
  local -a action_rows=("$@")
  REPLY=""
  (( ${#action_rows[@]} > 0 )) || {
    _git_error "No actions are available."
    return 1
  }

  local action_row=""
  for action_row in "${action_rows[@]}"; do
    local -a action_fields=("${(@ps:\t:)action_row}")
    if (( ${#action_fields[@]} != 3 )) \
      || [[ -z "${action_fields[1]}" || -z "${action_fields[3]}" \
        || "$action_row" == *[$'\n\r']* ]] \
      || [[ ! "${action_fields[2]}" =~ '^[a-z][a-z0-9-]*$' ]]; then
      _git_error "Invalid action picker row."
      return 2
    fi
  done

  local header_text="Type to filter | Enter choose | Esc cancel | Ctrl-/ details"
  [[ -n "$context_text" ]] && header_text="${context_text}"$'\n'"${header_text}"

  local -i fzf_rc=0
  _git_fzf_capture \
    --delimiter=$'\t' \
    --with-nth=1 \
    "--prompt=${prompt_text} > " \
    "--header=${header_text}" \
    --preview='printf "%s\n" {3}' \
    --preview-window='down:3:wrap' \
    --bind='ctrl-/:toggle-preview' \
    < <(print -rl -- "${action_rows[@]}") || fzf_rc=$?
  local selected_row="$REPLY"
  REPLY=""

  if (( fzf_rc != 0 )); then
    _git_fzf_rc_is_cancel "$fzf_rc" && return 0
    _git_error "Unable to open the action picker (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected_row" ]] || return 0
  (( ${action_rows[(Ie)$selected_row]} )) || {
    _git_error "The selected action was not in the picker snapshot."
    return 1
  }
  local -a selected_fields=("${(@ps:\t:)selected_row}")
  REPLY="${selected_fields[2]}"
}

# Opens a foreground record picker. Every row starts with a positive decimal
# identifier and a TAB; the other fields are display text. Sets reply to the
# distinct selected identifiers in ascending order. A cancellation leaves
# reply empty and returns 0; any other picker failure returns 1.
# Usage: _git_select_ids PROMPT HEADER VISIBLE_FIELDS MULTI ROWS_NAME [OPTIONS_NAME]
_git_select_ids() {
  emulate -L zsh

  local prompt_text="$1"
  local header_text="$2"
  local visible_fields="$3"
  local multi_mode="$4"
  local -a picker_rows=("${(@P)5}")
  local -a extra_options=()
  [[ -n "${6:-}" ]] && extra_options=("${(@P)6}")
  reply=()
  (( ${#picker_rows[@]} > 0 )) || return 0

  local -a fzf_options=(
    --height=60%
    --delimiter=$'\t'
    "--with-nth=${visible_fields}"
    "--prompt=${prompt_text} > "
    "--header=${header_text}"
  )
  [[ "$multi_mode" == "yes" ]] && fzf_options+=(--multi)
  fzf_options+=("${extra_options[@]}")

  local REPLY=""
  local -i fzf_code=0
  _git_fzf_capture "${fzf_options[@]}" \
    < <(print -rl -- "${picker_rows[@]}") || fzf_code=$?
  local selected_output="$REPLY"

  if (( fzf_code != 0 )); then
    _git_fzf_rc_is_cancel "$fzf_code" && return 0
    _git_error "fzf failed while selecting Git records (exit $fzf_code)."
    return 1
  fi
  [[ -n "$selected_output" ]] || return 0

  local -a selected_ids=()
  local selected_row=""
  local selected_id=""
  local -i id_number=0
  for selected_row in "${(@f)selected_output}"; do
    selected_id="${selected_row%%$'\t'*}"
    if [[ ${#selected_id} -gt 9 \
      || "$selected_id" != <-> \
      || "$selected_id" == 0* ]]; then
      _git_error "fzf returned an invalid record identifier."
      return 1
    fi
    id_number=$(( 10#$selected_id ))
    if (( id_number < 1 || id_number > ${#picker_rows[@]} )) \
      || [[ "${picker_rows[id_number]}" != "$selected_row" ]]; then
      _git_error "fzf returned a record outside the picker snapshot."
      return 1
    fi
    (( ${selected_ids[(Ie)$id_number]} == 0 )) && selected_ids+=("$id_number")
  done

  reply=("${(@on)selected_ids}")
}

# --- Local change records ----------------------------------------------------

# Sets reply to the NUL-terminated records of one Git command run with
# literal pathspecs. A malformed unterminated record fails closed.
_git_capture_nul() {
  emulate -L zsh
  setopt localoptions no_aliases

  local temp_dir=""
  local records_file=""
  local record=""
  local -i command_code=0
  reply=()

  temp_dir=$(command mktemp -d "${TMPDIR:-/tmp}/zdx-git-records.XXXXXX") || {
    _git_error "Unable to create a private temporary directory."
    return 1
  }
  records_file="$temp_dir/records"

  {
    command git --literal-pathspecs "$@" >| "$records_file"
    command_code=$?

    if (( command_code == 0 )); then
      while IFS= read -r -d '' record; do
        reply+=("$record")
      done < "$records_file"

      if [[ -n "$record" ]]; then
        _git_error "Git returned a malformed unterminated record."
        command_code=1
      fi
    fi
  } always {
    command rm -f -- "$records_file" 2>/dev/null
    command rmdir -- "$temp_dir" 2>/dev/null
  }

  return command_code
}

# Sets reply to flat status/path pairs from git diff --name-status, with
# rename detection disabled so both sides of a rename are listed.
# Usage: _git_name_status_pairs [--cached] [revision] --
_git_name_status_pairs() {
  emulate -L zsh

  _git_capture_nul diff --name-status --no-renames -z "$@" || return 1
  local -a status_records=("${reply[@]}")
  reply=()
  (( ${#status_records[@]} % 2 == 0 )) || {
    _git_error "Git returned malformed name-status records."
    return 1
  }
  local -i record_index=0
  for (( record_index = 1; record_index <= ${#status_records[@]}; record_index += 2 )); do
    [[ "${status_records[record_index]}" == [ACDMTUXB] \
      && -n "${status_records[record_index + 1]}" ]] || {
      _git_error "Git returned an unexpected name-status record."
      return 1
    }
  done
  reply=("${status_records[@]}")
}

# REPLY: a short description of one path's change from its index letter
# (index against HEAD) and worktree letter (worktree against the index).
_git_change_label() {
  local index_letter="${1:-}"
  local worktree_letter="${2:-}"
  local -a change_words=()
  case "$index_letter" in
    A) change_words+=(added) ;;
    M|T) change_words+=(staged) ;;
    D) change_words+=(removed) ;;
    U) change_words+=(conflict) ;;
  esac
  case "$worktree_letter" in
    A) change_words+=(added) ;;
    M|T) change_words+=(modified) ;;
    D) change_words+=(deleted) ;;
    U) [[ "$index_letter" == U ]] || change_words+=(conflict) ;;
  esac
  REPLY="${(j:, :)change_words}"
  [[ -n "$REPLY" ]] || REPLY="changed"
}

# Succeeds when the repository sets core.ignorecase, as Git does on a
# case-insensitive file system such as APFS, NTFS, or a WSL Windows drive.
_git_ignorecase_enabled() {
  [[ "$(command git config --type=bool --get core.ignorecase 2>/dev/null)" == "true" ]]
}

# Sets reply to the candidate paths that equal a target path, contain one, or
# lie inside one; a trailing slash on a candidate names a directory. With
# FOLD_CASE "yes" the paths are compared in lowercase, because a
# case-insensitive file system stores Notes.TXT and notes.txt as one file.
# Usage: _git_path_collisions CANDIDATES_NAME TARGETS_NAME [FOLD_CASE]
_git_path_collisions() {
  emulate -L zsh

  local -a candidate_paths=("${(@P)1}")
  local -a target_paths=("${(@P)2}")
  local fold_case="${3:-no}"
  local -a target_keys=("${target_paths[@]}")
  local -a collisions=()
  local candidate_path=""
  local candidate_key=""
  local target_key=""

  [[ "$fold_case" == "yes" ]] && target_keys=("${(@L)target_paths}")
  for candidate_path in "${candidate_paths[@]}"; do
    candidate_path="${candidate_path%/}"
    [[ -n "$candidate_path" ]] || continue
    candidate_key="$candidate_path"
    [[ "$fold_case" == "yes" ]] && candidate_key="${(L)candidate_path}"

    for target_key in "${target_keys[@]}"; do
      if [[ "$candidate_key" == "$target_key" \
        || "$candidate_key" == "$target_key"/* \
        || "$target_key" == "$candidate_key"/* ]]; then
        (( ${collisions[(Ie)$candidate_path]} == 0 )) &&
          collisions+=("$candidate_path")
        break
      fi
    done
  done

  reply=("${collisions[@]}")
}

# --- Dependencies ------------------------------------------------------------

_git_check_cmd() {
  command -v "$1" &>/dev/null
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
    git-pr-create|git-pr-checkout)
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

# --- Platform context --------------------------------------------------------

# True when Linux runs under WSL: its session variables, its interop
# registration (WSLInterop, or WSLInterop-late on newer releases), or a
# Microsoft kernel release. The optional argument replaces /proc for fixtures.
_git_is_wsl() {
  local proc_root="${1:-/proc}"
  local kernel_release=""
  # WSL evidence counts only on a Linux kernel; a copied WSL variable on
  # another host must not select WSL behavior.
  [[ "${OSTYPE:-}" == linux* ]] || return 1
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  [[ -e "$proc_root/sys/fs/binfmt_misc/WSLInterop" \
    || -e "$proc_root/sys/fs/binfmt_misc/WSLInterop-late" ]] && return 0
  [[ -r "$proc_root/sys/kernel/osrelease" ]] || return 1
  IFS= read -r kernel_release < "$proc_root/sys/kernel/osrelease" \
    || [[ -n "$kernel_release" ]] || return 1
  [[ "${kernel_release:l}" == *microsoft* ]]
}

# True when PATH is on a Windows drive that WSL mounts at /mnt/<letter>,
# where Git reaches every file through DrvFs.
_git_wsl_drive_path() {
  local target_path="${1:-}"
  [[ "$target_path" == /mnt/[A-Za-z] || "$target_path" == /mnt/[A-Za-z]/* ]] \
    || return 1
  _git_is_wsl
}

_git_wsl_drive_warning() {
  _git_warn \
    "This repository is on a Windows drive: Git is slower over DrvFs, and Windows and WSL Git can disagree on line endings (core.autocrlf)."
}

# Prints the Windows-drive advisory when the current repository is on one.
# A directory outside /mnt/<letter> costs no Git process.
_git_wsl_drive_notice() {
  local repository_root=""
  _git_wsl_drive_path "${PWD:A}" || return 0
  repository_root=$(command git rev-parse --show-toplevel 2>/dev/null) ||
    return 0
  _git_wsl_drive_path "$repository_root" || return 0
  _git_wsl_drive_warning
}

# --- Repository and ref context ---------------------------------------------

# True on macOS when GIT_PATH is the Apple Command Line Tools placeholder: the
# /usr/bin/git shim while xcode-select reports no installed developer
# directory. Running it opens an installation dialog instead of Git.
_git_clt_placeholder() {
  emulate -L zsh

  local git_path="${1-}"
  local developer_dir=""
  [[ "${OSTYPE:-}" == darwin* && "$git_path" == /usr/bin/git ]] || return 1
  (( ${+commands[xcode-select]} )) || return 0
  developer_dir=$(command xcode-select -p </dev/null 2>/dev/null) || return 0
  developer_dir="${developer_dir%%$'\n'*}"
  [[ -n "$developer_dir" && -d "$developer_dir" ]] && return 1
  return 0
}

# Prints how to install Git; "outdated" asks for a newer release instead.
_git_install_hint() {
  if [[ "${OSTYPE:-}" == darwin* && "${1:-}" == "outdated" ]]; then
    _git_info "Install a newer Git with 'brew install git' or update the Command Line Tools, then retry."
  elif [[ "${OSTYPE:-}" == darwin* ]]; then
    _git_info "Install the Command Line Tools with 'xcode-select --install' or Git with 'brew install git', then retry."
  else
    _git_info "Install Git $_GIT_MINIMUM_VERSION or newer with your platform package manager, then retry."
  fi
}

# Succeeds when the git that `command git` runs works and is Git 2.31 or
# newer; otherwise explains how to install it. The macOS placeholder is
# reported without being run. A binary that passed is remembered by its
# resolved path and file identity, so the version is not probed again.
_git_require_git() {
  emulate -L zsh

  local git_path="${commands[git]-}"
  if ! _git_check_cmd git || [[ -z "$git_path" ]]; then
    _git_error "Git is required for this command."
    _git_install_hint
    return 1
  fi
  if _git_clt_placeholder "$git_path"; then
    _git_error \
      "/usr/bin/git is the Apple Command Line Tools placeholder; Git is not installed."
    _git_install_hint
    return 1
  fi

  local resolved_path="${git_path:A}"
  local binary_identity=""
  local -A binary_state=()
  if zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -H binary_state -- "$resolved_path" 2>/dev/null; then
    binary_identity="${binary_state[device]}:${binary_state[inode]}"
    binary_identity+=":${binary_state[mtime]}:${binary_state[size]}"
    [[ "${_GIT_VERIFIED_BINARIES[$resolved_path]-}" == "$binary_identity" ]] &&
      return 0
  fi

  local version_text=""
  local -i version_rc=0
  version_text=$(command git --version </dev/null 2>/dev/null) || version_rc=$?
  if (( version_rc != 0 )); then
    _git_error "Git at ${(V)git_path} did not run (git --version exit $version_rc)."
    _git_install_hint
    return 1
  fi
  if [[ ! "$version_text" =~ '^git version ([0-9]+[.][0-9]+([.][0-9]+)*)' ]]; then
    _git_error "Unable to read the Git version from ${(V)git_path}."
    return 1
  fi
  local git_version="${match[1]}"
  autoload -Uz is-at-least
  if ! is-at-least "$_GIT_MINIMUM_VERSION" "$git_version"; then
    _git_error \
      "Git $_GIT_MINIMUM_VERSION or newer is required; ${(V)git_path} is Git $git_version."
    _git_install_hint outdated
    return 1
  fi
  [[ -n "$binary_identity" ]] &&
    _GIT_VERIFIED_BINARIES[$resolved_path]="$binary_identity"
  return 0
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

# REPLY: the operation in progress in the worktree whose Git directory is
# GIT_DIR -- rebase, merge, cherry-pick, revert, or bisect -- or empty.
_git_operation_in_progress() {
  local git_dir="${1-}"
  REPLY=""
  [[ -n "$git_dir" ]] || return 1
  if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
    REPLY="rebase"
  elif [[ -f "$git_dir/MERGE_HEAD" ]]; then
    REPLY="merge"
  elif [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
    REPLY="cherry-pick"
  elif [[ -f "$git_dir/REVERT_HEAD" ]]; then
    REPLY="revert"
  elif [[ -f "$git_dir/BISECT_LOG" ]]; then
    REPLY="bisect"
  fi
  return 0
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

# Sets reply to "planned<TAB>other" pairs for planned refs that collide with
# another planned or existing ref once letter case is ignored: a name or
# directory of one differs only in case from a name or directory of the
# other. Loose refs are files, so a case-insensitive file system cannot keep
# both apart. Exact-case conflicts are left to Git, which refuses them.
# Usage: _git_ref_case_conflicts PLANNED_NAME EXISTING_NAME
_git_ref_case_conflicts() {
  emulate -L zsh

  local -a planned_refs=("${(@P)1}")
  local -a existing_refs=("${(@P)2}")
  local -A prefix_owners=()
  local -A folded_prefixes=()
  local ref_name="" prefix="" part="" folded="" other_prefix=""
  local newline=$'\n'
  reply=()

  # Index every exact name and directory under its lowercase form.
  for ref_name in "${existing_refs[@]}" "${planned_refs[@]}"; do
    prefix=""
    for part in "${(@s:/:)ref_name}"; do
      prefix+="${prefix:+/}${part}"
      (( ${+prefix_owners[$prefix]} )) && continue
      prefix_owners[$prefix]="$ref_name"
      folded="${(L)prefix}"
      folded_prefixes[$folded]+="${folded_prefixes[$folded]:+${newline}}${prefix}"
    done
  done

  for ref_name in "${planned_refs[@]}"; do
    prefix=""
    for part in "${(@s:/:)ref_name}"; do
      prefix+="${prefix:+/}${part}"
      for other_prefix in "${(@f)folded_prefixes[${(L)prefix}]}"; do
        [[ "$other_prefix" == "$prefix" ]] && continue
        reply+=("$ref_name"$'\t'"${prefix_owners[$other_prefix]}")
        continue 3
      done
    done
  done
}

# Refuses planned refs that a case-insensitive file system cannot store next
# to the refs already in NAMESPACE (or to each other). It applies only when
# core.ignorecase is true, prints each colliding pair and GUIDANCE, and
# returns 1. Usage: _git_ref_case_guard PLANNED_NAME NAMESPACE GUIDANCE
_git_ref_case_guard() {
  emulate -L zsh

  local planned_name="$1"
  local ref_namespace="$2"
  local guidance="$3"
  local existing_output=""
  local -a existing_refs=()
  local -a reported_pairs=()
  local -a reply=()
  local conflict_pair=""
  local planned_ref=""
  local other_ref=""

  _git_ignorecase_enabled || return 0
  existing_output=$(command git for-each-ref --format='%(refname)' \
    "$ref_namespace" 2>/dev/null) || {
    _git_error "Unable to inspect existing refs for letter-case collisions."
    return 1
  }
  [[ -n "$existing_output" ]] && existing_refs=("${(@f)existing_output}")
  _git_ref_case_conflicts "$planned_name" existing_refs
  (( ${#reply[@]} > 0 )) || return 0

  _git_error \
    "These refs collide on this case-insensitive file system (core.ignorecase is true):"
  for conflict_pair in "${reply[@]}"; do
    planned_ref="${conflict_pair%%$'\t'*}"
    other_ref="${conflict_pair#*$'\t'}"
    # Two planned refs that collide report each other; show the pair once.
    (( ${reported_pairs[(Ie)${other_ref}$'\t'${planned_ref}]} )) && continue
    reported_pairs+=("$conflict_pair")
    _git_dim "$planned_ref and $other_ref"
  done
  [[ -n "$guidance" ]] && _git_info "$guidance"
  return 1
}

# --- Workspace layout and safe auth display ----------------------------------

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
    # A file saved by a Windows editor ends its line with CRLF.
    hostname="${hostname%$'\r'}"
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

# Sets reply to (platform identity) when PATH lies strictly below an existing
# $WS_BASE_DIR/<platform>/<identity> directory; returns 1 otherwise. Both paths
# are compared in canonical form, and the identity directory itself is not a
# repository location. Usage: _git_workspace_layout PATH
_git_workspace_layout() {
  emulate -L zsh

  local base="${WS_BASE_DIR-}"
  local target_path="${1-}"
  reply=()
  [[ "$base" == /* && "$target_path" == /* ]] || return 1
  base="${base:A}"
  target_path="${target_path:A}"
  [[ "$base" != / && "$target_path" == "$base"/*/*/?* ]] || return 1

  local relative="${target_path#$base/}"
  local platform="${relative%%/*}"
  relative="${relative#*/}"
  local identity="${relative%%/*}"
  [[ -n "$platform" && -n "$identity" \
    && "$platform" != (.|..) && "$identity" != (.|..) \
    && -d "$base/$platform/$identity" ]] || return 1
  reply=("$platform" "$identity")
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
  local untracked_mode="all"
  local -i changed_count=0
  root=$(command git rev-parse --show-toplevel 2>/dev/null) || return 1
  branch=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || branch="detached"
  remote=$(_git_current_remote 2>/dev/null) || remote=""
  [[ -n "$remote" ]] || remote="none"
  # Listing every untracked file is slow over DrvFs, so on a Windows drive
  # the badge counts an untracked directory as one change.
  _git_wsl_drive_path "$root" && untracked_mode="normal"
  status_output=$(command git status \
    --porcelain=v1 "--untracked-files=$untracked_mode" 2>/dev/null) || return 1
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

# Command presence for menu annotations. A menu build declares the
# _git_menu_dependency_cache association, so each command's PATH scan runs
# once per build: a missing command scans every PATH directory, which is slow
# when WSL appends Windows directories. Without the cache this is
# _git_check_cmd.
_git_menu_has_cmd() {
  local command_name="$1"
  if (( ! ${+_git_menu_dependency_cache} )); then
    _git_check_cmd "$command_name"
    return
  fi
  if (( ! ${+_git_menu_dependency_cache[$command_name]} )); then
    if _git_check_cmd "$command_name"; then
      _git_menu_dependency_cache[$command_name]=0
    else
      _git_menu_dependency_cache[$command_name]=1
    fi
  fi
  return "${_git_menu_dependency_cache[$command_name]}"
}

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
    git-identity-switcher)
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
    _git_menu_has_cmd "$dependency" || missing+=("$dependency")
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
    git-recover)
      git-recover "$@" ;;
    git-identity-check)
      git-identity-check "$@" ;;
    git-unstage)
      git-unstage "$@" ;;
    git-stash)
      git-stash "$@" ;;
    git-amend)
      git-amend "$@" ;;
    git-pull)
      git-pull "$@" ;;
    git-push)
      git-push "$@" ;;
    git-tag-create)
      git-tag-create "$@" ;;
    git-tag-verify)
      git-tag-verify "$@" ;;
    git-tag-push)
      git-tag-push "$@" ;;
    git-pr-create)
      git-pr-create "$@" ;;
    git-pr-checkout)
      git-pr-checkout "$@" ;;
    git-identity-switcher)
      git-identity-switcher "$@" ;;
    git-discard)
      git-discard "$@" ;;
    git-undo-commit)
      git-undo-commit "$@" ;;
    git-tag-delete)
      git-tag-delete "$@" ;;
    clean-branches)
      clean-branches "$@" ;;
    clean-remote-merged)
      clean-remote-merged "$@" ;;
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

typeset -g _GIT_COMMON_SOURCED=1
