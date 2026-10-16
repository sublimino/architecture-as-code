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
        assert "claude" in provider_ids

        claude_provider = next(p for p in data["providers"] if p["provider_id"] == "claude")
        assert claude_provider["display_name"] == "Anthropic Claude"
        claude_fields = {f["name"]: f for f in claude_provider["wizard_config"]["fields"]}
        assert claude_fields["api_key"]["required"] is True
        assert claude_fields["api_key"]["type"] == "password"
        assert claude_fields["workspace_id"]["required"] is False
        assert claude_fields["admin_api_key"]["required"] is False
        assert "models:read" in claude_provider["wizard_config"]["permissions"]
        assert "batches:read" in claude_provider["wizard_config"]["permissions"]

        openai_provider = next(p for p in data["providers"] if p["provider_id"] == "openai")
        openai_fields = {f["name"]: f for f in openai_provider["wizard_config"]["fields"]}
        assert openai_fields["api_key"]["required"] is True
        assert openai_fields["api_key"]["type"] == "password"
        assert openai_fields["openai_org_id"]["required"] is False


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
        assert "claude" in providers
        assert "openai" in providers
        assert all(c["status"] == "connected" for c in conns)


def test_claude_and_openai_connector_test_and_lifecycle(monkeypatch):
    with client_for(monkeypatch) as client:
        token = token_for("bob")
        headers = bearer(token)

        # 1. Create and test Claude connector
        claude_resp = client.post(
            "/api/v1/connectors",
            json={
                "provider_id": "claude",
                "display_name": "Anthropic Claude Ops",
                "credentials": {"api_key": "sk-ant-test-key", "workspace_id": "wrkspc_123"},
                "metadata": {"env": "prod"},
            },
            headers=headers,
        )
        assert claude_resp.status_code == 200
        claude_data = claude_resp.json()
        claude_id = claude_data["connector_id"]

        test_claude_resp = client.post(f"/api/v1/connectors/{claude_id}/test", headers=headers)
        assert test_claude_resp.status_code == 200
        test_claude = test_claude_resp.json()
        assert test_claude["valid"] is True
        assert test_claude["scopes_ok"] is True
        assert test_claude["error_msg"] is None

        # 2. Create and test OpenAI connector
        openai_resp = client.post(
            "/api/v1/connectors",
            json={
                "provider_id": "openai",
                "display_name": "OpenAI Assistants",
                "credentials": {"api_key": "sk-openai-test-key", "openai_org_id": "org-123"},
                "metadata": {"env": "prod"},
            },
            headers=headers,
        )
        assert openai_resp.status_code == 200
        openai_data = openai_resp.json()
        openai_id = openai_data["connector_id"]

        test_openai_resp = client.post(f"/api/v1/connectors/{openai_id}/test", headers=headers)
        assert test_openai_resp.status_code == 200
        test_openai = test_openai_resp.json()
        assert test_openai["valid"] is True
        assert test_openai["scopes_ok"] is True
        assert test_openai["error_msg"] is None


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

        # Testing a disconnected connector must report invalid
        test_disc_resp = client.post(f"/api/v1/connectors/{conn_id}/test", headers=headers)
        assert test_disc_resp.status_code == 200
        disc_test_data = test_disc_resp.json()
        assert disc_test_data["valid"] is False
        assert disc_test_data["scopes_ok"] is False
        assert "disconnected" in (disc_test_data["error_msg"] or "")

        # Test connector with expired credentials
        create_exp_resp = client.post(
            "/api/v1/connectors",
            json={
                "provider_id": "azure",
                "name": "Expired Azure Connector",
                "credential_expires_at": "2020-01-01T00:00:00Z",
            },
            headers=headers,
        )
        assert create_exp_resp.status_code == 200
        exp_id = create_exp_resp.json()["connector_id"]

        test_exp_resp = client.post(f"/api/v1/connectors/{exp_id}/test", headers=headers)
        assert test_exp_resp.status_code == 200
        exp_test_data = test_exp_resp.json()
        assert exp_test_data["valid"] is False
        assert exp_test_data["scopes_ok"] is False
        assert exp_test_data["needs_rotation"] is True
        assert "expired" in (exp_test_data["error_msg"] or "").lower()

        # Test connector with malformed credential timestamp
        create_mal_resp = client.post(
            "/api/v1/connectors",
            json={
                "provider_id": "okta",
                "name": "Malformed Okta Connector",
                "credential_expires_at": "not-a-valid-timestamp",
            },
            headers=headers,
        )
        assert create_mal_resp.status_code == 200
        mal_id = create_mal_resp.json()["connector_id"]

        test_mal_resp = client.post(f"/api/v1/connectors/{mal_id}/test", headers=headers)
        assert test_mal_resp.status_code == 200
        mal_test_data = test_mal_resp.json()
        assert mal_test_data["valid"] is False
        assert mal_test_data["scopes_ok"] is False
        assert mal_test_data["needs_rotation"] is True
        assert "invalid" in (mal_test_data["error_msg"] or "").lower()


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


def test_claude_and_openai_discovery_and_cel_metadata(monkeypatch):
    with client_for(monkeypatch) as client:
        headers = bearer(token_for("alice"))

        # 1. Check discovery workloads endpoint
        resp = client.get("/api/v1/discovery/workloads", headers=headers)
        assert resp.status_code == 200
        data = resp.json()
        workloads = data.get("workloads", [])
        workload_ids = {w["id"] for w in workloads}
        assert "claude-agent-fin-analyst" in workload_ids
        assert "openai-assistant-triage" in workload_ids

        claude_wl = next(w for w in workloads if w["id"] == "claude-agent-fin-analyst")
        assert claude_wl["name"] == "Financial Risk Intelligence Agent"
        assert claude_wl["source"] == "external_services"
        assert claude_wl["source_label"] == "Anthropic Claude"
        assert claude_wl["model"] == "claude-3-5-sonnet-20241022"
        assert claude_wl["metadata"]["runtime"]["framework"] == "claude-code"
        assert claude_wl["metadata"]["operational_state"]["runtime_status"] == "running"
        assert "read_sec_filing" in claude_wl["metadata"]["tools"]
        assert "calculate_risk_var" in claude_wl["metadata"]["tools"]
        assert claude_wl["metadata"]["guardrails"]["prompt_injection_filter"] is True
        assert claude_wl["metadata"]["guardrails"]["human_override_active"] is True
        assert claude_wl["metadata"]["telemetry"]["token_usage"]["total"] == 170500
        assert claude_wl["metadata"]["responsibility"]["owner_name"] == "Risk Ops"

        openai_wl = next(w for w in workloads if w["id"] == "openai-assistant-triage")
        assert openai_wl["name"] == "Customer Support Triage Assistant"
        assert openai_wl["source"] == "external_services"
        assert openai_wl["source_label"] == "OpenAI"
        assert openai_wl["model"] == "gpt-4o"
        assert openai_wl["metadata"]["runtime"]["framework"] == "openai-assistants"
        assert openai_wl["metadata"]["operational_state"]["runtime_status"] == "running"
        assert "file_search" in openai_wl["metadata"]["tools"]
        assert "route_ticket" in openai_wl["metadata"]["tools"]
        assert openai_wl["metadata"]["guardrails"]["prompt_injection_filter"] is True
        assert openai_wl["metadata"]["guardrails"]["human_override_active"] is True
        assert openai_wl["metadata"]["telemetry"]["token_usage"]["total"] == 85000
        assert openai_wl["metadata"]["responsibility"]["owner_name"] == "Support Ops"

        # 2. Check individual agent endpoints and AgentResponse CEL metadata
        ag_resp = client.get("/api/agents/claude-agent-fin-analyst", headers=headers)
        assert ag_resp.status_code == 200
        ag_data = ag_resp.json()
        assert ag_data["name"] == "Financial Risk Intelligence Agent"
        assert ag_data["model_name"] == "claude-3-5-sonnet-20241022"
        assert ag_data["runtime"]["framework"] == "claude-code"
        assert ag_data["operational_state"]["runtime_status"] == "running"
        assert ag_data["tools"] == ["read_sec_filing", "calculate_risk_var"]
        assert ag_data["guardrails"] == {"prompt_injection_filter": True, "human_override_active": True}
        assert ag_data["telemetry"] == {"token_usage": {"total": 170500}}
        assert ag_data["responsibility"]["owner_name"] == "Risk Ops"

        oai_resp = client.get("/api/agents/openai-assistant-triage", headers=headers)
        assert oai_resp.status_code == 200
        oai_data = oai_resp.json()
        assert oai_data["name"] == "Customer Support Triage Assistant"
        assert oai_data["model_name"] == "gpt-4o"
        assert oai_data["runtime"]["framework"] == "openai-assistants"
        assert oai_data["operational_state"]["runtime_status"] == "running"
        assert oai_data["tools"] == ["file_search", "route_ticket"]
        assert oai_data["guardrails"] == {"prompt_injection_filter": True, "human_override_active": True}
        assert oai_data["telemetry"] == {"token_usage": {"total": 85000}}
        assert oai_data["responsibility"]["owner_name"] == "Support Ops"


def test_connector_scan_claude(monkeypatch):
    with client_for(monkeypatch) as client:
        headers = bearer(token_for("alice"))
        resp = client.post("/api/v1/connectors/claude/scan", headers=headers, json={"force": True})
        assert resp.status_code == 200
        data = resp.json()
        assert data["provider_id"] == "claude"
        assert data["status"] == "success"
        assert data["duration_ms"] == 142
        assert data["records_scanned"] == {
            "agents": 1,
            "models": 2,
            "environments": 1,
            "tools": 4,
        }
        assert data["policies_evaluated"] == {
            "egress_rules": 3,
            "violations": 0,
        }
        logs = data["logs"]
        assert len(logs) == 4
        assert logs[0]["id"] == "log-1"
        assert "cloud-dev" in logs[0]["message"]
        assert logs[1]["id"] == "log-2"
        # Fixture demo trace, but wire fields are superadmin-only and alice is not one.
        assert (logs[1]["endpoint"], logs[1]["status_code"], logs[1]["details"]) == (None, None, None)
        assert logs[2]["id"] == "log-3"
        assert "Daily News Jokester" in logs[2]["message"]
        assert "agent_01FoEhnKF9QsC5DGmuELhm7G" in logs[2]["message"]
        assert logs[3]["id"] == "log-4"
        assert "CEL Policy Evaluation passed" in logs[3]["message"]

        # Check last_scan_at updated in connector record
        conns_resp = client.get("/api/v1/connectors", headers=headers)
        claude_conn = next(c for c in conns_resp.json()["connectors"] if c["provider_id"] == "claude")
        assert claude_conn["last_scan_at"] is not None


def test_connector_logs_claude(monkeypatch):
    with client_for(monkeypatch) as client:
        headers = bearer(token_for("alice"))
        # Get logs directly
        resp = client.get("/api/v1/connectors/claude/logs", headers=headers)
        assert resp.status_code == 200
        data = resp.json()
        assert data["provider_id"] == "claude"
        assert len(data["logs"]) >= 4

        # Test path variants
        resp2 = client.get("/api/connectors/claude/logs", headers=headers)
        assert resp2.status_code == 200
        resp3 = client.get("/connectors/claude/logs", headers=headers)
        assert resp3.status_code == 200


def test_connector_scan_paths_and_connector_id(monkeypatch):
    with client_for(monkeypatch) as client:
        headers = bearer(token_for("alice"))
        # Test scan via /api/connectors and /connectors
        resp1 = client.post("/api/connectors/claude/scan", headers=headers)
        assert resp1.status_code == 200
        resp2 = client.post("/connectors/claude/scan", headers=headers)
        assert resp2.status_code == 200

        # Test scan by connector_id
        resp3 = client.post("/api/v1/connectors/conn-claude-01/scan", headers=headers)
        assert resp3.status_code == 200
        assert resp3.json()["provider_id"] == "claude"

        # Unknown provider returns 404
        resp4 = client.post("/api/v1/connectors/nonexistent-xyz/scan", headers=headers)
        assert resp4.status_code == 404
        resp5 = client.get("/api/v1/connectors/nonexistent-xyz/logs", headers=headers)
        assert resp5.status_code == 404


def test_claude_live_api_and_fallback(monkeypatch):
    with client_for(monkeypatch) as client:
        headers = bearer(token_for("alice"))

        # 1. Fallback when offline / dummy key
        test_resp = client.post("/api/v1/connectors/conn-claude-01/test", headers=headers)
        assert test_resp.status_code == 200
        assert test_resp.json()["valid"] is True
        assert "Anthropic Claude API" in test_resp.json().get("message", "")

        # 2. Live Anthropic API call with dynamic agent name
        class MockResponse:
            def __init__(self, status_code, data):
                self.status_code = status_code
                self._data = data

            def json(self):
                return self._data

        async def mock_get(self, url, *args, **kwargs):
            if "agents" in url:
                return MockResponse(
                    200,
                    {
                        "data": [
                            {
                                "id": "agent_live_claude_test_42",
                                "name": "Live Console Modified Agent",
                            }
                        ]
                    },
                )
            return MockResponse(200, {"data": []})

        import httpx
        monkeypatch.setattr(httpx.AsyncClient, "get", mock_get)

        # Test connector with credentials in body
        test_live_resp = client.post(
            "/api/v1/connectors/conn-claude-01/test",
            headers=headers,
            json={"credentials": {"api_key": "sk-ant-live-key-12345"}},
        )
        assert test_live_resp.status_code == 200
        test_live_data = test_live_resp.json()
        assert test_live_data["valid"] is True
        assert "Live Console Modified Agent" in test_live_data["message"]

        # Trigger scan with live key
        scan_live_resp = client.post(
            "/api/v1/connectors/claude/scan",
            headers=headers,
            json={"credentials": {"api_key": "sk-ant-live-key-12345"}},
        )
        assert scan_live_resp.status_code == 200
        scan_live_data = scan_live_resp.json()
        assert scan_live_data["provider_id"] == "claude"
        log3 = next(l for l in scan_live_data["logs"] if l["id"] == "log-3")
        assert "Discovered live agent Live Console Modified Agent (agent_live_claude_test_42)" in log3["message"]

        # Check discovered workloads updated with live agent name
        workloads_resp = client.get("/api/v1/discovery/workloads", headers=headers)
        assert workloads_resp.status_code == 200
        claude_wl = next(w for w in workloads_resp.json()["workloads"] if w["id"] == "claude-agent-fin-analyst")
        assert claude_wl["name"] == "Live Console Modified Agent"


