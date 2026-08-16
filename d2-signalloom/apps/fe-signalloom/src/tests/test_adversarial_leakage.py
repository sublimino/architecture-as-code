"""Adversarial tests: error information leakage and HTTP method confusion.

Probes that error responses never leak stack traces, SQL queries, internal
paths, connection strings, or implementation details.
"""
from __future__ import annotations

import json
import socket
import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings, reset_tenant_state
from db.connection import set_pool_for_testing
from main import app


# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _token_for(subject: str = "alice") -> str:
    now = int(time.time())
    claims = {
        "iss": "https://issuer.test/dex",
        "aud": "signalloom-api",
        "iat": now, "nbf": now, "exp": now + 300,
        "azp": "signalloom-dashboard",
        "sub": subject,
        "email": f"{subject}@corp.test",
    }
    return jwt.encode(claims, TEST_SIGNING_KEY, algorithm="RS256", headers={"kid": "test-key", "typ": "JWT"})


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


class _ReadyPool:
    async def close(self):
        pass


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-a"})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    def reject_external(*_a, **_kw):
        raise AssertionError("no external network in tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external)
    set_pool_for_testing(_ReadyPool())
    reset_tenant_state("tenant-a")

    with TestClient(app, raise_server_exceptions=False) as tc:
        yield tc


AUTH = lambda: _bearer(_token_for("alice"))

# Strings that should NEVER appear in any error response
LEAK_PATTERNS = [
    "Traceback",
    "File \"",
    "line ",
    "asyncpg",
    "postgresql://",
    "postgres://",
    ".py\"",
    "import ",
    "def ",
    "class ",
    "raise ",
    "SELECT ",
    "INSERT ",
    "UPDATE ",
    "DELETE ",
    "WHERE ",
    "/home/",
    "/usr/",
    "/app/",
    "site-packages",
    "venv/",
    "python3",
    "SQLSTATE",
    "password",
    "secret",
    "connection",
    "pool",
]


def _assert_no_leakage(response, context: str = ""):
    """Assert that an error response does not leak internal details."""
    text = response.text.lower()
    for pattern in LEAK_PATTERNS:
        assert pattern.lower() not in text, (
            f"Information leakage ({context}): response contains '{pattern}'. "
            f"Status: {response.status_code}, Body: {response.text[:200]}"
        )


# =========================================================================
# 1. Error responses must not leak internals
# =========================================================================

class TestErrorResponseSafety:
    """Verify that all error paths return safe, opaque messages."""

    def test_404_is_opaque(self, client):
        resp = client.get("/api/nonexistent-endpoint-12345", headers=AUTH())
        assert resp.status_code == 404
        _assert_no_leakage(resp, "404")
        body = resp.json()
        assert body == {"error": {"code": "not_found", "message": "Resource was not found"}}

    def test_401_no_token_is_opaque(self, client):
        resp = client.get("/api/agents")
        assert resp.status_code == 401
        _assert_no_leakage(resp, "401 missing token")

    def test_401_bad_token_is_opaque(self, client):
        resp = client.get("/api/agents", headers={"Authorization": "Bearer garbage.token.here"})
        assert resp.status_code == 401
        _assert_no_leakage(resp, "401 bad token")
        # Must not disclose WHY the token is bad
        body = resp.json()
        assert body["error"]["message"] == "Bearer token is invalid"

    def test_422_validation_is_opaque(self, client):
        """Validation errors must not include field-level Pydantic details."""
        resp = client.post(
            "/api/agents",
            headers=AUTH(),
            json={"name": None, "type": 12345, "extra": "field"},
        )
        assert resp.status_code == 422
        _assert_no_leakage(resp, "422")
        body = resp.json()
        # The custom handler returns a generic message, not Pydantic details
        assert body == {"error": {"code": "invalid_request", "message": "Request is invalid"}}

    def test_405_method_not_allowed_is_opaque(self, client):
        resp = client.delete("/api/agents", headers=AUTH())
        assert resp.status_code == 405
        _assert_no_leakage(resp, "405")
        body = resp.json()
        assert body == {"error": {"code": "method_not_allowed", "message": "Method is not allowed"}}

    def test_malformed_json_body(self, client):
        resp = client.post(
            "/api/agents",
            headers={**AUTH(), "Content-Type": "application/json"},
            content=b"{'invalid': json}",
        )
        assert resp.status_code == 422
        _assert_no_leakage(resp, "malformed JSON")


# =========================================================================
# 2. HTTP method confusion
# =========================================================================

class TestHTTPMethodConfusion:
    """Send wrong HTTP methods to endpoints and verify safe 405 responses."""

    GET_ENDPOINTS = [
        # Note: /api/agents is excluded — it has both GET and POST handlers
        "/api/health/crypto",
        "/api/network-tests",
        "/api/trust-topology",
        "/api/compliance/summary",
        "/api/compliance/posture",
        "/api/compliance/frameworks",
        "/api/audit",
        "/api/nhi/scans",
        "/api/nhi/discovered",
        "/api/tenant/settings",
        "/api/tenant/users",
        "/api/user/preferences",
        "/api/consent/status",
        "/api/cookie-preferences",
    ]

    POST_ENDPOINTS = [
        "/api/agents",
        "/api/network-tests/scan",
        "/api/agents/tenant-a:agent-1/credentials",
        "/api/agents/tenant-a:agent-1/credentials/revoke",
        "/api/agents/tenant-a:agent-1/transition",
        "/api/agents/tenant-a:agent-1/stun",
        "/api/support",
        "/api/consent/accept",
    ]

    @pytest.mark.parametrize("endpoint", GET_ENDPOINTS)
    def test_post_to_get_endpoint(self, client, endpoint):
        resp = client.post(endpoint, headers=AUTH(), json={})
        assert resp.status_code == 405, f"POST to GET-only {endpoint} returned {resp.status_code}"
        _assert_no_leakage(resp, f"POST→{endpoint}")

    @pytest.mark.parametrize("endpoint", GET_ENDPOINTS)
    def test_delete_to_get_endpoint(self, client, endpoint):
        resp = client.delete(endpoint, headers=AUTH())
        assert resp.status_code == 405, f"DELETE to GET-only {endpoint} returned {resp.status_code}"
        _assert_no_leakage(resp, f"DELETE→{endpoint}")

    @pytest.mark.parametrize("endpoint", POST_ENDPOINTS)
    def test_get_to_post_endpoint(self, client, endpoint):
        resp = client.get(endpoint, headers=AUTH())
        # Some endpoints may legitimately have GET handlers too
        assert resp.status_code in (200, 405), f"GET to POST-only {endpoint} returned {resp.status_code}"

    def test_options_request(self, client):
        """OPTIONS should not leak handler details."""
        resp = client.options("/api/agents", headers=AUTH())
        _assert_no_leakage(resp, "OPTIONS")

    def test_head_request(self, client):
        """HEAD is not auto-generated by FastAPI for APIRouter routes.
        Verify it returns 405 (method not allowed) cleanly."""
        resp = client.head("/api/agents", headers=AUTH())
        assert resp.status_code == 405
        _assert_no_leakage(resp, "HEAD")


# =========================================================================
# 3. Header injection
# =========================================================================

class TestHeaderInjection:
    """Test CRLF injection and oversized headers."""

    def test_crlf_in_authorization(self, client):
        """CRLF injection attempt in Authorization header."""
        resp = client.get(
            "/api/agents",
            headers={"Authorization": "Bearer token\r\nX-Injected: true"},
        )
        # Should be rejected cleanly
        assert resp.status_code in (400, 401, 422)
        _assert_no_leakage(resp, "CRLF injection")

    def test_oversized_authorization(self, client):
        """Very large Authorization header."""
        resp = client.get(
            "/api/agents",
            headers={"Authorization": f"Bearer {'A' * 100_000}"},
        )
        assert resp.status_code in (400, 401, 413, 422)

    def test_duplicate_content_type(self, client):
        """Duplicate Content-Type headers."""
        # TestClient doesn't easily support duplicate headers,
        # but we can test with a conflicting content type
        resp = client.post(
            "/api/agents",
            headers={**AUTH(), "Content-Type": "text/xml"},
            content="<agent><name>test</name></agent>",
        )
        assert resp.status_code in (400, 415, 422)
        _assert_no_leakage(resp, "wrong content-type")


# =========================================================================
# 4. Path traversal
# =========================================================================

class TestPathTraversal:
    """Path traversal in URL path parameters."""

    @pytest.mark.parametrize("agent_id", [
        "../../../etc/passwd",
        "..%2F..%2F..%2Fetc%2Fpasswd",
        "%00",
        "agent-1/../../../secret",
    ])
    def test_agent_id_path_traversal(self, client, agent_id):
        resp = client.get(f"/api/agents/{agent_id}", headers=AUTH())
        assert resp.status_code in (200, 404, 422)
        _assert_no_leakage(resp, f"path traversal: {agent_id!r}")
        if resp.status_code == 200:
            body = resp.json()
            # The API should not reveal file system contents
            assert "root:" not in json.dumps(body)

    @pytest.mark.parametrize("violation_id", [
        "../../../etc/shadow",
        "'; DROP TABLE agent_violations;--",
    ])
    def test_violation_id_path_traversal(self, client, violation_id):
        resp = client.post(
            f"/api/agents/violations/{violation_id}/acknowledge",
            headers=AUTH(),
        )
        assert resp.status_code in (200, 404, 422)
        _assert_no_leakage(resp, f"violation path traversal: {violation_id!r}")


# =========================================================================
# 5. Response body does not expose internal state
# =========================================================================

class TestResponseSafety:
    """Verify responses do not contain sensitive information."""

    def test_agent_response_no_internal_fields(self, client):
        """Agent response should not leak database IDs, internal state."""
        resp = client.get("/api/agents", headers=AUTH())
        assert resp.status_code == 200
        body = resp.json()
        text = json.dumps(body)
        # Should not contain database connection info
        assert "postgresql" not in text.lower()
        assert "password" not in text.lower()

    def test_settings_response_no_secrets(self, client):
        resp = client.get("/api/tenant/settings", headers=AUTH())
        assert resp.status_code == 200
        text = json.dumps(resp.json())
        assert "secret" not in text.lower()
        assert "password" not in text.lower()
        assert "key_hash" not in text.lower()

    def test_error_format_is_consistent(self, client):
        """All errors should follow the same envelope format."""
        # 401
        r401 = client.get("/api/agents")
        assert "error" in r401.json()
        assert "code" in r401.json()["error"]
        assert "message" in r401.json()["error"]

        # 404
        r404 = client.get("/api/nonexistent", headers=AUTH())
        assert "error" in r404.json()
        assert "code" in r404.json()["error"]

        # 405
        r405 = client.delete("/api/agents", headers=AUTH())
        assert "error" in r405.json()
        assert "code" in r405.json()["error"]

        # 422
        r422 = client.post("/api/agents", headers=AUTH(), json={})
        assert "error" in r422.json()
        assert "code" in r422.json()["error"]
