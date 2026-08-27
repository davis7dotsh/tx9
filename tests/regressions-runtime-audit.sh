#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# A broken durable root must fail initialization and every lifecycle action.
printf 'not a directory\n' >"$tmp/blocked-data"
for action in init up reconcile pause; do
  if HB_DATA="$tmp/blocked-data" "$PROJECT_ROOT/guest/hb" "$action" \
    >"$tmp/$action.stdout" 2>"$tmp/$action.stderr"; then
    echo "$action ignored durable data initialization failure" >&2
    exit 1
  fi
done

# Backup quiescence requires a persistent stop marker before stopping writers.
(
  HB_DATA="$tmp/pause-failure"
  # shellcheck source=guest/hb
  source "$PROJECT_ROOT/guest/hb"
  init
  QUIESCE_FILE="$tmp/blocked-data/quiesced"
  _services_stop() { touch "$tmp/stopped-without-marker"; }
  _stop_gateway() { touch "$tmp/stopped-without-marker"; }
  _stop_executor() { touch "$tmp/stopped-without-marker"; }
  if pause >"$tmp/pause-marker.stdout" 2>"$tmp/pause-marker.stderr"; then
    echo "pause claimed quiescence without a persistent marker" >&2
    exit 1
  fi
  [[ ! -e "$tmp/stopped-without-marker" && ! -s "$tmp/pause-marker.stdout" ]]
)

# hb's sourced temporary variables do not replace the parent test directory.
# shellcheck disable=SC2031
python3 - "$PROJECT_ROOT/guest/tx9-logs" "$tmp" <<'PY'
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import time

loader = importlib.machinery.SourceFileLoader("tx9_logs_runtime", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
root = Path(sys.argv[2])

# A service can leave a same-group descendant with closed output pipes.
# Capture must give it a TERM grace and then stop it before returning.
pid_file = root / "descendant.pid"
child = '''import os, signal, sys
from pathlib import Path
reader, writer = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(reader)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(os.devnull, "wb") as sink:
        os.dup2(sink.fileno(), 1)
        os.dup2(sink.fileno(), 2)
    os.write(writer, b"ready")
    os.close(writer)
    while True:
        signal.pause()
os.close(writer)
assert os.read(reader, 5) == b"ready"
os.close(reader)
Path(sys.argv[1]).write_text(str(pid))
os._exit(23)
'''

def alive(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()[0] != "Z"
    except FileNotFoundError:
        return False

try:
    completed = subprocess.run(
        [sys.argv[1], "capture", "--source", "agent", "--log-dir", str(root / "capture"),
         "--", sys.executable, "-c", child, str(pid_file)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
    )
    assert completed.returncode == 23
    pid = int(pid_file.read_text())
    deadline = time.monotonic() + 1
    while alive(pid) and time.monotonic() < deadline:
        time.sleep(0.01)
    assert not alive(pid), "capture left a same-group descendant running after pipe EOF"
finally:
    if pid_file.exists():
        try:
            os.kill(int(pid_file.read_text()), signal.SIGKILL)
        except ProcessLookupError:
            pass

# Source filtering happens before opening runtime logs, not after parsing
# unrelated histories. Unselected malformed logs must not cause warnings.
agent = root / "agent"
logs = agent / "logs"
logs.mkdir(parents=True)
(logs / "agent.jsonl").write_text(json.dumps({"message": "selected supervisor"}) + "\n")
(logs / "hermes.jsonl").write_text("not JSON\n")
(logs / "service-worker.log").write_text("unselected service\n")
original_jsonl = module.read_jsonl
original_raw = module.read_raw

def selected_jsonl(path, **kwargs):
    assert kwargs["source"] == "agent", "parsed an unselected JSONL source"
    yield from original_jsonl(path, **kwargs)

def selected_raw(path, **kwargs):
    raise AssertionError("parsed an unselected raw source")

module.read_jsonl = selected_jsonl
module.read_raw = selected_raw
events = list(module.read_runtime_logs(agent, scope="agent", box="fixture", selected={"agent"}))
assert [event["message"] for event in events] == ["selected supervisor"]
module.read_jsonl = original_jsonl
module.read_raw = original_raw

# A canonical Hermes database avoids walking every session, skill, or cache
# file merely to rediscover the same state.db on each query.
home = agent / "home" / "agent"
hermes = home / ".hermes"
hermes.mkdir(parents=True)
with sqlite3.connect(hermes / "state.db") as connection:
    connection.execute("CREATE TABLE messages(content TEXT)")
original_walk = module.iter_regular_files

def unexpected_walk(*args, **kwargs):
    raise AssertionError("walked the Hermes tree despite a canonical state.db")

module.iter_regular_files = unexpected_walk
assert module.hermes_db_paths(home, root=agent) == [hermes / "state.db"]
module.iter_regular_files = original_walk
nested = hermes / "profiles" / "other"
nested.mkdir(parents=True)
(hermes / "state.db").rename(nested / "state.db")
assert module.hermes_db_paths(home, root=agent) == [nested / "state.db"]

# SQLite URI metacharacters in profile names must stay literal. Verification
# must inspect the requested file and never create a truncated-name database.
loader = importlib.machinery.SourceFileLoader(
    "hermes_state_runtime", str(Path(sys.argv[1]).with_name("hermes-state"))
)
spec = importlib.util.spec_from_loader(loader.name, loader)
state = importlib.util.module_from_spec(spec)
loader.exec_module(state)
for index, name in enumerate(("profile#one", "profile?two", "profile%2fthree", "profile four")):
    state_home = root / f"uri-home-{index}"
    directory = state_home / name
    directory.mkdir(parents=True)
    database = directory / "state.db"
    database.write_bytes(b"corrupt database fixture")
    before = set(state_home.rglob("*"))
    try:
        state.inspect_home(state_home)
    except sqlite3.DatabaseError:
        pass
    else:
        raise AssertionError("URI metacharacters bypassed database integrity validation")
    assert set(state_home.rglob("*")) == before
    database.unlink()
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE messages(content TEXT)")
        connection.execute("INSERT INTO messages VALUES('profile fixture')")
    for checkpoint in (False, True):
        report = state.inspect_home(state_home, checkpoint=checkpoint)
        assert report["databases"][0]["messages"] == 1
        assert report["databases"][0]["path"] == f"{name}/state.db"
PY

echo "runtime audit regression checks passed"
