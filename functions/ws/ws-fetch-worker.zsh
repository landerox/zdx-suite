#!/usr/bin/env zsh
# =============================================================================
# Workspace Fetch: private native-wait owners and owned-group guardian
# =============================================================================
#
# Loaded on demand by ws-status.zsh; safe to source for definitions only.
# Executed only by its fixed private owner/query/guardian launch protocol.
#

if [[ -z "${_WS_FETCH_WORKER_SOURCED:-}" ]]; then

_ws_fetch_modules() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null \
    && zmodload -F zsh/system b:sysopen b:sysread b:syswrite p:errnos p:sysparams 2>/dev/null \
    && zmodload -F zsh/parameter p:jobstates p:jobtexts 2>/dev/null \
    && zmodload zsh/zselect 2>/dev/null
}

# REPLY: a nofollow object identity. No chmod or unlink is performed here.
_ws_fetch_object_id() {
  emulate -L zsh
  local object="$1" kind="$2"
  local -A state=()
  REPLY=""
  [[ "$object" == /* && "$object" == "${object:a}" \
    && "$object" == "${object:A}" && ! -L "$object" ]] \
    && zstat -LH state -- "$object" 2>/dev/null || return 1
  (( state[uid] == EUID )) || return 1
  case "$kind" in
    fifo)
      (( (state[mode] & 8#170000) == 8#010000 \
        && (state[mode] & 8#777) == 8#600 && state[nlink] == 1 )) || return 1
      ;;
    directory)
      (( (state[mode] & 8#170000) == 8#040000 \
        && (state[mode] & 8#777) == 8#700 )) || return 1
      ;;
    *) return 1 ;;
  esac
  REPLY="${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}"
  [[ "$kind" == fifo ]] && REPLY+=":${state[nlink]}"
  return 0
}

_ws_fetch_fd_matches() {
  emulate -L zsh
  local -A state=()
  zstat -H state -f "$1" 2>/dev/null \
    && [[ "${state[device]}:${state[inode]}:${state[mode]}:${state[uid]}:${state[nlink]}" == "$2" ]] \
    && (( (state[mode] & 8#170000) == 8#010000 \
      && (state[mode] & 8#777) == 8#600 && state[uid] == EUID && state[nlink] == 1 ))
}

# Fixed three-field records only. Values are protocol integers, never tool output.
_ws_fetch_decode() {
  emulate -L zsh
  local nonce="$1" line="$2"
  local -a fields=("${(@s: :)line}")
  reply=()
  (( ${#line} <= 256 && ${#fields} == 3 )) && [[ "${fields[1]}" == "$nonce" ]] || return 1
  if [[ "${fields[2]}" == (BIND|MONITOR) ]]; then
    [[ "${fields[3]}" == <1-> && "${fields[3]}" != 0* \
      && ${#fields[3]} -le 10 ]] || return 1
  else
    [[ "${fields[3]}" == <0-255> && "${fields[3]}" != 0?* ]] || return 1
  fi
  case "${fields[2]}:${fields[3]}" in
    BOOT:0|READY:0|START:0|GO:0|CAPABILITY:0|CAPABILITY:1|DEADLINE:124|ERROR:1 \
      |OWNER_ERROR:1|OWNER_INTERRUPT:130|OWNER_INTERRUPT:143|NO_CHILD:1 \
      |QUERY_INTERRUPT:130|QUERY_INTERRUPT:143 \
      |CANCEL:1|CANCEL:130|CANCEL:143|CANCELLED:130|CANCELLED:143|RESULT:*|NATIVE_EXIT:*) ;;
    BIND:*|MONITOR:*) ;;
    *) return 1 ;;
  esac
  reply=("${fields[2]}" "${fields[3]}")
}

_ws_fetch_send() {
  emulate -L zsh
  setopt local_options no_multibyte
  local fd="$1" payload="$2 $3 $4"$'\n'
  local -i written=0
  _ws_fetch_fd_matches "$fd" "${_wsf_write_ids[$fd]-}" || return 1
  (( ${#payload} <= 256 )) || return 1
  syswrite -c written -o "$fd" "$payload" 2>/dev/null \
    && (( written == ${#payload} ))
}

# Caller owns invocation-local _wsf_buffers/_wsf_bytes/_wsf_read_ids maps. Status0 frame,
# 1 not ready/partial, 2 invalid framing, 3 clean EOF, 4 lost/read-error endpoint.
# Never block on a line or equate an unreadable descriptor with verified EOF.
_ws_fetch_read() {
  emulate -L zsh
  setopt local_options no_multibyte
  local fd="$1" chunk="" buffer="${_wsf_buffers[$1]-}"
  local -i count=0 read_rc=0
  REPLY=""
  # A zero-time readiness probe can call an invalid descriptor merely idle.
  # Observe descriptor validity first so EBADF never becomes an endless poll.
  _ws_fetch_fd_matches "$fd" "${_wsf_read_ids[$fd]-}" || return 4
  if [[ "$buffer" != *$'\n'* ]]; then
    sysread -t 0 -s 257 -c count -i "$fd" chunk 2>/dev/null || read_rc=$?
    case "$read_rc" in
      0)
        (( count > 0 )) && [[ "$chunk" != *$'\0'* && "$chunk" != *$'\r'* ]] || return 2
        _wsf_bytes[$fd]=$(( ${_wsf_bytes[$fd]:-0} + count ))
        (( _wsf_bytes[$fd] <= 4096 )) || return 2
        buffer+="$chunk"
        ;;
      4) return 1 ;;
      5) [[ -z "$buffer" ]] && return 3; return 2 ;;
      2)
        [[ "${errnos[ERRNO]-}" == (EAGAIN|EWOULDBLOCK) ]] && return 1
        return 4
        ;;
      *) return 4 ;;
    esac
  fi
  if [[ "$buffer" == *$'\n'* ]]; then
    REPLY="${buffer%%$'\n'*}"
    (( ${#REPLY} <= 255 )) || return 2
    _wsf_buffers[$fd]="${buffer#*$'\n'}"
    return 0
  fi
  (( ${#buffer} <= 255 )) || return 2
  _wsf_buffers[$fd]="$buffer"
  return 1
}

# A fresh query owner creates exactly one job and never launches a replacement.
_ws_fetch_job_slot() {
  emulate -L zsh
  local native_pid="$1" slot=""
  REPLY=""
  for slot in "${(@k)jobstates}"; do
    [[ "${jobstates[$slot]}" == *":${native_pid}="* ]] || continue
    REPLY="$slot"
    return 0
  done
  return 1
}

_ws_fetch_job_active() {
  emulate -L zsh
  [[ -n "$1" && "${jobstates[$1]-}" == (running|suspended):* \
    && "${jobstates[$1]-}" == *":$2="* ]]
}

# A fresh fixed owner has one outstanding native child. Missing initial slot
# lookup is not permission to wait a live child: inspect its current record.
_ws_fetch_native_active() {
  emulate -L zsh
  local native_pid="$1" slot=""
  for slot in "${(@k)jobstates}"; do
    [[ "${jobstates[$slot]}" == *":${native_pid}="* ]] || continue
    [[ "${jobstates[$slot]}" == (running|suspended):* ]]
    return $?
  done
  return 1
}

# Mainline only. An undeliverable event suppresses a later apparent-success ACK.
_ws_fetch_owner_events() {
  emulate -L zsh
  if [[ -n "$_wsf_owner_interrupt" ]] && (( ! _wsf_interrupt_sent )); then
    _wsf_interrupt_sent=1
    _ws_fetch_send 4 "$_wsf_nonce" OWNER_INTERRUPT "$_wsf_owner_interrupt" \
      || { _wsf_owner_error=1; _wsf_event_lost=1; }
  fi
  if (( _wsf_owner_error && ! _wsf_error_sent )); then
    _wsf_error_sent=1
    _ws_fetch_send 4 "$_wsf_nonce" OWNER_ERROR 1 || _wsf_event_lost=1
  fi
  (( ! _wsf_event_lost ))
}

# Only a fresh owner with a single outstanding child may use this wait path.
# No numeric wait runs while its own native record still says running/stopped.
_ws_fetch_wait_terminal() {
  emulate -L zsh
  local native_pid="$1" slot="$2"
  while _ws_fetch_native_active "$native_pid"; do
    (( ${_wsf_is_owner:-0} )) && _ws_fetch_owner_events
    zselect -t 1 2>/dev/null || true
  done
  builtin wait "$native_pid" 2>/dev/null
  _wsf_native_status=$?
}

# REPLY is bounded stdout. Its caller owns cause, query-status and started state.
# This is fresh-worker-only: the user's coprocess is never used or replaced.
_ws_fetch_capture() {
  emulate -L zsh
  setopt local_options no_monitor no_notify local_traps no_multibyte
  local native_pid="" slot="" slot_text="" chunk="" output="" gate=""
  local -i read_fd=-1 start_fd=-1 read_rc=0 count=0 output_eof=0
  local -F SECONDS=0
  local -a reply=()
  _wsf_query_started=0; _wsf_query_status=127
  REPLY=""
  [[ -z "$_wsf_cause" ]] || return 1
  {
    coproc (
      builtin trap - INT QUIT TERM HUP URG PIPE
      local gate=""
      IFS= read -r -t 2 gate && [[ "$gate" == GO ]] || exit 125
      exec 3<&- 4>&- 5<&- 6>&-
      exec "$@" </dev/null 2>/dev/null
    )
    native_pid="$!"
    [[ "$native_pid" == <1-> ]] || { native_pid=""; : "${_wsf_cause:=error:1}"; return 1; }
    _wsf_query_started=1
    exec {read_fd}<&p
    exec {start_fd}>&p
    _ws_fetch_job_slot "$native_pid" && slot="$REPLY" \
      || { : "${_wsf_cause:=error:1}"; return 1; }
    slot_text="${jobtexts[$slot]-}"
    _ws_fetch_job_active "$slot" "$native_pid" \
      && [[ -n "$slot_text" && "${jobtexts[$slot]-}" == "$slot_text" ]] \
      || { : "${_wsf_cause:=error:1}"; return 1; }
    if (( ${_wsf_is_owner:-0} )); then _ws_fetch_owner_events; fi
    [[ -z "$_wsf_cause" ]] || return 1
    syswrite -c count -o "$start_fd" $'GO\n' 2>/dev/null \
      && (( count == 3 )) || { : "${_wsf_cause:=error:1}"; return 1; }
    exec {start_fd}>&-
    start_fd=-1
    while (( SECONDS < 2.0 )); do
      [[ -z "$_wsf_cause" ]] || break
      read_rc=0; _ws_fetch_read 3 || read_rc=$?
      case "$read_rc" in
        0)
          if _ws_fetch_decode "$_wsf_nonce" "$REPLY" && [[ "${reply[1]}" == CANCEL ]]; then
            : "${_wsf_cause:=cancel:${reply[2]}}"
          else
            : "${_wsf_cause:=error:1}"
          fi
          break
          ;;
        2|3|4) : "${_wsf_cause:=error:1}"; break ;;
      esac
      if (( ! output_eof )); then
        chunk=""; count=0; read_rc=0
        sysread -t 0 -s 4097 -c count -i "$read_fd" chunk 2>/dev/null || read_rc=$?
        case "$read_rc" in
          0)
            output+="$chunk"
            (( ${#output} <= 4096 )) || { : "${_wsf_cause:=error:1}"; break; }
            ;;
          5) output_eof=1 ;;
          4) ;;
          2) [[ "${errnos[ERRNO]-}" == (EAGAIN|EWOULDBLOCK) ]] \
            || { : "${_wsf_cause:=error:1}"; break; } ;;
          *) : "${_wsf_cause:=error:1}"; break ;;
        esac
      fi
      if (( output_eof )) && ! _ws_fetch_job_active "$slot" "$native_pid"; then break; fi
      zselect -t 1 2>/dev/null || true
    done
    (( SECONDS < 2.0 )) || : "${_wsf_cause:=error:1}"
  } always {
    (( read_fd >= 0 )) && exec {read_fd}<&-
    (( start_fd >= 0 )) && exec {start_fd}>&-
    if [[ -n "$native_pid" ]]; then
      # The fresh owner has no competing child or later launch. Native job
      # lookup skips already-finished processes rather than signaling old PIDs.
      _ws_fetch_job_active "$slot" "$native_pid" \
        && builtin kill -KILL -- "%$slot" 2>/dev/null
      _ws_fetch_wait_terminal "$native_pid" "$slot"
      _wsf_query_status=$_wsf_native_status
    fi
  }
  (( _wsf_query_status != 127 )) || : "${_wsf_cause:=error:1}"
  if (( _wsf_query_status == 130 || _wsf_query_status == 143 )); then
    : "${_wsf_cause:=cancel:$_wsf_query_status}"
  fi
  REPLY="$output"
  [[ -z "$_wsf_cause" ]] && (( _wsf_query_status == 0 ))
}

# One GNU child, no external command or further fork after its launch. FD4 is
# never explicitly closed: its final EOF comes from this fixed owner's exit.
_ws_fetch_owner() {
  emulate -L zsh
  setopt local_options local_traps no_monitor no_notify
  local go_id="$1" backend="$2" duration="$3" zsh_path="$4" worker="$5"
  local git_path="$6" repository="$7" ps_path="$8"
  local native_pid="" slot="" slot_text="" REPLY=""
  local _wsf_owner_interrupt=""
  local -i _wsf_owner_error=0 _wsf_interrupt_sent=0 _wsf_error_sent=0 _wsf_event_lost=0
  local -i _wsf_is_owner=1 _wsf_native_status=127 created=0
  builtin trap ': "${_wsf_owner_interrupt:=130}"' INT
  builtin trap ': "${_wsf_owner_interrupt:=143}"' TERM
  builtin trap '_wsf_owner_error=1' HUP PIPE
  {
    if ! _ws_fetch_fd_matches 5 "$go_id" || ! _ws_fetch_fd_matches 6 "$go_id"; then
      _wsf_owner_error=1
    fi
    _ws_fetch_owner_events
    [[ -z "$_wsf_owner_interrupt" ]] && (( ! _wsf_owner_error )) || return 1
    (
      builtin trap - INT QUIT TERM HUP URG PIPE
      exec 6>&-
      local -A _wsf_read_ids=([5]="$go_id") _wsf_buffers=() _wsf_bytes=()
      local -a reply=()
      local REPLY=""
      local -i read_rc=0 released=0
      local -F SECONDS=0
      while (( SECONDS < 2.0 )); do
        read_rc=0; _ws_fetch_read 5 || read_rc=$?
        if (( read_rc == 0 )); then
          _ws_fetch_decode "$_wsf_nonce" "$REPLY" \
            && [[ "${reply[1]}:${reply[2]}" == GO:0 ]] || exit 125
          released=1
          break
        fi
        (( read_rc == 1 )) || exit 125
        zselect -t 1 2>/dev/null || true
      done
      (( released )) || exit 125
      exec 5<&-
      exec "$backend" --signal=URG -k 2s "$duration" \
        "$zsh_path" -f "$worker" guard "$_wsf_nonce" "$control_id" "$status_id" \
        "$git_path" "$repository" "$ps_path" </dev/null >/dev/null 2>&1
    ) &
    native_pid="$!"
    [[ "$native_pid" == <1-> ]] || { native_pid=""; _wsf_owner_error=1; return 1; }
    created=1
    exec 3<&- 5<&-
    _ws_fetch_job_slot "$native_pid" && slot="$REPLY" || _wsf_owner_error=1
    slot_text="${jobtexts[$slot]-}"
    _ws_fetch_job_active "$slot" "$native_pid" \
      && [[ -n "$slot_text" && "${jobtexts[$slot]-}" == "$slot_text" ]] || _wsf_owner_error=1
    if (( ! _wsf_owner_error )); then
      _ws_fetch_send 4 "$_wsf_nonce" MONITOR "$native_pid" || _wsf_owner_error=1
    fi
    _ws_fetch_owner_events
    if [[ -z "$_wsf_owner_interrupt" ]] && (( ! _wsf_owner_error )); then
      _ws_fetch_send 6 "$_wsf_nonce" GO 0 || _wsf_owner_error=1
    fi
    exec 6>&-
  } always {
    _ws_fetch_owner_events
    if (( created )); then
      _ws_fetch_wait_terminal "$native_pid" "$slot"
      (( _wsf_native_status != 127 )) || _wsf_owner_error=1
      _ws_fetch_owner_events
      (( _wsf_event_lost )) \
        || _ws_fetch_send 4 "$_wsf_nonce" NATIVE_EXIT "$_wsf_native_status" \
        || _wsf_owner_error=1
    else
      [[ -n "$_wsf_owner_interrupt" ]] || _wsf_owner_error=1
      _ws_fetch_owner_events
      (( _wsf_event_lost )) || _ws_fetch_send 4 "$_wsf_nonce" NO_CHILD 1
    fi
    _ws_fetch_owner_events
  }
  return 1
}

_ws_fetch_capability_owner() {
  emulate -L zsh
  setopt local_options local_traps no_monitor no_notify
  local program="$1" _wsf_cause="" REPLY="" _wsf_owner_interrupt=""
  local -i _wsf_query_started=0 _wsf_query_status=127 _wsf_native_status=127
  local -i _wsf_owner_error=0 _wsf_interrupt_sent=0 _wsf_error_sent=0 _wsf_event_lost=0 _wsf_is_owner=1
  local -A _wsf_buffers=() _wsf_bytes=()
  builtin trap ': "${_wsf_owner_interrupt:=130}"; : "${_wsf_cause:=cancel:130}"' INT
  builtin trap ': "${_wsf_owner_interrupt:=143}"; : "${_wsf_cause:=cancel:143}"' TERM
  builtin trap '_wsf_owner_error=1; : "${_wsf_cause:=error:1}"' HUP PIPE
  _ws_fetch_capture "$program" --version
  # Always cleanup may have consumed a real130/143 after an earlier error or
  # an early return. Read that fact here; do not replace the query's first cause.
  if (( _wsf_query_status == 130 || _wsf_query_status == 143 )); then
    : "${_wsf_owner_interrupt:=$_wsf_query_status}"
  fi
  case "$_wsf_cause" in
    cancel:130|cancel:143) : "${_wsf_owner_interrupt:=${_wsf_cause#*:}}" ;;
    ?*) _wsf_owner_error=1 ;;
  esac
  _ws_fetch_owner_events
  if (( ! _wsf_query_started )); then
    [[ -n "$_wsf_owner_interrupt" ]] || _wsf_owner_error=1
    _ws_fetch_owner_events
    (( _wsf_event_lost )) || _ws_fetch_send 4 "$_wsf_nonce" NO_CHILD 1
  else
    if [[ -z "$_wsf_owner_interrupt" ]] && (( ! _wsf_owner_error )); then
      if (( _wsf_query_status == 0 )) && [[ "$REPLY" == (timeout|gtimeout)' (GNU coreutils) '* ]]; then
        _ws_fetch_send 4 "$_wsf_nonce" CAPABILITY 0 || _wsf_owner_error=1
      else
        _ws_fetch_send 4 "$_wsf_nonce" CAPABILITY 1 || _wsf_owner_error=1
      fi
    fi
    _ws_fetch_owner_events
    (( _wsf_event_lost )) \
      || _ws_fetch_send 4 "$_wsf_nonce" NATIVE_EXIT "$_wsf_query_status" \
      || _wsf_owner_error=1
  fi
  _ws_fetch_owner_events
  return 1
}

# A caught signal may interrupt zselect before its requested interval expires.
# SECONDS is local to this fresh-worker helper; recheck elapsed time each tick.
_ws_fetch_wait_grace() {
  emulate -L zsh
  local -F SECONDS=0
  while (( SECONDS < 2.0 )); do
    zselect -t 1 2>/dev/null || true
  done
}

_ws_fetch_guard_finish() {
  emulate -L zsh
  (( _wsf_bound == 1 )) || return 1
  case "$_wsf_cause" in
    result:*) _ws_fetch_send 4 "$_wsf_nonce" RESULT "${_wsf_cause#*:}" ;;
    deadline:124) _ws_fetch_send 4 "$_wsf_nonce" DEADLINE 124 ;;
    cancel:130|cancel:143) _ws_fetch_send 4 "$_wsf_nonce" CANCELLED "${_wsf_cause#*:}" ;;
    *) _ws_fetch_send 4 "$_wsf_nonce" ERROR 1 ;;
  esac
  # BIND proved this process is a member of the private GNU group. Its own
  # continuing membership holds that identity; no historical PID is used.
  builtin kill -TERM -- 0 2>/dev/null
  _ws_fetch_wait_grace
  builtin kill -KILL -- 0 2>/dev/null
  return 1
}

_ws_fetch_guard() {
  emulate -L zsh
  setopt local_options no_monitor no_notify local_traps
  local git_path="$1" repository="$2" ps_path="$3"
  local _wsf_cause="" REPLY="" frame="" slot=""
  local -i _wsf_bound=0 native_pid=0 read_rc=0 tick=0 child_rc=1
  local -i _wsf_query_started=0 _wsf_query_status=127 _wsf_native_status=127 _wsf_is_owner=0 query_rc=1
  local -a reply=() facts=()
  local -A _wsf_buffers=() _wsf_bytes=()
  builtin trap ': "${_wsf_cause:=cancel:130}"' INT
  builtin trap ': "${_wsf_cause:=cancel:143}"' TERM
  builtin trap ': "${_wsf_cause:=error:1}"' HUP PIPE
  builtin trap ': "${_wsf_cause:=deadline:124}"' URG
  {
    _ws_fetch_send 4 "$_wsf_nonce" BOOT 0 || return 1
    while (( tick++ < 200 )); do
      [[ -z "$_wsf_cause" ]] || return 1
      read_rc=0; _ws_fetch_read 3 || read_rc=$?
      if (( read_rc == 0 )); then
        _ws_fetch_decode "$_wsf_nonce" "$REPLY" || return 1
        if [[ "${reply[1]}" == CANCEL ]]; then
          : "${_wsf_cause:=cancel:${reply[2]}}"
          return 1
        fi
        [[ "${reply[1]}" == BIND ]] || return 1
        frame="${reply[2]}"
        break
      fi
      (( read_rc == 1 )) || return 1
      zselect -t 1 2>/dev/null || true
    done
    [[ -n "$frame" ]] || return 1
    query_rc=0
    _ws_fetch_capture "$ps_path" -o pid= -o ppid= -o pgid= -p "${sysparams[pid]}" || query_rc=$?
    if (( _wsf_query_status == 130 || _wsf_query_status == 143 )); then
      # This query fact is independent of the immutable guardian/GNU cause.
      query_rc=1
      _ws_fetch_send 4 "$_wsf_nonce" QUERY_INTERRUPT "$_wsf_query_status" \
        || : "${_wsf_cause:=error:1}"
    fi
    (( query_rc == 0 )) || return 1
    facts=(${=REPLY})
    (( ${#facts} == 3 )) && [[ "${facts[1]}" == "${sysparams[pid]}" \
      && "${facts[2]}" == "$frame" && "${facts[3]}" == "$frame" ]] || return 1
    _wsf_bound=1
    _ws_fetch_send 4 "$_wsf_nonce" READY 0 || return 1
    tick=0; frame=""
    while (( tick++ < 200 )); do
      [[ -z "$_wsf_cause" ]] || return 1
      read_rc=0; _ws_fetch_read 3 || read_rc=$?
      if (( read_rc == 0 )); then
        _ws_fetch_decode "$_wsf_nonce" "$REPLY" || return 1
        if [[ "${reply[1]}" == CANCEL ]]; then
          : "${_wsf_cause:=cancel:${reply[2]}}"
          return 1
        fi
        [[ "${reply[1]}:${reply[2]}" == START:0 ]] || return 1
        frame=started
        break
      fi
      (( read_rc == 1 )) || return 1
      zselect -t 1 2>/dev/null || true
    done
    [[ "$frame" == started && -z "$_wsf_cause" ]] || return 1
    (
      builtin trap - INT QUIT TERM HUP URG PIPE
      exec 3<&- 4>&-
      exec "$git_path" -C "$repository" fetch --prune --quiet \
        </dev/null >/dev/null 2>&1
    ) &
    native_pid="$!"
    _ws_fetch_job_slot "$native_pid" && slot="$REPLY" \
      || { : "${_wsf_cause:=error:1}"; return 1; }
    while [[ -z "$_wsf_cause" ]]; do
      read_rc=0; _ws_fetch_read 3 || read_rc=$?
      case "$read_rc" in
        0)
          if _ws_fetch_decode "$_wsf_nonce" "$REPLY" && [[ "${reply[1]}" == CANCEL ]]; then
            : "${_wsf_cause:=cancel:${reply[2]}}"
          else
            : "${_wsf_cause:=error:1}"
          fi
          ;;
        2|3|4) : "${_wsf_cause:=error:1}" ;;
      esac
      if [[ -z "$_wsf_cause" ]] && ! _ws_fetch_job_active "$slot" "$native_pid"; then
        _ws_fetch_wait_terminal "$native_pid" "$slot"
        child_rc=$_wsf_native_status
        if (( child_rc == 127 )); then : "${_wsf_cause:=error:1}";
        else : "${_wsf_cause:=result:$child_rc}"; fi
      fi
      [[ -z "$_wsf_cause" ]] && { zselect -t 1 2>/dev/null || true; }
    done
  } always {
    if (( _wsf_bound )); then
      : "${_wsf_cause:=error:1}"
      _ws_fetch_guard_finish
    else
      case "$_wsf_cause" in
        cancel:130|cancel:143) _ws_fetch_send 4 "$_wsf_nonce" CANCELLED "${_wsf_cause#*:}" ;;
        *) _ws_fetch_send 4 "$_wsf_nonce" ERROR 1 ;;
      esac
    fi
  }
  return 1
}

# Status4 is already validated. These rejections precede any child creation;
# an unusable status channel remains the explicit unverified exception.
_ws_fetch_bootstrap_refuse() {
  emulate -L zsh
  setopt local_options local_traps
  builtin trap ':' HUP PIPE
  if [[ "$1" == guard ]]; then
    _ws_fetch_send 4 "$_wsf_nonce" ERROR 1
  else
    _ws_fetch_send 4 "$_wsf_nonce" OWNER_ERROR 1
    _ws_fetch_send 4 "$_wsf_nonce" NO_CHILD 1
  fi
}

_ws_fetch_worker_main() {
  emulate -L zsh
  setopt local_options local_traps
  (( $# >= 4 )) || return 2
  local mode="$1" _wsf_nonce="$2" control_id="$3" status_id="$4"
  local -A _wsf_read_ids=([3]="$control_id")
  local -A _wsf_write_ids=([4]="$status_id")
  shift 4
  _ws_fetch_modules || return 1
  [[ -n "$_wsf_nonce" && ${#_wsf_nonce} -le 128 \
    && "$_wsf_nonce" != *[^A-Za-z0-9_.:-]* ]] || return 2
  _ws_fetch_fd_matches 4 "$status_id" || return 1
  _ws_fetch_fd_matches 3 "$control_id" || { _ws_fetch_bootstrap_refuse "$mode"; return 1; }
  case "$mode" in
    capability)
      (( $# == 1 )) || { _ws_fetch_bootstrap_refuse "$mode"; return 2; }
      _ws_fetch_capability_owner "$1"
      ;;
    owner)
      (( $# == 8 )) && [[ "$3" == <1-60>s ]] \
        || { _ws_fetch_bootstrap_refuse "$mode"; return 2; }
      _wsf_write_ids[6]="$1"
      _ws_fetch_owner "$@"
      ;;
    guard)
      (( $# == 3 )) || { _ws_fetch_bootstrap_refuse "$mode"; return 2; }
      _ws_fetch_guard "$@"
      ;;
    *) return 2 ;;
  esac
}

typeset -g _WS_FETCH_WORKER_SOURCED=1
fi

if [[ "${ZSH_EVAL_CONTEXT:-}" == toplevel ]]; then
  _ws_fetch_worker_main "$@"
  exit $?
fi
