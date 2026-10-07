#!/usr/bin/env zsh
# =============================================================================
# Git Changes: unstage, discard, amend, and undo local changes
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_CHANGES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Private picker helpers --------------------------------------------------

# REPLY: "Repository: <name> | Branch: <branch>" for a picker header.
_git_changes_context_line() {
  emulate -L zsh

  local repo_root="" branch_name=""
  repo_root=$(command git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
  branch_name=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || branch_name="detached"
  REPLY="Repository: ${(V)${repo_root:t}:-unknown} | Branch: ${(V)branch_name}"
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

# REPLY: a fingerprint of one path's worktree content against the index, or
# with "head" also of its index entry against HEAD.
# Usage: _git_changes_path_fingerprint FILE [worktree|head]
_git_changes_path_fingerprint() {
  emulate -L zsh
  setopt localoptions no_aliases

  local file_name="$1"
  local fingerprint_scope="${2:-worktree}"
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

    if (( command_code == 0 )) && [[ "$fingerprint_scope" == "head" ]]; then
      command git --literal-pathspecs diff --cached \
        --binary --full-index --no-ext-diff --no-textconv -- \
        "$file_name" >> "$state_file"
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

# REPLY: the type, identity, size, and nanosecond times of one untracked path,
# read without following a symbolic link. Only regular files and symbolic
# links are supported.
_git_changes_untracked_fingerprint() {
  emulate -L zsh
  # Only zstat: the plain module would replace the shell's stat command.
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1

  local file_name="$1"
  local -A file_state=()
  REPLY=""
  zstat -F '%s.%N' -LH file_state -- "$file_name" 2>/dev/null || return 1
  [[ "${file_state[mode]}" == [-l]* ]] || return 1
  REPLY="${file_state[mode]}:${file_state[device]}:${file_state[inode]}"
  REPLY+=":${file_state[size]}:${file_state[mtime]}:${file_state[ctime]}"
  REPLY+=":${file_state[link]}"
}

# Sets reply to untracked, non-ignored files and REPLY to the number of nested
# repositories, which Git lists as "dir/" and which are never deleted.
_git_changes_untracked_files() {
  emulate -L zsh

  _git_capture_nul ls-files --others --exclude-standard -z -- || return 1
  local -a untracked_records=("${reply[@]}")
  local -a nested_repositories=("${(@M)untracked_records:#*/}")
  reply=("${(@)untracked_records:#*/}")
  REPLY="${#nested_repositories[@]}"
}

# HEAD identity is the commit plus its symbolic ref, so a branch switch to an
# identical commit still invalidates a plan that rewrites the current branch.
_git_changes_head_identity() {
  emulate -L zsh

  local head_oid=""
  local head_ref=""
  head_oid=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
    head_oid="UNBORN"
  head_ref=$(command git symbolic-ref -q HEAD 2>/dev/null) ||
    head_ref="DETACHED"
  REPLY="$head_oid $head_ref"
}

_git_changes_head_label() {
  emulate -L zsh

  local head_ref="${1#* }"
  if [[ "$head_ref" == refs/heads/* ]]; then
    REPLY="${head_ref#refs/heads/}"
  else
    REPLY="detached HEAD"
  fi
}

_git_changes_snapshot() {
  emulate -L zsh

  local repo_root=""
  local common_dir=""
  local worktree_git_dir=""
  local head_identity=""
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

  _git_changes_head_identity
  head_identity="$REPLY"

  _git_changes_diff_fingerprint || return 1
  diff_fingerprint="$REPLY"

  reply=(
    "$repo_root"
    "$common_dir"
    "$worktree_git_dir"
    "$head_identity"
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
  _git_changes_head_identity
  current_head="$REPLY"

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

# Sets reply to the untracked or ignored paths that a restore or reset of the
# named target paths would overwrite or remove: the same path, a directory
# that contains a target, or a file inside a target path. With
# core.ignorecase the comparison ignores letter case, because restoring
# notes.txt replaces an untracked Notes.TXT on such a file system.
_git_changes_untracked_obstacles() {
  emulate -L zsh

  local targets_name="$1"
  local -a obstacle_targets=("${(@P)targets_name}")
  local -a candidate_paths=()
  local fold_case="no"

  _git_ignorecase_enabled && fold_case="yes"
  _git_capture_nul ls-files --others --exclude-standard -z -- ||
    return 1
  candidate_paths=("${reply[@]}")
  _git_capture_nul \
    ls-files --others --ignored --exclude-standard -z -- || return 1
  candidate_paths+=("${reply[@]}")

  _git_path_collisions candidate_paths obstacle_targets "$fold_case"
}

# Returns 0 when restoring TARGET from HEAD would have to replace something
# that is not part of the reviewed plan: a directory at the target path, a
# file or link where one of its parent directories belongs, or a file at a
# path whose index entry is staged for removal. Reads only file metadata.
_git_changes_restore_blocked() {
  emulate -L zsh

  local target_path="$1"
  local index_letter="${2:-}"
  local parent_path="${target_path:h}"

  while [[ "$parent_path" != "." && -n "$parent_path" ]]; do
    if [[ -L "$parent_path" || ( -e "$parent_path" && ! -d "$parent_path" ) ]]; then
      return 0
    fi
    parent_path="${parent_path:h}"
  done
  [[ -d "$target_path" && ! -L "$target_path" ]] && return 0
  [[ "$index_letter" == "D" && ( -e "$target_path" || -L "$target_path" ) ]] &&
    return 0
  return 1
}

# REPLY: the Git operation in progress (rebase, merge, cherry-pick, revert),
# or empty when none is.
_git_changes_operation_in_progress() {
  emulate -L zsh

  local git_dir=""
  REPLY=""
  git_dir=$(command git rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
    return 1
  if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
    REPLY="rebase"
  elif [[ -f "$git_dir/MERGE_HEAD" ]]; then
    REPLY="merge"
  elif [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
    REPLY="cherry-pick"
  elif [[ -f "$git_dir/REVERT_HEAD" ]]; then
    REPLY="revert"
  fi
  return 0
}

_git_changes_show_paths() {
  emulate -L zsh

  local heading="$1"
  shift
  local -a file_names=("$@")
  local file_name=""

  _git_header "$heading"
  _git_info "Exact targets: ${#file_names[@]}"
  for file_name in "${file_names[@]}"; do
    _git_dim "${(V)file_name}"
  done
}

# Lists paths that block a plan, without a second heading.
_git_changes_show_obstacles() {
  emulate -L zsh

  local file_name=""
  _git_warn "These untracked or ignored paths would be overwritten or removed:"
  for file_name in "$@"; do
    _git_dim "${(V)file_name}"
  done
}

# Prints the counted verdict of a per-file batch and returns its status.
# Usage: _git_changes_report_results SUBJECT VERB PASSED FAILED
_git_changes_report_results() {
  emulate -L zsh

  local subject="$1"
  local verb="$2"
  local -i passed_count="$3"
  local -i failed_count="$4"
  local -i total_count=$(( passed_count + failed_count ))
  local REPLY=""

  if (( failed_count == 0 )); then
    _git_count_noun "$passed_count" file
    _git_success "$subject completed: $REPLY $verb."
    return 0
  fi

  _git_count_noun "$total_count" file
  if (( passed_count > 0 )); then
    _git_error "$subject completed with partial failures: $failed_count of $REPLY failed."
    _git_mark_partial
  else
    _git_error "$subject failed: $failed_count of $REPLY failed."
  fi
  return 1
}

# Lists the targets an interruption left unattempted and prints the verdict.
# Usage: _git_changes_report_interrupted SUBJECT VERB PASSED FAILED PENDING...
_git_changes_report_interrupted() {
  emulate -L zsh

  local subject="$1"
  local verb="$2"
  local -i passed_count="$3"
  local -i failed_count="$4"
  shift 4
  local pending_path=""
  for pending_path in "$@"; do
    _git_outcome_line "$pending_path" not-run
  done
  _git_warn \
    "$subject interrupted: $passed_count $verb, $failed_count failed, $# not run."
}

_git_changes_require_interactive() {
  _git_require_repo || return 1
  _git_check_cmd fzf || {
    _git_error "fzf is required for this interactive command."
    return 1
  }
}

# --- Unstage files -----------------------------------------------------------

_git_unstage_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  git-unstage [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-unstage --all [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-unstage --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Remove files from the next commit; their working-tree content stays unchanged."
  print -u2 -r -- \
    "Without --all, choose files in a picker whose first row selects every staged file."
  print -u2 -r -- "  --all      Unstage every staged file."
  print -u2 -r -- "  --dry-run  Show the exact plan without changing the index."
  print -u2 -r -- \
    "  -y, --yes  Confirm dropping a staged version that is not in the working tree."
}

git-unstage() {
  emulate -L zsh
  local REPLY=""
  # Git lists root-relative paths but resolves pathspecs from the current
  # directory; run from the repository root so both always agree.
  if _git_path_command_needs_root; then
    ( builtin cd -q -- "$REPLY" || exit 1; git-unstage "$@" )
    return $?
  fi

  local unstage_all="no"
  local dry_run="no"
  local assume_yes="no"
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _git_error "--help does not accept additional arguments."
          return 2
        }
        _git_unstage_usage
        return 0
        ;;
      --all) unstage_all="yes" ;;
      --dry-run) dry_run="yes" ;;
      -y|--yes) assume_yes="yes" ;;
      *)
        _git_error "Unknown argument for git-unstage: $1"
        _git_unstage_usage
        return 2
        ;;
    esac
    shift
  done
  [[ "$dry_run" == "yes" && "$assume_yes" == "yes" ]] && {
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  }

  if [[ "$unstage_all" == "yes" ]]; then
    _git_require_repo || return 1
  else
    _git_changes_require_interactive || return 1
  fi

  local -a reply=()
  local -a staged_pairs=()
  local -a worktree_pairs=()
  _git_name_status_pairs --cached -- || {
    _git_error "Unable to discover staged files."
    return 1
  }
  staged_pairs=("${reply[@]}")
  _git_name_status_pairs -- || {
    _git_error "Unable to inspect working-tree changes."
    return 1
  }
  worktree_pairs=("${reply[@]}")

  local -A worktree_letters=()
  local -i pair_index=0
  for (( pair_index = 1; pair_index <= ${#worktree_pairs[@]}; pair_index += 2 )); do
    worktree_letters[${worktree_pairs[pair_index + 1]}]="${worktree_pairs[pair_index]}"
  done

  local -a staged_files=()
  local -a staged_letters=()
  local -i conflict_count=0
  for (( pair_index = 1; pair_index <= ${#staged_pairs[@]}; pair_index += 2 )); do
    if [[ "${staged_pairs[pair_index]}" == "U" ]]; then
      (( conflict_count++ ))
      continue
    fi
    staged_files+=("${staged_pairs[pair_index + 1]}")
    staged_letters+=("${staged_pairs[pair_index]}")
  done

  if (( ${#staged_files[@]} == 0 )); then
    if (( conflict_count > 0 )); then
      _git_count_noun "$conflict_count" "conflicted file"
      _git_info "Nothing to unstage; resolve the $REPLY first."
    else
      _git_info "Nothing is staged."
    fi
    return 0
  fi

  local -a target_files=()
  local -a target_letters=()
  if [[ "$unstage_all" == "yes" ]]; then
    target_files=("${staged_files[@]}")
    target_letters=("${staged_letters[@]}")
  else
    local -a picker_rows=()
    _git_count_noun "${#staged_files[@]}" file
    picker_rows+=("1"$'\t'"all"$'\t'"All staged files ($REPLY)")
    local -i row_id=1
    local staged_file=""
    for staged_file in "${staged_files[@]}"; do
      (( row_id++ ))
      picker_rows+=("$row_id"$'\t'"file"$'\t'"${(V)staged_file}")
    done

    # A constant read-only preview of the staged change each row removes.
    local color_mode="never"
    [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]] && color_mode="always"
    local preview_program='case {2} in'
    preview_program+=" all) git --no-optional-locks --no-pager diff --cached --stat --color=${color_mode} -- ;;"
    preview_program+=" file) git --literal-pathspecs --no-optional-locks --no-pager diff --cached --color=${color_mode} --no-ext-diff --no-textconv -- {3} ;;"
    preview_program+=' esac'
    local -a picker_options=(
      "--preview=${preview_program}"
      --height=80%
      '--preview-window=right:50%:wrap,<120(down:8:wrap)'
      '--bind=ctrl-/:toggle-preview'
    )

    _git_changes_context_line
    local header_text="$REPLY | Staged: ${#staged_files[@]}"
    header_text+=$'\n''Type to filter | Enter unstage | Esc cancel | Ctrl-/ details'
    header_text+=$'\n''Tab mark several files'
    _git_select_ids "git unstage" "$header_text" 3 yes \
      picker_rows picker_options || return 1
    local -a selected_ids=("${reply[@]}")
    (( ${#selected_ids[@]} > 0 )) || return 0

    if (( ${selected_ids[(Ie)1]} )); then
      target_files=("${staged_files[@]}")
      target_letters=("${staged_letters[@]}")
    else
      local selected_id=""
      for selected_id in "${selected_ids[@]}"; do
        target_files+=("${staged_files[selected_id - 1]}")
        target_letters+=("${staged_letters[selected_id - 1]}")
      done
    fi
  fi

  local -a snapshot=()
  _git_changes_snapshot || {
    _git_error "Unable to capture repository state."
    return 1
  }
  snapshot=("${reply[@]}")
  _git_changes_head_label "${snapshot[4]}"
  local head_label="$REPLY"

  local -a plan_rows=()
  local -a at_risk_files=()
  local -i target_index=0
  local index_letter=""
  local worktree_letter=""
  for (( target_index = 1; target_index <= ${#target_files[@]}; target_index++ )); do
    index_letter="${target_letters[target_index]}"
    worktree_letter="${worktree_letters[${target_files[target_index]}]:-}"
    _git_change_label "$index_letter" ""
    plan_rows+=("$target_index"$'\t'"$REPLY"$'\t'"${(V)target_files[target_index]}")
    # The staged blob exists nowhere else when it differs from both HEAD and
    # the working tree, so unstaging it loses that version.
    if [[ "$index_letter" == [AMT] && "$worktree_letter" == [MDT] ]]; then
      at_risk_files+=("${target_files[target_index]}")
    fi
  done

  _git_header "Unstage Files"
  _git_label "Repository:" "${snapshot[1]:t}"
  _git_label "Branch:" "$head_label"
  _git_blank
  _git_table $'#\tStaged\tPath' "${plan_rows[@]}"
  _git_dim "Working-tree files are not changed."
  local at_risk_label=""
  if (( ${#at_risk_files[@]} > 0 )); then
    _git_count_noun "${#at_risk_files[@]}" file
    at_risk_label="$REPLY"
    _git_warn \
      "Unstaging loses the staged content of $at_risk_label because it differs from the working tree:"
    local at_risk_file=""
    for at_risk_file in "${at_risk_files[@]}"; do
      _git_dim "${(V)at_risk_file}"
    done
  fi

  _git_count_noun "${#target_files[@]}" file
  local planned="$REPLY"
  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: $planned planned; nothing was unstaged."
    return 0
  fi

  if (( ${#at_risk_files[@]} > 0 )); then
    _git_confirm_plan "$assume_yes" \
      "Unstage $planned and lose the staged content of $at_risk_label?" \
      "Cancelled: nothing was unstaged." || return 1
    [[ "$REPLY" == "cancelled" ]] && return 0
  fi

  _git_changes_snapshot_matches "${snapshot[@]}" || {
    _git_error "Repository state changed after review; nothing was unstaged."
    return 1
  }

  # One index write keeps the batch atomic: every target or none is unstaged.
  local -a unstage_command=()
  if [[ "${snapshot[4]%% *}" == "UNBORN" ]]; then
    unstage_command=(
      git --literal-pathspecs rm --cached -q -f
      --pathspec-from-file=- --pathspec-file-nul
    )
  else
    unstage_command=(
      git --literal-pathspecs restore --staged
      --pathspec-from-file=- --pathspec-file-nul
    )
  fi
  print -rn -- "${(pj:\0:)target_files}"$'\0' | command "${unstage_command[@]}" >&2
  local -a pipeline_codes=("${pipestatus[@]}")
  local -i command_code="${pipeline_codes[2]:-1}"
  (( pipeline_codes[1] == 0 || command_code != 0 )) || command_code=1

  _git_capture_nul diff --cached --name-only --no-renames -z -- || {
    _git_error "Unable to verify the index after unstaging."
    return 1
  }
  local -A still_staged=()
  local staged_name=""
  for staged_name in "${reply[@]}"; do
    still_staged[$staged_name]=1
  done

  _git_blank
  local -i passed_count=0
  local -i failed_count=0
  local target_file=""
  for target_file in "${target_files[@]}"; do
    if [[ -n "${still_staged[$target_file]:-}" ]]; then
      (( failed_count++ ))
      _git_error "Still staged: ${(V)target_file}"
    else
      (( passed_count++ ))
      _git_success "Unstaged: ${(V)target_file}"
    fi
  done

  if (( command_code == 130 || command_code == 143 )); then
    _git_warn "Unstage interrupted: $passed_count unstaged, $failed_count still staged."
    return "$command_code"
  fi
  if (( command_code != 0 && failed_count == 0 )); then
    _git_error "Git reported a failure (exit $command_code) although no target is still staged."
    return "$command_code"
  fi
  _git_changes_report_results "Unstage" "unstaged" "$passed_count" "$failed_count"
}

# --- Discard changes -----------------------------------------------------------

_git_discard_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  git-discard [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-discard --all [--include-untracked] [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-discard --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Without --all, choose files whose unstaged changes are replaced by their staged"
  print -u2 -r -- \
    "content, or choose a first row that discards every change."
  print -u2 -r -- \
    "  --all                Reset every staged and unstaged tracked change to HEAD."
  print -u2 -r -- \
    "  --include-untracked  With --all, also delete untracked files; ignored files stay."
  print -u2 -r -- "  --dry-run            Show the exact plan without changing files."
  print -u2 -r -- "  -y, --yes            Bypass only the final confirmation."
}

git-discard() {
  emulate -L zsh
  local REPLY=""
  # Git lists root-relative paths but resolves pathspecs from the current
  # directory; run from the repository root so both always agree.
  if _git_path_command_needs_root; then
    ( builtin cd -q -- "$REPLY" || exit 1; git-discard "$@" )
    return $?
  fi

  local discard_all="no"
  local include_untracked="no"
  local dry_run="no"
  local assume_yes="no"

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
      --all) discard_all="yes" ;;
      --include-untracked) include_untracked="yes" ;;
      --dry-run) dry_run="yes" ;;
      -y|--yes) assume_yes="yes" ;;
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
  [[ "$include_untracked" == "yes" && "$discard_all" != "yes" ]] && {
    _git_error "--include-untracked requires --all."
    return 2
  }

  if [[ "$discard_all" == "yes" ]]; then
    _git_require_repo || return 1
    _git_discard_all "$include_untracked" "$dry_run" "$assume_yes"
    return $?
  fi

  _git_changes_require_interactive || return 1
  _git_discard_interactive "$dry_run" "$assume_yes"
}

# Offers the all-changes rows first, then every file with unstaged changes.
_git_discard_interactive() {
  emulate -L zsh

  local dry_run="$1"
  local assume_yes="$2"
  local -a reply=()
  local REPLY=""

  local -a modified_files=()
  local -a staged_files=()
  local -a unstaged_files=()
  local -a untracked_files=()
  _git_capture_nul diff --name-only --no-renames -z --diff-filter=ACDMRTUXB -- || {
    _git_error "Unable to build the discard inventory."
    return 1
  }
  modified_files=("${reply[@]}")
  # The all-changes plan leaves submodule checkouts alone, so its counts do too.
  _git_capture_nul diff --cached --name-only --no-renames -z --ignore-submodules=all -- || {
    _git_error "Unable to build the discard inventory."
    return 1
  }
  staged_files=("${reply[@]}")
  _git_capture_nul diff --name-only --no-renames -z --ignore-submodules=all -- || {
    _git_error "Unable to build the discard inventory."
    return 1
  }
  unstaged_files=("${reply[@]}")
  _git_changes_untracked_files || {
    _git_error "Unable to inspect untracked files."
    return 1
  }
  untracked_files=("${reply[@]}")

  local -A tracked_seen=()
  local file_name=""
  for file_name in "${unstaged_files[@]}" "${staged_files[@]}"; do
    tracked_seen[$file_name]=1
  done
  local -i tracked_count=${#tracked_seen[@]}

  if (( tracked_count == 0 && ${#untracked_files[@]} == 0 \
    && ${#modified_files[@]} == 0 )); then
    _git_info "Nothing to discard: the working tree matches HEAD."
    return 0
  fi

  local -a picker_rows=()
  local -a row_kinds=()
  local -a row_files=()
  local -i row_id=0
  if (( tracked_count > 0 )); then
    (( row_id++ ))
    _git_count_noun "$tracked_count" "tracked file"
    picker_rows+=("$row_id"$'\t'"all"$'\t'"Discard all changes ($REPLY)")
    row_kinds+=(all)
    row_files+=("")
  fi
  if (( ${#untracked_files[@]} > 0 )); then
    (( row_id++ ))
    _git_count_noun "${#untracked_files[@]}" "untracked file"
    picker_rows+=(
      "$row_id"$'\t'"all-untracked"$'\t'"Discard all changes and delete untracked files ($REPLY)"
    )
    row_kinds+=(all-untracked)
    row_files+=("")
  fi
  for file_name in "${modified_files[@]}"; do
    (( row_id++ ))
    picker_rows+=("$row_id"$'\t'"file"$'\t'"${(V)file_name}")
    row_kinds+=(file)
    row_files+=("$file_name")
  done

  # A constant read-only preview: it shows what each row would discard. fzf
  # quotes the kind and path placeholders.
  local color_mode="never"
  [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]] && color_mode="always"
  local preview_program='case {2} in'
  preview_program+=" all|all-untracked) printf 'Reset to the last commit:\n'; git --no-optional-locks --no-pager diff --stat --color=${color_mode} --ignore-submodules=all HEAD -- ;;"
  preview_program+=' esac; case {2} in'
  preview_program+=" all-untracked) printf '\nDelete untracked files:\n'; git --no-optional-locks ls-files --others --exclude-standard | grep -v '/\$' ;;"
  preview_program+=" file) git --literal-pathspecs --no-optional-locks --no-pager diff --color=${color_mode} --no-ext-diff --no-textconv -- {3} ;;"
  preview_program+=' esac'
  local -a picker_options=(
    "--preview=${preview_program}"
    --height=80%
    '--preview-window=right:50%:wrap,<120(down:8:wrap)'
    '--bind=ctrl-/:toggle-preview'
  )

  _git_changes_context_line
  local header_text="$REPLY | Staged: ${#staged_files[@]}"
  header_text+=" | Modified: ${#modified_files[@]} | Untracked: ${#untracked_files[@]}"
  header_text+=$'\n''Type to filter | Enter review | Esc cancel | Ctrl-/ details'
  header_text+=$'\n''Tab mark several files'
  _git_select_ids "git discard" "$header_text" 3 yes picker_rows picker_options ||
    return 1
  local -a selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0

  # An all-changes row covers every file row, so the broadest choice wins.
  local selected_id=""
  local -a selected_files=()
  local discard_mode="files"
  for selected_id in "${selected_ids[@]}"; do
    case "${row_kinds[selected_id]}" in
      all-untracked) discard_mode="all-untracked" ;;
      all) [[ "$discard_mode" == "all-untracked" ]] || discard_mode="all" ;;
      file) selected_files+=("${row_files[selected_id]}") ;;
      *)
        _git_error "The selected discard row is invalid."
        return 1
        ;;
    esac
  done

  case "$discard_mode" in
    all-untracked) _git_discard_all yes "$dry_run" "$assume_yes" ;;
    all) _git_discard_all no "$dry_run" "$assume_yes" ;;
    *) _git_discard_files "$dry_run" "$assume_yes" "${selected_files[@]}" ;;
  esac
}

# Replaces the unstaged worktree content of the given files with the index.
_git_discard_files() {
  emulate -L zsh

  local dry_run="$1"
  local assume_yes="$2"
  shift 2
  local -a selected_files=("$@")
  local -a snapshot=()
  local -a file_fingerprints=()
  local -a untracked_obstacles=()
  local -a discard_target=()
  local -a reply=()
  local REPLY=""
  local file_name=""

  (( ${#selected_files[@]} > 0 )) || return 0

  _git_changes_snapshot || {
    _git_error "Unable to capture repository state."
    return 1
  }
  snapshot=("${reply[@]}")

  for file_name in "${selected_files[@]}"; do
    _git_changes_path_fingerprint "$file_name" || {
      _git_error "Unable to fingerprint a discard target."
      return 1
    }
    file_fingerprints+=("$REPLY")
  done

  _git_changes_head_label "${snapshot[4]}"
  local head_label="$REPLY"
  local -a plan_rows=()
  local -i item_index=0
  for (( item_index = 1; item_index <= ${#selected_files[@]}; item_index++ )); do
    plan_rows+=("$item_index"$'\t'"${(V)selected_files[item_index]}")
  done

  _git_header "Discard File Changes"
  _git_label "Repository:" "${snapshot[1]:t}"
  _git_label "Branch:" "$head_label"
  _git_blank
  _git_table $'#\tPath' "${plan_rows[@]}"

  # Restoring a deleted tracked path force-removes a directory in its place,
  # together with untracked or ignored files inside it.
  _git_changes_untracked_obstacles selected_files || {
    _git_error "Unable to inspect untracked discard obstacles."
    return 1
  }
  untracked_obstacles=("${reply[@]}")
  if (( ${#untracked_obstacles[@]} > 0 )); then
    _git_changes_show_obstacles "${untracked_obstacles[@]}"
    _git_error "Refusing to overwrite or remove untracked or ignored paths."
    return 1
  fi

  _git_warn "Unstaged changes in these files are lost; their staged changes are kept."
  _git_count_noun "${#selected_files[@]}" file
  local planned="$REPLY"
  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: $planned planned; nothing was discarded."
    return 0
  fi

  _git_confirm_plan "$assume_yes" "Discard changes in $planned?" \
    "Cancelled: nothing was discarded." || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0

  _git_changes_snapshot_matches "${snapshot[@]}" || {
    _git_error "Repository HEAD or diff changed after review; nothing was discarded."
    return 1
  }

  _git_blank
  local -i passed_count=0
  local -i failed_count=0
  local escaped_name=""
  for (( item_index = 1; item_index <= ${#selected_files[@]}; item_index++ )); do
    file_name="${selected_files[item_index]}"
    escaped_name="${(V)file_name}"

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
      _git_error "Changed after review; skipped: $escaped_name"
      continue
    fi

    discard_target=("$file_name")
    _git_changes_untracked_obstacles discard_target || {
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
      --worktree -- "$file_name" >&2; then
      (( passed_count++ ))
      _git_success "Discarded: $escaped_name"
    else
      local -i command_code=$?
      (( failed_count++ ))
      _git_error "Failed to discard: $escaped_name"
      if (( command_code == 130 || command_code == 143 )); then
        local -a pending_names=()
        local pending_name=""
        for pending_name in "${(@)selected_files[item_index + 1,-1]}"; do
          pending_names+=("${(V)pending_name}")
        done
        _git_changes_report_interrupted "Discard" "discarded" \
          "$passed_count" "$failed_count" "${pending_names[@]}"
        return "$command_code"
      fi
    fi
  done

  _git_changes_report_results "Discard" "discarded" "$passed_count" "$failed_count"
}

# Plans every staged and unstaged tracked change back to HEAD and, when asked,
# the deletion of untracked, non-ignored files. Ignored files and nested
# repositories are never touched.
_git_discard_all() {
  emulate -L zsh
  setopt localoptions no_aliases

  local include_untracked="$1"
  local dry_run="$2"
  local assume_yes="$3"
  local -a reply=()
  local REPLY=""

  local head_oid=""
  head_oid=$(command git rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null) || {
    _git_error "HEAD has no commit yet, so there is no last commit to reset to."
    return 1
  }
  _git_changes_operation_in_progress || {
    _git_error "Unable to inspect the repository state."
    return 1
  }
  if [[ -n "$REPLY" ]]; then
    _git_error "A $REPLY is in progress; finish or abort it before discarding all changes."
    return 1
  fi

  # Submodule checkouts belong to their own repositories and are left alone.
  local -a staged_pairs=()
  local -a worktree_pairs=()
  local -a untracked_files=()
  _git_name_status_pairs --cached --ignore-submodules=all -- || {
    _git_error "Unable to discover staged changes."
    return 1
  }
  staged_pairs=("${reply[@]}")
  _git_name_status_pairs --ignore-submodules=all -- || {
    _git_error "Unable to discover working-tree changes."
    return 1
  }
  worktree_pairs=("${reply[@]}")
  _git_changes_untracked_files || {
    _git_error "Unable to inspect untracked files."
    return 1
  }
  untracked_files=("${reply[@]}")
  local -i nested_count="$REPLY"

  local -A index_letters=()
  local -A worktree_letters=()
  local -a tracked_files=()
  local -i pair_index=0
  local pair_path=""
  for (( pair_index = 1; pair_index <= ${#staged_pairs[@]}; pair_index += 2 )); do
    pair_path="${staged_pairs[pair_index + 1]}"
    [[ -n "${index_letters[$pair_path]:-}" ]] || tracked_files+=("$pair_path")
    index_letters[$pair_path]="${staged_pairs[pair_index]}"
  done
  for (( pair_index = 1; pair_index <= ${#worktree_pairs[@]}; pair_index += 2 )); do
    pair_path="${worktree_pairs[pair_index + 1]}"
    [[ -n "${index_letters[$pair_path]:-}" || -n "${worktree_letters[$pair_path]:-}" ]] ||
      tracked_files+=("$pair_path")
    worktree_letters[$pair_path]="${worktree_pairs[pair_index]}"
  done
  tracked_files=("${(@o)tracked_files}")

  local -a untracked_targets=()
  [[ "$include_untracked" == "yes" ]] && untracked_targets=("${(@o)untracked_files}")

  if (( ${#tracked_files[@]} == 0 && ${#untracked_targets[@]} == 0 )); then
    if (( ${#untracked_files[@]} > 0 )); then
      _git_count_noun "${#untracked_files[@]}" "untracked file"
      _git_info \
        "No tracked changes to discard. Not included: $REPLY; --include-untracked deletes them."
    else
      _git_info "Nothing to discard: the working tree matches HEAD."
    fi
    return 0
  fi

  # A path absent from HEAD is removed; every other path is restored.
  local -a tracked_actions=()
  local -a tracked_changes=()
  local index_letter=""
  local worktree_letter=""
  local file_name=""
  for file_name in "${tracked_files[@]}"; do
    index_letter="${index_letters[$file_name]:-}"
    worktree_letter="${worktree_letters[$file_name]:-}"
    _git_change_label "$index_letter" "$worktree_letter"
    tracked_changes+=("$REPLY")
    if [[ "$index_letter" == "A" || "$worktree_letter" == "A" ]]; then
      tracked_actions+=(delete)
    elif [[ "$index_letter" == "U" ]] \
      && ! command git cat-file -e "${head_oid}:${file_name}" 2>/dev/null; then
      tracked_actions+=(delete)
    else
      tracked_actions+=(restore)
    fi
  done

  local -a snapshot=()
  _git_changes_snapshot || {
    _git_error "Unable to capture repository state."
    return 1
  }
  snapshot=("${reply[@]}")
  [[ "${snapshot[4]%% *}" == "$head_oid" ]] || {
    _git_error "HEAD changed while planning; nothing was discarded."
    return 1
  }
  _git_changes_head_label "${snapshot[4]}"
  local head_label="$REPLY"

  local -a tracked_fingerprints=()
  for file_name in "${tracked_files[@]}"; do
    _git_changes_path_fingerprint "$file_name" head || {
      _git_error "Unable to fingerprint a discard target."
      return 1
    }
    tracked_fingerprints+=("$REPLY")
  done
  local -a untracked_fingerprints=()
  for file_name in "${untracked_targets[@]}"; do
    _git_changes_untracked_fingerprint "$file_name" || {
      _git_error "Unsupported or unreadable untracked path: ${(V)file_name}"
      return 1
    }
    untracked_fingerprints+=("$REPLY")
  done

  local -a plan_rows=()
  local -i row_number=0
  local -i target_index=0
  for (( target_index = 1; target_index <= ${#tracked_files[@]}; target_index++ )); do
    (( row_number++ ))
    plan_rows+=(
      "$row_number"$'\t'"${tracked_changes[target_index]}"$'\t'"${tracked_actions[target_index]}"$'\t'"${(V)tracked_files[target_index]}"
    )
  done
  for (( target_index = 1; target_index <= ${#untracked_targets[@]}; target_index++ )); do
    (( row_number++ ))
    plan_rows+=(
      "$row_number"$'\t'"untracked"$'\t'"delete"$'\t'"${(V)untracked_targets[target_index]}"
    )
  done

  _git_header "Discard All Changes"
  _git_label "Repository:" "${snapshot[1]:t}"
  _git_label "Branch:" "$head_label"
  _git_label "Reset to:" "${head_oid[1,12]}"
  _git_blank
  _git_table $'#\tChange\tAction\tPath' "${plan_rows[@]}"

  _git_changes_untracked_obstacles tracked_files || {
    _git_error "Unable to inspect untracked discard obstacles."
    return 1
  }
  if (( ${#reply[@]} > 0 )); then
    _git_changes_show_obstacles "${reply[@]}"
    _git_error "Refusing to overwrite or remove untracked or ignored paths."
    return 1
  fi

  _git_warn "Discarded changes cannot be recovered."
  if [[ "$include_untracked" == "yes" ]]; then
    _git_dim "Ignored files are kept; directories left empty are removed."
  elif (( ${#untracked_files[@]} > 0 )); then
    _git_count_noun "${#untracked_files[@]}" "untracked file"
    _git_dim "Not included: $REPLY; --include-untracked deletes them."
  fi
  if (( nested_count > 0 )); then
    _git_count_noun "$nested_count" "nested repository" "nested repositories"
    _git_dim "Kept: $REPLY."
  fi

  local -i total_count=$(( ${#tracked_files[@]} + ${#untracked_targets[@]} ))
  _git_count_noun "$total_count" file
  local planned="$REPLY"
  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: $planned planned; nothing was discarded."
    return 0
  fi

  _git_confirm_plan "$assume_yes" "Discard all changes in $planned?" \
    "Cancelled: nothing was discarded." || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0

  # Revalidate the complete reviewed state before the first mutation.
  local -i state_changed=0
  _git_changes_snapshot_matches "${snapshot[@]}" || state_changed=1
  for (( target_index = 1; state_changed == 0 && target_index <= ${#untracked_targets[@]}; target_index++ )); do
    _git_changes_untracked_fingerprint "${untracked_targets[target_index]}" \
      && [[ "$REPLY" == "${untracked_fingerprints[target_index]}" ]] \
      || state_changed=1
  done
  if (( state_changed == 0 )); then
    _git_changes_untracked_obstacles tracked_files || state_changed=1
    (( ${#reply[@]} == 0 )) || state_changed=1
  fi
  if (( state_changed )); then
    _git_error "Repository changed after review; nothing was discarded."
    return 1
  fi

  _git_blank
  local -i passed_count=0
  local -i failed_count=0
  local -i command_code=0
  local -a removed_parents=()
  local escaped_name=""
  local -a pending_names=()
  local pending_name=""

  for (( target_index = 1; target_index <= ${#tracked_files[@]}; target_index++ )); do
    file_name="${tracked_files[target_index]}"
    escaped_name="${(V)file_name}"

    _git_changes_head_identity
    if [[ "$REPLY" != "${snapshot[4]}" ]]; then
      (( failed_count++ ))
      _git_error "HEAD changed; skipped: $escaped_name"
      continue
    fi
    _git_changes_path_fingerprint "$file_name" head || {
      (( failed_count++ ))
      _git_error "Unable to revalidate: $escaped_name"
      continue
    }
    if [[ "$REPLY" != "${tracked_fingerprints[target_index]}" ]]; then
      (( failed_count++ ))
      _git_error "Changed after review; skipped: $escaped_name"
      continue
    fi
    if [[ "${tracked_actions[target_index]}" == "restore" ]] \
      && _git_changes_restore_blocked "$file_name" "${index_letters[$file_name]:-}"; then
      (( failed_count++ ))
      _git_error "An untracked or ignored obstacle appeared; skipped: $escaped_name"
      continue
    fi

    command git --literal-pathspecs restore --source="$head_oid" \
      --staged --worktree -- "$file_name" >&2
    command_code=$?
    if (( command_code == 0 )); then
      (( passed_count++ ))
      if [[ "${tracked_actions[target_index]}" == "delete" ]]; then
        _git_success "Deleted: $escaped_name"
      else
        _git_success "Restored: $escaped_name"
      fi
      continue
    fi

    (( failed_count++ ))
    _git_error "Failed to discard: $escaped_name"
    if (( command_code == 130 || command_code == 143 )); then
      pending_names=()
      for pending_name in \
        "${(@)tracked_files[target_index + 1,-1]}" "${untracked_targets[@]}"; do
        pending_names+=("${(V)pending_name}")
      done
      _git_changes_report_interrupted "Discard" "discarded" \
        "$passed_count" "$failed_count" "${pending_names[@]}"
      return "$command_code"
    fi
  done

  for (( target_index = 1; target_index <= ${#untracked_targets[@]}; target_index++ )); do
    file_name="${untracked_targets[target_index]}"
    escaped_name="${(V)file_name}"

    _git_changes_untracked_fingerprint "$file_name" || REPLY=""
    if [[ "$REPLY" != "${untracked_fingerprints[target_index]}" ]]; then
      (( failed_count++ ))
      _git_error "Changed after review; skipped: $escaped_name"
      continue
    fi

    # git clean removes only untracked, non-ignored files, so a path that was
    # added or became ignored after review is left in place.
    command git --literal-pathspecs clean -f -q -- "$file_name" >&2
    command_code=$?
    if (( command_code == 0 )) && [[ ! -e "$file_name" && ! -L "$file_name" ]]; then
      (( passed_count++ ))
      _git_success "Deleted: $escaped_name"
      [[ "$file_name" == */* ]] && removed_parents+=("${file_name:h}")
      continue
    fi

    (( failed_count++ ))
    _git_error "Failed to delete: $escaped_name"
    if (( command_code == 130 || command_code == 143 )); then
      pending_names=()
      for pending_name in "${(@)untracked_targets[target_index + 1,-1]}"; do
        pending_names+=("${(V)pending_name}")
      done
      _git_changes_report_interrupted "Discard" "discarded" \
        "$passed_count" "$failed_count" "${pending_names[@]}"
      return "$command_code"
    fi
  done

  # Remove directories that deleting untracked files left empty, deepest
  # first. rmdir refuses any directory that still has an entry.
  local parent_dir=""
  for parent_dir in "${(@uO)removed_parents}"; do
    while [[ -n "$parent_dir" && "$parent_dir" != "." ]]; do
      [[ -d "$parent_dir" && ! -L "$parent_dir" ]] || break
      command rmdir -- "$parent_dir" 2>/dev/null || break
      parent_dir="${parent_dir:h}"
    done
  done

  _git_changes_report_results "Discard" "discarded" "$passed_count" "$failed_count"
}

# --- Amend the last commit ------------------------------------------------------

_git_amend_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  git-amend [--dry-run|-y|--yes]"
  print -u2 -r -- \
    "  git-amend [-m|--message TEXT] [--staged] [--reset-author] [--dry-run|-y|--yes]"
  print -u2 -r -- "  git-amend --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Rewrite the last commit. Without an action flag, choose one in a picker:"
  print -u2 -r -- \
    "change the message, edit it in your editor, add staged changes, or reset the author."
  print -u2 -r -- \
    "  -m, --message TEXT  Replace the subject line; the body and trailers are kept."
  print -u2 -r -- "  --staged            Add the staged changes to the commit."
  print -u2 -r -- "  --reset-author      Set the author to the current Git identity."
  print -u2 -r -- \
    "  --dry-run           Show the exact plan without rewriting the commit."
  print -u2 -r -- "  -y, --yes           Bypass only the final confirmation."
}

# Returns 0 for one non-empty subject line.
_git_amend_subject_valid() {
  emulate -L zsh

  local subject_text="$1"
  [[ "$subject_text" != *[$'\n\r']* && -n "${subject_text//[[:space:]]/}" ]]
}

git-amend() {
  emulate -L zsh

  local new_subject=""
  local message_given="no"
  local add_staged="no"
  local reset_author="no"
  local dry_run="no"
  local assume_yes="no"

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _git_error "--help does not accept additional arguments."
          return 2
        }
        _git_amend_usage
        return 0
        ;;
      -m|--message)
        [[ "$message_given" == "no" ]] || {
          _git_error "Duplicate option: --message"
          return 2
        }
        (( $# >= 2 )) || {
          _git_error "--message requires a subject line."
          return 2
        }
        new_subject="$2"
        message_given="yes"
        shift
        ;;
      --staged) add_staged="yes" ;;
      --reset-author) reset_author="yes" ;;
      --dry-run) dry_run="yes" ;;
      -y|--yes) assume_yes="yes" ;;
      *)
        _git_error "Unknown argument for git-amend: $1"
        _git_amend_usage
        return 2
        ;;
    esac
    shift
  done

  [[ "$dry_run" == "yes" && "$assume_yes" == "yes" ]] && {
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  }
  if [[ "$message_given" == "yes" ]] && ! _git_amend_subject_valid "$new_subject"; then
    _git_error \
      "--message requires one non-empty line; use the editor action for a multi-line message."
    return 2
  fi
  _git_require_repo || return 1

  local interactive_mode="no"
  [[ "$message_given" == "no" && "$add_staged" == "no" \
    && "$reset_author" == "no" ]] && interactive_mode="yes"
  if [[ "$interactive_mode" == "yes" ]]; then
    _git_check_cmd fzf || {
      _git_error \
        "fzf is required to choose an amend action; pass --message, --staged, or --reset-author."
      return 1
    }
  fi

  local REPLY=""
  local -a reply=()
  local head_identity=""
  _git_changes_head_identity
  head_identity="$REPLY"
  local head_oid="${head_identity%% *}"
  [[ "$head_oid" != "UNBORN" ]] || {
    _git_error "No commit is available to amend."
    return 1
  }
  _git_changes_head_label "$head_identity"
  local head_label="$REPLY"

  local raw_commit=""
  raw_commit=$(command git cat-file commit "$head_oid" 2>/dev/null) || {
    _git_error "Unable to read the last commit."
    return 1
  }
  local commit_message=""
  [[ "$raw_commit" == *$'\n\n'* ]] && commit_message="${raw_commit#*$'\n\n'}"
  local current_subject="${commit_message%%$'\n\n'*}"
  local current_body=""
  [[ "$commit_message" == *$'\n\n'* ]] && current_body="${commit_message#*$'\n\n'}"
  local subject_display="${current_subject//$'\n'/ }"
  local -a body_lines=()
  [[ -n "$current_body" ]] && body_lines=("${(@f)current_body}")

  local author_ident="" parent_oids=""
  author_ident=$(command git show -s --format='%an <%ae>' "$head_oid" 2>/dev/null) || {
    _git_error "Unable to read the last commit author."
    return 1
  }
  parent_oids=$(command git rev-parse "${head_oid}^@" 2>/dev/null) || parent_oids=""

  local published_output=""
  published_output=$(command git for-each-ref --contains "$head_oid" \
    --format='%(refname:short)' refs/remotes 2>/dev/null) || published_output=""
  local -a published_refs=()
  local published_ref=""
  for published_ref in "${(@f)published_output}"; do
    [[ -n "$published_ref" && "$published_ref" != */HEAD ]] &&
      published_refs+=("$published_ref")
  done

  local -a staged_pairs=()
  _git_name_status_pairs --cached -- || {
    _git_error "Unable to discover staged changes."
    return 1
  }
  staged_pairs=("${reply[@]}")
  local -i staged_count=$(( ${#staged_pairs[@]} / 2 ))

  _git_header "Amend Last Commit"
  _git_label "Branch:" "$head_label"
  _git_label "Commit:" "${head_oid[1,12]}"
  _git_label "Subject:" "$subject_display"
  _git_label "Author:" "$author_ident"

  local edit_message="no"
  if [[ "$interactive_mode" == "yes" ]]; then
    local staged_label=""
    _git_count_noun "$staged_count" "staged file"
    staged_label="$REPLY"
    local staged_note=""
    (( staged_count > 0 )) || staged_note=" (unavailable: nothing staged)"
    local -a action_rows=(
      "Change Message"$'\t'"message"$'\t'"Type a new subject line; the body and trailers such as Signed-off-by are kept."
      "Edit Message in Editor"$'\t'"edit"$'\t'"Open your Git editor with the complete current message."
      "Add Staged Changes${staged_note}"$'\t'"staged"$'\t'"Add $staged_label to the commit and keep its message."
      "Add Staged Changes and Change Message${staged_note}"$'\t'"staged-message"$'\t'"Add $staged_label to the commit and type a new subject line."
      "Reset Author"$'\t'"reset-author"$'\t'"Set the author to your current Git identity and keep the message."
    )
    local published_fact="no"
    (( ${#published_refs[@]} > 0 )) && published_fact="yes"
    local context_text="Commit: ${head_oid[1,12]} | Branch: ${(V)head_label}"
    context_text+=" | Staged: $staged_count | Published: $published_fact"
    _git_select_action "git amend" "$context_text" "${action_rows[@]}" || return $?
    local chosen_action="$REPLY"
    [[ -n "$chosen_action" ]] || {
      _git_info "Cancelled: nothing was amended."
      return 0
    }

    case "$chosen_action" in
      message) message_given="yes" ;;
      edit) edit_message="yes" ;;
      staged) add_staged="yes" ;;
      staged-message)
        add_staged="yes"
        message_given="yes"
        ;;
      reset-author) reset_author="yes" ;;
      *)
        _git_error "Invalid amend action."
        return 1
        ;;
    esac
    if [[ "$add_staged" == "yes" ]] && (( staged_count == 0 )); then
      _git_error "Nothing is staged; stage changes first or choose another action."
      return 1
    fi

    if [[ "$message_given" == "yes" ]]; then
      _git_read_line "New subject: " "$subject_display" || return 1
      new_subject="$REPLY"
      if [[ -z "${new_subject//[[:space:]]/}" ]]; then
        _git_info "Cancelled: nothing was amended."
        return 0
      fi
      _git_amend_subject_valid "$new_subject" || {
        _git_error "The subject must be one line."
        return 1
      }
      if [[ "$new_subject" == "$subject_display" && "$add_staged" == "no" ]]; then
        _git_info "The subject is unchanged; nothing was amended."
        return 0
      fi
    fi
  fi

  local -a snapshot=()
  _git_changes_snapshot || {
    _git_error "Unable to capture repository state."
    return 1
  }
  snapshot=("${reply[@]}")
  [[ "${snapshot[4]}" == "$head_identity" ]] || {
    _git_error "HEAD changed while planning; refusing to amend."
    return 1
  }

  if [[ "$add_staged" == "yes" ]] && (( staged_count == 0 )); then
    _git_error "Nothing is staged; there are no changes to add to the commit."
    return 1
  fi

  local new_author=""
  if [[ "$reset_author" == "yes" ]]; then
    new_author=$(command git var GIT_AUTHOR_IDENT 2>/dev/null) || {
      _git_error "Set user.name and user.email first, for example with git-identity-switcher."
      return 1
    }
    new_author="${new_author% * *}"
  fi

  if [[ "$message_given" == "yes" ]]; then
    _git_label "New subject:" "$new_subject"
    if (( ${#body_lines[@]} > 0 )); then
      _git_count_noun "${#body_lines[@]}" line
      _git_label "Body:" "kept ($REPLY)"
    fi
  elif [[ "$edit_message" == "yes" ]]; then
    _git_label "Message:" "edited in your Git editor after confirmation"
  else
    _git_label "Message:" "kept"
  fi
  [[ "$reset_author" == "yes" ]] && _git_label "New author:" "$new_author"
  if [[ "$add_staged" == "yes" ]]; then
    local -a plan_rows=()
    local -i pair_index=0
    local -i row_number=0
    for (( pair_index = 1; pair_index <= ${#staged_pairs[@]}; pair_index += 2 )); do
      (( row_number++ ))
      _git_change_label "${staged_pairs[pair_index]}" ""
      plan_rows+=("$row_number"$'\t'"$REPLY"$'\t'"${(V)staged_pairs[pair_index + 1]}")
    done
    _git_blank
    _git_table $'#\tStaged\tPath' "${plan_rows[@]}"
  fi
  if (( ${#published_refs[@]} > 0 )); then
    _git_warn \
      "The commit is already on ${published_refs[1]}; publishing the rewrite needs git-push --force-with-lease."
  fi
  [[ "$head_label" == "detached HEAD" ]] &&
    _git_warn "HEAD is detached; the amended commit is not on any branch."

  if [[ "$dry_run" == "yes" ]]; then
    _git_info "Dry run: 1 commit planned; nothing was amended."
    return 0
  fi

  _git_confirm_plan "$assume_yes" "Amend ${head_oid[1,12]} on ${head_label}?" \
    "Cancelled: nothing was amended." || return 1
  [[ "$REPLY" == "cancelled" ]] && return 0

  _git_changes_snapshot_matches "${snapshot[@]}" || {
    _git_error "Repository HEAD or diff changed after review; nothing was amended."
    return 1
  }

  local -a amend_command=(git commit --amend --quiet)
  [[ "$add_staged" == "yes" ]] || amend_command+=(--only)
  [[ "$reset_author" == "yes" ]] && amend_command+=(--reset-author)

  local message_dir=""
  local -i command_code=0
  {
    if [[ "$message_given" == "yes" ]]; then
      message_dir=$(umask 077; command mktemp -d \
        "${TMPDIR:-/tmp}/zdx-git-amend.XXXXXX" 2>/dev/null) || {
        _git_error "Unable to create a private temporary directory."
        return 1
      }
      local new_message="$new_subject"
      [[ -n "$current_body" ]] && new_message+=$'\n\n'"$current_body"
      print -r -- "$new_message" >| "$message_dir/message" || {
        _git_error "Unable to write the new commit message."
        return 1
      }
      amend_command+=(--cleanup=verbatim -F "$message_dir/message")
    elif [[ "$edit_message" != "yes" ]]; then
      amend_command+=(--no-edit)
    fi

    # commit.gpgSign may sign the amended commit through pinentry.
    _git_run_with_gpg_tty command "${amend_command[@]}" >&2
    command_code=$?
  } always {
    if [[ -n "$message_dir" ]]; then
      command rm -f -- "$message_dir/message" 2>/dev/null
      command rmdir -- "$message_dir" 2>/dev/null
    fi
  }

  _git_changes_head_identity
  local new_identity="$REPLY"
  local new_oid="${new_identity%% *}"
  if (( command_code != 0 )); then
    if [[ "$new_identity" == "$head_identity" ]]; then
      _git_error "Amend did not complete (exit $command_code); the commit is unchanged."
    else
      _git_error "Amend failed (exit $command_code) after HEAD moved; inspect git log."
    fi
    return "$command_code"
  fi

  local new_parents="" old_tree="" new_tree=""
  new_parents=$(command git rev-parse "${new_oid}^@" 2>/dev/null) || new_parents="?"
  old_tree=$(command git rev-parse "${head_oid}^{tree}" 2>/dev/null) || old_tree="?"
  new_tree=$(command git rev-parse "${new_oid}^{tree}" 2>/dev/null) || new_tree=""
  local -i state_ok=1
  [[ "$new_oid" != "$head_oid" \
    && "${new_identity#* }" == "${head_identity#* }" \
    && "$new_parents" == "$parent_oids" ]] || state_ok=0
  if [[ "$add_staged" == "yes" ]]; then
    command git diff --cached --quiet "$new_oid" -- 2>/dev/null || state_ok=0
  else
    [[ "$new_tree" == "$old_tree" ]] || state_ok=0
  fi
  if (( ! state_ok )); then
    _git_error "The amended commit is not in the expected state; inspect git log."
    return 1
  fi

  _git_success "Amended ${head_label}: ${head_oid[1,12]} → ${new_oid[1,12]}."
  (( ${#published_refs[@]} > 0 )) &&
    _git_info "Publish the rewrite with: git-push --force-with-lease"
  return 0
}

# --- Undo the last commit ----------------------------------------------------

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
  local REPLY=""
  # Git lists root-relative paths but resolves pathspecs from the current
  # directory; run from the repository root so both always agree.
  if _git_path_command_needs_root; then
    ( builtin cd -q -- "$REPLY" || exit 1; git-undo-commit "$@" )
    return $?
  fi

  local reset_mode=""
  local dry_run="no"
  local assume_yes="no"

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
  [[ "${snapshot[4]%% *}" == "$head_oid" ]] || {
    _git_error "HEAD changed while planning; refusing to reset."
    return 1
  }
  _git_changes_head_label "${snapshot[4]}"
  local head_label="$REPLY"

  if [[ "$reset_mode" == "hard" ]]; then
    local -a commit_files=()
    local -a worktree_files=()
    local -a index_files=()
    local file_name=""

    _git_capture_nul diff --name-only --no-renames -z "$parent_oid" "$head_oid" -- ||
      return 1
    commit_files=("${reply[@]}")
    _git_capture_nul diff --name-only --no-renames -z -- || return 1
    worktree_files=("${reply[@]}")
    _git_capture_nul diff --cached --name-only --no-renames -z -- || return 1
    index_files=("${reply[@]}")
    _git_capture_nul ls-tree -r -z --name-only "$parent_oid" ||
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
    _git_capture_nul diff --cached --name-only --no-renames -z "$parent_oid" -- ||
      return 1
    affected_files=("${reply[@]}")
  fi

  _git_header "Undo commit plan"
  _git_info "Branch: $head_label"
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

  _git_confirm_plan \
    "$assume_yes" \
    "Reset ${head_label} from ${head_oid[1,12]} to ${parent_oid[1,12]} using --${reset_mode}?" \
    "Cancelled." ||
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

typeset -g _GIT_CHANGES_SOURCED=1
