#!/usr/bin/env zsh
# =============================================================================
# AI Update: reviewed delegation to installed CLI self-updaters
# =============================================================================
#
# Loaded by ai-menu.zsh after ai-common.zsh.
# Safe to re-source; defines functions only.
#
# Each operation resolves and fingerprints one installed external executable,
# previews the exact argv, requires authorization, and revalidates the executable
# immediately before invoking its documented self-updater. Missing tools are
# never installed. The upstream updater remains a remote-code trust boundary.
#

if [[ -n "${_AI_UPDATE_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -g _AI_UPDATE_HELP=0
typeset -g _AI_UPDATE_LABEL=""
typeset -g _AI_UPDATE_CLI=""
typeset -ga _AI_UPDATE_ARGS=()
typeset -g _AI_UPDATE_BINARY=""
typeset -g _AI_UPDATE_CANONICAL=""
typeset -g _AI_UPDATE_FINGERPRINT=""
typeset -g _AI_UPDATE_PATH_PREFIX=""
typeset -g _AI_UPDATE_REASON=""
typeset -g _AI_UPDATE_FAILURE_KIND=""
typeset -g _AI_UPDATE_CAPTURE_REASON=""
typeset -gi _AI_UPDATE_SKIP_HOMEBREW=0
typeset -gi _AI_UPDATE_RESULT_TSV=0
typeset -gi _AI_UPDATE_MAX_BINARY_BYTES=536870912
typeset -gri _AI_UPDATE_CAPTURE_MAX_BYTES=262144
typeset -gr _AI_UPDATE_RESULT_SCHEMA="ai-update-result-v1"

_ai_update_usage() {
  local command_name="$1"
  print -u2 -r -- \
    "Usage: $command_name [--dry-run] [--yes] [--skip-homebrew-managed] [--result-tsv]"
  print -u2 -r -- ""
  print -u2 -r -- \
    "Update installed assistants through their reviewed official self-updaters."
  print -u2 -r -- "  --dry-run       Preview exact installed targets without updating"
  print -u2 -r -- "  --yes, -y       Authorize the reviewed plan non-interactively"
  print -u2 -r -- \
    "  --skip-homebrew-managed  Leave Homebrew-owned assistants to Homebrew"
  print -u2 -r -- \
    "  --result-tsv    Emit bounded machine-readable per-target results on stdout"
  print -u2 -r -- "  --help, -h      Show this help"
}

_ai_update_parse_flags() {
  local command_name="$1"
  shift
  _AI_DRY_RUN=0
  _AI_YES=0
  _AI_UPDATE_HELP=0
  _AI_UPDATE_SKIP_HOMEBREW=0
  _AI_UPDATE_RESULT_TSV=0
  while (( $# )); do
    case "$1" in
      --dry-run) _AI_DRY_RUN=1 ;;
      --yes|-y) _AI_YES=1 ;;
      --skip-homebrew-managed) _AI_UPDATE_SKIP_HOMEBREW=1 ;;
      --result-tsv) _AI_UPDATE_RESULT_TSV=1 ;;
      --help|-h) _AI_UPDATE_HELP=1 ;;
      --)
        shift
        (( $# == 0 )) || {
          _ai_error "Unexpected argument: $1"
          return 2
        }
        break
        ;;
      -*)
        _ai_error "Unknown option: $1"
        return 2
        ;;
      *)
        _ai_error "Unexpected argument: $1"
        return 2
        ;;
    esac
    shift
  done
  (( _AI_UPDATE_HELP )) && _ai_update_usage "$command_name"
  return 0
}

_ai_update_metadata() {
  _AI_UPDATE_LABEL=""
  _AI_UPDATE_CLI=""
  _AI_UPDATE_ARGS=()
  case "${1:-}" in
    claude)
      _AI_UPDATE_LABEL="Claude Code"
      _AI_UPDATE_CLI="claude"
      _AI_UPDATE_ARGS=(update)
      ;;
    codex)
      _AI_UPDATE_LABEL="Codex CLI"
      _AI_UPDATE_CLI="codex"
      _AI_UPDATE_ARGS=(update)
      ;;
    antigravity)
      _AI_UPDATE_LABEL="Antigravity CLI"
      _AI_UPDATE_CLI="agy"
      _AI_UPDATE_ARGS=(update)
      ;;
    opencode)
      _AI_UPDATE_LABEL="OpenCode"
      _AI_UPDATE_CLI="opencode"
      _AI_UPDATE_ARGS=(upgrade)
      ;;
    cursor)
      _AI_UPDATE_LABEL="Cursor Agent"
      _AI_UPDATE_CLI="cursor-agent"
      _AI_UPDATE_ARGS=(update)
      ;;
    copilot)
      _AI_UPDATE_LABEL="GitHub Copilot CLI"
      _AI_UPDATE_CLI="copilot"
      _AI_UPDATE_ARGS=(update)
      ;;
    amp)
      _AI_UPDATE_LABEL="Amp CLI"
      _AI_UPDATE_CLI="amp"
      _AI_UPDATE_ARGS=(update)
      ;;
    hermes)
      _AI_UPDATE_LABEL="Hermes Agent"
      _AI_UPDATE_CLI="hermes"
      _AI_UPDATE_ARGS=(update --backup --yes)
      ;;
    *)
      _AI_UPDATE_REASON="Unknown AI update target."
      return 2
      ;;
  esac
}

_ai_update_capture_binary() {
  emulate -L zsh
  zmodload zsh/stat 2>/dev/null || {
    _AI_UPDATE_REASON="zsh/stat is required to validate the updater."
    return 2
  }
  local cli="${1:-}" launch_path="" canonical_path="" checksum=""
  local path_prefix="" node_path="" node_canonical="" node_checksum=""
  local node_fingerprint=""
  local -a checksum_fields=() node_checksum_fields=()
  local -A launch_state=() target_state=()
  local -A launch_after=() target_after=()
  local -A node_state=() node_after=()
  local -i launch_type=0 target_type=0
  _AI_UPDATE_BINARY=""
  _AI_UPDATE_CANONICAL=""
  _AI_UPDATE_FINGERPRINT=""
  _AI_UPDATE_PATH_PREFIX=""
  _AI_UPDATE_REASON=""

  if _ai_resolve_cli "$cli"; then
    launch_path="$REPLY"
    path_prefix="$_AI_RESOLVED_PATH_PREFIX"
    node_path="$_AI_RESOLVED_NODE"
  elif command -v -- "$cli" >/dev/null 2>&1; then
    _AI_UPDATE_REASON="A shell wrapper exists, but no external executable is resolvable."
    return 2
  else
    _AI_UPDATE_REASON="Not installed."
    return 1
  fi

  canonical_path="${launch_path:A}"
  [[ "$canonical_path" == /* && "$canonical_path" != *'|'* \
    && "$canonical_path" != *[[:cntrl:]]* \
    && -f "$canonical_path" && ! -L "$canonical_path" \
    && -x "$canonical_path" ]] || {
    _AI_UPDATE_REASON="The resolved executable target is unsafe."
    return 2
  }
  zstat -LH launch_state -- "$launch_path" 2>/dev/null \
    && zstat -H target_state -- "$canonical_path" 2>/dev/null || {
    _AI_UPDATE_REASON="The executable identity could not be captured."
    return 2
  }
  launch_type=$(( launch_state[mode] & 8#170000 ))
  target_type=$(( target_state[mode] & 8#170000 ))
  (( (launch_type == 8#100000 || launch_type == 8#120000) \
    && target_type == 8#100000 \
    && (launch_state[uid] == EUID || launch_state[uid] == 0) \
    && (target_state[uid] == EUID || target_state[uid] == 0) \
    && (target_state[mode] & 8#022) == 0 \
    && target_state[size] >= 0 \
    && target_state[size] <= _AI_UPDATE_MAX_BINARY_BYTES )) || {
    _AI_UPDATE_REASON="The executable is not an owner/root-controlled regular file."
    return 2
  }

  checksum=$(command cksum < "$canonical_path" 2>/dev/null) || {
    _AI_UPDATE_REASON="The executable checksum could not be captured."
    return 2
  }
  checksum_fields=(${=checksum})
  (( ${#checksum_fields[@]} == 2 )) \
    && [[ "$checksum_fields[1]" == <-> && "$checksum_fields[2]" == <-> ]] || {
    _AI_UPDATE_REASON="The executable checksum is malformed."
    return 2
  }
  zstat -LH launch_after -- "$launch_path" 2>/dev/null \
    && zstat -H target_after -- "$canonical_path" 2>/dev/null \
    && [[ "${launch_state[device]}:${launch_state[inode]}:"\
"${launch_state[mode]}:${launch_state[uid]}:${launch_state[nlink]}:"\
"${launch_state[size]}:${launch_state[mtime]}:${launch_state[ctime]}" \
      == "${launch_after[device]}:${launch_after[inode]}:"\
"${launch_after[mode]}:${launch_after[uid]}:${launch_after[nlink]}:"\
"${launch_after[size]}:${launch_after[mtime]}:${launch_after[ctime]}" \
      && "${target_state[device]}:${target_state[inode]}:"\
"${target_state[mode]}:${target_state[uid]}:${target_state[nlink]}:"\
"${target_state[size]}:${target_state[mtime]}:${target_state[ctime]}" \
      == "${target_after[device]}:${target_after[inode]}:"\
"${target_after[mode]}:${target_after[uid]}:${target_after[nlink]}:"\
"${target_after[size]}:${target_after[mtime]}:${target_after[ctime]}" ]] || {
    _AI_UPDATE_REASON="The executable changed while it was fingerprinted."
    return 2
  }

  if [[ -n "$node_path" ]]; then
    node_canonical="${node_path:A}"
    [[ "$path_prefix" == "${node_path:h}" \
      && "$node_path" == "$node_canonical" \
      && "$node_canonical" == /* \
      && -f "$node_canonical" && ! -L "$node_canonical" \
      && -x "$node_canonical" ]] \
      && zstat -H node_state -- "$node_canonical" 2>/dev/null \
      && (( node_state[uid] == EUID \
        && (node_state[mode] & 8#170000) == 8#100000 \
        && (node_state[mode] & 8#022) == 0 \
        && node_state[size] > 0 \
        && node_state[size] <= _AI_UPDATE_MAX_BINARY_BYTES )) || {
      _AI_UPDATE_REASON="The NVM Node interpreter is unsafe."
      return 2
    }
    node_checksum=$(command cksum < "$node_canonical" 2>/dev/null) || {
      _AI_UPDATE_REASON="The NVM Node interpreter checksum failed."
      return 2
    }
    node_checksum_fields=(${=node_checksum})
    (( ${#node_checksum_fields[@]} == 2 )) \
      && [[ "$node_checksum_fields[1]" == <-> \
        && "$node_checksum_fields[2]" == <-> ]] || {
      _AI_UPDATE_REASON="The NVM Node interpreter checksum is malformed."
      return 2
    }
    zstat -H node_after -- "$node_canonical" 2>/dev/null \
      && [[ "${node_state[device]}:${node_state[inode]}:"\
"${node_state[mode]}:${node_state[uid]}:${node_state[nlink]}:"\
"${node_state[size]}:${node_state[mtime]}:${node_state[ctime]}" \
        == "${node_after[device]}:${node_after[inode]}:"\
"${node_after[mode]}:${node_after[uid]}:${node_after[nlink]}:"\
"${node_after[size]}:${node_after[mtime]}:${node_after[ctime]}" ]] || {
      _AI_UPDATE_REASON="The NVM Node interpreter changed while fingerprinting."
      return 2
    }
    node_fingerprint=":${node_state[device]}:${node_state[inode]}:"\
"${node_state[mode]}:${node_state[uid]}:${node_state[nlink]}:"\
"${node_state[size]}:${node_state[mtime]}:${node_state[ctime]}:"\
"${node_checksum_fields[1]}:${node_checksum_fields[2]}:${node_canonical}"
  fi

  _AI_UPDATE_BINARY="$launch_path"
  _AI_UPDATE_CANONICAL="$canonical_path"
  _AI_UPDATE_PATH_PREFIX="$path_prefix"
  _AI_UPDATE_FINGERPRINT="${launch_state[device]}:${launch_state[inode]}:"\
"${launch_state[mode]}:${launch_state[uid]}:${launch_state[nlink]}:"\
"${launch_state[size]}:${launch_state[mtime]}:${launch_state[ctime]}:"\
"${target_state[device]}:${target_state[inode]}:${target_state[mode]}:"\
"${target_state[uid]}:${target_state[nlink]}:${target_state[size]}:"\
"${target_state[mtime]}:${target_state[ctime]}:${checksum_fields[1]}:"\
"${checksum_fields[2]}:${canonical_path}${node_fingerprint}"
}

_ai_update_homebrew_managed() {
  local canonical_path="${1:-}"
  [[ "$canonical_path" == */Cellar/* || "$canonical_path" == */Caskroom/* ]]
}

_ai_update_action_label() {
  local binary="$1"
  shift
  local action="${(q)binary}" argument=""
  for argument in "$@"; do
    action+=" ${(q)argument}"
  done
  print -r -- "$action"
}

_ai_update_classify_output() {
  local normalized="${1:l}"
  REPLY="updater"
  if [[ "$normalized" == *unauthenticated* \
    || "$normalized" == *unauthorized* \
    || "$normalized" == *"not authenticated"* \
    || "$normalized" == *"authentication required"* \
    || "$normalized" == *"authentication failed"* \
    || "$normalized" == *"login required"* \
    || "$normalized" == *"please log in"* \
    || "$normalized" == *"please login"* \
    || "$normalized" == *"not logged in"* \
    || "$normalized" == *"sign in required"* \
    || "$normalized" == *"sign-in required"* ]]; then
    REPLY="authentication"
  elif [[ "$normalized" == *failed_precondition* \
    || "$normalized" == *"failed precondition"* \
    || "$normalized" == *"precondition failed"* \
    || "$normalized" == *"unmet precondition"* ]]; then
    REPLY="precondition"
  fi
}

# OpenCode catches installation errors, prints its spinner failure, and can
# return status 0. Match that complete vendor marker, including ANSI styling,
# without treating arbitrary diagnostics from other assistants as a failure.
_ai_update_opencode_reported_failure() {
  emulate -L zsh
  setopt EXTENDED_GLOB
  local normalized="${1:l}"
  local csi_pattern=$'\e''\[[0-?]#[ -/]#[@-~]'
  normalized="${normalized//$~csi_pattern/}"
  normalized="${normalized//$'\r'/$'\n'}"
  local output_line
  for output_line in "${(@f)normalized}"; do
    [[ "$output_line" =~ '^[^[:alnum:]]*upgrade failed[[:space:]]*$' ]] \
      && return 0
  done
  return 1
}

# Run one already-reviewed updater without a mutation timeout. The pipeline
# drains all vendor output while retaining only its final bounded bytes in an
# invocation-owned private file. No captured vendor text is replayed.
_ai_update_run_captured() {
  emulate -L zsh
  setopt LOCAL_OPTIONS PIPE_FAIL
  zmodload zsh/stat 2>/dev/null || {
    _AI_UPDATE_FAILURE_KIND="adapter"
    _AI_UPDATE_CAPTURE_REASON="zsh/stat is required for private updater output."
    return 125
  }
  local binary="${1:-}" path_prefix="${2:-}" target_id="${3:-}"
  shift 3 2>/dev/null || return 125
  (( $# > 0 )) || return 125
  _AI_UPDATE_FAILURE_KIND=""
  _AI_UPDATE_CAPTURE_REASON=""

  local tail_bin=""
  if _ai_resolve_cli tail; then
    tail_bin="$REPLY"
  else
    _AI_UPDATE_FAILURE_KIND="adapter"
    _AI_UPDATE_CAPTURE_REASON="tail is required for bounded updater output."
    return 125
  fi

  local temp_parent="${TMPDIR:-/tmp}"
  [[ "$temp_parent" == /* ]] || {
    _AI_UPDATE_FAILURE_KIND="adapter"
    _AI_UPDATE_CAPTURE_REASON="The updater output root is not absolute."
    return 125
  }
  temp_parent="${temp_parent:A}"
  _ai_temp_parent_check "$temp_parent" || {
    _AI_UPDATE_FAILURE_KIND="adapter"
    _AI_UPDATE_CAPTURE_REASON="The updater output root is unsafe."
    return 125
  }

  local capture_dir=""
  capture_dir=$(umask 077; command mktemp -d \
    "$temp_parent/zdx-ai-update-output.XXXXXX" 2>/dev/null) || {
    _AI_UPDATE_FAILURE_KIND="adapter"
    _AI_UPDATE_CAPTURE_REASON="A private updater output directory could not be created."
    return 125
  }
  local capture_file="$capture_dir/output"
  local captured_output=""
  local -A dir_before=() dir_after=()
  local -A out_before=() out_after=() out_read=() out_cleanup=()
  local -a pipeline_status=()
  local -i updater_rc=125 sink_rc=125 operation_rc=125
  local -i dir_valid=0 file_valid=0 cleanup_rc=0

  {
    if [[ "$capture_dir" == "${capture_dir:A}" \
      && "${capture_dir:h}" == "$temp_parent" \
      && "${capture_dir:t}" == zdx-ai-update-output.* \
      && -d "$capture_dir" && ! -L "$capture_dir" \
      && -O "$capture_dir" ]] \
      && zstat -LH dir_before -- "$capture_dir" 2>/dev/null \
      && (( dir_before[uid] == EUID \
        && dir_before[nlink] == 2 \
        && (dir_before[mode] & 8#170000) == 8#040000 \
        && (dir_before[mode] & 8#077) == 0 )); then
      dir_valid=1
    else
      _AI_UPDATE_CAPTURE_REASON="The private updater output directory failed validation."
    fi

    if (( dir_valid )); then
      (umask 077; : > "$capture_file") 2>/dev/null \
        && zstat -LH out_before -- "$capture_file" 2>/dev/null \
        && (( out_before[uid] == EUID \
          && out_before[nlink] == 1 \
          && (out_before[mode] & 8#170000) == 8#100000 \
          && (out_before[mode] & 8#077) == 0 )) \
        && file_valid=1
      (( file_valid )) \
        || _AI_UPDATE_CAPTURE_REASON="The private updater output file failed validation."
    fi

    if (( file_valid )); then
      if [[ -n "$path_prefix" ]]; then
        PATH="$path_prefix:$PATH" \
          command "$binary" "$@" </dev/null 2>&1 \
          | command "$tail_bin" -c "$_AI_UPDATE_CAPTURE_MAX_BYTES" \
            > "$capture_file"
        pipeline_status=("${pipestatus[@]}")
      else
        command "$binary" "$@" </dev/null 2>&1 \
          | command "$tail_bin" -c "$_AI_UPDATE_CAPTURE_MAX_BYTES" \
            > "$capture_file"
        pipeline_status=("${pipestatus[@]}")
      fi
      updater_rc="${pipeline_status[1]:-125}"
      sink_rc="${pipeline_status[2]:-125}"

      if (( sink_rc == 0 )) \
        && [[ -f "$capture_file" && ! -L "$capture_file" ]] \
        && zstat -LH out_after -- "$capture_file" 2>/dev/null \
        && [[ "${out_before[device]}:${out_before[inode]}:"\
"${out_before[uid]}:${out_before[nlink]}" \
          == "${out_after[device]}:${out_after[inode]}:"\
"${out_after[uid]}:${out_after[nlink]}" ]] \
        && (( (out_after[mode] & 8#170000) == 8#100000 \
          && (out_after[mode] & 8#077) == 0 \
          && out_after[size] >= 0 \
          && out_after[size] <= _AI_UPDATE_CAPTURE_MAX_BYTES )); then
        captured_output=$(<"$capture_file")
        if zstat -LH out_read -- "$capture_file" 2>/dev/null \
          && [[ "${out_after[device]}:${out_after[inode]}:"\
"${out_after[uid]}:${out_after[nlink]}:${out_after[size]}:"\
"${out_after[mtime]}:${out_after[ctime]}" \
            == "${out_read[device]}:${out_read[inode]}:"\
"${out_read[uid]}:${out_read[nlink]}:${out_read[size]}:"\
"${out_read[mtime]}:${out_read[ctime]}" ]]; then
          operation_rc=$updater_rc
          if (( updater_rc == 0 )) && [[ "$target_id" == opencode ]] \
            && _ai_update_opencode_reported_failure "$captured_output"; then
            operation_rc=1
          fi
          if (( operation_rc != 0 )); then
            _ai_update_classify_output "$captured_output"
            _AI_UPDATE_FAILURE_KIND="$REPLY"
            if (( updater_rc == 0 )) \
              && [[ "$_AI_UPDATE_FAILURE_KIND" == updater ]]; then
              _AI_UPDATE_FAILURE_KIND="reported-failure"
            fi
          fi
        else
          _AI_UPDATE_CAPTURE_REASON="Updater output changed during inspection."
        fi
      else
        _AI_UPDATE_CAPTURE_REASON="Updater output could not be captured safely."
      fi
    fi
  } always {
    if (( file_valid )) \
      && [[ -f "$capture_file" && ! -L "$capture_file" ]] \
      && zstat -LH out_cleanup -- "$capture_file" 2>/dev/null \
      && [[ "${out_before[device]}:${out_before[inode]}:"\
"${out_before[uid]}:${out_before[nlink]}" \
        == "${out_cleanup[device]}:${out_cleanup[inode]}:"\
"${out_cleanup[uid]}:${out_cleanup[nlink]}" ]]; then
      command rm -f -- "$capture_file" 2>/dev/null || cleanup_rc=1
    elif (( file_valid )); then
      cleanup_rc=1
    fi
    if (( dir_valid )) \
      && [[ -d "$capture_dir" && ! -L "$capture_dir" ]] \
      && zstat -LH dir_after -- "$capture_dir" 2>/dev/null \
      && [[ "${dir_before[device]}:${dir_before[inode]}:"\
"${dir_before[uid]}" == "${dir_after[device]}:${dir_after[inode]}:"\
"${dir_after[uid]}" ]]; then
      command rmdir -- "$capture_dir" 2>/dev/null || cleanup_rc=1
    else
      cleanup_rc=1
    fi
    if (( cleanup_rc != 0 )); then
      operation_rc=125
      _AI_UPDATE_CAPTURE_REASON="Private updater output cleanup failed."
    fi
  }

  if (( operation_rc == 125 )); then
    _AI_UPDATE_FAILURE_KIND="adapter"
    [[ -n "$_AI_UPDATE_CAPTURE_REASON" ]] \
      || _AI_UPDATE_CAPTURE_REASON="Updater output capture failed."
  fi
  # Interruptions can terminate both pipeline children. Preserve that request
  # after cleanup even when the output sink could not finish safely.
  if (( updater_rc == 130 || updater_rc == 143 )); then
    operation_rc=$updater_rc
  elif (( sink_rc == 130 || sink_rc == 143 )); then
    operation_rc=$sink_rc
  fi
  return $operation_rc
}

_ai_update_report_failure() {
  local label="$1" id="$2"
  local -i update_rc="$3"
  case "$_AI_UPDATE_FAILURE_KIND" in
    authentication)
      _ai_error \
        "$label updater was blocked: vendor authentication is required."
      if [[ "$id" == cursor ]]; then
        _ai_info \
          "Run 'cursor-agent status' to inspect authentication or 'cursor-agent login' explicitly, then retry ai-update-cursor."
      else
        _ai_info \
          "Authenticate in the vendor CLI explicitly, then retry ai-update-$id."
      fi
      ;;
    precondition)
      _ai_error "$label updater reported an unmet vendor precondition."
      _ai_info \
        "Resolve the vendor prerequisite explicitly, then retry ai-update-$id."
      ;;
    reported-failure)
      _ai_error \
        "$label reported an upgrade failure despite returning status 0."
      ;;
    adapter)
      _ai_error "$label updater result could not be captured safely."
      _ai_dim "$_AI_UPDATE_CAPTURE_REASON"
      ;;
    *)
      _ai_error "$label updater failed with status $update_rc."
      ;;
  esac
  [[ "$_AI_UPDATE_FAILURE_KIND" == adapter ]] \
    || _ai_dim \
      "Vendor output was withheld because it may contain sensitive data."
}

_ai_update_result_message() {
  local reason="${1:-}" result_rc="${2:-0}"
  case "$reason" in
    metadata-invalid)                  REPLY="updater metadata is invalid" ;;
    executable-validation-failed)      REPLY="executable validation failed" ;;
    version-probe-failed)              REPLY="version probe failed" ;;
    not-installed)                     REPLY="skipped (not installed)" ;;
    homebrew-managed)                  REPLY="skipped (Homebrew-managed)" ;;
    eligible)                          REPLY="planned" ;;
    cancelled)                         REPLY="not run (cancelled)" ;;
    interrupted)                       REPLY="not run (update interrupted)" ;;
    authorization-not-granted)         REPLY="not run (authorization not granted)" ;;
    executable-changed)                REPLY="executable changed after review" ;;
    updated-executable-unsafe)         REPLY="updated executable is unsafe" ;;
    post-update-version-probe-failed)  REPLY="post-update version probe failed" ;;
    version-changed|executable-content-changed)
      REPLY="updated"
      ;;
    unchanged)                         REPLY="already current" ;;
    authentication-required)           REPLY="authentication required" ;;
    vendor-precondition)               REPLY="vendor precondition not met" ;;
    result-capture-failed)             REPLY="result capture failed" ;;
    updater-failed)                    REPLY="updater failed (status $result_rc)" ;;
    *)                                 REPLY="unknown result" ;;
  esac
}

_ai_update_execute() {
  emulate -L zsh
  local title="$1"
  shift
  local -a requested_ids=("$@")
  local -a plan_ids=() plan_binaries=() plan_fingerprints=() plan_versions=()
  local -a plan_path_prefixes=()
  local -A result_labels=() result_outcomes=() result_reasons=() result_rcs=()
  local id="" label="" cli="" binary="" fingerprint="" version="" action=""
  local path_prefix=""
  local new_version="" post_fingerprint=""
  local -i state_rc=0 failures=0 skipped=0 updated=0 already_current=0
  local -i planned=0 not_run=0 publication_failed=0
  local -i authorization_rc=0 final_rc=0 cancelled=0

  _ai_header "$title"
  _ai_warn \
    "These vendor self-updaters may download and execute remote code."

  for id in "${requested_ids[@]}"; do
    result_labels[$id]="$id"
    result_outcomes[$id]="failed"
    result_reasons[$id]="metadata-invalid"
    result_rcs[$id]=2
    _ai_update_metadata "$id" || {
      _ai_error "$_AI_UPDATE_REASON"
      continue
    }
    label="$_AI_UPDATE_LABEL"
    cli="$_AI_UPDATE_CLI"
    result_labels[$id]="$label"
    _ai_update_capture_binary "$cli"
    state_rc=$?
    case "$state_rc" in
      0)
        binary="$_AI_UPDATE_BINARY"
        fingerprint="$_AI_UPDATE_FINGERPRINT"
        path_prefix="$_AI_UPDATE_PATH_PREFIX"
        if (( _AI_UPDATE_SKIP_HOMEBREW )) \
          && _ai_update_homebrew_managed "$_AI_UPDATE_CANONICAL"; then
          _ai_dim "$label: Homebrew-managed; left to the Homebrew update step."
          result_outcomes[$id]="skipped"
          result_reasons[$id]="homebrew-managed"
          result_rcs[$id]=0
          continue
        fi
        version=$(_ai_probe_cli "$cli" 2>/dev/null)
        state_rc=$?
        if (( state_rc != 0 )); then
          _ai_error \
            "$label: installed executable failed its bounded version probe."
          result_outcomes[$id]="failed"
          result_reasons[$id]="version-probe-failed"
          result_rcs[$id]="$state_rc"
          continue
        fi
        action=$(_ai_update_action_label \
          "$binary" "${_AI_UPDATE_ARGS[@]}")
        _ai_info "$label"
        _ai_label "Binary" "$binary"
        _ai_label "Current" "$version"
        _ai_label "Action" "$action"
        plan_ids+=("$id")
        plan_binaries+=("$binary")
        plan_fingerprints+=("$fingerprint")
        plan_versions+=("$version")
        plan_path_prefixes+=("$path_prefix")
        result_outcomes[$id]="planned"
        result_reasons[$id]="eligible"
        result_rcs[$id]=0
        ;;
      1)
        _ai_dim "$label: not installed; skipped."
        result_outcomes[$id]="skipped"
        result_reasons[$id]="not-installed"
        result_rcs[$id]=0
        ;;
      *)
        _ai_error "$label: $_AI_UPDATE_REASON"
        result_outcomes[$id]="failed"
        result_reasons[$id]="executable-validation-failed"
        result_rcs[$id]="$state_rc"
        ;;
    esac
  done

  if (( ${#plan_ids[@]} == 0 )); then
    _ai_info "No installed AI CLI is eligible for update."
  elif (( _AI_DRY_RUN )); then
    local cli_noun="AI CLI"
    local eligible_verb="is"
    if (( ${#plan_ids[@]} != 1 )); then
      cli_noun+="s"
      eligible_verb="are"
    fi
    _ai_info \
      "Dry run: ${#plan_ids[@]} installed $cli_noun $eligible_verb eligible for reviewed updater execution."
  else
    local updater_noun="self-updater"
    (( ${#plan_ids[@]} == 1 )) || updater_noun+="s"
    _ai_authorize \
      "Run ${#plan_ids[@]} reviewed AI CLI $updater_noun?"
    authorization_rc=$?
    if (( authorization_rc == 130 )); then
      cancelled=1
      for id in "${plan_ids[@]}"; do
        result_outcomes[$id]="not-run"
        result_reasons[$id]="cancelled"
        result_rcs[$id]=0
      done
    elif (( authorization_rc != 0 )); then
      final_rc=$authorization_rc
      for id in "${plan_ids[@]}"; do
        result_outcomes[$id]="not-run"
        result_reasons[$id]="authorization-not-granted"
        result_rcs[$id]="$authorization_rc"
      done
    else
      local -i index=0 update_rc=0
      for (( index = 1; index <= ${#plan_ids[@]}; index++ )); do
        id="${plan_ids[index]}"
        binary="${plan_binaries[index]}"
        fingerprint="${plan_fingerprints[index]}"
        version="${plan_versions[index]}"
        path_prefix="${plan_path_prefixes[index]}"
        _ai_update_metadata "$id" || {
          _ai_error "The reviewed updater metadata is no longer valid."
          result_outcomes[$id]="failed"
          result_reasons[$id]="metadata-invalid"
          result_rcs[$id]=2
          continue
        }
        label="$_AI_UPDATE_LABEL"
        cli="$_AI_UPDATE_CLI"
        _ai_update_capture_binary "$cli"
        state_rc=$?
        if (( state_rc != 0 )) \
          || [[ "$_AI_UPDATE_BINARY" != "$binary" \
            || "$_AI_UPDATE_FINGERPRINT" != "$fingerprint" \
            || "$_AI_UPDATE_PATH_PREFIX" != "$path_prefix" ]]; then
          _ai_error \
            "$label: executable changed after review; refusing the update."
          result_outcomes[$id]="failed"
          result_reasons[$id]="executable-changed"
          result_rcs[$id]=1
          continue
        fi

        _ai_info "Updating $label to the latest version..."
        _ai_update_run_captured \
          "$binary" "$path_prefix" "$id" "${_AI_UPDATE_ARGS[@]}"
        update_rc=$?
        if (( update_rc == 0 )); then
          _ai_update_capture_binary "$cli"
          state_rc=$?
          if (( state_rc != 0 )); then
            _ai_error \
              "$label updater completed, but the resulting executable is unsafe."
            result_outcomes[$id]="failed"
            result_reasons[$id]="updated-executable-unsafe"
            result_rcs[$id]="$state_rc"
            continue
          fi
          new_version=$(_ai_probe_cli "$cli" 2>/dev/null)
          state_rc=$?
          if (( state_rc != 0 )); then
            _ai_error \
              "$label updater completed, but the resulting version probe failed."
            result_outcomes[$id]="failed"
            result_reasons[$id]="post-update-version-probe-failed"
            result_rcs[$id]="$state_rc"
            continue
          fi
          post_fingerprint="$_AI_UPDATE_FINGERPRINT"
          if [[ "$new_version" == "$version" \
            && "$post_fingerprint" == "$fingerprint" ]]; then
            _ai_success \
              "$label is already at the latest reported version ($version)."
            result_outcomes[$id]="already-current"
            result_reasons[$id]="unchanged"
            result_rcs[$id]=0
          elif [[ "$new_version" == "$version" ]]; then
            _ai_success \
              "$label executable changed while reporting the same version ($version)."
            result_outcomes[$id]="updated"
            result_reasons[$id]="executable-content-changed"
            result_rcs[$id]=0
          else
            _ai_success "$label updated: $version -> $new_version"
            result_outcomes[$id]="updated"
            result_reasons[$id]="version-changed"
            result_rcs[$id]=0
          fi
        else
          _ai_update_report_failure "$label" "$id" "$update_rc"
          result_outcomes[$id]="failed"
          result_rcs[$id]="$update_rc"
          case "$_AI_UPDATE_FAILURE_KIND" in
            authentication) result_reasons[$id]="authentication-required" ;;
            precondition)   result_reasons[$id]="vendor-precondition" ;;
            adapter)        result_reasons[$id]="result-capture-failed" ;;
            *)              result_reasons[$id]="updater-failed" ;;
          esac
          if (( update_rc == 130 || update_rc == 143 )); then
            final_rc=$update_rc
            _ai_warn "AI updates interrupted; remaining targets will not run."
            local pending_id=""
            local -i pending_index=0
            for (( pending_index = index + 1; pending_index <= ${#plan_ids[@]}; pending_index++ )); do
              pending_id="${plan_ids[pending_index]}"
              result_outcomes[$pending_id]="not-run"
              result_reasons[$pending_id]="interrupted"
              result_rcs[$pending_id]="$update_rc"
            done
            break
          fi
        fi
      done
    fi
  fi

  failures=0
  skipped=0
  updated=0
  already_current=0
  for id in "${requested_ids[@]}"; do
    case "${result_outcomes[$id]}" in
      updated)         (( updated += 1 )) ;;
      already-current) (( already_current += 1 )) ;;
      failed)          (( failures += 1 )) ;;
      skipped)         (( skipped += 1 )) ;;
      planned)         (( planned += 1 )) ;;
      not-run)         (( not_run += 1 )) ;;
    esac
  done

  _ai_info "AI updater results:"
  local result_message="" outcome="" reason="" result_rc=""
  for id in "${requested_ids[@]}"; do
    label="${result_labels[$id]}"
    outcome="${result_outcomes[$id]}"
    reason="${result_reasons[$id]}"
    result_rc="${result_rcs[$id]}"
    _ai_update_result_message "$reason" "$result_rc"
    result_message="$REPLY"
    case "$outcome" in
      updated|already-current) _ai_success "$label — $result_message" ;;
      failed)                  _ai_error "$label — $result_message" ;;
      skipped)                 _ai_dim "$label — $result_message" ;;
      planned)                 _ai_info "$label — $result_message" ;;
      not-run)                 _ai_warn "$label — $result_message" ;;
    esac
    if (( _AI_UPDATE_RESULT_TSV )); then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_AI_UPDATE_RESULT_SCHEMA" "$id" "$label" \
        "$outcome" "$reason" "$result_rc" || publication_failed=1
    fi
  done

  if (( _AI_DRY_RUN )); then
    _ai_info \
      "Plan summary: $planned planned, $failures failed, $skipped skipped."
  elif (( not_run > 0 )); then
    _ai_info \
      "Update summary: $updated updated, $already_current already current, $failures failed, $skipped skipped, $not_run not run."
  else
    _ai_info \
      "Update summary: $updated updated, $already_current already current, $failures failed, $skipped skipped."
  fi
  if (( publication_failed )); then
    _ai_error "The requested AI result records could not be written."
    (( final_rc == 0 )) && final_rc=1
  fi
  if (( final_rc == 0 && failures > 0 )); then
    final_rc=1
  fi
  if (( final_rc == 1 && failures > 0 \
    && updated + already_current > 0 && ! cancelled )) \
    && typeset -f _zdx_timed_mark_partial &>/dev/null; then
    _zdx_timed_mark_partial || true
  fi
  return $final_rc
}

_ai_update_one() {
  emulate -L zsh
  local command_name="$1" target_id="$2"
  shift 2
  _ai_update_parse_flags "$command_name" "$@" || return $?
  (( _AI_UPDATE_HELP )) && return 0
  _ai_update_metadata "$target_id" || return 2
  _ai_update_execute "$_AI_UPDATE_LABEL Update" "$target_id"
}

ai-update-claude() {
  _ai_update_one ai-update-claude claude "$@"
}

ai-update-codex() {
  _ai_update_one ai-update-codex codex "$@"
}

ai-update-antigravity() {
  _ai_update_one ai-update-antigravity antigravity "$@"
}

ai-update-opencode() {
  _ai_update_one ai-update-opencode opencode "$@"
}

ai-update-cursor() {
  _ai_update_one ai-update-cursor cursor "$@"
}

ai-update-copilot() {
  _ai_update_one ai-update-copilot copilot "$@"
}

ai-update-amp() {
  _ai_update_one ai-update-amp amp "$@"
}

ai-update-hermes() {
  _ai_update_one ai-update-hermes hermes "$@"
}

ai-update() {
  emulate -L zsh
  _ai_update_parse_flags ai-update "$@" || return $?
  (( _AI_UPDATE_HELP )) && return 0
  _ai_update_execute "AI CLI Updates" \
    claude codex antigravity opencode cursor copilot amp hermes
}

typeset -g _AI_UPDATE_SOURCED=1
