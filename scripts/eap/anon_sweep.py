#!/usr/bin/env python3
"""Anonymous-reachability sweep over the five EAP routers.

Durable form of the /tmp probe used by EAPR-P2-PRE and the EAPR-P2-1 refusal
record, so the Governor can reproduce the "before" and "after" numbers without
a scratch file.

Route list is derived from ``app.routes`` filtered by the endpoint's module,
never from a hand-maintained list, so a route added to one of the five
routers is swept automatically.  Websocket routes are probed by an anonymous
handshake: a denial response counts as auth, an accepted socket as REACHABLE.

Run from ``d2-signalloom/apps/fe-signalloom/src``::

    UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache \
    uv run --python 3.12 --with-requirements requirements.txt \
        python ../../../../scripts/eap/anon_sweep.py

Exit status is 0 whenever the sweep ran; the verdict is the final line.
With ``--expect-zero`` the exit status is 1 when any HTTP or websocket route is
reachable, so a Governor can wire it as a gate.
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
import threading
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


# A streaming handler (the SLES SSE route) that is REACHED never finishes the
# response, so a plain TestClient request would block the sweep forever.  Each
# probe therefore runs on a daemon thread with a deadline; a probe that is still
# open when the deadline passes has, by definition, got past any auth gate and
# is reported as REACHABLE with the sentinel status below.  A 401 returns at
# once and never trips the deadline.
PROBE_DEADLINE_SECONDS = 3.0
STREAM_OPEN = -1  # sentinel status: handler reached and still streaming at the deadline


def _probe(client: TestClient, method: str, path: str) -> int:
    kwargs = {"json": {}} if method in {"POST", "PUT", "PATCH"} else {}
    result: list[int] = []

    def run() -> None:
        result.append(client.request(method, path, **kwargs).status_code)

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(PROBE_DEADLINE_SECONDS)
    return result[0] if result else STREAM_OPEN


def _probe_websocket(client: TestClient, path: str) -> int:
    """Anonymous websocket handshake: the HTTP status of the denial, or 101 if accepted."""
    from starlette.testclient import WebSocketDenialResponse
    from starlette.websockets import WebSocketDisconnect

    result: list[int] = []

    def run() -> None:
        try:
            with client.websocket_connect(path):
                result.append(101)
        except WebSocketDenialResponse as denial:  # handshake refused with an HTTP response
            result.append(denial.status_code)
        except WebSocketDisconnect as closed:  # accepted-or-not, then closed by the app
            result.append(101 if closed.code != 1008 else 403)

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(PROBE_DEADLINE_SECONDS)
    return result[0] if result else STREAM_OPEN


def _sweep(client: TestClient, routes: Iterable[APIRoute]) -> list[tuple[str, str, int]]:
    rows: list[tuple[str, str, int]] = []
    for route in routes:
        for method in sorted(route.methods or ()):
            if method in {"HEAD", "OPTIONS"}:
                continue
            rows.append((method, route.path, _probe(client, method, _fill(route.path))))
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
        shown = "open" if status == STREAM_OPEN else str(status)
        print(f"{method:<7}{path:<{width + 2}}{shown:<5}{verdict}")
    ws_reachable = 0
    for route in ws:
        status = _probe_websocket(client, _fill(route.path))
        verdict = "auth" if status in AUTH_STATUSES else "REACHABLE"
        if verdict == "REACHABLE":
            ws_reachable += 1
        print(f"WS     {route.path:<{width + 2}}{status:<5}{verdict}")

    reachable = sum(1 for _, _, s in rows if s not in AUTH_STATUSES)
    print(f"positive control GET /health without token: {control}")
    # Websockets ride on the verdict line so a reader of only the last line
    # cannot take "0 of N" as the whole surface.
    print(
        f"REACHABLE {reachable} of {len(rows)} EAP routes anonymously (non-401/403); "
        f"{ws_reachable} of {len(ws)} websocket route(s) reachable"
    )
    if expect_zero and (reachable or ws_reachable):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
