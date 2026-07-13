#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

helper="$PROJECT_ROOT/guest/tx9-logs"
agent_root="$tmp/agent"
executor_root="$tmp/executor"
mkdir -p "$agent_root/logs" "$executor_root/logs"

# Reject restart delays that can bypass or indefinitely poison the supervisor's
# monotonic sleep loop before any child process is started. Zero remains a
# deliberate immediate-restart setting.
python3 - "$helper" <<'PY'
import contextlib
import importlib.machinery
import importlib.util
import io
import sys

loader = importlib.machinery.SourceFileLoader("tx9_logs_restart_delay", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
parser = module.build_parser()

for value in ("-1", "nan", "inf", "-inf"):
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        try:
            parser.parse_args([
                "capture", "--source", "agent", f"--restart-delay={value}", "--", "true"
            ])
        except SystemExit as exc:
            assert exc.code == 2
        else:
            raise AssertionError(f"accepted invalid restart delay {value!r}")
    assert "must be finite and non-negative" in stderr.getvalue()

args = parser.parse_args([
    "capture", "--source", "agent", "--restart-delay=0", "--", "true"
])
assert args.restart_delay == 0
args = parser.parse_args([
    "capture", "--source", "agent", "--restart-delay=0.25", "--", "true"
])
assert args.restart_delay == 0.25
args = parser.parse_args(["capture", "--source", "agent", "--", "true"])
assert args.restart_delay is None
PY

# Source reads stop at the first unterminated snapshot boundary instead of
# reframing bytes appended during the query as a separate record. A record that
# fills the entire byte budget without room for its newline is already oversized.
python3 - "$helper" "$tmp/record-snapshot.log" <<'PY'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("tx9_logs_records", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
path = sys.argv[2]

with open(path, "wb") as handle:
    handle.write(b"prefix")
with open(path, "rb") as handle:
    records = module.iter_bounded_records(handle)
    assert next(records) == (1, b"prefix", False)
    with open(path, "ab") as writer:
        writer.write(b"-suffix\nnext\n")
    assert list(records) == []

with open(path, "wb") as handle:
    handle.write(b"x" * module.MAX_SOURCE_RECORD_BYTES)
with open(path, "rb") as handle:
    assert list(module.iter_bounded_records(handle)) == [(1, None, False)]
PY

# Capture preserves the wrapped command's status and stdout/stderr split while
# redacting all supported token forms before either mirroring or persistence.
set +e
TX9_BOX_NAME=fixture-box EXECUTOR_MCP_TOKEN=exact-capture-secret \
  OPENAI_API_KEY=exact-api-key-secret CLIENT_SECRET=exact-client-secret \
  "$helper" capture --source executor --log-dir "$executor_root/logs" -- \
    bash -c 'printf "executor-out Bearer bearer-secret api_token=query-secret exact-capture-secret exact-api-key-secret exact-client-secret\nCookie: session=cookie-first; prefs=cookie-second\n{\"api_token\":\"json-secret\",\"password\":\"pw-secret\"}\n"; printf "executor-err _token=param-secret exact-capture-secret\n" >&2; exit 7' \
    >"$tmp/capture.stdout" 2>"$tmp/capture.stderr"
capture_status=$?
set -e
[[ "$capture_status" == 7 ]]
grep -q 'executor-out' "$tmp/capture.stdout"
grep -q 'executor-err' "$tmp/capture.stderr"
grep -q 'executor-out' "$executor_root/logs/executor.log"
[[ "$(stat -c '%a' "$executor_root/logs")" == 700 ]]
[[ "$(stat -c '%a' "$executor_root/logs/executor.log")" == 600 ]]
[[ "$(stat -c '%a' "$executor_root/logs/executor.jsonl")" == 600 ]]
jq -e 'select(.source == "executor" and .stream == "stdout" and .type == "output")' \
  "$executor_root/logs/executor.jsonl" >/dev/null
if grep -R -nE -- 'bearer-secret|query-secret|param-secret|exact-capture-secret|exact-api-key-secret|exact-client-secret|cookie-first|cookie-second|json-secret|pw-secret' \
    "$tmp/capture.stdout" "$tmp/capture.stderr" "$executor_root/logs"; then
  echo "capture persisted or mirrored a token" >&2
  exit 1
fi

# Exact values are matched across logical-record boundaries too. Environment
# values can contain newlines, so line-oriented replacement would leak both
# halves even though neither half is independently sensitive-looking.
multiline_dir="$tmp/multiline-secret"
multiline_secret=$'multiline-first-half\nmultiline-second-half'
MULTILINE_SECRET="$multiline_secret" \
  "$helper" capture --source agent --log-dir "$multiline_dir" -- \
    python3 -c 'import os; print("before " + os.environ["MULTILINE_SECRET"] + " after")' \
    >"$tmp/multiline-secret.stdout"
if grep -R -nE -- 'multiline-first-half|multiline-second-half' \
    "$tmp/multiline-secret.stdout" "$multiline_dir"; then
  echo "capture exposed part of a multiline exact secret" >&2
  exit 1
fi
grep -q '\[REDACTED\]' "$tmp/multiline-secret.stdout"

# Capture retains enough lookahead to redact an exact environment token even
# when it crosses the bounded 64 KiB split for an unterminated logical line.
boundary_dir="$tmp/boundary"
boundary_secret='exact-boundary-secret'
BOUNDARY_TOKEN="$boundary_secret" \
  "$helper" capture --source executor --log-dir "$boundary_dir" -- \
    python3 -c 'import os; os.write(1, b"x" * (65536 - 7) + os.environ["BOUNDARY_TOKEN"].encode() + b"tail")' \
    >"$tmp/boundary.stdout"
if grep -R -nF -- "$boundary_secret" "$tmp/boundary.stdout" "$boundary_dir"; then
  echo "capture exposed an exact token across a chunk boundary" >&2
  exit 1
fi
grep -q '\[REDACTED\]tail' "$tmp/boundary.stdout"

# Very short environment values are redacted only in credential context;
# treating them as global exact matches would corrupt nearly every record.
short_secret_dir="$tmp/short-secret"
SHORT_TOKEN=x LONG_TOKEN=long-exact-secret \
  "$helper" capture --source agent --log-dir "$short_secret_dir" -- \
    bash -c 'printf "executor box next xylophone bare=x token=x long-exact-secret\n"' \
    >"$tmp/short-secret.stdout"
grep -q 'executor box next xylophone bare=x token=\[REDACTED\] \[REDACTED\]' \
  "$tmp/short-secret.stdout"
if grep -R -nF -- 'long-exact-secret' "$tmp/short-secret.stdout" "$short_secret_dir"; then
  echo "capture exposed a long exact secret" >&2
  exit 1
fi

# A complete exact value can overlap one of its own proper prefixes. Align the
# overlap with the fixed flush boundary and pause the writer so capture cannot
# rely on receiving the value and its following delimiter in one read.
overlap_dir="$tmp/overlap-secret"
overlap_secret='token-123-token'
SELF_TOKEN="$overlap_secret" \
  "$helper" capture --source agent --log-dir "$overlap_dir" -- python3 - <<'PY' \
  >"$tmp/overlap-secret.stdout"
import os
import time

os.write(1, b"o" * 65526)
time.sleep(0.02)
os.write(1, os.environ["SELF_TOKEN"].encode() + b"\n")
PY
if grep -R -nF -- "$overlap_secret" "$tmp/overlap-secret.stdout" "$overlap_dir"; then
  echo "capture split and exposed a self-overlapping exact secret" >&2
  exit 1
fi
grep -q '\[REDACTED\]' "$tmp/overlap-secret.stdout"

# Pattern recognition runs before exact replacement. An exact secret equal to
# the key name must not erase the `token=` cue and expose its following value.
context_dir="$tmp/exact-pattern-context"
KEY_SECRET=access_token \
  "$helper" capture --source agent --log-dir "$context_dir" -- \
    bash -c 'printf "access_token=pattern-value-secret\n"' \
    >"$tmp/exact-pattern-context.stdout"
if grep -R -nF -- 'pattern-value-secret' "$tmp/exact-pattern-context.stdout" "$context_dir"; then
  echo "exact replacement erased pattern context before value redaction" >&2
  exit 1
fi
[[ "$(grep -o '\[REDACTED\]' "$tmp/exact-pattern-context.stdout" | wc -l | tr -d ' ')" -ge 2 ]]

# Valid UTF-8 remains byte-identical when a code point straddles the fixed
# capture boundary; raw, mirrored, and structured output must all agree.
utf8_dir="$tmp/utf8-boundary"
"$helper" capture --source agent --log-dir "$utf8_dir" -- python3 - <<'PY' \
  >"$tmp/utf8-boundary.stdout"
import os

os.write(1, b"a" * 65535 + "🙂".encode() + b"z" * 300)
PY
python3 - "$tmp/utf8-boundary.stdout" "$utf8_dir/workload.log" "$utf8_dir/agent.jsonl" <<'PY'
import json
import pathlib
import sys

expected = b"a" * 65535 + "🙂".encode() + b"z" * 300
assert pathlib.Path(sys.argv[1]).read_bytes() == expected
assert pathlib.Path(sys.argv[2]).read_bytes() == expected
events = [json.loads(line) for line in pathlib.Path(sys.argv[3]).read_text().splitlines()]
message = "".join(
    event["message"]
    for event in events
    if event.get("type") == "output" and event.get("stream") == "stdout"
)
assert message.encode() == expected
PY

# Every supported pattern remains redacted when its prefix, arbitrarily long
# valid whitespace, and value straddle reads. Pauses force the state machine
# to process each incomplete phase before the value delimiter arrives.
pattern_dir="$tmp/pattern-boundary"
"$helper" capture --source agent --log-dir "$pattern_dir" -- python3 - <<'PY' \
  >"$tmp/pattern-boundary.stdout"
import os
import time

cases = (
    (b"Bearer ", b"bearer-boundary-secret" + b"a" * 1024, b" "),
    (b"Authorization:", b"authorization-boundary-secret" + b"b" * 1024, b"\n"),
    (b"Cookie:", b"cookie-boundary-secret" + b"c" * 1024, b"\n"),
    (b"api_token=", b"token-boundary-secret" + b"d" * 1024, b" "),
    (b"password=", b"password-boundary-secret" + b"e" * 1024, b" "),
    (b"headers.authorization:", b"Basic namespaced-auth-secret" + b"f" * 1024, b"\n"),
    (b"headers.set-cookie:", b"session=one; namespaced-cookie-secret" + b"g" * 1024, b"\n"),
    (b"auth.bearer ", b"namespaced-bearer-secret" + b"h" * 1024, b" "),
)
for prefix, value, suffix in cases:
    gap = b" " * 512
    os.write(1, b"x" * 65520 + b" " + prefix + gap[:256])
    time.sleep(0.02)
    os.write(1, gap[256:] + value[:512])
    time.sleep(0.02)
    os.write(1, value[512:] + suffix)
PY
if grep -R -nE -- 'bearer-boundary-secret|authorization-boundary-secret|cookie-boundary-secret|token-boundary-secret|password-boundary-secret|namespaced-auth-secret|namespaced-cookie-secret|namespaced-bearer-secret' \
    "$tmp/pattern-boundary.stdout" "$pattern_dir"; then
  echo "capture exposed a credential pattern across a chunk boundary" >&2
  exit 1
fi
[[ "$(grep -o '\[REDACTED\]' "$tmp/pattern-boundary.stdout" | wc -l | tr -d ' ')" -ge 8 ]]

# One active file plus numbered generations stays inside the configured file
# count and byte limit for both raw and JSONL formats.
rotation_dir="$tmp/rotation"
TX9_LOG_MAX_BYTES=1024 TX9_LOG_MAX_FILES=3 \
  "$helper" capture --source executor --log-dir "$rotation_dir" -- \
    python3 -c 'for _ in range(80): print("x" * 180)' >/dev/null
[[ "$(find "$rotation_dir" -maxdepth 1 -type f -name 'executor.log*' | wc -l | tr -d ' ')" -le 3 ]]
[[ "$(find "$rotation_dir" -maxdepth 1 -type f -name 'executor.jsonl*' | wc -l | tr -d ' ')" -le 3 ]]
while IFS= read -r path; do
  [[ "$(wc -c <"$path")" -le 1024 ]] || { echo "oversized rotated log: $path" >&2; exit 1; }
done < <(find "$rotation_dir" -maxdepth 1 -type f)

# A termination signal reaches the wrapped process group, and capture returns
# the conventional signal-derived status instead of masking it.
signal_dir="$tmp/signal"
"$helper" capture --source agent --log-dir "$signal_dir" -- \
  bash -c 'trap "exit 0" TERM; echo ready; while :; do sleep 1; done' \
  >"$tmp/signal.stdout" 2>"$tmp/signal.stderr" &
capture_pid=$!
pids+=("$capture_pid")
wait_for_pattern ready "$tmp/signal.stdout"
kill -TERM "$capture_pid"
set +e
wait "$capture_pid"
signal_status=$?
set -e
[[ "$signal_status" == 143 ]]

# Internal cleanup gives a same-group descendant a bounded TERM grace before
# cancellation/escalation, so normal shutdown handlers can flush state.
graceful_dir="$tmp/graceful-descendant"
graceful_marker="$tmp/graceful-descendant.marker"
graceful_pid_file="$tmp/graceful-descendant.pid"
GRACEFUL_MARKER="$graceful_marker" GRACEFUL_PID_FILE="$graceful_pid_file" \
  "$helper" capture --source agent --log-dir "$graceful_dir" -- python3 - \
    >/dev/null 2>&1 <<'PY' &
import os
import pathlib
import signal
import time

read_fd, write_fd = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(read_fd)

    def stop(_signum, _frame):
        time.sleep(0.3)
        pathlib.Path(os.environ["GRACEFUL_MARKER"]).write_text("graceful")
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    os.write(write_fd, b"ready")
    os.close(write_fd)
    while True:
        signal.pause()
os.close(write_fd)
assert os.read(read_fd, 5) == b"ready"
os.close(read_fd)
pathlib.Path(os.environ["GRACEFUL_PID_FILE"]).write_text(str(pid))
os._exit(23)
PY
graceful_capture_pid=$!
pids+=("$graceful_capture_pid")
for _ in {1..100}; do
  ! kill -0 "$graceful_capture_pid" 2>/dev/null && break
  sleep 0.02
done
if kill -0 "$graceful_capture_pid" 2>/dev/null; then
  echo "capture did not honor the bounded descendant shutdown grace" >&2
  exit 1
fi
set +e
wait "$graceful_capture_pid"
graceful_status=$?
set -e
[[ "$graceful_status" == 23 ]]
[[ "$(cat "$graceful_marker")" == graceful ]]

# A child leader may exit while a descendant keeps its stdout/stderr pipes
# open. Capture terminates that process group and preserves the leader status
# without waiting for the descendant or requiring an external signal.
descendant_dir="$tmp/descendant-exit"
descendant_pid_file="$tmp/descendant.pid"
descendant_ready_file="$tmp/descendant.ready"
# The nested bash expands its own job PID and inherited fixture path.
# shellcheck disable=SC2016
DESCENDANT_PID_FILE="$descendant_pid_file" DESCENDANT_READY_FILE="$descendant_ready_file" \
  "$helper" capture --source agent --log-dir "$descendant_dir" -- \
    bash -c '(trap "" TERM; : >"$DESCENDANT_READY_FILE"; while :; do sleep 1; done) & echo $! >"$DESCENDANT_PID_FILE"; while [[ ! -e "$DESCENDANT_READY_FILE" ]]; do sleep 0.01; done; exit 23' \
    >/dev/null 2>&1 &
descendant_capture_pid=$!
pids+=("$descendant_capture_pid")
for _ in {1..100}; do
  ! kill -0 "$descendant_capture_pid" 2>/dev/null && break
  sleep 0.02
done
if kill -0 "$descendant_capture_pid" 2>/dev/null; then
  echo "capture exit hung on a surviving descendant's output pipes" >&2
  exit 1
fi
set +e
wait "$descendant_capture_pid"
descendant_status=$?
set -e
[[ "$descendant_status" == 23 ]]
jq -e 'select(.type == "process_exit") | .data.status == 23' \
  "$descendant_dir/agent.jsonl" >/dev/null
descendant_pid="$(cat "$descendant_pid_file")"
for _ in {1..50}; do
  ! kill -0 "$descendant_pid" 2>/dev/null && break
  sleep 0.02
done
if kill -0 "$descendant_pid" 2>/dev/null; then
  echo "capture left the wrapped child process group running" >&2
  exit 1
fi

# A daemonized descendant can escape the original process group while keeping
# its inherited pipes. Cancellable readers still let capture return; the test
# explicitly cleans up that intentionally escaped fixture process.
escaped_dir="$tmp/escaped-descendant"
escaped_pid_file="$tmp/escaped-descendant.pid"
ESCAPED_PID_FILE="$escaped_pid_file" \
  "$helper" capture --source agent --log-dir "$escaped_dir" -- python3 - \
    >/dev/null 2>&1 <<'PY' &
import os
import pathlib
import time

read_fd, write_fd = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(read_fd)
    os.setsid()
    os.write(write_fd, b"ready")
    os.close(write_fd)
    time.sleep(10)
    os._exit(0)
os.close(write_fd)
assert os.read(read_fd, 5) == b"ready"
os.close(read_fd)
pathlib.Path(os.environ["ESCAPED_PID_FILE"]).write_text(str(pid))
os._exit(19)
PY
escaped_capture_pid=$!
pids+=("$escaped_capture_pid")
for _ in {1..100}; do
  ! kill -0 "$escaped_capture_pid" 2>/dev/null && break
  sleep 0.02
done
if kill -0 "$escaped_capture_pid" 2>/dev/null; then
  echo "capture exit hung on an escaped descendant's output pipes" >&2
  exit 1
fi
set +e
wait "$escaped_capture_pid"
escaped_status=$?
set -e
[[ "$escaped_status" == 19 ]]
jq -e 'select(.type == "process_exit") | .data.status == 19' \
  "$escaped_dir/agent.jsonl" >/dev/null
escaped_pid="$(cat "$escaped_pid_file")"
pids+=("$escaped_pid")
kill -0 "$escaped_pid"
escaped_state="$(ps -o stat= -p "$escaped_pid" | tr -d ' ')"
[[ -n "$escaped_state" && "$escaped_state" != Z* ]]
kill -KILL "$escaped_pid" 2>/dev/null || true

# Build pure fixtures for every query source. Deliberately place auth/config
# files beside them: export must normalize events, never archive source state.
python3 - "$agent_root" <<'PY'
import json
import pathlib
import sqlite3
import sys

root = pathlib.Path(sys.argv[1])
home = root / "home" / "agent"
codex = home / ".codex" / "sessions" / "2026" / "01"
claude = home / ".claude" / "projects" / "fixture"
hermes = home / ".hermes"
(hermes / "logs").mkdir(parents=True)
codex.mkdir(parents=True)
claude.mkdir(parents=True)

(codex / "rollout.jsonl").write_text(
    "\n".join(json.dumps(record) for record in ({
        "timestamp": "2026-01-01T00:00:00Z",
        "type": "response_item",
        "message": "codex old-marker Bearer codex-bearer bare-query-secret ?token=url-secret Authorization: Basic auth-secret access_token=pattern-value-secret",
        "api_token": "codex-field-secret",
        "password": "password-secret",
        "apiKey": "api-key-secret",
        "accessToken": "access-token-secret",
    }, {
        "schema": "tx9.event.v1",
        "timestamp": "2026-01-02T00:00:00Z",
        "source": "executor",
        "message": "spoofed-native-source",
    }, {
        "schema": "tx9.event.v1",
        "timestamp": "2026-01-03T00:00:00Z",
        "source": "agent",
    })) + "\n",
    encoding="utf-8",
)
(claude / "session.jsonl").write_text(
    json.dumps({
        "timestamp": "2026-02-01T00:00:00Z",
        "type": "assistant",
        "message": {"content": [{"type": "text", "text": "claude needle _token=claude-query"}]},
    }) + "\n",
    encoding="utf-8",
)
(hermes / "logs" / "gateway.jsonl").write_text(
    json.dumps({
        "timestamp": "2026-03-01T00:00:00Z",
        "type": "gateway.notice",
        "message": "hermes gateway fixture",
    }) + "\n",
    encoding="utf-8",
)
(home / ".codex" / "auth.json").write_text('{"token":"must-not-export"}\n', encoding="utf-8")
(hermes / "config.yaml").write_text("api_token: must-not-export\n", encoding="utf-8")

db = sqlite3.connect(hermes / "state.db")
db.executescript("""
CREATE TABLE sessions(id TEXT, created_at TEXT, title TEXT);
CREATE TABLE messages(id TEXT, session_id TEXT, created_at TEXT, role TEXT, content TEXT, api_token TEXT);
INSERT INTO sessions VALUES('s1', '2026-03-01T00:00:01Z', 'Hermes fixture session');
INSERT INTO messages VALUES('m1', 's1', '2026-03-01T00:00:02Z', 'assistant', 'Hermes DB message', 'db-field-secret');
""")
db.commit()
db.close()
PY

# A stopped/crashed WAL database can have a WAL but no SHM on a read-only
# volume. The direct read-only open fails there; the helper must recover via
# its no-follow writable snapshot without dropping the committed message.
python3 - "$agent_root/home/agent/.hermes/state.db" <<'PY'
import os
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA wal_autocheckpoint=0")
db.execute(
    "INSERT INTO messages VALUES(?, ?, ?, ?, ?, ?)",
    ("m-wal", "s1", "2026-03-01T00:00:03Z", "assistant", "Hermes stale WAL message", "wal-secret"),
)
db.commit()
os._exit(0)
PY
rm -f "$agent_root/home/agent/.hermes/state.db-shm"
chmod 0500 "$agent_root/home/agent/.hermes"
"$helper" query --agent-root "$agent_root" --executor-root "$executor_root" \
  --box fixture-box --source hermes --tail 100 --json >"$tmp/wal-query.jsonl"
chmod 0700 "$agent_root/home/agent/.hermes"
grep -q 'Hermes stale WAL message' "$tmp/wal-query.jsonl"

# If a live read fails after emitting one table, replay the writable snapshot
# and suppress only rows that already escaped. Identical legitimate rows keep
# their multiplicity instead of being collapsed by the recovery pass.
python3 - "$helper" "$tmp/partial-hermes" <<'PY'
from collections import Counter
import importlib.machinery
import importlib.util
import pathlib
import sqlite3
import sys

loader = importlib.machinery.SourceFileLoader("tx9_logs_partial_fallback", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
root = pathlib.Path(sys.argv[2])
root.mkdir()
path = root / "state.db"
with sqlite3.connect(path) as database:
    database.executescript("""
        CREATE TABLE sessions(id TEXT, created_at TEXT, title TEXT);
        CREATE TABLE messages(created_at TEXT, content TEXT);
        INSERT INTO sessions VALUES('s1', '2026-03-01T00:00:01Z', 'partial session');
        INSERT INTO messages VALUES('2026-03-01T00:00:02Z', 'snapshot message');
        INSERT INTO messages VALUES('2026-03-01T00:00:02Z', 'snapshot message');
    """)

original_events = module.hermes_database_events
calls = 0


def partial_events(connection, *, path, box, modified_at):
    global calls
    calls += 1
    call_number = calls
    for event in original_events(
        connection, path=path, box=box, modified_at=modified_at
    ):
        yield event
        if call_number == 1 and event["type"] == "hermes.message":
            raise sqlite3.DatabaseError("injected failure after partial read")


module.hermes_database_events = partial_events
events = list(module.read_hermes_db(path, root=root, box="fixture-box"))

assert calls == 2
assert Counter((event["type"], event["message"]) for event in events) == Counter({
    ("hermes.session", "partial session"): 1,
    ("hermes.message", "snapshot message"): 2,
})
assert any("recovered remaining rows" in warning for warning in module.WARNINGS)
PY

python3 - "$agent_root/logs" <<'PY'
import pathlib
import sys

log_dir = pathlib.Path(sys.argv[1])
for name, label in (
    ("workload.log.2", "legacy workload oldest rotation"),
    ("workload.log.1", "legacy workload newer rotation"),
    ("workload.log", "legacy workload active history"),
):
    pathlib.Path(log_dir / name).write_text(
        "".join(f"{label} line {index:02d} {'z' * 20}\n" for index in range(1, 11))
    )
PY
TX9_BOX_NAME=fixture-box "$helper" capture --source agent --log-dir "$agent_root/logs" \
  --max-bytes 1024 --max-files 3 -- \
  bash -c 'printf "agent supervisor fixture\n"' >/dev/null
for message in \
  'legacy workload oldest rotation line 01 zzzzzzzzzzzzzzzzzzzz' \
  'legacy workload newer rotation line 01 zzzzzzzzzzzzzzzzzzzz' \
  'legacy workload active history line 01 zzzzzzzzzzzzzzzzzzzz' \
  'agent supervisor fixture'; do
  grep -R -Fq -- "$message" "$agent_root/logs"
done
[[ ! -e "$agent_root/logs/workload.log.1" ]]
[[ ! -e "$agent_root/logs/workload.log.2" ]]
[[ "$(find "$agent_root/logs" -maxdepth 1 -type f -name 'workload.legacy-*.log' | wc -l | tr -d ' ')" == 3 ]]

printf 'legacy Hermes rotated history\n' >"$agent_root/logs/hermes-gateway.log.1"
printf 'legacy Hermes active history\n' >"$agent_root/logs/hermes-gateway.log"
TX9_BOX_NAME=fixture-box "$helper" capture --source hermes --log-dir "$agent_root/logs" -- \
  bash -c 'printf "modern Hermes supervisor fixture\n"' >/dev/null
[[ "$(find "$agent_root/logs" -maxdepth 1 -type f -name 'hermes-gateway.legacy-*.log' | wc -l | tr -d ' ')" == 2 ]]

# Every source path is agent-controlled while the query helper mounts both
# volumes. File and parent-directory symlinks must never cross that boundary.
mkdir -p "$executor_root/private"
printf '{"timestamp":"2026-04-01T00:00:00Z","message":"executor-volume-secret"}\n' \
  >"$executor_root/private/credential.jsonl"
ln -s "$executor_root/private/credential.jsonl" \
  "$agent_root/home/agent/.codex/sessions/2026/01/escape.jsonl"
ln -s "$executor_root/private" \
  "$agent_root/home/agent/.codex/sessions/escape-directory"
ln -s "$executor_root/private/credential.jsonl" \
  "$agent_root/home/agent/.claude/projects/fixture/escape.jsonl"
ln -s "$executor_root/private/credential.jsonl" \
  "$agent_root/home/agent/.hermes/logs/escape.jsonl"
ln -s "$executor_root/private/credential.jsonl" "$agent_root/logs/escape.log"
if "$helper" query --agent-root "$agent_root" --executor-root "$executor_root" \
    --box fixture-box --source all --tail 1000 --json | grep -q executor-volume-secret; then
  echo "query followed a symlink across the agent/Executor volume boundary" >&2
  exit 1
fi

KEY_SECRET=access_token SHORT_TOKEN=x QUERY_TOKEN=bare-query-secret "$helper" query \
  --agent-root "$agent_root" --executor-root "$executor_root" --box fixture-box \
  --source agent,executor,hermes,codex,cc --tail 100 --json >"$tmp/query.jsonl"
jq -e -s 'map(.source) | unique == ["agent", "claude", "codex", "executor", "hermes"]' \
  "$tmp/query.jsonl" >/dev/null
jq -e -s 'all(.[]; .schema == "tx9.event.v1" and .box == "fixture-box")' \
  "$tmp/query.jsonl" >/dev/null
if grep -nE -- 'codex-bearer|bare-query-secret|codex-field-secret|claude-query|db-field-secret' "$tmp/query.jsonl"; then
  echo "query emitted an unredacted token" >&2
  exit 1
fi
if grep -nE -- 'url-secret|auth-secret|password-secret|api-key-secret|access-token-secret|pattern-value-secret' \
    "$tmp/query.jsonl"; then
  echo "query emitted a common unredacted credential form" >&2
  exit 1
fi
for message in \
  'legacy workload oldest rotation line 01 zzzzzzzzzzzzzzzzzzzz' \
  'legacy workload newer rotation line 01 zzzzzzzzzzzzzzzzzzzz' \
  'legacy workload active history line 01 zzzzzzzzzzzzzzzzzzzz' \
  'agent supervisor fixture'; do
  [[ "$(jq -r --arg message "$message" 'select(.message == $message) | .message' "$tmp/query.jsonl" | wc -l | tr -d ' ')" == 1 ]]
done
for message in \
  'legacy Hermes rotated history' \
  'legacy Hermes active history' \
  'modern Hermes supervisor fixture'; do
  jq -e --arg message "$message" \
    'select(.message == $message) | .source == "hermes"' "$tmp/query.jsonl" >/dev/null
  [[ "$(jq -r --arg message "$message" 'select(.message == $message) | .message' "$tmp/query.jsonl" | wc -l | tr -d ' ')" == 1 ]]
done
"$helper" query --agent-root "$agent_root" --executor-root "$executor_root" \
  --box fixture-box --source agent --tail 1000 --grep 'legacy Hermes' --json \
  >"$tmp/legacy-hermes-as-agent.jsonl"
[[ ! -s "$tmp/legacy-hermes-as-agent.jsonl" ]]
jq -e 'select(.message == "spoofed-native-source") | .source == "codex" and .stream == "event" and .type == "codex.event"' \
  "$tmp/query.jsonl" >/dev/null
# Records with no extractable text used to surface as empty-message events;
# they are pure noise (~80% of codex events on live boxes) and are dropped.
if jq -e 'select(.source == "codex" and .timestamp == "2026-01-03T00:00:00.000Z")' \
    "$tmp/query.jsonl" >/dev/null; then
  echo "query emitted an empty-message native event" >&2
  exit 1
fi
"$helper" query --agent-root "$agent_root" --executor-root "$executor_root" \
  --box fixture-box --source codex --tail 100 >"$tmp/codex.txt"
grep -q 'spoofed-native-source' "$tmp/codex.txt"

# Aliases, timestamp filtering, case-insensitive grep, text output, and the
# explicit no-redact escape hatch are independently fixture-testable.
"$helper" query --agent-root "$agent_root" --executor-root "$executor_root" \
  --box fixture-box --source cc --tail 10 --json >"$tmp/claude.jsonl"
jq -e -s 'length == 1 and all(.[]; .source == "claude")' "$tmp/claude.jsonl" >/dev/null
"$helper" query --agent-root "$agent_root" --executor-root "$executor_root" \
  --box fixture-box --source codex,claude --tail 10 --since 2026-02-01T00:00:00Z --json \
  >"$tmp/since.jsonl"
if grep -q old-marker "$tmp/since.jsonl"; then
  echo "--since retained an older event" >&2
  exit 1
fi
"$helper" query --agent-root "$agent_root" --executor-root "$executor_root" \
  --box fixture-box --source all --tail 10 --grep NEEDLE >"$tmp/grep.txt"
grep -q '\[fixture-box/claude/event\].*needle' "$tmp/grep.txt"
QUERY_TOKEN=bare-query-secret "$helper" query \
  --agent-root "$agent_root" --executor-root "$executor_root" --box fixture-box \
  --source codex --tail 10 --json --no-redact >"$tmp/no-redact.jsonl"
grep -q 'bare-query-secret' "$tmp/no-redact.jsonl"
grep -q 'codex-field-secret' "$tmp/no-redact.jsonl"

# Export is a gzip tar streamed to stdout containing exactly a manifest and
# normalized JSONL. No source database, auth, config, or raw files can enter it.
KEY_SECRET=access_token SHORT_TOKEN=x QUERY_TOKEN=bare-query-secret "$helper" export \
  --agent-root "$agent_root" --executor-root "$executor_root" --box fixture-box \
  --source all >"$tmp/export.tar.gz"
gzip -t "$tmp/export.tar.gz"
tar -tzf "$tmp/export.tar.gz" >"$tmp/export.members"
[[ "$(sort "$tmp/export.members")" == $'events.jsonl\nmanifest.json' ]]
mkdir "$tmp/exported"
tar -xzf "$tmp/export.tar.gz" -C "$tmp/exported"
jq -e '.schema == "tx9.log-export.v1" and .box == "fixture-box" and .event_count > 0 and .complete == true and .warnings == [] and .members == ["manifest.json", "events.jsonl"]' \
  "$tmp/exported/manifest.json" >/dev/null
jq -e -s 'length > 0 and all(.[]; .schema == "tx9.event.v1")' "$tmp/exported/events.jsonl" >/dev/null
for message in \
  'legacy workload oldest rotation line 01 zzzzzzzzzzzzzzzzzzzz' \
  'legacy workload newer rotation line 01 zzzzzzzzzzzzzzzzzzzz' \
  'legacy workload active history line 01 zzzzzzzzzzzzzzzzzzzz' \
  'agent supervisor fixture'; do
  [[ "$(jq -r --arg message "$message" 'select(.message == $message) | .message' "$tmp/exported/events.jsonl" | wc -l | tr -d ' ')" == 1 ]]
done
for message in \
  'legacy Hermes rotated history' \
  'legacy Hermes active history' \
  'modern Hermes supervisor fixture'; do
  jq -e --arg message "$message" \
    'select(.message == $message) | .source == "hermes"' "$tmp/exported/events.jsonl" >/dev/null
  [[ "$(jq -r --arg message "$message" 'select(.message == $message) | .message' "$tmp/exported/events.jsonl" | wc -l | tr -d ' ')" == 1 ]]
done
if grep -R -nE -- 'must-not-export|bare-query-secret|codex-field-secret|claude-query|db-field-secret|pattern-value-secret' "$tmp/exported"; then
  echo "export contained source state or an unredacted token" >&2
  exit 1
fi

# Hostile native records stay bounded and cannot impersonate the Executor
# volume. An Executor-only query never even parses agent-volume runtime files.
hostile_agent="$tmp/hostile-agent"
mkdir -p "$hostile_agent/logs"
python3 - "$hostile_agent/logs" <<'PY'
import json
import pathlib
import sys

logs = pathlib.Path(sys.argv[1])
nested = "leaf"
for _ in range(100):
    nested = [nested]
(logs / "agent.jsonl").write_text(
    json.dumps({
        "schema": "tx9.event.v1",
        "timestamp": "2026-04-01T00:00:00Z",
        "source": "executor",
        "stream": "event",
        "type": "fixture",
        "message": "bounded-deep-record",
        "data": nested,
    }) + "\n" + json.dumps({
        "schema": "tx9.event.v1",
        "timestamp": "2026-04-01T00:00:00.500Z",
        "source": "agent",
        "message": '["hostile-nested-number",' + "9" * 5000 + "]",
    }) + "\n" + "[" * 1200 + "0" + "]" * 1200 + "\n"
    + '{"value":' + "9" * 5000 + "}\n",
    encoding="utf-8",
)
(logs / "executor.jsonl").write_text(
    json.dumps({
        "schema": "tx9.event.v1",
        "timestamp": "2026-04-01T00:00:01Z",
        "source": "executor",
        "message": "forged-executor-source",
    }) + "\n",
    encoding="utf-8",
)
(logs / "oversized-search-secret.log").write_bytes(
    b"z" * (2 * 1024 * 1024 + 128) + b"\n"
)
(logs / "oversized-cr-boundary.log").write_bytes(
    b"q" * (2 * 1024 * 1024) + b"\r" + b"must-not-escape-oversized-record\n"
)
PY
"$helper" query --agent-root "$hostile_agent" --executor-root "$executor_root" \
  --box fixture-box --source executor --tail 100 --json \
  >"$tmp/executor-only.jsonl" 2>"$tmp/executor-only.stderr"
grep -q 'executor-out' "$tmp/executor-only.jsonl"
[[ ! -s "$tmp/executor-only.stderr" ]]
if grep -q 'forged-executor-source' "$tmp/executor-only.jsonl"; then
  echo "agent-volume record impersonated the Executor source" >&2
  exit 1
fi
"$helper" query --agent-root "$hostile_agent" --executor-root "$executor_root" \
  --box fixture-box --source all --tail 1000 --json \
  >"$tmp/hostile-all.jsonl" 2>"$tmp/hostile-all.stderr"
grep -q '\[TRUNCATED\]' "$tmp/hostile-all.jsonl"
grep -q 'hostile-nested-number' "$tmp/hostile-all.jsonl"
grep -q 'record omitted because it exceeds the query size limit' "$tmp/hostile-all.jsonl"
grep -q 'omitted oversized source record' "$tmp/hostile-all.stderr"
if grep -q 'must-not-escape-oversized-record' "$tmp/hostile-all.jsonl"; then
  echo "query emitted the tail of an oversized CR-boundary record" >&2
  exit 1
fi
jq -e 'select(.message == "forged-executor-source") | .source == "agent" and .stream == "event" and .type == "output"' \
  "$tmp/hostile-all.jsonl" >/dev/null

# Default export redaction also covers operator-supplied filter metadata and
# warnings whose agent-controlled source paths contain the exact query token.
QUERY_TOKEN=search-secret "$helper" export \
  --agent-root "$hostile_agent" --executor-root "$executor_root" --box fixture-box \
  --source agent --grep search-secret >"$tmp/redacted-metadata.tar.gz" \
  2>"$tmp/redacted-metadata.stderr"
mkdir "$tmp/redacted-metadata"
tar -xzf "$tmp/redacted-metadata.tar.gz" -C "$tmp/redacted-metadata"
if grep -R -nF -- 'search-secret' "$tmp/redacted-metadata" "$tmp/redacted-metadata.stderr"; then
  echo "export metadata or warnings exposed an exact query token" >&2
  exit 1
fi
jq -e '.filters.grep == "[REDACTED]" and .complete == false and (.warnings | length > 0)' \
  "$tmp/redacted-metadata/manifest.json" >/dev/null

# Remote Executor logs live on the other volume; hb must point users to the
# host command instead of following a nonexistent local executor.log forever.
remote_hint="$({
  HB_DATA="$agent_root" EXECUTOR_HOST=executor TX9_BOX_NAME=fixture-box \
    bash -c 'source "$1"; logs executor' _ "$PROJECT_ROOT/guest/hb"
} 2>&1)"
grep -q 'tx9 logs fixture-box --source executor' <<<"$remote_hint"

# Consecutive identical lines collapse into one structured event plus a
# repeat-count summary; the raw log and the mirrored stream stay faithful,
# and blank lines never become structured events.
dedup_dir="$tmp/dedup"
"$helper" capture --source executor --log-dir "$dedup_dir" -- \
  bash -c 'printf "same-line\nsame-line\nsame-line\n\n   \ndifferent-line\n"' \
  >"$tmp/dedup.stdout"
[[ "$(grep -c 'same-line' "$tmp/dedup.stdout")" == 3 ]]
[[ "$(grep -c 'same-line' "$dedup_dir/executor.log")" == 3 ]]
[[ "$(jq -r 'select(.type == "output" and .message == "same-line") | .message' \
  "$dedup_dir/executor.jsonl" | wc -l | tr -d ' ')" == 1 ]]
jq -e 'select(.type == "output_repeated") | .data.count == 2 and .data.message == "same-line"' \
  "$dedup_dir/executor.jsonl" >/dev/null
jq -e 'select(.type == "output" and .message == "different-line")' \
  "$dedup_dir/executor.jsonl" >/dev/null
if jq -e 'select(.type == "output" and (.message | gsub("\\s"; "") == ""))' \
    "$dedup_dir/executor.jsonl" >/dev/null; then
  echo "capture persisted a blank structured event" >&2
  exit 1
fi

# Repeat summaries retain the repeated record's severity so matching query and
# export thresholds do not hide the count.
repeat_home="$tmp/repeat-agent"
mkdir -p "$repeat_home/logs"
"$helper" capture --source agent --log-dir "$repeat_home/logs" -- \
  bash -c 'printf "WARNING repeat-warning\nWARNING repeat-warning\nWARNING repeat-warning\nERROR repeat-error\nERROR repeat-error\nERROR repeat-error\n"' \
  >/dev/null
"$helper" query --agent-root "$repeat_home" --executor-root "$executor_root" \
  --box fixture-box --source agent --tail 100 --level warn --json >"$tmp/repeat-level.jsonl"
jq -e 'select(.type == "output_repeated" and .data.message == "WARNING repeat-warning") |
  .level == "warn" and .data.count == 2' "$tmp/repeat-level.jsonl" >/dev/null
jq -e 'select(.type == "output_repeated" and .data.message == "ERROR repeat-error") |
  .level == "error" and .data.count == 2' "$tmp/repeat-level.jsonl" >/dev/null
"$helper" export --agent-root "$repeat_home" --executor-root "$executor_root" \
  --box fixture-box --source agent --level warn >"$tmp/repeat-level.tar.gz"
mkdir "$tmp/repeat-level"
tar -xzf "$tmp/repeat-level.tar.gz" -C "$tmp/repeat-level"
jq -e 'select(.type == "output_repeated" and .level == "warn")' \
  "$tmp/repeat-level/events.jsonl" >/dev/null
jq -e 'select(.type == "output_repeated" and .level == "error")' \
  "$tmp/repeat-level/events.jsonl" >/dev/null
jq -e '.filters.level == "warn"' "$tmp/repeat-level/manifest.json" >/dev/null

# Hermes raw logs group continuation lines (tracebacks, embedded files, ps
# output) into the record that introduced them, parse severity levels, withhold
# a possibly mid-write tail, and never turn loadavg-like numeric fragments into
# 1970 timestamps.
grouping_home="$tmp/grouping-agent"
hermes_logs="$grouping_home/home/agent/.hermes/logs"
mkdir -p "$hermes_logs" "$grouping_home/logs"
printf '%s\n' \
  'WARNING gateway.run: first record' \
  '  continuation detail A' \
  '  continuation detail B' \
  '0.16 0.16 0.11 2/1393 31834' \
  '2026-05-01T00:00:00Z INFO plain second record' \
  '2026-05-01T00:00:01Z plain unlabeled record' \
  'ERROR loop: third record' \
  >"$hermes_logs/gateway.log"
printf 'WARNING tail: partial record without newline' >>"$hermes_logs/gateway.log"
printf '%s\n' 'WARNING grouped prefix' >"$hermes_logs/continuation.log"
printf '  ' >>"$hermes_logs/continuation.log"
"$helper" query --agent-root "$grouping_home" --executor-root "$executor_root" \
  --box fixture-box --source hermes --tail 100 --json >"$tmp/grouping.jsonl"
jq -e 'select(.message | startswith("WARNING gateway.run: first record")) |
  (.message | contains("continuation detail B")) and
  (.message | contains("0.16 0.16 0.11")) and
  .level == "warn"' "$tmp/grouping.jsonl" >/dev/null
jq -e 'select(.message | contains("third record")) | .level == "error"' \
  "$tmp/grouping.jsonl" >/dev/null
if grep -q '"timestamp":"1970' "$tmp/grouping.jsonl"; then
  echo "a numeric fragment became an epoch timestamp" >&2
  exit 1
fi
if grep -q 'partial record without newline' "$tmp/grouping.jsonl"; then
  echo "query emitted the unterminated tail of an active raw log" >&2
  exit 1
fi
if grep -q 'WARNING grouped prefix' "$tmp/grouping.jsonl"; then
  echo "query emitted a grouped record with an incomplete continuation" >&2
  exit 1
fi
[[ "$(jq -r 'select(.stream == "log") | .message' "$tmp/grouping.jsonl" | grep -c 'continuation detail A')" == 1 ]]

# An oversized active tail still reports a bounded truncation marker and does
# not hide the preceding complete grouped record.
oversized_grouping_home="$tmp/oversized-grouping-agent"
oversized_hermes_logs="$oversized_grouping_home/home/agent/.hermes/logs"
mkdir -p "$oversized_hermes_logs" "$oversized_grouping_home/logs"
python3 - "$oversized_hermes_logs/oversized.log" <<'PY'
import sys

with open(sys.argv[1], "wb") as handle:
    handle.write(b"WARNING preceding oversized record\n")
    handle.write(b"ERROR " + b"x" * (2 * 1024 * 1024))
PY
"$helper" query --agent-root "$oversized_grouping_home" \
  --executor-root "$executor_root" --box fixture-box --source hermes --tail 100 \
  --json >"$tmp/oversized-grouping.jsonl" 2>"$tmp/oversized-grouping.stderr"
grep -q 'preceding oversized record' "$tmp/oversized-grouping.jsonl"
jq -e 'select(.type == "truncated" and
  .message == "record omitted because it exceeds the query size limit")' \
  "$tmp/oversized-grouping.jsonl" >/dev/null
grep -q 'omitted oversized source record' "$tmp/oversized-grouping.stderr"

printf 'incomplete continuation\n' >>"$hermes_logs/continuation.log"
"$helper" query --agent-root "$grouping_home" --executor-root "$executor_root" \
  --box fixture-box --source hermes --tail 100 --json >"$tmp/grouping-complete.jsonl"
jq -e 'select(.message | startswith("WARNING grouped prefix")) |
  (.message | contains("incomplete continuation")) and .level == "warn"' \
  "$tmp/grouping-complete.jsonl" >/dev/null

# --level keeps this level and above; events without a level count as info in
# both queries and exported bundles.
"$helper" query --agent-root "$grouping_home" --executor-root "$executor_root" \
  --box fixture-box --source hermes --tail 100 --level warn --json >"$tmp/level-warn.jsonl"
jq -e 'select(.level == "warn")' "$tmp/level-warn.jsonl" >/dev/null
jq -e 'select(.level == "error")' "$tmp/level-warn.jsonl" >/dev/null
if grep -qE 'plain second record|plain unlabeled record' "$tmp/level-warn.jsonl"; then
  echo "--level warn kept an info or unlabeled event" >&2
  exit 1
fi
"$helper" query --agent-root "$grouping_home" --executor-root "$executor_root" \
  --box fixture-box --source hermes --tail 100 --level info --json >"$tmp/level-info.jsonl"
grep -q 'plain second record' "$tmp/level-info.jsonl"
grep -q 'plain unlabeled record' "$tmp/level-info.jsonl"
"$helper" export --agent-root "$grouping_home" --executor-root "$executor_root" \
  --box fixture-box --source hermes --level warn >"$tmp/level-warn.tar.gz"
mkdir "$tmp/level-warn"
tar -xzf "$tmp/level-warn.tar.gz" -C "$tmp/level-warn"
jq -e 'select(.level == "warn")' "$tmp/level-warn/events.jsonl" >/dev/null
jq -e 'select(.level == "error")' "$tmp/level-warn/events.jsonl" >/dev/null
if grep -qE 'plain second record|plain unlabeled record' "$tmp/level-warn/events.jsonl"; then
  echo "--level warn export kept an info or unlabeled event" >&2
  exit 1
fi
jq -e '.filters.level == "warn"' "$tmp/level-warn/manifest.json" >/dev/null

# Text output renders grouped records with indented continuation lines and a
# level segment in the header when one is known.
"$helper" query --agent-root "$grouping_home" --executor-root "$executor_root" \
  --box fixture-box --source hermes --tail 100 >"$tmp/grouping.txt"
grep -q '\[fixture-box/hermes/log/warn\] WARNING gateway.run: first record' "$tmp/grouping.txt"
grep -q '^      continuation detail A' "$tmp/grouping.txt"

# A schema-v1 record with a bogus level value has it dropped rather than
# forwarded, and a valid one is preserved.
level_home="$tmp/level-agent"
mkdir -p "$level_home/logs"
printf '%s\n' \
  '{"schema":"tx9.event.v1","timestamp":"2026-05-02T00:00:00Z","source":"agent","stream":"event","type":"fixture","message":"bogus-level-record","level":"loud"}' \
  '{"schema":"tx9.event.v1","timestamp":"2026-05-02T00:00:01Z","source":"agent","stream":"event","type":"fixture","message":"valid-level-record","level":"warning"}' \
  '{"schema":"tx9.event.v1","timestamp":"2026-05-02T00:00:02Z","source":"agent","stream":"stdout","type":"output_repeated","message":"previous line repeated 2 more times","data":{"count":2,"message":"ERROR historical repeated output"}}' \
  '{"schema":"tx9.event.v1","timestamp":"2026-05-02T00:00:03Z","source":"agent","stream":"event","type":"fixture","message":"   "}' \
  >"$level_home/logs/agent.jsonl"
"$helper" query --agent-root "$level_home" --executor-root "$executor_root" \
  --box fixture-box --source agent --tail 100 --json >"$tmp/level-schema.jsonl"
jq -e 'select(.message == "bogus-level-record") | has("level") | not' \
  "$tmp/level-schema.jsonl" >/dev/null
jq -e 'select(.message == "valid-level-record") | .level == "warn"' \
  "$tmp/level-schema.jsonl" >/dev/null
jq -e 'select(.type == "output_repeated") |
  .level == "error" and .data.message == "ERROR historical repeated output"' \
  "$tmp/level-schema.jsonl" >/dev/null
"$helper" query --agent-root "$level_home" --executor-root "$executor_root" \
  --box fixture-box --source agent --tail 100 --level error --json \
  >"$tmp/level-schema-error.jsonl"
jq -e 'select(.type == "output_repeated" and .level == "error")' \
  "$tmp/level-schema-error.jsonl" >/dev/null
if jq -e 'select(.type == "fixture" and (.message | gsub("\\s"; "") == ""))' \
    "$tmp/level-schema.jsonl" >/dev/null; then
  echo "query emitted a whitespace-only schema-v1 event" >&2
  exit 1
fi

# A complete active JSONL object is safe to parse without a trailing newline;
# a partial object remains hidden until a later query can read it completely.
complete_json_home="$tmp/complete-json-agent"
mkdir -p "$complete_json_home/logs"
printf '%s' \
  '{"schema":"tx9.event.v1","timestamp":"2026-05-03T00:00:00Z","source":"agent","stream":"event","type":"fixture","message":"complete JSON without newline","level":"error"}' \
  >"$complete_json_home/logs/agent.jsonl"
"$helper" query --agent-root "$complete_json_home" --executor-root "$executor_root" \
  --box fixture-box --source agent --tail 100 --json >"$tmp/complete-json.jsonl"
jq -e 'select(.message == "complete JSON without newline") | .level == "error"' \
  "$tmp/complete-json.jsonl" >/dev/null
"$helper" export --agent-root "$complete_json_home" --executor-root "$executor_root" \
  --box fixture-box --source agent --level error >"$tmp/complete-json.tar.gz"
mkdir "$tmp/complete-json"
tar -xzf "$tmp/complete-json.tar.gz" -C "$tmp/complete-json"
jq -e 'select(.message == "complete JSON without newline")' \
  "$tmp/complete-json/events.jsonl" >/dev/null
jq -e '.event_count == 1 and .filters.level == "error"' \
  "$tmp/complete-json/manifest.json" >/dev/null

partial_json_home="$tmp/partial-json-agent"
mkdir -p "$partial_json_home/logs"
printf '%s' \
  '{"schema":"tx9.event.v1","timestamp":"2026-05-03T00:00:01Z","message":"partial JSON without newline"' \
  >"$partial_json_home/logs/agent.jsonl"
"$helper" query --agent-root "$partial_json_home" --executor-root "$executor_root" \
  --box fixture-box --source agent --tail 100 --json >"$tmp/partial-json.jsonl" \
  2>"$tmp/partial-json.stderr"
if grep -q 'partial JSON without newline' "$tmp/partial-json.jsonl"; then
  echo "query emitted a partial active JSONL record" >&2
  exit 1
fi
grep -q 'ignored unterminated active JSONL record' "$tmp/partial-json.stderr"
printf '}\n' >>"$partial_json_home/logs/agent.jsonl"
"$helper" query --agent-root "$partial_json_home" --executor-root "$executor_root" \
  --box fixture-box --source agent --tail 100 --json >"$tmp/completed-json.jsonl"
jq -e 'select(.message == "partial JSON without newline")' \
  "$tmp/completed-json.jsonl" >/dev/null

echo "log capture/query/export regression checks passed"
