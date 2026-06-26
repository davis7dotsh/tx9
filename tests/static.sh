#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

files=(
  box
  guest/hb
  guest/hb-workload
  guest/profile.sh
  guest/agent-bash-profile.sh
  provision/provision.sh
  ops/tx9-host
  tests/lifecycle-smoke.sh
  tests/hermes-state.sh
  tests/regressions.sh
  tests/fixtures/smolvm
)

bash -n "${files[@]}"
for file in box guest/hb guest/hb-workload guest/hermes-state provision/provision.sh ops/tx9-host tests/lifecycle-smoke.sh tests/hermes-state.sh tests/regressions.sh tests/fixtures/smolvm; do
  [[ -x "$file" ]] || { echo "not executable: $file" >&2; exit 1; }
done

grep -q 'WIRE_EXECUTOR_MCP' guest/hb
grep -q 'http://127.0.0.1:.*}/mcp' guest/hb
if grep -q 'args = \["mcp"\]' guest/hb; then
  echo "legacy stdio Executor MCP wiring remains" >&2
  exit 1
fi
grep -q 'trap _cleanup EXIT' box
grep -q 'Decrypting and validating archive before creating a VM' box
grep -q 'refusing to overwrite existing backup' box
grep -q 'guest_tmp="/root/hb-data-' box
grep -q 'guest_tmp="/root/hb-restore-' box
if grep -Eq 'guest_tmp="/tmp/hb-(data|restore)-' box; then
  echo "smolvm-incompatible /tmp archive staging remains" >&2
  exit 1
fi
if grep -q '\blsof\b' box; then
  echo "lsof dependency remains" >&2
  exit 1
fi
grep -q 'protocolVersion.*2025-03-26' box
grep -q 'protocolVersion.*2025-03-26' guest/hb
grep -q 'ca-certificates curl git jq tmux' provision/provision.sh
grep -q 'runuser -u agent.*hb.*write-manifest' provision/provision.sh
grep -q -- '--commit.*sha' provision/provision.sh
grep -q 'BOX_OVERLAY_GIB="64"' box.env
grep -q 'gateway-disable' box
grep -Fq -- '--exclude="*/.hermes/*.db-wal"' box
if grep -Fq -- '--exclude="*.db-wal"' box; then
  echo "unrelated /data SQLite WAL files are still excluded" >&2
  exit 1
fi
grep -q 'LoadCredential=backup-passphrase' ops/systemd/tx9-backup@.service
grep -qi 'networking is always enabled' README.md
grep -q 'intentionally no CI configuration yet' README.md

echo "static checks passed"
