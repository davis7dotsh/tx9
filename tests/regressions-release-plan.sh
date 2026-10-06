#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

python3 - "$PROJECT_ROOT" "$tmp" <<'PY'
import contextlib
import http.client
import io
import os
import pathlib
import runpy
import subprocess
import sys
import types
import urllib.error
import urllib.request
from unittest import mock

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

account = "a" * 32
fixture_token = "fixture-token-do-not-print"
endpoint = f"https://api.cloudflare.com/client/v4/accounts/{account}/r2/buckets/tx9-releases/objects/latest.txt"
remote_cases = 0
build_opener = urllib.request.build_opener


def remote_plan(candidate, status=200, body=b"0.13.0\n", failure=None, credentials=None):
    output.write_text("prior=preserved\n")
    stderr = io.StringIO()
    requests = []
    reads = []
    error_bodies = []
    environment = {
        **os.environ,
        "GITHUB_OUTPUT": str(output),
        "CLOUDFLARE_ACCOUNT_ID": account,
        "CLOUDFLARE_API_TOKEN": fixture_token,
        **(credentials or {}),
    }

    class Response(io.BytesIO):
        def read(self, size):
            reads.append(size)
            assert size == 4097, size
            return super().read(size)

    def fetch(request, timeout):
        requests.append(request)
        assert request.full_url == endpoint, request.full_url
        assert request.get_method() == "GET", request.get_method()
        assert request.get_header("Authorization") == f"Bearer {fixture_token}"
        assert timeout == 30, timeout
        if failure is not None:
            raise failure
        if status >= 300:
            error_body = io.BytesIO(b"error body must close")
            error_bodies.append(error_body)
            raise urllib.error.HTTPError(endpoint, status, "fixture", {}, error_body)
        response = Response(body)
        response.status = status
        return response

    def opener(handler):
        assert isinstance(handler, urllib.request.HTTPRedirectHandler)
        actual_opener = build_opener(handler)
        assert handler in actual_opener.handlers
        assert not any(type(item) is urllib.request.HTTPRedirectHandler for item in actual_opener.handlers)
        # Redirects must be rejected before urllib forwards the bearer token.
        assert handler.redirect_request(None, None, 302, "fixture", {}, "https://elsewhere.invalid/") is None
        return types.SimpleNamespace(open=fetch)

    with (
        mock.patch.dict(os.environ, environment, clear=True),
        mock.patch.object(sys, "argv", [str(script), candidate, "--r2"]),
        mock.patch.object(urllib.request, "build_opener", side_effect=opener),
        contextlib.redirect_stderr(stderr),
    ):
        try:
            runpy.run_path(str(script), run_name="__main__")
            status_code = 0
        except SystemExit as exc:
            status_code = exc.code
    assert fixture_token not in stderr.getvalue(), stderr.getvalue()
    assert all(body.closed for body in error_bodies), "HTTP error response body leaked"
    if credentials:
        for name, value in credentials.items():
            if value.strip():
                assert value not in stderr.getvalue(), f"printed invalid {name}"
    return status_code, output.read_text(), requests, reads, stderr.getvalue()


for candidate, status, current, promote, latest in [
    # Only the direct API's HTTP 404 initializes a fresh release channel.
    ("0.12.0", 404, b"", True, True),
    ("0.14.0", 200, b"0.13.0\n", True, True),
    ("0.12.0", 200, b"0.13.0\n", False, False),
    ("0.13.0", 200, b"0.13.0\n", False, True),
    ("0.10.0", 200, b"0.9.10", True, True),
]:
    code, outputs, requests, reads, stderr = remote_plan(candidate, status, current)
    assert code == 0, stderr
    assert len(requests) == 1, requests
    assert reads == ([4097] if status == 200 else []), reads
    assert outputs == f"prior=preserved\npromote={str(promote).lower()}\nlatest={str(latest).lower()}\n", outputs
    remote_cases += 1

for current in [b"", b"0.13", b"0.13.0-rc1\n", b"0.13.0\n\n", b" 0.13.0\n", b"0.13.0\r\n", b"0.13.0\x00", b"\xff", b"1" * 4097]:
    code, outputs, requests, reads, stderr = remote_plan("0.14.0", body=current)
    assert code != 0, f"accepted malformed remote pointer: {current!r}"
    assert len(requests) == 1 and reads == [4097], (requests, reads)
    assert outputs == "prior=preserved\n", outputs
    remote_cases += 1

for status in [204, 301, 302, 303, 307, 308, 401, 403, 429, 500, 503]:
    code, outputs, requests, reads, stderr = remote_plan("0.14.0", status=status)
    assert code != 0, f"accepted unexpected HTTP status: {status}"
    assert len(requests) == 1 and reads == [], (requests, reads)
    assert outputs == "prior=preserved\n", outputs
    remote_cases += 1

for failure in [urllib.error.URLError(fixture_token), TimeoutError(fixture_token), http.client.IncompleteRead(b"partial response"), http.client.BadStatusLine(fixture_token)]:
    code, outputs, requests, reads, stderr = remote_plan("0.14.0", failure=failure)
    assert code != 0, f"accepted failed remote request: {type(failure).__name__}"
    assert len(requests) == 1 and reads == [], (requests, reads)
    assert outputs == "prior=preserved\n", outputs
    remote_cases += 1

for credentials in [
    {"CLOUDFLARE_ACCOUNT_ID": ""},
    {"CLOUDFLARE_ACCOUNT_ID": "../different-account"},
    {"CLOUDFLARE_API_TOKEN": ""},
    {"CLOUDFLARE_API_TOKEN": " "},
    {"CLOUDFLARE_API_TOKEN": fixture_token + "\r\n"},
    {"CLOUDFLARE_API_TOKEN": fixture_token + "\u0100"},
]:
    code, outputs, requests, reads, stderr = remote_plan("0.14.0", credentials=credentials)
    assert code != 0, "accepted malformed credentials"
    assert requests == [] and reads == [], (requests, reads)
    assert outputs == "prior=preserved\n", outputs
    remote_cases += 1

for candidate in ["", "0.14", "0.14.0-rc1", "0.14.0\nextra", "1" * 4097]:
    code, outputs, requests, reads, stderr = remote_plan(candidate, status=404)
    assert code != 0, f"accepted malformed bootstrap candidate: {candidate!r}"
    assert requests == [] and reads == [], (requests, reads)
    assert outputs == "prior=preserved\n", outputs
    remote_cases += 1

print(f"release promotion regressions passed (19 local cases, {remote_cases} R2 cases)")
PY
