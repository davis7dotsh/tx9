#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

python3 - "$PROJECT_ROOT" "$tmp" <<'PY'
import os
import pathlib
import subprocess
import sys

root, fixture = map(pathlib.Path, sys.argv[1:])
pointer = fixture / "latest.txt"
output = fixture / "outputs"
script = root / "scripts/release-plan.py"


def plan(candidate, current):
    output.write_text("prior=preserved\n")
    if current is None:
        pointer.unlink(missing_ok=True)
    else:
        pointer.write_bytes(current)
    result = subprocess.run(
        [sys.executable, str(script), candidate, str(pointer)],
        env={**os.environ, "GITHUB_OUTPUT": str(output)},
        capture_output=True,
        text=True,
    )
    return result, output.read_text()


for candidate, current, promote, latest in [
    ("0.13.0", b"0.12.0\n", True, True),
    # A later release's CI can finish first. An older tag still publishes its
    # versioned assets, but it cannot become GitHub latest or move R2 backward.
    ("0.12.0", b"0.13.0\n", False, False),
    # Retrying the current release retains GitHub latest without rewriting R2.
    ("0.13.0", b"0.13.0\n", False, True),
    ("0.10.0", b"0.9.10", True, True),
]:
    result, outputs = plan(candidate, current)
    assert result.returncode == 0, result.stderr
    assert outputs == f"prior=preserved\npromote={str(promote).lower()}\nlatest={str(latest).lower()}\n", outputs

for current in [None, b"", b"0.13", b"0.13.0-rc1\n", b"0.13.0\n\n", b" 0.13.0\n", b"0.13.0\r\n", b"0.13.0\x00", b"\xff", b"1" * 4097]:
    result, outputs = plan("0.14.0", current)
    assert result.returncode != 0, f"accepted malformed/missing pointer: {current!r}"
    assert outputs == "prior=preserved\n", outputs

for candidate in ["", "0.14", "0.14.0-rc1", "0.14.0\nextra", "1" * 4097]:
    result, outputs = plan(candidate, b"0.13.0\n")
    assert result.returncode != 0, f"accepted malformed candidate: {candidate!r}"
    assert outputs == "prior=preserved\n", outputs

print("release promotion regressions passed (19 cases)")
PY
