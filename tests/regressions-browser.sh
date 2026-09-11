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
session="default"
while [ $# -gt 0 ]; do
  case "$1" in
    --executable-path)
      exe="$2"
      shift 2
      ;;
    --session)
      session="$2"
      shift 2
      ;;
    --profile)
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
state="$state/$session"
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
    sleep 0.1
    if [ "${TX9_BROWSER_TEST_BAD_SNAPSHOT:-0}" = 1 ]; then
      echo TX9_BROWSER_FIXTURE_OK
      exit 1
    fi
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

TX9_BROWSER_TEST_BAD_SNAPSHOT=1 expect_code navigate_failed \
  --cli "$tmp/bin/cli" \
  --chrome "$tmp/bin/chrome-ok" \
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
python3 - "$tmp/seed-empty/config.yaml" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    assert yaml.safe_load(f) == {"browser": {"backend": "off", "cloud_provider": "local", "engine": "chrome"}}
PY

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
if ! kill -0 "$probe_pid" 2>/dev/null; then
  echo "cleanup killed another invocation's probe" >&2
  exit 1
fi

# Independent sessions must survive overlapping open/snapshot/close commands.
health --cli "$tmp/bin/cli" --chrome "$tmp/bin/chrome-ok" --ldd "$tmp/bin/ldd-ok" --fixture "$FIXTURE" >"$tmp/health-one" &
first=$!
pids+=("$first")
health --cli "$tmp/bin/cli" --chrome "$tmp/bin/chrome-ok" --ldd "$tmp/bin/ldd-ok" --fixture "$FIXTURE" >"$tmp/health-two" &
second=$!
pids+=("$second")
"$HELPER" versions >/dev/null
wait "$first"
wait "$second"
[[ "$(cat "$tmp/health-one")" == ok && "$(cat "$tmp/health-two")" == ok ]]

python3 - "$HELPER" "$tmp" <<'PY'
import os, pathlib, subprocess, sys, yaml

helper, root = sys.argv[1], pathlib.Path(sys.argv[2])
env_path = root / 'empty.env'
env_path.write_text('')
default = root / 'config.yaml'
default.write_text('model: keep-default\n')
custom = root / 'custom.yaml'
for before in (
    'browser: {backend: browser_use, engine: lightpanda}\n',
    '{browser: {backend: browserbase}}\n',
    'browser.backend: browser_use\n',
    'defaults: &chosen {engine: lightpanda}\nbrowser: *chosen\n',
):
    custom.write_text(before)
    proc = subprocess.run([helper, 'seed-config', '--config', str(custom), '--env', str(env_path)], capture_output=True, text=True)
    assert proc.returncode == 0 and proc.stdout.strip() == 'preserved', proc
    assert custom.read_text() == before

custom.write_text('model: keep-custom\nbrowser:\n  headless: true\n  timeout: 42\n')
custom.chmod(0o640)
proc = subprocess.run([helper, 'seed-config', '--config', str(custom), '--env', str(env_path)], capture_output=True, text=True)
assert proc.returncode == 0, proc
data = yaml.safe_load(custom.read_text())
assert data['model'] == 'keep-custom'
assert data['browser'] == dict(headless=True, timeout=42, backend='off', cloud_provider='local', engine='chrome')
assert custom.stat().st_mode & 0o777 == 0o640
assert default.read_text() == 'model: keep-default\n'
for before in ('browser: [invalid', '- not-a-mapping\n', 'browser: disabled\n'):
    custom.write_text(before)
    proc = subprocess.run([helper, 'seed-config', '--config', str(custom), '--env', str(env_path)], capture_output=True, text=True)
    assert proc.returncode != 0, proc
    assert custom.read_text() == before
for key, value in (('AGENT_BROWSER_ENGINE', 'lightpanda'), ('BROWSER_CDP_URL', 'http://127.0.0.1:9222'),
                   ('CAMOFOX_URL', 'http://127.0.0.1:9377')):
    for from_env_file in (False, True):
        custom.write_text('model: keep-custom\n')
        env_path.write_text(f'{key}={value}\n' if from_env_file else '')
        env = dict(os.environ)
        if not from_env_file:
            env[key] = value
        proc = subprocess.run([helper, 'seed-config', '--config', str(custom), '--env', str(env_path)],
                              env=env, capture_output=True, text=True)
        assert proc.returncode == 0 and proc.stdout.strip() == 'preserved', proc
        assert custom.read_text() == 'model: keep-custom\n'
PY

timeout --kill-after=2s 10 python3 - "$HELPER" "$tmp" <<'PY'
import importlib.machinery, importlib.util, pathlib, subprocess, sys, time

loader = importlib.machinery.SourceFileLoader('browser_timeout_test', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = module
loader.exec_module(module)
root = pathlib.Path(sys.argv[2])
pid_file = root / 'timeout-child.pid'
cli = root / 'wedged-cli'
cli.write_text('#!/usr/bin/env python3\nimport pathlib, signal, subprocess, sys, time\n'
               'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
               'child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])\n'
               f'pathlib.Path({str(pid_file)!r}).write_text(str(child.pid))\n'
               'time.sleep(60)\n')
cli.chmod(0o755)
paths = module.Paths(cli=cli, chrome=pathlib.Path('/bin/true'), ldd=None, fixture=root)
started = time.monotonic()
try:
    module._cli(paths, ['open'], timeout=0.5)
    raise AssertionError('wedged CLI unexpectedly returned')
except subprocess.TimeoutExpired:
    assert time.monotonic() - started < 3
finally:
    module.cleanup_probes()
    module.shutil.rmtree(module.PROBE_DIR, ignore_errors=True)
child_stat = pathlib.Path('/proc') / pid_file.read_text() / 'stat'
for _ in range(100):
    if not child_stat.exists() or child_stat.read_text().split(') ', 1)[1].startswith('Z '):
        break
    time.sleep(0.01)
else:
    raise AssertionError('timeout left a child process running')
PY

timeout --kill-after=2s 20 python3 - "$HELPER" "$tmp" "$PROJECT_ROOT" <<'PY'
import os, pathlib, signal, subprocess, sys, time

helper, root, project = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
cli = root / 'detached-cli'
cli.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
args = sys.argv[1:]
if 'open' in args:
    child = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pathlib.Path(os.environ['TX9_BROWSER_DAEMON_PID']).write_text(str(child.pid))
    if os.environ.get('TX9_BROWSER_TEST_WAIT') == '1':
        time.sleep(60)
elif 'snapshot' in args:
    print('TX9_BROWSER_FIXTURE_OK')
elif 'close' in args:
    sys.exit(1)
''')
cli.chmod(0o755)

def assert_stopped(pid):
    stat = pathlib.Path('/proc') / str(pid) / 'stat'
    for _ in range(100):
        if not stat.exists() or stat.read_text().split(') ', 1)[1].startswith('Z '):
            return
        time.sleep(0.01)
    raise AssertionError(f'detached probe daemon {pid} survived cleanup')

for interrupt in (False, True):
    pid_file = root / f'detached-{interrupt}.pid'
    env = dict(os.environ, TX9_BROWSER_DAEMON_PID=str(pid_file), TX9_BROWSER_TEST_WAIT=str(int(interrupt)))
    proc = subprocess.Popen([helper, 'health', '--cli', str(cli), '--chrome', '/bin/true',
                             '--ldd', str(root / 'bin/ldd-ok')], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    daemon = None
    try:
        for _ in range(200):
            if pid_file.exists() and pid_file.read_text():
                daemon = int(pid_file.read_text())
                break
            time.sleep(0.01)
        assert daemon is not None
        if interrupt:
            proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate(timeout=5)
        assert proc.returncode == (143 if interrupt else 0), (out, err)
        assert_stopped(daemon)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        if daemon:
            try: os.kill(daemon, signal.SIGKILL)
            except ProcessLookupError: pass

# The tools layer has its own smoke caller, which must also reap a failed-close daemon.
opt = root / 'smoke-opt'
(opt/'bin').mkdir(parents=True)
(opt/'browser/fixtures').mkdir(parents=True)
(opt/'bin/agent-browser').symlink_to(cli)
(opt/'bin/chrome').symlink_to('/bin/true')
(opt/'browser/fixtures/smoke.html').write_text('TX9_BROWSER_FIXTURE_OK')
pid_file = root/'smoke-daemon.pid'
env = dict(os.environ, OPT=str(opt), TX9_BROWSER_DAEMON_PID=str(pid_file))
try:
    proc = subprocess.run(['bash', '-c', 'source "$1/provision/install-browser.sh"; _browser_smoke',
                           'smoke-test', str(project)], env=env, capture_output=True, text=True, timeout=5)
    assert proc.returncode == 0, proc
    assert_stopped(int(pid_file.read_text()))
finally:
    if pid_file.exists():
        try: os.kill(int(pid_file.read_text()), signal.SIGKILL)
        except ProcessLookupError: pass
PY

echo "browser helper regression checks passed"
