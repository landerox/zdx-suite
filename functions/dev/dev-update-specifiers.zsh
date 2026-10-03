#!/usr/bin/env zsh
# =============================================================================
# Dev Update Specifiers: TOML-preserving specifier plans and PyPI readiness
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh and dev-pypi.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_UPDATE_SPECIFIERS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Result of the last _dev_update_specifier call:
#   "status|package|old_version|new_version|note"
typeset -g _DEV_UPDATE_RESULT=""

# Reuse only an aggregate invocation's probe. Standalone commands probe afresh;
# PyPI reachability says nothing about uv's configured index or Git remotes.
_dev_update_pypi_ready() {
  case "${_DEV_UPDATE_PYPI_STATUS:-}" in
    0) return 0 ;;
    1) return 1 ;;
    *) _dev_pypi_check_connectivity ;;
  esac
}

# --- Version comparison -----------------------------------------------------

# stdout: "major", "minor", "patch", or "none".
# PEP 440 aware so pre-releases such as b0 or rc1 classify correctly.
_dev_version_bump_type() {
  local old_version="$1"
  local new_version="$2"

  VERSION_OLD="$old_version" VERSION_NEW="$new_version" \
    command python3 -I - <<'PY_VERCMP' 2>/dev/null
import os
import re

old = os.environ.get("VERSION_OLD", "").strip()
new = os.environ.get("VERSION_NEW", "").strip()

pep440 = re.compile(
    r'^\s*v?'
    r'(?P<release>[0-9]+(?:\.[0-9]+)*)'
    r'(?:(?P<pre_l>a|b|rc)(?P<pre_n>[0-9]+))?'
    r'(?:\.post(?P<post>[0-9]+))?'
    r'(?:\.dev(?P<dev>[0-9]+))?'
    r'(?:\+[A-Za-z0-9]+(?:[-_.][A-Za-z0-9]+)*)?'
    r'\s*$'
)


def classify(value):
    match = pep440.match(value)
    if not match:
        return None
    release = [int(part) for part in match.group("release").split(".")]
    while len(release) < 2:
        release.append(0)
    return release[0], release[1]


if old == new:
    print("none")
    raise SystemExit

old_parts = classify(old)
new_parts = classify(new)
if old_parts and new_parts:
    if old_parts[0] != new_parts[0]:
        print("major")
    elif old_parts[1] != new_parts[1]:
        print("minor")
    else:
        print("patch")
else:
    print("patch")
PY_VERCMP
}

# --- pyproject.toml specifier rewriting -------------------------------------

# Plans only declared dependency strings and preserves their original TOML
# spelling. Semantic comparisons bind each lexical span to its exact array
# element, so an identical description, tool setting, or comment is untouched.
_dev_update_specifier_plan() {
  _dev_pyproject_python '
import copy
import math
import re
import sys
import tempfile

package, latest, bump_filter, dry_run = sys.argv[1:]
source = b"".join(chunks).decode("utf-8")


def normalize(value):
    return re.sub(r"[-_.]+", "-", value).lower()


def result(kind, old="—", new="—", note=""):
    print("|".join((kind, package, old, new, note)))
    raise SystemExit


def declarations():
    project = data.get("project", {})
    for index, value in enumerate(project.get("dependencies", [])):
        yield ("project", "dependencies", index), value
    for group, values in project.get("optional-dependencies", {}).items():
        for index, value in enumerate(values):
            yield ("project", "optional-dependencies", group, index), value
    for group, values in data.get("dependency-groups", {}).items():
        for index, value in enumerate(values):
            yield ("dependency-groups", group, index), value


name_pattern = r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"
requirement = re.compile(
    r"(?P<name>" + name_pattern + r")"
    r"(?:\[[A-Za-z0-9._, -]+\])?\s*>=\s*"
    r"(?P<version>[^\s,;]+)\s*"
)
eligible = {}
declared = False
for value_path, value in declarations():
    if not isinstance(value, str):
        continue
    name = re.match(name_pattern, value)
    if not name or normalize(name[0]) != normalize(package):
        continue
    declared = True
    match = requirement.fullmatch(value)
    if match:
        eligible[value_path] = (value, match)

if not eligible:
    result("skipped", note=(
        "user-pinned or no simple >= specifier" if declared else "no >= specifier"
    ))
if len(eligible) > 1000:
    raise ValueError("dependency inventory exceeds 1000 entries")
old = next(iter(eligible.values()))[1]["version"]
if latest == "--inspect":
    result("eligible", old)


def version_key(value):
    match = re.fullmatch(
        r"v?(?:(\d+)!)?(\d+(?:\.\d+)*)"
        r"(?:(a|b|rc)(\d+))?(?:\.post(\d+))?"
        r"(?:\.dev(\d+))?(?:\+([A-Za-z0-9]+(?:[-_.][A-Za-z0-9]+)*))?",
        value, re.IGNORECASE,
    )
    if not match:
        return None
    epoch, release, pre, pre_number, post, dev, local = match.groups()
    release = tuple(int(part) for part in release.split("."))
    while len(release) > 1 and release[-1] == 0:
        release = release[:-1]
    pre_key = ({"a": 0, "b": 1, "rc": 2}[pre.lower()], int(pre_number)) \
        if pre else ((-1, 0) if dev is not None and post is None else (3, 0))
    local_key = tuple(
        (1, int(part)) if part.isdigit() else (0, part.lower())
        for part in re.split(r"[-_.]", local)
    ) if local else ()
    return (
        int(epoch or 0), release, pre_key, int(post) if post else -1,
        (0, int(dev)) if dev is not None else (1, 0), local_key,
    )


new_key = version_key(latest)
updates = {}
skip_reasons = []
at_latest = True
for value_path, (value, match) in eligible.items():
    current = match["version"]
    current_key = version_key(current)
    if current_key is None or new_key is None:
        at_latest = False
        skip_reasons.append("version ordering unavailable")
        continue
    if current_key == new_key:
        continue
    at_latest = False
    if current_key > new_key:
        skip_reasons.append("current minimum is newer; no downgrade")
        continue
    old_release = current_key[1] + (0, 0)
    new_release = new_key[1] + (0, 0)
    bump = "major" if current_key[0] != new_key[0] or old_release[0] != new_release[0] \
        else "minor" if old_release[1] != new_release[1] else "patch"
    if bump_filter != "all" and bump != bump_filter:
        skip_reasons.append(f"{bump} bump (filtered by --{bump_filter}-only)")
        continue
    updates[value_path] = value[:match.start("version")] + latest + value[match.end("version"):]

if not updates:
    if at_latest:
        result("latest", old, latest)
    result("skipped", old, latest, skip_reasons[0])
old = eligible[next(iter(updates))][1]["version"]


def string_spans():
    offset = 0
    while offset < len(source):
        char = source[offset]
        if char == "#":
            end = source.find("\n", offset)
            offset = len(source) if end == -1 else end + 1
            continue
        if char not in (chr(34), chr(39)):
            offset += 1
            continue
        start = offset
        delimiter = char * (3 if source.startswith(char * 3, offset) else 1)
        offset += len(delimiter)
        while offset < len(source):
            if char == chr(34) and source[offset] == chr(92):
                offset += 2
            elif source.startswith(delimiter, offset):
                offset += len(delimiter)
                if len(delimiter) == 3:
                    for _ in range(2):
                        if offset < len(source) and source[offset] == char:
                            offset += 1
                break
            else:
                offset += 1
        yield start, offset


def differences(before, after, prefix=()):
    if type(before) is not type(after):
        return [prefix]
    if isinstance(before, float) and math.isnan(before) and math.isnan(after):
        return []
    if isinstance(before, dict):
        if before.keys() != after.keys():
            return [prefix]
        return [leaf for key in before for leaf in differences(before[key], after[key], prefix + (key,))]
    if isinstance(before, list):
        if len(before) != len(after):
            return [prefix]
        return [leaf for index in range(len(before)) for leaf in differences(before[index], after[index], prefix + (index,))]
    return [] if before == after else [prefix]


replacements = []
found_paths = set()
candidate_values = {eligible[value_path][0] for value_path in updates}
span_probes = 0
for start, end in string_spans():
    token = source[start:end]
    value = tomllib.loads("value = " + token)["value"]
    if value not in candidate_values:
        continue
    span_probes += 1
    if span_probes > 64:
        result("failed", old, latest, "more than 64 matching dependency strings")
    # Replacing one complete string with an inert value identifies its parsed
    # location without inferring table boundaries from text or regular expressions.
    try:
        probe = tomllib.loads(source[:start] + chr(34) + "ZDX dependency span" + chr(34) + source[end:])
    except tomllib.TOMLDecodeError:
        # A quoted key can look like a dependency and collide with another key.
        # It is not a value span and cannot belong to a dependency array.
        continue
    changed = differences(data, probe)
    if len(changed) != 1 or changed[0] not in updates:
        continue
    value_path = changed[0]
    match = eligible[value_path][1]
    # Preserve literal/basic quotes, comments, whitespace, and newline style.
    # Escaped spelling is retained unless the version itself was escaped.
    raw_match = re.search(r">=\s*(" + re.escape(match["version"]) + r")", token)
    if not raw_match:
        result("failed", old, latest, "escaped dependency operator or version cannot be rewritten safely")
    replacement = token[:raw_match.start(1)] + latest + token[raw_match.end(1):]
    replacements.append((start, end, replacement))
    found_paths.add(value_path)

if found_paths != updates.keys():
    raise ValueError("could not bind every dependency update to its TOML string")
planned = source
for start, end, replacement in reversed(replacements):
    planned = planned[:start] + replacement + planned[end:]
expected = copy.deepcopy(data)
for value_path, replacement in updates.items():
    parent = expected
    for part in value_path[:-1]:
        parent = parent[part]
    parent[value_path[-1]] = replacement
if differences(expected, tomllib.loads(planned)):
    raise ValueError("dependency update changed unrelated project metadata")

if dry_run != "1":
    current = os.lstat(path)
    if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns, current.st_ctime_ns, current.st_mode) != stable_after:
        raise ValueError("dependency plan changed before its rewrite")
    descriptor, temporary = tempfile.mkstemp(prefix="pyproject.toml.", dir=".")
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(planned.encode("utf-8"))
            os.fchmod(output.fileno(), stat.S_IMODE(current.st_mode))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
result("updated", old, latest)
' "$1" "${2:---inspect}" "${3:-all}" "${4:-0}"
}

# Bumps declared simple ">=" requirements for one normalized package name.
# Sets _DEV_UPDATE_RESULT; returns 0 only when the plan changes (or would change).
_dev_update_specifier() {
  local package="$1"
  local -i dry_run="${2:-0}"
  local bump_filter="${3:-all}"
  local -i quiet="${4:-0}"

  _DEV_UPDATE_RESULT=$(
    _dev_update_specifier_plan "$package" "" "$bump_filter" "$dry_run"
  ) || {
    _DEV_UPDATE_RESULT="failed|$package|—|—|TOML planning failed"
    return 1
  }
  [[ "${_DEV_UPDATE_RESULT%%|*}" == "eligible" ]] || return 1
  local current_version="${${_DEV_UPDATE_RESULT#*|*|}%%|*}"
  local latest_version
  if ! latest_version=$(_dev_pypi_latest "$package") \
    || [[ -z "$latest_version" ]]; then
    _dev_warn "Could not fetch the latest version for $package"
    _DEV_UPDATE_RESULT="failed|$package|$current_version|—|PyPI query failed"
    return 1
  fi

  _DEV_UPDATE_RESULT=$(
    _dev_update_specifier_plan "$package" "$latest_version" \
      "$bump_filter" "$dry_run"
  ) || {
    _DEV_UPDATE_RESULT="failed|$package|$current_version|—|TOML planning failed"
    return 1
  }
  [[ "${_DEV_UPDATE_RESULT%%|*}" == "updated" ]] || return 1
  current_version="${${_DEV_UPDATE_RESULT#*|*|}%%|*}"
  if (( dry_run )); then
    _dev_info "[dry-run] $package: $current_version -> $latest_version"
  elif (( ! quiet )); then
    _dev_info "$package: $current_version -> $latest_version"
  fi
  return 0
}

typeset -g _DEV_UPDATE_SPECIFIERS_SOURCED=1
