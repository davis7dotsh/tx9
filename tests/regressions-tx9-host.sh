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

# tx9-backup-prune keeps the newest TX9_BACKUP_RETAIN_COUNT backups, applies
# an optional TX9_BACKUP_RETAIN_DAYS cap on top, leaves a missing NAS
# directory alone, never touches another box's backups, and validates input.
#
# CRITICAL ISOLATION: the script sources /etc/tx9/tx9.conf and the per-box
# conf AFTER the environment, so a real host config overrides the test's
# TX9_BACKUP_DIR — on a production host, an unisolated run points the prune
# at the REAL backup directory and (given permissions) deletes real backups.
# Observed live on nexus: /etc/tx9/boxes/hermes.conf redirected this test to
# /var/backups/tx9; only a permission error stopped it. Point both config
# knobs at test-owned paths for every invocation below.
export TX9_CONFIG="/dev/null"
export TX9_BOX_CONFIG_DIR="$tmp/prune-no-box-config"
prune_dir="$tmp/prune-backups"
mkdir -p "$prune_dir"
for day in 10 9 8 7 6 5 4 3 2 1; do
  stamp="$(date -u -d "-${day} days" +%Y%m%d-%H%M%SZ)"
  : >"$prune_dir/hermes-${stamp}.tar.gz.gpg"
  : >"$prune_dir/hermes-${stamp}.tar.gz.gpg.sha256"
done
: >"$prune_dir/other-$(date -u -d '-1 days' +%Y%m%d-%H%M%SZ).tar.gz.gpg"
: >"$prune_dir/other-$(date -u -d '-1 days' +%Y%m%d-%H%M%SZ).tar.gz.gpg.sha256"

TX9_BACKUP_DIR="$prune_dir" TX9_BACKUP_RETAIN_COUNT=3 \
  "$PROJECT_ROOT/ops/tx9-backup-prune" hermes >/dev/null
[[ "$(find "$prune_dir" -maxdepth 1 -name 'hermes-*.tar.gz.gpg' | wc -l)" == 3 ]]
[[ "$(find "$prune_dir" -maxdepth 1 -name 'other-*.tar.gz.gpg' | wc -l)" == 1 ]]
# The 3 survivors are the 3 newest (days 1-3 back); each kept .tar.gz.gpg
# still has its matching .sha256 companion.
for day in 1 2 3; do
  stamp="$(date -u -d "-${day} days" +%Y%m%d-%H%M%SZ)"
  [[ -e "$prune_dir/hermes-${stamp}.tar.gz.gpg" ]]
  [[ -e "$prune_dir/hermes-${stamp}.tar.gz.gpg.sha256" ]]
done

TX9_BACKUP_DIR="$prune_dir" TX9_BACKUP_RETAIN_COUNT=3 TX9_BACKUP_RETAIN_DAYS=2 \
  "$PROJECT_ROOT/ops/tx9-backup-prune" hermes >/dev/null
[[ "$(find "$prune_dir" -maxdepth 1 -name 'hermes-*.tar.gz.gpg' | wc -l)" == 2 ]]

missing_nas="$tmp/missing-nas"
TX9_BACKUP_DIR="$prune_dir" TX9_NAS_DIR="$missing_nas" TX9_BACKUP_RETAIN_COUNT=2 \
  "$PROJECT_ROOT/ops/tx9-backup-prune" hermes >/dev/null
[[ ! -e "$missing_nas" ]]

if "$PROJECT_ROOT/ops/tx9-backup-prune" '../escape' >/dev/null 2>&1; then
  echo "tx9-backup-prune accepted an unsafe box name" >&2
  exit 1
fi
if TX9_BACKUP_RETAIN_COUNT=not-a-number "$PROJECT_ROOT/ops/tx9-backup-prune" hermes >/dev/null 2>&1; then
  echo "tx9-backup-prune accepted a non-numeric retain count" >&2
  exit 1
fi

echo "tx9-host regression checks passed"
