#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# tests/regressions-*.sh is globbed so new split-out regression files are
# picked up automatically.
regression_files=(tests/regressions-*.sh)

files=(
  guest/hb
  guest/hb-workload
  guest/lib-mcp.sh
  guest/profile.sh
  guest/agent-bash-profile.sh
  provision/provision.sh
  docker/entrypoint.sh
  docker/executor-entrypoint.sh
  tests/lib.sh
  tests/hermes-state.sh
  "${regression_files[@]}"
)

bash -n "${files[@]}"
python3 -c 'compile(open("guest/hermes-state", encoding="utf-8").read(), "guest/hermes-state", "exec")'
for file in guest/hb guest/hb-workload guest/hermes-state provision/provision.sh tests/hermes-state.sh "${regression_files[@]}"; do
  [[ -x "$file" ]] || { echo "not executable: $file" >&2; exit 1; }
done

# --- guest/hb invariants ------------------------------------------------
grep -q 'WIRE_EXECUTOR_MCP' guest/hb
# HTTP MCP wiring goes through _executor_url (http://$EXECUTOR_HOST:$PORT/mcp,
# loopback by default, container-DNS name in the compose split).
grep -q "printf 'http://%s:%s/mcp' \"\$EXECUTOR_HOST\"" guest/hb
grep -q "printf 'http://%s:%s/mcp'.*EXECUTOR_PORT:-4788" guest/hb
if grep -q 'args = \["mcp"\]' guest/hb; then
  echo "legacy stdio Executor MCP wiring remains" >&2
  exit 1
fi
if grep -q 'chown -R' guest/hb; then
  echo "reconcile still recursively changes durable-tree ownership" >&2
  exit 1
fi
grep -q 'Executor target port closed while quiesced' guest/hb
grep -q 'gateway-is-disabled' guest/hb
grep -q 'LEGACY_QUIESCE_FILE' guest/hb guest/hb-workload
# The remote-executor override must outrank the on-disk token env, which a
# restore can carry stale from the source box.
grep -q 'BOXD_EXECUTOR_TOKEN' guest/hb

# --- guest/hb-workload invariants ----------------------------------------
grep -q 'EXECUTOR_TARGET_PORT="${EXECUTOR_PORT:-4788}"' guest/hb-workload
grep -q 'TCP:127.0.0.1:$EXECUTOR_TARGET_PORT' guest/hb-workload
grep -q '_wait_api_ready' guest/hb-workload
grep -q '\[ ! -e "$GATEWAY_DISABLED" \]' guest/hb-workload
grep -q '\[ "$reconciled" = 1 \]' guest/hb-workload
grep -q '_refresh_targets' guest/hb-workload
grep -q '\. "$BOX_ENV"' guest/hb-workload
grep -q '_stop_executor_bridge' guest/hb-workload

# --- provisioning / config invariants ------------------------------------
grep -q 'tools) tools_only ;;' provision/provision.sh
grep -q 'assets) assets_only ;;' provision/provision.sh
# Node/npm come from Vite+ (managed LTS); claude and codex use their native
# installers, not npm globals.
grep -q 'vite-plus' guest/profile.sh
grep -q 'env default lts' provision/provision.sh
grep -q 'claude.ai/install.sh' provision/provision.sh
grep -q 'chatgpt.com/codex/install.sh' provision/provision.sh
grep -Fq -- '--dir | --dir=* | --hermes-home' provision/provision.sh
if grep -q 'npm install -g' provision/provision.sh; then
  echo "provision.sh still installs npm globals directly (use vp install -g)" >&2
  exit 1
fi

# --- docker build assets --------------------------------------------------
grep -q 'provision.sh tools' docker/Dockerfile
grep -q 'provision.sh assets' docker/Dockerfile
grep -q 'EXECUTOR_MCP_TOKEN' docker/executor-entrypoint.sh
grep -q -- '--hostname 0.0.0.0' docker/executor-entrypoint.sh

grep -qi 'networking is always enabled' README.md

echo "static checks passed"
