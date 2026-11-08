#!/usr/bin/env zsh
# =============================================================================
# Ws Status: read-only status of every workspace repository
# =============================================================================
#
# Loaded by ws-menu.zsh after ws-common.zsh.
# Safe to re-source; defines functions only.
#
# Status comes from local refs only. The network is used only with --fetch,
# which is disclosed first and runs bounded `git fetch --prune` jobs.
#

if [[ -n "${_WS_STATUS_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

typeset -gi _WS_FETCH_TIMEOUT=60

_ws_status_usage() {
  print -u2 -r -- "Usage: ws-status [--fetch] [--json]"
  print -u2 -r -- "       ws-status --help"
  print -u2 -r -- ""
  print -u2 -r -- \
    "List every repository below WS_BASE_DIR with its workspace, branch,"
  print -u2 -r -- \
    "uncommitted changes, ahead/behind counts from local refs, stashes, and"
  print -u2 -r -- \
    "last commit. Repositories that need attention are listed first."
  print -u2 -r -- ""
  print -u2 -r -- \
    "  --fetch   First run git fetch --prune in each repository with a remote,"
  print -u2 -r -- \
    "            at most WS_FETCH_JOBS (default 4) at a time, 60s each."
  print -u2 -r -- \
    "            Requires native GNU timeout/gtimeout and mkfifo; no tool is installed."
  print -u2 -r -- \
    "  --json    Print one JSON document (schema zdx.ws-status.v1) on stdout."
  print -u2 -r -- ""
  print -u2 -r -- \
    "Without --fetch, no network is used and no repository is changed."
}

# reply: one repository's state from local refs only:
#   (state branch detached head upstream upstream-state ahead behind
#    changes stashes last-commit-epoch error)
# state is ok or error, detached is 0 or 1, upstream-state is none,
# tracking, or gone, and an unknown number is empty. Every probe runs without
# the repository-local Git variables, so an inherited GIT_DIR cannot make it
# describe another repository.
# Usage: _ws_status_probe <git> <repository-directory>
_ws_status_probe() {
  emulate -L zsh
  local git_path="$1" repository="$2"
  reply=(error "" 0 "" "" none "" "" "" "" "" "")
  local output="" line="" oid="" head="" upstream="" ahead="" behind=""
  local -i rc=0 changes=0 have_ab=0

  # --no-optional-locks keeps status from rewriting the index.
  output=$(_ws_git_command "$_WS_GIT_TIMEOUT" "$git_path" \
    --no-optional-locks -C "$repository" status --porcelain=v2 --branch \
    --untracked-files=normal </dev/null 2>/dev/null) || rc=$?
  if (( rc != 0 )); then
    if (( rc == 124 )); then
      reply[12]="git status timed out"
    else
      reply[12]="git status failed (status $rc)"
    fi
    return 1
  fi
  for line in "${(@f)output}"; do
    case "$line" in
      '# branch.oid '*) oid="${line#'# branch.oid '}" ;;
      '# branch.head '*) head="${line#'# branch.head '}" ;;
      '# branch.upstream '*) upstream="${line#'# branch.upstream '}" ;;
      '# branch.ab '*)
        [[ "${line#'# branch.ab '}" =~ '^[+]([0-9]+) [-]([0-9]+)$' ]] || {
          reply[12]="unexpected git status output"
          return 1
        }
        ahead="${match[1]}"
        behind="${match[2]}"
        have_ab=1
        ;;
      '#'*|'') ;;
      *) (( ++changes )) ;;
    esac
  done
  if [[ ! ( "$oid" =~ '^[0-9a-f]{40,64}$' || "$oid" == '(initial)' ) \
    || -z "$head" || "$head" == *[[:cntrl:]]* \
    || "$upstream" == *[[:cntrl:]]* ]]; then
    reply[12]="unexpected git status output"
    return 1
  fi

  local branch="$head" short_head="" upstream_state="none"
  local -i detached=0
  if [[ "$head" == '(detached)' ]]; then
    branch=""
    detached=1
  fi
  [[ "$oid" != '(initial)' ]] && short_head="${oid[1,7]}"
  if [[ -n "$upstream" ]]; then
    if (( have_ab )); then
      upstream_state="tracking"
    else
      upstream_state="gone"
    fi
  fi

  local epoch="" stash_count="0" probe_output=""
  if [[ "$oid" != '(initial)' ]]; then
    rc=0
    # log.showSignature would print verification lines before the time.
    probe_output=$(_ws_git_command "$_WS_GIT_TIMEOUT" "$git_path" \
      -C "$repository" -c log.showSignature=false log -1 --format=%ct \
      </dev/null 2>/dev/null) || rc=$?
    probe_output="${probe_output%%$'\n'*}"
    if (( rc == 0 )) && [[ "$probe_output" == <-> ]]; then
      epoch="$probe_output"
    fi
  fi
  # refs/stash is absent until the first stash; git reports that as a failure.
  rc=0
  probe_output=$(_ws_git_command "$_WS_GIT_TIMEOUT" "$git_path" \
    -C "$repository" rev-list --walk-reflogs --count refs/stash \
    </dev/null 2>/dev/null) || rc=$?
  probe_output="${probe_output%%$'\n'*}"
  if (( rc == 0 )) && [[ "$probe_output" == <-> ]]; then
    stash_count="$probe_output"
  elif (( rc == 124 )); then
    stash_count=""
  fi

  reply=(ok "$branch" "$detached" "$short_head" "$upstream" \
    "$upstream_state" "$ahead" "$behind" "$changes" "$stash_count" \
    "$epoch" "")
}

# REPLY: a compact age such as "5 minutes ago" or "3 months ago".
# Usage: _ws_status_age <seconds>
_ws_status_age() {
  local -i seconds="${1:-0}" value=0
  local unit=""
  (( seconds < 0 )) && seconds=0
  if (( seconds < 60 )); then
    REPLY="just now"
    return 0
  elif (( seconds < 3600 )); then
    value=$(( seconds / 60 )); unit=minute
  elif (( seconds < 86400 )); then
    value=$(( seconds / 3600 )); unit=hour
  elif (( seconds < 1209600 )); then
    value=$(( seconds / 86400 )); unit=day
  elif (( seconds < 5184000 )); then
    value=$(( seconds / 604800 )); unit=week
  elif (( seconds < 63072000 )); then
    value=$(( seconds / 2592000 )); unit=month
  else
    value=$(( seconds / 31536000 )); unit=year
  fi
  _ws_count_noun "$value" "$unit"
  REPLY+=" ago"
}

_ws_fetch_load_helpers() {
  emulate -L zsh
  local worker="${${(%):-%x}:A:h}/ws-fetch-worker.zsh"
  [[ -f "$worker" && -r "$worker" && ! -L "$worker" \
    && "$worker" == "${worker:A}" ]] || return 1
  builtin source "$worker" || return
  _ws_fetch_modules || return 1
  REPLY="$worker"
}

# Refuse readonly repository carriers without expanding values or trying unset.
_ws_fetch_env_clearable() {
  emulate -L zsh
  local carrier=""
  for carrier in "${_WS_GIT_LOCAL_ENV_VARS[@]}"; do
    [[ "-${(tP)carrier}-" != *-readonly-* ]] || return 1
  done
  return 0
}

# These executable paths are trusted installed tools, not arbitrary callbacks.
_ws_fetch_native_path() {
  emulate -L zsh
  local found="" canonical=""
  local -A state=()
  REPLY=""
  _ws_system_root_uid || return 1
  local -i system_root_uid=$REPLY
  REPLY=""
  found=$(whence -p -- "$1" 2>/dev/null) || return 1
  [[ "$found" == /* ]] || return 1
  canonical="${found:A}"
  [[ -f "$canonical" && -x "$canonical" && ! -L "$canonical" \
    && "${canonical:l}" != *.exe && "$canonical" != *[[:cntrl:]]* ]] || return 1
  if [[ "$canonical" == /mnt/[a-zA-Z]/* ]] && _ws_host_is_wsl; then return 1; fi
  _ws_validate_ancestor_chain "$canonical" 2>/dev/null || return 1
  zstat -LH state -- "$canonical" 2>/dev/null \
    && (( (state[mode] & 8#170000) == 8#100000 \
      && (state[uid] == system_root_uid || state[uid] == EUID) \
      && (state[mode] & 8#22) == 0 )) || return 1
  REPLY="$canonical"
}

_ws_fetch_pair() {
  emulate -L zsh
  local key="$1" object="" kind="" fd=""
  local REPLY=""
  _ws_fetch_object_id "$_wsf_dir" directory && [[ "$REPLY" == "$_wsf_dir_id" ]] || return 1
  local -a kinds=(control status)
  [[ "${_wsf_mode[$key]-}" == guard ]] && kinds+=(go)
  for kind in "${kinds[@]}"; do
    object="$_wsf_dir/$key.$kind"
    [[ ! -e "$object" && ! -L "$object" ]] || return 1
    (umask 077; command "${_wsf_tools[mkfifo]}" -m 600 -- "$object") 2>/dev/null || return 1
    _ws_fetch_object_id "$_wsf_dir" directory && [[ "$REPLY" == "$_wsf_dir_id" ]] || return 1
    _ws_fetch_object_id "$object" fifo || return 1
    _wsf_objects[$object]="$REPLY"
  done
  object="$_wsf_dir/$key.control"
  sysopen -r -o nonblock,nofollow,cloexec -u fd -- "$object" 2>/dev/null || return 1
  _wsf_cr[$key]="$fd"
  if ! _ws_fetch_fd_matches "$fd" "${_wsf_objects[$object]}"; then
    # This acquisition is still held here. Close it even if the opened object
    # differs from the expected path; do not write or unlink that replacement.
    exec {fd}<&-
    _wsf_cr[$key]=-1
    return 1
  fi
  _wsf_read_ids[$fd]="${_wsf_objects[$object]}"
  object="$_wsf_dir/$key.status"
  sysopen -r -o nonblock,nofollow,cloexec -u fd -- "$object" 2>/dev/null || return 1
  _wsf_sr[$key]="$fd"
  if ! _ws_fetch_fd_matches "$fd" "${_wsf_objects[$object]}"; then
    exec {fd}<&-
    _wsf_sr[$key]=-1
    return 1
  fi
  _wsf_read_ids[$fd]="${_wsf_objects[$object]}"
  object="$_wsf_dir/$key.control"
  sysopen -w -o nonblock,nofollow,cloexec -u fd -- "$object" 2>/dev/null || return 1
  _wsf_cw[$key]="$fd"
  if ! _ws_fetch_fd_matches "$fd" "${_wsf_objects[$object]}"; then
    exec {fd}>&-
    _wsf_cw[$key]=-1
    return 1
  fi
  _wsf_write_ids[$fd]="${_wsf_objects[$object]}"
  object="$_wsf_dir/$key.status"
  sysopen -w -o nonblock,nofollow,cloexec -u fd -- "$object" 2>/dev/null || return 1
  _wsf_sw[$key]="$fd"
  if ! _ws_fetch_fd_matches "$fd" "${_wsf_objects[$object]}"; then
    exec {fd}>&-
    _wsf_sw[$key]=-1
    return 1
  fi
  _wsf_write_ids[$fd]="${_wsf_objects[$object]}"
  if [[ "${_wsf_mode[$key]-}" == guard ]]; then
    object="$_wsf_dir/$key.go"
    sysopen -r -o nonblock,nofollow,cloexec -u fd -- "$object" 2>/dev/null || return 1
    _wsf_gr[$key]="$fd"
    if ! _ws_fetch_fd_matches "$fd" "${_wsf_objects[$object]}"; then
      exec {fd}<&-; _wsf_gr[$key]=-1; return 1
    fi
    _wsf_read_ids[$fd]="${_wsf_objects[$object]}"
    sysopen -w -o nonblock,nofollow,cloexec -u fd -- "$object" 2>/dev/null || return 1
    _wsf_gw[$key]="$fd"
    if ! _ws_fetch_fd_matches "$fd" "${_wsf_objects[$object]}"; then
      exec {fd}>&-; _wsf_gw[$key]=-1; return 1
    fi
    _wsf_write_ids[$fd]="${_wsf_objects[$object]}"
  fi

}

_ws_fetch_launch() {
  emulate -L zsh
  _ws_fetch_env_clearable || {
    _ws_error "Read-only repository variables prevent safe --fetch."
    return 1
  }
  local key="$1" mode="$2" program="$3" repository="${4-}" descriptor=""
  local nonce="${_wsf_dir:t}.$key.$RANDOM" REPLY=""
  _wsf_nonce[$key]="$nonce"; _wsf_mode[$key]="$mode"
  _ws_fetch_pair "$key" || return 1
  [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )) || return 1
  (
    local control="${_wsf_cr[$key]}" result="${_wsf_sw[$key]}"
    exec 3<&$control 4>&$result
    if [[ "$mode" == guard ]]; then
      local gate_reader="${_wsf_gr[$key]}" gate_writer="${_wsf_gw[$key]}"
      exec 5<&$gate_reader 6>&$gate_writer
    fi
    for descriptor in "${(@v)_wsf_cr}" "${(@v)_wsf_cw}" "${(@v)_wsf_sr}" \
      "${(@v)_wsf_sw}" "${(@v)_wsf_gr}" "${(@v)_wsf_gw}"; do
      (( descriptor >= 10 )) && exec {descriptor}>&-
    done
    local -A _wsf_write_ids=([4]="${_wsf_objects[$_wsf_dir/$key.status]}")
    if ! unset -- "${_WS_GIT_LOCAL_ENV_VARS[@]}"; then
      # Refusal before the fixed owner exec still has no native child. Report
      # that fact instead of treating an ordinary readonly-env refusal as loss.
      builtin trap ':' HUP PIPE
      _ws_fetch_send 4 "$nonce" OWNER_ERROR 1
      _ws_fetch_send 4 "$nonce" NO_CHILD 1
      exit 1
    fi
    export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never
    if [[ "$mode" == capability ]]; then
      exec "${_wsf_tools[zsh]}" -f "$_wsf_worker" capability "$nonce" \
        "${_wsf_objects[$_wsf_dir/$key.control]}" "${_wsf_objects[$_wsf_dir/$key.status]}" "$program"
    else
      exec "${_wsf_tools[zsh]}" -f "$_wsf_worker" owner "$nonce" \
        "${_wsf_objects[$_wsf_dir/$key.control]}" "${_wsf_objects[$_wsf_dir/$key.status]}" \
        "${_wsf_objects[$_wsf_dir/$key.go]}" "$_wsf_backend" "${_WS_FETCH_TIMEOUT}s" \
        "${_wsf_tools[zsh]}" "$_wsf_worker" "$program" "$repository" "${_wsf_tools[ps]}"
    fi
  ) </dev/null >/dev/null 2>&1 &
  # $! is not used as a wait/signal/cache certificate. The private owner reports
  # its actual native wait, and holds the status writer until its kernel exit.
  for descriptor in "${_wsf_cr[$key]}" "${_wsf_sw[$key]}" \
    "${_wsf_gr[$key]:--1}" "${_wsf_gw[$key]:--1}"; do
    (( descriptor >= 0 )) && exec {descriptor}>&-
  done
  _wsf_cr[$key]=-1; _wsf_sw[$key]=-1; _wsf_gr[$key]=-1; _wsf_gw[$key]=-1
  [[ "$mode" == guard ]] && _wsf_phase[$key]=owner || _wsf_phase[$key]=capability
  _wsf_active+=("$key")
}

_ws_fetch_cancel_handle() {
  emulate -L zsh
  local key="$1" descriptor="${_wsf_cw[$1]:--1}" reason="${_wsf_interrupt:-1}"
  (( descriptor >= 0 )) || return 0
  if ! _ws_fetch_fd_matches "$descriptor" "${_wsf_write_ids[$descriptor]-}"; then
    _wsf_fatal=1; _wsf_retain=1
    _wsf_cw[$key]=-1
    return 1
  fi
  _ws_fetch_send "$descriptor" "${_wsf_nonce[$key]}" CANCEL "$reason" || _wsf_fatal=1
  exec {descriptor}>&-
  _wsf_cw[$key]=-1
}

_ws_fetch_cancel_active() {
  emulate -L zsh
  local key=""
  for key in "${_wsf_active[@]}"; do _ws_fetch_cancel_handle "$key"; done
}

# Frame facts are separate: owner events never overwrite a guardian cause.
_ws_fetch_frame() {
  emulate -L zsh
  local key="$1" token="$2" value="$3"
  if [[ -n "${_wsf_no_child[$key]-}" && "$token" != (OWNER_ERROR|OWNER_INTERRUPT) ]]; then return 1; fi
  if [[ -n "${_wsf_native[$key]-}" && "$token" != (OWNER_ERROR|OWNER_INTERRUPT) ]]; then return 1; fi
  case "$token" in
    QUERY_INTERRUPT)
      [[ "$value" == (130|143) && "${_wsf_mode[$key]}" == guard \
        && -n "${_wsf_monitor[$key]-}" && "${_wsf_phase[$key]}" == binding \
        && -z "${_wsf_query_interrupt[$key]-}${_wsf_native[$key]-}${_wsf_no_child[$key]-}" ]] \
        && (( ! ${_wsf_started[$key]:-0} )) || return 1
      _wsf_query_interrupt[$key]="$value"
      : "${_wsf_interrupt:=$value}"
      return 0 ;;
    OWNER_ERROR)
      [[ -z "${_wsf_owner_error[$key]-}" ]] || return 1
      _wsf_owner_error[$key]=1; _wsf_fatal=1; _wsf_retain=1
      return 0 ;;
    OWNER_INTERRUPT)
      [[ -z "${_wsf_owner_interrupt[$key]-}" ]] || return 1
      _wsf_owner_interrupt[$key]="$value"
      : "${_wsf_interrupt:=$value}"
      return 0 ;;
    NO_CHILD)
      [[ -z "${_wsf_native[$key]-}${_wsf_monitor[$key]-}${_wsf_kind[$key]-}" ]] \
        && (( ! ${_wsf_started[$key]:-0} )) || return 1
      _wsf_no_child[$key]=1; _wsf_fatal=1
      return 0 ;;
    NATIVE_EXIT)
      [[ -z "${_wsf_native[$key]-}" ]] || return 1
      _wsf_native[$key]="$value"
      # Native completion closes all launch phases. In particular a later
      # READY cannot authorize START after the monitor has already exited.
      if [[ "${_wsf_mode[$key]}" == capability ]]; then
        [[ "${_wsf_kind[$key]-}" == CAPABILITY \
          || -n "${_wsf_owner_error[$key]-}${_wsf_owner_interrupt[$key]-}" ]] \
          || { _wsf_bad[$key]=1; _wsf_fatal=1; }
      elif (( ${_wsf_started[$key]:-0} )); then
        [[ -n "${_wsf_kind[$key]-}" ]] || { _wsf_bad[$key]=1; _wsf_fatal=1; }
      else
        _wsf_fatal=1
      fi
      _wsf_phase[$key]=exited
      (( value != 127 )) || { _wsf_fatal=1; _wsf_retain=1; }
      return 0 ;;
  esac
  case "${_wsf_phase[$key]}:$token" in
    owner:MONITOR)
      _wsf_monitor[$key]="$value"; _wsf_phase[$key]=guard ;;
    guard:BOOT)
      _ws_fetch_send "${_wsf_cw[$key]}" "${_wsf_nonce[$key]}" BIND "${_wsf_monitor[$key]}" \
        || _wsf_fatal=1
      _wsf_phase[$key]=binding ;;
    binding:READY)
      if [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )); then
        # Set BEFORE writing: a failed/short write cannot prove no delivery.
        _wsf_started[$key]=1
        _ws_fetch_send "${_wsf_cw[$key]}" "${_wsf_nonce[$key]}" START 0 || _wsf_fatal=1
        _wsf_phase[$key]=running
      fi ;;
    capability:CAPABILITY|running:RESULT|running:DEADLINE)
      _wsf_kind[$key]="$token"; _wsf_result[$key]="$value"; _wsf_phase[$key]=closing
      [[ "$token:$value" == RESULT:(130|143) ]] && : "${_wsf_interrupt:=$value}" ;;
    *:CANCELLED)
      [[ -z "${_wsf_kind[$key]-}" ]] || return 1
      _wsf_kind[$key]="$token"; _wsf_result[$key]="$value"; _wsf_phase[$key]=closing
      : "${_wsf_interrupt:=$value}" ;;
    *:ERROR)
      [[ -z "${_wsf_kind[$key]-}" ]] || return 1
      _wsf_kind[$key]=ERROR; _wsf_result[$key]=1; _wsf_phase[$key]=closing; _wsf_fatal=1 ;;
    *) return 1 ;;
  esac
  return 0
}

# This checks private protocol facts only, never a caller PID/job-status cache.
_ws_fetch_verified() {
  emulate -L zsh
  local key="$1"
  (( ! ${_wsf_lost[$key]:-0} && ! ${_wsf_bad[$key]:-0} )) || return 1
  if [[ -n "${_wsf_no_child[$key]-}" && -z "${_wsf_native[$key]-}" ]] \
    && (( ! ${_wsf_started[$key]:-0} )); then
    _wsf_fatal=1
    return 0
  fi
  [[ -n "${_wsf_native[$key]-}" && "${_wsf_native[$key]}" != 127 ]] || return 1
  if [[ "${_wsf_mode[$key]}" == guard ]]; then
    if (( ${_wsf_started[$key]:-0} )); then
      [[ -n "${_wsf_kind[$key]-}" && "${_wsf_native[$key]}" == 137 ]]
    else
      # Fixed code received no attempted START: no Git was created. Its actual
      # Native status (such as 1 or 125) plus EOF is verified refusal, not success.
      _wsf_fatal=1
      return 0
    fi
  elif [[ -n "${_wsf_owner_interrupt[$key]-}${_wsf_owner_error[$key]-}" ]]; then
    return 0
  elif [[ "${_wsf_kind[$key]-}" == CAPABILITY ]]; then
    if [[ "${_wsf_result[$key]}" == 0 ]]; then [[ "${_wsf_native[$key]}" == 0 ]];
    else [[ "${_wsf_native[$key]}" != (130|143) ]]; fi
  else return 1; fi
}

_ws_fetch_pump() {
  emulate -L zsh
  local key="" descriptor="" REPLY="" object=""
  local -a reply=() remaining=()
  local -i read_rc=0 frame_count=0
  for key in "${_wsf_active[@]}"; do
    descriptor="${_wsf_sr[$key]:--1}"
    if (( descriptor >= 0 )); then
      frame_count=0
      while (( frame_count++ < 12 )); do
        read_rc=0; _ws_fetch_read "$descriptor" || read_rc=$?
        (( read_rc == 1 )) && break
        if (( read_rc == 3 )); then _wsf_eof[$key]=1; break; fi
        if (( read_rc == 4 )); then
          _wsf_lost[$key]=1; _wsf_fatal=1; _wsf_retain=1; _wsf_unverified=1
          _ws_fetch_cancel_handle "$key"
          break
        fi
        if (( read_rc != 0 )) || ! _ws_fetch_decode "${_wsf_nonce[$key]}" "$REPLY" \
          || ! _ws_fetch_frame "$key" "${reply[1]}" "${reply[2]}"; then
          _wsf_fatal=1; _wsf_bad[$key]=1; _wsf_buffers[$descriptor]=""
          break
        fi
      done
    fi
    if (( ${_wsf_eof[$key]:-0} || ${_wsf_lost[$key]:-0} )); then
      if ! _ws_fetch_verified "$key"; then
        _wsf_fatal=1; _wsf_retain=1; _wsf_unverified=1
      fi
      for descriptor in "${_wsf_cw[$key]:--1}" "${_wsf_sr[$key]:--1}"; do
        if (( descriptor >= 0 )); then
          object="$_wsf_dir/$key.control"
          [[ "$descriptor" == "${_wsf_sr[$key]}" ]] && object="$_wsf_dir/$key.status"
          _ws_fetch_fd_matches "$descriptor" "${_wsf_objects[$object]-}" && exec {descriptor}>&-
        fi
        unset "_wsf_buffers[$descriptor]" "_wsf_bytes[$descriptor]" \
          "_wsf_read_ids[$descriptor]" "_wsf_write_ids[$descriptor]"
      done
      _wsf_cw[$key]=-1; _wsf_sr[$key]=-1
      for object in "$_wsf_dir/$key.control" "$_wsf_dir/$key.status" "$_wsf_dir/$key.go"; do
        [[ -n "${_wsf_objects[$object]-}" ]] || continue
        (( _wsf_retain )) && continue
        if _ws_fetch_object_id "$_wsf_dir" directory && [[ "$REPLY" == "$_wsf_dir_id" ]] \
          && _ws_fetch_object_id "$object" fifo && [[ "$REPLY" == "${_wsf_objects[$object]}" ]]; then
          command "${_wsf_tools[rm]}" -f -- "$object" 2>/dev/null || _wsf_fatal=1
          unset "_wsf_objects[$object]"
        else _wsf_fatal=1; fi
      done
    else remaining+=("$key"); fi
  done
  _wsf_active=("${remaining[@]}")
}

# Fetch-only lifecycle. Ordinary Git failures still return their count in REPLY;
# interrupt and infrastructure statuses propagate before the public report.
_ws_status_fetch() {
  emulate -L zsh
  setopt local_options local_traps no_monitor no_notify
  local git_path="$1" root="$2"
  shift 2
  local -a repositories=("$@") fetchable=() reply=() _wsf_active=()
  local -A _wsf_tools=() _wsf_objects=() _wsf_cr=() _wsf_cw=() _wsf_sr=() _wsf_sw=()
  local -A _wsf_gr=() _wsf_gw=() _wsf_phase=() _wsf_nonce=() _wsf_kind=() _wsf_result=()
  local -A _wsf_monitor=() _wsf_native=() _wsf_no_child=() _wsf_started=()
  local -A _wsf_owner_error=() _wsf_owner_interrupt=()
  local -A _wsf_query_interrupt=()
  local -A _wsf_mode=()
  local -A _wsf_eof=() _wsf_bad=() _wsf_lost=() _wsf_buffers=() _wsf_bytes=() _wsf_target=()
  local -A _wsf_read_ids=() _wsf_write_ids=()
  local _wsf_interrupt="" _wsf_worker="" _wsf_backend="" _wsf_dir="" _wsf_dir_id=""
  local relative="" remotes="" key="" candidate="" descriptor="" object=""
  local -i jobs=0 index=0 remote_rc=0 _wsf_fatal=0 _wsf_retain=0 _wsf_unverified=0 failed=0 fetched=0 _wsf_return_status=1
  builtin trap ': "${_wsf_interrupt:=130}"' INT
  builtin trap ': "${_wsf_interrupt:=143}"' TERM
  builtin trap '_wsf_fatal=1' PIPE HUP
  {
    () {
      _ws_fetch_jobs || return 1
      jobs=$REPLY
      _ws_fetch_load_helpers || { _ws_error "The private fetch lifecycle helpers are unavailable."; return 1; }
      _wsf_worker="$REPLY"
      for relative in "${repositories[@]}"; do
        [[ -z "$_wsf_interrupt" ]] || return "$_wsf_interrupt"
        remote_rc=0
        remotes=$(_ws_git_command "$_WS_PROBE_TIMEOUT" "$git_path" \
          -C "$root/$relative" remote </dev/null 2>/dev/null) || remote_rc=$?
        (( remote_rc == 130 || remote_rc == 143 )) && return "$remote_rc"
        (( remote_rc == 0 )) || {
          _ws_error "Could not inspect remotes: $relative"
          return 1
        }
        if [[ -n "$remotes" ]]; then fetchable+=("$relative"); else fetch_outcomes[$relative]=skipped; fi
      done
      [[ -z "$_wsf_interrupt" ]] || return "$_wsf_interrupt"
      if (( ${#fetchable} == 0 )); then
        _ws_info "No repository has a remote to fetch."
        REPLY=0
        return 0
      fi
      _ws_fetch_env_clearable || {
        _ws_error "Read-only repository variables prevent safe --fetch."
        return 1
      }
      for candidate in zsh ps mkfifo rm rmdir; do
        _ws_fetch_native_path "$candidate" || {
          _ws_error "A native $candidate is required for safe --fetch; install the capability and retry."
          return 1
        }
        _wsf_tools[$candidate]="$REPLY"
      done
      _ws_private_dir_create fetch || return 1
      _wsf_dir="${reply[1]}"
      {
        _ws_fetch_object_id "$_wsf_dir" directory || return 1
        _wsf_dir_id="$REPLY"
        for candidate in timeout gtimeout; do
          [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )) || break
          _ws_fetch_native_path "$candidate" || continue
          [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )) || break
          _wsf_backend="$REPLY"
          key="cap$(( ++index ))"
          _ws_fetch_launch "$key" capability "$_wsf_backend" || { _wsf_fatal=1; break; }
          while (( ${#_wsf_active} )); do
            _ws_fetch_pump
            [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )) || _ws_fetch_cancel_active
            zselect -t 1 2>/dev/null || true
          done
          [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )) || break
          [[ "${_wsf_kind[$key]-}:${_wsf_result[$key]-}" == CAPABILITY:0 ]] && break
          _wsf_backend=""
        done
        if [[ -z "$_wsf_backend" ]] && (( ! _wsf_fatal )); then
          _ws_error "Safe --fetch requires GNU timeout or gtimeout; install coreutils and retry."
          _wsf_fatal=1
        fi
        if [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )); then
          _ws_count_noun "${#fetchable}" repository repositories
          _ws_warn "Fetching $REPLY over the network with git fetch --prune (at most $jobs at a time, ${_WS_FETCH_TIMEOUT}s each)."
          for relative in "${fetchable[@]}"; do
            _ws_fetch_pump
            [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )) || break
            while (( ${#_wsf_active} >= jobs )); do
              _ws_fetch_pump
              [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )) || break
              zselect -t 1 2>/dev/null || true
            done
            [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )) || break
            key="job$(( ++index ))"
            _wsf_target[$key]="$relative"
            _ws_fetch_launch "$key" guard "$git_path" "$root/$relative" || { _wsf_fatal=1; break; }
          done
        fi
      } always {
        while (( ${#_wsf_active} )); do
          [[ -z "$_wsf_interrupt" ]] && (( ! _wsf_fatal )) || _ws_fetch_cancel_active
          _ws_fetch_pump
          zselect -t 1 2>/dev/null || true
        done
        for key in "${(@k)_wsf_nonce}"; do
          for descriptor in "${_wsf_cr[$key]:--1}" "${_wsf_cw[$key]:--1}" \
            "${_wsf_sr[$key]:--1}" "${_wsf_sw[$key]:--1}" \
              "${_wsf_gr[$key]:--1}" "${_wsf_gw[$key]:--1}"; do
            (( descriptor >= 0 )) || continue
            object="$_wsf_dir/$key.control"
            [[ "$descriptor" == "${_wsf_sr[$key]:--1}" \
              || "$descriptor" == "${_wsf_sw[$key]:--1}" ]] && object="$_wsf_dir/$key.status"
            [[ "$descriptor" == "${_wsf_gr[$key]:--1}" \
              || "$descriptor" == "${_wsf_gw[$key]:--1}" ]] && object="$_wsf_dir/$key.go"
            _ws_fetch_fd_matches "$descriptor" "${_wsf_objects[$object]-}" \
              && exec {descriptor}>&-
          done
        done
        for object in "${(@k)_wsf_objects}"; do
          (( _wsf_retain )) && continue
          if _ws_fetch_object_id "$_wsf_dir" directory && [[ "$REPLY" == "$_wsf_dir_id" ]] \
            && _ws_fetch_object_id "$object" fifo && [[ "$REPLY" == "${_wsf_objects[$object]}" ]]; then
            command "${_wsf_tools[rm]}" -f -- "$object" 2>/dev/null || _wsf_fatal=1
          else
            _wsf_fatal=1
          fi
        done
        if [[ -z "$_wsf_dir_id" ]]; then
          _ws_warn "Private fetch state could not be verified and was retained: ${(V)_wsf_dir}"
          _wsf_fatal=1
        elif _ws_fetch_object_id "$_wsf_dir" directory && [[ "$REPLY" == "$_wsf_dir_id" ]]; then
          command "${_wsf_tools[rmdir]}" -- "$_wsf_dir" 2>/dev/null || {
            _ws_warn "Private fetch state was retained: ${(V)_wsf_dir}"
            _wsf_fatal=1
          }
        else
          _ws_warn "Private fetch state changed and was retained: ${(V)_wsf_dir}"
          _wsf_fatal=1
        fi
      }
      if (( _wsf_unverified )); then
        _ws_warn "Fetch completion is unverified; private state retained: ${(V)_wsf_dir}"
      fi
      [[ -z "$_wsf_interrupt" ]] || return "$_wsf_interrupt"
      (( ! _wsf_fatal )) || { _ws_error "The fetch lifecycle could not be verified."; return 1; }
      for key in "${(@k)_wsf_target}"; do
        relative="${_wsf_target[$key]}"
        case "${_wsf_kind[$key]-}:${_wsf_result[$key]-}" in
          RESULT:0) fetch_outcomes[$relative]=ok; (( ++fetched )) ;;
          DEADLINE:124)
            fetch_outcomes[$relative]=timed-out; (( ++failed )); _ws_warn "Fetch timed out: $relative" ;;
          RESULT:*)
            fetch_outcomes[$relative]=failed; (( ++failed ))
            _ws_warn "Fetch failed: $relative (status ${_wsf_result[$key]})"
            ;;
          *) return 1 ;;
        esac
      done
      _ws_count_noun "${#fetchable}" repository repositories
      if (( failed == 0 )); then _ws_success "Fetched $REPLY."; else _ws_warn "Fetched $fetched of $REPLY; $failed failed."; fi
      REPLY=$failed
      return 0
    }
    _wsf_return_status=$?
  } always {
    # Parent interruption remains authoritative across every early return.
    [[ -z "$_wsf_interrupt" ]] || _wsf_return_status=$_wsf_interrupt
  }
  return "${_wsf_interrupt:-$_wsf_return_status}"
}

ws-status() {
  emulate -L zsh

  local -i fetch=0 json=0
  while (( $# > 0 )); do
    case "$1" in
      --fetch) fetch=1 ;;
      --json) json=1 ;;
      -h|--help)
        (( $# == 1 && ! fetch && ! json )) || {
          _ws_error "--help accepts no additional arguments."
          return 2
        }
        _ws_status_usage
        return 0
        ;;
      *)
        _ws_error "Unknown ws-status argument: $1"
        return 2
        ;;
    esac
    shift
  done

  local REPLY="" jq_path=""
  local -a reply=()
  if (( json )); then
    _ws_command_path jq || {
      _ws_error "jq is required for ws-status --json; install jq and retry."
      return 1
    }
    jq_path="$REPLY"
  fi
  _ws_git_program || return 1
  local git_path="$REPLY"
  _ws_workspace_root || return 1
  local root_literal="${reply[1]}" root="${reply[2]}"
  _ws_command_display "$root_literal"
  local root_display="$REPLY"
  _ws_collect_repositories "$root" || return 1
  local -a repositories=("${reply[@]}")
  local -i skipped=$REPLY total=${#repositories[@]}

  if (( ! json )); then
    _ws_header "Workspace Status"
    _ws_label "Workspace root" "$root_display"
  fi
  if (( skipped > 0 )); then
    _ws_count_noun "$skipped" directory directories
    _ws_warn "Skipped $REPLY whose names cannot be shown safely."
  fi

  local -A fetch_outcomes=()
  local -i fetch_failures=0
  if (( fetch && total > 0 )); then
    _ws_status_fetch "$git_path" "$root" "${repositories[@]}" || return
    fetch_failures=$REPLY
  fi

  zmodload zsh/datetime 2>/dev/null || {
    _ws_error "The Zsh datetime module is required for ws-status."
    return 1
  }
  local -i now=$EPOCHSECONDS
  local relative="" workspace="" name="" platform="" identity=""
  local branch_cell="" changes_cell="" sync_cell="" stash_cell="" age_cell=""
  local commit_at="" fetch_outcome="" object="" row="" error_text=""
  local -a attention_rows=() quiet_rows=() attention_objects=()
  local -a quiet_objects=() reasons=() error_lines=() probe=()
  local -i attention_count=0 error_count=0 needs_attention=0 detached=0

  for relative in "${repositories[@]}"; do
    probe=()
    reply=()
    _ws_status_probe "$git_path" "$root/$relative"
    probe=("${reply[@]}")
    name="${relative:t}"
    workspace=""
    [[ "$relative" == */* ]] && workspace="${relative%/*}"
    platform=""
    identity=""
    if [[ "$relative" == */*/* && "$relative" != */*/*/* ]]; then
      platform="${relative%%/*}"
      identity="${${relative#*/}%%/*}"
    fi
    fetch_outcome=""
    (( fetch )) && fetch_outcome="${fetch_outcomes[$relative]:-}"
    detached="${probe[3]:-0}"
    error_text="${probe[12]}"

    reasons=()
    if [[ "${probe[1]}" != ok ]]; then
      reasons+=(error)
      (( ++error_count ))
      error_lines+=("$relative: $error_text")
    else
      [[ "${probe[9]}" == <-> ]] && (( probe[9] > 0 )) && reasons+=(changes)
      [[ "${probe[7]}" == <-> ]] && (( probe[7] > 0 )) && reasons+=(ahead)
      [[ "${probe[8]}" == <-> ]] && (( probe[8] > 0 )) && reasons+=(behind)
      [[ "${probe[10]}" == <-> ]] && (( probe[10] > 0 )) && reasons+=(stashes)
      (( detached )) && reasons+=(detached)
      [[ "${probe[6]}" == gone ]] && reasons+=(upstream-gone)
    fi
    [[ "$fetch_outcome" == (failed|timed-out) ]] && reasons+=(fetch-failed)
    needs_attention=0
    (( ${#reasons[@]} > 0 )) && needs_attention=1
    (( needs_attention )) && (( ++attention_count ))

    commit_at=""
    if [[ "${probe[11]}" == <-> ]]; then
      TZ=UTC strftime -s commit_at '%Y-%m-%dT%H:%M:%SZ' "${probe[11]}" \
        2>/dev/null || commit_at=""
    fi

    if (( json )); then
      object=$(command "$jq_path" -nc \
        --arg path "$root/$relative" \
        --arg relative_path "$relative" \
        --arg workspace "$workspace" \
        --arg platform "$platform" \
        --arg identity "$identity" \
        --arg repository "$name" \
        --arg branch "${probe[2]}" \
        --argjson detached "$(( detached ? 1 : 0 ))" \
        --arg head "${probe[4]}" \
        --arg upstream "${probe[5]}" \
        --arg upstream_state "${probe[6]}" \
        --arg ahead "${probe[7]}" \
        --arg behind "${probe[8]}" \
        --arg changes "${probe[9]}" \
        --arg stashes "${probe[10]}" \
        --arg last_commit_at "$commit_at" \
        --argjson attention "$needs_attention" \
        --arg reasons "${(j:,:)reasons}" \
        --arg fetch "$fetch_outcome" \
        --arg error "$error_text" \
        'def text: if . == "" then null else . end;
         def count: if . == "" then null else tonumber end;
         {
           path: $path,
           relative_path: $relative_path,
           workspace: ($workspace | text),
           platform: ($platform | text),
           identity: ($identity | text),
           repository: $repository,
           branch: ($branch | text),
           detached: ($detached == 1),
           head: ($head | text),
           upstream: ($upstream | text),
           upstream_state: $upstream_state,
           ahead: ($ahead | count),
           behind: ($behind | count),
           changes: ($changes | count),
           stashes: ($stashes | count),
           last_commit_at: ($last_commit_at | text),
           attention: ($attention == 1),
           attention_reasons: (if $reasons == "" then [] else ($reasons | split(",")) end),
           fetch: ($fetch | text),
           error: ($error | text)
         }') || {
        _ws_error "jq could not build the ws-status JSON document."
        return 1
      }
      if (( needs_attention )); then
        attention_objects+=("$object")
      else
        quiet_objects+=("$object")
      fi
      continue
    fi

    if [[ "${probe[1]}" != ok ]]; then
      branch_cell="—"
      changes_cell="error"
      sync_cell="—"
      stash_cell="—"
      age_cell="—"
    else
      if (( detached )); then
        branch_cell="detached at ${probe[4]:-unknown}"
      else
        branch_cell="${probe[2]}"
      fi
      if [[ "${probe[9]}" == 0 ]]; then
        changes_cell="clean"
      else
        changes_cell="${probe[9]}"
      fi
      case "${probe[6]}" in
        tracking)
          if (( probe[7] == 0 && probe[8] == 0 )); then
            sync_cell="up to date"
          elif (( probe[8] == 0 )); then
            sync_cell="ahead ${probe[7]}"
          elif (( probe[7] == 0 )); then
            sync_cell="behind ${probe[8]}"
          else
            sync_cell="ahead ${probe[7]}, behind ${probe[8]}"
          fi
          ;;
        gone) sync_cell="upstream gone" ;;
        *) sync_cell="no upstream" ;;
      esac
      stash_cell="${probe[10]:-unknown}"
      if [[ "${probe[11]}" == <-> ]]; then
        _ws_status_age $(( now - probe[11] ))
        age_cell="$REPLY"
      else
        age_cell="none"
      fi
    fi
    [[ "$fetch_outcome" == (failed|timed-out) ]] \
      && sync_cell+=" (fetch failed)"
    row="${workspace:-.}"$'\t'"$name"$'\t'"$branch_cell"$'\t'"$changes_cell"
    row+=$'\t'"$sync_cell"$'\t'"$stash_cell"$'\t'"$age_cell"
    if (( needs_attention )); then
      attention_rows+=("$row")
    else
      quiet_rows+=("$row")
    fi
  done

  local -i final_rc=0
  (( error_count > 0 || fetch_failures > 0 )) && final_rc=1
  if (( final_rc != 0 && error_count < total )); then
    _ws_mark_partial
  fi

  if (( json )); then
    {
      (( ${#attention_objects[@]} > 0 )) \
        && print -rl -- "${attention_objects[@]}"
      (( ${#quiet_objects[@]} > 0 )) \
        && print -rl -- "${quiet_objects[@]}"
      true
    } | command "$jq_path" -c -n \
      --arg schema "zdx.ws-status.v1" \
      --arg base "$root" \
      --argjson fetched "$fetch" \
      --argjson repositories "$total" \
      --argjson attention "$attention_count" \
      --argjson errors "$error_count" \
      '{
         schema: $schema,
         base: $base,
         fetched: ($fetched == 1),
         counts: {
           repositories: $repositories,
           attention: $attention,
           errors: $errors
         },
         repositories: [inputs]
       }' || {
      _ws_error "jq could not build the ws-status JSON document."
      return 1
    }
    return $final_rc
  fi

  if (( total == 0 )); then
    _ws_info "No repositories were found below $root_display."
    return 0
  fi
  _ws_label "Repositories" "$total"
  print -u2 -r -- ""
  _ws_table \
    $'Workspace\tRepository\tBranch\tChanges\tSync\tStashes\tLast commit' \
    "${attention_rows[@]}" "${quiet_rows[@]}"
  print -u2 -r -- ""
  local error_line=""
  for error_line in "${error_lines[@]}"; do
    _ws_error "$error_line"
  done
  if (( attention_count > 0 )); then
    _ws_count_noun "$total" repository repositories
    if (( attention_count == 1 )); then
      _ws_warn "1 of $REPLY needs attention."
    else
      _ws_warn "$attention_count of $REPLY need attention."
    fi
  fi
  return $final_rc
}

typeset -g _WS_STATUS_SOURCED=1
