#!/usr/bin/env zsh
# =============================================================================
# System Diagnostics: portable read-only host information and health
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, sys-capabilities.zsh, and the
# platform adapters.
# Safe to re-source; defines functions and read-only constants only.
#

if [[ -n "${_SYS_DIAG_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Platform data routing --------------------------------------------------

_sys_diag_os_name() {
  local os_name environment_name
  os_name=$(_sys_capability_value os) || return 1
  environment_name=$(_sys_capability_value environment) || return 1

  case "$os_name:$environment_name" in
    linux:wsl)    _sys_wsl_diag_os_name ;;
    linux:native) _sys_linux_diag_os_name ;;
    darwin:*)     _sys_macos_diag_os_name ;;
    *)            print -r -- "Unknown" ;;
  esac
}

_sys_diag_memory_record() {
  local os_name environment_name
  os_name=$(_sys_capability_value os) || return 1
  environment_name=$(_sys_capability_value environment) || return 1

  case "$os_name:$environment_name" in
    linux:wsl)    _sys_wsl_diag_memory_record ;;
    linux:native) _sys_linux_diag_memory_record ;;
    darwin:*)     _sys_macos_diag_memory_record ;;
    *)            return 3 ;;
  esac
}

_sys_diag_cpu_record() {
  local os_name environment_name
  os_name=$(_sys_capability_value os) || return 1
  environment_name=$(_sys_capability_value environment) || return 1

  case "$os_name:$environment_name" in
    linux:wsl)    _sys_wsl_diag_cpu_record ;;
    linux:native) _sys_linux_diag_cpu_record ;;
    darwin:*)     _sys_macos_diag_cpu_record ;;
    *)            return 3 ;;
  esac
}

_sys_diag_runtime_record() {
  local os_name environment_name
  os_name=$(_sys_capability_value os) || return 1
  environment_name=$(_sys_capability_value environment) || return 1

  case "$os_name:$environment_name" in
    linux:wsl)    _sys_wsl_diag_runtime_record ;;
    linux:native) _sys_linux_diag_runtime_record ;;
    darwin:*)     _sys_macos_diag_runtime_record ;;
    *)            return 3 ;;
  esac
}

_sys_diag_package_records() {
  local os_name environment_name package_manager
  os_name=$(_sys_capability_value os) || return 1
  environment_name=$(_sys_capability_value environment) || return 1
  package_manager=$(_sys_capability_value package_manager) || return 1

  case "$os_name:$environment_name" in
    linux:wsl)    _sys_wsl_diag_package_records "$package_manager" ;;
    linux:native) _sys_linux_diag_package_records "$package_manager" ;;
    darwin:*)     _sys_macos_diag_package_records "$package_manager" ;;
    *)            return 3 ;;
  esac
}

_sys_diag_zombie_records() {
  local process_backend
  process_backend=$(_sys_capability_value process_backend) || return 1

  case "$process_backend" in
    procps) _sys_linux_diag_zombie_records ;;
    bsd-ps) _sys_macos_diag_zombie_records ;;
    *)      return 3 ;;
  esac
}

_sys_diag_failed_service_records() {
  local service_manager environment_name
  service_manager=$(_sys_capability_value service_manager) || return 1
  environment_name=$(_sys_capability_value environment) || return 1

  case "$service_manager:$environment_name" in
    systemd:wsl)    _sys_wsl_diag_failed_service_records ;;
    systemd:native) _sys_linux_diag_failed_service_records ;;
    launchd:*)      _sys_macos_diag_failed_service_records ;;
    *)              return 3 ;;
  esac
}

_sys_diag_oom_event_count() {
  local os_name environment_name
  os_name=$(_sys_capability_value os) || return 1
  environment_name=$(_sys_capability_value environment) || return 1

  case "$os_name:$environment_name" in
    linux:wsl)    _sys_wsl_diag_oom_event_count ;;
    linux:native) _sys_linux_diag_oom_event_count ;;
    darwin:*)     _sys_macos_diag_oom_event_count ;;
    *)            return 3 ;;
  esac
}

_sys_diag_journal_size() {
  local service_manager environment_name
  service_manager=$(_sys_capability_value service_manager) || return 1
  environment_name=$(_sys_capability_value environment) || return 1

  case "$service_manager:$environment_name" in
    systemd:wsl)    _sys_wsl_diag_journal_size ;;
    systemd:native) _sys_linux_diag_journal_size ;;
    launchd:*)      _sys_macos_diag_journal_size ;;
    *)              return 3 ;;
  esac
}

_sys_diag_pending_reboot() {
  local os_name environment_name
  os_name=$(_sys_capability_value os) || return 1
  environment_name=$(_sys_capability_value environment) || return 1

  case "$os_name:$environment_name" in
    linux:wsl)    _sys_wsl_diag_pending_reboot ;;
    linux:native) _sys_linux_diag_pending_reboot ;;
    darwin:*)     _sys_macos_diag_pending_reboot ;;
    *)            return 3 ;;
  esac
}

# --- Portable collectors and formatters ------------------------------------

typeset -gr _SYS_DIAG_MAX_KIB_FOR_BYTES=9007199254740991
typeset -gr _SYS_DIAG_PROBE_MAX_BYTES=1048576

_sys_diag_usage_percent() {
  local total_value="${1:-}"
  local free_value="${2:-}"
  local REPLY
  _sys_normalize_uint "$total_value" || return 2
  total_value="$REPLY"
  _sys_normalize_uint "$free_value" || return 2
  free_value="$REPLY"
  (( total_value > 0 && free_value <= total_value )) || return 2

  local -F used_percent
  used_percent=$(( (total_value - free_value) * 100.0 / total_value ))
  printf '%.0f\n' "$used_percent"
}

# stdout TSV: filesystem, total-KiB, used-KiB, available-KiB, used-percent.
_sys_diag_disk_record() {
  local target_path="$1"
  local disk_output
  disk_output=$(
    _sys_run_bounded_probe 5 65536 df -Pk "$target_path" 2>/dev/null
  ) || return $?
  print -r -- "$disk_output" | command awk '
    NR == 2 {
      percent = $(NF - 1)
      gsub(/%/, "", percent)
      printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, percent
      exit
    }
  '
}

# stdout: inode usage percentage without the percent sign.
_sys_diag_inode_percent() {
  local target_path="$1"
  local inode_output
  inode_output=$(
    _sys_run_bounded_probe 5 65536 df -Pki "$target_path" 2>/dev/null
  ) || return $?
  print -r -- "$inode_output" | command awk '
    NR == 2 {
      percent = $(NF - 1)
      gsub(/%/, "", percent)
      if (percent ~ /^[0-9]+$/) print percent
      exit
    }
  '
}

_sys_diag_format_bytes() {
  local byte_count="${1:-0}"
  local REPLY
  _sys_normalize_uint "$byte_count" || {
    print -r -- "unknown"
    return 2
  }
  byte_count="$REPLY"

  if (( byte_count >= 1099511627776 )); then
    printf '%.1f TiB' $(( byte_count / 1099511627776.0 ))
  elif (( byte_count >= 1073741824 )); then
    printf '%.1f GiB' $(( byte_count / 1073741824.0 ))
  elif (( byte_count >= 1048576 )); then
    printf '%.1f MiB' $(( byte_count / 1048576.0 ))
  elif (( byte_count >= 1024 )); then
    printf '%.1f KiB' $(( byte_count / 1024.0 ))
  else
    printf '%d B' "$byte_count"
  fi
}

_sys_diag_format_uptime() {
  local uptime_seconds="${1:-0}"
  local REPLY
  _sys_normalize_uint "$uptime_seconds" || {
    print -r -- "unknown"
    return 2
  }
  uptime_seconds="$REPLY"

  local -i days=$(( uptime_seconds / 86400 ))
  local -i hours=$(( (uptime_seconds % 86400) / 3600 ))
  local -i minutes=$(( (uptime_seconds % 3600) / 60 ))

  if (( days > 0 )); then
    printf '%dd %dh %dm' "$days" "$hours" "$minutes"
  elif (( hours > 0 )); then
    printf '%dh %dm' "$hours" "$minutes"
  else
    printf '%dm' "$minutes"
  fi
}

_sys_diag_tool_version() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local tool_name="$1"

  case "$tool_name" in
    git)       _sys_run_bounded_probe 3 65536 git --version 2>/dev/null | command awk '{ print $3 }' ;;
    python3)   _sys_run_bounded_probe 3 65536 python3 --version 2>/dev/null | command awk '{ print $2 }' ;;
    uv)        _sys_run_bounded_probe 3 65536 uv --version 2>/dev/null | command awk '{ print $2 }' ;;
    node)      _sys_run_bounded_probe 3 65536 node --version 2>/dev/null ;;
    rustc)     _sys_run_bounded_probe 3 65536 rustc --version 2>/dev/null | command awk '{ print $2 }' ;;
    go)        _sys_run_bounded_probe 3 65536 go version 2>/dev/null | command awk '{ sub(/^go/, "", $3); print $3 }' ;;
    docker)    _sys_run_bounded_probe 3 65536 docker --version 2>/dev/null | command awk '{ gsub(/,/, "", $3); print $3 }' ;;
    gcloud)    _sys_run_bounded_probe 3 65536 gcloud --version 2>/dev/null | command awk 'NR == 1 { print $NF }' ;;
    terraform) _sys_run_bounded_probe 3 65536 terraform --version 2>/dev/null | command awk 'NR == 1 { print $NF }' ;;
    kubectl)
      _sys_run_bounded_probe 3 65536 \
        kubectl version --client -o json 2>/dev/null \
        | command sed -n 's/.*"gitVersion":[[:space:]]*"\([^"]*\)".*/\1/p'
      ;;
    helm)      _sys_run_bounded_probe 3 65536 helm version --short 2>/dev/null | command sed 's/^v//' ;;
    starship)  _sys_run_bounded_probe 3 65536 starship --version 2>/dev/null | command awk 'NR == 1 { print $NF }' ;;
    *)         return 2 ;;
  esac
}

_sys_diag_render_tool() {
  local display_name="$1" tool_name="$2"
  command -v "$tool_name" &>/dev/null || return 0

  local version_value
  version_value=$(_sys_diag_tool_version "$tool_name") || return 0
  [[ -n "$version_value" ]] || return 0
  version_value=$(_sys_display_escape "$version_value")
  _sys_label "$display_name:" "$version_value"
}

_sys_diag_render_disk() {
  local display_name="$1" target_path="$2"
  local disk_record filesystem total_kib used_kib available_kib used_percent
  disk_record=$(_sys_diag_disk_record "$target_path") || {
    _sys_label "$display_name:" "unavailable"
    return 0
  }
  IFS=$'\t' read -r \
    filesystem total_kib used_kib available_kib used_percent <<< "$disk_record"

  local REPLY
  if _sys_normalize_uint \
      "$total_kib" "$_SYS_DIAG_MAX_KIB_FOR_BYTES"; then
    total_kib="$REPLY"
    _sys_normalize_uint \
      "$used_kib" "$_SYS_DIAG_MAX_KIB_FOR_BYTES" || {
      _sys_label "$display_name:" "unavailable"
      return 0
    }
    used_kib="$REPLY"
    _sys_normalize_uint "$used_percent" 1000 || {
      _sys_label "$display_name:" "unavailable"
      return 0
    }
    used_percent="$REPLY"
    (( used_kib <= total_kib )) || {
      _sys_label "$display_name:" "unavailable"
      return 0
    }
    _sys_label "$display_name:" \
      "$(_sys_diag_format_bytes $(( used_kib * 1024 ))) used of $(_sys_diag_format_bytes $(( total_kib * 1024 ))) (${used_percent}%)"
  else
    _sys_label "$display_name:" "unavailable"
  fi
}

_sys_diag_render_package_records() {
  local package_output collection_rc
  package_output=$(_sys_diag_package_records)
  collection_rc=$?
  if (( collection_rc == 0 )); then
    local package_line package_label package_count
    local -a package_lines=()
    [[ -n "$package_output" ]] && package_lines=("${(@f)package_output}")
    for package_line in "${package_lines[@]}"; do
      IFS=$'\t' read -r package_label package_count <<< "$package_line"
      [[ "$package_count" =~ '^[0-9]+$' ]] || continue
      package_label=$(_sys_display_escape "$package_label")
      _sys_label "$package_label:" "$package_count"
    done
  fi

  if command -v npm &>/dev/null; then
    local npm_output
    local -a npm_lines=()
    npm_output=$(
      _sys_run_bounded_probe 5 "$_SYS_DIAG_PROBE_MAX_BYTES" \
        npm list -g --depth=0 2>/dev/null
    ) \
      || npm_output=""
    [[ -n "$npm_output" ]] && npm_lines=("${(@f)npm_output}")
    (( ${#npm_lines} > 0 )) && npm_lines=("${npm_lines[@]:1}")
    _sys_label "NPM global:" "${#npm_lines}"
  fi

  if command -v pipx &>/dev/null; then
    local pipx_output
    local -a pipx_lines=()
    pipx_output=$(
      _sys_run_bounded_probe 5 "$_SYS_DIAG_PROBE_MAX_BYTES" \
        pipx list --short 2>/dev/null
    ) \
      || pipx_output=""
    [[ -n "$pipx_output" ]] && pipx_lines=("${(@f)pipx_output}")
    _sys_label "pipx packages:" "${#pipx_lines}"
  fi
}

# --- System information -----------------------------------------------------

_sys_info_usage() {
  print -u2 -r -- 'Usage: sys-info [-h|--help]'
  print -u2 -r -- 'Display read-only host, runtime, tool, and package information.'
}

sys-info() {
  case "${1:-}" in
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_info_usage
      return 0
      ;;
    "") ;;
    *)
      _sys_error "Unknown option: $1"
      return 2
      ;;
  esac
  (( $# <= 1 )) || {
    _sys_error "sys-info accepts no positional arguments."
    return 2
  }

  _sys_capabilities_refresh_for_command || {
    _sys_error "Unable to detect host capabilities."
    return 1
  }

  _sys_header "System Information"

  local os_display kernel_release architecture environment_name
  os_display=$(_sys_diag_os_name) || os_display="Unknown"
  kernel_release=$(
    _sys_run_bounded_probe 3 65536 uname -r 2>/dev/null
  ) || kernel_release="Unknown"
  architecture=$(_sys_capability_value architecture) || architecture="unknown"
  environment_name=$(_sys_capability_value environment) || environment_name="native"

  _sys_label "OS:" "$(_sys_display_escape "$os_display")"
  _sys_label "Kernel:" "$(_sys_display_escape "$kernel_release")"
  _sys_label "Architecture:" "$(_sys_display_escape "$architecture")"
  _sys_label "Environment:" "${environment_name:u}"

  if [[ "$environment_name" == "wsl" ]]; then
    local wsl_release windows_version
    wsl_release=$(_sys_wsl_diag_release 2>/dev/null) || wsl_release="WSL"
    _sys_label "WSL:" "$wsl_release"
    windows_version=$(_sys_wsl_diag_windows_version 2>/dev/null) \
      || windows_version=""
    [[ -n "$windows_version" ]] \
      && _sys_label "Windows:" "$(_sys_display_escape "$windows_version")"
  fi

  local memory_record total_bytes available_bytes swap_total_bytes swap_free_bytes
  memory_record=$(_sys_diag_memory_record 2>/dev/null) || memory_record=""
  IFS=$'\t' read -r total_bytes available_bytes \
    swap_total_bytes swap_free_bytes <<< "$memory_record"
  if [[ "$total_bytes" =~ '^[0-9]+$' \
    && "$available_bytes" =~ '^[0-9]+$' ]]; then
    _sys_label "Memory:" \
      "$(_sys_diag_format_bytes "$total_bytes") total, $(_sys_diag_format_bytes "$available_bytes") available"
  else
    _sys_label "Memory:" "unavailable"
  fi
  if [[ "$swap_total_bytes" =~ '^[0-9]+$' \
    && "$swap_free_bytes" =~ '^[0-9]+$' ]]; then
    _sys_label "Swap:" \
      "$(_sys_diag_format_bytes "$swap_total_bytes") total, $(_sys_diag_format_bytes "$swap_free_bytes") free"
  else
    _sys_label "Swap:" "unavailable"
  fi

  local cpu_record core_count cpu_model
  cpu_record=$(_sys_diag_cpu_record 2>/dev/null) || cpu_record=""
  IFS=$'\t' read -r core_count cpu_model <<< "$cpu_record"
  if [[ "$core_count" =~ '^[0-9]+$' ]]; then
    _sys_label "CPU:" \
      "$core_count logical cores — $(_sys_display_escape "${cpu_model:-Unknown}")"
  else
    _sys_label "CPU:" "unavailable"
  fi

  _sys_diag_render_disk "Disk (/)" "/"
  _sys_diag_render_disk "Disk (HOME)" "$HOME"

  local runtime_record uptime_seconds load_one load_five load_fifteen
  runtime_record=$(_sys_diag_runtime_record 2>/dev/null) || runtime_record=""
  IFS=$'\t' read -r uptime_seconds load_one load_five load_fifteen \
    <<< "$runtime_record"
  if [[ "$uptime_seconds" =~ '^[0-9]+$' ]]; then
    _sys_label "Uptime:" "$(_sys_diag_format_uptime "$uptime_seconds")"
  else
    _sys_label "Uptime:" "unavailable"
  fi
  if [[ -n "$load_one" && -n "$load_five" && -n "$load_fifteen" ]]; then
    _sys_label "Load:" \
      "$load_one $load_five $load_fifteen (1m 5m 15m)"
  else
    _sys_label "Load:" "unavailable"
  fi

  _sys_blank
  local zsh_version
  zsh_version=$(
    _sys_run_bounded_probe 3 65536 zsh --version 2>/dev/null
  ) || zsh_version="unknown"
  _sys_label "Shell:" \
    "$(_sys_display_escape "${SHELL:-zsh}") ($(_sys_display_escape "$zsh_version"))"
  if [[ -n "${ZSH:-}" && -d "$ZSH" ]]; then
    local omz_version
    omz_version=$(
      _sys_run_bounded_probe 3 65536 \
        git -C "$ZSH" describe --tags 2>/dev/null
    ) \
      || omz_version="installed"
    _sys_label "Oh My Zsh:" "$(_sys_display_escape "$omz_version")"
  fi
  _sys_diag_render_tool "Starship" starship

  _sys_blank
  _sys_diag_render_tool "Git" git
  _sys_diag_render_tool "Python" python3
  _sys_diag_render_tool "uv" uv
  _sys_diag_render_tool "Node.js" node
  _sys_diag_render_tool "Rust" rustc
  _sys_diag_render_tool "Go" go
  _sys_diag_render_tool "Docker" docker
  _sys_diag_render_tool "gcloud" gcloud
  _sys_diag_render_tool "Terraform" terraform
  _sys_diag_render_tool "kubectl" kubectl
  _sys_diag_render_tool "Helm" helm

  _sys_blank
  _sys_diag_render_package_records
  return 0
}

# --- System health ----------------------------------------------------------

_sys_health_usage() {
  print -u2 -r -- 'Usage: sys-health [-h|--help]'
  print -u2 -r -- 'Run portable read-only disk, memory, process, and service checks.'
}

_sys_diag_health_disk() {
  local display_name="$1" disk_record="$2"
  local filesystem total_kib used_kib available_kib used_percent
  IFS=$'\t' read -r \
    filesystem total_kib used_kib available_kib used_percent <<< "$disk_record"

  local REPLY
  _sys_normalize_uint "$used_percent" 1000 || {
    _sys_dim "$display_name disk usage unavailable"
    return 3
  }
  used_percent="$REPLY"

  if (( used_percent >= 90 )); then
    _sys_error "$display_name disk at ${used_percent}% — critically low"
    return 1
  elif (( used_percent >= 80 )); then
    _sys_warn "$display_name disk at ${used_percent}% — getting full"
    return 1
  fi

  _sys_success "$display_name disk at ${used_percent}%"
  return 0
}

sys-health() {
  case "${1:-}" in
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_health_usage
      return 0
      ;;
    "") ;;
    *)
      _sys_error "Unknown option: $1"
      return 2
      ;;
  esac
  (( $# <= 1 )) || {
    _sys_error "sys-health accepts no positional arguments."
    return 2
  }

  _sys_capabilities_refresh_for_command || {
    _sys_error "Unable to detect host capabilities."
    return 1
  }

  _sys_header "System Health Check"
  local -i issues=0
  local collection_rc

  _sys_info "Checking disk space..."
  local root_disk home_disk root_filesystem home_filesystem
  root_disk=$(_sys_diag_disk_record "/") || root_disk=""
  home_disk=$(_sys_diag_disk_record "$HOME") || home_disk=""
  root_filesystem="${root_disk%%$'\t'*}"
  home_filesystem="${home_disk%%$'\t'*}"

  _sys_diag_health_disk "Root" "$root_disk"
  collection_rc=$?
  (( collection_rc == 1 )) && (( issues++ ))
  if [[ -n "$home_filesystem" && "$home_filesystem" != "$root_filesystem" ]]; then
    _sys_diag_health_disk "Home" "$home_disk"
    collection_rc=$?
    (( collection_rc == 1 )) && (( issues++ ))
  fi

  _sys_info "Checking inode usage..."
  local inode_percent
  inode_percent=$(_sys_diag_inode_percent "/") || inode_percent=""
  local REPLY
  if _sys_normalize_uint "$inode_percent" 100; then
    inode_percent="$REPLY"
    if (( inode_percent >= 90 )); then
      _sys_error "Inodes at ${inode_percent}% — critically low"
      (( issues++ ))
    elif (( inode_percent >= 80 )); then
      _sys_warn "Inodes at ${inode_percent}%"
      (( issues++ ))
    else
      _sys_success "Inodes at ${inode_percent}%"
    fi
  else
    _sys_dim "Inode usage unavailable"
  fi

  _sys_info "Checking memory..."
  local memory_record total_bytes available_bytes swap_total_bytes swap_free_bytes
  memory_record=$(_sys_diag_memory_record 2>/dev/null) || memory_record=""
  IFS=$'\t' read -r total_bytes available_bytes \
    swap_total_bytes swap_free_bytes <<< "$memory_record"
  local memory_percent
  memory_percent=$(
    _sys_diag_usage_percent "$total_bytes" "$available_bytes"
  ) || memory_percent=""
  if [[ -n "$memory_percent" ]]; then
    if (( memory_percent >= 90 )); then
      _sys_error "Memory at ${memory_percent}% — critically high"
      (( issues++ ))
    elif (( memory_percent >= 80 )); then
      _sys_warn "Memory at ${memory_percent}%"
      (( issues++ ))
    else
      _sys_success "Memory at ${memory_percent}%"
    fi
  else
    _sys_dim "Memory usage unavailable"
  fi

  local swap_percent=""
  if [[ "$swap_total_bytes" == <-> && "$swap_total_bytes" != 0 ]]; then
    swap_percent=$(
      _sys_diag_usage_percent "$swap_total_bytes" "$swap_free_bytes"
    ) || swap_percent=""
  fi
  if [[ -n "$swap_percent" ]]; then
    if (( swap_percent >= 80 )); then
      _sys_warn "Swap at ${swap_percent}% — high usage"
      (( issues++ ))
    else
      _sys_success "Swap at ${swap_percent}%"
    fi
  elif [[ "$swap_total_bytes" == "0" ]]; then
    _sys_dim "No swap configured"
  else
    _sys_dim "Swap usage unavailable"
  fi

  _sys_info "Checking for zombie processes..."
  local zombie_output
  zombie_output=$(_sys_diag_zombie_records 2>/dev/null)
  collection_rc=$?
  if (( collection_rc == 0 )); then
    local -a zombie_lines=()
    [[ -n "$zombie_output" ]] && zombie_lines=("${(@f)zombie_output}")
    if (( ${#zombie_lines} == 0 )); then
      _sys_success "No zombie processes"
    else
      _sys_warn "${#zombie_lines} zombie process(es) found"
      local zombie_line zombie_pid zombie_command
      for zombie_line in "${zombie_lines[@]}"; do
        IFS=$'\t' read -r zombie_pid zombie_command <<< "$zombie_line"
        [[ "$zombie_pid" =~ '^[0-9]+$' ]] || continue
        _sys_dim "PID $zombie_pid: $(_sys_display_escape "$zombie_command")"
      done
      (( issues++ ))
    fi
  else
    _sys_dim "Zombie process check unavailable"
  fi

  local service_manager
  service_manager=$(_sys_capability_value service_manager) \
    || service_manager="unavailable"
  if [[ "$service_manager" == "unavailable" ]]; then
    _sys_dim "Service health backend unavailable"
    if _sys_has_capability "environment:wsl"; then
      _sys_dim "WSL systemd can be enabled through /etc/wsl.conf when supported."
    fi
  else
    _sys_info "Checking ${service_manager} services..."
    local failed_service_output
    failed_service_output=$(_sys_diag_failed_service_records 2>/dev/null)
    collection_rc=$?
    if (( collection_rc == 0 )); then
      local -a failed_service_lines=()
      [[ -n "$failed_service_output" ]] \
        && failed_service_lines=("${(@f)failed_service_output}")
      if (( ${#failed_service_lines} == 0 )); then
        _sys_success "No failed services"
      else
        _sys_warn "${#failed_service_lines} failed service(s)"
        local service_line service_name service_detail
        for service_line in "${failed_service_lines[@]}"; do
          IFS=$'\t' read -r service_name service_detail <<< "$service_line"
          _sys_dim "$(_sys_display_escape "$service_name"): $(_sys_display_escape "$service_detail")"
        done
        (( issues++ ))
      fi
    else
      _sys_dim "Service health query unavailable"
    fi
  fi

  _sys_info "Checking for recent OOM events..."
  local oom_count
  oom_count=$(_sys_diag_oom_event_count 2>/dev/null)
  collection_rc=$?
  if (( collection_rc == 0 )) && [[ "$oom_count" =~ '^[0-9]+$' ]]; then
    if (( oom_count > 0 )); then
      _sys_warn "$oom_count OOM event(s) in the available kernel log"
      (( issues++ ))
    else
      _sys_success "No OOM events in the available kernel log"
    fi
  else
    _sys_dim "Kernel OOM log unavailable without additional access"
  fi

  if [[ "$service_manager" == "systemd" ]]; then
    local journal_size
    journal_size=$(_sys_diag_journal_size 2>/dev/null) || journal_size=""
    [[ -n "$journal_size" ]] \
      && _sys_dim "Journal using $(_sys_display_escape "$journal_size")"
  fi

  local reboot_reason
  reboot_reason=$(_sys_diag_pending_reboot 2>/dev/null)
  collection_rc=$?
  if (( collection_rc == 0 )); then
    _sys_warn "System reboot is pending"
    [[ -n "$reboot_reason" ]] \
      && _sys_dim "Packages: $(_sys_display_escape "$reboot_reason")"
    (( issues++ ))
  fi

  _sys_blank
  if (( issues == 0 )); then
    _sys_success "System health: all available checks passed"
  else
    _sys_warn "System health: $issues issue(s) found"
  fi
  return 0
}

typeset -g _SYS_DIAG_SOURCED=1
