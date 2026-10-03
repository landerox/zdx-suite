#!/usr/bin/env zsh
# =============================================================================
# System Common: shared UI, safety, privilege, and routing helpers
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
  if (( ${+functions[_zdx_ui_heading]} )); then
    _zdx_ui_heading "$1"
    return
  fi
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
# Key-value line; the core service owns its layout (docs/output-spec.md).
_sys_label()   {
  if (( ${+functions[_zdx_ui_label]} )); then
    _zdx_ui_label "${1-}" "${2-}"
    return
  fi
  local key="${1%:}:"
  if _sys_color_enabled; then
    printf "  \033[1m%-18s\033[0m %s\n" "${(V)key}" "${(V)2}" >&2
  else
    printf "  %-18s %s\n" "${(V)key}" "${(V)2}" >&2
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
      print -r -- "expired" >| "$timeout_marker" 2>/dev/null || exit 1
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
      | command head -c "$(( max_bytes + 1 ))" >| "$capture_file"
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
  # Hash stdin: GNU sha256sum prefixes the digest with "\" when the file name
  # contains a backslash or newline, which would fail the format check below.
  [[ -f "$artifact" && -r "$artifact" ]] || return 1
  if command -v sha256sum &>/dev/null; then
    digest=$(command sha256sum < "$artifact" 2>/dev/null)
  elif command -v shasum &>/dev/null; then
    digest=$(command shasum -a 256 < "$artifact" 2>/dev/null)
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
  _sys_run_logged "npm install -g $pkg" \
    command env npm_config_fetch_retries=0 \
    "$npm_program" install -g "${prefix_arguments[@]}" -- "$pkg"
}

# --- Command output services -------------------------------------------------
# docs/output-spec.md owns the vocabulary and rendering. Each wrapper checks
# the core service at call time and keeps a plain fallback, so a standalone
# source of this suite still works without functions.zsh.

# REPLY: "<count> <noun>". Usage: _sys_count_noun <count> <singular> [plural]
_sys_count_noun() {
  if (( ${+functions[_zdx_count_noun]} )); then
    _zdx_count_noun "$@"
    return
  fi
  local count="${1:-}" singular="${2:-}" plural="${3:-${2:-}s}"
  [[ "$count" == <-> && -n "$singular" ]] || return 2
  if (( count == 1 )); then REPLY="1 $singular"; else REPLY="$count $plural"; fi
}

# REPLY: one display duration. Usage: _sys_duration_label <seconds>
_sys_duration_label() {
  if (( ${+functions[_zdx_format_duration]} )); then
    _zdx_format_duration "${1:-0}"
    return
  fi
  local -i seconds="${${1:-0}%%.*}"
  REPLY="${seconds}s"
}

# Aligned columns from TAB-separated rows; plain lines when a row is rejected.
# Usage: _sys_table [--outcome-column N] <header-tsv> [row-tsv...]
_sys_table() {
  if (( ${+functions[_zdx_ui_table]} )); then
    _zdx_ui_table "$@" && return 0
  fi
  [[ "${1:-}" == --outcome-column ]] && shift 2
  local table_row
  for table_row in "$@"; do
    _sys_dim "${table_row//$'\t'/  }"
  done
}

# Usage: _sys_step_banner <index> <total> <label>
_sys_step_banner() {
  if (( ${+functions[_zdx_ui_step_banner]} )); then
    _zdx_ui_step_banner "$@"
    return
  fi
  _sys_info "Step ${1:-?}/${2:-?}: ${3:-}"
}

# Usage: _sys_step_result <index> <total> <label> <outcome> <detail> <seconds>
_sys_step_result() {
  if (( ${+functions[_zdx_ui_step_result]} )); then
    _zdx_ui_step_result "$@"
    return
  fi
  local REPLY
  _sys_duration_label "${6:-0}"
  _sys_dim "${3:-}: ${4:-done}${5:+ — $5} ($REPLY)"
}

# Runs one step in the current shell; reply=(outcome detail seconds). It never
# redirects the step's input or output.
_sys_step_exec() {
  if (( ${+functions[_zdx_step_exec]} )); then
    _zdx_step_exec "$@"
    return
  fi
  local -i _sys_step_started=$SECONDS _sys_step_rc=0
  "$@" || _sys_step_rc=$?
  local _sys_step_outcome=done
  case $_sys_step_rc in
    0) ;;
    124) _sys_step_outcome=timed-out ;;
    130|143) _sys_step_outcome=interrupted ;;
    *) _sys_step_outcome=failed ;;
  esac
  reply=("$_sys_step_outcome" "" "$(( SECONDS - _sys_step_started ))")
  return $_sys_step_rc
}

# Records a terminal outcome for an enclosing aggregate step, or prints the
# standalone message when there is none. Failure paths normally pass no
# message because the step already printed its diagnostics.
# Usage: _sys_report_result <outcome> <detail> [standalone-message]
_sys_report_result() {
  local outcome="${1:-}" detail="${2:-}" message="${3:-}"
  if (( ${+functions[_zdx_step_report]} )); then
    local -i report_rc=0
    _zdx_step_report "$outcome" "$detail" || report_rc=$?
    (( report_rc == 0 )) && return 0
    (( report_rc == 1 )) || return 2
  fi
  [[ -n "$message" ]] || return 0
  case "$outcome" in
    updated|current|done|passed) _sys_success "$message" ;;
    failed|blocked|interrupted|timed-out) _sys_error "$message" ;;
    *) _sys_info "$message" ;;
  esac
}

# True when the active step slot in this shell already holds a report.
_sys_step_reported() {
  (( ${+functions[_zdx_step_reported]} )) && _zdx_step_reported
}

# Prints a dim detail line only when ZDX_VERBOSE=1.
_sys_verbose_dim() {
  [[ "${ZDX_VERBOSE:-0}" == 1 ]] || return 0
  _sys_dim "${1:-}"
}

# Renders an aggregate summary from "label<TAB>outcome<TAB>seconds<TAB>detail"
# records; seconds may be empty. Usage: _sys_print_step_summary <title> <record>...
_sys_print_step_summary() {
  local title="${1:-Summary}"
  shift
  local REPLY record time_label
  local -a fields=() rows=()
  for record in "$@"; do
    fields=("${(@ps:\t:)record}")
    time_label=""
    if [[ -n "${fields[3]:-}" ]]; then
      _sys_duration_label "${fields[3]}"
      time_label="$REPLY"
    fi
    rows+=("${fields[1]:-}"$'\t'"${fields[2]:-done}"$'\t'"$time_label"$'\t'"${fields[4]:-}")
  done
  _sys_header "$title"
  _sys_table --outcome-column 2 $'Step\tResult\tTime\tDetail' "${rows[@]}"
}

# REPLY: the validated SYS_COMMAND_CAPTURE_MAX_BYTES limit.
_sys_capture_max_bytes() {
  local max_capture_bytes="${SYS_COMMAND_CAPTURE_MAX_BYTES:-262144}"
  if [[ ! "$max_capture_bytes" =~ '^[0-9]{4,8}$' ]] \
    || (( 10#$max_capture_bytes < 4096 \
      || 10#$max_capture_bytes > 16777216 )); then
    _sys_error "SYS_COMMAND_CAPTURE_MAX_BYTES must be between 4096 and 16777216."
    return 2
  fi
  REPLY="$(( 10#$max_capture_bytes ))"
}

# Runs "$@" with closed stdin and its output captured privately. Only a failure
# replays a bounded, escaped, credential-redacted tail; ZDX_VERBOSE=1 streams
# the output live instead. <display> is the readable command announced before
# it runs, never an internal identifier. Returns the command's status.
# Usage: _sys_run_logged <display> <cmd> [args...]
_sys_run_logged() {
  local display="${1:-}" REPLY
  shift
  [[ -n "$display" ]] && (( $# > 0 )) || return 2
  _sys_capture_max_bytes || return 2
  if (( ${+functions[_zdx_run_captured]} )); then
    _zdx_run_captured "$display" "$REPLY" 80 "$@"
    return
  fi
  # Standalone fallback without the core: announce and stream the command.
  _sys_dim "\$ $display"
  ( "$@" ) </dev/null >&2
}

# Like _sys_run_logged, but runs in the current shell so a shell function such
# as nvm can change it. Use it only for commands with small output.
# Usage: _sys_run_logged_here <display> <cmd> [args...]
_sys_run_logged_here() {
  local display="${1:-}" REPLY
  shift
  [[ -n "$display" ]] && (( $# > 0 )) || return 2
  _sys_capture_max_bytes || return 2
  if (( ${+functions[_zdx_run_captured_here]} )); then
    _zdx_run_captured_here "$display" "$REPLY" 80 "$@"
    return
  fi
  _sys_dim "\$ $display"
  "$@" </dev/null >&2
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

# --- Update step primitives ---------------------------------------------------
# Shared by the sys-update*.zsh modules: argument grammars, trusted program and
# owner-bound path validators, and the Darwin Homebrew askpass guard.

# Return 0 and set REPLY to "run" or "help"; invalid arguments return 2.
_sys_update_parse_no_args() {
  local command_name="$1"
  shift
  REPLY="run"
  if (( $# == 0 )); then
    return 0
  fi
  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print -u2 -r -- "Usage: $command_name [-h|--help]"
    REPLY="help"
    return 0
  fi
  _sys_error "Unknown or extra argument for $command_name: $1"
  return 2
}

# Shared grammar for the plan-based updaters: [--dry-run] [-y|--yes] [-h|--help].
# Returns 0 with reply=(dry_run assume_yes), or REPLY="help" after printing
# usage. Unknown or extra arguments return 2 before any probe runs.
_sys_update_parse_plan_flags() {
  local command_name="$1"
  shift
  local -i assume_yes=0 dry_run=0
  REPLY="run"
  reply=()
  while (( $# )); do
    case "$1" in
      -h|--help)
        (( $# == 1 && ! dry_run && ! assume_yes )) || {
          _sys_error "--help accepts no additional options or arguments."
          return 2
        }
        print -u2 -r -- \
          "Usage: $command_name [--dry-run] [-y|--yes] [-h|--help]"
        REPLY="help"
        return 0
        ;;
      --dry-run) dry_run=1 ;;
      -y|--yes)  assume_yes=1 ;;
      *)
        _sys_error "Unknown option for $command_name: $1"
        return 2
        ;;
    esac
    shift
  done
  reply=("$dry_run" "$assume_yes")
  return 0
}

_sys_brew_askpass_program() {
  local program="/usr/bin/false"
  local -A program_state=()
  zmodload zsh/stat 2>/dev/null \
    && [[ -f "$program" && ! -L "$program" && -x "$program" ]] \
    && zstat -H program_state "$program" 2>/dev/null || return 1
  (( program_state[uid] == 0 \
    && program_state[nlink] == 1 \
    && (program_state[mode] & 8#22) == 0 )) || return 1
  REPLY="$program"
}

_sys_update_resolve_trusted_program() {
  local requested_program="${1:-dnf}"
  [[ "$requested_program" == "apt-config" \
    || "$requested_program" == "dnf" \
    || "$requested_program" == "dpkg" \
    || "$requested_program" == "dpkg-query" \
    || "$requested_program" == "env" \
    || "$requested_program" == "zsh" ]] || return 2
  local program
  program=$(whence -p "$requested_program" 2>/dev/null) || return 1
  [[ "$program" == /* && "$program" != *[[:cntrl:]]* ]] || return 1
  program="${program:A}"
  local -A program_state=()
  zmodload zsh/stat 2>/dev/null \
    && [[ -f "$program" && ! -L "$program" && -x "$program" ]] \
    && zstat -H program_state "$program" 2>/dev/null || return 1
  (( program_state[uid] == 0 \
    && (program_state[mode] & 8#22) == 0 )) || return 1
  local -A directory_state=()
  local directory_cursor="" directory_component
  for directory_component in "${(@s:/:)${program:h}}"; do
    [[ -n "$directory_component" ]] || continue
    directory_cursor+="/$directory_component"
    [[ -d "$directory_cursor" && ! -L "$directory_cursor" ]] \
      && zstat -H directory_state "$directory_cursor" 2>/dev/null \
      || return 1
    (( directory_state[uid] == 0 \
      && (directory_state[mode] & 8#22) == 0 )) || return 1
  done
  REPLY="$program"
}

# Validate an existing path below an owner-bound trust root. The trust root and
# every child component must be owned by the current user and must not be a
# symbolic link. Set REPLY to the canonical candidate path on success.
_sys_update_validate_owned_path() {
  local allowed_root="${1:-}"
  local candidate_path="${2:-}"
  local expected_type="${3:-directory}"
  [[ -n "$allowed_root" && -n "$candidate_path" \
    && "$allowed_root" == /* && "$candidate_path" == /* \
    && "$allowed_root" != *[[:cntrl:]]* \
    && "$candidate_path" != *[[:cntrl:]]* \
    && ( "$expected_type" == "directory" \
      || "$expected_type" == "file" ) ]] || return 2

  local root_lexical="${allowed_root:a}"
  local candidate_lexical="${candidate_path:a}"
  [[ -d "$root_lexical" && ! -L "$root_lexical" \
    && -O "$root_lexical" && "${root_lexical:A}" == "$root_lexical" \
    && "$candidate_lexical" == "$root_lexical"/* ]] || return 1

  local relative_path="${candidate_lexical#$root_lexical/}"
  local -a path_components=("${(@s:/:)relative_path}")
  (( ${#path_components[@]} > 0 )) || return 1

  local component current_path="$root_lexical"
  for component in "${path_components[@]}"; do
    [[ -n "$component" && "$component" != "." \
      && "$component" != ".." ]] || return 1
    current_path+="/$component"
    [[ -e "$current_path" || -L "$current_path" ]] || return 1
    [[ ! -L "$current_path" && -O "$current_path" ]] || return 1
  done

  case "$expected_type" in
    directory) [[ -d "$candidate_lexical" ]] || return 1 ;;
    file)      [[ -f "$candidate_lexical" ]] || return 1 ;;
  esac
  REPLY="${candidate_lexical:A}"
}

# --- Privileged update session ------------------------------------------------
# One announced sudo authentication plus an owned, non-interactive timestamp
# refresher, shared by update-apt and the update-system aggregate.

# Small predicate so tests can model an interactive terminal without a PTY.
_sys_update_can_prompt() {
  [[ -t 0 && -t 2 ]]
}

# Report whether an aggregate step can require the shared sudo authorization.
# Homebrew formulae normally remain unprivileged, but macOS casks can delegate
# installer packages to sudo, so the Darwin aggregate keeps the same bounded
# credential alive through that adjacent step as well.
_sys_update_step_requires_privilege() {
  local command_name="${1:-}"
  case "$command_name" in
    update-apt|_sys_update_platform_packages|update-snap)
      return 0
      ;;
    update-brew)
      _sys_has_capability "os:darwin"
      ;;
    *)
      return 1
      ;;
  esac
}

# Authenticate sudo once, announced, when the authorized plan contains a
# privileged package step. The caller scopes a non-interactive timestamp
# refresher to the consecutive package entries. Suite-owned privilege calls use
# sudo -n; Darwin Homebrew receives a fixed failing askpass guard. An unavailable
# credential therefore becomes a visible failure, not a second prompt.
# Advisory only; it never fails the aggregate by itself.
_sys_update_preauthenticate() {
  REPLY=0
  local entry command_name
  local -i privileged=0 darwin_homebrew=0
  for entry in "$@"; do
    command_name="${entry#*;}"
    _sys_update_step_requires_privilege "$command_name" && privileged=1
    [[ "$command_name" == "update-brew" ]] && darwin_homebrew=1
  done
  (( privileged )) || return 0
  (( EUID != 0 )) || return 0
  _sys_has_capability "privilege:sudo" \
    && command -v sudo &>/dev/null || return 0
  if command sudo -n true 2>/dev/null; then
    REPLY=1
    return 0
  fi
  _sys_update_can_prompt || return 0

  _sys_info \
    "Privileged operation: sudo -v (authenticate once for the authorized package steps)"
  _sys_dim "Later ZDX privilege calls use sudo -n."
  if (( darwin_homebrew )) && _sys_has_capability "os:darwin"; then
    _sys_dim \
      "macOS Homebrew cask operations use a fixed non-interactive askpass guard."
  fi
  if command sudo -v >&2; then
    REPLY=1
  else
    _sys_warn \
      "sudo authentication failed; privileged steps will fail without reprompting."
  fi
  return 0
}

# Wait for either a private stop request on the worker's pseudo-terminal or the
# next refresh interval. Status 0 means input is ready; status 1 is a timeout.
_sys_update_sudo_keepalive_wait() {
  zmodload zsh/zselect 2>/dev/null || return 2
  zselect -r 0 -t 3000 2>/dev/null
}

_sys_update_sudo_keepalive_worker() {
  emulate -L zsh
  setopt NO_MONITOR NO_NOTIFY
  local control=""
  local -i refresh_enabled=1 wait_rc=0
  while true; do
    _sys_update_sudo_keepalive_wait
    wait_rc=$?
    if (( wait_rc == 0 )); then
      IFS= read -r control || return 1
      [[ "$control" == "stop" ]] || return 1
      print -r -- "zdx-sudo-keepalive-stopped"
      return 0
    fi
    (( wait_rc == 1 )) || return 1
    if (( refresh_enabled )) \
      && ! command sudo -n -v </dev/null >/dev/null 2>&1; then
      # A failed refresh is never retried. Keep this owned worker alive so its
      # private handle cannot be confused with a later process.
      refresh_enabled=0
    fi
  done
}

# Keep the one authorized sudo timestamp valid only while consecutive package
# entries run. A private zpty handle avoids the caller's interactive job table;
# the stop handshake and zpty deletion retain exact worker ownership.
_sys_update_start_sudo_keepalive() {
  emulate -L zsh
  local authenticated="${1:-0}"
  REPLY=""
  [[ "$authenticated" == 0 || "$authenticated" == 1 ]] || return 2
  (( authenticated && EUID != 0 )) || return 0
  _sys_has_capability "privilege:sudo" \
    && command -v sudo &>/dev/null || return 0
  zmodload zsh/zpty zsh/zselect 2>/dev/null || return 1
  command sudo -n -v </dev/null >/dev/null 2>&1 || return 1

  local keepalive_handle="zdx-sudo-keepalive-${sysparams[pid]:-$$}-${RANDOM}-${RANDOM}"
  [[ "$keepalive_handle" =~ '^zdx-sudo-keepalive-[0-9]+-[0-9]+-[0-9]+$' ]] \
    || return 1
  zpty -b "$keepalive_handle" _sys_update_sudo_keepalive_worker \
    2>/dev/null || return 1
  zpty -t "$keepalive_handle" 2>/dev/null || {
    zpty -d "$keepalive_handle" 2>/dev/null || true
    return 1
  }
  REPLY="$keepalive_handle"
  _sys_verbose_dim \
    "Sudo timestamp refresh is active only for the authorized package entries." \
    || true
  REPLY="$keepalive_handle"
  return 0
}

_sys_update_stop_sudo_keepalive() {
  emulate -L zsh
  local keepalive_handle="${1:-}"
  [[ "$keepalive_handle" \
    =~ '^zdx-sudo-keepalive-[0-9]+-[0-9]+-[0-9]+$' ]] || return 2
  zmodload zsh/zpty zsh/zselect 2>/dev/null || return 1
  if ! zpty -t "$keepalive_handle" 2>/dev/null; then
    zpty -d "$keepalive_handle" 2>/dev/null || true
    return 0
  fi
  zpty -w "$keepalive_handle" stop 2>/dev/null || {
    zpty -d "$keepalive_handle" 2>/dev/null || true
    return 1
  }

  local response="" chunk=""
  local -i attempt=0 acknowledged=0 stopped=0
  while (( ++attempt <= 100 )); do
    chunk=""
    if zpty -r -t "$keepalive_handle" chunk 2>/dev/null; then
      response+="$chunk"
      (( ${#response} <= 1024 )) || break
      [[ "$response" == *"zdx-sudo-keepalive-stopped"* ]] \
        && acknowledged=1
    fi
    if ! zpty -t "$keepalive_handle" 2>/dev/null; then
      stopped=1
      break
    fi
    zselect -t 1 2>/dev/null || true
  done
  zpty -d "$keepalive_handle" 2>/dev/null || return 1
  (( acknowledged && stopped ))
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

  # docs/menu-spec.md: an unavailable action keeps its command field and is
  # marked by a leading circle plus the requirement written in text.
  if [[ -n "$missing" ]]; then
    printf "  ○ %s (missing: %s)|%s|%s\n" \
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

  options+=('--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow')

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
          if (( fzf_rc == 1 )); then
            # No match: fzf still prints an --expect key line, which carries
            # no selection. Treat it as the cancellation it represents.
            selection=""
            operation_rc=$fzf_rc
          elif (( fzf_rc != 0 )) && [[ -n "$selection" ]]; then
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
