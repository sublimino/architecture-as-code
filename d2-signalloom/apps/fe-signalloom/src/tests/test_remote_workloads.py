"""Remote-cluster workloads on /api/agents, and the tenant gate over the list.

Two things are pinned here and they are different claims.

*Discovery* (``fleet_workloads``): fleet-manager's workload registry is read
through the existing caller-key path and merged into ``/api/agents`` as
``origin: "remote"`` records with the contract's fields, with stable
``cluster_id/namespace/name`` ids, and the agent detail path degrades rather
than inventing a local pod or a cAdvisor sample for a pod on another cluster.
The fleet-manager endpoint is being built in parallel, so every test here
drives a fake that answers the contract shape
(``docs/EAP/remote-contract.md``).

*Tenancy*: the agent list used to be the one surface in the portal that was not
a tenant boundary, which the pilot docs carried as a CAUTION. Two tenants are
always used, because a single-tenant fixture cannot detect a missing filter:
every row it can return is the caller's own.
"""
from __future__ import annotations

from typing import Any

import httpx
import pytest

import api_compat
import fleet_workloads
from tests.test_agent_discovery import bearer, client_for, token_for

CLUSTER = "kusari-prod"

#: One pod record in the shape the warden reports and fleet-manager serves.
REMOTE_POD: dict[str, Any] = {
    "cluster_id": CLUSTER,
    "node": "ip-10-0-1-7",
    "namespace": "payments",
    "name": "agent-x-7d6-abc",
    "uid": "11111111-2222-3333-4444-555555555555",
    "owner": {"kind": "Deployment", "name": "agent-x"},
    "tenant": "tenant-a",
    "labels": {"signalloom.ai/agent": "true", "signalloom.ai/model": "deterministic"},
    "frozen": False,
    "reported_at": "2026-10-04T09:00:00Z",
}


def _other_tenant_pod() -> dict[str, Any]:
    return {**REMOTE_POD, "name": "agent-y-000-zzz", "tenant": "tenant-b"}


class _FakeFleetManager:
    """Answers the central discovery URL and the fleet workloads URL.

    One class for both because ``agents()`` reads them through the same
    ``httpx.AsyncClient`` symbol, which the shared ``client_for`` fixture
    monkeypatches.
    """

    pods: list[dict[str, Any]] = []
    central: list[dict[str, Any]] = []
    status: int = 200
    envelope: str = "workloads"
    calls: list[str] = []

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        pass

    async def __aenter__(self) -> "_FakeFleetManager":
        return self

    async def __aexit__(self, *_args: Any) -> bool:
        return False

    async def get(self, url: str, params: Any = None, headers: Any = None) -> httpx.Response:
        type(self).calls.append(url)
        if "/api/v1/fleet/workloads" in url:
            # The read scope is presented as a caller key, never as a cookie or
            # a query parameter: assert it rather than trusting it.
            assert headers and headers.get("Authorization", "").startswith("Bearer ")
            if type(self).status != 200:
                return httpx.Response(type(self).status, json={})
            return httpx.Response(200, json={type(self).envelope: list(type(self).pods)})
        return httpx.Response(200, json={"agents": list(type(self).central)})


@pytest.fixture
def remote_registry(monkeypatch: pytest.MonkeyPatch):
    """Configure the portal to read one remote cluster, and reset the fake."""
    monkeypatch.setenv(fleet_workloads.FLEET_MANAGER_READ_KEY_ENV, "test-read-key")
    monkeypatch.setenv(fleet_workloads.FLEET_REMOTE_CLUSTERS_ENV, CLUSTER)
    _FakeFleetManager.pods = []
    _FakeFleetManager.central = []
    _FakeFleetManager.status = 200
    _FakeFleetManager.envelope = "workloads"
    _FakeFleetManager.calls = []
    return _FakeFleetManager


def _remote_agents(body: dict[str, Any]) -> list[dict[str, Any]]:
    return [a for a in body["agents"] if a.get("origin") == fleet_workloads.REMOTE_ORIGIN]


# ---------------------------------------------------------------------------
# normalize(): the record shape, decided without any HTTP
# ---------------------------------------------------------------------------


def test_a_registry_record_becomes_a_discovery_shaped_record_with_remote_fields():
    out = fleet_workloads.normalize(REMOTE_POD)
    assert out is not None
    assert out["id"] == f"remote:{CLUSTER}/payments/agent-x-7d6-abc"
    assert out["origin"] == "remote"
    assert out["cluster_id"] == CLUSTER
    assert out["pod"] == "agent-x-7d6-abc"
    assert out["namespace"] == "payments"
    assert out["tenant"] == "tenant-a"
    assert out["frozen"] is False
    # The model comes from the pod's own label; the portal never invents one.
    assert out["model"] == "deterministic"
    assert out["owner_kind"] == "Deployment"
    assert out["owner_name"] == "agent-x"


def test_the_id_is_cluster_namespace_name_so_it_is_stable_and_cannot_collide():
    a = fleet_workloads.normalize({**REMOTE_POD, "cluster_id": "one"})
    b = fleet_workloads.normalize({**REMOTE_POD, "cluster_id": "two"})
    assert a is not None and b is not None
    # Same namespace and name on two clusters are two different agents.
    assert a["id"] != b["id"]
    # And neither can be mistaken for a central discovery id or a registry UUID.
    assert a["id"].startswith(fleet_workloads.REMOTE_ID_PREFIX)


def test_a_record_without_a_stable_id_is_dropped_rather_than_shown_once():
    # No name, no namespace, no cluster: each alone makes the record
    # unaddressable, and a row that cannot be addressed again would appear and
    # disappear between polls.
    assert fleet_workloads.normalize({**REMOTE_POD, "name": ""}) is None
    assert fleet_workloads.normalize({**REMOTE_POD, "namespace": ""}) is None
    assert fleet_workloads.normalize({**REMOTE_POD, "cluster_id": ""}) is None


def test_a_record_with_no_reported_tenant_is_unattributed_not_guessed():
    out = fleet_workloads.normalize({k: v for k, v in REMOTE_POD.items() if k != "tenant"})
    assert out is not None
    assert out["tenant"] == fleet_workloads.UNATTRIBUTED_TENANT


def test_frozen_true_is_kernel_frozen_and_absent_is_unknown_never_running():
    frozen = fleet_workloads.normalize({**REMOTE_POD, "frozen": True})
    plain = fleet_workloads.normalize({**REMOTE_POD, "frozen": False})
    assert frozen is not None and plain is not None
    assert frozen["kernel_state"] == "frozen"
    # A registry that has not reported a freeze is not evidence of a thaw.
    assert plain["kernel_state"] == "unknown"


# ---------------------------------------------------------------------------
# /api/agents: the merge
# ---------------------------------------------------------------------------


def test_a_remote_workload_appears_on_the_agent_list_as_a_remote_origin_record(
    monkeypatch, remote_registry,
):
    remote_registry.pods = [REMOTE_POD]

    with client_for(monkeypatch, remote_registry) as client:
        body = client.get("/api/agents", headers=bearer(token_for("alice"))).json()

    remote = _remote_agents(body)
    assert len(remote) == 1
    agent = remote[0]
    assert agent["id"] == f"remote:{CLUSTER}/payments/agent-x-7d6-abc"
    assert agent["cluster_id"] == CLUSTER
    assert agent["pod"] == "agent-x-7d6-abc"
    assert agent["frozen"] is False
    assert agent["record_class"] == "discovered"
    # Never registry-linked: fleet-manager's registry is an inventory, not a
    # governance record, and no flow in this tree claims a remote pod.
    assert agent["is_registry_linked"] is False
    # The reported cluster, not this one: the field a reader uses to decide
    # which cluster to go and look at must not be fabricated.
    assert agent["runtime"]["cluster_id"] == CLUSTER


def test_a_central_agent_reports_no_remote_fields_so_the_two_are_distinguishable(
    monkeypatch, remote_registry,
):
    remote_registry.central = [{"id": "pod-local", "name": "local", "tenant": "tenant-a"}]

    with client_for(monkeypatch, remote_registry) as client:
        body = client.get("/api/agents", headers=bearer(token_for("alice"))).json()

    local = [a for a in body["agents"] if a["id"] == "pod-local"]
    assert len(local) == 1
    assert local[0]["cluster_id"] is None
    assert local[0]["pod"] is None
    assert local[0]["frozen"] is None


def test_an_unreadable_registry_degrades_the_source_and_keeps_the_central_agents(
    monkeypatch, remote_registry,
):
    """A pilot cluster being unreachable is somebody else's network, not an outage here."""
    remote_registry.status = 503
    remote_registry.central = [{"id": "pod-local", "name": "local", "tenant": "tenant-a"}]

    with client_for(monkeypatch, remote_registry) as client:
        response = client.get("/api/agents", headers=bearer(token_for("alice")))

    assert response.status_code == 200
    body = response.json()
    assert [a["id"] for a in body["agents"]] == ["pod-local"]
    assert body["source_health_detail"]["remote_registry"]["status"] == "error"
    # The central list is what the page is mostly for; it must not vanish
    # because a remote VPN dropped.
    assert body["source_health"] == "healthy"


def test_without_a_read_key_the_registry_is_unavailable_not_reported_empty(
    monkeypatch, remote_registry,
):
    monkeypatch.delenv(fleet_workloads.FLEET_MANAGER_READ_KEY_ENV, raising=False)
    remote_registry.pods = [REMOTE_POD]

    with client_for(monkeypatch, remote_registry) as client:
        body = client.get("/api/agents", headers=bearer(token_for("alice"))).json()

    assert _remote_agents(body) == []
    detail = body["source_health_detail"]["remote_registry"]
    # "No remote workloads" and "the portal cannot read the registry" are
    # different facts and the pilot has to be able to tell them apart.
    assert detail["status"] == "unavailable"
    assert fleet_workloads.FLEET_MANAGER_READ_KEY_ENV in detail["message"]
    # And nothing was asked of fleet-manager without a key to present.
    assert not [c for c in remote_registry.calls if "/fleet/workloads" in c]


@pytest.mark.parametrize("envelope", ["workloads", "pods", "items"])
def test_the_registry_envelope_key_is_read_defensively(monkeypatch, remote_registry, envelope):
    """fleet-manager owns the Go side; neither side has to land first."""
    remote_registry.envelope = envelope
    remote_registry.pods = [REMOTE_POD]

    with client_for(monkeypatch, remote_registry) as client:
        body = client.get("/api/agents", headers=bearer(token_for("alice"))).json()

    assert len(_remote_agents(body)) == 1


def test_a_remote_agents_detail_degrades_rather_than_inventing_a_local_pod(
    monkeypatch, remote_registry,
):
    """No cAdvisor sample and no local pod object exist for a pod on another cluster."""
    remote_registry.pods = [REMOTE_POD]
    remote_id = f"remote:{CLUSTER}/payments/agent-x-7d6-abc"

    with client_for(monkeypatch, remote_registry) as client:
        token = bearer(token_for("alice"))
        detail = client.get(f"/api/agents/{remote_id}", headers=token)
        telemetry = client.get(f"/api/agents/{remote_id}/telemetry", headers=token)

    # The dossier must not 500, and it must not answer with a fabricated agent.
    assert detail.status_code in (200, 404)
    if detail.status_code == 200:
        assert detail.json().get("cluster_id") == CLUSTER
    # Telemetry for a remote pod is genuinely absent: a refusal or an empty
    # series, never a sample attributed to a pod this cluster cannot see.
    assert telemetry.status_code in (200, 404, 503)
    if telemetry.status_code == 200:
        assert telemetry.json().get("observations") in ([], None)


# ---------------------------------------------------------------------------
# /api/agents: the tenant gate, over all three record kinds
# ---------------------------------------------------------------------------


def test_a_tenant_does_not_see_another_tenants_remote_workload(monkeypatch, remote_registry):
    remote_registry.pods = [REMOTE_POD, _other_tenant_pod()]

    with client_for(monkeypatch, remote_registry) as client:
        alice = client.get("/api/agents", headers=bearer(token_for("alice"))).json()
        bob = client.get("/api/agents", headers=bearer(token_for("bob"))).json()

    assert [a["pod"] for a in _remote_agents(alice)] == ["agent-x-7d6-abc"]
    assert [a["pod"] for a in _remote_agents(bob)] == ["agent-y-000-zzz"]


def test_a_tenant_does_not_see_another_tenants_discovered_workload(monkeypatch, remote_registry):
    remote_registry.central = [
        {"id": "pod-a", "name": "a", "tenant": "tenant-a"},
        {"id": "pod-b", "name": "b", "tenant": "tenant-b"},
    ]

    with client_for(monkeypatch, remote_registry) as client:
        alice = client.get("/api/agents", headers=bearer(token_for("alice"))).json()
        bob = client.get("/api/agents", headers=bearer(token_for("bob"))).json()

    assert [a["id"] for a in alice["agents"]] == ["pod-a"]
    assert [a["id"] for a in bob["agents"]] == ["pod-b"]


def test_the_attack_would_succeed_without_the_filter(monkeypatch, remote_registry):
    """Mechanism proof: the single-row answers above are the filter, not the fixture.

    Without this, a fixture that only ever returned one workload would pass the
    two tests above while the filter did nothing.
    """
    remote_registry.central = [
        {"id": "pod-a", "name": "a", "tenant": "tenant-a"},
        {"id": "pod-b", "name": "b", "tenant": "tenant-b"},
    ]
    monkeypatch.setattr(api_compat, "_visible_to_tenant", lambda *_a, **_k: True)

    with client_for(monkeypatch, remote_registry) as client:
        alice = client.get("/api/agents", headers=bearer(token_for("alice"))).json()

    assert sorted(a["id"] for a in alice["agents"]) == ["pod-a", "pod-b"]


def test_a_workload_declaring_no_tenant_is_shown_to_no_tenant_user(monkeypatch, remote_registry):
    """Deliberately hides the platform's own unlabelled agents, which were unclaimable anyway."""
    remote_registry.central = [{"id": "pod-orphan", "name": "orphan"}]

    with client_for(monkeypatch, remote_registry) as client:
        alice = client.get("/api/agents", headers=bearer(token_for("alice"))).json()

    assert alice["agents"] == []


def test_a_homoglyph_tenant_is_a_different_tenant(monkeypatch, remote_registry):
    """Exact string compare, the same rule claim_tenancy.authorize applies."""
    # Cyrillic "а" (U+0430) in place of the Latin one.
    remote_registry.central = [{"id": "pod-look-alike", "name": "x", "tenant": "tenant-а"}]

    with client_for(monkeypatch, remote_registry) as client:
        alice = client.get("/api/agents", headers=bearer(token_for("alice"))).json()

    assert alice["agents"] == []


def test_a_superadmin_sees_every_tenants_workloads(monkeypatch, remote_registry):
    """What makes the fleet and cross-tenant demo pages work at all."""
    remote_registry.central = [
        {"id": "pod-a", "name": "a", "tenant": "tenant-a"},
        {"id": "pod-b", "name": "b", "tenant": "tenant-b"},
    ]
    remote_registry.pods = [REMOTE_POD, _other_tenant_pod()]

    with client_for(monkeypatch, remote_registry) as client:
        # Set inside the block: client_for installs its own two-subject map, so
        # a demo-user mapping added before it would be overwritten and the
        # superadmin would be refused for want of a tenant, not for want of the
        # allow-list -- a false pass dressed as a 403.
        monkeypatch.setattr(
            api_compat.settings,
            "api_subject_tenants",
            {"alice": "tenant-a", "bob": "tenant-b", "demo-user": "tenant-demo"},
        )
        # Stated explicitly, not inherited: tests/test_eap_anonymous_surface.py
        # assigns settings.api_superadmin_emails/subjects directly rather than
        # through monkeypatch, so those defaults are gone for every module that
        # runs after it in a full session. A test that needs a superadmin has to
        # name one.
        monkeypatch.setattr(api_compat.settings, "api_superadmin_subjects", {"demo-user"})
        monkeypatch.setattr(api_compat.settings, "api_superadmin_emails", set())
        # No email claim is needed: the subject allow-list is enough.
        body = client.get("/api/agents", headers=bearer(token_for("demo-user"))).json()

    assert sorted(a["id"] for a in body["agents"] if a["id"].startswith("pod-")) == ["pod-a", "pod-b"]
    assert len(_remote_agents(body)) == 2


def test_superadmin_is_decided_from_the_token_not_from_the_request(monkeypatch, remote_registry):
    """A tenant user cannot acquire the unfiltered list by asking for it."""
    remote_registry.central = [
        {"id": "pod-a", "name": "a", "tenant": "tenant-a"},
        {"id": "pod-b", "name": "b", "tenant": "tenant-b"},
    ]

    with client_for(monkeypatch, remote_registry) as client:
        token = bearer(token_for("alice"))
        attempts = [
            client.get("/api/agents?superadmin=true", headers=token),
            client.get("/api/agents", headers={**token, "X-Superadmin": "true"}),
            client.get("/api/agents", headers={**token, "X-Tenant-Id": "tenant-b"}),
        ]

    for response in attempts:
        assert response.status_code == 200
        assert [a["id"] for a in response.json()["agents"]] == ["pod-a"]
