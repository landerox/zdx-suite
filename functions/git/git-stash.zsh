#!/usr/bin/env zsh
# =============================================================================
# Git Stash: save, inspect, apply, pop, branch from, and drop stashes
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_STASH_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Private stash records ----------------------------------------------------

# Sets reply to flat stash fields: oid, selector, subject, relative age.
_git_stash_collect() {
  emulate -L zsh

  local -a raw_records=()
  local raw_record=""
  local stash_oid=""
  local remaining=""
  local stash_selector=""
  local stash_subject=""
  local stash_age=""

  _git_capture_nul \
    stash list -z --format='%H%x09%gd%x09%ar%x09%s' || return 1
  raw_records=("${reply[@]}")
  reply=()

  for raw_record in "${raw_records[@]}"; do
    stash_oid="${raw_record%%$'\t'*}"
    remaining="${raw_record#*$'\t'}"
    stash_selector="${remaining%%$'\t'*}"
    remaining="${remaining#*$'\t'}"
    stash_age="${remaining%%$'\t'*}"
    stash_subject="${remaining#*$'\t'}"

    if [[ ! "$stash_oid" =~ '^[0-9A-Fa-f]+$' \
      || "$stash_selector" != 'stash@{'<->'}' ]] ||
      (( ${#stash_oid} != 40 && ${#stash_oid} != 64 )); then
      _git_error "Git returned a malformed stash record."
      return 1
    fi

    reply+=("$stash_oid" "$stash_selector" "$stash_subject" "$stash_age")
  done
}

_git_stash_inventory_summary() {
  emulate -L zsh

  local -a stash_fields=()
  local -a identities=()
  local fingerprint=""
  local -i field_index=0

  _git_stash_collect || return 1
  stash_fields=("${reply[@]}")
  for (( field_index = 1; field_index <= ${#stash_fields[@]}; field_index += 4 )); do
    identities+=(
      "${stash_fields[field_index]}:${stash_fields[field_index + 1]}"
    )
  done

  fingerprint=$(print -rl -- "${identities[@]}" |
    command git hash-object --stdin 2>/dev/null) || {
    _git_error "Unable to fingerprint the stash inventory."
    return 1
  }

  reply=(
    "$fingerprint"
    "$(( ${#stash_fields[@]} / 4 ))"
    "${stash_fields[1]:-NONE}"
  )
}

_git_stash_append_path_hashes() {
  emulate -L zsh
  setopt localoptions no_aliases

  local repo_root="$1"
  local marker="$2"
  local paths_name="$3"
  local state_file="$4"
  local -a file_names=("${(@P)paths_name}")
  local file_name=""
  local absolute_name=""
  local object_oid=""

  for file_name in "${file_names[@]}"; do
    absolute_name="$repo_root/$file_name"
    if [[ -L "$absolute_name" ]]; then
      _git_check_cmd readlink || {
        _git_error "readlink is required to fingerprint a planned symbolic link."
        return 1
      }
      print -rn -- \
        "$marker"$'\0'"$file_name"$'\0'"symlink"$'\0' \
        >> "$state_file" || return 1
      command readlink "$absolute_name" >> "$state_file" || {
        _git_error "Unable to fingerprint a planned symbolic link."
        return 1
      }
      print -rn -- $'\0' >> "$state_file" || return 1
    elif [[ -f "$absolute_name" ]]; then
      object_oid=$(command git -C "$repo_root" \
        hash-object --no-filters -- "$file_name" 2>/dev/null) || {
        _git_error "Unable to fingerprint a planned stash path."
        return 1
      }
      print -rn -- \
        "$marker"$'\0'"$file_name"$'\0'"blob"$'\0'"$object_oid"$'\0' \
        >> "$state_file" || return 1
    elif [[ -e "$absolute_name" ]]; then
      _git_error "Unsupported special file in planned stash scope: ${(V)file_name}"
      return 1
    else
      _git_error "A planned stash path disappeared while it was fingerprinted."
      return 1
    fi
  done
}

# Untracked and ignored paths that collide with the stash targets; with
# core.ignorecase letter case is ignored, as on the file system.
_git_stash_current_obstacles() {
  emulate -L zsh

  local targets_name="$1"
  local -a untracked_paths=()
  local -a ignored_paths=()
  local -a untracked_obstacles=()
  local -a ignored_obstacles=()
  local fold_case="no"

  _git_ignorecase_enabled && fold_case="yes"
  _git_capture_nul \
    ls-files --others --exclude-standard -z -- || return 1
  untracked_paths=("${reply[@]}")
  _git_capture_nul \
    ls-files --others --ignored --exclude-standard -z -- || return 1
  ignored_paths=("${reply[@]}")

  _git_path_collisions untracked_paths "$targets_name" "$fold_case" || return 1
  untracked_obstacles=("${reply[@]}")
  _git_path_collisions ignored_paths "$targets_name" "$fold_case" || return 1
  ignored_obstacles=("${reply[@]}")
  reply=("${untracked_obstacles[@]}" "${ignored_obstacles[@]}")
}

_git_stash_require_clear_targets() {
  emulate -L zsh

  local targets_name="$1"
  local action_name="$2"
  local -a obstacle_paths=()
  local obstacle_path=""

  _git_stash_current_obstacles "$targets_name" || {
    _git_error "Unable to inspect untracked and ignored stash obstacles."
    return 1
  }
  obstacle_paths=("${reply[@]}")
  (( ${#obstacle_paths[@]} == 0 )) && return 0

  _git_warn "These untracked or ignored paths collide with the stash:"
  for obstacle_path in "${obstacle_paths[@]}"; do
    _git_dim "${(V)obstacle_path}"
  done
  _git_error \
    "Refusing to $action_name across untracked or ignored path collisions."
  return 1
}

_git_stash_state_fingerprint() {
  emulate -L zsh
  setopt localoptions no_aliases

  local repo_root="$1"
  local state_scope="$2"
  local targets_name="${3:-}"
  local temp_dir=""
  local state_file=""
  local fingerprint=""
  local -a untracked_paths=()
  local -a ignored_paths=()
  local -a untracked_obstacles=()
  local -a ignored_obstacles=()
  local -a reply=()
  local -i command_code=0
  local fold_case="no"

  [[ "$state_scope" == (none|tracked|untracked|obstacles) ]] || {
    _git_error "Invalid internal stash state scope."
    return 2
  }
  if [[ "$state_scope" == "obstacles" && -z "$targets_name" ]]; then
    _git_error "Stash obstacle fingerprinting requires exact target paths."
    return 2
  fi

  temp_dir=$(command mktemp -d "${TMPDIR:-/tmp}/zdx-git-stash-state.XXXXXX") || {
    _git_error "Unable to create a private temporary directory."
    return 1
  }
  state_file="$temp_dir/state"

  {
    print -rn -- "scope"$'\0'"$state_scope"$'\0' >| "$state_file" ||
      command_code=1

    if (( command_code == 0 )) && [[ "$state_scope" != "none" ]]; then
      command git --literal-pathspecs -C "$repo_root" diff \
        --binary --full-index --no-ext-diff --no-textconv -- \
        >> "$state_file"
      command_code=$?
    fi
    if (( command_code == 0 )) && [[ "$state_scope" != "none" ]]; then
      command git --literal-pathspecs -C "$repo_root" diff --cached \
        --binary --full-index --no-ext-diff --no-textconv -- \
        >> "$state_file"
      command_code=$?
    fi

    if (( command_code == 0 )) && [[ "$state_scope" == (untracked|obstacles) ]]; then
      _git_capture_nul ls-files --others --exclude-standard -z -- ||
        command_code=$?
      untracked_paths=("${reply[@]}")
    fi

    if (( command_code == 0 )) && [[ "$state_scope" == "obstacles" ]]; then
      _git_ignorecase_enabled && fold_case="yes"
      _git_capture_nul ls-files --others --ignored --exclude-standard -z -- ||
        command_code=$?
      ignored_paths=("${reply[@]}")
      if (( command_code == 0 )); then
        _git_path_collisions untracked_paths "$targets_name" "$fold_case" ||
          command_code=$?
        untracked_obstacles=("${reply[@]}")
      fi
      if (( command_code == 0 )); then
        _git_path_collisions ignored_paths "$targets_name" "$fold_case" ||
          command_code=$?
        ignored_obstacles=("${reply[@]}")
      fi
    elif [[ "$state_scope" == "untracked" ]]; then
      # Git lists an untracked nested repository as "dir/" and git stash -u
      # leaves it in place, so it is not part of the stashed state.
      untracked_obstacles=("${(@)untracked_paths:#*/}")
    fi

    if (( command_code == 0 )) && [[ "$state_scope" == "obstacles" ]]; then
      local obstacle_path=""
      for obstacle_path in "${untracked_obstacles[@]}"; do
        print -rn -- \
          "untracked"$'\0'"$obstacle_path"$'\0' >> "$state_file" ||
          command_code=1
      done
      for obstacle_path in "${ignored_obstacles[@]}"; do
        print -rn -- \
          "ignored"$'\0'"$obstacle_path"$'\0' >> "$state_file" ||
          command_code=1
      done
    elif (( command_code == 0 )) && (( ${#untracked_obstacles[@]} > 0 )); then
      _git_stash_append_path_hashes \
        "$repo_root" "untracked" untracked_obstacles "$state_file" ||
        command_code=$?
    fi

    if (( command_code == 0 )); then
      fingerprint=$(command git hash-object --no-filters -- \
        "$state_file" 2>/dev/null)
      command_code=$?
    fi
  } always {
    command rm -f -- "$state_file" 2>/dev/null
    command rmdir -- "$temp_dir" 2>/dev/null
  }

  (( command_code == 0 )) || return "$command_code"
  REPLY="$fingerprint"
}

_git_stash_context_capture() {
  emulate -L zsh

  local state_scope="$1"
  local targets_name="${2:-}"
  local repo_root=""
  local common_dir=""
  local worktree_git_dir=""
  local head_oid=""
  local branch_ref=""
  local state_fingerprint=""
  local -a inventory=()

  repo_root=$(command git rev-parse \
    --path-format=absolute --show-toplevel 2>/dev/null) || return 1
  common_dir=$(command git rev-parse \
    --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  worktree_git_dir=$(command git rev-parse \
    --path-format=absolute --git-dir 2>/dev/null) || return 1
  head_oid=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
    head_oid="UNBORN"
  branch_ref=$(command git symbolic-ref -q HEAD 2>/dev/null) ||
    branch_ref="DETACHED"

  repo_root="${repo_root:A}"
  common_dir="${common_dir:A}"
  worktree_git_dir="${worktree_git_dir:A}"
  _git_stash_state_fingerprint \
    "$repo_root" "$state_scope" "$targets_name" || return 1
  state_fingerprint="$REPLY"
  _git_stash_inventory_summary || return 1
  inventory=("${reply[@]}")

  reply=(
    "$repo_root"
    "$common_dir"
    "$worktree_git_dir"
    "$head_oid"
    "$branch_ref"
    "$state_fingerprint"
    "${inventory[1]}"
    "${inventory[2]}"
    "${inventory[3]}"
  )
}

_git_stash_context_matches() {
  emulate -L zsh

  local snapshot_name="$1"
  local state_scope="$2"
  local targets_name="${3:-}"
  local compare_inventory="${4:-yes}"
  local -a expected=("${(@P)snapshot_name}")
  local -a current=()

  (( ${#expected[@]} == 9 )) || return 1
  _git_stash_context_capture "$state_scope" "$targets_name" || return 1
  current=("${reply[@]}")

  [[ "${current[1]}" == "${expected[1]}" \
    && "${current[2]}" == "${expected[2]}" \
    && "${current[3]}" == "${expected[3]}" \
    && "${current[4]}" == "${expected[4]}" \
    && "${current[5]}" == "${expected[5]}" \
    && "${current[6]}" == "${expected[6]}" ]] || return 1

  [[ "$compare_inventory" == "no" ]] && return 0
  [[ "${current[7]}" == "${expected[7]}" \
    && "${current[8]}" == "${expected[8]}" \
    && "${current[9]}" == "${expected[9]}" ]]
}

_git_stash_require_same_context() {
  emulate -L zsh

  _git_stash_context_matches "$@" && return 0
  _git_error "Repository or stash state changed after review; nothing was changed."
  return 1
}

_git_stash_identity_matches() {
  emulate -L zsh

  local snapshot_name="$1"
  local -a expected=("${(@P)snapshot_name}")
  local current_root=""
  local current_common=""
  local current_git_dir=""
  local current_head=""
  local current_branch=""

  current_root=$(command git rev-parse \
    --path-format=absolute --show-toplevel 2>/dev/null) || return 1
  current_common=$(command git rev-parse \
    --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  current_git_dir=$(command git rev-parse \
    --path-format=absolute --git-dir 2>/dev/null) || return 1
  current_head=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
    current_head="UNBORN"
  current_branch=$(command git symbolic-ref -q HEAD 2>/dev/null) ||
    current_branch="DETACHED"

  [[ "${current_root:A}" == "${expected[1]}" \
    && "${current_common:A}" == "${expected[2]}" \
    && "${current_git_dir:A}" == "${expected[3]}" \
    && "$current_head" == "${expected[4]}" \
    && "$current_branch" == "${expected[5]}" ]]
}

# Sets reply to flat change-label/path pairs for the files a save would store.
# Nested repositories ("dir/") are left in place by git stash -u.
_git_stash_collect_save_pairs() {
  emulate -L zsh

  local save_mode="$1"
  local -a staged_pairs=()
  local -a worktree_pairs=()
  local -a untracked_files=()
  local -a ordered_paths=()
  local -a save_pairs=()
  local -A index_letters=()
  local -A worktree_letters=()
  local file_name=""
  local -i pair_index=0

  [[ "$save_mode" == (tracked|untracked|keep-index) ]] || {
    _git_error "Invalid stash save mode."
    return 2
  }

  _git_name_status_pairs --cached -- || return 1
  staged_pairs=("${reply[@]}")
  _git_name_status_pairs -- || return 1
  worktree_pairs=("${reply[@]}")
  for (( pair_index = 1; pair_index <= ${#staged_pairs[@]}; pair_index += 2 )); do
    file_name="${staged_pairs[pair_index + 1]}"
    [[ -n "${index_letters[$file_name]:-}" ]] || ordered_paths+=("$file_name")
    index_letters[$file_name]="${staged_pairs[pair_index]}"
  done
  for (( pair_index = 1; pair_index <= ${#worktree_pairs[@]}; pair_index += 2 )); do
    file_name="${worktree_pairs[pair_index + 1]}"
    [[ -n "${index_letters[$file_name]:-}" || -n "${worktree_letters[$file_name]:-}" ]] ||
      ordered_paths+=("$file_name")
    worktree_letters[$file_name]="${worktree_pairs[pair_index]}"
  done
  for file_name in "${(@o)ordered_paths}"; do
    _git_change_label \
      "${index_letters[$file_name]:-}" "${worktree_letters[$file_name]:-}"
    save_pairs+=("$REPLY" "$file_name")
  done

  if [[ "$save_mode" == "untracked" ]]; then
    _git_capture_nul ls-files --others --exclude-standard -z -- || return 1
    untracked_files=("${(@)reply:#*/}")
    for file_name in "${(@o)untracked_files}"; do
      save_pairs+=("untracked" "$file_name")
    done
  fi
  reply=("${save_pairs[@]}")
}

# Sets reply to flat change-label/path pairs stored in one stash object:
# tracked changes against the stash base, then its untracked files.
_git_stash_object_paths() {
  emulate -L zsh

  local stash_oid="$1"
  local -a tracked_pairs=()
  local -a untracked_files=()
  local -a object_fields=()
  local file_name=""
  local change_label=""
  local -i pair_index=0

  _git_validate_oid "$stash_oid" || {
    _git_error "Invalid stash object identifier."
    return 1
  }
  command git cat-file -e "${stash_oid}^{commit}" 2>/dev/null || {
    _git_error "The selected stash object is no longer available."
    return 1
  }

  _git_name_status_pairs "${stash_oid}^1" "$stash_oid" -- || return 1
  tracked_pairs=("${reply[@]}")
  if command git cat-file -e "${stash_oid}^3^{commit}" 2>/dev/null; then
    _git_capture_nul ls-tree -r -z --name-only "${stash_oid}^3" || return 1
    untracked_files=("${reply[@]}")
  fi

  for (( pair_index = 1; pair_index <= ${#tracked_pairs[@]}; pair_index += 2 )); do
    case "${tracked_pairs[pair_index]}" in
      A) change_label="added" ;;
      D) change_label="deleted" ;;
      T) change_label="type changed" ;;
      *) change_label="modified" ;;
    esac
    object_fields+=("$change_label" "${tracked_pairs[pair_index + 1]}")
  done
  for file_name in "${untracked_files[@]}"; do
    object_fields+=("untracked" "$file_name")
  done
  reply=("${object_fields[@]}")
}

# Sets reply to the paths of flat change-label/path pairs.
_git_stash_paths_from_pairs() {
  emulate -L zsh

  local fields_name="$1"
  local -a object_fields=("${(@P)fields_name}")
  local -a file_names=()
  local -i field_index=0

  (( ${#object_fields[@]} % 2 == 0 )) || {
    _git_error "Malformed internal stash path inventory."
    return 1
  }
  for (( field_index = 1; field_index <= ${#object_fields[@]}; field_index += 2 )); do
    file_names+=("${object_fields[field_index + 1]}")
  done
  reply=("${file_names[@]}")
}

# Renders change-label/path pairs as a numbered plan table.
_git_stash_show_pairs_table() {
  emulate -L zsh

  local fields_name="$1"
  local -a object_fields=("${(@P)fields_name}")
  local -a plan_rows=()
  local -i field_index=0
  local -i row_number=0

  for (( field_index = 1; field_index <= ${#object_fields[@]}; field_index += 2 )); do
    (( row_number++ ))
    plan_rows+=(
      "$row_number"$'\t'"${object_fields[field_index]}"$'\t'"${(V)object_fields[field_index + 1]}"
    )
  done
  _git_blank
  _git_table $'#\tChange\tPath' "${plan_rows[@]}"
}

_git_stash_show_context() {
  emulate -L zsh

  local snapshot_name="$1"
  local -a snapshot=("${(@P)snapshot_name}")
  local branch_label="${snapshot[5]}"

  if [[ "$branch_label" == refs/heads/* ]]; then
    branch_label="${branch_label#refs/heads/}"
  else
    branch_label="detached HEAD"
  fi
  _git_label "Repository:" "${snapshot[1]:t}"
  _git_label "Branch:" "$branch_label"
}

_git_stash_contains_oid() {
  emulate -L zsh

  local expected_oid="$1"
  local -a stash_fields=()
  local -i match_count=0
  local -i field_index=0

  _git_stash_collect || return 1
  stash_fields=("${reply[@]}")
  for (( field_index = 1; field_index <= ${#stash_fields[@]}; field_index += 4 )); do
    [[ "${stash_fields[field_index]}" == "$expected_oid" ]] &&
      (( match_count++ ))
  done
  REPLY="$match_count"
}

# Resolves exact stash targets (full OIDs or current stash@{N} selectors) to
# flat stash fields. Ambiguous, missing, or duplicate targets fail closed.
_git_stash_resolve_targets() {
  emulate -L zsh

  local tokens_name="$1"
  local -a target_tokens=("${(@P)tokens_name}")
  local -a stash_fields=()
  local -a selected_fields=()
  local target_token=""
  local -i match_count=0
  local -i field_index=0
  local -i matched_index=0

  (( ${#target_tokens[@]} > 0 )) || {
    _git_error "At least one stash target is required."
    return 2
  }
  _git_stash_collect || return 1
  stash_fields=("${reply[@]}")

  for target_token in "${target_tokens[@]}"; do
    if [[ "$target_token" != 'stash@{'<->'}' ]] &&
      ! _git_validate_oid "$target_token"; then
      _git_error \
        "Invalid stash target; use a full stash OID or a current stash@{N} selector."
      return 2
    fi

    match_count=0
    matched_index=0
    for (( field_index = 1; field_index <= ${#stash_fields[@]}; field_index += 4 )); do
      if [[ "${stash_fields[field_index]}" == "$target_token" \
        || "${stash_fields[field_index + 1]}" == "$target_token" ]]; then
        (( match_count++ ))
        matched_index=$field_index
      fi
    done
    if (( match_count != 1 )); then
      _git_error "Stash target is missing or ambiguous: $target_token"
      return 1
    fi

    local selected_oid="${stash_fields[matched_index]}"
    local -i selected_index=0
    local duplicate_target="no"
    for (( selected_index = 1; selected_index <= ${#selected_fields[@]}; selected_index += 4 )); do
      if [[ "${selected_fields[selected_index]}" == "$selected_oid" ]]; then
        duplicate_target="yes"
        break
      fi
    done
    if [[ "$duplicate_target" == "yes" ]]; then
      _git_error "Duplicate stash target: $target_token"
      return 2
    fi
    selected_fields+=(
      "$selected_oid"
      "${stash_fields[matched_index + 1]}"
      "${stash_fields[matched_index + 2]}"
      "${stash_fields[matched_index + 3]}"
    )
  done

  for (( field_index = 1; field_index <= ${#selected_fields[@]}; field_index += 4 )); do
    _git_stash_contains_oid "${selected_fields[field_index]}" || return 1
    if (( REPLY != 1 )); then
      _git_error \
        "Stash commit identity is ambiguous: ${selected_fields[field_index][1,12]}"
      return 1
    fi
  done
  reply=("${selected_fields[@]}")
}

_git_stash_collect_unmerged_paths() {
  emulate -L zsh

  _git_capture_nul diff --name-only --diff-filter=U -z -- || return 1
}

_git_stash_fields_for_ids() {
  emulate -L zsh

  local fields_name="$1"
  local ids_name="$2"
  local -a stash_fields=("${(@P)fields_name}")
  local -a selected_ids=("${(@P)ids_name}")
  local selected_id=""
  local -i record_index=0
  local -i field_index=0
  reply=()

  for selected_id in "${selected_ids[@]}"; do
    record_index=$(( 10#$selected_id ))
    field_index=$(( ((record_index - 1) * 4) + 1 ))
    if (( field_index < 1 || field_index + 3 > ${#stash_fields[@]} )); then
      _git_error "Selected stash is outside the captured inventory."
      return 1
    fi
    reply+=(
      "${stash_fields[field_index]}"
      "${stash_fields[field_index + 1]}"
      "${stash_fields[field_index + 2]}"
      "${stash_fields[field_index + 3]}"
    )
  done
}

_git_stash_find_selector() {
  emulate -L zsh

  local expected_oid="$1"
  local -a current_fields=()
  local -a matches=()
  local -i field_index=0

  _git_stash_collect || return 1
  current_fields=("${reply[@]}")
  for (( field_index = 1; field_index <= ${#current_fields[@]}; field_index += 4 )); do
    if [[ "${current_fields[field_index]}" == "$expected_oid" ]]; then
      matches+=("${current_fields[field_index + 1]}")
    fi
  done

  if (( ${#matches[@]} != 1 )); then
    _git_error "Stash identity changed or became ambiguous: ${expected_oid[1,12]}"
    return 1
  fi
  REPLY="${matches[1]}"
}

# --- Diff views ---------------------------------------------------------------

# stdin is native Git diff content. Page it only for a terminal destination.
_git_stash_page() {
  if [[ -t 1 ]] && command -v less &>/dev/null; then
    LESS="${LESS:-FRX}" command less -R
  else
    command cat
  fi
}

_git_stash_page_git() {
  emulate -L zsh

  command git --literal-pathspecs "$@" | _git_stash_page
  local -a pipeline_codes=("${pipestatus[@]}")
  if (( pipeline_codes[1] != 0 )); then
    _git_error "Git failed while producing stash output (exit ${pipeline_codes[1]})."
    return "${pipeline_codes[1]}"
  fi
  if (( pipeline_codes[2] != 0 )); then
    _git_error "Pager failed (exit ${pipeline_codes[2]})."
    return "${pipeline_codes[2]}"
  fi
  return 0
}

# Pages the complete stash diff: tracked changes, then untracked files.
_git_stash_page_full() {
  emulate -L zsh
  setopt localoptions no_aliases

  local stash_oid="$1"
  local empty_tree_oid=""
  local temp_dir=""
  local diff_file=""
  local -i command_code=0
  local -i pager_code=0
  local color_mode="never"
  [[ -t 1 ]] && color_mode="always"

  _git_validate_oid "$stash_oid" || {
    _git_error "Invalid stash object identifier."
    return 1
  }
  empty_tree_oid=$(print -rn -- "" |
    command git hash-object -t tree --stdin 2>/dev/null) || {
    _git_error "Unable to resolve the empty Git tree."
    return 1
  }

  temp_dir=$(command mktemp -d "${TMPDIR:-/tmp}/zdx-git-stash-diff.XXXXXX") || {
    _git_error "Unable to create a private temporary directory."
    return 1
  }
  diff_file="$temp_dir/diff"

  {
    command git --literal-pathspecs diff \
      --binary "--color=$color_mode" --no-ext-diff --no-textconv \
      "${stash_oid}^1" "$stash_oid" -- >| "$diff_file"
    command_code=$?

    if (( command_code == 0 )) &&
      command git cat-file -e "${stash_oid}^3^{commit}" 2>/dev/null; then
      command git --literal-pathspecs diff \
        --binary "--color=$color_mode" --no-ext-diff --no-textconv \
        "$empty_tree_oid" "${stash_oid}^3" -- >> "$diff_file"
      command_code=$?
    fi

    if (( command_code == 0 )); then
      _git_stash_page < "$diff_file"
      pager_code=$?
    fi
  } always {
    command rm -f -- "$diff_file" 2>/dev/null
    command rmdir -- "$temp_dir" 2>/dev/null
  }

  if (( command_code != 0 )); then
    _git_error "Git failed while producing the full stash diff (exit $command_code)."
    return "$command_code"
  fi
  if (( pager_code != 0 )); then
    _git_error "Pager failed (exit $pager_code)."
    return "$pager_code"
  fi
  return 0
}

# Lists the files of one stash with a live diff preview; Enter pages a file.
_git_stash_browse_files() {
  emulate -L zsh

  local stash_oid="$1"
  local stash_selector="$2"
  local empty_tree_oid=""
  local -a object_fields=()
  local -a all_files=()
  local -a all_kinds=()
  local -a picker_rows=()
  local -a reply=()
  local REPLY=""
  local color_mode="never"
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]] && color_mode="always"

  _git_stash_object_paths "$stash_oid" || return 1
  object_fields=("${reply[@]}")
  local -i field_index=0
  for (( field_index = 1; field_index <= ${#object_fields[@]}; field_index += 2 )); do
    if [[ "${object_fields[field_index]}" == "untracked" ]]; then
      all_kinds+=(untracked)
    else
      all_kinds+=(tracked)
    fi
    all_files+=("${object_fields[field_index + 1]}")
  done
  (( ${#all_files[@]} > 0 )) || {
    _git_info "The selected stash contains no files."
    return 0
  }
  empty_tree_oid=$(print -rn -- "" |
    command git hash-object -t tree --stdin 2>/dev/null) || return 1
  _git_validate_oid "$empty_tree_oid" || return 1

  local -i item_index=0
  local -i label_width=0
  for (( item_index = 1; item_index <= ${#all_files[@]}; item_index++ )); do
    (( ${#object_fields[item_index * 2 - 1]} > label_width )) &&
      label_width=${#object_fields[item_index * 2 - 1]}
  done
  local change_label=""
  for (( item_index = 1; item_index <= ${#all_files[@]}; item_index++ )); do
    change_label="${object_fields[item_index * 2 - 1]}"
    picker_rows+=(
      "${item_index}"$'\t'"${all_kinds[item_index]}"$'\t'"${(V)all_files[item_index]}"$'\t'"${(r:label_width:)change_label}  ${(V)all_files[item_index]}"
    )
  done

  # The program is constant apart from validated hexadecimal object IDs; fzf
  # quotes the kind and path placeholders.
  local preview_program="case {2} in"
  preview_program+=" untracked) git --literal-pathspecs --no-pager diff --no-ext-diff --no-textconv --color=${color_mode} ${(qq)empty_tree_oid} ${(qq)stash_oid}^3 -- {3} ;;"
  preview_program+=" *) git --literal-pathspecs --no-pager diff --no-ext-diff --no-textconv --color=${color_mode} ${(qq)stash_oid}^1 ${(qq)stash_oid} -- {3} ;;"
  preview_program+=" esac"
  local -a picker_options=(
    "--preview=${preview_program}"
    --height=80%
    '--preview-window=right:50%:wrap,<120(down:8:wrap)'
    '--bind=ctrl-/:toggle-preview'
  )
  local header_text="Stash: ${stash_selector} | Files: ${#all_files[@]}"
  header_text+=$'\n''Type to filter | Enter page diff | Esc back | Ctrl-/ details'

  local file_name=""
  while true; do
    _git_select_ids "${stash_selector} files" "$header_text" 4 no \
      picker_rows picker_options || return 1
    (( ${#reply[@]} > 0 )) || return 0

    item_index="${reply[1]}"
    file_name="${all_files[item_index]}"
    command git cat-file -e "${stash_oid}^{commit}" 2>/dev/null || {
      _git_error "The selected stash object is no longer available."
      return 1
    }
    if [[ "${all_kinds[item_index]}" == "untracked" ]]; then
      _git_stash_page_git \
        diff "--color=$color_mode" --no-ext-diff --no-textconv \
        "$empty_tree_oid" "${stash_oid}^3" -- "$file_name" || return $?
    else
      _git_stash_page_git \
        diff "--color=$color_mode" --no-ext-diff --no-textconv \
        "${stash_oid}^1" "$stash_oid" -- "$file_name" || return $?
    fi
  done
}

# --- Save ---------------------------------------------------------------------

_git_stash_save() {
  emulate -L zsh

  local save_mode="$1"
  local stash_message="$2"
  local dry_run="$3"
  local assume_yes="$4"
  local state_scope="tracked"
  local -a snapshot=()
  local -a save_pairs=()
  local -a target_paths=()
  local -a inventory_after=()
  local -a reply=()
  local REPLY=""

  case "$save_mode" in
    tracked|keep-index) ;;
    untracked) state_scope="untracked" ;;
    *)
      _git_error "Invalid stash save mode."
      return 2
      ;;
  esac
  command git rev-parse --verify -q 'HEAD^{commit}' &>/dev/null || {
    _git_error "Stashes need at least one commit on the current branch."
    return 1
  }

  _git_stash_context_capture "$state_scope" target_paths || {
    _git_error "Unable to capture repository state for the stash."
    return 1
  }
  snapshot=("${reply[@]}")
  _git_stash_collect_save_pairs "$save_mode" || return $?
  save_pairs=("${reply[@]}")
  _git_stash_paths_from_pairs save_pairs || return 1
  target_paths=("${reply[@]}")
  _git_stash_require_same_context \
    snapshot "$state_scope" target_paths "yes" || return 1

  if (( ${#target_paths[@]} == 0 )); then
    if [[ "$save_mode" != "untracked" ]]; then
      _git_capture_nul ls-files --others --exclude-standard -z -- || return 1
      local -a untracked_candidates=("${(@)reply:#*/}")
      if (( ${#untracked_candidates[@]} > 0 )); then
        _git_count_noun "${#untracked_candidates[@]}" "untracked file"
        _git_info \
          "Nothing to save without untracked files; --include-untracked saves $REPLY."
        return 0
      fi
    fi
    _git_info "Nothing to save: there are no local changes."
    return 0
  fi

  _git_header "Save Changes to a Stash"
  _git_stash_show_context snapshot
  _git_label "Message:" "${stash_message:-Git default}"
  [[ "$save_mode" == "keep-index" ]] &&
    _git_label "Staged changes:" "stay in the working tree"
  _git_stash_show_pairs_table save_pairs
  _git_dim "The saved changes leave the working tree; Apply or Pop restores them."

  _git_count_noun "${#target_paths[@]}" file
  local planned="$REPLY"
  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: $planned planned; nothing was stashed."
    return 0
  fi

  _git_confirm_plan "$assume_yes" "Save $planned to a new stash?" \
    "Cancelled: nothing was stashed." || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0
  _git_stash_require_same_context \
    snapshot "$state_scope" target_paths "yes" || return 1

  local -a stash_command=(
    git -C "${snapshot[1]}" stash push --quiet
  )
  [[ "$save_mode" == "untracked" ]] && stash_command+=(--include-untracked)
  [[ "$save_mode" == "keep-index" ]] && stash_command+=(--keep-index)
  [[ -n "$stash_message" ]] && stash_command+=(-m "$stash_message")

  command "${stash_command[@]}" >&2
  local -i command_code=$?

  _git_stash_inventory_summary || {
    _git_error "Unable to inspect the stash list after saving."
    return 1
  }
  inventory_after=("${reply[@]}")

  local -i expected_count=$(( snapshot[8] + 1 ))
  if (( command_code == 0 )) &&
    (( inventory_after[2] == expected_count )) &&
    [[ "${inventory_after[1]}" != "${snapshot[7]}" \
      && "${inventory_after[3]}" != "NONE" ]]; then
    _git_success \
      "Stash saved: $planned stored as stash@{0} (${inventory_after[3][1,12]})."
    [[ "$save_mode" == "keep-index" ]] &&
      _git_info "The staged changes stay in the working tree."
    _git_stash_result="done"
    return 0
  fi

  if (( command_code == 0 )) &&
    (( inventory_after[2] == snapshot[8] )) &&
    [[ "${inventory_after[1]}" == "${snapshot[7]}" ]]; then
    _git_stash_state_fingerprint \
      "${snapshot[1]}" "$state_scope" target_paths || return 1
    if [[ "$REPLY" == "${snapshot[6]}" ]]; then
      _git_info "Git completed without creating a stash; nothing was stashed."
      return 0
    fi
    _git_error "Git created no stash but changed the working tree or index; inspect them."
    return 1
  fi

  if (( inventory_after[2] > snapshot[8] )); then
    _git_warn "A new stash exists despite the reported failure or unexpected result."
    _git_info "Newest stash OID: ${inventory_after[3]}"
  fi
  _git_error "Saving the stash did not reach the verified expected state (exit $command_code)."
  (( command_code == 0 )) && return 1
  return "$command_code"
}

# Asks only what matters: an optional message, then whether to include
# untracked files when there are any.
_git_stash_save_interactive() {
  emulate -L zsh

  local dry_run="$1"
  local assume_yes="$2"
  local save_mode="tracked"
  local stash_message=""
  local -a reply=()
  local REPLY=""

  _git_stash_collect_save_pairs tracked || return $?
  local -i tracked_count=$(( ${#reply[@]} / 2 ))
  _git_capture_nul ls-files --others --exclude-standard -z -- || return 1
  local -a untracked_candidates=("${(@)reply:#*/}")
  if (( tracked_count == 0 && ${#untracked_candidates[@]} == 0 )); then
    _git_info "Nothing to save: there are no local changes."
    return 0
  fi

  _git_read_line "Stash message (optional): " || return 1
  stash_message="$REPLY"
  [[ "$stash_message" != *[$'\n\r']* ]] || {
    _git_error "The stash message must be one line."
    return 1
  }
  [[ -n "${stash_message//[[:space:]]/}" ]] || stash_message=""

  if (( ${#untracked_candidates[@]} > 0 )); then
    _git_count_noun "${#untracked_candidates[@]}" "untracked file"
    _git_confirm_outcome "Include $REPLY?" || return 1
    case "$REPLY" in
      confirmed) save_mode="untracked" ;;
      cancelled)
        (( tracked_count > 0 )) || {
          _git_info "Cancelled: nothing was stashed."
          return 0
        }
        ;;
      *)
        _git_error "Choosing whether to include untracked files requires a terminal."
        return 1
        ;;
    esac
  fi

  _git_stash_save "$save_mode" "$stash_message" "$dry_run" "$assume_yes"
}

# --- Drop ---------------------------------------------------------------------

_git_stash_drop_selected() {
  emulate -L zsh

  local fields_name="$1"
  local dry_run="$2"
  local assume_yes="$3"
  local -a selected_fields=("${(@P)fields_name}")
  local -a snapshot=()
  local -a plan_rows=()
  local -a reply=()
  local REPLY=""

  (( ${#selected_fields[@]} > 0 && ${#selected_fields[@]} % 4 == 0 )) || {
    _git_error "No valid stash targets were supplied for deletion."
    return 1
  }
  local -i field_index=0
  local -i row_number=0
  for (( field_index = 1; field_index <= ${#selected_fields[@]}; field_index += 4 )); do
    _git_stash_contains_oid "${selected_fields[field_index]}" || return 1
    if (( REPLY != 1 )); then
      _git_error \
        "Stash identity is missing or ambiguous: ${selected_fields[field_index][1,12]}"
      return 1
    fi
    (( row_number++ ))
    plan_rows+=(
      "$row_number"$'\t'"${selected_fields[field_index + 1]}"$'\t'"${selected_fields[field_index][1,12]}"$'\t'"${(V)selected_fields[field_index + 2]}"
    )
  done

  _git_stash_context_capture "none" || {
    _git_error "Unable to capture repository context for stash deletion."
    return 1
  }
  snapshot=("${reply[@]}")

  _git_header "Drop Stashes"
  _git_stash_show_context snapshot
  _git_blank
  _git_table $'#\tStash\tOID\tMessage' "${plan_rows[@]}"
  _git_warn "Dropped stashes leave the stash list; only their object IDs can recover them."

  local -i stash_count=$(( ${#selected_fields[@]} / 4 ))
  _git_count_noun "$stash_count" stash stashes
  local planned="$REPLY"
  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: $planned planned; nothing was dropped."
    return 0
  fi

  _git_confirm_plan "$assume_yes" "Drop $planned?" \
    "Cancelled: nothing was dropped." || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0
  _git_stash_require_same_context snapshot "none" "" "yes" || return 1

  _git_blank
  local -i passed_count=0
  local -i failed_count=0
  local stash_oid=""
  local stash_label=""
  local current_selector=""
  for (( field_index = 1; field_index <= ${#selected_fields[@]}; field_index += 4 )); do
    stash_oid="${selected_fields[field_index]}"
    stash_label="${selected_fields[field_index + 1]} (${stash_oid[1,12]})"
    if ! _git_stash_identity_matches snapshot; then
      (( failed_count++ ))
      _git_error "Repository identity or HEAD changed; skipped $stash_label."
      continue
    fi
    if ! _git_stash_find_selector "$stash_oid"; then
      (( failed_count++ ))
      continue
    fi
    current_selector="$REPLY"

    command git -C "${snapshot[1]}" stash drop --quiet "$current_selector" >&2
    local -i command_code=$?
    if (( command_code == 130 || command_code == 143 )); then
      (( failed_count++ ))
      _git_error "Dropping $stash_label was interrupted (exit $command_code)."
      if _git_stash_contains_oid "$stash_oid"; then
        if (( REPLY == 0 )); then
          _git_warn "The interrupted stash is no longer in the stash list."
        else
          _git_info "The interrupted stash is still in the stash list."
        fi
      else
        _git_warn "The interrupted stash could not be rechecked; inspect the stash list."
      fi
      local -a pending_labels=()
      local -i pending_index=0
      for (( pending_index = field_index + 4; pending_index <= ${#selected_fields[@]}; pending_index += 4 )); do
        pending_labels+=(
          "${selected_fields[pending_index + 1]} (${selected_fields[pending_index][1,12]})"
        )
      done
      local pending_label=""
      for pending_label in "${pending_labels[@]}"; do
        _git_outcome_line "$pending_label" not-run
      done
      _git_warn \
        "Drop interrupted: $passed_count dropped, $failed_count failed, ${#pending_labels[@]} not run."
      return "$command_code"
    fi
    _git_stash_contains_oid "$stash_oid" || {
      (( failed_count++ ))
      _git_error "Unable to verify that $stash_label was dropped."
      continue
    }
    if (( command_code == 0 && REPLY == 0 )); then
      (( passed_count++ ))
      _git_success "Dropped $stash_label."
      continue
    fi

    (( failed_count++ ))
    if (( REPLY == 0 )); then
      _git_error \
        "Git reported a failure, but $stash_label is no longer in the stash list."
    else
      _git_error "Failed to drop $stash_label; it remains in the stash list."
    fi
  done

  if (( failed_count == 0 )); then
    _git_count_noun "$passed_count" stash stashes
    _git_success "Drop completed: $REPLY dropped."
    return 0
  fi
  _git_count_noun "$stash_count" stash stashes
  if (( passed_count > 0 )); then
    _git_error "Drop completed with partial failures: $failed_count of $REPLY failed."
    _git_mark_partial
  else
    _git_error "Drop failed: $failed_count of $REPLY failed."
  fi
  return 1
}

# --- Apply and pop ------------------------------------------------------------

_git_stash_apply_one() {
  emulate -L zsh

  local stash_oid="$1"
  local pop_after_apply="$2"
  local dry_run="$3"
  local assume_yes="$4"
  local -a object_fields=()
  local -a target_paths=()
  local -a snapshot=()
  local -a unmerged_paths=()
  local -a reply=()
  local REPLY=""

  _git_stash_contains_oid "$stash_oid" || return 1
  (( REPLY == 1 )) || {
    _git_error "Stash identity is missing or ambiguous: ${stash_oid[1,12]}"
    return 1
  }
  _git_stash_find_selector "$stash_oid" || return 1
  local stash_selector="$REPLY"
  local stash_subject=""
  stash_subject=$(command git log -1 --format='%s' "$stash_oid" 2>/dev/null) ||
    stash_subject=""
  _git_stash_object_paths "$stash_oid" || return 1
  object_fields=("${reply[@]}")
  _git_stash_paths_from_pairs object_fields || return 1
  target_paths=("${reply[@]}")
  _git_stash_context_capture "obstacles" target_paths || {
    _git_error "Unable to capture repository state for the stash."
    return 1
  }
  snapshot=("${reply[@]}")

  if [[ "$pop_after_apply" == "yes" ]]; then
    _git_header "Pop Stash"
  else
    _git_header "Apply Stash"
  fi
  _git_stash_show_context snapshot
  _git_label "Stash:" "$stash_selector (${stash_oid[1,12]})"
  _git_label "Message:" "$stash_subject"
  _git_stash_show_pairs_table object_fields
  _git_stash_require_clear_targets target_paths "apply a stash" || return 1
  _git_stash_require_same_context \
    snapshot "obstacles" target_paths "yes" || return 1
  _git_warn "Git merges these changes into the working tree; conflicts are possible."
  [[ "$pop_after_apply" == "yes" ]] &&
    _git_dim "The stash is dropped only after a successful apply."

  _git_count_noun "$(( ${#object_fields[@]} / 2 ))" file
  local planned="$REPLY"
  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: $planned planned; nothing was applied."
    return 0
  fi

  local prompt_text="Apply $stash_selector and keep it?"
  [[ "$pop_after_apply" == "yes" ]] &&
    prompt_text="Apply $stash_selector and drop it?"
  _git_confirm_plan "$assume_yes" "$prompt_text" \
    "Cancelled: nothing was applied." || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0
  _git_stash_require_same_context \
    snapshot "obstacles" target_paths "yes" || return 1
  _git_stash_require_clear_targets target_paths "apply a stash" || return 1

  _git_stash_find_selector "$stash_oid" || return 1
  local selector_before="$REPLY"

  command git -C "${snapshot[1]}" stash apply --quiet "$stash_oid" >&2
  local -i command_code=$?
  if (( command_code != 0 )); then
    _git_error "Applying $selector_before failed (exit $command_code)."
    _git_stash_state_fingerprint \
      "${snapshot[1]}" "obstacles" target_paths || return "$command_code"
    if [[ "$REPLY" != "${snapshot[6]}" ]]; then
      _git_warn "The failed apply changed the index or working tree; resolve it before retrying."
    fi
    if _git_stash_collect_unmerged_paths; then
      unmerged_paths=("${reply[@]}")
      if (( ${#unmerged_paths[@]} > 0 )); then
        _git_warn "Conflicted paths after the failed apply:"
        local unmerged_path=""
        for unmerged_path in "${unmerged_paths[@]}"; do
          _git_dim "${(V)unmerged_path}"
        done
      fi
    fi
    _git_stash_contains_oid "$stash_oid" || return "$command_code"
    if (( REPLY > 0 )); then
      _git_info "The stash is still in the stash list."
    else
      _git_warn "The stash is no longer in the stash list."
    fi
    return "$command_code"
  fi

  _git_stash_identity_matches snapshot || {
    _git_error "The stash was applied, but repository identity or HEAD changed unexpectedly."
    return 1
  }
  if [[ "$pop_after_apply" != "yes" ]]; then
    _git_stash_contains_oid "$stash_oid" || return 1
    (( REPLY == 1 )) || {
      _git_error "The stash was applied, but its retained identity changed unexpectedly."
      return 1
    }
    _git_success \
      "Applied $selector_before (${stash_oid[1,12]}): $planned restored; the stash is kept."
    _git_stash_result="done"
    return 0
  fi

  _git_stash_find_selector "$stash_oid" || {
    _git_error "The stash was applied but its identity changed; it was not dropped."
    return 1
  }
  local selector_after="$REPLY"
  if [[ "$selector_after" != "$selector_before" ]]; then
    _git_warn "The stash position changed after the apply; dropping $selector_after by its OID."
  fi

  command git -C "${snapshot[1]}" stash drop --quiet "$selector_after" >&2
  local -i drop_code=$?
  _git_stash_contains_oid "$stash_oid" || {
    _git_error "The stash was applied, but its drop could not be verified."
    return 1
  }
  if (( drop_code == 0 && REPLY == 0 )); then
    _git_success \
      "Popped $selector_before (${stash_oid[1,12]}): $planned restored and the stash dropped."
    _git_stash_result="done"
    return 0
  fi

  if (( REPLY == 0 )); then
    _git_error "The stash was applied and removed, but Git reported a drop failure (exit $drop_code)."
  else
    _git_error "The stash was applied but kept because the drop failed (exit $drop_code)."
  fi
  (( drop_code == 0 )) && return 1
  return "$drop_code"
}

# --- Branch -------------------------------------------------------------------

_git_stash_branch_one() {
  emulate -L zsh

  local stash_oid="$1"
  local branch_name="$2"
  local dry_run="$3"
  local assume_yes="$4"
  local -a object_fields=()
  local -a target_paths=()
  local -a snapshot=()
  local -a unmerged_paths=()
  local -a reply=()
  local REPLY=""

  _git_validate_branch_name "$branch_name" || {
    _git_error "Invalid Git branch name."
    return 2
  }
  _git_stash_contains_oid "$stash_oid" || return 1
  (( REPLY == 1 )) || {
    _git_error "Stash identity is missing or ambiguous: ${stash_oid[1,12]}"
    return 1
  }
  _git_stash_find_selector "$stash_oid" || return 1
  local stash_selector="$REPLY"
  _git_stash_object_paths "$stash_oid" || return 1
  object_fields=("${reply[@]}")
  _git_stash_paths_from_pairs object_fields || return 1
  target_paths=("${reply[@]}")
  _git_stash_context_capture "obstacles" target_paths || {
    _git_error "Unable to capture repository state for the stash."
    return 1
  }
  snapshot=("${reply[@]}")

  local base_oid=""
  base_oid=$(command git -C "${snapshot[1]}" \
    rev-parse --verify "${stash_oid}^1^{commit}" 2>/dev/null) || return 1

  _git_header "Create Branch From Stash"
  _git_stash_show_context snapshot
  _git_label "Stash:" "$stash_selector (${stash_oid[1,12]})"
  _git_label "New branch:" "$branch_name"
  _git_label "Branch base:" "${base_oid[1,12]}"
  _git_stash_show_pairs_table object_fields
  # The case guard runs first: on a case-insensitive file system the exact
  # lookup below would also find a branch that differs only by letter case.
  local -a stash_branch_refs=("refs/heads/$branch_name")
  _git_ref_case_guard stash_branch_refs refs/heads \
    "Choose a branch name that differs by more than letter case." || return 1
  command git -C "${snapshot[1]}" \
    show-ref --verify --quiet "refs/heads/$branch_name" && {
    _git_error "Local branch already exists: $branch_name"
    return 1
  }
  _git_stash_require_clear_targets \
    target_paths "create a stash branch" || return 1
  _git_stash_require_same_context \
    snapshot "obstacles" target_paths "yes" || return 1
  _git_warn "Success checks out the new branch and drops the stash."
  _git_dim "A conflict leaves the new branch checked out and keeps the stash."

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: 1 branch planned; nothing was created."
    return 0
  fi

  _git_confirm_plan "$assume_yes" "Create and check out $branch_name?" \
    "Cancelled: nothing was created." || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0
  _git_stash_require_same_context \
    snapshot "obstacles" target_paths "yes" || return 1
  _git_stash_require_clear_targets \
    target_paths "create a stash branch" || return 1
  _git_ref_case_guard stash_branch_refs refs/heads \
    "Choose a branch name that differs by more than letter case." || return 1
  command git -C "${snapshot[1]}" \
    show-ref --verify --quiet "refs/heads/$branch_name" && {
    _git_error "The branch appeared after confirmation; refusing to overwrite it."
    return 1
  }

  _git_stash_find_selector "$stash_oid" || return 1
  local current_selector="$REPLY"
  _git_run_captured "git stash branch ${(V)branch_name} $current_selector" \
    command git -C "${snapshot[1]}" stash branch \
    "$branch_name" "$current_selector"
  local -i command_code=$?

  local branch_oid=""
  local current_ref=""
  branch_oid=$(command git -C "${snapshot[1]}" rev-parse \
    --verify "refs/heads/${branch_name}^{commit}" 2>/dev/null) ||
    branch_oid=""
  current_ref=$(command git -C "${snapshot[1]}" symbolic-ref -q HEAD 2>/dev/null) ||
    current_ref="DETACHED"
  _git_stash_contains_oid "$stash_oid" || REPLY="-1"
  local -i stash_matches=$REPLY

  if (( command_code == 0 )) &&
    [[ -n "$branch_oid" \
      && "$current_ref" == "refs/heads/$branch_name" ]] &&
    (( stash_matches == 0 )); then
    _git_success \
      "Created and checked out $branch_name from $stash_selector; the stash was dropped."
    _git_stash_result="done"
    return 0
  fi

  _git_error "The stash branch did not reach the complete expected state (exit $command_code)."
  if [[ -n "$branch_oid" ]]; then
    _git_warn "The local branch exists at ${branch_oid[1,12]}."
  else
    _git_info "The requested local branch was not created."
  fi
  if [[ "$current_ref" == refs/heads/* ]]; then
    _git_warn "Current branch after the operation: ${current_ref#refs/heads/}"
  else
    _git_warn "HEAD is detached after the operation."
  fi
  if (( stash_matches > 0 )); then
    _git_info "The stash is still in the stash list."
  else
    _git_warn "The stash is no longer in the stash list."
  fi
  if _git_stash_collect_unmerged_paths; then
    unmerged_paths=("${reply[@]}")
    local unmerged_path=""
    for unmerged_path in "${unmerged_paths[@]}"; do
      _git_dim "Conflicted: ${(V)unmerged_path}"
    done
  fi

  (( command_code == 0 )) && return 1
  return "$command_code"
}

_git_stash_branch_interactive() {
  emulate -L zsh

  local stash_oid="$1"
  local dry_run="$2"
  local assume_yes="$3"

  _git_read_line "New branch name: " || return 1
  local branch_name="$REPLY"
  [[ -n "$branch_name" ]] || {
    _git_info "Cancelled: nothing was created."
    return 0
  }
  _git_stash_branch_one \
    "$stash_oid" "$branch_name" "$dry_run" "$assume_yes"
}

# --- Public manager -----------------------------------------------------------

_git_stash_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  git-stash [--dry-run|-y|--yes]"
  print -u2 -r -- \
    "  git-stash save [-u|--include-untracked|--keep-index] [-m|--message TEXT]"
  print -u2 -r -- "                 [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-stash apply [TARGET] [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-stash pop [TARGET] [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-stash drop TARGET... [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-stash branch TARGET NAME [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-stash --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Without an action, open the stash manager: save current changes, or choose a"
  print -u2 -r -- \
    "stash to apply, pop, inspect, branch from, or drop. Tab marks several to drop."
  print -u2 -r -- \
    "TARGET is a full stash OID or a current stash@{N}; apply and pop default to stash@{0}."
  print -u2 -r -- "'create' is accepted as another name for 'save'."
  print -u2 -r -- \
    "  -u, --include-untracked  Also save untracked, non-ignored files."
  print -u2 -r -- \
    "  --keep-index             Keep staged changes in the working tree after saving."
  print -u2 -r -- "  -m, --message TEXT       Record a stash message."
  print -u2 -r -- \
    "  --dry-run                Show the exact plan without changing anything."
  print -u2 -r -- "  -y, --yes                Bypass only the final confirmation."
}

# The stash manager is stateful: it refreshes the list after a view, a drop,
# or a cancelled action, and returns once changes were saved or restored.
_git_stash_interactive() {
  emulate -L zsh

  local dry_run="$1"
  local assume_yes="$2"
  local REPLY=""

  _git_check_cmd fzf || {
    _git_error "fzf is required for the interactive stash manager."
    return 1
  }

  local color_mode="never"
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]] && color_mode="always"
  # A constant read-only program: fzf quotes the key field, and only a
  # hexadecimal object ID reaches the diff commands.
  local preview_program='key={2}; case "$key" in'
  preview_program+=" save) changes=\$(git --no-optional-locks --no-pager -c color.status=${color_mode} status --short --untracked-files=all);"
  preview_program+=' if [ -n "$changes" ]; then printf "%s\n" "$changes"; else printf "No local changes to save.\n"; fi ;;'
  preview_program+=' *[!0-9a-f]*|"") ;;'
  preview_program+=" *) git --no-pager diff --stat --summary --no-ext-diff --no-textconv --color=${color_mode} \"\$key^1\" \"\$key\" --;"
  preview_program+=' if git cat-file -e "$key^3^{commit}" 2>/dev/null; then printf "\nUntracked files:\n"; git --no-pager ls-tree -r --name-only "$key^3"; fi ;;'
  preview_program+=' esac'
  local -a picker_options=(
    "--preview=${preview_program}"
    --height=80%
    '--preview-window=right:50%:wrap,<120(down:8:wrap)'
    '--bind=ctrl-/:toggle-preview'
  )

  while true; do
    local -a stash_fields=()
    local -a picker_rows=()
    local -a selected_ids=()
    local -a stash_ids=()
    local -a selected_fields=()
    local -a reply=()
    local -a change_records=()
    _git_stash_result=""

    _git_stash_collect || {
      _git_error "Unable to collect stashes."
      return 1
    }
    stash_fields=("${reply[@]}")
    _git_capture_nul status --porcelain=v1 -z --untracked-files=all --no-renames || {
      _git_error "Unable to inspect local changes."
      return 1
    }
    change_records=("${reply[@]}")
    local -i change_count=${#change_records[@]}

    local save_label="Save current changes"
    if (( change_count > 0 )); then
      _git_count_noun "$change_count" file
      save_label+=" ($REPLY)"
    else
      save_label+=" (nothing to save)"
    fi
    picker_rows+=("1"$'\t'"save"$'\t'"$save_label")
    local -i field_index=0
    local -i row_id=1
    for (( field_index = 1; field_index <= ${#stash_fields[@]}; field_index += 4 )); do
      (( row_id++ ))
      picker_rows+=(
        "$row_id"$'\t'"${stash_fields[field_index]}"$'\t'"${stash_fields[field_index + 1]}  ${(V)stash_fields[field_index + 2]}  (${(V)stash_fields[field_index + 3]})"
      )
    done

    local branch_name=""
    branch_name=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) ||
      branch_name="detached"
    local repo_root=""
    repo_root=$(command git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
    local header_text="Repository: ${(V)${repo_root:t}} | Branch: ${(V)branch_name}"
    header_text+=" | Changes: $change_count | Stashes: $(( ${#stash_fields[@]} / 4 ))"
    header_text+=$'\n''Type to filter | Enter choose | Esc cancel | Ctrl-/ details'
    header_text+=$'\n''Tab mark several stashes to drop them together'

    _git_select_ids "git stash" "$header_text" 3 yes \
      picker_rows picker_options || return 1
    selected_ids=("${reply[@]}")
    (( ${#selected_ids[@]} > 0 )) || return 0

    if (( ${selected_ids[(Ie)1]} )); then
      if (( ${#selected_ids[@]} > 1 )); then
        _git_error "Saving cannot be combined with marked stashes."
        continue
      fi
      _git_stash_save_interactive "$dry_run" "$assume_yes" || return $?
      [[ "$_git_stash_result" == "done" ]] && return 0
      continue
    fi

    local selected_id=""
    for selected_id in "${selected_ids[@]}"; do
      stash_ids+=("$(( selected_id - 1 ))")
    done
    _git_stash_fields_for_ids stash_fields stash_ids || return 1
    selected_fields=("${reply[@]}")

    if (( ${#stash_ids[@]} > 1 )); then
      _git_stash_drop_selected selected_fields "$dry_run" "$assume_yes" ||
        return $?
      continue
    fi

    local stash_oid="${selected_fields[1]}"
    local stash_selector="${selected_fields[2]}"
    local -a action_rows=(
      "Apply Stash"$'\t'"apply"$'\t'"Restore these changes to the working tree and keep the stash."
      "Pop Stash"$'\t'"pop"$'\t'"Restore these changes, then drop the stash when the apply succeeds."
      "Show Stash Diff"$'\t'"diff"$'\t'"Page the complete diff of the stash, including untracked files."
      "Browse Stash Files"$'\t'"files"$'\t'"Choose one file in the stash and page its diff."
      "Create Branch From Stash"$'\t'"branch"$'\t'"Check out a new branch at the stash's base commit with its changes."
      "Drop Stash"$'\t'"drop"$'\t'"Delete this stash after reviewing it."
    )
    local context_text="Stash: ${stash_selector} | Branch: ${(V)branch_name}"
    context_text+=" | Changes: $change_count"
    _git_select_action "$stash_selector" "$context_text" "${action_rows[@]}" ||
      return $?
    local chosen_action="$REPLY"

    case "$chosen_action" in
      "")
        continue
        ;;
      apply)
        _git_stash_apply_one "$stash_oid" "no" "$dry_run" "$assume_yes" ||
          return $?
        ;;
      pop)
        _git_stash_apply_one "$stash_oid" "yes" "$dry_run" "$assume_yes" ||
          return $?
        ;;
      diff)
        _git_stash_page_full "$stash_oid" || return $?
        ;;
      files)
        _git_stash_browse_files "$stash_oid" "$stash_selector" || return $?
        ;;
      branch)
        _git_stash_branch_interactive "$stash_oid" "$dry_run" "$assume_yes" ||
          return $?
        ;;
      drop)
        _git_stash_drop_selected selected_fields "$dry_run" "$assume_yes" ||
          return $?
        ;;
      *)
        _git_error "Invalid stash action."
        return 1
        ;;
    esac
    [[ "$_git_stash_result" == "done" ]] && return 0
  done
}

git-stash() {
  emulate -L zsh
  local REPLY=""
  # Git lists root-relative paths but resolves pathspecs from the current
  # directory; run from the repository root so both always agree.
  if _git_path_command_needs_root; then
    ( builtin cd -q -- "$REPLY" || exit 1; git-stash "$@" )
    return $?
  fi

  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _git_stash_usage
    return 0
  fi

  local action_name=""
  local dry_run="no"
  local assume_yes="no"
  local include_untracked="no"
  local keep_index="no"
  local stash_message=""
  local message_supplied="no"
  local -a positionals=()
  # Set by actions after they save or restore changes; read by the manager.
  local _git_stash_result=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        _git_error "--help does not accept additional arguments."
        return 2
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
      -u|--include-untracked)
        [[ "$include_untracked" == "no" ]] || {
          _git_error "Duplicate option: --include-untracked"
          return 2
        }
        include_untracked="yes"
        ;;
      --keep-index)
        [[ "$keep_index" == "no" ]] || {
          _git_error "Duplicate option: --keep-index"
          return 2
        }
        keep_index="yes"
        ;;
      -m|--message)
        [[ "$message_supplied" == "no" ]] || {
          _git_error "Duplicate option: --message"
          return 2
        }
        shift
        (( $# > 0 )) || {
          _git_error "--message requires text."
          return 2
        }
        [[ "$1" != (--dry-run|-y|--yes|-u|--include-untracked|--keep-index|-m|--message|-h|--help) ]] || {
          _git_error "--message requires text before the next option."
          return 2
        }
        [[ "$1" != *[$'\n\r']* ]] || {
          _git_error "--message must be one line."
          return 2
        }
        stash_message="$1"
        message_supplied="yes"
        ;;
      --)
        shift
        positionals+=("$@")
        break
        ;;
      -*)
        _git_error "Unknown option for git-stash: $1"
        _git_stash_usage
        return 2
        ;;
      *)
        if [[ -z "$action_name" ]]; then
          action_name="$1"
        else
          positionals+=("$1")
        fi
        ;;
    esac
    shift
  done

  [[ "$dry_run" == "yes" && "$assume_yes" == "yes" ]] && {
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  }
  [[ "$include_untracked" == "yes" && "$keep_index" == "yes" ]] && {
    _git_error "--include-untracked and --keep-index cannot be combined."
    return 2
  }
  [[ "$action_name" == "create" ]] && action_name="save"

  if [[ -z "$action_name" ]]; then
    if (( ${#positionals[@]} > 0 )) ||
      [[ "$include_untracked" == "yes" \
        || "$keep_index" == "yes" \
        || "$message_supplied" == "yes" ]]; then
      _git_error "Save options require the explicit 'save' action."
      return 2
    fi
    _git_require_repo || return 1
    _git_stash_interactive "$dry_run" "$assume_yes"
    return $?
  fi

  [[ "$action_name" == (save|apply|pop|drop|branch) ]] || {
    _git_error "Unknown git-stash action: $action_name"
    _git_stash_usage
    return 2
  }
  if [[ "$action_name" != "save" ]] &&
    [[ "$include_untracked" == "yes" \
      || "$keep_index" == "yes" \
      || "$message_supplied" == "yes" ]]; then
    _git_error "Save options are valid only with 'git-stash save'."
    return 2
  fi
  case "$action_name" in
    save)
      (( ${#positionals[@]} == 0 )) || {
        _git_error "git-stash save does not accept positional arguments."
        return 2
      }
      ;;
    apply|pop)
      (( ${#positionals[@]} <= 1 )) || {
        _git_error "git-stash $action_name accepts at most one TARGET."
        return 2
      }
      ;;
    drop)
      (( ${#positionals[@]} > 0 )) || {
        _git_error "git-stash drop requires at least one TARGET."
        return 2
      }
      ;;
    branch)
      (( ${#positionals[@]} == 2 )) || {
        _git_error "git-stash branch requires TARGET and NAME."
        return 2
      }
      _git_validate_branch_name "${positionals[2]}" || {
        _git_error "Invalid Git branch name."
        return 2
      }
      ;;
  esac

  _git_require_repo || return 1

  local -a selected_fields=()
  local -a target_tokens=()
  local -a reply=()
  case "$action_name" in
    save)
      local save_mode="tracked"
      [[ "$include_untracked" == "yes" ]] && save_mode="untracked"
      [[ "$keep_index" == "yes" ]] && save_mode="keep-index"
      _git_stash_save \
        "$save_mode" "$stash_message" "$dry_run" "$assume_yes"
      ;;
    apply|pop)
      if (( ${#positionals[@]} == 0 )); then
        _git_stash_collect || return 1
        (( ${#reply[@]} > 0 )) || {
          _git_info "There are no stashes."
          return 0
        }
        target_tokens=("${reply[2]}")
      else
        target_tokens=("${positionals[1]}")
      fi
      _git_stash_resolve_targets target_tokens || return $?
      selected_fields=("${reply[@]}")
      if [[ "$action_name" == "pop" ]]; then
        _git_stash_apply_one \
          "${selected_fields[1]}" "yes" "$dry_run" "$assume_yes"
      else
        _git_stash_apply_one \
          "${selected_fields[1]}" "no" "$dry_run" "$assume_yes"
      fi
      ;;
    drop)
      target_tokens=("${positionals[@]}")
      _git_stash_resolve_targets target_tokens || return $?
      selected_fields=("${reply[@]}")
      _git_stash_drop_selected selected_fields "$dry_run" "$assume_yes"
      ;;
    branch)
      target_tokens=("${positionals[1]}")
      _git_stash_resolve_targets target_tokens || return $?
      selected_fields=("${reply[@]}")
      _git_stash_branch_one \
        "${selected_fields[1]}" "${positionals[2]}" \
        "$dry_run" "$assume_yes"
      ;;
  esac
}

typeset -g _GIT_STASH_SOURCED=1
