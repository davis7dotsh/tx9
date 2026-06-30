#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2329
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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

echo "tx9-host regression checks passed"
