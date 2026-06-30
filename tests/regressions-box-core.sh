#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2329
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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

# Missing legacy resource settings use the documented production defaults.
(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  unset BOX_CPUS BOX_MEM_MIB BOX_OVERLAY_GIB BOX_STORAGE_GIB
  _validate_resources
  [[ "$BOX_CPUS" == 4 && "$BOX_MEM_MIB" == 8192 && "$BOX_OVERLAY_GIB" == 64 && -z "$BOX_STORAGE_GIB" ]]
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

echo "box-core regression checks passed"
