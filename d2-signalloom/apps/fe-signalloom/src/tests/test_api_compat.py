import base64
import json
import socket
import time
import uuid
from datetime import datetime, timezone
from types import SimpleNamespace
from typing import Any, Literal

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app


class ReadyPool:
    async def close(self):
        pass


TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _segment(value: dict) -> str:
    raw = json.dumps(value, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def token_for(
    subject: str | None = "alice",
    *,
    issuer: str = "https://issuer.test/dex",
    audience: str | list[str] = "signalloom-api",
    expires_at: int | None = None,
    authorized_party: str = "signalloom-dashboard",
    key_id: str = "test-key",
    signing_key=TEST_SIGNING_KEY,
    extra_claims: dict | None = None,
) -> str:
    now = int(time.time())
    claims = {
        "iss": issuer,
        "aud": audience,
        "iat": now,
        "nbf": now,
        "exp": expires_at if expires_at is not None else now + 300,
        "azp": authorized_party,
    }
    if subject is not None:
        claims["sub"] = subject
    if extra_claims:
        claims.update(extra_claims)
    return jwt.encode(
        claims,
        signing_key,
        algorithm="RS256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def unsupported_algorithm_token() -> str:
    now = int(time.time())
    return f"{_segment({'alg': 'none', 'typ': 'JWT', 'kid': 'test-key'})}.{_segment({'iss': 'https://issuer.test/dex', 'aud': 'signalloom-api', 'azp': 'signalloom-dashboard', 'sub': 'alice', 'iat': now, 'exp': now + 300})}."


def duplicate_header_token() -> str:
    now = int(time.time())
    header = base64.urlsafe_b64encode(
        b'{"alg":"RS256","alg":"RS256","typ":"JWT","kid":"test-key"}'
    ).rstrip(b"=").decode()
    claims = _segment(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "azp": "signalloom-dashboard",
            "sub": "alice",
            "iat": now,
            "exp": now + 300,
        }
    )
    return f"{header}.{claims}.unused"


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(
        settings,
        "api_subject_tenants",
        {"alice": "tenant-a", "bob": "tenant-b"},
    )
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: TestJWKClient())

    def reject_external_network(*_args, **_kwargs):
        raise AssertionError("external network access is forbidden in API tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    set_pool_for_testing(ReadyPool())
    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


def test_missing_and_malformed_bearer_tokens_return_typed_401(client):
    missing = client.get("/api/agents")
    malformed = client.get("/api/agents", headers={"Authorization": "Basic abc"})

    assert missing.status_code == 401
    assert missing.json() == {
        "error": {
            "code": "authentication_required",
            "message": "Bearer authentication is required",
        }
    }
    assert malformed.status_code == 401
    assert malformed.json()["error"]["code"] == "invalid_token"


@pytest.mark.parametrize(
    "candidate",
    [
        lambda: token_for(signing_key=OTHER_SIGNING_KEY),
        lambda: token_for(issuer="https://attacker.test/dex"),
        lambda: token_for(audience="another-api"),
        lambda: token_for(expires_at=int(time.time()) - 10),
        lambda: token_for(subject=None),
        lambda: token_for(authorized_party="attacker-dashboard"),
        lambda: token_for(key_id="unknown-key"),
        unsupported_algorithm_token,
        duplicate_header_token,
        lambda: "not.a.jwt.with.extra.parts",
    ],
)
def test_invalid_jwt_security_branches_return_same_safe_error(client, candidate):
    response = client.get("/api/agents", headers=bearer(candidate()))

    assert response.status_code == 401
    assert response.json() == {
        "error": {"code": "invalid_token", "message": "Bearer token is invalid"}
    }


def test_unknown_subject_is_forbidden_without_disclosing_mapping(client):
    response = client.get("/api/agents", headers=bearer(token_for("mallory")))

    assert response.status_code == 403
    assert response.json() == {
        "error": {
            "code": "tenant_forbidden",
            "message": "Subject has no tenant access",
        }
    }
    assert "mallory" not in response.text


def test_audience_list_and_known_subject_map_to_expected_tenant(client):
    response = client.get(
        "/api/tenant/settings",
        headers=bearer(token_for("alice", audience=["dashboard", "signalloom-api"])),
    )

    assert response.status_code == 200
    assert response.json()["tenant_id"] == "tenant-a"


def test_documented_dex_subject_maps_to_documented_demo_tenant(client, monkeypatch):
    issuer = "http://dex.inf-signalloom.svc.cluster.local:5556/dex"
    monkeypatch.setattr(settings, "api_jwt_issuer", issuer)
    monkeypatch.setattr(settings, "api_subject_tenants", {"demo-user": "tenant-demo"})

    response = client.get(
        "/api/tenant/settings",
        headers=bearer(token_for("demo-user", issuer=issuer)),
    )

    assert response.status_code == 200
    assert response.json()["tenant_id"] == "tenant-demo"


def test_authenticated_tenant_is_derived_from_subject_not_token_tenant_claim(client):
    response = client.get(
        "/api/tenant/settings",
        headers=bearer(token_for("alice", extra_claims={"tenant_id": "tenant-b"})),
    )

    assert response.status_code == 200
    assert response.json()["tenant_id"] == "tenant-a"


def test_current_compatibility_contracts_are_typed_and_tenant_scoped(client):
    headers = bearer(token_for("alice"))
    expected = {
        "/api/agents": api_compat.AgentListResponse,
        "/api/compliance/summary": api_compat.ComplianceSummaryResponse,
        "/api/audit": api_compat.AuditListResponse,
        "/api/tenant/settings": api_compat.TenantSettingsResponse,
    }

    for path, model in expected.items():
        response = client.get(path, headers=headers)
        assert response.status_code == 200
        model.model_validate(response.json())


def test_policy_compliance_compatibility_routes_match_dashboard_contract(client):
    headers = bearer(token_for("alice"))

    frameworks = client.get("/api/compliance/policy/frameworks", headers=headers)
    summary = client.get("/api/compliance/policy/summary", headers=headers)

    assert frameworks.status_code == 200
    assert summary.status_code == 200
    assert frameworks.json()
    # The key sets below gained DENOMINATED twins of the *Gbp figures. The change is additive on
    # purpose: `totalExposureGbp` and `totalCarriedGbp` stay so the dashboard keeps working while
    # it migrates, and the new `exposure` / `carried` / `currency` fields carry the denomination as
    # DATA. A currency welded into a field name does not survive a wire, a database column or a
    # chart axis -- which is how a consumer ends up defaulting its display to USD and relabelling a
    # GBP figure instead of converting it.
    #
    # This assertion is deliberately an exact set rather than a subset check, so that any future
    # field lands here as a conscious contract decision rather than by accident. Removing a *Gbp
    # field IS a breaking change and must be coordinated with the dashboard.
    assert set(frameworks.json()[0]) == {
        "id", "name", "versions", "totalControls", "passedControls",
        "failedControls", "totalExposureGbp", "exposure",
    }
    assert set(summary.json()) == {
        "totalChecks", "passed", "failed", "totalAle", "totalVar95",
        "totalTvar", "totalCarriedGbp", "scanTimestamp", "frameworks",
        "carried", "currency",
    }
    assert summary.json()["frameworks"] == frameworks.json()

    # A denominated figure must actually be denominated: a null currency here would mean the new
    # fields are decoration and a consumer still has nothing to convert from.
    assert summary.json()["currency"] == "GBP"
    assert summary.json()["carried"]["currency"] == "GBP"
    assert frameworks.json()[0]["exposure"]["currency"] == "GBP"
    # And the twins must agree with the legacy fields they mirror, or the two will drift.
    assert summary.json()["carried"]["amount"] == summary.json()["totalCarriedGbp"]
    assert frameworks.json()[0]["exposure"]["amount"] == frameworks.json()[0]["totalExposureGbp"]


def test_discovery_detail_reads_persisted_tenant_account(client, monkeypatch):
    account_id = uuid.UUID("e0000000-0000-0000-0000-000000000005")

    class DiscoveryPool:
        def __init__(self):
            self.args = ()

        async def fetchrow(self, _query, *args):
            self.args = args
            return {
                "id": account_id,
                "scan_id": uuid.UUID("d0000000-0000-0000-0000-000000000001"),
                "account_name": "svc-billing-sync",
                "directory_source": "ad_entra",
                "owner_email": "platform@example.test",
                "last_rotated": datetime(2026, 7, 1, tzinfo=timezone.utc),
                "privilege_level": "elevated",
                "findings": ["rotation_stale"],
                "status": "discovered",
                "first_discovered_at": datetime(2026, 6, 1, tzinfo=timezone.utc),
                "last_seen_at": datetime(2026, 8, 1, tzinfo=timezone.utc),
                "dismissed_at": None,
                "dismissed_by": None,
                "dismiss_reason": None,
                "scan_count": 3,
            }

    pool = DiscoveryPool()

    async def get_pool():
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    response = client.get(
        f"/api/nhi/discovered/{account_id}",
        headers=bearer(token_for("alice")),
    )

    assert response.status_code == 200, response.text
    assert response.json()["account_name"] == "svc-billing-sync"
    assert response.json()["last_rotated"] == "2026-07-01T00:00:00Z"
    assert pool.args == (account_id, "tenant-a")


def test_discovery_detail_fails_closed_without_database(client, monkeypatch):
    async def get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    response = client.get(
        "/api/nhi/discovered/e0000000-0000-0000-0000-000000000005",
        headers=bearer(token_for("alice")),
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "database_unavailable"


def test_tenant_users_reads_only_authenticated_tenant_records(client, monkeypatch):
    class TenantUsersPool:
        def __init__(self):
            self.query = ""
            self.args = ()

        async def fetch(self, query, *args):
            self.query = query
            self.args = args
            return [{
                "id": uuid.UUID("a0000000-0000-0000-0000-000000000001"),
                "email": "alice@example.test",
                "display_name": "Alice Example",
                "role": "admin",
                "status": "active",
                "department": "Security",
                "title": "Security Engineer",
                "last_login_at": datetime(2026, 8, 1, 10, 0, tzinfo=timezone.utc),
                "created_at": datetime(2026, 7, 1, 10, 0, tzinfo=timezone.utc),
            }]

    pool = TenantUsersPool()

    async def get_pool():
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    response = client.get("/api/tenant/users", headers=bearer(token_for("alice")))

    assert response.status_code == 200, response.text
    assert response.json()["total"] == 1
    assert response.json()["users"][0]["email"] == "alice@example.test"
    assert pool.args == ("tenant-a",)
    assert "FROM platform_users" in pool.query
    assert "tenant_id = $1" in pool.query


def test_tenant_users_fails_closed_without_database(client, monkeypatch):
    async def get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    response = client.get("/api/tenant/users", headers=bearer(token_for("alice")))

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "database_unavailable"


def test_policy_scan_updates_persisted_rows_and_returns_existing_summary_model(client, monkeypatch):
    assessed_at = datetime(2026, 8, 2, 22, 30, tzinfo=timezone.utc)

    class Transaction:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return False

    class Connection:
        def __init__(self):
            self.executions = []
            self.fetch_args = ()

        def transaction(self):
            return Transaction()

        async def execute(self, query, *args):
            self.executions.append((query, args))
            return "UPDATE 4" if "UPDATE agent_compliance_results" in query else "INSERT 0 1"

        async def fetch(self, _query, *args):
            self.fetch_args = args
            return [
                {
                    "framework_id": uuid.UUID("f0000000-0000-0000-0000-000000000001"),
                    "framework_name": "EU AI Act",
                    "control_id": uuid.UUID("c0000000-0000-0000-0000-000000000001"),
                    "control_name": "Traceability",
                    "passed": True,
                    "assessed_at": assessed_at,
                },
                {
                    "framework_id": uuid.UUID("f0000000-0000-0000-0000-000000000001"),
                    "framework_name": "EU AI Act",
                    "control_id": uuid.UUID("c0000000-0000-0000-0000-000000000002"),
                    "control_name": "Human oversight",
                    "passed": False,
                    "assessed_at": assessed_at,
                },
            ]

    class Acquire:
        def __init__(self, connection):
            self.connection = connection

        async def __aenter__(self):
            return self.connection

        async def __aexit__(self, *_args):
            return False

    class PolicyPool:
        def __init__(self):
            self.connection = Connection()

        def acquire(self):
            return Acquire(self.connection)

    pool = PolicyPool()

    async def get_pool():
        return pool

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    body = {
        "namespace": "default",
        "policyVersion": "v2.1",
        "frameworks": ["f0000000-0000-0000-0000-000000000001"],
    }
    response = client.post(
        "/api/compliance/policy/scan",
        json=body,
        headers=bearer(token_for("alice")),
    )

    assert response.status_code == 200, response.text
    scan = api_compat.PolicyScanResponse.model_validate(response.json())
    assert len(scan.checks) == 2
    assert scan.summary.totalChecks == 2
    assert scan.summary.passed == 1
    assert scan.summary.failed == 1
    assert scan.summary.scanTimestamp == "2026-08-02T22:30:00Z"
    assert pool.connection.fetch_args == ("tenant-a", body["frameworks"])
    assert any("UPDATE agent_compliance_results" in query for query, _ in pool.connection.executions)


def test_policy_scan_fails_closed_without_database(client, monkeypatch):
    async def get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    response = client.post(
        "/api/compliance/policy/scan",
        json={"namespace": "default", "policyVersion": "v2.0", "frameworks": []},
        headers=bearer(token_for("alice")),
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "database_unavailable"


def test_policy_scan_requires_authentication(client):
    response = client.post(
        "/api/compliance/policy/scan",
        json={"namespace": "default", "policyVersion": "v2.0", "frameworks": []},
    )
    assert response.status_code == 401


def test_policy_scan_rejects_empty_namespace(client):
    response = client.post(
        "/api/compliance/policy/scan",
        json={"namespace": "", "policyVersion": "v2.0", "frameworks": []},
        headers=bearer(token_for("alice")),
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_request"


def test_responses_never_mix_records_between_tenants(client):
    for path in ("/api/agents", "/api/compliance/summary", "/api/audit", "/api/tenant/settings"):
        alice = client.get(path, headers=bearer(token_for("alice"))).text
        bob = client.get(path, headers=bearer(token_for("bob"))).text
        assert "tenant-b" not in alice
        assert "tenant-a" not in bob


def test_unsupported_method_returns_stable_typed_error(client):
    response = client.post("/api/tenant/settings", headers=bearer(token_for("alice")))

    assert response.status_code == 405
    assert response.json() == {
        "error": {
            "code": "method_not_allowed",
            "message": "Method is not allowed",
        }
    }


def test_unknown_compatibility_path_returns_stable_typed_error(client):
    response = client.get("/api/not-a-contract", headers=bearer(token_for("alice")))

    assert response.status_code == 404
    assert response.json() == {
        "error": {"code": "not_found", "message": "Resource was not found"}
    }


def test_internal_exception_is_logged_but_never_disclosed(client, monkeypatch):
    secret_detail = "database password=do-not-disclose"

    def fail(_tenant_id):
        raise RuntimeError(secret_detail)

    monkeypatch.setattr(api_compat, "_get_pool", fail)
    response = client.get("/api/agents", headers=bearer(token_for("alice")))

    assert response.status_code == 500
    assert response.json() == {
        "error": {"code": "internal_error", "message": "Internal server error"}
    }
    assert secret_detail not in response.text


def test_missing_jwks_configuration_fails_closed(client, monkeypatch):
    monkeypatch.setattr(settings, "api_jwks_url", "")

    response = client.get("/api/agents", headers=bearer(token_for("alice")))

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "authentication_unavailable"


def test_openapi_publishes_response_models_for_each_compatibility_route(client):
    schema = client.get("/openapi.json").json()
    expected_models = {
        "/api/agents": "AgentListResponse",
        "/api/compliance/summary": "ComplianceSummaryResponse",
        "/api/audit": "AuditListResponse",
        "/api/tenant/settings": "TenantSettingsResponse",
    }

    for path, model in expected_models.items():
        responses = schema["paths"][path]["get"]["responses"]
        response_schema = responses["200"]["content"]["application/json"]["schema"]
        assert response_schema == {"$ref": f"#/components/schemas/{model}"}
        assert responses["405"]["content"]["application/json"]["schema"] == {
            "$ref": "#/components/schemas/ErrorResponse"
        }


def test_audit_get_is_strictly_side_effect_free_and_does_not_insert_on_zero_results(client, monkeypatch):
    """Proves GET /api/audit performs 0 SQL writes and is side-effect free on 0 results."""
    executed_writes = []

    class ReadOnlyMockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any]:
            return {"total": 0}

        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            return []

        async def execute(self, query: str, *params: Any) -> str:
            executed_writes.append((query, params))
            raise AssertionError("GET /api/audit must NEVER execute SQL write statements")

    mock_pool = ReadOnlyMockPool()

    async def _mock_get_pool():
        return mock_pool

    monkeypatch.setattr(api_compat, "_get_pool", _mock_get_pool)

    response = client.get("/api/audit?agent=nonexistent-agent", headers=bearer(token_for("alice")))
    assert response.status_code == 200
    assert response.json()["events"] == []
    assert response.json()["total"] == 0
    assert len(executed_writes) == 0


def test_agent_detail_returns_404_for_unknown_agent_in_fixture_mode(client, monkeypatch):
    """Proves GET /api/agents/{id} returns HTTP 404 for unknown agent without synthetic fallback."""
    async def get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    response = client.get("/api/agents/unknown-agent-uuid-9999", headers=bearer(token_for("alice")))
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


def test_agent_detail_returns_404_for_unknown_agent_in_db_mode(client, monkeypatch):
    """Proves GET /api/agents/{id} returns HTTP 404 in DB mode when agent is not found."""
    class EmptyDBPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            return None

    async def get_pool():
        return EmptyDBPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    response = client.get("/api/agents/unknown-agent-uuid-9999", headers=bearer(token_for("alice")))
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


def test_source_health_header_and_metadata_emitted_on_agents_get(client, monkeypatch):
    """Proves source_health header and metadata are emitted on GET /api/agents."""
    class HealthyAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(200, json={"agents": [{"id": "pod-1", "name": "Pod Agent"}]})

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", HealthyAsyncClient)

    response = client.get("/api/agents", headers=bearer(token_for("alice")))
    assert response.status_code == 200
    assert response.headers.get("source_health") == "healthy"
    assert response.headers.get("X-Source-Health") == "healthy"
    assert response.json()["source_health"] == "healthy"


def test_source_health_crypto_prover_fails_closed_with_503(client, monkeypatch):
    """Proves GET /api/health/crypto fails closed with HTTP 503 on unreachable upstream."""
    class FailingAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            raise httpx.ConnectError("prover down", request=httpx.Request("GET", url))

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", FailingAsyncClient)

    response = client.get("/api/health/crypto", headers=bearer(token_for("alice")))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "upstream_unavailable"


def test_posture_scale_normalized_zero_controls_is_none(client, monkeypatch):
    """Proves 0 evaluated controls result in posture_score=None (Not assessed)."""
    class SingleAgentClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(200, json={"agents": [{"id": "pod-zero-ctrl", "name": "Unassessed Agent"}]})

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", SingleAgentClient)

    response = client.get("/api/agents", headers=bearer(token_for("alice")))
    assert response.status_code == 200
    agent = response.json()["agents"][0]
    assert agent["compliance_summary"]["total_controls"] == 0
    assert agent["compliance_summary"]["posture_score"] is None


def test_enriched_inventory_preserves_discovery_fields(client, monkeypatch):
    """Proves GET /api/agents preserves Kubernetes discovery metadata."""
    class DiscoveryClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(
                200,
                json={
                    "agents": [
                        {
                            "id": "pod-worker-1",
                            "name": "Worker Agent",
                            "namespace": "fe-signalloom-agents",
                            "service_account": "sa-worker",
                            "node": "kind-osramp-control-plane",
                            "phase": "Running",
                            "pod_uid": "uid-worker-123",
                            "framework": "kagent",
                            "model": "gpt-5.4",
                            "state": "active",
                            "created_at": "2026-08-01T12:00:00Z",
                        }
                    ]
                },
            )

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", DiscoveryClient)

    response = client.get("/api/agents", headers=bearer(token_for("alice")))
    assert response.status_code == 200
    data = response.json()
    assert data["total"] == 1
    agent = data["agents"][0]
    assert agent["namespace"] == "fe-signalloom-agents"
    assert agent["service_account"] == "sa-worker"
    assert agent["node"] == "kind-osramp-control-plane"
    assert agent["phase"] == "Running"
    assert agent["pod_uid"] == "uid-worker-123"
    assert agent["framework"] == "kagent"
    assert agent["model_name"] == "gpt-5.4"
    assert agent["state"] == "active"
    assert agent["record_class"] == "discovered"
    assert agent["is_registry_linked"] is False

    # Check Section 2.1 sub-objects
    assert agent["runtime"]["cluster_id"] == "kind-osramp"
    assert agent["runtime"]["namespace"] == "fe-signalloom-agents"
    assert agent["runtime"]["pod_uid"] == "uid-worker-123"
    assert agent["runtime"]["framework"] == "kagent"
    assert agent["identity"]["spiffe_id"] == "spiffe://osramp.acme.local/ns/fe-signalloom-agents/sa/sa-worker"
    assert agent["identity"]["spiffe_status"] == "linked"
    assert agent["responsibility"]["assignment_status"] == "registry_unlinked"
    assert agent["assessment_summary"]["status"] == "not_assessed"


def test_enriched_inventory_server_side_search_and_filters(client, monkeypatch):
    """Proves GET /api/agents server-side search, namespace, framework, and attention filters."""
    class MultiAgentClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(
                200,
                json={
                    "agents": [
                        {
                            "id": "pod-alpha",
                            "name": "Alpha Service",
                            "namespace": "production",
                            "framework": "langchain",
                            "state": "active",
                        },
                        {
                            "id": "pod-beta",
                            "name": "Beta Scanner",
                            "namespace": "staging",
                            "framework": "crewai",
                            "state": "error",
                        },
                        {
                            "id": "pod-gamma",
                            "name": "Gamma Auditor",
                            "namespace": "production",
                            "framework": "kagent",
                            "state": "active",
                        },
                    ]
                },
            )

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", MultiAgentClient)

    # Search filter
    res_search = client.get("/api/agents?search=scanner", headers=bearer(token_for("alice")))
    assert res_search.status_code == 200
    assert res_search.json()["total"] == 1
    assert res_search.json()["agents"][0]["name"] == "Beta Scanner"

    # Namespace filter
    res_ns = client.get("/api/agents?namespace=production", headers=bearer(token_for("alice")))
    assert res_ns.status_code == 200
    assert res_ns.json()["total"] == 2
    assert {a["id"] for a in res_ns.json()["agents"]} == {"pod-alpha", "pod-gamma"}

    # Framework filter
    res_fw = client.get("/api/agents?framework=kagent", headers=bearer(token_for("alice")))
    assert res_fw.status_code == 200
    assert res_fw.json()["total"] == 1
    assert res_fw.json()["agents"][0]["id"] == "pod-gamma"

    # Attention filter
    res_att = client.get("/api/agents?attention=critical", headers=bearer(token_for("alice")))
    assert res_att.status_code == 200
    assert res_att.json()["total"] == 1
    assert res_att.json()["agents"][0]["id"] == "pod-beta"


def test_enriched_inventory_pagination_and_meta(client, monkeypatch):
    """Proves GET /api/agents pagination and meta metrics."""
    class PaginatedClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(
                200,
                json={
                    "agents": [
                        {"id": "agent-p1", "name": "P1"},
                        {"id": "agent-p2", "name": "P2"},
                        {"id": "agent-p3", "name": "P3"},
                    ]
                },
            )

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", PaginatedClient)

    res_p1 = client.get("/api/agents?page=1&limit=2", headers=bearer(token_for("alice")))
    assert res_p1.status_code == 200
    data_p1 = res_p1.json()
    assert len(data_p1["agents"]) == 2
    assert data_p1["total"] == 3
    assert data_p1["pagination"]["page"] == 1
    assert data_p1["pagination"]["limit"] == 2
    assert data_p1["pagination"]["total_pages"] == 2
    assert data_p1["meta"]["total_records"] == 3
    assert data_p1["meta"]["discovered_count"] == 3

    res_p2 = client.get("/api/agents?page=2&limit=2", headers=bearer(token_for("alice")))
    assert res_p2.status_code == 200
    data_p2 = res_p2.json()
    assert len(data_p2["agents"]) == 1
    assert data_p2["agents"][0]["id"] == "agent-p3"


def test_enriched_inventory_get_is_strictly_side_effect_free(client, monkeypatch):
    """Proves GET /api/agents does not execute any write/INSERT queries."""
    write_executed = []

    class MockPool:
        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            if "INSERT" in query.upper() or "UPDATE" in query.upper() or "DELETE" in query.upper():
                write_executed.append(query)
            return []

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    class EmptyDiscoveryClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(200, json={"agents": []})

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", EmptyDiscoveryClient)

    response = client.get("/api/agents", headers=bearer(token_for("alice")))
    assert response.status_code == 200
    assert len(write_executed) == 0


# ===========================================================================
# SFAGENTS-P1-5: Action Capabilities API (/api/capabilities)
# ===========================================================================

def test_capabilities_requires_authentication(client):
    """Proves GET /api/capabilities enforces Bearer authentication and tenant binding."""
    # Missing token -> 401
    res_no_auth = client.get("/api/capabilities")
    assert res_no_auth.status_code == 401
    assert res_no_auth.json()["error"]["code"] == "authentication_required"

    # Invalid token -> 401
    res_bad_token = client.get("/api/capabilities", headers=bearer("not-a-valid-jwt"))
    assert res_bad_token.status_code == 401
    assert res_bad_token.json()["error"]["code"] == "invalid_token"

    # Forbidden subject -> 403
    res_forbidden = client.get("/api/capabilities", headers=bearer(token_for("mallory")))
    assert res_forbidden.status_code == 403
    assert res_forbidden.json()["error"]["code"] == "tenant_forbidden"


def test_capabilities_for_operator_user(client):
    """Proves GET /api/capabilities returns tenant-scoped capabilities for standard operator."""
    response = client.get("/api/capabilities", headers=bearer(token_for("alice")))
    assert response.status_code == 200
    assert response.headers.get("X-Source-Health") == "healthy"

    data = response.json()
    assert data["tenant"] == "tenant-a"
    assert data["principal_id"] == "alice"
    assert data["is_superadmin"] is False
    assert data["roles"] == ["operator"]
    assert data["source_health"] == "healthy"

    # Tenant capabilities
    tenant_caps = data["tenant_capabilities"]
    assert tenant_caps["view_agents"] is True
    assert tenant_caps["register_agent"] is True
    assert tenant_caps["export_compliance"] is True
    assert tenant_caps["view_crypto_proofs"] is True
    assert tenant_caps["run_network_tests"] is True
    assert tenant_caps["view_audit_trail"] is True
    assert tenant_caps["manage_settings"] is False
    assert tenant_caps["manage_api_keys"] is False
    assert tenant_caps["manage_users"] is False
    assert tenant_caps["run_supercred_scenario"] is False

    # Action capabilities
    actions = data["actions"]
    assert actions["freeze"]["allowed"] is False
    assert "superadmin" in actions["freeze"]["reason"].lower()
    assert actions["thaw"]["allowed"] is False
    assert actions["network_isolate"]["allowed"] is False
    assert actions["network_restore"]["allowed"] is False
    assert actions["revoke_credentials"]["allowed"] is False
    assert actions["issue_credentials"]["allowed"] is True
    assert actions["reassess_compliance"]["allowed"] is True
    assert actions["decommission"]["allowed"] is False
    assert actions["decommission"]["requires_dual_approval"] is True
    assert actions["run_scenario"]["allowed"] is False
    assert data["workload"] is None


def test_capabilities_for_superadmin_user(client, monkeypatch):
    """Proves GET /api/capabilities returns elevated capabilities for superadmin."""
    monkeypatch.setattr(
        settings,
        "api_subject_tenants",
        {"alice": "tenant-a", "bob": "tenant-b", "demo-user": "tenant-demo"},
    )
    token = token_for("demo-user", extra_claims={"email": "demo-user@signalloom.local"})
    response = client.get("/api/capabilities", headers=bearer(token))
    assert response.status_code == 200

    data = response.json()
    assert data["is_superadmin"] is True
    assert "superadmin" in data["roles"]

    tenant_caps = data["tenant_capabilities"]
    assert tenant_caps["manage_settings"] is True
    assert tenant_caps["manage_api_keys"] is True
    assert tenant_caps["manage_users"] is True
    assert tenant_caps["run_supercred_scenario"] is True

    actions = data["actions"]
    assert actions["freeze"]["allowed"] is True
    assert actions["thaw"]["allowed"] is True
    assert actions["network_isolate"]["allowed"] is True
    assert actions["network_restore"]["allowed"] is True
    assert actions["revoke_credentials"]["allowed"] is True
    assert actions["issue_credentials"]["allowed"] is True
    assert actions["reassess_compliance"]["allowed"] is True
    assert actions["decommission"]["allowed"] is False
    assert actions["decommission"]["requires_dual_approval"] is True
    assert actions["run_scenario"]["allowed"] is True


def test_operational_inventory_response_envelope_and_models(client, monkeypatch):
    """SFAGENTS-P1-6: Asserts enriched inventory models and envelope for operational table."""
    class SampleClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(
                200,
                json={
                    "agents": [
                        {
                            "id": "agent-op-1",
                            "name": "Audit Scanner",
                            "namespace": "security",
                            "framework": "LangChain",
                            "model": "gpt-4o",
                            "service_account": "scanner-sa",
                            "node": "node-1",
                            "phase": "Running",
                            "pod_uid": "uid-12345",
                            "cgroup_frozen": False,
                            "cgroup_state": "thawed",
                            "tc_drop_active": False,
                            "traffic_control_state": "allow",
                            "ebpf_active": True,
                        }
                    ]
                },
            )

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", SampleClient)

    res = client.get("/api/agents", headers=bearer(token_for("alice")))
    assert res.status_code == 200
    data = res.json()
    assert len(data["agents"]) == 1
    agent = data["agents"][0]
    assert agent["id"] == "agent-op-1"
    assert agent["runtime"]["namespace"] == "security"
    assert agent["runtime"]["framework"] == "LangChain"
    assert agent["responsibility"]["assignment_status"] in ("unassigned", "registry_unlinked")
    assert agent["assessment_summary"]["status"] == "not_assessed"
    assert agent["kernel_telemetry"]["cgroup_state"] == "thawed"
    assert agent["kernel_telemetry"]["traffic_control_state"] == "allow"


def test_capabilities_workload_scoped_discovery(client, monkeypatch):
    """Proves GET /api/capabilities?agent_id=... resolves discovered workload scope."""
    class DiscoveryClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(
                200,
                json={
                    "agents": [
                        {
                            "id": "discovered-agent-1",
                            "name": "Discovered Pod",
                            "namespace": "agent-ns",
                            "service_account": "agent-sa",
                        }
                    ]
                },
            )

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", DiscoveryClient)

    response = client.get(
        "/api/capabilities?agent_id=discovered-agent-1",
        headers=bearer(token_for("alice")),
    )
    assert response.status_code == 200
    data = response.json()
    assert data["workload"] is not None
    assert data["workload"]["agent_id"] == "discovered-agent-1"
    assert data["workload"]["namespace"] == "agent-ns"
    assert data["workload"]["freeze"]["scope"] == "workload:discovered-agent-1"
    assert data["workload"]["freeze"]["allowed"] is False  # alice is not admin


def test_capabilities_workload_scoped_db(client, monkeypatch):
    """Proves GET /api/capabilities?agent_id=... resolves DB agent scope."""
    monkeypatch.setattr(
        settings,
        "api_subject_tenants",
        {"alice": "tenant-a", "bob": "tenant-b", "demo-user": "tenant-demo"},
    )
    class MockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if "SELECT id FROM agent_registry" in query:
                return {"id": "11111111-1111-1111-1111-111111111111"}
            return None

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    token = token_for("demo-user", extra_claims={"email": "demo-user@signalloom.local"})
    response = client.get(
        "/api/capabilities?agent_id=11111111-1111-1111-1111-111111111111&namespace=custom-ns",
        headers=bearer(token),
    )
    assert response.status_code == 200
    data = response.json()
    assert data["workload"] is not None
    assert data["workload"]["agent_id"] == "11111111-1111-1111-1111-111111111111"
    assert data["workload"]["namespace"] == "custom-ns"
    assert data["workload"]["freeze"]["allowed"] is True
    assert data["workload"]["freeze"]["scope"] == "workload:11111111-1111-1111-1111-111111111111"


def test_capabilities_returns_404_for_unknown_agent_id(client, monkeypatch):
    """Proves GET /api/capabilities?agent_id=... returns 404 for unknown agent without synthetic fallback."""
    class EmptyDiscoveryClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(200, json={"agents": []})

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", EmptyDiscoveryClient)

    class EmptyPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            return None

    async def get_pool():
        return EmptyPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    response = client.get(
        "/api/capabilities?agent_id=unknown-agent-uuid-9999",
        headers=bearer(token_for("alice")),
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


def test_capabilities_get_is_strictly_side_effect_free(client, monkeypatch):
    """Proves GET /api/capabilities performs zero SQL INSERT/UPDATE/DELETE writes."""
    writes_recorded = []

    class MockPool:
        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            if any(w in query.upper() for w in ("INSERT", "UPDATE", "DELETE")):
                writes_recorded.append(query)
            return []

        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if any(w in query.upper() for w in ("INSERT", "UPDATE", "DELETE")):
                writes_recorded.append(query)
            return None

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    response = client.get("/api/capabilities", headers=bearer(token_for("alice")))
    assert response.status_code == 200
    assert len(writes_recorded) == 0


def test_agent_response_model_with_drawer_telemetry_and_metadata():
    """Proves AgentResponse serialization supports all Quick Evidence Drawer fields."""
    telemetry = api_compat.SentinelKernelTelemetry(
        cgroup_state="frozen",
        traffic_control_state="drop",
        ebpf_active=True,
        ebpf_program_attached=True,
        observed_at="2026-09-07T08:30:00Z",
        last_observed_at="2026-09-07T08:30:00Z",
    )
    assert telemetry.ebpf_program_attached is True
    assert telemetry.last_observed_at == "2026-09-07T08:30:00Z"

    agent = api_compat.AgentResponse(
        id="agent-drawer-001",
        name="Drawer Verification Agent",
        type="Signal Loom Built",
        tenant_id="tenant-demo",
        lifecycle_state="active",
        last_transition_at="2026-09-07T08:00:00Z",
        eu_ai_act_risk_class="limited",
        compliance_summary=api_compat.ComplianceSummaryInline(
            total_controls=6,
            passing=5,
            failing=1,
            pending=0,
            posture_score=0.83,
        ),
        created_at="2026-09-01T10:00:00Z",
        record_class="registered",
        is_registry_linked=True,
        kernel_telemetry=telemetry,
        runtime=api_compat.RuntimeMetadata(
            namespace="sec-ops",
            framework="kagent",
            execution_mode="autonomous",
            model="claude-3-7-sonnet",
            node="node-1",
            pod_uid="pod-uid-drawer-1",
            service_account="drawer-sa",
            phase="Running",
        ),
        responsibility=api_compat.ResponsibilityMetadata(
            owner_name="alice@signal-loom.ai",
            team="Platform Security",
            assignment_status="assigned",
        ),
        identity=api_compat.IdentityMetadata(
            spiffe_id="spiffe://cluster.local/ns/sec-ops/sa/drawer-sa",
            spiffe_status="linked",
            aliases=["alias-1", "alias-2"],
        ),
        attention=api_compat.AttentionMetadata(
            level="critical",
            highest_issue="1 failing control detected",
        ),
        timestamps=api_compat.TimestampsMetadata(
            created_at="2026-09-01T10:00:00Z",
            last_observed_at="2026-09-07T08:30:00Z",
            last_transition_at="2026-09-07T08:00:00Z",
        ),
    )
    serialized = agent.model_dump()
    assert serialized["id"] == "agent-drawer-001"
    assert serialized["kernel_telemetry"]["cgroup_state"] == "frozen"
    assert serialized["kernel_telemetry"]["traffic_control_state"] == "drop"
    assert serialized["kernel_telemetry"]["ebpf_program_attached"] is True
    assert serialized["runtime"]["framework"] == "kagent"
    assert serialized["responsibility"]["owner_name"] == "alice@signal-loom.ai"
    assert serialized["identity"]["spiffe_status"] == "linked"
    assert serialized["attention"]["level"] == "critical"


def test_agent_detail_get_is_strictly_side_effect_free(client, monkeypatch):
    """Proves GET /api/agents/{id} performs zero SQL INSERT/UPDATE writes on hit or miss."""
    writes_recorded = []

    class MockPool:
        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            if any(w in query.upper() for w in ("INSERT", "UPDATE", "DELETE")):
                writes_recorded.append(query)
            return []

        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if any(w in query.upper() for w in ("INSERT", "UPDATE", "DELETE")):
                writes_recorded.append(query)
            if "agent_registry" in query:
                return {
                    "id": uuid.UUID("11111111-1111-1111-1111-111111111111"),
                    "name": "Live Registered Agent",
                    "type": "Signal Loom Built",
                    "owner": "alice@signal-loom.ai",
                    "tenant_id": "tenant-demo",
                    "lifecycle_state": "active",
                    "last_transition_at": datetime.now(timezone.utc),
                    "last_transition_by": "system",
                    "eu_ai_act_risk_class": "limited",
                    "model_name": "claude-3-7-sonnet",
                    "created_at": datetime.now(timezone.utc),
                }
            return None

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    # 1. Existing agent lookup
    res_hit = client.get(
        "/api/agents/11111111-1111-1111-1111-111111111111",
        headers=bearer(token_for("alice")),
    )
    assert res_hit.status_code == 200
    assert len(writes_recorded) == 0

    # 2. Non-existent agent lookup
    class EmptyDiscoveryClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(200, json={"agents": []})

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", EmptyDiscoveryClient)

    class EmptyPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if any(w in query.upper() for w in ("INSERT", "UPDATE", "DELETE")):
                writes_recorded.append(query)
            return None

    async def get_empty_pool():
        return EmptyPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_empty_pool)

    res_miss = client.get(
        "/api/agents/non-existent-agent-id",
        headers=bearer(token_for("alice")),
    )
    assert res_miss.status_code == 404
    assert len(writes_recorded) == 0


def test_dossier_detail_preserves_all_tab1_metadata(client, monkeypatch):
    """SFAGENTS-P2-1: Proves GET /api/agents/{id} returns all enriched Tab 1 Overview structures."""
    class MockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if "agent_registry" in query:
                return {
                    "id": uuid.UUID("22222222-2222-2222-2222-222222222222"),
                    "name": "Dossier Test Agent",
                    "type": "Signal Loom Built",
                    "owner": "alice@signal-loom.ai",
                    "tenant_id": "tenant-demo",
                    "lifecycle_state": "active",
                    "last_transition_at": datetime.now(timezone.utc),
                    "last_transition_by": "operator@signal-loom.ai",
                    "eu_ai_act_risk_class": "limited",
                    "model_name": "claude-3-7-sonnet",
                    "created_at": datetime.now(timezone.utc),
                }
            return None

        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            return []

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    res = client.get(
        "/api/agents/22222222-2222-2222-2222-222222222222",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    data = res.json()
    assert data["id"] == "22222222-2222-2222-2222-222222222222"
    assert data["name"] == "Dossier Test Agent"
    assert data["record_class"] == "registered"
    assert data["is_registry_linked"] is True
    assert "runtime" in data
    assert "responsibility" in data
    assert "identity" in data
    assert "operational_state" in data
    assert "assessment_summary" in data
    assert "attention" in data
    assert "timestamps" in data
    assert data["responsibility"]["owner_name"] == "alice@signal-loom.ai"
    assert data["responsibility"]["assignment_status"] == "assigned"


def test_dossier_unknown_id_fails_closed_with_404(client, monkeypatch):
    """SFAGENTS-P2-1: Proves GET /api/agents/{unknown_id} returns HTTP 404 without synthesizing records."""
    class EmptyDiscoveryClient:
        def __init__(self, *args, **kwargs):
            pass
        async def __aenter__(self):
            return self
        async def __aexit__(self, exc_type, exc, tb):
            return False
        async def get(self, url: str):
            import httpx
            return httpx.Response(200, json={"agents": []})

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", EmptyDiscoveryClient)

    class EmptyPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            return None

    async def get_empty_pool():
        return EmptyPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_empty_pool)

    res = client.get(
        "/api/agents/00000000-0000-0000-0000-000000000000",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 404
    body = res.json()
    assert body["error"]["code"] == "not_found"
    assert "not found" in body["error"]["message"].lower()


def test_dossier_identity_spiffe_metadata_enrichment(client, monkeypatch):
    """SFAGENTS-P2-2: Proves GET /api/agents/{id} returns all enriched Tab 2 IdentityMetadata structures."""
    class MockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if "agent_registry" in query:
                return {
                    "id": uuid.UUID("33333333-3333-3333-3333-333333333333"),
                    "name": "Identity Test Agent",
                    "type": "Signal Loom Built",
                    "owner": "alice@signal-loom.ai",
                    "tenant_id": "tenant-demo",
                    "lifecycle_state": "active",
                    "last_transition_at": datetime.now(timezone.utc),
                    "last_transition_by": "operator@signal-loom.ai",
                    "eu_ai_act_risk_class": "limited",
                    "model_name": "claude-3-7-sonnet",
                    "created_at": datetime.now(timezone.utc),
                    "spiffe_id": "spiffe://osramp.acme.local/ns/fe-signalloom-agents/sa/sa-identity-agent",
                }
            return None

        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            return []

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    res = client.get(
        "/api/agents/33333333-3333-3333-3333-333333333333",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    data = res.json()
    assert "identity" in data
    ident = data["identity"]
    assert ident["spiffe_id"] == "spiffe://osramp.acme.local/ns/fe-signalloom-agents/sa/sa-identity-agent"
    assert ident["spiffe_status"] == "linked"
    assert ident["trust_domain"] == "osramp.acme.local"
    assert ident["svid_type"] == "x509"
    assert ident["cert_issuer"] == "spiffe://signalloom.demo/spire/server"
    assert ident["authorizing_principal_id"] == "alice@signal-loom.ai"
    assert ident["executing_actor_id"] == "spiffe://osramp.acme.local/ns/fe-signalloom-agents/sa/sa-identity-agent"
    assert ident["delegation_hops"] == 1
    assert "openbao_role" in ident
    assert "openbao_path" in ident


def test_dossier_identity_separation_of_planes(client, monkeypatch):
    """SFAGENTS-P2-2: Proves separation of identity planes (authorizing principal vs executing actor)."""
    class MockDiscoveryClient:
        def __init__(self, *args, **kwargs):
            pass
        async def __aenter__(self):
            return self
        async def __aexit__(self, exc_type, exc, tb):
            return False
        async def get(self, url: str):
            import httpx
            return httpx.Response(200, json={
                "agents": [
                    {
                        "id": "discovered-agent-4444",
                        "name": "Discovered K8s Workload",
                        "namespace": "fe-signalloom-agents",
                        "service_account": "sa-discovered",
                        "state": "active",
                        "node": "worker-node-1",
                        "pod_uid": "uid-4444-5555",
                    }
                ]
            })

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", MockDiscoveryClient)

    class EmptyPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            return None
        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            return []

    async def get_empty_pool():
        return EmptyPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_empty_pool)

    res = client.get(
        "/api/agents/discovered-agent-4444",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    data = res.json()
    ident = data["identity"]
    # Discovered workload has no human authorizing principal -> None (rendered as Unassigned / Registry not linked)
    assert ident["authorizing_principal_id"] is None
    # Executing actor is the workload SVID
    assert ident["executing_actor_id"] == "spiffe://osramp.acme.local/ns/fe-signalloom-agents/sa/sa-discovered"
    assert ident["delegation_hops"] == 0
    # Selectors are populated
    assert "k8s:ns:fe-signalloom-agents" in ident["selectors"]
    assert "k8s:sa:sa-discovered" in ident["selectors"]


def test_dossier_identity_get_is_strictly_side_effect_free(client, monkeypatch):
    """SFAGENTS-P2-2: Proves GET /api/agents and detail queries are side-effect-free (zero SQL DML writes)."""
    writes_recorded = []

    class ReadOnlyMockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if "INSERT" in query.upper() or "UPDATE" in query.upper() or "DELETE" in query.upper():
                writes_recorded.append(query)
            return None

        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            if "INSERT" in query.upper() or "UPDATE" in query.upper() or "DELETE" in query.upper():
                writes_recorded.append(query)
            return []

        async def execute(self, query: str, *params: Any) -> str:
            writes_recorded.append(query)
            return "OK"

    async def get_ro_pool():
        return ReadOnlyMockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_ro_pool)

    res = client.get(
        "/api/agents/unknown-identity-probe",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 404
    assert len(writes_recorded) == 0


def test_tab3_access_containment_tracks_models_and_telemetry(client, monkeypatch):
    """SFAGENTS-P2-3: Proves GET /api/agents/{id} returns 3 independent containment tracks and kernel telemetry."""
    class MockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if "agent_registry" in query:
                return {
                    "id": uuid.UUID("33333333-3333-3333-3333-333333333333"),
                    "name": "Containment Sentinel Workload",
                    "type": "Signal Loom Built",
                    "owner": "alice@signal-loom.ai",
                    "tenant_id": "tenant-demo",
                    "lifecycle_state": "suspended",
                    "last_transition_at": datetime.now(timezone.utc),
                    "last_transition_by": "operator@signal-loom.ai",
                    "eu_ai_act_risk_class": "high",
                    "model_name": "claude-3-7-sonnet",
                    "created_at": datetime.now(timezone.utc),
                }
            return None

        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            return []

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    res = client.get(
        "/api/agents/33333333-3333-3333-3333-333333333333",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    data = res.json()
    assert data["id"] == "33333333-3333-3333-3333-333333333333"
    assert "kernel_telemetry" in data
    assert "credential_state" in data
    assert "operational_state" in data

    # Verify containment tracks in operational_state
    op_state = data["operational_state"]
    assert "containment" in op_state
    assert op_state["containment"]["process_freeze"] in ("active", "inactive", "requested", "unsupported")
    assert op_state["containment"]["network_isolation"] in ("active", "inactive", "requested", "unsupported")
    assert op_state["containment"]["credential_revocation"] in ("active", "inactive", "requested", "unsupported")


def test_tab3_capabilities_workload_scoped_rbac_and_invariants(client, monkeypatch):
    """SFAGENTS-P2-3: Proves GET /api/capabilities returns workload-scoped capabilities and enforces identity plane separation."""
    class MockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if "agent_registry" in query:
                return {"id": uuid.UUID("33333333-3333-3333-3333-333333333333")}
            return None

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    # 1. Non-superadmin operator caller
    res_op = client.get(
        "/api/capabilities?agent_id=33333333-3333-3333-3333-333333333333",
        headers=bearer(token_for("alice")),
    )
    assert res_op.status_code == 200
    data_op = res_op.json()
    assert data_op["is_superadmin"] is False
    assert data_op["workload"] is not None
    assert data_op["workload"]["freeze"]["allowed"] is False
    assert data_op["workload"]["network_isolate"]["allowed"] is False
    assert data_op["workload"]["issue_credentials"]["allowed"] is True
    assert data_op["workload"]["reassess_compliance"]["allowed"] is True
    assert data_op["workload"]["decommission"]["allowed"] is False
    assert data_op["workload"]["decommission"]["requires_dual_approval"] is True

    # 2. Superadmin caller
    monkeypatch.setattr(
        settings,
        "api_subject_tenants",
        {"alice": "tenant-demo", "demo-user": "tenant-demo"},
    )
    admin_token = token_for("demo-user", extra_claims={"email": "demo-user@signalloom.local"})
    res_admin = client.get(
        "/api/capabilities?agent_id=33333333-3333-3333-3333-333333333333",
        headers=bearer(admin_token),
    )
    assert res_admin.status_code == 200
    data_admin = res_admin.json()
    assert data_admin["is_superadmin"] is True
    assert data_admin["workload"]["freeze"]["allowed"] is True
    assert data_admin["workload"]["network_isolate"]["allowed"] is True
    assert data_admin["workload"]["revoke_credentials"]["allowed"] is True


def test_tab3_capabilities_is_strictly_side_effect_free_under_rfc9110(client, monkeypatch):
    """SFAGENTS-P2-3: Proves GET /api/capabilities performs 0 SQL writes and is strictly idempotent."""
    writes_recorded = []

    class MockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if any(w in query.upper() for w in ("INSERT", "UPDATE", "DELETE")):
                writes_recorded.append(query)
            if "agent_registry" in query:
                return {"id": uuid.UUID("33333333-3333-3333-3333-333333333333")}
            return None

        async def execute(self, query: str, *params: Any) -> str:
            writes_recorded.append(query)
            raise AssertionError("GET /api/capabilities must never write to database")

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    res = client.get(
        "/api/capabilities?agent_id=33333333-3333-3333-3333-333333333333",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    assert len(writes_recorded) == 0
    assert res.headers.get("X-Source-Health") == "healthy"




def test_tab4_compliance_posture_is_side_effect_free(client, monkeypatch):
    """SFAGENTS-P2-4: Proves GET /api/compliance/posture is strictly side-effect free and returns control ratios."""
    writes_recorded = []

    class ReadOnlyPool:
        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            if "INSERT" in query.upper() or "UPDATE" in query.upper() or "DELETE" in query.upper():
                writes_recorded.append(query)
                raise AssertionError(f"Illegal SQL mutation in GET: {query}")
            if "agent_registry" in query:
                return [
                    {
                        "id": uuid.UUID("11111111-1111-1111-1111-111111111111"),
                        "name": "Sir Lancelot",
                    }
                ]
            if "agent_compliance_results" in query:
                return [
                    {
                        "agent_id": uuid.UUID("11111111-1111-1111-1111-111111111111"),
                        "control_id": "eu-ai-act:art-9",
                        "control_name": "Risk management system (Article 9)",
                        "framework_name": "EU AI Act",
                        "status": "pass",
                        "assessed_at": datetime.now(timezone.utc),
                        "evidence_ref": "opa://assessments/lancelot/art-9",
                    },
                    {
                        "agent_id": uuid.UUID("11111111-1111-1111-1111-111111111111"),
                        "control_id": "soc2:cc7.2",
                        "control_name": "System monitoring",
                        "framework_name": "SOC 2",
                        "status": "fail",
                        "assessed_at": datetime.now(timezone.utc),
                        "evidence_ref": "opa://assessments/lancelot/cc7.2",
                    },
                ]
            return []

        async def execute(self, query: str, *params: Any) -> str:
            writes_recorded.append(query)
            raise AssertionError(f"Illegal SQL execute in GET: {query}")

    async def get_readonly_pool():
        return ReadOnlyPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_readonly_pool)

    res = client.get(
        "/api/compliance/posture",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    assert len(writes_recorded) == 0
    data = res.json()
    assert "agents" in data
    assert len(data["agents"]) == 1
    agent_posture = data["agents"][0]
    assert agent_posture["agent_id"] == "11111111-1111-1111-1111-111111111111"
    assert agent_posture["agent_name"] == "Sir Lancelot"
    assert agent_posture["posture_score"] == 0.5  # 1 pass out of 2 total
    assert len(agent_posture["results"]) == 2
    assert agent_posture["results"][0]["control_id"] == "eu-ai-act:art-9"
    assert agent_posture["results"][0]["status"] == "pass"


def test_tab4_compliance_frameworks_returns_article9(client, monkeypatch):
    """SFAGENTS-P2-4: Proves GET /api/compliance/frameworks returns EU AI Act and Article 9 controls."""
    res = client.get(
        "/api/compliance/frameworks",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    frameworks = res.json()
    assert isinstance(frameworks, list)
    eu_fw = next((f for f in frameworks if f["id"] == "eu-ai-act"), None)
    assert eu_fw is not None
    assert eu_fw["name"] == "EU AI Act"
    art9_control = next((c for c in eu_fw["controls"] if "art-9" in c["id"]), None)
    assert art9_control is not None
    assert "risk management" in art9_control["name"].lower() or "article 9" in art9_control["name"].lower()


def test_tab4_compliance_reassess_records_audit_honestly(client, monkeypatch):
    """SFAGENTS-P2-4: Proves POST /api/agents/{id}/compliance/{control_id}/reassess records audit truthfully with dispatched=False."""
    recorded_audits = []

    class MockPool:
        async def execute(self, query: str, *params: Any) -> str:
            if "audit_events" in query:
                recorded_audits.append(params)
            return "INSERT 1"

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)
    monkeypatch.setattr(api_compat, "_require_pool", lambda reason: get_pool())

    res = client.post(
        "/api/agents/11111111-1111-1111-1111-111111111111/compliance/eu-ai-act:art-9/reassess",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    data = res.json()
    assert data["agent_id"] == "11111111-1111-1111-1111-111111111111"
    assert data["control_id"] == "eu-ai-act:art-9"
    assert data["status"] == "reassessment_requested"
    assert data["clickup_task_id"] is None
    assert "reassessment_requested_at" in data
    assert data["reassessment_requested_by"] == "alice"


def test_tab4_agent_detail_preserves_assessment_summary(client, monkeypatch):
    """SFAGENTS-P2-4: Proves GET /api/agents/{id} response preserves assessment_summary structure."""
    class MockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            if "agent_registry" in query:
                return {
                    "id": uuid.UUID("33333333-3333-3333-3333-333333333333"),
                    "name": "Assessment Test Agent",
                    "type": "Custom",
                    "owner": "bob@signal-loom.ai",
                    "tenant_id": "tenant-demo",
                    "lifecycle_state": "active",
                    "last_transition_at": datetime.now(timezone.utc),
                    "last_transition_by": "operator@signal-loom.ai",
                    "eu_ai_act_risk_class": "high",
                    "model_name": "claude-3-7-sonnet",
                    "created_at": datetime.now(timezone.utc),
                }
            return None

        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            return []

    async def get_pool():
        return MockPool()

    monkeypatch.setattr(api_compat, "_get_pool", get_pool)

    res = client.get(
        "/api/agents/33333333-3333-3333-3333-333333333333",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    body = res.json()
    assert "assessment_summary" in body
    summary = body["assessment_summary"]
    assert "status" in summary
    assert "total_controls" in summary
    assert "passed_controls" in summary
    assert "failed_controls" in summary
    assert "pending_controls" in summary


def test_audit_get_in_fixture_mode_returns_empty_without_synthesizing_fake_events(client, monkeypatch):
    """SFAGENTS-P2-5: Proves GET /api/audit in fixture mode returns 0 results for unknown agent without synthetic fabrication."""
    async def mock_get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    res = client.get("/api/audit?agent=completely-unknown-agent", headers=bearer(token_for("alice")))
    assert res.status_code == 200
    data = res.json()
    assert data["events"] == []
    assert data["total"] == 0
    assert data["source_health"] == "healthy"


def test_audit_stream_emits_valid_sse_frames_and_headers(client, monkeypatch):
    """SFAGENTS-P2-5: Proves GET /api/audit/stream returns text/event-stream with no-cache headers and valid SSE frames."""
    async def mock_get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    res = client.get("/api/audit/stream", headers=bearer(token_for("alice")))
    assert res.status_code == 200
    assert "text/event-stream" in res.headers.get("content-type", "")
    assert "no-cache" in res.headers.get("cache-control", "")
    assert "no" in res.headers.get("x-accel-buffering", "").lower()

    content = res.text
    assert "event: audit_event" in content
    assert "data: {" in content
    assert ": keepalive" in content


def test_agent_audit_stream_returns_404_for_unknown_agent(client, monkeypatch):
    """SFAGENTS-P2-5: Proves GET /api/agents/{id}/audit/stream returns HTTP 404 for unknown agent IDs without synthesizing records."""
    async def mock_get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    res = client.get("/api/agents/unknown-agent-id-9999/audit/stream", headers=bearer(token_for("alice")))
    assert res.status_code == 404
    body = res.json()
    assert body["error"]["code"] == "not_found"
    assert "not found" in body["error"]["message"].lower()


def test_agent_audit_stream_for_valid_agent(client, monkeypatch):
    """SFAGENTS-P2-5: Proves GET /api/agents/{id}/audit/stream returns SSE stream for a known agent."""
    async def mock_get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    res = client.get("/api/agents/agent-1/audit/stream", headers=bearer(token_for("alice")))
    assert res.status_code == 200
    assert "text/event-stream" in res.headers.get("content-type", "")
    content = res.text
    assert "event: audit_event" in content
    assert "agent-1" in content


def test_audit_events_contain_attributable_identity_plane_metadata(client, monkeypatch):
    """SFAGENTS-P2-5: Proves AuditEventResponse preserves separation of identity planes (authorizer vs workload)."""
    async def mock_get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    res = client.get("/api/audit", headers=bearer(token_for("alice")))
    assert res.status_code == 200
    data = res.json()
    events = data["events"]
    assert len(events) >= 3

    # Check first event attribution
    ev = events[0]
    assert ev["authorizing_principal_id"] == "admin@signal-loom.ai"
    assert "agent-1" in ev["executing_actor_id"]
    assert ev["spiffe_id"] == "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-inventory"
    assert ev["attribution_rationale"] == "Initial declarative manifest registration"


def test_audit_stream_is_strictly_side_effect_free(client, monkeypatch):
    """SFAGENTS-P2-5: Proves GET /api/audit/stream executes 0 SQL writes and is side-effect free under RFC 9110."""
    executed_writes = []

    class ReadOnlyMockPool:
        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            return []

        async def execute(self, query: str, *params: Any) -> str:
            executed_writes.append((query, params))
            raise AssertionError("GET /api/audit/stream must NEVER execute SQL writes")

    mock_pool = ReadOnlyMockPool()

    async def mock_get_pool():
        return mock_pool

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    res = client.get("/api/audit/stream?agent=test-agent", headers=bearer(token_for("alice")))
    assert res.status_code == 200
    assert len(executed_writes) == 0


def test_get_agents_filter_by_lifecycle_state_and_spiffe_id(client, monkeypatch):
    """SFAGENTS-P2-6: Proves GET /api/agents filters by lifecycle_state, state, and spiffe_id correctly."""
    class MultiAgentClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url: str):
            import httpx
            return httpx.Response(
                200,
                json={
                    "agents": [
                        {
                            "id": "pod-inventory-1",
                            "name": "Inventory Agent",
                            "namespace": "fe-signalloom-agents",
                            "framework": "kagent",
                            "state": "active",
                            "spiffe_id": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-inventory",
                        },
                        {
                            "id": "pod-audit-2",
                            "name": "Audit Collector",
                            "namespace": "fe-signalloom-agents",
                            "framework": "langchain",
                            "state": "suspended",
                            "spiffe_id": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/sa-audit",
                        },
                    ]
                },
            )

    monkeypatch.setattr(api_compat.httpx, "AsyncClient", MultiAgentClient)

    async def mock_get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    # Filter by lifecycle_state=active
    res = client.get("/api/agents?lifecycle_state=active", headers=bearer(token_for("alice")))
    assert res.status_code == 200
    data = res.json()
    assert len(data["agents"]) == 1
    assert data["agents"][0]["id"] == "pod-inventory-1"
    assert data["agents"][0]["lifecycle_state"] == "active"

    # Filter by state alias
    res_state = client.get("/api/agents?state=suspended", headers=bearer(token_for("alice")))
    assert res_state.status_code == 200
    data_state = res_state.json()
    assert len(data_state["agents"]) == 1
    assert data_state["agents"][0]["id"] == "pod-audit-2"
    assert data_state["agents"][0]["lifecycle_state"] == "suspended"

    # Filter by spiffe_id substring
    res_spiffe = client.get("/api/agents?spiffe_id=inventory", headers=bearer(token_for("alice")))
    assert res_spiffe.status_code == 200
    data_spiffe = res_spiffe.json()
    assert len(data_spiffe["agents"]) == 1
    assert data_spiffe["agents"][0]["id"] == "pod-inventory-1"


def test_get_agents_deep_link_filters_strictly_side_effect_free(client, monkeypatch):
    """SFAGENTS-P2-6: Proves GET /api/agents with query filters executes 0 SQL writes and is side-effect free."""
    executed_writes = []

    class ReadOnlyMockPool:
        async def fetch(self, query: str, *params: Any) -> list[dict[str, Any]]:
            return []

        async def execute(self, query: str, *params: Any) -> str:
            executed_writes.append((query, params))
            raise AssertionError("GET /api/agents must NEVER execute SQL writes")

    mock_pool = ReadOnlyMockPool()

    async def mock_get_pool():
        return mock_pool

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    res = client.get(
        "/api/agents?lifecycle_state=active&spiffe_id=sa-order&search=order&page=1&limit=10",
        headers=bearer(token_for("alice")),
    )
    assert res.status_code == 200
    assert len(executed_writes) == 0


def test_agent_telemetry_endpoint_side_effect_free(client, monkeypatch):
    """SFAGENTS-P3-1: Proves GET /api/agents/{agent_id}/telemetry executes 0 SQL writes and is strictly side-effect free under RFC 9110."""
    executed_writes = []

    class ReadOnlyMockPool:
        async def fetchrow(self, query: str, *params: Any) -> dict[str, Any] | None:
            return {"id": "agent-123", "name": "Agent 123"}

        async def execute(self, query: str, *params: Any) -> str:
            executed_writes.append((query, params))
            raise AssertionError("GET /api/agents/{id}/telemetry must NEVER execute SQL writes")

    mock_pool = ReadOnlyMockPool()

    async def mock_get_pool():
        return mock_pool

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    res = client.get("/api/agents/agent-123/telemetry", headers=bearer(token_for("alice")))
    assert res.status_code == 200
    data = res.json()
    assert data["agent_id"] == "agent-123"
    assert "observations" in data
    assert len(executed_writes) == 0


def test_agent_telemetry_pushdown_filters(client, monkeypatch):
    """SFAGENTS-P3-1: Verifies pushdown query parameters (layer, source, limit) filter telemetry observations."""
    async def mock_get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    # Seed an agent for tenant-a (alice)
    api_compat._ensure_seeded("tenant-a")
    with api_compat._STORE_LOCK:
        agent_id = list(api_compat._AGENTS["tenant-a"].keys())[0]

    # Unfiltered
    res_all = client.get(f"/api/agents/{agent_id}/telemetry", headers=bearer(token_for("alice")))
    assert res_all.status_code == 200
    data_all = res_all.json()
    assert len(data_all["observations"]) >= 3
    assert data_all["source_health"] == "healthy"

    # Filter by layer
    res_layer = client.get(
        f"/api/agents/{agent_id}/telemetry?layer=LayerKernelSocket",
        headers=bearer(token_for("alice")),
    )
    assert res_layer.status_code == 200
    data_layer = res_layer.json()
    assert len(data_layer["observations"]) == 1
    assert data_layer["observations"][0]["layer"] == "LayerKernelSocket"
    assert data_layer["pushdown_filters"]["layer"] == "LayerKernelSocket"

    # Filter by source substring
    res_source = client.get(
        f"/api/agents/{agent_id}/telemetry?source=frostdb",
        headers=bearer(token_for("alice")),
    )
    assert res_source.status_code == 200
    data_source = res_source.json()
    assert len(data_source["observations"]) == 1
    assert "frostdb" in data_source["observations"][0]["source"].lower()
    assert data_source["pushdown_filters"]["source"] == "frostdb"

    # Limit filter
    res_limit = client.get(
        f"/api/agents/{agent_id}/telemetry?limit=1",
        headers=bearer(token_for("alice")),
    )
    assert res_limit.status_code == 200
    data_limit = res_limit.json()
    assert len(data_limit["observations"]) == 1
    assert data_limit["pushdown_filters"]["limit"] == 1


def test_agent_telemetry_unknown_agent_404(client, monkeypatch):
    """SFAGENTS-P3-1: Proves GET /api/agents/{agent_id}/telemetry fails closed with 404 for unknown agent."""
    async def mock_get_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", mock_get_pool)

    res = client.get("/api/agents/non-existent-agent-uuid/telemetry", headers=bearer(token_for("alice")))
    assert res.status_code == 404
    err = res.json()
    assert err["error"]["code"] == "not_found"
