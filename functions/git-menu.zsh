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
  git-branch.zsh \
  git-changes.zsh \
  git-history.zsh \
  git-stash.zsh \
  git-sync.zsh \
  git-tags.zsh \
  git-clean.zsh \
  git-issues.zsh \
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
  print -u2 -r -- \
    "  git-auth, git-status, git-identity-switcher, git-config-edit,"
  print -u2 -r -- \
    "  git-repo-create"
  print -u2 -r -- ""
  print -u2 -r -- "Branching and integration:"
  print -u2 -r -- \
    "  git-switch, git-branch-create, git-branch-rename, git-merge,"
  print -u2 -r -- \
    "  git-rebase, git-cherry-pick, git-pull, git-push"
  print -u2 -r -- ""
  print -u2 -r -- "Changes and commits:"
  print -u2 -r -- \
    "  git-stage, git-staged, git-unstage, git-commit,"
  print -u2 -r -- \
    "  git-commit-verify, git-amend, git-restore-from, git-stash"
  print -u2 -r -- ""
  print -u2 -r -- "History and review:"
  print -u2 -r -- \
    "  git-diff, git-blame, git-log-search, git-reflog,"
  print -u2 -r -- \
    "  git-file-history"
  print -u2 -r -- ""
  print -u2 -r -- "Tags and GitHub:"
  print -u2 -r -- \
    "  git-tag-create, git-tag-list, git-tag-verify, git-tag-push,"
  print -u2 -r -- \
    "  git-issues, git-prs, git-pr-create, git-pr-checkout"
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
    "Repository Context" "Identity, repository state, and configuration." \
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
    "History and Review" "Read-only changes, commits, and authorship." || return $?
  _git_menu_entry \
    "Browse Diffs" "git-diff" \
    "Inspect working tree, staged, branch, or commit differences." || return $?
  _git_menu_entry \
    "Inspect Line Authorship" "git-blame" \
    "Show which commit and author last changed each line of a tracked file." || return $?
  _git_menu_entry \
    "Search Commit Log" "git-log-search" \
    "Find commits by message or ID and inspect their changes." || return $?
  _git_menu_entry \
    "Browse Reflog" "git-reflog" \
    "Browse recent branch and HEAD movements to locate recovery points." || return $?
  _git_menu_entry \
    "Browse File History" "git-file-history" \
    "Browse the commits that changed a selected tracked file." || return $?

  _git_menu_section \
    "Changes and Commits" "Prepare changes, create commits, and save unfinished work." \
    || return $?
  _git_menu_entry \
    "Stage Files" "git-stage" \
    "Choose working-tree files to include in the next commit." || return $?
  _git_menu_entry \
    "Browse Staged Files" "git-staged" \
    "Inspect changes already selected for the next commit." || return $?
  _git_menu_entry \
    "Unstage Files" "git-unstage" \
    "Remove files from the next commit while keeping their local changes." \
    || return $?
  _git_menu_entry \
    "Create Commit" "git-commit" \
    "Commit staged changes with optional DCO sign-off." || return $?
  _git_menu_entry \
    "Verify Commit Signature" "git-commit-verify" \
    "Check the signature of a selected commit." || return $?
  _git_menu_entry \
    "Amend Last Commit" "git-amend" \
    "Rewrite the last commit message, staged content, or author." || return $?
  _git_menu_entry \
    "Restore From Commit" "git-restore-from" \
    "Review and replace selected files with their contents from a chosen commit." || return $?
  _git_menu_entry \
    "Manage Stashes" "git-stash" \
    "Save unfinished work, restore a stash, or review it before deletion." || return $?

  _git_menu_section \
    "Branching and Integration" "Branches, synchronization, and history integration." \
    || return $?
  _git_menu_entry \
    "Switch Branch" "git-switch" \
    "Switch to a local branch or create an explicit remote-tracking branch." \
    || return $?
  _git_menu_entry \
    "Create Branch" "git-branch-create" \
    "Create a branch from a selected starting point." || return $?
  _git_menu_entry \
    "Rename Branch" "git-branch-rename" \
    "Choose a local branch and give it a new name." || return $?
  _git_menu_entry \
    "Merge Branch" "git-merge" \
    "Merge a selected branch with an explicit strategy." || return $?
  _git_menu_entry \
    "Rebase Branch" "git-rebase" \
    "Move branch commits to a new base, or continue, abort, or skip a rebase." || return $?
  _git_menu_entry \
    "Cherry-Pick Commits" "git-cherry-pick" \
    "Apply selected commits in their original chronological order." || return $?
  _git_menu_entry \
    "Pull or Fetch" "git-pull" \
    "Fetch remote changes or integrate them with a selected pull strategy." \
    || return $?
  _git_menu_entry \
    "Push Refs" "git-push" \
    "Review the destination and push refs; force pushes refuse intervening remote changes." \
    || return $?

  _git_menu_section \
    "Tags and GitHub" "Tag publication and GitHub collaboration." || return $?
  _git_menu_entry \
    "Create Tag" "git-tag-create" \
    "Create a signed, annotated, or lightweight tag." || return $?
  _git_menu_entry \
    "Browse Tags" "git-tag-list" \
    "Browse tags and inspect their targets and signatures." || return $?
  _git_menu_entry \
    "Verify Tag Signature" "git-tag-verify" \
    "Check the signature of a selected tag." || return $?
  _git_menu_entry \
    "Push Tag" "git-tag-push" \
    "Review and publish a selected tag to its remote." || return $?
  _git_menu_entry \
    "Browse GitHub Issues" "git-issues" \
    "Browse issues, open them in a browser, or review a state change or deletion." || return $?
  _git_menu_entry \
    "Browse Pull Requests" "git-prs" \
    "Browse pull requests, view diffs, or review a merge or state change." \
    || return $?
  _git_menu_entry \
    "Create Pull Request" "git-pr-create" \
    "Create a PR for the current pushed branch." || return $?
  _git_menu_entry \
    "Check Out Pull Request" "git-pr-checkout" \
    "Switch to a selected or numbered pull request." || return $?

  _git_menu_section \
    "Configuration" "Set Git identity or create a GitHub repository." || return $?
  _git_menu_entry \
    "Switch Git Identity" "git-identity-switcher" \
    "Apply a configured identity locally or globally." || return $?
  _git_menu_entry \
    "Edit Local Identity" "git-config-edit" \
    "Set repository-local user.name or user.email." || return $?
  _git_menu_entry \
    "Create GitHub Repository" "git-repo-create" \
    "Review and create a GitHub repository from the current directory." \
    || return $?

  _git_menu_section \
    "Destructive Maintenance" "Review before discarding changes or deleting repository data." \
    || return $?
  _git_menu_entry \
    "Discard Working-Tree Changes" "git-discard" \
    "Discard uncommitted changes in selected tracked files after review." || return $?
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
  if _git_check_cmd gh; then
    context+=" | GitHub CLI: installed"
  else
    context+=" | GitHub CLI: missing"
  fi
  print -r -- "$context"
}

_git_interactive() {
  _git_check_cmd fzf || {
    _git_error "fzf is required for the interactive Git menu."
    _git_info "Install fzf or run a direct subcommand."
    return 1
  }

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
