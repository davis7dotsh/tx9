#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2329
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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

echo "doctor-mcp regression checks passed"
