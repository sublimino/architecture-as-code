# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_tenant_isolation.py
# Unit and integration test suite for Signal Loom Tenant Isolation Engine (SLET)
# ==============================================================================
import pytest
from tenant_isolation import (
    TenantIsolationManager,
    TenantIsolationConfig,
    get_tenant_namespace,
    get_tenant_spiffe_id,
    get_tenant_transit_key_path,
    generate_namespace_manifest,
    generate_network_policy_manifest,
    generate_resource_quota_manifest,
    generate_spire_registration_entry,
)


def test_tenant_naming_conventions_kurasi():
    """Verify canonical naming conventions for pilot tenant kurasi."""
    kurasi_hash = "6f82ad81"
    ns = get_tenant_namespace(kurasi_hash)
    assert ns == "eap-6f82ad81"

    spiffe_id = get_tenant_spiffe_id(kurasi_hash)
    assert spiffe_id == "spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app"

    transit_path = get_tenant_transit_key_path(kurasi_hash)
    assert transit_path == "transit/keys/eap-6f82ad81"


def test_generate_namespace_manifest_restricted_labels():
    """Verify namespace manifest contains Pod Security Standards restricted labels."""
    manifest = generate_namespace_manifest("kurasi")
    assert manifest["apiVersion"] == "v1"
    assert manifest["kind"] == "Namespace"
    assert manifest["metadata"]["name"] == "eap-6f82ad81"

    labels = manifest["metadata"]["labels"]
    assert labels["signalloom.io/eap-hash"] == "6f82ad81"
    assert labels["signalloom.io/customer"] == "kurasi"
    assert labels["pod-security.kubernetes.io/enforce"] == "restricted"
    assert labels["pod-security.kubernetes.io/audit"] == "restricted"
    assert labels["pod-security.kubernetes.io/warn"] == "restricted"


def test_generate_network_policy_manifest():
    """Verify NetworkPolicy establishes default-deny ingress and egress."""
    manifest = generate_network_policy_manifest("6f82ad81")
    assert manifest["apiVersion"] == "networking.k8s.io/v1"
    assert manifest["kind"] == "NetworkPolicy"
    assert manifest["metadata"]["namespace"] == "eap-6f82ad81"

    spec = manifest["spec"]
    assert "Ingress" in spec["policyTypes"]
    assert "Egress" in spec["policyTypes"]

    # Check ingress allows ingress and fe-signalloom
    allowed_ns = [
        f["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
        for rule in spec["ingress"]
        for f in rule.get("from", [])
    ]
    assert "ingress" in allowed_ns
    assert "fe-signalloom" in allowed_ns

    # Check egress allows DNS
    egress_ports = [
        p["port"]
        for rule in spec["egress"]
        for p in rule.get("ports", [])
    ]
    assert 53 in egress_ports


def test_generate_resource_quota_manifest():
    """Verify ResourceQuota limits CPU, memory, and pods."""
    manifest = generate_resource_quota_manifest("6f82ad81")
    assert manifest["apiVersion"] == "v1"
    assert manifest["kind"] == "ResourceQuota"
    assert manifest["metadata"]["namespace"] == "eap-6f82ad81"
    assert manifest["spec"]["hard"]["limits.cpu"] == "4"
    assert manifest["spec"]["hard"]["limits.memory"] == "8Gi"
    assert manifest["spec"]["hard"]["pods"] == "10"


def test_generate_spire_registration_entry():
    """Verify SPIRE registration entry schema and selectors."""
    entry = generate_spire_registration_entry("6f82ad81")
    assert entry["spiffe_id"] == "spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app"
    assert "k8s:ns:eap-6f82ad81" in entry["selectors"]
    assert "k8s:sa:tenant-app" in entry["selectors"]
    assert entry["ttl"] == 3600


def test_tenant_isolation_manager_lifecycle():
    """Verify provision, query, list, and teardown on TenantIsolationManager."""
    mgr = TenantIsolationManager()

    config = mgr.provision_tenant_boundary("kurasi")
    assert config.company_name == "kurasi"
    assert config.customer_hash == "6f82ad81"
    assert config.namespace == "eap-6f82ad81"
    assert config.is_active is True

    # Check get
    fetched = mgr.get_tenant_boundary("6f82ad81")
    assert fetched is not None
    assert fetched.namespace == "eap-6f82ad81"

    # Check active listing
    active = mgr.list_active_boundaries()
    assert len(active) == 1

    # Teardown
    assert mgr.teardown_tenant_boundary("6f82ad81") is True
    assert mgr.get_tenant_boundary("6f82ad81").is_active is False
    assert len(mgr.list_active_boundaries()) == 0


# ── API Contract Tests ─────────────────────────────────────────────────────────

from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_api_tenant_provision_and_lifecycle():
    """Verify HTTP API endpoints for provisioning, retrieving, and listing tenants."""
    resp = client.post(
        "/api/v1/eap/tenants",
        json={"company_name": "kurasi"}
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["company_name"] == "kurasi"
    assert data["customer_hash"] == "6f82ad81"
    assert data["namespace"] == "eap-6f82ad81"
    assert data["spiffe_id"] == "spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app"
    assert data["transit_key_path"] == "transit/keys/eap-6f82ad81"
    assert data["is_active"] is True

    # Retrieve by hash
    get_resp = client.get("/api/v1/eap/tenants/6f82ad81")
    assert get_resp.status_code == 200
    assert get_resp.json()["customer_hash"] == "6f82ad81"

    # List active
    list_resp = client.get("/api/v1/eap/tenants")
    assert list_resp.status_code == 200
    hashes = [t["customer_hash"] for t in list_resp.json()]
    assert "6f82ad81" in hashes

    # Teardown
    del_resp = client.delete("/api/v1/eap/tenants/6f82ad81")
    assert del_resp.status_code == 200
    assert del_resp.json()["status"] == "torn_down"


def test_api_tenant_manifests_and_spire():
    """Verify HTTP API returns complete k8s manifests and SPIRE entry."""
    # Provision explicitly: manifests are only served for a known boundary
    # (the endpoint used to fabricate a kurasi-labelled manifest for any hash,
    # which is the only reason this test once passed in isolation).
    assert client.post("/api/v1/eap/tenants", json={"company_name": "kurasi"}).status_code == 201
    resp = client.get("/api/v1/eap/tenants/6f82ad81/manifests")
    assert resp.status_code == 200
    manifests = resp.json()
    assert "namespace" in manifests
    assert "network_policy" in manifests
    assert "resource_quota" in manifests
    assert manifests["namespace"]["metadata"]["name"] == "eap-6f82ad81"

    spire_resp = client.get("/api/v1/eap/tenants/6f82ad81/spire-entry")
    assert spire_resp.status_code == 200
    spire_entry = spire_resp.json()
    assert spire_entry["spiffe_id"] == "spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app"
    assert client.delete("/api/v1/eap/tenants/6f82ad81").status_code == 200


def test_api_tenant_not_found_handling():
    """Verify 404 response when querying or tearing down non-existent tenant."""
    get_resp = client.get("/api/v1/eap/tenants/nonexist")
    assert get_resp.status_code == 404

    del_resp = client.delete("/api/v1/eap/tenants/nonexist")
    assert del_resp.status_code == 404
