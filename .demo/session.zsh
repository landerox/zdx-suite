#!/usr/bin/env zsh
# =============================================================================
# ZDX Demo: real menus and three private actions inside a recording workspace
# =============================================================================
#
# Loaded by demo.tape after record.zsh creates the isolated environment.
# Safe to source; defines private session and completion helpers only.
#

if [[ -n "${_ZDX_DEMO_SESSION_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_zdx_demo_session() {
  [[ -n "${ZDX_DEMO_ROOT:-}" && -d "$ZDX_DEMO_ROOT" \
    && ! -L "$ZDX_DEMO_ROOT" && -O "$ZDX_DEMO_ROOT" \
    && "$HOME" == "$ZDX_DEMO_ROOT/home" \
    && "$ZDOTDIR" == "$ZDX_DEMO_ROOT/zdotdir" \
    && "$TMPDIR" == "$ZDX_DEMO_ROOT/tmp" ]] || return 1
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions.zsh" || return
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/git-menu.zsh" || return
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/sys-menu.zsh" || return
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/dev-menu.zsh" || return
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/zdx-menu.zsh" || return
  # Rows, previews, and plans are real. Only three actions can run, all in the
  # private demo project: saving a stash, reading the system information, and
  # checking the project's health. Everything else is denied.
  functions[_zdx_demo_git_dispatch]=$functions[_git_dispatch]
  functions[_zdx_demo_sys_dispatch]=$functions[_sys_dispatch]
  functions[_zdx_demo_dev_dispatch]=$functions[_dev_dispatch]
  _git_dispatch() {
    _zdx_demo_allowed git-stash "$@" || return $?
    _zdx_demo_git_dispatch "$@"
  }
  _sys_dispatch() {
    _zdx_demo_allowed sys-info "$@" || return $?
    _zdx_demo_sys_dispatch "$@"
  }
  _dev_dispatch() {
    _zdx_demo_allowed dev-check-health "$@" || return $?
    _zdx_demo_dev_dispatch "$@"
  }
  _zdx_dispatch_suite() {
    (( $# == 1 )) || { _zdx_demo_deny; return $?; }
    case "$1" in
      git) git-menu ;;
      sys) sys-menu ;;
      dev) dev-menu ;;
      *) _zdx_demo_deny ;;
    esac
  }
  builtin cd -- "$ZDX_DEMO_ROOT/home/workspace/zdx-demo" || return
  PROMPT='%F{blue}%~%f %F{green}❯%f '
  RPROMPT=''
  HISTFILE=''
  print -r -- DEMO_READY
}

# Allows exactly one argument-free action, and only in the demo project.
# Usage: _zdx_demo_allowed <action> <dispatched arguments...>
_zdx_demo_allowed() {
  local action="$1"
  shift
  [[ $# == 1 && "$1" == "$action" \
    && "$PWD" == "$ZDX_DEMO_ROOT/home/workspace/zdx-demo" ]] && return 0
  _zdx_demo_deny
}

_zdx_demo_deny() {
  print -r -- denied > "$ZDX_DEMO_ROOT/action.denied"
  print -u2 -r -- 'demo: this action is disabled during recording.'
  return 99
}

_zdx_demo_check() {
  (( $1 == 0 )) || return "$1"
  print -r -- 0 >> "$ZDX_DEMO_ROOT/steps"
}

# Publishes completion only when the Git, System, and Developer steps returned
# 0, nothing was denied, and the stash exists.
_zdx_demo_finish() {
  local project="$ZDX_DEMO_ROOT/home/workspace/zdx-demo"
  local stashes=""
  [[ ! -e "$ZDX_DEMO_ROOT/action.denied" && -f "$ZDX_DEMO_ROOT/steps" \
    && "$(<"$ZDX_DEMO_ROOT/steps")" == $'0\n0\n0' ]] || return 1
  stashes=$(command git -C "$project" stash list 2>/dev/null) || return 1
  [[ "$stashes" == *'WIP: friendlier greeting'* ]] || return 1
  print -r -- 0 > "$ZDX_DEMO_ROOT/session.complete"
  print -r -- DEMO_COMPLETE
}

typeset -g _ZDX_DEMO_SESSION_SOURCED=1
