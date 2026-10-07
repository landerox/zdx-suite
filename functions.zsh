#!/usr/bin/env zsh
# =============================================================================
# ZDX Core: configuration, output, loading, plugins, timing, and telemetry
# =============================================================================
#
# Sourced by zdx-suite.plugin.zsh or directly by a Zsh startup file.
# Registers suite entrypoints and owner-local runtime helpers.
#

if [[ -n "${_ZDX_FUNCTIONS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Load optional user configuration
if [[ -f "$HOME/.config/zdx/config.zsh" \
  && -r "$HOME/.config/zdx/config.zsh" ]]; then
  source "$HOME/.config/zdx/config.zsh" || {
    typeset -i _zdx_config_rc=$?
    print -u2 -r -- "zdx: failed to load user configuration"
    {
      return $_zdx_config_rc 2>/dev/null || exit $_zdx_config_rc
    } always {
      unset _zdx_config_rc
    }
  }
fi

# --- Centralized FZF Theme Helpers -------------------------------------------

_tk_fzf_color_opts() {
  if [[ -n "${NO_COLOR:-}" || -n "${ZDX_FZF_PLAIN:-}" \
    || "${TERM:-}" == dumb ]]; then
    print -r -- '--no-color'
  elif [[ -n "${ZDX_FZF_THEME:-}" ]]; then
    print -r -- "--color=${ZDX_FZF_THEME}"
  else
    # Keep foreground and background paired with the terminal's own palette.
    # fzf before 0.66 draws borders, separators, and scrollbars in ANSI black
    # and the match counter in white, which vanish on dark or light profiles;
    # pin them to the values that newer releases already use by default.
    print -r -- '--color=16,fg:-1,bg:-1,fg+:-1,bg+:-1,border:-1:dim,info:yellow'
  fi
}

# REPLY: a --with-nth template that shows one field without its trailing
# delimiter, such as `--with-nth={1}` for `--with-nth=1`. fzf versions without
# templates keep the plain field and its delimiter. ZDX_FZF_TEMPLATES=auto (the
# default) probes the installed fzf once per executable with fixed input; 0
# keeps the plain field and 1 always uses the template. Status 1 means no
# option applies.
_tk_fzf_nth_template_option() {
  emulate -L zsh
  REPLY=""
  local arg="" nth=""
  for arg in "$@"; do
    [[ "$arg" == --with-nth=* ]] && nth="${arg#--with-nth=}"
  done
  [[ "$nth" == <1-99> ]] || return 1
  case "${ZDX_FZF_TEMPLATES:-auto}" in
    0) return 1 ;;
    1) REPLY="--with-nth={$nth}"; return 0 ;;
    auto) ;;
    *) return 1 ;;
  esac
  local fzf_path="${commands[fzf]-}"
  [[ -n "$fzf_path" ]] || return 1
  if [[ "${_TK_FZF_NTH_TEMPLATE_PROBE[1]-}" != "$fzf_path" ]]; then
    local -i probe_status=0
    print -r -- 'probe|field' | FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' \
      FZF_DEFAULT_COMMAND='' SHELL=/bin/sh command fzf --delimiter='[|]' \
      --with-nth='{1}' --filter=probe >/dev/null 2>&1 || probe_status=$?
    typeset -ga _TK_FZF_NTH_TEMPLATE_PROBE=("$fzf_path" "$probe_status")
  fi
  [[ "${_TK_FZF_NTH_TEMPLATE_PROBE[2]-}" == 0 ]] || return 1
  REPLY="--with-nth={$nth}"
}

_tk_fzf() {
  local -a default_opts
  default_opts=(
    "$(_tk_fzf_color_opts)"
    --layout=reverse
    --border
  )
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
    && _tk_fzf_nth_template_option "${default_opts[@]}" "$@"; then
    terminal_options+=("$REPLY")
  fi

  FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' FZF_DEFAULT_COMMAND='' \
    SHELL=/bin/sh fzf "${default_opts[@]}" "$@" "${terminal_options[@]}"
}

# --- Native Zsh Spinner ------------------------------------------------------

_tk_spinner() {
  local msg="$1"
  shift

  # Hide cursor using ANSI escape
  printf "\e[?25l" >&2

  # Run the command in the background
  "$@" &
  local pid=$!

  {
    local delay=0.1
    local -a frames
    frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local frame_count=${#frames[@]}
    local i=1

    while kill -0 $pid 2>/dev/null; do
      printf "\r\033[0;36m%s\033[0m %s" "${frames[i]}" "$msg" >&2
      i=$(( (i % frame_count) + 1 ))
      sleep $delay
    done
  } always {
    # Ensure background process is terminated if interrupted/completed
    if kill -0 $pid 2>/dev/null; then
      kill -TERM $pid 2>/dev/null
    fi
    # Restore cursor and clear the spinner line
    printf "\r\e[?25h\033[K" >&2
  }

  wait $pid 2>/dev/null
  return $?
}

_tk_check_cmd() {
  command -v "$1" &>/dev/null
}

# --- Command Output Services (docs/output-spec.md) ----------------------------
# Shared rendering for non-menu command output: outcome vocabulary, headings,
# step banners and results, summary tables, durations, counted nouns, step
# result slots, and private capture of child-tool output. Every service writes
# UI to stderr only and treats caller text as data. Suites call these through
# thin wrappers that keep a standalone fallback.

_zdx_ui_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]
}

# Only the exact value 1 enables verbose output.
_zdx_ui_verbose() {
  [[ "${ZDX_VERBOSE:-0}" == 1 ]]
}

# True inside an aggregate step, including subshells and captures of a step.
_zdx_step_active() {
  (( ${_ZDX_STEP_DEPTH:-0} > 0 ))
}

# REPLY: one compact duration such as 0.4s, 24s, 1m 18s, or 1h 02m. Integer
# arithmetic keeps LC_NUMERIC from changing the decimal point. Status 2 means
# the input is not an unsigned decimal number of seconds.
_zdx_format_duration() {
  emulate -L zsh
  local value="${1-}"
  local -i tenths=0 seconds=0 minutes=0
  REPLY=""
  [[ ${#value} -le 32 \
    && "$value" =~ '^[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$' ]] || return 2
  (( value <= 1e9 )) || return 2
  (( tenths = value * 10 + 0.5 ))
  if (( tenths < 100 )); then
    REPLY="$(( tenths / 10 )).$(( tenths % 10 ))s"
    return 0
  fi
  # Round once to whole seconds and classify that value, so no branch can
  # print 60s or 60m.
  (( seconds = value + 0.5 ))
  if (( seconds < 60 )); then
    REPLY="${seconds}s"
  elif (( seconds < 3600 )); then
    REPLY="$(( seconds / 60 ))m ${(l:2::0:)$(( seconds % 60 ))}s"
  else
    (( minutes = (seconds + 30) / 60 ))
    REPLY="$(( minutes / 60 ))h ${(l:2::0:)$(( minutes % 60 ))}m"
  fi
}

# REPLY: "<count> <noun>" with the singular only for exactly one.
# Usage: _zdx_count_noun <count> <singular> [plural]
_zdx_count_noun() {
  emulate -L zsh
  local count="${1-}" singular="${2-}" plural="${3-}"
  REPLY=""
  [[ "$count" =~ '^(0|[1-9][0-9]{0,17})$' && -n "$singular" ]] || return 2
  [[ -n "$plural" ]] || plural="${singular}s"
  if [[ "$count" == 1 ]]; then
    REPLY="1 $singular"
  else
    REPLY="$count $plural"
  fi
}

# REPLY: the class of one outcome token: success, info, neutral, or failure.
_zdx_outcome_class() {
  emulate -L zsh
  REPLY=""
  case "${1-}" in
    updated|current|done|passed)              REPLY=success ;;
    delegated|planned)                        REPLY=info ;;
    skipped|not-run)                          REPLY=neutral ;;
    failed|blocked|interrupted|timed-out)     REPLY=failure ;;
    *)                                        return 2 ;;
  esac
}

# REPLY: the glyph and word shown for one outcome token.
_zdx_ui_outcome() {
  emulate -L zsh
  REPLY=""
  case "${1-}" in
    updated)     REPLY="✔ updated" ;;
    current)     REPLY="✔ current" ;;
    done)        REPLY="✔ done" ;;
    passed)      REPLY="✔ passed" ;;
    delegated)   REPLY="→ delegated" ;;
    planned)     REPLY="➜ planned" ;;
    skipped)     REPLY="⊘ skipped" ;;
    not-run)     REPLY="– not run" ;;
    failed)      REPLY="✘ failed" ;;
    blocked)     REPLY="✘ blocked" ;;
    interrupted) REPLY="✘ interrupted" ;;
    timed-out)   REPLY="✘ timed out" ;;
    *)           return 2 ;;
  esac
}

# REPLY: the SGR parameters for one outcome token.
_zdx_ui_outcome_sgr() {
  emulate -L zsh
  REPLY=""
  case "${1-}" in
    updated)                              REPLY="1;32" ;;
    current|done|passed)                  REPLY="0;32" ;;
    delegated|planned)                    REPLY="0;36" ;;
    skipped)                              REPLY="0;90" ;;
    not-run)                              REPLY="0;33" ;;
    failed|blocked|interrupted|timed-out) REPLY="1;31" ;;
    *)                                    return 2 ;;
  esac
}

# REPLY: a display-only command line. Each word is quoted only when needed and
# a leading $HOME is shown as ~. The result is never executed.
_zdx_ui_command_display() {
  emulate -L zsh
  (( $# > 0 )) || { REPLY=""; return 2; }
  local word home="${HOME-}" rendered=""
  local -a words=()
  for word in "$@"; do
    if [[ -n "$home" && "$home" != / && "$word" == "$home" ]]; then
      rendered="~"
    elif [[ -n "$home" && "$home" != / && "$word" == "$home"/* ]]; then
      rendered="~/${(q-)${word#$home/}}"
    else
      rendered="${(q-)word}"
    fi
    words+=("$rendered")
  done
  REPLY="${(j: :)words}"
}

# Private printer for the services below.
# Usage: _zdx_ui_say <success|info|warn|error|dim> <text>
_zdx_ui_say() {
  emulate -L zsh
  local level="${1-}" text="${(V)2-}" sgr="" glyph=""
  case "$level" in
    success) sgr="1;32" glyph="✔ " ;;
    info)    sgr="0;36" glyph="➜ " ;;
    warn)    sgr="1;33" glyph="⚠ " ;;
    error)   sgr="1;31" glyph="✘ " ;;
    dim)     sgr="0;90" glyph="  " ;;
    *)       return 2 ;;
  esac
  if _zdx_ui_color_enabled; then
    printf '\033[%sm%s%s\033[0m\n' "$sgr" "$glyph" "$text" >&2
  else
    printf '%s%s\n' "$glyph" "$text" >&2
  fi
}

# Top-level heading. Inside an aggregate step the step banner already names
# the work, so a child's heading is omitted unless ZDX_VERBOSE=1 asks for a
# demoted sub-heading.
_zdx_ui_heading() {
  emulate -L zsh
  local title="${1-}"
  [[ -n "$title" ]] || return 2
  title="${(V)title}"
  if _zdx_step_active; then
    _zdx_ui_verbose || return 0
    local indent=""
    printf -v indent '%*s' $(( 2 * ${_ZDX_STEP_DEPTH:-0} )) ''
    if _zdx_ui_color_enabled; then
      printf '%s\033[0;35m▸ %s\033[0m\n' "$indent" "$title" >&2
    else
      printf '%s▸ %s\n' "$indent" "$title" >&2
    fi
    return 0
  fi
  if _zdx_ui_color_enabled; then
    printf '\n\033[1;35m════ %s ════\033[0m\n\n' "$title" >&2
  else
    printf '\n════ %s ════\n\n' "$title" >&2
  fi
}

# A sub-heading inside a report: one blank line, then "▸ Title", indented by
# the step depth. --first omits the blank line for the section that directly
# follows a heading, which already ends with one. Unlike a heading a section
# is content, so a step never omits it.
# Usage: _zdx_ui_section [--first] <title>
_zdx_ui_section() {
  emulate -L zsh
  local gap=$'\n'
  if [[ "${1-}" == --first ]]; then
    gap=""
    shift
  fi
  local title="${1-}"
  [[ -n "$title" ]] || return 2
  title="${(V)title}"
  local indent=""
  printf -v indent '%*s' $(( 2 * ${_ZDX_STEP_DEPTH:-0} )) ''
  if _zdx_ui_color_enabled; then
    printf '%s%s\033[1m▸ %s\033[0m\n' "$gap" "$indent" "$title" >&2
  else
    printf '%s%s▸ %s\n' "$gap" "$indent" "$title" >&2
  fi
}

# One key-value line: a two-space indent, the key with exactly one trailing
# colon padded to 18 display columns, a space, and the value. The key is bold
# in the terminal's own foreground, so it stays readable on light and dark
# themes. Usage: _zdx_ui_label <key> <value>
_zdx_ui_label() {
  emulate -L zsh
  local key="${1-}" value="${2-}"
  key="${key%:}"
  [[ -n "$key" ]] || return 2
  key="${(V)key}:"
  value="${(V)value}"
  local -i padding=$(( 19 - ${(m)#key} ))
  (( padding < 1 )) && padding=1
  if _zdx_ui_color_enabled; then
    printf '  \033[1m%s\033[0m%*s%s\n' "$key" "$padding" '' "$value" >&2
  else
    printf '  %s%*s%s\n' "$key" "$padding" '' "$value" >&2
  fi
}

# Returns 0 when "<index> <total>" is a valid step counter.
_zdx_ui_step_counter_valid() {
  emulate -L zsh
  [[ "${1-}" =~ '^[1-9][0-9]{0,3}$' && "${2-}" =~ '^[1-9][0-9]{0,3}$' ]] \
    && (( ${1} <= ${2} ))
}

# Usage: _zdx_ui_step_banner [--first] <index> <total> <label>
# --first omits the leading blank line for the banner that directly follows a
# heading, which already ends with one.
_zdx_ui_step_banner() {
  emulate -L zsh
  local gap=$'\n'
  if [[ "${1-}" == --first ]]; then
    gap=""
    shift
  fi
  local index="${1-}" total="${2-}" label="${3-}"
  _zdx_ui_step_counter_valid "$index" "$total" && [[ -n "$label" ]] \
    || return 2
  label="${(V)label}"
  local indent=""
  printf -v indent '%*s' $(( 2 * ${_ZDX_STEP_DEPTH:-0} )) ''
  if _zdx_step_active; then
    # A nested aggregate keeps its counter without another full-width rule.
    printf '%s[%s/%s] %s\n' "$indent" "$index" "$total" "$label" >&2
    return 0
  fi
  local -i width=72
  if [[ "${COLUMNS-}" =~ '^[0-9]{1,4}$' ]] && (( COLUMNS >= 21 )); then
    width=$(( COLUMNS - 1 ))
  fi
  (( width > 72 )) && width=72
  local prefix="── [$index/$total] $label "
  local -i rule_length=$(( width - ${(m)#prefix} ))
  (( rule_length < 3 )) && rule_length=3
  local rule=""
  printf -v rule '%*s' "$rule_length" ''
  rule="${rule// /─}"
  if _zdx_ui_color_enabled; then
    printf '%s\033[0;90m──\033[0m \033[1m[%s/%s] %s\033[0m \033[0;90m%s\033[0m\n' \
      "$gap" "$index" "$total" "$label" "$rule" >&2
  else
    printf '%s%s%s\n' "$gap" "$prefix" "$rule" >&2
  fi
}

# Usage: _zdx_ui_step_result <index> <total> <label> <outcome> <detail> <seconds>
# Prints: <glyph> [i/n] <label> — <word>[: <detail>][ (<duration>)]
_zdx_ui_step_result() {
  emulate -L zsh
  (( $# == 6 )) || return 2
  local index="$1" total="$2" label="$3" outcome="$4" detail="$5"
  local seconds="$6" REPLY word="" sgr="" duration=""
  _zdx_ui_step_counter_valid "$index" "$total" && [[ -n "$label" ]] \
    || return 2
  _zdx_ui_outcome "$outcome" || return 2
  word="$REPLY"
  _zdx_ui_outcome_sgr "$outcome"
  sgr="$REPLY"
  if [[ -n "$seconds" ]]; then
    _zdx_format_duration "$seconds" || return 2
    duration=" ($REPLY)"
  fi
  local glyph="${word%% *}" name="${word#* }"
  local text="[$index/$total] ${(V)label} — $name${detail:+: ${(V)detail}}"
  local indent=""
  printf -v indent '%*s' $(( 2 * ${_ZDX_STEP_DEPTH:-0} )) ''
  if _zdx_ui_color_enabled; then
    printf '%s\033[%sm%s\033[0m %s\033[0;90m%s\033[0m\n' \
      "$indent" "$sgr" "$glyph" "$text" "$duration" >&2
  else
    printf '%s%s %s%s\n' "$indent" "$glyph" "$text" "$duration" >&2
  fi
}

# Renders aligned columns from TAB-separated rows on stderr.
# Usage: _zdx_ui_table [--outcome-column N] <header-tsv> [row-tsv...]
# Cells are escaped with (V) and measured by display width. Every column except
# the last is padded to its widest cell, capped at 40 columns; the last column
# is never padded or truncated. Outcome-column cells must be outcome tokens and
# render as glyph plus word. Any invalid row prints nothing and returns 2.
_zdx_ui_table() {
  emulate -L zsh
  local -i outcome_column=0
  if [[ "${1-}" == --outcome-column ]]; then
    [[ "${2-}" =~ '^[1-9][0-9]?$' ]] || return 2
    outcome_column="$2"
    shift 2
  fi
  (( $# >= 1 )) || return 2
  (( $# >= 2 )) || return 0
  local -a header=("${(@ps:\t:)1}")
  local -i columns=${#header} row_count=$(( $# - 1 )) column=0 cell_width=0
  (( columns >= 1 && columns <= 16 )) || return 2
  (( outcome_column <= columns )) || return 2
  local -a cells=() fields=() widths=() classes=()
  local row cell REPLY
  for (( column = 1; column <= columns; column++ )); do
    widths[column]=0
  done
  # First pass: validate, escape, and measure every cell.
  local -i row_index=0
  for row in "$@"; do
    fields=("${(@ps:\t:)row}")
    (( ${#fields} == columns )) || return 2
    for (( column = 1; column <= columns; column++ )); do
      cell="${(V)fields[column]}"
      if (( row_index > 0 && column == outcome_column )); then
        _zdx_ui_outcome "${fields[column]}" || return 2
        cell="$REPLY"
        _zdx_ui_outcome_sgr "${fields[column]}"
        classes[row_index]="$REPLY"
      fi
      cells+=("$cell")
      cell_width=${(m)#cell}
      (( cell_width > 40 )) && cell_width=40
      (( cell_width > widths[column] )) && widths[column]=$cell_width
    done
    (( row_index++ ))
  done
  # Second pass: render.
  local -i color=0 index=0 padding=0
  _zdx_ui_color_enabled && color=1
  local line="" rendered="" sgr=""
  for (( row_index = 0; row_index <= row_count; row_index++ )); do
    line="  "
    for (( column = 1; column <= columns; column++ )); do
      index=$(( row_index * columns + column ))
      cell="${cells[index]}"
      rendered="$cell"
      if (( color )); then
        if (( row_index == 0 )); then
          rendered=$'\e[1m'"$cell"$'\e[0m'
        elif (( column == outcome_column )); then
          sgr="${classes[row_index]}"
          rendered=$'\e['"${sgr}m${cell}"$'\e[0m'
        fi
      fi
      line+="$rendered"
      if (( column < columns )); then
        padding=$(( widths[column] - ${(m)#cell} ))
        (( padding < 0 )) && padding=0
        line+="${(l:padding:: :)}  "
      fi
    done
    line="${line%"${line##*[^ ]}"}"
    print -u2 -r -- "$line"
  done
}

# Prints an aggregate summary from "label<TAB>outcome<TAB>seconds<TAB>detail"
# records under its own heading; seconds may be empty. A nested aggregate,
# running inside an enclosing step, prints no table unless ZDX_VERBOSE=1: the
# enclosing summary already has its row. Status 2 means a malformed record.
# Usage: _zdx_ui_step_summary [--first-column NAME] <title> <record...>
_zdx_ui_step_summary() {
  emulate -L zsh
  local first_column=Step
  if [[ "${1-}" == --first-column ]]; then
    [[ -n "${2-}" && "${2-}" != *[[:cntrl:]]* ]] || return 2
    first_column="$2"
    shift 2
  fi
  local title="${1-}"
  [[ -n "$title" ]] || return 2
  shift
  (( $# > 0 )) || return 0
  _zdx_step_active && ! _zdx_ui_verbose && return 0
  local record REPLY time_label
  local -a fields=() rows=()
  for record in "$@"; do
    fields=("${(@ps:\t:)record}")
    (( ${#fields} >= 2 && ${#fields} <= 4 )) || return 2
    time_label=""
    if [[ -n "${fields[3]-}" ]]; then
      _zdx_format_duration "${fields[3]}" || return 2
      time_label="$REPLY"
    fi
    rows+=("${fields[1]}"$'\t'"${fields[2]}"$'\t'"$time_label"$'\t'"${fields[4]-}")
  done
  _zdx_ui_heading "$title"
  _zdx_ui_table --outcome-column 2 \
    "$first_column"$'\tResult\tTime\tDetail' "${rows[@]}"
}

# Runs one aggregate step with a dynamically scoped result slot.
# reply=(outcome detail seconds); returns the command's status. It never
# redirects stdio: the caller decides whether a step keeps the terminal.
_zdx_step_exec() {
  if (( $# == 0 )); then
    reply=()
    return 2
  fi
  local _ZDX_STEP_OUTCOME="" _ZDX_STEP_DETAIL=""
  local -i _ZDX_STEP_DEPTH=$(( ${_ZDX_STEP_DEPTH:-0} + 1 ))
  local -i _ZDX_STEP_SHELL=$ZSH_SUBSHELL
  local _zdx_step_start="${EPOCHREALTIME:-$SECONDS}"
  local -i _zdx_step_rc=0
  "$@" || _zdx_step_rc=$?
  _zdx_step_finish "$_zdx_step_rc" "$_zdx_step_start" \
    "${EPOCHREALTIME:-$SECONDS}" "$_ZDX_STEP_OUTCOME" "$_ZDX_STEP_DETAIL"
  return $_zdx_step_rc
}

# Private: reconcile a reported outcome with the exit status, then set reply.
# The status always wins: an interruption or failure cannot report success,
# and an unreported success becomes "done".
_zdx_step_finish() {
  emulate -L zsh
  local -i rc="$1" elapsed_ms=0
  local start="$2" end="$3" outcome="$4" detail="$5" class="" REPLY
  (( elapsed_ms = (end - start) * 1000 + 0.5 ))
  (( elapsed_ms < 0 )) && elapsed_ms=0
  [[ -n "$outcome" ]] && _zdx_outcome_class "$outcome" && class="$REPLY"
  if (( rc == 130 || rc == 143 )); then
    [[ "$class" == failure && -n "$detail" ]] || detail="status $rc"
    outcome=interrupted
  elif (( rc != 0 )) && [[ "$class" != failure ]]; then
    if (( rc == 124 )); then
      outcome=timed-out
    else
      outcome=failed
    fi
    detail="status $rc"
  elif (( rc == 0 )) && [[ -z "$class" ]]; then
    outcome=done
    detail=""
  fi
  reply=("$outcome" "$detail" \
    "$(( elapsed_ms / 1000 )).${(l:3::0:)$(( elapsed_ms % 1000 ))}")
}

# Records one outcome in the active step slot. Status 0 records, 1 means no
# slot is reachable from this shell (the caller prints its own line), and 2
# rejects an invalid outcome. A report made from a subshell would be lost, so
# it returns 1 instead.
_zdx_step_report() {
  emulate -L zsh
  local outcome="${1-}" detail="${2-}" REPLY
  (( $# == 1 || $# == 2 )) || return 2
  _zdx_outcome_class "$outcome" || return 2
  (( ${+_ZDX_STEP_OUTCOME} && ${+_ZDX_STEP_SHELL} )) || return 1
  (( _ZDX_STEP_SHELL == ZSH_SUBSHELL )) || return 1
  detail="${detail//[[:cntrl:]]/ }"
  (( ${#detail} > 160 )) && detail="${detail[1,159]}…"
  _ZDX_STEP_OUTCOME="$outcome"
  _ZDX_STEP_DETAIL="$detail"
}

# True when the active slot in this shell already holds a report, so a
# delegating parent can keep its child's more specific result.
_zdx_step_reported() {
  emulate -L zsh
  (( ${+_ZDX_STEP_OUTCOME} && ${+_ZDX_STEP_SHELL} )) || return 1
  (( _ZDX_STEP_SHELL == ZSH_SUBSHELL )) && [[ -n "$_ZDX_STEP_OUTCOME" ]]
}

# --- Trusted directory resolution ---------------------------------------------
# _zdx_resolve_trusted_dir <absolute-path>
#
# REPLY is the canonical directory for an absolute, already-normalized path
# (trailing slashes are ignored). A symbolic link on the literal path is
# accepted only as a root-owned system alias, such as macOS /var and /tmp or
# Fedora Atomic /home, or above the final component when the current user owns
# it inside a directory owned by root or the current user that group and other
# users cannot write. Any other link refuses the path. Callers apply their own
# ownership, mode, and ancestor checks to the canonical result. Suites keep a
# private copy of this rule so they stay sourceable on their own; zdx-common.zsh
# repeats it only when the core runtime is absent.
_zdx_resolve_trusted_dir() {
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

# --- Captured child-tool output ----------------------------------------------
# _zdx_run_captured <display> <max_bytes> <replay_lines> <command...>
# _zdx_run_captured_here <display> <max_bytes> <replay_lines> <command...>
#
# The command runs with closed stdin and its stdout and stderr captured in a
# private owner-only directory. On failure the final <replay_lines> lines are
# replayed escaped and credential-redacted; replay_lines 0 never shows output.
# Empty max_bytes or replay_lines select 262144 and 80. ZDX_VERBOSE=1 streams
# the output live to stderr instead (unredacted, except replay_lines 0). The
# _here variant runs without a pipeline so a shell function can change the
# current shell; it bounds only what it reads back, so use it for small output.

# Private: validate and normalize the capture arguments in the caller's scope.
_zdx_capture_check_args() {
  local -i command_words="${1:-0}"
  if [[ -z "$_zdx_cap_display" || "$_zdx_cap_display" == *$'\n'* ]] \
    || (( command_words == 0 )); then
    _zdx_ui_say error "Invalid command-capture arguments."
    return 2
  fi
  [[ -n "$_zdx_cap_max" ]] || _zdx_cap_max=262144
  [[ -n "$_zdx_cap_lines" ]] || _zdx_cap_lines=80
  if [[ ! "$_zdx_cap_max" =~ '^[1-9][0-9]{3,7}$' \
    || ! "$_zdx_cap_lines" =~ '^(0|[1-9][0-9]{0,3})$' ]] \
    || (( _zdx_cap_max < 4096 || _zdx_cap_max > 16777216 \
      || _zdx_cap_lines > 1000 )); then
    _zdx_ui_say error "Invalid command-capture arguments."
    return 2
  fi
}

# Private: REPLY is the canonical temporary root when it is owner-private or a
# root-owned sticky directory. TMPDIR may be reached through a trusted alias,
# such as macOS /var/folders or /tmp (see _zdx_resolve_trusted_dir).
_zdx_capture_parent_safe() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local parent="${TMPDIR:-/tmp}"
  REPLY=""
  _zdx_resolve_trusted_dir "$parent" || return 1
  parent="$REPLY"
  REPLY=""
  [[ -d "$parent" && ! -L "$parent" ]] || return 1
  local -A state=()
  zstat -L -H state -- "$parent" 2>/dev/null || return 1
  if (( state[uid] == EUID && (state[mode] & 8#022) == 0 )); then
    :
  elif (( state[uid] == 0 && (state[mode] & 8#1000) != 0 )); then
    :
  else
    return 1
  fi
  REPLY="$parent"
}

# Private: create the private directory and log in the caller's scope.
_zdx_capture_open() {
  local REPLY parent=""
  _zdx_capture_parent_safe || {
    _zdx_ui_say error \
      "TMPDIR must be an owner-private or root-owned sticky directory for command capture."
    return 1
  }
  parent="$REPLY"
  _zdx_cap_dir=$(umask 077; command mktemp -d \
    "$parent/zdx-capture.XXXXXX" 2>/dev/null) || {
    _zdx_cap_dir=""
    _zdx_ui_say error "A private command-capture directory could not be created."
    return 1
  }
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local -A state=()
  if [[ "${_zdx_cap_dir:h}" != "$parent" || ! -d "$_zdx_cap_dir" \
    || -L "$_zdx_cap_dir" ]] \
    || ! zstat -L -H state -- "$_zdx_cap_dir" 2>/dev/null \
    || (( state[uid] != EUID || (state[mode] & 8#077) != 0 )); then
    _zdx_ui_say error "The private command-capture directory failed validation."
    return 1
  fi
  _zdx_cap_dir_id="${state[device]}:${state[inode]}"
  _zdx_cap_log="$_zdx_cap_dir/output.log"
  if ! (umask 077; : >| "$_zdx_cap_log") 2>/dev/null \
    || [[ ! -f "$_zdx_cap_log" || -L "$_zdx_cap_log" ]] \
    || ! zstat -L -H state -- "$_zdx_cap_log" 2>/dev/null \
    || (( state[uid] != EUID || state[nlink] != 1 \
      || (state[mode] & 8#077) != 0 )); then
    _zdx_ui_say error "The private command-capture log failed validation."
    return 1
  fi
  _zdx_cap_log_id="${state[device]}:${state[inode]}"
}

# Private: announce the command before it runs.
_zdx_capture_announce() {
  local suffix="  (output shown on failure)"
  case "${1-}" in
    live)   suffix="" ;;
    hidden) suffix="  (output not shown)" ;;
  esac
  _zdx_ui_say dim "\$ ${_zdx_cap_display}${suffix}"
}

# Private: return the effective status from the pipeline statuses. An
# interruption wins; a failed sink fails an otherwise successful command.
_zdx_capture_finish() {
  local -i command_rc="${1:-1}" sink_rc="${2:-0}"
  if (( command_rc == 130 || command_rc == 143 )); then
    return $command_rc
  elif (( sink_rc == 130 || sink_rc == 143 )); then
    return $sink_rc
  elif (( command_rc == 0 && sink_rc != 0 )); then
    _zdx_ui_say dim "output capture failed (status $sink_rc)"
    return $sink_rc
  fi
  return $command_rc
}

# Private: true when a captured line may contain a credential.
_zdx_capture_line_sensitive() {
  emulate -L zsh
  local normalized="${1:l}"
  [[ "$normalized" == *password* || "$normalized" == *passwd* \
    || "$normalized" == *passphrase* || "$normalized" == *token* \
    || "$normalized" == *secret* || "$normalized" == *authorization* \
    || "$normalized" == *credential* || "$normalized" == *bearer* \
    || "$normalized" == *api-key* || "$normalized" == *api_key* \
    || "$normalized" == *apikey* || "$normalized" == *access-key* \
    || "$normalized" == *access_key* || "$normalized" == *"private key"* \
    || "$normalized" == *private-key* || "$normalized" == *private_key* \
    || "$normalized" == *signature* || "$normalized" == *cookie* ]] \
    && return 0
  [[ "$normalized" =~ '://[^/@[:space:]]+:[^/@[:space:]]*@' ]]
}

# Private: replay the final lines of the captured log after a failure.
_zdx_capture_replay() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local -i rc="${1:-1}"
  (( _zdx_cap_lines > 0 )) || return 0
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 0
  local -A state=()
  if [[ ! -f "$_zdx_cap_log" || -L "$_zdx_cap_log" ]] \
    || ! zstat -L -H state -- "$_zdx_cap_log" 2>/dev/null \
    || [[ "${state[device]}:${state[inode]}" != "$_zdx_cap_log_id" ]]; then
    _zdx_ui_say warn "Captured output could not be verified and is not shown."
    return 0
  fi
  if (( state[size] == 0 )); then
    _zdx_ui_say dim "no output (status $rc)"
    return 0
  fi
  local -i truncated=0
  (( state[size] >= _zdx_cap_max )) && truncated=1
  local -a captured=()
  captured=("${(@f)$(command tail -n "$(( _zdx_cap_lines + truncated ))" \
    -- "$_zdx_cap_log" 2>/dev/null)}")
  # A byte-truncated log can start with a partial line.
  (( truncated && ${#captured} > _zdx_cap_lines )) && shift captured
  local note="status $rc, last ${#captured} lines"
  (( ${#captured} == 1 )) && note="status $rc, last line"
  (( truncated )) && note+="; earlier output truncated"
  _zdx_ui_say dim "output ($note):"
  local line esc=$'\e'
  for line in "${captured[@]}"; do
    line="${line%$'\r'}"
    line="${line##*$'\r'}"
    line="${line//${esc}\[[0-9;]#m/}"
    if _zdx_capture_line_sensitive "$line"; then
      _zdx_ui_say dim "│ [redacted potentially sensitive output]"
    else
      (( ${#line} > 1000 )) && line="${line[1,1000]}…"
      _zdx_ui_say dim "│ $line"
    fi
  done
}

# Private: remove the exact private log and directory.
_zdx_capture_close() {
  zmodload -F zsh/stat b:zstat 2>/dev/null
  local -A state=()
  local -i failed=0
  if [[ -n "$_zdx_cap_log" && -e "$_zdx_cap_log" ]]; then
    if [[ -f "$_zdx_cap_log" && ! -L "$_zdx_cap_log" ]] \
      && zstat -L -H state -- "$_zdx_cap_log" 2>/dev/null \
      && [[ "${state[device]}:${state[inode]}" == "$_zdx_cap_log_id" ]]; then
      command rm -f -- "$_zdx_cap_log" 2>/dev/null || failed=1
    else
      failed=1
    fi
  fi
  if [[ -n "$_zdx_cap_dir" && -d "$_zdx_cap_dir" && ! -L "$_zdx_cap_dir" ]] \
    && zstat -L -H state -- "$_zdx_cap_dir" 2>/dev/null \
    && [[ "${state[device]}:${state[inode]}" == "$_zdx_cap_dir_id" ]]; then
    command rmdir -- "$_zdx_cap_dir" 2>/dev/null || failed=1
  elif [[ -n "$_zdx_cap_dir" && -e "$_zdx_cap_dir" ]]; then
    failed=1
  fi
  (( failed )) && _zdx_ui_say warn \
    "Could not remove the private output directory $_zdx_cap_dir; remove it manually."
  return 0
}

_zdx_run_captured() {
  setopt LOCAL_OPTIONS NO_PIPE_FAIL
  local _zdx_cap_display="${1-}" _zdx_cap_max="${2-}" _zdx_cap_lines="${3-}"
  local _zdx_cap_dir="" _zdx_cap_log="" _zdx_cap_dir_id="" _zdx_cap_log_id=""
  local -i _zdx_cap_rc=0
  shift 3 2>/dev/null || { _zdx_ui_say error "Invalid command-capture arguments."; return 2; }
  _zdx_capture_check_args "$#" || return 2
  if (( _zdx_cap_lines > 0 )) && _zdx_ui_verbose; then
    _zdx_capture_announce live
    ( "$@" ) </dev/null >&2 || return $?
    return 0
  fi
  {
    _zdx_capture_open || return 1
    if (( _zdx_cap_lines == 0 )); then
      _zdx_capture_announce hidden
    else
      _zdx_capture_announce captured
    fi
    "$@" </dev/null 2>&1 | command tail -c "$_zdx_cap_max" >|"$_zdx_cap_log"
    _zdx_capture_finish "${pipestatus[@]}"
    _zdx_cap_rc=$?
    (( _zdx_cap_rc == 0 )) || _zdx_capture_replay "$_zdx_cap_rc"
  } always {
    [[ -n "$_zdx_cap_dir" ]] && _zdx_capture_close
  }
  return $_zdx_cap_rc
}

_zdx_run_captured_here() {
  local _zdx_cap_display="${1-}" _zdx_cap_max="${2-}" _zdx_cap_lines="${3-}"
  local _zdx_cap_dir="" _zdx_cap_log="" _zdx_cap_dir_id="" _zdx_cap_log_id=""
  local -i _zdx_cap_rc=0
  shift 3 2>/dev/null || { _zdx_ui_say error "Invalid command-capture arguments."; return 2; }
  _zdx_capture_check_args "$#" || return 2
  if (( _zdx_cap_lines > 0 )) && _zdx_ui_verbose; then
    _zdx_capture_announce live
    "$@" </dev/null >&2 || return $?
    return 0
  fi
  {
    _zdx_capture_open || return 1
    if (( _zdx_cap_lines == 0 )); then
      _zdx_capture_announce hidden
    else
      _zdx_capture_announce captured
    fi
    "$@" </dev/null >|"$_zdx_cap_log" 2>&1 || _zdx_cap_rc=$?
    _zdx_capture_finish "$_zdx_cap_rc" 0
    _zdx_cap_rc=$?
    (( _zdx_cap_rc == 0 )) || _zdx_capture_replay "$_zdx_cap_rc"
  } always {
    [[ -n "$_zdx_cap_dir" ]] && _zdx_capture_close
  }
  return $_zdx_cap_rc
}

# --- Bounded execution ---------------------------------------------------------
# _zdx_run_with_timeout <seconds> <command...>
#
# Runs one command with a wall-clock bound and returns its status, or 124 when
# the bound expired. <seconds> is an unsigned integer of at most six digits; 0
# runs the command without a bound. Invalid arguments return 2 before anything
# runs. GNU or BusyBox `timeout` is preferred, then `gtimeout` (Homebrew
# coreutils on macOS); both get a two-second KILL grace, so a command that
# ignores TERM can end with 137. Without either, a Zsh `zselect` watchdog sends
# TERM to the command's process tree at the deadline and KILL one second later;
# its expiry marker lives below a validated TMPDIR. The command inherits the
# caller's stdin, stdout, and stderr; this service prints nothing on success.

# Private: reply is the PID and every descendant visible in one portable
# pid/ppid snapshot. The PID itself remains available when ps fails.
_zdx_timeout_tree_pids() {
  emulate -L zsh
  local root_pid="${1-}"
  reply=("$root_pid")
  [[ "$root_pid" == <-> ]] || return 2

  local process_output=""
  process_output=$(command ps -Ao pid=,ppid= 2>/dev/null) || return 0
  local -a process_lines=("${(@f)process_output}") process_fields=()
  local -A selected=("$root_pid" 1)
  local -i changed=1 pass=0
  local process_line="" process_pid="" parent_pid=""

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

  reply=("${(k)selected[@]}")
}

# Private: send one signal to a process and its visible descendants.
_zdx_timeout_signal_tree() {
  local root_pid="${1-}" signal_name="${2-}"
  local -a reply=()
  _zdx_timeout_tree_pids "$root_pid" || reply=("$root_pid")
  (( ${#reply[@]} > 0 )) \
    && builtin kill "-$signal_name" "${reply[@]}" 2>/dev/null
  return 0
}

# Private: the Zsh watchdog used when neither timeout nor gtimeout exists.
_zdx_timeout_watchdog() {
  setopt LOCAL_OPTIONS NO_MONITOR
  local -i seconds="${1-0}"
  shift
  local REPLY="" parent="" timeout_marker=""
  _zdx_capture_parent_safe || {
    _zdx_ui_say error \
      "TMPDIR must be an owner-private or root-owned sticky directory for bounded commands."
    return 1
  }
  parent="$REPLY"
  timeout_marker=$(umask 077; command mktemp \
    "$parent/zdx-timeout.XXXXXX" 2>/dev/null) || return 1
  [[ "${timeout_marker:h}" == "$parent" && -f "$timeout_marker" \
    && ! -L "$timeout_marker" ]] || return 1
  local -i command_pid=0 watchdog_pid=0 command_rc=0 timed_out=0

  "$@" &
  command_pid=$!
  (
    if zmodload zsh/zselect 2>/dev/null; then
      zselect -t "$(( seconds * 100 ))" 2>/dev/null || true
    else
      command sleep "$seconds"
    fi
    print -r -- "expired" >| "$timeout_marker" 2>/dev/null || exit 1
    _zdx_timeout_signal_tree "$command_pid" TERM
    if zmodload zsh/zselect 2>/dev/null; then
      zselect -t 100 2>/dev/null || true
    else
      command sleep 1
    fi
    _zdx_timeout_signal_tree "$command_pid" KILL
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
      _zdx_timeout_signal_tree "$command_pid" TERM
      wait "$command_pid" 2>/dev/null
    fi
    command rm -f -- "$timeout_marker" 2>/dev/null
  }

  (( timed_out )) && return 124
  return $command_rc
}

_zdx_run_with_timeout() {
  # No emulate here: a shell-function command keeps the caller's options.
  local seconds="${1-}"
  [[ -n "$seconds" && "$seconds" != *[^0-9]* && ${#seconds} -le 6 ]] \
    || return 2
  shift
  (( $# > 0 )) || return 2

  if (( seconds == 0 )); then
    "$@"
  elif command -v timeout &>/dev/null; then
    # GNU coreutils and current BusyBox both support -k. Avoid capability
    # probes such as `timeout --help`: the probe itself could block forever.
    command timeout -k 2s "${seconds}s" "$@"
  elif command -v gtimeout &>/dev/null; then
    command gtimeout -k 2s "${seconds}s" "$@"
  else
    _zdx_timeout_watchdog "$seconds" "$@"
  fi
}

# --- Optimized Lazy Loading (Autoloading Diferido) ---------------------------
# To minimize shell startup time, we define lightweight stubs for public commands.
# The real implementation file is only sourced on first execution of the command.
# Under test environments or when explicitly disabled, we fall back to eager loading.

typeset _zdx_core_dir="${${(%):-%x}:A:h}"
typeset -g _ZDX_FUNCTIONS_DIR="$_zdx_core_dir/functions"

# Check if eager loading is requested or if we are in a test sandbox
typeset -i _zdx_eager_load=0
if [[ "${ZDX_EAGER_LOAD:-}" == "1" || "${ZDX_LAZY_LOAD:-}" == "0" || -n "${TEST_TEMP_DIR:-}" || -n "${BATS_TEST_DIRNAME:-}" ]]; then
  _zdx_eager_load=1
fi

if (( _zdx_eager_load )); then
  # Eager Loading: Source all top-level .zsh files immediately (fallback / test mode)
  if [[ -d "$_ZDX_FUNCTIONS_DIR" ]]; then
    typeset _zdx_function_file
    for _zdx_function_file in "$_ZDX_FUNCTIONS_DIR"/*.zsh(N); do
      if [[ -f "$_zdx_function_file" && -r "$_zdx_function_file" ]]; then
        source "$_zdx_function_file" || {
          typeset -i _zdx_source_rc=$?
          print -u2 -r -- \
            "zdx: failed to load ${_zdx_function_file:t}"
          unset _zdx_core_dir _zdx_eager_load _zdx_function_file
          {
            return $_zdx_source_rc 2>/dev/null || exit $_zdx_source_rc
          } always {
            unset _zdx_source_rc
          }
        }
      fi
    done
    unset _zdx_function_file
  fi
else
  # Lazy Loading: Register stubs for public commands to avoid shell startup penalties

  typeset -gA _ZDX_LAZY_FILES=(
    dev-menu dev-menu.zsh
    env-menu env-menu.zsh
    env-dotenv env-menu.zsh
    env-list env-menu.zsh
    env-path env-menu.zsh
    file-menu file-menu.zsh
    file-clean-junk file-menu.zsh
    file-compress file-menu.zsh
    file-extract file-menu.zsh
    file-find-large file-menu.zsh
    file-trash file-menu.zsh
    git-menu git-menu.zsh
    py-menu py-menu.zsh
    package-install py-menu.zsh
    package-search py-menu.zsh
    package-uninstall py-menu.zsh
    tool-install py-menu.zsh
    tool-list py-menu.zsh
    tool-uninstall py-menu.zsh
    tool-upgrade py-menu.zsh
    venv-activate py-menu.zsh
    venv-create py-menu.zsh
    venv-info py-menu.zsh
    venv-list py-menu.zsh
    venv-python-install py-menu.zsh
    venv-python-list py-menu.zsh
    venv-python-pin py-menu.zsh
    venv-rebuild py-menu.zsh
    venv-remove py-menu.zsh
    sys-menu sys-menu.zsh
    vpn-menu vpn-menu.zsh
    ws-menu ws-menu.zsh
    ws-clone ws-menu.zsh
    ws-jump ws-menu.zsh
    ws-status ws-menu.zsh
    zdx-doctor zdx-doctor.zsh
    zdx-menu zdx-menu.zsh
    zdx zdx-menu.zsh
    zdx-plugins zdx-plugins.zsh
    zdx-status zdx-status.zsh
  )

  # zdir is a compatibility name for an ignored user-local implementation.
  # Register it, and its wsj alias below, only when that file is present, so
  # a fresh clone exposes no command that cannot resolve.
  if [[ -f "$_ZDX_FUNCTIONS_DIR/zdir.zsh" && ! -L "$_ZDX_FUNCTIONS_DIR/zdir.zsh" \
    && -r "$_ZDX_FUNCTIONS_DIR/zdir.zsh" ]]; then
    _ZDX_LAZY_FILES[zdir]=zdir.zsh
  fi

  _zdx_lazy_dispatch() {
    local function_name="$1"
    shift
    local file_name="${_ZDX_LAZY_FILES[$function_name]:-}"
    local module_file="$_ZDX_FUNCTIONS_DIR/$file_name"
    [[ -n "$file_name" && "$function_name" =~ '^[a-z0-9-]+$' \
      && "$file_name" =~ '^[a-z0-9-]+[.]zsh$' \
      && -f "$module_file" && ! -L "$module_file" \
      && -r "$module_file" ]] || {
      print -u2 -r -- \
        "zdx: failed to resolve lazy command ${(V)function_name}"
      return 1
    }

    unset -f "$function_name"
    source "$module_file"
    local source_rc=$?
    if (( source_rc != 0 )) \
      || (( ! ${+functions[$function_name]} )); then
      # Restore the stub so a transient or repaired load failure can be retried.
      functions[$function_name]='_zdx_lazy_dispatch "${funcstack[1]}" "$@"'
      (( source_rc == 0 )) && source_rc=1
      print -u2 -r -- \
        "zdx: failed to load ${(V)function_name} from ${(V)file_name}"
      return $source_rc
    fi
    "$function_name" "$@"
  }

  typeset _zdx_lazy_name
  for _zdx_lazy_name in ${(k)_ZDX_LAZY_FILES}; do
    functions[$_zdx_lazy_name]='_zdx_lazy_dispatch "${funcstack[1]}" "$@"'
  done
  unset _zdx_lazy_name

  # Eagerly register aliases that point to lazy-loaded functions
  if (( ${+_ZDX_LAZY_FILES[zdir]} )); then
    alias wsj='zdir'
  fi
fi

unset _zdx_core_dir _zdx_eager_load

# --- Safe Plugin Loader ------------------------------------------------------
# Scans external directories under ~/.config/zdx/plugins/ and sources
# their entrypoint scripts safely.
typeset -a ZDX_LOADED_PLUGINS
ZDX_LOADED_PLUGINS=()

# Private: true when every ancestor of a canonical path is a real directory
# owned by root or the current user that group and other users cannot write,
# except a root-owned sticky world-writable directory such as /tmp.
_zdx_ancestors_trusted() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local child_path="${1-}" parent_path=""
  [[ "$child_path" == /* && "$child_path" == "${child_path:A}" ]] || return 1
  local -A root_state=() parent_state=()
  zstat -LH root_state -- / 2>/dev/null || return 1
  while [[ "$child_path" != / ]]; do
    parent_path="${child_path:h}"
    parent_state=()
    [[ -d "$parent_path" && ! -L "$parent_path" ]] \
      && zstat -LH parent_state -- "$parent_path" 2>/dev/null || return 1
    if (( (parent_state[uid] != root_state[uid] \
        && parent_state[uid] != EUID) \
      || ((parent_state[mode] & 8#22) != 0 \
        && ! (parent_state[uid] == root_state[uid] \
          && (parent_state[mode] & 8#1000) != 0 \
          && (parent_state[mode] & 8#2) != 0)) )); then
      return 1
    fi
    child_path="$parent_path"
  done
}

# Private: REPLY is the canonical plugin root. The configured path may reach it
# through trusted aliases (_zdx_resolve_trusted_dir), such as HOME below a
# root-owned /home -> var/home link, but the root itself is never a link. The
# canonical root must be owned by the current user and not writable by group
# or other users, below trusted ancestors.
_zdx_plugin_root_resolve() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  local plugins_dir="${1-}" canonical=""
  REPLY=""
  while [[ "$plugins_dir" != / && "$plugins_dir" == */ ]]; do
    plugins_dir="${plugins_dir%/}"
  done
  [[ -d "$plugins_dir" && ! -L "$plugins_dir" ]] || return 1
  _zdx_resolve_trusted_dir "$plugins_dir" || return 1
  canonical="$REPLY"
  REPLY=""
  local -A canonical_state=()
  [[ "$canonical" != / && -d "$canonical" && ! -L "$canonical" \
    && -O "$canonical" ]] \
    && zstat -LH canonical_state -- "$canonical" 2>/dev/null \
    && (( (canonical_state[mode] & 8#22) == 0 )) \
    && _zdx_ancestors_trusted "$canonical" || return 1
  REPLY="$canonical"
}

# Private: true when a canonical plugin root still resolves to itself.
_zdx_plugin_root_safe() {
  local REPLY=""
  _zdx_plugin_root_resolve "${1-}" && [[ "$REPLY" == "${1-}" ]]
}

_zdx_plugin_entrypoint_safe() {
  local plugins_dir="$1"
  local plugin_dir="$2"
  local menu_file="$3"
  local plugins_abs="${plugins_dir:A}"
  local plugin_abs="${plugin_dir:A}"
  local menu_abs="${menu_file:A}"
  local -A menu_state=()

  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zstat -H menu_state "$menu_file" 2>/dev/null \
    && _zdx_plugin_root_safe "$plugins_dir" \
    && [[ -d "$plugin_dir" && ! -L "$plugin_dir" && -O "$plugin_dir" \
      && "${plugin_dir:a}" == "$plugin_abs" \
      && "${plugin_abs:h}" == "$plugins_abs" \
      && -f "$menu_file" && ! -L "$menu_file" && -O "$menu_file" \
      && -r "$menu_file" && "${menu_file:a}" == "$menu_abs" \
      && "${menu_abs:h}" == "$plugin_abs" ]] \
    && (( menu_state[nlink] == 1 ))
}

_zdx_load_plugins() {
  local plugins_dir="${ZDX_PLUGINS_DIR:-$HOME/.config/zdx/plugins}"
  [[ -d "$plugins_dir" ]] || return 0
  local REPLY=""
  _zdx_plugin_root_resolve "$plugins_dir" || {
    print -u2 -r -- \
      "zdx: refusing unsafe plugin root ${(V)plugins_dir}"
    return 0
  }
  # Scan, validate, and source only below the canonical root.
  plugins_dir="$REPLY"

  local plugin_dir plugin_name menu_file
  for plugin_dir in "$plugins_dir"/*(N/); do
    plugin_name="${plugin_dir:t}"
    if [[ "$plugin_name" =~ ^[a-z0-9_-]+$ ]]; then
      menu_file="$plugin_dir/${plugin_name}-menu.zsh"
      if [[ -e "$menu_file" || -L "$menu_file" ]]; then
        _zdx_plugin_entrypoint_safe \
          "$plugins_dir" "$plugin_dir" "$menu_file" || {
          print -u2 -r -- \
            "zdx: refusing unsafe plugin entrypoint '${plugin_name}'"
          continue
        }
        if ! command zsh -n -- "$menu_file"; then
          print -u2 -r -- \
            "zdx: failed to load plugin '${plugin_name}' (invalid Zsh syntax)"
          continue
        fi
        # Repeat the path boundary after validation, immediately before source.
        _zdx_plugin_entrypoint_safe \
          "$plugins_dir" "$plugin_dir" "$menu_file" || {
          print -u2 -r -- \
            "zdx: plugin '${plugin_name}' changed during validation"
          continue
        }
        if source "$menu_file"; then
          if (( ${+functions[${plugin_name}-menu]} )); then
            ZDX_LOADED_PLUGINS+=("$plugin_name")
          else
            print -u2 -r -- \
              "zdx: plugin '${plugin_name}' loaded but failed to define function '${plugin_name}-menu'"
          fi
        else
          print -u2 -r -- \
            "zdx: failed to load plugin '${plugin_name}'"
        fi
      fi
    fi
  done
}
_zdx_load_plugins

# --- Timing & Telemetry Helpers ----------------------------------------------

# Measures wall-clock duration of any command, logs it, and aggregates it
# to a local-only JSON log at ~/.config/zdx/telemetry.json if opted in.

# Ensure zsh/datetime is loaded for EPOCHREALTIME
zmodload zsh/datetime 2>/dev/null

_tk_date_iso8601() {
  if zmodload zsh/datetime 2>/dev/null; then
    local tz
    tz=$(strftime "%z" $EPOCHSECONDS)
    if [[ "$tz" == "Z" ]]; then
      strftime "%Y-%m-%dT%H:%M:%SZ" $EPOCHSECONDS
    elif [[ "$tz" =~ '^([+-][0-9]{2})([0-9]{2})$' ]]; then
      local hours="${match[1]}"
      local mins="${match[2]}"
      local base
      base=$(strftime "%Y-%m-%dT%H:%M:%S" $EPOCHSECONDS)
      echo "${base}${hours}:${mins}"
    else
      strftime "%Y-%m-%dT%H:%M:%S%z" $EPOCHSECONDS
    fi
  else
    date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S"
  fi
}

_zdx_telemetry_dir_safe() {
  local target_dir="$1"
  local home_abs="${HOME:A}"
  local relative_dir="${target_dir#$HOME/}"
  local current_dir="$HOME"
  local component

  [[ "$target_dir" == "$HOME"/* && -n "$relative_dir" ]] || return 1
  for component in "${(@s:/:)relative_dir}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || return 1
    current_dir+="/$component"
    [[ ! -L "$current_dir" ]] || return 1
    if [[ -e "$current_dir" ]]; then
      [[ -d "$current_dir" && -O "$current_dir" ]] || return 1
    fi
  done
  [[ "${target_dir:A}" == "$home_abs"/* ]]
}

_log_telemetry() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local label="$1"
  local elapsed="$2"
  local exit_code="$3"

  local log_dir="$HOME/.config/zdx"
  local log_file="$log_dir/telemetry.json"
  local lock_dir="$log_dir/.telemetry.lock"
  local max_records="${ZDX_TELEMETRY_MAX_RECORDS:-1000}"
  local max_bytes="${ZDX_TELEMETRY_MAX_BYTES:-5242880}"

  [[ "$max_records" =~ '^[0-9]+$' \
    && "$max_records" != 0[0-9]* \
    && ${#max_records} -le 7 ]] \
    && (( max_records > 0 && max_records <= 1000000 )) || return 1
  [[ "$max_bytes" =~ '^[0-9]+$' \
    && "$max_bytes" != 0[0-9]* \
    && ${#max_bytes} -le 9 ]] \
    && (( max_bytes > 0 && max_bytes <= 134217728 )) || return 1
  [[ "$elapsed" =~ '^[0-9]{1,8}([.][0-9]{1,9})?$' ]] || return 1
  [[ "$elapsed" != 0[0-9]* ]] || return 1

  # ISO-8601 UTC timestamp
  local timestamp
  if zmodload zsh/datetime 2>/dev/null; then
    timestamp=$(TZ=UTC strftime "%Y-%m-%dT%H:%M:%SZ" $EPOCHSECONDS)
  else
    if command -v date >/dev/null 2>&1; then
      timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    fi
    timestamp="${timestamp:-$(date)}"
  fi


  # Calculate duration in ms
  local elapsed_ms
  elapsed_ms=$(printf "%.0f" $(( elapsed * 1000 )))

  # Infer suite from label (e.g., "sys:update-system")
  local suite="unknown"
  if [[ "$label" == *":"* ]]; then
    suite="${label%%:*}"
    label="${label#*:}"
  else
    # Fallback heuristics
    if [[ "$label" == vpn-* || "$label" == _vpn_* ]]; then
      suite="vpn"
    elif [[ "$label" == git-* || "$label" == _git_* ]]; then
      suite="git"
    elif [[ "$label" == sys-* || "$label" == _sys_* ]]; then
      suite="sys"
    elif [[ "$label" == dev-* || "$label" == _dev_* ]]; then
      suite="dev"
    fi
  fi

  # Telemetry identifiers are deliberately narrow: arguments, paths, URLs,
  # environment values, and command output never belong in this record.
  [[ "$suite" =~ '^[[:alnum:]_-]{1,32}$' ]] || return 1
  [[ "$label" =~ '^[[:alnum:]_.:@+-]{1,96}$' ]] || return 1
  [[ "$elapsed_ms" =~ '^[0-9]+$' \
    && ${#elapsed_ms} -le 11 \
    && "$elapsed_ms" -le 31536000000 ]] || return 1
  [[ "$exit_code" =~ '^[0-9]+$' \
    && "$exit_code" != 0[0-9]* ]] \
    && (( exit_code <= 255 )) || return 1
  [[ "$timestamp" =~ '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$' ]] \
    || return 1

  local previous_umask
  previous_umask=$(umask)
  local telemetry_tmp=""
  local telemetry_trim=""
  local -i lock_acquired=0 write_rc=0

  {
    umask 077
    _zdx_telemetry_dir_safe "$log_dir" || return 1
    if [[ -e "$log_dir" ]]; then
      [[ -d "$log_dir" && ! -L "$log_dir" && -O "$log_dir" ]] || return 1
    else
      command mkdir -p "$log_dir" 2>/dev/null || return 1
    fi
    _zdx_telemetry_dir_safe "$log_dir" || return 1
    command chmod 700 "$log_dir" 2>/dev/null || return 1

    command mkdir "$lock_dir" 2>/dev/null || return 1
    lock_acquired=1

    if [[ -e "$log_file" ]]; then
      [[ -f "$log_file" && ! -L "$log_file" && -O "$log_file" ]] || return 1
      local existing_bytes
      existing_bytes=$(command wc -c < "$log_file" 2>/dev/null) || return 1
      existing_bytes="${existing_bytes//[[:space:]]/}"
      [[ "$existing_bytes" =~ '^[0-9]+$' \
        && ${#existing_bytes} -le 9 ]] \
        && (( existing_bytes <= max_bytes )) || return 1
    fi

    telemetry_tmp=$(mktemp "$log_dir/.telemetry.XXXXXX") || return 1
    command chmod 600 "$telemetry_tmp" 2>/dev/null || return 1

    if [[ -s "$log_file" ]]; then
      local final_newline_count
      final_newline_count=$(
        command tail -c 1 "$log_file" 2>/dev/null | command wc -l
      ) || return 1
      final_newline_count="${final_newline_count//[[:space:]]/}"
      if [[ "$final_newline_count" == "1" ]]; then
        command tail -n $(( max_records - 1 )) "$log_file" \
          >| "$telemetry_tmp" 2>/dev/null || return 1
      else
        # A crash may leave one partial JSON line. Never join a new record to
        # that fragment; retain only preceding complete records.
        command sed '$d' "$log_file" 2>/dev/null \
          | command tail -n $(( max_records - 1 )) \
            >| "$telemetry_tmp" 2>/dev/null || return 1
      fi
    fi
    printf '{"suite": "%s", "command": "%s", "duration_ms": %d, "exit_code": %d, "timestamp": "%s"}\n' \
      "$suite" "$label" "$elapsed_ms" "$exit_code" "$timestamp" \
      >> "$telemetry_tmp" || return 1

    local pending_bytes
    pending_bytes=$(command wc -c < "$telemetry_tmp" 2>/dev/null) || return 1
    pending_bytes="${pending_bytes//[[:space:]]/}"
    [[ "$pending_bytes" =~ '^[0-9]+$' ]] || return 1
    if (( pending_bytes > max_bytes )); then
      telemetry_trim=$(mktemp "$log_dir/.telemetry-trim.XXXXXX") || return 1
      command chmod 600 "$telemetry_trim" 2>/dev/null || return 1
      command tail -c "$(( max_bytes + 1 ))" "$telemetry_tmp" 2>/dev/null \
        | command sed '1d' >| "$telemetry_trim" || return 1
      [[ -s "$telemetry_trim" ]] || return 1
      pending_bytes=$(command wc -c < "$telemetry_trim" 2>/dev/null) \
        || return 1
      pending_bytes="${pending_bytes//[[:space:]]/}"
      [[ "$pending_bytes" =~ '^[0-9]+$' ]] \
        && (( pending_bytes <= max_bytes )) || return 1
      command mv -f "$telemetry_trim" "$telemetry_tmp" 2>/dev/null \
        || return 1
      telemetry_trim=""
    fi

    command mv -f "$telemetry_tmp" "$log_file" 2>/dev/null || return 1
    telemetry_tmp=""
    command chmod 600 "$log_file" 2>/dev/null || return 1
  } always {
    write_rc=$?
    [[ -n "$telemetry_tmp" && -f "$telemetry_tmp" ]] \
      && command rm -f "$telemetry_tmp" 2>/dev/null
    [[ -n "$telemetry_trim" && -f "$telemetry_trim" ]] \
      && command rm -f "$telemetry_trim" 2>/dev/null
    (( lock_acquired )) && command rmdir "$lock_dir" 2>/dev/null
    umask "$previous_umask"
  }

  return $write_rc
}

_zdx_timed_mark_partial() {
  (( ${+_ZDX_TIMED_OUTCOME} )) || return 1
  _ZDX_TIMED_OUTCOME="partial"
}

_timed() {
  local label="$1"
  shift
  local _ZDX_TIMED_OUTCOME=""
  # Nested timers keep writing telemetry, but only the outermost timer outside
  # an aggregate step prints: step result lines already carry their durations.
  local -i _ZDX_TIMED_DEPTH=$(( ${_ZDX_TIMED_DEPTH:-0} + 1 ))

  local start_time="${EPOCHREALTIME:-}"
  if [[ -z "$start_time" ]]; then
    start_time=$(date +%s)
  fi

  "$@"
  local exit_code=$?

  local end_time="${EPOCHREALTIME:-}"
  if [[ -z "$end_time" ]]; then
    end_time=$(date +%s)
  fi

  local elapsed
  elapsed=$(( end_time - start_time ))
  (( elapsed >= 0 )) || elapsed=0

  if (( _ZDX_TIMED_DEPTH == 1 )) && ! _zdx_step_active; then
    local REPLY="" duration=""
    if _zdx_format_duration "$elapsed"; then
      duration="$REPLY"
    else
      LC_ALL=C printf -v duration '%.1fs' "$elapsed"
    fi

    # Print a status-aware timing message in dim gray.
    local timing_message
    if (( exit_code == 0 )); then
      timing_message="${(V)label} completed in ${duration}"
    elif [[ "$_ZDX_TIMED_OUTCOME" == "partial" ]]; then
      timing_message="${(V)label} completed with partial failures in ${duration} (status $exit_code)"
    else
      timing_message="${(V)label} failed after ${duration} (status $exit_code)"
    fi

    if _zdx_ui_color_enabled; then
      printf '\033[0;90m  %s\033[0m\n' "$timing_message" >&2
    else
      printf '  %s\n' "$timing_message" >&2
    fi
  fi

  # Log to telemetry if user has opted in
  if [[ "${ZDX_TELEMETRY:-}" == "1" || "${ZDX_TELEMETRY:-}" == "true" ]]; then
    local telemetry_elapsed
    # The record grammar requires a dot; LC_NUMERIC could produce a comma.
    LC_ALL=C printf -v telemetry_elapsed '%.9f' "$elapsed"
    _log_telemetry "$label" "$telemetry_elapsed" "$exit_code"
  fi

  return $exit_code
}

# --- Safe User Overrides Loader ----------------------------------------------
# Safely sources user-defined overrides that take precedence over core functions
if [[ -f "$HOME/.config/zdx/overrides.zsh" && -r "$HOME/.config/zdx/overrides.zsh" ]]; then
  source "$HOME/.config/zdx/overrides.zsh" || {
    typeset -i _zdx_overrides_rc=$?
    print -u2 -r -- "zdx: failed to load user overrides"
    {
      return $_zdx_overrides_rc 2>/dev/null || exit $_zdx_overrides_rc
    } always {
      unset _zdx_overrides_rc
    }
  }
fi

typeset -g _ZDX_FUNCTIONS_SOURCED=1
