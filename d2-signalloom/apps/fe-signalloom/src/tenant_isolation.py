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
import threading
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field, ConfigDict

from environment_routing import derive_customer_hash

logger = logging.getLogger("signalloom.tenant_isolation")

SPIFFE_TRUST_DOMAIN = "osramp.local"
DEFAULT_TRANSIT_MOUNT = "transit"


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


def get_tenant_spiffe_id(customer_hash: str, service_account: str = "tenant-app") -> str:
    """Format canonical SPIFFE ID for tenant workload attestation."""
    ns = get_tenant_namespace(customer_hash)
    return f"spiffe://{SPIFFE_TRUST_DOMAIN}/ns/{ns}/sa/{service_account}"


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
                    # Allow DNS resolution
                    "to": [
                        {
                            "namespaceSelector": {
                                "matchLabels": {
                                    "kubernetes.io/metadata.name": "kube-system"
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


def generate_spire_registration_entry(customer_hash: str, service_account: str = "tenant-app") -> Dict[str, Any]:
    """Generate SPIRE registration entry payload for tenant workload."""
    ns_name = get_tenant_namespace(customer_hash)
    spiffe_id = get_tenant_spiffe_id(customer_hash, service_account)
    return {
        "spiffe_id": spiffe_id,
        "parent_id": f"spiffe://{SPIFFE_TRUST_DOMAIN}/spire/agent/k8s-node",
        "selectors": [
            f"k8s:ns:{ns_name}",
            f"k8s:sa:{service_account}"
        ],
        "ttl": 3600,
        "admin": False
    }


class TenantIsolationManager:
    """Thread-safe manager for tenant isolation boundaries and cryptographic credentials."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._tenants: Dict[str, TenantIsolationConfig] = {}

    def provision_tenant_boundary(self, company_name: str, customer_hash: Optional[str] = None) -> TenantIsolationConfig:
        """Create and track an active tenant isolation boundary."""
        h = (customer_hash or derive_customer_hash(company_name)).lower()
        with self._lock:
            if h in self._tenants and self._tenants[h].is_active:
                logger.info("Reusing active isolation boundary for hash %s", h)
                return self._tenants[h]

            config = TenantIsolationConfig(
                company_name=company_name,
                customer_hash=h,
                namespace=get_tenant_namespace(h),
                spiffe_id=get_tenant_spiffe_id(h),
                transit_key_path=get_tenant_transit_key_path(h),
                is_active=True
            )
            self._tenants[h] = config
            logger.info("Provisioned isolation boundary: namespace=%s spiffe=%s", config.namespace, config.spiffe_id)
            return config

    def teardown_tenant_boundary(self, customer_hash: str) -> bool:
        """Mark a tenant isolation boundary as terminated."""
        h = customer_hash.lower()
        with self._lock:
            if h in self._tenants:
                self._tenants[h].is_active = False
                logger.info("Torn down isolation boundary for hash %s", h)
                return True
            return False

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
from fastapi import APIRouter, FastAPI, HTTPException, status

router = APIRouter(prefix="/api/v1/eap/tenants", tags=["eap-tenant-isolation"])


class TenantProvisionRequest(BaseModel):
    """Payload for provisioning a tenant isolation boundary."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")
    company_name: str = Field(..., min_length=1, max_length=64, description="Customer company name")
    customer_hash: Optional[str] = Field(default=None, min_length=8, max_length=8, description="Optional custom or precomputed hash")


@router.post("", response_model=TenantIsolationConfig, status_code=status.HTTP_201_CREATED)
async def api_provision_tenant(req: TenantProvisionRequest) -> TenantIsolationConfig:
    """Provision a tenant isolation boundary."""
    return GLOBAL_TENANT_ISOLATION_MANAGER.provision_tenant_boundary(
        company_name=req.company_name,
        customer_hash=req.customer_hash
    )


@router.get("", response_model=List[TenantIsolationConfig])
async def api_list_tenants() -> List[TenantIsolationConfig]:
    """List all active tenant boundaries."""
    return GLOBAL_TENANT_ISOLATION_MANAGER.list_active_boundaries()


@router.get("/{customer_hash}", response_model=TenantIsolationConfig)
async def api_get_tenant(customer_hash: str) -> TenantIsolationConfig:
    """Retrieve tenant boundary configuration by customer hash."""
    config = GLOBAL_TENANT_ISOLATION_MANAGER.get_tenant_boundary(customer_hash)
    if not config:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Tenant boundary not found for customer hash '{customer_hash}'."
        )
    return config


@router.delete("/{customer_hash}")
async def api_teardown_tenant(customer_hash: str) -> Dict[str, Any]:
    """Teardown a tenant boundary by customer hash."""
    success = GLOBAL_TENANT_ISOLATION_MANAGER.teardown_tenant_boundary(customer_hash)
    if not success:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Tenant boundary not found for customer hash '{customer_hash}'."
        )
    return {"status": "torn_down", "customer_hash": customer_hash.lower()}


@router.get("/{customer_hash}/manifests")
async def api_get_tenant_manifests(customer_hash: str) -> Dict[str, Any]:
    """Retrieve Kubernetes manifests for tenant isolation boundary."""
    config = GLOBAL_TENANT_ISOLATION_MANAGER.get_tenant_boundary(customer_hash)
    company = config.company_name if config else "kurasi"
    h = customer_hash.lower()
    return {
        "namespace": generate_namespace_manifest(company, h),
        "network_policy": generate_network_policy_manifest(h),
        "resource_quota": generate_resource_quota_manifest(h),
    }


@router.get("/{customer_hash}/spire-entry")
async def api_get_tenant_spire_entry(customer_hash: str) -> Dict[str, Any]:
    """Retrieve SPIRE workload attestation entry for tenant."""
    return generate_spire_registration_entry(customer_hash.lower())


def install_tenant_isolation_api(app: FastAPI) -> None:
    """Mount tenant isolation API routes into the FastAPI application."""
    app.include_router(router)
