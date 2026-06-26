#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
pids=()
cleaned_up=0

cleanup() {
  local pid
  [[ "$cleaned_up" == 0 ]] || return 0
  cleaned_up=1
  for pid in "${pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$tmp"
}

handle_signal() {
  local status="$1"
  trap - EXIT HUP INT TERM
  cleanup
  exit "$status"
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
[[ "$(trap -p HUP)" == *"handle_signal 129"* ]]
[[ "$(trap -p INT)" == *"handle_signal 130"* ]]
[[ "$(trap -p TERM)" == *"handle_signal 143"* ]]

wait_for_file() {
  local file="$1" attempt
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -s "$file" ]] && return
    sleep 0.02
  done
  echo "timed out waiting for $file" >&2
  return 1
}

wait_for_pattern() {
  local pattern="$1" file="$2" attempt
  for ((attempt = 0; attempt < 100; attempt++)); do
    grep -q "$pattern" "$file" 2>/dev/null && return
    sleep 0.02
  done
  echo "timed out waiting for '$pattern' in $file" >&2
  return 1
}

start_mcp_server() {
  local status="$1" label="$2" mode="${3:-valid}" bind_host="${4:-127.0.0.1}" port_file delete_file
  port_file="$tmp/$label.port"
  delete_file="$tmp/$label.delete"
  python3 "$PROJECT_ROOT/tests/fixtures/mcp-server.py" "$port_file" "$status" "$delete_file" "$mode" "$bind_host" &
  MCP_PID=$!
  pids+=("$MCP_PID")
  wait_for_file "$port_file"
  MCP_PORT="$(cat "$port_file")"
  MCP_DELETE_FILE="$delete_file"
}

# Basic VM operations do not require HTTP health tools; health operations do.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  have() { [[ "$1" == awk || "$1" == smolvm ]]; }
  _host_preflight basic
)
for missing_health_tool in curl jq mktemp; do
  if (
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/box"
    have() { [[ "$1" != "$missing_health_tool" ]]; }
    _host_preflight health
  ) 2>/dev/null; then
    echo "health preflight passed without $missing_health_tool" >&2
    exit 1
  fi
done

# The runtime manifest must be writable by the unprivileged durable-home owner,
# atomically published beneath that home, and private.
manifest_data="$tmp/manifest-data"
HB_DATA="$manifest_data" "$PROJECT_ROOT/guest/hb" init
HB_DATA="$manifest_data" "$PROJECT_ROOT/guest/hb" write-manifest
manifest="$manifest_data/home/agent/.config/hermes-box/runtime-manifest"
[[ -s "$manifest" ]]
[[ "$(stat -c '%a' "$manifest" 2>/dev/null || stat -f '%Lp' "$manifest")" == 600 ]]
[[ "$(stat -c '%u' "$manifest" 2>/dev/null || stat -f '%u' "$manifest")" == "$(id -u)" ]]
[[ -z "$(find "$(dirname "$manifest")" -name 'runtime-manifest.tmp.*' -print -quit)" ]]

# wire-once must execute its disabled cleanup path without requiring Executor.
(
  HB_DATA="$tmp/disabled-wire-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  _unwire_legacy() { :; }
  mkdir -p "$(dirname "$TOKEN_ENV")"
  printf 'stale\n' >"$WIRED"
  printf 'stale\n' >"$TOKEN_ENV"
  WIRE_EXECUTOR_MCP=0 wire_once >/dev/null
  [[ ! -e "$WIRED" && ! -e "$TOKEN_ENV" ]]
)

# Protocol-correct MCP initialize requires exact 200 plus a session header and
# closes the created session. Other HTTP statuses are unhealthy.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  REG="$tmp/empty-registry"
  touch "$REG"

  (
    doctor_calls="$tmp/doctor.calls"
    have() { [[ "$1" == awk || "$1" == smolvm ]]; }
    _acquire_lock() { :; }
    _machine_exists() { :; }
    smolvm() { :; }
    _guest_hb() {
      printf '%s\n' "$2" >>"$doctor_calls"
      [[ "$2" != executor-token ]] || printf 'fixture-token\n'
    }
    mcp_attempts=0
    sleep() { :; }
    _mcp_initialize() {
      printf 'host-mcp\n' >>"$doctor_calls"
      mcp_attempts=$((mcp_attempts + 1))
      [[ "$mcp_attempts" -ge 3 ]]
    }

    doctor_output="$(cmd_doctor no-host-port)"
    grep -q 'host Executor MCP: skipped (no exposed host port)' <<<"$doctor_output"
    [[ "$(cat "$doctor_calls")" == $'up\nwire-once\ndoctor' ]]

    printf 'doctor-host\t4899\n' >"$REG"
    if (cmd_doctor doctor-host >/dev/null 2>&1); then
      echo "exposed-port doctor passed without host health dependencies" >&2
      exit 1
    fi
    [[ "$(cat "$doctor_calls")" == $'up\nwire-once\ndoctor\nup\nwire-once\ndoctor' ]]

    : >"$doctor_calls"
    have() { :; }
    cmd_doctor doctor-host >/dev/null
    [[ "$(cat "$doctor_calls")" == $'up\nwire-once\ndoctor\nexecutor-token\nhost-mcp\nhost-mcp\nhost-mcp' ]]

    : >"$doctor_calls"
    : >"$REG"
    WIRE_EXECUTOR_MCP=0 INSTALL_EXECUTOR=0 cmd_doctor disabled-executor >/dev/null
    [[ "$(cat "$doctor_calls")" == $'up\nwire-once\ndoctor' ]]
  )

  BOX_BROWSER=true _open_url 'http://localhost:1/?_token=not-printed'
  if BOX_BROWSER=definitely-not-a-browser _open_url 'http://localhost:1/?_token=not-printed'; then
    echo "missing BOX_BROWSER command unexpectedly succeeded" >&2
    exit 1
  fi
  uname() { printf 'Linux\n'; }
  xdg-open() { return 1; }
  gio() { [[ "$1" == open && "$2" == 'https://fixture.invalid/secret' ]]; }
  _open_url 'https://fixture.invalid/secret'
  uname() { printf 'Darwin\n'; }
  open() { [[ "$1" == 'https://fixture.invalid/secret' ]]; }
  _open_url 'https://fixture.invalid/secret'

  start_mcp_server 200 healthy
  _mcp_initialize "http://127.0.0.1:$MCP_PORT/mcp" fixture-token
  wait_for_pattern initialized "$MCP_DELETE_FILE"
  wait_for_pattern deleted "$MCP_DELETE_FILE"
  _wait_mcp_ready "http://127.0.0.1:$MCP_PORT/mcp" fixture-token
  if _mcp_initialize "http://127.0.0.1:$MCP_PORT/mcp" wrong-token; then
    echo "invalid bearer token passed MCP health" >&2
    exit 1
  fi
  malformed_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H 'Authorization: Bearer fixture-token' -H 'Content-Type: application/json' \
    -H 'Accept: application/json,text/event-stream' --data '{not-json' \
    "http://127.0.0.1:$MCP_PORT/mcp")"
  [[ "$malformed_code" == 400 ]]
  for invalid_request in \
    '[]' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":[]}' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":[]}}'; do
    invalid_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      -H 'Authorization: Bearer fixture-token' -H 'Content-Type: application/json' \
      -H 'Accept: application/json,text/event-stream' --data "$invalid_request" \
      "http://127.0.0.1:$MCP_PORT/mcp")"
    [[ "$invalid_code" == 400 ]]
  done
  invalid_length_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H 'Authorization: Bearer fixture-token' -H 'Content-Type: application/json' \
    -H 'Accept: application/json,text/event-stream' -H 'Content-Length: invalid' \
    --data '{}' "http://127.0.0.1:$MCP_PORT/mcp")"
  [[ "$invalid_length_code" == 400 ]]

  guest_token_dir="$tmp/guest-token/.executor/server-control"
  mkdir -p "$guest_token_dir"
  printf '{"token":"fixture-token"}\n' >"$guest_token_dir/auth.json"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  TOKEN_FILE="$guest_token_dir/auth.json"
  EXECUTOR_PORT="$MCP_PORT"
  _mcp_auth_works
  printf '{"token":"wrong-token"}\n' >"$guest_token_dir/auth.json"
  if _mcp_auth_works; then
    echo "guest MCP health accepted an invalid bearer token" >&2
    exit 1
  fi
  if _port_free "$MCP_PORT"; then
    echo "occupied TCP port was reported free" >&2
    exit 1
  fi
  kill "$MCP_PID"
  wait "$MCP_PID" 2>/dev/null || true

  if python3 -c 'import socket; s = socket.socket(socket.AF_INET6); s.bind(("::1", 0)); s.close()'; then
    start_mcp_server 200 ipv6-only valid ::1
    if _port_free "$MCP_PORT"; then
      echo "IPv6-only occupied TCP port was reported free" >&2
      exit 1
    fi
    kill "$MCP_PID"
    wait "$MCP_PID" 2>/dev/null || true
  else
    echo "IPv6 loopback unavailable; skipping IPv6 occupancy regression" >&2
  fi

  start_mcp_server 200 malformed-json malformed-json
  if _mcp_initialize "http://127.0.0.1:$MCP_PORT/mcp" fixture-token; then
    echo "malformed initialize JSON passed MCP health" >&2
    exit 1
  fi
  kill "$MCP_PID"
  wait "$MCP_PID" 2>/dev/null || true

  start_mcp_server 200 wrong-version wrong-version
  if _mcp_initialize "http://127.0.0.1:$MCP_PORT/mcp" fixture-token; then
    echo "wrong negotiated MCP version passed health" >&2
    exit 1
  fi
  kill "$MCP_PID"
  wait "$MCP_PID" 2>/dev/null || true

  start_mcp_server 200 wrong-content-type wrong-content-type
  if _mcp_initialize "http://127.0.0.1:$MCP_PORT/mcp" fixture-token; then
    echo "wrong initialize Content-Type passed MCP health" >&2
    exit 1
  fi
  kill "$MCP_PID"
  wait "$MCP_PID" 2>/dev/null || true

  start_mcp_server 200 event-stream event-stream
  _mcp_initialize "http://127.0.0.1:$MCP_PORT/mcp" fixture-token
  kill "$MCP_PID"
  wait "$MCP_PID" 2>/dev/null || true

  start_mcp_server 404 missing
  if _mcp_initialize "http://127.0.0.1:$MCP_PORT/mcp" fixture-token; then
    echo "HTTP 404 passed MCP health" >&2
    exit 1
  fi
  kill "$MCP_PID"
  wait "$MCP_PID" 2>/dev/null || true

  start_mcp_server 500 broken
  if _mcp_initialize "http://127.0.0.1:$MCP_PORT/mcp" fixture-token; then
    echo "HTTP 500 passed MCP health" >&2
    exit 1
  fi
  kill "$MCP_PID"
  wait "$MCP_PID" 2>/dev/null || true

  free_port="$MCP_PORT"
  for ((attempt = 0; attempt < 100; attempt++)); do
    _port_free "$free_port" && break
    sleep 0.02
  done
  _port_free "$free_port"

  ready_attempts=0
  opener_attempt=0
  _mcp_initialize() {
    ready_attempts=$((ready_attempts + 1))
    [[ "$ready_attempts" -ge 3 ]]
  }
  _open_url() { opener_attempt="$ready_attempts"; }
  _wait_mcp_ready ignored ignored
  _open_url 'https://fixture.invalid/secret'
  [[ "$ready_attempts" == 3 && "$opener_attempt" == 3 ]]
)

mkdir -p "$tmp/valid/home/agent/workspace" "$tmp/gnupg" "$tmp/host-tmp"
chmod 0700 "$tmp/gnupg"
printf 'portable state\n' >"$tmp/valid/home/agent/workspace/probe.txt"
tar czf "$tmp/valid.tgz" -C "$tmp/valid" .
export GNUPGHOME="$tmp/gnupg"
export BOX_PASSPHRASE='regression-passphrase'
gpg --batch --yes --pinentry-mode loopback --passphrase "$BOX_PASSPHRASE" \
  --symmetric --cipher-algo AES256 -o "$tmp/valid.tar.gz.gpg" "$tmp/valid.tgz"

make_repo() {
  local dest="$1"
  mkdir -p "$dest"
  cp "$PROJECT_ROOT/box" "$PROJECT_ROOT/box.env" "$dest/"
  cp -R "$PROJECT_ROOT/guest" "$PROJECT_ROOT/provision" "$dest/"
}

# A failed precheck must preserve a same-named unmanaged smolvm machine.
preexisting_repo="$tmp/preexisting-repo"
make_repo "$preexisting_repo"
mkdir -p "$tmp/preexisting-state/owned-elsewhere"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/preexisting.calls" \
  SMOLVM_STATE_DIR="$tmp/preexisting-state" SMOLVM_BEHAVIOR=success \
  "$preexisting_repo/box" new owned-elsewhere >/dev/null 2>&1; then
  echo "creation over a preexisting machine unexpectedly succeeded" >&2
  exit 1
fi
[[ -d "$tmp/preexisting-state/owned-elsewhere" ]]

# If create reports failure after another machine appears, ownership is unknown
# and cleanup must preserve that race winner.
race_repo="$tmp/race-repo"
make_repo "$race_repo"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/race.calls" \
  SMOLVM_STATE_DIR="$tmp/race-state" SMOLVM_BEHAVIOR=create-race \
  "$race_repo/box" new race-winner >/dev/null 2>&1; then
  echo "ambiguous create race unexpectedly succeeded" >&2
  exit 1
fi
[[ -d "$tmp/race-state/race-winner" ]]
if grep -q 'machine delete' "$tmp/race.calls"; then
  echo "ambiguous create race winner was deleted" >&2
  exit 1
fi

# TERM during provisioning rolls back the invocation-owned VM and registry.
signal_repo="$tmp/signal-repo"
make_repo "$signal_repo"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/signal.calls" \
  SMOLVM_STATE_DIR="$tmp/signal-state" SMOLVM_BEHAVIOR=block-provision \
  "$signal_repo/box" new signal-probe >/dev/null 2>&1; then
  echo "signal-interrupted creation unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -d "$tmp/signal-state/signal-probe" ]]
[[ ! -s "$signal_repo/.boxes" ]]

# A signal delivered while create itself succeeds is deferred until ownership
# and registry metadata are recorded, then cleanup safely removes the owned VM.
create_signal_repo="$tmp/create-signal-repo"
make_repo "$create_signal_repo"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/create-signal.calls" \
  SMOLVM_STATE_DIR="$tmp/create-signal-state" SMOLVM_BEHAVIOR=signal-create-success \
  "$create_signal_repo/box" new create-signal-probe >/dev/null 2>&1; then
  echo "create-time signal unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -d "$tmp/create-signal-state/create-signal-probe" ]]
[[ ! -s "$create_signal_repo/.boxes" ]]
grep -q 'machine create' "$tmp/create-signal.calls"
grep -q 'machine delete' "$tmp/create-signal.calls"
if grep -q 'machine start' "$tmp/create-signal.calls"; then
  echo "create-time signal was not honored before start" >&2
  exit 1
fi

# Pause may have taken effect even when the pause command reports failure. The
# existing box is tracked early and resumed during cleanup.
pause_repo="$tmp/pause-repo"
make_repo "$pause_repo"
mkdir -p "$tmp/pause-state/pause-probe"
printf 'pause-probe\t\n' >"$pause_repo/.boxes"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/pause.calls" \
  SMOLVM_STATE_DIR="$tmp/pause-state" SMOLVM_BEHAVIOR=pause-fail \
  "$pause_repo/box" save pause-probe "$tmp/pause.gpg" >/dev/null 2>&1; then
  echo "failed pause unexpectedly allowed save" >&2
  exit 1
fi
grep -q 'hb resume' "$tmp/pause.calls"
[[ ! -e "$tmp/pause-state/pause-probe/paused" ]]

# Rollback remains best-effort when another process owns the registry lock: VM
# deletion and operation-lock cleanup still happen, while metadata is preserved.
contention_repo="$tmp/contention-repo"
make_repo "$contention_repo"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/contention.calls" \
  SMOLVM_STATE_DIR="$tmp/contention-state" SMOLVM_BEHAVIOR=registry-contention \
  SMOLVM_REGISTRY_LOCK_DIR="$contention_repo/.box-locks/registry.lock" \
  SMOLVM_REGISTRY_LOCK_OWNER_PID="$$" \
  "$contention_repo/box" new contention-probe >/dev/null 2>&1; then
  echo "registry-contention provisioning unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -d "$tmp/contention-state/contention-probe" ]]
grep -q '^contention-probe' "$contention_repo/.boxes"
[[ ! -e "$contention_repo/.box-locks/contention-probe.lock" ]]

# Rollback recovers a stale registry lock without aborting best-effort cleanup.
stale_lock_repo="$tmp/stale-lock-repo"
make_repo "$stale_lock_repo"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/stale-lock.calls" \
  SMOLVM_STATE_DIR="$tmp/stale-lock-state" SMOLVM_BEHAVIOR=stale-registry-lock \
  SMOLVM_REGISTRY_LOCK_DIR="$stale_lock_repo/.box-locks/registry.lock" \
  "$stale_lock_repo/box" new stale-lock-probe >/dev/null 2>&1; then
  echo "stale-lock provisioning unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -d "$tmp/stale-lock-state/stale-lock-probe" ]]
[[ ! -s "$stale_lock_repo/.boxes" ]]
[[ ! -e "$stale_lock_repo/.box-locks/registry.lock" ]]
[[ ! -e "$stale_lock_repo/.box-locks/stale-lock-probe.lock" ]]

# A failed delete preserves both the incomplete machine and its registry record.
delete_repo="$tmp/delete-repo"
make_repo "$delete_repo"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/delete.calls" \
  SMOLVM_STATE_DIR="$tmp/delete-state" SMOLVM_BEHAVIOR=delete-fail \
  "$delete_repo/box" new delete-probe >/dev/null 2>&1; then
  echo "delete-failure provisioning unexpectedly succeeded" >&2
  exit 1
fi
[[ -d "$tmp/delete-state/delete-probe" ]]
grep -q '^delete-probe' "$delete_repo/.boxes"

# A delete error plus a generic status error is never interpreted as absence.
delete_status_repo="$tmp/delete-status-repo"
make_repo "$delete_status_repo"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/delete-status.calls" \
  SMOLVM_STATE_DIR="$tmp/delete-status-state" SMOLVM_BEHAVIOR=delete-status-fail \
  "$delete_status_repo/box" new delete-status-probe >/dev/null 2>&1; then
  echo "delete/status-failure provisioning unexpectedly succeeded" >&2
  exit 1
fi
[[ -d "$tmp/delete-status-state/delete-status-probe" ]]
grep -q '^delete-status-probe' "$delete_status_repo/.boxes"

# Registration happens before start, so a start failure plus delete failure
# leaves enough host metadata for explicit recovery.
start_delete_repo="$tmp/start-delete-repo"
make_repo "$start_delete_repo"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/start-delete.calls" \
  SMOLVM_STATE_DIR="$tmp/start-delete-state" SMOLVM_BEHAVIOR=start-delete-fail \
  "$start_delete_repo/box" new start-delete-probe >/dev/null 2>&1; then
  echo "start/delete failure unexpectedly succeeded" >&2
  exit 1
fi
[[ -d "$tmp/start-delete-state/start-delete-probe" ]]
grep -q '^start-delete-probe' "$start_delete_repo/.boxes"

# Save failures remove the guest plaintext before resuming Executor.
save_repo="$tmp/save-repo"
make_repo "$save_repo"
mkdir -p "$tmp/save-state/save-probe"
printf 'save-probe\t\n' >"$save_repo/.boxes"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/save.calls" \
  SMOLVM_STATE_DIR="$tmp/save-state" SMOLVM_BEHAVIOR=save-cp-fail \
  SMOLVM_ARCHIVE_SOURCE="$tmp/valid.tgz" TMPDIR="$tmp/host-tmp" \
  "$save_repo/box" save save-probe "$tmp/save.gpg" >/dev/null 2>&1; then
  echo "save copy failure unexpectedly succeeded" >&2
  exit 1
fi
grep -q '/root/hb-data-' "$tmp/save.calls"
remove_line="$(grep -n 'rm -f -- /root/hb-data-' "$tmp/save.calls" | head -1 | cut -d: -f1)"
resume_line="$(grep -n 'hb resume' "$tmp/save.calls" | head -1 | cut -d: -f1)"
[[ -n "$remove_line" && -n "$resume_line" && "$remove_line" -lt "$resume_line" ]]
[[ -z "$(find "$tmp/host-tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]]

# Restore extraction failures propagate, delete the incomplete VM, and contain
# the fail-fast extraction and guest-temp trap in the invoked command.
restore_repo="$tmp/restore-repo"
make_repo "$restore_repo"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/restore.calls" \
  SMOLVM_STATE_DIR="$tmp/restore-state" SMOLVM_BEHAVIOR=restore-tar-fail \
  "$restore_repo/box" load "$tmp/valid.tar.gz.gpg" restore-probe >/dev/null 2>&1; then
  echo "restore tar failure unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -d "$tmp/restore-state/restore-probe" ]]
if grep -q 'hb resume' "$tmp/restore.calls"; then
  echo "failed restore resumed Executor before deleting its new VM" >&2
  exit 1
fi
grep -q 'machine delete' "$tmp/restore.calls"
grep -q 'chmod 0600 /root/hb-restore-' "$tmp/restore.calls"
restore_remove_line="$(grep -n 'rm -f -- /root/hb-restore-' "$tmp/restore.calls" | head -1 | cut -d: -f1)"
restore_delete_line="$(grep -n 'machine delete' "$tmp/restore.calls" | head -1 | cut -d: -f1)"
[[ -n "$restore_remove_line" && -n "$restore_delete_line" && "$restore_remove_line" -lt "$restore_delete_line" ]]
grep -q 'set -euo pipefail' "$tmp/restore.calls"
grep -q 'trap.*rm -f --.*archive' "$tmp/restore.calls"

echo "focused regression checks passed"
