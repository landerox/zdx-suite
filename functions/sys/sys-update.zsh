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
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
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
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
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

# REPLY: the static scope shown for one plan entry. It never probes the host,
# so planning keeps exactly one applicability call per entry.
_sys_update_step_scope() {
  local command_name="${1:-}" phased="${2:-0}"
  case "$command_name" in
    update-apt)
      REPLY="APT packages · sudo"
      [[ "${SYS_APT_KEY_RENEWAL:-1}" == 1 ]] \
        && REPLY+=" · key renewal for known repositories"
      [[ "$phased" == 1 ]] && REPLY+=" · phased updates included"
      ;;
    _sys_update_platform_packages)
      local backend=""
      if _sys_has_capability "os-updates:softwareupdate"; then
        REPLY="softwareupdate: no-restart updates · sudo"
      else
        backend=$(_sys_capability_value package_manager 2>/dev/null) \
          || backend="native"
        REPLY="$backend packages · sudo"
      fi
      ;;
    update-snap)          REPLY="Snap refresh · sudo" ;;
    update-brew)
      REPLY="Homebrew formulae and casks"
      _sys_has_capability "os:darwin" && REPLY+=" · sudo for casks"
      ;;
    update-starship)      REPLY="Cargo-installed binary" ;;
    update-fzf)           REPLY="Git checkout · remote code" ;;
    update-gcloud)        REPLY="gcloud components" ;;
    update-awscli)        REPLY="AWS CLI owner" ;;
    update-uv-system)     REPLY="uv self-update" ;;
    update-pipx)          REPLY="pipx applications" ;;
    update-node)          REPLY="Node.js LTS via fnm or nvm" ;;
    update-rust)          REPLY="rustup toolchains" ;;
    update-omz)           REPLY="Git checkout · remote code" ;;
    update-zsh-plugins)   REPLY="Git checkouts · remote code" ;;
    *)                    REPLY="" ;;
  esac
}

# Returns 0 for entries that run mutable upstream code.
_sys_update_step_remote_code() {
  case "${1:-}" in
    update-fzf|update-omz|update-zsh-plugins) return 0 ;;
    *) return 1 ;;
  esac
}

# REPLY: the public command that retries one failed entry.
_sys_update_retry_command() {
  case "${1:-}" in
    _sys_update_platform_packages) REPLY="sys-menu update-system" ;;
    update-*)                      REPLY="sys-menu $1" ;;
    *)                             REPLY="" ;;
  esac
}

# Prints the numbered plan table for the frozen entries.
# Usage: _sys_update_render_plan <include-phased-updates> <entry>...
_sys_update_render_plan() {
  local phased="${1:-0}" entry REPLY
  shift
  local -a rows=()
  local -i index=0
  for entry in "$@"; do
    (( ++index ))
    _sys_update_step_scope "${entry#*;}" "$phased"
    rows+=("$index"$'\t'"${entry%%;*}"$'\t'"$REPLY")
  done
  if (( ${+functions[_zdx_ui_table]} )); then
    _zdx_ui_table $'#\tStep\tScope' "${rows[@]}"
  else
    local row
    for row in "${rows[@]}"; do
      _sys_dim "${row//$'\t'/  }"
    done
  fi
}

# Prints at most two disclosure lines before authorization.
# Usage: _sys_update_render_disclosures <dry-run> <entry>...
_sys_update_render_disclosures() {
  local dry_run="${1:-0}" entry REPLY
  shift
  local -i total=$# remote=0 privileged=0
  for entry in "$@"; do
    _sys_update_step_remote_code "${entry#*;}" && (( ++remote ))
    _sys_update_step_requires_privilege "${entry#*;}" && (( ++privileged ))
  done
  if (( remote > 0 )); then
    _sys_count_noun "$remote" step
    if (( dry_run )); then
      _sys_warn "$REPLY run mutable upstream code (marked remote code)."
    else
      _sys_warn "$REPLY run mutable upstream code (marked remote code); review them first with --dry-run."
    fi
  fi
  (( dry_run )) && return 0
  local scope="all $total steps"
  (( total == 1 )) && scope="this step"
  if (( privileged > 0 && EUID != 0 )); then
    _sys_warn "One authorization runs $scope without further prompts; sudo is requested at most once."
  else
    _sys_warn "One authorization runs $scope without further prompts."
  fi
}

# Prints the static plan policy, shown only with --verbose or --dry-run.
# Usage: _sys_update_render_policy <apt-planned> <phased> <lock-path>
_sys_update_render_policy() {
  local apt_planned="${1:-0}" phased="${2:-0}" lock_path="${3:-}"
  _sys_dim "Package candidates are advisory; each package manager resolves its final transaction at execution."
  if (( apt_planned )); then
    if (( phased )); then
      _sys_dim "APT runs once, first, with lock timeout 0 and network retries 0."
      _sys_dim "Phased updates are explicitly included."
    else
      _sys_dim "APT runs once, first, with lock timeout 0 and network retries 0."
      _sys_dim "Phased-update eligibility remains in effect."
    fi
    _sys_dim "No other package process is signaled, no lock file is deleted, and SIGKILL is never used."
  fi
  [[ -n "$lock_path" ]] && _sys_dim \
    "Execution lock: $(_sys_display_escape "$lock_path") (per user, non-blocking; --dry-run does not take it)."
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
    || "$command_name" == "update-zsh-plugins" ]]; then
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
  local REPLY
  local -a reply=()
  local errors=0
  local step=0
  local -a failed_labels=() summary_records=() retry_commands=()
  local -a applicable=("$@")
  local -i _SYS_PRIVILEGE_NONINTERACTIVE=1
  local entry label cmd outcome detail step_seconds duration_label category
  local remaining stop_detail retry_command
  local -i step_rc=0
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
    _sys_step_banner "$step" "$total" "$label"

    step_rc=0
    _sys_step_exec _sys_run_update_step \
      "$cmd" "$assume_yes" "$include_phased_updates" "$verbose" </dev/null \
      || step_rc=$?
    outcome="${reply[1]:-done}"
    detail="${reply[2]:-}"
    step_seconds="${reply[3]:-0}"
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
    _sys_step_result "$step" "$total" "$label" "$outcome" "$detail" \
      "$step_seconds"
    summary_records+=("$label"$'\t'"$outcome"$'\t'"$step_seconds"$'\t'"$detail")
    _sys_update_step_category "$cmd"
    category="$REPLY"
    if (( step_rc == 0 )); then
      if [[ "$category" == "core" ]]; then
        (( ++core_succeeded ))
      else
        (( ++optional_succeeded ))
      fi
      continue
    fi

    errors=$((errors + 1))
    if [[ "$category" == "core" ]]; then
      (( ++core_failed ))
    else
      (( ++optional_failed ))
    fi
    _sys_duration_label "$step_seconds"
    duration_label="$REPLY"
    if [[ -n "$detail" && "$detail" != "status $step_rc" ]]; then
      failed_labels+=("$label — $detail ($duration_label)")
    else
      failed_labels+=("$label ($duration_label)")
    fi
    _sys_update_retry_command "$cmd"
    [[ -n "$REPLY" ]] && retry_commands+=("$REPLY")

    if (( fail_fast || step_rc == 130 || step_rc == 143 )); then
      stop_detail="stopped by --fail-fast"
      (( step_rc == 130 || step_rc == 143 )) && stop_detail="update interrupted"
      for remaining in "${(@)applicable[step+1,-1]}"; do
        summary_records+=("${remaining%%;*}"$'\tnot-run\t\t'"$stop_detail")
      done
      _sys_print_step_summary "Update Summary" "${summary_records[@]}"
      if (( step_rc == 130 || step_rc == 143 )); then
        _sys_error "System update interrupted (status $step_rc): $label"
      else
        _sys_error "Aborting after first failure (--fail-fast): $label"
      fi
      _sys_count_noun "$total" step
      _sys_dim "Stopped at $step of $REPLY."
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
  done

  _sys_print_step_summary "Update Summary" "${summary_records[@]}"
  _sys_update_print_category_summary \
    "Core package steps" "$core_succeeded" "$core_total" \
    "$core_failed" 0
  _sys_update_print_category_summary \
    "Optional tool steps" "$optional_succeeded" "$optional_total" \
    "$optional_failed" 0
  _sys_count_noun "$total" step
  if (( errors == 0 )); then
    _sys_success "System update completed successfully! ($total/$REPLY)"
    return 0
  fi
  if (( errors < total )); then
    _sys_error \
      "System update completed with partial failures: $errors of $REPLY failed."
    typeset -f _zdx_timed_mark_partial &>/dev/null \
      && _zdx_timed_mark_partial || true
  elif (( total == 1 )); then
    _sys_error "System update failed: the only step failed."
  else
    _sys_error "System update failed: all $REPLY failed."
  fi
  local failed_label
  for failed_label in "${failed_labels[@]}"; do
    _sys_dim "• $failed_label"
  done
  _sys_info "Retry only the failed steps after resolving the errors above:"
  for retry_command in "${(@u)retry_commands}"; do
    _sys_dim "  $retry_command"
  done
  return 1
}

# Runs the read-only previews of a dry run as numbered steps.
# Usage: _sys_update_run_previews <assume-yes> <phased> <verbose> <entry>...
_sys_update_run_previews() {
  local assume_yes="${1:-0}" phased="${2:-0}" verbose="${3:-0}"
  shift 3 2>/dev/null || return 2
  local REPLY entry label command_name outcome detail seconds
  local -a reply=() previews=() preview_args=() summary_records=()
  local -i preview_failures=0 index=0 preview_rc=0
  for entry in "$@"; do
    case "${entry#*;}" in
      update-apt|update-snap|update-fzf|update-omz|update-zsh-plugins)
        previews+=("$entry")
        ;;
      _sys_update_platform_packages)
        _sys_dim \
          "Native package candidates are queried immediately before execution."
        ;;
    esac
  done
  (( ${#previews[@]} > 0 )) && _sys_header "Detailed Previews"
  for entry in "${previews[@]}"; do
    (( ++index ))
    label="${entry%%;*}"
    command_name="${entry#*;}"
    preview_args=(--dry-run)
    case "$command_name" in
      update-apt)
        (( phased )) && preview_args+=(--include-phased-updates)
        (( verbose )) && preview_args+=(--verbose)
        ;;
    esac
    _sys_step_banner "$index" "${#previews[@]}" "$label"
    preview_rc=0
    _sys_step_exec "$command_name" "${preview_args[@]}" </dev/null \
      || preview_rc=$?
    outcome="${reply[1]:-done}"
    detail="${reply[2]:-}"
    seconds="${reply[3]:-}"
    [[ "$outcome" == done ]] && outcome=planned
    _sys_step_result "$index" "${#previews[@]}" "$label" "$outcome" \
      "$detail" "$seconds"
    summary_records+=("$label"$'\t'"$outcome"$'\t'"$seconds"$'\t'"$detail")
    (( preview_rc == 0 )) || (( ++preview_failures ))
  done
  (( ${#summary_records[@]} > 0 )) \
    && _sys_print_step_summary "Preview Summary" "${summary_records[@]}"
  if (( preview_failures > 0 )); then
    _sys_count_noun "$preview_failures" "detailed preview"
    _sys_error "$REPLY failed."
    return 1
  fi
  _sys_info "Dry run complete; no mutating update command was executed."
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
Git origins and script-owned updaters.
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
  --safe-only       Exclude mutable Git and script update workflows.
  --include-remote-code
                    Explicitly affirm their default inclusion.
  --help, -h        Show this help.

Steps that do not apply to the detected host are omitted. APT runs once, as the
first step after sudo pre-authentication, with lock timeout and network retries
set to zero. One exact automatic unattended-upgrade may receive a validated
cooperative SIGTERM; ZDX never polls, retries a lock, deletes locks, or sends
SIGKILL. By default, APT continues to respect Ubuntu phased-update eligibility.
When a known repository's signing key expired or changed, APT installs the
publisher's current key into that repository's dedicated keyring and repeats
the index refresh once; SYS_APT_KEY_RENEWAL=0 disables this.
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
  # --verbose also streams captured step output for this run only.
  local ZDX_VERBOSE="${ZDX_VERBOSE:-}"
  (( verbose )) && ZDX_VERBOSE=1

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
    "Oh My Zsh;update-omz"
    "Zsh Plugins;update-zsh-plugins"
  )
  local -a applicable_labels=() applicable_entries=()
  local entry label command_name
  for entry in "${plan_steps[@]}"; do
    label="${entry%%;*}"
    command_name="${entry#*;}"
    if (( ! include_remote_code )) \
      && _sys_update_step_remote_code "$command_name"; then
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
  _sys_update_render_plan "$include_phased_updates" "${applicable_entries[@]}"
  local apt_plan_entry="APT;update-apt"
  local apt_fingerprint=""
  local -i apt_planned=0
  (( ${applicable_entries[(Ie)$apt_plan_entry]} > 0 )) && apt_planned=1
  if (( apt_planned )); then
    _sys_apt_plan_blocker || return $?
    apt_fingerprint="$REPLY"
    local -i key_renewal_rc=0
    _sys_apt_key_renewal_enabled || key_renewal_rc=$?
    (( key_renewal_rc != 2 )) || return 2
  fi
  local -i _SYS_APT_PLAN_PREAUTHORIZED=1
  local _SYS_APT_AUTHORIZED_FINGERPRINT="$apt_fingerprint"
  _sys_update_lock_path || return $?
  local update_lock_path="$REPLY"
  _sys_update_render_disclosures "$dry_run" "${applicable_entries[@]}"
  (( dry_run || verbose )) && _sys_update_render_policy \
    "$apt_planned" "$include_phased_updates" "$update_lock_path"
  if (( dry_run )); then
    _sys_update_run_previews "$assume_yes" "$include_phased_updates" \
      "$verbose" "${applicable_entries[@]}"
    return $?
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
      _sys_verbose_dim "Exclusive update-system execution lock acquired."
      REPLY=0
      _sys_update_preauthenticate "${applicable_entries[@]}"
      sudo_authenticated="$REPLY"
      if [[ "$sudo_authenticated" != 0 \
        && "$sudo_authenticated" != 1 ]]; then
        update_rc=2
      else
        # The refresher warns itself when it cannot run; privileged steps
        # then still fail rather than reprompt.
        if (( sudo_authenticated )) \
          && _sys_update_start_sudo_keepalive "$sudo_authenticated"; then
          _SYS_UPDATE_SUDO_KEEPALIVE_HANDLE="$REPLY"
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
