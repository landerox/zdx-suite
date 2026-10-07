#!/usr/bin/env zsh
# =============================================================================
# VPN Path MTU: don't-fragment probe, egress and tunnel MTUs, and advice
# =============================================================================
#
# Loaded by vpn-menu.zsh after vpn-common.zsh.
# Safe to re-source; defines functions only.
#
# The probe is read-only and unprivileged. It sends a bounded number of
# don't-fragment ICMP echo requests to one validated IPv4 target and reads the
# route and interface MTUs that any account can read. It never calls sudo,
# never opens a profile file, and never applies what it recommends: every
# command it prints is text for the user to review.
#

if [[ -n "${_VPN_MTU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Fixed suite limits, not configuration. One external program runs for at
# most _VPN_MTU_PROBE_SECONDS; no ping starts once it could end after
# _VPN_MTU_BUDGET_SECONDS; and no run sends more than _VPN_MTU_MAX_PROBES.
typeset -gi _VPN_MTU_PROBE_SECONDS=3
typeset -gi _VPN_MTU_BUDGET_SECONDS=15
typeset -gi _VPN_MTU_MAX_PROBES=16

# A silent failure (no reply) may be a lost reply rather than a packet that
# is too large. One that would discard more than this many payload sizes from
# the search is retried at once; a smaller one is retried before it decides
# the result. Retries count toward the probe and time limits.
typeset -gi _VPN_MTU_RETRY_SPAN=32

# IPv4 payload bounds: ping's default 56 bytes answers "is it reachable", 1472
# fills a 1500-byte packet when the egress MTU is unknown, and 8972 fills a
# 9000-byte jumbo frame. The IPv4 header (20) and the ICMP echo header (8)
# make path MTU = payload + 28.
typeset -gi _VPN_MTU_MIN_PAYLOAD=56
typeset -gi _VPN_MTU_DEFAULT_PAYLOAD=1472
typeset -gi _VPN_MTU_MAX_PAYLOAD=8972
typeset -gi _VPN_MTU_IPV4_OVERHEAD=28

# WireGuard adds an outer IP header, UDP (8), and its own 32 bytes: 80 bytes
# over IPv6 (40-byte header), 60 over IPv4 (20). wg-quick's default 1420 is
# 1500 - 80.
typeset -gi _VPN_MTU_WG_OVERHEAD_IPV6=80
typeset -gi _VPN_MTU_WG_OVERHEAD_IPV4=60

typeset -g _VPN_MTU_DEFAULT_TARGET=1.1.1.1
typeset -g _VPN_MTU_SCHEMA=zdx.vpn-mtu-probe.v1

# --- Validation -------------------------------------------------------------

# True for a dotted-quad IPv4 literal. Leading zeros are refused because
# inet_aton, and therefore ping, would read them as octal.
_vpn_mtu_ipv4_literal() {
  emulate -L zsh
  local address="${1:-}"
  local -a octets=("${(@s:.:)address}")
  (( ${#octets[@]} == 4 )) || return 1
  local octet
  for octet in "${octets[@]}"; do
    [[ "$octet" == (0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ]] || return 1
    (( octet <= 255 )) || return 1
  done
}

# A target is an IPv4 literal or a DNS host name of letters, digits, and
# hyphens whose last label starts with a letter. No accepted value can be read
# as an option, shell text, an IPv6 literal, or a numeric address in another
# notation, and it reaches ping only as one argument after `--`. Bracket globs
# compare code points, so no locale widens the accepted set.
_vpn_mtu_validate_target() {
  emulate -L zsh
  local target="${1:-}"
  [[ -n "$target" && ${#target} -le 253 ]] || return 1
  _vpn_mtu_ipv4_literal "$target" && return 0

  local -a labels=("${(@s:.:)target}")
  local label
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 \
      && "$label" == [A-Za-z0-9]* && "$label" == *[A-Za-z0-9] \
      && "$label" != *[^A-Za-z0-9-]* ]] || return 1
  done
  [[ "${labels[-1]}" == [A-Za-z]* ]]
}

# Interface names come from route and tool output. They are displayed and
# passed back to ip or ifconfig as one argument, so only plain names pass.
_vpn_mtu_validate_device() {
  emulate -L zsh
  local device="${1:-}"
  [[ -n "$device" && ${#device} -le 32 && "$device" == [A-Za-z0-9]* \
    && "$device" != *[^A-Za-z0-9._-]* ]]
}

# --- Bounded collection -----------------------------------------------------

# Adds the run time of one bounded program, started at <start>, to the
# caller's mtu[spent]. The reading comes from the wall clock, which can jump,
# as it does when WSL resynchronizes with Windows; a negative or impossible
# reading counts the whole deadline and kill grace, so the time budget can
# overestimate but never underestimate what ran.
_vpn_mtu_account() {
  (( ${+mtu} )) || return 0
  local -F spent=$(( ${EPOCHREALTIME:-$SECONDS} - $1 ))
  local -F ceiling=$(( _VPN_MTU_PROBE_SECONDS + 2 ))
  (( spent >= 0 && spent <= ceiling )) || spent=$ceiling
  mtu[spent]=$(( ${mtu[spent]:-0} + spent ))
}

# REPLY: the output of one bounded external program, at most 4 KiB. With
# `all`, stderr is included, because ping reports refusals there; with `out`,
# stderr is discarded. The status is the program's, 124 on timeout.
# Usage: _vpn_mtu_capture all|out <program> [argument...]
_vpn_mtu_capture() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local streams="$1"
  shift
  REPLY=""
  local captured="" started="${EPOCHREALTIME:-$SECONDS}"
  local -i capture_status=0
  if [[ "$streams" == all ]]; then
    captured=$(
      _vpn_run_with_timeout "$_VPN_MTU_PROBE_SECONDS" "$@" </dev/null 2>&1 \
        | command head -c 4096
    ) || capture_status=$?
  else
    captured=$(
      _vpn_run_with_timeout "$_VPN_MTU_PROBE_SECONDS" "$@" \
        </dev/null 2>/dev/null | command head -c 4096
    ) || capture_status=$?
  fi
  _vpn_mtu_account "$started"
  REPLY="$captured"
  return "$capture_status"
}

# reply: the argv of one don't-fragment probe of <payload> bytes. Linux and
# WSL use iputils ping (-M do; -W waits one second for the reply); macOS uses
# BSD ping (-D; -t ends it after one second). Both stay numeric and IPv4.
_vpn_mtu_ping_argv() {
  local payload="$1" target="$2"
  if [[ "$_VPN_PLATFORM" == darwin ]]; then
    reply=(ping -n -c 1 -t 1 -D -s "$payload" -- "$target")
  else
    reply=(ping -4 -n -c 1 -W 1 -M do -s "$payload" -- "$target")
  fi
}

# Status 0 when ping supports the don't-fragment probe. On Linux and WSL only
# iputils ping does: BusyBox and GNU inetutils ping have no `-M do`.
_vpn_mtu_ping_capable() {
  [[ "$_VPN_PLATFORM" == darwin ]] && return 0
  local REPLY=""
  local -i version_status=0
  _vpn_mtu_capture all ping -V || version_status=$?
  (( version_status == 130 || version_status == 143 )) \
    && return "$version_status"
  [[ "$REPLY" == *iputils* ]]
}

# REPLY: why the reachability probe failed: unsupported, permission, resolve,
# timeout, or silent. Usage: _vpn_mtu_failure_kind <status> <output>
_vpn_mtu_failure_kind() {
  emulate -L zsh
  local -i probe_status="$1"
  local output="${(L)2}"
  REPLY=silent
  if (( probe_status == 124 )); then
    REPLY=timeout
  elif [[ "$output" == *(invalid|illegal|unrecognized|unknown)\ option* \
    || "$output" == *usage:* ]]; then
    REPLY=unsupported
  elif [[ "$output" == *(operation\ not\ permitted|permission\ denied)* ]]; then
    REPLY=permission
  elif [[ "$output" == *(unknown\ host|name\ or\ service\ not\ known|temporary\ failure\ in\ name\ resolution|cannot\ resolve|nodename\ nor\ servname)* ]]; then
    REPLY=resolve
  fi
}

# REPLY: the MTU a failed probe reported, from iputils' "message too long,
# mtu=1392" or "Frag needed and DF set (mtu = 1392)". It only orders the next
# probe; every value is still measured.
_vpn_mtu_failure_hint() {
  emulate -L zsh
  local output="$1"
  local -a match=() mbegin=() mend=()
  REPLY=""
  [[ "$output" =~ 'mtu ?= ?([0-9]{2,5})' ]] || return 1
  REPLY="${match[1]}"
}

# True when a failed probe carries explicit evidence that the packet was too
# large: a local EMSGSIZE ("message too long", iputils and BSD ping) or an
# ICMP "fragmentation needed" report, with or without its MTU. Such a failure
# is definitive; a silent one (no reply, or the deadline) may be a lost reply.
_vpn_mtu_failure_explicit() {
  emulate -L zsh
  local output="${(L)1}"
  [[ "$output" == *(message\ too\ long|frag\ needed|fragmentation\ needed)* \
    || "$output" =~ 'mtu ?= ?[0-9]' ]]
}

# REPLY: the IPv4 address ping resolved, from its first line: iputils prints
# "PING host (address) ..." and BSD ping "PING host (address): ...".
_vpn_mtu_resolved_address() {
  emulate -L zsh
  local output="$1" line="" candidate=""
  REPLY=""
  for line in "${(@f)output}"; do
    [[ "$line" == PING\ *\(*\)* ]] || continue
    candidate="${line#*\(}"
    candidate="${candidate%%\)*}"
    _vpn_mtu_ipv4_literal "$candidate" || return 1
    REPLY="$candidate"
    return 0
  done
  return 1
}

# REPLY: the interface the route to <address> leaves through: `dev` in
# `ip -4 route get` on Linux and WSL, `interface:` in `route -n get` on macOS.
_vpn_mtu_egress_device() {
  local address="$1"
  REPLY=""
  _vpn_mtu_ipv4_literal "$address" || return 1
  local device=""
  local -a words=()
  if [[ "$_VPN_PLATFORM" == darwin ]]; then
    _vpn_check_cmd route || return 1
    _vpn_mtu_capture out route -n get "$address" || return 1
    local line=""
    for line in "${(@f)REPLY}"; do
      words=(${=line})
      [[ "${words[1]-}" == interface: ]] || continue
      device="${words[2]-}"
      break
    done
  else
    _vpn_check_cmd ip || return 1
    _vpn_mtu_capture out ip -4 route get "$address" || return 1
    words=(${=REPLY})
    local -i index=${words[(i)dev]}
    device="${words[index + 1]-}"
  fi
  REPLY=""
  _vpn_mtu_validate_device "$device" || return 1
  REPLY="$device"
}

# REPLY: the MTU of <device> from `ip -o link show dev` on Linux and WSL or
# `ifconfig` on macOS; both answer without privileges.
_vpn_mtu_device_mtu() {
  local device="$1"
  REPLY=""
  _vpn_mtu_validate_device "$device" || return 1
  if [[ "$_VPN_PLATFORM" == darwin ]]; then
    _vpn_check_cmd ifconfig || return 1
    _vpn_mtu_capture out ifconfig "$device" || return 1
  else
    _vpn_check_cmd ip || return 1
    _vpn_mtu_capture out ip -o link show dev "$device" || return 1
  fi
  local -a words=(${=${REPLY%%$'\n'*}})
  local -i index=${words[(i)mtu]}
  local value="${words[index + 1]-}"
  REPLY=""
  [[ ${#value} -le 5 && "$value" == <68-65536> ]] || return 1
  REPLY="$(( 10#$value ))"
}

# reply: the WireGuard devices `wg show interfaces` lists for this account.
# Status 1 when wg is missing or the listing fails; it never retries through
# sudo, unlike the tunnel commands.
_vpn_mtu_wireguard_devices() {
  reply=()
  _vpn_check_cmd wg || return 1
  local REPLY=""
  _vpn_mtu_capture out wg show interfaces || return 1
  local device
  for device in ${=REPLY}; do
    _vpn_mtu_validate_device "$device" || continue
    reply+=("$device")
    (( ${#reply[@]} < _VPN_MAX_ACTIVE_INTERFACES )) || break
  done
  return 0
}

# REPLY: wsl1 or wsl2. WSL1 reports a synthetic kernel release ending in
# -Microsoft and shares the Windows network stack; later kernels run in the
# WSL2 virtual machine with their own eth0.
_vpn_mtu_wsl_generation() {
  local release=""
  if [[ -r /proc/sys/kernel/osrelease ]]; then
    release=$(</proc/sys/kernel/osrelease) 2>/dev/null || release=""
  fi
  [[ -n "$release" ]] \
    || release=$(command uname -r 2>/dev/null) || release=""
  if [[ "$release" == *-Microsoft ]]; then
    REPLY=wsl1
  else
    REPLY=wsl2
  fi
}

# --- Measurement ------------------------------------------------------------

# REPLY: seconds since <start>, from EPOCHREALTIME when zsh/datetime provides
# it and SECONDS otherwise.
_vpn_mtu_elapsed() {
  local start="$1" now="${EPOCHREALTIME:-$SECONDS}"
  local -F elapsed=$(( now - start ))
  (( elapsed >= 0 )) || elapsed=0
  REPLY="$elapsed"
}

# True when another probe may start: the count is below the limit and the
# probe would end inside the time budget, measured as the accounted run time
# of every bounded program so far. Reads the caller's mtu map.
_vpn_mtu_may_probe() {
  if (( mtu[probes] >= _VPN_MTU_MAX_PROBES )); then
    mtu[stopped]=limit
    return 1
  fi
  if (( ${mtu[spent]:-0} + _VPN_MTU_PROBE_SECONDS > _VPN_MTU_BUDGET_SECONDS )); then
    mtu[stopped]=budget
    return 1
  fi
  return 0
}

# One don't-fragment probe of <payload> bytes to the caller's target. Status 0
# when the echo returned; REPLY holds the bounded output.
_vpn_mtu_probe() {
  local payload="$1"
  local -a reply=()
  _vpn_mtu_ping_argv "$payload" "${mtu[probe_target]}"
  mtu[probes]=$(( mtu[probes] + 1 ))
  _vpn_mtu_capture all "${reply[@]}"
}

# One search probe of <payload>, whose failure would discard <span> sizes.
# An explicit failure is final and marked in the caller's `confirmed` map. A
# silent failure spanning more than _VPN_MTU_RETRY_SPAN sizes is retried at
# once, when the limits allow; a smaller one stays unconfirmed until the
# search verifies it. Status 0 passed, 1 failed, 130 or 143 interrupted;
# REPLY holds the last output.
_vpn_mtu_search_probe() {
  local payload="$1" span="$2"
  local -i probe_rc=0
  _vpn_mtu_probe "$payload" || probe_rc=$?
  (( probe_rc == 0 || probe_rc == 130 || probe_rc == 143 )) \
    && return "$probe_rc"
  if _vpn_mtu_failure_explicit "$REPLY"; then
    confirmed[$payload]=1
    return 1
  fi
  if (( span > _VPN_MTU_RETRY_SPAN )) && _vpn_mtu_may_probe; then
    probe_rc=0
    _vpn_mtu_probe "$payload" || probe_rc=$?
    (( probe_rc == 0 || probe_rc == 130 || probe_rc == 143 )) \
      && return "$probe_rc"
    confirmed[$payload]=1
  fi
  return 1
}

# Fills the caller's `mtu` map: capability, reachability, the route, the
# WireGuard devices, and the largest payload that passes. The search first
# tries the largest packet the egress interface can send, so a healthy path
# costs two probes, then bisects, trying the MTU a failed probe reported
# first. Silent failures are retried as _vpn_mtu_search_probe describes, and
# the result is exact only when its bounding failure is final. Status 1 when
# nothing could be measured; 130 or 143 when interrupted.
_vpn_mtu_measure() {
  local REPLY=""
  local -a reply=()
  local -i probe_status=0

  if ! _vpn_check_cmd ping; then
    mtu[supported]=false
    mtu[reason]="ping is not installed"
    return 1
  fi
  _vpn_mtu_ping_capable || probe_status=$?
  (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
  if (( probe_status != 0 )); then
    mtu[supported]=false
    mtu[reason]="ping cannot send don't-fragment probes; iputils ping is required on Linux and WSL"
    return 1
  fi
  mtu[supported]=true

  # Reachability: a small packet that fits every path. A silent failure is
  # retried once, because one lost reply must not read as unreachable.
  mtu[probe_target]="${mtu[target]}"
  probe_status=0
  _vpn_mtu_probe "$_VPN_MTU_MIN_PAYLOAD" || probe_status=$?
  (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
  local probe_output="$REPLY"
  if (( probe_status != 0 )); then
    _vpn_mtu_failure_kind "$probe_status" "$probe_output"
    if [[ "$REPLY" == (silent|timeout) ]] && _vpn_mtu_may_probe; then
      probe_status=0
      _vpn_mtu_probe "$_VPN_MTU_MIN_PAYLOAD" || probe_status=$?
      (( probe_status == 130 || probe_status == 143 )) \
        && return "$probe_status"
      probe_output="$REPLY"
    fi
  fi
  if (( probe_status != 0 )); then
    _vpn_mtu_failure_kind "$probe_status" "$probe_output"
    case "$REPLY" in
      unsupported)
        mtu[supported]=false
        mtu[reason]="ping rejected the don't-fragment options"
        ;;
      permission)
        mtu[supported]=false
        mtu[reason]="ping is not permitted to send ICMP from this account"
        ;;
      resolve)
        mtu[reachable]=false
        mtu[reason]="could not resolve ${mtu[target]}"
        ;;
      timeout)
        mtu[reachable]=false
        _vpn_count_noun "$_VPN_MTU_PROBE_SECONDS" second
        mtu[reason]="no reply within $REPLY"
        ;;
      *)
        mtu[reachable]=false
        mtu[reason]="no reply to a ${_VPN_MTU_MIN_PAYLOAD}-byte ping"
        ;;
    esac
    return 1
  fi
  mtu[reachable]=true

  # Later probes and the route use the resolved address, so a host name is
  # looked up once and every probe measures the same path.
  if _vpn_mtu_ipv4_literal "${mtu[target]}"; then
    mtu[address]="${mtu[target]}"
  elif _vpn_mtu_resolved_address "$probe_output"; then
    mtu[address]="$REPLY"
  fi
  [[ -n "${mtu[address]}" ]] && mtu[probe_target]="${mtu[address]}"

  if [[ -n "${mtu[address]}" ]] && _vpn_mtu_egress_device "${mtu[address]}"; then
    mtu[egress_interface]="$REPLY"
    _vpn_mtu_device_mtu "$REPLY" && mtu[egress_mtu]="$REPLY"
  fi

  # Tunnel context from the unprivileged device list. A profile names a
  # device only on Linux and WSL; macOS devices are utunN.
  if _vpn_mtu_wireguard_devices; then
    local -a wg_devices=("${reply[@]}")
    if [[ -n "${mtu[egress_interface]}" ]]; then
      if (( ${wg_devices[(Ie)${mtu[egress_interface]}]} )); then
        mtu[through_tunnel]=true
        mtu[tunnel_interface]="${mtu[egress_interface]}"
      else
        mtu[through_tunnel]=false
      fi
    fi
    if [[ -z "${mtu[tunnel_interface]}" && -n "${mtu[profile]}" \
      && "$_VPN_PLATFORM" != darwin ]] \
      && (( ${wg_devices[(Ie)${mtu[profile]}]} )); then
      mtu[tunnel_interface]="${mtu[profile]}"
    fi
    if [[ -z "${mtu[tunnel_interface]}" ]] && (( ${#wg_devices[@]} > 0 )); then
      mtu[tunnel_interface]="${wg_devices[1]}"
    fi
    if [[ -n "${mtu[tunnel_interface]}" ]] \
      && _vpn_mtu_device_mtu "${mtu[tunnel_interface]}"; then
      mtu[tunnel_mtu]="$REPLY"
    fi
  else
    mtu[wg_unavailable]=1
  fi

  # The largest payload the egress interface can send. Don't Fragment makes a
  # larger one fail locally, so the path MTU never exceeds the egress MTU.
  local -i passed=$_VPN_MTU_MIN_PAYLOAD failed=0 upper=$_VPN_MTU_DEFAULT_PAYLOAD
  local -i upper_is_egress=0 next=0 mid=0 hinted=0
  if [[ -n "${mtu[egress_mtu]}" ]]; then
    upper=$(( mtu[egress_mtu] - _VPN_MTU_IPV4_OVERHEAD ))
    if (( upper > _VPN_MTU_MAX_PAYLOAD )); then
      upper=$_VPN_MTU_MAX_PAYLOAD
    else
      upper_is_egress=1
    fi
  fi
  (( upper > passed )) || upper=$passed

  # Failing payloads, and those whose failure is final (explicit evidence or
  # a failed retry). A lost reply found late resumes above it.
  local -A confirmed=()
  local -a failures=()
  local -i failure=0

  # A silent failure of the first large probe is verified only if it ends up
  # bounding the result, which then costs one probe.
  if (( upper > passed )) && _vpn_mtu_may_probe; then
    probe_status=0
    _vpn_mtu_search_probe "$upper" 0 || probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    if (( probe_status == 0 )); then
      passed=$upper
    else
      failed=$upper
      failures+=("$upper")
      _vpn_mtu_failure_hint "$REPLY" && next=$(( REPLY - _VPN_MTU_IPV4_OVERHEAD ))
    fi
  fi

  while (( failed > 0 )); do
    while (( failed - passed > 1 )) && _vpn_mtu_may_probe; do
      if (( next > passed && next < failed )); then
        mid=$next
        hinted=1
      else
        mid=$(( (passed + failed) / 2 ))
        hinted=0
      fi
      next=0
      probe_status=0
      _vpn_mtu_search_probe "$mid" $(( failed - mid )) || probe_status=$?
      (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
      if (( probe_status == 0 )); then
        passed=$mid
        # A reported MTU that passed is confirmed by one byte more failing.
        (( hinted )) && next=$(( mid + 1 ))
      else
        failed=$mid
        failures+=("$mid")
        _vpn_mtu_failure_hint "$REPLY" \
          && next=$(( REPLY - _VPN_MTU_IPV4_OVERHEAD ))
      fi
    done

    # The failure that bounds the result must be final: an unconfirmed one is
    # retried once. When it passes now, its reply had been lost, and the
    # search resumes up to the next larger failure.
    (( failed - passed == 1 )) || break
    (( ${+confirmed[$failed]} )) && break
    _vpn_mtu_may_probe || break
    probe_status=0
    _vpn_mtu_probe "$failed" || probe_status=$?
    (( probe_status == 130 || probe_status == 143 )) && return "$probe_status"
    if (( probe_status != 0 )); then
      confirmed[$failed]=1
      break
    fi
    passed=$failed
    failed=0
    for failure in "${failures[@]}"; do
      (( failure > passed && (failed == 0 || failure < failed) )) \
        && failed=$failure
    done
  done

  mtu[payload]=$passed
  mtu[path_mtu]=$(( passed + _VPN_MTU_IPV4_OVERHEAD ))
  if (( failed > 0 )); then
    if (( failed - passed == 1 )) && (( ${+confirmed[$failed]} )); then
      mtu[exact]=true
    else
      mtu[exact]=false
    fi
  elif (( passed == upper && upper_is_egress )); then
    mtu[exact]=true
  else
    mtu[exact]=false
  fi
  return 0
}

# --- Recommendations --------------------------------------------------------

# Appends one piece of advice to the caller's rec_texts and rec_commands. The
# command is shown for review and never run.
_vpn_mtu_advise() {
  rec_texts+=("$1")
  rec_commands+=("${2-}")
}

# Builds advice from the caller's `mtu` map. Only an exact measurement yields
# advice: a lower bound could suggest an MTU that is still too large.
_vpn_mtu_recommend() {
  [[ "${mtu[exact]}" == true && -n "${mtu[path_mtu]}" ]] || return 0
  local -i path_mtu="${mtu[path_mtu]}"
  local device="${mtu[egress_interface]}" REPLY=""

  if [[ "${mtu[through_tunnel]}" == true ]]; then
    _vpn_mtu_advise \
      "This route goes through $device, so the probe measured the path inside the tunnel; disconnect it and probe again to size the tunnel from the network underneath"
    if [[ -n "${mtu[tunnel_mtu]}" ]] && (( mtu[tunnel_mtu] > path_mtu )); then
      local subject="the $device profile"
      [[ -n "${mtu[profile]}" ]] && subject="the ${mtu[profile]} profile"
      [[ "$_VPN_PLATFORM" == darwin && -z "${mtu[profile]}" ]] \
        && subject="the profile on $device"
      _vpn_mtu_advise \
        "Set the MTU of $subject to $path_mtu, the largest packet that crossed the tunnel, in its [Interface] section" \
        "MTU = $path_mtu"
    fi
    return 0
  fi

  if [[ -n "${mtu[egress_mtu]}" ]] && (( mtu[egress_mtu] > path_mtu )); then
    case "$_VPN_PLATFORM" in
      wsl)
        _vpn_mtu_wsl_generation
        if [[ "$REPLY" == wsl1 ]]; then
          _vpn_mtu_advise \
            "WSL1 shares the Windows network stack: set MTU $path_mtu on the Windows adapter that carries this route instead"
        else
          _vpn_mtu_advise \
            "Lower $device to the path MTU for this session" \
            "sudo ip link set dev $device mtu $path_mtu"
          _vpn_mtu_advise \
            "Keep it across restarts with this line under [boot] in /etc/wsl.conf, then run wsl.exe --shutdown from Windows" \
            "command = /usr/sbin/ip link set dev $device mtu $path_mtu"
        fi
        ;;
      darwin)
        _vpn_mtu_advise \
          "Lower $device to the path MTU; networksetup keeps the setting" \
          "sudo networksetup -setMTU $device $path_mtu"
        ;;
      *)
        _vpn_mtu_advise \
          "Lower $device to the path MTU until the next restart" \
          "sudo ip link set dev $device mtu $path_mtu"
        _vpn_mtu_advise \
          "Keep it with NetworkManager (wifi.mtu for a Wi-Fi connection)" \
          "nmcli connection modify <connection> ethernet.mtu $path_mtu"
        _vpn_mtu_advise \
          "Or with systemd-networkd, in the [Link] section of the $device .network file" \
          "MTUBytes=$path_mtu"
        ;;
    esac
  fi

  # Size a WireGuard tunnel for this underlying path when one is named or up
  # and its current MTU, when known, would not fit.
  local subject="" current=""
  if [[ -n "${mtu[profile]}" ]]; then
    subject="the ${mtu[profile]} profile"
    [[ "$_VPN_PLATFORM" != darwin \
      && "${mtu[tunnel_interface]}" == "${mtu[profile]}" ]] \
      && current="${mtu[tunnel_mtu]}"
  elif [[ -n "${mtu[tunnel_interface]}" ]]; then
    subject="the ${mtu[tunnel_interface]} profile"
    [[ "$_VPN_PLATFORM" == darwin ]] \
      && subject="the profile on ${mtu[tunnel_interface]}"
    current="${mtu[tunnel_mtu]}"
  else
    return 0
  fi
  local -i wg_mtu=$(( path_mtu - _VPN_MTU_WG_OVERHEAD_IPV6 ))
  local -i wg_mtu_ipv4=$(( path_mtu - _VPN_MTU_WG_OVERHEAD_IPV4 ))
  if [[ -n "$current" ]] && (( current <= wg_mtu )); then
    return 0
  fi
  _vpn_mtu_advise \
    "Set the MTU in the [Interface] section of $subject: path MTU $path_mtu less $_VPN_MTU_WG_OVERHEAD_IPV6 bytes of WireGuard overhead, safe for IPv6 endpoints (IPv4-only endpoints need $_VPN_MTU_WG_OVERHEAD_IPV4, allowing $wg_mtu_ipv4)" \
    "MTU = $wg_mtu"
}

# --- Rendering --------------------------------------------------------------

# stdout: one compact zdx.vpn-mtu-probe.v1 object on one line, built by jq
# from the caller's `mtu` map and advice. Unknown values are null; no data is
# concatenated into JSON text.
_vpn_mtu_render_json() {
  local -a advice=()
  local -i index=0
  for (( index = 1; index <= ${#rec_texts[@]}; index++ )); do
    if [[ -n "${rec_commands[index]}" ]]; then
      advice+=("${rec_texts[index]}: ${rec_commands[index]}")
    else
      advice+=("${rec_texts[index]}.")
    fi
  done

  local key=""
  local -A numbers=() flags=()
  for key in path_mtu egress_mtu tunnel_mtu; do
    numbers[$key]=null
    [[ "${mtu[$key]}" == <-> ]] && numbers[$key]="${mtu[$key]}"
  done
  for key in applicable supported reachable exact through_tunnel; do
    flags[$key]=null
    [[ "${mtu[$key]}" == (true|false) ]] && flags[$key]="${mtu[$key]}"
  done
  local -i probes="${mtu[probes]:-0}" duration_ms="${mtu[duration_ms]:-0}"

  command jq -c -n \
    --arg schema "$_VPN_MTU_SCHEMA" \
    --argjson applicable "${flags[applicable]}" \
    --argjson supported "${flags[supported]}" \
    --argjson reachable "${flags[reachable]}" \
    --arg target "${mtu[target]}" \
    --arg address "${mtu[address]}" \
    --arg profile "${mtu[profile]}" \
    --arg platform "${mtu[platform]}" \
    --argjson path_mtu "${numbers[path_mtu]}" \
    --argjson exact "${flags[exact]}" \
    --arg egress_interface "${mtu[egress_interface]}" \
    --argjson egress_mtu "${numbers[egress_mtu]}" \
    --argjson through_tunnel "${flags[through_tunnel]}" \
    --arg tunnel_interface "${mtu[tunnel_interface]}" \
    --argjson tunnel_mtu "${numbers[tunnel_mtu]}" \
    --argjson probes "$probes" \
    --argjson duration_ms "$duration_ms" \
    --arg recommendations "${(F)advice}" \
    --arg reason "${mtu[reason]}" \
    'def nz: if . == "" then null else . end;
    {
      schema: $schema,
      applicable: $applicable,
      supported: $supported,
      reachable: $reachable,
      target: ($target | nz),
      address: ($address | nz),
      profile: ($profile | nz),
      platform: ($platform | nz),
      path_mtu: $path_mtu,
      exact: $exact,
      egress_interface: ($egress_interface | nz),
      egress_mtu: $egress_mtu,
      through_tunnel: $through_tunnel,
      tunnel_interface: ($tunnel_interface | nz),
      tunnel_mtu: $tunnel_mtu,
      probes: $probes,
      duration_ms: $duration_ms,
      recommendations:
        (if $recommendations == "" then [] else ($recommendations | split("\n")) end),
      reason: ($reason | nz)
    }'
}

# Prints the measured facts, the advice, and one verdict line on stderr.
_vpn_mtu_render_text() {
  local REPLY="" value=""
  [[ -n "${mtu[address]}" && "${mtu[address]}" != "${mtu[target]}" ]] \
    && _vpn_label "Address" "${mtu[address]}"
  _vpn_label "Egress interface" "${mtu[egress_interface]:-unknown}"
  _vpn_label "Egress MTU" "${mtu[egress_mtu]:-unknown}"
  case "${mtu[through_tunnel]}" in
    true) value="yes" ;;
    false) value="no" ;;
    *)
      value="unknown"
      (( ${mtu[wg_unavailable]:-0} )) && value="unknown (wg unavailable)"
      ;;
  esac
  _vpn_label "Through tunnel" "$value"
  if [[ -n "${mtu[tunnel_interface]}" ]]; then
    value="${mtu[tunnel_interface]}"
    [[ -n "${mtu[tunnel_mtu]}" ]] && value+=", MTU ${mtu[tunnel_mtu]}"
  elif (( ${mtu[wg_unavailable]:-0} )); then
    value="unknown"
  else
    value="none active"
  fi
  _vpn_label "WireGuard tunnel" "$value"
  if [[ "${mtu[exact]}" == true ]]; then
    _vpn_label "Path MTU" "${mtu[path_mtu]}"
  else
    _vpn_label "Path MTU" "at least ${mtu[path_mtu]}"
  fi
  _vpn_label "Largest payload" "${mtu[payload]} bytes"
  _vpn_duration_label "${mtu[elapsed]}"
  _vpn_label "Probes" "${mtu[probes]} in $REPLY"

  local -i index=0
  if (( ${#rec_texts[@]} > 0 )); then
    _vpn_section "Recommendations"
    for (( index = 1; index <= ${#rec_texts[@]}; index++ )); do
      if [[ -n "${rec_commands[index]}" ]]; then
        _vpn_dim "${rec_texts[index]}:"
        _vpn_dim "  ${rec_commands[index]}"
      else
        _vpn_dim "${rec_texts[index]}."
      fi
    done
  fi

  local -i path_mtu="${mtu[path_mtu]}"
  local device="${mtu[egress_interface]}"
  if [[ "${mtu[exact]}" != true ]]; then
    case "${mtu[stopped]}" in
      budget)
        _vpn_count_noun "${mtu[probes]}" probe
        _vpn_warn \
          "Path MTU is at least $path_mtu; probing stopped at its ${_VPN_MTU_BUDGET_SECONDS}s limit after $REPLY."
        ;;
      limit)
        _vpn_count_noun "${mtu[probes]}" probe
        _vpn_warn \
          "Path MTU is at least $path_mtu; probing stopped at its limit of $REPLY."
        ;;
      *)
        _vpn_warn \
          "Path MTU is at least $path_mtu; larger packets were not tried because the egress MTU is unknown."
        ;;
    esac
    _vpn_dim "No change is recommended from a partial measurement."
  elif [[ "${mtu[through_tunnel]}" == true && -n "${mtu[tunnel_mtu]}" ]] \
    && (( mtu[tunnel_mtu] > path_mtu )); then
    _vpn_warn \
      "Path MTU $path_mtu inside $device is below its MTU ${mtu[tunnel_mtu]}; nothing was changed."
  elif [[ "${mtu[through_tunnel]}" != true && -n "${mtu[egress_mtu]}" ]] \
    && (( mtu[egress_mtu] > path_mtu )); then
    _vpn_warn \
      "Path MTU $path_mtu is below the $device MTU ${mtu[egress_mtu]}; nothing was changed."
  elif [[ -n "${mtu[egress_mtu]}" ]]; then
    _vpn_success "Path MTU $path_mtu fits the $device MTU; no interface change is needed."
  else
    _vpn_success "Path MTU: $path_mtu."
  fi
}

# Prints why nothing was measured, with the next step, on stderr.
_vpn_mtu_render_failure() {
  _vpn_error "Path MTU not measured: ${mtu[reason]}."
  if [[ "${mtu[supported]}" == false ]]; then
    case "${mtu[reason]}" in
      *permitted*)
        _vpn_info \
          "ping needs the cap_net_raw capability or net.ipv4.ping_group_range; this probe never uses sudo."
        ;;
      *installed*|*iputils*|*rejected*)
        if [[ "$_VPN_PLATFORM" == darwin ]]; then
          _vpn_info "Use the system ping at /sbin/ping."
        else
          _vpn_info \
            "Install iputils ping (the iputils-ping or iputils package); BusyBox and GNU inetutils ping are not supported."
        fi
        ;;
    esac
    return 0
  fi
  _vpn_info \
    "Choose a target that answers ICMP echo with --target HOST or VPN_MENU_MTU_TARGET."
}

# --- Public command ---------------------------------------------------------

# vpn-mtu-probe
#   Arguments: [--target HOST] [--profile NAME] [--json], or --help.
#   stdout:    with --json, one zdx.vpn-mtu-probe.v1 object; otherwise none.
#   Effects:   read-only and unprivileged; at most _VPN_MTU_MAX_PROBES pings
#              within _VPN_MTU_BUDGET_SECONDS. Recommendations are text only.
#   Requires:  ping (iputils on Linux and WSL); ip, or route and ifconfig on
#              macOS, for the egress MTU; wg for the tunnel; jq for --json.
#   Status:    0 when measured; 1 when not applicable, unsupported, or
#              unreachable; 2 on bad arguments; 130 or 143 when interrupted.
vpn-mtu-probe() {
  local target="" profile=""
  local -i json=0 target_given=0 profile_given=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- \
          "Usage: vpn-mtu-probe [--target HOST] [--profile NAME] [--json]"
        print -u2 -r -- \
          "  Measure the largest IPv4 packet that reaches HOST with Don't Fragment"
        print -u2 -r -- \
          "  set, report the egress interface and WireGuard tunnel MTUs, and print"
        print -u2 -r -- \
          "  MTU recommendations. Nothing is changed and sudo is never used."
        print -u2 -r -- \
          "  --target HOST   IPv4 address or host name (default: VPN_MENU_MTU_TARGET,"
        print -u2 -r -- "                  else $_VPN_MTU_DEFAULT_TARGET)"
        print -u2 -r -- \
          "  --profile NAME  Name the WireGuard profile in the recommendation"
        print -u2 -r -- \
          "  --json          Print one $_VPN_MTU_SCHEMA object on stdout"
        print -u2 -r -- \
          "  Sends at most $_VPN_MTU_MAX_PROBES pings and stops within ${_VPN_MTU_BUDGET_SECONDS}s."
        print -u2 -r -- \
          "  Needs iputils ping on Linux and WSL; --json needs jq."
        return 0
        ;;
      --target|--profile)
        if (( $# < 2 )); then
          _vpn_error "$1 needs a value."
          return 2
        fi
        if [[ "$1" == --target ]]; then
          (( target_given++ == 0 )) || {
            _vpn_error "--target was given more than once."
            return 2
          }
          target="$2"
        else
          (( profile_given++ == 0 )) || {
            _vpn_error "--profile was given more than once."
            return 2
          }
          profile="$2"
        fi
        shift
        ;;
      --json) json=1 ;;
      -*) _vpn_error "Unknown option: $1"; return 2 ;;
      *)
        _vpn_error "vpn-mtu-probe takes no operands; use --target HOST."
        return 2
        ;;
    esac
    shift
  done

  if (( ! target_given )); then
    target="${VPN_MENU_MTU_TARGET:-$_VPN_MTU_DEFAULT_TARGET}"
    if ! _vpn_mtu_validate_target "$target"; then
      _vpn_error "VPN_MENU_MTU_TARGET is not an IPv4 address or host name: $target"
      return 2
    fi
  elif ! _vpn_mtu_validate_target "$target"; then
    _vpn_error "Refusing the probe target: $target"
    _vpn_info "Use an IPv4 address such as 1.1.1.1 or a host name; IPv6 is not probed."
    return 2
  fi
  if (( profile_given )) && ! _vpn_validate_iface_name "$profile"; then
    _vpn_error "Invalid profile name: $profile"
    return 2
  fi

  if (( json )) && ! _vpn_check_cmd jq; then
    _vpn_error "jq is required for --json output."
    _vpn_info "Install jq, or run vpn-mtu-probe without --json."
    return 1
  fi

  _vpn_platform_load
  zmodload -F zsh/datetime p:EPOCHREALTIME 2>/dev/null || true
  local -A mtu=(
    applicable true supported "" reachable "" reason ""
    target "$target" address "" profile "$profile" platform "$_VPN_PLATFORM"
    probe_target "" path_mtu "" payload "" exact ""
    egress_interface "" egress_mtu "" through_tunnel ""
    tunnel_interface "" tunnel_mtu "" wg_unavailable 0
    probes 0 duration_ms 0 elapsed 0 spent 0 stopped ""
    started "${EPOCHREALTIME:-$SECONDS}"
  )
  local -a rec_texts=() rec_commands=()

  # Not applicable: another kernel, even with VPN_CONFIG_DIR set, because only
  # the Linux and macOS ping and routing spellings are known.
  if [[ "$_VPN_PLATFORM" != (linux|wsl|darwin) ]]; then
    mtu[applicable]=false
    mtu[reason]="the probe supports Linux, WSL, and macOS"
    _vpn_error "vpn-mtu-probe is not applicable on this host: ${mtu[reason]}."
    (( json )) && _vpn_mtu_render_json
    return 1
  fi

  if ! _vpn_bounded_ready; then
    mtu[supported]=false
    mtu[reason]="timeout or gtimeout is required without the ZDX core"
    (( json )) && _vpn_mtu_render_json
    return 1
  fi

  if (( ! json )); then
    _vpn_header "VPN Path MTU Probe"
    _vpn_label "Target" "$target"
    [[ -n "$profile" ]] && _vpn_label "Profile" "$profile"
    _vpn_info "Sending don't-fragment pings..."
  fi

  local -i measure_status=0
  _vpn_mtu_measure || measure_status=$?
  (( measure_status == 130 || measure_status == 143 )) \
    && return "$measure_status"

  # The wall clock can jump backwards; the accounted program time is then the
  # better estimate of the real duration.
  local REPLY=""
  _vpn_mtu_elapsed "${mtu[started]}"
  local -F elapsed="$REPLY"
  (( elapsed >= ${mtu[spent]:-0} )) || elapsed="${mtu[spent]:-0}"
  mtu[elapsed]="$elapsed"
  local -i duration_ms=0
  (( duration_ms = elapsed * 1000 + 0.5 ))
  mtu[duration_ms]=$duration_ms

  if (( measure_status != 0 )); then
    _vpn_mtu_render_failure
    (( json )) && _vpn_mtu_render_json
    return 1
  fi

  _vpn_mtu_recommend
  if (( json )); then
    _vpn_mtu_render_json || return 1
  else
    _vpn_mtu_render_text
  fi
  return 0
}

typeset -g _VPN_MTU_SOURCED=1
