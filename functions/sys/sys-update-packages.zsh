#!/usr/bin/env zsh
# =============================================================================
# System Update Packages: Homebrew, Snap, and native package backends
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh and the platform adapters.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_UPDATE_PACKAGES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

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

# Aggregate applicability predicates. update-system calls them only through
# _sys_step_applies while it freezes the plan; each mirrors its step's own
# skip conditions.

_sys_update_platform_applies() {
  local package_backend
  package_backend=$(_sys_capability_value package_manager) || return 1
  _sys_has_capability "os-updates:softwareupdate" \
    && command -v softwareupdate &>/dev/null && return 0
  [[ "$package_backend" == (dnf|pacman|zypper|apk|softwareupdate) ]] \
    && command -v "$package_backend" &>/dev/null
}

_sys_update_snap_applies() {
  _sys_snap_ready
}

_sys_update_brew_applies() {
  command -v brew &>/dev/null
}

typeset -g _SYS_UPDATE_PACKAGES_SOURCED=1
