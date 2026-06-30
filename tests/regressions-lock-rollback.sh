#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2329
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

mkdir -p "$tmp/valid/home/agent/workspace" "$tmp/gnupg" "$tmp/host-tmp"
chmod 0700 "$tmp/gnupg"
printf 'portable state\n' >"$tmp/valid/home/agent/workspace/probe.txt"
tar czf "$tmp/valid.tgz" -C "$tmp/valid" .
export GNUPGHOME="$tmp/gnupg"
export BOX_PASSPHRASE='regression-passphrase'
gpg --batch --yes --pinentry-mode loopback --passphrase "$BOX_PASSPHRASE" \
  --symmetric --cipher-algo AES256 -o "$tmp/valid.tar.gz.gpg" "$tmp/valid.tgz"

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
    archive.writestr("tmp/transient.log", "do not migrate\n")
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
      --external .honcho >"$tmp/${stopped_name}.output" 2>&1; then
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
grep -q 'Native import will intentionally skip 1 non-portable or transient file(s)' \
  "$tmp/stopped-import-success.output"
grep -q 'Hermes import verified. Gateway remains disabled' "$tmp/stopped-import-success.output"

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


echo "lock-rollback regression checks passed"
