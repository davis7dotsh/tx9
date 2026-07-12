#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

helper="$PROJECT_ROOT/guest/tx9-logs"
agent_root="$tmp/agent"
executor_root="$tmp/executor"
mkdir -p "$agent_root/logs" "$executor_root/logs"

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
if rg -n 'bearer-secret|query-secret|param-secret|exact-capture-secret|exact-api-key-secret|exact-client-secret|cookie-first|cookie-second|json-secret|pw-secret' \
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
if rg -n 'multiline-first-half|multiline-second-half' \
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
if rg -n "$boundary_secret" "$tmp/boundary.stdout" "$boundary_dir"; then
  echo "capture exposed an exact token across a chunk boundary" >&2
  exit 1
fi
grep -q '\[REDACTED\]tail' "$tmp/boundary.stdout"

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
if rg -n "$overlap_secret" "$tmp/overlap-secret.stdout" "$overlap_dir"; then
  echo "capture split and exposed a self-overlapping exact secret" >&2
  exit 1
fi
grep -q '\[REDACTED\]' "$tmp/overlap-secret.stdout"

# Pattern recognition runs before exact replacement. An exact secret equal to
# the key name must not erase the `token=` cue and expose its following value.
context_dir="$tmp/exact-pattern-context"
KEY_SECRET=token \
  "$helper" capture --source agent --log-dir "$context_dir" -- \
    bash -c 'printf "token=pattern-value-secret\n"' \
    >"$tmp/exact-pattern-context.stdout"
if rg -n 'pattern-value-secret' "$tmp/exact-pattern-context.stdout" "$context_dir"; then
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
if rg -n 'bearer-boundary-secret|authorization-boundary-secret|cookie-boundary-secret|token-boundary-secret|password-boundary-secret|namespaced-auth-secret|namespaced-cookie-secret|namespaced-bearer-secret' \
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

# A child leader may exit while a descendant keeps its stdout/stderr pipes
# open. Shutdown still targets the original process group so reader joins do
# not hang until that descendant exits on its own.
descendant_dir="$tmp/descendant-signal"
"$helper" capture --source agent --log-dir "$descendant_dir" -- \
  bash -c '(sleep 5) & exit 0' >/dev/null 2>&1 &
descendant_capture_pid=$!
pids+=("$descendant_capture_pid")
sleep 0.1
kill -TERM "$descendant_capture_pid"
for _ in {1..50}; do
  ! kill -0 "$descendant_capture_pid" 2>/dev/null && break
  sleep 0.02
done
if kill -0 "$descendant_capture_pid" 2>/dev/null; then
  echo "capture shutdown hung on a surviving descendant's output pipes" >&2
  exit 1
fi
set +e
wait "$descendant_capture_pid"
descendant_status=$?
set -e
[[ "$descendant_status" == 143 ]]

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
        "message": "codex old-marker Bearer codex-bearer bare-query-secret ?token=url-secret Authorization: Basic auth-secret token=pattern-value-secret",
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

printf 'legacy workload history\n' >"$agent_root/logs/workload.log"
TX9_BOX_NAME=fixture-box "$helper" capture --source agent --log-dir "$agent_root/logs" -- \
  bash -c 'printf "agent supervisor fixture\n"' >/dev/null
grep -q 'legacy workload history' "$agent_root/logs/agent.jsonl"

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

KEY_SECRET=token QUERY_TOKEN=bare-query-secret "$helper" query \
  --agent-root "$agent_root" --executor-root "$executor_root" --box fixture-box \
  --source agent,executor,hermes,codex,cc --tail 100 --json >"$tmp/query.jsonl"
jq -e -s 'map(.source) | unique == ["agent", "claude", "codex", "executor", "hermes"]' \
  "$tmp/query.jsonl" >/dev/null
jq -e -s 'all(.[]; .schema == "tx9.event.v1" and .box == "fixture-box")' \
  "$tmp/query.jsonl" >/dev/null
if rg -n 'codex-bearer|bare-query-secret|codex-field-secret|claude-query|db-field-secret' "$tmp/query.jsonl"; then
  echo "query emitted an unredacted token" >&2
  exit 1
fi
if rg -n 'url-secret|auth-secret|password-secret|api-key-secret|access-token-secret|pattern-value-secret' \
    "$tmp/query.jsonl"; then
  echo "query emitted a common unredacted credential form" >&2
  exit 1
fi
grep -q 'legacy workload history' "$tmp/query.jsonl"
jq -e 'select(.message == "spoofed-native-source") | .source == "codex" and .stream == "event" and .type == "codex.event"' \
  "$tmp/query.jsonl" >/dev/null
jq -e 'select(.source == "codex" and .timestamp == "2026-01-03T00:00:00.000Z") | .stream == "event" and .type == "codex.event" and .message == ""' \
  "$tmp/query.jsonl" >/dev/null
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
KEY_SECRET=token QUERY_TOKEN=bare-query-secret "$helper" export \
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
if rg -n 'must-not-export|bare-query-secret|codex-field-secret|claude-query|db-field-secret|pattern-value-secret' "$tmp/exported"; then
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
if rg -n 'search-secret' "$tmp/redacted-metadata" "$tmp/redacted-metadata.stderr"; then
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

echo "log capture/query/export regression checks passed"
