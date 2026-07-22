#!/usr/bin/env bash
# Container PID-1 workload (run under docker --init so signals behave).
# Reuses guest/hb-workload verbatim: it reconciles custom services, Executor,
# the Hermes gateway, and the 0.0.0.0 socat bridges every 20s. tx9-logs
# supervises the loop process itself; Docker's restart policy supervises the
# container.
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

# Runtime log limits are image defaults in the managed box environment. They
# are passed explicitly because runuser starts tx9-logs without a login shell.
# shellcheck disable=SC1091
[ ! -r /etc/hermes-box.env ] || . /etc/hermes-box.env

EXEC_BRIDGE_PORT="${BOX_EXECUTOR_BRIDGE_PORT:-14788}"
API_BRIDGE_PORT="${BOX_HERMES_BRIDGE_PORT:-18642}"

# tx9-logs owns the existing restart loop so it can forward container signals
# to the active workload process group while mirroring redacted output to
# Docker and persisting workload.log + normalized agent.jsonl on the volume.
exec runuser -u agent -- env HOME=/data/home/agent \
  TX9_BOX_NAME="${TX9_BOX_NAME:-}" \
  TX9_LOG_MAX_BYTES="${TX9_LOG_MAX_BYTES:-20971520}" \
  TX9_LOG_MAX_FILES="${TX9_LOG_MAX_FILES:-5}" \
  /opt/hermes-box/bin/tx9-logs capture \
    --source agent --log-dir /data/logs --restart-delay 2 -- \
    /opt/hermes-box/bin/hb-workload "$EXEC_BRIDGE_PORT" "$API_BRIDGE_PORT"
