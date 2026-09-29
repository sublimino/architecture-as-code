"""Kernel freezer truth versus the control-plane stun record.

The stun-sentinel publishes the cgroup freezer state as pod annotations, which
fake-integration-proxy discovery carries as ``kernel_state`` and
``kernel_observed_at``. A pod the kernel has frozen with no stun record is a
split brain: the dashboard rendered three of them as idle and healthy for up to
22 days. fe-signalloom must pass the kernel view through verbatim and name the
disagreement, never infer ``frozen`` from any other field.
"""
from __future__ import annotations

import uuid
from typing import Any

import pytest

import api_compat
from api_compat import (
    ComplianceSummaryInline,
    _agent_response_from_discovered,
    _agent_response_from_row,
)
from tests.test_agent_discovery import bearer, client_for, token_for

FROZEN_NO_STUN = "kernel frozen without stun record"
STUN_NOT_FROZEN = "stun record without kernel freeze"
OBSERVED = "2026-09-07T10:00:00Z"


def _disc(state: str = "idle", kernel_state: str | None = "frozen", **extra: Any) -> dict[str, Any]:
    d: dict[str, Any] = {
        "id": "agent-sir-lancelot",
        "name": "agent-sir-lancelot",
        "namespace": "fe-signalloom-agents",
        "state": state,
        "phase": "Running",
        "service_account": "agent-sir-lancelot",
    }
    if kernel_state is not None:
        d["kernel_state"] = kernel_state
        d["kernel_observed_at"] = OBSERVED
    d.update(extra)
    return d


def _row(lifecycle_state: str = "active") -> dict[str, Any]:
    return {
        "id": str(uuid.uuid4()),
        "name": "agent-sir-lancelot",
        "type": "Custom",
        "origin": "Custom",
        "owner": "secops@acme.corp",
        "tenant_id": "tenant-a",
        "lifecycle_state": lifecycle_state,
        "last_transition_at": None,
        "eu_ai_act_risk_class": "limited",
        "model_name": "m",
        "created_at": "2026-09-01T00:00:00Z",
    }


def _compliance() -> ComplianceSummaryInline:
    return ComplianceSummaryInline(total_controls=0, passing=0, failing=0, pending=0, posture_score=None)


class TestDiscoveredAgent:
    def test_idle_but_kernel_frozen_is_split_brain(self) -> None:
        resp = _agent_response_from_discovered(_disc(), tenant_id="tenant-a")
        assert resp.kernel_state == "frozen"
        assert resp.kernel_observed_at == OBSERVED
        assert resp.split_brain == [FROZEN_NO_STUN]
        assert resp.attention is not None
        assert resp.attention.level == "critical"
        assert resp.attention.highest_issue == FROZEN_NO_STUN
        assert resp.operational_state is not None
        assert resp.operational_state.runtime_status != "running"

    def test_stunned_and_kernel_frozen_agrees(self) -> None:
        resp = _agent_response_from_discovered(
            _disc(state="stunned", stunned_at="2026-09-01T00:00:00Z"), tenant_id="tenant-a",
        )
        assert resp.kernel_state == "frozen"
        assert resp.split_brain == []

    def test_stunned_but_kernel_running_is_the_mirror_split_brain(self) -> None:
        resp = _agent_response_from_discovered(
            _disc(state="stunned", kernel_state="running", stunned_at="2026-09-01T00:00:00Z"),
            tenant_id="tenant-a",
        )
        assert resp.kernel_state == "running"
        assert resp.split_brain == [STUN_NOT_FROZEN]

    def test_absent_kernel_observation_is_unknown_and_quiet(self) -> None:
        resp = _agent_response_from_discovered(_disc(kernel_state=None), tenant_id="tenant-a")
        assert resp.kernel_state == "unknown"
        assert resp.kernel_observed_at is None
        assert resp.split_brain == []

    def test_stunned_with_unknown_kernel_is_not_split_brain(self) -> None:
        resp = _agent_response_from_discovered(
            _disc(state="stunned", kernel_state=None, stunned_at="2026-09-01T00:00:00Z"),
            tenant_id="tenant-a",
        )
        assert resp.kernel_state == "unknown"
        assert resp.split_brain == []

    def test_garbage_kernel_state_is_unknown(self) -> None:
        resp = _agent_response_from_discovered(_disc(kernel_state="thawing"), tenant_id="tenant-a")
        assert resp.kernel_state == "unknown"
        assert resp.split_brain == []


class TestRegistryRow:
    def test_active_row_with_frozen_overlay_is_split_brain(self) -> None:
        resp = _agent_response_from_row(_row("active"), _compliance(), discovered_overlay=_disc())
        assert resp.kernel_state == "frozen"
        assert resp.split_brain == [FROZEN_NO_STUN]
        assert resp.attention is not None and resp.attention.level == "critical"

    def test_suspended_row_with_frozen_overlay_agrees(self) -> None:
        resp = _agent_response_from_row(_row("suspended"), _compliance(), discovered_overlay=_disc())
        assert resp.split_brain == []
        assert resp.kernel_state == "frozen"

    def test_suspended_row_without_observation_never_infers_frozen(self) -> None:
        resp = _agent_response_from_row(_row("suspended"), _compliance(), discovered_overlay=None)
        assert resp.kernel_state == "unknown"
        assert resp.split_brain == []


class _FakeDiscovery:
    agents: list[dict[str, Any]] = []

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    async def __aenter__(self) -> "_FakeDiscovery":
        return self

    async def __aexit__(self, *exc: Any) -> bool:
        return False

    async def get(self, url: str) -> Any:
        payload = {"agents": list(type(self).agents)}

        class _R:
            status_code = 200

            def raise_for_status(self) -> None:
                return None

            def json(self) -> Any:
                return payload

        return _R()


@pytest.fixture
def frozen_discovery() -> type[_FakeDiscovery]:
    _FakeDiscovery.agents = [_disc()]
    return _FakeDiscovery


def test_agents_list_exposes_kernel_state_and_split_brain(monkeypatch, frozen_discovery) -> None:
    with client_for(monkeypatch, frozen_discovery) as client:
        body = client.get("/api/agents", headers=bearer(token_for())).json()
    agent = next(a for a in body["agents"] if a["id"] == "agent-sir-lancelot")
    assert agent["kernel_state"] == "frozen"
    assert agent["kernel_observed_at"] == OBSERVED
    assert agent["split_brain"] == [FROZEN_NO_STUN]


def test_agents_attention_filter_surfaces_split_brain(monkeypatch, frozen_discovery) -> None:
    with client_for(monkeypatch, frozen_discovery) as client:
        body = client.get("/api/agents?attention=critical", headers=bearer(token_for())).json()
    assert "agent-sir-lancelot" in {a["id"] for a in body["agents"]}


def test_agent_detail_exposes_kernel_state(monkeypatch, frozen_discovery) -> None:
    with client_for(monkeypatch, frozen_discovery) as client:
        resp = client.get("/api/agents/agent-sir-lancelot", headers=bearer(token_for()))
    assert resp.status_code == 200
    body = resp.json()
    assert body["kernel_state"] == "frozen"
    assert body["split_brain"] == [FROZEN_NO_STUN]


def test_discovery_workloads_overlay_kernel_state(monkeypatch, frozen_discovery) -> None:
    with client_for(monkeypatch, frozen_discovery) as client:
        api_compat._ensure_seeded("tenant-a")
        with api_compat._STORE_LOCK:
            api_compat._AGENTS["tenant-a"]["agent-sir-lancelot"] = {
                "id": "agent-sir-lancelot",
                "name": "agent-sir-lancelot",
                "lifecycle_state": "active",
                "namespace": "fe-signalloom-agents",
            }
        body = client.get("/api/v1/discovery/workloads", headers=bearer(token_for())).json()
    by_id = {w["id"]: w for w in body["workloads"]}
    lancelot = by_id["agent-sir-lancelot"]
    assert lancelot["kernel_state"] == "frozen"
    assert lancelot["kernel_observed_at"] == OBSERVED
    assert lancelot["split_brain"] == [FROZEN_NO_STUN]
    others = [w for w in body["workloads"] if w["id"] != "agent-sir-lancelot"]
    assert others and all(w["kernel_state"] == "unknown" and w["split_brain"] == [] for w in others)
