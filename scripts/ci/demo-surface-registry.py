#!/usr/bin/env python3
"""Enumerate the user-facing demo surfaces from the code that serves them.

Prints one demo per line: `<demo_type>\t<label>\t<default_script>`.

── Why this parses source instead of carrying a list ────────────────────────

The gate this feeds exists because a hand-written list omitted a surface. A
second hand-written list inside the gate would reproduce the defect one layer
down, and it would do so silently: a demo added to DEMO_CONFIGS but not to the
gate's list is a demo nobody probes, and every run stays green while it is
broken. That exact shape — a hand-maintained enumeration drifting behind the
thing it claims to cover — has now been the root cause four separate times in
this repository (stage-1g lists, EXCLUDED_BATS, orphan proofs, dual-lane
registration). So the enumeration is DERIVED from the single place the server
itself reads: demo_runner.DEMO_CONFIGS.

── Why ast and not import ───────────────────────────────────────────────────

Importing demo_runner pulls FastAPI, pydantic and the app's whole settings
chain into a script that must run on a CI VM before that toolchain is proven,
and inside a bats suite that has no virtualenv. `ast` needs nothing but the
stdlib and reads the same bytes the server does.

── Why it fails loudly rather than returning empty ──────────────────────────

An extractor that returns zero demos when the file's shape changes would turn
the gate vacuous — it would iterate an empty set, find nothing broken, and
exit 0. That is precisely the failure this whole exercise is about, so a shape
this cannot parse is a hard error with a non-zero exit, never an empty list.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

REGISTRY_NAME = "DEMO_CONFIGS"
CONFIG_CALL = "DemoConfig"
# Keys read off each DemoConfig(...) call. demo_type is the URL segment, so it
# is the one field the gate cannot work without.
REQUIRED_FIELDS = ("demo_type", "label")


def _const_str(node: ast.AST) -> str | None:
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None


def _find_registry(tree: ast.Module) -> ast.Dict:
    """Return the dict literal DEMO_CONFIGS is built from.

    Handles both `DEMO_CONFIGS = {...}` and the MappingProxyType({...}) wrapper
    the module currently uses. Anything else is an unparsed shape, not a
    zero-demo answer.
    """
    for node in ast.walk(tree):
        if not isinstance(node, ast.AnnAssign | ast.Assign):
            continue
        targets = [node.target] if isinstance(node, ast.AnnAssign) else node.targets
        if not any(isinstance(t, ast.Name) and t.id == REGISTRY_NAME for t in targets):
            continue
        value = node.value
        # Unwrap MappingProxyType(...) / dict(...) style wrappers, one arg deep.
        if isinstance(value, ast.Call) and value.args:
            value = value.args[0]
        if isinstance(value, ast.Dict):
            return value
        raise SystemExit(
            f"{REGISTRY_NAME} is present but is not a dict literal this extractor "
            f"understands (got {type(value).__name__}). The gate's enumeration is "
            f"derived from it, so an unreadable shape is a hard failure, not an "
            f"empty demo list."
        )
    raise SystemExit(f"no {REGISTRY_NAME} assignment found — the demo registry moved or was renamed")


def extract(source: str) -> list[tuple[str, str, str]]:
    registry = _find_registry(ast.parse(source))
    demos: list[tuple[str, str, str]] = []

    for key_node, value_node in zip(registry.keys, registry.values, strict=True):
        key = _const_str(key_node) if key_node is not None else None
        if not isinstance(value_node, ast.Call) or getattr(value_node.func, "id", None) != CONFIG_CALL:
            raise SystemExit(
                f"registry entry {key!r} is not a {CONFIG_CALL}(...) call — refusing to "
                f"guess at its demo_type"
            )
        fields = {kw.arg: _const_str(kw.value) for kw in value_node.keywords if kw.arg}
        missing = [f for f in REQUIRED_FIELDS if not fields.get(f)]
        if missing:
            raise SystemExit(
                f"registry entry {key!r} is missing non-literal or absent field(s): "
                f"{', '.join(missing)}"
            )
        demo_type = fields["demo_type"]
        if key is not None and key != demo_type:
            # The dict key is what a reader scans; demo_type is what becomes the
            # URL. If they disagree, the gate would probe a path no client uses.
            raise SystemExit(f"registry key {key!r} disagrees with demo_type {demo_type!r}")
        demos.append((demo_type, fields["label"], fields.get("default_script") or ""))

    if not demos:
        raise SystemExit(f"{REGISTRY_NAME} parsed to zero demos — a gate over an empty set proves nothing")
    return demos


# ── The client half of the contract ─────────────────────────────────────────
#
# Knowing a demo's SERVER route is not enough to probe it as a human does, and
# assuming otherwise produced a false verdict in this gate's own first run.
#
# The two shipped demos do not share a user-facing prefix:
#
#   supercred     SPA calls /demo-api            -> nginx rewrites to /api/demo/supercred
#   signalfusion  SPA calls /api/demo/signalfusion  (straight through the Gateway)
#
# Probing the server prefix for BOTH reported SuperCred BROKEN — because
# /api/demo/supercred through the Gateway lands on fe-signalloom, which has no
# scripts BY DESIGN and is a path no client uses. Right verdict, wrong
# evidence, and the wrong evidence would have sent someone to fix routing that
# is working as intended.
#
# So the prefix is derived from the CLIENT too. For each demo the server knows
# about, find the SPA module that references /api/demo/<demo_type>, and take
# the prefix constant that module actually calls through. A demo the SPA never
# mentions is reported with an empty prefix, and the gate fails on it: that is
# a surface the server serves and no client can reach, which is exactly as
# broken as the reverse and just as invisible to either half alone.
PREFIX_CONST = re.compile(
    r"^\s*(?:export\s+)?const\s+\w*DEMO_API\w*\s*(?::\s*[\w<>\[\]| ]+)?\s*=\s*['\"]([^'\"]+)['\"]",
    re.MULTILINE,
)


def ui_prefix_for(demo_type: str, spa_dir: Path) -> str:
    """The prefix the SPA actually calls for this demo, or '' if none does."""
    if not spa_dir.is_dir():
        return ""
    for src in sorted(spa_dir.glob("*.ts")):
        if src.name.endswith(".test.ts"):
            continue  # tests assert on legacy spellings; they are not the client
        text = src.read_text(encoding="utf-8", errors="replace")
        if f"/api/demo/{demo_type}" not in text:
            continue
        m = PREFIX_CONST.search(text)
        if m:
            return m.group(1).rstrip("/")
    return ""


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(
            f"usage: {Path(argv[0]).name} <path-to-demo_runner.py> [spa-api-dir]",
            file=sys.stderr,
        )
        return 2
    path = Path(argv[1])
    if not path.is_file():
        print(f"demo registry source not found: {path}", file=sys.stderr)
        return 2
    spa_dir = Path(argv[2]) if len(argv) == 3 else None
    for demo_type, label, script in extract(path.read_text(encoding="utf-8")):
        prefix = ui_prefix_for(demo_type, spa_dir) if spa_dir else f"/api/demo/{demo_type}"
        print(f"{demo_type}\t{label}\t{script}\t{prefix}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
