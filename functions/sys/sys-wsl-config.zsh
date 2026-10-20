#!/usr/bin/env zsh
# =============================================================================
# System WSL Review: read-only WSL configuration review
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, sys-capabilities.zsh, and the
# WSL adapter.
# Safe to re-source; defines functions and read-only constants only.
#
# /etc/wsl.conf and the Windows .wslconfig are data: the WSL adapter reads
# them with byte and time bounds and parses them, and nothing in them is
# sourced, expanded, or executed. Windows interop queries are bounded and
# optional, and the review changes nothing on the host.
#

if [[ -n "${_SYS_WSL_CONFIG_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Reviewed settings as section|key|kind|default. kind is bool, count, or
# text; a default is shown only where WSL documents a stable one.
typeset -gra _SYS_WSL_CONF_SETTINGS=(
  'automount|enabled|bool|true'
  'automount|root|text|/mnt/'
  'automount|options|text|'
  'boot|systemd|bool|'
  'boot|command|text|'
  'network|generateResolvConf|bool|true'
  'network|generateHosts|bool|true'
  'network|hostname|text|'
  'interop|enabled|bool|true'
  'interop|appendWindowsPath|bool|true'
  'user|default|text|'
)
typeset -gra _SYS_WSL_WSLCONFIG_SETTINGS=(
  'wsl2|memory|text|'
  'wsl2|processors|count|'
  'wsl2|swap|text|'
  'wsl2|networkingMode|text|NAT'
  'wsl2|dnsTunneling|bool|'
  'wsl2|autoProxy|bool|'
  'wsl2|firewall|bool|'
  'wsl2|sparseVhd|bool|'
  'experimental|autoMemoryReclaim|text|'
  'experimental|sparseVhd|bool|'
)

_sys_wsl_usage() {
  print -u2 -r -- 'Usage: sys-wsl [--json] [-h|--help]'
  print -u2 -r -- 'Review the WSL configuration read-only: /etc/wsl.conf, networking and MTU,'
  print -u2 -r -- 'the Windows .wslconfig, and the manual virtual-disk compaction steps.'
  print -u2 -r -- '--json prints one zdx.sys-wsl.v1 JSON document on stdout.'
  print -u2 -r -- 'On a host that is not WSL it reports that it does not apply and returns 1.'
}

# True when a configuration value may hold a credential. The review then
# withholds it from the terminal and from JSON.
_sys_wsl_value_sensitive() {
  emulate -L zsh
  local normalized="${(L)1-}"
  [[ "$normalized" == *(password|passwd|passphrase|token|secret|credential|bearer|api-key|api_key|apikey|access-key|access_key|private-key|private_key|cookie)* ]] \
    && return 0
  [[ "$normalized" =~ '://[^/@[:space:]]+:[^/@[:space:]]*@' ]]
}

# REPLY: a camelCase setting name in snake_case, such as append_windows_path.
_sys_wsl_snake_case() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local -a match=() mbegin=() mend=()
  local separated="${${1-}//(#b)([A-Z])/_${match[1]}}"
  REPLY="${(L)separated}"
}

# True when DrvFs mount options include metadata.
_sys_wsl_options_have_metadata() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local option
  for option in "${(@s:,:)1-}"; do
    option="${${option##[[:space:]]#}%%[[:space:]]#}"
    [[ "${(L)option}" == metadata ]] && return 0
  done
  return 1
}

# reply=(interface mtu) when a [boot] command runs
# `ip link set [dev] <interface> ... mtu <value>`, which is how a pinned MTU is
# written. The command is split into words and never evaluated.
_sys_wsl_boot_mtu_pin() {
  emulate -L zsh
  local command_text="${1-}" word iface="" mtu=""
  reply=()
  [[ -n "$command_text" ]] || return 1
  local -a words=(${=${command_text//[\"\';&|()]/ }})
  local -i state=0
  for word in "${words[@]}"; do
    if [[ "${word:t}" == ip ]]; then
      state=1
      iface=""
      continue
    fi
    case $state in
      1) [[ "$word" == link ]] && state=2 ;;
      2) if [[ "$word" == set ]]; then state=3; else state=0; fi ;;
      3)
        if [[ "$word" == dev ]]; then
          state=4
        else
          iface="$word"
          state=5
        fi
        ;;
      4) iface="$word"; state=5 ;;
      5) [[ "$word" == mtu ]] && state=6 ;;
      6) mtu="$word"; break ;;
    esac
  done
  _sys_wsl_interface_name_valid "$iface" \
    && [[ "$mtu" =~ '^[0-9]{2,5}$' ]] \
    && (( 10#$mtu >= 68 && 10#$mtu <= 65535 )) || return 1
  reply=("$iface" "$(( 10#$mtu ))")
}

# Indexes one file's INI records into the caller's review state: wsl_values
# and wsl_lines by "<file>:<section>.<key>" without letter case, the last
# occurrence winning, plus wsl_other and wsl_malformed records. A reviewed
# boolean or count that does not parse is malformed and stays unset.
# Usage: _sys_wsl_review_index <file-id> <records> <settings-array-name>
_sys_wsl_review_index() {
  emulate -L zsh
  local file_id="$1" records="$2" settings_name="$3"
  local spec record line_number section key value lookup kind
  local -a spec_fields=() record_fields=()
  local -A kinds=()
  for spec in "${(@P)settings_name}"; do
    spec_fields=("${(@s:|:)spec}")
    kinds[${(L)spec_fields[1]}.${(L)spec_fields[2]}]="${spec_fields[3]}"
  done

  for record in "${(@f)records}"; do
    case "${record%%$'\t'*}" in
      malformed)
        wsl_malformed+=("$file_id"$'\t'"${record#malformed$'\t'}")
        ;;
      setting)
        record_fields=("${(@ps:\t:)record}")
        line_number="${record_fields[2]}"
        section="${record_fields[3]}"
        key="${record_fields[4]}"
        value="${record#*$'\t'*$'\t'*$'\t'*$'\t'}"
        lookup="${(L)section}.${(L)key}"
        kind="${kinds[$lookup]-}"
        case "$kind" in
          bool)
            if [[ "${(L)value}" == (true|false) ]]; then
              value="${(L)value}"
            else
              wsl_malformed+=("$file_id"$'\t'"$line_number"$'\t'"[$section] $key expects true or false")
              continue
            fi
            ;;
          count)
            if [[ "$value" =~ '^[0-9]{1,4}$' ]] && (( 10#$value > 0 )); then
              value="$(( 10#$value ))"
            else
              wsl_malformed+=("$file_id"$'\t'"$line_number"$'\t'"[$section] $key expects a positive whole number")
              continue
            fi
            ;;
          "")
            wsl_other+=("$file_id"$'\t'"$line_number"$'\t'"$section"$'\t'"$key"$'\t'"$value")
            ;;
        esac
        wsl_values[$file_id:$lookup]="$value"
        wsl_lines[$file_id:$lookup]="$line_number"
        ;;
    esac
  done
}

# Fills the caller's review state from the WSL adapter collectors. Every
# collector is read-only and bounded; a missing fact stays empty.
_sys_wsl_review_collect() {
  emulate -L zsh
  local REPLY root records value
  local -a reply=()
  local -i read_rc=0 profile_rc=0
  _sys_wsl_config_root
  root="$REPLY"

  value=$(_sys_wsl_diag_release 2>/dev/null) || value=""
  wsl_facts[generation]="$value"
  value=$(_sys_run_bounded_probe 3 65536 uname -r 2>/dev/null) || value=""
  wsl_facts[kernel]="$value"
  value="${WSL_DISTRO_NAME:-}"
  [[ ${#value} -le 128 && "$value" != *[[:cntrl:]]* ]] || value=""
  wsl_facts[distribution]="$value"
  value=$(_sys_wsl_diag_os_name 2>/dev/null) || value=""
  wsl_facts[os]="$value"
  value=$(_sys_wsl_diag_pid1_name 2>/dev/null) || value=""
  wsl_facts[pid1]="$value"
  records=$(_sys_wsl_diag_enabled_service_units 2>/dev/null) || records=""
  [[ -n "$records" ]] && wsl_services=("${(@f)records}")

  _sys_wsl_read_config_text "$root/etc/wsl.conf" || read_rc=$?
  case $read_rc in
    0)
      wsl_facts[conf_state]=present
      records=$(_sys_wsl_diag_ini_records "$REPLY")
      _sys_wsl_review_index wsl.conf "$records" _SYS_WSL_CONF_SETTINGS
      ;;
    3) wsl_facts[conf_state]=absent ;;
    *)
      wsl_facts[conf_state]=unreadable
      wsl_facts[conf_reason]="${reply[1]:-it could not be read}"
      ;;
  esac

  value=$(_sys_wsl_diag_default_route_interface 2>/dev/null) || value=""
  wsl_facts[default_interface]="$value"
  if [[ -n "$value" ]]; then
    value=$(_sys_wsl_diag_interface_mtu "$value" 2>/dev/null) || value=""
    wsl_facts[default_mtu]="$value"
  fi
  if _sys_wsl_boot_mtu_pin "${wsl_values[wsl.conf:boot.command]-}"; then
    wsl_facts[pin_interface]="${reply[1]}"
    wsl_facts[pin_mtu]="${reply[2]}"
    value=$(_sys_wsl_diag_interface_mtu "${reply[1]}" 2>/dev/null) || value=""
    wsl_facts[pin_current_mtu]="$value"
  fi
  value=$(_sys_wsl_diag_resolv_conf_state 2>/dev/null) || value=""
  wsl_facts[resolv_conf]="$value"
  records=$(_sys_wsl_diag_tunnel_records 2>/dev/null) || records=""
  [[ -n "$records" ]] && wsl_tunnels=("${(@f)records}")

  # A relocated [automount] root also moves the Windows profile.
  value="${wsl_values[wsl.conf:automount.root]-}"
  [[ "$value" == /* ]] || value=""
  value=$(_sys_wsl_diag_windows_profile "$value" 2>/dev/null) \
    || profile_rc=$?
  case $profile_rc in
    0) wsl_facts[profile_path]="$value" ;;
    3) wsl_facts[profile_reason]="Windows interop is unavailable" ;;
    *) wsl_facts[profile_reason]="the Windows user profile could not be resolved" ;;
  esac
  if [[ -n "${wsl_facts[profile_path]-}" ]]; then
    wsl_facts[wslconfig_path]="${wsl_facts[profile_path]}/.wslconfig"
    read_rc=0
    _sys_wsl_read_config_text "${wsl_facts[wslconfig_path]}" || read_rc=$?
    case $read_rc in
      0)
        wsl_facts[wslconfig_state]=present
        records=$(_sys_wsl_diag_ini_records "$REPLY")
        _sys_wsl_review_index .wslconfig "$records" _SYS_WSL_WSLCONFIG_SETTINGS
        ;;
      3) wsl_facts[wslconfig_state]=absent ;;
      *)
        wsl_facts[wslconfig_state]=unreadable
        wsl_facts[wslconfig_reason]="${reply[1]:-it could not be read}"
        ;;
    esac
  fi

  # The networking mode is known only from a .wslconfig that could be read;
  # earlier WSL releases read it from [experimental].
  if [[ "${wsl_facts[generation]}" != WSL1 \
    && "${wsl_facts[wslconfig_state]-}" == (present|absent) ]]; then
    value="${wsl_values[.wslconfig:wsl2.networkingmode]-}"
    [[ -n "$value" ]] \
      || value="${wsl_values[.wslconfig:experimental.networkingmode]-}"
    if [[ -n "$value" ]]; then
      wsl_facts[networking_mode]="${(L)value}"
      wsl_facts[networking_mode_source]=wslconfig
    else
      wsl_facts[networking_mode]=nat
      wsl_facts[networking_mode_source]=default
    fi
  fi

  # The VPN suite's path MTU probe is named only when this shell knows it.
  wsl_facts[mtu_probe]=0
  if (( ${+functions[vpn-mtu-probe]} || ${+_comps[vpn-mtu-probe]} )); then
    wsl_facts[mtu_probe]=1
  fi
  return 0
}

# Usage: _sys_wsl_review_add_finding <id> <message> <remedy>
_sys_wsl_review_add_finding() {
  wsl_findings+=("$1"$'\t'"$2"$'\t'"$3")
}

# REPLY: the line numbers of one file's malformed records, joined for display
# and capped at ten. Status 1 when there are none.
_sys_wsl_review_malformed_lines() {
  emulate -L zsh
  local file_id="$1" record rest
  local -a numbers=()
  for record in "${wsl_malformed[@]}"; do
    [[ "${record%%$'\t'*}" == "$file_id" ]] || continue
    rest="${record#*$'\t'}"
    numbers+=("${rest%%$'\t'*}")
  done
  (( ${#numbers} > 0 )) || return 1
  local count="${#numbers}"
  if (( ${#numbers} > 10 )); then
    REPLY="${(j:, :)numbers[1,10]}, …"
  else
    REPLY="${(j:, :)numbers}"
  fi
  reply=("$count")
}

# Appends factual advisories to the caller's wsl_findings. Findings never
# change the exit status; they describe the configuration as read.
_sys_wsl_review_findings() {
  emulate -L zsh
  local REPLY message remedy value record iface mtu
  local -a reply=() names=()
  local conf_state="${wsl_facts[conf_state]}"
  local generation="${wsl_facts[generation]}"

  if [[ "$conf_state" == unreadable ]]; then
    _sys_wsl_review_add_finding wsl-conf-unreadable \
      "/etc/wsl.conf was not read: ${wsl_facts[conf_reason]}." \
      "Keep /etc/wsl.conf a small UTF-8 text file that your account can read."
  fi
  if _sys_wsl_review_malformed_lines wsl.conf; then
    value="$REPLY"
    _sys_count_noun "${reply[1]}" "malformed line"
    _sys_wsl_review_add_finding wsl-conf-malformed \
      "/etc/wsl.conf has $REPLY: $value." \
      "Correct or remove those lines; the review lists the reason for each."
  fi

  # appendWindowsPath stays a fact in the settings: the suites already skip
  # Windows programs on PATH, so it is not a finding.
  if [[ "$conf_state" != unreadable \
    && "${wsl_values[wsl.conf:automount.enabled]:-true}" == true ]] \
    && ! _sys_wsl_options_have_metadata \
      "${wsl_values[wsl.conf:automount.options]-}"; then
    if (( ${+wsl_values[wsl.conf:automount.options]} )); then
      remedy="Add metadata to the [automount] options on line ${wsl_lines[wsl.conf:automount.options]} of /etc/wsl.conf, then restart WSL with wsl.exe --shutdown."
    else
      remedy='Add options = "metadata,umask=22,fmask=11" under [automount] in /etc/wsl.conf, then restart WSL with wsl.exe --shutdown.'
    fi
    _sys_wsl_review_add_finding automount-metadata \
      "Windows drives are mounted without DrvFs metadata, so the File, Python, and Developer suites refuse projects on them." \
      "$remedy"
  fi

  iface="${wsl_facts[pin_interface]-}"
  if [[ -n "$iface" \
    && "${wsl_facts[pin_current_mtu]-}" != "${wsl_facts[pin_mtu]-}" ]]; then
    if [[ -n "${wsl_facts[pin_current_mtu]-}" ]]; then
      message="The [boot] command pins $iface to MTU ${wsl_facts[pin_mtu]}, but $iface reports MTU ${wsl_facts[pin_current_mtu]}."
    else
      message="The [boot] command pins $iface to MTU ${wsl_facts[pin_mtu]}, but $iface has no readable MTU."
    fi
    _sys_wsl_review_add_finding boot-mtu-mismatch "$message" \
      "WSL runs the [boot] command when the distribution starts; restart WSL with wsl.exe --shutdown, then run sys-wsl again."
  fi

  iface="${wsl_facts[default_interface]-}"
  mtu="${wsl_facts[default_mtu]-}"
  if [[ -n "$iface" && "$mtu" == <-> ]] && (( mtu >= 1500 )) \
    && (( ${#wsl_tunnels} > 0 )); then
    names=()
    for record in "${wsl_tunnels[@]}"; do
      names+=("${record%%$'\t'*} ${${record#*$'\t'}%%$'\t'*}")
    done
    _sys_count_noun "${#wsl_tunnels}" "tunnel interface"
    message="$iface uses MTU $mtu next to $REPLY (${(j:, :)names}); a lower path MTU can stall HTTPS after the TCP connect."
    if [[ "${wsl_facts[mtu_probe]}" == 1 ]]; then
      remedy="Measure the path MTU with vpn-menu vpn-mtu-probe, then pin it under [boot] in /etc/wsl.conf, for example: command = /usr/sbin/ip link set dev $iface mtu <value>"
    else
      remedy="Measure the path MTU, then pin it under [boot] in /etc/wsl.conf, for example: command = /usr/sbin/ip link set dev $iface mtu <value>"
    fi
    _sys_wsl_review_add_finding tunnel-mtu "$message" "$remedy"
  fi

  local pid1="${wsl_facts[pid1]-}" services_text=""
  if [[ "$generation" != WSL1 && -n "$pid1" && "$pid1" != systemd ]]; then
    if (( ${#wsl_services} > 0 )); then
      _sys_count_noun "${#wsl_services}" "enabled service unit"
      if (( ${#wsl_services} > 3 )); then
        services_text="$REPLY cannot start: ${(j:, :)wsl_services[1,3]}, …"
      else
        services_text="$REPLY cannot start: ${(j:, :)wsl_services}"
      fi
    fi
    if [[ "${wsl_values[wsl.conf:boot.systemd]-}" == true ]]; then
      _sys_wsl_review_add_finding systemd-not-running \
        "[boot] systemd = true, but PID 1 is $pid1${services_text:+; $services_text}." \
        "Restart WSL with wsl.exe --shutdown so that the setting takes effect."
    elif [[ -n "$services_text" && "$conf_state" != unreadable ]]; then
      _sys_wsl_review_add_finding systemd-disabled \
        "systemd is not running (PID 1 is $pid1); $services_text." \
        "Set systemd = true under [boot] in /etc/wsl.conf, then restart WSL with wsl.exe --shutdown."
    fi
  fi

  if [[ "${wsl_facts[wslconfig_state]-}" == unreadable ]]; then
    _sys_wsl_review_add_finding wslconfig-unreadable \
      ".wslconfig was not read: ${wsl_facts[wslconfig_reason]}." \
      "Save %UserProfile%\\.wslconfig as a small UTF-8 text file."
  fi
  if _sys_wsl_review_malformed_lines .wslconfig; then
    value="$REPLY"
    _sys_count_noun "${reply[1]}" "malformed line"
    _sys_wsl_review_add_finding wslconfig-malformed \
      ".wslconfig has $REPLY: $value." \
      "Correct or remove those lines; the review lists the reason for each."
  fi
  if [[ "$generation" == WSL2 \
    && "${wsl_facts[wslconfig_state]-}" == (present|absent) \
    && -z "${wsl_values[.wslconfig:wsl2.memory]-}" ]]; then
    _sys_wsl_review_add_finding no-memory-limit \
      "No memory limit is set in .wslconfig, so the WSL 2 VM can use WSL's default share of Windows memory." \
      "To cap it, set memory = <size>, such as 8GB, under [wsl2] in %UserProfile%\\.wslconfig, then restart WSL with wsl.exe --shutdown."
  fi
  return 0
}

# reply: the documented manual steps that compact the distribution's
# ext4.vhdx from Windows. The review prints them and never runs them.
_sys_wsl_compaction_steps() {
  local distribution="${1-}"
  [[ "$distribution" =~ '^[A-Za-z0-9._-]{1,64}$' ]] \
    || distribution="<distribution>"
  reply=(
    "Shut WSL down from Windows: wsl.exe --shutdown"
    "Find the folder of ext4.vhdx in PowerShell: (Get-ChildItem HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss | Where-Object { \$_.GetValue('DistributionName') -eq '$distribution' }).GetValue('BasePath')"
    "With the Hyper-V module, in an elevated PowerShell: Optimize-VHD -Path '<BasePath>\\ext4.vhdx' -Mode Full"
    "Without it, in an elevated diskpart: select vdisk file=\"<BasePath>\\ext4.vhdx\", attach vdisk readonly, compact vdisk, detach vdisk"
  )
}

# REPLY: a reviewed value for display: withheld, empty, or the value itself.
_sys_wsl_review_display_value() {
  if _sys_wsl_value_sensitive "${1-}"; then
    REPLY="[withheld: may contain a credential]"
  elif [[ -z "${1-}" ]]; then
    REPLY="(empty)"
  else
    REPLY="${1-}"
  fi
}

# Renders one file's reviewed settings, other keys, and malformed lines.
# Usage: _sys_wsl_review_render_settings <file-id> <settings-array-name>
_sys_wsl_review_render_settings() {
  emulate -L zsh
  local file_id="$1" settings_name="$2"
  local REPLY spec lookup source record rest line_number section key
  local -a spec_fields=() rows=() other_names=()
  for spec in "${(@P)settings_name}"; do
    spec_fields=("${(@s:|:)spec}")
    lookup="$file_id:${(L)spec_fields[1]}.${(L)spec_fields[2]}"
    if (( ${+wsl_values[$lookup]} )); then
      source="line ${wsl_lines[$lookup]}"
      _sys_wsl_review_display_value "${wsl_values[$lookup]}"
    elif [[ -n "${spec_fields[4]}" ]]; then
      source="default"
      REPLY="${spec_fields[4]}"
    else
      source="not set"
      REPLY="–"
    fi
    rows+=("[${spec_fields[1]}] ${spec_fields[2]}"$'\t'"$source"$'\t'"$REPLY")
  done
  for record in "${wsl_other[@]}"; do
    [[ "${record%%$'\t'*}" == "$file_id" ]] || continue
    rest="${record#*$'\t'}"
    line_number="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    section="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    key="${rest%%$'\t'*}"
    _sys_wsl_review_display_value "${rest#*$'\t'}"
    rows+=("[$section] $key"$'\t'"line $line_number"$'\t'"$REPLY")
    other_names+=("[$section] $key")
  done
  _sys_table $'Setting\tSource\tValue' "${rows[@]}"
  if (( ${#other_names} > 0 )); then
    _sys_dim "Listed as written and not reviewed: ${(j:, :)other_names}."
  fi

  local -i shown=0 total=0
  for record in "${wsl_malformed[@]}"; do
    [[ "${record%%$'\t'*}" == "$file_id" ]] || continue
    (( ++total ))
    (( total <= 20 )) || continue
    rest="${record#*$'\t'}"
    _sys_dim "Line ${rest%%$'\t'*}: malformed (${rest#*$'\t'})"
    (( ++shown ))
  done
  if (( total > shown )); then
    _sys_count_noun "$(( total - shown ))" "malformed line"
    _sys_dim "… and $REPLY more"
  fi
}

# Renders the review on stderr from the caller's review state.
_sys_wsl_review_render() {
  emulate -L zsh
  local REPLY value record rest
  local -a reply=() names=()

  _sys_header "WSL Configuration Review"
  _sys_section --first "Distribution"
  _sys_label "Generation:" "${wsl_facts[generation]:-unknown}"
  _sys_label "Kernel:" "${wsl_facts[kernel]:-unknown}"
  _sys_label "Distribution:" "${wsl_facts[distribution]:-unknown}"
  _sys_label "OS:" "${wsl_facts[os]:-unknown}"
  _sys_label "PID 1:" "${wsl_facts[pid1]:-unknown}"

  _sys_section "/etc/wsl.conf"
  case "${wsl_facts[conf_state]}" in
    present)
      _sys_wsl_review_render_settings wsl.conf _SYS_WSL_CONF_SETTINGS
      ;;
    absent)
      _sys_dim "Not present; WSL defaults apply."
      _sys_wsl_review_render_settings wsl.conf _SYS_WSL_CONF_SETTINGS
      ;;
    *)
      _sys_dim "Not read: ${wsl_facts[conf_reason]}."
      ;;
  esac

  _sys_section "Network"
  _sys_label "Default route:" "${wsl_facts[default_interface]:-unavailable}"
  _sys_label "Interface MTU:" "${wsl_facts[default_mtu]:-unavailable}"
  if [[ -n "${wsl_facts[pin_interface]-}" ]]; then
    _sys_label "Boot MTU pin:" \
      "${wsl_facts[pin_interface]} → ${wsl_facts[pin_mtu]} ([boot] command)"
  else
    _sys_label "Boot MTU pin:" "none"
  fi
  case "${wsl_facts[resolv_conf]-}" in
    generated) value="generated by WSL" ;;
    custom)    value="custom" ;;
    *)         value="unavailable" ;;
  esac
  _sys_label "resolv.conf:" "$value"
  if [[ "${wsl_facts[generation]}" == WSL1 ]]; then
    value="not applicable on WSL 1"
  else
    case "${wsl_facts[networking_mode_source]-}" in
      default)   value="NAT (default)" ;;
      wslconfig) value="${wsl_facts[networking_mode]} (.wslconfig)" ;;
      *)         value="unknown (.wslconfig not read)" ;;
    esac
  fi
  _sys_label "Networking mode:" "$value"
  names=()
  for record in "${wsl_tunnels[@]}"; do
    rest="${record#*$'\t'}"
    value="${record%%$'\t'*} (${rest%%$'\t'*}"
    [[ -n "${rest#*$'\t'}" ]] && value+=", MTU ${rest#*$'\t'}"
    names+=("$value)")
  done
  if (( ${#names} > 0 )); then
    _sys_label "Tunnels:" "${(j:, :)names}"
  else
    _sys_label "Tunnels:" "none"
  fi

  _sys_section "Windows .wslconfig"
  if [[ -n "${wsl_facts[profile_path]-}" ]]; then
    _sys_label "Profile:" "${wsl_facts[profile_path]}"
    _sys_label "File:" "${wsl_facts[wslconfig_path]}"
    case "${wsl_facts[wslconfig_state]-}" in
      present)
        _sys_wsl_review_render_settings .wslconfig _SYS_WSL_WSLCONFIG_SETTINGS
        ;;
      absent)
        _sys_dim "Not present; WSL defaults apply."
        ;;
      *)
        _sys_dim "Not read: ${wsl_facts[wslconfig_reason]}."
        ;;
    esac
    [[ "${wsl_facts[generation]}" == WSL1 ]] \
      && _sys_dim ".wslconfig settings apply to WSL 2 distributions only."
  else
    _sys_label "Profile:" "unavailable (${wsl_facts[profile_reason]})"
    _sys_dim "Windows-side settings were not read."
  fi

  _sys_section "Virtual disk"
  _sys_dim "Linux cannot read the size of ext4.vhdx reliably; the review runs none of these steps."
  _sys_dim "To compact the disk, from Windows:"
  _sys_wsl_compaction_steps "${wsl_facts[distribution]}"
  local -i step_index=0
  for value in "${reply[@]}"; do
    _sys_dim "$(( ++step_index )). $value"
  done

  local message remedy
  if (( ${#wsl_findings} > 0 )); then
    _sys_section "Findings"
    for record in "${wsl_findings[@]}"; do
      rest="${record#*$'\t'}"
      message="${rest%%$'\t'*}"
      remedy="${rest#*$'\t'}"
      _sys_warn "$message"
      _sys_dim "$remedy"
    done
    _sys_blank
    _sys_count_noun "${#wsl_findings}" finding
    _sys_warn "WSL review: $REPLY — review the output above."
  else
    _sys_blank
    _sys_success "WSL review: no findings."
  fi
}

# stdout TSV rows for JSON: section, key, kind, state, value for each
# reviewed setting of one file, with state set, unset, or withheld.
_sys_wsl_review_json_settings() {
  emulate -L zsh
  local file_id="$1" settings_name="$2" REPLY spec lookup snake_section
  local -a spec_fields=()
  for spec in "${(@P)settings_name}"; do
    spec_fields=("${(@s:|:)spec}")
    lookup="$file_id:${(L)spec_fields[1]}.${(L)spec_fields[2]}"
    _sys_wsl_snake_case "${spec_fields[1]}"
    snake_section="$REPLY"
    _sys_wsl_snake_case "${spec_fields[2]}"
    if (( ! ${+wsl_values[$lookup]} )); then
      print -r -- "$snake_section"$'\t'"$REPLY"$'\t'"${spec_fields[3]}"$'\t'unset$'\t'
    elif _sys_wsl_value_sensitive "${wsl_values[$lookup]}"; then
      print -r -- "$snake_section"$'\t'"$REPLY"$'\t'"${spec_fields[3]}"$'\t'withheld$'\t'
    else
      print -r -- "$snake_section"$'\t'"$REPLY"$'\t'"${spec_fields[3]}"$'\t'set$'\t'"${wsl_values[$lookup]}"
    fi
  done
}

# stdout TSV rows for JSON: line, section, key, value, withheld (0 or 1) for
# one file's other keys.
_sys_wsl_review_json_other() {
  emulate -L zsh
  local file_id="$1" record rest line_number section key value
  for record in "${wsl_other[@]}"; do
    [[ "${record%%$'\t'*}" == "$file_id" ]] || continue
    rest="${record#*$'\t'}"
    line_number="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    section="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    key="${rest%%$'\t'*}"
    value="${rest#*$'\t'}"
    if _sys_wsl_value_sensitive "$value"; then
      print -r -- "$line_number"$'\t'"$section"$'\t'"$key"$'\t'$'\t'1
    else
      print -r -- "$line_number"$'\t'"$section"$'\t'"$key"$'\t'"$value"$'\t'0
    fi
  done
}

# stdout TSV rows for JSON: line, reason for one file's malformed lines.
_sys_wsl_review_json_malformed() {
  emulate -L zsh
  local file_id="$1" record
  for record in "${wsl_malformed[@]}"; do
    [[ "${record%%$'\t'*}" == "$file_id" ]] || continue
    print -r -- "${record#*$'\t'}"
  done
}

# Prints the zdx.sys-wsl.v1 document for the caller's review state. Every
# value reaches jq through --arg; TSV rows hold only fields that cannot
# contain a TAB or newline.
_sys_wsl_review_json() {
  emulate -L zsh
  local REPLY document metadata=""
  local -a reply=()
  if [[ "${wsl_facts[conf_state]}" != unreadable ]]; then
    if _sys_wsl_options_have_metadata \
      "${wsl_values[wsl.conf:automount.options]-}"; then
      metadata=true
    else
      metadata=false
    fi
  fi
  _sys_wsl_compaction_steps "${wsl_facts[distribution]}"

  document=$(_sys_jq \
    --arg generation "${wsl_facts[generation]-}" \
    --arg kernel "${wsl_facts[kernel]-}" \
    --arg distribution "${wsl_facts[distribution]-}" \
    --arg os "${wsl_facts[os]-}" \
    --arg pid1 "${wsl_facts[pid1]-}" \
    --arg services "${(F)wsl_services}" \
    --arg conf_state "${wsl_facts[conf_state]-}" \
    --arg conf_reason "${wsl_facts[conf_reason]-}" \
    --arg conf_settings "$(_sys_wsl_review_json_settings wsl.conf _SYS_WSL_CONF_SETTINGS)" \
    --arg conf_other "$(_sys_wsl_review_json_other wsl.conf)" \
    --arg conf_malformed "$(_sys_wsl_review_json_malformed wsl.conf)" \
    --arg metadata "$metadata" \
    --arg default_interface "${wsl_facts[default_interface]-}" \
    --arg default_mtu "${wsl_facts[default_mtu]-}" \
    --arg pin_interface "${wsl_facts[pin_interface]-}" \
    --arg pin_mtu "${wsl_facts[pin_mtu]-}" \
    --arg pin_current_mtu "${wsl_facts[pin_current_mtu]-}" \
    --arg resolv_conf "${wsl_facts[resolv_conf]-}" \
    --arg networking_mode "${wsl_facts[networking_mode]-}" \
    --arg networking_mode_source "${wsl_facts[networking_mode_source]-}" \
    --arg tunnels "${(F)wsl_tunnels}" \
    --arg profile_path "${wsl_facts[profile_path]-}" \
    --arg profile_reason "${wsl_facts[profile_reason]-}" \
    --arg wslconfig_path "${wsl_facts[wslconfig_path]-}" \
    --arg wslconfig_state "${wsl_facts[wslconfig_state]-}" \
    --arg wslconfig_reason "${wsl_facts[wslconfig_reason]-}" \
    --arg wslconfig_settings "$(_sys_wsl_review_json_settings .wslconfig _SYS_WSL_WSLCONFIG_SETTINGS)" \
    --arg wslconfig_other "$(_sys_wsl_review_json_other .wslconfig)" \
    --arg wslconfig_malformed "$(_sys_wsl_review_json_malformed .wslconfig)" \
    --arg steps "${(F)reply}" \
    --arg findings "${(F)wsl_findings}" \
    "$_SYS_JSON_DEFS"'
    def setting_value:
      if .[3] != "set" then null
      elif .[2] == "bool" then (.[4] | flag)
      elif .[2] == "count" then (.[4] | num)
      else .[4] end;
    def settings: rows | reduce .[] as $row ({};
      .[$row[0]] = ((.[$row[0]] // {}) + {($row[1]): ($row | setting_value)}));
    def withheld: rows | map(select(.[3] == "withheld") | "[\(.[0])] \(.[1])");
    def other_keys: rows | map({line: (.[0] | num), section: .[1], key: .[2],
      value: (if .[4] == "1" then null else .[3] end), withheld: (.[4] == "1")});
    def malformed: rows | map({line: (.[0] | num), reason: .[1]});
    {
      schema: "zdx.sys-wsl.v1",
      applicable: true,
      host: {
        generation: ($generation | str),
        kernel: ($kernel | str),
        distribution: ($distribution | str),
        os: ($os | str),
        pid1: ($pid1 | str),
        systemd_pid1: (if $pid1 == "" then null else ($pid1 == "systemd") end),
        enabled_service_units: ($services | lines)
      },
      wsl_conf: {
        path: "/etc/wsl.conf",
        state: ($conf_state | str),
        reason: ($conf_reason | str),
        settings: (($conf_settings | settings)
          | .automount.metadata = ($metadata | flag)),
        withheld_keys: ($conf_settings | withheld),
        other_keys: ($conf_other | other_keys),
        malformed_lines: ($conf_malformed | malformed)
      },
      network: {
        default_interface: ($default_interface | str),
        default_interface_mtu: ($default_mtu | num),
        boot_mtu_pin: (if $pin_interface == "" then null else {
          interface: $pin_interface,
          mtu: ($pin_mtu | num),
          current_mtu: ($pin_current_mtu | num)
        } end),
        resolv_conf: ($resolv_conf | str),
        networking_mode: ($networking_mode | str),
        networking_mode_source: ($networking_mode_source | str),
        tunnel_interfaces: ($tunnels | rows
          | map({name: .[0], kind: .[1], mtu: (.[2] | num)}))
      },
      windows: {
        profile_path: ($profile_path | str),
        reason: ($profile_reason | str),
        wslconfig: {
          path: ($wslconfig_path | str),
          state: (if $wslconfig_state == "" then "unavailable"
            else $wslconfig_state end),
          reason: ($wslconfig_reason | str),
          settings: ($wslconfig_settings | settings),
          withheld_keys: ($wslconfig_settings | withheld),
          other_keys: ($wslconfig_other | other_keys),
          malformed_lines: ($wslconfig_malformed | malformed)
        }
      },
      disk: {
        vhdx_size_bytes: null,
        compaction_steps: ($steps | lines)
      },
      findings: ($findings | rows
        | map({id: .[0], message: .[1], remedy: .[2]}))
    }') || {
    _sys_error "jq could not build the sys-wsl JSON document."
    return 1
  }
  print -r -- "$document"
}

sys-wsl() {
  local -i json=0
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! json )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        _sys_wsl_usage
        return 0
        ;;
      --json)
        (( ! json )) || {
          _sys_error "--json was given more than once."
          return 2
        }
        json=1
        ;;
      -*)
        _sys_error "Unknown option: $1"
        return 2
        ;;
      *)
        _sys_error "sys-wsl accepts no positional arguments."
        return 2
        ;;
    esac
    shift
  done

  if (( json )); then
    _sys_json_require || return 1
  fi
  _sys_capabilities_refresh_for_command || {
    _sys_error "Unable to detect host capabilities."
    return 1
  }

  local reason="not a WSL host"
  if ! _sys_has_capability "environment:wsl"; then
    if (( json )); then
      local document
      document=$(_sys_jq --arg reason "$reason" \
        '{schema: "zdx.sys-wsl.v1", applicable: false, reason: $reason}') \
        || return 1
      print -r -- "$document"
    fi
    _sys_report_not_applicable sys-wsl "$reason"
    return
  fi

  local -A wsl_facts=() wsl_values=() wsl_lines=()
  local -a wsl_other=() wsl_malformed=() wsl_tunnels=() wsl_services=()
  local -a wsl_findings=()
  _sys_wsl_review_collect || return 1
  _sys_wsl_review_findings || return 1
  if (( json )); then
    _sys_wsl_review_json
    return
  fi
  _sys_wsl_review_render
  return 0
}

typeset -g _SYS_WSL_CONFIG_SOURCED=1
