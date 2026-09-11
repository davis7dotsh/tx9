#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HELPER="$PROJECT_ROOT/guest/tx9-browser"
FIXTURE="$PROJECT_ROOT/provision/browser-fixture.html"
export TX9_BROWSER_TEST_STATE="$tmp/cli-state"
mkdir -p "$tmp/bin" "$TX9_BROWSER_TEST_STATE"

cat >"$tmp/bin/cli" <<'EOF'
#!/bin/sh
exe=""
while [ $# -gt 0 ]; do
  case "$1" in
    --executable-path)
      exe="$2"
      shift 2
      ;;
    --session)
      shift 2
      ;;
    --*)
      shift
      ;;
    *)
      break
      ;;
  esac
done
cmd="${1:-}"
[ $# -gt 0 ] && shift
state="${TX9_BROWSER_TEST_STATE:-${TMPDIR:-/tmp}/tx9-browser-cli-state}"
mkdir -p "$state"
case "$cmd" in
  open)
    if [ -z "$exe" ] || [ ! -x "$exe" ]; then
      echo "chrome missing" >&2
      exit 1
    fi
    html="$("$exe" --headless=new --dump-dom --user-data-dir="$state/ud" "${1:-}")" || exit 1
    printf '%s\n' "$html" >"$state/last.html"
    echo "✓ opened"
    ;;
  snapshot)
    if [ ! -f "$state/last.html" ]; then
      echo "no page" >&2
      exit 1
    fi
    cat "$state/last.html"
    ;;
  close)
    rm -f "$state/last.html"
    exit 0
    ;;
  *)
    echo 'agent-browser 0.26.0'
    ;;
esac
EOF

cat >"$tmp/bin/ldd-ok" <<'EOF'
#!/bin/sh
echo 'libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x000000000000)'
EOF

cat >"$tmp/bin/ldd-missing" <<'EOF'
#!/bin/sh
echo 'libfoo.so.1 => not found'
EOF

cat >"$tmp/bin/chrome-ok" <<'EOF'
#!/bin/sh
dump=0
headless=0
for arg in "$@"; do
  case "$arg" in
    --dump-dom) dump=1 ;;
    --headless=new) headless=1 ;;
  esac
done
if [ "$dump" -eq 1 ] && [ "$headless" -eq 1 ]; then
  printf '<!DOCTYPE html><html><body>TX9_BROWSER_FIXTURE_OK</body></html>\n'
  exit 0
fi
exit 1
EOF

cat >"$tmp/bin/chrome-version-only" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo 'Chrome 153.0.8010.36'
  exit 0
fi
exit 1
EOF

cat >"$tmp/bin/chrome-launch-fail" <<'EOF'
#!/bin/sh
echo 'chrome failed to start' >&2
exit 1
EOF

cat >"$tmp/bin/chrome-navigate-fail" <<'EOF'
#!/bin/sh
printf '<!DOCTYPE html><html><body>wrong page</body></html>\n'
exit 0
EOF

cat >"$tmp/bin/chrome-launch-log" <<'EOF'
#!/bin/sh
echo "launched" >>"${TX9_BROWSER_TEST_LAUNCH_LOG:-/dev/null}"
printf '<!DOCTYPE html><html><body>TX9_BROWSER_FIXTURE_OK</body></html>\n'
EOF

chmod 0755 "$tmp/bin/"*

health() {
  "$HELPER" health "$@"
}

expect_code() {
  local want="$1"
  shift
  local got rc=0
  got="$(health "$@")" || rc=$?
  if [[ "$got" != "$want" ]]; then
    echo "health code: want $want, got $got ($*)" >&2
    exit 1
  fi
  if [[ "$want" == "ok" && "$rc" -ne 0 ]]; then
    echo "health exited $rc for ok ($*)" >&2
    exit 1
  fi
  if [[ "$want" != "ok" && "$rc" -eq 0 ]]; then
    echo "health exited 0 for $want ($*)" >&2
    exit 1
  fi
}

expect_code cli_missing \
  --cli "$tmp/missing-cli" \
  --chrome "$tmp/bin/chrome-ok" \
  --ldd "$tmp/bin/ldd-ok" \
  --fixture "$FIXTURE"

expect_code browser_missing \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/missing-chrome" \
  --ldd "$tmp/bin/ldd-ok" \
  --fixture "$FIXTURE"

rm -f "$tmp/chrome-launched"
TX9_BROWSER_TEST_LAUNCH_LOG="$tmp/chrome-launched" expect_code libs_missing \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/bin/chrome-ok" \
  --ldd "$tmp/missing-ldd" \
  --fixture "$FIXTURE"

expect_code libs_missing \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/bin/chrome-launch-log" \
  --ldd "$tmp/bin/ldd-missing" \
  --fixture "$FIXTURE"
if [[ -e "$tmp/chrome-launched" ]]; then
  echo "libs_missing launched chrome" >&2
  exit 1
fi

expect_code launch_failed \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/bin/chrome-launch-fail" \
  --ldd "$tmp/bin/ldd-ok" \
  --fixture "$FIXTURE"

expect_code launch_failed \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/bin/chrome-version-only" \
  --ldd "$tmp/bin/ldd-ok" \
  --fixture "$FIXTURE"

expect_code navigate_failed \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/bin/chrome-navigate-fail" \
  --ldd "$tmp/bin/ldd-ok" \
  --fixture "$FIXTURE"

expect_code ok \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/bin/chrome-ok" \
  --ldd "$tmp/bin/ldd-ok" \
  --fixture "$FIXTURE"

if ! "$HELPER" verify \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/bin/chrome-ok" \
  --ldd "$tmp/bin/ldd-ok" \
  --fixture "$FIXTURE"; then
  echo "verify exited non-zero for ok health" >&2
  exit 1
fi
if "$HELPER" verify \
  --cli "$tmp/missing-cli" \
  --chrome "$tmp/bin/chrome-ok" \
  --ldd "$tmp/bin/ldd-ok" \
  --fixture "$FIXTURE"; then
  echo "verify exited 0 for cli_missing" >&2
  exit 1
fi

json="$("$HELPER" health --json \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/bin/chrome-ok" \
  --ldd "$tmp/bin/ldd-ok" \
  --fixture "$FIXTURE")"
[[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["code"])' <<<"$json")" == "ok" ]]

# seed-config: empty files receive the local chrome seed exactly.
mkdir -p "$tmp/seed-empty"
: >"$tmp/seed-empty/config.yaml"
: >"$tmp/seed-empty/.env"
seeded="$("$HELPER" seed-config --config "$tmp/seed-empty/config.yaml" --env "$tmp/seed-empty/.env")"
[[ "$seeded" == "seeded" ]]
diff -u - "$tmp/seed-empty/config.yaml" <<'EOF'
browser:
  backend: "off"
  cloud_provider: local
  engine: chrome
EOF

# Existing backend is already selected and must be preserved.
mkdir -p "$tmp/seed-backend"
printf 'browser:\n  backend: browser_use\n' >"$tmp/seed-backend/config.yaml"
: >"$tmp/seed-backend/.env"
[[ "$("$HELPER" seed-config --config "$tmp/seed-backend/config.yaml" --env "$tmp/seed-backend/.env")" == "preserved" ]]
diff -u - "$tmp/seed-backend/config.yaml" <<'EOF'
browser:
  backend: browser_use
EOF

# A cloud key in .env means a backend was already chosen.
mkdir -p "$tmp/seed-env"
printf 'BROWSER_USE_API_KEY=sk-test\n' >"$tmp/seed-env/.env"
[[ "$("$HELPER" seed-config --config "$tmp/seed-env/config.yaml" --env "$tmp/seed-env/.env")" == "preserved" ]]
[[ ! -e "$tmp/seed-env/config.yaml" ]]

# Existing cloud_provider is already selected and must be preserved.
mkdir -p "$tmp/seed-provider"
printf 'browser:\n  cloud_provider: browserbase\n' >"$tmp/seed-provider/config.yaml"
: >"$tmp/seed-provider/.env"
[[ "$("$HELPER" seed-config --config "$tmp/seed-provider/config.yaml" --env "$tmp/seed-provider/.env")" == "preserved" ]]
diff -u - "$tmp/seed-provider/config.yaml" <<'EOF'
browser:
  cloud_provider: browserbase
EOF

mkdir -p "$tmp/seed-cdp"
printf 'browser:\n  cdp_url: http://127.0.0.1:9222\n' >"$tmp/seed-cdp/config.yaml"
: >"$tmp/seed-cdp/.env"
[[ "$("$HELPER" seed-config --config "$tmp/seed-cdp/config.yaml" --env "$tmp/seed-cdp/.env")" == "preserved" ]]

mkdir -p "$tmp/seed-engine"
printf 'browser:\n  engine: lightpanda\n' >"$tmp/seed-engine/config.yaml"
: >"$tmp/seed-engine/.env"
[[ "$("$HELPER" seed-config --config "$tmp/seed-engine/config.yaml" --env "$tmp/seed-engine/.env")" == "preserved" ]]

mkdir -p "$tmp/seed-browserbase"
printf 'BROWSERBASE_API_KEY=sk-test\n' >"$tmp/seed-browserbase/.env"
[[ "$("$HELPER" seed-config --config "$tmp/seed-browserbase/config.yaml" --env "$tmp/seed-browserbase/.env")" == "preserved" ]]
[[ ! -e "$tmp/seed-browserbase/config.yaml" ]]

mkdir -p "$tmp/seed-firecrawl"
printf 'FIRECRAWL_API_KEY=sk-test\n' >"$tmp/seed-firecrawl/.env"
[[ "$("$HELPER" seed-config --config "$tmp/seed-firecrawl/config.yaml" --env "$tmp/seed-firecrawl/.env")" == "preserved" ]]
[[ ! -e "$tmp/seed-firecrawl/config.yaml" ]]

cp /bin/sleep "$tmp/tx9-browser-probe-sleep"
"$tmp/tx9-browser-probe-sleep" 60 &
probe_pid=$!
pids+=("$probe_pid")
"$HELPER" cleanup
if kill -0 "$probe_pid" 2>/dev/null; then
  echo "cleanup left a tx9-browser-probe process running" >&2
  exit 1
fi

echo "browser helper regression checks passed"
