#!/usr/bin/env zsh
# =============================================================================
# AI Log: bounded recent-log excerpts
# =============================================================================
#
# Loaded by ai-menu.zsh after ai-common.zsh.
# Safe to re-source; defines functions only.
#

if [[ -n "${_AI_LOG_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _AI_LOG_MAX_CANDIDATES=512
typeset -gi _AI_LOG_MAX_FILE_BYTES=67108864
typeset -gi _AI_LOG_READ_BYTES=262144
typeset -gi _AI_LOG_MAX_LINE_CHARS=4096
typeset -gi _AI_LOG_MAX_SCAN_BYTES=8388608
typeset -gi _AI_LOG_LINES=50

_ai_log_usage() {
  print -u2 -r -- "Usage: ai-log-tail [--lines N] [--verbose]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Print a bounded, redacted excerpt of the newest recognized log per assistant."
  print -u2 -r -- ""
  print -u2 -r -- "Flags:"
  print -u2 -r -- "  --lines N       Lines to print, from 1 to 500 (default: 50)"
  print -u2 -r -- "  --verbose, -v   Show additional diagnostics"
  print -u2 -r -- "  --help, -h      Show this help"
}

_ai_log_parse() {
  _AI_LOG_LINES=50
  while (( $# )); do
    case "$1" in
      --lines)
        (( $# >= 2 )) && [[ "$2" == <-> ]] \
          && (( $2 >= 1 && $2 <= 500 )) || {
          _ai_error "--lines requires an integer from 1 to 500."
          return 2
        }
        _AI_LOG_LINES="$2"
        shift
        ;;
      --verbose|-v)
        _AI_VERBOSE=1
        ;;
      --help|-h)
        _ai_log_usage
        return 64
        ;;
      --)
        shift
        (( $# == 0 )) || {
          _ai_error "Unexpected log operand: $1"
          return 2
        }
        break
        ;;
      -*)
        _ai_error "Unknown log option: $1"
        return 2
        ;;
      *)
        _ai_error "Unexpected log operand: $1"
        return 2
        ;;
    esac
    shift
  done
}

_ai_log_candidate_kind() {
  local root="$1" candidate="$2" kind="$3"
  [[ "$candidate" == "$root"/* ]] || return 1
  local relative="${candidate#$root/}"
  local -a parts=("${(@s:/:)relative}")
  case "$kind" in
    claude)
      (( ${#parts[@]} >= 1 && ${#parts[@]} <= 3 )) \
        && [[ "${parts[-1]}" == *.jsonl ]]
      ;;
    direct-log)
      (( ${#parts[@]} == 1 )) && [[ "${parts[1]}" == *.log ]]
      ;;
    nested-log)
      (( ${#parts[@]} >= 1 && ${#parts[@]} <= 2 )) \
        && [[ "${parts[-1]}" == *.log ]]
      ;;
    cursor)
      (( ${#parts[@]} >= 2 && ${#parts[@]} <= 3 )) \
        && [[ "${parts[-1]}" == worker.log ]]
      ;;
    *) return 2 ;;
  esac
}

_ai_log_latest() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local root="$1" kind="$2"
  reply=()
  [[ -d "$root" && ! -L "$root" && -O "$root" \
    && "$root" == "${root:A}" ]] || return 1

  local depth=0
  local name_pattern=""
  case "$kind" in
    claude) depth=3; name_pattern='*.jsonl' ;;
    cursor) depth=3; name_pattern='worker.log' ;;
    direct-log) depth=1; name_pattern='*.log' ;;
    nested-log) depth=2; name_pattern='*.log' ;;
    *) return 2 ;;
  esac

  local temp_parent="${TMPDIR:-/tmp}"
  [[ "$temp_parent" == /* ]] || return 2
  temp_parent="${temp_parent:A}"
  _ai_temp_parent_check "$temp_parent" || {
    _ai_error "Refusing an unsafe temporary root for log inventory."
    return 2
  }
  local temp_parent_identity="$REPLY"
  local scan_dir=""
  scan_dir=$(umask 077; command mktemp -d \
    "$temp_parent/zdx-ai-log.XXXXXX" 2>/dev/null) || return 2
  local scan_file="$scan_dir/candidates"
  local -A dir_before=() dir_after=() file_before=() file_after=()
  local -i operation_rc=1 cleanup_rc=0 scan_rc=1
  [[ "$scan_dir" == "${scan_dir:A}" && "${scan_dir:h}" == "$temp_parent" \
    && "${scan_dir:t}" == zdx-ai-log.* && -d "$scan_dir" \
    && ! -L "$scan_dir" && -O "$scan_dir" ]] \
    && zstat -LH dir_before -- "$scan_dir" 2>/dev/null \
    && (( dir_before[uid] == EUID && dir_before[nlink] == 2 \
      && (dir_before[mode] & 8#077) == 0 )) || return 2

  local candidate="" latest="" latest_fingerprint="" home_root="${HOME:A}"
  local -i latest_mtime=-1
  local -A state=()
  {
    (umask 077; : > "$scan_file") || return 2
    zstat -LH file_before -- "$scan_file" 2>/dev/null || return 2
    local timeout_bin=""
    if command -v timeout >/dev/null 2>&1; then
      timeout_bin="$(command -v timeout)"
    elif command -v gtimeout >/dev/null 2>&1; then
      timeout_bin="$(command -v gtimeout)"
    else
      return 2
    fi
    (
      ulimit -f 16384 2>/dev/null || exit 1
      command "$timeout_bin" --foreground --kill-after=1s 10s \
        find "$root" -mindepth 1 -maxdepth "$depth" -type f \
        -name "$name_pattern" -print0 \
        > "$scan_file" 2>/dev/null
    )
    scan_rc=$?
    (( scan_rc == 0 )) || return 2
    zstat -LH file_after -- "$scan_file" 2>/dev/null \
      && [[ "${file_before[device]}:${file_before[inode]}:"\
"${file_before[uid]}:${file_before[nlink]}" \
        == "${file_after[device]}:${file_after[inode]}:"\
"${file_after[uid]}:${file_after[nlink]}" ]] \
      && (( file_after[size] >= 0 \
        && file_after[size] <= _AI_LOG_MAX_SCAN_BYTES )) || return 2

    local -i candidate_count=0
    while IFS= read -r -d '' candidate; do
      [[ "$candidate" == "$home_root"/* && "$candidate" == "${candidate:A}" \
        && "$candidate" != *'|'* && "$candidate" != *[[:cntrl:]]* \
        && -f "$candidate" && ! -L "$candidate" && -O "$candidate" ]] \
        || continue
      _ai_log_candidate_kind "$root" "$candidate" "$kind" || continue
      (( candidate_count += 1 ))
      (( candidate_count <= _AI_LOG_MAX_CANDIDATES )) || {
        _ai_error "Log inventory exceeds $_AI_LOG_MAX_CANDIDATES files: $root"
        return 2
      }
      state=()
      zstat -LH state -- "$candidate" 2>/dev/null || continue
      (( state[nlink] == 1 && state[size] >= 0 \
        && state[size] <= _AI_LOG_MAX_FILE_BYTES )) || continue
      if (( state[mtime] > latest_mtime )); then
        latest="$candidate"
        latest_mtime=${state[mtime]}
        latest_fingerprint="${state[device]}:${state[inode]}:${state[mode]}:"\
"${state[uid]}:${state[nlink]}:${state[size]}:${state[mtime]}"
      fi
    done < "$scan_file"
    [[ -n "$latest" ]] || return 1
    operation_rc=0
  } always {
    if [[ -f "$scan_file" && ! -L "$scan_file" ]] \
      && zstat -LH file_after -- "$scan_file" 2>/dev/null \
      && [[ "${file_before[device]}:${file_before[inode]}:${file_before[uid]}" \
        == "${file_after[device]}:${file_after[inode]}:${file_after[uid]}" ]]; then
      command rm -f -- "$scan_file" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    if [[ -d "$scan_dir" && ! -L "$scan_dir" ]] \
      && zstat -LH dir_after -- "$scan_dir" 2>/dev/null \
      && [[ "${dir_before[device]}:${dir_before[inode]}:${dir_before[uid]}" \
        == "${dir_after[device]}:${dir_after[inode]}:${dir_after[uid]}" ]]; then
      command rmdir -- "$scan_dir" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    _ai_temp_parent_check "$temp_parent" \
      && [[ "$REPLY" == "$temp_parent_identity" ]] || cleanup_rc=1
    (( cleanup_rc == 0 )) || operation_rc=2
  }
  (( operation_rc == 0 )) || return 2
  [[ -n "$latest" ]] || return 1
  reply=("$latest" "$latest_fingerprint")
}

_ai_log_matches() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local log_file="$1" expected="$2"
  [[ -f "$log_file" && ! -L "$log_file" && -O "$log_file" \
    && "$log_file" == "${log_file:A}" ]] || return 1
  local -A state=()
  zstat -LH state -- "$log_file" 2>/dev/null || return 1
  [[ "${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}:"\
"${state[nlink]}:${state[size]}:${state[mtime]}" == "$expected" ]]
}

_ai_log_redact() {
  emulate -L zsh
  setopt local_options extended_glob nocasematch
  local redacted="$1"
  if [[ "$redacted" =~ \
'(api[_-]?key|access[_-]?key|access[_-]?token|auth(orization)?|bearer|password|passwd|secret|session[_-]?token|cookie|private[[:space:]_-]?key|aws_access_key_id)' \
    || "$redacted" == *'-----BEGIN '*'PRIVATE KEY-----'* \
    || "$redacted" == *'-----END '*'PRIVATE KEY-----'* ]]; then
    REPLY="[REDACTED_SENSITIVE_LINE]"
    return 0
  fi
  redacted="${redacted//(#bi)(sk-ant-|sk-|gh[pousr]_)[A-Za-z0-9_-]##/[REDACTED_TOKEN]}"
  redacted="${redacted//(#bi)bearer[[:space:]]##[A-Za-z0-9._~+\/=-]##/[REDACTED_BEARER]}"
  redacted="${redacted//(#bi)(api[_-]#key|access[_-]#token|token|authorization)[[:space:]]#[:=][[:space:]]#[^[:space:],;\}\]]##/[REDACTED_FIELD]}"
  (( ${#redacted} <= _AI_LOG_MAX_LINE_CHARS )) \
    || redacted="${redacted[1,_AI_LOG_MAX_LINE_CHARS]}…[truncated]"
  REPLY="$redacted"
}

_ai_log_print_excerpt() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || return 1
  local log_file="$1" expected="$2"
  _ai_log_matches "$log_file" "$expected" || {
    _ai_error "Selected log changed before reading: $log_file"
    return 1
  }
  local line="" timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="$(command -v gtimeout)"
  else
    return 1
  fi
  local -A log_state=()
  zstat -LH log_state -- "$log_file" 2>/dev/null || return 1
  local -a pipeline_status=()
  if (( log_state[size] > _AI_LOG_READ_BYTES )); then
    # The byte window may begin inside a sensitive line. Discard that first
    # partial record rather than trying to redact a value without its key.
    command "$timeout_bin" --foreground --kill-after=1s 5s \
      tail -c "$_AI_LOG_READ_BYTES" -- "$log_file" 2>/dev/null \
      | command tail -n +2 \
      | command tail -n "$_AI_LOG_LINES" \
      | while IFS= read -r line || [[ -n "$line" ]]; do
          _ai_log_redact "$line"
          print -u2 -r -- "${(V)REPLY}"
        done
    pipeline_status=("${pipestatus[@]}")
    (( pipeline_status[1] == 0 && pipeline_status[2] == 0 \
      && pipeline_status[3] == 0 && pipeline_status[4] == 0 ))
  else
    command "$timeout_bin" --foreground --kill-after=1s 5s \
      tail -c "$_AI_LOG_READ_BYTES" -- "$log_file" 2>/dev/null \
      | command tail -n "$_AI_LOG_LINES" \
      | while IFS= read -r line || [[ -n "$line" ]]; do
          _ai_log_redact "$line"
          print -u2 -r -- "${(V)REPLY}"
        done
    pipeline_status=("${pipestatus[@]}")
    (( pipeline_status[1] == 0 && pipeline_status[2] == 0 \
      && pipeline_status[3] == 0 ))
  fi
}

_ai_log_show() {
  local label="$1" root="$2" kind="$3"
  print -u2 -r -- "── $label ──"
  _ai_log_latest "$root" "$kind"
  local latest_rc=$?
  if (( latest_rc == 0 )); then
    local latest="${reply[1]}" fingerprint="${reply[2]}"
    _ai_info "Latest log: $latest"
    _ai_dim "Last $_AI_LOG_LINES lines:"
    _ai_log_print_excerpt "$latest" "$fingerprint" || {
      _ai_error "Could not read the selected log."
      return 1
    }
  elif (( latest_rc == 1 )); then
    _ai_info "No bounded, eligible log file found under $root."
  else
    _ai_error "Could not complete the bounded log inventory under $root."
    return 1
  fi
  print -u2 -r -- ""
}

ai-log-tail() {
  emulate -L zsh
  _AI_VERBOSE=0
  _ai_log_parse "$@"
  local parse_rc=$?
  (( parse_rc == 64 )) && return 0
  (( parse_rc == 0 )) || return $parse_rc

  _ai_header "AI CLI Recent Logs"
  local -i failures=0
  _ai_log_show "Claude Code" "${HOME:A}/.claude/projects" claude \
    || (( failures += 1 ))
  _ai_log_show "Codex CLI" "${HOME:A}/.codex/log" direct-log \
    || (( failures += 1 ))
  _ai_log_show "Antigravity CLI" \
    "${HOME:A}/.gemini/antigravity-cli/log" nested-log \
    || (( failures += 1 ))
  _ai_log_show "OpenCode" "$(_ai_opencode_data_dir)/logs" direct-log \
    || (( failures += 1 ))
  _ai_log_show "GitHub Copilot CLI" "${HOME:A}/.copilot" nested-log \
    || (( failures += 1 ))
  _ai_log_show "Cursor Agent" "${HOME:A}/.cursor/projects" cursor \
    || (( failures += 1 ))
  (( failures == 0 ))
}

typeset -g _AI_LOG_SOURCED=1
