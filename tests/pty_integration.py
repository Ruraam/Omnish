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
loop_read_dir() { loop_list=("fixture"); loop_total=0; loop_prev_idx=0; }
loop_rebuild_visual_marks() { :; }
loop_draw() {
    get_term_size
    printf '%s %s\n' "$LINES" "$COLUMNS" >> "$OMNISH_TEST_TRACE"
    printf 'DRAW\n'
}
loop_main "$1"
'''
        os.execvpe("bash", ["bash", "-c", script, "pty-loop", target], env)
    try:
        read_until(master, b"DRAW", 5)
        deadline = time.monotonic() + 3
        while not os.path.exists(trace) and time.monotonic() < deadline:
            time.sleep(0.01)
        # Change the PTY dimensions; the kernel delivers SIGWINCH to its foreground group.
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 41, 123, 0, 0))
        deadline = time.monotonic() + 3
        resized = False
        while time.monotonic() < deadline:
            if os.path.exists(trace):
                with open(trace, encoding="ascii") as stream:
                    if "41 123" in stream.read():
                        resized = True
                        break
            time.sleep(0.02)
        if not resized:
            raise AssertionError("loop backend did not redraw using resized PTY dimensions")
        # Exit through the real q key; queued CSI bytes are tested below.
        os.write(master, b"q")
        status = wait_child(pid, 5)
        if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
            raise AssertionError(f"loop backend exited abnormally: wait status {status}")
        with open(trace, encoding="ascii") as stream:
            rows = [line.strip() for line in stream if line.strip()]
        if rows.count("24 80") != 1 or rows.count("41 123") != 1 or len(rows) != 2:
            raise AssertionError(f"unexpected redraw sequence (duplicate/lost SIGWINCH): {rows}")
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
    input_flush_and_termios_test()
    print("PASS: PTY SIGWINCH redraw, queued escape cleanup and termios restoration")


if __name__ == "__main__":
    main()
