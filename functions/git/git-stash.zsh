#!/usr/bin/env zsh
# =============================================================================
# Git Stash: identity-safe stash creation, inspection, apply, pop, and deletion
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_STASH_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Private stash records ----------------------------------------------------

_git_stash_capture_nul_at() {
  emulate -L zsh
  setopt localoptions no_aliases

  local repo_root="$1"
  shift
  local temp_dir=""
  local records_file=""
  local record=""
  local -i command_code=0
  reply=()

  temp_dir=$(command mktemp -d "${TMPDIR:-/tmp}/zdx-git-stash.XXXXXX") || {
    _git_error "Unable to create a private temporary directory."
    return 1
  }
  records_file="$temp_dir/records"

  {
    command git --literal-pathspecs -C "$repo_root" "$@" >| "$records_file"
    command_code=$?
    if (( command_code == 0 )); then
      while IFS= read -r -d '' record; do
        reply+=("$record")
      done < "$records_file"

      if [[ -n "$record" ]]; then
        _git_error "Git returned a malformed unterminated record."
        command_code=1
      fi
    fi
  } always {
    command rm -f -- "$records_file" 2>/dev/null
    command rmdir -- "$temp_dir" 2>/dev/null
  }

  return command_code
}

_git_stash_capture_nul() {
  emulate -L zsh

  local repo_root=""
  repo_root=$(command git rev-parse \
    --path-format=absolute --show-toplevel 2>/dev/null) || {
    _git_error "Unable to resolve the Git worktree root."
    return 1
  }
  _git_stash_capture_nul_at "${repo_root:A}" "$@"
}

_git_stash_collect() {
  emulate -L zsh

  local -a raw_records=()
  local raw_record=""
  local stash_oid=""
  local remaining=""
  local stash_selector=""
  local stash_subject=""
  local stash_age=""

  _git_stash_capture_nul \
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
      _git_error "Unsupported special file in planned stash scope: $(_git_display_escape "$file_name")"
      return 1
    else
      _git_error "A planned stash path disappeared while it was fingerprinted."
      return 1
    fi
  done
}

_git_stash_filter_obstacles() {
  emulate -L zsh

  local candidates_name="$1"
  local targets_name="$2"
  local -a candidate_paths=("${(@P)candidates_name}")
  local -a target_paths=("${(@P)targets_name}")
  local -a obstacles=()
  local candidate_path=""
  local target_path=""

  for candidate_path in "${candidate_paths[@]}"; do
    candidate_path="${candidate_path%/}"
    [[ -n "$candidate_path" ]] || continue
    for target_path in "${target_paths[@]}"; do
      if [[ "$candidate_path" == "$target_path" \
        || "$candidate_path" == "$target_path"/* \
        || "$target_path" == "$candidate_path"/* ]]; then
        (( ${obstacles[(Ie)$candidate_path]} == 0 )) &&
          obstacles+=("$candidate_path")
        break
      fi
    done
  done

  reply=("${obstacles[@]}")
}

_git_stash_current_obstacles() {
  emulate -L zsh

  local targets_name="$1"
  local -a untracked_paths=()
  local -a ignored_paths=()
  local -a untracked_obstacles=()
  local -a ignored_obstacles=()

  _git_stash_capture_nul \
    ls-files --others --exclude-standard -z -- || return 1
  untracked_paths=("${reply[@]}")
  _git_stash_capture_nul \
    ls-files --others --ignored --exclude-standard -z -- || return 1
  ignored_paths=("${reply[@]}")

  _git_stash_filter_obstacles untracked_paths "$targets_name" || return 1
  untracked_obstacles=("${reply[@]}")
  _git_stash_filter_obstacles ignored_paths "$targets_name" || return 1
  ignored_obstacles=("${reply[@]}")
  reply=("${untracked_obstacles[@]}" "${ignored_obstacles[@]}")
}

_git_stash_require_clear_targets() {
  emulate -L zsh

  local targets_name="$1"
  local action_name="$2"
  local -a obstacle_paths=()

  _git_stash_current_obstacles "$targets_name" || {
    _git_error "Unable to inspect untracked and ignored stash obstacles."
    return 1
  }
  obstacle_paths=("${reply[@]}")
  (( ${#obstacle_paths[@]} == 0 )) && return 0

  _git_stash_show_paths \
    "Protected untracked or ignored obstacles" "${obstacle_paths[@]}" ||
    return 1
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
      _git_stash_capture_nul_at "$repo_root" \
        ls-files --others --exclude-standard -z -- || command_code=$?
      untracked_paths=("${reply[@]}")
    fi

    if (( command_code == 0 )) && [[ "$state_scope" == "obstacles" ]]; then
      _git_stash_capture_nul_at "$repo_root" \
        ls-files --others --ignored --exclude-standard -z -- ||
        command_code=$?
      ignored_paths=("${reply[@]}")
      if (( command_code == 0 )); then
        _git_stash_filter_obstacles untracked_paths "$targets_name" ||
          command_code=$?
        untracked_obstacles=("${reply[@]}")
      fi
      if (( command_code == 0 )); then
        _git_stash_filter_obstacles ignored_paths "$targets_name" ||
          command_code=$?
        ignored_obstacles=("${reply[@]}")
      fi
    elif [[ "$state_scope" == "untracked" ]]; then
      untracked_obstacles=("${untracked_paths[@]}")
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
  _git_error "Repository or stash state changed after planning; review and retry."
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

_git_stash_collect_create_paths() {
  emulate -L zsh

  local create_mode="$1"
  local -a unstaged_files=()
  local -a staged_files=()
  local -a untracked_files=()
  local -a file_names=()
  local file_name=""

  [[ "$create_mode" == (tracked|untracked|keep-index) ]] || {
    _git_error "Invalid stash creation mode."
    return 2
  }

  _git_stash_capture_nul \
    diff --name-only --no-renames -z -- || return 1
  unstaged_files=("${reply[@]}")
  _git_stash_capture_nul \
    diff --cached --name-only --no-renames -z -- || return 1
  staged_files=("${reply[@]}")
  if [[ "$create_mode" == "untracked" ]]; then
    _git_stash_capture_nul \
      ls-files --others --exclude-standard -z -- || return 1
    untracked_files=("${reply[@]}")
  fi

  for file_name in \
    "${unstaged_files[@]}" \
    "${staged_files[@]}" \
    "${untracked_files[@]}"; do
    [[ -n "$file_name" ]] || continue
    (( ${file_names[(Ie)$file_name]} == 0 )) && file_names+=("$file_name")
  done
  reply=("${file_names[@]}")
}

_git_stash_object_paths() {
  emulate -L zsh

  local stash_oid="$1"
  local repo_root=""
  local -a tracked_files=()
  local -a untracked_files=()
  local -a object_fields=()
  local file_name=""

  _git_validate_oid "$stash_oid" || {
    _git_error "Invalid stash object identifier."
    return 1
  }
  repo_root=$(command git rev-parse \
    --path-format=absolute --show-toplevel 2>/dev/null) || return 1
  repo_root="${repo_root:A}"
  command git -C "$repo_root" cat-file \
    -e "${stash_oid}^{commit}" 2>/dev/null || {
    _git_error "The selected stash object is no longer available."
    return 1
  }

  _git_stash_capture_nul_at "$repo_root" \
    diff --name-only --no-renames -z "${stash_oid}^1" "$stash_oid" -- ||
    return 1
  tracked_files=("${reply[@]}")

  if command git -C "$repo_root" \
    cat-file -e "${stash_oid}^3^{commit}" 2>/dev/null; then
    _git_stash_capture_nul_at "$repo_root" \
      ls-tree -r -z --name-only "${stash_oid}^3" || return 1
    untracked_files=("${reply[@]}")
  fi

  for file_name in "${tracked_files[@]}"; do
    object_fields+=("tracked" "$file_name")
  done
  for file_name in "${untracked_files[@]}"; do
    object_fields+=("untracked" "$file_name")
  done
  reply=("${object_fields[@]}")
}

_git_stash_paths_from_object_fields() {
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

_git_stash_show_paths() {
  emulate -L zsh

  local heading="$1"
  shift
  local -a file_names=("$@")
  local file_name=""
  local escaped_name=""

  _git_header "$heading"
  _git_info "Exact paths: ${#file_names[@]}"
  for file_name in "${file_names[@]}"; do
    escaped_name=$(_git_display_escape "$file_name") || return 1
    _git_dim "$escaped_name"
  done
}

_git_stash_show_object_paths() {
  emulate -L zsh

  local fields_name="$1"
  local -a object_fields=("${(@P)fields_name}")
  local escaped_name=""
  local -i field_index=0

  _git_header "Exact paths stored in the stash"
  _git_info "Exact paths: $(( ${#object_fields[@]} / 2 ))"
  for (( field_index = 1; field_index <= ${#object_fields[@]}; field_index += 2 )); do
    escaped_name=$(_git_display_escape \
      "${object_fields[field_index + 1]}") || return 1
    _git_dim "${object_fields[field_index]} $escaped_name"
  done
}

_git_stash_show_context() {
  emulate -L zsh

  local snapshot_name="$1"
  local -a snapshot=("${(@P)snapshot_name}")
  local branch_label="${snapshot[5]}"

  [[ "$branch_label" == refs/heads/* ]] &&
    branch_label="${branch_label#refs/heads/}"
  _git_info "Repository: ${snapshot[1]}"
  _git_info "Branch: $branch_label"
  _git_info "HEAD: ${snapshot[4]}"
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

  _git_stash_capture_nul \
    diff --name-only --diff-filter=U -z -- || return 1
}

_git_stash_rows() {
  emulate -L zsh

  local fields_name="$1"
  local -a stash_fields=("${(@P)fields_name}")
  local escaped_subject=""
  local escaped_age=""
  local record_subject=""
  local record_age=""
  local -i field_index=0
  local -i record_index=0
  reply=()

  (( ${#stash_fields[@]} % 4 == 0 )) || {
    _git_error "Malformed internal stash inventory."
    return 1
  }

  for (( field_index = 1; field_index <= ${#stash_fields[@]}; field_index += 4 )); do
    (( record_index++ ))
    escaped_subject=$(_git_display_escape "${stash_fields[field_index + 2]}") ||
      return 1
    escaped_age=$(_git_display_escape "${stash_fields[field_index + 3]}") ||
      return 1
    record_subject=$(_git_record_escape "$escaped_subject") || return 1
    record_age=$(_git_record_escape "$escaped_age") || return 1
    reply+=(
      "${record_index}"$'\t'"${stash_fields[field_index + 1]}"$'\t'"${record_subject}"$'\t'"${record_age}"
    )
  done
}

_git_stash_select_ids() {
  emulate -L zsh

  local prompt_text="$1"
  local header_text="$2"
  local visible_fields="$3"
  local multi_mode="$4"
  shift 4

  local -a menu_rows=("$@")
  local -a fzf_options=(
    --height=65%
    --layout=reverse
    --border=rounded
    --delimiter=$'\t'
    "--with-nth=${visible_fields}"
    "--prompt=${prompt_text} > "
    "--header=${header_text}"
  )
  [[ "$multi_mode" == "yes" ]] && fzf_options+=(--multi)

  local selected_output=""
  local -i fzf_code=0
  selected_output=$(printf '%s\n' "${menu_rows[@]}" | _git_fzf "${fzf_options[@]}")
  fzf_code=$?
  case "$fzf_code" in
    0) ;;
    1|130)
      reply=()
      return 0
      ;;
    *)
      _git_error "fzf failed while selecting stash records (exit $fzf_code)."
      return 1
      ;;
  esac

  local -a selected_rows=("${(@f)selected_output}")
  local -a selected_ids=()
  local selected_row=""
  local selected_id=""
  local -i id_number=0

  for selected_row in "${selected_rows[@]}"; do
    selected_id="${selected_row%%$'\t'*}"
    if [[ ${#selected_id} -gt 9 \
      || "$selected_id" != <-> \
      || "$selected_id" == 0* ]]; then
      _git_error "fzf returned an invalid stash identifier."
      return 1
    fi
    id_number=$(( 10#$selected_id ))
    if (( id_number < 1 || id_number > ${#menu_rows[@]} )); then
      _git_error "fzf returned an out-of-range stash identifier."
      return 1
    fi
    (( ${selected_ids[(Ie)$selected_id]} == 0 )) &&
      selected_ids+=("$selected_id")
  done

  reply=("${selected_ids[@]}")
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

_git_stash_page_git() {
  emulate -L zsh

  local repo_root=""
  repo_root=$(command git rev-parse \
    --path-format=absolute --show-toplevel 2>/dev/null) || return 1
  command git --literal-pathspecs -C "${repo_root:A}" "$@" | _git_page >&2
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

_git_stash_page_full() {
  emulate -L zsh
  setopt localoptions no_aliases

  local stash_oid="$1"
  local repo_root=""
  local empty_tree_oid=""
  local temp_dir=""
  local diff_file=""
  local -i command_code=0
  local -i pager_code=0

  repo_root=$(command git rev-parse \
    --path-format=absolute --show-toplevel 2>/dev/null) || return 1
  repo_root="${repo_root:A}"
  empty_tree_oid=$(print -rn -- "" |
    command git -C "$repo_root" hash-object -t tree --stdin 2>/dev/null) || {
    _git_error "Unable to resolve the empty Git tree."
    return 1
  }

  temp_dir=$(command mktemp -d "${TMPDIR:-/tmp}/zdx-git-stash-diff.XXXXXX") || {
    _git_error "Unable to create a private temporary directory."
    return 1
  }
  diff_file="$temp_dir/diff"

  {
    command git --literal-pathspecs -C "$repo_root" diff \
      --binary --color=always --no-ext-diff --no-textconv \
      "${stash_oid}^1" "$stash_oid" -- >| "$diff_file"
    command_code=$?

    if (( command_code == 0 )) &&
      command git -C "$repo_root" \
        cat-file -e "${stash_oid}^3^{commit}" 2>/dev/null; then
      command git --literal-pathspecs -C "$repo_root" diff \
        --binary --color=always --no-ext-diff --no-textconv \
        "$empty_tree_oid" "${stash_oid}^3" -- >> "$diff_file"
      command_code=$?
    fi

    if (( command_code == 0 )); then
      _git_page < "$diff_file" >&2
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

_git_stash_authorize() {
  emulate -L zsh

  local assume_yes="$1"
  local prompt_text="$2"
  REPLY="error"

  if [[ "$assume_yes" == "yes" ]]; then
    REPLY="authorized"
    return 0
  fi
  if [[ ! -t 0 || ! -t 2 ]]; then
    _git_error "Refusing stash mutation without a TTY; pass --yes after reviewing the plan."
    return 1
  fi
  _git_confirm_outcome "$prompt_text" || return 1
  case "$REPLY" in
    confirmed)
      REPLY="authorized"
      return 0
      ;;
    cancelled)
      _git_info "Cancelled."
      return 0
      ;;
    *)
      REPLY="error"
      return 1
      ;;
  esac
}

_git_stash_show_selected() {
  emulate -L zsh

  local fields_name="$1"
  local -a selected_fields=("${(@P)fields_name}")
  local -i field_index=0
  local escaped_subject=""

  _git_header "Exact stash targets"
  for (( field_index = 1; field_index <= ${#selected_fields[@]}; field_index += 4 )); do
    escaped_subject=$(_git_display_escape "${selected_fields[field_index + 2]}") ||
      return 1
    _git_dim "${selected_fields[field_index + 1]} ${selected_fields[field_index][1,12]} $escaped_subject"
  done
}

# --- Creation, identity-safe deletion, and browsing --------------------------

_git_stash_create() {
  emulate -L zsh

  local create_mode="$1"
  local stash_message="$2"
  local dry_run="$3"
  local assume_yes="$4"
  local state_scope="tracked"
  local scope_label=""
  local -a snapshot=()
  local -a target_paths=()
  local -a inventory_after=()
  local -a reply=()
  local REPLY=""

  case "$create_mode" in
    tracked) scope_label="Tracked index and worktree changes" ;;
    untracked)
      scope_label="Tracked and untracked changes"
      state_scope="untracked"
      ;;
    keep-index) scope_label="Tracked changes while retaining the index" ;;
    *)
      _git_error "Invalid stash creation mode."
      return 2
      ;;
  esac

  _git_stash_context_capture "$state_scope" target_paths || {
    _git_error "Unable to capture repository state for stash creation."
    return 1
  }
  snapshot=("${reply[@]}")
  _git_stash_collect_create_paths "$create_mode" || return $?
  target_paths=("${reply[@]}")
  _git_stash_require_same_context \
    snapshot "$state_scope" target_paths "yes" || return 1

  if (( ${#target_paths[@]} == 0 )); then
    _git_info "No changes match the requested stash scope; no stash was created."
    return 0
  fi

  _git_header "Create stash plan"
  _git_stash_show_context snapshot
  _git_info "Scope: $scope_label"
  [[ -n "$stash_message" ]] &&
    _git_info "A custom stash message will be recorded."
  _git_stash_show_paths "Exact paths to store" "${target_paths[@]}" || return 1

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run complete; no stash was created."
    return 0
  fi

  _git_stash_authorize "$assume_yes" \
    "Store exactly ${#target_paths[@]} path(s) in a new stash?" || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0
  _git_stash_require_same_context \
    snapshot "$state_scope" target_paths "yes" || return 1

  local -a stash_command=(
    git -C "${snapshot[1]}" stash push
  )
  [[ "$create_mode" == "untracked" ]] && stash_command+=(-u)
  [[ "$create_mode" == "keep-index" ]] && stash_command+=(--keep-index)
  [[ -n "$stash_message" ]] && stash_command+=(-m "$stash_message")

  command "${stash_command[@]}" >&2
  local -i command_code=$?

  _git_stash_inventory_summary || {
    _git_error "Unable to inspect the stash inventory after creation."
    return 1
  }
  inventory_after=("${reply[@]}")

  local -i expected_count=$(( snapshot[8] + 1 ))
  if (( command_code == 0 )) &&
    (( inventory_after[2] == expected_count )) &&
    [[ "${inventory_after[1]}" != "${snapshot[7]}" \
      && "${inventory_after[3]}" != "NONE" ]]; then
    _git_success "Created stash ${inventory_after[3][1,12]} from ${#target_paths[@]} path(s)."
    [[ "$create_mode" == "keep-index" ]] &&
      _git_info "The staged index was retained in the worktree."
    return 0
  fi

  if (( command_code == 0 )) &&
    (( inventory_after[2] == snapshot[8] )) &&
    [[ "${inventory_after[1]}" == "${snapshot[7]}" ]]; then
    _git_stash_state_fingerprint \
      "${snapshot[1]}" "$state_scope" target_paths || return 1
    if [[ "$REPLY" == "${snapshot[6]}" ]]; then
      _git_info "Git completed without creating a stash; repository state is unchanged."
      return 0
    fi
    _git_error "Git created no stash record but changed repository state; inspect the worktree and index."
    return 1
  fi

  if (( inventory_after[2] > snapshot[8] )); then
    _git_warn "A new stash record exists despite the reported failure or unexpected result."
    _git_info "Newest stash OID: ${inventory_after[3]}"
  fi
  _git_error "Stash creation did not reach the verified expected state (exit $command_code)."
  (( command_code == 0 )) && return 1
  return "$command_code"
}

_git_stash_create_interactive() {
  emulate -L zsh

  local dry_run="$1"
  local assume_yes="$2"
  local selected_mode=""
  local create_mode=""
  local stash_message=""
  local -i fzf_code=0

  selected_mode=$(printf '%s\n' \
    "Tracked changes" \
    "Tracked and untracked changes" \
    "Keep staged changes in the index" |
    _git_fzf \
      --height=25% \
      --layout=reverse \
      --border=rounded \
      --prompt="create stash > " \
      --header="Enter choose scope | Esc cancel")
  fzf_code=$?
  case "$fzf_code" in
    0) ;;
    1|130) return 0 ;;
    *)
      _git_error "fzf failed while selecting stash scope (exit $fzf_code)."
      return 1
      ;;
  esac

  case "$selected_mode" in
    "Tracked changes") create_mode="tracked" ;;
    "Tracked and untracked changes") create_mode="untracked" ;;
    "Keep staged changes in the index") create_mode="keep-index" ;;
    *)
      _git_error "Invalid stash creation selection."
      return 1
      ;;
  esac

  if [[ -t 0 && -t 2 ]]; then
    print -u2 -n -r -- "Stash message (optional): "
    IFS= read -r stash_message || {
      _git_error "Unable to read the stash message."
      return 1
    }
  else
    _git_error "Interactive stash creation requires a TTY."
    return 1
  fi

  _git_stash_create \
    "$create_mode" "$stash_message" "$dry_run" "$assume_yes"
}

_git_stash_drop_selected() {
  emulate -L zsh

  local fields_name="$1"
  local dry_run="$2"
  local assume_yes="$3"
  local -a selected_fields=("${(@P)fields_name}")
  local -a snapshot=()
  local -a reply=()
  local REPLY=""

  (( ${#selected_fields[@]} > 0 && ${#selected_fields[@]} % 4 == 0 )) || {
    _git_error "No valid stash targets were supplied for deletion."
    return 1
  }
  local -i field_index=0
  for (( field_index = 1; field_index <= ${#selected_fields[@]}; field_index += 4 )); do
    _git_stash_contains_oid "${selected_fields[field_index]}" || return 1
    if (( REPLY != 1 )); then
      _git_error \
        "Stash identity is missing or ambiguous: ${selected_fields[field_index][1,12]}"
      return 1
    fi
  done

  _git_stash_context_capture "none" || {
    _git_error "Unable to capture repository context for stash deletion."
    return 1
  }
  snapshot=("${reply[@]}")
  _git_stash_show_selected selected_fields || return 1
  _git_stash_show_context snapshot
  _git_warn "Dropping removes the selected reflog entries."

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run complete; no stashes were dropped."
    return 0
  fi

  local -i stash_count=$(( ${#selected_fields[@]} / 4 ))
  _git_stash_authorize "$assume_yes" "Drop exactly $stash_count stash(es)?" ||
    return 1
  [[ "$REPLY" == "cancelled" ]] && return 0
  _git_stash_require_same_context snapshot "none" "" "yes" || return 1

  local -i passed_count=0
  local -i failed_count=0
  local stash_oid=""
  local current_selector=""
  for (( field_index = 1; field_index <= ${#selected_fields[@]}; field_index += 4 )); do
    stash_oid="${selected_fields[field_index]}"
    if ! _git_stash_identity_matches snapshot; then
      (( failed_count++ ))
      _git_error "Repository identity or HEAD changed; skipped ${stash_oid[1,12]}."
      continue
    fi
    if ! _git_stash_find_selector "$stash_oid"; then
      (( failed_count++ ))
      continue
    fi
    current_selector="$REPLY"

    command git -C "${snapshot[1]}" stash drop "$current_selector" >&2
    local -i command_code=$?
    if (( command_code == 130 || command_code == 143 )); then
      (( failed_count++ ))
      local -i not_run=$(( (${#selected_fields[@]} - field_index - 3) / 4 ))
      _git_error "Stash drop was interrupted for ${stash_oid[1,12]} (exit $command_code)."
      if _git_stash_contains_oid "$stash_oid"; then
        if (( REPLY == 0 )); then
          _git_warn "The interrupted entry is no longer in the stash reflog."
        else
          _git_info "The interrupted entry remains in the stash reflog."
        fi
      else
        _git_warn "The interrupted entry could not be rechecked; inspect the stash list."
      fi
      _git_warn "Stash drop interrupted: $passed_count passed, $failed_count failed, $not_run not run."
      return "$command_code"
    fi
    _git_stash_contains_oid "$stash_oid" || {
      (( failed_count++ ))
      _git_error "Unable to verify deletion of ${stash_oid[1,12]}."
      continue
    }
    if (( command_code == 0 && REPLY == 0 )); then
      (( passed_count++ ))
      _git_success "Dropped ${stash_oid[1,12]}."
      continue
    fi

    (( failed_count++ ))
    if (( REPLY == 0 )); then
      _git_error \
        "Git reported failure, but ${stash_oid[1,12]} is no longer in the stash reflog."
    else
      _git_error "Failed to drop ${stash_oid[1,12]}; the entry remains."
    fi
  done

  if (( failed_count == 0 )); then
    _git_success "Dropped $passed_count stash(es)."
    return 0
  fi
  _git_error "Stash drop completed partially: $passed_count passed, $failed_count failed."
  return 1
}

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
  _git_stash_object_paths "$stash_oid" || return 1
  object_fields=("${reply[@]}")
  _git_stash_paths_from_object_fields object_fields || return 1
  target_paths=("${reply[@]}")
  _git_stash_require_clear_targets target_paths "apply a stash" || return 1
  _git_stash_context_capture "obstacles" target_paths || {
    _git_error "Unable to capture repository state for stash application."
    return 1
  }
  snapshot=("${reply[@]}")
  _git_stash_require_same_context \
    snapshot "obstacles" target_paths "yes" || return 1
  _git_stash_require_clear_targets target_paths "apply a stash" || return 1

  if [[ "$pop_after_apply" == "yes" ]]; then
    _git_header "Stash pop plan"
  else
    _git_header "Stash apply plan"
  fi
  _git_stash_show_context snapshot
  _git_info "Stash OID: $stash_oid"
  _git_stash_show_object_paths object_fields || return 1
  _git_warn "Git applies these changes with merge semantics; conflicts are possible."
  [[ "$pop_after_apply" == "yes" ]] &&
    _git_warn "The exact stash entry will be dropped only after a successful apply."

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run complete; worktree and stash list were unchanged."
    return 0
  fi

  local prompt_text="Apply stash ${stash_oid[1,12]} and retain it?"
  if [[ "$pop_after_apply" == "yes" ]]; then
    prompt_text="Apply stash ${stash_oid[1,12]} and drop it after a successful apply?"
  fi
  _git_stash_authorize "$assume_yes" "$prompt_text" || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0
  _git_stash_require_same_context \
    snapshot "obstacles" target_paths "yes" || return 1
  _git_stash_require_clear_targets target_paths "apply a stash" || return 1

  local selector_before=""
  _git_stash_find_selector "$stash_oid" || return 1
  selector_before="$REPLY"

  command git -C "${snapshot[1]}" stash apply "$stash_oid" >&2
  local -i command_code=$?
  if (( command_code != 0 )); then
    _git_error "Stash apply failed (exit $command_code)."
    _git_stash_state_fingerprint \
      "${snapshot[1]}" "obstacles" target_paths || return "$command_code"
    if [[ "$REPLY" != "${snapshot[6]}" ]]; then
      _git_warn "The failed apply changed the index or worktree; inspect and resolve it before retrying."
    fi
    _git_stash_collect_unmerged_paths && unmerged_paths=("${reply[@]}")
    (( ${#unmerged_paths[@]} > 0 )) &&
      _git_stash_show_paths "Unmerged paths after failed apply" "${unmerged_paths[@]}"
    _git_stash_contains_oid "$stash_oid" || return "$command_code"
    if (( REPLY > 0 )); then
      _git_info "The selected stash entry remains in the reflog."
    else
      _git_warn "The selected stash entry is no longer in the reflog."
    fi
    return "$command_code"
  fi

  _git_stash_identity_matches snapshot || {
    _git_error "Stash content was applied, but repository identity or HEAD changed unexpectedly."
    return 1
  }
  _git_success "Applied stash ${stash_oid[1,12]}."
  if [[ "$pop_after_apply" != "yes" ]]; then
    _git_stash_contains_oid "$stash_oid" || return 1
    (( REPLY == 1 )) || {
      _git_error "Stash content was applied, but the retained stash identity changed unexpectedly."
      return 1
    }
    return 0
  fi

  _git_stash_find_selector "$stash_oid" || {
    _git_error "Stash was applied but its identity changed; it was not dropped."
    return 1
  }
  local selector_after="$REPLY"
  if [[ "$selector_after" != "$selector_before" ]]; then
    _git_warn "Stash ordinal changed after apply; OID revalidation selected $selector_after."
  fi

  command git -C "${snapshot[1]}" stash drop "$selector_after" >&2
  local -i drop_code=$?
  _git_stash_contains_oid "$stash_oid" || {
    _git_error "Stash was applied, but its post-drop state could not be verified."
    return 1
  }
  if (( drop_code == 0 && REPLY == 0 )); then
    _git_success "Dropped the applied stash entry."
    return 0
  fi

  if (( REPLY == 0 )); then
    _git_error "Stash was applied and removed, but Git reported drop failure (exit $drop_code)."
  else
    _git_error "Stash was applied but retained because drop failed (exit $drop_code)."
  fi
  (( drop_code == 0 )) && return 1
  return "$drop_code"
}

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

  command git check-ref-format --branch "$branch_name" &>/dev/null || {
    _git_error "Invalid Git branch name."
    return 2
  }
  _git_stash_contains_oid "$stash_oid" || return 1
  (( REPLY == 1 )) || {
    _git_error "Stash identity is missing or ambiguous: ${stash_oid[1,12]}"
    return 1
  }
  _git_stash_object_paths "$stash_oid" || return 1
  object_fields=("${reply[@]}")
  _git_stash_paths_from_object_fields object_fields || return 1
  target_paths=("${reply[@]}")
  _git_stash_require_clear_targets \
    target_paths "create a stash branch" || return 1
  _git_stash_context_capture "obstacles" target_paths || {
    _git_error "Unable to capture repository state for stash branching."
    return 1
  }
  snapshot=("${reply[@]}")
  _git_stash_require_same_context \
    snapshot "obstacles" target_paths "yes" || return 1
  _git_stash_require_clear_targets \
    target_paths "create a stash branch" || return 1

  command git -C "${snapshot[1]}" \
    show-ref --verify --quiet "refs/heads/$branch_name" && {
    _git_error "Local branch already exists: $branch_name"
    return 1
  }

  _git_header "Stash branch plan"
  _git_stash_show_context snapshot
  _git_info "Stash OID: $stash_oid"
  local base_oid=""
  base_oid=$(command git -C "${snapshot[1]}" \
    rev-parse --verify "${stash_oid}^1^{commit}" 2>/dev/null) || return 1
  _git_info "Branch base: $base_oid"
  _git_info "New branch: $branch_name"
  _git_stash_show_object_paths object_fields || return 1
  _git_warn "Success switches worktrees and removes the stash entry."
  _git_warn "A conflict can leave the new branch checked out with the stash retained."

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run complete; no branch was created."
    return 0
  fi

  _git_stash_authorize "$assume_yes" "Create and switch to '$branch_name'?" ||
    return 1
  [[ "$REPLY" == "cancelled" ]] && return 0
  _git_stash_require_same_context \
    snapshot "obstacles" target_paths "yes" || return 1
  _git_stash_require_clear_targets \
    target_paths "create a stash branch" || return 1
  command git -C "${snapshot[1]}" \
    show-ref --verify --quiet "refs/heads/$branch_name" && {
    _git_error "The branch appeared after confirmation; refusing to overwrite it."
    return 1
  }

  _git_stash_find_selector "$stash_oid" || return 1
  local current_selector="$REPLY"
  command git -C "${snapshot[1]}" stash branch \
    "$branch_name" "$current_selector" >&2
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
    _git_success "Created and checked out '$branch_name' from stash ${stash_oid[1,12]}."
    return 0
  fi

  _git_error "Stash branch did not reach the complete expected state (exit $command_code)."
  if [[ -n "$branch_oid" ]]; then
    _git_warn "The local branch exists at $branch_oid."
  else
    _git_info "The requested local branch was not created."
  fi
  if [[ "$current_ref" == refs/heads/* ]]; then
    _git_warn "Current branch after the operation: ${current_ref#refs/heads/}"
  else
    _git_warn "HEAD is detached after the operation."
  fi
  if (( stash_matches > 0 )); then
    _git_info "The selected stash entry remains in the reflog."
  else
    _git_warn "The selected stash entry is no longer in the reflog."
  fi
  _git_stash_collect_unmerged_paths && unmerged_paths=("${reply[@]}")
  (( ${#unmerged_paths[@]} > 0 )) &&
    _git_stash_show_paths "Unmerged paths after stash branch" "${unmerged_paths[@]}"

  (( command_code == 0 )) && return 1
  return "$command_code"
}

_git_stash_branch_interactive() {
  emulate -L zsh

  local stash_oid="$1"
  local dry_run="$2"
  local assume_yes="$3"
  local branch_name=""

  if [[ ! -t 0 || ! -t 2 ]]; then
    _git_error "Branch-name input requires a TTY."
    return 1
  fi
  print -u2 -n -r -- "New branch name: "
  IFS= read -r branch_name || {
    _git_error "Unable to read the branch name."
    return 1
  }
  [[ -n "$branch_name" ]] || {
    _git_info "Cancelled."
    return 0
  }
  _git_stash_branch_one \
    "$stash_oid" "$branch_name" "$dry_run" "$assume_yes"
}

_git_stash_browse_files() {
  emulate -L zsh

  local stash_oid="$1"
  local repo_root=""
  local empty_tree_oid=""
  local -a object_fields=()
  local -a all_files=()
  local -a all_kinds=()
  local -a rows=()
  local -a selected_ids=()
  local -a reply=()
  local file_name=""

  _git_stash_object_paths "$stash_oid" || return 1
  object_fields=("${reply[@]}")
  local -i field_index=0
  for (( field_index = 1; field_index <= ${#object_fields[@]}; field_index += 2 )); do
    all_kinds+=("${object_fields[field_index]}")
    all_files+=("${object_fields[field_index + 1]}")
  done

  (( ${#all_files[@]} > 0 )) || {
    _git_info "The selected stash contains no files."
    return 0
  }

  local escaped_name=""
  local record_name=""
  local -i item_index=0
  for (( item_index = 1; item_index <= ${#all_files[@]}; item_index++ )); do
    escaped_name=$(_git_display_escape "${all_files[item_index]}") || return 1
    record_name=$(_git_record_escape "$escaped_name") || return 1
    rows+=(
      "${item_index}"$'\t'"${all_kinds[item_index]}"$'\t'"${record_name}"
    )
  done

  _git_stash_select_ids \
    "stash files" \
    "Enter page object diff | No live file preview | Esc cancel" \
    "2,3" "no" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0

  item_index=$(( 10#${selected_ids[1]} ))
  file_name="${all_files[item_index]}"
  repo_root=$(command git rev-parse \
    --path-format=absolute --show-toplevel 2>/dev/null) || return 1
  repo_root="${repo_root:A}"
  command git -C "$repo_root" \
    cat-file -e "${stash_oid}^{commit}" 2>/dev/null || {
    _git_error "The selected stash object is no longer available."
    return 1
  }

  if [[ "${all_kinds[item_index]}" == "untracked" ]]; then
    empty_tree_oid=$(print -rn -- "" |
      command git -C "$repo_root" hash-object -t tree --stdin 2>/dev/null) ||
      return 1
    _git_stash_page_git \
      diff --color=always --no-ext-diff --no-textconv \
      "$empty_tree_oid" "${stash_oid}^3" -- "$file_name"
  else
    _git_stash_page_git \
      diff --color=always --no-ext-diff --no-textconv \
      "${stash_oid}^1" "$stash_oid" -- "$file_name"
  fi
}

# --- Public manager -----------------------------------------------------------

_git_stash_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  git-stash [--dry-run] [--yes]"
  print -u2 -r -- "  git-stash create [--include-untracked|--keep-index] [--message TEXT] [--dry-run] [--yes]"
  print -u2 -r -- "  git-stash apply TARGET [--dry-run] [--yes]"
  print -u2 -r -- "  git-stash pop TARGET [--dry-run] [--yes]"
  print -u2 -r -- "  git-stash drop TARGET... [--dry-run] [--yes]"
  print -u2 -r -- "  git-stash branch TARGET NAME [--dry-run] [--yes]"
  print -u2 -r -- "  git-stash --help"
  print -u2 -r -- ""
  print -u2 -r -- "Without an action, open the interactive stash manager."
  print -u2 -r -- "TARGET is a full stash OID or a current stash@{N} selector."
  print -u2 -r -- "  --dry-run           Show the exact plan without changing repository state."
  print -u2 -r -- "  --yes               Bypass only the final mutation confirmation."
  print -u2 -r -- "  --include-untracked Include untracked, non-ignored files in a new stash."
  print -u2 -r -- "  --keep-index        Retain staged changes in the index after creating a stash."
  print -u2 -r -- "  --message TEXT      Record a custom stash message."
}

_git_stash_interactive() {
  emulate -L zsh

  local dry_run="$1"
  local assume_yes="$2"
  local REPLY=""

  _git_check_cmd fzf || {
    _git_error "fzf is required for the interactive stash manager."
    return 1
  }

  while true; do
    local -a stash_fields=()
    local -a rows=()
    local -a selected_ids=()
    local -a selected_fields=()
    local -a reply=()

    _git_stash_collect || {
      _git_error "Unable to collect stashes."
      return 1
    }
    stash_fields=("${reply[@]}")
    _git_stash_rows stash_fields || return 1
    rows=("${reply[@]}")

    local -i stash_count=$(( ${#stash_fields[@]} / 4 ))
    local -i create_id=$(( stash_count + 1 ))
    rows+=("${create_id}"$'\t'"create"$'\t'"Create a new stash"$'\t'"current worktree")

    _git_stash_select_ids \
      "git stash" \
      "Tab select for drop | Enter actions | Esc exit" \
      "2,3,4" "yes" "${rows[@]}" || return 1
    selected_ids=("${reply[@]}")
    (( ${#selected_ids[@]} > 0 )) || return 0

    if (( ${selected_ids[(Ie)$create_id]} > 0 )); then
      if (( ${#selected_ids[@]} != 1 )); then
        _git_error "Create cannot be combined with existing stash selections."
        continue
      fi
      _git_stash_create_interactive "$dry_run" "$assume_yes" || return $?
      continue
    fi

    _git_stash_fields_for_ids stash_fields selected_ids || return 1
    selected_fields=("${reply[@]}")

    local action=""
    local -i fzf_code=0
    action=$(printf '%s\n' \
      "Apply selected stash" \
      "Pop selected stash" \
      "Drop selected stash entries" \
      "Create branch from selected stash" \
      "Browse files in selected stash" \
      "Page full selected stash diff" \
      "Back" |
      _git_fzf \
        --height=40% \
        --layout=reverse \
        --border=rounded \
        --prompt="stash action > " \
        --header="Enter choose | Esc back")
    fzf_code=$?
    case "$fzf_code" in
      0) ;;
      1|130) continue ;;
      *)
        _git_error "fzf failed while selecting a stash action (exit $fzf_code)."
        return 1
        ;;
    esac

    [[ "$action" == "Back" ]] && continue

    if [[ "$action" != "Drop selected stash entries" \
      && ${#selected_ids[@]} -ne 1 ]]; then
      _git_error "This action requires exactly one selected stash."
      continue
    fi

    local stash_oid="${selected_fields[1]}"
    case "$action" in
      "Apply selected stash")
        _git_stash_apply_one "$stash_oid" "no" "$dry_run" "$assume_yes"
        return $?
        ;;
      "Pop selected stash")
        _git_stash_apply_one "$stash_oid" "yes" "$dry_run" "$assume_yes"
        return $?
        ;;
      "Drop selected stash entries")
        _git_stash_drop_selected selected_fields "$dry_run" "$assume_yes" ||
          return $?
        ;;
      "Create branch from selected stash")
        _git_stash_branch_interactive "$stash_oid" "$dry_run" "$assume_yes"
        return $?
        ;;
      "Browse files in selected stash")
        _git_stash_browse_files "$stash_oid" || return $?
        ;;
      "Page full selected stash diff")
        _git_stash_page_full "$stash_oid" || return $?
        ;;
      *)
        _git_error "Invalid stash action."
        return 1
        ;;
    esac
  done
}

git-stash() {
  emulate -L zsh

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
      --yes)
        [[ "$assume_yes" == "no" ]] || {
          _git_error "Duplicate option: --yes"
          return 2
        }
        assume_yes="yes"
        ;;
      --include-untracked)
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
      --message)
        [[ "$message_supplied" == "no" ]] || {
          _git_error "Duplicate option: --message"
          return 2
        }
        shift
        (( $# > 0 )) || {
          _git_error "--message requires text."
          return 2
        }
        [[ "$1" != (--dry-run|--yes|--include-untracked|--keep-index|--message|-h|--help) ]] || {
          _git_error "--message requires text before the next option."
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

  if [[ -z "$action_name" ]]; then
    if (( ${#positionals[@]} > 0 )) ||
      [[ "$include_untracked" == "yes" \
        || "$keep_index" == "yes" \
        || "$message_supplied" == "yes" ]]; then
      _git_error "Creation options require the explicit 'create' action."
      return 2
    fi
    _git_require_repo || return 1
    _git_stash_interactive "$dry_run" "$assume_yes"
    return $?
  fi

  [[ "$action_name" == (create|apply|pop|drop|branch) ]] || {
    _git_error "Unknown git-stash action: $action_name"
    _git_stash_usage
    return 2
  }
  if [[ "$action_name" != "create" ]] &&
    [[ "$include_untracked" == "yes" \
      || "$keep_index" == "yes" \
      || "$message_supplied" == "yes" ]]; then
    _git_error "Creation options are valid only with 'git-stash create'."
    return 2
  fi

  _git_require_repo || return 1

  local -a selected_fields=()
  local -a target_tokens=()
  local -a reply=()
  case "$action_name" in
    create)
      (( ${#positionals[@]} == 0 )) || {
        _git_error "git-stash create does not accept positional arguments."
        return 2
      }
      local create_mode="tracked"
      [[ "$include_untracked" == "yes" ]] && create_mode="untracked"
      [[ "$keep_index" == "yes" ]] && create_mode="keep-index"
      _git_stash_create \
        "$create_mode" "$stash_message" "$dry_run" "$assume_yes"
      ;;
    apply|pop)
      (( ${#positionals[@]} == 1 )) || {
        _git_error "git-stash $action_name requires exactly one TARGET."
        return 2
      }
      target_tokens=("${positionals[1]}")
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
      (( ${#positionals[@]} > 0 )) || {
        _git_error "git-stash drop requires at least one TARGET."
        return 2
      }
      target_tokens=("${positionals[@]}")
      _git_stash_resolve_targets target_tokens || return $?
      selected_fields=("${reply[@]}")
      _git_stash_drop_selected selected_fields "$dry_run" "$assume_yes"
      ;;
    branch)
      (( ${#positionals[@]} == 2 )) || {
        _git_error "git-stash branch requires TARGET and NAME."
        return 2
      }
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
