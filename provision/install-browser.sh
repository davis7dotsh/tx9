#!/usr/bin/env bash
# Image-owned Chromium for Testing + agent-browser. Sourced by provision.sh.
set -euo pipefail

: "${OPT:=/opt/hermes-box}"
: "${CTX:=}"

if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[provision] %s\n' "$*"; }
fi

_browser_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)
      AB_ASSET="agent-browser-linux-x64"
      AB_SHA256="${AGENT_BROWSER_LINUX_X64_SHA256:?}"
      CHROME_PLATFORM="linux64"
      CHROME_DIR="chrome-linux64"
      CHROME_SHA256="${CHROME_LINUX64_SHA256:?}"
      MANIFEST_ARCH="linux-x64"
      ;;
    aarch64 | arm64)
      AB_ASSET="agent-browser-linux-arm64"
      AB_SHA256="${AGENT_BROWSER_LINUX_ARM64_SHA256:?}"
      CHROME_PLATFORM="linux-arm64"
      CHROME_DIR="chrome-linux-arm64"
      CHROME_SHA256="${CHROME_LINUX_ARM64_SHA256:?}"
      MANIFEST_ARCH="linux-arm64"
      ;;
    *)
      log "browser: unsupported architecture: $(uname -m)"
      return 1
      ;;
  esac
}

_browser_pins_match() {
  local manifest="$OPT/browser/manifest.json"
  local chrome="$OPT/browser/chrome/$CHROME_DIR/chrome"
  local cli="$OPT/browser/bin/agent-browser"
  [[ -f "$manifest" && -x "$cli" && -x "$chrome" ]] || return 1
  python3 - "$manifest" "$AGENT_BROWSER_VERSION" "$CHROME_FOR_TESTING_VERSION" \
    "$AB_SHA256" "$CHROME_SHA256" "$MANIFEST_ARCH" <<'PY'
import json, sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
want = {
    "agent_browser_version": sys.argv[2],
    "chrome_version": sys.argv[3],
    "agent_browser_sha256": sys.argv[4],
    "chrome_sha256": sys.argv[5],
    "arch": sys.argv[6],
}
sys.exit(0 if all(data.get(key) == value for key, value in want.items()) else 1)
PY
}

_browser_link() {
  mkdir -p "$OPT/bin" "$OPT/browser/bin" "$OPT/browser/fixtures"
  ln -sfn "../browser/bin/agent-browser" "$OPT/bin/agent-browser"
  ln -sfn "../browser/chrome/$CHROME_DIR/chrome" "$OPT/bin/chrome"
  # agent-browser looks for system Chrome names, not $PATH/chrome.
  ln -sfn "$OPT/bin/chrome" /usr/bin/google-chrome
  ln -sfn "$OPT/bin/chrome" /usr/bin/google-chrome-stable
}

_browser_write_manifest() {
  python3 - "$OPT/browser/manifest.json" "$AGENT_BROWSER_VERSION" \
    "$CHROME_FOR_TESTING_VERSION" "$AB_SHA256" "$CHROME_SHA256" "$MANIFEST_ARCH" <<'PY'
import json, sys

path = sys.argv[1]
payload = {
    "agent_browser_version": sys.argv[2],
    "chrome_version": sys.argv[3],
    "agent_browser_sha256": sys.argv[4],
    "chrome_sha256": sys.argv[5],
    "arch": sys.argv[6],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

_browser_satisfy() {
  local deb_deps="$OPT/browser/chrome/$CHROME_DIR/deb.deps"
  [[ -f "$deb_deps" ]] || {
    log "browser: deb.deps missing at $deb_deps"
    return 1
  }
  local -a deps=()
  mapfile -t deps < <(grep -vE '^[[:space:]]*(#|$)' "$deb_deps" || true)
  if ((${#deps[@]})); then
    apt-get satisfy -y --no-install-recommends "${deps[@]}" >/dev/null
  fi
}

_browser_place_fixture() {
  local src="$CTX/guest/browser-fixture.html"
  [[ -n "$CTX" && -f "$src" ]] || {
    log "browser: fixture missing at $src"
    return 1
  }
  mkdir -p "$OPT/browser/fixtures"
  install -m 0644 "$src" "$OPT/browser/fixtures/smoke.html"
}

_browser_smoke() {
  local chrome="$OPT/bin/chrome"
  local cli="$OPT/bin/agent-browser"
  local fixture="$OPT/browser/fixtures/smoke.html"
  [[ -x "$chrome" && -x "$cli" && -f "$fixture" ]] || {
    log "browser smoke: chrome, agent-browser, or fixture missing"
    return 1
  }
  # Chrome 153 dump-dom never exits in Docker. Drive the same CDP path agents use.
  if ! timeout 45 "$cli" --executable-path "$chrome" --session tx9-browser-health \
    open "file://$(readlink -f "$fixture")"; then
    timeout 15 "$cli" --executable-path "$chrome" --session tx9-browser-health close >/dev/null 2>&1 || true
    log "browser smoke: launch failed"
    return 1
  fi
  local snap
  snap="$(timeout 30 "$cli" --executable-path "$chrome" --session tx9-browser-health snapshot || true)"
  timeout 15 "$cli" --executable-path "$chrome" --session tx9-browser-health close >/dev/null 2>&1 || true
  grep -q 'TX9_BROWSER_FIXTURE_OK' <<<"$snap" || {
    log "browser smoke: navigate failed"
    return 1
  }
}

_browser_download() {
  local url="$1" dest="$2" sha="$3"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 300 "$url" -o "$dest"
  printf '%s  %s\n' "$sha" "$dest" | sha256sum -c - >/dev/null
}

install_browser() {
  : "${AGENT_BROWSER_VERSION:?browser pins missing from box.env}"
  : "${CHROME_FOR_TESTING_VERSION:?browser pins missing from box.env}"
  _browser_arch
  mkdir -p "$OPT/browser/bin" "$OPT/browser/chrome" "$OPT/browser/fixtures" "$OPT/bin"
  apt-get install -y --no-install-recommends unzip libnss3-tools python3 >/dev/null

  if _browser_pins_match; then
    log "browser pins match, skipping download"
    _browser_link
    _browser_satisfy
    _browser_place_fixture
    _browser_smoke
    return 0
  fi

  local ab_url chrome_url stage
  ab_url="https://github.com/vercel-labs/agent-browser/releases/download/v${AGENT_BROWSER_VERSION}/${AB_ASSET}"
  chrome_url="https://storage.googleapis.com/chrome-for-testing-public/${CHROME_FOR_TESTING_VERSION}/${CHROME_PLATFORM}/${CHROME_DIR}.zip"

  log "browser (agent-browser ${AGENT_BROWSER_VERSION}, chrome ${CHROME_FOR_TESTING_VERSION}, ${MANIFEST_ARCH})"
  stage="$(mktemp -d /tmp/tx9-browser-stage-XXXXXX)"
  _browser_download "$ab_url" "$stage/$AB_ASSET" "$AB_SHA256"
  _browser_download "$chrome_url" "$stage/${CHROME_DIR}.zip" "$CHROME_SHA256"

  install -m 0755 "$stage/$AB_ASSET" "$OPT/browser/bin/agent-browser"
  rm -rf "$OPT/browser/chrome/$CHROME_DIR"
  unzip -q "$stage/${CHROME_DIR}.zip" -d "$OPT/browser/chrome"
  rm -rf "$stage"

  [[ -x "$OPT/browser/chrome/$CHROME_DIR/chrome" ]] || {
    log "browser: chrome binary missing after unpack ($CHROME_DIR)"
    return 1
  }

  _browser_link
  _browser_satisfy
  _browser_write_manifest
  _browser_place_fixture
  _browser_smoke
  log "browser installed -> $OPT/bin/agent-browser $OPT/bin/chrome"
}
