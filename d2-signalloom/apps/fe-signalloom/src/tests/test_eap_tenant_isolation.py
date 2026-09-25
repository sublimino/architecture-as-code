# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_tenant_isolation.py
# Unit and integration test suite for Signal Loom Tenant Isolation Engine (SLET)
# ==============================================================================
import pytest
from tenant_isolation import (
    OPENBAO_PORT,
    SPIRE_SERVER_PORT,
    TenantIsolationManager,
    TenantIsolationConfig,
    get_spiffe_trust_domain,
    get_tenant_namespace,
    get_tenant_spiffe_id,
    get_tenant_transit_key_path,
    generate_namespace_manifest,
    generate_network_policy_manifest,
    generate_openbao_ingress_policy,
    generate_resource_quota_manifest,
    generate_spire_registration_entry,
    generate_tenant_pod_manifest,
)
from environment_routing import derive_customer_hash

KUSARI = "kusari"
KUSARI_HASH = derive_customer_hash(KUSARI)
KUSARI_NS = f"eap-{KUSARI_HASH}"


def test_tenant_naming_conventions_kusari():
    """Verify canonical naming conventions for pilot tenant kusari."""
    kusari_hash = KUSARI_HASH
    ns = get_tenant_namespace(kusari_hash)
    assert ns == KUSARI_NS

    spiffe_id = get_tenant_spiffe_id(kusari_hash)
    assert spiffe_id == f"spiffe://{get_spiffe_trust_domain()}/ns/{KUSARI_NS}/sa/tenant-app"

    transit_path = get_tenant_transit_key_path(kusari_hash)
    assert transit_path == f"transit/keys/{KUSARI_NS}"


def test_generate_namespace_manifest_restricted_labels():
    """Verify namespace manifest contains Pod Security Standards restricted labels."""
    manifest = generate_namespace_manifest(KUSARI)
    assert manifest["apiVersion"] == "v1"
    assert manifest["kind"] == "Namespace"
    assert manifest["metadata"]["name"] == KUSARI_NS

    labels = manifest["metadata"]["labels"]
    assert labels["signalloom.io/eap-hash"] == KUSARI_HASH
    assert labels["signalloom.io/customer"] == KUSARI
    assert labels["pod-security.kubernetes.io/enforce"] == "restricted"
    assert labels["pod-security.kubernetes.io/audit"] == "restricted"
    assert labels["pod-security.kubernetes.io/warn"] == "restricted"


def test_generate_network_policy_manifest():
    """Verify NetworkPolicy establishes default-deny ingress and egress."""
    manifest = generate_network_policy_manifest(KUSARI_HASH)
    assert manifest["apiVersion"] == "networking.k8s.io/v1"
    assert manifest["kind"] == "NetworkPolicy"
    assert manifest["metadata"]["namespace"] == KUSARI_NS

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

    # Check egress allows DNS to kube-system and SPIRE/OpenBao to inf-bao
    egress_ns = [
        to["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
        for rule in spec["egress"]
        for to in rule.get("to", [])
    ]
    assert "kube-system" in egress_ns
    assert "inf-bao" in egress_ns
    assert "inf-spire" not in egress_ns

    egress_ports = [
        p["port"]
        for rule in spec["egress"]
        for p in rule.get("ports", [])
    ]
    assert 53 in egress_ports
    assert OPENBAO_PORT in egress_ports
    assert SPIRE_SERVER_PORT in egress_ports


def test_generate_openbao_ingress_policy():
    """Verify OpenBao ingress policy in inf-bao allows tenant namespace."""
    manifest = generate_openbao_ingress_policy("6f82ad81")
    assert manifest["apiVersion"] == "networking.k8s.io/v1"
    assert manifest["kind"] == "NetworkPolicy"
    assert manifest["metadata"]["name"] == "allow-eap-6f82ad81-to-openbao"
    assert manifest["metadata"]["namespace"] == "inf-bao"
    assert manifest["spec"]["podSelector"]["matchLabels"]["app.kubernetes.io/name"] == "openbao"

    from_ns = manifest["spec"]["ingress"][0]["from"][0]["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
    assert from_ns == "eap-6f82ad81"
    assert manifest["spec"]["ingress"][0]["ports"][0]["port"] == OPENBAO_PORT


def test_generate_tenant_pod_manifest_csi():
    """Verify tenant pod spec uses SPIFFE CSI ephemeral volume and no hostPath."""
    pod = generate_tenant_pod_manifest("6f82ad81")
    assert pod["apiVersion"] == "v1"
    assert pod["kind"] == "Pod"
    assert pod["metadata"]["namespace"] == "eap-6f82ad81"

    volumes = pod["spec"]["volumes"]
    assert len(volumes) == 1
    assert "csi" in volumes[0]
    assert volumes[0]["csi"]["driver"] == "csi.spiffe.io"
    assert volumes[0]["csi"]["readOnly"] is True
    assert not any("hostPath" in v for v in volumes)

    container = pod["spec"]["containers"][0]
    env_vars = {e["name"]: e["value"] for e in container["env"]}
    assert env_vars["SPIFFE_ENDPOINT_SOCKET"] == "unix:///spiffe-workload-api/spire-agent.sock"

    vm = container["volumeMounts"][0]
    assert vm["name"] == "spiffe-workload-api"
    assert vm["mountPath"] == "/spiffe-workload-api"
    assert vm["readOnly"] is True


def test_generate_resource_quota_manifest():
    """Verify ResourceQuota limits CPU, memory, and pods."""
    manifest = generate_resource_quota_manifest(KUSARI_HASH)
    assert manifest["apiVersion"] == "v1"
    assert manifest["kind"] == "ResourceQuota"
    assert manifest["metadata"]["namespace"] == KUSARI_NS
    assert manifest["spec"]["hard"]["limits.cpu"] == "4"
    assert manifest["spec"]["hard"]["limits.memory"] == "8Gi"
    assert manifest["spec"]["hard"]["pods"] == "10"


def test_generate_spire_registration_entry():
    """Verify SPIRE registration entry schema and selectors."""
    entry = generate_spire_registration_entry(KUSARI_HASH)
    assert entry["spiffe_id"] == f"spiffe://{get_spiffe_trust_domain()}/ns/{KUSARI_NS}/sa/tenant-app"
    assert f"k8s:ns:{KUSARI_NS}" in entry["selectors"]
    assert "k8s:sa:tenant-app" in entry["selectors"]
    assert entry["ttl"] == 3600


def test_tenant_isolation_manager_lifecycle():
    """Verify provision, query, list, and teardown on TenantIsolationManager."""
    mgr = TenantIsolationManager()

    config = mgr.provision_tenant_boundary(KUSARI)
    assert config.company_name == KUSARI
    assert config.customer_hash == KUSARI_HASH
    assert config.namespace == KUSARI_NS
    assert config.is_active is True

    # Check get
    fetched = mgr.get_tenant_boundary(KUSARI_HASH)
    assert fetched is not None
    assert fetched.namespace == KUSARI_NS

    # Check active listing
    active = mgr.list_active_boundaries()
    assert len(active) == 1

    # Teardown
    assert mgr.teardown_tenant_boundary(KUSARI_HASH) is True
    assert mgr.get_tenant_boundary(KUSARI_HASH).is_active is False
    assert len(mgr.list_active_boundaries()) == 0


# ── API Contract Tests ─────────────────────────────────────────────────────────

from fastapi.testclient import TestClient
from main import app
from conftest import EAPClient

# EAPR-P2-1: the tenants router is mounted behind authenticated_principal;
# every request here carries a real tenant-a token (see tests/conftest.py).
EAP_AUTHENTICATED = True
client = EAPClient(app)


def test_api_tenant_provision_and_lifecycle():
    """Verify HTTP API endpoints for provisioning, retrieving, and listing tenants."""
    resp = client.post(
        "/api/v1/eap/tenants",
        json={"company_name": KUSARI}
    )
    assert resp.status_code == 201
    data = resp.json()
    assert data["company_name"] == KUSARI
    assert data["customer_hash"] == KUSARI_HASH
    assert data["namespace"] == KUSARI_NS
    assert data["spiffe_id"] == f"spiffe://{get_spiffe_trust_domain()}/ns/{KUSARI_NS}/sa/tenant-app"
    assert data["transit_key_path"] == f"transit/keys/{KUSARI_NS}"
    assert data["is_active"] is True

    # Retrieve by hash
    get_resp = client.get(f"/api/v1/eap/tenants/{KUSARI_HASH}")
    assert get_resp.status_code == 200
    assert get_resp.json()["customer_hash"] == KUSARI_HASH

    # List active
    list_resp = client.get("/api/v1/eap/tenants")
    assert list_resp.status_code == 200
    hashes = [t["customer_hash"] for t in list_resp.json()]
    assert KUSARI_HASH in hashes

    # Teardown
    del_resp = client.delete(f"/api/v1/eap/tenants/{KUSARI_HASH}")
    assert del_resp.status_code == 200
    assert del_resp.json()["status"] == "torn_down"


def test_api_tenant_manifests_and_spire():
    """Verify HTTP API returns complete k8s manifests and SPIRE entry."""
    # Provision explicitly: manifests are only served for a known boundary
    # (the endpoint used to fabricate a kusari-labelled manifest for any hash,
    # which is the only reason this test once passed in isolation).
    assert client.post("/api/v1/eap/tenants", json={"company_name": KUSARI}).status_code == 201
    resp = client.get(f"/api/v1/eap/tenants/{KUSARI_HASH}/manifests")
    assert resp.status_code == 200
    manifests = resp.json()
    assert "namespace" in manifests
    assert "network_policy" in manifests
    assert "resource_quota" in manifests
    assert "pod" in manifests
    assert "openbao_ingress_policy" in manifests
    assert manifests["namespace"]["metadata"]["name"] == KUSARI_NS

    spire_resp = client.get(f"/api/v1/eap/tenants/{KUSARI_HASH}/spire-entry")
    assert spire_resp.status_code == 200
    spire_entry = spire_resp.json()
    assert spire_entry["spiffe_id"] == f"spiffe://{get_spiffe_trust_domain()}/ns/{KUSARI_NS}/sa/tenant-app"
    assert client.delete(f"/api/v1/eap/tenants/{KUSARI_HASH}").status_code == 200


def test_api_tenant_not_found_handling():
    """Verify 404 response when querying or tearing down non-existent tenant.

    The hash must be well-formed (``^[0-9a-f]{8}$``) to reach the lookup at
    all; a malformed one is rejected by validation first (422).
    """
    get_resp = client.get("/api/v1/eap/tenants/0badcafe")
    assert get_resp.status_code == 404

    del_resp = client.delete("/api/v1/eap/tenants/0badcafe")
    assert del_resp.status_code == 404

    assert client.get("/api/v1/eap/tenants/nonexist").status_code == 422
    assert client.delete("/api/v1/eap/tenants/nonexist").status_code == 422
