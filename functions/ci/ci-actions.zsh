#!/usr/bin/env zsh
# =============================================================================
# CI Actions: bounded run inspection and exact workflow dispatch
# =============================================================================
#
# Loaded by ci-menu.zsh after ci-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_CI_ACTIONS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ci_status_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  ci-status [--limit N] [--list]'
  print -u2 -r -- '  ci-status [--limit N] --run ID'
  print -u2 -r -- '  ci-status -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Without --list or --run, select one recent run interactively.'
  print -u2 -r -- \
    '--list emits validated TSV records to stdout; other suite UI uses stderr.'
}

_ci_run_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- \
    '  ci-run [--workflow ID|PATH] [--ref BRANCH] [--dry-run] [--yes]'
  print -u2 -r -- '  ci-run -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Select or resolve one active workflow, show its repository-bound plan,'
  print -u2 -r -- \
    'and dispatch it only after confirmation and post-review revalidation.'
  print -u2 -r -- \
    'The ref must be a local branch whose exact commit matches the GitHub'
  print -u2 -r -- \
    'branch before review and after confirmation.'
}

# stdout: P|D, run ID, workflow ID, state, workflow name, branch, timestamp,
# event, title, and an internal SHA-256 identity as one validated TSV record.
_ci_runs_inventory() {
  local limit="${1:-40}"
  _ci_validate_limit "$limit" || return 2

  _ci_api_probe \
    "repos/${_CI_REPO[name]}/actions/runs?per_page=$limit" \
    2097152 || return
  _ci_runs_records "$REPLY" "$limit"
}

# Resolve one historical run without treating the recent inventory as complete.
_ci_run_exact_record() {
  local run_id="$1"
  _ci_validate_api_id "$run_id" || return 2
  _ci_api_probe "repos/${_CI_REPO[name]}/actions/runs/$run_id" 2097152 || {
    local -i probe_rc=$?
    _ci_error "Unable to inspect workflow run $run_id in the current repository."
    return $probe_rc
  }
  _ci_runs_records "$REPLY" 1 "$run_id" "${_CI_REPO[id]}" "${_CI_REPO[name]}"
}

# Both run discovery paths share one schema and presentation-redaction policy.
_ci_runs_records() {
  local response="$1" limit="$2"
  local expected_run="${3:-0}" repo_id="${4:--}" repo_name="${5:--}"
  local records=""
  records=$(printf "%s" "$response" | command python3 -I -c '
import hashlib
import json
import re
import sys
from datetime import datetime

limit = int(sys.argv[1])
payload = json.load(sys.stdin)
if not isinstance(payload, dict):
    raise SystemExit(2)
expected_run, repo_id, repo_name = sys.argv[2:]
if expected_run != "0":
    repository = payload.get("repository")
    if (
        type(payload.get("id")) is not int
        or payload["id"] != int(expected_run)
        or not isinstance(repository, dict)
        or repository.get("node_id") != repo_id
        or repository.get("full_name") != repo_name
    ):
        raise SystemExit(2)
    runs = [payload]
else:
    runs = payload.get("workflow_runs")
if not isinstance(runs, list) or len(runs) > limit:
    raise SystemExit(2)

def integer(value):
    return type(value) is int and value > 0

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

def redact(value):
    return "[redacted]" if sensitive.search(value) else value

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
seen_run_ids = set()
for run in runs:
    if not isinstance(run, dict):
        raise SystemExit(2)
    run_id = run.get("id")
    workflow_id = run.get("workflow_id")
    if not integer(run_id) or not integer(workflow_id):
        raise SystemExit(2)
    if run_id in seen_run_ids:
        raise SystemExit(2)
    seen_run_ids.add(run_id)
    state_key = text(run.get("conclusion") or run.get("status"), 32)
    if not re.fullmatch(r"[A-Za-z_]+", state_key):
        raise SystemExit(2)
    name_key = text(run.get("name"), 256)
    branch_key = text(run.get("head_branch"), 255, empty=True)
    created_key, created = timestamp(run.get("created_at"))
    event_key = text(run.get("event"), 64)
    title_key = text(run.get("display_title"), 512, empty=True)
    identity = hashlib.sha256(
        json.dumps(
            (
                run_id,
                workflow_id,
                state_key,
                name_key,
                branch_key,
                created,
                event_key,
                title_key,
            ),
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    validated.append(
        (
            created_key,
            run_id,
            created,
            workflow_id,
            redact(state_key),
            redact(name_key),
            redact(branch_key),
            redact(event_key),
            redact(title_key),
            identity,
        )
    )

validated.sort(key=lambda item: (item[0], item[1]), reverse=True)
seen = set()
for (
    _created_key,
    run_id,
    created,
    workflow_id,
    state,
    name,
    branch,
    event,
    title,
    identity,
) in validated:
    marker = "P" if workflow_id not in seen else "D"
    seen.add(workflow_id)
    fields = (
        marker,
        str(run_id),
        str(workflow_id),
        state,
        name,
        branch,
        created,
        event,
        title,
        identity,
    )
    print("\t".join(fields))
' "$limit" "$expected_run" "$repo_id" "$repo_name" 2>/dev/null) || {
    local -i parser_rc=$?
    _ci_error "GitHub returned an invalid workflow-run inventory."
    (( parser_rc == 130 || parser_rc == 143 )) && return $parser_rc
    return 1
  }
  (( ${#records} <= 1048576 )) || {
    _ci_error "The validated workflow-run inventory is oversized."
    return 1
  }
  [[ -n "$records" ]] && print -r -- "$records"
  return 0
}

# stdout: workflow ID, state, path, name, and an internal SHA-256 identity.
_ci_workflows_inventory() {
  _ci_api_probe \
    "repos/${_CI_REPO[name]}/actions/workflows?per_page=100" \
    1048576 || return
  local response="$REPLY"
  local records=""
  records=$(printf "%s" "$response" | command python3 -I -c '
import hashlib
import json
import re
import sys

payload = json.load(sys.stdin)
workflows = payload.get("workflows")
if not isinstance(workflows, list) or len(workflows) > 100:
    raise SystemExit(2)

records = []
seen_ids = set()
seen_paths = set()
sensitive = re.compile(
    r"(?:authorization|bearer|token|secret|password|passwd|"
    r"api[-_ ]?key|private[-_ ]?key|client[-_ ]?secret)",
    re.IGNORECASE,
)
for workflow in workflows:
    if not isinstance(workflow, dict):
        raise SystemExit(2)
    workflow_id = workflow.get("id")
    state = workflow.get("state")
    path = workflow.get("path")
    name_key = workflow.get("name")
    if type(workflow_id) is not int or workflow_id <= 0:
        raise SystemExit(2)
    if workflow_id in seen_ids:
        raise SystemExit(2)
    seen_ids.add(workflow_id)
    if state not in (
        "active",
        "deleted",
        "disabled_fork",
        "disabled_inactivity",
        "disabled_manually",
    ):
        raise SystemExit(2)
    if (
        not isinstance(path, str)
        or len(path) > 256
        or not re.fullmatch(r"[.]github/workflows/[^/\x00-\x1f\x7f]+[.](?:yml|yaml)", path)
    ):
        raise SystemExit(2)
    if path in seen_paths:
        raise SystemExit(2)
    seen_paths.add(path)
    if (
        not isinstance(name_key, str)
        or not name_key
        or len(name_key) > 256
        or any(ord(char) < 32 or ord(char) == 127 for char in name_key)
    ):
        raise SystemExit(2)
    name = "[redacted]" if sensitive.search(name_key) else name_key
    identity = hashlib.sha256(
        json.dumps(
            (workflow_id, state, path, name_key),
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    records.append((workflow_id, state, path, name, identity))

for workflow_id, state, path, name, identity in sorted(records):
    print(f"{workflow_id}\t{state}\t{path}\t{name}\t{identity}")
' 2>/dev/null) || {
    local -i parser_rc=$?
    _ci_error "GitHub returned an invalid workflow inventory."
    (( parser_rc == 130 || parser_rc == 143 )) && return $parser_rc
    return 1
  }
  (( ${#records} <= 262144 )) || {
    _ci_error "The validated workflow inventory is oversized."
    return 1
  }
  [[ -n "$records" ]] && print -r -- "$records"
  return 0
}

_ci_remote_branch_oid() {
  local branch_name="$1"
  _ci_validate_ref "$branch_name" || return 2
  _ci_api_probe \
    "repos/${_CI_REPO[name]}/git/ref/heads/$branch_name" \
    65536 || return
  local response="$REPLY"
  local branch_oid=""
  branch_oid=$(printf "%s" "$response" | command python3 -I -c '
import json
import re
import sys

expected_ref = "refs/heads/" + sys.argv[1]
payload = json.load(sys.stdin)
if not isinstance(payload, dict) or payload.get("ref") != expected_ref:
    raise SystemExit(2)
target = payload.get("object")
if not isinstance(target, dict) or target.get("type") != "commit":
    raise SystemExit(2)
oid = target.get("sha")
if not isinstance(oid, str) or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", oid):
    raise SystemExit(2)
print(oid)
' "$branch_name" 2>/dev/null) || {
    local -i parser_rc=$?
    _ci_error "GitHub returned an invalid branch identity."
    (( parser_rc == 130 || parser_rc == 143 )) && return $parser_rc
    return 1
  }
  REPLY="$branch_oid"
}

_ci_pick_one_record() {
  emulate -L zsh
  local prompt_label="$1"
  local header_text="$2"
  shift 2
  local -a records=("$@")
  REPLY=""
  (( ${#records[@]} > 0 )) || return 3
  _ci_require_fzf || return 1

  local -i fzf_rc=0
  _ci_fzf_capture \
    --delimiter=$'\t' \
    --with-nth='1..-2' \
    --prompt="$prompt_label > " \
    --header="$header_text" \
    --preview='' \
    --preview-window=hidden \
    < <(printf "%s\n" "${records[@]}") || fzf_rc=$?
  local selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _ci_fzf_rc_is_cancel "$fzf_rc" && return 3
    _ci_error "Unable to open the CI picker (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 3
  (( ${records[(Ie)$selected]} > 0 )) || {
    _ci_error "The selected CI record was not in the reviewed snapshot."
    return 1
  }
  REPLY="$selected"
}

ci-status() {
  local limit="40"
  local run_id=""
  local -i list_mode=0

  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _ci_error "--help accepts no arguments."
          return 2
        }
        _ci_status_usage
        return 0
        ;;
      --limit)
        (( $# >= 2 )) && _ci_validate_limit "$2" || {
          _ci_error "--limit requires an integer from 1 to 100."
          return 2
        }
        limit="$2"
        shift 2
        ;;
      --run)
        (( $# >= 2 )) && _ci_validate_api_id "$2" || {
          _ci_error "--run requires a positive numeric run ID."
          return 2
        }
        [[ -z "$run_id" ]] || {
          _ci_error "--run may be supplied only once."
          return 2
        }
        run_id="$2"
        shift 2
        ;;
      --list)
        list_mode=1
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

  (( list_mode == 0 || ${#run_id} == 0 )) || {
    _ci_error "--list cannot be combined with --run."
    return 2
  }

  _ci_require_python || return 1
  _ci_repo_context || return
  local inventory=""
  if [[ -n "$run_id" ]]; then
    inventory=$(_ci_run_exact_record "$run_id") || return
  else
    inventory=$(_ci_runs_inventory "$limit") || return
  fi
  local -a records=("${(@f)inventory}")

  if (( list_mode )); then
    local record=""
    for record in "${records[@]}"; do
      record="${record%$'\t'*}"
      print -r -- "${record#*$'\t'}"
    done
    return 0
  fi

  if (( ${#records[@]} == 0 )); then
    _ci_warn "No workflow runs were found in the bounded inventory."
    return 0
  fi

  local selected=""
  if [[ -n "$run_id" ]]; then
    selected="${records[1]}"
  else
    _ci_header "GitHub Actions Workflow Runs"
    local -i pick_rc=0
    _ci_pick_one_record \
      "ci runs" \
      "Up/Down navigate | Enter view | Esc cancel | P newest per workflow" \
      "${records[@]}" || pick_rc=$?
    if (( pick_rc != 0 )); then
      (( pick_rc == 3 )) && return 0
      return $pick_rc
    fi
    selected="$REPLY"
    run_id="${${selected#*$'\t'}%%$'\t'*}"
  fi

  _ci_info "Viewing run $run_id in $(_ci_display_escape "${_CI_REPO[target]}")."
  _ci_run_probe 30 gh run view "$run_id" \
    --repo "${_CI_REPO[target]}" 2>/dev/null
  local -i view_rc=$?
  if (( view_rc != 0 )); then
    _ci_error "Unable to view workflow run $run_id."
    (( view_rc == 124 || view_rc == 130 || view_rc == 143 )) \
      && return $view_rc
    return 1
  fi
}

ci-run() {
  local workflow_target=""
  local ref_name=""
  local -i dry_run=0 assume_yes=0

  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _ci_error "--help accepts no arguments."
          return 2
        }
        _ci_run_usage
        return 0
        ;;
      --workflow)
        (( $# >= 2 )) && _ci_validate_workflow_target "$2" || {
          _ci_error "--workflow requires a numeric ID or workflow YAML path."
          return 2
        }
        [[ -z "$workflow_target" ]] || {
          _ci_error "--workflow may be supplied only once."
          return 2
        }
        workflow_target="$2"
        shift 2
        ;;
      --ref)
        (( $# >= 2 )) && _ci_validate_ref "$2" || {
          _ci_error "--ref requires a validated branch name."
          return 2
        }
        [[ -z "$ref_name" ]] || {
          _ci_error "--ref may be supplied only once."
          return 2
        }
        ref_name="$2"
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
  local workflow_inventory=""
  workflow_inventory=$(_ci_workflows_inventory) || return
  local -a workflows=("${(@f)workflow_inventory}")
  local selected=""

  if [[ -n "$workflow_target" ]]; then
    local workflow=""
    local workflow_id="" workflow_path=""
    for workflow in "${workflows[@]}"; do
      workflow_id="${workflow%%$'\t'*}"
      workflow_path="${${workflow#*$'\t'}#*$'\t'}"
      workflow_path="${workflow_path%%$'\t'*}"
      if [[ "$workflow_id" == "$workflow_target" \
        || "$workflow_path" == "$workflow_target" ]]; then
        [[ -z "$selected" ]] || {
          _ci_error "The workflow target is ambiguous."
          return 1
        }
        selected="$workflow"
      fi
    done
    [[ -n "$selected" ]] || {
      _ci_error "The requested workflow is not in the bounded inventory."
      return 1
    }
  else
    local -a active_workflows=()
    local workflow=""
    for workflow in "${workflows[@]}"; do
      [[ "${${workflow#*$'\t'}%%$'\t'*}" == "active" ]] \
        && active_workflows+=("$workflow")
    done
    (( ${#active_workflows[@]} > 0 )) || {
      _ci_warn "No active workflows were found in the bounded inventory."
      return 0
    }
    local -i pick_rc=0
    _ci_pick_one_record \
      "ci workflow" \
      "Up/Down navigate | Enter select | Esc cancel" \
      "${active_workflows[@]}" || pick_rc=$?
    if (( pick_rc != 0 )); then
      (( pick_rc == 3 )) && return 0
      return $pick_rc
    fi
    selected="$REPLY"
  fi

  local workflow_id="${selected%%$'\t'*}"
  local remainder="${selected#*$'\t'}"
  local workflow_state="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  local workflow_path="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  local workflow_name="${remainder%%$'\t'*}"
  [[ "$workflow_state" == "active" ]] || {
    _ci_error "The selected workflow is not active."
    return 1
  }

  if [[ -z "$ref_name" ]]; then
    ref_name=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
      _ci_error "A detached checkout requires an explicit --ref."
      return 1
    }
  fi
  _ci_validate_ref "$ref_name" || {
    _ci_error "The selected ref is invalid."
    return 2
  }
  local ref_oid=""
  command git show-ref --verify --quiet \
    "refs/heads/$ref_name" 2>/dev/null || {
    _ci_error "The selected ref is not an exact local branch."
    return 1
  }
  ref_oid=$(command git rev-parse --verify \
    "refs/heads/${ref_name}^{commit}" 2>/dev/null) || {
    _ci_error "The selected branch does not resolve to a local commit."
    return 1
  }
  _ci_remote_branch_oid "$ref_name" || {
    local -i probe_rc=$?
    _ci_error "The selected branch is unavailable on GitHub."
    (( probe_rc == 130 || probe_rc == 143 )) && return $probe_rc
    return 1
  }
  local remote_ref_oid="$REPLY"
  [[ "$remote_ref_oid" == "$ref_oid" ]] || {
    _ci_error \
      "The local and GitHub branch commits differ; synchronize before dispatch."
    return 1
  }

  _ci_header "Workflow Dispatch Plan"
  _ci_dim "Repository: ${_CI_REPO[target]}"
  _ci_dim "Workflow: $workflow_name"
  _ci_dim "Workflow ID: $workflow_id"
  _ci_dim "Workflow path: $workflow_path"
  _ci_dim "Branch: $ref_name"
  _ci_dim "Reviewed local and GitHub commit: $ref_oid"
  _ci_warn \
    "Dispatch executes repository workflow code with its configured permissions and secrets."
  _ci_warn "GitHub resolves the named branch again when accepting the dispatch."

  (( dry_run == 0 )) || {
    _ci_info "Dry run complete; no workflow was dispatched."
    return 0
  }

  local -i authorization_rc=0
  _ci_authorize "$assume_yes" \
    "Dispatch workflow $workflow_id on ref $ref_name?" \
    || authorization_rc=$?
  if (( authorization_rc != 0 )); then
    (( authorization_rc == 3 )) && return 0
    return $authorization_rc
  fi

  _ci_require_same_repo || return
  local current_oid=""
  current_oid=$(command git rev-parse --verify \
    "refs/heads/${ref_name}^{commit}" 2>/dev/null) || {
    _ci_error "The reviewed branch no longer resolves."
    return 1
  }
  [[ "$current_oid" == "$ref_oid" ]] || {
    _ci_error "The reviewed local branch changed after confirmation; retry."
    return 1
  }
  _ci_remote_branch_oid "$ref_name" || return
  [[ "$REPLY" == "$ref_oid" ]] || {
    _ci_error "The reviewed GitHub branch changed after confirmation; retry."
    return 1
  }

  local current_inventory=""
  current_inventory=$(_ci_workflows_inventory) || return
  local -a current_workflows=("${(@f)current_inventory}")
  (( ${current_workflows[(Ie)$selected]} > 0 )) || {
    _ci_error "The selected workflow changed after confirmation; retry."
    return 1
  }

  _ci_api_mutate POST \
    "repos/${_CI_REPO[name]}/actions/workflows/$workflow_id/dispatches" \
    -f "ref=$ref_name" >/dev/null 2>&1 || {
    local -i dispatch_rc=$?
    _ci_error "Workflow dispatch failed; acceptance could not be confirmed."
    (( dispatch_rc == 130 || dispatch_rc == 143 )) && return $dispatch_rc
    return 1
  }
  _ci_success "Workflow dispatch accepted for $workflow_name."
}

typeset -g _CI_ACTIONS_SOURCED=1
