#!/usr/bin/env zsh
# =============================================================================
# Git History: safe diff, log, reflog, file history, and blame inspection
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_HISTORY_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Private records and paging ----------------------------------------------

_git_history_capture_nul() {
  emulate -L zsh
  setopt localoptions no_aliases

  local temp_dir=""
  local records_file=""
  local record=""
  local -i command_code=0
  reply=()

  temp_dir=$(command mktemp -d "${TMPDIR:-/tmp}/zdx-git-history.XXXXXX") || {
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

_git_history_rows() {
  emulate -L zsh

  local -a values=("$@")
  local escaped_value=""
  local record_value=""
  local -i item_index=0
  reply=()

  for (( item_index = 1; item_index <= ${#values[@]}; item_index++ )); do
    escaped_value=$(_git_display_escape "${values[item_index]}") || return 1
    record_value=$(_git_record_escape "$escaped_value") || return 1
    reply+=("${item_index}"$'\t'"${record_value}")
  done
}

_git_history_select_ids() {
  emulate -L zsh

  local prompt_text="$1"
  local header_text="$2"
  local visible_fields="$3"
  local multi_mode="$4"
  shift 4

  local -a menu_rows=("$@")
  local -a fzf_options=(
    --height=70%
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
      _git_error "fzf failed while selecting history records (exit $fzf_code)."
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
    (( ${selected_ids[(Ie)$selected_id]} == 0 )) &&
      selected_ids+=("$selected_id")
  done

  reply=("${selected_ids[@]}")
}

_git_history_values_for_ids() {
  emulate -L zsh

  local values_name="$1"
  local ids_name="$2"
  local -a source_values=("${(@P)values_name}")
  local -a selected_ids=("${(@P)ids_name}")
  local selected_id=""
  local -i id_number=0
  reply=()

  for selected_id in "${selected_ids[@]}"; do
    id_number=$(( 10#$selected_id ))
    if (( id_number < 1 || id_number > ${#source_values[@]} )); then
      _git_error "Selected record no longer maps to captured data."
      return 1
    fi
    reply+=("${source_values[id_number]}")
  done
}

_git_history_collect_commits() {
  emulate -L zsh

  local -a raw_records=()
  local raw_record=""
  local commit_oid=""
  local remaining=""
  local short_oid=""
  local subject_text=""

  _git_history_capture_nul "$@" || return 1
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

_git_history_commit_rows() {
  emulate -L zsh

  local fields_name="$1"
  local -a commit_fields=("${(@P)fields_name}")
  local escaped_subject=""
  local record_subject=""
  local -i field_index=0
  local -i record_index=0
  reply=()

  (( ${#commit_fields[@]} % 3 == 0 )) || {
    _git_error "Malformed internal commit inventory."
    return 1
  }

  for (( field_index = 1; field_index <= ${#commit_fields[@]}; field_index += 3 )); do
    (( record_index++ ))
    escaped_subject=$(_git_display_escape "${commit_fields[field_index + 2]}") ||
      return 1
    record_subject=$(_git_record_escape "$escaped_subject") || return 1
    reply+=(
      "${record_index}"$'\t'"${commit_fields[field_index + 1]}"$'\t'"${record_subject}"
    )
  done
}

_git_history_commit_oids_for_ids() {
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

_git_history_collect_refs() {
  emulate -L zsh

  local ref_output=""
  ref_output=$(command git for-each-ref \
    --format='%(refname)%09%(refname:short)' refs/heads refs/remotes refs/tags) || {
    _git_error "Unable to enumerate Git refs."
    return 1
  }

  local -a ref_lines=("${(@f)ref_output}")
  local ref_line=""
  local ref_name=""
  local ref_label=""
  reply=()

  for ref_line in "${ref_lines[@]}"; do
    ref_name="${ref_line%%$'\t'*}"
    ref_label="${ref_line#*$'\t'}"
    [[ "$ref_name" == refs/remotes/*/HEAD ]] && continue
    reply+=("$ref_name" "$ref_label")
  done
}

_git_history_ref_rows() {
  emulate -L zsh

  local fields_name="$1"
  local -a ref_fields=("${(@P)fields_name}")
  local escaped_label=""
  local record_label=""
  local -i field_index=0
  local -i record_index=0
  reply=()

  (( ${#ref_fields[@]} % 2 == 0 )) || {
    _git_error "Malformed internal ref inventory."
    return 1
  }

  for (( field_index = 1; field_index <= ${#ref_fields[@]}; field_index += 2 )); do
    (( record_index++ ))
    escaped_label=$(_git_display_escape "${ref_fields[field_index + 1]}") || return 1
    record_label=$(_git_record_escape "$escaped_label") || return 1
    reply+=("${record_index}"$'\t'"${record_label}")
  done
}

_git_history_path_at_commit() {
  emulate -L zsh

  local current_file="$1"
  local selected_oid="$2"
  local fields_name="$3"
  local -a history_fields=("${(@P)fields_name}")
  local traced_file="$current_file"
  local commit_oid=""
  local status_token=""
  local old_file=""
  local new_file=""
  local changed_file=""
  local -a diff_records=()
  local -a reply=()
  local -i field_index=0
  local -i record_index=0

  for (( field_index = 1;
    field_index <= ${#history_fields[@]};
    field_index += 3 )); do
    commit_oid="${history_fields[field_index]}"
    if [[ "$commit_oid" == "$selected_oid" ]]; then
      REPLY="$traced_file"
      return 0
    fi

    _git_history_capture_nul \
      diff-tree --root -r -M --no-commit-id --name-status -z \
      "$commit_oid" || {
      _git_error "Unable to trace the historical file name."
      return 1
    }
    diff_records=("${reply[@]}")
    record_index=1

    while (( record_index <= ${#diff_records[@]} )); do
      status_token="${diff_records[record_index]}"
      (( record_index++ ))

      case "$status_token" in
        R<->|C<->)
          if (( record_index + 1 > ${#diff_records[@]} )); then
            _git_error "Git returned a malformed rename record."
            return 1
          fi
          old_file="${diff_records[record_index]}"
          new_file="${diff_records[record_index + 1]}"
          record_index=$(( record_index + 2 ))
          if [[ "$status_token" == R* && "$new_file" == "$traced_file" ]]; then
            traced_file="$old_file"
          fi
          ;;
        A|D|M|T|U|X|B)
          if (( record_index > ${#diff_records[@]} )); then
            _git_error "Git returned a malformed path-status record."
            return 1
          fi
          changed_file="${diff_records[record_index]}"
          (( record_index++ ))
          ;;
        *)
          _git_error "Git returned an unsupported path-status record."
          return 1
          ;;
      esac
    done
  done

  _git_error "The selected commit is outside the captured file history."
  return 1
}

_git_history_ref_for_id() {
  emulate -L zsh

  local fields_name="$1"
  local selected_id="$2"
  local -a ref_fields=("${(@P)fields_name}")
  local -i record_index=$(( 10#$selected_id ))
  local -i field_index=$(( ((record_index - 1) * 2) + 1 ))

  if (( field_index < 1 || field_index + 1 > ${#ref_fields[@]} )); then
    _git_error "Selected ref is outside the captured inventory."
    return 1
  fi
  REPLY="${ref_fields[field_index]}"
}

_git_history_page_git() {
  emulate -L zsh

  command git --literal-pathspecs "$@" | _git_page
  local -a pipeline_codes=("${pipestatus[@]}")

  if (( pipeline_codes[1] != 0 )); then
    _git_error "Git failed while producing paged output (exit ${pipeline_codes[1]})."
    return "${pipeline_codes[1]}"
  fi
  if (( pipeline_codes[2] != 0 )); then
    _git_error "Pager failed (exit ${pipeline_codes[2]})."
    return "${pipeline_codes[2]}"
  fi
  return 0
}

_git_history_require_interactive() {
  _git_require_repo || return 1
  _git_check_cmd fzf || {
    _git_error "fzf is required for this interactive command."
    return 1
  }
}

_git_history_select_paths() {
  emulate -L zsh

  local prompt_text="$1"
  local header_text="$2"
  shift 2
  local -a file_names=("$@")
  local -a rows=()
  local -a selected_ids=()

  (( ${#file_names[@]} > 0 )) || {
    reply=()
    return 0
  }

  _git_history_rows "${file_names[@]}" || return 1
  rows=("${reply[@]}")
  _git_history_select_ids \
    "$prompt_text" "$header_text" "2" "yes" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || {
    reply=()
    return 0
  }

  _git_history_values_for_ids file_names selected_ids
}

# --- Diff --------------------------------------------------------------------

_git_diff_usage() {
  print -u2 -r -- "Usage: git-diff [--help]"
  print -u2 -r -- "Interactively inspect worktree, index, ref, or commit diffs."
}

git-diff() {
  emulate -L zsh

  local REPLY=""

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_diff_usage
      return 0
    fi
    _git_error "Unknown argument for git-diff: $1"
    _git_diff_usage
    return 2
  fi

  _git_history_require_interactive || return 1

  local action=""
  local -i fzf_code=0
  action=$(printf '%s\n' \
    "Working tree changes" \
    "Staged changes" \
    "All tracked changes versus HEAD" \
    "Between two refs" \
    "Between two commits" \
    "Last commit" |
    _git_fzf \
      --height=35% \
      --layout=reverse \
      --border=rounded \
      --prompt="git diff > " \
      --header="Enter choose diff scope | Esc cancel")
  fzf_code=$?
  case "$fzf_code" in
    0) ;;
    1|130) return 0 ;;
    *)
      _git_error "fzf failed while selecting diff scope (exit $fzf_code)."
      return 1
      ;;
  esac

  local -a file_names=()
  local -a selected_files=()
  local -a reply=()

  case "$action" in
    "Working tree changes")
      _git_history_capture_nul diff --name-only -z -- || return 1
      file_names=("${reply[@]}")
      (( ${#file_names[@]} > 0 )) || {
        _git_info "No unstaged tracked changes."
        return 0
      }
      _git_history_select_paths \
        "worktree diff" \
        "Tab select | Enter page diff | Esc cancel" \
        "${file_names[@]}" || return 1
      selected_files=("${reply[@]}")
      (( ${#selected_files[@]} > 0 )) || return 0
      _git_history_page_git \
        diff --color=always --no-ext-diff --no-textconv -- "${selected_files[@]}"
      ;;

    "Staged changes")
      _git_history_capture_nul diff --cached --name-only -z -- || return 1
      file_names=("${reply[@]}")
      (( ${#file_names[@]} > 0 )) || {
        _git_info "Nothing is staged."
        return 0
      }
      _git_history_select_paths \
        "staged diff" \
        "Tab select | Enter page cached diff | Esc cancel" \
        "${file_names[@]}" || return 1
      selected_files=("${reply[@]}")
      (( ${#selected_files[@]} > 0 )) || return 0
      _git_history_page_git \
        diff --cached --color=always --no-ext-diff --no-textconv -- \
        "${selected_files[@]}"
      ;;

    "All tracked changes versus HEAD")
      local head_oid=""
      head_oid=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
        _git_error "HEAD is unborn; use the staged and worktree views separately."
        return 1
      }
      _git_history_capture_nul diff --name-only -z "$head_oid" -- || return 1
      file_names=("${reply[@]}")
      (( ${#file_names[@]} > 0 )) || {
        _git_info "No tracked changes versus HEAD."
        return 0
      }
      _git_history_select_paths \
        "all changes" \
        "Tab select | Enter page diff | Esc cancel" \
        "${file_names[@]}" || return 1
      selected_files=("${reply[@]}")
      (( ${#selected_files[@]} > 0 )) || return 0
      _git_history_page_git \
        diff --color=always --no-ext-diff --no-textconv "$head_oid" -- \
        "${selected_files[@]}"
      ;;

    "Between two refs")
      local -a ref_fields=()
      local -a ref_rows=()
      local -a selected_ids=()
      _git_history_collect_refs || return 1
      ref_fields=("${reply[@]}")
      (( ${#ref_fields[@]} >= 4 )) || {
        _git_error "At least two refs are required."
        return 1
      }
      _git_history_ref_rows ref_fields || return 1
      ref_rows=("${reply[@]}")

      _git_history_select_ids \
        "diff from ref" "Enter select first ref | Esc cancel" \
        "2" "no" "${ref_rows[@]}" || return 1
      selected_ids=("${reply[@]}")
      (( ${#selected_ids[@]} > 0 )) || return 0
      _git_history_ref_for_id ref_fields "${selected_ids[1]}" || return 1
      local from_ref="$REPLY"

      _git_history_select_ids \
        "diff to ref" "Enter select second ref | Esc cancel" \
        "2" "no" "${ref_rows[@]}" || return 1
      selected_ids=("${reply[@]}")
      (( ${#selected_ids[@]} > 0 )) || return 0
      _git_history_ref_for_id ref_fields "${selected_ids[1]}" || return 1
      local to_ref="$REPLY"

      [[ "$from_ref" != "$to_ref" ]] || {
        _git_error "Choose two different refs."
        return 2
      }

      local ref_range="${from_ref}..${to_ref}"
      _git_history_capture_nul diff --name-only -z "$ref_range" -- || return 1
      file_names=("${reply[@]}")
      (( ${#file_names[@]} > 0 )) || {
        _git_info "The selected refs have no differing files."
        return 0
      }
      _git_history_select_paths \
        "ref diff files" \
        "Tab select | Enter page diff | Esc cancel" \
        "${file_names[@]}" || return 1
      selected_files=("${reply[@]}")
      (( ${#selected_files[@]} > 0 )) || return 0
      _git_history_page_git \
        diff --color=always --no-ext-diff --no-textconv "$ref_range" -- \
        "${selected_files[@]}"
      ;;

    "Between two commits")
      local -a commit_fields=()
      local -a commit_rows=()
      local -a selected_ids=()
      local -a selected_oids=()

      _git_history_collect_commits \
        log -z --all -n 200 --format='%H%x09%h%x09%s' || return 1
      commit_fields=("${reply[@]}")
      (( ${#commit_fields[@]} >= 6 )) || {
        _git_error "At least two commits are required."
        return 1
      }
      _git_history_commit_rows commit_fields || return 1
      commit_rows=("${reply[@]}")

      _git_history_select_ids \
        "diff from commit" "Enter select first commit | Esc cancel" \
        "2,3" "no" "${commit_rows[@]}" || return 1
      selected_ids=("${reply[@]}")
      (( ${#selected_ids[@]} > 0 )) || return 0
      _git_history_commit_oids_for_ids commit_fields selected_ids || return 1
      selected_oids=("${reply[@]}")
      local from_oid="${selected_oids[1]}"

      _git_history_select_ids \
        "diff to commit" "Enter select second commit | Esc cancel" \
        "2,3" "no" "${commit_rows[@]}" || return 1
      selected_ids=("${reply[@]}")
      (( ${#selected_ids[@]} > 0 )) || return 0
      _git_history_commit_oids_for_ids commit_fields selected_ids || return 1
      selected_oids=("${reply[@]}")
      local to_oid="${selected_oids[1]}"

      [[ "$from_oid" != "$to_oid" ]] || {
        _git_error "Choose two different commits."
        return 2
      }

      local commit_range="${from_oid}..${to_oid}"
      _git_history_capture_nul diff --name-only -z "$commit_range" -- || return 1
      file_names=("${reply[@]}")
      (( ${#file_names[@]} > 0 )) || {
        _git_info "The selected commits have no differing files."
        return 0
      }
      _git_history_select_paths \
        "commit diff files" \
        "Tab select | Enter page diff | Esc cancel" \
        "${file_names[@]}" || return 1
      selected_files=("${reply[@]}")
      (( ${#selected_files[@]} > 0 )) || return 0
      _git_history_page_git \
        diff --color=always --no-ext-diff --no-textconv "$commit_range" -- \
        "${selected_files[@]}"
      ;;

    "Last commit")
      local head_oid=""
      local parent_oid=""
      head_oid=$(command git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
        _git_error "No commit is available."
        return 1
      }
      if parent_oid=$(command git rev-parse --verify 'HEAD^1^{commit}' 2>/dev/null); then
        _git_history_page_git \
          diff --color=always --no-ext-diff --no-textconv \
          "${parent_oid}..${head_oid}" --
      else
        _git_history_page_git \
          show --color=always --show-signature --no-ext-diff --no-textconv \
          --format=fuller "$head_oid"
      fi
      ;;

    *)
      _git_error "Invalid diff action."
      return 1
      ;;
  esac
}

# --- Commit and reflog browsers ----------------------------------------------

_git_log_search_usage() {
  print -u2 -r -- "Usage: git-log-search [--help]"
  print -u2 -r -- "Search captured commit subjects and page the selected immutable commit."
}

git-log-search() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_log_search_usage
      return 0
    fi
    _git_error "Unknown argument for git-log-search: $1"
    _git_log_search_usage
    return 2
  fi

  _git_history_require_interactive || return 1

  local -a commit_fields=()
  local -a commit_rows=()
  local -a selected_ids=()
  local -a selected_oids=()
  local -a reply=()

  _git_history_collect_commits \
    log -z --all -n 500 --format='%H%x09%h%x09%s' || {
    _git_error "Unable to collect commit history."
    return 1
  }
  commit_fields=("${reply[@]}")
  (( ${#commit_fields[@]} > 0 )) || {
    _git_info "No commits are available."
    return 0
  }

  _git_history_commit_rows commit_fields || return 1
  commit_rows=("${reply[@]}")
  _git_history_select_ids \
    "git log" \
    "Enter page selected commit | Esc cancel" \
    "2,3" "no" "${commit_rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0
  _git_history_commit_oids_for_ids commit_fields selected_ids || return 1
  selected_oids=("${reply[@]}")

  _git_history_page_git \
    show --show-signature --stat --color=always --no-ext-diff --no-textconv \
    "${selected_oids[1]}"
}

_git_reflog_usage() {
  print -u2 -r -- "Usage: git-reflog [--help]"
  print -u2 -r -- "Browse reflog entries by immutable commit OID without changing repository state."
}

git-reflog() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_reflog_usage
      return 0
    fi
    _git_error "Unknown argument for git-reflog: $1"
    _git_reflog_usage
    return 2
  fi

  _git_history_require_interactive || return 1

  local -a raw_records=()
  local -a entry_oids=()
  local -a rows=()
  local -a selected_ids=()
  local -a selected_oids=()
  local -a reply=()
  local raw_record=""
  local entry_oid=""
  local remaining=""
  local short_oid=""
  local selector=""
  local subject_text=""
  local escaped_text=""
  local record_text=""
  local -i entry_index=0

  _git_history_capture_nul \
    reflog -z --format='%H%x09%h%x09%gd%x09%gs' || {
    _git_error "Unable to collect reflog entries."
    return 1
  }
  raw_records=("${reply[@]}")

  for raw_record in "${raw_records[@]}"; do
    entry_oid="${raw_record%%$'\t'*}"
    remaining="${raw_record#*$'\t'}"
    short_oid="${remaining%%$'\t'*}"
    remaining="${remaining#*$'\t'}"
    selector="${remaining%%$'\t'*}"
    subject_text="${remaining#*$'\t'}"

    if [[ ! "$entry_oid" =~ '^[0-9A-Fa-f]+$' ]] ||
      (( ${#entry_oid} != 40 && ${#entry_oid} != 64 )); then
      _git_error "Git returned an invalid reflog OID."
      return 1
    fi
    entry_oids+=("$entry_oid")
    (( entry_index++ ))
    escaped_text=$(_git_display_escape "$selector $subject_text") || return 1
    record_text=$(_git_record_escape "$escaped_text") || return 1
    rows+=("${entry_index}"$'\t'"${short_oid}"$'\t'"${record_text}")
  done

  (( ${#rows[@]} > 0 )) || {
    _git_info "The reflog is empty."
    return 0
  }

  _git_history_select_ids \
    "git reflog" \
    "Enter page selected reflog commit | Esc cancel" \
    "2,3" "no" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0
  _git_history_values_for_ids entry_oids selected_ids || return 1
  selected_oids=("${reply[@]}")

  _git_history_page_git \
    show --show-signature --stat --color=always --no-ext-diff --no-textconv \
    "${selected_oids[1]}"
}

# --- File history and blame ---------------------------------------------------

_git_file_history_usage() {
  print -u2 -r -- "Usage: git-file-history [--help]"
  print -u2 -r -- "Select an opaque tracked path, then page one immutable historical diff."
}

git-file-history() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_file_history_usage
      return 0
    fi
    _git_error "Unknown argument for git-file-history: $1"
    _git_file_history_usage
    return 2
  fi

  _git_history_require_interactive || return 1

  local -a tracked_files=()
  local -a rows=()
  local -a selected_ids=()
  local -a selected_files=()
  local -a commit_fields=()
  local -a commit_rows=()
  local -a selected_oids=()
  local -a reply=()

  _git_history_capture_nul ls-files -z || {
    _git_error "Unable to enumerate tracked files."
    return 1
  }
  tracked_files=("${reply[@]}")
  (( ${#tracked_files[@]} > 0 )) || {
    _git_info "No tracked files are available."
    return 0
  }

  _git_history_rows "${tracked_files[@]}" || return 1
  rows=("${reply[@]}")
  _git_history_select_ids \
    "file history" \
    "Enter choose path | No live file preview | Esc cancel" \
    "2" "no" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0
  _git_history_values_for_ids tracked_files selected_ids || return 1
  selected_files=("${reply[@]}")
  local file_name="${selected_files[1]}"

  _git_history_collect_commits \
    log -z --follow -n 200 --format='%H%x09%h%x09%s' -- "$file_name" || {
    _git_error "Unable to collect file history."
    return 1
  }
  commit_fields=("${reply[@]}")
  (( ${#commit_fields[@]} > 0 )) || {
    _git_info "No commits were found for the selected path."
    return 0
  }

  _git_history_commit_rows commit_fields || return 1
  commit_rows=("${reply[@]}")
  _git_history_select_ids \
    "file commit" \
    "Enter page path diff at commit | Esc cancel" \
    "2,3" "no" "${commit_rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0
  _git_history_commit_oids_for_ids commit_fields selected_ids || return 1
  selected_oids=("${reply[@]}")

  local historical_file=""
  _git_history_path_at_commit \
    "$file_name" "${selected_oids[1]}" commit_fields || return 1
  historical_file="$REPLY"

  _git_history_page_git \
    show --show-signature --color=always --no-ext-diff --no-textconv \
    "${selected_oids[1]}" -- "$historical_file"
}

_git_blame_usage() {
  print -u2 -r -- "Usage: git-blame [--help]"
  print -u2 -r -- "Select an opaque tracked path and page Git blame output."
}

git-blame() {
  emulate -L zsh

  if (( $# > 0 )); then
    if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
      _git_blame_usage
      return 0
    fi
    _git_error "Unknown argument for git-blame: $1"
    _git_blame_usage
    return 2
  fi

  _git_history_require_interactive || return 1

  local -a tracked_files=()
  local -a rows=()
  local -a selected_ids=()
  local -a selected_files=()
  local -a reply=()

  _git_history_capture_nul ls-files -z || {
    _git_error "Unable to enumerate tracked files."
    return 1
  }
  tracked_files=("${reply[@]}")
  (( ${#tracked_files[@]} > 0 )) || {
    _git_info "No tracked files are available."
    return 0
  }

  _git_history_rows "${tracked_files[@]}" || return 1
  rows=("${reply[@]}")
  _git_history_select_ids \
    "git blame" \
    "Enter page blame | No live file preview | Esc cancel" \
    "2" "no" "${rows[@]}" || return 1
  selected_ids=("${reply[@]}")
  (( ${#selected_ids[@]} > 0 )) || return 0
  _git_history_values_for_ids tracked_files selected_ids || return 1
  selected_files=("${reply[@]}")

  _git_history_page_git \
    blame --color-by-age --color-lines -- "${selected_files[1]}"
}

typeset -g _GIT_HISTORY_SOURCED=1
