#!/usr/bin/env zsh
# =============================================================================
# Env Suite: public loader and command router
# =============================================================================
#
# Public entrypoint for passive dotenv, exported-variable, PATH, and private
# profile workflows. Usage: env-menu [subcommand] [arguments...]
#

if [[ -n "${_ENV_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _env_menu_loader_dir="${${(%):-%x}:A:h}"

_env_menu_source_module() {
  local module_name="$1"
  local module_file="${_env_menu_loader_dir}/env/${module_name}"
  [[ "$module_name" == "env-common.zsh" ]] \
    && module_file="${_env_menu_loader_dir}/env-common.zsh"

  local resolved_file="${module_file:A}"
  [[ ! -L "$module_file" \
    && -f "$module_file" \
    && -r "$module_file" \
    && "$resolved_file" == "$module_file" ]] || return 1
  builtin source "$module_file"
}

typeset -i _env_menu_load_rc=0
_env_menu_source_module "env-common.zsh" || _env_menu_load_rc=$?
if (( _env_menu_load_rc != 0 )); then
  print -u2 -r -- "env-menu.zsh: failed to load env-common.zsh"
  {
    return $_env_menu_load_rc 2>/dev/null || exit $_env_menu_load_rc
  } always {
    unset -f _env_menu_source_module
    unset _env_menu_load_rc _env_menu_loader_dir
  }
fi

typeset _env_menu_module=""
for _env_menu_module in \
  env-dotenv.zsh \
  env-vars.zsh \
  env-profiles.zsh; do
  _env_menu_load_rc=0
  _env_menu_source_module "$_env_menu_module" || _env_menu_load_rc=$?
  if (( _env_menu_load_rc != 0 )); then
    print -u2 -r -- \
      "env-menu.zsh: failed to load ${_env_menu_module}"
    {
      return $_env_menu_load_rc 2>/dev/null || exit $_env_menu_load_rc
    } always {
      unset -f _env_menu_source_module
      unset _env_menu_load_rc _env_menu_loader_dir _env_menu_module
    }
  fi
done

unset -f _env_menu_source_module
unset _env_menu_load_rc _env_menu_loader_dir _env_menu_module

_env_usage() {
  print -u2 -r -- "Usage:"
  print -u2 -r -- "  env-menu"
  print -u2 -r -- "  env-menu <subcommand> [arguments...]"
  print -u2 -r -- "  env-menu --help"
  print -u2 -r -- ""
  print -u2 -r -- "Canonical subcommands:"
  print -u2 -r -- \
    "  env-switch, env-create, env-list, env-path"
  print -u2 -r -- \
    "  env-profile-save, env-profile-list, env-profile-load, env-profile-delete"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Arguments after a subcommand are forwarded unchanged."
  print -u2 -r -- \
    "Use '<subcommand> --help' for exact grammar and safety flags."
}

# stdout records: label|command|description
_env_menu_rows() {
  local -a rows=()
  local row=""

  row=$(_env_menu_section \
    "Inspection" "Inspect exported variables, PATH, and saved profiles.") \
    || return $?
  rows+=("$row")
  row=$(_env_menu_entry \
    "Browse Exported Variables" "env-list" \
    "Browse variables with masked values; select a value explicitly to copy it.") \
    || return $?
  rows+=("$row")
  row=$(_env_menu_entry \
    "Inspect PATH" "env-path" \
    "Find missing, writable, duplicate, and current-directory PATH entries.") \
    || return $?
  rows+=("$row")

  row=$(_env_menu_entry \
    "List Profiles" "env-profile-list" \
    "Show saved profile names and variable counts without revealing values.") \
    || return $?
  rows+=("$row")
  row=$(_env_menu_section \
    "Dotenv Files" "Create or load dotenv data without executing shell code.") \
    || return $?
  rows+=("$row")
  row=$(_env_menu_entry \
    "Load Dotenv" "env-switch" \
    "Choose a dotenv file and review variable names before changing this session.") \
    || return $?
  rows+=("$row")
  row=$(_env_menu_entry \
    "Create Dotenv" "env-create" \
    "Create a private dotenv file from a template or values entered with hidden input.") \
    || return $?
  rows+=("$row")

  row=$(_env_menu_section \
    "Private Profiles" "Save or load environment snapshots with hidden values.") \
    || return $?
  rows+=("$row")
  row=$(_env_menu_entry \
    "Save Profile" "env-profile-save" \
    "Save selected exported variables in a private profile for later use.") \
    || return $?
  rows+=("$row")
  row=$(_env_menu_entry \
    "Load Profile" "env-profile-load" \
    "Review a saved profile before applying its variables to this session.") \
    || return $?
  rows+=("$row")
  row=$(_env_menu_entry \
    "Delete Profile" "env-profile-delete" \
    "Review and delete one saved profile; current session variables stay unchanged.") \
    || return $?
  rows+=("$row")

  print -rl -- "${rows[@]}"
}

_env_dispatch() {
  local command_name="${1:-}"
  (( $# > 0 )) && shift
  case "$command_name" in
    :) return 0 ;;
    env-switch) env-switch "$@" ;;
    env-create) env-create "$@" ;;
    env-list) env-list "$@" ;;
    env-path) env-path "$@" ;;
    env-profile-save) env-profile-save "$@" ;;
    env-profile-list) env-profile-list "$@" ;;
    env-profile-load) env-profile-load "$@" ;;
    env-profile-delete) env-profile-delete "$@" ;;
    *)
      _env_error "Unknown Environment command: $command_name"
      return 2
      ;;
  esac
}

_env_menu_interactive() {
  _env_require_cmd fzf "the interactive Environment menu" || return 1
  local rows_output=""
  rows_output=$(_env_menu_rows) || return $?
  local -a rows=("${(@f)rows_output}")
  (( ${#rows[@]} <= _ENV_MAX_MENU_ROWS )) || {
    _env_error "The Environment menu exceeds its row limit."
    return 1
  }

  local selected=""
  local -i fzf_rc=0
  _env_fzf_capture \
    --height='80%' \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='env > ' \
    --header="Directory: ${(V)PWD}"$'\n'"Type to filter | Enter run | Esc cancel | Ctrl-/ details" \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    --bind='ctrl-/:toggle-preview' \
    < <(print -rl -- "${rows[@]}") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    if _env_fzf_rc_is_cancel "$fzf_rc" && [[ -z "$selected" ]]; then
      return 0
    fi
    _env_error "Unable to open the Environment menu (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 0
  [[ "$selected" != *$'\n'* && "$selected" != *$'\r'* ]] || {
    _env_error "Refusing malformed Environment menu output."
    return 1
  }
  local -i selected_row_position=0
  selected_row_position="${rows[(Ie)$selected]}"
  (( selected_row_position > 0 )) || {
    _env_error "The selected Environment action was not in the menu snapshot."
    return 1
  }
  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  _env_info "Executing: $command_name"
  _env_timed "env:$command_name" _env_dispatch "$command_name"
}

env-menu() {
  emulate -L zsh
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _env_menu_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _env_error "--help accepts no additional arguments."
        return 2
      }
      _env_usage
      ;;
    -*)
      _env_error "Unknown env-menu option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      _env_timed "env:$command_name" \
        _env_dispatch "$command_name" "$@"
      ;;
  esac
}

typeset -g _ENV_MENU_SOURCED=1

if [[ "${ZSH_EVAL_CONTEXT:-}" == "toplevel" ]]; then
  env-menu "$@"
fi
