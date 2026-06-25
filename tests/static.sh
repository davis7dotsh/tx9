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
  tests/lifecycle-smoke.sh
  tests/fixtures/smolvm
)

bash -n "${files[@]}"
for file in box guest/hb guest/hb-workload provision/provision.sh tests/lifecycle-smoke.sh tests/fixtures/smolvm; do
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
grep -qi 'networking is always enabled' README.md
grep -q 'There is intentionally no CI configuration yet' README.md

echo "static checks passed"
