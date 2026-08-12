"""Prove the standalone demo-runner app stays narrow and dependency-light.

These tests exist because the dedicated demo-runner workload must expose only
the SuperCred orchestration surface while reusing the shared error handlers.
The threat model is accidental widening: importing the wrong app could publish
business routes or trigger database startup side effects that the runner pod
must never own.
"""
from __future__ import annotations

from fastapi.testclient import TestClient

from demo_runner_main import app


def test_demo_runner_main_exposes_only_demo_runner_and_probe_routes() -> None:
    # The published OpenAPI paths, not app.routes: this FastAPI version keeps an
    # included router as a single opaque _IncludedRouter entry with no .path, so
    # walking app.routes cannot see the demo endpoints at all. The OpenAPI
    # document is also the stronger assertion -- it is the surface a client can
    # actually reach.
    route_paths = set(app.openapi()["paths"])

    # Equality, not membership: the threat model here is accidental WIDENING,
    # and a set of `in` checks passes just as happily when thirty business
    # routes have been published alongside the six intended ones.
    assert route_paths == {
        "/api/demo/supercred/steps",
        "/api/demo/supercred/runs",
        "/api/demo/supercred/runs/{run_id}",
        "/api/demo/supercred/runs/{run_id}/log",
        "/api/demo/supercred/reset",
        "/api/demo/supercred/status",
        # Read-only evidence probe backing the dashboard's Credential
        # Lifecycle card. Listed explicitly because this set is a security
        # surface: a route appearing here without a deliberate edit is
        # exactly what this test exists to catch.
        "/api/demo/supercred/evidence",
        "/health",
        "/readyz",
    }


def test_demo_runner_main_health_and_readyz_need_no_database() -> None:
    with TestClient(app, raise_server_exceptions=False) as client:
        assert client.get("/health").json() == {"status": "ok"}
        assert client.get("/readyz").json() == {"status": "ready"}
        assert client.get("/api/agents").status_code == 404
