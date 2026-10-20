#!/usr/bin/env zsh
# =============================================================================
# Git Suite: public loader and command router
# =============================================================================
#
# Public loader and command router for Git repository and GitHub workflows.
# Usage: git-menu [subcommand] [arguments...]
#

if [[ -n "${_GIT_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _git_menu_loader_dir="${${(%):-%x}:A:h}"

_git_menu_source_module() {
  local module_name="$1"
  local module_path="${_git_menu_loader_dir}/git/${module_name}"
  [[ "$module_name" == "git-common.zsh" ]] \
    && module_path="${_git_menu_loader_dir}/git-common.zsh"
  local resolved_path="${module_path:A}"
  [[ ! -L "$module_path" \
    && -f "$module_path" \
    && -r "$module_path" \
    && "$resolved_path" == "$module_path" ]] || return 1
  builtin source "$module_path"
}

typeset -i _git_menu_load_rc=0
_git_menu_source_module "git-common.zsh" || _git_menu_load_rc=$?
if (( _git_menu_load_rc != 0 )); then
  print -u2 -r -- "git-menu.zsh: failed to load git-common.zsh"
  {
    return $_git_menu_load_rc 2>/dev/null || exit $_git_menu_load_rc
  } always {
    unset -f _git_menu_source_module
    unset _git_menu_load_rc _git_menu_loader_dir
  }
fi

typeset _git_menu_module
for _git_menu_module in \
  git-changes.zsh \
  git-stash.zsh \
  git-branch.zsh \
  git-sync.zsh \
  git-tags.zsh \
  git-clean.zsh \
  git-pr.zsh \
  git-identity.zsh \
  git-repo.zsh; do
  _git_menu_load_rc=0
  _git_menu_source_module "$_git_menu_module" || _git_menu_load_rc=$?
  if (( _git_menu_load_rc != 0 )); then
    print -u2 -r -- \
      "git-menu.zsh: failed to load ${_git_menu_module}"
    {
      return $_git_menu_load_rc 2>/dev/null || exit $_git_menu_load_rc
    } always {
      unset -f _git_menu_source_module
      unset _git_menu_load_rc _git_menu_loader_dir _git_menu_module
    }
  fi
done

unset -f _git_menu_source_module
unset _git_menu_load_rc _git_menu_module _git_menu_loader_dir

# --- Public usage ------------------------------------------------------------

_git_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  git-menu"
  print -u2 -r -- "  git-menu <subcommand> [arguments...]"
  print -u2 -r -- "  git-menu -h|--help"
  print -u2 -r -- ""
  print -u2 -r -- "Repository context:"
  print -u2 -r -- "  git-auth, git-status"
  print -u2 -r -- ""
  print -u2 -r -- "Local changes:"
  print -u2 -r -- "  git-unstage, git-stash, git-amend"
  print -u2 -r -- ""
  print -u2 -r -- "Branches:"
  print -u2 -r -- "  git-switch, git-recover"
  print -u2 -r -- ""
  print -u2 -r -- "Synchronization:"
  print -u2 -r -- "  git-pull, git-push"
  print -u2 -r -- ""
  print -u2 -r -- "Tags and pull requests:"
  print -u2 -r -- \
    "  git-tag-create, git-tag-verify, git-tag-push, git-pr-create,"
  print -u2 -r -- \
    "  git-pr-checkout"
  print -u2 -r -- ""
  print -u2 -r -- "Configuration:"
  print -u2 -r -- "  git-identity-check, git-identity-switcher"
  print -u2 -r -- ""
  print -u2 -r -- "Destructive maintenance:"
  print -u2 -r -- \
    "  git-discard, git-undo-commit, git-tag-delete, clean-branches,"
  print -u2 -r -- \
    "  clean-remote-merged"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Arguments after a subcommand are forwarded unchanged."
  print -u2 -r -- \
    "Use '<subcommand> --help' for direct modes and safety flags."
  print -u2 -r -- \
    "Broad or destructive workflows support an exact plan and explicit authorization."
}

# --- Interactive menu --------------------------------------------------------

# stdout records: label|command|description
_git_menu_rows_build() {
  local -i _GIT_MENU_CONTEXTUAL_ROWS=1
  local -i _GIT_MENU_HAS_REPO=0
  local inside_worktree=""
  inside_worktree=$(command git rev-parse \
    --is-inside-work-tree 2>/dev/null) || inside_worktree=""
  [[ "$inside_worktree" == "true" ]] && _GIT_MENU_HAS_REPO=1

  _git_menu_section \
    "Repository Context" "Read-only identity, remote, and working-tree state." \
    || return $?
  _git_menu_entry \
    "Show Authentication Context" "git-auth" \
    "Show Git identity, remote destination, SSH routing, and GitHub CLI availability." \
    || return $?
  _git_menu_entry \
    "Show Repository Status" "git-status" \
    "Inspect branch, upstream, changes, stashes, and operations in progress." \
    || return $?

  _git_menu_section \
    "Local Changes" "Unstage files, stash work in progress, and amend the last commit." \
    || return $?
  _git_menu_entry \
    "Unstage Files" "git-unstage" \
    "Remove selected or all files from the next commit; their changes stay." \
    || return $?
  _git_menu_entry \
    "Manage Stashes" "git-stash" \
    "Save current changes, or apply, pop, inspect, branch from, or drop a stash." \
    || return $?
  _git_menu_entry \
    "Amend Last Commit" "git-amend" \
    "Change the last commit message, add staged changes to it, or reset its author." \
    || return $?

  _git_menu_section \
    "Branches" "Switch branches and restore lost commits as new branches." \
    || return $?
  _git_menu_entry \
    "Switch Branch" "git-switch" \
    "Switch to a local or remote branch; changes are carried or stashed after review." \
    || return $?
  _git_menu_entry \
    "Recover Lost Commit" "git-recover" \
    "Restore a commit no branch or tag reaches, from the reflog, as a new branch." \
    || return $?

  _git_menu_section \
    "Synchronization" "Fetch, integrate, and publish branch changes." \
    || return $?
  _git_menu_entry \
    "Pull or Fetch" "git-pull" \
    "Pull with merge, rebase, or fast-forward, or only fetch, after reviewing the plan." \
    || return $?
  _git_menu_entry \
    "Push Branches" "git-push" \
    "Review the destination and push branches; force pushes refuse intervening remote changes." \
    || return $?

  _git_menu_section \
    "Tags and Pull Requests" "Tag publication and GitHub pull requests." \
    || return $?
  _git_menu_entry \
    "Create Tag" "git-tag-create" \
    "Create a signed, annotated, or lightweight tag." || return $?
  _git_menu_entry \
    "Verify Tag Signature" "git-tag-verify" \
    "Check the signature of a selected tag." || return $?
  _git_menu_entry \
    "Push Tags" "git-tag-push" \
    "Review and publish selected tags without overwriting remote tags." || return $?
  _git_menu_entry \
    "Create Pull Request" "git-pr-create" \
    "Create a PR for the current pushed branch." || return $?
  _git_menu_entry \
    "Check Out Pull Request" "git-pr-checkout" \
    "Switch to a selected or numbered pull request." || return $?

  _git_menu_section \
    "Configuration" "Check or apply a configured Git identity." || return $?
  _git_menu_entry \
    "Check Workspace Identity" "git-identity-check" \
    "Compare the repository identity with the profile of its workspace directory." \
    || return $?
  _git_menu_entry \
    "Switch Git Identity" "git-identity-switcher" \
    "Apply a configured identity locally or globally." || return $?

  _git_menu_section \
    "Destructive Maintenance" "Review before discarding changes or deleting repository data." \
    || return $?
  _git_menu_entry \
    "Discard Changes" "git-discard" \
    "Discard changes in chosen files, or every uncommitted change, after review." \
    || return $?
  _git_menu_entry \
    "Undo Last Commit" "git-undo-commit" \
    "Undo the last commit, choosing whether to keep or discard its changes." \
    || return $?
  _git_menu_entry \
    "Delete Tag" "git-tag-delete" \
    "Delete a local tag and optionally its matching remote tag after review." \
    || return $?
  _git_menu_entry \
    "Clean Local Branches" "clean-branches" \
    "Review and delete selected merged local branches." \
    || return $?
  _git_menu_entry \
    "Clean Remote Merged Branches" "clean-remote-merged" \
    "Review and delete merged remote branches; refuse changes made since review." || return $?
}

_git_menu_rows() {
  local rows_output
  rows_output=$(_git_menu_rows_build) || return $?
  local -a rows=()
  [[ -n "$rows_output" ]] && rows=("${(@f)rows_output}")
  (( ${#rows[@]} > 0 )) || {
    _git_error "The Git menu did not produce any valid rows."
    return 1
  }
  print -r -- "${(F)rows}"
}

_git_menu_context() {
  local context
  context=$(_git_auth_badge) || return 1
  if _git_menu_has_cmd gh; then
    context+=" | GitHub CLI: installed"
  else
    context+=" | GitHub CLI: missing"
  fi
  print -r -- "$context"
}

_git_interactive() {
  # Each dependency's PATH scan runs once for the whole menu: the row and
  # context builders run in subshells that inherit this filled cache.
  local -A _git_menu_dependency_cache=()
  local menu_dependency=""
  for menu_dependency in fzf git gh; do
    _git_menu_has_cmd "$menu_dependency"
  done

  _git_menu_has_cmd fzf || {
    _git_error "fzf is required for the interactive Git menu."
    _git_info "Install fzf or run a direct subcommand."
    return 1
  }
  # An installed Git must be usable before the menu runs it for its context;
  # the macOS placeholder would open an installation dialog instead.
  if _git_menu_has_cmd git; then
    _git_require_git || return 1
  fi
  _git_wsl_drive_notice

  local rows_output
  rows_output=$(_git_menu_rows) || return $?
  local -a options=("${(@f)rows_output}")

  local context
  context=$(_git_menu_context) || {
    _git_error "Unable to render Git repository context."
    return 1
  }
  local header="${context}"$'\n''Type to filter | Enter run | Esc cancel | Ctrl-/ details'

  local selected=""
  local -i fzf_rc=0
  _git_fzf_capture \
    --height=80% \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='git > ' \
    --header="$header" \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    --bind='ctrl-/:toggle-preview' \
    < <(printf '%s\n' "${options[@]}") || fzf_rc=$?
  selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _git_fzf_rc_is_cancel "$fzf_rc" && return 0
    _git_error "Unable to open the interactive Git menu."
    return 1
  fi
  [[ -z "$selected" ]] && return 0

  local snapshot_row=""
  local -i snapshot_match=0
  for snapshot_row in "${options[@]}"; do
    if [[ "$snapshot_row" == "$selected" ]]; then
      snapshot_match=1
      break
    fi
  done
  (( snapshot_match )) || {
    _git_error "The selected Git action was not in the menu snapshot."
    return 1
  }

  local remainder="${selected#*|}"
  local command_name="${remainder%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  [[ "$command_name" =~ '^[a-z][a-z0-9-]*$' ]] || {
    _git_error "The selected Git menu record is invalid."
    return 1
  }

  _git_info "Executing: $command_name"
  _git_timed "git:$command_name" _git_dispatch "$command_name"
}

git-menu() {
  emulate -L zsh

  case "${1:-}" in
    "")
      (( $# == 0 )) || {
        _git_error "Invalid empty Git command."
        return 2
      }
      _git_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _git_error "--help accepts no additional arguments."
        return 2
      }
      _git_usage
      ;;
    -*)
      _git_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _git_timed "git:$command_name" \
        _git_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _GIT_MENU_SOURCED=1
