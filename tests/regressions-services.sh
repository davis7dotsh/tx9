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
printf '%s\t%s\tstale\t%s\t%s\n' "$decoy_pid" "$decoy_start" \
  "$TX9_SERVICES_LOG_HELPER" "$TX9_SERVICES_RESTART_DELAY" \
  >"$runtime/ghost.state"
"$services" reconcile >/dev/null 2>&1
kill -0 "$decoy_pid"
[[ ! -e "$runtime/ghost.state" ]]
kill "$decoy_pid"
wait "$decoy_pid" 2>/dev/null || true

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
