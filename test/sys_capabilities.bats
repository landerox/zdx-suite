#!/usr/bin/env bats

setup() {
  load test_helper
}

teardown() {
  cleanup_sandbox
}

@test "sys capabilities: standalone loader is silent and core-independent" {
  run env HOME="$HOME" PATH="$PATH" zsh -f -c '
    source "$1/functions/sys-menu.zsh" || return 1
    source "$1/functions/sys-menu.zsh" || return 1

    typeset -f _timed &>/dev/null && return 2
    typeset -f _tk_fzf_color_opts &>/dev/null && return 3
    typeset -f sys-menu &>/dev/null || return 4

    print -r -- \
      "${_SYS_MENU_SOURCED}:${_SYS_COMMON_SOURCED}:${_SYS_CAPABILITIES_SOURCED}"
  ' zsh "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = "1:1:1" ]
}

@test "sys capabilities: standalone timing fallback preserves command status" {
  run env HOME="$HOME" PATH="$PATH" zsh -f -c '
    source "$1/functions/sys-menu.zsh" || return 1
    _sys_dispatch() { return 7; }
    sys-menu sys-info
  ' zsh "$TEST_SUITE_ROOT"

  [ "$status" -eq 7 ]
  [ -z "$output" ]
}

@test "sys capabilities: loader failure preserves status and clears temporary state" {
  local partial_root="$TEST_TEMP_DIR/partial/functions"
  mkdir -p "$partial_root/sys"
  cp "$TEST_SUITE_ROOT/functions/sys-menu.zsh" "$partial_root/sys-menu.zsh"
  cp "$TEST_SUITE_ROOT/functions/sys-common.zsh" "$partial_root/sys-common.zsh"
  printf '%s\n' 'return 23 2>/dev/null || exit 23' \
    > "$partial_root/sys/sys-capabilities.zsh"

  run env HOME="$HOME" PATH="$PATH" zsh -f -c '
    source "$1/sys-menu.zsh"
    load_rc=$?

    [[ -z "${_SYS_MENU_SOURCED:-}" ]] || return 1
    typeset -f _sys_menu_source_module &>/dev/null && return 2
    [[ -z "${_sys_menu_loader_dir:-}" ]] || return 3
    [[ -z "${_sys_menu_load_rc:-}" ]] || return 4
    print -r -- "load-rc=$load_rc"
  ' zsh "$partial_root"

  [ "$status" -eq 0 ]
  [[ "$output" == *"failed to load sys-capabilities.zsh"* ]]
  [[ "$output" == *"load-rc=23"* ]]
}

@test "sys capabilities: detection remains lazy until first access" {
  run env HOME="$HOME" PATH="$PATH" zsh -f -c '
    source "$1/functions/sys-menu.zsh" || return 1
    print -r -- "$_SYS_CAPABILITIES_READY"
    _sys_capability_value os >/dev/null || return 2
    print -r -- "$_SYS_CAPABILITIES_READY"
  ' zsh "$TEST_SUITE_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = $'0\n1' ]
}

@test "sys capabilities: dispatched commands reuse one fresh snapshot" {
  run run_zsh '
    local -i refresh_count=0
    _sys_capabilities_refresh() {
      (( refresh_count++ ))
      _SYS_CAPABILITIES_READY=1
      return 0
    }
    sys-info() {
      _sys_capabilities_refresh_for_command
    }

    _sys_dispatch sys-info || return 1
    print -r -- "$refresh_count"
    sys-info || return 2
    print -r -- "$refresh_count"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'1\n2' ]
}

@test "sys capabilities: native Linux selects independent backends" {
  run run_zsh '
    _sys_detect_os() { print -r -- "linux"; }
    _sys_detect_architecture() { print -r -- "x86_64"; }
    _sys_wsl_detect() { return 1; }
    _sys_linux_package_manager() { print -r -- "apt"; }
    _sys_linux_service_manager() { print -r -- "systemd"; }
    _sys_linux_process_backend() { print -r -- "procps"; }
    _sys_linux_ports_backend() { print -r -- "lsof"; }
    _sys_linux_fonts_backend() { print -r -- "fontconfig"; }
    _sys_linux_snapd_available() { return 0; }

    _sys_capabilities_refresh || return 1
    print -r -- \
      "$(_sys_capability_value os)|$(_sys_capability_value environment)|$(_sys_capability_value architecture)"
    print -r -- \
      "$(_sys_capability_value package_manager)|$(_sys_capability_value service_manager)|$(_sys_capability_value process_backend)"
    print -r -- \
      "$(_sys_capability_value ports_backend)|$(_sys_capability_value fonts_backend)|$(_sys_capability_value snapd)"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'linux|native|x86_64\napt|systemd|procps\nlsof|fontconfig|available' ]
}

@test "sys capabilities: WSL overlays Linux and probes interop separately" {
  run run_zsh '
    _sys_detect_os() { print -r -- "linux"; }
    _sys_detect_architecture() { print -r -- "aarch64"; }
    _sys_wsl_detect() { return 0; }
    _sys_wsl_package_manager() { print -r -- "apt"; }
    _sys_wsl_service_manager() { print -r -- "unavailable"; }
    _sys_wsl_process_backend() { print -r -- "procps"; }
    _sys_wsl_ports_backend() { print -r -- "ss"; }
    _sys_wsl_fonts_backend() { print -r -- "fontconfig"; }
    _sys_wsl_snapd_available() { return 1; }
    _sys_wsl_interop_available() { return 0; }

    _sys_capabilities_refresh || return 1
    print -r -- \
      "$(_sys_capability_value os)|$(_sys_capability_value environment)|$(_sys_capability_value architecture)"
    print -r -- \
      "$(_sys_capability_value package_manager)|$(_sys_capability_value service_manager)|$(_sys_capability_value ports_backend)"
    print -r -- \
      "$(_sys_capability_value snapd)|$(_sys_capability_value wsl_interop)"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'linux|wsl|aarch64\napt|unavailable|ss\nunavailable|available' ]
}

@test "sys capabilities: Darwin selects macOS adapters" {
  run run_zsh '
    _sys_detect_os() { print -r -- "darwin"; }
    _sys_detect_architecture() { print -r -- "arm64"; }
    _sys_macos_package_manager() { print -r -- "brew"; }
    _sys_macos_os_updates_backend() { print -r -- "softwareupdate"; }
    _sys_macos_service_manager() { print -r -- "launchd"; }
    _sys_macos_process_backend() { print -r -- "bsd-ps"; }
    _sys_macos_ports_backend() { print -r -- "lsof"; }
    _sys_macos_fonts_backend() { print -r -- "macos-user-fonts"; }

    _sys_capabilities_refresh || return 1
    print -r -- \
      "$(_sys_capability_value os)|$(_sys_capability_value environment)|$(_sys_capability_value architecture)"
    print -r -- \
      "$(_sys_capability_value package_manager)|$(_sys_capability_value service_manager)|$(_sys_capability_value process_backend)"
    print -r -- \
      "$(_sys_capability_value ports_backend)|$(_sys_capability_value fonts_backend)"
    print -r -- \
      "$(_sys_capability_value os_updates_backend)"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'darwin|native|arm64\nbrew|launchd|bsd-ps\nlsof|macos-user-fonts\nsoftwareupdate' ]
}

@test "sys capabilities: predicates distinguish absence from invalid input" {
  run run_zsh '
    _SYS_CAPABILITIES=(
      architecture x86_64
      environment wsl
      fonts_backend fontconfig
      os linux
      os_updates_backend unavailable
      package_manager apt
      ports_backend ss
      privilege sudo
      process_backend procps
      service_manager systemd
      snapd unavailable
      wsl_interop available
    )
    _SYS_CAPABILITIES_READY=1

    _sys_has_capability "os:linux" || return 1
    _sys_has_capability "environment:wsl" || return 2
    _sys_has_capability "package:apt" || return 3
    _sys_has_capability "service:systemd" || return 4
    _sys_has_capability "process:procps" || return 5
    _sys_has_capability "ports:ss" || return 6
    _sys_has_capability "privilege:sudo" || return 7
    _sys_has_capability "fonts:fontconfig" || return 8
    _sys_has_capability "runtime:wsl-interop" || return 9
    _sys_has_capability "os-updates:unavailable" || return 10

    _sys_has_capability "runtime:snapd" && return 11
    [[ $? -eq 1 ]] || return 12
    _sys_has_capability "kernel:linux"
    [[ $? -eq 2 ]] || return 13
  '

  [ "$status" -eq 0 ]
}

@test "sys capabilities: refresh replaces stale probe results" {
  run run_zsh '
    typeset manager="apt"
    _sys_detect_os() { print -r -- "linux"; }
    _sys_wsl_detect() { return 1; }
    _sys_linux_package_manager() { print -r -- "$manager"; }
    _sys_linux_service_manager() { print -r -- "unavailable"; }
    _sys_linux_process_backend() { print -r -- "procps"; }
    _sys_linux_ports_backend() { print -r -- "unavailable"; }
    _sys_linux_fonts_backend() { print -r -- "unavailable"; }
    _sys_linux_snapd_available() { return 1; }

    _sys_capabilities_refresh || return 1
    print -r -- "$(_sys_capability_value package_manager)"
    manager="dnf"
    _sys_capabilities_refresh || return 2
    print -r -- "$(_sys_capability_value package_manager)"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'apt\ndnf' ]
}

@test "sys capabilities: legacy systemd and snap helpers use the registry" {
  run run_zsh '
    _SYS_CAPABILITIES=(
      service_manager systemd
      snapd available
    )
    _SYS_CAPABILITIES_READY=1

    _sys_has_systemd || return 1
    _sys_snap_ready || return 2

    _SYS_CAPABILITIES[service_manager]="unavailable"
    _SYS_CAPABILITIES[snapd]="unavailable"
    _sys_has_systemd && return 3
    _sys_snap_ready && return 4
    return 0
  '

  [ "$status" -eq 0 ]
}

@test "sys capabilities: printable registry has stable data-only ordering" {
  run run_zsh '
    _SYS_CAPABILITIES=(
      architecture arm64
      environment native
      fonts_backend macos-user-fonts
      os darwin
      os_updates_backend softwareupdate
      package_manager brew
      ports_backend lsof
      privilege sudo
      process_backend bsd-ps
      service_manager launchd
      snapd unavailable
      wsl_interop unavailable
    )
    _SYS_CAPABILITIES_READY=1
    _sys_capabilities_print
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'architecture=arm64\nenvironment=native\nfonts_backend=macos-user-fonts\nos=darwin\nos_updates_backend=softwareupdate\npackage_manager=brew\nports_backend=lsof\nprivilege=sudo\nprocess_backend=bsd-ps\nservice_manager=launchd\nsnapd=unavailable\nwsl_interop=unavailable' ]
}
