#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2329
set -euo pipefail

# Sourced helpers modify shell-local variables, and fixture overrides are
# invoked indirectly by lifecycle functions.

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# A failed readiness prerequisite must preserve the existing credentials and
# MCP configuration instead of replacing them and claiming wiring succeeded.
(
  HB_DATA="$tmp/wiring-readiness"
  # shellcheck source=guest/hb
  source "$PROJECT_ROOT/guest/hb"
  _seed_browser_config() { :; }
  init
  printf 'existing token environment\n' >"$TOKEN_ENV"
  printf 'existing wiring marker\n' >"$WIRED"
  up() { return 1; }
  executor_token() { printf 'fixture-token\n'; }
  _unwire_legacy() { touch "$tmp/old-config-removed"; }
  _gateway_running() { return 1; }
  if EXECUTOR_HOST=executor WIRE_EXECUTOR_MCP=1 wire_mcp >/dev/null 2>&1; then
    echo 'MCP wiring succeeded after readiness failed' >&2
    exit 1
  fi
  [[ ! -e "$tmp/old-config-removed" ]]
  [[ "$(cat "$TOKEN_ENV")" == 'existing token environment' ]]
  [[ "$(cat "$WIRED")" == 'existing wiring marker' ]]
)

# Credential persistence is a prerequisite, and shell metacharacters in a
# runtime token must survive sourcing literally without executing any code.
(
  HB_DATA="$tmp/wiring-credentials"
  # shellcheck source=guest/hb
  source "$PROJECT_ROOT/guest/hb"
  _seed_browser_config() { :; }
  init
  token="literal'\$(touch $tmp/token-executed) token"
  _write_token_env "$token"
  unset EXECUTOR_MCP_TOKEN
  # shellcheck disable=SC1090
  source "$TOKEN_ENV"
  [[ "$EXECUTOR_MCP_TOKEN" == "$token" && ! -e "$tmp/token-executed" ]]
  [[ "$(stat -c '%a' "$TOKEN_ENV")" == 600 ]]
  (
    CODEX_HOME="$AGENT_HOME/.codex"
    printf '%s\n' "$WIRE_VERSION" >"$WIRED"
    printf 'url = "http://executor:4788/mcp"\n' >"$CODEX_HOME/config.toml"
    fixture_token="$token"
    executor_token() { printf '%s\n' "$fixture_token"; }
    _hermes_http_config() { return 0; }
    wire_mcp() { echo 'unchanged quoted credentials triggered unnecessary MCP rewiring' >&2; return 1; }
    EXECUTOR_HOST=executor WIRE_EXECUTOR_MCP=1 wire_once
  )
  up() { return 0; }
  executor_token() { printf 'fixture-token\n'; }
  _unwire_legacy() { touch "$tmp/credentials-config-removed"; }
  TOKEN_ENV="$tmp/missing-directory/blocked/credentials.env"
  mkdir -p "$tmp/missing-directory"
  printf 'not a directory\n' >"$tmp/missing-directory/blocked"
  if EXECUTOR_HOST=executor WIRE_EXECUTOR_MCP=1 wire_mcp >/dev/null 2>&1; then
    echo 'MCP wiring succeeded without persisting credentials' >&2
    exit 1
  fi
  [[ ! -e "$tmp/credentials-config-removed" ]]
)

# A reload that cannot stop its previous worker must not launch a duplicate or
# overwrite that worker's identity record. Inject only the stop failure; the
# normal reconciliation policy decides whether a replacement may launch.
(
  TX9_SERVICES_CONFIG_ROOT="$tmp/services-config"
  TX9_SERVICES_STATE_DIR="$tmp/services-state"
  TX9_SERVICES_LOG_DIR="$tmp/services-logs"
  # shellcheck source=guest/tx9-services
  source "$PROJECT_ROOT/guest/tx9-services"
  _ensure_dirs
  printf '#!/bin/sh\nexit 0\n' >"$DEFINITIONS/worker"
  chmod 0700 "$DEFINITIONS/worker"
  printf 'owned previous worker\n' >"$STATE_DIR/worker.state"
  _log_helper() { printf '%s\n' "$PROJECT_ROOT/guest/tx9-logs"; }
  _state_process_matches() {
    STATE_FINGERPRINT=previous-definition
    STATE_HELPER="$PROJECT_ROOT/guest/tx9-logs"
    STATE_LOG_DIR="$LOG_DIR"
    STATE_DELAY="$RESTART_DELAY"
    return 0
  }
  _stop_one() { return 1; }
  _start_one() { touch "$tmp/duplicate-worker-launched"; }
  if reconcile >/dev/null 2>&1; then
    echo 'service reload ignored an unsuccessful stop' >&2
    exit 1
  fi
  [[ ! -e "$tmp/duplicate-worker-launched" ]]
  [[ "$(cat "$STATE_DIR/worker.state")" == 'owned previous worker' ]]
)

# A starter queued behind the real flock must recheck durable policy after
# acquiring it. Pause and gateway-disable can both be requested while queued.
for policy in quiesced gateway-disabled; do
  (
    HB_DATA="$tmp/queued-$policy"
    # shellcheck source=guest/hb
    source "$PROJECT_ROOT/guest/hb"
    _seed_browser_config() { :; }
    init
    rm -f "$GATEWAY_DISABLED" "$QUIESCE_FILE"
    INSTALL_HERMES=1
    hermes() { :; }
    _gateway_pids() { printf '4242\n'; }
    _acquire_daemon_lock "$GATEWAY_LOCK"
    inherited_fd="${_DAEMON_LOCK_FDS[$GATEWAY_LOCK]}"
    eval "$(declare -f _acquire_daemon_lock | sed '1s/_acquire_daemon_lock/_test_acquire_daemon_lock/')"
    _acquire_daemon_lock() {
      printf 'waiting\n' >"$tmp/$policy.waiting"
      _test_acquire_daemon_lock "$@"
    }
    (
      eval "exec ${inherited_fd}>&-"
      unset '_DAEMON_LOCK_FDS[$GATEWAY_LOCK]'
      _start_gateway
    ) &
    starter=$!
    wait_for_file "$tmp/$policy.waiting"
    touch "$STATE_DIR/$policy"
    _release_daemon_lock "$GATEWAY_LOCK"
    wait "$starter"
    [[ ! -e "$GATEWAY_PID" ]] || {
      echo "queued gateway startup ignored $policy policy" >&2
      exit 1
    }
  )
done

# Stop operations wait for an in-flight starter before inspecting/killing its
# process. Otherwise they can report success before that starter execs.
for daemon in gateway executor; do
  (
    HB_DATA="$tmp/inflight-$daemon"
    # shellcheck source=guest/hb
    source "$PROJECT_ROOT/guest/hb"
    _seed_browser_config() { :; }
    init
    pkill() { touch "$tmp/$daemon.stopped"; }
    _signal_gateway() { touch "$tmp/$daemon.stopped"; }
    _gateway_or_capture_running() { return 1; }
    executor() { :; }
    _wait_port() { return 0; }
    EXECUTOR_HOST=127.0.0.1
    if [[ "$daemon" == gateway ]]; then lock="$GATEWAY_LOCK"; else lock="$EXECUTOR_LOCK"; fi
    _acquire_daemon_lock "$lock"
    inherited_fd="${_DAEMON_LOCK_FDS[$lock]}"
    eval "$(declare -f _acquire_daemon_lock | sed '1s/_acquire_daemon_lock/_test_acquire_daemon_lock/')"
    _acquire_daemon_lock() {
      printf 'waiting\n' >"$tmp/$daemon.stop-waiting"
      _test_acquire_daemon_lock "$@"
    }
    (
      eval "exec ${inherited_fd}>&-"
      unset '_DAEMON_LOCK_FDS[$lock]'
      "_stop_$daemon"
    ) &
    stopper=$!
    wait_for_file "$tmp/$daemon.stop-waiting"
    [[ ! -e "$tmp/$daemon.stopped" ]]
    _release_daemon_lock "$lock"
    wait "$stopper"
    [[ -e "$tmp/$daemon.stopped" ]]
  )
done

# du may emit a partial total before failing on inaccessible restored /data.
# Status must expose the failed measurement rather than present that partial
# output as the box's usage, while retaining successful measurements.
(
  HB_DATA="$tmp/status-usage"
  # shellcheck source=guest/hb
  source "$PROJECT_ROOT/guest/hb"
  HERMES_HOME="$AGENT_HOME/.hermes"
  _seed_browser_config() { :; }
  _port_open() { return 1; }
  init
  du() { printf '4.0K\t%s\n' "$DATA"; return 1; }
  output="$(status)"
  [[ "$output" == *'data:     unavailable'* && "$output" != *'4.0K'* ]] || {
    echo 'status presented a failed partial usage measurement as complete' >&2
    exit 1
  }
  du() { printf '53M\t%s\n' "$DATA"; }
  [[ "$(status)" == *'data:     53M'* ]]
)

echo 'guest lifecycle audit regression checks passed'
