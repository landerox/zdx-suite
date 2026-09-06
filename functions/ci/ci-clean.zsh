#!/usr/bin/env zsh
# =============================================================================
# CI Cleanup: exact GitHub Actions, deployment, release, and notification plans
# =============================================================================
#
# Loaded by ci-menu.zsh after ci-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_CI_CLEAN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ci_clean_actions_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- \
    '  ci-clean-actions [--run ID]... [--limit N] [--dry-run] [--yes]'
  print -u2 -r -- '  ci-clean-actions -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Delete exact runs from a bounded inventory while preserving the newest'
  print -u2 -r -- \
    'run for every workflow. Without --run, targets are selected interactively.'
}

_ci_clean_deployments_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- \
    '  ci-clean-deployments [--deployment ID]... [--dry-run] [--yes]'
  print -u2 -r -- '  ci-clean-deployments -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Deactivate and delete exact deployments while preserving the newest'
  print -u2 -r -- \
    'deployment for every environment.'
}

_ci_clean_releases_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- \
    '  ci-clean-releases [--release ID]... [--dry-run] [--yes]'
  print -u2 -r -- '  ci-clean-releases -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Delete exact releases while preserving the newest release in the bounded'
  print -u2 -r -- \
    'repository inventory. Associated Git tags are never deleted by CI.'
}

_ci_clean_notifications_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- \
    '  ci-clean-notifications [--thread ID]... [--dry-run] [--yes]'
  print -u2 -r -- '  ci-clean-notifications -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Mark exact unread notification threads for the current repository as read.'
}

_ci_clean_tags_usage() {
  print -u2 -r -- 'Usage: ci-clean-tags'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Deprecated compatibility adapter. Tag lifecycle belongs to the Git suite;'
  print -u2 -r -- 'this command delegates to: git-menu git-tag-list'
}

_ci_clean_issues_usage() {
  print -u2 -r -- 'Usage: ci-clean-issues'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Deprecated compatibility adapter. Issue lifecycle belongs to the Git suite;'
  print -u2 -r -- 'this command delegates to: git-menu git-issues'
}

# stdout: P|D, deployment ID, environment, creator, creation timestamp, and
# an internal SHA-256 identity.
_ci_deployments_inventory() {
  _ci_api_probe \
    "repos/${_CI_REPO[name]}/deployments?per_page=100" \
    2097152 || return
  local response="$REPLY"
  local records=""
  records=$(printf "%s" "$response" | command python3 -I -c '
import hashlib
import json
import re
import sys
from datetime import datetime

deployments = json.load(sys.stdin)
if not isinstance(deployments, list) or len(deployments) > 100:
    raise SystemExit(2)

def text(value, maximum, empty=False):
    if value is None:
        if empty:
            return ""
        raise SystemExit(2)
    if (
        not isinstance(value, str)
        or (not value and not empty)
        or len(value) > maximum
    ):
        raise SystemExit(2)
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise SystemExit(2)
    return value

sensitive = re.compile(
    r"(?:authorization|bearer|token|secret|password|passwd|"
    r"api[-_ ]?key|private[-_ ]?key|client[-_ ]?secret)",
    re.IGNORECASE,
)

def timestamp(value):
    value = text(value, 64)
    if not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T"
        r"[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.][0-9]{1,6})?Z",
        value,
    ):
        raise SystemExit(2)
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        raise SystemExit(2)
    return parsed.timestamp(), value

validated = []
seen_ids = set()
for deployment in deployments:
    if not isinstance(deployment, dict):
        raise SystemExit(2)
    deployment_id = deployment.get("id")
    if type(deployment_id) is not int or deployment_id <= 0:
        raise SystemExit(2)
    if deployment_id in seen_ids:
        raise SystemExit(2)
    seen_ids.add(deployment_id)
    environment_key = text(deployment.get("environment"), 255)
    environment = (
        "[redacted]" if sensitive.search(environment_key) else environment_key
    )
    creator = deployment.get("creator") or {}
    if not isinstance(creator, dict):
        raise SystemExit(2)
    login_key = text(creator.get("login"), 128, empty=True)
    login = "[redacted]" if sensitive.search(login_key) else login_key
    created_key, created = timestamp(deployment.get("created_at"))
    identity = hashlib.sha256(
        json.dumps(
            (deployment_id, environment_key, login_key, created),
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    validated.append(
        (
            created_key,
            deployment_id,
            created,
            environment_key,
            environment,
            login,
            identity,
        )
    )

validated.sort(key=lambda item: (item[0], item[1]), reverse=True)
seen = set()
for (
    _created_key,
    deployment_id,
    created,
    environment_key,
    environment,
    login,
    identity,
) in validated:
    marker = "P" if environment_key not in seen else "D"
    seen.add(environment_key)
    print(
        "\t".join(
            (
                marker,
                str(deployment_id),
                environment,
                login,
                created,
                identity,
            )
        )
    )
' 2>/dev/null) || {
    local -i parser_rc=$?
    _ci_error "GitHub returned an invalid deployment inventory."
    (( parser_rc == 130 || parser_rc == 143 )) && return $parser_rc
    return 1
  }
  (( ${#records} <= 524288 )) || {
    _ci_error "The validated deployment inventory is oversized."
    return 1
  }
  [[ -n "$records" ]] && print -r -- "$records"
  return 0
}

# stdout: P|D, release ID, tag, name, timestamp, draft, prerelease, and an
# internal SHA-256 identity.
_ci_releases_inventory() {
  _ci_api_probe \
    "repos/${_CI_REPO[name]}/releases?per_page=100" \
    2097152 || return
  local response="$REPLY"
  local records=""
  records=$(printf "%s" "$response" | command python3 -I -c '
import hashlib
import json
import re
import sys
from datetime import datetime

releases = json.load(sys.stdin)
if not isinstance(releases, list) or len(releases) > 100:
    raise SystemExit(2)

def text(value, maximum, empty=False):
    if value is None and empty:
        return ""
    if not isinstance(value, str) or (not value and not empty) or len(value) > maximum:
        raise SystemExit(2)
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise SystemExit(2)
    return value

sensitive = re.compile(
    r"(?:authorization|bearer|token|secret|password|passwd|"
    r"api[-_ ]?key|private[-_ ]?key|client[-_ ]?secret)",
    re.IGNORECASE,
)

def timestamp(value):
    value = text(value, 64)
    if not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T"
        r"[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.][0-9]{1,6})?Z",
        value,
    ):
        raise SystemExit(2)
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        raise SystemExit(2)
    return parsed.timestamp(), value

validated = []
seen_ids = set()
for release in releases:
    if not isinstance(release, dict):
        raise SystemExit(2)
    release_id = release.get("id")
    if type(release_id) is not int or release_id <= 0:
        raise SystemExit(2)
    if release_id in seen_ids:
        raise SystemExit(2)
    seen_ids.add(release_id)
    tag_key = text(release.get("tag_name"), 255)
    tag = "[redacted]" if sensitive.search(tag_key) else tag_key
    name_key = text(release.get("name"), 512, empty=True)
    name = "[redacted]" if sensitive.search(name_key) else name_key
    created_key, created = timestamp(release.get("created_at"))
    draft = release.get("draft")
    prerelease = release.get("prerelease")
    if not isinstance(draft, bool) or not isinstance(prerelease, bool):
        raise SystemExit(2)
    identity = hashlib.sha256(
        json.dumps(
            (release_id, tag_key, name_key, created, draft, prerelease),
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    validated.append(
        (
            created_key,
            release_id,
            created,
            tag,
            name,
            str(draft).lower(),
            str(prerelease).lower(),
            identity,
        )
    )

validated.sort(key=lambda item: (item[0], item[1]), reverse=True)
for index, item in enumerate(validated):
    (
        _created_key,
        release_id,
        created,
        tag,
        name,
        draft,
        prerelease,
        identity,
    ) = item
    marker = "P" if index == 0 else "D"
    print(
        "\t".join(
            (
                marker,
                str(release_id),
                tag,
                name,
                created,
                draft,
                prerelease,
                identity,
            )
        )
    )
' 2>/dev/null) || {
    local -i parser_rc=$?
    _ci_error "GitHub returned an invalid release inventory."
    (( parser_rc == 130 || parser_rc == 143 )) && return $parser_rc
    return 1
  }
  (( ${#records} <= 524288 )) || {
    _ci_error "The validated release inventory is oversized."
    return 1
  }
  [[ -n "$records" ]] && print -r -- "$records"
  return 0
}

# stdout: thread ID, type, reason, title, update timestamp, repository, and an
# internal SHA-256 identity.
_ci_notifications_inventory() {
  _ci_api_probe \
    "repos/${_CI_REPO[name]}/notifications?all=false&participating=false&per_page=100" \
    2097152 || return
  local response="$REPLY"
  local records=""
  records=$(printf "%s" "$response" | command python3 -I -c '
import hashlib
import json
import re
import sys
from datetime import datetime

expected_repo = sys.argv[1]
notifications = json.load(sys.stdin)
if not isinstance(notifications, list) or len(notifications) > 100:
    raise SystemExit(2)

def text(value, maximum):
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise SystemExit(2)
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise SystemExit(2)
    return value

sensitive = re.compile(
    r"(?:authorization|bearer|token|secret|password|passwd|"
    r"api[-_ ]?key|private[-_ ]?key|client[-_ ]?secret)",
    re.IGNORECASE,
)

def timestamp(value):
    value = text(value, 64)
    if not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T"
        r"[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.][0-9]{1,6})?Z",
        value,
    ):
        raise SystemExit(2)
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        raise SystemExit(2)
    return parsed.timestamp(), value

validated = []
seen_ids = set()
for notification in notifications:
    if not isinstance(notification, dict):
        raise SystemExit(2)
    thread_id = text(notification.get("id"), 20)
    if not re.fullmatch(r"[1-9][0-9]*", thread_id):
        raise SystemExit(2)
    if thread_id in seen_ids:
        raise SystemExit(2)
    seen_ids.add(thread_id)
    subject = notification.get("subject")
    repository = notification.get("repository")
    if not isinstance(subject, dict) or not isinstance(repository, dict):
        raise SystemExit(2)
    if notification.get("unread") is not True:
        raise SystemExit(2)
    if repository.get("full_name") != expected_repo:
        raise SystemExit(2)
    subject_type_key = text(subject.get("type"), 64)
    reason_key = text(notification.get("reason"), 64)
    title_key = text(subject.get("title"), 512)
    subject_type = (
        "[redacted]" if sensitive.search(subject_type_key) else subject_type_key
    )
    reason = "[redacted]" if sensitive.search(reason_key) else reason_key
    title = "[redacted]" if sensitive.search(title_key) else title_key
    updated_key, updated = timestamp(notification.get("updated_at"))
    identity = hashlib.sha256(
        json.dumps(
            (
                thread_id,
                subject_type_key,
                reason_key,
                title_key,
                updated,
                expected_repo,
            ),
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    validated.append(
        (
            updated_key,
            thread_id,
            updated,
            subject_type,
            reason,
            title,
            identity,
        )
    )

validated.sort(key=lambda item: (item[0], item[1]), reverse=True)
for (
    _updated_key,
    thread_id,
    updated,
    subject_type,
    reason,
    title,
    identity,
) in validated:
    print(
        "\t".join(
            (
                thread_id,
                subject_type,
                reason,
                title,
                updated,
                expected_repo,
                identity,
            )
        )
    )
' "${_CI_REPO[name]}" 2>/dev/null) || {
    local -i parser_rc=$?
    _ci_error "GitHub returned an invalid notification inventory."
    (( parser_rc == 130 || parser_rc == 143 )) && return $parser_rc
    return 1
  }
  (( ${#records} <= 524288 )) || {
    _ci_error "The validated notification inventory is oversized."
    return 1
  }
  [[ -n "$records" ]] && print -r -- "$records"
  return 0
}

_ci_records_for_requested_ids() {
  emulate -L zsh
  local requested_text="$1"
  shift
  local -a requested=("${(@f)requested_text}")
  local -a records=("$@")
  reply=()

  local -A seen_ids=()
  local requested_id="" record="" record_id="" marker=""
  for requested_id in "${requested[@]}"; do
    [[ -z "${seen_ids[$requested_id]:-}" ]] || {
      _ci_error "Duplicate requested target: $(_ci_display_escape "$requested_id")"
      return 2
    }
    seen_ids[$requested_id]=1

    local matched=""
    for record in "${records[@]}"; do
      marker="${record%%$'\t'*}"
      record_id="${${record#*$'\t'}%%$'\t'*}"
      [[ "$record_id" == "$requested_id" ]] || continue
      [[ "$marker" != "P" ]] || {
        _ci_error "Target $requested_id is protected by the current plan."
        return 1
      }
      matched="$record"
      break
    done
    [[ -n "$matched" ]] || {
      _ci_error "Target $requested_id was not found in the bounded inventory."
      return 1
    }
    reply+=("$matched")
  done
}

_ci_exact_records_still_present() {
  local expected_text="$1"
  shift
  local -a expected=("${(@f)expected_text}")
  local -a current=("$@")
  local record=""
  for record in "${expected[@]}"; do
    (( ${current[(Ie)$record]} > 0 )) || return 1
    [[ "${record%%$'\t'*}" != "P" ]] || return 1
  done
}

_ci_filter_deletable_records() {
  reply=()
  local record=""
  for record in "$@"; do
    [[ "${record%%$'\t'*}" == "D" ]] && reply+=("$record")
  done
}

_ci_show_plan_records() {
  local title="$1"
  local repository="$2"
  local noun="$3"
  shift 3
  local -a records=("$@")

  _ci_header "$title"
  _ci_dim "Repository: $repository"
  _ci_dim "Target count: ${#records[@]}"
  local record="" visible_record=""
  for record in "${records[@]}"; do
    visible_record="${record%$'\t'*}"
    _ci_dim "$noun: $visible_record"
  done
}

# Returns success only for an interrupted operation; no later target is safe
# to attempt, and a remote mutation may already have been accepted.
_ci_cleanup_interrupted() {
  local -i operation_rc="$1"
  local -i remaining="$2"
  (( operation_rc == 130 || operation_rc == 143 )) || return 1
  _ci_warn "CI cleanup interrupted; not attempted: $remaining."
  _ci_warn "Verify the current target before retrying; its result may be partial."
}

ci-clean-actions() {
  local limit="100"
  local -a requested_ids=()
  local -i dry_run=0 assume_yes=0

  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _ci_error "--help accepts no arguments."
          return 2
        }
        _ci_clean_actions_usage
        return 0
        ;;
      --run)
        (( $# >= 2 )) && _ci_validate_api_id "$2" || {
          _ci_error "--run requires a positive numeric run ID."
          return 2
        }
        (( ${requested_ids[(Ie)$2]} == 0 )) || {
          _ci_error "Duplicate requested target: $2"
          return 2
        }
        (( ${#requested_ids[@]} < 100 )) || {
          _ci_error "At most 100 workflow run targets may be requested."
          return 2
        }
        requested_ids+=("$2")
        shift 2
        ;;
      --limit)
        (( $# >= 2 )) && _ci_validate_limit "$2" || {
          _ci_error "--limit requires an integer from 1 to 100."
          return 2
        }
        limit="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --yes)
        assume_yes=1
        shift
        ;;
      -*)
        _ci_error "Unknown option: $(_ci_display_escape "$1")"
        return 2
        ;;
      *)
        _ci_error "Unexpected argument: $(_ci_display_escape "$1")"
        return 2
        ;;
    esac
  done
  (( dry_run == 0 || assume_yes == 0 )) || {
    _ci_error "--dry-run cannot be combined with --yes."
    return 2
  }

  _ci_require_python || return 1
  _ci_repo_context || return
  local inventory=""
  inventory=$(_ci_runs_inventory "$limit") || return
  local -a records=("${(@f)inventory}")

  local -a selected=()
  if (( ${#requested_ids[@]} > 0 )); then
    local requested_text="${(F)requested_ids}"
    _ci_records_for_requested_ids "$requested_text" "${records[@]}" || return
    selected=("${reply[@]}")
  else
    _ci_filter_deletable_records "${records[@]}"
    local -a deletable=("${reply[@]}")
    (( ${#deletable[@]} > 0 )) || {
      _ci_success \
        "No deletable workflow runs are present in the bounded inventory."
      return 0
    }
    local -i pick_rc=0
    _ci_select_records \
      "ci delete runs" \
      "Tab select | Ctrl-A all | Enter review | Esc cancel | newest protected" \
      "${deletable[@]}" || pick_rc=$?
    if (( pick_rc != 0 )); then
      (( pick_rc == 3 )) && return 0
      return $pick_rc
    fi
    selected=("${reply[@]}")
  fi

  _ci_show_plan_records \
    "Workflow Run Deletion Plan" \
    "${_CI_REPO[target]}" \
    "Run record" \
    "${selected[@]}"
  (( dry_run == 0 )) || {
    _ci_info "Dry run complete; no workflow run was deleted."
    return 0
  }

  local -i authorization_rc=0
  _ci_authorize "$assume_yes" \
    "Delete ${#selected[@]} exact workflow run(s)?" \
    || authorization_rc=$?
  if (( authorization_rc != 0 )); then
    (( authorization_rc == 3 )) && return 0
    return $authorization_rc
  fi

  _ci_require_same_repo || return
  local -i failures=0 processed=0 operation_rc=0
  local record="" run_id="" current_inventory=""
  local -a current=()
  for record in "${selected[@]}"; do
    (( processed += 1 ))
    current_inventory=$(_ci_runs_inventory "$limit") || {
      operation_rc=$?
      if _ci_cleanup_interrupted "$operation_rc" "$(( ${#selected[@]} - processed ))"; then
        return $operation_rc
      fi
      _ci_error "Unable to revalidate the next workflow run."
      (( failures += 1 ))
      break
    }
    current=("${(@f)current_inventory}")
    _ci_exact_records_still_present "$record" "${current[@]}" || {
      _ci_error "A workflow run changed or became protected after confirmation."
      (( failures += 1 ))
      continue
    }
    run_id="${${record#*$'\t'}%%$'\t'*}"
    if _ci_api_mutate DELETE \
      "repos/${_CI_REPO[name]}/actions/runs/$run_id" \
      >/dev/null 2>&1; then
      _ci_success "Deleted workflow run $run_id."
    else
      operation_rc=$?
      if _ci_cleanup_interrupted "$operation_rc" "$(( ${#selected[@]} - processed ))"; then
        return $operation_rc
      fi
      _ci_error "Failed to delete workflow run $run_id."
      (( failures += 1 ))
    fi
  done
  (( failures == 0 )) || {
    _ci_error "$failures workflow run deletion(s) failed."
    return 1
  }
}

ci-clean-deployments() {
  local -a requested_ids=()
  local -i dry_run=0 assume_yes=0

  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _ci_error "--help accepts no arguments."
          return 2
        }
        _ci_clean_deployments_usage
        return 0
        ;;
      --deployment)
        (( $# >= 2 )) && _ci_validate_api_id "$2" || {
          _ci_error "--deployment requires a positive numeric deployment ID."
          return 2
        }
        (( ${requested_ids[(Ie)$2]} == 0 )) || {
          _ci_error "Duplicate requested target: $2"
          return 2
        }
        (( ${#requested_ids[@]} < 100 )) || {
          _ci_error "At most 100 deployment targets may be requested."
          return 2
        }
        requested_ids+=("$2")
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --yes)
        assume_yes=1
        shift
        ;;
      -*)
        _ci_error "Unknown option: $(_ci_display_escape "$1")"
        return 2
        ;;
      *)
        _ci_error "Unexpected argument: $(_ci_display_escape "$1")"
        return 2
        ;;
    esac
  done
  (( dry_run == 0 || assume_yes == 0 )) || {
    _ci_error "--dry-run cannot be combined with --yes."
    return 2
  }

  _ci_require_python || return 1
  _ci_repo_context || return
  local inventory=""
  inventory=$(_ci_deployments_inventory) || return
  local -a records=("${(@f)inventory}")

  local -a selected=()
  if (( ${#requested_ids[@]} > 0 )); then
    local requested_text="${(F)requested_ids}"
    _ci_records_for_requested_ids "$requested_text" "${records[@]}" || return
    selected=("${reply[@]}")
  else
    _ci_filter_deletable_records "${records[@]}"
    local -a deletable=("${reply[@]}")
    (( ${#deletable[@]} > 0 )) || {
      _ci_success \
        "No deletable deployments are present in the bounded inventory."
      return 0
    }
    local -i pick_rc=0
    _ci_select_records \
      "ci delete deployments" \
      "Tab select | Ctrl-A all | Enter review | Esc cancel | newest protected" \
      "${deletable[@]}" || pick_rc=$?
    if (( pick_rc != 0 )); then
      (( pick_rc == 3 )) && return 0
      return $pick_rc
    fi
    selected=("${reply[@]}")
  fi

  _ci_show_plan_records \
    "Deployment Deletion Plan" \
    "${_CI_REPO[target]}" \
    "Deployment record" \
    "${selected[@]}"
  (( dry_run == 0 )) || {
    _ci_info "Dry run complete; no deployment was changed."
    return 0
  }

  local -i authorization_rc=0
  _ci_authorize "$assume_yes" \
    "Deactivate and delete ${#selected[@]} exact deployment(s)?" \
    || authorization_rc=$?
  if (( authorization_rc != 0 )); then
    (( authorization_rc == 3 )) && return 0
    return $authorization_rc
  fi

  _ci_require_same_repo || return
  local -i failures=0 processed=0 operation_rc=0
  local record="" deployment_id="" current_inventory=""
  local -a current=()
  for record in "${selected[@]}"; do
    (( processed += 1 ))
    current_inventory=$(_ci_deployments_inventory) || {
      operation_rc=$?
      if _ci_cleanup_interrupted "$operation_rc" "$(( ${#selected[@]} - processed ))"; then
        return $operation_rc
      fi
      _ci_error "Unable to revalidate the next deployment."
      (( failures += 1 ))
      break
    }
    current=("${(@f)current_inventory}")
    _ci_exact_records_still_present "$record" "${current[@]}" || {
      _ci_error "A deployment changed or became protected after confirmation."
      (( failures += 1 ))
      continue
    }
    deployment_id="${${record#*$'\t'}%%$'\t'*}"
    operation_rc=0
    _ci_api_mutate POST \
      "repos/${_CI_REPO[name]}/deployments/$deployment_id/statuses" \
      -f state=inactive >/dev/null 2>&1 || operation_rc=$?
    if (( operation_rc != 0 )); then
      if _ci_cleanup_interrupted "$operation_rc" "$(( ${#selected[@]} - processed ))"; then
        return $operation_rc
      fi
      _ci_error "Failed to deactivate deployment $deployment_id."
      (( failures += 1 ))
      continue
    fi
    if _ci_api_mutate DELETE \
      "repos/${_CI_REPO[name]}/deployments/$deployment_id" \
      >/dev/null 2>&1; then
      _ci_success "Deleted deployment $deployment_id."
    else
      operation_rc=$?
      if (( operation_rc == 130 || operation_rc == 143 )); then
        _ci_warn "Deployment $deployment_id was deactivated; deletion could not be confirmed."
      fi
      if _ci_cleanup_interrupted "$operation_rc" "$(( ${#selected[@]} - processed ))"; then
        return $operation_rc
      fi
      _ci_error \
        "Deployment $deployment_id was deactivated but could not be deleted."
      (( failures += 1 ))
    fi
  done
  (( failures == 0 )) || {
    _ci_error "$failures deployment transaction(s) failed."
    return 1
  }
}

ci-clean-releases() {
  local -a requested_ids=()
  local -i dry_run=0 assume_yes=0

  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _ci_error "--help accepts no arguments."
          return 2
        }
        _ci_clean_releases_usage
        return 0
        ;;
      --release)
        (( $# >= 2 )) && _ci_validate_api_id "$2" || {
          _ci_error "--release requires a positive numeric release ID."
          return 2
        }
        (( ${requested_ids[(Ie)$2]} == 0 )) || {
          _ci_error "Duplicate requested target: $2"
          return 2
        }
        (( ${#requested_ids[@]} < 100 )) || {
          _ci_error "At most 100 release targets may be requested."
          return 2
        }
        requested_ids+=("$2")
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --yes)
        assume_yes=1
        shift
        ;;
      -*)
        _ci_error "Unknown option: $(_ci_display_escape "$1")"
        return 2
        ;;
      *)
        _ci_error "Unexpected argument: $(_ci_display_escape "$1")"
        return 2
        ;;
    esac
  done
  (( dry_run == 0 || assume_yes == 0 )) || {
    _ci_error "--dry-run cannot be combined with --yes."
    return 2
  }

  _ci_require_python || return 1
  _ci_repo_context || return
  local inventory=""
  inventory=$(_ci_releases_inventory) || return
  local -a records=("${(@f)inventory}")

  local -a selected=()
  if (( ${#requested_ids[@]} > 0 )); then
    local requested_text="${(F)requested_ids}"
    _ci_records_for_requested_ids "$requested_text" "${records[@]}" || return
    selected=("${reply[@]}")
  else
    _ci_filter_deletable_records "${records[@]}"
    local -a deletable=("${reply[@]}")
    (( ${#deletable[@]} > 0 )) || {
      _ci_success "No deletable releases are present in the bounded inventory."
      return 0
    }
    local -i pick_rc=0
    _ci_select_records \
      "ci delete releases" \
      "Tab select | Ctrl-A all | Enter review | Esc cancel | newest protected" \
      "${deletable[@]}" || pick_rc=$?
    if (( pick_rc != 0 )); then
      (( pick_rc == 3 )) && return 0
      return $pick_rc
    fi
    selected=("${reply[@]}")
  fi

  _ci_show_plan_records \
    "Release Deletion Plan" \
    "${_CI_REPO[target]}" \
    "Release record" \
    "${selected[@]}"
  _ci_warn "Associated Git tags are outside this plan and will not be deleted."
  (( dry_run == 0 )) || {
    _ci_info "Dry run complete; no release was deleted."
    return 0
  }

  local -i authorization_rc=0
  _ci_authorize "$assume_yes" \
    "Delete ${#selected[@]} exact release(s), preserving their tags?" \
    || authorization_rc=$?
  if (( authorization_rc != 0 )); then
    (( authorization_rc == 3 )) && return 0
    return $authorization_rc
  fi

  _ci_require_same_repo || return
  local -i failures=0 processed=0 operation_rc=0
  local record="" release_id="" release_tag="" current_inventory=""
  local -a current=()
  for record in "${selected[@]}"; do
    (( processed += 1 ))
    current_inventory=$(_ci_releases_inventory) || {
      operation_rc=$?
      if _ci_cleanup_interrupted "$operation_rc" "$(( ${#selected[@]} - processed ))"; then
        return $operation_rc
      fi
      _ci_error "Unable to revalidate the next release."
      (( failures += 1 ))
      break
    }
    current=("${(@f)current_inventory}")
    _ci_exact_records_still_present "$record" "${current[@]}" || {
      _ci_error "A release changed or became protected after confirmation."
      (( failures += 1 ))
      continue
    }
    release_id="${${record#*$'\t'}%%$'\t'*}"
    release_tag="${${record#*$'\t'}#*$'\t'}"
    release_tag="${release_tag%%$'\t'*}"
    if _ci_api_mutate DELETE \
      "repos/${_CI_REPO[name]}/releases/$release_id" \
      >/dev/null 2>&1; then
      _ci_success "Deleted release $release_id ($release_tag)."
    else
      operation_rc=$?
      if _ci_cleanup_interrupted "$operation_rc" "$(( ${#selected[@]} - processed ))"; then
        return $operation_rc
      fi
      _ci_error "Failed to delete release $release_id ($release_tag)."
      (( failures += 1 ))
    fi
  done
  (( failures == 0 )) || {
    _ci_error "$failures release deletion(s) failed."
    return 1
  }
}

ci-clean-notifications() {
  local -a requested_ids=()
  local -i dry_run=0 assume_yes=0

  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _ci_error "--help accepts no arguments."
          return 2
        }
        _ci_clean_notifications_usage
        return 0
        ;;
      --thread)
        (( $# >= 2 )) && _ci_validate_api_id "$2" || {
          _ci_error "--thread requires a positive numeric notification ID."
          return 2
        }
        (( ${requested_ids[(Ie)$2]} == 0 )) || {
          _ci_error "Duplicate requested target: $2"
          return 2
        }
        (( ${#requested_ids[@]} < 100 )) || {
          _ci_error "At most 100 notification targets may be requested."
          return 2
        }
        requested_ids+=("$2")
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --yes)
        assume_yes=1
        shift
        ;;
      -*)
        _ci_error "Unknown option: $(_ci_display_escape "$1")"
        return 2
        ;;
      *)
        _ci_error "Unexpected argument: $(_ci_display_escape "$1")"
        return 2
        ;;
    esac
  done
  (( dry_run == 0 || assume_yes == 0 )) || {
    _ci_error "--dry-run cannot be combined with --yes."
    return 2
  }

  _ci_require_python || return 1
  _ci_repo_context || return
  local inventory=""
  inventory=$(_ci_notifications_inventory) || return
  local -a records=("${(@f)inventory}")

  local -a selected=()
  if (( ${#requested_ids[@]} > 0 )); then
    local -A seen=()
    local requested_id="" record=""
    for requested_id in "${requested_ids[@]}"; do
      [[ -z "${seen[$requested_id]:-}" ]] || {
        _ci_error "Duplicate requested target: $requested_id"
        return 2
      }
      seen[$requested_id]=1
      local matched=""
      for record in "${records[@]}"; do
        [[ "${record%%$'\t'*}" == "$requested_id" ]] || continue
        matched="$record"
        break
      done
      [[ -n "$matched" ]] || {
        _ci_error \
          "Notification $requested_id was not found in the bounded inventory."
        return 1
      }
      selected+=("$matched")
    done
  else
    (( ${#records[@]} > 0 )) || {
      _ci_success "No unread notifications were found for this repository."
      return 0
    }
    local -i pick_rc=0
    _ci_select_records \
      "ci mark notifications" \
      "Tab select | Ctrl-A all | Enter review | Esc cancel" \
      "${records[@]}" || pick_rc=$?
    if (( pick_rc != 0 )); then
      (( pick_rc == 3 )) && return 0
      return $pick_rc
    fi
    selected=("${reply[@]}")
  fi

  _ci_show_plan_records \
    "Notification Update Plan" \
    "${_CI_REPO[target]}" \
    "Thread record" \
    "${selected[@]}"
  (( dry_run == 0 )) || {
    _ci_info "Dry run complete; no notification was changed."
    return 0
  }

  local -i authorization_rc=0
  _ci_authorize "$assume_yes" \
    "Mark ${#selected[@]} exact notification thread(s) as read?" \
    || authorization_rc=$?
  if (( authorization_rc != 0 )); then
    (( authorization_rc == 3 )) && return 0
    return $authorization_rc
  fi

  _ci_require_same_repo || return
  local -i failures=0 processed=0 operation_rc=0
  local record="" thread_id="" current_inventory=""
  local -a current=()
  for record in "${selected[@]}"; do
    (( processed += 1 ))
    current_inventory=$(_ci_notifications_inventory) || {
      operation_rc=$?
      if _ci_cleanup_interrupted "$operation_rc" "$(( ${#selected[@]} - processed ))"; then
        return $operation_rc
      fi
      _ci_error "Unable to revalidate the next notification."
      (( failures += 1 ))
      break
    }
    current=("${(@f)current_inventory}")
    (( ${current[(Ie)$record]} > 0 )) || {
      _ci_error "A notification changed after confirmation; retry."
      (( failures += 1 ))
      continue
    }
    thread_id="${record%%$'\t'*}"
    if _ci_api_mutate PATCH \
      "notifications/threads/$thread_id" >/dev/null 2>&1; then
      _ci_success "Marked notification $thread_id as read."
    else
      operation_rc=$?
      if _ci_cleanup_interrupted "$operation_rc" "$(( ${#selected[@]} - processed ))"; then
        return $operation_rc
      fi
      _ci_error "Failed to mark notification $thread_id as read."
      (( failures += 1 ))
    fi
  done
  (( failures == 0 )) || {
    _ci_error "$failures notification update(s) failed."
    return 1
  }
}

ci-clean-tags() {
  case "${1:-}" in
    -h|--help)
      (( $# == 1 )) || {
        _ci_error "--help accepts no arguments."
        return 2
      }
      _ci_clean_tags_usage
      return 0
      ;;
    "")
      (( $# == 0 )) || return 2
      ;;
    -*)
      _ci_error "Unknown option: $(_ci_display_escape "$1")"
      return 2
      ;;
    *)
      _ci_error "ci-clean-tags accepts no arguments."
      return 2
      ;;
  esac

  _ci_warn \
    "ci-clean-tags is deprecated; delegating tag lifecycle to git-tag-list."
  typeset -f git-menu &>/dev/null || {
    _ci_error "git-menu is unavailable; run git-menu git-tag-list after loading ZDX."
    return 1
  }
  git-menu git-tag-list
}

ci-clean-issues() {
  case "${1:-}" in
    -h|--help)
      (( $# == 1 )) || {
        _ci_error "--help accepts no arguments."
        return 2
      }
      _ci_clean_issues_usage
      return 0
      ;;
    "")
      (( $# == 0 )) || return 2
      ;;
    -*)
      _ci_error "Unknown option: $(_ci_display_escape "$1")"
      return 2
      ;;
    *)
      _ci_error "ci-clean-issues accepts no arguments."
      return 2
      ;;
  esac

  _ci_warn \
    "ci-clean-issues is deprecated; delegating issue lifecycle to git-issues."
  typeset -f git-menu &>/dev/null || {
    _ci_error "git-menu is unavailable; run git-menu git-issues after loading ZDX."
    return 1
  }
  git-menu git-issues
}

typeset -g _CI_CLEAN_SOURCED=1
