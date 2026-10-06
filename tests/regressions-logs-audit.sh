#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

python3 - "$PROJECT_ROOT/guest/tx9-logs" "$tmp" <<'PY'
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile

helper = Path(sys.argv[1])
root = Path(sys.argv[2])
loader = importlib.machinery.SourceFileLoader("logs_audit", str(helper))
spec = importlib.util.spec_from_loader(loader.name, loader)
logs = importlib.util.module_from_spec(spec)
loader.exec_module(logs)
agent = root / "agent"
executor = root / "executor"
(agent / "logs").mkdir(parents=True)
(executor / "logs").mkdir(parents=True)


def write(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)


def record(message, timestamp="2026-10-04T12:00:00Z", **extra):
    return json.dumps({"schema": logs.SCHEMA, "message": message, "timestamp": timestamp, **extra}) + "\n"


def command(action, *options, environment=None):
    result = subprocess.run(
        [sys.executable, str(helper), action, "--agent-root", str(agent),
         "--executor-root", str(executor), "--box", "fixture", *options],
        capture_output=True, env=environment, check=True,
    )
    assert b"Traceback" not in result.stderr, result.stderr.decode()
    return result.stdout


def query(*options, environment=None):
    return [json.loads(line) for line in command("query", "--json", *options, environment=environment).splitlines()]


def export(*options, environment=None):
    with tarfile.open(fileobj=io.BytesIO(command("export", *options, environment=environment)), mode="r:gz") as archive:
        assert set(archive.getnames()) == {"manifest.json", "events.jsonl"}
        manifest = json.load(archive.extractfile("manifest.json"))
        events = [json.loads(line) for line in archive.extractfile("events.jsonl")]
    assert manifest["event_count"] == len(events)
    return events


# An existing FIFO must not deadlock capture, whether it has a reader or not.
# Persistence failures still leave the command's output and exit status intact.
for reader_present in (False, True):
    log_dir = root / f"fifo-{reader_present}"
    log_dir.mkdir()
    destination = log_dir / "agent.jsonl"
    os.mkfifo(destination)
    reader_fd = os.open(destination, os.O_RDONLY | os.O_NONBLOCK) if reader_present else None
    try:
        result = subprocess.run([
            sys.executable, str(helper), "capture", "--source", "agent", "--log-dir", str(log_dir),
            "--", "/bin/sh", "-c", "printf 'fifo fixture output\\n'; exit 7",
        ], capture_output=True, timeout=5)
        assert result.returncode == 7, result.stderr.decode()
        assert result.stdout == b"fifo fixture output\n", result.stdout
        assert b"cannot persist structured log" in result.stderr
        if reader_fd is not None:
            assert os.read(reader_fd, 1024) == b""
    finally:
        if reader_fd is not None:
            os.close(reader_fd)


# Rotation can temporarily remove the active path. Its durable generations
# still belong in both queries and exports, without raw/structured duplicates.
write(agent / "logs/agent.jsonl.2", record("older agent generation", "2026-10-04T11:00:00Z"))
write(agent / "logs/agent.jsonl.1", record("newer agent generation"))
write(agent / "logs/workload.log.1", "raw duplicate hidden by structured history\n")
write(executor / "logs/executor.log.1", "executor rotated raw history\n")
write(agent / "logs/service-worker.jsonl.1", record("service rotated history"))
write(agent / ".hermes/logs/gateway.log.1", "2026-10-04T12:30:00Z WARNING gateway: rotated history\n")
write(agent / ".hermes/events.jsonl.1", record("Hermes rotated event"))
# Non-ASCII digit-like filenames are not the writer's numbered generations.
write(agent / "logs/agent.jsonl.¹", record("invalid rotation suffix"))
write(agent / "logs/agent.jsonl.backup", record("backup file ignored"))
expected = {
    "older agent generation", "newer agent generation", "executor rotated raw history",
    "service rotated history", "2026-10-04T12:30:00Z WARNING gateway: rotated history",
    "Hermes rotated event",
}
for events in (query("--tail", "100"), export()):
    assert {event["message"] for event in events} == expected, events
    assert len(events) == len(expected)
    assert next(event for event in events if event["message"] == "service rotated history")["source"] == "service-worker"
    assert next(event for event in events if event["message"] == "executor rotated raw history")["source"] == "executor"
write(agent / "logs/agent.jsonl", record("active agent history", "2026-10-04T13:00:00Z"))
assert {event["message"] for event in query("--source", "agent")} == {
    "older agent generation", "newer agent generation", "active agent history",
}

# Space-separated logging timestamps must preserve time-of-day, fractional
# seconds, and offsets when applying --since to live/log-rotated history.
write(agent / ".hermes/logs/python.log", "".join([
    "2026-10-04 11:59:59,123 WARNING worker: before cutoff\n",
    "2026-10-04 12:34:56,789 WARNING worker: recent local log\n",
    "  continuation retained\n",
    "2026-10-04 14:00:00+01:00 WARNING worker: recent offset log\n",
    "2026-10-04T13:01:00Z WARNING worker: recent ISO log\n",
]))
recent = query("--source", "hermes", "--since", "2026-10-04T12:31:00Z")
assert [event["timestamp"] for event in recent] == [
    "2026-10-04T12:34:56.789Z", "2026-10-04T13:00:00.000Z", "2026-10-04T13:01:00.000Z",
], recent
assert recent[0]["message"].endswith("\n  continuation retained")
assert all(event["level"] == "warn" for event in recent)
assert logs.raw_timestamp("0.23 0.17 0.21 loadavg") is None

# ISO timestamps permit an hour-only timezone offset. Preserve it before
# normalizing so filters and newest-event selection use UTC, not local time.
for timestamp in (
    "2026-10-04T14:00:00+01", "2026-10-04T14:00:00+0100", "2026-10-04T14:00:00+01:00",
    "2026-10-04T12:00:00-01", "2026-10-04T12:00:00-0100", "2026-10-04T12:00:00-01:00",
):
    assert logs.isoformat(logs.raw_timestamp(timestamp + " WARNING offset fixture")) == "2026-10-04T13:00:00.000Z"
write(agent / ".hermes/logs/short-offset.log", "".join([
    "2026-10-04T14:00:00+01 WARNING short offset fixture east\n",
    "2026-10-04T12:00:00-01 WARNING short offset fixture west\n",
    "2026-10-04T13:30:00Z WARNING short offset fixture latest\n",
]))
for events in (
    query("--source", "hermes", "--grep", "short offset fixture", "--since", "2026-10-04T13:15:00Z"),
    query("--source", "hermes", "--grep", "short offset fixture", "--tail", "1"),
    export("--source", "hermes", "--grep", "short offset fixture", "--tail", "1"),
):
    assert len(events) == 1 and events[0]["message"].endswith("short offset fixture latest"), events
    assert events[0]["timestamp"] == "2026-10-04T13:30:00.000Z", events

# Agent-controlled invalid timestamps must fall back instead of terminating
# the entire query/export, and non-finite native data must remain valid JSON.
invalid = [10**400, "0001-01-01T00:00:00+01:00", "9999-12-31T23:59:59-01:00"]
for timestamp in invalid:
    assert logs.parse_timestamp(timestamp) is None
write(agent / "logs/agent.jsonl", "".join(
    record(f"invalid timestamp {index}", timestamp, data={"float": float("nan"), "infinity": float("inf")})
    for index, timestamp in enumerate(invalid)
))
for events in (query("--source", "agent"), export("--source", "agent")):
    malformed = [event for event in events if event["message"].startswith("invalid timestamp")]
    assert len(malformed) == len(invalid)
    assert all(event["data"] == {"float": None, "infinity": None} for event in malformed)
    json.dumps(events, allow_nan=False)
for action in ("query", "export"):
    result = subprocess.run([
        sys.executable, str(helper), action, "--agent-root", str(agent), "--executor-root", str(executor),
        "--box", "fixture", "--since", "9" * 400 + "h",
    ], capture_output=True)
    assert result.returncode != 0
    assert b"--since duration exceeds the supported date range" in result.stderr
    assert b"Traceback" not in result.stderr

# Selecting the latest events before redaction must retain filtering against
# original values while protecting every emitted event in queries and exports.
secret = "logs-audit-private-value"
environment = dict(os.environ, AUDIT_SECRET=secret)
write(agent / "logs/agent.jsonl", "".join([
    record("older " + secret, "2026-10-04T10:00:00Z"),
    record("middle " + secret, "2026-10-04T11:00:00Z"),
    record("newer " + secret, "2026-10-04T12:00:00Z", data={"password": "nested-private-value"}),
]))
for events in (
    query("--source", "agent", "--grep", secret, "--tail", "2", environment=environment),
    export("--source", "agent", "--grep", secret, "--tail", "2", environment=environment),
):
    assert [event["message"] for event in events] == ["middle [REDACTED]", "newer [REDACTED]"]
    assert events[1]["data"]["password"] == "[REDACTED]"
    assert secret not in json.dumps(events)
    assert "nested-private-value" not in json.dumps(events)
assert [event["message"] for event in query(
    "--source", "agent", "--grep", secret, "--tail", "1", "--no-redact", environment=environment
)] == ["newer " + secret]
PY

echo "log discovery, timestamps, redaction, and query performance regression checks passed"
