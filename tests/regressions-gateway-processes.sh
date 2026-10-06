#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

timeout --kill-after=2s 30 python3 - "$PROJECT_ROOT" "$tmp" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

project, root = map(pathlib.Path, sys.argv[1:])
processes = []


def terminate(signum, frame):
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
modules = root / 'modules/hermes_cli'
modules.mkdir(parents=True)
(modules / '__init__.py').write_text('')
(modules / 'main.py').write_text('''import os, pathlib, time

def main():
    destination = pathlib.Path(os.environ['TEST_GATEWAY_PID'])
    pending = destination.with_name(f'{destination.name}.{os.getpid()}.tmp')
    pending.write_text(str(os.getpid()))
    pending.replace(destination)
    time.sleep(60)
''')
bootstrap = f'''import sys
sys.path.insert(0, {str(modules.parent)!r})
from hermes_cli.main import main
sys.exit(main())
'''
legacy = root / 'legacy/hermes'
legacy.parent.mkdir()
legacy.write_text('import time; time.sleep(60)\n')
launcher = root / 'bin/hermes'
launcher.parent.mkdir()
launcher.write_text(f'''#!/usr/bin/env python3
import os, sys
os.execv(sys.executable, [sys.executable, '-I', '-c', {bootstrap!r}, *sys.argv[1:]])
''')
launcher.chmod(0o700)
state = root / 'data/home/agent/.config/hermes-box'
# Run the real classifier, then scope fixture control operations to processes
# carrying this unique marker. Other same-UID gateways must remain untouched.
filter_script = root / 'filter-owned-pids.py'
filter_script.write_text('''import os, pathlib, sys
expected = os.fsencode('TEST_GATEWAY_PID=' + os.environ['TEST_GATEWAY_PID'])
for line in sys.stdin:
    pid = line.strip()
    try:
        environment = (pathlib.Path('/proc') / pid / 'environ').read_bytes().split(b'\\0')
    except OSError:
        continue
    if expected in environment:
        print(pid)
''')
env = dict(os.environ, HB_DATA=str(root / 'data'), INSTALL_HERMES='1',
           TEST_GATEWAY_PID=str(root / 'gateway.pid'), TEST_GATEWAY_FILTER=str(filter_script),
           TEST_GATEWAY_OWNER=str(root),
           PATH=f'{launcher.parent}:{os.environ["PATH"]}')


def spawn(argv, process_env=None):
    proc = subprocess.Popen(argv, env=env if process_env is None else process_env, start_new_session=True,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    processes.append(proc)
    return proc


def hb(body):
    setup = '''source "$1/guest/hb";
eval "$(declare -f _gateway_process_pids | sed '1s/_gateway_process_pids/_fixture_gateway_process_pids/')";
_gateway_process_pids() { _fixture_gateway_process_pids "$1" | python3 "$TEST_GATEWAY_FILTER"; };
'''
    result = subprocess.run(['bash', '-c', setup + body,
                             'gateway-test', str(project)], env=env,
                            capture_output=True, text=True, timeout=8)
    assert result.returncode == 0, (body, result.stdout, result.stderr)
    return result.stdout.strip()


def poll(predicate):
    for _ in range(100):
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError('process fixture did not reach expected state')


def finish(proc):
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
    proc.wait(timeout=3)


def cleanup_owned():
    # Discovery excludes the sentinel; cleanup owns it too, even if a signal
    # arrives after spawn but before its Popen is appended to `processes`.
    expected = os.fsencode('TEST_GATEWAY_OWNER=' + env['TEST_GATEWAY_OWNER'])
    for _ in range(10):
        found = False
        for entry in pathlib.Path('/proc').iterdir():
            if not entry.name.isdecimal() or int(entry.name) == os.getpid():
                continue
            try:
                pidfd = os.pidfd_open(int(entry.name))
            except ProcessLookupError:
                continue
            try:
                if entry.stat().st_uid != os.geteuid():
                    continue
                try:
                    environment = (entry / 'environ').read_bytes().split(b'\0')
                except OSError:
                    continue
                if expected not in environment:
                    continue
                # The pidfd pins this process identity while ownership is
                # checked, so a recycled numeric PID cannot receive the kill.
                signal.pidfd_send_signal(pidfd, signal.SIGKILL)
                found = True
            except (FileNotFoundError, ProcessLookupError):
                continue
            finally:
                os.close(pidfd)
        if not found:
            return
        time.sleep(0.02)  # Rescan children forked while their wrapper stopped.
    raise AssertionError('fixture-owned processes survived cleanup')


try:
    # An independent same-user gateway is visible to production discovery but
    # outside this fixture's ownership. Every test stop must preserve it.
    sentinel_env = dict(env)
    del sentinel_env['TEST_GATEWAY_PID']
    sentinel = spawn([sys.executable, str(legacy), 'gateway', 'run'], sentinel_env)
    raw = subprocess.run(['bash', '-c', 'source "$1/guest/hb"; _gateway_pids',
                          'gateway-test', str(project)], env=env,
                         capture_output=True, text=True, timeout=8)
    assert raw.returncode == 0 and str(sentinel.pid) in raw.stdout.splitlines()

    # Literal mentions, exec shims, and unrelated gateway argv are not children
    # or capture supervisors, even when flattened ps output looks plausible.
    decoys = [
        [sys.executable, '-I', '-c', "import time; marker='from hermes_cli.main import main'; time.sleep(60)", 'gateway', 'run'],
        [sys.executable, '-I', '-c', "import time; from math import cos as main; time.sleep(60); main()", 'gateway', 'run'],
        [sys.executable, '-c', "import os,sys,time; time.sleep(60); os.execvp(sys.argv[1], sys.argv[1:])", 'hermes', 'gateway', 'run'],
        [sys.executable, '-c', 'import time; time.sleep(60)', '/opt/bin/tx9-logs', 'capture', '--source', 'hermes', '--', 'hermes', 'gateway', 'run'],
        [sys.executable, '-I', '-c', bootstrap, 'gateway', 'status'],
    ]
    prefix = f"import sys, time; sys.path.insert(0, {str(modules.parent)!r}); from hermes_cli.main import main; "
    for overwrite in ("main = lambda: None", "del main", "from math import cos as main"):
        decoys.append([sys.executable, '-I', '-c', prefix + overwrite + '; time.sleep(60); sys.exit(main())', 'gateway', 'run'])
    decoys.append([sys.executable, '-I', '-c', prefix + '\ndef main(): time.sleep(60)\nsys.exit(main())', 'gateway', 'run'])
    unrelated = [spawn(argv) for argv in decoys]
    assert hb('_gateway_pids') == ''
    assert hb('_gateway_capture_pids') == ''
    hb('! _gateway_running')

    # Both legacy interpreter/script forms and global Hermes options survive.
    for flags in ([], ['-u'], ['-I'], ['-uB'], ['-W', 'ignore'], ['-X', 'dev'], ['--']):
        proc = spawn([sys.executable, *flags, str(legacy), '--home', str(root), 'gateway', 'run'])
        poll(lambda: hb('_gateway_pids') == str(proc.pid))
        hb('_signal_gateway TERM')
        proc.wait(timeout=3)
        assert proc.returncode == -signal.SIGTERM

    # The actual PM argv form counts as the child, passes the doctor's process
    # check, and is adopted by startup rather than launching a second writer.
    proc = spawn([sys.executable, '-I', '-c', bootstrap, 'gateway', 'run', '--replace', '--external-supervisor'])
    poll(lambda: hb('_gateway_pids') == str(proc.pid))
    hb('_check "Hermes gateway process" _gateway_running')
    hb('init; rm -f "$GATEWAY_DISABLED"; _start_gateway')
    assert (state / 'gateway.pid').read_text().strip() == str(proc.pid)
    hb('gateway_disable')
    proc.wait(timeout=3)
    assert (state / 'gateway-disabled').exists()
    assert hb('_gateway_pids') == ''
    assert all(decoy.poll() is None for decoy in unrelated)

    # A real capture owns/restarts the PM child. Stop reaches both identities
    # and leaves no supervisor to resurrect it.
    pid_file = pathlib.Path(env['TEST_GATEWAY_PID'])
    pid_file.unlink(missing_ok=True)
    wrapper = spawn([str(project / 'guest/tx9-logs'), 'capture', '--source', 'hermes',
                     '--log-dir', str(root / 'logs'), '--restart-delay', '0.1', '--',
                     str(launcher), 'gateway', 'run', '--replace', '--external-supervisor'])
    poll(lambda: pid_file.exists())
    child = int(pid_file.read_text())
    poll(lambda: hb('_gateway_pids') == str(child))
    assert hb('_gateway_capture_pids') == str(wrapper.pid)
    hb('_stop_gateway')
    wrapper.wait(timeout=3)
    time.sleep(0.3)
    assert hb('_gateway_pids') == ''
    assert hb('_gateway_capture_pids') == ''

    # A wrapper by itself does not satisfy health. This small capture-shaped
    # fixture can also disappear without taking its isolated child with it.
    capture = root / 'tx9-logs'
    capture.write_text(f'''import subprocess, sys, time
if '--launch-child' in sys.argv:
    subprocess.Popen([sys.executable, '-I', '-c', {bootstrap!r}, 'gateway', 'run'], start_new_session=True)
time.sleep(60)
''')
    args = [sys.executable, str(capture), 'capture', '--source', 'hermes', '--', 'hermes', 'gateway', 'run']
    wrapper_only = spawn(args)
    poll(lambda: hb('_gateway_capture_pids') == str(wrapper_only.pid))
    hb('! _gateway_running')
    finish(wrapper_only)
    pid_file.unlink(missing_ok=True)
    orphan_wrapper = spawn([*args, '--launch-child'])
    poll(lambda: pid_file.exists())
    orphan = int(pid_file.read_text())
    orphan_wrapper.kill()
    orphan_wrapper.wait(timeout=3)
    poll(lambda: hb('_gateway_pids') == str(orphan))
    hb('_stop_gateway')
    assert hb('_gateway_pids') == ''
    assert hb('_gateway_capture_pids') == ''
    assert all(decoy.poll() is None for decoy in unrelated)
    assert sentinel.poll() is None
finally:
    try:
        # Detached children can exist before their PID is published or read.
        # Clean every inherited owner marker without relying on `orphan`
        # or on a Popen having already been appended to `processes`.
        cleanup_owned()
    finally:
        for proc in processes:
            try:
                finish(proc)
            except ProcessLookupError:
                pass

PY

echo "gateway process regression checks passed"
