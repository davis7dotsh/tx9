#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp/valid/home/agent/workspace" "$tmp/invalid/not-home" "$tmp/gnupg" "$tmp/host-tmp"
chmod 0700 "$tmp/gnupg"
printf 'portable state\n' >"$tmp/valid/home/agent/workspace/probe.txt"
printf 'invalid state\n' >"$tmp/invalid/not-home/probe.txt"
tar czf "$tmp/valid.tgz" -C "$tmp/valid" .
tar czf "$tmp/invalid.tgz" -C "$tmp/invalid" .

(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  _validate_name valid-box_1.2
  _validate_archive "$tmp/valid.tgz"
  if _validate_archive "$tmp/invalid.tgz"; then
    echo "archive without durable home passed validation" >&2
    exit 1
  fi
)

if (
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  _validate_name '../unsafe'
); then
  echo "unsafe box name passed validation" >&2
  exit 1
fi

export GNUPGHOME="$tmp/gnupg"
export BOX_PASSPHRASE='lifecycle-smoke-passphrase'
gpg --batch --yes --pinentry-mode loopback --passphrase "$BOX_PASSPHRASE" \
  --symmetric --cipher-algo AES256 -o "$tmp/valid.tar.gz.gpg" "$tmp/valid.tgz"
gpg --batch --yes --pinentry-mode loopback --passphrase "$BOX_PASSPHRASE" \
  --symmetric --cipher-algo AES256 -o "$tmp/invalid.tar.gz.gpg" "$tmp/invalid.tgz"

TMPDIR="$tmp/host-tmp" "$PROJECT_ROOT/box" extract "$tmp/valid.tar.gz.gpg" "$tmp/extracted" >/dev/null
cmp "$tmp/valid/home/agent/workspace/probe.txt" "$tmp/extracted/home/agent/workspace/probe.txt"
[[ -z "$(find "$tmp/host-tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]]

sentinel="$tmp/smolvm-called"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$sentinel" \
  SMOLVM_STATE_DIR="$tmp/smolvm-state" \
  TMPDIR="$tmp/host-tmp" "$PROJECT_ROOT/box" load "$tmp/invalid.tar.gz.gpg" invalid-destination >/dev/null 2>&1; then
  echo "invalid archive unexpectedly loaded" >&2
  exit 1
fi
[[ ! -e "$sentinel" ]] || { echo "VM command ran before archive validation" >&2; exit 1; }
[[ -z "$(find "$tmp/host-tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]]

mkdir -p "$tmp/repo"
cp "$PROJECT_ROOT/box" "$PROJECT_ROOT/box.env" "$tmp/repo/"
cp -R "$PROJECT_ROOT/guest" "$PROJECT_ROOT/provision" "$tmp/repo/"
if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$sentinel" \
  SMOLVM_STATE_DIR="$tmp/smolvm-state" "$tmp/repo/box" new rollback-probe >/dev/null 2>&1; then
  echo "mock provisioning failure unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -d "$tmp/smolvm-state/rollback-probe" ]] || { echo "failed box was not deleted" >&2; exit 1; }
[[ ! -s "$tmp/repo/.boxes" ]] || { echo "failed box remained registered" >&2; exit 1; }
[[ -z "$(find "$tmp/repo/.box-locks" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || {
  echo "operation lock survived process exit" >&2
  exit 1
}

if BOX_PASSPHRASE=wrong TMPDIR="$tmp/host-tmp" \
  "$PROJECT_ROOT/box" extract "$tmp/valid.tar.gz.gpg" "$tmp/wrong-pass" >/dev/null 2>&1; then
  echo "wrong passphrase unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -e "$tmp/wrong-pass" ]]
[[ -z "$(find "$tmp/host-tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]]

echo "lifecycle smoke checks passed"
