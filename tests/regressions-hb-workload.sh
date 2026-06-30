#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2329
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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

echo "hb-workload regression checks passed"
