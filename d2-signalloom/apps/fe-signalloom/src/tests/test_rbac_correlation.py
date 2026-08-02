"""Tests for rbac_correlation.py — the RBAC/AFM intermediate correlation API.

Two layers, deliberately kept separate:

1. `correlate_rbac()` unit tests below use payload shapes copied from a real
   AFM response captured against the live `osramp` KinD cluster on
   2026-08-02 (see docs/signalloom/rbac-live-wiring.md), not an idealised
   contract. The old client-side RBAC Explorer read `analysis.escalation_paths`
   (does not exist — real keys are `single_escalations`/`group_escalations`),
   `conformance[i].namespace`/`.details` at the top level (nested under
   `.role`, and `.details` does not exist), and
   `shared_roles.results[i].shared_by`/`.risk` (real fields are
   `all_subjects`/`privileged_subjects`, no risk field). Fixtures below encode
   the real shape so a regression back to the idealised one fails loudly.

2. The HTTP-level tests follow the FakeAsyncClient pattern from
   test_crypto_health.py: patch `rbac_correlation.httpx.AsyncClient` and
   assert on requested URLs, status codes and auth enforcement.
"""
import socket
import time
from contextlib import contextmanager
from types import SimpleNamespace

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import rbac_correlation
from api_compat import settings
from db.connection import set_pool_for_testing
from rbac_correlation import correlate_rbac

# ─── Shared JWT/auth scaffolding (copied from test_crypto_health.py) ────────

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class ReadyPool:
    async def close(self):
        pass


class TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def token_for(
    subject: str = "alice",
    *,
    issuer: str = "https://issuer.test/dex",
    audience: str = "signalloom-api",
    authorized_party: str = "signalloom-dashboard",
) -> str:
    now = int(time.time())
    return jwt.encode(
        {
            "iss": issuer,
            "aud": audience,
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": authorized_party,
            "sub": subject,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@contextmanager
def client_for(monkeypatch: pytest.MonkeyPatch, async_client_cls):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-a"})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: TestJWKClient())
    monkeypatch.setattr(rbac_correlation, "httpx", SimpleNamespace(AsyncClient=async_client_cls, HTTPError=httpx.HTTPError))
    set_pool_for_testing(ReadyPool())

    def reject_external_network(*_args, **_kwargs):
        raise AssertionError("external network access is forbidden in rbac correlation tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    from main import app

    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


class FakeResponse:
    def __init__(self, payload, status: int = 200):
        self._payload = payload
        self._status = status

    def raise_for_status(self) -> None:
        if self._status >= 400:
            request = httpx.Request("GET", "http://afm.test/x")
            raise httpx.HTTPStatusError("bad status", request=request, response=httpx.Response(self._status, request=request))

    def json(self):
        return self._payload


def fake_client_cls(routes: dict[str, FakeResponse], requested: list[str] | None = None):
    class FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            if requested is not None:
                requested.append(url)
            path = url.split(rbac_correlation.AFM_BASE_URL, 1)[-1]
            if path not in routes:
                raise httpx.ConnectError(f"no fake route for {path}", request=httpx.Request("GET", url))
            return routes[path]

    return FakeAsyncClient


# ─── Real-shape fixtures (trimmed from a live capture, see module docstring) ─

REAL_RBAC = {
    "subjects": [
        {"name": "flux", "kind": "ServiceAccount", "namespace": "fe-signalloom", "annotations": {}},
        {"name": "system:masters", "kind": "Group", "namespace": None, "annotations": {}},
    ],
    "roles": [
        {"name": "cluster-admin", "scope": "Cluster", "namespace": None, "rules": [{"verbs": ["*"], "apiGroups": ["*"], "resources": ["*"]}]},
        {"name": "admin", "scope": "Cluster", "namespace": None, "rules": None},
    ],
    "bindings": [
        {
            "name": "cluster-admin", "scope": "Cluster", "namespace": None, "roleRef": "cluster-admin", "roleRefKind": None,
            "subjects": [{"kind": "Group", "name": "system:masters"}],
        },
        {
            "name": "flux", "scope": "Namespace", "namespace": "fe-signalloom", "roleRef": "admin", "roleRefKind": None,
            "subjects": [{"kind": "ServiceAccount", "name": "flux", "namespace": "fe-signalloom"}],
        },
    ],
    "namespaces": [],
}

REAL_ANALYSIS = {
    "schema_version": "3.4.0",
    "group_escalations": [],
    "single_escalations": [
        {
            "escalation_type": "admin_via_impersonation",
            "subject": "sa_fe_signalloom_flux",
            "risk": {"score": 48, "level": "high", "likelihood": 50, "impact": 100},
            "gained_permission": {"namespace": "cluster", "resource": "all", "verb": "all"},
            "trace": {"explanation": {"summary": "ServiceAccount fe-signalloom/flux reaches all on * at cluster scope through 2 modeled steps."}},
        },
    ],
    "metadata": {
        "admins": ["group_system_masters"],
        "full_admins": [],
        "non_admins": ["sa_fe_signalloom_flux"],
        "namespaces": ["fe-signalloom"],
        "name_map": {
            "group_system_masters": "Group/cluster/system:masters",
            "sa_fe_signalloom_flux": "ServiceAccount/fe-signalloom/flux",
        },
    },
}

# Real conformance shape: role identity nested under `role`, no top-level
# `namespace`/`details` — the fields the old frontend read that don't exist.
REAL_CONFORMANCE = [
    {
        "role": {"name": "cluster-admin", "scope": "Cluster", "namespace": None},
        "severity": "high",
        "reason": "Contains escalate/bind or wildcard verb",
        "rule": {"verbs": ["*"], "apiGroups": ["*"], "resources": ["*"]},
    },
]

# Real shared_roles shape: `all_subjects`/`privileged_subjects`, no
# `shared_by`/`risk`/`reason` fields — also the label-encoded role identity
# ("ClusterRole/x" or "Role/x [namespace=y]") rather than an object.
REAL_SHARED_ROLES = {
    "cluster": {"id": "local", "name": "Local Cluster"},
    "results": [
        {
            "role": "ClusterRole/cluster-admin",
            "bindings": [{"kind": "ClusterRoleBinding", "name": "cluster-admin", "namespace": None, "subjects": ["Group/system:masters"]}],
            "all_subjects": ["Group/system:masters", "ServiceAccount/kube-system/x"],
            "privileged_subjects": ["Group/system:masters"],
            "privileged_details": [],
        },
        {
            "role": "Role/extension-apiserver-authentication-reader [namespace=kube-system]",
            "bindings": [],
            "all_subjects": ["ServiceAccount/kube-system/a", "ServiceAccount/kube-system/b"],
            "privileged_subjects": [],
            "privileged_details": [],
        },
    ],
}


# ─── correlate_rbac() unit tests ─────────────────────────────────────────────


def test_correlate_rbac_resolves_escalation_by_afm_internal_id():
    """The regression test for the bug this module exists to fix: AFM's
    escalation subject is its own internal id, resolved through name_map —
    not the plain k8s subject name the /rbac endpoint uses."""
    result = correlate_rbac("local", "Local Cluster", REAL_RBAC, REAL_ANALYSIS, REAL_CONFORMANCE, REAL_SHARED_ROLES)

    assert len(result.escalations) == 1
    escalation = result.escalations[0]
    assert escalation.kind == "single"
    assert escalation.subject == "sa_fe_signalloom_flux"
    assert escalation.subject_display == "ServiceAccount/fe-signalloom/flux"
    assert escalation.risk_level == "high"
    assert escalation.risk_score == 48

    flux_subject = next(s for s in result.subjects if s.name == "flux")
    assert flux_subject.is_escalation_actor is True
    admin_subject = next(s for s in result.subjects if s.name == "system:masters")
    assert admin_subject.is_admin is True
    assert admin_subject.is_escalation_actor is False


def test_correlate_rbac_reads_conformance_role_from_nested_object():
    """Old frontend read c.namespace/c.details at the top level — both are
    absent on the real wire; the identity is nested under c.role."""
    result = correlate_rbac("local", "Local Cluster", REAL_RBAC, REAL_ANALYSIS, REAL_CONFORMANCE, REAL_SHARED_ROLES)

    assert len(result.conformance) == 1
    issue = result.conformance[0]
    assert issue.role_name == "cluster-admin"
    assert issue.role_scope == "Cluster"
    assert issue.role_namespace is None
    assert issue.severity == "high"

    cluster_admin_role = next(r for r in result.roles if r.name == "cluster-admin")
    assert cluster_admin_role.conformance_issue_count == 1


def test_correlate_rbac_derives_shared_by_from_all_subjects_length():
    """Old frontend read `.shared_by` and `.risk`, which do not exist —
    the count is len(all_subjects), and there is no risk field."""
    result = correlate_rbac("local", "Local Cluster", REAL_RBAC, REAL_ANALYSIS, REAL_CONFORMANCE, REAL_SHARED_ROLES)

    assert len(result.shared_roles) == 2
    cluster_admin_shared = next(s for s in result.shared_roles if s.role_name == "cluster-admin")
    assert cluster_admin_shared.shared_by == 2
    assert cluster_admin_shared.privileged_subject_count == 1

    namespaced_shared = next(s for s in result.shared_roles if s.role_name == "extension-apiserver-authentication-reader")
    assert namespaced_shared.role_scope == "Namespace"
    assert namespaced_shared.role_namespace == "kube-system"
    assert namespaced_shared.shared_by == 2

    cluster_admin_role = next(r for r in result.roles if r.name == "cluster-admin")
    assert cluster_admin_role.shared_by_count == 2
    assert cluster_admin_role.has_privileged_sharing is True


def test_correlate_rbac_prefers_reported_namespaces_over_derived():
    result = correlate_rbac("local", "Local Cluster", REAL_RBAC, REAL_ANALYSIS, REAL_CONFORMANCE, REAL_SHARED_ROLES)
    assert result.namespaces == ["fe-signalloom"]


def test_correlate_rbac_derives_namespaces_when_afm_reports_none():
    analysis = {**REAL_ANALYSIS, "metadata": {**REAL_ANALYSIS["metadata"], "namespaces": []}}
    result = correlate_rbac("local", "Local Cluster", REAL_RBAC, analysis, REAL_CONFORMANCE, REAL_SHARED_ROLES)
    assert result.namespaces == ["fe-signalloom"]


def test_correlate_rbac_admin_and_non_admin_counts():
    result = correlate_rbac("local", "Local Cluster", REAL_RBAC, REAL_ANALYSIS, REAL_CONFORMANCE, REAL_SHARED_ROLES)
    assert result.admin_count == 1
    assert result.non_admin_count == 1


def test_correlate_rbac_tolerates_missing_enrichment():
    """Analysis/conformance/shared-roles can be legitimately empty (cluster
    imported, Z3 job not yet run) — correlation must not crash."""
    result = correlate_rbac("local", "Local Cluster", REAL_RBAC, {}, [], {})
    assert result.escalations == []
    assert result.conformance == []
    assert result.shared_roles == []
    assert len(result.subjects) == 2
    assert len(result.roles) == 2


def test_correlate_rbac_ignores_group_role_rules_null():
    """Aggregated ClusterRoles (admin, edit, view) carry rules: null."""
    result = correlate_rbac("local", "Local Cluster", REAL_RBAC, REAL_ANALYSIS, REAL_CONFORMANCE, REAL_SHARED_ROLES)
    admin_role = next(r for r in result.roles if r.name == "admin")
    assert admin_role.rules == []


# ─── HTTP-level tests ─────────────────────────────────────────────────────


def test_correlated_rbac_requires_bearer_auth(monkeypatch):
    with client_for(monkeypatch, fake_client_cls({})) as client:
        response = client.get("/api/rbac/clusters/local/correlated")
    assert response.status_code == 401


def test_correlated_rbac_fails_closed_when_afm_unreachable(monkeypatch):
    """Fails 503 (visible), never silently returns an empty-but-200 posture."""
    with client_for(monkeypatch, fake_client_cls({})) as client:
        response = client.get("/api/rbac/clusters/local/correlated", headers=bearer(token_for()))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "afm_unreachable"


def test_correlated_rbac_succeeds_end_to_end(monkeypatch):
    requested: list[str] = []
    routes = {
        "/clusters/local/rbac": FakeResponse(REAL_RBAC),
        "/clusters": FakeResponse([{"id": "local", "name": "Local Cluster"}]),
        "/clusters/local/analysis/latest": FakeResponse(REAL_ANALYSIS),
        "/clusters/local/rbac/conformance": FakeResponse(REAL_CONFORMANCE),
        "/clusters/local/analysis/shared_roles": FakeResponse(REAL_SHARED_ROLES),
    }
    with client_for(monkeypatch, fake_client_cls(routes, requested)) as client:
        response = client.get("/api/rbac/clusters/local/correlated", headers=bearer(token_for()))

    assert response.status_code == 200
    body = response.json()
    assert body["cluster"] == {"id": "local", "name": "Local Cluster"}
    assert len(body["escalations"]) == 1
    assert body["escalations"][0]["risk_level"] == "high"
    assert any(url.endswith("/clusters/local/rbac") for url in requested)


def test_correlated_rbac_degrades_gracefully_when_analysis_not_yet_run(monkeypatch):
    """RBAC succeeds but the Z3 analysis job hasn't produced output yet
    (e.g. a just-imported cluster) — the request must still succeed."""
    routes = {
        "/clusters/local/rbac": FakeResponse(REAL_RBAC),
        "/clusters": FakeResponse([{"id": "local", "name": "Local Cluster"}]),
        # analysis/conformance/shared_roles deliberately absent from routes
    }
    with client_for(monkeypatch, fake_client_cls(routes)) as client:
        response = client.get("/api/rbac/clusters/local/correlated", headers=bearer(token_for()))

    assert response.status_code == 200
    body = response.json()
    assert body["escalations"] == []
    assert body["conformance"] == []
    assert len(body["subjects"]) == 2


def test_list_clusters_success(monkeypatch):
    routes = {"/clusters": FakeResponse([{"id": "local", "name": "Local Cluster"}, {"id": "prod", "name": "Prod"}])}
    with client_for(monkeypatch, fake_client_cls(routes)) as client:
        response = client.get("/api/rbac/clusters", headers=bearer(token_for()))
    assert response.status_code == 200
    assert response.json() == [{"id": "local", "name": "Local Cluster"}, {"id": "prod", "name": "Prod"}]


def test_list_clusters_fails_closed_when_afm_unreachable(monkeypatch):
    with client_for(monkeypatch, fake_client_cls({})) as client:
        response = client.get("/api/rbac/clusters", headers=bearer(token_for()))
    assert response.status_code == 503
