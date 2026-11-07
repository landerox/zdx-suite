#!/usr/bin/env zsh
# =============================================================================
# Dev Update Pre-commit: guarded frozen hook revisions and package update
# =============================================================================
#
# Loaded by dev-menu.zsh after dev-state.zsh, dev-pypi.zsh,
# dev-update-transaction.zsh, and dev-update-specifiers.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_DEV_UPDATE_PRECOMMIT_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Pre-commit -------------------------------------------------------------

# Sanitizes a private pre-commit autoupdate candidate in place. The updater may
# change only remote `rev:` lines, every changed revision must be a frozen Git
# object, and an already immutable revision is retained when the proposed tag
# is older, incomparable, or was moved to a different object.
#
# stdout: one tab-separated `outcome, repo, previous, final, detail` record
#         for every remote revision. The outcome is `current` for an untouched
#         revision, `updated` for an accepted change, or `kept` when the guard
#         retained the previous revision; a kept record's detail is
#         `<proposed>: <reason>`. Other details are `-`.
_dev_precommit_sanitize_plan() {
  local original_config="$1"
  local planned_config="$2"

  local REPLY=""
  _dev_python_toml_resolve || return 1
  command "$REPLY" -I -S - "$original_config" "$planned_config" \
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

    results = []
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
        changed_object = planned_revision.lower() != original_revision.lower()
        # Only a changed target must be an immutable object; a repository that
        # autoupdate left untouched keeps its existing revision line.
        if changed_object and not planned_is_frozen:
            raise ValueError

        previous_label = version_label(original_match)
        proposed_label = version_label(planned_match)
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

        previous_display = previous_label or original_revision
        if reason:
            planned_lines[planned_index] = original_lines[original_index]
            results.append(
                (
                    "kept",
                    original_repo,
                    previous_display,
                    previous_display,
                    f"{proposed_label or planned_revision}: {reason}",
                )
            )
        elif changed_object:
            results.append(
                (
                    "updated",
                    original_repo,
                    previous_display,
                    proposed_label or planned_revision,
                    "-",
                )
            )
        else:
            results.append(
                ("current", original_repo, previous_display, previous_display, "-")
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

    for record in results:
        if any(not field or "\t" in field or "\n" in field for field in record):
            raise ValueError
        print("\t".join(record))
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
finally:
    if planned_fd >= 0:
        os.close(planned_fd)
PY_PRECOMMIT_GUARD
}

# REPLY: the Git hook types that `pre-commit install` installs for a config:
# pre-commit's own default, a flow-style default_install_hook_types list, or
# empty when another form makes the list unknown.
_dev_precommit_hook_types() {
  local config_file="${1:-}" line="" MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=() hook_types=()
  REPLY="pre-commit"
  [[ -f "$config_file" && ! -L "$config_file" ]] || return 0
  for line in "${(@f)$(command head -c 262144 -- "$config_file" 2>/dev/null)}"; do
    [[ "$line" == default_install_hook_types:* ]] || continue
    REPLY=""
    [[ "$line" =~ '^default_install_hook_types:[[:space:]]*\[([-a-z, ]*)\][[:space:]]*(#.*)?$' ]] \
      || return 0
    hook_types=(${(s:,:)match[1]})
    hook_types=("${(@)hook_types//[[:space:]]/}")
    hook_types=("${(@)hook_types:#}")
    REPLY="${(j:, :)hook_types}"
    return 0
  done
}

_dev_precommit_live_config_matches() {
  local config_path="$1"
  local expected_fingerprint="$2"

  _dev_update_file_fingerprint "$config_path" || return 1
  [[ "$REPLY" == "$expected_fingerprint" ]]
}

# REPLY: a display-only repository identifier without URL userinfo, query,
# or fragment data. The original repository value remains the updater's data.
_dev_precommit_display_repo() {
  emulate -L zsh
  local repository="${1-}" scheme authority remainder
  repository="${repository%%\?*}"
  repository="${repository%%\#*}"
  if [[ "$repository" == *://* ]]; then
    scheme="${repository%%://*}"
    remainder="${repository#*://}"
    authority="${remainder%%/*}"
    repository="${scheme}://${authority##*@}${remainder#"$authority"}"
  elif [[ "$repository" == *@*:* ]]; then
    repository="${repository##*@}"
  fi
  REPLY="${repository#https://github.com/}"
}

# dev-update-precommit
#   Arguments: --yes | -y | --dry-run | --help
#   stdout:    none. Plans, tool output, diffs, and diagnostics go to stderr.
#   Effects:   bumps the pre-commit specifier, re-locks, syncs, plans frozen
#              hook revisions privately, rejects unsafe regressions, installs
#              and validates the candidate, publishes it atomically,
#              reinstalls the Git hooks, then runs the file-stage hooks and
#              reports their findings without discarding the publication.
#              Execution requires an explicit upstream trust decision; a dry
#              run uses an installed runner and a private cache to preview only.
#   Requires:  uv, Python 3.11+, pyproject.toml, .pre-commit-config.yaml, and
#              network access to the configured package and hook repositories.
#              A failed PyPI probe skips only the package specifier query.
#   Status:    0 on success, a passive preview, or a declined trust decision;
#              1 when consent is unavailable, validation or a stage fails,
#              or the published hooks report findings; 2 on invalid arguments.
#              Interrupted stages return 130 or 143.
dev-update-precommit() {
  emulate -L zsh
  (( ${+_DEV_RUN_PYTHON} )) || local _DEV_RUN_PYTHON=""

  local REPLY
  local -i auto_yes=0 dry_run=0 show_help=0
  local option
  for option in "$@"; do
    case "$option" in
      --yes|-y) auto_yes=1 ;;
      --dry-run) dry_run=1 ;;
      -h|--help) show_help=1 ;;
      *) _dev_error "Unknown option: $option"; return 2 ;;
    esac
  done
  if (( show_help )); then
    (( $# == 1 )) || {
      _dev_error "Help does not accept additional arguments."
      return 2
    }
    print -u2 -r -- "Usage: dev-update-precommit [--yes] [--dry-run]"
    print -u2 -r -- \
      "  Review dynamic upstream package and hook updates before installing and running code."
    print -u2 -r -- \
      "  --dry-run   Preview with already-installed pre-commit; never install or publish."
    print -u2 -r -- \
      "  --yes, -y   Trust this upstream scope without prompting; validation still applies."
    return 0
  fi

  setopt LOCAL_OPTIONS LOCAL_TRAPS NO_MONITOR
  local -i interrupted=0
  trap 'interrupted=130' INT
  trap 'interrupted=143' TERM

  local -i _DEV_PREVIEW_EXEC_TRUST=$dry_run
  (( ${+_DEV_PREVIEW_EXEC_IDENTITIES} )) \
    || local -A _DEV_PREVIEW_EXEC_IDENTITIES=()
  _dev_header "Updating Pre-commit (Package and Hooks)"
  _dev_require_command uv || return $(( interrupted ? interrupted : 1 ))
  _dev_require_python_toml || return $(( interrupted ? interrupted : 1 ))
  _dev_require_file ".pre-commit-config.yaml" || return $(( interrupted ? interrupted : 1 ))
  _dev_require_file "pyproject.toml" || return $(( interrupted ? interrupted : 1 ))
  _dev_pypi_validate_config || return $(( interrupted ? interrupted : 1 ))
  local -i pypi_ready=1
  _dev_update_pypi_ready || pypi_ready=0

  # Let Git abort stalled HTTP transfers itself, without detaching or killing
  # a mutating hook environment transaction. SSH retains its configured policy.
  local -x GIT_HTTP_LOW_SPEED_LIMIT=1
  local -x GIT_HTTP_LOW_SPEED_TIME="$DEV_PYPI_TIMEOUT"

  local project_root="${PWD:A}"
  local project_identity
  project_identity=$(
    _dev_directory_identity "$project_root" "project directory"
  ) || return $(( interrupted ? interrupted : 1 ))

  local pyproject_path="${project_root}/pyproject.toml"
  local config_path="${project_root}/.pre-commit-config.yaml"
  _dev_owned_file_identity "$pyproject_path" "pyproject.toml" \
    >/dev/null || return $(( interrupted ? interrupted : 1 ))
  _dev_owned_file_identity "$config_path" "pre-commit configuration" \
    >/dev/null || return $(( interrupted ? interrupted : 1 ))

  local initial_pyproject_fingerprint=""
  local initial_config_fingerprint=""
  _dev_update_file_fingerprint "$pyproject_path" || return $(( interrupted ? interrupted : 1 ))
  initial_pyproject_fingerprint="$REPLY"
  _dev_update_file_fingerprint "$config_path" || return $(( interrupted ? interrupted : 1 ))
  initial_config_fingerprint="$REPLY"

  # An aggregate's --yes authorizes only the configuration it displayed.
  # These dynamically scoped facts exist for that invocation alone.
  if [[ -n "${_DEV_PRECOMMIT_REVIEW_CONFIG_PATH:-}" \
    && ( "$config_path" != "$_DEV_PRECOMMIT_REVIEW_CONFIG_PATH" \
      || "$initial_config_fingerprint" != \
        "${_DEV_PRECOMMIT_REVIEW_CONFIG_FINGERPRINT:-}" ) ]]; then
    _dev_error \
      "The pre-commit configuration differs from the authorized aggregate plan; start a new invocation to review it."
    return $(( interrupted ? interrupted : 1 ))
  fi

  local transaction_root=""
  local transaction_root_identity=""
  local transaction_dir=""
  local transaction_dir_identity=""
  local -i preserve_workspace=0
  local -a reply=()

  {
    (( interrupted )) && return $interrupted
    _dev_update_workspace_create || return $(( interrupted ? interrupted : 1 ))
    transaction_root="${reply[1]}"
    transaction_root_identity="${reply[2]}"
    transaction_dir="${reply[3]}"
    transaction_dir_identity="${reply[4]}"

    local original_pyproject="${transaction_dir}/pyproject.toml.original"
    local planned_pyproject="${transaction_dir}/pyproject.toml"
    local config_snapshot="${transaction_dir}/pre-commit-config.original"
    local planned_config="${transaction_dir}/pre-commit-config.candidate"
    local original_pyproject_fingerprint=""
    local planned_pyproject_fingerprint=""
    local config_snapshot_fingerprint=""
    local planned_config_fingerprint=""

    _dev_update_copy_snapshot \
      "$pyproject_path" "$original_pyproject" \
      "$initial_pyproject_fingerprint" || {
      _dev_error "Could not snapshot pyproject.toml for the pre-commit plan."
      return $(( interrupted ? interrupted : 1 ))
    }
    original_pyproject_fingerprint="$REPLY"
    _dev_update_copy_snapshot \
      "$original_pyproject" "$planned_pyproject" \
      "$original_pyproject_fingerprint" || {
      _dev_error "Could not create the private pre-commit dependency plan."
      return $(( interrupted ? interrupted : 1 ))
    }
    planned_pyproject_fingerprint="$REPLY"
    _dev_update_copy_snapshot \
      "$config_path" "$config_snapshot" "$initial_config_fingerprint" || {
      _dev_error "Could not snapshot the pre-commit configuration."
      return $(( interrupted ? interrupted : 1 ))
    }
    config_snapshot_fingerprint="$REPLY"
    _dev_update_copy_snapshot \
      "$config_snapshot" "$planned_config" \
      "$config_snapshot_fingerprint" || {
      _dev_error "Could not create the private hook update plan."
      return $(( interrupted ? interrupted : 1 ))
    }
    planned_config_fingerprint="$REPLY"

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed during setup."
      return $(( interrupted ? interrupted : 1 ))
    }

    (( interrupted )) && return $interrupted
    _dev_info "Planning the pre-commit specifier update..."
    local plan_result
    if (( pypi_ready )); then
      # Create the invocation cache in this shell so the always block removes
      # it; a first initialization inside the planning subshell would leak.
      _dev_pypi_cache_init 2>/dev/null || true
      plan_result=$(
        builtin cd -- "$transaction_dir" || return $(( interrupted ? interrupted : 1 ))
        _dev_update_specifier "pre-commit" 0 all 1
        print -r -- "$_DEV_UPDATE_RESULT"
      ) || plan_result="failed|pre-commit|—|—|planning failed"
    else
      plan_result="failed|pre-commit|—|—|PyPI unreachable"
    fi

    local specifier_status specifier_old specifier_new specifier_note
    IFS='|' read -r specifier_status _ specifier_old specifier_new \
      specifier_note <<< "$plan_result"
    (( interrupted )) && return $interrupted

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed during planning."
      return $(( interrupted ? interrupted : 1 ))
    }
    _dev_update_file_fingerprint "$planned_pyproject" || return $(( interrupted ? interrupted : 1 ))
    planned_pyproject_fingerprint="$REPLY"
    _dev_update_file_fingerprint "$config_snapshot" || return $(( interrupted ? interrupted : 1 ))
    if [[ "$REPLY" != "$config_snapshot_fingerprint" ]]; then
      _dev_error "The pre-commit configuration snapshot changed unexpectedly."
      return $(( interrupted ? interrupted : 1 ))
    fi
    _dev_update_file_fingerprint "$planned_config" || return $(( interrupted ? interrupted : 1 ))
    if [[ "$REPLY" != "$planned_config_fingerprint" ]]; then
      _dev_error "The private hook update plan changed unexpectedly."
      return $(( interrupted ? interrupted : 1 ))
    fi

    local current_project_identity
    current_project_identity=$(
      _dev_directory_identity "$project_root" "project directory"
    ) || return $(( interrupted ? interrupted : 1 ))
    if [[ "$current_project_identity" != "$project_identity" \
      || "${PWD:A}" != "$project_root" ]]; then
      _dev_error "The project context changed during pre-commit planning."
      return $(( interrupted ? interrupted : 1 ))
    fi
    _dev_update_file_fingerprint "$pyproject_path" || return $(( interrupted ? interrupted : 1 ))
    [[ "$REPLY" == "$initial_pyproject_fingerprint" ]] || {
      _dev_error "pyproject.toml changed during pre-commit planning."
      return $(( interrupted ? interrupted : 1 ))
    }
    _dev_update_file_fingerprint "$config_path" || return $(( interrupted ? interrupted : 1 ))
    [[ "$REPLY" == "$initial_config_fingerprint" ]] || {
      _dev_error \
        ".pre-commit-config.yaml changed during pre-commit planning."
      return $(( interrupted ? interrupted : 1 ))
    }

    _dev_update_show_planned_diff \
      "$original_pyproject" "$original_pyproject_fingerprint" \
      "$planned_pyproject" "$planned_pyproject_fingerprint" || return $(( interrupted ? interrupted : 1 ))
    (( interrupted )) && return $interrupted

    case "$specifier_status" in
      updated)
        _dev_info "pre-commit specifier: $specifier_old → $specifier_new"
        ;;
      latest)
        _dev_dim "pre-commit specifier already at latest ($specifier_old)"
        ;;
      failed)
        _dev_warn \
          "PyPI query failed for pre-commit; continuing with the lockfile."
        ;;
      skipped)
        _dev_dim \
          "pre-commit specifier not bumped (${specifier_note:-no >= specifier})"
        ;;
    esac

    _dev_label "Configuration" "$config_path"
    _dev_label "Configuration SHA256" "${initial_config_fingerprint##*:}"
    _dev_label "Project SHA256" "${initial_pyproject_fingerprint##*:}"
    _dev_warn \
      "Trust scope: dynamic upstream pre-commit packages and every hook repository declared by this configuration, including local hooks."
    _dev_info \
      "Installed pre-commit resolves upstream revisions with autoupdate --freeze --config <private candidate>; this can access the network without executing newly resolved hooks."
    _dev_info \
      "Execution may publish pyproject.toml, run uv lock --upgrade-package pre-commit and uv sync --all-groups, then validate-config <private candidate>, install-hooks --config <private candidate>, publish frozen revisions, install --install-hooks, and run --all-files --config <project configuration>."
    _dev_warn \
      "Package builds and hook installation can execute upstream code; hooks may rewrite project files. Frozen revisions do not attest that upstream code is safe."

    if (( ! dry_run )); then
      local -i previous_auto_yes=$_DEV_AUTO_YES
      local trust_outcome="declined"
      {
        (( auto_yes )) && _DEV_AUTO_YES=1
        trust_outcome=$(_dev_confirm_outcome \
          "Trust this upstream scope and install and execute its package and hook code?")
      } always {
        _DEV_AUTO_YES=$previous_auto_yes
      }
      (( interrupted )) && return $interrupted
      case "$trust_outcome" in
        confirmed) ;;
        unavailable)
          _dev_error \
            "Pre-commit updates need an explicit trust decision; pass --yes in a non-interactive shell."
          return $(( interrupted ? interrupted : 1 ))
          ;;
        *)
          _dev_info "Cancelled. No package or hook update was started."
          return 0
          ;;
      esac
    fi

    (( interrupted )) && return $interrupted
    # Consent does not authorize a different project or configuration.
    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || return $(( interrupted ? interrupted : 1 ))
    current_project_identity=$(
      _dev_directory_identity "$project_root" "project directory"
    ) || return $(( interrupted ? interrupted : 1 ))
    [[ "$current_project_identity" == "$project_identity" \
      && "${PWD:A}" == "$project_root" ]] || {
      _dev_error "The project context changed during trust review."
      return $(( interrupted ? interrupted : 1 ))
    }
    _dev_update_file_fingerprint "$pyproject_path" || return $(( interrupted ? interrupted : 1 ))
    [[ "$REPLY" == "$initial_pyproject_fingerprint" ]] || {
      _dev_error "pyproject.toml changed during trust review."
      return $(( interrupted ? interrupted : 1 ))
    }
    _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint" || {
      _dev_error ".pre-commit-config.yaml changed during trust review."
      return $(( interrupted ? interrupted : 1 ))
    }

    local invocation_backup=""
    local invocation_backup_fingerprint=""
    local applied_pyproject_fingerprint=""
    if [[ "$specifier_status" == "updated" ]] && (( ! dry_run )); then
      (( interrupted )) && return $interrupted
      _dev_info "Creating an invocation-owned backup of pyproject.toml..."
      reply=()
      _dev_update_prepare_pyproject_backup \
        "$initial_pyproject_fingerprint" || return $(( interrupted ? interrupted : 1 ))
      invocation_backup="${reply[1]}"
      invocation_backup_fingerprint="${reply[2]}"
      (( interrupted )) && return $interrupted

      _dev_update_workspace_validate \
        "$transaction_root" "$transaction_root_identity" \
        "$transaction_dir" "$transaction_dir_identity" || {
        _dev_error "The pre-commit update workspace changed before publication."
        return $(( interrupted ? interrupted : 1 ))
      }
      _dev_update_file_fingerprint "$planned_pyproject" || return $(( interrupted ? interrupted : 1 ))
      [[ "$REPLY" == "$planned_pyproject_fingerprint" ]] || {
        _dev_error "The finished pre-commit dependency plan changed."
        return $(( interrupted ? interrupted : 1 ))
      }
      _dev_update_file_fingerprint "$config_snapshot" || return $(( interrupted ? interrupted : 1 ))
      [[ "$REPLY" == "$config_snapshot_fingerprint" ]] || {
        _dev_error "The pre-commit configuration snapshot changed."
        return $(( interrupted ? interrupted : 1 ))
      }
      _dev_update_file_fingerprint "$planned_config" || return $(( interrupted ? interrupted : 1 ))
      [[ "$REPLY" == "$planned_config_fingerprint" ]] || {
        _dev_error "The private hook update plan changed."
        return $(( interrupted ? interrupted : 1 ))
      }
      _dev_update_file_fingerprint "$pyproject_path" || return $(( interrupted ? interrupted : 1 ))
      [[ "$REPLY" == "$initial_pyproject_fingerprint" ]] || {
        _dev_error "pyproject.toml changed while its backup was created."
        return $(( interrupted ? interrupted : 1 ))
      }
      _dev_update_file_fingerprint "$config_path" || return $(( interrupted ? interrupted : 1 ))
      [[ "$REPLY" == "$initial_config_fingerprint" ]] || {
        _dev_error \
          ".pre-commit-config.yaml changed before dependency publication."
        return $(( interrupted ? interrupted : 1 ))
      }

      (( interrupted )) && return $interrupted
      if ! _dev_update_publish_snapshot \
        "$planned_pyproject" "$pyproject_path" \
        "$initial_pyproject_fingerprint" "$planned_pyproject_fingerprint"; then
        _dev_error \
          "Could not publish the pre-commit dependency plan atomically."
        return $(( interrupted ? interrupted : 1 ))
      fi
      applied_pyproject_fingerprint="$REPLY"
      _dev_info \
        "pre-commit specifier applied to pyproject.toml after its backup."

      local -i precommit_lock_status=0
      if (( ! interrupted )); then
        _dev_run_captured "uv lock --upgrade-package pre-commit" \
          command uv lock --upgrade-package pre-commit \
          || precommit_lock_status=$?
      fi
      case "$precommit_lock_status" in
        130|143) interrupted=$precommit_lock_status ;;
      esac
      if (( interrupted || precommit_lock_status != 0 )); then
        if (( interrupted )); then
          _dev_error \
            "Interrupted — attempting an exact pyproject.toml rollback."
        else
          _dev_error \
            "Lock failed — attempting an exact pyproject.toml rollback."
        fi
        if ! _dev_update_rollback_pyproject \
          "$invocation_backup" "$invocation_backup_fingerprint" \
          "$applied_pyproject_fingerprint" \
          "$initial_pyproject_fingerprint"; then
          _dev_error "Lock failed and pyproject.toml rollback also failed."
          _dev_report_result failed "lock failed; pyproject.toml rollback failed"
          return $(( interrupted ? interrupted : 1 ))
        fi
        _dev_warn \
          "pyproject.toml was restored from the exact invocation backup."
        _dev_report_result failed "lock failed; pyproject.toml restored"
        return $(( interrupted ? interrupted : 1 ))
      fi
    fi

    (( interrupted )) && return $interrupted
    if (( ! dry_run )); then
      local -i precommit_sync_status=0
      _dev_run_captured "uv sync --all-groups" \
        command uv sync --all-groups || precommit_sync_status=$?
      case "$precommit_sync_status" in
        130|143) interrupted=$precommit_sync_status ;;
      esac
      if (( interrupted || precommit_sync_status != 0 )); then
        _dev_error "Sync failed — pre-commit autoupdate needs the environment."
        _dev_report_result failed "sync failed"
        return $(( interrupted ? interrupted : 1 ))
      fi

    fi

    (( interrupted )) && return $interrupted
    reply=()
    _dev_exact_project_python_tool_runner \
      pre-commit pre_commit "uv add --dev pre-commit" configured || {
      if (( dry_run )); then
        _dev_error \
          "A dry run requires already-installed project pre-commit; install it through your reviewed project workflow first."
      else
        _dev_error \
          "Sync completed, but the project pre-commit runner is unavailable."
      fi
      return $(( interrupted ? interrupted : 1 ))
    }
    local -a precommit_runner=("${reply[@]}")
    local preview_runner_fingerprint=""
    if (( dry_run )); then
      # Execute only the existing runner, never uv run or a newly synced tool.
      _dev_preview_exec_guard "${precommit_runner[1]}" || {
        _dev_error "The installed preview runner is not trusted."
        return $(( interrupted ? interrupted : 1 ))
      }
      local -A preview_runner_stat
      zmodload -F zsh/stat b:zstat || return $(( interrupted ? interrupted : 1 ))
      zstat -H preview_runner_stat -- "${precommit_runner[1]}" \
        2>/dev/null || return $(( interrupted ? interrupted : 1 ))
      [[ -f "${precommit_runner[1]}" && -x "${precommit_runner[1]}" \
        && ( "${preview_runner_stat[uid]}" == "$EUID" \
          || "${preview_runner_stat[uid]}" == 0 ) ]] \
        && (( (preview_runner_stat[mode] & 8#022) == 0 )) || {
        _dev_error "The installed preview runner is not trusted."
        return $(( interrupted ? interrupted : 1 ))
      }
      _dev_update_file_fingerprint "${precommit_runner[1]:A}" || return $(( interrupted ? interrupted : 1 ))
      preview_runner_fingerprint="$REPLY"
      local -x PRE_COMMIT_HOME="${transaction_dir}/pre-commit-cache"
      command mkdir -m 700 -- "$PRE_COMMIT_HOME" || return $(( interrupted ? interrupted : 1 ))
      _dev_info \
        "DRY-RUN — executing installed pre-commit only, with an invocation-private cache; no package or hook installation or publication."
    fi

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed before autoupdate."
      return $(( interrupted ? interrupted : 1 ))
    }
    _dev_update_file_fingerprint "$config_snapshot" || return $(( interrupted ? interrupted : 1 ))
    [[ "$REPLY" == "$config_snapshot_fingerprint" ]] || {
      _dev_error "The pre-commit configuration snapshot changed."
      return $(( interrupted ? interrupted : 1 ))
    }
    _dev_update_file_fingerprint "$planned_config" || return $(( interrupted ? interrupted : 1 ))
    [[ "$REPLY" == "$planned_config_fingerprint" ]] || {
      _dev_error "The private hook update plan changed before autoupdate."
      return $(( interrupted ? interrupted : 1 ))
    }
    current_project_identity=$(
      _dev_directory_identity "$project_root" "project directory"
    ) || return $(( interrupted ? interrupted : 1 ))
    if [[ "$current_project_identity" != "$project_identity" \
      || "${PWD:A}" != "$project_root" ]]; then
      _dev_error "The project context changed before pre-commit autoupdate."
      return $(( interrupted ? interrupted : 1 ))
    fi
    _dev_update_file_fingerprint "$config_path" || return $(( interrupted ? interrupted : 1 ))
    if [[ "$REPLY" != "$initial_config_fingerprint" ]]; then
      _dev_error \
        ".pre-commit-config.yaml changed before autoupdate; refusing to overwrite it."
      return $(( interrupted ? interrupted : 1 ))
    fi

    local -i autoupdate_status=0
    if (( dry_run )); then
      _dev_preview_exec_guard "${precommit_runner[1]}" || {
        _dev_error "The installed preview runner changed before execution."
        return $(( interrupted ? interrupted : 1 ))
      }
      _dev_update_file_fingerprint "${precommit_runner[1]:A}" || return $(( interrupted ? interrupted : 1 ))
      [[ "$REPLY" == "$preview_runner_fingerprint" ]] || {
        _dev_error "The installed preview runner changed before execution."
        return $(( interrupted ? interrupted : 1 ))
      }
    fi
    (( interrupted )) && return $interrupted
    _dev_run_captured "pre-commit autoupdate --freeze" \
      "${precommit_runner[@]}" autoupdate --freeze \
      --config "$planned_config" || autoupdate_status=$?

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
      return $(( interrupted ? interrupted : 1 ))
    fi

    if (( interrupted || autoupdate_status == 130 || autoupdate_status == 143 )); then
      _dev_warn "pre-commit autoupdate was interrupted."
      return $(( interrupted ? interrupted : autoupdate_status ))
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
      return $(( interrupted ? interrupted : 1 ))
    fi
    if (( guard_status != 0 )); then
      _dev_error \
        "The private hook update plan was unsafe; it was not published."
      return $(( interrupted ? interrupted : 1 ))
    fi

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed after autoupdate."
      return $(( interrupted ? interrupted : 1 ))
    }
    _dev_update_file_fingerprint "$config_snapshot" || return $(( interrupted ? interrupted : 1 ))
    [[ "$REPLY" == "$config_snapshot_fingerprint" ]] || {
      _dev_error "The pre-commit configuration snapshot changed."
      return $(( interrupted ? interrupted : 1 ))
    }
    _dev_update_file_fingerprint "$planned_config" || return $(( interrupted ? interrupted : 1 ))
    planned_config_fingerprint="$REPLY"
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed while the private plan was validated."
      _dev_info "Original snapshot retained: $config_snapshot"
      return $(( interrupted ? interrupted : 1 ))
    fi

    local guard_record guard_outcome guard_repo guard_previous guard_final
    local guard_detail guard_display
    local -a guard_fields=() revision_rows=()
    local -i updated_revisions=0 kept_revisions=0 current_revisions=0
    for guard_record in "${(@f)guard_report}"; do
      [[ -n "$guard_record" ]] || continue
      guard_fields=("${(@ps:\t:)guard_record}")
      guard_outcome="${guard_fields[1]:-}"
      guard_repo="${guard_fields[2]:-}"
      guard_previous="${guard_fields[3]:-}"
      guard_final="${guard_fields[4]:-}"
      guard_detail="${guard_fields[5]:-}"
      if (( ${#guard_fields[@]} != 5 )) \
        || [[ "$guard_outcome" != (current|updated|kept) \
          || -z "$guard_repo" || -z "$guard_previous" \
          || -z "$guard_final" || -z "$guard_detail" ]]; then
        _dev_error "The hook revision guard returned an invalid record."
        return $(( interrupted ? interrupted : 1 ))
      fi
      _dev_precommit_display_repo "$guard_repo"
      guard_display="$REPLY"
      case "$guard_outcome" in
        current)
          (( ++current_revisions ))
          revision_rows+=("$guard_display"$'\t'"$guard_final"$'\t'current$'\t')
          ;;
        updated)
          (( ++updated_revisions ))
          revision_rows+=("$guard_display"$'\t'"$guard_final"$'\t'updated$'\t'"from $guard_previous")
          ;;
        kept)
          (( ++kept_revisions ))
          _dev_warn \
            "Kept ${(V)guard_display} at ${(V)guard_previous}: ${(V)${guard_detail#*: }}."
          _dev_dim "  Rejected autoupdate proposal: ${(V)${guard_detail%%: *}}"
          revision_rows+=("$guard_display"$'\t'"$guard_final"$'\t'skipped$'\t'"kept; autoupdate proposed ${guard_detail%%: *} (${guard_detail#*: })")
          ;;
      esac
    done
    (( ${#revision_rows[@]} > 0 )) && _dev_table --outcome-column 3 \
      $'Hook repository\tRevision\tResult\tDetail' "${revision_rows[@]}"

    (( interrupted )) && return $interrupted
    if (( dry_run )); then
      _dev_info "Dry run complete. No package, hook, or project file was installed or published."
      (( autoupdate_status == 0 )) \
        && [[ "$specifier_status" != failed ]]
      return $?
    fi

    (( interrupted )) && return $interrupted
    local -i validate_config_status=0
    _dev_run_captured "pre-commit validate-config" \
      "${precommit_runner[@]}" validate-config "$planned_config" \
      || validate_config_status=$?
    case "$validate_config_status" in
      130|143) interrupted=$validate_config_status ;;
    esac
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed during candidate validation; refusing to overwrite it."
      _dev_info "Original snapshot retained: $config_snapshot"
      return $(( interrupted ? interrupted : 1 ))
    fi
    (( interrupted )) && return $interrupted
    if (( validate_config_status != 0 )); then
      _dev_error \
        "The private hook configuration is invalid; it was not published."
      return $(( interrupted ? interrupted : 1 ))
    fi

    (( interrupted )) && return $interrupted
    local -i install_hooks_status=0
    _dev_run_captured "pre-commit install-hooks" \
      "${precommit_runner[@]}" install-hooks \
      --config "$planned_config" || install_hooks_status=$?
    case "$install_hooks_status" in
      130|143) interrupted=$install_hooks_status ;;
    esac
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed while hook environments were installed; refusing to overwrite it."
      _dev_info "Original snapshot retained: $config_snapshot"
      return $(( interrupted ? interrupted : 1 ))
    fi
    (( interrupted )) && return $interrupted
    if (( install_hooks_status != 0 )); then
      _dev_error \
        "A planned hook environment could not be installed; the candidate was not published."
      return $(( interrupted ? interrupted : 1 ))
    fi

    _dev_update_workspace_validate \
      "$transaction_root" "$transaction_root_identity" \
      "$transaction_dir" "$transaction_dir_identity" || {
      _dev_error "The pre-commit update workspace changed during validation."
      return $(( interrupted ? interrupted : 1 ))
    }
    _dev_update_file_fingerprint "$planned_config" || return $(( interrupted ? interrupted : 1 ))
    [[ "$REPLY" == "$planned_config_fingerprint" ]] || {
      _dev_error "The private hook update plan changed during validation."
      return $(( interrupted ? interrupted : 1 ))
    }
    current_project_identity=$(
      _dev_directory_identity "$project_root" "project directory"
    ) || return $(( interrupted ? interrupted : 1 ))
    if [[ "$current_project_identity" != "$project_identity" \
      || "${PWD:A}" != "$project_root" ]]; then
      _dev_error "The project context changed during hook validation."
      return $(( interrupted ? interrupted : 1 ))
    fi
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$initial_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed during private hook validation."
      _dev_info "Original snapshot retained: $config_snapshot"
      return $(( interrupted ? interrupted : 1 ))
    fi

    (( interrupted )) && return $interrupted
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
          return $(( interrupted ? interrupted : 1 ))
        fi
        _dev_error "Could not publish the frozen hook revision plan."
        return $(( interrupted ? interrupted : 1 ))
      fi
      expected_installed_config_fingerprint="$REPLY"
      _dev_success "Published the validated frozen hook revisions."
    else
      _dev_dim "  No safe hook revision change needs publication."
    fi

    (( interrupted )) && return $interrupted
    local -i hook_install_status=0
    _dev_run_captured "pre-commit install --install-hooks" \
      "${precommit_runner[@]}" install --install-hooks \
      || hook_install_status=$?
    case "$hook_install_status" in
      130|143) interrupted=$hook_install_status ;;
    esac
    if ! _dev_precommit_live_config_matches \
      "$config_path" "$expected_installed_config_fingerprint"; then
      preserve_workspace=1
      _dev_error \
        ".pre-commit-config.yaml changed while Git hooks were installed; refusing recovery overwrite."
      _dev_info "Original snapshot retained: $config_snapshot"
      return $(( interrupted ? interrupted : 1 ))
    fi
    (( interrupted )) && return $interrupted
    if (( hook_install_status != 0 )); then
      _dev_warn "Hook installation failed after revision validation."
      _dev_report_result failed "hook installation failed"
      return $(( interrupted ? interrupted : 1 ))
    fi
    _dev_precommit_hook_types "$config_path"
    if [[ -n "$REPLY" ]]; then
      _dev_success "Git hooks installed: $REPLY."
    else
      _dev_success "Git hooks reinstalled."
    fi

    # Hook findings are project findings, not update failures. They are
    # reported after the validated revisions are published and the Git hooks
    # are installed, so a lint finding or a fixer rewrite cannot discard a
    # safe update or leave the repository on stale hook revisions.
    _dev_info "Running the configured file-stage hooks against all files..."
    (( interrupted )) && return $interrupted
    "${precommit_runner[@]}" run --all-files --config "$config_path" >&2
    local -i hook_run_status=$?
    case "$hook_run_status" in
      130|143) interrupted=$hook_run_status ;;
    esac
    if (( interrupted )); then
      _dev_warn \
        "Hook execution was interrupted; published revisions and installed Git hooks stay in place."
      return $interrupted
    fi
    if (( hook_run_status != 0 )); then
      _dev_warn "Some hooks reported issues (exit status: $hook_run_status)."
      _dev_info \
        "The frozen hook revisions stay published and the Git hooks stay installed."
      _dev_info "Review the findings above, then rerun: dev-run-hooks"
    fi

    # The step result: the package specifier and the revision counts.
    local -a result_parts=()
    [[ "$specifier_status" == "updated" ]] \
      && result_parts+=("pre-commit $specifier_old → $specifier_new")
    if (( updated_revisions > 0 )); then
      _dev_count_noun "$updated_revisions" revision
      result_parts+=("$REPLY updated")
    fi
    (( kept_revisions > 0 )) && result_parts+=("$kept_revisions kept")
    if (( current_revisions > 0 )); then
      if (( updated_revisions + kept_revisions == 0 )); then
        _dev_count_noun "$current_revisions" revision
        result_parts+=("$REPLY current")
      else
        result_parts+=("$current_revisions current")
      fi
    fi
    local result_detail="${(j: · :)result_parts}"

    if (( autoupdate_status != 0 )); then
      _dev_warn \
        "Validated hook revisions were kept, but some repositories could not be updated."
      _dev_info "Retry the remaining updates: dev-menu dev-update-precommit"
    fi
    if [[ "$specifier_status" == "failed" ]]; then
      _dev_warn \
        "Hooks were validated, but the pre-commit package query or plan failed."
      _dev_info "Retry the package update: dev-menu dev-update-precommit"
      _dev_report_result failed \
        "pre-commit package query failed${result_detail:+; $result_detail}"
      return $(( interrupted ? interrupted : 1 ))
    fi
    if (( autoupdate_status != 0 )); then
      _dev_report_result failed \
        "some hook repositories could not be updated${result_detail:+; $result_detail}"
      return $(( interrupted ? interrupted : 1 ))
    fi
    if (( hook_run_status != 0 )); then
      _dev_warn \
        "Pre-commit revisions were published, but the hook run reported issues."
      _dev_report_result failed \
        "hook run reported issues${result_detail:+; $result_detail}"
      return $(( interrupted ? interrupted : 1 ))
    fi
    if [[ "$specifier_status" == "updated" ]] || (( updated_revisions > 0 )); then
      _dev_report_result updated "$result_detail" \
        "Pre-commit maintenance completed with safe frozen hook revisions."
    else
      _dev_report_result current "$result_detail" \
        "Pre-commit maintenance completed with safe frozen hook revisions."
    fi
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

typeset -g _DEV_UPDATE_PRECOMMIT_SOURCED=1
