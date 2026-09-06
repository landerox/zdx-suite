#!/usr/bin/env zsh
# =============================================================================
# System Capabilities: lazy host detection and capability predicates
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh and before platform adapters.
# Safe to re-source; defines private detection functions and the empty lazy
# registry state only.
#

if [[ -n "${_SYS_CAPABILITIES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gA _SYS_CAPABILITIES=()
typeset -gi _SYS_CAPABILITIES_READY=0

_sys_detect_os() {
  local kernel_name
  kernel_name=$(
    _sys_run_bounded_probe 3 65536 uname -s 2>/dev/null
  ) || {
    print -r -- "unknown"
    return 0
  }

  case "${kernel_name:l}" in
    linux)  print -r -- "linux" ;;
    darwin) print -r -- "darwin" ;;
    *)      print -r -- "unknown" ;;
  esac
}

_sys_detect_architecture() {
  local architecture
  architecture=$(
    _sys_run_bounded_probe 3 65536 uname -m 2>/dev/null
  ) || architecture=""
  architecture="${architecture:l}"
  print -r -- "${architecture:-unknown}"
}

_sys_capabilities_refresh() {
  local os_name environment_name architecture
  local package_manager os_updates_backend
  local service_manager process_backend ports_backend
  local privilege_backend fonts_backend snapd_state wsl_interop_state

  os_name=$(_sys_detect_os)
  architecture=$(_sys_detect_architecture)
  environment_name="native"
  package_manager="unavailable"
  os_updates_backend="unavailable"
  service_manager="unavailable"
  process_backend="unavailable"
  ports_backend="unavailable"
  fonts_backend="unavailable"
  snapd_state="unavailable"
  wsl_interop_state="unavailable"

  case "$os_name" in
    linux)
      if typeset -f _sys_wsl_detect &>/dev/null && _sys_wsl_detect; then
        environment_name="wsl"
        package_manager=$(_sys_wsl_package_manager)
        service_manager=$(_sys_wsl_service_manager)
        process_backend=$(_sys_wsl_process_backend)
        ports_backend=$(_sys_wsl_ports_backend)
        fonts_backend=$(_sys_wsl_fonts_backend)
        _sys_wsl_snapd_available && snapd_state="available"
        _sys_wsl_interop_available && wsl_interop_state="available"
      else
        package_manager=$(_sys_linux_package_manager)
        service_manager=$(_sys_linux_service_manager)
        process_backend=$(_sys_linux_process_backend)
        ports_backend=$(_sys_linux_ports_backend)
        fonts_backend=$(_sys_linux_fonts_backend)
        _sys_linux_snapd_available && snapd_state="available"
      fi
      ;;
    darwin)
      package_manager=$(_sys_macos_package_manager)
      os_updates_backend=$(_sys_macos_os_updates_backend)
      service_manager=$(_sys_macos_service_manager)
      process_backend=$(_sys_macos_process_backend)
      ports_backend=$(_sys_macos_ports_backend)
      fonts_backend=$(_sys_macos_fonts_backend)
      ;;
  esac

  if (( EUID == 0 )); then
    privilege_backend="direct"
  elif command -v sudo &>/dev/null; then
    privilege_backend="sudo"
  else
    privilege_backend="unavailable"
  fi

  _SYS_CAPABILITIES=(
    architecture "$architecture"
    environment "$environment_name"
    fonts_backend "${fonts_backend:-unavailable}"
    os "$os_name"
    os_updates_backend "${os_updates_backend:-unavailable}"
    package_manager "${package_manager:-unavailable}"
    ports_backend "${ports_backend:-unavailable}"
    privilege "$privilege_backend"
    process_backend "${process_backend:-unavailable}"
    service_manager "${service_manager:-unavailable}"
    snapd "$snapd_state"
    wsl_interop "$wsl_interop_state"
  )
  _SYS_CAPABILITIES_READY=1
}

_sys_capabilities_ensure() {
  if (( ${_SYS_DISPATCH_CAPABILITIES_PENDING:-0} \
    && ! ${_SYS_DISPATCH_CAPABILITIES_FRESH:-0} )); then
    _sys_capabilities_refresh || return 1
    _SYS_DISPATCH_CAPABILITIES_FRESH=1
    _SYS_DISPATCH_CAPABILITIES_PENDING=0
    return 0
  fi
  (( _SYS_CAPABILITIES_READY )) || _sys_capabilities_refresh
}

_sys_capabilities_refresh_for_command() {
  (( ${_SYS_DISPATCH_CAPABILITIES_FRESH:-0} )) && return 0
  _sys_capabilities_refresh || return 1
  if (( ${_SYS_DISPATCH_CAPABILITIES_PENDING:-0} )); then
    _SYS_DISPATCH_CAPABILITIES_FRESH=1
    _SYS_DISPATCH_CAPABILITIES_PENDING=0
  fi
  return 0
}

_sys_capability_value() {
  local capability_name="$1"

  case "$capability_name" in
    architecture|environment|fonts_backend|os|os_updates_backend|package_manager|ports_backend|privilege|process_backend|service_manager|snapd|wsl_interop) ;;
    *) return 2 ;;
  esac

  _sys_capabilities_ensure || return 1
  print -r -- "${_SYS_CAPABILITIES[$capability_name]}"
}

_sys_has_capability() {
  local predicate="$1"
  local capability_name expected_value

  case "$predicate" in
    os:linux|os:darwin)
      capability_name="os"
      expected_value="${predicate#*:}"
      ;;
    environment:native|environment:wsl)
      capability_name="environment"
      expected_value="${predicate#*:}"
      ;;
    package:apt|package:dnf|package:pacman|package:zypper|package:apk|package:brew|package:softwareupdate|package:unavailable)
      capability_name="package_manager"
      expected_value="${predicate#*:}"
      ;;
    os-updates:softwareupdate|os-updates:unavailable)
      capability_name="os_updates_backend"
      expected_value="${predicate#*:}"
      ;;
    service:systemd|service:launchd|service:unavailable)
      capability_name="service_manager"
      expected_value="${predicate#*:}"
      ;;
    process:procps|process:bsd-ps|process:unavailable)
      capability_name="process_backend"
      expected_value="${predicate#*:}"
      ;;
    ports:lsof|ports:ss|ports:unavailable)
      capability_name="ports_backend"
      expected_value="${predicate#*:}"
      ;;
    privilege:direct|privilege:sudo|privilege:unavailable)
      capability_name="privilege"
      expected_value="${predicate#*:}"
      ;;
    fonts:fontconfig|fonts:macos-user-fonts|fonts:unavailable)
      capability_name="fonts_backend"
      expected_value="${predicate#*:}"
      ;;
    runtime:snapd)
      capability_name="snapd"
      expected_value="available"
      ;;
    runtime:wsl-interop)
      capability_name="wsl_interop"
      expected_value="available"
      ;;
    *) return 2 ;;
  esac

  _sys_capabilities_ensure || return 1
  [[ "${_SYS_CAPABILITIES[$capability_name]}" == "$expected_value" ]]
}

_sys_capabilities_print() {
  local capability_name
  local -a capability_names=(
    architecture
    environment
    fonts_backend
    os
    os_updates_backend
    package_manager
    ports_backend
    privilege
    process_backend
    service_manager
    snapd
    wsl_interop
  )

  _sys_capabilities_ensure || return 1
  for capability_name in "${capability_names[@]}"; do
    print -r -- \
      "${capability_name}=${_SYS_CAPABILITIES[$capability_name]}"
  done
}

_sys_has_systemd() {
  _sys_has_capability "service:systemd"
}

_sys_snap_ready() {
  _sys_has_capability "runtime:snapd"
}

typeset -g _SYS_CAPABILITIES_SOURCED=1
