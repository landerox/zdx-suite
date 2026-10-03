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
  _dev_info "Host uv maintenance is owned by sys-menu. Delegating..."
  _dev_delegate_sys update-uv-system || return 1

  _dev_info \
    "Ambient Python and pip were left unchanged; their package manager owns them."
  _dev_success "Host toolchain maintenance completed through sys-menu."
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
      _dev_info "Managed by tfenv."
      _dev_info \
        "The Developer suite does not install or select Terraform versions."
      _dev_info \
        "Review a pinned version, then update it explicitly through tfenv."
      return 0
      ;;
    brew)
      _dev_info "Managed by Homebrew. Update it there: sys-menu update-brew"
      return 0
      ;;
    apt)
      _dev_info "Managed by APT. Update it there: sys-menu update-apt"
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
    _dev_info "Managed by Homebrew. Update it there: sys-menu update-brew"
    return 0
  fi

  _dev_refuse_remote_installer "TFLint" \
    "ZDX could not prove that the active TFLint binary is package-managed." \
    "Install or upgrade it with a verified path:" \
    "  brew install tflint" \
    "Or download the pinned release together with its checksum file:" \
    "  https://github.com/terraform-linters/tflint/releases"
  return 1
}

# --- Full maintenance -------------------------------------------------------

# Runs one aggregate maintenance step and records its outcome in the caller's
# dynamically scoped step_labels, step_outcomes, and failures variables.
_dev_update_all_step() {
  local label="$1"
  local timed_label="$2"
  shift 2

  # After an interrupted step no later step starts; each is listed as not run.
  step_labels+=("$label")
  if (( interrupted_status )); then
    step_outcomes+=("– not run (interrupted)")
    return $interrupted_status
  fi

  local -i step_status=0
  _dev_timed "$timed_label" "$@" || step_status=$?

  if (( step_status == 130 || step_status == 143 )); then
    interrupted_status=$step_status
    step_outcomes+=("✘ interrupted (status $step_status)")
    failures=$(( failures + 1 ))
    return $step_status
  fi
  if (( step_status == 0 )); then
    step_outcomes+=("✔ completed")
  else
    step_outcomes+=("✘ failed (status $step_status)")
    local -a retry_arguments=("${(@)@:#--yes}")
    retry_commands+=("${(j: :)${(@q)retry_arguments}}")
    failures=$(( failures + 1 ))
  fi
  return $step_status
}

# Records a step that was not started, with the reason shown in the summary.
# A blocking reason (an unmet precondition such as an unreachable index)
# counts as a failure; an inapplicable step does not.
_dev_update_all_skip() {
  local label="$1"
  local reason="$2"
  local -i blocking="${3:-0}"

  step_labels+=("$label")
  if (( blocking )); then
    step_outcomes+=("✘ blocked ($reason)")
    [[ -n "${4:-}" ]] && retry_commands+=("$4")
    failures=$(( failures + 1 ))
  else
    step_outcomes+=("⊘ skipped ($reason)")
  fi
}

_dev_update_all_summary() {
  (( ${#step_labels[@]} > 0 )) || return 0

  _dev_header "Maintenance Summary"
  local -i index
  for (( index = 1; index <= ${#step_labels[@]}; index++ )); do
    printf '  %-24s %s\n' \
      "${step_labels[index]}" "${step_outcomes[index]}" >&2
  done
  if (( ${#retry_commands[@]} > 0 )); then
    _dev_info "Retry only the pending steps after resolving the errors above:"
    local retry_command
    for retry_command in "${(@u)retry_commands}"; do
      _dev_dim "  dev-menu $retry_command"
    done
  fi
}

# dev-update-all
#   Arguments: --yes | --dry-run | --help
#   Effects:   freezes the applicable scope, then runs the toolchain,
#              dependency, lockfile, pre-commit, infrastructure, and cleanup
#              steps in order and prints a per-step summary. Interactive
#              cleanup confirms its exact targets immediately before removal.
#              Non-interactive mutation requires --yes.
#   Status:    0 when every step succeeded, 1 when any step failed.
dev-update-all() {
  emulate -L zsh

  local -i auto_yes=0 dry_run=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-update-all [--yes] [--dry-run]"
        print -u2 -r -- \
          "  Run the toolchain, dependency, lockfile, pre-commit, and cleanup steps."
        print -u2 -r -- \
          "  Steps whose project files are absent are reported as skipped."
        print -u2 -r -- \
          "  --dry-run   Preview dependency bumps and the cleanup plan only."
        print -u2 -r -- \
          "  --yes       Authorize aggregate and exact child plans without prompts."
        return 0
        ;;
      --yes|-y)  auto_yes=1 ;;
      --dry-run) dry_run=1 ;;
      *) _dev_error "Unknown option: $1"; return 2 ;;
    esac
    shift
  done

  _dev_header "Full Project Maintenance"

  local total_start
  total_start=$(_dev_now)

  # Dynamically scoped for the step helpers above.
  local -i failures=0 interrupted_status=0
  local -a step_labels=() step_outcomes=() retry_commands=()

  if (( dry_run )); then
    _dev_warn "DRY-RUN — dependency and cleanup steps only preview their plans."
    if [[ -f pyproject.toml ]]; then
      _dev_update_all_step "Dependency preview" "dev:dev-update-deps-dry" \
        dev-update-deps-dry
    else
      _dev_update_all_skip "Dependency preview" "no pyproject.toml"
    fi
    _dev_update_all_step "Cleanup preview" "dev:dev-clean-all" \
      dev-clean-all --dry-run
  else
    # Applicability is frozen once so the displayed plan and the executed
    # steps cannot diverge while the prompt is open.
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

    local -i plan_step=1
    _dev_info "Maintenance plan:"
    _dev_dim \
      "$plan_step. Delegate the host uv update; leave ambient Python and pip unchanged."
    plan_step=$(( plan_step + 1 ))
    if (( has_pyproject && network_ready )); then
      _dev_dim \
        "$plan_step. Plan, back up, and update eligible dependency specifiers."
      plan_step=$(( plan_step + 1 ))
    fi
    if (( has_lockfile )); then
      _dev_dim \
        "$plan_step. Refresh uv.lock to the newest compatible versions and sync."
      plan_step=$(( plan_step + 1 ))
    fi
    if (( has_pyproject && has_hook_config )); then
      _dev_dim \
        "$plan_step. Update and validate the configured pre-commit hooks."
      plan_step=$(( plan_step + 1 ))
    fi
    if (( has_terraform )); then
      _dev_dim \
        "$plan_step. Inspect Terraform ownership and its update workflow."
      plan_step=$(( plan_step + 1 ))
    fi
    if (( has_tflint )); then
      _dev_dim "$plan_step. Report the owning TFLint update workflow."
    fi
    _dev_dim "Final. Preview and remove the exact project cleanup targets."
    if (( ! has_pyproject )); then
      _dev_dim \
        "Not applicable: dependency and pre-commit updates need pyproject.toml."
    elif (( ! has_hook_config )); then
      _dev_dim \
        "Not applicable: the pre-commit update needs .pre-commit-config.yaml."
    fi
    (( has_lockfile )) \
      || _dev_dim "Not applicable: the lockfile refresh needs uv.lock."
    (( network_ready )) || _dev_warn \
      "PyPI is unreachable: specifier queries are blocked; lockfile and hook updates will use their own backends."
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

    # A stale lockfile is the only dependency outcome that must block the
    # pre-commit update: its own lock and sync would build on inconsistent
    # metadata. Every other failure leaves the project files consistent.
    local -i lockfile_trusted=1
    _DEV_UPDATE_DEPS_OUTCOME=""
    if (( ! has_pyproject )); then
      _dev_update_all_skip "Dependency specifiers" "no pyproject.toml"
    elif (( ! network_ready )); then
      _dev_update_all_skip "Dependency specifiers" "PyPI unreachable" 1 \
        dev-update-deps
    else
      _dev_update_all_step "Dependency specifiers" "dev:dev-update-deps" \
        dev-update-deps --yes
      [[ "$_DEV_UPDATE_DEPS_OUTCOME" == "inconsistent" ]] \
        && lockfile_trusted=0
    fi

    if (( ! has_lockfile )); then
      _dev_update_all_skip "Lockfile refresh" "no uv.lock"
    elif _dev_update_all_step "Lockfile refresh" "dev:dev-update-lock" \
      dev-update-lock; then
      lockfile_trusted=1
    fi

    if (( ! has_pyproject )); then
      _dev_update_all_skip "Pre-commit hooks" "no pyproject.toml"
    elif (( ! has_hook_config )); then
      _dev_update_all_skip "Pre-commit hooks" "no .pre-commit-config.yaml"
    elif (( ! lockfile_trusted )); then
      _dev_warn \
        "Skipping dev-update-precommit: dependency publication left the lockfile stale."
      _dev_update_all_skip "Pre-commit hooks" "lockfile may be stale"
    else
      _dev_update_all_step "Pre-commit hooks" "dev:dev-update-precommit" \
        dev-update-precommit
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
  fi

  local total_elapsed
  total_elapsed=$(_dev_elapsed "$total_start")

  _dev_update_all_summary
  _dev_blank
  if (( interrupted_status )); then
    _dev_error \
      "Full maintenance was interrupted (status $interrupted_status); later steps did not run."
    return $interrupted_status
  fi
  if (( failures == 0 )); then
    _dev_success "Full maintenance completed in ${total_elapsed}s."
    return 0
  fi

  _dev_error \
    "$failures step(s) had issues — review the summary above (${total_elapsed}s)."
  if (( failures < ${#step_outcomes[@]} )) \
    && (( ${+functions[_zdx_timed_mark_partial]} )); then
    _zdx_timed_mark_partial || true
  fi
  return 1
}

typeset -g _DEV_UPDATE_SOURCED=1
