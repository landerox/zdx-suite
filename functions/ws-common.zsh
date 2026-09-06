#!/usr/bin/env zsh
# =============================================================================
# Workspace Common: validation, menu, and routing primitives
# =============================================================================
#
# Loaded by ws-menu.zsh before every module under functions/ws/.
# Private Workspace helpers plus temporary `_tk_*` compatibility adapters.
#

if [[ -n "${_WS_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset _ws_common_root="${${(%):-%x}:A:h}"
typeset _ws_git_common="$_ws_common_root/git-common.zsh"
typeset -i _ws_common_source_rc=0

# Workspace identity remains the documented Git/Workspace legacy coupling.
# Load that exact sibling only; never mix modules from another installation.
if [[ -z "${_GIT_COMMON_SOURCED:-}" ]]; then
  if [[ ! -f "$_ws_git_common" || -L "$_ws_git_common" \
    || ! -r "$_ws_git_common" ]]; then
    print -u2 -r -- "ws-common.zsh: failed to load git-common.zsh"
    unset _ws_common_root _ws_git_common _ws_common_source_rc
    return 1 2>/dev/null || exit 1
  fi

  source "$_ws_git_common"
  _ws_common_source_rc=$?
  if (( _ws_common_source_rc != 0 )) \
    || [[ -z "${_GIT_COMMON_SOURCED:-}" ]]; then
    print -u2 -r -- "ws-common.zsh: failed to load git-common.zsh"
    unset _ws_common_root _ws_git_common
    {
      (( _ws_common_source_rc == 0 )) && _ws_common_source_rc=1
      return $_ws_common_source_rc 2>/dev/null || exit $_ws_common_source_rc
    } always {
      unset _ws_common_source_rc
    }
  fi
fi

unset _ws_common_root _ws_git_common _ws_common_source_rc

# --- Runtime and UI ---------------------------------------------------------

_ws_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

_ws_header()  { _git_header "$@"; }
_ws_success() { _git_success "$@"; }
_ws_warn()    { _git_warn "$@"; }
_ws_info()    { _git_info "$@"; }
_ws_error()   { _git_error "$@"; }
_ws_dim()     { _git_dim "$@"; }
_ws_label()   { _git_label "$@"; }
_ws_blank()   { _git_blank; }

_ws_timed() {
  local label="$1"
  shift
  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

_ws_check_cmd() {
  command -v "$1" &>/dev/null
}

_ws_check_deps() {
  local -a missing=()
  local dependency=""
  for dependency in "$@"; do
    _ws_check_cmd "$dependency" || missing+=("$dependency")
  done
  if (( ${#missing[@]} > 0 )); then
    _ws_error "Missing dependencies: ${(j:, :)missing}"
    return 1
  fi
  return 0
}

# Shared minimal parser for feature commands that accept no operands. It runs
# before any dependency, base-directory, or host probe. Sets REPLY to "run" or
# "help"; unknown options and unexpected operands fail closed with status 2.
_ws_parse_no_args() {
  local command_name="$1"
  local description="$2"
  shift 2
  REPLY="run"
  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print -u2 -r -- "Usage: $command_name [-h|--help]"
    print -u2 -r -- "  $description"
    REPLY="help"
    return 0
  fi
  (( $# == 0 )) && return 0
  if [[ "$1" == -* ]]; then
    _ws_error "Unknown option for $command_name: $1"
  else
    _ws_error "Unexpected argument for $command_name: $1"
  fi
  return 2
}

# Shared parser for feature commands that accept plain repository operands.
# max_operands bounds the operand count; -1 leaves it unbounded. Option-like
# arguments beyond a sole -h/--help fail closed with status 2, matching the
# repository grammar that forbids operands beginning with a dash.
_ws_parse_operands() {
  local command_name="$1"
  local max_operands="$2"
  local operand_usage="$3"
  local description="$4"
  shift 4
  REPLY="run"
  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print -u2 -r -- "Usage: $command_name [-h|--help] $operand_usage"
    print -u2 -r -- "  $description"
    REPLY="help"
    return 0
  fi
  local argument=""
  for argument in "$@"; do
    [[ "$argument" == -* ]] || continue
    _ws_error "Unknown option for $command_name: $argument"
    return 2
  done
  if [[ "$max_operands" == <-> ]] && (( $# > max_operands )); then
    _ws_error "Too many arguments for $command_name."
    return 2
  fi
  return 0
}

_ws_timeout_tree_pids() {
  local root_pid="${1:-}"
  reply=("$root_pid")
  [[ "$root_pid" == <-> && "$root_pid" -gt 1 ]] || return 2

  local process_output=""
  process_output=$(command ps -Ao pid=,ppid= 2>/dev/null) || return 0
  local -a process_lines=("${(@f)process_output}")
  local -A selected=(["$root_pid"]=1)
  local -i changed=1 pass=0
  local process_line="" process_pid="" parent_pid=""
  local -a process_fields=()

  while (( changed && ++pass <= 64 )); do
    changed=0
    for process_line in "${process_lines[@]}"; do
      process_fields=(${=process_line})
      (( ${#process_fields[@]} == 2 )) || continue
      process_pid="${process_fields[1]}"
      parent_pid="${process_fields[2]}"
      [[ "$process_pid" == <-> && "$parent_pid" == <-> ]] || continue
      if (( ${+selected[$parent_pid]} && ! ${+selected[$process_pid]} )); then
        selected[$process_pid]=1
        changed=1
      fi
    done
  done

  reply=("${(@k)selected}")
}

_ws_timeout_signal_tree() {
  local root_pid="${1:-}"
  local signal_name="${2:-}"
  local -a reply=()
  _ws_timeout_tree_pids "$root_pid" || reply=("$root_pid")
  (( ${#reply[@]} > 0 )) \
    && builtin kill "-$signal_name" "${reply[@]}" 2>/dev/null
  return 0
}

# Run one command within a hard wall-clock bound. GNU `timeout` and Homebrew
# `gtimeout` are preferred; the Zsh fallback owns and reaps the exact child PID.
_ws_run_with_timeout() {
  emulate -L zsh
  setopt NO_MONITOR

  local seconds="${1:-}"
  shift 2>/dev/null || {
    _ws_error "A timeout and command are required."
    return 2
  }
  [[ "$seconds" == <-> && ${#seconds} -le 3 ]] \
    && (( seconds >= 1 && seconds <= 120 )) || {
      _ws_error "The command timeout must be between 1 and 120 seconds."
      return 2
    }
  (( $# > 0 )) || {
    _ws_error "A bounded command is required."
    return 2
  }

  local timeout_program=""
  timeout_program=$(whence -p timeout 2>/dev/null) || timeout_program=""
  if [[ -n "$timeout_program" ]]; then
    command "$timeout_program" -k 1s "${seconds}s" "$@"
    return $?
  fi

  timeout_program=$(whence -p gtimeout 2>/dev/null) || timeout_program=""
  if [[ -n "$timeout_program" ]]; then
    command "$timeout_program" -k 1s "${seconds}s" "$@"
    return $?
  fi

  local timeout_marker=""
  timeout_marker=$(command mktemp \
    "${TMPDIR:-/tmp}/zdx-ws-ssh-timeout.XXXXXX") || return 1
  command chmod 600 "$timeout_marker" 2>/dev/null || {
    command rm -f -- "$timeout_marker" 2>/dev/null
    return 1
  }

  local -i command_pid=0 watchdog_pid=0 command_rc=0 timed_out=0
  "$@" &
  command_pid=$!
  (
    if zmodload zsh/zselect 2>/dev/null; then
      zselect -t "$(( seconds * 100 ))" 2>/dev/null || true
    else
      command sleep "$seconds"
    fi
    print -r -- expired > "$timeout_marker" 2>/dev/null || return 1
    _ws_timeout_signal_tree "$command_pid" TERM
    if zmodload zsh/zselect 2>/dev/null; then
      zselect -t 100 2>/dev/null || true
    else
      command sleep 1
    fi
    _ws_timeout_signal_tree "$command_pid" KILL
  ) &
  watchdog_pid=$!

  {
    wait "$command_pid" 2>/dev/null
    command_rc=$?
  } always {
    [[ -s "$timeout_marker" ]] && timed_out=1
    builtin kill -TERM "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
    if builtin kill -0 "$command_pid" 2>/dev/null; then
      _ws_timeout_signal_tree "$command_pid" TERM
      _ws_timeout_signal_tree "$command_pid" KILL
      wait "$command_pid" 2>/dev/null
    fi
    command rm -f -- "$timeout_marker" 2>/dev/null
  }

  (( timed_out )) && return 124
  return $command_rc
}

# Probe one validated Workspace SSH alias. No server text reaches a public
# stream: at most 4 KiB is held in a private temporary solely to recognize the
# fixed GitHub/GitLab success greetings. Sets REPLY to accepted, failed, or
# timed-out and returns 0, 1, 2, or 124.
_ws_ssh_probe() {
  emulate -L zsh

  local host_alias="${1:-}"
  local connect_timeout="${2:-}"
  local overall_timeout="${3:-}"
  REPLY="failed"

  (( $# == 3 )) || {
    _ws_error "An SSH alias and two timeout bounds are required."
    return 2
  }
  [[ "$host_alias" =~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' ]] || {
    _ws_error "Refusing an invalid SSH host alias."
    return 2
  }
  [[ "$connect_timeout" == <-> && ${#connect_timeout} -le 2 ]] \
    && (( connect_timeout >= 1 && connect_timeout <= 60 )) || {
      _ws_error "The SSH connection timeout must be between 1 and 60 seconds."
      return 2
    }
  [[ "$overall_timeout" == <-> && ${#overall_timeout} -le 3 ]] \
    && (( overall_timeout >= connect_timeout \
      && overall_timeout <= 120 )) || {
      _ws_error \
        "The SSH probe timeout must be between the connection timeout and 120 seconds."
      return 2
    }

  local ssh_program=""
  ssh_program=$(whence -p ssh 2>/dev/null) || ssh_program=""
  [[ -n "$ssh_program" && -x "$ssh_program" ]] || {
    _ws_error "Missing dependency: ssh"
    return 1
  }

  local capture_file=""
  capture_file=$(command mktemp \
    "${TMPDIR:-/tmp}/zdx-ws-ssh-probe.XXXXXX") || return 1
  command chmod 600 "$capture_file" 2>/dev/null || {
    command rm -f -- "$capture_file" 2>/dev/null
    return 1
  }

  local -a ssh_command=(
    "$ssh_program"
    -T
    -o BatchMode=yes
    -o ConnectionAttempts=1
    -o "ConnectTimeout=$connect_timeout"
    -o KbdInteractiveAuthentication=no
    -o LogLevel=ERROR
    -o NumberOfPasswordPrompts=0
    -o PasswordAuthentication=no
    -o PreferredAuthentications=publickey
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=1
    -o StrictHostKeyChecking=yes
    "git@${host_alias}"
  )

  local -i probe_rc=0
  local probe_output=""
  {
    (
      limit filesize 4k || return 1
      _ws_run_with_timeout "$overall_timeout" "${ssh_command[@]}"
    ) > "$capture_file" 2>&1
    probe_rc=$?
    probe_output=$(<"$capture_file")
  } always {
    command rm -f -- "$capture_file" 2>/dev/null
  }

  if (( probe_rc == 124 )); then
    REPLY="timed-out"
    return 124
  fi
  probe_output="${probe_output:l}"
  if [[ "$probe_output" == *"successfully authenticated"* \
    || "$probe_output" == *"welcome to gitlab"* ]]; then
    REPLY="accepted"
    return 0
  fi

  REPLY="failed"
  return 1
}

_ws_fzf() {
  local -a options=(
    --height=80%
    --layout=reverse
    --border=rounded
    --delimiter='[|]'
    --with-nth=1
    --pointer='▶'
  )

  options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')

  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option=""
    theme_option=$(_tk_fzf_color_opts)
    [[ -n "$theme_option" ]] && options+=("$theme_option")
  fi

  # Compatibility settings are local to this picker and never change the shell.
  local -a terminal_options=()
  local terminal_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"
  if [[ -n "${ZDX_FZF_PLAIN:-}" || "$terminal_locale" == C \
    || "$terminal_locale" == POSIX || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-unicode '--pointer=>' '--marker=+')
  fi
  if [[ -n "${NO_COLOR:-}" || -n "${ZDX_FZF_PLAIN:-}" \
    || "${TERM:-}" == dumb ]]; then
    terminal_options+=(--no-color)
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh fzf "${options[@]}" "$@" "${terminal_options[@]}"
}

_ws_array_contains_literal() {
  local needle="${1-}" candidate=""
  shift 2>/dev/null || return 2
  for candidate in "$@"; do
    [[ "$candidate" == "$needle" ]] && return 0
  done
  return 1
}

# stdout from fzf is captured outside command substitution so the interactive
# process remains in the terminal's foreground process group. Callers provide
# records on stdin (normally through process substitution), receive the exact
# selection in REPLY, and inspect the unchanged fzf status.
_ws_fzf_capture() {
  emulate -L zsh

  REPLY=""
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _ws_error "Zsh file-descriptor support is required for Workspace pickers."
    return 125
  }

  local temp_root="${TMPDIR:-/tmp}"
  while [[ "$temp_root" != "/" && "$temp_root" == */ ]]; do
    temp_root="${temp_root%/}"
  done
  [[ -n "$temp_root" && "$temp_root" == /* && -d "$temp_root" ]] || {
    _ws_error "Could not resolve a temporary root for the Workspace picker."
    return 125
  }

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_root/zdx-ws-fzf.XXXXXX" 2>/dev/null) || {
    _ws_error "Could not create a private Workspace picker directory."
    return 125
  }
  command chmod 700 -- "$capture_dir" 2>/dev/null || {
    command rmdir -- "$capture_dir" 2>/dev/null
    _ws_error "Could not protect the Workspace picker directory."
    return 125
  }

  local -A capture_dir_state=()
  if [[ "$capture_dir" != "${capture_dir:a}" \
    || "$capture_dir" != "${capture_dir:A}" \
    || ! -d "$capture_dir" || -L "$capture_dir" \
    || "${capture_dir:t}" != zdx-ws-fzf.* ]] \
    || ! zstat -LH capture_dir_state -- "$capture_dir" 2>/dev/null \
    || (( (capture_dir_state[mode] & 8#170000) != 8#040000 \
      || capture_dir_state[uid] != EUID \
      || (capture_dir_state[mode] & 8#77) != 0 )); then
    command rmdir -- "$capture_dir" 2>/dev/null
    _ws_error "Refusing an unsafe Workspace picker directory."
    return 125
  fi
  local capture_dir_identity="${capture_dir_state[device]}:${capture_dir_state[inode]}:${capture_dir_state[mode]}:${capture_dir_state[uid]}"

  local capture_file=""
  local capture_file_identity=""
  local selection=""
  local -i capture_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A capture_file_state=() current_dir_state=() current_file_state=()

  {
    capture_file=$(umask 077; command mktemp \
      "$capture_dir/.result.XXXXXX" 2>/dev/null)
    if [[ -z "$capture_file" ]]; then
      _ws_error "Could not create a private Workspace picker result."
    elif ! command chmod 600 -- "$capture_file" 2>/dev/null; then
      _ws_error "Could not protect the Workspace picker result."
    elif [[ "$capture_file" != "${capture_file:a}" \
      || "$capture_file" != "${capture_file:A}" \
      || "${capture_file:h}" != "$capture_dir" \
      || ! -f "$capture_file" || -L "$capture_file" ]] \
      || ! zstat -LH capture_file_state -- "$capture_file" 2>/dev/null \
      || (( (capture_file_state[mode] & 8#170000) != 8#100000 \
        || capture_file_state[uid] != EUID \
        || capture_file_state[nlink] != 1 \
        || (capture_file_state[mode] & 8#77) != 0 )); then
      _ws_error "Refusing an unsafe Workspace picker result."
    else
      capture_file_identity="${capture_file_state[device]}:${capture_file_state[inode]}:${capture_file_state[mode]}:${capture_file_state[uid]}:${capture_file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u capture_fd \
        -- "$capture_file" 2>/dev/null; then
        _ws_error "Could not open the Workspace picker result safely."
      else
        _ws_fzf "$@" 1>&$(( capture_fd ))
        fzf_rc=$?
        exec {capture_fd}>&-
        capture_fd=-1

        if ! zstat -LH current_dir_state -- "$capture_dir" 2>/dev/null \
          || [[ "${current_dir_state[device]}:${current_dir_state[inode]}:${current_dir_state[mode]}:${current_dir_state[uid]}" \
            != "$capture_dir_identity" ]] \
          || ! zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$capture_file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > 4 * 1024 * 1024 )); then
          _ws_error "The Workspace picker result changed or is oversized."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$capture_file" 2>/dev/null; then
          _ws_error "Could not read the Workspace picker result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          operation_rc=$fzf_rc
        fi
      fi
    fi
  } always {
    (( capture_fd >= 0 )) && exec {capture_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    if [[ -n "$capture_file" && ( -e "$capture_file" || -L "$capture_file" ) ]]; then
      current_file_state=()
      if [[ -n "$capture_file_identity" \
        && -f "$capture_file" && ! -L "$capture_file" \
        && "${capture_file:a}" == "$capture_file" \
        && "${capture_file:A}" == "$capture_file" \
        && "${capture_file:h}" == "$capture_dir" ]] \
        && zstat -LH current_file_state -- "$capture_file" 2>/dev/null \
        && [[ "${current_file_state[device]}:${current_file_state[inode]}:${current_file_state[mode]}:${current_file_state[uid]}:${current_file_state[nlink]}" \
          == "$capture_file_identity" ]]; then
        command rm -f -- "$capture_file" 2>/dev/null || cleanup_failed=1
      else
        _ws_warn "The Workspace picker result changed; refusing cleanup."
        cleanup_failed=1
      fi
    fi

    current_dir_state=()
    if [[ -d "$capture_dir" && ! -L "$capture_dir" \
      && "${capture_dir:a}" == "$capture_dir" \
      && "${capture_dir:A}" == "$capture_dir" \
      && "${capture_dir:t}" == zdx-ws-fzf.* ]] \
      && zstat -LH current_dir_state -- "$capture_dir" 2>/dev/null \
      && [[ "${current_dir_state[device]}:${current_dir_state[inode]}:${current_dir_state[mode]}:${current_dir_state[uid]}" \
        == "$capture_dir_identity" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_failed=1
    else
      _ws_warn "The Workspace picker directory changed; refusing cleanup."
      cleanup_failed=1
    fi

    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

_ws_fzf_rc_is_cancel() {
  (( ${1:-0} == 1 || ${1:-0} == 130 ))
}

# --- Workspace path and record safety --------------------------------------

# Sets REPLY to a canonical absolute base. The base may not exist yet, but its
# existing ancestors must not resolve through symbolic links.
_ws_validate_base_dir() {
  emulate -L zsh

  local candidate="${1-${WS_BASE_DIR:-}}"
  REPLY=""
  while [[ "$candidate" != "/" && "$candidate" == */ ]]; do
    candidate="${candidate%/}"
  done

  [[ -n "$candidate" ]] || {
    _ws_error "WS_BASE_DIR cannot be empty."
    return 1
  }
  [[ "$candidate" == /* ]] || {
    _ws_error "WS_BASE_DIR must be an absolute path."
    return 1
  }
  [[ "$candidate" != *[[:cntrl:]]* ]] || {
    _ws_error "WS_BASE_DIR contains control characters."
    return 1
  }

  local relative="${candidate#/}"
  local component=""
  for component in "${(@s:/:)relative}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || {
        _ws_error "WS_BASE_DIR must be a canonical path."
        return 1
      }
  done

  local literal="${candidate:a}"
  local resolved="${candidate:A}"
  local home_path="${HOME:a}"
  [[ "$literal" != "/" && "$literal" != "$home_path" ]] || {
    _ws_error "WS_BASE_DIR cannot be the filesystem root or home directory."
    return 1
  }
  [[ "$literal" == "$resolved" ]] || {
    _ws_error "WS_BASE_DIR must not contain symbolic-link components."
    return 1
  }
  if [[ -e "$literal" ]]; then
    [[ -d "$literal" && ! -L "$literal" ]] || {
      _ws_error "WS_BASE_DIR must identify a real directory."
      return 1
    }
  fi

  REPLY="$literal"
  return 0
}

# Accepts exactly `github/<identity>` or `gitlab/<identity>`. Sets REPLY to a
# canonical descendant of WS_BASE_DIR. The destination may be absent so the
# same helper is safe for creation and existing-workspace workflows.
_ws_resolve_workspace() {
  emulate -L zsh

  (( $# == 1 )) || {
    _ws_error "A workspace identifier is required."
    return 2
  }
  local workspace_name="$1"
  REPLY=""

  [[ "$workspace_name" == */* \
    && -n "${workspace_name%%/*}" \
    && -n "${workspace_name#*/}" \
    && "${workspace_name#*/}" != */* ]] || {
    _ws_error "A workspace must use the platform/identity format."
    return 2
  }

  local platform="${workspace_name%%/*}"
  local identity="${workspace_name#*/}"
  case "$platform" in
    github|gitlab) ;;
    *)
      _ws_error "Unsupported workspace platform: $platform"
      return 2
      ;;
  esac
  (( ${#identity} <= 64 )) \
    && [[ "$identity" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
      && "$identity" != "." && "$identity" != ".." ]] || {
    _ws_error "Invalid workspace identity."
    return 2
  }

  local base_reply=""
  _ws_validate_base_dir || return $?
  base_reply="$REPLY"

  local candidate="${base_reply}/${platform}/${identity}"
  local literal="${candidate:a}"
  local resolved="${candidate:A}"
  [[ "$literal" == "$base_reply"/* && "$literal" == "$resolved" ]] || {
    _ws_error "The workspace path must remain a non-symlink descendant of WS_BASE_DIR."
    return 1
  }

  REPLY="$literal"
  return 0
}

_ws_validate_repo_dir() {
  emulate -L zsh

  local workspace_dir="${1:-}"
  local candidate="${2:-}"
  REPLY=""
  [[ -n "$workspace_dir" && -n "$candidate" \
    && -d "$workspace_dir" && ! -L "$workspace_dir" \
    && "${workspace_dir:a}" == "${workspace_dir:A}" ]] || return 1

  local workspace_abs="${workspace_dir:A}"
  local candidate_abs="${candidate:a}"
  local repo_name="${candidate_abs:t}"
  local git_dir="$candidate_abs/.git"
  [[ "${candidate_abs:h}" == "$workspace_abs" \
    && -n "$repo_name" && "$repo_name" != *[[:cntrl:]]* \
    && "$repo_name" != *'|'* \
    && -d "$candidate_abs" && ! -L "$candidate_abs" \
    && "$candidate_abs" == "${candidate_abs:A}" \
    && -d "$git_dir" && ! -L "$git_dir" \
    && "${git_dir:a}" == "${git_dir:A}" ]] || return 1

  REPLY="$candidate_abs"
}

_ws_directory_fingerprint() {
  emulate -L zsh

  local directory="${1:-}"
  REPLY=""
  [[ -n "$directory" && "$directory" == /* \
    && -d "$directory" && ! -L "$directory" \
    && "${directory:a}" == "${directory:A}" ]] || return 1

  local -A directory_state=()
  zmodload zsh/stat 2>/dev/null \
    && zstat -LH directory_state "$directory" 2>/dev/null || return 1
  (( (directory_state[mode] & 8#170000) == 8#040000 \
    && directory_state[uid] == EUID )) || return 1

  REPLY="${directory_state[device]}:${directory_state[inode]}:${directory_state[mode]}:${directory_state[uid]}:${directory_state[nlink]}"
}

_ws_owned_file_fingerprint() {
  emulate -L zsh

  local file_path="${1:-}"
  REPLY=""
  [[ -n "$file_path" && "$file_path" == /* \
    && -f "$file_path" && ! -L "$file_path" \
    && -O "$file_path" ]] || return 1

  local -A file_state=() after_state=()
  zmodload zsh/stat 2>/dev/null \
    && zmodload zsh/system 2>/dev/null \
    && zstat -LH file_state "$file_path" 2>/dev/null || return 1
  (( (file_state[mode] & 8#170000) == 8#100000 \
    && file_state[uid] == EUID \
    && file_state[nlink] == 1 \
    && file_state[size] >= 0 \
    && file_state[size] <= 4 * 1024 * 1024 )) || return 1

  local -i file_fd=-1
  sysopen -r -o nofollow,cloexec -u file_fd -- "$file_path" \
    2>/dev/null || return 1
  local content_fingerprint=""
  {
    content_fingerprint=$(command cksum <&$file_fd 2>/dev/null) \
      || return 1
  } always {
    exec {file_fd}>&-
  }
  local -a checksum_fields=("${(z)content_fingerprint}")
  (( ${#checksum_fields[@]} == 2 )) \
    && [[ "${checksum_fields[1]}" == <-> \
      && "${checksum_fields[2]}" == <-> \
      && "${checksum_fields[2]}" == "${file_state[size]}" ]] || return 1

  zstat -LH after_state "$file_path" 2>/dev/null || return 1
  local before_fingerprint="${file_state[device]}:${file_state[inode]}:${file_state[size]}:${file_state[mtime]}:${file_state[ctime]}:${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
  local after_fingerprint="${after_state[device]}:${after_state[inode]}:${after_state[size]}:${after_state[mtime]}:${after_state[ctime]}:${after_state[mode]}:${after_state[uid]}:${after_state[nlink]}"
  [[ "$after_fingerprint" == "$before_fingerprint" ]] || return 1

  REPLY="${before_fingerprint}:${checksum_fields[1]}"
}

_ws_repo_fingerprint() {
  local workspace_dir="${1:-}"
  local candidate="${2:-}"
  REPLY=""
  _ws_validate_repo_dir "$workspace_dir" "$candidate" || return 1
  local repo_dir="$REPLY"
  local git_dir="$repo_dir/.git"
  local -A repo_state=() git_state=()
  zmodload zsh/stat 2>/dev/null \
    && zstat -H repo_state "$repo_dir" 2>/dev/null \
    && zstat -H git_state "$git_dir" 2>/dev/null || return 1
  REPLY="${repo_state[device]}:${repo_state[inode]}:${git_state[device]}:${git_state[inode]}"
}

# stdout: URL with user information, query, and fragment content redacted.
_ws_redact_remote_url() {
  _git_redact_remote_url "${1:-}"
}

# stdout: one validated `platform/identity` record per line.
_ws_list_workspaces() {
  emulate -L zsh

  local REPLY=""
  _ws_validate_base_dir || return $?
  local base_dir="$REPLY"
  [[ -d "$base_dir" ]] || return 0

  local platform_dir="" identity_dir="" workspace_name="" workspace_dir=""
  for platform_dir in "$base_dir"/*(/N); do
    for identity_dir in "$platform_dir"/*(/N); do
      workspace_name="${platform_dir:t}/${identity_dir:t}"
      REPLY=""
      _ws_resolve_workspace "$workspace_name" 2>/dev/null || continue
      workspace_dir="$REPLY"
      if [[ ( -d "$workspace_dir/.ssh" && ! -L "$workspace_dir/.ssh" ) \
        || ( -f "$workspace_dir/.gitconfig" \
          && ! -L "$workspace_dir/.gitconfig" ) ]]; then
        print -r -- "$workspace_name"
      fi
    done
  done
}

# Sets REPLY to one selected validated `platform/identity` record, or to an
# empty string when the user cancels.
_ws_pick_workspace() {
  REPLY=""
  local prompt="${1:-Select workspace}"
  local workspaces=""
  workspaces=$(_ws_list_workspaces) || return $?

  if [[ -z "$workspaces" ]]; then
    _ws_warn "No workspaces found."
    return 1
  fi

  local selected=""
  local -i fzf_rc=0
  _ws_fzf_capture \
    --height=40% \
    --prompt="$prompt > " \
    --preview='' \
    --preview-window=hidden \
    < <(print -r -- "$workspaces") || fzf_rc=$?
  selected="$REPLY"
  if (( fzf_rc != 0 )); then
    _ws_fzf_rc_is_cancel "$fzf_rc" && return 0
    _ws_error "Unable to select a workspace (status $fzf_rc)."
    return 1
  fi
  [[ -n "$selected" ]] || return 0
  local -a workspace_snapshot=("${(@f)workspaces}")
  _ws_array_contains_literal "$selected" "${workspace_snapshot[@]}" || {
    _ws_error "The selected workspace was not in the current inventory."
    return 1
  }

  _ws_resolve_workspace "$selected" || return $?
  REPLY="$selected"
}

_ws_capture_workspace_selection() {
  _ws_pick_workspace "$@"
}

# stdout: repository owner/path extracted from an HTTPS or SSH remote.
_ws_extract_repo_path() {
  local remote_url="${1:-}"
  remote_url="${remote_url%.git}"
  if [[ "$remote_url" == *:* && "$remote_url" != *://* ]]; then
    print -r -- "${remote_url#*:}"
  elif [[ "$remote_url" == *://* ]]; then
    local remainder="${remote_url#*://}"
    [[ "$remainder" == */* ]] \
      && print -r -- "${remainder#*/}" \
      || print -r -- ""
  else
    print -r -- "$remote_url"
  fi
}

_ws_test_write() {
  local REPLY=""
  _ws_validate_base_dir || return $?
  local base_dir="$REPLY"
  local -a paths=("$HOME/.gitconfig" "$base_dir")
  local target=""
  for target in "${paths[@]}"; do
    if [[ -L "$target" ]]; then
      _ws_error "Path $target must not be a symbolic link."
      return 1
    elif [[ -e "$target" ]]; then
      if [[ ! -w "$target" ]]; then
        _ws_error "Path $target is not writable."
        return 1
      fi
    else
      local parent_dir="${target:h}"
      if [[ ! -d "$parent_dir" || ! -w "$parent_dir" ]]; then
        _ws_error \
          "Path $target does not exist and its parent $parent_dir is not writable."
        return 1
      fi
    fi
  done
  return 0
}

# --- Command menu -----------------------------------------------------------

_ws_menu_validate_fields() {
  local value=""
  for value in "$@"; do
    [[ "$value" != *'|'* \
      && "$value" != *$'\n'* \
      && "$value" != *$'\r'* \
      && "$value" != *$'\0'* ]] || {
      _ws_error "Menu fields cannot contain record delimiters or controls."
      return 2
    }
  done
}

_ws_menu_section() {
  (( $# >= 1 && $# <= 2 )) || {
    _ws_error "A menu section requires a title and optional description."
    return 2
  }
  local title="${1:-}"
  local description="${2:-}"
  [[ -n "$title" ]] || {
    _ws_error "A menu section title cannot be empty."
    return 2
  }
  _ws_menu_validate_fields "$title" "$description" || return $?
  printf '── %s ──|:|%s\n' "$title" "$description"
}

# stdout: comma-separated dependencies for one canonical Workspace command.
_ws_command_dependencies() {
  case "${1:-}" in
    ws-auth)
      print -r -- "git,ssh-keygen,ssh"
      ;;
    ws-create|ws-info|ws-clone|ws-clone-multi|ws-show-key|ws-rotate-key)
      print -r -- "git,ssh-keygen,fzf"
      ;;
    ws-list|ws-doctor|ws-remove)
      print -r -- "git"
      ;;
    ws-repos|ws-migrate)
      print -r -- "git,fzf"
      ;;
    ws-sync|ws-autoclean)
      print -r -- "git,fzf"
      ;;
    ws-test)
      print -r -- "git,ssh-keygen,ssh,fzf"
      ;;
    *)
      return 2
      ;;
  esac
}

_ws_menu_entry() {
  (( $# == 3 )) || {
    _ws_error "A menu entry requires label, command, and description fields."
    return 2
  }
  local label="${1:-}"
  local command_name="${2:-}"
  local description="${3:-}"
  [[ -n "$label" && -n "$command_name" && -n "$description" ]] || {
    _ws_error "Menu entry fields cannot be empty."
    return 2
  }
  [[ "$command_name" =~ '^ws-[a-z0-9-]+$' ]] || {
    _ws_error "Invalid Workspace command token."
    return 2
  }
  _ws_menu_validate_fields "$label" "$command_name" "$description" \
    || return $?

  local dependencies=""
  dependencies=$(_ws_command_dependencies "$command_name") || return 2
  local -a missing=()
  local dependency=""
  for dependency in ${(s:,:)dependencies}; do
    [[ -n "$dependency" ]] || continue
    _ws_check_cmd "$dependency" || missing+=("$dependency")
  done
  (( ${#missing[@]} > 0 )) \
    && label+=" (missing: ${(j:, :)missing})"
  printf '  %s|%s|%s\n' "$label" "$command_name" "$description"
}

_ws_verify_deps() {
  local command_name="${1:-}"
  local dependencies=""
  dependencies=$(_ws_command_dependencies "$command_name") || return 2
  local -a missing=()
  local dependency=""
  for dependency in ${(s:,:)dependencies}; do
    [[ -n "$dependency" ]] || continue
    _ws_check_cmd "$dependency" || missing+=("$dependency")
  done
  if (( ${#missing[@]} > 0 )); then
    _ws_error \
      "Missing ${(j:, :)missing} required by '$command_name'."
    return 1
  fi
  return 0
}

_ws_dispatch() {
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    ws-auth|ws-create|ws-list|ws-info|ws-doctor|ws-clone|ws-clone-multi|\
    ws-sync|ws-repos|ws-migrate|ws-show-key|ws-rotate-key|ws-test|\
    ws-autoclean)
      _ws_verify_deps "$command_name" || return $?
      ;;
    ws-remove)
      # ws-remove owns a complete parser and must parse before dependencies.
      ;;
    :)
      return 0
      ;;
    "")
      _ws_error "A Workspace command is required."
      return 2
      ;;
    *)
      _ws_error "Unknown workspace command: $command_name"
      return 2
      ;;
  esac

  case "$command_name" in
    ws-auth)        ws-auth "$@" ;;
    ws-create)      ws-create "$@" ;;
    ws-list)        ws-list "$@" ;;
    ws-info)        ws-info "$@" ;;
    ws-doctor)      ws-doctor "$@" ;;
    ws-clone)       ws-clone "$@" ;;
    ws-clone-multi) ws-clone-multi "$@" ;;
    ws-sync)        ws-sync "$@" ;;
    ws-repos)       ws-repos "$@" ;;
    ws-migrate)     ws-migrate "$@" ;;
    ws-show-key)    ws-show-key "$@" ;;
    ws-rotate-key)  ws-rotate-key "$@" ;;
    ws-test)        ws-test "$@" ;;
    ws-autoclean)   ws-autoclean "$@" ;;
    ws-remove)      ws-remove "$@" ;;
  esac
}

# --- Temporary module compatibility ----------------------------------------

_tk_list_workspaces()  { _ws_list_workspaces "$@"; }
_tk_pick_workspace() {
  _ws_pick_workspace "$@" || return $?
  [[ -n "$REPLY" ]] && print -r -- "$REPLY"
}
_tk_extract_repo_path(){ _ws_extract_repo_path "$@"; }
_tk_test_write()       { _ws_test_write "$@"; }

typeset -g _WS_COMMON_SOURCED=1
