#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# tests/regressions-*.sh is globbed so new split-out regression files are
# picked up automatically.
regression_files=(tests/regressions-*.sh)

files=(
  box
  guest/hb
  guest/hb-workload
  guest/lib-mcp.sh
  guest/profile.sh
  guest/agent-bash-profile.sh
  provision/provision.sh
  ops/tx9-host
  ops/tx9-backup-prune
  tests/lib.sh
  tests/lifecycle-smoke.sh
  tests/hermes-state.sh
  tests/cli-surface.sh
  "${regression_files[@]}"
  tests/fixtures/smolvm
)

bash -n "${files[@]}"
for file in box guest/hb guest/hb-workload guest/hermes-state provision/provision.sh ops/tx9-host ops/tx9-backup-prune tests/lifecycle-smoke.sh tests/hermes-state.sh tests/cli-surface.sh "${regression_files[@]}" tests/fixtures/smolvm; do
  [[ -x "$file" ]] || { echo "not executable: $file" >&2; exit 1; }
done

grep -q 'WIRE_EXECUTOR_MCP' guest/hb
# HTTP MCP wiring goes through _executor_url (http://$EXECUTOR_HOST:$PORT/mcp,
# loopback by default, container-DNS name in the compose split).
grep -q "printf 'http://%s:%s/mcp' \"\$EXECUTOR_HOST\"" guest/hb
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
grep -q 'protocolVersion.*2025-03-26' guest/lib-mcp.sh
grep -q 'source .*guest/lib-mcp\.sh' box
grep -q 'lib-mcp\.sh' guest/hb
grep -q 'ca-certificates curl git jq tmux' provision/provision.sh
grep -q 'runuser -u agent.*hb.*write-manifest' provision/provision.sh
grep -q -- '--commit.*sha' provision/provision.sh
grep -q 'HERMES_INSTALLER_SHA256="[0-9a-f]\{64\}"' box.env
grep -q 'sha256sum --check --status' provision/provision.sh
python3 - <<'PY'
from pathlib import Path

source = Path("provision/provision.sh").read_text()
checksum = source.index('sha256sum --check --status')
destructive_checkout = source.index('rm -rf "$install_dir"')
if checksum >= destructive_checkout:
    raise SystemExit("Hermes checkout is modified before installer verification")
installer = source.index('if bash "$installer"')
user_args = source.index('"${args[@]}"', installer)
pinned_dir = source.index('--dir "$install_dir"', user_args)
head_check = source.index('git -C "$install_dir" rev-parse HEAD', installer)
origin_reset = source.index('git -C "$install_dir" remote set-url origin', head_check)
if not installer < user_args < pinned_dir < head_check < origin_reset:
    raise SystemExit("bundle origin is reset before installer and exact-HEAD verification")

box = Path("box").read_text()
stage_root = box.index('chown root:root "$stage" "$stage/home"')
stage_traverse = box.index('chmod 0711 "$stage" "$stage/home"', stage_root)
nested_owner = box.index('chown -R agent:agent "$stage/home/agent"', stage_traverse)
staged_verify = box.index('setpriv --reuid=agent', nested_owner)
if not stage_root < stage_traverse < nested_owner < staged_verify:
    raise SystemExit("restore ownership boundary is not established before agent verification")
if 'chown agent:agent "$stage"' in box:
    raise SystemExit("restore stage root is writable by the agent")
PY
if grep -q 'curl .*install.sh.*|.*bash' provision/provision.sh; then
  echo "unverified Hermes installer execution remains" >&2
  exit 1
fi
grep -q 'HERMES_INSTALL_ARGS cannot override protected installer option' provision/provision.sh
if grep -q 'git -C "$install_dir" fetch origin main' provision/provision.sh; then
  echo "bundle provisioning still fetches the public origin" >&2
  exit 1
fi
grep -q 'BOX_OVERLAY_GIB="64"' box.env
grep -q 'gateway-disable' box
grep -Fq -- '--exclude="*/.hermes/*.db-wal"' box
if grep -Fq -- '--exclude="*.db-wal"' box; then
  echo "unrelated /data SQLite WAL files are still excluded" >&2
  exit 1
fi
grep -q 'LoadCredential=backup-passphrase' ops/systemd/tx9-backup@.service
if grep -q '^Requires=tx9-box@' ops/systemd/tx9-*.service; then
  echo "timer service still pulls the box service active" >&2
  exit 1
fi
grep -q '^Type=simple$' ops/systemd/tx9-box@.service
grep -q 'tx9-host supervise %i' ops/systemd/tx9-box@.service
grep -Fq 'ExecStop=-/bin/kill -TERM $MAINPID' ops/systemd/tx9-box@.service
if grep -q '^RemainAfterExit=' ops/systemd/tx9-box@.service; then
  echo "box supervisor is still modeled as a oneshot service" >&2
  exit 1
fi
if grep -q 'chown -R' guest/hb; then
  echo "reconcile still recursively changes durable-tree ownership" >&2
  exit 1
fi
grep -q 'EXECUTOR_TARGET_PORT="${EXECUTOR_PORT:-4788}"' guest/hb-workload
grep -q 'TCP:127.0.0.1:$EXECUTOR_TARGET_PORT' guest/hb-workload
grep -q '_wait_api_ready' guest/hb-workload
grep -q '\[ ! -e "$GATEWAY_DISABLED" \]' guest/hb-workload
grep -q '\[ "$reconciled" = 1 \]' guest/hb-workload
grep -q '_refresh_targets' guest/hb-workload
grep -q '\. "$BOX_ENV"' guest/hb-workload
grep -q '_stop_executor_bridge' guest/hb-workload
grep -q 'LEGACY_QUIESCE_FILE' guest/hb guest/hb-workload
grep -q 'Executor target port closed while quiesced' guest/hb
grep -q 'gateway-is-disabled' guest/hb box
grep -q "printf 'http://%s:%s/mcp'.*EXECUTOR_PORT:-4788" guest/hb
grep -q 'guest_tmp="/data/home/agent/.config/hermes-box/import-' box
if grep -q 'guest_tmp="/root/hermes-import-' box; then
  echo "Hermes import remains unreadable to the agent" >&2
  exit 1
fi
grep -qi 'networking is always enabled' README.md
grep -q 'check.yml. runs it on every push' README.md
[[ -f .depot/workflows/check.yml ]]
grep -q 'make check' .depot/workflows/check.yml

echo "static checks passed"
