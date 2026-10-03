#!/usr/bin/env zsh
# =============================================================================
# Dev Update Deps: dependency specifier updates and lockfile refresh
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-state.zsh, dev-pypi.zsh,
# dev-update-transaction.zsh, and dev-update-specifiers.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_UPDATE_DEPS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Summary table ----------------------------------------------------------

_dev_print_summary_table() {
  local -a rows=("$@")
  (( ${#rows[@]} > 0 )) || return 0

  _dev_header "Update Summary"

  if _dev_color_enabled; then
    printf '  \033[1;37m%-30s %-14s %-14s %s\033[0m\n' \
      "Package" "Previous" "Latest" "Status" >&2
  else
    printf '  %-30s %-14s %-14s %s\n' \
      "Package" "Previous" "Latest" "Status" >&2
  fi

  local row row_status rest package old_version new_version note label
  for row in "${rows[@]}"; do
    row_status="${row%%|*}"; rest="${row#*|}"
    package="${rest%%|*}";   rest="${rest#*|}"
    old_version="${rest%%|*}"; rest="${rest#*|}"
    new_version="${rest%%|*}"; note="${rest#*|}"

    case "$row_status" in
      updated) label="✔ updated" ;;
      latest)  label="✔ latest" ;;
      failed)  label="✘ failed" ;;
      skipped) label="⊘ skipped" ;;
      *)       label="$row_status" ;;
    esac

    printf '  %-30s %-14s %-14s %s%s\n' \
      "${(V)package}" "${(V)old_version}" "${(V)new_version}" \
      "$label" "${note:+ (${(V)note})}" >&2
  done
  _dev_blank
}

# --- Dependency specifiers --------------------------------------------------

# Outcome of the most recent dev-update-deps invocation, for orchestrators:
#   unchanged     no live project file was modified
#   restored      pyproject.toml was published, the lock failed, and the exact
#                 invocation backup was restored
#   inconsistent  pyproject.toml was published but the lockfile could not be
#                 refreshed and the rollback failed; metadata and lock disagree
#   locked        pyproject.toml and uv.lock were updated, but the environment
#                 sync failed and may be partial
#   applied       metadata, lockfile, and environment were updated
typeset -g _DEV_UPDATE_DEPS_OUTCOME=""

_dev_update_deps_usage() {
  print -u2 -r -- "Usage: dev-update-deps [options]"
  print -u2 -r -- "  --dry-run       Show the planned bumps without writing."
  print -u2 -r -- "  --yes, -y       Apply without the confirmation prompt."
  print -u2 -r -- "  --verbose       Enable debug output for this run."
  print -u2 -r -- "  --major-only    Only apply major version bumps."
  print -u2 -r -- "  --minor-only    Only apply minor version bumps."
  print -u2 -r -- "  --patch-only    Only apply patch version bumps."
}

# dev-update-deps
#   stdout:    none. The plan, summary, and diff go to stderr.
#   Effects:   rewrites pyproject.toml ">=" specifiers after a backup, then
#              re-locks and syncs only the bumped packages.
#   Requires:  uv, curl, python3 3.11+, network access to PyPI.
#   Status:    0 on success or cancellation, 1 on failure, 2 on bad arguments.
dev-update-deps() {
  emulate -L zsh

  _DEV_UPDATE_DEPS_OUTCOME="unchanged"
  local -i dry_run=0 verbose=0 auto_yes=0
  local bump_filter="all"
  local requested_filter=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)     _dev_update_deps_usage; return 0 ;;
      --dry-run)     dry_run=1 ;;
      --verbose)     verbose=1 ;;
      --yes|-y)      auto_yes=1 ;;
      --major-only|--minor-only|--patch-only)
        requested_filter="${${1#--}%-only}"
        if [[ "$bump_filter" != "all" \
          && "$bump_filter" != "$requested_filter" ]]; then
          _dev_error \
            "Choose only one of --major-only, --minor-only, or --patch-only."
          return 2
        fi
        bump_filter="$requested_filter"
        ;;
      *)
        _dev_error "Unknown option: $1"
        _dev_update_deps_usage
        return 2
        ;;
    esac
    shift
  done

  # Job-control noise and a stray spinner must not survive this function, and
  # the INT/TERM handler is scoped so it never lands in the user's shell. A
  # string trap would otherwise resume the function, so it records the signal
  # and every stage below stops before its next effect.
  setopt LOCAL_OPTIONS LOCAL_TRAPS NO_MONITOR
  local -i interrupted=0
  trap '_dev_spinner_stop; interrupted=130' INT
  trap '_dev_spinner_stop; interrupted=143' TERM

  local previous_debug="${DEV_SUITE_DEBUG:-0}"
  local -i previous_auto_yes=$_DEV_AUTO_YES
  local transaction_root=""
  local transaction_root_identity=""
  local transaction_dir=""
  local transaction_dir_identity=""
  local -a reply=()

  {
    (( verbose )) && DEV_SUITE_DEBUG=1
    (( auto_yes )) && _DEV_AUTO_YES=1

    _dev_header "Updating pyproject.toml Specifiers"
    (( dry_run )) && _dev_warn "DRY-RUN — no files will be modified."
    [[ "$bump_filter" != "all" ]] \
      && _dev_info "Filter: --${bump_filter}-only (other bump types are skipped)"

    _dev_require_command uv || return 1
    _dev_require_python_toml || return 1
    _dev_require_file "pyproject.toml" || return 1
    _dev_update_pypi_ready || return 1

    local project_root="${PWD:A}"
    local pyproject_path="${project_root}/pyproject.toml"
    local initial_fingerprint=""
    _dev_update_file_fingerprint "$pyproject_path" || {
      _dev_error \
        "pyproject.toml must be a regular, non-symlink file before it can be updated."
      return 1
    }
    initial_fingerprint="$REPLY"

    _dev_update_workspace_create || return 1
    transaction_root="${reply[1]}"
    transaction_root_identity="${reply[2]}"
    transaction_dir="${reply[3]}"
    transaction_dir_identity="${reply[4]}"

    local original_snapshot="${transaction_dir}/pyproject.toml.original"
    local planned_snapshot="${transaction_dir}/pyproject.toml"
    local snapshot_fingerprint=""
    _dev_update_copy_snapshot \
      "$pyproject_path" "$original_snapshot" "$initial_fingerprint" || {
      _dev_error "Could not snapshot pyproject.toml for planning."
      return 1
    }
    snapshot_fingerprint="$REPLY"
    _dev_update_copy_snapshot \
      "$original_snapshot" "$planned_snapshot" "$snapshot_fingerprint" || {
      _dev_error "Could not create the private pyproject.toml update plan."
      return 1
    }
    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The dependency-update workspace changed during setup."
      return 1
    }

    reply=()
    _dev_pyproject_all_deps || return 1
    local -a all_deps=("${reply[@]}")

    if (( ${#all_deps[@]} == 0 )); then
      _dev_warn "No dependencies declared in pyproject.toml."
      return 0
    fi

    _dev_info \
      "Found ${#all_deps[@]} unique dependency(ies). Querying PyPI..."

    _dev_spinner_start "Fetching versions from PyPI (${#all_deps[@]} packages)"
    _dev_pypi_prefetch "${all_deps[@]}"
    _dev_spinner_stop
    (( interrupted )) && {
      _dev_warn "Interrupted before planning; pyproject.toml was not modified."
      return $interrupted
    }

    local -i updated=0 failed=0 skipped=0 at_latest=0
    local -a summary_rows=() updated_packages=()
    local package row_rest plan_result

    for package in "${all_deps[@]}"; do
      [[ -n "$package" ]] || continue
      (( interrupted )) && {
        _dev_warn "Interrupted during planning; pyproject.toml was not modified."
        return $interrupted
      }

      # Build the proposed file in the private workspace. The live project file
      # is never touched while versions are queried or while authorization is
      # pending.
      _dev_update_workspace_validate \
        "$transaction_root" "$transaction_root_identity" \
        "$transaction_dir" "$transaction_dir_identity" || {
        _dev_error "The dependency-update workspace changed during planning."
        return 1
      }
      plan_result=$(
        builtin cd -- "$transaction_dir" || return 1
        _dev_update_specifier "$package" 0 "$bump_filter" 1
        print -r -- "$_DEV_UPDATE_RESULT"
      ) || plan_result="failed|$package|—|—|planning failed"
      summary_rows+=("$plan_result")

      case "${plan_result%%|*}" in
        updated)
          updated=$(( updated + 1 ))
          row_rest="${plan_result#*|}"
          updated_packages+=("${row_rest%%|*}")
          ;;
        latest)  at_latest=$(( at_latest + 1 )) ;;
        failed)  failed=$(( failed + 1 )) ;;
        skipped) skipped=$(( skipped + 1 )) ;;
      esac
    done

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The dependency-update workspace changed after planning."
      return 1
    }
    local planned_fingerprint=""
    _dev_update_file_fingerprint "$planned_snapshot" || {
      _dev_error "Could not fingerprint the finished dependency update plan."
      return 1
    }
    planned_fingerprint="$REPLY"

    _dev_print_summary_table "${summary_rows[@]}"

    _dev_update_file_fingerprint "$pyproject_path" || {
      _dev_error "Unable to revalidate pyproject.toml after planning."
      return 1
    }
    if [[ "$REPLY" != "$initial_fingerprint" \
      || "${PWD:A}" != "$project_root" ]]; then
      _dev_error \
        "pyproject.toml or the project context changed during planning; refusing to continue."
      return 1
    fi

    if (( dry_run )); then
      if (( updated > 0 )); then
        _dev_success "$updated specifier(s) would be updated."
        _dev_info "Run without --dry-run to apply the changes."
      else
        _dev_success "All specifiers are already at their latest versions."
      fi
      (( failed > 0 )) \
        && _dev_warn "$failed package(s) could not be queried from PyPI."
      (( skipped > 0 )) \
        && _dev_dim "$skipped package(s) skipped (see the notes above)."
      (( failed > 0 )) && return 1
      return 0
    fi

    if (( updated == 0 )); then
      if (( failed > 0 )); then
        _dev_error \
          "No update was applied because $failed package query or plan failed."
        return 1
      fi
      _dev_success "No eligible dependency specifier needs updating."
      (( failed > 0 )) \
        && _dev_warn "$failed package(s) could not be queried from PyPI."
      (( skipped > 0 )) \
        && _dev_dim "$skipped package(s) skipped (see the notes above)."
      return 0
    fi

    (( interrupted )) && {
      _dev_warn "Interrupted during planning; pyproject.toml was not modified."
      return $interrupted
    }
    local apply_outcome
    apply_outcome=$(_dev_confirm_outcome \
      "Apply $updated update(s) to pyproject.toml?")
    case "$apply_outcome" in
      confirmed) ;;
      unavailable)
        _dev_error \
          "Applying updates needs confirmation; pass --yes in a non-interactive shell."
        return 1
        ;;
      *)
        _dev_info "Cancelled. pyproject.toml was never modified."
        return 0
        ;;
    esac

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The dependency-update workspace changed after authorization."
      return 1
    }
    _dev_update_file_fingerprint "$planned_snapshot" || return 1
    if [[ "$REPLY" != "$planned_fingerprint" ]]; then
      _dev_error \
        "The finished dependency update plan changed after authorization."
      return 1
    fi

    _dev_update_file_fingerprint "$pyproject_path" || return 1
    if [[ "$REPLY" != "$initial_fingerprint" \
      || "${PWD:A}" != "$project_root" ]]; then
      _dev_error \
        "pyproject.toml or the project context changed after authorization; refusing to apply."
      return 1
    fi

    _dev_info "Creating an invocation-owned backup of pyproject.toml..."
    reply=()
    _dev_update_prepare_pyproject_backup "$initial_fingerprint" || return 1
    local invocation_backup="${reply[1]}"
    local invocation_backup_fingerprint="${reply[2]}"

    # Backup creation is fallible and can take time. Refuse to publish if the
    # source changed anywhere across that boundary.
    _dev_update_file_fingerprint "$pyproject_path" || return 1
    if [[ "$REPLY" != "$initial_fingerprint" \
      || "${PWD:A}" != "$project_root" ]]; then
      _dev_error \
        "pyproject.toml changed while its backup was created; refusing to apply."
      return 1
    fi
    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The dependency-update workspace changed before publication."
      return 1
    }
    _dev_update_file_fingerprint "$planned_snapshot" || return 1
    if [[ "$REPLY" != "$planned_fingerprint" ]]; then
      _dev_error "The finished dependency update plan changed before publication."
      return 1
    fi

    local applied_fingerprint=""
    if ! _dev_update_publish_snapshot \
      "$planned_snapshot" "$pyproject_path" "$initial_fingerprint" \
      "$planned_fingerprint"; then
      _dev_error "Could not publish the dependency update plan atomically."
      return 1
    fi
    applied_fingerprint="$REPLY"
    _DEV_UPDATE_DEPS_OUTCOME="inconsistent"

    _dev_info "$updated specifier(s) applied to pyproject.toml."
    _dev_info "Changes to pyproject.toml:"
    _dev_show_diff pyproject.toml

    (( failed > 0 )) \
      && _dev_warn "$failed package(s) could not be queried from PyPI."
    (( skipped > 0 )) \
      && _dev_dim "$skipped package(s) skipped (see the notes above)."

    # Re-lock only the packages that changed. A blanket --upgrade churns
    # transitive dependencies and can surface conflicts that existing pins
    # were specifically written to avoid.
    _dev_info "Re-locking ${#updated_packages[@]} package(s) and syncing..."
    local -a upgrade_args=()
    for package in "${updated_packages[@]}"; do
      upgrade_args+=(--upgrade-package "$package")
    done

    # An interruption after publication takes the same exact rollback as a
    # failed lock, then preserves the signal status.
    if (( interrupted )) || ! command uv lock "${upgrade_args[@]}" >&2 \
      || (( interrupted )); then
      if (( interrupted )); then
        _dev_error "Interrupted — attempting an exact pyproject.toml rollback."
      else
        _dev_error "Lock failed — attempting an exact pyproject.toml rollback."
      fi
      if ! _dev_update_rollback_pyproject \
        "$invocation_backup" "$invocation_backup_fingerprint" \
        "$applied_fingerprint" "$initial_fingerprint"; then
        _dev_error "Lock failed and pyproject.toml rollback also failed."
        return $(( interrupted ? interrupted : 1 ))
      fi

      _DEV_UPDATE_DEPS_OUTCOME="restored"
      _dev_warn "pyproject.toml was restored from the exact invocation backup."
      return $(( interrupted ? interrupted : 1 ))
    fi
    _DEV_UPDATE_DEPS_OUTCOME="locked"

    if ! command uv sync --all-groups >&2 || (( interrupted )); then
      _dev_error \
        "Sync failed after the project and lockfile were updated; the environment may be partial."
      return $(( interrupted ? interrupted : 1 ))
    fi
    _DEV_UPDATE_DEPS_OUTCOME="applied"

    if (( failed > 0 )); then
      _dev_warn \
        "Applied $updated update(s), but $failed package query or plan failed."
      return 1
    fi

    _dev_success \
      "Applied $updated dependency update(s) and synchronized the environment."
    return 0
  } always {
    _dev_spinner_stop
    _dev_pypi_cache_cleanup
    _dev_update_workspace_cleanup \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity"
    _DEV_AUTO_YES=$previous_auto_yes
    DEV_SUITE_DEBUG="$previous_debug"
  }
}

# dev-update-deps-dry — read-only preview of dev-update-deps.
#   Exists as a real command so the menu entry maps to a working direct call.
dev-update-deps-dry() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-update-deps-dry [dev-update-deps options...]"
    print -u2 -r -- \
      "  Equivalent to: dev-update-deps --dry-run. Never modifies files."
    return 0
  fi

  dev-update-deps --dry-run "$@"
}

# --- Lockfile ---------------------------------------------------------------

# dev-update-lock
#   Effects:   refreshes uv.lock to the newest resolvable versions and syncs
#              the environment. pyproject.toml is not modified.
dev-update-lock() {
  emulate -L zsh

  local REPLY
  _dev_parse_no_arguments dev-update-lock "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-update-lock"
    print -u2 -r -- \
      "  Refresh uv.lock and sync the environment without editing pyproject."
    return 0
  fi

  _dev_header "Updating uv.lock"
  _dev_require_command uv || return 1
  _dev_require_file "pyproject.toml" || return 1

  _dev_info "Resolving the newest compatible versions..."
  command uv lock --upgrade >&2 || {
    _dev_error "Lock failed."
    return 1
  }

  _dev_info "Syncing the environment..."
  command uv sync --all-groups >&2 || {
    _dev_error "Sync failed."
    return 1
  }

  _dev_success "uv.lock updated and the environment synced."
}

typeset -g _DEV_UPDATE_DEPS_SOURCED=1
