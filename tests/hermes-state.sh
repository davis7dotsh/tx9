#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

python3 - "$tmp" <<'PY'
import json, sqlite3, stat, struct, sys, zipfile
from pathlib import Path

root = Path(sys.argv[1])
source = root / "source"
(source / "sessions").mkdir(parents=True)
(source / "memories").mkdir()
(source / "cron").mkdir()
(source / "hooks").mkdir()
(source / "bin").mkdir()
(source / "tmp").mkdir()
(source / "skills/example/hermes-agent").mkdir(parents=True)
(source / "_external/.honcho").mkdir(parents=True)
(source / "config.yaml").write_text("workspace: /Users/davis/Developer\n")
(source / ".env").write_text("DISCORD_BOT_TOKEN=fixture\nROOT=/Users/davis\n")
(source / "sessions/history.json").write_text('{"historical":"/Users/davis"}\n')
(source / "memories/MEMORY.md").write_text("memory\n")
(source / "cron/jobs.json").write_text(json.dumps({"jobs": [{"enabled": True, "command": "/Users/davis/task"}]}))
(source / "hooks/run.sh").write_text("cd /Users/davis\n")
(source / "hooks/run.sh").chmod(0o4755)
(source / "tmp/transient.log").write_text("do not migrate\n")
(source / "bin/eventide-tool").write_bytes(b"\xcf\xfa\xed\xfe" + b"macOS thin binary fixture\n")
(source / "classes").mkdir()
(source / "classes/Portable.class").write_bytes(b"\xca\xfe\xba\xbe\x00\x00\x00\x3d\x00\x01")
(source / "skills/example/hermes-agent/KEEP.md").write_text("nested skill\n")
(source / "_external/.honcho/.env").write_text('ROOT=/Users/davis\n')
fat_mach_o = (
    b"\xca\xfe\xba\xbf"
    + struct.pack(">IiiQQII", 1, 0x0100000C, 0, 40, 8, 0, 0)
    + b"\xcf\xfa\xed\xfe"
    + struct.pack("<I", 0x0100000C)
)
(source / "_external/.honcho/provider-tool").write_bytes(fat_mach_o)
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
with zipfile.ZipFile(root / "duplicate-normalized.zip", "w") as zf:
    zf.writestr("config.yaml", "first\n")
    zf.writestr("./config.yaml", "second\n")
with zipfile.ZipFile(root / "skipped-marker-only.zip", "w") as zf:
    zf.writestr("tmp/config.yaml", "transient marker\n")
with zipfile.ZipFile(root / "nested-marker-only.zip", "w") as zf:
    zf.writestr("nested/config.yaml", "nested marker\n")
with zipfile.ZipFile(root / "prefixed-valid.zip", "w") as zf:
    zf.writestr(".hermes/config.yaml", "canonical prefixed marker\n")
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
jq -e '.migration_scope.skipped_by_reason == {"mach_o_binary": 2, "root_tmp": 1} and .migration_scope.skipped_files == 3 and .migration_scope.normalized_files == (.files - 3)' "$tmp/external-validation.json" >/dev/null
jq -e '.migration_scope.skipped_entries == [
  {"bytes": 48, "path": "_external/.honcho/provider-tool", "reason": "mach_o_binary"},
  {"bytes": 30, "path": "bin/eventide-tool", "reason": "mach_o_binary"},
  {"bytes": 15, "path": "tmp/transient.log", "reason": "root_tmp"}
]' "$tmp/external-validation.json" >/dev/null
if "$ROOT/guest/hermes-state" validate-zip "$tmp/traversal.zip" >/dev/null 2>&1; then
  echo "path traversal ZIP passed validation" >&2; exit 1
fi
if "$ROOT/guest/hermes-state" validate-zip "$tmp/symlink.zip" >/dev/null 2>&1; then
  echo "symlink ZIP passed validation" >&2; exit 1
fi
if "$ROOT/guest/hermes-state" validate-zip "$tmp/duplicate-normalized.zip" \
  >/dev/null 2>"$tmp/duplicate-error"; then
  echo "duplicate normalized ZIP path passed validation" >&2; exit 1
fi
grep -q 'duplicate normalized archive path: config.yaml' "$tmp/duplicate-error"
if "$ROOT/guest/hermes-state" validate-zip "$tmp/skipped-marker-only.zip" \
  >/dev/null 2>"$tmp/skipped-marker-error"; then
  echo "archive with only a skipped marker passed validation" >&2; exit 1
fi
grep -q 'archive has no importable canonical root Hermes marker' "$tmp/skipped-marker-error"
if "$ROOT/guest/hermes-state" validate-zip "$tmp/nested-marker-only.zip" \
  >/dev/null 2>"$tmp/nested-marker-error"; then
  echo "archive with only a nested marker passed validation" >&2; exit 1
fi
grep -q 'archive has no importable canonical root Hermes marker' "$tmp/nested-marker-error"
"$ROOT/guest/hermes-state" validate-zip "$tmp/prefixed-valid.zip" >"$tmp/prefixed-validation.json"
jq -e '.prefix == ".hermes/" and .migration_scope.normalized_files == 1' \
  "$tmp/prefixed-validation.json" >/dev/null
if "$ROOT/guest/hermes-state" validate-zip "$tmp/external-only.zip" >/dev/null 2>&1; then
  echo "external-only archive passed native Hermes validation" >&2; exit 1
fi
if HOME="$tmp/home" "$ROOT/guest/hermes-state" import-zip "$tmp/bad-db.zip" --home "$target" >/dev/null 2>&1; then
  echo "corrupt SQLite import succeeded" >&2; exit 1
fi
grep -q 'preserve on failure' "$target/original"
if HOME="$tmp/home" "$ROOT/guest/hermes-state" import-zip "$tmp/duplicate-normalized.zip" \
  --home "$target" >/dev/null 2>&1; then
  echo "duplicate normalized ZIP import succeeded" >&2; exit 1
fi
grep -q 'preserve on failure' "$target/original"
if HOME="$tmp/home" "$ROOT/guest/hermes-state" import-zip "$tmp/skipped-marker-only.zip" \
  --home "$target" >/dev/null 2>&1; then
  echo "archive with only a skipped marker imported successfully" >&2; exit 1
fi
grep -q 'preserve on failure' "$target/original"

# Replacing the archive after validate_zip returns must still fail against the
# exact ZIP snapshot reopened for extraction, without swapping the destination.
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/guest/hermes-state" "$tmp/valid-no-external.zip" \
  "$tmp/skipped-marker-only.zip" "$target" "$tmp/toctou-manifest.json" <<'PY'
import importlib.machinery
import importlib.util
import os
import shutil
import sys
from pathlib import Path

script, valid, replacement, target, manifest = map(Path, sys.argv[1:])
loader = importlib.machinery.SourceFileLoader("hermes_state_toctou", str(script))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
race_archive = valid.with_name("toctou.zip")
race_replacement = replacement.with_name("toctou-replacement.zip")
shutil.copy2(valid, race_archive)
shutil.copy2(replacement, race_replacement)
original_validate = module.validate_zip

def replace_after_validate(path):
    report = original_validate(path)
    os.replace(race_replacement, path)
    return report

module.validate_zip = replace_after_validate
try:
    module.import_zip(race_archive, target, [], manifest, set())
except ValueError as error:
    if "no importable canonical root Hermes marker" not in str(error):
        raise
else:
    raise SystemExit("replacement with transient-only archive imported successfully")
if (target / "original").read_text() != "preserve on failure\n":
    raise SystemExit("TOCTOU rejection did not preserve the existing Hermes home")
if manifest.exists():
    raise SystemExit("TOCTOU rejection unexpectedly published an import manifest")
PY

archive_hash_before="$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$tmp/valid-no-external.zip")"
HOME="$tmp/home" "$ROOT/guest/hermes-state" import-zip "$tmp/valid-no-external.zip" --home "$target" \
  --map /Users/davis=/data/home/agent >"$tmp/result.json" 2>"$tmp/import-warning"
archive_hash_after="$(python3 -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$tmp/valid-no-external.zip")"
[[ "$archive_hash_before" == "$archive_hash_after" ]]
grep -q 'warning: import completed with 2 intentionally skipped file(s)' "$tmp/import-warning"
grep -q '/data/home/agent/Developer' "$target/config.yaml"
grep -q '/data/home/agent/task' "$target/cron/jobs.json"
grep -q '/Users/davis' "$target/sessions/history.json"
[[ ! -e "$tmp/home/.honcho/.env" ]]
grep -q keep "$tmp/home/.honcho/keep"
grep -q 'nested skill' "$target/skills/example/hermes-agent/KEEP.md"
[[ ! -e "$target/tmp" ]]
[[ ! -e "$target/bin/eventide-tool" ]]
cmp "$target/classes/Portable.class" "$tmp/source/classes/Portable.class"
[[ "$(stat -c '%a' "$target/hooks/run.sh" 2>/dev/null || stat -f '%Lp' "$target/hooks/run.sh")" == 755 ]]
[[ ! -e "$target/original" ]]
jq -e '.status == "completed_with_skips" and .format == 2 and .source.databases[0].integrity == "ok" and .destination.databases[0].user_version == 16 and .destination.databases[0].sessions == 1 and .destination.databases[0].messages == 2 and .destination.inventory.cron_jobs == 1 and .destination.inventory.memory_files == 1 and .external_state_imported == false and .accounting.archive_files == (.accounting.hermes_files + .accounting.external_files + .accounting.skipped_files) and .accounting.skipped_by_reason == {"mach_o_binary": 1, "root_tmp": 1} and .accounting.normalized_files == (.accounting.hermes_files + .accounting.external_files) and .gateway_enabled == false' "$tmp/result.json" >/dev/null
jq -e '.source.databases[0].integrity == "ok"' "$tmp/home/.config/hermes-box/import-manifest.json" >/dev/null
[[ "$(jq '.files' "$tmp/validation.json")" == "$(jq '.accounting.archive_files' "$tmp/result.json")" ]]
jq -s -e '.[0].migration_scope == .[1].accounting' "$tmp/validation.json" "$tmp/result.json" >/dev/null
jq -s -e '.[0].accounting == .[1].accounting' "$tmp/result.json" "$tmp/home/.config/hermes-box/import-manifest.json" >/dev/null
if HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check >/dev/null 2>&1; then
  echo "cutover passed without active-path acknowledgement" >&2; exit 1
fi
HOME="$tmp/home" "$ROOT/guest/hermes-state" acknowledge-paths >/dev/null
HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check >/dev/null
jq 'del(.accounting.skipped_entries[0])' \
  "$tmp/home/.config/hermes-box/import-manifest.json" >"$tmp/tampered-v2-manifest.json"
if HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check \
  --manifest "$tmp/tampered-v2-manifest.json" >/dev/null 2>&1; then
  echo "cutover passed a format-2 manifest with incomplete migration accounting" >&2; exit 1
fi
jq '.accounting.skipped_entries[0].bytes += 1' \
  "$tmp/home/.config/hermes-box/import-manifest.json" >"$tmp/tampered-v2-bytes.json"
if HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check \
  --manifest "$tmp/tampered-v2-bytes.json" >/dev/null 2>&1; then
  echo "cutover passed a format-2 manifest with tampered skipped bytes" >&2; exit 1
fi
jq '.accounting.skipped_entries[0].reason = "fabricated_reason"' \
  "$tmp/home/.config/hermes-box/import-manifest.json" >"$tmp/tampered-v2-reason.json"
if HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check \
  --manifest "$tmp/tampered-v2-reason.json" >/dev/null 2>&1; then
  echo "cutover passed a format-2 manifest with a fabricated skip reason" >&2; exit 1
fi
jq '.accounting.hermes_bytes = 0 | .accounting.external_bytes = 0' \
  "$tmp/home/.config/hermes-box/import-manifest.json" >"$tmp/tampered-v2-categories.json"
if HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check \
  --manifest "$tmp/tampered-v2-categories.json" >/dev/null 2>&1; then
  echo "cutover passed a format-2 manifest with zeroed category bytes" >&2; exit 1
fi
jq 'del(
  .status,
  .migration_policy,
  .accounting.archive_bytes,
  .accounting.hermes_bytes,
  .accounting.external_bytes,
  .accounting.skipped_bytes,
  .accounting.normalized_files,
  .accounting.normalized_bytes,
  .accounting.skipped_by_reason,
  .accounting.skipped_entries
) | .format = 1' "$tmp/home/.config/hermes-box/import-manifest.json" >"$tmp/legacy-manifest.json"
HOME="$tmp/home" "$ROOT/guest/hermes-state" cutover-check \
  --manifest "$tmp/legacy-manifest.json" >"$tmp/legacy-cutover.json"
jq -e '.ready == true and .gates.archive_accounted == true and .gates.migration_scope_accounted == true' \
  "$tmp/legacy-cutover.json" >/dev/null
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
[[ ! -e "$tmp/home/.honcho/provider-tool" ]]
jq -e '.external_state_imported == true and .accounting.skipped_by_reason == {"mach_o_binary": 2, "root_tmp": 1}' "$tmp/external-result.json" >/dev/null

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
