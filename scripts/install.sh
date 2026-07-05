#!/bin/sh
# tx9 installer -- served by https://tx9.davis7.sh/install (decision 10,
# docs/tx9-cli-design.md).
#
#   curl -fsSL https://tx9.davis7.sh/install | sh
#
# Detects OS/arch, downloads the matching tx9 release binary + its
# checksums.txt from the latest GitHub release, verifies the checksum, and
# installs to ~/.local/bin/tx9 (override with TX9_INSTALL_DIR).
#
# Asset naming is the one invariant this script shares with
# internal/selfupdate.AssetName, the Makefile's `dist` target, and
# .github/workflows/release.yml: plain, uncompressed executables named
# tx9_<os>_<arch>, verified against a checksums.txt release asset in
# `sha256sum` output format ("<64-hex-digest>  <filename>" per line).
#
# Deliberately plain POSIX sh + curl: no jq, no GitHub API call -- the
# stable /releases/latest/download/<asset> URL shape resolves straight to
# the current release's asset without needing to parse JSON.
set -eu

REPO="davis7dotsh/tx9"
INSTALL_DIR="${TX9_INSTALL_DIR:-$HOME/.local/bin}"

log() {
  printf 'tx9-install: %s\n' "$*" >&2
}

die() {
  log "$*"
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required to install tx9"
}

detect_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) die "unsupported OS: $(uname -s) (tx9 currently ships Linux and macOS binaries)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m) (tx9 currently ships amd64 and arm64 binaries)" ;;
  esac
}

need curl
need uname
need mktemp
need mkdir
need chmod
need mv
need awk

os=$(detect_os)
arch=$(detect_arch)
asset="tx9_${os}_${arch}"

base_url="https://github.com/${REPO}/releases/latest/download"
asset_url="${base_url}/${asset}"
checksums_url="${base_url}/checksums.txt"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT INT TERM HUP

log "downloading ${asset}..."
if ! curl -fsSL "$asset_url" -o "$tmpdir/$asset"; then
  die "download failed: $asset_url (no release published yet, or an unsupported platform)"
fi

log "downloading checksums.txt..."
if ! curl -fsSL "$checksums_url" -o "$tmpdir/checksums.txt"; then
  die "download failed: $checksums_url"
fi

expected=$(awk -v want="$asset" '$2 == want { print $1; found=1 } END { if (!found) exit 1 }' "$tmpdir/checksums.txt") \
  || die "no checksum entry for ${asset} in checksums.txt"

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmpdir/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$tmpdir/$asset" | awk '{ print $1 }')
else
  die "neither sha256sum nor shasum found; cannot verify ${asset} (install them, or download and verify manually)"
fi

[ "$actual" = "$expected" ] || die "checksum mismatch for ${asset}: got ${actual}, want ${expected} (not installing)"

mkdir -p "$INSTALL_DIR"
chmod 0755 "$tmpdir/$asset"
mv "$tmpdir/$asset" "$INSTALL_DIR/tx9"

log "installed tx9 to ${INSTALL_DIR}/tx9"

case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *)
    log "note: ${INSTALL_DIR} is not on your PATH. Add it to your shell profile, e.g.:"
    log "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    ;;
esac

if version=$("$INSTALL_DIR/tx9" version 2>/dev/null); then
  log "tx9 ${version} ready"
else
  log "installed, but 'tx9 version' did not run cleanly -- check ${INSTALL_DIR}/tx9 manually"
fi
