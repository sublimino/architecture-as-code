from contextlib import contextmanager
import httpx
import pytest

import api_compat
from test_crypto_health import bearer, client_for, token_for


def test_derived_topology_preserves_agent_attributes_and_metadata():
    """Verify _derived_topology populates lifecycle states, metadata, and verified status."""
    agent_governed = {
        "id": "agent-gov-1",
        "name": "Governed Worker",
        "tenant_id": "tenant-a",
        "lifecycle_state": "active",
        "spiffe_id": "spiffe://signalloom.demo/tenant/tenant-a/agent/worker-1",
        "namespace": "agent-trust-acme",
        "trust_domain": "tenant-a.signalloom.demo",
        "tool_permissions": ["read_repo", "execute_code"],
        "egress_allowlist": ["api.anthropic.com", "in-cluster"],
        "custom_attributes": {"tier": "primary", "workload": "coding"},
    }
    agent_discovered = {
        "id": "agent-disc-2",
        "name": "Discovered Shadow Agent",
        "tenant_id": "tenant-a",
        "lifecycle_state": "registered",
        "spiffe_id": None,
        "namespace": "shadow-ns",
        "trust_domain": "tenant-a.signalloom.demo",
        "tool_permissions": ["raw_socket"],
        "egress_allowlist": ["*"],
        "custom_attributes": {"shadow": "true"},
    }

    topo = api_compat._derived_topology(
        tenant_id="tenant-a",
        available=[agent_governed, agent_discovered],
        reason="live collector down",
    )

    node_gov = next(n for n in topo.nodes if n.id == "agent-gov-1")
    assert node_gov.lifecycle_state == "active"
    assert node_gov.verified is True
    assert node_gov.spiffe_id == "spiffe://signalloom.demo/tenant/tenant-a/agent/worker-1"
    assert node_gov.tool_permissions == ["read_repo", "execute_code"]
    assert node_gov.egress_allowlist == ["api.anthropic.com", "in-cluster"]
    assert node_gov.custom_attributes == {"tier": "primary", "workload": "coding"}

    node_disc = next(n for n in topo.nodes if n.id == "agent-disc-2")
    assert node_disc.lifecycle_state == "registered"
    assert node_disc.verified is False
    assert node_disc.spiffe_id is None
    assert node_disc.tool_permissions == ["raw_socket"]

    # Platform and shared service nodes must exist
    assert any(n.id == "platform" for n in topo.nodes)
    assert any(n.id == "spire" and n.tenant == "shared" for n in topo.nodes)
    assert any(n.id == "openbao" and n.tenant == "shared" for n in topo.nodes)

    # Edge telemetry fields
    edge_gov = next(e for e in topo.edges if e.to_id == "agent-gov-1")
    assert edge_gov.throughput_pps is not None
    assert edge_gov.latency_ms is not None
    assert edge_gov.mtls_enforced is True


def test_trust_topology_endpoint_retains_shared_and_modeled_gaps(monkeypatch):
    """Verify trust_topology endpoint keeps shared infrastructure nodes, cross-tenant nodes, and modeled gaps."""
    mock_payload = {
        "generated_at": "2026-09-29T06:00:00Z",
        "version": "v1",
        "collectors": {"kubernetes": {"status": "ok", "observed_at": "2026-09-29T06:00:00Z", "reason": "healthy"}},
        "nodes": [
            {
                "id": "platform",
                "kind": "platform",
                "label": "Platform Root",
                "tenant": None,
                "evidence_state": "observed",
                "evidence_source": "k8s",
                "observed_at": "2026-09-29T06:00:00Z",
                "freshness": "fresh",
                "assurance": "runtime-observed",
                "reason": "root",
            },
            {
                "id": "spire-shared",
                "kind": "service",
                "label": "SPIRE Server",
                "tenant": "shared",
                "evidence_state": "observed",
                "evidence_source": "spire",
                "observed_at": "2026-09-29T06:00:00Z",
                "freshness": "fresh",
                "assurance": "runtime-observed",
                "reason": "shared-spire",
            },
            {
                "id": "tenant-a-agent-1",
                "kind": "agent",
                "label": "Tenant A Agent",
                "tenant": "tenant-a",
                "evidence_state": "observed",
                "evidence_source": "k8s",
                "observed_at": "2026-09-29T06:00:00Z",
                "freshness": "fresh",
                "assurance": "runtime-observed",
                "reason": "workload",
            },
            {
                "id": "other-agent-2",
                "kind": "agent",
                "label": "Other Tenant Agent",
                "tenant": "other-tenant",
                "evidence_state": "observed",
                "evidence_source": "k8s",
                "observed_at": "2026-09-29T06:00:00Z",
                "freshness": "fresh",
                "assurance": "runtime-observed",
                "reason": "other",
            },
            {
                "id": "external-aws",
                "kind": "external",
                "label": "AWS Lambda Connector",
                "tenant": "tenant-a",
                "evidence_state": "modeled",
                "evidence_source": "model",
                "observed_at": "2026-09-29T06:00:00Z",
                "freshness": "fresh",
                "assurance": "modeled",
                "reason": "external boundary",
            },
        ],
        "edges": [
            {
                "id": "edge-platform-spire",
                "from_id": "platform",
                "to_id": "spire-shared",
                "verb": "issues trust",
                "plane": "identity",
                "decision": "allowed",
                "tenant": "shared",
                "evidence_state": "observed",
                "evidence_source": "k8s",
                "observed_at": "2026-09-29T06:00:00Z",
                "freshness": "fresh",
                "assurance": "runtime-observed",
                "reason": "core link",
                "throughput_pps": 250.0,
                "latency_ms": 0.4,
                "mtls_enforced": True,
            },
            {
                "id": "edge-spire-tenant-a",
                "from_id": "spire-shared",
                "to_id": "tenant-a-agent-1",
                "verb": "attests",
                "plane": "identity",
                "decision": "allowed",
                "tenant": "tenant-a",
                "evidence_state": "observed",
                "evidence_source": "k8s",
                "observed_at": "2026-09-29T06:00:00Z",
                "freshness": "fresh",
                "assurance": "runtime-observed",
                "reason": "attestation",
                "throughput_pps": 120.0,
                "latency_ms": 1.5,
                "mtls_enforced": True,
            },
        ],
        "modeled_gaps": [
            {
                "id": "gap-aws-binding",
                "kind": "gap",
                "label": "AWS IAM runtime gap",
                "tenant": "tenant-a",
                "evidence_state": "modeled",
                "evidence_source": "model",
                "observed_at": "2026-09-29T06:00:00Z",
                "freshness": "unavailable",
                "assurance": "modeled",
                "reason": "no runtime assertion",
            }
        ],
    }

    class Response:
        def raise_for_status(self): pass
        def json(self): return mock_payload

    class Client:
        def __init__(self, **_kwargs): pass
        async def __aenter__(self): return self
        async def __aexit__(self, *_args): return False
        async def get(self, _url): return Response()

    with client_for(monkeypatch, Client) as client:
        response = client.get("/api/trust-topology", headers=bearer(token_for(subject="alice")))

    assert response.status_code == 200
    body = response.json()

    node_ids = {n["id"] for n in body["nodes"]}
    assert "platform" in node_ids
    assert "spire-shared" in node_ids
    assert "tenant-a-agent-1" in node_ids
    assert "external-aws" in node_ids
    assert "other-agent-2" not in node_ids  # Properly isolated from other tenant

    edge_ids = {e["id"] for e in body["edges"]}
    assert "edge-platform-spire" in edge_ids
    assert "edge-spire-tenant-a" in edge_ids

    # Modeled gap retained
    assert any(g["id"] == "gap-aws-binding" for g in body["modeled_gaps"])
