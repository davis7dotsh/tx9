#!/usr/bin/env python3
"""Plan latest promotion against canonical R2 state inside serialized release CI."""

import os
import re
import sys

MAX_VERSION_BYTES = 4096


def version_tuple(value):
    if len(value.encode("utf-8")) > MAX_VERSION_BYTES or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\n?", value):
        raise ValueError("Release version must be a plain numeric X.Y.Z with at most one trailing newline")
    return tuple(int(part) for part in value.rstrip("\n").split("."))


def release_plan(candidate, current):
    candidate_version = version_tuple(candidate)
    current_version = version_tuple(current)
    return {
        "promote": candidate_version > current_version,
        "latest": candidate_version >= current_version,
    }


def main():
    if len(sys.argv) != 3:
        raise ValueError("Usage: release-plan.py VERSION CURRENT_VERSION_FILE")
    with open(sys.argv[2], "rb") as stream:
        current = stream.read(MAX_VERSION_BYTES + 1).decode("ascii")
    plan = release_plan(sys.argv[1], current)
    # Validate everything before opening the outputs file. A corrupt/missing
    # pointer fails closed, leaving both publication decisions unset.
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        for name, value in plan.items():
            stream.write(f"{name}={str(value).lower()}\n")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError) as exc:
        print(f"Release planning failed: {exc}", file=sys.stderr)
        sys.exit(1)
