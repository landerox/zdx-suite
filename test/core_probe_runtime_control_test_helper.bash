# Two finite F308 route/job-ownership controls. All executable fixtures and
# PTY files stay inside test_helper's private HOME/TMPDIR sandbox.
# Literal child Zsh programs are expanded only by their isolated interpreter.
# shellcheck disable=SC2016

f308r_setup() {
  export F308R_REAL_PYTHON F308R_REAL_ZSH
  F308R_REAL_PYTHON=$(type -P python3) || return 1
  F308R_REAL_ZSH=$(type -P zsh) || return 1
  local program
  for program in "$F308R_REAL_PYTHON" "$F308R_REAL_ZSH"; do
    [[ "$program" == /* && -f "$program" && -x "$program" ]] || return 1
  done
  make_core_probe_path || return 1
  printf '%s\n' 'Caller input remains unread by the version probe.' > "$HOME/runtime-control.stdin"
}

f308r_slow_pipx() {
  cat > "$HOME/runtime-pipx.py" <<'PY'
import json, pathlib, sys, time
home = pathlib.Path.home()
started = time.monotonic()
eof = sys.stdin.buffer.read(1) == b''
receipt = {'argv': sys.argv[1:], 'stdin_eof': eof,
           'started_monotonic': started, 'deadline_monotonic': started + 8.0}
(home / 'runtime-pipx-started.json').write_text(json.dumps(receipt) + '\n')
if not eof or len(sys.argv) != 3 or sys.argv[2] != '--version':
    raise SystemExit(98)
time.sleep(max(0.0, receipt['deadline_monotonic'] - time.monotonic()))
(home / 'runtime-pipx-completed').write_text('completed\n')
print('1.4.3')
PY
  core_probe_program pipx <<'MOCK'
exec "$F308R_REAL_PYTHON" -B -I "$HOME/runtime-pipx.py" "$0" "$@"
MOCK
  cat > "$HOME/observe-pipx-window.py" <<'PY'
import json, math, pathlib, sys, time
home = pathlib.Path.home()
receipt = json.loads((home / 'runtime-pipx-started.json').read_text())
assert receipt['argv'] == [sys.argv[1], '--version']
assert receipt['stdin_eof'] is True
started, deadline = receipt['started_monotonic'], receipt['deadline_monotonic']
assert math.isfinite(started) and math.isfinite(deadline) and deadline == started + 8.0
now = time.monotonic()
assert started <= now and deadline - now <= 8.0
limit = now + 10.0
while time.monotonic() < deadline + 0.2:
    assert time.monotonic() < limit
    time.sleep(min(0.05, max(0.0, deadline + 0.2 - time.monotonic())))
observed = time.monotonic()
(home / 'runtime-observation.json').write_text(json.dumps({'observed_monotonic': observed,
    'deadline_monotonic': deadline}) + '\n')
assert observed >= deadline + 0.2
assert not (home / 'runtime-pipx-completed').exists()
PY
}

f308r_spinner_worker() {
  cat > "$HOME/runtime spinner [owned].zsh" <<'ZSH'
emulate -R zsh
builtin source "$1/functions.zsh" || exit 90
unset NO_COLOR ZDX_FZF_PLAIN
TERM=xterm-256color
[[ -t 2 ]] || { print -r -- not-a-terminal > "$HOME/runtime-spinner-tty"; exit 91; }
print -r -- stderr=TTY > "$HOME/runtime-spinner-tty"
typeset -gi F308R_REAPED=0 F308R_WAIT_CALLS=0
# This signal boundary NEVER forwards any signal or existence query.
# Before wait, -0 ends the loop. After a real wait, a recycled-PID-shaped
# response exposes any forbidden post-reap existence query/TERM attempt.
kill() {
  printf '%s\0' "$@" >> "$HOME/runtime-spinner-kill.argv"
  if [[ "${1-}" == -0 ]]; then
    if (( F308R_REAPED )); then
      print -r -- post-reap-query > "$HOME/runtime-spinner-post-reap"
      return 0
    fi
    return 1
  fi
  print -r -- "${(j: :)@}" >> "$HOME/runtime-spinner-forbidden-signal"
  return 0
}
wait() {
  local -i actual_rc=0
  (( ++F308R_WAIT_CALLS ))
  builtin wait "$@" || actual_rc=$?
  F308R_REAPED=1
  print -r -- "$actual_rc" >> "$HOME/runtime-spinner-reaped"
  return $actual_rc
}
_f308r_spinner_child() {
  print -r -- started > "$HOME/runtime-spinner-child-started"
  return 23
}
local -i spinner_rc=0
_zdx_spinner Working _f308r_spinner_child || spinner_rc=$?
print -r -- "$spinner_rc" > "$HOME/runtime-spinner-result"
print -r -- "$F308R_WAIT_CALLS" > "$HOME/runtime-spinner-waits"
print -r -- complete > "$HOME/runtime-spinner-done"
exit 0
ZSH
}

# The controller owns one named zpty handle only. Polls are nonblocking and
# finite; deletion addresses that handle, never a PID read from an old log.
f308r_spinner_pty() {
  "$F308R_REAL_ZSH" -f -c '
    emulate -R zsh
    zmodload zsh/zpty || { print -u2 -r -- "zsh/zpty is required for the spinner control"; exit 80; }
    zmodload zsh/zselect || exit 81
    local transcript="" chunk="" hide=$'"'"'\e[?25l'"'"'
    local -i tick=0 complete=0
    # zpty joins argv for a second shell parse; quote each original operand.
    local -a worker_argv=("$F308R_REAL_ZSH" -f "$HOME/runtime spinner [owned].zsh" "$1")
    zpty -b F308SPINNER "${(@q)worker_argv}" || exit 82
    {
      while (( ++tick <= 2000 )); do
        if zpty -r -t F308SPINNER chunk 2>/dev/null; then transcript+="$chunk"; fi
        if [[ -f "$HOME/runtime-spinner-done" ]]; then complete=1; break; fi
        zselect -t 1 2>/dev/null || :
      done
      # Drain only available output, including the final cursor restoration.
      for tick in {1..32}; do
        zpty -r -t F308SPINNER chunk 2>/dev/null || break
        transcript+="$chunk"
      done
    } always {
      zpty -d F308SPINNER 2>/dev/null
    }
    print -rn -- "$transcript" > "$HOME/runtime-spinner-transcript"
    (( complete )) || { print -u2 -r -- "spinner PTY worker did not finish"; exit 83; }
    [[ "$transcript" == *"$hide"* && "$(<"$HOME/runtime-spinner-tty")" == stderr=TTY ]] || exit 84
    print -r -- drawing-branch-observed
  ' _ "$TEST_SUITE_ROOT" </dev/null
}
