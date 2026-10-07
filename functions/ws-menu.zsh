#!/usr/bin/env zsh
# =============================================================================
# Ws Suite: public loader and command router
# =============================================================================
#
# Public loader and command router for workspace repository workflows.
# Usage: ws-menu [subcommand] [arguments...]
#

if [[ -n "${_WS_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _ws_menu_loader_dir="${${(%):-%x}:A:h}"

_ws_menu_source_module() {
  local module_name="$1"
  local module_file="${_ws_menu_loader_dir}/ws/${module_name}"
  [[ "$module_name" == "ws-common.zsh" ]] \
    && module_file="${_ws_menu_loader_dir}/ws-common.zsh"

  local resolved_file="${module_file:A}"
  [[ ! -L "$module_file" \
    && -f "$module_file" \
    && -r "$module_file" \
    && "$resolved_file" == "$module_file" ]] || return 1
  builtin source "$module_file"
}

typeset -i _ws_menu_load_rc=0
_ws_menu_source_module "ws-common.zsh" || _ws_menu_load_rc=$?
if (( _ws_menu_load_rc != 0 )); then
  print -u2 -r -- "ws-menu.zsh: failed to load ws-common.zsh"
  {
    return $_ws_menu_load_rc 2>/dev/null || exit $_ws_menu_load_rc
  } always {
    unset -f _ws_menu_source_module
    unset _ws_menu_load_rc _ws_menu_loader_dir
  }
fi

typeset _ws_menu_module=""
for _ws_menu_module in \
  ws-jump.zsh \
  ws-status.zsh \
  ws-clone.zsh; do
  _ws_menu_load_rc=0
  _ws_menu_source_module "$_ws_menu_module" || _ws_menu_load_rc=$?
  if (( _ws_menu_load_rc != 0 )); then
    print -u2 -r -- \
      "ws-menu.zsh: failed to load ${_ws_menu_module}"
    {
      return $_ws_menu_load_rc 2>/dev/null || exit $_ws_menu_load_rc
    } always {
      unset -f _ws_menu_source_module
      unset _ws_menu_load_rc _ws_menu_loader_dir _ws_menu_module
    }
  fi
done

unset -f _ws_menu_source_module
unset _ws_menu_load_rc _ws_menu_loader_dir _ws_menu_module

_ws_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  ws-menu"
  print -u2 -r -- "  ws-menu <subcommand> [arguments...]"
  print -u2 -r -- "  ws-menu --help"
  print -u2 -r -- ""
  print -u2 -r -- "Canonical subcommands:"
  print -u2 -r -- "  ws-status, ws-jump, ws-clone"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Arguments after a subcommand are forwarded unchanged."
  print -u2 -r -- \
    "Use '<subcommand> --help' for exact grammar and safety flags."
  print -u2 -r -- \
    "ws-jump changes the directory of the current shell; ws-clone supports --dry-run and --yes."
}

# stdout records: label|command|description
_ws_menu_rows() {
  local -a rows=()
  local row=""

  row=$(_ws_menu_section \
    "Inspection" "Read-only status for every repository below the workspace root.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Show Workspace Status" "ws-status" \
    "List branch, changes, ahead/behind, stashes, and last commit for each repository.") \
    || return $?
  rows+=("$row")

  row=$(_ws_menu_section \
    "Navigation" "Move this shell between repositories in the workspace layout.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Jump to Repository" "ws-jump" \
    "Pick a repository and change to its directory in the current shell.") \
    || return $?
  rows+=("$row")

  row=$(_ws_menu_section \
    "Repositories" "Add repositories to the platform/identity/repository layout.") \
    || return $?
  rows+=("$row")
  row=$(_ws_menu_entry \
    "Clone Repository" "ws-clone" \
    "Review and clone a URL into its workspace, applying the matching Git identity.") \
    || return $?
  rows+=("$row")

  print -rl -- "${rows[@]}"
}

# REPLY: the menu context block, a scope line and a state line of facts. It
# never scans the workspace, so opening the menu stays constant-time.
_ws_menu_context() {
  local root="${WS_BASE_DIR-}" root_state="present" discovery="none"
  local profiles="none" scope_value=""
  local -a reply=()
  if [[ -z "$root" || "$root" != /* ]]; then
    scope_value="not set"
    root_state="invalid"
  else
    _ws_command_display "$root"
    scope_value="$REPLY"
    [[ -d "$root" ]] || root_state="missing"
  fi
  _ws_discovery_backend && discovery="${reply[2]}"
  if [[ "${(t)ZDX_GIT_IDENTITIES-}" == *association* ]] \
    && (( ${#ZDX_GIT_IDENTITIES} > 0 )); then
    profiles="${#ZDX_GIT_IDENTITIES}"
  fi
  REPLY="Workspace: ${(V)scope_value}"$'\n'
  REPLY+="Root: $root_state | Discovery: $discovery | Profiles: $profiles"
}

_ws_menu_interactive() {
  _ws_require_cmd fzf "the interactive Workspace menu" || return 1

  local rows_output=""
  rows_output=$(_ws_menu_rows) || return $?
  local -a rows=("${(@f)rows_output}")
  (( ${#rows[@]} <= _WS_MAX_MENU_ROWS )) || {
    _ws_error "The Workspace menu exceeds its row limit."
    return 1
  }

  local REPLY=""
  _ws_menu_context
  local context="$REPLY"
  local selected=""
  local -i fzf_rc=0
  _ws_fzf_capture \
    --height='80%' \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='ws > ' \
    --header="$context"$'\n''Type to filter | Enter run | Esc cancel | Ctrl-/ details' \
    --bind='ctrl-/:toggle-preview' \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _ws_fzf_rc_is_cancel "$fzf_rc" && return 0
    _ws_error "Unable to open the interactive Workspace menu (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 0
  [[ "$selected" != *$'\n'* && "$selected" != *$'\r'* ]] || {
    _ws_error "Refusing malformed Workspace menu output."
    return 1
  }
  _ws_array_contains_literal "$selected" "${rows[@]}" || {
    _ws_error "The selected Workspace action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  # ws-jump changes the directory of this shell, so dispatch stays in it.
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
      _ws_usage
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
