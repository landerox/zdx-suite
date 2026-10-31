#!/usr/bin/env zsh
# =============================================================================
# ZDX Version: the release reported by zdx --version and zdx status
# =============================================================================
#
# Sourced by functions.zsh, and by zdx-menu.zsh or zdx-status.zsh when one of
# them is loaded on its own. Defines the release parameter and the checkout
# probe only. Commitizen rewrites the release line (version_files in
# pyproject.toml).
#

if [[ -n "${_ZDX_VERSION_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g _ZDX_RELEASE_VERSION="0.1.0" # ZDX (Zsh Developer Experience)

# reply: the abbreviated commit of the ZDX checkout at ROOT and "modified"
# when tracked files differ from it, or an empty second element. It applies
# only when ROOT is exactly the top level of a Git work tree, so an install
# from a release archive, or a copy inside another repository, reports
# nothing. Git runs through the core timeout service with optional locks off,
# untracked files ignored, and GIT_DIR, GIT_WORK_TREE, and GIT_INDEX_FILE
# removed; status 1 when any of that is unavailable or fails.
# Usage: _zdx_release_checkout ROOT
_zdx_release_checkout() {
  emulate -L zsh
  local MATCH="" MBEGIN=0 MEND=0
  local -a match=() mbegin=() mend=()
  local root="${1:-}" git_path="" toplevel="" commit="" changes=""
  reply=()
  [[ "$root" == /* && ( -d "$root/.git" || -f "$root/.git" ) ]] \
    && (( ${+functions[_zdx_run_with_timeout]} )) || return 1
  git_path=$(whence -p git 2>/dev/null) || return 1
  if [[ "${OSTYPE:-}" == darwin* && "$git_path" == /usr/bin/git ]]; then
    # Apple's placeholder opens an installation dialog without a developer
    # directory.
    local developer_dir=""
    developer_dir=$(_zdx_run_with_timeout 3 xcode-select -p \
      </dev/null 2>/dev/null) || return 1
    [[ -d "${developer_dir%%$'\n'*}" ]] || return 1
  fi
  local -a git_run=(
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE GIT_OPTIONAL_LOCKS=0
    "$git_path" -C "$root"
  )
  toplevel=$(_zdx_run_with_timeout 3 "${git_run[@]}" \
    rev-parse --show-toplevel </dev/null 2>/dev/null) || return 1
  [[ -n "$toplevel" && "${toplevel:A}" == "${root:A}" ]] || return 1
  commit=$(_zdx_run_with_timeout 3 "${git_run[@]}" \
    rev-parse --short=7 --verify 'HEAD^{commit}' </dev/null 2>/dev/null) \
    || return 1
  [[ "$commit" =~ '^[0-9a-f]{7,40}$' ]] || return 1
  changes=$(_zdx_run_with_timeout 5 "${git_run[@]}" \
    status --porcelain --untracked-files=no </dev/null 2>/dev/null) \
    || return 1
  reply=("$commit" "${changes:+modified}")
}

typeset -g _ZDX_VERSION_SOURCED=1
