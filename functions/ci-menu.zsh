#!/usr/bin/env zsh
# =============================================================================
# CI Menu: public loader and command router for GitHub Actions workflows
# =============================================================================
#
# Public loader and command router for repository-bound CI workflows.
# Usage: ci-menu [subcommand]
#

if [[ -n "${_CI_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _ci_loader_dir="${${(%):-%x}:A:h}"

_ci_source_module() {
  local relative_name="$1"
  local module_path="${_ci_loader_dir}/${relative_name}"
  [[ -f "$module_path" && ! -L "$module_path" && -r "$module_path" ]] \
    || return 1
  [[ "${module_path:A}" == "$module_path" \
    && "${module_path:A:h}" == "${module_path:h}" ]] || return 1
  builtin source "$module_path"
}

typeset -i _ci_source_rc=0
typeset _ci_failed_module="ci-common.zsh"
_ci_source_module "$_ci_failed_module" || _ci_source_rc=$?
if (( _ci_source_rc == 0 )); then
  typeset _ci_module=""
  for _ci_module in \
    ci/ci-actions.zsh \
    ci/ci-clean.zsh; do
    _ci_failed_module="$_ci_module"
    _ci_source_module "$_ci_module" || {
      _ci_source_rc=$?
      break
    }
  done
fi
if (( _ci_source_rc != 0 )); then
  print -u2 -r -- \
    "ci-menu.zsh: failed to load $_ci_failed_module (status $_ci_source_rc)"
  unset -f _ci_source_module
  unset _ci_loader_dir _ci_module _ci_failed_module
  {
    return $_ci_source_rc 2>/dev/null || exit $_ci_source_rc
  } always {
    unset _ci_source_rc
  }
fi

unset -f _ci_source_module
unset _ci_loader_dir _ci_module _ci_failed_module _ci_source_rc

_ci_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  ci-menu'
  print -u2 -r -- '  ci-menu COMMAND [arguments]'
  print -u2 -r -- '  ci-menu -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Commands:'
  print -u2 -r -- '  ci-status               Inspect bounded GitHub Actions run data'
  print -u2 -r -- '  ci-run                  Dispatch one active workflow'
  print -u2 -r -- '  ci-clean-actions        Delete exact non-latest workflow runs'
  print -u2 -r -- '  ci-clean-deployments    Delete exact non-latest deployments'
  print -u2 -r -- '  ci-clean-releases       Delete exact non-latest releases'
  print -u2 -r -- '  ci-clean-notifications  Mark exact repository threads as read'
  print -u2 -r -- '  ci-clean-tags           Compatibility adapter to git-tag-list'
  print -u2 -r -- '  ci-clean-issues         Compatibility adapter to git-issues'
  print -u2 -r -- ''
  print -u2 -r -- 'Safety:'
  print -u2 -r -- \
    '  Remote mutations show an exact plan, support --dry-run, and require'
  print -u2 -r -- \
    '  a terminal confirmation unless --yes is supplied.'
  print -u2 -r -- \
    '  Repository identity and selected resources are revalidated after review.'
  print -u2 -r -- ''
  print -u2 -r -- 'Dependencies:'
  print -u2 -r -- \
    '  Operational commands require Git, authenticated gh, Python 3, and'
  print -u2 -r -- \
    '  timeout or gtimeout. Interactive selection additionally requires fzf.'
  print -u2 -r -- ''
  print -u2 -r -- 'Use COMMAND --help for command-specific flags.'
}

_ci_interactive() {
  _ci_require_fzf || return 1

  local -a menu_rows=()
  local row=""
  row=$(_ci_menu_section \
    "Inspection" \
    "Inspect GitHub Actions runs for the current repository.") || return
  menu_rows+=("$row")
  row=$(_ci_menu_entry \
    "Browse Workflow Runs" \
    "ci-status" \
    "Browse recent runs and choose one to inspect its status and details.") || return
  menu_rows+=("$row")
  row=$(_ci_menu_section \
    "Repository Actions" \
    "Run workflows or manage this repository's notifications.") \
    || return
  menu_rows+=("$row")
  row=$(_ci_menu_entry \
    "Trigger Workflow Run" \
    "ci-run" \
    "Choose a branch and run a GitHub Actions workflow with its configured permissions.") \
    || return
  menu_rows+=("$row")
  row=$(_ci_menu_entry \
    "Mark Notifications Read" \
    "ci-clean-notifications" \
    "Mark selected unread threads for this repository as read.") || return
  menu_rows+=("$row")
  row=$(_ci_menu_section \
    "Git Tools" \
    "Open tag and issue workflows owned by the Git suite.") \
    || return
  menu_rows+=("$row")
  row=$(_ci_menu_entry \
    "Open Git Tag Manager" \
    "ci-clean-tags" \
    "Browse and manage repository tags through the Git suite.") || return
  menu_rows+=("$row")
  row=$(_ci_menu_entry \
    "Open Git Issue Manager" \
    "ci-clean-issues" \
    "Browse and manage GitHub issues through the Git suite.") || return
  menu_rows+=("$row")
  row=$(_ci_menu_section \
    "Maintenance" \
    "Review selected GitHub resources before deleting them.") \
    || return
  menu_rows+=("$row")
  row=$(_ci_menu_entry \
    "Delete Workflow Runs" \
    "ci-clean-actions" \
    "Delete selected runs while preserving the newest run per workflow.") \
    || return
  menu_rows+=("$row")
  row=$(_ci_menu_entry \
    "Delete Deployments" \
    "ci-clean-deployments" \
    "Deactivate and delete selected deployments that are not the latest.") || return
  menu_rows+=("$row")
  row=$(_ci_menu_entry \
    "Delete Releases" \
    "ci-clean-releases" \
    "Delete selected releases while preserving the newest release.") || return
  menu_rows+=("$row")

  local -i fzf_rc=0
  _ci_fzf_capture \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='ci > ' \
    --header="Directory: ${(V)PWD}"$'\n'"Type to filter | Enter run | Esc cancel | Ctrl-/ details" \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    --bind='ctrl-/:toggle-preview' \
    < <(printf "%s\n" "${menu_rows[@]}") || fzf_rc=$?
  local selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _ci_fzf_rc_is_cancel "$fzf_rc" && return 0
    _ci_error "Unable to open the CI menu (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  (( ${menu_rows[(Ie)$selected]} > 0 )) || {
    _ci_error "The selected CI action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  _ci_timed "ci:$command_name" _ci_dispatch "$command_name"
}

ci-menu() {
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _ci_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _ci_error "--help accepts no arguments."
        return 2
      }
      _ci_usage
      ;;
    -*)
      _ci_error "Unknown option: $(_ci_display_escape "$1")"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _ci_timed "ci:$command_name" \
        _ci_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _CI_MENU_SOURCED=1
