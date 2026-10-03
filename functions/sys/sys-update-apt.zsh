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
  zmodload zsh/stat 2>/dev/null \
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
  zmodload zsh/stat 2>/dev/null \
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
  zmodload zsh/stat 2>/dev/null \
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
  zmodload zsh/stat zsh/system 2>/dev/null || return 2
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

_sys_apt_report_reboot_requirement() {
  _sys_apt_reboot_required
  local marker_rc=$?
  case "$marker_rc" in
    0)
      _sys_warn \
        "A system reboot is required to finish applying package updates."
      ;;
    1)
      ;;
    *)
      _sys_warn \
        "The reboot-required marker exists but could not be validated safely; reboot status is unknown."
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
    _sys_error "APT is not the active package backend on this host."
    return 1
  }
  # Pin PATH only after the shared capability registry is populated, so a
  # direct first invocation cannot cache host probes taken under this narrow
  # PATH for the rest of the shell session.
  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  _sys_header "APT Update Scope"
  _sys_info "Operations: refresh indexes, full-upgrade packages, then autoremove."
  _sys_warn "The package snapshot below is advisory."
  _sys_dim "Refreshing indexes can change the final transaction resolved by APT."
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
  local simulation
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
    _sys_label "Current candidates:" "$upgrade_count"
  else
    _sys_warn \
      "Unable to calculate the advisory APT snapshot (status $simulation_rc)."
    _sys_label "Current candidates:" "unavailable"
    _sys_dim \
      "An authorized execution can refresh the indexes before resolving the real transaction."
  fi
  _sys_dim \
    "APT uses lock timeout 0 and network retries 0; ZDX does not poll or rerun the step."
  if (( include_phased_updates )); then
    _sys_warn \
      "Phased updates are explicitly included for this APT transaction."
  else
    _sys_dim \
      "Ubuntu phased-update eligibility remains in effect unless --include-phased-updates is supplied."
  fi
  _sys_dim \
    "Only an exact automatic unattended-upgrade can receive one cooperative SIGTERM."

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
    _sys_info "Dry run complete; APT state was not changed."
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

  local direct_keepalive_handle=""
  if (( direct_sudo_authenticated )); then
    if _sys_update_start_sudo_keepalive 1; then
      direct_keepalive_handle="$REPLY"
    else
      _sys_warn \
        "Sudo timestamp refresh could not start; APT will still fail rather than reprompt."
    fi
  fi

  local _SYS_APT_AUTHORIZED_FINGERPRINT="$apt_fingerprint"
  {
    _sys_apt_prepare_transaction "$apt_fingerprint" || return $?
    local -a privilege_prefix=()
    _sys_resolve_privilege_prefix || return 1
    privilege_prefix=("${reply[@]}")
    local privilege_label=""
    (( ${#privilege_prefix[@]} > 0 )) \
      && privilege_label="${(j: :)privilege_prefix} "
    local apt_policy_label="${(j: :)apt_policy}"
    local -i transaction_rc=0
    _sys_apt_announce_operation "$verbose" "$privilege_label" \
      "$apt_env_program" "$apt_environment_label" "$apt_policy_label" \
      update --error-on=any || return 2
    # APT otherwise returns success for some download failures while retaining
    # old indexes. The supported flag makes an incomplete refresh fail before
    # package mutation; older APT versions refuse the unsupported option.
    "${privilege_prefix[@]}" "$apt_env_program" -i \
      "${apt_environment[@]}" \
      apt-get "${apt_policy[@]}" update --error-on=any </dev/null >&2 || {
      _sys_error "APT index update failed."
      transaction_rc=1
    }
    if (( transaction_rc == 0 )); then
      _sys_apt_announce_operation "$verbose" "$privilege_label" \
        "$apt_env_program" "$apt_environment_label" "$apt_policy_label" \
        full-upgrade -y || return 2
      "${privilege_prefix[@]}" "$apt_env_program" -i \
        "${apt_environment[@]}" \
        apt-get "${apt_policy[@]}" full-upgrade -y </dev/null >&2 || {
        _sys_error "APT full-upgrade failed."
        transaction_rc=1
      }
    fi
    if (( transaction_rc == 0 )); then
      _sys_apt_announce_operation "$verbose" "$privilege_label" \
        "$apt_env_program" "$apt_environment_label" "$apt_policy_label" \
        autoremove -y || return 2
      "${privilege_prefix[@]}" "$apt_env_program" -i \
        "${apt_environment[@]}" \
        apt-get "${apt_policy[@]}" autoremove -y </dev/null >&2 || {
        _sys_error "APT autoremove failed."
        transaction_rc=1
      }
    fi

    # Audit the resulting dpkg state even after a failed mutation. A partial
    # package operation is exactly when this postcondition is most valuable.
    local -i post_audit_rc=0
    _sys_apt_dpkg_state_clean after || post_audit_rc=$?
    if (( post_audit_rc == 0 )); then
      _sys_apt_report_reboot_requirement
    else
      transaction_rc=1
    fi
    if (( transaction_rc == 0 )); then
      _sys_success "APT update plan completed."
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
