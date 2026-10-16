"""GET /api/agents/{id} returns the agent that id names, or 404. Never a lookalike.

A dashboard deep link to ``agent_01FoEhnKF9QsC5DGmuELhm7G`` opened "Demo Agent
(Nono Evidenced)" (``agent-nono-evidenced-8b4674c45-67mmg``). The handler's
discovery correlation accepted a discovered workload whose id merely *started
with* the requested id, or whose service account equalled it, so a
deployment-name prefix, a shared service account such as ``default``, or an
empty id after stripping ``supercred:`` resolved to some other workload.

Both fixture mode (no pool) and live mode (a pool that finds no registry row)
are covered: the discovered-workload fallback is shared by both.
"""
from __future__ import annotations

from typing import Any

import pytest

import api_compat
from tests.test_agent_discovery import FakeDiscoveryResponse, bearer, client_for, token_for

NONO_POD = "agent-nono-evidenced-8b4674c45-67mmg"
REQUESTED = "agent_01FoEhnKF9QsC5DGmuELhm7G"


def _discovery_client(agents: list[dict[str, Any]]):
    class FakeAsyncClient:
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str) -> FakeDiscoveryResponse:
            return FakeDiscoveryResponse({"agents": agents})

    return FakeAsyncClient


DISCOVERED = [
    {
        "id": NONO_POD,
        "tenant": "tenant-a",
        "name": "Demo Agent (Nono Evidenced)",
        "service_account": "default",
        "type": "service",
        "state": "ready",
    },
]


class _EmptyLivePool:
    """A live pool with no registry rows: every read comes back empty."""

    async def fetchrow(self, *_a: Any, **_k: Any) -> None:
        return None

    async def fetch(self, *_a: Any, **_k: Any) -> list[Any]:
        return []

    async def fetchval(self, *_a: Any, **_k: Any) -> None:
        return None


def _go_live(monkeypatch: pytest.MonkeyPatch) -> None:
    pool = _EmptyLivePool()

    async def _live_pool():
        return pool

    async def _no_stuns(_tenant: str, _pool: Any) -> dict[str, dict[str, Any]]:
        return {}

    monkeypatch.setattr(api_compat, "_get_pool", _live_pool)
    monkeypatch.setattr(api_compat, "_latest_stun_index", _no_stuns)


# Each id names no agent. Before the fix, the last three resolved to NONO_POD.
NOT_AN_AGENT = [
    pytest.param(REQUESTED, id="unknown-anthropic-id"),
    pytest.param("agent-nono-evidenced", id="prefix-of-a-pod-id"),
    pytest.param("default", id="shared-service-account"),
    pytest.param("supercred:", id="empty-after-supercred-prefix"),
]


@pytest.mark.parametrize("mode", ["fixture", "live"])
@pytest.mark.parametrize("agent_id", NOT_AN_AGENT)
def test_unknown_or_partial_id_is_404_never_a_lookalike(monkeypatch, mode: str, agent_id: str) -> None:
    with client_for(monkeypatch, _discovery_client(DISCOVERED)) as client:
        if mode == "live":
            _go_live(monkeypatch)
        response = client.get(f"/api/agents/{agent_id}", headers=bearer(token_for()))

    assert response.status_code == 404, response.text
    assert NONO_POD not in response.text


@pytest.mark.parametrize("mode", ["fixture", "live"])
@pytest.mark.parametrize("agent_id", [NONO_POD, "Demo Agent (Nono Evidenced)"])
def test_exact_discovered_id_or_name_still_resolves(monkeypatch, mode: str, agent_id: str) -> None:
    with client_for(monkeypatch, _discovery_client(DISCOVERED)) as client:
        if mode == "live":
            _go_live(monkeypatch)
        response = client.get(f"/api/agents/{agent_id}", headers=bearer(token_for()))

    assert response.status_code == 200, response.text
    assert response.json()["id"] == NONO_POD
