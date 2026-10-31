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
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_zdx_doctor_log() {
  emulate -L zsh
  local level="${1:-info}"
  local message="${2:-}"
  local color="" marker=""

  case "$level" in
    success) color='1;32'; marker='✔' ;;
    warn)    color='1;33'; marker='⚠' ;;
    info)    color='0;36'; marker='➜' ;;
    error)   color='1;31'; marker='✘' ;;
    dim)     color='0;90'; marker='·' ;;
    na)      color='0;90'; marker='⊘' ;;
    *)       color='0'; marker='·' ;;
  esac

  if _zdx_doctor_color_enabled; then
    printf '\033[%sm%s\033[0m %s\n' \
      "$color" "$marker" "${(V)message}" >&2
  else
    printf '%s %s\n' "$marker" "${(V)message}" >&2
  fi
}

_zdx_doctor_header() {
  emulate -L zsh
  local title="${1:-ZDX Doctor}"
  print -u2 -r -- ""
  if _zdx_doctor_color_enabled; then
    printf '\033[1;35m════ %s ════\033[0m\n' "${(V)title}" >&2
  else
    printf '════ %s ════\n' "${(V)title}" >&2
  fi
  print -u2 -r -- ""
}

_zdx_doctor_section() {
  emulate -L zsh
  local title="${1:-Dependencies}"
  print -u2 -r -- ""
  if _zdx_doctor_color_enabled; then
    printf '\033[1;34m[%s]\033[0m\n' "${(V)title}" >&2
  else
    printf '[%s]\n' "${(V)title}" >&2
  fi
}

_zdx_doctor_success() { _zdx_doctor_log success "${1:-}"; }
_zdx_doctor_warn()    { _zdx_doctor_log warn "${1:-}"; }
_zdx_doctor_info()    { _zdx_doctor_log info "${1:-}"; }
_zdx_doctor_error()   { _zdx_doctor_log error "${1:-}"; }
_zdx_doctor_dim()     { _zdx_doctor_log dim "${1:-}"; }
# A row that cannot apply on this platform; it is never counted as an issue.
_zdx_doctor_not_applicable() { _zdx_doctor_log na "${1:-}"; }

# Reports configuration presence and the loaded copy without reading option
# files, inspecting theme contents, or querying terminal control sequences.
_zdx_doctor_visual_diagnostics() {
  emulate -L zsh
  local color_mode="terminal defaults"
  local theme_state="not configured"
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

  _zdx_doctor_info \
    "TERM: ${TERM:-unset}; colors: $color_mode; custom theme: $theme_state."
  _zdx_doctor_info \
    "fzf defaults: options=$options_state; file=$file_state (isolated by suite menus)."
  _zdx_doctor_info \
    "Doctor source: $_ZDX_DOCTOR_SOURCE_FILE; after updating this copy, open a new shell."
}

# --- Version Introspection ----------------------------------------------------

# stdout: one validated version token. Each probe runs with closed stdin and is
# captured whole before parsing, so a failed command never becomes an installed
# version: a failing probe returns its own status and unrecognized output
# returns 1. Status 0 with no output means the command has no version probe,
# and the caller shows only its path.
_zdx_doctor_get_version() {
  emulate -L zsh
  local MATCH="" MBEGIN=0 MEND=0
  local -a match=() mbegin=() mend=()
  local cmd="$1"
  local version_output="" version_token="" IFS=$' \t\n'
  local -a version_fields=()
  local -i version_rc=0
  case "$cmd" in
    fzf)
      local -x FZF_DEFAULT_OPTS="" FZF_DEFAULT_OPTS_FILE="" FZF_DEFAULT_COMMAND=""
      version_output=$(command fzf --version </dev/null 2>/dev/null) \
        || version_rc=$?
      (( version_rc == 0 )) || return $version_rc
      version_token="${version_output%%$'\n'*}"
      version_token="${version_token%%[[:space:]]*}"
      [[ "$version_token" =~ '^[0-9]+[.][0-9]+([.][0-9]+)?([.-][A-Za-z0-9]+)*$' ]] \
        || return 1
      printf '%s\n' "$version_token"
      return 0
      ;;
    git|gh|jq|uv|pipx|python3|curl)
      version_output=$(command "$cmd" --version </dev/null 2>/dev/null) \
        || version_rc=$?
      ;;
    wg-quick)
      # wg-quick has no version flag; wireguard-tools reports it through wg.
      command -v wg &>/dev/null || return 0
      version_output=$(command wg --version </dev/null 2>/dev/null) \
        || version_rc=$?
      ;;
    *)
      return 0
      ;;
  esac
  (( version_rc == 0 )) || return $version_rc

  version_fields=(${=version_output%%$'\n'*})
  case "$cmd" in
    git|gh)   version_token="${version_fields[3]-}" ;;   # git version 2.43.0
    jq)       version_token="${${version_fields[1]-}#jq-}" ;;  # jq-1.7.1
    pipx)     version_token="${version_fields[1]-}" ;;   # 1.4.3
    wg-quick) version_token="${${version_fields[2]-}#v}" ;;  # wireguard-tools v1.0
    *)        version_token="${version_fields[2]-}" ;;   # uv 0.4.0, Python 3.12.3
  esac
  [[ ${#version_token} -le 64 \
    && "$version_token" =~ '^[0-9]+([.][0-9]+)*([.+~_-]?[0-9A-Za-z]+)*$' ]] \
    || return 1
  printf '%s\n' "$version_token"
}

# True on macOS when <path> is an Apple Command Line Tools placeholder: the
# /usr/bin/git or /usr/bin/python3 shim while xcode-select reports no installed
# developer directory. Running a placeholder opens an installation dialog, so
# callers report the command as missing instead of probing it. Other /usr/bin
# commands, such as curl, are part of macOS itself.
_zdx_doctor_clt_placeholder() {
  emulate -L zsh
  local cmd="${1-}" resolved="${2-}" developer_dir=""
  case "$cmd" in
    git|python3) ;;
    *) return 1 ;;
  esac
  [[ "${OSTYPE:-}" == darwin* && "$resolved" == "/usr/bin/$cmd" ]] || return 1
  command -v xcode-select &>/dev/null || return 0
  developer_dir=$(command xcode-select -p </dev/null 2>/dev/null) || return 0
  developer_dir="${developer_dir%%$'\n'*}"
  [[ -n "$developer_dir" && -d "$developer_dir" ]] && return 1
  return 0
}

# --- Platform & Package Manager Introspection ---------------------------------

# True when Linux runs under WSL: its interop registration (WSLInterop, or
# WSLInterop-late on newer releases), its session variables, or a Microsoft
# kernel release string. A stripped environment keeps the kernel evidence.
# The optional argument replaces /proc for fixtures.
_zdx_doctor_is_wsl() {
  emulate -L zsh
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
  local os_name="${1:-}"
  [[ -n "$os_name" ]] || os_name=$(_zdx_doctor_detect_os)
  local -a candidates=()
  case "$os_name" in
    macOS)     candidates=(brew) ;;
    Linux|WSL) candidates=(apt-get dnf pacman apk brew) ;;
    *)         candidates=(brew apt-get dnf pacman apk) ;;
  esac

  local candidate=""
  for candidate in "${candidates[@]}"; do
    command -v "$candidate" &>/dev/null || continue
    if [[ "$candidate" == apt-get ]]; then
      print -r -- "apt"
    else
      print -r -- "$candidate"
    fi
    return 0
  done
  print -r -- "none"
}

_zdx_doctor_confirm() {
  emulate -L zsh
  local MATCH="" MBEGIN=0 MEND=0
  local -a match=() mbegin=() mend=()
  local prompt="${1:-Continue?}"
  [[ -t 0 && -t 2 ]] || return 2

  if _zdx_doctor_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "${(V)prompt}" >&2
  else
    printf '? %s [y/N]: ' "${(V)prompt}" >&2
  fi

  local answer=""
  IFS= read -r answer || {
    print -u2 -r -- ""
    return 2
  }
  print -u2 -r -- ""
  [[ "$answer" =~ '^[Yy]$' ]]
}

_zdx_doctor_package_name_valid() {
  emulate -L zsh
  local MATCH="" MBEGIN=0 MEND=0
  local -a match=() mbegin=() mend=()
  local package_name="${1:-}"
  (( ${#package_name} >= 1 && ${#package_name} <= 128 )) \
    && [[ "$package_name" =~ '^[A-Za-z0-9][A-Za-z0-9+._-]*$' ]]
}

# REPLY: COUNT with its noun, through the core service when it is loaded.
_zdx_doctor_count_noun() {
  emulate -L zsh
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

# True when PROGRAM is an absolute path whose resolved target is an
# executable regular file that group and other users cannot write, owned by
# root, or also by the current user when OWNER is "user".
_zdx_doctor_program_trusted() {
  emulate -L zsh
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
  local -i dry_run="$1"
  local package_manager="$2" missing_name="$3"
  shift 3
  local -a package_names=("$@") install_plan=()
  local sudo_program="" REPLY=""
  local -a reply=()

  _zdx_doctor_install_plan "$package_manager" "${package_names[@]}" || return 1
  install_plan=("${reply[@]}")
  sudo_program="$REPLY"

  _zdx_doctor_section "Install Plan"
  local -i step_index=0
  for step_index in {1..${#install_plan[@]}}; do
    _zdx_doctor_info "${step_index}. ${install_plan[step_index]}"
  done
  _zdx_doctor_count_noun "${#install_plan[@]}" command
  local plan_size="$REPLY"
  if (( dry_run )); then
    _zdx_doctor_info "Dry run: $plan_size planned; nothing was installed."
    return 0
  fi

  _zdx_doctor_confirm "Run the ${plan_size} above via ${package_manager}?"
  case $? in
    0) ;;
    1)
      _zdx_doctor_info "Skipping installation. You can run 'zdx doctor' anytime to check again."
      return 1
      ;;
    *)
      _zdx_doctor_info \
        "Skipping installation: confirmation needs a terminal. Review the plan with zdx-doctor --dry-run."
      return 1
      ;;
  esac

  _zdx_doctor_install_plan_current "$package_manager" install_plan \
    "$missing_name" "${package_names[@]}" || return 1
  if [[ -n "$sudo_program" ]]; then
    _zdx_doctor_info \
      "Privileged operation: sudo -v (authenticate once for the install plan)"
    _zdx_doctor_dim "Each planned command then runs with sudo -n."
    command "$sudo_program" -v >&2 || {
      _zdx_doctor_error "sudo authentication failed; nothing was installed."
      return 1
    }
    _zdx_doctor_install_plan_current "$package_manager" install_plan \
      "$missing_name" "${package_names[@]}" || return 1
  fi

  zmodload zsh/datetime 2>/dev/null
  local -a step_command=()
  local step_label=""
  local -F started_at=0
  local -i step_rc=0 remaining=0
  for step_index in {1..${#install_plan[@]}}; do
    if [[ -n "$sudo_program" ]] \
      && ! command "$sudo_program" -n true </dev/null 2>/dev/null; then
      _zdx_doctor_warn \
        "sudo no longer accepts the authentication without a prompt (for example with timestamp_timeout=0)."
      _zdx_doctor_info "Run the remaining commands yourself:"
      for (( remaining = step_index; remaining <= ${#install_plan[@]}; remaining++ )); do
        _zdx_doctor_info "  ${install_plan[remaining]}"
      done
      return 1
    fi
    step_command=("${(@Q)${(z)install_plan[step_index]}}")
    _zdx_doctor_step_label "$sudo_program" "${step_command[@]}"
    step_label="$REPLY"
    if (( ${+functions[_zdx_ui_step_banner]} )); then
      _zdx_ui_step_banner "$step_index" "${#install_plan[@]}" "$step_label"
    fi
    _zdx_doctor_dim "Executing: ${install_plan[step_index]}"
    started_at=${EPOCHREALTIME:-0}
    step_rc=0
    command "${step_command[@]}" </dev/null >&2 || step_rc=$?
    _zdx_doctor_step_result "$step_index" "${#install_plan[@]}" \
      "$step_label" "$step_rc" "$started_at"
    (( step_rc == 0 )) && continue
    for (( remaining = step_index + 1; remaining <= ${#install_plan[@]}; remaining++ )); do
      _zdx_doctor_step_label "$sudo_program" \
        "${(@Q)${(z)install_plan[remaining]}}"
      _zdx_doctor_step_result "$remaining" "${#install_plan[@]}" \
        "$REPLY" skip 0
    done
    _zdx_doctor_error "Installation failed. Review the package-manager errors above."
    return 1
  done
}

# REPLY: a short display label for one planned command: the sudo prefix is
# dropped and the program is shown by name.
# Usage: _zdx_doctor_step_label SUDO_PROGRAM WORD...
_zdx_doctor_step_label() {
  emulate -L zsh
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

# Prints one install step result through the core output service when it is
# loaded. STATUS is an exit status or "skip".
_zdx_doctor_step_result() {
  emulate -L zsh
  local index="$1" total="$2" label="$3" step_status="$4" started_at="$5"
  local seconds=""
  if [[ "$step_status" != skip && "$started_at" != 0* && -n "${EPOCHREALTIME:-}" ]]; then
    printf -v seconds '%.1f' $(( EPOCHREALTIME - started_at ))
  fi
  if (( ${+functions[_zdx_ui_step_result]} )); then
    case "$step_status" in
      0)    _zdx_ui_step_result "$index" "$total" "$label" done "" "$seconds" ;;
      skip) _zdx_ui_step_result "$index" "$total" "$label" not-run \
              "an earlier step failed" "" ;;
      *)    _zdx_ui_step_result "$index" "$total" "$label" failed \
              "exit $step_status" "$seconds" ;;
    esac
    return 0
  fi
  case "$step_status" in
    0)    _zdx_doctor_success "[$index/$total] $label — done" ;;
    skip) _zdx_doctor_dim "[$index/$total] $label — not run: an earlier step failed" ;;
    *)    _zdx_doctor_error "[$index/$total] $label — failed: exit $step_status" ;;
  esac
}

# Sets REPLY to the first available external timeout implementation.
_zdx_doctor_timeout_command() {
  emulate -L zsh
  REPLY=""

  local candidate=""
  local resolved_command=""
  for candidate in timeout gtimeout; do
    resolved_command=$(builtin command -v "$candidate" 2>/dev/null) || continue
    [[ -n "$resolved_command" && -x "$resolved_command" ]] || continue
    REPLY="$resolved_command"
    return 0
  done
  return 1
}

# Sets REPLY to fd, or to fdfind, the name Debian and Ubuntu install it under.
_zdx_doctor_fd_command() {
  emulate -L zsh
  REPLY=""

  local candidate=""
  local resolved_command=""
  for candidate in fd fdfind; do
    resolved_command=$(builtin command -v "$candidate" 2>/dev/null) || continue
    [[ -n "$resolved_command" && -x "$resolved_command" ]] || continue
    REPLY="$resolved_command"
    return 0
  done
  return 1
}

# Sets REPLY to the first available SHA-256 implementation.
_zdx_doctor_sha256_command() {
  emulate -L zsh
  REPLY=""

  local candidate=""
  local resolved_command=""
  for candidate in sha256sum shasum; do
    resolved_command=$(builtin command -v "$candidate" 2>/dev/null) || continue
    [[ -n "$resolved_command" && -x "$resolved_command" ]] || continue
    REPLY="$resolved_command"
    return 0
  done
  return 1
}

# Sets reply=(path version-line) for the first of tar and gtar that reports
# GNU tar, the order in which the File suite resolves its archiver.
_zdx_doctor_gnu_tar() {
  emulate -L zsh
  reply=()

  local candidate="" resolved_command="" version_text=""
  local -x LC_ALL=C
  for candidate in tar gtar; do
    command -v "$candidate" &>/dev/null || continue
    resolved_command=$(builtin command -v "$candidate" 2>/dev/null) || continue
    version_text=$(command "$candidate" --version </dev/null 2>/dev/null) \
      || continue
    [[ "$version_text" == *"GNU tar"* ]] || continue
    reply=("$resolved_command" "${version_text%%$'\n'*}")
    return 0
  done
  return 1
}

# Reports one dependency record (cmd|suite|severity|url|apt|brew|dnf|pacman|
# description). It updates zdx-doctor's pm-dependent missing_cmds and
# missing_pkgs arrays and its issue counters through dynamic scope. An
# interrupted version probe returns its 130 or 143 status.
_zdx_doctor_report_dependency() {
  emulate -L zsh
  local -a fields=("${(@s:|:)1}")
  local cmd="${fields[1]-}" suite="${fields[2]-}" sev="${fields[3]-}"
  local url="${fields[4]-}" apt_n="${fields[5]-}" brew_n="${fields[6]-}"
  local dnf_n="${fields[7]-}" pac_n="${fields[8]-}" desc="${fields[9]-}"
  local suffix="" path_loc="" ver="" rec_cmd="" package_name=""
  local -i version_rc=0 placeholder=0
  [[ "$sev" == critical ]] || suffix=" [$suite]"

  if command -v "$cmd" &>/dev/null; then
    path_loc=$(builtin command -v "$cmd")
    _zdx_doctor_clt_placeholder "$cmd" "$path_loc" && placeholder=1
  fi

  if [[ -n "$path_loc" ]] && (( ! placeholder )); then
    ver=$(_zdx_doctor_get_version "$cmd") || version_rc=$?
    if (( version_rc != 0 )); then
      local failure="$cmd - VERSION CHECK FAILED (${path_loc}, status $version_rc); verify the active executable.${suffix}"
      if [[ "$sev" == critical ]]; then
        _zdx_doctor_error "$failure"
      else
        _zdx_doctor_warn "$failure"
      fi
      (( version_rc == 130 || version_rc == 143 )) && return $version_rc
      (( issues_count += 1 ))
      (( capability_issues_count += 1 ))
    elif [[ -n "$ver" ]]; then
      _zdx_doctor_success "$cmd - Installed (${path_loc}, v${ver})${suffix}"
    else
      _zdx_doctor_success "$cmd - Installed (${path_loc})${suffix}"
    fi
    return 0
  fi

  if [[ "$sev" == critical ]]; then
    _zdx_doctor_error "$cmd - MISSING (${desc})${suffix}"
  else
    _zdx_doctor_warn "$cmd - MISSING (${desc})${suffix}"
  fi
  if (( placeholder )); then
    _zdx_doctor_info \
      "  ➜ ${path_loc} is an Apple Command Line Tools placeholder; it was not run because running it opens an installation dialog."
    _zdx_doctor_info "  ➜ Apple's tools: xcode-select --install"
  fi
  _zdx_doctor_info "  ➜ Official Link: $url"
  case "$pm" in
    apt)
      package_name="$apt_n"
      [[ -n "$apt_n" ]] \
        && rec_cmd="sudo apt-get update && sudo apt-get install -y $apt_n"
      ;;
    brew)
      package_name="$brew_n"
      [[ -n "$brew_n" ]] && rec_cmd="brew install $brew_n"
      ;;
    dnf)
      package_name="$dnf_n"
      [[ -n "$dnf_n" ]] && rec_cmd="sudo dnf install -y $dnf_n"
      ;;
    pacman)
      package_name="$pac_n"
      [[ -n "$pac_n" ]] && rec_cmd="sudo pacman -S --noconfirm $pac_n"
      ;;
    apk)
      package_name="$cmd"
      rec_cmd="sudo apk add $cmd"
      ;;
  esac
  if [[ -n "$rec_cmd" ]]; then
    _zdx_doctor_info "  ➜ Suggested Command: $rec_cmd"
    missing_cmds+=("$cmd")
    missing_pkgs+=("$package_name")
  fi
  (( issues_count += 1 ))
  return 0
}

_zdx_doctor_usage() {
  emulate -L zsh
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
  local -i dry_run=0
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
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
  _zdx_doctor_success "Platform:      ${os}"
  _zdx_doctor_success "Shell:         zsh ${ZSH_VERSION:-unknown}"
  _zdx_doctor_success "Pkg Manager:   ${pm}"

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
  local -i dependency_rc=0
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
    _zdx_doctor_success \
      "timeout/gtimeout - Available (${REPLY}) [System, Python & VPN]"
  else
    # Not an issue: the core Zsh watchdog enforces the same bounds, only slower.
    _zdx_doctor_info \
      "timeout/gtimeout - Not found (bounded inventories, probes, and remote lookups use the slower Zsh watchdog) [System, Python & VPN]"
    if [[ "$os" == macOS ]]; then
      _zdx_doctor_info "  ➜ Optional: brew install coreutils provides the faster gtimeout."
    else
      _zdx_doctor_info "  ➜ Optional: GNU coreutils provides the faster timeout command."
    fi
  fi

  if _zdx_doctor_fd_command; then
    _zdx_doctor_success \
      "fd/fdfind - Available (${REPLY}) [Workspaces]"
  else
    # Not an issue: workspace discovery falls back to find.
    _zdx_doctor_info \
      "fd/fdfind - Not found (workspace discovery uses find) [Workspaces]"
    if [[ "$os" == macOS ]]; then
      _zdx_doctor_info "  ➜ Optional: brew install fd provides faster discovery."
    else
      _zdx_doctor_info "  ➜ Optional: the fd package (fd-find on Debian and Ubuntu) provides faster discovery."
    fi
  fi

  if _zdx_doctor_sha256_command; then
    _zdx_doctor_success \
      "sha256sum/shasum - Available (${REPLY}) [File]"
  else
    _zdx_doctor_warn \
      "sha256sum/shasum - MISSING (archive identity checks) [File]"
    _zdx_doctor_info "  ➜ Either command satisfies this capability."
    _zdx_doctor_info "  ➜ Official Link: https://www.gnu.org/software/coreutils/"
    (( issues_count += 1 ))
    (( capability_issues_count += 1 ))
  fi

  if [[ "$os" != Linux && "$os" != WSL ]]; then
    _zdx_doctor_not_applicable \
      "ip - Not applicable on ${os} (iproute2 route lookups run on Linux and WSL) [VPN]"
  elif command -v ip &>/dev/null; then
    path_loc=$(builtin command -v ip)
    _zdx_doctor_success "ip - Available (${path_loc}) [VPN routes]"
  else
    _zdx_doctor_warn "ip - MISSING (route lookups in VPN diagnostics) [VPN]"
    (( issues_count += 1 ))
    (( capability_issues_count += 1 ))
  fi

  local tar_version=""
  if _zdx_doctor_gnu_tar; then
    _zdx_doctor_success \
      "GNU tar - Available (${reply[1]}, ${reply[2]}) [File & Archive Utilities]"
  else
    if ! command -v tar &>/dev/null; then
      _zdx_doctor_warn \
        "GNU tar - MISSING (hardened TAR extraction) [File & Archive Utilities]"
    else
      path_loc=$(builtin command -v tar)
      tar_version=$(LC_ALL=C command tar --version </dev/null 2>/dev/null) \
        || tar_version=""
      tar_version="${tar_version%%$'\n'*}"
      [[ -n "$tar_version" ]] || tar_version="version could not be identified"
      _zdx_doctor_warn \
        "GNU tar - INCOMPATIBLE (${path_loc}, ${tar_version}) [File & Archive Utilities]"
      _zdx_doctor_dim \
        "The File suite requires GNU tar, found as either tar or gtar."
    fi
    if [[ "$os" == macOS ]]; then
      _zdx_doctor_info "  ➜ Homebrew installs GNU tar as gtar: brew install gnu-tar"
    fi
    _zdx_doctor_info "  ➜ Official Link: https://www.gnu.org/software/tar/"
    (( issues_count += 1 ))
    (( capability_issues_count += 1 ))
  fi

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
      _zdx_doctor_success "No executable on PATH shares a ZDX command name"
    else
      _zdx_doctor_info \
        "ZDX commands take precedence over these executables on PATH: ${(j:, :)shadowed_commands}"
      _zdx_doctor_info "  ➜ Run 'command NAME' to reach the executable."
    fi
  fi

  # The core refuses a configuration or overrides file that fails its
  # ownership and permission checks at startup and records it here.
  if (( ${+_ZDX_REFUSED_USER_FILES} )); then
    _zdx_doctor_section "User Files"
    if (( ${#_ZDX_REFUSED_USER_FILES} == 0 )); then
      _zdx_doctor_success \
        "No configuration or overrides file was refused at startup"
    else
      local refused_file
      for refused_file in "${_ZDX_REFUSED_USER_FILES[@]}"; do
        _zdx_doctor_warn \
          "Refused at startup: $refused_file (owner, link count, or group/other write permission)"
        _zdx_doctor_info \
          "  ➜ Fix it, for example: chmod -- go-w ${(q-)refused_file} ${(q-)${refused_file:A:h}}; then open a new shell."
        (( issues_count += 1 ))
        (( capability_issues_count += 1 ))
      done
    fi
  fi

  print -u2 -r -- ""
  print -u2 -r -- \
    "═════════════════════════════════════════════════════════════"

  if [[ $issues_count -eq 0 ]]; then
    _zdx_doctor_success "Diagnosis: Perfect! No issues found. Your ZDX ecosystem is fully optimal."
    return 0
  fi

  _zdx_doctor_count_noun "$issues_count" \
    "dependency or capability issue" "dependency or capability issues"
  _zdx_doctor_warn "Diagnosis: $REPLY identified."

  if (( ${#missing_pkgs[@]} == 0 )) || [[ "$pm" == "none" ]]; then
    _zdx_doctor_info "Resolve the reported issues, then run zdx-doctor again."
    return 1
  fi

  _zdx_doctor_run_install "$dry_run" "$pm" missing_cmds "${missing_pkgs[@]}"
  local -i install_rc=$?
  (( dry_run || install_rc != 0 )) && return $install_rc
  if (( capability_issues_count > 0 )); then
    _zdx_doctor_count_noun "$capability_issues_count" \
      "operational capability issue" "operational capability issues"
    _zdx_doctor_warn "Selected packages installed, but $REPLY remain."
    _zdx_doctor_info \
      "Run zdx-doctor again after resolving the manual guidance above."
    return 1
  fi
  _zdx_doctor_success \
    "All packages installed successfully! Run zdx-doctor again to verify."
  return 0
}

typeset -g _ZDX_DOCTOR_SOURCED=1
