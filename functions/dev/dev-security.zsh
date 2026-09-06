#!/usr/bin/env zsh
# =============================================================================
# Dev Security: dependency vulnerability audit and Bandit static analysis
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_SECURITY_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# dev-run-audit
#   Arguments: --fix, --yes, --help
#   Non-interactive: read-only audits are supported; --fix requires --yes.
#   stdout:    the audit tool's own report.
#   Effects:   read-only unless --fix is passed, which upgrades packages.
#   Requires:  pip-audit installed in the project's .venv.
#   Status:    the backend status, 0 on decline, 1 when confirmation is
#              unavailable or a precondition fails, and 2 on bad arguments.
dev-run-audit() {
  emulate -L zsh

  local -i fix=0
  local -i auto_yes=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-run-audit [--fix [--yes]]"
        print -u2 -r -- \
          "  --fix   Attempt automatic remediation by upgrading packages."
        print -u2 -r -- \
          "  --yes   Authorize --fix without asking (validation still runs)."
        return 0
        ;;
      --fix) fix=1 ;;
      --yes|-y) auto_yes=1 ;;
      *)
        _dev_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  if (( auto_yes && ! fix )); then
    _dev_error "--yes is valid only together with --fix."
    return 2
  fi

  _dev_header "Running Dependency Security Audit"
  _dev_require_venv || return 1

  local -a runner=()
  local -a reply=()
  _dev_project_python_tool_runner \
    pip-audit pip_audit "uv add --dev pip-audit" || return 1
  runner=("${reply[@]}")

  if (( fix )); then
    _dev_warn \
      "--fix upgrades vulnerable packages in ${PWD:A}/.venv."
    _dev_info "Planned remediation: pip-audit --fix"

    local -i previous_auto_yes=$_DEV_AUTO_YES
    local confirmation="declined"
    {
      (( auto_yes )) && _DEV_AUTO_YES=1
      confirmation=$(
        _dev_confirm_outcome \
          "Upgrade vulnerable packages in the project virtual environment?"
      )
    } always {
      _DEV_AUTO_YES=$previous_auto_yes
    }

    case "$confirmation" in
      confirmed) ;;
      unavailable)
        _dev_error \
          "Audit remediation needs confirmation; pass --yes with --fix in a non-interactive shell."
        return 1
        ;;
      *)
        _dev_info \
          "Cancelled. The project virtual environment was left unchanged."
        return 0
        ;;
    esac

    runner+=(--fix)
  fi

  _dev_info "Auditing installed packages for known vulnerabilities..."
  "${runner[@]}"
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "No known vulnerabilities found."
  else
    _dev_warn "Vulnerabilities detected (exit status: $exit_code)."
    (( fix )) || _dev_info \
      "Run 'dev-run-audit --fix' to attempt automatic remediation."
  fi
  return $exit_code
}

# dev-run-bandit
#   Arguments: --high-only | --help
#   stdout:    Bandit's own report.
#   Effects:   read-only.
#   Requires:  bandit, or uv with bandit as a dev dependency.
#   Status:    Bandit's status, 0 when no Python files exist, 2 on bad args.
dev-run-bandit() {
  emulate -L zsh

  # Bandit severity: -l (LOW+), -ll (MEDIUM+), -lll (HIGH only).
  # Bandit confidence: -i (LOW+), -ii (MEDIUM+), -iii (HIGH only).
  local severity="l"
  local confidence="i"

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-run-bandit [--high-only]"
        print -u2 -r -- \
          "  --high-only   Report only high severity, high confidence findings."
        return 0
        ;;
      --high-only)
        severity="lll"
        confidence="iii"
        ;;
      *)
        _dev_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  _dev_header "Running Bandit (Static Security Analysis)"
  _dev_validate_scan_depth || return 1

  local -a reply=()
  _dev_project_files 512 '*.py' || return $?
  local -a python_files=("${reply[@]}")

  if (( ${#python_files[@]} == 0 )); then
    _dev_info "No Python files found in this project."
    return 0
  fi

  reply=()
  _dev_python_tool_runner bandit "uv add --dev bandit" || return 1
  local -a runner=("${reply[@]}")

  _dev_info "Scanning ${#python_files[@]} Python file(s) for security issues..."
  local -i exit_code=0 batch_status=0 offset=1
  local -a batch=()
  while (( offset <= ${#python_files[@]} )); do
    batch=("${python_files[@][$offset,$(( offset + 63 ))]}")
    "${runner[@]}" "-${severity}" "-${confidence}" --format txt -- \
      "${batch[@]}"
    batch_status=$?
    (( batch_status != 0 && exit_code == 0 )) && exit_code=$batch_status
    offset=$(( offset + 64 ))
  done

  if (( exit_code == 0 )); then
    _dev_success "Bandit: no security issues found."
  else
    _dev_warn "Bandit found issues (exit status: $exit_code)."
  fi
  return $exit_code
}

typeset -g _DEV_SECURITY_SOURCED=1
