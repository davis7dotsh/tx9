#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# A failed import gate must keep the gateway disabled even when invoked in a
# conditional shell context, where errexit cannot propagate helper failures.
(
  HB_DATA="$tmp/cutover"
  # shellcheck source=guest/hb
  source "$PROJECT_ROOT/guest/hb"
  init
  printf '{"gateway_enabled":false}\n' >"$STATE_DIR/import-manifest.json"
  _gateway_running() { return 1; }
  hermes-state() { return 42; }
  _start_gateway() { touch "$tmp/gateway-started"; }
  if gateway_enable --confirm-single-writer I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY \
    >"$tmp/cutover.stdout" 2>"$tmp/cutover.stderr"; then
    echo "gateway enabled after failed cutover validation" >&2
    exit 1
  fi
  [[ -e "$GATEWAY_DISABLED" && ! -e "$tmp/gateway-started" ]]
  [[ "$(jq -r .gateway_enabled "$STATE_DIR/import-manifest.json")" == false ]]
  [[ ! -s "$tmp/cutover.stdout" ]]
)

# hb's sourced temporary variables do not replace the parent test directory.
# shellcheck disable=SC2031
python3 - "$PROJECT_ROOT/guest/tx9-logs" "$tmp" <<'PY'
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import signal
import sqlite3
import sys

loader = importlib.machinery.SourceFileLoader("tx9_logs_security", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
root = Path(sys.argv[2])

# Source validation must not block if an enumerated regular file becomes a
# FIFO before open. No writer exists for this fixture.
fifo = root / "source.log"
os.mkfifo(fifo)
signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(AssertionError("FIFO open blocked")))
signal.alarm(2)
try:
    try:
        module.open_regular_binary(root, fifo)
    except OSError as exc:
        assert "non-regular" in str(exc)
    else:
        raise AssertionError("accepted a FIFO as a log source")
finally:
    signal.alarm(0)

# Quoted passwords and tokens can contain whitespace, delimiters, escaped
# quotes, and newlines. Both query redaction and capture must hide every byte
# of the value, including when a read ends just after an escape character.
cases = [
    ('password="first second third" visible', 'password="[REDACTED]" visible'),
    ("api_token='first, second; third' visible", "api_token='[REDACTED]' visible"),
    ('{"client_secret":"first \\" second"} visible', '{"client_secret":"[REDACTED]"} visible'),
    ('password="first\nsecond" visible', 'password="[REDACTED]" visible'),
    ('password="first second', 'password="[REDACTED]'),
    ('password="first second' + chr(92), 'password="[REDACTED]'),
]
for text, expected in cases:
    assert module.redact_text(text, ()) == expected
    payload = text.encode()
    for split in range(len(payload) + 1):
        redactor = module.StreamingRedactor(())
        redacted = redactor.feed(payload[:split]) + redactor.feed(payload[split:]) + redactor.finish()
        assert redacted.decode() == expected, (text, split, redacted)

# A WAL is also untrusted. The SQLite input must never include a symlinked
# sidecar from the Executor volume, even when the main database is regular.
agent = root / "wal-agent"
executor = root / "wal-executor"
agent.mkdir()
executor.mkdir()
database = agent / "state.db"
with sqlite3.connect(database) as connection:
    connection.execute("CREATE TABLE messages(content TEXT)")
(executor / "private-wal").write_bytes(b"private fixture bytes")
Path(str(database) + "-wal").symlink_to(executor / "private-wal")
assert list(module.read_hermes_db(database, root=agent, box="fixture")) == []
assert any("cannot read Hermes database" in warning for warning in module.WARNINGS)
PY

echo "guest security regression checks passed"
