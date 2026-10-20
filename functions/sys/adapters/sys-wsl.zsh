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

# REPLY: the binfmt_misc directory where WSL registers Windows interop.
_sys_wsl_binfmt_dir() {
  REPLY=/proc/sys/fs/binfmt_misc
}

# REPLY: the directory below which WSL mounts Windows drives by default.
_sys_wsl_drive_root() {
  REPLY=/mnt
}

# Newer WSL releases register interop as WSLInterop-late.
_sys_wsl_interop_registered() {
  local REPLY
  _sys_wsl_binfmt_dir
  [[ -e "$REPLY/WSLInterop" || -e "$REPLY/WSLInterop-late" ]]
}

_sys_wsl_detect() {
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  _sys_wsl_interop_registered && return 0
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

_sys_wsl_snapd_available() {
  _sys_linux_snapd_available
}

_sys_wsl_interop_available() {
  [[ -n "${WSL_INTEROP:-}" ]] \
    || _sys_wsl_interop_registered \
    || command -v cmd.exe &>/dev/null
}

# REPLY: the cmd.exe to run for Windows facts: the one on PATH, or else
# <drive-root>/c/Windows/System32/cmd.exe when it is an executable regular
# file reached without a symbolic link. WSL omits the Windows PATH when
# appendWindowsPath=false.
_sys_wsl_cmd_program() {
  local program=""
  program=$(builtin whence -p cmd.exe 2>/dev/null)
  if [[ "$program" == /* ]]; then
    REPLY="$program"
    return 0
  fi
  _sys_wsl_drive_root
  program="$REPLY/c/Windows/System32/cmd.exe"
  REPLY=""
  [[ "$program" == /* && "$program" == "${program:A}" \
    && -f "$program" && ! -L "$program" && -x "$program" ]] || return 1
  REPLY="$program"
}

# True when <path>, or the file it resolves to, lies on a Windows drive that
# WSL mounts below /mnt/<drive letter>/, such as a program the appended
# Windows PATH provides. It runs on Windows through interop, so Linux tool
# steps and diagnostics never treat it as this host's tool.
_sys_wsl_windows_program() {
  local program="${1:-}" REPLY
  [[ "$program" == /* ]] || return 1
  _sys_wsl_drive_root
  [[ "$program" == "$REPLY"/[a-z]/* \
    || "${program:A}" == "$REPLY"/[a-z]/* ]]
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

  local version_output cmd_program REPLY
  _sys_wsl_cmd_program || return 3
  cmd_program="$REPLY"
  version_output=$(
    _sys_run_bounded_probe 5 65536 "$cmd_program" /c ver 2>/dev/null
  ) \
    || return 1
  version_output="${version_output//$'\r'/}"
  if [[ "$version_output" =~ '([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)' ]]; then
    print -r -- "${match[1]}"
    return 0
  fi
  return 1
}

# --- WSL configuration review collectors ------------------------------------
# Configuration files are data: they are read with a byte and time bound and
# parsed here, never sourced, expanded, or executed.

typeset -gr _SYS_WSL_CONFIG_MAX_BYTES=65536

# REPLY: the root below which the configuration review reads /etc, /proc, and
# /sys. It is the host root; tests point it at a fixture tree.
_sys_wsl_config_root() {
  REPLY=""
}

# REPLY: the deadline in seconds for one Windows interop query.
_sys_wsl_interop_deadline() {
  REPLY=5
}

# True for a Linux network interface name that is safe to use in a /sys path.
_sys_wsl_interface_name_valid() {
  [[ "${1:-}" =~ '^[A-Za-z0-9_.:@-]{1,15}$' \
    && "${1:-}" != . && "${1:-}" != .. ]]
}

# REPLY: the text of one small configuration file. Status 3: the file does
# not exist; 1: it is not a readable regular file, is larger than the limit,
# contains NUL bytes (as UTF-16 text does), or the bounded read failed, with
# reply=(<reason>). Usage: _sys_wsl_read_config_text <path> [max-bytes]
_sys_wsl_read_config_text() {
  emulate -L zsh
  local file_path="${1:-}" max_bytes="${2:-$_SYS_WSL_CONFIG_MAX_BYTES}"
  local content=""
  REPLY=""
  reply=()
  [[ "$file_path" == /* && "$max_bytes" == <1-> ]] || {
    reply=("invalid request")
    return 1
  }
  [[ -e "$file_path" || -L "$file_path" ]] || return 3
  [[ -f "$file_path" ]] || {
    reply=("not a regular file")
    return 1
  }
  [[ -r "$file_path" ]] || {
    reply=("not readable")
    return 1
  }
  local -A file_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -H file_state -- "$file_path" 2>/dev/null || {
    reply=("not readable")
    return 1
  }
  (( file_state[size] <= max_bytes )) || {
    reply=("larger than $max_bytes bytes")
    return 1
  }
  content=$(
    _sys_run_bounded_probe 3 "$max_bytes" cat -- "$file_path" 2>/dev/null
  ) || {
    reply=("the bounded read failed or timed out")
    return 1
  }
  [[ "$content" != *$'\0'* ]] || {
    reply=("not UTF-8 text (it contains NUL bytes)")
    return 1
  }
  REPLY="$content"
}

# stdout TSV records parsed from INI text such as /etc/wsl.conf or .wslconfig,
# with lines counted from 1:
#   setting<TAB>line<TAB>section<TAB>key<TAB>value
#   malformed<TAB>line<TAB>reason
# Comments start with # or ;. Keys and values lose surrounding whitespace, and
# a value loses one pair of surrounding double quotes. A value that still
# holds a control character is malformed, so a record never spans fields.
_sys_wsl_diag_ini_records() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local text="${1-}"
  local -a lines=("${(@f)text}") match=() mbegin=() mend=()
  local line="" trimmed="" section="" key="" value=""
  local -i line_number=0 section_state=0
  for line in "${lines[@]}"; do
    (( ++line_number ))
    line="${line%$'\r'}"
    (( line_number == 1 )) && line="${line#$'\xef\xbb\xbf'}"
    trimmed="${${line##[[:space:]]#}%%[[:space:]]#}"
    [[ -z "$trimmed" || "$trimmed" == [\#\;]* ]] && continue
    if [[ "$trimmed" == \[* ]]; then
      if [[ "$trimmed" =~ '^\[[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*\]$' ]]; then
        section="${match[1]}"
        section_state=1
      else
        section=""
        section_state=2
        print -r -- "malformed"$'\t'"$line_number"$'\t'"invalid section header"
      fi
      continue
    fi
    if [[ "$trimmed" != *=* ]]; then
      print -r -- "malformed"$'\t'"$line_number"$'\t'"no '=' separator"
      continue
    fi
    key="${${${trimmed%%=*}##[[:space:]]#}%%[[:space:]]#}"
    value="${${${trimmed#*=}##[[:space:]]#}%%[[:space:]]#}"
    if [[ ! "$key" =~ '^[A-Za-z0-9._-]+$' ]]; then
      print -r -- "malformed"$'\t'"$line_number"$'\t'"invalid key"
      continue
    fi
    if (( section_state != 1 )); then
      if (( section_state == 0 )); then
        print -r -- "malformed"$'\t'"$line_number"$'\t'"setting outside a section"
      else
        print -r -- "malformed"$'\t'"$line_number"$'\t'"setting under an invalid section header"
      fi
      continue
    fi
    if (( ${#value} >= 2 )) && [[ "$value" == \"*\" ]]; then
      value="${value[2,-2]}"
    fi
    if [[ "$value" == *[[:cntrl:]]* ]]; then
      print -r -- "malformed"$'\t'"$line_number"$'\t'"control character in value"
      continue
    fi
    print -r -- "setting"$'\t'"$line_number"$'\t'"$section"$'\t'"$key"$'\t'"$value"
  done
  return 0
}

# stdout: the interface of the IPv4 default route with the lowest metric in
# /proc/net/route. Status 1 when there is none.
_sys_wsl_diag_default_route_interface() {
  emulate -L zsh
  local REPLY
  _sys_wsl_config_root
  local route_file="$REPLY/proc/net/route"
  [[ -f "$route_file" && -r "$route_file" ]] || return 1
  local iface destination gateway flags refcnt use metric mask rest
  local best=""
  local -i best_metric=0 line_number=0
  while IFS=$' \t' read -r \
      iface destination gateway flags refcnt use metric mask rest; do
    (( ++line_number <= 1024 )) || break
    (( line_number == 1 )) && continue
    [[ "$destination" == 00000000 && "$mask" == 00000000 \
      && "$flags" =~ '^[0-9A-Fa-f]{1,8}$' && "$metric" =~ '^[0-9]{1,9}$' ]] \
      || continue
    (( 16#$flags & 1 )) || continue
    _sys_wsl_interface_name_valid "$iface" || continue
    if [[ -z "$best" ]] || (( 10#$metric < best_metric )); then
      best="$iface"
      best_metric=$(( 10#$metric ))
    fi
  done < "$route_file"
  [[ -n "$best" ]] || return 1
  print -r -- "$best"
}

# stdout: the MTU of one interface from /sys/class/net. Status 1 when it is
# absent or unreadable; 2 for an invalid name.
_sys_wsl_diag_interface_mtu() {
  emulate -L zsh
  local iface="${1:-}" mtu="" REPLY
  _sys_wsl_interface_name_valid "$iface" || return 2
  _sys_wsl_config_root
  local mtu_file="$REPLY/sys/class/net/$iface/mtu"
  [[ -f "$mtu_file" && -r "$mtu_file" ]] || return 1
  IFS= read -r mtu < "$mtu_file" || [[ -n "$mtu" ]] || return 1
  [[ "$mtu" =~ '^[0-9]{1,6}$' ]] || return 1
  print -r -- "$(( 10#$mtu ))"
}

# stdout TSV records: interface, kind, MTU (empty when unreadable) for each
# tunnel interface: WireGuard (DEVTYPE=wireguard) or a tun/tap device.
_sys_wsl_diag_tunnel_records() {
  emulate -L zsh
  local REPLY
  _sys_wsl_config_root
  local net_dir="$REPLY/sys/class/net"
  [[ -d "$net_dir" ]] || return 1
  local iface_dir iface kind uevent_line mtu
  local -i interface_count=0 uevent_lines=0
  for iface_dir in "$net_dir"/*(N); do
    (( ++interface_count <= 256 )) || break
    iface="${iface_dir:t}"
    _sys_wsl_interface_name_valid "$iface" || continue
    kind=""
    if [[ -f "$iface_dir/uevent" && -r "$iface_dir/uevent" ]]; then
      uevent_lines=0
      while IFS= read -r uevent_line; do
        (( ++uevent_lines <= 64 )) || break
        [[ "$uevent_line" == DEVTYPE=wireguard ]] && kind=wireguard
      done < "$iface_dir/uevent"
    fi
    [[ -z "$kind" && -e "$iface_dir/tun_flags" ]] && kind=tun
    [[ -n "$kind" ]] || continue
    mtu=$(_sys_wsl_diag_interface_mtu "$iface") || mtu=""
    print -r -- "$iface"$'\t'"$kind"$'\t'"$mtu"
  done
  return 0
}

# stdout: the command name of PID 1, such as systemd or init.
_sys_wsl_diag_pid1_name() {
  emulate -L zsh
  local REPLY name=""
  _sys_wsl_config_root
  local comm_file="$REPLY/proc/1/comm"
  [[ -f "$comm_file" && -r "$comm_file" ]] || return 1
  IFS= read -r name < "$comm_file" || [[ -n "$name" ]] || return 1
  [[ -n "$name" && ${#name} -le 64 && "$name" != *[[:cntrl:]]* ]] || return 1
  print -r -- "$name"
}

# stdout: generated when WSL wrote /etc/resolv.conf, else custom. Status 3:
# the file does not exist; 1: it cannot be read.
_sys_wsl_diag_resolv_conf_state() {
  emulate -L zsh
  local REPLY
  local -a reply=()
  _sys_wsl_config_root
  local -i read_rc=0
  _sys_wsl_read_config_text "$REPLY/etc/resolv.conf" || read_rc=$?
  (( read_rc == 0 )) || return $(( read_rc == 3 ? 3 : 1 ))
  if [[ "$REPLY" == *"automatically generated by WSL"* ]]; then
    print -r -- generated
  else
    print -r -- custom
  fi
}

# stdout: the systemd service units enabled for multi-user.target, at most 64.
_sys_wsl_diag_enabled_service_units() {
  emulate -L zsh
  local REPLY unit unit_name
  _sys_wsl_config_root
  local wants_dir="$REPLY/etc/systemd/system/multi-user.target.wants"
  [[ -d "$wants_dir" ]] || return 0
  local -i unit_count=0
  for unit in "$wants_dir"/*.service(N); do
    unit_name="${unit:t}"
    [[ "$unit_name" =~ '^[A-Za-z0-9@._:-]{1,128}$' ]] || continue
    (( ++unit_count <= 64 )) || break
    print -r -- "$unit_name"
  done
  return 0
}

# Validates one Windows path such as C:\Users\Jane into REPLY after removing
# carriage returns and surrounding whitespace.
_sys_wsl_windows_path_valid() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local windows_path="${1-}"
  REPLY=""
  windows_path="${windows_path//$'\r'/}"
  windows_path="${${windows_path##[[:space:]]#}%%[[:space:]]#}"
  [[ ${#windows_path} -le 260 \
    && "$windows_path" =~ '^[A-Za-z]:\\[^"<>|?*%]*$' \
    && "$windows_path" != *[[:cntrl:]]* ]] || return 1
  REPLY="$windows_path"
}

# stdout: the Linux path of the Windows user profile (%USERPROFILE%). wslvar
# answers when it is installed; otherwise cmd.exe does, started from its own
# Windows directory so that it does not warn about a UNC working directory.
# wslpath converts the result, or else the drive root does. Every query is
# bounded. Status 3: Windows interop is unavailable; 1: the profile could not
# be resolved. Usage: _sys_wsl_diag_windows_profile [drive-root]
_sys_wsl_diag_windows_profile() {
  emulate -L zsh
  _sys_wsl_interop_available || return 3
  local drive_root="${1-}" REPLY deadline program="" answer="" windows_path=""
  local -a reply=()
  _sys_wsl_interop_deadline
  deadline="$REPLY"
  [[ "$deadline" == <1-> ]] || deadline=5

  if _sys_tool_program wslvar; then
    program="$REPLY"
    answer=$(
      _sys_run_bounded_probe "$deadline" 4096 "$program" USERPROFILE \
        2>/dev/null
    ) || answer=""
    _sys_wsl_windows_path_valid "$answer" && windows_path="$REPLY"
  fi
  if [[ -z "$windows_path" ]] && _sys_wsl_cmd_program; then
    program="$REPLY"
    answer=$(
      builtin cd -q -- "${program:h}" 2>/dev/null
      _sys_run_bounded_probe "$deadline" 4096 \
        "$program" /c echo '%USERPROFILE%' 2>/dev/null
    ) || answer=""
    _sys_wsl_windows_path_valid "$answer" && windows_path="$REPLY"
  fi
  [[ -n "$windows_path" ]] || return 1

  local linux_path=""
  if _sys_tool_program wslpath; then
    program="$REPLY"
    linux_path=$(
      _sys_run_bounded_probe 3 4096 "$program" -u "$windows_path" 2>/dev/null
    ) || linux_path=""
    linux_path="${linux_path//$'\r'/}"
  fi
  if [[ "$linux_path" != /* ]]; then
    if [[ -z "$drive_root" ]]; then
      _sys_wsl_drive_root
      drive_root="$REPLY"
    fi
    local rest="${windows_path[4,-1]}"
    linux_path="${drive_root%/}/${(L)windows_path[1]}${rest:+/${rest//\\//}}"
  fi
  linux_path="${linux_path%/}"
  [[ "$linux_path" == /?* && "$linux_path" != *[[:cntrl:]]* \
    && "/$linux_path/" != */../* ]] || return 1
  print -r -- "$linux_path"
}

typeset -g _SYS_WSL_ADAPTER_SOURCED=1
