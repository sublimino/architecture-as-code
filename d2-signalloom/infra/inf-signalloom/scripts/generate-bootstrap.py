#!/usr/bin/env python3
"""Generate the empty-database PostgreSQL bootstrap from vendored migrations."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

MIGRATION = re.compile(r"^(?P<id>[0-9]+)_(?P<name>[a-z0-9][a-z0-9_-]*)\.sql$")


def migrations(source: Path) -> list[tuple[int, str, Path]]:
    entries: list[tuple[int, str, Path]] = []
    identifiers: dict[int, str] = {}
    for path in source.iterdir():
        if not path.is_file() or path.suffix != ".sql":
            continue
        match = MIGRATION.fullmatch(path.name)
        if not match:
            raise ValueError(f"ambiguous migration filename: {path.name}")
        identifier = int(match["id"])
        if identifier in identifiers:
            raise ValueError(f"duplicate migration identifier {identifier:03d}: {identifiers[identifier]}, {path.name}")
        identifiers[identifier] = path.name
        entries.append((identifier, path.name, path))
    if not entries:
        raise ValueError(f"no migrations found in {source}")
    return sorted(entries)


def render(source: Path) -> str:
    parts = ["-- GENERATED FILE: do not edit.", "-- Source: d2-signalloom/apps/fe-signalloom/src/db/migrations", ""]
    for _, name, path in migrations(source):
        sql = path.read_text(encoding="utf-8").rstrip()
        parts.extend((f"-- BEGIN {name}", sql, f"-- END {name}", ""))
    return "\n".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        content = render(args.source)
    except (OSError, ValueError) as error:
        print(f"bootstrap generation failed: {error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(content, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
