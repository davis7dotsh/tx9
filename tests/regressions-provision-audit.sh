#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

python3 - "$PROJECT_ROOT" "$tmp" <<'PY'
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys

project, root = map(Path, sys.argv[1:])

def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o700)

# A surviving global launcher is not evidence of a usable Executor install.
# Exercise the real installer function without touching host accounts/tools.
fixture = root / "executor"
bin_dir = fixture / "bin"
executable(bin_dir / "executor", '''#!/usr/bin/env bash
printf '%s\n' "$PROBE_OUTPUT"
exit "$PROBE_STATUS"
''')
executable(bin_dir / "chown", "#!/usr/bin/env bash\nexit 0\n")
executable(fixture / "vite/bin/vp", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ["INSTALL_RECORD"]).write_text(json.dumps(sys.argv[1:]))
sys.exit(int(os.environ.get("INSTALL_STATUS", "0")))
''')
record = fixture / "installed.json"
install_command = '''
source "$1/provision/provision.sh"
export PATH="$2/bin:$PATH" VP_HOME="$2/vite"
INSTALL_EXECUTOR=1
EXECUTOR_VERSION="$3"
install_executor
'''
for output, status, pin, expected in (
    ("Executor 1.6.0", 0, "", None),
    ("Executor 1.6.0", 0, "1.6.0", None),
    ("Executor 1.5.28", 0, "1.6.0", "executor@1.6.0"),
    ("", 1, "1.6.0", "executor@1.6.0"),
    ("", 0, "1.6.0", "executor@1.6.0"),
    ("runtime missing", 1, "", "executor"),
    ("Executor 1.6.0\nfailed runtime", 1, "1.6.0", "executor@1.6.0"),
    ("Executor 1.6.0\nNode.js 24.0.0", 0, "1.6.0", None),
):
    record.unlink(missing_ok=True)
    env = dict(os.environ, PROBE_OUTPUT=output, PROBE_STATUS=str(status), INSTALL_RECORD=str(record))
    result = subprocess.run(["bash", "-c", install_command, "fixture", str(project), str(fixture), pin],
                            env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result
    if expected is None:
        assert not record.exists(), result
    else:
        assert json.loads(record.read_text()) == ["install", "-g", expected], result
failed = subprocess.run(["bash", "-c", install_command, "fixture", str(project), str(fixture), "1.6.0"],
                        env=dict(os.environ, PROBE_OUTPUT="", PROBE_STATUS="1", INSTALL_RECORD=str(record),
                                 INSTALL_STATUS="1"), capture_output=True, text=True, timeout=15)
assert failed.returncode != 0 and "executor install FAILED" in failed.stdout, failed

# Pin and checksum the upstream installer before it can run, and force the
# matching source checkout. The fixture installer uses the preserved FHS/venv
# contract; no host locations or account changes are involved.
fixture = root / "hermes"
bin_dir = fixture / "bin"
repo = fixture / "repo"
(repo / "provision").mkdir(parents=True)
(repo / "box.env").write_bytes((project / "box.env").read_bytes())
(repo / "provision/install-browser.sh").write_bytes((project / "provision/install-browser.sh").read_bytes())
install_dir = fixture / "lib/hermes-agent"
launcher = bin_dir / "hermes"
state = fixture / "state"
source = (project / "provision/provision.sh").read_text()
(repo / "provision/provision.sh").write_text(
    source.replace("/usr/local/lib/hermes-agent", str(install_dir))
    .replace("/usr/local/bin/hermes", str(launcher))
    .replace("/data/home/agent/.hermes", str(state))
)
executable(bin_dir / "chown", "#!/usr/bin/env bash\nexit 0\n")
executable(bin_dir / "curl", r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
arguments = sys.argv[1:]
Path(os.environ["CURL_RECORD"]).write_text(json.dumps(arguments))
shutil.copyfile(os.environ["INSTALLER_FIXTURE"], arguments[arguments.index("-o") + 1])
sys.exit(int(os.environ["CURL_STATUS"]))
''')
executable(fixture / "uv/uv", r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ["UV_RECORD"]).write_text(json.dumps(sys.argv[1:]))
''')
installer = fixture / "installer.sh"
executable(installer, r'''#!/usr/bin/env bash
python3 - "$@" <<'FAKE_INSTALL'
import json, os, sys
from pathlib import Path
assert "HERMES_INSTALL_DIR" not in os.environ
Path(os.environ["INSTALL_RECORD"]).write_text(json.dumps(sys.argv[1:]))
if os.environ["INSTALL_STATUS"] != "0":
    sys.exit(int(os.environ["INSTALL_STATUS"]))
python = Path(os.environ["HERMES_FIXTURE_DIR"]) / "venv/bin/python"
python.parent.mkdir(parents=True, exist_ok=True)
python.write_text("#!/usr/bin/env bash\nexit 0\n")
python.chmod(0o700)
launcher = Path(os.environ["HERMES_FIXTURE_LAUNCHER"])
launcher.write_text("#!/usr/bin/env bash\nexit 0\n")
launcher.chmod(0o700)
FAKE_INSTALL
''')
digest = hashlib.sha256(installer.read_bytes()).hexdigest()
pin = re.search(r'^HERMES_INSTALL_COMMIT="([0-9a-f]{40})"$', (repo / "box.env").read_text(), re.MULTILINE).group(1)
record = fixture / "installed.json"
curl_record = fixture / "download.json"
uv_record = fixture / "uv.json"
install_command = '''
source "$1/provision/provision.sh"
export PATH="$2/bin:$PATH"
OPT="$2/opt"
UV_DIR="$2/uv"
mkdir -p "$OPT/bin"
INSTALL_HERMES=1
HERMES_INSTALL_ARGS="$3"
HERMES_INSTALLER_SHA256="$4"
own_agent_tree() { chown agent:agent "$1"; }
install_hermes
'''
env = dict(os.environ, INSTALLER_FIXTURE=str(installer), CURL_RECORD=str(curl_record),
           INSTALL_RECORD=str(record), UV_RECORD=str(uv_record),
           HERMES_FIXTURE_DIR=str(install_dir), HERMES_FIXTURE_LAUNCHER=str(launcher),
           HERMES_INSTALL_DIR="inherited-layout-must-not-win", CURL_STATUS="0", INSTALL_STATUS="0")
for argument in ("--dir=/tmp/unmanaged", "--hermes-home=/tmp/unmanaged", "--commit=deadbeef", "--branch=main",
                 "--force-commit", "--no-venv", "--stage=path", "--manifest", "--ensure-deps=messaging", "-Commit"):
    rejected = subprocess.run(["bash", "-c", install_command, "fixture", str(repo), str(fixture), argument, digest],
                              env=env, capture_output=True, text=True, timeout=15)
    assert rejected.returncode != 0 and "protected installer option" in rejected.stdout, rejected
    assert not curl_record.exists() and not record.exists()
for label, checksum, curl_status, install_status in (
    ("checksum", "0" * 64, "0", "0"),
    ("network", digest, "22", "0"),
    ("installer", digest, "0", "1"),
    ("success", digest, "0", "0"),
):
    record.unlink(missing_ok=True)
    result = subprocess.run(["bash", "-c", install_command, "fixture", str(repo), str(fixture),
                             "--skip-browser", checksum],
                            env=dict(env, CURL_STATUS=curl_status, INSTALL_STATUS=install_status),
                            capture_output=True, text=True, timeout=15)
    download = json.loads(curl_record.read_text())
    assert f"https://raw.githubusercontent.com/NousResearch/hermes-agent/{pin}/scripts/install.sh" in download
    assert not Path(download[download.index("-o") + 1]).exists(), result
    if label == "success":
        assert result.returncode == 0, result
        assert json.loads(record.read_text()) == [
            "--skip-browser", "--commit", pin, "--force-commit",
            "--hermes-home", str(state), "--skip-setup", "--non-interactive",
        ]
        assert json.loads(uv_record.read_text()) == ["pip", "install", "--python", "venv/bin/python", "-e", ".[messaging]"]
    else:
        assert result.returncode != 0, result
        assert not launcher.exists()
        if label in ("checksum", "network"):
            assert not record.exists(), result
# Re-running assets must retain a working existing version, even if the fresh
# install pin would otherwise fail its checksum.
record.unlink()
curl_record.unlink()
result = subprocess.run(["bash", "-c", install_command, "fixture", str(repo), str(fixture), "--skip-browser", "0" * 64],
                        env=env, capture_output=True, text=True, timeout=15)
assert result.returncode == 0 and "already installed" in result.stdout, result
assert not record.exists() and not curl_record.exists()

# Run the complete browser install with staged executable candidates and
# controlled apt/archive responses. The real smoke test launches the staged
# browser and checks its snapshot before installed binaries can be replaced.
fixture = root / "browser"
bin_dir = fixture / "bin"
opt = fixture / "opt"
ctx = fixture / "ctx"
(ctx / "provision").mkdir(parents=True)
(ctx / "provision/browser-fixture.html").write_text("TX9_BROWSER_FIXTURE_OK\n")
executable(bin_dir / "apt-get", '''#!/usr/bin/env bash
[[ "$1" != satisfy || "$FAIL_DEPS" != 1 ]]
''')
executable(bin_dir / "unzip", r'''#!/usr/bin/env python3
import os, sys
from pathlib import Path
stage = Path(sys.argv[-1])
chrome = stage / "chrome-linux64"
chrome.mkdir()
(chrome / "chrome").write_text('#!/usr/bin/env bash\nprintf "candidate Chrome\\n"\n')
(chrome / "chrome").chmod(0o700)
(chrome / "deb.deps").write_text('libc6\n')
''')
candidate = fixture / "candidate-agent-browser"
executable(candidate, '''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if "open" in args:
    chrome = args[args.index("--executable-path") + 1]
    assert "/.stage-" in chrome, chrome
    result = subprocess.run([chrome], capture_output=True, text=True, check=True)
    assert result.stdout.strip() == "candidate Chrome", result
    sys.exit(1 if os.environ["FAIL_SMOKE"] == "1" else 0)
elif "snapshot" in args:
    print("TX9_BROWSER_FIXTURE_OK")
''')
install_command = '''
source "$1/provision/install-browser.sh"
_browser_arch() {
  AB_ASSET=agent-browser-linux-x64
  AB_SHA256=fixture-agent-digest
  CHROME_PLATFORM=linux64
  CHROME_DIR=chrome-linux64
  CHROME_SHA256=fixture-chrome-digest
  MANIFEST_ARCH=linux-x64
}
_browser_download() {
  if [[ "$1" == */agent-browser-linux-x64 ]]; then
    cp "$CANDIDATE_CLI" "$2"
  else
    : >"$2"
  fi
}
# Keep every symlink inside the fixture; real linking also publishes /usr/bin.
_browser_link() {
  ln -sfn ../browser/bin/agent-browser "$OPT/bin/agent-browser"
  ln -sfn ../browser/chrome/chrome-linux64/chrome "$OPT/bin/chrome"
}
install_browser
'''
old_cli = opt / "browser/bin/agent-browser"
old_chrome = opt / "browser/chrome/chrome-linux64/chrome"
manifest = opt / "browser/manifest.json"
for fail_deps, fail_smoke in (("1", "0"), ("0", "1"), ("0", "0")):
    executable(old_cli, "#!/usr/bin/env bash\nprintf 'previous CLI\\n'\n")
    executable(old_chrome, "#!/usr/bin/env bash\nprintf 'previous Chrome\\n'\n")
    (old_chrome.parent / "deb.deps").write_text("libc6\n")
    manifest.write_text('{"previous": true}\n')
    before = {path: path.read_bytes() for path in (old_cli, old_chrome, manifest)}
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
               OPT=str(opt), CTX=str(ctx), CANDIDATE_CLI=str(candidate),
               AGENT_BROWSER_VERSION="fixture-new-cli", CHROME_FOR_TESTING_VERSION="fixture-new-chrome",
               FAIL_DEPS=fail_deps, FAIL_SMOKE=fail_smoke)
    result = subprocess.run(["bash", "-c", install_command, "fixture", str(project)], env=env,
                            capture_output=True, text=True, timeout=15)
    assert not list((opt / "browser").glob(".stage-*")), result
    if fail_deps == "1" or fail_smoke == "1":
        assert result.returncode != 0, result
        assert all(path.read_bytes() == contents for path, contents in before.items()), result
    else:
        assert result.returncode == 0, result
        assert old_cli.read_bytes() == candidate.read_bytes()
        assert b"candidate Chrome" in old_chrome.read_bytes()
        assert json.loads(manifest.read_text())["chrome_version"] == "fixture-new-chrome"
        assert (opt / "bin/agent-browser").resolve() == old_cli
        assert (opt / "bin/chrome").resolve() == old_chrome
        assert (opt / "browser/fixtures/smoke.html").read_bytes() == (ctx / "provision/browser-fixture.html").read_bytes()
PY

echo 'provisioning recovery regression checks passed'
