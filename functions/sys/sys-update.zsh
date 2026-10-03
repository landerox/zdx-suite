#!/usr/bin/env zsh
# =============================================================================
# System Update: update-system plan, authorization, lock, and step runner
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh and the sys-update-*.zsh step
# modules. Safe to re-source; defines functions and lock-state defaults only.
#

if [[ -n "${_SYS_UPDATE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Planning-time applicability dispatcher: exactly one call per plan entry, so
# steps that do not apply are omitted instead of reporting "skipping" later.
# Each predicate lives beside its step command in a sys-update-*.zsh module and
# mirrors that command's own skip conditions. Returns 0 if the step should run.
_sys_step_applies() {
  local REPLY
  local -a reply=()
  case "$1" in
    update-apt)                    _sys_update_apt_applies ;;
    _sys_update_platform_packages) _sys_update_platform_applies ;;
    update-snap)                   _sys_update_snap_applies ;;
    update-gcloud)                 _sys_update_gcloud_applies ;;
    update-brew)                   _sys_update_brew_applies ;;
    update-rust)                   _sys_update_rust_applies ;;
    update-uv-system)              _sys_update_uv_applies ;;
    update-pipx)                   _sys_update_pipx_applies ;;
    update-node)                   _sys_update_node_applies ;;
    update-starship)               _sys_update_starship_applies ;;
    update-fzf)                    _sys_update_fzf_applies ;;
    update-omz)                    _sys_update_omz_applies ;;
    update-zsh-plugins)            _sys_update_zsh_plugins_applies ;;
    update-repomix)                _sys_update_repomix_applies ;;
    _sys_update_ai_tools)          _sys_update_ai_applies ;;
    update-awscli)                 _sys_update_awscli_applies ;;
    *)                             return 0 ;;
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
