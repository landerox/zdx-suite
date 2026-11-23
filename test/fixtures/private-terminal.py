"""Send Ctrl-C to a private terminal and report its child's exit status."""

import errno
import os
import pty
import select
import signal
import sys
import time


def read_terminal(terminal):
    if not select.select([terminal], [], [], 0.05)[0]:
        return None
    try:
        return os.read(terminal, 65536)
    except OSError as error:
        if error.errno != errno.EIO:
            raise
        return b""


def reap_owned_child(pid):
    found, status = os.waitpid(pid, os.WNOHANG)
    if found:
        return status
    # The child is still ours and unreaped.
    os.kill(pid, signal.SIGTERM)
    limit = time.monotonic() + 2
    while time.monotonic() < limit:
        found, status = os.waitpid(pid, os.WNOHANG)
        if found:
            return status
        time.sleep(0.02)
    os.kill(pid, signal.SIGKILL)
    return os.waitpid(pid, 0)[1]


ready_marker, complete_marker = (argument.encode() for argument in sys.argv[1:3])
argv = sys.argv[3:]
pid, terminal = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)

output = bytearray()
status = None
sent = acknowledged = terminal_closed = False
deadline = time.monotonic() + 12
try:
    while time.monotonic() < deadline:
        data = b"" if terminal_closed else read_terminal(terminal)
        if data is not None:
            output.extend(data)
            if len(output) > 1024 * 1024:
                raise RuntimeError("private terminal output exceeded its limit")
            terminal_closed = not data
        if not sent and ready_marker in output:
            os.write(terminal, b"\x03")
            sent = True
        if complete_marker and sent and not acknowledged and complete_marker in output:
            # The child keeps its terminal open until the report has been read.
            os.write(terminal, b"\n")
            acknowledged = True
        if status is not None and not data:
            break
        if status is None:
            found, child_status = os.waitpid(pid, os.WNOHANG)
            if found:
                status = child_status
            elif terminal_closed:
                time.sleep(0.02)
finally:
    try:
        if status is None:
            status = reap_owned_child(pid)
    finally:
        os.close(terminal)

sys.stdout.buffer.write(output.replace(b"\r", b""))
code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
print(f"PTY_CTRL_C_SENT:{sent}")
print(f"PTY_CHILD_STATUS:{code}")
if not sent or (complete_marker and not acknowledged):
    raise SystemExit(97)
raise SystemExit(code if code >= 0 else 128 - code)
