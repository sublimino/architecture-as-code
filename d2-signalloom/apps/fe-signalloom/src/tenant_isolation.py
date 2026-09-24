# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tenant_isolation.py
# Signal Loom EAP Tenant Isolation & Cryptographic Identity Engine (SLET)
#
# Provides deterministic namespace scoping, Pod Security Admission (restricted)
# manifest generation, default-deny NetworkPolicy templates, SPIFFE workload
# identity bindings, and OpenBao Transit key leasing for on-demand EAP tenants.
# ==============================================================================
from __future__ import annotations

import logging
import os
import threading
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field, ConfigDict

from environment_routing import derive_customer_hash
from tenant_transit import (
    InMemoryTransitBackend,
    ShredReceipt,
    TransitBackend,
    TransitDecryptError,
    TransitKeyNotFound,
)

logger = logging.getLogger("signalloom.tenant_isolation")

SPIFFE_TRUST_DOMAIN = "osramp.local"
DEFAULT_TRANSIT_MOUNT = "transit"
TENANT_SERVICE_ACCOUNT = "tenant-app"
SVID_TTL_SECONDS = 3600
# SPIRE backdates NotBefore by 10s to absorb clock skew, so a 1h SVID really
# spans 3610s. Anything beyond that is a TTL violation.
SVID_CLOCK_SKEW_SECONDS = 10


def get_spiffe_trust_domain() -> str:
    """Trust domain for tenant SPIFFE IDs.

    Defaults to the proposal's ``osramp.local``. Overridable through
    ``SLET_SPIFFE_TRUST_DOMAIN`` because a real SPIRE server only registers and
    mints IDs in its own trust domain (the kind-osramp cluster runs
    ``signalloom.demo``). Read per call so tests cannot leak it between cases.
    """
    return os.environ.get("SLET_SPIFFE_TRUST_DOMAIN", SPIFFE_TRUST_DOMAIN)


class TenantIsolationConfig(BaseModel):
    """Configuration model for an isolated EAP tenant boundary."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    company_name: str = Field(..., min_length=1, max_length=64, description="Customer organization name")
    customer_hash: str = Field(..., min_length=8, max_length=8, description="Salted 8-char hex customer hash")
    namespace: str = Field(..., description="Target Kubernetes namespace")
    spiffe_id: str = Field(..., description="Canonical SPIFFE ID for tenant workloads")
    transit_key_path: str = Field(..., description="OpenBao transit engine key path")
    is_active: bool = Field(default=True, description="Isolation boundary lifecycle state")


def get_tenant_namespace(customer_hash: str) -> str:
    """Format canonical Kubernetes namespace name for tenant."""
    return f"eap-{customer_hash.lower()}"


def get_tenant_spiffe_id(customer_hash: str, service_account: str = TENANT_SERVICE_ACCOUNT) -> str:
    """Format canonical SPIFFE ID for tenant workload attestation."""
    ns = get_tenant_namespace(customer_hash)
    return f"spiffe://{get_spiffe_trust_domain()}/ns/{ns}/sa/{service_account}"


def get_tenant_transit_key_name(customer_hash: str) -> str:
    """Name of the tenant's key inside the transit mount."""
    return f"eap-{customer_hash.lower()}"


def get_tenant_transit_key_path(customer_hash: str) -> str:
    """Format canonical OpenBao transit key engine path."""
    return f"{DEFAULT_TRANSIT_MOUNT}/keys/eap-{customer_hash.lower()}"


def generate_namespace_manifest(company_name: str, customer_hash: Optional[str] = None) -> Dict[str, Any]:
    """Generate Kubernetes Namespace manifest with Pod Security Standards (restricted)."""
    h = customer_hash or derive_customer_hash(company_name)
    ns_name = get_tenant_namespace(h)
    return {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": ns_name,
            "labels": {
                "app.kubernetes.io/managed-by": "signalloom-eap",
                "signalloom.io/eap-hash": h,
                "signalloom.io/customer": company_name.lower().strip(),
                "pod-security.kubernetes.io/enforce": "restricted",
                "pod-security.kubernetes.io/enforce-version": "latest",
                "pod-security.kubernetes.io/audit": "restricted",
                "pod-security.kubernetes.io/warn": "restricted",
            }
        }
    }


def generate_network_policy_manifest(customer_hash: str) -> Dict[str, Any]:
    """Generate default-deny Ingress/Egress NetworkPolicy manifest for tenant."""
    ns_name = get_tenant_namespace(customer_hash)
    return {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "NetworkPolicy",
        "metadata": {
            "name": "eap-default-deny-and-isolation",
            "namespace": ns_name,
            "labels": {
                "app.kubernetes.io/managed-by": "signalloom-eap",
                "signalloom.io/eap-hash": customer_hash,
            }
        },
        "spec": {
            "podSelector": {},
            "policyTypes": ["Ingress", "Egress"],
            "ingress": [
                {
                    "from": [
                        {
                            "namespaceSelector": {
                                "matchLabels": {
                                    "kubernetes.io/metadata.name": "ingress"
                                }
                            }
                        },
                        {
                            "namespaceSelector": {
                                "matchLabels": {
                                    "kubernetes.io/metadata.name": "fe-signalloom"
                                }
                            }
                        }
                    ],
                    "ports": [
                        {"protocol": "TCP", "port": 8080}
                    ]
                }
            ],
            "egress": [
                {
                    # Allow DNS resolution — kube-dns pods only. namespaceSelector
                    # and podSelector in ONE peer are ANDed; without the
                    # podSelector every kube-system pod would be reachable on 53.
                    "to": [
                        {
                            "namespaceSelector": {
                                "matchLabels": {
                                    "kubernetes.io/metadata.name": "kube-system"
                                }
                            },
                            "podSelector": {
                                "matchLabels": {
                                    "k8s-app": "kube-dns"
                                }
                            }
                        }
                    ],
                    "ports": [
                        {"protocol": "UDP", "port": 53},
                        {"protocol": "TCP", "port": 53}
                    ]
                },
                {
                    # Allow communication to SPIRE agent and OpenBao server
                    "to": [
                        {
                            "namespaceSelector": {
                                "matchLabels": {
                                    "kubernetes.io/metadata.name": "inf-spire"
                                }
                            }
                        },
                        {
                            "namespaceSelector": {
                                "matchLabels": {
                                    "kubernetes.io/metadata.name": "inf-bao"
                                }
                            }
                        }
                    ],
                    "ports": [
                        {"protocol": "TCP", "port": 8200}
                    ]
                }
            ]
        }
    }


def generate_resource_quota_manifest(customer_hash: str) -> Dict[str, Any]:
    """Generate ResourceQuota manifest constraining tenant resource consumption."""
    ns_name = get_tenant_namespace(customer_hash)
    return {
        "apiVersion": "v1",
        "kind": "ResourceQuota",
        "metadata": {
            "name": "eap-tenant-quota",
            "namespace": ns_name,
            "labels": {
                "app.kubernetes.io/managed-by": "signalloom-eap",
                "signalloom.io/eap-hash": customer_hash,
            }
        },
        "spec": {
            "hard": {
                "requests.cpu": "2",
                "requests.memory": "4Gi",
                "limits.cpu": "4",
                "limits.memory": "8Gi",
                "pods": "10",
                "services": "5",
                "persistentvolumeclaims": "2"
            }
        }
    }


def generate_spire_registration_entry(customer_hash: str, service_account: str = TENANT_SERVICE_ACCOUNT) -> Dict[str, Any]:
    """Generate SPIRE registration entry payload for tenant workload."""
    ns_name = get_tenant_namespace(customer_hash)
    spiffe_id = get_tenant_spiffe_id(customer_hash, service_account)
    return {
        "spiffe_id": spiffe_id,
        "parent_id": f"spiffe://{get_spiffe_trust_domain()}/spire/agent/k8s-node",
        "selectors": [
            f"k8s:ns:{ns_name}",
            f"k8s:sa:{service_account}"
        ],
        "ttl": SVID_TTL_SECONDS,
        "admin": False
    }


class CrossTenantAccessDenied(Exception):
    """A caller identity addressed a tenant boundary it does not belong to."""


def authorize_tenant_access(caller_spiffe_id: Optional[str], customer_hash: str) -> None:
    """Allow only the tenant's own workload identity to act on its boundary.

    Exact match against the canonical SPIFFE ID — never a prefix or substring,
    so ``eap-6f82ad81`` cannot be reached by ``eap-6f82ad810`` or by any other
    service account in the same namespace.
    """
    expected = get_tenant_spiffe_id(customer_hash)
    if not caller_spiffe_id or caller_spiffe_id != expected:
        raise CrossTenantAccessDenied(
            f"caller {caller_spiffe_id!r} is not the workload identity for {get_tenant_namespace(customer_hash)}"
        )


def verify_tenant_svid(
    cert_pem: bytes,
    customer_hash: str,
    max_ttl_seconds: int = SVID_TTL_SECONDS,
    skew_seconds: int = SVID_CLOCK_SKEW_SECONDS,
) -> Dict[str, Any]:
    """Check an X.509-SVID belongs to exactly this tenant.

    Returns the parsed facts on success; raises ``ValueError`` naming the first
    violated property. An SVID must carry exactly one URI SAN (SPIFFE X.509-SVID
    spec section 2), that URI must be the tenant's canonical ID, it must not be
    a CA, and its validity window must not exceed the tenant SVID TTL.
    """
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    from cryptography.x509.oid import ExtensionOID

    cert = x509.load_pem_x509_certificate(cert_pem)
    try:
        san = cert.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME).value
    except x509.ExtensionNotFound as exc:
        raise ValueError("SVID has no subjectAltName") from exc
    uris = san.get_values_for_type(x509.UniformResourceIdentifier)
    if len(uris) != 1:
        raise ValueError(f"SVID must carry exactly one URI SAN, found {len(uris)}")
    expected = get_tenant_spiffe_id(customer_hash)
    if uris[0] != expected:
        raise ValueError(f"SVID URI SAN {uris[0]!r} != tenant identity {expected!r}")
    try:
        bc = cert.extensions.get_extension_for_oid(ExtensionOID.BASIC_CONSTRAINTS).value
        if bc.ca:
            raise ValueError("SVID is a CA certificate")
    except x509.ExtensionNotFound:
        pass
    lifetime = (cert.not_valid_after_utc - cert.not_valid_before_utc).total_seconds()
    if lifetime > max_ttl_seconds + skew_seconds:
        raise ValueError(
            f"SVID lifetime {lifetime:.0f}s exceeds tenant TTL {max_ttl_seconds}s (+{skew_seconds}s skew)"
        )
    return {
        "spiffe_id": uris[0],
        "serial_number": format(cert.serial_number, "x"),
        "not_before": cert.not_valid_before_utc.isoformat(),
        "not_after": cert.not_valid_after_utc.isoformat(),
        "lifetime_seconds": int(lifetime),
        "fingerprint_sha256": cert.fingerprint(hashes.SHA256()).hex(),
    }


class TenantIsolationManager:
    """Thread-safe manager for tenant isolation boundaries and cryptographic credentials."""

    def __init__(self, transit: Optional[TransitBackend] = None) -> None:
        self._lock = threading.RLock()
        self._tenants: Dict[str, TenantIsolationConfig] = {}
        self.transit: TransitBackend = transit if transit is not None else InMemoryTransitBackend()
        self._shred_receipts: Dict[str, ShredReceipt] = {}

    def provision_tenant_boundary(self, company_name: str, customer_hash: Optional[str] = None) -> TenantIsolationConfig:
        """Create and track an active tenant isolation boundary.

        Leases the tenant's transit key first. If anything after key creation
        fails, the half-created key is shredded before the error propagates, so
        a transient fault never leaves an orphaned key or a phantom boundary.
        """
        h = (customer_hash or derive_customer_hash(company_name)).lower()
        with self._lock:
            if h in self._tenants and self._tenants[h].is_active:
                logger.info("Reusing active isolation boundary for hash %s", h)
                return self._tenants[h]

            key_name = get_tenant_transit_key_name(h)
            try:
                self.transit.create_key(key_name)
                config = TenantIsolationConfig(
                    company_name=company_name,
                    customer_hash=h,
                    namespace=get_tenant_namespace(h),
                    spiffe_id=get_tenant_spiffe_id(h),
                    transit_key_path=get_tenant_transit_key_path(h),
                    is_active=True
                )
            except Exception:
                self._rollback_key(key_name)
                raise
            self._tenants[h] = config
            self._shred_receipts.pop(h, None)
            logger.info("Provisioned isolation boundary: namespace=%s spiffe=%s", config.namespace, config.spiffe_id)
            return config

    def _rollback_key(self, key_name: str) -> None:
        """Best-effort removal of a key left behind by a failed provision."""
        try:
            if self.transit.key_exists(key_name):
                self.transit.shred_key(key_name)
                logger.warning("Rolled back transit key %s after failed provision", key_name)
        except Exception:  # pragma: no cover - logged, original error re-raised by caller
            logger.exception("Rollback of transit key %s failed; key may be orphaned", key_name)

    def teardown_tenant_boundary(self, customer_hash: str) -> bool:
        """Terminate a tenant boundary and permanently shred its transit key."""
        h = customer_hash.lower()
        with self._lock:
            if h not in self._tenants:
                return False
            config = self._tenants[h]
            if config.is_active:
                key_name = get_tenant_transit_key_name(h)
                if self.transit.key_exists(key_name):
                    self._shred_receipts[h] = self.transit.shred_key(key_name)
                config.is_active = False
                logger.info("Torn down isolation boundary for hash %s", h)
            return True

    def get_shred_receipt(self, customer_hash: str) -> Optional[ShredReceipt]:
        """Receipt for the most recent key shred of this tenant, if any."""
        with self._lock:
            return self._shred_receipts.get(customer_hash.lower())

    def _active_key_name(self, customer_hash: str) -> str:
        h = customer_hash.lower()
        config = self._tenants.get(h)
        if config is None or not config.is_active:
            raise TransitKeyNotFound(get_tenant_transit_key_path(h))
        return get_tenant_transit_key_name(h)

    def encrypt_for_tenant(self, customer_hash: str, plaintext: bytes) -> str:
        """Encrypt with the tenant's transit key (active boundaries only)."""
        with self._lock:
            key_name = self._active_key_name(customer_hash)
        return self.transit.encrypt(key_name, plaintext)

    def decrypt_for_tenant(self, customer_hash: str, ciphertext: str) -> bytes:
        """Decrypt with the tenant's transit key (active boundaries only)."""
        with self._lock:
            key_name = self._active_key_name(customer_hash)
        return self.transit.decrypt(key_name, ciphertext)

    def get_tenant_boundary(self, customer_hash: str) -> Optional[TenantIsolationConfig]:
        """Retrieve isolation boundary metadata if present."""
        h = customer_hash.lower()
        with self._lock:
            return self._tenants.get(h)

    def list_active_boundaries(self) -> List[TenantIsolationConfig]:
        """List all currently active isolation boundaries."""
        with self._lock:
            return [t for t in self._tenants.values() if t.is_active]


GLOBAL_TENANT_ISOLATION_MANAGER = TenantIsolationManager()


# ==============================================================================
# FastAPI Routing & Endpoints
# ==============================================================================
import base64
import binascii

from fastapi import APIRouter, Depends, FastAPI, HTTPException, status

import api_compat
from eap_tenancy import (
    CUSTOMER_HASH_PATTERN,
    TENANT_KEY_RE,  # noqa: F401 — re-exported: tenant_isolation owns the tenant model
    CustomerHash,
    Tenant,
    claim_or_403,
    owned_hashes,
    require_owned_or_404,
)

router = APIRouter(prefix="/api/v1/eap/tenants", tags=["eap-tenant-isolation"])


class TenantProvisionRequest(BaseModel):
    """Payload for provisioning a tenant isolation boundary."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    company_name: str = Field(..., min_length=1, max_length=64, description="Customer company name")
    customer_hash: Optional[str] = Field(
        default=None, pattern=CUSTOMER_HASH_PATTERN, description="Optional custom or precomputed 8-char hex hash"
    )


@router.post("", response_model=TenantIsolationConfig, status_code=status.HTTP_201_CREATED)
async def api_provision_tenant(req: TenantProvisionRequest, tenant: Tenant) -> TenantIsolationConfig:
    """Provision a tenant isolation boundary, bound to the caller's tenant."""
    customer_hash = claim_or_403(req.customer_hash or derive_customer_hash(req.company_name), tenant)
    return GLOBAL_TENANT_ISOLATION_MANAGER.provision_tenant_boundary(
        company_name=req.company_name,
        customer_hash=customer_hash,
    )


@router.get("", response_model=List[TenantIsolationConfig])
async def api_list_tenants(tenant: Tenant) -> List[TenantIsolationConfig]:
    """List the caller's active tenant boundaries."""
    mine = owned_hashes(tenant)
    return [b for b in GLOBAL_TENANT_ISOLATION_MANAGER.list_active_boundaries() if b.customer_hash in mine]


@router.get("/{customer_hash}", response_model=TenantIsolationConfig)
async def api_get_tenant(customer_hash: CustomerHash, tenant: Tenant) -> TenantIsolationConfig:
    """Retrieve tenant boundary configuration by customer hash."""
    require_owned_or_404(customer_hash, tenant)
    config = GLOBAL_TENANT_ISOLATION_MANAGER.get_tenant_boundary(customer_hash)
    if not config:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Tenant boundary not found for customer hash '{customer_hash}'."
        )
    return config


@router.delete("/{customer_hash}")
async def api_teardown_tenant(customer_hash: CustomerHash, tenant: Tenant) -> Dict[str, Any]:
    """Teardown a tenant boundary by customer hash and shred its transit key."""
    require_owned_or_404(customer_hash, tenant)
    success = GLOBAL_TENANT_ISOLATION_MANAGER.teardown_tenant_boundary(customer_hash)
    if not success:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Tenant boundary not found for customer hash '{customer_hash}'."
        )
    receipt = GLOBAL_TENANT_ISOLATION_MANAGER.get_shred_receipt(customer_hash)
    return {
        "status": "torn_down",
        "customer_hash": customer_hash.lower(),
        "key_shred": receipt.as_dict() if receipt else None,
    }


class TransitEncryptRequest(BaseModel):
    """Plaintext to seal with the tenant's transit key (base64)."""
    model_config = ConfigDict(extra="forbid")
    plaintext: str = Field(..., description="Base64-encoded plaintext")


class TransitDecryptRequest(BaseModel):
    """Ciphertext produced by this tenant's transit key."""
    model_config = ConfigDict(extra="forbid")
    ciphertext: str = Field(..., description="vault:v1: ciphertext")


# EAPR-P2-1: the transit routes authorise by ``tenant == owner(customer_hash)``,
# where the tenant comes from the verified principal.  No identity header is
# read here or anywhere else in the EAP routers; main.py strips them at ingress.


@router.post("/{customer_hash}/transit/encrypt")
async def api_tenant_encrypt(
    customer_hash: CustomerHash,
    req: TransitEncryptRequest,
    tenant: Tenant,
) -> Dict[str, Any]:
    """Encrypt with the tenant's own transit key; another tenant's key is not found."""
    require_owned_or_404(customer_hash, tenant)
    try:
        plaintext = base64.b64decode(req.plaintext, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="plaintext is not base64") from exc
    try:
        ciphertext = GLOBAL_TENANT_ISOLATION_MANAGER.encrypt_for_tenant(customer_hash, plaintext)
    except TransitKeyNotFound as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"no active transit key: {exc}") from exc
    return {"key_path": get_tenant_transit_key_path(customer_hash), "ciphertext": ciphertext}


@router.post("/{customer_hash}/transit/decrypt")
async def api_tenant_decrypt(
    customer_hash: CustomerHash,
    req: TransitDecryptRequest,
    tenant: Tenant,
) -> Dict[str, Any]:
    """Decrypt with the tenant's own transit key; another tenant's key is not found."""
    require_owned_or_404(customer_hash, tenant)
    try:
        plaintext = GLOBAL_TENANT_ISOLATION_MANAGER.decrypt_for_tenant(customer_hash, req.ciphertext)
    except TransitKeyNotFound as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"no active transit key: {exc}") from exc
    except TransitDecryptError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return {"plaintext": base64.b64encode(plaintext).decode("ascii")}


@router.get("/{customer_hash}/manifests")
async def api_get_tenant_manifests(customer_hash: CustomerHash, tenant: Tenant) -> Dict[str, Any]:
    """Retrieve Kubernetes manifests for tenant isolation boundary."""
    require_owned_or_404(customer_hash, tenant)
    config = GLOBAL_TENANT_ISOLATION_MANAGER.get_tenant_boundary(customer_hash)
    if not config:
        # Never synthesise a boundary: labelling an unknown hash with some
        # other customer's name is a tenant-identity misattribution.
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Tenant boundary not found for customer hash '{customer_hash}'."
        )
    company = config.company_name
    h = customer_hash.lower()
    return {
        "namespace": generate_namespace_manifest(company, h),
        "network_policy": generate_network_policy_manifest(h),
        "resource_quota": generate_resource_quota_manifest(h),
    }


@router.get("/{customer_hash}/spire-entry")
async def api_get_tenant_spire_entry(customer_hash: CustomerHash, tenant: Tenant) -> Dict[str, Any]:
    """Retrieve SPIRE workload attestation entry for tenant."""
    require_owned_or_404(customer_hash, tenant)
    return generate_spire_registration_entry(customer_hash.lower())


def install_tenant_isolation_api(app: FastAPI) -> None:
    """Mount tenant isolation API routes into the FastAPI application.

    The authentication dependency is attached at the mount (EAPR-P2-1, SP-5) so a
    route added to this router is denied by default rather than opt-in.
    """
    app.include_router(router, dependencies=[Depends(api_compat.authenticated_principal)])
