#!/usr/bin/env zsh
# =============================================================================
# Ws Common: private UI, picker, workspace-root, and discovery primitives
# =============================================================================
#
# Loaded by ws-menu.zsh before every module under functions/ws/.
# Private helpers only; not a standalone public command.
#
# The suite owns the $WS_BASE_DIR/<platform>/<identity>/<repository> layout.
# Discovery reads it; only ws-clone writes below it, and only after a plan.
#

if [[ -n "${_WS_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Workspace settings. The canonical HOME keeps the default valid when HOME
# traverses a symlink. An explicit empty WS_BASE_DIR is kept and refused when
# used; the Git suite declares the same default for git-auth.
typeset -g WS_BASE_DIR="${WS_BASE_DIR-${HOME:A}/workspaces}"
typeset -g WS_MAX_DEPTH="${WS_MAX_DEPTH-3}"
typeset -g WS_FETCH_JOBS="${WS_FETCH_JOBS-4}"
(( ${+WS_EXCLUDE} )) || typeset -ga WS_EXCLUDE=()

typeset -gi _WS_MAX_MENU_ROWS=32
typeset -gi _WS_MAX_PICKER_BYTES=1048576
typeset -gi _WS_MAX_REPOSITORIES=2000
typeset -gi _WS_MAX_SCAN_BYTES=8388608
typeset -gi _WS_SCAN_TIMEOUT=30
typeset -gi _WS_GIT_TIMEOUT=15
typeset -gi _WS_PROBE_TIMEOUT=10

# --- UI --------------------------------------------------------------------

_ws_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

# Top-level heading; the core service omits or demotes it inside a step.
_ws_header() {
  if (( ${+functions[_zdx_ui_heading]} )); then
    _zdx_ui_heading "${1:-}"
    return
  fi
  if _ws_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}

_ws_success() {
  if _ws_color_enabled; then
    printf '\033[1;32m✔ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✔ %s\n' "${(V)1}" >&2
  fi
}

_ws_warn() {
  if _ws_color_enabled; then
    printf '\033[1;33m⚠ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⚠ %s\n' "${(V)1}" >&2
  fi
}

_ws_info() {
  if _ws_color_enabled; then
    printf '\033[0;36m➜ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '➜ %s\n' "${(V)1}" >&2
  fi
}

_ws_error() {
  if _ws_color_enabled; then
    printf '\033[1;31m✘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✘ %s\n' "${(V)1}" >&2
  fi
}

_ws_dim() {
  if _ws_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
}

# --- Command output services -------------------------------------------------
# docs/output-spec.md owns the vocabulary and rendering. Each wrapper checks
# the core service at call time and keeps a plain fallback, so a standalone
# source of this suite still works without functions.zsh.

# Key-value fact. Usage: _ws_label <key> <value>
_ws_label() {
  if (( ${+functions[_zdx_ui_label]} )); then
    _zdx_ui_label "${1-}" "${2-}"
    return
  fi
  printf '  %-18s %s\n' "${(V)${1-}%:}:" "${(V)2-}" >&2
}

# Aligned columns from TAB-separated rows; plain lines when a row is rejected.
# Usage: _ws_table <header-tsv> [row-tsv...]
_ws_table() {
  if (( ${+functions[_zdx_ui_table]} )); then
    _zdx_ui_table "$@" && return 0
  fi
  local table_row=""
  for table_row in "$@"; do
    _ws_dim "${table_row//$'\t'/  }"
  done
}

# REPLY: "<count> <noun>". Usage: _ws_count_noun <count> <singular> [plural]
_ws_count_noun() {
  if (( ${+functions[_zdx_count_noun]} )); then
    _zdx_count_noun "$@"
    return
  fi
  local count="${1:-}" singular="${2:-}" plural="${3:-${2:-}s}"
  [[ "$count" == <-> && -n "$singular" ]] || return 2
  if (( count == 1 )); then REPLY="1 $singular"; else REPLY="$count $plural"; fi
}

# REPLY: a display-only path or command with HOME shown as ~.
# Usage: _ws_command_display <argv...>
_ws_command_display() {
  if (( ${+functions[_zdx_ui_command_display]} )); then
    _zdx_ui_command_display "$@"
    return
  fi
  REPLY="${(j: :)@}"
}

# Partial-success timing for a command that ends with mixed results.
_ws_mark_partial() {
  (( ${+functions[_zdx_timed_mark_partial]} )) || return 0
  _zdx_timed_mark_partial || true
}

_ws_timed() {
  local label="$1"
  shift
  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

# --- Host platform and external commands -------------------------------------
# Platform branches follow the kernel that uname reports, so tests select a
# branch with a uname mock instead of the host.

# REPLY is the kernel name reported by uname -s, such as Linux or Darwin.
_ws_host_kernel() {
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
_ws_host_is_wsl() {
  local proc_root="${1:-/proc}" kernel_release="" REPLY=""
  _ws_host_kernel && [[ "$REPLY" == Linux ]] || return 1
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  [[ -e "$proc_root/sys/fs/binfmt_misc/WSLInterop" \
    || -e "$proc_root/sys/fs/binfmt_misc/WSLInterop-late" ]] && return 0
  [[ -f "$proc_root/sys/kernel/osrelease" \
    && -r "$proc_root/sys/kernel/osrelease" ]] || return 1
  kernel_release=$(<"$proc_root/sys/kernel/osrelease") 2>/dev/null || return 1
  [[ "${kernel_release:l}" == *microsoft* ]]
}

# REPLY: the absolute path of an external command. On WSL, a program below a
# Windows drive, such as one on the appended Windows PATH, is not a Linux tool
# and counts as missing. Usage: _ws_command_path <name-or-absolute-path>
_ws_command_path() {
  REPLY=""
  local requested="${1-}" resolved=""
  [[ -n "$requested" ]] || return 2
  if [[ "$requested" == /* ]]; then
    resolved="$requested"
  else
    resolved=$(whence -p -- "$requested" 2>/dev/null) || return 1
  fi
  [[ "$resolved" == /* && -f "$resolved" && -x "$resolved" ]] || return 1
  if [[ "$resolved" == /mnt/[[:alpha:]]/* ]] && _ws_host_is_wsl; then
    return 1
  fi
  REPLY="$resolved"
}

_ws_require_cmd() {
  local command_name="$1"
  local purpose="${2:-this operation}"
  local REPLY=""
  _ws_command_path "$command_name" && return 0
  _ws_error "$command_name is required for $purpose."
  return 1
}

# Runs one external program with a deadline: status 124 on timeout and 2 for
# invalid arguments. The program is resolved to its absolute path, so a shell
# function or alias of the same name never runs. The core
# _zdx_run_with_timeout owns the portable implementation, including a Zsh
# watchdog for hosts without timeout, such as stock macOS. When this suite is
# sourced without the core, timeout or gtimeout is required and the command
# fails closed without either.
# Usage: _ws_run_with_timeout <seconds> <program> [argument...]
_ws_run_with_timeout() {
  local seconds="${1-}"
  shift 2>/dev/null
  [[ "$seconds" == <1-600> && ${#seconds} -le 3 ]] && (( $# > 0 )) || {
    _ws_error "Internal error: invalid bounded workspace command."
    return 2
  }
  local requested_program="$1" REPLY=""
  shift
  _ws_command_path "$requested_program" || {
    _ws_error "$requested_program not found."
    return 1
  }
  local program="$REPLY"

  if (( ${+functions[_zdx_run_with_timeout]} )); then
    _zdx_run_with_timeout "$seconds" "$program" "$@"
    return
  fi
  local candidate="" timeout_command=""
  for candidate in timeout gtimeout; do
    timeout_command=$(whence -p "$candidate" 2>/dev/null) \
      || timeout_command=""
    [[ "$timeout_command" == /* && -x "$timeout_command" ]] && break
    timeout_command=""
  done
  [[ -n "$timeout_command" ]] || {
    _ws_error \
      "Bounded workspace commands need timeout or gtimeout when the ZDX core is not loaded."
    return 1
  }
  command "$timeout_command" -k 2s "${seconds}s" "$program" "$@"
}

# REPLY: the absolute path of Git 2.31 or newer, the ZDX Git baseline. On
# macOS, Apple's /usr/bin/git is a Command Line Tools placeholder that opens
# an installation dialog while no developer directory exists; it is reported
# as missing and never run.
_ws_git_command() {
  emulate -L zsh
  REPLY=""
  local git_path="" version_output="" developer_dir=""
  _ws_command_path git || {
    _ws_error "git is required; install Git 2.31 or newer."
    return 1
  }
  git_path="$REPLY"
  REPLY=""
  if [[ "$git_path" == /usr/bin/git ]] && _ws_host_kernel \
    && [[ "$REPLY" == Darwin ]]; then
    REPLY=""
    if _ws_command_path xcode-select; then
      developer_dir=$(_ws_run_with_timeout "$_WS_PROBE_TIMEOUT" "$REPLY" -p \
        </dev/null 2>/dev/null) || developer_dir=""
    fi
    developer_dir="${developer_dir%%$'\n'*}"
    [[ -n "$developer_dir" && -d "$developer_dir" ]] || {
      _ws_error "/usr/bin/git is the Command Line Tools placeholder; it was not run."
      _ws_info "Install Apple's tools with xcode-select --install, or install Homebrew git."
      return 1
    }
  fi
  REPLY=""
  version_output=$(_ws_run_with_timeout "$_WS_PROBE_TIMEOUT" "$git_path" \
    --version </dev/null 2>/dev/null) || {
    _ws_error "git --version failed; verify the active Git executable."
    return 1
  }
  version_output="${version_output%%$'\n'*}"
  [[ "$version_output" =~ '^git version ([0-9]+)[.]([0-9]+)' ]] || {
    _ws_error "Could not read the Git version."
    return 1
  }
  local -i major="${match[1]}" minor="${match[2]}"
  if (( major < 2 || (major == 2 && minor < 31) )); then
    _ws_error "Git 2.31 or newer is required; found $major.$minor."
    return 1
  fi
  REPLY="$git_path"
}

# --- Filesystem trust helpers ----------------------------------------------

_ws_system_root_uid() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

# True when every ancestor of a canonical path is a real directory owned by
# root or the current user that group and other users cannot write, except a
# root-owned sticky world-writable directory such as /tmp.
_ws_validate_ancestor_chain() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local child_path="$1"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  local REPLY=""
  _ws_system_root_uid || return 1
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
      _ws_error \
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
_ws_resolve_trusted_dir() {
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
_ws_validate_temp_parent() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local requested_parent="${1:-}"
  REPLY=""
  _ws_resolve_trusted_dir "$requested_parent" || return 1
  requested_parent="$REPLY"
  REPLY=""
  [[ -n "$requested_parent" && "$requested_parent" == /* \
    && -d "$requested_parent" && ! -L "$requested_parent" \
    && "$requested_parent" == "${requested_parent:a}" \
    && "$requested_parent" == "${requested_parent:A}" ]] || return 1

  _ws_system_root_uid || return 1
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
  _ws_validate_ancestor_chain "$requested_parent" 2>/dev/null || return 1
  REPLY="$requested_parent"
}

# REPLY: device:inode of a real directory that the current user owns and that
# group and other users cannot write. Usage: _ws_owned_directory <path>
_ws_owned_directory() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local directory="${1-}"
  REPLY=""
  local -A state=()
  [[ -d "$directory" && ! -L "$directory" ]] \
    && zstat -LH state -- "$directory" 2>/dev/null \
    && (( (state[mode] & 8#170000) == 8#040000 \
      && state[uid] == EUID && (state[mode] & 8#22) == 0 )) || return 1
  REPLY="${state[device]}:${state[inode]}"
}

# reply: a new owner-only directory below the validated temporary root and
# its device:inode identity. Usage: _ws_private_dir_create <purpose>
_ws_private_dir_create() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  reply=()
  local purpose="${1-}" REPLY=""
  [[ "$purpose" =~ '^[a-z]+$' ]] || return 2
  _ws_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _ws_error "Refusing an unsafe temporary root for the Workspace suite."
    return 1
  }
  local temp_root="$REPLY" directory=""
  directory=$(umask 077; command mktemp -d \
    "$temp_root/zdx-ws-$purpose.XXXXXX" 2>/dev/null) || {
    _ws_error "Could not create a private Workspace directory."
    return 1
  }
  local -A state=()
  if [[ "$directory" != "${directory:a}" \
    || "$directory" != "${directory:A}" \
    || "${directory:h}" != "$temp_root" \
    || "${directory:t}" != zdx-ws-$purpose.?????? \
    || ! -d "$directory" || -L "$directory" ]] \
    || ! zstat -LH state -- "$directory" 2>/dev/null \
    || (( (state[mode] & 8#170000) != 8#040000 \
      || state[uid] != EUID || (state[mode] & 8#77) != 0 )); then
    _ws_error "Refusing an unsafe private Workspace directory."
    return 1
  fi
  reply=("$directory" "${state[device]}:${state[inode]}")
}

# Removes a directory made by _ws_private_dir_create and the files and links
# directly inside it, only while its identity is unchanged.
# Usage: _ws_private_dir_remove <directory> <identity>
_ws_private_dir_remove() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local directory="${1-}" identity="${2-}"
  local -A state=()
  [[ -n "$directory" && -d "$directory" && ! -L "$directory" \
    && "${directory:t}" == zdx-ws-* ]] \
    && zstat -LH state -- "$directory" 2>/dev/null \
    && [[ "${state[device]}:${state[inode]}" == "$identity" ]] || {
    _ws_warn "A private Workspace directory changed; it was not removed."
    return 1
  }
  local -a entries=("$directory"/*(DN^/))
  if (( ${#entries[@]} > 0 )); then
    command rm -f -- "${entries[@]}" 2>/dev/null || return 1
  fi
  command rmdir -- "$directory" 2>/dev/null
}

# --- Confirmation ------------------------------------------------------------

# True when a person can answer a prompt. Tests replace this predicate.
_ws_interactive_available() {
  [[ -t 0 && -t 2 ]]
}

_ws_confirm() {
  local prompt="${1:-Proceed?}"
  local auto_yes="${2:-no}"

  [[ "$auto_yes" == "yes" ]] && return 0
  _ws_interactive_available || return 2

  local response=""
  if _ws_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi
  read -r response || return 2
  print -u2 -r -- ""
  [[ "$response" =~ ^[Yy]$ ]]
}

# Usage: _ws_confirm_mutation <prompt> [auto-yes] [cancellation message]
# Status 130 means the user declined; 2 means no terminal and no --yes.
_ws_confirm_mutation() {
  local prompt="$1"
  local auto_yes="${2:-no}"
  local cancelled_message="${3:-Cancelled.}"
  local -i confirm_rc=0

  _ws_confirm "$prompt" "$auto_yes" || confirm_rc=$?
  case "$confirm_rc" in
    0) return 0 ;;
    1)
      _ws_info "$cancelled_message"
      return 130
      ;;
    *)
      _ws_error "Confirmation requires a terminal; pass --yes to proceed."
      return 2
      ;;
  esac
}

# REPLY: one line typed at a terminal prompt. Usage: _ws_read_line <prompt>
_ws_read_line() {
  local prompt="$1"
  REPLY=""
  _ws_interactive_available || return 2
  printf '? %s: ' "${(V)prompt}" >&2
  local response=""
  read -r response || return 1
  REPLY="$response"
}

# --- Canonical menu rows ----------------------------------------------------

_ws_menu_field_safe() {
  [[ "$1" != *'|'* && "$1" != *$'\n'* && "$1" != *$'\r'* \
    && "$1" != *[[:cntrl:]]* ]]
}

_ws_menu_section() {
  local title="$1"
  local description="${2:-}"
  _ws_menu_field_safe "$title" && _ws_menu_field_safe "$description" || {
    _ws_error "Invalid menu section fields."
    return 2
  }
  printf '── %s ──|:|%s\n' "$title" "$description"
}

_ws_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"
  _ws_menu_field_safe "$label" \
    && _ws_menu_field_safe "$command_name" \
    && _ws_menu_field_safe "$description" || {
    _ws_error "Invalid menu entry fields."
    return 2
  }

  local REPLY=""
  _ws_menu_missing_requirements "$command_name"
  # docs/menu-spec.md: an unavailable action keeps its command field and is
  # marked by a leading circle plus the requirement written in text.
  if [[ -n "$REPLY" ]]; then
    printf '  ○ %s (missing: %s)|%s|%s\n' \
      "$label" "$REPLY" "$command_name" "$description"
  else
    printf '  %s|%s|%s\n' "$label" "$command_name" "$description"
  fi
}

# REPLY lists the requirements without which an action cannot run at all on
# this host, for its menu label; it is empty when the action can run. This is
# advisory: each command repeats its own checks.
_ws_menu_missing_requirements() {
  local command_name="${1-}" missing=""
  case "$command_name" in
    ws-status|ws-clone)
      _ws_command_path git || missing="git"
      ;;
  esac
  REPLY="$missing"
  return 0
}

_ws_array_contains_literal() {
  local needle="${1-}" candidate=""
  shift 2>/dev/null || return 2
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

# --- Foreground fzf capture -------------------------------------------------

_ws_fzf() {
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

# Runs fzf synchronously in the terminal foreground and returns its bounded
# selection in REPLY. The status is fzf's own, or 125 when the picker could
# not be set up, read, or cleaned up safely, so a setup failure is never
# mistaken for a cancellation.
_ws_fzf_capture() {
  emulate -L zsh

  REPLY=""
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
    _ws_error "Zsh file-descriptor support is required for Workspace pickers."
    return 125
  }

  _ws_validate_temp_parent "${TMPDIR:-/tmp}" || {
    _ws_error "Refusing an unsafe temporary root for the Workspace picker."
    return 125
  }
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-ws-fzf.XXXXXX" 2>/dev/null) || {
    _ws_error "Could not create a private Workspace picker directory."
    return 125
  }

  local -A capture_dir_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || "${capture_dir:h}" != "$temp_root" \
    || ! -d "$capture_dir" || -L "$capture_dir" \
    || "${capture_dir:t}" != zdx-ws-fzf.?????? ]] \
    || ! zstat -LH capture_dir_state -- "$capture_dir" 2>/dev/null \
    || (( (capture_dir_state[mode] & 8#170000) != 8#040000 \
      || capture_dir_state[uid] != EUID \
      || (capture_dir_state[mode] & 8#77) != 0 )); then
    _ws_error "Refusing an unsafe Workspace picker directory."
    return 125
  fi
  local capture_dir_identity="${capture_dir_state[device]}:${capture_dir_state[inode]}:${capture_dir_state[mode]}:${capture_dir_state[uid]}"

  local capture_file=""
  local capture_file_identity=""
  local selection=""
  local -i capture_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A capture_file_state=() current_dir_state=() current_file_state=()

  {
    capture_file=$(umask 077; command mktemp \
      "$capture_dir/.result.XXXXXX" 2>/dev/null)
    if [[ -z "$capture_file" ]]; then
      _ws_error "Could not create a private Workspace picker result."
    elif [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$capture_dir" \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH capture_file_state -- "$capture_file" 2>/dev/null \
      || (( (capture_file_state[mode] & 8#170000) != 8#100000 \
        || capture_file_state[uid] != EUID \
        || capture_file_state[nlink] != 1 \
        || (capture_file_state[mode] & 8#77) != 0 )); then
      _ws_error "Refusing an unsafe Workspace picker result."
    else
      capture_file_identity="${capture_file_state[device]}:${capture_file_state[inode]}:${capture_file_state[mode]}:${capture_file_state[uid]}:${capture_file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u capture_fd \
        -- "$capture_file" 2>/dev/null; then
        _ws_error "Could not open the Workspace picker result safely."
      else
        _ws_fzf "$@" 1>&$(( capture_fd ))
        fzf_rc=$?
        exec {capture_fd}>&-
        capture_fd=-1

        if ! zstat -LH current_dir_state -- "$capture_dir" 2>/dev/null \
          || [[ "${current_dir_state[device]}:${current_dir_state[inode]}:${current_dir_state[mode]}:${current_dir_state[uid]}" \
            != "$capture_dir_identity" ]] \
          || ! zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$capture_file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > _WS_MAX_PICKER_BYTES )); then
          _ws_error "The Workspace picker result changed or is oversized."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _ws_error "Could not read the Workspace picker result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _ws_error "A failed Workspace picker returned unexpected data."
            selection=""
          else
            operation_rc=$fzf_rc
          fi
        fi
      fi
    fi
  } always {
    (( capture_fd >= 0 )) && exec {capture_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    if [[ -n "$capture_file" && ( -e "$capture_file" || -L "$capture_file" ) ]]; then
      current_file_state=()
      if [[ -n "$capture_file_identity" \
        && -f "$capture_file" && ! -L "$capture_file" \
        && "${capture_file:h}" == "$capture_dir" ]] \
        && zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
        && [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
          == "$capture_file_identity" ]]; then
        command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
      else
        _ws_warn "The Workspace picker result changed; refusing cleanup."
        cleanup_failed=1
      fi
    fi

    current_dir_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" \
      && "${capture_dir:t}" == zdx-ws-fzf.?????? ]] \
      && zstat -LH current_dir_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_dir_state[device]}:${current_dir_state[inode]}:${current_dir_state[mode]}:${current_dir_state[uid]}" \
        == "$capture_dir_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      _ws_warn "The Workspace picker directory changed; refusing cleanup."
      cleanup_failed=1
    fi

    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_ws_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

# --- Workspace root and discovery -----------------------------------------

# True for one workspace path component: a platform, identity, or repository
# directory name. It starts with a letter or digit, so it can never be read as
# an option, a hidden name, or a relative traversal.
_ws_name_valid() {
  [[ "${1-}" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' ]]
}

# True when a relative path can appear in a picker record, a table cell, or a
# preview snapshot line without changing its structure.
_ws_path_displayable() {
  [[ -n "${1-}" && "$1" != *'|'* && "$1" != *[[:cntrl:]]* ]]
}

# REPLY: the byte length of a value, independent of the locale.
_ws_byte_length() {
  emulate -L zsh
  setopt no_multibyte
  REPLY=${#1}
}

# reply: the configured workspace root as written (without trailing slashes)
# and its canonical directory. Read-only commands accept a root reached
# through symbolic links; ws-clone applies its own ownership checks.
_ws_workspace_root() {
  emulate -L zsh
  reply=()
  local base="${WS_BASE_DIR-}" REPLY=""
  [[ -n "$base" ]] || {
    _ws_error "WS_BASE_DIR is empty; set it to an absolute path."
    return 1
  }
  [[ "$base" == /* && "$base" != *[[:cntrl:]]* ]] || {
    _ws_error "WS_BASE_DIR must be an absolute path."
    return 1
  }
  while [[ "$base" != / && "$base" == */ ]]; do
    base="${base%/}"
  done
  [[ "$base" != / ]] || {
    _ws_error "WS_BASE_DIR cannot be the filesystem root."
    return 1
  }
  if [[ ! -d "$base" ]]; then
    _ws_command_display "$base"
    _ws_error "The workspace root does not exist: $REPLY"
    _ws_info "Create it, or set WS_BASE_DIR in ~/.config/zdx/config.zsh."
    return 1
  fi
  local canonical="${base:A}"
  [[ -d "$canonical" && "$canonical" != / ]] || {
    _ws_error "The workspace root is not a directory."
    return 1
  }
  reply=("$base" "$canonical")
}

# REPLY: the validated WS_MAX_DEPTH, an integer from 1 to 10.
_ws_max_depth() {
  REPLY=""
  [[ "${WS_MAX_DEPTH-}" == <1-10> && ${#WS_MAX_DEPTH} -le 2 ]] || {
    _ws_error "WS_MAX_DEPTH must be an integer from 1 to 10."
    return 1
  }
  REPLY="$WS_MAX_DEPTH"
}

# REPLY: the validated WS_FETCH_JOBS, an integer from 1 to 16.
_ws_fetch_jobs() {
  REPLY=""
  [[ "${WS_FETCH_JOBS-}" == <1-16> && ${#WS_FETCH_JOBS} -le 2 ]] || {
    _ws_error "WS_FETCH_JOBS must be an integer from 1 to 16."
    return 1
  }
  REPLY="$WS_FETCH_JOBS"
}

# reply: the WS_EXCLUDE entries as relative paths without trailing slashes.
# An entry names a subtree below the workspace root, such as github/archive;
# it is never a pattern. Empty entries are ignored.
_ws_exclusions() {
  emulate -L zsh
  reply=()
  local -a configured=()
  (( ${+WS_EXCLUDE} )) && configured=("${WS_EXCLUDE[@]}")
  local entry=""
  for entry in "${configured[@]}"; do
    while [[ "$entry" == */ ]]; do
      entry="${entry%/}"
    done
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == /* || "$entry" == *[[:cntrl:]]* \
      || "/$entry/" == */./* || "/$entry/" == */../* \
      || "$entry" == *//* ]]; then
      _ws_error "WS_EXCLUDE entries must be relative paths below WS_BASE_DIR: ${entry}"
      return 1
    fi
    reply+=("$entry")
  done
  return 0
}

# reply: the discovery program and its kind. fd is preferred, including the
# fdfind name used by Debian and Ubuntu, and find is the portable fallback.
_ws_discovery_backend() {
  reply=()
  local REPLY=""
  if _ws_command_path fd || _ws_command_path fdfind; then
    reply=("$REPLY" fd)
  elif _ws_command_path find; then
    reply=("$REPLY" find)
  else
    return 1
  fi
}

# reply: the repositories below a canonical workspace root, as sorted
# relative paths. A repository is a directory with a .git entry (a directory,
# or the file of a linked worktree or submodule) at most WS_MAX_DEPTH levels
# below the root. Hidden directories, symbolic links, WS_EXCLUDE subtrees, and
# repositories nested inside another listed repository are left out. The scan
# is bounded in time and output. REPLY counts directories skipped because
# their names cannot be shown safely. Usage: _ws_collect_repositories <root>
_ws_collect_repositories() {
  emulate -L zsh
  reply=()
  REPLY=0
  local root="${1-}"
  [[ "$root" == /* && "$root" == "${root:A}" && -d "$root" ]] || {
    _ws_error "Internal error: invalid workspace root."
    return 1
  }
  _ws_max_depth || return 1
  local -i depth=$REPLY
  _ws_exclusions || return 1
  local -a exclusions=("${reply[@]}")
  _ws_discovery_backend || {
    _ws_error "fd or find is required to discover repositories."
    return 1
  }
  local -a backend=("${reply[@]}")
  local -a scan_command=()
  if [[ "${backend[2]}" == fd ]]; then
    # fd skips hidden directories, and --no-ignore keeps .gitignore rules
    # from hiding repositories. It never follows symbolic links by default.
    scan_command=("${backend[1]}" --no-ignore --type d --max-depth "$depth"
      --print0 --color never . "$root")
  else
    scan_command=("${backend[1]}" "$root" -mindepth 1 -maxdepth "$depth"
      -name '.*' -prune -o -type d -print0)
  fi

  # The status pair follows the NUL-separated data after a final NUL.
  local scan_output=""
  scan_output=$(
    _ws_run_with_timeout "$_WS_SCAN_TIMEOUT" "${scan_command[@]}" \
      </dev/null 2>/dev/null \
      | command head -c "$(( _WS_MAX_SCAN_BYTES + 1 ))"
    print -rn -- $'\0'"status:${pipestatus[1]}:${pipestatus[2]}"
  )
  local status_field="${scan_output##*$'\0'}"
  local scan_data="${scan_output%$'\0'*}"
  [[ "$status_field" =~ '^status:([0-9]+):([0-9]+)$' ]] || {
    _ws_error "Repository discovery returned malformed output."
    return 1
  }
  local -i scan_rc="${match[1]}" limit_rc="${match[2]}"
  _ws_byte_length "$scan_data"
  if (( REPLY > _WS_MAX_SCAN_BYTES )); then
    REPLY=0
    _ws_error "Repository discovery exceeded its output limit; lower WS_MAX_DEPTH or add WS_EXCLUDE entries."
    return 1
  fi
  REPLY=0
  if (( scan_rc == 124 )); then
    _ws_error "Repository discovery timed out after ${_WS_SCAN_TIMEOUT}s; lower WS_MAX_DEPTH or add WS_EXCLUDE entries."
    return 1
  elif (( limit_rc != 0 && limit_rc != 141 )); then
    _ws_error "Repository discovery could not read its results (status $limit_rc)."
    return 1
  elif (( scan_rc == 1 )); then
    # Unreadable directories are reported and skipped; the rest still count.
    _ws_warn "Some directories below the workspace root could not be read."
  elif (( scan_rc != 0 )); then
    _ws_error "Repository discovery failed (status $scan_rc)."
    return 1
  fi

  local -a entries=() candidates=()
  [[ -n "$scan_data" ]] && entries=("${(@0)scan_data}")
  local entry="" relative="" excluded=""
  local -i skipped=0 is_excluded=0
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    while [[ "$entry" != / && "$entry" == */ ]]; do
      entry="${entry%/}"
    done
    [[ "$entry" == "$root"/* ]] || continue
    relative="${entry#$root/}"
    [[ -n "$relative" && "/$relative" != */.* ]] || continue
    is_excluded=0
    for excluded in "${exclusions[@]}"; do
      if [[ "$relative" == "$excluded" || "$relative" == "$excluded"/* ]]; then
        is_excluded=1
        break
      fi
    done
    (( is_excluded )) && continue
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    [[ -e "$entry/.git" || -L "$entry/.git" ]] || continue
    if ! _ws_path_displayable "$relative"; then
      (( ++skipped ))
      continue
    fi
    candidates+=("$relative")
  done

  # A repository inside another found repository, such as a submodule
  # checkout or a vendored clone, belongs to its enclosing repository.
  local -A found=()
  for relative in "${candidates[@]}"; do
    found[$relative]=1
  done
  # Byte order keeps the listing identical on every platform and locale.
  local LC_COLLATE=C
  local -a repositories=()
  local ancestor=""
  local -i nested=0
  for relative in "${(@o)candidates}"; do
    nested=0
    ancestor="$relative"
    while [[ "$ancestor" == */* ]]; do
      ancestor="${ancestor%/*}"
      if (( ${+found[$ancestor]} )); then
        nested=1
        break
      fi
    done
    (( nested )) && continue
    repositories+=("$relative")
    if (( ${#repositories[@]} > _WS_MAX_REPOSITORIES )); then
      _ws_error "More than $_WS_MAX_REPOSITORIES repositories were found; lower WS_MAX_DEPTH or add WS_EXCLUDE entries."
      return 1
    fi
  done

  reply=("${repositories[@]}")
  REPLY=$skipped
  return 0
}

# --- Dispatcher -------------------------------------------------------------

_ws_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    ws-clone)  ws-clone "$@" ;;
    ws-jump)   ws-jump "$@" ;;
    ws-status) ws-status "$@" ;;
    :)         return 0 ;;
    *)
      _ws_error "Unknown Workspace command: $command_name"
      return 2
      ;;
  esac
}

typeset -g _WS_COMMON_SOURCED=1
