#!/usr/bin/env zsh
# =============================================================================
# Ws Status: read-only status of every workspace repository
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#
# Status comes from local refs only. The network is used only with --fetch,
# which is disclosed first and runs bounded `git fetch --prune` jobs.
#

if [[ -n "${_WS_STATUS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _WS_FETCH_TIMEOUT=60

_ws_status_usage() {
  print -u2 -r -- "Usage: ws-status [--fetch] [--json]"
  print -u2 -r -- "       ws-status --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "List every repository below WS_BASE_DIR with its workspace, branch,"
  print -u2 -r -- \
    "uncommitted changes, ahead/behind counts from local refs, stashes, and"
  print -u2 -r -- \
    "last commit. Repositories that need attention are listed first."
  print -u2 -r -- ""
  print -u2 -r -- \
    "  --fetch   First run git fetch --prune in each repository with a remote,"
  print -u2 -r -- \
    "            at most WS_FETCH_JOBS (default 4) at a time, 60s each."
  print -u2 -r -- \
    "  --json    Print one JSON document (schema zdx.ws-status.v1) on stdout."
  print -u2 -r -- ""
  print -u2 -r -- \
    "Without --fetch, no network is used and no repository is changed."
}

# reply: one repository's state from local refs only:
#   (state branch detached head upstream upstream-state ahead behind
#    changes stashes last-commit-epoch error)
# state is ok or error, detached is 0 or 1, upstream-state is none,
# tracking, or gone, and an unknown number is empty.
# Usage: _ws_status_probe <git> <repository-directory>
_ws_status_probe() {
  emulate -L zsh
  local git_path="$1" repository="$2"
  reply=(error "" 0 "" "" none "" "" "" "" "" "")
  local output="" line="" oid="" head="" upstream="" ahead="" behind=""
  local -i rc=0 changes=0 have_ab=0

  # --no-optional-locks keeps status from rewriting the index.
  output=$(_ws_run_with_timeout "$_WS_GIT_TIMEOUT" "$git_path" \
    --no-optional-locks -C "$repository" status --porcelain=v2 --branch \
    --untracked-files=normal </dev/null 2>/dev/null) || rc=$?
  if (( rc != 0 )); then
    if (( rc == 124 )); then
      reply[12]="git status timed out"
    else
      reply[12]="git status failed (status $rc)"
    fi
    return 1
  fi
  for line in "${(@f)output}"; do
    case "$line" in
      '# branch.oid '*) oid="${line#'# branch.oid '}" ;;
      '# branch.head '*) head="${line#'# branch.head '}" ;;
      '# branch.upstream '*) upstream="${line#'# branch.upstream '}" ;;
      '# branch.ab '*)
        [[ "${line#'# branch.ab '}" =~ '^[+]([0-9]+) [-]([0-9]+)$' ]] || {
          reply[12]="unexpected git status output"
          return 1
        }
        ahead="${match[1]}"
        behind="${match[2]}"
        have_ab=1
        ;;
      '#'*|'') ;;
      *) (( ++changes )) ;;
    esac
  done
  if [[ ! ( "$oid" =~ '^[0-9a-f]{40,64}$' || "$oid" == '(initial)' ) \
    || -z "$head" || "$head" == *[[:cntrl:]]* \
    || "$upstream" == *[[:cntrl:]]* ]]; then
    reply[12]="unexpected git status output"
    return 1
  fi

  local branch="$head" short_head="" upstream_state="none"
  local -i detached=0
  if [[ "$head" == '(detached)' ]]; then
    branch=""
    detached=1
  fi
  [[ "$oid" != '(initial)' ]] && short_head="${oid[1,7]}"
  if [[ -n "$upstream" ]]; then
    if (( have_ab )); then
      upstream_state="tracking"
    else
      upstream_state="gone"
    fi
  fi

  local epoch="" stash_count="0" probe_output=""
  if [[ "$oid" != '(initial)' ]]; then
    rc=0
    # log.showSignature would print verification lines before the time.
    probe_output=$(_ws_run_with_timeout "$_WS_GIT_TIMEOUT" "$git_path" \
      -C "$repository" -c log.showSignature=false log -1 --format=%ct \
      </dev/null 2>/dev/null) || rc=$?
    probe_output="${probe_output%%$'\n'*}"
    if (( rc == 0 )) && [[ "$probe_output" == <-> ]]; then
      epoch="$probe_output"
    fi
  fi
  # refs/stash is absent until the first stash; git reports that as a failure.
  rc=0
  probe_output=$(_ws_run_with_timeout "$_WS_GIT_TIMEOUT" "$git_path" \
    -C "$repository" rev-list --walk-reflogs --count refs/stash \
    </dev/null 2>/dev/null) || rc=$?
  probe_output="${probe_output%%$'\n'*}"
  if (( rc == 0 )) && [[ "$probe_output" == <-> ]]; then
    stash_count="$probe_output"
  elif (( rc == 124 )); then
    stash_count=""
  fi

  reply=(ok "$branch" "$detached" "$short_head" "$upstream" \
    "$upstream_state" "$ahead" "$behind" "$changes" "$stash_count" \
    "$epoch" "")
}

# REPLY: a compact age such as "5 minutes ago" or "3 months ago".
# Usage: _ws_status_age <seconds>
_ws_status_age() {
  local -i seconds="${1:-0}" value=0
  local unit=""
  (( seconds < 0 )) && seconds=0
  if (( seconds < 60 )); then
    REPLY="just now"
    return 0
  elif (( seconds < 3600 )); then
    value=$(( seconds / 60 )); unit=minute
  elif (( seconds < 86400 )); then
    value=$(( seconds / 3600 )); unit=hour
  elif (( seconds < 1209600 )); then
    value=$(( seconds / 86400 )); unit=day
  elif (( seconds < 5184000 )); then
    value=$(( seconds / 604800 )); unit=week
  elif (( seconds < 63072000 )); then
    value=$(( seconds / 2592000 )); unit=month
  else
    value=$(( seconds / 31536000 )); unit=year
  fi
  _ws_count_noun "$value" "$unit"
  REPLY+=" ago"
}

# Fetches every repository that has a remote, at most WS_FETCH_JOBS at a
# time, each bounded by _WS_FETCH_TIMEOUT. Fetches run without prompts and
# with closed stdin. The caller's fetch_outcomes association receives ok,
# failed, timed-out, or skipped (no remote) per relative path, and REPLY the
# number of fetches that failed or timed out. A started fetch is stopped and
# waited for on every exit path.
# Usage: _ws_status_fetch <git> <root> <relative-path...>
_ws_status_fetch() {
  emulate -L zsh
  setopt local_options no_monitor no_notify
  local git_path="$1" root="$2"
  shift 2
  local -a repositories=("$@") fetchable=() reply=()
  local relative="" remotes=""
  REPLY=0
  _ws_fetch_jobs || return 1
  local -i jobs=$REPLY
  REPLY=0

  for relative in "${repositories[@]}"; do
    remotes=$(_ws_run_with_timeout "$_WS_PROBE_TIMEOUT" "$git_path" \
      -C "$root/$relative" remote </dev/null 2>/dev/null) || remotes=""
    if [[ -n "$remotes" ]]; then
      fetchable+=("$relative")
    else
      fetch_outcomes[$relative]=skipped
    fi
  done
  if (( ${#fetchable[@]} == 0 )); then
    _ws_info "No repository has a remote to fetch."
    return 0
  fi

  _ws_count_noun "${#fetchable[@]}" repository repositories
  _ws_warn "Fetching $REPLY over the network with git fetch --prune (at most $jobs at a time, ${_WS_FETCH_TIMEOUT}s each)."
  REPLY=0

  _ws_private_dir_create fetch || return 1
  local status_dir="${reply[1]}" status_identity="${reply[2]}"
  local -a pids=()
  local -i index=0 pid=0 operation_rc=0
  {
    for relative in "${fetchable[@]}"; do
      (( ++index ))
      (
        export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never
        local -i fetch_rc=0
        _ws_run_with_timeout "$_WS_FETCH_TIMEOUT" "$git_path" \
          -C "$root/$relative" fetch --prune --quiet \
          </dev/null >/dev/null 2>&1 || fetch_rc=$?
        print -r -- "$fetch_rc" >| "$status_dir/status.$index"
      ) &
      pids+=($!)
      if (( ${#pids[@]} >= jobs )); then
        for pid in "${pids[@]}"; do
          while builtin kill -0 "$pid" 2>/dev/null; do
            wait "$pid" 2>/dev/null
            (( $? == 127 )) && break
          done
        done
        pids=()
      fi
    done
    for pid in "${pids[@]}"; do
      while builtin kill -0 "$pid" 2>/dev/null; do
        wait "$pid" 2>/dev/null
        (( $? == 127 )) && break
      done
    done
    pids=()

    local status_text=""
    local -i failed=0 fetched=0
    index=0
    for relative in "${fetchable[@]}"; do
      (( ++index ))
      status_text=""
      [[ -f "$status_dir/status.$index" && ! -L "$status_dir/status.$index" ]] \
        && status_text=$(<"$status_dir/status.$index") 2>/dev/null
      case "$status_text" in
        0)
          fetch_outcomes[$relative]=ok
          (( ++fetched ))
          ;;
        124)
          fetch_outcomes[$relative]=timed-out
          (( ++failed ))
          _ws_warn "Fetch timed out: $relative"
          ;;
        *)
          fetch_outcomes[$relative]=failed
          (( ++failed ))
          if [[ "$status_text" == <-> ]]; then
            _ws_warn "Fetch failed: $relative (status $status_text)"
          else
            _ws_warn "Fetch failed: $relative"
          fi
          ;;
      esac
    done
    _ws_count_noun "${#fetchable[@]}" repository repositories
    if (( failed == 0 )); then
      _ws_success "Fetched $REPLY."
    else
      _ws_warn "Fetched $fetched of $REPLY; $failed failed."
    fi
    operation_rc=$failed
  } always {
    for pid in "${pids[@]}"; do
      builtin kill "$pid" 2>/dev/null
    done
    for pid in "${pids[@]}"; do
      while builtin kill -0 "$pid" 2>/dev/null; do
        wait "$pid" 2>/dev/null
        (( $? == 127 )) && break
      done
    done
    _ws_private_dir_remove "$status_dir" "$status_identity" || true
  }
  REPLY=$operation_rc
  return 0
}

ws-status() {
  emulate -L zsh

  local -i fetch=0 json=0
  while (( $# > 0 )); do
    case "$1" in
      --fetch) fetch=1 ;;
      --json) json=1 ;;
      -h|--help)
        (( $# == 1 && ! fetch && ! json )) || {
          _ws_error "--help accepts no additional arguments."
          return 2
        }
        _ws_status_usage
        return 0
        ;;
      *)
        _ws_error "Unknown ws-status argument: $1"
        return 2
        ;;
    esac
    shift
  done

  local REPLY="" jq_path=""
  local -a reply=()
  if (( json )); then
    _ws_command_path jq || {
      _ws_error "jq is required for ws-status --json; install jq and retry."
      return 1
    }
    jq_path="$REPLY"
  fi
  _ws_git_command || return 1
  local git_path="$REPLY"
  _ws_workspace_root || return 1
  local root_literal="${reply[1]}" root="${reply[2]}"
  _ws_command_display "$root_literal"
  local root_display="$REPLY"
  _ws_collect_repositories "$root" || return 1
  local -a repositories=("${reply[@]}")
  local -i skipped=$REPLY total=${#repositories[@]}

  if (( ! json )); then
    _ws_header "Workspace Status"
    _ws_label "Workspace root" "$root_display"
  fi
  if (( skipped > 0 )); then
    _ws_count_noun "$skipped" directory directories
    _ws_warn "Skipped $REPLY whose names cannot be shown safely."
  fi

  local -A fetch_outcomes=()
  local -i fetch_failures=0
  if (( fetch && total > 0 )); then
    _ws_status_fetch "$git_path" "$root" "${repositories[@]}" || return
    fetch_failures=$REPLY
  fi

  zmodload zsh/datetime 2>/dev/null || {
    _ws_error "The Zsh datetime module is required for ws-status."
    return 1
  }
  local -i now=$EPOCHSECONDS
  local relative="" workspace="" name="" platform="" identity=""
  local branch_cell="" changes_cell="" sync_cell="" stash_cell="" age_cell=""
  local commit_at="" fetch_outcome="" object="" row="" error_text=""
  local -a attention_rows=() quiet_rows=() attention_objects=()
  local -a quiet_objects=() reasons=() error_lines=() probe=()
  local -i attention_count=0 error_count=0 needs_attention=0 detached=0

  for relative in "${repositories[@]}"; do
    probe=()
    reply=()
    _ws_status_probe "$git_path" "$root/$relative"
    probe=("${reply[@]}")
    name="${relative:t}"
    workspace=""
    [[ "$relative" == */* ]] && workspace="${relative%/*}"
    platform=""
    identity=""
    if [[ "$relative" == */*/* && "$relative" != */*/*/* ]]; then
      platform="${relative%%/*}"
      identity="${${relative#*/}%%/*}"
    fi
    fetch_outcome=""
    (( fetch )) && fetch_outcome="${fetch_outcomes[$relative]:-}"
    detached="${probe[3]:-0}"
    error_text="${probe[12]}"

    reasons=()
    if [[ "${probe[1]}" != ok ]]; then
      reasons+=(error)
      (( ++error_count ))
      error_lines+=("$relative: $error_text")
    else
      [[ "${probe[9]}" == <-> ]] && (( probe[9] > 0 )) && reasons+=(changes)
      [[ "${probe[7]}" == <-> ]] && (( probe[7] > 0 )) && reasons+=(ahead)
      [[ "${probe[8]}" == <-> ]] && (( probe[8] > 0 )) && reasons+=(behind)
      [[ "${probe[10]}" == <-> ]] && (( probe[10] > 0 )) && reasons+=(stashes)
      (( detached )) && reasons+=(detached)
      [[ "${probe[6]}" == gone ]] && reasons+=(upstream-gone)
    fi
    [[ "$fetch_outcome" == (failed|timed-out) ]] && reasons+=(fetch-failed)
    needs_attention=0
    (( ${#reasons[@]} > 0 )) && needs_attention=1
    (( needs_attention )) && (( ++attention_count ))

    commit_at=""
    if [[ "${probe[11]}" == <-> ]]; then
      TZ=UTC strftime -s commit_at '%Y-%m-%dT%H:%M:%SZ' "${probe[11]}" \
        2>/dev/null || commit_at=""
    fi

    if (( json )); then
      object=$(command "$jq_path" -nc \
        --arg path "$root/$relative" \
        --arg relative_path "$relative" \
        --arg workspace "$workspace" \
        --arg platform "$platform" \
        --arg identity "$identity" \
        --arg repository "$name" \
        --arg branch "${probe[2]}" \
        --argjson detached "$(( detached ? 1 : 0 ))" \
        --arg head "${probe[4]}" \
        --arg upstream "${probe[5]}" \
        --arg upstream_state "${probe[6]}" \
        --arg ahead "${probe[7]}" \
        --arg behind "${probe[8]}" \
        --arg changes "${probe[9]}" \
        --arg stashes "${probe[10]}" \
        --arg last_commit_at "$commit_at" \
        --argjson attention "$needs_attention" \
        --arg reasons "${(j:,:)reasons}" \
        --arg fetch "$fetch_outcome" \
        --arg error "$error_text" \
        'def text: if . == "" then null else . end;
         def count: if . == "" then null else tonumber end;
         {
           path: $path,
           relative_path: $relative_path,
           workspace: ($workspace | text),
           platform: ($platform | text),
           identity: ($identity | text),
           repository: $repository,
           branch: ($branch | text),
           detached: ($detached == 1),
           head: ($head | text),
           upstream: ($upstream | text),
           upstream_state: $upstream_state,
           ahead: ($ahead | count),
           behind: ($behind | count),
           changes: ($changes | count),
           stashes: ($stashes | count),
           last_commit_at: ($last_commit_at | text),
           attention: ($attention == 1),
           attention_reasons: (if $reasons == "" then [] else ($reasons | split(",")) end),
           fetch: ($fetch | text),
           error: ($error | text)
         }') || {
        _ws_error "jq could not build the ws-status JSON document."
        return 1
      }
      if (( needs_attention )); then
        attention_objects+=("$object")
      else
        quiet_objects+=("$object")
      fi
      continue
    fi

    if [[ "${probe[1]}" != ok ]]; then
      branch_cell="—"
      changes_cell="error"
      sync_cell="—"
      stash_cell="—"
      age_cell="—"
    else
      if (( detached )); then
        branch_cell="detached at ${probe[4]:-unknown}"
      else
        branch_cell="${probe[2]}"
      fi
      if [[ "${probe[9]}" == 0 ]]; then
        changes_cell="clean"
      else
        changes_cell="${probe[9]}"
      fi
      case "${probe[6]}" in
        tracking)
          if (( probe[7] == 0 && probe[8] == 0 )); then
            sync_cell="up to date"
          elif (( probe[8] == 0 )); then
            sync_cell="ahead ${probe[7]}"
          elif (( probe[7] == 0 )); then
            sync_cell="behind ${probe[8]}"
          else
            sync_cell="ahead ${probe[7]}, behind ${probe[8]}"
          fi
          ;;
        gone) sync_cell="upstream gone" ;;
        *) sync_cell="no upstream" ;;
      esac
      stash_cell="${probe[10]:-unknown}"
      if [[ "${probe[11]}" == <-> ]]; then
        _ws_status_age $(( now - probe[11] ))
        age_cell="$REPLY"
      else
        age_cell="none"
      fi
    fi
    [[ "$fetch_outcome" == (failed|timed-out) ]] \
      && sync_cell+=" (fetch failed)"
    row="${workspace:-.}"$'\t'"$name"$'\t'"$branch_cell"$'\t'"$changes_cell"
    row+=$'\t'"$sync_cell"$'\t'"$stash_cell"$'\t'"$age_cell"
    if (( needs_attention )); then
      attention_rows+=("$row")
    else
      quiet_rows+=("$row")
    fi
  done

  local -i final_rc=0
  (( error_count > 0 || fetch_failures > 0 )) && final_rc=1
  if (( final_rc != 0 && error_count < total )); then
    _ws_mark_partial
  fi

  if (( json )); then
    {
      (( ${#attention_objects[@]} > 0 )) \
        && print -rl -- "${attention_objects[@]}"
      (( ${#quiet_objects[@]} > 0 )) \
        && print -rl -- "${quiet_objects[@]}"
      true
    } | command "$jq_path" -c -n \
      --arg schema "zdx.ws-status.v1" \
      --arg base "$root" \
      --argjson fetched "$fetch" \
      --argjson repositories "$total" \
      --argjson attention "$attention_count" \
      --argjson errors "$error_count" \
      '{
         schema: $schema,
         base: $base,
         fetched: ($fetched == 1),
         counts: {
           repositories: $repositories,
           attention: $attention,
           errors: $errors
         },
         repositories: [inputs]
       }' || {
      _ws_error "jq could not build the ws-status JSON document."
      return 1
    }
    return $final_rc
  fi

  if (( total == 0 )); then
    _ws_info "No repositories were found below $root_display."
    return 0
  fi
  _ws_label "Repositories" "$total"
  print -u2 -r -- ""
  _ws_table \
    $'Workspace\tRepository\tBranch\tChanges\tSync\tStashes\tLast commit' \
    "${attention_rows[@]}" "${quiet_rows[@]}"
  print -u2 -r -- ""
  local error_line=""
  for error_line in "${error_lines[@]}"; do
    _ws_error "$error_line"
  done
  if (( attention_count > 0 )); then
    _ws_count_noun "$total" repository repositories
    if (( attention_count == 1 )); then
      _ws_warn "1 of $REPLY needs attention."
    else
      _ws_warn "$attention_count of $REPLY need attention."
    fi
  fi
  return $final_rc
}

typeset -g _WS_STATUS_SOURCED=1
