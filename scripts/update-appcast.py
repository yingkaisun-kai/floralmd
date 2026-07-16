#!/usr/bin/env python3
"""Insert or replace one signed FloralMD release in a Sparkle appcast."""

from __future__ import annotations

import argparse
import html
import re
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", required=True, type=int)
    parser.add_argument("--pub-date", required=True)
    parser.add_argument("--description-file", type=Path)
    return parser.parse_args()


def make_item(args: argparse.Namespace) -> str:
    description = ""
    if args.description_file:
        body = args.description_file.read_text(encoding="utf-8").strip()
        if body:
            if "]]>" in body:
                raise SystemExit("description contains an invalid CDATA terminator")
            description = f"\n            <description><![CDATA[\n{body}\n]]></description>"

    attrs = {
        "url": args.url,
        "sparkle:version": args.build,
        "sparkle:shortVersionString": args.version,
        "sparkle:edSignature": args.signature,
        "length": str(args.length),
        "type": "application/x-apple-diskimage",
    }
    rendered_attrs = "\n                       ".join(
        f'{name}="{html.escape(value, quote=True)}"' for name, value in attrs.items()
    )
    return (
        "        <item>\n"
        f"            <title>FloralMD {html.escape(args.version)}</title>\n"
        f"            <pubDate>{html.escape(args.pub_date)}</pubDate>"
        f"{description}\n"
        f"            <enclosure {rendered_attrs}/>\n"
        "        </item>"
    )


def main() -> None:
    args = parse_args()
    content = args.appcast.read_text(encoding="utf-8")
    if content.count("</channel>") != 1:
        raise SystemExit("appcast must contain exactly one closing channel element")

    version_attribute = re.compile(
        r"sparkle:shortVersionString=[\"']" + re.escape(args.version) + r"[\"']"
    )
    item_pattern = re.compile(r"\n?[ \t]*<item>.*?</item>\n?", re.DOTALL)
    content = item_pattern.sub(
        lambda match: "\n" if version_attribute.search(match.group(0)) else match.group(0),
        content,
    )
    new_item = make_item(args)
    first_item = re.search(r"\n[ \t]*<item>", content)
    if first_item:
        content = content[: first_item.start()] + f"\n{new_item}" + content[first_item.start() :]
    else:
        content = content.replace("    </channel>", f"{new_item}\n    </channel>")
    args.appcast.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    main()
