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

# A pending gateway reload is handed to the persistent workload before normal
# reconciliation, keeping login shells out of their parent gateway's lifecycle.
(
  HOME="$tmp/workload-reload-home"
  mkdir -p "$HOME/.config/hermes-box" "$tmp/workload-reload-logs"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb-workload"
  PORT=4788
  HERMES_BRIDGE_PORT=0
  LOGS="$tmp/workload-reload-logs"
  BOX_ENV="$tmp/workload-reload-box.env"
  LEGACY_QUIESCE_FILE="$tmp/workload-reload-legacy-paused"
  printf 'EXECUTOR_PORT=4788\nHERMES_API_PORT=8642\n' >"$BOX_ENV"
  mkdir -p "$GATEWAY_RELOAD_REQUESTS"
  touch "$GATEWAY_RELOAD_REQUESTS/request.test"
  hb() {
    printf '%s\n' "$*" >>"$tmp/workload-reload.events"
    [[ "$*" != gateway-reload-if-requested ]] || rm -f "$GATEWAY_RELOAD_REQUESTS"/request.*
  }
  reconcile_once
  [[ "$(cat "$tmp/workload-reload.events")" == $'gateway-reload-if-requested\nreconcile' ]]
)

# The bridge-presence checks must match on "socat TCP-LISTEN:<port>,", not a
# bare "TCP-LISTEN:<port>," substring — otherwise an unrelated process whose
# argv happens to contain that text is mistaken for the real socat bridge,
# and reconcile_once silently and permanently skips (re-)starting host access
# on that port. This intentionally runs pgrep for real (no stub) against a
# decoy process to prove the pattern discriminates on the "socat " prefix,
# the same way _stop_bridge already does.
(
  HOME="$tmp/workload-decoy-home"
  mkdir -p "$HOME/.config/hermes-box" "$tmp/workload-decoy-logs"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb-workload"
  PORT=4799
  HERMES_BRIDGE_PORT=0
  LOGS="$tmp/workload-decoy-logs"
  BOX_ENV="$tmp/workload-decoy-box.env"
  LEGACY_QUIESCE_FILE="$tmp/workload-decoy-legacy-paused"
  printf 'EXECUTOR_PORT=4788\nHERMES_API_PORT=8642\n' >"$BOX_ENV"
  _exec_up() { return 0; }
  hb() { return 0; }
  socat() { printf 'started %s\n' "$*" >>"$tmp/decoy-bridge.events"; }
  ( exec -a "TCP-LISTEN:4799,decoy" sleep 5 ) &
  decoy_pid=$!
  trap 'kill "$decoy_pid" 2>/dev/null || true' EXIT
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "TCP-LISTEN:4799," >/dev/null 2>&1 && break
    sleep 0.1
  done
  reconcile_once
  kill "$decoy_pid" 2>/dev/null || true
  wait
  if ! grep -q 'started.*TCP-LISTEN:4799,' "$tmp/decoy-bridge.events" 2>/dev/null; then
    echo "a decoy process matching a bare TCP-LISTEN pattern blocked the real socat bridge from starting" >&2
    exit 1
  fi
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

# Cutover gates fire only on the FIRST enable after an import: a successful
# enable records gateway_enabled=true in the manifest, so a later restart
# (disable → enable) must not re-run gates that can no longer pass once live
# traffic has diverged the database from the import baselines. A fresh import
# (gateway_enabled=false again) must re-gate.
(
  HB_DATA="$tmp/gateway-regate-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  init
  _start_gateway() { return 0; }
  _stop_gateway() { return 0; }
  gates_run=0
  cutover_ready() { gates_run=$((gates_run + 1)); return 0; }
  printf '{"status":"completed","gateway_enabled":false}\n' >"$STATE_DIR/import-manifest.json"
  gateway_enable --confirm-single-writer I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY >/dev/null
  [[ "$gates_run" == 1 ]] || { echo "first enable did not run cutover gates" >&2; exit 1; }
  [[ "$(jq -r .gateway_enabled "$STATE_DIR/import-manifest.json")" == true ]] ||
    { echo "successful enable did not persist gateway_enabled" >&2; exit 1; }
  gateway_disable >/dev/null
  gateway_enable --confirm-single-writer I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY >/dev/null
  [[ "$gates_run" == 1 ]] || { echo "restart re-ran cutover gates after a successful enable" >&2; exit 1; }
  printf '{"status":"completed","gateway_enabled":false}\n' >"$STATE_DIR/import-manifest.json"
  gateway_disable >/dev/null
  gateway_enable --confirm-single-writer I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY >/dev/null
  [[ "$gates_run" == 2 ]] || { echo "fresh import did not re-run cutover gates" >&2; exit 1; }
)

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

# Stopping an already-stopped gateway is success, not failure: pause (and so
# every box save) must not fail just because the gateway was never running.
(
  HB_DATA="$tmp/stop-gateway-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  _gateway_running() { return 1; }
  pkill() { :; }
  sleep() { :; }
  _stop_gateway || { echo "stop_gateway failed with no gateway running" >&2; exit 1; }
  _gateway_running() { return 0; }
  if _stop_gateway 2>/dev/null; then
    echo "stop_gateway claimed success while the gateway survived" >&2
    exit 1
  fi
)

# gateway_disable must fail loudly when it cannot persist the durable marker,
# and succeed when an existing (possibly unwritable) marker is already there —
# provisioning creates it as root, and touch on a root-owned file fails for
# the agent user even though the disabled state itself is correct.
(
  HB_DATA="$tmp/gateway-disable-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  init
  _stop_gateway() { return 0; }
  touch() { return 1; }  # simulate a marker touch denied by ownership
  gateway_disable >/dev/null || { echo "gateway_disable failed though the marker exists" >&2; exit 1; }
  command rm -f "$GATEWAY_DISABLED"
  if gateway_disable >/dev/null 2>&1; then
    echo "gateway_disable claimed success without a persisted disabled marker" >&2
    exit 1
  fi
)

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
# When removal changes a live Hermes gateway, it queues the persistent workload
# to reload it instead of killing the gateway from its own login shell.
(
  HB_DATA="$tmp/disabled-wire-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  HERMES_HOME="$AGENT_HOME/.hermes"
  mkdir -p "$HERMES_HOME"
  cat >"$HERMES_HOME/config.yaml" <<'EOF'
mcp_servers:
    executor:
        enabled: true
EOF
  _unwire_legacy() {
    printf 'unwire\n' >>"$tmp/disabled-wire.events"
    printf 'mcp_servers: {}\n' >"$HERMES_HOME/config.yaml"
  }
  hermes() { :; }
  _gateway_running() { return 0; }
  _stop_gateway() { echo "disabled wiring stopped its parent gateway" >&2; return 1; }
  _start_gateway() { echo "disabled wiring restarted its parent gateway" >&2; return 1; }
  mkdir -p "$(dirname "$TOKEN_ENV")"
  printf 'stale\n' >"$WIRED"
  printf 'stale\n' >"$TOKEN_ENV"
  export EXECUTOR_MCP_TOKEN=stale
  WIRE_EXECUTOR_MCP=0 wire_once >/dev/null
  [[ ! -e "$WIRED" && ! -e "$TOKEN_ENV" ]]
  [[ -n "$(find "$GATEWAY_RELOAD_REQUESTS" -type f -name 'request.*' -print -quit)" ]]
  [[ "$(cat "$tmp/disabled-wire.events")" == unwire ]]
)

# Disable cleanup must persist reload intent before changing live Hermes state.
# A transient request-write failure leaves config and credentials intact so the
# next login can retry instead of permanently losing the reload requirement.
(
  HB_DATA="$tmp/disabled-request-failure-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  HERMES_HOME="$AGENT_HOME/.hermes"
  mkdir -p "$HERMES_HOME" "$(dirname "$TOKEN_ENV")"
  cat >"$HERMES_HOME/config.yaml" <<'EOF'
mcp_servers:
  executor:
    enabled: true
EOF
  printf 'stale\n' >"$WIRED"
  printf 'stale\n' >"$TOKEN_ENV"
  hermes() { :; }
  _gateway_running() { return 0; }
  _request_gateway_reload() { return 1; }
  _unwire_legacy() { touch "$tmp/disabled-request-failure-unwired"; }
  if WIRE_EXECUTOR_MCP=0 wire_mcp >/dev/null 2>&1; then
    echo "disabled wiring ignored a failed gateway reload request" >&2
    exit 1
  fi
  [[ ! -e "$tmp/disabled-request-failure-unwired" ]]
  [[ -e "$WIRED" && -e "$TOKEN_ENV" ]]
  _hermes_executor_config >/dev/null
)

# A failed Hermes removal keeps credentials and the durable reload request so
# a retry cannot publish a disabled state while config still enables Executor.
(
  HB_DATA="$tmp/disabled-removal-failure-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  HERMES_HOME="$AGENT_HOME/.hermes"
  mkdir -p "$HERMES_HOME" "$(dirname "$TOKEN_ENV")"
  cat >"$HERMES_HOME/config.yaml" <<'EOF'
mcp_servers:
  executor:
    enabled: true
EOF
  printf 'stale\n' >"$WIRED"
  printf 'stale\n' >"$TOKEN_ENV"
  hermes() { return 1; }
  _gateway_running() { return 0; }
  if WIRE_EXECUTOR_MCP=0 wire_mcp >/dev/null 2>&1; then
    echo "disabled wiring ignored failed Hermes config removal" >&2
    exit 1
  fi
  [[ -e "$WIRED" && -e "$TOKEN_ENV" ]]
  _hermes_executor_config >/dev/null
  [[ -n "$(find "$GATEWAY_RELOAD_REQUESTS" -type f -name 'request.*' -print -quit)" ]]
)

# The workload-facing reload command stops and starts a live gateway once,
# then consumes its durable request marker. Gateway startup sanitizes the
# Executor token when wiring is disabled.
(
  HB_DATA="$tmp/gateway-reload-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  init
  rm -f "$GATEWAY_DISABLED"
  mkdir -p "$GATEWAY_RELOAD_REQUESTS"
  touch "$GATEWAY_RELOAD_REQUESTS/request.initial"
  export EXECUTOR_MCP_TOKEN=stale
  _gateway_running() { return 0; }
  _stop_gateway() { printf 'gateway-stop\n' >>"$tmp/gateway-reload.events"; }
  _start_gateway() {
    _load_executor_mcp_env
    [[ -z "${EXECUTOR_MCP_TOKEN:-}" ]]
    printf 'gateway-start\n' >>"$tmp/gateway-reload.events"
    touch "$GATEWAY_RELOAD_REQUESTS/request.concurrent"
  }
  WIRE_EXECUTOR_MCP=0 gateway_reload_if_requested
  [[ ! -e "$GATEWAY_RELOAD_REQUESTS/request.initial" ]]
  [[ -e "$GATEWAY_RELOAD_REQUESTS/request.concurrent" ]]
  [[ "$(cat "$tmp/gateway-reload.events")" == $'gateway-stop\ngateway-start' ]]
)

# Hermes removal prompts for confirmation. Legacy cleanup must provide its
# answer rather than invisibly reading from the login terminal before tmux.
(
  HB_DATA="$tmp/unwire-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  mkdir -p "$AGENT_HOME/workspace"
  claude() { :; }
  codex() { :; }
  hermes() {
    [[ "$*" == 'mcp remove executor' ]]
    read -r answer
    [[ "$answer" == y ]]
    touch "$tmp/hermes-remove-confirmed"
  }
  _unwire_legacy
  [[ -e "$tmp/hermes-remove-confirmed" ]]
)

# Enabled MCP wiring registers the authenticated Executor endpoint for Hermes
# as well as Claude and Codex. The secret stays in the managed token env; the
# Hermes config receives only an environment placeholder.
(
  HB_DATA="$tmp/enabled-wire-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  CODEX_HOME="$AGENT_HOME/.codex"
  HERMES_HOME="$AGENT_HOME/.hermes"
  mkdir -p "$CODEX_HOME" "$HERMES_HOME"
  up() { :; }
  executor_token() { printf 'test-token\n'; }
  _unwire_legacy() { :; }
  _record_tool() {
    local tool="$1"
    shift
    { printf '%s' "$tool"; printf ' <%s>' "$@"; printf '\n'; } >>"$tmp/enabled-wire.events"
  }
  claude() { _record_tool claude "$@"; }
  codex() { _record_tool codex "$@"; }
  hermes() { _record_tool hermes "$@"; }
  _gateway_running() { return 0; }
  _stop_gateway() { echo "enabled wiring stopped its parent gateway" >&2; return 1; }
  _start_gateway() { echo "enabled wiring restarted its parent gateway" >&2; return 1; }
  EXECUTOR_HOST=executor WIRE_EXECUTOR_MCP=1 wire_mcp >/dev/null
  grep -Fq 'hermes <config> <set> <mcp_servers.executor.url> <http://executor:4788/mcp>' "$tmp/enabled-wire.events"
  grep -Fq 'hermes <config> <set> <mcp_servers.executor.headers.Authorization> <Bearer ${EXECUTOR_MCP_TOKEN}>' "$tmp/enabled-wire.events"
  grep -Fq 'hermes <config> <set> <mcp_servers.executor.enabled> <true>' "$tmp/enabled-wire.events"
  [[ -n "$(find "$GATEWAY_RELOAD_REQUESTS" -type f -name 'request.*' -print -quit)" ]]
  [[ "$(cat "$WIRED")" == http-v3 ]]
)

# Failed client configuration must leave an already-running gateway alone and
# must not publish the wiring marker.
(
  HB_DATA="$tmp/failed-wire-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  up() { :; }
  executor_token() { printf 'test-token\n'; }
  _unwire_legacy() { :; }
  claude() { :; }
  codex() { :; }
  hermes() { return 1; }
  _gateway_running() { return 0; }
  _stop_gateway() { touch "$tmp/failed-wire-gateway-stopped"; }
  _start_gateway() { touch "$tmp/failed-wire-gateway-started"; }
  if EXECUTOR_HOST=executor WIRE_EXECUTOR_MCP=1 wire_mcp >/dev/null 2>&1; then
    echo "failed Hermes registration unexpectedly succeeded" >&2
    exit 1
  fi
  [[ ! -e "$tmp/failed-wire-gateway-stopped" ]]
  [[ ! -e "$tmp/failed-wire-gateway-started" ]]
  [[ ! -d "$GATEWAY_RELOAD_REQUESTS" ]]
  [[ ! -e "$WIRED" ]]
)

# Freshness and doctor validation require the Executor entry itself to be
# enabled; an unrelated enabled server must not hide a disabled Executor.
(
  HB_DATA="$tmp/hermes-config-data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  HERMES_HOME="$AGENT_HOME/.hermes"
  mkdir -p "$HERMES_HOME"
  hermes() { :; }
  cat >"$HERMES_HOME/config.yaml" <<'EOF'
mcp_servers:
  other:
    enabled: true
  executor:
    url: http://executor:4788/mcp
    headers:
      Authorization: Bearer ${EXECUTOR_MCP_TOKEN}
    sampling:
      enabled: true
    enabled: false
EOF
  if EXECUTOR_HOST=executor _hermes_http_config; then
    echo "Hermes config accepted a disabled Executor MCP server" >&2
    exit 1
  fi
  sed -i 's/enabled: false/enabled: true/' "$HERMES_HOME/config.yaml"
  EXECUTOR_HOST=executor _hermes_http_config
)

# The daemon lock (_acquire_daemon_lock/_release_daemon_lock, shared by
# _start_gateway and _executor_up) must serialize concurrent contenders, and
# a process spawned via _spawn_without_lock_fd must not inherit the lock's
# fd — otherwise a long-lived daemon would hold the underlying flock open
# for its entire lifetime, wedging every later acquire attempt.
lock_test_data="$tmp/daemon-lock-data"
HB_DATA="$lock_test_data" "$PROJECT_ROOT/guest/hb" init >/dev/null
lock_state_dir="$lock_test_data/home/agent/.config/hermes-box"
lock_path="$lock_state_dir/test.lock"
outer_lock_path="$lock_state_dir/outer.lock"
marker="$lock_state_dir/marker"
for _ in 1 2 3 4 5 6 7 8; do
  (
    HB_DATA="$lock_test_data"
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/guest/hb"
    _acquire_daemon_lock "$lock_path" || exit 1
    if [[ ! -e "$marker" ]]; then
      sleep 0.1
      touch "$marker"
    fi
    _release_daemon_lock "$lock_path"
  ) &
done
wait
[[ -e "$marker" ]]

(
  HB_DATA="$lock_test_data"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  rm -f "$lock_path"
  rm -f "$outer_lock_path"
  _acquire_daemon_lock "$outer_lock_path" || exit 1
  _acquire_daemon_lock "$lock_path" || exit 1
  _spawn_without_lock_fd "$lock_path" "$tmp/spawned-daemon.log" sleep 30
  spawned_pid=$!
  _release_daemon_lock "$lock_path"
  _release_daemon_lock "$outer_lock_path"
  echo "$spawned_pid" >"$tmp/spawned.pid"
)
[[ -s "$tmp/spawned.pid" ]]
spawned_pid="$(cat "$tmp/spawned.pid")"
kill -0 "$spawned_pid" 2>/dev/null || { echo "spawned daemon did not survive its spawning subshell" >&2; exit 1; }
if ! flock -w 2 "$lock_path" -c 'exit 0' 2>/dev/null; then
  echo "daemon lock was not released — the spawned process likely inherited its fd" >&2
  kill -9 "$spawned_pid" 2>/dev/null
  exit 1
fi
if ! flock -w 2 "$outer_lock_path" -c 'exit 0' 2>/dev/null; then
  echo "outer daemon lock was not released — the spawned process inherited an unrelated coordination fd" >&2
  kill -9 "$spawned_pid" 2>/dev/null
  exit 1
fi
kill -9 "$spawned_pid" 2>/dev/null || true

echo "hb-workload regression checks passed"
