#!/usr/bin/env zsh
# =============================================================================
# Docker Menu: public loader and command router for container workflows
# =============================================================================
#
# Public loader and command router for Docker workflows.
# Usage: docker-menu [subcommand]
#

if [[ -n "${_DOCKER_MENU_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _docker_loader_dir="${${(%):-%x}:A:h}"

_docker_source_module() {
  local relative_name="$1"
  local module_file="${_docker_loader_dir}/${relative_name}"
  [[ -f "$module_file" && ! -L "$module_file" && -r "$module_file" \
    && "${module_file:A}" == "$module_file" \
    && "${module_file:A:h}" == "${module_file:h}" ]] || return 1
  builtin source "$module_file"
}

typeset -i _docker_source_rc=0
typeset _docker_failed_module="docker-common.zsh"
_docker_source_module "$_docker_failed_module" || _docker_source_rc=$?
if (( _docker_source_rc == 0 )); then
  typeset _docker_module=""
  for _docker_module in \
    docker/docker-containers.zsh \
    docker/docker-images.zsh \
    docker/docker-clean.zsh \
    docker/docker-compose.zsh \
    docker/docker-registry.zsh; do
    _docker_failed_module="$_docker_module"
    _docker_source_module "$_docker_failed_module" || {
      _docker_source_rc=$?
      break
    }
  done
fi
if (( _docker_source_rc != 0 )); then
  print -u2 -r -- \
    "docker-menu.zsh: failed to load $_docker_failed_module (status $_docker_source_rc)"
  unset -f _docker_source_module
  unset _docker_loader_dir _docker_module _docker_failed_module
  {
    return $_docker_source_rc 2>/dev/null || exit $_docker_source_rc
  } always {
    unset _docker_source_rc
  }
fi

unset -f _docker_source_module
unset _docker_loader_dir _docker_module _docker_failed_module _docker_source_rc

_docker_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  docker-menu'
  print -u2 -r -- '  docker-menu COMMAND [arguments]'
  print -u2 -r -- '  docker-menu -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Commands:'
  print -u2 -r -- '  docker-containers       Inspect and act on exact containers'
  print -u2 -r -- '  docker-images           Inspect, run, or remove exact images'
  print -u2 -r -- '  docker-clean            Plan and remove exact unused resources'
  print -u2 -r -- '  docker-login            Authenticate to a validated registry'
  print -u2 -r -- '  docker-compose-up       Start one reviewed Compose project'
  print -u2 -r -- '  docker-compose-down     Stop one reviewed Compose project'
  print -u2 -r -- '  docker-compose-restart  Restart one reviewed Compose project'
  print -u2 -r -- '  docker-compose-logs     Read bounded Compose logs'
  print -u2 -r -- ''
  print -u2 -r -- \
    'Use COMMAND --help for command-specific flags and output contracts.'
}

_docker_interactive() {
  _docker_require_cmd fzf "the interactive Docker menu" || return 1

  local -a menu_rows=()
  local row=""
  row=$(_docker_menu_section \
    "Inspection" "Browse resources in the selected Docker context.") \
    || return
  menu_rows+=("$row")
  row=$(_docker_menu_entry \
    "Browse Containers" "docker-containers" \
    "Choose a container to open a shell, read logs, start, stop, or remove it.") || return
  menu_rows+=("$row")
  row=$(_docker_menu_entry \
    "Browse Images" "docker-images" \
    "Choose an image to run after review or remove from the selected daemon.") || return
  menu_rows+=("$row")

  row=$(_docker_menu_section \
    "Compose" "Read logs or manage the current Compose project.") || return
  menu_rows+=("$row")
  row=$(_docker_menu_entry \
    "Read Compose Logs" "docker-compose-logs" \
    "Show recent project logs; follow new output only when requested.") || return
  menu_rows+=("$row")
  row=$(_docker_menu_entry \
    "Start Compose Project" "docker-compose-up" \
    "Review the Compose configuration and start its services.") || return
  menu_rows+=("$row")
  row=$(_docker_menu_entry \
    "Stop Compose Project" "docker-compose-down" \
    "Stop and remove the current project's containers and networks.") || return
  menu_rows+=("$row")
  row=$(_docker_menu_entry \
    "Restart Compose Project" "docker-compose-restart" \
    "Review the current Compose project and restart its services.") || return
  menu_rows+=("$row")

  row=$(_docker_menu_section \
    "Registry" "Sign in to a container registry.") || return
  menu_rows+=("$row")
  row=$(_docker_menu_entry \
    "Log In to Registry" "docker-login" \
    "Sign in to a registry; a running Docker daemon is not required.") || return
  menu_rows+=("$row")

  row=$(_docker_menu_section \
    "Maintenance" "Review unused resources before deleting them.") || return
  menu_rows+=("$row")
  row=$(_docker_menu_entry \
    "Clean Unused Resources" "docker-clean" \
    "Choose resource types and review the unused items to delete.") || return
  menu_rows+=("$row")

  local header=""
  header=$(_docker_menu_header)
  local -i fzf_rc=0
  _docker_fzf_capture \
    --delimiter='[|]' \
    --with-nth=1 \
    --prompt='docker > ' \
    --header="$header"$'\n'"Type to filter | Enter run | Esc cancel | Ctrl-/ details" \
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac' \
    --preview-window='down:4:wrap' \
    --bind='ctrl-/:toggle-preview' \
    < <(printf '%s\n' "${menu_rows[@]}") || fzf_rc=$?
  local selected="$REPLY"

  if (( fzf_rc != 0 )); then
    _docker_fzf_rc_is_cancel "$fzf_rc" && return 0
    _docker_error "Unable to open the Docker menu (status $fzf_rc)."
    return 1
  fi
  [[ -z "$selected" ]] && return 0
  _docker_array_contains_literal "$selected" "${menu_rows[@]}" || {
    _docker_error "The selected Docker action was not in the menu snapshot."
    return 1
  }

  local command_name="${${selected#*|}%%|*}"
  [[ "$command_name" == ":" ]] && return 0
  if typeset -f _timed &>/dev/null; then
    _timed "docker:$command_name" _docker_dispatch "$command_name"
  else
    _docker_dispatch "$command_name"
  fi
}

docker-menu() {
  case "${1:-}" in
    "")
      (( $# == 0 )) || return 2
      _docker_interactive
      ;;
    -h|--help)
      (( $# == 1 )) || {
        _docker_error "--help accepts no additional arguments."
        return 2
      }
      _docker_usage
      ;;
    -*)
      _docker_error "Unknown docker-menu option: $1"
      return 2
      ;;
    *)
      local command_name="$1"
      shift
      if typeset -f _timed &>/dev/null; then
        _timed "docker:$command_name" \
          _docker_dispatch "$command_name" "$@"
      else
        _docker_dispatch "$command_name" "$@"
      fi
      ;;
  esac
}

typeset -g _DOCKER_MENU_SOURCED=1
