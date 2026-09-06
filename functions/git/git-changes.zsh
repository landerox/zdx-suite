#!/usr/bin/env zsh
# =============================================================================
# Git Changes: staging, restore, commit, verification, and history mutation
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_CHANGES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Private record and selection helpers ------------------------------------

_git_changes_capture_nul() {
  emulate -L zsh
  setopt localoptions no_aliases

  local temp_dir=""
  local records_file=""
  local record=""
  local -i command_code=0
  reply=()

  temp_dir=$(command mktemp -d "${TMPDIR:-/tmp}/zdx-git-records.XXXXXX") || {
    _git_error "Unable to create a private temporary directory."
    return 1
  }
  records_file="$temp_dir/records"

  {
    command git --literal-pathspecs "$@" >| "$records_file"
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

_git_changes_path_rows() {
  emulate -L zsh

  local -a file_names=("$@")
  local escaped_name=""
  local record_name=""
  local -i item_index=0
  reply=()

  for (( item_index = 1; item_index <= ${#file_names[@]}; item_index++ )); do
    escaped_name=$(_git_display_escape "${file_names[item_index]}") || return 1
    record_name=$(_git_record_escape "$escaped_name") || return 1
    reply+=("${item_index}"$'\t'"${record_name}")
  done
}

_git_changes_labeled_path_rows() {
  emulate -L zsh

  local -a file_names=("${(@P)1}")
  local -a file_kinds=("${(@P)2}")
  local escaped_name=""
  local record_name=""
  local record_kind=""
  local -i item_index=0
  reply=()

  for (( item_index = 1; item_index <= ${#file_names[@]}; item_index++ )); do
    escaped_name=$(_git_display_escape "${file_names[item_index]}") || return 1
    record_name=$(_git_record_escape "$escaped_name") || return 1
    record_kind=$(_git_record_escape "${file_kinds[item_index]}") || return 1
    reply+=("${item_index}"$'\t'"${record_kind}"$'\t'"${record_name}")
  done
}

_git_changes_select_ids() {
  emulate -L zsh

  local prompt_text="$1"
  local header_text="$2"
  local visible_fields="$3"
  local multi_mode="$4"
  shift 4

  local -a menu_rows=("$@")
  local -a fzf_options=(
    --height=60%
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
      _git_error "fzf failed while selecting Git records (exit $fzf_code)."
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
      _git_error "fzf returned an invalid record identifier."
      return 1
    fi

    id_number=$(( 10#$selected_id ))
    if (( id_number < 1 || id_number > ${#menu_rows[@]} )); then
      _git_error "fzf returned an out-of-range record identifier."
      return 1
    fi

    if (( ${selected_ids[(Ie)$selected_id]} == 0 )); then
      selected_ids+=("$selected_id")
    fi
  done

  reply=("${selected_ids[@]}")
}

_git_changes_values_for_ids() {
  emulate -L zsh

  local values_name="$1"
  local ids_name="$2"
  local -a source_values=("${(@P)values_name}")
  local -a source_ids=("${(@P)ids_name}")
  local selected_id=""
  local -i id_number=0
  reply=()

  for selected_id in "${source_ids[@]}"; do
    id_number=$(( 10#$selected_id ))
    if (( id_number < 1 || id_number > ${#source_values[@]} )); then
      _git_error "Selected record no longer maps to a Git object."
      return 1
    fi
    reply+=("${source_values[id_number]}")
  done
}

_git_changes_collect_commits() {
  emulate -L zsh

  local -a raw_records=()
  local raw_record=""
  local commit_oid=""
  local remaining=""
  local short_oid=""
  local subject_text=""
  reply=()

  _git_changes_capture_nul "$@" || return 1
  raw_records=("${reply[@]}")
  reply=()

  for raw_record in "${raw_records[@]}"; do
    commit_oid="${raw_record%%$'\t'*}"
    remaining="${raw_record#*$'\t'}"
    short_oid="${remaining%%$'\t'*}"
    subject_text="${remaining#*$'\t'}"

    if [[ ! "$commit_oid" =~ '^[0-9A-Fa-f]+$' ]] ||
      (( ${#commit_oid} != 40 && ${#commit_oid} != 64 )); then
      _git_error "Git returned an invalid commit identifier."
      return 1
    fi

    reply+=("$commit_oid" "$short_oid" "$subject_text")
  done
}

_git_changes_commit_rows() {
  emulate -L zsh

  local fields_name="$1"
  local -a commit_fields=("${(@P)fields_name}")
  local escaped_subject=""
  local record_subject=""
  local short_oid=""
  local -i field_index=0
  local -i record_index=0
  reply=()

  if (( ${#commit_fields[@]} % 3 != 0 )); then
    _git_error "Malformed internal commit inventory."
    return 1
  fi

  for (( field_index = 1; field_index <= ${#commit_fields[@]}; field_index += 3 )); do
    (( record_index++ ))
    short_oid="${commit_fields[field_index + 1]}"
    escaped_subject=$(_git_display_escape "${commit_fields[field_index + 2]}") || return 1
    record_subject=$(_git_record_escape "$escaped_subject") || return 1
    reply+=("${record_index}"$'\t'"${short_oid}"$'\t'"${record_subject}")
  done
}

_git_changes_commit_oids_for_ids() {
  emulate -L zsh

  local fields_name="$1"
  local ids_name="$2"
  local -a commit_fields=("${(@P)fields_name}")
  local -a selected_ids=("${(@P)ids_name}")
  local selected_id=""
  local -i record_index=0
  local -i field_index=0
  reply=()

  for selected_id in "${selected_ids[@]}"; do
    record_index=$(( 10#$selected_id ))
    field_index=$(( ((record_index - 1) * 3) + 1 ))
    if (( field_index < 1 || field_index + 2 > ${#commit_fields[@]} )); then
      _git_error "Selected commit is outside the captured inventory."
      return 1
    fi
    reply+=("${commit_fields[field_index]}")
  done
}

# --- Private repository state helpers ----------------------------------------

_git_changes_diff_fingerprint() {
  emulate -L zsh
  setopt localoptions no_aliases

  local temp_dir=""
  local state_file=""
  local fingerprint=""
  local -i command_code=0

  temp_dir=$(command mktemp -d "${TMPDIR:-/tmp}/zdx-git-state.XXXXXX") || {
    _git_error "Unable to create a private temporary directory."
    return 1
  }
  state_file="$temp_dir/state"

  {
    command git --literal-pathspecs diff \
      --binary --full-index --no-ext-diff --no-textconv -- >| "$state_file"
    command_code=$?

    if (( command_code == 0 )); then
      command git --literal-pathspecs diff --cached \
        --binary --full-index --no-ext-diff --no-textconv -- >> "$state_file"
      command_code=$?
    fi

    if (( command_code == 0 )); then
      fingerprint=$(command git hash-object -- "$state_file")
      command_code=$?
    fi
  } always {
    command rm -f -- "$state_file" 2>/dev/null
    command rmdir -- "$temp_dir" 2>/dev/null
  }

  (( command_code == 0 )) || return "$command_code"
  REPLY="$fingerprint"
}

_git_changes_path_fingerprint() {
  emulate -L zsh
  setopt localoptions no_aliases

  local file_name="$1"
  local temp_dir=""
  local state_file=""
  local fingerprint=""
  local -i command_code=0

  temp_dir=$(command mktemp -d "${TMPDIR:-/tmp}/zdx-git-path.XXXXXX") || {
    _git_error "Unable to create a private temporary directory."
    return 1
  }
  state_file="$temp_dir/state"

  {
    command git --literal-pathspecs diff \
      --binary --full-index --no-ext-diff --no-textconv -- \
      "$file_name" >| "$state_file"
    command_code=$?

    if (( command_code == 0 )); then
      fingerprint=$(command git hash-object -- "$state_file")
      command_code=$?
    fi
  } always {
    command rm -f -- "$state_file" 2>/dev/null
    command rmdir -- "$temp_dir" 2>/dev/null
  }

  (( command_code == 0 )) || return "$command_code"
  REPLY="$fingerprint"
}

_git_changes_snapshot() {
  emulate -L zsh

  local repo_root=""
  local common_dir=""
  local worktree_git_dir=""
  local head_oid=""
  local diff_fingerprint=""

  repo_root=$(command git rev-parse --path-format=absolute --show-toplevel 2>/dev/null) ||
    return 1
  common_dir=$(command git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    return 1
  worktree_git_dir=$(command git rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
    return 1

  repo_root="${repo_root:A}"
  common_dir="${common_dir:A}"
  worktree_git_dir="${worktree_git_dir:A}"

  head_oid=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
    head_oid="UNBORN"

  _git_changes_diff_fingerprint || return 1
  diff_fingerprint="$REPLY"

  reply=(
    "$repo_root"
    "$common_dir"
    "$worktree_git_dir"
    "$head_oid"
    "$diff_fingerprint"
  )
}

_git_changes_context_matches() {
  emulate -L zsh

  local expected_root="$1"
  local expected_common="$2"
  local expected_git_dir="$3"
  local expected_head="$4"
  local current_root=""
  local current_common=""
  local current_git_dir=""
  local current_head=""

  current_root=$(command git rev-parse --path-format=absolute --show-toplevel 2>/dev/null) ||
    return 1
  current_common=$(command git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    return 1
  current_git_dir=$(command git rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
    return 1
  current_head=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
    current_head="UNBORN"

  [[ "${current_root:A}" == "$expected_root" \
    && "${current_common:A}" == "$expected_common" \
    && "${current_git_dir:A}" == "$expected_git_dir" \
    && "$current_head" == "$expected_head" ]]
}

_git_changes_snapshot_matches() {
  emulate -L zsh

  local expected_root="$1"
  local expected_common="$2"
  local expected_git_dir="$3"
  local expected_head="$4"
  local expected_fingerprint="$5"

  _git_changes_context_matches \
    "$expected_root" "$expected_common" "$expected_git_dir" "$expected_head" ||
    return 1

  _git_changes_diff_fingerprint || return 1
  [[ "$REPLY" == "$expected_fingerprint" ]]
}

_git_changes_untracked_obstacles() {
  emulate -L zsh

  local targets_name="$1"
  local -a target_paths=("${(@P)targets_name}")
  local -a untracked_paths=()
  local -a ignored_paths=()
  local -a candidate_paths=()
  local -a obstacles=()
  local candidate_path=""
  local target_path=""

  _git_changes_capture_nul ls-files --others --exclude-standard -z -- ||
    return 1
  untracked_paths=("${reply[@]}")
  _git_changes_capture_nul \
    ls-files --others --ignored --exclude-standard -z -- || return 1
  ignored_paths=("${reply[@]}")

  candidate_paths=("${untracked_paths[@]}" "${ignored_paths[@]}")
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

_git_changes_authorize() {
  emulate -L zsh

  local assume_yes="$1"
  local prompt_text="$2"
  REPLY="error"

  if [[ "$assume_yes" == "yes" ]]; then
    REPLY="authorized"
    return 0
  fi

  if [[ ! -t 0 || ! -t 2 ]]; then
    _git_error "Refusing destructive work without a TTY; pass --yes after reviewing the plan."
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

_git_changes_show_paths() {
  emulate -L zsh

  local heading="$1"
  shift
  local -a file_names=("$@")
  local escaped_name=""
  local file_name=""

  _git_header "$heading"
  _git_info "Exact targets: ${#file_names[@]}"
  for file_name in "${file_names[@]}"; do
    escaped_name=$(_git_display_escape "$file_name") || return 1
    _git_dim "$escaped_name"
  done
}

_git_changes_report_results() {
  emulate -L zsh

  local action_name="$1"
  local -i passed_count="$2"
  local -i failed_count="$3"

  if (( failed_count == 0 )); then
    _git_success "$action_name completed for $passed_count target(s)."
    return 0
  fi

  _git_error "$action_name completed partially: $passed_count passed, $failed_count failed."
  return 1
}

_git_changes_require_interactive() {
  _git_require_repo || return 1
  _git_check_cmd fzf || {
    _git_error "fzf is required for this interactive command."
    return 1
  }
}

# --- Stage and unstage --------------------------------------------------------

_git_stage_usage() {
  print -u2 -r -- "Usage: git-stage [--help]"
  print -u2 -r -- "Interactively select tracked or untracked files to stage."
}

git-stage() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_stage_usage
      return 0
    fi
    _git_error "Unknown argument for git-stage: $1"
    _git_stage_usage
    return 2
  fi

  _git_changes_require_interactive || return 1

  local -a tracked_files=()
  local -a untracked_files=()
  local -a all_files=()
  local -a all_kinds=()
  local -a rows=()
  local -a selected_ids=()
  local -a selected_files=()
  local -a reply=()
  local file_name=""

  _git_changes_capture_nul diff --name-only -z -- || {
    _git_error "Unable to discover tracked worktree changes."
    return 1
  }
  tracked_files=("${reply[@]}")

  _git_changes_capture_nul ls-files --others --exclude-standard -z || {
    _git_error "Unable to discover untracked files."
    return 1
  }
  untracked_files=("${reply[@]}")

  for file_name in "${tracked_files[@]}"; do
    if (( ${all_files[(Ie)$file_name]} == 0 )); then
      all_files+=("$file_name")
      all_kinds+=("tracked")
    fi
  done
  for file_name in "${untracked_files[@]}"; do
    if (( ${all_files[(Ie)$file_name]} == 0 )); then
      all_files+=("$file_name")
      all_kinds+=("untracked")
    fi
  done

  if (( ${#all_files[@]} == 0 )); then
    _git_info "Nothing to stage; the worktree is clean."
    return 0
  fi

  _git_changes_labeled_path_rows all_files all_kinds || return 1
  rows=("${reply[@]}")
  _git_changes_select_ids \
    "git stage" \
    "Tab select | Enter stage | Esc cancel" \
    "2,3" "yes" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0

  _git_changes_values_for_ids all_files selected_ids || return 1
  selected_files=("${reply[@]}")

  local -i passed_count=0
  local -i failed_count=0
  local escaped_name=""
  for file_name in "${selected_files[@]}"; do
    escaped_name=$(_git_display_escape "$file_name") || return 1
    if command git --literal-pathspecs add -- "$file_name" >&2; then
      (( passed_count++ ))
      _git_success "Staged: $escaped_name"
    else
      (( failed_count++ ))
      _git_error "Failed to stage: $escaped_name"
    fi
  done

  _git_changes_report_results "Stage" "$passed_count" "$failed_count"
}

_git_unstage_usage() {
  print -u2 -r -- "Usage: git-unstage [--help]"
  print -u2 -r -- "Interactively select index entries to restore without changing worktree files."
}

git-unstage() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_unstage_usage
      return 0
    fi
    _git_error "Unknown argument for git-unstage: $1"
    _git_unstage_usage
    return 2
  fi

  _git_changes_require_interactive || return 1

  local -a staged_files=()
  local -a rows=()
  local -a selected_ids=()
  local -a selected_files=()
  local -a reply=()

  _git_changes_capture_nul diff --cached --name-only -z -- || {
    _git_error "Unable to discover staged files."
    return 1
  }
  staged_files=("${reply[@]}")

  if (( ${#staged_files[@]} == 0 )); then
    _git_info "Nothing is staged."
    return 0
  fi

  _git_changes_path_rows "${staged_files[@]}" || return 1
  rows=("${reply[@]}")
  _git_changes_select_ids \
    "git unstage" \
    "Tab select | Enter unstage | Esc cancel" \
    "2" "yes" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0

  _git_changes_values_for_ids staged_files selected_ids || return 1
  selected_files=("${reply[@]}")

  local head_oid=""
  head_oid=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
    head_oid="UNBORN"

  local -i passed_count=0
  local -i failed_count=0
  local file_name=""
  local escaped_name=""
  for file_name in "${selected_files[@]}"; do
    escaped_name=$(_git_display_escape "$file_name") || return 1
    if [[ "$head_oid" == "UNBORN" ]]; then
      command git --literal-pathspecs rm --cached -- "$file_name" >&2
    else
      command git --literal-pathspecs restore --staged -- "$file_name" >&2
    fi
    local -i command_code=$?

    if (( command_code == 0 )); then
      (( passed_count++ ))
      _git_success "Unstaged: $escaped_name"
    else
      (( failed_count++ ))
      _git_error "Failed to unstage: $escaped_name"
    fi
  done

  _git_changes_report_results "Unstage" "$passed_count" "$failed_count"
}

# --- Destructive restore plans -----------------------------------------------

_git_discard_usage() {
  print -u2 -r -- "Usage: git-discard [--dry-run] [--yes] [--help]"
  print -u2 -r -- "Select modified tracked files and restore their worktree content from the index."
  print -u2 -r -- "  --dry-run  Show the exact immutable plan without restoring files."
  print -u2 -r -- "  --yes      Bypass only the final confirmation."
}

git-discard() {
  emulate -L zsh

  local dry_run="no"
  local assume_yes="no"
  local REPLY=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _git_error "--help does not accept additional arguments."
          return 2
        }
        _git_discard_usage
        return 0
        ;;
      --dry-run) dry_run="yes" ;;
      --yes) assume_yes="yes" ;;
      *)
        _git_error "Unknown argument for git-discard: $1"
        _git_discard_usage
        return 2
        ;;
    esac
    shift
  done

  [[ "$dry_run" == "yes" && "$assume_yes" == "yes" ]] && {
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  }
  _git_changes_require_interactive || return 1

  local -a modified_files=()
  local -a rows=()
  local -a selected_ids=()
  local -a selected_files=()
  local -a snapshot=()
  local -a file_fingerprints=()
  local -a untracked_obstacles=()
  local -a reply=()

  _git_changes_capture_nul diff --name-only -z --diff-filter=ACDMRTUXB -- || {
    _git_error "Unable to build the discard inventory."
    return 1
  }
  modified_files=("${reply[@]}")

  if (( ${#modified_files[@]} == 0 )); then
    _git_info "No tracked worktree changes can be discarded."
    return 0
  fi

  _git_changes_path_rows "${modified_files[@]}" || return 1
  rows=("${reply[@]}")
  _git_changes_select_ids \
    "git discard" \
    "Tab select | Enter plan irreversible restore | Esc cancel" \
    "2" "yes" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0

  _git_changes_values_for_ids modified_files selected_ids || return 1
  selected_files=("${reply[@]}")

  _git_changes_snapshot || {
    _git_error "Unable to capture repository state."
    return 1
  }
  snapshot=("${reply[@]}")

  local file_name=""
  for file_name in "${selected_files[@]}"; do
    _git_changes_path_fingerprint "$file_name" || {
      _git_error "Unable to fingerprint a discard target."
      return 1
    }
    file_fingerprints+=("$REPLY")
  done

  _git_changes_show_paths "Discard plan" "${selected_files[@]}" || return 1
  _git_warn "The listed worktree changes will be permanently replaced by index content."

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run complete; no files were changed."
    return 0
  fi

  _git_changes_authorize "$assume_yes" "Discard exactly ${#selected_files[@]} file(s)?" ||
    return 1
  [[ "$REPLY" == "cancelled" ]] && return 0

  _git_changes_snapshot_matches "${snapshot[@]}" || {
    _git_error "Repository HEAD or diff changed after planning; refusing to discard."
    return 1
  }

  local -i passed_count=0
  local -i failed_count=0
  local -i item_index=0
  local escaped_name=""
  for (( item_index = 1; item_index <= ${#selected_files[@]}; item_index++ )); do
    file_name="${selected_files[item_index]}"
    escaped_name=$(_git_display_escape "$file_name") || return 1

    if ! _git_changes_context_matches \
      "${snapshot[1]}" "${snapshot[2]}" "${snapshot[3]}" "${snapshot[4]}"; then
      (( failed_count++ ))
      _git_error "Repository context changed; skipped: $escaped_name"
      continue
    fi

    _git_changes_path_fingerprint "$file_name" || {
      (( failed_count++ ))
      _git_error "Unable to revalidate: $escaped_name"
      continue
    }
    if [[ "$REPLY" != "${file_fingerprints[item_index]}" ]]; then
      (( failed_count++ ))
      _git_error "Target changed after confirmation; skipped: $escaped_name"
      continue
    fi

    if command git --literal-pathspecs restore \
      --worktree -- "$file_name" >&2; then
      (( passed_count++ ))
      _git_success "Discarded: $escaped_name"
    else
      local -i command_code=$?
      (( failed_count++ ))
      _git_error "Failed to discard: $escaped_name"
      if (( command_code == 130 || command_code == 143 )); then
        local -i not_run=$(( ${#selected_files[@]} - item_index ))
        _git_warn "Discard interrupted: $passed_count passed, $failed_count failed, $not_run not run."
        return "$command_code"
      fi
    fi
  done

  _git_changes_report_results "Discard" "$passed_count" "$failed_count"
}

_git_restore_from_usage() {
  print -u2 -r -- "Usage: git-restore-from [--source <revision>] [--dry-run] [--yes] [--help]"
  print -u2 -r -- "Restore selected worktree files from an immutable commit without changing the index."
  print -u2 -r -- "  --source   Resolve and use a specific commit instead of selecting one."
  print -u2 -r -- "  --dry-run  Show the exact plan without restoring files."
  print -u2 -r -- "  --yes      Bypass only the final confirmation."
}

git-restore-from() {
  emulate -L zsh

  local source_revision=""
  local dry_run="no"
  local assume_yes="no"
  local REPLY=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _git_error "--help does not accept additional arguments."
          return 2
        }
        _git_restore_from_usage
        return 0
        ;;
      --source)
        shift
        (( $# > 0 )) || {
          _git_error "--source requires a revision."
          return 2
        }
        source_revision="$1"
        ;;
      --dry-run) dry_run="yes" ;;
      --yes) assume_yes="yes" ;;
      *)
        _git_error "Unknown argument for git-restore-from: $1"
        _git_restore_from_usage
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

  local source_oid=""
  if [[ -n "$source_revision" ]]; then
    source_oid=$(command git rev-parse \
      --verify --end-of-options "${source_revision}^{commit}" 2>/dev/null) || {
      _git_error "Revision does not resolve to a commit."
      return 1
    }
  else
    _git_check_cmd fzf || {
      _git_error "fzf is required to select a source commit."
      return 1
    }

    local -a commit_fields=()
    local -a commit_rows=()
    local -a selected_commit_ids=()
    local -a selected_oids=()
    local -a reply=()

    _git_changes_collect_commits \
      log -z --format='%H%x09%h%x09%s' --all -n 100 || {
      _git_error "Unable to collect commit history."
      return 1
    }
    commit_fields=("${reply[@]}")
    (( ${#commit_fields[@]} > 0 )) || {
      _git_error "No commits are available."
      return 1
    }

    _git_changes_commit_rows commit_fields || return 1
    commit_rows=("${reply[@]}")
    _git_changes_select_ids \
      "restore source" \
      "Enter select commit | Esc cancel" \
      "2,3" "no" "${commit_rows[@]}" || return 1
    selected_commit_ids=("${reply[@]}")
    (( ${#selected_commit_ids[@]} > 0 )) || return 0

    _git_changes_commit_oids_for_ids commit_fields selected_commit_ids || return 1
    selected_oids=("${reply[@]}")
    source_oid="${selected_oids[1]}"
  fi

  _git_check_cmd fzf || {
    _git_error "fzf is required to select files."
    return 1
  }

  local -a source_files=()
  local -a rows=()
  local -a selected_ids=()
  local -a selected_files=()
  local -a snapshot=()
  local -a file_fingerprints=()
  local -a untracked_obstacles=()
  local -a reply=()

  _git_changes_capture_nul ls-tree -r -z --name-only "$source_oid" || {
    _git_error "Unable to enumerate files in the source commit."
    return 1
  }
  source_files=("${reply[@]}")
  (( ${#source_files[@]} > 0 )) || {
    _git_info "The selected commit contains no restorable files."
    return 0
  }

  _git_changes_path_rows "${source_files[@]}" || return 1
  rows=("${reply[@]}")
  _git_changes_select_ids \
    "restore files" \
    "Tab select | Enter plan restore | Esc cancel" \
    "2" "yes" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0

  _git_changes_values_for_ids source_files selected_ids || return 1
  selected_files=("${reply[@]}")

  _git_changes_snapshot || {
    _git_error "Unable to capture repository state."
    return 1
  }
  snapshot=("${reply[@]}")

  local file_name=""
  _git_changes_untracked_obstacles selected_files || {
    _git_error "Unable to inspect untracked restore obstacles."
    return 1
  }
  untracked_obstacles=("${reply[@]}")
  if (( ${#untracked_obstacles[@]} > 0 )); then
    _git_changes_show_paths \
      "Protected untracked restore obstacles" "${untracked_obstacles[@]}" ||
      return 1
    _git_error "Refusing to overwrite or remove untracked or ignored paths."
    return 1
  fi

  for file_name in "${selected_files[@]}"; do
    _git_changes_path_fingerprint "$file_name" || {
      _git_error "Unable to fingerprint a restore target."
      return 1
    }
    file_fingerprints+=("$REPLY")
  done

  _git_changes_show_paths "Restore plan from ${source_oid[1,12]}" \
    "${selected_files[@]}" || return 1
  _git_warn "The listed worktree paths will be replaced; the index will remain unchanged."

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run complete; no files were changed."
    return 0
  fi

  _git_changes_authorize "$assume_yes" "Restore exactly ${#selected_files[@]} file(s)?" ||
    return 1
  [[ "$REPLY" == "cancelled" ]] && return 0

  command git cat-file -e "${source_oid}^{commit}" 2>/dev/null || {
    _git_error "The selected source commit is no longer available."
    return 1
  }
  _git_changes_snapshot_matches "${snapshot[@]}" || {
    _git_error "Repository HEAD or diff changed after planning; refusing to restore."
    return 1
  }

  local -i passed_count=0
  local -i failed_count=0
  local -i item_index=0
  local escaped_name=""
  local -a current_target=()
  for (( item_index = 1; item_index <= ${#selected_files[@]}; item_index++ )); do
    file_name="${selected_files[item_index]}"
    escaped_name=$(_git_display_escape "$file_name") || return 1

    if ! _git_changes_context_matches \
      "${snapshot[1]}" "${snapshot[2]}" "${snapshot[3]}" "${snapshot[4]}"; then
      (( failed_count++ ))
      _git_error "Repository context changed; skipped: $escaped_name"
      continue
    fi

    _git_changes_path_fingerprint "$file_name" || {
      (( failed_count++ ))
      _git_error "Unable to revalidate: $escaped_name"
      continue
    }
    if [[ "$REPLY" != "${file_fingerprints[item_index]}" ]]; then
      (( failed_count++ ))
      _git_error "Target changed after confirmation; skipped: $escaped_name"
      continue
    fi

    current_target=("$file_name")
    _git_changes_untracked_obstacles current_target || {
      (( failed_count++ ))
      _git_error "Unable to revalidate untracked obstacles: $escaped_name"
      continue
    }
    if (( ${#reply[@]} > 0 )); then
      (( failed_count++ ))
      _git_error "An untracked or ignored obstacle appeared; skipped: $escaped_name"
      continue
    fi

    if command git --literal-pathspecs restore \
      --source="$source_oid" --worktree -- "$file_name" >&2; then
      (( passed_count++ ))
      _git_success "Restored: $escaped_name"
    else
      local -i command_code=$?
      (( failed_count++ ))
      _git_error "Failed to restore: $escaped_name"
      if (( command_code == 130 || command_code == 143 )); then
        local -i not_run=$(( ${#selected_files[@]} - item_index ))
        _git_warn "Restore interrupted: $passed_count passed, $failed_count failed, $not_run not run."
        return "$command_code"
      fi
    fi
  done

  _git_changes_report_results "Restore" "$passed_count" "$failed_count"
}

# --- Amend and reset ----------------------------------------------------------

_git_amend_usage() {
  print -u2 -r -- "Usage: git-amend [--help]"
  print -u2 -r -- "Interactively amend the last commit after an exact action review."
}

git-amend() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_amend_usage
      return 0
    fi
    _git_error "Unknown argument for git-amend: $1"
    _git_amend_usage
    return 2
  fi

  _git_changes_require_interactive || return 1
  local REPLY=""

  local head_oid=""
  head_oid=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
    _git_error "No commit is available to amend."
    return 1
  }

  local subject_text=""
  local author_name=""
  local author_email=""
  subject_text=$(command git show -s --format='%s' "$head_oid" 2>/dev/null) ||
    return 1
  author_name=$(command git show -s --format='%an' "$head_oid" 2>/dev/null) ||
    return 1
  author_email=$(command git show -s --format='%ae' "$head_oid" 2>/dev/null) ||
    return 1

  _git_header "Amend last commit"
  _git_label "Commit:" "$head_oid"
  _git_label "Subject:" "$subject_text"
  _git_label "Author:" "$author_name <$author_email>"

  local action=""
  local -i fzf_code=0
  action=$(printf '%s\n' \
    "Edit message only (ignore staged changes)" \
    "Add staged changes (keep message)" \
    "Add staged changes and edit message" \
    "Reset author only (ignore staged changes)" |
    _git_fzf \
      --height=30% \
      --layout=reverse \
      --border=rounded \
      --prompt="git amend > " \
      --header="Enter choose | Esc cancel")
  fzf_code=$?
  case "$fzf_code" in
    0) ;;
    1|130) return 0 ;;
    *)
      _git_error "fzf failed while selecting an amend action (exit $fzf_code)."
      return 1
      ;;
  esac

  local -a snapshot=()
  local -a reply=()
  _git_changes_snapshot || {
    _git_error "Unable to capture repository state."
    return 1
  }
  snapshot=("${reply[@]}")

  local staged_count=0
  local -a staged_files=()
  _git_changes_capture_nul diff --cached --name-only -z -- || return 1
  staged_files=("${reply[@]}")
  staged_count=${#staged_files[@]}

  case "$action" in
    "Edit message only"*)
      _git_info "Plan: rewrite only the message for ${head_oid[1,12]}; staged changes remain staged."
      ;;
    "Add staged changes (keep message)")
      (( staged_count > 0 )) || {
        _git_error "No staged changes are available to amend."
        return 1
      }
      _git_changes_show_paths "Amend staged content" "${staged_files[@]}" || return 1
      _git_info "Plan: rewrite ${head_oid[1,12]} with the same message and the staged content."
      ;;
    "Add staged changes and edit message")
      (( staged_count > 0 )) || {
        _git_error "No staged changes are available to amend."
        return 1
      }
      _git_changes_show_paths "Amend staged content" "${staged_files[@]}" || return 1
      _git_info "Plan: rewrite ${head_oid[1,12]} with a new message and the staged content."
      ;;
    "Reset author only"*)
      _git_info "Plan: rewrite only the author for ${head_oid[1,12]}; staged changes remain staged."
      ;;
    *)
      _git_error "Invalid amend action."
      return 1
      ;;
  esac

  _git_changes_authorize "no" "Amend commit ${head_oid[1,12]}?" || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0
  _git_changes_snapshot_matches "${snapshot[@]}" || {
    _git_error "Repository HEAD or diff changed after planning; refusing to amend."
    return 1
  }

  local -a amend_command=(git commit --amend)
  case "$action" in
    "Edit message only"*) amend_command+=(--only) ;;
    "Add staged changes (keep message)") amend_command+=(--no-edit) ;;
    "Add staged changes and edit message") ;;
    "Reset author only"*) amend_command+=(--only --no-edit --reset-author) ;;
  esac

  if command "${amend_command[@]}" >&2; then
    _git_success "Commit amended."
    _git_warn "If the original commit was published, use an explicit force-with-lease workflow."
    return 0
  else
    local -i command_code=$?
    _git_error "Amend failed (exit $command_code)."
    return "$command_code"
  fi
}

_git_undo_commit_usage() {
  print -u2 -r -- "Usage: git-undo-commit [--soft|--mixed|--hard] [--dry-run] [--yes] [--help]"
  print -u2 -r -- "Move the current branch from HEAD to its first parent."
  print -u2 -r -- "  --soft     Keep index and worktree changes."
  print -u2 -r -- "  --mixed    Reset the index and keep worktree changes."
  print -u2 -r -- "  --hard     Reset index and worktree, discarding listed changes."
  print -u2 -r -- "  --dry-run  Show the exact target OIDs and affected paths."
  print -u2 -r -- "  --yes      Bypass only the final confirmation."
}

git-undo-commit() {
  emulate -L zsh

  local reset_mode=""
  local dry_run="no"
  local assume_yes="no"
  local REPLY=""

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _git_error "--help does not accept additional arguments."
          return 2
        }
        _git_undo_commit_usage
        return 0
        ;;
      --soft|--mixed|--hard)
        [[ -z "$reset_mode" ]] || {
          _git_error "Choose exactly one reset mode."
          return 2
        }
        reset_mode="${1#--}"
        ;;
      --dry-run) dry_run="yes" ;;
      --yes) assume_yes="yes" ;;
      *)
        _git_error "Unknown argument for git-undo-commit: $1"
        _git_undo_commit_usage
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

  if [[ -z "$reset_mode" ]]; then
    _git_check_cmd fzf || {
      _git_error "fzf is required to select a reset mode."
      return 1
    }

    local selected_mode=""
    local -i fzf_code=0
    selected_mode=$(printf '%s\n' \
      "soft"$'\t'"Keep index and worktree" \
      "mixed"$'\t'"Reset index; keep worktree" \
      "hard"$'\t'"Discard index and worktree changes" |
      _git_fzf \
        --height=25% \
        --layout=reverse \
        --border=rounded \
        --delimiter=$'\t' \
        --with-nth=1,2 \
        --prompt="git undo > " \
        --header="Enter choose reset mode | Esc cancel")
    fzf_code=$?
    case "$fzf_code" in
      0) reset_mode="${selected_mode%%$'\t'*}" ;;
      1|130) return 0 ;;
      *)
        _git_error "fzf failed while selecting a reset mode (exit $fzf_code)."
        return 1
        ;;
    esac
  fi

  local head_oid=""
  local parent_oid=""
  head_oid=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
    _git_error "No commit is available to undo."
    return 1
  }
  parent_oid=$(command git rev-parse --verify 'HEAD^1^{commit}' 2>/dev/null) || {
    _git_error "HEAD has no first parent; refusing to reset past the initial commit."
    return 1
  }

  local -a snapshot=()
  local -a affected_files=()
  local -a target_files=()
  local -a untracked_obstacles=()
  local -a reply=()
  _git_changes_snapshot || {
    _git_error "Unable to capture repository state."
    return 1
  }
  snapshot=("${reply[@]}")

  if [[ "$reset_mode" == "hard" ]]; then
    local -a commit_files=()
    local -a worktree_files=()
    local -a index_files=()
    local file_name=""

    _git_changes_capture_nul diff --name-only -z "$parent_oid" "$head_oid" -- ||
      return 1
    commit_files=("${reply[@]}")
    _git_changes_capture_nul diff --name-only -z -- || return 1
    worktree_files=("${reply[@]}")
    _git_changes_capture_nul diff --cached --name-only -z -- || return 1
    index_files=("${reply[@]}")
    _git_changes_capture_nul ls-tree -r -z --name-only "$parent_oid" ||
      return 1
    target_files=("${reply[@]}")
    _git_changes_untracked_obstacles target_files || {
      _git_error "Unable to inspect untracked hard-reset obstacles."
      return 1
    }
    untracked_obstacles=("${reply[@]}")

    for file_name in "${commit_files[@]}" "${worktree_files[@]}" "${index_files[@]}"; do
      [[ -n "$file_name" ]] || continue
      (( ${affected_files[(Ie)$file_name]} == 0 )) && affected_files+=("$file_name")
    done
  elif [[ "$reset_mode" == "mixed" ]]; then
    _git_changes_capture_nul diff --cached --name-only -z "$parent_oid" -- ||
      return 1
    affected_files=("${reply[@]}")
  fi

  _git_header "Undo commit plan"
  _git_info "Current HEAD: $head_oid"
  _git_info "Reset target: $parent_oid"
  _git_info "Mode: $reset_mode"
  if (( ${#affected_files[@]} > 0 )); then
    _git_changes_show_paths "Affected paths" "${affected_files[@]}" || return 1
  else
    _git_info "No worktree paths will be replaced by this mode."
  fi
  [[ "$reset_mode" == "hard" ]] &&
    _git_warn "Hard reset permanently discards the listed tracked index and worktree state."
  if (( ${#untracked_obstacles[@]} > 0 )); then
    _git_changes_show_paths \
      "Protected untracked hard-reset obstacles" "${untracked_obstacles[@]}" ||
      return 1
    _git_error "Refusing a hard reset that could remove untracked or ignored paths."
    return 1
  fi

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run complete; HEAD, index, and worktree were not changed."
    return 0
  fi

  _git_changes_authorize \
    "$assume_yes" \
    "Reset ${head_oid[1,12]} to ${parent_oid[1,12]} using --${reset_mode}?" ||
    return 1
  [[ "$REPLY" == "cancelled" ]] && return 0

  _git_changes_snapshot_matches "${snapshot[@]}" || {
    _git_error "Repository HEAD or diff changed after planning; refusing to reset."
    return 1
  }
  if [[ "$reset_mode" == "hard" ]]; then
    _git_changes_untracked_obstacles target_files || {
      _git_error "Unable to revalidate untracked hard-reset obstacles."
      return 1
    }
    if (( ${#reply[@]} > 0 )); then
      _git_error "An untracked or ignored obstacle appeared; refusing to reset."
      return 1
    fi
  fi

  if command git reset "--${reset_mode}" "$parent_oid" >&2; then
    _git_success "HEAD moved to ${parent_oid[1,12]} using --${reset_mode}."
    _git_warn "If the removed commit was published, use an explicit force-with-lease workflow."
    return 0
  else
    local -i command_code=$?
    _git_error "Reset failed (exit $command_code)."
    return "$command_code"
  fi
}

# --- Staged inspection --------------------------------------------------------

_git_staged_usage() {
  print -u2 -r -- "Usage: git-staged [--help]"
  print -u2 -r -- "Select staged paths and page their exact cached diff."
}

git-staged() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_staged_usage
      return 0
    fi
    _git_error "Unknown argument for git-staged: $1"
    _git_staged_usage
    return 2
  fi

  _git_changes_require_interactive || return 1

  local -a staged_files=()
  local -a rows=()
  local -a selected_ids=()
  local -a selected_files=()
  local -a reply=()

  _git_changes_capture_nul diff --cached --name-only -z -- || {
    _git_error "Unable to discover staged files."
    return 1
  }
  staged_files=("${reply[@]}")
  (( ${#staged_files[@]} > 0 )) || {
    _git_info "Nothing is staged."
    return 0
  }

  _git_changes_path_rows "${staged_files[@]}" || return 1
  rows=("${reply[@]}")
  _git_changes_select_ids \
    "git staged" \
    "Tab select | Enter view cached diff | Esc cancel" \
    "2" "yes" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0

  _git_changes_values_for_ids staged_files selected_ids || return 1
  selected_files=("${reply[@]}")

  command git --literal-pathspecs diff \
    --cached --color=always -- "${selected_files[@]}" | _git_page
  local -a pipeline_codes=("${pipestatus[@]}")
  if (( pipeline_codes[1] != 0 )); then
    _git_error "Unable to render the staged diff (exit ${pipeline_codes[1]})."
    return "${pipeline_codes[1]}"
  fi
  if (( pipeline_codes[2] != 0 )); then
    _git_error "Pager failed (exit ${pipeline_codes[2]})."
    return "${pipeline_codes[2]}"
  fi
  return 0
}

# --- Cherry-pick --------------------------------------------------------------

_git_cherry_pick_usage() {
  print -u2 -r -- "Usage: git-cherry-pick [--help]"
  print -u2 -r -- "Interactively select commits or continue, abort, or skip an existing cherry-pick."
}

_git_changes_cherry_pick_selected() {
  emulate -L zsh

  local fields_name="$1"
  local ids_name="$2"
  local -a commit_fields=("${(@P)fields_name}")
  local -a selected_ids=("${(@P)ids_name}")
  local -a ordered_ids=("${(@on)selected_ids}")
  local -a selected_oids=()
  local -a reply=()
  local REPLY=""

  _git_changes_commit_oids_for_ids commit_fields ordered_ids || return 1
  selected_oids=("${reply[@]}")
  (( ${#selected_oids[@]} > 0 )) || return 0

  local expected_head=""
  expected_head=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
    _git_error "No current commit is available."
    return 1
  }

  _git_header "Cherry-pick plan"
  _git_info "Current HEAD: $expected_head"
  _git_info "Commits in oldest-first order: ${#selected_oids[@]}"
  local commit_oid=""
  for commit_oid in "${selected_oids[@]}"; do
    _git_dim "$commit_oid"
  done

  _git_changes_authorize "no" "Cherry-pick exactly ${#selected_oids[@]} commit(s)?" ||
    return 1
  [[ "$REPLY" == "cancelled" ]] && return 0

  local current_head=""
  current_head=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
    _git_error "HEAD became unavailable before cherry-pick."
    return 1
  }
  if [[ "$current_head" != "$expected_head" ]]; then
    _git_error "HEAD changed outside this plan; refusing the cherry-pick sequence."
    return 1
  fi
  for commit_oid in "${selected_oids[@]}"; do
    command git cat-file -e "${commit_oid}^{commit}" 2>/dev/null || {
      _git_error "Selected commit is no longer available: $commit_oid"
      return 1
    }
  done

  # One native sequence retains every remaining selected OID after a conflict,
  # so the existing continue, skip, and abort actions cover the complete plan.
  if command git cherry-pick "${selected_oids[@]}" >&2; then
    current_head=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
      _git_error "Unable to capture HEAD after cherry-pick."
      return 1
    }
    _git_success "Cherry-picked ${#selected_oids[@]} commit(s)."
    return 0
  else
    local -i command_code=$?
    _git_error "Cherry-pick sequence stopped or failed (exit $command_code)."
    _git_info "Run git-cherry-pick to continue, skip, or abort an in-progress sequence."
    return "$command_code"
  fi
}

git-cherry-pick() {
  emulate -L zsh

  local REPLY=""

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_cherry_pick_usage
      return 0
    fi
    _git_error "Unknown argument for git-cherry-pick: $1"
    _git_cherry_pick_usage
    return 2
  fi

  _git_changes_require_interactive || return 1

  local action=""
  local -i fzf_code=0
  action=$(printf '%s\n' \
    "Pick commits from another ref" \
    "Pick commits from recent history" \
    "Continue an in-progress cherry-pick" \
    "Abort an in-progress cherry-pick" \
    "Skip the current conflicting commit" |
    _git_fzf \
      --height=35% \
      --layout=reverse \
      --border=rounded \
      --prompt="git cherry-pick > " \
      --header="Enter choose | Esc cancel")
  fzf_code=$?
  case "$fzf_code" in
    0) ;;
    1|130) return 0 ;;
    *)
      _git_error "fzf failed while selecting a cherry-pick action (exit $fzf_code)."
      return 1
      ;;
  esac

  case "$action" in
    "Continue"*)
      command git cherry-pick --continue >&2
      local -i command_code=$?
      (( command_code == 0 )) && _git_success "Cherry-pick continued." ||
        _git_error "Cherry-pick continue failed (exit $command_code)."
      return "$command_code"
      ;;
    "Abort"*)
      _git_changes_authorize "no" "Abort the in-progress cherry-pick?" || return 1
      [[ "$REPLY" == "cancelled" ]] && return 0
      command git cherry-pick --abort >&2
      local -i command_code=$?
      (( command_code == 0 )) && _git_success "Cherry-pick aborted." ||
        _git_error "Cherry-pick abort failed (exit $command_code)."
      return "$command_code"
      ;;
    "Skip"*)
      _git_changes_authorize "no" "Skip the current cherry-pick commit?" || return 1
      [[ "$REPLY" == "cancelled" ]] && return 0
      command git cherry-pick --skip >&2
      local -i command_code=$?
      (( command_code == 0 )) && _git_success "Cherry-pick commit skipped." ||
        _git_error "Cherry-pick skip failed (exit $command_code)."
      return "$command_code"
      ;;
  esac

  local -a commit_fields=()
  local -a commit_rows=()
  local -a selected_ids=()
  local -a reply=()

  if [[ "$action" == "Pick commits from another ref" ]]; then
    local current_ref=""
    current_ref=$(command git symbolic-ref -q HEAD 2>/dev/null) || {
      _git_error "A named current branch is required for ref-relative cherry-pick."
      return 1
    }

    local ref_output=""
    ref_output=$(command git for-each-ref \
      --format='%(refname)%09%(refname:short)' refs/heads refs/remotes) || {
      _git_error "Unable to enumerate Git refs."
      return 1
    }

    local -a ref_lines=("${(@f)ref_output}")
    local -a ref_names=()
    local -a ref_rows=()
    local ref_line=""
    local ref_name=""
    local ref_label=""
    local escaped_label=""
    local record_label=""
    local -i ref_index=0

    for ref_line in "${ref_lines[@]}"; do
      ref_name="${ref_line%%$'\t'*}"
      ref_label="${ref_line#*$'\t'}"
      [[ "$ref_name" == "$current_ref" || "$ref_name" == refs/remotes/*/HEAD ]] &&
        continue
      ref_names+=("$ref_name")
      (( ref_index++ ))
      escaped_label=$(_git_display_escape "$ref_label") || return 1
      record_label=$(_git_record_escape "$escaped_label") || return 1
      ref_rows+=("${ref_index}"$'\t'"${record_label}")
    done

    (( ${#ref_names[@]} > 0 )) || {
      _git_info "No alternate refs are available."
      return 0
    }

    _git_changes_select_ids \
      "cherry-pick ref" \
      "Enter choose source ref | Esc cancel" \
      "2" "no" "${ref_rows[@]}" || return 1
    local -a selected_ref_ids=("${reply[@]}")
    (( ${#selected_ref_ids[@]} > 0 )) || return 0
    _git_changes_values_for_ids ref_names selected_ref_ids || return 1
    local source_ref="${reply[1]}"

    _git_changes_collect_commits \
      log -z --topo-order --reverse --format='%H%x09%h%x09%s' \
      "${current_ref}..${source_ref}" || {
      _git_error "Unable to enumerate commits unique to the selected ref."
      return 1
    }
    commit_fields=("${reply[@]}")
  else
    _git_changes_collect_commits \
      log -z --all --topo-order --reverse -n 100 \
      --format='%H%x09%h%x09%s' || {
      _git_error "Unable to enumerate recent commits."
      return 1
    }
    commit_fields=("${reply[@]}")
  fi

  (( ${#commit_fields[@]} > 0 )) || {
    _git_info "No candidate commits are available."
    return 0
  }

  _git_changes_commit_rows commit_fields || return 1
  commit_rows=("${reply[@]}")
  _git_changes_select_ids \
    "cherry-pick commits" \
    "Tab select | Enter review oldest-first plan | Esc cancel" \
    "2,3" "yes" "${commit_rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0

  _git_changes_cherry_pick_selected commit_fields selected_ids
}

# --- Commit creation and signature verification ------------------------------

_git_commit_usage() {
  print -u2 -r -- "Usage: git-commit [--help]"
  print -u2 -r -- "Create a commit from the current index using an interactive safe message flow."
}

_git_changes_read_line() {
  emulate -L zsh

  local prompt_text="$1"
  if [[ ! -t 0 || ! -t 2 ]]; then
    _git_error "Interactive text input requires a TTY."
    return 1
  fi

  print -u2 -n -r -- "$prompt_text"
  IFS= read -r REPLY
}

git-commit() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_commit_usage
      return 0
    fi
    _git_error "Unknown argument for git-commit: $1"
    _git_commit_usage
    return 2
  fi

  _git_changes_require_interactive || return 1

  local -a staged_files=()
  local -a reply=()
  _git_changes_capture_nul diff --cached --name-only -z -- || return 1
  staged_files=("${reply[@]}")

  if (( ${#staged_files[@]} == 0 )); then
    _git_warn "Nothing is staged."
    if _git_confirm "Open git-stage now?"; then
      git-stage || return $?
      _git_changes_capture_nul diff --cached --name-only -z -- || return 1
      staged_files=("${reply[@]}")
    else
      _git_info "Cancelled."
      return 0
    fi
  fi

  (( ${#staged_files[@]} > 0 )) || {
    _git_info "Nothing is staged after selection."
    return 0
  }

  _git_changes_show_paths "Commit index plan" "${staged_files[@]}" || return 1

  local signoff_choice=""
  local -i fzf_code=0
  signoff_choice=$(printf '%s\n' \
    "Add Signed-off-by trailer" \
    "Commit without sign-off" |
    _git_fzf \
      --height=20% \
      --layout=reverse \
      --border=rounded \
      --prompt="git sign-off > " \
      --header="Enter choose | Esc cancel")
  fzf_code=$?
  case "$fzf_code" in
    0) ;;
    1|130) return 0 ;;
    *)
      _git_error "fzf failed while selecting sign-off behavior (exit $fzf_code)."
      return 1
      ;;
  esac

  local commit_style=""
  commit_style=$(printf '%s\n' \
    "Conventional message" \
    "Free-form message" \
    "Open configured editor" |
    _git_fzf \
      --height=25% \
      --layout=reverse \
      --border=rounded \
      --prompt="git commit style > " \
      --header="Enter choose | Esc cancel")
  fzf_code=$?
  case "$fzf_code" in
    0) ;;
    1|130) return 0 ;;
    *)
      _git_error "fzf failed while selecting commit style (exit $fzf_code)."
      return 1
      ;;
  esac

  local -a commit_command=(git commit)
  [[ "$signoff_choice" == "Add Signed-off-by trailer" ]] &&
    commit_command+=(--signoff)

  local commit_message=""
  if [[ "$commit_style" == "Conventional message" ]]; then
    local commit_type=""
    commit_type=$(printf '%s\n' \
      feat fix refactor docs style test chore perf ci build revert |
      _git_fzf \
        --height=35% \
        --layout=reverse \
        --border=rounded \
        --prompt="commit type > " \
        --header="Enter choose type | Esc cancel")
    fzf_code=$?
    case "$fzf_code" in
      0) ;;
      1|130) return 0 ;;
      *)
        _git_error "fzf failed while selecting a commit type (exit $fzf_code)."
        return 1
        ;;
    esac

    local commit_scope=""
    local commit_description=""
    _git_changes_read_line "Scope (optional): " || return 1
    commit_scope="$REPLY"
    _git_changes_read_line "Description: " || return 1
    commit_description="$REPLY"
    [[ -n "$commit_description" ]] || {
      _git_info "Cancelled."
      return 0
    }
    if [[ "$commit_scope" == *[$'\n\r()']* ]]; then
      _git_error "Commit scope contains unsupported characters."
      return 2
    fi

    if [[ -n "$commit_scope" ]]; then
      commit_message="${commit_type}(${commit_scope}): ${commit_description}"
    else
      commit_message="${commit_type}: ${commit_description}"
    fi
    commit_command+=(-m "$commit_message")
  elif [[ "$commit_style" == "Free-form message" ]]; then
    _git_changes_read_line "Commit message: " || return 1
    commit_message="$REPLY"
    [[ -n "$commit_message" ]] || {
      _git_info "Cancelled."
      return 0
    }
    commit_command+=(-m "$commit_message")
  elif [[ "$commit_style" != "Open configured editor" ]]; then
    _git_error "Invalid commit style."
    return 1
  fi

  if command "${commit_command[@]}" >&2; then
    _git_success "Commit created."
    return 0
  else
    local -i command_code=$?
    _git_error "Commit failed or was cancelled by Git (exit $command_code)."
    return "$command_code"
  fi
}

_git_commit_verify_usage() {
  print -u2 -r -- "Usage: git-commit-verify [--help]"
  print -u2 -r -- "Select a commit and preserve the exact git verify-commit result."
}

git-commit-verify() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_commit_verify_usage
      return 0
    fi
    _git_error "Unknown argument for git-commit-verify: $1"
    _git_commit_verify_usage
    return 2
  fi

  _git_changes_require_interactive || return 1

  local -a commit_fields=()
  local -a commit_rows=()
  local -a selected_ids=()
  local -a selected_oids=()
  local -a reply=()

  _git_changes_collect_commits \
    log -z --all --format='%H%x09%h%x09%s' -n 100 || {
    _git_error "Unable to collect commits."
    return 1
  }
  commit_fields=("${reply[@]}")
  (( ${#commit_fields[@]} > 0 )) || {
    _git_info "No commits are available."
    return 0
  }

  _git_changes_commit_rows commit_fields || return 1
  commit_rows=("${reply[@]}")
  _git_changes_select_ids \
    "verify commit" \
    "Enter verify signature | Esc cancel" \
    "2,3" "no" "${commit_rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0

  _git_changes_commit_oids_for_ids commit_fields selected_ids || return 1
  selected_oids=("${reply[@]}")
  local commit_oid="${selected_oids[1]}"

  _git_info "Verifying commit $commit_oid."
  command git verify-commit -v "$commit_oid" >&2
  local -i verify_code=$?
  if (( verify_code == 0 )); then
    _git_success "Commit signature verified."
    return 0
  fi

  _git_error "Commit signature verification failed (exit $verify_code)."
  return "$verify_code"
}

typeset -g _GIT_CHANGES_SOURCED=1
