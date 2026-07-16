"""Shared parsing and validation for FloralMD release-note generators."""

from __future__ import annotations

import re


CALVER_RE = re.compile(r"[0-9]{4}\.[0-9]{1,2}\.[0-9]+")
VERSION_HEADER_RE = re.compile(r"^## \[([^]]+)\](?:\s|$)")
INLINE_LANGUAGE_LABEL_RE = re.compile(r"\*\*(?:中文|English)[：:]\*\*")

LANGUAGE_HEADINGS = ("### 中文", "### English")
CATEGORY_HEADINGS = {
    "中文": {"新增", "变更", "弃用", "移除", "修复", "安全"},
    "English": {"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"},
}


class ChangelogFormatError(ValueError):
    """A CalVer section does not follow FloralMD's bilingual contract."""


def extract_section(version: str, lines: list[str]) -> list[str]:
    """Return one version body, stopping only at the next version heading."""
    section: list[str] = []
    capturing = False
    for line in lines:
        match = VERSION_HEADER_RE.match(line)
        if match:
            if capturing:
                break
            if match.group(1) == version:
                capturing = True
                continue
        if capturing:
            section.append(line.rstrip("\n"))
    return section


def trim_section(section: list[str]) -> list[str]:
    """Remove blank padding without changing Markdown inside the section."""
    start = 0
    end = len(section)
    while start < end and not section[start].strip():
        start += 1
    while end > start and not section[end - 1].strip():
        end -= 1
    return section[start:end]


def validate_section(version: str, section: list[str]) -> None:
    """Enforce the bilingual block contract for CalVer releases."""
    if not CALVER_RE.fullmatch(version):
        return

    text = "\n".join(section)
    if INLINE_LANGUAGE_LABEL_RE.search(text):
        raise ChangelogFormatError(
            f"{version} uses an inline language label; use block headings instead"
        )

    positions: dict[str, int] = {}
    for heading in LANGUAGE_HEADINGS:
        matches = [index for index, line in enumerate(section) if line == heading]
        if len(matches) != 1:
            raise ChangelogFormatError(
                f"{version} must contain exactly one {heading!r} heading"
            )
        positions[heading] = matches[0]
    if positions["### 中文"] > positions["### English"]:
        raise ChangelogFormatError(f"{version} must place 中文 before English")

    language_ranges = (
        ("中文", positions["### 中文"] + 1, positions["### English"]),
        ("English", positions["### English"] + 1, len(section)),
    )
    for language, start, end in language_ranges:
        category_count = 0
        for line in section[start:end]:
            if not line.startswith("#### "):
                continue
            category = line[5:]
            if category not in CATEGORY_HEADINGS[language]:
                raise ChangelogFormatError(
                    f"{version} has unsupported {language} category {category!r}"
                )
            category_count += 1
        if category_count == 0:
            raise ChangelogFormatError(
                f"{version} must contain at least one {language} category"
            )


def release_notes(version: str, lines: list[str]) -> str:
    """Return validated Markdown suitable for GitHub's --notes-file."""
    section = trim_section(extract_section(version, lines))
    if not section:
        return ""
    validate_section(version, section)
    return "\n".join(section) + "\n"
