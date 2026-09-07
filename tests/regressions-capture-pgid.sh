#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

python3 - "$PROJECT_ROOT/guest/tx9-logs" "$tmp" <<'PY'
import errno
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys

loader = importlib.machinery.SourceFileLoader("tx9_logs_pgid", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
root = Path(sys.argv[2])
original_popen = subprocess.Popen
original_killpg = os.killpg
original_fdopen = os.fdopen

for case, command, expected in (
    ("exited", [sys.executable, "-c", "raise SystemExit(23)"], 23),
    ("exec-failed", [str(root / "missing-command")], 127),
    ("handshake-failed", [sys.executable, "-c", "import time; time.sleep(30)"], 126),
):
    capture = module.Capture("agent", root / case, 10000, 2)
    sent = []
    reaped = []

    def checked_killpg(pgid, signum):
        # WNOWAIT proves the leader still pins this numeric group identity
        # without reaping it ourselves. A probe with killpg(pgid, 0) alone
        # cannot distinguish the owned group from a reused numeric PGID.
        try:
            os.waitid(os.P_PID, pgid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
        except ChildProcessError:
            raise AssertionError("signalled a group after reaping its leader") from None
        sent.append(signum)
        return original_killpg(pgid, signum)

    class CheckedPopen(original_popen):
        def wait(self, *args, **kwargs):
            result = super().wait(*args, **kwargs)
            reaped.append(self.pid)
            # Deliver a shutdown signal in the exact window where this PID
            # can now be recycled. Capture must have stopped forwarding.
            before = len(sent)
            previous_signal = capture.received_signal
            try:
                capture._forward_signal(signal.SIGTERM, None)
            finally:
                capture.received_signal = previous_signal
            assert len(sent) == before, "forwarded a signal after reaping"
            return result

    def failing_fdopen(fd, *args, **kwargs):
        if case == "handshake-failed" and kwargs.get("buffering") == 0:
            os.close(fd)
            raise OSError(errno.EIO, "synthetic handshake failure")
        return original_fdopen(fd, *args, **kwargs)

    subprocess.Popen = CheckedPopen
    os.killpg = checked_killpg
    os.fdopen = failing_fdopen
    try:
        assert capture.run_once(command) == expected
        assert len(reaped) == 1, "direct child was not reaped exactly once"
        assert capture.active_pgid is None
        if case == "exited":
            assert signal.SIGTERM in sent and signal.SIGKILL in sent
    finally:
        subprocess.Popen = original_popen
        os.killpg = original_killpg
        os.fdopen = original_fdopen
        if capture.child is not None:
            if capture.child.returncode is None:
                original_killpg(capture.child.pid, signal.SIGKILL)
            capture.active_pgid = None
            original_popen.wait(capture.child)
        capture.close()
PY

echo "capture process-group identity regression checks passed"
