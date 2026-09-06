#!/usr/bin/env zsh
# =============================================================================
# System Linux Adapter: native Linux capability probes
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-capabilities.zsh.
# Safe to re-source; defines private read-only probes only.
#

if [[ -n "${_SYS_LINUX_ADAPTER_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_sys_linux_package_manager() {
  if command -v apt-get &>/dev/null; then
    print -r -- "apt"
  elif command -v dnf &>/dev/null; then
    print -r -- "dnf"
  elif command -v pacman &>/dev/null; then
    print -r -- "pacman"
  elif command -v zypper &>/dev/null; then
    print -r -- "zypper"
  elif command -v apk &>/dev/null; then
    print -r -- "apk"
  elif command -v brew &>/dev/null; then
    print -r -- "brew"
  else
    print -r -- "unavailable"
  fi
}

_sys_linux_service_manager() {
  if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
    print -r -- "systemd"
  else
    print -r -- "unavailable"
  fi
}

_sys_linux_process_backend() {
  if command -v ps &>/dev/null \
    && _sys_run_with_timeout 3 \
      env LC_ALL=C ps -eo pid=,uid=,pcpu=,pmem=,comm= \
      --sort=-pcpu >/dev/null 2>&1 \
    && _sys_run_with_timeout 3 \
      env LC_ALL=C ps -p "$$" -o uid= -o lstart= -o comm= \
      >/dev/null 2>&1; then
    print -r -- "procps"
  else
    print -r -- "unavailable"
  fi
}

_sys_linux_ports_backend() {
  if command -v lsof &>/dev/null; then
    print -r -- "lsof"
  elif command -v ss &>/dev/null; then
    print -r -- "ss"
  else
    print -r -- "unavailable"
  fi
}

_sys_linux_fonts_backend() {
  if command -v fc-list &>/dev/null && command -v fc-cache &>/dev/null; then
    print -r -- "fontconfig"
  else
    print -r -- "unavailable"
  fi
}

_sys_linux_snapd_available() {
  command -v snap &>/dev/null && [[ -S /run/snapd.socket ]]
}

# stdout: one human-readable operating-system name.
_sys_linux_diag_os_name() {
  local release_name=""

  if [[ -r /etc/os-release ]]; then
    release_name=$(command awk -F= '
      $1 == "PRETTY_NAME" {
        value = substr($0, index($0, "=") + 1)
        sub(/^"/, "", value)
        sub(/"$/, "", value)
        print value
        exit
      }
    ' /etc/os-release 2>/dev/null)
  fi

  if [[ -z "$release_name" ]] && command -v lsb_release &>/dev/null; then
    release_name=$(
      _sys_run_bounded_probe 3 65536 lsb_release -ds 2>/dev/null
    )
  fi

  print -r -- "${release_name:-Linux}"
}

# stdout TSV: total-bytes, available-bytes, swap-total-bytes, swap-free-bytes.
_sys_linux_diag_memory_record() {
  [[ -r /proc/meminfo ]] || return 1

  command awk '
    $1 == "MemTotal:" { total = $2 * 1024 }
    $1 == "MemAvailable:" { available = $2 * 1024 }
    $1 == "MemFree:" { free = $2 * 1024 }
    $1 == "Buffers:" { buffers = $2 * 1024 }
    $1 == "Cached:" { cached = $2 * 1024 }
    $1 == "SReclaimable:" { reclaimable = $2 * 1024 }
    $1 == "Shmem:" { shmem = $2 * 1024 }
    $1 == "SwapTotal:" { swap_total = $2 * 1024 }
    $1 == "SwapFree:" { swap_free = $2 * 1024 }
    END {
      if (total <= 0) exit 1
      if (available <= 0) {
        available = free + buffers + cached + reclaimable - shmem
      }
      if (available < 0) available = 0
      printf "%.0f\t%.0f\t%.0f\t%.0f\n", \
        total, available, swap_total, swap_free
    }
  ' /proc/meminfo 2>/dev/null
}

# stdout TSV: logical-core-count, CPU model.
_sys_linux_diag_cpu_record() {
  local core_count="" model_name=""

  if command -v getconf &>/dev/null; then
    core_count=$(
      _sys_run_bounded_probe 3 65536 getconf _NPROCESSORS_ONLN 2>/dev/null
    )
  fi
  if [[ ! "$core_count" =~ '^[0-9]+$' ]] \
    && command -v nproc &>/dev/null; then
    core_count=$(_sys_run_bounded_probe 3 65536 nproc 2>/dev/null)
  fi
  if [[ ! "$core_count" =~ '^[0-9]+$' ]] && [[ -r /proc/cpuinfo ]]; then
    core_count=$(command awk -F: '$1 ~ /^processor[[:space:]]*$/ { count++ }
      END { print count + 0 }' /proc/cpuinfo 2>/dev/null)
  fi

  if [[ -r /proc/cpuinfo ]]; then
    model_name=$(command awk -F: '
      $1 ~ /^(model name|Hardware|Processor)[[:space:]]*$/ {
        value = $2
        sub(/^[[:space:]]+/, "", value)
        print value
        exit
      }
    ' /proc/cpuinfo 2>/dev/null)
  fi

  model_name="${model_name//$'\t'/ }"
  model_name="${model_name//$'\n'/ }"
  printf '%s\t%s\n' "${core_count:-0}" "${model_name:-Unknown}"
}

# stdout TSV: uptime-seconds, 1-minute, 5-minute, and 15-minute load.
_sys_linux_diag_runtime_record() {
  [[ -r /proc/uptime && -r /proc/loadavg ]] || return 1

  local uptime_seconds ignored load_one load_five load_fifteen
  read -r uptime_seconds ignored < /proc/uptime || return 1
  read -r load_one load_five load_fifteen ignored < /proc/loadavg || return 1
  uptime_seconds="${uptime_seconds%%.*}"
  [[ "$uptime_seconds" =~ '^[0-9]+$' ]] || return 1

  printf '%s\t%s\t%s\t%s\n' \
    "$uptime_seconds" "$load_one" "$load_five" "$load_fifteen"
}

# stdout TSV records: display label, installed package count.
_sys_linux_diag_package_records() {
  local package_manager="$1"
  local package_output=""
  local -a package_lines=()

  case "$package_manager" in
    apt)
      package_output=$(
        _sys_run_bounded_probe 5 1048576 \
          dpkg-query -W -f='${binary:Package}\n' 2>/dev/null
      ) || return 1
      [[ -n "$package_output" ]] && package_lines=("${(@f)package_output}")
      printf 'APT packages\t%d\n' "${#package_lines}"
      ;;
    dnf|zypper)
      package_output=$(
        _sys_run_bounded_probe 5 1048576 rpm -qa 2>/dev/null
      ) || return 1
      [[ -n "$package_output" ]] && package_lines=("${(@f)package_output}")
      printf 'RPM packages\t%d\n' "${#package_lines}"
      ;;
    pacman)
      package_output=$(
        _sys_run_bounded_probe 5 1048576 pacman -Qq 2>/dev/null
      ) || return 1
      [[ -n "$package_output" ]] && package_lines=("${(@f)package_output}")
      printf 'Pacman packages\t%d\n' "${#package_lines}"
      ;;
    apk)
      package_output=$(
        _sys_run_bounded_probe 5 1048576 apk info 2>/dev/null
      ) || return 1
      [[ -n "$package_output" ]] && package_lines=("${(@f)package_output}")
      printf 'APK packages\t%d\n' "${#package_lines}"
      ;;
    brew)
      local formula_output cask_output
      local -a formula_lines=() cask_lines=()
      formula_output=$(
        _sys_run_bounded_probe 5 1048576 \
          _sys_brew list --formula 2>/dev/null
      ) \
        || return 1
      cask_output=$(
        _sys_run_bounded_probe 5 1048576 \
          _sys_brew list --cask 2>/dev/null
      ) \
        || cask_output=""
      [[ -n "$formula_output" ]] && formula_lines=("${(@f)formula_output}")
      [[ -n "$cask_output" ]] && cask_lines=("${(@f)cask_output}")
      printf 'Brew formulae\t%d\n' "${#formula_lines}"
      printf 'Brew casks\t%d\n' "${#cask_lines}"
      ;;
    unavailable)
      return 3
      ;;
    *)
      return 2
      ;;
  esac

  if _sys_linux_snapd_available; then
    local snap_output
    local -a snap_lines=()
    snap_output=$(
      _sys_run_bounded_probe 3 1048576 snap list 2>/dev/null
    ) || return 0
    [[ -n "$snap_output" ]] && snap_lines=("${(@f)snap_output}")
    (( ${#snap_lines} > 0 )) && snap_lines=("${snap_lines[@]:1}")
    printf 'Snap packages\t%d\n' "${#snap_lines}"
  fi
}

# stdout TSV records: zombie PID, command name.
_sys_linux_diag_zombie_records() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  _sys_run_bounded_probe 5 1048576 \
    ps -eo pid=,stat=,comm= 2>/dev/null | command awk '
    $2 ~ /^Z/ {
      pid = $1
      $1 = ""
      $2 = ""
      sub(/^[[:space:]]+/, "", $0)
      gsub(/\t/, " ", $0)
      printf "%s\t%s\n", pid, $0
    }
  '
}

# stdout TSV records: failed systemd unit, state and description.
_sys_linux_diag_failed_service_records() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  _sys_run_bounded_probe 5 1048576 \
    systemctl --failed --no-legend --no-pager --plain 2>/dev/null \
    | command awk '
      NF >= 4 {
        unit = $1
        detail = $3 "/" $4
        for (i = 5; i <= NF; i++) detail = detail " " $i
        gsub(/\t/, " ", detail)
        printf "%s\t%s\n", unit, detail
      }
    '
}

# stdout: decimal count. Status 3 means the kernel log is inaccessible.
_sys_linux_diag_oom_event_count() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  _sys_run_bounded_probe 5 1048576 dmesg 2>/dev/null | command awk '
    BEGIN { count = 0 }
    tolower($0) ~ /out of memory|oom-killer/ { count++ }
    END { print count }
  '
}

# stdout: journal disk-usage value as reported by journalctl.
_sys_linux_diag_journal_size() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  _sys_run_bounded_probe 5 65536 \
    journalctl --disk-usage 2>/dev/null | command awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9.]+[KMGT]?i?B\.?$/) {
          gsub(/\.$/, "", $i)
          print $i
          exit
        }
      }
    }
  '
}

# stdout: optional package reason. Status 1 means no reboot is pending.
_sys_linux_diag_pending_reboot() {
  [[ -f /var/run/reboot-required ]] || return 1

  if [[ -r /var/run/reboot-required.pkgs ]]; then
    command awk 'NF { printf "%s%s", separator, $0; separator = " " }
      END { if (separator != "") print "" }' \
      /var/run/reboot-required.pkgs 2>/dev/null
  fi
  return 0
}

typeset -g _SYS_LINUX_ADAPTER_SOURCED=1
