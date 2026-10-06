#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PYTHONDONTWRITEBYTECODE=1 python3 - "$PROJECT_ROOT" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

import yaml

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("release_tag", root / "scripts/release-tag.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class GitHubFixture:
    def __init__(self, existing=None, annotated=None, raced=None):
        self.existing = existing
        self.annotated = annotated or {}
        self.raced = raced
        self.requests = []

    def __call__(self, request, *, timeout):
        assert timeout == 30
        self.requests.append(request)
        path = request.full_url.split("/repos/owner/tx9/")[1]
        if request.method == "POST":
            assert path == "git/refs"
            if self.raced:
                self.existing = {"type": "commit", "sha": self.raced}
                raise urllib.error.HTTPError(request.full_url, 422, "fixture conflict", {}, None)
            data = json.loads(request.data)
            self.existing = {"type": "commit", "sha": data["sha"]}
            result = {"ref": data["ref"], "object": self.existing}
        elif path.startswith("git/ref/tags/"):
            if self.existing is None:
                raise urllib.error.HTTPError(request.full_url, 404, "fixture missing", {}, None)
            result = {"object": self.existing}
        else:
            assert path.startswith("git/tags/")
            result = {"object": self.annotated[path.rsplit("/", 1)[1]]}
        return io.BytesIO(json.dumps(result).encode())


class ReleaseTagTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = pathlib.Path.cwd()
        os.chdir(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(os.chdir, self.cwd)
        self.git("init", "-q")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "user.name", "Release Test")
        self.env = {
            "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": "owner/tx9", "GH_TOKEN": "release-test-placeholder",
            "GITHUB_EVENT_PATH": str(pathlib.Path("event.json").resolve()),
            "GITHUB_API_URL": "https://api.example.invalid",
        }

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.PIPE).strip()

    def commit(self, version, notes=True):
        if version is None:
            pathlib.Path("VERSION").unlink(missing_ok=True)
        else:
            pathlib.Path("VERSION").write_text(version + "\n")
            if notes:
                directory = pathlib.Path("docs/releases")
                directory.mkdir(parents=True, exist_ok=True)
                (directory / f"v{version}.md").write_text("Release notes\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture", "--allow-empty")
        return self.git("rev-parse", "HEAD")

    def run_event(self, before, after, api=None, **env):
        pathlib.Path("event.json").write_text(json.dumps({"before": before, "after": after}))
        settings = {**self.env, "GITHUB_SHA": after, **env}
        api = api or GitHubFixture()
        with mock.patch.dict(os.environ, settings), mock.patch.object(release.urllib.request, "urlopen", api):
            with contextlib.redirect_stdout(io.StringIO()):
                release.main()
        return api

    def test_ignores_pr_and_non_main_events(self):
        for event, ref in [("pull_request", "refs/pull/37/merge"), ("push", "refs/heads/feature")]:
            api = self.run_event("invalid", "invalid", GITHUB_EVENT_NAME=event, GITHUB_REF=ref)
            self.assertFalse(api.requests)

    def test_unchanged_version_does_not_need_notes_or_a_token(self):
        before = self.commit("0.11.0", notes=False)
        after = self.commit("0.11.0", notes=False)
        api = self.run_event(before, after, GH_TOKEN="")
        self.assertFalse(api.requests)

    def test_exact_event_commit_is_tagged_even_if_checkout_moved(self):
        before = self.commit("0.11.10")
        after = self.commit("0.12.0")
        self.commit("0.13.0")
        api = self.run_event(before, after)
        writes = [request for request in api.requests if request.method == "POST"]
        self.assertEqual(len(writes), 1)
        self.assertEqual(json.loads(writes[0].data), {"ref": "refs/tags/v0.12.0", "sha": after})

    def test_initial_version_file_can_release(self):
        before = self.commit(None)
        after = self.commit("0.12.0")
        self.assertEqual(self.run_event(before, after).existing["sha"], after)

    def test_invalid_missing_or_decreasing_version_cannot_write(self):
        for value in [None, "0.12", "0.12.0-rc1", "0.12.0\nextra", "0.9.0"]:
            before = self.commit("0.11.0")
            after = self.commit(value, notes=False)
            api = GitHubFixture()
            with self.assertRaises(ValueError):
                self.run_event(before, after, api)
            self.assertFalse(api.requests)

    def test_missing_notes_cannot_write(self):
        before = self.commit("0.11.0")
        after = self.commit("0.12.0", notes=False)
        api = GitHubFixture()
        with self.assertRaisesRegex(ValueError, "release notes"):
            self.run_event(before, after, api)
        self.assertFalse(api.requests)

    def test_event_sha_mismatch_is_rejected(self):
        before = self.commit("0.11.0")
        after = self.commit("0.12.0")
        with self.assertRaisesRegex(ValueError, "exact before and after"):
            self.run_event(before, after, GITHUB_SHA=before)

    def test_existing_lightweight_tag_is_immutable_and_idempotent(self):
        before = self.commit("0.11.0")
        after = self.commit("0.12.0")
        same = GitHubFixture(existing={"type": "commit", "sha": after})
        self.run_event(before, after, same)
        self.assertEqual([r.method for r in same.requests], ["GET"])
        different = GitHubFixture(existing={"type": "commit", "sha": before})
        with self.assertRaisesRegex(ValueError, "refusing to retarget"):
            self.run_event(before, after, different)
        self.assertEqual([r.method for r in different.requests], ["GET"])

    def test_existing_annotated_tag_is_peeled(self):
        before = self.commit("0.11.0")
        after = self.commit("0.12.0")
        tag_sha = "a" * 40
        api = GitHubFixture(existing={"type": "tag", "sha": tag_sha},
                            annotated={tag_sha: {"type": "commit", "sha": after}})
        self.run_event(before, after, api)
        self.assertEqual([r.method for r in api.requests], ["GET", "GET"])

    def test_concurrent_same_commit_creation_is_safe(self):
        before = self.commit("0.11.0")
        after = self.commit("0.12.0")
        api = GitHubFixture(raced=after)
        self.run_event(before, after, api)
        self.assertEqual([r.method for r in api.requests], ["GET", "POST", "GET"])
        with self.assertRaisesRegex(ValueError, "refusing to retarget"):
            self.run_event(before, after, GitHubFixture(raced=before))

    def test_workflow_requires_both_successful_checks_and_a_main_push(self):
        workflow = yaml.safe_load((root / ".depot/workflows/check.yml").read_text())
        job = workflow["jobs"]["release-tag"]
        self.assertEqual(set(job["needs"]), {"make-check", "site-check"})
        for guard in ["success()", "github.event_name == 'push'", "github.ref == 'refs/heads/main'"]:
            self.assertIn(guard, job["if"])
        checkout = job["steps"][0]["with"]
        self.assertEqual(checkout["ref"], "${{ github.sha }}")
        self.assertEqual(checkout["fetch-depth"], 0)
        self.assertFalse(checkout["persist-credentials"])
        self.assertEqual(job["permissions"], {"contents": "write"})
        self.assertEqual(job["steps"][-1]["env"]["GH_TOKEN"], "${{ secrets.GITHUB_TOKEN }}")


unittest.main(argv=["release-tag"], verbosity=1)
PY
