"""A lifecycle transition for an agent that does not exist is refused, and recorded as refused.

routers/agents.py used to treat a missing agent as `registered`: with a database
it audited `agent.transitioned` "registered -> X" for a row it never found, and
without one it synthesised the agent and moved it. Both answered 200, so the
audit trail carried transitions that never happened. The attempt is still worth
a record, so the row stays, but as `agent.transition_failed` with outcome
`not_found`, and the caller gets 404.
"""
from __future__ import annotations

from contextlib import asynccontextmanager
from typing import Any

import pytest
from fastapi.testclient import TestClient

import api_compat
from conftest import EAP_ALICE, EAP_TENANT_A, eap_bearer
from main import app

EAP_AUTHENTICATED = True

PATH = "/api/v1/agents/{agent_id}/transition"
BODY = {"to_state": "governed", "reason": "operator check"}


class _NoAgentPool:
    """A pool whose agent_registry holds no rows; records every statement."""

    def __init__(self) -> None:
        self.statements: list[tuple[str, tuple[Any, ...]]] = []

    async def fetchrow(self, query: str, *args: Any) -> None:
        self.statements.append((query, args))
        return None

    async def fetch(self, query: str, *args: Any) -> list[Any]:
        self.statements.append((query, args))
        return []

    async def execute(self, query: str, *args: Any) -> str:
        self.statements.append((query, args))
        return "OK"

    @asynccontextmanager
    async def acquire(self):
        yield self

    @asynccontextmanager
    async def transaction(self):
        yield self


@pytest.fixture(autouse=True)
def clean_tenant():
    api_compat.reset_tenant_state(EAP_TENANT_A)
    yield
    api_compat.reset_tenant_state(EAP_TENANT_A)


def _client() -> TestClient:
    return TestClient(app, raise_server_exceptions=False)


def _assert_not_found(response, agent_id: str) -> None:
    assert response.status_code == 404, response.text
    assert response.json()["error"]["code"] == "agent_not_found"
    assert agent_id in response.json()["error"]["message"]


def test_unknown_agent_transition_is_404_and_audited_as_failed_with_a_database(monkeypatch) -> None:
    pool = _NoAgentPool()

    async def get_pool() -> _NoAgentPool:
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    response = _client().post(PATH.format(agent_id="ghost-agent"), json=BODY, headers=eap_bearer())

    _assert_not_found(response, "ghost-agent")
    writes = [(q, a) for q, a in pool.statements if q.lstrip().upper().startswith(("INSERT", "UPDATE"))]
    assert not any("agent_registry" in q for q, _ in writes), writes
    audits = [a for q, a in writes if "audit_events" in q]
    assert len(audits) == 1, writes
    assert "agent.transition_failed" in audits[0]
    assert "agent.transitioned" not in audits[0]
    assert any('"outcome": "not_found"' in str(arg) for arg in audits[0]), audits[0]


def test_unknown_agent_transition_is_404_and_audited_as_failed_without_a_database() -> None:
    response = _client().post(PATH.format(agent_id="ghost-agent"), json=BODY, headers=eap_bearer())

    _assert_not_found(response, "ghost-agent")
    with api_compat._STORE_LOCK:
        assert "ghost-agent" not in api_compat._AGENTS.get(EAP_TENANT_A, {})
        events = list(api_compat._AUDIT_EVENTS.get(EAP_TENANT_A, []))
    assert [e["event_type"] for e in events] == ["agent.transition_failed"]
    assert events[0]["actor"] == EAP_ALICE
    assert events[0]["detail"]["outcome"] == "not_found"
    assert events[0]["detail"]["to_state"] == "governed"
