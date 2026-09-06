#!/usr/bin/env zsh
# =============================================================================
# System macOS Adapter: Darwin capability probes
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-capabilities.zsh.
# Safe to re-source; defines private read-only probes only.
#

if [[ -n "${_SYS_MACOS_ADAPTER_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_sys_macos_package_manager() {
  if command -v brew &>/dev/null; then
    print -r -- "brew"
  elif command -v softwareupdate &>/dev/null; then
    print -r -- "softwareupdate"
  else
    print -r -- "unavailable"
  fi
}

_sys_macos_os_updates_backend() {
  if command -v softwareupdate &>/dev/null; then
    print -r -- "softwareupdate"
  else
    print -r -- "unavailable"
  fi
}

_sys_macos_service_manager() {
  if command -v launchctl &>/dev/null; then
    print -r -- "launchd"
  else
    print -r -- "unavailable"
  fi
}

_sys_macos_process_backend() {
  if command -v ps &>/dev/null; then
    print -r -- "bsd-ps"
  else
    print -r -- "unavailable"
  fi
}

_sys_macos_ports_backend() {
  if command -v lsof &>/dev/null; then
    print -r -- "lsof"
  else
    print -r -- "unavailable"
  fi
}

_sys_macos_fonts_backend() {
  print -r -- "macos-user-fonts"
}

# stdout: one human-readable operating-system name.
_sys_macos_diag_os_name() {
  local product_name product_version build_version
  product_name=$(
    _sys_run_bounded_probe 3 65536 sw_vers -productName 2>/dev/null
  ) \
    || product_name="macOS"
  product_version=$(
    _sys_run_bounded_probe 3 65536 sw_vers -productVersion 2>/dev/null
  ) \
    || product_version=""
  build_version=$(
    _sys_run_bounded_probe 3 65536 sw_vers -buildVersion 2>/dev/null
  ) \
    || build_version=""

  local os_name="$product_name"
  [[ -n "$product_version" ]] && os_name+=" $product_version"
  [[ -n "$build_version" ]] && os_name+=" ($build_version)"
  print -r -- "$os_name"
}

# stdout TSV: total-bytes, available-bytes, swap-total-bytes, swap-free-bytes.
_sys_macos_diag_memory_record() {
  local total_bytes vm_output page_size available_pages
  local swap_output swap_record swap_total_bytes swap_free_bytes

  total_bytes=$(
    _sys_run_bounded_probe 3 65536 sysctl -n hw.memsize 2>/dev/null
  ) || return 1
  local REPLY
  _sys_normalize_uint "$total_bytes" || return 1
  total_bytes="$REPLY"

  vm_output=$(
    _sys_run_bounded_probe 3 1048576 vm_stat 2>/dev/null
  ) || return 1
  page_size=$(print -r -- "$vm_output" | command awk '
    NR == 1 && match($0, /page size of [0-9]+ bytes/) {
      value = substr($0, RSTART, RLENGTH)
      gsub(/[^0-9]/, "", value)
      print value
      exit
    }
  ')
  available_pages=$(print -r -- "$vm_output" | command awk -F: '
    /Pages free|Pages inactive|Pages speculative/ {
      value = $2
      gsub(/[^0-9]/, "", value)
      pages += value
    }
    END { print pages + 0 }
  ')
  _sys_normalize_uint "$page_size" || return 1
  page_size="$REPLY"
  _sys_normalize_uint "$available_pages" || return 1
  available_pages="$REPLY"
  (( page_size > 0 \
    && available_pages <= _SYS_MAX_INTEGER / page_size )) || return 1

  local -i available_bytes=$(( page_size * available_pages ))
  (( available_bytes <= total_bytes )) || return 1
  swap_total_bytes=0
  swap_free_bytes=0
  swap_output=$(
    _sys_run_bounded_probe 3 65536 sysctl -n vm.swapusage 2>/dev/null
  ) \
    || swap_output=""
  if [[ -n "$swap_output" ]]; then
    swap_record=$(print -r -- "$swap_output" | command awk '
      function to_bytes(value, suffix, number) {
        suffix = substr(value, length(value), 1)
        number = substr(value, 1, length(value) - 1) + 0
        if (suffix == "T") return number * 1099511627776
        if (suffix == "G") return number * 1073741824
        if (suffix == "M") return number * 1048576
        if (suffix == "K") return number * 1024
        return value + 0
      }
      {
        for (i = 1; i <= NF; i++) {
          if ($i == "total") total = $(i + 2)
          if ($i == "free") free = $(i + 2)
        }
      }
      END { printf "%.0f\t%.0f\n", to_bytes(total), to_bytes(free) }
    ')
    IFS=$'\t' read -r swap_total_bytes swap_free_bytes <<< "$swap_record"
    _sys_normalize_uint "$swap_total_bytes" || return 1
    swap_total_bytes="$REPLY"
    _sys_normalize_uint "$swap_free_bytes" || return 1
    swap_free_bytes="$REPLY"
    (( swap_free_bytes <= swap_total_bytes )) || return 1
  fi

  printf '%s\t%s\t%s\t%s\n' \
    "$total_bytes" "$available_bytes" \
    "${swap_total_bytes:-0}" "${swap_free_bytes:-0}"
}

# stdout TSV: logical-core-count, CPU model.
_sys_macos_diag_cpu_record() {
  local core_count model_name
  core_count=$(
    _sys_run_bounded_probe 3 65536 sysctl -n hw.logicalcpu 2>/dev/null
  ) || core_count=0
  local REPLY
  _sys_normalize_uint "$core_count" 1048576 || core_count=0
  [[ "$core_count" == 0 ]] || core_count="$REPLY"
  model_name=$(
    _sys_run_bounded_probe 3 65536 \
      sysctl -n machdep.cpu.brand_string 2>/dev/null
  ) \
    || model_name=""
  if [[ -z "$model_name" ]]; then
    model_name=$(
      _sys_run_bounded_probe 3 65536 sysctl -n hw.model 2>/dev/null
    ) || model_name="Unknown"
  fi
  model_name="${model_name//$'\t'/ }"
  model_name="${model_name//$'\n'/ }"
  printf '%s\t%s\n' "$core_count" "$model_name"
}

# stdout TSV: uptime-seconds, 1-minute, 5-minute, and 15-minute load.
_sys_macos_diag_runtime_record() {
  local boot_record boot_seconds now_seconds uptime_seconds load_record
  boot_record=$(
    _sys_run_bounded_probe 3 65536 sysctl -n kern.boottime 2>/dev/null
  ) || return 1
  boot_seconds=$(print -r -- "$boot_record" | command awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "sec") {
          value = $(i + 2)
          gsub(/[^0-9]/, "", value)
          print value
          exit
        }
      }
    }
  ')
  now_seconds=$(
    _sys_run_bounded_probe 3 65536 date +%s 2>/dev/null
  ) || return 1
  local REPLY
  _sys_normalize_uint "$boot_seconds" || return 1
  boot_seconds="$REPLY"
  _sys_normalize_uint "$now_seconds" || return 1
  now_seconds="$REPLY"
  (( now_seconds >= boot_seconds )) || return 1
  uptime_seconds=$(( now_seconds - boot_seconds ))

  load_record=$(
    _sys_run_bounded_probe 3 65536 sysctl -n vm.loadavg 2>/dev/null
  ) || return 1
  load_record="${load_record//[\{\}]/}"
  local -a load_parts=( ${(z)load_record} )
  (( ${#load_parts} >= 3 )) || return 1
  local load_value
  for load_value in "${(@)load_parts[1,3]}"; do
    [[ ${#load_value} -le 32 \
      && "$load_value" =~ '^[0-9]+([.][0-9]+)?$' ]] || return 1
  done
  printf '%s\t%s\t%s\t%s\n' \
    "$uptime_seconds" "${load_parts[1]}" \
    "${load_parts[2]}" "${load_parts[3]}"
}

# stdout TSV records: display label, installed package count.
_sys_macos_diag_package_records() {
  local package_manager="$1"
  local package_output=""
  local -a package_lines=()

  case "$package_manager" in
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
    softwareupdate)
      command -v pkgutil &>/dev/null || return 3
      package_output=$(
        _sys_run_bounded_probe 5 1048576 pkgutil --pkgs 2>/dev/null
      ) \
        || return 1
      [[ -n "$package_output" ]] && package_lines=("${(@f)package_output}")
      printf 'Installer packages\t%d\n' "${#package_lines}"
      ;;
    unavailable)
      return 3
      ;;
    *)
      return 2
      ;;
  esac
}

# stdout TSV records: zombie PID, command name.
_sys_macos_diag_zombie_records() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  _sys_run_bounded_probe 5 1048576 \
    ps -axo pid=,state=,comm= 2>/dev/null | command awk '
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

# stdout TSV records: failed launchd label, last exit status.
_sys_macos_diag_failed_service_records() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  _sys_run_bounded_probe 5 1048576 \
    launchctl list 2>/dev/null | command awk '
    NR > 1 && $2 ~ /^-?[0-9]+$/ && $2 != "0" {
      printf "%s\tlast-exit=%s\n", $3, $2
    }
  '
}

_sys_macos_diag_oom_event_count() {
  return 3
}

_sys_macos_diag_journal_size() {
  return 3
}

_sys_macos_diag_pending_reboot() {
  return 1
}

typeset -g _SYS_MACOS_ADAPTER_SOURCED=1
