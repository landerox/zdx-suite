#!/usr/bin/env zsh
# =============================================================================
# Git Branches: switch branches and recover unreachable commits
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh and git-stash.zsh.
# Safe to re-source; defines functions only.
#
# git-switch creates a branch only as the local branch that tracks a chosen
# remote-tracking branch, and git-recover only adds a new branch at a commit
# that no ref reaches. Neither moves, resets, or deletes an existing ref.
#

if [[ -n "${_GIT_BRANCH_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Seconds that git-recover --deep gives git fsck to list dangling commits.
typeset -g _GIT_RECOVER_FSCK_SECONDS=60
# Rows that one branch or commit picker lists at most, as completion does.
typeset -g _GIT_BRANCH_LIST_LIMIT=500

# --- Branch records ------------------------------------------------------------

# Succeeds for a name that may be looked up or created as a branch: valid as a
# branch name and as refs/heads/NAME, which also rules out the @{-N} shorthand
# that check-ref-format --branch would expand, and not HEAD.
_git_branch_name_valid() {
  local branch_name="${1-}"
  [[ -n "$branch_name" && "$branch_name" != -* && "$branch_name" != HEAD \
    && "$branch_name" != *[[:cntrl:]]* ]] || return 1
  _git_validate_full_ref "refs/heads/$branch_name" &&
    _git_validate_branch_name "$branch_name"
}

# Fills the caller's _git_branch_heads (branch name -> OID) and
# _git_branch_tracking (refs/remotes/... -> OID) associations from one
# listing. The listing keeps exact letter case, so a lookup cannot match a
# branch that differs only in case on a case-insensitive file system.
# Symbolic refs such as refs/remotes/origin/HEAD are left out.
_git_branch_inventory() {
  emulate -L zsh

  local listing="" branch_record="" ref_name="" object_id="" symbolic_target=""
  _git_branch_heads=()
  _git_branch_tracking=()
  listing=$(command git for-each-ref \
    --format='%(refname)%09%(objectname)%09%(symref)' \
    refs/heads refs/remotes 2>/dev/null) || {
    _git_error "Unable to list branches."
    return 1
  }
  for branch_record in "${(@f)listing}"; do
    [[ -n "$branch_record" ]] || continue
    ref_name="${branch_record%%$'\t'*}"
    branch_record="${branch_record#*$'\t'}"
    object_id="${branch_record%%$'\t'*}"
    symbolic_target="${branch_record#*$'\t'}"
    [[ -z "$symbolic_target" ]] || continue
    _git_validate_oid "$object_id" || {
      _git_error "Git returned an invalid branch record."
      return 1
    }
    case "$ref_name" in
      refs/heads/?*)
        _git_branch_heads[${ref_name#refs/heads/}]="$object_id"
        ;;
      refs/remotes/?*/?*)
        _git_branch_tracking[$ref_name]="$object_id"
        ;;
    esac
  done
  return 0
}

# Sets reply to the configured remote names.
_git_branch_remotes() {
  local remote_output=""
  reply=()
  remote_output=$(command git remote 2>/dev/null) || return 1
  [[ -n "$remote_output" ]] && reply=("${(@f)remote_output}")
  return 0
}

# REPLY: the configured remote that owns refs/remotes/<remote>/<branch>. Remote
# names may contain "/", so the longest matching name wins.
# Usage: _git_branch_remote_of TRACKING_REF REMOTE...
_git_branch_remote_of() {
  emulate -L zsh

  local tracking_ref="$1"
  shift
  local remote_name="" best_match=""
  REPLY=""
  for remote_name in "$@"; do
    [[ -n "$remote_name" && "$tracking_ref" == "refs/remotes/$remote_name/"?* ]] ||
      continue
    (( ${#remote_name} > ${#best_match} )) && best_match="$remote_name"
  done
  [[ -n "$best_match" ]] || return 1
  REPLY="$best_match"
}

# REPLY: "Repository: <name> | Branch: <branch>" for a picker header.
_git_branch_context_line() {
  emulate -L zsh

  local repo_root="" branch_name=""
  repo_root=$(command git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
  branch_name=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) ||
    branch_name="detached"
  REPLY="Repository: ${(V)${repo_root:t}:-unknown} | Branch: ${(V)branch_name}"
}

# --- Switch: targets -------------------------------------------------------------

# A target record is (kind name ref oid remote): an existing local branch is
# (local NAME refs/heads/NAME OID ""), and a branch that exists only as a
# remote-tracking ref is (remote NAME refs/remotes/REMOTE/NAME OID REMOTE).

# Sets reply to the target record for a remote-tracking ref. A local branch of
# the same name is used only when it already points at the same commit; one
# that differs is refused instead of being moved.
# Usage: _git_switch_target_from_tracking TRACKING_REF BRANCH REMOTE
_git_switch_target_from_tracking() {
  emulate -L zsh

  local tracking_ref="$1"
  local branch_name="$2"
  local remote_name="$3"
  local tracking_oid="${_git_branch_tracking[$tracking_ref]-}"
  local tracking_label="${tracking_ref#refs/remotes/}"
  reply=()

  _git_branch_name_valid "$branch_name" || {
    _git_error "${tracking_label} has no valid local branch name."
    return 1
  }
  if (( ${+_git_branch_heads[$branch_name]} )); then
    if [[ "${_git_branch_heads[$branch_name]}" == "$tracking_oid" ]]; then
      _git_info "Local branch $branch_name already matches $tracking_label."
      reply=(local "$branch_name" "refs/heads/$branch_name" "$tracking_oid" "")
      return 0
    fi
    _git_error "Local branch $branch_name already exists and differs from $tracking_label."
    _git_info "Switch to the local branch with: git-switch $branch_name"
    return 1
  fi
  reply=(remote "$branch_name" "$tracking_ref" "$tracking_oid" "$remote_name")
}

# Resolves a BRANCH argument to a target record. A local branch wins; else a
# branch of that name on exactly one remote, or REMOTE/BRANCH for one remote.
_git_switch_resolve_name() {
  emulate -L zsh

  local requested="$1"
  local remote_name="" candidate_ref="" candidate_name="" candidate_record=""
  local -a remote_names=() candidates=()
  reply=()

  if (( ${+_git_branch_heads[$requested]} )); then
    reply=(local "$requested" "refs/heads/$requested"
      "${_git_branch_heads[$requested]}" "")
    return 0
  fi

  _git_branch_remotes || {
    _git_error "Unable to list remotes."
    return 1
  }
  remote_names=("${reply[@]}")
  for remote_name in "${remote_names[@]}"; do
    _git_validate_remote_token "$remote_name" || continue
    candidate_ref="refs/remotes/$remote_name/$requested"
    if (( ${+_git_branch_tracking[$candidate_ref]} )); then
      candidate_record="$candidate_ref"$'\t'"$requested"$'\t'"$remote_name"
      (( ${candidates[(Ie)$candidate_record]} )) ||
        candidates+=("$candidate_record")
    fi
    [[ "$requested" == "$remote_name"/?* ]] || continue
    candidate_name="${requested#$remote_name/}"
    candidate_ref="refs/remotes/$requested"
    [[ "$candidate_name" != HEAD ]] || continue
    if (( ${+_git_branch_tracking[$candidate_ref]} )); then
      candidate_record="$candidate_ref"$'\t'"$candidate_name"$'\t'"$remote_name"
      (( ${candidates[(Ie)$candidate_record]} )) ||
        candidates+=("$candidate_record")
    fi
  done

  if (( ${#candidates[@]} == 0 )); then
    _git_error "No local or remote-tracking branch is named $requested."
    _git_info \
      "git-switch only switches to existing branches; create a new one with git switch -c."
    return 1
  fi
  if (( ${#candidates[@]} > 1 )); then
    _git_error "$requested matches several remote-tracking branches:"
    for candidate_record in "${candidates[@]}"; do
      candidate_ref="${candidate_record%%$'\t'*}"
      _git_dim "${candidate_ref#refs/remotes/}"
    done
    _git_info "Name one of them as REMOTE/BRANCH."
    return 1
  fi

  candidate_ref="${candidates[1]%%$'\t'*}"
  candidate_record="${candidates[1]#*$'\t'}"
  candidate_name="${candidate_record%%$'\t'*}"
  remote_name="${candidate_record#*$'\t'}"
  _git_switch_target_from_tracking \
    "$candidate_ref" "$candidate_name" "$remote_name"
}

# Resolves "-" to the branch checked out before the current one.
_git_switch_resolve_previous() {
  emulate -L zsh

  local previous_ref=""
  reply=()
  previous_ref=$(command git rev-parse --symbolic-full-name '@{-1}' \
    2>/dev/null) || previous_ref=""
  if [[ "$previous_ref" != refs/heads/?* ]]; then
    _git_error "The previous checkout is not an existing branch."
    return 1
  fi
  local branch_name="${previous_ref#refs/heads/}"
  (( ${+_git_branch_heads[$branch_name]} )) || {
    _git_error "The previous branch $branch_name no longer exists."
    return 1
  }
  reply=(local "$branch_name" "$previous_ref"
    "${_git_branch_heads[$branch_name]}" "")
}

# Opens the branch picker: local branches first, then branches that exist only
# on a remote, each newest first with its last-commit date and upstream facts.
# Sets reply to the selected target record, or leaves it empty after a
# cancellation. Usage: _git_switch_pick CURRENT_REF CONTEXT_TEXT
_git_switch_pick() {
  emulate -L zsh

  local current_ref="$1"
  local context_text="$2"
  local listing="" branch_record="" ref_name="" object_id="" commit_age=""
  local upstream_name="" track_text="" symbolic_target="" fact_text=""
  local branch_name="" remote_name="" display_name=""
  local -a remote_names=() row_kinds=() row_names=() row_refs=()
  local -a row_oids=() row_remotes=() row_labels=() row_facts=()
  local -i name_width=0 row_index=0 padding=0
  local REPLY=""

  _git_branch_remotes || {
    _git_error "Unable to list remotes."
    return 1
  }
  remote_names=("${reply[@]}")
  reply=()

  listing=$(command git for-each-ref \
    --count="$_GIT_BRANCH_LIST_LIMIT" --sort=-committerdate \
    --format='%(refname)%09%(objectname)%09%(committerdate:relative)%09%(upstream:short)%09%(upstream:track,nobracket)%09%(symref)' \
    refs/heads 2>/dev/null) || {
    _git_error "Unable to list local branches."
    return 1
  }
  for branch_record in "${(@f)listing}"; do
    [[ -n "$branch_record" ]] || continue
    local -a record_fields=("${(@ps:\t:)branch_record}")
    ref_name="${record_fields[1]}"
    object_id="${record_fields[2]}"
    commit_age="${record_fields[3]-}"
    upstream_name="${record_fields[4]-}"
    track_text="${record_fields[5]-}"
    symbolic_target="${record_fields[6]-}"
    [[ -z "$symbolic_target" && "$ref_name" == refs/heads/?* \
      && "$ref_name" != "$current_ref" ]] || continue
    _git_validate_oid "$object_id" || continue
    if [[ -z "$upstream_name" ]]; then
      fact_text="no upstream"
    elif [[ -z "$track_text" ]]; then
      fact_text="$upstream_name, in sync"
    else
      fact_text="$upstream_name, $track_text"
    fi
    row_kinds+=(local)
    row_names+=("${ref_name#refs/heads/}")
    row_refs+=("$ref_name")
    row_oids+=("$object_id")
    row_remotes+=("")
    row_labels+=("${ref_name#refs/heads/}")
    row_facts+=("$commit_age  $fact_text")
  done

  listing=$(command git for-each-ref \
    --count="$_GIT_BRANCH_LIST_LIMIT" --sort=-committerdate \
    --format='%(refname)%09%(objectname)%09%(committerdate:relative)%09%(symref)' \
    refs/remotes 2>/dev/null) || {
    _git_error "Unable to list remote-tracking branches."
    return 1
  }
  for branch_record in "${(@f)listing}"; do
    [[ -n "$branch_record" ]] || continue
    local -a record_fields=("${(@ps:\t:)branch_record}")
    ref_name="${record_fields[1]}"
    object_id="${record_fields[2]}"
    commit_age="${record_fields[3]-}"
    symbolic_target="${record_fields[4]-}"
    [[ -z "$symbolic_target" ]] || continue
    _git_validate_oid "$object_id" || continue
    _git_branch_remote_of "$ref_name" "${remote_names[@]}" || continue
    remote_name="$REPLY"
    branch_name="${ref_name#refs/remotes/$remote_name/}"
    # A branch that exists locally is already listed as that local branch.
    [[ "$branch_name" != HEAD ]] || continue
    (( ${+_git_branch_heads[$branch_name]} )) && continue
    row_kinds+=(remote)
    row_names+=("$branch_name")
    row_refs+=("$ref_name")
    row_oids+=("$object_id")
    row_remotes+=("$remote_name")
    row_labels+=("${ref_name#refs/remotes/}")
    row_facts+=("$commit_age  remote only; creates local $branch_name")
  done

  if (( ${#row_kinds[@]} == 0 )); then
    _git_info "There is no other branch to switch to."
    return 0
  fi

  for display_name in "${row_labels[@]}"; do
    (( ${(m)#display_name} > name_width )) && name_width=${(m)#display_name}
  done
  (( name_width > 40 )) && name_width=40

  local -a picker_rows=()
  for (( row_index = 1; row_index <= ${#row_kinds[@]}; row_index++ )); do
    display_name="${(V)row_labels[row_index]}"
    padding=$(( name_width - ${(m)#display_name} ))
    (( padding < 0 )) && padding=0
    picker_rows+=(
      "$row_index"$'\t'"${row_kinds[row_index]}"$'\t'"${row_oids[row_index]}"$'\t'"${display_name}${(l:padding:: :)}  ${(V)row_facts[row_index]//$'\t'/ }"
    )
  done

  local color_mode="never"
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]] && color_mode="always"
  # A constant read-only preview: fzf quotes the object ID field, and only a
  # hexadecimal value reaches git log.
  local preview_program='oid={3}; case "$oid" in *[!0-9a-f]*|"") ;; *)'
  preview_program+=" git --no-optional-locks --no-pager log --no-show-signature --color=${color_mode} --date=short --format='%C(auto)%h %ad %an%n    %s' -n 20 \"\$oid\" -- ;; esac"
  local -a picker_options=(
    "--preview=${preview_program}"
    --height=80%
    '--preview-window=right:50%:wrap,<120(down:8:wrap)'
    '--bind=ctrl-/:toggle-preview'
  )
  local header_text="$context_text"
  header_text+=$'\n''Type to filter | Enter switch | Esc cancel | Ctrl-/ details'

  _git_select_ids "git switch" "$header_text" 4 no \
    picker_rows picker_options || return 1
  local -a selected_ids=("${reply[@]}")
  reply=()
  (( ${#selected_ids[@]} == 1 )) || return 0
  row_index="${selected_ids[1]}"
  reply=(
    "${row_kinds[row_index]}"
    "${row_names[row_index]}"
    "${row_refs[row_index]}"
    "${row_oids[row_index]}"
    "${row_remotes[row_index]}"
  )
}

# REPLY: the path of another worktree that has REF checked out, or empty.
# Usage: _git_switch_worktree_holder REF CURRENT_ROOT
_git_switch_worktree_holder() {
  emulate -L zsh

  local wanted_ref="$1"
  local current_root="${2:A}"
  local listing="" listing_line="" worktree_path=""
  REPLY=""
  listing=$(command git worktree list --porcelain 2>/dev/null) || return 1
  for listing_line in "${(@f)listing}"; do
    case "$listing_line" in
      "worktree "*)
        worktree_path="${listing_line#worktree }"
        ;;
      "branch "*)
        if [[ "${listing_line#branch }" == "$wanted_ref" \
          && "${worktree_path:A}" != "$current_root" ]]; then
          REPLY="$worktree_path"
          return 0
        fi
        ;;
    esac
  done
  return 0
}

# --- Switch: working-tree state --------------------------------------------------

# Sets reply to the (staged unstaged conflicted) path counts and the caller's
# _git_switch_changed array to each tracked path with a staged or unstaged
# change. Changes inside a submodule's own worktree are not counted: neither a
# switch nor a stash touches them.
_git_switch_tracked_changes() {
  emulate -L zsh

  local -a status_records=()
  local status_record=""
  local -i staged_count=0 unstaged_count=0 conflicted_count=0
  _git_switch_changed=()
  _git_capture_nul status --porcelain=v2 -z --untracked-files=no \
    --no-renames --ignore-submodules=dirty || return 1
  status_records=("${reply[@]}")
  for status_record in "${status_records[@]}"; do
    case "${status_record[1]}" in
      1)
        [[ "${status_record[3]}" != "." ]] && (( staged_count++ ))
        [[ "${status_record[4]}" != "." ]] && (( unstaged_count++ ))
        _git_switch_changed+=("${status_record#* * * * * * * * }")
        ;;
      u)
        (( conflicted_count++ ))
        _git_switch_changed+=("${status_record#* * * * * * * * * * }")
        ;;
    esac
  done
  reply=("$staged_count" "$unstaged_count" "$conflicted_count")
}

# Sets reply to the paths whose content differs between HEAD_OID and
# TARGET_OID, or every path of the target when HEAD is unborn.
# Usage: _git_switch_diff_paths ROOT HEAD_OID TARGET_OID
_git_switch_diff_paths() {
  emulate -L zsh

  local repo_root="$1"
  local head_oid="$2"
  local target_oid="$3"
  reply=()
  [[ "$head_oid" != "$target_oid" ]] || return 0
  if [[ -z "$head_oid" ]]; then
    _git_capture_nul -C "$repo_root" ls-tree -r -z --name-only "$target_oid"
  else
    _git_capture_nul -C "$repo_root" diff-tree -r -z --name-only \
      --no-renames "$head_oid" "$target_oid"
  fi
}

# Sets reply to the untracked or ignored paths that switching would overwrite,
# remove, or be blocked by. Git silently replaces ignored files on checkout, so
# they count as well. An untracked or ignored directory is listed once rather
# than walked, and a target path inside it blocks only when something already
# exists on its way. Usage: _git_switch_obstacles ROOT TARGET_PATHS_NAME
_git_switch_obstacles() {
  emulate -L zsh

  local repo_root="$1"
  local -a target_paths=("${(@P)2}")
  local -a candidate_paths=() obstacle_paths=()
  local -A candidate_kinds=() candidate_names=() target_keys=()
  local fold_case="no" candidate_path="" candidate_key="" target_path=""
  local target_key="" path_prefix="" key_prefix="" path_part="" walk_path=""
  local -a path_parts=()
  local -i part_index=0 walk_index=0
  reply=()
  (( ${#target_paths[@]} > 0 )) || return 0

  _git_capture_nul -C "$repo_root" \
    ls-files --others --exclude-standard --directory -z -- || return 1
  candidate_paths=("${reply[@]}")
  _git_capture_nul -C "$repo_root" \
    ls-files --others --ignored --exclude-standard --directory -z -- || return 1
  candidate_paths+=("${reply[@]}")
  reply=()
  (( ${#candidate_paths[@]} > 0 )) || return 0
  _git_ignorecase_enabled && fold_case="yes"

  for candidate_path in "${candidate_paths[@]}"; do
    candidate_key="${candidate_path%/}"
    [[ -n "$candidate_key" ]] || continue
    [[ "$fold_case" == "yes" ]] && candidate_key="${(L)candidate_key}"
    if [[ "$candidate_path" == */ ]]; then
      candidate_kinds[$candidate_key]="directory"
    else
      candidate_kinds[$candidate_key]="file"
    fi
    candidate_names[$candidate_key]="${candidate_path%/}"
  done
  for target_path in "${target_paths[@]}"; do
    target_key="$target_path"
    [[ "$fold_case" == "yes" ]] && target_key="${(L)target_key}"
    target_keys[$target_key]=1
  done

  # A target path that is, or lies below, an untracked or ignored entry.
  for target_path in "${target_paths[@]}"; do
    path_parts=("${(@s:/:)target_path}")
    path_prefix=""
    for (( part_index = 1; part_index <= ${#path_parts[@]}; part_index++ )); do
      path_prefix+="${path_prefix:+/}${path_parts[part_index]}"
      key_prefix="$path_prefix"
      [[ "$fold_case" == "yes" ]] && key_prefix="${(L)key_prefix}"
      (( ${+candidate_kinds[$key_prefix]} )) || continue
      if (( part_index == ${#path_parts[@]} )) \
        || [[ "${candidate_kinds[$key_prefix]}" == "file" ]]; then
        obstacle_paths+=("${candidate_names[$key_prefix]}")
        break
      fi
      # Git creates the target inside the directory; only an existing file,
      # link, or the target itself on the way would be replaced.
      walk_path="$path_prefix"
      for (( walk_index = part_index + 1; walk_index <= ${#path_parts[@]}; walk_index++ )); do
        walk_path+="/${path_parts[walk_index]}"
        if [[ -L "$repo_root/$walk_path" ]] \
          || { [[ -e "$repo_root/$walk_path" ]] \
            && { (( walk_index == ${#path_parts[@]} )) \
              || [[ ! -d "$repo_root/$walk_path" ]]; }; }; then
          obstacle_paths+=("$walk_path")
          break
        fi
      done
      break
    done
  done

  # An untracked or ignored entry inside a path that becomes a file.
  for candidate_path in "${candidate_paths[@]}"; do
    candidate_key="${candidate_path%/}"
    [[ "$fold_case" == "yes" ]] && candidate_key="${(L)candidate_key}"
    path_parts=("${(@s:/:)candidate_key}")
    key_prefix=""
    for (( part_index = 1; part_index < ${#path_parts[@]}; part_index++ )); do
      key_prefix+="${key_prefix:+/}${path_parts[part_index]}"
      if (( ${+target_keys[$key_prefix]} )); then
        obstacle_paths+=("${candidate_path%/}")
        break
      fi
    done
  done

  reply=("${(@u)obstacle_paths}")
}

# --- Switch: plan and execution ---------------------------------------------------

_git_switch_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- \
    "  git-switch [BRANCH|-] [--stash|--carry] [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-switch --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Switch to an existing local branch, to the previous branch (-), or to a branch"
  print -u2 -r -- \
    "that exists only as a remote-tracking ref, which creates just the local branch"
  print -u2 -r -- \
    "of that name tracking it. REMOTE/BRANCH chooses one remote. Without BRANCH,"
  print -u2 -r -- \
    "choose in a picker: local branches first, then branches only on a remote."
  print -u2 -r -- \
    "A clean working tree switches at once. Uncommitted tracked changes need a"
  print -u2 -r -- \
    "reviewed plan and a choice: carry them, or stash them first."
  print -u2 -r -- \
    "  --carry    Keep the changes; refused when the target branch changes those files."
  print -u2 -r -- \
    "  --stash    First stash them as 'zdx git-switch: <from> -> <to>'."
  print -u2 -r -- \
    "  --dry-run  Show the exact plan without changing anything."
  print -u2 -r -- \
    "  -y, --yes  Bypass only the confirmation of a plan with changes."
  print -u2 -r -- \
    "A merge, rebase, cherry-pick, revert, or bisect in progress refuses the switch."
}

# Revalidates a reviewed switch after its authorization: the repository,
# HEAD, index and working tree, stash list, the target ref, the worktree that
# holds the target, and the untracked and ignored obstacles.
# Usage: _git_switch_revalidate SNAPSHOT_NAME TARGET_NAME ROOT HEAD_OID
_git_switch_revalidate() {
  emulate -L zsh

  local snapshot_name="$1"
  local -a target=("${(@P)2}")
  local repo_root="$3"
  local head_oid="$4"
  local -A _git_branch_heads=() _git_branch_tracking=()
  local -a reply=()
  local REPLY=""

  _git_stash_context_matches "$snapshot_name" tracked "" yes || return 1
  _git_branch_inventory || return 1
  if [[ "${target[1]}" == "local" ]]; then
    [[ "${_git_branch_heads[${target[2]}]-}" == "${target[4]}" ]] || return 1
    _git_switch_worktree_holder "${target[3]}" "$repo_root" || return 1
    [[ -z "$REPLY" ]] || return 1
  else
    [[ "${_git_branch_tracking[${target[3]}]-}" == "${target[4]}" ]] || return 1
    (( ! ${+_git_branch_heads[${target[2]}]} )) || return 1
  fi
  _git_switch_diff_paths "$repo_root" "$head_oid" "${target[4]}" || return 1
  local -a target_paths=("${reply[@]}")
  _git_switch_obstacles "$repo_root" target_paths || return 1
  (( ${#reply[@]} == 0 ))
}

# Runs a reviewed switch. CHANGE_MODE "stash" saves the tracked changes first
# under STASH_MESSAGE; every step is verified before the next one starts.
# Usage: _git_switch_execute TARGET_NAME FROM_LABEL CHANGE_MODE STASH_MESSAGE
#   CHANGED_COUNT
_git_switch_execute() {
  emulate -L zsh

  local -a target=("${(@P)1}")
  local from_label="$2"
  local change_mode="$3"
  local stash_message="$4"
  local -i changed_count="$5"
  local target_kind="${target[1]}" target_name="${target[2]}"
  local target_ref="${target[3]}" target_oid="${target[4]}"
  local stash_oid="" REPLY=""
  local -a reply=()
  local -i command_code=0

  _git_blank
  if [[ "$change_mode" == "stash" ]] && (( changed_count > 0 )); then
    _git_stash_inventory_summary || return 1
    local -a inventory_before=("${reply[@]}")
    _git_run_captured "git stash push -m ${(qq)stash_message}" \
      command git stash push --quiet -m "$stash_message"
    command_code=$?
    _git_stash_inventory_summary || return 1
    local -a inventory_after=("${reply[@]}")
    local newest_subject=""
    newest_subject=$(command git log -g -1 --format='%gs' refs/stash -- \
      2>/dev/null) || newest_subject=""
    local -a _git_switch_changed=()
    _git_switch_tracked_changes || return 1
    local -a changes_after=("${reply[@]}")
    if (( command_code != 0 \
      || inventory_after[2] != inventory_before[2] + 1 )) \
      || [[ "${inventory_after[3]}" == "NONE" \
        || "${inventory_after[3]}" == "${inventory_before[3]}" \
        || "$newest_subject" != *": $stash_message" ]] \
      || (( changes_after[1] + changes_after[2] + changes_after[3] > 0 )); then
      _git_outcome_line "Stash the changes" failed "exit $command_code"
      if (( inventory_after[2] > inventory_before[2] )); then
        _git_warn "A new stash exists: ${inventory_after[3]}"
      fi
      _git_error "Stashing did not reach the expected state; nothing was switched."
      (( command_code == 0 )) && return 1
      return "$command_code"
    fi
    stash_oid="${inventory_after[3]}"
    _git_outcome_line "Stash the changes" done "stash@{0} ${stash_oid[1,12]}"
  fi

  if [[ "$target_kind" == "remote" ]]; then
    _git_run_captured "git switch -c $target_name ${target_oid[1,12]}" \
      command git switch --no-guess --no-track -c "$target_name" "$target_oid"
  else
    _git_run_captured "git switch $target_name" \
      command git switch --no-guess "$target_name"
  fi
  command_code=$?

  local current_ref="" current_oid=""
  current_ref=$(command git symbolic-ref -q HEAD 2>/dev/null) || current_ref=""
  current_oid=$(command git rev-parse --verify --quiet 'HEAD^{commit}' \
    2>/dev/null) || current_oid=""
  local switch_label="Switch to $target_name"
  [[ "$target_kind" == "remote" ]] &&
    switch_label="Create $target_name at ${target_oid[1,12]} and switch to it"
  if (( command_code != 0 )) \
    || [[ "$current_ref" != "refs/heads/$target_name" \
      || "$current_oid" != "$target_oid" ]]; then
    _git_outcome_line "$switch_label" failed "exit $command_code"
    if [[ "$current_ref" == refs/heads/?* ]]; then
      _git_error "The switch did not reach the reviewed state; HEAD is on ${current_ref#refs/heads/}."
    else
      _git_error "The switch did not reach the reviewed state; HEAD is detached."
    fi
    if [[ -n "$stash_oid" ]]; then
      _git_warn "The stashed changes are kept as ${stash_oid[1,12]}."
      _git_info "Restore them here with: git-stash pop $stash_oid"
    fi
    (( command_code == 0 )) && return 1
    return "$command_code"
  fi
  _git_outcome_line "$switch_label" done

  if [[ "$target_kind" == "remote" ]]; then
    local tracking_label="${target_ref#refs/remotes/}"
    _git_run_captured "git branch --set-upstream-to=$tracking_label $target_name" \
      command git branch "--set-upstream-to=$target_ref" "$target_name"
    command_code=$?
    local upstream_ref=""
    upstream_ref=$(command git for-each-ref --format='%(upstream)' \
      "refs/heads/$target_name" 2>/dev/null) || upstream_ref=""
    if (( command_code != 0 )) || [[ "$upstream_ref" != "$target_ref" ]]; then
      _git_outcome_line "Track $tracking_label" failed "exit $command_code"
      _git_error "Switched to $target_name, but it does not track $tracking_label."
      _git_info "Set it with: git branch --set-upstream-to=$tracking_label $target_name"
      _git_mark_partial
      return 1
    fi
    _git_outcome_line "Track $tracking_label" done
  fi

  if [[ -n "$stash_oid" ]]; then
    _git_success "Switched to $target_name from $from_label; the changes are in stash@{0}."
    _git_info "Restore them with: git-stash pop $stash_oid"
  elif (( changed_count > 0 )); then
    _git_count_noun "$changed_count" "changed file"
    _git_success "Switched to $target_name from $from_label, carrying $REPLY."
  else
    _git_success "Switched to $target_name from $from_label."
  fi
}

git-switch() {
  emulate -L zsh

  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _git_switch_usage
    return 0
  fi

  local requested="" change_mode="" dry_run="no" assume_yes="no"
  local -i target_given=0
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        _git_error "--help does not accept additional arguments."
        return 2
        ;;
      --stash|--carry)
        if [[ -n "$change_mode" ]]; then
          if [[ "$change_mode" == "${1#--}" ]]; then
            _git_error "Duplicate option: $1"
          else
            _git_error "--stash and --carry cannot be combined."
          fi
          return 2
        fi
        change_mode="${1#--}"
        ;;
      --dry-run)
        [[ "$dry_run" == "no" ]] || {
          _git_error "Duplicate option: --dry-run"
          return 2
        }
        dry_run="yes"
        ;;
      -y|--yes)
        [[ "$assume_yes" == "no" ]] || {
          _git_error "Duplicate option: --yes"
          return 2
        }
        assume_yes="yes"
        ;;
      -)
        (( ! target_given )) || {
          _git_error "git-switch accepts at most one BRANCH."
          return 2
        }
        requested="-"
        target_given=1
        ;;
      -*)
        _git_error "Unknown option for git-switch: $1"
        return 2
        ;;
      *)
        (( ! target_given )) || {
          _git_error "git-switch accepts at most one BRANCH."
          return 2
        }
        requested="$1"
        target_given=1
        ;;
    esac
    shift
  done
  [[ "$dry_run" == "yes" && "$assume_yes" == "yes" ]] && {
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  }
  if (( target_given )) && [[ "$requested" != "-" ]]; then
    _git_branch_name_valid "$requested" || {
      _git_error "Invalid branch name: ${(V)requested}"
      return 2
    }
  fi

  _git_require_repo || return 1
  local repo_root="" git_dir="" REPLY=""
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
  repo_root="${repo_root:A}"
  _git_operation_in_progress "$git_dir"
  if [[ -n "$REPLY" ]]; then
    _git_error "A $REPLY is in progress; finish or abort it before switching branches."
    return 1
  fi

  local head_ref="" head_oid="" from_label=""
  head_ref=$(command git symbolic-ref -q HEAD 2>/dev/null) || head_ref=""
  head_oid=$(command git rev-parse --verify --quiet 'HEAD^{commit}' \
    2>/dev/null) || head_oid=""
  if [[ "$head_ref" == refs/heads/?* ]]; then
    from_label="${head_ref#refs/heads/}"
  elif [[ -n "$head_oid" ]]; then
    from_label="detached HEAD ${head_oid[1,12]}"
  else
    from_label="detached HEAD"
  fi

  local -A _git_branch_heads=() _git_branch_tracking=()
  _git_branch_inventory || return 1

  local -a _git_switch_changed=()
  _git_switch_tracked_changes || {
    _git_error "Unable to inspect local changes."
    return 1
  }
  local -i staged_count="${reply[1]}" unstaged_count="${reply[2]}"
  local -i conflicted_count="${reply[3]}"
  local -a changed_paths=("${(@u)_git_switch_changed}")
  local -i changed_count=${#changed_paths[@]}
  if (( conflicted_count > 0 )); then
    _git_count_noun "$conflicted_count" "conflicted file"
    _git_error "Resolve the $REPLY before switching branches."
    return 1
  fi

  local -a target=()
  if (( ! target_given )); then
    _git_require_interactive || return 1
    _git_branch_context_line
    local picker_context="$REPLY | Changes: $changed_count"
    _git_switch_pick "$head_ref" "$picker_context" || return $?
    target=("${reply[@]}")
    (( ${#target[@]} == 5 )) || return 0
  elif [[ "$requested" == "-" ]]; then
    _git_switch_resolve_previous || return 1
    target=("${reply[@]}")
  else
    _git_switch_resolve_name "$requested" || return 1
    target=("${reply[@]}")
  fi
  local target_kind="${target[1]}" target_name="${target[2]}"
  local target_ref="${target[3]}" target_oid="${target[4]}"
  _git_validate_oid "$target_oid" || {
    _git_error "The target branch does not point at a valid commit."
    return 1
  }

  if [[ "$target_kind" == "local" && "$target_ref" == "$head_ref" ]]; then
    _git_info "Already on $target_name; nothing to switch."
    return 0
  fi
  if [[ "$target_kind" == "local" ]]; then
    _git_switch_worktree_holder "$target_ref" "$repo_root" || {
      _git_error "Unable to inspect linked worktrees."
      return 1
    }
    if [[ -n "$REPLY" ]]; then
      _git_error "$target_name is checked out in another worktree: ${(V)REPLY}"
      _git_info "Switch to another branch there first, or work in that worktree."
      return 1
    fi
  else
    local -a planned_refs=("refs/heads/$target_name")
    _git_ref_case_guard planned_refs refs/heads \
      "Rename or delete the local branch that differs only in letter case." ||
      return 1
  fi

  _git_switch_diff_paths "$repo_root" "$head_oid" "$target_oid" || {
    _git_error "Unable to compare the current and target commits."
    return 1
  }
  local -a target_paths=("${reply[@]}")
  _git_switch_obstacles "$repo_root" target_paths || {
    _git_error "Unable to inspect untracked and ignored paths."
    return 1
  }
  local -a obstacle_paths=("${reply[@]}")
  if (( ${#obstacle_paths[@]} > 0 )); then
    local obstacle_path=""
    _git_warn "Switching to $target_name would overwrite or remove these untracked or ignored paths:"
    for obstacle_path in "${obstacle_paths[@]}"; do
      _git_dim "${(V)obstacle_path}"
    done
    _git_error "Refusing to switch; move or remove these paths first."
    return 1
  fi

  local carry_possible="yes" stash_possible="yes"
  local -a carry_blockers=()
  if (( changed_count > 0 )); then
    local fold_case="no"
    _git_ignorecase_enabled && fold_case="yes"
    _git_path_collisions changed_paths target_paths "$fold_case"
    carry_blockers=("${reply[@]}")
    (( ${#carry_blockers[@]} == 0 )) || carry_possible="no"
    [[ -n "$head_oid" ]] || stash_possible="no"
  fi

  # The plan binds HEAD, the index and working tree, and the stash list.
  local -a snapshot=()
  if (( changed_count > 0 )); then
    _git_stash_context_capture tracked || {
      _git_error "Unable to capture repository state."
      return 1
    }
    snapshot=("${reply[@]}")
  fi

  local target_subject=""
  target_subject=$(command git log -1 --no-show-signature --format='%s' \
    "$target_oid" -- 2>/dev/null) || target_subject=""
  local tracking_label="${target_ref#refs/remotes/}"
  local stash_message="zdx git-switch: $from_label -> $target_name"

  _git_ui_heading "Switch Branch"
  _git_ui_label "Repository" "${repo_root:t}"
  _git_ui_label "From" "$from_label"
  if [[ "$target_kind" == "remote" ]]; then
    _git_ui_label "To" "$target_name (new local branch tracking $tracking_label)"
  else
    _git_ui_label "To" "$target_name"
  fi
  _git_ui_label "Target commit" "${target_oid[1,12]}${target_subject:+ $target_subject}"
  if (( changed_count > 0 )); then
    _git_count_noun "$staged_count" file
    _git_ui_label "Staged" "$REPLY"
    _git_count_noun "$unstaged_count" file
    _git_ui_label "Unstaged" "$REPLY"
    local -a save_pairs=()
    _git_stash_collect_save_pairs tracked || return 1
    save_pairs=("${reply[@]}")
    _git_stash_show_pairs_table save_pairs
  fi

  _git_count_noun "$changed_count" "changed file"
  local changed_label="$REPLY"
  if (( changed_count > 0 )); then
    if [[ "$carry_possible" == "no" ]]; then
      local blocker_path=""
      _git_warn "Carrying is not possible: $target_name also changes these files:"
      for blocker_path in "${carry_blockers[@]}"; do
        _git_dim "${(V)blocker_path}"
      done
    fi
    [[ "$stash_possible" == "yes" ]] ||
      _git_warn "Stashing is not possible: the current branch has no commit yet."
    if [[ "$carry_possible" == "no" && "$stash_possible" == "no" ]]; then
      _git_error "Refusing to switch: the changes can be neither carried nor stashed."
      return 1
    fi
    if [[ "$change_mode" == "carry" && "$carry_possible" == "no" ]]; then
      _git_error "Refusing to carry changes that $target_name would overwrite; use --stash."
      return 1
    fi
    if [[ "$change_mode" == "stash" && "$stash_possible" == "no" ]]; then
      _git_error "Refusing to stash without a commit; commit first or use --carry."
      return 1
    fi
  fi

  local -a step_rows=()
  local -i step_count=0
  if (( changed_count > 0 )) && [[ -z "$change_mode" ]]; then
    local -a choice_rows=()
    [[ "$carry_possible" == "yes" ]] &&
      choice_rows+=("carry"$'\t'"keep the $changed_label in the working tree on $target_name")
    [[ "$stash_possible" == "yes" ]] &&
      choice_rows+=("stash"$'\t'"save them as '${stash_message}', then switch")
    _git_blank
    _git_table $'Choice\tEffect' "${choice_rows[@]}"
  else
    if [[ "$change_mode" == "stash" ]] && (( changed_count > 0 )); then
      (( step_count++ ))
      step_rows+=("$step_count"$'\t'"Stash the $changed_label as '${stash_message}'")
    fi
    local carry_text=""
    [[ "$change_mode" == "carry" ]] && (( changed_count > 0 )) &&
      carry_text=", carrying the $changed_label"
    (( step_count++ ))
    if [[ "$target_kind" == "remote" ]]; then
      step_rows+=("$step_count"$'\t'"Create $target_name at ${target_oid[1,12]} and switch to it$carry_text")
      (( step_count++ ))
      step_rows+=("$step_count"$'\t'"Track $tracking_label")
    else
      step_rows+=("$step_count"$'\t'"Switch to $target_name$carry_text")
    fi
    if (( step_count > 1 || changed_count > 0 )); then
      _git_blank
      _git_table $'#\tStep' "${step_rows[@]}"
    fi
  fi

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: 1 branch switch planned; nothing was changed."
    return 0
  fi

  if (( changed_count == 0 )); then
    # A clean switch is reversible and runs without a question; the target ref
    # must still be the reviewed one.
    local -A _git_branch_heads=() _git_branch_tracking=()
    _git_branch_inventory || return 1
    if [[ "$target_kind" == "local" ]]; then
      [[ "${_git_branch_heads[$target_name]-}" == "$target_oid" ]]
    else
      [[ "${_git_branch_tracking[$target_ref]-}" == "$target_oid" \
        && -z "${_git_branch_heads[$target_name]-}" ]]
    fi || {
      _git_error "$target_name changed after review; nothing was switched."
      return 1
    }
    _git_switch_execute target "$from_label" "" "" 0
    return
  fi

  if [[ -z "$change_mode" ]]; then
    if [[ "$assume_yes" == "yes" ]]; then
      _git_error "--yes needs --carry or --stash when the working tree has changes."
      return 1
    fi
    if ! _git_require_interactive 2>/dev/null; then
      _git_error \
        "Choosing how to keep the changes needs a terminal and fzf; pass --carry or --stash, then --yes after reviewing the plan."
      return 1
    fi
    local -a action_rows=()
    [[ "$carry_possible" == "yes" ]] && action_rows+=(
      "Carry Changes"$'\t'"carry"$'\t'"Switch to $target_name and keep the $changed_label in the working tree."
    )
    [[ "$stash_possible" == "yes" ]] && action_rows+=(
      "Stash Changes and Switch"$'\t'"stash"$'\t'"Save the $changed_label as a stash, then switch with a clean working tree."
    )
    action_rows+=(
      "Cancel"$'\t'"cancel"$'\t'"Stay on $from_label; nothing changes."
    )
    _git_select_action "git switch" \
      "Branch: $from_label -> $target_name | Changes: $changed_count" \
      "${action_rows[@]}" || return $?
    case "$REPLY" in
      carry|stash)
        change_mode="$REPLY"
        ;;
      *)
        _git_info "Cancelled: nothing was switched."
        return 0
        ;;
    esac
  else
    local question=""
    if [[ "$change_mode" == "stash" ]]; then
      question="Stash the $changed_label and switch to $target_name?"
    else
      question="Switch to $target_name and carry the $changed_label?"
    fi
    _git_confirm_plan "$assume_yes" "$question" \
      "Cancelled: nothing was switched." || return 1
    [[ "$REPLY" == "cancelled" ]] && return 0
  fi

  _git_switch_revalidate snapshot target "$repo_root" "$head_oid" || {
    _git_error "Repository state changed after review; nothing was switched."
    return 1
  }
  _git_switch_execute target "$from_label" "$change_mode" "$stash_message" \
    "$changed_count"
}

# --- Recover: candidates ---------------------------------------------------------

# Sets reply to flat (oid source) pairs: commits named by the HEAD and local
# branch reflogs that no branch, remote-tracking ref, or tag reaches, newest
# first, then with DEEP "yes" the dangling commits a bounded git fsck lists.
# Each commit appears once, and at most _GIT_BRANCH_LIST_LIMIT pairs are kept.
_git_recover_candidates() {
  emulate -L zsh

  local deep="$1"
  local listing="" reflog_record="" object_id="" reflog_selector=""
  local -a reflog_refs=(HEAD) ordered_oids=() candidate_pairs=()
  local -A reflog_sources=() unreachable_oids=()

  listing=$(command git for-each-ref --count="$_GIT_BRANCH_LIST_LIMIT" \
    --format='%(refname)' refs/heads 2>/dev/null) || {
    _git_error "Unable to list local branches."
    return 1
  }
  [[ -n "$listing" ]] && reflog_refs+=("${(@f)listing}")

  # One walk reads every reflog; a ref without a reflog contributes nothing.
  listing=$(command git log --walk-reflogs --no-show-signature \
    --format='%H%x09%gd' "${reflog_refs[@]}" -- 2>/dev/null) || listing=""
  for reflog_record in "${(@f)listing}"; do
    object_id="${reflog_record%%$'\t'*}"
    reflog_selector="${reflog_record#*$'\t'}"
    _git_validate_oid "$object_id" || continue
    (( ${+reflog_sources[$object_id]} )) && continue
    reflog_sources[$object_id]="$reflog_selector"
    ordered_oids+=("$object_id")
  done

  if (( ${#ordered_oids[@]} > 0 )); then
    listing=$(print -rl -- "${ordered_oids[@]}" |
      command git rev-list --stdin --not --branches --tags --remotes \
        2>/dev/null) || {
      _git_error "Unable to compute which reflog commits are unreachable."
      return 1
    }
    for object_id in "${(@f)listing}"; do
      [[ -n "$object_id" ]] && unreachable_oids[$object_id]=1
    done
    for object_id in "${ordered_oids[@]}"; do
      (( ${+unreachable_oids[$object_id]} )) || continue
      candidate_pairs+=("$object_id" "${reflog_sources[$object_id]}")
    done
  fi

  if [[ "$deep" == "yes" ]]; then
    local fsck_output="" fsck_line=""
    local -i fsck_code=0
    _git_info "Searching for dangling commits (git fsck, up to ${_GIT_RECOVER_FSCK_SECONDS}s)..."
    fsck_output=$(_git_run_with_timeout "$_GIT_RECOVER_FSCK_SECONDS" \
      git fsck --connectivity-only --no-progress </dev/null 2>/dev/null) ||
      fsck_code=$?
    if (( fsck_code == 124 )); then
      _git_warn "git fsck did not finish within ${_GIT_RECOVER_FSCK_SECONDS}s; dangling commits may be missing."
    elif (( fsck_code != 0 )); then
      _git_warn "git fsck reported problems (exit $fsck_code); dangling commits may be missing."
    fi
    for fsck_line in "${(@f)fsck_output}"; do
      [[ "$fsck_line" == "dangling commit "* ]] || continue
      object_id="${fsck_line#dangling commit }"
      _git_validate_oid "$object_id" || continue
      (( ${+reflog_sources[$object_id]} )) && continue
      reflog_sources[$object_id]="dangling commit"
      candidate_pairs+=("$object_id" "dangling commit")
    done
  fi

  local -i pair_limit=$(( _GIT_BRANCH_LIST_LIMIT * 2 ))
  (( ${#candidate_pairs[@]} > pair_limit )) &&
    candidate_pairs=("${(@)candidate_pairs[1,pair_limit]}")
  reply=("${candidate_pairs[@]}")
}

# Sets reply to flat (date author subject) fields for each OID, in order.
_git_recover_commit_fields() {
  emulate -L zsh

  local -a object_ids=("$@") log_fields=() commit_fields=()
  local -i field_index=0
  reply=()
  (( ${#object_ids[@]} > 0 )) || return 0
  _git_capture_nul log -z --no-walk=unsorted --no-show-signature \
    --date=short --format='%H%x00%ad%x00%an%x00%s' "${object_ids[@]}" -- ||
    return 1
  log_fields=("${reply[@]}")
  (( ${#log_fields[@]} == 4 * ${#object_ids[@]} )) || {
    _git_error "Git returned unexpected commit records."
    return 1
  }
  for (( field_index = 1; field_index <= ${#log_fields[@]}; field_index += 4 )); do
    [[ "${log_fields[field_index]}" == "${object_ids[(field_index + 3) / 4]}" ]] || {
      _git_error "Git returned commit records out of order."
      return 1
    }
    commit_fields+=(
      "${log_fields[field_index + 1]}"
      "${log_fields[field_index + 2]}"
      "${log_fields[field_index + 3]}"
    )
  done
  reply=("${commit_fields[@]}")
}

# Refuses BRANCH when a local branch has that name, would share its loose ref
# file (a name that is a directory of the other), or differs from it only in
# letter case under core.ignorecase.
_git_recover_require_free_name() {
  emulate -L zsh

  local branch_name="$1"
  local listing="" existing_ref="" new_ref="refs/heads/$branch_name"
  local -a planned_refs=("$new_ref")
  _git_ref_case_guard planned_refs refs/heads \
    "Choose a branch name that differs by more than letter case." || return 1
  listing=$(command git for-each-ref --format='%(refname)' refs/heads \
    2>/dev/null) || {
    _git_error "Unable to list local branches."
    return 1
  }
  for existing_ref in "${(@f)listing}"; do
    [[ -n "$existing_ref" ]] || continue
    if [[ "$existing_ref" == "$new_ref" ]]; then
      _git_error "Local branch already exists: $branch_name"
      return 1
    fi
    if [[ "$new_ref" == "$existing_ref"/* || "$existing_ref" == "$new_ref"/* ]]; then
      _git_error "$branch_name conflicts with the existing branch ${existing_ref#refs/heads/}."
      return 1
    fi
  done
  return 0
}

_git_recover_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  git-recover [--deep] [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-recover --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Choose a commit from the HEAD and branch reflogs that no branch,"
  print -u2 -r -- \
    "remote-tracking branch, or tag reaches any more, and restore it as a new"
  print -u2 -r -- \
    "branch, recover/<short-sha> unless you name it. No existing ref is moved,"
  print -u2 -r -- \
    "reset, or deleted. Interactive: the picker needs a terminal and fzf."
  print -u2 -r -- \
    "  --deep     Also list dangling commits from git fsck, bounded to ${_GIT_RECOVER_FSCK_SECONDS}s."
  print -u2 -r -- \
    "  --dry-run  Show the exact plan without creating the branch."
  print -u2 -r -- \
    "  -y, --yes  Bypass only the final confirmation."
}

git-recover() {
  emulate -L zsh

  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _git_recover_usage
    return 0
  fi

  local deep="no" dry_run="no" assume_yes="no"
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        _git_error "--help does not accept additional arguments."
        return 2
        ;;
      --deep)
        [[ "$deep" == "no" ]] || {
          _git_error "Duplicate option: --deep"
          return 2
        }
        deep="yes"
        ;;
      --dry-run)
        [[ "$dry_run" == "no" ]] || {
          _git_error "Duplicate option: --dry-run"
          return 2
        }
        dry_run="yes"
        ;;
      -y|--yes)
        [[ "$assume_yes" == "no" ]] || {
          _git_error "Duplicate option: --yes"
          return 2
        }
        assume_yes="yes"
        ;;
      *)
        _git_error "Unknown argument for git-recover: $1"
        return 2
        ;;
    esac
    shift
  done
  [[ "$dry_run" == "yes" && "$assume_yes" == "yes" ]] && {
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  }

  _git_require_repo || return 1
  _git_require_interactive || return 1
  local repo_root="" common_dir="" REPLY=""
  local -a reply=()
  repo_root=$(command git rev-parse --path-format=absolute --show-toplevel \
    2>/dev/null) || {
    _git_error "Unable to locate the repository root."
    return 1
  }
  common_dir=$(command git rev-parse --path-format=absolute --git-common-dir \
    2>/dev/null) || {
    _git_error "Unable to locate the Git directory."
    return 1
  }
  repo_root="${repo_root:A}"
  common_dir="${common_dir:A}"

  _git_recover_candidates "$deep" || return 1
  local -a candidate_pairs=("${reply[@]}")
  if (( ${#candidate_pairs[@]} == 0 )); then
    _git_info "No unreachable commits were found in the HEAD and branch reflogs."
    [[ "$deep" == "yes" ]] ||
      _git_info "git-recover --deep also searches dangling commits."
    return 0
  fi

  local -a candidate_oids=() candidate_sources=()
  local -i pair_index=0
  for (( pair_index = 1; pair_index <= ${#candidate_pairs[@]}; pair_index += 2 )); do
    candidate_oids+=("${candidate_pairs[pair_index]}")
    candidate_sources+=("${candidate_pairs[pair_index + 1]}")
  done
  _git_recover_commit_fields "${candidate_oids[@]}" || return 1
  local -a commit_fields=("${reply[@]}")

  local -a picker_rows=()
  local -i row_index=0
  local commit_date="" commit_author="" commit_subject=""
  for (( row_index = 1; row_index <= ${#candidate_oids[@]}; row_index++ )); do
    commit_date="${commit_fields[3 * row_index - 2]}"
    commit_author="${commit_fields[3 * row_index - 1]}"
    commit_subject="${commit_fields[3 * row_index]}"
    picker_rows+=(
      "$row_index"$'\t'"${candidate_oids[row_index]}"$'\t'"${candidate_oids[row_index][1,10]}  ${(V)commit_date}  ${(V)${commit_author//$'\t'/ }}  ${(V)${commit_subject//$'\t'/ }}  (${(V)candidate_sources[row_index]})"
    )
  done

  local color_mode="never"
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]] && color_mode="always"
  # A constant read-only preview: fzf quotes the object ID field, and only a
  # hexadecimal value reaches git show.
  local preview_program='oid={2}; case "$oid" in *[!0-9a-f]*|"") ;; *)'
  preview_program+=" git --no-optional-locks --no-pager show --stat --summary --no-show-signature --no-ext-diff --no-textconv --format=fuller --color=${color_mode} \"\$oid\" -- ;; esac"
  local -a picker_options=(
    "--preview=${preview_program}"
    --height=80%
    '--preview-window=right:50%:wrap,<120(down:8:wrap)'
    '--bind=ctrl-/:toggle-preview'
  )
  _git_branch_context_line
  local header_text="$REPLY | Unreachable commits: ${#candidate_oids[@]}"
  header_text+=$'\n''Type to filter | Enter recover | Esc cancel | Ctrl-/ details'

  _git_select_ids "git recover" "$header_text" 3 no \
    picker_rows picker_options || return 1
  local -a selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} == 1 )) || return 0
  row_index="${selected_ids[1]}"
  local recover_oid="${candidate_oids[row_index]}"
  local recover_source="${candidate_sources[row_index]}"
  commit_date="${commit_fields[3 * row_index - 2]}"
  commit_author="${commit_fields[3 * row_index - 1]}"
  commit_subject="${commit_fields[3 * row_index]}"

  local short_oid=""
  short_oid=$(command git rev-parse --short "$recover_oid" 2>/dev/null) ||
    short_oid="${recover_oid[1,7]}"
  local default_name="recover/$short_oid"
  _git_read_line "New branch name [$default_name]: " || return 1
  local branch_name="$REPLY"
  [[ -n "${branch_name//[[:space:]]/}" ]] || branch_name="$default_name"
  _git_branch_name_valid "$branch_name" || {
    _git_error "Invalid branch name: ${(V)branch_name}"
    return 2
  }

  _git_ui_heading "Recover Commit"
  _git_ui_label "Repository" "${repo_root:t}"
  _git_ui_label "Commit" "${recover_oid[1,12]}"
  _git_ui_label "Subject" "$commit_subject"
  _git_ui_label "Author" "$commit_author"
  _git_ui_label "Date" "$commit_date"
  _git_ui_label "Found in" "$recover_source"
  _git_ui_label "New branch" "$branch_name"
  _git_dim "Creates refs/heads/$branch_name at ${recover_oid[1,12]}; no existing ref is moved or deleted."
  _git_recover_require_free_name "$branch_name" || return 1

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: 1 branch planned; nothing was created."
    return 0
  fi
  _git_confirm_plan "$assume_yes" \
    "Create branch $branch_name at ${recover_oid[1,12]}?" \
    "Cancelled: nothing was created." || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0

  # Revalidate: the same repository, the commit still exists, and the name is
  # still free.
  local current_root="" current_common=""
  current_root=$(command git rev-parse --path-format=absolute --show-toplevel \
    2>/dev/null) || current_root=""
  current_common=$(command git rev-parse --path-format=absolute \
    --git-common-dir 2>/dev/null) || current_common=""
  if [[ "${current_root:A}" != "$repo_root" \
    || "${current_common:A}" != "$common_dir" ]] \
    || ! command git cat-file -e "${recover_oid}^{commit}" 2>/dev/null; then
    _git_error "Repository state changed after review; nothing was created."
    return 1
  fi
  _git_recover_require_free_name "$branch_name" || return 1

  # An empty old value makes the update create-only: Git refuses it when the
  # ref appeared in the meantime, so no existing ref can be moved.
  _git_run_captured "git update-ref refs/heads/$branch_name ${recover_oid[1,12]}" \
    command git update-ref --create-reflog \
    -m "git-recover: restore ${recover_oid}" \
    "refs/heads/$branch_name" "$recover_oid" ""
  local -i command_code=$?
  local created_oid=""
  created_oid=$(command git rev-parse --verify --quiet \
    "refs/heads/${branch_name}^{commit}" 2>/dev/null) || created_oid=""
  if (( command_code != 0 )) || [[ "$created_oid" != "$recover_oid" ]]; then
    _git_error "The branch was not created (exit $command_code); nothing else changed."
    (( command_code == 0 )) && return 1
    return "$command_code"
  fi
  _git_success "Created branch $branch_name at ${recover_oid[1,12]}."
  _git_info "Switch to it with: git-switch $branch_name"
}

typeset -g _GIT_BRANCH_SOURCED=1
