#!/usr/bin/env python3
"""Validate FloralMD CalVer, tag, and monotonic Sparkle build metadata."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from typing import Optional


CALVER_PATTERN = re.compile(
    r"^(?P<year>[0-9]{4})\.(?P<month>[1-9]|1[0-2])\.(?P<patch>0|[1-9][0-9]*)$"
)


@dataclass(frozen=True, order=True)
class CalVer:
    year: int
    month: int
    patch: int


def parse_calver(value: str) -> CalVer:
    match = CALVER_PATTERN.fullmatch(value)
    if not match:
        raise ValueError(
            f"{value!r} is not FloralMD CalVer YYYY.MM.PATCH "
            "(month and patch must not be zero-padded)"
        )
    return CalVer(*(int(match.group(name)) for name in ("year", "month", "patch")))


def validate_successor(previous: str, current: str) -> None:
    old = parse_calver(previous)
    new = parse_calver(current)
    old_month = (old.year, old.month)
    new_month = (new.year, new.month)
    if new_month == old_month and new.patch == old.patch + 1:
        return
    if new_month > old_month and new.patch == 0:
        return
    raise ValueError(
        f"{current} is not the next FloralMD release after {previous}: "
        "increment PATCH within a month, or use PATCH 0 in a later month"
    )


def positive_integer(value: str, label: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError(f"{label} must be a positive integer without leading zeroes")
    return int(value)


def validate_release(
    *,
    version: str,
    tag: str,
    build: str,
    previous_version: Optional[str] = None,
    previous_build: Optional[str] = None,
) -> None:
    parse_calver(version)
    if tag != f"v{version}":
        raise ValueError(f"tag {tag!r} must be exactly 'v{version}'")

    build_number = positive_integer(build, "build")

    if previous_version is not None:
        validate_successor(previous_version, version)
    if previous_build is not None:
        old_build = positive_integer(previous_build, "previous build")
        if build_number <= old_build:
            raise ValueError(
                f"build {build_number} must be greater than previous build {old_build}"
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--previous-version")
    parser.add_argument("--previous-build")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        validate_release(
            version=args.version,
            tag=args.tag,
            build=args.build,
            previous_version=args.previous_version,
            previous_build=args.previous_build,
        )
    except ValueError as error:
        raise SystemExit(f"release version validation failed: {error}") from error


if __name__ == "__main__":
    main()
