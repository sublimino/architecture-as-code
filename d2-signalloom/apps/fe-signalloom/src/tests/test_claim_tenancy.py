"""A claim binds a workload only into the tenant the platform declared for it.

The Kusari pilot's agent was claimed into tenant-demo with a fabricated
``claude-3-5-sonnet`` model: every claim path claimed into whoever asked, and
three of them invented the model. These tests drive the real endpoints with a
workload source in discovery's contract shape (fake-integration-proxy
``GET /agents``: ``id``, ``name``, ``agent_name``, ``namespace``, ``tenant``,
``model``) and assert the exact status and error code of every refusal.
"""
from __future__ import annotations

import socket
import time
from types import SimpleNamespace
from typing import Any

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import claim_tenancy
from agent_identity_map import AgentIdentity
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
NS = "fe-signalloom-agents"
KUSARI_OP = "kusari-operator"
DEMO_USER = "demo-claimant"
SUBJECT_TENANTS = {KUSARI_OP: "kusari", DEMO_USER: "tenant-demo"}

WORKLOADS: list[dict[str, Any]] = [
    {"id": "agent-kusari-abc", "name": "Kusari Agent (stub)", "agent_name": "kusari-agent",
     "namespace": NS, "tenant": "kusari", "model": "deterministic"},
    {"id": "demo-bot-1", "name": "demo-bot", "agent_name": "demo-bot",
     "namespace": NS, "tenant": "tenant-demo", "model": "openai/gpt-4o", "model_label": "gpt-4o"},
    {"id": "unlabelled-1", "name": "unlabelled", "agent_name": "unlabelled",
     "namespace": NS, "tenant": None, "model": "gpt-4o"},
    {"id": "nomodel-1", "name": "nomodel", "agent_name": "nomodel",
     "namespace": NS, "tenant": "kusari", "model": None},
    {"id": "homoglyph-1", "name": "homoglyph", "agent_name": "homoglyph",
     "namespace": NS, "tenant": "kusarі", "model": "deterministic"},
    {"id": "twin-a", "name": "twin", "agent_name": "twin", "namespace": NS, "tenant": "kusari", "model": "m"},
    {"id": "twin-b", "name": "twin", "agent_name": "twin", "namespace": NS, "tenant": "kusari", "model": "m"},
]


def _bearer(subject: str) -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {"iss": "https://issuer.test/dex", "aud": "signalloom-api", "iat": now, "nbf": now,
         "exp": now + 300, "azp": "signalloom-dashboard", "sub": subject,
         "email": f"{subject}@signalloom.test"},
        KEY, algorithm="RS256", headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


class _JWK:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        return SimpleNamespace(key=KEY.public_key())


class _ReadyPool:
    async def close(self) -> None:
        pass


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _JWK())

    async def _no_pool() -> None:
        return None

    async def _workloads() -> list[dict[str, Any]]:
        return [dict(w) for w in WORKLOADS]

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)
    monkeypatch.setattr(claim_tenancy, "workload_source", _workloads)

    class _FakeDiscoveryResponse:
        def __init__(self, data: Any):
            self._data = data
            self.status_code = 200

        def json(self) -> Any:
            return self._data

        def raise_for_status(self) -> None:
            pass

    class _FakeAsyncClient:
        def __init__(self, *args: Any, **kwargs: Any):
            pass

        async def __aenter__(self) -> "_FakeAsyncClient":
            return self

        async def __aexit__(self, *args: Any) -> None:
            pass

        async def get(self, url: str, **kwargs: Any) -> _FakeDiscoveryResponse:
            return _FakeDiscoveryResponse({"agents": [dict(w) for w in WORKLOADS]})

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", _FakeAsyncClient)

    def _no_network(*_a: Any, **_k: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", _no_network)
    for t in ("kusari", "tenant-demo"):
        api_compat.reset_tenant_state(t)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as c:
            yield c
    finally:
        set_pool_for_testing(None)
        for t in ("kusari", "tenant-demo"):
            api_compat.reset_tenant_state(t)


def _claim(client: TestClient, subject: str, pod_name: str, **extra: Any):
    body = {"pod_name": pod_name, "namespace": NS,
            "spiffe_id": f"spiffe://signalloom.demo/ns/{NS}/sa/{pod_name}", **extra}
    return client.post("/api/v1/agents/claim", json=body, headers=_bearer(subject))


def _error(res: Any) -> str:
    return res.json()["error"]["code"]


def _claimed_models(client: TestClient, subject: str) -> dict[str, str]:
    res = client.get("/api/v1/agents/claims", headers=_bearer(subject))
    assert res.status_code == 200, res.text
    return {c["pod_name"]: c["model"] for c in res.json()["claims"]}


def test_the_declared_tenant_claims_its_workload_and_the_model_is_the_workloads(client: TestClient) -> None:
    res = _claim(client, KUSARI_OP, "kusari-agent")
    assert res.status_code == 200, res.text
    assert _claimed_models(client, KUSARI_OP) == {"kusari-agent": "deterministic"}


def test_another_tenant_is_refused_403_without_naming_the_owner(client: TestClient) -> None:
    res = _claim(client, DEMO_USER, "kusari-agent")
    assert res.status_code == 403, res.text
    assert _error(res) == "cross_tenant_forbidden"
    assert "kusari\"" not in res.text.replace("kusari-agent", "")
    assert _claimed_models(client, DEMO_USER) == {}


def test_the_display_name_resolves_to_the_same_workload_and_the_same_refusal(client: TestClient) -> None:
    res = _claim(client, DEMO_USER, "Kusari Agent (stub)")
    assert res.status_code == 403, res.text
    assert _error(res) == "cross_tenant_forbidden"


def test_an_unlabelled_workload_is_refused_403(client: TestClient) -> None:
    res = _claim(client, KUSARI_OP, "unlabelled")
    assert res.status_code == 403, res.text
    assert _error(res) == "workload_tenant_undeclared"


def test_a_homoglyph_tenant_label_is_a_different_tenant(client: TestClient) -> None:
    res = _claim(client, KUSARI_OP, "homoglyph")
    assert res.status_code == 403, res.text
    assert _error(res) == "cross_tenant_forbidden"


def test_a_workload_with_no_model_label_is_refused_422(client: TestClient) -> None:
    res = _claim(client, KUSARI_OP, "nomodel")
    assert res.status_code == 422, res.text
    assert _error(res) == "workload_model_undeclared"


def test_an_asserted_model_the_workload_does_not_declare_is_refused_422(client: TestClient) -> None:
    res = _claim(client, KUSARI_OP, "kusari-agent", model="claude-3-5-sonnet")
    assert res.status_code == 422, res.text
    assert _error(res) == "model_mismatch"
    assert _claimed_models(client, KUSARI_OP) == {}


def test_the_matching_asserted_model_is_accepted(client: TestClient) -> None:
    res = _claim(client, KUSARI_OP, "kusari-agent", model="deterministic")
    assert res.status_code == 200, res.text


def test_the_bare_model_label_is_an_accepted_assertion_and_the_full_model_is_recorded(client: TestClient) -> None:
    res = _claim(client, DEMO_USER, "demo-bot", model="gpt-4o")
    assert res.status_code == 200, res.text
    assert _claimed_models(client, DEMO_USER) == {"demo-bot": "openai/gpt-4o"}
    res = _claim(client, DEMO_USER, "demo-bot", model="gpt-4")
    assert res.status_code == 422, res.text
    assert _error(res) == "model_mismatch"


def test_an_unknown_workload_is_404(client: TestClient) -> None:
    res = _claim(client, KUSARI_OP, "no-such-agent")
    assert res.status_code == 404, res.text
    assert _error(res) == "workload_not_found"


def test_a_name_two_workloads_answer_to_is_409(client: TestClient) -> None:
    res = _claim(client, KUSARI_OP, "twin")
    assert res.status_code == 409, res.text
    assert _error(res) == "workload_ambiguous"


def test_the_same_name_in_another_namespace_is_not_the_workload(client: TestClient) -> None:
    body = {"pod_name": "kusari-agent", "namespace": "default",
            "spiffe_id": "spiffe://signalloom.demo/ns/default/sa/kusari-agent"}
    res = client.post("/api/v1/agents/claim", json=body, headers=_bearer(KUSARI_OP))
    assert res.status_code == 404, res.text
    assert _error(res) == "workload_not_found"


def test_discovery_down_fails_closed_503(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(claim_tenancy, "workload_source", claim_tenancy._discovery_workloads)

    class _Down:
        def __init__(self, *_a: Any, **_k: Any) -> None:
            pass

        async def __aenter__(self) -> "_Down":
            return self

        async def __aexit__(self, *_a: Any) -> None:
            return None

        async def get(self, url: str) -> Any:
            raise httpx.ConnectError("refused", request=httpx.Request("GET", url))

    monkeypatch.setattr(claim_tenancy.httpx, "AsyncClient", _Down)
    res = _claim(client, KUSARI_OP, "kusari-agent")
    assert res.status_code == 503, res.text
    assert _error(res) == "discovery_unavailable"


def test_autoclaim_claims_only_the_callers_declared_workloads_with_their_models(client: TestClient) -> None:
    res = client.post("/api/v1/agents/autoclaim-discovered", headers=_bearer(KUSARI_OP))
    assert res.status_code == 200, res.text
    claimed = {c["pod_name"]: c["model"] for c in res.json()["claimed"]}
    # twin/twin is ambiguous and nomodel has no model: neither is claimable.
    assert claimed == {"kusari-agent": "deterministic"}
    res = client.post("/api/v1/agents/autoclaim-discovered", headers=_bearer(DEMO_USER))
    assert {c["pod_name"]: c["model"] for c in res.json()["claimed"]} == {"demo-bot": "openai/gpt-4o"}


def test_autoclaim_with_nothing_claimable_claims_nothing_and_invents_nothing(client: TestClient) -> None:
    res = client.post("/api/v1/agents/autoclaim-discovered", json={"namespace": "empty-ns"},
                      headers=_bearer(KUSARI_OP))
    assert res.status_code == 200, res.text
    assert res.json() == {"claimed": [], "total_claimed": 0}
    assert _claimed_models(client, KUSARI_OP) == {}


def test_discovery_claim_route_refuses_another_tenant_403(client: TestClient) -> None:
    body = {"agent_id": "kusari-agent", "namespace": NS}
    res = client.post("/api/v1/discovery/claim", json=body, headers=_bearer(DEMO_USER))
    assert res.status_code == 403, res.text
    assert _error(res) == "cross_tenant_forbidden"
    res = client.post("/api/v1/discovery/claim", json=body, headers=_bearer(KUSARI_OP))
    assert res.status_code == 200, res.text


def test_claim_and_release_sync_the_spine_under_the_claimants_tenant(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    # agent_claim's spine sync and clamp send NOTHING without a tenant (they act
    # for that tenant via the gateway key), so a claim path that omits it
    # silently stops recording delegation edges.
    calls: list[tuple[str, dict[str, Any]]] = []

    async def _sync(**kw: Any) -> bool:
        calls.append(("sync", kw))
        return True

    async def _clamp(**kw: Any) -> bool:
        calls.append(("clamp", kw))
        return True

    monkeypatch.setattr(api_compat, "sync_claim_delegation_to_spine", _sync)
    monkeypatch.setattr(api_compat, "clamp_claim_delegation_in_spine", _clamp)

    res = _claim(client, KUSARI_OP, "kusari-agent")
    assert res.status_code == 200, res.text
    claim_id = res.json()["claim_id"]
    rel = client.delete(f"/api/v1/agents/claim/{claim_id}", headers=_bearer(KUSARI_OP))
    assert rel.status_code == 200, rel.text

    assert [(kind, kw.get("tenant")) for kind, kw in calls] == [("sync", "kusari"), ("clamp", "kusari")]
    assert calls[0][1].get("subject")


# ── Agent-identity spoof rejection (sldc/sa-identity) ────────────────────────
#
# hosted-daytona-coder holds pod-create RBAC in fe-signalloom-agents
# (d2-signalloom/infra/agent-swarm/hosted-daytona-coder/rolebinding.yaml). A
# pod it creates carrying signalloom.ai/agent-name=kusari-agent discovers
# with agent_name="kusari-agent" exactly like the real agent, but its own
# ServiceAccount (read live from the pod spec by fake-integration-proxy,
# never a label -- see service_account: spec.get("serviceAccountName") in
# apps/fake-integration-proxy/server.py) is its own. The default client
# fixture's identity_map_source reads a directory that does not exist on a
# test machine and returns {}, so these tests override it locally to prove
# the registered-identity check without touching every other test's fixture.

DECOY_WORKLOAD: dict[str, Any] = {
    "id": "decoy-daytona-1", "name": "decoy-daytona", "agent_name": "kusari-agent",
    "namespace": NS, "tenant": "kusari", "model": "deterministic",
    "service_account": "hosted-daytona-coder",
}


KUSARI_IDENTITY = {"kusari-agent": AgentIdentity(namespace=NS, service_account="kusari-agent")}


def test_a_workload_spoofing_a_registered_agents_identity_label_is_refused_403(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def _workloads() -> list[dict[str, Any]]:
        return [dict(w) for w in WORKLOADS] + [dict(DECOY_WORKLOAD)]

    monkeypatch.setattr(claim_tenancy, "workload_source", _workloads)
    monkeypatch.setattr(claim_tenancy, "identity_map_source", lambda: KUSARI_IDENTITY)

    res = _claim(client, KUSARI_OP, "decoy-daytona")
    assert res.status_code == 403, res.text
    assert _error(res) == "agent_identity_mismatch"
    assert _claimed_models(client, KUSARI_OP) == {}


def test_a_workload_with_the_right_service_account_name_but_wrong_namespace_is_refused_403(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A ServiceAccount name is only unique within its namespace. This decoy's
    # service_account is literally "kusari-agent" -- exactly the registered
    # name -- but it runs (and is claimed) in hosted-daytona-coder's own
    # namespace, not the one kusari-agent is registered to.
    decoy_namespace = "hosted-daytona-coder-workspace"
    decoy = {
        "id": "decoy-daytona-2", "name": "decoy-daytona-2", "agent_name": "kusari-agent",
        "namespace": decoy_namespace, "tenant": "kusari", "model": "deterministic",
        "service_account": "kusari-agent",
    }

    async def _workloads() -> list[dict[str, Any]]:
        return [dict(w) for w in WORKLOADS] + [decoy]

    monkeypatch.setattr(claim_tenancy, "workload_source", _workloads)
    monkeypatch.setattr(claim_tenancy, "identity_map_source", lambda: KUSARI_IDENTITY)

    body = {"pod_name": "decoy-daytona-2", "namespace": decoy_namespace,
            "spiffe_id": f"spiffe://signalloom.demo/ns/{decoy_namespace}/sa/kusari-agent"}
    res = client.post("/api/v1/agents/claim", json=body, headers=_bearer(KUSARI_OP))
    assert res.status_code == 403, res.text
    assert _error(res) == "agent_identity_mismatch"


def test_a_workload_whose_namespace_and_service_account_match_its_registered_identity_is_claimable(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(claim_tenancy, "identity_map_source", lambda: KUSARI_IDENTITY)
    # The shared fixture's real kusari-agent entry declares no service_account
    # at all (added here only, so every other test's fixture is untouched).
    # Its namespace is already NS, matching KUSARI_IDENTITY.
    legit = dict(WORKLOADS[0])
    legit["service_account"] = "kusari-agent"

    async def _workloads() -> list[dict[str, Any]]:
        return [legit] + [dict(w) for w in WORKLOADS[1:]]

    monkeypatch.setattr(claim_tenancy, "workload_source", _workloads)

    res = _claim(client, KUSARI_OP, "kusari-agent")
    assert res.status_code == 200, res.text


def test_an_unregistered_agent_identity_is_unaffected_by_the_identity_map(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    # demo-bot is not a key in this identity map: the map must not become a
    # second allow-list that starts denying names it was never told about.
    monkeypatch.setattr(claim_tenancy, "identity_map_source", lambda: KUSARI_IDENTITY)
    res = _claim(client, DEMO_USER, "demo-bot", model="gpt-4o")
    assert res.status_code == 200, res.text


def test_unlabelled_workload_claim_when_undeclared_claims_allowed(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    # By default unlabelled is refused 403 workload_tenant_undeclared
    res = _claim(client, DEMO_USER, "unlabelled")
    assert res.status_code == 403
    assert _error(res) == "workload_tenant_undeclared"

    # With allow_undeclared_tenant_claims enabled, workload is discoverable as undeclared
    monkeypatch.setattr(settings, "allow_undeclared_tenant_claims", True)
    get_res = client.get("/api/v1/agents/unlabelled-1", headers=_bearer(DEMO_USER))
    assert get_res.status_code == 200, get_res.text
    agent_data = get_res.json()
    assert agent_data["tenant"] is None
    assert agent_data["tenant_id"] == "undeclared"

    # Claim succeeds and binds to claimant tenant
    res = _claim(client, DEMO_USER, "unlabelled", model="gpt-4o")
    assert res.status_code == 200, res.text
    body = res.json()
    claim_id = body["claim_id"]
    agent_id = body["agent_id"]
    assert claim_id

    # Post-claim agent reflects claimant tenant
    claimed_res = client.get(f"/api/v1/agents/{agent_id}", headers=_bearer(DEMO_USER))
    assert claimed_res.status_code == 200, claimed_res.text
    claimed_data = claimed_res.json()
    assert claimed_data["tenant"] == "tenant-demo"
    assert claimed_data["tenant_id"] == "tenant-demo"

