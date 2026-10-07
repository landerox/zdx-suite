#!/usr/bin/env zsh
# =============================================================================
# Git Repository: read-only repository status report
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_REPO_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_git_status_usage() {
  print -u2 -r -- "Usage: git-status [--json]"
  print -u2 -r -- \
    "Show branch, upstream, working-tree, stash, and operation state."
  print -u2 -r -- "       git-status --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "  --json  Write one zdx.git-status.v1 JSON object to stdout instead; the"
  print -u2 -r -- \
    "          ahead and behind counts come from local refs only."
}

# Writes the zdx.git-status.v1 document for the current repository. Ahead and
# behind counts compare HEAD with the local upstream ref; nothing is fetched.
# Conflicted paths are counted only as conflicted.
_git_status_json() {
  emulate -L zsh

  local repo_root="" git_dir="" branch_name="" head_oid="" upstream_name=""
  local ahead_count="" behind_count="" operation_name="" detached="false"
  local platform="" identity="" REPLY=""
  local -a reply=()

  repo_root=$(command git rev-parse --path-format=absolute --show-toplevel \
    2>/dev/null) || {
    _git_error "Unable to locate the repository root."
    return 1
  }
  git_dir=$(command git rev-parse --path-format=absolute --git-dir \
    2>/dev/null) || {
    _git_error "Unable to locate the Git directory."
    return 1
  }
  branch_name=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    branch_name=""
    detached="true"
  }
  head_oid=$(command git rev-parse --verify --quiet 'HEAD^{commit}' \
    2>/dev/null) || head_oid=""
  upstream_name=$(command git rev-parse --abbrev-ref '@{upstream}' \
    2>/dev/null) || upstream_name=""

  if [[ -n "$upstream_name" && -n "$head_oid" ]]; then
    local counts=""
    counts=$(command git rev-list --left-right --count \
      "HEAD...@{upstream}" 2>/dev/null) || {
      _git_error "Unable to compare HEAD with its upstream."
      return 1
    }
    [[ "$counts" =~ '^([0-9]+)[[:space:]]+([0-9]+)$' ]] || {
      _git_error "Git returned invalid upstream comparison data."
      return 1
    }
    ahead_count="${match[1]}"
    behind_count="${match[2]}"
  fi

  _git_operation_in_progress "$git_dir"
  operation_name="$REPLY"

  _git_capture_nul status --porcelain=v2 -z --untracked-files=all \
    --no-renames || {
    _git_error "Unable to inspect the working tree."
    return 1
  }
  local -a status_records=("${reply[@]}")
  local -i staged=0 unstaged=0 untracked=0 conflicted=0 skip_next=0
  local status_record=""
  for status_record in "${status_records[@]}"; do
    if (( skip_next )); then
      skip_next=0
      continue
    fi
    case "${status_record[1]}" in
      1|2)
        [[ "${status_record[3]}" != "." ]] && (( staged++ ))
        [[ "${status_record[4]}" != "." ]] && (( unstaged++ ))
        # A rename or copy record is followed by its original path.
        [[ "${status_record[1]}" == 2 ]] && skip_next=1
        ;;
      u)
        (( conflicted++ ))
        ;;
      \?)
        (( untracked++ ))
        ;;
    esac
  done

  local stash_output=""
  local -i stash_count=0
  stash_output=$(command git stash list --format='%gd' 2>/dev/null) || {
    _git_error "Unable to inspect the stash list."
    return 1
  }
  if [[ -n "$stash_output" ]]; then
    local -a stash_records=("${(@f)stash_output}")
    stash_count=${#stash_records[@]}
  fi

  if _git_workspace_layout "$repo_root"; then
    platform="${reply[1]}"
    identity="${reply[2]}"
  fi

  command jq -n -c -M \
    --arg schema "zdx.git-status.v1" \
    --arg repository "${repo_root:A}" \
    --arg branch "$branch_name" \
    --argjson detached "$detached" \
    --arg head "$head_oid" \
    --arg upstream "$upstream_name" \
    --arg ahead "$ahead_count" \
    --arg behind "$behind_count" \
    --arg operation "$operation_name" \
    --argjson staged "$staged" \
    --argjson unstaged "$unstaged" \
    --argjson untracked "$untracked" \
    --argjson conflicted "$conflicted" \
    --argjson stashes "$stash_count" \
    --arg platform "$platform" \
    --arg identity "$identity" \
    'def text: if . == "" then null else . end;
     def count: if . == "" then null else tonumber end;
     {
       schema: $schema,
       repository: $repository,
       branch: ($branch | text),
       detached: $detached,
       head: ($head | text),
       upstream: ($upstream | text),
       ahead: ($ahead | count),
       behind: ($behind | count),
       operation: ($operation | text),
       changes: {
         staged: $staged,
         unstaged: $unstaged,
         untracked: $untracked,
         conflicted: $conflicted
       },
       stashes: $stashes,
       workspace: (if $platform == "" then null
         else {platform: $platform, identity: $identity} end)
     }' || {
    _git_error "Unable to write the JSON status document."
    return 1
  }
}

git-status() {
  emulate -L zsh

  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _git_status_usage
    return 0
  fi
  if (( $# == 1 )) && [[ "$1" == "--json" ]]; then
    _git_require_jq || return 1
    _git_require_repo || return 1
    _git_status_json
    return
  fi
  (( $# == 0 )) || {
    _git_error "git-status accepts no arguments other than --json."
    return 2
  }
  _git_context_refresh || return 1

  local root="${_GIT_CONTEXT[root]}"
  local branch="${_GIT_CONTEXT[branch]}"
  local head="${_GIT_CONTEXT[head]}"
  local upstream="${_GIT_CONTEXT[upstream]}"
  local remote="${_GIT_CONTEXT[remote]}"
  local remote_url="${_GIT_CONTEXT[remote_url]}"
  local git_dir="${_GIT_CONTEXT[git_dir]}"

  local status_output
  status_output=$(command git status \
    --porcelain=v2 --untracked-files=all 2>/dev/null) || {
    _git_error "Unable to inspect the working tree."
    return 1
  }
  local -i staged=0 modified=0 untracked=0 conflicts=0
  local record xy
  for record in "${(@f)status_output}"; do
    case "${record[1]:-}" in
      1)
        xy="${record[3,4]}"
        [[ "${xy[1]}" != "." ]] && (( staged++ ))
        [[ "${xy[2]}" != "." ]] && (( modified++ ))
        ;;
      2)
        xy="${record[3,4]}"
        [[ "${xy[1]}" != "." ]] && (( staged++ ))
        [[ "${xy[2]}" != "." ]] && (( modified++ ))
        ;;
      u)
        (( staged++, modified++, conflicts++ ))
        ;;
      \?)
        (( untracked++ ))
        ;;
    esac
  done

  local ahead="" behind=""
  if [[ -n "$upstream" ]]; then
    local counts
    counts=$(command git rev-list --left-right --count \
      "HEAD...$upstream" 2>/dev/null) || {
      _git_error "Unable to compare HEAD with its upstream."
      return 1
    }
    [[ "$counts" == *$'\t'* ]] || {
      _git_error "Git returned invalid upstream comparison data."
      return 1
    }
    ahead="${counts%%$'\t'*}"
    behind="${counts#*$'\t'}"
  fi

  local stash_output
  stash_output=$(command git stash list --format='%gd' 2>/dev/null) || {
    _git_error "Unable to inspect the stash list."
    return 1
  }
  local -i stash_count=0
  if [[ -n "$stash_output" ]]; then
    local -a stash_records=("${(@f)stash_output}")
    stash_count=${#stash_records[@]}
  fi

  _git_header "Repository Status"
  _git_label "Repository:" "${root:t}"
  _git_label "Path:" "$root"
  _git_label "Branch:" "$branch"
  _git_label "HEAD:" \
    "$([[ "$head" == "unborn" ]] && print -r -- unborn \
      || print -r -- "${head[1,12]}")"
  _git_label "Upstream:" "${upstream:-(none)}"
  if [[ -n "$ahead" && -n "$behind" ]]; then
    _git_label "Synchronization:" "$ahead ahead, $behind behind"
  fi
  _git_label "Remote:" "${remote:-(none)}"
  [[ -n "$remote_url" ]] \
    && _git_label "Push URL:" "$(_git_redact_remote_url "$remote_url")"
  _git_blank
  _git_label "Staged:" "$staged file(s)"
  _git_label "Modified:" "$modified file(s)"
  _git_label "Untracked:" "$untracked file(s)"
  _git_label "Conflicts:" "$conflicts file(s)"
  _git_label "Stashes:" "$stash_count"

  local -a operations=()
  [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]] \
    && operations+=(rebase)
  [[ -f "$git_dir/MERGE_HEAD" ]] && operations+=(merge)
  [[ -f "$git_dir/CHERRY_PICK_HEAD" ]] && operations+=(cherry-pick)
  [[ -f "$git_dir/REVERT_HEAD" ]] && operations+=(revert)
  [[ -f "$git_dir/BISECT_LOG" ]] && operations+=(bisect)
  if (( ${#operations[@]} > 0 )); then
    _git_blank
    _git_warn "Operation in progress: ${(j:, :)operations}"
  fi
  if _git_wsl_drive_path "$root"; then
    _git_blank
    _git_wsl_drive_warning
  fi
  return 0
}

typeset -g _GIT_REPO_SOURCED=1
