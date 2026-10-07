#!/usr/bin/env zsh
# =============================================================================
# Dev Checks: linters, formatters, type checkers, tests, and project health
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh, dev-state.zsh, dev-report.zsh,
# and dev-pypi.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_CHECKS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Shared option parsing --------------------------------------------------

# Accepts only --report for the inspection commands. Sets the caller's
# _dev_check_opt_report local.
_dev_check_parse_options() {
  local command_name="$1"
  shift

  _dev_check_opt_report=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: $command_name [--report]"
        print -u2 -r -- \
          "  --report   Also write a Markdown report under \$DEV_REPORT_DIR."
        return 3
        ;;
      --report) _dev_check_opt_report=1 ;;
      *)
        _dev_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done
  return 0
}

# --- Outdated dependencies --------------------------------------------------

# dev-check-outdated
#   Arguments: --report | --help
#   stdout:    the `uv pip list --outdated` rows for direct dependencies.
#   Effects:   read-only, plus an optional Markdown report.
#   Requires:  uv, Python 3.11+ (see _dev_python_toml_resolve), and an
#              existing .venv.
#   Status:    0 on success, 1 on unmet preconditions, 2 on bad arguments.
dev-check-outdated() {
  emulate -L zsh
  (( ${+_DEV_RUN_PYTHON} )) || local _DEV_RUN_PYTHON=""

  local REPLY
  local -i _dev_check_opt_report=0
  local -i parse_status=0
  _dev_check_parse_options dev-check-outdated "$@" || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  _dev_header "Checking Outdated Direct Dependencies"
  _dev_require_command uv || return 1
  _dev_require_file "pyproject.toml" || return 1
  _dev_require_venv || return 1

  local -a reply=()
  _dev_pyproject_all_deps || return 1
  local -a direct_deps=("${reply[@]}")

  if (( ${#direct_deps[@]} == 0 )); then
    _dev_warn "No direct dependencies declared in pyproject.toml."
    if (( _dev_check_opt_report )); then
      _dev_report_init "Outdated Dependencies Report"
      _dev_report_section "Outdated Direct Dependencies"
      _dev_report_line "_No direct dependencies are declared._"
      _dev_report_save "outdated.md" || return 1
    fi
    return 0
  fi

  _dev_count_noun "${#direct_deps[@]}" "direct dependency" "direct dependencies"
  _dev_info "Comparing $REPLY..."

  local project_python="${PWD:A}/.venv/bin/python"
  if [[ ! -x "$project_python" ]]; then
    _dev_error "The project virtual environment has no usable Python interpreter."
    _dev_info "Recreate it with: uv sync"
    return 1
  fi

  local outdated_output
  outdated_output=$(UV_SYSTEM_PYTHON=0 command uv pip list \
    --python "$project_python" --outdated --format=columns) || {
    _dev_error "Could not query the project environment for outdated packages."
    return 1
  }

  if [[ -z "$outdated_output" ]]; then
    _dev_success "All installed packages are up to date."
    if (( _dev_check_opt_report )); then
      _dev_report_init "Outdated Dependencies Report"
      _dev_report_section "Outdated Direct Dependencies"
      _dev_report_line "_All installed packages are up to date._"
      _dev_report_save "outdated.md" || return 1
    fi
    return 0
  fi

  (( _dev_check_opt_report )) && {
    _dev_report_init "Outdated Dependencies Report"
    _dev_report_section "Outdated Direct Dependencies"
  }

  local -i found=0
  local dependency normalized matched_row line installed_name
  local installed_normalized
  local -a fields=()
  for dependency in "${direct_deps[@]}"; do
    [[ -n "$dependency" ]] || continue
    normalized=$(_dev_normalize_pkg_name "$dependency") || continue
    matched_row=""
    for line in "${(@f)outdated_output}"; do
      fields=(${=line})
      (( ${#fields[@]} > 0 )) || continue
      installed_name="${fields[1]}"
      installed_normalized=$(
        _dev_normalize_pkg_name "$installed_name" 2>/dev/null
      ) || continue
      if [[ "$installed_normalized" == "$normalized" ]]; then
        matched_row="$line"
        break
      fi
    done
    [[ -n "$matched_row" ]] || continue

    print -r -- "$matched_row"
    found=$(( found + 1 ))
    (( _dev_check_opt_report )) \
      && _dev_report_line "    $(_dev_display_escape "$matched_row")"
  done

  if (( found == 0 )); then
    _dev_success "All direct dependencies are up to date."
    (( _dev_check_opt_report )) \
      && _dev_report_line "_All direct dependencies are up to date._"
  else
    local found_label="direct dependencies have"
    (( found == 1 )) && found_label="direct dependency has"
    _dev_info "$found $found_label newer versions available."
    (( _dev_check_opt_report )) && {
      _dev_report_line ""
      _dev_report_line \
        "**$found** $found_label newer versions available."
    }
  fi

  if (( _dev_check_opt_report )); then
    _dev_report_save "outdated.md" || return 1
  fi
  return 0
}

# --- Project health ---------------------------------------------------------

# Compares simple uv Python requests component by component.
# Status: 0 match, 1 mismatch, 2 unsupported request.
_dev_health_python_pin_matches() {
  emulate -L zsh
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local pin="$1"
  local interpreter_implementation="$2"
  local interpreter_version="$3"

  local requested_implementation=""
  if [[ "$pin" == [A-Za-z][A-Za-z0-9]#-* ]]; then
    requested_implementation="${${pin%%-*}:l}"
    pin="${pin#*-}"
  fi
  if [[ "$pin" != <->.<-> && "$pin" != <->.<->.<-> ]] \
    || [[ "$interpreter_version" != <->.<->.<-> ]]; then
    return 2
  fi
  if [[ -n "$requested_implementation" \
    && "$requested_implementation" != "${interpreter_implementation:l}" ]]; then
    return 1
  fi

  local -a requested_parts=("${(s:.:)pin}")
  local -a actual_parts=("${(s:.:)interpreter_version}")
  [[ "${requested_parts[1]}" == "${actual_parts[1]}" \
    && "${requested_parts[2]}" == "${actual_parts[2]}" ]] || return 1
  if (( ${#requested_parts[@]} == 3 )) \
    && [[ "${requested_parts[3]}" != "${actual_parts[3]}" ]]; then
    return 1
  fi
  return 0
}

# dev-check-health
#   Arguments: --report | --help
#   stdout:    none. Findings go to stderr; the report is written to a file.
#   Scope:     Python/uv projects. Other supported stacks are a clean no-op.
#   Effects:   read-only, plus an optional Markdown report.
#   Status:    0 when no issue is found, 1 when at least one issue is found.
dev-check-health() {
  emulate -L zsh
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  local REPLY
  (( ${+_DEV_RUN_PYTHON} )) || local _DEV_RUN_PYTHON=""

  local -i _dev_check_opt_report=0
  local -i parse_status=0
  _dev_check_parse_options dev-check-health "$@" || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  _dev_header "Python/uv Project Health Check"
  _dev_validate_scan_depth || return 1

  local -i python_project=0
  if [[ -e "pyproject.toml" || -L "pyproject.toml" \
    || -e ".venv" || -L ".venv" \
    || -e "uv.lock" || -L "uv.lock" \
    || -e ".python-version" || -L ".python-version" ]]; then
    python_project=1
  else
    local -i python_probe_status=0
    _dev_project_has_files '*.py' || python_probe_status=$?
    (( python_probe_status == 2 )) && return 1
    (( python_probe_status == 0 )) && python_project=1
  fi
  if (( ! python_project )); then
    _dev_info \
      "No Python or uv project markers found; this health check is not applicable."
    if (( _dev_check_opt_report )); then
      _dev_report_init "Project Health Report"
      _dev_report_section "Summary"
      _dev_report_status info \
        "Not applicable: no Python or uv project markers found"
      _dev_report_save "health.md" || return 1
    fi
    return 0
  fi

  local -i issues=0

  (( _dev_check_opt_report )) && {
    _dev_report_init "Project Health Report"
    _dev_report_section "Core Files"
  }

  local requires_python=""
  local -i pyproject_metadata_valid=0
  local pinned=""
  local -i python_pin_present=0 python_pin_valid=0
  # A missing metadata interpreter is one issue, reported with its remedy
  # under Required Tools rather than as a pyproject.toml parse failure.
  local -i metadata_python_ready=0
  _dev_python_toml_resolve && metadata_python_ready=1

  # 1. pyproject.toml
  if [[ -e "pyproject.toml" || -L "pyproject.toml" ]]; then
    if [[ -L "pyproject.toml" || ! -f "pyproject.toml" \
      || ! -r "pyproject.toml" ]]; then
      _dev_error \
        "pyproject.toml must be a readable, non-symlinked regular file."
      (( _dev_check_opt_report )) && _dev_report_status fail \
        "pyproject.toml is not a safe readable regular file"
      issues=$(( issues + 1 ))
    elif (( ! metadata_python_ready )); then
      _dev_warn \
        "pyproject.toml found but not parsed: no Python 3.11+ with tomllib is available."
      (( _dev_check_opt_report )) && _dev_report_status warn \
        "pyproject.toml not parsed: Python 3.11+ unavailable"
    elif requires_python=$(_dev_pyproject_requires_python); then
      pyproject_metadata_valid=1
      _dev_success "pyproject.toml found."
      (( _dev_check_opt_report )) \
        && _dev_report_status ok "pyproject.toml found and parsed"
    else
      _dev_error "pyproject.toml is present but could not be parsed safely."
      (( _dev_check_opt_report )) \
        && _dev_report_status fail "pyproject.toml could not be parsed safely"
      issues=$(( issues + 1 ))
    fi
  else
    _dev_error "pyproject.toml not found."
    (( _dev_check_opt_report )) \
      && _dev_report_status fail "pyproject.toml not found"
    issues=$(( issues + 1 ))
  fi

  if [[ -e ".python-version" || -L ".python-version" ]]; then
    python_pin_present=1
    if _dev_read_python_pin .python-version; then
      pinned="$REPLY"
      python_pin_valid=1
    else
      (( _dev_check_opt_report )) && _dev_report_status fail \
        ".python-version could not be validated"
      issues=$(( issues + 1 ))
    fi
  fi

  # 2. Virtual environment and interpreter agreement
  if [[ -e ".venv" || -L ".venv" ]] && ! _dev_require_venv quiet; then
    _dev_error \
      ".venv exists but is unsafe, incomplete, or has no usable Python interpreter."
    (( _dev_check_opt_report )) && _dev_report_status fail \
      ".venv is unsafe, incomplete, or unusable"
    issues=$(( issues + 1 ))
  elif [[ -e ".venv" || -L ".venv" ]]; then
    local venv_python="${PWD:A}/.venv/bin/python"
    local venv_version="" venv_identity="" venv_implementation="" venv_full=""
    if [[ ! -x "$venv_python" ]] \
      || ! venv_version=$("$venv_python" --version 2>&1) \
      || ! venv_identity=$("$venv_python" -I -c \
        'import sys; print("%s|%d.%d.%d" % ((sys.implementation.name,) + sys.version_info[:3]))' \
        2>/dev/null) \
      || [[ "$venv_identity" != [a-z0-9]##\|<->.<->.<-> ]]; then
      _dev_error ".venv exists but its Python interpreter is unusable."
      (( _dev_check_opt_report )) && _dev_report_status fail \
        ".venv Python interpreter is missing or unusable"
      issues=$(( issues + 1 ))
    else
      venv_implementation="${venv_identity%%|*}"
      venv_full="${venv_identity#*|}"
      _dev_success ".venv exists ($venv_version)."
      (( _dev_check_opt_report )) \
        && _dev_report_status ok ".venv exists ($venv_version)"

      if (( python_pin_present && python_pin_valid )); then
        _dev_health_python_pin_matches \
          "$pinned" "$venv_implementation" "$venv_full"
        local -i pin_match_status=$?
        case "$pin_match_status" in
          0)
            _dev_success ".python-version ($pinned) matches the venv."
            (( _dev_check_opt_report )) && _dev_report_status ok \
              ".python-version ($pinned) matches the venv"
            ;;
          1)
            _dev_warn \
              ".python-version ($pinned) does not match the venv ($venv_full)."
            (( _dev_check_opt_report )) && _dev_report_status warn \
              ".python-version mismatch: pinned=$pinned venv=$venv_full"
            issues=$(( issues + 1 ))
            ;;
          *)
            _dev_error \
              ".python-version contains an unsupported Python request: $pinned"
            (( _dev_check_opt_report )) && _dev_report_status fail \
              "Unsupported .python-version request: $pinned"
            issues=$(( issues + 1 ))
            ;;
        esac
      fi

      if (( pyproject_metadata_valid )) && [[ -n "$requires_python" ]]; then
        local compatibility
        compatibility=$(REQUIRES_PYTHON="$requires_python" \
          VENV_VERSION="$venv_full" "$venv_python" -I - <<'PY_SPEC' 2>/dev/null
import os
import re


def simple_match(spec_text, version_text):
    """Evaluate plain release clauses; None means the form needs packaging."""
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version_text):
        return None
    version = tuple(int(part) for part in version_text.split("."))

    def padded(values, size):
        return values + (0,) * (size - len(values))

    clauses = [clause.strip() for clause in spec_text.split(",")]
    if not clauses or "" in clauses:
        return None
    for clause in clauses:
        match = re.fullmatch(
            r"(~=|==|!=|<=|>=|<|>)\s*([0-9]+(?:\.[0-9]+)*)(\.\*)?", clause)
        if not match:
            return None
        operator, target_text, wildcard = match.groups()
        target = tuple(int(part) for part in target_text.split("."))
        if wildcard:
            if operator not in ("==", "!="):
                return None
            prefix = padded(version, len(target))[:len(target)]
            satisfied = (prefix == target) == (operator == "==")
        elif operator == "~=":
            if len(target) < 2:
                return None
            size = max(len(version), len(target))
            satisfied = (padded(version, size) >= padded(target, size)
                         and padded(version, len(target))[:len(target) - 1]
                         == target[:-1])
        else:
            size = max(len(version), len(target))
            left, right = padded(version, size), padded(target, size)
            satisfied = {
                "==": left == right, "!=": left != right,
                "<=": left <= right, ">=": left >= right,
                "<": left < right, ">": left > right,
            }[operator]
        if not satisfied:
            return False
    return True


requires_python = os.environ["REQUIRES_PYTHON"]
venv_version = os.environ["VENV_VERSION"]
try:
    from packaging.specifiers import SpecifierSet
    from packaging.version import Version
except ImportError:
    # A fresh environment without dependencies has no packaging module; the
    # common release clauses are still decidable without it.
    result = simple_match(requires_python, venv_version)
    print("unknown" if result is None else ("yes" if result else "no"))
    raise SystemExit

try:
    spec = SpecifierSet(requires_python)
    version = Version(venv_version)
except Exception:
    print("unknown")
else:
    print("yes" if version in spec else "no")
PY_SPEC
        )

        case "$compatibility" in
          yes)
            _dev_success \
              "venv Python $venv_full satisfies requires-python ($requires_python)."
            (( _dev_check_opt_report )) && _dev_report_status ok \
              "Python $venv_full satisfies requires-python ($requires_python)"
            ;;
          no)
            _dev_error \
              "venv Python $venv_full violates requires-python ($requires_python)."
            (( _dev_check_opt_report )) && _dev_report_status fail \
              "Python $venv_full violates requires-python ($requires_python)"
            issues=$(( issues + 1 ))
            ;;
          *)
            _dev_error \
              "Could not validate requires-python inside the isolated .venv."
            _dev_info \
              "Synchronize the project environment and install 'packaging' in it to evaluate this requires-python form."
            (( _dev_check_opt_report )) && _dev_report_status fail \
              "Could not validate requires-python ($requires_python)"
            issues=$(( issues + 1 ))
            ;;
        esac
      fi
    fi
  else
    _dev_warn ".venv not found. Create it with: uv sync"
    (( _dev_check_opt_report )) && _dev_report_status warn ".venv not found"
    issues=$(( issues + 1 ))
  fi

  # 3. Lockfile freshness
  (( _dev_check_opt_report )) && _dev_report_section "Lock and Sync"

  if [[ -e "uv.lock" || -L "uv.lock" ]]; then
    if [[ -L "uv.lock" || ! -f "uv.lock" || ! -r "uv.lock" ]]; then
      _dev_error "uv.lock must be a readable, non-symlinked regular file."
      (( _dev_check_opt_report )) && _dev_report_status fail \
        "uv.lock is not a safe readable regular file"
      issues=$(( issues + 1 ))
    elif ! _dev_have_command uv; then
      _dev_success "uv.lock found."
      (( _dev_check_opt_report )) && _dev_report_status ok "uv.lock found"
      _dev_error "uv is required to validate uv.lock."
      (( _dev_check_opt_report )) \
        && _dev_report_status fail "uv.lock could not be validated without uv"
      issues=$(( issues + 1 ))
    else
      _dev_success "uv.lock found."
      (( _dev_check_opt_report )) && _dev_report_status ok "uv.lock found"
      if command uv lock --check --offline --no-cache >/dev/null 2>&1; then
        _dev_success "uv.lock is current (verified offline without cache writes)."
        (( _dev_check_opt_report )) \
          && _dev_report_status ok "uv.lock is current (offline check)"
      else
        _dev_error \
          "uv.lock failed the offline freshness check. Run: uv lock"
        (( _dev_check_opt_report )) && _dev_report_status fail \
          "uv.lock failed: uv lock --check --offline --no-cache"
        issues=$(( issues + 1 ))
      fi
    fi
  else
    _dev_warn "uv.lock not found. Create it with: uv lock"
    (( _dev_check_opt_report )) && _dev_report_status warn "uv.lock not found"
    issues=$(( issues + 1 ))
  fi

  # 4. Pre-commit hooks
  (( _dev_check_opt_report )) && _dev_report_section "Pre-commit"

  if [[ -f ".pre-commit-config.yaml" ]]; then
    local precommit_hook=""
    # A Command Line Tools placeholder git is never run; its hooks read as
    # not installed, and Required Tools explains the missing git.
    if _dev_have_command git; then
      precommit_hook=$(
        command git rev-parse --git-path hooks/pre-commit 2>/dev/null
      )
    fi
    if [[ -n "$precommit_hook" && -f "$precommit_hook" \
      && -x "$precommit_hook" ]]; then
      _dev_success "Pre-commit hooks installed."
      (( _dev_check_opt_report )) \
        && _dev_report_status ok "Pre-commit hooks installed"
    else
      _dev_warn \
        "Pre-commit config exists but hooks are not installed."
      _dev_info \
        "After uv sync --all-groups, run: .venv/bin/pre-commit install"
      (( _dev_check_opt_report )) \
        && _dev_report_status warn "Pre-commit hooks not installed"
      issues=$(( issues + 1 ))
    fi
  else
    _dev_info "No .pre-commit-config.yaml (optional)."
    (( _dev_check_opt_report )) \
      && _dev_report_status info "No .pre-commit-config.yaml"
  fi

  # 5. Required tooling
  (( _dev_check_opt_report )) && _dev_report_section "Required Tools"

  local -a required_tools=(uv git)
  local tool version
  for tool in "${required_tools[@]}"; do
    if _dev_have_command "$tool"; then
      version=$(command "$tool" --version 2>/dev/null | command head -1)
      _dev_success "$tool available (${version:-unknown})."
      (( _dev_check_opt_report )) \
        && _dev_report_status ok "$tool (${version:-unknown})"
    else
      _dev_error "$tool not found."
      _dev_command_unusable_hint "$tool"
      (( _dev_check_opt_report )) && _dev_report_status fail "$tool not found"
      issues=$(( issues + 1 ))
    fi
  done

  # The metadata interpreter, which need not be the first python3 on PATH.
  if (( metadata_python_ready )) && _dev_python_toml_resolve; then
    local metadata_python="$REPLY"
    version=$(command "$metadata_python" -I -S -c \
      'import sys; print("Python %d.%d.%d" % sys.version_info[:3])' \
      2>/dev/null)
    _dev_command_display "$metadata_python"
    _dev_success \
      "Python 3.11+ for project metadata: ${version:-unknown} ($REPLY)."
    (( _dev_check_opt_report )) && _dev_report_status ok \
      "Python 3.11+ for project metadata (${version:-unknown})"
  else
    _dev_error "Python 3.11+ with tomllib was not found for project metadata."
    _dev_python_install_hint
    (( _dev_check_opt_report )) && _dev_report_status fail \
      "Python 3.11+ with tomllib not found"
    issues=$(( issues + 1 ))
  fi

  # 6. Optional tooling
  local -a optional_tools=(fzf fd bat delta ruff jq shellcheck)
  local -a missing_optional=()
  for tool in "${optional_tools[@]}"; do
    _dev_have_command "$tool" || missing_optional+=("$tool")
  done
  if (( ${#missing_optional[@]} > 0 )); then
    _dev_dim "Optional tools not found: ${missing_optional[*]}"
    (( _dev_check_opt_report )) && {
      _dev_report_section "Optional Tools"
      _dev_report_status info "Not found: ${missing_optional[*]}"
    }
  fi

  # 7. Package index reachability
  (( _dev_check_opt_report )) && _dev_report_section "Network"

  if _dev_pypi_check_connectivity; then
    _dev_success "PyPI reachable."
    (( _dev_check_opt_report )) && _dev_report_status ok "PyPI reachable"
  else
    (( _dev_check_opt_report )) && _dev_report_status fail "PyPI unreachable"
    issues=$(( issues + 1 ))
  fi

  _dev_blank
  (( _dev_check_opt_report )) && _dev_report_section "Summary"

  if (( issues == 0 )); then
    _dev_success "Project health: all checks passed."
    (( _dev_check_opt_report )) \
      && _dev_report_status ok "All checks passed — 0 issues"
    if (( _dev_check_opt_report )); then
      _dev_report_save "health.md" || return 1
    fi
    return 0
  fi

  _dev_count_noun "$issues" issue
  local issues_label="$REPLY"
  _dev_warn "Project health: $issues_label found — review the output above."
  (( _dev_check_opt_report )) && _dev_report_status warn "$issues_label found"
  if (( _dev_check_opt_report )); then
    _dev_report_save "health.md" || return 1
  fi
  return 1
}

# --- Type checking ----------------------------------------------------------

# Private runners for dev-check-types, which has already proven that the
# project contains Python files. Both are read-only and take no arguments, so
# no caller-supplied option can enable a state-writing mode.

# Runs the Astral ty type checker. Returns the checker's status.
_dev_run_ty() {
  _dev_header "Running ty Type Checker"

  local -a reply=()
  _dev_python_tool_runner ty "uv add --dev ty" || return 1
  local -a runner=("${reply[@]}")

  "${runner[@]}" check >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "ty: no type errors found."
  else
    _dev_warn "ty reported issues (exit status: $exit_code)."
  fi
  return $exit_code
}

# Runs the Pyright type checker. Returns the checker's status.
_dev_run_pyright() {
  _dev_header "Running Pyright Type Checker"

  local -a reply=()
  _dev_python_tool_runner pyright "uv add --dev pyright" || return 1
  local -a runner=("${reply[@]}")

  "${runner[@]}" >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "Pyright: no type errors found."
  else
    _dev_warn "Pyright reported issues (exit status: $exit_code)."
  fi
  return $exit_code
}

# dev-check-types
#   Arguments: --help only.
#   Effects:   read-only. Runs every type checker the project configures.
#   Status:    0 when every detected checker passes, 1 otherwise.
dev-check-types() {
  emulate -L zsh
  (( ${+_DEV_RUN_PYTHON} )) || local _DEV_RUN_PYTHON=""

  local REPLY
  _dev_parse_no_arguments dev-check-types "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-check-types"
    print -u2 -r -- \
      "  Detect and run the configured type checkers (ty and/or pyright)."
    return 0
  fi

  _dev_header "Type Checking (Auto-detect)"
  _dev_validate_scan_depth || return 1

  local -i python_probe_status=0
  _dev_project_has_files '*.py' || python_probe_status=$?
  (( python_probe_status == 2 )) && return 1
  if (( python_probe_status == 1 )); then
    _dev_info "No Python files found in this project."
    return 0
  fi

  local -i has_ty=0 has_pyright=0

  if [[ -f "pyproject.toml" ]]; then
    local -i dependency_status=0
    _dev_pyproject_has_dep "ty" || dependency_status=$?
    (( dependency_status == 2 )) && return 1
    (( dependency_status == 0 )) && has_ty=1

    dependency_status=0
    _dev_pyproject_has_dep "pyright" || dependency_status=$?
    (( dependency_status == 2 )) && return 1
    (( dependency_status == 0 )) && has_pyright=1
  fi
  [[ -f "pyrightconfig.json" ]] && has_pyright=1

  if (( ! has_ty && ! has_pyright )); then
    _dev_have_command ty && has_ty=1
    _dev_have_command pyright && has_pyright=1
  fi

  if (( ! has_ty && ! has_pyright )); then
    _dev_error "No type checker found."
    _dev_info "Add one: uv add --dev ty   or   uv add --dev pyright"
    return 1
  fi

  local -i exit_code=0 checker_status=0

  if (( has_ty )); then
    _dev_run_ty || checker_status=$?
    (( checker_status == 130 || checker_status == 143 )) \
      && return $checker_status
    (( checker_status == 0 )) || exit_code=1
  fi

  if (( has_pyright )); then
    checker_status=0
    _dev_run_pyright || checker_status=$?
    (( checker_status == 130 || checker_status == 143 )) \
      && return $checker_status
    (( checker_status == 0 )) || exit_code=1
  fi

  if (( exit_code == 0 )); then
    _dev_success "All type checks passed."
  else
    _dev_warn "Type check issues found — review the output above."
  fi
  return $exit_code
}

# --- Pre-commit -------------------------------------------------------------

# dev-run-hooks
#   Arguments: forwarded unchanged to `pre-commit run`.
#   Effects:   pre-commit hooks may rewrite files by design.
#   Requires:  .pre-commit-config.yaml and pre-commit installed in .venv.
dev-run-hooks() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-run-hooks [pre-commit arguments...]"
    print -u2 -r -- \
      "  Runs file-stage hooks over all files by default."
    print -u2 -r -- \
      "  Arguments replace the default run options; hooks may modify files."
    print -u2 -r -- \
      "  Requires pre-commit installed in this project's .venv."
    return 0
  fi

  _dev_header "Running Pre-commit Hooks"
  _dev_require_file ".pre-commit-config.yaml" || return 1

  local -a arguments=(run --all-files)
  (( $# > 0 )) && arguments=(run "$@")

  local -a reply=()
  _dev_exact_project_python_tool_runner \
    pre-commit pre_commit "uv add --dev pre-commit" configured || return 1
  local -a runner=("${reply[@]}")

  "${runner[@]}" "${arguments[@]}" >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "Selected hooks passed."
  else
    _dev_warn "Some selected hooks failed (exit status: $exit_code)."
  fi
  return $exit_code
}

# --- Python linters and formatters ------------------------------------------

# Shared implementation for the two Ruff entrypoints.
_dev_run_ruff_mode() {
  local mode="$1"
  shift

  _dev_validate_scan_depth || return 1
  local -i python_probe_status=0
  _dev_project_has_files '*.py' || python_probe_status=$?
  (( python_probe_status == 2 )) && return 1
  if (( python_probe_status == 1 )); then
    _dev_info "No Python files found in this project."
    return 0
  fi

  local -a reply=()
  _dev_python_tool_runner ruff "uv add --dev ruff" || return 1
  local -a runner=("${reply[@]}")

  local -a mode_arguments=("$mode")
  [[ "$mode" == "check" ]] && mode_arguments+=(--no-fix --no-cache)

  # Ruff defaults to the current directory when no path is given; appending
  # "." would widen an explicit file selection to the whole project.
  if [[ "$mode" == "check" ]]; then
    command env -u RUFF_OUTPUT_FILE \
      "${runner[@]}" "${mode_arguments[@]}" "$@" >&2
  else
    "${runner[@]}" "${mode_arguments[@]}" "$@" >&2
  fi
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    if [[ "$mode" == "format" ]]; then
      _dev_success "Ruff: formatting completed."
    else
      _dev_success "Ruff: no issues found."
    fi
  else
    _dev_warn "Ruff reported issues (exit status: $exit_code)."
  fi
  return $exit_code
}

# dev-run-ruff — read-only lint pass. Arguments are forwarded to `ruff check`.
dev-run-ruff() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-run-ruff [ruff check arguments...]"
    print -u2 -r -- \
      "  Fixing flags are refused; use dev-run-ruff-format for explicit rewrites."
    return 0
  fi

  local argument
  for argument in "$@"; do
    case "$argument" in
      --fix|--fix=*|--fix-only|--fix-only=*|--unsafe-fixes|--unsafe-fixes=*|\
      --add-noqa|--add-noqa=*|--output-file|--output-file=*|-o|-o?*|\
      --cache-dir|--cache-dir=*|-[!-]*o*)
        _dev_error \
          "dev-run-ruff is read-only; refusing mutating option: $argument"
        _dev_info "Use dev-run-ruff-format for an explicit rewrite workflow."
        return 2
        ;;
    esac
  done

  _dev_header "Running Ruff Linter"
  _dev_run_ruff_mode check "$@"
}

# dev-run-ruff-format — rewrites Python files in place by design.
dev-run-ruff-format() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-run-ruff-format [ruff format arguments...]"
    print -u2 -r -- "  Rewrites Python files in place."
    return 0
  fi
  _dev_header "Running Ruff Formatter"
  _dev_run_ruff_mode format "$@"
}

# --- Terraform lint ---------------------------------------------------------

# dev-run-tflint — read-only lint by default; --init explicitly downloads the
# plugins declared by the project's TFLint configuration.
dev-run-tflint() {
  emulate -L zsh

  local -i initialize=0 auto_yes=0
  local -a arguments=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- \
          "Usage: dev-run-tflint [--init [--yes]] [tflint arguments...]"
        print -u2 -r -- \
          "  --init   Download configured plugins before the read-only lint."
        print -u2 -r -- \
          "  --yes    Bypass only the plugin-download confirmation."
        return 0
        ;;
      --init) initialize=1 ;;
      --yes|-y) auto_yes=1 ;;
      --fix|--fix=*|--langserver|--init=*)
        _dev_error "dev-run-tflint is read-only; refusing option: $1"
        return 2
        ;;
      *) arguments+=("$1") ;;
    esac
    shift
  done

  if (( auto_yes && ! initialize )); then
    _dev_error "--yes is valid only together with --init."
    return 2
  fi

  _dev_header "Running TFLint"
  _dev_validate_scan_depth || return 1

  local -i terraform_probe_status=0
  _dev_project_has_files '*.tf' || terraform_probe_status=$?
  (( terraform_probe_status == 2 )) && return 1
  if (( terraform_probe_status == 1 )); then
    _dev_info "No Terraform files found in this project."
    return 0
  fi

  _dev_require_command tflint || return 1

  if (( initialize )); then
    _dev_warn \
      "TFLint plugin initialization downloads and executes configured plugins."
    _dev_info "Planned command: tflint --init"

    if (( ! auto_yes )); then
      local confirmation
      confirmation=$(
        _dev_confirm_outcome "Download and initialize configured TFLint plugins?"
      )
      case "$confirmation" in
        confirmed) ;;
        unavailable)
          _dev_error \
            "No terminal is available; pass --yes with --init to authorize downloads."
          return 1
          ;;
        *)
          _dev_info "Cancelled. No plugins were downloaded."
          return 0
          ;;
      esac
    fi

    command tflint --init >&2 || {
      local -i init_status=$?
      _dev_error "TFLint plugin initialization failed (exit status: $init_status)."
      return $init_status
    }
  fi

  _dev_info "Linting Terraform files..."
  command tflint --recursive "${arguments[@]}" >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "TFLint passed."
  else
    _dev_warn "TFLint reported issues (exit status: $exit_code)."
  fi
  return $exit_code
}

# --- Markdown lint ----------------------------------------------------------

# dev-run-markdownlint
#   Arguments: --fix | --help
#   Effects:   read-only by default. --fix rewrites Markdown files.
dev-run-markdownlint() {
  emulate -L zsh

  local -i fix=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-run-markdownlint [--fix]"
        print -u2 -r -- \
          "  --fix   Rewrite Markdown files to resolve fixable findings."
        return 0
        ;;
      --fix) fix=1 ;;
      *)
        _dev_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  _dev_header "Running Markdownlint"
  _dev_validate_scan_depth || return 1

  # The suite's bounded inventory prunes node_modules, vendored and generated
  # trees, and nested repositories; a bare '**/*.md' glob would lint (and with
  # --fix rewrite) all of them.
  local -a reply=()
  _dev_project_files 512 '*.md' || return 1
  local -a markdown_files=("${reply[@]}")
  if (( ${#markdown_files[@]} == 0 )); then
    _dev_info "No Markdown files found in this project."
    return 0
  fi

  reply=()
  _dev_node_tool_runner markdownlint markdownlint-cli || return 1
  local -a runner=("${reply[@]}")

  local -a arguments=()
  if [[ -f ".config/markdownlint.yaml" ]]; then
    arguments+=(--config ".config/markdownlint.yaml")
  fi
  (( fix )) && arguments+=(--fix)

  if (( fix )); then
    _dev_warn "--fix rewrites Markdown files in place."
  fi
  local -i exit_code=0 batch_status=0 offset=1
  local -a batch=()
  while (( offset <= ${#markdown_files[@]} )); do
    batch=("${markdown_files[@][$offset,$(( offset + 63 ))]}")
    batch_status=0
    "${runner[@]}" "${arguments[@]}" "${batch[@]}" >&2 || batch_status=$?
    if (( batch_status == 130 || batch_status == 143 )); then
      return $batch_status
    fi
    (( batch_status != 0 && exit_code == 0 )) && exit_code=$batch_status
    offset=$(( offset + 64 ))
  done

  if (( exit_code == 0 )); then
    _dev_success "Markdownlint passed."
  else
    _dev_warn "Markdownlint reported issues (exit status: $exit_code)."
  fi
  return $exit_code
}

# --- Shell ------------------------------------------------------------------

# dev-run-shellcheck
#   Arguments: --help only.
#   Effects:   read-only. Runs ShellCheck over sh/bash files and `zsh -n` over
#              .zsh files, which ShellCheck cannot parse.
dev-run-shellcheck() {
  emulate -L zsh

  local REPLY
  _dev_parse_no_arguments dev-run-shellcheck "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-run-shellcheck"
    print -u2 -r -- \
      "  Lints .sh and .bash files with ShellCheck and parses .zsh with zsh -n."
    return 0
  fi

  _dev_header "Running ShellCheck"
  local -a reply=()
  _dev_project_files 512 '*.sh' '*.bash' '*.zsh' || return 1
  local -a files=("${reply[@]}")

  if (( ${#files[@]} == 0 )); then
    _dev_info "No shell files (.sh, .bash, .zsh) found in this project."
    return 0
  fi

  local -a posix_files=() zsh_files=()
  local candidate
  for candidate in "${files[@]}"; do
    [[ -n "$candidate" ]] || continue
    if [[ "$candidate" == *.zsh ]]; then
      zsh_files+=("$candidate")
    else
      posix_files+=("$candidate")
    fi
  done

  local -i shellcheck_status=0 parse_status=0

  if (( ${#posix_files[@]} > 0 )); then
    _dev_require_command shellcheck || return 1
    _dev_count_noun "${#posix_files[@]}" "shell file"
    _dev_info "Analyzing $REPLY with ShellCheck..."
    local -i offset=1
    local -a batch=()
    while (( offset <= ${#posix_files[@]} )); do
      batch=("${posix_files[@][$offset,$(( offset + 63 ))]}")
      command shellcheck -- "${batch[@]}" >&2 || shellcheck_status=1
      offset=$(( offset + 64 ))
    done
  fi

  if (( ${#zsh_files[@]} > 0 )); then
    _dev_count_noun "${#zsh_files[@]}" "Zsh file"
    _dev_info "Parsing $REPLY with zsh -n..."
    for candidate in "${zsh_files[@]}"; do
      _dev_debug "zsh -n $candidate"
      command zsh -n -- "$candidate" >&2 || parse_status=1
    done
  fi

  if (( shellcheck_status == 0 && parse_status == 0 )); then
    _dev_success "ShellCheck: no issues found."
    return 0
  fi

  _dev_warn "ShellCheck or the Zsh parse check reported issues."
  return 1
}

# --- Tests ------------------------------------------------------------------

# Status 0 means a pytest configuration is present, 1 means absent, and 2 means
# its bounded root-file inspection could not be trusted.
_dev_has_pytest_config() {
  local -a config_files=(
    pytest.toml
    .pytest.toml
    pytest.ini
    .pytest.ini
    pyproject.toml
    tox.ini
    setup.cfg
  )
  local -a existing_configs=()
  local config_file config_size

  zmodload -F zsh/stat b:zstat 2>/dev/null || {
    _dev_error "The zsh/stat module is required to inspect pytest configuration."
    return 2
  }

  for config_file in "${config_files[@]}"; do
    [[ -e "$config_file" || -L "$config_file" ]] || continue
    if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
      _dev_error "Pytest configuration is not a readable regular file: $config_file"
      return 2
    fi
    config_size=$(zstat +size -- "$config_file" 2>/dev/null) || {
      _dev_error "Could not inspect pytest configuration: $config_file"
      return 2
    }
    if [[ "$config_size" != <-> ]] \
      || (( config_size > 2097152 )); then
      _dev_error \
        "Refusing to parse pytest configuration larger than 2 MiB: $config_file"
      return 2
    fi

    case "$config_file" in
      pytest.toml|.pytest.toml|pytest.ini|.pytest.ini)
        return 0
        ;;
    esac
    existing_configs+=("$config_file")
  done

  (( ${#existing_configs[@]} > 0 )) || return 1
  local REPLY=""
  if ! _dev_python_toml_resolve; then
    _dev_error "Python 3.11+ is required to inspect pytest configuration."
    _dev_python_install_hint
    return 2
  fi

  command "$REPLY" -I -S -c '
import configparser
import os
import stat
import sys


MAX_CONFIG_SIZE = 2 * 1024 * 1024
CONFIGS = set(sys.argv[1:])


def read_bounded(filename):
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(filename, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) \
                or metadata.st_size > MAX_CONFIG_SIZE:
            raise ValueError
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            payload = handle.read(MAX_CONFIG_SIZE + 1)
        if len(payload) > MAX_CONFIG_SIZE:
            raise ValueError
        return payload
    finally:
        os.close(descriptor)


def ini_has_section(filename, section):
    parser = configparser.RawConfigParser()
    parser.read_string(read_bounded(filename).decode("utf-8"))
    return parser.has_section(section)


try:
    if "tox.ini" in CONFIGS \
            and ini_has_section("tox.ini", "pytest"):
        raise SystemExit(0)
    if "setup.cfg" in CONFIGS \
            and ini_has_section("setup.cfg", "tool:pytest"):
        raise SystemExit(0)

    if "pyproject.toml" in CONFIGS:
        try:
            import tomllib
        except ImportError:
            raise SystemExit(2)
        data = tomllib.loads(
            read_bounded("pyproject.toml").decode("utf-8")
        )
        tool = data.get("tool", {})
        if isinstance(tool, dict) and isinstance(tool.get("pytest"), dict):
            raise SystemExit(0)
except (
        OSError,
        UnicodeError,
        configparser.Error,
        ValueError,
):
    raise SystemExit(2)

raise SystemExit(3)
' "${existing_configs[@]}" 2>/dev/null
  local -i parser_status=$?
  case "$parser_status" in
    0) return 0 ;;
    3) return 1 ;;
    *)
      _dev_error "Could not parse the project's pytest configuration."
      return 2
      ;;
  esac
}

# Status 0 means tests are present, 1 means absent, and 2 means project
# discovery failed. Generated trees and nested repositories are pruned by the
# shared project probe.
_dev_has_tests() {
  local -i file_probe_status=0
  _dev_project_has_files 'test_*.py' '*_test.py' 'conftest.py' \
    || file_probe_status=$?
  (( file_probe_status == 0 )) && return 0
  (( file_probe_status == 2 )) && return 2
  _dev_has_pytest_config
}

# dev-run-tests
#   Arguments: forwarded unchanged to pytest.
#   Requires:  pytest installed in the exact project .venv.
#   Status:    pytest's status, or 0 when the project has no tests.
dev-run-tests() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-run-tests [pytest arguments...]"
    print -u2 -r -- \
      "  Requires pytest installed in this project's .venv."
    return 0
  fi

  _dev_header "Running Pytest"
  _dev_validate_scan_depth || return 1

  local -i explicit_pytest_arguments=$(( $# > 0 ))
  if (( $# == 0 )); then
    local -i test_probe_status=0
    _dev_has_tests || test_probe_status=$?
    case "$test_probe_status" in
      0) ;;
      1)
        _dev_info "No test files or pytest configuration found in this project."
        return 0
        ;;
      *) return 1 ;;
    esac
  fi

  local -a reply=()
  _dev_exact_project_python_tool_runner \
    pytest pytest "uv add --dev pytest" configured || return 1
  local -a runner=("${reply[@]}")

  _dev_info "Running pytest..."
  "${runner[@]}" "$@" >&2
  local -i exit_code=$?

  if (( exit_code == 5 && ! explicit_pytest_arguments )); then
    _dev_info "Pytest collected no tests; nothing to run."
    return 0
  fi

  if (( exit_code == 0 )); then
    _dev_success "Tests passed."
  else
    _dev_warn "Tests failed (exit status: $exit_code)."
  fi
  return $exit_code
}

# dev-run-coverage
#   Arguments: --html | --fail-under=N | --help; anything else goes to pytest.
#   Requires:  pytest and the selected coverage backend in the exact project
#              .venv. A missing coverage backend is an error.
dev-run-coverage() {
  emulate -L zsh
  (( ${+_DEV_RUN_PYTHON} )) || local _DEV_RUN_PYTHON=""

  local -i html=0
  local -i min_coverage=0
  local -i explicit_pytest_arguments=0
  local -a pytest_args=()
  local requested=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- \
          "Usage: dev-run-coverage [--html] [--fail-under=N] [pytest args...]"
        print -u2 -r -- "  --html           Also write an HTML coverage report."
        print -u2 -r -- \
          "  --fail-under=N   Fail when total coverage is below N percent."
        print -u2 -r -- \
          "  Requires pytest plus pytest-cov or coverage in this project's .venv."
        return 0
        ;;
      --html) html=1 ;;
      --fail-under=*)
        requested="${1#*=}"
        if ! _dev_validate_bounded_integer \
          "--fail-under" "$requested" 0 100; then
          return 2
        fi
        min_coverage=$(( 10#$requested ))
        ;;
      *)
        pytest_args+=("$1")
        explicit_pytest_arguments=1
        ;;
    esac
    shift
  done

  _dev_header "Running Tests with Coverage"
  _dev_validate_scan_depth || return 1

  if (( ${#pytest_args[@]} == 0 )); then
    local -i test_probe_status=0
    _dev_has_tests || test_probe_status=$?
    case "$test_probe_status" in
      0) ;;
      1)
        _dev_info "No test files or pytest configuration found in this project."
        return 0
        ;;
      *) return 1 ;;
    esac
  fi

  local -i exit_code=0
  local -i pytest_cov_status=0 coverage_status=0

  _dev_pyproject_has_dep "pytest-cov" || pytest_cov_status=$?
  (( pytest_cov_status == 2 )) && return 1
  if (( pytest_cov_status != 0 )); then
    _dev_pyproject_has_dep "coverage" || coverage_status=$?
    (( coverage_status == 2 )) && return 1
  fi

  _dev_require_venv || return 1

  local -i use_pytest_cov=0
  local -a reply=()
  local -a coverage_runner=()
  if (( pytest_cov_status == 0 )); then
    if ! _dev_project_python_module_available pytest_cov quiet; then
      _dev_error \
        "pytest-cov is declared but is not installed in the project virtual environment."
      _dev_info \
        "Synchronize the project environment first: uv sync --all-groups"
      return 1
    fi
    use_pytest_cov=1
  elif (( coverage_status == 0 )); then
    reply=()
    _dev_exact_project_python_tool_runner \
      coverage coverage "uv add --dev coverage" declared || return 1
    coverage_runner=("${reply[@]}")
  elif _dev_project_python_module_available pytest_cov quiet; then
    use_pytest_cov=1
  else
    reply=()
    if _dev_exact_project_python_tool_runner \
      coverage coverage "" required quiet; then
      coverage_runner=("${reply[@]}")
    fi
  fi

  if (( ! use_pytest_cov && ${#coverage_runner[@]} == 0 )); then
    _dev_error \
      "No coverage backend is installed in the project virtual environment."
    _dev_info "Install one with: uv add --dev pytest-cov"
    return 1
  fi

  reply=()
  _dev_exact_project_python_tool_runner \
    pytest pytest "uv add --dev pytest" configured || return 1
  local -a pytest_runner=("${reply[@]}")

  if (( use_pytest_cov )); then
    _dev_info "Running pytest with coverage (pytest-cov)..."
    local -a coverage_args=(--cov --cov-report=term-missing)
    (( html )) && coverage_args+=(--cov-report=html)
    (( min_coverage > 0 )) \
      && coverage_args+=("--cov-fail-under=$min_coverage")

    "${pytest_runner[@]}" \
      "${coverage_args[@]}" "${pytest_args[@]}" >&2
    exit_code=$?
  else
    _dev_info "Running pytest under coverage..."
    "${coverage_runner[@]}" run -m pytest "${pytest_args[@]}" >&2
    exit_code=$?

    if (( exit_code == 5 && ! explicit_pytest_arguments )); then
      _dev_info "Pytest collected no tests; no coverage report was generated."
      return 0
    fi

    local -a report_arguments=(report -m)
    (( min_coverage > 0 )) \
      && report_arguments+=("--fail-under=$min_coverage")
    "${coverage_runner[@]}" "${report_arguments[@]}" >&2 || {
      local -i report_status=$?
      _dev_error "Coverage report generation failed (exit status: $report_status)."
      (( exit_code == 0 )) && exit_code=$report_status
    }
    if (( html )); then
      if "${coverage_runner[@]}" html >&2; then
        _dev_info "HTML report: htmlcov/index.html"
      else
        local -i html_status=$?
        _dev_error "HTML coverage generation failed (exit status: $html_status)."
        (( exit_code == 0 )) && exit_code=$html_status
      fi
    fi
  fi

  if (( exit_code == 5 && ! explicit_pytest_arguments )); then
    _dev_info "Pytest collected no tests; no coverage report was generated."
    return 0
  fi

  if (( exit_code == 0 )); then
    _dev_success "Tests passed."
  else
    _dev_warn "Tests failed (exit status: $exit_code)."
  fi
  return $exit_code
}

# --- Consolidated quality gate ----------------------------------------------

# Runs one check as a gate step: a banner, its output captured privately and
# replayed only when the check fails, and one result line. It records the
# caller's dynamically scoped check_index, check_total, summary_records,
# failed_checks, and interrupted_status.
# Usage: _dev_run_check <label> <command> [arguments...]
_dev_run_check() {
  local label="$1"
  shift
  (( ++check_index ))

  # After an interrupted gate no later gate starts; it is listed as not run.
  if (( interrupted_status )); then
    summary_records+=("$label"$'\tnot-run\t\tchecks interrupted')
    return 0
  fi

  # The first banner follows the heading's blank line directly.
  if (( check_index == 1 )); then
    _dev_step_banner --first "$check_index" "$check_total" "$label"
  else
    _dev_step_banner "$check_index" "$check_total" "$label"
  fi
  local -a reply=()
  local -i check_status=0
  _dev_step_exec _dev_run_captured "$*" "$@" || check_status=$?
  local outcome="${reply[1]:-done}" detail="${reply[2]:-}"
  local seconds="${reply[3]:-}"
  # A gate that finishes without its own result has passed.
  [[ "$outcome" == done ]] && outcome=passed
  _dev_step_result "$check_index" "$check_total" "$label" "$outcome" \
    "$detail" "$seconds"
  summary_records+=("$label"$'\t'"$outcome"$'\t'"$seconds"$'\t'"$detail")
  (( check_status == 0 )) && return 0
  if (( check_status == 130 || check_status == 143 )); then
    interrupted_status=$check_status
  else
    failed_checks+=("$*")
  fi
  return 0
}

# dev-run-all-checks
#   Arguments: --verbose | --help
#   stdout:    none. Step results and the summary table go to stderr.
#   Effects:   read-only except for hooks and formatters the project configures.
#   Status:    0 when every executed check passed, 1 otherwise, or the status
#              of an interrupted check.
dev-run-all-checks() {
  emulate -L zsh
  # Resolved once here, the interpreter is inherited by every captured gate.
  (( ${+_DEV_RUN_PYTHON} )) || local _DEV_RUN_PYTHON=""

  local -i verbose=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-run-all-checks [--verbose]"
        print -u2 -r -- \
          "  --verbose   Stream each check's output instead of showing it only on failure."
        return 0
        ;;
      --verbose) verbose=1 ;;
      *)
        _dev_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  _dev_header "Running All Checks (Lint, Types, Security, Tests)"
  _dev_validate_scan_depth || return 1

  # --verbose streams each check's output for this run only.
  local ZDX_VERBOSE="${ZDX_VERBOSE:-}"
  (( verbose )) && ZDX_VERBOSE=1

  # The applicable checks are frozen first, so every banner shows its position.
  local -a checks=()
  local -i project_probe_status=0
  _dev_project_has_files '*.py' || project_probe_status=$?
  (( project_probe_status == 2 )) && return 1
  if (( project_probe_status == 0 )); then
    checks+=($'Ruff (lint)\tdev-run-ruff')

    local -i type_dependency_status=0
    _dev_pyproject_has_dep "ty" || type_dependency_status=$?
    (( type_dependency_status == 2 )) && return 1
    if (( type_dependency_status == 1 )); then
      type_dependency_status=0
      _dev_pyproject_has_dep "pyright" || type_dependency_status=$?
      (( type_dependency_status == 2 )) && return 1
    fi
    (( type_dependency_status == 0 )) \
      && checks+=($'Type checker\tdev-check-types')

    [[ -d ".venv" ]] && checks+=($'pip-audit (CVE)\tdev-run-audit')
    checks+=($'Bandit (SAST)\tdev-run-bandit')
  fi

  local -i test_probe_status=0
  _dev_has_tests || test_probe_status=$?
  (( test_probe_status == 2 )) && return 1
  (( test_probe_status == 0 )) && checks+=($'Tests (pytest)\tdev-run-tests')

  [[ -f ".pre-commit-config.yaml" ]] \
    && checks+=($'Pre-commit hooks\tdev-run-hooks')

  project_probe_status=0
  _dev_project_has_files '*.tf' || project_probe_status=$?
  (( project_probe_status == 2 )) && return 1
  (( project_probe_status == 0 )) && checks+=($'TFLint\tdev-run-tflint')

  project_probe_status=0
  _dev_project_has_files '*.sh' '*.bash' '*.zsh' \
    || project_probe_status=$?
  (( project_probe_status == 2 )) && return 1
  (( project_probe_status == 0 )) && checks+=($'ShellCheck\tdev-run-shellcheck')

  project_probe_status=0
  _dev_project_has_files '*.md' || project_probe_status=$?
  (( project_probe_status == 2 )) && return 1
  (( project_probe_status == 0 )) \
    && checks+=($'Markdownlint\tdev-run-markdownlint')

  if (( ${#checks[@]} == 0 )); then
    _dev_info "No applicable checks for this project."
    return 0
  fi

  local -i check_index=0 check_total=${#checks[@]} interrupted_status=0
  local -a summary_records=() failed_checks=()
  local check
  for check in "${checks[@]}"; do
    _dev_run_check "${check%%$'\t'*}" "${check#*$'\t'}"
  done

  _dev_print_step_summary "Check Results" "${summary_records[@]}"

  local REPLY
  _dev_count_noun "$check_total" check
  if (( interrupted_status )); then
    _dev_error \
      "Checks were interrupted (status $interrupted_status); later checks did not run."
    return $interrupted_status
  fi
  if (( ${#failed_checks[@]} == 0 )); then
    if (( check_total == 1 )); then
      _dev_success "The only check passed."
    else
      _dev_success "All $REPLY passed."
    fi
    return 0
  fi

  _dev_error "${#failed_checks[@]} of $REPLY failed."
  _dev_info "Run a failing check directly for its complete output:"
  local failed_check
  for failed_check in "${(@u)failed_checks}"; do
    _dev_dim "dev-menu $failed_check"
  done
  return 1
}

typeset -g _DEV_CHECKS_SOURCED=1
