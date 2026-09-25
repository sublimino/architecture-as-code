# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_eap_identity.py
# Unit tests pinning SPIFFE trust domain alignment and CSI volume projections
# ==============================================================================
import os
import pathlib
import pytest

from eap_contract import (
    OPENBAO_PORT,
    SPIRE_SERVER_PORT,
    SPIFFE_TRUST_DOMAIN,
    get_spiffe_trust_domain,
)
from tenant_isolation import (
    get_tenant_namespace,
    get_tenant_spiffe_id,
    generate_spire_registration_entry,
    generate_network_policy_manifest,
    generate_openbao_ingress_policy,
    generate_tenant_pod_manifest,
    generate_namespace_manifest,
)


def test_trust_domain_matches_cluster():
    """Verify trust domain matches live SPIRE server (signalloom.demo) and no osramp.local remains."""
    # Shared Patterns Phase 3 pinned trust domain: signalloom.demo
    expected_domain = "signalloom.demo"
    assert get_spiffe_trust_domain() == expected_domain
    assert SPIFFE_TRUST_DOMAIN == expected_domain

    # Verify that no EAP Python module contains the stale osramp.local literal
    src_root = pathlib.Path(__file__).resolve().parent.parent
    py_files = list(src_root.glob("*.py"))
    assert len(py_files) > 0, "No python files found in fe-signalloom src"

    for py_path in py_files:
        content = py_path.read_text(encoding="utf-8")
        assert "osramp.local" not in content, f"Found stale 'osramp.local' in {py_path.name}"
        assert "inf-spire" not in content, f"Found stale 'inf-spire' in {py_path.name}"


def test_spiffe_id_generation_and_spire_entry():
    """Verify tenant SPIFFE ID and SPIRE registration parent_id use signalloom.demo."""
    customer_hash = "6f82ad81"
    spiffe_id = get_tenant_spiffe_id(customer_hash)
    assert spiffe_id == "spiffe://signalloom.demo/ns/eap-6f82ad81/sa/tenant-app"

    entry = generate_spire_registration_entry(customer_hash)
    assert entry["spiffe_id"] == "spiffe://signalloom.demo/ns/eap-6f82ad81/sa/tenant-app"
    assert entry["parent_id"] == "spiffe://signalloom.demo/spire/agent/k8s-node"
    assert entry["selectors"] == ["k8s:ns:eap-6f82ad81", "k8s:sa:tenant-app"]
    assert entry["ttl"] == 3600


def test_network_policy_inf_bao_and_ports():
    """Verify network policy egress targets inf-bao with SPIRE and OpenBao ports."""
    policy = generate_network_policy_manifest("6f82ad81")
    egress_rules = policy["spec"]["egress"]

    egress_namespaces = []
    egress_ports = []
    for rule in egress_rules:
        for to_clause in rule.get("to", []):
            ns = to_clause.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name")
            if ns:
                egress_namespaces.append(ns)
        for port_clause in rule.get("ports", []):
            egress_ports.append(port_clause.get("port"))

    assert "inf-bao" in egress_namespaces
    assert "kube-system" in egress_namespaces
    assert "inf-spire" not in egress_namespaces

    assert 53 in egress_ports
    assert OPENBAO_PORT in egress_ports
    assert SPIRE_SERVER_PORT in egress_ports
    assert OPENBAO_PORT == 8200
    assert SPIRE_SERVER_PORT == 8081


def test_openbao_ingress_policy():
    """Verify OpenBao ingress policy admits tenant traffic on OPENBAO_PORT in inf-bao."""
    np = generate_openbao_ingress_policy("6f82ad81")
    assert np["metadata"]["name"] == "allow-eap-6f82ad81-to-openbao"
    assert np["metadata"]["namespace"] == "inf-bao"
    assert np["spec"]["podSelector"]["matchLabels"]["app.kubernetes.io/name"] == "openbao"

    ingress_rule = np["spec"]["ingress"][0]
    from_ns = ingress_rule["from"][0]["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
    assert from_ns == "eap-6f82ad81"
    assert ingress_rule["ports"][0]["port"] == 8200


def test_tenant_pod_csi_volume_and_no_hostpath():
    """Verify tenant pod spec utilizes SPIFFE CSI ephemeral volume without any hostPath."""
    pod = generate_tenant_pod_manifest("6f82ad81")
    volumes = pod["spec"]["volumes"]
    assert len(volumes) == 1
    assert "csi" in volumes[0]
    assert volumes[0]["csi"]["driver"] == "csi.spiffe.io"
    assert volumes[0]["csi"]["readOnly"] is True
    assert not any("hostPath" in v for v in volumes)

    container = pod["spec"]["containers"][0]
    env_map = {e["name"]: e["value"] for e in container["env"]}
    assert env_map.get("SPIFFE_ENDPOINT_SOCKET") == "unix:///spiffe-workload-api/spire-agent.sock"

    vm = container["volumeMounts"][0]
    assert vm["name"] == "spiffe-workload-api"
    assert vm["mountPath"] == "/spiffe-workload-api"
    assert vm["readOnly"] is True

    # PSS restricted securityContext
    sec = container.get("securityContext", {})
    assert sec.get("allowPrivilegeEscalation") is False
    assert sec.get("readOnlyRootFilesystem") is True
    assert sec.get("runAsNonRoot") is True
    assert "ALL" in sec.get("capabilities", {}).get("drop", [])


def test_namespace_pss_labels():
    """Verify tenant namespace manifest sets enforce, warn, and audit to restricted."""
    ns = generate_namespace_manifest("kurasi", "6f82ad81")
    labels = ns["metadata"]["labels"]
    assert labels["pod-security.kubernetes.io/enforce"] == "restricted"
    assert labels["pod-security.kubernetes.io/warn"] == "restricted"
    assert labels["pod-security.kubernetes.io/audit"] == "restricted"
    assert labels["pod-security.kubernetes.io/enforce-version"] == "latest"
