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

# funcstack preserves the source filename before diagnostic display escaping.
typeset -g _ZDX_DOCTOR_SOURCE_FILE="${${funcstack[1]:-$0}:A}"

# --- Private UI & Logging Helpers ---------------------------------------------

_zdx_doctor_color_enabled() {
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 2 ]]
}

_zdx_doctor_log() {
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
  local package_name="${1:-}"
  (( ${#package_name} >= 1 && ${#package_name} <= 128 )) \
    && [[ "$package_name" =~ '^[A-Za-z0-9][A-Za-z0-9+._-]*$' ]]
}

_zdx_doctor_run_package_command() {
  local -a package_command=("$@")
  (( ${#package_command[@]} > 0 )) || return 2

  _zdx_doctor_info \
    "Executing: ${(j: :)${(@q)package_command}}"
  command "${package_command[@]}" >&2
}

_zdx_doctor_install_packages() {
  local package_manager="${1:-}"
  shift 2>/dev/null || true
  local -a package_names=("$@")

  (( ${#package_names[@]} >= 1 && ${#package_names[@]} <= 64 )) || return 2
  local package_name=""
  for package_name in "${package_names[@]}"; do
    _zdx_doctor_package_name_valid "$package_name" || {
      _zdx_doctor_error "Refusing an invalid package name."
      return 2
    }
  done

  case "$package_manager" in
    apt)
      _zdx_doctor_run_package_command sudo apt-get update || return
      _zdx_doctor_run_package_command \
        sudo apt-get install -y "${package_names[@]}"
      ;;
    brew)
      _zdx_doctor_run_package_command brew install "${package_names[@]}"
      ;;
    dnf)
      _zdx_doctor_run_package_command \
        sudo dnf install -y "${package_names[@]}"
      ;;
    pacman)
      _zdx_doctor_run_package_command \
        sudo pacman -S --noconfirm "${package_names[@]}"
      ;;
    apk)
      _zdx_doctor_run_package_command \
        sudo apk add "${package_names[@]}"
      ;;
    *)
      _zdx_doctor_error "Unsupported package manager: $package_manager"
      return 2
      ;;
  esac
}

# Sets REPLY to the first available external timeout implementation.
_zdx_doctor_timeout_command() {
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
  cat >&2 <<'EOF'

  ═════════════════════════════════════════════════════════════
         ZDX Doctor - Dependency Diagnostic CLI Assistant
  ═════════════════════════════════════════════════════════════

  Usage:
    zdx-doctor                Run diagnostics and offer an interactive installer
    zdx-doctor -h|--help|help Show this documentation

  Options:
    -h, --help, help          Show this documentation screen

  Features:
    - OS and environment detection
    - Real-time checks for Core vs Optional suite requirements
    - Alternative-command and installed-library capability checks
    - Native version introspection
    - Visual status indicator dashboard
    - Tailored official URLs and copy-paste installation tips
    - Safe, interactive, OS-aware batch installation helper

EOF
}

zdx-doctor() {
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
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

  print -u2 -r -- ""
  print -u2 -r -- \
    "═════════════════════════════════════════════════════════════"

  if [[ $issues_count -eq 0 ]]; then
    _zdx_doctor_success "Diagnosis: Perfect! No issues found. Your ZDX ecosystem is fully optimal."
    return 0
  fi

  _zdx_doctor_warn "Diagnosis: $issues_count dependency or capability issue(s) identified."

  if (( ${#missing_pkgs[@]} == 0 )) || [[ "$pm" == "none" ]]; then
    _zdx_doctor_info "Resolve the reported issues, then run zdx-doctor again."
    return 1
  fi

  # Interactive batch installation option
  if _zdx_doctor_confirm "Would you like ZDX to attempt installing the missing packages (${missing_cmds[*]}) via ${pm}?"; then
    if _zdx_doctor_install_packages "$pm" "${missing_pkgs[@]}"; then
      if (( capability_issues_count > 0 )); then
        _zdx_doctor_warn \
          "Selected packages installed, but ${capability_issues_count} operational capability issue(s) remain."
        _zdx_doctor_info \
          "Run zdx-doctor again after resolving the manual guidance above."
        return 1
      fi
      _zdx_doctor_success \
        "All packages installed successfully! Run zdx-doctor again to verify."
      return 0
    else
      _zdx_doctor_error \
        "Installation failed. Review the package-manager errors above."
      return 1
    fi
  else
    _zdx_doctor_info "Skipping installation. You can run 'zdx doctor' anytime to check again."
    return 1
  fi
}

typeset -g _ZDX_DOCTOR_SOURCED=1
