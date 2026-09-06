#!/usr/bin/env zsh
# =============================================================================
# Git Clean: planned cleanup of merged local and remote branches
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_CLEAN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Argument and confirmation helpers --------------------------------------

_git_clean_usage() {
  local command_name="$1"

  if [[ "$command_name" == "clean-remote-merged" ]]; then
    print -u2 -r -- \
      "Usage: $command_name [--dry-run] [--yes] [--remote REMOTE] [BRANCH ...]"
  else
    print -u2 -r -- \
      "Usage: $command_name [--dry-run] [--yes] [BRANCH ...]"
  fi
  print -u2 -r -- ""
  print -u2 -r -- \
    "Delete only branches merged into the repository's default branch."
  print -u2 -r -- \
    "With no flags or branch names, select eligible branches interactively."
  print -u2 -r -- \
    "With --dry-run or --yes and no names, target every eligible branch."
  print -u2 -r -- ""
  print -u2 -r -- \
    "  --dry-run       Display the frozen plan without deleting branches."
  print -u2 -r -- \
    "  --yes, -y       Skip confirmation; validation and revalidation still run."
  if [[ "$command_name" == "clean-remote-merged" ]]; then
    print -u2 -r -- \
      "  --remote NAME   Use this configured remote instead of the current remote."
  fi
}

# Sets dynamically scoped _git_clean_opt_* variables in the public caller.
_git_clean_parse_options() {
  local command_name="$1"
  local -i allow_remote="$2"
  shift 2

  _git_clean_opt_dry_run=0
  _git_clean_opt_yes=0
  _git_clean_opt_remote=""
  _git_clean_opt_targets=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        (( $# == 1 )) || {
          _git_error "--help accepts no additional arguments."
          return 2
        }
        _git_clean_usage "$command_name"
        return 3
        ;;
      --dry-run)
        _git_clean_opt_dry_run=1
        ;;
      -y|--yes)
        _git_clean_opt_yes=1
        ;;
      --remote)
        (( allow_remote )) || {
          _git_error "Unknown option for $command_name: $1"
          return 2
        }
        (( $# >= 2 )) || {
          _git_error "--remote requires a configured remote name."
          return 2
        }
        [[ -z "$_git_clean_opt_remote" ]] || {
          _git_error "--remote may be specified only once."
          return 2
        }
        _git_clean_opt_remote="$2"
        shift
        ;;
      --)
        shift
        _git_clean_opt_targets+=("$@")
        break
        ;;
      -*)
        _git_error "Unknown option for $command_name: $1"
        return 2
        ;;
      *)
        _git_clean_opt_targets+=("$1")
        ;;
    esac
    shift
  done

  if (( ! allow_remote )) && [[ -n "$_git_clean_opt_remote" ]]; then
    _git_error "--remote is not valid for $command_name."
    return 2
  fi
  if [[ -n "$_git_clean_opt_remote" ]] \
    && ! _git_validate_remote_token "$_git_clean_opt_remote"; then
    _git_error "Invalid remote name."
    return 2
  fi
  local target normalized
  for target in "${_git_clean_opt_targets[@]}"; do
    normalized="${target#refs/heads/}"
    _git_validate_branch_name "$normalized" || {
      _git_error "Invalid branch name: $(_git_display_escape "$target")"
      return 2
    }
  done
  if (( _git_clean_opt_dry_run && _git_clean_opt_yes )); then
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  fi
  return 0
}

# Sets REPLY to confirmed, cancelled, unavailable, or error.
_git_clean_confirm_outcome() {
  _git_confirm_outcome "$@"
}

_git_clean_authorize_plan() {
  local -i assume_yes="$1"
  local prompt="$2"
  (( assume_yes )) && return 0

  local REPLY=""
  _git_clean_confirm_outcome "$prompt" || return 1
  case "$REPLY" in
    confirmed)
      return 0
      ;;
    cancelled)
      _git_info "Cancelled. No branches were deleted."
      return 3
      ;;
    unavailable)
      _git_error \
        "Interactive confirmation requires a terminal; pass --yes after reviewing the plan."
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Repository and record helpers ------------------------------------------

_git_clean_validate_remote() {
  local requested="${1:-}"
  [[ -n "$requested" && "$requested" != -* \
    && "$requested" != *$'\n'* && "$requested" != *$'\r'* \
    && "$requested" != *$'\t'* ]] || {
    _git_error "Invalid remote name."
    return 2
  }

  local remotes
  remotes=$(command git remote 2>/dev/null) || {
    _git_error "Unable to list configured remotes."
    return 1
  }
  local candidate
  for candidate in "${(@f)remotes}"; do
    [[ "$candidate" == "$requested" ]] && return 0
  done

  _git_error "Remote '$(_git_display_escape "$requested")' is not configured."
  return 1
}

# Sets reply to oid<TAB>refs/heads/... records from the exact push target.
_git_clean_remote_snapshot() {
  local remote_name="$1"
  local push_url="$2"
  reply=()

  local output=""
  local -i remote_rc=0
  output=$(command git ls-remote \
    --refs --heads -- "$push_url" 2>/dev/null) \
    || remote_rc=$?
  if (( remote_rc != 0 )); then
    _git_error \
      "Unable to inspect branches on '$remote_name' (exit $remote_rc)."
    return $remote_rc
  fi
  [[ -z "$output" ]] && return 0

  local record oid ref
  for record in "${(@f)output}"; do
    [[ -n "$record" && "$record" == *$'\t'* ]] || {
      _git_error "The remote returned a malformed branch record."
      return 1
    }
    oid="${record%%$'\t'*}"
    ref="${record#*$'\t'}"
    _git_validate_oid "$oid" \
      && _git_validate_full_ref "$ref" \
      && [[ "$ref" == refs/heads/* ]] || {
      _git_error "The remote returned an invalid branch ref or object ID."
      return 1
    }
    reply+=("${oid}"$'\t'"${ref}")
  done
}

_git_clean_remote_find_oid() {
  local wanted_ref="$1"
  shift
  local -a records=("$@")
  REPLY="absent"

  local record
  for record in "${records[@]}"; do
    [[ "${record#*$'\t'}" == "$wanted_ref" ]] || continue
    REPLY="${record%%$'\t'*}"
    return 0
  done
}

_git_clean_remote_default_ref() {
  local remote_name="$1"
  local push_url="$2"
  local output=""
  local -i remote_rc=0
  output=$(command git ls-remote \
    --symref -- "$push_url" HEAD 2>/dev/null) \
    || remote_rc=$?
  if (( remote_rc != 0 )); then
    _git_error \
      "Unable to inspect the default branch on '$remote_name' (exit $remote_rc)."
    return $remote_rc
  fi

  local record symref target
  for record in "${(@f)output}"; do
    [[ "$record" == 'ref: '*$'\t''HEAD' ]] || continue
    symref="${record#ref: }"
    symref="${symref%%$'\t'*}"
    _git_validate_full_ref "$symref" \
      && [[ "$symref" == refs/heads/* ]] || {
      _git_error "The remote advertised an invalid default branch."
      return 1
    }
    REPLY="$symref"
    return 0
  done
  _git_error \
    "The remote default branch is unavailable; configure its HEAD and retry."
  return 1
}

# Sets REPLY to a stable digest and reply_refs to full refs checked out in any
# linked worktree.
_git_clean_worktree_snapshot() {
  local listing
  listing=$(command git worktree list --porcelain 2>/dev/null) || {
    _git_error "Unable to inspect linked worktrees."
    return 1
  }

  REPLY=$(print -rn -- "$listing" | command git hash-object --stdin \
    2>/dev/null) || return 1
  _git_validate_oid "$REPLY" || {
    _git_error "Unable to freeze the worktree state."
    return 1
  }

  reply_refs=()
  local line ref
  for line in "${(@f)listing}"; do
    [[ "$line" == "branch "* ]] || continue
    ref="${line#branch }"
    _git_validate_full_ref "$ref" || {
      _git_error "Git returned an invalid worktree branch reference."
      return 1
    }
    reply_refs+=("$ref")
  done
  return 0
}

_git_clean_is_checked_out() {
  local ref="$1"
  shift
  local checked_ref
  for checked_ref in "$@"; do
    [[ "$checked_ref" == "$ref" ]] && return 0
  done
  return 1
}

# Sets reply to canonical local-branch records:
#   short-name<TAB>refs/heads/name<TAB>object-id
_git_clean_collect_local_candidates() {
  local default_ref="$1"
  local default_oid="$2"
  local current_ref="$3"
  shift 3
  local -a checked_refs=("$@")

  local output
  output=$(command git for-each-ref \
    --format='%(refname)%09%(objectname)' \
    --merged "$default_oid" refs/heads 2>/dev/null) || {
    _git_error "Unable to enumerate merged local branches."
    return 1
  }

  reply=()
  local line ref oid short_name
  for line in "${(@f)output}"; do
    [[ -n "$line" && "$line" == *$'\t'* ]] || continue
    ref="${line%%$'\t'*}"
    oid="${line#*$'\t'}"
    _git_validate_full_ref "$ref" && _git_validate_oid "$oid" || {
      _git_error "Git returned an invalid local branch record."
      return 1
    }
    [[ "$ref" == refs/heads/* ]] || continue
    [[ "$ref" != "$default_ref" && "$ref" != "$current_ref" ]] || continue
    _git_clean_is_checked_out "$ref" "${checked_refs[@]}" && continue
    short_name="${ref#refs/heads/}"
    reply+=("${short_name}"$'\t'"${ref}"$'\t'"${oid}")
  done
  return 0
}

# Sets reply to canonical remote-branch records:
#   short-name<TAB>refs/heads/name<TAB>refs/remotes/remote/name<TAB>object-id
_git_clean_collect_remote_candidates() {
  local remote="$1"
  local default_tracking_ref="$2"
  local default_oid="$3"
  local current_ref="$4"

  local prefix="refs/remotes/${remote}/"
  local output
  output=$(command git for-each-ref \
    --format='%(refname)%09%(objectname)' \
    --merged "$default_oid" "$prefix" 2>/dev/null) || {
    _git_error "Unable to enumerate merged remote branches."
    return 1
  }

  reply=()
  local line tracking_ref oid short_name branch_ref
  for line in "${(@f)output}"; do
    [[ -n "$line" && "$line" == *$'\t'* ]] || continue
    tracking_ref="${line%%$'\t'*}"
    oid="${line#*$'\t'}"
    _git_validate_full_ref "$tracking_ref" && _git_validate_oid "$oid" || {
      _git_error "Git returned an invalid remote branch record."
      return 1
    }
    [[ "$tracking_ref" == "$prefix"* ]] || continue
    [[ "$tracking_ref" != "$default_tracking_ref" \
      && "$tracking_ref" != "${prefix}HEAD" ]] || continue

    short_name="${tracking_ref#$prefix}"
    branch_ref="refs/heads/${short_name}"
    _git_validate_branch_name "$short_name" \
      && _git_validate_full_ref "$branch_ref" || {
      _git_error "Git returned an invalid remote branch name."
      return 1
    }
    [[ "$branch_ref" != "$current_ref" ]] || continue
    reply+=("${short_name}"$'\t'"${branch_ref}"$'\t'"${tracking_ref}"$'\t'"${oid}")
  done
  return 0
}

# Filters canonical records by user-supplied short or full branch names.
_git_clean_filter_records() {
  local -i remote_records="$1"
  local -i record_count="$2"
  shift 2
  local -a records=("${@:1:$record_count}")
  shift "$record_count"
  local -a requested=("$@")

  if (( ${#requested[@]} == 0 )); then
    reply=("${records[@]}")
    return 0
  fi

  reply=()
  local target normalized record short_name full_ref matched
  local existing existing_ref
  for target in "${requested[@]}"; do
    if [[ "$target" == refs/heads/* ]]; then
      normalized="${target#refs/heads/}"
    else
      normalized="$target"
    fi
    _git_validate_branch_name "$normalized" || {
      _git_error "Invalid branch name: $(_git_display_escape "$target")"
      return 2
    }

    matched=""
    for record in "${records[@]}"; do
      short_name="${record%%$'\t'*}"
      full_ref="${${record#*$'\t'}%%$'\t'*}"
      if [[ "$target" == "$full_ref" || "$normalized" == "$short_name" ]]; then
        matched="$record"
        break
      fi
    done
    [[ -n "$matched" ]] || {
      _git_error \
        "Branch '$(_git_display_escape "$target")' is protected, checked out, unmerged, or absent."
      return 1
    }

    full_ref="${${matched#*$'\t'}%%$'\t'*}"
    local -i duplicate=0
    for existing in "${reply[@]}"; do
      existing_ref="${${existing#*$'\t'}%%$'\t'*}"
      [[ "$existing_ref" == "$full_ref" ]] && {
        duplicate=1
        break
      }
    done
    (( duplicate )) || reply+=("$matched")
  done
  return 0
}

# Selects one or more canonical records without reparsing display labels.
_git_clean_select_records() {
  local prompt="$1"
  local -i remote_records="$2"
  shift 2
  local -a records=("$@")
  reply=()

  _git_require_interactive || return 1

  local selected=""
  local -i picker_rc=0
  if (( remote_records )); then
    selected=$(printf '%s\n' "${records[@]}" | _git_fzf \
      --multi \
      --delimiter=$'\t' \
      --with-nth=1,4 \
      --preview='' \
      --preview-window=hidden \
      --header='Tab select | Enter accept | Esc cancel' \
      --prompt="$prompt > ") || picker_rc=$?
  else
    selected=$(printf '%s\n' "${records[@]}" | _git_fzf \
      --multi \
      --delimiter=$'\t' \
      --with-nth=1,3 \
      --preview='' \
      --preview-window=hidden \
      --header='Tab select | Enter accept | Esc cancel' \
      --prompt="$prompt > ") || picker_rc=$?
  fi

  if (( picker_rc != 0 )); then
    if _git_fzf_rc_is_cancel "$picker_rc"; then
      return 0
    fi
    _git_error "fzf failed while selecting branches (exit $picker_rc)."
    return $picker_rc
  fi
  if [[ -n "$selected" ]]; then
    local -a selected_records=("${(@f)selected}")
    local selected_record candidate
    local -i matched=0
    for selected_record in "${selected_records[@]}"; do
      matched=0
      for candidate in "${records[@]}"; do
        [[ "$selected_record" == "$candidate" ]] && {
          matched=1
          break
        }
      done
      if (( ! matched )); then
        _git_error "fzf returned a branch record outside the frozen candidate set."
        return 1
      fi
      reply+=("$selected_record")
    done
  fi
  return 0
}

_git_clean_show_local_plan() {
  local root="$1"
  local common_dir="$2"
  local head_oid="$3"
  local current_ref="$4"
  local default_ref="$5"
  local default_oid="$6"
  local worktree_digest="$7"
  shift 7
  local -a records=("$@")

  _git_label "Repository:" "$root"
  _git_label "Git common dir:" "$common_dir"
  _git_label "Worktree state:" "$worktree_digest"
  _git_label "HEAD:" "$head_oid"
  _git_label "Current branch:" "${current_ref:-(detached)}"
  _git_label "Default branch:" "$default_ref @ $default_oid"
  _git_label "Targets:" "${#records[@]} merged local branch(es)"
  _git_blank

  local record short_name ref oid
  for record in "${records[@]}"; do
    short_name="${record%%$'\t'*}"
    ref="${${record#*$'\t'}%%$'\t'*}"
    oid="${record##*$'\t'}"
    _git_dim "$short_name | $ref | $oid"
  done
}

_git_clean_show_remote_plan() {
  local root="$1"
  local common_dir="$2"
  local head_oid="$3"
  local current_ref="$4"
  local remote="$5"
  local remote_url="$6"
  local default_ref="$7"
  local default_oid="$8"
  local worktree_digest="$9"
  shift 9
  local -a records=("$@")

  _git_label "Repository:" "$root"
  _git_label "Git common dir:" "$common_dir"
  _git_label "Worktree state:" "$worktree_digest"
  _git_label "HEAD:" "$head_oid"
  _git_label "Current branch:" "${current_ref:-(detached)}"
  _git_label "Remote:" "$remote"
  _git_label "Push URL:" "$(_git_redact_remote_url "$remote_url")"
  _git_label "Default branch:" "$default_ref @ $default_oid"
  _git_label "Targets:" "${#records[@]} merged remote branch(es)"
  _git_blank

  local record short_name remainder branch_ref tracking_ref oid
  for record in "${records[@]}"; do
    short_name="${record%%$'\t'*}"
    remainder="${record#*$'\t'}"
    branch_ref="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    tracking_ref="${remainder%%$'\t'*}"
    oid="${remainder##*$'\t'}"
    _git_dim "$short_name | $branch_ref | $tracking_ref | $oid"
  done
}

_git_clean_revalidate_base() {
  local root="$1"
  local common_dir="$2"
  local head_oid="$3"
  local fingerprint="$4"
  local current_ref="$5"
  local default_ref="$6"
  local default_oid="$7"
  local worktree_digest="$8"

  _git_require_same_context "$root" "$head_oid" "$fingerprint" || return 1

  local actual_common_dir
  actual_common_dir=$(command git rev-parse --git-common-dir 2>/dev/null) \
    || return 1
  [[ "$actual_common_dir" == /* ]] || actual_common_dir="$root/$actual_common_dir"
  actual_common_dir="${actual_common_dir:A}"
  [[ "$actual_common_dir" == "$common_dir" ]] || {
    _git_error "The repository's common directory changed after planning."
    return 1
  }

  local actual_current_ref=""
  actual_current_ref=$(command git symbolic-ref --quiet HEAD 2>/dev/null) \
    || actual_current_ref=""
  [[ "$actual_current_ref" == "$current_ref" ]] || {
    _git_error "The current branch changed after planning."
    return 1
  }

  local actual_default_oid
  actual_default_oid=$(command git rev-parse --verify \
    "${default_ref}^{commit}" 2>/dev/null) || {
    _git_error "The default branch disappeared after planning."
    return 1
  }
  [[ "$actual_default_oid" == "$default_oid" ]] || {
    _git_error "The default branch changed after planning."
    return 1
  }

  local REPLY=""
  local -a reply_refs=()
  _git_clean_worktree_snapshot || return 1
  [[ "$REPLY" == "$worktree_digest" ]] || {
    _git_error "Linked worktree state changed after planning."
    return 1
  }
  return 0
}

# --- Local branch cleanup ----------------------------------------------------

clean-branches() {
  emulate -L zsh

  local -i _git_clean_opt_dry_run=0 _git_clean_opt_yes=0
  local _git_clean_opt_remote=""
  local -a _git_clean_opt_targets=()
  local -i parse_rc=0

  _git_clean_parse_options clean-branches 0 "$@" || parse_rc=$?
  (( parse_rc == 3 )) && return 0
  (( parse_rc != 0 )) && return $parse_rc

  _git_require_repo || return 1
  _git_header "Clean Merged Local Branches"
  _git_context_refresh || return 1

  local root="${_GIT_CONTEXT[root]}"
  local common_dir="${_GIT_CONTEXT[common_dir]}"
  local head_oid="${_GIT_CONTEXT[head]}"
  local fingerprint="${_GIT_CONTEXT[fingerprint]}"
  local current_ref=""
  current_ref=$(command git symbolic-ref --quiet HEAD 2>/dev/null) \
    || current_ref=""

  local default_name
  default_name=$(_git_get_default_branch) || {
    _git_error "Unable to determine the default branch."
    return 1
  }
  _git_validate_branch_name "$default_name" || {
    _git_error "The configured default branch is invalid."
    return 1
  }
  local default_ref="refs/heads/${default_name}"
  local default_oid
  default_oid=$(command git rev-parse --verify \
    "${default_ref}^{commit}" 2>/dev/null) || {
    _git_error "Default branch '$default_name' does not exist locally."
    return 1
  }
  _git_validate_oid "$default_oid" || return 1

  local worktree_digest=""
  local -a checked_refs=()
  local REPLY=""
  local -a reply=()
  local -a reply_refs=()
  _git_clean_worktree_snapshot || return 1
  worktree_digest="$REPLY"
  checked_refs=("${reply_refs[@]}")

  local -a candidates=()
  _git_clean_collect_local_candidates \
    "$default_ref" "$default_oid" "$current_ref" "${checked_refs[@]}" \
    || return $?
  candidates=("${reply[@]}")
  if (( ${#candidates[@]} == 0 )); then
    _git_success "No eligible merged local branches were found."
    return 0
  fi

  local -a plan=()
  if (( ${#_git_clean_opt_targets[@]} > 0 \
    || _git_clean_opt_dry_run || _git_clean_opt_yes )); then
    _git_clean_filter_records 0 "${#candidates[@]}" "${candidates[@]}" \
      "${_git_clean_opt_targets[@]}" || return $?
    plan=("${reply[@]}")
  else
    _git_clean_select_records \
      "merged local branches" 0 "${candidates[@]}" || return $?
    plan=("${reply[@]}")
    if (( ${#plan[@]} == 0 )); then
      _git_info "Cancelled. No branches were selected."
      return 0
    fi
  fi

  (( ${#plan[@]} > 0 )) || {
    _git_success "No eligible merged local branches were selected."
    return 0
  }

  _git_clean_show_local_plan \
    "$root" "$common_dir" "$head_oid" "$current_ref" \
    "$default_ref" "$default_oid" "$worktree_digest" "${plan[@]}"

  if (( _git_clean_opt_dry_run )); then
    _git_warn "DRY-RUN — no local branches were deleted."
    return 0
  fi

  local -i authorize_rc=0
  _git_clean_authorize_plan "$_git_clean_opt_yes" \
    "Delete ${#plan[@]} merged local branch(es)?" || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  _git_clean_revalidate_base \
    "$root" "$common_dir" "$head_oid" "$fingerprint" "$current_ref" \
    "$default_ref" "$default_oid" "$worktree_digest" || return 1

  local -i deleted=0 failed=0
  local record ref oid actual_oid
  for record in "${plan[@]}"; do
    ref="${${record#*$'\t'}%%$'\t'*}"
    oid="${record##*$'\t'}"

    actual_oid=$(command git rev-parse --verify "${ref}^{commit}" \
      2>/dev/null) || actual_oid=""
    if [[ "$actual_oid" != "$oid" ]] \
      || ! command git merge-base --is-ancestor "$oid" "$default_oid" \
        2>/dev/null; then
      _git_error \
        "Refused changed or no-longer-merged branch: $(_git_display_escape "$ref")"
      failed=$(( failed + 1 ))
      continue
    fi

    local current_worktree_digest=""
    local -a current_checked_refs=()
    REPLY=""
    reply=()
    reply_refs=()
    if ! _git_clean_worktree_snapshot; then
      failed=$(( failed + 1 ))
      continue
    fi
    current_worktree_digest="$REPLY"
    current_checked_refs=("${reply_refs[@]}")
    if [[ "$current_worktree_digest" != "$worktree_digest" ]] \
      || _git_clean_is_checked_out "$ref" "${current_checked_refs[@]}"; then
      _git_error \
        "Refused branch after linked worktree state changed: $(_git_display_escape "$ref")"
      failed=$(( failed + 1 ))
      continue
    fi

    if command git update-ref -d "$ref" "$oid" 2>/dev/null; then
      _git_success "Deleted $(_git_display_escape "$ref") at $oid."
      deleted=$(( deleted + 1 ))
    else
      _git_error "Failed to delete $(_git_display_escape "$ref")."
      failed=$(( failed + 1 ))
    fi
  done

  if (( failed > 0 )); then
    _git_error \
      "Local cleanup incomplete: $deleted deleted, $failed failed."
    return 1
  fi
  _git_success "Local cleanup complete: $deleted branch(es) deleted."
  return 0
}

# --- Remote merged branch cleanup -------------------------------------------

clean-remote-merged() {
  emulate -L zsh

  local -i _git_clean_opt_dry_run=0 _git_clean_opt_yes=0
  local _git_clean_opt_remote=""
  local -a _git_clean_opt_targets=()
  local -i parse_rc=0

  _git_clean_parse_options clean-remote-merged 1 "$@" || parse_rc=$?
  (( parse_rc == 3 )) && return 0
  (( parse_rc != 0 )) && return $parse_rc

  _git_require_repo || return 1
  _git_header "Clean Merged Remote Branches"

  local remote="$_git_clean_opt_remote"
  [[ -n "$remote" ]] || remote=$(_git_current_remote 2>/dev/null)
  [[ -n "$remote" ]] || {
    _git_error "No current remote is configured; pass --remote NAME."
    return 1
  }
  _git_clean_validate_remote "$remote" || return $?

  local REPLY=""
  _git_remote_push_url "$remote" || return 1
  local push_url="$REPLY"
  local -a reply=()
  local -a remote_snapshot=()
  _git_clean_remote_snapshot "$remote" "$push_url" || return $?
  remote_snapshot=("${reply[@]}")
  _git_clean_remote_default_ref "$remote" "$push_url" || return $?
  local default_ref="$REPLY"
  _git_clean_remote_find_oid "$default_ref" "${remote_snapshot[@]}"
  local default_oid="$REPLY"
  [[ "$default_oid" != "absent" ]] || {
    _git_error "The remote default branch is absent from the push target."
    return 1
  }

  _git_context_refresh || return 1
  local root="${_GIT_CONTEXT[root]}"
  local common_dir="${_GIT_CONTEXT[common_dir]}"
  local head_oid="${_GIT_CONTEXT[head]}"
  local fingerprint="${_GIT_CONTEXT[fingerprint]}"
  local current_ref=""
  current_ref=$(command git symbolic-ref --quiet HEAD 2>/dev/null) \
    || current_ref=""

  local default_name="${default_ref#refs/heads/}"
  _git_validate_branch_name "$default_name" || {
    _git_error "The remote default branch is invalid."
    return 1
  }
  local default_tracking_ref="refs/remotes/${remote}/${default_name}"
  local tracking_default_oid
  tracking_default_oid=$(command git rev-parse --verify \
    "${default_tracking_ref}^{commit}" 2>/dev/null) || {
    _git_error \
      "Remote default branch '$default_tracking_ref' is unavailable locally; fetch and retry."
    return 1
  }
  [[ "$tracking_default_oid" == "$default_oid" ]] || {
    _git_error \
      "Remote-tracking refs are stale; run an explicit fetch-and-prune, then retry."
    return 1
  }

  local worktree_digest=""
  local -a reply_refs=()
  _git_clean_worktree_snapshot || return 1
  worktree_digest="$REPLY"

  local -a candidates=()
  _git_clean_collect_remote_candidates \
    "$remote" "$default_tracking_ref" "$default_oid" "$current_ref" \
    || return $?
  candidates=("${reply[@]}")

  local candidate remainder branch_ref candidate_oid
  for candidate in "${candidates[@]}"; do
    remainder="${candidate#*$'\t'}"
    branch_ref="${remainder%%$'\t'*}"
    candidate_oid="${candidate##*$'\t'}"
    _git_clean_remote_find_oid "$branch_ref" "${remote_snapshot[@]}"
    [[ "$REPLY" == "$candidate_oid" ]] || {
      _git_error \
        "Remote-tracking refs are stale; run an explicit fetch-and-prune, then retry."
      return 1
    }
  done
  if (( ${#candidates[@]} == 0 )); then
    _git_success "No eligible merged remote branches were found."
    return 0
  fi

  local -a plan=()
  if (( ${#_git_clean_opt_targets[@]} > 0 \
    || _git_clean_opt_dry_run || _git_clean_opt_yes )); then
    _git_clean_filter_records 1 "${#candidates[@]}" "${candidates[@]}" \
      "${_git_clean_opt_targets[@]}" || return $?
    plan=("${reply[@]}")
  else
    _git_clean_select_records \
      "merged remote branches" 1 "${candidates[@]}" || return $?
    plan=("${reply[@]}")
    if (( ${#plan[@]} == 0 )); then
      _git_info "Cancelled. No branches were selected."
      return 0
    fi
  fi

  (( ${#plan[@]} > 0 )) || {
    _git_success "No eligible merged remote branches were selected."
    return 0
  }

  _git_clean_show_remote_plan \
    "$root" "$common_dir" "$head_oid" "$current_ref" \
    "$remote" "$push_url" "$default_tracking_ref" "$default_oid" \
    "$worktree_digest" "${plan[@]}"

  if (( _git_clean_opt_dry_run )); then
    _git_warn "DRY-RUN — no remote branches were deleted."
    return 0
  fi

  local -i authorize_rc=0
  _git_clean_authorize_plan "$_git_clean_opt_yes" \
    "Delete ${#plan[@]} merged branch(es) from '$remote'?" \
    || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  _git_clean_revalidate_base \
    "$root" "$common_dir" "$head_oid" "$fingerprint" "$current_ref" \
    "$default_tracking_ref" "$default_oid" "$worktree_digest" || return 1
  _git_clean_validate_remote "$remote" || return 1
  _git_remote_push_url "$remote" || return 1
  local current_push_url="$REPLY"
  [[ "$current_push_url" == "$push_url" ]] || {
    _git_error "The push URL for '$remote' changed after planning."
    return 1
  }
  local -a current_remote_snapshot=()
  _git_clean_remote_snapshot "$remote" "$push_url" || return $?
  current_remote_snapshot=("${reply[@]}")
  _git_clean_remote_find_oid "$default_ref" "${current_remote_snapshot[@]}"
  [[ "$REPLY" == "$default_oid" ]] || {
    _git_error "The remote default branch changed after planning."
    return 1
  }

  local -i deleted=0 failed=0
  local record tracking_ref oid actual_oid
  for record in "${plan[@]}"; do
    remainder="${record#*$'\t'}"
    branch_ref="${remainder%%$'\t'*}"
    remainder="${remainder#*$'\t'}"
    tracking_ref="${remainder%%$'\t'*}"
    oid="${remainder##*$'\t'}"

    _git_clean_remote_find_oid "$branch_ref" "${current_remote_snapshot[@]}"
    actual_oid="$REPLY"
    if [[ "$actual_oid" != "$oid" ]] \
      || ! command git merge-base --is-ancestor "$oid" "$default_oid" \
        2>/dev/null; then
      _git_error \
        "Refused changed or no-longer-merged remote branch: $(_git_display_escape "$branch_ref")"
      failed=$(( failed + 1 ))
      continue
    fi

    _git_remote_push_url "$remote" || {
      failed=$(( failed + 1 ))
      continue
    }
    current_push_url="$REPLY"
    if [[ "$current_push_url" != "$push_url" ]]; then
      _git_error "The push URL for '$remote' changed during cleanup."
      failed=$(( failed + 1 ))
      continue
    fi

    local -a push_cmd=(
      command git push
      "--force-with-lease=${branch_ref}:${oid}"
      --
      "$push_url"
      ":${branch_ref}"
    )
    "${push_cmd[@]}" >&2
    local -i push_rc=$?
    if (( push_rc == 0 )); then
      _git_success \
        "Deleted $remote/$(_git_display_escape "${branch_ref#refs/heads/}") at $oid."
      deleted=$(( deleted + 1 ))
    else
      _git_error \
        "Failed to delete $(_git_display_escape "$branch_ref") from '$remote' (exit $push_rc)."
      failed=$(( failed + 1 ))
    fi
  done

  if (( failed > 0 )); then
    _git_error \
      "Remote cleanup incomplete: $deleted deleted, $failed failed."
    return 1
  fi
  _git_success "Remote cleanup complete: $deleted branch(es) deleted."
  return 0
}

typeset -g _GIT_CLEAN_SOURCED=1
