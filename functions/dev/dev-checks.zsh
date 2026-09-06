#!/usr/bin/env zsh
# =============================================================================
# Dev Checks: linters, formatters, type checkers, tests, health and licenses
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
# _dev_check_opt_report and _dev_check_opt_strict locals.
_dev_check_parse_options() {
  local command_name="$1"
  local -i allow_strict="$2"
  shift 2

  _dev_check_opt_report=0
  _dev_check_opt_strict=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: $command_name [--report]$( \
          (( allow_strict )) && print -n -- ' [--strict]')"
        print -u2 -r -- \
          "  --report   Also write a Markdown report under \$DEV_REPORT_DIR."
        (( allow_strict )) && print -u2 -r -- \
          "  --strict   Fail when a restrictive copyleft license is found."
        return 3
        ;;
      --report) _dev_check_opt_report=1 ;;
      --strict)
        if (( ! allow_strict )); then
          _dev_error "Unknown option: $1"
          return 2
        fi
        _dev_check_opt_strict=1
        ;;
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
#   Requires:  uv, python3 3.11+, and an existing .venv.
#   Status:    0 on success, 1 on unmet preconditions, 2 on bad arguments.
dev-check-outdated() {
  emulate -L zsh

  local -i _dev_check_opt_report=0 _dev_check_opt_strict=0
  local -i parse_status=0
  _dev_check_parse_options dev-check-outdated 0 "$@" || parse_status=$?
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

  _dev_info "Comparing ${#direct_deps[@]} direct dependency(ies)..."

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
    _dev_info "$found direct dependency(ies) have newer versions available."
    (( _dev_check_opt_report )) && {
      _dev_report_line ""
      _dev_report_line \
        "**$found** direct dependency(ies) have newer versions available."
    }
  fi

  if (( _dev_check_opt_report )); then
    _dev_report_save "outdated.md" || return 1
  fi
  return 0
}

# --- Project health ---------------------------------------------------------

# Reads one bounded, non-symlinked uv Python request from .python-version and
# stores it in REPLY. Multiple or malformed requests are ambiguous for health
# comparison and fail closed.
_dev_health_read_python_pin() {
  emulate -L zsh
  setopt LOCAL_OPTIONS EXTENDED_GLOB
  REPLY=""

  if [[ -L ".python-version" || ! -f ".python-version" \
    || ! -r ".python-version" ]]; then
    _dev_error ".python-version must be a readable, non-symlinked regular file."
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || {
    _dev_error "The zsh/stat module is required to inspect .python-version."
    return 1
  }
  local pin_size
  pin_size=$(zstat +size -- .python-version 2>/dev/null) || {
    _dev_error "Could not inspect .python-version."
    return 1
  }
  if [[ "$pin_size" != <-> ]] || (( pin_size > 256 )); then
    _dev_error "Refusing a .python-version larger than 256 bytes."
    return 1
  fi

  local pin_content
  pin_content=$(< .python-version) || {
    _dev_error "Could not read .python-version."
    return 1
  }

  local -a pins=()
  local raw_line
  for raw_line in "${(@f)pin_content}"; do
    raw_line="${raw_line##[[:space:]]#}"
    raw_line="${raw_line%%[[:space:]]#}"
    [[ -n "$raw_line" ]] || continue
    if [[ "$raw_line" == *[[:space:]]* ]]; then
      _dev_error ".python-version contains an unsupported whitespace-delimited request."
      return 1
    fi
    pins+=("$raw_line")
  done

  if (( ${#pins[@]} != 1 )); then
    _dev_error ".python-version must contain exactly one Python request."
    return 1
  fi
  REPLY="${pins[1]}"
  return 0
}

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

  local -i _dev_check_opt_report=0 _dev_check_opt_strict=0
  local -i parse_status=0
  _dev_check_parse_options dev-check-health 0 "$@" || parse_status=$?
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

  # 1. pyproject.toml
  if [[ -e "pyproject.toml" || -L "pyproject.toml" ]]; then
    if [[ -L "pyproject.toml" || ! -f "pyproject.toml" \
      || ! -r "pyproject.toml" ]]; then
      _dev_error \
        "pyproject.toml must be a readable, non-symlinked regular file."
      (( _dev_check_opt_report )) && _dev_report_status fail \
        "pyproject.toml is not a safe readable regular file"
      issues=$(( issues + 1 ))
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
    if _dev_health_read_python_pin; then
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

try:
    from packaging.specifiers import SpecifierSet
    from packaging.version import Version
except ImportError:
    print("unknown")
    raise SystemExit

try:
    spec = SpecifierSet(os.environ["REQUIRES_PYTHON"])
    version = Version(os.environ["VENV_VERSION"])
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
              "Synchronize the project environment and ensure 'packaging' is installed."
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
    elif ! command -v uv &>/dev/null; then
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
    precommit_hook=$(
      command git rev-parse --git-path hooks/pre-commit 2>/dev/null
    )
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

  local -a required_tools=(uv git python3)
  local tool version
  for tool in "${required_tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
      version=$(command "$tool" --version 2>/dev/null | command head -1)
      _dev_success "$tool available (${version:-unknown})."
      (( _dev_check_opt_report )) \
        && _dev_report_status ok "$tool (${version:-unknown})"
    else
      _dev_error "$tool not found."
      (( _dev_check_opt_report )) && _dev_report_status fail "$tool not found"
      issues=$(( issues + 1 ))
    fi
  done

  # 6. Optional tooling
  local -a optional_tools=(fzf fd bat delta ruff jq shellcheck)
  local -a missing_optional=()
  for tool in "${optional_tools[@]}"; do
    command -v "$tool" &>/dev/null || missing_optional+=("$tool")
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

  _dev_warn "Project health: $issues issue(s) found — review the output above."
  (( _dev_check_opt_report )) && _dev_report_status warn "$issues issue(s) found"
  if (( _dev_check_opt_report )); then
    _dev_report_save "health.md" || return 1
  fi
  return 1
}

# --- Dependency licenses ----------------------------------------------------

typeset -gi _DEV_LICENSE_OUTPUT_LIMIT=10485760

# Captures at most limit+1 bytes from an external license backend. Checking the
# captured size before its pipeline status preserves a precise limit error when
# the producer receives SIGPIPE after `head` closes the bounded stream.
_dev_license_capture_output() {
  local label="$1"
  shift
  REPLY=""

  local LC_ALL=C
  local captured=""
  local -i capture_status=0
  captured=$(
    "$@" | command head -c $(( _DEV_LICENSE_OUTPUT_LIMIT + 1 ))
    local -a pipeline_status=("${pipestatus[@]}")
    (( pipeline_status[2] == 0 )) || exit "${pipeline_status[2]}"
    exit "${pipeline_status[1]}"
  ) || capture_status=$?

  if (( ${#captured} > _DEV_LICENSE_OUTPUT_LIMIT )); then
    _dev_error "$label exceeds the 10 MiB safety limit."
    return 1
  fi
  if (( capture_status != 0 )); then
    return $capture_status
  fi

  REPLY="$captured"
  return 0
}

# dev-check-licenses
#   Arguments: --strict | --report | --help
#   stdout:    the pip-licenses table.
#   Effects:   read-only, plus an optional Markdown report.
#   Status:    0 normally, 1 with --strict when a copyleft license is found.
dev-check-licenses() {
  emulate -L zsh

  local -i _dev_check_opt_report=0 _dev_check_opt_strict=0
  local -i parse_status=0
  _dev_check_parse_options dev-check-licenses 1 "$@" || parse_status=$?
  (( parse_status == 3 )) && return 0
  (( parse_status != 0 )) && return $parse_status

  _dev_header "Checking Dependency Licenses"
  _dev_require_venv || return 1

  local -a reply=()
  _dev_project_python_tool_runner \
    pip-licenses piplicenses "uv add --dev pip-licenses" || return 1
  local -a runner=("${reply[@]}")

  _dev_info "Scanning installed package licenses..."
  _dev_license_capture_output "The license table" \
    "${runner[@]}" --format=table --with-authors --order=license || {
    _dev_error "The license scanner failed."
    return 1
  }
  local output="$REPLY"

  if [[ -z "$output" ]]; then
    _dev_error "Could not retrieve license information."
    return 1
  fi

  print -r -- "$output"

  (( _dev_check_opt_report )) && {
    _dev_report_init "Dependency License Report"
    _dev_report_section "Installed Licenses"
    local report_line
    for report_line in "${(@f)output}"; do
      _dev_report_line "    $(_dev_display_escape "$report_line")"
    done
  }

  # The human-readable table may contain license-like words in package names
  # or author fields. Classify a separate JSON result and inspect only each
  # record's License field.
  _dev_license_capture_output "The structured license inventory" \
    "${runner[@]}" --format=json --with-authors --order=license || {
    _dev_error "The license scanner could not produce structured output."
    return 1
  }
  local license_json="$REPLY"

  local project_python="${runner[1]}"
  local flagged
  flagged=$(print -rn -- "$license_json" | "$project_python" -I -c '
import json
import re
import sys
import unicodedata

try:
    records = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeError):
    raise SystemExit(1)
if not isinstance(records, list):
    raise SystemExit(1)

restrictive = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:AGPL|GPL|SSPL|EUPL|OSL|CPAL)"
    r"(?:[- ]?v?[0-9][A-Za-z0-9.+-]*)?(?![A-Za-z])"
)


def terminal_safe(value):
    return "".join(
        " " if unicodedata.category(character) in {"Cc", "Cf"} else character
        for character in value
    )


for record in records:
    if not isinstance(record, dict):
        raise SystemExit(1)
    if any(
        field not in record or not isinstance(record[field], str)
        for field in ("Name", "Version", "License")
    ):
        raise SystemExit(1)
    license_name = record["License"]
    if not restrictive.search(license_name):
        continue
    fields = (
        record["Name"],
        record["Version"],
        license_name,
    )
    print(" | ".join(terminal_safe(field) for field in fields))
') || {
    _dev_error "The structured license inventory is invalid."
    return 1
  }

  if [[ -n "$flagged" ]]; then
    _dev_blank
    _dev_warn "Potentially restrictive licenses found (review for copyleft):"
    local flagged_line
    for flagged_line in "${(@f)flagged}"; do
      print -u2 -r -- "$(_dev_display_escape "$flagged_line")"
    done
    if (( _dev_check_opt_report )); then
      _dev_report_section "Restrictive Licenses"
      for flagged_line in "${(@f)flagged}"; do
        _dev_report_line "    $(_dev_display_escape "$flagged_line")"
      done
      _dev_report_save "licenses.md" || return 1
    fi
    if (( _dev_check_opt_strict )); then
      _dev_error "Strict mode: failing because restrictive licenses were found."
      return 1
    fi
    return 0
  fi

  _dev_success "No restrictive (copyleft) licenses detected."
  if (( _dev_check_opt_report )); then
    _dev_report_status ok "No restrictive licenses detected"
    _dev_report_save "licenses.md" || return 1
  fi
  return 0
}

# --- Type checking ----------------------------------------------------------

# dev-check-types
#   Arguments: --help only.
#   Effects:   read-only. Runs every type checker the project configures.
#   Status:    0 when every detected checker passes, 1 otherwise.
dev-check-types() {
  emulate -L zsh

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
    command -v ty &>/dev/null && has_ty=1
    command -v pyright &>/dev/null && has_pyright=1
  fi

  if (( ! has_ty && ! has_pyright )); then
    _dev_error "No type checker found."
    _dev_info "Add one: uv add --dev ty   or   uv add --dev pyright"
    return 1
  fi

  local -i exit_code=0

  if (( has_ty )); then
    _dev_timed "dev:dev-run-ty" dev-run-ty || exit_code=1
  fi

  if (( has_pyright )); then
    _dev_timed "dev:dev-run-pyright" dev-run-pyright || exit_code=1
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

  if [[ "$mode" == "check" ]]; then
    command env -u RUFF_OUTPUT_FILE \
      "${runner[@]}" "${mode_arguments[@]}" "$@" . >&2
  else
    "${runner[@]}" "${mode_arguments[@]}" "$@" . >&2
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
      --cache-dir|--cache-dir=*)
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

# dev-run-ty — Astral ty type checker.
dev-run-ty() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-run-ty [ty arguments...]"
    return 0
  fi

  _dev_header "Running ty Type Checker"
  _dev_validate_scan_depth || return 1

  local -i python_probe_status=0
  _dev_project_has_files '*.py' || python_probe_status=$?
  (( python_probe_status == 2 )) && return 1
  if (( python_probe_status == 1 )); then
    _dev_info "No Python files found in this project."
    return 0
  fi

  local -a reply=()
  _dev_python_tool_runner ty "uv add --dev ty" || return 1
  local -a runner=("${reply[@]}")

  "${runner[@]}" check "$@" >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "ty: no type errors found."
  else
    _dev_warn "ty reported issues (exit status: $exit_code)."
  fi
  return $exit_code
}

# dev-run-pyright — Pyright type checker.
dev-run-pyright() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-run-pyright [pyright arguments...]"
    print -u2 -r -- \
      "  Stub-generation options are refused because this command is read-only."
    return 0
  fi

  local argument
  for argument in "$@"; do
    case "$argument" in
      --createstub|--createstub=*)
        _dev_error \
          "dev-run-pyright is read-only; refusing mutating option: $argument"
        return 2
        ;;
    esac
  done

  _dev_header "Running Pyright Type Checker"
  _dev_validate_scan_depth || return 1

  local -i python_probe_status=0
  _dev_project_has_files '*.py' || python_probe_status=$?
  (( python_probe_status == 2 )) && return 1
  if (( python_probe_status == 1 )); then
    _dev_info "No Python files found in this project."
    return 0
  fi

  local -a reply=()
  _dev_python_tool_runner pyright "uv add --dev pyright" || return 1
  local -a runner=("${reply[@]}")

  "${runner[@]}" "$@" >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "Pyright: no type errors found."
  else
    _dev_warn "Pyright reported issues (exit status: $exit_code)."
  fi
  return $exit_code
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

  local -i markdown_probe_status=0
  _dev_project_has_files '*.md' || markdown_probe_status=$?
  (( markdown_probe_status == 2 )) && return 1
  if (( markdown_probe_status == 1 )); then
    _dev_info "No Markdown files found in this project."
    return 0
  fi

  local -a reply=()
  _dev_node_tool_runner markdownlint markdownlint-cli || return 1
  local -a runner=("${reply[@]}")

  local -a arguments=()
  if [[ -f ".config/markdownlint.yaml" ]]; then
    arguments+=(--config ".config/markdownlint.yaml")
  fi
  arguments+=('**/*.md')
  (( fix )) && arguments+=(--fix)

  if (( fix )); then
    _dev_warn "--fix rewrites Markdown files in place."
  fi
  "${runner[@]}" "${arguments[@]}" >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "Markdownlint passed."
  else
    _dev_warn "Markdownlint reported issues (exit status: $exit_code)."
  fi
  return $exit_code
}

# --- JavaScript and TypeScript ----------------------------------------------

# dev-run-eslint — arguments are forwarded to eslint.
dev-run-eslint() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-run-eslint [eslint arguments...]"
    print -u2 -r -- "  Mutating and cache-writing options are refused."
    return 0
  fi

  local argument
  for argument in "$@"; do
    case "$argument" in
      --fix|--fix=*|--init|--init=*|\
      --output-file|--output-file=*|-o|-o?*|\
      --suppress-all|--suppress-all=*|\
      --suppress-rule|--suppress-rule=*|\
      --prune-suppressions|--prune-suppressions=*|\
      --suppressions-location|--suppressions-location=*|\
      --cache|--cache=*|--cache-file|--cache-file=*|\
      --cache-location|--cache-location=*|--cache-strategy|--cache-strategy=*)
        _dev_error \
          "dev-run-eslint is read-only; refusing state-writing option: $argument"
        return 2
        ;;
    esac
  done

  _dev_header "Running ESLint"
  _dev_require_file "package.json" || return 1

  local -a reply=()
  _dev_node_tool_runner eslint || return 1
  local -a runner=("${reply[@]}")

  "${runner[@]}" . "$@" >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "ESLint: no issues found."
  else
    _dev_warn "ESLint reported issues (exit status: $exit_code)."
  fi
  return $exit_code
}

# dev-run-prettier — read-only format verification.
dev-run-prettier() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-run-prettier [prettier arguments...]"
    print -u2 -r -- \
      "  Verifies formatting; write and cache options are refused."
    return 0
  fi

  local argument
  for argument in "$@"; do
    case "$argument" in
      --write|--write=*|-w|--cache|--cache=*|--cache-location|--cache-location=*)
        _dev_error \
          "dev-run-prettier is read-only; refusing state-writing option: $argument"
        return 2
        ;;
    esac
  done

  _dev_header "Running Prettier Check"
  _dev_require_file "package.json" || return 1

  local -a reply=()
  _dev_node_tool_runner prettier || return 1
  local -a runner=("${reply[@]}")

  "${runner[@]}" --check . "$@" >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "Prettier: all files match the configured style."
  else
    _dev_warn "Prettier found formatting issues (exit status: $exit_code)."
  fi
  return $exit_code
}

# --- Rust -------------------------------------------------------------------

# dev-run-clippy — arguments are forwarded to cargo clippy. Cargo may create
# target/ build artifacts, but source-rewriting flags are refused.
dev-run-clippy() {
  emulate -L zsh

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -u2 -r -- "Usage: dev-run-clippy [cargo clippy arguments...]"
    print -u2 -r -- \
      "  Creates Cargo build artifacts; source-rewriting --fix is refused."
    return 0
  fi

  local argument
  for argument in "$@"; do
    case "$argument" in
      --fix|--fix=*)
        _dev_error "Refusing Cargo's source-rewriting option: $argument"
        return 2
        ;;
    esac
  done

  _dev_header "Running Cargo Clippy"
  _dev_require_file "Cargo.toml" || return 1
  _dev_require_command cargo || return 1

  command cargo clippy --locked --all-targets "$@" >&2
  local -i exit_code=$?

  if (( exit_code == 0 )); then
    _dev_success "Clippy: no warnings or errors found."
  else
    _dev_warn "Clippy reported issues (exit status: $exit_code)."
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
    _dev_info "Analyzing ${#posix_files[@]} shell file(s) with ShellCheck..."
    local -i offset=1
    local -a batch=()
    while (( offset <= ${#posix_files[@]} )); do
      batch=("${posix_files[@][$offset,$(( offset + 63 ))]}")
      command shellcheck -- "${batch[@]}" >&2 || shellcheck_status=1
      offset=$(( offset + 64 ))
    done
  fi

  if (( ${#zsh_files[@]} > 0 )); then
    _dev_info "Parsing ${#zsh_files[@]} Zsh file(s) with zsh -n..."
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

  zmodload zsh/stat 2>/dev/null || {
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
  if ! command -v python3 &>/dev/null; then
    _dev_error "Python 3.11+ is required to inspect pytest configuration."
    return 2
  fi

  command python3 -I -c '
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

# Records one "name|result|seconds" row per executed check.
typeset -ga _DEV_CHECK_RESULTS=()
typeset -gi _DEV_CHECK_FAILURES=0
typeset -gi _DEV_CHECK_VERBOSE=0

_dev_run_check() {
  local name="$1"
  shift

  local start
  start=$(_dev_now)

  if (( _DEV_CHECK_VERBOSE )); then
    "$@" >&2
  else
    "$@" >/dev/null 2>&1
  fi
  local -i exit_code=$?

  local elapsed
  elapsed=$(_dev_elapsed "$start")

  if (( exit_code == 0 )); then
    _DEV_CHECK_RESULTS+=("${name}|passed|${elapsed}s")
  else
    _DEV_CHECK_RESULTS+=("${name}|failed|${elapsed}s")
    _DEV_CHECK_FAILURES=$(( _DEV_CHECK_FAILURES + 1 ))
  fi
  return 0
}

_dev_check_print_results() {
  local -a rows=("$@")
  (( ${#rows[@]} > 0 )) || return 0

  _dev_header "Check Results"

  if _dev_color_enabled; then
    printf '  \033[1;37m%-30s %-10s %s\033[0m\n' "Check" "Result" "Time" >&2
  else
    printf '  %-30s %-10s %s\n' "Check" "Result" "Time" >&2
  fi

  local row name rest result elapsed
  for row in "${rows[@]}"; do
    name="${row%%|*}"
    rest="${row#*|}"
    result="${rest%%|*}"
    elapsed="${rest#*|}"

    if _dev_color_enabled; then
      if [[ "$result" == "passed" ]]; then
        printf '  %-30s \033[1;32m%-10s\033[0m %s\n' \
          "${(V)name}" "✔ $result" "$elapsed" >&2
      else
        printf '  %-30s \033[1;31m%-10s\033[0m %s\n' \
          "${(V)name}" "✘ $result" "$elapsed" >&2
      fi
    else
      printf '  %-30s %-10s %s\n' "${(V)name}" "$result" "$elapsed" >&2
    fi
  done
}

# dev-run-all-checks
#   Arguments: --verbose | --help
#   stdout:    none. The summary table is UI and goes to stderr.
#   Effects:   read-only except for hooks and formatters the project configures.
#   Status:    0 when every executed check passed, 1 otherwise.
dev-run-all-checks() {
  emulate -L zsh

  local -i verbose=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-run-all-checks [--verbose]"
        print -u2 -r -- \
          "  --verbose   Show each check's output instead of only the summary."
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

  local total_start
  total_start=$(_dev_now)

  local -i previous_verbose=$_DEV_CHECK_VERBOSE
  local -a results=()
  local -i failures=0

  {
    _DEV_CHECK_RESULTS=()
    _DEV_CHECK_FAILURES=0
    _DEV_CHECK_VERBOSE=$verbose

    local -i project_probe_status=0
    _dev_project_has_files '*.py' || project_probe_status=$?
    (( project_probe_status == 2 )) && return 1
    if (( project_probe_status == 0 )); then
      _dev_info "Python project detected."
      _dev_run_check "Ruff (lint)" dev-run-ruff

      local -i type_dependency_status=0
      _dev_pyproject_has_dep "ty" || type_dependency_status=$?
      (( type_dependency_status == 2 )) && return 1
      if (( type_dependency_status == 1 )); then
        type_dependency_status=0
        _dev_pyproject_has_dep "pyright" || type_dependency_status=$?
        (( type_dependency_status == 2 )) && return 1
      fi
      if (( type_dependency_status == 0 )); then
        _dev_run_check "Type checker" dev-check-types
      fi

      if [[ -d ".venv" ]]; then
        _dev_run_check "pip-audit (CVE)" dev-run-audit
      fi
      _dev_run_check "Bandit (SAST)" dev-run-bandit
    fi

    local -i test_probe_status=0
    _dev_has_tests || test_probe_status=$?
    (( test_probe_status == 2 )) && return 1
    if (( test_probe_status == 0 )); then
      _dev_run_check "Tests (pytest)" dev-run-tests
    fi

    if [[ -f ".pre-commit-config.yaml" ]]; then
      _dev_run_check "Pre-commit hooks" dev-run-hooks
    fi

    project_probe_status=0
    _dev_project_has_files '*.tf' || project_probe_status=$?
    (( project_probe_status == 2 )) && return 1
    if (( project_probe_status == 0 )); then
      _dev_run_check "TFLint" dev-run-tflint
    fi

    if [[ -f "package.json" ]]; then
      _dev_run_check "ESLint" dev-run-eslint
      _dev_run_check "Prettier" dev-run-prettier
    fi

    if [[ -f "Cargo.toml" ]]; then
      _dev_run_check "Cargo Clippy" dev-run-clippy
    fi

    project_probe_status=0
    _dev_project_has_files '*.sh' '*.bash' '*.zsh' \
      || project_probe_status=$?
    (( project_probe_status == 2 )) && return 1
    if (( project_probe_status == 0 )); then
      _dev_run_check "ShellCheck" dev-run-shellcheck
    fi

    project_probe_status=0
    _dev_project_has_files '*.md' || project_probe_status=$?
    (( project_probe_status == 2 )) && return 1
    if (( project_probe_status == 0 )); then
      _dev_run_check "Markdownlint" dev-run-markdownlint
    fi

    results=("${_DEV_CHECK_RESULTS[@]}")
    failures=$_DEV_CHECK_FAILURES
  } always {
    _DEV_CHECK_VERBOSE=$previous_verbose
    _DEV_CHECK_RESULTS=()
    _DEV_CHECK_FAILURES=0
  }

  if (( ${#results[@]} == 0 )); then
    _dev_info "No applicable checks for this project."
    return 0
  fi

  _dev_check_print_results "${results[@]}"

  local total_elapsed
  total_elapsed=$(_dev_elapsed "$total_start")

  _dev_blank
  if (( failures == 0 )); then
    _dev_success "All ${#results[@]} check(s) passed in ${total_elapsed}s."
    return 0
  fi

  _dev_warn \
    "$failures of ${#results[@]} check(s) failed (${total_elapsed}s total)."
  (( verbose )) || _dev_info \
    "Re-run with --verbose, or run the failing check directly, to see details."
  return 1
}

typeset -g _DEV_CHECKS_SOURCED=1
