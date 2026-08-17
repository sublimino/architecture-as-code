"""Prove the standalone demo-runner app stays narrow and dependency-light.

These tests exist because the dedicated demo-runner workload must expose only
the SuperCred orchestration surface while reusing the shared error handlers.
The threat model is accidental widening: importing the wrong app could publish
business routes or trigger database startup side effects that the runner pod
must never own.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import demo_runner
from demo_runner_main import app

SINK_URL = "http://fe-signalloom-api.fe-signalloom.svc.cluster.local:8000"


@pytest.fixture(autouse=True)
def _configured_sink(monkeypatch: pytest.MonkeyPatch) -> None:
    """The deployed runner's configuration, which is now a readiness condition.

    Every test in this file predates the audit sink and none of them is about
    it, so the deployed value is supplied here rather than repeated. The one
    test that cares about its absence clears it explicitly.
    """
    monkeypatch.setenv(demo_runner._ENV_AUDIT_SINK, SINK_URL)


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
        # The SSE push route beside the poll route above. Same log, same
        # superadmin gate, different transport — and listed here deliberately,
        # because this set is the security surface and a route arriving in it
        # without an edit is what the assertion exists to catch.
        "/api/demo/supercred/runs/{run_id}/stream",
        "/api/demo/supercred/reset",
        "/api/demo/supercred/status",
        # Read-only evidence probe backing the dashboard's Credential
        # Lifecycle card. Listed explicitly because this set is a security
        # surface: a route appearing here without a deliberate edit is
        # exactly what this test exists to catch.
        "/api/demo/supercred/evidence",
        # Signal Fusion demo runner — same infrastructure, different step
        # registry and script. Shares the mutation lock and run state with
        # SuperCred because both mutate the same cluster.
        "/api/demo/signalfusion/steps",
        "/api/demo/signalfusion/runs",
        "/api/demo/signalfusion/runs/{run_id}",
        "/api/demo/signalfusion/runs/{run_id}/log",
        "/api/demo/signalfusion/runs/{run_id}/stream",
        "/api/demo/signalfusion/reset",
        "/api/demo/signalfusion/status",
        "/health",
        "/readyz",
    }


def test_demo_runner_main_health_and_readyz_need_no_database() -> None:
    with TestClient(app, raise_server_exceptions=False) as client:
        assert client.get("/health").json() == {"status": "ok"}
        assert client.get("/readyz").json() == {"status": "ready"}
        assert client.get("/api/agents").status_code == 404


def test_readyz_refuses_a_runner_with_nowhere_durable_to_audit(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The one state a deployed runner must never serve traffic in.

    This workload has no database by design, so its privileged-invocation
    records are forwarded to fe-signalloom. With no sink configured there is
    nowhere for them to go, and the fallback is an in-process dict that dies
    with the pod -- which is the defect the server-side audit trail was built
    to remove. It cannot be detected from a request: the runs still return 202
    and the audit simply is not there.

    So it is made a readiness condition instead. A misconfigured runner never
    joins its Service, the rollout stalls visibly, and nobody drives a
    privileged phase through a pod that cannot record it. Failing closed at
    the probe is the only place this is loud.
    """
    monkeypatch.delenv(demo_runner._ENV_AUDIT_SINK, raising=False)

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get("/readyz")

        assert response.status_code == 503, response.text
        assert response.json()["status"] == "not_ready"
        # Liveness must still pass: the process is healthy, its configuration
        # is not. A failing liveness probe would restart-loop the pod and hide
        # the reason behind a CrashLoopBackOff.
        assert client.get("/health").status_code == 200
