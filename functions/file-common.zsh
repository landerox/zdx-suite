#!/usr/bin/env zsh
# =============================================================================
# File Suite: private UI, selection, path, and dispatch primitives
# =============================================================================
#
# Loaded by file-menu.zsh before every module under functions/file/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_FILE_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _FILE_MAX_MENU_ROWS=64
typeset -gi _FILE_MAX_PICKER_BYTES=1048576
typeset -gi _FILE_MAX_CANDIDATES=4096
# Junk files hide in deep trees, so their discovery looks deeper than the
# five levels of the picker inventories; the candidate limits still apply.
typeset -gi _FILE_MAX_JUNK_DEPTH=12
typeset -gi _FILE_MAX_ARCHIVE_ENTRIES=4096
typeset -gi _FILE_MAX_ARCHIVE_BYTES=1073741824
# Bounds for one Linux mount-table snapshot (/proc/self/mountinfo).
typeset -gi _FILE_MAX_MOUNT_RECORDS=16384
typeset -gi _FILE_MAX_MOUNT_TABLE_BYTES=4194304
typeset -g _FILE_SUITE_ROOT="${${(%):-%x}:A:h:h}"

# --- UI --------------------------------------------------------------------

_file_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

# Top-level heading; the core service omits or demotes it inside a step.
_file_header() {
  if (( ${+functions[_zdx_ui_heading]} )); then
    _zdx_ui_heading "${1:-}"
    return
  fi
  if _file_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}

_file_success() {
  if _file_color_enabled; then
    printf '\033[1;32m✔ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✔ %s\n' "${(V)1}" >&2
  fi
}

_file_warn() {
  if _file_color_enabled; then
    printf '\033[1;33m⚠ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⚠ %s\n' "${(V)1}" >&2
  fi
}

_file_info() {
  if _file_color_enabled; then
    printf '\033[0;36m➜ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '➜ %s\n' "${(V)1}" >&2
  fi
}

_file_error() {
  if _file_color_enabled; then
    printf '\033[1;31m✘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✘ %s\n' "${(V)1}" >&2
  fi
}

_file_dim() {
  if _file_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
}

# --- Command output services -------------------------------------------------
# docs/output-spec.md owns the vocabulary and rendering. Each wrapper checks
# the core service at call time and keeps a plain fallback, so a standalone
# source of this suite still works without functions.zsh.

# Key-value fact. Usage: _file_label <key> <value>
_file_label() {
  if (( ${+functions[_zdx_ui_label]} )); then
    _zdx_ui_label "${1-}" "${2-}"
    return
  fi
  printf '  %-18s %s\n' "${(V)${1-}%:}:" "${(V)2-}" >&2
}

# Aligned columns from TAB-separated rows; plain lines when a row is rejected.
# Usage: _file_table <header-tsv> [row-tsv...]
_file_table() {
  if (( ${+functions[_zdx_ui_table]} )); then
    _zdx_ui_table "$@" && return 0
  fi
  local table_row=""
  for table_row in "$@"; do
    _file_dim "${table_row//$'\t'/  }"
  done
}

# REPLY: "<count> <noun>". Usage: _file_count_noun <count> <singular> [plural]
_file_count_noun() {
  if (( ${+functions[_zdx_count_noun]} )); then
    _zdx_count_noun "$@"
    return
  fi
  local count="${1:-}" singular="${2:-}" plural="${3:-${2:-}s}"
  [[ "$count" == <-> && -n "$singular" ]] || return 2
  if (( count == 1 )); then REPLY="1 $singular"; else REPLY="$count $plural"; fi
}

# REPLY: a display-only path with HOME shown as ~.
# Usage: _file_path_display <path>
_file_path_display() {
  if (( ${+functions[_zdx_ui_command_display]} )); then
    _zdx_ui_command_display "${1-}"
    return
  fi
  REPLY="${1-}"
}

# Partial-success timing for a batch that ends with mixed results.
_file_mark_partial() {
  (( ${+functions[_zdx_timed_mark_partial]} )) || return 0
  _zdx_timed_mark_partial || true
}

# True only for ZDX_VERBOSE=1.
_file_verbose() {
  if (( ${+functions[_zdx_ui_verbose]} )); then
    _zdx_ui_verbose
    return
  fi
  [[ "${ZDX_VERBOSE:-0}" == 1 ]]
}

# Prints plan disclosures, in order, from "--warn TEXT" and "--note TEXT"
# pairs: a warning line or a dimmed detail line each. Status 2 means a
# malformed pair.
_file_print_disclosures() {
  while (( $# >= 2 )); do
    case "$1" in
      --warn) _file_warn "$2" ;;
      --note) _file_dim "$2" ;;
      *) return 2 ;;
    esac
    shift 2
  done
  (( $# == 0 )) || return 2
}

_file_timed() {
  local label="$1"
  shift

  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

_file_require_cmd() {
  local command_name="$1"
  local purpose="${2:-this operation}"
  command -v "$command_name" &>/dev/null && return 0
  _file_error "$command_name is required for $purpose."
  return 1
}

# --- Host platform and external tools ----------------------------------------
# Platform branches follow the kernel that uname reports, so tests select a
# branch with a uname mock instead of the host.

# REPLY is the kernel name reported by uname -s, such as Linux or Darwin.
_file_host_kernel() {
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
_file_host_is_wsl() {
  local proc_root="${1:-/proc}" kernel_release="" REPLY=""
  _file_host_kernel && [[ "$REPLY" == Linux ]] || return 1
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  [[ -e "$proc_root/sys/fs/binfmt_misc/WSLInterop" \
    || -e "$proc_root/sys/fs/binfmt_misc/WSLInterop-late" ]] && return 0
  [[ -f "$proc_root/sys/kernel/osrelease" \
    && -r "$proc_root/sys/kernel/osrelease" ]] || return 1
  kernel_release=$(<"$proc_root/sys/kernel/osrelease") 2>/dev/null || return 1
  [[ "${kernel_release:l}" == *microsoft* ]]
}

# Explains a refusal of a path on a Windows drive under WSL. Without DrvFs
# metadata, every file there reports mode 777, so the ownership and
# permission checks refuse it. The refusal itself stays in place.
# Usage: _file_wsl_drive_hint <refused-path>
_file_wsl_drive_hint() {
  local refused="${1-}"
  [[ "$refused" == /mnt/[[:alpha:]] || "$refused" == /mnt/[[:alpha:]]/* ]] \
    || return 0
  _file_host_is_wsl || return 0
  _file_info "Windows drives under /mnt report mode 777 unless WSL mounts them with DrvFs metadata."
  _file_dim "Work in the Linux filesystem, such as ~/projects, or add [automount] options=\"metadata,umask=22,fmask=11\" to /etc/wsl.conf and restart WSL."
}

# REPLY is the absolute path of GNU tar, found as tar or as gtar (Homebrew's
# gnu-tar on macOS). Hardened extraction depends on GNU listing options, so
# bsdtar is never used for it.
_file_gnu_tar_command() {
  REPLY=""
  local candidate="" resolved="" version_text=""
  for candidate in tar gtar; do
    resolved=$(whence -p "$candidate" 2>/dev/null) || continue
    [[ "$resolved" == /* && -x "$resolved" ]] || continue
    version_text=$(LC_ALL=C command "$resolved" --version \
      </dev/null 2>/dev/null) || continue
    [[ "${version_text%%$'\n'*}" == *"GNU tar"* ]] || continue
    REPLY="$resolved"
    return 0
  done
  return 1
}

# reply is the command that creates a TAR archive without platform metadata.
# GNU tar (tar or gtar) is preferred: it stores no macOS metadata by default.
# Otherwise tar is used, with --no-mac-metadata and --no-xattrs when it
# accepts them, as bsdtar on a stock macOS host does, so neither AppleDouble
# ._* members nor extended-attribute headers enter the archive. Callers also
# export COPYFILE_DISABLE=1, which stops macOS tools from adding ._* copies.
_file_tar_create_command() {
  reply=()
  local REPLY=""
  if _file_gnu_tar_command; then
    reply=("$REPLY")
    return 0
  fi
  local tar_command=""
  tar_command=$(whence -p tar 2>/dev/null) || tar_command=""
  [[ "$tar_command" == /* && -x "$tar_command" ]] || return 1
  # Capability probe: an empty archive written to /dev/null.
  if command "$tar_command" --no-mac-metadata --no-xattrs \
    -cf /dev/null -T /dev/null </dev/null >/dev/null 2>&1; then
    reply=("$tar_command" --no-mac-metadata --no-xattrs)
  else
    reply=("$tar_command")
  fi
}

# REPLY is the first 7-Zip command found as 7z, 7zz (7-Zip 21 and newer, as
# Homebrew's sevenzip installs it), or 7za (p7zip's standalone build).
_file_7z_command() {
  REPLY=""
  local candidate="" resolved=""
  for candidate in 7z 7zz 7za; do
    resolved=$(whence -p "$candidate" 2>/dev/null) || continue
    [[ "$resolved" == /* && -x "$resolved" ]] || continue
    REPLY="$resolved"
    return 0
  done
  return 1
}

# reply is the mv command that refuses to replace a destination. GNU and
# uutils mv take -T -n, so an existing directory is never entered. Other
# implementations, such as BSD mv on macOS, take -n only; every caller
# verifies the moved identity afterwards, which detects a destination
# directory that appeared after the last check.
_file_mv_no_clobber_command() {
  reply=()
  local mv_command="" version_text=""
  mv_command=$(whence -p mv 2>/dev/null) || mv_command=""
  [[ "$mv_command" == /* && -x "$mv_command" ]] || {
    _file_error "mv is required to move a reviewed path."
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

_file_system_root_uid() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A root_state=()
  [[ -d / && ! -L / ]] \
    && zstat -LH root_state -- / 2>/dev/null \
    && (( (root_state[mode] & 8#170000) == 8#040000 )) || return 1
  REPLY="${root_state[uid]}"
}

# REPLY is the canonical directory for an absolute, already-normalized path.
# A symbolic link on the literal path is accepted only as a root-owned system
# alias, such as macOS /var and /tmp, or above the final component when the
# current user owns it inside a directory owned by root or the current user
# that group and other users cannot write. This mirrors the core
# _zdx_resolve_trusted_dir so the suite stays sourceable on its own.
_file_resolve_trusted_dir() {
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

# REPLY is the canonical temporary or staging parent. A TMPDIR reached through
# a trusted alias is accepted; the ownership, sticky-bit, and ancestor checks
# apply to the canonical directory.
_file_validate_temp_parent() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local requested_parent="${1:-}"
  local purpose="${2:-temporary files}"
  REPLY=""

  _file_resolve_trusted_dir "$requested_parent" || {
    _file_error "The temporary parent for $purpose is not a real directory."
    return 1
  }
  requested_parent="$REPLY"
  REPLY=""
  [[ -n "$requested_parent" && "$requested_parent" == /* \
    && -d "$requested_parent" && ! -L "$requested_parent" \
    && "$requested_parent" == "${requested_parent:a}" \
    && "$requested_parent" == "${requested_parent:A}" ]] || {
    _file_error "The temporary parent for $purpose is not a real directory."
    return 1
  }

  _file_system_root_uid || return 1
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
    _file_error \
      "The temporary parent for $purpose has unsafe ownership or permissions."
    return 1
  fi
  _file_validate_ancestor_chain "$requested_parent" || return 1
  REPLY="$requested_parent"
}

_file_validate_ancestor_chain() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local child_path="$1"
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1

  _file_system_root_uid || return 1
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
      _file_error \
        "A parent directory is not trusted against replacement: $parent_path"
      _file_wsl_drive_hint "$parent_path"
      return 1
    fi
    child_path="$parent_path"
  done
}

# REPLY is the SHA-256 digest of a regular file's content. The file is opened
# without following a link and hashed through standard input, so its name
# never reaches the digest line (sha256sum and shasum escape a name that
# contains a backslash) and a FIFO cannot block the open.
_file_sha256_digest() {
  emulate -L zsh
  local input_file="$1"
  REPLY=""
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zmodload zsh/system 2>/dev/null || return 1
  local -a digest_command=()
  if command -v sha256sum &>/dev/null; then
    digest_command=(sha256sum)
  elif command -v shasum &>/dev/null; then
    digest_command=(shasum -a 256)
  else
    _file_error "sha256sum or shasum is required for content revalidation."
    return 1
  fi
  local raw_output=""
  local -i input_fd=-1 digest_rc=1
  local -A input_state=()
  sysopen -r -o nofollow,nonblock,cloexec -u input_fd \
    -- "$input_file" 2>/dev/null || return 1
  {
    zstat -H input_state -f "$input_fd" 2>/dev/null \
      && (( (input_state[mode] & 8#170000) == 8#100000 )) || return 1
    raw_output=$(command "${digest_command[@]}" <&$(( input_fd )))
    digest_rc=$?
  } always {
    exec {input_fd}<&-
  }
  (( digest_rc == 0 )) || return 1
  local digest="${raw_output%%[[:space:]]*}"
  digest="${digest:l}"
  [[ "$digest" =~ '^[0-9a-f]{64}$' ]] || return 1
  REPLY="$digest"
}

_file_confirm() {
  local prompt="${1:-Proceed?}"
  local auto_yes="${2:-no}"

  [[ "$auto_yes" == "yes" ]] && return 0
  [[ -t 0 && -t 2 ]] || return 2

  local response=""
  if _file_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi
  read -r response || return 2
  print -u2 -r -- ""
  [[ "$response" =~ ^[Yy]$ ]]
}

# Usage: _file_confirm_mutation <prompt> [auto-yes] [cancellation message]
# Status 130 means the user declined; 2 means no terminal and no --yes.
_file_confirm_mutation() {
  local prompt="$1"
  local auto_yes="${2:-no}"
  local cancelled_message="${3:-Cancelled.}"
  local -i confirm_rc=0

  _file_confirm "$prompt" "$auto_yes" || confirm_rc=$?
  case "$confirm_rc" in
    0) return 0 ;;
    1)
      _file_info "$cancelled_message"
      return 130
      ;;
    *)
      _file_error "Confirmation requires a terminal; pass --yes to proceed."
      return "$confirm_rc"
      ;;
  esac
}

_file_read_line() {
  local prompt="$1"
  local default_value="${2:-}"
  [[ -t 0 && -t 2 ]] || {
    _file_error "Interactive input requires a terminal."
    return 1
  }

  if [[ -n "$default_value" ]]; then
    printf '? %s [%s]: ' "${(V)prompt}" "${(V)default_value}" >&2
  else
    printf '? %s: ' "${(V)prompt}" >&2
  fi
  local response=""
  read -r response || return 1
  response="${response:-$default_value}"
  REPLY="$response"
}

# --- Canonical menu rows ----------------------------------------------------

_file_menu_section() {
  local title="$1"
  local description="${2:-}"

  if [[ "$title" == *'|'* || "$title" == *$'\n'* \
    || "$description" == *'|'* || "$description" == *$'\n'* ]]; then
    _file_error "Invalid menu section fields."
    return 2
  fi

  printf "── %s ──|:|%s\n" "$title" "$description"
}

_file_menu_entry() {
  local label="$1"
  local command_name="$2"
  local description="$3"

  if [[ "$label" == *'|'* || "$label" == *$'\n'* \
    || "$command_name" == *'|'* || "$command_name" == *$'\n'* \
    || "$description" == *'|'* || "$description" == *$'\n'* ]]; then
    _file_error "Invalid menu entry fields."
    return 2
  fi

  local REPLY=""
  _file_menu_missing_requirements "$command_name"
  # docs/menu-spec.md: an unavailable action keeps its command field and is
  # marked by a leading circle plus the requirement written in text.
  if [[ -n "$REPLY" ]]; then
    printf "  ○ %s (missing: %s)|%s|%s\n" \
      "$label" "$REPLY" "$command_name" "$description"
  else
    printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
  fi
}

# REPLY lists the requirements without which an action cannot run at all on
# this host, for its menu label; it is empty when the action can run. This is
# advisory: each command repeats its own checks. A missing 7z, for example,
# leaves the other compression formats available.
_file_menu_missing_requirements() {
  local command_name="${1-}" missing=""
  case "$command_name" in
    file-extract)
      _file_gnu_tar_command || missing="GNU tar"
      ;;
    file-compress)
      if ! command -v tar &>/dev/null && ! command -v zip &>/dev/null \
        && ! _file_7z_command; then
        missing="tar or zip or 7z"
      fi
      ;;
  esac
  REPLY="$missing"
}

_file_array_contains_literal() {
  local needle="${1-}" candidate=""
  shift 2>/dev/null || return 2
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

# --- Foreground fzf capture -------------------------------------------------

_file_fzf() {
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
    SHELL=/bin/sh fzf "${fzf_options[@]}" "$@" "${terminal_options[@]}"
}

_file_fzf_capture() {
  emulate -L zsh

  REPLY=""
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
    _file_error "Zsh file-descriptor support is required for File pickers."
    return 125
  }

  _file_validate_temp_parent "${TMPDIR:-/tmp}" "the File picker" || return 125
  local temp_root="$REPLY"

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-file-fzf.XXXXXX" 2>/dev/null) || {
    _file_error "Could not create a private File picker directory."
    return 125
  }
  command chmod -- 700 "$capture_dir" 2>/dev/null || {
    command rmdir -- "$capture_dir" 2>/dev/null
    _file_error "Could not protect the File picker directory."
    return 125
  }

  local -A capture_dir_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || ! -d "$capture_dir" || -L "$capture_dir" \
    || "${capture_dir:t}" != zdx-file-fzf.* ]] \
    || ! zstat -LH capture_dir_state -- "$capture_dir" 2>/dev/null \
    || (( (capture_dir_state[mode] & 8#170000) != 8#040000 \
      || capture_dir_state[uid] != EUID \
      || (capture_dir_state[mode] & 8#77) != 0 )); then
    command rmdir -- "$capture_dir" 2>/dev/null
    _file_error "Refusing an unsafe File picker directory."
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
      _file_error "Could not create a private File picker result."
    elif ! command chmod -- 600 "$capture_file" 2>/dev/null; then
      _file_error "Could not protect the File picker result."
    elif [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$capture_dir" \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH capture_file_state -- "$capture_file" 2>/dev/null \
      || (( (capture_file_state[mode] & 8#170000) != 8#100000 \
        || capture_file_state[uid] != EUID \
        || capture_file_state[nlink] != 1 \
        || (capture_file_state[mode] & 8#77) != 0 )); then
      _file_error "Refusing an unsafe File picker result."
    else
      capture_file_identity="${capture_file_state[device]}:${capture_file_state[inode]}:${capture_file_state[mode]}:${capture_file_state[uid]}:${capture_file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u capture_fd \
        -- "$capture_file" 2>/dev/null; then
        _file_error "Could not open the File picker result safely."
      else
        _file_fzf "$@" 1>&$(( capture_fd ))
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
            || current_file_state[size] > _FILE_MAX_PICKER_BYTES )); then
          _file_error "The File picker result changed or is oversized."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _file_error "Could not read the File picker result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          operation_rc=$fzf_rc
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
        && "${capture_file:a}" == "$capture_file" \
        && "${capture_file:A}" == "$capture_file" \
        && "${capture_file:h}" == "$capture_dir" ]] \
        && zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
        && [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
          == "$capture_file_identity" ]]; then
        command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
      else
        _file_warn "The File picker result changed; refusing cleanup."
        cleanup_failed=1
      fi
    fi

    current_dir_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" \
      && "${capture_dir:a}" == "$capture_dir" \
      && "${capture_dir:A}" == "$capture_dir" \
      && "${capture_dir:t}" == zdx-file-fzf.* ]] \
      && zstat -LH current_dir_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_dir_state[device]}:${current_dir_state[inode]}:${current_dir_state[mode]}:${current_dir_state[uid]}" \
        == "$capture_dir_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      _file_warn "The File picker directory changed; refusing cleanup."
      cleanup_failed=1
    fi

    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_file_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

_file_choose_fixed() {
  local prompt="$1"
  shift
  local -a choices=("$@")
  local selected=""
  local -i fzf_rc=0

  _file_fzf_capture \
    --height='50%' \
    --prompt="${prompt} > " \
    < <(print -rl -- "${choices[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _file_fzf_rc_is_cancel "$fzf_rc" && return 130
    _file_error "The File picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 130
  _file_array_contains_literal "$selected" "${choices[@]}" || {
    _file_error "The selection was not in the current snapshot."
    return 1
  }
  REPLY="$selected"
}

# --- Path inventory and selection ------------------------------------------

_file_path_is_displayable() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *[[:cntrl:]]* ]]
}

# True when find supports the GNU predicates junk discovery uses
# (-readable, -executable, and -printf). BSD find on macOS does not.
_file_find_has_gnu_predicates() {
  command find . -maxdepth 0 -readable -executable -printf '' \
    </dev/null >/dev/null 2>&1
}

# Prints the records of the GNU junk-discovery expression in
# _file_collect_paths without GNU find: "<root>/<path>\0" for each regular
# file with an exact junk name and "<root>/<dir>/\0" for a directory that
# cannot be listed, which is not entered. Links are never followed, pruned
# trees are never entered, and entries deeper than _FILE_MAX_JUNK_DEPTH are
# not examined. A directory that becomes unreadable while it is listed fails
# the walk instead of hiding its entries.
# Usage: _file_junk_walk <root>
_file_junk_walk() {
  emulate -L zsh
  local scan_root="${1:-.}"
  [[ -d "$scan_root" && -r "$scan_root" && -x "$scan_root" ]] || return 1
  local -a pending=("$scan_root") next=() directories=() files=()
  local directory="" entry=""
  local -i depth=0
  while (( ${#pending[@]} > 0 && depth < _FILE_MAX_JUNK_DEPTH )); do
    (( ++depth ))
    next=()
    for directory in "${pending[@]}"; do
      # Qualifiers test the entry itself: / is a real directory and . a
      # regular file, so links never match either list.
      directories=("$directory"/*(DNoN/))
      files=("$directory"/(*:Zone.Identifier|.DS_Store|._*|Thumbs.db|desktop.ini)(DNoN.))
      if (( ${#directories[@]} == 0 && ${#files[@]} == 0 )) \
        && [[ ! -r "$directory" || ! -x "$directory" ]]; then
        return 1
      fi
      for entry in "${files[@]}"; do
        print -rn -- "$entry"$'\0' || return 1
      done
      for entry in "${directories[@]}"; do
        case "${entry:t}" in
          .git|*.git|node_modules|.venv|.tmp|vendor|vendored) continue ;;
          site-packages|dist-packages|.tox|.nox) continue ;;
        esac
        if [[ ! -r "$entry" || ! -x "$entry" ]]; then
          print -rn -- "$entry/"$'\0' || return 1
          continue
        fi
        next+=("$entry")
      done
    done
    pending=("${next[@]}")
  done
  return 0
}

_file_collect_paths() {
  emulate -L zsh
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
    _file_error "Zsh file-descriptor support is required for path scans."
    return 1
  }
  _file_require_cmd head "bounded path scanning" || return 1
  local mode="$1"
  local scan_root="${2:-.}"
  reply=()

  local -a find_command=(command find "$scan_root")
  # The junk scan's GNU predicates have a portable Zsh walker for BSD find.
  local -a producer_command=()
  local node_filter="all"
  case "$mode" in
    immediate)
      find_command+=(-mindepth 1 -maxdepth 1)
      ;;
    directories)
      find_command+=(-mindepth 1 -maxdepth 1)
      node_filter="directory"
      ;;
    recursive-directories)
      find_command+=(-mindepth 1 -maxdepth 5)
      node_filter="directory"
      ;;
    files)
      find_command+=(-mindepth 1 -maxdepth 5)
      node_filter="file"
      ;;
    recursive)
      find_command+=(-mindepth 1 -maxdepth 5)
      ;;
    junk)
      find_command+=(-mindepth 1 -maxdepth "$_FILE_MAX_JUNK_DEPTH")
      node_filter="junk"
      ;;
    *)
      _file_error "Unknown inventory mode: $mode"
      return 2
      ;;
  esac
  if [[ "$node_filter" == "junk" ]] && ! _file_find_has_gnu_predicates; then
    producer_command=(_file_junk_walk "$scan_root")
  elif [[ "$node_filter" == "junk" ]]; then
    # Regular files with an exact junk name only; links are never followed
    # or returned. Repository metadata and generated, vendored, and
    # installed-package trees are pruned. A directory that cannot be listed
    # is returned as one record with a trailing slash instead of failing
    # the whole scan.
    find_command+=(
      \( -type d \(
        -name .git -o -name '*.git' -o -name node_modules -o -name .venv
        -o -name .tmp -o -name vendor -o -name vendored
        -o -name site-packages -o -name dist-packages
        -o -name .tox -o -name .nox
      \) -prune \)
      -o \( -type d \( '!' -readable -o '!' -executable \)
        -printf '%p/\0' -prune \)
      -o \( -type f \(
        -name '*:Zone.Identifier' -o -name .DS_Store -o -name '._*'
        -o -name Thumbs.db -o -name desktop.ini
      \) -print0 \)
    )
  else
    find_command+=(
      \(
        -name .git
        -o -name node_modules
        -o -name .venv
        -o -name .tmp
      \)
      -prune
      -o
    )
    [[ "$node_filter" == "directory" ]] && find_command+=(-type d)
    [[ "$node_filter" == "file" ]] && find_command+=(-type f)
    find_command+=(-print0)
  fi
  (( ${#producer_command[@]} > 0 )) || producer_command=("${find_command[@]}")

  _file_validate_temp_parent "${TMPDIR:-/tmp}" "path scanning" || return 1
  local temp_root="$REPLY"
  local inventory_file=""
  inventory_file=$(umask 077; command mktemp \
    "$temp_root/zdx-file-scan.XXXXXX" 2>/dev/null) || {
    _file_error "Could not create a private path inventory."
    return 1
  }
  command chmod -- 600 "$inventory_file" 2>/dev/null || {
    command rm -f -- "$inventory_file" 2>/dev/null
    return 1
  }
  local -A initial_state=() current_state=()
  if [[ ! -f "$inventory_file" || -L "$inventory_file" \
    || "$inventory_file" != "${inventory_file:a}" \
    || "$inventory_file" != "${inventory_file:A}" ]] \
    || ! zstat -LH initial_state -- "$inventory_file" 2>/dev/null \
    || (( initial_state[uid] != EUID \
      || initial_state[nlink] != 1 \
      || (initial_state[mode] & 8#77) != 0 )); then
    command rm -f -- "$inventory_file" 2>/dev/null
    _file_error "Refusing an unsafe path inventory."
    return 1
  fi
  local inventory_identity="${initial_state[device]}:${initial_state[inode]}:${initial_state[mode]}:${initial_state[uid]}:${initial_state[nlink]}"

  local candidate=""
  local -a scanned_paths=()
  local -i count=0 scan_rc=1 cleanup_rc=0
  local -i write_fd=-1 read_fd=-1
  {
    if ! sysopen -w -o nofollow,cloexec -u write_fd \
      -- "$inventory_file" 2>/dev/null; then
      _file_error "Could not open the path inventory safely."
      return 1
    fi
    setopt local_options pipefail
    "${producer_command[@]}" 2>/dev/null \
      | command head -c "$(( _FILE_MAX_PICKER_BYTES + 1 ))" \
        1>&$(( write_fd ))
    scan_rc=$?
    exec {write_fd}>&-
    write_fd=-1

    current_state=()
    zstat -LH current_state -- "$inventory_file" 2>/dev/null || return 1
    [[ "${current_state[device]}:${current_state[inode]}:${current_state[mode]}:${current_state[uid]}:${current_state[nlink]}" \
      == "$inventory_identity" ]] || {
      _file_error "The path inventory changed unexpectedly."
      return 1
    }
    (( current_state[size] <= _FILE_MAX_PICKER_BYTES )) || {
      _file_error \
        "Candidate inventory exceeds the $_FILE_MAX_PICKER_BYTES byte limit."
      return 1
    }
    (( scan_rc == 0 )) || {
      _file_error "Could not scan candidate paths."
      return 1
    }
    if ! sysopen -r -o nofollow,cloexec -u read_fd \
      -- "$inventory_file" 2>/dev/null; then
      return 1
    fi
    while IFS= read -r -d '' candidate <&$(( read_fd )); do
      [[ "$candidate" == */.git || "$candidate" == */.git/* \
        || "$candidate" == */node_modules || "$candidate" == */node_modules/* \
        || "$candidate" == */.venv || "$candidate" == */.venv/* \
        || "$candidate" == */.tmp || "$candidate" == */.tmp/* ]] && continue
      [[ "$node_filter" == "junk" \
        && "$candidate" == */(vendor|vendored|site-packages|dist-packages|.tox|.nox|*.git)/* ]] \
        && continue
      candidate="${candidate#./}"
      _file_path_is_displayable "$candidate" || {
        if [[ "$node_filter" == "junk" ]]; then
          _file_warn "Skipped a path whose name contains control characters."
        else
          _file_warn "Excluded a path that cannot be represented safely in fzf."
        fi
        continue
      }
      scanned_paths+=("$candidate")
      (( ++count <= _FILE_MAX_CANDIDATES )) || {
        _file_error \
          "Candidate inventory exceeds the $_FILE_MAX_CANDIDATES entry limit."
        return 1
      }
    done
    exec {read_fd}>&-
    read_fd=-1
    reply=("${scanned_paths[@]}")
    scan_rc=0
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-
    current_state=()
    if [[ -f "$inventory_file" && ! -L "$inventory_file" ]] \
      && zstat -LH current_state -- "$inventory_file" 2>/dev/null \
      && [[ "${current_state[device]}:${current_state[inode]}:${current_state[mode]}:${current_state[uid]}:${current_state[nlink]}" \
        == "$inventory_identity" ]]; then
      command rm -f -- "$inventory_file" 2>/dev/null || cleanup_rc=1
    else
      _file_warn "The path inventory changed; refusing cleanup."
      cleanup_rc=1
    fi
    (( cleanup_rc == 0 )) || scan_rc=1
  }
  return $scan_rc
}

_file_select_from_snapshot() {
  local prompt="$1"
  local multi_select="$2"
  local paths_name="$3"
  local -a paths=("${(@P)paths_name}")
  reply=()
  (( ${#paths[@]} > 0 )) || return 130

  local -a rows=()
  local -i index=1
  local item=""
  for item in "${paths[@]}"; do
    rows+=("${index}|${(V)item}")
    (( ++index ))
  done

  local -a fzf_options=(
    --height='75%'
    --delimiter='[|]'
    --with-nth=2
    --prompt="${prompt} > "
  )
  [[ "$multi_select" == "yes" ]] && fzf_options+=(
    --multi
    --header='Tab select multiple | Enter confirm | Esc cancel'
  )

  local selected=""
  local -i fzf_rc=0
  _file_fzf_capture "${fzf_options[@]}" \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _file_fzf_rc_is_cancel "$fzf_rc" && return 130
    _file_error "The File picker failed (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 130

  local -a selected_rows=("${(@f)selected}")
  local selected_row=""
  local selected_index=""
  for selected_row in "${selected_rows[@]}"; do
    _file_array_contains_literal "$selected_row" "${rows[@]}" || {
      _file_error "A selected path was not in the current snapshot."
      return 1
    }
    selected_index="${selected_row%%|*}"
    [[ "$selected_index" == <-> \
      && selected_index -ge 1 \
      && selected_index -le ${#paths[@]} ]] || {
      _file_error "A selected path index is invalid."
      return 1
    }
    reply+=("${paths[selected_index]}")
  done
}

_file_select_paths() {
  local prompt="$1"
  local multi_select="${2:-yes}"
  local kind="${3:-all}"
  reply=()

  _file_require_cmd fzf "interactive path selection" || return 1
  local inventory_mode="immediate"
  case "$kind" in
    files) inventory_mode="files" ;;
    directories) inventory_mode="directories" ;;
    all) inventory_mode="immediate" ;;
    *)
      _file_error "Unknown path selection kind: $kind"
      return 2
      ;;
  esac

  _file_collect_paths "$inventory_mode" "." || return $?
  local -a candidates=("${reply[@]}")
  if (( ${#candidates[@]} == 0 )); then
    _file_warn "No matching files or directories were found."
    return 130
  fi
  _file_select_from_snapshot "$prompt" "$multi_select" candidates
}

# --- Mutation boundaries ---------------------------------------------------

# REPLY is the canonical operation base. The working directory may be reached
# through trusted aliases (_file_resolve_trusted_dir), such as macOS /tmp or
# a root-owned /home link, but the base itself is a real directory, and the
# ownership, mode, and ancestor checks apply to its canonical path.
_file_validate_base() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local candidate="${1:-$PWD}"
  REPLY=""
  local lexical="${candidate:a}"
  _file_resolve_trusted_dir "$lexical" || {
    _file_error \
      "The operation base must be a real directory reached without untrusted symbolic links."
    return 1
  }
  local base="$REPLY"
  REPLY=""
  [[ -d "$base" && ! -L "$base" && "$base" == "${base:A}" ]] || {
    _file_error "The operation base must be a real directory."
    return 1
  }
  [[ "$base" != "/" ]] || {
    _file_error "The filesystem root cannot be an operation base."
    return 1
  }
  local -A base_state=()
  zstat -LH base_state -- "$base" 2>/dev/null || return 1
  (( base_state[uid] == EUID && (base_state[mode] & 8#22) == 0 )) || {
    _file_error \
      "The operation base must be owned and not group/world-writable."
    _file_wsl_drive_hint "$base"
    return 1
  }
  _file_validate_ancestor_chain "$base" || return 1
  REPLY="$base"
}

# REPLY is the absolute form of a requested path below a canonical base. A
# relative path is joined to the base itself, not to a working directory that
# reached it through an alias. An absolute path through a trusted alias of
# its parent directory, such as /tmp/work/file on macOS, maps to the
# canonical parent. Callers still check containment, links, and identity.
# Usage: _file_path_in_base <path> <canonical-base>
_file_path_in_base() {
  emulate -L zsh
  local requested="${1-}" base="${2-}" absolute=""
  if [[ "$requested" == /* ]]; then
    absolute="${requested:a}"
  else
    absolute="${base}/${requested}"
    absolute="${absolute:a}"
  fi
  if [[ "$requested" == /* && "$absolute" != "$base"/* \
    && "$absolute" != / ]] \
    && _file_resolve_trusted_dir "${absolute:h}"; then
    absolute="${REPLY%/}/${absolute:t}"
  fi
  REPLY="$absolute"
}

_file_path_fingerprint() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local target="$1"
  local -A state=()
  zstat -LH state -- "$target" 2>/dev/null || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}:${state[nlink]}:${state[size]}:${state[mtime]}:${state[ctime]}"
}

_file_fingerprint_node_identity() {
  local fingerprint="$1"
  local -a fields=("${(@s/:/)fingerprint}")
  (( ${#fields[@]} == 8 )) || return 1
  REPLY="${(j/:/)fields[1,5]}"
}

_file_directory_identity() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local directory="$1"
  local -A state=()
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  zstat -LH state -- "$directory" 2>/dev/null || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}"
}

_file_node_identity() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local node="$1"
  local -A state=()
  [[ ( -e "$node" || -L "$node" ) && ! -L "$node" ]] || return 1
  zstat -LH state -- "$node" 2>/dev/null || return 1
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}:${state[nlink]}"
}

# --- Mount boundaries ---------------------------------------------------------
# Mutations refuse a mount at a target or below a directory target. Linux and
# WSL compare canonical paths with one snapshot of the kernel mount table
# (/proc/self/mountinfo, the table findmnt reads), which also lists bind
# mounts. macOS has no bind mounts, so a node whose device differs from its
# parent's is a mount point there. Other kernels fail closed.
#
# A pass that checks many nodes declares, without loading them,
#   local _file_mount_mode=""
#   local -A _file_mount_targets=()
# and every check below then shares one snapshot, loaded on first use.
# Resetting _file_mount_mode to "" makes the next check reload it. A check
# outside such a pass takes a private snapshot.

# REPLY is the Linux mount table read by _file_mount_snapshot.
_file_mount_table_path() {
  REPLY=/proc/self/mountinfo
}

# Loads the snapshot into the caller's _file_mount_mode (table or device) and
# _file_mount_targets (decoded mount points, table mode only).
_file_mount_snapshot() {
  emulate -L zsh
  setopt local_options no_multibyte
  (( ${+_file_mount_mode} && ${+_file_mount_targets} )) || return 1
  _file_mount_mode=""
  _file_mount_targets=()
  local REPLY=""
  _file_host_kernel || {
    _file_error "Could not identify the host kernel for mount-boundary validation."
    return 1
  }
  case "$REPLY" in
    Darwin)
      _file_mount_mode=device
      return 0
      ;;
    Linux) ;;
    *)
      _file_error \
        "Recursive mount-boundary validation is not supported on ${REPLY}."
      return 1
      ;;
  esac
  zmodload zsh/system 2>/dev/null || return 1
  _file_mount_table_path
  local table_path="$REPLY" table="" chunk=""
  local -i table_fd=-1 read_rc=0
  sysopen -r -o cloexec -u table_fd -- "$table_path" 2>/dev/null || {
    _file_error "Could not read the mount table: $table_path"
    return 1
  }
  {
    while true; do
      chunk=""
      sysread -s 65536 -i "$table_fd" chunk
      read_rc=$?
      (( read_rc == 0 )) || break
      table+="$chunk"
      (( ${#table} <= _FILE_MAX_MOUNT_TABLE_BYTES )) || {
        _file_error "The mount table exceeds its validation size limit."
        return 1
      }
    done
  } always {
    exec {table_fd}<&-
  }
  # sysread returns 5 at the end of the file.
  (( read_rc == 5 )) || {
    _file_error "Could not read the mount table: $table_path"
    return 1
  }

  # Field 5 of each mountinfo record is the mount point, with every space,
  # tab, newline, and backslash written as a three-digit octal escape.
  local line="" mount_point=""
  local -a fields=()
  local -i count=0
  for line in "${(@f)table}"; do
    [[ -n "$line" ]] || continue
    (( ++count <= _FILE_MAX_MOUNT_RECORDS )) || {
      _file_error "The mount table exceeds its validation entry limit."
      return 1
    }
    fields=(${(s: :)line})
    mount_point="${fields[5]-}"
    [[ "$mount_point" == /* \
      && "${mount_point//\\[0-7][0-7][0-7]/}" != *\\* ]] || {
      _file_error "Could not parse the mount table."
      return 1
    }
    mount_point="${(g:o:)mount_point}"
    _file_mount_targets[$mount_point]=1
  done
  (( count > 0 )) || {
    _file_error "The mount table was empty."
    return 1
  }
  _file_mount_mode=table
}

# REPLY is the device number of a path itself (lstat).
_file_path_device() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A device_state=()
  REPLY=""
  zstat -LH device_state -- "${1-}" 2>/dev/null || return 1
  REPLY="${device_state[device]}"
}

# True when a canonical node and its parent directory share one device.
_file_node_on_parent_device() {
  local node="${1-}" REPLY="" node_device=""
  [[ "$node" == /?* ]] || return 1
  _file_path_device "$node" || return 1
  node_device="$REPLY"
  _file_path_device "${node:h}" || return 1
  [[ -n "$node_device" && "$node_device" == "$REPLY" ]]
}

# Status 0 when no mount sits at a canonical node.
_file_mountpoint_clear() {
  local node="$1"
  if (( ! ${+_file_mount_mode} )); then
    local _file_mount_mode=""
    local -A _file_mount_targets=()
  fi
  if [[ -z "$_file_mount_mode" ]]; then
    _file_mount_snapshot || return 1
  fi
  case "$_file_mount_mode" in
    table)
      (( ! ${+_file_mount_targets[$node]} )) || {
        _file_error "Refusing a recursive operation across a mount: $node"
        return 1
      }
      ;;
    device)
      _file_node_on_parent_device "$node" || {
        _file_error "Refusing a recursive operation across a mount: $node"
        return 1
      }
      ;;
    *)
      _file_error "Could not verify a recursive mount boundary."
      return 1
      ;;
  esac
}

# Status 0 when the snapshot lists no mount at or below a canonical directory.
# Device mode checks every inventoried node instead (see
# _file_validate_tree_for_transfer).
_file_mount_table_clear_below() {
  local tree_root="$1" mount_point=""
  [[ "${_file_mount_mode:-}" == table ]] || return 0
  for mount_point in "${(@k)_file_mount_targets}"; do
    if [[ "$mount_point" == "$tree_root" || "$mount_point" == "$tree_root"/* ]]; then
      _file_error "Refusing a recursive operation across a mount: $mount_point"
      return 1
    fi
  done
}

_file_delete_mounts_clear() {
  local target="$1"
  if [[ -d "$target" && ! -L "$target" ]]; then
    _file_validate_tree_for_transfer "$target"
  else
    _file_mountpoint_clear "$target"
  fi
}

_file_validate_mutation_target() {
  local target="$1"
  local base="$2"
  REPLY=""
  [[ -n "$target" && "$target" != *[[:cntrl:]]* \
    && "$target" != *'|'* ]] || {
    _file_error "Refusing an empty or unrepresentable path."
    return 1
  }
  _file_path_in_base "$target" "$base"
  local lexical="$REPLY"
  REPLY=""
  [[ "$lexical" == "$base"/* ]] || {
    _file_error "Refusing a target outside the operation base: $target"
    return 1
  }
  [[ "$lexical" != "$base" \
    && "$lexical" != "/" \
    && "$lexical" != "${HOME:A}" \
    && "$lexical" != "$_FILE_SUITE_ROOT" ]] || {
    _file_error "Refusing a protected target: $target"
    return 1
  }
  [[ ( -f "$lexical" || -d "$lexical" ) \
    && ! -L "$lexical" \
    && "$lexical" == "${lexical:A}" ]] || {
    _file_error "Mutation targets must exist and contain no symbolic links: $target"
    return 1
  }
  _file_validate_ancestor_chain "$lexical" || return 1
  local -A target_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -LH target_state -- "$lexical" 2>/dev/null || {
    _file_error "Could not inspect mutation target: $target"
    return 1
  }
  if (( target_state[uid] != EUID || target_state[nlink] < 1 \
    || (target_state[mode] & 8#22) != 0 )); then
    _file_error "Mutation target ownership or permissions are unsafe: $target"
    return 1
  fi
  if [[ -f "$lexical" ]] && (( target_state[nlink] != 1 )); then
    _file_error "Mutation targets may not be hard-linked files: $target"
    return 1
  fi
  _file_path_fingerprint "$lexical" || {
    _file_error "Could not fingerprint mutation target: $target"
    return 1
  }
  local identity="$REPLY"
  REPLY="${lexical}|${identity}"
}

# Status 0 while a planned target keeps its reviewed fingerprint. A target
# reviewed as a symbolic link, which only the trash plans, is checked as the
# link itself below a canonical parent and is never followed; every other
# target must be a canonical path without links.
_file_revalidate_mutation_target() {
  local target="$1"
  local expected_identity="$2"
  local -a expected_fields=("${(@s/:/)expected_identity}")
  if (( ${#expected_fields[@]} == 8 \
    && (${expected_fields[3]:-0} & 8#170000) == 8#120000 )); then
    [[ -L "$target" && "${target:h}" == "${target:h:A}" ]] || {
      _file_error "A planned target changed before execution: $target"
      return 1
    }
  else
    [[ -e "$target" && ! -L "$target" && "$target" == "${target:A}" ]] || {
      _file_error "A planned target changed before execution: $target"
      return 1
    }
  fi
  _file_path_fingerprint "$target" || return 1
  [[ "$REPLY" == "$expected_identity" ]] || {
    _file_error "A planned target changed identity before execution: $target"
    return 1
  }
}

_file_validate_destination_parent() {
  local destination="$1"
  local base_dir="${2:-${PWD:A}}"
  REPLY=""
  reply=()
  [[ -n "$destination" && "$destination" != *[[:cntrl:]]* \
    && "$destination" != *'|'* ]] || return 1
  _file_path_in_base "$destination" "$base_dir"
  local absolute="$REPLY"
  REPLY=""
  local parent="${absolute:h}"
  [[ "$base_dir" == "${base_dir:A}" \
    && "$absolute" == "$base_dir"/* \
    && "$absolute" != "$base_dir" ]] || {
    _file_error "The destination must be a child of the current operation base."
    return 1
  }
  [[ -d "$parent" && ! -L "$parent" && "$parent" == "${parent:A}" ]] || {
    _file_error "The destination parent must be a real, symlink-free directory."
    return 1
  }
  [[ ! -L "$absolute" ]] || {
    _file_error "Refusing a symbolic-link destination: $destination"
    return 1
  }
  _file_directory_identity "$parent" || return 1
  local parent_identity="$REPLY"
  local -A parent_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -LH parent_state -- "$parent" 2>/dev/null || return 1
  (( parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )) || {
    _file_error \
      "The destination parent must be owned and not group/world-writable."
    return 1
  }
  _file_validate_ancestor_chain "$parent" || return 1
  reply=("$absolute" "$parent_identity")
  REPLY="$absolute"
}

_file_revalidate_parent() {
  local destination="$1"
  local expected_identity="$2"
  local parent="${destination:h}"
  [[ -d "$parent" && ! -L "$parent" && "$parent" == "${parent:A}" ]] \
    || return 1
  _file_directory_identity "$parent" || return 1
  [[ "$REPLY" == "$expected_identity" ]] || {
    _file_error "The destination parent changed after planning."
    return 1
  }
}

_file_validate_private_temp() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local candidate="$1" parent="$2" prefix="$3" kind="$4"
  [[ -n "$candidate" && "$candidate" == "${candidate:a}" \
    && "$candidate" == "${candidate:A}" \
    && "${candidate:h}" == "$parent" \
    && "${candidate:t}" == "$prefix"?????? \
    && ! -L "$candidate" ]] || return 1
  local -A state=()
  zstat -LH state -- "$candidate" 2>/dev/null || return 1
  (( state[uid] == EUID && (state[mode] & 8#77) == 0 )) || return 1
  case "$kind" in
    file)
      [[ -f "$candidate" ]] \
        && (( (state[mode] & 8#170000) == 8#100000 \
          && state[nlink] == 1 && state[size] == 0 ))
      ;;
    directory)
      [[ -d "$candidate" ]] \
        && (( (state[mode] & 8#170000) == 8#040000 ))
      ;;
    *) return 2 ;;
  esac
}

_file_make_sibling_temp() {
  local destination="$1"
  REPLY=""
  local parent="${destination:h}"
  _file_validate_temp_parent "$parent" "same-directory staging" || return 1
  parent="$REPLY"
  local name="${destination:t}"
  local temp_file=""
  temp_file=$(umask 077; command mktemp \
    "${parent}/.${name}.zdx.XXXXXX" 2>/dev/null) || {
    _file_error "Could not create a private staging file."
    return 1
  }
  _file_validate_private_temp \
    "$temp_file" "$parent" ".${name}.zdx." file || {
    _file_error "Refusing an unsafe staging file."
    return 1
  }
  REPLY="$temp_file"
}

_file_output_snapshot() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local destination="$1"
  REPLY="absent"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" \
      && "$destination" == "${destination:A}" ]] || {
      _file_error "An existing output must be a real regular file."
      return 1
    }
    _file_path_fingerprint "$destination" || return 1
    local output_identity="$REPLY"
    local -A output_state=()
    zstat -LH output_state -- "$destination" 2>/dev/null || return 1
    (( output_state[uid] == EUID && output_state[nlink] == 1 \
      && (output_state[mode] & 8#22) == 0 )) || {
      _file_error \
        "An existing output must be owned, protected, and singly linked."
      return 1
    }
    _file_sha256_digest "$destination" || return 1
    local output_digest="$REPLY"
    _file_path_fingerprint "$destination" || return 1
    [[ "$REPLY" == "$output_identity" ]] || {
      _file_error "The existing output changed while it was inspected."
      return 1
    }
    REPLY="file|${output_identity}|${output_digest}"
  fi
}

_file_revalidate_output_snapshot() {
  local destination="$1"
  local expected_state="$2"
  if [[ "$expected_state" == "absent" ]]; then
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
      _file_error "The output appeared after planning: $destination"
      return 1
    }
    return 0
  fi

  [[ "$expected_state" == file\|*\|* \
    && -f "$destination" && ! -L "$destination" \
    && "$destination" == "${destination:A}" ]] || {
    _file_error "The output changed type after planning: $destination"
    return 1
  }
  local snapshot_body="${expected_state#file|}"
  local expected_identity="${snapshot_body%|*}"
  local expected_digest="${snapshot_body##*|}"
  _file_path_fingerprint "$destination" || return 1
  [[ "$REPLY" == "$expected_identity" ]] || {
    _file_error "The output changed identity after planning: $destination"
    return 1
  }
  _file_sha256_digest "$destination" || return 1
  [[ "$REPLY" == "$expected_digest" ]] || {
    _file_error "The output content changed after planning: $destination"
    return 1
  }
  _file_path_fingerprint "$destination" || return 1
  [[ "$REPLY" == "$expected_identity" ]] || {
    _file_error "The output changed while it was revalidated: $destination"
    return 1
  }
}

_file_publish_staged_file() {
  local staged_file="$1"
  local destination="$2"
  local expected_state="$3"
  local parent_identity="${4:-}"
  local -i publish_rc=0
  [[ -f "$staged_file" && ! -L "$staged_file" ]] || return 1
  _file_path_fingerprint "$staged_file" || return 1
  _file_fingerprint_node_identity "$REPLY" || return 1
  local staged_node_identity="$REPLY"
  _file_sha256_digest "$staged_file" || return 1
  local staged_digest="$REPLY"
  [[ -z "$parent_identity" ]] \
    || _file_revalidate_parent "$destination" "$parent_identity" || return 1
  _file_revalidate_output_snapshot "$destination" "$expected_state" || return 1

  if [[ "$expected_state" == "absent" ]]; then
    command ln -- "$staged_file" "$destination" 2>/dev/null || {
      publish_rc=$?
      _file_error "Could not publish the output without clobbering."
      return $publish_rc
    }
    command rm -f -- "$staged_file" 2>/dev/null || {
      publish_rc=$?
      _file_warn "Published output, but could not remove its staging link."
      return $publish_rc
    }
  else
    command mv -f -- "$staged_file" "$destination" 2>/dev/null || {
      publish_rc=$?
      _file_error "Could not publish the staged output."
      return $publish_rc
    }
  fi

  [[ ! -e "$staged_file" && ! -L "$staged_file" \
    && -f "$destination" && ! -L "$destination" ]] || {
    _file_error "The staged output did not publish atomically."
    return 1
  }
  _file_sha256_digest "$destination" || return 1
  [[ "$REPLY" == "$staged_digest" ]] || {
    _file_error "The published output does not match staging."
    return 1
  }
  _file_node_identity "$destination" || return 1
  [[ "$REPLY" == "$staged_node_identity" ]] || {
    _file_error "The published output identity does not match staging."
    return 1
  }
  local -A published_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -LH published_state -- "$destination" 2>/dev/null || return 1
  (( published_state[uid] == EUID && published_state[nlink] == 1 )) || {
    _file_error "The published output has an unsafe link or owner state."
    return 1
  }
  [[ -z "$parent_identity" ]] \
    || _file_revalidate_parent "$destination" "$parent_identity" || return 1
}

# --- Dispatcher -------------------------------------------------------------

_file_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    file-compress)   file-compress "$@" ;;
    file-extract)    file-extract "$@" ;;
    file-find-large) file-find-large "$@" ;;
    file-trash)      file-trash "$@" ;;
    file-clean-junk) file-clean-junk "$@" ;;
    :)               return 0 ;;
    *)
      _file_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

typeset -g _FILE_COMMON_SOURCED=1
