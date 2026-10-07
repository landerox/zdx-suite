#!/usr/bin/env zsh
# =============================================================================
# ZDX Plugins: staged, trust-gated custom plugin lifecycle manager
# =============================================================================
#
# Loaded lazily by functions.zsh for the zdx-plugins command. Installs and
# updates are fetched into private staging below the plugin root, validated
# with the loader's own rules, shown as an exact commit transition, and
# published only after a trust decision. See docs/plugins.md.
# Safe to re-source; defines functions only.
#

if [[ -n "${_ZDX_PLUGINS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Output wrappers (docs/output-spec.md) -----------------------------------
# Thin wrappers over the core output services. The plain fallbacks keep help,
# listing, and picker rendering usable when this file is sourced on its own.

_zdx_plugins_color_enabled() {
  if (( ${+functions[_zdx_ui_color_enabled]} )); then
    _zdx_ui_color_enabled
    return
  fi
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]
}

# Usage: _zdx_plugins_say <success|info|warn|error|dim> <text>
_zdx_plugins_say() {
  local level="${1-}" text="${2-}" glyph=""
  if (( ${+functions[_zdx_ui_say]} )); then
    _zdx_ui_say "$level" "$text"
    return
  fi
  case "$level" in
    success) glyph="✔ " ;;
    info)    glyph="➜ " ;;
    warn)    glyph="⚠ " ;;
    error)   glyph="✘ " ;;
    *)       glyph="  " ;;
  esac
  printf '%s%s\n' "$glyph" "${(V)text}" >&2
}

_zdx_plugins_info()    { _zdx_plugins_say info "${1-}"; }
_zdx_plugins_success() { _zdx_plugins_say success "${1-}"; }
_zdx_plugins_warn()    { _zdx_plugins_say warn "${1-}"; }
_zdx_plugins_error()   { _zdx_plugins_say error "${1-}"; }
_zdx_plugins_dim()     { _zdx_plugins_say dim "${1-}"; }

_zdx_plugins_header() {
  if (( ${+functions[_zdx_ui_heading]} )); then
    _zdx_ui_heading "${1-}"
    return
  fi
  printf '\n════ %s ════\n\n' "${(V)1-}" >&2
}

# Usage: _zdx_plugins_section [--first] <title>
_zdx_plugins_section() {
  if (( ${+functions[_zdx_ui_section]} )); then
    _zdx_ui_section "$@"
    return
  fi
  [[ "${1-}" == --first ]] && shift || print -u2 -r -- ""
  printf '▸ %s\n' "${(V)1-}" >&2
}

_zdx_plugins_label() {
  if (( ${+functions[_zdx_ui_label]} )); then
    _zdx_ui_label "${1-}" "${2-}"
    return
  fi
  printf '  %-18s %s\n' "${(V)${1%:}}:" "${(V)2-}" >&2
}

# REPLY: "<count> <noun>". Usage: _zdx_plugins_count_noun <count> <singular> [plural]
_zdx_plugins_count_noun() {
  if (( ${+functions[_zdx_count_noun]} )); then
    _zdx_count_noun "$@"
    return
  fi
  local count="${1-}" singular="${2-}" plural="${3:-${2-}s}"
  REPLY=""
  [[ "$count" == <-> && -n "$singular" ]] || return 2
  if (( count == 1 )); then REPLY="1 $singular"; else REPLY="$count $plural"; fi
}

# REPLY: a display path with HOME shown as ~. Display only; never used again.
_zdx_plugins_tilde() {
  local target="${1-}" home="${HOME-}"
  REPLY="$target"
  if [[ -n "$home" && "$home" != / && "$target" == "$home"/* ]]; then
    REPLY="~/${target#"$home"/}"
  fi
}

# Records an outcome in the active aggregate step, or prints the standalone
# message when no step slot is reachable from this shell.
# Usage: _zdx_plugins_report_result <outcome> <detail> <level> <message>
_zdx_plugins_report_result() {
  local outcome="${1-}" detail="${2-}" level="${3:-info}" message="${4-}"
  if (( ${+functions[_zdx_step_report]} )) \
    && _zdx_step_report "$outcome" "$detail" 2>/dev/null; then
    return 0
  fi
  _zdx_plugins_say "$level" "$message"
}

# Prints a failure and records it for an enclosing aggregate step.
# Usage: _zdx_plugins_fail <failed|blocked> <detail> <message>
_zdx_plugins_fail() {
  _zdx_plugins_error "${3-}"
  if (( ${+functions[_zdx_step_report]} )); then
    _zdx_step_report "${1:-failed}" "${2-}" 2>/dev/null
  fi
  return 1
}

# --- Menu rows and fzf ------------------------------------------------------

_zdx_plugins_menu_section() {
  local title="$1" description="${2:-}"
  printf "── %s ──|:|%s\n" "$title" "$description"
}

_zdx_plugins_menu_entry() {
  local label="$1" command="$2" description="$3"
  printf "  %s|%s|%s\n" "$label" "$command" "$description"
}

# Keep picker rendering independent of the user's standalone fzf defaults.
_zdx_plugins_fzf() {
  local -a options=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow')
  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option=""
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && options+=("$theme_option")
  fi

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
    SHELL=/bin/sh fzf "${options[@]}" "$@" "${terminal_options[@]}"
}

# Runs fzf in the terminal foreground and returns its selection in REPLY. The
# selection goes to one private, byte-bounded file below the core's validated
# temporary root, which is removed only while it keeps its identity.
_zdx_plugins_fzf_capture() {
  emulate -L zsh
  REPLY=""
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
    _zdx_plugins_error "Zsh file-descriptor support is required for the plugin menu."
    return 125
  }
  if (( ! ${+functions[_zdx_capture_parent_safe]} )) \
    || ! _zdx_capture_parent_safe; then
    _zdx_plugins_error "Refusing an unsafe temporary root for the plugin menu."
    return 125
  fi
  local temp_root="$REPLY"
  REPLY=""

  local result_file=""
  result_file=$(umask 077; command mktemp \
    "${temp_root%/}/zdx-plugins-fzf.XXXXXX" 2>/dev/null) || {
    _zdx_plugins_error "Could not create a private plugin menu result."
    return 125
  }

  local selection="" identity=""
  local -i write_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A file_state=() current_state=()
  {
    if [[ "$result_file" != "${result_file:a}" \
      || "$result_file" != "${result_file:A}" \
      || "${result_file:h}" != "$temp_root" \
      || "${result_file:t}" != zdx-plugins-fzf.* \
      || ! -f "$result_file" || -L "$result_file" ]] \
      || ! zstat -LH file_state -- "$result_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 \
        || (file_state[mode] & 8#170000) != 8#100000 \
        || file_state[size] != 0 )); then
      _zdx_plugins_error "Refusing an unsafe plugin menu result."
    else
      identity="${file_state[device]}:${file_state[inode]}:"\
"${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$result_file" 2>/dev/null; then
        _zdx_plugins_error "Could not open the plugin menu result safely."
      else
        _zdx_plugins_fzf "$@" 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_state -- "$result_file" 2>/dev/null \
          || [[ "${current_state[device]}:${current_state[inode]}:"\
"${current_state[mode]}:${current_state[uid]}:"\
"${current_state[nlink]}" != "$identity" ]] \
          || (( current_state[size] < 0 \
            || current_state[size] > 65536 )); then
          _zdx_plugins_error "The plugin menu result changed or exceeded its limit."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$result_file" 2>/dev/null; then
          _zdx_plugins_error "Could not read the plugin menu result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _zdx_plugins_error "A failed plugin picker returned unexpected data."
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
    current_state=()
    if [[ -n "$identity" \
      && -f "$result_file" && ! -L "$result_file" \
      && "${result_file:h}" == "$temp_root" ]] \
      && zstat -LH current_state -- "$result_file" 2>/dev/null \
      && [[ "${current_state[device]}:${current_state[inode]}:"\
"${current_state[mode]}:${current_state[uid]}:"\
"${current_state[nlink]}" == "$identity" ]]; then
      command rm -f -- "$result_file" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

# True when the complete selected row is one exact row of the menu snapshot.
_zdx_plugins_row_in_snapshot() {
  local selected="${1-}" snapshot_row=""
  shift
  for snapshot_row in "$@"; do
    [[ "$selected" == "$snapshot_row" ]] && return 0
  done
  return 1
}

# --- Confirmation -------------------------------------------------------------

# True when a confirmation prompt can reach a person.
_zdx_plugins_terminal() {
  [[ -t 0 && -t 2 ]]
}

# Status 0 accepted, 1 declined, 2 no terminal for the prompt.
_zdx_plugins_confirm() {
  local prompt="${1:-Proceed?}" auto_yes="${2:-no}" answer=""
  [[ "$auto_yes" == yes ]] && return 0
  _zdx_plugins_terminal || return 2
  if _zdx_plugins_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi
  read -r answer || return 2
  [[ "$answer" == [Yy] ]]
}

# Refuses a change that could neither prompt nor rely on --yes, before any
# network access, staging, or deletion.
_zdx_plugins_require_authorization() {
  [[ "${1:-no}" == yes || "${2:-no}" == yes ]] && return 0
  _zdx_plugins_terminal && return 0
  _zdx_plugins_error "Plugin changes need a terminal for the trust decision; review with --dry-run, then pass --yes to proceed without a prompt."
  return 1
}

# --- Validation primitives ----------------------------------------------------

_zdx_plugins_name_valid() {
  local plugin_name="${1-}"
  (( ${#plugin_name} >= 1 && ${#plugin_name} <= 128 )) \
    && [[ "$plugin_name" =~ '^[a-z0-9_-]+$' ]]
}

# True when a name is one exact entry of ZDX_LOADED_PLUGINS.
_zdx_plugins_loaded() {
  local plugin_name="${1-}" loaded_name=""
  (( ${+ZDX_LOADED_PLUGINS} )) || return 1
  for loaded_name in "${ZDX_LOADED_PLUGINS[@]}"; do
    [[ "$loaded_name" == "$plugin_name" ]] && return 0
  done
  return 1
}

# A Git URL or local path is data for Git, never an option or shell text.
_zdx_plugins_url_valid() {
  local url="${1-}"
  (( ${#url} >= 1 && ${#url} <= 2048 )) \
    && [[ "$url" != -* && "$url" != *[[:cntrl:]]* ]]
}

# REPLY: a display form of a Git URL with any userinfo of a scheme URL, and
# any query or fragment, hidden. Display only; never used to fetch.
_zdx_plugins_redact_url() {
  local remote_url="${1-}" suffix=""
  REPLY=""
  if [[ "$remote_url" == *[\?\#]* ]]; then
    suffix=" (query or fragment redacted)"
    remote_url="${remote_url%%[\?\#]*}"
  fi
  if [[ "$remote_url" == *://* ]]; then
    local scheme="${remote_url%%://*}" remainder="${remote_url#*://}"
    local authority="${remainder%%/*}"
    if [[ "$authority" == *@* ]]; then
      remainder="***@${authority##*@}${remainder:${#authority}}"
    fi
    remote_url="${scheme}://${remainder}"
  fi
  REPLY="${remote_url}${suffix}"
}

# REPLY: "device:inode" of an owned real directory; status 1 for anything else.
_zdx_plugins_dir_identity() {
  emulate -L zsh
  local target="${1-}"
  local -A state=()
  REPLY=""
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  [[ -n "$target" && -d "$target" && ! -L "$target" ]] \
    && zstat -LH state -- "$target" 2>/dev/null \
    && (( (state[mode] & 8#170000) == 8#040000 && state[uid] == EUID )) \
    || return 1
  REPLY="${state[device]}:${state[inode]}"
}

# Lifecycle actions reuse the core loader's root, entrypoint, capture, and
# output services, so the manager and loader apply one rule set.
_zdx_plugins_require_runtime() {
  local service=""
  for service in _zdx_plugin_root_resolve _zdx_plugin_root_safe \
    _zdx_plugin_entrypoint_safe _zdx_capture_parent_safe _zdx_run_captured \
    _zdx_run_with_timeout _zdx_ui_label _zdx_ui_table _zdx_ui_step_banner \
    _zdx_ui_step_result _zdx_ui_step_summary _zdx_step_exec _zdx_step_report \
    _zdx_count_noun; do
    (( ${+functions[$service]} )) && continue
    _zdx_plugins_error "zdx-plugins needs the ZDX core runtime; load it through zdx-suite.plugin.zsh or functions.zsh."
    return 1
  done
  (( ${+ZDX_LOADED_PLUGINS} )) || typeset -ga ZDX_LOADED_PLUGINS=()
}

# macOS ships /usr/bin/git as a Command Line Tools placeholder that opens an
# installation dialog; it is reported as missing and never run.
_zdx_plugins_require_git() {
  local git_path=""
  git_path=$(whence -p git 2>/dev/null) || git_path=""
  if [[ -n "$git_path" && "${OSTYPE:-}" == darwin* \
    && "$git_path" == /usr/bin/git ]] \
    && ! command xcode-select -p >/dev/null 2>&1; then
    git_path=""
  fi
  [[ -n "$git_path" ]] && return 0
  _zdx_plugins_error "git is required to install or update plugins; install Git, then retry."
  return 1
}

# --- Git boundary -------------------------------------------------------------
# Every Git call targets one exact repository with the caller's routing and
# configuration-injection variables removed. Output belongs to the caller.

# Usage: _zdx_plugins_git [--timeout SECONDS] <git arguments...>
_zdx_plugins_git() {
  local -i seconds=0
  if [[ "${1-}" == --timeout ]]; then
    seconds="${2:-0}"
    shift 2
  fi
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    export GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0
    if (( seconds > 0 )) && (( ${+functions[_zdx_run_with_timeout]} )); then
      # The bounded form must exec the Git binary itself, not a function.
      local git_path=""
      git_path=$(whence -p git 2>/dev/null) || exit 127
      _zdx_run_with_timeout "$seconds" "$git_path" "$@"
    else
      command git "$@"
    fi
  )
}

# The network form also disables credential prompts and askpass helpers,
# limits transports to file, git, http(s), and ssh, and bounds a stalled
# transfer, so a hidden prompt or a dead peer cannot hang the shell.
# Credentials must come from a credential helper or an SSH agent.
_zdx_plugins_git_network() {
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
      GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS SSH_ASKPASS
    export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' GIT_OPTIONAL_LOCKS=0
    export GIT_ALLOW_PROTOCOL='file:git:http:https:ssh'
    if [[ -z "${GIT_SSH_COMMAND:-}" && -z "${GIT_SSH:-}" ]] \
      && ! command git config --get core.sshCommand >/dev/null 2>&1; then
      export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4'
    fi
    # Git aborts a transfer that stays below 1 KiB/s for 60 seconds.
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0=http.lowSpeedLimit GIT_CONFIG_VALUE_0=1024
    export GIT_CONFIG_KEY_1=http.lowSpeedTime GIT_CONFIG_VALUE_1=60
    command git "$@"
  )
}

# REPLY: the full commit object ID at HEAD of one exact repository.
_zdx_plugins_head() {
  local repository="${1-}" oid=""
  REPLY=""
  oid=$(_zdx_plugins_git -C "$repository" rev-parse --verify --quiet \
    'HEAD^{commit}' 2>/dev/null) || return 1
  [[ "$oid" =~ '^[0-9a-f]{40}([0-9a-f]{24})?$' ]] || return 1
  REPLY="$oid"
}

# REPLY: one origin-supplied text field as bounded, single-line display data.
_zdx_plugins_display_field() {
  local value="${1-}"
  value="${value//[[:cntrl:]]/ }"
  (( ${#value} > 100 )) && value="${value[1,99]}…"
  REPLY="$value"
}

# REPLY: "<short-oid> <subject>" for one commit; display data, never code.
_zdx_plugins_commit_line() {
  local repository="${1-}" oid="${2-}" subject=""
  subject=$(_zdx_plugins_git -C "$repository" -c log.showSignature=false \
    show -s --format=%s "$oid" -- 2>/dev/null) || subject=""
  _zdx_plugins_display_field "$subject"
  REPLY="${oid[1,7]}${REPLY:+ $REPLY}"
}

# REPLY: the signature verdict for one commit; reply=(class) with class good,
# bad, unsigned, or unknown. An unsigned commit is a verdict, not a failure.
# The verifier is bounded because a GnuPG configuration can reach the network.
_zdx_plugins_signature() {
  local repository="${1-}" oid="${2-}" raw="" code="" signer=""
  raw=$(_zdx_plugins_git --timeout 15 -C "$repository" \
    -c log.showSignature=false show -s --format='%G?%x1f%GS' "$oid" -- \
    2>/dev/null) || raw=""
  code="${raw%%$'\x1f'*}"
  signer="${raw#*$'\x1f'}"
  [[ "$raw" == *$'\x1f'* ]] || signer=""
  _zdx_plugins_display_field "$signer"
  signer="$REPLY"
  reply=(good)
  case "$code" in
    G) REPLY="good signature${signer:+ from $signer}" ;;
    U) REPLY="good signature${signer:+ from $signer} (key validity unknown)" ;;
    X) REPLY="good but expired signature${signer:+ from $signer}" ;;
    Y) REPLY="good signature by an expired key${signer:+ ($signer)}" ;;
    R) REPLY="good signature by a revoked key${signer:+ ($signer)}"
       reply=(unknown) ;;
    B) REPLY="BAD signature${signer:+ claiming $signer}"
       reply=(bad) ;;
    E) REPLY="signed, but not verifiable here (missing key or verifier)"
       reply=(unknown) ;;
    N) REPLY="unsigned"
       reply=(unsigned) ;;
    *) REPLY="unknown (the signature check failed or timed out)"
       reply=(unknown) ;;
  esac
}

# reply=(relation count): how a staged commit relates to the installed one in
# the staged clone. relation is fast-forward, rewritten, or unknown when the
# installed commit is absent from the fetched history; count is the number of
# commits only the new history has, or empty when unknown.
_zdx_plugins_transition() {
  local repository="${1-}" old_oid="${2-}" new_oid="${3-}" count=""
  reply=(unknown "")
  _zdx_plugins_git -C "$repository" cat-file -e "${old_oid}^{commit}" \
    2>/dev/null || return 0
  count=$(_zdx_plugins_git -C "$repository" rev-list --count \
    "${old_oid}..${new_oid}" -- 2>/dev/null) || count=""
  [[ "$count" == <-> ]] || count=""
  if _zdx_plugins_git -C "$repository" merge-base --is-ancestor \
    "$old_oid" "$new_oid" 2>/dev/null; then
    reply=(fast-forward "$count")
  else
    reply=(rewritten "$count")
  fi
}

# Lists at most ten incoming commits, newest first, as escaped display lines.
_zdx_plugins_show_incoming() {
  local repository="${1-}" old_oid="${2-}" new_oid="${3-}" count="${4-}"
  local log_output="" line="" REPLY=""
  log_output=$(_zdx_plugins_git -C "$repository" -c log.showSignature=false \
    log --format='%H%x1f%s' --max-count=10 "${old_oid}..${new_oid}" -- \
    2>/dev/null) || return 0
  [[ -n "$log_output" ]] || return 0
  for line in "${(@f)log_output}"; do
    _zdx_plugins_display_field "${line#*$'\x1f'}"
    _zdx_plugins_dim "${line[1,7]} $REPLY"
  done
  if [[ "$count" == <-> ]] && (( count > 10 )); then
    _zdx_plugins_count_noun "$(( count - 10 ))" "earlier commit"
    _zdx_plugins_dim "… and $REPLY"
  fi
}

# True when a checkout has no modified, untracked, or ignored files, so
# replacing it cannot discard local work and its files equal its commit.
# Otherwise reply holds up to three porcelain status lines as display text.
_zdx_plugins_checkout_clean() {
  local repository="${1-}" changes="" line="" REPLY=""
  reply=()
  changes=$(_zdx_plugins_git -C "$repository" status --porcelain --ignored \
    --untracked-files=all 2>/dev/null) || return 1
  [[ -z "$changes" ]] && return 0
  for line in "${(@f)changes}"; do
    (( ${#reply} < 3 )) || break
    _zdx_plugins_display_field "$line"
    reply+=("$REPLY")
  done
  return 1
}

# --- Plugin root, lock, and staging ---------------------------------------------

# REPLY: the canonical plugin root, created private when asked. The core
# loader's resolver decides, so the manager and the loader agree on the root.
_zdx_plugins_root() {
  local create="${1:-no}"
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  REPLY=""
  if [[ "$create" == yes && ! -e "$plugins_dir" && ! -L "$plugins_dir" ]]; then
    # The loader refuses a group- or other-writable root, so a root created
    # here is private whatever the caller's umask is.
    ( umask 077; command mkdir -p -- "$plugins_dir" ) 2>/dev/null
  fi
  _zdx_plugin_root_resolve "$plugins_dir" || {
    _zdx_plugins_error "Refusing a missing or unsafe plugin root: $plugins_dir"
    return 1
  }
}

# Takes the manager's exclusive, non-blocking fcntl lock on
# <root>/.zdx-plugins.lock. The kernel releases it when the descriptor closes
# or the shell exits, so an interrupted run never leaves a stale lock. The
# file itself is kept: unlinking a lock file lets two runs lock two inodes.
_zdx_plugins_lock() {
  emulate -L zsh
  local root="${1-}"
  local lock_file="$root/.zdx-plugins.lock"
  if [[ -n "${_ZDX_PLUGINS_LOCK_FD:-}" ]]; then
    _zdx_plugins_error "A zdx-plugins operation is already running in this shell."
    return 1
  fi
  if ! { zmodload zsh/system && zmodload -F zsh/stat b:zstat; } 2>/dev/null \
    || ! zsystem supports flock 2>/dev/null; then
    _zdx_plugins_error "Zsh file locking (zsh/system) is required to manage plugins."
    return 1
  fi

  local -i create_fd=-1 lock_fd=-1
  if [[ ! -e "$lock_file" && ! -L "$lock_file" ]] \
    && sysopen -w -o create,excl,nofollow,cloexec -m 600 -u create_fd \
      -- "$lock_file" 2>/dev/null; then
    exec {create_fd}>&-
  fi
  local -A path_state=() fd_state=()
  if [[ ! -f "$lock_file" || -L "$lock_file" ]] \
    || ! zstat -LH path_state -- "$lock_file" 2>/dev/null \
    || (( path_state[uid] != EUID || path_state[nlink] != 1 \
      || (path_state[mode] & 8#077) != 0 )); then
    _zdx_plugins_error "Refusing an unsafe plugin lock file: $lock_file"
    return 1
  fi
  if ! zsystem flock -t 0 -f lock_fd "$lock_file" 2>/dev/null; then
    _zdx_plugins_error "Another zdx-plugins operation holds the plugin lock; retry when it finishes."
    return 1
  fi
  if ! zstat -H fd_state -f "$lock_fd" 2>/dev/null \
    || [[ "${fd_state[device]}:${fd_state[inode]}" \
      != "${path_state[device]}:${path_state[inode]}" ]]; then
    zsystem flock -u "$lock_fd" 2>/dev/null
    _zdx_plugins_error "The plugin lock file changed while it was opened."
    return 1
  fi
  typeset -g _ZDX_PLUGINS_LOCK_FD="$lock_fd"
}

_zdx_plugins_unlock() {
  [[ -n "${_ZDX_PLUGINS_LOCK_FD:-}" ]] || return 0
  zsystem flock -u "$_ZDX_PLUGINS_LOCK_FD" 2>/dev/null
  unset _ZDX_PLUGINS_LOCK_FD
}

# reply: an mv that never replaces a destination. GNU and uutils mv take -T,
# so an existing directory is never entered; BSD mv takes -n only, and every
# caller verifies the moved identity afterwards.
_zdx_plugins_mv_command() {
  emulate -L zsh
  reply=()
  local mv_command="" version_text=""
  mv_command=$(whence -p mv 2>/dev/null) || mv_command=""
  [[ "$mv_command" == /* && -x "$mv_command" ]] || {
    _zdx_plugins_error "mv is required to publish or remove a plugin."
    return 1
  }
  version_text=$(LC_ALL=C command "$mv_command" --version \
    </dev/null 2>/dev/null) || version_text=""
  version_text="${version_text%%$'\n'*}"
  if [[ "$version_text" == *"GNU coreutils"* \
    || "$version_text" == *"uutils coreutils"* ]]; then
    reply=("$mv_command" -T -n)
  else
    reply=("$mv_command" -n)
  fi
}

# Renames one directory to an absent destination and proves that the
# destination now holds exactly the expected directory.
# Usage: _zdx_plugins_move <source> <destination> <expected-identity>
_zdx_plugins_move() {
  local source_dir="${1-}" destination="${2-}" identity="${3-}" REPLY=""
  local -a reply=()
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  _zdx_plugins_mv_command || return 1
  command "${reply[@]}" -- "$source_dir" "$destination" 2>/dev/null
  _zdx_plugins_dir_identity "$destination" && [[ "$REPLY" == "$identity" ]]
}

# reply=(stage identity): a new owner-only staging directory inside the
# canonical root, named for its plugin so an interrupted transaction can be
# recognized later. Being a child of the root keeps every publish a
# same-filesystem rename, and its dot name never matches the loader pattern.
_zdx_plugins_stage_create() {
  emulate -L zsh
  local root="${1-}" plugin_name="${2-}" stage=""
  local -A state=()
  reply=()
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  stage=$(umask 077; command mktemp -d \
    "$root/.zdx-staging.$plugin_name.XXXXXX" 2>/dev/null) || {
    _zdx_plugins_error "Could not create a private staging directory in the plugin root."
    return 1
  }
  if [[ "${stage:h}" != "$root" || "${stage:t}" != .zdx-staging.$plugin_name.* \
    || ! -d "$stage" || -L "$stage" ]] \
    || ! zstat -LH state -- "$stage" 2>/dev/null \
    || (( state[uid] != EUID || (state[mode] & 8#077) != 0 )); then
    _zdx_plugins_error "The private staging directory failed validation: $stage"
    return 1
  fi
  reply=("$stage" "${state[device]}:${state[inode]}")
}

# Removes one exact staging tree of this root. The name, parent, and identity
# checks keep the deletion to the manager's own staging, and rm -rf never
# follows links inside the tree.
_zdx_plugins_remove_stage() {
  local stage="${1-}" root="${2-}" identity="${3-}" REPLY=""
  [[ -n "$stage" && -n "$root" && "${stage:h}" == "$root" \
    && "${stage:t}" == .zdx-staging.* ]] || return 1
  _zdx_plugins_dir_identity "$stage" || return 1
  [[ -z "$identity" || "$REPLY" == "$identity" ]] || return 1
  command rm -rf -- "$stage" 2>/dev/null
  [[ ! -e "$stage" && ! -L "$stage" ]]
}

# Recovers staging that an interrupted run left behind; the caller holds the
# lock, so no live transaction owns it. A previous version that was moved
# aside while its plugin is absent is restored. A previous version is never
# deleted automatically: when the plugin directory exists again, its staging
# is kept and named. Anything else (a partial clone, a rolled-back tree, or a
# removal quarantine) is discarded.
_zdx_plugins_recover_stale() {
  emulate -L zsh
  local root="${1-}" stage="" plugin_name="" REPLY=""
  local -a stages=("$root"/.zdx-staging.*(DN))
  for stage in "${stages[@]}"; do
    _zdx_plugins_tilde "$stage"
    local stage_display="$REPLY"
    if [[ "${stage:t}" =~ '^\.zdx-staging\.([a-z0-9_-]+)\.[A-Za-z0-9]{6,}$' ]] \
      && _zdx_plugins_dir_identity "$stage"; then
      plugin_name="${match[1]}"
    else
      _zdx_plugins_error "Refusing unexpected staging in the plugin root: $stage_display"
      return 1
    fi
    local stage_id="$REPLY"
    if _zdx_plugins_dir_identity "$stage/previous"; then
      if [[ -e "$root/$plugin_name" || -L "$root/$plugin_name" ]]; then
        _zdx_plugins_warn "An interrupted update of '$plugin_name' kept its previous version in $stage_display/previous; remove that directory once you no longer need it."
        continue
      fi
      if _zdx_plugins_move "$stage/previous" "$root/$plugin_name" "$REPLY"; then
        _zdx_plugins_warn "Restored plugin '$plugin_name' from an interrupted transaction."
      else
        _zdx_plugins_error "Could not restore plugin '$plugin_name' from $stage_display/previous; move it back manually."
        return 1
      fi
    fi
    if _zdx_plugins_remove_stage "$stage" "$root" "$stage_id"; then
      _zdx_plugins_warn "Removed staging left by an interrupted transaction: $stage_display"
    else
      _zdx_plugins_error "Could not remove leftover staging $stage_display; remove it manually."
      return 1
    fi
  done
}

# Opens the manager session: the canonical root, the exclusive lock, and
# recovery of interrupted staging. It fills the caller's _zdx_plugins_session
# map (root, root_id), which _zdx_plugins_session_close ends.
_zdx_plugins_session_open() {
  local create="${1:-no}" REPLY=""
  _zdx_plugins_require_runtime || return 1
  _zdx_plugins_root "$create" || return 1
  local root="$REPLY"
  _zdx_plugins_dir_identity "$root" || {
    _zdx_plugins_error "Refusing an unsafe plugin root: $root"
    return 1
  }
  local root_id="$REPLY"
  _zdx_plugins_lock "$root" || return 1
  _zdx_plugins_session=(root "$root" root_id "$root_id")
  _zdx_plugins_recover_stale "$root" || return 1
}

# True when the session root still resolves to the same canonical directory.
_zdx_plugins_root_unchanged() {
  local root="${_zdx_plugins_session[root]-}" REPLY=""
  [[ -n "$root" ]] \
    && _zdx_plugin_root_safe "$root" \
    && _zdx_plugins_dir_identity "$root" \
    && [[ "$REPLY" == "${_zdx_plugins_session[root_id]-}" ]]
}

# Creates the transaction's staging directory. The caller's _zdx_plugins_tx
# map tracks the phase: staged, swapping, published, activated, removed,
# rolled-back, or stranded.
_zdx_plugins_tx_open() {
  local plugin_name="${1-}"
  local -a reply=()
  _zdx_plugins_stage_create "${_zdx_plugins_session[root]}" "$plugin_name" \
    || return 1
  _zdx_plugins_tx=(
    name "$plugin_name" stage "${reply[1]}" stage_id "${reply[2]}"
    phase staged mode "" staged_id "" active_id ""
  )
}

# Ends the transaction on every exit path. A tree that was published but not
# activated (an interruption between publication and the source result) is
# rolled back first. Staging is then removed, unless it still holds the only
# copy of a previous version, which is kept and named for recovery.
_zdx_plugins_tx_close() {
  [[ -n "${_zdx_plugins_tx[stage]-}" ]] || return 0
  local stage="${_zdx_plugins_tx[stage]}" REPLY=""
  local plugin_name="${_zdx_plugins_tx[name]}"
  local target="${_zdx_plugins_session[root]}/${_zdx_plugins_tx[name]}"
  case "${_zdx_plugins_tx[phase]}" in
    published)
      if _zdx_plugins_rollback; then
        _zdx_plugins_warn "Rolled back '$plugin_name' after an interrupted activation."
      fi
      ;;
    swapping)
      # Interrupted between the two renames: put the previous version back.
      if _zdx_plugins_move "$stage/previous" "$target" \
        "${_zdx_plugins_tx[active_id]}"; then
        _zdx_plugins_tx[phase]=rolled-back
        _zdx_plugins_warn "Restored the installed version of '$plugin_name' after an interruption."
      else
        _zdx_plugins_tx[phase]=stranded
      fi
      ;;
  esac
  _zdx_plugins_tilde "$stage"
  if [[ "${_zdx_plugins_tx[phase]}" == stranded ]]; then
    if [[ "${_zdx_plugins_tx[mode]}" == update ]]; then
      _zdx_plugins_error "Automatic rollback of '$plugin_name' did not complete; its previous version is kept in $REPLY/previous. Restore it to the plugin root manually."
    else
      _zdx_plugins_error "Automatic rollback of '$plugin_name' did not complete; inspect $REPLY and the plugin root manually."
    fi
    _zdx_plugins_tx=()
    return 1
  fi
  if ! _zdx_plugins_remove_stage "$stage" "${_zdx_plugins_session[root]}" \
    "${_zdx_plugins_tx[stage_id]}"; then
    _zdx_plugins_warn "Could not remove the private staging directory $REPLY; remove it manually."
  fi
  _zdx_plugins_tx=()
}

# --- Staged validation ---------------------------------------------------------

# Refuses a checkout that contains symbolic links anywhere, so no path in the
# published tree can point outside the plugin root.
_zdx_plugins_tree_links() {
  emulate -L zsh
  local tree="${1-}"
  local -a links=("$tree"/**/*(DN@))
  (( ${#links} == 0 )) && return 0
  _zdx_plugins_error "Refusing a plugin checkout that contains symbolic links, such as ${links[1]#$tree/}."
  return 1
}

# Applies the loader's own entrypoint rules to a staged tree, with the staging
# directory as its root, then refuses links and checks the entrypoint syntax.
# Usage: _zdx_plugins_tree_validate <container> <plugin-name>
_zdx_plugins_tree_validate() {
  local container="${1-}" plugin_name="${2-}"
  local tree="${1-}/${2-}"
  local entrypoint="$tree/${plugin_name}-menu.zsh"
  if [[ ! -e "$entrypoint" && ! -L "$entrypoint" ]]; then
    _zdx_plugins_error "Ecosystem Contract Violation: Entrypoint script '${plugin_name}-menu.zsh' not found in the repository root."
    return 1
  fi
  if ! _zdx_plugin_entrypoint_safe "$container" "$tree" "$entrypoint"; then
    _zdx_plugins_error "Ecosystem Contract Violation: '${plugin_name}-menu.zsh' must be an owned, singly linked regular file in the repository root."
    return 1
  fi
  _zdx_plugins_tree_links "$tree" || return 1
  if ! _zdx_run_captured "zsh -n ${plugin_name}-menu.zsh" "" 20 \
    command zsh -n -- "$entrypoint"; then
    _zdx_plugins_error "Ecosystem Contract Violation: Syntax error in '${plugin_name}-menu.zsh'."
    return 1
  fi
  _zdx_plugin_entrypoint_safe "$container" "$tree" "$entrypoint" || {
    _zdx_plugins_error "The staged plugin changed during validation."
    return 1
  }
}

# Repeats every pre-trust check after the decision: the root, the staging
# directory, the staged tree and its reviewed commit, and its clean files.
# Usage: _zdx_plugins_revalidate_staged <reviewed-oid>
_zdx_plugins_revalidate_staged() {
  local reviewed_oid="${1-}" REPLY=""
  local plugin_name="${_zdx_plugins_tx[name]}" stage="${_zdx_plugins_tx[stage]}"
  if ! _zdx_plugins_root_unchanged \
    || ! _zdx_plugins_dir_identity "$stage" \
    || [[ "$REPLY" != "${_zdx_plugins_tx[stage_id]}" ]] \
    || ! _zdx_plugins_dir_identity "$stage/$plugin_name" \
    || [[ "$REPLY" != "${_zdx_plugins_tx[staged_id]}" ]] \
    || ! _zdx_plugins_head "$stage/$plugin_name" \
    || [[ "$REPLY" != "$reviewed_oid" ]] \
    || ! _zdx_plugins_checkout_clean "$stage/$plugin_name"; then
    _zdx_plugins_error "The reviewed plugin changed after the trust decision; nothing was activated."
    return 1
  fi
  _zdx_plugin_entrypoint_safe "$stage" "$stage/$plugin_name" \
    "$stage/$plugin_name/${plugin_name}-menu.zsh" \
    && _zdx_plugins_tree_links "$stage/$plugin_name" || {
    _zdx_plugins_error "The reviewed plugin changed after the trust decision; nothing was activated."
    return 1
  }
}

# --- Publication, activation, and rollback --------------------------------------

# Publishes the staged tree. An update first moves the active version into
# staging, so it stays intact until the new version is active. Each rename is
# atomic within the root; a failed second rename restores the first.
_zdx_plugins_publish() {
  local plugin_name="${_zdx_plugins_tx[name]}" stage="${_zdx_plugins_tx[stage]}"
  local root="${_zdx_plugins_session[root]}"
  local target="${_zdx_plugins_session[root]}/${_zdx_plugins_tx[name]}"
  if [[ "${_zdx_plugins_tx[mode]}" == update ]]; then
    if ! _zdx_plugins_move "$target" "$stage/previous" \
      "${_zdx_plugins_tx[active_id]}"; then
      if [[ -e "$stage/previous" || -L "$stage/previous" ]]; then
        _zdx_plugins_tx[phase]=swapping
      fi
      _zdx_plugins_error "Could not move the installed version of '$plugin_name' aside; nothing was activated."
      return 1
    fi
    _zdx_plugins_tx[phase]=swapping
  fi
  if _zdx_plugins_move "$stage/$plugin_name" "$target" \
    "${_zdx_plugins_tx[staged_id]}"; then
    _zdx_plugins_tx[phase]=published
    return 0
  fi
  _zdx_plugins_error "Could not publish the validated plugin '$plugin_name'."
  if [[ "${_zdx_plugins_tx[mode]}" == update ]]; then
    if _zdx_plugins_move "$stage/previous" "$target" \
      "${_zdx_plugins_tx[active_id]}"; then
      _zdx_plugins_tx[phase]=rolled-back
      _zdx_plugins_warn "The installed version of '$plugin_name' was restored unchanged."
    else
      _zdx_plugins_tx[phase]=stranded
    fi
  fi
  return 1
}

# Restores the state before publication: an install is unpublished into
# staging, and an update moves the failed tree aside and the previous version
# back. Identity checks prove each step; any doubt leaves it stranded.
_zdx_plugins_rollback() {
  local plugin_name="${_zdx_plugins_tx[name]}" stage="${_zdx_plugins_tx[stage]}"
  local target="${_zdx_plugins_session[root]}/${_zdx_plugins_tx[name]}"
  if ! _zdx_plugins_move "$target" "$stage/failed" \
    "${_zdx_plugins_tx[staged_id]}"; then
    _zdx_plugins_tx[phase]=stranded
    return 1
  fi
  if [[ "${_zdx_plugins_tx[mode]}" == update ]]; then
    if ! _zdx_plugins_move "$stage/previous" "$target" \
      "${_zdx_plugins_tx[active_id]}"; then
      _zdx_plugins_tx[phase]=stranded
      return 1
    fi
  fi
  _zdx_plugins_tx[phase]=rolled-back
}

# Sources a published entrypoint into this shell after the loader's checks,
# the way the loader would. Nothing on this call path uses emulate or
# LOCAL_OPTIONS, so the plugin's top-level options and definitions persist as
# they would at shell start. Plugin source-time output goes to stderr.
# Usage: _zdx_plugins_activate <root> <plugin-name>
_zdx_plugins_activate() {
  local _zdx_plugins_activate_dir="$1/$2" _zdx_plugins_activate_name="$2"
  local _zdx_plugins_activate_entry="$1/$2/$2-menu.zsh"
  local -i _zdx_plugins_activate_rc=0
  if ! _zdx_plugin_entrypoint_safe "$1" "$_zdx_plugins_activate_dir" \
    "$_zdx_plugins_activate_entry"; then
    _zdx_plugins_error "The published entrypoint failed the loader's path checks."
    return 1
  fi
  # Staging already showed any syntax diagnostics; this repeat is the loader's.
  if ! command zsh -n -- "$_zdx_plugins_activate_entry" >/dev/null 2>&1; then
    _zdx_plugins_error "Ecosystem Contract Violation: Syntax error in '$2-menu.zsh'."
    return 1
  fi
  # Repeat the path boundary immediately before source, as the loader does.
  _zdx_plugin_entrypoint_safe "$1" "$_zdx_plugins_activate_dir" \
    "$_zdx_plugins_activate_entry" || {
    _zdx_plugins_error "The published plugin changed during validation."
    return 1
  }
  source "$_zdx_plugins_activate_entry" >&2 || _zdx_plugins_activate_rc=$?
  if (( _zdx_plugins_activate_rc != 0 )); then
    _zdx_plugins_error "Sourcing '${_zdx_plugins_activate_name}-menu.zsh' failed with status $_zdx_plugins_activate_rc."
    return 1
  fi
  if (( ! ${+functions[${_zdx_plugins_activate_name}-menu]} )); then
    _zdx_plugins_error "Ecosystem Contract Violation: Function '${_zdx_plugins_activate_name}-menu' was not defined after sourcing."
    return 1
  fi
}

# Activates the published tree and, when activation fails, rolls the files
# back and restores the menu function and the conventional source sentinel
# that activation replaced. Other definitions the failed source made cannot
# be undone, so the user is told to open a new shell. State that must survive
# the plugin's own top-level code lives in the namespaced transaction map.
_zdx_plugins_activate_published() {
  _zdx_plugins_tx[sentinel]="${_zdx_plugins_tx[name]//-/_}"
  _zdx_plugins_tx[sentinel]="_${(U)_zdx_plugins_tx[sentinel]}_MENU_SOURCED"
  _zdx_plugins_tx[had_function]=0
  _zdx_plugins_tx[had_sentinel]=0
  if (( ${+functions[${_zdx_plugins_tx[name]}-menu]} )); then
    _zdx_plugins_tx[had_function]=1
    _zdx_plugins_tx[saved_function]="${functions[${_zdx_plugins_tx[name]}-menu]}"
  fi
  if (( ${+parameters[${_zdx_plugins_tx[sentinel]}]} )); then
    _zdx_plugins_tx[had_sentinel]=1
    _zdx_plugins_tx[saved_sentinel]="${(P)_zdx_plugins_tx[sentinel]}"
  fi
  # A reload clears the plugin's documented idempotency sentinel, so its
  # guard does not turn the new source into a no-op.
  unset -- "${_zdx_plugins_tx[sentinel]}" 2>/dev/null

  if _zdx_plugins_activate "${_zdx_plugins_session[root]}" \
    "${_zdx_plugins_tx[name]}"; then
    _zdx_plugins_tx[phase]=activated
    _zdx_plugins_loaded "${_zdx_plugins_tx[name]}" \
      || ZDX_LOADED_PLUGINS+=("${_zdx_plugins_tx[name]}")
    return 0
  fi

  local plugin_name="${_zdx_plugins_tx[name]}"
  if [[ "${_zdx_plugins_tx[had_function]}" == 1 ]]; then
    functions[${plugin_name}-menu]="${_zdx_plugins_tx[saved_function]}"
  else
    unfunction -- "${plugin_name}-menu" 2>/dev/null
  fi
  if [[ "${_zdx_plugins_tx[had_sentinel]}" == 1 ]]; then
    typeset -g "${_zdx_plugins_tx[sentinel]}=${_zdx_plugins_tx[saved_sentinel]}"
  else
    unset -- "${_zdx_plugins_tx[sentinel]}" 2>/dev/null
  fi
  if _zdx_plugins_rollback; then
    if [[ "${_zdx_plugins_tx[mode]}" == update ]]; then
      _zdx_plugins_warn "Rolled back '$plugin_name' to ${_zdx_plugins_tx[active_oid][1,7]}; its files are unchanged."
    else
      _zdx_plugins_warn "Rolled back: '$plugin_name' was not installed."
    fi
  fi
  _zdx_plugins_warn "The failed source may have left definitions in this shell; open a new shell to load plugins cleanly."
  return 1
}

# --- Fetch and review -----------------------------------------------------------

# Clones one origin into staging with captured, credential-redacted output.
# Usage: _zdx_plugins_fetch <origin> <origin-display> <destination> <clone-options...>
_zdx_plugins_fetch() {
  local origin="${1-}" origin_display="${2-}" destination="${3-}" REPLY=""
  shift 3
  _zdx_plugins_tilde "$destination"
  local display="git clone ${(j: :)@} --no-recurse-submodules -- $origin_display $REPLY"
  local -i fetch_rc=0
  _zdx_run_captured "$display" "" "" _zdx_plugins_git_network clone "$@" \
    --no-recurse-submodules -- "$origin" "$destination" || fetch_rc=$?
  (( fetch_rc == 0 )) && return 0
  (( fetch_rc == 130 || fetch_rc == 143 )) && return $fetch_rc
  _zdx_plugins_error "Could not fetch the plugin from its origin."
  return 1
}

# Prints the facts of the trust decision and the arbitrary-code disclosure.
# Status 1 refuses a commit whose signature is bad, whatever the decision.
# Usage: _zdx_plugins_review <repository> <new-oid>
#          [<old-oid> <old-commit-line> <relation> <count>]
_zdx_plugins_review() {
  local repository="${1-}" new_oid="${2-}" old_oid="${3-}"
  local old_line="${4-}" relation="${5-}" count="${6-}" REPLY=""
  local -a reply=()
  _zdx_plugins_section "Trust decision"
  [[ -n "$old_oid" ]] && _zdx_plugins_label "Installed" "$old_line"
  _zdx_plugins_commit_line "$repository" "$new_oid"
  _zdx_plugins_label "New commit" "$REPLY"
  # The full object ID is the exact identity to compare with the origin; an
  # abbreviated one can be forged.
  _zdx_plugins_label "Commit ID" "$new_oid"
  if [[ -n "$old_oid" ]]; then
    local commits="unknown"
    if [[ "$count" == <-> ]]; then
      _zdx_plugins_count_noun "$count" commit
      commits="$REPLY"
    fi
    case "$relation" in
      fast-forward) _zdx_plugins_label "Commits" "$commits (fast-forward)" ;;
      rewritten)    _zdx_plugins_label "Commits" "$commits (history rewritten)" ;;
      *)            _zdx_plugins_label "Commits" "unknown (installed commit not in the fetched history)" ;;
    esac
  fi
  _zdx_plugins_signature "$repository" "$new_oid"
  local signature_class="${reply[1]}"
  _zdx_plugins_label "Signature" "$REPLY"
  _zdx_plugins_label "Validation" "passed (layout, ownership, links, entrypoint, Zsh syntax)"
  if [[ -n "$old_oid" && "$relation" != unknown ]]; then
    _zdx_plugins_show_incoming "$repository" "$old_oid" "$new_oid" "$count"
  fi
  if [[ "$signature_class" == bad ]]; then
    _zdx_plugins_error "The new commit carries a bad signature; refusing to activate it."
    return 1
  fi
  if [[ -n "$old_oid" && "$relation" != fast-forward ]]; then
    _zdx_plugins_warn "The new commit does not descend from the installed commit; review the origin before you trust it."
  fi
  _zdx_plugins_warn "Activating runs this plugin's code in your current shell with your full user privileges; it is not sandboxed."
}

# --- Install --------------------------------------------------------------------

_zdx_plugins_install() {
  local url="${1-}" plugin_name="${2-}" dry_run="${3:-no}" auto_yes="${4:-no}"
  if [[ -z "$url" ]]; then
    _zdx_plugins_error "Git repository URL is required."
    return 2
  fi
  if ! _zdx_plugins_url_valid "$url"; then
    _zdx_plugins_error "Invalid Git URL: it must not be empty, start with '-', or contain control characters."
    return 2
  fi
  if [[ -z "$plugin_name" ]]; then
    plugin_name="${url%/}"
    plugin_name="${plugin_name:t}"
    plugin_name="${plugin_name%.git}"
  fi
  if ! _zdx_plugins_name_valid "$plugin_name"; then
    _zdx_plugins_error "Plugin name '$plugin_name' is invalid. Must match '^[a-z0-9_-]+$' (lowercase, numbers, dashes, underscores)."
    _zdx_plugins_dim "Pass a valid name after the URL, such as: zdx-plugins --install <url> my-plugin"
    return 2
  fi
  _zdx_plugins_require_git || return 1
  _zdx_plugins_require_authorization "$dry_run" "$auto_yes" || return 1

  local -A _zdx_plugins_session=() _zdx_plugins_tx=()
  local -i install_rc=0
  {
    if _zdx_plugins_session_open yes; then
      _zdx_plugins_install_locked "$url" "$plugin_name" "$dry_run" \
        "$auto_yes" || install_rc=$?
    else
      install_rc=1
    fi
  } always {
    _zdx_plugins_tx_close || install_rc=1
    _zdx_plugins_unlock
  }
  return $install_rc
}

_zdx_plugins_install_locked() {
  local url="$1" plugin_name="$2" dry_run="$3" auto_yes="$4" REPLY=""
  local root="${_zdx_plugins_session[root]}"
  local target="${_zdx_plugins_session[root]}/$2"
  local -a reply=()
  _zdx_plugins_tilde "$target"
  local target_display="$REPLY"
  if [[ -e "$target" || -L "$target" ]]; then
    _zdx_plugins_warn "Plugin '$plugin_name' already exists at $target_display. Use '--update' to refresh it."
    return 1
  fi
  _zdx_plugins_redact_url "$url"
  local origin_display="$REPLY"

  _zdx_plugins_header "Install Plugin"
  _zdx_plugins_label "Plugin" "$plugin_name"
  _zdx_plugins_label "Origin" "$origin_display"
  _zdx_plugins_label "Destination" "$target_display"

  _zdx_plugins_tx_open "$plugin_name" || return 1
  _zdx_plugins_tx[mode]=install
  local stage="${_zdx_plugins_tx[stage]}"
  _zdx_plugins_fetch "$url" "$origin_display" "$stage/$plugin_name" \
    --depth 1 || return
  _zdx_plugins_tree_validate "$stage" "$plugin_name" || return 1
  if ! _zdx_plugins_head "$stage/$plugin_name"; then
    _zdx_plugins_error "The fetched repository has no commit to install."
    return 1
  fi
  local new_oid="$REPLY"
  _zdx_plugins_dir_identity "$stage/$plugin_name" || return 1
  _zdx_plugins_tx[staged_id]="$REPLY"

  _zdx_plugins_review "$stage/$plugin_name" "$new_oid" || return 1
  if [[ "$dry_run" == yes ]]; then
    _zdx_plugins_info "Dry run: '$plugin_name' at ${new_oid[1,7]} planned; nothing was installed."
    return 0
  fi
  local -i confirm_rc=0
  _zdx_plugins_confirm "Trust and activate '$plugin_name' at ${new_oid[1,7]}?" \
    "$auto_yes" || confirm_rc=$?
  case "$confirm_rc" in
    0) [[ "$auto_yes" == yes ]] && _zdx_plugins_info "Trusted with --yes." ;;
    1)
      _zdx_plugins_info "Cancelled: nothing was installed."
      return 0
      ;;
    *)
      _zdx_plugins_error "The trust decision needs a terminal; pass --yes to proceed."
      return 1
      ;;
  esac

  _zdx_plugins_revalidate_staged "$new_oid" || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    _zdx_plugins_error "Plugin '$plugin_name' appeared during review; nothing was installed."
    return 1
  fi
  _zdx_plugins_publish || return 1
  _zdx_plugins_activate_published || return 1
  _zdx_plugins_success "Plugin '$plugin_name' installed and activated at ${new_oid[1,7]}."
}

# --- Update ---------------------------------------------------------------------

# Updates one installed plugin inside an open session and always ends its
# transaction, so each plugin of an aggregate cleans its own staging before
# the next one starts. A step records its outcome; a standalone run prints it.
_zdx_plugins_update_one() {
  local -i _zdx_plugins_update_rc=0
  {
    _zdx_plugins_update_staged "$@" || _zdx_plugins_update_rc=$?
  } always {
    _zdx_plugins_tx_close || _zdx_plugins_update_rc=1
  }
  return $_zdx_plugins_update_rc
}

_zdx_plugins_update_staged() {
  local plugin_name="${1-}" dry_run="${2:-no}" auto_yes="${3:-no}" REPLY=""
  local root="${_zdx_plugins_session[root]}"
  local target="${_zdx_plugins_session[root]}/${1-}"
  local -a reply=()
  _zdx_plugins_tilde "$target"
  local target_display="$REPLY"

  if ! _zdx_plugins_dir_identity "$target"; then
    _zdx_plugins_fail failed "not installed" \
      "Plugin '$plugin_name' is not installed."
    return
  fi
  local active_id="$REPLY"
  if [[ ! -d "$target/.git" || -L "$target/.git" ]]; then
    _zdx_plugins_report_result skipped "not Git-tracked" info \
      "Plugin '$plugin_name' is not Git-tracked; nothing to update."
    return 0
  fi

  local toplevel="" branch="" upstream="" remote_branch="" origin=""
  toplevel=$(_zdx_plugins_git -C "$target" rev-parse --show-toplevel \
    2>/dev/null) || toplevel=""
  if [[ "$toplevel" != "$target" ]]; then
    _zdx_plugins_fail blocked "not a repository root" \
      "Plugin '$plugin_name' is not the root of its own Git repository."
    return
  fi
  if ! _zdx_plugins_head "$target"; then
    _zdx_plugins_fail blocked "no commit" \
      "Plugin '$plugin_name' has no commit to update from."
    return
  fi
  local old_oid="$REPLY"
  branch=$(_zdx_plugins_git -C "$target" symbolic-ref --quiet --short HEAD \
    2>/dev/null) || branch=""
  if [[ -z "$branch" ]]; then
    _zdx_plugins_fail blocked "detached HEAD" \
      "Plugin '$plugin_name' is on a detached commit; check out its branch to update it."
    return
  fi
  upstream=$(_zdx_plugins_git -C "$target" rev-parse --symbolic-full-name \
    '@{upstream}' 2>/dev/null) || upstream=""
  remote_branch="$branch"
  [[ "$upstream" == refs/remotes/origin/?* ]] \
    && remote_branch="${upstream#refs/remotes/origin/}"
  if [[ "$remote_branch" == -* ]] \
    || ! _zdx_plugins_git check-ref-format "refs/heads/$remote_branch" \
      2>/dev/null; then
    _zdx_plugins_fail blocked "invalid branch" \
      "Plugin '$plugin_name' tracks a branch name Git does not accept."
    return
  fi
  origin=$(_zdx_plugins_git -C "$target" config --get remote.origin.url \
    2>/dev/null) || origin=""
  if ! _zdx_plugins_url_valid "$origin"; then
    _zdx_plugins_fail blocked "no usable origin" \
      "Plugin '$plugin_name' has no usable 'origin' remote URL."
    return
  fi
  if ! _zdx_plugins_checkout_clean "$target"; then
    local change=""
    for change in "${reply[@]}"; do
      _zdx_plugins_dim "$change"
    done
    _zdx_plugins_fail blocked "local changes" \
      "Plugin '$plugin_name' has local, untracked, or ignored files; commit, move, or remove them before updating."
    return
  fi
  _zdx_plugins_redact_url "$origin"
  local origin_display="$REPLY"

  _zdx_plugins_header "Update Plugin: $plugin_name"
  _zdx_plugins_label "Plugin" "$target_display"
  _zdx_plugins_label "Origin" "$origin_display"
  _zdx_plugins_label "Branch" "$remote_branch"

  _zdx_plugins_tx_open "$plugin_name" || {
    _zdx_plugins_fail failed "staging failed" \
      "Could not stage an update for '$plugin_name'."
    return
  }
  _zdx_plugins_tx[mode]=update
  _zdx_plugins_tx[active_id]="$active_id"
  _zdx_plugins_tx[active_oid]="$old_oid"
  local stage="${_zdx_plugins_tx[stage]}"
  local staged="${_zdx_plugins_tx[stage]}/${1-}"
  local -i step_rc=0
  _zdx_plugins_fetch "$origin" "$origin_display" "$staged" --single-branch \
    --branch "$remote_branch" || step_rc=$?
  if (( step_rc != 0 )); then
    (( step_rc == 130 || step_rc == 143 )) && return $step_rc
    _zdx_plugins_report_result failed "fetch failed" error \
      "Plugin '$plugin_name' was not updated."
    return 1
  fi
  if ! _zdx_plugins_head "$staged"; then
    _zdx_plugins_fail failed "validation failed" \
      "The fetched update has no usable commit; '$plugin_name' is unchanged."
    return
  fi
  local new_oid="$REPLY"
  if [[ "$new_oid" == "$old_oid" ]]; then
    _zdx_plugins_report_result current "${old_oid[1,7]}" success \
      "Plugin '$plugin_name' is current at ${old_oid[1,7]}."
    return 0
  fi
  if ! _zdx_plugins_tree_validate "$stage" "$plugin_name" \
    || ! _zdx_plugins_dir_identity "$staged"; then
    _zdx_plugins_fail failed "validation failed" \
      "The fetched update failed validation; '$plugin_name' is unchanged."
    return
  fi
  _zdx_plugins_tx[staged_id]="$REPLY"

  _zdx_plugins_transition "$staged" "$old_oid" "$new_oid"
  local relation="${reply[1]}" count="${reply[2]}"
  local transition="${old_oid[1,7]} → ${new_oid[1,7]}"
  if [[ "$count" == <-> ]]; then
    _zdx_plugins_count_noun "$count" commit
    transition+=" · $REPLY"
  fi
  _zdx_plugins_commit_line "$target" "$old_oid"
  if ! _zdx_plugins_review "$staged" "$new_oid" "$old_oid" "$REPLY" \
    "$relation" "$count"; then
    _zdx_plugins_report_result blocked "bad signature" error \
      "Plugin '$plugin_name' was not updated."
    return 1
  fi
  if [[ "$dry_run" == yes ]]; then
    _zdx_plugins_report_result planned "$transition" info \
      "Dry run: '$plugin_name' $transition planned; nothing was activated."
    return 0
  fi
  local -i confirm_rc=0
  _zdx_plugins_confirm \
    "Trust and activate '$plugin_name' at ${new_oid[1,7]}?" "$auto_yes" \
    || confirm_rc=$?
  case "$confirm_rc" in
    0) [[ "$auto_yes" == yes ]] && _zdx_plugins_info "Trusted with --yes." ;;
    1)
      _zdx_plugins_report_result skipped "declined" info \
        "Cancelled: '$plugin_name' was not updated."
      return 0
      ;;
    *)
      _zdx_plugins_fail blocked "no terminal" \
        "The trust decision needs a terminal; pass --yes to proceed."
      return
      ;;
  esac

  # The active checkout must still be exactly the reviewed one.
  if ! _zdx_plugins_revalidate_staged "$new_oid" \
    || ! _zdx_plugins_dir_identity "$target" \
    || [[ "$REPLY" != "$active_id" ]] \
    || ! _zdx_plugins_head "$target" || [[ "$REPLY" != "$old_oid" ]] \
    || ! _zdx_plugins_checkout_clean "$target"; then
    _zdx_plugins_fail failed "changed after review" \
      "Plugin '$plugin_name' changed after the trust decision; nothing was activated."
    return
  fi
  if ! _zdx_plugins_publish; then
    _zdx_plugins_report_result failed "publication failed" error \
      "Plugin '$plugin_name' was not updated."
    return 1
  fi
  if ! _zdx_plugins_activate_published; then
    _zdx_plugins_report_result failed "activation failed; rolled back" error \
      "Plugin '$plugin_name' was not updated."
    return 1
  fi
  _zdx_plugins_report_result updated "$transition" success \
    "Plugin '$plugin_name' updated ($transition) and sourced in this shell."
}

_zdx_plugins_update() {
  local plugin_name="${1-}" dry_run="${2:-no}" auto_yes="${3:-no}"
  if ! _zdx_plugins_name_valid "$plugin_name"; then
    _zdx_plugins_error "Invalid plugin name: '$plugin_name'."
    return 2
  fi
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  if [[ ! -e "$plugins_dir" && ! -L "$plugins_dir" ]]; then
    _zdx_plugins_error "Plugin '$plugin_name' is not installed."
    return 1
  fi
  _zdx_plugins_require_git || return 1
  _zdx_plugins_require_authorization "$dry_run" "$auto_yes" || return 1

  local -A _zdx_plugins_session=() _zdx_plugins_tx=()
  local -i update_rc=0
  {
    if _zdx_plugins_session_open no; then
      _zdx_plugins_update_one "$plugin_name" "$dry_run" "$auto_yes" \
        || update_rc=$?
    else
      update_rc=1
    fi
  } always {
    _zdx_plugins_tx_close || update_rc=1
    _zdx_plugins_unlock
  }
  return $update_rc
}

# reply: the valid plugin directory names below a canonical root, sorted.
# Without GLOB_DOTS the manager's dot-named staging is never listed.
_zdx_plugins_names() {
  emulate -L zsh
  local root="${1-}" entry=""
  reply=()
  for entry in "$root"/*(N/); do
    _zdx_plugins_name_valid "${entry:t}" && reply+=("${entry:t}")
  done
  return 0
}

_zdx_plugins_update_all() {
  local dry_run="${1:-no}" auto_yes="${2:-no}"
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  if [[ ! -e "$plugins_dir" && ! -L "$plugins_dir" ]]; then
    _zdx_plugins_info "No plugins are installed."
    return 0
  fi
  _zdx_plugins_require_git || return 1
  _zdx_plugins_require_authorization "$dry_run" "$auto_yes" || return 1

  local -A _zdx_plugins_session=() _zdx_plugins_tx=()
  local -i update_rc=0
  {
    if _zdx_plugins_session_open no; then
      _zdx_plugins_update_all_locked "$dry_run" "$auto_yes" || update_rc=$?
    else
      update_rc=1
    fi
  } always {
    _zdx_plugins_tx_close || update_rc=1
    _zdx_plugins_unlock
  }
  return $update_rc
}

# One step per plugin: each fetches into its own staging and asks for its
# own trust decision, then the summary, verdict, and retry hints follow.
_zdx_plugins_update_all_locked() {
  local dry_run="$1" auto_yes="$2" REPLY=""
  local root="${_zdx_plugins_session[root]}"
  local -a reply=() plugin_names=()
  _zdx_plugins_names "$root"
  plugin_names=("${reply[@]}")
  if (( ${#plugin_names} == 0 )); then
    _zdx_plugins_info "No plugins are installed."
    return 0
  fi

  local -i total=${#plugin_names} index=0
  local plugin_name="" origin=""
  local -a rows=()
  for (( index = 1; index <= total; index++ )); do
    plugin_name="${plugin_names[index]}"
    origin="(not Git-tracked)"
    if [[ -d "$root/$plugin_name/.git" && ! -L "$root/$plugin_name/.git" ]]; then
      origin=$(_zdx_plugins_git -C "$root/$plugin_name" config --get \
        remote.origin.url 2>/dev/null) || origin=""
      _zdx_plugins_redact_url "${origin:-(no origin)}"
      _zdx_plugins_display_field "$REPLY"
      origin="$REPLY"
    fi
    rows+=("$index"$'\t'"$plugin_name"$'\t'"$origin")
  done
  _zdx_plugins_header "Update Plugins"
  _zdx_ui_table $'#\tPlugin\tOrigin' "${rows[@]}"
  _zdx_plugins_warn "Each update fetches its origin over the network; nothing is activated before its own trust decision."
  if [[ "$dry_run" == yes ]]; then
    _zdx_plugins_info "Dry run: updates are fetched and validated, never activated."
  elif [[ "$auto_yes" == yes ]]; then
    _zdx_plugins_warn "--yes trusts every changed plugin without a prompt."
  fi

  local -a records=() hints=()
  local outcome="" detail="" seconds="" hint=""
  local -i step_rc=0 failed=0 stopped=0 updated=0 current=0 planned=0
  local -i skipped=0
  for (( index = 1; index <= total; index++ )); do
    plugin_name="${plugin_names[index]}"
    if (( stopped )); then
      records+=("$plugin_name"$'\t'"not-run"$'\t\t'"update interrupted")
      continue
    fi
    _zdx_ui_step_banner "$index" "$total" "$plugin_name"
    step_rc=0
    reply=()
    _zdx_step_exec _zdx_plugins_update_one "$plugin_name" "$dry_run" \
      "$auto_yes" || step_rc=$?
    outcome="${reply[1]:-failed}" detail="${reply[2]-}" seconds="${reply[3]-}"
    _zdx_ui_step_result "$index" "$total" "$plugin_name" "$outcome" \
      "$detail" "$seconds"
    records+=("$plugin_name"$'\t'"$outcome"$'\t'"$seconds"$'\t'"$detail")
    case "$outcome" in
      updated) (( updated++ )) ;;
      current) (( current++ )) ;;
      planned) (( planned++ )) ;;
      skipped) (( skipped++ )) ;;
      failed|blocked|timed-out|interrupted)
        (( failed++ ))
        hint="zdx-plugins --update $plugin_name"
        [[ "$dry_run" == yes ]] && hint+=" --dry-run"
        hints+=("$hint")
        ;;
    esac
    if (( step_rc == 130 || step_rc == 143 )); then
      stopped=$step_rc
    fi
  done

  _zdx_ui_step_summary --first-column Plugin "Plugin Update Summary" \
    "${records[@]}"
  local -a parts=()
  (( updated )) && parts+=("$updated updated")
  (( current )) && parts+=("$current current")
  (( planned )) && parts+=("$planned planned")
  (( skipped )) && parts+=("$skipped skipped")
  _zdx_plugins_count_noun "$total" plugin
  local plugin_count="$REPLY"
  (( ${#parts} > 0 )) || parts=("$plugin_count checked")
  if (( stopped )); then
    _zdx_plugins_error "Plugin update was interrupted."
  elif (( failed == total )); then
    _zdx_plugins_error "Plugin update failed: $failed of $plugin_count failed."
  elif (( failed > 0 )); then
    _zdx_plugins_warn "Plugin update completed with partial failures: $failed of $plugin_count failed."
  else
    _zdx_plugins_success "Plugin update completed: ${(j:, :)parts}."
  fi
  for hint in "${hints[@]}"; do
    _zdx_plugins_dim "Retry: $hint"
  done
  (( stopped )) && return $stopped
  (( failed == 0 ))
}

# --- Remove ---------------------------------------------------------------------

_zdx_plugins_remove() {
  local plugin_name="${1-}" dry_run="${2:-no}" auto_yes="${3:-no}"
  if [[ -z "$plugin_name" ]]; then
    _zdx_plugins_error "Plugin name is required."
    return 2
  fi
  if ! _zdx_plugins_name_valid "$plugin_name"; then
    _zdx_plugins_error "Invalid plugin name: '$plugin_name'. Names match '^[a-z0-9_-]+$', so no path can leave the plugin root."
    return 2
  fi
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  if [[ ! -e "$plugins_dir" && ! -L "$plugins_dir" ]]; then
    _zdx_plugins_error "Plugin '$plugin_name' is not installed."
    return 1
  fi
  _zdx_plugins_require_authorization "$dry_run" "$auto_yes" || return 1

  local -A _zdx_plugins_session=() _zdx_plugins_tx=()
  local -i remove_rc=0
  {
    if _zdx_plugins_session_open no; then
      _zdx_plugins_remove_locked "$plugin_name" "$dry_run" "$auto_yes" \
        || remove_rc=$?
    else
      remove_rc=1
    fi
  } always {
    _zdx_plugins_tx_close || remove_rc=1
    _zdx_plugins_unlock
  }
  return $remove_rc
}

# Exact plan, confirmation, revalidation, then a quarantine rename into
# staging before the recursive deletion, so the plugin directory disappears
# atomically and the deletion only ever touches the reviewed directory.
_zdx_plugins_remove_locked() {
  local plugin_name="$1" dry_run="$2" auto_yes="$3" REPLY=""
  local target="${_zdx_plugins_session[root]}/$1"
  if ! _zdx_plugins_dir_identity "$target"; then
    _zdx_plugins_error "Plugin '$plugin_name' is not installed."
    return 1
  fi
  local target_id="$REPLY"
  _zdx_plugins_tilde "$target"
  local target_display="$REPLY"

  _zdx_plugins_header "Remove Plugin"
  _zdx_plugins_label "Plugin" "$plugin_name"
  _zdx_plugins_label "Path" "$target_display"
  if [[ -d "$target/.git" && ! -L "$target/.git" ]] \
    && command -v git >/dev/null 2>&1; then
    local origin=""
    origin=$(_zdx_plugins_git -C "$target" config --get remote.origin.url \
      2>/dev/null) || origin=""
    if [[ -n "$origin" ]]; then
      _zdx_plugins_redact_url "$origin"
      _zdx_plugins_label "Origin" "$REPLY"
    fi
    _zdx_plugins_head "$target" && _zdx_plugins_label "Commit" "${REPLY[1,7]}"
  fi
  if _zdx_plugins_loaded "$plugin_name"; then
    _zdx_plugins_label "Loaded" "yes; its other functions stay defined until a new shell"
  fi
  _zdx_plugins_warn "The plugin directory and everything in it will be deleted."
  if [[ "$dry_run" == yes ]]; then
    _zdx_plugins_info "Dry run: 1 plugin planned; nothing was removed."
    return 0
  fi
  local -i confirm_rc=0
  _zdx_plugins_confirm "Remove plugin '$plugin_name'?" "$auto_yes" \
    || confirm_rc=$?
  case "$confirm_rc" in
    0) ;;
    1)
      _zdx_plugins_info "Cancelled: nothing was removed."
      return 0
      ;;
    *)
      _zdx_plugins_error "Removal needs a terminal for confirmation; pass --yes to proceed."
      return 1
      ;;
  esac

  if ! _zdx_plugins_root_unchanged \
    || ! _zdx_plugins_dir_identity "$target" \
    || [[ "$REPLY" != "$target_id" ]]; then
    _zdx_plugins_error "Plugin '$plugin_name' changed after review; nothing was removed."
    return 1
  fi
  _zdx_plugins_tx_open "$plugin_name" || return 1
  _zdx_plugins_tx[mode]=remove
  local stage="${_zdx_plugins_tx[stage]}"
  if ! _zdx_plugins_move "$target" "$stage/removed" "$target_id"; then
    _zdx_plugins_error "Could not move plugin '$plugin_name' out of the plugin root; nothing was removed."
    [[ -e "$stage/removed" || -L "$stage/removed" ]] \
      && _zdx_plugins_tx[phase]=stranded
    return 1
  fi
  _zdx_plugins_tx[phase]=removed

  # The plugin is gone from the root: unregister it and its menu function.
  if _zdx_plugins_loaded "$plugin_name"; then
    ZDX_LOADED_PLUGINS=("${(@)ZDX_LOADED_PLUGINS:#$plugin_name}")
  fi
  unfunction -- "${plugin_name}-menu" 2>/dev/null

  if ! _zdx_plugins_remove_stage "$stage" "${_zdx_plugins_session[root]}" \
    "${_zdx_plugins_tx[stage_id]}"; then
    _zdx_plugins_tilde "$stage"
    _zdx_plugins_error "Plugin '$plugin_name' left the plugin root, but some files could not be deleted; remove $REPLY manually."
    _zdx_plugins_tx=()
    return 1
  fi
  _zdx_plugins_tx=()
  _zdx_plugins_success "Plugin '$plugin_name' removed."
}

# --- List -------------------------------------------------------------------------

_zdx_plugins_list() {
  emulate -L zsh
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}" REPLY=""
  if [[ ! -e "$plugins_dir" && ! -L "$plugins_dir" ]]; then
    print -u2 -r -- "No plugins installed."
    return 0
  fi
  if (( ${+functions[_zdx_plugin_root_resolve]} )); then
    _zdx_plugin_root_resolve "$plugins_dir" || {
      _zdx_plugins_error "Refusing an unsafe plugin root: $plugins_dir"
      return 1
    }
    plugins_dir="$REPLY"
  fi

  local -a subdirs=("$plugins_dir"/*(N/))
  local -a stale=("$plugins_dir"/.zdx-staging.*(DN))
  if (( ${#subdirs} == 0 )); then
    print -u2 -r -- "No plugins installed."
  else
    if _zdx_plugins_color_enabled; then
      printf '\033[1;34m%-20s %-10s %s\033[0m\n' "Plugin Name" "Status" "Git Remote Origin" >&2
    else
      printf '%-20s %-10s %s\n' "Plugin Name" "Status" "Git Remote Origin" >&2
    fi
    printf '%s\n' "────────────────────────────────────────────────────────────────────────────────" >&2

    local subdir="" plugin_name="" plugin_status="" origin="" git_origin=""
    local status_color=""
    for subdir in "${subdirs[@]}"; do
      plugin_name="${subdir:t}"
      plugin_status="Invalid"
      origin="Local"
      if _zdx_plugins_name_valid "$plugin_name" \
        && [[ -f "$subdir/${plugin_name}-menu.zsh" \
          && -r "$subdir/${plugin_name}-menu.zsh" ]]; then
        plugin_status="Inactive"
        _zdx_plugins_loaded "$plugin_name" && plugin_status="Active"
      fi
      if [[ -d "$subdir/.git" && ! -L "$subdir/.git" ]] \
        && command -v git >/dev/null 2>&1; then
        git_origin=$(_zdx_plugins_git -C "$subdir" config --get \
          remote.origin.url 2>/dev/null) || git_origin=""
        if [[ -n "$git_origin" ]]; then
          _zdx_plugins_redact_url "$git_origin"
          origin="$REPLY"
        fi
      fi
      if _zdx_plugins_color_enabled; then
        case "$plugin_status" in
          Active)   status_color=$'\e[1;32m' ;;
          Inactive) status_color=$'\e[1;33m' ;;
          *)        status_color=$'\e[1;31m' ;;
        esac
        printf '%-20s %s%-10s\033[0m %s\n' "${(V)plugin_name}" \
          "$status_color" "$plugin_status" "${(V)origin}" >&2
      else
        printf '%-20s %-10s %s\n' "${(V)plugin_name}" "$plugin_status" \
          "${(V)origin}" >&2
      fi
    done
  fi
  if (( ${#stale} > 0 )); then
    _zdx_plugins_warn "An interrupted plugin transaction left staging in the plugin root; the next install, update, or remove recovers it."
  fi
  return 0
}

# --- Interactive menu -------------------------------------------------------------

# A stateful manager loop. Every picker runs in the foreground through the
# private capture, and only an exact row of the current snapshot dispatches.
# The loop sets no local options, because actions source plugin code.
_zdx_plugins_menu() {
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  while true; do
    local -a options=(
      "$(_zdx_plugins_menu_section "Plugin Manager" "List, install, update, and remove custom plugins.")"
      "$(_zdx_plugins_menu_entry "List Installed Plugins" "list" "Show installed plugins, their status, and their origin.")"
      "$(_zdx_plugins_menu_entry "Install New Plugin" "install" "Fetch a plugin from a Git URL, review its commit, and activate it after your trust decision.")"
      "$(_zdx_plugins_menu_entry "Update Installed Plugins" "update" "Stage each update, review the exact commits, and activate only what you trust.")"
      "$(_zdx_plugins_menu_entry "Uninstall Plugin" "remove" "Review and remove one installed plugin.")"
    )

    local -a fzf_opts=(
      --height=50%
      --layout=reverse
      --border=rounded
      --delimiter='[|]'
      --with-nth=1
      --pointer='▶'
      --prompt='Plugins > '
      --header=$'Select a plugin action\n[Enter] Select  [Esc] Exit'
    )

    # In-loop locals keep an initializer: re-declaring an existing local
    # without one makes zsh print the variable on every later iteration.
    local selected=""
    local -i fzf_rc=0
    _zdx_plugins_fzf_capture "${fzf_opts[@]}" \
      < <(printf '%s\n' "${options[@]}") || fzf_rc=$?
    selected="$REPLY"
    if (( fzf_rc != 0 )); then
      (( fzf_rc == 1 || fzf_rc == 130 )) && return 0
      _zdx_plugins_error "Unable to open the plugin menu (status $fzf_rc)."
      return 1
    fi
    [[ -z "$selected" ]] && return 0
    if ! _zdx_plugins_row_in_snapshot "$selected" "${options[@]}"; then
      _zdx_plugins_error "The selected action was not in the plugin menu snapshot."
      return 1
    fi

    local action="${${selected#*|}%%|*}"
    [[ "$action" == ":" ]] && continue

    case "$action" in
      list)
        _zdx_plugins_header "Installed Plugins"
        _zdx_plugins_list
        ;;
      install)
        _zdx_plugins_header "Install New Plugin"
        printf '? Enter Git Repository URL: ' >&2
        local url=""
        read -r url
        if [[ -n "$url" ]]; then
          printf '? Enter Custom Name (optional): ' >&2
          local custom_name=""
          read -r custom_name
          _zdx_plugins_install "$url" "$custom_name" no no
        else
          _zdx_plugins_warn "No URL entered. Installation canceled."
        fi
        ;;
      update)
        _zdx_plugins_update_all no no
        ;;
      remove)
        _zdx_plugins_menu_remove "$plugins_dir"
        ;;
    esac

    if _zdx_plugins_terminal; then
      printf '\n%s\n' "Press any key to return to Plugins menu..." >&2
      read -k1
    fi
  done
}

# Picks one installed plugin from a frozen snapshot of valid names.
_zdx_plugins_menu_remove() {
  local plugins_dir="${1-}" REPLY=""
  local -a reply=() plugin_names=()
  _zdx_plugins_header "Uninstall Plugin"
  if [[ -d "$plugins_dir" ]] && (( ${+functions[_zdx_plugin_root_resolve]} )) \
    && _zdx_plugin_root_resolve "$plugins_dir"; then
    _zdx_plugins_names "$REPLY"
    plugin_names=("${reply[@]}")
  fi
  if (( ${#plugin_names} == 0 )); then
    _zdx_plugins_info "No plugins installed to remove."
    return 0
  fi
  local chosen=""
  local -i fzf_rc=0
  _zdx_plugins_fzf_capture \
    --height=40% \
    --layout=reverse \
    --border=rounded \
    --prompt='Uninstall > ' \
    --header='Select a plugin to uninstall' \
    --pointer='▶' \
    < <(printf '%s\n' "${plugin_names[@]}") || fzf_rc=$?
  chosen="$REPLY"
  if (( fzf_rc != 0 )); then
    (( fzf_rc == 1 || fzf_rc == 130 )) && return 0
    _zdx_plugins_error "Unable to open the plugin picker (status $fzf_rc)."
    return 1
  fi
  [[ -z "$chosen" ]] && return 0
  if ! _zdx_plugins_row_in_snapshot "$chosen" "${plugin_names[@]}"; then
    _zdx_plugins_error "The selected plugin was not in the picker snapshot."
    return 1
  fi
  _zdx_plugins_remove "$chosen" no no
}

# --- Public API Command -------------------------------------------------------

_zdx_plugins_usage() {
  cat >&2 <<'EOF'
Usage:
  zdx-plugins                                   Interactive menu (list, install, update, remove)
  zdx-plugins --list                            Print installed plugins
  zdx-plugins --install <url> [name] [--dry-run] [--yes]
                                                Fetch, validate, review, and activate a plugin
  zdx-plugins --update [name] [--dry-run] [--yes]
                                                Stage, review, and activate plugin updates
  zdx-plugins --remove <name> [--dry-run] [--yes]
                                                Review and remove one plugin

Options:
  --dry-run   Fetch and validate, or plan a removal, without changing anything
  --yes       Trust or confirm without a prompt; required without a terminal
  -h, --help  Show this help

Notes:
  Plugins live under ${ZDX_PLUGINS_DIR:-~/.config/zdx/plugins} and are
  executable Zsh sourced into this shell; they are not sandboxed. Installs
  and updates are fetched into private staging in the plugin root, validated
  with the loader's rules, and activated only after a trust decision that
  shows the origin and the exact commits. A failed activation rolls back.
EOF
}

zdx-plugins() {
  local action="${1-}"
  case "$action" in
    "")
      if ! command -v fzf &>/dev/null; then
        _zdx_plugins_error "fzf not found. Plugin manager interactive menu requires fzf."
        return 1
      fi
      _zdx_plugins_menu
      return
      ;;
    -h|--help)
      _zdx_plugins_usage
      return 0
      ;;
    --list)
      if (( $# > 1 )); then
        _zdx_plugins_error "--list takes no arguments."
        return 2
      fi
      _zdx_plugins_list
      return
      ;;
    --install|--update|--remove)
      shift
      ;;
    *)
      _zdx_plugins_error "Unknown flag: $action"
      _zdx_plugins_dim "Run 'zdx-plugins --help' for usage."
      return 2
      ;;
  esac

  local dry_run=no auto_yes=no argument=""
  local -a positional=()
  local -i options_done=0
  for argument in "$@"; do
    if (( ! options_done )); then
      case "$argument" in
        --dry-run) dry_run=yes; continue ;;
        --yes)     auto_yes=yes; continue ;;
        --)        options_done=1; continue ;;
        -?*)
          _zdx_plugins_error "Unknown option for $action: $argument"
          return 2
          ;;
      esac
    fi
    positional+=("$argument")
  done

  case "$action" in
    --install)
      if (( ${#positional} == 0 )); then
        _zdx_plugins_error "Missing Git URL for --install flag."
        return 2
      fi
      if (( ${#positional} > 2 )); then
        _zdx_plugins_error "Usage: zdx-plugins --install <url> [name] [--dry-run] [--yes]"
        return 2
      fi
      _zdx_plugins_install "${positional[1]}" "${positional[2]-}" \
        "$dry_run" "$auto_yes"
      ;;
    --update)
      if (( ${#positional} > 1 )); then
        _zdx_plugins_error "Usage: zdx-plugins --update [name] [--dry-run] [--yes]"
        return 2
      fi
      if (( ${#positional} == 1 )); then
        _zdx_plugins_update "${positional[1]}" "$dry_run" "$auto_yes"
      else
        _zdx_plugins_update_all "$dry_run" "$auto_yes"
      fi
      ;;
    --remove)
      if (( ${#positional} == 0 )); then
        _zdx_plugins_error "Missing plugin name for --remove flag."
        return 2
      fi
      if (( ${#positional} > 1 )); then
        _zdx_plugins_error "Usage: zdx-plugins --remove <name> [--dry-run] [--yes]"
        return 2
      fi
      _zdx_plugins_remove "${positional[1]}" "$dry_run" "$auto_yes"
      ;;
  esac
}

typeset -g _ZDX_PLUGINS_SOURCED=1
