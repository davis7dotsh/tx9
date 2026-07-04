#!/usr/bin/env bash
# Container PID-1 workload (run under docker --init so signals behave).
# Reuses guest/hb-workload verbatim: it reconciles Executor, the Hermes
# gateway, and the 0.0.0.0 socat bridges every 20s. The outer loop is the
# supervisor for the loop process itself; Docker's restart policy is the
# supervisor for the container.
set -uo pipefail

trap 'exit 143' TERM
trap 'exit 130' INT

# Idempotent: ensures the /data skeleton and gateway-policy markers exist
# even when the volume predates this image (e.g. restored from a backup).
# Fail fast if it can't — a container without a sane /data must not look
# healthy, so the restart policy (not a silent loop) handles recovery.
/opt/hermes-box/bin/hb init || exit 1

EXEC_BRIDGE_PORT="${BOX_EXECUTOR_BRIDGE_PORT:-14788}"
API_BRIDGE_PORT="${BOX_HERMES_BRIDGE_PORT:-18642}"

while true; do
  runuser -u agent -- env HOME=/data/home/agent \
    /opt/hermes-box/bin/hb-workload "$EXEC_BRIDGE_PORT" "$API_BRIDGE_PORT" || true
  sleep 2
done
