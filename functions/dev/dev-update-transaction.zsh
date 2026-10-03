#!/usr/bin/env zsh
# =============================================================================
# Dev Update Transaction: workspaces, fingerprints, publication, rollback
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-common.zsh and dev-state.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_UPDATE_TRANSACTION_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

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

typeset -g _DEV_UPDATE_TRANSACTION_SOURCED=1
