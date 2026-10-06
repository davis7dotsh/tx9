#!/usr/bin/env python3
"""Plan latest promotion against canonical R2 state inside serialized release CI."""

import http.client
import os
import re
import sys
import urllib.error
import urllib.request

MAX_VERSION_BYTES = 4096


def version_tuple(value):
    if len(value.encode("utf-8")) > MAX_VERSION_BYTES or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\n?", value):
        raise ValueError("Release version must be a plain numeric X.Y.Z with at most one trailing newline")
    return tuple(int(part) for part in value.rstrip("\n").split("."))


def release_plan(candidate, current):
    candidate_version = version_tuple(candidate)
    if current is None:
        return {"promote": True, "latest": True}
    current_version = version_tuple(current)
    return {
        "promote": candidate_version > current_version,
        "latest": candidate_version >= current_version,
    }


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, stream, code, message, headers, new_url):
        return None


def r2_latest_version():
    account = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not re.fullmatch(r"[a-fA-F0-9]{32}", account):
        raise ValueError("CLOUDFLARE_ACCOUNT_ID must be a 32-digit hexadecimal account ID")
    if not token.strip() or not token.isascii() or any(character in token for character in "\r\n"):
        raise ValueError("CLOUDFLARE_API_TOKEN must be set without non-ASCII characters or line breaks")
    request = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/accounts/{account}/r2/buckets/tx9-releases/objects/latest.txt",
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    # Keep credentials on this exact endpoint and reject redirected responses.
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=30) as response:
            if response.status != 200:
                raise ValueError(f"Unexpected R2 latest pointer HTTP status: {response.status}")
            return response.read(MAX_VERSION_BYTES + 1).decode("ascii")
    except urllib.error.HTTPError as exc:
        exc.close()
        if exc.code == 404:
            return None
        raise ValueError(f"R2 latest pointer request failed with HTTP {exc.code}") from None
    except (urllib.error.URLError, OSError, http.client.HTTPException):
        raise ValueError("R2 latest pointer request failed") from None


def main():
    if len(sys.argv) != 3:
        raise ValueError("Usage: release-plan.py VERSION CURRENT_VERSION_FILE|--r2")
    # A missing remote pointer initializes the release channel only after the
    # candidate has validated. Local files still fail closed when missing.
    version_tuple(sys.argv[1])
    if sys.argv[2] == "--r2":
        current = r2_latest_version()
    else:
        with open(sys.argv[2], "rb") as stream:
            current = stream.read(MAX_VERSION_BYTES + 1).decode("ascii")
    plan = release_plan(sys.argv[1], current)
    # Validate everything before opening the outputs file. A corrupt/unavailable
    # pointer fails closed, leaving both publication decisions unset. Only a
    # confirmed remote HTTP 404 can initialize an absent release channel.
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        for name, value in plan.items():
            stream.write(f"{name}={str(value).lower()}\n")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError) as exc:
        print(f"Release planning failed: {exc}", file=sys.stderr)
        sys.exit(1)
