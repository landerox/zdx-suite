#!/usr/bin/env bats
# Each BATS case has a fresh setup; exported boundary controls intentionally
# change only inside that case, not between the independent test subshells.
# shellcheck disable=SC2030,SC2031

setup() {
  load test_helper
  export T03_FIXTURE="$TEST_TEMP_DIR/session-cleanup"
  mkdir -m 700 "$T03_FIXTURE"
  export ZDX_TEST_SESSION_PROBE="$T03_FIXTURE/probe.bats"
  export ZDX_TEST_SESSION_RECEIPT="$T03_FIXTURE/receipt"
  printf 'private probe data\n' > "$ZDX_TEST_SESSION_PROBE"
  export T03_CLEANUP_SOURCE="$T03_FIXTURE/cleanup-functions.bash"
  _t03_extract_cleanup
  _t03_install_process_fences
  _t03_reset_observations
}

teardown() {
  # Never invoke the cleanup under test from teardown. It runs only inside
  # the fenced BATS run subshell below; the shared teardown owns this sandbox.
  cleanup_sandbox
}

# Load function definitions only, never setup/teardown or a PTY probe. The
# legacy signal spelling is checked before this text can be sourced: both
# old and corrected cleanup must use the non-forwarding shell kill boundary.
_t03_extract_cleanup() {
  local line signal started=0 finished=0 signal_lines=0
  : > "$T03_CLEANUP_SOURCE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == '_zdx_test_parallel_session_probe() {' ]]; then
      finished=1
      break
    fi
    if [[ "$line" =~ ^_zdx_test_(session_probe_[[:alnum:]_]+|stop_session_probe)\(\)[[:space:]]*\{ ]]; then
      started=1
    fi
    (( started )) || continue
    if [[ ! "$line" =~ ^[[:space:]]*# && "$line" == *kill* ]]; then
      signal=${line#"${line%%[![:space:]]*}"}
      # shellcheck disable=SC2016 # these are exact source spellings, not argv
      case "$signal" in
        'kill -KILL -- "-$group" 2>/dev/null || true' | \
        'kill -KILL -- "-$group" 2>/dev/null || return 1' | \
        'kill -KILL -- "-$group" 2>/dev/null') ;;
        *)
          printf 'Unfenced signal syntax in cleanup section: %s\n' "$line" >&2
          return 1
          ;;
      esac
      signal_lines=$((signal_lines + 1))
    fi
    if [[ ! "$line" =~ ^[[:space:]]*# && "$line" =~ /([^[:space:]]*/)?ps([[:space:]]|$) ]]; then
      printf 'Absolute process discovery escapes the fixture: %s\n' "$line" >&2
      return 1
    fi
    printf '%s\n' "$line" >> "$T03_CLEANUP_SOURCE"
  done < "$TEST_SUITE_ROOT/test/sandbox_isolation.bats"
  [[ "$started" -eq 1 ]]
  [[ "$finished" -eq 1 ]]
  [[ "$signal_lines" -eq 1 ]]
  [[ "$(< "$T03_CLEANUP_SOURCE")" == *'_zdx_test_stop_session_probe() {'* ]]
}

_t03_install_process_fences() {
  # Absolute paths to these inert scripts also cover `command ps/kill`.
  # A new absolute host ps/kill or builtin kill is rejected by extraction.
  local tool
  for tool in ps kill; do
    printf '#!%s\n' "$BASH" > "$TEST_MOCK_BIN/$tool"
    cat >> "$TEST_MOCK_BIN/$tool" <<'BASH'
tool=${0##*/}
{
  printf '%s' "$tool"
  printf ' <%s>' "$@"
  printf '\n'
} >> "$T03_FIXTURE/process.log"
if [[ "$tool" == kill ]]; then
  {
    printf 'kill'
    printf ' <%s>' "$@"
    printf '\n'
  } >> "$T03_FIXTURE/events.log"
  exit "$T03_KILL_STATUS"
fi
case "$*" in
  '-eo pid=,pgid=,args=')
    printf '%s %s observer %s\n' 691003 691003 "$ZDX_TEST_SESSION_PROBE" ;;
  '-p '*' -o pgid=') printf '%s\n' "$T03_OUTER_GROUP" ;;
  '-p '*' -o pgid=,sid=') printf '%s %s\n' "$T03_OUTER_GROUP" "$T03_OUTER_SESSION" ;;
  *) exit 2 ;;
esac
BASH
    chmod -- 700 "$TEST_MOCK_BIN/$tool"
  done
}

_t03_reset_observations() {
  export T03_WORKER_PID=591003 T03_WORKER_GROUP=591002 T03_WORKER_SESSION=591001
  export T03_WORKER_START=440000001 T03_OUTER_GROUP=491002 T03_OUTER_SESSION=491001
  export T03_WORKER_STATUS=0 T03_KILL_STATUS=0
  export T03_WORKER_ROW='591003 591002 591001 440000001 T'
  export T03_WORKER_SECOND_ROW=
  : > "$T03_FIXTURE/process.log"
  : > "$T03_FIXTURE/events.log"
  : > "$T03_FIXTURE/stat.log"
  printf '0\n' > "$T03_FIXTURE/worker-count"
}

_t03_write_receipt() {
  printf 'zdx-session-probe-v1 %s %s %s %s\n' \
    "$T03_WORKER_PID" "$T03_WORKER_GROUP" "$T03_WORKER_SESSION" "$T03_WORKER_START" \
    > "$ZDX_TEST_SESSION_RECEIPT"
  chmod -- 600 "$ZDX_TEST_SESSION_RECEIPT"
  mkdir -m 700 "$ZDX_TEST_SESSION_RECEIPT.ready"
}

_t03_stat_boundary() {
  local pid="$1" count
  printf '%s\n' "$pid" >> "$T03_FIXTURE/stat.log"
  if [[ "$pid" != "$T03_WORKER_PID" ]]; then
    printf '%s %s %s 330000001 S\n' "$pid" "$T03_OUTER_GROUP" "$T03_OUTER_SESSION"
    return 0
  fi
  count=$(< "$T03_FIXTURE/worker-count")
  count=$((count + 1))
  printf '%s\n' "$count" > "$T03_FIXTURE/worker-count"
  printf 'stat %s %s\n' "$pid" "$count" >> "$T03_FIXTURE/events.log"
  [[ "$T03_WORKER_STATUS" -eq 0 ]] || return "$T03_WORKER_STATUS"
  if [[ "$count" -gt 1 && -n "$T03_WORKER_SECOND_ROW" ]]; then
    printf '%s\n' "$T03_WORKER_SECOND_ROW"
  else
    printf '%s\n' "$T03_WORKER_ROW"
  fi
}

_t03_cleanup_invoke() {
  # The actual coordinator is retained. Only discovery/signaling and its
  # narrow kernel-identity observation boundary are synthetic. No numeric PID
  # or PGID is ever forwarded to a real signaling primitive.
  # shellcheck disable=SC2329 # called indirectly by the extracted real body
  ps() { "$TEST_MOCK_BIN/ps" "$@"; }
  # shellcheck disable=SC2329 # called indirectly by the extracted real body
  kill() { "$TEST_MOCK_BIN/kill" "$@"; }
  readonly -f ps kill
  # shellcheck disable=SC1090 # generated from the reviewed definition section
  source "$T03_CLEANUP_SOURCE"
  # shellcheck disable=SC2329 # the real coordinator calls its kernel boundary
  _zdx_test_session_probe_stat() { _t03_stat_boundary "$@"; }
  # shellcheck disable=SC2329 # direct self-identity boundary, without host /proc
  _zdx_test_session_probe_self() { REPLY=491003; return 0; }
  _zdx_test_stop_session_probe
}

_t03_assert_no_global_discovery() {
  local line
  while IFS= read -r line; do
    [[ "$line" == ps* ]] || continue
    [[ "$line" =~ ^ps\ \<-p\>\ \<[1-9][0-9]*\>\ \<-o\>\ \<pgid=(,sid=)?\>$ ]] || return 1
  done < "$T03_FIXTURE/process.log"
}

_t03_assert_no_signal() {
  local log
  log=$(< "$T03_FIXTURE/process.log")
  [[ "$log" != *kill* ]]
}

@test "sandbox cleanup: an unconfigured probe does not discover or signal processes" {
  unset ZDX_TEST_SESSION_PROBE ZDX_TEST_SESSION_RECEIPT
  run _t03_cleanup_invoke
  [ "$status" -eq 0 ]
  [ ! -s "$T03_FIXTURE/process.log" ]
  [ ! -s "$T03_FIXTURE/stat.log" ]
}

@test "sandbox cleanup: a configured probe without a receipt fails closed" {
  run _t03_cleanup_invoke
  [ "$status" -eq 1 ]
  _t03_assert_no_global_discovery
  _t03_assert_no_signal
}

@test "sandbox cleanup: incomplete and malformed receipts never authorize a signal" {
  local row
  mkdir -m 700 "$ZDX_TEST_SESSION_RECEIPT.ready"
  for row in \
    '' \
    'zdx-session-probe-v1 591003 591002 591001' \
    'zdx-session-probe-v2 591003 591002 591001 440000001' \
    'zdx-session-probe-v1 0 591002 591001 440000001' \
    'zdx-session-probe-v1 591003 -1 591001 440000001' \
    'zdx-session-probe-v1 591003 591002 x 440000001' \
    'zdx-session-probe-v1 591003 591002 591001 0' \
    'zdx-session-probe-v1 591003 591002 591001 440000001 extra' \
    $'zdx-session-probe-v1 591003 591002 591001 440000001\nforeign'; do
    printf '%s\n' "$row" > "$ZDX_TEST_SESSION_RECEIPT"
    chmod -- 600 "$ZDX_TEST_SESSION_RECEIPT"
    _t03_reset_observations
    run _t03_cleanup_invoke
    [ "$status" -eq 1 ]
    _t03_assert_no_global_discovery
    _t03_assert_no_signal
  done
}

@test "sandbox cleanup: an uncommitted receipt is distinct from a proven gone worker" {
  printf 'zdx-session-probe-v1 591003 591002 591001 440000001\n' > "$ZDX_TEST_SESSION_RECEIPT"
  chmod -- 600 "$ZDX_TEST_SESSION_RECEIPT"
  export T03_WORKER_STATUS=1
  run _t03_cleanup_invoke
  [ "$status" -eq 1 ]
  _t03_assert_no_global_discovery
  _t03_assert_no_signal
}

@test "sandbox cleanup: a linked receipt cannot authorize a group and its target is unchanged" {
  _t03_write_receipt
  mv "$ZDX_TEST_SESSION_RECEIPT" "$T03_FIXTURE/target"
  local before
  before=$(< "$T03_FIXTURE/target")
  ln -s "$T03_FIXTURE/target" "$ZDX_TEST_SESSION_RECEIPT"
  run _t03_cleanup_invoke
  [ "$status" -eq 1 ]
  _t03_assert_no_global_discovery
  _t03_assert_no_signal
  [ "$(< "$T03_FIXTURE/target")" = "$before" ]
}

@test "sandbox cleanup: a hardlinked receipt fails closed without modifying either link" {
  _t03_write_receipt
  ln "$ZDX_TEST_SESSION_RECEIPT" "$T03_FIXTURE/second-link"
  local before
  before=$(< "$T03_FIXTURE/second-link")
  run _t03_cleanup_invoke
  [ "$status" -eq 1 ]
  _t03_assert_no_global_discovery
  _t03_assert_no_signal
  [ "$(< "$T03_FIXTURE/second-link")" = "$before" ]
  [ "$(< "$ZDX_TEST_SESSION_RECEIPT")" = "$before" ]
}

@test "sandbox cleanup: a nonprivate receipt fails closed" {
  _t03_write_receipt
  chmod -- 666 "$ZDX_TEST_SESSION_RECEIPT"
  run _t03_cleanup_invoke
  [ "$status" -eq 1 ]
  _t03_assert_no_global_discovery
  _t03_assert_no_signal
}

@test "sandbox cleanup: a receipt reached through a linked parent fails closed" {
  _t03_write_receipt
  ln -s "$T03_FIXTURE" "$TEST_TEMP_DIR/linked-receipt-parent"
  export ZDX_TEST_SESSION_RECEIPT="$TEST_TEMP_DIR/linked-receipt-parent/receipt"
  run _t03_cleanup_invoke
  [ "$status" -eq 1 ]
  _t03_assert_no_global_discovery
  _t03_assert_no_signal
}

@test "sandbox cleanup: the ready commit must be a real empty private directory" {
  local condition
  _t03_write_receipt
  for condition in nonempty nonprivate linked; do
    case "$condition" in
      nonempty) printf 'incomplete\n' > "$ZDX_TEST_SESSION_RECEIPT.ready/unexpected" ;;
      nonprivate) chmod -- 777 "$ZDX_TEST_SESSION_RECEIPT.ready" ;;
      linked)
        rmdir "$ZDX_TEST_SESSION_RECEIPT.ready"
        mkdir -m 700 "$T03_FIXTURE/foreign-ready"
        ln -s "$T03_FIXTURE/foreign-ready" "$ZDX_TEST_SESSION_RECEIPT.ready"
        ;;
    esac
    _t03_reset_observations
    run _t03_cleanup_invoke
    [ "$status" -eq 1 ]
    _t03_assert_no_global_discovery
    _t03_assert_no_signal
    case "$condition" in
      nonempty) rm -f -- "$ZDX_TEST_SESSION_RECEIPT.ready/unexpected" ;;
      nonprivate) chmod -- 700 "$ZDX_TEST_SESSION_RECEIPT.ready" ;;
    esac
  done
}

@test "sandbox cleanup: a committed matching stopped worker authorizes only its recorded group" {
  _t03_write_receipt
  # Transient STATE may change while the four receipt identity fields stay
  # fixed; the second observation proves that a stopped worker is still live.
  export T03_WORKER_ROW='591003 591002 591001 440000001 S'
  export T03_WORKER_SECOND_ROW='591003 591002 591001 440000001 T'
  run _t03_cleanup_invoke
  [ "$status" -eq 0 ]
  _t03_assert_no_global_discovery
  [ "$(< "$T03_FIXTURE/process.log")" = 'kill <-KILL> <--> <-591002>' ]
  [ "$(< "$T03_FIXTURE/events.log")" = $'stat 591003 1\nstat 591003 2\nkill <-KILL> <--> <-591002>' ]
  [ "$(< "$T03_FIXTURE/worker-count")" -eq 2 ]
}

@test "sandbox cleanup: a committed receipt with a proven gone or dead worker sends no signal" {
  local observation
  _t03_write_receipt
  for observation in absent Z X x; do
    _t03_reset_observations
    if [[ "$observation" == absent ]]; then
      export T03_WORKER_STATUS=1
    else
      export T03_WORKER_ROW="591003 591002 591001 440000001 $observation"
    fi
    run _t03_cleanup_invoke
    [ "$status" -eq 0 ]
    _t03_assert_no_global_discovery
    _t03_assert_no_signal
    [[ "$(< "$T03_FIXTURE/stat.log")" == *591003* ]]
  done
}

@test "sandbox cleanup: unreadable process identity cannot authorize a signal" {
  _t03_write_receipt
  export T03_WORKER_STATUS=2
  run _t03_cleanup_invoke
  [ "$status" -eq 1 ]
  _t03_assert_no_global_discovery
  _t03_assert_no_signal
}

@test "sandbox cleanup: PID group session and start identity must all match the receipt" {
  local row
  _t03_write_receipt
  for row in \
    '591004 591002 591001 440000001 S' \
    '591003 591004 591001 440000001 S' \
    '591003 591002 591004 440000001 S' \
    '591003 591002 591001 440000002 S'; do
    _t03_reset_observations
    export T03_WORKER_ROW="$row"
    run _t03_cleanup_invoke
    [ "$status" -eq 1 ]
    _t03_assert_no_global_discovery
    _t03_assert_no_signal
  done
}

@test "sandbox cleanup: identity changing on revalidation never reaches the signal boundary" {
  _t03_write_receipt
  export T03_WORKER_SECOND_ROW='591003 591002 591001 440000002 T'
  run _t03_cleanup_invoke
  [ "$status" -eq 1 ]
  _t03_assert_no_global_discovery
  _t03_assert_no_signal
  [ "$(< "$T03_FIXTURE/worker-count")" -eq 2 ]
}

@test "sandbox cleanup: outer groups and sessions are excluded even with matching receipts" {
  local relation
  for relation in group session group-one session-one group-is-outer-session; do
    case "$relation" in
      group) export T03_WORKER_GROUP="$T03_OUTER_GROUP" ;;
      session) export T03_WORKER_SESSION="$T03_OUTER_SESSION" ;;
      group-one) export T03_WORKER_GROUP=1 ;;
      session-one) export T03_WORKER_SESSION=1 ;;
      group-is-outer-session) export T03_WORKER_GROUP="$T03_OUTER_SESSION" ;;
    esac
    _t03_write_receipt
    export T03_WORKER_ROW="$T03_WORKER_PID $T03_WORKER_GROUP $T03_WORKER_SESSION $T03_WORKER_START T"
    run _t03_cleanup_invoke
    [ "$status" -eq 1 ]
    _t03_assert_no_global_discovery
    _t03_assert_no_signal
    rm -f -- "$ZDX_TEST_SESSION_RECEIPT"
    rmdir "$ZDX_TEST_SESSION_RECEIPT.ready"
    _t03_reset_observations
  done
}

@test "sandbox cleanup: a refused owned-group signal reports incomplete cleanup" {
  _t03_write_receipt
  export T03_KILL_STATUS=1
  run _t03_cleanup_invoke
  [ "$status" -eq 1 ]
  _t03_assert_no_global_discovery
  [ "$(< "$T03_FIXTURE/process.log")" = 'kill <-KILL> <--> <-591002>' ]
}
