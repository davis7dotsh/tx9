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

exec runuser -u agent -- env HOME=/data/home/agent \
  bash --noprofile --norc -c '. /etc/profile.d/hermes-box.sh
    exec executor daemon run --foreground --hostname 0.0.0.0 --port 4788 \
      --auth-token "$EXECUTOR_MCP_TOKEN"'
