#!/usr/bin/env zsh
# =============================================================================
# WS Autoclean: delete stale branches across all workspace repositories
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_WS_AUTOCLEAN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_ws_autoclean_branch_still_stale() {
  emulate -L zsh

  local repo_dir="${1:-}"
  local branch_name="${2:-}"
  command git check-ref-format --branch "$branch_name" &>/dev/null \
    || return 1

  local current_branch=""
  current_branch=$(command git -C "$repo_dir" branch --show-current \
    2>/dev/null) || return 1
  local default_branch=""
  default_branch=$(cd "$repo_dir" && _tk_get_default_branch) || return 1
  [[ "$branch_name" != "$current_branch" \
    && "$branch_name" != "$default_branch" \
    && "$branch_name" != "main" \
    && "$branch_name" != "master" ]] || return 1

  local branch_record=""
  branch_record=$(command git -C "$repo_dir" branch \
    --format='%(refname:short)%09%(upstream:track)' \
    --list "$branch_name" 2>/dev/null) || return 1
  [[ -n "$branch_record" ]] || return 1

  local -a branch_parts=("${(ps:\t:)branch_record}")
  [[ "${branch_parts[1]:-}" == "$branch_name" ]] || return 1
  [[ "${branch_parts[2]:-}" == "[gone]" ]] && return 0

  local merged_branches=""
  merged_branches=$(command git -C "$repo_dir" branch \
    --merged "$default_branch" --format='%(refname:short)' \
    2>/dev/null) || return 1
  (( ${${(f)merged_branches}[(Ie)$branch_name]} > 0 ))
}

_ws_autoclean_confirmation_available() {
  [[ -t 0 && -t 2 ]]
}

_ws_autoclean_branch_checked_out() {
  emulate -L zsh

  local repo_dir="${1:-}"
  local branch_name="${2:-}"
  local worktree_state=""
  worktree_state=$(command git -C "$repo_dir" worktree list --porcelain \
    2>/dev/null) || return 2

  local record=""
  for record in ${(f)worktree_state}; do
    [[ "$record" == "branch refs/heads/$branch_name" ]] && return 0
  done
  return 1
}

ws-autoclean() {
  emulate -L zsh

  local REPLY=""
  _ws_parse_no_args ws-autoclean \
    "Fetch, prune, and compare-and-delete selected merged or gone branches." \
    "$@" || return 2
  [[ "$REPLY" == "help" ]] && return 0
  _tk_check_deps git fzf || return 1

  # --- Resolve workspace ---
  local ws=""
  local current_ws=""
  current_ws=$(_tk_detect_workspace 2>/dev/null)

  if [[ -n "$current_ws" ]]; then
    ws="$current_ws"
    _tk_info "Detected workspace: $ws"
  else
    _ws_capture_workspace_selection "Autoclean branches in" || return $?
    ws="$REPLY"
    [[ -z "$ws" ]] && return 0
  fi

  _ws_resolve_workspace "$ws" || return $?
  local ws_dir="$REPLY"
  [[ -d "$ws_dir" && ! -L "$ws_dir" ]] || {
    _tk_error "Workspace not found: ${(V)ws}"
    return 1
  }

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

  _tk_header "Autoclean: $ws (${#repos[@]} repos)"
  _tk_info "Scanning workspace '$ws' for stale branches..."

  local -a candidates=()
  local -A allowed_candidates=()
  local -A candidate_branch_oids=()
  local -i scan_failures=0
  local repo=""
  for repo in "${repos[@]}"; do
    local repo_dir="$ws_dir/$repo"
    if ! _ws_repo_fingerprint "$ws_dir" "$repo_dir" \
      || [[ "$REPLY" != "${repo_fingerprints[$repo]}" ]]; then
      _tk_error "[$repo] Repository path changed before fetch."
      ((scan_failures++))
      continue
    fi
    _tk_dim "$repo: fetching remote status..."

    # Prune remote tracking branches to detect gone branches accurately
    if ! command git -C "$repo_dir" fetch --prune --all &>/dev/null; then
      _tk_error "[$repo] Fetch failed; stale branches were not evaluated."
      ((scan_failures++))
      continue
    fi

    local default_branch=""
    default_branch=$(cd "$repo_dir" && _tk_get_default_branch) || {
      _tk_error "[$repo] Could not determine the default branch."
      ((scan_failures++))
      continue
    }
    local current_branch=""
    current_branch=$(command git -C "$repo_dir" branch --show-current \
      2>/dev/null) || {
      _tk_error "[$repo] Could not determine the current branch."
      ((scan_failures++))
      continue
    }

    # Retrieve merged branches list
    local merged_branches=""
    merged_branches=$(command git -C "$repo_dir" branch \
      --merged "$default_branch" --format='%(refname:short)' \
      2>/dev/null) || {
      _tk_error "[$repo] Could not inspect merged branches."
      ((scan_failures++))
      continue
    }

    # Retrieve branch details with git branch format
    local branch_lines=""
    branch_lines=$(command git -C "$repo_dir" branch \
      --format='%(refname:short)%09%(upstream:track)' \
      2>/dev/null) || {
      _tk_error "[$repo] Could not inspect local branches."
      ((scan_failures++))
      continue
    }

    [[ -z "$branch_lines" ]] && continue

    local bline=""
    for bline in ${(f)branch_lines}; do
      # Parse tab-separated line using Zsh-native parameter splitting to avoid read overrides
      local -a bparts=("${(ps:\t:)bline}")
      local bname="${bparts[1]:-}"
      local btrack="${bparts[2]:-}"

      bname="${bname## }"
      bname="${bname%% }"

      # Protect current and default branches
      [[ "$bname" == "$default_branch" || "$bname" == "$current_branch" ]] && continue
      [[ "$bname" == "main" || "$bname" == "master" ]] && continue

      local is_merged=0
      if (( ${${(f)merged_branches}[(Ie)$bname]} > 0 )); then
        is_merged=1
      fi

      local is_gone=0
      if [[ "$btrack" == "[gone]" ]]; then
        is_gone=1
      fi

      if (( is_merged || is_gone )); then
        local reason=""
        if (( is_merged && is_gone )); then
          reason="merged & gone"
        elif (( is_merged )); then
          reason="merged"
        else
          reason="remote gone"
        fi

        local display_label="[$repo] $bname ($reason)"
        local candidate="${display_label}	${repo}	${bname}"
        local branch_oid=""
        branch_oid=$(command git -C "$repo_dir" rev-parse --verify \
          "refs/heads/$bname" 2>/dev/null) || {
          _tk_error "[$repo] Could not fingerprint branch ${(V)bname}."
          ((scan_failures++))
          continue
        }
        [[ "$branch_oid" =~ '^[0-9a-f]{40}$|^[0-9a-f]{64}$' ]] || {
          _tk_error "[$repo] Refusing an invalid branch object ID."
          ((scan_failures++))
          continue
        }
        candidates+=("$candidate")
        allowed_candidates[$candidate]=1
        candidate_branch_oids[$candidate]="$branch_oid"
      fi
    done
  done

  if (( ${#candidates[@]} == 0 )); then
    print -u2 -r -- ""
    if (( scan_failures == 0 )); then
      _tk_success "No stale branches found in workspace '$ws'."
      return 0
    fi
    _tk_error \
      "Branch scan failed for $scan_failures repository/repositories; no deletion was attempted."
    return 1
  fi

  print -u2 -r -- ""
  local selected=""
  local -i fzf_rc=0
  _ws_fzf_capture -m --ansi \
    --height=60% --layout=reverse --border \
    --delimiter='\t' \
    --with-nth=1 \
    --header="TAB to select multiple | ENTER to delete (Force -D)" \
    --prompt="Delete stale branches > " \
    --preview-window=hidden \
    < <(printf "%s\n" "${candidates[@]}") || fzf_rc=$?
  selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _ws_fzf_rc_is_cancel "$fzf_rc" && return 0
    _tk_error "Unable to select stale branches (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0

  local -a selected_lines=("${(f)selected}")
  local -i count=${#selected_lines[@]}
  local selected_line=""
  local -A selected_candidate_seen=()
  for selected_line in "${selected_lines[@]}"; do
    [[ -n "$selected_line" \
      && ${+allowed_candidates[$selected_line]} -eq 1 \
      && ${+selected_candidate_seen[$selected_line]} -eq 0 ]] || {
      _tk_error "The stale-branch selection is invalid or duplicated."
      return 2
    }
    selected_candidate_seen[$selected_line]=1
  done
  _ws_autoclean_confirmation_available || {
    _tk_error \
      "Branch deletion requires an interactive terminal; no branches were deleted."
    return 1
  }
  _tk_confirm_count "$count" "stale branch(es) across workspace '$ws'" || { _tk_info "Cancelled."; return 0; }

  local line=""
  local -i deletion_failures=0
  for line in ${(f)selected}; do
    [[ -z "$line" ]] && continue
    if (( ! ${+allowed_candidates[$line]} )); then
      _tk_error "Invalid branch selection."
      return 2
    fi
    local -a parts=("${(ps:\t:)line}")
    local repo_name=$parts[2]
    local branch_name=$parts[3]
    git check-ref-format --branch "$branch_name" >/dev/null 2>&1 || {
      _tk_error "Invalid branch name: ${(V)branch_name}"
      return 2
    }

    local repo_dir="$ws_dir/$repo_name"
    if ! _ws_repo_fingerprint "$ws_dir" "$repo_dir" \
      || [[ "$REPLY" != "${repo_fingerprints[$repo_name]:-}" ]]; then
      _tk_error "[$repo_name] Repository path changed after selection."
      ((deletion_failures++))
      continue
    fi
    if ! _ws_autoclean_branch_still_stale "$repo_dir" "$branch_name"; then
      _tk_error \
        "[$repo_name] Branch state changed; refusing to delete ${(V)branch_name}."
      ((deletion_failures++))
      continue
    fi
    local current_branch_oid=""
    current_branch_oid=$(command git -C "$repo_dir" rev-parse --verify \
      "refs/heads/$branch_name" 2>/dev/null) || current_branch_oid=""
    if [[ -z "$current_branch_oid" \
      || "$current_branch_oid" != "${candidate_branch_oids[$line]:-}" ]]; then
      _tk_error \
        "[$repo_name] Branch object changed; refusing to delete ${(V)branch_name}."
      ((deletion_failures++))
      continue
    fi

    local -i checked_out_rc=0
    _ws_autoclean_branch_checked_out "$repo_dir" "$branch_name" \
      || checked_out_rc=$?
    case "$checked_out_rc" in
      0)
        _tk_error \
          "[$repo_name] Branch is checked out in a worktree; refusing to delete ${(V)branch_name}."
        ((deletion_failures++))
        continue
        ;;
      1)
        ;;
      *)
        _tk_error \
          "[$repo_name] Could not inspect linked worktrees; refusing to delete ${(V)branch_name}."
        ((deletion_failures++))
        continue
        ;;
    esac

    _tk_info "[$repo_name] Deleting branch: $branch_name"
    local expected_oid="${candidate_branch_oids[$line]}"
    if ! command git -C "$repo_dir" update-ref -d \
      "refs/heads/$branch_name" "$expected_oid" &>/dev/null; then
      _tk_error \
        "[$repo_name] Branch changed during deletion; ${(V)branch_name} was preserved."
      ((deletion_failures++))
      continue
    fi

    checked_out_rc=0
    _ws_autoclean_branch_checked_out "$repo_dir" "$branch_name" \
      || checked_out_rc=$?
    if (( checked_out_rc == 0 )); then
      local zero_oid="${expected_oid//?/0}"
      if command git -C "$repo_dir" update-ref \
        "refs/heads/$branch_name" "$expected_oid" "$zero_oid" &>/dev/null; then
        _tk_error \
          "[$repo_name] Branch became active during deletion and was restored."
      else
        _tk_error \
          "[$repo_name] Branch became active during deletion; restore ${(V)branch_name} to $expected_oid."
      fi
      ((deletion_failures++))
      continue
    elif (( checked_out_rc > 1 )); then
      _tk_warn \
        "[$repo_name] Deleted ${(V)branch_name}, but the final worktree check failed."
      ((deletion_failures++))
      continue
    fi

    _tk_success "[$repo_name] Deleted $branch_name"
  done

  print -u2 -r -- ""
  if (( deletion_failures == 0 && scan_failures == 0 )); then
    _tk_success "Workspace branch cleanup complete."
  else
    _tk_error \
      "Workspace branch cleanup completed with $((deletion_failures + scan_failures)) failure(s)."
    return 1
  fi
}

typeset -g _WS_AUTOCLEAN_SOURCED=1
