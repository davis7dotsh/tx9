#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2329
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

# Scheduled host health gates on an already-running box and never starts one.
host_root="$tmp/tx9-host-root"
mkdir -p "$host_root" "$tmp/tx9-host-state/scheduled"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"${TX9_BOX_CALLS:?}"\n' >"$host_root/box"
chmod +x "$host_root/box"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/tx9-inactive.smolvm" \
  SMOLVM_STATE_DIR="$tmp/tx9-host-state" SMOLVM_BEHAVIOR=inactive \
  SMOLVM_CALLED_UNUSED=1 TX9_ROOT="$host_root" TX9_BOX_CALLS="$tmp/tx9-inactive.box" \
  "$PROJECT_ROOT/ops/tx9-host" health scheduled >/dev/null 2>&1; then
  echo "scheduled health accepted an inactive box" >&2
  exit 1
fi
[[ ! -e "$tmp/tx9-inactive.box" ]]
if grep -q 'machine start' "$tmp/tx9-inactive.smolvm"; then
  echo "scheduled health started an inactive box" >&2
  exit 1
fi
PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/tx9-active.smolvm" \
  SMOLVM_STATE_DIR="$tmp/tx9-host-state" SMOLVM_BEHAVIOR=success \
  TX9_ROOT="$host_root" TX9_BOX_CALLS="$tmp/tx9-active.box" \
  "$PROJECT_ROOT/ops/tx9-host" health scheduled >/dev/null
grep -q '^doctor scheduled$' "$tmp/tx9-active.box"

# Sourced configuration cannot redirect an operation to another box name.
mkdir -p "$tmp/tx9-config/boxes"
printf 'name=global-override\nTX9_BOX_CONFIG_DIR=%s\n' "$tmp/tx9-config/boxes" >"$tmp/tx9-config/global.conf"
printf 'name=box-override\n' >"$tmp/tx9-config/boxes/scheduled.conf"
PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/tx9-config-name.smolvm" \
  SMOLVM_STATE_DIR="$tmp/tx9-host-state" SMOLVM_BEHAVIOR=success \
  TX9_CONFIG="$tmp/tx9-config/global.conf" TX9_ROOT="$host_root" \
  TX9_BOX_CALLS="$tmp/tx9-config-name.box" \
  "$PROJECT_ROOT/ops/tx9-host" health scheduled >/dev/null
[[ "$(cat "$tmp/tx9-config-name.box")" == 'doctor scheduled' ]]

# The foreground supervisor starts once and restarts an unexpectedly stopped VM.
PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/tx9-supervise.smolvm" \
  SMOLVM_STATE_DIR="$tmp/tx9-host-state" SMOLVM_BEHAVIOR=inactive \
  TX9_ROOT="$host_root" TX9_BOX_CALLS="$tmp/tx9-supervise.box" TX9_SUPERVISE_ONCE=1 \
  "$PROJECT_ROOT/ops/tx9-host" supervise scheduled >/dev/null 2>&1
[[ "$(grep -c '^start scheduled$' "$tmp/tx9-supervise.box")" == 2 ]]

# A supervisor that receives stop intent exits without probing or restarting.
PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/tx9-supervise-stop.smolvm" \
  SMOLVM_STATE_DIR="$tmp/tx9-host-state" SMOLVM_BEHAVIOR=inactive \
  TX9_ROOT="$host_root" TX9_BOX_CALLS="$tmp/tx9-supervise-stop.box" \
  TX9_SUPERVISE_INTERVAL_SECONDS=300 \
  "$PROJECT_ROOT/ops/tx9-host" supervise scheduled >/dev/null 2>&1 &
supervisor_pid=$!
pids+=("$supervisor_pid")
wait_for_pattern '^start scheduled$' "$tmp/tx9-supervise-stop.box"
kill -TERM "$supervisor_pid"
wait "$supervisor_pid"
[[ "$(grep -c '^start scheduled$' "$tmp/tx9-supervise-stop.box")" == 1 ]]
[[ ! -e "$tmp/tx9-supervise-stop.smolvm" ]]

# Root-run installer state is recursively returned to the agent and made
# writable, including nested runtime directories created during full repair.
hermes_fixture="$tmp/installer-hermes-home"
mkdir -p "$hermes_fixture/sessions/deep" "$hermes_fixture/cron" "$hermes_fixture/logs"
printf 'session\n' >"$hermes_fixture/sessions/deep/history.json"
printf 'job\n' >"$hermes_fixture/cron/jobs.json"
chmod 0500 "$hermes_fixture/sessions/deep"
chmod 0400 "$hermes_fixture/sessions/deep/history.json" "$hermes_fixture/cron/jobs.json"
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/provision/provision.sh"
  HERMES_HOME="$hermes_fixture"
  chown() {
    [[ "$1" == -R && "$2" == agent:agent && "$3" == "$hermes_fixture" ]]
    printf 'recursive agent ownership\n' >"$tmp/hermes-chown.called"
  }
  own_hermes_home
)
[[ -s "$tmp/hermes-chown.called" ]]
[[ -w "$hermes_fixture/sessions/deep/history.json" ]]
[[ -w "$hermes_fixture/cron/jobs.json" ]]
[[ -w "$hermes_fixture/sessions/deep" ]]

# Restore staging grants non-owners traversal but not top-level mutation; only
# the nested agent home models owner-writable imported state.
permission_stage="$tmp/restore-permission-model"
mkdir -p "$permission_stage/home/agent"
chmod 0711 "$permission_stage" "$permission_stage/home"
chmod 0700 "$permission_stage/home/agent"
python3 - "$permission_stage" <<'PY'
import os
import stat
import sys
from pathlib import Path

stage = Path(sys.argv[1])
home = stage / "home"
agent = home / "agent"
for envelope in (stage, home):
    mode = stat.S_IMODE(envelope.stat().st_mode)
    assert mode == 0o711
    assert mode & 0o001
    assert not mode & 0o002
assert stat.S_IMODE(agent.stat().st_mode) == 0o700
assert os.access(agent, os.W_OK)
PY

# Hermes API forwarding requires a successful reconcile, an enabled gateway,
# and a listening target API.
(
  HOME="$tmp/workload-home"
  mkdir -p "$HOME/.config/hermes-box" "$tmp/workload-logs"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb-workload"
  PORT=4799
  HERMES_BRIDGE_PORT=8650
  LOGS="$tmp/workload-logs"
  BOX_ENV="$tmp/workload-box.env"
  LEGACY_QUIESCE_FILE="$tmp/workload-legacy-paused"
  printf 'EXECUTOR_PORT=4788\nHERMES_API_PORT=8642\n' >"$BOX_ENV"
  pgrep() { return 1; }
  pkill() { printf 'stopped %s\n' "$*" >>"$tmp/api-bridge.events"; }
  socat() { printf 'started %s\n' "$*" >>"$tmp/api-bridge.events"; }
  _exec_up() { return 0; }
  hb() { return 1; }
  _wait_api_ready() { return 0; }
  reconcile_once
  if grep -q 'started.*TCP-LISTEN:8650,' "$tmp/api-bridge.events" 2>/dev/null; then
    echo "API bridge started after failed reconcile" >&2; exit 1
  fi
  hb() { return 0; }
  _wait_api_ready() { return 1; }
  reconcile_once
  if grep -q 'started.*TCP-LISTEN:8650,' "$tmp/api-bridge.events" 2>/dev/null; then
    echo "API bridge started before its target was ready" >&2; exit 1
  fi
  _wait_api_ready() { return 0; }
  reconcile_once
  wait
  grep -q started "$tmp/api-bridge.events"
  printf 'EXECUTOR_PORT=4990\nHERMES_API_PORT=8990\n' >"$BOX_ENV"
  reconcile_once
  wait
  grep -q 'stopped.*TCP-LISTEN:4799,' "$tmp/api-bridge.events"
  grep -q 'stopped.*TCP-LISTEN:8650,' "$tmp/api-bridge.events"
  grep -q 'started.*TCP:127.0.0.1:4990' "$tmp/api-bridge.events"
  grep -q 'started.*TCP:127.0.0.1:8990' "$tmp/api-bridge.events"
  api_stops_before="$(grep -c 'stopped.*TCP-LISTEN:8650,' "$tmp/api-bridge.events")"
  touch "$GATEWAY_DISABLED"
  reconcile_once
  [[ "$(grep -c 'stopped.*TCP-LISTEN:8650,' "$tmp/api-bridge.events")" -gt "$api_stops_before" ]]
  executor_stops_before="$(grep -c 'stopped.*TCP-LISTEN:4799,' "$tmp/api-bridge.events")"
  api_stops_before="$(grep -c 'stopped.*TCP-LISTEN:8650,' "$tmp/api-bridge.events")"
  touch "$QUIESCE_FILE"
  reconcile_once
  [[ "$(grep -c 'stopped.*TCP-LISTEN:4799,' "$tmp/api-bridge.events")" -gt "$executor_stops_before" ]]
  [[ "$(grep -c 'stopped.*TCP-LISTEN:8650,' "$tmp/api-bridge.events")" -gt "$api_stops_before" ]]
  rm -f "$QUIESCE_FILE"
  executor_stops_before="$(grep -c 'stopped.*TCP-LISTEN:4799,' "$tmp/api-bridge.events")"
  api_stops_before="$(grep -c 'stopped.*TCP-LISTEN:8650,' "$tmp/api-bridge.events")"
  hb() { touch "$tmp/legacy-workload-reconciled"; return 0; }
  touch "$LEGACY_QUIESCE_FILE"
  reconcile_once
  [[ -e "$QUIESCE_FILE" ]]
  [[ ! -e "$LEGACY_QUIESCE_FILE" ]]
  [[ ! -e "$tmp/legacy-workload-reconciled" ]]
  [[ "$(grep -c 'stopped.*TCP-LISTEN:4799,' "$tmp/api-bridge.events")" -gt "$executor_stops_before" ]]
  [[ "$(grep -c 'stopped.*TCP-LISTEN:8650,' "$tmp/api-bridge.events")" -gt "$api_stops_before" ]]

  migration_failure="$tmp/workload-migration-failure"
  mkdir -p "$migration_failure"
  chmod 0500 "$migration_failure"
  QUIESCE_FILE="$migration_failure/state/quiesced"
  LEGACY_QUIESCE_FILE="$tmp/workload-legacy-failure"
  rm -f "$tmp/legacy-workload-reconciled"
  touch "$LEGACY_QUIESCE_FILE"
  reconcile_once 2>/dev/null
  [[ ! -e "$QUIESCE_FILE" ]]
  [[ -e "$LEGACY_QUIESCE_FILE" ]]
  [[ ! -e "$tmp/legacy-workload-reconciled" ]]
  chmod 0700 "$migration_failure"
)

# Active-path acknowledgement reports success only when persistence succeeds.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  hermes-state() { return 1; }
  if output="$(acknowledge_active_paths 2>&1)"; then
    echo "active-path acknowledgement masked helper failure" >&2
    exit 1
  fi
  [[ "$output" != *'active import paths acknowledged'* ]]
)

# An unset systemd credential directory does not resolve to /backup-passphrase.
if env -u BOX_PASSPHRASE_FILE -u CREDENTIALS_DIRECTORY \
  PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/tx9-no-credential.smolvm" \
  SMOLVM_STATE_DIR="$tmp/tx9-host-state" SMOLVM_BEHAVIOR=success \
  TX9_ROOT="$host_root" TX9_BOX_CALLS="$tmp/tx9-no-credential.box" \
  "$PROJECT_ROOT/ops/tx9-host" backup scheduled >/dev/null 2>&1; then
  echo "scheduled backup accepted a missing credential" >&2
  exit 1
fi
[[ ! -e "$tmp/tx9-no-credential.box" ]] || ! grep -q '^save ' "$tmp/tx9-no-credential.box"

# Credential files without a trailing newline are accepted intact.
printf 'no-newline-passphrase' >"$tmp/passphrase-no-newline"
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  _BOX_PASS=""
  BOX_PASSPHRASE_FILE="$tmp/passphrase-no-newline"
  _resolve_passphrase
  [[ "$_BOX_PASS" == no-newline-passphrase ]]
)

# Missing legacy resource settings use the documented production defaults.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  unset BOX_CPUS BOX_MEM_MIB BOX_OVERLAY_GIB BOX_STORAGE_GIB
  _validate_resources
  [[ "$BOX_CPUS" == 4 && "$BOX_MEM_MIB" == 8192 && "$BOX_OVERLAY_GIB" == 64 && -z "$BOX_STORAGE_GIB" ]]
)

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

# Gateway startup always requires the explicit single-writer confirmation.
gateway_data="$tmp/gateway-data"
HB_DATA="$gateway_data" "$PROJECT_ROOT/guest/hb" init
if HB_DATA="$gateway_data" "$PROJECT_ROOT/guest/hb" gateway-enable >/dev/null 2>&1; then
  echo "gateway enabled without single-writer confirmation" >&2
  exit 1
fi
HB_DATA="$gateway_data" "$PROJECT_ROOT/guest/hb" gateway-enable \
  --confirm-single-writer I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY >/dev/null
[[ ! -e "$gateway_data/home/agent/.config/hermes-box/gateway-disabled" ]]

# A failed gateway start restores the durable disabled policy marker.
(
  HB_DATA="$tmp/gateway-failure-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  init
  _start_gateway() { return 1; }
  if gateway_enable --confirm-single-writer I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY >/dev/null 2>&1; then
    echo "failed gateway start unexpectedly succeeded" >&2
    exit 1
  fi
  [[ -e "$GATEWAY_DISABLED" ]]
)

# Executor startup failure is never masked by a later gateway result.
(
  HB_DATA="$tmp/up-failure-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  init() { mkdir -p "$STATE_DIR"; }
  _executor_up() { return 42; }
  _start_gateway() { touch "$tmp/up-gateway-started"; }
  if up; then echo "hb up masked Executor failure" >&2; exit 1; fi
  [[ ! -e "$tmp/up-gateway-started" ]]
  if reconcile; then echo "hb reconcile masked Executor failure" >&2; exit 1; fi
  [[ ! -e "$tmp/up-gateway-started" ]]
)

# Hermes state validation is explicitly skipped when Hermes is disabled.
(
  HB_DATA="$tmp/hermes-disabled-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  _check() { :; }
  _hermes_state_valid() { touch "$tmp/hermes-state-called"; }
  output="$(INSTALL_HERMES=0 INSTALL_EXECUTOR=0 WIRE_EXECUTOR_MCP=0 doctor)"
  grep -q 'Hermes state check skipped' <<<"$output"
  [[ ! -e "$tmp/hermes-state-called" ]]
)

# Doctor validates Codex MCP wiring against the configured Executor port.
(
  HB_DATA="$tmp/doctor-port-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  CODEX_HOME="$AGENT_HOME/.codex"
  mkdir -p "$CODEX_HOME"
  printf 'url = "http://127.0.0.1:5999/mcp"\n' >"$CODEX_HOME/config.toml"
  _check() {
    local label="$1"
    shift
    if [[ "$label" == 'Codex HTTP MCP config' ]]; then
      touch "$tmp/codex-doctor-check-ran"
      "$@"
    else
      return 0
    fi
  }
  INSTALL_HERMES=0 INSTALL_EXECUTOR=0 WIRE_EXECUTOR_MCP=1 EXECUTOR_PORT=5999 doctor >/dev/null
  [[ -e "$tmp/codex-doctor-check-ran" ]]
)

# Quiesced doctor requires the Executor target to be closed, not just marked.
(
  HB_DATA="$tmp/quiesced-doctor-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  mkdir -p "$STATE_DIR"
  touch "$QUIESCE_FILE"
  _check() {
    local label="$1"
    shift
    if [[ "$label" == 'Executor target port closed while quiesced' ]]; then "$@"; else return 0; fi
  }
  _port_open() { return 1; }
  INSTALL_HERMES=0 INSTALL_EXECUTOR=1 WIRE_EXECUTOR_MCP=0 doctor >/dev/null
  _port_open() { return 0; }
  if INSTALL_HERMES=0 INSTALL_EXECUTOR=1 WIRE_EXECUTOR_MCP=0 doctor >/dev/null 2>&1; then
    echo "quiesced doctor accepted a listening Executor target" >&2
    exit 1
  fi
)

# Rolling upgrades migrate the legacy pause marker durably before removing it.
legacy_pause="$tmp/legacy-executor-paused"
legacy_data="$tmp/legacy-pause-data"
touch "$legacy_pause"
HB_DATA="$legacy_data" HB_LEGACY_QUIESCE_FILE="$legacy_pause" "$PROJECT_ROOT/guest/hb" init
[[ -e "$legacy_data/home/agent/.config/hermes-box/quiesced" ]]
[[ ! -e "$legacy_pause" ]]

# Explicit MCP wiring refuses to clear durable quiesce.
wire_quiesced="$tmp/wire-quiesced"
HB_DATA="$wire_quiesced" "$PROJECT_ROOT/guest/hb" init
mkdir -p "$wire_quiesced/home/agent/.config/hermes-box"
touch "$wire_quiesced/home/agent/.config/hermes-box/quiesced"
if HB_DATA="$wire_quiesced" "$PROJECT_ROOT/guest/hb" wire-mcp >/dev/null 2>&1; then
  echo "MCP wiring unexpectedly ran while quiesced" >&2
  exit 1
fi
[[ -e "$wire_quiesced/home/agent/.config/hermes-box/quiesced" ]]

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
    mock_quiesced=0
    mock_gateway_disabled=0
    have() { [[ "$1" == awk || "$1" == smolvm ]]; }
    _acquire_lock() { :; }
    _machine_exists() { :; }
    _guest_hb() {
      printf '%s\n' "$2" >>"$doctor_calls"
      if [[ "$2" == is-paused ]]; then [[ "$mock_quiesced" == 1 ]]; return; fi
      if [[ "$2" == gateway-is-disabled ]]; then [[ "$mock_gateway_disabled" == 1 ]]; return; fi
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
    [[ "$(cat "$doctor_calls")" == $'is-paused\ndoctor' ]]

    printf 'doctor-host\t4899\n' >"$REG"
    if (cmd_doctor doctor-host >/dev/null 2>&1); then
      echo "exposed-port doctor passed without host health dependencies" >&2
      exit 1
    fi
    [[ "$(cat "$doctor_calls")" == $'is-paused\ndoctor\nis-paused\ndoctor' ]]

    : >"$doctor_calls"
    have() { :; }
    cmd_doctor doctor-host >/dev/null
    [[ "$(cat "$doctor_calls")" == $'is-paused\ndoctor\nexecutor-token\nhost-mcp\nhost-mcp\nhost-mcp' ]]

    : >"$doctor_calls"
    mock_quiesced=1
    cmd_doctor doctor-host >/dev/null
    [[ "$(cat "$doctor_calls")" == $'is-paused\ndoctor' ]]
    mock_quiesced=0

    : >"$doctor_calls"
    printf 'api-host\t\t8650\t8650\n' >"$REG"
    _hermes_api_healthy() { printf 'host-api\n' >>"$doctor_calls"; }
    api_output="$(cmd_doctor api-host)"
    grep -q 'host Hermes API: healthy' <<<"$api_output"
    [[ "$(cat "$doctor_calls")" == $'is-paused\ngateway-is-disabled\ndoctor\nhost-api' ]]

    : >"$doctor_calls"
    mock_gateway_disabled=1
    _hermes_api_healthy() { touch "$tmp/disabled-api-probed"; return 1; }
    api_output="$(cmd_doctor api-host)"
    grep -q 'host Hermes API: intentionally disabled by gateway policy' <<<"$api_output"
    [[ "$(cat "$doctor_calls")" == $'is-paused\ngateway-is-disabled\ndoctor' ]]
    [[ ! -e "$tmp/disabled-api-probed" ]]
    mock_gateway_disabled=0

    : >"$doctor_calls"
    : >"$REG"
    WIRE_EXECUTOR_MCP=0 INSTALL_EXECUTOR=0 cmd_doctor disabled-executor >/dev/null
    [[ "$(cat "$doctor_calls")" == $'is-paused\ndoctor' ]]
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
  _hermes_api_healthy "$MCP_PORT"
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

  for unhealthy_status in 401 404 500; do
    start_mcp_server "$unhealthy_status" "api-$unhealthy_status"
    if _hermes_api_healthy "$MCP_PORT"; then
      echo "Hermes API HTTP $unhealthy_status passed health" >&2
      exit 1
    fi
    kill "$MCP_PID"
    wait "$MCP_PID" 2>/dev/null || true
  done
  start_mcp_server 200 api-malformed health-malformed
  if _hermes_api_healthy "$MCP_PORT"; then
    echo "malformed Hermes API health JSON passed" >&2
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

# Open refuses a quiesced box before hb up can clear its marker.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  calls="$tmp/open-quiesced.calls"
  _host_preflight() { :; }
  _acquire_lock() { :; }
  _reg_port() { printf '4899\n'; }
  _machine_running() { :; }
  smolvm() { printf 'smolvm %s\n' "$*" >>"$calls"; }
  _guest_hb() {
    printf 'hb %s\n' "$2" >>"$calls"
    [[ "$2" == is-paused ]]
  }
  if (cmd_open quiesced >/dev/null 2>&1); then
    echo "box open unexpectedly succeeded while quiesced" >&2
    exit 1
  fi
  grep -q 'hb is-paused' "$calls"
  if grep -q 'hb up' "$calls"; then
    echo "box open cleared quiesce through hb up" >&2
    exit 1
  fi
  if grep -q 'machine start' "$calls"; then
    echo "box open started the VM" >&2
    exit 1
  fi
)

# Open refuses a stopped box and never changes its lifecycle state.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  calls="$tmp/open-stopped.calls"
  _host_preflight() { :; }
  _acquire_lock() { :; }
  _reg_port() { printf '4899\n'; }
  _machine_running() { return 1; }
  smolvm() { printf 'smolvm %s\n' "$*" >>"$calls"; }
  _guest_hb() { printf 'hb %s\n' "$2" >>"$calls"; }
  if (cmd_open stopped >/dev/null 2>&1); then
    echo "box open accepted a stopped box" >&2
    exit 1
  fi
  [[ ! -e "$calls" ]] || ! grep -q 'machine start' "$calls"
)

# Repair refreshes assets but preserves a pre-existing durable quiesce policy.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  calls="$tmp/repair-quiesced.calls"
  _host_preflight() { :; }
  _acquire_lock() { :; }
  _machine_exists() { :; }
  smolvm() { printf 'smolvm %s\n' "$*" >>"$calls"; }
  _provision_into() { printf 'provision %s %s\n' "$1" "$2" >>"$calls"; }
  _guest_hb() {
    printf 'hb %s\n' "$2" >>"$calls"
    [[ "$2" == is-paused || "$2" == doctor ]]
  }
  cmd_repair quiesced >/dev/null
  grep -q 'provision quiesced full' "$calls"
  grep -q 'hb doctor' "$calls"
  if grep -Eq 'hb (up|resume)' "$calls"; then
    echo "repair resumed a previously quiesced box" >&2
    exit 1
  fi
)

# Repair validates a configured bundle before constructing the provision tar.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  calls="$tmp/repair-invalid-bundle.calls"
  HERMES_GIT_BUNDLE='../invalid.bundle'
  _host_preflight() { :; }
  _acquire_lock() { :; }
  _machine_exists() { :; }
  _guest_hb() { [[ "$2" == is-paused ]]; }
  smolvm() { printf '%s\n' "$*" >>"$calls"; }
  if (cmd_repair invalid-bundle >/dev/null 2>&1); then
    echo "repair accepted an invalid Hermes bundle path" >&2
    exit 1
  fi
  if grep -q 'machine exec -i' "$calls"; then
    echo "repair streamed provision context before bundle validation" >&2
    exit 1
  fi
)

# Guest bundle verification is independent of the caller's repository and
# rejects incremental bundles whose prerequisite objects are unavailable.
bundle_repo="$tmp/bundle-source"
mkdir -p "$bundle_repo" "$tmp/bundle-nonrepo" "$tmp/bundle-verify-tmp"
git -C "$bundle_repo" init -q
printf 'base\n' >"$bundle_repo/state.txt"
git -C "$bundle_repo" add state.txt
git -C "$bundle_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m base
base_commit="$(git -C "$bundle_repo" rev-parse HEAD)"
git -C "$bundle_repo" bundle create "$tmp/complete.bundle" --all
printf 'next\n' >>"$bundle_repo/state.txt"
git -C "$bundle_repo" add state.txt
git -C "$bundle_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m next
git -C "$bundle_repo" bundle create "$tmp/incremental.bundle" HEAD "^$base_commit"
(
  cd "$tmp/bundle-nonrepo"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/provision/provision.sh"
  TMPDIR="$tmp/bundle-verify-tmp" verify_self_contained_bundle "$tmp/complete.bundle"
  if TMPDIR="$tmp/bundle-verify-tmp" verify_self_contained_bundle "$tmp/incremental.bundle"; then
    echo "incremental bundle passed self-contained verification" >&2
    exit 1
  fi
)
[[ -z "$(find "$tmp/bundle-verify-tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]]

# Asset-only refreshes neither validate nor transport the optional source bundle.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  calls="$tmp/provision-mode.calls"
  HERMES_GIT_BUNDLE='artifacts/hermes.bundle'
  _validate_bundle() { printf 'validate\n' >>"$calls"; }
  tar() { printf 'tar %s\n' "$*" >>"$calls"; printf 'fixture'; }
  smolvm() { if [[ "$*" == *'machine exec -i'* ]]; then cat >/dev/null; fi; }
  _provision_into fixture assets >/dev/null
  [[ ! -e "$calls" ]] || ! grep -q '^validate$\|artifacts/hermes.bundle' "$calls"
  _provision_into fixture full >/dev/null
  grep -q '^validate$' "$calls"
  grep -q 'artifacts/hermes.bundle' "$calls"
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

# Legacy registry rows remain readable and reserve their Executor port.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  REG="$tmp/legacy-registry"
  printf 'legacy\t4900\n' >"$REG"
  _reg_exists legacy
  [[ "$(_reg_port legacy)" == 4900 ]]
  [[ -z "$(_reg_api_port legacy)" ]]
  if _port_free 4900; then
    echo "legacy registry port was reported free" >&2
    exit 1
  fi
)

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
grep -q -- '--cpus 4 --mem 8192 --overlay 64' "$tmp/create-signal.calls"
grep -q 'machine delete' "$tmp/create-signal.calls"
if grep -q 'machine start' "$tmp/create-signal.calls"; then
  echo "create-time signal was not honored before start" >&2
  exit 1
fi

# Optional Hermes API exposure constructs a distinct loopback forward and
# passes its guest bridge port to the persistent workload.
api_repo="$tmp/api-repo"
make_repo "$api_repo"
printf '\nEXPOSE_HERMES_API=1\nHERMES_API_PORT_LO=8650\nHERMES_API_PORT_HI=8650\n' >>"$api_repo/box.env"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/api.calls" \
  SMOLVM_STATE_DIR="$tmp/api-state" SMOLVM_BEHAVIOR=fail-exec \
  "$api_repo/box" new api-probe >/dev/null 2>&1; then
  echo "mock API provisioning failure unexpectedly succeeded" >&2
  exit 1
fi
grep -q -- '-p 8650:8650' "$tmp/api.calls"
grep -q 'hb-workload.*8650' "$tmp/api.calls"

# Native import fails closed. External provider state requires explicit consent
# before any VM command, and failures/signals after disable never restart it.
python3 - "$tmp/hermes-import.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("config.yaml", "model: fixture\n")
    archive.writestr(".env", "DISCORD_BOT_TOKEN=fixture\n")
    archive.writestr("_external/.honcho/config.json", "{}\n")
PY
import_repo="$tmp/import-repo"
make_repo "$import_repo"
mkdir -p "$tmp/import-state/import-probe"
printf 'import-probe\t\n' >"$import_repo/.boxes"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/import-no-consent.calls" \
  SMOLVM_STATE_DIR="$tmp/import-state" SMOLVM_BEHAVIOR=success \
  "$import_repo/box" import-hermes import-probe "$tmp/hermes-import.zip" >/dev/null 2>&1; then
  echo "external import without consent unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -e "$tmp/import-no-consent.calls" ]]

if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/import-fail.calls" \
  SMOLVM_STATE_DIR="$tmp/import-state" SMOLVM_BEHAVIOR=import-post-fail \
  "$import_repo/box" import-hermes import-probe "$tmp/hermes-import.zip" \
    --external .honcho >/dev/null 2>&1; then
  echo "post-import verification failure unexpectedly succeeded" >&2
  exit 1
fi
[[ -e "$tmp/import-state/import-probe/gateway-disabled" ]]
[[ ! -e "$tmp/import-state/import-probe/gateway-restarted" ]]
grep -q 'hb gateway-disable' "$tmp/import-fail.calls"
grep -q 'hb resume' "$tmp/import-fail.calls"
grep -q '/data/home/agent/.config/hermes-box/import-' "$tmp/import-fail.calls"
if grep -q '/root/hermes-import-' "$tmp/import-fail.calls"; then
  echo "Hermes import still stages beneath root-only storage" >&2
  exit 1
fi
import_dir_line="$(grep -n 'install -d -o agent -g agent -m 0700 /data/home/agent/.config/hermes-box' "$tmp/import-fail.calls" | head -1 | cut -d: -f1)"
import_cp_line="$(grep -n 'machine cp.*\.config/hermes-box/import-' "$tmp/import-fail.calls" | head -1 | cut -d: -f1)"
import_chown_line="$(grep -n 'chown agent:agent /data/home/agent/.config/hermes-box/import-' "$tmp/import-fail.calls" | head -1 | cut -d: -f1)"
import_chmod_line="$(grep -n 'chmod 0600 /data/home/agent/.config/hermes-box/import-' "$tmp/import-fail.calls" | head -1 | cut -d: -f1)"
import_setpriv_line="$(grep -n 'setpriv.*hermes-state.*import-zip.*/data/home/agent/.config/hermes-box/import-' "$tmp/import-fail.calls" | head -1 | cut -d: -f1)"
[[ -n "$import_dir_line" && -n "$import_cp_line" && -n "$import_chown_line" && -n "$import_chmod_line" && -n "$import_setpriv_line" ]]
[[ "$import_dir_line" -lt "$import_cp_line" && "$import_cp_line" -lt "$import_chown_line" && "$import_chown_line" -lt "$import_chmod_line" && "$import_chmod_line" -lt "$import_setpriv_line" ]]
import_remove_line="$(grep -n 'rm -f -- /data/home/agent/.config/hermes-box/import-' "$tmp/import-fail.calls" | head -1 | cut -d: -f1)"
import_resume_line="$(grep -n 'hb resume' "$tmp/import-fail.calls" | head -1 | cut -d: -f1)"
[[ -n "$import_remove_line" && -n "$import_resume_line" && "$import_remove_line" -lt "$import_resume_line" ]]

rm -f "$tmp/import-state/import-probe/paused"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/import-signal.calls" \
  SMOLVM_STATE_DIR="$tmp/import-state" SMOLVM_BEHAVIOR=signal-import \
  "$import_repo/box" import-hermes import-probe "$tmp/hermes-import.zip" \
    --external .honcho >/dev/null 2>&1; then
  echo "signal-interrupted import unexpectedly succeeded" >&2
  exit 1
fi
[[ -e "$tmp/import-state/import-probe/gateway-disabled" ]]
[[ ! -e "$tmp/import-state/import-probe/gateway-restarted" ]]
grep -q 'hb resume' "$tmp/import-signal.calls"
signal_remove_line="$(grep -n 'rm -f -- /data/home/agent/.config/hermes-box/import-' "$tmp/import-signal.calls" | head -1 | cut -d: -f1)"
signal_resume_line="$(grep -n 'hb resume' "$tmp/import-signal.calls" | head -1 | cut -d: -f1)"
[[ -n "$signal_remove_line" && -n "$signal_resume_line" && "$signal_remove_line" -lt "$signal_resume_line" ]]

# Import temporarily starts a stopped target, preserves its unpaused policy,
# keeps the gateway disabled, and returns it to stopped on success or failure.
for stopped_case in success failure; do
  stopped_name="stopped-import-$stopped_case"
  mkdir -p "$tmp/import-state/$stopped_name"
  printf '%s\t\n' "$stopped_name" >>"$import_repo/.boxes"
  behavior=inactive
  [[ "$stopped_case" == success ]] || behavior=inactive-import-post-fail
  if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$tmp/${stopped_name}.calls" \
    SMOLVM_STATE_DIR="$tmp/import-state" SMOLVM_BEHAVIOR="$behavior" \
    "$import_repo/box" import-hermes "$stopped_name" "$tmp/hermes-import.zip" \
      --external .honcho >/dev/null 2>&1; then
    [[ "$stopped_case" == success ]] || {
      echo "stopped import failure case unexpectedly succeeded" >&2; exit 1;
    }
  else
    [[ "$stopped_case" == failure ]] || {
      echo "stopped import success case failed" >&2; exit 1;
    }
  fi
  grep -q 'machine start' "$tmp/${stopped_name}.calls"
  grep -q 'machine stop' "$tmp/${stopped_name}.calls"
  grep -q 'hb gateway-disable' "$tmp/${stopped_name}.calls"
  [[ -e "$tmp/import-state/$stopped_name/gateway-disabled" ]]
  [[ ! -e "$tmp/import-state/$stopped_name/paused" ]]
  [[ ! -e "$tmp/import-state/$stopped_name/gateway-restarted" ]]
done

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
