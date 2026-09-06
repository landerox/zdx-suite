#!/usr/bin/env zsh
# =============================================================================
# Workspace Menu: public loader and command router
# =============================================================================
#
# Public loader and command router for workspace and identity workflows.
# Usage: ws-menu [subcommand]
#

if [[ -n "${_WS_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _ws_menu_root="${${(%):-%x}:A:h}"
typeset _ws_menu_common="$_ws_menu_root/ws-common.zsh"
typeset -i _ws_menu_source_rc=0

if [[ -z "${_WS_COMMON_SOURCED:-}" ]]; then
  if [[ ! -f "$_ws_menu_common" || -L "$_ws_menu_common" \
    || ! -r "$_ws_menu_common" ]]; then
    print -u2 -r -- "ws-menu.zsh: failed to load ws-common.zsh"
    unset _ws_menu_root _ws_menu_common _ws_menu_source_rc
    return 1 2>/dev/null || exit 1
  fi

  source "$_ws_menu_common"
  _ws_menu_source_rc=$?
  if (( _ws_menu_source_rc != 0 )) \
    || [[ -z "${_WS_COMMON_SOURCED:-}" ]]; then
    print -u2 -r -- "ws-menu.zsh: failed to load ws-common.zsh"
    unset _ws_menu_root _ws_menu_common
    {
      (( _ws_menu_source_rc == 0 )) && _ws_menu_source_rc=1
      return $_ws_menu_source_rc 2>/dev/null || exit $_ws_menu_source_rc
    } always {
      unset _ws_menu_source_rc
    }
  fi
fi

typeset -a _ws_menu_modules=(
  ws-create.zsh
  ws-info.zsh
  ws-clone.zsh
  ws-sync.zsh
  ws-keys.zsh
  ws-danger.zsh
  ws-autoclean.zsh
)
typeset _ws_menu_module _ws_menu_module_path

for _ws_menu_module in "${_ws_menu_modules[@]}"; do
  _ws_menu_module_path="$_ws_menu_root/ws/$_ws_menu_module"
  if [[ ! -f "$_ws_menu_module_path" || -L "$_ws_menu_module_path" \
    || ! -r "$_ws_menu_module_path" ]]; then
    print -u2 -r -- \
      "ws-menu.zsh: failed to load $_ws_menu_module"
    unset _ws_menu_root _ws_menu_common _ws_menu_source_rc
    unset _ws_menu_modules _ws_menu_module _ws_menu_module_path
    return 1 2>/dev/null || exit 1
  fi

  source "$_ws_menu_module_path"
  _ws_menu_source_rc=$?
  if (( _ws_menu_source_rc != 0 )); then
    print -u2 -r -- \
      "ws-menu.zsh: failed to load $_ws_menu_module"
    unset _ws_menu_root _ws_menu_common
    unset _ws_menu_modules _ws_menu_module _ws_menu_module_path
    {
      return $_ws_menu_source_rc 2>/dev/null || exit $_ws_menu_source_rc
    } always {
      unset _ws_menu_source_rc
    }
  fi
done

unset _ws_menu_root _ws_menu_common _ws_menu_source_rc
unset _ws_menu_modules _ws_menu_module _ws_menu_module_path

_ws_menu_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  ws-menu                    Open the interactive Workspace menu"
  print -u2 -r -- "  ws-menu <command> [args]   Run one command directly"
  print -u2 -r -- "  ws-menu -h|--help          Show this help"
  print -u2 -r -- ""
  print -u2 -r -- "Commands:"
  print -u2 -r -- "  ws-auth          Check authentication across workspaces"
  print -u2 -r -- "  ws-create        Create an isolated workspace"
  print -u2 -r -- "  ws-list          List configured workspaces"
  print -u2 -r -- "  ws-info          Inspect one workspace"
  print -u2 -r -- "  ws-doctor        Diagnose workspace configuration"
  print -u2 -r -- "  ws-clone         Clone one repository into a workspace"
  print -u2 -r -- "  ws-clone-multi   Clone multiple repositories"
  print -u2 -r -- "  ws-sync          Fetch and update workspace repositories"
  print -u2 -r -- "  ws-repos         Inspect repositories in one workspace"
  print -u2 -r -- "  ws-migrate       Move repositories into a workspace"
  print -u2 -r -- "  ws-show-key      Display a workspace public key"
  print -u2 -r -- "  ws-rotate-key    Replace a workspace SSH key"
  print -u2 -r -- "  ws-test          Test a workspace SSH route"
  print -u2 -r -- "  ws-autoclean     Remove selected stale branches"
  print -u2 -r -- "  ws-remove        Remove a workspace and its configuration"
}

_ws_menu_rows() {
  local -a rows=()
  local row=""

  row=$(_ws_menu_section \
    "Inspection" "Check workspace identities, repositories, and configuration.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Check Authentication" "ws-auth" \
    "Check keys, GitHub CLI authentication, and SSH connections for each workspace.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "List Workspaces" "ws-list" \
    "List configured workspaces with identity and repository details.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Inspect Workspace" "ws-info" \
    "Inspect one workspace, its identity, key, routes, and repositories.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Diagnose Workspaces" "ws-doctor" \
    "Check workspace permissions, identity routing, and remote configuration.") \
    || return $?
  rows+=("$row")

  row=$(_ws_menu_entry \
    "Inspect Repositories" "ws-repos" \
    "Show branches, working-tree changes, and remote destinations in one workspace.") \
    || return $?
  rows+=("$row")

  row=$(_ws_menu_section \
    "Workspaces and Repositories" "Create workspaces, clone repositories, and synchronize changes.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Create Workspace" "ws-create" \
    "Create a workspace with isolated Git identity, SSH key, and routing.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Clone Repository" "ws-clone" \
    "Clone a repository using the selected workspace identity.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Clone Repositories" "ws-clone-multi" \
    "Clone a reviewed list of repositories into one workspace.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Sync Repositories" "ws-sync" \
    "Fetch repositories and fast-forward eligible branches in one workspace.") \
    || return $?
  rows+=("$row")

  row=$(_ws_menu_section \
    "SSH Keys" "Inspect, replace, and test workspace SSH identities.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Show Public Key" "ws-show-key" \
    "Display the selected workspace public key and fingerprint.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Rotate SSH Key" "ws-rotate-key" \
    "Back up the current key and generate a replacement keypair.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Test SSH Route" "ws-test" \
    "Test the selected workspace alias without changing its configuration.") \
    || return $?
  rows+=("$row")

  row=$(_ws_menu_section \
    "Maintenance" "Review moves and deletions before changing workspace data.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Migrate Repositories" "ws-migrate" \
    "Move selected repositories into one workspace and optionally rewrite remotes.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Clean Stale Branches" "ws-autoclean" \
    "Review and remove selected stale branches across one workspace.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Remove Workspace" "ws-remove" \
    "Delete one workspace, its repositories, SSH key, and routing entries.") \
    || return $?
  rows+=("$row")

  print -rl -- "${rows[@]}"
}

_ws_menu_interactive() {
  _ws_check_cmd fzf || {
    _ws_error "fzf is required for the interactive Workspace menu."
    return 1
  }

  local rows=""
  rows=$(_ws_menu_rows) || return $?

  local current_workspace=""
  local workspace_output=""
  local -i workspace_count=0
  current_workspace=$(_tk_detect_workspace 2>/dev/null) || current_workspace=""
  workspace_output=$(_ws_list_workspaces 2>/dev/null) || workspace_output=""
  if [[ -n "$workspace_output" ]]; then
    local -a workspaces=("${(@f)workspace_output}")
    workspace_count=${#workspaces[@]}
  fi

  local context="Workspace: (outside) | Configured: $workspace_count"
  [[ -n "$current_workspace" ]] \
    && context="Workspace: $current_workspace | Configured: $workspace_count"
  local header="${context}"$'\n''Type to filter | Enter run | Esc cancel | Ctrl-/ details'

  local selected=""
  local -i fzf_rc=0
  _ws_fzf_capture \
    --prompt='ws > ' \
    --header="$header" \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    --bind='ctrl-/:toggle-preview' \
    < <(print -r -- "$rows") || fzf_rc=$?
  selected="$REPLY"

  if (( fzf_rc != 0 )); then
    if _ws_fzf_rc_is_cancel "$fzf_rc"; then
      return 0
    fi
    _ws_error "Unable to open the interactive Workspace menu (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 0

  local -a row_snapshot=("${(@f)rows}")
  _ws_array_contains_literal "$selected" "${row_snapshot[@]}" || {
    _ws_error "The selected Workspace action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  _ws_timed "ws:$command_name" _ws_dispatch "$command_name"
}

ws-menu() {
  emulate -L zsh

  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _ws_menu_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _ws_error "--help accepts no additional arguments."
        return 2
      }
      _ws_menu_usage
      ;;
    -*)
      _ws_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _ws_timed "ws:$command_name" \
        _ws_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _WS_MENU_SOURCED=1

if [[ "${zsh_eval_context[-1]}" == "toplevel" ]]; then
  ws-menu "$@"
fi
