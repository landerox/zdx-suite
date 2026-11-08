#!/usr/bin/env bats

setup() {
  load test_helper
  load ws_fetch_test_helper
  export WFI_LOG="$HOME/fetch-status-model.log"
  export WFI_DISCOVERY="$HOME/fetch-discovery-model.log"
  export WFI_FDS="$HOME/fetch-pair-descriptors"
  export WFI_FDS_CHECK="$HOME/fetch-pair-retained"
  export WFI_LAUNCHED="$HOME/fetch-launch-modes"
  export WFI_RESULT="$HOME/fetch-model-result"
  export WFI_CALLER_WAIT="$HOME/fetch-caller-wait"
  export WFI_START_FLAG="$HOME/fetch-start-attempt"
  export WFI_BIND_LOG="$HOME/fetch-bind-pids"
  : > "$WFI_LOG"
  : > "$WFI_DISCOVERY"
  : > "$WFI_LAUNCHED"
  : > "$WFI_CALLER_WAIT"
  : > "$WFI_BIND_LOG"
}

teardown() {
  cleanup_sandbox
}

@test "ws fetch source: private worker re-sources silently without jobs or process setup" {
  run run_zsh '
    local before_options="${(kv)options}" before_traps="$(trap)" before_mask="$(umask)"
    local before_modules="$(zmodload -L)" before_jobs="${(kv)jobstates}"
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 91
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 92
    [[ "${(kv)options}" == "$before_options" && "$(trap)" == "$before_traps" \
      && "$(umask)" == "$before_mask" && "$(zmodload -L)" == "$before_modules" \
      && "${(kv)jobstates}" == "$before_jobs" && "$_WS_FETCH_WORKER_SOURCED" == 1 \
      && -n "${functions[_ws_fetch_worker_main]-}" ]]
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch parser: exact protocol values and bounded positive PID data" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 90
    local frame=""; local -a reply=()
    for frame in "BOOT 0" "READY 0" "START 0" "CAPABILITY 0" "CAPABILITY 1" \
      "GO 0" "MONITOR 314159" "NATIVE_EXIT 0" "NATIVE_EXIT 137" \
      "OWNER_ERROR 1" "OWNER_INTERRUPT 130" "OWNER_INTERRUPT 143" "NO_CHILD 1" \
      "QUERY_INTERRUPT 130" "QUERY_INTERRUPT 143" \
      "BIND 1" "BIND 2147483647" "DEADLINE 124" "CANCEL 1" "CANCEL 130" \
      "CANCEL 143" "CANCELLED 130" "CANCELLED 143" "ERROR 1" "RESULT 0" \
      "RESULT 255"; do
      _ws_fetch_decode nonce "nonce $frame" || exit 91
    done
    for frame in "BOOT 1" "DEADLINE 143" "BIND 0" "BIND 01" "BIND -1" \
      "MONITOR 0" "NATIVE_EXIT 256" "OWNER_INTERRUPT 1" "OWNER_ERROR 0" "NO_CHILD 0" \
      "QUERY_INTERRUPT 1" \
      "BIND 12345678901" "RESULT 256" "RESULT 00" "RESULT -1" "RESULT 1 extra" \
      "RESULT" "CANCELLED 1" "UNKNOWN 0" "RESULT 0 "; do
      _ws_fetch_decode nonce "nonce $frame" && exit 92
    done
    _ws_fetch_decode nonce "other RESULT 0" && exit 93
    exit 0
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch parser: partial data idle and clean EOF remain distinct" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 90
    _ws_fetch_modules || exit 91
    local -A _wsf_buffers=() _wsf_bytes=() _wsf_read_ids=()
    local -i reader=-1 writer=-1 rc=0
    command mkfifo -m 600 -- "$HOME/status.fifo" || exit 92
    sysopen -r -o nonblock,nofollow,cloexec -u reader -- "$HOME/status.fifo" || exit 93
    sysopen -w -o nonblock,nofollow,cloexec -u writer -- "$HOME/status.fifo" || exit 94
    _ws_fetch_object_id "$HOME/status.fifo" fifo || exit 102
    _wsf_read_ids[$reader]="$REPLY"
    _ws_fetch_read "$reader"; rc=$?; (( rc == 1 )) || exit 95
    syswrite -o "$writer" "nonce RES" || exit 96
    _ws_fetch_read "$reader"; rc=$?; (( rc == 1 )) || exit 97
    syswrite -o "$writer" $'\''ULT 0\nnonce READY 0\n'\'' || exit 98
    _ws_fetch_read "$reader" && [[ "$REPLY" == "nonce RESULT 0" ]] || exit 99
    _ws_fetch_read "$reader" && [[ "$REPLY" == "nonce READY 0" ]] || exit 100
    exec {writer}>&-
    _ws_fetch_read "$reader"; rc=$?; (( rc == 3 )) || exit 101
    exec {reader}<&-
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch parser: unterminated EOF malformed bytes and lost FD fail separately" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 90
    _ws_fetch_modules || exit 91
    local -A _wsf_buffers=() _wsf_bytes=() _wsf_read_ids=()
    local -i reader=-1 writer=-1 rc=0
    command mkfifo -m 600 -- "$HOME/status.fifo" || exit 92
    sysopen -r -o nonblock,nofollow,cloexec -u reader -- "$HOME/status.fifo" || exit 93
    sysopen -w -o nonblock,nofollow,cloexec -u writer -- "$HOME/status.fifo" || exit 94
    _ws_fetch_object_id "$HOME/status.fifo" fifo || exit 102
    _wsf_read_ids[$reader]="$REPLY"
    syswrite -o "$writer" "nonce RESULT 0" || exit 95
    _ws_fetch_read "$reader"; rc=$?; (( rc == 1 )) || exit 96
    exec {writer}>&-
    _ws_fetch_read "$reader"; rc=$?; (( rc == 2 )) || exit 97
    exec {reader}<&-
    _wsf_buffers[$reader]=""
    _ws_fetch_read "$reader"; rc=$?
    (( rc == 4 )) || { print -r -- "lost-reader-status=$rc"; exit 98; }
  '
  [[ "$status" -eq 0 ]] || printf 'status=%s output=%s\n' "$status" "$output" >&2
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch identities: FIFO modes links and changed objects are rejected" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 90
    _ws_fetch_modules || exit 91
    local original=""; local -i reader=-1
    command mkfifo -m 600 -- "$HOME/status.fifo" || exit 92
    _ws_fetch_object_id "$HOME/status.fifo" fifo || exit 93
    original="$REPLY"
    sysopen -r -o nonblock,nofollow,cloexec -u reader -- "$HOME/status.fifo" || exit 94
    _ws_fetch_fd_matches "$reader" "$original" || exit 95
    command chmod -- 644 "$HOME/status.fifo" || exit 96
    _ws_fetch_object_id "$HOME/status.fifo" fifo && exit 97
    _ws_fetch_fd_matches "$reader" "$original" && exit 98
    command chmod -- 600 "$HOME/status.fifo" || exit 99
    command ln -- "$HOME/status.fifo" "$HOME/linked.fifo" || exit 100
    _ws_fetch_object_id "$HOME/status.fifo" fifo && exit 101
    command rm -- "$HOME/linked.fifo" "$HOME/status.fifo" || exit 102
    command mkfifo -m 600 -- "$HOME/status.fifo" || exit 103
    _ws_fetch_object_id "$HOME/status.fifo" fifo || exit 104
    [[ "$REPLY" != "$original" ]] || exit 105
    command ln -s -- "$HOME/status.fifo" "$HOME/symlink.fifo" || exit 106
    _ws_fetch_object_id "$HOME/symlink.fifo" fifo && exit 107
    exec {reader}<&-
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch identities: a changed writer is neither written nor closed on cancellation" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || exit 90
    _ws_fetch_load_helpers || exit 91
    local -A _wsf_read_ids=() _wsf_write_ids=() _wsf_buffers=() _wsf_bytes=()
    local -A _wsf_cw=() _wsf_nonce=([job]=nonce)
    local -a _wsf_active=(job)
    local _wsf_interrupt="" identity=""
    local -i reader=-1 writer=-1 victim=-1 _wsf_fatal=0 _wsf_retain=0
    command mkfifo -m 600 -- "$HOME/status.fifo" || exit 92
    _ws_fetch_object_id "$HOME/status.fifo" fifo || exit 93
    identity="$REPLY"
    sysopen -r -o nonblock,nofollow,cloexec -u reader -- "$HOME/status.fifo" || exit 94
    sysopen -w -o nonblock,nofollow,cloexec -u writer -- "$HOME/status.fifo" || exit 95
    _wsf_read_ids[$reader]="$identity"; _wsf_write_ids[$writer]="$identity"
    _ws_fetch_send "$writer" nonce RESULT 0 || exit 96
    _ws_fetch_read "$reader" && [[ "$REPLY" == "nonce RESULT 0" ]] || exit 97
    exec {victim}>"$HOME/unchanged-writer"
    _wsf_write_ids[$victim]="$identity"; _wsf_cw[job]="$victim"
    _ws_fetch_send "$victim" nonce RESULT 0 && exit 98
    _ws_fetch_cancel_active
    (( _wsf_fatal == 1 && _wsf_retain == 1 )) || exit 99
    syswrite -o "$victim" still-open || exit 100
    exec {victim}>&- {writer}>&- {reader}<&-
    [[ "$(<"$HOME/unchanged-writer")" == still-open ]] || exit 101
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch grace: an early readiness return cannot consume the two-second grace" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 90
    _ws_fetch_modules || exit 91
    local -F SECONDS=100
    local -i calls=0
    zselect() {
      (( ++calls == 1 )) && return 1
      builtin zselect "$@"
    }
    _ws_fetch_wait_grace || exit 92
    (( SECONDS >= 102.0 && calls > 1 )) || exit 93
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Current cases use an explicit protocol stand-in. The pre-implementation
# four returned-status cases are archived separately as the original baseline.

@test "ws fetch status: child130 propagates and prevents later launch" {
  run_fetch_protocol_model 130
  [ "$status" -eq 130 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" != *'Fetch failed:'* && "$output" != *'Fetched '* ]]
}

@test "ws fetch status: child143 propagates and prevents later launch" {
  run_fetch_protocol_model 143
  [ "$status" -eq 143 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" != *'Fetch failed:'* && "$output" != *'Fetched '* ]]
}

@test "ws fetch status: ordinary child failure preserves the remaining batch" {
  run_fetch_protocol_model 1
  [ "$status" -eq 0 ]
  [ "$(cat "$WFI_LOG")" = $'first\nlater' ]
  [[ "$output" == *'Fetch failed: first (status 1)'* ]]
  [ "$(cat "$WFI_RESULT")" = '1 failed ok' ]
}

@test "ws fetch status: successful children preserve the complete batch" {
  run_fetch_protocol_model 0
  [ "$status" -eq 0 ]
  [ "$(cat "$WFI_LOG")" = $'first\nlater' ]
  [[ "$output" == *'Fetched 2 repositories.'* ]]
  [ "$(cat "$WFI_RESULT")" = '0 ok ok' ]
}

@test "ws fetch protocol: deadline without Git result counts timeout and continues" {
  run_fetch_protocol_model deadline
  [ "$status" -eq 0 ]
  [ "$(cat "$WFI_LOG")" = $'first\nlater' ]
  [[ "$output" == *'Fetch timed out: first'* && "$output" != *'Fetch failed: first'* ]]
}

@test "ws fetch protocol: missing terminal frame stops the batch with unknown failure" {
  run_fetch_protocol_model missing
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" == *'lifecycle could not be verified'* && "$output" != *'Fetched '* ]]
}

@test "ws fetch protocol: malformed terminal frame stops the batch" {
  run_fetch_protocol_model malformed
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" != *'Fetched '* ]]
}

@test "ws fetch protocol: duplicate terminal frames stop the batch" {
  run_fetch_protocol_model duplicate
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" != *'Fetched '* ]]
}

@test "ws fetch protocol: contradictory cancellation cannot manufacture an interruption" {
  run_fetch_protocol_model duplicatecancel
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" != *'Fetched '* ]]
}

@test "ws fetch protocol: capability frame cannot hide its failed native exit" {
  run_fetch_protocol_model capfailed
  [ "$status" -eq 1 ]
  [ ! -s "$WFI_LOG" ]
  [[ "$output" != *'Fetching '* ]]
}

@test "ws fetch protocol: successful Git frame cannot hide failed guardian teardown" {
  run_fetch_protocol_model badteardown
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" == *'lifecycle could not be verified'* && "$output" != *'Fetched '* ]]
}

@test "ws fetch protocol: a lost observer returns unknown failure and retains its evidence" {
  run_fetch_protocol_model lost
  [ "$status" -eq 1 ]
  [ ! -s "$WFI_LOG" ]
  [[ "$output" == *'Private fetch state was retained:'* \
    && "$output" == *'lifecycle could not be verified'* && "$output" != *'Fetched '* ]]
  local states=("$TMPDIR"/zdx-ws-fetch.*)
  [ "${#states[@]}" -eq 1 ]
  [ -p "${states[0]}/cap1.control" ]
  [ -p "${states[0]}/cap1.status" ]
}

@test "ws fetch refusal: partial endpoint setup closes before any native job starts" {
  run_fetch_protocol_model pairfail
  [ "$status" -eq 1 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_FDS_CHECK")" = 0 ]
  [[ "$output" == *'lifecycle could not be verified'* ]]
}

@test "ws fetch refusal: a freshly opened mismatching FIFO closes while its replacement remains" {
  run_fetch_protocol_model pairmismatch
  [ "$status" -eq 1 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_FDS_CHECK")" = 0 ]
  [ -p "$HOME/original-control.fifo" ]
  local states=("$TMPDIR"/zdx-ws-fetch.*)
  [ "${#states[@]}" -eq 1 ]
  [ -p "${states[0]}/cap1.control" ]
  [[ "$output" == *'Private fetch state was retained:'* ]]
}

@test "ws fetch refusal: no GNU backend starts no fetch" {
  run_fetch_protocol_model nobackend
  [ "$status" -eq 1 ]
  [ ! -s "$WFI_LOG" ]
  [[ "$output" == *'requires GNU timeout or gtimeout'* && "$output" != *'Fetching '* ]]
}

@test "ws fetch discovery: 130 propagates before any fetch or later observation" {
  run_fetch_protocol_model discovery130
  [ "$status" -eq 130 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_DISCOVERY")" = first ]
  [[ "$output" != *'No repository has a remote'* ]]
}

@test "ws fetch discovery: 143 propagates before any fetch or later observation" {
  run_fetch_protocol_model discovery143
  [ "$status" -eq 143 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_DISCOVERY")" = first ]
  [[ "$output" != *'No repository has a remote'* ]]
}

@test "ws fetch discovery: ordinary unknown remotes cannot claim empty success" {
  run_fetch_protocol_model discovery1
  [ "$status" -eq 1 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_DISCOVERY")" = first ]
  [[ "$output" == *'Could not inspect remotes: first'* ]]
}

@test "ws fetch discovery: demonstrated empty remotes need no fetch backend" {
  run_fetch_protocol_model empty
  [ "$status" -eq 0 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_DISCOVERY")" = $'first\nlater' ]
  [[ "$output" == *'No repository has a remote to fetch.'* ]]
}

# These callbacks only assign invocation-local state and return1. They neither
# deliver a signal nor start a fixed worker/native fetch job.
@test "ws fetch preflight: jobs failure preserves an already observed130" {
  run_fetch_protocol_model preflight_jobs130
  [ "$status" -eq 130 ]
  [ ! -s "$WFI_LOG" ]
  [ ! -s "$WFI_DISCOVERY" ]
}

@test "ws fetch preflight: loader failure preserves an already observed143" {
  run_fetch_protocol_model preflight_load143
  [ "$status" -eq 143 ]
  [ ! -s "$WFI_LOG" ]
  [ ! -s "$WFI_DISCOVERY" ]
}

@test "ws fetch preflight: native-tool failure preserves an already observed130" {
  run_fetch_protocol_model preflight_native130
  [ "$status" -eq 130 ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch preflight: directory failure preserves an already observed143" {
  run_fetch_protocol_model preflight_directory143
  [ "$status" -eq 143 ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch preflight: directory-identity failure preserves an already observed130" {
  run_fetch_protocol_model preflight_object130
  [ "$status" -eq 130 ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch preflight: capability qualification cancellation prevents its launch" {
  run_fetch_protocol_model capinterrupt
  [ "$status" -eq 143 ]
  [ ! -s "$WFI_LOG" ]
  [ ! -s "$WFI_LAUNCHED" ]
}

@test "ws fetch preflight: cancellation during pair setup prevents the actual launcher fork" {
  run_fetch_protocol_model pairinterrupt
  [ "$status" -eq 143 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_FDS_CHECK")" = 0 ]
}

@test "ws fetch owner protocol: coordinator uses MONITOR data and never calls wait" {
  run_fetch_protocol_model 0
  [ "$status" -eq 0 ]
  [ "$(cat "$WFI_BIND_LOG")" = $'314159\n314159' ]
  [ ! -s "$WFI_CALLER_WAIT" ]
}

@test "ws fetch owner protocol: missing native ACK cannot certify a Git success" {
  run_fetch_protocol_model noack
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" == *'completion is unverified'* && "$output" != *'Fetched '* ]]
}

@test "ws fetch owner protocol: owner error remains fatal after successful guardian cause" {
  run_fetch_protocol_model ownererror
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" != *'Fetched '* ]]
}

@test "ws fetch owner protocol: owner interruption after cause stops later launch" {
  run_fetch_protocol_model ownerint
  [ "$status" -eq 143 ]
  [ "$(cat "$WFI_LOG")" = first ]
  [[ "$output" != *'Fetched '* ]]
}

@test "ws fetch owner protocol: no-child cancellation requires no fake native ACK" {
  run_fetch_protocol_model nochild
  [ "$status" -eq 130 ]
  [ ! -s "$WFI_LOG" ]
  [[ "$output" != *'completion is unverified'* ]]
}

@test "ws fetch owner protocol: pre-START native1 EOF is verified cancellation without cause" {
  run_fetch_protocol_model prestart
  [ "$status" -eq 143 ]
  [ ! -s "$WFI_LOG" ]
  [[ "$output" != *'completion is unverified'* ]]
}

@test "ws fetch owner protocol: failed START write is marked before delivery and still requires137" {
  run_fetch_protocol_model startfail
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_START_FLAG")" = 1 ]
  [ ! -s "$WFI_LOG" ]
  [[ "$output" == *'completion is unverified'* ]]
}

@test "ws fetch capability protocol: native130 stops without trying another backend" {
  run_fetch_protocol_model cap130
  [ "$status" -eq 130 ]
  [ "$(cat "$WFI_LAUNCHED")" = capability ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch capability protocol: native143 stops without trying another backend" {
  run_fetch_protocol_model cap143
  [ "$status" -eq 143 ]
  [ "$(cat "$WFI_LAUNCHED")" = capability ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch capability protocol: query timeout is fatal rather than unavailable" {
  run_fetch_protocol_model captimeout
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LAUNCHED")" = capability ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch capability protocol: overflow is fatal rather than unavailable" {
  run_fetch_protocol_model capoverflow
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LAUNCHED")" = capability ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch capability protocol: native127 is unknown and stops next backend" {
  run_fetch_protocol_model cap127
  [ "$status" -eq 1 ]
  [ "$(cat "$WFI_LAUNCHED")" = capability ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch capability protocol: ACK without capability fact is unknown" {
  run_fetch_protocol_model capmissing
  [ "$status" -eq 1 ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch capability protocol: ordinary unavailable candidate permits gtimeout" {
  run_fetch_protocol_model capunavailable
  [ "$status" -eq 0 ]
  [ "$(cat "$WFI_LAUNCHED")" = $'capability\ncapability\nguard\nguard' ]
  [ "$(cat "$WFI_LOG")" = $'first\nlater' ]
}

@test "ws fetch owner IPC: third GO FIFO is private identity-bound and data-only" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || exit 90
    _ws_fetch_load_helpers || exit 91
    local -A _wsf_tools=([mkfifo]="$(whence -p mkfifo)") _wsf_objects=() _wsf_mode=([job]=guard)
    local -A _wsf_cr=() _wsf_cw=() _wsf_sr=() _wsf_sw=() _wsf_gr=() _wsf_gw=()
    local -A _wsf_read_ids=() _wsf_write_ids=() _wsf_buffers=() _wsf_bytes=()
    local -a reply=()
    local _wsf_dir="" _wsf_dir_id="" before_mask="$(umask)"
    _ws_private_dir_create fetch || exit 92
    _wsf_dir="${reply[1]}"
    _ws_fetch_object_id "$_wsf_dir" directory || exit 93
    _wsf_dir_id="$REPLY"
    _ws_fetch_pair job || exit 94
    (( ${#_wsf_objects} == 3 )) || exit 95
    _ws_fetch_fd_matches "${_wsf_gr[job]}" "${_wsf_objects[$_wsf_dir/job.go]}" || exit 96
    _ws_fetch_fd_matches "${_wsf_gw[job]}" "${_wsf_objects[$_wsf_dir/job.go]}" || exit 97
    _ws_fetch_send "${_wsf_gw[job]}" nonce GO 0 || exit 98
    _ws_fetch_read "${_wsf_gr[job]}" && [[ "$REPLY" == "nonce GO 0" ]] || exit 99
    [[ "$(umask)" == "$before_mask" ]] || exit 100
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch owner events: interrupt and infrastructure facts emit once without native jobs" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 90
    local _wsf_nonce=nonce _wsf_owner_interrupt=143
    local -i _wsf_owner_error=1 _wsf_interrupt_sent=0 _wsf_error_sent=0 _wsf_event_lost=0
    _ws_fetch_send() { print -r -- "$3 $4"; }
    _ws_fetch_owner_events || exit 91
    _ws_fetch_owner_events || exit 92
    (( _wsf_interrupt_sent == 1 && _wsf_error_sent == 1 && _wsf_event_lost == 0 )) || exit 93
  '
  [ "$status" -eq 0 ]
  [ "$output" = $'OWNER_INTERRUPT 143\nOWNER_ERROR 1' ]
}

@test "ws fetch owner events: undeliverable event latches error and delivery failure" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws/ws-fetch-worker.zsh" || exit 90
    local _wsf_nonce=nonce _wsf_owner_interrupt=130
    local -i _wsf_owner_error=0 _wsf_interrupt_sent=0 _wsf_error_sent=0 _wsf_event_lost=0
    _ws_fetch_send() { return 1; }
    _ws_fetch_owner_events && exit 91
    (( _wsf_event_lost == 1 && _wsf_owner_error == 1 )) || exit 92
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch owner protocol: READY after native exit never attempts START" {
  run_fetch_protocol_model earlyack
  [ "$status" -eq 1 ]
  [ ! -s "$WFI_START_FLAG" ]
  [ ! -s "$WFI_LOG" ]
}

@test "ws fetch capability protocol: capability fact after native exit cannot qualify" {
  run_fetch_protocol_model capearlyack
  [ "$status" -eq 1 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_LAUNCHED")" = capability ]
}

@test "ws query priority: actual capability130 survives an earlier query error" {
  run_query_priority_model capability 130
  [ "$status" -eq 1 ]
  [[ "$output" == *'OWNER_INTERRUPT 130'* && "$output" == *'OWNER_ERROR 1'* \
    && "$output" == *'NATIVE_EXIT 130'* && "$output" != *'CAPABILITY '* ]]
}

@test "ws query priority: actual capability143 survives an earlier query error" {
  run_query_priority_model capability 143
  [ "$status" -eq 1 ]
  [[ "$output" == *'OWNER_INTERRUPT 143'* && "$output" == *'OWNER_ERROR 1'* \
    && "$output" == *'NATIVE_EXIT 143'* && "$output" != *'CAPABILITY '* ]]
}

@test "ws query priority: actual ps130 is separate from the guardian error cause" {
  run_query_priority_model ps 130
  [ "$status" -eq 1 ]
  [[ "$output" == *'QUERY_INTERRUPT 130'* && "$output" == *'ERROR 1'* \
    && "$output" != *'CANCELLED '* && "$output" != *'READY '* ]]
}

@test "ws query priority: actual ps143 is separate from the guardian error cause" {
  run_query_priority_model ps 143
  [ "$status" -eq 1 ]
  [[ "$output" == *'QUERY_INTERRUPT 143'* && "$output" == *'ERROR 1'* \
    && "$output" != *'CANCELLED '* && "$output" != *'READY '* ]]
}

@test "ws query protocol: query fact latches global status without changing cause or starting" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || exit 90
    local -A _wsf_mode=([job]=guard) _wsf_monitor=([job]=314159) _wsf_phase=([job]=binding)
    local -A _wsf_query_interrupt=() _wsf_native=() _wsf_no_child=() _wsf_started=()
    local -A _wsf_owner_error=() _wsf_owner_interrupt=() _wsf_kind=() _wsf_result=()
    local _wsf_interrupt=""
    local -i _wsf_fatal=0 _wsf_retain=0
    _ws_fetch_send() { print -r -- unexpected-START; return 1; }
    _ws_fetch_frame job QUERY_INTERRUPT 130 || exit 91
    [[ "$_wsf_interrupt" == 130 && "${_wsf_phase[job]}" == binding \
      && -z "${_wsf_kind[job]-}${_wsf_started[job]-}" ]] || exit 92
    _ws_fetch_frame job READY 0 || exit 93
    [[ -z "${_wsf_started[job]-}" ]] || exit 94
    _ws_fetch_frame job ERROR 1 || exit 95
    [[ "${_wsf_kind[job]}:${_wsf_result[job]}" == ERROR:1 && "$_wsf_interrupt" == 130 ]] || exit 96
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws query protocol: scope phase once and lifetime guards reject invalid query facts" {
  run run_zsh '
    source "$ZSH_CUSTOM/functions/ws-menu.zsh" || exit 90
    local scenario=""
    for scenario in duplicate capability unbound beforebinding started native nochild; do
      () {
        local -A _wsf_mode=([job]=guard) _wsf_monitor=([job]=314159) _wsf_phase=([job]=binding)
        local -A _wsf_query_interrupt=() _wsf_native=() _wsf_no_child=() _wsf_started=()
        local -A _wsf_owner_error=() _wsf_owner_interrupt=() _wsf_kind=() _wsf_result=()
        local _wsf_interrupt=""
        local -i _wsf_fatal=0 _wsf_retain=0
        case "$scenario" in
          duplicate) _wsf_query_interrupt[job]=130 ;;
          capability) _wsf_mode[job]=capability ;;
          unbound) _wsf_monitor[job]="" ;;
          beforebinding) _wsf_phase[job]=guard ;;
          started) _wsf_started[job]=1 ;;
          native) _wsf_native[job]=137 ;;
          nochild) _wsf_no_child[job]=1 ;;
        esac
        _ws_fetch_frame job QUERY_INTERRUPT 143 && return 1
        [[ -z "$_wsf_interrupt" ]]
      } || exit 91
    done
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws query protocol: ps130 crosses the real FIFO parser and stops before START" {
  run_fetch_protocol_model queryps130
  [ "$status" -eq 130 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_LAUNCHED")" = $'capability\nguard' ]
  [[ "$output" != *'completion is unverified'* ]]
}

@test "ws query protocol: ps143 crosses the real FIFO parser and stops before START" {
  run_fetch_protocol_model queryps143
  [ "$status" -eq 143 ]
  [ ! -s "$WFI_LOG" ]
  [ "$(cat "$WFI_LAUNCHED")" = $'capability\nguard' ]
  [[ "$output" != *'completion is unverified'* ]]
}

@test "ws fetch environment: absent carriers stay absent and clearable" {
  run_fetch_environment_model absent
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch environment: mutable types and readonly-looking values stay unchanged" {
  run_fetch_environment_model mutable
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch environment: every fixed readonly carrier is refused without changing exports" {
  run_fetch_environment_model allreadonly
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l < "$WFI_ENV_RESULT" | tr -d ' ')" -eq 17 ]
}

@test "ws fetch environment: readonly scalar stays private and unchanged" {
  run_fetch_environment_model scalar
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch environment: readonly empty scalar is still refused" {
  run_fetch_environment_model empty
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch environment: declared readonly unset carrier is still refused" {
  run_fetch_environment_model declared
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch environment: readonly array remains unchanged" {
  run_fetch_environment_model array
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch environment: readonly association remains unchanged" {
  run_fetch_environment_model association
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch environment: readonly integer remains unchanged" {
  run_fetch_environment_model integer
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ws fetch environment: initial refusal precedes native qualification and state" {
  run_fetch_environment_model entry
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$WFI_ENV_RESULT")" = 'rc=1 native=0 directory=0 launch=0' ]
}

@test "ws fetch environment: capability refusal precedes pairing and launch maps" {
  run_fetch_environment_model launchcapability
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$WFI_ENV_RESULT")" = 'rc=1 pair=0 nonce=0 mode=0' ]
}

@test "ws fetch environment: fetch refusal precedes pairing and launch maps" {
  run_fetch_environment_model launchguard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$WFI_ENV_RESULT")" = 'rc=1 pair=0 nonce=0 mode=0' ]
}

@test "ws fetch environment: a trusted callback change is rechecked before pairing" {
  run_fetch_environment_model changed
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$WFI_ENV_RESULT")" = 'rc=1 pair=0 nonce=0 mode=0' ]
}

@test "ws fetch environment: demonstrated empty remotes still need no safe backend" {
  run_fetch_environment_model emptyremotes
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$WFI_ENV_RESULT")" = 'rc=0 native=0 directory=0 launch=0' ]
}

@test "ws fetch initial identity: ordinary failure retains and discloses the unverified directory" {
  run_fetch_initial_identity_model 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$WFI_IDENTITY_RESULT")" = 'rc=1 identity=1 launch=0 pair=0' ]
  [ -d "$WFI_IDENTITY_DIR" ]
  [ "$(file_mode "$WFI_IDENTITY_DIR")" = 700 ]
  [ -z "$(find "$WFI_IDENTITY_DIR" -mindepth 1 -print)" ]
  [ ! -s "$WFI_IDENTITY_MUTATIONS" ]
}

@test "ws fetch initial identity: observed130 survives disclosure without unsafe removal" {
  run_fetch_initial_identity_model 130
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$WFI_IDENTITY_RESULT")" = 'rc=130 identity=1 launch=0 pair=0' ]
  [ -d "$WFI_IDENTITY_DIR" ]
  [ "$(file_mode "$WFI_IDENTITY_DIR")" = 700 ]
  [ -z "$(find "$WFI_IDENTITY_DIR" -mindepth 1 -print)" ]
  [ ! -s "$WFI_IDENTITY_MUTATIONS" ]
}

@test "ws fetch initial identity: observed143 survives disclosure without unsafe removal" {
  run_fetch_initial_identity_model 143
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$WFI_IDENTITY_RESULT")" = 'rc=143 identity=1 launch=0 pair=0' ]
  [ -d "$WFI_IDENTITY_DIR" ]
  [ "$(file_mode "$WFI_IDENTITY_DIR")" = 700 ]
  [ -z "$(find "$WFI_IDENTITY_DIR" -mindepth 1 -print)" ]
  [ ! -s "$WFI_IDENTITY_MUTATIONS" ]
}
