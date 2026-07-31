import base64
import json
import socket
import time
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
