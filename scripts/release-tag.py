#!/usr/bin/env python3
"""Tag a checked main-branch version bump; the tag workflow publishes it."""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request


SHA_RE = re.compile(r"[0-9a-f]{40}")
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def git_file(sha, path):
    subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], check=True, capture_output=True)
    result = subprocess.run(["git", "show", f"{sha}:{path}"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def version_tuple(value):
    if value is None or not VERSION_RE.fullmatch(value):
        raise ValueError("VERSION must contain a plain numeric X.Y.Z version")
    return tuple(int(part) for part in value.split("."))


def github_request(repository, token, method, path, payload=None):
    url = f"{os.environ.get('GITHUB_API_URL', 'https://api.github.com')}/repos/{repository}/{path}"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode() if payload is not None else None,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def tag_commit(repository, token, tag):
    try:
        obj = github_request(repository, token, "GET", f"git/ref/tags/{tag}")["object"]
    except urllib.error.HTTPError as exc:
        exc.close()
        if exc.code == 404:
            return None
        raise
    # Annotated tags can point at other annotated tags. Bound malformed chains.
    for _ in range(8):
        if obj["type"] == "commit":
            return obj["sha"]
        if obj["type"] != "tag" or not SHA_RE.fullmatch(obj["sha"]):
            break
        obj = github_request(repository, token, "GET", f"git/tags/{obj['sha']}")["object"]
    raise ValueError(f"{tag} does not resolve to a commit")


def create_tag(repository, token, sha, version):
    tag = f"v{version}"
    existing = tag_commit(repository, token, tag)
    if existing is None:
        try:
            github_request(repository, token, "POST", "git/refs", {"ref": f"refs/tags/{tag}", "sha": sha})
        except urllib.error.HTTPError as exc:
            exc.close()
            if exc.code != 422:
                raise
            # A concurrent retry can create the same ref between GET and POST.
            existing = tag_commit(repository, token, tag)
            if existing is None:
                raise
        else:
            print(f"Created {tag} at {sha}; tag-push release CI will publish it.")
            return
    if existing != sha:
        raise ValueError(f"{tag} already points to a different commit; refusing to retarget it")
    print(f"{tag} already points to {sha}; nothing to change.")


def main():
    if os.environ.get("GITHUB_EVENT_NAME") != "push" or os.environ.get("GITHUB_REF") != "refs/heads/main":
        print("Ignoring an event outside pushes to main.")
        return
    sha = os.environ["GITHUB_SHA"]
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as stream:
        event = json.load(stream)
    before = event["before"]
    if not SHA_RE.fullmatch(sha) or not SHA_RE.fullmatch(before) or event.get("after") != sha:
        raise ValueError("Push event must identify the exact before and after commits")
    current = git_file(sha, "VERSION")
    previous = None if before == "0" * 40 else git_file(before, "VERSION")
    if current == previous:
        print("VERSION did not change; no release tag needed.")
        return
    version = version_tuple(current)
    if previous is not None and version <= version_tuple(previous):
        raise ValueError("VERSION must increase before a new release is tagged")
    if not git_file(sha, f"docs/releases/v{current}.md"):
        raise ValueError(f"Nonempty release notes docs/releases/v{current}.md are required")
    repository = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GITHUB_REPOSITORY")
    token = os.environ["GH_TOKEN"]
    if not token:
        raise ValueError("GH_TOKEN is required to create a release tag")
    create_tag(repository, token, sha, current)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError, subprocess.CalledProcessError) as exc:
        # HTTPError's message contains only URL/status, never auth headers.
        print(f"Release tagging failed: {exc}", file=sys.stderr)
        sys.exit(1)
