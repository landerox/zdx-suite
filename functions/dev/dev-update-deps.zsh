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

# --- Specifier plan ---------------------------------------------------------

# Prints the planned specifier changes from "status|package|old|new|note" rows.
# Nothing is applied yet, so a bump renders as planned and an unchanged
# specifier as current.
_dev_print_summary_table() {
  local -a rows=("$@") table_rows=()
  (( ${#rows[@]} > 0 )) || return 0

  _dev_header "Specifier Plan"

  local row row_status rest package old_version new_version note outcome
  for row in "${rows[@]}"; do
    row_status="${row%%|*}"; rest="${row#*|}"
    package="${rest%%|*}";   rest="${rest#*|}"
    old_version="${rest%%|*}"; rest="${rest#*|}"
    new_version="${rest%%|*}"; note="${rest#*|}"
    case "$row_status" in
      updated) outcome=planned ;;
      latest)  outcome=current ;;
      failed)  outcome=failed ;;
      *)       outcome=skipped ;;
    esac
    table_rows+=("$package"$'\t'"$old_version"$'\t'"$new_version"$'\t'"$outcome"$'\t'"$note")
  done
  _dev_table --outcome-column 4 $'Package\tPrevious\tLatest\tPlan\tNote' \
    "${table_rows[@]}"
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
    # An enclosing dry-run aggregate has already said so.
    if (( dry_run )) && ! _dev_step_quiet; then
      _dev_warn "DRY-RUN — no files will be modified."
    fi
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

    _dev_count_noun "${#all_deps[@]}" dependency dependencies
    _dev_info "Found $REPLY. Querying PyPI..."

    _dev_count_noun "${#all_deps[@]}" package
    _dev_spinner_start "Fetching versions from PyPI ($REPLY)"
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

    local failed_label="" skipped_label=""
    _dev_count_noun "$failed" package
    failed_label="$REPLY"
    _dev_count_noun "$skipped" package
    skipped_label="$REPLY"

    if (( dry_run )); then
      if (( updated > 0 )); then
        _dev_count_noun "$updated" specifier
        _dev_report_result planned "$REPLY" "$REPLY would be updated."
        _dev_note "Run without --dry-run to apply the changes."
      else
        _dev_report_result current "every specifier at its latest version" \
          "All specifiers are already at their latest versions."
      fi
      (( failed > 0 )) \
        && _dev_warn "$failed_label could not be queried from PyPI."
      (( skipped > 0 )) \
        && _dev_dim "$skipped_label skipped (see the notes above)."
      if (( failed > 0 )); then
        _dev_report_result failed "$failed_label could not be queried"
        return 1
      fi
      return 0
    fi

    if (( updated == 0 )); then
      if (( failed > 0 )); then
        _dev_error \
          "No update was applied: $failed_label could not be queried or planned."
        _dev_report_result failed "$failed_label could not be queried"
        return 1
      fi
      (( skipped > 0 )) \
        && _dev_dim "$skipped_label skipped (see the notes above)."
      _dev_report_result current "no eligible specifier changes" \
        "No eligible dependency specifier needs updating."
      return 0
    fi

    (( interrupted )) && {
      _dev_warn "Interrupted during planning; pyproject.toml was not modified."
      return $interrupted
    }
    local apply_outcome
    _dev_count_noun "$updated" update
    apply_outcome=$(_dev_confirm_outcome \
      "Apply $REPLY to pyproject.toml?")
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

    _dev_count_noun "$updated" specifier
    _dev_info "$REPLY applied to pyproject.toml."
    _dev_info "Changes to pyproject.toml:"
    _dev_show_diff pyproject.toml

    (( failed > 0 )) \
      && _dev_warn "$failed_label could not be queried from PyPI."
    (( skipped > 0 )) \
      && _dev_dim "$skipped_label skipped (see the notes above)."

    # The evidence for the step result: the bumped packages and versions.
    local -a applied_changes=()
    local applied_row applied_rest
    for applied_row in "${summary_rows[@]}"; do
      [[ "${applied_row%%|*}" == updated ]] || continue
      applied_rest="${applied_row#*|}"
      applied_changes+=("${applied_rest%%|*} ${${applied_rest#*|}%%|*} → ${${${applied_rest#*|}#*|}%%|*}")
    done
    local applied_detail="${(j:, :)applied_changes[1,3]}"
    (( ${#applied_changes[@]} > 3 )) && applied_detail+=", …"

    # Re-lock only the packages that changed. A blanket --upgrade churns
    # transitive dependencies and can surface conflicts that existing pins
    # were specifically written to avoid.
    _dev_count_noun "${#updated_packages[@]}" package
    _dev_info "Re-locking $REPLY and syncing..."
    local -a upgrade_args=()
    for package in "${updated_packages[@]}"; do
      upgrade_args+=(--upgrade-package "$package")
    done
    _dev_command_display uv lock "${upgrade_args[@]}"
    local lock_display="$REPLY"

    # An interruption after publication takes the same exact rollback as a
    # failed lock, then preserves the signal status.
    if (( interrupted )) || ! _dev_run_captured "$lock_display" \
      command uv lock "${upgrade_args[@]}" || (( interrupted )); then
      if (( interrupted )); then
        _dev_error "Interrupted — attempting an exact pyproject.toml rollback."
      else
        _dev_error "Lock failed — attempting an exact pyproject.toml rollback."
      fi
      if ! _dev_update_rollback_pyproject \
        "$invocation_backup" "$invocation_backup_fingerprint" \
        "$applied_fingerprint" "$initial_fingerprint"; then
        _dev_error "Lock failed and pyproject.toml rollback also failed."
        _dev_report_result failed "lock failed; pyproject.toml rollback failed"
        return $(( interrupted ? interrupted : 1 ))
      fi

      _DEV_UPDATE_DEPS_OUTCOME="restored"
      _dev_warn "pyproject.toml was restored from the exact invocation backup."
      _dev_report_result failed "lock failed; pyproject.toml restored"
      return $(( interrupted ? interrupted : 1 ))
    fi
    _DEV_UPDATE_DEPS_OUTCOME="locked"

    if ! _dev_run_captured "uv sync --all-groups" \
      command uv sync --all-groups || (( interrupted )); then
      _dev_error \
        "Sync failed after the project and lockfile were updated; the environment may be partial."
      _dev_report_result failed "sync failed; environment may be partial"
      return $(( interrupted ? interrupted : 1 ))
    fi
    _DEV_UPDATE_DEPS_OUTCOME="applied"

    _dev_count_noun "$updated" "dependency update"
    if (( failed > 0 )); then
      _dev_warn "Applied $REPLY, but $failed_label could not be queried or planned."
      _dev_report_result failed "$applied_detail; $failed_label could not be queried"
      return 1
    fi

    _dev_report_result updated "$applied_detail" \
      "Applied $REPLY and synchronized the environment."
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

# Prints "name<TAB>version" records for the packages locked in uv.lock. A
# missing, symlinked, oversized, or unparsable lockfile prints nothing and
# returns 1, so the caller reports the refresh without version evidence.
_dev_update_lock_versions() {
  local lock_file="${1:-uv.lock}"
  [[ -f "$lock_file" && ! -L "$lock_file" ]] || return 1
  command python3 -I - "$lock_file" <<'PY_LOCK_VERSIONS' 2>/dev/null
import os
import sys
import tomllib

MAX_LOCK_SIZE = 16 * 1024 * 1024
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
with os.fdopen(os.open(sys.argv[1], flags), "rb") as handle:
    data = handle.read(MAX_LOCK_SIZE + 1)
if len(data) > MAX_LOCK_SIZE:
    raise SystemExit(1)
document = tomllib.loads(data.decode("utf-8"))
for package in document.get("package", []):
    name = package.get("name")
    version = package.get("version")
    if (
        isinstance(name, str)
        and isinstance(version, str)
        and name.isprintable()
        and version.isprintable()
    ):
        print(f"{name}\t{version}")
PY_LOCK_VERSIONS
}

# Reports a lockfile refresh from the locked versions before and after it.
# Usage: _dev_update_lock_report <versions-known> <before-records>
_dev_update_lock_report() {
  local -i versions_known="${1:-0}"
  local before_records="${2:-}" after_records="" record name REPLY
  if (( ! versions_known )) \
    || ! after_records=$(_dev_update_lock_versions uv.lock); then
    _dev_report_result done "" "uv.lock updated and the environment synced."
    return 0
  fi

  # A package can be locked at several versions for different markers.
  local -A before=() after=()
  for record in "${(@f)before_records}"; do
    [[ -n "$record" ]] || continue
    name="${record%%$'\t'*}"
    before[$name]="${before[$name]:+${before[$name]}, }${record#*$'\t'}"
  done
  for record in "${(@f)after_records}"; do
    [[ -n "$record" ]] || continue
    name="${record%%$'\t'*}"
    after[$name]="${after[$name]:+${after[$name]}, }${record#*$'\t'}"
  done

  local -aU names=("${(@k)before}" "${(@k)after}")
  names=("${(@o)names}")
  local -a rows=() changed=()
  for name in "${names[@]}"; do
    [[ "${before[$name]-}" == "${after[$name]-}" ]] && continue
    changed+=("$name")
    rows+=("$name"$'\t'"${before[$name]:-—}"$'\t'"${after[$name]:-removed}")
  done
  if (( ${#changed[@]} == 0 )); then
    _dev_report_result current "no locked version changed" \
      "uv.lock is already current; the environment was synced."
    return 0
  fi

  _dev_count_noun "${#changed[@]}" package
  local changed_label="$REPLY"
  _dev_info "Locked version changes:"
  _dev_table $'Package\tPrevious\tLocked' "${(@)rows[1,20]}"
  (( ${#rows[@]} > 20 )) && _dev_dim "… and $(( ${#rows[@]} - 20 )) more"
  local preview="${(j:, :)changed[1,3]}"
  (( ${#changed[@]} > 3 )) && preview+=", …"
  _dev_report_result updated "$changed_label ($preview)" \
    "uv.lock updated: $changed_label changed; the environment was synced."
}

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

  # The locked versions are evidence for the result only; an unreadable lock
  # never blocks the refresh.
  local before_versions=""
  local -i versions_known=0
  if command -v python3 &>/dev/null \
    && before_versions=$(_dev_update_lock_versions uv.lock); then
    versions_known=1
  fi

  _dev_run_captured "uv lock --upgrade" command uv lock --upgrade || {
    _dev_error "Lock failed."
    return 1
  }

  _dev_run_captured "uv sync --all-groups" command uv sync --all-groups || {
    _dev_error "Sync failed."
    return 1
  }

  _dev_update_lock_report "$versions_known" "$before_versions"
}

typeset -g _DEV_UPDATE_DEPS_SOURCED=1
