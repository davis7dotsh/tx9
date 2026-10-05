#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT_ROOT" "$tmp" <<'PY'
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

project, root = map(Path, sys.argv[1:])
errors = []

# Relative probe overrides are resolved from the caller's directory before
# the browser CLI is isolated in its private HOME/cwd/socket directory.
relative = root / "browser-relative"
relative.mkdir()
cli = relative / "cli"
cli.write_text('''#!/usr/bin/env python3
from pathlib import Path
import os, sys
chrome = Path(sys.argv[sys.argv.index('--executable-path') + 1])
if not chrome.is_file() or not os.access(chrome, os.X_OK):
    sys.exit(2)
if 'snapshot' in sys.argv:
    print('TX9_BROWSER_FIXTURE_OK')
''')
for path in (cli, relative / "chrome", relative / "ldd"):
    if path != cli:
        path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(0o700)
(relative / "fixture.html").write_text("TX9_BROWSER_FIXTURE_OK")
probe = subprocess.run(
    [str(project / "guest/tx9-browser"), "health", "--json",
     "--cli", "./browser-relative/cli", "--chrome", "./browser-relative/chrome",
     "--ldd", "./browser-relative/ldd", "--fixture", "./browser-relative/fixture.html"],
    cwd=root, capture_output=True, text=True, timeout=10,
)
if probe.returncode or json.loads(probe.stdout)["code"] != "ok":
    errors.append("browser health failed with existing relative executable overrides")

loader = importlib.machinery.SourceFileLoader("state_inspection_audit", str(project / "guest/hermes-state"))
spec = importlib.util.spec_from_loader(loader.name, loader)
state = importlib.util.module_from_spec(spec)
loader.exec_module(state)
home = root / "state-home"
(home / "sessions/nested/sessions").mkdir(parents=True)
(home / "sessions/current.json").write_text("current session")
(home / "sessions/nested/sessions/child.json").write_text("nested active session")
(home / "memories").mkdir()
(home / "memories/MEMORY.md").write_text("current memory")
(home / "skills/example").mkdir(parents=True)
(home / "skills/example/SKILL.md").write_text("current skill")
(home / "cron").mkdir()
(home / "cron/jobs.json").write_text(json.dumps({"jobs": [{"enabled": True}, {"enabled": False}]}))
(home / "gateway_state.json").write_text("[]")
with sqlite3.connect(home / "state.db") as connection:
    connection.execute("CREATE TABLE messages(content TEXT)")
    connection.execute("INSERT INTO messages VALUES('current message')")
for excluded in ("backups", ".cache", "checkpoints", ".venv"):
    copy = home / excluded / "old-state"
    (copy / "cron").mkdir(parents=True)
    (copy / "cron/jobs.json").write_text("malformed obsolete cron fixture")
    (copy / "sessions").mkdir()
    (copy / "sessions/obsolete.json").write_text("obsolete session")
    (copy / "state.db").write_text("obsolete invalid database")
    (copy / "gateway_state.json").write_text("malformed obsolete gateway fixture")
outside = root / "outside-state"
outside.mkdir()
(outside / "secret.json").write_text("outside fixture")
(home / "sessions/external.json").symlink_to(outside / "secret.json")
(home / "sessions/external-directory").symlink_to(outside, target_is_directory=True)
try:
    report = state.inspect_home(home)
    assert report["inventory"] == {
        "session_files": 2, "memory_files": 1, "skill_files": 1,
        "cron_jobs": 2, "active_cron_jobs": 1,
    }, report["inventory"]
    assert [item["path"] for item in report["databases"]] == ["state.db"]
    assert report["databases"][0]["messages"] == 1
    assert report["gateway_states"] == [{"path": "gateway_state.json", "state": "invalid"}]
except (AssertionError, ValueError, AttributeError, TypeError) as error:
    errors.append(f"state verification included obsolete or duplicate inventory: {type(error).__name__}")

for error in errors:
    print(error, file=sys.stderr)
if errors:
    raise SystemExit(1)
PY

echo 'guest inspection audit regression checks passed'
