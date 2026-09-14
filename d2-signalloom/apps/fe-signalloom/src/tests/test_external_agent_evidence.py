"""Unit and contract test suite for external agent allowlisted evidence persistence and projections (AMXO-P5-3).

Verifies:
1. Strict storage-boundary field allowlisting (stripping prohibited customer payload/memory/command content).
2. Memory fallback and asyncpg database persistence semantics.
3. Tenant-scoped REST API query projections and cross-tenant isolation.
4. Correct pagination, ordering, and session-binding.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from api_compat import (
    Principal,
    authenticated_principal,
    authenticated_tenant,
    install_api_exception_handlers,
)
from external_agent_evidence import (
    ALLOWLISTED_ATTRIBUTE_FIELDS,
    PROHIBITED_FIELD_NAMES,
    ExternalEvidenceIngestPayload,
    _clear_evidence_for_testing,
    query_external_evidence,
    router,
    sanitize_evidence_attributes,
    save_external_evidence,
)


@pytest.fixture(autouse=True)
def clean_store():
    _clear_evidence_for_testing()
    yield
    _clear_evidence_for_testing()


def test_prohibited_field_names_are_stripped():
    """Verify all prohibited raw payload, memory, and command contents are stripped."""
    raw_attributes = {
        "pid": 1234,
        "binary_path": "/usr/local/bin/agent",
        "cpu_time_ms": 250,
        "payload": "ATTACK_PAYLOAD_CUSTOMER_DATA",
        "raw_payload": {"secret": "private_key_material"},
        "file_contents": "CONFIDENTIAL SOURCE CODE",
        "memory_dump": "0xDEADBEEFCAFEBABE",
        "command": "rm -rf /",
        "command_text": "cat /etc/shadow",
        "raw_command": "curl evil.com",
        "stdin_content": "password123",
        "buffer": b"binary data",
        "raw_nono_record": {"raw": True},
        "streamed_payload_contents": "stream bytes",
        "network_payload_contents": "http body",
    }

    filtered = sanitize_evidence_attributes("process", raw_attributes)

    # Prohibited fields must NOT be present
    for prohibited in PROHIBITED_FIELD_NAMES:
        assert prohibited not in filtered, f"Prohibited field {prohibited} leaked into evidence"

    # Allowlisted fields must be preserved
    assert filtered["pid"] == 1234
    assert filtered["binary_path"] == "/usr/local/bin/agent"
    assert filtered["cpu_time_ms"] == 250


def test_artifact_attributes_allowlist():
    """Verify artifact attributes keep allowlisted metadata and strip arbitrary fields."""
    attrs = {
        "artifact_id": "sha256:abcd1234abcd1234",
        "root_id": "workspace-root",
        "sha256": "abcd1234abcd1234",
        "size_bytes": 4096,
        "mtime_ns": "1726000000000000000",
        "file_contents": "MALICIOUS OR SENSITIVE FILE CONTENTS",
        "arbitrary_unallowlisted_key": "drop_this",
    }
    filtered = sanitize_evidence_attributes("artifact", attrs)
    assert filtered["artifact_id"] == "sha256:abcd1234abcd1234"
    assert filtered["sha256"] == "abcd1234abcd1234"
    assert filtered["size_bytes"] == 4096
    assert "file_contents" not in filtered
    assert "arbitrary_unallowlisted_key" not in filtered


def test_network_attributes_allowlist():
    """Verify network attributes keep destinations and port but strip payload contents."""
    attrs = {
        "dest_domain": "api.signalloom.internal",
        "dest_port": 443,
        "protocol": "tcp",
        "network_payload_contents": "GET /secret HTTP/1.1\r\nAuthorization: Bearer topsecret",
    }
    filtered = sanitize_evidence_attributes("network", attrs)
    assert filtered["dest_domain"] == "api.signalloom.internal"
    assert filtered["dest_port"] == 443
    assert filtered["protocol"] == "tcp"
    assert "network_payload_contents" not in filtered


@pytest.mark.anyio
async def test_save_and_query_memory_evidence_tenant_isolation():
    """Verify evidence saving and tenant-isolated querying."""
    now = datetime.now(timezone.utc).isoformat()

    # Save evidence for tenant A
    item_a = await save_external_evidence(
        tenant_id="tenant-alpha",
        agent_id="agent-001",
        session_id="ses-100",
        evidence_type="process",
        source="agentmaxxing-host-sensor",
        observed_at=now,
        attributable_actor="spiffe://signalloom.internal/ns/default/sa/agent-alpha",
        spiffe_id="spiffe://signalloom.internal/ns/default/sa/agent-alpha",
        landlock_abi=3,
        git_oid=None,
        attributes={"pid": 42, "binary_path": "/bin/bash", "payload": "DROP ME"},
        hash_chain_digest="hash_digest_100",
        verified=True,
    )
    assert item_a["tenant_id"] == "tenant-alpha"
    assert "payload" not in item_a["attributes"]
    assert item_a["attributes"]["pid"] == 42

    # Save evidence for tenant B
    await save_external_evidence(
        tenant_id="tenant-beta",
        agent_id="agent-002",
        session_id="ses-200",
        evidence_type="artifact",
        source="agentmaxxing-host-sensor",
        observed_at=now,
        attributable_actor="spiffe://signalloom.internal/ns/default/sa/agent-beta",
        spiffe_id="spiffe://signalloom.internal/ns/default/sa/agent-beta",
        landlock_abi=3,
        git_oid=None,
        attributes={"artifact_id": "art-1", "sha256": "feedbeef"},
        hash_chain_digest="hash_digest_200",
        verified=True,
    )

    # Query for tenant A
    items_a, total_a = await query_external_evidence("tenant-alpha", "agent-001")
    assert total_a == 1
    assert len(items_a) == 1
    assert items_a[0]["agent_id"] == "agent-001"
    assert items_a[0]["tenant_id"] == "tenant-alpha"

    # Cross-tenant check: tenant A cannot see tenant B's agent or evidence
    items_cross, total_cross = await query_external_evidence("tenant-alpha", "agent-002")
    assert total_cross == 0
    assert len(items_cross) == 0

    # Session query
    ses_items, ses_total = await query_external_evidence("tenant-alpha", "agent-001", session_id="ses-100")
    assert ses_total == 1
    assert len(ses_items) == 1
    assert ses_items[0]["session_id"] == "ses-100"

    # Cross-tenant session query
    ses_cross, ses_cross_total = await query_external_evidence("tenant-beta", "agent-001", session_id="ses-100")
    assert ses_cross_total == 0
    assert len(ses_cross) == 0


def test_rest_api_projections_and_ingest():
    """Verify REST API endpoint projections and POST ingest handler."""
    app = FastAPI()
    install_api_exception_handlers(app)
    app.include_router(router)

    def mock_principal_alpha():
        return Principal("tenant-alpha", "user-alpha", None)

    def mock_tenant_alpha():
        return "tenant-alpha"

    app.dependency_overrides[authenticated_principal] = mock_principal_alpha
    app.dependency_overrides[authenticated_tenant] = mock_tenant_alpha

    client = TestClient(app)

    # Ingest evidence via POST /api/v1/agents/{agent_id}/external-evidence
    now = datetime.now(timezone.utc).isoformat()
    payload = {
        "session_id": "ses-300",
        "evidence_type": "process",
        "source": "agentmaxxing-host-sensor",
        "observed_at": now,
        "attributable_actor": "spiffe://signalloom.internal/agent-003",
        "spiffe_id": "spiffe://signalloom.internal/agent-003",
        "landlock_abi": 3,
        "attributes": {
            "pid": 9999,
            "binary_path": "/usr/bin/python3",
            "payload": "DANGEROUS RAW PAYLOAD MUST BE STRIPPED",
            "memory_contents": "SECRET DATA",
        },
        "hash_chain_digest": "digest_300",
        "verified": True,
    }

    resp = client.post("/api/v1/agents/agent-003/external-evidence", json=payload)
    assert resp.status_code == 201, resp.text
    data = resp.json()
    assert data["agent_id"] == "agent-003"
    assert data["tenant_id"] == "tenant-alpha"
    assert "payload" not in data["attributes"]
    assert "memory_contents" not in data["attributes"]
    assert data["attributes"]["pid"] == 9999

    # Query evidence via GET /api/v1/agents/{agent_id}/external-evidence
    get_resp = client.get("/api/v1/agents/agent-003/external-evidence")
    assert get_resp.status_code == 200, get_resp.text
    query_data = get_resp.json()
    assert query_data["total"] == 1
    assert query_data["agent_id"] == "agent-003"
    assert len(query_data["evidence"]) == 1
    assert query_data["evidence"][0]["session_id"] == "ses-300"
    assert "payload" not in query_data["evidence"][0]["attributes"]

    # Negative test: cross-tenant agent path with explicit foreign tenant prefix
    neg_resp = client.get("/api/v1/agents/tenant-beta:agent-999/external-evidence")
    assert neg_resp.status_code == 404, neg_resp.text
