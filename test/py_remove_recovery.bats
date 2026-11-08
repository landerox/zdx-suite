#!/usr/bin/env bats

setup() {
  load test_helper
  export PY_REMOVE_REAL_MV PY_REMOVE_REAL_RM PY_REMOVE_REAL_RMDIR
  export PY_REMOVE_REAL_PYTHON PY_REMOVE_REAL_ZSH
  PY_REMOVE_REAL_MV=$(type -P mv)
  PY_REMOVE_REAL_RM=$(type -P rm)
  PY_REMOVE_REAL_RMDIR=$(type -P rmdir)
  PY_REMOVE_REAL_PYTHON=$(type -P python3)
  PY_REMOVE_REAL_ZSH=$(type -P zsh)
  export PY_REMOVE_PROJECT="$HOME/project"
  export PY_REMOVE_BIN="$HOME/removal-bin"
  export PY_REMOVE_SETUP="$HOME/removal-setup.zsh"
  mkdir -m 700 "$PY_REMOVE_PROJECT" "$PY_REMOVE_BIN"
  mkdir -p "$PY_REMOVE_PROJECT/.venv/lib" "$HOME/unrelated"
  printf 'version = 3.12.1\n' > "$PY_REMOVE_PROJECT/.venv/pyvenv.cfg"
  printf 'retained payload\n' > "$PY_REMOVE_PROJECT/.venv/lib/payload"
  printf 'unrelated environment\n' > "$HOME/unrelated/canary"
  export PY_REMOVE_MODE=fail PY_REMOVE_STATUS=130
  local tool
  for tool in mv rm rmdir; do
    printf '#!%s -f\n' "$PY_REMOVE_REAL_ZSH" > "$PY_REMOVE_BIN/$tool"
    cat >> "$PY_REMOVE_BIN/$tool" <<'MOCK'
emulate -R zsh
[[ "$HOME" == "$TEST_TEMP_DIR/home" && "$PY_REMOVE_PROJECT" == "$HOME/project" ]] || exit 97
local tool="${0:t}" target="" quarantine=""
if [[ "$tool" == mv ]]; then
  (( $# == 3 )) && [[ "$1" == -- && "$2" == "$PY_REMOVE_PROJECT/.venv" ]] || exit 97
  target="$3"
else
  if [[ "$tool" == rm ]]; then
    (( $# == 3 )) && [[ "$1" == -rf && "$2" == -- ]] || exit 97
    target="$3"
  else
    (( $# == 2 )) && [[ "$1" == -- ]] || exit 97
    quarantine="$2"
  fi
fi
[[ -n "$quarantine" ]] || quarantine="${target:h}"
[[ "${quarantine:h}" == "$PY_REMOVE_PROJECT" \
  && "${quarantine:t}" == .zdx-py-quarantine.* \
  && "$quarantine" == "${quarantine:A}" \
  && -d "$quarantine" && ! -L "$quarantine" ]] || exit 97
[[ -z "$target" || "$target" == "$quarantine/environment" ]] || exit 97
zmodload -F zsh/stat b:zstat || exit 97
local -A state=()
zstat -LH state -- "$quarantine" || exit 97
(( state[uid] == EUID && (state[mode] & 8#77) == 0 )) || exit 97
print -r -- "$tool:$target:$quarantine" >> "$HOME/removal-calls"
case "$tool" in
  mv)
    [[ "$PY_REMOVE_MODE" != move-before ]] || exit "$PY_REMOVE_STATUS"
    [[ ! -e "$target" && ! -L "$target" && -d "$2" && ! -L "$2" \
      && "$2" == "${2:A}" ]] || exit 97
    "$PY_REMOVE_REAL_MV" -- "$2" "$3" || exit $?
    print -r -- "$target" > "$HOME/retained-path"
    [[ "$PY_REMOVE_MODE" != move-after ]] || exit "$PY_REMOVE_STATUS"
    ;;
  rm)
    [[ -d "$target" && ! -L "$target" && "$target" == "${target:A}" ]] || exit 97
    case "$PY_REMOVE_MODE" in
      success|empty-parent-failure|delete-after)
        "$PY_REMOVE_REAL_RM" -rf -- "$target" || exit $?
        [[ "$PY_REMOVE_MODE" != delete-after ]] || exit "$PY_REMOVE_STATUS" ;;
      partial)
        local payload_parent="$target/lib"
        [[ -d "$payload_parent" && ! -L "$payload_parent" \
          && "$payload_parent" == "${payload_parent:A}" ]] || exit 97
        "$PY_REMOVE_REAL_RM" -f -- "$target/lib/payload" || exit $?
        exit "$PY_REMOVE_STATUS" ;;
      partial-config)
        "$PY_REMOVE_REAL_RM" -f -- "$target/pyvenv.cfg" || exit $?
        exit "$PY_REMOVE_STATUS" ;;
      incomplete-success) exit 0 ;;
      terminal)
        print -u2 -r -- ZDX_REMOVE_READY
        local ignored
        IFS= read -r -t 8 ignored
        exit 130 ;;
      *) exit "$PY_REMOVE_STATUS" ;;
    esac
    ;;
  rmdir)
    [[ "$PY_REMOVE_MODE" != empty-parent-failure ]] || exit "$PY_REMOVE_STATUS"
    "$PY_REMOVE_REAL_RMDIR" -- "$quarantine"
    ;;
esac
MOCK
    chmod -- 700 "$PY_REMOVE_BIN/$tool"
  done
  cat > "$PY_REMOVE_SETUP" <<'ZSH'
emulate -R zsh
export ZSH_CUSTOM="$TEST_SUITE_ROOT"
source "$TEST_SUITE_ROOT/functions.zsh" || return $?
source "$TEST_SUITE_ROOT/functions/py-menu.zsh" || return $?
export PATH="$PY_REMOVE_BIN:$PATH"
_py_assert_no_mounts_under() {
  print -r -- "$1" >> "$HOME/mount-checks"
  if [[ "$1" == */environment && "${PY_REMOVE_MODE:-}" == mount-failure ]]; then
    return "${PY_REMOVE_STATUS:-1}"
  fi
  if [[ "$1" == */environment && "${PY_REMOVE_MODE:-}" == unsafe-retained ]]; then
    command chmod -- 777 "$1" || return 1
  fi
  return 0
}
cd -q -- "$PY_REMOVE_PROJECT" || return 1
ZSH
  cat > "$HOME/remove-pty.py" <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import time

# Own exactly the child returned by forkpty. Ctrl-C goes only to its private
# terminal; fallback signals address that still-unreaped child, never a group.
pid, terminal = pty.fork()
if pid == 0:
    program = ('emulate -R zsh; source "$PY_REMOVE_SETUP" || exit $?; '
               'venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes')
    os.execv(os.environ['PY_REMOVE_REAL_ZSH'],
             [os.environ['PY_REMOVE_REAL_ZSH'], '-f', '-i', '-c', program])
output = bytearray()
status = None
sent = False
deadline = time.monotonic() + 12
try:
    while time.monotonic() < deadline:
        if select.select([terminal], [], [], 0.05)[0]:
            try:
                data = os.read(terminal, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b''
            output.extend(data)
            if len(output) > 1024 * 1024:
                raise RuntimeError('private terminal output exceeded its limit')
            if not sent and b'ZDX_REMOVE_READY' in output:
                os.write(terminal, b'\x03')
                sent = True
            if not data:
                break
        found, child_status = os.waitpid(pid, os.WNOHANG)
        if found:
            status = child_status
            # Drain queued output after the tracked child exits.
            while select.select([terminal], [], [], 0.05)[0]:
                try:
                    data = os.read(terminal, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not data:
                    break
                output.extend(data)
            break
finally:
    if status is None:
        found, child_status = os.waitpid(pid, os.WNOHANG)
        if found:
            status = child_status
        else:
            # This PID is still our own unreaped forkpty child.
            os.kill(pid, signal.SIGTERM)
            limit = time.monotonic() + 2
            while time.monotonic() < limit:
                found, child_status = os.waitpid(pid, os.WNOHANG)
                if found:
                    status = child_status
                    break
                time.sleep(0.02)
            if status is None:
                os.kill(pid, signal.SIGKILL)
                _, status = os.waitpid(pid, 0)
    os.close(terminal)
sys.stdout.write(output.decode('utf-8', 'replace').replace('\r', ''))
code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
print('PTY_CTRL_C_SENT:' + str(sent))
print('PTY_CHILD_STATUS:' + str(code))
if not sent:
    raise SystemExit(97)
raise SystemExit(code if code >= 0 else 128 - code)
PY
}

teardown() {
  cleanup_sandbox
}

assert_retained_environment() {
  local retained
  printf '%s\n' "$output"
  retained=$(cat "$HOME/retained-path")
  [ -d "$retained" ]
  [ -f "$retained/pyvenv.cfg" ]
  [ ! -e "$PY_REMOVE_PROJECT/.venv" ]
  [ "$(cat "$HOME/unrelated/canary")" = 'unrelated environment' ]
  [[ "$output" == *"$retained"* ]]
  [[ "$output" != *'Removed '* ]]
}

@test "py remove recovery: real private-terminal Ctrl-C reports the retained environment" {
  export PY_REMOVE_MODE=terminal
  run -130 "$PY_REMOVE_REAL_PYTHON" -B -I -S "$HOME/remove-pty.py"
  [[ "$output" == *'PTY_CTRL_C_SENT:True'* ]]
  [[ "$output" == *'PTY_CHILD_STATUS:130'* ]]
  assert_retained_environment
  [[ "$output" == *"move it back to $PY_REMOVE_PROJECT/.venv only while the target remains absent"* ]]
  [ -f "$(cat "$HOME/retained-path")/lib/payload" ]
}

@test "py remove recovery: completed rename returning 130 reports its recovery path" {
  export PY_REMOVE_MODE=move-after PY_REMOVE_STATUS=130
  run -130 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  assert_retained_environment
}

@test "py remove recovery: completed rename returning 143 reports its recovery path" {
  export PY_REMOVE_MODE=move-after PY_REMOVE_STATUS=143
  run -143 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  assert_retained_environment
}

@test "py remove recovery: returned deletion interruption reports an inspectable retained copy" {
  export PY_REMOVE_MODE=fail PY_REMOVE_STATUS=143
  run -143 run_zsh '
    source "$PY_REMOVE_SETUP" || return $?
    venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes > "$HOME/remove.stdout" 2> "$HOME/remove.stderr"
    local -i remove_rc=$?
    command cat -- "$HOME/remove.stderr" >&2
    return "$remove_rc"
  '
  assert_retained_environment
  [ ! -s "$HOME/remove.stdout" ]
}

@test "py remove recovery: ordinary partial deletion reports remaining data without success" {
  export PY_REMOVE_MODE=partial PY_REMOVE_STATUS=7
  run -7 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  assert_retained_environment
  [ ! -e "$(cat "$HOME/retained-path")/lib/payload" ]
}

@test "py remove recovery: an interrupted post-rename mount check retains status and recovery" {
  export PY_REMOVE_MODE=mount-failure PY_REMOVE_STATUS=130
  run -130 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  assert_retained_environment
  [[ "$(cat "$HOME/removal-calls")" != *'rm:'* ]]
}

@test "py remove recovery: successful deletion removes only the reviewed fixture" {
  export PY_REMOVE_MODE=success
  run -0 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  [ ! -e "$PY_REMOVE_PROJECT/.venv" ]
  [ -z "$(find "$PY_REMOVE_PROJECT" -name '.zdx-py-quarantine.*' -print -quit)" ]
  [ "$(cat "$HOME/unrelated/canary")" = 'unrelated environment' ]
  [[ "$output" == *'Removed '* ]]
  [[ "$output" != *'Recovery path retained'* ]]
}

@test "py remove recovery: passive dry run never creates or mutates a quarantine" {
  run -0 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --dry-run'
  [ -f "$PY_REMOVE_PROJECT/.venv/lib/payload" ]
  [ ! -e "$HOME/removal-calls" ]
}

@test "py remove recovery: rename refusal leaves the original and no phantom recovery path" {
  export PY_REMOVE_MODE=move-before PY_REMOVE_STATUS=130
  run -130 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  [ -f "$PY_REMOVE_PROJECT/.venv/lib/payload" ]
  [ -z "$(find "$PY_REMOVE_PROJECT" -name '.zdx-py-quarantine.*' -print -quit)" ]
  [[ "$output" != *'Recovery path retained:'* ]]
}

@test "py remove recovery: missing metadata after partial deletion still reports retained data once" {
  export PY_REMOVE_MODE=partial-config PY_REMOVE_STATUS=7
  run -7 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  local retained
  retained=$(cat "$HOME/retained-path")
  [ -f "$retained/lib/payload" ]
  [ ! -e "$retained/pyvenv.cfg" ]
  [[ "$output" == *"$retained"* ]]
  [ "$(grep -F -c "$retained" <<< "$output")" -eq 1 ]
  [[ "$output" != *'Removed '* ]]
}

@test "py remove recovery: deletion that falsely returns success cannot claim completion" {
  export PY_REMOVE_MODE=incomplete-success
  run -1 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  assert_retained_environment
}

@test "py remove recovery: completed deletion returning 130 reports only the remaining directory" {
  export PY_REMOVE_MODE=delete-after PY_REMOVE_STATUS=130
  run -130 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  local retained
  retained=$(cat "$HOME/retained-path")
  [ ! -e "$retained" ]
  [ -d "${retained%/*}" ]
  printf '%s\n' "$output"
  [[ "$output" != *"$retained"* ]]
  [[ "$output" == *"Quarantine path retained: ${retained%/*}"* ]]
  [[ "$output" != *'Removed '* ]]
}

@test "py remove recovery: interrupted empty-directory cleanup preserves 143 without phantom environment" {
  export PY_REMOVE_MODE=empty-parent-failure PY_REMOVE_STATUS=143
  run -143 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  local retained
  retained=$(cat "$HOME/retained-path")
  [ ! -e "$retained" ]
  [ -d "${retained%/*}" ]
  [[ "$output" == *"Quarantine path retained: ${retained%/*}"* ]]
  [[ "$output" != *'Recovery path retained:'* ]]
  [[ "$output" != *'Removed '* ]]
}

@test "py remove recovery: changed retained permissions refuse deletion and qualify the recovery identity" {
  export PY_REMOVE_MODE=unsafe-retained
  run -1 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  local retained
  retained=$(cat "$HOME/retained-path")
  [ -f "$retained/lib/payload" ]
  printf '%s\n' "$output"
  [[ "$output" != *'move it back'* ]]
  [[ "$output" == *"Quarantine path retained with unverified identity: $retained"* ]]
  [[ "$(cat "$HOME/removal-calls")" != *'rm:'* ]]
}

@test "py remove recovery: a returned post-rename mount interruption preserves 143" {
  export PY_REMOVE_MODE=mount-failure PY_REMOVE_STATUS=143
  run -143 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes'
  assert_retained_environment
}

@test "py remove recovery: decline and nonterminal refusal precede every quarantine mutation" {
  run -0 run_zsh 'source "$PY_REMOVE_SETUP"; _py_confirm() { return 130; }; venv-remove --path "$PY_REMOVE_PROJECT/.venv"'
  [ -f "$PY_REMOVE_PROJECT/.venv/lib/payload" ]
  [ ! -e "$HOME/removal-calls" ]
  run -1 run_zsh 'source "$PY_REMOVE_SETUP"; venv-remove --path "$PY_REMOVE_PROJECT/.venv"'
  [ -f "$PY_REMOVE_PROJECT/.venv/lib/payload" ]
  [ ! -e "$HOME/removal-calls" ]
}

@test "py remove recovery: inaccessible parent does not imply environment absence" {
  run -143 run_zsh '
    source "$PY_REMOVE_SETUP" || return $?
    _py_assert_no_mounts_under() {
      if [[ "$1" == */environment ]]; then
        command chmod -- 000 "${1:h}" || return 98
        return 143
      fi
      return 0
    }
    venv-remove --path "$PY_REMOVE_PROJECT/.venv" --yes
  '
  local retained parent
  retained=$(cat "$HOME/retained-path")
  parent=${retained%/*}
  [[ "${parent%/*}" == "$PY_REMOVE_PROJECT" && "${parent##*/}" == .zdx-py-quarantine.* ]]
  chmod -- 700 "$parent"
  [ -f "$retained/lib/payload" ]
  printf '%s\n' "$output"
  [[ "$output" != *'The environment path is absent'* ]]
  [[ "$output" == *'unverified'* ]]
}
