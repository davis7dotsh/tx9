#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2329
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

data="$tmp/data"
home="$data/home/agent"
config_root="$home/.config/hermes-box"
definitions="$config_root/services.d"
runtime="$tmp/runtime"
logs="$data/logs"
events="$tmp/events"
mkdir -p "$definitions" "$runtime" "$logs" "$events"

export TX9_SERVICES_CONFIG_ROOT="$config_root"
export TX9_SERVICES_STATE_DIR="$runtime"
export TX9_SERVICES_LOG_DIR="$logs"
export TX9_SERVICES_LOG_HELPER="$PROJECT_ROOT/guest/tx9-logs"
export TX9_SERVICES_RESTART_DELAY=0.2
export TX9_SERVICES_STOP_TIMEOUT=2
export SERVICE_TEST_EVENTS="$events"
services="$PROJECT_ROOT/guest/tx9-services"

wait_for_count() {
  local expected="$1" file="$2" attempt count
  for ((attempt = 0; attempt < 150; attempt++)); do
    if [[ -f "$file" ]]; then count="$(wc -l <"$file")"; else count=0; fi
    [[ "$count" -ge "$expected" ]] && return 0
    sleep 0.02
  done
  echo "timed out waiting for $expected records in $file" >&2
  return 1
}

wait_for_absent() {
  local path="$1" attempt
  for ((attempt = 0; attempt < 150; attempt++)); do
    [[ ! -e "$path" ]] && return 0
    sleep 0.02
  done
  echo "timed out waiting for $path to disappear" >&2
  return 1
}

wait_for_process_exit() {
  local pid="$1" attempt state
  for ((attempt = 0; attempt < 150; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    [[ "$state" == Z* ]] && return 0
    sleep 0.02
  done
  echo "timed out waiting for process $pid to exit" >&2
  return 1
}

cat >"$definitions/healthy" <<'EOF'
#!/usr/bin/env bash
printf 'start %s\n' "$$" >>"$SERVICE_TEST_EVENTS/healthy.starts"
printf 'healthy-log\n'
trap 'printf "term %s\n" "$$" >>"$SERVICE_TEST_EVENTS/healthy.terms"; exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod 0700 "$definitions/healthy"

cat >"$definitions/broken" <<'EOF'
#!/usr/bin/env bash
printf 'start %s\n' "$$" >>"$SERVICE_TEST_EVENTS/broken.starts"
printf 'broken-log\n'
exit 17
EOF
chmod 0700 "$definitions/broken"

# Invalid direct children are ignored and reported: unsafe name, non-executable
# regular file, directory, and symlink.
printf '#!/usr/bin/env bash\nexit 0\n' >"$definitions/BadName"
chmod 0700 "$definitions/BadName"
printf '#!/usr/bin/env bash\nexit 0\n' >"$definitions/disabled"
mkdir "$definitions/not-a-file"
ln -s "$definitions/healthy" "$definitions/linked"

"$services" reconcile
wait_for_count 1 "$events/healthy.starts"
wait_for_count 2 "$events/broken.starts"
[[ -s "$runtime/healthy.state" ]]
[[ -s "$runtime/broken.state" ]]
if ! flock -n "$runtime/reconcile.lock" -c true; then
  echo "service capture inherited and pinned the reconciliation lock" >&2
  exit 1
fi

# A stale or forged PID record is never authority to kill an arbitrary
# same-user process. PID identity and the exact capture argv must both match.
sleep 30 &
decoy_pid=$!
pids+=("$decoy_pid")
decoy_start="$(awk '{print $22}' "/proc/$decoy_pid/stat")"
printf '%s\t%s\tstale\t%s\t%s\t%s\n' "$decoy_pid" "$decoy_start" \
  "$TX9_SERVICES_LOG_HELPER" "$TX9_SERVICES_LOG_DIR" \
  "$TX9_SERVICES_RESTART_DELAY" \
  >"$runtime/ghost.state"
"$services" reconcile >/dev/null 2>&1
kill -0 "$decoy_pid"
[[ ! -e "$runtime/ghost.state" ]]
kill "$decoy_pid"
wait "$decoy_pid" 2>/dev/null || true

# Stop escalation remains bound to the exact capture and service identities
# observed before TERM. Reused numeric PIDs/PGIDs are never sent SIGKILL.
(
  # shellcheck disable=SC1090
  source "$services"
  STATE_DIR="$tmp/reused-stop-runtime"
  STOP_TIMEOUT=1
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/reused.state"
  signal_log="$tmp/reused-stop.signals"
  capture_reads="$tmp/reused-capture.reads"
  child_reads="$tmp/reused-child.reads"

  _state_process_matches() {
    STATE_PID=4242
    STATE_START=100
    return 0
  }
  _direct_children() { printf '6262\n'; }
  _pid_alive() { return 0; }
  _process_start_time() {
    local pid="$1" reads_file count=0
    if [[ "$pid" == 4242 ]]; then
      reads_file="$capture_reads"
      [[ -f "$reads_file" ]] && count="$(wc -l <"$reads_file")"
      printf 'read\n' >>"$reads_file"
      if [[ "$count" == 0 ]]; then printf '100\n'; else printf '200\n'; fi
      return
    fi
    reads_file="$child_reads"
    [[ -f "$reads_file" ]] && count="$(wc -l <"$reads_file")"
    printf 'read\n' >>"$reads_file"
    if ((count < 2)); then printf '300\n'; else printf '400\n'; fi
  }
  ps() { printf '6262\n'; }
  kill() { printf '%s\n' "$*" >>"$signal_log"; }
  sleep() { :; }

  _stop_one reused "$definitions/reused" >/dev/null
  grep -Fxq -- '-TERM 4242' "$signal_log"
  if grep -Fq -- '-KILL' "$signal_log"; then
    echo "stop sent SIGKILL after capture or service PID identity changed" >&2
    exit 1
  fi
  [[ ! -e "$STATE_DIR/reused.state" ]]
)

# A genuinely stuck capture and same-identity service group are both
# escalated. If they survive SIGKILL, stop fails and retains state for retry.
(
  # shellcheck disable=SC1090
  source "$services"
  STATE_DIR="$tmp/stuck-stop-runtime"
  STOP_TIMEOUT=0
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/stuck.state"
  signal_log="$tmp/stuck-stop.signals"

  _state_process_matches() {
    STATE_PID=5252
    STATE_START=500
    return 0
  }
  _direct_children() { printf '7272\n'; }
  _pid_alive() { return 0; }
  _process_start_time() {
    if [[ "$1" == 5252 ]]; then printf '500\n'; else printf '700\n'; fi
  }
  ps() { printf '7272\n'; }
  kill() { printf '%s\n' "$*" >>"$signal_log"; }
  sleep() { :; }

  if _stop_one stuck "$definitions/stuck" \
    >"$tmp/stuck-stop.stdout" 2>"$tmp/stuck-stop.stderr"; then
    echo "stop succeeded after same-identity processes survived SIGKILL" >&2
    exit 1
  fi
  : "$STOP_TIMEOUT" "$STATE_PID" "$STATE_START"
  grep -Fxq -- '-TERM 5252' "$signal_log"
  grep -Fxq -- '-KILL -- -7272' "$signal_log"
  grep -Fxq -- '-KILL 5252' "$signal_log"
  grep -Fq 'capture survived stop' "$tmp/stuck-stop.stderr"
  grep -Fq 'process group survived stop' "$tmp/stuck-stop.stderr"
  [[ -e "$STATE_DIR/stuck.state" ]]
)

"$services" status >"$tmp/services.status"
grep -Fq $'healthy\trunning' "$tmp/services.status"
grep -Fq $'broken\trestarting' "$tmp/services.status"
if grep -Fq $'broken\trunning' "$tmp/services.status"; then
  echo "crash-looping service was reported as running" >&2
  exit 1
fi
grep -Fq $'BadName\tignored (unsafe name)' "$tmp/services.status"
grep -Fq $'disabled\tignored (not executable)' "$tmp/services.status"
grep -Fq $'not-a-file\tignored (not a regular file)' "$tmp/services.status"
grep -Fq $'linked\tignored (symlink)' "$tmp/services.status"

# The flock and runtime identity record serialize concurrent reconciliations;
# the already-running foreground service is not launched twice.
for _ in 1 2 3 4 5 6 7 8; do
  "$services" reconcile >"$tmp/concurrent.$_.out" 2>"$tmp/concurrent.$_.err" &
done
wait
[[ "$(wc -l <"$events/healthy.starts" | tr -d ' ')" == 1 ]]

# A transiently missing current helper cannot replace configured services, so
# reconcile fails without stopping or duplicating their existing supervisors.
# Removed definitions and explicit stop-all still use stored identity to stop.
helper_failure_config="$tmp/helper-failure-config"
helper_failure_definitions="$helper_failure_config/services.d"
helper_failure_runtime="$tmp/helper-failure-runtime"
helper_failure_logs="$tmp/helper-failure-logs"
helper_failure_events="$tmp/helper-failure-events"
missing_helper="$tmp/missing-tx9-logs"
mkdir -p "$helper_failure_definitions" "$helper_failure_runtime" \
  "$helper_failure_logs" "$helper_failure_events"
cat >"$helper_failure_definitions/keep" <<'EOF'
#!/usr/bin/env bash
name="${0##*/}"
printf 'start %s\n' "$$" >>"$HELPER_FAILURE_EVENTS/$name.starts"
trap 'printf "term %s\n" "$$" >>"$HELPER_FAILURE_EVENTS/$name.terms"; exit 0' TERM INT
while :; do sleep 1; done
EOF
cp "$helper_failure_definitions/keep" "$helper_failure_definitions/remove"
chmod 0700 "$helper_failure_definitions/keep" "$helper_failure_definitions/remove"

helper_failure_services() {
  local helper="$1"
  shift
  env HELPER_FAILURE_EVENTS="$helper_failure_events" \
    TX9_SERVICES_CONFIG_ROOT="$helper_failure_config" \
    TX9_SERVICES_STATE_DIR="$helper_failure_runtime" \
    TX9_SERVICES_LOG_DIR="$helper_failure_logs" \
    TX9_SERVICES_LOG_HELPER="$helper" \
    TX9_SERVICES_RESTART_DELAY=0.2 \
    TX9_SERVICES_STOP_TIMEOUT=2 \
    "$services" "$@"
}

helper_failure_services "$PROJECT_ROOT/guest/tx9-logs" reconcile >/dev/null
wait_for_count 1 "$helper_failure_events/keep.starts"
wait_for_count 1 "$helper_failure_events/remove.starts"
keep_state="$(cat "$helper_failure_runtime/keep.state")"
remove_state="$(cat "$helper_failure_runtime/remove.state")"
keep_capture="${keep_state%%$'\t'*}"
remove_capture="${remove_state%%$'\t'*}"
keep_child="$(awk 'NR == 1 { print $2 }' "$helper_failure_events/keep.starts")"
remove_child="$(awk 'NR == 1 { print $2 }' "$helper_failure_events/remove.starts")"
pids+=("$keep_capture" "$remove_capture")

if helper_failure_services "$missing_helper" reconcile \
  >"$tmp/helper-failure.stdout" 2>"$tmp/helper-failure.stderr"; then
  echo "reconcile succeeded without an available log helper" >&2
  exit 1
fi
grep -Fq 'tx9-logs is unavailable' "$tmp/helper-failure.stderr"
[[ "$(cat "$helper_failure_runtime/keep.state")" == "$keep_state" ]]
[[ "$(cat "$helper_failure_runtime/remove.state")" == "$remove_state" ]]
kill -0 "$keep_capture"
kill -0 "$remove_capture"
kill -0 "$keep_child"
kill -0 "$remove_child"
[[ "$(wc -l <"$helper_failure_events/keep.starts" | tr -d ' ')" == 1 ]]
[[ "$(wc -l <"$helper_failure_events/remove.starts" | tr -d ' ')" == 1 ]]
[[ ! -e "$helper_failure_events/keep.terms" ]]
[[ ! -e "$helper_failure_events/remove.terms" ]]

rm -f "$helper_failure_definitions/remove"
if helper_failure_services "$missing_helper" reconcile >/dev/null 2>&1; then
  echo "reconcile masked helper failure after removing a definition" >&2
  exit 1
fi
wait_for_absent "$helper_failure_runtime/remove.state"
wait_for_count 1 "$helper_failure_events/remove.terms"
[[ "$(cat "$helper_failure_runtime/keep.state")" == "$keep_state" ]]
kill -0 "$keep_capture"
kill -0 "$keep_child"
[[ "$(wc -l <"$helper_failure_events/keep.starts" | tr -d ' ')" == 1 ]]

helper_failure_services "$missing_helper" stop-all >/dev/null
wait_for_absent "$helper_failure_runtime/keep.state"
wait_for_count 1 "$helper_failure_events/keep.terms"

# Unexpected SIGKILL of a capture wrapper cannot orphan its direct foreground
# service. Reconcile replaces the stale wrapper with one service, and stop-all
# leaves no managed capture or foreground service behind.
pdeath_config="$tmp/pdeath-config"
pdeath_definitions="$pdeath_config/services.d"
pdeath_runtime="$tmp/pdeath-runtime"
pdeath_logs="$tmp/pdeath-logs"
pdeath_events="$tmp/pdeath-events"
mkdir -p "$pdeath_definitions" "$pdeath_runtime" "$pdeath_logs" "$pdeath_events"
cat >"$pdeath_definitions/guarded" <<'EOF'
#!/usr/bin/env bash
printf 'start %s\n' "$$" >>"$PDEATH_SERVICE_EVENTS/starts"
exec python3 -c 'import signal; signal.pause()' >/dev/null 2>&1
EOF
chmod 0700 "$pdeath_definitions/guarded"

pdeath_services() {
  env PDEATH_SERVICE_EVENTS="$pdeath_events" \
    TX9_SERVICES_CONFIG_ROOT="$pdeath_config" \
    TX9_SERVICES_STATE_DIR="$pdeath_runtime" \
    TX9_SERVICES_LOG_DIR="$pdeath_logs" \
    TX9_SERVICES_LOG_HELPER="$PROJECT_ROOT/guest/tx9-logs" \
    TX9_SERVICES_RESTART_DELAY=0.2 \
    TX9_SERVICES_STOP_TIMEOUT=2 \
    "$services" "$@"
}

pdeath_services reconcile >/dev/null
wait_for_count 1 "$pdeath_events/starts"
old_pdeath_capture="$(cut -f1 "$pdeath_runtime/guarded.state")"
old_pdeath_service="$(awk 'NR == 1 { print $2 }' "$pdeath_events/starts")"
pids+=("$old_pdeath_capture")
kill -KILL "$old_pdeath_capture"
wait_for_process_exit "$old_pdeath_capture"
wait_for_process_exit "$old_pdeath_service"

pdeath_services reconcile >/dev/null
wait_for_count 2 "$pdeath_events/starts"
new_pdeath_capture="$(cut -f1 "$pdeath_runtime/guarded.state")"
new_pdeath_service="$(awk 'NR == 2 { print $2 }' "$pdeath_events/starts")"
pids+=("$new_pdeath_capture")
[[ "$new_pdeath_capture" != "$old_pdeath_capture" ]]
[[ "$new_pdeath_service" != "$old_pdeath_service" ]]
kill -0 "$new_pdeath_capture"
kill -0 "$new_pdeath_service"
[[ "$(wc -l <"$pdeath_events/starts" | tr -d ' ')" == 2 ]]

pdeath_services stop-all >/dev/null
wait_for_absent "$pdeath_runtime/guarded.state"
wait_for_process_exit "$new_pdeath_capture"
wait_for_process_exit "$new_pdeath_service"

# Runtime logging configuration is part of supervisor identity. Status reports
# drift in each setting, and reconcile uses the stored settings to stop the old
# process before starting exactly one replacement with the current settings.
drift_config="$tmp/drift-config"
drift_definitions="$drift_config/services.d"
drift_runtime="$tmp/drift-runtime"
drift_logs_a="$tmp/drift-logs-a"
drift_logs_b="$tmp/drift-logs-b"
drift_events="$tmp/drift-events"
drift_helper_b="$tmp/tx9-logs-b"
mkdir -p "$drift_definitions" "$drift_runtime" "$drift_logs_a" \
  "$drift_logs_b" "$drift_events"
cp "$PROJECT_ROOT/guest/tx9-logs" "$drift_helper_b"
chmod 0700 "$drift_helper_b"
cat >"$drift_definitions/drift" <<'EOF'
#!/usr/bin/env bash
printf 'start %s\n' "$$" >>"$SERVICE_DRIFT_EVENTS/starts"
printf 'drift-log %s\n' "$$"
trap 'printf "term %s\n" "$$" >>"$SERVICE_DRIFT_EVENTS/terms"; exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod 0700 "$drift_definitions/drift"

drift_services() {
  local log_dir="$1" helper="$2" delay="$3"
  shift 3
  env SERVICE_DRIFT_EVENTS="$drift_events" \
    TX9_SERVICES_CONFIG_ROOT="$drift_config" \
    TX9_SERVICES_STATE_DIR="$drift_runtime" \
    TX9_SERVICES_LOG_DIR="$log_dir" \
    TX9_SERVICES_LOG_HELPER="$helper" \
    TX9_SERVICES_RESTART_DELAY="$delay" \
    TX9_SERVICES_STOP_TIMEOUT=2 \
    "$services" "$@"
}

drift_services "$drift_logs_a" "$PROJECT_ROOT/guest/tx9-logs" 0.2 reconcile >/dev/null
wait_for_count 1 "$drift_events/starts"
IFS=$'\t' read -r old_capture _old_start _old_fingerprint old_helper \
  old_log_dir old_delay <"$drift_runtime/drift.state"
pids+=("$old_capture")
[[ "$old_helper" == "$PROJECT_ROOT/guest/tx9-logs" ]]
[[ "$old_log_dir" == "$drift_logs_a" ]]
[[ "$old_delay" == 0.2 ]]

drift_services "$drift_logs_b" "$PROJECT_ROOT/guest/tx9-logs" 0.2 status \
  >"$tmp/drift-log-dir.status"
grep -Fq $'drift\treload pending' "$tmp/drift-log-dir.status"
drift_services "$drift_logs_a" "$drift_helper_b" 0.2 status \
  >"$tmp/drift-helper.status"
grep -Fq $'drift\treload pending' "$tmp/drift-helper.status"
drift_services "$drift_logs_a" "$PROJECT_ROOT/guest/tx9-logs" 0.7 status \
  >"$tmp/drift-delay.status"
grep -Fq $'drift\treload pending' "$tmp/drift-delay.status"

drift_services "$drift_logs_b" "$drift_helper_b" 0.7 reconcile >/dev/null
wait_for_count 1 "$drift_events/terms"
wait_for_count 2 "$drift_events/starts"
wait_for_pattern drift-log "$drift_logs_b/service-drift.jsonl"
IFS=$'\t' read -r new_capture _new_start _new_fingerprint new_helper \
  new_log_dir new_delay <"$drift_runtime/drift.state"
pids+=("$new_capture")
[[ "$new_capture" != "$old_capture" ]]
[[ "$new_helper" == "$drift_helper_b" ]]
[[ "$new_log_dir" == "$drift_logs_b" ]]
[[ "$new_delay" == 0.7 ]]
old_service="$(awk 'NR == 1 { print $2 }' "$drift_events/starts")"
new_service="$(awk 'NR == 2 { print $2 }' "$drift_events/starts")"
for _ in {1..100}; do
  if ! kill -0 "$old_capture" 2>/dev/null ||
    [[ "$(ps -o stat= -p "$old_capture" 2>/dev/null)" == Z* ]]; then
    break
  fi
  sleep 0.02
done
if kill -0 "$old_capture" 2>/dev/null &&
  [[ "$(ps -o stat= -p "$old_capture" 2>/dev/null)" != Z* ]]; then
  echo "old service supervisor survived runtime-config reconciliation" >&2
  exit 1
fi
if kill -0 "$old_service" 2>/dev/null &&
  [[ "$(ps -o stat= -p "$old_service" 2>/dev/null)" != Z* ]]; then
  echo "old custom service survived runtime-config reconciliation" >&2
  exit 1
fi
kill -0 "$new_capture"
kill -0 "$new_service"
[[ "$(wc -l <"$drift_events/starts" | tr -d ' ')" == 2 ]]
[[ "$(wc -l <"$drift_events/terms" | tr -d ' ')" == 1 ]]
drift_services "$drift_logs_b" "$drift_helper_b" 0.7 stop-all >/dev/null
wait_for_count 2 "$drift_events/terms"
wait_for_absent "$drift_runtime/drift.state"

# Definition identity includes the content digest, not just whole-second stat
# metadata. Rewrite a same-size script in place, restore its original mtime,
# and require immediate replacement of the old foreground child.
cat >"$definitions/reloadable" <<'EOF'
#!/usr/bin/env bash
printf 'old\n' >>"$SERVICE_TEST_EVENTS/reloadable.starts"
trap 'printf "old\n" >>"$SERVICE_TEST_EVENTS/reloadable.terms"; exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod 0700 "$definitions/reloadable"
"$services" reconcile >/dev/null
wait_for_pattern old "$events/reloadable.starts"
reload_metadata="$(stat -c '%d:%i:%Y:%s:%a' "$definitions/reloadable")"
reload_mtime="$(stat -c '%Y' "$definitions/reloadable")"
cat >"$definitions/reloadable" <<'EOF'
#!/usr/bin/env bash
printf 'new\n' >>"$SERVICE_TEST_EVENTS/reloadable.starts"
trap 'printf "new\n" >>"$SERVICE_TEST_EVENTS/reloadable.terms"; exit 0' TERM INT
while :; do sleep 1; done
EOF
touch -d "@$reload_mtime" "$definitions/reloadable"
[[ "$(stat -c '%d:%i:%Y:%s:%a' "$definitions/reloadable")" == "$reload_metadata" ]]
"$services" reconcile >/dev/null
wait_for_pattern old "$events/reloadable.terms"
wait_for_pattern new "$events/reloadable.starts"
rm -f "$definitions/reloadable"
"$services" reconcile >/dev/null

# A crashing service restarts with the configured bounded delay while the
# healthy service stays up and reconciliation remains responsive.
before="$(wc -l <"$events/broken.starts" | tr -d ' ')"
sleep 0.1
after_early="$(wc -l <"$events/broken.starts" | tr -d ' ')"
[[ "$after_early" -le $((before + 1)) ]]
wait_for_count $((before + 1)) "$events/broken.starts"
[[ "$(wc -l <"$events/healthy.starts" | tr -d ' ')" == 1 ]]

# Each custom source is independently queryable, and `all` includes it.
wait_for_pattern healthy-log "$logs/service-healthy.jsonl"
"$PROJECT_ROOT/guest/tx9-logs" query --agent-root "$data" \
  --executor-root "$tmp/empty-executor" --box fixture --source service-healthy \
  --tail 100 --json >"$tmp/service-query.jsonl"
jq -e 'select(.source == "service-healthy" and .message == "healthy-log")' \
  "$tmp/service-query.jsonl" >/dev/null
"$PROJECT_ROOT/guest/tx9-logs" query --agent-root "$data" \
  --executor-root "$tmp/empty-executor" --box fixture --source all \
  --tail 100 --json >"$tmp/all-query.jsonl"
jq -e 'select(.source == "service-healthy" and .message == "healthy-log")' \
  "$tmp/all-query.jsonl" >/dev/null

# Removing execute permission removes the desired service and synchronously
# stops its capture and foreground child. Restoring it starts one fresh copy.
chmod 0600 "$definitions/healthy"
"$services" reconcile
wait_for_absent "$runtime/healthy.state"
wait_for_count 1 "$events/healthy.terms"
chmod 0700 "$definitions/healthy"
"$services" reconcile
wait_for_count 2 "$events/healthy.starts"

# Direct capture termination reaches the service process group, including its
# foreground shell trap. Reconciliation replaces the now-stale runtime record.
capture_pid="$(cut -f1 "$runtime/healthy.state")"
kill -TERM "$capture_pid"
wait_for_count 2 "$events/healthy.terms"
for _ in {1..100}; do
  kill -0 "$capture_pid" 2>/dev/null || break
  [[ "$(ps -o stat= -p "$capture_pid" 2>/dev/null)" == Z* ]] && break
  sleep 0.02
done
"$services" reconcile
wait_for_count 3 "$events/healthy.starts"

# hb owns the durable lifecycle gate: pause waits for every service, a
# quiesced reload cannot restart them, resume starts them, and gateway-disable
# remains independent.
(
  export HB_DATA="$data" HOME="$home"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  _stop_gateway() { return 0; }
  _stop_executor() { return 0; }
  _executor_up() { return 0; }
  _start_gateway() { return 0; }
  pause >/dev/null
)
wait_for_absent "$runtime/healthy.state"
wait_for_absent "$runtime/broken.state"
healthy_before_resume="$(wc -l <"$events/healthy.starts" | tr -d ' ')"
"$services" reconcile
sleep 0.1
[[ "$(wc -l <"$events/healthy.starts" | tr -d ' ')" == "$healthy_before_resume" ]]
(
  export HB_DATA="$data" HOME="$home"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  _executor_up() { return 0; }
  _start_gateway() { return 0; }
  resume >/dev/null
)
wait_for_count $((healthy_before_resume + 1)) "$events/healthy.starts"
healthy_capture="$(cut -f1 "$runtime/healthy.state")"
(
  export HB_DATA="$data" HOME="$home"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/guest/hb"
  _stop_gateway() { return 0; }
  gateway_disable >/dev/null
)
kill -0 "$healthy_capture"

# Deletion stops a service, while the other definition remains independently
# supervised. Finish by proving stop-all leaves no managed capture alive.
rm -f "$definitions/broken"
"$services" reconcile
wait_for_absent "$runtime/broken.state"
"$services" stop-all
wait_for_absent "$runtime/healthy.state"

# An empty status includes the exact installation path instead of presenting
# a bare table with no next step.
empty_config="$tmp/empty-config"
TX9_SERVICES_CONFIG_ROOT="$empty_config" \
  TX9_SERVICES_STATE_DIR="$tmp/empty-runtime" \
  TX9_SERVICES_LOG_DIR="$tmp/empty-logs" \
  "$services" status >"$tmp/empty.status"
grep -Fq "No custom services configured. Add executable files to $empty_config/services.d" \
  "$tmp/empty.status"

# A service started by a separate reload/session is outside the workload's
# process group. TERM on the workload must still synchronously stop it via the
# runtime identity record and preserve signal-derived exit status.
term_data="$tmp/term-data"
term_home="$term_data/home/agent"
term_config="$term_home/.config/hermes-box"
term_definitions="$term_config/services.d"
term_runtime="$tmp/term-runtime"
term_logs="$term_data/logs"
term_events="$tmp/term-events"
mkdir -p "$term_definitions" "$term_runtime" "$term_logs" "$term_events" "$tmp/term-bin"
cat >"$term_definitions/separate" <<'EOF'
#!/usr/bin/env bash
printf 'started\n' >>"$SERVICE_TERM_EVENTS/starts"
trap 'printf "terminated\n" >>"$SERVICE_TERM_EVENTS/terms"; exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod 0700 "$term_definitions/separate"
cat >"$tmp/term-bin/hb" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0700 "$tmp/term-bin/hb"
setsid env HOME="$term_home" SERVICE_TERM_EVENTS="$term_events" \
  TX9_SERVICES_CONFIG_ROOT="$term_config" \
  TX9_SERVICES_STATE_DIR="$term_runtime" \
  TX9_SERVICES_LOG_DIR="$term_logs" \
  TX9_SERVICES_LOG_HELPER="$PROJECT_ROOT/guest/tx9-logs" \
  TX9_SERVICES_RESTART_DELAY=0.2 TX9_SERVICES_STOP_TIMEOUT=2 \
  "$services" reconcile >/dev/null
wait_for_pattern started "$term_events/starts"
separate_capture="$(cut -f1 "$term_runtime/separate.state")"
pids+=("$separate_capture")
setsid env HOME="$term_home" PATH="$tmp/term-bin:$PATH" \
  TX9_SERVICES_STATE_DIR="$term_runtime" \
  TX9_SERVICES_LOG_HELPER="$PROJECT_ROOT/guest/tx9-logs" \
  TX9_SERVICES_RESTART_DELAY=0.2 TX9_SERVICES_STOP_TIMEOUT=2 \
  HB_WORKLOAD_LOGS="$term_logs" HB_BOX_ENV="$tmp/missing-box.env" \
  "$PROJECT_ROOT/guest/hb-workload" 4788 0 \
  >"$tmp/term-workload.stdout" 2>"$tmp/term-workload.stderr" &
workload_pid=$!
pids+=("$workload_pid")
for _ in {1..100}; do
  kill -0 "$workload_pid" 2>/dev/null && break
  sleep 0.02
done
separate_pgid="$(ps -o pgid= -p "$separate_capture" | tr -d ' ')"
workload_pgid="$(ps -o pgid= -p "$workload_pid" | tr -d ' ')"
[[ -n "$separate_pgid" && -n "$workload_pgid" && "$separate_pgid" != "$workload_pgid" ]]
kill -TERM "$workload_pid"
set +e
wait "$workload_pid"
workload_status=$?
set -e
[[ "$workload_status" == 143 ]]
wait_for_pattern terminated "$term_events/terms"
wait_for_absent "$term_runtime/separate.state"

echo "custom service regression checks passed"
