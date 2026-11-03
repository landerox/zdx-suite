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
# removed. Unavailable metadata may be omitted; returned interruption statuses
# must reach the public consumer before it prints a successful report.
# Usage: _zdx_release_checkout ROOT
_zdx_release_checkout() {
  emulate -L zsh
  local MATCH="" MBEGIN=0 MEND=0
  local -a match=() mbegin=() mend=()
  local root="${1:-}" git_path="" env_path="" toplevel="" commit="" changes="" REPLY=""
  local -i probe_rc=0
  reply=()
  [[ "$root" == /* && ( -d "$root/.git" || -f "$root/.git" ) ]] \
    && (( ${+functions[_zdx_probe_resolve]} && ${+functions[_zdx_probe_tool]} \
      && ${+functions[_zdx_probe_clt_placeholder]} )) || return 1
  _zdx_probe_resolve git || return 1
  git_path="$REPLY"
  _zdx_probe_clt_placeholder git "$git_path" || probe_rc=$?
  case "$probe_rc" in
    1) ;;
    0) return 1 ;;
    124|125|130|143) return $probe_rc ;;
    *) return 125 ;;
  esac
  _zdx_probe_resolve env || return 1
  env_path="$REPLY"
  local -a git_run=(
    "$env_path" -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE GIT_OPTIONAL_LOCKS=0
    "$git_path" -C "$root"
  )
  probe_rc=0
  toplevel=$(_zdx_probe_tool 3 "${git_run[@]}" rev-parse --show-toplevel) \
    || probe_rc=$?
  (( probe_rc == 0 )) || return $probe_rc
  [[ -n "$toplevel" && "${toplevel:A}" == "${root:A}" ]] || return 1
  commit=$(_zdx_probe_tool 3 "${git_run[@]}" \
    rev-parse --short=7 --verify 'HEAD^{commit}') || probe_rc=$?
  (( probe_rc == 0 )) || return $probe_rc
  [[ "$commit" =~ '^[0-9a-f]{7,40}$' ]] || return 1
  changes=$(_zdx_probe_tool 5 "${git_run[@]}" -c core.fsmonitor=false \
    status --porcelain --untracked-files=no) || probe_rc=$?
  (( probe_rc == 0 )) || return $probe_rc
  reply=("$commit" "${changes:+modified}")
}

typeset -g _ZDX_VERSION_SOURCED=1
