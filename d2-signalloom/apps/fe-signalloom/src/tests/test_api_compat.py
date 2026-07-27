import base64
import hashlib
import hmac
import json
import socket
import time

import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from main import app


class ReadyPool:
    async def close(self):
        pass


def _segment(value: dict) -> str:
    raw = json.dumps(value, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def token_for(
    subject: str | None = "alice",
    *,
    secret: str = "test-secret",
    issuer: str = "https://issuer.test/dex",
    audience: str | list[str] = "signalloom-api",
    expires_at: int | None = None,
    header: dict | None = None,
    extra_claims: dict | None = None,
) -> str:
    now = int(time.time())
    claims = {
        "iss": issuer,
        "aud": audience,
        "iat": now,
        "nbf": now,
        "exp": expires_at if expires_at is not None else now + 300,
    }
    if subject is not None:
        claims["sub"] = subject
    if extra_claims:
        claims.update(extra_claims)
    encoded_header = _segment(header or {"alg": "HS256", "typ": "JWT"})
    encoded_claims = _segment(claims)
    signing_input = f"{encoded_header}.{encoded_claims}"
    signature = hmac.new(
        secret.encode(), signing_input.encode(), hashlib.sha256
    ).digest()
    encoded_signature = base64.urlsafe_b64encode(signature).rstrip(b"=").decode()
    return f"{signing_input}.{encoded_signature}"


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(settings, "api_jwt_secret", SecretStr("test-secret"))
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(
        settings,
        "api_subject_tenants",
        {"alice": "tenant-a", "bob": "tenant-b"},
    )

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
        lambda: token_for(secret="wrong-secret"),
        lambda: token_for(issuer="https://attacker.test/dex"),
        lambda: token_for(audience="another-api"),
        lambda: token_for(expires_at=int(time.time()) - 1),
        lambda: token_for(subject=None),
        lambda: token_for(header={"alg": "none", "typ": "JWT"}),
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
        "/api/agents",
        headers=bearer(token_for("alice", audience=["dashboard", "signalloom-api"])),
    )

    assert response.status_code == 200
    assert response.json()["tenant_id"] == "tenant-a"


def test_documented_demo_subject_maps_to_documented_demo_tenant(client, monkeypatch):
    issuer = "http://dex.inf-signalloom.svc.cluster.local:5556/dex"
    monkeypatch.setattr(settings, "api_jwt_issuer", issuer)
    monkeypatch.setattr(settings, "api_subject_tenants", {"demo-user": "tenant-demo"})

    response = client.get(
        "/api/agents",
        headers=bearer(token_for("demo-user", issuer=issuer)),
    )

    assert response.status_code == 200
    assert response.json()["tenant_id"] == "tenant-demo"


def test_authenticated_tenant_is_derived_from_subject_not_token_tenant_claim(client):
    response = client.get(
        "/api/agents",
        headers=bearer(token_for("alice", extra_claims={"tenant_id": "tenant-b"})),
    )

    assert response.status_code == 200
    assert response.json()["tenant_id"] == "tenant-a"


def test_four_compatibility_contracts_are_typed_and_tenant_scoped(client):
    headers = bearer(token_for("alice"))
    expected = {
        "/api/agents": {
            "tenant_id": "tenant-a",
            "agents": [
                {
                    "id": "tenant-a:inventory-agent",
                    "name": "Inventory Agent",
                    "status": "ready",
                }
            ],
        },
        "/api/compliance": {
            "tenant_id": "tenant-a",
            "controls": [
                {
                    "id": "tenant-a:access-boundary",
                    "status": "passing",
                    "evidence": "Local tenant boundary validated",
                }
            ],
        },
        "/api/audit": {
            "tenant_id": "tenant-a",
            "events": [
                {
                    "id": "tenant-a:baseline-ready",
                    "event_type": "baseline.ready",
                    "occurred_at": "2026-07-27T00:00:00Z",
                    "actor": "signalloom-local",
                }
            ],
        },
        "/api/settings": {
            "tenant_id": "tenant-a",
            "settings": [{"key": "environment", "value": "development"}],
        },
    }

    for path, contract in expected.items():
        response = client.get(path, headers=headers)
        assert response.status_code == 200
        assert response.json() == contract


def test_responses_never_mix_records_between_tenants(client):
    for path in ("/api/agents", "/api/compliance", "/api/audit", "/api/settings"):
        alice = client.get(path, headers=bearer(token_for("alice"))).text
        bob = client.get(path, headers=bearer(token_for("bob"))).text
        assert "tenant-b" not in alice
        assert "tenant-a" not in bob


def test_unsupported_method_returns_stable_typed_error(client):
    response = client.post("/api/settings", headers=bearer(token_for("alice")))

    assert response.status_code == 405
    assert response.json() == {
        "error": {
            "code": "method_not_allowed",
            "message": "Method is not allowed",
        }
    }


def test_internal_exception_is_logged_but_never_disclosed(client, monkeypatch):
    secret_detail = "database password=do-not-disclose"

    def fail(_tenant_id):
        raise RuntimeError(secret_detail)

    monkeypatch.setattr(api_compat, "build_agents_response", fail)
    response = client.get("/api/agents", headers=bearer(token_for("alice")))

    assert response.status_code == 500
    assert response.json() == {
        "error": {"code": "internal_error", "message": "Internal server error"}
    }
    assert secret_detail not in response.text


def test_missing_verification_secret_fails_closed(client, monkeypatch):
    monkeypatch.setattr(settings, "api_jwt_secret", SecretStr(""))

    response = client.get("/api/agents", headers=bearer(token_for("alice")))

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "authentication_unavailable"


def test_openapi_publishes_response_models_for_each_compatibility_route(client):
    schema = client.get("/openapi.json").json()
    expected_models = {
        "/api/agents": "AgentsResponse",
        "/api/compliance": "ComplianceResponse",
        "/api/audit": "AuditResponse",
        "/api/settings": "SettingsResponse",
    }

    for path, model in expected_models.items():
        responses = schema["paths"][path]["get"]["responses"]
        response_schema = responses["200"]["content"]["application/json"]["schema"]
        assert response_schema == {"$ref": f"#/components/schemas/{model}"}
        assert responses["405"]["content"]["application/json"]["schema"] == {
            "$ref": "#/components/schemas/ErrorResponse"
        }
