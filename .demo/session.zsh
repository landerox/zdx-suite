#!/usr/bin/env zsh
# =============================================================================
# ZDX Demo: real menu browsing inside a private recording workspace
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
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/file-menu.zsh" || return
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/dev-menu.zsh" || return
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/sys-menu.zsh" || return
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/ai-menu.zsh" || return
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/git-menu.zsh" || return
  builtin source "$ZDX_DEMO_SOURCE_ROOT/functions/zdx-menu.zsh" || return
  # The rows and previews are real; a mistyped tape cannot run backend actions.
  _file_dispatch() { _zdx_demo_deny; }
  _dev_dispatch() { _zdx_demo_deny; }
  _sys_dispatch() { _zdx_demo_deny; }
  _ai_dispatch() { _zdx_demo_deny; }
  _git_dispatch() { _zdx_demo_deny; }
  _zdx_dispatch_suite() {
    (( $# == 1 )) || { _zdx_demo_deny; return $?; }
    case "$1" in
      dev) dev-menu ;;
      sys) sys-menu ;;
      ai) ai-menu ;;
      git) git-menu ;;
      file) file-menu ;;
      *) _zdx_demo_deny ;;
    esac
  }
  builtin cd -- "$ZDX_DEMO_ROOT/home/workspace/zdx-demo" || return
  PROMPT='zdx-demo > '
  RPROMPT=''
  HISTFILE=''
  print -r -- DEMO_READY
}

_zdx_demo_deny() {
  print -r -- denied > "$ZDX_DEMO_ROOT/action.denied"
  print -u2 -r -- 'demo: backend actions are disabled during recording.'
  return 99
}

_zdx_demo_check() {
  (( $1 == 0 )) || return "$1"
  print -r -- 0 >> "$ZDX_DEMO_ROOT/steps"
}

_zdx_demo_finish() {
  [[ ! -e "$ZDX_DEMO_ROOT/action.denied" && -f "$ZDX_DEMO_ROOT/steps" \
    && "$(<"$ZDX_DEMO_ROOT/steps")" == $'0\n0\n0\n0\n0' ]] || return 1
  print -r -- 0 > "$ZDX_DEMO_ROOT/session.complete"
  print -r -- DEMO_COMPLETE
}

typeset -g _ZDX_DEMO_SESSION_SOURCED=1
