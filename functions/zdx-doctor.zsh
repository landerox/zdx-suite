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

_zdx_doctor_get_version() {
  local cmd="$1"
  case "$cmd" in
    fzf)
      local -x FZF_DEFAULT_OPTS="" FZF_DEFAULT_OPTS_FILE="" FZF_DEFAULT_COMMAND=""
      local version_output="" version_token=""
      local -i version_rc=0
      version_output=$(command fzf --version </dev/null 2>/dev/null) \
        || version_rc=$?
      (( version_rc == 0 )) || return $version_rc
      version_token="${version_output%%$'\n'*}"
      version_token="${version_token%%[[:space:]]*}"
      [[ "$version_token" =~ '^[0-9]+[.][0-9]+([.][0-9]+)?([.-][A-Za-z0-9]+)*$' ]] \
        || return 1
      printf '%s\n' "$version_token"
      ;;
    git)
      git --version 2>/dev/null | head -n 1 | awk '{print $3}'
      ;;
    jq)
      jq --version 2>/dev/null | head -n 1 | sed 's/^jq-//'
      ;;
    gh)
      gh --version 2>/dev/null | head -n 1 | awk '{print $3}'
      ;;
    docker)
      docker --version 2>/dev/null | head -n 1 | awk '{print $3}' | sed 's/,$//'
      ;;
    wg-quick)
      wg-quick --version 2>/dev/null | head -n 1 | awk '{print $2}'
      ;;
    uv)
      uv --version 2>/dev/null | head -n 1 | awk '{print $2}'
      ;;
    pipx)
      pipx --version 2>/dev/null | head -n 1
      ;;
    nvidia-smi)
      echo "available"
      ;;
    *)
      echo "installed"
      ;;
  esac
}

# --- Platform & Package Manager Introspection ---------------------------------

_zdx_doctor_detect_os() {
  if [[ "$OSTYPE" == darwin* ]]; then
    echo "macOS"
  elif [[ "$OSTYPE" == linux* ]]; then
    if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop || -n "${WSL_DISTRO_NAME:-}" ]]; then
      echo "WSL"
    else
      echo "Linux"
    fi
  else
    echo "Unknown"
  fi
}

_zdx_doctor_detect_pkg_manager() {
  if command -v brew &>/dev/null; then
    echo "brew"
  elif command -v apt-get &>/dev/null; then
    echo "apt"
  elif command -v dnf &>/dev/null; then
    echo "dnf"
  elif command -v pacman &>/dev/null; then
    echo "pacman"
  elif command -v apk &>/dev/null; then
    echo "apk"
  else
    echo "none"
  fi
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

# Sets REPLY to the first GNU tar version line when the active tar is GNU tar.
_zdx_doctor_gnu_tar_version() {
  REPLY=""

  local version_text=""
  local -x LC_ALL=C
  version_text=$(command tar --version 2>/dev/null) || return 1
  [[ "$version_text" == *"GNU tar"* ]] || return 1
  REPLY="${version_text%%$'\n'*}"
}

# Sets REPLY to a compatible installed Hugging Face backend description.
# The probe is isolated and deadline-bound; no package is installed here.
_zdx_doctor_hf_backend() {
  REPLY=""

  local timeout_command="${1:-}"
  [[ -n "$timeout_command" && -x "$timeout_command" ]] || return 1

  local -a candidates=()
  if [[ -n "${HF_PYTHON:-}" ]]; then
    candidates=("$HF_PYTHON")
  else
    candidates=(python3 python)
  fi

  local candidate=""
  local resolved_command=""
  local version=""
  for candidate in "${candidates[@]}"; do
    resolved_command=$(builtin command -v "$candidate" 2>/dev/null) || continue
    [[ -n "$resolved_command" && -x "$resolved_command" ]] || continue
    version=$(command "$timeout_command" -k 2s 15s \
      "$resolved_command" -I -c '
import re
import sys
import huggingface_hub
version = getattr(huggingface_hub, "__version__", "")
match = re.match(r"^([0-9]+)[.]([0-9]+)(?:[.]([0-9]+))?", version)
if not match:
    sys.exit(2)
major, minor = int(match.group(1)), int(match.group(2))
if not ((major == 0 and minor >= 23) or major == 1):
    sys.exit(3)
print(version)
' 2>/dev/null) || continue
    [[ "$resolved_command" != *[[:cntrl:]]* \
      && "$version" != *[[:cntrl:]]* \
      && "$version" =~ '^[0-9]+[.][0-9]+([.][0-9]+)?' ]] || continue
    REPLY="${resolved_command}, huggingface_hub ${version}"
    return 0
  done
  return 1
}

# --- Main Checkup logic -------------------------------------------------------

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
  pm=$(_zdx_doctor_detect_pkg_manager)

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
    "jq|Core System|critical|https://jqlang.github.io/jq/|jq|jq|jq|jq|Telemetry parsing & Network diagnostics"
    "gh|Git, Workspaces & CI|optional|https://cli.github.com/|gh|gh|gh|github-cli|GitHub repository and Actions workflows"
    "python3|App & CI|optional|https://www.python.org/downloads/|python3|python|python3|python|Bounded descriptor and GitHub JSON parsing"
    "curl|Network & Remote Diagnostics|optional|https://curl.se/download.html|curl|curl|curl|curl|Bounded HTTPS diagnostics"
    "docker|Docker Dash|optional|https://docs.docker.com/engine/install/|docker.io|docker|docker|docker|Container dashboards"
    "wg-quick|WireGuard VPN|optional|https://www.wireguard.com/install/|wireguard-tools|wireguard-tools|wireguard-tools|wireguard-tools|WireGuard VPN tunnel management"
    "uv|Python & Virtualenvs|optional|https://github.com/astral-sh/uv|uv|uv|uv|uv|Python and packages manager"
    "pipx|Python & Virtualenvs|optional|https://github.com/pypa/pipx|pipx|pipx|pipx|python-pipx|Alternative Python global tools"
    "nvidia-smi|MLOps & Hardware|optional|https://developer.nvidia.com/cuda-downloads|nvidia-utils||||NVIDIA GPU hardware metrics"
  )

  local -a missing_cmds
  local -a missing_pkgs
  local -i issues_count=0
  local -i capability_issues_count=0

  # Print Core Dependencies
  _zdx_doctor_section "Core Dependencies"
  local d cmd suite sev url apt_n brew_n dnf_n pac_n desc is_missing path_loc ver
  for d in "${deps[@]}"; do
    # Split fields
    cmd=$(echo "$d" | cut -d'|' -f1)
    suite=$(echo "$d" | cut -d'|' -f2)
    sev=$(echo "$d" | cut -d'|' -f3)
    url=$(echo "$d" | cut -d'|' -f4)
    apt_n=$(echo "$d" | cut -d'|' -f5)
    brew_n=$(echo "$d" | cut -d'|' -f6)
    dnf_n=$(echo "$d" | cut -d'|' -f7)
    pac_n=$(echo "$d" | cut -d'|' -f8)
    desc=$(echo "$d" | cut -d'|' -f9)

    if [[ "$sev" != "critical" ]]; then
      continue
    fi

    if command -v "$cmd" &>/dev/null; then
      path_loc=$(builtin command -v "$cmd")
      local -i version_rc=0
      ver=$(_zdx_doctor_get_version "$cmd") || version_rc=$?
      if (( version_rc != 0 )); then
        _zdx_doctor_error \
          "$cmd - VERSION CHECK FAILED (${path_loc}, status $version_rc); verify the active executable."
        (( version_rc == 130 || version_rc == 143 )) && return $version_rc
        (( issues_count += 1 ))
        (( capability_issues_count += 1 ))
      else
        _zdx_doctor_success "$cmd - Installed (${path_loc}, v${ver})"
      fi
    else
      _zdx_doctor_error "$cmd - MISSING (${desc})"
      _zdx_doctor_info "  ➜ Official Link: $url"
      local rec_cmd=""
      case "$pm" in
        apt)    rec_cmd="sudo apt-get update && sudo apt-get install -y $apt_n" ;;
        brew)   rec_cmd="brew install $brew_n" ;;
        dnf)    rec_cmd="sudo dnf install -y $dnf_n" ;;
        pacman) rec_cmd="sudo pacman -S --noconfirm $pac_n" ;;
        apk)    rec_cmd="sudo apk add $cmd" ;;
      esac
      if [[ -n "$rec_cmd" ]]; then
        _zdx_doctor_info "  ➜ Suggested Command: $rec_cmd"
        missing_cmds+=("$cmd")
        case "$pm" in
          apt)    missing_pkgs+=("$apt_n") ;;
          brew)   missing_pkgs+=("$brew_n") ;;
          dnf)    missing_pkgs+=("$dnf_n") ;;
          pacman) missing_pkgs+=("$pac_n") ;;
          apk)    missing_pkgs+=("$cmd") ;;
        esac
      fi
      (( issues_count++ ))
    fi
  done

  # Print Optional Dependencies
  _zdx_doctor_section "Optional Suite-Specific Dependencies"
  for d in "${deps[@]}"; do
    # Split fields
    cmd=$(echo "$d" | cut -d'|' -f1)
    suite=$(echo "$d" | cut -d'|' -f2)
    sev=$(echo "$d" | cut -d'|' -f3)
    url=$(echo "$d" | cut -d'|' -f4)
    apt_n=$(echo "$d" | cut -d'|' -f5)
    brew_n=$(echo "$d" | cut -d'|' -f6)
    dnf_n=$(echo "$d" | cut -d'|' -f7)
    pac_n=$(echo "$d" | cut -d'|' -f8)
    desc=$(echo "$d" | cut -d'|' -f9)

    if [[ "$sev" == "critical" ]]; then
      continue
    fi

    # Special logic for nvidia-smi (since it might only exist on gpu hardware setups)
    if [[ "$cmd" == "nvidia-smi" && "$os" == "macOS" ]]; then
      continue # Skip nvidia check entirely on macOS
    fi

    if command -v "$cmd" &>/dev/null; then
      path_loc=$(builtin command -v "$cmd")
      ver=$(_zdx_doctor_get_version "$cmd")
      _zdx_doctor_success "$cmd - Installed (${path_loc}, v${ver}) [$suite]"
    else
      _zdx_doctor_warn "$cmd - MISSING (${desc}) [$suite]"
      _zdx_doctor_info "  ➜ Official Link: $url"
      local rec_cmd=""
      case "$pm" in
        apt)    [[ -n "$apt_n" ]] && rec_cmd="sudo apt-get update && sudo apt-get install -y $apt_n" ;;
        brew)   [[ -n "$brew_n" ]] && rec_cmd="brew install $brew_n" ;;
        dnf)    [[ -n "$dnf_n" ]] && rec_cmd="sudo dnf install -y $dnf_n" ;;
        pacman) [[ -n "$pac_n" ]] && rec_cmd="sudo pacman -S --noconfirm $pac_n" ;;
        apk)    rec_cmd="sudo apk add $cmd" ;;
      esac
      if [[ -n "$rec_cmd" ]]; then
        _zdx_doctor_info "  ➜ Suggested Command: $rec_cmd"
        # Special case for Docker or Wireguard or nvidia where automated install might need caution, but we add to installer
        if [[ "$cmd" != "nvidia-smi" && -n "$rec_cmd" ]]; then
          missing_cmds+=("$cmd")
          case "$pm" in
            apt)    missing_pkgs+=("$apt_n") ;;
            brew)   missing_pkgs+=("$brew_n") ;;
            dnf)    missing_pkgs+=("$dnf_n") ;;
            pacman) missing_pkgs+=("$pac_n") ;;
            apk)    missing_pkgs+=("$cmd") ;;
          esac
        fi
      fi
      (( issues_count++ ))
    fi
  done

  # Check required capabilities that cannot be represented as one installable
  # command. These checks never add packages to the batch installer.
  _zdx_doctor_section "Suite Operational Capabilities"

  local timeout_command=""
  if _zdx_doctor_timeout_command; then
    timeout_command="$REPLY"
    _zdx_doctor_success \
      "timeout/gtimeout - Available (${timeout_command}) [Docker, Python, CI, Network, Hugging Face Hub & NVIDIA GPU]"
  else
    _zdx_doctor_warn \
      "timeout/gtimeout - MISSING (bounded Docker and suite inventories, remote diagnostics, metadata, and hardware probes) [Docker, Python, CI, Network, Hugging Face Hub & NVIDIA GPU]"
    _zdx_doctor_info "  ➜ Either command satisfies this capability."
    _zdx_doctor_info "  ➜ Official Link: https://www.gnu.org/software/coreutils/"
    (( issues_count++ ))
    (( capability_issues_count++ ))
  fi

  if _zdx_doctor_sha256_command; then
    _zdx_doctor_success \
      "sha256sum/shasum - Available (${REPLY}) [App, Docker & Environment]"
  else
    _zdx_doctor_warn \
      "sha256sum/shasum - MISSING (descriptor, Docker identity, and passive-data revalidation) [App, Docker & Environment]"
    _zdx_doctor_info "  ➜ Either command satisfies this capability."
    _zdx_doctor_info "  ➜ Official Link: https://www.gnu.org/software/coreutils/"
    (( issues_count++ ))
    (( capability_issues_count++ ))
  fi

  if command -v ping &>/dev/null; then
    path_loc=$(builtin command -v ping)
    _zdx_doctor_success "ping - Installed (${path_loc}) [Network latency]"
  else
    _zdx_doctor_warn \
      "ping - MISSING (bounded latency diagnostics) [Network]"
    (( issues_count++ ))
    (( capability_issues_count++ ))
  fi

  if command -v dig &>/dev/null; then
    path_loc=$(builtin command -v dig)
    _zdx_doctor_success \
      "dig/host - Available (${path_loc}) [Network DNS]"
  elif command -v host &>/dev/null; then
    path_loc=$(builtin command -v host)
    _zdx_doctor_success \
      "dig/host - Available (${path_loc}) [Network DNS]"
  else
    _zdx_doctor_warn \
      "dig/host - MISSING (bounded DNS diagnostics) [Network]"
    _zdx_doctor_info "  ➜ Either command satisfies this capability."
    (( issues_count++ ))
    (( capability_issues_count++ ))
  fi

  if command -v ip &>/dev/null; then
    path_loc=$(builtin command -v ip)
    _zdx_doctor_success \
      "ip/ifconfig - Available (${path_loc}) [Network interfaces]"
  elif command -v ifconfig &>/dev/null; then
    path_loc=$(builtin command -v ifconfig)
    _zdx_doctor_success \
      "ip/ifconfig - Available (${path_loc}) [Network interfaces]"
  else
    _zdx_doctor_warn \
      "ip/ifconfig - MISSING (augmented interface and route diagnostics) [Network]"
    _zdx_doctor_info \
      "  ➜ Linux sysfs remains available for a reduced local inventory."
    (( issues_count++ ))
    (( capability_issues_count++ ))
  fi

  if command -v findmnt &>/dev/null; then
    path_loc=$(builtin command -v findmnt)
    _zdx_doctor_success \
      "findmnt - Installed (${path_loc}) [AI / File / Python / Hugging Face]"
  else
    _zdx_doctor_warn \
      "findmnt - MISSING (recursive mount-boundary validation) [AI / File / Python / Hugging Face]"
    _zdx_doctor_info \
      "  ➜ Official Link: https://www.kernel.org/pub/linux/utils/util-linux/"
    (( issues_count++ ))
    (( capability_issues_count++ ))
  fi

  local tar_version=""
  if ! command -v tar &>/dev/null; then
    _zdx_doctor_warn \
      "GNU tar - MISSING (hardened TAR extraction) [File & Archive Utilities]"
    _zdx_doctor_info "  ➜ Official Link: https://www.gnu.org/software/tar/"
    (( issues_count++ ))
    (( capability_issues_count++ ))
  elif _zdx_doctor_gnu_tar_version; then
    path_loc=$(builtin command -v tar)
    _zdx_doctor_success \
      "GNU tar - Available (${path_loc}, ${REPLY}) [File & Archive Utilities]"
  else
    path_loc=$(builtin command -v tar)
    tar_version=$(LC_ALL=C command tar --version 2>/dev/null) \
      || tar_version=""
    tar_version="${tar_version%%$'\n'*}"
    [[ -n "$tar_version" ]] || tar_version="version could not be identified"
    _zdx_doctor_warn \
      "GNU tar - INCOMPATIBLE (${path_loc}, ${tar_version}) [File & Archive Utilities]"
    _zdx_doctor_dim \
      "The File suite requires the 'tar' command itself to resolve to GNU tar."
    _zdx_doctor_info "  ➜ Official Link: https://www.gnu.org/software/tar/"
    (( issues_count++ ))
    (( capability_issues_count++ ))
  fi

  if [[ -n "$timeout_command" ]]; then
    if _zdx_doctor_hf_backend "$timeout_command"; then
      _zdx_doctor_success \
        "huggingface_hub - Compatible (${REPLY}) [Hugging Face Hub]"
    else
      _zdx_doctor_warn \
        "huggingface_hub - MISSING OR INCOMPATIBLE (requires 0.23+ and below 2.0) [Hugging Face Hub]"
      _zdx_doctor_dim \
        "Install it for HF_PYTHON, python3, or python; ZDX Doctor does not install Python packages."
      _zdx_doctor_info \
        "  ➜ Official Link: https://huggingface.co/docs/huggingface_hub/installation"
      (( issues_count++ ))
      (( capability_issues_count++ ))
    fi
  else
    _zdx_doctor_warn \
      "huggingface_hub - NOT PROBED (timeout/gtimeout is unavailable) [Hugging Face Hub]"
    _zdx_doctor_dim \
      "The installed Python backend was not executed without the required deadline."
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
