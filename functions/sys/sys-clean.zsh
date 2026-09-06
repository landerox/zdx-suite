#!/usr/bin/env zsh
# =============================================================================
# System Clean: cleanup of caches, logs and temporary system data
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, sys-capabilities.zsh, and the
# platform adapters.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_CLEAN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# =============================================================================
# CLEAN STEPS (internal helpers)
# =============================================================================

_sys_clean_validate_user_path() {
  local candidate="$1"
  local home_abs="${HOME:A}"
  local current="$HOME"
  local relative_path

  [[ "$candidate" == /* && "$candidate" != *$'\n'* \
    && "$candidate" != *$'\r'* && "$candidate" != *$'\t'* \
    && "$candidate" != *'|'* ]] || {
    _sys_error "Cleanup target is not a safe absolute path."
    return 1
  }
  [[ "${candidate:A}" == "$home_abs"/* \
    && "${candidate:A}" != "$home_abs" ]] || {
    _sys_error "Cleanup target is outside the protected user boundary."
    return 1
  }

  relative_path="${candidate#$HOME/}"
  local component
  for component in "${(@s:/:)relative_path}"; do
    current+="/$component"
    [[ ! -L "$current" ]] || {
      _sys_error "Cleanup target crosses a symbolic link."
      return 1
    }
  done
  if [[ -e "$candidate" ]]; then
    [[ -d "$candidate" && ! -L "$candidate" && -O "$candidate" ]] || {
      _sys_error "Cleanup target must be a user-owned directory."
      return 1
    }
  fi
  REPLY="${candidate:A}"
}

_sys_clean_npm_cache_dir() {
  local REPLY
  local cache_dir
  cache_dir=$(_sys_run_with_timeout 5 npm config get cache 2>/dev/null) \
    || return 1
  _sys_clean_validate_user_path "$cache_dir" || return 1
  print -r -- "$REPLY"
}

_sys_clean_uv_cache_dir() {
  local REPLY
  local cache_dir
  cache_dir=$(_sys_run_with_timeout 5 uv cache dir 2>/dev/null) || return 1
  _sys_clean_validate_user_path "$cache_dir" || return 1
  print -r -- "$REPLY"
}

_sys_clean_pip_cache_dir() {
  local REPLY
  local cache_dir
  cache_dir=$(_sys_run_with_timeout 5 pip cache dir 2>/dev/null) || return 1
  _sys_clean_validate_user_path "$cache_dir" || return 1
  print -r -- "$REPLY"
}

_sys_clean_go_cache_dir() {
  local REPLY
  local cache_dir
  cache_dir=$(_sys_run_with_timeout 5 go env GOMODCACHE 2>/dev/null) \
    || return 1
  _sys_clean_validate_user_path "$cache_dir" || return 1
  print -r -- "$REPLY"
}

_sys_disabled_snap_revisions() {
  local output
  output=$(LC_ALL=C _sys_run_with_timeout 20 snap list --all 2>/dev/null)
  local rc=$?
  (( rc != 0 )) && return "$rc"
  print -r -- "$output" | command awk '/disabled/{print $1, $3}'
}

_sys_validate_disabled_snap_revisions() {
  local disabled_snaps="$1"
  [[ -n "$disabled_snaps" ]] || return 0

  local record name rev extra
  for record in "${(@f)disabled_snaps}"; do
    read -r name rev extra <<< "$record"
    [[ -z "$extra" && "$name" =~ '^[[:alnum:]][[:alnum:]._-]*$' \
      && "$rev" =~ '^[0-9]+$' ]] || {
      _sys_error "Invalid disabled Snap record; refusing the cleanup plan."
      return 1
    }
    print -r -- "$name $rev"
  done
}

_sys_remove_disabled_snap_revisions() {
  local disabled_snaps="$1"

  [[ -z "$disabled_snaps" ]] && return 0

  local -a privilege_prefix=()
  if (( EUID == 0 )); then
    privilege_prefix=()
  elif _sys_has_capability "privilege:sudo" \
    && command -v sudo &>/dev/null; then
    _sys_info "Privileged authentication: sudo -v"
    sudo -v >&2 || {
      _sys_error "sudo authentication failed; no Snap revision was removed."
      return 1
    }
    privilege_prefix=(sudo -n)
  else
    _sys_error "No supported privilege path is available."
    return 1
  fi
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  local -a snap_records=("${(@f)disabled_snaps}")
  local record name rev current_disabled
  local -i failures=0
  for record in "${snap_records[@]}"; do
    read -r name rev <<< "$record"
    [[ "$name" =~ '^[[:alnum:]][[:alnum:]._-]*$' \
      && "$rev" =~ '^[0-9]+$' ]] || {
      _sys_error "Invalid disabled Snap record; refusing to remove it."
      (( failures++ ))
      continue
    }

    current_disabled=$(_sys_disabled_snap_revisions) || {
      _sys_error "Unable to revalidate $name revision $rev."
      (( failures++ ))
      continue
    }
    current_disabled=$(
      _sys_validate_disabled_snap_revisions "$current_disabled"
    ) || {
      (( failures++ ))
      continue
    }
    local -a current_records=()
    [[ -n "$current_disabled" ]] \
      && current_records=("${(@f)current_disabled}")
    local current_record
    local -i still_disabled=0
    for current_record in "${current_records[@]}"; do
      if [[ "$current_record" == "$record" ]]; then
        still_disabled=1
        break
      fi
    done
    if (( ! still_disabled )); then
      _sys_error \
        "$name revision $rev is no longer disabled; refusing to remove it."
      (( failures++ ))
      continue
    fi

    _sys_info "Removing $name rev $rev..."
    _sys_dim \
      "Privileged operation: ${privilege_label}snap remove $name --revision=$rev"
    "${privilege_prefix[@]}" \
      snap remove "$name" --revision="$rev" 2>/dev/null || {
        _sys_error "Failed to remove $name revision $rev."
        (( failures++ ))
      }
  done
  (( failures == 0 ))
}

_sys_clean_step_apt_cache() {
  local -a reply=()
  _sys_has_capability "package:apt" || {
    _sys_info "APT is not the active package backend, skipping."
    return 0
  }
  local -a privilege_prefix=()
  _sys_resolve_privilege_prefix || return 1
  privilege_prefix=("${reply[@]}")
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  _sys_dim "Privileged operation: ${privilege_label}apt-get clean"
  "${privilege_prefix[@]}" apt-get clean >&2
}

_sys_clean_step_homebrew() {
  if ! command -v brew &>/dev/null; then
    _sys_info "Homebrew not installed, skipping."
    return 0
  fi

  _sys_dim "May take several minutes on large Homebrew installs."
  _sys_brew autoremove >&2 || return $?
  _sys_brew cleanup --prune=all >&2
}

_sys_clean_step_snap_revisions() {
  if ! command -v snap &>/dev/null; then
    _sys_info "Snap not installed, skipping."
    return 0
  fi

  if ! _sys_snap_ready; then
    _sys_warn "snapd is not available — skipping disabled snap cleanup."
    _sys_dim "This avoids hangs in WSL environments without a running snapd."
    return 0
  fi

  local disabled_snaps
  disabled_snaps=$(_sys_disabled_snap_revisions)
  local rc=$?
  if (( rc == 124 )); then
    _sys_warn "Timed out while listing disabled snap revisions."
    return 124
  elif (( rc != 0 )); then
    _sys_warn "Could not inspect disabled snap revisions."
    return 1
  fi
  disabled_snaps=$(_sys_validate_disabled_snap_revisions "$disabled_snaps") \
    || return 1

  if [[ -z "$disabled_snaps" ]]; then
    _sys_info "No disabled snap revisions to remove."
    return 0
  fi

  _sys_dim "May take several minutes if many snap revisions are pending removal."
  _sys_remove_disabled_snap_revisions "$disabled_snaps"
}

_sys_clean_step_npm_cache() {
  local REPLY
  if ! command -v npm &>/dev/null; then
    _sys_info "npm not installed, skipping."
    return 0
  fi

  local expected_cache="${1:-}"
  local cache_dir
  cache_dir=$(_sys_clean_npm_cache_dir) || return 1
  [[ -n "$expected_cache" && "$cache_dir" == "$expected_cache" ]] || {
    _sys_error "npm cache path changed after confirmation."
    return 1
  }
  _sys_clean_validate_user_path "$expected_cache" || return 1
  cache_dir="$REPLY"
  [[ -d "$cache_dir" ]] || {
    _sys_error "The confirmed npm cache directory is no longer available."
    return 1
  }
  _sys_run_logged npm-cache env npm_config_cache="$cache_dir" \
    npm cache clean --force
}

_sys_clean_step_uv_cache() {
  local REPLY
  if ! command -v uv &>/dev/null; then
    _sys_info "uv not installed, skipping."
    return 0
  fi

  local expected_cache="${1:-}"
  local cache_dir
  cache_dir=$(_sys_clean_uv_cache_dir) || return 1
  [[ -n "$expected_cache" && "$cache_dir" == "$expected_cache" ]] || {
    _sys_error "uv cache path changed after confirmation."
    return 1
  }
  _sys_clean_validate_user_path "$expected_cache" || return 1
  cache_dir="$REPLY"
  [[ -d "$cache_dir" ]] || {
    _sys_error "The confirmed uv cache directory is no longer available."
    return 1
  }
  _sys_run_logged uv-cache env UV_CACHE_DIR="$cache_dir" uv cache clean
}

_sys_clean_step_pip_cache() {
  local REPLY
  if ! command -v pip &>/dev/null; then
    _sys_info "pip not installed, skipping."
    return 0
  fi

  local expected_cache="${1:-}"
  local cache_dir
  cache_dir=$(_sys_clean_pip_cache_dir) || return 1
  [[ -n "$expected_cache" && "$cache_dir" == "$expected_cache" ]] || {
    _sys_error "pip cache path changed after confirmation."
    return 1
  }
  _sys_clean_validate_user_path "$expected_cache" || return 1
  cache_dir="$REPLY"
  [[ -d "$cache_dir" ]] || {
    _sys_error "The confirmed pip cache directory is no longer available."
    return 1
  }
  _sys_run_logged pip-cache env PIP_CACHE_DIR="$cache_dir" pip cache purge
}

_sys_clean_step_rust_downloads() {
  local REPLY
  if ! command -v rustup &>/dev/null; then
    _sys_info "rustup not installed, skipping."
    return 0
  fi

  local rustup_downloads="${1:-}"
  if [[ -d "$rustup_downloads" ]]; then
    _sys_clean_validate_user_path "$rustup_downloads" || return 1
    command rm -rf -- "$REPLY"/*(ND)
    _sys_dim "Cleared rustup download cache"
  else
    _sys_info "No rustup download cache found."
  fi
}

_sys_clean_step_cargo_cache() {
  local REPLY
  if ! command -v cargo &>/dev/null; then
    _sys_info "cargo not installed, skipping."
    return 0
  fi

  local cargo_cache="${1:-}"
  if [[ -d "$cargo_cache" ]]; then
    _sys_clean_validate_user_path "$cargo_cache" || return 1
    cargo_cache="$REPLY"
    local cache_size
    cache_size=$(command du -sh -- "$cargo_cache" 2>/dev/null \
      | command awk '{print $1}')
    command rm -rf -- "$cargo_cache"/*(ND)
    _sys_dim "Freed ${cache_size:-some} from cargo registry cache"
  else
    _sys_info "No cargo registry cache found."
  fi
}

_sys_clean_step_go_modcache() {
  local REPLY
  if ! command -v go &>/dev/null; then
    _sys_info "Go not installed, skipping."
    return 0
  fi

  _sys_dim "May take several minutes for large module caches."
  local expected_cache="${1:-}"
  local cache_dir
  cache_dir=$(_sys_clean_go_cache_dir) || return 1
  [[ -n "$expected_cache" && "$cache_dir" == "$expected_cache" ]] || {
    _sys_error "Go module cache path changed after confirmation."
    return 1
  }
  _sys_clean_validate_user_path "$expected_cache" || return 1
  cache_dir="$REPLY"
  [[ -d "$cache_dir" ]] || {
    _sys_error "The confirmed Go module cache is no longer available."
    return 1
  }
  env GOMODCACHE="$cache_dir" go clean -modcache >&2
}

_sys_clean_step_journal() {
  local -a reply=()
  if ! _sys_has_systemd; then
    _sys_dim "Systemd not active — skipping journal vacuum"
    return 0
  fi

  local -a privilege_prefix=()
  _sys_resolve_privilege_prefix || return 1
  privilege_prefix=("${reply[@]}")
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  _sys_dim \
    "Privileged operation: ${privilege_label}journalctl --vacuum-time=3d"
  "${privilege_prefix[@]}" journalctl --vacuum-time=3d >&2
}

_sys_clean_step_thumbnails() {
  local REPLY
  local thumbnails_dir="${1:-}"
  [[ -d "$thumbnails_dir" ]] || return 0
  _sys_clean_validate_user_path "$thumbnails_dir" || return 1
  command rm -rf -- "$REPLY"/*(ND) 2>/dev/null
}

_sys_clean_step_temp_files() {
  local REPLY
  local cache_tmp="${1:-}"
  [[ -d "$cache_tmp" ]] || return 0
  _sys_clean_validate_user_path "$cache_tmp" || return 1
  command rm -rf -- "$REPLY"/*(ND) 2>/dev/null
}

_sys_clean_plan() {
  local REPLY
  local mode="$1"
  _sys_has_capability "package:apt" \
    && print -r -- "APT cache|apt-get clean"
  local cache_dir
  if command -v npm &>/dev/null; then
    cache_dir=$(_sys_clean_npm_cache_dir) || return 1
    [[ -d "$cache_dir" ]] && print -r -- "npm cache|$cache_dir"
  fi
  if command -v uv &>/dev/null; then
    cache_dir=$(_sys_clean_uv_cache_dir) || return 1
    [[ -d "$cache_dir" ]] && print -r -- "uv cache|$cache_dir"
  fi
  if command -v pip &>/dev/null; then
    cache_dir=$(_sys_clean_pip_cache_dir) || return 1
    [[ -d "$cache_dir" ]] && print -r -- "pip cache|$cache_dir"
  fi
  if command -v cargo &>/dev/null \
    && [[ -d "${CARGO_HOME:-$HOME/.cargo}/registry/cache" ]]; then
    _sys_clean_validate_user_path \
      "${CARGO_HOME:-$HOME/.cargo}/registry/cache" || return 1
    print -r -- "Cargo registry cache|$REPLY"
  fi
  _sys_has_systemd \
    && print -r -- "Journal logs|journal entries older than 3 days"
  if [[ -d "$HOME/.cache/thumbnails" ]]; then
    _sys_clean_validate_user_path "$HOME/.cache/thumbnails" || return 1
    print -r -- "Thumbnail cache|$REPLY"
  fi
  if [[ -d "$HOME/.cache/tmp" ]]; then
    _sys_clean_validate_user_path "$HOME/.cache/tmp" || return 1
    print -r -- "Temporary files|$REPLY"
  fi

  if [[ "$mode" == "deep" ]]; then
    command -v brew &>/dev/null \
      && print -r -- "Homebrew cleanup|brew autoremove and cleanup --prune=all"
    if command -v rustup &>/dev/null \
      && [[ -d "${RUSTUP_HOME:-$HOME/.rustup}/downloads" ]]; then
      _sys_clean_validate_user_path \
        "${RUSTUP_HOME:-$HOME/.rustup}/downloads" || return 1
      print -r -- "Rust downloads|$REPLY"
    fi
    if command -v go &>/dev/null; then
      cache_dir=$(_sys_clean_go_cache_dir) || return 1
      [[ -d "$cache_dir" ]] && print -r -- "Go module cache|$cache_dir"
    fi
  fi
}

_sys_clean_run() {
  local mode="${1:-deep}"
  local plan_output="${2:-}"
  local REPLY
  local -a reply=()
  local errors=0
  local step=0
  local -a failed_labels=()
  local start_time=$SECONDS
  local entry label func step_start rc

  local -a steps_quick=(
    "APT cache;_sys_clean_step_apt_cache"
    "npm cache;_sys_clean_step_npm_cache"
    "uv cache;_sys_clean_step_uv_cache"
    "pip cache;_sys_clean_step_pip_cache"
    "Cargo registry cache;_sys_clean_step_cargo_cache"
    "Journal logs;_sys_clean_step_journal"
    "Thumbnail cache;_sys_clean_step_thumbnails"
    "Temporary files;_sys_clean_step_temp_files"
  )

  local -a steps_deep=(
    "APT cache;_sys_clean_step_apt_cache"
    "Homebrew cleanup;_sys_clean_step_homebrew"
    "npm cache;_sys_clean_step_npm_cache"
    "uv cache;_sys_clean_step_uv_cache"
    "pip cache;_sys_clean_step_pip_cache"
    "Rust downloads;_sys_clean_step_rust_downloads"
    "Cargo registry cache;_sys_clean_step_cargo_cache"
    "Go module cache;_sys_clean_step_go_modcache"
    "Journal logs;_sys_clean_step_journal"
    "Thumbnail cache;_sys_clean_step_thumbnails"
    "Temporary files;_sys_clean_step_temp_files"
  )

  local -a steps
  if [[ "$mode" == "deep" ]]; then
    steps=("${steps_deep[@]}")
  else
    steps=("${steps_quick[@]}")
  fi

  local -A planned_scopes=()
  local plan_record plan_label plan_scope
  for plan_record in "${(@f)plan_output}"; do
    [[ "$plan_record" == *"|"* ]] || {
      _sys_error "Invalid cleanup plan record."
      return 1
    }
    plan_label="${plan_record%%|*}"
    plan_scope="${plan_record#*|}"
    [[ -n "$plan_label" && -n "$plan_scope" ]] \
      && (( ! ${+planned_scopes[$plan_label]} )) || {
      _sys_error "Ambiguous cleanup plan record."
      return 1
    }
    planned_scopes[$plan_label]="$plan_scope"
  done

  local -a applicable_steps=()
  for entry in "${steps[@]}"; do
    label="${entry%%;*}"
    (( ${+planned_scopes[$label]} )) && applicable_steps+=("$entry")
  done
  if (( ${#applicable_steps[@]} != ${#planned_scopes[@]} )); then
    _sys_error "Cleanup plan contains an unsupported step."
    return 1
  fi
  steps=("${applicable_steps[@]}")

  local total=${#steps[@]}
  (( total > 0 )) || {
    _sys_info "No cleanup targets remain."
    return 0
  }
  for entry in "${steps[@]}"; do
    step=$((step + 1))
    label="${entry%%;*}"
    func="${entry#*;}"
    step_start=$SECONDS

    _sys_info "Step $step/$total: $label"
    "$func" "${planned_scopes[$label]}"
    rc=$?

    _sys_dim "Step time: $(_sys_format_duration $(( SECONDS - step_start )))"
    if (( rc != 0 )); then
      errors=$((errors + 1))
      failed_labels+=("$label")
      if (( rc == 124 )); then
        _sys_warn "Timed out while cleaning: $label"
      else
        _sys_warn "Finished with issues: $label"
      fi
    fi
  done

  local elapsed=$(( SECONDS - start_time ))

  _sys_blank
  _sys_dim "Completed in $(_sys_format_duration "$elapsed")"
  if (( errors == 0 )); then
    _sys_success "System cleanup completed successfully! ($total/$total steps)"
  else
    _sys_warn "Cleanup completed with $errors issue(s) out of $total steps:"
    for label in "${failed_labels[@]}"; do
      _sys_warn "  • $label"
    done
    return 1
  fi
  return 0
}

_sys_clean_system_main() {
  local mode="${1:?cleanup mode required}"
  shift
  local assume_yes=0 dry_run=0
  local REPLY
  local -a reply=()

  while (( $# )); do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      --help|-h)
        (( $# == 1 && ! assume_yes && ! dry_run )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        print -u2 -r -- \
          "Usage: clean-system-${mode} [--dry-run] [-y|--yes] [-h|--help]"
        return 0 ;;
      *)
        _sys_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  local plan_output
  plan_output=$(_sys_clean_plan "$mode") || return 1
  local -a plan_records=()
  [[ -n "$plan_output" ]] && plan_records=("${(@f)plan_output}")
  _sys_header "${mode:u} Cleanup Plan"
  _sys_info "Validated steps: ${#plan_records[@]}"
  local plan_record plan_label plan_scope
  for plan_record in "${plan_records[@]}"; do
    plan_label="${plan_record%%|*}"
    plan_scope="${plan_record#*|}"
    _sys_dim "$plan_label — $(_sys_display_escape "$plan_scope")"
  done
  _sys_warn "Shared /tmp content and Docker resources are never removed by this workflow."

  if (( dry_run )); then
    _sys_info "Dry run complete; no cleanup step was executed."
    return 0
  fi
  (( ${#plan_records[@]} > 0 )) || {
    _sys_info "No applicable cleanup targets were found."
    return 0
  }

  if [[ "$mode" == "deep" ]]; then
    _sys_test_pkg_manager all || return 1
  elif _sys_has_capability "package:apt"; then
    _sys_test_pkg_manager apt || return 1
  fi

  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive cleanup requires --yes."
      return 1
    fi

    _sys_info "This will remove cache and temporary data for this system."
    if [[ "$mode" == "quick" ]]; then
      _sys_dim "Quick mode: package/language caches, journal, thumbnails, and user temp cache."
    else
      _sys_warn "Deep mode includes Homebrew cleanup plus Rust and Go caches."
      _sys_dim "Use quick mode if you want a fast cleanup with lower risk of long waits."
    fi
    _sys_blank
    _sys_confirm "Proceed with this exact ${mode} cleanup plan?" || {
      _sys_blank
      _sys_info "Cancelled."
      return 0
    }
    _sys_blank
  fi

  _sys_clean_run "$mode" "$plan_output"
}

# =============================================================================
# PUBLIC COMMANDS
# =============================================================================

clean-journal() {
  local -i assume_yes=0 dry_run=0
  local -a reply=()
  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! dry_run && ! assume_yes )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        print -u2 -r -- \
          'Usage: clean-journal [--dry-run] [-y|--yes] [-h|--help]'
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      -y|--yes)  assume_yes=1 ;;
      *)
        _sys_error "Unknown option for clean-journal: $1"
        return 2
        ;;
    esac
    shift
  done
  _sys_header "Journal Cleanup Plan"

  if ! _sys_has_systemd; then
    _sys_error "The systemd journal capability is unavailable."
    return 1
  fi

  local before_size
  before_size=$(_sys_run_with_timeout 5 journalctl --disk-usage 2>/dev/null \
    | command grep -oE '[0-9.]+[KMGT]?i?B' | command head -1)
  _sys_info "Current journal size: ${before_size:-unknown}"
  _sys_info "Target: journal entries older than 3 days."
  (( dry_run )) && {
    _sys_info "Dry run complete; the journal was not changed."
    return 0
  }
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive journal cleanup requires --yes."
      return 1
    fi
    _sys_confirm "Vacuum this exact journal scope?" || {
      _sys_info "Cancelled."
      return 0
    }
  fi

  _sys_info "Vacuuming logs older than 3 days..."
  local -a privilege_prefix=()
  _sys_resolve_privilege_prefix || return 1
  privilege_prefix=("${reply[@]}")
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  _sys_info \
    "Privileged operation: ${privilege_label}journalctl --vacuum-time=3d"
  "${privilege_prefix[@]}" journalctl --vacuum-time=3d >&2 || {
    local cleanup_rc=$?
    _sys_error "Journal cleanup failed."
    return "$cleanup_rc"
  }

  local after_size
  after_size=$(_sys_run_with_timeout 5 journalctl --disk-usage 2>/dev/null \
    | command grep -oE '[0-9.]+[KMGT]?i?B' | command head -1)
  _sys_success "Journal cleaned. Now: ${after_size:-unknown}"
}

clean-snaps() {
  local assume_yes=0 dry_run=0

  while (( $# )); do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      --help|-h)
        (( $# == 1 && ! assume_yes && ! dry_run )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        print -u2 -r -- \
          "Usage: clean-snaps [--dry-run] [-y|--yes] [-h|--help]"
        return 0 ;;
      *)
        _sys_error "Unknown option for clean-snaps: $1"
        return 2
        ;;
    esac
    shift
  done

  _sys_header "Cleaning Disabled Snap Revisions"

  if ! command -v snap &>/dev/null; then
    _sys_info "Snap not installed, skipping."
    return 0
  fi

  if ! _sys_snap_ready; then
    _sys_warn "snap is installed, but snapd is not available in this environment."
    _sys_dim "Skipping to avoid hangs while waiting for snapd."
    return 0
  fi

  local disabled_snaps
  disabled_snaps=$(_sys_disabled_snap_revisions)
  local rc=$?
  if (( rc == 124 )); then
    _sys_warn "Timed out while querying disabled snap revisions."
    return 1
  elif (( rc != 0 )); then
    _sys_error "Failed to inspect disabled snap revisions."
    return 1
  fi
  disabled_snaps=$(_sys_validate_disabled_snap_revisions "$disabled_snaps") \
    || return 1

  if [[ -z "$disabled_snaps" ]]; then
    _sys_info "No disabled snap revisions found."
    return 0
  fi

  local -a snap_lines=( "${(@f)disabled_snaps}" )
  local count=${#snap_lines}
  _sys_info "Found $count disabled revision(s):"
  local line name rev
  for line in "${snap_lines[@]}"; do
    read -r name rev <<<"$line"
    _sys_dim "$name (rev $rev)"
  done

  _sys_blank
  if (( dry_run )); then
    _sys_info "Dry run complete; no Snap revision was removed."
    return 0
  fi
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive snap cleanup requires --yes."
      return 1
    fi
    _sys_confirm "Remove these exact disabled revisions?" || {
      _sys_info "Cancelled."
      return 0
    }
    _sys_blank
  fi

  _sys_remove_disabled_snap_revisions "$disabled_snaps" || return 1
  _sys_success "Disabled snap revisions cleaned."
}

clean-system-quick() {
  _sys_clean_system_main quick "$@"
}

clean-system-deep() {
  _sys_clean_system_main deep "$@"
}

clean-system() {
  local mode="" assume_yes=0 dry_run=0 choice

  while (( $# )); do
    case "$1" in
      --quick)
        [[ -z "$mode" || "$mode" == "quick" ]] || {
          _sys_error "Choose exactly one cleanup mode."
          return 2
        }
        mode="quick"
        ;;
      --deep)
        [[ -z "$mode" || "$mode" == "deep" ]] || {
          _sys_error "Choose exactly one cleanup mode."
          return 2
        }
        mode="deep"
        ;;
      --yes|-y) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      --help|-h)
        (( $# == 1 && ! assume_yes && ! dry_run )) \
          && [[ -z "$mode" ]] || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        cat >&2 <<'EOF'
Usage: clean-system [--quick|--deep] [--dry-run] [-y|--yes] [-h|--help]

Modes:
  --quick   Fast cleanup for common caches, logs, and temp files
  --deep    Quick cleanup plus slower package/runtime cleanup

Without a mode, an interactive shell will prompt you to choose.
EOF
        return 0 ;;
      *)
        _sys_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  if [[ -z "$mode" ]]; then
    if [[ -t 0 && -t 2 ]]; then
      _sys_header "System Cleanup"
      _sys_info "Choose a cleanup mode:"
      _sys_dim "  1) quick — common caches, journal, thumbnails, temp files"
      _sys_dim "  2) deep  — quick + Homebrew, Rust, and Go caches"
      _sys_blank
      if _sys_color_enabled; then
        printf "\033[1;33m? Select mode [1/2/c]: \033[0m" >&2
      else
        printf "? Select mode [1/2/c]: " >&2
      fi
      read -r choice
      case "${choice:l}" in
        1|quick)   mode="quick" ;;
        2|d|deep)  mode="deep" ;;
        *) _sys_info "Cancelled."; return 0 ;;
      esac
      _sys_blank
    else
      _sys_error "Non-interactive cleanup requires --quick or --deep."
      return 2
    fi
  fi

  local -a forwarded_args=()
  (( assume_yes )) && forwarded_args+=(--yes)
  (( dry_run )) && forwarded_args+=(--dry-run)
  if [[ "$mode" == "quick" ]]; then
    clean-system-quick "${forwarded_args[@]}"
  else
    clean-system-deep "${forwarded_args[@]}"
  fi
}

typeset -g _SYS_CLEAN_SOURCED=1
