#!/usr/bin/env zsh
# =============================================================================
# Git Repository: status, local identity editing, and GitHub repository creation
# =============================================================================
#
# Loaded by git-menu.zsh after git-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_GIT_REPO_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_git_repo_usage() {
  local command_name="${1:-git-status}"
  case "$command_name" in
    git-status)
      print -u2 -r -- "Usage: git-status"
      print -u2 -r -- \
        "Show branch, upstream, working-tree, stash, and operation state."
      ;;
    git-config-edit)
      print -u2 -r -- \
        "Usage: git-config-edit [--name <value>] [--email <value>]"
      print -u2 -r -- \
        "                       [--dry-run] [--yes]"
      print -u2 -r -- \
        "Edit repository-local user.name and user.email transactionally."
      ;;
    git-repo-create)
      print -u2 -r -- \
        "Usage: git-repo-create [--name <name>]"
      print -u2 -r -- \
        "                       [--private|--public|--internal]"
      print -u2 -r -- \
        "                       [--description <text>]"
      print -u2 -r -- \
        "                       [--remote <name>] [--push|--no-push]"
      print -u2 -r -- \
        "                       [--dry-run] [--yes]"
      print -u2 -r -- \
        "Create an exact GitHub repository from the current directory."
      ;;
  esac
  print -u2 -r -- "       ${command_name} --help"
}

_git_repo_help_requested() {
  local command_name="$1"
  shift
  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _git_repo_usage "$command_name"
    return 0
  fi
  return 1
}

git-status() {
  emulate -L zsh

  _git_repo_help_requested git-status "$@" && return 0
  (( $# == 0 )) || {
    _git_error "git-status accepts no arguments."
    return 2
  }
  _git_context_refresh || return 1

  local root="${_GIT_CONTEXT[root]}"
  local branch="${_GIT_CONTEXT[branch]}"
  local head="${_GIT_CONTEXT[head]}"
  local upstream="${_GIT_CONTEXT[upstream]}"
  local remote="${_GIT_CONTEXT[remote]}"
  local remote_url="${_GIT_CONTEXT[remote_url]}"
  local git_dir="${_GIT_CONTEXT[git_dir]}"

  local status_output
  status_output=$(command git status \
    --porcelain=v2 --untracked-files=all 2>/dev/null) || {
    _git_error "Unable to inspect the working tree."
    return 1
  }
  local -i staged=0 modified=0 untracked=0 conflicts=0
  local record xy
  for record in "${(@f)status_output}"; do
    case "${record[1]:-}" in
      1)
        xy="${record[3,4]}"
        [[ "${xy[1]}" != "." ]] && (( staged++ ))
        [[ "${xy[2]}" != "." ]] && (( modified++ ))
        ;;
      2)
        xy="${record[3,4]}"
        [[ "${xy[1]}" != "." ]] && (( staged++ ))
        [[ "${xy[2]}" != "." ]] && (( modified++ ))
        ;;
      u)
        (( staged++, modified++, conflicts++ ))
        ;;
      \?)
        (( untracked++ ))
        ;;
    esac
  done

  local ahead="" behind=""
  if [[ -n "$upstream" ]]; then
    local counts
    counts=$(command git rev-list --left-right --count \
      "HEAD...$upstream" 2>/dev/null) || {
      _git_error "Unable to compare HEAD with its upstream."
      return 1
    }
    [[ "$counts" == *$'\t'* ]] || {
      _git_error "Git returned invalid upstream comparison data."
      return 1
    }
    ahead="${counts%%$'\t'*}"
    behind="${counts#*$'\t'}"
  fi

  local stash_output
  stash_output=$(command git stash list --format='%gd' 2>/dev/null) || {
    _git_error "Unable to inspect the stash list."
    return 1
  }
  local -i stash_count=0
  if [[ -n "$stash_output" ]]; then
    local -a stash_records=("${(@f)stash_output}")
    stash_count=${#stash_records[@]}
  fi

  _git_header "Repository Status"
  _git_label "Repository:" "${root:t}"
  _git_label "Path:" "$root"
  _git_label "Branch:" "$branch"
  _git_label "HEAD:" \
    "$([[ "$head" == "unborn" ]] && print -r -- unborn \
      || print -r -- "${head[1,12]}")"
  _git_label "Upstream:" "${upstream:-(none)}"
  if [[ -n "$ahead" && -n "$behind" ]]; then
    _git_label "Synchronization:" "$ahead ahead, $behind behind"
  fi
  _git_label "Remote:" "${remote:-(none)}"
  [[ -n "$remote_url" ]] \
    && _git_label "Push URL:" "$(_git_redact_remote_url "$remote_url")"
  _git_blank
  _git_label "Staged:" "$staged file(s)"
  _git_label "Modified:" "$modified file(s)"
  _git_label "Untracked:" "$untracked file(s)"
  _git_label "Conflicts:" "$conflicts file(s)"
  _git_label "Stashes:" "$stash_count"

  local -a operations=()
  [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]] \
    && operations+=(rebase)
  [[ -f "$git_dir/MERGE_HEAD" ]] && operations+=(merge)
  [[ -f "$git_dir/CHERRY_PICK_HEAD" ]] && operations+=(cherry-pick)
  [[ -f "$git_dir/REVERT_HEAD" ]] && operations+=(revert)
  [[ -f "$git_dir/BISECT_LOG" ]] && operations+=(bisect)
  if (( ${#operations[@]} > 0 )); then
    _git_blank
    _git_warn "Operation in progress: ${(j:, :)operations}"
  fi
}

_git_config_edit_restore() {
  local key="$1"
  local was_present="$2"
  local old_value="$3"
  if (( was_present )); then
    command git config --local --replace-all "$key" "$old_value" &>/dev/null
    return $?
  fi
  command git config --local --unset-all "$key" &>/dev/null
  local -i unset_rc=$?
  (( unset_rc == 0 || unset_rc == 5 ))
}

_git_config_edit_capture() {
  local key="$1"
  local value=""
  local -a values=()
  while IFS= read -r -d $'\0' value; do
    values+=("$value")
  done < <(
    command git config --local --null --get-all "$key" 2>/dev/null
  )
  if (( ${#values[@]} > 1 )); then
    _git_error \
      "Refusing to replace multi-valued '$key'; normalize it first."
    return 1
  fi
  reply_present=${#values[@]}
  REPLY="${values[1]:-}"
}

git-config-edit() {
  emulate -L zsh

  _git_repo_help_requested git-config-edit "$@" && return 0

  local new_name="" new_email=""
  local -i set_name=0 set_email=0 dry_run=0 assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --name)
        (( $# >= 2 )) || {
          _git_error "--name requires a value."
          return 2
        }
        new_name="$2"
        set_name=1
        shift
        ;;
      --email)
        (( $# >= 2 )) || {
          _git_error "--email requires a value."
          return 2
        }
        new_email="$2"
        set_email=1
        shift
        ;;
      --dry-run)
        dry_run=1
        ;;
      -y|--yes)
        assume_yes=1
        ;;
      -*)
        _git_error "Unknown git-config-edit option: $1"
        return 2
        ;;
      *)
        _git_error "Unexpected git-config-edit argument: $1"
        return 2
        ;;
    esac
    shift
  done
  (( dry_run && assume_yes )) && {
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  }
  [[ "$new_name" != *$'\n'* && "$new_name" != *$'\r'* \
    && "$new_email" != *$'\n'* && "$new_email" != *$'\r'* ]] || {
    _git_error "Identity values cannot contain control characters."
    return 2
  }
  (( ! set_name || ${#new_name} > 0 )) || {
    _git_error "--name cannot be empty."
    return 2
  }
  (( ! set_email || ${#new_email} > 0 )) || {
    _git_error "--email cannot be empty."
    return 2
  }

  _git_context_refresh || return 1
  if (( ! set_name && ! set_email )); then
    _git_require_interactive || return 1
    local selection
    local -i fzf_rc=0
    selection=$(printf 'name|user.name\nemail|user.email\n' | _git_fzf \
      --delimiter='[|]' \
      --with-nth=2 \
      --height=20% \
      --prompt='Local identity field > ' \
      --header='Up/Down navigate | Enter select | Esc cancel' \
      --preview='' \
      --preview-window=hidden) || fzf_rc=$?
    if (( fzf_rc != 0 )); then
      _git_fzf_rc_is_cancel "$fzf_rc" && return 0
      return 1
    fi
    printf 'New %s: ' "${selection#*|}" >&2
    local entered_value=""
    IFS= read -r entered_value
    [[ -n "$entered_value" \
      && "$entered_value" != *$'\n'* \
      && "$entered_value" != *$'\r'* ]] || {
      _git_info "Cancelled; no value was provided."
      return 0
    }
    if [[ "${selection%%|*}" == "name" ]]; then
      new_name="$entered_value"
      set_name=1
    elif [[ "${selection%%|*}" == "email" ]]; then
      new_email="$entered_value"
      set_email=1
    else
      _git_error "Invalid identity field selection."
      return 1
    fi
  fi

  local expected_root="${_GIT_CONTEXT[root]}"
  local expected_head="${_GIT_CONTEXT[head]}"
  local expected_fingerprint="${_GIT_CONTEXT[fingerprint]}"
  local old_name="" old_email=""
  local -i had_name=0 had_email=0
  local -i reply_present=0
  local REPLY=""
  _git_config_edit_capture user.name || return 1
  old_name="$REPLY"
  had_name=$reply_present
  _git_config_edit_capture user.email || return 1
  old_email="$REPLY"
  had_email=$reply_present

  _git_header "Local Git Configuration Plan"
  _git_label "Repository:" "$expected_root"
  (( set_name )) && {
    _git_label "user.name:" "${old_name:-(not set)}"
    _git_label "New name:" "$new_name"
  }
  (( set_email )) && {
    _git_label "user.email:" "${old_email:-(not set)}"
    _git_label "New email:" "$new_email"
  }
  (( dry_run )) && {
    _git_info "Dry run complete; no configuration was changed."
    return 0
  }
  local -i authorize_rc=0
  _git_authorize "$assume_yes" "Apply this local identity plan?" \
    || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc
  _git_require_same_context \
    "$expected_root" "$expected_head" "$expected_fingerprint" || return 1

  local current_name="" current_email=""
  local -i current_had_name=0 current_had_email=0
  REPLY=""
  reply_present=0
  _git_config_edit_capture user.name || return 1
  current_name="$REPLY"
  current_had_name=$reply_present
  _git_config_edit_capture user.email || return 1
  current_email="$REPLY"
  current_had_email=$reply_present
  [[ "$current_had_name" == "$had_name" \
    && "$current_name" == "$old_name" \
    && "$current_had_email" == "$had_email" \
    && "$current_email" == "$old_email" ]] || {
    _git_error \
      "Repository identity changed after planning; review and retry."
    return 1
  }

  if (( set_name )); then
    command git config --local --replace-all user.name "$new_name" || {
      _git_error "Unable to update local user.name."
      return 1
    }
  fi
  if (( set_email )); then
    command git config --local --replace-all user.email "$new_email" || {
      if (( set_name )); then
        REPLY=""
        reply_present=0
        _git_config_edit_capture user.name || {
          _git_error \
            "Unable to update user.email; inspect user.name for a partial result."
          return 1
        }
        if (( reply_present == 1 )) && [[ "$REPLY" == "$new_name" ]]; then
          if _git_config_edit_restore user.name "$had_name" "$old_name"; then
            _git_error \
              "Unable to update user.email; the previous user.name was restored."
          else
            _git_error \
              "Unable to update user.email, and restoring user.name failed; inspect the partial result."
          fi
        else
          _git_error \
            "Unable to update user.email; user.name changed concurrently and was not overwritten."
        fi
      else
        _git_error "Unable to update local user.email."
      fi
      return 1
    }
  fi

  REPLY=""
  reply_present=0
  _git_config_edit_capture user.name || return 1
  current_name="$REPLY"
  current_had_name=$reply_present
  _git_config_edit_capture user.email || return 1
  current_email="$REPLY"
  current_had_email=$reply_present

  local expected_name="$old_name"
  local expected_email="$old_email"
  local -i expected_had_name=$had_name
  local -i expected_had_email=$had_email
  if (( set_name )); then
    expected_name="$new_name"
    expected_had_name=1
  fi
  if (( set_email )); then
    expected_email="$new_email"
    expected_had_email=1
  fi
  [[ "$current_had_name" == "$expected_had_name" \
    && "$current_name" == "$expected_name" \
    && "$current_had_email" == "$expected_had_email" \
    && "$current_email" == "$expected_email" ]] || {
    _git_error \
      "Repository identity changed during update; inspect the partial result."
    return 1
  }
  _git_success "Repository-local identity updated."
}

_git_repo_validate_name() {
  local name="${1:-}"
  [[ ${#name} -ge 1 && ${#name} -le 100 \
    && "$name" != "." \
    && "$name" != ".." \
    && "$name" =~ '^[A-Za-z0-9._-]+$' ]]
}

_git_repo_validate_remote() {
  local remote="${1:-}"
  [[ "$remote" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]]
}

_git_repo_remote_identity() {
  local remote_url="${1:-}"
  local remainder authority host path
  [[ -n "$remote_url" \
    && "$remote_url" != *$'\n'* \
    && "$remote_url" != *$'\r'* ]] || return 1
  if [[ "$remote_url" == *://* ]]; then
    remainder="${remote_url#*://}"
    authority="${remainder%%/*}"
    [[ "$remainder" != "$authority" ]] || return 1
    authority="${authority##*@}"
    host="${authority%%:*}"
    path="${remainder#*/}"
  elif [[ "$remote_url" == *@*:* ]]; then
    authority="${remote_url%%:*}"
    host="${authority#*@}"
    path="${remote_url#*:}"
  else
    return 1
  fi
  path="${path%%\?*}"
  path="${path%%\#*}"
  path="${path#/}"
  path="${path%/}"
  path="${path%.git}"
  [[ "$host" =~ '^[A-Za-z0-9.-]+$' \
    && "$path" =~ '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' ]] || return 1
  print -r -- "${host:l}/${path:l}"
}

git-repo-create() {
  emulate -L zsh

  _git_repo_help_requested git-repo-create "$@" && return 0

  local repo_name="" visibility="private" description=""
  local remote="origin"
  local -i visibility_set=0 push_mode=-1 dry_run=0 assume_yes=0
  while (( $# > 0 )); do
    case "$1" in
      --name)
        (( $# >= 2 )) || {
          _git_error "--name requires a value."
          return 2
        }
        repo_name="$2"
        shift
        ;;
      --private|--public|--internal)
        (( visibility_set == 0 )) || {
          _git_error "Choose exactly one repository visibility."
          return 2
        }
        visibility="${1#--}"
        visibility_set=1
        ;;
      --description)
        (( $# >= 2 )) || {
          _git_error "--description requires a value."
          return 2
        }
        description="$2"
        shift
        ;;
      --remote)
        (( $# >= 2 )) || {
          _git_error "--remote requires a value."
          return 2
        }
        remote="$2"
        shift
        ;;
      --push)
        (( push_mode == -1 )) || {
          _git_error "Choose only one push mode."
          return 2
        }
        push_mode=1
        ;;
      --no-push)
        (( push_mode == -1 )) || {
          _git_error "Choose only one push mode."
          return 2
        }
        push_mode=0
        ;;
      --dry-run)
        dry_run=1
        ;;
      -y|--yes)
        assume_yes=1
        ;;
      -*)
        _git_error "Unknown git-repo-create option: $1"
        return 2
        ;;
      *)
        _git_error "Unexpected git-repo-create argument: $1"
        return 2
        ;;
    esac
    shift
  done
  (( dry_run && assume_yes )) && {
    _git_error "--dry-run and --yes cannot be combined."
    return 2
  }
  [[ "$description" != *$'\n'* && "$description" != *$'\r'* ]] || {
    _git_error "Repository description cannot contain control characters."
    return 2
  }
  _git_repo_validate_remote "$remote" || {
    _git_error "Invalid remote name: $remote"
    return 2
  }
  if [[ -n "$repo_name" ]]; then
    _git_repo_validate_name "$repo_name" || {
      _git_error \
        "Repository name must use 1-100 ASCII letters, digits, '.', '_', or '-'."
      return 2
    }
  fi

  _git_require_git || return 1
  _git_check_gh || return 1
  local source_root="${PWD:A}"
  local -i needs_init=0
  local inside_worktree=""
  inside_worktree=$(command git rev-parse \
    --is-inside-work-tree 2>/dev/null) || inside_worktree=""
  if [[ "$inside_worktree" == "true" ]]; then
    source_root=$(command git rev-parse --show-toplevel 2>/dev/null) \
      || return 1
  elif command git rev-parse --git-dir &>/dev/null; then
    _git_error "Repository creation requires a Git worktree, not a bare repository."
    return 1
  else
    needs_init=1
  fi

  local default_name="${source_root:t}"
  if [[ -z "$repo_name" ]]; then
    _git_require_interactive || return 1
    printf 'Repository name [%s]: ' "$default_name" >&2
    IFS= read -r repo_name
    repo_name="${repo_name:-$default_name}"
    local selected_visibility
    local -i fzf_rc=0
    selected_visibility=$(printf 'private\npublic\ninternal\n' | _git_fzf \
      --height=20% \
      --prompt='GitHub visibility > ' \
      --header='Up/Down navigate | Enter select | Esc cancel' \
      --preview='' \
      --preview-window=hidden) || fzf_rc=$?
    if (( fzf_rc != 0 )); then
      _git_fzf_rc_is_cancel "$fzf_rc" && return 0
      return 1
    fi
    visibility="$selected_visibility"
  fi
  _git_repo_validate_name "$repo_name" || {
    _git_error \
      "Repository name must use 1-100 ASCII letters, digits, '.', '_', or '-'."
    return 2
  }
  [[ "$visibility" == (private|public|internal) ]] || {
    _git_error "Invalid repository visibility."
    return 2
  }

  local owner
  owner=$(command gh api user --jq .login 2>/dev/null) || {
    _git_error "Unable to resolve the authenticated GitHub account."
    return 1
  }
  [[ "$owner" =~ '^[A-Za-z0-9-]+$' ]] || {
    _git_error "GitHub returned an invalid account name."
    return 1
  }
  local target="$owner/$repo_name"

  local head="unborn" branch="" expected_fingerprint=""
  local -i has_commit=0
  if (( ! needs_init )); then
    command git remote get-url "$remote" &>/dev/null && {
      _git_error "Remote '$remote' already exists; choose another name."
      return 1
    }
    head=$(command git rev-parse --verify HEAD 2>/dev/null) && has_commit=1
    branch=$(command git symbolic-ref --quiet --short HEAD 2>/dev/null) \
      || branch="detached"
    expected_fingerprint=$(_git_repo_fingerprint) || return 1
  fi
  (( push_mode == -1 )) && push_mode=$has_commit
  (( push_mode && ! has_commit )) && {
    _git_error "Cannot push a repository without an initial commit."
    return 1
  }
  (( push_mode )) && [[ "$branch" == "detached" ]] && {
    _git_error "Attach HEAD to a local branch before using --push."
    return 1
  }

  local default_branch
  default_branch=$(command git config --global --get init.defaultBranch \
    2>/dev/null)
  [[ -n "$default_branch" ]] || default_branch="main"
  _git_validate_branch_name "$default_branch" || default_branch="main"

  _git_header "GitHub Repository Creation Plan"
  _git_label "Target:" "$target"
  _git_label "Visibility:" "$visibility"
  _git_label "Source:" "$source_root"
  _git_label "Initialize Git:" "$(( needs_init ? 1 : 0 ))"
  _git_label "Remote:" "$remote"
  _git_label "HEAD:" \
    "$([[ "$head" == "unborn" ]] && print -r -- unborn \
      || print -r -- "$branch @ ${head[1,12]}")"
  _git_label "Push current HEAD:" "$(( push_mode ? 1 : 0 ))"
  [[ -n "$description" ]] && _git_label "Description:" "$description"
  (( dry_run )) && {
    _git_info "Dry run complete; no local or GitHub state was changed."
    return 0
  }
  local -i authorize_rc=0
  _git_authorize "$assume_yes" "Create this GitHub repository?" \
    || authorize_rc=$?
  (( authorize_rc == 3 )) && return 0
  (( authorize_rc != 0 )) && return $authorize_rc

  local current_owner
  current_owner=$(command gh api user --jq .login 2>/dev/null) || {
    _git_error "Unable to revalidate the authenticated GitHub account."
    return 1
  }
  [[ "$current_owner" == "$owner" ]] || {
    _git_error "The authenticated GitHub account changed; retry."
    return 1
  }
  if (( needs_init )); then
    [[ "${PWD:A}" == "$source_root" ]] || {
      _git_error "The working directory changed; retry."
      return 1
    }
    command git rev-parse --git-dir &>/dev/null && {
      _git_error "A Git repository appeared after planning; retry."
      return 1
    }
    command git init --initial-branch="$default_branch" "$source_root" >&2 \
      || {
      _git_error "Unable to initialize the local repository."
      return 1
    }
  else
    _git_context_matches "$source_root" "$head" "$expected_fingerprint" || {
      _git_error \
        "Repository state changed after planning; review and retry."
      return 1
    }
    command git remote get-url "$remote" &>/dev/null && {
      _git_error "Remote '$remote' appeared after planning; retry."
      return 1
    }
  fi

  local -a create_args=(
    repo create
    "$target"
    "--$visibility"
    --source "$source_root"
    --remote "$remote"
  )
  [[ -n "$description" ]] && create_args+=(--description "$description")
  (( push_mode )) && create_args+=(--push)

  command gh "${create_args[@]}" >&2
  local -i create_rc=$?
  if (( create_rc != 0 )); then
    _git_error \
      "GitHub repository creation failed (exit $create_rc)."
    (( needs_init )) && _git_warn \
      "Partial result: local Git initialization remains at $source_root."
    return $create_rc
  fi

  local remote_urls_output
  remote_urls_output=$(command git -C "$source_root" remote \
    get-url --push --all "$remote" 2>/dev/null) || remote_urls_output=""
  local -a configured_urls=()
  [[ -n "$remote_urls_output" ]] \
    && configured_urls=("${(@f)remote_urls_output}")
  if (( ${#configured_urls[@]} != 1 )); then
    _git_error \
      "Repository '$target' exists, but remote '$remote' was not configured with one exact push URL."
    return 1
  fi
  local configured_url="${configured_urls[1]}"
  local repository_metadata
  repository_metadata=$(command gh repo view "$target" \
    --json nameWithOwner,url,sshUrl \
    --jq '[.nameWithOwner, .url, .sshUrl] | @tsv' 2>/dev/null) || {
    _git_error \
      "Repository '$target' exists, but its GitHub identity could not be verified."
    return 1
  }
  local metadata_name="${repository_metadata%%$'\t'*}"
  local metadata_urls="${repository_metadata#*$'\t'}"
  [[ "$metadata_urls" != "$repository_metadata" \
    && "$metadata_urls" == *$'\t'* \
    && "${metadata_name:l}" == "${target:l}" ]] || {
    _git_error \
      "Repository creation returned unexpected GitHub metadata; inspect the partial result."
    return 1
  }
  local web_url="${metadata_urls%%$'\t'*}"
  local ssh_url="${metadata_urls#*$'\t'}"
  local configured_identity web_identity ssh_identity
  configured_identity=$(_git_repo_remote_identity "$configured_url") \
    || configured_identity=""
  web_identity=$(_git_repo_remote_identity "$web_url") || web_identity=""
  ssh_identity=$(_git_repo_remote_identity "$ssh_url") || ssh_identity=""
  [[ -n "$configured_identity" \
    && ( "$configured_identity" == "$web_identity" \
      || "$configured_identity" == "$ssh_identity" ) ]] || {
    _git_error \
      "Repository '$target' exists, but remote '$remote' points elsewhere."
    _git_label "Remote URL:" "$(_git_redact_remote_url "$configured_url")"
    return 1
  }
  if (( push_mode )); then
    local pushed_record pushed_oid
    pushed_record=$(command git ls-remote --exit-code "$configured_url" \
      "refs/heads/$branch" 2>/dev/null) || {
      _git_error \
        "Repository '$target' exists, but the pushed branch could not be verified."
      return 1
    }
    pushed_oid="${pushed_record%%$'\t'*}"
    [[ "$pushed_oid" == "$head" ]] || {
      _git_error \
        "Repository '$target' exists, but the remote branch does not match planned HEAD."
      return 1
    }
  fi
  _git_success "Created GitHub repository '$target'."
  _git_label "Remote URL:" "$(_git_redact_remote_url "$configured_url")"
  return 0
}

typeset -g _GIT_REPO_SOURCED=1
