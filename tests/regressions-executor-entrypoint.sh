#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Exercise the complete entrypoint in a temporary filesystem. Only account
# switching and ownership changes are stubbed. The real capture helper runs.
python3 - "$PROJECT_ROOT" "$tmp" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

project, root = map(Path, sys.argv[1:])
bin_dir = root / "bin"
bin_dir.mkdir()

def executable(name, text):
    path = bin_dir / name
    path.write_text(text)
    path.chmod(0o700)
    return path

executable("chown", "#!/usr/bin/env bash\nexit 0\n")
executable("runuser", '''#!/usr/bin/env bash
[[ "$1" == -u && "$2" == agent && "$3" == -- ]] || exit 1
shift 3
exec "$@"
''')
capture = executable("capture", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ["ARGV_ROOT"], "capture.json").write_text(json.dumps(sys.argv[1:]))
os.execv(sys.executable, [sys.executable, os.environ["REAL_CAPTURE"], *sys.argv[1:]])
''')
executable("executor", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ["ARGV_ROOT"], "executor.json").write_text(json.dumps(sys.argv[1:]))
data = Path(os.environ.get("EXECUTOR_DATA_DIR", str(Path.home() / ".executor")))
token = json.loads((data / "server-control" / "auth.json").read_text())["token"]
assert token == os.environ["EXPECTED_TOKEN"] == os.environ["EXECUTOR_MCP_TOKEN"]
print("credential fixture " + token)
''')
profile = root / "profile.sh"
profile.write_text("export EXECUTOR_MCP_TOKEN=stale-profile-fixture\n")
source = (project / "docker" / "executor-entrypoint.sh").read_text()

for label in ("default", "custom"):
    fixture = root / label
    home = fixture / "home"
    logs = fixture / "logs"
    home.mkdir(parents=True)
    data = home / ".executor" if label == "default" else fixture / "custom data"
    control = data / "server-control"
    control.mkdir(parents=True)
    control.chmod(0o755)
    outside = fixture / "outside.json"
    outside.write_text("unchanged fixture\n")
    auth = control / "auth.json"
    auth.symlink_to(outside)
    entrypoint = fixture / "entrypoint.sh"
    entrypoint.write_text(
        source.replace("/data/home/agent", str(home))
        .replace("/data/logs", str(logs))
        .replace("/etc/profile.d/hermes-box.sh", str(profile))
        .replace("/opt/hermes-box/bin/tx9-logs", str(capture))
    )
    environment = dict(os.environ)
    environment.pop("EXECUTOR_DATA_DIR", None)
    environment.update({
        "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
        "ARGV_ROOT": str(fixture),
        "REAL_CAPTURE": str(project / "guest" / "tx9-logs"),
    })
    if label == "custom":
        environment["EXECUTOR_DATA_DIR"] = str(data)
    for token in ("entrypoint-first-fixture-token", "entrypoint-rotated-fixture-token"):
        environment.update(EXECUTOR_MCP_TOKEN=token, EXPECTED_TOKEN=token)
        result = subprocess.run(
            ["bash", str(entrypoint)], env=environment, capture_output=True,
            text=True, timeout=5, check=True,
        )
        assert token not in result.stdout + result.stderr
        assert "[REDACTED]" in result.stdout
        assert json.loads(auth.read_text()) == {"token": token}
        assert not auth.is_symlink()
        assert auth.stat().st_mode & 0o777 == 0o600
        assert control.stat().st_mode & 0o777 == 0o700
        assert outside.read_text() == "unchanged fixture\n"
        assert list(control.glob(".auth-*")) == []
        for name in ("capture.json", "executor.json"):
            arguments = json.loads((fixture / name).read_text())
            assert token not in " ".join(arguments)
            assert "--auth-token" not in arguments
        assert json.loads((fixture / "executor.json").read_text()) == [
            "daemon", "run", "--foreground", "--hostname", "0.0.0.0", "--port", "4788",
        ]
        assert token not in (logs / "executor.log").read_text()
        assert token not in (logs / "executor.jsonl").read_text()

    environment.pop("EXECUTOR_MCP_TOKEN")
    rejected = subprocess.run(
        ["bash", str(entrypoint)], env=environment, capture_output=True, text=True, timeout=5,
    )
    assert rejected.returncode != 0
    assert "EXECUTOR_MCP_TOKEN is required" in rejected.stderr
PY

echo "Executor entrypoint regression checks passed"
