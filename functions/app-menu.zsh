#!/usr/bin/env zsh
# =============================================================================
# App Suite: public loader and command router
# =============================================================================
#
# Public loader and command router for project task discovery and execution.
# Usage: app-menu [-m|--multi | subcommand]
#

if [[ -n "${_APP_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _app_menu_loader_dir="${${(%):-%x}:A:h}"

_app_menu_source_module() {
  local module_name="$1"
  local module_file="${_app_menu_loader_dir}/app/${module_name}"
  [[ "$module_name" == "app-common.zsh" ]] \
    && module_file="${_app_menu_loader_dir}/app-common.zsh"

  local resolved_file="${module_file:A}"
  [[ ! -L "$module_file" \
    && -f "$module_file" \
    && -r "$module_file" \
    && "$resolved_file" == "$module_file" ]] || return 1
  builtin source "$module_file"
}

typeset -i _app_menu_load_rc=0
_app_menu_source_module "app-common.zsh" || _app_menu_load_rc=$?
if (( _app_menu_load_rc != 0 )); then
  print -u2 -r -- "app-menu.zsh: failed to load app-common.zsh"
  {
    return $_app_menu_load_rc 2>/dev/null || exit $_app_menu_load_rc
  } always {
    unset -f _app_menu_source_module
    unset _app_menu_load_rc _app_menu_loader_dir
  }
fi

_app_menu_load_rc=0
_app_menu_source_module "app-tasks.zsh" || _app_menu_load_rc=$?
if (( _app_menu_load_rc != 0 )); then
  print -u2 -r -- "app-menu.zsh: failed to load app-tasks.zsh"
  {
    return $_app_menu_load_rc 2>/dev/null || exit $_app_menu_load_rc
  } always {
    unset -f _app_menu_source_module
    unset _app_menu_load_rc _app_menu_loader_dir
  }
fi

unset -f _app_menu_source_module
unset _app_menu_load_rc _app_menu_loader_dir

_app_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  app-menu"
  print -u2 -r -- "  app-menu -m|--multi"
  print -u2 -r -- "  app-menu <subcommand> [arguments...]"
  print -u2 -r -- "  app-menu --help"
  print -u2 -r -- ""
  print -u2 -r -- "Canonical commands:"
  print -u2 -r -- "  app-list    List available project tasks and their backends."
  print -u2 -r -- "  app-run     Review and run one project task."
  print -u2 -r -- ""
  print -u2 -r -- \
    "Select a task to review its workspace and command before execution."
  print -u2 -r -- \
    "Use '<subcommand> --help' for exact grammar and safety controls."
  print -u2 -r -- \
    "Project task descriptors contain executable code; inspect and trust them."
}

app-menu() {
  emulate -L zsh

  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _app_interactive "no"
      ;;
    -m|--multi)
      (( $# == 1 )) || {
        _app_error "--multi accepts no additional arguments."
        return 2
      }
      _app_interactive "yes"
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _app_error "--help accepts no additional arguments."
        return 2
      }
      _app_usage
      ;;
    -*)
      _app_error "Unknown option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _app_timed "app:$command_name" \
        _app_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _APP_MENU_SOURCED=1
