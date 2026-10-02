"""Policy bundle registration and rollback are audited, and never claimed when they did not happen.

Both change which policy governs a tenant's agents, and both happen in the Go
policy-engine, so fe-signalloom has no local write to bind an audit row to.
The row is written *before* the policy-engine is asked (see
``api_compat._audit_outbound_request``) and records the request and who made it.
"""
from __future__ import annotations

import hashlib
import json

import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient

import api_compat
from conftest import EAP_ALICE, EAP_TENANT_A, eap_bearer
from main import app
from routers.policy_engine import POLICY_ENGINE_URL

EAP_AUTHENTICATED = True

BUNDLE = {
    "framework_id": "eu-ai-act",
    "version": "v1.1.0",
    "rules": [{"id": "r1", "name": "Check", "cel_expression": "true"}],
}
ROLLBACK = {"framework_id": "eu-ai-act", "target_version": "v1.0.0"}


@pytest.fixture(autouse=True)
def clean_tenant():
    api_compat.reset_tenant_state(EAP_TENANT_A)
    yield
    api_compat.reset_tenant_state(EAP_TENANT_A)


def _rows(event_type: str) -> list[dict]:
    with api_compat._STORE_LOCK:
        return [e for e in api_compat._AUDIT_EVENTS.get(EAP_TENANT_A, []) if e["event_type"] == event_type]


async def _post(path: str, payload: dict) -> httpx.Response:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        return await client.post(path, content=json.dumps(payload), headers={
            **eap_bearer(EAP_ALICE), "Content-Type": "application/json",
        })


@pytest.mark.asyncio
async def test_bundle_submission_is_audited_before_the_policy_engine_is_asked():
    rows_when_asked: list[int] = []

    def upstream(request: httpx.Request) -> httpx.Response:
        rows_when_asked.append(len(_rows("policy.bundle_submitted")))
        return httpx.Response(201, json={**BUNDLE, "id": "eu-ai-act-v1.1.0"})

    with respx.mock(assert_all_called=True) as mock:
        route = mock.post(f"{POLICY_ENGINE_URL}/api/v1/policies/bundles").mock(side_effect=upstream)
        response = await _post("/api/v1/policies/bundles", BUNDLE)

    assert response.status_code == 201, response.text
    assert rows_when_asked == [1]
    (row,) = _rows("policy.bundle_submitted")
    assert row["actor"] == EAP_ALICE
    assert row["detail"] == {
        "framework_id": "eu-ai-act",
        "version": "v1.1.0",
        "rule_count": 1,
        "bundle_sha256": hashlib.sha256(route.calls.last.request.content).hexdigest(),
    }


@pytest.mark.asyncio
async def test_rollback_request_is_audited_before_the_policy_engine_is_asked():
    rows_when_asked: list[int] = []

    def upstream(request: httpx.Request) -> httpx.Response:
        rows_when_asked.append(len(_rows("policy.rollback_requested")))
        return httpx.Response(200, json={"framework_id": "eu-ai-act", "version": "v1.0.0"})

    with respx.mock(assert_all_called=True) as mock:
        mock.post(f"{POLICY_ENGINE_URL}/api/v1/policies/rollback").mock(side_effect=upstream)
        response = await _post("/api/v1/policies/rollback", ROLLBACK)

    assert response.status_code == 200, response.text
    assert rows_when_asked == [1]
    (row,) = _rows("policy.rollback_requested")
    assert row["actor"] == EAP_ALICE
    assert row["detail"] == {"framework_id": "eu-ai-act", "target_version": "v1.0.0"}


@pytest.mark.asyncio
@pytest.mark.parametrize("payload, missing", [
    ({"target_version": "v1.0.0"}, "framework_id"),
    ({"framework_id": "eu-ai-act"}, "target_version"),
    ({"framework_id": 7, "target_version": "v1.0.0"}, "framework_id"),
])
async def test_rollback_without_a_target_is_rejected_unaudited(payload, missing):
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post(f"{POLICY_ENGINE_URL}/api/v1/policies/rollback")
        response = await _post("/api/v1/policies/rollback", payload)

    assert response.status_code == 400
    assert response.json()["error"] == {"code": "invalid_rollback", "message": f"{missing} is required"}
    assert not route.called
    assert _rows("policy.rollback_requested") == []


@pytest.mark.asyncio
async def test_bundle_failing_cel_validation_is_rejected_unaudited():
    broken = {**BUNDLE, "rules": [{"id": "r1", "cel_expression": "1 +"}]}
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post(f"{POLICY_ENGINE_URL}/api/v1/policies/bundles")
        response = await _post("/api/v1/policies/bundles", broken)

    assert response.status_code == 422
    assert not route.called
    assert _rows("policy.bundle_submitted") == []


@pytest.mark.asyncio
async def test_bundle_is_not_reported_created_when_the_policy_engine_is_unreachable():
    with respx.mock(assert_all_called=True) as mock:
        mock.post(f"{POLICY_ENGINE_URL}/api/v1/policies/bundles").mock(
            side_effect=httpx.ConnectError("refused")
        )
        response = await _post("/api/v1/policies/bundles", BUNDLE)

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "upstream_unavailable"


@pytest.mark.asyncio
@pytest.mark.parametrize("path, payload", [
    ("/api/v1/policies/bundles", BUNDLE),
    ("/api/v1/policies/rollback", ROLLBACK),
])
async def test_policy_change_is_refused_when_the_audit_database_is_down(monkeypatch, path, payload):
    async def no_pool() -> None:
        return None

    monkeypatch.setattr(api_compat.settings, "database_url", "postgresql://unused:unused@127.0.0.1:1/unused")
    monkeypatch.setattr(api_compat, "_get_pool", no_pool)
    with respx.mock(assert_all_called=False) as mock:
        route = mock.post(f"{POLICY_ENGINE_URL}{path}")
        response = await _post(path, payload)

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "database_unavailable"
    assert not route.called
    with api_compat._STORE_LOCK:
        assert api_compat._AUDIT_EVENTS.get(EAP_TENANT_A, []) == []
