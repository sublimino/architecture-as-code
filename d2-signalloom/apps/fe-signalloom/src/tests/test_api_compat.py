import base64
import json
import socket
import time
import uuid
from datetime import datetime, timezone
from types import SimpleNamespace

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
    assert set(frameworks.json()[0]) == {
        "id", "name", "versions", "totalControls", "passedControls",
        "failedControls", "totalExposureGbp",
    }
    assert set(summary.json()) == {
        "totalChecks", "passed", "failed", "totalAle", "totalVar95",
        "totalTvar", "totalCarriedGbp", "scanTimestamp", "frameworks",
    }
    assert summary.json()["frameworks"] == frameworks.json()


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
