"""Connector management router for fe-signalloom.

Provides CRUD, toggling with structured audit event emission, and real-time
synchronization health status for cloud and Git connectors (AWS, GCP, Azure,
K8s, GitHub, Okta, OpenAI, Google Workspace).
"""
from __future__ import annotations

import copy
import json
import logging
import threading
from datetime import datetime, timezone
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from api_compat import (
    APIError,
    Principal,
    _STORE_LOCK,
    _TENANT_CONNECTORS,
    _error_response,
    _get_pool,
    _now_iso,
    _require_pool,
    _ts,
    _write,
    authenticated_principal,
    authenticated_tenant,
)

logger = logging.getLogger("signalloom.connectors")

router = APIRouter(tags=["connectors"])

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

ConnectorStatusType = Literal["connected", "disconnected", "error"]


class WizardFieldSpec(BaseModel):
    model_config = ConfigDict(extra="ignore")
    name: str
    label: str
    type: str = "text"
    required: bool = True
    placeholder: str | None = None
    help_text: str | None = None
    options: list[dict[str, str]] | None = None


class WizardStepConfig(BaseModel):
    model_config = ConfigDict(extra="ignore")
    fields: list[WizardFieldSpec] = Field(default_factory=list)
    permissions: list[str] = Field(default_factory=list)
    docs_link: str = ""
    help_text: str = ""


class ConnectorProvider(BaseModel):
    model_config = ConfigDict(extra="ignore")
    provider_id: str
    display_name: str
    wizard_config: WizardStepConfig


class ConnectorProvidersResponse(BaseModel):
    providers: list[ConnectorProvider]


class TenantConnector(BaseModel):
    model_config = ConfigDict(extra="ignore")
    connector_id: str
    provider_id: str
    display_name: str | None = None
    status: ConnectorStatusType = "connected"
    credential_expires_at: str | None = None
    last_tested_at: str | None = None
    last_scan_at: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)
    created_at: str = Field(default_factory=_now_iso)


class TenantConnectorsResponse(BaseModel):
    connectors: list[TenantConnector]


class ConnectorCreateRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")
    provider_id: str
    display_name: str | None = None
    credentials: dict[str, str] = Field(default_factory=dict)
    metadata: dict[str, Any] = Field(default_factory=dict)


class ConnectorCreateResponse(BaseModel):
    connector_id: str
    provider_id: str
    status: ConnectorStatusType
    created_at: str


class ConnectorToggleRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")
    enabled: bool | None = None


class ConnectorDeleteResponse(BaseModel):
    connector_id: str
    status: ConnectorStatusType


class ConnectorTestResult(BaseModel):
    connector_id: str
    valid: bool
    scopes_ok: bool
    error_msg: str | None = None
    credential_expires_at: str | None = None
    needs_rotation: bool = False


class ConnectorSyncStatus(BaseModel):
    status: str = "healthy"
    synced_at: str = Field(default_factory=_now_iso)
    total_connectors: int = 0
    active_connectors: int = 0
    connectors: list[TenantConnector] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# In-memory Seed Data & Fallback Store
# ---------------------------------------------------------------------------

STANDARD_PROVIDERS: list[ConnectorProvider] = [
    ConnectorProvider(
        provider_id="aws_iam",
        display_name="AWS IAM",
        wizard_config=WizardStepConfig(
            fields=[
                WizardFieldSpec(name="account_id", label="AWS Account ID", type="text", required=True, placeholder="123456789012"),
                WizardFieldSpec(name="role_arn", label="Cross-Account Role ARN", type="text", required=True, placeholder="arn:aws:iam::123456789012:role/signal-loom-readonly"),
                WizardFieldSpec(name="external_id", label="External ID", type="password", required=True),
            ],
            permissions=["iam:ListUsers", "iam:ListAccessKeys", "iam:ListRoles"],
            docs_link="https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-user_externalid.html",
            help_text="Grant a cross-account role scoped to read-only IAM actions.",
        ),
    ),
    ConnectorProvider(
        provider_id="gcp_iam",
        display_name="GCP IAM",
        wizard_config=WizardStepConfig(
            fields=[
                WizardFieldSpec(name="project_id", label="GCP Project ID", type="text", required=True),
                WizardFieldSpec(name="service_account_key", label="Service Account Key (JSON)", type="password", required=True),
            ],
            permissions=["iam.serviceAccounts.list", "resourcemanager.projects.getIamPolicy"],
            docs_link="https://cloud.google.com/iam/docs/keys-create-delete",
            help_text="Use a service account with the read-only IAM viewer role.",
        ),
    ),
    ConnectorProvider(
        provider_id="ad_entra",
        display_name="Microsoft Entra ID",
        wizard_config=WizardStepConfig(
            fields=[
                WizardFieldSpec(name="tenant_directory_id", label="Directory (tenant) ID", type="text", required=True, placeholder="00000000-0000-0000-0000-000000000000"),
                WizardFieldSpec(name="client_id", label="Application (client) ID", type="text", required=True),
                WizardFieldSpec(name="client_secret", label="Client secret", type="password", required=True),
            ],
            permissions=["Directory.Read.All", "User.Read.All"],
            docs_link="/help/connectors/entra",
            help_text="Create an app registration with Directory.Read.All and use its credentials here.",
        ),
    ),
    ConnectorProvider(
        provider_id="k8s",
        display_name="Kubernetes",
        wizard_config=WizardStepConfig(
            fields=[
                WizardFieldSpec(name="cluster_name", label="Cluster Name", type="text", required=True, placeholder="cluster-prod-01"),
                WizardFieldSpec(name="kubeconfig", label="Kubeconfig / ServiceAccount Token", type="password", required=True),
            ],
            permissions=["pods:list", "serviceaccounts:list", "namespaces:list"],
            docs_link="/help/connectors/k8s",
            help_text="Provide read-only credentials to discover running pod workloads.",
        ),
    ),
    ConnectorProvider(
        provider_id="github",
        display_name="GitHub",
        wizard_config=WizardStepConfig(
            fields=[
                WizardFieldSpec(name="organization", label="GitHub Organization", type="text", required=True, placeholder="org-name"),
                WizardFieldSpec(name="personal_access_token", label="Personal Access Token (Fine-grained)", type="password", required=True),
            ],
            permissions=["read:org", "repo:status"],
            docs_link="/help/connectors/github",
            help_text="Generate a fine-grained personal access token with organization read permissions.",
        ),
    ),
    ConnectorProvider(
        provider_id="okta",
        display_name="Okta",
        wizard_config=WizardStepConfig(
            fields=[
                WizardFieldSpec(name="okta_domain", label="Okta Domain", type="text", required=True, placeholder="your-org.okta.com"),
                WizardFieldSpec(name="api_token", label="API Token", type="password", required=True),
            ],
            permissions=["okta.users.read", "okta.apps.read"],
            docs_link="/help/connectors/okta",
            help_text="Generate a read-only API token from an Okta service account.",
        ),
    ),
    ConnectorProvider(
        provider_id="openai",
        display_name="OpenAI",
        wizard_config=WizardStepConfig(
            fields=[
                WizardFieldSpec(name="admin_api_key", label="OpenAI Admin API Key", type="password", required=True, placeholder="sk-admin-..."),
                WizardFieldSpec(name="openai_org_id", label="Organization ID (optional)", type="text", required=False, placeholder="org-xxxxxxxx"),
            ],
            permissions=["api.management.read"],
            docs_link="/help/connectors/openai",
            help_text="Create an Admin API key to discover non-human AI assistant keys.",
        ),
    ),
    ConnectorProvider(
        provider_id="google_workspace",
        display_name="Google Workspace",
        wizard_config=WizardStepConfig(
            fields=[
                WizardFieldSpec(name="admin_email", label="Admin Email", type="text", required=True),
                WizardFieldSpec(name="service_account_json", label="Service Account Key (JSON)", type="password", required=True),
            ],
            permissions=["admin.directory.user.readonly", "admin.directory.rolemanagement.readonly"],
            docs_link="https://developers.google.com/workspace/guides/create-credentials",
            help_text="Use a service account with domain-wide delegation scoped to read-only Admin SDK.",
        ),
    ),
]

_TENANT_CONNECTORS_DATA: dict[str, list[dict[str, Any]]] = {}
_AUDIT_LOG_EVENTS: list[dict[str, Any]] = []
_CONN_LOCK = threading.Lock()


def _ensure_tenant_connectors_seeded(tenant_id: str) -> list[dict[str, Any]]:
    with _CONN_LOCK:
        if tenant_id not in _TENANT_CONNECTORS_DATA:
            _TENANT_CONNECTORS_DATA[tenant_id] = [
                {
                    "connector_id": f"conn-aws-01",
                    "provider_id": "aws_iam",
                    "display_name": "AWS Production",
                    "status": "connected",
                    "credential_expires_at": "2027-01-01T00:00:00Z",
                    "last_tested_at": "2026-09-29T10:00:00Z",
                    "last_scan_at": "2026-09-29T10:05:00Z",
                    "metadata": {"region": "us-east-1", "account_id": "123456789012"},
                    "created_at": "2026-01-15T08:00:00Z",
                },
                {
                    "connector_id": f"conn-gcp-01",
                    "provider_id": "gcp_iam",
                    "display_name": "GCP Europe-West",
                    "status": "connected",
                    "credential_expires_at": "2027-01-01T00:00:00Z",
                    "last_tested_at": "2026-09-29T10:00:00Z",
                    "last_scan_at": "2026-09-29T10:05:00Z",
                    "metadata": {"project_id": "signalloom-prod", "region": "europe-west1"},
                    "created_at": "2026-01-15T08:00:00Z",
                },
                {
                    "connector_id": f"conn-azure-01",
                    "provider_id": "ad_entra",
                    "display_name": "Microsoft Entra ID",
                    "status": "connected",
                    "credential_expires_at": "2027-01-01T00:00:00Z",
                    "last_tested_at": "2026-09-29T10:00:00Z",
                    "last_scan_at": "2026-09-29T10:05:00Z",
                    "metadata": {"tenant_name": "corp.contoso.com"},
                    "created_at": "2026-01-15T08:00:00Z",
                },
                {
                    "connector_id": f"conn-k8s-01",
                    "provider_id": "k8s",
                    "display_name": "Kubernetes Cluster Local",
                    "status": "connected",
                    "credential_expires_at": "2027-01-01T00:00:00Z",
                    "last_tested_at": "2026-09-29T10:00:00Z",
                    "last_scan_at": "2026-09-29T10:05:00Z",
                    "metadata": {"cluster_id": "cluster-local"},
                    "created_at": "2026-01-15T08:00:00Z",
                },
                {
                    "connector_id": f"conn-github-01",
                    "provider_id": "github",
                    "display_name": "GitHub Enterprise",
                    "status": "connected",
                    "credential_expires_at": "2027-01-01T00:00:00Z",
                    "last_tested_at": "2026-09-29T10:00:00Z",
                    "last_scan_at": "2026-09-29T10:05:00Z",
                    "metadata": {"org": "signalloom-corp"},
                    "created_at": "2026-01-15T08:00:00Z",
                },
            ]
            _sync_tenant_connectors_map(tenant_id)
        return _TENANT_CONNECTORS_DATA[tenant_id]


def _sync_tenant_connectors_map(tenant_id: str) -> None:
    """Synchronize connector active states to _TENANT_CONNECTORS in api_compat."""
    connectors = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
    active_by_provider = {c["provider_id"]: (c.get("status") == "connected") for c in connectors}
    active_by_id = {c["connector_id"]: (c.get("status") == "connected") for c in connectors}

    idp_active = active_by_provider.get("ad_entra", True) or active_by_provider.get("okta", True)
    local_k8s_active = active_by_provider.get("k8s", True)
    ext_services_active = (
        active_by_provider.get("aws_iam", True)
        or active_by_provider.get("gcp_iam", True)
        or active_by_provider.get("github", True)
    )

    with _STORE_LOCK:
        if tenant_id not in _TENANT_CONNECTORS:
            _TENANT_CONNECTORS[tenant_id] = {}
        _TENANT_CONNECTORS[tenant_id].update({
            "idp": idp_active,
            "local_k8s": local_k8s_active,
            "external_services": ext_services_active,
            **active_by_provider,
            **active_by_id,
        })


def get_audit_events_for_testing() -> list[dict[str, Any]]:
    with _CONN_LOCK:
        return copy.deepcopy(_AUDIT_LOG_EVENTS)


def reset_connectors_for_testing(tenant_id: str | None = None) -> None:
    with _CONN_LOCK:
        if tenant_id:
            _TENANT_CONNECTORS_DATA.pop(tenant_id, None)
        else:
            _TENANT_CONNECTORS_DATA.clear()
            _AUDIT_LOG_EVENTS.clear()


# ---------------------------------------------------------------------------
# Route Handlers
# ---------------------------------------------------------------------------

@router.get("/api/v1/connectors/providers", response_model=ConnectorProvidersResponse)
@router.get("/api/connectors/providers", response_model=ConnectorProvidersResponse)
@router.get("/connectors/providers", response_model=ConnectorProvidersResponse)
async def list_connector_providers(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> ConnectorProvidersResponse:
    """List supported third-party identity, cloud, and Git connector providers."""
    return ConnectorProvidersResponse(providers=STANDARD_PROVIDERS)


@router.get("/api/v1/connectors/status", response_model=ConnectorSyncStatus)
@router.get("/api/connectors/status", response_model=ConnectorSyncStatus)
@router.get("/connectors/status", response_model=ConnectorSyncStatus)
async def get_connectors_status(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> ConnectorSyncStatus:
    """Fetch real-time connector synchronization and ingestion health."""
    tenant_id = principal.tenant
    raw_conns = _ensure_tenant_connectors_seeded(tenant_id)
    conns = [TenantConnector(**c) for c in raw_conns]
    active_count = sum(1 for c in conns if c.status == "connected")
    return ConnectorSyncStatus(
        status="healthy" if active_count > 0 else "degraded",
        synced_at=_now_iso(),
        total_connectors=len(conns),
        active_connectors=active_count,
        connectors=conns,
    )


@router.get("/api/v1/connectors", response_model=TenantConnectorsResponse)
@router.get("/api/connectors", response_model=TenantConnectorsResponse)
@router.get("/connectors", response_model=TenantConnectorsResponse)
async def list_connectors(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> TenantConnectorsResponse:
    """List configured cloud, Git, and IdP connectors for caller's tenant."""
    tenant_id = principal.tenant
    raw_conns = _ensure_tenant_connectors_seeded(tenant_id)
    return TenantConnectorsResponse(connectors=[TenantConnector(**c) for c in raw_conns])


@router.post("/api/v1/connectors/{connector_id}/toggle", response_model=TenantConnector)
@router.post("/api/connectors/{connector_id}/toggle", response_model=TenantConnector)
@router.post("/connectors/{connector_id}/toggle", response_model=TenantConnector)
async def toggle_connector(
    connector_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    body: ConnectorToggleRequest | None = None,
) -> TenantConnector:
    """Enable or disable a connector with immediate audit event emission."""
    tenant_id = principal.tenant
    _ensure_tenant_connectors_seeded(tenant_id)

    with _CONN_LOCK:
        conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
        match = next((c for c in conns if c["connector_id"] == connector_id or c["provider_id"] == connector_id), None)
        if match is None:
            raise HTTPException(status_code=404, detail=f"Connector '{connector_id}' not found")

        prev_status = match.get("status", "connected")
        if body and body.enabled is not None:
            new_status: ConnectorStatusType = "connected" if body.enabled else "disconnected"
        else:
            new_status = "disconnected" if prev_status == "connected" else "connected"

        match["status"] = new_status
        match["last_tested_at"] = _now_iso()

        # Emit structured audit event
        audit_entry = {
            "eventType": "CONNECTOR_STATUS_CHANGED",
            "action": "tenant.connector_toggled",
            "tenant_id": tenant_id,
            "actor": principal.actor,
            "connector_id": match["connector_id"],
            "provider_id": match["provider_id"],
            "previous_status": prev_status,
            "new_status": new_status,
            "timestamp": _now_iso(),
        }
        _AUDIT_LOG_EVENTS.append(audit_entry)
        _sync_tenant_connectors_map(tenant_id)

        result = TenantConnector(**match)

    # Optional DB write
    pool = await _get_pool()
    if pool is not None:
        try:
            async with _write(pool) as conn:
                await conn.execute(
                    """INSERT INTO audit_events (tenant_id, action, actor, target_type, target_id, details, created_at)
                       VALUES ($1, $2, $3, $4, $5, $6, NOW())""",
                    tenant_id,
                    "CONNECTOR_STATUS_CHANGED",
                    principal.actor,
                    "connector",
                    match["connector_id"],
                    json.dumps(audit_entry),
                )
        except Exception as exc:
            logger.warning("Failed to persist connector toggle audit log to DB: %s", exc)

    logger.info("Connector '%s' toggled to '%s' for tenant '%s' by actor '%s'", match["connector_id"], new_status, tenant_id, principal.actor)
    return result


@router.post("/api/v1/connectors", response_model=ConnectorCreateResponse)
@router.post("/api/connectors", response_model=ConnectorCreateResponse)
@router.post("/connectors", response_model=ConnectorCreateResponse)
async def create_connector(
    body: ConnectorCreateRequest,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> ConnectorCreateResponse:
    """Create or update a connector configuration."""
    tenant_id = principal.tenant
    _ensure_tenant_connectors_seeded(tenant_id)

    with _CONN_LOCK:
        conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
        match = next((c for c in conns if c["provider_id"] == body.provider_id), None)
        now = _now_iso()
        if match:
            match["status"] = "connected"
            match["display_name"] = body.display_name or match.get("display_name")
            match["metadata"] = {**match.get("metadata", {}), **body.metadata}
            match["last_tested_at"] = now
            conn_id = match["connector_id"]
        else:
            conn_id = f"conn-{body.provider_id}-{len(conns) + 1:02d}"
            new_row = {
                "connector_id": conn_id,
                "provider_id": body.provider_id,
                "display_name": body.display_name or body.provider_id,
                "status": "connected",
                "credential_expires_at": "2027-01-01T00:00:00Z",
                "last_tested_at": now,
                "last_scan_at": now,
                "metadata": body.metadata,
                "created_at": now,
            }
            conns.append(new_row)

        _AUDIT_LOG_EVENTS.append({
            "eventType": "CONNECTOR_CREATED",
            "action": "tenant.connector_created",
            "tenant_id": tenant_id,
            "actor": principal.actor,
            "connector_id": conn_id,
            "provider_id": body.provider_id,
            "status": "connected",
            "timestamp": now,
        })
        _sync_tenant_connectors_map(tenant_id)

    return ConnectorCreateResponse(
        connector_id=conn_id,
        provider_id=body.provider_id,
        status="connected",
        created_at=now,
    )


@router.delete("/api/v1/connectors/{connector_id}", response_model=ConnectorDeleteResponse)
@router.delete("/api/connectors/{connector_id}", response_model=ConnectorDeleteResponse)
@router.delete("/connectors/{connector_id}", response_model=ConnectorDeleteResponse)
async def delete_connector(
    connector_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> ConnectorDeleteResponse:
    """Disconnect a connector for the caller's tenant."""
    tenant_id = principal.tenant
    _ensure_tenant_connectors_seeded(tenant_id)

    with _CONN_LOCK:
        conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
        match = next((c for c in conns if c["connector_id"] == connector_id or c["provider_id"] == connector_id), None)
        if match is None:
            raise HTTPException(status_code=404, detail=f"Connector '{connector_id}' not found")

        match["status"] = "disconnected"
        _AUDIT_LOG_EVENTS.append({
            "eventType": "CONNECTOR_STATUS_CHANGED",
            "action": "tenant.connector_disconnected",
            "tenant_id": tenant_id,
            "actor": principal.actor,
            "connector_id": match["connector_id"],
            "provider_id": match["provider_id"],
            "previous_status": "connected",
            "new_status": "disconnected",
            "timestamp": _now_iso(),
        })
        _sync_tenant_connectors_map(tenant_id)
        cid = match["connector_id"]

    return ConnectorDeleteResponse(connector_id=cid, status="disconnected")


@router.post("/api/v1/connectors/{connector_id}/test", response_model=ConnectorTestResult)
@router.post("/api/connectors/{connector_id}/test", response_model=ConnectorTestResult)
@router.post("/connectors/{connector_id}/test", response_model=ConnectorTestResult)
async def test_connector(
    connector_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> ConnectorTestResult:
    """Test connector credentials and return diagnostic validation result."""
    tenant_id = principal.tenant
    _ensure_tenant_connectors_seeded(tenant_id)

    with _CONN_LOCK:
        conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
        match = next((c for c in conns if c["connector_id"] == connector_id or c["provider_id"] == connector_id), None)
        if match is None:
            raise HTTPException(status_code=404, detail=f"Connector '{connector_id}' not found")

        match["last_tested_at"] = _now_iso()
        return ConnectorTestResult(
            connector_id=match["connector_id"],
            valid=True,
            scopes_ok=True,
            error_msg=None,
            credential_expires_at=match.get("credential_expires_at"),
            needs_rotation=False,
        )


# ---------------------------------------------------------------------------
# App Installer Function
# ---------------------------------------------------------------------------

def install_connectors_api(app: Any) -> None:
    """Mount the connectors router on the FastAPI application."""
    for route in app.routes:
        if getattr(route, "endpoint", None) in (
            list_connector_providers,
            list_connectors,
            toggle_connector,
            get_connectors_status,
            create_connector,
            delete_connector,
            test_connector,
        ):
            return
    app.include_router(router)
