#!/usr/bin/env bash
# Container PID-1 workload (run under docker --init so signals behave).
# Reuses guest/hb-workload verbatim: it reconciles Executor, the Hermes
# gateway, and the 0.0.0.0 socat bridges every 20s. The outer loop is the
# supervisor for the loop process itself; Docker's restart policy is the
# supervisor for the container.
set -uo pipefail

trap 'exit 143' TERM
trap 'exit 130' INT

# Docker's supplemental groups reach `docker exec -u agent`, but runuser
# intentionally rebuilds the agent's group list from /etc/group. Register the
# host-mount GIDs in the container account before hb-workload starts so Hermes
# and every other long-running agent process keep the same mount access.
configure_mount_groups() {
  local gid group
  local -a gids
  IFS=',' read -r -a gids <<<"${TX9_AGENT_MOUNT_GIDS:-}"
  for gid in "${gids[@]}"; do
    [[ -n "$gid" ]] || continue
    if ! [[ "$gid" =~ ^[0-9]+$ ]] || ((gid <= 0)); then
      echo "invalid TX9 agent mount GID: $gid" >&2
      return 1
    fi
    group="$(getent group "$gid" | cut -d: -f1)"
    if [[ -z "$group" ]]; then
      group="tx9-mount-$gid"
      groupadd --gid "$gid" "$group" || return 1
    fi
    usermod --append --groups "$group" agent || return 1
  done
}

configure_mount_groups || exit 1

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
