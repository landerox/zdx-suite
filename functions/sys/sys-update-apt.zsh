#!/usr/bin/env zsh
# =============================================================================
# System Update APT: dpkg audits, unattended-upgrade yield, and update-apt
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh and the platform adapters.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_UPDATE_APT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Fingerprint schema:
# unattended-upgrade<TAB>PID<TAB>UID<TAB>START<TAB>COMM<TAB>UNIT<TAB>SCRIPT
_sys_apt_validate_unattended_fingerprint() {
  local fingerprint="${1:-}"
  local -a fields=("${(@ps:\t:)fingerprint}")
  (( ${#fields[@]} == 7 )) || return 2
  [[ "${fields[1]}" == "unattended-upgrade" \
    && "${fields[2]}" == <-> && "${fields[2]}" -gt 1 \
    && "${fields[3]}" == "0" \
    && "${fields[4]}" == <-> \
    && "${fields[5]}" == "unattended-upgr" \
    && ( "${fields[6]}" == "apt-daily.service" \
      || "${fields[6]}" == "apt-daily-upgrade.service" ) \
    && "${fields[7]}" == "/usr/bin/unattended-upgrade" ]] || return 2
}

_sys_apt_unattended_program_trusted() {
  local program="/usr/bin/unattended-upgrade"
  local -A program_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && [[ -f "$program" && ! -L "$program" ]] \
    && zstat -H program_state "$program" 2>/dev/null || return 1
  (( program_state[uid] == 0 \
    && program_state[nlink] == 1 \
    && (program_state[mode] & 8#22) == 0 )) || return 1
  REPLY="$program"
}

_sys_apt_read_unattended_pid() {
  local pid_file="/run/unattended-upgrades.pid"
  local -A before_state=() after_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zmodload zsh/system 2>/dev/null \
    && [[ -f "$pid_file" && ! -L "$pid_file" ]] \
    && zstat -H before_state "$pid_file" 2>/dev/null || return 1
  (( before_state[uid] == 0 \
    && before_state[nlink] == 1 \
    && before_state[size] > 0 \
    && before_state[size] <= 32 \
    && (before_state[mode] & 8#22) == 0 )) || return 1

  local -i pid_fd=-1
  sysopen -r -o nofollow,cloexec -u pid_fd -- "$pid_file" 2>/dev/null \
    || return 1
  local pid_text="" extra_line=""
  local -i read_rc=0 unsafe_content=0
  {
    IFS= read -r -u $pid_fd pid_text
    read_rc=$?
    (( read_rc == 0 )) || [[ -n "$pid_text" ]] || unsafe_content=1
    if (( ! unsafe_content )); then
      if IFS= read -r -u $pid_fd extra_line || [[ -n "$extra_line" ]]; then
        unsafe_content=1
      fi
    fi
  } always {
    exec {pid_fd}>&-
  }
  (( ! unsafe_content )) && [[ "$pid_text" == <-> && "$pid_text" -gt 1 ]] \
    || return 1

  zstat -H after_state "$pid_file" 2>/dev/null || return 1
  [[ "${after_state[device]}:${after_state[inode]}:${after_state[size]}:${after_state[mtime]}:${after_state[ctime]}:${after_state[mode]}:${after_state[uid]}:${after_state[nlink]}" \
    == "${before_state[device]}:${before_state[inode]}:${before_state[size]}:${before_state[mtime]}:${before_state[ctime]}:${before_state[mode]}:${before_state[uid]}:${before_state[nlink]}" ]] \
    || return 1
  REPLY="$pid_text"
}

# Return one exact fingerprint only for root's packaged unattended-upgrade
# running inside an automatic apt-daily systemd unit.
_sys_apt_unattended_fingerprint() {
  _sys_apt_read_unattended_pid || return 1
  local pid="$REPLY"
  local proc_dir="/proc/$pid"
  [[ -d "$proc_dir" && ! -L "$proc_dir" ]] || return 1

  local proc_metadata
  proc_metadata=$(< "$proc_dir/status") 2>/dev/null || return 1
  local process_name="" uid_text="" sigcgt_text="" metadata_line
  local -i sigcgt_records=0
  for metadata_line in "${(@f)proc_metadata}"; do
    case "$metadata_line" in
      Name:*) process_name="${metadata_line#Name:}" ;;
      Uid:*)  uid_text="${metadata_line#Uid:}" ;;
      SigCgt:*)
        (( sigcgt_records++ ))
        sigcgt_text="${metadata_line#SigCgt:}"
        ;;
    esac
  done
  process_name="${process_name//[[:space:]]/}"
  sigcgt_text="${sigcgt_text//[[:space:]]/}"
  local -a uid_fields=("${=uid_text}")
  uid_fields=("${(@)uid_fields:#}")
  (( ${#uid_fields[@]} == 4 )) \
    && [[ "${uid_fields[1]}" == "0" \
      && "${uid_fields[2]}" == "0" \
      && "${uid_fields[3]}" == "0" \
      && "${uid_fields[4]}" == "0" \
      && "$process_name" == "unattended-upgr" ]] || return 1
  # SIGTERM is signal 15, represented by bit 0x4000 in SigCgt. Requiring the
  # live process to catch it prevents a package-version race from turning the
  # cooperative request into the default terminating action.
  (( sigcgt_records == 1 \
    && ${#sigcgt_text} >= 4 \
    && ${#sigcgt_text} <= 16 )) \
    && [[ "$sigcgt_text" != *[^0-9A-Fa-f]* ]] || return 1
  local sigcgt_tail="${sigcgt_text[-4,-1]}"
  (( (16#$sigcgt_tail & 16#4000) != 0 )) || return 1

  local stat_line
  IFS= read -r stat_line < "$proc_dir/stat" 2>/dev/null || return 1
  [[ "${stat_line%% *}" == "$pid" && "$stat_line" == *") "* ]] || return 1
  local stat_tail="${stat_line##*) }"
  local -a stat_fields=()
  read -r -A stat_fields <<< "$stat_tail"
  (( ${#stat_fields[@]} >= 20 )) \
    && [[ "${stat_fields[20]}" == <-> ]] || return 1
  local start_value="${stat_fields[20]}"

  local process_unit="" cgroup_line
  while IFS= read -r cgroup_line; do
    case "$cgroup_line" in
      *:/system.slice/apt-daily.service)
        process_unit="apt-daily.service"
        break
        ;;
      *:/system.slice/apt-daily-upgrade.service)
        process_unit="apt-daily-upgrade.service"
        break
        ;;
    esac
  done < "$proc_dir/cgroup"
  [[ -n "$process_unit" ]] || return 1

  local -a process_argv=()
  local process_arg=""
  while IFS= read -r -d '' process_arg; do
    if (( ${#process_arg} >= 3 )) \
      && [[ "--no-minimal-upgrade-steps" == "$process_arg"* ]]; then
      return 1
    fi
    process_argv+=("$process_arg")
    (( ${#process_argv[@]} <= 32 )) || return 1
  done < "$proc_dir/cmdline"
  (( ${#process_argv[@]} > 0 \
    && ${process_argv[(Ie)/usr/bin/unattended-upgrade]} > 0 )) || return 1

  local program=""
  _sys_apt_unattended_program_trusted || return 1
  program="$REPLY"
  [[ "$program" == "/usr/bin/unattended-upgrade" ]] || return 1

  local fingerprint=$'unattended-upgrade\t'"$pid"$'\t0\t'"$start_value"$'\tunattended-upgr\t'"$process_unit"$'\t/usr/bin/unattended-upgrade'
  _sys_apt_validate_unattended_fingerprint "$fingerprint" || return 1

  local final_pid
  _sys_apt_read_unattended_pid || return 1
  final_pid="$REPLY"
  [[ "$final_pid" == "$pid" ]] || return 1
  REPLY="$fingerprint"
}

_sys_apt_unattended_fingerprint_matches() {
  local expected_fingerprint="${1:-}"
  _sys_apt_validate_unattended_fingerprint "$expected_fingerprint" || return 2
  local REPLY
  _sys_apt_unattended_fingerprint || return 1
  [[ "$REPLY" == "$expected_fingerprint" ]]
}

_sys_apt_unattended_version_at_least() {
  local minimum_version="${1:-}"
  local installed_version="${2:-}"
  [[ "$minimum_version" == "0.94" \
    || "$minimum_version" == "0.95" ]] || return 2
  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  _sys_update_resolve_trusted_program env || return 2
  local version_env_program="$REPLY"
  _sys_update_resolve_trusted_program dpkg || return 2
  local dpkg_program="$REPLY"

  if [[ -z "$installed_version" ]]; then
    _sys_update_resolve_trusted_program dpkg-query || return 2
    local dpkg_query_program="$REPLY"
    local version_record
    version_record=$(
      _sys_run_bounded_probe 10 4096 \
        "$version_env_program" -i HOME=/nonexistent LC_ALL=C \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb \
        "$dpkg_query_program" --show \
        '--showformat=${Status}\t${Version}\n' \
        unattended-upgrades </dev/null 2>/dev/null
    ) || return 2
    [[ "$version_record" == *$'\t'* \
      && "$version_record" != *$'\n'* ]] || return 2
    local package_status="${version_record%%$'\t'*}"
    local -a status_fields=("${=package_status}")
    (( ${#status_fields[@]} == 3 )) \
      && [[ ( "${status_fields[1]}" == "install" \
        || "${status_fields[1]}" == "hold" ) \
        && "${status_fields[2]}" == "ok" \
        && "${status_fields[3]}" == "installed" ]] || return 2
    installed_version="${version_record#*$'\t'}"
  fi
  [[ -n "$installed_version" \
    && "$installed_version" != *[[:space:]]* \
    && "$installed_version" != *[[:cntrl:]]* \
    && ${#installed_version} -le 256 ]] || return 2

  local feature_version="$installed_version"
  if [[ "$feature_version" == *:* ]]; then
    local version_epoch="${feature_version%%:*}"
    [[ "$version_epoch" == <-> ]] || return 2
    feature_version="${feature_version#*:}"
  fi
  [[ -n "$feature_version" ]] || return 2

  "$version_env_program" -i HOME=/nonexistent LC_ALL=C \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb \
    "$dpkg_program" --compare-versions \
    "$feature_version" ge "$minimum_version" </dev/null 2>/dev/null
  local compare_rc=$?
  (( compare_rc == 0 || compare_rc == 1 )) || return 2
  REPLY="$installed_version"
  return $compare_rc
}

_sys_apt_config_true_by_default() {
  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  local variable_name="${1:-}"
  local config_key="${2:-}"
  local default_enabled="${3:-1}"
  [[ "$default_enabled" == 0 || "$default_enabled" == 1 ]] || return 2
  case "$variable_name:$config_key" in
    ZdxMinimalSteps:Unattended-Upgrade::MinimalSteps|\
    ZdxMinimalStepsCompat:Unattended-Upgrades::MinimalSteps)
      ;;
    *)
      return 2
      ;;
  esac
  _sys_update_resolve_trusted_program env || return 2
  local apt_config_env_program="$REPLY"
  _sys_update_resolve_trusted_program apt-config || return 2
  local apt_config_program="$REPLY"
  local config_output
  config_output=$(
    _sys_run_bounded_probe 10 4096 \
      "$apt_config_env_program" -i HOME=/nonexistent \
      XDG_CACHE_HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent \
      XDG_DATA_HOME=/nonexistent LC_ALL=C \
      PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb \
      "$apt_config_program" shell \
      "$variable_name" "$config_key/b" </dev/null 2>/dev/null
  ) || return 2
  case "$config_output" in
    "")                         return $(( 1 - default_enabled )) ;;
    "$variable_name='true'"|"$variable_name='1'") return 0 ;;
    "$variable_name='false'"|"$variable_name='0'") return 1 ;;
    *)                          return 2 ;;
  esac
}

_sys_apt_minimal_steps_enabled() {
  _sys_apt_unattended_version_at_least 0.94
  local version_rc=$?
  (( version_rc == 0 )) || return $version_rc
  local installed_version="$REPLY"
  local -i minimal_steps_default=0
  if _sys_apt_unattended_version_at_least 0.95 "$installed_version"; then
    minimal_steps_default=1
  else
    version_rc=$?
    (( version_rc == 1 )) || return $version_rc
  fi
  _sys_apt_config_true_by_default \
    ZdxMinimalSteps Unattended-Upgrade::MinimalSteps \
    "$minimal_steps_default"
  local primary_rc=$?
  _sys_apt_config_true_by_default \
    ZdxMinimalStepsCompat Unattended-Upgrades::MinimalSteps \
    "$minimal_steps_default"
  local compat_rc=$?
  (( primary_rc <= 1 && compat_rc <= 1 )) || return 2
  if (( minimal_steps_default )); then
    (( primary_rc == 0 && compat_rc == 0 ))
  else
    (( primary_rc == 0 || compat_rc == 0 ))
  fi
}

_sys_apt_automatic_takeover_enabled() {
  case "${SYS_APT_AUTOMATIC_TAKEOVER:-1}" in
    1) return 0 ;;
    0) return 1 ;;
    *)
      _sys_error "SYS_APT_AUTOMATIC_TAKEOVER must be exactly 0 or 1."
      return 2
      ;;
  esac
}

_sys_apt_kill_program() {
  local program="/usr/bin/kill"
  local -A program_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && [[ -f "$program" && ! -L "$program" ]] \
    && zstat -H program_state "$program" 2>/dev/null || return 1
  (( program_state[uid] == 0 \
    && program_state[nlink] == 1 \
    && (program_state[mode] & 8#22) == 0 )) || return 1
  REPLY="$program"
}

# Request a cooperative stop at unattended-upgrade's next minimal-step
# boundary. The process is revalidated around authentication and SIGKILL is
# never an allowed escalation. Aggregate updates use an already authenticated
# sudo timestamp and never open another password prompt.
_sys_apt_request_automatic_yield() {
  local expected_fingerprint="${1:-}"
  _sys_apt_validate_unattended_fingerprint "$expected_fingerprint" || return 2
  local -a fields=("${(@ps:\t:)expected_fingerprint}")
  local pid="${fields[2]}"
  local process_unit="${fields[6]}"

  if ! _sys_apt_minimal_steps_enabled; then
    _sys_dim \
      "Automatic unattended-upgrade does not permit a verified minimal-step stop; APT will fail immediately if it stays busy."
    return 1
  fi

  local REPLY
  _sys_apt_kill_program || {
    _sys_error \
      "The trusted /usr/bin/kill program is unavailable; automatic unattended-upgrade was not signaled."
    return 1
  }
  local kill_program="$REPLY"

  _sys_info \
    "Cooperative takeover: request SIGTERM for automatic PID $pid ($process_unit)."
  _sys_dim \
    "unattended-upgrade will finish its current package step before yielding."
  _sys_apt_unattended_fingerprint_matches "$expected_fingerprint" || {
    _sys_error \
      "Automatic updater identity changed before authentication; no signal was sent."
    return 1
  }

  if (( EUID == 0 )); then
    _sys_apt_unattended_fingerprint_matches "$expected_fingerprint" || {
      _sys_error \
        "Automatic updater identity changed before signaling; no signal was sent."
      return 1
    }
    "$kill_program" -s TERM -- "$pid" 2>/dev/null || {
      _sys_error "Failed to request a cooperative stop for PID $pid."
      return 1
    }
  else
    _sys_has_capability "privilege:sudo" \
      && command -v sudo &>/dev/null || {
        _sys_error \
        "sudo is unavailable; automatic unattended-upgrade was not signaled."
        return 1
    }
    _sys_info \
      "Privileged operation: sudo -n $(_sys_display_escape "$kill_program") -s TERM $pid"
    local aggregate_privilege_mode="${_SYS_PRIVILEGE_NONINTERACTIVE:-0}"
    [[ "$aggregate_privilege_mode" == 0 \
      || "$aggregate_privilege_mode" == 1 ]] || return 2
    if [[ "$aggregate_privilege_mode" == 0 ]]; then
      sudo -v >&2 || {
        _sys_error \
          "sudo authentication failed; automatic unattended-upgrade was not signaled."
        return 1
      }
      _sys_apt_unattended_fingerprint_matches "$expected_fingerprint" || {
        _sys_error \
          "Automatic updater identity changed during authentication; no signal was sent."
        return 1
      }
    else
      _sys_apt_unattended_fingerprint_matches "$expected_fingerprint" || {
        _sys_error \
          "Automatic updater identity changed before non-interactive signaling; no signal was sent."
        return 1
      }
    fi
    sudo -n "$kill_program" -s TERM -- "$pid" >&2 || {
      _sys_error "Privileged cooperative SIGTERM failed for PID $pid."
      return 1
    }
  fi

  _sys_success \
    "Cooperative SIGTERM sent; ZDX will not wait or escalate to SIGKILL."
}

# Discover an exact automatic unattended-upgrade for the mutation plan. REPLY
# remains empty unless the live packaged process is eligible for one
# cooperative SIGTERM. APT itself is the sole lock arbiter: process-name scans
# must not produce false "busy" diagnostics or suppress a valid transaction.
_sys_apt_plan_blocker() {
  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  REPLY=""
  _sys_apt_automatic_takeover_enabled
  local takeover_rc=$?
  if (( takeover_rc == 1 )); then
    return 0
  elif (( takeover_rc != 0 )); then
    return $takeover_rc
  fi

  local fingerprint=""
  if ! _sys_apt_unattended_fingerprint; then
    REPLY=""
    return 0
  fi
  fingerprint="$REPLY"
  REPLY=""
  if ! _sys_apt_minimal_steps_enabled; then
    _sys_dim \
      "An automatic unattended-upgrade is active, but a safe minimal-step stop could not be verified; no signal is planned."
    return 0
  fi

  local -a fields=("${(@ps:\t:)fingerprint}")
  _sys_info \
    "Proposed APT takeover: SIGTERM PID ${fields[2]} (${fields[6]})."
  _sys_dim \
    "The fingerprint will be revalidated before the fixed privileged signal."
  REPLY="$fingerprint"
}

_sys_apt_dpkg_state_clean() {
  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  local phase="${1:-before}"
  [[ "$phase" == "before" || "$phase" == "after" ]] || return 2
  local updates_dir="/var/lib/dpkg/updates"
  [[ -d "$updates_dir" && ! -L "$updates_dir" ]] || {
    _sys_error "Unable to validate dpkg's transaction journal."
    return 1
  }
  local -a journal_entries=("$updates_dir"/<->(N.))
  (( ${#journal_entries[@]} == 0 )) || {
    if [[ "$phase" == "after" ]]; then
      _sys_error \
        "Post-transaction dpkg journal still contains unfinished entries."
    else
      _sys_error \
        "dpkg has an unfinished transaction journal; automatic APT execution is refused."
    fi
    _sys_dim \
      "Review the package state and run 'sudo dpkg --configure -a' manually."
    return 1
  }
  _sys_update_resolve_trusted_program env || {
    _sys_error "A trusted env program is unavailable for the dpkg audit."
    return 1
  }
  local audit_env_program="$REPLY"
  _sys_update_resolve_trusted_program dpkg || {
    _sys_error "A trusted dpkg program is unavailable for package-state validation."
    return 1
  }
  local dpkg_program="$REPLY"
  local audit_output
  audit_output=$(
    _sys_run_bounded_probe 10 65536 \
      "$audit_env_program" -i HOME=/nonexistent LC_ALL=C \
      PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb \
      "$dpkg_program" --audit </dev/null 2>/dev/null
  ) || {
    if [[ "$phase" == "after" ]]; then
      _sys_error "Unable to audit dpkg state after the APT transaction."
    else
      _sys_error "Unable to audit dpkg state before the APT transaction."
    fi
    return 1
  }
  [[ -z "${audit_output//[[:space:]]/}" ]] || {
    if [[ "$phase" == "after" ]]; then
      _sys_error \
        "Post-transaction dpkg audit reports an incomplete package state."
    else
      _sys_error \
        "dpkg reports an incomplete package state; automatic APT execution is refused."
    fi
    _sys_dim \
      "Review the package state and run 'sudo dpkg --configure -a' manually."
    return 1
  }
}

# Return 0 only for the fixed, safe reboot-required marker; 1 means absent and
# 2 means present but unsafe or unstable. Its content is never read or run.
_sys_apt_reboot_required_path() {
  REPLY="/run/reboot-required"
}

_sys_apt_reboot_required() {
  _sys_apt_reboot_required_path || return 2
  local marker="$REPLY"
  [[ "$marker" == /* && "$marker" != *[[:cntrl:]]* ]] || return 2
  [[ -e "$marker" || -L "$marker" ]] || return 1
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || return 2
  local -A before_state=() fd_state=() after_state=()
  [[ -f "$marker" && ! -L "$marker" ]] \
    && zstat -H before_state -- "$marker" 2>/dev/null || return 2
  (( before_state[uid] == 0 \
    && before_state[nlink] == 1 \
    && before_state[size] >= 0 \
    && before_state[size] <= 4096 \
    && (before_state[mode] & 8#22) == 0 )) || return 2

  local -i marker_fd=-1 marker_safe=1
  sysopen -r -o nofollow,cloexec -u marker_fd -- "$marker" 2>/dev/null \
    || return 2
  {
    zstat -H fd_state -f "$marker_fd" 2>/dev/null || marker_safe=0
    zstat -H after_state -- "$marker" 2>/dev/null || marker_safe=0
  } always {
    exec {marker_fd}<&-
  }
  (( marker_safe )) || return 2
  local before_identity="${before_state[device]}:${before_state[inode]}:${before_state[uid]}:${before_state[nlink]}:${before_state[size]}:${before_state[mode]}"
  local fd_identity="${fd_state[device]}:${fd_state[inode]}:${fd_state[uid]}:${fd_state[nlink]}:${fd_state[size]}:${fd_state[mode]}"
  local after_identity="${after_state[device]}:${after_state[inode]}:${after_state[uid]}:${after_state[nlink]}:${after_state[size]}:${after_state[mode]}"
  [[ "$before_identity" == "$fd_identity" \
    && "$before_identity" == "$after_identity" ]] || return 2
}

# REPLY: "required", "unknown", or empty for the reboot-required marker.
_sys_apt_report_reboot_requirement() {
  _sys_apt_reboot_required
  local marker_rc=$?
  REPLY=""
  case "$marker_rc" in
    0)
      _sys_warn \
        "A system reboot is required to finish applying package updates."
      REPLY=required
      ;;
    1)
      ;;
    *)
      _sys_warn \
        "The reboot-required marker exists but could not be validated safely; reboot status is unknown."
      REPLY=unknown
      ;;
  esac
  return 0
}

_sys_apt_prepare_transaction() {
  local authorized_fingerprint="${1:-${_SYS_APT_AUTHORIZED_FINGERPRINT:-}}"
  [[ -z "$authorized_fingerprint" ]] \
    || _sys_apt_validate_unattended_fingerprint "$authorized_fingerprint" \
    || return 2

  # Never stop an automatic updater when dpkg already reports an unfinished
  # transaction. That state needs operator review or completion by its current
  # owner; signaling first could abandon the only process able to finish it.
  _sys_apt_dpkg_state_clean || return $?

  # The planned automatic target is revalidated only to decide whether its one
  # cooperative signal is still authorized. Lock ownership is left to APT's
  # native zero-timeout attempt: a process-name scan must never suppress a
  # valid transaction or become a polling loop.
  if [[ -n "$authorized_fingerprint" ]]; then
    if _sys_apt_unattended_fingerprint_matches "$authorized_fingerprint"; then
      _sys_apt_request_automatic_yield "$authorized_fingerprint" || _sys_warn \
        "The cooperative signal was not sent; APT will still make its single native no-wait attempt."
    else
      _sys_info \
        "The planned automatic APT owner is no longer active; no signal is needed."
    fi
  fi
}

_sys_apt_announce_operation() {
  local verbose="${1:-0}"
  local privilege_label="${2:-}"
  local apt_env_program="${3:-}"
  local apt_environment_label="${4:-}"
  local apt_policy_label="${5:-}"
  shift 5 2>/dev/null || return 2
  [[ "$verbose" == 0 || "$verbose" == 1 ]] || return 2
  (( $# > 0 )) || return 2
  local operation_label="${(j: :)@}"
  _sys_info \
    "Privileged operation: ${privilege_label}apt-get $operation_label"
  if (( verbose )); then
    _sys_dim \
      "Full invocation: ${privilege_label}$(_sys_display_escape "$apt_env_program") -i $apt_environment_label apt-get $apt_policy_label $operation_label"
  fi
  return 0
}

# --- APT output relay and diagnosis -------------------------------------------

# Relays APT's own output to stderr unchanged and keeps a bounded private tail
# in REPLY for diagnosis. It must be the last pipeline element so it runs in
# this shell. It drains its input to end of file, so APT never receives
# SIGPIPE, and it never reopens stderr, so a redirected log is not truncated.
_sys_apt_relay_output() {
  emulate -L zsh
  local LC_ALL=C chunk="" tail=""
  local -i limit="${1:-65536}" read_rc=0
  if ! zmodload zsh/system 2>/dev/null; then
    command cat >&2
    REPLY=""
    return 0
  fi
  while true; do
    chunk=""
    sysread -i 0 -s 8192 chunk
    read_rc=$?
    (( read_rc == 0 )) || break
    print -rn -u2 -- "$chunk"
    tail+="$chunk"
    (( ${#tail} > limit )) && tail="${tail[-limit,-1]}"
  done
  REPLY="$tail"
}

# reply=(upgraded installed removed held) from APT's transaction summary line.
# Returns 1 when no summary line is present.
_sys_apt_transaction_counts() {
  emulate -L zsh
  local line MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=() counts=()
  reply=()
  for line in "${(@f)1}"; do
    line="${line%$'\r'}"
    if [[ "$line" =~ '^([0-9]+) upgraded, ([0-9]+) newly installed, ([0-9]+ reinstalled, )?([0-9]+ downgraded, )?([0-9]+) to remove and ([0-9]+) not upgraded[.]$' ]]; then
      counts=("${match[1]}" "${match[2]}" "${match[5]}" "${match[6]}")
    fi
  done
  (( ${#counts} == 4 )) || return 1
  reply=("${counts[@]}")
}

# Display-only source: credentials in a URI are removed, the text is bounded,
# and control characters are made visible.
_sys_apt_display_source() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local source="${1-}"
  source="${source//(#b)([a-zA-Z][a-zA-Z0-9+.-]#:\/\/)[^\/@[:space:]]##@/${match[1]}}"
  (( ${#source} > 120 )) && source="${source[1,119]}…"
  REPLY="${(V)source}"
}

# REPLY: "<class><TAB><problem>" for one APT failure reason.
_sys_apt_classify_index_problem() {
  emulate -L zsh
  local reason="${1-}" MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  if [[ "$reason" =~ '(NO_PUBKEY|EXPKEYSIG|EXPSIG|REVKEYSIG|BADSIG) ([0-9A-Fa-f]{8,40})' ]]; then
    case "${match[1]}" in
      NO_PUBKEY) REPLY=$'key\tsigning key not installed ('"${match[1]} ${match[2]}"')' ;;
      EXPKEYSIG|EXPSIG) REPLY=$'key\tsigning key expired ('"${match[1]} ${match[2]}"')' ;;
      REVKEYSIG) REPLY=$'key\tsigning key revoked ('"${match[1]} ${match[2]}"')' ;;
      *) REPLY=$'key\tbad signature ('"${match[1]} ${match[2]}"')' ;;
    esac
  elif [[ "$reason" =~ 'Missing key ([0-9A-Fa-f]{16,64})' ]]; then
    # APT 3 verifies with sqv, which names a missing key this way.
    REPLY=$'key\tsigning key not installed (Missing key '"${match[1]}"')'
  elif [[ "$reason" == *"is not signed"* ]]; then
    REPLY=$'key\trepository is not signed'
  elif [[ "$reason" == *"Could not resolve"* \
    || "$reason" == *"Temporary failure resolving"* ]]; then
    REPLY=$'network\thost lookup failed'
  elif [[ "$reason" == *"Could not connect"* || "$reason" == *"Unable to connect"* \
    || "$reason" == *"Connection timed out"* \
    || "$reason" == *"Connection failed"* ]]; then
    REPLY=$'network\tconnection failed'
  elif [[ "$reason" =~ '(^|[[:space:]])(5[0-9][0-9]) ' ]]; then
    REPLY=$'network\tserver error HTTP '"${match[2]}"
  elif [[ "$reason" =~ '(^|[[:space:]])(4[0-9][0-9]) ' \
    || "$reason" == *"does not have a Release file"* ]]; then
    REPLY=$'missing\trepository or suite not found'
  elif [[ "$reason" == *"is not valid yet"* ]]; then
    REPLY=$'clock\trelease file not valid yet'
  elif [[ "$reason" == *"is expired"* ]]; then
    REPLY=$'release\trelease file expired'
  elif [[ "$reason" == *"changed its '"* ]]; then
    REPLY=$'release\trelease metadata changed'
  elif [[ "$reason" == *"Could not get lock"* ]]; then
    REPLY=$'lock\tlock held by another package process'
  else
    local text="${reason##[[:space:]]#}"
    (( ${#text} > 80 )) && text="${text[1,79]}…"
    REPLY=$'other\t'"${(V)text}"
  fi
}

# Private: record one failure in the caller's dynamically scoped problems,
# classes, and order. A key problem is never replaced by a generic one, and
# one that names a key ID (such as NO_PUBKEY) is never replaced by one that
# does not (such as APT's closing "is not signed").
_sys_apt_index_record() {
  local record_source="$1" record_reason="$2" REPLY
  _sys_apt_classify_index_problem "$record_reason"
  local record_class="${REPLY%%$'\t'*}" record_problem="${REPLY#*$'\t'}"
  if (( ! ${+problems[$record_source]} )); then
    order+=("$record_source")
  elif [[ "${classes[$record_source]}" == key ]]; then
    [[ "$record_class" == key ]] || return 0
    [[ "${problems[$record_source]}" == *"("* \
      && "$record_problem" != *"("* ]] && return 0
  fi
  problems[$record_source]="$record_problem"
  classes[$record_source]="$record_class"
}

# reply: "<class><TAB><source><TAB><problem>" records for failed repositories,
# at most one per source. A key problem replaces a generic one for a source.
# Sources are display-safe unless the second argument is "raw", which keeps
# APT's "<uri> <suite>" text for matching against the source entries.
_sys_apt_index_failures() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local tail="${1-}" mode="${2-}" line source reason pending_source=""
  local MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=() order=()
  local -A problems=() classes=()
  reply=()
  for line in "${(@f)tail}"; do
    line="${line%$'\r'}"
    if [[ -n "$pending_source" && "$line" == [[:space:]]##* ]]; then
      _sys_apt_index_record "$pending_source" "$line"
      pending_source=""
      continue
    fi
    pending_source=""
    if [[ "$line" =~ '^Err:[0-9]+ ([^ ]+ [^ ]+)' ]]; then
      pending_source="${match[1]}"
    elif [[ "$line" =~ 'GPG error: ([^ ]+ [^ :]+)[^:]*: (.*)$' ]]; then
      _sys_apt_index_record "${match[1]}" "${match[2]}"
    elif [[ "$line" =~ "The repository '([^']+)' (.*)$" ]]; then
      source="${match[1]% Release}"
      source="${source% InRelease}"
      _sys_apt_index_record "$source" "${match[2]}"
    elif [[ "$line" =~ '^E: Failed to fetch ([^ ]+)[[:space:]]+(.*)$' ]]; then
      source="${match[1]}"
      reason="${match[2]}"
      if [[ "$source" =~ '^(.+)/dists/([^/]+)/' ]]; then
        source="${match[1]} ${match[2]}"
      fi
      _sys_apt_index_record "$source" "$reason"
    elif [[ "$line" =~ '^E: Could not get lock (.*)$' ]]; then
      _sys_apt_index_record "APT lock" "Could not get lock ${match[1]}"
    fi
  done
  local display_source=""
  for source in "${order[@]}"; do
    if [[ "$mode" == raw ]]; then
      display_source="$source"
    else
      _sys_apt_display_source "$source"
      display_source="$REPLY"
    fi
    reply+=("${classes[$source]}"$'\t'"$display_source"$'\t'"${problems[$source]}")
  done
}

# Prints at most four lines for the first repository key problem that ZDX did
# not fix: that the key is the repository's problem, the cause, and the two
# ways forward. Usage: _sys_apt_report_key_guidance <guidance-record>
_sys_apt_report_key_guidance() {
  local record="${1-}" repository="" key_id="" source_file="" keyring=""
  local cause="" where="" REPLY
  local -a fields=("${(@ps:\t:)record}")
  repository="${fields[1]-}"
  key_id="${fields[2]-}"
  source_file="${fields[3]-}"
  keyring="${fields[4]-}"
  cause="${fields[5]-}"
  _sys_apt_display_source "$repository"
  repository="$REPLY"
  where="${source_file:+ ($(_sys_display_escape "$source_file"))}"
  if [[ -n "$key_id" ]]; then
    _sys_dim "This is a problem with the repository's signing key, not with ZDX: $repository$where needs key $key_id."
  else
    _sys_dim "This is a problem with the repository's signing key, not with ZDX: $repository$where."
  fi
  [[ -n "$cause" ]] && _sys_dim "$cause"
  if [[ "$keyring" == /* ]]; then
    _sys_dim "Install the publisher's current key from its official instructions: sudo install -m 0644 -o 0 -g 0 <downloaded-key> $(_sys_display_escape "$keyring")"
  else
    _sys_dim "Install the publisher's current key from its official instructions, as its documentation describes."
  fi
  if [[ "$source_file" == */sources.list.d/*.(list|sources) ]]; then
    _sys_dim "Or disable the source: sudo mv $(_sys_display_escape "$source_file") $(_sys_display_escape "$source_file").disabled"
  elif [[ -n "$source_file" ]]; then
    _sys_dim "Or disable the source: comment out its entry in $(_sys_display_escape "$source_file")"
  else
    _sys_dim "Or disable that source in /etc/apt/sources.list.d."
  fi
}

# Prints the diagnosis of a failed index refresh. REPLY: one short detail for
# the step result. The optional guidance record describes the first key
# problem ZDX did not fix (_sys_apt_key_guidance).
# Usage: _sys_apt_report_index_failure <tail> <candidates|""> [<guidance>]
_sys_apt_report_index_failure() {
  local tail="${1-}" candidates="${2-}" guidance="${3-}" record first_detail=""
  local -a reply=() failures=() rows=() classes=()
  local -i shown=0
  _sys_apt_index_failures "$tail"
  failures=("${reply[@]}")
  if (( ${#failures} == 0 )); then
    _sys_dim "APT reported no recognizable repository error; review its output above."
  else
    _sys_count_noun "${#failures}" repository repositories
    _sys_info "$REPLY could not be refreshed:"
    for record in "${failures[@]}"; do
      classes+=("${record%%$'\t'*}")
      (( shown < 10 )) || continue
      rows+=("${record#*$'\t'}")
      (( ++shown ))
    done
    _sys_table $'Repository\tProblem' "${rows[@]}"
    (( ${#failures} > shown )) \
      && _sys_dim "… and $(( ${#failures} - shown )) more"
    local first="${failures[1]#*$'\t'}"
    local first_source="${first%%$'\t'*}" first_problem="${first#*$'\t'}"
    first_source="${first_source#*://}"
    first_source="${first_source%%[/ ]*}"
    # The table keeps the key evidence; the one-line detail stays short.
    first_detail="${first_problem% \(*} ($first_source)"
    (( ${#failures} > 1 )) && first_detail+=" and $(( ${#failures} - 1 )) more"
  fi
  if (( ${classes[(Ie)key]} )) && [[ -n "$guidance" ]]; then
    _sys_apt_report_key_guidance "$guidance"
  elif (( ${classes[(Ie)key]} )); then
    _sys_dim "A repository signing key is missing, expired, revoked, or replaced. Install the publisher's current key from its official instructions, or disable that source."
  elif (( ${classes[(Ie)lock]} )); then
    _sys_dim "Another package process holds an APT lock; let it finish before running the update again."
  elif (( ${classes[(Ie)clock]} )); then
    _sys_dim "The system clock appears to be behind the repository; correct the time first."
  elif (( ${classes[(Ie)release]} )); then
    _sys_dim "A repository changed or expired its release metadata; review the change before trusting it."
  elif (( ${classes[(Ie)missing]} )); then
    _sys_dim "A repository path or suite no longer exists; correct or remove that source entry."
  elif (( ${classes[(Ie)network]} )); then
    _sys_dim "Check network and DNS access to the listed hosts."
  fi
  if [[ "$candidates" == <-> ]]; then
    _sys_count_noun "$candidates" candidate
    if (( candidates == 1 )); then
      _sys_dim "No package was upgraded; $REPLY remains pending."
    else
      _sys_dim "No package was upgraded; $REPLY remain pending."
    fi
  else
    _sys_dim "No package was upgraded; pending candidates are unknown."
  fi
  _sys_dim "After fixing the cause, run: sys-menu update-apt"
  REPLY="index refresh failed${first_detail:+: $first_detail}"
}

# reply=(outcome detail message-suffix) for a finished APT transaction. A
# renewed signing key is change evidence of its own: the keyring holds a key
# fingerprint it did not hold before, and APT verified the repository with it.
# Usage: _sys_apt_transaction_outcome <upgrade-tail> <autoremove-tail> <reboot>
#   [<renewed-key-label>]
_sys_apt_transaction_outcome() {
  local upgrade_tail="${1-}" autoremove_tail="${2-}" reboot_state="${3-}"
  local renewed_label="${4-}"
  local -a counts=() removed=()
  local outcome=done detail="transaction completed" suffix="."
  if _sys_apt_transaction_counts "$upgrade_tail"; then
    counts=("${reply[@]}")
    removed=(0 0 0 0)
    _sys_apt_transaction_counts "$autoremove_tail" && removed=("${reply[@]}")
    local -i upgraded="${counts[1]}" installed="${counts[2]}" held="${counts[4]}"
    local -i removed_total=$(( counts[3] + removed[3] ))
    if (( upgraded + installed + removed_total > 0 )); then
      outcome=updated
      detail="$upgraded upgraded, $installed newly installed, $removed_total removed"
    else
      outcome=current
      detail="no package changes"
    fi
    (( held > 0 )) && detail+=", $held held back"
  fi
  if [[ -n "$renewed_label" ]]; then
    if [[ "$outcome" == done ]]; then
      detail="$renewed_label"
    else
      detail+=", $renewed_label"
    fi
    outcome=updated
  fi
  case "$reboot_state" in
    required) detail+=", reboot required" ;;
    unknown)  detail+=", reboot status unknown" ;;
  esac
  if [[ "$outcome" == current ]]; then
    suffix="; no package changes were needed."
    [[ "$detail" == "no package changes" ]] || suffix=": $detail."
  elif [[ "$outcome" == updated ]]; then
    suffix=": $detail."
  fi
  reply=("$outcome" "$detail" "$suffix")
}

# Runs one announced `apt-get update --error-on=any` with update-apt's
# dynamically scoped privilege prefix, trusted env program, environment, and
# policy. Its output stays live. REPLY: the bounded output tail. Returns APT's
# status.
_sys_apt_index_update() {
  local -a phase_status=()
  _sys_apt_announce_operation "$verbose" "$privilege_label" \
    "$apt_env_program" "$apt_environment_label" "$apt_policy_label" \
    update --error-on=any || return 2
  # APT otherwise returns success for some download failures while retaining
  # old indexes. The supported flag makes an incomplete refresh fail before
  # package mutation; older APT versions refuse the unsupported option.
  { "${privilege_prefix[@]}" "$apt_env_program" -i \
      "${apt_environment[@]}" \
      apt-get "${apt_policy[@]}" update --error-on=any </dev/null 2>&1 } \
    | _sys_apt_relay_output
  phase_status=("${pipestatus[@]}")
  return "${phase_status[1]}"
}

# Refreshes the APT indexes and renews the signing keys of known repositories
# (sys-update-apt-keys.zsh): first every dedicated keyring whose signing keys
# have all expired, then, after a failed refresh, each one whose key APT
# reported missing or expired, followed by exactly one retry. A renewed key is
# kept only after APT refreshes its repositories with it; otherwise the
# previous keyring is restored. Uses update-apt's dynamically scoped state.
# reply=(<status> <tail> <renewed-key-label> <guidance-record>)
_sys_apt_refresh_indexes() {
  local REPLY tail="" guidance="" renewed_label=""
  local -i renewal=0 update_rc=0
  local -A apt_key_context=() apt_key_outcomes=()
  local -a apt_key_pending=() apt_key_renewed=()
  _sys_apt_key_renewal_enabled 2>/dev/null && renewal=1
  {
    (( renewal )) && _sys_apt_key_renew_expired
    _sys_apt_index_update
    update_rc=$?
    tail="$REPLY"
    (( ${#apt_key_pending} == 0 )) \
      || _sys_apt_key_settle "$update_rc" "$tail"
    if (( update_rc != 0 && renewal )); then
      _sys_apt_key_renew_reported "$tail"
      if (( ${#apt_key_pending} > 0 )); then
        _sys_info "Retrying the APT index update once to verify the renewed key."
        _sys_apt_index_update
        update_rc=$?
        tail="$REPLY"
        _sys_apt_key_settle "$update_rc" "$tail"
      fi
    fi
    if (( update_rc != 0 )); then
      _sys_apt_key_guidance "$tail" "$renewal"
      guidance="$REPLY"
    fi
  } always {
    (( ${#apt_key_pending} == 0 )) || _sys_apt_key_abandon
    if [[ -n "${apt_key_context[session]-}" ]]; then
      if [[ "${apt_key_context[keep]-}" == 1 ]]; then
        _sys_warn "The private key workspace is kept for recovery: $(_sys_display_escape "${apt_key_context[session]}")"
      else
        _sys_apt_key_session_close "${apt_key_context[session]}" \
          || _sys_warn "Could not remove the private key workspace: $(_sys_display_escape "${apt_key_context[session]}")"
      fi
    fi
  }
  apt_key_renewed=("${(@u)apt_key_renewed}")
  if (( ${#apt_key_renewed} == 1 )); then
    renewed_label="${apt_key_renewed[1]} key renewed"
  elif (( ${#apt_key_renewed} > 1 )); then
    renewed_label="${(j:, :)apt_key_renewed} keys renewed"
  fi
  reply=("$update_rc" "$tail" "$renewed_label" "$guidance")
}

update-apt() {
  local REPLY
  local -i assume_yes=0 dry_run=0 include_phased_updates=0 verbose=0
  local inherited_privilege_mode="${_SYS_PRIVILEGE_NONINTERACTIVE:-0}"
  [[ "$inherited_privilege_mode" == 0 \
    || "$inherited_privilege_mode" == 1 ]] || return 2
  local -i _SYS_PRIVILEGE_NONINTERACTIVE=$inherited_privilege_mode
  local -a reply=()
  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! dry_run && ! assume_yes \
          && ! include_phased_updates && ! verbose )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        print -u2 -r -- \
          'Usage: update-apt [--dry-run] [-y|--yes] [-v|--verbose] [--include-phased-updates] [-h|--help]'
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      -y|--yes)  assume_yes=1 ;;
      -v|--verbose) verbose=1 ;;
      --include-phased-updates) include_phased_updates=1 ;;
      *)
        _sys_error "Unknown option for update-apt: $1"
        return 2
        ;;
    esac
    shift
  done
  _sys_has_capability "package:apt" || {
    _sys_report_not_applicable update-apt \
      "APT is not the active package manager"
    return
  }
  # Pin PATH only after the shared capability registry is populated, so a
  # direct first invocation cannot cache host probes taken under this narrow
  # PATH for the rest of the shell session.
  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  _sys_header "APT Update Scope"
  _sys_verbose_dim "Operations: refresh indexes, full-upgrade packages, then autoremove."
  _sys_update_resolve_trusted_program env || {
    _sys_error "A trusted root-owned env program is required for APT."
    return 1
  }
  local apt_env_program="$REPLY"
  local -a apt_policy=(
    -o 'Acquire::Retries=0'
    -o 'DPkg::Lock::Timeout=0'
    -o 'Dpkg::Use-Pty=0'
    -o 'Dpkg::Options::=--force-confdef'
    -o 'Dpkg::Options::=--force-confold'
  )
  (( include_phased_updates )) \
    && apt_policy+=(
      -o 'APT::Get::Always-Include-Phased-Updates=true'
    )
  local -a apt_environment=(
    HOME=/nonexistent
    XDG_CACHE_HOME=/nonexistent
    XDG_CONFIG_HOME=/nonexistent
    XDG_DATA_HOME=/nonexistent
    LC_ALL=C
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    TERM=dumb
    DEBIAN_FRONTEND=noninteractive
    APT_LISTCHANGES_FRONTEND=none
  )
  local apt_environment_label=
  apt_environment_label="HOME=/nonexistent XDG_CACHE_HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent XDG_DATA_HOME=/nonexistent LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none"
  local simulation candidate_count=""
  local -i simulation_rc=0
  simulation=$(
    _sys_run_with_timeout 30 \
      "$apt_env_program" -i "${apt_environment[@]}" \
      apt-get "${apt_policy[@]}" -s full-upgrade </dev/null 2>/dev/null
  ) || simulation_rc=$?
  if (( simulation_rc == 0 )); then
    local upgrade_count
    upgrade_count=$(print -r -- "$simulation" | command awk '
    /^Inst / { count++ }
    END { print count + 0 }
  ')
    candidate_count="$upgrade_count"
    _sys_label "Current candidates:" \
      "$upgrade_count (advisory; APT resolves the final transaction)"
  else
    _sys_warn \
      "Unable to calculate the advisory APT snapshot (status $simulation_rc)."
    _sys_label "Current candidates:" "unavailable"
    _sys_dim \
      "An authorized execution can refresh the indexes before resolving the real transaction."
  fi
  _sys_verbose_dim \
    "APT uses lock timeout 0 and network retries 0; ZDX does not poll or rerun the step."
  if (( include_phased_updates )); then
    _sys_warn \
      "Phased updates are explicitly included for this APT transaction."
  else
    _sys_verbose_dim \
      "Ubuntu phased-update eligibility remains in effect unless --include-phased-updates is supplied."
  fi
  _sys_verbose_dim \
    "Only an exact automatic unattended-upgrade can receive one cooperative SIGTERM."
  local -i planned_key_renewals=0
  _sys_apt_key_plan "$dry_run" || return $?
  planned_key_renewals="$REPLY"

  local apt_fingerprint=""
  local plan_preauthorized="${_SYS_APT_PLAN_PREAUTHORIZED:-0}"
  [[ "$plan_preauthorized" == 0 || "$plan_preauthorized" == 1 ]] || return 2
  if [[ "$plan_preauthorized" == 1 ]]; then
    apt_fingerprint="${_SYS_APT_AUTHORIZED_FINGERPRINT:-}"
    [[ -z "$apt_fingerprint" ]] \
      || _sys_apt_validate_unattended_fingerprint "$apt_fingerprint" \
      || return 2
  else
    _sys_apt_plan_blocker || return $?
    apt_fingerprint="$REPLY"
  fi
  (( dry_run )) && {
    if (( simulation_rc != 0 )); then
      _sys_error "The APT dry run could not calculate package candidates."
      return 1
    fi
    local planned_candidates=""
    _sys_count_noun "${candidate_count:-0}" candidate
    planned_candidates="$REPLY"
    if (( planned_key_renewals > 0 )); then
      _sys_count_noun "$planned_key_renewals" "signing key" "signing keys"
      planned_candidates+=", $REPLY to renew"
    fi
    _sys_report_result planned "$planned_candidates" \
      "Dry run complete; APT state was not changed."
    return 0
  }
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive APT updates require --yes."
      return 1
    fi
    _sys_confirm "Run this privileged dynamic APT update scope?" || {
      _sys_info "Cancelled."
      return 0
      }
  fi

  local -i direct_sudo_authenticated=0
  if (( !_SYS_PRIVILEGE_NONINTERACTIVE && EUID != 0 )); then
    REPLY=0
    _sys_update_preauthenticate "APT;update-apt"
    [[ "$REPLY" == 1 ]] || {
      _sys_error \
        "APT privilege authentication is unavailable; no signal or package mutation was attempted."
      return 1
    }
    _SYS_PRIVILEGE_NONINTERACTIVE=1
    direct_sudo_authenticated=1
  fi

  # The refresher warns itself when it cannot run; APT then still fails
  # rather than reprompts.
  local direct_keepalive_handle=""
  if (( direct_sudo_authenticated )) \
    && _sys_update_start_sudo_keepalive 1; then
    direct_keepalive_handle="$REPLY"
  fi

  local _SYS_APT_AUTHORIZED_FINGERPRINT="$apt_fingerprint"
  {
    _sys_apt_prepare_transaction "$apt_fingerprint" || {
      local -i prepare_rc=$?
      _sys_report_result blocked "package state needs manual review"
      return $prepare_rc
    }
    local -a privilege_prefix=()
    _sys_resolve_privilege_prefix || return 1
    privilege_prefix=("${reply[@]}")
    local privilege_label=""
    (( ${#privilege_prefix[@]} > 0 )) \
      && privilege_label="${(j: :)privilege_prefix} "
    local apt_policy_label="${(j: :)apt_policy}"
    local -i transaction_rc=0
    local -a phase_status=()
    local phase_tail="" upgrade_tail="" autoremove_tail="" result_detail=""
    local renewed_key_label=""
    # The index output stays live; the relay keeps a bounded tail for
    # diagnosis and for the key-renewal decisions.
    _sys_apt_refresh_indexes
    phase_status=("${reply[1]}")
    phase_tail="${reply[2]}"
    renewed_key_label="${reply[3]}"
    if (( phase_status[1] != 0 )); then
      _sys_error "APT index update failed."
      _sys_apt_report_index_failure "$phase_tail" "$candidate_count" \
        "${reply[4]}"
      result_detail="$REPLY"
      transaction_rc=1
    fi
    if (( transaction_rc == 0 )); then
      _sys_apt_announce_operation "$verbose" "$privilege_label" \
        "$apt_env_program" "$apt_environment_label" "$apt_policy_label" \
        full-upgrade -y || return 2
      { "${privilege_prefix[@]}" "$apt_env_program" -i \
          "${apt_environment[@]}" \
          apt-get "${apt_policy[@]}" full-upgrade -y </dev/null 2>&1 } \
        | _sys_apt_relay_output
      phase_status=("${pipestatus[@]}")
      upgrade_tail="$REPLY"
      if (( phase_status[1] != 0 )); then
        _sys_error "APT full-upgrade failed."
        result_detail="full-upgrade failed (status ${phase_status[1]})"
        transaction_rc=1
      fi
    fi
    if (( transaction_rc == 0 )); then
      _sys_apt_announce_operation "$verbose" "$privilege_label" \
        "$apt_env_program" "$apt_environment_label" "$apt_policy_label" \
        autoremove -y || return 2
      { "${privilege_prefix[@]}" "$apt_env_program" -i \
          "${apt_environment[@]}" \
          apt-get "${apt_policy[@]}" autoremove -y </dev/null 2>&1 } \
        | _sys_apt_relay_output
      phase_status=("${pipestatus[@]}")
      autoremove_tail="$REPLY"
      if (( phase_status[1] != 0 )); then
        _sys_error "APT autoremove failed."
        result_detail="autoremove failed (status ${phase_status[1]})"
        transaction_rc=1
      fi
    fi

    # Audit the resulting dpkg state even after a failed mutation. A partial
    # package operation is exactly when this postcondition is most valuable.
    local -i post_audit_rc=0
    local reboot_state=""
    _sys_apt_dpkg_state_clean after || post_audit_rc=$?
    if (( post_audit_rc == 0 )); then
      REPLY=""
      _sys_apt_report_reboot_requirement
      reboot_state="$REPLY"
    else
      transaction_rc=1
      [[ -n "$result_detail" ]] \
        || result_detail="package state needs manual review"
    fi
    if (( transaction_rc == 0 )); then
      _sys_apt_transaction_outcome \
        "$upgrade_tail" "$autoremove_tail" "$reboot_state" \
        "$renewed_key_label"
      _sys_report_result "${reply[1]}" "${reply[2]}" \
        "APT update plan completed${reply[3]}"
    else
      _sys_report_result failed "$result_detail"
    fi
    return $transaction_rc
  } always {
    if [[ -n "$direct_keepalive_handle" ]]; then
      _sys_update_stop_sudo_keepalive "$direct_keepalive_handle" || true
      direct_keepalive_handle=""
    fi
  }
}

# Aggregate applicability predicates. update-system calls them only through
# _sys_step_applies while it freezes the plan; each mirrors its step's own
# skip conditions.

_sys_update_apt_applies() {
  _sys_has_capability "package:apt"
}

typeset -g _SYS_UPDATE_APT_SOURCED=1
