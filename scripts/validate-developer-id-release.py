#!/usr/bin/env python3
"""Validate Apple notarization results for a Developer ID release."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def inspect_notary_result(
    submission: dict[str, object], log: dict[str, object]
) -> tuple[str, int, int]:
    status = submission.get("status")
    submission_id = submission.get("id")
    if status != "Accepted":
        raise ValueError(f"Apple notarization status is {status!r}, not 'Accepted'")
    if not isinstance(submission_id, str) or not submission_id:
        raise ValueError("Apple notarization response has no submission id")

    # Apple's clean notarization log may encode "no issues" as null rather
    # than an empty array.
    issues = log.get("issues")
    if issues is None:
        issues = []
    if not isinstance(issues, list):
        raise ValueError("Apple notarization log has an invalid issues field")
    errors = 0
    warnings = 0
    for issue in issues:
        if not isinstance(issue, dict):
            raise ValueError("Apple notarization log contains an invalid issue")
        severity = str(issue.get("severity", "")).lower()
        if severity == "error":
            errors += 1
        elif severity == "warning":
            warnings += 1
    if errors:
        raise ValueError(f"Apple notarization log contains {errors} error(s)")
    if warnings:
        raise ValueError(f"Apple notarization log contains {warnings} warning(s)")
    return submission_id, warnings, errors


def load_json(path: Path) -> dict[str, object]:
    with path.open(encoding="utf-8") as file:
        value = json.load(file)
    if not isinstance(value, dict):
        raise ValueError(f"{path} does not contain a JSON object")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--submission", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--print-id", action="store_true")

    args = parser.parse_args()
    try:
        submission_id, warnings, errors = inspect_notary_result(
            load_json(args.submission), load_json(args.log)
        )
        if args.print_id:
            print(submission_id)
        else:
            print(f"Accepted; warnings={warnings}; errors={errors}")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
