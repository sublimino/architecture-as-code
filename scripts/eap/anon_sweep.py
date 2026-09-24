#!/usr/bin/env python3
"""Anonymous-reachability sweep over the five EAP routers.

Durable form of the /tmp probe used by EAPR-P2-PRE and the EAPR-P2-1 refusal
record, so the Governor can reproduce the "before" and "after" numbers without
a scratch file.

Route list is derived from ``app.routes`` filtered by the endpoint's module,
never from a hand-maintained list, so a route added to one of the five
routers is swept automatically.  Websocket routes are counted separately and
printed, so a post-merge tree that gains one cannot be silently skipped.

Run from ``d2-signalloom/apps/fe-signalloom/src``::

    UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache \
    uv run --python 3.12 --with-requirements requirements.txt \
        python ../../../../scripts/eap/anon_sweep.py

Exit status is 0 whenever the sweep ran; the verdict is the final line.
With ``--expect-zero`` the exit status is 1 when any HTTP route is reachable
or any websocket route exists unprobed, so a Governor can wire it as a gate.
The script refuses to run (exit 2) when ``DATABASE_URL`` is set.

Reading the verdict:

* ``REACHABLE`` means the response was not 401/403 — a 200/201 reached the
  handler; a 404/422/400 means validation or lookup ran, i.e. no principal
  gate fired before it.  Both count as "no auth".
* This is an in-process ``TestClient`` sweep on a bare app (no lifespan, no
  database, no ingress).  It measures the routers, not the deployed topology.
* Routes are found by endpoint module, so a sub-application or a route whose
  endpoint lives outside the five modules is invisible: the count is a lower
  bound on the anonymous surface, not an upper bound.
* Once the sealed sweep (``tests/test_tenant_isolation.py``, P1-4) is on the
  base it is the source of truth; this script is the reproduction of the
  pre-merge number.  If the two disagree, that is a finding.
"""

from __future__ import annotations

import os
import sys
from typing import Iterable

from fastapi.routing import APIRoute, APIWebSocketRoute
from fastapi.testclient import TestClient

EAP_MODULES = {
    "tenant_isolation",
    "scenario_seeding",
    "environment_routing",
    "environment_lifecycle",
    "webhook_triggers",
}

# Placeholder values for path parameters.  They only need to be syntactically
# acceptable so the request reaches auth (or the handler) rather than 422.
PATH_PARAMS = {
    "customer_hash": "deadbeef",
    "environment_id": "deadbeef",
    "agent_id": "deadbeef",
}

AUTH_STATUSES = {401, 403}


def _fill(path: str) -> str:
    for name, value in PATH_PARAMS.items():
        path = path.replace("{" + name + "}", value)
    return path


def _eap_routes(app) -> tuple[list[APIRoute], list[APIWebSocketRoute]]:
    http: list[APIRoute] = []
    ws: list[APIWebSocketRoute] = []
    for route in app.routes:
        endpoint = getattr(route, "endpoint", None)
        module = getattr(endpoint, "__module__", "")
        if module not in EAP_MODULES:
            continue
        if isinstance(route, APIWebSocketRoute):
            ws.append(route)
        elif isinstance(route, APIRoute):
            http.append(route)
    return http, ws


def _sweep(client: TestClient, routes: Iterable[APIRoute]) -> list[tuple[str, str, int]]:
    rows: list[tuple[str, str, int]] = []
    for route in routes:
        for method in sorted(route.methods or ()):
            if method in {"HEAD", "OPTIONS"}:
                continue
            path = _fill(route.path)
            kwargs = {"json": {}} if method in {"POST", "PUT", "PATCH"} else {}
            resp = client.request(method, path, **kwargs)
            rows.append((method, route.path, resp.status_code))
    return rows


def main(argv: list[str] | None = None) -> int:
    expect_zero = "--expect-zero" in (argv if argv is not None else sys.argv[1:])

    # The sweep sends anonymous mutating requests (DELETE tenant, POST
    # reap-now, POST teardown, POST scenarios/execute).  On a bare app they hit
    # in-memory stores only; with a live DSN a DB-backed handler could mutate
    # real rows, so refuse rather than measure against production state.
    if os.environ.get("DATABASE_URL"):
        print("refusing to sweep with DATABASE_URL set: unset it and re-run", file=sys.stderr)
        return 2

    # The script lives outside the app tree; import ``main`` from the cwd the
    # way pytest does (run from d2-signalloom/apps/fe-signalloom/src).
    sys.path.insert(0, os.getcwd())
    from main import app  # noqa: WPS433 — same import the test suite uses

    http, ws = _eap_routes(app)
    # No ``with`` block: entering the client runs the lifespan, which opens a
    # Postgres pool.  The test suite uses the bare client for the same reason.
    client = TestClient(app)
    control = client.get("/health").status_code
    rows = _sweep(client, http)

    width = max((len(p) for _, p, _ in rows), default=10)
    for method, path, status in rows:
        verdict = "auth" if status in AUTH_STATUSES else "REACHABLE"
        print(f"{method:<7}{path:<{width + 2}}{status:<5}{verdict}")
    for route in ws:
        print(f"WS     {route.path:<{width + 2}}-    UNPROBED")

    reachable = sum(1 for _, _, s in rows if s not in AUTH_STATUSES)
    print(f"positive control GET /health without token: {control}")
    # Websockets are counted, not probed; they ride on the verdict line so a
    # reader of only the last line cannot take "0 of N" as the whole surface.
    print(
        f"REACHABLE {reachable} of {len(rows)} EAP routes anonymously (non-401/403); "
        f"{len(ws)} websocket route(s) unprobed"
    )
    if expect_zero and (reachable or ws):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
