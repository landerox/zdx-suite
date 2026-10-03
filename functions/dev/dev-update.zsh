#!/usr/bin/env zsh
# =============================================================================
# Dev Update: toolchain delegation, ownership reports, and full maintenance
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh, dev-update-deps.zsh, and
# dev-update-precommit.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_UPDATE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Toolchain --------------------------------------------------------------

# dev-update-toolchain
#   Arguments: --help only.
#   Effects:   delegates the host uv lifecycle to its owning suite. Ambient
#              Python and pip installations are never mutated.
#   Status:    0 when the owner completed, 1 when delegation failed.
dev-update-toolchain() {
  emulate -L zsh

  local REPLY
  _dev_parse_no_arguments dev-update-toolchain "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-update-toolchain"
    print -u2 -r -- \
      "  Delegate the host uv update to sys-menu; leave ambient pip unchanged."
    return 0
  fi

  _dev_header "Updating Host Toolchain"
  _dev_note "Host uv maintenance is owned by sys-menu. Delegating..."
  _dev_delegate_sys update-uv-system || return 1

  _dev_note \
    "Ambient Python and pip were left unchanged; their package manager owns them."
  # The System owner reports uv's version evidence to an enclosing step.
  _dev_step_reported || _dev_report_result done "" \
    "Host toolchain maintenance completed through sys-menu."
}

# --- Terraform and TFLint ---------------------------------------------------

# dev-update-terraform
#   Arguments: --help only.
#   Effects:   reports the detected version or package manager without changing
#              the active Terraform version or installing remote code.
dev-update-terraform() {
  emulate -L zsh

  local REPLY
  _dev_parse_no_arguments dev-update-terraform "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-update-terraform"
    print -u2 -r -- \
      "  Inspect Terraform's owner and report its update workflow."
    return 0
  fi

  _dev_header "Inspecting Terraform Update Ownership"
  _dev_require_command terraform || return 1

  local manager
  manager=$(_dev_detect_terraform_manager 2>/dev/null)

  case "$manager" in
    tfenv)
      _dev_note \
        "The Developer suite does not install or select Terraform versions."
      _dev_report_result delegated "tfenv → review a pinned version" \
        "Managed by tfenv. Review a pinned version, then update it explicitly through tfenv."
      return 0
      ;;
    brew)
      _dev_report_result delegated "Homebrew → sys-menu update-brew" \
        "Managed by Homebrew. Update it there: sys-menu update-brew"
      return 0
      ;;
    apt)
      _dev_report_result delegated "APT → sys-menu update-apt" \
        "Managed by APT. Update it there: sys-menu update-apt"
      return 0
      ;;
  esac

  _dev_warn "Terraform appears to be installed manually."
  local resolved
  resolved=$(_dev_terraform_resolved_path 2>/dev/null) \
    && _dev_info "Current binary: $resolved"
  _dev_info "For reproducible updates, install Terraform through tfenv."
  _dev_info \
    "Manual procedure: https://developer.hashicorp.com/terraform/install"
  _dev_report_result skipped "installed manually; no update owner"
  return 0
}

# dev-update-tflint
#   Effects:   reports the owning host workflow. It never mutates Homebrew and
#              refuses to run the upstream shell installer.
dev-update-tflint() {
  emulate -L zsh

  local REPLY
  _dev_parse_no_arguments dev-update-tflint "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-update-tflint"
    print -u2 -r -- \
      "  Report TFLint's host owner or print the verified procedure."
    return 0
  fi

  _dev_header "Inspecting TFLint Update Ownership"
  _dev_require_command tflint || return 1

  local manager=""
  manager=$(_dev_detect_tflint_manager 2>/dev/null)
  if [[ "$manager" == "brew" ]]; then
    _dev_report_result delegated "Homebrew → sys-menu update-brew" \
      "Managed by Homebrew. Update it there: sys-menu update-brew"
    return 0
  fi

  _dev_refuse_remote_installer "TFLint" \
    "ZDX could not prove that the active TFLint binary is package-managed." \
    "Install or upgrade it with a verified path:" \
    "  brew install tflint" \
    "Or download the pinned release together with its checksum file:" \
    "  https://github.com/terraform-linters/tflint/releases"
  _dev_report_result blocked "no verified update path"
  return 1
}

# --- Full maintenance -------------------------------------------------------

# Runs one planned maintenance step as an output-spec step and records it in
# the caller's dynamically scoped step_index, step_total, summary_records,
# failed_labels, retry_commands, failures, and interrupted_status.
# Usage: _dev_update_all_step <label> <telemetry-label> <command> [args...]
_dev_update_all_step() {
  local label="$1"
  local timed_label="$2"
  shift 2
  (( ++step_index ))

  # After an interrupted step no later step starts; each is listed as not run.
  if (( interrupted_status )); then
    summary_records+=("$label"$'\tnot-run\t\tmaintenance interrupted')
    return $interrupted_status
  fi

  _dev_step_banner "$step_index" "$step_total" "$label"
  local -a reply=()
  local -i step_status=0
  _dev_step_exec _dev_timed "$timed_label" "$@" || step_status=$?
  local outcome="${reply[1]:-done}" detail="${reply[2]:-}"
  local seconds="${reply[3]:-}"
  _dev_step_result "$step_index" "$step_total" "$label" "$outcome" \
    "$detail" "$seconds"
  summary_records+=("$label"$'\t'"$outcome"$'\t'"$seconds"$'\t'"$detail")
  (( step_status == 0 )) && return 0

  failures=$(( failures + 1 ))
  local REPLY
  _dev_duration_label "${seconds:-0}"
  if [[ -n "$detail" && "$detail" != "status $step_status" ]]; then
    failed_labels+=("$label — $detail ($REPLY)")
  else
    failed_labels+=("$label ($REPLY)")
  fi
  if (( step_status == 130 || step_status == 143 )); then
    interrupted_status=$step_status
    return $step_status
  fi
  local -a retry_arguments=("${(@)@:#--yes}")
  retry_commands+=("${(j: :)${(@q)retry_arguments}}")
  return $step_status
}

# Records a planned step that an earlier result made unsafe to start. It keeps
# its number, so the banners, result lines, and summary still agree.
# Usage: _dev_update_all_skip_planned <label> <reason>
_dev_update_all_skip_planned() {
  local label="$1"
  local reason="$2"
  (( ++step_index ))
  if (( interrupted_status )); then
    summary_records+=("$label"$'\tnot-run\t\tmaintenance interrupted')
    return 0
  fi
  _dev_step_result "$step_index" "$step_total" "$label" skipped "$reason" ""
  summary_records+=("$label"$'\tskipped\t\t'"$reason")
}

# Prints the summary table, verdict, failed steps, and retry commands. A dry
# run counts its previews.
# Usage: _dev_update_all_report <counted-steps> [run|dry-run]
_dev_update_all_report() {
  local -i total="${1:-0}"
  local subject="Full maintenance" noun="step"
  [[ "${2:-run}" == dry-run ]] && subject="Full maintenance dry run" noun="preview"
  (( ${#summary_records[@]} > 0 )) \
    && _dev_print_step_summary "Maintenance Summary" "${summary_records[@]}"

  local REPLY
  _dev_count_noun "$total" "$noun"
  local steps_label="$REPLY"
  if (( interrupted_status )); then
    _dev_error \
      "Full maintenance was interrupted (status $interrupted_status); later steps did not run."
    return $interrupted_status
  fi
  if (( failures == 0 )); then
    _dev_success "$subject completed: $total of $steps_label succeeded."
    return 0
  fi
  if (( failures < total )); then
    _dev_error \
      "$subject completed with partial failures: $failures of $steps_label failed."
    if (( ${+functions[_zdx_timed_mark_partial]} )); then
      _zdx_timed_mark_partial || true
    fi
  elif (( total == 1 )); then
    _dev_error "$subject failed: the only $noun failed."
  else
    _dev_error "$subject failed: all $steps_label failed."
  fi
  local failed_label
  for failed_label in "${failed_labels[@]}"; do
    _dev_dim "• $failed_label"
  done
  if (( ${#retry_commands[@]} > 0 )); then
    _dev_info "Retry only the failed steps after resolving the errors above:"
    local retry_command
    for retry_command in "${(@u)retry_commands}"; do
      _dev_dim "dev-menu $retry_command"
    done
  fi
  return 1
}

# dev-update-all
#   Arguments: --yes | --dry-run | --verbose | --help
#   Effects:   freezes the applicable scope, then runs the toolchain,
#              dependency, lockfile, pre-commit, infrastructure, and cleanup
#              steps in order and prints a per-step summary. Interactive
#              cleanup confirms its exact targets immediately before removal.
#              Non-interactive mutation requires --yes.
#   Status:    0 when every step succeeded, 1 when any step failed or was
#              blocked, or the status of an interrupted step.
dev-update-all() {
  emulate -L zsh

  local -i auto_yes=0 dry_run=0 verbose=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-update-all [--yes] [--dry-run] [--verbose]"
        print -u2 -r -- \
          "  Run the toolchain, dependency, lockfile, pre-commit, and cleanup steps."
        print -u2 -r -- \
          "  Steps whose project files are absent are listed as not applicable."
        print -u2 -r -- \
          "  --dry-run   Preview dependency bumps and the cleanup plan only."
        print -u2 -r -- \
          "  --yes       Authorize aggregate and exact child plans without prompts."
        print -u2 -r -- \
          "  --verbose   Stream each tool's output and show policy notes."
        return 0
        ;;
      --yes|-y)     auto_yes=1 ;;
      --dry-run)    dry_run=1 ;;
      --verbose|-v) verbose=1 ;;
      *) _dev_error "Unknown option: $1"; return 2 ;;
    esac
    shift
  done

  # --verbose streams captured tool output and policy notes for this run only.
  local ZDX_VERBOSE="${ZDX_VERBOSE:-}"
  (( verbose )) && ZDX_VERBOSE=1

  _dev_header "Full Project Maintenance"

  # Dynamically scoped for the step helpers above.
  local -i failures=0 interrupted_status=0 step_index=0 step_total=0
  local -a summary_records=() failed_labels=() retry_commands=()

  if (( dry_run )); then
    _dev_warn "DRY-RUN — dependency and cleanup steps only preview their plans."
    local -i has_pyproject=0
    [[ -f pyproject.toml ]] && has_pyproject=1
    step_total=$(( has_pyproject + 1 ))
    if (( has_pyproject )); then
      _dev_update_all_step "Dependency preview" "dev:dev-update-deps-dry" \
        dev-update-deps-dry
    else
      summary_records+=("Dependency preview"$'\tskipped\t\tno pyproject.toml')
    fi
    _dev_update_all_step "Cleanup preview" "dev:dev-clean-all" \
      dev-clean-all --dry-run
    _dev_update_all_report "$step_total" dry-run
    return $?
  fi

  # Applicability is frozen once so the displayed plan and the executed steps
  # cannot diverge while the prompt is open.
  local -i has_pyproject=0 has_lockfile=0 has_hook_config=0
  local -i has_terraform=0 has_tflint=0
  [[ -f "pyproject.toml" ]] && has_pyproject=1
  [[ -f "uv.lock" ]] && has_lockfile=1
  [[ -f ".pre-commit-config.yaml" ]] && has_hook_config=1
  command -v terraform &>/dev/null && has_terraform=1
  command -v tflint &>/dev/null && has_tflint=1

  # Only specifier queries require public PyPI. uv may use another index or
  # cached packages, and hook repositories have independent endpoints.
  local -i network_ready=1
  local _DEV_UPDATE_PYPI_STATUS=""
  if (( has_pyproject )); then
    _dev_info "Checking PyPI reachability for package specifier queries..."
    _dev_pypi_check_connectivity || network_ready=0
    _DEV_UPDATE_PYPI_STATUS=$(( ! network_ready ))
  fi

  # Numbered rows are the steps that will start; the others explain why a
  # step does not apply or cannot start.
  local -a plan_rows=() unplanned_rows=()
  local -i blocked_steps=0
  plan_rows+=("Host toolchain"$'\t'"Delegate uv to sys-menu; ambient Python and pip stay unchanged.")
  if (( ! has_pyproject )); then
    unplanned_rows+=($'⊘\tDependency specifiers\tnot applicable (no pyproject.toml)')
  elif (( ! network_ready )); then
    unplanned_rows+=($'✘\tDependency specifiers\tblocked (PyPI unreachable)')
    blocked_steps=1
  else
    plan_rows+=("Dependency specifiers"$'\t'"Plan, back up, and bump eligible specifiers.")
  fi
  if (( has_lockfile )); then
    plan_rows+=("Lockfile refresh"$'\t'"Upgrade uv.lock and sync the environment.")
  else
    unplanned_rows+=($'⊘\tLockfile refresh\tnot applicable (no uv.lock)')
  fi
  if (( ! has_pyproject )); then
    unplanned_rows+=($'⊘\tPre-commit hooks\tnot applicable (no pyproject.toml)')
  elif (( ! has_hook_config )); then
    unplanned_rows+=($'⊘\tPre-commit hooks\tnot applicable (no .pre-commit-config.yaml)')
  else
    plan_rows+=("Pre-commit hooks"$'\t'"Update, validate, and install frozen hook revisions.")
  fi
  (( has_terraform )) \
    && plan_rows+=("Terraform ownership"$'\t'"Report Terraform's owner and update workflow.")
  (( has_tflint )) \
    && plan_rows+=("TFLint ownership"$'\t'"Report TFLint's owner and update workflow.")
  plan_rows+=("Project cleanup"$'\t'"Preview and remove the exact cleanup targets.")
  step_total=${#plan_rows[@]}

  local -a numbered_rows=()
  local -i plan_index=0
  for (( plan_index = 1; plan_index <= step_total; plan_index++ )); do
    numbered_rows+=("$plan_index"$'\t'"${plan_rows[plan_index]}")
  done
  _dev_table $'#\tStep\tAction' "${numbered_rows[@]}" "${unplanned_rows[@]}"
  (( network_ready )) || _dev_warn \
    "PyPI is unreachable: specifier queries are blocked; lockfile and hook updates use their own backends."
  _dev_warn \
    "This workflow changes toolchains, project files, hooks, and cleanup targets."

  local -i previous_auto_yes=$_DEV_AUTO_YES
  local maintenance_outcome="declined"
  {
    (( auto_yes )) && _DEV_AUTO_YES=1
    maintenance_outcome=$(_dev_confirm_outcome \
      "Execute this full maintenance plan?")
  } always {
    _DEV_AUTO_YES=$previous_auto_yes
  }

  case "$maintenance_outcome" in
    confirmed) ;;
    unavailable)
      _dev_error \
        "Full maintenance needs confirmation; pass --yes in a non-interactive shell."
      return 1
      ;;
    *)
      _dev_info "Cancelled. No maintenance step was started."
      return 0
      ;;
  esac

  _dev_update_all_step "Host toolchain" "dev:dev-update-toolchain" \
    dev-update-toolchain

  if (( blocked_steps )); then
    summary_records+=($'Dependency specifiers\tblocked\t\tPyPI unreachable')
    failed_labels+=("Dependency specifiers — PyPI unreachable")
    retry_commands+=("dev-update-deps")
    failures=$(( failures + 1 ))
  fi

  # A stale lockfile is the only dependency outcome that must block the
  # pre-commit update: its own lock and sync would build on inconsistent
  # metadata. Every other failure leaves the project files consistent. Steps
  # that do not apply stay in the summary as skipped, in pipeline order.
  local -i lockfile_trusted=1
  _DEV_UPDATE_DEPS_OUTCOME=""
  if (( ! has_pyproject )); then
    summary_records+=($'Dependency specifiers\tskipped\t\tno pyproject.toml')
  elif (( network_ready )); then
    _dev_update_all_step "Dependency specifiers" "dev:dev-update-deps" \
      dev-update-deps --yes
    [[ "$_DEV_UPDATE_DEPS_OUTCOME" == "inconsistent" ]] \
      && lockfile_trusted=0
  fi

  if (( has_lockfile )); then
    _dev_update_all_step "Lockfile refresh" "dev:dev-update-lock" \
      dev-update-lock && lockfile_trusted=1
  else
    summary_records+=($'Lockfile refresh\tskipped\t\tno uv.lock')
  fi

  if (( ! has_pyproject )); then
    summary_records+=($'Pre-commit hooks\tskipped\t\tno pyproject.toml')
  elif (( ! has_hook_config )); then
    summary_records+=($'Pre-commit hooks\tskipped\t\tno .pre-commit-config.yaml')
  elif (( lockfile_trusted )); then
    _dev_update_all_step "Pre-commit hooks" "dev:dev-update-precommit" \
      dev-update-precommit
  else
    _dev_warn \
      "Skipping dev-update-precommit: dependency publication left the lockfile stale."
    _dev_update_all_skip_planned "Pre-commit hooks" "lockfile may be stale"
  fi

  if (( has_terraform )); then
    _dev_update_all_step "Terraform ownership" "dev:dev-update-terraform" \
      dev-update-terraform
  fi
  if (( has_tflint )); then
    _dev_update_all_step "TFLint ownership" "dev:dev-update-tflint" \
      dev-update-tflint
  fi

  local -a cleanup_arguments=()
  (( auto_yes )) && cleanup_arguments=(--yes)
  _dev_update_all_step "Project cleanup" "dev:dev-clean-all" \
    dev-clean-all "${cleanup_arguments[@]}"

  _dev_update_all_report "$(( step_total + blocked_steps ))"
}

typeset -g _DEV_UPDATE_SOURCED=1
