"""The routers/ mutations fail closed when the audit database is configured but down.

routers/agents.py (lifecycle transition) and routers/discovery.py (workload
claim) each have a durable branch that audits on the write connection and a
no-pool branch that mutates the in-memory fixture store and audits with
``_record_memory_audit``.  Only a deliberate fixture deployment (no DSN) may take
the second branch.  A configured deployment whose database is unreachable must
answer 503 ``database_unavailable`` and change nothing, which is what
``api_compat._require_pool`` decides and ``_get_pool`` alone cannot.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from conftest import EAP_TENANT_A, eap_bearer
from main import app

EAP_AUTHENTICATED = True

DSN = "postgresql://unused:unused@127.0.0.1:1/unused"


@pytest.fixture
def unreachable_database(monkeypatch: pytest.MonkeyPatch) -> None:
    async def no_pool() -> None:
        return None

    monkeypatch.setattr(settings, "database_url", DSN)
    monkeypatch.setattr(api_compat, "_get_pool", no_pool)
    api_compat.reset_tenant_state(EAP_TENANT_A)
    yield
    api_compat.reset_tenant_state(EAP_TENANT_A)


def _memory_audit_types() -> list[str]:
    with api_compat._STORE_LOCK:
        return [e["event_type"] for e in api_compat._AUDIT_EVENTS.get(EAP_TENANT_A, [])]


def test_transition_answers_503_and_records_nothing_when_the_database_is_down(unreachable_database) -> None:
    client = TestClient(app, raise_server_exceptions=False)
    response = client.post(
        "/api/v1/agents/agent-x/transition",
        json={"to_state": "governed", "reason": "operator check"},
        headers=eap_bearer(),
    )
    assert response.status_code == 503, response.text
    assert response.json()["error"]["code"] == "database_unavailable"
    assert "agent.transitioned" not in _memory_audit_types()
    with api_compat._STORE_LOCK:
        assert "agent-x" not in api_compat._AGENTS.get(EAP_TENANT_A, {})


def test_claim_answers_503_and_records_nothing_when_the_database_is_down(unreachable_database) -> None:
    client = TestClient(app, raise_server_exceptions=False)
    response = client.post(
        "/api/v1/discovery/claim",
        json={"agent_id": "workload-x", "namespace": "fe-signalloom-agents"},
        headers=eap_bearer(),
    )
    assert response.status_code == 503, response.text
    assert response.json()["error"]["code"] == "database_unavailable"
    assert "agent.claimed" not in _memory_audit_types()
    with api_compat._STORE_LOCK:
        assert not api_compat._CLAIMS.get(EAP_TENANT_A)
