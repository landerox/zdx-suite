#!/usr/bin/env zsh
# =============================================================================
# Dev PyPI: PEP 503 normalization, pyproject parsing, and PyPI version queries
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_PYPI_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- PEP 503 name normalization ---------------------------------------------
# PyPI normalizes package names: lowercase, and runs of [-_.] collapse to a
# single hyphen. Without this, "pip_audit" queries a URL that 302s or 404s.
# Ref: https://peps.python.org/pep-0503/#normalized-names

# stdout: the normalized name, or nothing when the input is unusable.
_dev_normalize_pkg_name() {
  # The `##` repetition operator below requires extended globbing, scoped to
  # this function so the caller's options are untouched.
  setopt LOCAL_OPTIONS EXTENDED_GLOB

  local raw="$1"
  [[ -n "$raw" ]] || return 1
  if (( ${#raw} > 214 )) \
    || [[ ! "$raw" =~ '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$' ]]; then
    return 1
  fi

  # Pure Zsh: avoids one python3 process per package on large dependency sets.
  local lowered="${raw:l}"
  local collapsed="${lowered//[-_.]##/-}"
  collapsed="${collapsed#-}"
  collapsed="${collapsed%-}"

  [[ -n "$collapsed" ]] || return 1
  print -r -- "$collapsed"
}

# --- pyproject.toml parsing --------------------------------------------------
# Each parser emits one package name per line on stdout and nothing else.
# Callers MUST check the exit status before consuming the records.

_dev_pyproject_python() {
  local script="$1"
  shift

  local loader='
import os
import pathlib
import stat
import tomllib

MAX_PYPROJECT_SIZE = 2 * 1024 * 1024
path = pathlib.Path("pyproject.toml")
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
'

  local parsed_output
  parsed_output=$(
    command python3 -I -c "${loader}"$'\n'"${script}" "$@" 2>/dev/null
  )
  local -i parser_status=$?
  if (( parser_status != 0 )); then
    if (( parser_status == 4 )); then
      _dev_error "Refusing to parse a pyproject.toml larger than 2 MiB."
    else
      _dev_error "Could not parse pyproject.toml safely."
    fi
    return 1
  fi
  [[ -n "$parsed_output" ]] && print -r -- "$parsed_output"
  return 0
}

# stdout: package names from [project.dependencies], one per line.
_dev_pyproject_main_deps() {
  _dev_require_file "pyproject.toml" || return 1
  _dev_require_python_toml || return 1

  _dev_pyproject_python '
import re

project = data.get("project", {})
if not isinstance(project, dict):
    raise TypeError("project must be a table")
dependencies = project.get("dependencies", [])
if not isinstance(dependencies, list):
    raise TypeError("project.dependencies must be an array")
for dep in dependencies:
    if not isinstance(dep, str):
        raise TypeError("project.dependencies entries must be strings")
    pkg = re.split(r"[\[(\s><=!~;@]", dep, maxsplit=1)[0].strip()
    if pkg:
        print(pkg)
'
}

# stdout: package names from every group in [dependency-groups].
_dev_pyproject_dev_deps() {
  _dev_require_file "pyproject.toml" || return 1
  _dev_require_python_toml || return 1

  _dev_pyproject_python '
import re

groups = data.get("dependency-groups", {})
if not isinstance(groups, dict):
    raise TypeError("dependency-groups must be a table")
for deps in groups.values():
    if not isinstance(deps, list):
        raise TypeError("dependency group values must be arrays")
    for dep in deps:
        if isinstance(dep, dict) \
          and set(dep) == {"include-group"} \
          and isinstance(dep["include-group"], str):
            continue
        if not isinstance(dep, str):
            raise TypeError("dependency group entries are invalid")
        pkg = re.split(r"[\[(\s><=!~;@]", dep, maxsplit=1)[0].strip()
        if pkg:
            print(pkg)
'
}

# stdout: package names from every group in [project.optional-dependencies].
_dev_pyproject_optional_deps() {
  _dev_require_file "pyproject.toml" || return 1
  _dev_require_python_toml || return 1

  _dev_pyproject_python '
import re

project = data.get("project", {})
if not isinstance(project, dict):
    raise TypeError("project must be a table")
groups = project.get("optional-dependencies", {})
if not isinstance(groups, dict):
    raise TypeError("project.optional-dependencies must be a table")
for deps in groups.values():
    if not isinstance(deps, list):
        raise TypeError("optional dependency values must be arrays")
    for dep in deps:
        if not isinstance(dep, str):
            raise TypeError("optional dependency entries must be strings")
        pkg = re.split(r"[\[(\s><=!~;@]", dep, maxsplit=1)[0].strip()
        if pkg:
            print(pkg)
'
}

# stdout: the project's requires-python specifier, or nothing.
_dev_pyproject_requires_python() {
  [[ -f "pyproject.toml" ]] || return 1
  _dev_require_python_toml || return 1

  _dev_pyproject_python '
project = data.get("project", {})
if not isinstance(project, dict):
    raise TypeError("project must be a table")
value = project.get("requires-python", "")
if not isinstance(value, str):
    raise TypeError("project.requires-python must be a string")
if value:
    print(value)
'
}

# Sets the `reply` array to the deduplicated union of declared direct
# dependencies, preserving first-seen order.
_dev_pyproject_all_deps() {
  reply=()

  local main_output dev_output optional_output
  main_output=$(_dev_pyproject_main_deps) || return 1
  local -a candidates=("${(@f)main_output}")
  if (( ${#candidates[@]} > 1000 )); then
    _dev_error "Refusing a dependency inventory larger than 1000 entries."
    return 1
  fi

  dev_output=$(_dev_pyproject_dev_deps) || return 1
  candidates+=("${(@f)dev_output}")
  if (( ${#candidates[@]} > 1000 )); then
    _dev_error "Refusing a dependency inventory larger than 1000 entries."
    return 1
  fi

  optional_output=$(_dev_pyproject_optional_deps) || return 1
  candidates+=("${(@f)optional_output}")
  if (( ${#candidates[@]} > 1000 )); then
    _dev_error "Refusing a dependency inventory larger than 1000 entries."
    return 1
  fi

  local -A seen=()
  local candidate normalized
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    normalized=$(_dev_normalize_pkg_name "$candidate") || {
      _dev_error "Unsupported dependency name in pyproject.toml: $candidate"
      reply=()
      return 1
    }
    (( ${+seen[$normalized]} )) && continue
    seen[$normalized]=1
    reply+=("$candidate")
  done

  return 0
}

# --- PyPI query cache -------------------------------------------------------
# The cache lives for one public command invocation. Callers register cleanup
# in an `always` block so an interrupt cannot leave the directory behind.

typeset -g _DEV_PYPI_CACHE_DIR=""
typeset -g _DEV_PYPI_CACHE_ROOT=""
typeset -g _DEV_PYPI_CACHE_ROOT_ID=""
typeset -g _DEV_PYPI_CACHE_ID=""

_dev_pypi_validate_config() {
  if [[ "$DEV_PYPI_TIMEOUT" != <-> ]] \
    || (( DEV_PYPI_TIMEOUT < 1 || DEV_PYPI_TIMEOUT > 300 )); then
    _dev_error "DEV_PYPI_TIMEOUT must be an integer between 1 and 300."
    return 1
  fi
  if [[ "$DEV_PYPI_RETRIES" != <-> ]] \
    || (( DEV_PYPI_RETRIES < 0 || DEV_PYPI_RETRIES > 10 )); then
    _dev_error "DEV_PYPI_RETRIES must be an integer between 0 and 10."
    return 1
  fi
  if [[ "$DEV_PYPI_JOBS" != <-> ]] \
    || (( DEV_PYPI_JOBS < 1 || DEV_PYPI_JOBS > 32 )); then
    _dev_error "DEV_PYPI_JOBS must be an integer between 1 and 32."
    return 1
  fi
}

# stdout: device:inode:mode:uid for a stable temporary root. A shared root is
# accepted only when it has the sticky bit, as /tmp normally does.
_dev_pypi_temp_root_identity() {
  local root="$1"
  local literal="${root:a}"
  local resolved="${root:A}"

  if [[ "$literal" != "$resolved" || ! -d "$literal" || -L "$literal" \
    || ! -w "$literal" ]]; then
    _dev_error "TMPDIR must name a writable, non-symlinked directory."
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || {
    _dev_error "The zsh/stat module is required to validate the PyPI cache."
    return 1
  }
  local -A metadata=()
  zstat -H metadata -- "$literal" 2>/dev/null || return 1

  if (( metadata[uid] == EUID )); then
    if (( (metadata[mode] & 8#22) != 0 \
      && (metadata[mode] & 8#1000) == 0 )); then
      _dev_error \
        "A group/world-writable TMPDIR must be protected by the sticky bit."
      return 1
    fi
  elif (( metadata[uid] != 0 || (metadata[mode] & 8#1000) == 0 )); then
    _dev_error \
      "TMPDIR must be owned by the current user, or root-owned with the sticky bit."
    return 1
  fi

  print -r -- \
    "${metadata[device]}:${metadata[inode]}:${metadata[mode]}:${metadata[uid]}"
}

# stdout: device:inode for the exact private cache directory.
_dev_pypi_cache_identity() {
  local cache_dir="$1"
  local cache_root="$2"
  local literal="${cache_dir:a}"

  if [[ "$literal" != "${cache_dir:A}" || "${literal:h}" != "${cache_root:A}" \
    || ! -d "$literal" || -L "$literal" \
    || ! "${literal:t}" =~ '^zdx-dev-pypi\.[A-Za-z0-9]+$' ]]; then
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$literal" 2>/dev/null || return 1
  if (( metadata[uid] != EUID || (metadata[mode] & 8#77) != 0 )); then
    return 1
  fi

  print -r -- "${metadata[device]}:${metadata[inode]}"
}

_dev_pypi_cache_validate() {
  [[ -n "$_DEV_PYPI_CACHE_DIR" && -n "$_DEV_PYPI_CACHE_ROOT" \
    && -n "$_DEV_PYPI_CACHE_ROOT_ID" && -n "$_DEV_PYPI_CACHE_ID" ]] || return 1

  local current_root_id current_cache_id
  current_root_id=$(
    _dev_pypi_temp_root_identity "$_DEV_PYPI_CACHE_ROOT"
  ) || return 1
  [[ "$current_root_id" == "$_DEV_PYPI_CACHE_ROOT_ID" ]] || return 1

  current_cache_id=$(
    _dev_pypi_cache_identity \
      "$_DEV_PYPI_CACHE_DIR" "$_DEV_PYPI_CACHE_ROOT"
  ) || return 1
  [[ "$current_cache_id" == "$_DEV_PYPI_CACHE_ID" ]]
}

# stdout: device:inode for a private, singly linked cache file.
_dev_pypi_cache_file_identity() {
  local target_path="$1"
  _dev_pypi_cache_validate || return 1

  if [[ "${target_path:a}" != "${target_path:A}" \
    || "${target_path:h}" != "${_DEV_PYPI_CACHE_DIR:A}" \
    || ! -f "$target_path" || -L "$target_path" ]]; then
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || return 1
  local -A metadata=()
  zstat -H metadata -- "$target_path" 2>/dev/null || return 1
  if (( metadata[uid] != EUID || metadata[nlink] != 1 \
    || (metadata[mode] & 8#77) != 0 )); then
    return 1
  fi

  print -r -- "${metadata[device]}:${metadata[inode]}"
}

_dev_pypi_cache_state_reset() {
  _DEV_PYPI_CACHE_DIR=""
  _DEV_PYPI_CACHE_ROOT=""
  _DEV_PYPI_CACHE_ROOT_ID=""
  _DEV_PYPI_CACHE_ID=""
}

_dev_pypi_cache_init() {
  _dev_pypi_validate_config || return 1

  if [[ -n "$_DEV_PYPI_CACHE_DIR" ]]; then
    if _dev_pypi_cache_validate; then
      return 0
    fi
    _dev_error "The active PyPI cache changed identity; refusing to reuse it."
    _dev_pypi_cache_state_reset
    return 1
  fi

  local cache_root="${TMPDIR:-/tmp}"
  cache_root="${cache_root:a}"
  local root_identity
  root_identity=$(_dev_pypi_temp_root_identity "$cache_root") || return 1

  local cache_dir
  cache_dir=$(command mktemp -d \
    "${cache_root}/zdx-dev-pypi.XXXXXX" 2>/dev/null) || {
    _dev_error "Could not create a temporary PyPI cache directory."
    return 1
  }

  command chmod 700 -- "$cache_dir" 2>/dev/null || {
    _dev_error "Could not make the temporary PyPI cache private."
    command rmdir -- "$cache_dir" 2>/dev/null
    return 1
  }

  local current_root_identity cache_identity
  current_root_identity=$(
    _dev_pypi_temp_root_identity "$cache_root"
  ) || {
    command rmdir -- "$cache_dir" 2>/dev/null
    return 1
  }
  if [[ "$current_root_identity" != "$root_identity" ]]; then
    _dev_error "TMPDIR changed while the PyPI cache was being created."
    command rmdir -- "$cache_dir" 2>/dev/null
    return 1
  fi
  cache_identity=$(
    _dev_pypi_cache_identity "$cache_dir" "$cache_root"
  ) || {
    _dev_error "Could not validate the temporary PyPI cache."
    command rmdir -- "$cache_dir" 2>/dev/null
    return 1
  }

  _DEV_PYPI_CACHE_DIR="$cache_dir"
  _DEV_PYPI_CACHE_ROOT="$cache_root"
  _DEV_PYPI_CACHE_ROOT_ID="$root_identity"
  _DEV_PYPI_CACHE_ID="$cache_identity"
  _dev_debug "PyPI cache dir: $cache_dir"
}

_dev_pypi_cache_cleanup() {
  [[ -n "$_DEV_PYPI_CACHE_DIR" ]] || return 0

  local cache_dir="$_DEV_PYPI_CACHE_DIR"
  local cache_root="$_DEV_PYPI_CACHE_ROOT"
  local cache_identity="$_DEV_PYPI_CACHE_ID"

  if [[ ! -e "$cache_dir" && ! -L "$cache_dir" ]]; then
    _dev_pypi_cache_state_reset
    return 0
  fi

  if ! _dev_pypi_cache_validate; then
    _dev_error "The PyPI cache changed identity; refusing recursive removal."
    _dev_pypi_cache_state_reset
    return 1
  fi

  # Rename the proven directory first. Removal then targets an invocation-owned
  # inode at an unguessable quarantine name, not a path an attacker can swap.
  local quarantine="${cache_root}/.zdx-dev-pypi.cleanup.${$}.${RANDOM}"
  if [[ -e "$quarantine" || -L "$quarantine" ]] \
    || ! command mv -- "$cache_dir" "$quarantine" 2>/dev/null; then
    _dev_error "Could not quarantine the PyPI cache for safe removal."
    _dev_pypi_cache_state_reset
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || {
    _dev_pypi_cache_state_reset
    return 1
  }
  local -A metadata=()
  if [[ "${quarantine:a}" != "${quarantine:A}" || ! -d "$quarantine" \
    || -L "$quarantine" ]] \
    || ! zstat -H metadata -- "$quarantine" 2>/dev/null \
    || (( metadata[uid] != EUID \
      || (metadata[mode] & 8#77) != 0 )) \
    || [[ "${metadata[device]}:${metadata[inode]}" != "$cache_identity" ]]; then
    _dev_error "The quarantined PyPI cache failed its final identity check."
    _dev_pypi_cache_state_reset
    return 1
  fi

  command rm -rf -- "$quarantine" 2>/dev/null
  local -i remove_status=$?
  _dev_pypi_cache_state_reset
  if (( remove_status != 0 )) || [[ -e "$quarantine" || -L "$quarantine" ]]; then
    _dev_error "Could not remove the quarantined PyPI cache."
    return 1
  fi
  return 0
}

# --- PyPI queries -----------------------------------------------------------

# Reports whether this shell runs inside a WSL distribution. Kept separate so
# tests can pin the host type without depending on the runner's kernel.
_dev_pypi_host_is_wsl() {
  local kernel_version=""
  [[ -r /proc/version ]] || return 1
  kernel_version="$(<'/proc/version')" 2>/dev/null || return 1
  [[ "$kernel_version" == *[Mm]icrosoft* ]]
}

# Explains a failed PyPI probe with the most specific cause curl can prove.
# Whether TCP connected distinguishes "nothing answers" from "the server
# accepted the connection but the exchange stalled", which on a VPN or tunnel
# almost always means large packets are silently dropped by an MTU mismatch.
#
# On a transfer that times out inside the TLS handshake curl leaves
# time_connect at zero, but it has already recorded the peer address and
# counted the connection, so any of the three fields proves the connect.
_dev_pypi_explain_probe_failure() {
  local -i curl_status="${1:-0}"
  local http_code="${2:-000}"
  local time_connect="${3:-}"
  local num_connects="${4:-}"
  local remote_ip="${5:-}"

  # External values are validated before they enter arithmetic.
  local -i tcp_connected=0
  if [[ "$time_connect" == <-> || "$time_connect" == <->.<-> ]] \
    && (( time_connect > 0 )); then
    tcp_connected=1
  elif [[ "$num_connects" == <-> ]] && (( num_connects > 0 )) \
    && [[ -n "$remote_ip" ]]; then
    tcp_connected=1
  fi

  case "$curl_status" in
    0)
      _dev_info \
        "PyPI answered HTTP ${http_code} instead of 200; a proxy or captive portal may be intercepting HTTPS."
      ;;
    6)
      _dev_info \
        "DNS could not resolve pypi.org; check /etc/resolv.conf or the VPN's DNS."
      ;;
    7)
      _dev_info \
        "No TCP connection to pypi.org:443; check routing, the firewall, or a VPN kill switch."
      ;;
    28|35|52|55|56)
      if (( tcp_connected )); then
        _dev_info \
          "pypi.org accepted the TCP connection, but the TLS/HTTP exchange stalled (curl status $curl_status)."
        _dev_info \
          "That pattern means large packets are being dropped, usually by a VPN or tunnel with a smaller MTU."
        if _dev_pypi_host_is_wsl; then
          _dev_info \
            "WSL2 keeps eth0 at MTU 1500 and never learns the tunnel MTU. Lower it to match, for example:"
          _dev_dim "  sudo ip link set dev eth0 mtu 1392"
          _dev_dim "  ping -c1 -M do -s 1364 1.1.1.1   # a 1392-byte packet must pass"
        else
          _dev_dim "  ping -c1 -M do -s 1364 pypi.org   # find the largest packet that passes"
        fi
      else
        _dev_info \
          "The connection attempt to pypi.org:443 timed out before TCP connected (curl status $curl_status)."
        _dev_info \
          "Check routing, the firewall, or a VPN kill switch; DNS did resolve the host."
      fi
      ;;
    *)
      _dev_info \
        "curl exited with status $curl_status; rerun it with -v against https://pypi.org/simple/ for details."
      ;;
  esac
}

_dev_pypi_check_connectivity() {
  _dev_require_command curl || return 1
  _dev_pypi_validate_config || return 1
  _dev_debug "Testing PyPI connectivity..."

  local probe_output
  probe_output=$(command curl -q --proto '=https' --proto-redir '=https' \
    -sSLI -o /dev/null \
    -w "%{http_code} %{time_connect} %{num_connects} %{remote_ip}" \
    --max-time "$DEV_PYPI_TIMEOUT" "https://pypi.org/simple/" 2>/dev/null)
  local -i curl_status=$?
  local -a probe_fields=(${=probe_output})
  local http_code="${probe_fields[1]:-}"

  if [[ "$http_code" != "200" ]]; then
    _dev_error "Cannot reach PyPI (HTTP ${http_code:-none}). Check network, DNS, or proxy."
    _dev_pypi_explain_probe_failure "$curl_status" "${http_code:-000}" \
      "${probe_fields[2]:-}" "${probe_fields[3]:-}" "${probe_fields[4]:-}"
    return 1
  fi

  _dev_debug "PyPI reachable (HTTP $http_code)."
  return 0
}

# stdout: the latest published version string for a package.
# Follows redirects because PyPI 302s non-canonical names, and writes the JSON
# body to a file because responses can be several megabytes.
_dev_pypi_latest() {
  local raw_name="$1"
  local pkg
  pkg=$(_dev_normalize_pkg_name "$raw_name") || return 1
  _dev_debug "PyPI query: raw='$raw_name' normalized='$pkg'"

  _dev_pypi_cache_init || return 1

  local cache_file="${_DEV_PYPI_CACHE_DIR}/${pkg}"
  if [[ -e "$cache_file" || -L "$cache_file" ]]; then
    if ! _dev_pypi_cache_file_identity "$cache_file" >/dev/null; then
      _dev_error "Refusing an unsafe PyPI cache entry for $pkg."
      return 1
    fi
    _dev_debug "Cache hit for $pkg"
    command cat -- "$cache_file"
    return $?
  fi

  local body_file body_identity
  body_file=$(command mktemp "${_DEV_PYPI_CACHE_DIR}/body.XXXXXX" 2>/dev/null) \
    || return 1
  command chmod 600 -- "$body_file" 2>/dev/null || {
    command rm -f -- "$body_file" 2>/dev/null
    return 1
  }
  body_identity=$(_dev_pypi_cache_file_identity "$body_file") || {
    command rm -f -- "$body_file" 2>/dev/null
    return 1
  }

  {
    local url="https://pypi.org/pypi/${pkg}/json"
    local -i max_retries=DEV_PYPI_RETRIES
    local -i attempt=0
    local version=""

    while (( attempt <= max_retries )); do
      if (( attempt > 0 )); then
        _dev_debug "Retry $attempt/$max_retries for $pkg..."
        sleep 1
      fi

      if command curl -q --proto '=https' --proto-redir '=https' \
        -sSL --fail --max-time "$DEV_PYPI_TIMEOUT" \
        --max-filesize 20971520 \
        -o "$body_file" -- "$url" 2>/dev/null; then
        version=$(command python3 -I -c '
import json
import os
import stat
import sys

MAX_RESPONSE_SIZE = 20 * 1024 * 1024
path = sys.argv[1]
expected_identity = sys.argv[2]
flags = os.O_RDONLY
flags |= getattr(os, "O_CLOEXEC", 0)
flags |= getattr(os, "O_NOFOLLOW", 0)
flags |= getattr(os, "O_NONBLOCK", 0)

path_before = os.lstat(path)
descriptor = os.open(path, flags)
try:
    before = os.fstat(descriptor)
    observed_identity = f"{before.st_dev}:{before.st_ino}"
    if not stat.S_ISREG(path_before.st_mode) \
            or not stat.S_ISREG(before.st_mode) \
            or observed_identity != expected_identity \
            or (path_before.st_dev, path_before.st_ino) != (
                before.st_dev,
                before.st_ino,
            ) \
            or before.st_size > MAX_RESPONSE_SIZE:
        raise ValueError

    chunks = []
    length = 0
    while length <= MAX_RESPONSE_SIZE:
        chunk = os.read(
            descriptor,
            min(1024 * 1024, MAX_RESPONSE_SIZE + 1 - length),
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
    if length > MAX_RESPONSE_SIZE \
            or stable_before != stable_after \
            or (path_after.st_dev, path_after.st_ino) != (
                after.st_dev,
                after.st_ino,
            ):
        raise ValueError
finally:
    os.close(descriptor)

data = json.loads(b"".join(chunks).decode("utf-8"))
if not isinstance(data, dict) or not isinstance(data.get("info"), dict):
    raise ValueError
version = data["info"].get("version")
if not isinstance(version, str):
    raise ValueError
print(version)
' "$body_file" "$body_identity" 2>/dev/null)

        if [[ -n "$version" && ${#version} -le 128 \
          && "$version" =~ '^[A-Za-z0-9][A-Za-z0-9.!+_-]*$' ]]; then
          _dev_pypi_cache_validate || return 1

          local version_file
          version_file=$(command mktemp \
            "${_DEV_PYPI_CACHE_DIR}/.version.XXXXXX" 2>/dev/null) \
            || return 1
          command chmod 600 -- "$version_file" 2>/dev/null || {
            command rm -f -- "$version_file" 2>/dev/null
            return 1
          }
          print -r -- "$version" > "$version_file" || {
            command rm -f -- "$version_file" 2>/dev/null
            return 1
          }

          # Linking is an atomic no-clobber publication. A concurrent worker
          # that won the same package key simply supplies the cache entry.
          command ln -- "$version_file" "$cache_file" 2>/dev/null
          command rm -f -- "$version_file" 2>/dev/null
          if ! _dev_pypi_cache_file_identity "$cache_file" >/dev/null; then
            return 1
          fi
          command cat -- "$cache_file"
          return $?
        fi
        _dev_debug "JSON parse failed for $pkg"
      else
        _dev_debug "curl failed for $pkg"
      fi

      attempt=$(( attempt + 1 ))
    done

    _dev_debug "All retries exhausted for $pkg"
    return 1
  } always {
    local current_body_identity=""
    current_body_identity=$(
      _dev_pypi_cache_file_identity "$body_file" 2>/dev/null
    )
    if [[ -n "$current_body_identity" \
      && "$current_body_identity" == "$body_identity" ]]; then
      command rm -f -- "$body_file" 2>/dev/null
    fi
  }
}

# Warms the cache concurrently. Explicit PID tracking avoids a deadlock with
# the spinner, which is also a background job in the same shell.
_dev_pypi_prefetch() {
  setopt LOCAL_OPTIONS NO_MONITOR

  _dev_pypi_validate_config || return 1
  local -a packages=("$@")
  local -i max_jobs=DEV_PYPI_JOBS

  _dev_pypi_cache_init || return 1

  local -a pids=()
  local package pid
  {
    for package in "${packages[@]}"; do
      [[ -n "$package" ]] || continue

      ( _dev_pypi_latest "$package" >/dev/null 2>&1 ) &
      pids+=($!)

      if (( ${#pids[@]} >= max_jobs )); then
        wait "${pids[1]}" 2>/dev/null
        pids=("${pids[@]:1}")
      fi
    done

    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null
    done
    pids=()
  } always {
    for pid in "${pids[@]}"; do
      builtin kill "$pid" 2>/dev/null
    done
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null
    done
  }
  return 0
}

typeset -g _DEV_PYPI_SOURCED=1
