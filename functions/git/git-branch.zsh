#!/usr/bin/env zsh
# =============================================================================
# Git Branch: switch, create, rename, merge, and rebase branches
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_BRANCH_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_git_branch_usage() {
  local command_name="${1:-git-switch}"
  case "$command_name" in
    git-switch)
      print -u2 -r -- "Usage: git-switch [branch]"
      print -u2 -r -- "Switch to a local branch or track an exact remote branch."
      ;;
    git-branch-create)
      print -u2 -r -- "Usage: git-branch-create [name [base-ref]]"
      print -u2 -r -- "Create and switch to a validated branch."
      ;;
    git-branch-rename)
      print -u2 -r -- "Usage: git-branch-rename [old-name new-name]"
      print -u2 -r -- "Rename an exact local branch."
      ;;
    git-merge)
      print -u2 -r -- \
        "Usage: git-merge [source] [--no-ff|--ff-only|--squash] [--yes]"
      print -u2 -r -- "Merge a captured source OID into the current branch."
      ;;
    git-rebase)
      print -u2 -r -- \
        "Usage: git-rebase [onto-branch] [--yes]"
      print -u2 -r -- \
        "       git-rebase --interactive <count> [--yes]"
      print -u2 -r -- \
        "       git-rebase --continue|--abort|--skip"
      ;;
  esac
  print -u2 -r -- "       ${command_name} --help"
}

_git_branch_parse_help() {
  local command_name="$1"
  shift
  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _git_branch_usage "$command_name"
    return 0
  fi
  return 1
}

_git_branch_verify_head() {
  local expected_branch="$1"
  local expected_oid="$2"
  local actual_branch actual_oid
  actual_branch=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || return 1
  actual_oid=$(command git rev-parse --verify HEAD 2>/dev/null) || return 1
  [[ "$actual_branch" == "$expected_branch" \
    && "$actual_oid" == "$expected_oid" ]]
}

# stdout: selected numeric index. Ref names cannot contain control characters,
# while their display form is escaped before becoming an fzf row.
_git_branch_pick_ref() {
  local prompt="${1:-Branch}"
  local include_remote="${2:-1}"
  local excluded_ref="${3:-}"
  local refs_output
  refs_output=$(command git for-each-ref \
    --format='%(refname)%09%(objectname)' \
    refs/heads refs/remotes 2>/dev/null) || return 1

  local -a refs=() oids=() rows=()
  local line ref oid display kind
  local -i index=0
  for line in "${(@f)refs_output}"; do
    ref="${line%%$'\t'*}"
    oid="${line#*$'\t'}"
    [[ "$ref" == "$excluded_ref" ]] && continue
    [[ "$ref" == refs/remotes/*/HEAD ]] && continue
    if [[ "$ref" == refs/remotes/* ]]; then
      (( include_remote )) || continue
      kind="remote"
      display="${ref#refs/remotes/}"
    else
      kind="local"
      display="${ref#refs/heads/}"
    fi
    _git_validate_oid "$oid" || continue
    refs+=("$ref")
    oids+=("$oid")
    (( index++ ))
    rows+=("$(_git_record_escape "$display")|$index|$kind branch at ${oid[1,12]}")
  done

  (( ${#rows[@]} > 0 )) || {
    _git_warn "No selectable branches were found."
    return 1
  }

  local selected
  local -i fzf_rc=0
  selected=$(printf '%s\n' "${rows[@]}" | _git_fzf \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt="${prompt} > " \
    --header='Up/Down navigate | Enter select | Esc cancel' \
    --preview='printf "%s\n" {3}' \
    --preview-window='down:3:wrap') || fzf_rc=$?
  if (( fzf_rc != 0 )); then
    _git_fzf_rc_is_cancel "$fzf_rc" && return 3
    _git_error "fzf failed while selecting a branch (exit $fzf_rc)."
    return 1
  fi
  local selected_index="${${selected#*|}%%|*}"
  [[ "$selected_index" == <-> \
    && selected_index -ge 1 \
    && selected_index -le ${#refs[@]} ]] || return 1

  reply=("${refs[$selected_index]}" "${oids[$selected_index]}")
  return 0
}

_git_branch_read_name() {
  local prompt="$1"
  local branch_name
  printf '%s' "$prompt" >&2
  IFS= read -r branch_name
  [[ -n "$branch_name" ]] || return 1
  _git_validate_branch_name "$branch_name" || {
    _git_error "Invalid branch name: $branch_name"
    return 2
  }
  REPLY="$branch_name"
}

git-switch() {
  emulate -L zsh

  _git_branch_parse_help git-switch "$@" && return 0
  (( $# <= 1 )) || {
    _git_error "git-switch accepts at most one branch."
    return 2
  }
  [[ "${1:-}" != -* ]] || {
    _git_error "Unknown option: $1"
    return 2
  }
  if (( $# == 1 )); then
    _git_validate_branch_name "$1" || {
      _git_error "Invalid branch name: $1"
      return 2
    }
  fi
  _git_require_repo || return 1

  local ref="" expected_oid="" branch_name="" remote="" remote_branch=""
  if (( $# == 1 )); then
    branch_name="$1"
    if command git show-ref --verify --quiet "refs/heads/$branch_name"; then
      ref="refs/heads/$branch_name"
    else
      local -a matches=(
        "${(@f)$(command git for-each-ref \
          --format='%(refname)' "refs/remotes/*/$branch_name" 2>/dev/null)}"
      )
      matches=("${(@)matches:#refs/remotes/*/HEAD}")
      (( ${#matches[@]} == 1 )) || {
        _git_error \
          "Branch '$branch_name' is neither local nor uniquely available on a remote."
        return 1
      }
      ref="${matches[1]}"
    fi
    expected_oid=$(command git rev-parse --verify "${ref}^{commit}" 2>/dev/null) \
      || return 1
  else
    _git_require_interactive || return 1
    local -a reply=()
    local -i picker_rc=0
    _git_branch_pick_ref "Switch branch" 1 || picker_rc=$?
    if (( picker_rc != 0 )); then
      (( picker_rc == 3 )) && return 0
      return $picker_rc
    fi
    ref="${reply[1]}"
    expected_oid="${reply[2]}"
  fi

  local current_oid
  current_oid=$(command git rev-parse --verify "${ref}^{commit}" 2>/dev/null) \
    || {
      _git_error "The selected branch no longer resolves to a commit."
      return 1
    }
  [[ "$current_oid" == "$expected_oid" ]] || {
    _git_error "The selected branch changed while it was being reviewed."
    return 1
  }

  if [[ "$ref" == refs/heads/* ]]; then
    branch_name="${ref#refs/heads/}"
    command git switch "$branch_name" >&2
    local -i switch_rc=$?
    if (( switch_rc != 0 )); then
      _git_error "Unable to switch to $branch_name (exit $switch_rc)."
      return $switch_rc
    fi
    _git_branch_verify_head "$branch_name" "$expected_oid" || {
      _git_error \
        "Branch state changed while switching; inspect HEAD before retrying."
      return 1
    }
    _git_success "Switched to $branch_name."
    return 0
  fi

  local remote_ref="${ref#refs/remotes/}"
  local candidate_remote
  local -a remotes=("${(@f)$(command git remote 2>/dev/null)}")
  for candidate_remote in "${remotes[@]}"; do
    if [[ "$remote_ref" == "$candidate_remote/"* ]] \
      && (( ${#candidate_remote} > ${#remote} )); then
      remote="$candidate_remote"
    fi
  done
  [[ -n "$remote" ]] || {
    _git_error "Unable to identify the selected remote."
    return 1
  }
  _git_validate_remote_token "$remote" || {
    _git_error "The selected remote name is unsafe."
    return 1
  }
  remote_branch="${remote_ref#${remote}/}"
  _git_validate_branch_name "$remote_branch" || {
    _git_error "The remote branch cannot become a safe local branch name."
    return 1
  }
  if command git show-ref --verify --quiet "refs/heads/$remote_branch"; then
    command git switch "$remote_branch" >&2
    local -i switch_rc=$?
    if (( switch_rc != 0 )); then
      _git_error "Unable to switch to $remote_branch (exit $switch_rc)."
      return $switch_rc
    fi
    _git_branch_verify_head "$remote_branch" "$expected_oid" || {
      _git_error \
        "Branch state changed while switching; inspect HEAD before retrying."
      return 1
    }
    _git_success "Switched to $remote_branch."
  else
    command git switch -c "$remote_branch" "$expected_oid" >&2
    local -i switch_rc=$?
    if (( switch_rc != 0 )); then
      _git_error "Unable to create $remote_branch (exit $switch_rc)."
      return $switch_rc
    fi
    _git_branch_verify_head "$remote_branch" "$expected_oid" || {
      _git_error \
        "Branch state changed while switching; $remote_branch was created."
      return 1
    }
    current_oid=$(command git rev-parse --verify "${ref}^{commit}" \
      2>/dev/null) || current_oid=""
    if [[ "$current_oid" != "$expected_oid" ]]; then
      _git_warn \
        "$remote_branch was created, but the remote branch changed; upstream was not configured."
      return 1
    fi
    command git branch --set-upstream-to="$remote/$remote_branch" \
      "$remote_branch" >&2 || {
      _git_warn \
        "$remote_branch was created, but its upstream could not be configured."
      return 1
    }
    _git_success "Created $remote_branch tracking $remote/$remote_branch."
  fi
}

git-branch-create() {
  emulate -L zsh

  _git_branch_parse_help git-branch-create "$@" && return 0
  (( $# <= 2 )) || {
    _git_error "git-branch-create accepts a name and optional base ref."
    return 2
  }
  [[ "${1:-}" != -* && "${2:-}" != -* ]] || {
    _git_error "Unknown option."
    return 2
  }
  if [[ -n "${1:-}" ]]; then
    _git_validate_branch_name "$1" || {
      _git_error "Invalid branch name: $1"
      return 2
    }
  fi
  [[ "${2:-}" != *$'\n'* && "${2:-}" != *$'\r'* ]] || {
    _git_error "Invalid base ref."
    return 2
  }
  _git_require_repo || return 1

  local new_name="${1:-}"
  local base_ref="${2:-}"
  local base_oid=""
  if [[ -z "$base_ref" ]]; then
    if [[ -n "$new_name" ]]; then
      base_ref="HEAD"
    else
      _git_require_interactive || return 1
      local -a reply=()
      local -i picker_rc=0
      _git_branch_pick_ref "Base branch" 1 || picker_rc=$?
      if (( picker_rc != 0 )); then
        (( picker_rc == 3 )) && return 0
        return $picker_rc
      fi
      base_ref="${reply[1]}"
      base_oid="${reply[2]}"
    fi
  fi

  if [[ -z "$new_name" ]]; then
    _git_branch_read_name "New branch name: " || {
      local -i read_rc=$?
      (( read_rc == 1 )) && return 0
      return $read_rc
    }
    new_name="$REPLY"
  fi

  command git show-ref --verify --quiet "refs/heads/$new_name" && {
    _git_error "Local branch '$new_name' already exists."
    return 1
  }
  [[ "$base_ref" != -* && "$base_ref" != *$'\n'* ]] || {
    _git_error "Invalid base ref."
    return 2
  }
  local resolved_base
  resolved_base=$(command git rev-parse --verify "${base_ref}^{commit}" \
    2>/dev/null) || {
      _git_error "Base ref '$base_ref' does not resolve to a commit."
      return 1
    }
  [[ -z "$base_oid" || "$resolved_base" == "$base_oid" ]] || {
    _git_error "The selected base branch changed; retry."
    return 1
  }

  _git_run_report \
    "Created and switched to $new_name at ${resolved_base[1,12]}." \
    "Unable to create branch $new_name" \
    command git switch -c "$new_name" "$resolved_base"
}

git-branch-rename() {
  emulate -L zsh

  _git_branch_parse_help git-branch-rename "$@" && return 0
  (( $# == 0 || $# == 2 )) || {
    _git_error "Provide both old and new branch names, or neither."
    return 2
  }
  if (( $# == 2 )); then
    _git_validate_branch_name "$1" \
      && _git_validate_branch_name "$2" || {
      _git_error "Invalid branch name."
      return 2
    }
  fi
  _git_require_repo || return 1

  local old_name="${1:-}"
  local new_name="${2:-}"
  local expected_oid=""
  if (( $# == 0 )); then
    _git_require_interactive || return 1
    local -a reply=()
    local -i picker_rc=0
    _git_branch_pick_ref "Rename branch" 0 || picker_rc=$?
    if (( picker_rc != 0 )); then
      (( picker_rc == 3 )) && return 0
      return $picker_rc
    fi
    old_name="${reply[1]#refs/heads/}"
    expected_oid="${reply[2]}"
    _git_branch_read_name "New name for $(_git_display_escape "$old_name"): " \
      || {
        local -i read_rc=$?
        (( read_rc == 1 )) && return 0
        return $read_rc
      }
    new_name="$REPLY"
  else
    expected_oid=$(command git rev-parse --verify \
      "refs/heads/${old_name}^{commit}" 2>/dev/null) || {
      _git_error "Local branch '$old_name' does not exist."
      return 1
    }
  fi

  command git show-ref --verify --quiet "refs/heads/$new_name" && {
    _git_error "Local branch '$new_name' already exists."
    return 1
  }
  local current_oid
  current_oid=$(command git rev-parse --verify \
    "refs/heads/${old_name}^{commit}" 2>/dev/null) || return 1
  [[ "$current_oid" == "$expected_oid" ]] || {
    _git_error "The selected branch changed; retry."
    return 1
  }
  command git branch -m "$old_name" "$new_name" >&2
  local -i rename_rc=$?
  if (( rename_rc != 0 )); then
    _git_error "Unable to rename $old_name (exit $rename_rc)."
    return $rename_rc
  fi
  current_oid=$(command git rev-parse --verify \
    "refs/heads/${new_name}^{commit}" 2>/dev/null) || current_oid=""
  if [[ "$current_oid" != "$expected_oid" ]] \
    || command git show-ref --verify --quiet "refs/heads/$old_name"; then
    _git_error \
      "Branch state changed during rename; inspect it before retrying."
    return 1
  fi
  _git_success "Renamed $old_name to $new_name."
  return 0
}

git-merge() {
  emulate -L zsh

  _git_branch_parse_help git-merge "$@" && return 0
  local source_ref=""
  local strategy=""
  local -i assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --no-ff|--ff-only|--squash)
        [[ -z "$strategy" ]] || {
          _git_error "Choose only one merge strategy."
          return 2
        }
        strategy="$1"
        ;;
      --yes)
        assume_yes=1
        ;;
      -*)
        _git_error "Unknown git-merge option: $1"
        return 2
        ;;
      *)
        [[ -z "$source_ref" ]] || {
          _git_error "git-merge accepts one source branch."
          return 2
        }
        source_ref="$1"
        ;;
    esac
    shift
  done
  [[ "$source_ref" != *$'\n'* && "$source_ref" != *$'\r'* ]] || {
    _git_error "Invalid source ref."
    return 2
  }
  _git_require_repo || return 1

  local source_oid=""
  if [[ -z "$source_ref" ]]; then
    _git_require_interactive || return 1
    local current_full_ref
    current_full_ref=$(command git symbolic-ref --quiet HEAD 2>/dev/null) \
      || {
        _git_error "Merge requires an attached current branch."
        return 1
      }
    local -a reply=()
    local -i picker_rc=0
    _git_branch_pick_ref "Merge from" 1 "$current_full_ref" \
      || picker_rc=$?
    if (( picker_rc != 0 )); then
      (( picker_rc == 3 )) && return 0
      return $picker_rc
    fi
    source_ref="${reply[1]}"
    source_oid="${reply[2]}"

    local selected_strategy
    local -i fzf_rc=0
    selected_strategy=$(printf '%s\n' \
      "Fast-forward when possible|" \
      "Create a merge commit|--no-ff" \
      "Fast-forward only|--ff-only" \
      "Squash changes into the index|--squash" |
      _git_fzf --delimiter='[|]' --with-nth=1 \
        --height=25% --prompt='Merge strategy > ' \
        --header='Up/Down navigate | Enter select | Esc cancel') \
      || fzf_rc=$?
    if (( fzf_rc != 0 )); then
      _git_fzf_rc_is_cancel "$fzf_rc" && return 0
      return 1
    fi
    strategy="${selected_strategy#*|}"
  else
    [[ "$source_ref" != -* && "$source_ref" != *$'\n'* ]] || {
      _git_error "Invalid source ref."
      return 2
    }
    source_oid=$(command git rev-parse --verify "${source_ref}^{commit}" \
      2>/dev/null) || {
      _git_error "Source '$source_ref' does not resolve to a commit."
      return 1
    }
  fi

  _git_context_refresh || return 1
  local expected_root="${_GIT_CONTEXT[root]}"
  local expected_head="${_GIT_CONTEXT[head]}"
  local expected_fingerprint="${_GIT_CONTEXT[fingerprint]}"
  local current_source_oid
  current_source_oid=$(command git rev-parse --verify "${source_ref}^{commit}" \
    2>/dev/null) || return 1
  [[ "$current_source_oid" == "$source_oid" ]] || {
    _git_error "The merge source changed; retry."
    return 1
  }

  _git_header "Merge Plan"
  _git_label "Current:" "${_GIT_CONTEXT[branch]} @ ${expected_head[1,12]}"
  _git_label "Source:" "$source_ref @ ${source_oid[1,12]}"
  _git_label "Strategy:" "${strategy:-default}"
  local -i authorize_rc=0
  _git_authorize "$assume_yes" "Execute this merge plan?" \
    || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc
  _git_require_same_context \
    "$expected_root" "$expected_head" "$expected_fingerprint" || return 1
  current_source_oid=$(command git rev-parse --verify "${source_ref}^{commit}" \
    2>/dev/null) || return 1
  [[ "$current_source_oid" == "$source_oid" ]] || {
    _git_error "The merge source changed after authorization."
    return 1
  }

  local -a merge_args=()
  [[ -n "$strategy" ]] && merge_args+=("$strategy")
  command git merge "${merge_args[@]}" "$source_oid" >&2
  local -i merge_rc=$?
  if (( merge_rc == 0 )); then
    [[ "$strategy" == "--squash" ]] \
      && _git_success "Squash result is staged for review." \
      || _git_success "Merge completed."
  else
    _git_error "Merge failed (exit $merge_rc)."
    _git_info "Resolve conflicts and commit, or run 'git merge --abort'."
  fi
  return $merge_rc
}

git-rebase() {
  emulate -L zsh

  _git_branch_parse_help git-rebase "$@" && return 0
  local mode="onto"
  local target=""
  local count=""
  local -i assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --continue|--abort|--skip)
        [[ "$mode" == "onto" && -z "$target" && -z "$count" ]] || {
          _git_error "Rebase modes cannot be combined."
          return 2
        }
        mode="${1#--}"
        ;;
      --interactive)
        [[ "$mode" == "onto" && -z "$target" ]] || {
          _git_error "Rebase modes cannot be combined."
          return 2
        }
        (( $# >= 2 )) || {
          _git_error \
            "--interactive requires a commit count between 1 and 10000."
          return 2
        }
        mode="interactive"
        shift
        count="$1"
        ;;
      --yes)
        assume_yes=1
        ;;
      -*)
        _git_error "Unknown git-rebase option: $1"
        return 2
        ;;
      *)
        [[ "$mode" == "onto" && -z "$target" ]] || {
          _git_error "git-rebase accepts one target branch."
          return 2
        }
        target="$1"
        ;;
    esac
    shift
  done
  if [[ "$mode" == "interactive" ]]; then
    [[ "$count" == <-> ]] || {
      _git_error "Interactive commit count must be between 1 and 10000."
      return 2
    }
    (( 10#$count >= 1 && 10#$count <= 10000 )) || {
      _git_error "Interactive commit count must be between 1 and 10000."
      return 2
    }
  fi
  [[ "$target" != *$'\n'* && "$target" != *$'\r'* ]] || {
    _git_error "Invalid rebase target."
    return 2
  }
  _git_require_repo || return 1

  case "$mode" in
    continue|abort|skip)
      _git_context_refresh || return 1
      local expected_root="${_GIT_CONTEXT[root]}"
      local expected_head="${_GIT_CONTEXT[head]}"
      local expected_fingerprint="${_GIT_CONTEXT[fingerprint]}"
      local git_dir="${_GIT_CONTEXT[git_dir]}"
      [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]] || {
        _git_error "No rebase is in progress."
        return 1
      }
      _git_header "Rebase Action Plan"
      _git_label "Repository:" "${expected_root:t}"
      _git_label "Current HEAD:" "${expected_head[1,12]}"
      _git_label "Action:" "$mode"
      if [[ "$mode" == "abort" ]]; then
        _git_warn "Abort restores the pre-rebase state."
      elif [[ "$mode" == "skip" ]]; then
        _git_warn "Skip omits the current commit from this rebase."
      fi
      local -i authorize_rc=0
      _git_authorize "$assume_yes" "Execute rebase $mode?" \
        || authorize_rc=$?
      (( authorize_rc == 3 )) && return 0
      (( authorize_rc != 0 )) && return $authorize_rc
      _git_require_same_context \
        "$expected_root" "$expected_head" "$expected_fingerprint" || return 1
      [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]] || {
        _git_error "The rebase completed or changed after authorization."
        return 1
      }
      command git rebase "--$mode" >&2
      local -i action_rc=$?
      (( action_rc == 0 )) \
        && _git_success "Rebase $mode completed." \
        || _git_error "Unable to $mode rebase (exit $action_rc)."
      return $action_rc
      ;;
    interactive)
      target="HEAD~${count}"
      ;;
  esac

  if [[ -z "$target" ]]; then
    _git_require_interactive || return 1
    local current_full_ref
    current_full_ref=$(command git symbolic-ref --quiet HEAD 2>/dev/null) \
      || {
        _git_error "Rebase requires an attached current branch."
        return 1
      }
    local -a reply=()
    local -i picker_rc=0
    _git_branch_pick_ref "Rebase onto" 1 "$current_full_ref" \
      || picker_rc=$?
    if (( picker_rc != 0 )); then
      (( picker_rc == 3 )) && return 0
      return $picker_rc
    fi
    target="${reply[1]}"
  fi
  [[ "$target" != -* && "$target" != *$'\n'* ]] || {
    _git_error "Invalid rebase target."
    return 2
  }

  local target_oid
  target_oid=$(command git rev-parse --verify "${target}^{commit}" 2>/dev/null) \
    || {
      _git_error "Rebase target '$target' does not resolve to a commit."
      return 1
    }
  _git_context_refresh || return 1
  local expected_root="${_GIT_CONTEXT[root]}"
  local expected_head="${_GIT_CONTEXT[head]}"
  local expected_fingerprint="${_GIT_CONTEXT[fingerprint]}"

  _git_header "Rebase Plan"
  _git_label "Branch:" "${_GIT_CONTEXT[branch]}"
  _git_label "Current HEAD:" "${expected_head[1,12]}"
  _git_label "Target:" "$target @ ${target_oid[1,12]}"
  _git_label "Mode:" "$mode"
  local -i authorize_rc=0
  _git_authorize "$assume_yes" "Rewrite commits using this rebase plan?" \
    || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc
  _git_require_same_context \
    "$expected_root" "$expected_head" "$expected_fingerprint" || return 1
  local current_target_oid
  current_target_oid=$(command git rev-parse --verify "${target}^{commit}" \
    2>/dev/null) || return 1
  [[ "$current_target_oid" == "$target_oid" ]] || {
    _git_error "The rebase target changed after authorization."
    return 1
  }

  if [[ "$mode" == "interactive" ]]; then
    command git rebase -i "$target_oid" >&2
  else
    command git rebase "$target_oid" >&2
  fi
  local -i rebase_rc=$?
  if (( rebase_rc == 0 )); then
    _git_success "Rebase completed."
  else
    _git_error "Rebase stopped or failed (exit $rebase_rc)."
    _git_info "Resolve conflicts and continue, or run 'git rebase --abort'."
  fi
  return $rebase_rc
}

typeset -g _GIT_BRANCH_SOURCED=1
