#!/usr/bin/env zsh
# =============================================================================
# ZDX Installer: integrate a reviewed local checkout without editing profiles
# =============================================================================
# Executed by scripts/install.sh; requires installed Zsh and Python 3.8+.
# Safe to re-source; defines private helpers only.
#
if [[ -n "${_ZDX_INSTALL_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g _ZDX_INSTALL_SOURCE_FILE="${${(%):-%x}:A}"

_zdx_install_help() {
  print -u2 -r -- 'Usage: bash scripts/install.sh [--help | --dry-run | --yes]'
  print -u2 -r -- 'Integrate this reviewed local checkout with an existing Oh My Zsh installation.'
  print -u2 -r -- 'Requires Zsh and Python 3.8+; no downloads, updates, or shell-profile edits.'
  print -u2 -r -- '  --help     Show help without probing dependencies or installation paths.'
  print -u2 -r -- '  --dry-run  Validate and display the complete plan without writing files.'
  print -u2 -r -- '  --yes      Apply the validated plan without an interactive confirmation.'
  print -u2 -r -- 'With no option, a terminal confirmation is required. Flags are exclusive.'
  print -u2 -r -- 'Paths: HOME, ZSH (default $HOME/.oh-my-zsh), ZSH_CUSTOM (default $ZSH/custom).'
  print -u2 -r -- 'ZDOTDIR selects the shell-profile path shown in the activation instructions.'
}

_zdx_install_main() {
  emulate -L zsh
  setopt localtraps
  (( $# <= 1 )) || { _zdx_install_help; return 2; }
  case "$#:${1-}" in
    1:--help) _zdx_install_help; return 0 ;;
    0:|1:--dry-run|1:--yes) ;;
    *) print -u2 -r -- 'installer: unknown option; use --help.'; return 2 ;;
  esac

  local python_path="$(builtin whence -p python3)"
  [[ -n "$python_path" ]] || {
    print -u2 -r -- 'installer: Python 3 is required; install it with your package manager, then retry.'
    return 1
  }
  local source_root="${_ZDX_INSTALL_SOURCE_FILE:h:h}"
  local home_root="${HOME-}" omz_root="${ZSH:-${HOME-}/.oh-my-zsh}"
  local custom_root="${ZSH_CUSTOM:-$omz_root/custom}" profile_root="${ZDOTDIR:-${HOME-}}"
  local plan
  trap 'return 130' INT
  trap 'return 143' TERM HUP
  plan=$(command "$python_path" -I -S "$source_root/scripts/install_fs.py" plan \
    "$source_root" "$home_root" "$omz_root" "$custom_root" "$profile_root") || return $?
  [[ "${1-}" == --dry-run ]] && return 0
  if [[ "${1-}" != --yes ]]; then
    [[ -t 0 && -t 2 ]] || {
      print -u2 -r -- 'installer: a terminal confirmation is required; review --dry-run, then use --yes to apply unattended.'
      return 1
    }
    if ! read -q 'REPLY?Apply this installation plan? [y/N] '; then
      print -u2 -r -- $'\ninstaller: cancelled; no files changed.'
      return 0
    fi
    print -u2
  fi
  print -r -- "$plan" | command "$python_path" -I -S "$source_root/scripts/install_fs.py" apply || return $?
  print -u2 -r -- 'installer: local integration is ready.'
  print -u2 -r -- "Activation: edit ${(q)profile_root}/.zshrc and add zdx-suite to the plugins array before loading Oh My Zsh:"
  print -u2 -r -- '  plugins+=(zdx-suite)'
  print -u2 -r -- '  source "$ZSH/oh-my-zsh.sh"'
  print -u2 -r -- 'Preserve your other plugins and existing Oh My Zsh source line, then open a new Zsh terminal.'
  print -u2 -r -- 'Run zdx doctor in the new terminal to check suite dependencies; use zdx to open the launcher.'
  return 0
}

typeset -g _ZDX_INSTALL_SOURCED=1
if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
  _zdx_install_main "$@"
  exit $?
fi
