"""Unit tests for CodingAgentTelemetry FastAPI BFF proxy (SLCD-P5-1)."""
from fastapi.testclient import TestClient

from main import app


def test_coding_agent_telemetry_routes_mounted():
    """Assert the /api/v1/telemetry/coding-agents routes exist and are handled by FastAPI."""
    client = TestClient(app, raise_server_exceptions=False)
    # Requesting without signal-ingest running should return 502/upstream_unavailable
    # which proves the route is correctly mounted in FastAPI and forwarding upstream,
    # rather than 404 (route missing) or 405 (SPA catch-all).
    resp = client.post(
        "/api/v1/telemetry/coding-agents",
        json={"schema_version": "1.0.0"},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code in (502, 504, 200, 201, 400, 401)
    assert resp.status_code != 404
    assert resp.status_code != 405


def test_coding_agent_telemetry_aggregate_route_mounted():
    """Assert the aggregate endpoint is mounted and proxies upstream."""
    client = TestClient(app, raise_server_exceptions=False)
    resp = client.get(
        "/api/v1/telemetry/coding-agents/aggregate",
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code in (502, 504, 200, 401, 422)
    assert resp.status_code != 404
    assert resp.status_code != 405


def test_coding_agent_telemetry_v1_alias_routes_mounted():
    """Assert the /v1/telemetry/coding-agents alias routes exist and are handled by FastAPI."""
    client = TestClient(app, raise_server_exceptions=False)
    # Test POST /v1/telemetry/coding-agents
    resp = client.post(
        "/v1/telemetry/coding-agents",
        json={"schema_version": "1.0.0"},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp.status_code in (502, 504, 200, 201, 400, 401)
    assert resp.status_code != 404
    assert resp.status_code != 405

    # Test GET /v1/telemetry/coding-agents/aggregate
    resp_agg = client.get(
        "/v1/telemetry/coding-agents/aggregate",
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp_agg.status_code in (502, 504, 200, 401, 422)
    assert resp_agg.status_code != 404
    assert resp_agg.status_code != 405

    # Test POST /v1/telemetry/coding-agents/ordering
    resp_ord = client.post(
        "/v1/telemetry/coding-agents/ordering",
        json={"event_a": {}, "event_b": {}},
        headers={"Authorization": "Bearer test-token"},
    )
    assert resp_ord.status_code in (502, 504, 200, 400, 401, 422)
    assert resp_ord.status_code != 404
    assert resp_ord.status_code != 405
