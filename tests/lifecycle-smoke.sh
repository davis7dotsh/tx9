#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp/valid/home/agent/workspace" "$tmp/invalid/not-home" "$tmp/gnupg" "$tmp/host-tmp"
chmod 0700 "$tmp/gnupg"
printf 'portable state\n' >"$tmp/valid/home/agent/workspace/probe.txt"
ln -s probe.txt "$tmp/valid/home/agent/workspace/probe-link"
ln "$tmp/valid/home/agent/workspace/probe.txt" "$tmp/valid/home/agent/workspace/probe-hard"
printf 'invalid state\n' >"$tmp/invalid/not-home/probe.txt"
tar czf "$tmp/valid.tgz" -C "$tmp/valid" .
tar czf "$tmp/invalid.tgz" -C "$tmp/invalid" .
python3 - "$tmp/absolute-symlink.tgz" "$tmp/traversal-symlink.tgz" \
  "$tmp/invalid-hardlink.tgz" "$tmp/special-file.tgz" "$tmp/home-link.tgz" \
  "$tmp/cycle-link.tgz" "$tmp/pivot-link.tgz" "$tmp/root-symlink.tgz" \
  "$tmp/root-hardlink.tgz" "$tmp/linked-parent-alias.tgz" \
  "$tmp/linked-parent-regular.tgz" "$tmp/control-char-name.tgz" \
  "$tmp/control-char-link.tgz" <<'PY'
import io
import sys
import tarfile

def directory(name):
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o700
    return info

with tarfile.open(sys.argv[1], "w:gz") as archive:
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    link = tarfile.TarInfo("home/agent/workspace")
    link.type = tarfile.SYMTYPE
    link.linkname = "/tmp/escape"
    archive.addfile(link)

with tarfile.open(sys.argv[2], "w:gz") as archive:
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    link = tarfile.TarInfo("home/escape-link")
    link.type = tarfile.SYMTYPE
    link.linkname = "../../"
    archive.addfile(link)

with tarfile.open(sys.argv[3], "w:gz") as archive:
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    link = tarfile.TarInfo("home/agent/workspace")
    link.type = tarfile.LNKTYPE
    link.linkname = "../../escape"
    archive.addfile(link)

with tarfile.open(sys.argv[4], "w:gz") as archive:
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    fifo = tarfile.TarInfo("home/agent/runtime.fifo")
    fifo.type = tarfile.FIFOTYPE
    archive.addfile(fifo)

with tarfile.open(sys.argv[5], "w:gz") as archive:
    archive.addfile(directory("home"))
    link = tarfile.TarInfo("home/agent")
    link.type = tarfile.SYMTYPE
    link.linkname = "/"
    archive.addfile(link)

with tarfile.open(sys.argv[6], "w:gz") as archive:
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    first = tarfile.TarInfo("home/agent/first")
    first.type = tarfile.SYMTYPE
    first.linkname = "second"
    archive.addfile(first)
    second = tarfile.TarInfo("home/agent/second")
    second.type = tarfile.SYMTYPE
    second.linkname = "first"
    archive.addfile(second)

with tarfile.open(sys.argv[7], "w:gz") as archive:
    archive.addfile(directory("."))
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    victim_data = b"victim\n"
    victim = tarfile.TarInfo("home/agent/victim")
    victim.size = len(victim_data)
    archive.addfile(victim, io.BytesIO(victim_data))
    up = tarfile.TarInfo("home/agent/up")
    up.type = tarfile.SYMTYPE
    up.linkname = "../.."
    archive.addfile(up)
    pivot = tarfile.TarInfo("home/agent/x")
    pivot.type = tarfile.SYMTYPE
    pivot.linkname = "up/../victim"
    archive.addfile(pivot)

with tarfile.open(sys.argv[8], "w:gz") as archive:
    root = tarfile.TarInfo("./")
    root.type = tarfile.SYMTYPE
    root.linkname = "home"
    archive.addfile(root)
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))

with tarfile.open(sys.argv[9], "w:gz") as archive:
    root = tarfile.TarInfo(".")
    root.type = tarfile.LNKTYPE
    root.linkname = "home/agent"
    archive.addfile(root)
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))

with tarfile.open(sys.argv[10], "w:gz") as archive:
    archive.addfile(directory("."))
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    up = tarfile.TarInfo("home/agent/up")
    up.type = tarfile.SYMTYPE
    up.linkname = "../.."
    archive.addfile(up)
    alias = tarfile.TarInfo("home/agent/up/home")
    alias.type = tarfile.SYMTYPE
    alias.linkname = "/tmp/linked-parent-escape"
    archive.addfile(alias)

with tarfile.open(sys.argv[11], "w:gz") as archive:
    archive.addfile(directory("."))
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    up = tarfile.TarInfo("home/agent/up")
    up.type = tarfile.SYMTYPE
    up.linkname = "../.."
    archive.addfile(up)
    payload = b"must not extract through link\n"
    child = tarfile.TarInfo("home/agent/up/owned")
    child.size = len(payload)
    archive.addfile(child, io.BytesIO(payload))

with tarfile.open(sys.argv[12], "w:gz") as archive:
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    bad = tarfile.TarInfo("home/agent/bad\x01name")
    payload = b"control character in member name\n"
    bad.size = len(payload)
    archive.addfile(bad, io.BytesIO(payload))

with tarfile.open(sys.argv[13], "w:gz") as archive:
    archive.addfile(directory("home"))
    archive.addfile(directory("home/agent"))
    link = tarfile.TarInfo("home/agent/bad-link")
    link.type = tarfile.SYMTYPE
    link.linkname = "bad\x01target"
    archive.addfile(link)
PY

(
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/box"
  _validate_name valid-box_1.2
  _validate_archive "$tmp/valid.tgz"
  if _validate_archive "$tmp/invalid.tgz"; then
    echo "archive without durable home passed validation" >&2
    exit 1
  fi
  for unsafe in "$tmp/absolute-symlink.tgz" "$tmp/traversal-symlink.tgz" \
    "$tmp/invalid-hardlink.tgz" "$tmp/special-file.tgz" "$tmp/home-link.tgz" \
    "$tmp/cycle-link.tgz" "$tmp/pivot-link.tgz" "$tmp/root-symlink.tgz" \
    "$tmp/root-hardlink.tgz" "$tmp/linked-parent-alias.tgz" \
    "$tmp/linked-parent-regular.tgz" "$tmp/control-char-name.tgz" \
    "$tmp/control-char-link.tgz"; do
    if _validate_archive "$unsafe"; then
      echo "linked archive passed validation: $unsafe" >&2
      exit 1
    fi
  done
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
for unsafe in absolute-symlink traversal-symlink invalid-hardlink special-file home-link cycle-link \
  pivot-link root-symlink root-hardlink linked-parent-alias linked-parent-regular \
  control-char-name control-char-link; do
  gpg --batch --yes --pinentry-mode loopback --passphrase "$BOX_PASSPHRASE" \
    --symmetric --cipher-algo AES256 -o "$tmp/${unsafe}.tar.gz.gpg" "$tmp/${unsafe}.tgz"
done

TMPDIR="$tmp/host-tmp" "$PROJECT_ROOT/box" extract "$tmp/valid.tar.gz.gpg" "$tmp/extracted" >/dev/null
cmp "$tmp/valid/home/agent/workspace/probe.txt" "$tmp/extracted/home/agent/workspace/probe.txt"
[[ -L "$tmp/extracted/home/agent/workspace/probe-link" ]]
[[ "$(readlink "$tmp/extracted/home/agent/workspace/probe-link")" == probe.txt ]]
cmp "$tmp/extracted/home/agent/workspace/probe-link" "$tmp/extracted/home/agent/workspace/probe.txt"
python3 - "$tmp/extracted/home/agent/workspace/probe.txt" \
  "$tmp/extracted/home/agent/workspace/probe-hard" <<'PY'
import os
import sys
assert os.stat(sys.argv[1]).st_ino == os.stat(sys.argv[2]).st_ino
PY
[[ -z "$(find "$tmp/host-tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]]

for unsafe in absolute-symlink traversal-symlink invalid-hardlink special-file home-link cycle-link \
  pivot-link root-symlink root-hardlink linked-parent-alias linked-parent-regular \
  control-char-name control-char-link; do
  unsafe_sentinel="$tmp/${unsafe}-smolvm-called"
  if PATH="$PROJECT_ROOT/tests/fixtures:$PATH" SMOLVM_CALLED="$unsafe_sentinel" \
    SMOLVM_STATE_DIR="$tmp/smolvm-state" TMPDIR="$tmp/host-tmp" \
    "$PROJECT_ROOT/box" load "$tmp/${unsafe}.tar.gz.gpg" "${unsafe}-destination" >/dev/null 2>&1; then
    echo "$unsafe archive unexpectedly loaded" >&2
    exit 1
  fi
  [[ ! -e "$unsafe_sentinel" ]] || { echo "VM command ran before $unsafe validation" >&2; exit 1; }
done

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
