#!/usr/bin/env zsh
# =============================================================================
# Py Common: shared UI, validation, confirmation, and picker helpers
# =============================================================================
#
# Sourced by py-menu.zsh before loading modules under py/.
# Idempotent and free of source-time capability probes.
#

if [[ -n "${_PY_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_py_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb && -t 2 ]]
}

_py_log() {
  local plain_prefix="$1" color="$2" message="$3"
  if _py_color_enabled; then
    print -u2 -r -- "${color}${plain_prefix} ${message}"$'\e[0m'
  else
    print -u2 -r -- "${plain_prefix} ${message}"
  fi
}

# Top-level heading; the core service omits or demotes it inside a step.
_py_header() {
  if (( ${+functions[_zdx_ui_heading]} )); then
    _zdx_ui_heading "$1"
    return
  fi
  print -u2 -r -- ""
  if _py_color_enabled; then
    print -u2 -r -- $'\e[1;34m'"════ ${(V)1} ════"$'\e[0m'
  else
    print -u2 -r -- "════ ${(V)1} ════"
  fi
  print -u2 -r -- ""
}

_py_success() { _py_log "✔" $'\e[1;32m' "${(V)1}"; }
_py_warn()    { _py_log "⚠" $'\e[1;33m' "${(V)1}"; }
_py_info()    { _py_log "➜" $'\e[0;36m' "${(V)1}"; }
_py_error()   { _py_log "✘" $'\e[1;31m' "${(V)1}"; }
_py_dim()     { _py_log " " $'\e[0;90m' "${(V)1}"; }

# --- Command output services -------------------------------------------------
# docs/output-spec.md owns the vocabulary and rendering. Each wrapper checks
# the core service at call time and keeps a plain fallback, so a standalone
# source of this suite still works without functions.zsh.

# Key-value line. Usage: _py_label <key> <value>
_py_label() {
  if (( ${+functions[_zdx_ui_label]} )); then
    _zdx_ui_label "${1-}" "${2-}"
    return
  fi
  local key="${1%:}:"
  printf '  %-18s %s\n' "${(V)key}" "${(V)2}" >&2
}

# REPLY: "<count> <noun>". Usage: _py_count_noun <count> <singular> [plural]
_py_count_noun() {
  if (( ${+functions[_zdx_count_noun]} )); then
    _zdx_count_noun "$@"
    return
  fi
  local count="${1:-}" singular="${2:-}" plural="${3:-${2:-}s}"
  [[ "$count" == <-> && -n "$singular" ]] || return 2
  if (( count == 1 )); then REPLY="1 $singular"; else REPLY="$count $plural"; fi
}

# Aligned columns from TAB-separated rows; plain lines when a row is rejected.
# Usage: _py_table [--outcome-column N] <header-tsv> [row-tsv...]
_py_table() {
  if (( ${+functions[_zdx_ui_table]} )); then
    _zdx_ui_table "$@" && return 0
  fi
  [[ "${1:-}" == --outcome-column ]] && shift 2
  local table_row
  for table_row in "$@"; do
    _py_dim "${table_row//$'\t'/  }"
  done
}

# REPLY: a display-only path or command with HOME shown as ~.
# Usage: _py_command_display <argv...>
_py_command_display() {
  if (( ${+functions[_zdx_ui_command_display]} )); then
    _zdx_ui_command_display "$@"
    return
  fi
  REPLY="${(j: :)@}"
}

# Usage: _py_step_banner [--first] <index> <total> <label>
_py_step_banner() {
  if (( ${+functions[_zdx_ui_step_banner]} )); then
    _zdx_ui_step_banner "$@"
    return
  fi
  [[ "${1:-}" == --first ]] && shift
  _py_info "[${1:-?}/${2:-?}] ${3:-}"
}

# Usage: _py_step_result <index> <total> <label> <outcome> <detail> <seconds>
_py_step_result() {
  if (( ${+functions[_zdx_ui_step_result]} )); then
    _zdx_ui_step_result "$@"
    return
  fi
  _py_dim "${3:-}: ${4:-done}${5:+ — $5}"
}

# Runs one batch step; reply=(outcome detail seconds), status of the command.
_py_step_exec() {
  if (( ${+functions[_zdx_step_exec]} )); then
    _zdx_step_exec "$@"
    return
  fi
  local -i _py_step_started=$SECONDS _py_step_rc=0
  "$@" || _py_step_rc=$?
  local _py_step_outcome=done
  case $_py_step_rc in
    0) ;;
    124) _py_step_outcome=timed-out ;;
    130|143) _py_step_outcome=interrupted ;;
    *) _py_step_outcome=failed ;;
  esac
  reply=("$_py_step_outcome" "" "$(( SECONDS - _py_step_started ))")
  return $_py_step_rc
}

# Runs a chatty backend command with its output captured privately and
# replayed only on failure. Usage: _py_run_captured <display> <command...>
_py_run_captured() {
  local display="$1"
  shift
  if (( ${+functions[_zdx_run_captured]} )); then
    _zdx_run_captured "$display" 262144 80 "$@"
    return
  fi
  "$@" </dev/null >&2
}

# Renders a summary from "label<TAB>outcome<TAB>seconds<TAB>detail" records.
# Usage: _py_print_step_summary [--first-column NAME] <title> <record>...
_py_print_step_summary() {
  if (( ${+functions[_zdx_ui_step_summary]} )); then
    _zdx_ui_step_summary "$@" && return 0
  fi
  [[ "${1:-}" == --first-column ]] && shift 2
  local title="${1:-Summary}" record
  shift
  _py_header "$title"
  for record in "$@"; do
    _py_dim "${record//$'\t'/  }"
  done
}

_py_debug() {
  [[ "${PY_SUITE_DEBUG:-0}" == 1 ]] \
    && _py_log " " $'\e[0;90m' "[debug] $1"
  return 0
}

_py_check_command() {
  local command_name="${1:-}"
  [[ -n "$command_name" ]] || {
    _py_error "Internal error: a command name is required."
    return 2
  }
  command -v "$command_name" &>/dev/null || {
    _py_error "$command_name not found."
    return 1
  }
}

# Runs one external program with a deadline: status 124 on timeout and 2 for
# invalid arguments. The program is resolved to its absolute path, so a shell
# function or alias of the same name never runs. The core
# _zdx_run_with_timeout owns the portable implementation, including a Zsh
# watchdog for hosts without timeout, such as stock macOS. When this suite is
# sourced without the core, timeout or gtimeout is required and the command
# fails closed without either.
# Usage: _py_run_with_timeout <seconds> <program> [argument...]
_py_run_with_timeout() {
  local seconds="${1-}"
  shift 2>/dev/null
  [[ "$seconds" == <1-600> && ${#seconds} -le 3 ]] && (( $# > 0 )) || {
    _py_error "Internal error: invalid bounded Py command."
    return 2
  }
  local requested_program="$1" program="$1"
  shift
  if [[ "$program" != /* ]]; then
    program=$(whence -p -- "$program" 2>/dev/null) || program=""
  fi
  [[ "$program" == /* && -x "$program" ]] || {
    _py_error "$requested_program not found."
    return 1
  }

  if (( ${+functions[_zdx_run_with_timeout]} )); then
    _zdx_run_with_timeout "$seconds" "$program" "$@"
    return
  fi
  local REPLY=""
  _py_standalone_timeout_command || return 1
  command "$REPLY" -k 2s "${seconds}s" "$program" "$@"
}

# Status 0 when bounded commands can run: always with the core loaded, and
# otherwise when timeout or gtimeout exists, whose path is then in REPLY.
# Prints the refusal for a standalone source without either.
_py_standalone_timeout_command() {
  REPLY=""
  (( ${+functions[_zdx_run_with_timeout]} )) && return 0
  local candidate="" timeout_command=""
  for candidate in timeout gtimeout; do
    timeout_command=$(whence -p "$candidate" 2>/dev/null) \
      || timeout_command=""
    [[ "$timeout_command" == /* && -x "$timeout_command" ]] || continue
    REPLY="$timeout_command"
    return 0
  done
  _py_error \
    "Bounded Py commands need timeout or gtimeout when the ZDX core is not loaded."
  return 1
}

# Run uv without environment variables that can redirect project discovery or
# the project environment away from the path reviewed by this suite.
_py_run_uv_scoped() {
  emulate -L zsh
  local uv_command="" env_command=""
  uv_command=$(whence -p uv 2>/dev/null) || uv_command=""
  env_command=$(whence -p env 2>/dev/null) || env_command=""
  [[ -n "$uv_command" && -x "$uv_command" ]] || {
    _py_error "uv not found."
    return 1
  }
  [[ -n "$env_command" && -x "$env_command" ]] || {
    _py_error "env is required for target-bound uv execution."
    return 1
  }
  command "$env_command" \
    -u UV_PROJECT \
    -u UV_PROJECT_ENVIRONMENT \
    -u UV_WORKING_DIR \
    "$uv_command" "$@"
}

_py_require_tomllib() {
  _py_check_command python3 || return $?
  command python3 -I -c 'import tomllib' </dev/null >/dev/null 2>&1 || {
    _py_error "Python 3.11 or newer is required for project metadata."
    return 1
  }
}

_py_timed() {
  local label="$1"
  shift
  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

_py_confirmation_available() {
  [[ -t 0 && -t 2 ]]
}

# Return 0 for yes, 130 for a user decline, and 1 when no TTY is available.
_py_confirm() {
  local message="${1:-Proceed?}"
  if [[ "${_PY_AUTO_YES:-0}" == 1 ]]; then
    _py_debug "Auto-confirmed: $message"
    return 0
  fi
  _py_confirmation_available || {
    _py_error "Confirmation is unavailable; rerun with --yes after reviewing the plan."
    return 1
  }

  local reply=""
  if _py_color_enabled; then
    print -nu2 -r -- $'\e[1;33m'"? $message [y/N]: "$'\e[0m'
  else
    print -nu2 -r -- "? $message [y/N]: "
  fi
  read -r -k 1 reply
  local read_rc=$?
  print -u2 -r -- ""
  (( read_rc == 0 )) || return 130
  [[ "$reply" == [Yy] ]] || return 130
  return 0
}

_py_confirm_or_cancel() {
  _py_confirm "$1"
  local confirm_rc=$?
  case "$confirm_rc" in
    0) return 0 ;;
    130)
      _py_info "Cancelled."
      return 130
      ;;
    *) return "$confirm_rc" ;;
  esac
}

_py_value_is_safe() {
  local value="${1:-}"
  [[ "$value" != *[[:cntrl:]]* && "$value" != *'|'* ]]
}

_py_system_root_uid() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

_py_validate_ancestor_chain() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local child_path="${1:-}"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _py_system_root_uid || return 1
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

# REPLY is the canonical directory for an absolute, already-normalized path.
# A symbolic link on the literal path is accepted only as a root-owned system
# alias, such as macOS /var and /tmp, or above the final component when the
# current user owns it inside a directory owned by root or the current user
# that group and other users cannot write. This mirrors the core
# _zdx_resolve_trusted_dir so the suite stays sourceable on its own.
_py_resolve_trusted_dir() {
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
_py_validate_temp_parent() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local requested_parent="${1:-}"
  REPLY=""
  _py_resolve_trusted_dir "$requested_parent" || return 1
  requested_parent="$REPLY"
  REPLY=""
  [[ -n "$requested_parent" && "$requested_parent" == /* \
    && -d "$requested_parent" && ! -L "$requested_parent" \
    && "$requested_parent" == "${requested_parent:a}" \
    && "$requested_parent" == "${requested_parent:A}" ]] || return 1

  _py_system_root_uid || return 1
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
  _py_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

# --- Host platform ---------------------------------------------------------
# Platform branches follow the kernel that uname reports, so tests select a
# branch with a uname mock instead of the host.

# REPLY is the kernel name reported by uname -s, such as Linux or Darwin.
_py_host_kernel() {
  REPLY=""
  local kernel=""
  kernel=$(command uname -s </dev/null 2>/dev/null) || return 1
  kernel="${kernel%%$'\n'*}"
  [[ -n "$kernel" && "$kernel" != *[^A-Za-z0-9_.-]* ]] || return 1
  REPLY="$kernel"
}

# True when Linux runs under WSL: its session variables, its interop
# registration (WSLInterop, or WSLInterop-late on newer releases), or a
# Microsoft kernel release. The optional argument replaces /proc for fixtures.
_py_host_is_wsl() {
  local proc_root="${1:-/proc}" kernel_release="" REPLY=""
  _py_host_kernel && [[ "$REPLY" == Linux ]] || return 1
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  [[ -e "$proc_root/sys/fs/binfmt_misc/WSLInterop" \
    || -e "$proc_root/sys/fs/binfmt_misc/WSLInterop-late" ]] && return 0
  [[ -f "$proc_root/sys/kernel/osrelease" \
    && -r "$proc_root/sys/kernel/osrelease" ]] || return 1
  kernel_release=$(<"$proc_root/sys/kernel/osrelease") 2>/dev/null || return 1
  [[ "${kernel_release:l}" == *microsoft* ]]
}

# Explains a refusal of a project on a Windows drive under WSL. Without DrvFs
# metadata, every file there reports mode 777, so the ownership and
# permission checks refuse it. The refusal itself stays in place.
# Usage: _py_wsl_drive_hint <refused-path>
_py_wsl_drive_hint() {
  local refused="${1-}"
  [[ "$refused" == /mnt/[[:alpha:]] || "$refused" == /mnt/[[:alpha:]]/* ]] \
    || return 0
  _py_host_is_wsl || return 0
  _py_info "Windows drives under /mnt report mode 777 unless WSL mounts them with DrvFs metadata."
  _py_dim "Work in the Linux filesystem, such as ~/projects, or add [automount] options=\"metadata,umask=22,fmask=11\" to /etc/wsl.conf and restart WSL."
}

_py_menu_section() {
  local title="${1:-}" description="${2:-}"
  _py_value_is_safe "$title" && _py_value_is_safe "$description" || {
    _py_error "Refusing an unsafe Py menu section."
    return 1
  }
  print -r -- "── $title ──|:|$description"
}

_py_menu_entry() {
  local label="${1:-}" command_name="${2:-}" description="${3:-}"
  _py_value_is_safe "$label" \
    && _py_value_is_safe "$command_name" \
    && _py_value_is_safe "$description" || {
    _py_error "Refusing an unsafe Py menu entry."
    return 1
  }
  [[ -n "$label" && -n "$command_name" ]] || {
    _py_error "Refusing an incomplete Py menu entry."
    return 1
  }
  local REPLY=""
  _py_menu_missing_requirements "$command_name"
  # docs/menu-spec.md: an unavailable action keeps its command field and is
  # marked by a leading circle plus the requirement written in text.
  if [[ -n "$REPLY" ]]; then
    print -r -- "  ○ $label (missing: $REPLY)|$command_name|$description"
  else
    print -r -- "  ● $label|$command_name|$description"
  fi
}

# REPLY lists the requirements without which a menu action cannot run at all
# on this host; it is empty when the action can run. This is advisory: each
# command repeats its own checks. Bounded inventories and mount validation
# use the core watchdog when timeout and gtimeout are absent, as on stock
# macOS, so they are unavailable only in a standalone source without either.
_py_menu_missing_requirements() {
  local command_name="${1-}"
  REPLY=""
  case "$command_name" in
    tool-list|tool-uninstall|tool-upgrade|\
    venv-python-list|venv-python-install|venv-python-pin|venv-remove)
      (( ${+functions[_zdx_run_with_timeout]} )) && return 0
      whence -p timeout &>/dev/null || whence -p gtimeout &>/dev/null \
        || REPLY="timeout or gtimeout"
      ;;
  esac
  return 0
}

_py_array_contains_literal() {
  local needle="${1-}" candidate=""
  shift 2>/dev/null || return 2
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

_py_fzf() {
  local -a fzf_options=(
    --height=80%
    --layout=reverse
    --border=rounded
    '--delimiter=[|]'
    --with-nth=1
    '--pointer=▶'
  )
  fzf_options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow')

  if [[ -z "${NO_COLOR:-}" ]] && typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option=""
    theme_option=$(_tk_fzf_color_opts 2>/dev/null) || theme_option=""
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
    SHELL=/bin/sh fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

_py_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

# Execute one read-only producer under a deadline, bound its stdout, and emit
# the captured data. Its stderr is discarded: diagnostics are not data, and a
# failure reports the producer status (124 after the deadline).
# Usage: _py_capture_bounded_output <max-bytes> <label> <seconds> <program> [argument...]
_py_capture_bounded_output() {
  emulate -L zsh
  local -i max_bytes=${1:-0}
  local label="${2:-command}"
  local seconds="${3-}"
  shift 3 2>/dev/null || {
    _py_error "Internal error: invalid bounded-output request."
    return 1
  }
  (( max_bytes > 0 && max_bytes <= 64 * 1024 * 1024 && $# > 0 )) \
    && [[ "$seconds" == <1-600> ]] || {
    _py_error "Internal error: invalid bounded-output request."
    return 1
  }
  local producer_program="$1"
  if [[ "$producer_program" != /* ]]; then
    producer_program=$(whence -p -- "$1" 2>/dev/null) || producer_program=""
  fi
  [[ "$producer_program" == /* && -x "$producer_program" ]] || {
    _py_error "$1 not found."
    return 1
  }
  shift
  local -a producer_args=("$@")
  # The producer's stderr is discarded, so refuse a missing bound visibly.
  local REPLY=""
  _py_standalone_timeout_command || return 1
  local head_command=""
  head_command=$(whence -p head 2>/dev/null) || head_command=""
  [[ -n "$head_command" && -x "$head_command" ]] || {
    _py_error "head is required for byte-bounded Py inventories."
    return 1
  }

  zmodload -F zsh/stat b:zstat 2>/dev/null || {
    _py_error "Zsh stat support is required for bounded command output."
    return 1
  }
  _py_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _py_error "Refusing an unsafe temporary root for $label."
    return 1
  }
  local temp_root="$REPLY"

  local capture_file=""
  capture_file=$(umask 077; command mktemp \
    "$temp_root/zdx-py-output.XXXXXX" 2>/dev/null) || {
    _py_error "Could not create private output storage for $label."
    return 1
  }
  command chmod -- 600 "$capture_file" 2>/dev/null || {
    command rm -f -- "$capture_file" 2>/dev/null
    _py_error "Could not protect private output storage for $label."
    return 1
  }

  local -A initial_state=() current_state=()
  [[ "$capture_file" == "${capture_file:a}" \
    && "$capture_file" == "${capture_file:A}" \
    && -f "$capture_file" && ! -L "$capture_file" ]] \
    && zstat -LH initial_state -- "$capture_file" 2>/dev/null \
    && (( (initial_state[mode] & 8#170000) == 8#100000 \
      && initial_state[uid] == EUID \
      && initial_state[nlink] == 1 \
      && (initial_state[mode] & 8#77) == 0 )) || {
    command rm -f -- "$capture_file" 2>/dev/null
    _py_error "Refusing unsafe output storage for $label."
    return 1
  }
  local identity="${initial_state[device]}:${initial_state[inode]}:${initial_state[uid]}:${initial_state[nlink]}"
  local output=""
  local -a pipeline_rcs=()
  local -i producer_rc=1 limiter_rc=1 operation_rc=1 cleanup_failed=0

  {
    # Inventory diagnostics are not data; a failure reports its status.
    _py_run_with_timeout "$seconds" "$producer_program" "${producer_args[@]}" \
      2>/dev/null \
      | command "$head_command" -c "$(( max_bytes + 1 ))" \
        >"$capture_file"
    pipeline_rcs=("${pipestatus[@]}")
    producer_rc=${pipeline_rcs[1]:-1}
    limiter_rc=${pipeline_rcs[2]:-1}

    current_state=()
    if ! zstat -LH current_state -- "$capture_file" 2>/dev/null \
      || [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
        != "$identity" ]] \
      || (( (current_state[mode] & 8#170000) != 8#100000 \
        || (current_state[mode] & 8#77) != 0 \
        || current_state[size] < 0 \
        || current_state[size] > max_bytes + 1 )); then
      _py_error "$label output storage changed unexpectedly."
      operation_rc=1
    elif (( current_state[size] > max_bytes )); then
      _py_error "$label output exceeded ${max_bytes} bytes."
      operation_rc=1
    elif (( limiter_rc != 0 )); then
      _py_error "$label output limiter failed (status $limiter_rc)."
      operation_rc=$limiter_rc
    elif (( producer_rc != 0 )); then
      _py_error "$label failed (status $producer_rc)."
      operation_rc=$producer_rc
    else
      output=$(<"$capture_file")
      operation_rc=0
    fi
  } always {
    current_state=()
    if [[ -f "$capture_file" && ! -L "$capture_file" ]] \
      && zstat -LH current_state -- "$capture_file" 2>/dev/null \
      && [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
        == "$identity" ]]; then
      command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
    else
      _py_warn "$label output changed; refusing cleanup."
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=1
  }

  (( operation_rc == 0 )) || return "$operation_rc"
  [[ -n "$output" ]] && print -r -- "$output"
  return 0
}

# Run fzf in the foreground and return its bounded result in REPLY. The status
# is fzf's own, or 125 when the picker could not be set up, read, or cleaned
# up safely, so callers never mistake a setup failure for a cancellation
# (fzf returns 1 for no match and 130 for Esc).
_py_fzf_capture() {
  emulate -L zsh
  setopt local_options local_traps
  REPLY=""

  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
    _py_error "Zsh file-descriptor support is required for Py pickers."
    return 125
  }

  _py_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _py_error "Refusing an unsafe temporary root for the Py picker."
    return 125
  }
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-py-fzf.XXXXXX" 2>/dev/null) || {
    _py_error "Could not create a private Py picker directory."
    return 125
  }
  command chmod -- 700 "$capture_dir" 2>/dev/null || {
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Could not protect the Py picker directory."
    return 125
  }

  local -A dir_state=() file_state=() current_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || ! -d "$capture_dir" || -L "$capture_dir" \
    || "${capture_dir:t}" != zdx-py-fzf.* ]] \
    || ! zstat -LH dir_state -- "$capture_dir" 2>/dev/null \
    || (( (dir_state[mode] & 8#170000) != 8#040000 \
      || dir_state[uid] != EUID \
      || (dir_state[mode] & 8#77) != 0 )); then
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Refusing an unsafe Py picker directory."
    return 125
  fi
  local dir_identity="${dir_state[device]}:${dir_state[inode]}:${dir_state[uid]}"

  local capture_file=""
  capture_file=$(umask 077; command mktemp \
    "$capture_dir/.result.XXXXXX" 2>/dev/null) || {
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Could not create a private Py picker result."
    return 125
  }
  command chmod -- 600 "$capture_file" 2>/dev/null || {
    command rm -f -- "$capture_file" 2>/dev/null
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Could not protect the Py picker result."
    return 125
  }

  if [[ "$capture_file" != "${capture_file:a}" \
    || "$capture_file" != "${capture_file:A}" \
    || "${capture_file:h}" != "$capture_dir" \
    || ! -f "$capture_file" || -L "$capture_file" ]] \
    || ! zstat -LH file_state -- "$capture_file" 2>/dev/null \
    || (( (file_state[mode] & 8#170000) != 8#100000 \
      || file_state[uid] != EUID || file_state[nlink] != 1 \
      || (file_state[mode] & 8#77) != 0 )); then
    command rm -f -- "$capture_file" 2>/dev/null
    command rmdir -- "$capture_dir" 2>/dev/null
    _py_error "Refusing an unsafe Py picker result."
    return 125
  fi

  local file_identity="${file_state[device]}:${file_state[inode]}:${file_state[uid]}:${file_state[nlink]}"
  local -i capture_fd=-1 read_fd=-1 picker_rc=125 operation_rc=125
  local -i cleanup_failed=0
  local selection=""

  {
    trap 'operation_rc=130; return 130' INT
    trap 'operation_rc=143; return 143' TERM HUP

    if sysopen -w -o nofollow,cloexec -u capture_fd \
      -- "$capture_file" 2>/dev/null; then
      _py_fzf "$@" 1>&$(( capture_fd ))
      picker_rc=$?
      exec {capture_fd}>&-
      capture_fd=-1

      dir_state=()
      current_state=()
      if zstat -LH dir_state -- "$capture_dir" 2>/dev/null \
        && [[ "${dir_state[device]}:${dir_state[inode]}:${dir_state[uid]}" \
          == "$dir_identity" ]] \
        && zstat -LH current_state -- "$capture_file" 2>/dev/null \
        && [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
          == "$file_identity" ]] \
        && (( current_state[size] >= 0 \
          && current_state[size] <= 4 * 1024 * 1024 )) \
        && sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
        selection=$(<&$(( read_fd )))
        exec {read_fd}>&-
        read_fd=-1
        operation_rc=$picker_rc
      else
        _py_error "The Py picker result changed or is oversized."
      fi
    else
      _py_error "Could not open the Py picker result safely."
    fi
  } always {
    trap - INT TERM HUP
    (( capture_fd >= 0 )) && exec {capture_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    current_state=()
    if [[ -f "$capture_file" && ! -L "$capture_file" \
      && "${capture_file:a}" == "$capture_file" \
      && "${capture_file:A}" == "$capture_file" \
      && "${capture_file:h}" == "$capture_dir" ]] \
      && zstat -LH current_state -- "$capture_file" 2>/dev/null \
      && [[ "${current_state[device]}:${current_state[inode]}:${current_state[uid]}:${current_state[nlink]}" \
        == "$file_identity" ]]; then
      command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
    else
      _py_warn "The Py picker result changed; refusing cleanup."
      cleanup_failed=1
    fi

    dir_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" \
      && "${capture_dir:a}" == "$capture_dir" \
      && "${capture_dir:A}" == "$capture_dir" \
      && "${capture_dir:t}" == zdx-py-fzf.* ]] \
      && zstat -LH dir_state -- "$capture_dir" 2>/dev/null \
      && [[ "${dir_state[device]}:${dir_state[inode]}:${dir_state[uid]}" \
        == "$dir_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      _py_warn "The Py picker directory changed; refusing cleanup."
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return "$operation_rc"
}

_py_validate_package_name() {
  local package_name="${1:-}"
  [[ -n "$package_name" && ${#package_name} -le 128 \
    && "$package_name" != -* ]] \
    && [[ "$package_name" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]
}

_py_validate_python_version() {
  local version="${1:-}"
  [[ "$version" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]]
}

typeset -g _PY_COMMON_SOURCED=1
