#!/usr/bin/env zsh
# =============================================================================
# System Update: package, SDK and tooling update helpers
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, sys-capabilities.zsh, and the
# platform adapters.
# Safe to re-source; defines functions and lock-state defaults only.
#

if [[ -n "${_SYS_UPDATE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Return 0 and set REPLY to "run" or "help"; invalid arguments return 2.
_sys_update_parse_no_args() {
  local command_name="$1"
  shift
  REPLY="run"
  if (( $# == 0 )); then
    return 0
  fi
  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print -u2 -r -- "Usage: $command_name [-h|--help]"
    REPLY="help"
    return 0
  fi
  _sys_error "Unknown or extra argument for $command_name: $1"
  return 2
}

# Shared grammar for the plan-based updaters: [--dry-run] [-y|--yes] [-h|--help].
# Returns 0 with reply=(dry_run assume_yes), or REPLY="help" after printing
# usage. Unknown or extra arguments return 2 before any probe runs.
_sys_update_parse_plan_flags() {
  local command_name="$1"
  shift
  local -i assume_yes=0 dry_run=0
  REPLY="run"
  reply=()
  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! dry_run && ! assume_yes )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        print -u2 -r -- \
          "Usage: $command_name [--dry-run] [-y|--yes] [-h|--help]"
        REPLY="help"
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      -y|--yes)  assume_yes=1 ;;
      *)
        _sys_error "Unknown option for $command_name: $1"
        return 2
        ;;
    esac
    shift
  done
  reply=("$dry_run" "$assume_yes")
  return 0
}

# =============================================================================
# PACKAGE MANAGERS
# =============================================================================

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

_sys_update_counted_noun() {
  local count="${1:-}" singular="${2:-}" plural="${3:-}"
  [[ "$count" == <-> && -n "$singular" && -n "$plural" ]] || return 2
  if (( count == 1 )); then
    REPLY="$singular"
  else
    REPLY="$plural"
  fi
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

_sys_brew_askpass_program() {
  local program="/usr/bin/false"
  local -A program_state=()
  zmodload zsh/stat 2>/dev/null \
    && [[ -f "$program" && ! -L "$program" && -x "$program" ]] \
    && zstat -H program_state "$program" 2>/dev/null || return 1
  (( program_state[uid] == 0 \
    && program_state[nlink] == 1 \
    && (program_state[mode] & 8#22) == 0 )) || return 1
  REPLY="$program"
}

update-brew() {
  local REPLY
  _sys_update_parse_no_args update-brew "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Homebrew"

  if ! command -v brew &>/dev/null; then
    _sys_info "Homebrew not installed, skipping."
    return 0
  fi

  local brew_program
  brew_program=$(whence -p brew 2>/dev/null) \
    && [[ "$brew_program" == /* \
      && "$brew_program" != *[[:cntrl:]]* ]] || {
    _sys_error "Homebrew did not resolve to an executable path."
    return 1
  }
  local -x HOMEBREW_CURL_RETRIES=0
  local -x HOMEBREW_NO_ANALYTICS=1
  # Do not let a runner or caller suppress the explicit metadata refresh or
  # inject an askpass program. The mutation phases set their own fixed policy.
  local HOMEBREW_NO_AUTO_UPDATE SUDO_ASKPASS
  unset HOMEBREW_NO_AUTO_UPDATE SUDO_ASKPASS
  if _sys_has_capability "os:darwin"; then
    _sys_brew_askpass_program || {
      _sys_error \
        "The trusted /usr/bin/false askpass guard is unavailable; refusing a Homebrew run that could prompt invisibly."
      return 1
    }
    local askpass_program="$REPLY"
    local -x SUDO_ASKPASS="$askpass_program"
  fi

  _sys_info "Fetching latest formulae..."
  _sys_dim \
    "The metadata refresh is bounded to 120s with Homebrew curl retries disabled."
  _sys_warn \
    "Homebrew exposes no supported zero-wait control for its internal download locks; ZDX will not kill an active package mutation."
  # The refresh is a download, not a package mutation, so it may be bounded.
  # The absolute executable prevents a caller-defined shell function from
  # intercepting the timeout fallback or dropping the non-interactive policy.
  local -i refresh_rc=0
  _sys_run_with_timeout 120 \
    "$brew_program" update </dev/null >&2 || refresh_rc=$?
  if (( refresh_rc == 124 )); then
    _sys_error "Homebrew metadata refresh timed out after 120s."
    return 1
  elif (( refresh_rc != 0 )); then
    _sys_error "Homebrew update failed."
    return 1
  fi

  # Mutating phases run to their reported result. HOMEBREW_NO_AUTO_UPDATE
  # prevents each phase from starting a second, unbounded metadata fetch.
  local -x HOMEBREW_NO_AUTO_UPDATE=1
  _sys_info "Upgrading packages..."
  if ! "$brew_program" upgrade --no-ask </dev/null >&2; then
    _sys_error "Homebrew upgrade failed."
    return 1
  fi

  _sys_info "Removing unused dependencies..."
  if ! "$brew_program" autoremove </dev/null >&2; then
    _sys_error "Homebrew autoremove failed."
    return 1
  fi

  _sys_info "Cleaning up old versions..."
  if ! "$brew_program" cleanup </dev/null >&2; then
    _sys_error "Homebrew cleanup failed."
    return 1
  fi

  _sys_success "Homebrew updated."
}

update-snap() {
  local REPLY
  local -a reply=()
  _sys_update_parse_plan_flags update-snap "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  local -i dry_run="${reply[1]}" assume_yes="${reply[2]}"
  _sys_header "Snap Update Scope"

  if ! command -v snap &>/dev/null; then
    _sys_info "Snap not installed, skipping."
    return 0
  fi

  if ! _sys_snap_ready; then
    _sys_error "snapd is not available on this host."
    return 1
  fi

  local refresh_plan=""
  local -i refresh_plan_rc=0
  refresh_plan=$(
    LC_ALL=C _sys_run_bounded_probe 30 262144 \
      snap refresh --list </dev/null 2>&1
  ) || refresh_plan_rc=$?
  if (( refresh_plan_rc == 124 )); then
    _sys_error "Snap refresh discovery timed out after 30s."
    return 1
  elif (( refresh_plan_rc != 0 )); then
    _sys_error "Snap could not calculate the refresh plan."
    return 1
  fi
  if [[ -z "${refresh_plan//[[:space:]]/}" \
    || "$refresh_plan" == "All snaps up to date." ]]; then
    _sys_info "No Snap refreshes are currently pending."
    return 0
  fi
  _sys_warn "The records below are an advisory snapshot."
  _sys_dim "snap refresh resolves the final transaction when it executes."
  _sys_info "Currently pending Snap refreshes:"
  local plan_line
  for plan_line in "${(@f)refresh_plan}"; do
    _sys_dim "$(_sys_display_escape "$plan_line")"
  done
  (( dry_run )) && {
    _sys_info "Dry run complete; Snap packages were not changed."
    return 0
  }
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive Snap updates require --yes."
      return 1
    fi
    _sys_confirm "Run the privileged dynamic Snap refresh scope?" || {
      _sys_info "Cancelled."
      return 0
    }
  fi

  local -a privilege_prefix=()
  _sys_resolve_privilege_prefix || return 1
  privilege_prefix=("${reply[@]}")
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  _sys_info "Privileged operation: ${privilege_label}snap refresh"
  if "${privilege_prefix[@]}" snap refresh </dev/null >&2; then
    _sys_success "Snap packages updated."
  else
    _sys_error "Snap refresh failed."
    return 1
  fi
}

_sys_update_resolve_trusted_program() {
  local requested_program="${1:-dnf}"
  [[ "$requested_program" == "apt-config" \
    || "$requested_program" == "dnf" \
    || "$requested_program" == "dpkg" \
    || "$requested_program" == "dpkg-query" \
    || "$requested_program" == "env" \
    || "$requested_program" == "zsh" ]] || return 2
  local program
  program=$(whence -p "$requested_program" 2>/dev/null) || return 1
  [[ "$program" == /* && "$program" != *[[:cntrl:]]* ]] || return 1
  program="${program:A}"
  local -A program_state=()
  zmodload zsh/stat 2>/dev/null \
    && [[ -f "$program" && ! -L "$program" && -x "$program" ]] \
    && zstat -H program_state "$program" 2>/dev/null || return 1
  (( program_state[uid] == 0 \
    && (program_state[mode] & 8#22) == 0 )) || return 1
  local -A directory_state=()
  local directory_cursor="" directory_component
  for directory_component in "${(@s:/:)${program:h}}"; do
    [[ -n "$directory_component" ]] || continue
    directory_cursor+="/$directory_component"
    [[ -d "$directory_cursor" && ! -L "$directory_cursor" ]] \
      && zstat -H directory_state "$directory_cursor" 2>/dev/null \
      || return 1
    (( directory_state[uid] == 0 \
      && (directory_state[mode] & 8#22) == 0 )) || return 1
  done
  REPLY="$program"
}

# Compatibility name kept local to the DNF helpers and their focused tests.
_sys_dnf_resolve_trusted_program() {
  _sys_update_resolve_trusted_program "$@"
}

_sys_dnf_major_version() {
  local dnf_program="${1:-}"
  [[ "$dnf_program" == /* && "$dnf_program" != *[[:cntrl:]]* ]] \
    || return 2
  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  _sys_dnf_resolve_trusted_program env || {
    _sys_error "A trusted root-owned env program is required for DNF probes."
    return 1
  }
  local env_program="$REPLY"
  local -a clean_environment=(
    -i
    HOME=/nonexistent
    XDG_CACHE_HOME=/nonexistent
    XDG_CONFIG_HOME=/nonexistent
    XDG_DATA_HOME=/nonexistent
    LC_ALL=C
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    TERM=dumb
    DNF5_FORCE_INTERACTIVE=0
    PYTHONNOUSERSITE=1
  )
  local version_output
  version_output=$(
    _sys_run_bounded_probe 10 16384 \
      "$env_program" "${clean_environment[@]}" \
      "$dnf_program" --version </dev/null 2>/dev/null
  ) || {
    _sys_error "DNF did not return a bounded version record."
    return 1
  }
  local first_line="${version_output%%$'\n'*}"
  local -a match=()
  reply=()
  if [[ "$first_line" \
    =~ '^dnf5 version (5)\.([0-9]+)\.([0-9]+)\.([0-9]+)$' ]]; then
    REPLY=5
    reply=("${match[@]}")
  elif [[ "$first_line" =~ '^(4)\.([0-9]+)\.([0-9]+)$' ]]; then
    REPLY=4
    reply=("${match[@]}")
  else
    _sys_error "DNF returned an unsupported version record."
    return 1
  fi
}

_sys_dnf5_persistdir() {
  local dnf_program="${1:-}"
  [[ "$dnf_program" == /* && "$dnf_program" != *[[:cntrl:]]* ]] \
    || return 2
  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  _sys_dnf_resolve_trusted_program env || {
    _sys_error "A trusted root-owned env program is required for DNF5 probes."
    return 1
  }
  local env_program="$REPLY"
  local -a clean_environment=(
    -i
    HOME=/nonexistent
    XDG_CACHE_HOME=/nonexistent
    XDG_CONFIG_HOME=/nonexistent
    XDG_DATA_HOME=/nonexistent
    LC_ALL=C
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    TERM=dumb
    DNF5_FORCE_INTERACTIVE=0
    PYTHONNOUSERSITE=1
  )
  local config_output
  config_output=$(
    _sys_run_bounded_probe 10 262144 \
      "$env_program" "${clean_environment[@]}" \
      "$dnf_program" --dump-main-config </dev/null 2>/dev/null
  ) || {
    _sys_error "DNF5 did not return a bounded main configuration."
    return 1
  }

  local persistdir="" installroot="" skip_system_repo_lock="" config_line
  local -i persistdir_records=0 installroot_records=0 skip_lock_records=0
  for config_line in "${(@f)config_output}"; do
    case "$config_line" in
      'persistdir = '*)
        (( ++persistdir_records ))
        persistdir="${config_line#persistdir = }"
        ;;
      'installroot = '*)
        (( ++installroot_records ))
        installroot="${config_line#installroot = }"
        ;;
      'skip_system_repo_lock = '*)
        (( ++skip_lock_records ))
        skip_system_repo_lock="${config_line#skip_system_repo_lock = }"
        ;;
    esac
  done
  (( persistdir_records == 1 && installroot_records == 1 \
    && skip_lock_records <= 1 )) \
    && [[ "$installroot" == "/" \
      && "$persistdir" == /* \
      && "$persistdir" != "/" \
      && "$persistdir" != *[[:cntrl:]]* \
      && ${#persistdir} -le 4096 \
      && "${persistdir:a}" == "$persistdir" \
      && ( "$skip_lock_records" == 0 \
        || "$skip_system_repo_lock" == "True" \
        || "$skip_system_repo_lock" == "False" \
        || "$skip_system_repo_lock" == "true" \
        || "$skip_system_repo_lock" == "false" \
        || "$skip_system_repo_lock" == 0 \
        || "$skip_system_repo_lock" == 1 ) ]] || {
    _sys_error \
      "DNF5's effective system-root and persistdir could not be frozen safely."
    return 1
  }
  reply=("$persistdir" "$(( skip_lock_records == 1 ))")
  REPLY="$persistdir"
}

# Run DNF5 inside one trusted root Zsh wrapper. A trusted env(1) starts DNF with
# a fixed empty environment; proxy policy must therefore come from root-owned
# DNF configuration rather than caller-controlled variables. No environment
# data crosses the privilege boundary in argv or survives into DNF.
#
# DNF5 5.4 and newer waits on its system-repository lock. In guarded mode the
# wrapper takes the same whole-file fcntl write lock once, holds it while DNF5
# runs with only that redundant lock disabled, and leaves DNF5's separate
# transaction lock enabled. No active mutation is timed out.
_sys_dnf5_run_sanitized() {
  local lock_mode="${1:-}"
  local privilege_label="${2:-}"
  local dnf_program="${3:-}"
  local persistdir="${4:-}"
  shift 4 2>/dev/null || return 2
  local -a privilege_prefix=("$@")
  [[ "$lock_mode" == 0 || "$lock_mode" == 1 ]] || return 2
  [[ "$dnf_program" == /* && "$dnf_program" != *[[:cntrl:]]* ]] \
    || return 2
  if (( lock_mode )) \
    || [[ -n "$persistdir" ]]; then
    [[ "$persistdir" == /* && "$persistdir" != "/" \
      && "$persistdir" != *[[:cntrl:]]* \
      && "${persistdir:a}" == "$persistdir" ]] || return 2
  fi

  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  local REPLY
  _sys_dnf_resolve_trusted_program zsh || {
    _sys_error "A trusted root-owned Zsh is required for the DNF5 runner."
    return 1
  }
  local zsh_program="$REPLY"
  _sys_dnf_resolve_trusted_program env || {
    _sys_error "A trusted root-owned env program is required for DNF5."
    return 1
  }
  local env_program="$REPLY"
  local -a fixed_environment=(
    HOME=/nonexistent
    XDG_CACHE_HOME=/nonexistent
    XDG_CONFIG_HOME=/nonexistent
    XDG_DATA_HOME=/nonexistent
    LC_ALL=C
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    TERM=dumb
    DNF5_FORCE_INTERACTIVE=0
    PYTHONNOUSERSITE=1
  )
  local lock_path=""
  (( lock_mode )) && lock_path="${persistdir%/}/system-repo.lock"
  local wrapper_source='
setopt LOCAL_OPTIONS NO_UNSET
zmodload zsh/stat 2>/dev/null || exit 70
local lock_mode="$1" lock_path="$2" persistdir="$3" dnf_program="$4"
local env_program="$5"
[[ "$lock_mode" == 0 || "$lock_mode" == 1 ]] || exit 70
[[ "$dnf_program" == /* && "$dnf_program" != *[[:cntrl:]]* \
  && "$env_program" == /* && "$env_program" != *[[:cntrl:]]* ]] || exit 70
if (( lock_mode )) || [[ -n "$persistdir" ]]; then
  [[ "$persistdir" == /* && "$persistdir" != "/" \
    && "$persistdir" != *[[:cntrl:]]* \
    && "${persistdir:a}" == "$persistdir" ]] || exit 70
fi
if (( lock_mode )); then
  [[ "$lock_path" == "${persistdir%/}/system-repo.lock" ]] || exit 70
else
  [[ -z "$lock_path" ]] || exit 70
fi

local -A path_state=() program_state=()
local trusted_directory path_cursor path_component
local -a trusted_directories=("${dnf_program:h}" "${env_program:h}")
[[ -n "$persistdir" ]] && trusted_directories=("$persistdir" "${trusted_directories[@]}")
for trusted_directory in "${trusted_directories[@]}"; do
  path_cursor=""
  for path_component in "${(@s:/:)trusted_directory}"; do
    [[ -n "$path_component" ]] || continue
    path_cursor+="/$path_component"
    [[ -d "$path_cursor" && ! -L "$path_cursor" ]] \
      && zstat -H path_state "$path_cursor" 2>/dev/null || exit 70
    (( path_state[uid] == 0 && (path_state[mode] & 8#22) == 0 )) || exit 70
  done
done
[[ -f "$dnf_program" && ! -L "$dnf_program" && -x "$dnf_program" ]] \
  && zstat -H program_state "$dnf_program" 2>/dev/null || exit 70
(( program_state[uid] == 0 && (program_state[mode] & 8#22) == 0 )) || exit 70
[[ -f "$env_program" && ! -L "$env_program" && -x "$env_program" ]] \
  && zstat -H program_state "$env_program" 2>/dev/null || exit 70
(( program_state[uid] == 0 && (program_state[mode] & 8#22) == 0 )) || exit 70

local -a dnf_arguments=(
  --installroot=/
)
[[ -n "$persistdir" ]] \
  && dnf_arguments+=("--setopt=persistdir=$persistdir")
local -i lock_fd=-1 lock_rc=0 dnf_rc=0
if (( lock_mode )); then
  zmodload zsh/system 2>/dev/null || exit 70
  if [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
    local -i create_fd=-1
    local previous_umask
    previous_umask=$(umask) || exit 70
    umask 0022
    sysopen -w -m 0664 -o create,excl,nofollow,cloexec \
      -u create_fd -- "$lock_path" 2>/dev/null
    local -i create_rc=$?
    umask "$previous_umask" || exit 70
    if (( create_rc != 0 )); then
      [[ -e "$lock_path" || -L "$lock_path" ]] || exit 70
    fi
    (( create_fd >= 0 )) && exec {create_fd}>&-
  fi
  local -A lock_state=()
  [[ -f "$lock_path" && ! -L "$lock_path" ]] \
    && zstat -H lock_state "$lock_path" 2>/dev/null || exit 70
  (( lock_state[uid] == 0 && lock_state[nlink] == 1 \
    && (lock_state[mode] & 8#2) == 0 )) || exit 70
  zsystem flock -t 0 -f lock_fd "$lock_path" 2>/dev/null \
    || lock_rc=$?
  if (( lock_rc != 0 )); then
    print -u2 -r -- \
      "DNF5 system repository is busy; strict no-wait policy aborted this step."
    exit 75
  fi
  dnf_arguments+=(--setopt=skip_system_repo_lock=True)
fi
dnf_arguments+=(--assumeyes --refresh upgrade)

if (( lock_mode )); then
  {
    "$env_program" -i HOME=/nonexistent XDG_CACHE_HOME=/nonexistent \
      XDG_CONFIG_HOME=/nonexistent XDG_DATA_HOME=/nonexistent LC_ALL=C \
      PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb \
      DNF5_FORCE_INTERACTIVE=0 PYTHONNOUSERSITE=1 \
      "$dnf_program" "${dnf_arguments[@]}" </dev/null
    dnf_rc=$?
  } always {
    zsystem flock -u "$lock_fd" 2>/dev/null || true
  }
else
  "$env_program" -i HOME=/nonexistent XDG_CACHE_HOME=/nonexistent \
    XDG_CONFIG_HOME=/nonexistent XDG_DATA_HOME=/nonexistent LC_ALL=C \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM=dumb \
    DNF5_FORCE_INTERACTIVE=0 PYTHONNOUSERSITE=1 \
    "$dnf_program" "${dnf_arguments[@]}" </dev/null
  dnf_rc=$?
fi
exit $dnf_rc
'

  local wrapper_label="sanitized runner"
  (( lock_mode )) && wrapper_label="no-wait lock guard"
  _sys_info \
    "Privileged operation: ${privilege_label}$(_sys_display_escape "$env_program") -i <fixed-system-environment> $(_sys_display_escape "$zsh_program") -fc <fixed DNF5 $wrapper_label> zdx-dnf5-runner $lock_mode $(_sys_display_escape "$lock_path") $(_sys_display_escape "$persistdir") $(_sys_display_escape "$dnf_program") $(_sys_display_escape "$env_program")"
  local skip_lock_label=""
  local persistdir_label=""
  [[ -n "$persistdir" ]] \
    && persistdir_label=" --setopt=persistdir=$(_sys_display_escape "$persistdir")"
  (( lock_mode )) \
    && skip_lock_label=" --setopt=skip_system_repo_lock=True"
  _sys_dim \
    "Sanitized command: env -i <fixed-system-environment> $(_sys_display_escape "$dnf_program") --installroot=/${persistdir_label}${skip_lock_label} --assumeyes --refresh upgrade"
  "${privilege_prefix[@]}" "$env_program" -i \
    "${fixed_environment[@]}" \
    "$zsh_program" -fc "$wrapper_source" \
    zdx-dnf5-runner \
    "$lock_mode" "$lock_path" "$persistdir" "$dnf_program" \
    "$env_program" >&2
}

_sys_dnf5_run_without_system_lock() {
  _sys_dnf5_run_sanitized 0 "$@"
}

_sys_dnf5_run_guarded() {
  _sys_dnf5_run_sanitized 1 "$@"
}

_sys_update_render_platform_plan() {
  local plan_output="$1"
  local -a plan_lines=()
  [[ -n "$plan_output" ]] && plan_lines=("${(@f)plan_output}")
  if (( ${#plan_lines[@]} == 0 )); then
    _sys_info "The package manager reported no pending package records."
    return 0
  fi

  _sys_info "Current package-manager plan:"
  local plan_line
  local -i displayed=0 total_lines=0
  for plan_line in "${plan_lines[@]}"; do
    [[ -n "$plan_line" ]] && (( ++total_lines ))
  done
  for plan_line in "${plan_lines[@]}"; do
    [[ -n "$plan_line" ]] || continue
    _sys_dim "$plan_line"
    (( ++displayed >= 50 )) && break
  done
  (( total_lines > displayed )) \
    && _sys_dim "... and $(( total_lines - displayed )) more line(s)"
}

# Private aggregate step for native package backends without a dedicated
# public update command. The caller has already selected update-system.
_sys_update_platform_packages() {
  local assume_yes="${1:-0}"
  local dry_run="${2:-0}"
  local -a reply=()
  local package_backend
  package_backend=$(_sys_capability_value package_manager) || return 1
  if _sys_has_capability "os-updates:softwareupdate"; then
    package_backend="softwareupdate"
  fi
  case "$package_backend" in
    dnf|pacman|zypper|apk|softwareupdate) ;;
    *) return 2 ;;
  esac
  if ! command -v "$package_backend" &>/dev/null; then
    _sys_error "The detected package backend is no longer available: $package_backend"
    return 1
  fi

  _sys_header "Native Package Update Scope"
  _sys_label "Backend:" "$package_backend"
  _sys_warn "Any package records shown below are an advisory snapshot."
  _sys_dim "The final transaction is resolved after repository metadata refresh."
  local plan_output="" plan_rc=0
  local -i render_platform_plan=1
  local -i dnf5_minor=0 dnf5_lock_capable=0
  local dnf_program="" dnf_major="" dnf5_persistdir=""
  case "$package_backend" in
    dnf)
      _sys_dnf_resolve_trusted_program dnf || {
        _sys_error "The active DNF executable is not a trusted root-owned program."
        return 1
      }
      dnf_program="$REPLY"
      _sys_dnf_major_version "$dnf_program" || return 1
      dnf_major="$REPLY"
      if [[ "$dnf_major" == 4 ]]; then
        _sys_warn \
          "DNF4 cannot represent zero download retries; retries=1 is its minimum finite policy."
        plan_output=$(
          _sys_run_with_timeout 60 \
            "$dnf_program" --setopt=exit_on_lock=True \
              --setopt=retries=1 -q check-update </dev/null 2>&1
        ) || plan_rc=$?
        (( plan_rc == 0 || plan_rc == 100 )) || {
          _sys_error "DNF4 could not calculate an update plan."
          return 1
        }
      else
        (( ${#reply[@]} == 4 )) \
          && [[ "${reply[1]}" == 5 && "${reply[2]}" == <-> ]] || {
          _sys_error "DNF5 returned an incomplete canonical version record."
          return 1
        }
        dnf5_minor="${reply[2]}"
        if (( dnf5_minor >= 2 )); then
          _sys_dnf5_persistdir "$dnf_program" || return 1
          (( ${#reply[@]} == 2 )) \
            && [[ "${reply[1]}" == "$REPLY" \
              && ( "${reply[2]}" == 0 || "${reply[2]}" == 1 ) ]] || {
            _sys_error "DNF5 returned an inconsistent configuration record."
            return 1
          }
          dnf5_persistdir="${reply[1]}"
          dnf5_lock_capable="${reply[2]}"
        fi
        if (( dnf5_minor >= 4 && ! dnf5_lock_capable )); then
          _sys_error \
            "DNF5 5.4 or newer did not expose its required system-repository lock control."
          return 1
        fi
        render_platform_plan=0
        if (( dnf5_lock_capable )); then
          _sys_warn \
            "DNF5 candidate rendering is skipped because its read path can wait on the system-repository lock."
          _sys_dim \
            "Execution uses a held non-blocking lock guard; DNF5 still owns final dependency resolution."
        else
          if (( dnf5_minor < 2 )); then
            _sys_dim \
              "This early DNF5 path does not depend on config dumping and has no system-repository wait lock; its transaction lock remains non-blocking."
          else
            _sys_dim \
              "This pre-5.4 DNF5 has no system-repository wait lock; its transaction lock remains non-blocking."
          fi
        fi
      fi
      ;;
    pacman)
      plan_output=$(_sys_run_with_timeout 60 pacman -Qu </dev/null 2>&1) \
        || plan_rc=$?
      (( plan_rc == 0 || plan_rc == 1 )) || {
        _sys_error "Pacman could not calculate an update plan."
        return 1
      }
      ;;
    zypper)
      _sys_warn \
        "Zypper has no supported zero-retry override for its internal soft media-error policy."
      plan_output=$(
        _sys_run_with_timeout 60 \
          zypper --non-interactive list-updates </dev/null 2>&1
      ) || plan_rc=$?
      (( plan_rc == 0 || plan_rc == 100 )) || {
        _sys_error "Zypper could not calculate an update plan."
        return 1
      }
      ;;
    apk)
      plan_output=$(
        _sys_run_with_timeout 60 apk version -l '<' </dev/null 2>&1
      ) || plan_rc=$?
      (( plan_rc == 0 )) || {
        _sys_error "APK could not calculate an update plan."
        return 1
      }
      ;;
    softwareupdate)
      plan_output=$(
        _sys_run_with_timeout 120 softwareupdate --list </dev/null 2>&1
      ) || plan_rc=$?
      (( plan_rc == 0 )) || {
        _sys_error "softwareupdate could not calculate an update plan."
        return 1
      }
      _sys_warn "A macOS update may require a restart."
      ;;
  esac
  (( render_platform_plan )) \
    && _sys_update_render_platform_plan "$plan_output"
  if (( dry_run )); then
    _sys_info "Dry run complete; no package installation command was executed."
    return 0
  fi

  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive native package updates require --yes."
      return 1
    fi
    _sys_confirm "Run this privileged dynamic $package_backend update scope?" || {
      _sys_info "Native package update cancelled."
      return 0
    }
  fi
  local -a privilege_prefix=()
  _sys_resolve_privilege_prefix || return 1
  privilege_prefix=("${reply[@]}")
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  case "$package_backend" in
    dnf)
      if [[ "$dnf_major" == 4 ]]; then
        _sys_info \
          "Privileged operation: ${privilege_label}$(_sys_display_escape "$dnf_program") --setopt=exit_on_lock=True --setopt=retries=1 -y upgrade --refresh"
        "${privilege_prefix[@]}" "$dnf_program" \
          --setopt=exit_on_lock=True --setopt=retries=1 \
          -y upgrade --refresh </dev/null >&2
      else
        if (( dnf5_lock_capable )); then
          _sys_dnf5_run_guarded \
            "$privilege_label" "$dnf_program" "$dnf5_persistdir" \
            "${privilege_prefix[@]}"
        else
          _sys_dnf5_run_without_system_lock \
            "$privilege_label" "$dnf_program" "$dnf5_persistdir" \
            "${privilege_prefix[@]}"
        fi
      fi
      ;;
    pacman)
      _sys_info \
        "Privileged operation: ${privilege_label}pacman -Syu --noconfirm"
      "${privilege_prefix[@]}" pacman -Syu --noconfirm </dev/null >&2
      ;;
    zypper)
      _sys_info \
        "Privileged operation: ${privilege_label}zypper refresh, then update"
      "${privilege_prefix[@]}" zypper --non-interactive refresh \
        </dev/null >&2 \
        && "${privilege_prefix[@]}" zypper --non-interactive update -y \
          </dev/null >&2
      ;;
    apk)
      _sys_info \
        "Privileged operation: ${privilege_label}apk --wait 0 update, then apk --wait 0 upgrade"
      "${privilege_prefix[@]}" apk --wait 0 update </dev/null >&2 \
        && "${privilege_prefix[@]}" apk --wait 0 upgrade </dev/null >&2
      ;;
    softwareupdate)
      _sys_info \
        "Privileged operation: ${privilege_label}softwareupdate --install --all"
      "${privilege_prefix[@]}" softwareupdate --install --all \
        </dev/null >&2
      ;;
  esac
  local update_rc=$?
  (( update_rc == 0 )) || {
    _sys_error "The $package_backend package update failed."
    return "$update_rc"
  }
  _sys_success "Native $package_backend packages updated."
}

# =============================================================================
# SDKs AND RUNTIMES
# =============================================================================

update-gcloud() {
  local REPLY
  _sys_update_parse_no_args update-gcloud "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Google Cloud SDK"

  if ! command -v gcloud &>/dev/null; then
    _sys_info "gcloud not installed, skipping."
    return 0
  fi

  if command -v dpkg &>/dev/null \
    && dpkg -s google-cloud-cli &>/dev/null; then
    _sys_warn "Managed by APT — use update-apt instead."
    return 0
  fi
  if command -v brew &>/dev/null \
    && { _sys_brew list --formula google-cloud-sdk &>/dev/null \
      || _sys_brew list --cask google-cloud-sdk &>/dev/null; }; then
    _sys_warn "Managed by Homebrew — use update-brew instead."
    return 0
  fi

  _sys_info "Updating components..."
  if command gcloud components update --quiet >&2; then
    _sys_success "Google Cloud SDK updated."
  else
    _sys_error "Google Cloud SDK update failed."
    return 1
  fi
}

update-awscli() {
  local REPLY
  _sys_update_parse_no_args update-awscli "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating AWS CLI v2"

  if command -v brew &>/dev/null \
    && _sys_brew list awscli &>/dev/null 2>&1; then
    _sys_info "AWS CLI is managed by Homebrew; upgrading that formula."
    HOMEBREW_NO_AUTO_UPDATE=1 _sys_brew upgrade --no-ask awscli \
      </dev/null >&2 || {
      _sys_error "Homebrew failed to update AWS CLI."
      return 1
    }
    _sys_success "AWS CLI updated through Homebrew."
    return 0
  fi

  if command -v snap &>/dev/null \
    && command snap list aws-cli &>/dev/null 2>&1; then
    _sys_warn "AWS CLI is managed by Snap; run update-snap instead."
    return 0
  fi

  local current_version="not installed"
  command -v aws &>/dev/null \
    && current_version=$(command aws --version 2>&1 | command awk '{print $1}')
  _sys_label "Current:" "$current_version"
  _sys_error "Automatic AWS CLI bundle installation is disabled."
  _sys_dim "AWS publishes detached signatures rather than a pinned checksum."
  _sys_dim "Follow the official verification procedure before installing:"
  _sys_dim "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  return 1
}

_sys_repomix_program() {
  local program=""
  program=$(builtin whence -p repomix 2>/dev/null) || return 1
  [[ "$program" == /* && "$program" != *[[:cntrl:]]* \
    && -f "$program" && -x "$program" ]] || return 2
  REPLY="${program:A}"
}

_sys_repomix_homebrew_managed() {
  local program="$1" brew_prefix=""
  command -v brew &>/dev/null || return 1
  brew_prefix=$(_sys_brew --prefix 2>/dev/null) || return 1
  [[ "$brew_prefix" == /* && "$brew_prefix" != *[[:cntrl:]]* \
    && -d "$brew_prefix" ]] || return 1
  [[ "$program" == "${brew_prefix:A}"/Cellar/repomix/* \
    || "$program" == "${brew_prefix:A}"/opt/repomix/* ]]
}

# Bind the active launcher to the installed package's passive bin descriptor.
# A separate npm installation cannot claim an earlier custom executable in PATH.
_sys_repomix_npm_binding() {
  local program="$1" npm_program="$2" node_program="$3"
  local npm_prefix="" npm_root=""
  npm_prefix=$(
    _sys_run_bounded_probe 3 65536 "$npm_program" config get prefix 2>/dev/null
  ) || return 1
  npm_root=$(
    _sys_run_bounded_probe 3 65536 "$npm_program" root -g 2>/dev/null
  ) || return 1
  [[ "$npm_prefix" == /* && "$npm_prefix" != / \
    && "$npm_prefix" != *[[:cntrl:]]* \
    && "$npm_root" == "$npm_prefix/lib/node_modules" ]] || return 1
  local package_dir="$npm_root/repomix"
  local descriptor="$package_dir/package.json"
  _sys_update_validate_owned_path "$npm_prefix" "$descriptor" file || return 1
  local bin_relative=""
  bin_relative=$(
    _sys_run_bounded_probe 3 65536 "$node_program" --input-type=commonjs -e '
const fs = require("node:fs");
const file = process.argv[1];
const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
const before = fs.fstatSync(fd);
if (!before.isFile() || before.nlink !== 1 ||
    before.size > 65536 || before.uid !== process.getuid() || (before.mode & 0o22)) {
  process.exit(1);
}
const buffer = Buffer.alloc(65537);
const bytes = fs.readSync(fd, buffer, 0, buffer.length, 0);
const after = fs.fstatSync(fd);
const live = fs.lstatSync(file);
fs.closeSync(fd);
if (bytes > 65536 || live.isSymbolicLink() ||
    live.dev !== before.dev || live.ino !== before.ino) process.exit(1);
if (before.dev !== after.dev || before.ino !== after.ino ||
    before.size !== after.size || before.mtimeMs !== after.mtimeMs ||
    before.ctimeMs !== after.ctimeMs) process.exit(1);
const data = JSON.parse(buffer.subarray(0, bytes).toString("utf8"));
const bin = typeof data.bin === "string" ? data.bin : data.bin?.repomix;
if (data.name !== "repomix" || typeof bin !== "string" || bin.length > 4096 ||
    !bin || bin.startsWith("/") || /[\x00-\x1f\x7f]/.test(bin) ||
    bin.split("/").some(part => !part || part === "..")) process.exit(1);
process.stdout.write(bin);
' "$descriptor" 2>/dev/null
  ) || return 1
  _sys_update_validate_owned_path \
    "$package_dir" "$package_dir/$bin_relative" file || return 1
  [[ "$REPLY" == "$program" && -x "$REPLY" ]] || return 1
  REPLY="$npm_prefix"
}

_sys_repomix_version() {
  local program="$1" version_output=""
  version_output=$(
    _sys_run_bounded_probe 3 65536 "$program" --version 2>/dev/null
  ) || return 1
  [[ -n "$version_output" && ${#version_output} -le 256 \
    && "$version_output" != *[[:cntrl:]]* ]] || return 1
  REPLY="$version_output"
}

update-repomix() {
  local REPLY
  _sys_update_parse_no_args update-repomix "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Repomix CLI"

  local -i resolve_rc=0
  _sys_repomix_program || resolve_rc=$?
  if (( resolve_rc == 1 )); then
    _sys_info "No external Repomix executable is installed, skipping."
    return 0
  elif (( resolve_rc != 0 )); then
    _sys_error "The active Repomix executable could not be resolved safely."
    return 1
  fi
  local current_binary="$REPLY"
  if _sys_repomix_homebrew_managed "$current_binary"; then
    _sys_warn "Managed by Homebrew — use update-brew instead."
    return 0
  fi

  local node_program="" npm_program=""
  node_program=$(builtin whence -p node 2>/dev/null)
  npm_program=$(builtin whence -p npm 2>/dev/null)
  [[ "$node_program" == /* && "$node_program" != *[[:cntrl:]]* \
    && -f "$node_program" && -x "$node_program" ]] || {
    _sys_error "An external Node.js executable is required to update Repomix."
    return 1
  }
  [[ "$npm_program" == /* && "$npm_program" != *[[:cntrl:]]* \
    && -f "$npm_program" && -x "$npm_program" ]] || {
    _sys_error "An external npm executable is required to update Repomix."
    return 1
  }
  node_program="${node_program:A}"
  npm_program="${npm_program:A}"
  local node_version=""
  node_version=$(
    _sys_run_bounded_probe 3 65536 "$node_program" --version 2>/dev/null
  ) || node_version=""
  [[ "$node_version" == v<->.<->.<-> ]] || {
    _sys_error "Could not verify the Node.js version required by Repomix."
    return 1
  }
  local node_major="${${node_version#v}%%.*}"
  (( node_major >= 20 )) || {
    _sys_error "Repomix requires Node.js 20 or newer. Current: $node_version"
    return 1
  }

  _sys_repomix_npm_binding \
    "$current_binary" "$npm_program" "$node_program" || {
    _sys_error "The active Repomix executable does not belong to the selected npm global package."
    _sys_dim "Update it through its original installation method; no npm package was changed."
    return 1
  }
  local npm_prefix="$REPLY"
  _sys_repomix_version "$current_binary" || {
    _sys_error "Could not verify the installed Repomix version."
    return 1
  }
  local current_version="$REPLY"
  _sys_info "Current: $current_version"
  _sys_info "Binary: $current_binary"

  _sys_repomix_program && [[ "$REPLY" == "$current_binary" ]] \
    && _sys_repomix_npm_binding "$current_binary" "$npm_program" "$node_program" \
    && [[ "$REPLY" == "$npm_prefix" ]] || {
    _sys_error "The Repomix installation changed before its update."
    return 1
  }
  if ! _sys_npm_install_g repomix@latest "$npm_prefix" "$npm_program"; then
    _sys_warn "Repomix update failed."
    return 1
  fi
  _sys_repomix_program || {
    _sys_error "npm completed, but the updated Repomix executable is unavailable."
    return 1
  }
  local new_binary="$REPLY"
  _sys_repomix_npm_binding "$new_binary" "$npm_program" "$node_program" \
    && [[ "$REPLY" == "$npm_prefix" ]] \
    && _sys_repomix_version "$new_binary" || {
    _sys_error "npm completed, but could not verify the updated Repomix installation."
    return 1
  }
  local new_version="$REPLY"
  if [[ "$current_version" == "$new_version" ]]; then
    _sys_success "Repomix already at latest ($new_version)."
  else
    _sys_success "Repomix updated to $new_version."
  fi
  _sys_info "Binary: $new_binary"
}

# =============================================================================
# SHELL AND PROMPT
# =============================================================================

# Keep caller-provided Git routing variables from redirecting validation or
# mutation away from the repository passed with -C.
_sys_update_git_read() {
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
    unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    _sys_run_bounded_probe 10 1048576 git "$@"
  )
}

_sys_update_git_logged() {
  local label="${1:-git}"
  shift
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
    unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    # A remote Git transaction must fail visibly instead of stalling the
    # aggregate on a credential prompt, an askpass dialog, or a dead peer.
    export GIT_TERMINAL_PROMPT=0
    unset GIT_ASKPASS SSH_ASKPASS
    [[ -n "${GIT_SSH_COMMAND:-}" ]] || export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4'
    # Git aborts its own transfer below 1 KiB/s for 60s. This bounds a
    # stalled download without wrapping the mutating command in an external
    # watchdog that could return while the transaction continues.
    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0=http.lowSpeedLimit GIT_CONFIG_VALUE_0=1024
    export GIT_CONFIG_KEY_1=http.lowSpeedTime GIT_CONFIG_VALUE_1=60
    _sys_run_logged "$label" git "$@"
  )
}

# Validate an existing path below an owner-bound trust root. The trust root and
# every child component must be owned by the current user and must not be a
# symbolic link. Set REPLY to the canonical candidate path on success.
_sys_update_validate_owned_path() {
  local allowed_root="${1:-}"
  local candidate_path="${2:-}"
  local expected_type="${3:-directory}"
  [[ -n "$allowed_root" && -n "$candidate_path" \
    && "$allowed_root" == /* && "$candidate_path" == /* \
    && "$allowed_root" != *[[:cntrl:]]* \
    && "$candidate_path" != *[[:cntrl:]]* \
    && ( "$expected_type" == "directory" \
      || "$expected_type" == "file" ) ]] || return 2

  local root_lexical="${allowed_root:a}"
  local candidate_lexical="${candidate_path:a}"
  [[ -d "$root_lexical" && ! -L "$root_lexical" \
    && -O "$root_lexical" && "${root_lexical:A}" == "$root_lexical" \
    && "$candidate_lexical" == "$root_lexical"/* ]] || return 1

  local relative_path="${candidate_lexical#$root_lexical/}"
  local -a path_components=("${(@s:/:)relative_path}")
  (( ${#path_components[@]} > 0 )) || return 1

  local component current_path="$root_lexical"
  for component in "${path_components[@]}"; do
    [[ -n "$component" && "$component" != "." \
      && "$component" != ".." ]] || return 1
    current_path+="/$component"
    [[ -e "$current_path" || -L "$current_path" ]] || return 1
    [[ ! -L "$current_path" && -O "$current_path" ]] || return 1
  done

  case "$expected_type" in
    directory) [[ -d "$candidate_lexical" ]] || return 1 ;;
    file)      [[ -f "$candidate_lexical" ]] || return 1 ;;
  esac
  REPLY="${candidate_lexical:A}"
}

# Resolve the active ZDX checkout from the core's source-derived functions
# directory. This path is used only to recognize the installer's exact local
# development link; it never authorizes a Git mutation through that link.
_sys_update_active_zdx_checkout_root() {
  local functions_dir="${_ZDX_FUNCTIONS_DIR:-}"
  [[ -n "$functions_dir" \
    && "$functions_dir" == /* \
    && "$functions_dir" != *[[:cntrl:]]* ]] || return 1

  _sys_update_validate_owned_path \
    "$HOME" "$functions_dir" directory || return 1
  local functions_dir_abs="$REPLY"
  local checkout_root="${functions_dir_abs:h}"
  [[ "$functions_dir_abs" == "$checkout_root/functions" ]] || return 1

  _sys_update_validate_owned_path \
    "$HOME" "$checkout_root" directory || return 1
  checkout_root="$REPLY"

  local marker_file
  for marker_file in functions.zsh zdx-suite.plugin.zsh; do
    _sys_update_validate_owned_path \
      "$checkout_root" "$checkout_root/$marker_file" file || return 1
  done
  _sys_update_validate_owned_path \
    "$checkout_root" "$checkout_root/.git" directory || return 1

  REPLY="$checkout_root"
}

# Recognize only the local installer's exact plugins/zdx-suite symlink when it
# resolves to the active, owner-bound ZDX checkout. All other symlinks continue
# through the generic Git validator and fail closed.
_sys_update_linked_zdx_checkout() {
  local custom_dir="${1:-}"
  local repository="${2:-}"
  [[ -n "$custom_dir" && -n "$repository" \
    && "$custom_dir" == /* && "$repository" == /* \
    && "$custom_dir" != *[[:cntrl:]]* \
    && "$repository" != *[[:cntrl:]]* ]] || return 1

  _sys_update_validate_owned_path \
    "$HOME" "$custom_dir" directory || return 1
  local custom_dir_abs="$REPLY"
  local plugins_dir="$custom_dir_abs/plugins"
  _sys_update_validate_owned_path \
    "$custom_dir_abs" "$plugins_dir" directory || return 1
  plugins_dir="$REPLY"

  local expected_link="$plugins_dir/zdx-suite"
  [[ "${repository:a}" == "$expected_link" && -L "$expected_link" ]] \
    || return 1

  zmodload zsh/stat 2>/dev/null || return 1
  local -A link_before=() link_after=()
  zstat -L -H link_before -- "$expected_link" 2>/dev/null || return 1
  local raw_target="${link_before[link]:-}"
  [[ -n "${link_before[device]:-}" \
    && -n "${link_before[inode]:-}" \
    && -n "$raw_target" \
    && "$raw_target" != *[[:cntrl:]]* ]] || return 1
  (( link_before[uid] == EUID \
    && link_before[nlink] == 1 \
    && link_before[size] > 0 \
    && link_before[size] <= 4096 )) || return 1

  _sys_update_active_zdx_checkout_root || return 1
  local checkout_root="$REPLY"
  [[ "${expected_link:A}" == "$checkout_root" ]] || return 1

  zstat -L -H link_after -- "$expected_link" 2>/dev/null || return 1
  [[ -L "$expected_link" \
    && "${link_after[device]}:${link_after[inode]}:${link_after[size]}:${link_after[mtime]}:${link_after[ctime]}:${link_after[mode]}:${link_after[uid]}:${link_after[nlink]}" \
    == "${link_before[device]}:${link_before[inode]}:${link_before[size]}:${link_before[mtime]}:${link_before[ctime]}:${link_before[mode]}:${link_before[uid]}:${link_before[nlink]}" \
    && "${link_after[link]:-}" == "$raw_target" \
    && "${expected_link:A}" == "$checkout_root" ]] \
    || return 1

  REPLY="$checkout_root"
}

# Capture the complete authorization identity for a user-owned Git checkout.
# reply contains: path, origin, HEAD, repo device/inode, .git device/inode.
_sys_update_git_fingerprint() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  local allowed_root="${1:-}"
  local repository="${2:-}"

  _sys_update_validate_owned_path \
    "$allowed_root" "$repository" directory || {
      _sys_error "Git checkout is not an owned, symlink-free child of HOME: $(_sys_display_escape "$repository")"
      return 1
    }
  local repository_abs="$REPLY"
  [[ "$repository_abs" != "${allowed_root:A}" ]] || return 1

  _sys_update_validate_owned_path \
    "$repository_abs" "$repository_abs/.git" directory || {
      _sys_error "Git metadata is not an owned, symlink-free directory: $(_sys_display_escape "$repository_abs/.git")"
      _sys_dim "Linked worktrees and .git indirection files are not supported."
      return 1
    }
  local git_dir_abs="$REPLY"

  local repository_top origin origin_record current_commit
  repository_top=$(_sys_update_git_read -C "$repository_abs" \
    rev-parse --show-toplevel 2>/dev/null) || {
      _sys_error "Unable to verify Git checkout: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  [[ -n "$repository_top" \
    && "$repository_top" != *[[:cntrl:]]* \
    && "${repository_top:A}" == "$repository_abs" ]] || {
      _sys_error "Git checkout root does not match its authorized path: $(_sys_display_escape "$repository_abs")"
      return 1
    }

  origin_record=$(_sys_update_git_read -C "$repository_abs" \
    config --local --null --get-all remote.origin.url 2>/dev/null) || {
      _sys_error "Git checkout has no readable origin: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  [[ "$origin_record" == *$'\0' ]] || return 1
  origin="${origin_record%$'\0'}"
  [[ -n "$origin" && ${#origin} -le 2048 \
    && "$origin" != *[[:cntrl:]]* \
    && "$origin" != *$'\0'* ]] || {
      _sys_error "Git checkout origin is empty or contains unsafe control data: $(_sys_display_escape "$repository_abs")"
      return 1
    }

  current_commit=$(_sys_update_git_read -C "$repository_abs" \
    rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
      _sys_error "Git checkout has no verifiable HEAD commit: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  (( ${#current_commit} == 40 || ${#current_commit} == 64 )) \
    && [[ "$current_commit" == [[:xdigit:]]## ]] || {
      _sys_error "Git checkout returned an invalid HEAD identifier: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  current_commit="${current_commit:l}"

  local -A repository_state=() git_dir_state=()
  zmodload zsh/stat 2>/dev/null \
    && zstat -H repository_state "$repository_abs" 2>/dev/null \
    && zstat -H git_dir_state "$git_dir_abs" 2>/dev/null || {
      _sys_error "Unable to fingerprint Git checkout metadata: $(_sys_display_escape "$repository_abs")"
      return 1
    }
  [[ -n "${repository_state[device]:-}" \
    && -n "${repository_state[inode]:-}" \
    && -n "${git_dir_state[device]:-}" \
    && -n "${git_dir_state[inode]:-}" ]] || return 1

  reply=(
    "$repository_abs"
    "$origin"
    "$current_commit"
    "${repository_state[device]}"
    "${repository_state[inode]}"
    "${git_dir_state[device]}"
    "${git_dir_state[inode]}"
  )
  REPLY="${repository_state[device]}:${repository_state[inode]}:${git_dir_state[device]}:${git_dir_state[inode]}:${#origin}:$origin:$current_commit"
}

# Revalidate the exact Git identity authorized by the displayed update plan.
_sys_update_git_revalidate() {
  local allowed_root="${1:-}"
  local repository="${2:-}"
  local expected_fingerprint="${3:-}"
  [[ -n "$expected_fingerprint" ]] || return 2

  _sys_update_git_fingerprint "$allowed_root" "$repository" || return 1
  [[ "$REPLY" == "$expected_fingerprint" ]] || {
    _sys_error "Git checkout changed after authorization: $(_sys_display_escape "$repository")"
    return 1
  }
}

# After a successful pull, HEAD may advance but the repository and origin must
# retain the stable identity that was authorized.
_sys_update_git_revalidate_stable() {
  local allowed_root="${1:-}"
  local repository="${2:-}"
  local expected_path="${3:-}"
  local expected_origin="${4:-}"
  local expected_repo_device="${5:-}"
  local expected_repo_inode="${6:-}"
  local expected_git_device="${7:-}"
  local expected_git_inode="${8:-}"

  _sys_update_git_fingerprint "$allowed_root" "$repository" || return 1
  [[ "${reply[1]}" == "$expected_path" \
    && "${reply[2]}" == "$expected_origin" \
    && "${reply[4]}" == "$expected_repo_device" \
    && "${reply[5]}" == "$expected_repo_inode" \
    && "${reply[6]}" == "$expected_git_device" \
    && "${reply[7]}" == "$expected_git_inode" ]] || {
      _sys_error "Git checkout identity or origin changed during update: $(_sys_display_escape "$repository")"
      return 1
    }
}

# Validate that fzf's installer is an owner-bound, single-link executable whose
# content exactly matches the installer blob in the authorized HEAD.
_sys_update_fzf_install_fingerprint() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  local repository="${1:-}"
  local installer="$repository/install"

  _sys_update_validate_owned_path \
    "$repository" "$installer" file || {
      _sys_error "Refusing an unsafe fzf integration installer."
      return 1
    }
  installer="$REPLY"
  [[ -x "$installer" ]] || {
    _sys_error "fzf's tracked integration installer is not executable."
    return 1
  }

  local expected_blob actual_blob
  expected_blob=$(_sys_update_git_read -C "$repository" \
    rev-parse --verify 'HEAD:install' 2>/dev/null) || {
      _sys_error "fzf's integration installer is not tracked by HEAD."
      return 1
    }
  actual_blob=$(_sys_update_git_read -C "$repository" \
    hash-object -- install 2>/dev/null) || return 1
  (( ${#expected_blob} == 40 || ${#expected_blob} == 64 )) \
    && [[ "$expected_blob" == [[:xdigit:]]## \
      && "$actual_blob" == "$expected_blob" ]] || {
      _sys_error "fzf's integration installer differs from the authorized HEAD."
      return 1
    }

  local -A installer_state=()
  zmodload zsh/stat 2>/dev/null \
    && zstat -H installer_state "$installer" 2>/dev/null || return 1
  (( installer_state[nlink] == 1 )) || {
    _sys_error "fzf's integration installer has an unsafe hard-link count."
    return 1
  }
  REPLY="${installer_state[device]}:${installer_state[inode]}:${installer_state[size]}:${installer_state[mtime]}:${installer_state[ctime]}:${expected_blob:l}"
}

_sys_update_fzf_install_revalidate() {
  local repository="${1:-}"
  local expected_fingerprint="${2:-}"
  [[ -n "$expected_fingerprint" ]] || return 2
  _sys_update_fzf_install_fingerprint "$repository" || return 1
  [[ "$REPLY" == "$expected_fingerprint" ]] || {
    _sys_error "fzf's integration installer changed before execution."
    return 1
  }
}

_sys_update_fzf_git_dir() {
  local -a candidate_dirs=(
    "$HOME/.fzf"
    "${XDG_DATA_HOME:-$HOME/.local/share}/fzf"
    "$HOME/.local/opt/fzf"
  )
  local candidate_dir
  for candidate_dir in "${candidate_dirs[@]}"; do
    [[ -e "$candidate_dir/.git" || -L "$candidate_dir/.git" ]] || continue
    _sys_update_git_fingerprint "$HOME" "$candidate_dir" || return 2
    REPLY="${reply[1]}"
    return 0
  done
  return 1
}

update-starship() {
  local REPLY
  _sys_update_parse_no_args update-starship "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Starship"

  if ! command -v starship &>/dev/null; then
    _sys_info "Starship not installed, skipping."
    return 0
  fi

  if command -v brew &>/dev/null \
    && _sys_brew list starship &>/dev/null 2>&1; then
    _sys_info "Starship is managed by Homebrew."
    HOMEBREW_NO_AUTO_UPDATE=1 _sys_brew upgrade --no-ask starship \
      </dev/null >&2 || {
      _sys_error "Homebrew failed to update Starship."
      return 1
    }
    _sys_success "Starship updated through Homebrew."
    return 0
  fi

  if command -v cargo &>/dev/null \
    && command cargo install --list 2>/dev/null \
      | command grep -q '^starship '; then
    _sys_info "Starship is managed by Cargo."
    command env CARGO_NET_RETRY=0 \
      cargo install --locked starship >&2 || {
      _sys_error "Cargo failed to update Starship."
      return 1
    }
    _sys_success "Starship updated through Cargo."
    return 0
  fi

  _sys_error "Starship's installation owner could not be verified."
  _sys_dim "Update it with its original package manager."
  _sys_dim "Official options: https://starship.rs/installing/"
  return 1
}

update-fzf() {
  local REPLY
  local -a reply=()
  _sys_update_parse_plan_flags update-fzf "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  local -i dry_run="${reply[1]}" assume_yes="${reply[2]}"
  _sys_header "Updating fzf"

  if ! command -v fzf &>/dev/null; then
    _sys_info "fzf not installed, skipping."
    return 0
  fi

  # Managed by Homebrew
  if command -v brew &>/dev/null \
    && _sys_brew list fzf &>/dev/null 2>&1; then
    _sys_warn "Managed by Homebrew — use update-brew instead."
    return 0
  fi

  # Managed by APT
  if command -v dpkg &>/dev/null && dpkg -s fzf &>/dev/null; then
    _sys_warn "Managed by APT — use update-apt instead."
    return 0
  fi

  local fzf_dir=""
  _sys_update_fzf_git_dir
  local discovery_rc=$?
  if (( discovery_rc == 0 )); then
    fzf_dir="$REPLY"
  elif (( discovery_rc == 2 )); then
    _sys_error "Refusing an unsafe Git-owned fzf checkout."
    return 1
  fi

  if [[ -n "$fzf_dir" ]]; then
    _sys_update_git_fingerprint "$HOME" "$fzf_dir" || return 1
    fzf_dir="${reply[1]}"
    local origin="${reply[2]}"
    local current_commit="${reply[3]}"
    local expected_repo_device="${reply[4]}"
    local expected_repo_inode="${reply[5]}"
    local expected_git_device="${reply[6]}"
    local expected_git_inode="${reply[7]}"
    local expected_fingerprint="$REPLY"
    _sys_info "Git-owned fzf update plan:"
    _sys_label "Repository:" "${fzf_dir/#$HOME/~}"
    _sys_label "Origin:" "$(_sys_display_escape "$origin")"
    _sys_label "Current commit:" "$current_commit"
    (( dry_run )) && {
      _sys_info "Dry run complete; the repository was not updated."
      return 0
    }
    if (( ! assume_yes )); then
      if [[ ! -t 0 || ! -t 2 ]]; then
        _sys_error "Non-interactive Git-owned fzf updates require --yes."
        return 1
      fi
      _sys_confirm "Trust this origin and fast-forward fzf?" || {
        _sys_info "Cancelled."
        return 0
      }
    fi

    # Check once after authorization, then again immediately before the pull.
    _sys_update_git_revalidate \
      "$HOME" "$fzf_dir" "$expected_fingerprint" || return 1
    expected_fingerprint="$REPLY"
    _sys_update_git_revalidate \
      "$HOME" "$fzf_dir" "$expected_fingerprint" || return 1

    if _sys_update_git_logged \
      fzf-pull -C "$fzf_dir" pull --ff-only; then
      _sys_update_git_revalidate_stable \
        "$HOME" "$fzf_dir" "$fzf_dir" "$origin" \
        "$expected_repo_device" "$expected_repo_inode" \
        "$expected_git_device" "$expected_git_inode" || return 1
      local post_pull_fingerprint="$REPLY"

      if [[ -e "$fzf_dir/install" || -L "$fzf_dir/install" ]]; then
        _sys_update_fzf_install_fingerprint "$fzf_dir" || return 1
        local installer_fingerprint="$REPLY"
        _sys_info "Refreshing shell integration..."
        _sys_update_git_revalidate \
          "$HOME" "$fzf_dir" "$post_pull_fingerprint" || return 1
        _sys_update_fzf_install_revalidate \
          "$fzf_dir" "$installer_fingerprint" || return 1
        "$fzf_dir/install" --key-bindings --completion --no-update-rc \
          >/dev/null 2>&1 || {
            _sys_error "fzf updated, but shell integration refresh failed."
            return 1
          }
      else
        _sys_dim "No tracked fzf integration installer was present."
      fi
      local version_output updated_version
      version_output=$(
        _sys_run_bounded_probe 3 65536 fzf --version 2>/dev/null
      ) || version_output=""
      updated_version="${version_output%%[[:space:]]*}"
      [[ -n "$updated_version" ]] || updated_version="unknown"
      _sys_success "fzf updated to $updated_version."
    else
      _sys_warn "fzf git update failed."
      return 1
    fi
    return 0
  fi

  (( dry_run )) && {
    _sys_info "No Git-owned fzf update applies."
    return 0
  }
  _sys_warn "fzf is installed, but its package manager could not be determined."
  _sys_dim "Update it using the same method you originally used to install it."
}

update-omz() {
  local REPLY
  local -a reply=()
  _sys_update_parse_plan_flags update-omz "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  local -i dry_run="${reply[1]}" assume_yes="${reply[2]}"
  _sys_header "Updating Oh My Zsh"

  if [[ -z "${ZSH:-}" \
    || ( ! -e "$ZSH/.git" && ! -L "$ZSH/.git" ) ]]; then
    _sys_warn "Oh My Zsh not detected."
    return 0
  fi

  local omz_dir="$ZSH"
  _sys_update_git_fingerprint "$HOME" "$omz_dir" || {
    _sys_error "Refusing an unsafe Oh My Zsh checkout."
    return 1
  }
  omz_dir="${reply[1]}"
  local origin="${reply[2]}"
  local current_commit="${reply[3]}"
  local expected_repo_device="${reply[4]}"
  local expected_repo_inode="${reply[5]}"
  local expected_git_device="${reply[6]}"
  local expected_git_inode="${reply[7]}"
  local expected_fingerprint="$REPLY"

  _sys_info "Oh My Zsh update plan:"
  _sys_label "Directory:" "${omz_dir/#$HOME/~}"
  _sys_label "Origin:" "$(_sys_display_escape "$origin")"
  _sys_label "Current commit:" "$current_commit"
  _sys_dim "Uses Git fast-forward only; tools/upgrade.sh will not be executed."
  (( dry_run )) && {
    _sys_info "Dry run complete; Git pull was not executed."
    return 0
  }
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive Oh My Zsh updates require --yes."
        return 1
      fi
    _sys_confirm "Trust this origin and fast-forward Oh My Zsh?" || {
      _sys_info "Cancelled."
      return 0
    }
  fi

  # Check once after authorization, then again immediately before the pull.
  _sys_update_git_revalidate \
    "$HOME" "$omz_dir" "$expected_fingerprint" || return 1
  expected_fingerprint="$REPLY"
  _sys_update_git_revalidate \
    "$HOME" "$omz_dir" "$expected_fingerprint" || return 1

  if _sys_update_git_logged \
    omz-pull -C "$omz_dir" pull --ff-only; then
    _sys_update_git_revalidate_stable \
      "$HOME" "$omz_dir" "$omz_dir" "$origin" \
      "$expected_repo_device" "$expected_repo_inode" \
      "$expected_git_device" "$expected_git_inode" || return 1
    _sys_success "Oh My Zsh updated."
  else
    _sys_error "Oh My Zsh update failed."
    return 1
  fi
}

update-zsh-plugins() {
  local REPLY
  local -a reply=()
  _sys_update_parse_plan_flags update-zsh-plugins "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  local -i dry_run="${reply[1]}" assume_yes="${reply[2]}"
  _sys_header "Updating Custom Zsh Plugins"

  local custom_dir="${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}"
  if [[ ! -e "$custom_dir" && ! -L "$custom_dir" ]]; then
    _sys_info "No custom Git-owned plugins or themes were found."
    return 0
  fi
  _sys_update_validate_owned_path "$HOME" "$custom_dir" directory || {
    _sys_error "Custom Zsh directory must be an owned, symlink-free child of HOME."
    return 1
  }
  custom_dir="$REPLY"

  local plugins_dir="$custom_dir/plugins"
  local themes_dir="$custom_dir/themes"
  local repository_root
  local -a repositories=()
  for repository_root in "$plugins_dir" "$themes_dir"; do
    [[ -e "$repository_root" || -L "$repository_root" ]] || continue
    _sys_update_validate_owned_path \
      "$custom_dir" "$repository_root" directory || {
        _sys_error "Plugin collection is not owner-bound and symlink-free: $(_sys_display_escape "$repository_root")"
        return 1
      }
    repository_root="$REPLY"
    repositories+=( "$repository_root"/*(N) )
  done

  local -a git_repositories=()
  local -a repository_origins=()
  local -a repository_heads=()
  local -a repository_fingerprints=()
  local -a repository_devices=()
  local -a repository_inodes=()
  local -a git_devices=()
  local -a git_inodes=()
  local -a linked_zdx_links=()
  local -a linked_zdx_targets=()
  local repository
  local -i validation_failures=0
  for repository in "${repositories[@]}"; do
    [[ -e "$repository/.git" || -L "$repository/.git" ]] || continue
    if _sys_update_linked_zdx_checkout "$custom_dir" "$repository"; then
      linked_zdx_links+=("${repository:a}")
      linked_zdx_targets+=("$REPLY")
      continue
    fi
    if ! _sys_update_git_fingerprint "$HOME" "$repository"; then
      (( validation_failures++ ))
      _sys_warn "Excluded unsafe repository: $(_sys_display_escape "$repository")"
      continue
    fi
    git_repositories+=("${reply[1]}")
    repository_origins+=("${reply[2]}")
    repository_heads+=("${reply[3]}")
    repository_devices+=("${reply[4]}")
    repository_inodes+=("${reply[5]}")
    git_devices+=("${reply[6]}")
    git_inodes+=("${reply[7]}")
    repository_fingerprints+=("$REPLY")
  done

  local -i linked_zdx_count=${#linked_zdx_links[@]}
  if (( linked_zdx_count > 0 )); then
    local linked_checkout_noun="checkouts"
    local linked_verb="are"
    local linked_source_phrase="their source checkouts"
    if (( linked_zdx_count == 1 )); then
      linked_checkout_noun="checkout"
      linked_verb="is"
      linked_source_phrase="its source checkout"
    fi
    _sys_info \
      "Linked ZDX development $linked_checkout_noun $linked_verb managed from $linked_source_phrase:"
    local -i linked_zdx_index
    for (( linked_zdx_index = 1;
      linked_zdx_index <= linked_zdx_count;
      linked_zdx_index++ )); do
      _sys_dim "$(_sys_display_escape "${linked_zdx_links[linked_zdx_index]}") -> $(_sys_display_escape "${linked_zdx_targets[linked_zdx_index]}")"
    done
    _sys_dim "No Git pull will be attempted by update-zsh-plugins."
  fi

  if (( ${#git_repositories[@]} == 0 )); then
    if (( validation_failures > 0 )); then
      _sys_error "No repository passed executable-code safety validation."
      return 1
    fi
    if (( linked_zdx_count > 0 )); then
      _sys_update_counted_noun \
        "$linked_zdx_count" "checkout" "checkouts" || return 2
      local linked_summary_noun="$REPLY"
      _sys_success \
        "$linked_zdx_count linked ZDX development $linked_summary_noun skipped; no managed repository update was required."
      return 0
    fi
    _sys_info "No custom Git-owned plugins or themes were found."
    return 0
  fi

  _sys_warn "These repositories contain executable shell code."
  _sys_info "Fast-forward update plan:"
  local -i repository_index
  for (( repository_index = 1;
    repository_index <= ${#git_repositories[@]};
    repository_index++ )); do
    repository="${git_repositories[repository_index]}"
    _sys_dim "${repository:t} | $(_sys_display_escape "${repository_origins[repository_index]}") | ${repository_heads[repository_index]}"
  done
  if (( validation_failures > 0 )); then
    _sys_update_counted_noun \
      "$validation_failures" "repository" "repositories" || return 2
    _sys_warn "$validation_failures $REPLY failed safety validation."
  fi
  (( dry_run )) && {
    _sys_info "Dry run complete; no repository was updated."
    (( validation_failures == 0 ))
    return $?
  }
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive executable-code updates require --yes."
      return 1
    fi
    _sys_confirm "Trust every listed origin and fast-forward its code?" || {
      _sys_info "Cancelled."
      return 0
    }
  fi

  local -i updated=0 failed=$validation_failures
  local -a ready_indices=()
  # Revalidate every repository immediately after the shared authorization.
  for (( repository_index = 1;
    repository_index <= ${#git_repositories[@]};
    repository_index++ )); do
    repository="${git_repositories[repository_index]}"
    if _sys_update_git_revalidate \
      "$HOME" "$repository" \
      "${repository_fingerprints[repository_index]}"; then
      ready_indices+=("$repository_index")
    else
      (( failed++ ))
      _sys_warn "${repository:t} changed after authorization and was skipped."
    fi
  done

  for repository_index in "${ready_indices[@]}"; do
    repository="${git_repositories[repository_index]}"
    _sys_info "Updating ${repository:t}..."
    # This second exact check is adjacent to the mutating Git command.
    if ! _sys_update_git_revalidate \
      "$HOME" "$repository" \
      "${repository_fingerprints[repository_index]}"; then
      (( failed++ ))
      _sys_warn "${repository:t} changed before execution and was skipped."
      continue
    fi
    if ! _sys_update_git_logged "zsh-${repository:t}" \
      -C "$repository" pull --ff-only --quiet; then
      (( failed++ ))
      _sys_warn "${repository:t} was left unchanged or requires manual review."
      continue
    fi
    if ! _sys_update_git_revalidate_stable \
      "$HOME" "$repository" "$repository" \
      "${repository_origins[repository_index]}" \
      "${repository_devices[repository_index]}" \
      "${repository_inodes[repository_index]}" \
      "${git_devices[repository_index]}" \
      "${git_inodes[repository_index]}"; then
      (( failed++ ))
      _sys_warn "${repository:t} identity changed during update."
      continue
    fi
    (( updated++ ))
  done
  if (( failed > 0 )); then
    _sys_update_counted_noun "$updated" "repository" "repositories" \
      || return 2
    local updated_noun="$REPLY"
    if (( linked_zdx_count > 0 )); then
      _sys_update_counted_noun \
        "$linked_zdx_count" "checkout" "checkouts" || return 2
      local linked_failed_noun="$REPLY"
      _sys_error \
        "$updated $updated_noun updated; $failed failed; $linked_zdx_count linked ZDX development $linked_failed_noun skipped."
    else
      _sys_error "$updated $updated_noun updated; $failed failed."
    fi
    return 1
  fi
  _sys_update_counted_noun \
    "$updated" "repository" "repositories" || return 2
  local updated_success_noun="$REPLY"
  local updated_success_verb="were"
  local updated_success_subject="All $updated executable-code $updated_success_noun"
  if (( updated == 1 )); then
    updated_success_verb="was"
    updated_success_subject="$updated executable-code $updated_success_noun"
  fi
  if (( linked_zdx_count > 0 )); then
    _sys_update_counted_noun \
      "$linked_zdx_count" "checkout" "checkouts" || return 2
    local linked_success_noun="$REPLY"
    _sys_success \
      "$updated_success_subject $updated_success_verb updated; $linked_zdx_count linked ZDX development $linked_success_noun skipped."
  else
    _sys_success \
      "$updated_success_subject $updated_success_verb updated."
  fi
}

# =============================================================================
# PYTHON TOOLS
# =============================================================================

_sys_uv_resolved_program() {
  local uv_program=""
  uv_program=$(whence -p uv 2>/dev/null) || return 1
  [[ "$uv_program" == /* && "$uv_program" != *[[:cntrl:]]* ]] \
    || return 2

  uv_program="${uv_program:A}"
  [[ -f "$uv_program" && -x "$uv_program" ]] || return 2
  REPLY="$uv_program"
}

_sys_uv_homebrew_managed() {
  local uv_program="${1:-}"
  [[ "$uv_program" == /* && "$uv_program" != *[[:cntrl:]]* \
    && -f "$uv_program" && -x "$uv_program" ]] || return 2
  uv_program="${uv_program:A}"
  command -v brew &>/dev/null || return 1

  local brew_prefix=""
  brew_prefix=$(_sys_brew --prefix 2>/dev/null) || return 1
  [[ "$brew_prefix" == /* && "$brew_prefix" != *[[:cntrl:]]* \
    && -d "$brew_prefix" ]] || return 1
  brew_prefix="${brew_prefix:A}"

  [[ "$uv_program" == "$brew_prefix"/Cellar/uv/*/bin/uv \
    || "$uv_program" == "$brew_prefix"/opt/uv/bin/uv ]]
}

# A successful updater status does not prove that the resulting command works.
_sys_uv_updated_version() {
  local uv_program="$1" version_output=""
  REPLY=""
  version_output=$(
    _sys_run_bounded_probe 3 65536 "$uv_program" --version 2>/dev/null
  ) || return 1
  local updated_version="${${version_output#uv }%%[[:space:]]*}"
  [[ "$version_output" == "uv "* \
    && "$version_output" != *[[:cntrl:]]* \
    && "$updated_version" == <->.<->.<->* ]] || return 1
  REPLY="$updated_version"
}

update-uv-system() {
  local REPLY
  _sys_update_parse_no_args update-uv-system "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating uv"

  local -i resolve_rc=0
  _sys_uv_resolved_program || resolve_rc=$?
  if (( resolve_rc == 1 )); then
    _sys_info "uv not installed, skipping."
    return 0
  elif (( resolve_rc != 0 )); then
    _sys_error "The active uv executable did not resolve to a regular executable path."
    return 1
  fi
  local uv_program="$REPLY"

  if _sys_uv_homebrew_managed "$uv_program"; then
    _sys_info "The active uv executable is managed by Homebrew; upgrading the uv formula."
    local -x HOMEBREW_NO_AUTO_UPDATE=1
    local -x HOMEBREW_CURL_RETRIES=0 HOMEBREW_NO_ANALYTICS=1
    local SUDO_ASKPASS
    unset SUDO_ASKPASS
    if _sys_has_capability "os:darwin"; then
      _sys_brew_askpass_program || {
        _sys_error "The trusted Homebrew askpass guard is unavailable."
        return 1
      }
      local -x SUDO_ASKPASS="$REPLY"
    fi
    _sys_brew upgrade --no-ask uv </dev/null >&2 || {
      _sys_error "Homebrew failed to update uv; its self-updater was not invoked."
      return 1
    }
    # Homebrew can replace the Cellar target. Resolve its public launcher again
    # before probing, instead of executing the removed previous version path.
    _sys_uv_resolved_program || {
      _sys_error "Homebrew completed, but could not verify the active uv executable."
      return 1
    }
    uv_program="$REPLY"
    _sys_uv_homebrew_managed "$uv_program" \
      && _sys_uv_updated_version "$uv_program" || {
      _sys_error "Homebrew completed, but could not verify the updated uv version."
      return 1
    }
    _sys_success "uv updated through Homebrew to $REPLY."
    return 0
  fi

  if _sys_run_logged uv command env UV_HTTP_RETRIES=0 \
    "$uv_program" self update; then
    _sys_uv_updated_version "$uv_program" || {
      _sys_error "The uv self-update completed, but could not verify its version."
      return 1
    }
    _sys_success "uv updated to $REPLY."
  else
    _sys_error "uv self-update failed or is managed externally."
    return 1
  fi
}

update-pipx() {
  local REPLY
  _sys_update_parse_no_args update-pipx "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating pipx & its packages"

  if ! command -v pipx &>/dev/null; then
    _sys_info "pipx not installed, skipping."
    return 0
  fi

  _sys_info "Upgrading all pipx packages..."
  if _sys_run_logged pipx command env PIP_NO_INPUT=1 PIP_RETRIES=0 \
    pipx upgrade-all; then
    _sys_success "pipx packages updated."
  else
    _sys_error "pipx upgrade-all failed."
    return 1
  fi
}

update-node() {
  local REPLY
  _sys_update_parse_no_args update-node "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Node.js (via version manager)"

  local fnm_program=""
  fnm_program=$(builtin whence -p fnm 2>/dev/null)
  if [[ -n "$fnm_program" ]]; then
    [[ "$fnm_program" == /* && "$fnm_program" != *[[:cntrl:]]* \
      && -f "$fnm_program" && -x "$fnm_program" ]] || {
      _sys_error "fnm did not resolve to a regular executable path."
      return 1
    }
    fnm_program="${fnm_program:A}"
    if command -v brew &>/dev/null \
      && _sys_brew list fnm &>/dev/null 2>&1; then
      _sys_info "fnm itself is managed by Homebrew — updating Node.js LTS only."
    fi

    _sys_info "Installing latest Node.js LTS via fnm..."
    if _sys_run_logged fnm-install command "$fnm_program" install --lts; then
      local -i phase_failures=0
      if ! command "$fnm_program" use lts-latest </dev/null >&2; then
        _sys_error "Node.js LTS was installed, but activation failed."
        _sys_dim "Retry activation after checking fnm shell setup: fnm use lts-latest"
        phase_failures=$(( phase_failures + 1 ))
      fi
      if ! command "$fnm_program" default lts-latest </dev/null >&2; then
        _sys_error "Node.js LTS was installed, but default selection failed."
        _sys_dim "Retry the default selection: fnm default lts-latest"
        phase_failures=$(( phase_failures + 1 ))
      fi
      (( phase_failures == 0 )) || return 1

      local lts_version
      lts_version=$(
        _sys_run_bounded_probe 3 65536 "$fnm_program" current 2>/dev/null
      ) || lts_version=""

      [[ "$lts_version" == v<->.<->.<-> ]] || {
        _sys_error "Node.js LTS was installed, but could not verify fnm's active version."
        return 1
      }
      _sys_success "Node.js LTS ($lts_version) installed and set as default."
    else
      _sys_error "fnm failed to install Node.js LTS."
      return 1
    fi

  elif [[ -d "${NVM_DIR:-$HOME/.nvm}" ]]; then
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"

    _sys_info "Using the existing nvm installation..."
    _sys_dim "The nvm Git checkout is not changed by this command."

    if ! command -v nvm &>/dev/null; then
      _sys_error "nvm is installed but is not loaded in this shell."
      _sys_dim "Load nvm through your trusted shell configuration, then retry."
      return 1
    fi

    _sys_info "Installing latest Node.js LTS via nvm..."
    if _sys_run_logged nvm-install nvm install --lts; then
      local lts_version
      lts_version=$(nvm version "lts/*" 2>/dev/null) || lts_version=""

      [[ "$lts_version" == v<->.<->.<-> ]] || {
        _sys_error "Node.js LTS installation completed, but could not verify its installed version."
        return 1
      }
      local -i phase_failures=0
      if ! nvm alias default "$lts_version" </dev/null >&2; then
        _sys_error "Node.js LTS was installed, but default selection failed."
        _sys_dim "Retry the default selection: nvm alias default $lts_version"
        phase_failures=$(( phase_failures + 1 ))
      fi
      # Keep activation in the invoking shell: output capture through a pipeline
      # would discard nvm's PATH/session changes even when it returned success.
      if ! nvm use "$lts_version" </dev/null >&2; then
        _sys_error "Node.js LTS was installed, but activation failed."
        _sys_dim "Retry activation: nvm use $lts_version"
        phase_failures=$(( phase_failures + 1 ))
      fi
      (( phase_failures == 0 )) || return 1
      local active_version=""
      active_version=$(nvm current 2>/dev/null) || active_version=""
      [[ "$active_version" == "$lts_version" ]] || {
        _sys_error "Node.js LTS was installed, but could not verify nvm's active version."
        return 1
      }
      _sys_success "Node.js LTS ($lts_version) installed and set as default."
    else
      _sys_error "nvm failed to install Node.js LTS."
      return 1
    fi

  else
    _sys_info "Neither fnm nor nvm detected, skipping."
    return 0
  fi
}

update-rust() {
  local REPLY
  _sys_update_parse_no_args update-rust "$@" || return $?
  [[ "$REPLY" == "help" ]] && return 0
  _sys_header "Updating Rust Toolchain"

  if ! command -v rustup &>/dev/null; then
    _sys_info "rustup not installed, skipping."
    return 0
  fi

  _sys_info "Updating rustup and toolchains..."
  if _sys_run_logged rust command env RUSTUP_MAX_RETRIES=0 rustup update; then
    _sys_success "Rust toolchain updated."
  else
    _sys_error "Rust update failed."
    return 1
  fi
}

_sys_update_ai_load_owner() {
  if typeset -f ai-menu &>/dev/null; then
    return 0
  fi

  local module_dir="${${(%):-%x}:A:h:h}"
  local owner_file="${module_dir}/ai-menu.zsh"
  if [[ "$owner_file" != "${owner_file:A}" \
    || ! -f "$owner_file" || -L "$owner_file" || ! -r "$owner_file" ]]; then
    _sys_error "The AI suite owner is unavailable."
    return 1
  fi

  builtin source "$owner_file" || {
    _sys_error "Failed to load the AI suite owner."
    return 1
  }
  if ! typeset -f ai-menu &>/dev/null; then
    _sys_error "The AI suite owner did not define ai-menu."
    return 1
  fi
}

_sys_update_ai_failure_detail() {
  local label="${1:-}" reason="${2:-}" result_rc="${3:-}"
  case "$reason" in
    metadata-invalid)                 REPLY="$label: updater metadata is invalid" ;;
    executable-validation-failed)     REPLY="$label: executable validation failed" ;;
    version-probe-failed)             REPLY="$label: version probe failed" ;;
    executable-changed)               REPLY="$label: executable changed after review" ;;
    updated-executable-unsafe)        REPLY="$label: updated executable is unsafe" ;;
    post-update-version-probe-failed) REPLY="$label: post-update version probe failed" ;;
    authentication-required)          REPLY="$label: authentication required" ;;
    vendor-precondition)              REPLY="$label: vendor precondition not met" ;;
    result-capture-failed)            REPLY="$label: result capture failed" ;;
    updater-failed)                   REPLY="$label: updater failed (status $result_rc)" ;;
    *) return 2 ;;
  esac
}

# Parse the AI owner's public, bounded result protocol. Human stderr is never
# parsed as data, and vendor output never enters these synthesized records.
_sys_update_ai_parse_results() {
  local report="${1:-}"
  reply=()
  (( ${#report} > 0 && ${#report} <= 16384 )) || return 2
  local -a result_lines=("${(@f)report}")
  local -a expected_ids=(
    claude codex antigravity opencode cursor copilot amp hermes
  )
  local -A expected_labels=(
    claude "Claude Code"
    codex "Codex CLI"
    antigravity "Antigravity CLI"
    opencode "OpenCode"
    cursor "Cursor Agent"
    copilot "GitHub Copilot CLI"
    amp "Amp CLI"
    hermes "Hermes Agent"
  )
  (( ${#result_lines[@]} == ${#expected_ids[@]} )) || return 2

  local -A seen_ids=()
  local line schema id label outcome reason result_rc extra expected_id
  local -i result_index=0
  for line in "${result_lines[@]}"; do
    (( ++result_index ))
    expected_id="${expected_ids[result_index]}"
    schema=""
    id=""
    label=""
    outcome=""
    reason=""
    result_rc=""
    extra=""
    IFS=$'\t' read -r \
      schema id label outcome reason result_rc extra <<< "$line"
    [[ "$schema" == "ai-update-result-v1" \
      && -n "$id" && -n "$label" && -n "$outcome" \
      && -n "$reason" && -n "$result_rc" && -z "$extra" ]] || return 2
    [[ "$id" =~ '^[a-z][a-z0-9-]{0,31}$' \
      && "$label" =~ '^[[:alnum:]][[:alnum:] .()+/_-]{0,63}$' \
      && "$result_rc" == <-> && ${#result_rc} -le 3 ]] || return 2
    [[ "$id" == "$expected_id" \
      && "$label" == "${expected_labels[$expected_id]}" ]] || return 2
    (( result_rc >= 0 && result_rc <= 255 )) || return 2
    (( ! ${+seen_ids[$id]} )) || return 2
    seen_ids[$id]=1

    case "$outcome:$reason" in
      updated:version-changed|updated:executable-content-changed|\
      already-current:unchanged|skipped:not-installed|\
      skipped:homebrew-managed|planned:eligible)
        (( result_rc == 0 )) || return 2
        ;;
      not-run:cancelled)
        (( result_rc == 0 )) || return 2
        ;;
      not-run:interrupted)
        (( result_rc == 130 || result_rc == 143 )) || return 2
        ;;
      not-run:authorization-not-granted)
        (( result_rc != 0 )) || return 2
        ;;
      failed:metadata-invalid|failed:executable-validation-failed|\
      failed:version-probe-failed|failed:executable-changed|\
      failed:updated-executable-unsafe|\
      failed:post-update-version-probe-failed|\
      failed:authentication-required|failed:vendor-precondition|\
      failed:result-capture-failed|failed:updater-failed)
        (( result_rc != 0 )) || return 2
        _sys_update_ai_failure_detail "$label" "$reason" "$result_rc" \
          || return 2
        reply+=("$REPLY")
        ;;
      *)
        return 2
        ;;
    esac
  done
}

# Private aggregate adapter. AI lifecycle and updater validation remain owned
# by the public AI suite; System forwards aggregate authorization flags and
# consumes only the owner's versioned result records.
_sys_update_ai_tools() {
  local -a reply=()
  _sys_update_ai_load_owner || return 1
  local result_report=""
  local -i ai_rc=0
  result_report=$(ai-menu ai-update --skip-homebrew-managed \
    --result-tsv "$@") || ai_rc=$?

  local -a failure_details=()
  if _sys_update_ai_parse_results "$result_report"; then
    failure_details=("${reply[@]}")
  else
    _sys_error "The AI updater returned an invalid result report."
    failure_details=("result report is invalid")
    ai_rc=1
  fi
  if (( ai_rc == 0 && ${#failure_details[@]} > 0 )); then
    _sys_error "The AI updater result report contradicts its success status."
    failure_details=("result report contradicts the updater status")
    ai_rc=1
  elif (( ai_rc != 0 && ${#failure_details[@]} == 0 )); then
    failure_details=("aggregate updater failed (status $ai_rc)")
  fi
  if (( ${+_SYS_UPDATE_STEP_FAILURE_DETAILS} )); then
    _SYS_UPDATE_STEP_FAILURE_DETAILS=("${failure_details[@]}")
  fi
  return $ai_rc
}

# Compatibility command retained from the frozen System public surface.
update-hermes() {
  _sys_update_ai_load_owner || return 1
  _sys_warn \
    "update-hermes is a compatibility command; delegating to ai-menu."
  ai-menu ai-update-hermes "$@"
}

# =============================================================================
# FULL SYSTEM UPDATE
# =============================================================================

# Mirror of each update-*'s skip condition. Used to pre-filter the loop so we
# don't print "skipping" inside the bucket for steps that don't apply.
# Returns 0 if the step should run, 1 if it should be filtered out.
_sys_step_applies() {
  local -a reply=()
  case "$1" in
    update-apt)
      _sys_has_capability "package:apt" ;;
    _sys_update_platform_packages)
      local package_backend
      package_backend=$(_sys_capability_value package_manager) || return 1
      _sys_has_capability "os-updates:softwareupdate" \
        && command -v softwareupdate &>/dev/null && return 0
      [[ "$package_backend" == (dnf|pacman|zypper|apk|softwareupdate) ]] \
        && command -v "$package_backend" &>/dev/null ;;
    update-snap)
      _sys_snap_ready ;;
    update-gcloud)
      command -v gcloud &>/dev/null \
        && ! { command -v dpkg &>/dev/null \
          && dpkg -s google-cloud-cli &>/dev/null; } \
        && ! { command -v brew &>/dev/null \
          && { _sys_brew list --formula google-cloud-sdk &>/dev/null \
            || _sys_brew list --cask google-cloud-sdk &>/dev/null; }; } ;;
    update-brew)
      command -v brew &>/dev/null ;;
    update-rust)
      command -v rustup &>/dev/null ;;
    update-uv-system)
      local REPLY
      _sys_uv_resolved_program \
        && ! _sys_uv_homebrew_managed "$REPLY" ;;
    update-pipx)
      command -v pipx &>/dev/null ;;
    update-node)
      builtin whence -p fnm &>/dev/null \
        || { [[ -d "${NVM_DIR:-$HOME/.nvm}" ]] \
          && command -v nvm &>/dev/null; } ;;
    update-starship)
      command -v starship &>/dev/null \
        && ! { command -v brew &>/dev/null \
          && _sys_brew list starship &>/dev/null 2>&1; } \
        && command -v cargo &>/dev/null \
        && command cargo install --list 2>/dev/null \
          | command grep -q '^starship ' ;;
    update-fzf)
      command -v fzf &>/dev/null \
        && ! { command -v brew &>/dev/null \
          && _sys_brew list fzf &>/dev/null 2>&1; } \
        && ! { command -v dpkg &>/dev/null \
          && dpkg -s fzf &>/dev/null; } \
        && _sys_update_fzf_git_dir ;;
    update-omz)
      command -v git &>/dev/null \
        && [[ -n "${ZSH:-}" \
          && ( -e "$ZSH/.git" || -L "$ZSH/.git" ) ]] ;;
    update-zsh-plugins)
      local custom_dir="${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}"
      local -a custom_repositories=(
        "$custom_dir/plugins"/*(N/)
        "$custom_dir/themes"/*(N/)
      )
      local custom_repository
      for custom_repository in "${custom_repositories[@]}"; do
        [[ -d "$custom_repository/.git" ]] && return 0
      done
      return 1 ;;
    update-repomix)
      local REPLY
      _sys_repomix_program && ! _sys_repomix_homebrew_managed "$REPLY" ;;
    _sys_update_ai_tools)
      _sys_update_ai_load_owner ;;
    update-awscli)
      return 1 ;;
    *)
      return 0 ;;
  esac
}

# Small predicate so tests can model an interactive terminal without a PTY.
_sys_update_can_prompt() {
  [[ -t 0 && -t 2 ]]
}

# Report whether an aggregate step can require the shared sudo authorization.
# Homebrew formulae normally remain unprivileged, but macOS casks can delegate
# installer packages to sudo, so the Darwin aggregate keeps the same bounded
# credential alive through that adjacent step as well.
_sys_update_step_requires_privilege() {
  local command_name="${1:-}"
  case "$command_name" in
    update-apt|_sys_update_platform_packages|update-snap)
      return 0
      ;;
    update-brew)
      _sys_has_capability "os:darwin"
      ;;
    *)
      return 1
      ;;
  esac
}

# The aggregate lock file is persistent: removing it after unlock could let a
# third process create and lock a new inode while another waiter still refers
# to the old one. The advisory lock itself is released with its owned fd.
typeset -gi _SYS_UPDATE_LOCK_HELD=0
typeset -g _SYS_UPDATE_LOCK_HELD_FD=""

_sys_update_lock_directory_safe() {
  local directory="${1:-}"
  [[ -n "$directory" \
    && "$directory" == /* \
    && "$directory" != *[[:cntrl:]]* ]] || return 1
  local literal="${directory:a}"
  local resolved="${directory:A}"
  [[ "$literal" == "$resolved" \
    && -d "$literal" \
    && ! -L "$literal" \
    && -w "$literal" \
    && -x "$literal" ]] || return 1
  zmodload zsh/stat 2>/dev/null || return 1
  local -A directory_state=()
  zstat -H directory_state -- "$literal" 2>/dev/null || return 1
  (( directory_state[uid] == EUID \
    && (directory_state[mode] & 8#22) == 0 )) || return 1
  REPLY="$literal"
}

_sys_update_lock_path() {
  [[ -n "${HOME:-}" \
    && "$HOME" == /* \
    && "$HOME" != *[[:cntrl:]]* ]] || {
    _sys_error \
      "No owner-controlled directory is available for the update-system lock."
    return 1
  }
  local literal_home="${HOME:a}"
  local resolved_home="${HOME:A}"
  [[ "$literal_home" == "$resolved_home" ]] \
    && _sys_update_lock_directory_safe "$resolved_home" || {
    _sys_error \
      "No owner-controlled directory is available for the update-system lock."
    return 1
  }
  REPLY="$REPLY/.zdx-update-system.lock"
  return 0
}

_sys_update_acquire_lock() {
  emulate -L zsh
  local lock_path="${1:-}"
  REPLY=""
  [[ "$lock_path" == /* \
    && "$lock_path" != *[[:cntrl:]]* \
    && -d "${lock_path:h}" ]] \
    && _sys_update_lock_directory_safe "${lock_path:h}" || {
    _sys_error "The update-system lock path is invalid."
    return 1
  }
  (( !_SYS_UPDATE_LOCK_HELD )) || {
    _sys_error "update-system is already running in this shell."
    return 1
  }
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _sys_error "Zsh file-lock support is unavailable."
    return 1
  }

  if [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
    local -i create_fd=-1
    local previous_umask
    previous_umask=$(umask) || return 1
    local -i create_rc=0 restore_umask_rc=0
    {
      umask 0077 || create_rc=$?
      if (( create_rc == 0 )); then
        sysopen -w -m 0600 -o create,excl,nofollow,cloexec \
          -u create_fd -- "$lock_path" 2>/dev/null || create_rc=$?
      fi
    } always {
      umask "$previous_umask" || restore_umask_rc=$?
      (( create_fd >= 0 )) && exec {create_fd}>&-
    }
    (( restore_umask_rc == 0 )) || {
      _sys_error "Unable to restore the shell umask after lock creation."
      return 1
    }
    if (( create_rc != 0 )); then
      [[ -e "$lock_path" || -L "$lock_path" ]] || {
        _sys_error "Unable to create the update-system lock file."
        return 1
      }
    fi
  fi

  local -A path_state=() fd_state=()
  [[ -f "$lock_path" && ! -L "$lock_path" ]] \
    && zstat -H path_state -- "$lock_path" 2>/dev/null || {
    _sys_error "The update-system lock file is unsafe."
    return 1
  }
  (( path_state[uid] == EUID \
    && path_state[nlink] == 1 \
    && (path_state[mode] & 8#777) == 8#600 )) || {
    _sys_error "The update-system lock file has unsafe ownership or permissions."
    return 1
  }

  local -i lock_fd=-1 lock_rc=0 lock_safe=1 lock_transferred=0
  {
    zsystem flock -t 0 -f lock_fd "$lock_path" 2>/dev/null \
      || lock_rc=$?
    if (( lock_rc != 0 )); then
      _sys_error \
        "The update-system lock could not be acquired; another invocation may already be running. No update step was started."
      return 1
    fi

    _SYS_UPDATE_LOCK_HELD=1
    _SYS_UPDATE_LOCK_HELD_FD="$lock_fd"
    zstat -H fd_state -f "$lock_fd" 2>/dev/null || lock_safe=0
    zstat -H path_state -- "$lock_path" 2>/dev/null || lock_safe=0
    if (( ! lock_safe \
      || fd_state[device] != path_state[device] \
      || fd_state[inode] != path_state[inode] \
      || fd_state[uid] != EUID \
      || fd_state[nlink] != 1 \
      || (fd_state[mode] & 8#777) != 8#600 )); then
      _sys_error "The update-system lock file changed during acquisition."
      return 1
    fi

    REPLY="$lock_fd"
    lock_transferred=1
  } always {
    if (( lock_fd >= 0 && ! lock_transferred )); then
      if [[ "$_SYS_UPDATE_LOCK_HELD" == 1 \
        && "$_SYS_UPDATE_LOCK_HELD_FD" == "$lock_fd" ]]; then
        _sys_update_release_lock "$lock_fd" || true
      else
        zsystem flock -u "$lock_fd" 2>/dev/null || true
      fi
      REPLY=""
    fi
  }
}

_sys_update_release_lock() {
  emulate -L zsh
  local lock_fd="${1:-}"
  [[ "$lock_fd" == <-> \
    && "$lock_fd" -gt 2 \
    && "$_SYS_UPDATE_LOCK_HELD" == 1 \
    && "$_SYS_UPDATE_LOCK_HELD_FD" == "$lock_fd" ]] || return 2
  zmodload zsh/system 2>/dev/null || return 1
  local -i release_rc=0
  zsystem flock -u "$lock_fd" 2>/dev/null || release_rc=$?
  if (( release_rc != 0 )); then
    # Closing the exact owned descriptor is the kernel-level fallback for a
    # failed zsystem ownership check. Never forget the sentinel while the fd
    # might still retain the lock in this long-lived interactive shell.
    local -i close_rc=0
    exec {lock_fd}>&- 2>/dev/null || close_rc=$?
    (( close_rc == 0 )) || return $release_rc
  fi
  _SYS_UPDATE_LOCK_HELD=0
  _SYS_UPDATE_LOCK_HELD_FD=""
  return 0
}

# Authenticate sudo once, announced, when the authorized plan contains a
# privileged package step. The caller scopes a non-interactive timestamp
# refresher to the consecutive package entries. Suite-owned privilege calls use
# sudo -n; Darwin Homebrew receives a fixed failing askpass guard. An unavailable
# credential therefore becomes a visible failure, not a second prompt.
# Advisory only; it never fails the aggregate by itself.
_sys_update_preauthenticate() {
  REPLY=0
  local entry command_name
  local -i privileged=0 darwin_homebrew=0
  for entry in "$@"; do
    command_name="${entry#*;}"
    _sys_update_step_requires_privilege "$command_name" && privileged=1
    [[ "$command_name" == "update-brew" ]] && darwin_homebrew=1
  done
  (( privileged )) || return 0
  (( EUID != 0 )) || return 0
  _sys_has_capability "privilege:sudo" \
    && command -v sudo &>/dev/null || return 0
  if command sudo -n true 2>/dev/null; then
    REPLY=1
    return 0
  fi
  _sys_update_can_prompt || return 0

  _sys_info \
    "Privileged operation: sudo -v (authenticate once for the authorized package steps)"
  _sys_dim "Later ZDX privilege calls use sudo -n."
  if (( darwin_homebrew )) && _sys_has_capability "os:darwin"; then
    _sys_dim \
      "macOS Homebrew cask operations use a fixed non-interactive askpass guard."
  fi
  if command sudo -v >&2; then
    REPLY=1
  else
    _sys_warn \
      "sudo authentication failed; privileged steps will fail without reprompting."
  fi
  return 0
}

# Wait for either a private stop request on the worker's pseudo-terminal or the
# next refresh interval. Status 0 means input is ready; status 1 is a timeout.
_sys_update_sudo_keepalive_wait() {
  zmodload zsh/zselect 2>/dev/null || return 2
  zselect -r 0 -t 3000 2>/dev/null
}

_sys_update_sudo_keepalive_worker() {
  emulate -L zsh
  setopt NO_MONITOR NO_NOTIFY
  local control=""
  local -i refresh_enabled=1 wait_rc=0
  while true; do
    _sys_update_sudo_keepalive_wait
    wait_rc=$?
    if (( wait_rc == 0 )); then
      IFS= read -r control || return 1
      [[ "$control" == "stop" ]] || return 1
      print -r -- "zdx-sudo-keepalive-stopped"
      return 0
    fi
    (( wait_rc == 1 )) || return 1
    if (( refresh_enabled )) \
      && ! command sudo -n -v </dev/null >/dev/null 2>&1; then
      # A failed refresh is never retried. Keep this owned worker alive so its
      # private handle cannot be confused with a later process.
      refresh_enabled=0
    fi
  done
}

# Keep the one authorized sudo timestamp valid only while consecutive package
# entries run. A private zpty handle avoids the caller's interactive job table;
# the stop handshake and zpty deletion retain exact worker ownership.
_sys_update_start_sudo_keepalive() {
  emulate -L zsh
  local authenticated="${1:-0}"
  REPLY=""
  [[ "$authenticated" == 0 || "$authenticated" == 1 ]] || return 2
  (( authenticated && EUID != 0 )) || return 0
  _sys_has_capability "privilege:sudo" \
    && command -v sudo &>/dev/null || return 0
  zmodload zsh/zpty zsh/zselect 2>/dev/null || return 1
  command sudo -n -v </dev/null >/dev/null 2>&1 || return 1

  local keepalive_handle="zdx-sudo-keepalive-${sysparams[pid]:-$$}-${RANDOM}-${RANDOM}"
  [[ "$keepalive_handle" =~ '^zdx-sudo-keepalive-[0-9]+-[0-9]+-[0-9]+$' ]] \
    || return 1
  zpty -b "$keepalive_handle" _sys_update_sudo_keepalive_worker \
    2>/dev/null || return 1
  zpty -t "$keepalive_handle" 2>/dev/null || {
    zpty -d "$keepalive_handle" 2>/dev/null || true
    return 1
  }
  REPLY="$keepalive_handle"
  _sys_dim \
    "Sudo timestamp refresh is active only for the authorized package entries." \
    || true
  REPLY="$keepalive_handle"
  return 0
}

_sys_update_stop_sudo_keepalive() {
  emulate -L zsh
  local keepalive_handle="${1:-}"
  [[ "$keepalive_handle" \
    =~ '^zdx-sudo-keepalive-[0-9]+-[0-9]+-[0-9]+$' ]] || return 2
  zmodload zsh/zpty zsh/zselect 2>/dev/null || return 1
  if ! zpty -t "$keepalive_handle" 2>/dev/null; then
    zpty -d "$keepalive_handle" 2>/dev/null || true
    return 0
  fi
  zpty -w "$keepalive_handle" stop 2>/dev/null || {
    zpty -d "$keepalive_handle" 2>/dev/null || true
    return 1
  }

  local response="" chunk=""
  local -i attempt=0 acknowledged=0 stopped=0
  while (( ++attempt <= 100 )); do
    chunk=""
    if zpty -r -t "$keepalive_handle" chunk 2>/dev/null; then
      response+="$chunk"
      (( ${#response} <= 1024 )) || break
      [[ "$response" == *"zdx-sudo-keepalive-stopped"* ]] \
        && acknowledged=1
    fi
    if ! zpty -t "$keepalive_handle" 2>/dev/null; then
      stopped=1
      break
    fi
    zselect -t 1 2>/dev/null || true
  done
  zpty -d "$keepalive_handle" 2>/dev/null || return 1
  (( acknowledged && stopped ))
}

_sys_run_update_step() {
  local command_name="$1"
  local assume_yes="${2:-0}"
  local include_phased_updates="${3:-0}"
  local verbose="${4:-0}"
  [[ "$include_phased_updates" == 0 \
    || "$include_phased_updates" == 1 ]] || return 2
  [[ "$verbose" == 0 || "$verbose" == 1 ]] || return 2
  if [[ "$command_name" == "_sys_update_platform_packages" ]]; then
    "$command_name" "$assume_yes"
  elif [[ "$command_name" == "update-apt" ]]; then
    local -a apt_args=()
    (( assume_yes )) && apt_args+=(--yes)
    (( include_phased_updates )) \
      && apt_args+=(--include-phased-updates)
    (( verbose )) && apt_args+=(--verbose)
    "$command_name" "${apt_args[@]}"
  elif [[ "$command_name" == "update-snap" \
    || "$command_name" == "update-fzf" \
    || "$command_name" == "update-omz" \
    || "$command_name" == "update-zsh-plugins" \
    || "$command_name" == "_sys_update_ai_tools" ]]; then
    if (( assume_yes )); then
      "$command_name" --yes
    else
      "$command_name"
    fi
  else
    "$command_name"
  fi
}

_sys_update_step_category() {
  local command_name="${1:-}"
  case "$command_name" in
    update-apt|_sys_update_platform_packages|update-snap|update-brew)
      REPLY="core"
      ;;
    *)
      REPLY="optional"
      ;;
  esac
}

_sys_update_print_category_summary() {
  local label="$1" succeeded="$2" total="$3" failed="$4" not_run="$5"
  (( total > 0 )) || return 0
  local message="$label: $succeeded/$total succeeded"
  (( failed > 0 )) && message+="; $failed failed"
  (( not_run > 0 )) && message+="; $not_run not run"
  if (( failed > 0 )); then
    _sys_error "$message"
  elif (( not_run > 0 )); then
    _sys_warn "$message"
  else
    _sys_success "$message"
  fi
}

_sys_update_run() {
  local fail_fast="${1:-0}"
  local assume_yes="${2:-0}"
  local include_phased_updates="${3:-0}"
  local verbose="${4:-0}"
  shift 4 2>/dev/null || return 2
  [[ "$fail_fast" == 0 || "$fail_fast" == 1 ]] || return 2
  [[ "$assume_yes" == 0 || "$assume_yes" == 1 ]] || return 2
  [[ "$include_phased_updates" == 0 \
    || "$include_phased_updates" == 1 ]] || return 2
  [[ "$verbose" == 0 || "$verbose" == 1 ]] || return 2
  local errors=0
  local step=0
  local -a failed_labels=()
  local -a _SYS_UPDATE_STEP_FAILURE_DETAILS=()
  local -a applicable=("$@")
  local start_time=$SECONDS
  local -i step_started=0 step_elapsed=0
  local -i _SYS_PRIVILEGE_NONINTERACTIVE=1
  local entry label cmd
  local -i privileged_entries_remaining=0
  local -i core_total=0 core_succeeded=0 core_failed=0
  local -i optional_total=0 optional_succeeded=0 optional_failed=0

  for entry in "${applicable[@]}"; do
    cmd="${entry#*;}"
    _sys_update_step_requires_privilege "$cmd" \
      && (( ++privileged_entries_remaining ))
    _sys_update_step_category "$cmd"
    if [[ "$REPLY" == "core" ]]; then
      (( ++core_total ))
    else
      (( ++optional_total ))
    fi
  done

  local total=${#applicable[@]}
  if (( total == 0 )); then
    _sys_warn "No applicable update steps for this system."
    return 0
  fi

  for entry in "${applicable[@]}"; do
    step=$((step + 1))
    label="${entry%%;*}"
    cmd="${entry#*;}"
    _sys_info "Step $step/$total: $label"

    step_started=$SECONDS
    local step_rc=0
    _SYS_UPDATE_STEP_FAILURE_DETAILS=()
    _sys_run_update_step \
      "$cmd" "$assume_yes" "$include_phased_updates" "$verbose" </dev/null \
      || step_rc=$?
    step_elapsed=$(( SECONDS - step_started ))
    if _sys_update_step_requires_privilege "$cmd"; then
      (( --privileged_entries_remaining ))
      if (( privileged_entries_remaining == 0 )) \
        && [[ -n "${_SYS_UPDATE_SUDO_KEEPALIVE_HANDLE:-}" ]]; then
        _sys_update_stop_sudo_keepalive \
          "$_SYS_UPDATE_SUDO_KEEPALIVE_HANDLE" || _sys_warn \
          "Unable to stop the aggregate sudo timestamp refresher cleanly."
        _SYS_UPDATE_SUDO_KEEPALIVE_HANDLE=""
      fi
    fi
    if (( step_rc != 0 )); then
      errors=$((errors + 1))
      local failure_duration="$(_sys_format_duration "$step_elapsed")"
      if (( ${#_SYS_UPDATE_STEP_FAILURE_DETAILS[@]} > 0 )); then
        local nested_failure
        for nested_failure in "${_SYS_UPDATE_STEP_FAILURE_DETAILS[@]}"; do
          failed_labels+=(
            "$label — $nested_failure ($failure_duration)"
          )
        done
      else
        failed_labels+=("$label ($failure_duration)")
      fi
      _sys_update_step_category "$cmd"
      if [[ "$REPLY" == "core" ]]; then
        (( ++core_failed ))
      else
        (( ++optional_failed ))
      fi
      _sys_warn \
        "Step failed after $failure_duration: $label"
      if (( fail_fast || step_rc == 130 || step_rc == 143 )); then
        local elapsed=$(( SECONDS - start_time ))
        local mins=$(( elapsed / 60 ))
        local secs=$(( elapsed % 60 ))
        local step_noun="steps"
        (( total == 1 )) && step_noun="step"
        _sys_blank
        if (( step_rc == 130 || step_rc == 143 )); then
          _sys_error "System update interrupted (status $step_rc): $label"
        elif (( ${#_SYS_UPDATE_STEP_FAILURE_DETAILS[@]} == 1 )); then
          _sys_error \
            "Aborting after first failure (--fail-fast): $label — ${_SYS_UPDATE_STEP_FAILURE_DETAILS[1]}"
        else
          _sys_error "Aborting after first failure (--fail-fast): $label"
        fi
        _sys_dim \
          "Stopped at $step of $total $step_noun, ${mins}m ${secs}s elapsed"
        _sys_update_print_category_summary \
          "Core package steps" "$core_succeeded" "$core_total" \
          "$core_failed" \
          "$(( core_total - core_succeeded - core_failed ))"
        _sys_update_print_category_summary \
          "Optional tool steps" "$optional_succeeded" "$optional_total" \
          "$optional_failed" \
          "$(( optional_total - optional_succeeded - optional_failed ))"
        (( step_rc == 130 || step_rc == 143 )) && return $step_rc
        return 1
      fi
    else
      _sys_update_step_category "$cmd"
      if [[ "$REPLY" == "core" ]]; then
        (( ++core_succeeded ))
      else
        (( ++optional_succeeded ))
      fi
      _sys_dim \
        "Step completed in $(_sys_format_duration "$step_elapsed"): $label"
    fi
  done

  local elapsed=$(( SECONDS - start_time ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))

  _sys_blank
  _sys_dim "Completed in ${mins}m ${secs}s"
  _sys_update_print_category_summary \
    "Core package steps" "$core_succeeded" "$core_total" \
    "$core_failed" 0
  _sys_update_print_category_summary \
    "Optional tool steps" "$optional_succeeded" "$optional_total" \
    "$optional_failed" 0
  if (( errors == 0 )); then
    local success_step_noun="steps"
    (( total == 1 )) && success_step_noun="step"
    _sys_success \
      "System update completed successfully! ($total/$total $success_step_noun)"
  else
    local final_step_noun="steps"
    (( total == 1 )) && final_step_noun="step"
    if (( errors < total )); then
      _sys_error \
        "System update completed with partial failures: $errors of $total $final_step_noun failed."
      typeset -f _zdx_timed_mark_partial &>/dev/null \
        && _zdx_timed_mark_partial || true
    else
      if (( total == 1 )); then
        _sys_error "System update failed: the only step failed."
      else
        _sys_error "System update failed: all $total $final_step_noun failed."
      fi
    fi
    local fl
    for fl in "${failed_labels[@]}"; do
      _sys_error "  • $fl"
    done
    return 1
  fi
}

update-system() {
  local REPLY
  local -i fail_fast=0 assume_yes=0 dry_run=0 include_remote_code=1
  local -i include_phased_updates=0 verbose=0
  local -i option_count=0 remote_code_mode=0
  while (( $# )); do
    case "$1" in
      --fail-fast|-f)
        fail_fast=1
        (( ++option_count ))
        ;;
      --dry-run)
        dry_run=1
        (( ++option_count ))
        ;;
      --yes|-y)
        assume_yes=1
        (( ++option_count ))
        ;;
      --verbose|-v)
        verbose=1
        (( ++option_count ))
        ;;
      --include-phased-updates)
        include_phased_updates=1
        (( ++option_count ))
        ;;
      --include-remote-code)
        (( remote_code_mode == -1 )) && {
          _sys_error \
            "--include-remote-code and --safe-only cannot be combined."
          return 2
        }
        include_remote_code=1
        remote_code_mode=1
        (( ++option_count ))
        ;;
      --safe-only)
        (( remote_code_mode == 1 )) && {
          _sys_error \
            "--include-remote-code and --safe-only cannot be combined."
          return 2
        }
        include_remote_code=0
        remote_code_mode=-1
        (( ++option_count ))
        ;;
      --help|-h)
        (( $# == 1 && option_count == 0 )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        cat >&2 <<'EOF'
Usage: update-system [-f|--fail-fast] [--dry-run] [-y|--yes]
                     [--safe-only|--include-remote-code]
                     [--include-phased-updates] [-v|--verbose] [-h|--help]

Runs every applicable installed update step in sequence, including mutable
Git origins, script-owned updaters, and reviewed AI CLI self-updaters.
One aggregate authorization — the interactive plan confirmation or --yes —
covers every displayed step, so an authorized run never stops at a mid-run
prompt. By default, continues on error and reports a summary at the end.

Options:
  --fail-fast, -f   Stop at the first failing step.
  --dry-run         Print the applicable update plan without changing state.
  --yes, -y         Authorize the displayed aggregate plan non-interactively.
  --verbose, -v     Show complete APT invocations for operations that run.
  --include-phased-updates
                    Include APT phased updates in the authorized transaction.
  --safe-only       Exclude mutable Git, script, and AI update workflows.
  --include-remote-code
                    Explicitly affirm their default inclusion.
  --help, -h        Show this help.

Steps that do not apply to the detected host are omitted. APT runs once, as the
first step after sudo pre-authentication, with lock timeout and network retries
set to zero. One exact automatic unattended-upgrade may receive a validated
cooperative SIGTERM; ZDX never polls, retries, deletes locks, or sends SIGKILL.
By default, APT continues to respect Ubuntu phased-update eligibility.
EOF
        return 0 ;;
      *)
        _sys_error "Unknown option: $1"
        print -u2 -r -- "Try: update-system --help"
        return 2 ;;
    esac
    shift
  done

  _sys_capabilities_refresh_for_command || return 1

  local -a plan_steps=(
    "APT;update-apt"
    "Native packages;_sys_update_platform_packages"
    "Snap;update-snap"
    "Homebrew;update-brew"
    "Starship;update-starship"
    "fzf;update-fzf"
    "Google Cloud SDK;update-gcloud"
    "AWS CLI;update-awscli"
    "uv;update-uv-system"
    "pipx;update-pipx"
    "Node.js (fnm/nvm);update-node"
    "Rust;update-rust"
    "AI assistants;_sys_update_ai_tools"
    "Repomix CLI;update-repomix"
    "Oh My Zsh;update-omz"
    "Zsh Plugins;update-zsh-plugins"
  )
  local -a applicable_labels=() applicable_entries=()
  local entry label command_name
  for entry in "${plan_steps[@]}"; do
    label="${entry%%;*}"
    command_name="${entry#*;}"
    if (( ! include_remote_code )) \
      && [[ "$command_name" == "update-fzf" || "$command_name" == "update-omz" \
        || "$command_name" == "update-zsh-plugins" \
        || "$command_name" == "_sys_update_ai_tools" ]]; then
      continue
    fi
    if _sys_step_applies "$command_name"; then
      applicable_labels+=("$label")
      applicable_entries+=("$entry")
    fi
  done
  (( ${#applicable_labels[@]} > 0 )) || {
    _sys_warn "No update steps apply to the detected host."
    return 0
  }

  _sys_header "System Update Plan"
  _sys_info "Applicable steps: ${#applicable_labels[@]}"
  for label in "${applicable_labels[@]}"; do
    _sys_dim "$label"
  done
  _sys_warn "Package candidate lists are advisory snapshots."
  _sys_dim "Each package manager resolves its final dynamic transaction at execution."
  local apt_plan_entry="APT;update-apt"
  local apt_fingerprint=""
  if (( ${applicable_entries[(Ie)$apt_plan_entry]} > 0 )); then
    _sys_dim \
      "APT policy: run once first with lock timeout 0 and network retries 0."
    if (( include_phased_updates )); then
      _sys_warn \
        "APT phased updates are explicitly included in this authorized plan."
    else
      _sys_dim \
        "APT phased-update eligibility remains enabled by default."
    fi
    _sys_dim \
      "No other package process is signaled, no lock is deleted, and SIGKILL is never used."
    _sys_apt_plan_blocker || return $?
    apt_fingerprint="$REPLY"
  fi
  local -i _SYS_APT_PLAN_PREAUTHORIZED=1
  local _SYS_APT_AUTHORIZED_FINGERPRINT="$apt_fingerprint"
  _sys_update_lock_path || return $?
  local update_lock_path="$REPLY"
  _sys_dim \
    "Execution lock: $(_sys_display_escape "$update_lock_path") (non-blocking, per user)."
  (( include_remote_code )) \
    && _sys_warn \
      "The plan includes mutable Git origins and AI CLI self-updaters."
  _sys_warn \
    "One aggregate authorization runs every applicable step without further prompts."
  if (( include_remote_code )); then
    _sys_dim \
      "It pre-authorizes every mutable origin and self-updater in the plan."
    (( dry_run )) || _sys_dim \
      "Run this command with --dry-run first to review update targets."
  fi
  if (( dry_run )); then
    local -i preview_failures=0
    for entry in "${applicable_entries[@]}"; do
      label="${entry%%;*}"
      command_name="${entry#*;}"
      case "$command_name" in
        update-apt)
          _sys_blank
          _sys_info "Detailed preview: $label"
          local -a apt_preview_args=(--dry-run)
          (( include_phased_updates )) \
            && apt_preview_args+=(--include-phased-updates)
          (( verbose )) && apt_preview_args+=(--verbose)
          "$command_name" "${apt_preview_args[@]}" \
            || (( preview_failures++ ))
          ;;
        update-snap|update-fzf|update-omz|update-zsh-plugins)
          _sys_blank
          _sys_info "Detailed preview: $label"
          "$command_name" --dry-run || (( preview_failures++ ))
          ;;
        _sys_update_ai_tools)
          _sys_blank
          _sys_info "Detailed preview: $label"
          local -a ai_preview_args=(--dry-run)
          (( assume_yes )) && ai_preview_args+=(--yes)
          "$command_name" "${ai_preview_args[@]}" \
            || (( preview_failures++ ))
          ;;
        _sys_update_platform_packages)
          _sys_dim \
            "Native package candidates are queried immediately before execution."
          ;;
      esac
    done
    (( preview_failures == 0 )) || {
      local preview_noun="previews"
      (( preview_failures == 1 )) && preview_noun="preview"
      _sys_error "$preview_failures detailed $preview_noun failed."
      return 1
    }
    _sys_info "Dry run complete; no mutating update command was executed."
    return 0
  fi
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive aggregate updates require --yes."
      return 1
    fi
    _sys_confirm "Authorize and run this exact update plan?" || {
      _sys_info "Cancelled."
      return 0
    }
    # The confirmed plan is the one aggregate trust decision. Children run
    # with the same authorization as --yes so a mid-run prompt cannot stall
    # an unattended update; their validation still runs unchanged.
    assume_yes=1
    _sys_info \
      "Aggregate plan authorized; steps will run without further prompts."
  fi

  local update_lock_fd=""
  local sudo_authenticated=0
  local _SYS_UPDATE_SUDO_KEEPALIVE_HANDLE=""
  local update_rc=0
  # An outer invocation in this shell may already own the lock. Remember that
  # before acquisition so cleanup never releases a descriptor it did not open.
  local -i lock_held_before_acquire=$(( _SYS_UPDATE_LOCK_HELD ))
  {
    _sys_update_acquire_lock "$update_lock_path" || update_rc=$?
    if (( update_rc == 0 )); then
      update_lock_fd="$REPLY"
      _sys_dim "Exclusive update-system execution lock acquired."
      REPLY=0
      _sys_update_preauthenticate "${applicable_entries[@]}"
      sudo_authenticated="$REPLY"
      if [[ "$sudo_authenticated" != 0 \
        && "$sudo_authenticated" != 1 ]]; then
        update_rc=2
      else
        if (( sudo_authenticated )); then
          if _sys_update_start_sudo_keepalive "$sudo_authenticated"; then
            _SYS_UPDATE_SUDO_KEEPALIVE_HANDLE="$REPLY"
          else
            _sys_warn \
              "Sudo timestamp refresh could not start; package steps will still fail rather than reprompt."
          fi
        fi
        _sys_update_run \
          "$fail_fast" "$assume_yes" "$include_phased_updates" "$verbose" \
          "${applicable_entries[@]}" || update_rc=$?
      fi
    fi
  } always {
    if [[ -n "$_SYS_UPDATE_SUDO_KEEPALIVE_HANDLE" ]]; then
      _sys_update_stop_sudo_keepalive \
        "$_SYS_UPDATE_SUDO_KEEPALIVE_HANDLE" || true
      _SYS_UPDATE_SUDO_KEEPALIVE_HANDLE=""
    fi
    local cleanup_lock_fd="$update_lock_fd"
    if [[ -z "$cleanup_lock_fd" \
      && "$lock_held_before_acquire" == 0 \
      && "$_SYS_UPDATE_LOCK_HELD" == 1 \
      && "$_SYS_UPDATE_LOCK_HELD_FD" == <-> ]]; then
      cleanup_lock_fd="$_SYS_UPDATE_LOCK_HELD_FD"
    fi
    if [[ -n "$cleanup_lock_fd" ]]; then
      _sys_update_release_lock "$cleanup_lock_fd" || _sys_warn \
        "Unable to release the owned update-system execution lock cleanly."
      update_lock_fd=""
    fi
  }
  return $update_rc
}

typeset -g _SYS_UPDATE_SOURCED=1
