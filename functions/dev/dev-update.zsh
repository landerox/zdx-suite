#!/usr/bin/env zsh
# =============================================================================
# Dev Update: dependency, lockfile, toolchain, pre-commit, and runtime updates
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh, dev-state.zsh, dev-pypi.zsh,
# and dev-export.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_UPDATE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Result of the last _dev_update_specifier call:
#   "status|package|old_version|new_version|note"
typeset -g _DEV_UPDATE_RESULT=""

# Fingerprints one regular, non-symlink file. Device and inode protect the
# selected object while the digest protects its exact contents.
_dev_update_file_fingerprint() {
  local file_path="$1"
  REPLY=""

  local fingerprint
  fingerprint=$(command python3 -I - "$file_path" <<'PY_FINGERPRINT' 2>/dev/null
import hashlib
import os
import stat
import sys

path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
flags |= getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    before = os.fstat(descriptor)
    linked_before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit(1)
    if (linked_before.st_dev, linked_before.st_ino) != (
        before.st_dev,
        before.st_ino,
    ):
        raise SystemExit(1)

    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)

    after = os.fstat(descriptor)
    linked_after = os.lstat(path)
    stable_before = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        stat.S_IMODE(before.st_mode),
    )
    stable_after = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        stat.S_IMODE(after.st_mode),
    )
    if stable_before != stable_after:
        raise SystemExit(1)
    if (linked_after.st_dev, linked_after.st_ino) != (
        after.st_dev,
        after.st_ino,
    ):
        raise SystemExit(1)

    print(
        f"{after.st_dev}:{after.st_ino}:{after.st_size}:"
        f"{after.st_mtime_ns}:{stat.S_IMODE(after.st_mode)}:"
        f"{digest.hexdigest()}"
    )
finally:
    os.close(descriptor)
PY_FINGERPRINT
  ) || return 1

  [[ -n "$fingerprint" ]] || return 1
  REPLY="$fingerprint"
}

# stdout: device:inode for an owner-controlled regular file.
_dev_update_file_object_identity() {
  local file_path="$1"
  local label="${2:-temporary file}"
  local owned_identity
  owned_identity=$(
    _dev_owned_file_identity "$file_path" "$label"
  ) || return 1
  [[ "$owned_identity" != "absent" ]] || return 1

  local device="${owned_identity%%:*}"
  local identity_tail="${owned_identity#*:}"
  local inode="${identity_tail%%:*}"
  print -r -- "${device}:${inode}"
}

_dev_update_fingerprint_mode() {
  local without_digest="${1%:*}"
  REPLY="${without_digest##*:}"
}

# stdout: device:inode:mode:uid for a stable temporary root. A shared root is
# accepted only when it is root-owned and sticky; a current-user root may also
# be private.
_dev_update_temp_root_identity() {
  local temp_root="$1"
  local literal="${temp_root:a}"
  local resolved="${temp_root:A}"

  if [[ "$literal" != "$resolved" || ! -d "$literal" || -L "$literal" \
    || ! -w "$literal" ]]; then
    _dev_error "TMPDIR must name a writable, non-symlinked directory."
    return 1
  fi

  zmodload zsh/stat 2>/dev/null || {
    _dev_error \
      "The zsh/stat module is required to validate the update workspace."
    return 1
  }
  local -A metadata=()
  zstat -H metadata -- "$literal" 2>/dev/null || {
    _dev_error "Could not inspect TMPDIR: $literal"
    return 1
  }

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

# stdout: device:inode for one private workspace directly below temp_root.
_dev_update_workspace_identity() {
  local workspace_dir="$1"
  local temp_root="$2"
  local literal="${workspace_dir:a}"

  if [[ "$literal" != "${workspace_dir:A}" \
    || "${literal:h}" != "${temp_root:a}" \
    || ! -d "$literal" || -L "$literal" ]]; then
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

_dev_update_workspace_validate() {
  local temp_root="$1"
  local expected_root_identity="$2"
  local workspace_dir="$3"
  local expected_workspace_identity="$4"

  local current_root_identity
  current_root_identity=$(
    _dev_update_temp_root_identity "$temp_root"
  ) || return 1
  [[ "$current_root_identity" == "$expected_root_identity" ]] || return 1

  local current_workspace_identity
  current_workspace_identity=$(
    _dev_update_workspace_identity "$workspace_dir" "$temp_root"
  ) || return 1
  [[ "$current_workspace_identity" == "$expected_workspace_identity" ]]
}

# Sets reply=(temp_root root_identity workspace_dir workspace_identity).
_dev_update_workspace_create() {
  reply=()

  local temp_root="${TMPDIR:-/tmp}"
  temp_root="${temp_root:a}"
  local root_identity
  root_identity=$(
    _dev_update_temp_root_identity "$temp_root"
  ) || return 1

  local workspace_dir
  workspace_dir=$(command mktemp -d \
    "${temp_root}/zdx-dev-update.XXXXXX" 2>/dev/null) || {
    _dev_error "Could not create a private update workspace."
    return 1
  }

  command chmod 700 -- "$workspace_dir" 2>/dev/null || {
    _dev_error "Could not restrict the update workspace."
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  }

  local current_root_identity
  current_root_identity=$(
    _dev_update_temp_root_identity "$temp_root"
  ) || {
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  }
  if [[ "$current_root_identity" != "$root_identity" ]]; then
    _dev_error "TMPDIR changed while the update workspace was being created."
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  fi

  local workspace_identity
  workspace_identity=$(
    _dev_update_workspace_identity "$workspace_dir" "$temp_root"
  ) || {
    _dev_error "Could not validate the private update workspace."
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  }

  reply=(
    "$temp_root"
    "$root_identity"
    "$workspace_dir"
    "$workspace_identity"
  )
}

# Quarantines the exact proven workspace inode before recursive removal.
_dev_update_workspace_cleanup() {
  local temp_root="$1"
  local root_identity="$2"
  local workspace_dir="$3"
  local workspace_identity="$4"
  local current_root_identity=""

  [[ -n "$workspace_dir" ]] || return 0
  if [[ ! -e "$workspace_dir" && ! -L "$workspace_dir" ]]; then
    current_root_identity=$(
      _dev_update_temp_root_identity "$temp_root"
    ) || return 1
    if [[ "$current_root_identity" != "$root_identity" ]]; then
      _dev_error \
        "TMPDIR changed and the original update workspace cannot be located."
      return 1
    fi
    return 0
  fi

  if ! _dev_update_workspace_validate \
    "$temp_root" "$root_identity" "$workspace_dir" "$workspace_identity"; then
    _dev_error \
      "The update workspace changed identity; refusing recursive removal."
    return 1
  fi

  local quarantine="${temp_root}/.zdx-dev-update.cleanup.${$}.${RANDOM}.${RANDOM}"
  if [[ -e "$quarantine" || -L "$quarantine" ]] \
    || ! command mv -- "$workspace_dir" "$quarantine" 2>/dev/null; then
    _dev_error "Could not quarantine the update workspace for safe removal."
    return 1
  fi

  current_root_identity=$(
    _dev_update_temp_root_identity "$temp_root"
  ) || return 1
  if [[ "$current_root_identity" != "$root_identity" ]]; then
    _dev_error "TMPDIR changed while the update workspace was quarantined."
    return 1
  fi

  local quarantined_identity
  quarantined_identity=$(
    _dev_update_workspace_identity "$quarantine" "$temp_root"
  ) || {
    _dev_error "The quarantined update workspace is no longer safe."
    return 1
  }
  if [[ "$quarantined_identity" != "$workspace_identity" ]]; then
    _dev_error "The quarantined update workspace changed identity."
    return 1
  fi

  command rm -rf -- "$quarantine" 2>/dev/null
  local -i remove_status=$?
  if (( remove_status != 0 )) || [[ -e "$quarantine" || -L "$quarantine" ]]; then
    _dev_error "Could not remove the quarantined update workspace."
    return 1
  fi
  return 0
}

# Copies one stable source into a private snapshot and proves content and mode.
_dev_update_copy_snapshot() {
  local source_file="$1"
  local snapshot_file="$2"
  local expected_source_fingerprint="$3"
  REPLY=""

  _dev_update_file_fingerprint "$source_file" || return 1
  [[ "$REPLY" == "$expected_source_fingerprint" ]] || return 1
  command cp -p -- "$source_file" "$snapshot_file" 2>/dev/null || return 1
  _dev_update_file_fingerprint "$source_file" || return 1
  [[ "$REPLY" == "$expected_source_fingerprint" ]] || return 1

  local snapshot_fingerprint=""
  _dev_update_file_fingerprint "$snapshot_file" || return 1
  snapshot_fingerprint="$REPLY"
  _dev_update_fingerprint_mode "$expected_source_fingerprint"
  local expected_mode="$REPLY"
  _dev_update_fingerprint_mode "$snapshot_fingerprint"
  if [[ "${snapshot_fingerprint##*:}" != \
      "${expected_source_fingerprint##*:}" \
    || "$REPLY" != "$expected_mode" ]]; then
    return 1
  fi

  REPLY="$snapshot_fingerprint"
}

# Publishes a private planned snapshot only while the destination still matches
# the exact object inspected during planning and the source matches the exact
# finished plan. The same-directory temporary keeps publication atomic.
_dev_update_publish_snapshot() {
  local source_file="$1"
  local target_file="$2"
  local expected_target_fingerprint="$3"
  local expected_source_fingerprint="$4"
  local metadata_policy="${5:-target}"
  REPLY=""

  [[ "$metadata_policy" == "target" || "$metadata_policy" == "source" ]] \
    || return 1

  _dev_update_file_fingerprint "$target_file" || return 1
  [[ "$REPLY" == "$expected_target_fingerprint" ]] || return 1
  _dev_owned_file_identity "$target_file" "snapshot destination" \
    >/dev/null || return 1

  _dev_update_file_fingerprint "$source_file" || return 1
  [[ "$REPLY" == "$expected_source_fingerprint" ]] || return 1
  _dev_owned_file_identity "$source_file" "planned snapshot" \
    >/dev/null || return 1

  local target_directory="${target_file:a:h}"
  local target_directory_identity
  target_directory_identity=$(
    _dev_write_directory_identity \
      "$target_directory" "snapshot destination directory"
  ) || return 1

  local publish_temp=""
  local publish_temp_identity=""
  publish_temp=$(command mktemp "${target_file}.zdx-publish.XXXXXX" 2>/dev/null) \
    || return 1

  {
    publish_temp_identity=$(
      _dev_update_file_object_identity "$publish_temp" "publication temporary"
    ) || {
      _dev_error "Could not validate the publication temporary."
      return 1
    }

    if [[ "$metadata_policy" == "source" ]]; then
      command cp -p -- "$source_file" "$publish_temp" 2>/dev/null || return 1
    else
      # A planned file may be mode 600 inside the private workspace. Preserve
      # the live target's metadata and replace only the staged contents.
      command cp -p -- "$target_file" "$publish_temp" 2>/dev/null || return 1
      command cat -- "$source_file" > "$publish_temp" || return 1
    fi

    _dev_update_file_fingerprint "$source_file" || return 1
    [[ "$REPLY" == "$expected_source_fingerprint" ]] || return 1

    local staged_fingerprint=""
    _dev_update_file_fingerprint "$publish_temp" || return 1
    staged_fingerprint="$REPLY"
    local expected_metadata_fingerprint="$expected_target_fingerprint"
    [[ "$metadata_policy" == "source" ]] \
      && expected_metadata_fingerprint="$expected_source_fingerprint"
    _dev_update_fingerprint_mode "$expected_metadata_fingerprint"
    local expected_mode="$REPLY"
    _dev_update_fingerprint_mode "$staged_fingerprint"
    if [[ "${staged_fingerprint##*:}" != \
        "${expected_source_fingerprint##*:}" \
      || "$REPLY" != "$expected_mode" ]]; then
      return 1
    fi

    _dev_update_file_fingerprint "$target_file" || return 1
    [[ "$REPLY" == "$expected_target_fingerprint" ]] || return 1
    local current_directory_identity
    current_directory_identity=$(
      _dev_write_directory_identity \
        "$target_directory" "snapshot destination directory"
    ) || return 1
    [[ "$current_directory_identity" == "$target_directory_identity" ]] \
      || return 1

    command mv -f -- "$publish_temp" "$target_file" || return 1
    publish_temp=""
    publish_temp_identity=""

    local published_fingerprint=""
    _dev_update_file_fingerprint "$target_file" || return 1
    published_fingerprint="$REPLY"
    _dev_update_fingerprint_mode "$published_fingerprint"
    if [[ "${published_fingerprint##*:}" != \
        "${expected_source_fingerprint##*:}" \
      || "$REPLY" != "$expected_mode" ]]; then
      return 1
    fi

    REPLY="$published_fingerprint"
    return 0
  } always {
    if [[ -n "$publish_temp" \
      && ( -e "$publish_temp" || -L "$publish_temp" ) ]]; then
      local current_temp_identity=""
      current_temp_identity=$(
        _dev_update_file_object_identity \
          "$publish_temp" "publication temporary" 2>/dev/null
      )
      if [[ -n "$current_temp_identity" \
        && "$current_temp_identity" == "$publish_temp_identity" ]]; then
        command rm -f -- "$publish_temp" 2>/dev/null
      else
        _dev_error \
          "The publication temporary changed identity; refusing removal."
      fi
    fi
  }
}

# Sets reply=(backup_file backup_fingerprint) for the exact current invocation.
_dev_update_prepare_pyproject_backup() {
  local expected_fingerprint="$1"
  reply=()

  _DEV_LAST_BACKUP_FILE=""
  _DEV_LAST_BACKUP_MODE=""
  dev-backup-pyproject || return 1

  local backup_file="${_DEV_LAST_BACKUP_FILE:-}"
  if [[ -z "$backup_file" || ! -f "$backup_file" || -L "$backup_file" ]]; then
    _dev_error "The pyproject.toml backup was not published safely."
    return 1
  fi
  _dev_owned_file_identity "$backup_file" "invocation backup" \
    >/dev/null || return 1

  local backup_fingerprint=""
  _dev_update_file_fingerprint "$backup_file" || {
    _dev_error "The invocation backup could not be verified."
    return 1
  }
  backup_fingerprint="$REPLY"
  if [[ "${backup_fingerprint##*:}" != \
    "${expected_fingerprint##*:}" ]]; then
    _dev_error \
      "The invocation backup does not match the inspected pyproject.toml."
    return 1
  fi

  _dev_update_fingerprint_mode "$expected_fingerprint"
  local expected_mode
  expected_mode=$(printf '%o' "$REPLY")
  if [[ -n "${_DEV_LAST_BACKUP_MODE:-}" \
    && "$_DEV_LAST_BACKUP_MODE" != "$expected_mode" ]]; then
    _dev_error "The invocation backup recorded the wrong source permissions."
    return 1
  fi

  reply=("$backup_file" "$backup_fingerprint")
}

# Restores one exact backup only while the live file is still the object this
# invocation published, then verifies both original contents and permissions.
_dev_update_rollback_pyproject() {
  local backup_file="$1"
  local expected_backup_fingerprint="$2"
  local expected_applied_fingerprint="$3"
  local expected_original_fingerprint="$4"
  local pyproject_path="${PWD:A}/pyproject.toml"

  _dev_update_file_fingerprint "$backup_file" || {
    _dev_error "The invocation backup could not be fingerprinted for rollback."
    return 1
  }
  if [[ "$REPLY" != "$expected_backup_fingerprint" ]]; then
    _dev_error \
      "The invocation backup changed after creation; automatic rollback was refused."
    return 1
  fi

  _dev_update_file_fingerprint "$pyproject_path" || {
    _dev_error \
      "Could not fingerprint the applied file; automatic rollback was refused."
    return 1
  }
  if [[ "$REPLY" != "$expected_applied_fingerprint" ]]; then
    _dev_error \
      "pyproject.toml changed after publication; automatic rollback was refused."
    _dev_info "Recovery backup: $backup_file"
    return 1
  fi

  if ! _dev_restore_pyproject "$backup_file"; then
    _dev_error "Could not restore pyproject.toml from the invocation backup."
    _dev_info "Recovery backup: $backup_file"
    return 1
  fi

  local restored_fingerprint=""
  _dev_update_file_fingerprint "$pyproject_path" || {
    _dev_error "Rollback completed but could not be verified."
    return 1
  }
  restored_fingerprint="$REPLY"
  _dev_update_fingerprint_mode "$expected_original_fingerprint"
  local expected_mode="$REPLY"
  _dev_update_fingerprint_mode "$restored_fingerprint"
  if [[ "${restored_fingerprint##*:}" != \
      "${expected_original_fingerprint##*:}" \
    || "$REPLY" != "$expected_mode" ]]; then
    _dev_error \
      "Rollback did not restore the original pyproject.toml contents and permissions."
    return 1
  fi
  return 0
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

# --- Summary table ----------------------------------------------------------

_dev_print_summary_table() {
  local -a rows=("$@")
  (( ${#rows[@]} > 0 )) || return 0

  _dev_header "Update Summary"

  if _dev_color_enabled; then
    printf '  \033[1;37m%-30s %-14s %-14s %s\033[0m\n' \
      "Package" "Previous" "Latest" "Status" >&2
  else
    printf '  %-30s %-14s %-14s %s\n' \
      "Package" "Previous" "Latest" "Status" >&2
  fi

  local row row_status rest package old_version new_version note label
  for row in "${rows[@]}"; do
    row_status="${row%%|*}"; rest="${row#*|}"
    package="${rest%%|*}";   rest="${rest#*|}"
    old_version="${rest%%|*}"; rest="${rest#*|}"
    new_version="${rest%%|*}"; note="${rest#*|}"

    case "$row_status" in
      updated) label="✔ updated" ;;
      latest)  label="✔ latest" ;;
      failed)  label="✘ failed" ;;
      skipped) label="⊘ skipped" ;;
      *)       label="$row_status" ;;
    esac

    printf '  %-30s %-14s %-14s %s%s\n' \
      "${(V)package}" "${(V)old_version}" "${(V)new_version}" \
      "$label" "${note:+ (${(V)note})}" >&2
  done
  _dev_blank
}

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

# --- Python runtime ---------------------------------------------------------

# Creates a private, same-filesystem workspace below the project root.
# Sets reply=(workspace directory_identity).
_dev_update_python_workspace_create() {
  local project_root="$1"
  local expected_project_identity="$2"
  reply=()

  local current_project_identity
  current_project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || return 1
  [[ "$current_project_identity" == "$expected_project_identity" ]] || {
    _dev_error "The project directory changed before Python staging."
    return 1
  }

  local workspace_dir
  workspace_dir=$(command mktemp -d \
    "${project_root}/.zdx-dev-python.XXXXXX" 2>/dev/null) || {
    _dev_error "Could not create a private Python update workspace."
    return 1
  }

  command chmod 700 -- "$workspace_dir" 2>/dev/null || {
    _dev_error "Could not restrict the Python update workspace."
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  }

  current_project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || {
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  }
  if [[ "$current_project_identity" != "$expected_project_identity" ]]; then
    _dev_error "The project directory changed during Python staging."
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  fi

  local workspace_identity
  workspace_identity=$(
    _dev_update_workspace_identity "$workspace_dir" "$project_root"
  ) || {
    _dev_error "Could not validate the private Python update workspace."
    command rmdir -- "$workspace_dir" 2>/dev/null
    return 1
  }

  reply=("$workspace_dir" "$workspace_identity")
}

_dev_update_python_workspace_validate() {
  local project_root="$1"
  local expected_project_identity="$2"
  local workspace_dir="$3"
  local expected_workspace_identity="$4"

  local current_project_identity
  current_project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || return 1
  [[ "$current_project_identity" == "$expected_project_identity" ]] || return 1

  local current_workspace_identity
  current_workspace_identity=$(
    _dev_update_workspace_identity "$workspace_dir" "$project_root"
  ) || return 1
  [[ "$current_workspace_identity" == "$expected_workspace_identity" ]]
}

# Quarantines the proven project-local workspace before recursive removal.
_dev_update_python_workspace_cleanup() {
  local project_root="$1"
  local project_identity="$2"
  local workspace_dir="$3"
  local workspace_identity="$4"

  [[ -n "$workspace_dir" ]] || return 0
  if [[ ! -e "$workspace_dir" && ! -L "$workspace_dir" ]]; then
    local current_project_identity
    current_project_identity=$(
      _dev_write_directory_identity \
        "$project_root" "Python update project directory"
    ) || return 1
    [[ "$current_project_identity" == "$project_identity" ]]
    return $?
  fi

  if ! _dev_update_python_workspace_validate \
    "$project_root" "$project_identity" \
    "$workspace_dir" "$workspace_identity"; then
    _dev_error \
      "The Python update workspace changed identity; refusing recursive removal."
    return 1
  fi

  local quarantine="${project_root}/.zdx-dev-python.cleanup.${$}.${RANDOM}.${RANDOM}"
  if [[ -e "$quarantine" || -L "$quarantine" ]] \
    || ! command mv -- "$workspace_dir" "$quarantine" 2>/dev/null; then
    _dev_error "Could not quarantine the Python update workspace."
    return 1
  fi

  if ! _dev_update_python_workspace_validate \
    "$project_root" "$project_identity" \
    "$quarantine" "$workspace_identity"; then
    _dev_error "The quarantined Python update workspace is no longer safe."
    return 1
  fi

  command rm -rf -- "$quarantine" 2>/dev/null
  local -i remove_rc=$?
  if (( remove_rc != 0 )) || [[ -e "$quarantine" || -L "$quarantine" ]]; then
    _dev_error "Could not remove the quarantined Python update workspace."
    return 1
  fi
  return 0
}

# Sets REPLY to one minor-version request safe for `uv python install
# --upgrade`. Exact and multi-version pins are owned by py-menu and must be
# changed explicitly instead of being silently overridden here.
_dev_update_python_request() {
  local current_version="$1"
  REPLY=""

  local -a pin_files=()
  local candidate
  for candidate in ".python-version" ".python-versions"; do
    [[ -e "$candidate" || -L "$candidate" ]] && pin_files+=("$candidate")
  done

  if (( ${#pin_files[@]} > 1 )); then
    _dev_error \
      "Both .python-version and .python-versions exist; Python selection is ambiguous."
    return 1
  fi

  if (( ${#pin_files[@]} == 1 )); then
    local pin_file="${pin_files[1]}"
    _dev_owned_file_identity "$pin_file" "Python version pin" \
      >/dev/null || return 1

    local pin_contents
    pin_contents=$(<"$pin_file") || return 1
    local -a pin_lines=("${(@f)pin_contents}")
    local -a active_pins=()
    local pin_line
    for pin_line in "${pin_lines[@]}"; do
      [[ -n "${pin_line//[[:space:]]/}" ]] && active_pins+=("$pin_line")
    done

    if (( ${#active_pins[@]} != 1 )) \
      || [[ "${active_pins[1]}" != <->.<-> ]]; then
      _dev_error \
        "An exact or complex Python pin cannot be upgraded implicitly."
      _dev_info \
        "Choose the new runtime explicitly with: dev-menu venv-python-pin <major.minor>"
      return 1
    fi

    REPLY="${active_pins[1]}"
    return 0
  fi

  local version_token="${current_version#Python }"
  local major_version="${version_token%%.*}"
  local remaining_version="${version_token#*.}"
  local minor_version="${remaining_version%%.*}"
  if [[ "$major_version" != <-> || "$minor_version" != <-> ]]; then
    _dev_error \
      "Could not determine the current .venv Python minor version."
    _dev_info \
      "Choose it explicitly with: dev-menu venv-python-pin <major.minor>"
    return 1
  fi

  REPLY="${major_version}.${minor_version}"
}

_dev_update_python_inputs_validate() {
  local project_root="$1"
  local expected_pyproject_fingerprint="$2"
  local expected_lock_fingerprint="$3"

  local current_pyproject_fingerprint
  current_pyproject_fingerprint=$(
    _dev_owned_file_fingerprint \
      "${project_root}/pyproject.toml" "pyproject.toml"
  ) || return 1
  local current_lock_fingerprint
  current_lock_fingerprint=$(
    _dev_owned_file_fingerprint "${project_root}/uv.lock" "uv.lock"
  ) || return 1

  if [[ "$current_pyproject_fingerprint" != \
      "$expected_pyproject_fingerprint" \
    || "$current_lock_fingerprint" != "$expected_lock_fingerprint" ]]; then
    _dev_error \
      "pyproject.toml or uv.lock changed during the Python update."
    return 1
  fi
}

# Builds and synchronizes a replacement environment privately, then swaps it
# into place only after the original environment is revalidated.
_dev_update_python_rebuild() {
  local project_root="$1"
  local project_identity="$2"
  local expected_venv_identity="$3"
  local current_version="$4"
  local python_request="$5"
  local expected_pyproject_fingerprint="$6"
  local expected_lock_fingerprint="$7"

  local -a reply=()
  _dev_update_python_workspace_create \
    "$project_root" "$project_identity" || return 1
  local workspace_dir="${reply[1]}"
  local workspace_identity="${reply[2]}"
  local staged_venv="${workspace_dir}/new-venv"
  local original_venv="${workspace_dir}/original-venv"
  local -i preserve_workspace=0
  local -i original_moved=0
  local -i operation_rc=1
  local new_version=""

  {
    _dev_info "Upgrading uv-managed Python patch releases..."
    if ! _dev_update_python_inputs_validate \
      "$project_root" "$expected_pyproject_fingerprint" \
      "$expected_lock_fingerprint"; then
      _dev_error \
        "Project inputs changed before the Python upgrade could start."
    elif ! command uv python install --upgrade "$python_request" >&2; then
      _dev_error \
        "Python installation failed. The existing .venv was left untouched."
    else
      _dev_info "Building a replacement environment privately..."
      # Both activation and installed console scripts must survive the rename
      # from the private workspace to .venv and the later workspace removal.
      if ! command uv venv --clear --managed-python \
        --python "$python_request" --relocatable "$staged_venv" >&2; then
        _dev_error \
          "Could not create the replacement environment; .venv was left untouched."
      else
        local staged_venv_identity
        staged_venv_identity=$(
          _dev_directory_identity \
            "$staged_venv" "staged Python environment"
        )
        if [[ -z "$staged_venv_identity" \
          || ! -x "${staged_venv}/bin/python" ]]; then
          _dev_error \
            "The replacement environment did not contain a usable Python."
        else
          _dev_info \
            "Synchronizing the replacement environment from the current lockfile..."
          if ! _dev_update_python_inputs_validate \
            "$project_root" "$expected_pyproject_fingerprint" \
            "$expected_lock_fingerprint"; then
            _dev_error \
              "Project inputs changed before environment synchronization."
          elif ! UV_PROJECT_ENVIRONMENT="$staged_venv" \
            command uv sync --all-groups --locked >&2; then
            _dev_error \
              "Environment sync failed. Run dev-update-lock first if uv.lock is stale or missing."
            _dev_info "The existing .venv was left untouched."
          else
            local current_staged_identity
            current_staged_identity=$(
              _dev_directory_identity \
                "$staged_venv" "staged Python environment"
            )
            local current_project_identity
            current_project_identity=$(
              _dev_write_directory_identity \
                "$project_root" "Python update project directory"
            )
            local current_venv_identity
            current_venv_identity=$(
              _dev_directory_identity \
                "${project_root}/.venv" "existing Python environment"
            )

            if ! _dev_update_python_inputs_validate \
              "$project_root" "$expected_pyproject_fingerprint" \
              "$expected_lock_fingerprint"; then
              _dev_error \
                "Project inputs changed while the environment was synchronized."
            elif [[ "$current_staged_identity" != "$staged_venv_identity" \
              || "$current_project_identity" != "$project_identity" \
              || "$current_venv_identity" != "$expected_venv_identity" \
              || "${PWD:A}" != "$project_root" ]]; then
              _dev_error \
                "The project or environment changed during Python staging."
            else
              new_version=$(
                command "${staged_venv}/bin/python" --version 2>/dev/null
              ) || new_version=""
              local staged_implementation=""
              staged_implementation=$(
                command "${staged_venv}/bin/python" -I -c \
                  'import platform; print(platform.python_implementation())' \
                  2>/dev/null
              ) || staged_implementation=""
              if [[ -z "$new_version" ]]; then
                _dev_error \
                  "Could not verify the staged Python interpreter."
              elif [[ "$new_version" != "Python ${python_request}."<-> \
                || "$staged_implementation" != "CPython" ]]; then
                _dev_error \
                  "The staged interpreter does not match CPython $python_request; .venv was left untouched."
              elif ! command mv -- \
                "${project_root}/.venv" "$original_venv"; then
                _dev_error \
                  "Could not preserve the existing .venv before publication."
              else
                original_moved=1
                local moved_original_identity
                moved_original_identity=$(
                  _dev_directory_identity \
                    "$original_venv" "preserved Python environment"
                )
                if [[ "$moved_original_identity" != \
                  "$expected_venv_identity" ]]; then
                  preserve_workspace=1
                  _dev_error \
                    "The preserved environment changed identity; automatic publication was refused."
                elif command mv -- \
                  "$staged_venv" "${project_root}/.venv"; then
                  local published_venv_identity
                  published_venv_identity=$(
                    _dev_directory_identity \
                      "${project_root}/.venv" "published Python environment"
                  )
                  if [[ "$published_venv_identity" == \
                    "$staged_venv_identity" ]]; then
                    operation_rc=0
                  else
                    preserve_workspace=1
                    _dev_error \
                      "The published environment could not be verified."
                  fi
                else
                  _dev_error \
                    "Could not publish the replacement environment; restoring the original."
                  if [[ ! -e "${project_root}/.venv" \
                    && ! -L "${project_root}/.venv" ]] \
                    && command mv -- \
                      "$original_venv" "${project_root}/.venv"; then
                    local restored_venv_identity
                    restored_venv_identity=$(
                      _dev_directory_identity \
                        "${project_root}/.venv" "restored Python environment"
                    )
                    if [[ "$restored_venv_identity" == \
                      "$expected_venv_identity" ]]; then
                      original_moved=0
                      _dev_warn \
                        "The original .venv was restored after publication failed."
                    else
                      preserve_workspace=1
                      _dev_error \
                        "The restored environment could not be verified."
                    fi
                  else
                    preserve_workspace=1
                    _dev_error \
                      "Automatic .venv rollback failed; the original is retained in the recovery workspace."
                  fi
                fi
              fi
            fi
          fi
        fi
      fi
    fi
  } always {
    # An interrupt between the two directory renames must never make cleanup
    # delete the only preserved copy of the original environment.
    (( original_moved && operation_rc != 0 )) && preserve_workspace=1

    if (( preserve_workspace )); then
      _dev_warn \
        "Python recovery workspace retained: $workspace_dir"
    elif ! _dev_update_python_workspace_cleanup \
      "$project_root" "$project_identity" \
      "$workspace_dir" "$workspace_identity"; then
      operation_rc=1
      preserve_workspace=1
      _dev_warn \
        "Python recovery workspace retained: $workspace_dir"
    fi
  }

  (( operation_rc == 0 )) || return 1
  _dev_success \
    "Python updated: ${current_version:-unknown} -> ${new_version:-unknown}"
  return 0
}

# dev-update-python
#   Arguments: --yes | --help
#   Effects:   delegates runtime installation to py-menu when .venv is absent;
#              otherwise upgrades uv-managed Python installations and, after
#              confirmation, stages and replaces the existing .venv.
dev-update-python() {
  emulate -L zsh

  local -i auto_yes=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        print -u2 -r -- "Usage: dev-update-python [--yes]"
        print -u2 -r -- \
          "  Delegate runtime selection and installation, or safely replace .venv."
        print -u2 -r -- \
          "  --yes   Skip confirmation; delegated version selection may still prompt."
        print -u2 -r -- \
          "  For unattended installation: dev-menu venv-python-install VERSION --yes"
        return 0
        ;;
      --yes|-y) auto_yes=1 ;;
      *) _dev_error "Unknown option: $1"; return 2 ;;
    esac
    shift
  done

  _dev_header "Maintaining Project Python"

  local project_root="${PWD:A}"
  local venv_path="${project_root}/.venv"
  if [[ -e "$venv_path" || -L "$venv_path" ]]; then
    if [[ ! -d "$venv_path" || -L "$venv_path" \
      || "${venv_path:a}" != "${venv_path:A}" ]]; then
      _dev_error "Refusing to replace an unsafe .venv path."
      return 1
    fi
  fi

  if [[ ! -d "$venv_path" ]]; then
    local -a delegate_arguments=(venv-python-install)
    (( auto_yes )) && delegate_arguments+=(--yes)
    _dev_info \
      "No .venv exists; Python runtime selection and installation are owned by py-menu."
    _dev_info "Delegating to the Python suite..."
    _dev_delegate_py "${delegate_arguments[@]}"
    return $?
  fi

  _dev_require_command uv || return 1

  local current_version=""
  local current_implementation=""
  if [[ -d "$venv_path" ]]; then
    current_version=$(
      command "${venv_path}/bin/python" --version 2>/dev/null
    )
    current_implementation=$(
      command "${venv_path}/bin/python" -I -c \
        'import platform; print(platform.python_implementation())' 2>/dev/null
    )
    _dev_info "Current venv Python: ${current_version:-unknown}"
  fi

  local requires_python
  requires_python=$(_dev_pyproject_requires_python 2>/dev/null) \
    && [[ -n "$requires_python" ]] \
    && _dev_info "pyproject.toml requires-python: $requires_python"

  _dev_require_file "pyproject.toml" || return 1
  _dev_require_file "uv.lock" || {
    _dev_info "Create or refresh it first with: dev-update-lock"
    return 1
  }
  if [[ "$current_implementation" != "CPython" ]]; then
    _dev_error \
      "Automatic patch upgrades currently require a CPython .venv."
    _dev_info \
      "Choose an alternative runtime explicitly with: dev-menu venv-python-pin <runtime>"
    return 1
  fi

  local pyproject_fingerprint
  pyproject_fingerprint=$(
    _dev_owned_file_fingerprint \
      "${project_root}/pyproject.toml" "pyproject.toml"
  ) || return 1
  local lock_fingerprint
  lock_fingerprint=$(
    _dev_owned_file_fingerprint "${project_root}/uv.lock" "uv.lock"
  ) || return 1

  local project_identity
  project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || return 1
  local venv_identity
  venv_identity=$(
    _dev_directory_identity "$venv_path" "existing Python environment"
  ) || return 1
  _dev_update_python_request "$current_version" || return 1
  local python_request="$REPLY"
  _dev_info "Python minor selected for patch upgrade: $python_request"

  local -i previous_auto_yes=$_DEV_AUTO_YES
  local rebuild_outcome="declined"
  {
    (( auto_yes )) && _DEV_AUTO_YES=1
    _dev_warn \
      "Replacing .venv discards packages not represented by the current lockfile."
    _dev_info \
      "The replacement will be built and synchronized before .venv is swapped."
    rebuild_outcome=$(_dev_confirm_outcome \
      "Upgrade Python and replace .venv?")
  } always {
    _DEV_AUTO_YES=$previous_auto_yes
  }

  case "$rebuild_outcome" in
    confirmed) ;;
    unavailable)
      _dev_error \
        "Rebuilding .venv needs confirmation; pass --yes in a non-interactive shell."
      return 1
      ;;
    *)
      _dev_info "Cancelled. Python and .venv were left untouched."
      return 0
      ;;
  esac

  local current_project_identity
  current_project_identity=$(
    _dev_write_directory_identity \
      "$project_root" "Python update project directory"
  ) || return 1
  local current_venv_identity
  current_venv_identity=$(
    _dev_directory_identity "$venv_path" "existing Python environment"
  ) || return 1
  local authorized_version
  authorized_version=$(
    command "${venv_path}/bin/python" --version 2>/dev/null
  )
  local authorized_implementation
  authorized_implementation=$(
    command "${venv_path}/bin/python" -I -c \
      'import platform; print(platform.python_implementation())' 2>/dev/null
  )
  if [[ "$current_project_identity" != "$project_identity" \
    || "$current_venv_identity" != "$venv_identity" \
    || "$authorized_version" != "$current_version" \
    || "$authorized_implementation" != "$current_implementation" \
    || "${PWD:A}" != "$project_root" ]]; then
    _dev_error \
      "The project or .venv changed after authorization; refusing to continue."
    return 1
  fi

  _dev_update_python_request "$authorized_version" || return 1
  if [[ "$REPLY" != "$python_request" ]]; then
    _dev_error \
      "The Python version selection changed after authorization."
    return 1
  fi
  _dev_update_python_inputs_validate \
    "$project_root" "$pyproject_fingerprint" "$lock_fingerprint" || {
    _dev_error \
      "Project inputs changed after authorization; refusing to continue."
    return 1
  }

  _dev_update_python_rebuild \
    "$project_root" "$project_identity" "$venv_identity" \
    "$current_version" "$python_request" \
    "$pyproject_fingerprint" "$lock_fingerprint"
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
  # the INT/TERM handler is scoped so it never lands in the user's shell.
  setopt LOCAL_OPTIONS LOCAL_TRAPS NO_MONITOR
  trap '_dev_spinner_stop' INT TERM

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
    (( dry_run )) && _dev_warn "DRY-RUN — no files will be modified."
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

    _dev_info \
      "Found ${#all_deps[@]} unique dependency(ies). Querying PyPI..."

    _dev_spinner_start "Fetching versions from PyPI (${#all_deps[@]} packages)"
    _dev_pypi_prefetch "${all_deps[@]}"
    _dev_spinner_stop

    local -i updated=0 failed=0 skipped=0 at_latest=0
    local -a summary_rows=() updated_packages=()
    local package row_rest plan_result

    for package in "${all_deps[@]}"; do
      [[ -n "$package" ]] || continue

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

    if (( dry_run )); then
      if (( updated > 0 )); then
        _dev_success "$updated specifier(s) would be updated."
        _dev_info "Run without --dry-run to apply the changes."
      else
        _dev_success "All specifiers are already at their latest versions."
      fi
      (( failed > 0 )) \
        && _dev_warn "$failed package(s) could not be queried from PyPI."
      (( skipped > 0 )) \
        && _dev_dim "$skipped package(s) skipped (see the notes above)."
      (( failed > 0 )) && return 1
      return 0
    fi

    if (( updated == 0 )); then
      if (( failed > 0 )); then
        _dev_error \
          "No update was applied because $failed package query or plan failed."
        return 1
      fi
      _dev_success "No eligible dependency specifier needs updating."
      (( failed > 0 )) \
        && _dev_warn "$failed package(s) could not be queried from PyPI."
      (( skipped > 0 )) \
        && _dev_dim "$skipped package(s) skipped (see the notes above)."
      return 0
    fi

    local apply_outcome
    apply_outcome=$(_dev_confirm_outcome \
      "Apply $updated update(s) to pyproject.toml?")
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

    _dev_info "$updated specifier(s) applied to pyproject.toml."
    _dev_info "Changes to pyproject.toml:"
    _dev_show_diff pyproject.toml

    (( failed > 0 )) \
      && _dev_warn "$failed package(s) could not be queried from PyPI."
    (( skipped > 0 )) \
      && _dev_dim "$skipped package(s) skipped (see the notes above)."

    # Re-lock only the packages that changed. A blanket --upgrade churns
    # transitive dependencies and can surface conflicts that existing pins
    # were specifically written to avoid.
    _dev_info "Re-locking ${#updated_packages[@]} package(s) and syncing..."
    local -a upgrade_args=()
    for package in "${updated_packages[@]}"; do
      upgrade_args+=(--upgrade-package "$package")
    done

    if ! command uv lock "${upgrade_args[@]}" >&2; then
      _dev_error "Lock failed — attempting an exact pyproject.toml rollback."
      if ! _dev_update_rollback_pyproject \
        "$invocation_backup" "$invocation_backup_fingerprint" \
        "$applied_fingerprint" "$initial_fingerprint"; then
        _dev_error "Lock failed and pyproject.toml rollback also failed."
        return 1
      fi

      _DEV_UPDATE_DEPS_OUTCOME="restored"
      _dev_warn "pyproject.toml was restored from the exact invocation backup."
      return 1
    fi
    _DEV_UPDATE_DEPS_OUTCOME="locked"

    if ! command uv sync --all-groups >&2; then
      _dev_error \
        "Sync failed after the project and lockfile were updated; the environment may be partial."
      return 1
    fi
    _DEV_UPDATE_DEPS_OUTCOME="applied"

    if (( failed > 0 )); then
      _dev_warn \
        "Applied $updated update(s), but $failed package query or plan failed."
      return 1
    fi

    _dev_success \
      "Applied $updated dependency update(s) and synchronized the environment."
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

  _dev_info "Resolving the newest compatible versions..."
  command uv lock --upgrade >&2 || {
    _dev_error "Lock failed."
    return 1
  }

  _dev_info "Syncing the environment..."
  command uv sync --all-groups >&2 || {
    _dev_error "Sync failed."
    return 1
  }

  _dev_success "uv.lock updated and the environment synced."
}

# --- Pre-commit -------------------------------------------------------------

# Reuse only an aggregate invocation's probe. Standalone commands probe afresh;
# PyPI reachability says nothing about uv's configured index or Git remotes.
_dev_update_pypi_ready() {
  case "${_DEV_UPDATE_PYPI_STATUS:-}" in
    0) return 0 ;;
    1) return 1 ;;
    *) _dev_pypi_check_connectivity ;;
  esac
}

# Sanitizes a private pre-commit autoupdate candidate in place. The updater may
# change only remote `rev:` lines, every changed revision must be a frozen Git
# object, and an already immutable revision is retained when the proposed tag
# is older, incomparable, or was moved to a different object.
#
# stdout: tab-separated `repo, previous tag, proposed tag, reason` records for
#         revisions retained by the guard.
_dev_precommit_sanitize_plan() {
  local original_config="$1"
  local planned_config="$2"

  command python3 -I - "$original_config" "$planned_config" \
    <<'PY_PRECOMMIT_GUARD' 2>/dev/null
import os
import re
import stat
import sys

MAX_CONFIG_SIZE = 2 * 1024 * 1024
REVISION = re.compile(
    r"^(\s+)rev:(\s*)(['\"]?)([^\s#]+)(.*)(\r?\n)$"
)
FULL_OBJECT_ID = re.compile(r"^[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?$")
FROZEN_COMMENT = re.compile(r"^\s*# frozen: ([^\s#]+)\s*$")
VERSION = re.compile(
    r"^[^0-9]*([0-9]+(?:\.[0-9]+)+)(.*)$",
    re.IGNORECASE,
)


def read_stable(path, writable=False):
    flags = os.O_RDWR if writable else os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)

    linked_before = os.lstat(path)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(linked_before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or (linked_before.st_dev, linked_before.st_ino)
            != (before.st_dev, before.st_ino)
            or before.st_size > MAX_CONFIG_SIZE
        ):
            raise ValueError

        chunks = []
        length = 0
        while length <= MAX_CONFIG_SIZE:
            chunk = os.read(
                descriptor,
                min(1024 * 1024, MAX_CONFIG_SIZE + 1 - length),
            )
            if not chunk:
                break
            chunks.append(chunk)
            length += len(chunk)

        after = os.fstat(descriptor)
        linked_after = os.lstat(path)
        stable_before = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            before.st_mode,
            before.st_uid,
            before.st_nlink,
        )
        stable_after = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_mode,
            after.st_uid,
            after.st_nlink,
        )
        if (
            length > MAX_CONFIG_SIZE
            or stable_before != stable_after
            or (linked_after.st_dev, linked_after.st_ino)
            != (after.st_dev, after.st_ino)
        ):
            raise ValueError

        data = b"".join(chunks).decode("utf-8")
        if writable:
            return descriptor, data, before
        return -1, data, before
    except Exception:
        if writable:
            os.close(descriptor)
        raise
    finally:
        if not writable:
            os.close(descriptor)


def repo_records(lines):
    current_repo = "<unknown>"
    records = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("- repo:"):
            value = stripped[len("- repo:"):].split("#", 1)[0].strip()
            if (
                len(value) >= 2
                and value[0] == value[-1]
                and value[0] in "'\""
            ):
                value = value[1:-1]
            if not value or any(char in value for char in "\t\r\n"):
                raise ValueError
            current_repo = value

        match = REVISION.match(line)
        if match is not None:
            records.append((index, current_repo, match))
    return records


def version_label(match):
    revision = match.group(4).strip("'\"")
    frozen = FROZEN_COMMENT.fullmatch(match.group(5))
    if frozen is not None:
        return frozen.group(1)
    if VERSION.fullmatch(revision) is not None:
        return revision
    legacy = re.fullmatch(r"\s*#\s*([vV]?\d[^\s#]*)\s*", match.group(5))
    return legacy.group(1) if legacy is not None else ""


def version_key(label):
    match = VERSION.fullmatch(label)
    if match is None:
        return None

    release = tuple(int(part) for part in match.group(1).split("."))
    suffix = match.group(2).strip()
    if not suffix:
        return release, 3, ()

    suffix = suffix.lstrip("._-+").lower()
    if suffix.isdigit():
        return release, 4, (int(suffix),)

    suffix_match = re.fullmatch(
        r"(a|alpha|b|beta|pre|preview|rc|post|rev|r)[._-]?(\d*)",
        suffix,
    )
    if suffix_match is None:
        return None

    stage_name, stage_number = suffix_match.groups()
    stages = {
        "a": 0,
        "alpha": 0,
        "b": 1,
        "beta": 1,
        "pre": 2,
        "preview": 2,
        "rc": 2,
        "post": 4,
        "rev": 4,
        "r": 4,
    }
    return release, stages[stage_name], (int(stage_number or "0"),)


def compare_versions(proposed, previous):
    proposed_key = version_key(proposed)
    previous_key = version_key(previous)
    if proposed_key is None or previous_key is None:
        return None

    proposed_release, proposed_stage, proposed_suffix = proposed_key
    previous_release, previous_stage, previous_suffix = previous_key
    width = max(len(proposed_release), len(previous_release))
    proposed_release += (0,) * (width - len(proposed_release))
    previous_release += (0,) * (width - len(previous_release))
    proposed_key = proposed_release, proposed_stage, proposed_suffix
    previous_key = previous_release, previous_stage, previous_suffix
    return (proposed_key > previous_key) - (proposed_key < previous_key)


planned_fd = -1
try:
    _, original_text, _ = read_stable(sys.argv[1])
    planned_fd, planned_text, planned_state = read_stable(
        sys.argv[2],
        writable=True,
    )
    original_lines = original_text.splitlines(keepends=True)
    planned_lines = planned_text.splitlines(keepends=True)
    original_records = repo_records(original_lines)
    planned_records = repo_records(planned_lines)

    if (
        len(original_lines) != len(planned_lines)
        or len(original_records) != len(planned_records)
    ):
        raise ValueError

    revision_indexes = {record[0] for record in original_records}
    for index, (original_line, planned_line) in enumerate(
        zip(original_lines, planned_lines)
    ):
        if original_line != planned_line and index not in revision_indexes:
            raise ValueError

    retained = []
    for original_record, planned_record in zip(
        original_records,
        planned_records,
    ):
        original_index, original_repo, original_match = original_record
        planned_index, planned_repo, planned_match = planned_record
        if (
            original_index != planned_index
            or original_repo != planned_repo
            or original_match.group(1, 2, 3, 6)
            != planned_match.group(1, 2, 3, 6)
        ):
            raise ValueError

        original_revision = original_match.group(4).strip("'\"")
        planned_revision = planned_match.group(4).strip("'\"")
        original_is_frozen = FULL_OBJECT_ID.fullmatch(original_revision) is not None
        planned_is_frozen = FULL_OBJECT_ID.fullmatch(planned_revision) is not None
        if not planned_is_frozen:
            raise ValueError

        previous_label = version_label(original_match)
        proposed_label = version_label(planned_match)
        changed_object = planned_revision.lower() != original_revision.lower()
        if changed_object and FROZEN_COMMENT.fullmatch(planned_match.group(5)) is None:
            raise ValueError

        reason = ""
        if changed_object:
            comparison = compare_versions(proposed_label, previous_label)
            if original_is_frozen:
                if not previous_label or not proposed_label or comparison is None:
                    reason = "incomparable provenance"
                elif comparison < 0:
                    reason = "version downgrade"
                elif comparison == 0:
                    reason = "tag moved to a different object"
            elif not proposed_label:
                raise ValueError
            elif previous_label:
                if (
                    previous_label != proposed_label
                    and (comparison is None or comparison < 0)
                ):
                    raise ValueError
            elif original_revision != proposed_label:
                # A non-version mutable reference can be frozen only at the
                # exact provenance label the user already selected.
                raise ValueError
        elif (
            original_is_frozen
            and previous_label
            and proposed_label != previous_label
        ):
            reason = "version metadata changed without an object change"

        if reason:
            planned_lines[planned_index] = original_lines[original_index]
            retained.append(
                (
                    original_repo,
                    previous_label or original_revision,
                    proposed_label or planned_revision,
                    reason,
                )
            )

    sanitized = "".join(planned_lines).encode("utf-8")
    if len(sanitized) > MAX_CONFIG_SIZE:
        raise ValueError

    linked_before_write = os.lstat(sys.argv[2])
    current = os.fstat(planned_fd)
    if (
        (linked_before_write.st_dev, linked_before_write.st_ino)
        != (planned_state.st_dev, planned_state.st_ino)
        or (current.st_dev, current.st_ino, current.st_uid, current.st_nlink)
        != (
            planned_state.st_dev,
            planned_state.st_ino,
            planned_state.st_uid,
            planned_state.st_nlink,
        )
    ):
        raise ValueError

    if sanitized != planned_text.encode("utf-8"):
        os.lseek(planned_fd, 0, os.SEEK_SET)
        os.ftruncate(planned_fd, 0)
        view = memoryview(sanitized)
        while view:
            written = os.write(planned_fd, view)
            if written <= 0:
                raise OSError
            view = view[written:]
        os.fsync(planned_fd)

    after_write = os.fstat(planned_fd)
    linked_after_write = os.lstat(sys.argv[2])
    if (
        (after_write.st_dev, after_write.st_ino, after_write.st_uid,
         after_write.st_nlink, stat.S_IMODE(after_write.st_mode))
        != (planned_state.st_dev, planned_state.st_ino, planned_state.st_uid,
            planned_state.st_nlink, stat.S_IMODE(planned_state.st_mode))
        or (linked_after_write.st_dev, linked_after_write.st_ino)
        != (after_write.st_dev, after_write.st_ino)
    ):
        raise ValueError

    for record in retained:
        print("\t".join(record))
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
finally:
    if planned_fd >= 0:
        os.close(planned_fd)
PY_PRECOMMIT_GUARD
}

_dev_precommit_live_config_matches() {
  local config_path="$1"
  local expected_fingerprint="$2"

  _dev_update_file_fingerprint "$config_path" || return 1
  [[ "$REPLY" == "$expected_fingerprint" ]]
}

# dev-update-precommit
#   Arguments: --help only.
#   stdout:    none. Plans, tool output, diffs, and diagnostics go to stderr.
#   Effects:   bumps the pre-commit specifier, re-locks, syncs, plans frozen
#              hook revisions privately, rejects unsafe regressions, installs
#              and validates the candidate, publishes it atomically,
#              reinstalls the Git hooks, then runs the file-stage hooks and
#              reports their findings without discarding the publication.
#   Requires:  uv, Python 3.11+, pyproject.toml, .pre-commit-config.yaml, and
#              network access to the configured package and hook repositories.
#              A failed PyPI probe skips only the package specifier query.
#   Status:    0 when every stage succeeds, 1 on an operational or rollback
#              failure or when the published hooks report findings, 2 on
#              invalid arguments.
dev-update-precommit() {
  emulate -L zsh

  local REPLY
  _dev_parse_no_arguments dev-update-precommit "$@" || return $?
  if [[ "$REPLY" == "help" ]]; then
    print -u2 -r -- "Usage: dev-update-precommit"
    print -u2 -r -- \
      "  Publish only safe frozen hook revisions after private validation."
    return 0
  fi

  _dev_header "Updating Pre-commit (Package and Hooks)"
  _dev_require_command uv || return 1
  _dev_require_python_toml || return 1
  _dev_require_file ".pre-commit-config.yaml" || return 1
  _dev_require_file "pyproject.toml" || return 1
  _dev_pypi_validate_config || return 1
  local -i pypi_ready=1
  _dev_update_pypi_ready || pypi_ready=0

  # Let Git abort stalled HTTP transfers itself, without detaching or killing
  # a mutating hook environment transaction. SSH retains its configured policy.
  local -x GIT_HTTP_LOW_SPEED_LIMIT=1
  local -x GIT_HTTP_LOW_SPEED_TIME="$DEV_PYPI_TIMEOUT"

  setopt LOCAL_OPTIONS LOCAL_TRAPS NO_MONITOR

  local project_root="${PWD:A}"
  local project_identity
  project_identity=$(
    _dev_directory_identity "$project_root" "project directory"
  ) || return 1

  local pyproject_path="${project_root}/pyproject.toml"
  local config_path="${project_root}/.pre-commit-config.yaml"
  _dev_owned_file_identity "$pyproject_path" "pyproject.toml" \
    >/dev/null || return 1
  _dev_owned_file_identity "$config_path" "pre-commit configuration" \
    >/dev/null || return 1

  local initial_pyproject_fingerprint=""
  local initial_config_fingerprint=""
  _dev_update_file_fingerprint "$pyproject_path" || return 1
  initial_pyproject_fingerprint="$REPLY"
  _dev_update_file_fingerprint "$config_path" || return 1
  initial_config_fingerprint="$REPLY"

  local transaction_root=""
  local transaction_root_identity=""
  local transaction_dir=""
  local transaction_dir_identity=""
  local -i preserve_workspace=0
  local -a reply=()

  {
    _dev_update_workspace_create || return 1
    transaction_root="${reply[1]}"
    transaction_root_identity="${reply[2]}"
    transaction_dir="${reply[3]}"
    transaction_dir_identity="${reply[4]}"

    local planned_pyproject="${transaction_dir}/pyproject.toml"
    local config_snapshot="${transaction_dir}/pre-commit-config.original"
    local planned_config="${transaction_dir}/pre-commit-config.candidate"
    local planned_pyproject_fingerprint=""
    local config_snapshot_fingerprint=""
    local planned_config_fingerprint=""

    _dev_update_copy_snapshot \
      "$pyproject_path" "$planned_pyproject" \
      "$initial_pyproject_fingerprint" || {
      _dev_error "Could not create the private pre-commit dependency plan."
      return 1
    }
    planned_pyproject_fingerprint="$REPLY"
    _dev_update_copy_snapshot \
      "$config_path" "$config_snapshot" "$initial_config_fingerprint" || {
      _dev_error "Could not snapshot the pre-commit configuration."
      return 1
    }
    config_snapshot_fingerprint="$REPLY"
    _dev_update_copy_snapshot \
      "$config_snapshot" "$planned_config" \
      "$config_snapshot_fingerprint" || {
      _dev_error "Could not create the private hook update plan."
      return 1
    }
    planned_config_fingerprint="$REPLY"

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed during setup."
      return 1
    }

    _dev_info "Planning the pre-commit specifier update..."
    local plan_result
    if (( pypi_ready )); then
      plan_result=$(
        builtin cd -- "$transaction_dir" || return 1
        _dev_update_specifier "pre-commit" 0 all 1
        print -r -- "$_DEV_UPDATE_RESULT"
      ) || plan_result="failed|pre-commit|—|—|planning failed"
    else
      plan_result="failed|pre-commit|—|—|PyPI unreachable"
    fi

    local specifier_status specifier_old specifier_new specifier_note
    IFS='|' read -r specifier_status _ specifier_old specifier_new \
      specifier_note <<< "$plan_result"

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed during planning."
      return 1
    }
    _dev_update_file_fingerprint "$planned_pyproject" || return 1
    planned_pyproject_fingerprint="$REPLY"
    _dev_update_file_fingerprint "$config_snapshot" || return 1
    if [[ "$REPLY" != "$config_snapshot_fingerprint" ]]; then
      _dev_error "The pre-commit configuration snapshot changed unexpectedly."
      return 1
    fi
    _dev_update_file_fingerprint "$planned_config" || return 1
    if [[ "$REPLY" != "$planned_config_fingerprint" ]]; then
      _dev_error "The private hook update plan changed unexpectedly."
      return 1
    fi

    local current_project_identity
    current_project_identity=$(
      _dev_directory_identity "$project_root" "project directory"
    ) || return 1
    if [[ "$current_project_identity" != "$project_identity" \
      || "${PWD:A}" != "$project_root" ]]; then
      _dev_error "The project context changed during pre-commit planning."
      return 1
    fi
    _dev_update_file_fingerprint "$pyproject_path" || return 1
    [[ "$REPLY" == "$initial_pyproject_fingerprint" ]] || {
      _dev_error "pyproject.toml changed during pre-commit planning."
      return 1
    }
    _dev_update_file_fingerprint "$config_path" || return 1
    [[ "$REPLY" == "$initial_config_fingerprint" ]] || {
      _dev_error \
        ".pre-commit-config.yaml changed during pre-commit planning."
      return 1
    }

    case "$specifier_status" in
      updated)
        _dev_info "  pre-commit specifier: $specifier_old -> $specifier_new"
        ;;
      latest)
        _dev_dim "  pre-commit specifier already at latest ($specifier_old)"
        ;;
      failed)
        _dev_warn \
          "  PyPI query failed for pre-commit; continuing with the lockfile."
        ;;
      skipped)
        _dev_dim \
          "  pre-commit specifier not bumped (${specifier_note:-no >= specifier})"
        ;;
    esac

    local invocation_backup=""
    local invocation_backup_fingerprint=""
    local applied_pyproject_fingerprint=""
    if [[ "$specifier_status" == "updated" ]]; then
      _dev_info "Creating an invocation-owned backup of pyproject.toml..."
      reply=()
      _dev_update_prepare_pyproject_backup \
        "$initial_pyproject_fingerprint" || return 1
      invocation_backup="${reply[1]}"
      invocation_backup_fingerprint="${reply[2]}"

      _dev_update_workspace_validate \
        "$transaction_root" "$transaction_root_identity" \
        "$transaction_dir" "$transaction_dir_identity" || {
        _dev_error "The pre-commit update workspace changed before publication."
        return 1
      }
      _dev_update_file_fingerprint "$planned_pyproject" || return 1
      [[ "$REPLY" == "$planned_pyproject_fingerprint" ]] || {
        _dev_error "The finished pre-commit dependency plan changed."
        return 1
      }
      _dev_update_file_fingerprint "$config_snapshot" || return 1
      [[ "$REPLY" == "$config_snapshot_fingerprint" ]] || {
        _dev_error "The pre-commit configuration snapshot changed."
        return 1
      }
      _dev_update_file_fingerprint "$planned_config" || return 1
      [[ "$REPLY" == "$planned_config_fingerprint" ]] || {
        _dev_error "The private hook update plan changed."
        return 1
      }
      _dev_update_file_fingerprint "$pyproject_path" || return 1
      [[ "$REPLY" == "$initial_pyproject_fingerprint" ]] || {
        _dev_error "pyproject.toml changed while its backup was created."
        return 1
      }
      _dev_update_file_fingerprint "$config_path" || return 1
      [[ "$REPLY" == "$initial_config_fingerprint" ]] || {
        _dev_error \
          ".pre-commit-config.yaml changed before dependency publication."
        return 1
      }

      if ! _dev_update_publish_snapshot \
        "$planned_pyproject" "$pyproject_path" \
        "$initial_pyproject_fingerprint" "$planned_pyproject_fingerprint"; then
        _dev_error \
          "Could not publish the pre-commit dependency plan atomically."
        return 1
      fi
      applied_pyproject_fingerprint="$REPLY"
      _dev_info \
        "pre-commit specifier applied to pyproject.toml after its backup."
      _dev_show_diff pyproject.toml

      _dev_info "Re-locking pre-commit..."
      if ! command uv lock --upgrade-package pre-commit >&2; then
        _dev_error \
          "Lock failed — attempting an exact pyproject.toml rollback."
        if ! _dev_update_rollback_pyproject \
          "$invocation_backup" "$invocation_backup_fingerprint" \
          "$applied_pyproject_fingerprint" \
          "$initial_pyproject_fingerprint"; then
          _dev_error "Lock failed and pyproject.toml rollback also failed."
          return 1
        fi
        _dev_warn \
          "pyproject.toml was restored from the exact invocation backup."
        return 1
      fi
    fi

    _dev_info "Syncing the environment..."
    if ! command uv sync --all-groups >&2; then
      _dev_error "Sync failed — pre-commit autoupdate needs the environment."
      return 1
    fi

    reply=()
    _dev_exact_project_python_tool_runner \
      pre-commit pre_commit "uv add --dev pre-commit" configured || {
      _dev_error \
        "Sync completed, but the project pre-commit runner is unavailable."
      return 1
    }
    local -a precommit_runner=("${reply[@]}")

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed before autoupdate."
      return 1
    }
    _dev_update_file_fingerprint "$config_snapshot" || return 1
    [[ "$REPLY" == "$config_snapshot_fingerprint" ]] || {
      _dev_error "The pre-commit configuration snapshot changed."
      return 1
    }
    _dev_update_file_fingerprint "$planned_config" || return 1
    [[ "$REPLY" == "$planned_config_fingerprint" ]] || {
      _dev_error "The private hook update plan changed before autoupdate."
      return 1
    }
    current_project_identity=$(
      _dev_directory_identity "$project_root" "project directory"
    ) || return 1
    if [[ "$current_project_identity" != "$project_identity" \
      || "${PWD:A}" != "$project_root" ]]; then
      _dev_error "The project context changed before pre-commit autoupdate."
      return 1
    fi
    _dev_update_file_fingerprint "$config_path" || return 1
    if [[ "$REPLY" != "$initial_config_fingerprint" ]]; then
      _dev_error \
        ".pre-commit-config.yaml changed before autoupdate; refusing to overwrite it."
      return 1
    fi

    _dev_info "Planning frozen hook revisions (autoupdate)..."
    "${precommit_runner[@]}" autoupdate --freeze \
      --config "$planned_config" >&2
    local -i autoupdate_status=$?

    local observed_config_fingerprint=""
    _dev_update_file_fingerprint "$config_path" \
      && observed_config_fingerprint="$REPLY"

    if [[ -z "$observed_config_fingerprint" \
      || "$observed_config_fingerprint" != \
        "$initial_config_fingerprint" ]]; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed during autoupdate; refusing to overwrite concurrent or unexpected edits."
      _dev_info "Original snapshot retained: $config_snapshot"
      return 1
    fi

    if (( autoupdate_status == 130 || autoupdate_status == 143 )); then
      _dev_warn "pre-commit autoupdate was interrupted."
      return $autoupdate_status
    elif (( autoupdate_status != 0 )); then
      _dev_warn \
        "pre-commit autoupdate was incomplete (status $autoupdate_status); checking the available revision changes."
    fi

    local guard_report=""
    local -i guard_status=0
    guard_report=$(
      _dev_precommit_sanitize_plan "$config_snapshot" "$planned_config"
    ) || guard_status=$?
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed while the private plan was sanitized; refusing to overwrite it."
      _dev_info "Original snapshot retained: $config_snapshot"
      return 1
    fi
    if (( guard_status != 0 )); then
      _dev_error \
        "The private hook update plan was unsafe; it was not published."
      return 1
    fi

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed after autoupdate."
      return 1
    }
    _dev_update_file_fingerprint "$config_snapshot" || return 1
    [[ "$REPLY" == "$config_snapshot_fingerprint" ]] || {
      _dev_error "The pre-commit configuration snapshot changed."
      return 1
    }
    _dev_update_file_fingerprint "$planned_config" || return 1
    planned_config_fingerprint="$REPLY"
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed while the private plan was validated."
      _dev_info "Original snapshot retained: $config_snapshot"
      return 1
    fi

    local guard_record guard_repo guard_previous guard_proposed guard_reason
    local guard_extra
    for guard_record in "${(@f)guard_report}"; do
      [[ -n "$guard_record" ]] || continue
      guard_repo=""
      guard_previous=""
      guard_proposed=""
      guard_reason=""
      guard_extra=""
      IFS=$'\t' read -r guard_repo guard_previous guard_proposed \
        guard_reason guard_extra <<< "$guard_record"
      if [[ -z "$guard_repo" || -z "$guard_previous" \
        || -z "$guard_proposed" || -z "$guard_reason" \
        || -n "$guard_extra" ]]; then
        _dev_error "The hook revision guard returned an invalid record."
        return 1
      fi
      _dev_warn \
        "Kept ${(V)guard_repo} at ${(V)guard_previous}: ${(V)guard_reason}."
      _dev_dim "  Rejected autoupdate proposal: ${(V)guard_proposed}"
    done

    _dev_info "Validating the private hook configuration..."
    "${precommit_runner[@]}" validate-config "$planned_config" >&2
    local -i validate_config_status=$?
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed during candidate validation; refusing to overwrite it."
      _dev_info "Original snapshot retained: $config_snapshot"
      return 1
    fi
    if (( validate_config_status != 0 )); then
      _dev_error \
        "The private hook configuration is invalid; it was not published."
      return 1
    fi

    _dev_info "Installing every planned hook environment before publication..."
    "${precommit_runner[@]}" install-hooks \
      --config "$planned_config" >&2
    local -i install_hooks_status=$?
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed while hook environments were installed; refusing to overwrite it."
      _dev_info "Original snapshot retained: $config_snapshot"
      return 1
    fi
    if (( install_hooks_status != 0 )); then
      _dev_error \
        "A planned hook environment could not be installed; the candidate was not published."
      return 1
    fi

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed during validation."
      return 1
    }
    _dev_update_file_fingerprint "$planned_config" || return 1
    [[ "$REPLY" == "$planned_config_fingerprint" ]] || {
      _dev_error "The private hook update plan changed during validation."
      return 1
    }
    current_project_identity=$(
      _dev_directory_identity "$project_root" "project directory"
    ) || return 1
    if [[ "$current_project_identity" != "$project_identity" \
      || "${PWD:A}" != "$project_root" ]]; then
      _dev_error "The project context changed during hook validation."
      return 1
    fi
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed during private hook validation."
      _dev_info "Original snapshot retained: $config_snapshot"
      return 1
    fi

    local expected_installed_config_fingerprint="$initial_config_fingerprint"
    if [[ "${planned_config_fingerprint##*:}" != \
      "${config_snapshot_fingerprint##*:}" ]]; then
      if ! _dev_update_publish_snapshot \
        "$planned_config" "$config_path" \
        "$initial_config_fingerprint" "$planned_config_fingerprint"; then
        if ! _dev_precommit_live_config_matches \
          "$config_path" "$initial_config_fingerprint"; then
          preserve_workspace=1
          _dev_error \
            ".pre-commit-config.yaml changed at publication; refusing recovery overwrite."
          _dev_info "Original snapshot retained: $config_snapshot"
          return 1
        fi
        _dev_error "Could not publish the frozen hook revision plan."
        return 1
      fi
      expected_installed_config_fingerprint="$REPLY"
      _dev_success "Published the validated frozen hook revisions."
    else
      _dev_dim "  No safe hook revision change needs publication."
    fi

    _dev_info "Reinstalling hooks..."
    "${precommit_runner[@]}" install --install-hooks >&2
    local -i hook_install_status=$?
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$expected_installed_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed while Git hooks were installed; refusing recovery overwrite."
      _dev_info "Original snapshot retained: $config_snapshot"
      return 1
    fi
    if (( hook_install_status != 0 )); then
      _dev_warn "Hook installation failed after revision validation."
      return 1
    fi

    # Hook findings are project findings, not update failures. They are
    # reported after the validated revisions are published and the Git hooks
    # are installed, so a lint finding or a fixer rewrite cannot discard a
    # safe update or leave the repository on stale hook revisions.
    _dev_info "Running the configured file-stage hooks against all files..."
    "${precommit_runner[@]}" run --all-files --config "$config_path" >&2
    local -i hook_run_status=$?
    if (( hook_run_status != 0 )); then
      _dev_warn "Some hooks reported issues (exit status: $hook_run_status)."
      _dev_info \
        "The frozen hook revisions stay published and the Git hooks stay installed."
      _dev_info "Review the findings above, then rerun: dev-run-hooks"
    fi

    if (( autoupdate_status != 0 )); then
      _dev_warn \
        "Validated hook revisions were kept, but some repositories could not be updated."
      _dev_info "Retry the remaining updates: dev-menu dev-update-precommit"
    fi
    if [[ "$specifier_status" == "failed" ]]; then
      _dev_warn \
        "Hooks were validated, but the pre-commit package query or plan failed."
      _dev_info "Retry the package update: dev-menu dev-update-precommit"
      return 1
    fi
    (( autoupdate_status != 0 )) && return 1
    if (( hook_run_status != 0 )); then
      _dev_warn \
        "Pre-commit revisions were published, but the hook run reported issues."
      return 1
    fi
    _dev_success \
      "Pre-commit maintenance completed with safe frozen hook revisions."
    return 0
  } always {
    _dev_pypi_cache_cleanup
    if (( preserve_workspace )); then
      _dev_warn \
        "The private update workspace was retained for manual recovery: $transaction_dir"
    else
      _dev_update_workspace_cleanup \
        "$transaction_root" "$transaction_root_identity" \
        "$transaction_dir" "$transaction_dir_identity"
    fi
  }
}

# --- Full maintenance -------------------------------------------------------

# Runs one aggregate maintenance step and records its outcome in the caller's
# dynamically scoped step_labels, step_outcomes, and failures variables.
_dev_update_all_step() {
  local label="$1"
  local timed_label="$2"
  shift 2

  local -i step_status=0
  _dev_timed "$timed_label" "$@" || step_status=$?

  step_labels+=("$label")
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
  local -i failures=0
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
