#!/usr/bin/env zsh
# =============================================================================
# System Common: shared UI, safety, and routing helpers
# =============================================================================
#
# Loaded by sys-menu.zsh before every module under functions/sys/.
# Private helpers only; not a standalone public command.
#

if [[ -n "${_SYS_COMMON_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Logging primitives -----------------------------------------------------

_sys_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

_sys_header()  {
  if _sys_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "${(V)1}" >&2
  else
    printf '\n════ %s ════\n\n' "${(V)1}" >&2
  fi
}
_sys_success() {
  if _sys_color_enabled; then
    printf '\033[1;32m✔ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✔ %s\n' "${(V)1}" >&2
  fi
}
_sys_warn()    {
  if _sys_color_enabled; then
    printf '\033[1;33m⚠ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⚠ %s\n' "${(V)1}" >&2
  fi
}
_sys_info()    {
  if _sys_color_enabled; then
    printf '\033[0;36m➜ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '➜ %s\n' "${(V)1}" >&2
  fi
}
_sys_error()   {
  if _sys_color_enabled; then
    printf '\033[1;31m✘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '✘ %s\n' "${(V)1}" >&2
  fi
}
_sys_dim()     {
  if _sys_color_enabled; then
    printf '\033[0;90m  %s\033[0m\n' "${(V)1}" >&2
  else
    printf '  %s\n' "${(V)1}" >&2
  fi
}
_sys_label()   {
  if _sys_color_enabled; then
    printf "\033[1;37m  %-18s\033[0m %s\n" "${(V)1}" "${(V)2}" >&2
  else
    printf "  %-18s %s\n" "${(V)1}" "${(V)2}" >&2
  fi
}
_sys_blank()   { print -u2 -r -- ""; }

# Render control characters visibly before including external data in UI.
_sys_display_escape() {
  print -r -- "${(V)1}"
}

# --- Prompts ---------------------------------------------------------------

_sys_confirm() {
  local REPLY
  local prompt="$1"
  local selected=""
  if [[ ! -t 0 || ! -t 2 ]]; then
    _sys_error "Interactive confirmation requires a terminal; use the documented --yes flag."
    return 1
  fi

  if command -v fzf &>/dev/null; then
    local -a fzf_options=(
      --height=20%
      --layout=reverse
      --border=rounded
      --pointer='▶'
      --preview=''
      --preview-window=hidden
      --header='Up/Down navigate | Enter confirm | Esc cancel'
      --prompt="${prompt} > "
    )
    if typeset -f _tk_fzf_color_opts &>/dev/null; then
      local theme_option
      theme_option=$(_tk_fzf_color_opts)
      [[ -n "$theme_option" ]] && fzf_options+=("$theme_option")
    fi

    local -i fzf_rc=0
    _sys_fzf_capture "${fzf_options[@]}" \
      < <(printf "No\nYes\n") || fzf_rc=$?
    selected="$REPLY"
    if (( fzf_rc == 0 )); then
      [[ "$selected" == "Yes" ]]
      return $?
    elif (( fzf_rc == 1 || fzf_rc == 130 )); then
      return 1
    fi
    _sys_warn "fzf confirmation failed; using the terminal prompt."
  fi

  local reply
  if _sys_color_enabled; then
    printf "\033[1;33m? %s [y/N]: \033[0m" "$prompt" >&2
  else
    printf "? %s [y/N]: " "$prompt" >&2
  fi
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- Time and string helpers -----------------------------------------------

_sys_format_duration() {
  local elapsed="${1:-0}"
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  printf "%dm %02ds" "$mins" "$secs"
}

_sys_timed() {
  local label="$1"
  shift

  if typeset -f _timed &>/dev/null; then
    _timed "$label" "$@"
  else
    "$@"
  fi
}

# Sets reply to the direct process and every descendant visible in a portable
# pid/ppid snapshot. The direct PID remains available even if ps fails.
_sys_timeout_tree_pids() {
  local root_pid="$1"
  reply=("$root_pid")
  [[ "$root_pid" == <-> ]] || return 2

  local process_output
  process_output=$(command ps -Ao pid=,ppid= 2>/dev/null) || return 0
  local -a process_lines=("${(@f)process_output}")
  local -A selected=(["$root_pid"]=1)
  local -i changed=1 pass=0
  local process_line
  local -a process_fields=()
  local process_pid parent_pid

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

  reply=("${(k)selected}")
}

_sys_timeout_signal_tree() {
  local root_pid="$1"
  local signal_name="$2"
  local -a reply=()
  _sys_timeout_tree_pids "$root_pid" || reply=("$root_pid")
  (( ${#reply[@]} > 0 )) \
    && builtin kill "-$signal_name" "${reply[@]}" 2>/dev/null
  return 0
}

_sys_run_with_timeout() {
  local seconds="${1:-0}"
  shift
  [[ "$seconds" == <-> && ${#seconds} -le 6 ]] || return 2

  if command -v timeout &>/dev/null && (( seconds > 0 )); then
    # GNU coreutils and current BusyBox both support -k. Avoid capability
    # probes such as `timeout --help`: the probe itself could block forever.
    command timeout -k 2s "${seconds}s" "$@"
  elif command -v gtimeout &>/dev/null && (( seconds > 0 )); then
    command gtimeout -k 2s "${seconds}s" "$@"
  elif (( seconds > 0 )); then
    setopt LOCAL_OPTIONS NO_MONITOR
    local timeout_marker
    timeout_marker=$(umask 077; command mktemp \
      "${TMPDIR:-/tmp}/zdx-timeout.XXXXXX") || return 1
    local -i command_pid watchdog_pid command_rc=0 timed_out=0

    "$@" &
    command_pid=$!
    (
      if zmodload zsh/zselect 2>/dev/null; then
        zselect -t "$(( seconds * 100 ))" 2>/dev/null || true
      else
        command sleep "$seconds"
      fi
      print -r -- "expired" > "$timeout_marker" 2>/dev/null || exit 1
      _sys_timeout_signal_tree "$command_pid" TERM
      if zmodload zsh/zselect 2>/dev/null; then
        zselect -t 100 2>/dev/null || true
      else
        command sleep 1
      fi
      _sys_timeout_signal_tree "$command_pid" KILL
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
        _sys_timeout_signal_tree "$command_pid" TERM
        wait "$command_pid" 2>/dev/null
      fi
      command rm -f "$timeout_marker" 2>/dev/null
    }

    (( timed_out )) && return 124
    return $command_rc
  else
    "$@"
  fi
}

# stdout: command output only when it completes within both configured bounds.
_sys_run_bounded_probe() {
  local seconds="${1:-0}"
  local max_bytes="${2:-0}"
  shift 2
  [[ "$seconds" == <-> && ${#seconds} -le 6 \
    && "$max_bytes" == <-> && ${#max_bytes} -le 9 ]] || return 2
  (( seconds > 0 && max_bytes > 0 && max_bytes <= 134217728 )) || return 2

  local capture_file
  capture_file=$(umask 077; command mktemp \
    "${TMPDIR:-/tmp}/zdx-bounded-probe.XXXXXX") || return 1

  local probe_rc=0
  {
    _sys_run_with_timeout "$seconds" "$@" \
      | command head -c "$(( max_bytes + 1 ))" > "$capture_file"
    local -a probe_status=("${pipestatus[@]}")
    (( probe_status[2] == 0 )) || return "${probe_status[2]}"

    local captured_bytes
    captured_bytes=$(command wc -c < "$capture_file" 2>/dev/null) \
      || return 1
    captured_bytes="${captured_bytes//[[:space:]]/}"
    [[ "$captured_bytes" == <-> ]] || return 1
    (( captured_bytes <= max_bytes )) || return 1
    (( probe_status[1] == 0 )) || return "${probe_status[1]}"

    command cat "$capture_file"
  } always {
    probe_rc=$?
    command rm -f "$capture_file" 2>/dev/null
  }
  return $probe_rc
}

_sys_resolve_privilege_prefix() {
  reply=()
  if (( EUID == 0 )) || _sys_has_capability "privilege:direct"; then
    return 0
  fi
  if _sys_has_capability "privilege:sudo" && command -v sudo &>/dev/null; then
    reply=(sudo)
    case "${_SYS_PRIVILEGE_NONINTERACTIVE:-0}" in
      0) ;;
      1) reply+=(-n) ;;
      *)
        _sys_error "Invalid private privilege mode."
        return 2
        ;;
    esac
    return 0
  fi
  _sys_error "No supported privilege path is available."
  return 1
}

_sys_repeat_char() {
  local char="${1:--}" count="${2:-0}" out=""
  while (( count > 0 )); do
    out+="$char"
    count=$((count - 1))
  done
  print -r -- "$out"
}

typeset -gr _SYS_MAX_INTEGER=9223372036854775807

# Normalizes an unsigned decimal into REPLY without entering arithmetic until
# its value is proven to fit the configured maximum.
_sys_normalize_uint() {
  local LC_ALL=C
  local value="${1:-}"
  local maximum="${2:-$_SYS_MAX_INTEGER}"
  [[ "$value" == <-> && "$maximum" == <-> ]] || return 2
  while [[ ${#value} -gt 1 && "$value" == 0* ]]; do
    value="${value#0}"
  done
  if (( ${#value} > ${#maximum} )) \
    || { (( ${#value} == ${#maximum} )) && [[ "$value" > "$maximum" ]]; }; then
    return 2
  fi
  REPLY="$value"
}

# --- Dependency and archive primitives ---------------------------------------

# Fail closed with the dependency name and a safe next step when a required
# external tool is absent. Usage: _sys_require_commands <tool>...
_sys_require_commands() {
  local -a missing=()
  local tool
  for tool in "$@"; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done
  (( ${#missing[@]} == 0 )) && return 0
  _sys_error "Missing required dependency: ${(j:, :)missing}."
  _sys_dim "Install ${(j:, :)missing} with the package manager for this host."
  return 1
}

_sys_require_sha256_tool() {
  command -v sha256sum &>/dev/null || command -v shasum &>/dev/null || {
    _sys_error "Missing required dependency: sha256sum or shasum."
    _sys_dim "Install coreutils or perl with the package manager for this host."
    return 1
  }
}

# stdout: lowercase SHA-256 hex digest of one file.
_sys_sha256_file() {
  local artifact="$1"
  local digest=""
  if command -v sha256sum &>/dev/null; then
    digest=$(command sha256sum "$artifact" 2>/dev/null)
  elif command -v shasum &>/dev/null; then
    digest=$(command shasum -a 256 "$artifact" 2>/dev/null)
  else
    _sys_error "A SHA-256 tool (sha256sum or shasum) is required."
    return 1
  fi
  digest="${digest%%[[:space:]]*}"
  [[ "$digest" =~ '^[[:xdigit:]]{64}$' ]] || return 1
  print -r -- "${digest:l}"
}

# REPLY: expanded byte count of a gzip or xz tar archive, bounded by the
# caller's limit. Status 2 means the content expands beyond that limit.
_sys_tar_measure_expanded_bytes() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local archive="$1"
  local max_expanded_bytes="$2"
  local compression="${3:-gzip}"
  local extract_flags=""
  case "$compression" in
    gzip) extract_flags="-xOzf" ;;
    xz)   extract_flags="-xOJf" ;;
    *)    return 1 ;;
  esac
  local measurement=""
  local -i pipeline_rc=0

  measurement=$(
    _sys_run_with_timeout 120 tar "$extract_flags" "$archive" 2>/dev/null \
      | command head -c "$(( max_expanded_bytes + 1 ))" \
      | command wc -c
  )
  pipeline_rc=$?
  measurement="${measurement//[[:space:]]/}"
  [[ "$measurement" =~ '^[0-9]+$' ]] || return 1
  REPLY="$measurement"
  (( measurement <= max_expanded_bytes )) || return 2
  (( pipeline_rc == 0 ))
}

# --- Safe npm global install -------------------------------------------------

_sys_npm_install_g() {
  local pkg="$1"
  local expected_prefix="${2:-}" npm_program="${3:-npm}"
  [[ "$pkg" =~ '^[A-Za-z0-9@][A-Za-z0-9@/_.+-]{0,127}$' \
    && "$pkg" != *'..'* ]] || {
    _sys_error "Invalid npm package identifier."
    return 2
  }

  if [[ "$npm_program" != npm ]] \
    && [[ "$npm_program" != /* || "$npm_program" == *[[:cntrl:]]* \
      || ! -f "$npm_program" || ! -x "$npm_program" ]]; then
    _sys_error "The selected npm executable is unavailable."
    return 1
  fi
  local npm_prefix
  npm_prefix=$(
    _sys_run_bounded_probe 3 65536 "$npm_program" config get prefix 2>/dev/null
  ) || return 1
  [[ "$npm_prefix" == /* && "$npm_prefix" != *$'\n'* \
    && "$npm_prefix" != *$'\r'* && "$npm_prefix" != *$'\t'* \
    && "$npm_prefix" != *'|'* && "$npm_prefix" != "/" ]] || {
    _sys_error "npm returned an unsafe global prefix."
    return 1
  }
  if [[ -n "$expected_prefix" && "$npm_prefix" != "$expected_prefix" ]]; then
    _sys_error "The npm global prefix changed before installation."
    return 1
  fi

  local prefix_cursor="" prefix_component
  for prefix_component in "${(@s:/:)npm_prefix}"; do
    [[ -n "$prefix_component" ]] || continue
    prefix_cursor+="/$prefix_component"
    [[ ! -L "$prefix_cursor" ]] || {
      _sys_error "The npm global prefix crosses a symbolic link."
      return 1
    }
  done
  if [[ ! -d "$npm_prefix" || ! -O "$npm_prefix" \
    || ! -w "$npm_prefix" ]]; then
    _sys_error "The npm global prefix is not user-writable as an owner-bound directory: $(_sys_display_escape "$npm_prefix")"
    _sys_dim "Refusing to run a downloaded npm package through sudo."
    _sys_dim "Configure a user-owned npm prefix or use a trusted OS package manager."
    return 1
  fi

  local -a prefix_arguments=()
  [[ -n "$expected_prefix" ]] && prefix_arguments=(--prefix "$expected_prefix")
  _sys_run_logged npm-global command env npm_config_fetch_retries=0 \
    "$npm_program" install -g "${prefix_arguments[@]}" -- "$pkg"
}

# --- Output capture helper --------------------------------------------------

# Run "$@" with all output captured in a private temp directory and surface a
# bounded, visibly escaped tail on failure. Returns the command's exit code.
# Usage: _sys_run_logged <label> <cmd> [args...]
_sys_run_logged() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local label="${1:-cmd}"; shift
  (( $# > 0 )) || return 2
  local max_capture_bytes="${SYS_COMMAND_CAPTURE_MAX_BYTES:-262144}"
  [[ "$max_capture_bytes" =~ '^[0-9]+$' \
    && ${#max_capture_bytes} -le 8 ]] \
    && (( max_capture_bytes >= 4096 && max_capture_bytes <= 16777216 )) \
    || {
      _sys_error "SYS_COMMAND_CAPTURE_MAX_BYTES must be between 4096 and 16777216."
      return 2
    }
  local temp_root="${TMPDIR:-/tmp}"
  local capture_dir
  capture_dir=$(command mktemp -d "$temp_root/zdx-sys-command.XXXXXX") \
    || return 1
  [[ -d "$capture_dir" && ! -L "$capture_dir" \
    && "${capture_dir:h:A}" == "${temp_root:A}" \
    && "${capture_dir:t}" == zdx-sys-command.* ]] || {
      [[ -d "$capture_dir" && ! -L "$capture_dir" ]] \
        && command rm -rf "$capture_dir" 2>/dev/null
      return 1
    }
  local capture_log="$capture_dir/output.log"
  local -i command_rc=0
  local previous_umask
  previous_umask=$(umask)

  {
    umask 077
    command chmod 700 "$capture_dir" 2>/dev/null || return 1
    # A long silent step is indistinguishable from a hang, so announce that
    # this command runs with its output captured privately.
    _sys_dim \
      "Running $(_sys_display_escape "$label"); output is captured and shown only on failure."
    "$@" </dev/null 2>&1 \
      | command tail -c "$max_capture_bytes" >"$capture_log"
    local -a pipeline_status=("${pipestatus[@]}")
    command_rc="${pipeline_status[1]:-1}"
    (( command_rc == 0 && ${pipeline_status[2]:-1} != 0 )) \
      && command_rc="${pipeline_status[2]}"
    if (( command_rc != 0 )) && [[ -s "$capture_log" ]]; then
      _sys_dim "Error details for $(_sys_display_escape "$label"):"
      local captured_line normalized_line
      while IFS= read -r captured_line || [[ -n "$captured_line" ]]; do
        normalized_line="${captured_line:l}"
        if [[ "$normalized_line" == *password* \
          || "$normalized_line" == *token* \
          || "$normalized_line" == *secret* \
          || "$normalized_line" == *authorization* \
          || "$normalized_line" == *credential* \
          || "$normalized_line" == *api-key* \
          || "$normalized_line" == *api_key* \
          || "$normalized_line" == *apikey* \
          || "$normalized_line" == *signature* \
          || "$normalized_line" == *cookie* ]]; then
          _sys_dim "  [redacted potentially sensitive output]"
        else
          _sys_dim "  $(_sys_display_escape "$captured_line")"
        fi
      done < <(command tail -n 80 "$capture_log" 2>/dev/null)
    fi
  } always {
    command rm -rf "$capture_dir" 2>/dev/null
    umask "$previous_umask"
  }
  return $command_rc
}

# Keep Homebrew's detached analytics transport out of suite-owned probes and
# mutations. In addition to avoiding unnecessary telemetry, this prevents a
# short-lived analytics client from being mistaken for package-manager work.
# ZDX also disables Homebrew's curl-layer retries. Homebrew may retain separate
# version-specific download-queue behavior outside that public setting.
_sys_brew() {
  command env HOMEBREW_CURL_RETRIES=0 HOMEBREW_NO_ANALYTICS=1 brew "$@"
}

# Sets REPLY to a bounded, display-safe owner description and returns 0 only
# when an APT-family process is currently active. Homebrew performs its own
# resource-lock arbitration; process-name scans cannot establish a Brew lock.
_sys_package_manager_busy() {
  local backend="${1:-}"
  REPLY=""
  case "$backend" in
    apt)
      command -v apt-get &>/dev/null || return 1
      local -a process_names=(
        unattended-upgr
        unattended-upgrade
        apt.systemd.dai
        apt.systemd.daily
        apt
        apt-get
        dpkg
      )
      local process_name process_pid
      for process_name in "${process_names[@]}"; do
        process_pid=$(command pgrep -o -x "$process_name" 2>/dev/null) \
          || continue
        [[ "$process_pid" == <-> \
          && "$process_pid" != "$$" && "$process_pid" != "$PPID" ]] \
          || continue
        REPLY="$process_name (PID $process_pid)"
        return 0
      done
      return 1
      ;;
    brew)
      return 1
      ;;
    *)
      return 2
      ;;
  esac
}

_sys_test_pkg_manager() {
  local backend="${1:-all}"
  [[ "$backend" == "all" || "$backend" == "apt" || "$backend" == "brew" ]] \
    || return 2

  if [[ "$backend" == "all" || "$backend" == "apt" ]] \
    && command -v apt-get &>/dev/null; then
    local REPLY
    if _sys_package_manager_busy apt; then
      _sys_warn \
        "An APT-family process is active: $(_sys_display_escape "$REPLY")."
      _sys_warn \
        "Lock ownership is unknown; cleanup fails closed without waiting or signaling it."
      return 1
    fi
  fi

  # Homebrew locks concrete resources itself. Never infer a lock from an argv
  # substring: its detached analytics curl legitimately contains "Linuxbrew".
  return 0
}

# Advisory binary dependencies used only to annotate menu rows. Public
# commands own the authoritative dependency and capability checks after
# parsing, so a missing tool is reported by the command itself.
_sys_cmd_deps() {
  case "$1" in
    update-apt)         print -r -- "apt-get" ;;
    update-brew)        print -r -- "brew" ;;
    update-gcloud)      print -r -- "gcloud" ;;
    update-awscli)      print -r -- "" ;;
    update-repomix)     print -r -- "node,npm" ;;
    update-starship)    print -r -- "starship" ;;
    update-fzf)         print -r -- "fzf" ;;
    update-omz)         print -r -- "git" ;;
    update-zsh-plugins) print -r -- "git" ;;
    update-uv-system)   print -r -- "uv" ;;
    update-pipx)        print -r -- "pipx" ;;
    update-rust)        print -r -- "rustup" ;;
    update-hermes)      print -r -- "" ;;
    sys-backup-dots)    print -r -- "tar" ;;
    sys-restore-dots)   print -r -- "tar" ;;
    sys-fonts)          print -r -- "" ;;
    sys-plugins)        print -r -- "" ;;
    sys-processes)      print -r -- "ps" ;;
    *)                  print -r -- "" ;;
  esac
}

# --- Menu helpers (canonical: args = output positions) ----------------------

_sys_menu_validate_fields() {
  local field
  for field in "$@"; do
    if [[ "$field" == *'|'* || "$field" == *$'\n'* \
      || "$field" == *$'\r'* || "$field" == *$'\0'* ]]; then
      _sys_error \
        "Invalid menu field: pipe, LF, CR, and NUL characters are not allowed."
      return 2
    fi
  done
}

_sys_menu_missing_requirements() {
  local command_name="$1"
  local -a missing=()
  local deps dep

  deps=$(_sys_cmd_deps "$command_name")
  if [[ -n "$deps" ]]; then
    for dep in ${(s:,:)deps}; do
      command -v "$dep" &>/dev/null || missing+=("$dep")
    done
  fi

  case "$command_name" in
    update-node)
      if ! builtin whence -p fnm &>/dev/null; then
        if [[ -d "${NVM_DIR:-$HOME/.nvm}" ]]; then
          command -v nvm &>/dev/null || missing+=("loaded nvm")
        else
          missing+=("fnm or nvm")
        fi
      fi
      ;;
    update-omz)
      if [[ -z "${ZSH:-}" \
        || ( ! -e "$ZSH/.git" && ! -L "$ZSH/.git" ) ]]; then
        missing+=("Oh My Zsh Git checkout")
      fi
      ;;
    update-snap|clean-snaps)
      _sys_has_capability "runtime:snapd" || missing+=("snapd")
      ;;
    clean-journal)
      _sys_has_capability "service:systemd" || missing+=("systemd")
      ;;
    sys-services)
      _sys_has_capability "service:unavailable" \
        && missing+=("systemd or launchd")
      ;;
    sys-processes)
      _sys_has_capability "process:unavailable" \
        && missing+=("procps or BSD ps")
      ;;
    sys-ports)
      _sys_has_capability "ports:unavailable" && missing+=("lsof or ss")
      ;;
    sys-backup-dots|sys-restore-dots)
      if ! command -v sha256sum &>/dev/null \
        && ! command -v shasum &>/dev/null; then
        missing+=("sha256sum or shasum")
      fi
      ;;
    sys-fonts)
      _sys_has_capability "fonts:unavailable" \
        && missing+=("user-font backend")
      command -v curl &>/dev/null || missing+=("curl")
      command -v tar &>/dev/null || missing+=("tar with xz")
      if ! command -v sha256sum &>/dev/null \
        && ! command -v shasum &>/dev/null; then
        missing+=("sha256sum or shasum")
      fi
      ;;
  esac

  (( ${#missing[@]} > 0 )) && print -r -- "${(j:, :)missing}"
  return 0
}

_sys_menu_section() {
  (( $# >= 1 && $# <= 2 )) || {
    _sys_error "A menu section requires a title and optional description."
    return 2
  }

  local title="${1:-}"
  local description="${2:-}"
  [[ -n "$title" ]] || {
    _sys_error "A menu section title cannot be empty."
    return 2
  }
  _sys_menu_validate_fields "$title" "$description" || return $?

  printf "── %s ──|:|%s\n" "$title" "$description"
}

_sys_menu_entry() {
  (( $# == 3 )) || {
    _sys_error "A menu entry requires label, command, and description fields."
    return 2
  }

  local label="${1:-}"
  local command_name="${2:-}"
  local description="${3:-}"
  if [[ -z "$label" || -z "$command_name" || -z "$description" ]]; then
    _sys_error "Menu entry fields cannot be empty."
    return 2
  fi
  _sys_menu_validate_fields "$label" "$command_name" "$description" || return $?

  local missing
  missing=$(_sys_menu_missing_requirements "$command_name") || return $?

  if [[ -n "$missing" ]]; then
    printf "  %s (missing: %s)|%s|%s\n" \
      "$label" "$missing" "$command_name" "$description"
  else
    printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
  fi
}

# --- fzf preset for the sys suite -------------------------------------------

_sys_temp_parent_safe() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local temp_parent="${1:-}"
  REPLY=""

  while [[ "$temp_parent" != "/" && "$temp_parent" == */ ]]; do
    temp_parent="${temp_parent%/}"
  done
  [[ -n "$temp_parent" && "$temp_parent" == /* \
    && "$temp_parent" == "${temp_parent:a}" \
    && "$temp_parent" == "${temp_parent:A}" \
    && -d "$temp_parent" && ! -L "$temp_parent" ]] || return 1

  local -A root_state=() parent_state=()
  zstat -LH root_state -- / 2>/dev/null \
    && zstat -LH parent_state -- "$temp_parent" 2>/dev/null || return 1
  if (( parent_state[uid] == EUID \
    && (parent_state[mode] & 8#22) == 0 )); then
    :
  elif (( parent_state[uid] == root_state[uid] \
    && (parent_state[mode] & 8#1000) != 0 \
    && (parent_state[mode] & 8#2) != 0 )); then
    :
  else
    return 1
  fi
  REPLY="$temp_parent"
}

_sys_fzf() {
  local -a options=(
    --height=80%
    --layout=reverse
    --border=rounded
    --delimiter='[|]'
    --with-nth=1
    --pointer='▶'
    --preview='case {2} in :) printf "%s\n" {3} ;; *) printf "Command: %s\n\n%s\n" {2} {3} ;; esac'
    --preview-window='down:4:wrap'
  )

  options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1')

  if typeset -f _tk_fzf_color_opts &>/dev/null; then
    local theme_option
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

# Run fzf synchronously in the terminal foreground and capture only its
# selection stdout in one private, bounded, invocation-owned result file.
_sys_fzf_capture() {
  emulate -L zsh
  REPLY=""
  zmodload zsh/stat zsh/system 2>/dev/null || {
    _sys_error "Zsh file-descriptor support is required for System pickers."
    return 125
  }
  _sys_temp_parent_safe "${TMPDIR:-/tmp}" || {
    _sys_error "Refusing an unsafe temporary root for System pickers."
    return 125
  }
  local temp_parent="$REPLY"

  local picker_result_file=""
  picker_result_file=$(umask 077; command mktemp \
    "${temp_parent%/}/zdx-sys-fzf.XXXXXX" 2>/dev/null) || {
    _sys_error "Could not create a private System picker result."
    return 125
  }

  local selection="" file_identity=""
  local -i write_fd=-1 read_fd=-1
  local -i fzf_rc=125 operation_rc=125 cleanup_failed=0
  local -A file_state=() current_file_state=()

  {
    if [[ "$picker_result_file" != "${picker_result_file:a}" \
      || "$picker_result_file" != "${picker_result_file:A}" \
      || "${picker_result_file:h}" != "$temp_parent" \
      || "${picker_result_file:t}" != zdx-sys-fzf.* \
      || ! -f "$picker_result_file" || -L "$picker_result_file" ]] \
      || ! zstat -LH file_state -- "$picker_result_file" 2>/dev/null \
      || (( file_state[uid] != EUID || file_state[nlink] != 1 \
        || (file_state[mode] & 8#77) != 0 \
        || (file_state[mode] & 8#170000) != 8#100000 \
        || file_state[size] != 0 )); then
      _sys_error "Refusing an unsafe System picker result."
    else
      file_identity="${file_state[device]}:${file_state[inode]}:"\
"${file_state[mode]}:${file_state[uid]}:${file_state[nlink]}"
      if ! sysopen -w -o nofollow,cloexec -u write_fd \
        -- "$picker_result_file" 2>/dev/null; then
        _sys_error "Could not open the System picker result safely."
      else
        _sys_fzf "$@" 1>&$(( write_fd ))
        fzf_rc=$?
        exec {write_fd}>&-
        write_fd=-1

        if ! zstat -LH current_file_state -- "$picker_result_file" 2>/dev/null \
          || [[ "${current_file_state[device]}:"\
"${current_file_state[inode]}:${current_file_state[mode]}:"\
"${current_file_state[uid]}:${current_file_state[nlink]}" \
            != "$file_identity" ]] \
          || (( current_file_state[size] < 0 \
            || current_file_state[size] > 65536 )); then
          _sys_error "The System picker result changed or exceeded its limit."
        elif ! sysopen -r -o nofollow,cloexec -u read_fd \
          -- "$picker_result_file" 2>/dev/null; then
          _sys_error "Could not read the System picker result safely."
        else
          selection=$(<&$(( read_fd )))
          exec {read_fd}>&-
          read_fd=-1
          if (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
            _sys_error "A failed System picker returned unexpected data."
            selection=""
          else
            operation_rc=$fzf_rc
          fi
        fi
      fi
    fi
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    (( read_fd >= 0 )) && exec {read_fd}>&-

    current_file_state=()
    if [[ -n "$file_identity" \
      && -f "$picker_result_file" && ! -L "$picker_result_file" \
      && "${picker_result_file:h}" == "$temp_parent" ]] \
      && zstat -LH current_file_state -- "$picker_result_file" 2>/dev/null \
      && [[ "${current_file_state[device]}:"\
"${current_file_state[inode]}:${current_file_state[mode]}:"\
"${current_file_state[uid]}:${current_file_state[nlink]}" \
        == "$file_identity" ]]; then
      command rm -f -- "$picker_result_file" 2>/dev/null || cleanup_failed=1
    else
      cleanup_failed=1
    fi
    (( cleanup_failed == 0 )) || operation_rc=125
  }

  REPLY="$selection"
  return $operation_rc
}

# --- Dispatch (case-based; arms ARE the allowlist) --------------------------

_sys_dispatch_prepare() {
  # Public functions own their grammar and perform dependency or capability
  # checks only after parsing. This hook must remain probe-free so nested and
  # direct invocation return the same parser status.
  (( $# >= 1 )) || return 2
  return 0
}

_sys_dispatch() {
  local -i _SYS_DISPATCH_CAPABILITIES_FRESH=0
  local -i _SYS_DISPATCH_CAPABILITIES_PENDING=1
  local command_name="${1:-}"
  shift 2>/dev/null || true

  case "$command_name" in
    update-system)
      _sys_dispatch_prepare "$command_name" "$@" && update-system "$@" ;;
    update-apt)
      _sys_dispatch_prepare "$command_name" "$@" && update-apt "$@" ;;
    update-brew)
      _sys_dispatch_prepare "$command_name" "$@" && update-brew "$@" ;;
    update-snap)
      _sys_dispatch_prepare "$command_name" "$@" && update-snap "$@" ;;
    update-gcloud)
      _sys_dispatch_prepare "$command_name" "$@" && update-gcloud "$@" ;;
    update-awscli)
      _sys_dispatch_prepare "$command_name" "$@" && update-awscli "$@" ;;
    update-repomix)
      _sys_dispatch_prepare "$command_name" "$@" && update-repomix "$@" ;;
    update-starship)
      _sys_dispatch_prepare "$command_name" "$@" && update-starship "$@" ;;
    update-fzf)
      _sys_dispatch_prepare "$command_name" "$@" && update-fzf "$@" ;;
    update-omz)
      _sys_dispatch_prepare "$command_name" "$@" && update-omz "$@" ;;
    update-zsh-plugins)
      _sys_dispatch_prepare "$command_name" "$@" \
        && update-zsh-plugins "$@" ;;
    update-uv-system)
      _sys_dispatch_prepare "$command_name" "$@" && update-uv-system "$@" ;;
    update-pipx)
      _sys_dispatch_prepare "$command_name" "$@" && update-pipx "$@" ;;
    update-node)
      _sys_dispatch_prepare "$command_name" "$@" && update-node "$@" ;;
    update-rust)
      _sys_dispatch_prepare "$command_name" "$@" && update-rust "$@" ;;
    update-hermes)
      _sys_dispatch_prepare "$command_name" "$@" && update-hermes "$@" ;;
    clean-system)
      _sys_dispatch_prepare "$command_name" "$@" && clean-system "$@" ;;
    clean-system-quick)
      _sys_dispatch_prepare "$command_name" "$@" && clean-system-quick "$@" ;;
    clean-system-deep)
      _sys_dispatch_prepare "$command_name" "$@" && clean-system-deep "$@" ;;
    clean-journal)
      _sys_dispatch_prepare "$command_name" "$@" && clean-journal "$@" ;;
    clean-snaps)
      _sys_dispatch_prepare "$command_name" "$@" && clean-snaps "$@" ;;
    sys-info)
      _sys_dispatch_prepare "$command_name" "$@" && sys-info "$@" ;;
    sys-health)
      _sys_dispatch_prepare "$command_name" "$@" && sys-health "$@" ;;
    sys-startup)
      _sys_dispatch_prepare "$command_name" "$@" && sys-startup "$@" ;;
    sys-path)
      _sys_dispatch_prepare "$command_name" "$@" && sys-path "$@" ;;
    sys-aliases)
      _sys_dispatch_prepare "$command_name" "$@" && sys-aliases "$@" ;;
    sys-backup-dots)
      _sys_dispatch_prepare "$command_name" "$@" && sys-backup-dots "$@" ;;
    sys-restore-dots)
      _sys_dispatch_prepare "$command_name" "$@" && sys-restore-dots "$@" ;;
    sys-fonts)
      _sys_dispatch_prepare "$command_name" "$@" && sys-fonts "$@" ;;
    sys-telemetry)
      _sys_dispatch_prepare "$command_name" "$@" && sys-telemetry "$@" ;;
    sys-plugins)
      _sys_dispatch_prepare "$command_name" "$@" && sys-plugins "$@" ;;
    sys-ports)
      _sys_dispatch_prepare "$command_name" "$@" && sys-ports "$@" ;;
    sys-services)
      _sys_dispatch_prepare "$command_name" "$@" && sys-services "$@" ;;
    sys-processes)
      _sys_dispatch_prepare "$command_name" "$@" && sys-processes "$@" ;;
    :)                  return 0 ;;
    *)
      _sys_error "Unknown command: $command_name"
      return 2
      ;;
  esac
}

typeset -g _SYS_COMMON_SOURCED=1
