#!/usr/bin/env python3
"""Derive the dashboard's explorable application surface from its route table.

The Jev test bot explores one area at a time. Left to a human, the list of
areas drifts: a page gets added to `App.tsx` and nobody remembers to add it to
the bot's invocation, so it is never explored and nobody notices — an absence
of findings reads exactly like a clean bill of health.

So the surface is derived, not written down. This module is the single place
that reads `<Route path=...>` out of
`d2-signalloom/apps/dashboard-signalloom/src/App.tsx` and turns it into a list
of concrete, fetchable paths. `test_routes.py` asserts against the real file
that every static route survives the derivation, so a new page cannot be
silently uncovered.

Four kinds of declared path, handled differently:

  * static (`/agents`)                 — taken as-is
  * parametrised (`/agents/:id`)       — a representative value is substituted
  * splat (`/demos/agentmaxxing/*`)    — collapsed onto its addressable parent
  * catch-all (`*`)                    — dropped; it is a fallback, not a page

`/login` and `/callback` are excluded: they are the unauthenticated auth
handshake, and walking them from an exploration run either logs the session
out or bounces straight back. `docs/EAP/pages.md` describes them as the two
pages that need no session, which is the same boundary from the other side.

Usage:

    python3 scripts/jev-test-bot/routes.py              # one path per line
    python3 scripts/jev-test-bot/routes.py --json       # {"routes": [...], ...}
    python3 scripts/jev-test-bot/routes.py --app-tsx path/to/App.tsx
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import List

# Representative values for parametrised segments. These are deliberately
# obviously-synthetic: the bot fetches them against a demo-mode dashboard, and
# a value that looks like real data invites someone to believe the page under
# it was really exercised. Keep this map small and named — the catch-all below
# exists so an unmapped parameter never drops a page from the surface, not so
# that mapping can be skipped (test_routes.py reports unmapped parameters).
PARAM_VALUES = {
    "id": "example",
    "accountId": "example-account",
    "frameworkId": "example-framework",
    "provider": "github",
}

DEFAULT_PARAM_VALUE = "example"

# Excluded from exploration, with the reason kept next to the exclusion so a
# future reader can tell a deliberate omission from an oversight.
EXCLUDED_ROUTES = {
    "/login": "unauthenticated auth entry point; exploring it fights the session",
    "/callback": "OIDC redirect target; meaningless without a live code exchange",
}

# `path` is the first attribute on every `<Route>` in App.tsx today, but the
# pattern tolerates preceding attributes as long as they carry no angle
# bracket. Both the bare-string and the brace-wrapped forms occur in the file.
_ROUTE_RE = re.compile(
    r"""<Route\s[^<>]*?\bpath=
        (?:
            "([^"]*)"                 |   # path="/agents"
            '([^']*)'                 |   # path='/agents'
            \{\s*'([^']*)'\s*\}       |   # path={'/demos/agentmaxxing'}
            \{\s*"([^"]*)"\s*\}           # path={"/demos/agentmaxxing"}
        )
    """,
    re.VERBOSE,
)

_PARAM_RE = re.compile(r"^:([A-Za-z0-9_]+)$")


def default_app_tsx() -> str:
    """Path to the dashboard route table, relative to the repository root."""
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", ".."))
    return os.path.join(
        root, "d2-signalloom", "apps", "dashboard-signalloom", "src", "App.tsx"
    )


def parse_route_paths(source: str) -> List[str]:
    """Every distinct `path` declared on a `<Route>`, in declaration order."""
    seen: List[str] = []
    for match in _ROUTE_RE.finditer(source):
        path = next(group for group in match.groups() if group is not None)
        if path not in seen:
            seen.append(path)
    return seen


def is_static(path: str) -> bool:
    """True when the path addresses a page directly, with no placeholder."""
    return ":" not in path and "*" not in path


def is_auth_only(path: str) -> bool:
    return path in EXCLUDED_ROUTES


def substitute_params(path: str) -> str:
    """Replace `:param` segments with representative values."""
    out = []
    for segment in path.split("/"):
        match = _PARAM_RE.match(segment)
        if match:
            out.append(PARAM_VALUES.get(match.group(1), DEFAULT_PARAM_VALUE))
        else:
            out.append(segment)
    return "/".join(out)


def _collapse_splat(path: str) -> str | None:
    """`/a/b/*` addresses the same page as `/a/b`; bare `*` addresses nothing."""
    if path == "*":
        return None
    if path.endswith("/*"):
        return path[: -len("/*")] or "/"
    if "*" in path:
        # A splat anywhere other than the tail is not a react-router shape we
        # know how to address. Drop it loudly rather than fetching nonsense.
        return None
    return path


def derive_routes(source: str) -> List[str]:
    """The explorable surface: concrete, deduped, in declaration order."""
    derived: List[str] = []
    for raw in parse_route_paths(source):
        if is_auth_only(raw):
            continue
        collapsed = _collapse_splat(raw)
        if collapsed is None:
            continue
        concrete = substitute_params(collapsed)
        if not concrete.startswith("/"):
            continue
        if concrete not in derived:
            derived.append(concrete)
    return derived


def derive_from_file(app_tsx: str) -> List[str]:
    with open(app_tsx, encoding="utf-8") as handle:
        return derive_routes(handle.read())


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Derive the dashboard's explorable route surface from App.tsx"
    )
    parser.add_argument(
        "--app-tsx",
        default=os.environ.get("JEV_APP_TSX", default_app_tsx()),
        help="Path to the dashboard App.tsx holding the <Route> table",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit a JSON object instead of one path per line",
    )
    args = parser.parse_args(argv)

    if not os.path.exists(args.app_tsx):
        print(f"routes.py: no such route table: {args.app_tsx}", file=sys.stderr)
        return 2

    with open(args.app_tsx, encoding="utf-8") as handle:
        source = handle.read()

    declared = parse_route_paths(source)
    if not declared:
        print(
            f"routes.py: parsed zero <Route> entries from {args.app_tsx} — "
            "the route table moved or changed shape, refusing to report an "
            "empty surface as success",
            file=sys.stderr,
        )
        return 3

    derived = derive_routes(source)

    if args.json:
        json.dump(
            {
                "app_tsx": args.app_tsx,
                "declared_count": len(declared),
                "routes": derived,
                "route_count": len(derived),
                "excluded": EXCLUDED_ROUTES,
                "param_values": PARAM_VALUES,
            },
            sys.stdout,
            indent=2,
        )
        sys.stdout.write("\n")
    else:
        for route in derived:
            print(route)
    return 0


if __name__ == "__main__":
    sys.exit(main())
