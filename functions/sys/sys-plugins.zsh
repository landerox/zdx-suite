#!/usr/bin/env zsh
# =============================================================================
# System Plugins: compatibility bridge to the core plugin manager
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_PLUGINS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_sys_plugins_load_owner() {
  if typeset -f zdx-plugins &>/dev/null; then
    return 0
  fi

  local module_dir="${${(%):-%x}:A:h:h}"
  local owner_file="${module_dir}/zdx-plugins.zsh"
  if [[ ! -f "$owner_file" || ! -r "$owner_file" ]]; then
    _sys_error "The core zdx-plugins manager is unavailable."
    return 1
  fi

  source "$owner_file" || {
    _sys_error "Failed to load the core zdx-plugins manager."
    return 1
  }

  if ! typeset -f zdx-plugins &>/dev/null; then
    _sys_error "The core plugin manager did not define zdx-plugins."
    return 1
  fi
}

_sys_plugins_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  sys-plugins [zdx-plugins options]'
  print -u2 -r -- '  sys-plugins -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- 'Compatibility command. Plugin lifecycle ownership belongs to zdx-plugins.'
  print -u2 -r -- 'Run "zdx-plugins --help" for the canonical interface.'
}

sys-plugins() {
  case "${1:-}" in
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_plugins_usage
      return 0
      ;;
  esac

  _sys_plugins_load_owner || return 1
  _sys_warn "sys-plugins is a compatibility command; delegating to zdx-plugins."
  zdx-plugins "$@"
}

typeset -g _SYS_PLUGINS_SOURCED=1
