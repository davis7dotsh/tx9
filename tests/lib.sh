#!/usr/bin/env bash
# Shared test harness: a fresh $tmp per file, cleaned up on exit or signal
# using the same signal-to-exit-code mapping box itself uses (129/130/143),
# plus make_repo() and the wait_for_* polling helpers used across the suite.
# Source this after `set -euo pipefail`; do not execute it directly.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
pids=()
cleaned_up=0

cleanup() {
  local pid
  [[ "$cleaned_up" == 0 ]] || return 0
  cleaned_up=1
  for pid in "${pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$tmp"
}

handle_signal() {
  local status="$1"
  trap - EXIT HUP INT TERM
  cleanup
  exit "$status"
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
[[ "$(trap -p HUP)" == *"handle_signal 129"* ]]
[[ "$(trap -p INT)" == *"handle_signal 130"* ]]
[[ "$(trap -p TERM)" == *"handle_signal 143"* ]]

wait_for_file() {
  local file="$1" attempt
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -s "$file" ]] && return
    sleep 0.02
  done
  echo "timed out waiting for $file" >&2
  return 1
}

wait_for_pattern() {
  local pattern="$1" file="$2" attempt
  for ((attempt = 0; attempt < 100; attempt++)); do
    grep -q "$pattern" "$file" 2>/dev/null && return
    sleep 0.02
  done
  echo "timed out waiting for '$pattern' in $file" >&2
  return 1
}

make_repo() {
  local dest="$1"
  mkdir -p "$dest/backups"
  cp "$PROJECT_ROOT/box" "$PROJECT_ROOT/box.env" "$dest/"
  cp -R "$PROJECT_ROOT/guest" "$PROJECT_ROOT/provision" "$dest/"
}
