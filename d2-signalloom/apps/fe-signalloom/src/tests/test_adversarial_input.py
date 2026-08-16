"""Adversarial tests: input validation attacks.

Probes unbounded fields, injection payloads, type confusion, and resource
exhaustion vectors that the existing test suite does not exercise.
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
# Test JWT infrastructure
# ---------------------------------------------------------------------------

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _token_for(subject: str = "alice", **extra) -> str:
    now = int(time.time())
    claims = {
        "iss": "https://issuer.test/dex",
        "aud": "signalloom-api",
        "iat": now, "nbf": now, "exp": now + 300,
        "azp": "signalloom-dashboard",
        "sub": subject,
        "email": f"{subject}@corp.test",
    }
    claims.update(extra)
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


# =========================================================================
# 1. Unbounded string fields
# =========================================================================

class TestUnboundedStrings:
    """Several Pydantic request models have `str` fields with no max_length.
    These accept megabytes of data in fixture mode, bloating memory."""

    @pytest.mark.parametrize("field,value", [
        ("name", "A" * 100_000),
        ("type", "B" * 100_000),
        ("description", "C" * 100_000),
        ("owner", "D" * 100_000),
    ])
    def test_agent_create_overlong_fields(self, client, field, value):
        """AgentCreateRequest has no max_length on name, type, description, owner."""
        body = {"name": "test", "type": "service", "description": None, "owner": None}
        body[field] = value
        resp = client.post("/api/agents", headers=AUTH(), json=body)
        # BUG: These should be rejected with 422 but are accepted
        # Documenting the gap: a 100KB name is stored in memory
        assert resp.status_code in (200, 201, 422), f"Unexpected: {resp.status_code}"
        if resp.status_code in (200, 201):
            # The overlong value was accepted — this is the finding
            assert len(resp.json()["name"]) == 100_000 if field == "name" else True

    def test_transition_overlong_reason(self, client):
        """TransitionRequest.reason has no max_length."""
        # Use suspended (valid: active -> suspended) so we test the reason field,
        # not the transition graph.
        resp = client.post(
            "/api/agents/tenant-a:agent-1/transition",
            headers=AUTH(),
            json={"to_state": "suspended", "reason": "X" * 100_000},
        )
        assert resp.status_code in (200, 422)

    def test_support_request_overlong_message(self, client):
        """SupportRequestCreate.message has no max_length."""
        resp = client.post(
            "/api/support",
            headers=AUTH(),
            json={
                "subject": "Y" * 100_000,
                "urgency": "critical",
                "message": "Z" * 1_000_000,
            },
        )
        assert resp.status_code in (200, 201, 422)
        if resp.status_code in (200, 201):
            body = resp.json()
            assert len(body.get("subject", "")) == 100_000, "100KB subject accepted"

    def test_frameworks_patch_unbounded_list(self, client):
        """FrameworksPatchRequest.selected_frameworks has no length limit."""
        huge_list = [f"FRAMEWORK-{i}" for i in range(10_000)]
        resp = client.patch(
            "/api/tenant/settings/frameworks",
            headers=AUTH(),
            json={"selected_frameworks": huge_list},
        )
        assert resp.status_code in (200, 422)
        if resp.status_code == 200:
            body = resp.json()
            fws = body.get("selected_frameworks", [])
            assert len(fws) == 10_000, "10K frameworks accepted"

    def test_consent_unbounded_document_versions(self, client):
        """ConsentAcceptRequest.document_versions has no size limit."""
        huge_dict = {f"doc-{i}": f"v{i}" for i in range(10_000)}
        resp = client.post(
            "/api/consent/accept",
            headers=AUTH(),
            json={
                "document_versions": huge_dict,
                "cookie_preferences": {"strictly_necessary": True, "analytics": False},
                "b2b_warranty_accepted": True,
            },
        )
        assert resp.status_code in (200, 422)
        if resp.status_code == 200:
            body = resp.json()
            assert len(body.get("document_versions", {})) == 10_000, "10K doc versions accepted"


# =========================================================================
# 2. Lifecycle state vocabulary — no validation in fixture mode
# =========================================================================

class TestLifecycleVocabulary:
    """TransitionRequest.to_state is now validated against VALID_LIFECYCLE_STATES.
    Invalid states are rejected with 400 (invalid_state)."""

    @pytest.mark.parametrize("bad_state", [
        "",                      # empty
        " ",                     # whitespace
        "ACTIVE",                # wrong case
        "nonexistent_state",     # not in vocabulary
        "'; DROP TABLE agents;--",  # SQL injection
        "<script>alert(1)</script>",  # XSS
        "a" * 10_000,           # overlong
        "registered\x00active",  # null byte
    ])
    def test_transition_rejects_invalid_to_state(self, client, bad_state):
        """Invalid lifecycle states are rejected with 400."""
        resp = client.post(
            "/api/agents/tenant-a:agent-1/transition",
            headers=AUTH(),
            json={"to_state": bad_state, "reason": "adversarial test"},
        )
        assert resp.status_code == 400, (
            f"Expected 400 for invalid state {bad_state!r}, got {resp.status_code}: {resp.text}"
        )
        body = resp.json()
        assert body["error"]["code"] == "invalid_state"

    def test_empty_reason_accepted(self, client):
        """Reason field has no min_length — empty string is accepted."""
        resp = client.post(
            "/api/agents/tenant-a:agent-1/transition",
            headers=AUTH(),
            json={"to_state": "suspended", "reason": ""},
        )
        assert resp.status_code in (200, 422)


# =========================================================================
# 3. SQL injection payloads in string fields
# =========================================================================

class TestSQLInjection:
    """Even in fixture mode, these values would reach the DB in production.
    The parameterised queries should handle them, but the test documents
    that the API accepts them without validation."""

    SQL_PAYLOADS = [
        "'; DROP TABLE agents;--",
        "1 OR 1=1",
        "admin'--",
        "1'; UPDATE agents SET lifecycle_state='hacked' WHERE '1'='1",
        "UNION SELECT * FROM pg_catalog.pg_tables--",
    ]

    @pytest.mark.parametrize("payload", SQL_PAYLOADS)
    def test_agent_name_sql_injection(self, client, payload):
        resp = client.post(
            "/api/agents",
            headers=AUTH(),
            json={"name": payload, "type": "service"},
        )
        # Should accept (parameterised queries protect) but not crash
        assert resp.status_code in (200, 201, 422)
        if resp.status_code in (200, 201):
            # The payload is stored verbatim — fine if parameterised, risky if not
            assert resp.json()["name"] == payload

    @pytest.mark.parametrize("payload", SQL_PAYLOADS)
    def test_support_subject_sql_injection(self, client, payload):
        resp = client.post(
            "/api/support",
            headers=AUTH(),
            json={"subject": payload, "urgency": "low", "message": "test"},
        )
        assert resp.status_code in (200, 201, 422)


# =========================================================================
# 4. Type confusion and unexpected JSON shapes
# =========================================================================

class TestTypeConfusion:
    """Send unexpected types where specific ones are expected."""

    def test_agent_create_numeric_name(self, client):
        resp = client.post(
            "/api/agents",
            headers=AUTH(),
            json={"name": 12345, "type": "service"},
        )
        # Pydantic should coerce or reject
        assert resp.status_code in (200, 201, 422)

    def test_agent_create_null_required_field(self, client):
        resp = client.post(
            "/api/agents",
            headers=AUTH(),
            json={"name": None, "type": "service"},
        )
        assert resp.status_code == 422

    def test_agent_create_nested_object_for_string(self, client):
        resp = client.post(
            "/api/agents",
            headers=AUTH(),
            json={"name": {"nested": "object"}, "type": "service"},
        )
        assert resp.status_code == 422

    def test_agent_create_array_for_string(self, client):
        resp = client.post(
            "/api/agents",
            headers=AUTH(),
            json={"name": ["list", "value"], "type": "service"},
        )
        assert resp.status_code == 422

    def test_transition_boolean_to_state(self, client):
        resp = client.post(
            "/api/agents/tenant-a:agent-1/transition",
            headers=AUTH(),
            json={"to_state": True, "reason": "test"},
        )
        assert resp.status_code == 422

    def test_preferences_negative_cadence(self, client):
        """preferred_scan_cadence_hours has ge=1 but let's test boundary."""
        resp = client.patch(
            "/api/tenant/settings/preferences",
            headers=AUTH(),
            json={"preferred_scan_cadence_hours": 0, "alert_email": None, "alert_threshold": 1},
        )
        assert resp.status_code == 422

    def test_preferences_float_cadence(self, client):
        resp = client.patch(
            "/api/tenant/settings/preferences",
            headers=AUTH(),
            json={"preferred_scan_cadence_hours": 1.5, "alert_email": None, "alert_threshold": 1},
        )
        # Pydantic may coerce float to int or reject
        assert resp.status_code in (200, 422)

    def test_preferences_huge_cadence(self, client):
        """No upper bound on scan cadence."""
        resp = client.patch(
            "/api/tenant/settings/preferences",
            headers=AUTH(),
            json={"preferred_scan_cadence_hours": 2**31, "alert_email": None, "alert_threshold": 1},
        )
        assert resp.status_code in (200, 422)

    def test_consent_b2b_warranty_false_rejected(self, client):
        """b2b_warranty_accepted is Literal[True] — False should be rejected."""
        resp = client.post(
            "/api/consent/accept",
            headers=AUTH(),
            json={
                "document_versions": {"tos": "v1"},
                "cookie_preferences": {"strictly_necessary": True, "analytics": False},
                "b2b_warranty_accepted": False,
            },
        )
        assert resp.status_code == 422

    def test_cookie_preferences_missing_strictly_necessary(self, client):
        """strictly_necessary should be required."""
        resp = client.patch(
            "/api/cookie-preferences",
            headers=AUTH(),
            json={"analytics": True},
        )
        # CookiePrefsPatchRequest only has `analytics`, not `strictly_necessary`
        # so this should work
        assert resp.status_code in (200, 422)


# =========================================================================
# 5. Extra fields (extra="forbid")
# =========================================================================

class TestExtraFields:
    """All models use extra='forbid'. Verify extra fields are rejected."""

    def test_agent_create_extra_field(self, client):
        resp = client.post(
            "/api/agents",
            headers=AUTH(),
            json={"name": "test", "type": "service", "malicious_field": "injected"},
        )
        assert resp.status_code == 422

    def test_transition_extra_field(self, client):
        resp = client.post(
            "/api/agents/tenant-a:agent-1/transition",
            headers=AUTH(),
            json={"to_state": "active", "reason": "test", "admin_override": True},
        )
        assert resp.status_code == 422

    def test_support_extra_field(self, client):
        resp = client.post(
            "/api/support",
            headers=AUTH(),
            json={"subject": "test", "urgency": "low", "message": "test", "priority": "p0"},
        )
        assert resp.status_code == 422

    def test_consent_extra_field(self, client):
        resp = client.post(
            "/api/consent/accept",
            headers=AUTH(),
            json={
                "document_versions": {"tos": "v1"},
                "cookie_preferences": {"strictly_necessary": True, "analytics": False},
                "b2b_warranty_accepted": True,
                "bypass_consent": True,
            },
        )
        assert resp.status_code == 422


# =========================================================================
# 6. Unicode edge cases
# =========================================================================

class TestUnicodeEdgeCases:
    """Unicode characters that commonly break string processing."""

    UNICODE_PAYLOADS = [
        "\xef\xbb\xbf",                # BOM
        "\u200b",                   # zero-width space
        "\u202e",                   # right-to-left override
        "\n\r\n",                 # line breaks
        "\U0001F389" * 1000,        # emoji flood
        "a" + "\u0300" * 100,       # combining diacriticals
    ]

    @pytest.mark.parametrize("payload", UNICODE_PAYLOADS)
    def test_agent_name_unicode(self, client, payload):
        resp = client.post(
            "/api/agents",
            headers=AUTH(),
            json={"name": payload, "type": "service"},
        )
        # Should not crash — 200 or 422 are both acceptable
        assert resp.status_code in (200, 201, 422, 400)


# =========================================================================
# 7. Empty and malformed JSON bodies
# =========================================================================

class TestMalformedBodies:
    """Send malformed, empty, or missing bodies to POST endpoints."""

    def test_agent_create_empty_body(self, client):
        resp = client.post("/api/agents", headers=AUTH(), json={})
        assert resp.status_code == 422

    def test_agent_create_no_content_type(self, client):
        resp = client.post(
            "/api/agents",
            headers={**AUTH(), "Content-Type": "text/plain"},
            content="not json",
        )
        assert resp.status_code == 422

    def test_transition_no_body(self, client):
        resp = client.post(
            "/api/agents/tenant-a:agent-1/transition",
            headers=AUTH(),
        )
        assert resp.status_code == 422

    def test_support_missing_required_fields(self, client):
        resp = client.post(
            "/api/support",
            headers=AUTH(),
            json={"subject": "help"},
        )
        assert resp.status_code == 422

    def test_deeply_nested_json(self, client):
        """Deeply nested JSON to test stack depth limits."""
        nested = {"key": "value"}
        for _ in range(100):
            nested = {"nested": nested}
        resp = client.post(
            "/api/agents",
            headers=AUTH(),
            json={"name": json.dumps(nested), "type": "service"},
        )
        # The name is a stringified deep JSON — should be accepted as a string
        assert resp.status_code in (200, 201, 422)


# =========================================================================
# 8. Display currency validation
# =========================================================================

class TestDisplayCurrencyValidation:
    """The display_currency validator checks membership in SUPPORTED_DISPLAY_CURRENCIES."""

    @pytest.mark.parametrize("bad_currency", [
        "usd",      # lowercase
        "Usd",      # mixed case
        "US",       # too short
        "USDD",     # too long (caught by Field(max_length=3))
        "123",      # digits
        "XXX",      # not in supported set
        "   ",      # whitespace
        "",         # empty
        "USD ",     # trailing space
        " USD",     # leading space
    ])
    def test_invalid_currencies_rejected(self, client, bad_currency):
        resp = client.patch(
            "/api/user/preferences",
            headers=AUTH(),
            json={"display_currency": bad_currency},
        )
        assert resp.status_code == 422, f"Expected 422 for {bad_currency!r}, got {resp.status_code}"

    @pytest.mark.parametrize("good_currency", ["USD", "GBP", "EUR", "JPY", "AED"])
    def test_valid_currencies_accepted(self, client, good_currency):
        resp = client.patch(
            "/api/user/preferences",
            headers=AUTH(),
            json={"display_currency": good_currency},
        )
        assert resp.status_code == 200
        assert resp.json()["display_currency"] == good_currency


# =========================================================================
# 9. Alert email validation
# =========================================================================

class TestAlertEmailValidation:
    """alert_email has max_length=320 and blank-is-unset normalisation."""

    def test_blank_email_normalised_to_null(self, client):
        resp = client.patch(
            "/api/tenant/settings/preferences",
            headers=AUTH(),
            json={"preferred_scan_cadence_hours": 24, "alert_email": "   ", "alert_threshold": 1},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body.get("alert_email") is None, "Blank email should be normalised to null"

    def test_overlong_email_rejected(self, client):
        """max_length=320 should reject longer values."""
        resp = client.patch(
            "/api/tenant/settings/preferences",
            headers=AUTH(),
            json={"preferred_scan_cadence_hours": 24, "alert_email": "a" * 321, "alert_threshold": 1},
        )
        assert resp.status_code == 422

    def test_email_no_format_validation(self, client):
        """alert_email has no email format validation — just max_length.
        This documents the gap."""
        resp = client.patch(
            "/api/tenant/settings/preferences",
            headers=AUTH(),
            json={
                "preferred_scan_cadence_hours": 24,
                "alert_email": "not-an-email-at-all",
                "alert_threshold": 1,
            },
        )
        # BUG: Accepted because there's no email format validation
        assert resp.status_code == 200, "Expected acceptance (documenting the validation gap)"


# =========================================================================
# 10. Urgency enumeration
# =========================================================================

class TestUrgencyEnumeration:
    """SupportRequestCreate.urgency is Literal['low','normal','high','critical']."""

    @pytest.mark.parametrize("bad_urgency", [
        "LOW",        # wrong case
        "emergency",  # not in set
        "p0",         # alternative format
        "",           # empty
        "low; DROP TABLE support_requests;--",
    ])
    def test_invalid_urgency_rejected(self, client, bad_urgency):
        resp = client.post(
            "/api/support",
            headers=AUTH(),
            json={"subject": "test", "urgency": bad_urgency, "message": "test"},
        )
        assert resp.status_code == 422
