"""Unit and integration tests for the Connectors router and Discovery synchronization."""
from __future__ import annotations

import socket
import time
from contextlib import contextmanager
from types import SimpleNamespace
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
from api_compat import settings
from db.connection import set_pool_for_testing
from routers.connectors import get_audit_events_for_testing, reset_connectors_for_testing


class ReadyPool:
    async def close(self):
        pass


TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


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
def client_for(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {"alice": "tenant-a", "bob": "tenant-b"})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: TestJWKClient())

    async def _no_pool():
        return None

    monkeypatch.setattr(api_compat, "_get_pool", _no_pool)

    def reject_external_network(*_args, **_kwargs):
        raise AssertionError("external network access is forbidden in connectors tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)
    api_compat.reset_tenant_state("tenant-a")
    api_compat.reset_tenant_state("tenant-b")
    reset_connectors_for_testing()
    set_pool_for_testing(ReadyPool())

    from main import app

    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)
        api_compat.reset_tenant_state("tenant-a")
        api_compat.reset_tenant_state("tenant-b")
        reset_connectors_for_testing()


def test_list_connector_providers(monkeypatch):
    with client_for(monkeypatch) as client:
        resp = client.get("/api/v1/connectors/providers", headers=bearer(token_for("alice")))
        assert resp.status_code == 200
        data = resp.json()
        assert "providers" in data
        provider_ids = {p["provider_id"] for p in data["providers"]}
        assert "aws_iam" in provider_ids
        assert "gcp_iam" in provider_ids
        assert "ad_entra" in provider_ids
        assert "k8s" in provider_ids
        assert "github" in provider_ids
        assert "okta" in provider_ids
        assert "openai" in provider_ids


def test_list_connectors_default_seeded(monkeypatch):
    with client_for(monkeypatch) as client:
        resp = client.get("/api/v1/connectors", headers=bearer(token_for("alice")))
        assert resp.status_code == 200
        data = resp.json()
        assert "connectors" in data
        conns = data["connectors"]
        assert len(conns) >= 5
        providers = {c["provider_id"] for c in conns}
        assert "aws_iam" in providers
        assert "gcp_iam" in providers
        assert "ad_entra" in providers
        assert "k8s" in providers
        assert "github" in providers
        assert all(c["status"] == "connected" for c in conns)


def test_get_connectors_status(monkeypatch):
    with client_for(monkeypatch) as client:
        resp = client.get("/api/v1/connectors/status", headers=bearer(token_for("alice")))
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "healthy"
        assert data["total_connectors"] >= 5
        assert data["active_connectors"] >= 5
        assert len(data["connectors"]) == data["total_connectors"]


def test_toggle_connector_and_emit_audit_event(monkeypatch):
    with client_for(monkeypatch) as client:
        token = token_for("alice")
        headers = bearer(token)

        # 1. Toggle conn-k8s-01 to disconnected
        toggle_resp = client.post(
            "/api/v1/connectors/conn-k8s-01/toggle",
            json={"enabled": False},
            headers=headers,
        )
        assert toggle_resp.status_code == 200
        updated = toggle_resp.json()
        assert updated["connector_id"] == "conn-k8s-01"
        assert updated["status"] == "disconnected"

        # 2. Verify audit event was emitted
        audit_events = get_audit_events_for_testing()
        matching = [e for e in audit_events if e.get("eventType") == "CONNECTOR_STATUS_CHANGED" and e.get("connector_id") == "conn-k8s-01"]
        assert len(matching) > 0
        event = matching[-1]
        assert event["previous_status"] == "connected"
        assert event["new_status"] == "disconnected"
        assert event["tenant_id"] == "tenant-a"

        # 3. Toggle back to connected without body
        toggle_back = client.post("/api/v1/connectors/conn-k8s-01/toggle", headers=headers)
        assert toggle_back.status_code == 200
        assert toggle_back.json()["status"] == "connected"


def test_connector_toggle_syncs_with_discovery(monkeypatch):
    with client_for(monkeypatch) as client:
        token = token_for("alice")
        headers = bearer(token)

        # Baseline: check workloads in discovery
        disc_before = client.get("/api/v1/discovery/workloads", headers=headers)
        assert disc_before.status_code == 200
        data_before = disc_before.json()
        sources_before = {w["source"] for w in data_before["workloads"]}
        assert "local_k8s" in sources_before
        initial_total = data_before["summary"]["total"]

        # Toggle k8s connector to disconnected
        client.post("/api/v1/connectors/conn-k8s-01/toggle", json={"enabled": False}, headers=headers)

        # Check workloads in discovery again: local_k8s must be purged
        disc_after = client.get("/api/v1/discovery/workloads", headers=headers)
        assert disc_after.status_code == 200
        data_after = disc_after.json()
        sources_after = {w["source"] for w in data_after["workloads"]}
        assert "local_k8s" not in sources_after
        assert data_after["summary"]["by_source"]["local_k8s"] == 0
        assert data_after["summary"]["total"] < initial_total

        # Re-enable k8s connector
        client.post("/api/v1/connectors/conn-k8s-01/toggle", json={"enabled": True}, headers=headers)
        disc_restored = client.get("/api/v1/discovery/workloads", headers=headers)
        assert disc_restored.status_code == 200
        data_restored = disc_restored.json()
        assert "local_k8s" in {w["source"] for w in data_restored["workloads"]}
        assert data_restored["summary"]["by_source"]["local_k8s"] > 0


def test_create_delete_test_connector(monkeypatch):
    with client_for(monkeypatch) as client:
        token = token_for("bob")
        headers = bearer(token)

        # Create new connector
        create_resp = client.post(
            "/api/v1/connectors",
            json={
                "provider_id": "okta",
                "display_name": "Corporate Okta IdP",
                "credentials": {"api_token": "secret-123", "okta_domain": "corp.okta.com"},
                "metadata": {"env": "prod"},
            },
            headers=headers,
        )
        assert create_resp.status_code == 200
        created = create_resp.json()
        assert created["provider_id"] == "okta"
        assert created["status"] == "connected"
        conn_id = created["connector_id"]

        # Test connector
        test_resp = client.post(f"/api/v1/connectors/{conn_id}/test", headers=headers)
        assert test_resp.status_code == 200
        test_data = test_resp.json()
        assert test_data["valid"] is True
        assert test_data["scopes_ok"] is True

        # Delete (disconnect) connector
        del_resp = client.delete(f"/api/v1/connectors/{conn_id}", headers=headers)
        assert del_resp.status_code == 200
        del_data = del_resp.json()
        assert del_data["status"] == "disconnected"


def test_frameworks_patch_all_six_frameworks(monkeypatch):
    with client_for(monkeypatch) as client:
        token = token_for("alice")
        headers = bearer(token)

        six_frameworks = [
            "eu-ai-act",
            "nist-800-53",
            "cyber-resilience-act",
            "finos-ai-governance-framework",
            "dora",
            "nis2",
        ]

        resp = client.patch(
            "/api/tenant/settings/frameworks",
            json={"selected_frameworks": six_frameworks},
            headers=headers,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["selected_frameworks"] == six_frameworks
