#!/usr/bin/env zsh
# =============================================================================
# Dev Suite: public loader and command router
# =============================================================================
#
# Public loader and command router for project maintenance workflows.
# Usage: dev-menu [subcommand]
#

if [[ -n "${_DEV_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _dev_menu_loader_dir="${${(%):-%x}:A:h}"

_dev_menu_source_module() {
  local module_name="$1"
  local module_file="${_dev_menu_loader_dir}/dev/${module_name}"
  [[ "$module_name" == "dev-common.zsh" ]] \
    && module_file="${_dev_menu_loader_dir}/dev-common.zsh"

  local resolved_path="${module_file:A}"
  [[ ! -L "$module_file" \
    && -f "$module_file" \
    && -r "$module_file" \
    && "$resolved_path" == "$module_file" ]] || return 1

  builtin source "$module_file"
}

# --- Load common helpers first ----------------------------------------------

typeset -i _dev_menu_load_rc=0
_dev_menu_source_module "dev-common.zsh" || _dev_menu_load_rc=$?
if (( _dev_menu_load_rc != 0 )); then
  print -u2 -r -- "dev-menu.zsh: failed to load dev-common.zsh"
  {
    return $_dev_menu_load_rc 2>/dev/null || exit $_dev_menu_load_rc
  } always {
    unset -f _dev_menu_source_module
    unset _dev_menu_load_rc _dev_menu_loader_dir
  }
fi

# --- Load feature modules ---------------------------------------------------
# Order is explicit: state and report primitives first, then the update
# transaction and specifier helpers before the update workflows that consume
# them.

typeset _dev_menu_module
for _dev_menu_module in \
  dev-state.zsh \
  dev-report.zsh \
  dev-pypi.zsh \
  dev-update-transaction.zsh \
  dev-update-specifiers.zsh \
  dev-update-deps.zsh \
  dev-update-precommit.zsh \
  dev-update-actions.zsh \
  dev-update-python.zsh \
  dev-update.zsh \
  dev-checks.zsh \
  dev-security.zsh \
  dev-clean.zsh; do
  _dev_menu_load_rc=0
  _dev_menu_source_module "$_dev_menu_module" || _dev_menu_load_rc=$?
  if (( _dev_menu_load_rc != 0 )); then
    print -u2 -r -- "dev-menu.zsh: failed to load ${_dev_menu_module}"
    {
      return $_dev_menu_load_rc 2>/dev/null || exit $_dev_menu_load_rc
    } always {
      unset -f _dev_menu_source_module
      unset _dev_menu_load_rc _dev_menu_loader_dir _dev_menu_module
    }
  fi
done

unset -f _dev_menu_source_module
unset _dev_menu_load_rc _dev_menu_module _dev_menu_loader_dir

# =============================================================================
# DEV MENU
# =============================================================================

_dev_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  dev-menu"
  print -u2 -r -- "  dev-menu <subcommand> [arguments...]"
  print -u2 -r -- "  dev-menu --multi"
  print -u2 -r -- "  dev-menu --help"
  print -u2 -r -- ""
  print -u2 -r -- "Inspection:"
  print -u2 -r -- "  dev-check-health, dev-check-outdated"
  print -u2 -r -- ""
  print -u2 -r -- "Quality gates:"
  print -u2 -r -- \
    "  dev-check-types, dev-run-ruff, dev-run-shellcheck, dev-run-markdownlint,"
  print -u2 -r -- \
    "  dev-run-tflint, dev-run-ruff-format, dev-run-hooks, dev-run-all-checks"
  print -u2 -r -- ""
  print -u2 -r -- "Tests:"
  print -u2 -r -- "  dev-run-tests, dev-run-coverage"
  print -u2 -r -- ""
  print -u2 -r -- "Security:"
  print -u2 -r -- "  dev-run-audit, dev-run-bandit"
  print -u2 -r -- ""
  print -u2 -r -- "Dependencies and toolchain:"
  print -u2 -r -- \
    "  dev-update-deps, dev-update-lock, dev-update-precommit, dev-update-actions,"
  print -u2 -r -- \
    "  dev-update-python, dev-update-terraform, dev-update-tflint"
  print -u2 -r -- ""
  print -u2 -r -- "Destructive maintenance:"
  print -u2 -r -- \
    "  dev-clean-py, dev-clean-terraform, dev-clean-all, dev-update-all"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Arguments after a subcommand are forwarded unchanged to that command."
  print -u2 -r -- \
    "Use '<subcommand> --help' for command-specific modes and safety flags."
  print -u2 -r -- \
    "--multi exposes only independent batch-eligible tasks."
  print -u2 -r -- \
    "Eligible gates can execute project code or create documented artifacts."
  print -u2 -r -- \
    "Every cleanup workflow supports --dry-run and --yes."
  print -u2 -r -- \
    "Remote installers are refused; uvx/npx need DEV_ALLOW_EPHEMERAL=1."
  print -u2 -r -- \
    "Python environments and runtimes are managed through py-menu."
}

# stdout records: label|command|description
_dev_menu_rows() {
  # Dynamically scoped for requirement helpers and discarded after this
  # snapshot so a later render observes PATH and project changes.
  local -A _dev_menu_probe_cache=()

  _dev_menu_section \
    "Inspection" "Read-only project diagnostics." || return $?
  _dev_menu_entry \
    "Inspect Python Project Health" "dev-check-health" \
    "Diagnose Python environment, lockfile, hooks, and toolchain state." \
    || return $?
  _dev_menu_entry \
    "List Outdated Dependencies" "dev-check-outdated" \
    "Find newer releases of the project's installed direct dependencies." \
    || return $?

  _dev_menu_section \
    "Quality Gates" \
    "Linters, formatters, type checkers, and configured hooks." || return $?
  _dev_menu_entry \
    "Check Types" "dev-check-types" \
    "Detect and run the configured type checkers (ty and pyright)." \
    || return $?
  _dev_menu_entry \
    "Lint With Ruff" "dev-run-ruff" \
    "Run the Ruff linter without modifying any file." || return $?
  _dev_menu_entry \
    "Lint Shell Scripts" "dev-run-shellcheck" \
    "Run ShellCheck on sh and bash files and parse .zsh with zsh -n." \
    || return $?
  _dev_menu_entry \
    "Lint Markdown" "dev-run-markdownlint" \
    "Check Markdown style; rewriting requires the explicit --fix flag." \
    || return $?
  _dev_menu_entry \
    "Lint Terraform" "dev-run-tflint" \
    "Lint recursively; plugin initialization requires --init and confirmation." \
    || return $?
  _dev_menu_entry \
    "Format With Ruff" "dev-run-ruff-format" \
    "Rewrite Python files in place using the Ruff formatter." || return $?
  _dev_menu_entry \
    "Run Pre-commit Hooks" "dev-run-hooks" \
    "Execute project-controlled hooks; they may initialize tools and rewrite files." \
    || return $?
  _dev_menu_entry \
    "Run All Checks" "dev-run-all-checks" \
    "Run every gate; project hooks may execute code and rewrite files." \
    || return $?

  _dev_menu_section \
    "Tests" "Test execution and coverage reporting." || return $?
  _dev_menu_entry \
    "Run Tests" "dev-run-tests" \
    "Run the project's configured pytest suite." || return $?
  _dev_menu_entry \
    "Run Tests With Coverage" "dev-run-coverage" \
    "Run pytest with the project's coverage backend and a summary." \
    || return $?

  _dev_menu_section \
    "Security" "Vulnerability and static security analysis." || return $?
  _dev_menu_entry \
    "Audit Dependencies" "dev-run-audit" \
    "Check installed packages against known vulnerability advisories." \
    || return $?
  _dev_menu_entry \
    "Scan Code With Bandit" "dev-run-bandit" \
    "Run Bandit static analysis over the project's Python sources." \
    || return $?

  _dev_menu_section \
    "Dependencies and Tools" \
    "Update project dependencies, hooks, and development tools." || return $?
  _dev_menu_entry \
    "Update Project Dependencies" "dev-update-deps" \
    "Preview, then raise minimum versions in pyproject.toml after backup and confirmation." \
    || return $?
  _dev_menu_entry \
    "Update Lockfile and Environment" "dev-update-lock" \
    "Resolve newer versions in uv.lock and sync the environment without editing pyproject.toml." \
    || return $?
  _dev_menu_entry \
    "Update Pre-commit Hooks" "dev-update-precommit" \
    "Review and update pinned hook versions in .pre-commit-config.yaml." \
    || return $?
  _dev_menu_entry \
    "Update GitHub Actions" "dev-update-actions" \
    "Preview, then pin workflow actions to newer release SHAs after backup and confirmation." \
    || return $?
  _dev_menu_entry \
    "Update Python Runtime" "dev-update-python" \
    "Replace an existing .venv, or delegate runtime selection and installation." \
    || return $?
  _dev_menu_entry \
    "Inspect Terraform Installation" "dev-update-terraform" \
    "Identify how Terraform was installed and show its update route." \
    || return $?
  _dev_menu_entry \
    "Inspect TFLint Installation" "dev-update-tflint" \
    "Identify how TFLint was installed and show its update route." \
    || return $?

  _dev_menu_section \
    "Destructive Maintenance" \
    "Removal and aggregate workflows with a plan and confirmation." \
    || return $?
  _dev_menu_entry \
    "Clean Python Artifacts" "dev-clean-py" \
    "Preview and remove Python caches, coverage, and root build artifacts." \
    || return $?
  _dev_menu_entry \
    "Clean Terraform Artifacts" "dev-clean-terraform" \
    "Preview and remove Terraform caches, plans, and state backups." \
    || return $?
  _dev_menu_entry \
    "Clean Project Artifacts" "dev-clean-all" \
    "Review and remove Python, Terraform, and Cargo artifacts together." \
    || return $?
  _dev_menu_entry \
    "Run Full Maintenance" "dev-update-all" \
    "Update tools, dependencies, lockfile, and hooks, then review project cleanup." \
    || return $?
}

# stdout records: the batch-eligible subset of _dev_menu_rows, retaining only
# sections that contain at least one eligible action.
_dev_menu_batch_rows() {
  local rows_output
  rows_output=$(_dev_menu_rows) || return $?

  local pending_section=""
  local row command_name
  for row in "${(@f)rows_output}"; do
    [[ -n "$row" ]] || continue
    command_name="${${row#*|}%%|*}"

    if [[ "$command_name" == ":" ]]; then
      pending_section="$row"
      continue
    fi

    _dev_command_batch_safe "$command_name" || continue
    if [[ -n "$pending_section" ]]; then
      print -r -- "$pending_section"
      pending_section=""
    fi
    print -r -- "$row"
  done
}

_dev_menu_context() {
  _dev_validate_scan_depth || return 1
  _dev_validate_allow_ephemeral || return 1

  local project="${PWD:t}"
  local -a detected=()

  [[ -f "pyproject.toml" ]] && detected+=("python")
  [[ -f "package.json" ]] && detected+=("node")
  [[ -f "Cargo.toml" ]] && detected+=("rust")
  local -i terraform_probe_status=0
  _dev_project_has_stack_files '*.tf' || terraform_probe_status=$?
  (( terraform_probe_status == 2 )) && return 1
  (( terraform_probe_status == 0 )) && detected+=("terraform")
  (( ${#detected[@]} > 0 )) || detected=("none detected")

  local environment="absent"
  [[ -d ".venv" ]] && environment="present"

  local ephemeral="disabled"
  [[ "$DEV_ALLOW_EPHEMERAL" == "1" ]] && ephemeral="enabled"

  _dev_display_escape "Project: $project"
  _dev_display_escape \
    "Stack: ${(j:,:)detected} | .venv: $environment | Ephemeral runners: $ephemeral"
}

# Runs one selected command through the dispatcher with timing applied once.
_dev_menu_execute() {
  local command_name="$1"

  _dev_info "Executing: $command_name"
  _dev_timed "dev:$command_name" _dev_dispatch "$command_name"
}

# Multi-select runs actions sequentially in the order fzf reported them and
# continues past a failing step so the summary covers the whole batch.
_dev_menu_execute_batch() {
  (( $# > 0 )) || {
    _dev_info "No runnable tasks were selected."
    return 0
  }
  _dev_run_task_batch "Selected Tasks" "$@"
}

_dev_interactive() {
  local -i multi_select="${1:-0}"

  if ! _dev_have_command fzf; then
    _dev_error "fzf is required for the interactive Dev menu."
    _dev_info \
      "Install fzf with your platform package manager, or run a direct subcommand."
    return 1
  fi

  local context
  context=$(_dev_menu_context) || return $?

  local rows_output
  if (( multi_select )); then
    rows_output=$(_dev_menu_batch_rows) || return $?
  else
    rows_output=$(_dev_menu_rows) || return $?
  fi
  local -a menu_rows=("${(@f)rows_output}")

  local -a fzf_options=(--prompt='dev > ' --bind='ctrl-/:toggle-preview')
  local header="$context"
  header+=$'\n''Type to filter | Enter run | Esc cancel | Ctrl-/ details'

  if (( multi_select )); then
    fzf_options+=(--multi --marker='✓' --bind='ctrl-a:select-all,ctrl-d:deselect-all')
    header+=$'\n''Tab mark | Ctrl-A all | Ctrl-D none'
  fi
  fzf_options+=(--header="$header")

  local selected=""
  local -i fzf_status=0
  _dev_fzf_capture "${fzf_options[@]}" \
    < <(printf "%s\n" "${menu_rows[@]}") || fzf_status=$?
  selected="$REPLY"

  if (( fzf_status != 0 )); then
    _dev_fzf_rc_is_cancel "$fzf_status" && return 0
    _dev_error "Unable to open the interactive Dev menu (status $fzf_status)."
    return 1
  fi

  [[ -n "$selected" ]] || return 0

  local snapshot_row=""
  local -i row_in_snapshot=0

  if (( ! multi_select )); then
    # A display row is never trusted: the complete selected record must be one
    # of the rows this invocation rendered before its command field is used.
    for snapshot_row in "${menu_rows[@]}"; do
      if [[ "$snapshot_row" == "$selected" ]]; then
        row_in_snapshot=1
        break
      fi
    done
    (( row_in_snapshot )) || {
      _dev_error "The selected action was not in the menu snapshot."
      return 1
    }

    local command_name="${${selected#*|}%%|*}"
    [[ "$command_name" == ":" ]] && return 0
    _dev_menu_execute "$command_name"
    return $?
  fi

  local -a command_names=()
  local row command_field
  for row in "${(@f)selected}"; do
    [[ -n "$row" ]] || continue
    command_field="${${row#*|}%%|*}"
    [[ -n "$command_field" && "$command_field" != ":" ]] || continue
    if ! _dev_command_batch_safe "$command_field"; then
      _dev_warn \
        "Skipping non-batch-eligible task returned by the selector: $command_field"
      continue
    fi
    row_in_snapshot=0
    for snapshot_row in "${menu_rows[@]}"; do
      if [[ "$snapshot_row" == "$row" ]]; then
        row_in_snapshot=1
        break
      fi
    done
    (( row_in_snapshot )) || {
      _dev_warn \
        "Skipping a selection outside the menu snapshot: $command_field"
      continue
    }
    command_names+=("$command_field")
  done

  _dev_menu_execute_batch "${command_names[@]}"
}

dev-menu() {
  emulate -L zsh

  case "${1:-}" in
    "")
      _dev_interactive 0
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _dev_error "--help accepts no arguments."
        return 2
      }
      _dev_usage
      ;;
    -m|--multi)
      (( $# == 1 )) || {
        _dev_error "${1} accepts no arguments."
        return 2
      }
      _dev_interactive 1
      ;;
    -*)
      _dev_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _dev_timed "dev:$command_name" \
        _dev_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _DEV_MENU_SOURCED=1
