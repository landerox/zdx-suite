#!/usr/bin/env zsh
# =============================================================================
# System Clean: cleanup of caches, logs and temporary system data
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-common.zsh, sys-capabilities.zsh, and the
# platform adapters.
# Safe to re-source; defines functions and the suite root it protects.
#

if [[ -n "${_SYS_CLEAN_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# The suite root that cleanup never removes, from this file's location in
# functions/sys/. It stands in for the core's root in a standalone suite.
typeset -g _SYS_CLEAN_SUITE_ROOT="${${(%):-%x}:A:h:h:h}"

# =============================================================================
# CLEAN STEPS (internal helpers)
# =============================================================================

# REPLY: <path> for display, with a leading home directory shown as ~.
# Usage: _sys_clean_display_path <path>
_sys_clean_display_path() {
  local path_text="${1:-}" home_abs="${HOME:A}"
  if [[ -n "$HOME" && "$HOME" != / && "$path_text" == "$HOME"/* ]]; then
    path_text="~/${path_text#"$HOME"/}"
  elif [[ "$home_abs" != / && "$path_text" == "$home_abs"/* ]]; then
    path_text="~/${path_text#"$home_abs"/}"
  fi
  REPLY="$path_text"
}

# True when <dir> is itself a Git directory, as a bare repository or a .git
# directory is: it has the HEAD, objects/, and refs/ entries Git checks for.
# Usage: _sys_clean_is_git_dir <dir>
_sys_clean_is_git_dir() {
  local dir="${1:-}"
  [[ ( -e "$dir/HEAD" || -L "$dir/HEAD" ) && -d "$dir/objects" \
    && -d "$dir/refs" ]]
}

# reply: the canonical directories of the Git repository that contains the
# working directory, empty outside one. The nearest directory at or above it
# that holds a .git entry or is itself a Git directory, as a bare repository
# is, always counts. The bounded Git reader adds the Git directory and the
# work tree top level it reports, which a planted core.worktree can move
# elsewhere. Git is not run outside a repository, and a failed probe keeps
# the directory found on disk. rev-parse reads no index, so no fsmonitor or
# other configured command runs.
_sys_clean_repository_roots() {
  local directory="${PWD:A}" answer="" line
  reply=()
  until [[ -e "$directory/.git" || -L "$directory/.git" ]] \
    || _sys_clean_is_git_dir "$directory"; do
    [[ "$directory" == / ]] && return 0
    directory="${directory:h}"
  done
  if (( ${+functions[_sys_update_git_read]} )) && _sys_tool_available git; then
    answer=$(_sys_update_git_read -C "${PWD:A}" rev-parse --absolute-git-dir \
      --show-toplevel </dev/null 2>/dev/null) || answer=""
  fi
  reply=("$directory")
  for line in "${(@f)answer}"; do
    [[ "$line" == /* && "$line" != *[[:cntrl:]]* ]] && reply+=("${line:A}")
  done
  reply=("${(@u)reply}")
  return 0
}

# reply: "<label>|<root>" records of the canonical directories that no
# cleanup target may be or contain: the suite root, both the core's and this
# suite's own, and the top levels of the repository that contains the
# working directory.
_sys_clean_resolve_protected_roots() {
  local root
  local -a roots=() repository_roots=()
  [[ -n "${_ZDX_FUNCTIONS_DIR:-}" ]] \
    && roots+=("the ZDX suite|${_ZDX_FUNCTIONS_DIR:h:A}")
  [[ -n "${_SYS_CLEAN_SUITE_ROOT:-}" ]] \
    && roots+=("the ZDX suite|${_SYS_CLEAN_SUITE_ROOT:A}")
  _sys_clean_repository_roots
  repository_roots=("${reply[@]}")
  for root in "${repository_roots[@]}"; do
    roots+=("the current repository|$root")
  done
  reply=("${(@u)roots}")
}

# reply: the protected-root records of this cleanup run, which
# _sys_clean_system_main resolves once before any probe; a direct call
# resolves them now.
_sys_clean_protected_roots() {
  if (( ${_sys_clean_protected_ready:-0} )); then
    reply=("${_sys_clean_protected_cache[@]}")
  else
    _sys_clean_resolve_protected_roots
  fi
}

# REPLY: the canonical <path> when it may be a cleanup target: an absolute
# path below HOME, never HOME itself, that crosses no symbolic link, is not
# and does not contain a protected root (_sys_clean_protected_roots), and is
# a user-owned directory when it exists. A refusal prints an error and
# returns 1; with --quiet it prints nothing and REPLY holds the displayed
# path and the reason, for the caller's single warning.
# Usage: _sys_clean_validate_user_path [--quiet] <path>
_sys_clean_validate_user_path() {
  local -i quiet=0
  [[ "${1:-}" == --quiet ]] && { quiet=1; shift; }
  local candidate="${1:-}"
  local home_abs="${HOME:A}"
  local current="$HOME"
  local relative_path target record root shown
  local -a reply=()

  [[ "$candidate" == /* && "$candidate" != *$'\n'* \
    && "$candidate" != *$'\r'* && "$candidate" != *$'\t'* \
    && "$candidate" != *'|'* ]] || {
    _sys_clean_path_refused $quiet "$candidate" \
      "Cleanup target is not a safe absolute path." \
      "is not a safe absolute path."
    return 1
  }
  [[ "${candidate:A}" == "$home_abs"/* \
    && "${candidate:A}" != "$home_abs" ]] || {
    _sys_clean_path_refused $quiet "$candidate" \
      "Cleanup target is outside the protected user boundary." \
      "is outside the protected user boundary."
    return 1
  }
  target="${candidate:A}"
  _sys_clean_protected_roots
  for record in "${reply[@]}"; do
    root="${record#*|}"
    [[ -n "$root" ]] \
      && [[ "$target" == "$root" || "$root" == "$target"/* ]] || continue
    _sys_clean_display_path "$target"
    shown="$REPLY"
    _sys_clean_path_refused $quiet "$target" \
      "Cleanup target $shown is or contains ${record%%|*}." \
      "is or contains ${record%%|*}."
    return 1
  done

  relative_path="${candidate#$HOME/}"
  local component
  for component in "${(@s:/:)relative_path}"; do
    current+="/$component"
    [[ ! -L "$current" ]] || {
      _sys_clean_path_refused $quiet "$candidate" \
        "Cleanup target crosses a symbolic link." \
        "crosses a symbolic link."
      return 1
    }
  done
  if [[ -e "$candidate" ]]; then
    [[ -d "$candidate" && ! -L "$candidate" && -O "$candidate" ]] || {
      _sys_clean_path_refused $quiet "$candidate" \
        "Cleanup target must be a user-owned directory." \
        "is not a user-owned directory."
      return 1
    }
  fi
  REPLY="${candidate:A}"
}

# Reports one refused cleanup target: <error> as an error, or with <quiet> 1
# nothing, leaving REPLY as the displayed <path> followed by <reason>.
# Usage: _sys_clean_path_refused <quiet> <path> <error> <reason>
_sys_clean_path_refused() {
  if (( ${1:-0} )); then
    _sys_clean_display_path "${2:-}"
    REPLY+=" ${4:-}"
  else
    _sys_error "${3:-}"
  fi
}

# Prints the validated form of <dir> (_sys_clean_validate_user_path). Status 1
# after the validator's error; with --quiet, status 3 and the refusal reason
# printed instead, so the plan can warn once.
# Usage: _sys_clean_print_validated [--quiet] <dir>
_sys_clean_print_validated() {
  local REPLY
  if [[ "${1:-}" == --quiet ]]; then
    _sys_clean_validate_user_path --quiet "${2:-}" || {
      print -r -- "$REPLY"
      return 3
    }
  else
    _sys_clean_validate_user_path "${1:-}" || return 1
  fi
  print -r -- "$REPLY"
}

# Runs one command from the root directory in a subshell, so a cache probe or
# purge never loads code or settings from the caller's working directory;
# python3 -m, for example, puts that directory first on sys.path. The command
# may be a shell function, such as the timeout service. The caller's shell
# keeps its directory. Status: the command's, or 1 when / cannot be entered.
# Usage: _sys_clean_in_neutral_dir <command> [args...]
_sys_clean_in_neutral_dir() {
  (
    builtin cd -q -- / || exit 1
    "$@"
  )
}

# The npm, uv, and Go probes and cleans run through _sys_clean_in_neutral_dir,
# so a project .npmrc, uv.toml, [tool.uv] table, or go.mod in the working
# directory never chooses a target; the user's own configuration and
# environment still apply. Each probe prints its validated directory, with
# status 1 when it fails or, after the validator's error, when the directory
# is refused; with --quiet a refusal prints its reason and returns 3.
# Usage: _sys_clean_npm_cache_dir [--quiet]
_sys_clean_npm_cache_dir() {
  local cache_dir
  cache_dir=$(_sys_clean_in_neutral_dir _sys_run_with_timeout 5 \
    npm config get cache 2>/dev/null) || return 1
  _sys_clean_print_validated "$@" "$cache_dir"
}

# Usage: _sys_clean_uv_cache_dir [--quiet]
_sys_clean_uv_cache_dir() {
  local cache_dir
  cache_dir=$(_sys_clean_in_neutral_dir _sys_run_with_timeout 5 \
    uv cache dir 2>/dev/null) || return 1
  _sys_clean_print_validated "$@" "$cache_dir"
}

# True when <dir> is a uv cache root: uv's default
# ${XDG_CACHE_HOME:-~/.cache}/uv, or a directory holding the CACHEDIR.TAG that
# uv writes, a regular file of at most 4096 bytes that starts with the
# 43-byte signature of the Cache Directory Tagging Specification.
# Usage: _sys_clean_uv_cache_layout <dir>
_sys_clean_uv_cache_layout() {
  local dir="${1:-}" cache_home="${XDG_CACHE_HOME:-}" default_dir tag
  local signature=""
  local -A tag_state=() read_state=()
  [[ "$dir" == /* ]] || return 1
  # uv, like the XDG specification, ignores a relative XDG_CACHE_HOME.
  [[ "$cache_home" == /* ]] || cache_home="$HOME/.cache"
  default_dir="$cache_home/uv"
  [[ "${dir:A}" == "${default_dir:A}" ]] && return 0
  tag="$dir/CACHEDIR.TAG"
  [[ -f "$tag" && ! -L "$tag" && -r "$tag" ]] || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -L -H tag_state -- "$tag" 2>/dev/null || return 1
  (( tag_state[size] <= 4096 )) || return 1
  # The name can be swapped for a FIFO after these checks, so the read is
  # bounded in time and size, and the file must still be the one checked.
  signature=$(_sys_run_bounded_probe 2 64 head -c 43 -- "$tag" \
    </dev/null 2>/dev/null) || return 1
  zstat -L -H read_state -- "$tag" 2>/dev/null || return 1
  [[ -f "$tag" && ! -L "$tag" \
    && "${read_state[device]}:${read_state[inode]}" \
      == "${tag_state[device]}:${tag_state[inode]}" ]] || return 1
  [[ "$signature" == "Signature: 8a477f597d28d172789f06886806bc55" ]]
}

# True when <dir> has the Go module cache layout: a cache/download directory
# that no symbolic link reaches.
# Usage: _sys_clean_go_cache_layout <dir>
_sys_clean_go_cache_layout() {
  local dir="${1:-}"
  [[ "$dir" == /* && -d "$dir/cache" && ! -L "$dir/cache" \
    && -d "$dir/cache/download" && ! -L "$dir/cache/download" ]]
}

# reply: the argv of the pip whose cache the cleanup manages: pip, then pip3,
# which is all that Homebrew Python provides, then python3 -m pip when that
# module answers a bounded --version probe. REPLY: its display form. Every
# pip runs through _sys_clean_in_neutral_dir, and the module form also with
# PYTHONSAFEPATH=1, which Python 3.11 and later honor, so a pip.py or pip/
# package in the working directory is never imported. The module form keeps
# the user site, where it may be the only pip, so it never runs with -I.
# Status 1 when none is usable.
_sys_clean_pip_command() {
  reply=()
  REPLY=""
  local pip_tool
  # env, not command, leads the module form: the timeout service executes its
  # argv directly, so command would not be found.
  local -a module_form=(env PYTHONSAFEPATH=1 python3 -m pip)
  for pip_tool in pip pip3; do
    if _sys_tool_available "$pip_tool"; then
      reply=("$pip_tool")
      REPLY="$pip_tool"
      return 0
    fi
  done
  _sys_tool_available python3 \
    && _sys_clean_in_neutral_dir _sys_run_with_timeout 5 \
      "${module_form[@]}" --version </dev/null >/dev/null 2>&1 || return 1
  reply=("${module_form[@]}")
  REPLY="python3 -m pip"
}

_sys_clean_pip_cache_dir() {
  local REPLY
  local -a reply=()
  local cache_dir
  _sys_clean_pip_command || return 1
  cache_dir=$(_sys_clean_in_neutral_dir _sys_run_with_timeout 5 \
    "${reply[@]}" cache dir </dev/null 2>/dev/null) || return 1
  _sys_clean_validate_user_path "$cache_dir" || return 1
  print -r -- "$REPLY"
}

# GOTOOLCHAIN=local keeps every Go probe and clean on the installed
# toolchain: a toolchain line can never make cleanup download or switch one.
# Usage: _sys_clean_go_cache_dir [--quiet]
_sys_clean_go_cache_dir() {
  local cache_dir
  cache_dir=$(_sys_clean_in_neutral_dir _sys_run_with_timeout 5 \
    env GOTOOLCHAIN=local go env GOMODCACHE 2>/dev/null) || return 1
  _sys_clean_print_validated "$@" "$cache_dir"
}

# The pre-commit cache follows PRE_COMMIT_HOME, then XDG_CACHE_HOME, as
# pre-commit itself does.
_sys_clean_precommit_cache_dir() {
  local REPLY
  _sys_clean_validate_user_path \
    "${PRE_COMMIT_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/pre-commit}" \
    || return 1
  print -r -- "$REPLY"
}

# --- Superseded tool versions ------------------------------------------------
# Self-updating CLIs, the AWS CLI v2 bundled installer, and nvm keep one
# directory or file per installed version. The plan record of such a target is
# "<label>|<root>|<names>": its validated root and the space-separated
# superseded entries below it. Execution removes only planned names that are
# still superseded when the step runs.

# True when <name> is a relative path of plain components: no whitespace,
# control character, "|", or "." or ".." component.
# Usage: _sys_clean_plain_relative_path <name>
_sys_clean_plain_relative_path() {
  local name="${1:-}" component
  [[ -n "$name" && "$name" != /* \
    && "$name" != *[[:space:][:cntrl:]\|]* ]] || return 1
  for component in "${(@s:/:)name}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. ]] \
      || return 1
  done
}

# True when /proc exposes each process's executable, as on Linux.
_sys_clean_proc_exe_available() {
  [[ -d /proc/self && -L /proc/self/exe ]]
}

# reply: the executables and mapped program files of this user's running
# processes: /proc/<pid>/exe where /proc provides it, otherwise each
# process's text files from a bounded lsof. Status 1 when neither source
# answers, so a caller cannot tell whether a version is in use.
_sys_clean_running_executables() {
  emulate -L zsh
  local exe line output lsof_program
  local -a link=()
  local -i lsof_rc=0
  reply=()
  if _sys_clean_proc_exe_available; then
    zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
    for exe in /proc/<->/exe(N@); do
      link=()
      zstat -L -A link +link -- "$exe" 2>/dev/null || continue
      [[ "${link[1]:-}" == /* ]] && reply+=("${link[1]% (deleted)}")
    done
    return 0
  fi
  lsof_program=$(builtin whence -p lsof 2>/dev/null) || return 1
  output=$(_sys_run_with_timeout 15 "$lsof_program" -nP -w -a \
    -u "$EUID" -d txt -F n </dev/null 2>/dev/null) || lsof_rc=$?
  (( lsof_rc != 124 )) || return 1
  for line in "${(@f)output}"; do
    [[ "$line" == n/* ]] && reply+=("${line#n}")
  done
  # lsof also reports a partial answer with a non-zero status. This shell's
  # own program is always listed, so an empty answer means lsof saw nothing.
  (( ${#reply} > 0 ))
}

# REPLY: the root directory of one release target. reply: its stores as
# "<store>|<pointer>[|<pointer>...]" records. Codex keeps one store per
# package below ${CODEX_HOME:-~/.codex}/packages, selected by its current
# link; Cursor Agent and Claude CLI each keep one store, selected by their
# ~/.local/bin launchers.
# Usage: _sys_clean_release_layout <label>
_sys_clean_release_layout() {
  local package
  REPLY=""
  reply=()
  case "${1:-}" in
    "Codex releases")
      REPLY="${CODEX_HOME:-$HOME/.codex}/packages"
      for package in "$REPLY"/*(N/); do
        reply+=("$package/releases|$package/current")
      done
      ;;
    "Cursor Agent versions")
      REPLY="$HOME/.local/share/cursor-agent/versions"
      reply=("$REPLY|$HOME/.local/bin/cursor-agent|$HOME/.local/bin/agent")
      ;;
    "Claude CLI versions")
      REPLY="$HOME/.local/share/claude/versions"
      reply=("$REPLY|$HOME/.local/bin/claude")
      ;;
    *) return 2 ;;
  esac
}

# reply: the Claude CLI versions that a live process holds through the native
# installer's lock files, <state>/claude/locks/<version>.lock, each a small
# JSON record whose "pid" names the holder. A lock that is not a small regular
# file or has no readable PID keeps its version; a lock whose process has
# exited is ignored.
_sys_clean_claude_locked_versions() {
  emulate -L zsh
  local lock_dir lock_file content MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=() readable=()
  local -aU lock_dirs=(
    "${XDG_STATE_HOME:-$HOME/.local/state}/claude/locks"
    "$HOME/.local/state/claude/locks"
  )
  reply=()
  for lock_dir in "${lock_dirs[@]}"; do
    readable=("$lock_dir"/*.lock(N.Lk-64))
    for lock_file in "$lock_dir"/*.lock(N); do
      content=""
      (( ${readable[(Ie)$lock_file]} )) && [[ -r "$lock_file" ]] \
        && content="$(<"$lock_file")"
      if [[ "$content" =~ '"pid"[[:space:]]*:[[:space:]]*([0-9]+)' ]]; then
        builtin kill -0 "${match[1]}" 2>/dev/null || continue
      fi
      reply+=("${${lock_file:t}%.lock}")
    done
  done
}

# reply: the superseded entries of one release store, as absolute paths,
# oldest first. An entry is a direct child whose name starts with a digit.
# Ordered by modification time, the store keeps every entry a pointer
# selects, every newer entry, which an updater may still be installing, the
# newest older entry as the previous release, each protected name, and any
# entry that holds a running executable. REPLY: the selected entry. Status 1
# when no pointer selects an entry, and 3 when an older entry exists but
# running executables cannot be determined; nothing is removable then.
# Usage: _sys_clean_release_candidates <store> <pointer>... [-- <protected>...]
_sys_clean_release_candidates() {
  emulate -L zsh
  local store="${1:-}" pointer target name entry running
  local -A selected=() protected=()
  local -a pointers=() older=() running_executables=()
  local -i seen_selected=0 kept_previous=0
  shift
  while (( $# )) && [[ "$1" != -- ]]; do
    pointers+=("$1")
    shift
  done
  (( $# )) && shift
  for name in "$@"; do
    protected[$name]=1
  done
  reply=()
  REPLY=""
  [[ "$store" == /* && -d "$store" && ! -L "$store" ]] || return 1
  store="${store:A}"
  for pointer in "${pointers[@]}"; do
    [[ -L "$pointer" ]] || continue
    target="${pointer:A}"
    [[ "$target" == "$store"/?* ]] || continue
    name="${${target#"$store"/}%%/*}"
    [[ "$name" == [0-9]* && -e "$store/$name" && ! -L "$store/$name" ]] \
      || continue
    selected[$name]=1
    [[ -n "$REPLY" ]] || REPLY="$name"
  done
  (( ${#selected} > 0 )) || return 1

  for entry in "$store"/[0-9]*(Nom); do
    name="${entry:t}"
    if (( ${+selected[$name]} )); then
      seen_selected=1
      continue
    fi
    (( seen_selected )) && [[ ! -L "$entry" ]] || continue
    if (( ! kept_previous )); then
      kept_previous=1
      continue
    fi
    (( ${+protected[$name]} )) || older+=("$entry")
  done
  (( ${#older} > 0 )) || return 0

  _sys_clean_running_executables || return 3
  running_executables=("${reply[@]}")
  reply=()
  for entry in "${(@Oa)older}"; do
    for running in "${running_executables[@]}"; do
      [[ "$running" == "$entry" || "$running" == "$entry"/* ]] && continue 2
    done
    reply+=("$entry")
  done
  return 0
}

# reply: the superseded entries of every store of one release target, as
# absolute paths; REPLY: its validated root. A store whose selected release
# cannot be determined, or whose running programs cannot be inspected,
# contributes nothing and is named in a warning. Status 1 when the root is
# absent, or unsafe after a warning.
# Usage: _sys_clean_release_targets <label>
_sys_clean_release_targets() {
  local label="${1:-}" root record store
  local -a stores=() targets=() pointers=() entries=() protected=()
  local -i candidates_rc=0
  _sys_clean_release_layout "$label" || return 2
  root="$REPLY"
  stores=("${reply[@]}")
  [[ -d "$root" ]] || return 1
  _sys_clean_validate_user_path "$root" 2>/dev/null || {
    _sys_warn "Skipping $label: $(_sys_display_escape "${root/#$HOME/~}") is not a safe user-owned directory."
    return 1
  }
  root="$REPLY"
  if [[ "$label" == "Claude CLI versions" ]]; then
    _sys_clean_claude_locked_versions
    protected=("${reply[@]}")
  fi
  for record in "${stores[@]}"; do
    store="${record%%|*}"
    pointers=("${(@s:|:)${record#*|}}")
    [[ -d "$store" ]] || continue
    _sys_clean_validate_user_path "$store" 2>/dev/null || {
      _sys_warn "Skipping $(_sys_display_escape "${store/#$HOME/~}"): not a safe user-owned directory."
      continue
    }
    store="$REPLY"
    candidates_rc=0
    _sys_clean_release_candidates "$store" "${pointers[@]}" \
      -- "${protected[@]}" || candidates_rc=$?
    case $candidates_rc in
      0) targets+=("${reply[@]}") ;;
      3)
        _sys_warn "Skipping $(_sys_display_escape "${store/#$HOME/~}"): running programs cannot be inspected on this host."
        ;;
      *)
        entries=("$store"/[0-9]*(N))
        (( ${#entries} > 1 )) && _sys_warn \
          "Skipping $(_sys_display_escape "${store/#$HOME/~}"): its active release could not be determined."
        ;;
    esac
  done
  REPLY="$root"
  reply=("${targets[@]}")
}

# True when every directory from / down to <dir> is a real directory that
# group and other users cannot write, owned by root or by <owner-uid>. With
# owner 0, as for a privileged removal, every component must be root's, so no
# other account can swap the path between the check and its use.
# Usage: _sys_clean_trusted_directory_chain <dir> <owner-uid>
_sys_clean_trusted_directory_chain() {
  emulate -L zsh
  local directory="${1:-}" owner="${2:-}" cursor="" component
  local -a cursors=(/)
  local -A state=()
  [[ "$directory" == /* && "$owner" == <-> ]] || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  for component in "${(@s:/:)directory}"; do
    [[ -n "$component" ]] || continue
    cursor+="/$component"
    cursors+=("$cursor")
  done
  for cursor in "${cursors[@]}"; do
    [[ -d "$cursor" && ! -L "$cursor" ]] || return 1
    state=()
    zstat -H state -- "$cursor" 2>/dev/null || return 1
    (( (state[mode] & 8#22) == 0 \
      && (state[uid] == 0 || state[uid] == owner) )) || return 1
  done
}

# REPLY: the AWS CLI v2 directory (<install-dir>/v2) of the active aws when it
# uses the bundled installer's layout: aws resolves to
# <v2>/<version>/dist/aws, and the <v2>/current link selects that same version
# directory, where current/dist/aws exists. Root or the current user owns the
# directory, and its whole directory chain passes
# _sys_clean_trusted_directory_chain for that owner. reply=(<version>
# <owner-uid>). Status 1 for any other installation, such as Homebrew's.
_sys_clean_awscli_root() {
  emulate -L zsh
  local program resolved version_dir v2_root current_link
  local -A root_state=()
  _sys_tool_program aws || return 1
  program="$REPLY"
  REPLY=""
  reply=()
  resolved="${program:A}"
  [[ "$resolved" == /?*/v2/2.<->.<->/dist/aws ]] || return 1
  version_dir="${resolved%/dist/aws}"
  v2_root="${version_dir:h}"
  current_link="$v2_root/current"
  [[ -L "$current_link" && "${current_link:A}" == "$version_dir" \
    && -f "$current_link/dist/aws" ]] || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -H root_state -- "$v2_root" 2>/dev/null || return 1
  (( root_state[uid] == 0 || root_state[uid] == EUID )) || return 1
  _sys_clean_trusted_directory_chain "$v2_root" "${root_state[uid]}" \
    || return 1
  REPLY="$v2_root"
  reply=("${version_dir:t}" "${root_state[uid]}")
}

# reply: the superseded bundle versions of an AWS CLI v2 directory, as
# absolute paths: every 2.x.y directory except the active one and any that
# holds a running executable. Status 1 when one of them is not owned like the
# v2 directory, so nothing may be removed, and 3 when running executables
# cannot be determined.
# Usage: _sys_clean_awscli_superseded <v2-dir> <version> <owner-uid>
_sys_clean_awscli_superseded() {
  emulate -L zsh
  local v2_root="${1:-}" version="${2:-}" owner="${3:-}" entry running
  local -a candidates=() running_executables=()
  local -A entry_state=()
  reply=()
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  for entry in "$v2_root"/2.<->.<->(Nn/); do
    [[ "${entry:t}" != "$version" && ! -L "$entry" ]] || continue
    entry_state=()
    zstat -H entry_state -- "$entry" 2>/dev/null || return 1
    [[ "${entry_state[uid]}" == "$owner" ]] || return 1
    candidates+=("$entry")
  done
  (( ${#candidates} > 0 )) || return 0
  _sys_clean_running_executables || return 3
  running_executables=("${reply[@]}")
  reply=()
  for entry in "${candidates[@]}"; do
    for running in "${running_executables[@]}"; do
      [[ "$running" == "$entry"/* ]] && continue 2
    done
    reply+=("$entry")
  done
}

# True when version <a> is older than version <b>; both are vX.Y.Z.
# Usage: _sys_clean_nvm_version_older <a> <b>
_sys_clean_nvm_version_older() {
  local -a older=("${(@s:.:)${1#v}}") newer=("${(@s:.:)${2#v}}")
  local -i index
  for index in 1 2 3; do
    (( older[index] < newer[index] )) && return 0
    (( older[index] > newer[index] )) && return 1
  done
  return 1
}

# True when a dotted number in <pin> is a version prefix of <version> but not
# of <replacement>: "24.21" or "v24.21.0" select v24.21.0 and not v24.22.0,
# while "24" selects both.
# Usage: _sys_nvm_pin_selects <version> <replacement> <pin>
_sys_nvm_pin_selects() {
  emulate -L zsh
  local version="${${1:-}#v}." replacement="${${2:-}#v}." pin="${3:-}"
  local token MATCH MBEGIN MEND
  local -a match=() mbegin=() mend=()
  while [[ "$pin" =~ '[0-9]+([.][0-9]+){0,2}' ]]; do
    token="$MATCH."
    pin="${pin[MEND+1,-1]}"
    [[ "$version" == "$token"* && "$replacement" != "$token"* ]] && return 0
  done
  return 1
}

# True when a project in the workspace layout pins <version> in a way that
# <replacement> does not satisfy. Pins are read from .nvmrc and .node-version
# files and package.json "node" entries, such as engines, in each repository
# directly below $WS_BASE_DIR/<platform>/<identity>/. Every dotted number in
# a pin counts as a version prefix, so a range keeps a runtime that the
# replacement might already satisfy rather than risk removing one a project
# needs. Projects outside that layout are not inspected. REPLY: the pinning
# file.
# Usage: _sys_nvm_pinned_by_project <version> <replacement>
_sys_nvm_pinned_by_project() {
  emulate -L zsh
  local version="${1:-}" replacement="${2:-}"
  local base="${WS_BASE_DIR-${HOME:A}/workspaces}" name file line
  local -a lines=()
  REPLY=""
  [[ "$version" == v<->.<->.<-> && "$base" == /* && -d "$base" ]] || return 1
  for name in .nvmrc .node-version package.json; do
    # Bounded discovery: the layout's repository depth and files below 1 MiB.
    for file in "$base"/*/*/*/"$name"(N.Lk-1024); do
      [[ -r "$file" ]] || continue
      lines=("${(@f)$(<"$file")}")
      for line in "${lines[@]}"; do
        [[ "$name" != package.json || "$line" == *'"node"'* ]] || continue
        if _sys_nvm_pin_selects "$version" "$replacement" "$line"; then
          REPLY="$file"
          return 0
        fi
      done
    done
  done
  return 1
}

# REPLY: the version that nvm selects as its default (vX.Y.Z): the exact
# version in <nvm-dir>/alias/default, or otherwise nvm's own resolution of
# that alias when the nvm function is loaded. Status 1 when it cannot be
# determined or is not installed.
# Usage: _sys_clean_nvm_default_version <nvm-dir>
_sys_clean_nvm_default_version() {
  emulate -L zsh
  local nvm_dir="${1:-}" alias_file alias_value resolved=""
  REPLY=""
  alias_file="$nvm_dir/alias/default"
  [[ -f "$alias_file" && ! -L "$alias_file" && -r "$alias_file" ]] \
    || return 1
  alias_value="$(<"$alias_file")"
  alias_value="${alias_value%%$'\n'*}"
  if [[ "$alias_value" == v<->.<->.<-> ]]; then
    resolved="$alias_value"
  elif (( ${+functions[nvm]} )); then
    resolved=$(nvm version default </dev/null 2>/dev/null) || return 1
  fi
  [[ "$resolved" == v<->.<->.<-> \
    && -d "$nvm_dir/versions/node/$resolved" ]] || return 1
  REPLY="$resolved"
}

# reply: the superseded nvm runtimes below <versions-root>, as vX.Y.Z names:
# each installed runtime older than the default on the default's major line
# that no nvm alias or workspace project selects, that this shell's PATH does
# not use, that runs no process, and whose global npm packages the default
# runtime already holds. Other release lines and newer runtimes stay. REPLY:
# the default version. Status 1 when the default cannot be determined, and 3
# when running executables cannot be determined.
# Usage: _sys_clean_nvm_candidates <nvm-dir> <versions-root>
_sys_clean_nvm_candidates() {
  emulate -L zsh
  local nvm_dir="${1:-}" root="${2:-}" default_version entry version
  local alias_file alias_target running
  local -a candidates=() default_packages=() packages=() missing=()
  local -a running_executables=()
  reply=()
  _sys_clean_nvm_default_version "$nvm_dir" || return 1
  default_version="$REPLY"
  _sys_nvm_global_packages "$root/$default_version" || return 1
  default_packages=("${reply[@]}")
  for entry in "$root"/v<->.<->.<->(Nn/); do
    version="${entry:t}"
    [[ ! -L "$entry" && -O "$entry" ]] || continue
    [[ "${${version#v}%%.*}" == "${${default_version#v}%%.*}" ]] || continue
    _sys_clean_nvm_version_older "$version" "$default_version" || continue
    for alias_file in "$nvm_dir"/alias/*(N.); do
      [[ "${alias_file:t}" != default && -r "$alias_file" ]] || continue
      alias_target="$(<"$alias_file")"
      if _sys_nvm_pin_selects "$version" "$default_version" \
        "${alias_target%%$'\n'*}"; then
        _sys_verbose_dim "Keeping $version: the nvm alias $(_sys_display_escape "${alias_file:t}") selects it."
        continue 2
      fi
    done
    if _sys_nvm_pinned_by_project "$version" "$default_version"; then
      _sys_verbose_dim "Keeping $version: pinned by $(_sys_display_escape "${REPLY/#$HOME/~}")."
      continue
    fi
    if (( ${path[(Ie)$root/$version/bin]} \
      || ${path[(Ie)$nvm_dir/versions/node/$version/bin]} )); then
      _sys_verbose_dim "Keeping $version: this shell's PATH uses it."
      continue
    fi
    _sys_nvm_global_packages "$entry" || continue
    packages=("${reply[@]}")
    missing=("${(@)packages:|default_packages}")
    if (( ${#missing} > 0 )); then
      _sys_verbose_dim "Keeping $version: $default_version lacks its global packages (${(j:, :)${(@V)missing[1,5]}})."
      continue
    fi
    candidates+=("$version")
  done
  REPLY="$default_version"
  reply=()
  (( ${#candidates} > 0 )) || return 0
  _sys_clean_running_executables || return 3
  running_executables=("${reply[@]}")
  reply=()
  for version in "${candidates[@]}"; do
    for running in "${running_executables[@]}"; do
      [[ "$running" == "$root/$version"/* ]] && continue 2
    done
    reply+=("$version")
  done
  REPLY="$default_version"
}

# REPLY: the validated nvm runtime root, ${NVM_DIR:-~/.nvm}/versions/node;
# reply: its superseded runtimes (see _sys_clean_nvm_candidates). Status 1
# when nvm is absent, and also after a warning when the root is unsafe or
# the running programs cannot be inspected.
_sys_clean_nvm_targets() {
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}" root
  local -i candidates_rc=0
  reply=()
  REPLY=""
  root="$nvm_dir/versions/node"
  [[ -d "$root" ]] || return 1
  _sys_clean_validate_user_path "$root" 2>/dev/null || {
    _sys_warn "Skipping Node.js runtimes: $(_sys_display_escape "${root/#$HOME/~}") is not a safe user-owned directory."
    return 1
  }
  root="$REPLY"
  _sys_clean_nvm_candidates "$nvm_dir" "$root" || candidates_rc=$?
  case $candidates_rc in
    0) ;;
    3)
      _sys_warn "Skipping Node.js runtimes: running programs cannot be inspected on this host."
      return 1
      ;;
    *)
      _sys_verbose_dim "Skipping Node.js runtimes: the nvm default version could not be determined."
      reply=()
      ;;
  esac
  REPLY="$root"
}

_sys_disabled_snap_revisions() {
  local output
  output=$(LC_ALL=C _sys_run_with_timeout 20 snap list --all 2>/dev/null)
  local rc=$?
  (( rc != 0 )) && return "$rc"
  # Only the Notes column marks a revision as disabled.
  print -r -- "$output" \
    | command awk '$NF ~ /(^|,)disabled(,|$)/ {print $1, $3}'
}

_sys_validate_disabled_snap_revisions() {
  local disabled_snaps="$1"
  [[ -n "$disabled_snaps" ]] || return 0

  local record name rev extra
  for record in "${(@f)disabled_snaps}"; do
    read -r name rev extra <<< "$record"
    [[ -z "$extra" && "$name" =~ '^[[:alnum:]][[:alnum:]._-]*$' \
      && "$rev" =~ '^[0-9]+$' ]] || {
      _sys_error "Invalid disabled Snap record; refusing the cleanup plan."
      return 1
    }
    print -r -- "$name $rev"
  done
}

_sys_remove_disabled_snap_revisions() {
  local disabled_snaps="$1"

  [[ -z "$disabled_snaps" ]] && return 0

  local -a privilege_prefix=()
  if (( EUID == 0 )); then
    privilege_prefix=()
  elif _sys_has_capability "privilege:sudo" \
    && command -v sudo &>/dev/null; then
    _sys_info "Privileged authentication: sudo -v"
    sudo -v >&2 || {
      _sys_error "sudo authentication failed; no Snap revision was removed."
      return 1
    }
    privilege_prefix=(sudo -n)
  else
    _sys_error "No supported privilege path is available."
    return 1
  fi
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  local -a snap_records=("${(@f)disabled_snaps}")
  local record name rev current_disabled current_record
  local -i failures=0
  for record in "${snap_records[@]}"; do
    read -r name rev <<< "$record"
    [[ "$name" =~ '^[[:alnum:]][[:alnum:]._-]*$' \
      && "$rev" =~ '^[0-9]+$' ]] || {
      _sys_error "Invalid disabled Snap record; refusing to remove it."
      (( failures++ ))
      continue
    }

    current_disabled=$(_sys_disabled_snap_revisions) || {
      _sys_error "Unable to revalidate $name revision $rev."
      (( failures++ ))
      continue
    }
    current_disabled=$(
      _sys_validate_disabled_snap_revisions "$current_disabled"
    ) || {
      (( failures++ ))
      continue
    }
    local -a current_records=()
    [[ -n "$current_disabled" ]] \
      && current_records=("${(@f)current_disabled}")
    local -i still_disabled=0
    for current_record in "${current_records[@]}"; do
      if [[ "$current_record" == "$record" ]]; then
        still_disabled=1
        break
      fi
    done
    if (( ! still_disabled )); then
      _sys_error \
        "$name revision $rev is no longer disabled; refusing to remove it."
      (( failures++ ))
      continue
    fi

    _sys_info "Removing $name rev $rev..."
    _sys_dim \
      "Privileged operation: ${privilege_label}snap remove $name --revision=$rev"
    "${privilege_prefix[@]}" \
      snap remove "$name" --revision="$rev" >&2 2>/dev/null || {
        _sys_error "Failed to remove $name revision $rev."
        (( failures++ ))
      }
  done
  (( failures == 0 ))
}

_sys_clean_step_apt_cache() {
  local -a reply=()
  _sys_has_capability "package:apt" || {
    _sys_report_not_applicable "APT cache cleanup" \
      "APT is not the active package manager"
    return
  }
  local -a privilege_prefix=()
  _sys_resolve_privilege_prefix || return 1
  privilege_prefix=("${reply[@]}")
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  _sys_dim "Privileged operation: ${privilege_label}apt-get clean"
  "${privilege_prefix[@]}" apt-get clean >&2
}

_sys_clean_step_homebrew() {
  if ! command -v brew &>/dev/null; then
    _sys_report_result skipped "not installed" \
      "Homebrew not installed, skipping."
    return 0
  fi

  _sys_dim "May take several minutes on large Homebrew installs."
  _sys_brew autoremove >&2 || return $?
  _sys_brew cleanup --prune=all >&2
}

_sys_clean_step_snap_revisions() {
  if ! command -v snap &>/dev/null; then
    _sys_info "Snap not installed, skipping."
    return 0
  fi

  if ! _sys_snap_ready; then
    _sys_warn "snapd is not available — skipping disabled snap cleanup."
    _sys_dim "This avoids hangs in WSL environments without a running snapd."
    return 0
  fi

  local disabled_snaps
  disabled_snaps=$(_sys_disabled_snap_revisions)
  local rc=$?
  if (( rc == 124 )); then
    _sys_warn "Timed out while listing disabled snap revisions."
    return 124
  elif (( rc != 0 )); then
    _sys_warn "Could not inspect disabled snap revisions."
    return 1
  fi
  disabled_snaps=$(_sys_validate_disabled_snap_revisions "$disabled_snaps") \
    || return 1

  if [[ -z "$disabled_snaps" ]]; then
    _sys_report_result current "no disabled revisions" \
      "No disabled snap revisions to remove."
    return 0
  fi

  _sys_dim "May take several minutes if many snap revisions are pending removal."
  _sys_remove_disabled_snap_revisions "$disabled_snaps" || return $?
  local REPLY
  _sys_count_noun "${#${(f)disabled_snaps}}" revision
  _sys_report_result done "$REPLY removed"
}

_sys_clean_step_npm_cache() {
  local REPLY
  if ! _sys_tool_available npm; then
    _sys_report_result skipped "not installed" "npm not installed, skipping."
    return 0
  fi

  local expected_cache="${1:-}"
  local cache_dir
  cache_dir=$(_sys_clean_npm_cache_dir) || return 1
  [[ -n "$expected_cache" && "$cache_dir" == "$expected_cache" ]] || {
    _sys_error "npm cache path changed after confirmation."
    return 1
  }
  _sys_clean_validate_user_path "$expected_cache" || return 1
  cache_dir="$REPLY"
  [[ -d "$cache_dir" ]] || {
    _sys_error "The confirmed npm cache directory is no longer available."
    return 1
  }
  _sys_run_logged "npm cache clean --force" _sys_clean_in_neutral_dir \
    command env npm_config_cache="$cache_dir" npm cache clean --force
}

_sys_clean_step_uv_cache() {
  local REPLY
  if ! command -v uv &>/dev/null; then
    _sys_report_result skipped "not installed" "uv not installed, skipping."
    return 0
  fi

  local expected_cache="${1:-}"
  local cache_dir
  cache_dir=$(_sys_clean_uv_cache_dir) || return 1
  [[ -n "$expected_cache" && "$cache_dir" == "$expected_cache" ]] || {
    _sys_error "uv cache path changed after confirmation."
    return 1
  }
  _sys_clean_validate_user_path "$expected_cache" || return 1
  cache_dir="$REPLY"
  [[ -d "$cache_dir" ]] || {
    _sys_error "The confirmed uv cache directory is no longer available."
    return 1
  }
  _sys_clean_uv_cache_layout "$cache_dir" || {
    _sys_error "The confirmed uv cache directory no longer has its CACHEDIR.TAG."
    return 1
  }
  _sys_run_logged "uv cache clean" _sys_clean_in_neutral_dir \
    command env UV_CACHE_DIR="$cache_dir" uv cache clean
}

_sys_clean_step_pip_cache() {
  local REPLY pip_display
  local -a reply=() pip_command=()
  if ! _sys_clean_pip_command; then
    _sys_report_result skipped "not installed" "pip not installed, skipping."
    return 0
  fi
  pip_command=("${reply[@]}")
  pip_display="$REPLY"

  local expected_cache="${1:-}"
  local cache_dir
  cache_dir=$(_sys_clean_pip_cache_dir) || return 1
  [[ -n "$expected_cache" && "$cache_dir" == "$expected_cache" ]] || {
    _sys_error "pip cache path changed after confirmation."
    return 1
  }
  _sys_clean_validate_user_path "$expected_cache" || return 1
  cache_dir="$REPLY"
  [[ -d "$cache_dir" ]] || {
    _sys_error "The confirmed pip cache directory is no longer available."
    return 1
  }
  _sys_run_logged "$pip_display cache purge" _sys_clean_in_neutral_dir \
    command env PIP_CACHE_DIR="$cache_dir" "${pip_command[@]}" cache purge
}

_sys_clean_step_precommit_cache() {
  local REPLY
  if ! _sys_tool_available pre-commit; then
    _sys_report_result skipped "not installed" \
      "pre-commit not installed, skipping."
    return 0
  fi

  local expected_cache="${1:-}"
  local cache_dir
  cache_dir=$(_sys_clean_precommit_cache_dir) || return 1
  [[ -n "$expected_cache" && "$cache_dir" == "$expected_cache" ]] || {
    _sys_error "pre-commit cache path changed after confirmation."
    return 1
  }
  _sys_clean_validate_user_path "$expected_cache" || return 1
  cache_dir="$REPLY"
  [[ -d "$cache_dir" ]] || {
    _sys_error "The confirmed pre-commit cache directory is no longer available."
    return 1
  }
  # gc removes only the hook repositories that no known config still uses.
  _sys_run_logged "pre-commit gc" \
    env PRE_COMMIT_HOME="$cache_dir" pre-commit gc
}

# REPLY: the root of a "<root>|<names>" scope; reply: its names. Status 1
# for a scope without a root, without names, or with a name that is not a
# plain relative path.
# Usage: _sys_clean_split_version_scope <scope>
_sys_clean_split_version_scope() {
  local scope="${1:-}" name
  REPLY="${scope%%|*}"
  reply=("${(@s: :)${scope#*|}}")
  [[ "$scope" == *"|"* && "$REPLY" == /* && -n "${scope#*|}" ]] || return 1
  for name in "${reply[@]}"; do
    _sys_clean_plain_relative_path "$name" || return 1
  done
}

# Removes the planned superseded entries of one release target. Each planned
# name must still be superseded below the confirmed root when the step runs:
# a name that is already gone, for example after the tool's own pruning, is
# skipped, and one that is no longer superseded is refused as a failure.
# Usage: _sys_clean_step_releases <label> <confirmed-root>|<names>
_sys_clean_step_releases() {
  local label="${1:-}" REPLY expected_root name target
  local -a reply=() names=() current=() removed=()
  local -i failures=0
  _sys_clean_split_version_scope "${2:-}" || {
    _sys_error "Invalid $label plan record."
    return 1
  }
  expected_root="$REPLY"
  names=("${reply[@]}")
  if ! _sys_clean_release_targets "$label"; then
    _sys_error "The confirmed $label directory is no longer available."
    return 1
  fi
  [[ "$REPLY" == "$expected_root" ]] || {
    _sys_error "$label path changed after confirmation."
    return 1
  }
  current=("${reply[@]}")

  for name in "${names[@]}"; do
    target="$expected_root/$name"
    [[ -e "$target" || -L "$target" ]] || continue
    if (( ! ${current[(Ie)$target]} )); then
      _sys_error "$(_sys_display_escape "$name") is no longer superseded; it was kept."
      (( ++failures ))
      continue
    fi
    if command rm -rf -- "$target"; then
      removed+=("${name:t}")
    else
      (( ++failures ))
    fi
  done
  (( ${#removed} > 0 )) \
    && _sys_dim "Removed: ${(j:, :)${(@V)removed}}"
  if (( failures > 0 )); then
    _sys_error "Some planned $label could not be removed."
    return 1
  fi
  if (( ${#removed} == 0 )); then
    _sys_report_result current "nothing left to remove" \
      "No planned $label remain to remove."
    return 0
  fi
  _sys_count_noun "${#removed}" "superseded version"
  _sys_report_result done "$REPLY removed" "$label: removed $REPLY."
}

_sys_clean_step_codex_releases() {
  _sys_clean_step_releases "Codex releases" "$@"
}

_sys_clean_step_cursor_versions() {
  _sys_clean_step_releases "Cursor Agent versions" "$@"
}

_sys_clean_step_claude_versions() {
  _sys_clean_step_releases "Claude CLI versions" "$@"
}

# Removes the planned superseded bundle versions of the confirmed AWS CLI v2
# directory, through the privilege prefix when root owns it. Planned versions
# follow the rules of _sys_clean_step_releases.
# Usage: _sys_clean_step_awscli_bundles <confirmed-v2-dir>|<versions>
_sys_clean_step_awscli_bundles() {
  local REPLY expected_root version owner name target
  local -a reply=() names=() current=() targets=() privilege_prefix=()
  local -i failures=0 superseded_rc=0
  _sys_clean_split_version_scope "${1:-}" || {
    _sys_error "Invalid AWS CLI bundles plan record."
    return 1
  }
  expected_root="$REPLY"
  names=("${reply[@]}")
  if ! _sys_clean_awscli_root; then
    _sys_error "The confirmed AWS CLI installation can no longer be verified."
    return 1
  fi
  [[ "$REPLY" == "$expected_root" ]] || {
    _sys_error "AWS CLI installation path changed after confirmation."
    return 1
  }
  version="${reply[1]}"
  owner="${reply[2]}"
  _sys_clean_awscli_superseded "$expected_root" "$version" "$owner" \
    || superseded_rc=$?
  case $superseded_rc in
    0) current=("${reply[@]}") ;;
    3)
      _sys_error "Running programs cannot be inspected; no AWS CLI bundle was removed."
      return 1
      ;;
    *)
      _sys_error "An AWS CLI bundle directory has an unexpected owner; nothing was removed."
      return 1
      ;;
  esac

  for name in "${names[@]}"; do
    target="$expected_root/$name"
    if [[ "$name" != 2.<->.<-> ]]; then
      _sys_error "Refusing an unexpected AWS CLI bundle name: $(_sys_display_escape "$name")"
      (( ++failures ))
      continue
    fi
    [[ -e "$target" || -L "$target" ]] || continue
    if (( ! ${current[(Ie)$target]} )); then
      _sys_error "AWS CLI $name is no longer superseded; it was kept."
      (( ++failures ))
      continue
    fi
    targets+=("$target")
  done

  if (( ${#targets} > 0 )); then
    if (( owner != EUID )); then
      _sys_resolve_privilege_prefix || return 1
      privilege_prefix=("${reply[@]}")
    fi
    if (( ${#privilege_prefix} > 0 )); then
      _sys_dim "Privileged operation: ${(j: :)privilege_prefix} rm -rf -- $(_sys_display_escape "${(j: :)targets}")"
      "${privilege_prefix[@]}" rm -rf -- "${targets[@]}" >&2
    else
      command rm -rf -- "${targets[@]}" >&2
    fi || (( ++failures ))
    for target in "${targets[@]}"; do
      [[ ! -e "$target" && ! -L "$target" ]] || {
        _sys_error "A superseded AWS CLI bundle version remains: $(_sys_display_escape "$target")"
        (( ++failures ))
      }
    done
  fi
  if (( failures > 0 )); then
    _sys_error "Some planned AWS CLI bundle versions could not be removed."
    return 1
  fi
  if (( ${#targets} == 0 )); then
    _sys_report_result current "nothing left to remove" \
      "No planned AWS CLI bundle versions remain to remove."
    return 0
  fi
  _sys_count_noun "${#targets}" "superseded version"
  _sys_report_result done "$REPLY removed, kept $version" \
    "AWS CLI bundles: removed $REPLY; kept the active $version."
}

# Removes the planned superseded nvm runtimes below the confirmed root.
# Planned versions follow the rules of _sys_clean_step_releases; the default
# runtime and every other release line stay installed.
# Usage: _sys_clean_step_nvm_runtimes <confirmed-root>|<versions>
_sys_clean_step_nvm_runtimes() {
  local REPLY expected_root name target
  local -a reply=() names=() current=() removed=()
  local -i failures=0
  _sys_clean_split_version_scope "${1:-}" || {
    _sys_error "Invalid Node.js runtimes plan record."
    return 1
  }
  expected_root="$REPLY"
  names=("${reply[@]}")
  if ! _sys_clean_nvm_targets; then
    _sys_error "The confirmed nvm runtime directory is no longer available."
    return 1
  fi
  [[ "$REPLY" == "$expected_root" ]] || {
    _sys_error "nvm runtime path changed after confirmation."
    return 1
  }
  current=("${reply[@]}")

  for name in "${names[@]}"; do
    target="$expected_root/$name"
    if [[ "$name" != v<->.<->.<-> ]]; then
      _sys_error "Refusing an unexpected Node.js runtime name: $(_sys_display_escape "$name")"
      (( ++failures ))
      continue
    fi
    [[ -e "$target" || -L "$target" ]] || continue
    if (( ! ${current[(Ie)$name]} )); then
      _sys_error "Node.js $name is no longer superseded; it was kept."
      (( ++failures ))
      continue
    fi
    if command rm -rf -- "$target"; then
      removed+=("$name")
    else
      (( ++failures ))
    fi
  done
  (( ${#removed} > 0 )) \
    && _sys_dim "Removed: ${(j:, :)removed}"
  if (( failures > 0 )); then
    _sys_error "Some planned Node.js runtimes could not be removed."
    return 1
  fi
  if (( ${#removed} == 0 )); then
    _sys_report_result current "nothing left to remove" \
      "No planned Node.js runtimes remain to remove."
    return 0
  fi
  _sys_count_noun "${#removed}" "superseded runtime"
  _sys_report_result done "$REPLY removed" \
    "Node.js runtimes: removed $REPLY."
}

_sys_clean_step_rust_downloads() {
  local REPLY
  if ! command -v rustup &>/dev/null; then
    _sys_report_result skipped "not installed" "rustup not installed, skipping."
    return 0
  fi

  local rustup_downloads="${1:-}"
  if [[ -d "$rustup_downloads" ]]; then
    _sys_clean_validate_user_path "$rustup_downloads" || return 1
    command rm -rf -- "$REPLY"/*(ND) || {
      _sys_error "Some rustup download cache entries could not be removed."
      return 1
    }
    _sys_report_result done "download cache cleared" \
      "Cleared rustup download cache."
  else
    _sys_report_result current "nothing to clean" \
      "No rustup download cache found."
  fi
}

_sys_clean_step_cargo_cache() {
  local REPLY
  if ! command -v cargo &>/dev/null; then
    _sys_report_result skipped "not installed" "cargo not installed, skipping."
    return 0
  fi

  local cargo_cache="${1:-}"
  if [[ -d "$cargo_cache" ]]; then
    _sys_clean_validate_user_path "$cargo_cache" || return 1
    cargo_cache="$REPLY"
    local cache_size
    cache_size=$(command du -sh -- "$cargo_cache" 2>/dev/null \
      | command awk '{print $1}')
    command rm -rf -- "$cargo_cache"/*(ND) || {
      _sys_error "Some cargo registry cache entries could not be removed."
      return 1
    }
    _sys_report_result done "freed ${cache_size:-some space}" \
      "Freed ${cache_size:-some space} from cargo registry cache."
  else
    _sys_report_result current "nothing to clean" \
      "No cargo registry cache found."
  fi
}

_sys_clean_step_go_modcache() {
  local REPLY
  if ! command -v go &>/dev/null; then
    _sys_report_result skipped "not installed" "Go not installed, skipping."
    return 0
  fi

  _sys_dim "May take several minutes for large module caches."
  local expected_cache="${1:-}"
  local cache_dir
  cache_dir=$(_sys_clean_go_cache_dir) || return 1
  [[ -n "$expected_cache" && "$cache_dir" == "$expected_cache" ]] || {
    _sys_error "Go module cache path changed after confirmation."
    return 1
  }
  _sys_clean_validate_user_path "$expected_cache" || return 1
  cache_dir="$REPLY"
  [[ -d "$cache_dir" ]] || {
    _sys_error "The confirmed Go module cache is no longer available."
    return 1
  }
  _sys_clean_go_cache_layout "$cache_dir" || {
    _sys_error "The confirmed Go module cache no longer has its cache/download directory."
    return 1
  }
  _sys_clean_in_neutral_dir command env GOTOOLCHAIN=local \
    GOMODCACHE="$cache_dir" go clean -modcache >&2
}

_sys_clean_step_journal() {
  local -a reply=()
  if ! _sys_has_systemd; then
    _sys_report_not_applicable "Journal cleanup" "systemd is not active"
    return
  fi

  local -a privilege_prefix=()
  _sys_resolve_privilege_prefix || return 1
  privilege_prefix=("${reply[@]}")
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  _sys_dim \
    "Privileged operation: ${privilege_label}journalctl --vacuum-time=3d"
  "${privilege_prefix[@]}" journalctl --vacuum-time=3d >&2
}

_sys_clean_step_thumbnails() {
  local REPLY
  local thumbnails_dir="${1:-}"
  [[ -d "$thumbnails_dir" ]] || {
    _sys_report_result current "nothing to clean"
    return 0
  }
  _sys_clean_validate_user_path "$thumbnails_dir" || return 1
  command rm -rf -- "$REPLY"/*(ND) 2>/dev/null
}

_sys_clean_step_temp_files() {
  local REPLY
  local cache_tmp="${1:-}"
  [[ -d "$cache_tmp" ]] || {
    _sys_report_result current "nothing to clean"
    return 0
  }
  _sys_clean_validate_user_path "$cache_tmp" || return 1
  command rm -rf -- "$REPLY"/*(ND) 2>/dev/null
}

# Prints the "<label>|<dir>" plan record of one probed cache, or one warning
# that says why it is skipped: the probe failed, the validator refused the
# directory, which it reports with --quiet, or the directory lacks its
# layout signature. An absent cache has nothing to clean and is skipped
# silently.
# Usage: _sys_clean_plan_cache <label> <dir-function> [<layout-function> <signature>]
_sys_clean_plan_cache() {
  local label="${1:-}" dir_function="${2:-}" layout_function="${3:-}"
  local signature="${4:-}" cache_dir REPLY
  local -i cache_rc=0
  cache_dir=$("$dir_function" --quiet) || cache_rc=$?
  if (( cache_rc == 3 )); then
    _sys_warn "Skipping $label: $cache_dir"
    return 0
  elif (( cache_rc != 0 )); then
    _sys_warn "Skipping $label: its directory could not be resolved."
    return 0
  fi
  [[ -d "$cache_dir" ]] || return 0
  if [[ -n "$layout_function" ]] && ! "$layout_function" "$cache_dir"; then
    _sys_clean_display_path "$cache_dir"
    _sys_warn "Skipping $label: $REPLY has no $signature."
    return 0
  fi
  print -r -- "$label|$cache_dir"
}

_sys_clean_plan() {
  local REPLY
  local -a reply=()
  local mode="$1"
  _sys_has_capability "package:apt" \
    && print -r -- "APT cache|apt-get clean"
  local cache_dir
  # A failed cache probe omits only that tool's step, for example when the
  # tool is a lazy shell function that the timeout helper cannot execute.
  # Nothing is removed for a cache whose directory cannot be resolved.
  # A Windows npm that WSL reaches through its appended Windows PATH is not
  # this host's npm.
  _sys_tool_available npm \
    && _sys_clean_plan_cache "npm cache" _sys_clean_npm_cache_dir
  command -v uv &>/dev/null \
    && _sys_clean_plan_cache "uv cache" _sys_clean_uv_cache_dir \
      _sys_clean_uv_cache_layout "uv CACHEDIR.TAG"
  if _sys_clean_pip_command; then
    if cache_dir=$(_sys_clean_pip_cache_dir); then
      [[ -d "$cache_dir" ]] && print -r -- "pip cache|$cache_dir"
    else
      _sys_warn "Skipping pip cache: its directory could not be resolved."
    fi
  fi
  if _sys_tool_available pre-commit; then
    if cache_dir=$(_sys_clean_precommit_cache_dir); then
      [[ -d "$cache_dir" ]] && print -r -- "pre-commit cache|$cache_dir"
    else
      _sys_warn "Skipping pre-commit cache: its directory could not be resolved."
    fi
  fi
  if command -v cargo &>/dev/null \
    && [[ -d "${CARGO_HOME:-$HOME/.cargo}/registry/cache" ]]; then
    _sys_clean_validate_user_path \
      "${CARGO_HOME:-$HOME/.cargo}/registry/cache" || return 1
    print -r -- "Cargo registry cache|$REPLY"
  fi
  # Superseded versions are planned by name only when some exist; execution
  # removes a planned name only while it is still superseded.
  local release_label
  local -a release_names=()
  local -i awscli_rc=0
  for release_label in "Codex releases" "Cursor Agent versions" \
    "Claude CLI versions"; do
    _sys_clean_release_targets "$release_label" && (( ${#reply} > 0 )) \
      || continue
    release_names=("${(@)reply#"$REPLY"/}")
    release_names=("${(@)release_names:#}")
    _sys_clean_plain_relative_path "${(j:/:)release_names}" || continue
    print -r -- "$release_label|$REPLY|${(j: :)release_names}"
  done
  if _sys_clean_awscli_root; then
    local awscli_root="$REPLY"
    _sys_clean_awscli_superseded "$awscli_root" "${reply[1]}" "${reply[2]}" \
      || awscli_rc=$?
    case $awscli_rc in
      0)
        (( ${#reply} > 0 )) \
          && print -r -- "AWS CLI bundles|$awscli_root|${(j: :)${(@)reply:t}}"
        ;;
      3)
        _sys_warn "Skipping AWS CLI bundles: running programs cannot be inspected on this host."
        ;;
      *)
        _sys_warn "Skipping AWS CLI bundles: a bundle directory has an unexpected owner."
        ;;
    esac
  fi
  if _sys_clean_nvm_targets && (( ${#reply} > 0 )); then
    print -r -- "Node.js runtimes|$REPLY|${(j: :)reply}"
  fi
  _sys_has_systemd \
    && print -r -- "Journal logs|journal entries older than 3 days"
  if [[ -d "$HOME/.cache/thumbnails" ]]; then
    _sys_clean_validate_user_path "$HOME/.cache/thumbnails" || return 1
    print -r -- "Thumbnail cache|$REPLY"
  fi
  if [[ -d "$HOME/.cache/tmp" ]]; then
    _sys_clean_validate_user_path "$HOME/.cache/tmp" || return 1
    print -r -- "Temporary files|$REPLY"
  fi

  if [[ "$mode" == "deep" ]]; then
    command -v brew &>/dev/null \
      && print -r -- "Homebrew cleanup|brew autoremove and cleanup --prune=all"
    if command -v rustup &>/dev/null \
      && [[ -d "${RUSTUP_HOME:-$HOME/.rustup}/downloads" ]]; then
      _sys_clean_validate_user_path \
        "${RUSTUP_HOME:-$HOME/.rustup}/downloads" || return 1
      print -r -- "Rust downloads|$REPLY"
    fi
    command -v go &>/dev/null \
      && _sys_clean_plan_cache "Go module cache" _sys_clean_go_cache_dir \
        _sys_clean_go_cache_layout "cache/download directory"
  fi
  return 0
}

# reply: the "<label>;<function>" steps of one cleanup mode in execution
# order, which the numbered plan table follows as well. Any mode other than
# quick selects deep, as _sys_clean_run always has.
# Usage: _sys_clean_mode_steps <quick|deep>
_sys_clean_mode_steps() {
  if [[ "${1:-}" == quick ]]; then
    reply=(
      "APT cache;_sys_clean_step_apt_cache"
      "npm cache;_sys_clean_step_npm_cache"
      "uv cache;_sys_clean_step_uv_cache"
      "pip cache;_sys_clean_step_pip_cache"
      "pre-commit cache;_sys_clean_step_precommit_cache"
      "Cargo registry cache;_sys_clean_step_cargo_cache"
      "Codex releases;_sys_clean_step_codex_releases"
      "Cursor Agent versions;_sys_clean_step_cursor_versions"
      "Claude CLI versions;_sys_clean_step_claude_versions"
      "AWS CLI bundles;_sys_clean_step_awscli_bundles"
      "Node.js runtimes;_sys_clean_step_nvm_runtimes"
      "Journal logs;_sys_clean_step_journal"
      "Thumbnail cache;_sys_clean_step_thumbnails"
      "Temporary files;_sys_clean_step_temp_files"
    )
    return 0
  fi
  reply=(
    "APT cache;_sys_clean_step_apt_cache"
    "Homebrew cleanup;_sys_clean_step_homebrew"
    "npm cache;_sys_clean_step_npm_cache"
    "uv cache;_sys_clean_step_uv_cache"
    "pip cache;_sys_clean_step_pip_cache"
    "pre-commit cache;_sys_clean_step_precommit_cache"
    "Rust downloads;_sys_clean_step_rust_downloads"
    "Cargo registry cache;_sys_clean_step_cargo_cache"
    "Go module cache;_sys_clean_step_go_modcache"
    "Codex releases;_sys_clean_step_codex_releases"
    "Cursor Agent versions;_sys_clean_step_cursor_versions"
    "Claude CLI versions;_sys_clean_step_claude_versions"
    "AWS CLI bundles;_sys_clean_step_awscli_bundles"
    "Node.js runtimes;_sys_clean_step_nvm_runtimes"
    "Journal logs;_sys_clean_step_journal"
    "Thumbnail cache;_sys_clean_step_thumbnails"
    "Temporary files;_sys_clean_step_temp_files"
  )
}

_sys_clean_run() {
  local mode="${1:-deep}"
  local plan_output="${2:-}"
  local REPLY
  local -a reply=()
  local -i errors=0 step=0 step_rc=0
  local -a failed_labels=() summary_records=() retry_commands=()
  local entry label func outcome detail step_seconds remaining retry_command

  local -a steps
  _sys_clean_mode_steps "$mode"
  steps=("${reply[@]}")

  local -A planned_scopes=()
  local plan_record plan_label plan_scope
  for plan_record in "${(@f)plan_output}"; do
    [[ "$plan_record" == *"|"* ]] || {
      _sys_error "Invalid cleanup plan record."
      return 1
    }
    plan_label="${plan_record%%|*}"
    plan_scope="${plan_record#*|}"
    [[ -n "$plan_label" && -n "$plan_scope" ]] \
      && (( ! ${+planned_scopes[$plan_label]} )) || {
      _sys_error "Ambiguous cleanup plan record."
      return 1
    }
    planned_scopes[$plan_label]="$plan_scope"
  done

  local -a applicable_steps=()
  for entry in "${steps[@]}"; do
    label="${entry%%;*}"
    (( ${+planned_scopes[$label]} )) && applicable_steps+=("$entry")
  done
  if (( ${#applicable_steps[@]} != ${#planned_scopes[@]} )); then
    _sys_error "Cleanup plan contains an unsupported step."
    return 1
  fi
  steps=("${applicable_steps[@]}")

  local total=${#steps[@]}
  (( total > 0 )) || {
    _sys_info "No cleanup targets remain."
    return 0
  }
  for entry in "${steps[@]}"; do
    (( ++step ))
    label="${entry%%;*}"
    func="${entry#*;}"
    _sys_step_banner "$step" "$total" "$label"
    step_rc=0
    _sys_step_exec "$func" "${planned_scopes[$label]}" || step_rc=$?
    outcome="${reply[1]:-done}"
    detail="${reply[2]:-}"
    step_seconds="${reply[3]:-0}"
    _sys_step_result "$step" "$total" "$label" "$outcome" "$detail" \
      "$step_seconds"
    summary_records+=("$label"$'\t'"$outcome"$'\t'"$step_seconds"$'\t'"$detail")
    (( step_rc == 0 )) && continue

    (( ++errors ))
    _sys_duration_label "$step_seconds"
    if [[ -n "$detail" && "$detail" != "status $step_rc" ]]; then
      failed_labels+=("$label — $detail ($REPLY)")
    else
      failed_labels+=("$label ($REPLY)")
    fi
    _sys_clean_retry_command "$mode" "$label"
    retry_commands+=("$REPLY")
    if (( step_rc == 130 || step_rc == 143 )); then
      # An interruption stops the plan; later targets keep their data.
      for remaining in "${(@)steps[step+1,-1]}"; do
        summary_records+=("${remaining%%;*}"$'\tnot-run\t\tcleanup interrupted')
      done
      _sys_print_step_summary "Cleanup Summary" "${summary_records[@]}"
      _sys_error "System cleanup interrupted (status $step_rc): $label"
      return $step_rc
    fi
  done

  _sys_print_step_summary "Cleanup Summary" "${summary_records[@]}"
  _sys_count_noun "$total" step
  if (( errors == 0 )); then
    _sys_success "System cleanup completed successfully! ($total/$REPLY)"
    return 0
  fi
  if (( errors < total )); then
    _sys_error \
      "System cleanup completed with partial failures: $errors of $REPLY failed."
    typeset -f _zdx_timed_mark_partial &>/dev/null \
      && _zdx_timed_mark_partial || true
  elif (( total == 1 )); then
    _sys_error "System cleanup failed: the only step failed."
  else
    _sys_error "System cleanup failed: all $REPLY failed."
  fi
  for label in "${failed_labels[@]}"; do
    _sys_dim "• $label"
  done
  _sys_info "Retry after resolving the errors above:"
  for retry_command in "${(@u)retry_commands}"; do
    _sys_dim "  $retry_command"
  done
  return 1
}

# REPLY: the public command that retries one failed cleanup step. Only the
# journal has a focused command; every other step reruns its mode.
# Usage: _sys_clean_retry_command <quick|deep> <label>
_sys_clean_retry_command() {
  case "${2:-}" in
    "Journal logs") REPLY="sys-menu clean-journal" ;;
    *)              REPLY="sys-menu clean-system --${1:-quick}" ;;
  esac
}

# reply: the given plan labels whose step runs through sudo on this host, in
# order. Empty for root or a direct privilege path. The AWS CLI bundles need
# sudo only when root owns the installation.
# Usage: _sys_clean_privileged_labels <label>...
_sys_clean_privileged_labels() {
  local label REPLY
  local -a privileged=()
  reply=()
  (( EUID != 0 )) && ! _sys_has_capability "privilege:direct" || return 0
  for label in "$@"; do
    case "$label" in
      "APT cache"|"Journal logs") privileged+=("$label") ;;
      "AWS CLI bundles")
        _sys_clean_awscli_root && [[ "${reply[2]:-}" == 0 ]] \
          && privileged+=("$label")
        ;;
    esac
  done
  reply=("${privileged[@]}")
}

# REPLY: the display form of the space-separated superseded names of a plan
# record: every name in plan order, each without a Codex "releases"
# component. A destructive plan names its exact target set, so no name is
# summarized as a count.
# Usage: _sys_clean_names_display <names>
_sys_clean_names_display() {
  local -a names=("${(@s: :)${1:-}}") shown=()
  local name
  for name in "${names[@]}"; do
    shown+=("${(V)${name//\/releases\///}}")
  done
  REPLY="${(j:, :)shown}"
}

# REPLY: what a cleanup mode covers on this host, for the mode prompt and the
# confirmation. Journal and thumbnail wording appears only where those targets
# exist: the journal needs systemd, and the thumbnail cache is the freedesktop
# one on Linux.
# Usage: _sys_clean_mode_summary <quick|deep-extra>
_sys_clean_mode_summary() {
  local -a parts=()
  case "${1:-}" in
    quick)
      parts=("package and language caches" "superseded tool versions")
      _sys_has_systemd && parts+=("old journal logs")
      _sys_has_capability "os:linux" && parts+=("thumbnails")
      parts+=("the user temporary cache")
      ;;
    deep-extra)
      command -v brew &>/dev/null && parts+=("Homebrew cleanup")
      parts+=("Rust and Go caches")
      ;;
    *) return 2 ;;
  esac
  if (( ${#parts} == 1 )); then
    REPLY="${parts[1]}"
  elif (( ${#parts} == 2 )); then
    REPLY="${parts[1]} and ${parts[2]}"
  else
    REPLY="${(j:, :)parts[1,-2]}, and ${parts[-1]}"
  fi
}

# Plans, confirms, and runs one cleanup mode for clean-system, which owns the
# public grammar. Usage: _sys_clean_system_main <quick|deep> <dry-run> <yes>
_sys_clean_system_main() {
  local mode="${1:-}" dry_run="${2:-0}" assume_yes="${3:-0}"
  [[ "$mode" == quick || "$mode" == deep ]] \
    && [[ "$dry_run" == 0 || "$dry_run" == 1 ]] \
    && [[ "$assume_yes" == 0 || "$assume_yes" == 1 ]] || return 2
  local REPLY
  local -a reply=()

  # The protected roots come from the caller's directory once, before any
  # probe; the plan and every step's revalidation reuse them.
  local -a _sys_clean_protected_cache=()
  local -i _sys_clean_protected_ready=0
  _sys_clean_resolve_protected_roots
  _sys_clean_protected_cache=("${reply[@]}")
  _sys_clean_protected_ready=1

  local plan_output
  plan_output=$(_sys_clean_plan "$mode") || return 1
  local -a plan_records=()
  [[ -n "$plan_output" ]] && plan_records=("${(@f)plan_output}")
  _sys_header "${(C)mode} Cleanup Plan"
  local plan_record plan_scope plan_names step_label
  local -a plan_rows=() ordered_records=() step_labels=()
  local -i plan_index=0
  # Number the table in execution order, so each row matches its banner. A
  # record without a step stays at the end, where execution refuses it.
  _sys_clean_mode_steps "$mode"
  step_labels=("${reply[@]%%;*}")
  for step_label in "${step_labels[@]}"; do
    for plan_record in "${plan_records[@]}"; do
      [[ "${plan_record%%|*}" == "$step_label" ]] \
        && ordered_records+=("$plan_record")
    done
  done
  for plan_record in "${plan_records[@]}"; do
    (( ${step_labels[(Ie)${plan_record%%|*}]} )) \
      || ordered_records+=("$plan_record")
  done
  plan_records=("${ordered_records[@]}")
  for plan_record in "${plan_records[@]}"; do
    (( ++plan_index ))
    plan_scope="${plan_record#*|}"
    plan_names=""
    if [[ "$plan_scope" == *"|"* ]]; then
      plan_names="${plan_scope#*|}"
      plan_scope="${plan_scope%%|*}"
    fi
    [[ -n "$HOME" && "$HOME" != / && "$plan_scope" == "$HOME"/* ]] \
      && plan_scope="~/${plan_scope#"$HOME"/}"
    if [[ -n "$plan_names" ]]; then
      _sys_clean_names_display "$plan_names"
      plan_scope+=" (superseded: $REPLY)"
    fi
    plan_rows+=("$plan_index"$'\t'"${plan_record%%|*}"$'\t'"${plan_scope//$'\t'/ }")
  done
  (( ${#plan_rows[@]} > 0 )) \
    && _sys_table $'#\tStep\tTarget' "${plan_rows[@]}"
  _sys_clean_privileged_labels "${plan_records[@]%%|*}"
  (( ${#reply} > 0 )) \
    && _sys_warn "These steps run through sudo: ${(j:, :)reply}."
  (( ${plan_records[(I)Node.js runtimes\|*]} )) \
    && _sys_warn "Open shells that still use a planned Node.js runtime need nvm use default afterwards."
  # Static policy belongs to the dry run, ZDX_VERBOSE=1, and --help.
  if (( dry_run )) || [[ "${ZDX_VERBOSE:-0}" == 1 ]]; then
    _sys_dim "Shared /tmp content and Docker resources are never removed by this workflow."
  fi

  if (( dry_run )); then
    _sys_info "Dry run complete; no cleanup step was executed."
    return 0
  fi
  (( ${#plan_records[@]} > 0 )) || {
    _sys_info "No applicable cleanup targets were found."
    return 0
  }

  # No process-name scan gates the plan: each package manager arbitrates its
  # own lock, so a busy APT fails only the APT cache step.
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive cleanup requires --yes."
      return 1
    fi

    _sys_info "This will remove cache and temporary data for this system."
    if [[ "$mode" == "quick" ]]; then
      _sys_clean_mode_summary quick
      _sys_dim "Quick mode: $REPLY."
    else
      _sys_clean_mode_summary deep-extra
      _sys_warn "Deep mode adds $REPLY."
      _sys_dim "Use quick mode if you want a fast cleanup with lower risk of long waits."
    fi
    _sys_blank
    _sys_confirm "Proceed with this exact ${mode} cleanup plan?" || {
      _sys_blank
      _sys_info "Cancelled."
      return 0
    }
    _sys_blank
  fi

  _sys_clean_run "$mode" "$plan_output"
}

# =============================================================================
# PUBLIC COMMANDS
# =============================================================================

clean-journal() {
  local -i assume_yes=0 dry_run=0
  local -a reply=()
  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! dry_run && ! assume_yes )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        print -u2 -r -- \
          'Usage: clean-journal [--dry-run] [-y|--yes] [-h|--help]'
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      -y|--yes)  assume_yes=1 ;;
      *)
        _sys_error "Unknown option for clean-journal: $1"
        return 2
        ;;
    esac
    shift
  done
  if ! _sys_has_systemd; then
    _sys_report_not_applicable clean-journal "the systemd journal is not active"
    return
  fi
  _sys_header "Journal Cleanup Plan"

  local before_size
  before_size=$(_sys_run_with_timeout 5 journalctl --disk-usage 2>/dev/null \
    | command grep -oE '[0-9]+([.][0-9]+)?([KMGTPE](i?B)?|B)' \
    | command head -1)
  _sys_info "Current journal size: ${before_size:-unknown}"
  _sys_info "Target: journal entries older than 3 days."
  (( dry_run )) && {
    _sys_info "Dry run complete; the journal was not changed."
    return 0
  }
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive journal cleanup requires --yes."
      return 1
    fi
    _sys_confirm "Vacuum this exact journal scope?" || {
      _sys_info "Cancelled."
      return 0
    }
  fi

  _sys_info "Vacuuming logs older than 3 days..."
  local -a privilege_prefix=()
  _sys_resolve_privilege_prefix || return 1
  privilege_prefix=("${reply[@]}")
  local privilege_label=""
  (( ${#privilege_prefix[@]} > 0 )) \
    && privilege_label="${(j: :)privilege_prefix} "
  _sys_info \
    "Privileged operation: ${privilege_label}journalctl --vacuum-time=3d"
  "${privilege_prefix[@]}" journalctl --vacuum-time=3d >&2 || {
    local cleanup_rc=$?
    _sys_error "Journal cleanup failed."
    return "$cleanup_rc"
  }

  local after_size
  after_size=$(_sys_run_with_timeout 5 journalctl --disk-usage 2>/dev/null \
    | command grep -oE '[0-9]+([.][0-9]+)?([KMGTPE](i?B)?|B)' \
    | command head -1)
  _sys_success "Journal cleaned. Now: ${after_size:-unknown}"
}

clean-snaps() {
  local assume_yes=0 dry_run=0

  while (( $# )); do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      --help|-h)
        (( $# == 1 && ! assume_yes && ! dry_run )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        print -u2 -r -- \
          "Usage: clean-snaps [--dry-run] [-y|--yes] [-h|--help]"
        return 0 ;;
      *)
        _sys_error "Unknown option for clean-snaps: $1"
        return 2
        ;;
    esac
    shift
  done

  if ! command -v snap &>/dev/null; then
    _sys_report_not_applicable clean-snaps "Snap is not installed"
    return
  fi
  if ! _sys_snap_ready; then
    # Querying an absent snapd can hang, notably on WSL without systemd.
    _sys_report_not_applicable clean-snaps "snapd is not running"
    return
  fi
  _sys_header "Cleaning Disabled Snap Revisions"

  local disabled_snaps
  disabled_snaps=$(_sys_disabled_snap_revisions)
  local rc=$?
  if (( rc == 124 )); then
    _sys_warn "Timed out while querying disabled snap revisions."
    return 1
  elif (( rc != 0 )); then
    _sys_error "Failed to inspect disabled snap revisions."
    return 1
  fi
  disabled_snaps=$(_sys_validate_disabled_snap_revisions "$disabled_snaps") \
    || return 1

  if [[ -z "$disabled_snaps" ]]; then
    _sys_info "No disabled snap revisions found."
    return 0
  fi

  local -a snap_lines=( "${(@f)disabled_snaps}" )
  local REPLY
  _sys_count_noun "${#snap_lines}" "disabled revision"
  _sys_info "Found $REPLY:"
  local line name rev
  for line in "${snap_lines[@]}"; do
    read -r name rev <<<"$line"
    _sys_dim "$name (rev $rev)"
  done

  _sys_blank
  if (( dry_run )); then
    _sys_info "Dry run complete; no Snap revision was removed."
    return 0
  fi
  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 2 ]]; then
      _sys_error "Non-interactive snap cleanup requires --yes."
      return 1
    fi
    _sys_confirm "Remove these exact disabled revisions?" || {
      _sys_info "Cancelled."
      return 0
    }
    _sys_blank
  fi

  _sys_remove_disabled_snap_revisions "$disabled_snaps" || return 1
  _sys_success "Disabled snap revisions cleaned."
}

clean-system() {
  local mode="" assume_yes=0 dry_run=0 choice

  while (( $# )); do
    case "$1" in
      --quick)
        [[ -z "$mode" || "$mode" == "quick" ]] || {
          _sys_error "Choose exactly one cleanup mode."
          return 2
        }
        mode="quick"
        ;;
      --deep)
        [[ -z "$mode" || "$mode" == "deep" ]] || {
          _sys_error "Choose exactly one cleanup mode."
          return 2
        }
        mode="deep"
        ;;
      --yes|-y) assume_yes=1 ;;
      --dry-run) dry_run=1 ;;
      --help|-h)
        (( $# == 1 && ! assume_yes && ! dry_run )) \
          && [[ -z "$mode" ]] || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        cat >&2 <<'EOF'
Usage: clean-system [--quick|--deep] [--dry-run] [-y|--yes] [-h|--help]

Modes:
  --quick     Fast cleanup for common caches, logs, and temp files
  --deep      Quick cleanup plus slower package/runtime cleanup

Options:
  --dry-run   Print the cleanup plan without removing anything.
  --yes, -y   Authorize the displayed plan without a prompt.

Without a mode, an interactive shell will prompt you to choose. A
non-interactive run needs a mode, plus --yes unless it is a dry run.
Shared /tmp content and Docker resources are never removed.
EOF
        return 0 ;;
      *)
        _sys_error "Unknown option: $1"
        return 2
        ;;
    esac
    shift
  done

  if [[ -z "$mode" ]]; then
    if [[ -t 0 && -t 2 ]]; then
      _sys_header "System Cleanup"
      _sys_info "Choose a cleanup mode:"
      local REPLY
      _sys_clean_mode_summary quick
      _sys_dim "  1) quick — $REPLY"
      _sys_clean_mode_summary deep-extra
      _sys_dim "  2) deep  — quick + $REPLY"
      _sys_blank
      if _sys_color_enabled; then
        printf "\033[1;33m? Select mode [1/2/c]: \033[0m" >&2
      else
        printf "? Select mode [1/2/c]: " >&2
      fi
      read -r choice
      case "${choice:l}" in
        1|quick)   mode="quick" ;;
        2|d|deep)  mode="deep" ;;
        *) _sys_info "Cancelled."; return 0 ;;
      esac
      _sys_blank
    else
      _sys_error "Non-interactive cleanup requires --quick or --deep."
      return 2
    fi
  fi

  _sys_clean_system_main "$mode" "$dry_run" "$assume_yes"
}

typeset -g _SYS_CLEAN_SOURCED=1
