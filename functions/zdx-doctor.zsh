#!/usr/bin/env zsh
# =============================================================================
# ZDX Doctor: dependency diagnostics and opt-in package installation
# =============================================================================
#
# Loaded lazily by functions.zsh and routed by zdx-menu.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_ZDX_DOCTOR_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Keep source bytes raw; pattern lookup selects the first stack entry under
# either array indexing convention. Display escaping happens only at rendering.
typeset -g _ZDX_DOCTOR_SOURCE_FILE="${${funcstack[(r)*]:-$0}:A}"

# --- Private UI & Logging Helpers ---------------------------------------------

_zdx_doctor_color_enabled() {
  emulate -L zsh
  unsetopt force_float
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_zdx_doctor_log() {
  emulate -L zsh
  unsetopt force_float
  local level="${1:-info}" message="${2:-}"
  if [[ "$level" != na ]] && (( ${+functions[_zdx_ui_say]} )); then
    _zdx_ui_say "$level" "$message"
    return
  fi
  local marker="" color=""
  case "$level" in
    success) marker='✔ '; color='1;32' ;;
    warn) marker='⚠ '; color='1;33' ;;
    error) marker='✘ '; color='1;31' ;;
    info) marker='➜ '; color='0;36' ;;
    na) marker='⊘ '; color='0;90' ;;
    *) marker='  '; color='0;90' ;;
  esac
  if _zdx_doctor_color_enabled; then
    printf '\033[%sm%s%s\033[0m\n' "$color" "$marker" "${(V)message}" >&2
  else
    printf '%s%s\n' "$marker" "${(V)message}" >&2
  fi
}

_zdx_doctor_header() {
  emulate -L zsh
  unsetopt force_float
  if (( ${+functions[_zdx_ui_heading]} )); then
    _zdx_ui_heading "$@"
    return
  fi
  local title="${1:-ZDX Doctor}"
  if (( ${_ZDX_STEP_DEPTH:-0} > 0 )); then
    [[ "${ZDX_VERBOSE:-0}" == 1 ]] || return 0
    printf '%*s▸ %s\n' $(( 2 * ${_ZDX_STEP_DEPTH:-0} )) '' "${(V)title}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)title}" >&2
  fi
}

_zdx_doctor_section() {
  emulate -L zsh
  unsetopt force_float
  if (( ${+functions[_zdx_ui_section]} )); then
    _zdx_ui_section "$@"
    return
  fi
  local gap=$'\n'
  if [[ "${1-}" == --first ]]; then gap=""; shift; fi
  [[ -n "${1-}" ]] || return 2
  printf '%s%*s▸ %s\n' "$gap" $(( 2 * ${_ZDX_STEP_DEPTH:-0} )) '' "${(V)1}" >&2
}

_zdx_doctor_label() {
  emulate -L zsh
  unsetopt force_float
  if (( ${+functions[_zdx_ui_label]} )); then
    _zdx_ui_label "$@"
    return
  fi
  local key="${1%:}" value="${2-}"
  [[ -n "$key" ]] || return 2
  key="${(V)key}:"
  local -i padding=$(( 19 - ${(m)#key} ))
  (( padding < 1 )) && padding=1
  printf '  %s%*s%s\n' "$key" "$padding" '' "${(V)value}" >&2
}

_zdx_doctor_success() { _zdx_doctor_log success "${1:-}"; }
_zdx_doctor_warn()    { _zdx_doctor_log warn "${1:-}"; }
_zdx_doctor_info()    { _zdx_doctor_log info "${1:-}"; }
_zdx_doctor_error()   { _zdx_doctor_log error "${1:-}"; }
_zdx_doctor_dim()     { _zdx_doctor_log dim "${1:-}"; }
_zdx_doctor_not_applicable() { _zdx_doctor_log na "${1:-}"; }

# Read-only configuration facts: never read option files or theme contents.
_zdx_doctor_visual_diagnostics() {
  emulate -L zsh
  unsetopt force_float
  local color_mode="terminal defaults" theme_state="not configured"
  local options_state="unset" file_state="unset"
  [[ -n "${ZDX_FZF_THEME:-}" ]] && theme_state="configured"
  if [[ -n "${NO_COLOR:-}" ]]; then
    color_mode="disabled by NO_COLOR"
  elif [[ -n "${ZDX_FZF_PLAIN:-}" ]]; then
    color_mode="disabled by ZDX_FZF_PLAIN"
  elif [[ -z "${TERM:-}" || "$TERM" == dumb ]]; then
    color_mode="limited terminal"
  elif [[ "$theme_state" == configured ]]; then
    color_mode="custom theme"
  fi
  [[ -n "${FZF_DEFAULT_OPTS:-}" ]] && options_state="set"
  [[ -n "${FZF_DEFAULT_OPTS_FILE:-}" ]] && file_state="set"
  _zdx_doctor_label TERM "${TERM:-unset}"
  _zdx_doctor_label Colors "$color_mode"
  _zdx_doctor_label 'Custom theme' "$theme_state"
  _zdx_doctor_label 'fzf defaults' "options=$options_state; file=$file_state (isolated by suite menus)"
  _zdx_doctor_label 'Doctor source' "$_ZDX_DOCTOR_SOURCE_FILE; after updating this copy, open a new shell"
}

# --- Core-optional owned external probes -------------------------------------

_zdx_doctor_probe_resolve() {
  emulate -L zsh
  unsetopt force_float
  if (( ${+functions[_zdx_probe_resolve]} )); then
    _zdx_probe_resolve "$@"
    return
  fi
  REPLY=""
  (( $# == 1 )) || return 2
  local token="$1" resolved="" canonical=""
  [[ -n "$token" && "$token" != *$'\0'* ]] || return 2
  if [[ "$token" == /* ]]; then
    resolved="$token"
  else
    [[ "$token" != */* ]] || return 2
    resolved=$(whence -p -- "$token" 2>/dev/null) || return 1
  fi
  [[ "$resolved" == /* && -f "$resolved" && -x "$resolved" ]] || return 1
  canonical="${resolved:A}"
  if [[ "${OSTYPE:-}" == linux* ]] && _zdx_doctor_is_wsl; then
    [[ "$canonical" != /mnt/[a-zA-Z]/* && "${canonical:l}" != *.exe ]] || return 1
  fi
  REPLY="$resolved"
}

_zdx_doctor_probe_tool() {
  emulate -L zsh
  unsetopt force_float
  if (( ${+functions[_zdx_probe_tool]} )); then
    _zdx_probe_tool "$@"
    return
  fi
  (( $# >= 2 )) || return 2
  local seconds="$1" program="$2" backend="" REPLY=""
  [[ -n "$seconds" && "$seconds" != 0* && "$seconds" != *[^0-9]* \
    && ${#seconds} -le 6 && "$program" == /* ]] || return 2
  _zdx_doctor_probe_resolve "$program" || return 127
  shift 2
  if (( ${+functions[_zdx_run_with_timeout]} )); then
    # Reuse an available older core service, even without the new adapters.
    if command -v timeout >/dev/null 2>&1; then backend=timeout
    elif command -v gtimeout >/dev/null 2>&1; then backend=gtimeout; fi
    if [[ -z "$backend" ]] || _zdx_doctor_probe_resolve "$backend"; then
      _zdx_run_with_timeout "$seconds" "$program" "$@" </dev/null 2>/dev/null
      return $?
    elif (( ${+functions[_zdx_timeout_watchdog]} )); then
      _zdx_timeout_watchdog "$seconds" "$program" "$@" </dev/null 2>/dev/null
      return $?
    fi
  fi
  for backend in timeout gtimeout; do
    _zdx_doctor_probe_resolve "$backend" || continue
    command "$REPLY" -k 2s "${seconds}s" "$program" "$@" </dev/null 2>/dev/null
    return $?
  done
  return 125
}

# --- Version Introspection ----------------------------------------------------

# stdout: one validated version token. Each probe runs with closed stdin and is
# captured whole before parsing, so a failed command never becomes an installed
# version: a failing probe returns its own status and unrecognized output
# returns 1. Status 0 with no output means the command has no version probe,
# and the caller shows only its path.
_zdx_doctor_get_version() {
  emulate -L zsh
  unsetopt force_float
  local MATCH="" MBEGIN=0 MEND=0
  local -a match=() mbegin=() mend=()
  (( $# == 1 || $# == 2 )) || return 2
  local cmd="$1" program="${2-}" REPLY=""
  local version_output="" version_token="" IFS=$' \t\n'
  local -a version_fields=()
  local -i version_rc=0 classifier_rc=0
  if (( $# == 1 )); then
    _zdx_doctor_probe_resolve "$cmd" || return 127
    program="$REPLY"
    _zdx_doctor_clt_placeholder "$cmd" "$program" || classifier_rc=$?
    case "$classifier_rc" in
      1) ;;
      0) return 127 ;;
      124|125|130|143) return $classifier_rc ;;
      *) return 125 ;;
    esac
  else
    # Only owned rows pass a path already cleared by the classifier.
    [[ "$program" == /* ]] || return 2
    _zdx_doctor_probe_resolve "$program" || return 127
  fi
  case "$cmd" in
    fzf)
      local -x FZF_DEFAULT_OPTS="" FZF_DEFAULT_OPTS_FILE="" FZF_DEFAULT_COMMAND=""
      version_output=$(_zdx_doctor_probe_tool 5 "$program" --version) || version_rc=$?
      (( version_rc == 0 )) || return $version_rc
      version_token="${version_output%%$'\n'*}"
      version_token="${version_token%%[[:space:]]*}"
      [[ ${#version_token} -le 64 \
        && "$version_token" =~ '^[0-9]+[.][0-9]+([.][0-9]+)?([.-][A-Za-z0-9]+)*$' ]] || return 1
      print -r -- "$version_token"
      return 0
      ;;
    git|gh|jq|uv|pipx|python3|curl)
      version_output=$(_zdx_doctor_probe_tool 5 "$program" --version) || version_rc=$?
      ;;
    wg-quick)
      _zdx_doctor_probe_resolve wg || return 127
      program="$REPLY"
      version_output=$(_zdx_doctor_probe_tool 5 "$program" --version) || version_rc=$?
      ;;
    *) return 0 ;;
  esac
  (( version_rc == 0 )) || return $version_rc
  version_fields=(${=version_output%%$'\n'*})
  case "$cmd" in
    git|gh)   version_token="${version_fields[3]-}" ;;
    jq)       version_token="${${version_fields[1]-}#jq-}" ;;
    pipx)     version_token="${version_fields[1]-}" ;;
    wg-quick) version_token="${${version_fields[2]-}#v}" ;;
    *)        version_token="${version_fields[2]-}" ;;
  esac
  [[ ${#version_token} -le 64 \
    && "$version_token" =~ '^[0-9]+([.][0-9]+)*([.+~_-]?[0-9A-Za-z]+)*$' ]] || return 1
  print -r -- "$version_token"
}

# Only explicit 1 clears. The ordinary negative0 is retained for legacy
# placeholder advice; it does not prove physical CLT absence or child execution.
_zdx_doctor_clt_placeholder() {
  emulate -L zsh
  unsetopt force_float
  if (( ${+functions[_zdx_probe_clt_placeholder]} )); then
    _zdx_probe_clt_placeholder "$@"
    return
  fi
  (( $# == 2 )) || return 2
  local cmd="$1" resolved="$2" developer_dir="" secondary="" REPLY=""
  local -i probe_rc=0
  [[ -n "$cmd" && "$cmd" != */* && "$cmd" != *$'\0'* \
    && "$resolved" == /* ]] || return 2
  _zdx_doctor_probe_resolve "$resolved" || return 2
  case "$cmd" in git|python3) ;; *) return 1 ;; esac
  [[ "${OSTYPE:-}" == darwin* \
    && ( "$resolved" == "/usr/bin/$cmd" || "${resolved:A}" == "/usr/bin/$cmd" ) ]] || return 1
  _zdx_doctor_probe_resolve xcode-select || return 0
  secondary="$REPLY"
  developer_dir=$(_zdx_doctor_probe_tool 3 "$secondary" -p) || probe_rc=$?
  case "$probe_rc" in
    0)
      developer_dir="${developer_dir%%$'\n'*}"
      [[ -n "$developer_dir" && -d "$developer_dir" ]] && return 1
      return 0 ;;
    124|130|143) return $probe_rc ;;
    125|127) return 125 ;;
    *) return 0 ;;
  esac
}

# --- Platform & Package Manager Introspection ---------------------------------

# True when Linux runs under WSL: its interop registration (WSLInterop, or
# WSLInterop-late on newer releases), its session variables, or a Microsoft
# kernel release string. A stripped environment keeps the kernel evidence.
# The optional argument replaces /proc for fixtures.
_zdx_doctor_is_wsl() {
  emulate -L zsh
  unsetopt force_float
  local proc_root="${1:-/proc}" kernel_release=""
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  [[ -e "$proc_root/sys/fs/binfmt_misc/WSLInterop" \
    || -e "$proc_root/sys/fs/binfmt_misc/WSLInterop-late" ]] && return 0
  [[ -f "$proc_root/sys/kernel/osrelease" \
    && -r "$proc_root/sys/kernel/osrelease" ]] || return 1
  kernel_release=$(<"$proc_root/sys/kernel/osrelease") 2>/dev/null || return 1
  [[ "${kernel_release:l}" == *microsoft* ]]
}

# stdout: macOS, WSL, Linux, or Unknown. The optional argument replaces /proc
# for WSL fixtures.
_zdx_doctor_detect_os() {
  emulate -L zsh
  unsetopt force_float
  if [[ "$OSTYPE" == darwin* ]]; then
    print -r -- "macOS"
  elif [[ "$OSTYPE" == linux* ]]; then
    if _zdx_doctor_is_wsl "${1:-/proc}"; then
      print -r -- "WSL"
    else
      print -r -- "Linux"
    fi
  else
    print -r -- "Unknown"
  fi
}

# stdout: the package manager used for suggestions and opt-in installation.
# Linux and WSL prefer the system manager over a Linuxbrew brew; macOS uses
# Homebrew only.
_zdx_doctor_detect_pkg_manager() {
  emulate -L zsh
  unsetopt force_float
  local os_name="${1:-}"
  [[ -n "$os_name" ]] || os_name=$(_zdx_doctor_detect_os)
  local -a candidates=()
  case "$os_name" in
    macOS)     candidates=(brew) ;;
    Linux|WSL) candidates=(apt-get dnf pacman apk brew) ;;
    *)         candidates=(brew apt-get dnf pacman apk) ;;
  esac

  local candidate="" REPLY=""
  for candidate in "${candidates[@]}"; do
    _zdx_doctor_probe_resolve "$candidate" || continue
    if [[ "$candidate" == apt-get ]]; then
      print -r -- "apt"
    else
      print -r -- "$candidate"
    fi
    return 0
  done
  print -r -- "none"
}

# >>> zdx-primitive confirm-prompt
# Asks one yes/no question on the terminal and returns 0 for yes, 1 for a
# decline or a cancelled picker, 2 when no terminal can answer (stdin or
# stderr is not a terminal, or input ended), and 3 when the picker failed.
# Line/key reads preserve returned interruption statuses 130 and 143.
# Only an exact Yes, or y or Y, confirms. --style picker offers No and Yes in
# an fzf picker through the given capture function when fzf is installed and
# otherwise asks for a line; --style line asks `? PROMPT [y/N]:` and reads a
# line; --style key reads a single key. --available names a suite function
# that replaces the terminal test. Generated copies in the suite common files
# keep a suite working without the core; `just sync-primitives` writes them.
# Usage: _zdx_doctor_confirm_prompt --style picker|line|key --error FUNCTION \
#          [--capture FUNCTION] [--available FUNCTION] -- PROMPT
_zdx_doctor_confirm_prompt() {
  emulate -L zsh
  unsetopt force_float
  local MATCH="" MBEGIN=0 MEND=0
  local -a match=() mbegin=() mend=()
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
  local -i zcp_read_rc=0
  if [[ "$zcp_style" == key ]]; then
    read -r -k 1 -u 0 zcp_reply || zcp_read_rc=$?
    if (( zcp_read_rc != 0 )); then
      print -u2 -r -- ""
      (( zcp_read_rc == 130 || zcp_read_rc == 143 )) && return $zcp_read_rc
      return 2
    fi
    print -u2 -r -- ""
  else
    IFS= read -r zcp_reply || zcp_read_rc=$?
    if (( zcp_read_rc != 0 )); then
      (( zcp_read_rc == 130 || zcp_read_rc == 143 )) && return $zcp_read_rc
      return 2
    fi
  fi
  [[ "$zcp_reply" == [Yy] ]]
}
# <<< zdx-primitive confirm-prompt

_zdx_doctor_confirm_ask() {
  if (( ${+functions[_zdx_confirm_prompt]} )); then
    _zdx_confirm_prompt --style line --error _zdx_doctor_error -- "${1:-Continue?}"
  else
    _zdx_doctor_confirm_prompt --style line --error _zdx_doctor_error -- "${1:-Continue?}"
  fi
}

# Compatibility boundary for callers and deliberate prompt fixtures.
_zdx_doctor_confirm() { _zdx_doctor_confirm_ask "$@"; }

_zdx_doctor_package_name_valid() {
  emulate -L zsh
  unsetopt force_float
  local MATCH="" MBEGIN=0 MEND=0
  local -a match=() mbegin=() mend=()
  local package_name="${1:-}"
  (( ${#package_name} >= 1 && ${#package_name} <= 128 )) \
    && [[ "$package_name" =~ '^[A-Za-z0-9][A-Za-z0-9+._-]*$' ]]
}

# REPLY: COUNT with its noun, through the core service when it is loaded.
_zdx_doctor_count_noun() {
  emulate -L zsh
  unsetopt force_float
  if (( ${+functions[_zdx_count_noun]} )); then
    _zdx_count_noun "$@"
    return
  fi
  local count="${1-}" singular="${2-}" plural="${3:-${2-}s}"
  [[ "$count" == <-> && -n "$singular" ]] || return 2
  if [[ "$count" == 1 ]]; then
    REPLY="1 $singular"
  else
    REPLY="$count $plural"
  fi
}

# Same duration grammar when doctor is sourced without the core.
_zdx_doctor_format_duration() {
  emulate -L zsh
  unsetopt force_float
  if (( ${+functions[_zdx_format_duration]} )); then
    _zdx_format_duration "$@"
    return
  fi
  local MATCH="" MBEGIN=0 MEND=0
  local -a match=() mbegin=() mend=()
  local value="${1-}"
  local -i tenths=0 seconds=0 minutes=0 hours=0
  REPLY=""
  [[ ${#value} -le 32 \
    && "$value" =~ '^[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$' ]] || return 2
  (( value <= 1e9 )) || return 2
  (( tenths = value * 10 + 0.5 ))
  if (( tenths < 100 )); then
    REPLY="$(( tenths / 10 )).$(( tenths % 10 ))s"
    return 0
  fi
  # Round once to whole seconds and classify that value, so no branch can
  # print 60s or 60m.
  (( seconds = value + 0.5 ))
  if (( seconds < 60 )); then
    REPLY="${seconds}s"
  elif (( seconds < 3600 )); then
    REPLY="$(( seconds / 60 ))m ${(l:2::0:)$(( seconds % 60 ))}s"
  else
    (( minutes = (seconds + 30) / 60 ))
    if (( minutes < 1440 )); then
      REPLY="$(( minutes / 60 ))h ${(l:2::0:)$(( minutes % 60 ))}m"
    else
      # Round the original value directly, without compounding minute rounding.
      (( hours = value / 3600.0 + 0.5 ))
      REPLY="$(( hours / 24 ))d ${(l:2::0:)$(( hours % 24 ))}h"
    fi
  fi
}

# True when PROGRAM is an absolute path whose resolved target is an
# executable regular file that group and other users cannot write, owned by
# root, or also by the current user when OWNER is "user".
_zdx_doctor_program_trusted() {
  emulate -L zsh
  unsetopt force_float
  local program="${1:-}" owner="${2:-root}" target=""
  local -A program_state=()
  [[ "$program" == /* ]] || return 1
  target="${program:A}"
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && [[ -f "$target" && -x "$target" ]] \
    && zstat -H program_state -- "$target" 2>/dev/null || return 1
  (( (program_state[mode] & 8#22) == 0 )) || return 1
  (( program_state[uid] == 0 )) && return 0
  [[ "$owner" == user ]] && (( program_state[uid] == EUID ))
}

# reply: the exact install plan for PACKAGE_MANAGER and PACKAGE..., one
# shell-quoted command per element; REPLY: the absolute sudo path the plan
# uses, or empty. The package manager is resolved to an absolute path and
# must be root-owned and not writable by other users; it runs through a
# root-owned sudo with -n unless the shell already runs as root. Homebrew
# may belong to the current user and never runs through sudo or as root.
# Usage: _zdx_doctor_install_plan PACKAGE_MANAGER PACKAGE...
_zdx_doctor_install_plan() {
  emulate -L zsh
  unsetopt force_float
  local package_manager="${1:-}"
  shift 2>/dev/null || true
  local -a package_names=("$@")
  reply=()
  REPLY=""

  (( ${#package_names[@]} >= 1 && ${#package_names[@]} <= 64 )) || return 2
  local package_name=""
  for package_name in "${package_names[@]}"; do
    _zdx_doctor_package_name_valid "$package_name" || {
      _zdx_doctor_error "Refusing an invalid package name."
      return 2
    }
  done

  local program_name="" owner=root
  case "$package_manager" in
    apt)            program_name=apt-get ;;
    dnf|pacman|apk) program_name="$package_manager" ;;
    brew)           program_name=brew; owner=user ;;
    *)
      _zdx_doctor_error "Unsupported package manager: $package_manager"
      return 2
      ;;
  esac

  local program=""
  program=$(whence -p -- "$program_name" 2>/dev/null) || program=""
  _zdx_doctor_program_trusted "$program" "$owner" || {
    if [[ "$owner" == user ]]; then
      _zdx_doctor_error \
        "Refusing $program_name: it must be an executable owned by you or root that other users cannot write."
    else
      _zdx_doctor_error \
        "Refusing $program_name: it must be a root-owned executable that other users cannot write."
    fi
    return 1
  }

  local -a prefix=()
  local sudo_program=""
  if [[ "$package_manager" == brew ]]; then
    (( EUID != 0 )) || {
      _zdx_doctor_error \
        "Homebrew never runs as root; run zdx-doctor as your own user."
      return 1
    }
  elif (( EUID != 0 )); then
    sudo_program=$(whence -p -- sudo 2>/dev/null) || sudo_program=""
    _zdx_doctor_program_trusted "$sudo_program" root || {
      _zdx_doctor_error \
        "Refusing to install: sudo must be a root-owned executable that other users cannot write."
      return 1
    }
    prefix=("$sudo_program" -n)
  fi

  local -a step=()
  case "$package_manager" in
    apt)
      step=("${prefix[@]}" "$program" update)
      reply+=("${(j: :)${(@q-)step}}")
      step=("${prefix[@]}" "$program" install -y "${package_names[@]}")
      ;;
    brew)   step=("$program" install "${package_names[@]}") ;;
    dnf)    step=("${prefix[@]}" "$program" install -y "${package_names[@]}") ;;
    pacman) step=("${prefix[@]}" "$program" -S --noconfirm "${package_names[@]}") ;;
    apk)    step=("${prefix[@]}" "$program" add "${package_names[@]}") ;;
  esac
  reply+=("${(j: :)${(@q-)step}}")
  REPLY="$sudo_program"
}

# Rebuilds the install plan and requires it to equal PLAN_NAME exactly, with
# every command in MISSING_NAME still absent from PATH.
# Usage: _zdx_doctor_install_plan_current PM PLAN_NAME MISSING_NAME PACKAGE...
_zdx_doctor_install_plan_current() {
  emulate -L zsh
  unsetopt force_float
  local package_manager="$1"
  local -a expected_plan=("${(@P)2}") missing_commands=("${(@P)3}")
  shift 3
  local REPLY="" command_name=""
  local -a reply=()
  rehash
  for command_name in "${missing_commands[@]}"; do
    (( ${+commands[$command_name]} )) || continue
    _zdx_doctor_error \
      "$command_name appeared after the review; nothing was installed. Run zdx-doctor again."
    return 1
  done
  _zdx_doctor_install_plan "$package_manager" "$@" 2>/dev/null \
    && [[ "${(pj:\0:)reply}" == "${(pj:\0:)expected_plan}" ]] || {
    _zdx_doctor_error \
      "The install plan changed after the review; nothing was installed. Run zdx-doctor again."
    return 1
  }
}

# Runs a reviewed install plan: confirmation (unless DRY_RUN), revalidation,
# one announced sudo -v when the plan uses sudo, revalidation again, and each
# exact command with stdin closed. A plan step that fails stops the rest.
# When sudo -n no longer works after sudo -v, as with timestamp_timeout=0, the
# remaining commands are printed for the user instead of prompting again.
# Usage: _zdx_doctor_run_install DRY_RUN PM MISSING_NAME PACKAGE...
_zdx_doctor_run_install() {
  emulate -L zsh
  unsetopt force_float
  REPLY=""
  local doctor_install_outcome=failed
  local -i doctor_install_rc=1
  {
    # Temporary plan/label replies belong to this inner scope. The outer
    # REPLY slot remains the caller's output and is published in always.
    () {
      local -i dry_run="$1"
      local package_manager="$2" missing_name="$3"
      shift 3
      local -a package_names=("$@") install_plan=() reply=()
      local sudo_program="" REPLY="" plan_size=""
      local -i step_index=0 step_rc=0 remaining=0
      _zdx_doctor_install_plan "$package_manager" "${package_names[@]}" || return 1
      install_plan=("${reply[@]}")
      sudo_program="$REPLY"
      _zdx_doctor_section 'Install Plan'
      for step_index in {1..${#install_plan[@]}}; do
        _zdx_doctor_label "Command $step_index" "${install_plan[step_index]}"
      done
      _zdx_doctor_count_noun "${#install_plan[@]}" command
      plan_size="$REPLY"
      if (( dry_run )); then
        _zdx_doctor_info "Dry run: $plan_size planned; nothing was installed."
        doctor_install_outcome=planned
        return 0
      fi
      step_rc=0
      _zdx_doctor_confirm "Run the $plan_size above via $package_manager?" || step_rc=$?
      case "$step_rc" in
        0) ;;
        1)
          _zdx_doctor_info 'Installation cancelled: nothing was installed.'
          doctor_install_outcome=declined
          return 0 ;;
        130|143) doctor_install_outcome=interrupted; return $step_rc ;;
        *)
          _zdx_doctor_error 'Installation unavailable: confirmation could not be completed. Review with zdx-doctor --dry-run.'
          return 1 ;;
      esac
      _zdx_doctor_install_plan_current "$package_manager" install_plan \
        "$missing_name" "${package_names[@]}" || return 1
      if [[ -n "$sudo_program" ]]; then
        _zdx_doctor_label 'Privileged operation' 'sudo -v (authenticate once for the install plan)'
        _zdx_doctor_dim 'Each planned command then runs with sudo -n.'
        step_rc=0
        command "$sudo_program" -v >&2 || step_rc=$?
        case "$step_rc" in
          0) ;;
          130|143) doctor_install_outcome=interrupted; return $step_rc ;;
          *) _zdx_doctor_error 'sudo authentication failed; nothing was installed.'; return 1 ;;
        esac
        _zdx_doctor_install_plan_current "$package_manager" install_plan \
          "$missing_name" "${package_names[@]}" || return 1
      fi
      zmodload zsh/datetime 2>/dev/null
      local -a step_command=()
      local step_label=""
      local -F started_at=0
      for step_index in {1..${#install_plan[@]}}; do
        if [[ -n "$sudo_program" ]]; then
          step_rc=0
          command "$sudo_program" -n true </dev/null 2>/dev/null || step_rc=$?
          case "$step_rc" in
            0) ;;
            130|143) doctor_install_outcome=interrupted; return $step_rc ;;
            *)
              _zdx_doctor_warn 'sudo no longer accepts authentication without a prompt.'
              for (( remaining=step_index; remaining<=${#install_plan[@]}; remaining++ )); do
                _zdx_doctor_label "Not run $remaining" "${install_plan[remaining]}"
              done
              return 1 ;;
          esac
        fi
        step_command=("${(@Q)${(z)install_plan[step_index]}}")
        _zdx_doctor_step_label "$sudo_program" "${step_command[@]}"
        step_label="$REPLY"
        _zdx_doctor_step_banner "$step_index" "${#install_plan[@]}" "$step_label"
        _zdx_doctor_label 'Executing' "${install_plan[step_index]}"
        started_at=${EPOCHREALTIME:-0}
        step_rc=0
        command "${step_command[@]}" </dev/null >&2 || step_rc=$?
        _zdx_doctor_step_result "$step_index" "${#install_plan[@]}" \
          "$step_label" "$step_rc" "$started_at"
        (( step_rc == 0 )) && continue
        for (( remaining=step_index+1; remaining<=${#install_plan[@]}; remaining++ )); do
          _zdx_doctor_step_label "$sudo_program" "${(@Q)${(z)install_plan[remaining]}}"
          _zdx_doctor_step_result "$remaining" "${#install_plan[@]}" "$REPLY" skip 0
        done
        case "$step_rc" in
          130|143) doctor_install_outcome=interrupted; return $step_rc ;;
          *) _zdx_doctor_error 'Installation failed. Review the package-manager errors above.'; return 1 ;;
        esac
      done
      doctor_install_outcome=installed
      return 0
    } "$@"
    doctor_install_rc=$?
  } always {
    REPLY="$doctor_install_outcome"
  }
  return $doctor_install_rc
}

# REPLY: a short display label for one planned command: the sudo prefix is
# dropped and the program is shown by name.
# Usage: _zdx_doctor_step_label SUDO_PROGRAM WORD...
_zdx_doctor_step_label() {
  emulate -L zsh
  unsetopt force_float
  local sudo_program="$1"
  shift
  local -a label_words=("$@")
  if [[ -n "$sudo_program" && "${label_words[1]}" == "$sudo_program" \
    && "${label_words[2]}" == -n ]]; then
    label_words=("${(@)label_words[3,-1]}")
  fi
  label_words[1]="${label_words[1]:t}"
  REPLY="${(j: :)label_words}"
}

_zdx_doctor_step_banner() {
  emulate -L zsh
  unsetopt force_float
  if (( ${+functions[_zdx_ui_step_banner]} )); then
    _zdx_ui_step_banner "$@"
    return
  fi
  local index="$1" total="$2" label="${(V)3}"
  if (( ${_ZDX_STEP_DEPTH:-0} > 0 )); then
    printf '%*s[%s/%s] %s\n' $(( 2 * ${_ZDX_STEP_DEPTH:-0} )) '' "$index" "$total" "$label" >&2
    return
  fi
  local -i width=72 rule_length=0
  [[ "${COLUMNS-}" == <21-9999> ]] && width=$(( COLUMNS - 1 ))
  (( width > 72 )) && width=72
  local prefix="── [$index/$total] $label " rule=""
  rule_length=$(( width - ${(m)#prefix} ))
  (( rule_length < 3 )) && rule_length=3
  printf -v rule '%*s' "$rule_length" ''
  printf '\n%s%s\n' "$prefix" "${rule// /─}" >&2
}

# Numeric serialization is scoped to rendering, never the package command.
_zdx_doctor_step_result() {
  emulate -L zsh
  unsetopt force_float
  local index="$1" total="$2" label="$3" step_status="$4" started_at="$5"
  local seconds="" outcome="" detail="" glyph="" word="" duration="" REPLY=""
  local -x LC_ALL=C
  if [[ "$step_status" != skip && "$started_at" != 0* && -n "${EPOCHREALTIME:-}" ]]; then
    printf -v seconds '%.1f' $(( EPOCHREALTIME - started_at ))
  fi
  case "$step_status" in
    0) outcome=done; word=done; glyph='✔' ;;
    130|143) outcome=interrupted; word=interrupted; glyph='✘'; detail="exit $step_status" ;;
    skip) outcome=not-run; word='not run'; glyph='–'; detail='an earlier step failed' ;;
    *) outcome=failed; word=failed; glyph='✘'; detail="exit $step_status" ;;
  esac
  if (( ${+functions[_zdx_ui_step_result]} )); then
    _zdx_ui_step_result "$index" "$total" "$label" "$outcome" "$detail" "$seconds"
    return
  fi
  if [[ -n "$seconds" ]]; then
    _zdx_doctor_format_duration "$seconds" || return 2
    duration=" ($REPLY)"
  fi
  printf '%*s%s [%s/%s] %s — %s%s%s\n' $(( 2 * ${_ZDX_STEP_DEPTH:-0} )) '' \
    "$glyph" "$index" "$total" "${(V)label}" "$word" "${detail:+: $detail}" "$duration" >&2
}

# Resolution-only alternatives; no capability executable runs for discovery.
_zdx_doctor_timeout_command() {
  emulate -L zsh
  unsetopt force_float
  local candidate=""
  for candidate in timeout gtimeout; do
    _zdx_doctor_probe_resolve "$candidate" && return 0
  done
  REPLY=""
  return 1
}

_zdx_doctor_fd_command() {
  emulate -L zsh
  unsetopt force_float
  local candidate=""
  for candidate in fd fdfind; do
    _zdx_doctor_probe_resolve "$candidate" && return 0
  done
  REPLY=""
  return 1
}

_zdx_doctor_sha256_command() {
  emulate -L zsh
  unsetopt force_float
  local candidate=""
  for candidate in sha256sum shasum; do
    _zdx_doctor_probe_resolve "$candidate" && return 0
  done
  REPLY=""
  return 1
}

# reply=(path version-line) for an established GNU tar, or a known non-GNU
# alternative on status1. Unknown checks return124/125; interruption stays exact.
# A verified GNU alternative settles the capability despite an unused failure.
_zdx_doctor_gnu_tar() {
  emulate -L zsh
  unsetopt force_float
  reply=()
  local candidate="" program="" version_text="" REPLY=""
  local -a known_alternative=()
  local -i probe_rc=0 unknown_rc=0
  local -x LC_ALL=C
  for candidate in tar gtar; do
    _zdx_doctor_probe_resolve "$candidate" || continue
    program="$REPLY"
    probe_rc=0
    version_text=$(_zdx_doctor_probe_tool 5 "$program" --version) || probe_rc=$?
    case "$probe_rc" in
      0) ;;
      130|143) return $probe_rc ;;
      124) (( unknown_rc == 0 )) && unknown_rc=124; continue ;;
      *) (( unknown_rc == 0 )) && unknown_rc=125; continue ;;
    esac
    version_text="${version_text%%$'\n'*}"
    if [[ "$version_text" == *"GNU tar"* ]]; then
      reply=("$program" "$version_text")
      return 0
    elif [[ "$version_text" == *tar*[0-9]* ]]; then
      (( ${#known_alternative} )) || known_alternative=("$program" "$version_text")
    else
      (( unknown_rc == 0 )) && unknown_rc=125
    fi
  done
  (( unknown_rc == 0 )) || return $unknown_rc
  reply=("${known_alternative[@]}")
  return 1
}

# Reports one dependency record (cmd|suite|severity|url|apt|brew|dnf|pacman|
# description). It updates zdx-doctor's pm-dependent missing_cmds and
# missing_pkgs arrays and its issue counters through dynamic scope. An
# interrupted version probe returns its 130 or 143 status.
_zdx_doctor_report_dependency() {
  emulate -L zsh
  unsetopt force_float
  local -a fields=("${(@s:|:)1}")
  local cmd="${fields[1]-}" suite="${fields[2]-}" sev="${fields[3]-}"
  local url="${fields[4]-}" apt_n="${fields[5]-}" brew_n="${fields[6]-}"
  local dnf_n="${fields[7]-}" pac_n="${fields[8]-}" desc="${fields[9]-}"
  local suffix="" path_loc="" ver="" rec_cmd="" package_name="" REPLY=""
  local -i version_rc=0 classifier_rc=0 placeholder=0
  [[ "$sev" == critical ]] || suffix=" [$suite]"

  if _zdx_doctor_probe_resolve "$cmd"; then
    path_loc="$REPLY"
    _zdx_doctor_clt_placeholder "$cmd" "$path_loc" || classifier_rc=$?
    case "$classifier_rc" in
      1) ;;
      0) placeholder=1 ;;
      130|143) return $classifier_rc ;;
      *)
        _zdx_doctor_label "$cmd" "Unknown (CLT check status $classifier_rc; candidate not run)$suffix"
        (( issues_count += 1, capability_issues_count += 1, indeterminate_probe_count += 1 ))
        return 0
        ;;
    esac
  fi

  if [[ -n "$path_loc" ]] && (( ! placeholder )); then
    ver=$(_zdx_doctor_get_version "$cmd" "$path_loc") || version_rc=$?
    case "$version_rc" in 130|143) return $version_rc ;; esac
    if (( version_rc != 0 )); then
      _zdx_doctor_label "$cmd" "Unknown (version check failed, status $version_rc; $path_loc)$suffix"
      (( issues_count += 1, capability_issues_count += 1, indeterminate_probe_count += 1 ))
    elif [[ -n "$ver" ]]; then
      _zdx_doctor_label "$cmd" "Installed ($path_loc, v$ver)$suffix"
    else
      _zdx_doctor_label "$cmd" "Installed ($path_loc)$suffix"
    fi
    return 0
  fi

  _zdx_doctor_label "$cmd" "MISSING ($desc)$suffix"
  if (( placeholder )); then
    _zdx_doctor_info "$path_loc is an Apple Command Line Tools placeholder; it was not run."
    _zdx_doctor_label "Apple's tools" 'xcode-select --install'
  fi
  _zdx_doctor_label 'Official link' "$url"
  case "$pm" in
    apt)
      package_name="$apt_n"
      [[ -n "$apt_n" ]] && rec_cmd="sudo apt-get update && sudo apt-get install -y $apt_n" ;;
    brew)
      package_name="$brew_n"
      [[ -n "$brew_n" ]] && rec_cmd="brew install $brew_n" ;;
    dnf)
      package_name="$dnf_n"
      [[ -n "$dnf_n" ]] && rec_cmd="sudo dnf install -y $dnf_n" ;;
    pacman)
      package_name="$pac_n"
      [[ -n "$pac_n" ]] && rec_cmd="sudo pacman -S --noconfirm $pac_n" ;;
    apk) package_name="$cmd"; rec_cmd="sudo apk add $cmd" ;;
  esac
  if [[ -n "$rec_cmd" ]]; then
    _zdx_doctor_label 'Suggested command' "$rec_cmd"
    missing_cmds+=("$cmd")
    missing_pkgs+=("$package_name")
  fi
  (( issues_count += 1 ))
  return 0
}

_zdx_doctor_usage() {
  emulate -L zsh
  unsetopt force_float
  cat >&2 <<'EOF'

  ═════════════════════════════════════════════════════════════
         ZDX Doctor - Dependency Diagnostic CLI Assistant
  ═════════════════════════════════════════════════════════════

  Usage:
    zdx-doctor                Run diagnostics and offer an interactive installer
    zdx-doctor --dry-run      Run diagnostics and print the exact install plan
    zdx-doctor -h|--help|help Show this documentation

  Options:
    --dry-run                 Print the install plan; install nothing
    -h, --help, help          Show this documentation screen

  Features:
    - OS and environment detection
    - Real-time checks for Core vs Optional suite requirements
    - Alternative-command and installed-library capability checks
    - Native version introspection
    - Visual status indicator dashboard
    - Tailored official URLs and copy-paste installation tips
    - An exact, reviewed install plan: absolute root-owned package manager
      and sudo, revalidation after the decision, one sudo -v, then sudo -n

EOF
}

zdx-doctor() {
  emulate -L zsh
  unsetopt force_float
  local -i dry_run=0
  case "${1:-}" in
    "")
      (( $# == 0 )) || {
        _zdx_doctor_error "zdx-doctor does not accept an empty argument."
        return 2
      }
      ;;
    --dry-run)
      (( $# == 1 )) || {
        _zdx_doctor_error "--dry-run accepts no additional arguments."
        return 2
      }
      dry_run=1
      ;;
    -h|--help|help)
      (( $# == 1 )) || {
        _zdx_doctor_error "zdx-doctor help accepts no additional arguments."
        return 2
      }
      _zdx_doctor_usage
      return 0
      ;;
    -*)
      _zdx_doctor_error "Unknown zdx-doctor option: $1"
      return 2
      ;;
    *)
      _zdx_doctor_error "Unexpected zdx-doctor argument: $1"
      return 2
      ;;
  esac

  local os
  os=$(_zdx_doctor_detect_os)
  local pm
  pm=$(_zdx_doctor_detect_pkg_manager "$os")

  _zdx_doctor_header "ZDX Dependency Doctor Checkup"
  _zdx_doctor_label Platform "$os"
  _zdx_doctor_label Shell "zsh ${ZSH_VERSION:-unknown}"
  _zdx_doctor_label 'Package manager' "$pm"

  _zdx_doctor_section "Menu Display"
  _zdx_doctor_visual_diagnostics

  # Define dependencies: cmd|suite_group|severity|official_url|apt_name|brew_name|dnf_name|pacman_name|description
  local -a deps
  deps=(
    "fzf|Core System|critical|https://github.com/junegunn/fzf|fzf|fzf|fzf|fzf|Interactive FZF menus"
    "git|Core System|critical|https://git-scm.com/|git|git|git|git|Repository and code management"
    "jq|Core System|critical|https://jqlang.github.io/jq/|jq|jq|jq|jq|Telemetry parsing and VPN exit lookups"
    "gh|Git & GitHub|optional|https://cli.github.com/|gh|gh|gh|github-cli|GitHub pull requests and repository metadata"
    "python3|Developer & Python|optional|https://www.python.org/downloads/|python3|python|python3|python|Project metadata and lockfile parsing"
    "curl|VPN & Python|optional|https://curl.se/download.html|curl|curl|curl|curl|Bounded HTTPS lookups"
    "wg-quick|WireGuard VPN|optional|https://www.wireguard.com/install/|wireguard-tools|wireguard-tools|wireguard-tools|wireguard-tools|WireGuard VPN tunnel management"
    "uv|Python & Virtualenvs|optional|https://github.com/astral-sh/uv|uv|uv|uv|uv|Python and packages manager"
    "pipx|Python & Virtualenvs|optional|https://github.com/pypa/pipx|pipx|pipx|pipx|python-pipx|Alternative Python global tools"
  )

  local -a missing_cmds
  local -a missing_pkgs
  local -i issues_count=0
  local -i capability_issues_count=0
  local -i indeterminate_probe_count=0
  local -i dependency_rc=0
  local REPLY=""
  local -a reply=()
  local d path_loc

  # Print Core Dependencies
  _zdx_doctor_section "Core Dependencies"
  for d in "${deps[@]}"; do
    [[ "${${(@s:|:)d}[3]}" == critical ]] || continue
    _zdx_doctor_report_dependency "$d" || {
      dependency_rc=$?
      return $dependency_rc
    }
  done

  # Print Optional Dependencies
  _zdx_doctor_section "Optional Suite-Specific Dependencies"
  for d in "${deps[@]}"; do
    [[ "${${(@s:|:)d}[3]}" != critical ]] || continue
    _zdx_doctor_report_dependency "$d" || {
      dependency_rc=$?
      return $dependency_rc
    }
  done

  # Check required capabilities that cannot be represented as one installable
  # command. These checks never add packages to the batch installer. A row
  # that cannot apply on this platform is reported but never counted.
  _zdx_doctor_section "Suite Operational Capabilities"

  if _zdx_doctor_timeout_command; then
    _zdx_doctor_label 'timeout/gtimeout' "Available ($REPLY) [System, Python & VPN]"
  else
    if (( ${+functions[_zdx_run_with_timeout]} )); then
      _zdx_doctor_label 'timeout/gtimeout' 'Not found (bounded inventories, probes, and remote lookups use the slower Zsh watchdog) [System, Python & VPN]'
      if [[ "$os" == macOS ]]; then
        _zdx_doctor_label 'Optional backend' 'brew install coreutils provides the faster gtimeout'
      else
        _zdx_doctor_label 'Optional backend' 'GNU coreutils provides the faster timeout command.'
      fi
    else
      _zdx_doctor_label 'timeout/gtimeout' 'Not found (standalone external probes require a native timeout or gtimeout)'
    fi
  fi

  if _zdx_doctor_fd_command; then
    _zdx_doctor_label 'fd/fdfind' "Available ($REPLY) [Workspaces]"
  else
    _zdx_doctor_label 'fd/fdfind' 'Not found (workspace discovery uses find) [Workspaces]'
    _zdx_doctor_dim 'The fd package (fd-find on Debian and Ubuntu) provides faster discovery.'
  fi

  if _zdx_doctor_sha256_command; then
    _zdx_doctor_label 'sha256sum/shasum' "Available ($REPLY) [File]"
  else
    _zdx_doctor_label 'sha256sum/shasum' 'MISSING (archive identity checks) [File]'
    _zdx_doctor_dim 'Either command satisfies this capability: https://www.gnu.org/software/coreutils/'
    (( issues_count += 1, capability_issues_count += 1 ))
  fi

  if [[ "$os" != Linux && "$os" != WSL ]]; then
    _zdx_doctor_label ip "Not applicable on $os (iproute2 route lookups run on Linux and WSL) [VPN]"
  elif _zdx_doctor_probe_resolve ip; then
    _zdx_doctor_label ip "Available ($REPLY) [VPN routes]"
  else
    _zdx_doctor_label ip 'MISSING (route lookups in VPN diagnostics) [VPN]'
    (( issues_count += 1, capability_issues_count += 1 ))
  fi

  local -i tar_rc=0
  _zdx_doctor_gnu_tar || tar_rc=$?
  case "$tar_rc" in
    0) _zdx_doctor_label 'GNU tar' "Available (${reply[1]}, ${reply[2]}) [File & Archive Utilities]" ;;
    130|143) return $tar_rc ;;
    1)
      if (( ${#reply} )); then
        _zdx_doctor_label 'GNU tar' "INCOMPATIBLE (${reply[1]}, ${reply[2]}) [File & Archive Utilities]"
      else
        _zdx_doctor_label 'GNU tar' 'MISSING (hardened TAR extraction) [File & Archive Utilities]'
      fi
      _zdx_doctor_dim 'The File suite requires GNU tar, found as either tar or gtar.'
      [[ "$os" != macOS ]] || _zdx_doctor_label 'Suggested command' 'brew install gnu-tar'
      _zdx_doctor_label 'Official link' 'https://www.gnu.org/software/tar/'
      (( issues_count += 1, capability_issues_count += 1 ))
      ;;
    *)
      _zdx_doctor_label 'GNU tar' "Unknown (version check status $tar_rc) [File & Archive Utilities]"
      (( issues_count += 1, capability_issues_count += 1, indeterminate_probe_count += 1 ))
      ;;
  esac

  # Every public command is a shell function, so it takes precedence over an
  # executable of the same name on PATH. Report such names; they are not
  # issues. The core's command table is absent when this file is sourced on
  # its own, and so is the section.
  if (( ${+_ZDX_LAZY_FILES} )); then
    _zdx_doctor_section "Command Names"
    local -a shadowed_commands=()
    local command_name
    for command_name in "${(@ok)_ZDX_LAZY_FILES}"; do
      (( ${+commands[$command_name]} )) && shadowed_commands+=("$command_name")
    done
    if (( ${#shadowed_commands} == 0 )); then
      _zdx_doctor_label 'Command names' 'No executable on PATH shares a ZDX command name'
    else
      _zdx_doctor_label 'PATH names' "ZDX commands take precedence over ${(j:, :)shadowed_commands}"
      _zdx_doctor_dim "Run 'command NAME' to reach the executable."
    fi
  fi

  # The core refuses a configuration or overrides file that fails its
  # ownership and permission checks at startup and records it here.
  if (( ${+_ZDX_REFUSED_USER_FILES} )); then
    _zdx_doctor_section "User Files"
    if (( ${#_ZDX_REFUSED_USER_FILES} == 0 )); then
      _zdx_doctor_label 'User files' 'No configuration or overrides file was refused at startup'
    else
      local refused_file
      for refused_file in "${_ZDX_REFUSED_USER_FILES[@]}"; do
        _zdx_doctor_label 'Refused at startup' "$refused_file (owner, link count, or group/other write permission)"
        _zdx_doctor_info \
          "Fix it, for example: chmod -- go-w ${(q-)refused_file} ${(q-)${refused_file:A:h}}; then open a new shell."
        (( issues_count += 1 ))
        (( capability_issues_count += 1 ))
      done
    fi
  fi

  if (( issues_count == 0 )); then
    _zdx_doctor_success 'Diagnosis completed: no issues found.'
    return 0
  fi
  _zdx_doctor_count_noun "$issues_count" \
    'dependency or capability issue' 'dependency or capability issues'
  _zdx_doctor_label Issues "$REPLY"
  if (( ${#missing_pkgs} == 0 )) || [[ "$pm" == none ]]; then
    _zdx_doctor_warn 'Diagnosis unresolved: review the reported issues, then run zdx-doctor again.'
    return 1
  fi

  local -i install_rc=0
  local install_outcome=""
  REPLY=""
  _zdx_doctor_run_install "$dry_run" "$pm" missing_cmds "${missing_pkgs[@]}" || install_rc=$?
  install_outcome="$REPLY"
  (( install_rc == 130 || install_rc == 143 )) && return $install_rc
  (( install_rc == 0 )) || return 1
  case "$install_outcome" in
    declined) return 0 ;;
    planned)
      if (( indeterminate_probe_count > 0 )); then
        _zdx_doctor_warn 'Diagnosis unresolved: the dry-run plan excludes uncertain probes.'
        return 1
      fi
      return 0 ;;
    installed)
      if (( capability_issues_count > 0 )); then
        _zdx_doctor_warn 'Installation commands completed; unresolved capability checks remain. Run zdx-doctor again after reviewing the guidance above.'
        return 1
      fi
      _zdx_doctor_success 'Installation commands completed. Run zdx-doctor again to verify dependencies.'
      return 0 ;;
    *)
      _zdx_doctor_error 'Installation outcome was unavailable. Run zdx-doctor again.'
      return 1 ;;
  esac
}

typeset -g _ZDX_DOCTOR_SOURCED=1
