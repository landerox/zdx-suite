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

# True on macOS when python3 is Apple's Command Line Tools placeholder: the
# /usr/bin/python3 shim while xcode-select reports no developer directory.
# Running the placeholder opens an installation dialog instead of Python.
_zdx_install_python_placeholder() {
  emulate -L zsh
  local python_path="${1-}" developer_dir=""
  [[ "$OSTYPE" == darwin* && "$python_path" == /usr/bin/python3 ]] || return 1
  builtin whence -p xcode-select >/dev/null 2>&1 || return 0
  developer_dir=$(command xcode-select -p </dev/null 2>/dev/null) || return 0
  developer_dir="${developer_dir%%$'\n'*}"
  [[ -n "$developer_dir" && -d "$developer_dir" ]] && return 1
  return 0
}

# Returns 0 only when python3 runs and reports 3.8 or newer; otherwise prints
# one clear diagnosis before any planning. Interruptions keep 130 or 143.
_zdx_install_python_ready() {
  emulate -L zsh
  local python_path="${1-}" version_text=""
  local -i version_rc=0 major=0 minor=0
  if _zdx_install_python_placeholder "$python_path"; then
    print -u2 -r -- "installer: $python_path is the Apple Command Line Tools placeholder, not Python."
    print -u2 -r -- 'installer: install the tools with xcode-select --install, or install Python 3.8+ from python.org or Homebrew, then retry.'
    return 1
  fi
  version_text=$(command "$python_path" -I -S -c \
    'import sys; print("%d.%d" % sys.version_info[:2])' </dev/null 2>/dev/null) \
    || version_rc=$?
  (( version_rc == 130 || version_rc == 143 )) && return $version_rc
  if (( version_rc != 0 )) || [[ ! "$version_text" =~ '^[0-9]{1,3}[.][0-9]{1,3}$' ]]; then
    print -u2 -r -- "installer: ${(V)python_path} did not run as Python 3 (status $version_rc); install Python 3.8 or newer, then retry."
    return 1
  fi
  major="${version_text%%.*}"
  minor="${version_text#*.}"
  if (( major < 3 || (major == 3 && minor < 8) )); then
    print -u2 -r -- "installer: Python 3.8 or newer is required; ${(V)python_path} reports Python $version_text."
    return 1
  fi
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
  trap 'return 130' INT
  trap 'return 143' TERM HUP
  _zdx_install_python_ready "$python_path" || return $?
  local source_root="${_ZDX_INSTALL_SOURCE_FILE:h:h}"
  local home_root="${HOME-}" omz_root="${ZSH:-${HOME-}/.oh-my-zsh}"
  local custom_root="${ZSH_CUSTOM:-$omz_root/custom}" profile_root="${ZDOTDIR:-${HOME-}}"
  local plan
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
