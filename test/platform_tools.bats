#!/usr/bin/env bats
# shellcheck disable=SC2016
#
# External tools that differ between GNU/Linux and macOS: the core timeout
# service without GNU timeout, and BSD chmod argument parsing.

setup() {
  load test_helper
  mkdir -m 700 "$TEST_TEMP_DIR/runtime"
  PLATFORM_TMP=$(cd -P "$TEST_TEMP_DIR/runtime" && pwd -P)
  export PLATFORM_TMP
  export PLATFORM_CALLS="$TEST_TEMP_DIR/timeout-calls"
  : > "$PLATFORM_CALLS"

  # Hides GNU timeout and Homebrew gtimeout, as on a stock macOS host.
  export PLATFORM_NO_TIMEOUT="$TEST_TEMP_DIR/no-timeout.zsh"
  cat > "$PLATFORM_NO_TIMEOUT" <<'ZSH'
command() {
  if [[ "$1" == -v && ( "$2" == timeout || "$2" == gtimeout ) ]]; then
    return 1
  fi
  builtin command "$@"
}
ZSH
}

teardown() {
  cleanup_sandbox
}

_platform_timeout_recorder() {
  local name="$1"
  cat > "$TEST_MOCK_BIN/$name" <<SH
#!/usr/bin/env bash
printf '$name' >> "\$PLATFORM_CALLS"
printf ' %q' "\$@" >> "\$PLATFORM_CALLS"
printf '\n' >> "\$PLATFORM_CALLS"
[[ "\${1:-}" == -k && "\${2:-}" == 2s && "\${3:-}" == *s ]] || exit 98
shift 3
exec "\$@"
SH
  chmod +x "$TEST_MOCK_BIN/$name"
}

@test "platform tools: the timeout service validates arguments before running" {
  run run_zsh '
    export TMPDIR="$PLATFORM_TMP"
    local marker="$HOME/ran"
    _zdx_run_with_timeout x touch "$marker"; print -r -- "word=$?"
    _zdx_run_with_timeout 1234567 touch "$marker"; print -r -- "digits=$?"
    _zdx_run_with_timeout -1 touch "$marker"; print -r -- "negative=$?"
    _zdx_run_with_timeout 5; print -r -- "command=$?"
    _zdx_run_with_timeout; print -r -- "empty=$?"
    [[ ! -e "$marker" ]] && print -r -- "not-run"
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'word=2\ndigits=2\nnegative=2\ncommand=2\nempty=2\nnot-run' ]
}

@test "platform tools: timeout is preferred, then gtimeout, with a KILL grace" {
  _platform_timeout_recorder timeout
  _platform_timeout_recorder gtimeout

  run run_zsh '
    _zdx_run_with_timeout 7 printf "%s\n" first-ok || return 91
    command() {
      if [[ "$1" == -v && "$2" == timeout ]]; then
        return 1
      fi
      builtin command "$@"
    }
    _zdx_run_with_timeout 9 printf "%s\n" second-ok || return 92
    _zdx_run_with_timeout 0 printf "%s\n" unbounded-ok
  '

  [ "$status" -eq 0 ]
  [ "$output" = $'first-ok\nsecond-ok\nunbounded-ok' ]
  [ "$(cat "$PLATFORM_CALLS")" = \
    $'timeout -k 2s 7s printf %s\\\\n first-ok\ngtimeout -k 2s 9s printf %s\\\\n second-ok' ]
}

@test "platform tools: the Zsh watchdog bounds a command without timeout or gtimeout" {
  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    export TMPDIR="$PLATFORM_TMP"
    local -F started=$EPOCHREALTIME
    _zdx_run_with_timeout 1 sleep 20
    local -i timeout_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 8 )) || return 93
    _zdx_run_with_timeout 5 zsh -fc "exit 7"
    print -r -- "bounded=$timeout_rc passthrough=$?"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "bounded=124 passthrough=7" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: the watchdog stops descendants and keeps its marker private" {
  mkdir -m 700 "$TEST_TEMP_DIR/physical"
  ln -s "$TEST_TEMP_DIR/physical" "$TEST_TEMP_DIR/alias"
  mkdir -m 700 "$TEST_TEMP_DIR/physical/tmp"
  export PLATFORM_CANONICAL
  PLATFORM_CANONICAL=$(cd -P "$TEST_TEMP_DIR/physical/tmp" && pwd -P)

  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    export TMPDIR="$TEST_TEMP_DIR/alias/tmp"
    _zdx_run_with_timeout 1 zsh -fc "
      markers=(\"\$PLATFORM_CANONICAL\"/zdx-timeout.*(N))
      print -r -- \${#markers} > \"\$HOME/markers\"
      sleep 20 &
      print -r -- \$! > \"\$HOME/descendant.pid\"
      wait
    "
    local -i timeout_rc=$?
    local descendant_pid=""
    descendant_pid=$(<"$HOME/descendant.pid") || return 91
    if builtin kill -0 "$descendant_pid" 2>/dev/null; then
      builtin kill -KILL "$descendant_pid" 2>/dev/null
      return 92
    fi
    print -r -- "rc=$timeout_rc markers=$(<"$HOME/markers")"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 markers=1" ]
  [ -z "$(ls -A "$PLATFORM_CANONICAL")" ]
}

@test "platform tools: the watchdog refuses an unsafe TMPDIR without running the command" {
  mkdir -m 777 "$TEST_TEMP_DIR/shared"
  chmod 777 "$TEST_TEMP_DIR/shared"

  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    export TMPDIR="$TEST_TEMP_DIR/shared"
    _zdx_run_with_timeout 5 touch "$HOME/ran"
    print -r -- "rc=$?"
    [[ ! -e "$HOME/ran" ]] && print -r -- "not-run"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"TMPDIR must be an owner-private or root-owned sticky directory"* ]]
  [[ "$output" == *$'rc=1\nnot-run' ]]
  [ -z "$(ls -A "$TEST_TEMP_DIR/shared")" ]
}

@test "platform tools: the standalone System watchdog refuses an unsafe TMPDIR without running the command" {
  mkdir -m 777 "$TEST_TEMP_DIR/shared"
  chmod 777 "$TEST_TEMP_DIR/shared"

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    export TMPDIR="$3"
    _sys_run_with_timeout 5 touch "$HOME/ran"
    print -r -- "rc=$?"
    [[ ! -e "$HOME/ran" ]] && print -r -- "not-run"
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$TEST_TEMP_DIR/shared"

  [ "$status" -eq 0 ]
  [[ "$output" == *"TMPDIR must be an owner-private or root-owned sticky directory"* ]]
  [[ "$output" == *$'rc=1\nnot-run' ]]
  [ -z "$(ls -A "$TEST_TEMP_DIR/shared")" ]
}

@test "platform tools: System delegates to the core and keeps its standalone fallback" {
  run run_zsh '
    _zdx_run_with_timeout() {
      print -r -- "core:$*"
      return 42
    }
    _sys_run_with_timeout 3 printf ok
  '
  [ "$status" -eq 42 ]
  [ "$output" = "core:3 printf ok" ]

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    export TMPDIR="$3"
    _sys_run_with_timeout 1 sleep 20
    print -r -- "standalone=$?"
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$PLATFORM_TMP"
  [ "$status" -eq 0 ]
  [ "$output" = "standalone=124" ]
}

# Writes the helpers of the signal-pass tests. $PLATFORM_PASS_HELPERS defines
# _platform_preempted_pass, which stands in for a watchdog's tree signal: each
# PID gets its own kill, the root first, with a pause before each of the
# others ($PLATFORM_PASS_PAUSE centiseconds, 50 by default), and $HOME/passes
# records the pass. That models a watchdog preempted
# between its kill(2) calls, which under CPU load left a descendant running in
# 40 to 46 percent of timed-out runs: the command exits on its signal, and the
# caller stops the watchdog before the rest of the tree has it.
# Each tree records its descendant first, so a loaded host has the whole bound
# to start it; the descendant outlives the bound and the poll, and its streams
# never hold the BATS pipes open. In $PLATFORM_TERM_IGNORING_TREE the command
# and its descendant both ignore TERM, so only the KILL pass ends them. In
# $PLATFORM_THREE_LEVEL_TREE the command waits for a child that records the
# TERM it gets, and the child waits for a grandchild and then stays; each
# ends on its own only after 12 s.
_platform_pass_helpers() {
  export PLATFORM_PASS_HELPERS="$TEST_TEMP_DIR/pass-helpers.zsh"
  export PLATFORM_TREE="$TEST_TEMP_DIR/tree.zsh"
  export PLATFORM_TERM_IGNORING_TREE="$TEST_TEMP_DIR/term-ignoring-tree.zsh"
  export PLATFORM_THREE_LEVEL_TREE="$TEST_TEMP_DIR/three-level-tree.zsh"
  export PLATFORM_TRAPPING_CHILD="$TEST_TEMP_DIR/trapping-child.zsh"
  cat > "$PLATFORM_TREE" <<'ZSH'
sleep 60 </dev/null >/dev/null 2>&1 3>&- &
print -r -- $! > "$HOME/descendant.pid"
wait
ZSH
  cat > "$PLATFORM_TERM_IGNORING_TREE" <<'ZSH'
trap '' TERM
zsh -fc 'trap "" TERM; exec sleep 60' </dev/null >/dev/null 2>&1 3>&- &
print -r -- $! > "$HOME/descendant.pid"
wait
ZSH
  cat > "$PLATFORM_THREE_LEVEL_TREE" <<'ZSH'
zsh -f "$PLATFORM_TRAPPING_CHILD" </dev/null >/dev/null 2>&1 3>&- &
wait
ZSH
  cat > "$PLATFORM_TRAPPING_CHILD" <<'ZSH'
trap 'print -r -- TERM >| "$HOME/child.signal"; exit 143' TERM
print -r -- $$ > "$HOME/child.pid"
sleep 12 </dev/null >/dev/null 2>&1 3>&- &
print -r -- $! > "$HOME/grandchild.pid"
wait
# Stay for the TERM even when the grandchild got its own first.
zmodload zsh/zselect && zselect -t 1200
ZSH
  cat > "$PLATFORM_PASS_HELPERS" <<'ZSH'
# Usage: _platform_preempted_pass <tree-pids-function> <root-pid> <signal>
_platform_preempted_pass() {
  local tree_pids="$1" root_pid="${2-}" signal_name="${3-}" pid=""
  local -a reply=()
  print -r -- "$signal_name" >> "$HOME/passes"
  "$tree_pids" "$root_pid" || reply=("$root_pid")
  builtin kill "-$signal_name" "$root_pid" 2>/dev/null
  # Every word is split: this stand-in pins the pass order, and the
  # multi-process test covers the snapshot itself.
  for pid in ${=reply}; do
    [[ "$pid" == "$root_pid" ]] && continue
    zselect -t "${PLATFORM_PASS_PAUSE:-50}" 2>/dev/null
    builtin kill "-$signal_name" "$pid" 2>/dev/null
  done
  return 0
}

# Prints the bounded call's status, the fate of the descendant that the tree
# recorded, and the passes the watchdog began. A signaled process exits and is
# reaped asynchronously, so its exit is polled for up to 10 s; a survivor is
# killed and reported.
_platform_tree_outcome() {
  local -i timeout_rc="$1" attempt=0
  local descendant_pid="" fate="stopped" passes=""
  descendant_pid=$(<"$HOME/descendant.pid") || return 91
  [[ "$descendant_pid" == <-> ]] || return 91
  while builtin kill -0 "$descendant_pid" 2>/dev/null \
    && (( ++attempt <= 500 )); do
    zselect -t 2
  done
  if builtin kill -0 "$descendant_pid" 2>/dev/null; then
    builtin kill -KILL "$descendant_pid" 2>/dev/null
    fate="survived"
  fi
  [[ -f "$HOME/passes" ]] && passes=$(<"$HOME/passes")
  print -r -- "rc=$timeout_rc descendant=$fate passes=${passes//$'\n'/ }"
  [[ "$fate" == stopped ]] || return 92
}

# A DEBUG trap body: stalls the caller for <centiseconds> right before it
# KILLs the watchdog, that is, right after it decided the deadline had not
# passed, then records in $HOME/watchdog.state whether the watchdog is still
# there to receive that KILL. Usage:
#   trap "_platform_stall_before_watchdog_kill 350" DEBUG
_platform_stall_before_watchdog_kill() {
  [[ "$ZSH_DEBUG_CMD" == 'builtin kill -KILL "$watchdog_pid"'* ]] || return 0
  zselect -t "$1" 2>/dev/null
  if builtin kill -0 "$watchdog_pid" 2>/dev/null; then
    print -r -- alive >| "$HOME/watchdog.state"
  else
    print -r -- gone >| "$HOME/watchdog.state"
  fi
  return 0
}

zmodload zsh/zselect
ZSH
}

# The watchdog stops after the TERM pass that ended the command: no KILL pass.
@test "platform tools: a command that exits on TERM cannot cut the watchdog's pass short" {
  _platform_pass_helpers

  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    source "$PLATFORM_PASS_HELPERS" || return 90
    export TMPDIR="$PLATFORM_TMP"
    _zdx_timeout_signal_tree() {
      _platform_preempted_pass _zdx_timeout_tree_pids "$@"
    }
    _zdx_run_with_timeout 3 zsh -f "$PLATFORM_TREE"
    _platform_tree_outcome $?
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 descendant=stopped passes=TERM" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: a command that exits on KILL cannot cut the watchdog's escalation short" {
  _platform_pass_helpers

  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    source "$PLATFORM_PASS_HELPERS" || return 90
    export TMPDIR="$PLATFORM_TMP"
    _zdx_timeout_signal_tree() {
      _platform_preempted_pass _zdx_timeout_tree_pids "$@"
    }
    _zdx_run_with_timeout 3 zsh -f "$PLATFORM_TERM_IGNORING_TREE"
    _platform_tree_outcome $?
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 descendant=stopped passes=TERM KILL" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: a command that exits on TERM cannot cut the standalone System pass short" {
  _platform_pass_helpers

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    source "$3" || exit 92
    export TMPDIR="$4"
    _sys_timeout_signal_tree() {
      _platform_preempted_pass _sys_timeout_tree_pids "$@"
    }
    _sys_run_with_timeout 3 zsh -f "$PLATFORM_TREE"
    _platform_tree_outcome $?
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$PLATFORM_PASS_HELPERS" \
    "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 descendant=stopped passes=TERM" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: a command that exits on KILL cannot cut the standalone System escalation short" {
  _platform_pass_helpers

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    source "$3" || exit 92
    export TMPDIR="$4"
    _sys_timeout_signal_tree() {
      _platform_preempted_pass _sys_timeout_tree_pids "$@"
    }
    _sys_run_with_timeout 3 zsh -f "$PLATFORM_TERM_IGNORING_TREE"
    _platform_tree_outcome $?
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$PLATFORM_PASS_HELPERS" \
    "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 descendant=stopped passes=TERM KILL" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

# The real snapshot: a pass that named the tree as one word signaled nothing,
# so the call returned only when the whole tree ended on its own.
@test "platform tools: the standalone System watchdog signals every process of a tree" {
  _platform_pass_helpers

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    source "$3" || exit 92
    zmodload zsh/datetime || exit 92
    export TMPDIR="$4"
    local -F started=$EPOCHREALTIME
    _sys_run_with_timeout 3 zsh -f "$PLATFORM_THREE_LEVEL_TREE"
    local -i timeout_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 8 )) || { print -r -- "returned after ${elapsed}s (rc=$timeout_rc)"; exit 93; }
    local -i attempt=0
    while [[ ! -s "$HOME/child.signal" ]] && (( ++attempt <= 500 )); do
      zselect -t 2
    done
    if [[ ! -s "$HOME/child.signal" ]]; then
      builtin kill -KILL "$(<"$HOME/child.pid")" 2>/dev/null
      print -r -- "child got no TERM"
      exit 94
    fi
    local grandchild_pid=""
    grandchild_pid=$(<"$HOME/grandchild.pid") || exit 95
    [[ "$grandchild_pid" == <-> ]] || exit 95
    attempt=0
    while builtin kill -0 "$grandchild_pid" 2>/dev/null \
      && (( ++attempt <= 200 )); do
      zselect -t 2
    done
    if builtin kill -0 "$grandchild_pid" 2>/dev/null; then
      builtin kill -KILL "$grandchild_pid" 2>/dev/null
      print -r -- "grandchild got no TERM"
      exit 96
    fi
    print -r -- "rc=$timeout_rc child=$(<"$HOME/child.signal") grandchild=stopped"
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$PLATFORM_PASS_HELPERS" \
    "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 child=TERM grandchild=stopped" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

# A trapped signal ends the caller's wait while the command still runs, two
# seconds before the deadline. The caller then stalls right before it KILLs
# the watchdog, past the deadline, while the watchdog would fire and start a
# slow pass. The caller must not cut that pass: the watchdog stands down, the
# caller signals the tree itself, and the watchdog is still there for the
# caller's KILL, so that no released PID is ever signaled.
@test "platform tools: a caller stopped before the deadline cannot cut the watchdog's late pass" {
  _platform_pass_helpers

  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    source "$PLATFORM_PASS_HELPERS" || return 90
    export TMPDIR="$PLATFORM_TMP"
    _zdx_timeout_signal_tree() {
      _platform_preempted_pass _zdx_timeout_tree_pids "$@"
    }
    PLATFORM_PASS_PAUSE=300
    trap ":" USR1
    ( zselect -t 100; builtin kill -USR1 $$ ) </dev/null >/dev/null 2>&1 3>&- &
    trap "_platform_stall_before_watchdog_kill 350" DEBUG
    _zdx_run_with_timeout 3 zsh -f "$PLATFORM_TREE"
    local -i timeout_rc=$?
    trap - DEBUG
    print -r -n -- "watchdog=$(<"$HOME/watchdog.state") "
    _platform_tree_outcome $timeout_rc
  '

  [ "$status" -eq 0 ]
  [ "$output" = "watchdog=alive rc=$(( 128 + $(kill -l USR1) )) descendant=stopped passes=TERM" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: a caller stopped before the deadline cannot cut the standalone System late pass" {
  _platform_pass_helpers

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    source "$3" || exit 92
    export TMPDIR="$4"
    _sys_timeout_signal_tree() {
      _platform_preempted_pass _sys_timeout_tree_pids "$@"
    }
    PLATFORM_PASS_PAUSE=300
    trap ":" USR1
    ( zselect -t 100; builtin kill -USR1 $$ ) </dev/null >/dev/null 2>&1 3>&- &
    trap "_platform_stall_before_watchdog_kill 350" DEBUG
    _sys_run_with_timeout 3 zsh -f "$PLATFORM_TREE"
    local -i timeout_rc=$?
    trap - DEBUG
    print -r -n -- "watchdog=$(<"$HOME/watchdog.state") "
    _platform_tree_outcome $timeout_rc
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$PLATFORM_PASS_HELPERS" \
    "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "watchdog=alive rc=$(( 128 + $(kill -l USR1) )) descendant=stopped passes=TERM" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

# A ps that stalls for 20 s and records its PID. It closes descriptor 3 so
# that it cannot hold the BATS pipes open, and it execs sleep so that the
# recorded PID is the stalled process.
_platform_stalled_ps() {
  cat > "$TEST_MOCK_BIN/ps" <<'SH'
#!/bin/sh
exec 3>&- </dev/null
echo $$ > "$HOME/ps.pid"
exec sleep 20
SH
  chmod +x "$TEST_MOCK_BIN/ps"
}

# A stalled ps that also sends TERM to its parent, the watchdog, every 0.3 s
# for 8 s while that parent lives, then stalls like the other one.
_platform_storming_ps() {
  cat > "$TEST_MOCK_BIN/ps" <<'SH'
#!/bin/sh
exec 3>&- </dev/null
echo $$ > "$HOME/ps.pid"
parent=$PPID
i=0
while [ "$i" -lt 27 ] && kill -0 "$parent" 2>/dev/null; do
  kill -TERM "$parent" 2>/dev/null
  sleep 0.3
  i=$((i + 1))
done
exec sleep 20
SH
  chmod +x "$TEST_MOCK_BIN/ps"
}

# A ps that sends one TERM to its parent, the watchdog, as a stop request
# arriving mid-listing, then lists the real processes one second later.
_platform_slow_ps() {
  cat > "$TEST_MOCK_BIN/ps" <<'SH'
#!/bin/sh
exec 3>&- </dev/null
kill -TERM "$PPID" 2>/dev/null
sleep 1
for real_ps in /bin/ps /usr/bin/ps; do
  [ -x "$real_ps" ] && exec "$real_ps" "$@"
done
exit 1
SH
  chmod +x "$TEST_MOCK_BIN/ps"
}

# Hides timeout and gtimeout once, then removes itself, so that the watchdog
# runs `command ps` as a real shell would, with ps as its direct child.
_platform_one_shot_no_timeout() {
  export PLATFORM_ONE_SHOT_NO_TIMEOUT="$TEST_TEMP_DIR/one-shot-no-timeout.zsh"
  cat > "$PLATFORM_ONE_SHOT_NO_TIMEOUT" <<'ZSH'
command() {
  if [[ "$1" == -v && ( "$2" == timeout || "$2" == gtimeout ) ]]; then
    [[ "$2" == gtimeout ]] && unfunction command
    return 1
  fi
  builtin command "$@"
}
ZSH
}

# Exports PLATFORM_PS_FATE, a Zsh snippet that prints whether the recorded ps
# still runs a second after the call, then stops it. The watchdog must abandon
# a stalled listing without signaling a PID it no longer owns; a signaled ps
# is reaped well within that second.
_platform_ps_fate() {
  export PLATFORM_PS_FATE
  PLATFORM_PS_FATE=$(cat <<'ZSH'
local ps_pid="" ps_fate="gone"
zmodload zsh/zselect && zselect -t 100
ps_pid=$(<"$HOME/ps.pid") 2>/dev/null
if [[ "$ps_pid" == <-> ]] && builtin kill -0 "$ps_pid" 2>/dev/null; then
  ps_fate="alive"
  builtin kill -KILL "$ps_pid" 2>/dev/null
fi
print -r -- "rc=$timeout_rc ps=$ps_fate"
ZSH
  )
}

# The watchdog fires and its process listing stalls; the command then ends on
# its own. The caller waits for the watchdog's pass, which must give up on
# the listing within a small fixed bound instead of holding the caller.
@test "platform tools: a stalled process listing cannot hold the caller of a fired watchdog" {
  _platform_stalled_ps
  _platform_ps_fate

  _platform_one_shot_no_timeout

  run run_zsh '
    source "$PLATFORM_ONE_SHOT_NO_TIMEOUT" || return 90
    export TMPDIR="$PLATFORM_TMP"
    local -F started=$EPOCHREALTIME
    _zdx_run_with_timeout 1 zsh -fc "sleep 2"
    local -i timeout_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 8 )) || { print -r -- "returned after ${elapsed}s (rc=$timeout_rc)"; return 93; }
    eval "$PLATFORM_PS_FATE"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 ps=alive" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: a stalled process listing cannot hold the caller of the standalone System watchdog" {
  _platform_stalled_ps
  _platform_ps_fate

  _platform_one_shot_no_timeout

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    zmodload zsh/datetime || exit 92
    export TMPDIR="$3"
    local -F started=$EPOCHREALTIME
    _sys_run_with_timeout 1 zsh -fc "sleep 2"
    local -i timeout_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 8 )) || { print -r -- "returned after ${elapsed}s (rc=$timeout_rc)"; exit 93; }
    eval "$PLATFORM_PS_FATE"
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_ONE_SHOT_NO_TIMEOUT" "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 ps=alive" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

# A TRAPTERM function survives into Zsh subshells. A watchdog that inherited
# one ignored the caller's stop request, kept its caller until the deadline
# and then signaled the finished command's PID.
@test "platform tools: a caller's TRAPTERM cannot hold the watchdog past a finished command" {
  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    export TMPDIR="$PLATFORM_TMP"
    TRAPTERM() { return 0; }
    local -F started=$EPOCHREALTIME
    _zdx_run_with_timeout 6 zsh -fc "exit 7"
    local -i command_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 3 )) || { print -r -- "returned after ${elapsed}s"; return 93; }
    print -r -- "rc=$command_rc"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=7" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

# The stalled listing receives a TERM every 0.3 s for 8 s, as the held pass
# of a fired watchdog would from repeated stop requests. Each signal must not
# restart the listing's wait: its two-second bound is absolute.
@test "platform tools: repeated stop requests cannot stretch the watchdog's process listing" {
  _platform_storming_ps
  _platform_ps_fate

  _platform_one_shot_no_timeout

  run run_zsh '
    source "$PLATFORM_ONE_SHOT_NO_TIMEOUT" || return 90
    export TMPDIR="$PLATFORM_TMP"
    local -F started=$EPOCHREALTIME
    _zdx_run_with_timeout 1 zsh -fc "sleep 2"
    local -i timeout_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 7 )) || { print -r -- "returned after ${elapsed}s (rc=$timeout_rc)"; return 93; }
    eval "$PLATFORM_PS_FATE"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 ps=alive" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: repeated stop requests cannot stretch the standalone System listing" {
  _platform_storming_ps
  _platform_ps_fate

  _platform_one_shot_no_timeout

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    zmodload zsh/datetime || exit 92
    export TMPDIR="$3"
    local -F started=$EPOCHREALTIME
    _sys_run_with_timeout 1 zsh -fc "sleep 2"
    local -i timeout_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 7 )) || { print -r -- "returned after ${elapsed}s (rc=$timeout_rc)"; exit 93; }
    eval "$PLATFORM_PS_FATE"
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_ONE_SHOT_NO_TIMEOUT" "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 ps=alive" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

# A stop request that reaches the watchdog while its listing is still being
# written must not cut the listing short: the pass waits for the complete
# listing, within its bound, and signals the whole tree.
@test "platform tools: a stop request during the listing cannot cut the watchdog's pass short" {
  _platform_pass_helpers
  _platform_slow_ps
  _platform_one_shot_no_timeout

  run run_zsh '
    source "$PLATFORM_ONE_SHOT_NO_TIMEOUT" || return 90
    source "$PLATFORM_PASS_HELPERS" || return 90
    export TMPDIR="$PLATFORM_TMP"
    _zdx_run_with_timeout 3 zsh -f "$PLATFORM_TREE"
    _platform_tree_outcome $?
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 descendant=stopped passes=" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: a stop request during the listing cannot cut the standalone System pass short" {
  _platform_pass_helpers
  _platform_slow_ps
  _platform_one_shot_no_timeout

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    source "$3" || exit 92
    export TMPDIR="$4"
    _sys_run_with_timeout 3 zsh -f "$PLATFORM_TREE"
    _platform_tree_outcome $?
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_ONE_SHOT_NO_TIMEOUT" "$PLATFORM_PASS_HELPERS" \
    "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 descendant=stopped passes=" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

# The caller dies while the watchdog's first command is stalled, so the
# watchdog starts out orphaned. It must still fire, signal the command's tree,
# and exit within 20 s, instead of waiting forever on whatever process adopted
# it.
_platform_orphaned_watchdog_program() {
  export PLATFORM_ORPHAN_PROGRAM
  PLATFORM_ORPHAN_PROGRAM=$(cat <<'ZSH'
zmodload zsh/system zsh/zselect || exit 93
(
  # A resident DEBUG trap would slow every later command of the watchdog,
  # so it removes itself once it has stalled the watchdog.
  TRAPDEBUG() {
    [[ "$ZSH_DEBUG_CMD" == "local -i in_pass=0 stop_requested=0"* ]] || return 0
    unfunction TRAPDEBUG
    print -r -- "${sysparams[pid]}" >| "$HOME/watchdog.pid"
    zselect -t 100 2>/dev/null
    return 0
  }
  print -r -- "${sysparams[pid]}" >| "$HOME/caller.pid"
  "$PLATFORM_BOUNDED" 2 zsh -fc "sleep 30 </dev/null >/dev/null 2>&1 3>&- & wait"
) </dev/null >/dev/null 2>&1 3>&- &
local -i attempt=0
while [[ ! -s "$HOME/watchdog.pid" ]] && (( ++attempt <= 500 )); do zselect -t 2; done
builtin kill -KILL "$(<"$HOME/caller.pid")" 2>/dev/null || exit 94
local watchdog_pid=""
watchdog_pid=$(<"$HOME/watchdog.pid") || exit 95
[[ "$watchdog_pid" == <-> ]] || exit 95
attempt=0
while builtin kill -0 "$watchdog_pid" 2>/dev/null && (( ++attempt <= 1000 )); do
  zselect -t 2
done
if builtin kill -0 "$watchdog_pid" 2>/dev/null; then
  builtin kill -KILL "$watchdog_pid" 2>/dev/null
  print -r -- "watchdog still waits 20 s after its caller died"
  exit 92
fi
print -r -- "watchdog=gone"
ZSH
  )
}

@test "platform tools: a watchdog whose caller died first does not wait forever" {
  _platform_orphaned_watchdog_program

  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    export TMPDIR="$PLATFORM_TMP"
    PLATFORM_BOUNDED=_zdx_run_with_timeout
    eval "$PLATFORM_ORPHAN_PROGRAM"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "watchdog=gone" ]
}

@test "platform tools: a standalone System watchdog whose caller died first does not wait forever" {
  _platform_orphaned_watchdog_program

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    export TMPDIR="$3"
    PLATFORM_BOUNDED=_sys_run_with_timeout
    eval "$PLATFORM_ORPHAN_PROGRAM"
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "watchdog=gone" ]
}

# A fired watchdog replaces the caller's TRAPTERM before its pass, so the
# caller's stop takes effect once the pass ends: no grace and no KILL pass.
@test "platform tools: a caller's TRAPTERM cannot hold a fired watchdog either" {
  _platform_pass_helpers

  run run_zsh '
    source "$PLATFORM_NO_TIMEOUT" || return 90
    source "$PLATFORM_PASS_HELPERS" || return 90
    export TMPDIR="$PLATFORM_TMP"
    _zdx_timeout_signal_tree() {
      _platform_preempted_pass _zdx_timeout_tree_pids "$@"
    }
    PLATFORM_PASS_PAUSE=10
    TRAPTERM() { return 0; }
    local -F started=$EPOCHREALTIME
    _zdx_run_with_timeout 3 zsh -f "$PLATFORM_TREE"
    local -i timeout_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 8 )) || { print -r -- "returned after ${elapsed}s"; return 93; }
    _platform_tree_outcome $timeout_rc
  '

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 descendant=stopped passes=TERM" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: a caller's TRAPTERM cannot hold a fired standalone System watchdog" {
  _platform_pass_helpers

  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    source "$3" || exit 92
    zmodload zsh/datetime || exit 92
    export TMPDIR="$4"
    _sys_timeout_signal_tree() {
      _platform_preempted_pass _sys_timeout_tree_pids "$@"
    }
    PLATFORM_PASS_PAUSE=10
    TRAPTERM() { return 0; }
    local -F started=$EPOCHREALTIME
    _sys_run_with_timeout 3 zsh -f "$PLATFORM_TREE"
    local -i timeout_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 8 )) || { print -r -- "returned after ${elapsed}s"; exit 93; }
    _platform_tree_outcome $timeout_rc
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$PLATFORM_PASS_HELPERS" \
    "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "rc=124 descendant=stopped passes=TERM" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: a caller's TRAPTERM cannot hold the standalone System watchdog" {
  run zsh -f -c '
    source "$1/functions/sys-menu.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    source "$2" || exit 92
    zmodload zsh/datetime || exit 92
    export TMPDIR="$3"
    TRAPTERM() { return 0; }
    local -F started=$EPOCHREALTIME
    _sys_run_with_timeout 6 zsh -fc "exit 7"
    local -i command_rc=$?
    local -F elapsed=$(( EPOCHREALTIME - started ))
    (( elapsed < 3 )) || { print -r -- "returned after ${elapsed}s"; exit 93; }
    print -r -- "rc=$command_rc"
  ' _ "$TEST_SUITE_ROOT" "$PLATFORM_NO_TIMEOUT" "$PLATFORM_TMP"

  [ "$status" -eq 0 ]
  [ "$output" = "rc=7" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: Git delegates to the core and bounds its standalone fallback" {
  run run_zsh '
    _zdx_run_with_timeout() {
      print -r -- "core:$*"
      return 42
    }
    _git_run_with_timeout 3 printf ok
  '
  [ "$status" -eq 42 ]
  [[ "$output" == core:3\ /*/printf\ ok ]]

  # A host without timeout or gtimeout, such as the macOS runner, fails
  # closed instead; the next test covers that message.
  local bounded=124
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
    || bounded=1
  run zsh -f -c '
    source "$1/functions/git-common.zsh" || exit 90
    (( ! ${+functions[_zdx_run_with_timeout]} )) || exit 91
    _git_run_with_timeout 1 sleep 20 2>/dev/null
    print -r -- "standalone=$?"
    _git_run_with_timeout 0 printf ok; print -r -- "zero=$?"
    _git_run_with_timeout 601 printf ok; print -r -- "large=$?"
    _git_run_with_timeout 5; print -r -- "program=$?"
    _git_run_with_timeout 5 zdx-no-such-program; print -r -- "missing=$?"
  ' _ "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "standalone=$bounded"$'\nzero=2\nlarge=2\nprogram=2\nmissing=127' ]
}

@test "platform tools: standalone Git fails closed without timeout or gtimeout" {
  local bin="$TEST_TEMP_DIR/no-timeout-bin"
  mkdir -p "$bin"
  ln -s "$(command -v touch)" "$bin/touch"
  run env PATH="$bin" "$(command -v zsh)" -f -c '
    source "$1/functions/git-common.zsh" || exit 90
    _git_run_with_timeout 5 touch "$2"
    print -r -- "rc=$?"
  ' _ "$TEST_SUITE_ROOT" "$TEST_TEMP_DIR/ran"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bounded Git commands need timeout or gtimeout"* ]]
  [[ "$output" == *"rc=1" ]]
  [ ! -e "$TEST_TEMP_DIR/ran" ]
}

# BSD chmod parses options with getopt(3), which stops at the first operand:
# in `chmod 700 -- path` the `--` becomes a file operand and chmod exits 1.
# This shim reproduces that on Linux so the argument order cannot regress.
_platform_bsd_chmod() {
  local real_chmod
  real_chmod=$(command -v chmod)
  mkdir -p "$TEST_TEMP_DIR/bsd-bin"
  cat > "$TEST_TEMP_DIR/bsd-bin/chmod" <<SH
#!/usr/bin/env bash
operand_seen=0
for argument in "\$@"; do
  if (( operand_seen )) && [[ "\$argument" == -- ]]; then
    printf 'chmod: --: No such file or directory\n' >&2
    exit 1
  fi
  case "\$argument" in
    --) break ;;
    -*) ;;
    *) operand_seen=1 ;;
  esac
done
exec '$real_chmod' "\$@"
SH
  chmod +x "$TEST_TEMP_DIR/bsd-bin/chmod"
  export PATH="$TEST_TEMP_DIR/bsd-bin:$PATH"
}

@test "platform tools: private modes are applied with BSD chmod argument parsing" {
  _platform_bsd_chmod
  export MOCK_FZF_MODE=response
  export MOCK_FZF_RESPONSE=picked

  run run_zsh '
    export TMPDIR="$PLATFORM_TMP"
    local probe="$HOME/order-probe"
    command mkdir -p "$probe" || return 90
    command chmod 700 -- "$probe" 2>/dev/null && return 91
    command chmod -- 700 "$probe" || return 92

    local created=""
    created=$(_vpn_make_private_temp_dir zdx-vpn-chmod) || return 93
    command rmdir -- "$created" || return 94

    local capture="" REPLY=""
    for capture in _py_fzf_capture _file_fzf_capture; do
      REPLY=""
      "$capture" </dev/null >/dev/null || return 95
      [[ "$REPLY" == picked ]] || return 96
    done

    local -a reply=()
    _dev_update_workspace_create || return 97
    _dev_update_workspace_cleanup "${reply[@]}" || return 98
    print -r -- "private modes applied"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "private modes applied" ]
  [ -z "$(ls -A "$PLATFORM_TMP")" ]
}

@test "platform tools: product code never places the option terminator after a mode" {
  run grep -rnE \
    'chmod[[:space:]]+[^-[:space:]][^[:space:]]*[[:space:]]+--([[:space:]]|$)' \
    "$TEST_SUITE_ROOT/functions" "$TEST_SUITE_ROOT/functions.zsh" \
    "$TEST_SUITE_ROOT/completions" "$TEST_SUITE_ROOT/scripts"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "platform tools: product code loads only zstat from zsh/stat" {
  # A full zsh/stat load adds a stat builtin that shadows the external stat
  # command in the user's interactive shell for the rest of the session.
  local offenders=""
  offenders=$(grep -rnIE 'zmodload[^#]*zsh/stat' \
    "$TEST_SUITE_ROOT/functions" "$TEST_SUITE_ROOT/functions.zsh" \
    "$TEST_SUITE_ROOT/completions" "$TEST_SUITE_ROOT/scripts" \
    "$TEST_SUITE_ROOT/.demo" | grep -v -- '-F zsh/stat b:zstat' || true)
  [ -z "$offenders" ]
}

@test "platform tools: suite helpers keep the external stat command" {
  run run_zsh '
    local suite=""
    for suite in git dev file env py sys vpn ws; do
      source "$ZSH_CUSTOM/functions/$suite-menu.zsh" || exit 1
    done
    # Each helper loads zstat; their verdicts do not matter here.
    _zdx_resolve_trusted_dir "$TMPDIR" >/dev/null 2>&1
    _git_temp_parent_safe >/dev/null 2>&1
    _dev_temp_parent_safe >/dev/null 2>&1
    _sys_temp_parent_safe >/dev/null 2>&1
    _file_validate_temp_parent "$TMPDIR" >/dev/null 2>&1
    _env_validate_temp_parent "$TMPDIR" >/dev/null 2>&1
    _py_validate_temp_parent "$TMPDIR" >/dev/null 2>&1
    _ws_validate_temp_parent "$TMPDIR" >/dev/null 2>&1
    (( ${+builtins[zstat]} )) || exit 4
    (( ! ${+builtins[stat]} )) || exit 5
    print -r -- "$(whence -w stat)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *": builtin"* ]]
}

@test "platform tools: the plugin entrypoint keeps the external stat command" {
  run zsh -fc '
    source "$1/zdx-suite.plugin.zsh" >/dev/null 2>&1 || exit 3
    (( ${+builtins[zstat]} )) || exit 4
    (( ! ${+builtins[stat]} )) || exit 5
    print -r -- "$(whence -w stat)"
  ' zsh "$TEST_SUITE_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *": builtin"* ]]
}
