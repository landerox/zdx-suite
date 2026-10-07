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
# A check or step that does not apply on this host: the skipped glyph and the
# text, dimmed (docs/output-spec.md).
_sys_not_applicable() {
  if _sys_color_enabled; then
    printf '\033[0;90m⊘ %s\033[0m\n' "${(V)1}" >&2
  else
    printf '⊘ %s\n' "${(V)1}" >&2
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

# Report sub-heading; the core service owns its layout (docs/output-spec.md).
# Usage: _sys_section [--first] <title>
_sys_section() {
  if (( ${+functions[_zdx_ui_section]} )); then
    _zdx_ui_section "$@"
    return
  fi
  local gap=$'\n'
  if [[ "${1:-}" == --first ]]; then
    gap=""
    shift
  fi
  if _sys_color_enabled; then
    printf '%s\033[1m▸ %s\033[0m\n' "$gap" "${(V)${1:-}}" >&2
  else
    printf '%s▸ %s\n' "$gap" "${(V)${1:-}}" >&2
  fi
}

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

# The core _zdx_run_with_timeout owns the portable implementation and its
# status contract (124 on timeout, 2 for invalid arguments). This body remains
# the fallback when the System suite is sourced without the core runtime.
_sys_run_with_timeout() {
  if (( ${+functions[_zdx_run_with_timeout]} )); then
    _zdx_run_with_timeout "$@"
    return
  fi

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
# --merge-stderr also captures the command's stderr within the same bound, for
# tools such as softwareupdate that report their result on stderr.
# Usage: _sys_run_bounded_probe [--merge-stderr] <seconds> <max-bytes> <cmd...>
_sys_run_bounded_probe() {
  local -i merge_stderr=0
  if [[ "${1:-}" == --merge-stderr ]]; then
    merge_stderr=1
    shift
  fi
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
    # pipestatus is read inside each branch: after fi it describes the if.
    local -a probe_status=()
    if (( merge_stderr )); then
      _sys_run_with_timeout "$seconds" "$@" 2>&1 \
        | command head -c "$(( max_bytes + 1 ))" >| "$capture_file"
      probe_status=("${pipestatus[@]}")
    else
      _sys_run_with_timeout "$seconds" "$@" \
        | command head -c "$(( max_bytes + 1 ))" >| "$capture_file"
      probe_status=("${pipestatus[@]}")
    fi
    (( ${#probe_status} == 2 )) || return 1
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
  [[ "${1:-}" == --first ]] && shift
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
  local -i _SYS_STEP_DEPTH=$(( ${_SYS_STEP_DEPTH:-0} + 1 ))
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

# True inside an aggregate step, through the core slot or the standalone
# _sys_step_exec fallback.
_sys_step_active() {
  if (( ${+functions[_zdx_step_active]} )); then
    _zdx_step_active
    return
  fi
  (( ${_SYS_STEP_DEPTH:-0} > 0 ))
}

# One contract for a platform-specific command whose capability is absent on
# this host, such as update-apt on macOS (docs/sys-menu.md): inside an
# aggregate step it reports "skipped: not applicable (<reason>)" and returns 0;
# run directly it names the reason and returns 1, because the command's
# runtime precondition is unmet.
# Usage: _sys_report_not_applicable <command> <reason>
_sys_report_not_applicable() {
  local command_name="${1:-}" reason="${2:-}"
  [[ -n "$command_name" && -n "$reason" ]] || return 2
  if _sys_step_active; then
    _sys_report_result skipped "not applicable ($reason)" \
      "$command_name skipped: not applicable ($reason)."
    return 0
  fi
  _sys_error "$command_name is not applicable on this host: $reason."
  return 1
}

# Prints a dim detail line only when ZDX_VERBOSE=1.
_sys_verbose_dim() {
  [[ "${ZDX_VERBOSE:-0}" == 1 ]] || return 0
  _sys_dim "${1:-}"
}

# Renders an aggregate summary from "label<TAB>outcome<TAB>seconds<TAB>detail"
# records through the core service; seconds may be empty. A nested aggregate
# prints no table (docs/output-spec.md).
# Usage: _sys_print_step_summary <title> <record>...
_sys_print_step_summary() {
  if (( ${+functions[_zdx_ui_step_summary]} )); then
    _zdx_ui_step_summary "$@" && return 0
  fi
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

# --- JSON output ---------------------------------------------------------------
# A read-only command given --json prints exactly one JSON object and a newline
# on stdout, never prompts, and keeps warnings and errors on stderr. Documents
# are built only by jq from --arg values, never by concatenating data into
# JSON text. Scalars travel as strings, and the jq definitions below map an
# empty string to null; lists travel as newline-separated rows of TAB-separated
# fields that the caller has proven free of control characters. num is applied
# only to values already validated as decimal numbers.

typeset -gr _SYS_JSON_DEFS='def str: if . == "" then null else . end;
def num: if . == "" then null else tonumber end;
def flag: if . == "true" then true elif . == "false" then false else null end;
def lines: if . == "" then [] else split("\n") end;
def rows: lines | map(split("\t"));
'

# Status 0 when jq is usable; otherwise names the missing capability on
# stderr and returns 1.
_sys_json_require() {
  _sys_tool_available jq && return 0
  _sys_error "--json requires jq; install it with your package manager (see zdx doctor)."
  return 1
}

# Runs jq without input and prints one compact JSON value.
# Usage: _sys_jq <jq arguments...> <program>
_sys_jq() {
  command jq -cn "$@"
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
# HOMEBREW_NO_ENV_HINTS=1 removes only Homebrew's "Hide these hints" advice;
# its normal output stays visible.
_sys_brew() {
  command env HOMEBREW_CURL_RETRIES=0 HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_ENV_HINTS=1 brew "$@"
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
    update-starship)    print -r -- "starship" ;;
    update-fzf)         print -r -- "fzf" ;;
    update-omz)         print -r -- "git" ;;
    update-zsh-plugins) print -r -- "git" ;;
    update-uv-system)   print -r -- "uv" ;;
    update-pipx)        print -r -- "pipx" ;;
    update-rust)        print -r -- "rustup" ;;
    sys-processes)      print -r -- "ps" ;;
    *)                  print -r -- "" ;;
  esac
}

# True when neither the literal executable path nor the file it resolves to is
# writable by other users.
_sys_tool_program_safe() {
  emulate -L zsh
  local program="${1:-}" candidate
  [[ "$program" == /* && "$program" != *[[:cntrl:]]* ]] || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A program_state=()
  for candidate in "$program" "${program:A}"; do
    program_state=()
    zstat -H program_state -- "$candidate" 2>/dev/null || return 1
    (( (program_state[mode] & 8#2) == 0 )) || return 1
  done
}

# Resolves the executable that the user's own PATH selects for a tool, so a
# tool step and sys-info act on the same program the user runs. REPLY is its
# absolute path. Status 0: usable. 1: not on PATH. 3: present but not used,
# with reply=(<reason>): on WSL a Windows program reached through the
# appended Windows PATH (/mnt/<drive>/...), a world-writable executable, or on
# macOS an Apple Command Line Tools placeholder whose execution would open an
# installation dialog. 2: invalid name.
# Usage: _sys_tool_program <name>
_sys_tool_program() {
  emulate -L zsh
  local tool_name="${1:-}" program=""
  REPLY=""
  reply=()
  [[ -n "$tool_name" && "$tool_name" != */* && "$tool_name" != -* \
    && "$tool_name" != *[[:space:][:cntrl:]]* ]] || return 2
  command -v "$tool_name" &>/dev/null || return 1
  program=$(builtin whence -p -- "$tool_name" 2>/dev/null) || return 1
  [[ "$program" == /* && "$program" != *[[:cntrl:]]* ]] || return 1
  REPLY="$program"
  if _sys_has_capability "environment:wsl" \
    && (( ${+functions[_sys_wsl_windows_program]} )) \
    && _sys_wsl_windows_program "$program"; then
    reply=("Windows executable")
    return 3
  fi
  if ! _sys_tool_program_safe "$program"; then
    reply=("world-writable executable")
    return 3
  fi
  if _sys_has_capability "os:darwin" \
    && (( ${+functions[_sys_macos_clt_placeholder]} )) \
    && _sys_macos_clt_placeholder "$tool_name" "$program"; then
    reply=("Command Line Tools placeholder")
    return 3
  fi
  return 0
}

# True when the tool's active executable is usable (see _sys_tool_program).
_sys_tool_available() {
  local REPLY
  local -a reply=()
  _sys_tool_program "${1:-}"
}

# --- Update step primitives ---------------------------------------------------
# Shared by the sys-update*.zsh modules: argument grammars, the trusted program
# validator, and the Darwin Homebrew askpass guard.

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

# True when <path> is a fixed failing program that root vouches for: a
# root-owned, singly linked, executable regular file that group and other
# users cannot write.
_sys_brew_askpass_trusted_false() {
  local program="${1:-}"
  local -A program_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && [[ "$program" == /* && -f "$program" && ! -L "$program" \
      && -x "$program" ]] \
    && zstat -H program_state "$program" 2>/dev/null || return 1
  (( program_state[uid] == 0 \
    && program_state[nlink] == 1 \
    && (program_state[mode] & 8#22) == 0 ))
}

# REPLY: the askpass program for Homebrew's internal `sudo -A` on macOS. It
# always fails, so a cask that needs an unavailable credential fails instead
# of prompting invisibly. /usr/bin/false is used when it passes the validator.
# Otherwise a private script whose only command is `exit 1` is created below
# the validated temporary root; the caller removes it with
# _sys_brew_askpass_release after the Homebrew run. Status 1: neither exists.
_sys_brew_askpass_program() {
  REPLY=""
  if _sys_brew_askpass_trusted_false /usr/bin/false; then
    REPLY="/usr/bin/false"
    return 0
  fi
  _sys_brew_askpass_private
}

# REPLY: a new private askpass script, <temp-root>/zdx-sys-askpass.XXXXXX/
# false-askpass, mode 0700, containing only "#!/bin/sh" and "exit 1". Its
# interpreter must be root-owned and not writable by group or other users.
_sys_brew_askpass_private() {
  emulate -L zsh
  REPLY=""
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || return 1
  local -A file_state=()
  [[ -f /bin/sh && -x /bin/sh ]] \
    && zstat -H file_state /bin/sh 2>/dev/null || return 1
  (( file_state[uid] == 0 && (file_state[mode] & 8#22) == 0 )) || return 1
  _sys_temp_parent_safe "${TMPDIR:-/tmp}" || return 1
  local temp_parent="$REPLY" askpass_dir="" askpass_program=""
  REPLY=""
  askpass_dir=$(umask 077; command mktemp -d \
    "${temp_parent%/}/zdx-sys-askpass.XXXXXX" 2>/dev/null) || return 1
  local -i write_fd=-1 created=0
  {
    [[ "${askpass_dir:h}" == "$temp_parent" \
      && "${askpass_dir:t}" == zdx-sys-askpass.* \
      && -d "$askpass_dir" && ! -L "$askpass_dir" && -O "$askpass_dir" ]] \
      || return 1
    askpass_program="$askpass_dir/false-askpass"
    sysopen -w -m 0700 -o create,excl,nofollow,cloexec -u write_fd \
      -- "$askpass_program" 2>/dev/null || return 1
    print -r -u $write_fd -- $'#!/bin/sh\nexit 1' || return 1
    exec {write_fd}>&-
    write_fd=-1
    file_state=()
    zstat -LH file_state -- "$askpass_program" 2>/dev/null || return 1
    (( file_state[uid] == EUID && file_state[nlink] == 1 \
      && (file_state[mode] & 8#170000) == 8#100000 \
      && (file_state[mode] & 8#777) == 8#700 \
      && file_state[size] == 17 )) || return 1
    created=1
  } always {
    (( write_fd >= 0 )) && exec {write_fd}>&-
    if (( ! created )); then
      [[ -n "$askpass_program" && -f "$askpass_program" \
        && ! -L "$askpass_program" ]] \
        && command rm -f -- "$askpass_program" 2>/dev/null
      [[ -d "$askpass_dir" && ! -L "$askpass_dir" ]] \
        && command rmdir -- "$askpass_dir" 2>/dev/null
    fi
  }
  (( created )) || return 1
  REPLY="$askpass_program"
}

# Removes the private askpass fallback after a Homebrew run; a no-op for
# /usr/bin/false. Only the exact private layout below a directory owned by
# this user is removed.
_sys_brew_askpass_release() {
  emulate -L zsh
  local askpass_program="${1:-}"
  [[ -n "$askpass_program" && "$askpass_program" != /usr/bin/false ]] \
    || return 0
  local askpass_dir="${askpass_program:h}"
  [[ "${askpass_program:t}" == false-askpass \
    && "${askpass_dir:t}" == zdx-sys-askpass.* \
    && "$askpass_dir" == /* && "$askpass_dir" == "${askpass_dir:A}" \
    && -d "$askpass_dir" && ! -L "$askpass_dir" && -O "$askpass_dir" ]] \
    || return 1
  if [[ -e "$askpass_program" || -L "$askpass_program" ]]; then
    [[ -f "$askpass_program" && ! -L "$askpass_program" \
      && -O "$askpass_program" ]] || return 1
    command rm -f -- "$askpass_program" || return 1
  fi
  command rmdir -- "$askpass_dir"
}

_sys_update_resolve_trusted_program() {
  local requested_program="${1:-dnf}"
  [[ "$requested_program" == "apt-config" \
    || "$requested_program" == "curl" \
    || "$requested_program" == "dnf" \
    || "$requested_program" == "dpkg" \
    || "$requested_program" == "dpkg-query" \
    || "$requested_program" == "env" \
    || "$requested_program" == "gpg" \
    || "$requested_program" == "install" \
    || "$requested_program" == "zsh" ]] || return 2
  local program
  program=$(whence -p "$requested_program" 2>/dev/null) || return 1
  [[ "$program" == /* && "$program" != *[[:cntrl:]]* ]] || return 1
  program="${program:A}"
  local -A program_state=()
  zmodload -F zsh/stat b:zstat 2>/dev/null \
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

# --- Sudo timestamp refresher -----------------------------------------------
# sudo keeps its timestamp per terminal session by default (sudoers
# timestamp_type=tty): a refresh counts only when it runs on the controlling
# terminal and in the session of the authentication. The refresher therefore
# runs as a process substitution of this shell. It shares the caller's session
# and terminal, never enters the interactive job table, and in an interactive
# shell runs in its own process group, so neither terminal signals nor job
# notifications reach it. Its only output is a private status pipe that the
# caller reads:
#
#   zdx-sudo-keepalive-ready <pid> <ok|failed>     after the first refresh
#   zdx-sudo-keepalive-stopped <pid> <ok|failed>   after the stop request
#
# The handle zdx-sudo-keepalive-<pid>-<fd>-<device>-<inode> names the worker,
# the caller's descriptor for that pipe, and the pipe's identity.

# Waits for the next refresh while noticing a stop request within a quarter of
# a second: a trapped signal does not interrupt zselect, so the 30-second
# interval is sliced. Status 0: stop requested; 1: the interval elapsed; 2:
# zsh/zselect is unavailable.
_sys_update_sudo_keepalive_wait() {
  zmodload zsh/zselect 2>/dev/null || return 2
  local -i slice=0
  while (( slice++ < 120 )); do
    (( ${_sys_keepalive_stop_requested:-0} )) && return 0
    zselect -t 25 2>/dev/null
  done
  (( ${_sys_keepalive_stop_requested:-0} )) && return 0
  return 1
}

# True while the invoking shell still owns this worker. A worker re-parented
# after its caller exited never refreshes on that caller's behalf.
_sys_update_sudo_keepalive_caller_alive() {
  local caller_pid="${1:-}"
  [[ "$caller_pid" == <-> ]] || return 1
  if [[ -n "${sysparams[ppid]:-}" ]]; then
    [[ "${sysparams[ppid]}" == "$caller_pid" ]] || return 1
  fi
  builtin kill -0 "$caller_pid" 2>/dev/null
}

# Usage: _sys_update_sudo_keepalive_worker <caller-pid>
_sys_update_sudo_keepalive_worker() {
  emulate -L zsh
  setopt NO_MONITOR NO_NOTIFY
  zmodload zsh/system 2>/dev/null || return 1
  local caller_pid="${1:-}" worker_pid="${sysparams[pid]:-}"
  local refresh_state=ok
  [[ "$caller_pid" == <-> && "$worker_pid" == <-> ]] || return 1
  local -i _sys_keepalive_stop_requested=0 wait_rc=0
  trap '_sys_keepalive_stop_requested=1' TERM
  command sudo -n -v </dev/null >/dev/null 2>&1 || refresh_state=failed
  print -r -- "zdx-sudo-keepalive-ready $worker_pid $refresh_state" \
    || return 1
  while true; do
    _sys_update_sudo_keepalive_wait
    wait_rc=$?
    (( wait_rc == 0 )) && break
    (( wait_rc == 1 )) || return 1
    _sys_update_sudo_keepalive_caller_alive "$caller_pid" || return 0
    # A failed refresh is never retried; the worker only awaits its stop.
    [[ "$refresh_state" == ok ]] || continue
    command sudo -n -v </dev/null >/dev/null 2>&1 || refresh_state=failed
  done
  print -r -- "zdx-sudo-keepalive-stopped $worker_pid $refresh_state"
}

# Stops one worker and closes its status pipe. It drains the status records,
# sends TERM only while the open pipe proves that the worker still runs, so
# the PID cannot belong to another process, and then waits up to five
# seconds for the acknowledgement and the end of the pipe, which confirms the
# exit. REPLY: the last refresh state reported (ok, failed, or empty).
# Usage: _sys_update_sudo_keepalive_terminate <worker-pid> <status-fd>
_sys_update_sudo_keepalive_terminate() {
  emulate -L zsh
  local worker_pid="${1:-}" status_fd="${2:-}"
  REPLY=""
  [[ "$worker_pid" == <-> && "$status_fd" == <-> ]] || return 2
  zmodload zsh/zselect 2>/dev/null || return 1
  local record="" refresh_state=""
  local -a record_fields=()
  local -i attempt=0 exited=0 signaled=0 read_rc=0
  while (( ++attempt <= 500 )); do
    if zselect -t 1 -r "$status_fd" 2>/dev/null; then
      record=""
      IFS= read -r -u "$status_fd" record
      read_rc=$?
      if (( read_rc != 0 )) && [[ -z "$record" ]]; then
        exited=1
        break
      fi
      record_fields=(${=record})
      if (( ${#record_fields} == 3 )) \
        && [[ "${record_fields[1]}" == zdx-sudo-keepalive-* \
          && "${record_fields[2]}" == "$worker_pid" \
          && ( "${record_fields[3]}" == ok \
            || "${record_fields[3]}" == failed ) ]]; then
        refresh_state="${record_fields[3]}"
      fi
      continue
    fi
    if (( ! signaled )); then
      builtin kill -TERM "$worker_pid" 2>/dev/null || true
      signaled=1
    fi
  done
  exec {status_fd}<&-
  REPLY="$refresh_state"
  (( exited ))
}

# Starts the refresher for the consecutive privileged entries after the caller
# holds a fresh sudo timestamp. REPLY: the private handle. The worker renews
# the timestamp once before it reports ready, so a refresher that cannot renew
# this session's timestamp is reported now instead of failing silently later.
# Status 0: running; 1: not running, after a warning; 2: invalid argument.
_sys_update_start_sudo_keepalive() {
  emulate -L zsh
  local authenticated="${1:-0}"
  REPLY=""
  [[ "$authenticated" == 0 || "$authenticated" == 1 ]] || return 2
  (( authenticated && EUID != 0 )) || return 0
  _sys_has_capability "privilege:sudo" \
    && command -v sudo &>/dev/null || return 0
  local start_warning="Sudo timestamp refresh could not start; privileged steps will still fail rather than reprompt."
  { zmodload zsh/system zsh/zselect && zmodload -F zsh/stat b:zstat; } 2>/dev/null || {
    _sys_warn "$start_warning"
    return 1
  }
  local caller_pid="${sysparams[pid]:-}"
  [[ "$caller_pid" == <-> ]] || {
    _sys_warn "$start_warning"
    return 1
  }

  # exec keeps only the new descriptor; a redirection of another stream on
  # this line would replace the caller's own stream permanently.
  local -i status_fd=-1
  exec {status_fd}< <(
    _sys_update_sudo_keepalive_worker "$caller_pid" </dev/null 2>/dev/null
  )
  (( status_fd >= 0 )) || {
    _sys_warn "$start_warning"
    return 1
  }
  # zsh reports the PID it started; the worker reports its own.
  local started_pid="${sysparams[procsubstpid]:-}"
  local record=""
  local -a record_fields=()
  if ! zselect -t 1000 -r "$status_fd" 2>/dev/null; then
    # No ready record within ten seconds. Closing the pipe ends the worker at
    # its first write, which follows its first refresh.
    exec {status_fd}<&-
    _sys_warn "$start_warning"
    return 1
  fi
  IFS= read -r -u "$status_fd" record || record=""
  record_fields=(${=record})

  local worker_pid="${record_fields[2]:-}"
  if (( ${#record_fields} != 3 )) \
    || [[ "${record_fields[1]}" != zdx-sudo-keepalive-ready \
      || "$worker_pid" != <-> \
      || ( "${record_fields[3]}" != ok && "${record_fields[3]}" != failed ) ]] \
    || [[ -n "$started_pid" && "$started_pid" != "$worker_pid" ]]; then
    # Only the PID that zsh itself started may be signaled.
    if [[ "$started_pid" == <-> ]]; then
      _sys_update_sudo_keepalive_terminate "$started_pid" "$status_fd" \
        || true
    else
      exec {status_fd}<&-
    fi
    REPLY=""
    _sys_warn "$start_warning"
    return 1
  fi

  if [[ "${record_fields[3]}" != ok ]]; then
    _sys_update_sudo_keepalive_terminate "$worker_pid" "$status_fd" || true
    REPLY=""
    _sys_warn \
      "Sudo timestamp refresh does not work in this terminal session (sudo -n -v failed); a privileged step that outlasts sudo's timestamp timeout will fail rather than reprompt."
    return 1
  fi

  local -A pipe_state=()
  if ! zstat -H pipe_state -f "$status_fd" 2>/dev/null \
    || [[ "${pipe_state[device]:-}" != <-> \
      || "${pipe_state[inode]:-}" != <-> ]]; then
    _sys_update_sudo_keepalive_terminate "$worker_pid" "$status_fd" || true
    REPLY=""
    _sys_warn "$start_warning"
    return 1
  fi
  _sys_verbose_dim \
    "Sudo timestamp refresh is active only for the authorized package entries." \
    || true
  REPLY="zdx-sudo-keepalive-${worker_pid}-${status_fd}-${pipe_state[device]}-${pipe_state[inode]}"
  return 0
}

# Stops the refresher named by a handle from _sys_update_start_sudo_keepalive.
# It acts only while the handle's descriptor is still the same private pipe,
# and warns when a refresh failed during the run. Status 0 when the worker's
# exit is confirmed.
_sys_update_stop_sudo_keepalive() {
  emulate -L zsh
  local keepalive_handle="${1:-}"
  local -a match=() mbegin=() mend=()
  [[ "$keepalive_handle" \
    =~ '^zdx-sudo-keepalive-([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)$' ]] \
    || return 2
  local worker_pid="${match[1]}" status_fd="${match[2]}"
  local pipe_device="${match[3]}" pipe_inode="${match[4]}"
  (( ${#status_fd} <= 6 && status_fd > 2 )) || return 2
  { zmodload zsh/zselect && zmodload -F zsh/stat b:zstat; } 2>/dev/null || return 1
  local -A pipe_state=()
  zstat -H pipe_state -f "$status_fd" 2>/dev/null \
    && [[ "${pipe_state[device]}" == "$pipe_device" \
      && "${pipe_state[inode]}" == "$pipe_inode" ]] || return 1

  local REPLY=""
  local -i terminate_rc=0
  _sys_update_sudo_keepalive_terminate "$worker_pid" "$status_fd" \
    || terminate_rc=$?
  if [[ "$REPLY" == failed ]]; then
    _sys_warn \
      "Sudo timestamp refresh failed during this run; a later privileged step may have failed rather than reprompt."
  fi
  return $terminate_rc
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

  # A dependency counts only when the command can use it: not a Windows
  # program on WSL, a world-writable file, or a macOS Command Line Tools
  # placeholder (see _sys_tool_program).
  deps=$(_sys_cmd_deps "$command_name")
  if [[ -n "$deps" ]]; then
    for dep in ${(s:,:)deps}; do
      _sys_tool_available "$dep" || missing+=("$dep")
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
  esac

  (( ${#missing[@]} > 0 )) && print -r -- "${(j:, :)missing}"
  return 0
}

# REPLY: advisory host context that a command needs and the host lacks, such
# as WSL for sys-wsl, or empty. The command repeats the check and reports that
# it does not apply.
_sys_menu_unavailable_context() {
  REPLY=""
  case "${1:-}" in
    sys-wsl)
      _sys_has_capability "environment:wsl" || REPLY="WSL"
      ;;
  esac
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

  local missing REPLY
  missing=$(_sys_menu_missing_requirements "$command_name") || return $?
  _sys_menu_unavailable_context "$command_name" || return $?
  local -a facts=()
  [[ -n "$missing" ]] && facts+=("missing: $missing")
  [[ -n "$REPLY" ]] && facts+=("unavailable: $REPLY")

  # docs/menu-spec.md: an unavailable action keeps its command field and is
  # marked by a leading circle plus the requirement or context in text.
  if (( ${#facts} > 0 )); then
    printf "  ○ %s (%s)|%s|%s\n" \
      "$label" "${(j:; :)facts}" "$command_name" "$description"
  else
    printf "  %s|%s|%s\n" "$label" "$command_name" "$description"
  fi
}

# --- fzf preset for the sys suite -------------------------------------------

# REPLY is the canonical directory for an absolute, already-normalized path.
# A symbolic link on the literal path is accepted only as a root-owned system
# alias, such as macOS /var and /tmp, or above the final component when the
# current user owns it inside a directory owned by root or the current user
# that group and other users cannot write. This mirrors the core
# _zdx_resolve_trusted_dir so the suite stays sourceable on its own.
_sys_resolve_trusted_dir() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local requested="${1-}"
  REPLY=""
  while [[ "$requested" != / && "$requested" == */ ]]; do
    requested="${requested%/}"
  done
  [[ -n "$requested" && "$requested" == /* \
    && "$requested" == "${requested:a}" ]] || return 1

  local -A root_state=() link_state=() parent_state=()
  zstat -LH root_state -- / 2>/dev/null || return 1
  local -a components=("${(@s:/:)requested}")
  local prefix="" component=""
  local -i index=0 last=${#components}
  for component in "${components[@]}"; do
    (( ++index ))
    [[ -n "$component" ]] || continue
    prefix+="/$component"
    [[ -L "$prefix" ]] || continue
    link_state=()
    zstat -LH link_state -- "$prefix" 2>/dev/null || return 1
    (( link_state[uid] == root_state[uid] )) && continue
    (( index < last && link_state[uid] == EUID )) || return 1
    parent_state=()
    zstat -H parent_state -- "${prefix:h}" 2>/dev/null || return 1
    (( parent_state[uid] == root_state[uid] || parent_state[uid] == EUID )) \
      && (( (parent_state[mode] & 8#22) == 0 )) || return 1
  done
  local resolved="${requested:A}"
  [[ "$resolved" == /* && -d "$resolved" && ! -L "$resolved" ]] || return 1
  REPLY="$resolved"
}

# REPLY is the canonical temporary root; the ownership and sticky checks
# apply to the canonical directory.
_sys_temp_parent_safe() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local temp_parent="${1:-}"
  REPLY=""

  _sys_resolve_trusted_dir "$temp_parent" || return 1
  temp_parent="$REPLY"
  REPLY=""
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

  # fzf with templates hides the delimiter that trails a single shown field.
  local REPLY=""
  if typeset -f _tk_fzf_nth_template_option &>/dev/null \
    && _tk_fzf_nth_template_option "${options[@]}" "$@"; then
    terminal_options+=("$REPLY")
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh fzf "${options[@]}" "$@" "${terminal_options[@]}"
}

# Run fzf synchronously in the terminal foreground and capture only its
# selection stdout in one private, bounded, invocation-owned result file.
_sys_fzf_capture() {
  emulate -L zsh
  REPLY=""
  { zmodload -F zsh/stat b:zstat && zmodload zsh/system; } 2>/dev/null || {
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
    clean-system)
      _sys_dispatch_prepare "$command_name" "$@" && clean-system "$@" ;;
    clean-journal)
      _sys_dispatch_prepare "$command_name" "$@" && clean-journal "$@" ;;
    clean-snaps)
      _sys_dispatch_prepare "$command_name" "$@" && clean-snaps "$@" ;;
    sys-info)
      _sys_dispatch_prepare "$command_name" "$@" && sys-info "$@" ;;
    sys-health)
      _sys_dispatch_prepare "$command_name" "$@" && sys-health "$@" ;;
    sys-wsl)
      _sys_dispatch_prepare "$command_name" "$@" && sys-wsl "$@" ;;
    sys-startup)
      _sys_dispatch_prepare "$command_name" "$@" && sys-startup "$@" ;;
    sys-telemetry)
      _sys_dispatch_prepare "$command_name" "$@" && sys-telemetry "$@" ;;
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
