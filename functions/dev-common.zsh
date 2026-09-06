#!/usr/bin/env zsh
# =============================================================================
# Dev Common: shared UI, safety, capability, and routing helpers
# =============================================================================
#
# Loaded by dev-menu.zsh before every module under functions/dev/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_DEV_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Configuration ----------------------------------------------------------
# Source time performs parameter expansion only: no external commands, no
# filesystem scans, and no network access.

typeset -g DEV_BACKUP_DIR="${DEV_BACKUP_DIR-.dev-suite-backups}"
typeset -g DEV_PROFILE_DIR="${DEV_PROFILE_DIR-.dev-suite-profiles}"
typeset -g DEV_REPORT_DIR="${DEV_REPORT_DIR-dev-suite-reports}"
typeset -g DEV_BACKUP_RETENTION="${DEV_BACKUP_RETENTION-5}"
typeset -g DEV_SCAN_DEPTH="${DEV_SCAN_DEPTH-3}"
typeset -g DEV_PYPI_TIMEOUT="${DEV_PYPI_TIMEOUT-15}"
typeset -g DEV_PYPI_RETRIES="${DEV_PYPI_RETRIES-2}"
typeset -g DEV_PYPI_JOBS="${DEV_PYPI_JOBS-8}"

# Running `uvx`/`npx` downloads and executes the latest published version of a
# third-party package. That is remote code execution, so it stays opt-in.
typeset -g DEV_ALLOW_EPHEMERAL="${DEV_ALLOW_EPHEMERAL-0}"

# Per-invocation confirmation bypass. Public commands set this only from their
# own documented --yes flag and always reset it before returning.
typeset -g _DEV_AUTO_YES=0

# --- Logging primitives -----------------------------------------------------

_dev_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

_dev_header() {
  if _dev_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}

_dev_success() {
  if _dev_color_enabled; then
    printf '\033[1;32m✔ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✔ %s\n' "${(V)1}" >&2
  fi
}

_dev_warn() {
  if _dev_color_enabled; then
    printf '\033[1;33m⚠ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⚠ %s\n' "${(V)1}" >&2
  fi
}

_dev_info() {
  if _dev_color_enabled; then
    printf '\033[0;36m➜ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '➜ %s\n' "${(V)1}" >&2
  fi
}

_dev_error() {
  if _dev_color_enabled; then
    printf '\033[1;31m✘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✘ %s\n' "${(V)1}" >&2
  fi
}

_dev_dim() {
  if _dev_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
}

_dev_label() {
  if _dev_color_enabled; then
    printf '\033[1;37m  %-28s\033[0m %s\n' "${(V)1}" "${(V)2}" >&2
  else
    printf '  %-28s %s\n' "${(V)1}" "${(V)2}" >&2
  fi
}

_dev_debug() {
  [[ "${DEV_SUITE_DEBUG:-0}" == "1" ]] || return 0
  if _dev_color_enabled; then
    printf '\033[0;90m  [debug] %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  [debug] %s\n' "${(V)1}" >&2
  fi
}

_dev_blank() { print -u2 -r -- ""; }

# Render control characters visibly before including external data in UI text.
_dev_display_escape() {
  print -r -- "${(V)1}"
}

# --- Timing -----------------------------------------------------------------
# The core runtime owns _timed. A standalone source of this suite must not
# depend on it, and it must never define a competing global implementation.

_dev_timed() {
  local label="$1"
  shift

  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

_dev_now() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    print -r -- "$EPOCHREALTIME"
  else
    print -r -- "0"
  fi
}

_dev_elapsed() {
  local start="${1:-0}"
  local now
  now=$(_dev_now)
  printf '%.1f' $(( now - start ))
}

# --- Prompts ----------------------------------------------------------------

# Confirmation gate for mutating work.
#
# Status:
#   0  the user confirmed, or _DEV_AUTO_YES is set from a documented --yes flag
#   1  the user declined; a declined confirmation is a cancellation, not an error
#   2  no terminal is attached, so no confirmation can be obtained
#
# Callers MUST distinguish 1 from 2: a decline returns 0 from the public
# command, while "cannot prompt" fails closed and names the flag to pass.
_dev_confirm() {
  local prompt="${1:-Proceed?}"
  local display_prompt="${(V)prompt}"

  if (( _DEV_AUTO_YES )); then
    _dev_debug "Auto-confirmed: $prompt"
    return 0
  fi

  if [[ ! -t 0 || ! -t 2 ]]; then
    _dev_debug "No terminal available to confirm: $prompt"
    return 2
  fi

  local selected=""
  if command -v fzf &>/dev/null; then
    # The confirmation options are appended after the _dev_fzf preset, so the
    # preset height, preview, and theme are overridden for this small picker.
    local -a fzf_options=(
      --height=20%
      --layout=reverse
      --border=rounded
      --pointer='▶'
      --preview=''
      --preview-window=hidden
      --header='Up/Down navigate | Enter confirm | Esc cancel'
      --prompt="${display_prompt} > "
    )

    local -i fzf_status=0
    _dev_fzf_capture "${fzf_options[@]}" \
      < <(printf "No\nYes\n") || fzf_status=$?
    selected="$REPLY"
    if (( fzf_status == 0 )); then
      [[ "$selected" == "Yes" ]]
      return $?
    elif _dev_fzf_rc_is_cancel "$fzf_status"; then
      return 1
    fi
    _dev_warn "fzf confirmation failed; using the terminal prompt."
  fi

  local reply
  if _dev_color_enabled; then
    printf '\033[1;33m? %s [y/N]: \033[0m' "$display_prompt" >&2
  else
    printf '? %s [y/N]: ' "$display_prompt" >&2
  fi
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Runs a confirmation for a mutating command and reports the outcome as one of
# three words on stdout: "confirmed", "declined", or "unavailable". This keeps
# the three-way decision identical at every call site.
_dev_confirm_outcome() {
  local prompt="$1"
  local -i confirm_status=0

  _dev_confirm "$prompt" || confirm_status=$?

  case "$confirm_status" in
    0) print -r -- "confirmed" ;;
    2) print -r -- "unavailable" ;;
    *) print -r -- "declined" ;;
  esac
  return 0
}

# Reads a single line of user input. Data goes to stdout; the prompt to stderr.
_dev_read_line() {
  local prompt="${1:-Value}"
  [[ -t 0 && -t 2 ]] || return 1

  printf '  %s: ' "${(V)prompt}" >&2
  local reply
  read -r reply || return 1
  print -r -- "$reply"
}

# --- Dependency and context checks ------------------------------------------

# Validates an unsigned decimal configuration value without evaluating
# arbitrary parameter content as an arithmetic expression.
_dev_validate_bounded_integer() {
  local variable_name="$1"
  local value="$2"
  local -i minimum="$3"
  local -i maximum="$4"

  if [[ -z "$value" || "$value" != <-> \
    || ${#value} -gt ${#maximum} ]]; then
    _dev_error \
      "$variable_name must be an integer from $minimum through $maximum."
    return 1
  fi

  local -i numeric_value
  numeric_value=$(( 10#$value ))
  if (( numeric_value < minimum || numeric_value > maximum )); then
    _dev_error \
      "$variable_name must be an integer from $minimum through $maximum."
    return 1
  fi
  return 0
}

_dev_validate_scan_depth() {
  _dev_validate_bounded_integer DEV_SCAN_DEPTH "$DEV_SCAN_DEPTH" 1 32
}

_dev_validate_backup_retention() {
  _dev_validate_bounded_integer \
    DEV_BACKUP_RETENTION "$DEV_BACKUP_RETENTION" 1 100
}

_dev_validate_allow_ephemeral() {
  if [[ "$DEV_ALLOW_EPHEMERAL" != "0" \
    && "$DEV_ALLOW_EPHEMERAL" != "1" ]]; then
    _dev_error "DEV_ALLOW_EPHEMERAL must be either 0 or 1."
    return 1
  fi
  return 0
}

# Parses the complete argument vector for a command that accepts no operands.
# Sets REPLY to `run` or `help`; malformed arity always fails before a caller
# performs capability, filesystem, or UI probes.
_dev_parse_no_arguments() {
  local command_name="${1:-}"
  REPLY=""

  if [[ -z "$command_name" ]]; then
    _dev_error "An argument-free command name is required."
    return 2
  fi
  shift

  if (( $# == 0 )); then
    REPLY="run"
    return 0
  fi

  if (( $# == 1 )); then
    case "$1" in
      -h|--help)
        REPLY="help"
        return 0
        ;;
      "")
        _dev_error "$command_name accepts no arguments."
        return 2
        ;;
      *)
        _dev_error "Unknown option: $1"
        return 2
        ;;
    esac
  fi

  _dev_error "$command_name accepts no arguments."
  return 2
}

_dev_require_command() {
  local command_name="$1"

  # The public function has already parsed its arguments by the time it asks
  # for an operational dependency. This dynamically scoped gate preserves the
  # central metadata check without probing before the public parser.
  if [[ -n "${_DEV_DISPATCH_COMMAND:-}" ]] \
    && (( ! ${_DEV_DISPATCH_DEPS_CHECKED:-0} )); then
    _DEV_DISPATCH_DEPS_CHECKED=1
    _dev_verify_deps "$_DEV_DISPATCH_COMMAND" || return 1
  fi

  if ! command -v "$command_name" &>/dev/null; then
    _dev_error "$command_name not found."
    _dev_info "Install $command_name with the package manager for this host."
    return 1
  fi
}

_dev_require_file() {
  local file_name="$1"
  if [[ ! -f "$file_name" ]]; then
    _dev_error "No $file_name found in $PWD."
    return 1
  fi
}

_dev_require_venv() {
  local mode="${1:-}"
  local -i quiet=0
  [[ "$mode" == "quiet" ]] && quiet=1
  if [[ -n "$mode" && "$mode" != "quiet" ]]; then
    _dev_error "Invalid virtual-environment validation mode."
    return 2
  fi

  local project_root="${PWD:A}"
  local venv_directory="${project_root}/.venv"
  local venv_bin="${venv_directory}/bin"
  local project_python="${venv_bin}/python"

  if [[ ! -e "$venv_directory" && ! -L "$venv_directory" ]]; then
    if (( ! quiet )); then
      _dev_error "No .venv found in $PWD."
      _dev_info "Create it with: uv sync"
    fi
    return 1
  fi

  if [[ ! -d "$venv_directory" || -L "$venv_directory" \
    || "${venv_directory:a}" != "${venv_directory:A}" ]]; then
    if (( ! quiet )); then
      _dev_error \
        "Refusing an unsafe project virtual environment: .venv must be a real directory."
      _dev_info "Recreate it in this project with: uv sync"
    fi
    return 1
  fi

  if [[ ! -d "$venv_bin" || -L "$venv_bin" \
    || "${venv_bin:A}" != "${venv_directory}/bin" \
    || ! -x "$project_python" ]] \
    || ! "$project_python" -I -c \
      'from pathlib import Path
import sys

expected = Path(sys.argv[1]).resolve()
actual = Path(sys.prefix).resolve()
raise SystemExit(actual != expected or sys.base_prefix == sys.prefix)' \
      "$venv_directory" 2>/dev/null; then
    if (( ! quiet )); then
      _dev_error \
        "The project virtual environment has no usable .venv/bin/python."
      _dev_info "Recreate or synchronize it with: uv sync --all-groups"
    fi
    return 1
  fi
  return 0
}

# tomllib ships with Python 3.11+. Probe at each use because PATH and installed
# interpreters can change during a long-lived interactive shell.
_dev_require_python_toml() {
  if command -v python3 &>/dev/null \
    && command python3 -I -c 'import tomllib' 2>/dev/null; then
    return 0
  fi

  _dev_error "Python 3.11+ with tomllib is required to parse pyproject.toml."
  _dev_info "Install it with: uv python install 3.12 && uv python pin 3.12"
  return 1
}

# Copies a bounded NUL-delimited stream without materializing record limit+1.
# The producer receives a closed pipe as soon as the limit is exceeded.
_dev_project_limit_nul_stream() {
  local label="$1"
  local -i limit="$2"
  local record
  local -i count=0

  while IFS= read -r -d '' record; do
    count=$(( count + 1 ))
    if (( count > limit )); then
      _dev_error "$label exceeds the safe limit of $limit entries."
      return 1
    fi
    print -rn -- "$record"$'\0'
  done
  return 0
}

_dev_project_find_path_pattern() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\*/\\*}"
  value="${value//\?/\\?}"
  value="${value//\[/\\[}"
  REPLY="$value"
}

# Sets `reply` to a bounded set of nested repository roots. Generated and bare
# repository trees are pruned before marker discovery. Status 2 means the
# inventory could not be trusted.
_dev_project_repository_roots() {
  local maximum_records="$1"
  reply=()

  _dev_validate_scan_depth || return 2
  _dev_validate_bounded_integer \
    "project repository limit" "$maximum_records" 1 10000 || return 2
  local -i limit=$(( 10#$maximum_records ))

  local repository_markers=""
  repository_markers=$(
    command find . \
      -mindepth 1 \
      -maxdepth "$DEV_SCAN_DEPTH" \
      \( -type d \( \
        -name '.venv' -o -name 'node_modules' \
        -o -name 'vendor' -o -name 'vendored' \
        -o -name 'build' -o -name 'dist' \
        -o -name '?*.git' \
      \) -prune \) -o \
      \( -name '.git' -print0 -prune \) 2>/dev/null \
      | _dev_project_limit_nul_stream \
        "Nested repository marker inventory" "$limit"
    local -a pipeline_status=("${pipestatus[@]}")
    (( pipeline_status[1] == 0 && pipeline_status[2] == 0 ))
  ) || {
    _dev_error "Could not discover nested repository boundaries."
    return 2
  }

  local -A seen=()
  local marker repository_root
  for marker in ${(0)repository_markers}; do
    [[ -n "$marker" ]] || continue
    repository_root="${marker:h}"
    [[ "$repository_root" != "." ]] || continue
    (( ${+seen[$repository_root]} )) && continue
    seen[$repository_root]=1
    reply+=("$repository_root")
  done
  return 0
}

# Sets `reply` to the find exclusion expression shared by project probes and
# inventories. Nested repository paths are treated as literal find patterns.
_dev_project_exclusions() {
  local -a repository_roots=("$@")
  reply=(
    \( -type d \( \
      -name '.git' -o -name '*.git' \
      -o -name '.venv' -o -name 'node_modules' \
      -o -name 'vendor' -o -name 'vendored' \
      -o -name 'build' -o -name 'dist' \
    \) -prune \) -o
  )

  local repository_root
  for repository_root in "${repository_roots[@]}"; do
    _dev_project_find_path_pattern "$repository_root"
    reply+=(\( -path "$REPLY" -prune \) -o)
  done
}

# Bounded project probe. Status 0 means a match, 1 means no match, and 2 means
# discovery failed. Callers must not turn an I/O error into a clean no-op.
_dev_project_has_files() {
  _dev_validate_scan_depth || return 2
  (( $# > 0 )) || {
    _dev_error "At least one project filename pattern is required."
    return 2
  }

  local -a name_expression=()
  local pattern
  for pattern in "$@"; do
    [[ -n "$pattern" ]] || {
      _dev_error "Project filename patterns must not be empty."
      return 2
    }
    name_expression+=(-name "$pattern" -o)
  done
  name_expression[-1]=()

  local -a reply=()
  _dev_project_repository_roots 512 || return 2
  local -a repository_roots=("${reply[@]}")
  _dev_project_exclusions "${repository_roots[@]}"
  local -a exclusions=("${reply[@]}")

  local found=""
  found=$(command find . -maxdepth "$DEV_SCAN_DEPTH" \
    "${exclusions[@]}" \
    -type f \( "${name_expression[@]}" \) \
    -print -quit 2>/dev/null)
  local -i find_status=$?
  if (( find_status != 0 )); then
    _dev_error "Could not probe project files."
    return 2
  fi
  [[ -n "$found" ]]
}

# Sets `reply` to a bounded, NUL-safe inventory of project files matching any
# supplied name pattern. Generated trees and nested repositories are pruned
# before traversal so the returned scope matches the suite's project probes.
_dev_project_files() {
  local maximum_records="$1"
  shift
  reply=()

  _dev_validate_scan_depth || return 1
  _dev_validate_bounded_integer \
    "project file limit" "$maximum_records" 1 10000 || return 1
  (( $# > 0 )) || {
    _dev_error "At least one project filename pattern is required."
    return 2
  }

  local -a name_expression=()
  local pattern
  for pattern in "$@"; do
    [[ -n "$pattern" ]] || {
      _dev_error "Project filename patterns must not be empty."
      return 2
    }
    name_expression+=(-name "$pattern" -o)
  done
  name_expression[-1]=()

  _dev_project_repository_roots "$maximum_records" || return 1
  local -a repository_roots=("${reply[@]}")
  _dev_project_exclusions "${repository_roots[@]}"
  local -a exclusions=("${reply[@]}")

  local -i limit=$(( 10#$maximum_records ))
  local discovered=""
  discovered=$(
    command find . -maxdepth "$DEV_SCAN_DEPTH" \
      "${exclusions[@]}" \
      -type f \( "${name_expression[@]}" \) -print0 2>/dev/null \
      | _dev_project_limit_nul_stream "Project file inventory" "$limit"
    local -a pipeline_status=("${pipestatus[@]}")
    (( pipeline_status[1] == 0 && pipeline_status[2] == 0 ))
  ) || {
    _dev_error "Could not enumerate project files."
    return 1
  }
  reply=(${(0)discovered})
  return 0
}

# Parses declared dependencies as TOML and compares normalized distribution
# names. This prevents comments and unrelated strings from manufacturing a
# project tool match while still accepting every PEP 503 spelling variant.
#
# Status: 0 when declared, 1 when absent, and 2 when metadata cannot be parsed
# safely. The optional `quiet` mode is reserved for advisory menu annotations.
_dev_pyproject_has_dep() {
  local name="$1"
  local mode="${2:-}"
  local -i quiet=0
  [[ "$mode" == "quiet" ]] && quiet=1
  [[ -e "pyproject.toml" || -L "pyproject.toml" ]] || return 1

  if [[ -z "$name" || ( -n "$mode" && "$mode" != "quiet" ) ]]; then
    (( quiet )) || _dev_error "A valid dependency name is required."
    return 2
  fi

  if (( quiet )); then
    if ! command -v python3 &>/dev/null \
      || ! command python3 -I -c 'import tomllib' 2>/dev/null; then
      return 2
    fi
  else
    _dev_require_python_toml || return 2
  fi

  command python3 -I -c '
import os
import re
import stat
import sys
import tomllib

MAX_PYPROJECT_SIZE = 2 * 1024 * 1024
name_pattern = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$"
)
dependency_pattern = re.compile(
    r"^\s*"
    r"([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)"
    r"(?=\s*(?:\[|\(|@|[<>=!~;]|$))"
)


def normalize(value):
    if not isinstance(value, str) or not name_pattern.fullmatch(value):
        return None
    return re.sub(r"[-_.]+", "-", value).lower()


requested = normalize(sys.argv[1])
if requested is None:
    raise SystemExit(2)

try:
    path = "pyproject.toml"
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)

    path_before = os.lstat(path)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(path_before.st_mode) \
                or not stat.S_ISREG(before.st_mode) \
                or (path_before.st_dev, path_before.st_ino) != (
                    before.st_dev,
                    before.st_ino,
                ):
            raise ValueError
        if before.st_size > MAX_PYPROJECT_SIZE:
            raise SystemExit(4)

        chunks = []
        length = 0
        while length <= MAX_PYPROJECT_SIZE:
            chunk = os.read(
                descriptor,
                min(1024 * 1024, MAX_PYPROJECT_SIZE + 1 - length),
            )
            if not chunk:
                break
            chunks.append(chunk)
            length += len(chunk)

        after = os.fstat(descriptor)
        path_after = os.lstat(path)
        stable_before = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            before.st_mode,
        )
        stable_after = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_mode,
        )
        if length > MAX_PYPROJECT_SIZE:
            raise SystemExit(4)
        if stable_before != stable_after \
                or (path_after.st_dev, path_after.st_ino) != (
                    after.st_dev,
                    after.st_ino,
                ):
            raise ValueError
    finally:
        os.close(descriptor)

    data = tomllib.loads(b"".join(chunks).decode("utf-8"))
except (
        OSError,
        UnicodeError,
        ValueError,
        tomllib.TOMLDecodeError,
):
    raise SystemExit(2)

declared = []
project = data.get("project", {})
if not isinstance(project, dict):
    raise SystemExit(2)

dependencies = project.get("dependencies", [])
if not isinstance(dependencies, list) \
  or any(not isinstance(value, str) for value in dependencies):
    raise SystemExit(2)
declared.extend(dependencies)

optional = project.get("optional-dependencies", {})
if not isinstance(optional, dict):
    raise SystemExit(2)
for dependencies in optional.values():
    if not isinstance(dependencies, list) \
      or any(not isinstance(value, str) for value in dependencies):
        raise SystemExit(2)
    declared.extend(dependencies)

groups = data.get("dependency-groups", {})
if not isinstance(groups, dict):
    raise SystemExit(2)
for dependencies in groups.values():
    if not isinstance(dependencies, list):
        raise SystemExit(2)
    for dependency in dependencies:
        if isinstance(dependency, str):
            declared.append(dependency)
        elif not (
            isinstance(dependency, dict)
            and set(dependency) == {"include-group"}
            and isinstance(dependency["include-group"], str)
        ):
            raise SystemExit(2)

for dependency in declared:
    if not isinstance(dependency, str):
        continue
    match = dependency_pattern.match(dependency)
    if match is not None and normalize(match.group(1)) == requested:
        raise SystemExit(0)

raise SystemExit(3)
' "$name" 2>/dev/null
  local -i parser_status=$?
  case "$parser_status" in
    0) return 0 ;;
    3) return 1 ;;
    4)
      (( quiet )) \
        || _dev_error "Refusing to parse a pyproject.toml larger than 2 MiB."
      return 2
      ;;
    *)
      (( quiet )) \
        || _dev_error "Could not parse dependency metadata in pyproject.toml."
      return 2
      ;;
  esac
}

# --- Remote-code policy -----------------------------------------------------

# uvx/npx fetch and execute the newest published package. Callers use this to
# decide whether an ephemeral runner is permitted for this shell session.
_dev_ephemeral_allowed() {
  _dev_validate_allow_ephemeral || return 2
  [[ "$DEV_ALLOW_EPHEMERAL" == "1" ]]
}

_dev_refuse_ephemeral() {
  local tool_name="$1"
  local install_hint="${2:-}"

  _dev_error \
    "$tool_name is not installed locally and ephemeral execution is disabled."
  _dev_info \
    "Ephemeral runners (uvx/npx) download and execute unverified remote code."
  [[ -n "$install_hint" ]] && _dev_info "Install it locally: $install_hint"
  _dev_info \
    "To allow ephemeral runners for this session: export DEV_ALLOW_EPHEMERAL=1"
  return 1
}

# TLS does not establish artifact integrity. This suite never pipes a remote
# installer into a shell; it prints the officially documented procedure.
_dev_refuse_remote_installer() {
  local tool_name="$1"
  shift

  _dev_error \
    "Refusing to pipe an unverified remote installer for $tool_name to a shell."
  _dev_info "Use a verified installation path instead:"
  local line
  for line in "$@"; do
    _dev_dim "$line"
  done
  return 1
}

# --- Tool runner resolution -------------------------------------------------
# Every quality gate resolves its backend through one of these helpers so the
# fallback order, and the point at which remote code would be executed, is
# identical across the suite.

# Sets `reply` to an exact project-environment executable or isolated Python
# module runner. The executable's resolved object must remain below .venv;
# .venv/bin/python itself may be the normal interpreter symlink created by a
# virtual environment.
#
# The fourth argument describes why the tool is required and controls only the
# diagnostic wording: declared, configured, or required. The optional fifth
# argument is `quiet`, reserved for advisory menu probes.
_dev_exact_project_python_tool_runner() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local tool_name="${1:-}"
  local module_name="${2:-}"
  local install_hint="${3:-uv add --dev $tool_name}"
  local requirement="${4:-required}"
  local mode="${5:-}"
  local -i quiet=0
  [[ "$mode" == "quiet" ]] && quiet=1
  reply=()

  if [[ -z "$tool_name" || -z "$module_name" \
    || "$tool_name" != [a-zA-Z0-9][a-zA-Z0-9_.-]# \
    || "$module_name" != [a-zA-Z_][a-zA-Z0-9_.]# \
    || "$requirement" != (declared|configured|required) \
    || ( -n "$mode" && "$mode" != "quiet" ) ]]; then
    (( quiet )) \
      || _dev_error "A valid project Python tool and module are required."
    return 2
  fi

  if (( quiet )); then
    _dev_require_venv quiet || return 1
  else
    _dev_require_venv || return 1
  fi

  local project_root="${PWD:A}"
  local venv_directory="${project_root}/.venv"
  local tool_executable="${venv_directory}/bin/${tool_name}"
  local resolved_executable=""
  local project_python="${venv_directory}/bin/python"

  # Prefer an isolated module runner when the module has an executable
  # __main__. This avoids trusting a project wrapper whose shebang might
  # resolve python through PATH. Native tools and packages without __main__
  # fall back to their exact in-environment executable below.
  if "$project_python" -I -c \
    'from pathlib import Path
import importlib.util
import sys

name = sys.argv[1]
environment = Path(sys.argv[2]).resolve()
spec = importlib.util.find_spec(name)
if spec is None:
    raise SystemExit(1)


def inside_environment(candidate):
    try:
        Path(candidate).resolve().relative_to(environment)
        return True
    except (OSError, RuntimeError, ValueError):
        return False


if spec.submodule_search_locations is None:
    raise SystemExit(
        spec.origin is None or not inside_environment(spec.origin)
    )
for location in spec.submodule_search_locations:
    main_file = Path(location, "__main__.py")
    if main_file.is_file() and inside_environment(main_file):
        raise SystemExit(0)
raise SystemExit(1)' \
    "$module_name" "$venv_directory" 2>/dev/null; then
    (( quiet )) \
      || _dev_info \
        "Using $module_name from the isolated project virtual environment."
    reply=("$project_python" -I -m "$module_name")
    return 0
  fi

  if [[ -f "$tool_executable" && -x "$tool_executable" ]]; then
    resolved_executable="${tool_executable:A}"
    if [[ -f "$resolved_executable" && -x "$resolved_executable" \
      && "$resolved_executable" == "${venv_directory}/"* ]] \
      && "$project_python" -I -c \
        'import os
import stat
import sys

flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
flags |= getattr(os, "O_NOFOLLOW", 0)
flags |= getattr(os, "O_NONBLOCK", 0)
descriptor = os.open(sys.argv[1], flags)
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit(1)
    header = os.read(descriptor, 4096)
    after = os.fstat(descriptor)
    linked = os.lstat(sys.argv[1])
    if (
        (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        or (linked.st_dev, linked.st_ino) != (after.st_dev, after.st_ino)
    ):
        raise SystemExit(1)
finally:
    os.close(descriptor)

if not header.startswith(b"#!"):
    raise SystemExit(0)
first_line, separator, _ = header.partition(b"\n")
if not separator:
    raise SystemExit(1)
expected = ("#!" + sys.argv[2]).encode()
raise SystemExit(
    first_line != expected and not first_line.startswith(expected + b" ")
)' "$resolved_executable" "$project_python" 2>/dev/null; then
      (( quiet )) \
        || _dev_info "Using the exact project executable: .venv/bin/$tool_name"
      reply=("$resolved_executable")
      return 0
    fi
  fi

  if (( ! quiet )); then
    case "$requirement" in
      declared)
        _dev_error \
          "$tool_name is declared but is not installed in the project virtual environment."
        ;;
      configured)
        _dev_error \
          "$tool_name is configured but is not installed in the project virtual environment."
        ;;
      *)
        _dev_error \
          "$tool_name is required but is not installed in the project virtual environment."
        ;;
    esac
    _dev_info "Synchronize the project environment first: uv sync --all-groups"
    [[ -n "$install_hint" ]] && _dev_info "If it is undeclared, add it with: $install_hint"
  fi
  return 1
}

# Tests whether one module is importable only through the validated project
# interpreter. This never consults PATH, the current directory, PYTHONPATH, or
# the user site. The optional `quiet` mode is for advisory probes.
_dev_project_python_module_available() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local module_name="${1:-}"
  local mode="${2:-}"
  local -i quiet=0
  [[ "$mode" == "quiet" ]] && quiet=1

  if [[ -z "$module_name" \
    || "$module_name" != [a-zA-Z_][a-zA-Z0-9_.]# \
    || ( -n "$mode" && "$mode" != "quiet" ) ]]; then
    (( quiet )) || _dev_error "A valid Python module name is required."
    return 2
  fi

  if (( quiet )); then
    _dev_require_venv quiet || return 1
  else
    _dev_require_venv || return 1
  fi

  local project_python="${PWD:A}/.venv/bin/python"
  "$project_python" -I -c \
    'from pathlib import Path
import importlib.util
import sys

environment = Path(sys.argv[2]).resolve()
spec = importlib.util.find_spec(sys.argv[1])
if spec is None:
    raise SystemExit(1)
candidates = []
if spec.origin is not None:
    candidates.append(spec.origin)
if spec.submodule_search_locations is not None:
    candidates.extend(spec.submodule_search_locations)
for candidate in candidates:
    try:
        Path(candidate).resolve().relative_to(environment)
        raise SystemExit(0)
    except (OSError, RuntimeError, ValueError):
        continue
raise SystemExit(1)' "$module_name" "${PWD:A}/.venv" 2>/dev/null
}

# Sets `reply` to the command prefix for a Python tool.
# Order for a declared dependency: exact project environment only. An
# undeclared tool may use a PATH binary, then the explicitly enabled uvx
# fallback. This prevents uv from finding a global executable for a
# declared-but-unsynchronized dependency.
_dev_python_tool_runner() {
  local tool_name="$1"
  local install_hint="${2:-uv add --dev $tool_name}"
  local module_name="${3:-${tool_name//-/_}}"
  reply=()

  _dev_validate_allow_ephemeral || return 1

  local -i dependency_status=0
  _dev_pyproject_has_dep "$tool_name" || dependency_status=$?
  (( dependency_status == 2 )) && return 1

  if (( dependency_status == 0 )); then
    _dev_exact_project_python_tool_runner \
      "$tool_name" "$module_name" "$install_hint" declared
    return $?
  fi

  if command -v "$tool_name" &>/dev/null; then
    _dev_info "Using the installed $tool_name binary."
    reply=("$tool_name")
    return 0
  fi

  if _dev_ephemeral_allowed; then
    if command -v uvx &>/dev/null; then
      _dev_warn "Running $tool_name through uvx: this downloads remote code."
      reply=(uvx "$tool_name")
      return 0
    fi

    _dev_error \
      "$tool_name is not installed locally and the uvx runner was not found."
    [[ -n "$install_hint" ]] && _dev_info "Install it locally: $install_hint"
    return 1
  fi

  _dev_refuse_ephemeral "$tool_name" "$install_hint"
}

# Sets `reply` to an installed-environment inventory command. Unlike quality
# gates, inventory tools must inspect this project's environment and therefore
# may never fall back to an arbitrary global binary or an overlay environment.
# The module must already be installed in this project's .venv; adding the
# inventory tool ephemerally would contaminate the inventory being measured.
_dev_project_python_tool_runner() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local tool_name="${1:-}"
  local module_name="${2:-}"
  local install_hint="${3:-uv add --dev $tool_name}"
  reply=()

  if [[ -z "$tool_name" || -z "$module_name" \
    || "$tool_name" != [a-zA-Z0-9][a-zA-Z0-9_.-]# \
    || "$module_name" != [a-zA-Z_][a-zA-Z0-9_.]# ]]; then
    _dev_error "A valid tool and Python module are required."
    return 2
  fi

  _dev_require_venv || return 1

  local project_python="${PWD:A}/.venv/bin/python"
  if "$project_python" -I -c \
      'from pathlib import Path
import importlib.util
import sys

environment = Path(sys.argv[2]).resolve()
spec = importlib.util.find_spec(sys.argv[1])
if spec is None:
    raise SystemExit(1)
candidates = []
if spec.origin is not None:
    candidates.append(spec.origin)
if spec.submodule_search_locations is not None:
    candidates.extend(spec.submodule_search_locations)
for candidate in candidates:
    try:
        Path(candidate).resolve().relative_to(environment)
        raise SystemExit(0)
    except (OSError, RuntimeError, ValueError):
        continue
raise SystemExit(1)' "$module_name" "${PWD:A}/.venv" 2>/dev/null; then
    _dev_info "Using $module_name from the isolated project virtual environment."
    reply=("$project_python" -I -m "$module_name")
    return 0
  fi

  local -i dependency_status=0
  _dev_pyproject_has_dep "$tool_name" || dependency_status=$?
  (( dependency_status == 2 )) && return 1

  if (( dependency_status == 0 )); then
    _dev_error \
      "$tool_name is declared but is not importable from the project virtual environment."
    _dev_info "Synchronize the declared environment first: uv sync --all-groups"
  else
    _dev_error \
      "$tool_name is not installed in the project virtual environment."
    _dev_info "Install it into the project environment: $install_hint"
  fi
  _dev_info \
    "Ephemeral runners are disabled for installed-environment inventories."
  return 1
}

# Sets `reply` to the command prefix for a Node tool.
# Order: project node_modules -> local binary -> ephemeral npx.
# Selecting node_modules avoids the npx fallback, but the project-controlled
# executable can still run code or perform its own network and file effects.
_dev_node_tool_runner() {
  local tool_name="$1"
  local package_name="${2:-$tool_name}"
  reply=()

  _dev_validate_allow_ephemeral || return 1

  if [[ -x "./node_modules/.bin/${tool_name}" ]]; then
    _dev_info "Using the project dependency (node_modules/.bin/$tool_name)."
    reply=("./node_modules/.bin/${tool_name}")
    return 0
  fi

  if command -v "$tool_name" &>/dev/null; then
    _dev_info "Using the installed $tool_name binary."
    reply=("$tool_name")
    return 0
  fi

  if command -v npx &>/dev/null && _dev_ephemeral_allowed; then
    _dev_warn "Running $package_name through npx: this downloads remote code."
    reply=(npx --yes "$package_name")
    return 0
  fi

  _dev_refuse_ephemeral "$tool_name" "npm install --save-dev $package_name"
}

# --- Diff rendering ---------------------------------------------------------

_dev_show_diff() {
  local file_name="$1"
  command -v git &>/dev/null || return 0

  if command -v delta &>/dev/null; then
    command git diff --no-color -- "$file_name" 2>/dev/null \
      | command delta --paging=never >&2
  elif command -v bat &>/dev/null; then
    command git diff --no-color -- "$file_name" 2>/dev/null \
      | command bat -l diff --plain --paging=never >&2
  else
    command git diff --no-color -- "$file_name" >&2
  fi
}

# --- Spinner ----------------------------------------------------------------
# Inline progress indicator for bounded, long-running network work.

typeset -g _DEV_SPINNER_PID=""

_dev_spinner_start() {
  setopt LOCAL_OPTIONS NO_MONITOR

  # A spinner is UI. Without a terminal on stderr it would corrupt captured
  # output, so it degrades to a single status line.
  if ! _dev_color_enabled; then
    _dev_info "${1:-Working}..."
    return 0
  fi

  local message="${1:-Working}"
  (
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local -i index=0
    while true; do
      printf '\r\033[0;36m  %s %s...\033[0m' \
        "${frames:$(( index % ${#frames} )):1}" "$message" >&2
      index=$(( index + 1 ))
      sleep 0.1
    done
  ) &
  _DEV_SPINNER_PID=$!
  disown "$_DEV_SPINNER_PID" 2>/dev/null
}

_dev_spinner_stop() {
  setopt LOCAL_OPTIONS NO_MONITOR
  [[ -n "$_DEV_SPINNER_PID" ]] || return 0

  builtin kill "$_DEV_SPINNER_PID" 2>/dev/null
  wait "$_DEV_SPINNER_PID" 2>/dev/null
  _DEV_SPINNER_PID=""
  _dev_color_enabled && printf '\r\033[K' >&2
  return 0
}

# --- Path boundary safety ---------------------------------------------------

# Resolves the directory a recursive cleanup may traverse. Protected roots are
# refused before any target is calculated.
_dev_scan_root() {
  local root="${PWD:A}"

  if [[ -z "$root" || "$root" == "/" ]]; then
    _dev_error "Refusing to run a recursive cleanup at the filesystem root."
    return 1
  fi

  if [[ "$root" == "${HOME:A}" ]]; then
    _dev_error \
      "Refusing to run a recursive cleanup directly in the home directory."
    _dev_info "Change into a project directory first."
    return 1
  fi

  # The installed suite tree is deliberately NOT protected here. It holds no
  # data these patterns match, and refusing it would stop the ZDX repository
  # from using its own tooling. The real hazards are the two roots above.
  print -r -- "$root"
}

# Proves a candidate path is the base itself or a descendant of it.
_dev_within_root() {
  local base="${1:A}"
  local candidate="${2:A}"

  [[ -n "$base" && -n "$candidate" ]] || return 1
  [[ "$candidate" == "$base" || "$candidate" == "$base"/* ]]
}

# --- Command metadata -------------------------------------------------------

# External binaries a command cannot run without. Commands that resolve their
# own backend at runtime (ruff, bandit, markdownlint) are deliberately absent:
# their public contract documents an ordered fallback chain instead.
# Aggregates have no blanket dependency: each applicable child checks its own
# backend, so an unavailable tool cannot block unrelated maintenance steps.
_dev_cmd_deps() {
  local command_name="${1:-}"
  local output_mode="${2:-stdout}"
  local dependencies=""

  case "$command_name" in
    dev-update-deps|dev-update-deps-dry) dependencies="uv,curl,python3" ;;
    dev-update-lock)          dependencies="uv" ;;
    dev-update-precommit)     dependencies="uv" ;;
    dev-update-terraform)     dependencies="terraform" ;;
    dev-update-tflint)        dependencies="tflint" ;;
    dev-check-outdated)       dependencies="uv,python3" ;;
    dev-run-tflint)           dependencies="tflint" ;;
    dev-run-clippy)           dependencies="cargo" ;;
    dev-export-deps)          dependencies="uv" ;;
    dev-profile-save)         dependencies="fzf" ;;
  esac

  REPLY="$dependencies"
  case "$output_mode" in
    stdout) print -r -- "$dependencies" ;;
    reply) ;;
    *)
      _dev_error "Invalid command-dependency output mode."
      return 2
      ;;
  esac
}

# Commands exposed by --multi and the profile-save picker. This allowlist is
# deliberately narrower than the dispatcher: entries must be independent,
# eligible with no arguments, and free of nested orchestration or environment
# lifecycle changes. Eligibility does not imply that project-controlled tools
# cannot execute code or create their documented artifacts.
_dev_command_batch_safe() {
  case "$1" in
    dev-check-health|dev-check-outdated|dev-check-licenses\
      |dev-run-ruff|dev-run-ty|dev-run-pyright\
      |dev-run-eslint|dev-run-prettier|dev-run-clippy\
      |dev-run-shellcheck|dev-run-markdownlint|dev-run-tflint\
      |dev-run-tests|dev-run-audit|dev-run-bandit\
      |dev-update-deps-dry)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Dependency-aware read-only availability probe. Menu rendering deliberately
# uses cheaper path-only helpers below; authoritative runner resolution remains
# inside the public command after argument parsing.
_dev_python_tool_available() {
  local tool_name="$1"
  local module_name="${2:-${tool_name//-/_}}"

  local -i dependency_status=0
  _dev_pyproject_has_dep "$tool_name" quiet || dependency_status=$?
  (( dependency_status == 2 )) && return 1

  if (( dependency_status == 0 )); then
    local -a reply=()
    _dev_exact_project_python_tool_runner \
      "$tool_name" "$module_name" "" declared quiet
    return $?
  fi
  command -v "$tool_name" &>/dev/null && return 0
  [[ "$DEV_ALLOW_EPHEMERAL" == "1" ]] && command -v uvx &>/dev/null
}

_dev_project_python_tool_available() {
  local tool_name="${1:-}"
  local module_name="${2:-}"
  [[ -n "$tool_name" ]] || return 1
  _dev_project_python_module_available "$module_name" quiet
}

_dev_node_tool_available() {
  local tool_name="$1"

  [[ -x "./node_modules/.bin/${tool_name}" ]] && return 0
  command -v "$tool_name" &>/dev/null && return 0
  [[ "$DEV_ALLOW_EPHEMERAL" == "1" ]] && command -v npx &>/dev/null
}

# Caches status-only menu probes when _dev_menu_rows provides its dynamically
# scoped associative cache. Outside one render, probes stay live so PATH and
# project state changes remain visible in long-lived shells.
_dev_menu_cached_probe() {
  local cache_key="${1:-}"
  shift

  local -i cache_active=0
  if (( ${+_dev_menu_probe_cache} )) \
    && [[ "${(t)_dev_menu_probe_cache}" == association* ]]; then
    cache_active=1
  fi

  if (( cache_active && ${+_dev_menu_probe_cache[$cache_key]} )); then
    return "${_dev_menu_probe_cache[$cache_key]}"
  fi

  local -i probe_status=0
  "$@" || probe_status=$?
  if (( cache_active )); then
    _dev_menu_probe_cache[$cache_key]="$probe_status"
  fi
  return "$probe_status"
}

_dev_menu_probe_command() {
  command -v "$1" &>/dev/null
}

_dev_menu_command_available() {
  local command_name="$1"
  _dev_menu_cached_probe \
    "command:${command_name}" _dev_menu_probe_command "$command_name"
}

_dev_menu_probe_project_venv() {
  local project_root="${PWD:A}"
  local venv_directory="${project_root}/.venv"

  [[ -d "$venv_directory" && ! -L "$venv_directory" \
    && "${venv_directory:a}" == "${venv_directory:A}" ]]
}

_dev_menu_project_venv_available() {
  _dev_menu_cached_probe \
    "path:project-venv" _dev_menu_probe_project_venv
}

# Advisory menu probes never execute project code. A project-local executable
# is considered available only when .venv/bin is a real directory and the
# executable resolves back inside that same project environment.
_dev_menu_probe_project_executable() {
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local tool_name="${1:-}"
  [[ "$tool_name" == [a-zA-Z0-9][a-zA-Z0-9_.-]# ]] || return 1
  _dev_menu_project_venv_available || return 1

  local project_root="${PWD:A}"
  local venv_directory="${project_root}/.venv"
  local bin_directory="${venv_directory}/bin"
  local candidate="${bin_directory}/${tool_name}"
  local resolved_candidate=""

  [[ -d "$bin_directory" && ! -L "$bin_directory" \
    && "${bin_directory:A}" == "${venv_directory}/bin" \
    && -f "$candidate" && -x "$candidate" ]] || return 1

  resolved_candidate="${candidate:A}"
  [[ -f "$resolved_candidate" && -x "$resolved_candidate" \
    && "$resolved_candidate" == "${venv_directory}/"* ]]
}

_dev_menu_project_executable_available() {
  local tool_name="$1"
  _dev_menu_cached_probe \
    "path:project-executable:${tool_name}" \
    _dev_menu_probe_project_executable "$tool_name"
}

_dev_menu_python_tool_available_shallow() {
  local tool_name="$1"

  _dev_menu_project_executable_available "$tool_name" && return 0
  _dev_menu_command_available "$tool_name" && return 0
  [[ "$DEV_ALLOW_EPHEMERAL" == "1" ]] \
    && _dev_menu_command_available uvx
}

# Human-readable, comma-separated list of shallow unmet requirements for a
# command. Advisory probes inspect commands and bounded paths only; each public
# command performs authoritative metadata and environment checks after its
# argument parser accepts the invocation. The optional `reply` mode sets REPLY
# instead of writing the list, avoiding a per-row subshell while preserving the
# default stdout API.
_dev_menu_missing_requirements() {
  local command_name="$1"
  local output_mode="${2:-stdout}"
  local -a missing=()
  local deps dep

  _dev_cmd_deps "$command_name" reply || return $?
  deps="$REPLY"
  if [[ -n "$deps" ]]; then
    for dep in ${(s:,:)deps}; do
      _dev_menu_command_available "$dep" || missing+=("$dep")
    done
  fi

  case "$command_name" in
    dev-run-eslint|dev-run-prettier|dev-run-markdownlint)
      local tool_name="${command_name#dev-run-}"
      if ! _dev_menu_cached_probe \
        "node-tool:${tool_name}" _dev_node_tool_available "$tool_name"; then
        missing+=("$tool_name (project/local or ephemeral opt-in)")
      fi
      ;;
    dev-run-ty|dev-run-pyright)
      local tool_name="${command_name#dev-run-}"
      if ! _dev_menu_python_tool_available_shallow "$tool_name"; then
        missing+=("$tool_name (project/local or ephemeral opt-in)")
      fi
      ;;
    dev-run-ruff|dev-run-ruff-format)
      if ! _dev_menu_python_tool_available_shallow ruff; then
        missing+=("ruff (project/local or ephemeral opt-in)")
      fi
      ;;
    dev-check-licenses)
      if ! _dev_menu_project_executable_available pip-licenses; then
        missing+=("pip-licenses (installed in .venv)")
      fi
      ;;
    dev-run-audit)
      if ! _dev_menu_project_executable_available pip-audit; then
        missing+=("pip-audit (installed in .venv)")
      fi
      ;;
    dev-run-bandit)
      if ! _dev_menu_python_tool_available_shallow bandit; then
        missing+=("bandit (project/local or ephemeral opt-in)")
      fi
      ;;
    dev-run-hooks)
      if ! _dev_menu_project_executable_available pre-commit; then
        missing+=("pre-commit (installed in .venv)")
      fi
      ;;
    dev-run-tests)
      if ! _dev_menu_project_executable_available pytest; then
        missing+=("pytest (installed in .venv)")
      fi
      ;;
    dev-run-coverage)
      if ! _dev_menu_project_executable_available pytest; then
        missing+=("pytest (installed in .venv)")
      fi
      if ! _dev_menu_project_executable_available coverage; then
        missing+=("pytest-cov or coverage (installed in .venv)")
      fi
      ;;
    dev-build-package)
      if ! _dev_menu_command_available uv \
        && ! _dev_menu_command_available python3; then
        missing+=("uv or python3")
      fi
      ;;
    dev-update-python)
      if _dev_menu_project_venv_available \
        && ! _dev_menu_command_available uv; then
        missing+=("uv")
      fi
      ;;
    venv-python-list|venv-python-install|venv-python-pin)
      _dev_menu_command_available uv || missing+=("uv")
      ;;
  esac

  local missing_text="${(j:, :)missing}"
  REPLY="$missing_text"
  case "$output_mode" in
    stdout)
      [[ -n "$missing_text" ]] && print -r -- "$missing_text"
      ;;
    reply) ;;
    *)
      _dev_error "Invalid menu-requirement output mode."
      return 2
      ;;
  esac
  return 0
}

# Authoritative dependency gate. Never prompts: a missing dependency is
# reported with a safe next step and the command fails closed.
_dev_verify_deps() {
  local command_name="$1"
  local deps dep
  local -a missing=()

  deps=$(_dev_cmd_deps "$command_name")
  [[ -z "$deps" ]] && return 0

  for dep in ${(s:,:)deps}; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
  done

  (( ${#missing[@]} == 0 )) && return 0

  _dev_error \
    "Missing required dependency: ${(j:, :)missing} to run '$command_name'"
  _dev_info "Install ${(j:, :)missing} with the package manager for this host."
  return 1
}

# --- Menu helpers (canonical: args = output positions) -----------------------

_dev_menu_validate_fields() {
  local field
  for field in "$@"; do
    if [[ "$field" == *'|'* || "$field" == *$'\n'* \
      || "$field" == *$'\0'* ]]; then
      _dev_error \
        "Invalid menu field: pipe, newline, and NUL characters are not allowed."
      return 2
    fi
  done
}

_dev_menu_section() {
  (( $# >= 1 && $# <= 2 )) || {
    _dev_error "A menu section requires a title and optional description."
    return 2
  }

  local title="${1:-}"
  local description="${2:-}"
  [[ -n "$title" ]] || {
    _dev_error "A menu section title cannot be empty."
    return 2
  }
  _dev_menu_validate_fields "$title" "$description" || return $?

  printf "── %s ──|:|%s\n" "$title" "$description"
}

_dev_menu_entry() {
  (( $# == 3 )) || {
    _dev_error "A menu entry requires label, command, and description fields."
    return 2
  }

  local label="${1:-}"
  local command_name="${2:-}"
  local description="${3:-}"
  if [[ -z "$label" || -z "$command_name" || -z "$description" ]]; then
    _dev_error "Menu entry fields cannot be empty."
    return 2
  fi
  _dev_menu_validate_fields "$label" "$command_name" "$description" || return $?

  local REPLY
  _dev_menu_missing_requirements "$command_name" reply || return $?
  local missing="$REPLY"

  if [[ -n "$missing" ]]; then
    printf "  %s (missing: %s)|%s|%s\n" \
      "$label" "$missing" "$command_name" "$description"
  else
    printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
  fi
}

# --- fzf preset for the dev suite -------------------------------------------
# Options are constructed at invocation time so a standalone source never
# evaluates the core theme helper and configuration stays live.

_dev_fzf() {
  local -a fzf_arguments=(
    --height=80%
    --layout=reverse
    --border=rounded
    --delimiter='[|]'
    --with-nth=1
    --pointer='▶'
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac'
    --preview-window='down:4:wrap'
  )

  fzf_arguments+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')

  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && fzf_arguments+=("$theme_option")
  fi

  # Compatibility settings are local to this picker and never change the shell.
  local -a terminal_options=()
  local terminal_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
  if [[ -n "${ZDX_FZF_PLAIN:-}" || "$terminal_locale" == C \
    || "$terminal_locale" == POSIX || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-unicode '--pointer=>' '--marker=+')
  fi
  if [[ -n "${NO_COLOR:-}" || -n "${ZDX_FZF_PLAIN:-}" \
    || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-color)
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh fzf "${fzf_arguments[@]}" "$@" "${terminal_options[@]}"
}

_dev_fzf_rc_is_cancel() {
  (( $1 == 1 || $1 == 130 ))
}

# Validates a picker temporary root: an absolute, canonical, non-symlink
# directory owned by the current user without group/world write access, or a
# root-owned sticky shared directory such as /tmp. REPLY holds the result.
_dev_temp_parent_safe() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local temp_parent="${1:-}"
  REPLY=""

  while [[ "$temp_parent" != "/" && "$temp_parent" == */ ]]; do
    temp_parent="${temp_parent%/}"
  done
  [[ -n "$temp_parent" && "$temp_parent" == /* \
    && "$temp_parent" == "${temp_parent:a}" \
    && "$temp_parent" == "${temp_parent:A}" \
    && -d "$temp_parent" && ! -L "$temp_parent" ]] || return 1

  local -A root_state=() parent_state=()
  zstat -LH root_state -- / 2>/dev/null \
    && zstat -LH parent_state -- "$temp_parent" 2>/dev/null || return 1
  if (( parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )); then
    :
  elif (( parent_state[uid] == root_state[uid] \
    && (parent_state[mode] & 8#1000) != 0 \
    && (parent_state[mode] & 8#2) != 0 )); then
    :
  else
    return 1
  fi
  REPLY="$temp_parent"
}

# Run fzf synchronously in the terminal foreground and capture only its
# selection stdout in one private, bounded, invocation-owned result file.
# REPLY holds the selection; the exact fzf status is returned, and a failed
# picker cannot carry selection data.
_dev_fzf_capture() {
  emulate -L zsh
  REPLY=""
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _dev_error "Zsh file-descriptor support is required for Dev pickers."
    return 125
  }
  _dev_temp_parent_safe "${TMPDIR:-/tmp}" || {
    _dev_error "Refusing an unsafe temporary root for Dev pickers."
    return 125
  }
  local temp_parent="$REPLY"

  local picker_result_file=""
  picker_result_file=$(umask 077; command mktemp \
    "${temp_parent%/}/zdx-dev-fzf.XXXXXX" 2>/dev/null) || {
    _dev_error "Could not create a private Dev picker result."
    return 125
  }

  local selection="" file_identity=""
  local -i write_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A file_state=() current_file_state=()

  {
    if [[ "$picker_result_file" != "${picker_result_file:a}" \
      || "$picker_result_file" != "${picker_result_file:A}" \
      || "${picker_result_file:h}" != "$temp_parent" \
      || "${picker_result_file:t}" != zdx-dev-fzf.* \
      || ! -f "$picker_result_file" || -L "$picker_result_file" ]] \
      || ! zstat -LH file_state -- "$picker_result_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 \
        || (file_state[mode] & 8#170000) != 8#100000 \
        || file_state[size] != 0 )); then
      _dev_error "Refusing an unsafe Dev picker result."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:"\
"${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$picker_result_file" 2>/dev/null; then
        _dev_error "Could not open the Dev picker result safely."
      else
        # Cap regular-file growth while fzf is writing, not only before the
        # later read. The synchronous subshell remains in the foreground and
        # the picker status (including SIGXFSZ) is preserved exactly.
        (
          # Apply the limit to this disposable shell as well as its children.
          # Lowering both soft and hard limits prevents a selected executable
          # from raising the soft limit before it writes.
          limit -s filesize 64k || return 125
          limit -hs filesize 64k || return 125
          _dev_fzf "$@"
        ) 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_file_state -- "$picker_result_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:"\
"${current_file_state[inode]}:${current_file_state[mode]}:"\
"${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > 65536 )); then
          _dev_error "The Dev picker result changed or exceeded its limit."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$picker_result_file" 2>/dev/null; then
          _dev_error "Could not read the Dev picker result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _dev_error "A failed Dev picker returned unexpected data."
            selection=""
            operation_rc=$fzf_rc
          else
            operation_rc=$fzf_rc
          fi
        fi
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    current_file_state=()
    if [[ -n "$file_identity" \
      && -f "$picker_result_file" && ! -L "$picker_result_file" \
      && "${picker_result_file:h}" == "$temp_parent" ]] \
      && zstat -LH current_file_state -- "$picker_result_file" 2>/dev/null \
      && [[ "${current_file_state[device]}:"\
"${current_file_state[inode]}:${current_file_state[mode]}:"\
"${current_file_state[uid]}:${current_file_state[nlink]}" \
        == "$file_identity" ]]; then
      command rm -f -- "$picker_result_file" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

# --- Delegation to owning suites --------------------------------------------
# Virtual environment and Python runtime lifecycle is owned by the py suite.
# The dev suite keeps discoverable entries that forward to the owner rather
# than maintaining a second implementation.

_dev_delegate_py() {
  local command_name="$1"
  shift

  if ! typeset -f py-menu &>/dev/null; then
    _dev_error "py-menu is unavailable; cannot delegate '$command_name'."
    return 1
  fi

  _dev_debug "Delegating $command_name to the py suite."
  py-menu "$command_name" "$@"
}

# Host package and tool lifecycle is owned by the sys suite. Dev forwards only
# narrowly scoped public operations and never sources sys-private helpers.
_dev_delegate_sys() {
  local command_name="$1"
  shift

  if ! typeset -f sys-menu &>/dev/null; then
    _dev_error "sys-menu is unavailable; cannot delegate '$command_name'."
    return 1
  fi

  _dev_debug "Delegating $command_name to the sys suite."
  sys-menu "$command_name" "$@"
}

# Docker lifecycle is owned by the docker suite. These tokens remain only as
# deprecated compatibility bridges and are not part of the dev menu.
_dev_delegate_docker() {
  local command_name="$1"
  shift

  _dev_warn \
    "'$command_name' is deprecated in the dev suite; Docker cleanup is owned by docker-menu."
  _dev_info "Use: docker-menu docker-clean"

  if ! typeset -f docker-menu &>/dev/null; then
    _dev_error "docker-menu is unavailable; cannot delegate '$command_name'."
    return 1
  fi

  docker-menu docker-clean "$@"
}

# Emits a single deprecation notice per shell session per alias so scripted
# callers are informed without flooding interactive output.
typeset -gA _DEV_DEPRECATION_SEEN=()

_dev_deprecated_alias() {
  local old_name="$1"
  local new_name="$2"

  if [[ -z "${_DEV_DEPRECATION_SEEN[$old_name]:-}" ]]; then
    _DEV_DEPRECATION_SEEN[$old_name]=1
    _dev_warn "'$old_name' is deprecated; use '$new_name' instead."
  fi
  return 0
}

# --- Dispatch (case-based; arms ARE the allowlist) --------------------------

_dev_dispatch_deprecated() {
  local old_name="$1"
  local canonical_name="$2"
  shift 2

  _dev_deprecated_alias "$old_name" "$canonical_name"
  _dev_dispatch "$canonical_name" "$@"
}

_dev_dispatch() {
  emulate -L zsh

  local command_name="${1:-}"
  (( $# > 0 )) && shift

  # Dynamically visible to _dev_require_command. The public command parses
  # first, then its first operational dependency request runs metadata checks
  # once for this dispatch.
  local _DEV_DISPATCH_COMMAND="$command_name"
  local -i _DEV_DISPATCH_DEPS_CHECKED=0

  case "$command_name" in
    # --- Inspection ---------------------------------------------------------
    dev-check-health) dev-check-health "$@" ;;
    dev-check-outdated) dev-check-outdated "$@" ;;
    dev-check-licenses) dev-check-licenses "$@" ;;

    # --- Quality gates ------------------------------------------------------
    dev-run-all-checks) dev-run-all-checks "$@" ;;
    dev-run-hooks) dev-run-hooks "$@" ;;
    dev-check-types) dev-check-types "$@" ;;
    dev-run-ruff) dev-run-ruff "$@" ;;
    dev-run-ruff-format) dev-run-ruff-format "$@" ;;
    dev-run-ty) dev-run-ty "$@" ;;
    dev-run-pyright) dev-run-pyright "$@" ;;
    dev-run-eslint) dev-run-eslint "$@" ;;
    dev-run-prettier) dev-run-prettier "$@" ;;
    dev-run-clippy) dev-run-clippy "$@" ;;
    dev-run-shellcheck) dev-run-shellcheck "$@" ;;
    dev-run-markdownlint) dev-run-markdownlint "$@" ;;
    dev-run-tflint) dev-run-tflint "$@" ;;

    # --- Tests --------------------------------------------------------------
    dev-run-tests) dev-run-tests "$@" ;;
    dev-run-coverage) dev-run-coverage "$@" ;;

    # --- Security -----------------------------------------------------------
    dev-run-audit) dev-run-audit "$@" ;;
    dev-run-bandit) dev-run-bandit "$@" ;;

    # --- Dependencies and toolchain -----------------------------------------
    dev-update-deps-dry) dev-update-deps-dry "$@" ;;
    dev-update-deps) dev-update-deps "$@" ;;
    dev-update-lock) dev-update-lock "$@" ;;
    dev-update-precommit) dev-update-precommit "$@" ;;
    dev-update-toolchain) dev-update-toolchain "$@" ;;
    dev-update-python) dev-update-python "$@" ;;
    dev-update-terraform) dev-update-terraform "$@" ;;
    dev-update-tflint) dev-update-tflint "$@" ;;

    # --- Packaging and export -----------------------------------------------
    dev-export-deps) dev-export-deps "$@" ;;
    dev-build-package) dev-build-package "$@" ;;
    dev-backup-pyproject) dev-backup-pyproject "$@" ;;

    # --- Python environments (owned by the py suite) ------------------------
    venv-list|venv-create|venv-activate|venv-info|venv-rebuild|venv-remove\
      |venv-python-list|venv-python-install|venv-python-pin)
      _dev_delegate_py "$command_name" "$@" ;;

    # --- Task profiles ------------------------------------------------------
    dev-profile-run) dev-profile-run "$@" ;;
    dev-profile-save) dev-profile-save "$@" ;;
    dev-profile-list) dev-profile-list "$@" ;;
    dev-profile-delete) dev-profile-delete "$@" ;;

    # --- Destructive maintenance --------------------------------------------
    dev-clean-py) dev-clean-py "$@" ;;
    dev-clean-repo) dev-clean-repo "$@" ;;
    dev-clean-terraform) dev-clean-terraform "$@" ;;
    dev-clean-all) dev-clean-all "$@" ;;
    dev-update-all) dev-update-all "$@" ;;

    # --- Deprecated compatibility tokens ------------------------------------
    # Not part of the menu, help, or completion surfaces. Each forwards to its
    # canonical owner and is scheduled for removal in v0.3.0.
    update-all)
      _dev_dispatch_deprecated update-all dev-update-all "$@" ;;
    update-deps)
      _dev_dispatch_deprecated update-deps dev-update-deps "$@" ;;
    update-deps-dry)
      _dev_dispatch_deprecated update-deps-dry dev-update-deps-dry "$@" ;;
    update-lock)
      _dev_dispatch_deprecated update-lock dev-update-lock "$@" ;;
    update-precommit)
      _dev_dispatch_deprecated update-precommit dev-update-precommit "$@" ;;
    update-terraform)
      _dev_dispatch_deprecated update-terraform dev-update-terraform "$@" ;;
    update-tflint)
      _dev_dispatch_deprecated update-tflint dev-update-tflint "$@" ;;
    update-toolchain)
      _dev_dispatch_deprecated update-toolchain dev-update-toolchain "$@" ;;
    update-python)
      _dev_dispatch_deprecated update-python dev-update-python "$@" ;;
    check-outdated)
      _dev_dispatch_deprecated check-outdated dev-check-outdated "$@" ;;
    check-health)
      _dev_dispatch_deprecated check-health dev-check-health "$@" ;;
    check-licenses)
      _dev_dispatch_deprecated check-licenses dev-check-licenses "$@" ;;
    check-types)
      _dev_dispatch_deprecated check-types dev-check-types "$@" ;;
    run-hooks)
      _dev_dispatch_deprecated run-hooks dev-run-hooks "$@" ;;
    run-ruff)
      _dev_dispatch_deprecated run-ruff dev-run-ruff "$@" ;;
    run-ruff-format)
      _dev_dispatch_deprecated run-ruff-format dev-run-ruff-format "$@" ;;
    run-ty)
      _dev_dispatch_deprecated run-ty dev-run-ty "$@" ;;
    run-pyright)
      _dev_dispatch_deprecated run-pyright dev-run-pyright "$@" ;;
    run-tflint)
      _dev_dispatch_deprecated run-tflint dev-run-tflint "$@" ;;
    run-markdownlint)
      _dev_dispatch_deprecated run-markdownlint dev-run-markdownlint "$@" ;;
    run-eslint)
      _dev_dispatch_deprecated run-eslint dev-run-eslint "$@" ;;
    run-prettier)
      _dev_dispatch_deprecated run-prettier dev-run-prettier "$@" ;;
    run-clippy)
      _dev_dispatch_deprecated run-clippy dev-run-clippy "$@" ;;
    run-shellcheck)
      _dev_dispatch_deprecated run-shellcheck dev-run-shellcheck "$@" ;;
    run-all-checks)
      _dev_dispatch_deprecated run-all-checks dev-run-all-checks "$@" ;;
    run-tests)
      _dev_dispatch_deprecated run-tests dev-run-tests "$@" ;;
    run-coverage)
      _dev_dispatch_deprecated run-coverage dev-run-coverage "$@" ;;
    run-audit)
      _dev_dispatch_deprecated run-audit dev-run-audit "$@" ;;
    run-bandit)
      _dev_dispatch_deprecated run-bandit dev-run-bandit "$@" ;;
    clean-py)
      _dev_dispatch_deprecated clean-py dev-clean-py "$@" ;;
    clean-repo)
      _dev_dispatch_deprecated clean-repo dev-clean-repo "$@" ;;
    clean-terraform)
      _dev_dispatch_deprecated clean-terraform dev-clean-terraform "$@" ;;
    clean-all)
      _dev_dispatch_deprecated clean-all dev-clean-all "$@" ;;
    export-deps)
      _dev_dispatch_deprecated export-deps dev-export-deps "$@" ;;
    build-package)
      _dev_dispatch_deprecated build-package dev-build-package "$@" ;;
    backup-pyproject)
      _dev_dispatch_deprecated \
        backup-pyproject dev-backup-pyproject "$@" ;;
    profile-save)
      _dev_dispatch_deprecated profile-save dev-profile-save "$@" ;;
    profile-list)
      _dev_dispatch_deprecated profile-list dev-profile-list "$@" ;;
    profile-delete)
      _dev_dispatch_deprecated profile-delete dev-profile-delete "$@" ;;
    venv-python)
      _dev_deprecated_alias venv-python "py-menu venv-python"
      _dev_delegate_py venv-python "$@"
      ;;
    clean-docker)        _dev_delegate_docker clean-docker "$@" ;;
    docker-prune-all)    _dev_delegate_docker docker-prune-all "$@" ;;

    :) return 0 ;;
    *)
      _dev_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

# --- Infrastructure tool ownership detection -------------------------------
# Kept local to the dev suite: a suite must not source another suite's private
# helpers to obtain generic behavior.

_dev_terraform_resolved_path() {
  local terraform_bin
  terraform_bin=$(command -v terraform 2>/dev/null) || return 1
  local resolved_path="${terraform_bin:A}"
  [[ "$terraform_bin" == /* && -f "$resolved_path" \
    && -x "$resolved_path" ]] || return 1
  print -r -- "$resolved_path"
}

_dev_tfenv_resolved_path() {
  local tfenv_bin
  tfenv_bin=$(command -v tfenv 2>/dev/null) || return 1
  local resolved_path="${tfenv_bin:A}"
  [[ "$tfenv_bin" == /* && -f "$resolved_path" \
    && -x "$resolved_path" && "${resolved_path:t}" == "tfenv" ]] || return 1
  print -r -- "$resolved_path"
}

_dev_tflint_resolved_path() {
  local tflint_bin
  tflint_bin=$(command -v tflint 2>/dev/null) || return 1
  local resolved_path="${tflint_bin:A}"
  [[ "$tflint_bin" == /* && -f "$resolved_path" \
    && -x "$resolved_path" ]] || return 1
  print -r -- "$resolved_path"
}

_dev_detect_terraform_manager() {
  command -v terraform &>/dev/null || return 1

  local resolved_path=""
  resolved_path=$(_dev_terraform_resolved_path 2>/dev/null)

  # tfenv installs canonical `tfenv` and `terraform` sibling launchers. Bind
  # the claim to that resolved pair rather than the caller-controlled
  # TFENV_ROOT environment variable.
  local tfenv_path=""
  if tfenv_path=$(_dev_tfenv_resolved_path 2>/dev/null) \
    && [[ -n "$resolved_path" \
      && "$resolved_path" == "${tfenv_path:h}/terraform" ]]; then
    print -r -- "tfenv"
    return 0
  fi

  if command -v brew &>/dev/null; then
    local brew_prefix
    brew_prefix=$(command brew --prefix 2>/dev/null)
    if [[ -n "$brew_prefix" && -n "$resolved_path" ]]; then
      if [[ "$resolved_path" == \
          ${brew_prefix:A}/Cellar/terraform/*/bin/terraform ]] \
        || [[ "$resolved_path" == \
          ${brew_prefix:A}/opt/terraform/bin/terraform ]]; then
        print -r -- "brew"
        return 0
      fi
    fi
  fi

  local dpkg_status=""
  dpkg_status=$(command dpkg-query -W -f='${Status}' terraform 2>/dev/null)
  if [[ "$dpkg_status" == "install ok installed" ]]; then
    local dpkg_ownership=""
    dpkg_ownership=$(command dpkg-query -S "$resolved_path" 2>/dev/null)
    local ownership_line package_field owned_path
    for ownership_line in "${(@f)dpkg_ownership}"; do
      package_field="${ownership_line%%: *}"
      owned_path="${ownership_line#*: }"
      if [[ "$owned_path" == "$resolved_path" \
        && ( "$package_field" == "terraform" \
          || "$package_field" == terraform:* ) ]]; then
        print -r -- "apt"
        return 0
      fi
    done
  fi

  print -r -- "manual"
}

_dev_detect_tflint_manager() {
  command -v tflint &>/dev/null || return 1

  local resolved_path=""
  resolved_path=$(_dev_tflint_resolved_path 2>/dev/null)

  if command -v brew &>/dev/null; then
    local brew_prefix=""
    brew_prefix=$(command brew --prefix 2>/dev/null)
    if [[ -n "$brew_prefix" && -n "$resolved_path" ]]; then
      if [[ "$resolved_path" == ${brew_prefix:A}/Cellar/tflint/* ]] \
        || [[ "$resolved_path" == ${brew_prefix:A}/opt/tflint/* ]]; then
        print -r -- "brew"
        return 0
      fi
    fi
  fi

  print -r -- "manual"
}

typeset -g _DEV_COMMON_SOURCED=1
