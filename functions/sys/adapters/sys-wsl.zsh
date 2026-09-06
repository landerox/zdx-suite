#!/usr/bin/env zsh
# =============================================================================
# System WSL Adapter: Linux capabilities with Windows interop detection
# =============================================================================
#
# Loaded by sys-menu.zsh after the native Linux adapter.
# Safe to re-source; defines private read-only probes only.
#

if [[ -n "${_SYS_WSL_ADAPTER_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_sys_wsl_detect() {
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]] && return 0
  [[ -r /proc/version ]] && command grep -qi microsoft /proc/version
}

_sys_wsl_package_manager() {
  _sys_linux_package_manager
}

_sys_wsl_service_manager() {
  _sys_linux_service_manager
}

_sys_wsl_process_backend() {
  _sys_linux_process_backend
}

_sys_wsl_ports_backend() {
  _sys_linux_ports_backend
}

_sys_wsl_fonts_backend() {
  _sys_linux_fonts_backend
}

_sys_wsl_snapd_available() {
  _sys_linux_snapd_available
}

_sys_wsl_interop_available() {
  [[ -n "${WSL_INTEROP:-}" ]] \
    || [[ -e /proc/sys/fs/binfmt_misc/WSLInterop ]] \
    || command -v cmd.exe &>/dev/null
}

_sys_wsl_diag_os_name() {
  _sys_linux_diag_os_name
}

_sys_wsl_diag_memory_record() {
  _sys_linux_diag_memory_record
}

_sys_wsl_diag_cpu_record() {
  _sys_linux_diag_cpu_record
}

_sys_wsl_diag_runtime_record() {
  _sys_linux_diag_runtime_record
}

_sys_wsl_diag_package_records() {
  _sys_linux_diag_package_records "$@"
}

_sys_wsl_diag_zombie_records() {
  _sys_linux_diag_zombie_records
}

_sys_wsl_diag_failed_service_records() {
  _sys_linux_diag_failed_service_records
}

_sys_wsl_diag_oom_event_count() {
  _sys_linux_diag_oom_event_count
}

_sys_wsl_diag_journal_size() {
  _sys_linux_diag_journal_size
}

_sys_wsl_diag_pending_reboot() {
  _sys_linux_diag_pending_reboot
}

# stdout: WSL1 or WSL2.
_sys_wsl_diag_release() {
  local kernel_release
  kernel_release=$(
    _sys_run_bounded_probe 3 65536 uname -r 2>/dev/null
  ) || kernel_release=""
  if [[ "${kernel_release:l}" == *"wsl2"* \
    || "${kernel_release:l}" == *"microsoft-standard"* ]]; then
    print -r -- "WSL2"
  else
    print -r -- "WSL1"
  fi
}

# stdout: Windows version when interop is available.
_sys_wsl_diag_windows_version() {
  _sys_wsl_interop_available || return 3

  local version_output
  version_output=$(
    _sys_run_bounded_probe 5 65536 cmd.exe /c ver 2>/dev/null
  ) \
    || return 1
  version_output="${version_output//$'\r'/}"
  if [[ "$version_output" =~ '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)' ]]; then
    print -r -- "${match[1]}"
    return 0
  fi
  return 1
}

typeset -g _SYS_WSL_ADAPTER_SOURCED=1
