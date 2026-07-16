#!/usr/bin/env python3
"""Print one validated CHANGELOG section as GitHub Release Markdown."""

from __future__ import annotations

import sys

from changelog_tools import ChangelogFormatError, release_notes


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: extract-release-notes.py <version>", file=sys.stderr)
        return 2
    try:
        with open("CHANGELOG.md", encoding="utf-8") as file:
            notes = release_notes(sys.argv[1], file.readlines())
    except ChangelogFormatError as error:
        print(f"invalid CHANGELOG section: {error}", file=sys.stderr)
        return 1
    print(notes, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
