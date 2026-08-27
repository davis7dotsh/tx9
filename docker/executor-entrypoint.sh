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
exec runuser -u agent -- env HOME=/data/home/agent TX9_BOX_NAME="${TX9_BOX_NAME:-}" \
  bash --noprofile --norc -euo pipefail <<'WORKLOAD'
tx9_runtime_executor_token="$EXECUTOR_MCP_TOKEN"
# shellcheck disable=SC1091
. /etc/profile.d/hermes-box.sh
# Restored profile state must not replace the runtime's current credential.
export EXECUTOR_MCP_TOKEN="$tx9_runtime_executor_token"
export TX9_LOG_MAX_BYTES TX9_LOG_MAX_FILES

# Executor reads this token when --auth-token is absent. Keep the value out of
# both the capture wrapper's and the daemon's process arguments. The format is
# shared by Executor 1.5.26, 1.5.28, and 1.6.0.
python3 - <<'PY'
import json
import os
from pathlib import Path
import tempfile

data = Path(os.environ.get("EXECUTOR_DATA_DIR", str(Path.home() / ".executor"))).resolve()
control = data / "server-control"
control.mkdir(mode=0o700, parents=True, exist_ok=True)
control.chmod(0o700)
fd, temporary = tempfile.mkstemp(prefix=".auth-", dir=control)
try:
    with os.fdopen(fd, "w") as output:
        json.dump({"token": os.environ["EXECUTOR_MCP_TOKEN"]}, output)
        output.write("\n")
    os.replace(temporary, control / "auth.json")
finally:
    Path(temporary).unlink(missing_ok=True)
PY

exec /opt/hermes-box/bin/tx9-logs capture --source executor --log-dir /data/logs -- \
  executor daemon run --foreground --hostname 0.0.0.0 --port 4788 </dev/null
WORKLOAD
