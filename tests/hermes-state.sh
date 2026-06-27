#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

python3 - "$tmp" <<'PY'
import json, sqlite3, stat, sys, zipfile
from pathlib import Path

root = Path(sys.argv[1])
source = root / "source"
(source / "sessions").mkdir(parents=True)
(source / "memories").mkdir()
(source / "cron").mkdir()
(source / "hooks").mkdir()
(source / "skills/example/hermes-agent").mkdir(parents=True)
(source / "_external/.honcho").mkdir(parents=True)
(source / "config.yaml").write_text("workspace: /Users/davis/Developer\n")
(source / ".env").write_text("DISCORD_BOT_TOKEN=fixture\nROOT=/Users/davis\n")
(source / "sessions/history.json").write_text('{"historical":"/Users/davis"}\n')
(source / "memories/MEMORY.md").write_text("memory\n")
(source / "cron/jobs.json").write_text(json.dumps({"jobs": [{"enabled": True, "command": "/Users/davis/task"}]}))
(source / "hooks/run.sh").write_text("cd /Users/davis\n")
(source / "hooks/run.sh").chmod(0o4755)
(source / "skills/example/hermes-agent/KEEP.md").write_text("nested skill\n")
(source / "_external/.honcho/.env").write_text('ROOT=/Users/davis\n')
db = sqlite3.connect(source / "state.db")
db.executescript("PRAGMA user_version=16; CREATE TABLE sessions(id); CREATE TABLE messages(id); INSERT INTO sessions VALUES(1); INSERT INTO messages VALUES(1); INSERT INTO messages VALUES(2);")
db.commit(); db.close()
with zipfile.ZipFile(root / "valid.zip", "w") as zf:
    for path in source.rglob("*"):
        if path.is_file(): zf.write(path, path.relative_to(source).as_posix())
with zipfile.ZipFile(root / "valid-no-external.zip", "w") as zf:
    for path in source.rglob("*"):
        if path.is_file() and "_external" not in path.relative_to(source).parts:
            zf.write(path, path.relative_to(source).as_posix())
with zipfile.ZipFile(root / "reserved-external.zip", "w") as zf:
    zf.writestr("config.yaml", "model: fixture\n")
    zf.writestr("_external/.ssh/config", "Host *\n")
with zipfile.ZipFile(root / "external-only.zip", "w") as zf:
    zf.writestr("_external/.honcho/.env", "TOKEN=fixture\n")
with zipfile.ZipFile(root / "traversal.zip", "w") as zf:
    zf.writestr("../config.yaml", "bad")
with zipfile.ZipFile(root / "symlink.zip", "w") as zf:
    info = zipfile.ZipInfo("config.yaml")
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    zf.writestr(info, "/etc/passwd")
bad = root / "bad"
bad.mkdir()
(bad / "config.yaml").write_text("marker\n")
(bad / "state.db").write_text("not sqlite")
with zipfile.ZipFile(root / "bad-db.zip", "w") as zf:
    for path in bad.iterdir(): zf.write(path, path.name)
PY

target="$tmp/home/.hermes"
mkdir -p "$target"
mkdir -p "$tmp/home/.honcho"
printf 'keep\n' >"$tmp/home/.honcho/keep"
printf 'preserve on failure\n' >"$target/original"
"$ROOT/guest/hermes-state" validate-zip "$tmp/valid-no-external.zip" >"$tmp/validation.json"
"$ROOT/guest/hermes-state" validate-zip "$tmp/valid.zip" >"$tmp/external-validation.json"
jq -e '.external_top_level_entries == [".honcho"]' "$tmp/external-validation.json" >/dev/null
if "$ROOT/guest/hermes-state" validate-zip "$tmp/traversal.zip" >/dev/null 2>&1; then
  echo "path traversal ZIP passed validation" >&2; exit 1
fi
if "$ROOT/guest/hermes-state" validate-zip "$tmp/symlink.zip" >/dev/null 2>&1; then
  echo "symlink ZIP passed validation" >&2; exit 1
fi
if "$ROOT/guest/hermes-state" validate-zip "$tmp/external-only.zip" >/dev/null 2>&1; then
  echo "external-only archive passed native Hermes validation" >&2; exit 1
fi
if HOME="$tmp/home" "$ROOT/guest/hermes-state" import-zip "$tmp/bad-db.zip" --home "$target" >/dev/null 2>&1; then
  echo "corrupt SQLite import succeeded" >&2; exit 1
fi
grep -q 'preserve on failure' "$target/original"

HOME="$tmp/home" "$ROOT/guest/hermes-state" import-zip "$tmp/valid-no-external.zip" --home "$target" \
  --map /Users/davis=/data/home/agent >"$tmp/result.json"
grep -q '/data/home/agent/Developer' "$target/config.yaml"
grep -q '/data/home/agent/task' "$target/cron/jobs.json"
grep -q '/Users/davis' "$target/sessions/history.json"
[[ ! -e "$tmp/home/.honcho/.env" ]]
grep -q keep "$tmp/home/.honcho/keep"
grep -q 'nested skill' "$target/skills/example/hermes-agent/KEEP.md"
[[ "$(stat -c '%a' "$target/hooks/run.sh" 2>/dev/null || stat -f '%Lp' "$target/hooks/run.sh")" == 755 ]]
[[ ! -e "$target/original" ]]
jq -e '.source.databases[0].integrity == "ok" and .destination.databases[0].user_version == 16 and .destination.databases[0].sessions == 1 and .destination.databases[0].messages == 2 and .destination.inventory.cron_jobs == 1 and .destination.inventory.memory_files == 1 and .external_state_imported == false and .accounting.archive_files == (.accounting.hermes_files + .accounting.external_files + .accounting.skipped_files) and .gateway_enabled == false' "$tmp/result.json" >/dev/null
jq -e '.source.databases[0].integrity == "ok"' "$tmp/home/.config/hermes-box/import-manifest.json" >/dev/null
[[ "$(jq '.files' "$tmp/validation.json")" == "$(jq '.accounting.archive_files' "$tmp/result.json")" ]]
if HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check >/dev/null 2>&1; then
  echo "cutover passed without active-path acknowledgement" >&2; exit 1
fi
HOME="$tmp/home" "$ROOT/guest/hermes-state" acknowledge-paths >/dev/null
HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check >/dev/null
rm "$target/memories/MEMORY.md"
if HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check >/dev/null 2>&1; then
  echo "cutover passed after inventory drift" >&2; exit 1
fi
printf 'corrupt database\n' >"$target/state.db"
if HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check >/dev/null 2>&1; then
  echo "cutover passed after database corruption" >&2; exit 1
fi

if HOME="$tmp/home" "$ROOT/guest/hermes-state" import-zip "$tmp/reserved-external.zip" \
  --home "$target" --external .ssh >/dev/null 2>&1; then
  echo "reserved .ssh external import succeeded" >&2; exit 1
fi
mkdir -p "$tmp/outside"
printf 'outside unchanged\n' >"$tmp/outside/probe"
ln -s "$tmp/outside" "$tmp/home/.honcho/link"
printf 'rollback preserved\n' >"$target/rollback-probe"
if HOME="$tmp/home" "$ROOT/guest/hermes-state" import-zip "$tmp/valid.zip" --home "$target" \
  --external .honcho --map /Users/davis=/data/home/agent >/dev/null 2>&1; then
  echo "external merge into a symlinked provider tree succeeded" >&2; exit 1
fi
grep -q 'rollback preserved' "$target/rollback-probe"
grep -q 'outside unchanged' "$tmp/outside/probe"
rm "$tmp/home/.honcho/link"
HOME="$tmp/home" "$ROOT/guest/hermes-state" import-zip "$tmp/valid.zip" --home "$target" \
  --external .honcho --map /Users/davis=/data/home/agent >"$tmp/external-result.json"
grep -q '/data/home/agent' "$tmp/home/.honcho/.env"
grep -q keep "$tmp/home/.honcho/keep"
[[ "$(stat -c '%a' "$tmp/home/.honcho" 2>/dev/null || stat -f '%Lp' "$tmp/home/.honcho")" == 700 ]]
[[ "$(stat -c '%a' "$tmp/home/.honcho/.env" 2>/dev/null || stat -f '%Lp' "$tmp/home/.honcho/.env")" == 600 ]]
jq -e '.external_state_imported == true' "$tmp/external-result.json" >/dev/null

# Explicit --home anchors approved provider state beside that Hermes home,
# independent of the process HOME used for manifest defaults.
custom_target="$tmp/custom-agent/.hermes"
HOME="$tmp/unrelated-process-home" "$ROOT/guest/hermes-state" import-zip "$tmp/valid.zip" \
  --home "$custom_target" --manifest "$tmp/custom-manifest.json" \
  --external .honcho --map /Users/davis=/srv/custom-agent >/dev/null
grep -q '/srv/custom-agent' "$tmp/custom-agent/.honcho/.env"
[[ ! -e "$tmp/unrelated-process-home/.honcho" ]]

# A reader holding an older WAL snapshot must make checkpoint verification fail.
wal_home="$tmp/wal-home"
mkdir -p "$wal_home"
python3 - "$wal_home/state.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=WAL")
db.execute("CREATE TABLE probe(value)")
db.execute("INSERT INTO probe VALUES (1)")
db.commit()
db.close()
PY
python3 - "$wal_home/state.db" "$tmp/reader-ready" <<'PY' &
import pathlib, sqlite3, sys, time
db = sqlite3.connect(sys.argv[1])
db.execute("BEGIN")
db.execute("SELECT * FROM probe").fetchall()
pathlib.Path(sys.argv[2]).write_text("ready")
time.sleep(10)
db.close()
PY
reader_pid=$!
for _ in {1..100}; do [[ -e "$tmp/reader-ready" ]] && break; sleep 0.02; done
python3 - "$wal_home/state.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("INSERT INTO probe VALUES (2)")
db.commit()
db.close()
PY
if "$ROOT/guest/hermes-state" verify --home "$wal_home" --checkpoint >/dev/null 2>&1; then
  echo "busy WAL checkpoint unexpectedly passed" >&2
  kill "$reader_pid" 2>/dev/null || true
  exit 1
fi
kill "$reader_pid" 2>/dev/null || true
wait "$reader_pid" 2>/dev/null || true
"$ROOT/guest/hermes-state" verify --home "$wal_home" --checkpoint >/dev/null

echo "Hermes state checks passed"
