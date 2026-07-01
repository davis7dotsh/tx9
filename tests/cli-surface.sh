#!/usr/bin/env bash
# Coverage for box subcommands that previously had zero test coverage:
# ls, rm, stop, start, enter, plus the _assign_port exhaustion path and
# control-character archive rejection (the latter lives in
# tests/lifecycle-smoke.sh, alongside the rest of the archive-safety suite).
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# --- box ls (empty registry) -------------------------------------------
ls_empty_repo="$tmp/ls-empty-repo"
make_repo "$ls_empty_repo"
out="$(PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/ls-empty.calls" \
  SMOLVM_STATE_DIR="$tmp/ls-empty-state" "$ls_empty_repo/box" ls)"
[[ "$out" == "No hermes-box-lite boxes yet. Create one: ./box new <name>" ]]

# --- box ls (populated registry: one running, one missing from smolvm) -
ls_repo="$tmp/ls-repo"
make_repo "$ls_repo"
mkdir -p "$tmp/ls-state/present-box"
printf 'present-box\t4790\t8650\t8650\nghost-box\t\t\t\n' >"$ls_repo/.boxes"
out="$(PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/ls.calls" \
  SMOLVM_STATE_DIR="$tmp/ls-state" "$ls_repo/box" ls)"
grep -q '^BOX *STATE' <<<"$out"
grep -q '^present-box *running *http://localhost:4790 *http://localhost:8650' <<<"$out"
grep -q '^ghost-box *missing *— *—' <<<"$out"

# --- box ls --all (needs the smolvm fixture's bare `machine ls`) -------
mkdir -p "$tmp/ls-state/other-vm"
out="$(PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/ls-all.calls" \
  SMOLVM_STATE_DIR="$tmp/ls-state" "$ls_repo/box" ls --all)"
grep -q 'present-box' <<<"$out"
grep -q 'other-vm' <<<"$out"

# --- box rm <name> --force ----------------------------------------------
rm_repo="$tmp/rm-repo"
make_repo "$rm_repo"
mkdir -p "$tmp/rm-state/force-box"
printf 'force-box\t4790\t\t\n' >"$rm_repo/.boxes"
rm_sentinel="$tmp/rm-force.calls"
out="$(PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$rm_sentinel" \
  SMOLVM_STATE_DIR="$tmp/rm-state" "$rm_repo/box" rm force-box --force)"
grep -q "deleted 'force-box'" <<<"$out"
grep -q -- '--name force-box -f' "$rm_sentinel"
[[ ! -s "$rm_repo/.boxes" ]]
[[ ! -d "$tmp/rm-state/force-box" ]]

# --- box rm <name> without --force and without a controlling terminal ---
# `[[ -r /dev/tty ]]` on Linux is a permission-bits check, not proof a
# controlling terminal exists, so a plain stdin redirect doesn't reach the
# "refusing non-interactive deletion" message here (it does on a real
# interactive shell). setsid genuinely detaches the terminal, so this
# asserts the safety property that actually matters regardless of which
# of the two failure modes fires: no confirmation reached, no deletion.
# setsid/timeout are util-linux, not on stock macOS — skip rather than fail
# the whole suite for a host the project otherwise supports.
if ! command -v setsid >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
  echo "setsid/timeout unavailable; skipping the no-controlling-terminal box rm regression" >&2
else
  rm_noforce_repo="$tmp/rm-noforce-repo"
  make_repo "$rm_noforce_repo"
  mkdir -p "$tmp/rm-noforce-state/no-force-box"
  printf 'no-force-box\t\t\t\n' >"$rm_noforce_repo/.boxes"
  noforce_sentinel="$tmp/rm-noforce.calls"
  if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$noforce_sentinel" \
    SMOLVM_STATE_DIR="$tmp/rm-noforce-state" \
    timeout 10 setsid "$rm_noforce_repo/box" rm no-force-box </dev/null >/dev/null 2>&1; then
    echo "box rm without --force unexpectedly succeeded with no controlling terminal" >&2
    exit 1
  fi
  [[ ! -e "$noforce_sentinel" ]] || { echo "smolvm ran before rm confirmation" >&2; exit 1; }
  grep -q '^no-force-box' "$rm_noforce_repo/.boxes"
fi

# --- box rm <name>: typed-name confirmation, both mismatch and match ----
# Exercises the real /dev/tty prompt path via a pty, since `--force` and the
# no-tty refusal above don't reach this code at all.
rm_tty_repo="$tmp/rm-tty-repo"
make_repo "$rm_tty_repo"
mkdir -p "$tmp/rm-tty-state/tty-box"
printf 'tty-box\t\t\t\n' >"$rm_tty_repo/.boxes"
tty_sentinel="$tmp/rm-tty.calls"
PROJECT_ROOT="$PROJECT_ROOT" RM_REPO="$rm_tty_repo" RM_STATE="$tmp/rm-tty-state" \
  RM_SENTINEL="$tty_sentinel" python3 <<'PY'
import os
import pty
import sys
import time

project_root = os.environ["PROJECT_ROOT"]
repo = os.environ["RM_REPO"]
state = os.environ["RM_STATE"]
sentinel = os.environ["RM_SENTINEL"]


def run(answer):
    pid, master_fd = pty.fork()
    if pid == 0:
        os.environ["PATH"] = project_root + "/tests/fixtures:" + os.environ["PATH"]
        os.environ["SMOLVM_CALLED"] = sentinel
        os.environ["SMOLVM_STATE_DIR"] = state
        os.execv(repo + "/box", [repo + "/box", "rm", "tty-box"])
    buf = b""
    deadline = time.time() + 10
    while b"Type the box name" not in buf and time.time() < deadline:
        try:
            chunk = os.read(master_fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    os.write(master_fd, (answer + "\n").encode())
    try:
        while True:
            chunk = os.read(master_fd, 4096)
            if not chunk:
                break
            buf += chunk
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
    code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1
    return code, buf

code, output = run("wrong-name")
if code != 1 or b"deletion cancelled" not in output:
    sys.exit(f"mismatched confirmation did not refuse deletion: code={code} output={output!r}")
if os.path.exists(sentinel):
    sys.exit("smolvm ran despite a confirmation mismatch")

code, output = run("tty-box")
if code != 0 or b"deleted 'tty-box'" not in output:
    sys.exit(f"matching confirmation did not delete the box: code={code} output={output!r}")
PY
[[ ! -s "$rm_tty_repo/.boxes" ]]
[[ ! -d "$tmp/rm-tty-state/tty-box" ]]

# --- box stop / box start: happy path delegates to smolvm ---------------
stop_repo="$tmp/stop-repo"
make_repo "$stop_repo"
mkdir -p "$tmp/stop-state/stop-box"
stop_sentinel="$tmp/stop.calls"
PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$stop_sentinel" \
  SMOLVM_STATE_DIR="$tmp/stop-state" "$stop_repo/box" stop stop-box >/dev/null
grep -q -- 'machine stop --name stop-box' "$stop_sentinel"
start_sentinel="$tmp/start.calls"
PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$start_sentinel" \
  SMOLVM_STATE_DIR="$tmp/stop-state" "$stop_repo/box" start stop-box >/dev/null
grep -q -- 'machine start --name stop-box' "$start_sentinel"

# --- box stop: a held per-box lock blocks a concurrent operation --------
lock_repo="$tmp/lock-repo"
make_repo "$lock_repo"
mkdir -p "$tmp/lock-state/locked-box" "$lock_repo/.box-locks/locked-box.lock"
printf '%s\n' "$$" >"$lock_repo/.box-locks/locked-box.lock/pid"
locked_sentinel="$tmp/locked.calls"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$locked_sentinel" \
  SMOLVM_STATE_DIR="$tmp/lock-state" "$lock_repo/box" stop locked-box >/dev/null 2>"$tmp/locked.err"; then
  echo "box stop unexpectedly succeeded against a held lock" >&2
  exit 1
fi
grep -q "already holds the 'locked-box' lock" "$tmp/locked.err"
[[ ! -e "$locked_sentinel" ]] || { echo "smolvm ran despite a held lock" >&2; exit 1; }

# --- box enter: execs the expected smolvm command line -------------------
enter_repo="$tmp/enter-repo"
make_repo "$enter_repo"
mkdir -p "$tmp/enter-state/enter-box"
enter_sentinel="$tmp/enter.calls"
PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$enter_sentinel" \
  SMOLVM_BEHAVIOR=success \
  SMOLVM_STATE_DIR="$tmp/enter-state" "$enter_repo/box" enter enter-box >/dev/null
grep -q -- 'machine start --name enter-box' "$enter_sentinel"
grep -q -- 'machine exec -it --name enter-box -- login -f agent' "$enter_sentinel"

# --- _assign_port: the exhaustion path dies with the documented message -
port_repo="$tmp/port-repo"
make_repo "$port_repo"
printf 'port-hog\t39999\t\t\n' >"$port_repo/.boxes"
if err="$(
  cd "$port_repo"
  # shellcheck disable=SC1091
  source ./box
  _assign_port 39999 39999 testlabel 2>&1
)"; then
  echo "_assign_port unexpectedly succeeded against an exhausted range" >&2
  exit 1
else
  grep -q 'no free host port in 39999-39999' <<<"$err"
fi

echo "cli-surface checks passed"
