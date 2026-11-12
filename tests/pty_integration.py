#!/usr/bin/env python3
"""PTY integration tests for Omnish loop resize and terminal input cleanup."""
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_until(fd, needle, timeout=5.0):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        data.extend(chunk)
        if needle in data:
            return bytes(data)
    raise AssertionError(f"PTY did not emit {needle!r}; received {bytes(data)!r}")


def wait_child(pid, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = os.waitpid(pid, os.WNOHANG)
        if result[0]:
            return result[1]
        time.sleep(0.02)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    raise AssertionError("PTY child did not exit in time")


def loop_resize_and_exit_test(tmp):
    trace = os.path.join(tmp, "draws")
    target = os.path.join(tmp, "target")
    os.mkdir(target)
    pid, master = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        env = os.environ.copy()
        env.update({"OMNISH_TEST_ROOT": ROOT, "OMNISH_TEST_TRACE": trace,
                    "OMNISH_RUNTIME_DIR": os.path.join(tmp, "runtime"),
                    "OMNI_CD_ON_EXIT": "0"})
        script = r'''
set -euo pipefail
source "$OMNISH_TEST_ROOT/lib/00-config.sh"
source "$OMNISH_TEST_ROOT/lib/10-utils.sh"
source "$OMNISH_TEST_ROOT/lib/70-loop.sh"
loop_read_dir() { loop_list=("fixture-a" "fixture-b"); loop_total=1; loop_prev_idx=0; }
loop_rebuild_visual_marks() { :; }
loop_draw() {
    get_term_size
    printf 'DRAW %s %s %s\n' "$LINES" "$COLUMNS" "$loop_scroll" >> "$OMNISH_TEST_TRACE"
    printf 'DRAW\n'
}
before=$(stty -g </dev/tty)
(loop_main "$1")
after=$(stty -g </dev/tty)
[[ "$before" == "$after" ]] || { printf 'TERMIOS-EXIT-MISMATCH\n'; exit 8; }
stty -icanon -echo min 1 time 0 </dev/tty
if IFS= read -rsn 1 -t 0.15 leaked </dev/tty 2>/dev/null; then
    stty "$before" </dev/tty
    printf 'INPUT-LEAK\n'
    exit 9
fi
stty "$before" </dev/tty
printf 'EXIT-CLEAN\n'
'''
        os.execvpe("bash", ["bash", "-c", script, "pty-loop", target], env)
    try:
        read_until(master, b"DRAW", 5)
        # Navigate first so SIGWINCH is delivered while the UI is in use.
        os.write(master, b"j")
        deadline = time.monotonic() + 3
        navigated = False
        while time.monotonic() < deadline:
            if os.path.exists(trace):
                with open(trace, encoding="ascii") as stream:
                    if "DRAW 24 80 1" in stream.read():
                        navigated = True
                        break
            time.sleep(0.02)
        if not navigated:
            raise AssertionError("loop backend did not process navigation input")
        # Change the PTY dimensions during navigation; the kernel delivers SIGWINCH.
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 41, 123, 0, 0))
        deadline = time.monotonic() + 3
        resized = False
        while time.monotonic() < deadline:
            if os.path.exists(trace):
                with open(trace, encoding="ascii") as stream:
                    if "DRAW 41 123 1" in stream.read():
                        resized = True
                        break
            time.sleep(0.02)
        if not resized:
            raise AssertionError("loop backend did not redraw using resized PTY dimensions")
        # Queue an incomplete CSI after q. Cleanup must drain it before the
        # calling shell resumes, and restore the exact original termios state.
        os.write(master, b"q\x1b[")
        output = read_until(master, b"EXIT-CLEAN", 5)
        status = wait_child(pid, 5)
        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise AssertionError(f"loop backend exited abnormally: {output!r}, wait status {status}")
        if b"INPUT-LEAK" in output or b"TERMIOS-EXIT-MISMATCH" in output:
            raise AssertionError(f"terminal cleanup regression: {output!r}")
        with open(trace, encoding="ascii") as stream:
            rows = [line.strip() for line in stream if line.strip()]
        if rows.count("DRAW 24 80 0") != 1 or rows.count("DRAW 24 80 1") != 1 or rows.count("DRAW 41 123 1") != 1 or len(rows) != 3:
            raise AssertionError(f"unexpected redraw/navigation sequence: {rows}")
    finally:
        try:
            os.close(master)
        except OSError:
            pass



def loop_sigterm_mid_escape_test(tmp):
    target = os.path.join(tmp, "sigterm-target")
    os.mkdir(target)
    pidfile = os.path.join(tmp, "ui-pid")
    pid, master = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        env.update({"OMNISH_TEST_ROOT": ROOT,
                    "OMNISH_TEST_PID": pidfile,
                    "OMNISH_RUNTIME_DIR": os.path.join(tmp, "sigterm-runtime"),
                    "OMNI_CD_ON_EXIT": "0"})
        script = r'''
set -euo pipefail
source "$OMNISH_TEST_ROOT/lib/00-config.sh"
source "$OMNISH_TEST_ROOT/lib/10-utils.sh"
source "$OMNISH_TEST_ROOT/lib/70-loop.sh"
loop_read_dir() { loop_list=("fixture-a" "fixture-b"); loop_total=1; loop_prev_idx=0; }
loop_rebuild_visual_marks() { :; }
loop_draw() { printf 'READY\n'; }
before=$(stty -g </dev/tty)
(loop_main "$1") &
ui_pid=$!
printf '%s\n' "$ui_pid" > "$OMNISH_TEST_PID"
rc=0
wait "$ui_pid" || rc=$?
after=$(stty -g </dev/tty)
[[ "$rc" == 143 ]] || { printf 'BAD-SIGNAL-STATUS:%s\n' "$rc"; exit 10; }
[[ "$before" == "$after" ]] || { printf 'TERMIOS-SIGNAL-MISMATCH\n'; exit 11; }
stty -icanon -echo min 1 time 0 </dev/tty
if IFS= read -rsn 1 -t 0.15 leaked </dev/tty 2>/dev/null; then
    stty "$before" </dev/tty
    printf 'SIGNAL-INPUT-LEAK\n'
    exit 12
fi
stty "$before" </dev/tty
printf 'SIGTERM-CLEAN\n'
'''
        os.execvpe("bash", ["bash", "-c", script, "pty-sigterm", target], env)
    try:
        read_until(master, b"READY", 5)
        deadline = time.monotonic() + 3
        while not os.path.exists(pidfile) and time.monotonic() < deadline:
            time.sleep(0.01)
        if not os.path.exists(pidfile):
            raise AssertionError("loop backend did not publish its PID")
        with open(pidfile, encoding="ascii") as stream:
            ui_pid = int(stream.read().strip())
        # ESC is consumed as the start of a CSI sequence; terminate while the
        # backend is waiting for the next byte, not after a completed key.
        os.write(master, b"\x1b")
        time.sleep(0.02)
        os.kill(ui_pid, signal.SIGTERM)
        output = read_until(master, b"SIGTERM-CLEAN", 5)
        status = wait_child(pid, 5)
        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise AssertionError(f"SIGTERM cleanup failed: {output!r}, status={status}")
        if b"TERMIOS-SIGNAL-MISMATCH" in output or b"SIGNAL-INPUT-LEAK" in output:
            raise AssertionError(f"SIGTERM terminal restoration regression: {output!r}")
    finally:
        try:
            os.close(master)
        except OSError:
            pass

def input_flush_and_termios_test():
    pid, master = pty.fork()
    if pid == 0:
        script = r'''
set -euo pipefail
source "$OMNISH_TEST_ROOT/lib/00-config.sh"
source "$OMNISH_TEST_ROOT/lib/10-utils.sh"
stty -icanon -echo min 1 time 0 </dev/tty
before=$(stty -g </dev/tty)
printf 'READY\\n'
IFS= read -rsn 1 token </dev/tty
[[ "$token" == X ]]
_omnish_flush_tty_input
after=$(stty -g </dev/tty)
[[ "$before" == "$after" ]] || { printf 'TERMios-MISMATCH\\n'; exit 8; }
if IFS= read -rsn 1 -t 0.15 leaked </dev/tty 2>/dev/null; then
    printf 'INPUT-LEAK\\n'
    exit 9
fi
printf 'FLUSH-CLEAN\\n'
'''
        env = os.environ.copy()
        env.update({"OMNISH_TEST_ROOT": ROOT,
                    "OMNISH_RUNTIME_DIR": "/tmp/omnish-pty-flush-test"})
        os.execvpe("bash", ["bash", "-c", script], env)
    try:
        read_until(master, b"READY", 5)
        os.write(master, b"X\x1b[")
        output = read_until(master, b"FLUSH-CLEAN", 5)
        status = wait_child(pid, 5)
        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise AssertionError(f"TTY flush test failed: {output!r}, status={status}")
        if b"INPUT-LEAK" in output or b"TERMios-MISMATCH" in output:
            raise AssertionError(f"TTY cleanup regression: {output!r}")
    finally:
        try:
            os.close(master)
        except OSError:
            pass


def main():
    with tempfile.TemporaryDirectory(prefix="omnish-pty-") as tmp:
        loop_resize_and_exit_test(tmp)
    with tempfile.TemporaryDirectory(prefix="omnish-pty-sigterm-") as tmp:
        loop_sigterm_mid_escape_test(tmp)
    input_flush_and_termios_test()
    print("PASS: PTY SIGWINCH redraw, queued escape cleanup and termios restoration")


if __name__ == "__main__":
    main()
