#!/usr/bin/env zsh
# =============================================================================
# WS Sync: fetch and fast-forward every repo, then browse repository status
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_WS_SYNC_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ws_sync_create_stash() {
  emulate -L zsh

  local repo_dir="$1"
  local message="$2"
  local before_oid=""
  local stash_inventory=""
  zmodload zsh/datetime 2>/dev/null || true
  local token="zdx-ws-sync:${EPOCHREALTIME:-$SECONDS}:$$:$RANDOM"
  local tagged_message="${message} [${token}]"
  REPLY=""

  before_oid=$(git -C "$repo_dir" rev-parse --verify refs/stash 2>/dev/null) \
    || before_oid=""
  git -C "$repo_dir" stash push --include-untracked -m "$tagged_message" \
    >/dev/null 2>&1 || return 1
  REPLY="$token"
  stash_inventory=$(git -C "$repo_dir" stash list \
    --format='%H%x09%gs' 2>/dev/null) || return 2

  local record=""
  local -a record_parts=()
  local -a matching_oids=()
  for record in ${(f)stash_inventory}; do
    record_parts=("${(ps:\t:)record}")
    [[ "${record_parts[2]:-}" == *"$token"* ]] \
      && matching_oids+=("${record_parts[1]:-}")
  done
  (( ${#matching_oids[@]} == 1 )) || return 2
  REPLY="${matching_oids[1]}"
  [[ -n "$REPLY" && "$REPLY" != "$before_oid" ]] || return 2
  return 0
}

_ws_sync_restore_stash() {
  emulate -L zsh

  local repo_dir="$1"
  local stash_oid="$2"

  git -C "$repo_dir" stash apply --index "$stash_oid" >/dev/null 2>&1 \
    || return 1

  # Stash selectors are index-based. Another process can push between a
  # selector lookup and `stash drop`, so preserve the exact recovery object
  # instead of risking deletion of somebody else's stash.
  return 0
}

_ws_sync_repo_unchanged() {
  emulate -L zsh

  local workspace_dir="${1:-}"
  local repo_dir="${2:-}"
  local expected_fingerprint="${3:-}"
  [[ -n "$expected_fingerprint" ]] || return 1
  _ws_repo_fingerprint "$workspace_dir" "$repo_dir" \
    && [[ "$REPLY" == "$expected_fingerprint" ]]
}

_ws_sync_head_snapshot() {
  emulate -L zsh

  local repo_dir="${1:-}"
  REPLY=""
  local branch_name=""
  local head_oid=""
  branch_name=$(git -C "$repo_dir" branch --show-current 2>/dev/null) \
    || return 1
  [[ -n "$branch_name" ]] || return 1
  head_oid=$(git -C "$repo_dir" rev-parse --verify HEAD 2>/dev/null) \
    || return 1
  [[ "$head_oid" =~ '^[0-9a-f]{40}$|^[0-9a-f]{64}$' ]] || return 1
  REPLY="${branch_name}	${head_oid}"
}

_ws_sync_branch_snapshot() {
  emulate -L zsh

  local repo_dir="${1:-}"
  local head_snapshot=""
  _ws_sync_head_snapshot "$repo_dir" || return 1
  head_snapshot="$REPLY"
  local branch_name="${head_snapshot%%	*}"
  local upstream=""
  local upstream_oid=""
  upstream=$(git -C "$repo_dir" rev-parse --abbrev-ref \
    "${branch_name}@{upstream}" 2>/dev/null) || return 1
  upstream_oid=$(git -C "$repo_dir" rev-parse --verify "$upstream" \
    2>/dev/null) || return 1
  [[ -n "$upstream" \
    && "$upstream_oid" =~ '^[0-9a-f]{40}$|^[0-9a-f]{64}$' ]] || return 1
  REPLY="${head_snapshot}	${upstream}	${upstream_oid}"
}

_ws_sync_branch_matches() {
  local repo_dir="${1:-}"
  local expected_snapshot="${2:-}"
  [[ -n "$expected_snapshot" ]] || return 1
  _ws_sync_branch_snapshot "$repo_dir" \
    && [[ "$REPLY" == "$expected_snapshot" ]]
}

_ws_sync_fast_forward_matches() {
  local planned_snapshot="${1:-}"
  local current_snapshot="${2:-}"
  local -a planned_parts=("${(ps:\t:)planned_snapshot}")
  local -a current_parts=("${(ps:\t:)current_snapshot}")
  (( ${#planned_parts[@]} == 4 && ${#current_parts[@]} == 4 )) \
    && [[ "${current_parts[1]}" == "${planned_parts[1]}" \
      && "${current_parts[2]}" == "${planned_parts[4]}" \
      && "${current_parts[3]}" == "${planned_parts[3]}" \
      && "${current_parts[4]}" == "${planned_parts[4]}" ]]
}

_ws_sync_worktree_clean() {
  local repo_dir="${1:-}"
  local status_output=""
  status_output=$(git -C "$repo_dir" status --porcelain \
    2>/dev/null) || return 1
  [[ -z "$status_output" ]]
}

ws-sync() {
  emulate -L zsh

  local REPLY=""
  _ws_parse_no_args ws-sync \
    "Fetch every repository, fast-forward clean behind branches, and offer stash handling." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git fzf || return 1

  # --- Resolve workspace ---
  local ws=""
  local current_ws=""
  current_ws=$(_tk_detect_workspace)

  if [[ -n "$current_ws" ]]; then
    ws="$current_ws"
    _tk_info "Detected workspace: $ws"
  else
    _ws_capture_workspace_selection "Sync repos in" || return $?
    ws="$REPLY"
    [[ -z "$ws" ]] && return 0
  fi

  _ws_resolve_workspace "$ws" || return $?
  local ws_dir="$REPLY"
  [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
    _tk_error "Workspace not found: ${(V)ws}"
    return 1
  }
  local host_alias=""
  host_alias=$(_tk_host_alias "${ws%%/*}" "${ws#*/}")

  # --- Discover repos ---
  local -a repos=()
  local -A repo_fingerprints=()
  local r=""
  for r in "$ws_dir"/*(DN/); do
    [[ "${r:t}" == ".ssh" ]] && continue
    if _ws_repo_fingerprint "$ws_dir" "$r"; then
      local repo_name="${r:t}"
      repos+=("$repo_name")
      repo_fingerprints[$repo_name]="$REPLY"
    fi
  done

  if (( ${#repos[@]} == 0 )); then
    _tk_warn "No repos found in $ws_dir"
    return 0
  fi

  _tk_header "Sync: $ws (${#repos[@]} repos)"

  # --- Sync loop ---
  local synced=0 fetched_only=0 issues=0
  local dirty_repos=()
  local -A dirty_branch_snapshots=()
  local diverged_repos=()
  local new_remote_branches=()
  local -a remote_candidate_order=()
  local -A remote_candidate_refs=()
  local -A remote_candidate_ambiguous=()

  local repo=""
  for repo in "${repos[@]}"; do
    local repo_dir="$ws_dir/$repo"
    if ! _ws_sync_repo_unchanged \
      "$ws_dir" "$repo_dir" "${repo_fingerprints[$repo]}"; then
      _tk_error "[$repo] Repository path changed before fetch."
      ((issues++))
      continue
    fi
    local branch=""
    branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null)
    [[ -z "$branch" ]] && branch="(detached)"

    # Fetch
    if ! git -C "$repo_dir" fetch --all --prune 2>/dev/null; then
      printf "  ✘ %-30s [%s] fetch failed\n" \
        "${(V)repo}" "${(V)branch}" >&2
      ((issues++))
      continue
    fi

    # Detect new remote branches not tracked locally
    local remote_only=""
    remote_only=$(git -C "$repo_dir" branch -r --no-merged HEAD 2>/dev/null \
      | grep -v '\->' \
      | while read rb; do
          rb="${rb## }"
          rb="${rb%% }"
          local local_name="${rb#*/}"
          local_name="${local_name## }"
          if [[ "$rb" == */* ]] \
            && git check-ref-format "refs/remotes/$rb" &>/dev/null \
            && git check-ref-format --branch "$local_name" &>/dev/null \
            && ! git -C "$repo_dir" show-ref --verify --quiet \
              "refs/heads/$local_name" 2>/dev/null; then
            print -r -- "${rb}	${local_name}"
          fi
        done)
    if [[ -n "$remote_only" ]]; then
      local rb_line=""
      for rb_line in ${(f)remote_only}; do
        local -a rb_parts=("${(ps:\t:)rb_line}")
        local remote_ref="${rb_parts[1]:-}"
        local local_name="${rb_parts[2]:-}"
        local candidate_key="${repo}	${local_name}"
        if (( ! ${+remote_candidate_refs[$candidate_key]} )); then
          remote_candidate_order+=("$candidate_key")
          remote_candidate_refs[$candidate_key]="$remote_ref"
        elif [[ "${remote_candidate_refs[$candidate_key]}" != "$remote_ref" ]]; then
          remote_candidate_ambiguous[$candidate_key]=1
        fi
      done
    fi

    # Check working tree status
    local status_output=""
    status_output=$(git -C "$repo_dir" status --porcelain \
      2>/dev/null) || {
      _tk_error "[$repo] Could not inspect the working tree."
      ((issues++))
      continue
    }
    local -i dirty_count=0
    local -a status_lines=()
    [[ -n "$status_output" ]] && status_lines=("${(f)status_output}")
    dirty_count=${#status_lines[@]}

    if [[ "$branch" == "(detached)" ]]; then
      printf "  ⏭ %-30s [%s] detached HEAD — fetched only\n" \
        "${(V)repo}" "${(V)branch}" >&2
      ((fetched_only++))
      continue
    fi

    # Check if upstream exists
    local upstream=""
    upstream=$(git -C "$repo_dir" rev-parse \
      --abbrev-ref "${branch}@{upstream}" 2>/dev/null)

    if [[ -z "$upstream" ]]; then
      printf "  ⏭ %-30s [%s] no upstream — fetched only\n" \
        "${(V)repo}" "${(V)branch}" >&2
      ((fetched_only++))
      continue
    fi
    local branch_snapshot=""
    _ws_sync_branch_snapshot "$repo_dir" || {
      _tk_error "[$repo] Could not freeze branch state."
      ((issues++))
      continue
    }
    branch_snapshot="$REPLY"
    local -a branch_snapshot_parts=("${(ps:\t:)branch_snapshot}")
    [[ "${branch_snapshot_parts[1]:-}" == "$branch" \
      && "${branch_snapshot_parts[3]:-}" == "$upstream" \
      && "${branch_snapshot_parts[4]:-}" \
        =~ '^[0-9a-f]{40}$|^[0-9a-f]{64}$' ]] || {
      _tk_error "[$repo] Branch state changed during inspection."
      ((issues++))
      continue
    }
    local planned_upstream_oid="${branch_snapshot_parts[4]}"

    # Check ahead/behind
    local ahead="" behind=""
    ahead=$(git -C "$repo_dir" rev-list --count \
      "${upstream}..HEAD" 2>/dev/null) || ahead=""
    behind=$(git -C "$repo_dir" rev-list --count \
      "HEAD..${upstream}" 2>/dev/null) || behind=""
    if [[ "$ahead" != <-> || "$behind" != <-> ]]; then
      _tk_error "[$repo] Could not calculate ahead/behind state."
      ((issues++))
      continue
    fi

    if (( behind == 0 && ahead == 0 )); then
      printf "  ✔ %-30s [%s] up to date\n" \
        "${(V)repo}" "${(V)branch}" >&2
      ((synced++))

    elif (( behind > 0 && ahead == 0 )); then
      # Can fast-forward
      if (( dirty_count > 0 )); then
        printf "  ● %-30s [%s] ⬇ %d behind — %d local changes (fetched only)\n" \
          "${(V)repo}" "${(V)branch}" "$behind" "$dirty_count" >&2
        dirty_repos+=("$repo")
        dirty_branch_snapshots[$repo]="$branch_snapshot"
        ((fetched_only++))
      else
        if ! _ws_sync_repo_unchanged \
          "$ws_dir" "$repo_dir" "${repo_fingerprints[$repo]}" \
          || ! _ws_sync_branch_matches "$repo_dir" "$branch_snapshot" \
          || ! _ws_sync_worktree_clean "$repo_dir"; then
          _tk_error "[$repo] Repository or branch state changed before pull."
          ((issues++))
        elif git -C "$repo_dir" merge --ff-only -- "$planned_upstream_oid" \
          2>/dev/null; then
          local post_merge_snapshot=""
          if _ws_sync_branch_snapshot "$repo_dir" \
            && post_merge_snapshot="$REPLY" \
            && _ws_sync_fast_forward_matches \
              "$branch_snapshot" "$post_merge_snapshot"; then
            printf "  ✔ %-30s [%s] ⬇ %d commits fast-forwarded\n" \
              "${(V)repo}" "${(V)branch}" "$behind" >&2
            ((synced++))
          else
            _tk_error \
              "[$repo] Branch state changed during the fast-forward."
            ((issues++))
          fi
        else
          printf "  ✘ %-30s [%s] fast-forward failed\n" \
            "${(V)repo}" "${(V)branch}" >&2
          ((issues++))
        fi
      fi

    elif (( ahead > 0 && behind == 0 )); then
      printf "  ⬆ %-30s [%s] %d ahead (unpushed)\n" \
        "${(V)repo}" "${(V)branch}" "$ahead" >&2
      ((synced++))

    else
      # Diverged
      printf "  ⚡ %-30s [%s] diverged (%d ahead, %d behind)\n" \
        "${(V)repo}" "${(V)branch}" "$ahead" "$behind" >&2
      diverged_repos+=("$repo")
      ((issues++))
    fi
  done

  local candidate_key=""
  for candidate_key in "${remote_candidate_order[@]}"; do
    local repo_name="${candidate_key%%	*}"
    local local_name="${candidate_key#*	}"
    if (( ${+remote_candidate_ambiguous[$candidate_key]} )); then
      _tk_warn \
        "$repo_name: multiple remotes offer $local_name; automatic checkout was skipped."
      continue
    fi
    new_remote_branches+=(
      "${repo_name}	${remote_candidate_refs[$candidate_key]}	${local_name}"
    )
  done

  # --- Summary ---
  print -u2 -r -- ""
  print -u2 -r -- "────────────────────────────────────────"
  print -u2 -r -- "  Sync Summary"
  print -u2 -r -- "────────────────────────────────────────"
  print -u2 -r -- ""
  _tk_label "Workspace"    "$ws"
  _tk_label "Synced"       "$synced"
  [[ $fetched_only -gt 0 ]] && _tk_label "Fetched only" "$fetched_only"
  [[ $issues -gt 0 ]]      && _tk_label "Issues"       "$issues"
  print -u2 -r -- ""

  # --- Offer stash+pull for dirty repos ---
  if (( ${#dirty_repos[@]} > 0 )); then
    _tk_warn "${#dirty_repos[@]} repo(s) had local changes and were not pulled."
    if [[ ! -t 0 || ! -t 2 ]]; then
      _tk_error \
        "Stash-and-pull requires an interactive terminal; dirty repositories were left unchanged."
      ((issues++))
    elif _tk_confirm "Stash → pull → unstash for these repos?"; then
      print -u2 -r -- ""
      for repo in "${dirty_repos[@]}"; do
        local repo_dir="$ws_dir/$repo"
        local stash_oid=""

        _tk_info "Stash + pull: $repo"
        if ! _ws_sync_repo_unchanged \
          "$ws_dir" "$repo_dir" "${repo_fingerprints[$repo]}" \
          || ! _ws_sync_branch_matches \
            "$repo_dir" "${dirty_branch_snapshots[$repo]:-}"; then
          _tk_error "$repo: repository path changed before stash"
          ((issues++))
          continue
        fi
        _ws_sync_create_stash "$repo_dir" \
          "ws-sync invocation-owned auto-stash"
        local -i stash_status=$?
        if (( stash_status != 0 )); then
          if (( stash_status == 2 )) && [[ -n "$REPLY" ]]; then
            _tk_error \
              "$repo: stash ownership could not be verified; inspect git stash list for marker ${(V)REPLY}"
          else
            _tk_error "$repo: could not create an invocation-owned stash"
          fi
          ((issues++))
          continue
        fi
        stash_oid="$REPLY"

        if ! _ws_sync_repo_unchanged \
          "$ws_dir" "$repo_dir" "${repo_fingerprints[$repo]}" \
          || ! _ws_sync_branch_matches \
            "$repo_dir" "${dirty_branch_snapshots[$repo]:-}" \
          || ! _ws_sync_worktree_clean "$repo_dir"; then
          _tk_error \
            "$repo: repository path changed after stash; recovery object ${(V)stash_oid} was preserved"
          ((issues++))
          continue
        fi

        local -i merge_status=0
        local planned_snapshot="${dirty_branch_snapshots[$repo]:-}"
        local -a planned_parts=("${(ps:\t:)planned_snapshot}")
        local planned_upstream_oid="${planned_parts[4]:-}"
        if [[ ! "$planned_upstream_oid" \
          =~ '^[0-9a-f]{40}$|^[0-9a-f]{64}$' ]]; then
          _tk_error \
            "$repo: frozen upstream object is invalid; recovery object ${(V)stash_oid} was preserved"
          ((issues++))
          continue
        fi
        git -C "$repo_dir" merge --ff-only -- "$planned_upstream_oid" \
          >&2 || merge_status=$?
        if (( merge_status == 0 )); then
          _tk_success "$repo fast-forwarded"
        else
          _tk_error "$repo fast-forward failed after stash"
          ((issues++))
        fi

        local restore_snapshot=""
        _ws_sync_branch_snapshot "$repo_dir" || {
          _tk_error \
            "$repo: branch state is uncertain after pull; recovery object ${(V)stash_oid} was preserved"
          ((issues++))
          continue
        }
        restore_snapshot="$REPLY"
        if (( merge_status == 0 )) \
          && ! _ws_sync_fast_forward_matches \
            "$planned_snapshot" "$restore_snapshot"; then
          _tk_error \
            "$repo: branch state changed during fast-forward; recovery object ${(V)stash_oid} was preserved"
          ((issues++))
          continue
        elif (( merge_status != 0 )) \
          && [[ "$restore_snapshot" != "$planned_snapshot" ]]; then
          _tk_error \
            "$repo: failed fast-forward changed branch state; recovery object ${(V)stash_oid} was preserved"
          ((issues++))
          continue
        fi
        if ! _ws_sync_repo_unchanged \
          "$ws_dir" "$repo_dir" "${repo_fingerprints[$repo]}" \
          || ! _ws_sync_branch_matches "$repo_dir" "$restore_snapshot"; then
          _tk_error \
            "$repo: repository path changed before restore; recovery object ${(V)stash_oid} was preserved"
          ((issues++))
          continue
        fi
        _ws_sync_restore_stash "$repo_dir" "$stash_oid"
        local -i restore_status=$?
        if (( restore_status == 1 )); then
          _tk_warn "$repo: restoring stash $stash_oid had conflicts"
          _tk_dim "  The invocation-owned stash was preserved."
          ((issues++))
        else
          _tk_dim \
            "$repo: changes restored; recovery stash ${(V)stash_oid} was preserved."
        fi
      done
      print -u2 -r -- ""
    fi
  fi

  # --- Report diverged repos ---
  if (( ${#diverged_repos[@]} > 0 )); then
    _tk_warn "Diverged repos need manual resolution:"
    for repo in "${diverged_repos[@]}"; do
      _tk_dim "  cd $ws_dir/$repo && git pull --rebase  # or merge"
    done
    print -u2 -r -- ""
  fi

  # --- Report new remote branches ---
  if (( ${#new_remote_branches[@]} > 0 )); then
    _tk_info "New remote branches not tracked locally:"
    local entry=""
    for entry in "${new_remote_branches[@]}"; do
      local -a entry_parts=("${(ps:\t:)entry}")
      local r_name="${entry_parts[1]:-}"
      local remote_ref="${entry_parts[2]:-}"
      local b_name="${entry_parts[3]:-}"
      _tk_dim "  $r_name → $remote_ref as $b_name"
    done
    print -u2 -r -- ""

    if [[ ! -t 0 || ! -t 2 ]]; then
      _tk_error \
        "Remote-branch checkout requires an interactive terminal; no branches were checked out."
      ((issues++))
    elif _tk_confirm "Checkout new remote branches locally?"; then
      for entry in "${new_remote_branches[@]}"; do
        local -a entry_parts=("${(ps:\t:)entry}")
        local r_name="${entry_parts[1]:-}"
        local remote_ref="${entry_parts[2]:-}"
        local b_name="${entry_parts[3]:-}"
        local repo_dir="$ws_dir/$r_name"
        local head_snapshot=""
        _ws_sync_head_snapshot "$repo_dir" \
          && head_snapshot="$REPLY" || head_snapshot=""

        if ! _ws_sync_repo_unchanged \
          "$ws_dir" "$repo_dir" "${repo_fingerprints[$r_name]:-}"; then
          _tk_error "$r_name: repository path changed before checkout"
          ((issues++))
        elif [[ -z "$head_snapshot" ]] \
          || ! _ws_sync_head_snapshot "$repo_dir" \
          || [[ "$REPLY" != "$head_snapshot" ]]; then
          _tk_error "$r_name: branch state changed before checkout"
          ((issues++))
        elif ! git check-ref-format "refs/remotes/$remote_ref" &>/dev/null \
          || ! git check-ref-format --branch "$b_name" &>/dev/null; then
          _tk_error "$r_name: invalid remote branch name ${(V)b_name}"
          ((issues++))
        elif git -C "$repo_dir" checkout --track "$remote_ref" >&2; then
          _tk_success "$r_name: checked out $b_name"
          # Return to previous branch
          git -C "$repo_dir" checkout - >&2 || {
            _tk_error "$r_name: could not return to the previous branch"
            ((issues++))
          }
        else
          _tk_warn "$r_name: could not checkout $b_name"
          ((issues++))
        fi
      done
      print -u2 -r -- ""
    fi
  fi

  (( issues == 0 ))
}


# =============================================================================
# LIST REPOS IN WORKSPACE
# =============================================================================

ws-repos() {
  emulate -L zsh

  local REPLY=""
  _ws_parse_no_args ws-repos \
    "Display branch, dirty count, and redacted origin for each repository." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git ssh-keygen fzf || return 1

  local ws=""
  _ws_capture_workspace_selection "Show repos for" || return $?
  ws="$REPLY"
  [[ -z "$ws" ]] && return 0

  _ws_resolve_workspace "$ws" || return $?
  local ws_dir="$REPLY"
  [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
    _tk_error "Workspace not found: ${(V)ws}"
    return 1
  }
  local host_alias=""
  host_alias=$(_tk_host_alias "${ws%%/*}" "${ws#*/}")

  _tk_header "Repos in $ws"

  local repo_count=0
  for r in "$ws_dir"/*(DN/); do
    [[ "${r:t}" == ".ssh" ]] && continue
    if _ws_validate_repo_dir "$ws_dir" "$r"; then
      local safe_repo_dir="$REPLY"
      repo_count=$((repo_count + 1))
      local repo_name="${safe_repo_dir:t}"
      local remote=""
          remote=$(git -C "$safe_repo_dir" remote get-url origin 2>/dev/null) \
        || remote="(no remote)"
      remote=$(_ws_redact_remote_url "$remote")
      local branch=""
          branch=$(git -C "$safe_repo_dir" branch --show-current 2>/dev/null) \
        || branch="?"
      local status_clean=""
          status_clean=$(git -C "$safe_repo_dir" status --porcelain 2>/dev/null \
        | wc -l | xargs)

      local status_icon=""
          if [[ "$status_clean" == "0" ]]; then
        status_icon="✔"
      else
        status_icon="● ${status_clean} changes"
      fi

      print -u2 -r -- \
        "  $status_icon ${(V)repo_name} [${(V)branch}]"
      _tk_dim "    $remote"
    fi
  done

  if [[ $repo_count -eq 0 ]]; then
    _tk_warn "No repos found."
    print -u2 -r -- ""
    print -u2 -r -- \
      "  Clone with: git clone git@${host_alias}:owner/repo.git"
    print -u2 -r -- "  Or use:     ws-clone"
  fi
  print -u2 -r -- ""
}

typeset -g _WS_SYNC_SOURCED=1
