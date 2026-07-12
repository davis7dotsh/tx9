#!/usr/bin/env bash
# PID-1 for the executor service container. Runs ONLY the Executor daemon,
# foreground, as the agent user, bound to 0.0.0.0 so both the private compose
# network (the agent container) and the published host port (LAN/Tailscale
# dashboard) can reach it. The bearer token is the gate on every request.
#
# This container is the trust boundary: the hermes/agent container never
# shares a namespace, filesystem, or process table with it — its only surface
# is this HTTP endpoint.
set -euo pipefail

[[ -n "${EXECUTOR_MCP_TOKEN:-}" ]] || { echo "EXECUTOR_MCP_TOKEN is required" >&2; exit 1; }

mkdir -p /data/home/agent /data/logs
chown agent:agent /data/home/agent /data/logs

# tx9-logs remains in the foreground between runuser and Executor: it mirrors
# stdout/stderr to Docker, persists redacted executor.log + executor.jsonl,
# forwards signals to Executor's process group, and exits with its status.
# shellcheck disable=SC2016 # $EXECUTOR_MCP_TOKEN expands in the inner shell
exec runuser -u agent -- env HOME=/data/home/agent TX9_BOX_NAME="${TX9_BOX_NAME:-}" \
  bash --noprofile --norc -c '. /etc/profile.d/hermes-box.sh
    export TX9_LOG_MAX_BYTES TX9_LOG_MAX_FILES
    exec /opt/hermes-box/bin/tx9-logs capture --source executor --log-dir /data/logs -- \
      executor daemon run --foreground --hostname 0.0.0.0 --port 4788 \
        --auth-token "$EXECUTOR_MCP_TOKEN"'
