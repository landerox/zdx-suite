#!/usr/bin/env zsh
# =============================================================================
# System Shell Diagnostics: Zsh startup, PATH, aliases, and functions
# =============================================================================
#
# Loaded by sys-menu.zsh after sys-diag.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_SYS_SHELL_DIAG_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

# --- Zsh startup diagnostics ------------------------------------------------

_sys_startup_usage() {
  print -u2 -r -- 'Usage: sys-startup [-h|--help]'
  print -u2 -r -- 'Benchmark and profile the current interactive Zsh startup.'
  print -u2 -r -- \
    'Warning: startup files run in isolated subprocesses and may have external side effects.'
}

# REPLY: monotonic uptime where Linux exposes it, otherwise a portable
# high-resolution wall-clock value. Callers must reject a regressing fallback.
_sys_diag_clock_seconds() {
  REPLY=""

  if [[ -r /proc/uptime ]]; then
    local uptime_seconds="" ignored=""
    IFS=' ' read -r uptime_seconds ignored < /proc/uptime || return 1
    [[ "$uptime_seconds" =~ '^[0-9]+([.][0-9]+)?$' ]] || return 1
    REPLY="$uptime_seconds"
    return 0
  fi

  zmodload zsh/datetime 2>/dev/null || return 1
  [[ "$EPOCHREALTIME" =~ '^[0-9]+([.][0-9]+)?$' ]] || return 1
  REPLY="$EPOCHREALTIME"
}

# stdout: elapsed milliseconds for one interactive Zsh startup.
_sys_diag_measure_startup_once() {
  local -F started_at finished_at elapsed_ms
  local collection_rc
  _sys_diag_clock_seconds || return 1
  started_at=$REPLY
  # 'exit 0', not a bare 'exit'. A bare exit leaves with the status of the
  # last command run before it, which here is whatever the interactive startup
  # files happened to evaluate last -- commonly a false conditional in
  # /etc/zsh/zshrc or a user rc. That status is unrelated to whether the
  # startup completed, and treating it as a probe failure discards a perfectly
  # good measurement. Only a real timeout or spawn failure should be non-zero.
  _sys_run_with_timeout 15 zsh -i -c 'exit 0' </dev/null >/dev/null 2>&1
  collection_rc=$?
  (( collection_rc == 0 )) || return $collection_rc
  _sys_diag_clock_seconds || return 1
  finished_at=$REPLY
  (( finished_at >= started_at )) || return 1

  elapsed_ms=$(( (finished_at - started_at) * 1000 ))
  printf '%.0f\n' "$elapsed_ms"
}

# stdout: zprof report generated while explicitly sourcing the user's .zshrc.
_sys_diag_profile_startup() {
  local zshrc_file="$HOME/.zshrc"
  [[ -r "$zshrc_file" ]] || return 3

  _sys_run_with_timeout 15 env ZDX_PROFILE_ZSHRC="$zshrc_file" zsh -dfi -c '
    zmodload zsh/zprof || exit 1
    source "$ZDX_PROFILE_ZSHRC"
    zprof
  ' </dev/null 2>/dev/null
}

_sys_diag_render_startup_hints() {
  local zshrc_file="$HOME/.zshrc"
  [[ -r "$zshrc_file" ]] || {
    _sys_dim "No readable ~/.zshrc found for slowdown hints."
    return 0
  }

  if command grep -q 'nvm\.sh' "$zshrc_file" 2>/dev/null; then
    _sys_warn "nvm detected — consider a lazy loader or a faster version manager"
  fi

  local plugin_count
  plugin_count=$(command sed -n '/plugins=(/,/)/p' "$zshrc_file" 2>/dev/null \
    | command sed 's/plugins=(//; s/)//' | command wc -w)
  plugin_count="${plugin_count//[[:space:]]/}"
  if [[ "$plugin_count" =~ '^[0-9]+$' ]]; then
    if (( plugin_count > 15 )); then
      _sys_warn "$plugin_count Oh My Zsh plugins loaded — consider reducing"
    else
      _sys_dim "$plugin_count Oh My Zsh plugins detected"
    fi
  fi

  command grep -q 'pyenv init' "$zshrc_file" 2>/dev/null \
    && _sys_warn "pyenv init detected — consider lazy loading"
  command grep -q 'rbenv init' "$zshrc_file" 2>/dev/null \
    && _sys_warn "rbenv init detected — consider lazy loading"
  command grep -Eq 'conda (init|activate)' "$zshrc_file" 2>/dev/null \
    && _sys_warn "conda initialization detected — consider lazy loading"
  return 0
}

sys-startup() {
  case "${1:-}" in
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_startup_usage
      return 0
      ;;
    "") ;;
    *)
      _sys_error "Unknown option: $1"
      return 2
      ;;
  esac
  (( $# <= 1 )) || {
    _sys_error "sys-startup accepts no positional arguments."
    return 2
  }

  _sys_header "Zsh Startup Time Analysis"
  _sys_warn \
    "This benchmark runs startup files in 11 isolated Zsh subprocesses; their usual external side effects may still occur."
  local -i run_count=10 successful_runs=0 total_ms=0 minimum_ms=0 maximum_ms=0
  local -i run_index measurement_ms
  local measurement collection_rc
  _sys_info "Measuring startup time ($run_count runs)..."

  for (( run_index = 1; run_index <= run_count; run_index++ )); do
    measurement=$(_sys_diag_measure_startup_once)
    collection_rc=$?
    if (( collection_rc != 0 )) || [[ ! "$measurement" =~ '^[0-9]+$' ]]; then
      _sys_warn "Startup measurement $run_index failed (status $collection_rc)"
      continue
    fi

    measurement_ms=$measurement
    (( successful_runs++ ))
    (( total_ms += measurement_ms ))
    if (( successful_runs == 1 || measurement_ms < minimum_ms )); then
      minimum_ms=$measurement_ms
    fi
    (( measurement_ms > maximum_ms )) && maximum_ms=$measurement_ms
  done

  if (( successful_runs == 0 )); then
    _sys_error "Unable to complete any startup measurements."
    return 1
  fi

  local -i average_ms=$(( total_ms / successful_runs ))
  _sys_blank
  _sys_label "Average:" "${average_ms}ms"
  _sys_label "Minimum:" "${minimum_ms}ms"
  _sys_label "Maximum:" "${maximum_ms}ms"
  _sys_label "Samples:" "$successful_runs/$run_count"

  if (( average_ms < 200 )); then
    _sys_success "Startup is fast (< 200ms)"
  elif (( average_ms < 500 )); then
    _sys_warn "Startup is moderate (${average_ms}ms)"
  else
    _sys_error "Startup is slow (${average_ms}ms)"
  fi

  _sys_blank
  _sys_info "Profiling ~/.zshrc with zprof..."
  local profile_output
  profile_output=$(_sys_diag_profile_startup)
  local profile_rc=$?
  if (( profile_rc == 0 )) && [[ -n "$profile_output" ]]; then
    local -a profile_lines=()
    [[ -n "$profile_output" ]] && profile_lines=("${(@f)profile_output}")
    local -i profile_limit=${#profile_lines}
    (( profile_limit > 25 )) && profile_limit=25
    for (( run_index = 1; run_index <= profile_limit; run_index++ )); do
      _sys_dim "$(_sys_display_escape "${profile_lines[run_index]}")"
    done
  elif (( profile_rc == 3 )); then
    _sys_dim "No readable ~/.zshrc found for profiling."
  else
    _sys_dim "Could not capture zprof output from the isolated profile run."
  fi

  _sys_blank
  _sys_info "Checking for common slowdowns..."
  _sys_diag_render_startup_hints
  return 0
}

# --- PATH diagnostics -------------------------------------------------------

_sys_path_usage() {
  print -u2 -r -- 'Usage: sys-path [-h|--help]'
  print -u2 -r -- 'Inspect PATH entries without modifying shell configuration.'
}

sys-path() {
  case "${1:-}" in
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_path_usage
      return 0
      ;;
    "") ;;
    *)
      _sys_error "Unknown option: $1"
      return 2
      ;;
  esac
  (( $# <= 1 )) || {
    _sys_error "sys-path accepts no positional arguments."
    return 2
  }

  _sys_header "PATH Inspector"
  local -a path_entries=("${path[@]}")
  local -i total_entries=${#path_entries} duplicate_count=0
  local -i missing_count=0 current_directory_count=0 entry_index=0
  local -A seen_entries=()

  _sys_info "Analyzing $total_entries entries in \$PATH..."
  _sys_blank

  local directory_entry entry_key display_path entry_state first_index
  for directory_entry in "${path_entries[@]}"; do
    (( entry_index++ ))
    entry_key="entry:${directory_entry}"
    display_path="${directory_entry:-$PWD}"
    display_path=$(_sys_display_escape "$display_path")
    entry_state="ok"

    if [[ -n "${seen_entries[$entry_key]:-}" ]]; then
      first_index="${seen_entries[$entry_key]}"
      entry_state="duplicate of #$first_index"
      (( duplicate_count++ ))
    else
      seen_entries[$entry_key]=$entry_index
      if [[ -z "$directory_entry" ]]; then
        entry_state="current directory"
        (( current_directory_count++ ))
      elif [[ ! -d "$directory_entry" ]]; then
        entry_state="missing"
        (( missing_count++ ))
      fi
    fi

    printf '  %3d  [%-16s] %s\n' \
      "$entry_index" "$entry_state" "$display_path" >&2
  done

  _sys_blank
  _sys_label "Total entries:" "$total_entries"
  (( duplicate_count > 0 )) \
    && _sys_warn "$duplicate_count duplicate(s) found" \
    || _sys_success "No duplicates"
  (( missing_count > 0 )) \
    && _sys_warn "$missing_count missing directory(ies)" \
    || _sys_success "All explicit directories exist"
  (( current_directory_count > 0 )) \
    && _sys_warn "$current_directory_count empty PATH entry exposes the current directory"

  if (( duplicate_count > 0 )); then
    if [[ -r "$HOME/.zshrc" ]] \
      && command grep -q 'typeset -U PATH' "$HOME/.zshrc" 2>/dev/null; then
      _sys_dim "'typeset -U PATH' is already present in ~/.zshrc."
    else
      _sys_dim "Recommendation: review ~/.zshrc and consider 'typeset -U PATH'."
    fi
  fi
  return 0
}

# --- Alias and function diagnostics ----------------------------------------

_sys_aliases_usage() {
  print -u2 -r -- 'Usage:'
  print -u2 -r -- '  sys-aliases [all|aliases|functions]'
  print -u2 -r -- '  sys-aliases --list [all|aliases|functions]'
  print -u2 -r -- '  sys-aliases -h|--help'
  print -u2 -r -- ''
  print -u2 -r -- '--list emits TSV records: kind<TAB>name.'
}

# stdout TSV records: symbol kind, validated symbol name.
_sys_diag_symbol_records() {
  local symbol_mode="${1:-all}"
  case "$symbol_mode" in
    all|aliases|functions) ;;
    *) return 2 ;;
  esac

  local symbol_name
  if [[ "$symbol_mode" == "all" || "$symbol_mode" == "aliases" ]]; then
    for symbol_name in ${(ok)aliases}; do
      [[ "$symbol_name" =~ '^[A-Za-z0-9][A-Za-z0-9_.:+@%-]*$' ]] || continue
      printf 'alias\t%s\n' "$symbol_name"
    done
  fi

  if [[ "$symbol_mode" == "all" || "$symbol_mode" == "functions" ]]; then
    for symbol_name in ${(ok)functions}; do
      [[ "$symbol_name" == _* ]] && continue
      [[ "$symbol_name" =~ '^[A-Za-z0-9][A-Za-z0-9_.:+@%-]*$' ]] || continue
      printf 'function\t%s\n' "$symbol_name"
    done
  fi
}

sys-aliases() {
  local REPLY
  local symbol_mode="all" list_only=0

  case "${1:-}" in
    -h|--help)
      (( $# == 1 )) || {
        _sys_error "--help accepts no arguments."
        return 2
      }
      _sys_aliases_usage
      return 0
      ;;
    --list)
      list_only=1
      symbol_mode="${2:-all}"
      (( $# <= 2 )) || {
        _sys_error "Too many arguments for sys-aliases --list."
        return 2
      }
      ;;
    all|aliases|functions)
      symbol_mode="$1"
      (( $# == 1 )) || {
        _sys_error "Too many arguments for sys-aliases."
        return 2
      }
      ;;
    "") ;;
    *)
      _sys_error "Unknown option or mode: $1"
      return 2
      ;;
  esac

  case "$symbol_mode" in
    all|aliases|functions) ;;
    *)
      _sys_error "Unknown symbol mode: $symbol_mode"
      return 2
      ;;
  esac

  if (( list_only )); then
    _sys_diag_symbol_records "$symbol_mode"
    return $?
  fi

  _sys_header "Aliases & Functions Browser"
  if ! command -v fzf &>/dev/null; then
    _sys_error "fzf not found. Use 'sys-aliases --list' for non-interactive output."
    return 1
  fi

  local records_output
  records_output=$(_sys_diag_symbol_records "$symbol_mode") || return 1
  local -a symbol_records=()
  [[ -n "$records_output" ]] && symbol_records=("${(@f)records_output}")
  if (( ${#symbol_records} == 0 )); then
    _sys_info "No matching aliases or public functions found."
    return 0
  fi

  local selected_record=""
  local -i select_rc=0
  _sys_fzf_capture \
    --delimiter=$'\t' \
    --with-nth=1,2 \
    --preview='' \
    --preview-window=hidden \
    --prompt='Symbols > ' \
    --header='Select a symbol to inspect; Esc returns without output' \
    < <(printf '%s\n' "${symbol_records[@]}") || select_rc=$?
  selected_record="$REPLY"
  if (( select_rc != 0 )); then
    (( select_rc == 1 || select_rc == 130 )) && return 0
    _sys_error \
      "fzf failed while browsing aliases and functions (status $select_rc)."
    return 1
  fi
  [[ -n "$selected_record" ]] || return 0
  (( ${symbol_records[(Ie)$selected_record]} > 0 )) || {
    _sys_error "The selected symbol was not in the browser snapshot."
    return 1
  }

  local symbol_kind symbol_name
  IFS=$'\t' read -r symbol_kind symbol_name <<< "$selected_record"
  [[ "$symbol_name" =~ '^[A-Za-z0-9][A-Za-z0-9_.:+@%-]*$' ]] || {
    _sys_error "Invalid symbol record returned by fzf."
    return 1
  }

  case "$symbol_kind" in
    alias)
      [[ -n "${aliases[$symbol_name]+defined}" ]] || return 1
      ;;
    function)
      [[ -n "${functions[$symbol_name]+defined}" ]] || return 1
      ;;
    *)
      _sys_error "Unknown symbol kind returned by fzf."
      return 1
      ;;
  esac
  _sys_info "Selected $symbol_kind: $symbol_name"
  _sys_dim "Definition hidden to prevent secret disclosure."
  return 0
}

typeset -g _SYS_SHELL_DIAG_SOURCED=1
