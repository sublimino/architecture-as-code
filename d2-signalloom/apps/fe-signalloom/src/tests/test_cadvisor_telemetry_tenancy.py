"""The four cAdvisor telemetry routes are tenant-scoped, not merely authenticated.

A cAdvisor sample carries no tenant: the poller indexes by namespace and pod
name. So these routes were authenticated but cluster-wide, and an authenticated
tenant that knew or guessed another tenant's pod name could read its CPU and
memory series. ``docs/EAP/faq-and-limits.md`` carried that as a known limit.

The pod-to-tenant mapping is the pod's own ``signalloom.ai/tenant`` label, read
through ``claim_tenancy`` -- the same source the claim decision uses, so there
is one answer to "whose pod is this" rather than two that can disagree.

Two tenants throughout: a single-tenant fixture cannot detect a missing filter.
And two specific oracles are pinned, because each would leak existence even
with the obvious filter in place -- the 409 "ambiguous pod name" answer, and the
SSE stream, which bypasses the single-shot path entirely.
"""
from __future__ import annotations

from typing import Any

import pytest

import cadvisor_poller
from cadvisor_poller import AgentTelemetry
from tests.test_agent_discovery import bearer, client_for, token_for

ALICE_POD = "alice-agent-abc"
BOB_POD = "bob-agent-xyz"
SHARED_NAME = "agent-same-name"

NS_A = "tenant-a-agents"
NS_B = "tenant-b-agents"


def _telemetry(pod_name: str, namespace: str, millicores: float = 12.5) -> AgentTelemetry:
    return AgentTelemetry(
        pod_name=pod_name,
        namespace=namespace,
        millicores=millicores,
        memory_rss_mb=64.0,
        status="running",
        last_updated="2026-10-04T09:00:00Z",
    )


@pytest.fixture
def telemetry_estate(monkeypatch: pytest.MonkeyPatch):
    """A healthy poller holding one pod per tenant, plus a shared pod name."""
    poller = cadvisor_poller.GLOBAL_CADVISOR_POLLER
    cache = {
        f"{NS_A}/{ALICE_POD}": _telemetry(ALICE_POD, NS_A, 10.0),
        f"{NS_B}/{BOB_POD}": _telemetry(BOB_POD, NS_B, 20.0),
        f"{NS_A}/{SHARED_NAME}": _telemetry(SHARED_NAME, NS_A, 30.0),
        f"{NS_B}/{SHARED_NAME}": _telemetry(SHARED_NAME, NS_B, 40.0),
    }
    monkeypatch.setattr(poller, "telemetry_cache", cache, raising=False)
    monkeypatch.setattr(poller, "healthy", lambda: True)

    workloads: list[dict[str, Any]] = [
        {"id": ALICE_POD, "name": ALICE_POD, "namespace": NS_A, "tenant": "tenant-a", "model": "m"},
        {"id": BOB_POD, "name": BOB_POD, "namespace": NS_B, "tenant": "tenant-b", "model": "m"},
        {"id": SHARED_NAME, "name": SHARED_NAME, "namespace": NS_A, "tenant": "tenant-a", "model": "m"},
        {"id": SHARED_NAME, "name": SHARED_NAME, "namespace": NS_B, "tenant": "tenant-b", "model": "m"},
    ]

    async def _source() -> list[dict[str, Any]]:
        return list(workloads)

    monkeypatch.setattr(cadvisor_poller.claim_tenancy, "workload_source", _source)
    return workloads


class _NoDiscovery:
    """Stands in for httpx so client_for's stub never reaches the network."""

    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        pass

    async def __aenter__(self) -> "_NoDiscovery":
        return self

    async def __aexit__(self, *_args: Any) -> bool:
        return False

    async def get(self, *_args: Any, **_kwargs: Any):
        import httpx

        return httpx.Response(200, json={"agents": []})


@pytest.mark.parametrize("prefix", ["/api", "/api/v1"])
def test_a_tenant_reads_its_own_pods_telemetry(monkeypatch, telemetry_estate, prefix):
    """The permission proof: without this, the refusals below would mean nothing."""
    with client_for(monkeypatch, _NoDiscovery) as client:
        response = client.get(f"{prefix}/telemetry/agents/{ALICE_POD}", headers=bearer(token_for("alice")))

    assert response.status_code == 200
    assert response.json()["pod_name"] == ALICE_POD
    assert response.json()["millicores"] == 10.0


@pytest.mark.parametrize("prefix", ["/api", "/api/v1"])
def test_addressing_another_tenants_pod_is_not_found_rather_than_forbidden(
    monkeypatch, telemetry_estate, prefix,
):
    """404, not 403: a refusal that distinguishes the two confirms the pod exists."""
    with client_for(monkeypatch, _NoDiscovery) as client:
        known = client.get(f"{prefix}/telemetry/agents/{BOB_POD}", headers=bearer(token_for("alice")))
        invented = client.get(f"{prefix}/telemetry/agents/no-such-pod", headers=bearer(token_for("alice")))

    assert known.status_code == 404
    assert invented.status_code == 404
    # Byte-identical, so the response cannot be used to enumerate pod names.
    assert known.json() == invented.json()


@pytest.mark.parametrize("prefix", ["/api", "/api/v1"])
def test_the_listing_returns_only_the_callers_own_pods(monkeypatch, telemetry_estate, prefix):
    with client_for(monkeypatch, _NoDiscovery) as client:
        alice = client.get(f"{prefix}/telemetry/agents", headers=bearer(token_for("alice"))).json()
        bob = client.get(f"{prefix}/telemetry/agents", headers=bearer(token_for("bob"))).json()

    assert sorted(alice) == sorted([f"{NS_A}/{ALICE_POD}", f"{NS_A}/{SHARED_NAME}"])
    assert sorted(bob) == sorted([f"{NS_B}/{BOB_POD}", f"{NS_B}/{SHARED_NAME}"])


def test_the_attack_succeeds_against_the_same_fixture_without_the_gate(monkeypatch, telemetry_estate):
    """Mechanism proof: the short lists above are the gate, not a small fixture."""
    async def _unrestricted(_principal):
        return None

    monkeypatch.setattr(cadvisor_poller, "_visible_pods", _unrestricted)

    with client_for(monkeypatch, _NoDiscovery) as client:
        alice = client.get("/api/telemetry/agents", headers=bearer(token_for("alice"))).json()

    assert len(alice) == 4, "the gate was not what produced the two-entry answer"


def test_a_shared_pod_name_does_not_leak_through_the_ambiguity_answer(
    monkeypatch, telemetry_estate,
):
    """The 409 is computed after the filter, so it cannot confirm the other pod.

    Both tenants run a pod called ``agent-same-name``. Were the ambiguity count
    taken before the tenant filter, alice would get 409 "exists in several
    namespaces", which tells her bob has one too.
    """
    with client_for(monkeypatch, _NoDiscovery) as client:
        response = client.get(
            f"/api/telemetry/agents/{SHARED_NAME}", headers=bearer(token_for("alice"))
        )

    assert response.status_code == 200
    body = response.json()
    assert body["namespace"] == NS_A
    assert body["millicores"] == 30.0


@pytest.mark.asyncio
async def test_the_stream_filters_per_item_so_it_is_not_a_second_unguarded_path(
    monkeypatch, telemetry_estate,
):
    """SSE bypasses the single-shot path entirely, so it gets its own check.

    Driven at the handler rather than over HTTP: the SSE generator is an
    unbounded ``while True`` by design, so a test client that consumed it would
    block on close rather than finish. What matters is the predicate, and the
    predicate is built from the same ``_visible_pods`` set the single-shot path
    uses -- asserted here so the two cannot drift apart.
    """
    import api_compat

    alice = api_compat.Principal(tenant="tenant-a", subject="alice", email=None)
    bob = api_compat.Principal(tenant="tenant-b", subject="bob", email=None)

    alice_visible = await cadvisor_poller._visible_pods(alice)
    bob_visible = await cadvisor_poller._visible_pods(bob)

    assert alice_visible == {(NS_A, ALICE_POD), (NS_A, SHARED_NAME)}
    assert bob_visible == {(NS_B, BOB_POD), (NS_B, SHARED_NAME)}

    # Both tenants run a pod called agent-same-name; neither set contains the
    # other's, so the stream's per-item check cannot emit the other's samples.
    assert (NS_B, SHARED_NAME) not in alice_visible
    assert (NS_A, SHARED_NAME) not in bob_visible


def test_the_stream_releases_its_subscription(monkeypatch, telemetry_estate):
    """A walked-away SSE client must not leak a queue on the poller."""
    poller = cadvisor_poller.GLOBAL_CADVISOR_POLLER
    before = poller.subscriber_count(ALICE_POD)
    queue, unsubscribe = poller.subscribe(ALICE_POD)
    assert poller.subscriber_count(ALICE_POD) == before + 1
    unsubscribe()
    assert poller.subscriber_count(ALICE_POD) == before


def test_a_superadmin_reads_every_tenants_telemetry(monkeypatch, telemetry_estate):
    import api_compat

    with client_for(monkeypatch, _NoDiscovery) as client:
        # Set inside the block: client_for installs its own two-subject map.
        monkeypatch.setattr(
            api_compat.settings,
            "api_subject_tenants",
            {"alice": "tenant-a", "bob": "tenant-b", "demo-user": "tenant-demo"},
        )
        body = client.get("/api/telemetry/agents", headers=bearer(token_for("demo-user"))).json()

    assert len(body) == 4


def test_unreadable_discovery_fails_the_gate_closed_not_open(monkeypatch, telemetry_estate):
    """An unavailable tenant map means the gate cannot be applied, so nothing is served."""
    async def _broken() -> list[dict[str, Any]]:
        import api_compat

        raise api_compat.APIError(
            503, "discovery_unavailable", "Workload discovery is unavailable; claims fail closed"
        )

    monkeypatch.setattr(cadvisor_poller.claim_tenancy, "workload_source", _broken)

    with client_for(monkeypatch, _NoDiscovery) as client:
        listing = client.get("/api/telemetry/agents", headers=bearer(token_for("alice")))
        single = client.get(f"/api/telemetry/agents/{ALICE_POD}", headers=bearer(token_for("alice")))

    assert listing.status_code == 503
    assert single.status_code == 503


def test_the_routes_still_refuse_an_unauthenticated_caller(monkeypatch, telemetry_estate):
    with client_for(monkeypatch, _NoDiscovery) as client:
        for path in (
            "/api/telemetry/agents",
            "/api/v1/telemetry/agents",
            f"/api/telemetry/agents/{ALICE_POD}",
            f"/api/v1/telemetry/agents/{ALICE_POD}",
        ):
            assert client.get(path).status_code == 401, path
