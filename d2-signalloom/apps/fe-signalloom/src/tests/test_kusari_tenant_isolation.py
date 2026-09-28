# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_kusari_tenant_isolation.py
# SLET-P4-2 — kusari tenant end-to-end attestation & isolation acceptance suite
# ==============================================================================
"""End-to-end acceptance for the pilot tenant ``kusari``.

Two tiers, one contract.

Tier 1 (always runs, hermetic): drives the real FastAPI app and the real
``TenantIsolationManager`` through the seven lifecycle stages —

    1 provision  2 PSS  3 NetworkPolicy  4 SPIFFE  5 transit  6 teardown/shred
    7 negative traversal

— plus rollback under injected faults, concurrency, and a cryptographic
workload benchmark. Every structural check here is also run against a mutated
input that must make it fail (``test_checks_reject_*``): a guard that passes
with the control removed is worthless, and "succeeds when the PSS restricted
labels are missing" is a named failure mode for this card.

Tier 2 (``SLET_LIVE_CLUSTER=1``): replays the journey against the kind-osramp
cluster — PSA admission on the real API server, NetworkPolicy enforced by
Cilium between real pods, a real SPIRE registration entry and minted X.509-SVID,
and a real OpenBao transit key that is created, used, and destroyed. It needs
``kubectl`` and ``BAO_TOKEN`` (never hardcoded; see
``scripts/eap/run_slet_p4_2_acceptance.sh``). Skipped with a stated reason
otherwise, so a standalone or CI checkout without a cluster still runs tier 1.

Evidence sinks are opt-in: set ``SLET_METRICS_PATH`` (per-stage duration, CPU,
peak memory) and/or ``SLET_TRANSCRIPT_PATH`` (JSONL of every request and
response). Unset, the suite writes nothing outside pytest's ``tmp_path``.
"""
from __future__ import annotations

import asyncio
import base64
import contextlib
import copy
import datetime as dt
import hashlib
import json
import os
import random
import re
import secrets
import shutil
import socket
import subprocess
import threading
import time
import tracemalloc
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Optional

import httpx
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from fastapi.testclient import TestClient

import tenant_isolation
from environment_routing import derive_customer_hash
from main import app
from conftest import EAPClient, eap_bearer

# EAPR-P2-1: the tenants router is mounted behind authenticated_principal and
# identity headers (X-SPIFFE-ID) are stripped at ingress.  Every request here
# carries a real token: tenant-a (alice) by default, tenant-b (bob) for the peer.
EAP_AUTHENTICATED = True
from tenant_isolation import (
    TenantIsolationManager,
    authorize_tenant_access,
    CrossTenantAccessDenied,
    generate_namespace_manifest,
    generate_network_policy_manifest,
    generate_resource_quota_manifest,
    generate_spire_registration_entry,
    get_spiffe_trust_domain,
    get_tenant_namespace,
    get_tenant_spiffe_id,
    get_tenant_transit_key_path,
    verify_tenant_svid,
)
from tenant_transit import (
    CIPHERTEXT_PREFIX,
    InMemoryTransitBackend,
    KEY_BYTES,
    NONCE_BYTES,
    TransitDecryptError,
    TransitDeletionNotAllowed,
    TransitKeyNotFound,
)

# ── Canonical pilot tenant ──────────────────────────────────────────────────
KUSARI = "kusari"
KUSARI_HASH = derive_customer_hash(KUSARI)
KUSARI_NS = get_tenant_namespace(KUSARI_HASH)
KUSARI_SPIFFE = get_tenant_spiffe_id(KUSARI_HASH)
KUSARI_KEY_PATH = get_tenant_transit_key_path(KUSARI_HASH)

# A second tenant, so every isolation claim has a concrete peer to fail against.
PEER = "slet-p4-2-peer-probe"

CIPHERTEXT_RE = re.compile(r"^vault:v1:[A-Za-z0-9+/]+={0,2}$")
GCM_TAG_BYTES = 16
PAYLOAD = b'{"customer":"kusari","record":"pilot-ledger-0001","amount_gbp":"1250.00"}'


# ── Evidence sinks ──────────────────────────────────────────────────────────
class StageMetrics:
    """Per-stage wall time, CPU time and peak Python heap, keyed by stage."""

    def __init__(self) -> None:
        self.rows: List[Dict[str, Any]] = []
        self._lock = threading.Lock()

    @contextlib.contextmanager
    def measure(self, stage: str) -> Iterator[None]:
        started_tracing = not tracemalloc.is_tracing()
        if started_tracing:
            tracemalloc.start()
        tracemalloc.reset_peak()
        base_current, _ = tracemalloc.get_traced_memory()
        t0, c0 = time.perf_counter(), time.process_time()
        try:
            yield
        finally:
            wall = time.perf_counter() - t0
            cpu = time.process_time() - c0
            _, peak = tracemalloc.get_traced_memory()
            if started_tracing:
                tracemalloc.stop()
            with self._lock:
                self.rows.append({
                    "stage": stage,
                    "duration_ms": round(wall * 1000, 3),
                    "cpu_ms": round(cpu * 1000, 3),
                    "peak_heap_kib": round(max(peak - base_current, 0) / 1024, 1),
                })


class Transcript:
    """Request/response audit log; in memory unless SLET_TRANSCRIPT_PATH is set."""

    def __init__(self) -> None:
        self.entries: List[Dict[str, Any]] = []
        self._lock = threading.Lock()

    def record(self, stage: str, kind: str, **payload: Any) -> None:
        entry = {
            "ts": dt.datetime.now(dt.timezone.utc).isoformat(),
            "stage": stage,
            "kind": kind,
            **payload,
        }
        with self._lock:
            self.entries.append(entry)


@pytest.fixture(scope="session")
def stage_metrics() -> Iterator[StageMetrics]:
    m = StageMetrics()
    yield m
    sink = os.environ.get("SLET_METRICS_PATH")
    if sink and m.rows:
        Path(sink).write_text(json.dumps(m.rows, indent=2) + "\n")


@pytest.fixture(scope="session")
def transcript() -> Iterator[Transcript]:
    t = Transcript()
    yield t
    sink = os.environ.get("SLET_TRANSCRIPT_PATH")
    if sink and t.entries:
        with open(sink, "w") as fh:
            for e in t.entries:
                fh.write(json.dumps(e, sort_keys=True) + "\n")


# ── Isolation of global state ───────────────────────────────────────────────
@pytest.fixture(autouse=True)
def canonical_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Pin the trust domain so tests derive canonical values."""
    monkeypatch.delenv("SLET_SPIFFE_TRUST_DOMAIN", raising=False)


@pytest.fixture
def manager(monkeypatch: pytest.MonkeyPatch) -> TenantIsolationManager:
    """A fresh manager + transit engine behind the real API routes.

    The routes resolve ``GLOBAL_TENANT_ISOLATION_MANAGER`` at call time, so
    swapping the module attribute isolates this test without touching the app.
    It is restored by monkeypatch, leaving no state behind.
    """
    mgr = TenantIsolationManager(transit=InMemoryTransitBackend())
    monkeypatch.setattr(tenant_isolation, "GLOBAL_TENANT_ISOLATION_MANAGER", mgr)
    return mgr


@pytest.fixture
def client(manager: TenantIsolationManager) -> TestClient:
    return EAPClient(app)


class Api:
    """Thin wrapper that records every exchange into the transcript."""

    def __init__(self, client: TestClient, transcript: Transcript) -> None:
        self.client = client
        self.transcript = transcript

    def call(self, stage: str, method: str, path: str, *, json_body: Any = None,
             headers: Optional[Dict[str, str]] = None) -> httpx.Response:
        resp = self.client.request(method, path, json=json_body, headers=headers)
        try:
            body: Any = resp.json()
        except ValueError:
            body = resp.text
        self.transcript.record(
            stage, "http",
            request={"method": method, "path": path, "json": json_body,
                     "headers": {k: ("<redacted>" if k.lower() == "authorization" else v)
                                 for k, v in (headers or {}).items()}},
            response={"status": resp.status_code, "json": body},
        )
        return resp


@pytest.fixture
def api(client: TestClient, transcript: Transcript) -> Api:
    return Api(client, transcript)


def error_code(resp: httpx.Response) -> str:
    """The app's global handler wraps errors as {"error": {"code", "message"}}
    and masks HTTPException detail, so the HTTP layer can only show *that* a
    request failed; tests pin *why* at the manager layer."""
    return resp.json()["error"]["code"]


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


# ── Structural checks (each one is falsified below) ─────────────────────────
def check_namespace_pss_restricted(manifest: Dict[str, Any], customer_hash: str, company: str) -> None:
    assert manifest["apiVersion"] == "v1"
    assert manifest["kind"] == "Namespace"
    meta = manifest["metadata"]
    assert meta["name"] == get_tenant_namespace(customer_hash)
    labels = meta.get("labels", {})
    for mode in ("enforce", "audit", "warn"):
        assert labels.get(f"pod-security.kubernetes.io/{mode}") == "restricted", (
            f"PSS {mode} label missing or not 'restricted': {labels.get(f'pod-security.kubernetes.io/{mode}')!r}"
        )
    assert labels.get("pod-security.kubernetes.io/enforce-version") == "latest"
    assert labels.get("signalloom.io/eap-hash") == customer_hash
    assert labels.get("signalloom.io/customer") == company
    assert labels.get("app.kubernetes.io/managed-by") == "signalloom-eap"


def _peer_matches(peer: Dict[str, Any], ns_labels: Dict[str, str], pod_labels: Dict[str, str]) -> bool:
    """Kubernetes NetworkPolicyPeer semantics for matchLabels selectors.

    Within one peer, namespaceSelector and podSelector are ANDed. An absent
    namespaceSelector means "the policy's own namespace", which a tenant policy
    must never rely on for cross-namespace traffic, so we treat it as no match
    for foreign namespaces. ipBlock peers match nothing here and are rejected
    outright by check_default_deny_network_policy.
    """
    if "ipBlock" in peer:
        return False
    ns_sel = peer.get("namespaceSelector")
    pod_sel = peer.get("podSelector")
    if ns_sel is None:
        return False
    if any(ns_labels.get(k) != v for k, v in ns_sel.get("matchLabels", {}).items()):
        return False
    if pod_sel is not None and any(pod_labels.get(k) != v for k, v in pod_sel.get("matchLabels", {}).items()):
        return False
    return True


def _port_matches(rule: Dict[str, Any], port: int, proto: str) -> bool:
    ports = rule.get("ports")
    if not ports:  # absent/empty ports == all ports
        return True
    return any(p.get("port") == port and p.get("protocol", "TCP") == proto for p in ports)


def policy_allows(policy: Dict[str, Any], direction: str, ns: str, port: int,
                  proto: str = "TCP", pod_labels: Optional[Dict[str, str]] = None) -> bool:
    """Would this NetworkPolicy admit a flow to/from namespace ``ns``?"""
    spec = policy["spec"]
    type_name = "Ingress" if direction == "ingress" else "Egress"
    if type_name not in spec.get("policyTypes", []):
        return True  # not isolated in this direction
    peer_key = "from" if direction == "ingress" else "to"
    ns_labels = {"kubernetes.io/metadata.name": ns}
    for rule in spec.get(direction, []):
        peers = rule.get(peer_key)
        if not peers:  # absent/empty peers == all sources/destinations
            if _port_matches(rule, port, proto):
                return True
            continue
        if any(_peer_matches(p, ns_labels, pod_labels or {}) for p in peers) and _port_matches(rule, port, proto):
            return True
    return False


def check_default_deny_network_policy(policy: Dict[str, Any], customer_hash: str) -> None:
    assert policy["kind"] == "NetworkPolicy"
    assert policy["metadata"]["namespace"] == get_tenant_namespace(customer_hash)
    spec = policy["spec"]
    assert spec["podSelector"] == {}, "policy must select every pod in the tenant namespace"
    assert sorted(spec["policyTypes"]) == ["Egress", "Ingress"]
    text = json.dumps(spec)
    assert "ipBlock" not in text, "tenant policy must not open CIDR ranges"
    for direction, key in (("ingress", "from"), ("egress", "to")):
        for rule in spec.get(direction, []):
            assert rule.get(key), f"{direction} rule with empty '{key}' allows every peer"
            assert rule.get("ports"), f"{direction} rule with no ports allows every port"
    # Ingress: exactly the designated gateway namespaces, exactly TCP/8080.
    assert len(spec["ingress"]) == 1
    ingress_ns = sorted(p["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
                        for p in spec["ingress"][0]["from"])
    assert ingress_ns == ["fe-signalloom", "ingress"]
    assert spec["ingress"][0]["ports"] == [{"protocol": "TCP", "port": 8080}]
    # Egress DNS: kube-dns pods in kube-system only, port 53 only.
    dns = [r for r in spec["egress"] if any(p.get("port") == 53 for p in r["ports"])]
    assert len(dns) == 1
    assert sorted((p["protocol"], p["port"]) for p in dns[0]["ports"]) == [("TCP", 53), ("UDP", 53)]
    assert dns[0]["to"] == [{
        "namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
        "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}},
    }]


def check_traversal_matrix(policy: Dict[str, Any], peer_ns: str) -> Dict[str, bool]:
    """Evaluate the flows that matter and assert the isolation verdict for each."""
    kube_dns = {"k8s-app": "kube-dns"}
    matrix = {
        # (allowed?) flows INTO the tenant
        "ingress<-ingress:8080": policy_allows(policy, "ingress", "ingress", 8080),
        "ingress<-fe-signalloom:8080": policy_allows(policy, "ingress", "fe-signalloom", 8080),
        "ingress<-ingress:9090": policy_allows(policy, "ingress", "ingress", 9090),
        f"ingress<-{peer_ns}:8080": policy_allows(policy, "ingress", peer_ns, 8080),
        "ingress<-default:8080": policy_allows(policy, "ingress", "default", 8080),
        "ingress<-kube-system:8080": policy_allows(policy, "ingress", "kube-system", 8080),
        # flows OUT of the tenant
        "egress->kube-dns:53/UDP": policy_allows(policy, "egress", "kube-system", 53, "UDP", kube_dns),
        "egress->kube-dns:53/TCP": policy_allows(policy, "egress", "kube-system", 53, "TCP", kube_dns),
        "egress->kube-system(non-dns):53/UDP": policy_allows(policy, "egress", "kube-system", 53, "UDP", {"k8s-app": "metrics"}),
        "egress->inf-bao:8200": policy_allows(policy, "egress", "inf-bao", 8200),
        "egress->inf-bao:8081": policy_allows(policy, "egress", "inf-bao", 8081),
        f"egress->{peer_ns}:8080": policy_allows(policy, "egress", peer_ns, 8080),
        "egress->fe-signalloom:8000": policy_allows(policy, "egress", "fe-signalloom", 8000),
        "egress->ingress:8080": policy_allows(policy, "egress", "ingress", 8080),
    }
    expected_allowed = {
        "ingress<-ingress:8080", "ingress<-fe-signalloom:8080",
        "egress->kube-dns:53/UDP", "egress->kube-dns:53/TCP",
        "egress->inf-bao:8200", "egress->inf-bao:8081",
    }
    for flow, allowed in matrix.items():
        assert allowed == (flow in expected_allowed), f"flow {flow}: allowed={allowed}"
    return matrix


def check_spire_entry(entry: Dict[str, Any], customer_hash: str) -> None:
    ns = get_tenant_namespace(customer_hash)
    assert entry["spiffe_id"] == get_tenant_spiffe_id(customer_hash)
    assert entry["parent_id"] == f"spiffe://{get_spiffe_trust_domain()}/spire/agent/k8s-node"
    assert sorted(entry["selectors"]) == sorted([f"k8s:ns:{ns}", "k8s:sa:tenant-app"])
    assert entry["ttl"] == 3600
    assert entry["admin"] is False


def check_ciphertext_shape(ciphertext: str, plaintext_len: int) -> bytes:
    assert CIPHERTEXT_RE.match(ciphertext), ciphertext
    raw = base64.b64decode(ciphertext[len(CIPHERTEXT_PREFIX):])
    assert len(raw) == NONCE_BYTES + plaintext_len + GCM_TAG_BYTES
    return raw


# ── Local SVID minting (tier-1 stand-in for SPIRE's CA) ─────────────────────
def mint_svid(spiffe_ids: List[str], lifetime: dt.timedelta = dt.timedelta(hours=1),
              is_ca: bool = False) -> bytes:
    ca_key = ec.generate_private_key(ec.SECP256R1())
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    now = dt.datetime.now(dt.timezone.utc)
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.ORGANIZATION_NAME, "SPIRE")]))
        .issuer_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "slet-test-ca")]))
        .public_key(leaf_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + lifetime)
        .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True)
    )
    if spiffe_ids:
        builder = builder.add_extension(
            x509.SubjectAlternativeName([x509.UniformResourceIdentifier(u) for u in spiffe_ids]),
            critical=False,
        )
    return builder.sign(ca_key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM)


# ══════════════════════════════════════════════════════════════════════════════
# Tier 1 — the seven-stage kusari journey
# ══════════════════════════════════════════════════════════════════════════════
def test_kusari_canonical_hash_is_derived_not_assumed() -> None:
    """The hash every other assertion pins is recomputed from its definition."""
    assert derive_customer_hash(KUSARI) == KUSARI_HASH
    # Normalisation: case and surrounding whitespace do not fork the identity.
    assert derive_customer_hash("  KUSARI ") == KUSARI_HASH


def test_kusari_end_to_end_journey(api: Api, manager: TenantIsolationManager,
                                   stage_metrics: StageMetrics, transcript: Transcript,
                                   fresh_tenant_ownership) -> None:
    peer_hash = derive_customer_hash(PEER)
    assert peer_hash != KUSARI_HASH

    # Stage 1 — boundary provisioning
    with stage_metrics.measure("1-provision"):
        r = api.call("1-provision", "POST", "/api/v1/eap/tenants", json_body={"company_name": KUSARI})
        assert r.status_code == 201, r.text
        assert r.json() == {
            "company_name": KUSARI,
            "customer_hash": KUSARI_HASH,
            "namespace": KUSARI_NS,
            "spiffe_id": KUSARI_SPIFFE,
            "transit_key_path": KUSARI_KEY_PATH,
            "is_active": True,
        }
        assert manager.transit.key_exists(f"eap-{KUSARI_HASH}")
        # The peer belongs to another tenant (bob / tenant-b), so Stage 7 is a
        # genuine cross-tenant negative rather than one caller on two hashes.
        assert api.call("1-provision", "POST", "/api/v1/eap/tenants",
                        json_body={"company_name": PEER}, headers=eap_bearer("bob")).status_code == 201

    manifests = api.call("2-pss", "GET", f"/api/v1/eap/tenants/{KUSARI_HASH}/manifests").json()
    transcript.record("2-pss", "manifests", manifests=manifests)

    # Stage 2 — Pod Security Standards
    with stage_metrics.measure("2-pss"):
        check_namespace_pss_restricted(manifests["namespace"], KUSARI_HASH, KUSARI)
        assert manifests["resource_quota"]["metadata"]["namespace"] == KUSARI_NS
        assert manifests["resource_quota"]["spec"]["hard"]["pods"] == "10"

    # Stage 3 — NetworkPolicy default deny + designated allows
    with stage_metrics.measure("3-netpol"):
        policy = manifests["network_policy"]
        check_default_deny_network_policy(policy, KUSARI_HASH)
        matrix = check_traversal_matrix(policy, get_tenant_namespace(peer_hash))
        transcript.record("3-netpol", "traversal-matrix", matrix=matrix)

    # Stage 4 — SPIFFE attestation
    with stage_metrics.measure("4-spiffe"):
        r = api.call("4-spiffe", "GET", f"/api/v1/eap/tenants/{KUSARI_HASH}/spire-entry")
        assert r.status_code == 200
        check_spire_entry(r.json(), KUSARI_HASH)
        svid = verify_tenant_svid(mint_svid([KUSARI_SPIFFE]), KUSARI_HASH)
        assert svid["spiffe_id"] == KUSARI_SPIFFE
        assert svid["lifetime_seconds"] == 3600
        transcript.record("4-spiffe", "svid", svid=svid)

    # Stage 5 — cryptographic transit
    with stage_metrics.measure("5-transit"):
        r = api.call("5-transit", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/encrypt",
                     json_body={"plaintext": b64(PAYLOAD)})
        assert r.status_code == 200, r.text
        assert r.json()["key_path"] == KUSARI_KEY_PATH
        ciphertext = r.json()["ciphertext"]
        raw = check_ciphertext_shape(ciphertext, len(PAYLOAD))
        assert PAYLOAD not in raw
        again = api.call("5-transit", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/encrypt",
                         json_body={"plaintext": b64(PAYLOAD)}).json()
        assert again["ciphertext"] != ciphertext, "nonce reuse: identical ciphertexts"
        r = api.call("5-transit", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/decrypt",
                     json_body={"ciphertext": ciphertext})
        assert r.status_code == 200
        assert base64.b64decode(r.json()["plaintext"]) == PAYLOAD

    # Stage 7 (while live) — negative traversal
    with stage_metrics.measure("7-negative"):
        peer_identity = eap_bearer("bob")
        r = api.call("7-negative", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/decrypt",
                     json_body={"ciphertext": ciphertext}, headers=peer_identity)
        assert r.status_code == 404  # kusari is not bob's: existence is not leaked
        # Even through its own door, the peer's key cannot open kusari's data.
        r = api.call("7-negative", "POST", f"/api/v1/eap/tenants/{peer_hash}/transit/decrypt",
                     json_body={"ciphertext": ciphertext}, headers=peer_identity)
        assert r.status_code == 400 and error_code(r) == "request_error"
        with pytest.raises(TransitDecryptError, match="authentication"):
            manager.decrypt_for_tenant(peer_hash, ciphertext)

    # Stage 6 — teardown and shredding
    with stage_metrics.measure("6-teardown"):
        state = manager.transit._keys[f"eap-{KUSARI_HASH}"]  # white-box: watch the bytes die
        live_material = state.material
        expected_fp = hashlib.sha256(bytes(live_material)).hexdigest()
        r = api.call("6-teardown", "DELETE", f"/api/v1/eap/tenants/{KUSARI_HASH}")
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "torn_down"
        shred = body["key_shred"]
        assert shred["key_path"] == KUSARI_KEY_PATH
        assert shred["material_zeroised"] is True
        assert shred["key_fingerprint_sha256"] == expected_fp
        assert bytes(live_material) == b"\x00" * KEY_BYTES, "key bytes survived teardown"
        assert not manager.transit.key_exists(f"eap-{KUSARI_HASH}")
        assert api.call("6-teardown", "GET", f"/api/v1/eap/tenants/{KUSARI_HASH}").json()["is_active"] is False
        assert KUSARI_HASH not in [t["customer_hash"] for t in
                                   api.call("6-teardown", "GET", "/api/v1/eap/tenants").json()]
        r = api.call("6-teardown", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/decrypt",
                     json_body={"ciphertext": ciphertext})
        assert r.status_code == 404, "ciphertext still decryptable after shredding"
        transcript.record("6-teardown", "shred-proof", ciphertext=ciphertext, receipt=shred,
                          post_shred_decrypt_status=r.status_code)
        assert api.call("6-teardown", "DELETE", f"/api/v1/eap/tenants/{peer_hash}",
                        headers=eap_bearer("bob")).status_code == 200


def test_stage6_reprovision_gets_a_new_key_and_old_data_stays_dead(api: Api, manager: TenantIsolationManager) -> None:
    """Same tenant, same key name, new key: pre-teardown ciphertext never opens again."""
    api.call("6-reprovision", "POST", "/api/v1/eap/tenants", json_body={"company_name": KUSARI})
    ct = api.call("6-reprovision", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/encrypt",
                  json_body={"plaintext": b64(PAYLOAD)}).json()["ciphertext"]
    first = api.call("6-reprovision", "DELETE", f"/api/v1/eap/tenants/{KUSARI_HASH}").json()["key_shred"]

    assert api.call("6-reprovision", "POST", "/api/v1/eap/tenants",
                    json_body={"company_name": KUSARI}).status_code == 201
    r = api.call("6-reprovision", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/decrypt",
                 json_body={"ciphertext": ct})
    assert r.status_code == 400 and error_code(r) == "request_error"
    with pytest.raises(TransitDecryptError, match="authentication"):
        manager.decrypt_for_tenant(KUSARI_HASH, ct)
    second = api.call("6-reprovision", "DELETE", f"/api/v1/eap/tenants/{KUSARI_HASH}").json()["key_shred"]
    assert first["key_fingerprint_sha256"] != second["key_fingerprint_sha256"]


def test_stage6_teardown_is_idempotent_and_does_not_reshred(api: Api, manager: TenantIsolationManager) -> None:
    api.call("6-idem", "POST", "/api/v1/eap/tenants", json_body={"company_name": KUSARI})
    first = api.call("6-idem", "DELETE", f"/api/v1/eap/tenants/{KUSARI_HASH}").json()["key_shred"]
    again = api.call("6-idem", "DELETE", f"/api/v1/eap/tenants/{KUSARI_HASH}")
    assert again.status_code == 200
    assert again.json()["key_shred"] == first


@pytest.mark.parametrize("caller", [
    None,
    "",
    "spiffe://evil.local/ns/eap-attacker99/sa/tenant-app",   # foreign tenant
    f"spiffe://{get_spiffe_trust_domain()}/ns/eap-{KUSARI_HASH}0/sa/tenant-app",  # prefix extension
    f"spiffe://{get_spiffe_trust_domain()}/ns/eap-{KUSARI_HASH[:-1]}/sa/tenant-app",    # truncation
    f"spiffe://{get_spiffe_trust_domain()}/ns/eap-{KUSARI_HASH}/sa/default",      # other SA, same namespace
    f"spiffe://evil.local/ns/eap-{KUSARI_HASH}/sa/tenant-app",     # foreign trust domain
    f"spiffe://{get_spiffe_trust_domain()}/ns/EAP-{KUSARI_HASH.upper()}/sa/tenant-app",   # case games
    KUSARI_SPIFFE + "/",                                      # trailing slash
    KUSARI_SPIFFE + "?sa=tenant-app",                         # query smuggling
])
def test_stage7_cross_tenant_identities_are_rejected(api: Api, caller: Optional[str],
                                                    fresh_tenant_ownership) -> None:
    """A claimed workload identity grants nothing over HTTP; only the tenant does.

    X-SPIFFE-ID is stripped at ingress (EAPR-P2-1), so each forged identity is
    sent alongside a real bearer token: another tenant (bob) gets 404 on
    kusari's hash, anonymous gets 401, and the owner (alice) still succeeds
    with the same forged header, so neither refusal is an endpoint that
    rejects everyone.  The identity check itself is pinned at the function.
    """
    assert api.call("7-identities", "POST", "/api/v1/eap/tenants",
                    json_body={"company_name": KUSARI}).status_code == 201
    forged = {} if caller is None else {"X-SPIFFE-ID": caller}
    path = f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/encrypt"
    r = api.call("7-identities", "POST", path, json_body={"plaintext": b64(PAYLOAD)},
                 headers={**forged, **eap_bearer("bob")})
    assert r.status_code == 404, (caller, r.status_code, r.text)
    anonymous = TestClient(app).post(path, json={"plaintext": b64(PAYLOAD)}, headers=forged)
    assert anonymous.status_code == 401, (caller, anonymous.status_code, anonymous.text)
    owner = api.call("7-identities", "POST", path, json_body={"plaintext": b64(PAYLOAD)}, headers=forged)
    assert owner.status_code == 200, (caller, owner.status_code, owner.text)
    with pytest.raises(CrossTenantAccessDenied):
        authorize_tenant_access(caller, KUSARI_HASH)


def test_stage7_positive_control_the_owner_is_admitted(api: Api) -> None:
    """Without this, every 403 above could be an endpoint that rejects everyone."""
    api.call("7-positive", "POST", "/api/v1/eap/tenants", json_body={"company_name": KUSARI})
    authorize_tenant_access(KUSARI_SPIFFE, KUSARI_HASH)
    r = api.call("7-positive", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/encrypt",
                 json_body={"plaintext": b64(PAYLOAD)})
    assert r.status_code == 200


def test_stage7_unknown_hash_is_never_labelled_as_kusari(api: Api) -> None:
    """The manifests route used to fabricate a kusari-labelled namespace for any hash."""
    r = api.call("7-fabrication", "GET", "/api/v1/eap/tenants/deadbeef/manifests")
    assert r.status_code == 404
    assert "kusari" not in r.text


def test_stage7_svid_for_another_tenant_is_rejected() -> None:
    peer_id = get_tenant_spiffe_id(derive_customer_hash(PEER))
    with pytest.raises(ValueError, match="URI SAN"):
        verify_tenant_svid(mint_svid([peer_id]), KUSARI_HASH)
    with pytest.raises(ValueError, match="exactly one URI SAN"):
        verify_tenant_svid(mint_svid([KUSARI_SPIFFE, peer_id]), KUSARI_HASH)
    with pytest.raises(ValueError, match="exactly one URI SAN|subjectAltName"):
        verify_tenant_svid(mint_svid([]), KUSARI_HASH)
    with pytest.raises(ValueError, match="exceeds tenant TTL"):
        verify_tenant_svid(mint_svid([KUSARI_SPIFFE], lifetime=dt.timedelta(hours=2)), KUSARI_HASH)
    with pytest.raises(ValueError, match="exceeds tenant TTL"):
        verify_tenant_svid(mint_svid([KUSARI_SPIFFE], lifetime=dt.timedelta(seconds=3611)), KUSARI_HASH)
    # SPIRE's 10s backdate is tolerated, exactly.
    verify_tenant_svid(mint_svid([KUSARI_SPIFFE], lifetime=dt.timedelta(seconds=3610)), KUSARI_HASH)
    with pytest.raises(ValueError, match="CA certificate"):
        verify_tenant_svid(mint_svid([KUSARI_SPIFFE], is_ca=True), KUSARI_HASH)


def test_stage5_tampered_ciphertext_is_rejected(api: Api) -> None:
    api.call("5-tamper", "POST", "/api/v1/eap/tenants", json_body={"company_name": KUSARI})
    ct = api.call("5-tamper", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/encrypt",
                  json_body={"plaintext": b64(PAYLOAD)}).json()["ciphertext"]
    raw = bytearray(base64.b64decode(ct[len(CIPHERTEXT_PREFIX):]))
    raw[NONCE_BYTES + 3] ^= 0x01
    for bad in (CIPHERTEXT_PREFIX + b64(bytes(raw)), "vault:v2:" + ct[9:], "not-a-ciphertext",
                CIPHERTEXT_PREFIX + b64(b"short")):
        r = api.call("5-tamper", "POST", f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/decrypt",
                     json_body={"ciphertext": bad})
        assert r.status_code == 400, (bad, r.text)


# ── Falsification: every check must fail when its control is removed ────────
def _drop(path: List[str]) -> Callable[[Dict[str, Any]], None]:
    def mutate(m: Dict[str, Any]) -> None:
        node = m
        for k in path[:-1]:
            node = node[k]
        del node[path[-1]]
    return mutate


def _set(path: List[str], value: Any) -> Callable[[Dict[str, Any]], None]:
    def mutate(m: Dict[str, Any]) -> None:
        node = m
        for k in path[:-1]:
            node = node[k]
        node[path[-1]] = value
    return mutate


LABELS = ["metadata", "labels"]


@pytest.mark.parametrize("name,mutate", [
    ("no-enforce", _drop(LABELS + ["pod-security.kubernetes.io/enforce"])),
    ("enforce-baseline", _set(LABELS + ["pod-security.kubernetes.io/enforce"], "baseline")),
    ("enforce-privileged", _set(LABELS + ["pod-security.kubernetes.io/enforce"], "privileged")),
    ("no-audit", _drop(LABELS + ["pod-security.kubernetes.io/audit"])),
    ("no-warn", _drop(LABELS + ["pod-security.kubernetes.io/warn"])),
    ("no-labels", _drop(LABELS)),
    ("wrong-hash", _set(LABELS + ["signalloom.io/eap-hash"], "00000000")),
    ("wrong-name", _set(["metadata", "name"], "eap-00000000")),
])
def test_checks_reject_namespace_without_restricted_pss(name: str, mutate: Callable) -> None:
    good = generate_namespace_manifest(KUSARI)
    check_namespace_pss_restricted(good, KUSARI_HASH, KUSARI)  # control: passes unmutated
    bad = copy.deepcopy(good)
    mutate(bad)
    with pytest.raises((AssertionError, KeyError)):
        check_namespace_pss_restricted(bad, KUSARI_HASH, KUSARI)


def _open_ingress(m: Dict[str, Any]) -> None:
    m["spec"]["ingress"][0]["from"] = []


def _open_egress_peer(m: Dict[str, Any]) -> None:
    m["spec"]["egress"].append({"to": [{"namespaceSelector": {"matchLabels": {
        "kubernetes.io/metadata.name": get_tenant_namespace(derive_customer_hash(PEER))}}}],
        "ports": [{"protocol": "TCP", "port": 8080}]})


def _dns_any_kube_system(m: Dict[str, Any]) -> None:
    del m["spec"]["egress"][0]["to"][0]["podSelector"]


def _ingress_all_ports(m: Dict[str, Any]) -> None:
    del m["spec"]["ingress"][0]["ports"]


def _cidr_egress(m: Dict[str, Any]) -> None:
    m["spec"]["egress"].append({"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}],
                                "ports": [{"protocol": "TCP", "port": 443}]})


def _no_egress_type(m: Dict[str, Any]) -> None:
    m["spec"]["policyTypes"] = ["Ingress"]


def _selects_one_pod(m: Dict[str, Any]) -> None:
    m["spec"]["podSelector"] = {"matchLabels": {"app": "tenant-app"}}


@pytest.mark.parametrize("mutate", [_open_ingress, _open_egress_peer, _dns_any_kube_system,
                                    _ingress_all_ports, _cidr_egress, _no_egress_type, _selects_one_pod])
def test_checks_reject_weakened_network_policy(mutate: Callable) -> None:
    peer_ns = get_tenant_namespace(derive_customer_hash(PEER))
    good = generate_network_policy_manifest(KUSARI_HASH)
    check_default_deny_network_policy(good, KUSARI_HASH)
    check_traversal_matrix(good, peer_ns)
    bad = copy.deepcopy(good)
    mutate(bad)
    with pytest.raises((AssertionError, KeyError)):
        check_default_deny_network_policy(bad, KUSARI_HASH)
        check_traversal_matrix(bad, peer_ns)


def test_checks_traversal_evaluator_catches_semantic_opening() -> None:
    """The matrix alone (not the shape check) must catch a peer being admitted."""
    peer_ns = get_tenant_namespace(derive_customer_hash(PEER))
    bad = generate_network_policy_manifest(KUSARI_HASH)
    _open_ingress(bad)
    with pytest.raises(AssertionError, match=re.escape(f"ingress<-{peer_ns}:8080")):
        check_traversal_matrix(bad, peer_ns)


# ── Rollback under injected faults ──────────────────────────────────────────
class FlakyTransit(InMemoryTransitBackend):
    """Fails ``enable_deletion`` a fixed number of times, then recovers."""

    def __init__(self, failures: int) -> None:
        super().__init__()
        self.failures_left = failures

    def enable_deletion(self, name: str) -> None:
        if self.failures_left > 0:
            self.failures_left -= 1
            raise ConnectionError("injected: OpenBao unavailable during key config")
        super().enable_deletion(name)


class DeadTransit(InMemoryTransitBackend):
    def create_key(self, name: str) -> None:
        raise ConnectionError("injected: OpenBao unreachable")


def test_rollback_transient_fault_after_key_creation_leaves_nothing() -> None:
    transit = FlakyTransit(failures=1)
    mgr = TenantIsolationManager(transit=transit)
    with pytest.raises(ConnectionError):
        mgr.provision_tenant_boundary(KUSARI)
    assert mgr.get_tenant_boundary(KUSARI_HASH) is None, "phantom boundary recorded"
    assert not transit.key_exists(f"eap-{KUSARI_HASH}"), "half-created key orphaned"
    # Recovery: the next attempt provisions cleanly.
    cfg = mgr.provision_tenant_boundary(KUSARI)
    assert cfg.is_active and transit.key_exists(f"eap-{KUSARI_HASH}")


def test_rollback_fault_before_key_creation_leaves_nothing() -> None:
    transit = DeadTransit()
    mgr = TenantIsolationManager(transit=transit)
    with pytest.raises(ConnectionError):
        mgr.provision_tenant_boundary(KUSARI)
    assert mgr.get_tenant_boundary(KUSARI_HASH) is None
    assert transit._keys == {}


def test_rollback_validation_failure_after_key_creation_shreds_the_key() -> None:
    """A rejected boundary (name > 64 chars) fails after the key exists."""
    transit = InMemoryTransitBackend()
    mgr = TenantIsolationManager(transit=transit)
    with pytest.raises(Exception):
        mgr.provision_tenant_boundary("k" * 65, customer_hash=KUSARI_HASH)
    assert transit._keys == {}
    assert mgr.list_active_boundaries() == []


def test_raw_delete_refused_without_deletion_allowed() -> None:
    """The guard OpenBao applies; shred_key must go through enable_deletion first."""
    transit = InMemoryTransitBackend()
    transit.create_key("eap-probe")
    transit._keys["eap-probe"].deletion_allowed = False
    with pytest.raises(TransitDeletionNotAllowed):
        transit.delete_key("eap-probe")
    assert transit.key_exists("eap-probe")
    assert transit.shred_key("eap-probe").material_zeroised is True
    with pytest.raises(TransitKeyNotFound):
        transit.encrypt("eap-probe", b"x")


# ── Concurrency ─────────────────────────────────────────────────────────────
def test_concurrent_provision_of_same_tenant_yields_one_boundary_one_key() -> None:
    transit = InMemoryTransitBackend()
    mgr = TenantIsolationManager(transit=transit)
    barrier = threading.Barrier(32)

    def provision(_: int):
        barrier.wait()
        return mgr.provision_tenant_boundary(KUSARI)

    with ThreadPoolExecutor(max_workers=32) as pool:
        configs = list(pool.map(provision, range(32)))
    assert len({id(c) for c in configs}) == 1
    assert list(transit._keys) == [f"eap-{KUSARI_HASH}"]

    def teardown(_: int) -> bool:
        barrier.wait()
        return mgr.teardown_tenant_boundary(KUSARI_HASH)

    with ThreadPoolExecutor(max_workers=32) as pool:
        assert all(pool.map(teardown, range(32)))
    assert transit._keys == {}
    assert mgr.get_shred_receipt(KUSARI_HASH).material_zeroised is True


def test_concurrent_mixed_journeys_preserve_the_key_invariant() -> None:
    """Random interleaved provision/teardown across 12 tenants; invariant holds after."""
    transit = InMemoryTransitBackend()
    mgr = TenantIsolationManager(transit=transit)
    names = [KUSARI] + [f"slet-concurrency-{i}" for i in range(11)]
    rng = random.Random(0x12345678)
    ops = [(rng.choice(names), rng.random() < 0.6) for _ in range(600)]
    errors: List[BaseException] = []

    def run(op):
        name, provision = op
        try:
            if provision:
                mgr.provision_tenant_boundary(name)
            else:
                mgr.teardown_tenant_boundary(derive_customer_hash(name))
        except BaseException as exc:  # pragma: no cover - surfaced by the assert
            errors.append(exc)

    with ThreadPoolExecutor(max_workers=24) as pool:
        list(pool.map(run, ops))
    assert errors == []
    for name in names:
        h = derive_customer_hash(name)
        cfg = mgr.get_tenant_boundary(h)
        has_key = transit.key_exists(f"eap-{h}")
        assert (cfg is not None and cfg.is_active) == has_key, f"{name}: active/key diverged"
    active_keys = {f"eap-{c.customer_hash}" for c in mgr.list_active_boundaries()}
    assert set(transit._keys) == active_keys


@pytest.mark.asyncio
async def test_concurrent_http_journeys_over_asgi(manager: TenantIsolationManager) -> None:
    """20 parallel kusari+peer journeys through the ASGI stack, no state corruption."""
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://slet.test", headers=eap_bearer()) as ac:
        provisions = await asyncio.gather(*[
            ac.post("/api/v1/eap/tenants", json={"company_name": KUSARI if i % 2 == 0 else f"slet-async-{i}"})
            for i in range(20)
        ])
        assert all(r.status_code == 201 for r in provisions)
        assert {r.json()["namespace"] for r in provisions if r.json()["company_name"] == KUSARI} == {KUSARI_NS}

        async def roundtrip(i: int) -> bytes:
            pt = f"record-{i}".encode()
            ct = (await ac.post(f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/encrypt",
                                json={"plaintext": b64(pt)})).json()["ciphertext"]
            out = await ac.post(f"/api/v1/eap/tenants/{KUSARI_HASH}/transit/decrypt",
                                json={"ciphertext": ct})
            return base64.b64decode(out.json()["plaintext"])

        results = await asyncio.gather(*[roundtrip(i) for i in range(50)])
        assert results == [f"record-{i}".encode() for i in range(50)]

        teardowns = await asyncio.gather(*[
            ac.delete(f"/api/v1/eap/tenants/{r.json()['customer_hash']}") for r in provisions
        ])
        assert all(t.status_code == 200 for t in teardowns)
    assert manager.list_active_boundaries() == []
    assert manager.transit._keys == {}


# ── Performance: peak cryptographic workload ────────────────────────────────
def test_peak_crypto_workload_budget(stage_metrics: StageMetrics) -> None:
    """1,000 x 4 KiB seal/open cycles: record cost, and bound it loosely."""
    transit = InMemoryTransitBackend()
    mgr = TenantIsolationManager(transit=transit)
    mgr.provision_tenant_boundary(KUSARI)
    blob = secrets.token_bytes(4096)
    n = 1000
    with stage_metrics.measure("perf-crypto-1000x4KiB"):
        cts = [mgr.encrypt_for_tenant(KUSARI_HASH, blob) for _ in range(n)]
        assert all(mgr.decrypt_for_tenant(KUSARI_HASH, c) == blob for c in cts)
    row = stage_metrics.rows[-1]
    assert len(set(cts)) == n
    # Budgets are ~20x the measured cost on the reference box; they catch a
    # pathological regression (e.g. re-deriving keys per call), not jitter.
    assert row["duration_ms"] < 5000, row
    assert row["peak_heap_kib"] < 64 * 1024, row
    mgr.teardown_tenant_boundary(KUSARI_HASH)
    assert transit._keys == {}


def test_suite_leaves_no_global_tenant_state_behind() -> None:
    """The fixtures swap the global manager; the real one must be untouched."""
    real = tenant_isolation.GLOBAL_TENANT_ISOLATION_MANAGER
    assert not any(n.startswith("slet-concurrency-") or n.startswith("slet-async-")
                   for n in [c.company_name for c in real.list_active_boundaries()])


# ══════════════════════════════════════════════════════════════════════════════
# Tier 2 — live kind-osramp cluster (SLET_LIVE_CLUSTER=1)
# ══════════════════════════════════════════════════════════════════════════════
LIVE = os.environ.get("SLET_LIVE_CLUSTER") == "1"
KCTX = os.environ.get("SLET_KUBE_CONTEXT", "kind-osramp")
SPIRE_NS = os.environ.get("SLET_SPIRE_NAMESPACE", "inf-bao")
BAO_NS = os.environ.get("SLET_BAO_NAMESPACE", "inf-bao")
PROBE_IMAGE = os.environ.get("SLET_PROBE_IMAGE", "busybox:1.36")
SPIRE_BIN = "/opt/spire/bin/spire-server"

live = pytest.mark.skipif(
    not LIVE,
    reason="tier 2 needs SLET_LIVE_CLUSTER=1, kubectl context and BAO_TOKEN "
           "(run scripts/eap/run_slet_p4_2_acceptance.sh)",
)


def kubectl(*args: str, stdin: Optional[str] = None, check: bool = True,
            timeout: int = 90) -> subprocess.CompletedProcess:
    cmd = ["kubectl", "--context", KCTX, *args]
    proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=timeout)
    if check and proc.returncode != 0:
        raise AssertionError(f"{' '.join(cmd)} -> rc={proc.returncode}\n{proc.stderr.strip()}")
    return proc


def spire(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return kubectl("-n", SPIRE_NS, "exec", "deploy/spire-server", "-c", "spire-server", "--",
                   SPIRE_BIN, *args, check=check)


def restricted_pod(name: str, ns: str, labels: Dict[str, str], command: str) -> Dict[str, Any]:
    """A pod that satisfies PSS 'restricted' and the tenant ResourceQuota."""
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "namespace": ns, "labels": labels},
        "spec": {
            "automountServiceAccountToken": False,
            "securityContext": {"runAsNonRoot": True, "runAsUser": 65534, "runAsGroup": 65534,
                                "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [{
                "name": "probe", "image": PROBE_IMAGE, "imagePullPolicy": "IfNotPresent",
                "command": ["sh", "-c", command],
                "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                                    "capabilities": {"drop": ["ALL"]}},
                "resources": {"requests": {"cpu": "10m", "memory": "16Mi"},
                              "limits": {"cpu": "100m", "memory": "32Mi"}},
                "volumeMounts": [{"name": "www", "mountPath": "/www"}],
            }],
            "volumes": [{"name": "www", "emptyDir": {}}],
            "terminationGracePeriodSeconds": 0,
        },
    }


# 8080 is the designated tenant port; 9090 is a second listener that exists
# only so a denial can be attributed to the tenant's own ingress rule.
HTTPD = "echo ok > /www/index.html && httpd -p 9090 -h /www && exec httpd -f -p 8080 -h /www"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class LiveRun:
    """Owns every live artefact this run creates, and removes all of them."""

    def __init__(self, transcript: Transcript) -> None:
        self.run_id = uuid.uuid4().hex[:12]
        self.transcript = transcript
        self.namespaces: List[str] = []
        self.pods: List[tuple] = []
        self.spire_entries: List[str] = []
        self.transit_keys: List[str] = []
        self.mounted_transit = False
        self.port_forward: Optional[subprocess.Popen] = None
        self.bao = None

    def log(self, stage: str, kind: str, **payload: Any) -> None:
        self.transcript.record(f"live-{stage}", kind, run_id=self.run_id, **payload)

    def cleanup(self) -> Dict[str, Any]:
        report: Dict[str, Any] = {}
        for kname in self.transit_keys:
            with contextlib.suppress(Exception):
                if self.bao and self.bao.key_exists(kname):
                    self.bao.shred_key(kname)
        if self.bao and self.mounted_transit:
            with contextlib.suppress(Exception):
                keys = self.bao._client.request("LIST", "/v1/transit/keys")
                if keys.status_code == 404:
                    self.bao._client.delete("/v1/sys/mounts/transit")
                    report["transit_unmounted"] = True
        for entry_id in self.spire_entries:
            spire("entry", "delete", "-entryID", entry_id, check=False)
        for ns in self.namespaces:
            owner = kubectl("get", "ns", ns, "-o", "jsonpath={.metadata.labels.signalloom\\.io/slet-run-id}",
                            check=False)
            if owner.returncode == 0 and owner.stdout.strip() == self.run_id:
                kubectl("delete", "ns", ns, "--wait=true", "--timeout=120s", check=False, timeout=150)
        for ns, name in self.pods:
            kubectl("-n", ns, "delete", "pod", name, "--ignore-not-found", "--wait=true", check=False)
        if self.bao:
            self.bao.close()
        if self.port_forward:
            self.port_forward.terminate()
            with contextlib.suppress(Exception):
                self.port_forward.wait(timeout=5)
        return report


@pytest.fixture
def live_run(transcript: Transcript) -> Iterator[LiveRun]:
    if shutil.which("kubectl") is None:
        pytest.fail("SLET_LIVE_CLUSTER=1 but kubectl is not on PATH")
    run = LiveRun(transcript)
    try:
        yield run
    finally:
        run.log("cleanup", "report", **run.cleanup())


def wait_ready(ns: str, name: str) -> str:
    kubectl("-n", ns, "wait", "--for=condition=Ready", f"pod/{name}", "--timeout=90s", timeout=120)
    return kubectl("-n", ns, "get", "pod", name, "-o", "jsonpath={.status.podIP}").stdout.strip()


def probe_http(ns: str, pod: str, url: str, attempts: int = 1, wait: float = 0.0) -> bool:
    ok = False
    for i in range(attempts):
        proc = kubectl("-n", ns, "exec", pod, "--", "wget", "-q", "-T", "3", "-O-", url, check=False, timeout=30)
        ok = proc.returncode == 0 and proc.stdout.strip() == "ok"
        if ok:
            return True
        if i + 1 < attempts:
            time.sleep(wait)
    return ok


@live
def test_live_kusari_journey_on_kind_cluster(live_run: LiveRun, stage_metrics: StageMetrics,
                                             monkeypatch: pytest.MonkeyPatch) -> None:
    from tenant_transit import OpenBaoTransitBackend

    run = live_run
    peer_hash = derive_customer_hash(PEER)
    peer_ns = get_tenant_namespace(peer_hash)

    # Preflight: never adopt or clobber a boundary another run owns.
    for ns in (KUSARI_NS, peer_ns):
        existing = kubectl("get", "ns", ns, "-o", "json", check=False)
        assert existing.returncode != 0, (
            f"namespace {ns} already exists (owner labels: "
            f"{json.loads(existing.stdout)['metadata'].get('labels', {})}); refusing to adopt it"
        )

    # Stage L1 — provision namespaces from the engine's own manifests.
    with stage_metrics.measure("live-1-namespaces"):
        for name, h in ((KUSARI, KUSARI_HASH), (PEER, peer_hash)):
            ns_manifest = generate_namespace_manifest(name, h)
            ns_manifest["metadata"]["labels"]["signalloom.io/slet-run-id"] = run.run_id
            kubectl("create", "-f", "-", stdin=json.dumps(ns_manifest))
            run.namespaces.append(get_tenant_namespace(h))
        served = json.loads(kubectl("get", "ns", KUSARI_NS, "-o", "json").stdout)
        check_namespace_pss_restricted(
            {"apiVersion": "v1", "kind": "Namespace", "metadata": served["metadata"]}, KUSARI_HASH, KUSARI)
        run.log("1-namespaces", "api-server-readback", labels=served["metadata"]["labels"])

    # Stage L2 — the API server's PSA admission actually enforces 'restricted'.
    with stage_metrics.measure("live-2-psa"):
        compliant = restricted_pod("psa-compliant", KUSARI_NS, {"app": "psa"}, "sleep 1")
        ok = kubectl("create", "--dry-run=server", "-f", "-", stdin=json.dumps(compliant), check=False)
        assert ok.returncode == 0, f"positive control rejected: {ok.stderr}"
        privileged = copy.deepcopy(compliant)
        privileged["metadata"]["name"] = "psa-privileged"
        c = privileged["spec"]["containers"][0]
        c["securityContext"] = {"privileged": True, "runAsUser": 0}
        privileged["spec"]["securityContext"] = {}
        denied = kubectl("create", "--dry-run=server", "-f", "-", stdin=json.dumps(privileged), check=False)
        assert denied.returncode != 0
        assert 'violates PodSecurity "restricted:latest"' in denied.stderr, denied.stderr
        run.log("2-psa", "admission", compliant_rc=ok.returncode, privileged_rc=denied.returncode,
                privileged_stderr=denied.stderr.strip())

    # Stage L3 — Cilium enforces the tenant NetworkPolicy between real pods.
    with stage_metrics.measure("live-3-netpol"):
        for h in (KUSARI_HASH, peer_hash):
            for m in (generate_network_policy_manifest(h), generate_resource_quota_manifest(h)):
                kubectl("apply", "-f", "-", stdin=json.dumps(m))
        pods = {
            "kusari": ("kusari-srv", KUSARI_NS),
            "peer": ("peer-srv", peer_ns),
            "ingress": (f"slet-ingress-probe-{run.run_id}", "ingress"),
        }
        for key, (name, ns) in pods.items():
            labels = {"app": "tenant-app", "signalloom.io/slet-run-id": run.run_id}
            kubectl("apply", "-f", "-", stdin=json.dumps(restricted_pod(name, ns, labels, HTTPD)))
            if ns == "ingress":
                run.pods.append((ns, name))
        ips = {key: wait_ready(ns, name) for key, (name, ns) in pods.items()}
        k_name, _ = pods["kusari"]
        p_name, _ = pods["peer"]
        i_name, _ = pods["ingress"]
        flows = {
            # positive controls first: the server is up and the allow path works
            "ingress->kusari:8080 (allow)": probe_http("ingress", i_name, f"http://{ips['kusari']}:8080/", 10, 2),
            "kusari->kube-dns (allow)": kubectl("-n", KUSARI_NS, "exec", k_name, "--", "nslookup",
                                                "kubernetes.default.svc.cluster.local", check=False).returncode == 0,
            # The tenant policy permits this (see check_traversal_matrix), but
            # inf-bao runs its own default-deny that does not admit eap-*
            # namespaces, so the destination refuses it. Tenants never call
            # OpenBao directly — SLET's manager encrypts on their behalf — so
            # the refusal is the enforced (and safer) reality.
            "kusari->openbao:8200 (deny: inf-bao default-deny)": kubectl(
                "-n", KUSARI_NS, "exec", k_name, "--", "wget", "-q", "-T", "3", "-O", "/dev/null",
                f"http://openbao.{BAO_NS}.svc.cluster.local:8200/v1/sys/health", check=False).returncode == 0,
            # the isolation claims
            "peer->kusari:8080 (deny)": probe_http(peer_ns, p_name, f"http://{ips['kusari']}:8080/", 3, 1),
            "kusari->peer:8080 (deny)": probe_http(KUSARI_NS, k_name, f"http://{ips['peer']}:8080/", 3, 1),
            "kusari->ingress:8080 (deny egress)": probe_http(KUSARI_NS, k_name, f"http://{ips['ingress']}:8080/", 3, 1),
            # the ingress namespace has no policies, so only kusari's ingress
            # port list can refuse this one
            "ingress->kusari:9090 (deny ingress port)": probe_http("ingress", i_name, f"http://{ips['kusari']}:9090/", 3, 1),
        }
        run.log("3-netpol", "cilium-flows", flows=flows, pod_ips=ips)
        for flow, reached in flows.items():
            assert reached == flow.endswith("(allow)"), f"{flow}: reached={reached}"

    # Stage L4 — SPIRE registration, attestation material, pruning.
    with stage_metrics.measure("live-4-spire"):
        foreign = spire("entry", "create", "-spiffeID", "spiffe://foreign.invalid/ns/eap-attacker/sa/tenant-app",
                        "-parentID", "spiffe://foreign.invalid/spire/agent/k8s-node",
                        "-selector", f"k8s:ns:{KUSARI_NS}", "-selector", "k8s:sa:tenant-app",
                        "-x509SVIDTTL", "3600", "-output", "json", check=False)
        # spire-server reports a per-entry failure in the JSON body and still
        # exits 0, so the exit status proves nothing; read the status code.
        foreign_results = json.loads(foreign.stdout).get("results", []) if foreign.stdout.strip() else []
        for e in foreign_results:
            if e.get("entry", {}).get("id"):
                run.spire_entries.append(e["entry"]["id"])  # cleaned up either way
        run.log("4-spire", "foreign-trust-domain", rc=foreign.returncode,
                stdout=foreign.stdout.strip()[:800], stderr=foreign.stderr.strip()[:800])
        assert foreign_results and all(e["status"]["code"] != 0 for e in foreign_results), (
            "SPIRE accepted an entry outside its trust domain")

        # The server's own trust domain, read from an entry it already holds.
        any_entries = json.loads(spire("entry", "show", "-output", "json").stdout).get("entries") or []
        assert any_entries, "SPIRE server holds no entries to read its trust domain from"
        trust_domain = any_entries[0]["spiffe_id"]["trust_domain"]
        monkeypatch.setenv("SLET_SPIFFE_TRUST_DOMAIN", trust_domain)
        entry = generate_spire_registration_entry(KUSARI_HASH)
        created = spire("entry", "create", "-spiffeID", entry["spiffe_id"], "-parentID", entry["parent_id"],
                        *sum((["-selector", s] for s in entry["selectors"]), []),
                        "-x509SVIDTTL", str(entry["ttl"]), "-output", "json")
        result = json.loads(created.stdout)["results"][0]
        assert result["status"]["code"] == 0, result
        run.spire_entries.append(result["entry"]["id"])
        shown = json.loads(spire("entry", "show", "-spiffeID", entry["spiffe_id"], "-output", "json").stdout)
        entries = shown.get("entries") or []
        assert len(entries) == 1
        e = entries[0]
        assert sorted(f"{s['type']}:{s['value']}" for s in e["selectors"]) == sorted(entry["selectors"])
        assert e["x509_svid_ttl"] == 3600
        run.log("4-spire", "entry", entry=e)

        minted = spire("x509", "mint", "-spiffeID", entry["spiffe_id"], "-ttl", "1h").stdout
        pem_blocks = re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", minted, re.S)
        assert pem_blocks, "x509 mint printed no certificate"
        pem = (pem_blocks[0] + "\n").encode()  # first block is the leaf SVID
        svid = verify_tenant_svid(pem, KUSARI_HASH)
        assert 3600 <= svid["lifetime_seconds"] <= 3610  # 1h + SPIRE's 10s backdate
        # The same verifier with zero skew tolerance must reject it: proves the
        # allowance is what admits SPIRE's backdate, not a loose TTL check.
        if svid["lifetime_seconds"] > 3600:
            with pytest.raises(ValueError, match="exceeds tenant TTL"):
                verify_tenant_svid(pem, KUSARI_HASH, skew_seconds=0)
        with pytest.raises(ValueError):
            verify_tenant_svid(pem, peer_hash)
        run.log("4-spire", "minted-svid", svid=svid)

    # Stage L5 — OpenBao transit through the production backend class.
    with stage_metrics.measure("live-5-transit"):
        assert os.environ.get("BAO_TOKEN"), "BAO_TOKEN not set (the runner script supplies it)"
        port = free_port()
        run.port_forward = subprocess.Popen(
            ["kubectl", "--context", KCTX, "-n", BAO_NS, "port-forward", "svc/openbao", f"{port}:8200"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            with contextlib.suppress(OSError), socket.create_connection(("127.0.0.1", port), timeout=1):
                break
            time.sleep(0.2)
        bao = OpenBaoTransitBackend(addr=f"http://127.0.0.1:{port}")
        run.bao = bao
        mounts = bao._client.get("/v1/sys/mounts").json()
        if "transit/" not in mounts.get("data", mounts):
            r = bao._client.post("/v1/sys/mounts/transit", json={"type": "transit"})
            assert r.status_code in (200, 204), r.text
            run.mounted_transit = True
        mgr = TenantIsolationManager(transit=bao)
        run.transit_keys += [f"eap-{KUSARI_HASH}", f"eap-{peer_hash}"]
        mgr.provision_tenant_boundary(KUSARI)
        mgr.provision_tenant_boundary(PEER)
        key_meta = bao.read_key(f"eap-{KUSARI_HASH}")
        assert key_meta["type"] == "aes256-gcm96"
        assert key_meta["deletion_allowed"] is True
        ct = mgr.encrypt_for_tenant(KUSARI_HASH, PAYLOAD)
        check_ciphertext_shape(ct, len(PAYLOAD))
        assert mgr.decrypt_for_tenant(KUSARI_HASH, ct) == PAYLOAD
        with pytest.raises(TransitDecryptError):
            mgr.decrypt_for_tenant(peer_hash, ct)
        run.log("5-transit", "openbao", key=f"transit/keys/eap-{KUSARI_HASH}",
                key_type=key_meta["type"], deletion_allowed=key_meta["deletion_allowed"],
                ciphertext=ct, mounted_by_run=run.mounted_transit)

    # Stage L6 — teardown: key shredded, entry pruned, namespaces gone.
    with stage_metrics.measure("live-6-teardown"):
        assert mgr.teardown_tenant_boundary(KUSARI_HASH)
        receipt = mgr.get_shred_receipt(KUSARI_HASH)
        assert receipt.material_zeroised is True
        assert bao.read_key(f"eap-{KUSARI_HASH}") is None
        with pytest.raises(TransitKeyNotFound):
            bao.decrypt(f"eap-{KUSARI_HASH}", ct)
        mgr.teardown_tenant_boundary(peer_hash)
        assert bao.read_key(f"eap-{peer_hash}") is None
        for entry_id in list(run.spire_entries):
            spire("entry", "delete", "-entryID", entry_id)
            run.spire_entries.remove(entry_id)
        after = json.loads(spire("entry", "show", "-spiffeID", entry["spiffe_id"], "-output", "json").stdout)
        assert not (after.get("entries") or [])
        kubectl("-n", "ingress", "delete", "pod", i_name, "--wait=true")
        run.pods.clear()
        for ns in list(run.namespaces):
            kubectl("delete", "ns", ns, "--wait=true", "--timeout=120s", timeout=150)
            run.namespaces.remove(ns)
            assert kubectl("get", "ns", ns, check=False).returncode != 0
        run.log("6-teardown", "proof", receipt=receipt.as_dict(), key_readback="404",
                spire_entries_after=0, namespaces_after=[])
