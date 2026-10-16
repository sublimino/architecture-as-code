"""Connector management router for fe-signalloom.

Provides CRUD, toggling with structured audit event emission, and real-time
synchronization health status for cloud and Git connectors (AWS, GCP, Azure,
K8s, GitHub, Okta, OpenAI, Google Workspace).
"""
from __future__ import annotations

import copy
import json
import logging
import os
import threading
import time
import uuid
from datetime import datetime, timezone
from typing import Annotated, Any, Literal

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

import api_compat
import connector_credentials
import remote_agent_sync
import superadmin
from api_compat import (
    APIError,
    Principal,
    _STORE_LOCK,
    _TENANT_CONNECTORS,
    _audit_outbound_request,
    _now_iso,
    _write,
    authenticated_principal,
    update_claude_agent_name,
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
    # Time of the last fully successful scan. A failed or partial scan leaves it
    # alone and records its outcome in last_scan_status / last_scan_error.
    last_scan_at: str | None = None
    last_scan_status: Literal["success", "warning", "error"] | None = None
    last_scan_error: str | None = None
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
    credential_expires_at: str | None = None


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
    model_config = ConfigDict(extra="ignore")
    # None when testing supplied credentials that belong to no stored connector.
    connector_id: str | None
    valid: bool
    scopes_ok: bool
    error_msg: str | None = None
    credential_expires_at: str | None = None
    needs_rotation: bool = False
    message: str | None = None
    # Machine-readable reason for a failed verdict, e.g. ``workspace_required``.
    error_code: str | None = None


class ConnectorTestRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")
    credentials: dict[str, str] = Field(default_factory=dict)



class ConnectorSyncStatus(BaseModel):
    status: str = "healthy"
    synced_at: str = Field(default_factory=_now_iso)
    total_connectors: int = 0
    active_connectors: int = 0
    connectors: list[TenantConnector] = Field(default_factory=list)


class SyncLogEntry(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: str
    timestamp: str = Field(default_factory=_now_iso)
    level: Literal["info", "warn", "error", "debug"] = "info"
    message: str
    endpoint: str | None = None
    status_code: int | None = None
    duration_ms: int | None = None
    details: dict[str, Any] | None = None


class RecordsScanned(BaseModel):
    """Counts observed by one scan. ``None`` means not observed, never zero-as-placeholder."""
    model_config = ConfigDict(extra="ignore")
    agents: int | None = None
    sessions: int | None = None
    models: int | None = None
    environments: int | None = None
    tools: int | None = None


class PoliciesEvaluated(BaseModel):
    model_config = ConfigDict(extra="ignore")
    egress_rules: int = 0
    violations: int = 0


class SyncResult(BaseModel):
    """One scan's outcome. Nothing here defaults to an observation: duration and
    status are measured per scan, and ``policies_evaluated`` is ``None`` unless
    policies were actually evaluated."""
    model_config = ConfigDict(extra="ignore")
    provider_id: str
    synced_at: str = Field(default_factory=_now_iso)
    duration_ms: int
    status: Literal["success", "warning", "error"]
    records_scanned: RecordsScanned
    policies_evaluated: PoliciesEvaluated | None
    logs: list[SyncLogEntry] = Field(default_factory=list)


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
        provider_id="claude",
        display_name="Anthropic Claude",
        wizard_config=WizardStepConfig(
            fields=[
                WizardFieldSpec(name="api_key", label="Anthropic API Key", type="password", required=True, placeholder="sk-ant-..."),
                # Optional in the schema because a workspace-scoped key needs none, but an
                # organisation-scoped key is refused by every endpoint without it.
                WizardFieldSpec(name="workspace_id", label="Workspace ID (required for organisation-scoped keys)", type="text",
                                required=False, placeholder="wrkspc_xxxxxxxxxxxx",
                                help_text="Required when the key is organisation-scoped (not tied to one workspace): Anthropic refuses "
                                          "every request from such a key unless it names the workspace. Find it in Console → Settings → Workspaces. "
                                          "Sent as the anthropic-workspace-id header on every call."),
                WizardFieldSpec(name="admin_api_key", label="Admin API Key (optional)", type="password", required=False, placeholder="sk-ant-admin..."),
            ],
            permissions=["models:read", "batches:read"],
            docs_link="/help/connectors/claude",
            help_text="Provide a read-only Anthropic API key to discover models, batches, and agent telemetry.",
        ),
    ),
    ConnectorProvider(
        provider_id="openai",
        display_name="OpenAI",
        wizard_config=WizardStepConfig(
            fields=[
                # Field name stays ``api_key``; the value must be an org Admin key
                # because the verifier calls the Admin API. Credentials stored
                # under the older ``admin_api_key`` name are still read.
                WizardFieldSpec(name="api_key", label="OpenAI Admin API Key", type="password", required=True, placeholder="sk-admin-...",
                                help_text="An org Admin key from Organization > Admin keys. A project API key cannot read the Admin API."),
                WizardFieldSpec(name="openai_org_id", label="Organization ID (optional)", type="text", required=False, placeholder="org-xxxxxxxx"),
            ],
            permissions=["api.management.read"],
            docs_link="/help/connectors/openai",
            help_text="Create an org Admin API key (sk-admin-...) to discover non-human AI assistant keys.",
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
_TENANT_SYNC_RESULTS: dict[str, dict[str, SyncResult]] = {}
_TENANT_CONNECTOR_CREDENTIALS: dict[str, dict[str, dict[str, str]]] = {}
_CONN_LOCK = threading.Lock()



def _ensure_tenant_connectors_seeded(tenant_id: str) -> list[dict[str, Any]]:
    """Fixture mode only (no database): the demo tenant's connectors.

    A deployment with a database never calls this; its tenants have exactly the
    connectors they configured, read from ``public.tenant_connectors``.
    """
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
                {
                    "connector_id": f"conn-claude-01",
                    "provider_id": "claude",
                    "display_name": "Anthropic Claude",
                    "status": "connected",
                    "credential_expires_at": "2027-01-01T00:00:00Z",
                    "last_tested_at": "2026-09-29T10:00:00Z",
                    "last_scan_at": "2026-09-29T10:05:00Z",
                    "metadata": {"workspace_id": "wrkspc_signalloom_demo"},
                    "created_at": "2026-01-15T08:00:00Z",
                },
                {
                    "connector_id": f"conn-openai-01",
                    "provider_id": "openai",
                    "display_name": "OpenAI Production",
                    "status": "connected",
                    "credential_expires_at": "2027-01-01T00:00:00Z",
                    "last_tested_at": "2026-09-29T10:00:00Z",
                    "last_scan_at": "2026-09-29T10:05:00Z",
                    "metadata": {"openai_org_id": "org-signalloom"},
                    "created_at": "2026-01-15T08:00:00Z",
                },
            ]
            _sync_tenant_connectors_map(tenant_id)
        return _TENANT_CONNECTORS_DATA[tenant_id]


def _sync_tenant_connectors_map(tenant_id: str, connectors: list[dict[str, Any]] | None = None) -> None:
    """Synchronize connector active states to _TENANT_CONNECTORS in api_compat.

    ``connectors`` is the tenant's full list; fixture mode omits it and the
    in-memory list is used.
    """
    if connectors is None:
        connectors = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
    active_by_provider = {c["provider_id"]: (c.get("status") == "connected") for c in connectors}
    active_by_id = {c["connector_id"]: (c.get("status") == "connected") for c in connectors}

    idp_active = active_by_provider.get("ad_entra", True) or active_by_provider.get("okta", True)
    local_k8s_active = active_by_provider.get("k8s", True)
    ext_services_active = (
        active_by_provider.get("aws_iam", True)
        or active_by_provider.get("gcp_iam", True)
        or active_by_provider.get("github", True)
        or active_by_provider.get("claude", False)
        or active_by_provider.get("openai", False)
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
            _TENANT_SYNC_RESULTS.pop(tenant_id, None)
            _TENANT_CONNECTOR_CREDENTIALS.pop(tenant_id, None)
        else:
            _TENANT_CONNECTORS_DATA.clear()
            _AUDIT_LOG_EVENTS.clear()
            _TENANT_SYNC_RESULTS.clear()
            _TENANT_CONNECTOR_CREDENTIALS.clear()


# ---------------------------------------------------------------------------
# Live store: public.tenant_connectors (migration 070)
# ---------------------------------------------------------------------------
# With a database, a tenant's connectors, their sealed credentials and the last
# scan result live in Postgres, never in the dicts above: a restart forgets
# nothing, and no tenant is handed connectors it never configured. Every
# statement is scoped by ``tenant_id = $1`` and tagged
# ``/* connector_store:<op> */`` (tests/connector_store_fake.py keys on the tag).
# Credentials are stored only as connector_credentials.seal_credentials output.

_TABLE = "public.tenant_connectors"
_COLS = (
    "connector_id, provider_id, display_name, status, credential_expires_at, last_tested_at, "
    "last_scan_at, last_scan_status, last_scan_error, metadata, created_at"
)
_SQL_LIST = (
    f"/* connector_store:list */ SELECT {_COLS} FROM {_TABLE} "
    "WHERE tenant_id = $1 ORDER BY created_at, connector_id"
)
# A key matches a connector id or a provider id; the connector id wins.
_SQL_GET = (
    f"/* connector_store:get */ SELECT {_COLS}, credentials_ciphertext, last_scan_result FROM {_TABLE} "
    "WHERE tenant_id = $1 AND (connector_id = $2 OR provider_id = $2) "
    "ORDER BY (connector_id = $2) DESC LIMIT 1"
)
_SQL_GET_LOCKED = _SQL_GET + " FOR UPDATE"
_SQL_GET_PROVIDER = (
    f"/* connector_store:get_provider */ SELECT {_COLS}, credentials_ciphertext, last_scan_result FROM {_TABLE} "
    "WHERE tenant_id = $1 AND provider_id = $2 FOR UPDATE"
)
_SQL_COUNT = f"/* connector_store:count */ SELECT count(*) FROM {_TABLE} WHERE tenant_id = $1"
_SQL_INSERT = (
    f"/* connector_store:insert */ INSERT INTO {_TABLE} (tenant_id, connector_id, provider_id, display_name, "
    "status, credential_expires_at, metadata, credentials_ciphertext, created_at, updated_at) "
    "VALUES ($1, $2, $3, $4, 'connected', $5, $6::jsonb, $7, $8, $8)"
)
_SQL_RECONNECT = (
    f"/* connector_store:reconnect */ UPDATE {_TABLE} SET status = 'connected', display_name = $3, "
    "metadata = $4::jsonb, credential_expires_at = $5, "
    "credentials_ciphertext = COALESCE($6, credentials_ciphertext), updated_at = NOW() "
    "WHERE tenant_id = $1 AND connector_id = $2"
)
_SQL_SET_STATUS = (
    f"/* connector_store:set_status */ UPDATE {_TABLE} SET status = $3, updated_at = NOW() "
    f"WHERE tenant_id = $1 AND connector_id = $2 RETURNING {_COLS}"
)
_SQL_DISCONNECT = (
    f"/* connector_store:disconnect */ UPDATE {_TABLE} SET status = 'disconnected', "
    "credentials_ciphertext = NULL, last_scan_result = NULL, updated_at = NOW() "
    "WHERE tenant_id = $1 AND connector_id = $2"
)
_SQL_STAMP_TESTED = (
    f"/* connector_store:stamp_tested */ UPDATE {_TABLE} SET last_tested_at = $3, updated_at = NOW() "
    "WHERE tenant_id = $1 AND connector_id = $2"
)
_SQL_RECORD_SCAN = (
    f"/* connector_store:record_scan */ UPDATE {_TABLE} SET last_scan_at = COALESCE($3, last_scan_at), "
    "last_scan_status = $4, last_scan_error = $5, last_scan_result = $6::jsonb, updated_at = NOW() "
    "WHERE tenant_id = $1 AND connector_id = $2"
)


async def _store_pool(what: str) -> Any:
    """The pool, or None in fixture mode; 503 when a configured database is unreachable.

    A configured-but-down database must not fall back to the demo seeds.
    """
    return await api_compat._require_pool(what)


def _ts_out(value: Any) -> str | None:
    if value is None or isinstance(value, str):
        return value
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _ts_in(value: str | None, field: str) -> datetime | None:
    if value is None:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise APIError(422, "invalid_timestamp", f"{field} is not an ISO-8601 timestamp") from None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _json_in(value: Any) -> Any:
    return json.loads(value) if isinstance(value, str) else value


def _connector_from_row(row: Any) -> dict[str, Any]:
    """The public connector record. Never carries the ciphertext."""
    return {
        "connector_id": row["connector_id"],
        "provider_id": row["provider_id"],
        "display_name": row["display_name"],
        "status": row["status"],
        "credential_expires_at": _ts_out(row["credential_expires_at"]),
        "last_tested_at": _ts_out(row["last_tested_at"]),
        "last_scan_at": _ts_out(row["last_scan_at"]),
        "last_scan_status": row["last_scan_status"],
        "last_scan_error": row["last_scan_error"],
        "metadata": _json_in(row["metadata"]) or {},
        "created_at": _ts_out(row["created_at"]),
    }


def _credential_store_unavailable(exc: Exception) -> APIError:
    return APIError(503, "credential_store_unavailable", f"Connector credentials cannot be stored or read: {exc}")


def _open_stored(tenant_id: str, row: Any) -> dict[str, str]:
    ciphertext = row["credentials_ciphertext"]
    if not ciphertext:
        return {}
    try:
        return connector_credentials.open_credentials(tenant_id, row["connector_id"], ciphertext)
    except (connector_credentials.CredentialStoreUnavailable, connector_credentials.CredentialDecryptError) as exc:
        raise _credential_store_unavailable(exc) from None


async def _live_connectors(pool: Any, tenant_id: str) -> list[dict[str, Any]]:
    connectors = [_connector_from_row(r) for r in await pool.fetch(_SQL_LIST, tenant_id)]
    _sync_tenant_connectors_map(tenant_id, connectors)
    return connectors


async def refresh_live_connector_states(pool: Any, tenant_id: str) -> None:
    """Load the tenant's stored connector states into ``api_compat._TENANT_CONNECTORS``.

    Discovery gates sources on that map; after a restart it is empty until the
    store is read.
    """
    await _live_connectors(pool, tenant_id)


async def _live_create(pool: Any, tenant_id: str, body: ConnectorCreateRequest) -> tuple[str, str]:
    """Insert or reconnect the tenant's connector for ``body.provider_id``. Returns (id, created_at)."""
    credentials = dict(body.credentials)
    if credentials:
        try:
            connector_credentials.require_key()
        except connector_credentials.CredentialStoreUnavailable as exc:
            raise _credential_store_unavailable(exc) from None
    expires = _ts_in(body.credential_expires_at, "credential_expires_at")
    now = datetime.now(timezone.utc).replace(microsecond=0)

    async with _write(pool) as conn:
        existing = await conn.fetchrow(_SQL_GET_PROVIDER, tenant_id, body.provider_id)
        if existing is not None:
            conn_id = existing["connector_id"]
        else:
            conn_id = f"conn-{body.provider_id}-{(await conn.fetchval(_SQL_COUNT, tenant_id)) + 1:02d}"
        ciphertext = None
        if credentials:
            try:
                ciphertext = connector_credentials.seal_credentials(tenant_id, conn_id, credentials)
            except connector_credentials.CredentialStoreUnavailable as exc:
                raise _credential_store_unavailable(exc) from None
        # Saving a connector is not testing or scanning it: no test, scan or
        # expiry timestamp is written unless the caller supplied the expiry.
        if existing is not None:
            metadata = {**(_json_in(existing["metadata"]) or {}), **body.metadata}
            await conn.execute(
                _SQL_RECONNECT, tenant_id, conn_id,
                body.display_name or existing["display_name"], json.dumps(metadata),
                expires if expires is not None else existing["credential_expires_at"], ciphertext,
            )
        else:
            await conn.execute(
                _SQL_INSERT, tenant_id, conn_id, body.provider_id, body.display_name or body.provider_id,
                expires, json.dumps(body.metadata), ciphertext, now,
            )
    return conn_id, _ts_out(now) or _now_iso()


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


async def _tenant_connectors(tenant_id: str, what: str) -> list[dict[str, Any]]:
    pool = await _store_pool(what)
    if pool is None:
        return _ensure_tenant_connectors_seeded(tenant_id)
    return await _live_connectors(pool, tenant_id)


@router.get("/api/v1/connectors/status", response_model=ConnectorSyncStatus)
@router.get("/api/connectors/status", response_model=ConnectorSyncStatus)
@router.get("/connectors/status", response_model=ConnectorSyncStatus)
async def get_connectors_status(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> ConnectorSyncStatus:
    """Fetch real-time connector synchronization and ingestion health."""
    raw_conns = await _tenant_connectors(principal.tenant, "Reading connector status")
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
    raw_conns = await _tenant_connectors(principal.tenant, "Listing connectors")
    return TenantConnectorsResponse(connectors=[TenantConnector(**c) for c in raw_conns])


def _requested_status(prev_status: str, body: ConnectorToggleRequest | None) -> ConnectorStatusType:
    if body and body.enabled is not None:
        return "connected" if body.enabled else "disconnected"
    return "disconnected" if prev_status == "connected" else "connected"


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
    pool = await _store_pool("Toggling a connector")

    # Toggling probes nothing, so it does not touch last_tested_at.
    if pool is None:
        _ensure_tenant_connectors_seeded(tenant_id)
        with _CONN_LOCK:
            conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
            match = next((c for c in conns if c["connector_id"] == connector_id or c["provider_id"] == connector_id), None)
            if match is None:
                raise HTTPException(status_code=404, detail=f"Connector '{connector_id}' not found")
            prev_status = match.get("status", "connected")
            new_status = _requested_status(prev_status, body)
            match["status"] = new_status
            _sync_tenant_connectors_map(tenant_id)
            match = dict(match)
    else:
        async with _write(pool) as conn:
            row = await conn.fetchrow(_SQL_GET_LOCKED, tenant_id, connector_id)
            if row is None:
                raise HTTPException(status_code=404, detail=f"Connector '{connector_id}' not found")
            prev_status = row["status"]
            new_status = _requested_status(prev_status, body)
            match = _connector_from_row(await conn.fetchrow(_SQL_SET_STATUS, tenant_id, row["connector_id"], new_status))
        await _live_connectors(pool, tenant_id)

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
    with _CONN_LOCK:
        _AUDIT_LOG_EVENTS.append(audit_entry)
    result = TenantConnector(**match)

    # Optional DB write
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
    pool = await _store_pool("Saving a connector")

    if pool is not None:
        conn_id, now = await _live_create(pool, tenant_id, body)
        await _live_connectors(pool, tenant_id)
        with _CONN_LOCK:
            _AUDIT_LOG_EVENTS.append(_created_entry(tenant_id, principal, conn_id, body.provider_id, now))
        return ConnectorCreateResponse(connector_id=conn_id, provider_id=body.provider_id, status="connected", created_at=now)

    # Fixture mode (no database): the demo shows demo timestamps and a demo expiry.
    _ensure_tenant_connectors_seeded(tenant_id)
    with _CONN_LOCK:
        conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
        match = next((c for c in conns if c["provider_id"] == body.provider_id), None)
        now = _now_iso()
        if match:
            match["status"] = "connected"
            match["display_name"] = body.display_name or match.get("display_name")
            match["metadata"] = {**match.get("metadata", {}), **body.metadata}
            if body.credential_expires_at is not None:
                match["credential_expires_at"] = body.credential_expires_at
            match["last_tested_at"] = now
            conn_id = match["connector_id"]
        else:
            conn_id = f"conn-{body.provider_id}-{len(conns) + 1:02d}"
            new_row = {
                "connector_id": conn_id,
                "provider_id": body.provider_id,
                "display_name": body.display_name or body.provider_id,
                "status": "connected",
                "credential_expires_at": body.credential_expires_at or "2027-01-01T00:00:00Z",
                "last_tested_at": now,
                "last_scan_at": now,
                "metadata": body.metadata,
                "created_at": now,
            }
            conns.append(new_row)

        if body.credentials:
            if tenant_id not in _TENANT_CONNECTOR_CREDENTIALS:
                _TENANT_CONNECTOR_CREDENTIALS[tenant_id] = {}
            _TENANT_CONNECTOR_CREDENTIALS[tenant_id][conn_id] = dict(body.credentials)
            _TENANT_CONNECTOR_CREDENTIALS[tenant_id][body.provider_id] = dict(body.credentials)

        _AUDIT_LOG_EVENTS.append(_created_entry(tenant_id, principal, conn_id, body.provider_id, now))
        _sync_tenant_connectors_map(tenant_id)

    return ConnectorCreateResponse(
        connector_id=conn_id,
        provider_id=body.provider_id,
        status="connected",
        created_at=now,
    )


def _created_entry(tenant_id: str, principal: Principal, conn_id: str, provider_id: str, now: str) -> dict[str, Any]:
    return {
        "eventType": "CONNECTOR_CREATED",
        "action": "tenant.connector_created",
        "tenant_id": tenant_id,
        "actor": principal.actor,
        "connector_id": conn_id,
        "provider_id": provider_id,
        "status": "connected",
        "timestamp": now,
    }


@router.delete("/api/v1/connectors/{connector_id}", response_model=ConnectorDeleteResponse)
@router.delete("/api/connectors/{connector_id}", response_model=ConnectorDeleteResponse)
@router.delete("/connectors/{connector_id}", response_model=ConnectorDeleteResponse)
async def delete_connector(
    connector_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> ConnectorDeleteResponse:
    """Disconnect a connector for the caller's tenant.

    Disconnecting forgets the tenant's key and what it observed, so a later
    re-enable cannot test or scan with the old credential.
    """
    tenant_id = principal.tenant
    pool = await _store_pool("Disconnecting a connector")

    if pool is None:
        _ensure_tenant_connectors_seeded(tenant_id)
        with _CONN_LOCK:
            conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
            match = next((c for c in conns if c["connector_id"] == connector_id or c["provider_id"] == connector_id), None)
            if match is None:
                raise HTTPException(status_code=404, detail=f"Connector '{connector_id}' not found")
            match["status"] = "disconnected"
            for key in (match["connector_id"], match["provider_id"]):
                _TENANT_CONNECTOR_CREDENTIALS.get(tenant_id, {}).pop(key, None)
                _TENANT_SYNC_RESULTS.get(tenant_id, {}).pop(key, None)
            _sync_tenant_connectors_map(tenant_id)
            cid, provider = match["connector_id"], match["provider_id"]
    else:
        async with _write(pool) as conn:
            row = await conn.fetchrow(_SQL_GET_LOCKED, tenant_id, connector_id)
            if row is None:
                raise HTTPException(status_code=404, detail=f"Connector '{connector_id}' not found")
            cid, provider = row["connector_id"], row["provider_id"]
            await conn.execute(_SQL_DISCONNECT, tenant_id, cid)
        await _live_connectors(pool, tenant_id)

    audit_entry = {
        "eventType": "CONNECTOR_STATUS_CHANGED",
        "action": "tenant.connector_disconnected",
        "tenant_id": tenant_id,
        "actor": principal.actor,
        "connector_id": cid,
        "provider_id": provider,
        "previous_status": "connected",
        "new_status": "disconnected",
        "timestamp": _now_iso(),
    }
    with _CONN_LOCK:
        _AUDIT_LOG_EVENTS.append(audit_entry)

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
                    cid,
                    json.dumps(audit_entry),
                )
        except Exception as exc:
            logger.warning("Failed to persist connector delete audit log to DB: %s", exc)

    return ConnectorDeleteResponse(connector_id=cid, status="disconnected")


ANTHROPIC_API = "https://api.anthropic.com"
OPENAI_API = "https://api.openai.com"
_ANTHROPIC_HEADERS = {"anthropic-version": "2023-06-01", "anthropic-beta": "managed-agents-2026-04-01"}
_UPSTREAM_TIMEOUT = 10.0


def _stored_credentials(tenant_id: str, match: dict[str, Any]) -> dict[str, str]:
    """Credentials this tenant stored for this connector. Never a server env var."""
    with _CONN_LOCK:
        by_tenant = _TENANT_CONNECTOR_CREDENTIALS.get(tenant_id, {})
        return dict(by_tenant.get(match["connector_id"]) or by_tenant.get(match["provider_id"]) or {})


def _supplied_credentials(body: Any) -> dict[str, str]:
    if isinstance(body, dict):
        creds = body.get("credentials") or {}
    else:
        creds = getattr(body, "credentials", None) or {}
    return {str(k): str(v) for k, v in creds.items() if v} if isinstance(creds, dict) else {}


async def _fetch_live_anthropic_telemetry(api_key: str, workspace_id: str | None = None) -> dict[str, Any] | None:
    """Fixture mode only: list agents with the tenant's own key for the demo overlay.

    Returns None unless Anthropic answered 200 with a named agent; it never
    substitutes a placeholder name or id.
    """
    if not api_key:
        return None
    try:
        async with httpx.AsyncClient(timeout=_UPSTREAM_TIMEOUT) as client:
            resp = await client.get(f"{ANTHROPIC_API}/v1/agents", headers=remote_agent_sync.anthropic_headers(api_key, workspace_id))
            if resp.status_code != 200:
                return None
            data = resp.json()
            agents = (data.get("data") or data.get("agents") or []) if isinstance(data, dict) else []
            if isinstance(agents, list) and agents and isinstance(agents[0], dict) and agents[0].get("name"):
                first = agents[0]
                return {"agent_name": first["name"], "agent_id": first.get("id"), "agents": agents, "count": len(agents)}
    except Exception as exc:
        logger.debug("Anthropic agents listing failed: %s", exc)
    return None


async def _probe(url: str, headers: dict[str, str]) -> tuple[int | None, int, str | None, str]:
    """One real GET. Returns (status or None, measured ms, transport error or None, body text)."""
    started = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=_UPSTREAM_TIMEOUT) as client:
            resp = await client.get(url, headers=headers)
        return resp.status_code, int((time.monotonic() - started) * 1000), None, resp.text
    except httpx.HTTPError as exc:
        return None, int((time.monotonic() - started) * 1000), type(exc).__name__, ""


# (valid, scopes_ok, error_msg, message, tested). ``tested`` is True only when
# the upstream answered, i.e. the credential was really put to the provider.
# The sixth element is a machine-readable error code, or None.
Verdict = tuple[bool, bool, str | None, str | None, bool, str | None]


def _probe_verdict(service: str, status: int | None, error: str | None) -> Verdict:
    """A verdict from a real probe outcome only."""
    if status is None:
        return False, False, f"Could not reach the {service} API ({error}); the credential was not tested.", None, False, None
    if status == 200:
        return True, True, None, f"{service} API accepted the credential (HTTP 200).", True, None
    if status == 401:
        return False, False, f"{service} API rejected the credential (HTTP 401).", None, True, None
    if status == 403:
        return True, False, f"{service} API authenticated the credential but refused the required permission (HTTP 403).", None, True, None
    return False, False, f"Unexpected HTTP {status} from the {service} API; the credential was not verified.", None, True, None


async def _verify_claude(creds: dict[str, str]) -> Verdict:
    key = creds.get("api_key")
    if not key:
        return False, False, "No Anthropic API key was supplied or stored; nothing was tested.", None, False, None
    headers = {"x-api-key": key, "anthropic-version": "2023-06-01"}
    if (creds.get("workspace_id") or "").strip():
        headers["anthropic-workspace-id"] = creds["workspace_id"].strip()
    status, _, error, body = await _probe(f"{ANTHROPIC_API}/v1/models", headers)
    if remote_agent_sync.anthropic_workspace_required(status, body):
        # The key authenticated as an organisation key; it is not invalid, it needs a workspace.
        return (False, False, remote_agent_sync.WORKSPACE_REQUIRED_MESSAGE, None, True,
                remote_agent_sync.WORKSPACE_REQUIRED_CODE)
    return _probe_verdict("Anthropic", status, error)


async def _verify_openai(creds: dict[str, str]) -> Verdict:
    # ``admin_api_key`` is the field name credentials were stored under before
    # the wizard field became ``api_key``; both hold an org Admin key.
    key = creds.get("api_key") or creds.get("admin_api_key")
    if not key:
        return False, False, "No OpenAI Admin API key was supplied or stored; nothing was tested.", None, False, None
    status, _, error, _body = await _probe(f"{OPENAI_API}/v1/organization/admin_api_keys", {"Authorization": f"Bearer {key}"})
    return _probe_verdict("OpenAI Admin", status, error)


# Providers with a real credential verifier. Anything else answers 501 rather
# than a verdict nobody measured.
_VERIFIERS = {"claude": _verify_claude, "openai": _verify_openai}


def _stored_state_problem(match: dict[str, Any]) -> tuple[str, bool] | None:
    """(error_msg, needs_rotation) when the stored connector state already fails."""
    status = match.get("status", "connected")
    if status == "disconnected":
        return "Connector is disconnected", False
    if status == "error":
        return "Connector is in error state", False
    expires_at_str = match.get("credential_expires_at")
    if expires_at_str:
        try:
            exp_dt = datetime.fromisoformat(expires_at_str.replace("Z", "+00:00"))
        except Exception:
            return f"Invalid credential expiration timestamp: {expires_at_str}", True
        if exp_dt <= datetime.now(timezone.utc):
            return "Credential has expired", True
    return None


@router.post("/api/v1/connectors/providers/{provider_id}/test", response_model=ConnectorTestResult)
@router.post("/api/connectors/providers/{provider_id}/test", response_model=ConnectorTestResult)
@router.post("/connectors/providers/{provider_id}/test", response_model=ConnectorTestResult)
async def test_supplied_credentials(
    provider_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    body: ConnectorTestRequest | None = None,
) -> ConnectorTestResult:
    """Probe credentials supplied in the body, without storing them anywhere."""
    verifier = _VERIFIERS.get(provider_id)
    if verifier is None:
        raise APIError(501, "test_unsupported", f"No credential verifier exists for provider '{provider_id}'")
    valid, scopes_ok, error_msg, message, _tested, error_code = await verifier(_supplied_credentials(body))
    return ConnectorTestResult(connector_id=None, valid=valid, scopes_ok=scopes_ok, error_msg=error_msg, message=message,
                               error_code=error_code)


@router.post("/api/v1/connectors/{connector_id}/test", response_model=ConnectorTestResult)
@router.post("/api/connectors/{connector_id}/test", response_model=ConnectorTestResult)
@router.post("/connectors/{connector_id}/test", response_model=ConnectorTestResult)
async def test_connector(
    connector_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    body: ConnectorTestRequest | dict[str, Any] | None = None,
) -> ConnectorTestResult:
    """Test a stored connector's credentials (or credentials supplied in the body)."""
    tenant_id = principal.tenant
    pool = await _store_pool("Testing a connector")

    if pool is not None:
        row = await pool.fetchrow(_SQL_GET, tenant_id, connector_id)
        if row is None:
            raise HTTPException(status_code=404, detail=f"Connector '{connector_id}' not found")
        match = _connector_from_row(row)
        expires_at_str = match["credential_expires_at"]
        problem = _stored_state_problem(match)
        if problem is not None:
            return ConnectorTestResult(
                connector_id=match["connector_id"], valid=False, scopes_ok=False, error_msg=problem[0],
                credential_expires_at=expires_at_str, needs_rotation=problem[1],
            )
        verifier = _VERIFIERS.get(match["provider_id"])
        if verifier is None:
            raise APIError(501, "test_unsupported", f"No credential verifier exists for provider '{match['provider_id']}'")
        creds = remote_agent_sync.with_connector_workspace(_supplied_credentials(body) or _open_stored(tenant_id, row), row)
        valid, scopes_ok, error_msg, message, tested, error_code = await verifier(creds)
        if tested:
            # The provider answered: this is when the credential was tested.
            await pool.execute(_SQL_STAMP_TESTED, tenant_id, match["connector_id"], datetime.now(timezone.utc))
        return ConnectorTestResult(
            connector_id=match["connector_id"], valid=valid, scopes_ok=scopes_ok, error_msg=error_msg,
            credential_expires_at=expires_at_str, message=message, error_code=error_code,
        )

    # Fixture mode (no database): the demo path.
    _ensure_tenant_connectors_seeded(tenant_id)
    with _CONN_LOCK:
        conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
        match = next((c for c in conns if c["connector_id"] == connector_id or c["provider_id"] == connector_id), None)
        if match is None:
            raise HTTPException(status_code=404, detail=f"Connector '{connector_id}' not found")
        expires_at_str = match.get("credential_expires_at")
        problem = _stored_state_problem(match)

    if problem is not None:
        return ConnectorTestResult(
            connector_id=match["connector_id"], valid=False, scopes_ok=False, error_msg=problem[0],
            credential_expires_at=expires_at_str, needs_rotation=problem[1],
        )

    creds = remote_agent_sync.with_connector_workspace(
        _supplied_credentials(body) or _stored_credentials(tenant_id, match), match)

    # The stored state passed, so the demo reports it valid.
    test_message = None
    if match.get("provider_id") == "claude":
        live_telemetry = await _fetch_live_anthropic_telemetry(creds.get("api_key", ""), creds.get("workspace_id"))
        if live_telemetry:
            update_claude_agent_name(tenant_id, live_telemetry["agent_name"], live_telemetry.get("agent_id"))
            test_message = f"✓ Verified connection to Anthropic Claude API. Discovered live agent: {live_telemetry['agent_name']}"
        else:
            test_message = "✓ Verified connection to Anthropic Claude API."
    with _CONN_LOCK:
        match["last_tested_at"] = _now_iso()
    return ConnectorTestResult(
        connector_id=match["connector_id"], valid=True, scopes_ok=True,
        credential_expires_at=expires_at_str, message=test_message,
    )


def _generate_sync_result(
    provider_id: str,
    timestamp: str | None = None,
    live_agent_name: str | None = None,
    live_agent_id: str | None = None,
    live_count: int | None = None,
) -> SyncResult:
    """Fixture mode only (no database pool): canned demo results for the dashboard.

    Nothing here was observed. A deployment with a database never calls this.
    """
    now = timestamp or _now_iso()
    if provider_id == "claude":
        agent_name = live_agent_name or "Daily News Jokester"
        agent_id = live_agent_id or "agent_01FoEhnKF9QsC5DGmuELhm7G"
        agent_count = live_count if live_count is not None else 1

        if live_agent_name:
            log3_msg = f"Discovered live agent {agent_name} ({agent_id}) from Anthropic API"
        else:
            log3_msg = f"Discovered agent {agent_name} ({agent_id}) with runtime claude-managed"

        return SyncResult(
            provider_id="claude",
            synced_at=now,
            duration_ms=142,
            status="success",
            records_scanned=RecordsScanned(
                agents=agent_count,
                models=2,
                environments=1,
                tools=4,
            ),
            policies_evaluated=PoliciesEvaluated(
                egress_rules=3,
                violations=0,
            ),
            logs=[
                SyncLogEntry(
                    id="log-1",
                    timestamp=now,
                    level="info",
                    message="Initiating read-only discovery sync for Anthropic Claude environment cloud-dev",
                ),
                SyncLogEntry(
                    id="log-2",
                    timestamp=now,
                    level="debug",
                    message="Queried /v1/environments/env_01CyCigBbDRSLTzSCyyHQ7eT",
                    endpoint="GET /v1/environments/env_01CyCigBbDRSLTzSCyyHQ7eT",
                    status_code=200,
                    duration_ms=84,
                    details={
                        "env_id": "env_01CyCigBbDRSLTzSCyyHQ7eT",
                        "hosting": "Cloud",
                        "network": {
                            "allowed_hosts": [],
                            "package_managers": True,
                            "mcp_servers": True,
                        },
                    },
                ),
                SyncLogEntry(
                    id="log-3",
                    timestamp=now,
                    level="info",
                    message=log3_msg,
                ),
                SyncLogEntry(
                    id="log-4",
                    timestamp=now,
                    level="info",
                    message="CEL Policy Evaluation passed: NET_RAW not held, egress confined, MCP attestation verified",
                ),
            ],
        )
    elif provider_id == "openai":
        return SyncResult(
            provider_id="openai",
            synced_at=now,
            duration_ms=168,
            status="success",
            records_scanned=RecordsScanned(
                agents=2,
                models=3,
                environments=1,
                tools=3,
            ),
            policies_evaluated=PoliciesEvaluated(
                egress_rules=2,
                violations=0,
            ),
            logs=[
                SyncLogEntry(
                    id="log-1",
                    timestamp=now,
                    level="info",
                    message="Connecting to OpenAI API management endpoint...",
                ),
                SyncLogEntry(
                    id="log-2",
                    timestamp=now,
                    level="debug",
                    message="Scanned OpenAI models: gpt-4o, gpt-4o-mini, o1-preview",
                    endpoint="GET /v1/models",
                    status_code=200,
                    duration_ms=110,
                    details={
                        "models": ["gpt-4o", "gpt-4o-mini", "o1-preview"],
                        "organization": "org-signalloom",
                    },
                ),
                SyncLogEntry(
                    id="log-3",
                    timestamp=now,
                    level="debug",
                    message="Discovered assistant definitions and tools",
                    endpoint="GET /v1/assistants",
                    status_code=200,
                    duration_ms=135,
                    details={
                        "assistants_count": 2,
                        "code_interpreter_enabled": True,
                        "file_search_enabled": True,
                    },
                ),
                SyncLogEntry(
                    id="log-4",
                    timestamp=now,
                    level="info",
                    message="CEL network policy evaluation passed with 0 egress violations.",
                ),
            ],
        )
    else:
        return SyncResult(
            provider_id=provider_id,
            synced_at=now,
            duration_ms=120,
            status="success",
            records_scanned=RecordsScanned(
                agents=1,
                models=1,
                environments=1,
                tools=1,
            ),
            policies_evaluated=PoliciesEvaluated(
                egress_rules=1,
                violations=0,
            ),
            logs=[
                SyncLogEntry(
                    id=f"log-{provider_id}-1",
                    timestamp=now,
                    level="info",
                    message=f"Initiating discovery sync with {provider_id} provider...",
                ),
                SyncLogEntry(
                    id=f"log-{provider_id}-2",
                    timestamp=now,
                    level="debug",
                    message=f"Queried resources from {provider_id}",
                    endpoint=f"/api/v1/{provider_id}/resources",
                    status_code=200,
                    duration_ms=120,
                    details={"provider": provider_id, "status": "synced"},
                ),
                SyncLogEntry(
                    id=f"log-{provider_id}-3",
                    timestamp=now,
                    level="info",
                    message=f"Discovery sync completed successfully for {provider_id}.",
                ),
            ],
        )


def _redact_for(principal: Principal, result: SyncResult) -> SyncResult:
    """Wire traces (endpoint, status code, details) are for superadmins only."""
    if superadmin.is_superadmin(principal):
        return result
    return result.model_copy(update={
        "logs": [log.model_copy(update={"endpoint": None, "status_code": None, "details": None}) for log in result.logs],
    })


_KIND_LABEL = {"agent": "agents", "session": "sessions"}


async def _list_anthropic_models(key: str, logs: list[SyncLogEntry], workspace_id: str | None = None) -> int | None:
    """``GET /v1/models`` with the tenant's key: the one listing a scan adds to the sync."""
    url = f"{ANTHROPIC_API}/v1/models"
    started = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=_UPSTREAM_TIMEOUT) as client:
            resp = await client.get(url, headers=remote_agent_sync.anthropic_headers(key, workspace_id))
    except httpx.HTTPError as exc:
        logs.append(SyncLogEntry(
            id=f"log-{len(logs) + 1}", timestamp=_now_iso(), level="error",
            message=f"Listing Anthropic models failed before a response ({type(exc).__name__}).",
            endpoint=f"GET {url}", duration_ms=int((time.monotonic() - started) * 1000),
        ))
        return None
    elapsed = int((time.monotonic() - started) * 1000)
    if remote_agent_sync.anthropic_workspace_required(resp.status_code, resp.text):
        logs.append(SyncLogEntry(
            id=f"log-{len(logs) + 1}", timestamp=_now_iso(), level="error",
            message=remote_agent_sync.WORKSPACE_REQUIRED_MESSAGE, endpoint=f"GET {url}", status_code=400,
            duration_ms=elapsed, details={"error_code": remote_agent_sync.WORKSPACE_REQUIRED_CODE},
        ))
        return None
    items = None
    if resp.status_code == 200:
        try:
            payload = resp.json()
        except ValueError:
            payload = None
        if isinstance(payload, dict) and isinstance(payload.get("data"), list):
            items = payload["data"]
    if items is None:
        logs.append(SyncLogEntry(
            id=f"log-{len(logs) + 1}", timestamp=_now_iso(), level="error",
            message=f"Listing Anthropic models failed (HTTP {resp.status_code}).",
            endpoint=f"GET {url}", status_code=resp.status_code, duration_ms=elapsed,
        ))
        return None
    logs.append(SyncLogEntry(
        id=f"log-{len(logs) + 1}", timestamp=_now_iso(), level="info", message=f"Listed {len(items)} Anthropic models.",
        endpoint=f"GET {url}", status_code=200, duration_ms=elapsed, details={"count": len(items)},
    ))
    return len(items)


async def _scan_live(pool: Any, tenant_id: str, row: Any, creds: dict[str, str]) -> SyncResult:
    """A manual scan: the same adapter, diff and persistence the continuous sync uses, now.

    Counts are what this scan's listing returned; a kind whose listing failed
    is ``None``, never zero.
    """
    provider_id = row["provider_id"]
    adapter = remote_agent_sync.ADAPTERS[provider_id]
    creds = remote_agent_sync.with_connector_workspace(creds, row)
    started = time.monotonic()
    now = _now_iso()
    if not adapter.credential(creds):
        return SyncResult(
            provider_id=provider_id, synced_at=now, duration_ms=int((time.monotonic() - started) * 1000),
            status="error", records_scanned=RecordsScanned(), policies_evaluated=None,
            logs=[SyncLogEntry(id="log-1", timestamp=now, level="error",
                               message=f"No {adapter.display_name} API key is stored for this connector; no request was made.")],
        )

    outcome = await remote_agent_sync.SYNC.sync_connector(
        pool, tenant_id, row["connector_id"], creds_override=creds, connector=row,
    )
    listing = outcome.listing
    logs: list[SyncLogEntry] = []
    for call in listing.calls:
        failed = call.error is not None
        workspace = call.error == remote_agent_sync.WORKSPACE_REQUIRED_MESSAGE
        logs.append(SyncLogEntry(
            id=f"log-{len(logs) + 1}", timestamp=_now_iso(), level="error" if failed else "info",
            message=(call.error if workspace else f"{call.endpoint} failed ({call.error})." if failed
                     else f"Listed {call.count} {adapter.display_name} records."),
            endpoint=call.endpoint, status_code=call.status_code, duration_ms=call.duration_ms,
            details=({"error_code": remote_agent_sync.WORKSPACE_REQUIRED_CODE} if workspace
                     else None if failed else {"count": call.count}),
        ))
    for error in listing.errors:
        if error.status is None or error.status == 200 or not listing.calls:
            # Not an HTTP failure already logged above (truncation, missing key).
            logs.append(SyncLogEntry(id=f"log-{len(logs) + 1}", timestamp=_now_iso(), level="error", message=str(error)))

    counts: dict[str, int | None] = {}
    for kind in listing.attempted_kinds:
        counts[_KIND_LABEL.get(kind, kind)] = outcome.counts.get(kind, 0) if kind in listing.complete_kinds else None
    observed = [kind in listing.complete_kinds for kind in listing.attempted_kinds]
    if provider_id == "claude":
        counts["models"] = await _list_anthropic_models(adapter.credential(creds) or "", logs, creds.get("workspace_id"))
        observed.append(counts["models"] is not None)
    status: Literal["success", "warning", "error"] = (
        "success" if all(observed) and not listing.errors else ("warning" if any(observed) else "error"))
    return SyncResult(
        provider_id=provider_id, synced_at=now, duration_ms=int((time.monotonic() - started) * 1000),
        status=status, records_scanned=RecordsScanned(**counts), policies_evaluated=None, logs=logs,
    )


# Providers with a live scanner (a remote_agent_sync adapter). Every other
# provider answers 501 in live mode.
_LIVE_SCANNERS = remote_agent_sync.ADAPTERS


def _scan_outcome(result: SyncResult) -> tuple[str | None, str | None]:
    """(new last_scan_at or None to keep the previous one, last_scan_error).

    last_scan_at means "synced": only a scan that observed everything it asked
    for earns it. A warning is a partial scan (some listings failed), so it
    records its status and error but keeps the previous successful time.
    """
    if result.status == "success":
        return result.synced_at, None
    failures = [log.message for log in result.logs if log.level == "error"]
    return None, " ".join(failures) or f"Scan finished with status '{result.status}'."


@router.post("/api/v1/connectors/{provider_id}/scan", response_model=SyncResult)
@router.post("/api/connectors/{provider_id}/scan", response_model=SyncResult)
@router.post("/connectors/{provider_id}/scan", response_model=SyncResult)
async def scan_connector(
    provider_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
    body: dict[str, Any] | None = None,
) -> SyncResult:
    """Scan one of the caller's connected connectors, by provider id or connector id."""
    tenant_id = principal.tenant
    pool = await _store_pool("Scanning a connector")
    fixture = pool is None

    row: Any = None
    if fixture:
        _ensure_tenant_connectors_seeded(tenant_id)
        with _CONN_LOCK:
            conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
            match = next(
                (c for c in conns
                 if (c["connector_id"] == provider_id or c["provider_id"] == provider_id) and c.get("status") == "connected"),
                None,
            )
    else:
        row = await pool.fetchrow(_SQL_GET, tenant_id, provider_id)
        match = _connector_from_row(row) if row is not None and row["status"] == "connected" else None
    if match is None:
        raise APIError(404, "connector_not_configured", f"No connected connector '{provider_id}' for this tenant")
    connector_id, canonical_provider = match["connector_id"], match["provider_id"]

    scanner = None if fixture else _LIVE_SCANNERS.get(canonical_provider)
    if not fixture and scanner is None:
        raise APIError(501, "scan_unsupported", f"No live scanner exists for provider '{canonical_provider}'")

    await _audit_outbound_request(
        principal, "connector.scan_requested",
        {"connector_id": connector_id, "provider_id": canonical_provider}, "Connector scan",
    )

    if scanner is not None:
        creds = _supplied_credentials(body) or _open_stored(tenant_id, row)
        result = await _scan_live(pool, tenant_id, row, creds)
        scan_at, scan_error = _scan_outcome(result)
        await pool.execute(
            _SQL_RECORD_SCAN, tenant_id, connector_id, _ts_in(scan_at, "synced_at"),
            result.status, scan_error, result.model_dump_json(),
        )
        await _live_connectors(pool, tenant_id)
    else:
        creds = _supplied_credentials(body) or _stored_credentials(tenant_id, match)
        live_telemetry = None
        if canonical_provider == "claude":
            live_telemetry = await _fetch_live_anthropic_telemetry(creds.get("api_key", ""), creds.get("workspace_id"))
            if live_telemetry:
                update_claude_agent_name(tenant_id, live_telemetry["agent_name"], live_telemetry.get("agent_id"))
        result = _generate_sync_result(
            canonical_provider,
            timestamp=_now_iso(),
            live_agent_name=live_telemetry["agent_name"] if live_telemetry else None,
            live_agent_id=live_telemetry.get("agent_id") if live_telemetry else None,
            live_count=live_telemetry.get("count") if live_telemetry else None,
        )
        scan_at, scan_error = _scan_outcome(result)
        with _CONN_LOCK:
            if scan_at is not None:
                match["last_scan_at"] = scan_at
            match["last_scan_error"] = scan_error
            match["last_scan_status"] = result.status
            stored = _TENANT_SYNC_RESULTS.setdefault(tenant_id, {})
            stored[canonical_provider] = result
            stored[connector_id] = result

    logger.info("Connector '%s' scanned for tenant '%s' by actor '%s'", connector_id, tenant_id, principal.actor)
    return _redact_for(principal, result)


@router.get("/api/v1/connectors/{provider_id}/logs", response_model=SyncResult)
@router.get("/api/connectors/{provider_id}/logs", response_model=SyncResult)
@router.get("/connectors/{provider_id}/logs", response_model=SyncResult)
async def get_connector_logs(
    provider_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> SyncResult:
    """The last stored scan result for a provider or connector id."""
    tenant_id = principal.tenant
    pool = await _store_pool("Reading connector scan logs")

    if pool is not None:
        row = await pool.fetchrow(_SQL_GET, tenant_id, provider_id)
        stored = _json_in(row["last_scan_result"]) if row is not None else None
        result = SyncResult.model_validate(stored) if stored else None
    else:
        _ensure_tenant_connectors_seeded(tenant_id)
        with _CONN_LOCK:
            conns = _TENANT_CONNECTORS_DATA.get(tenant_id, [])
            match = next((c for c in conns if c["connector_id"] == provider_id or c["provider_id"] == provider_id), None)
            tenant_results = _TENANT_SYNC_RESULTS.get(tenant_id, {})
            result = tenant_results.get(provider_id) or (tenant_results.get(match["provider_id"]) if match else None)
            if result is None and match is not None:
                # Fixture mode only: the demo shows canned logs before any scan.
                result = _generate_sync_result(match["provider_id"])
                tenant_results = _TENANT_SYNC_RESULTS.setdefault(tenant_id, {})
                tenant_results[match["provider_id"]] = result
                tenant_results[match["connector_id"]] = result

    if result is None:
        raise APIError(404, "never_scanned", f"No scan has run for '{provider_id}' in this tenant")
    return _redact_for(principal, result)


# ---------------------------------------------------------------------------
# Remote agentic runtime: read API, change stream, webhook
# ---------------------------------------------------------------------------

class RemoteAgent(BaseModel):
    external_id: str
    kind: str
    name: str | None
    model: str | None
    status: str | None
    version: str | None
    external_updated_at: str | None
    first_seen_at: str
    last_seen_at: str
    last_changed_at: str
    gone_at: str | None
    # The registry agent this remote agent is claimed as (migration 072), or None.
    claimed_agent_id: str | None = None
    claimed_at: str | None = None


class RemoteSyncState(BaseModel):
    mode: Literal["poll", "poll+stream", "backoff"]
    last_poll_at: str | None
    last_success_at: str | None
    last_error: str | None
    next_poll_at: str | None
    consecutive_failures: int


class RemoteAgentsResponse(BaseModel):
    provider_id: str
    connector_id: str
    sync_state: RemoteSyncState | None
    agents: list[RemoteAgent]


@router.get("/api/v1/connectors/stream")
@router.get("/api/connectors/stream")
@router.get("/connectors/stream")
async def stream_connector_events(
    request: Request,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> Response:
    """Server-Sent Events of remote agent changes for the caller's tenant only.

    Events: ``remote_agent.upserted`` {provider_id, connector_id, agent},
    ``remote_agent.gone`` {provider_id, connector_id, external_id, gone_at},
    ``connector.sync_state`` {provider_id, connector_id, sync_state}, and
    ``stream.reset`` {} when a Last-Event-ID cannot be replayed (refetch).
    ``: heartbeat`` every 15 s.
    """
    from fastapi.responses import StreamingResponse

    frames = remote_agent_sync.sse_frames(
        remote_agent_sync.EVENTS, principal.tenant, request.headers.get("last-event-id"),
        request.is_disconnected, heartbeat=remote_agent_sync.HEARTBEAT_SECONDS, max_events=_STREAM_MAX_EVENTS,
    )
    return StreamingResponse(frames, media_type="text/event-stream",
                             headers={"cache-control": "no-cache", "x-accel-buffering": "no"})


# Tests bound a stream; production never sets this.
_STREAM_MAX_EVENTS: int | None = None


@router.get("/api/v1/connectors/{provider_id}/remote-agents", response_model=RemoteAgentsResponse)
@router.get("/api/connectors/{provider_id}/remote-agents", response_model=RemoteAgentsResponse)
@router.get("/connectors/{provider_id}/remote-agents", response_model=RemoteAgentsResponse)
async def list_connector_remote_agents(
    provider_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> RemoteAgentsResponse:
    """What continuous sync last observed on the connector's platform, gone items included."""
    tenant_id = principal.tenant
    pool = await _store_pool("Reading remote agents")
    if pool is None:
        # Fixture mode: no sync runs and no remote state is invented.
        _ensure_tenant_connectors_seeded(tenant_id)
        with _CONN_LOCK:
            match = next((c for c in _TENANT_CONNECTORS_DATA.get(tenant_id, [])
                          if c["connector_id"] == provider_id or c["provider_id"] == provider_id), None)
        if match is None:
            raise APIError(404, "connector_not_configured", f"No connector '{provider_id}' for this tenant")
        return RemoteAgentsResponse(provider_id=match["provider_id"], connector_id=match["connector_id"],
                                    sync_state=None, agents=[])
    row = await pool.fetchrow(_SQL_GET, tenant_id, provider_id)
    if row is None:
        raise APIError(404, "connector_not_configured", f"No connector '{provider_id}' for this tenant")
    agents, state = await remote_agent_sync.list_remote_agents(pool, tenant_id, row["connector_id"])
    return RemoteAgentsResponse(provider_id=row["provider_id"], connector_id=row["connector_id"],
                                sync_state=state, agents=agents)


class RemoteAgentClaimResponse(BaseModel):
    """The registry agent a remote provider agent is claimed as. ``created`` is False on a repeat claim."""
    agent_id: str
    agent_name: str
    display_name: str
    provider_id: str
    connector_id: str
    external_id: str
    kind: str
    model: str | None
    claimed_at: str | None
    created: bool


# The model vendor behind each connector provider, for agent_registry.model_provider.
_MODEL_PROVIDER = {"claude": "anthropic", "openai": "openai"}
# Deterministic registry ids: uuid5 over tenant, provider and provider id.
_REMOTE_AGENT_NS = uuid.uuid5(uuid.NAMESPACE_URL, "https://signalloom.ai/remote-agents")


def _remote_agent_registry_identity(tenant_id: str, provider_id: str, external_id: str) -> tuple[uuid.UUID, str]:
    """(id, name) for the registry record of a claimed remote agent.

    Both are a pure function of (tenant, provider, external id): a retry or a
    concurrent claim converges on one row, a reconnected connector re-links the
    same agent, and two tenants that connect the same provider organisation get
    two records. The name carries the tenant so it is unique even under the
    original global UNIQUE (name) that migration 035 replaced.
    """
    return (uuid.uuid5(_REMOTE_AGENT_NS, f"{tenant_id}\x1f{provider_id}\x1f{external_id}"),
            f"{provider_id}:{external_id}@{tenant_id}")


def _claim_response(row: Any, provider_id: str, connector_id: str, agent_id: str, name: str,
                    created: bool) -> RemoteAgentClaimResponse:
    return RemoteAgentClaimResponse(
        agent_id=agent_id, agent_name=name, display_name=row["name"] or row["external_id"],
        provider_id=provider_id, connector_id=connector_id, external_id=row["external_id"], kind=row["kind"],
        model=row["model"], claimed_at=remote_agent_sync.iso(row["claimed_at"]), created=created,
    )


@router.post("/api/v1/connectors/{provider_id}/remote-agents/{external_id}/claim",
             response_model=RemoteAgentClaimResponse, status_code=201)
@router.post("/api/connectors/{provider_id}/remote-agents/{external_id}/claim",
             response_model=RemoteAgentClaimResponse, status_code=201)
@router.post("/connectors/{provider_id}/remote-agents/{external_id}/claim",
             response_model=RemoteAgentClaimResponse, status_code=201)
async def claim_remote_agent(
    provider_id: str,
    external_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> Any:
    """Claim a remote agent continuous sync observed into the caller's tenant.

    201 with the new registry agent; 200 with the same agent on a repeat claim.
    404 when the connector or the remote agent is not the caller's, 409 when the
    provider no longer lists it. Fixture mode has no remote state (the same as
    GET remote-agents), so every claim there is 404 remote_agent_not_found.
    """
    tenant_id = principal.tenant
    pool = await _store_pool("Claiming a remote agent")
    if pool is None:
        _ensure_tenant_connectors_seeded(tenant_id)
        with _CONN_LOCK:
            match = next((c for c in _TENANT_CONNECTORS_DATA.get(tenant_id, [])
                          if c["connector_id"] == provider_id or c["provider_id"] == provider_id), None)
        if match is None:
            raise APIError(404, "connector_not_configured", f"No connector '{provider_id}' for this tenant")
        raise APIError(404, "remote_agent_not_found", f"No remote agent '{external_id}' on this connector")

    conn_row = await pool.fetchrow(_SQL_GET, tenant_id, provider_id)
    if conn_row is None:
        raise APIError(404, "connector_not_configured", f"No connector '{provider_id}' for this tenant")
    connector_id, real_provider = conn_row["connector_id"], conn_row["provider_id"]
    agent_uuid, name = _remote_agent_registry_identity(tenant_id, real_provider, external_id)

    async with _write(pool) as conn:
        row = await conn.fetchrow(remote_agent_sync.SQL_EXISTING_ONE, tenant_id, connector_id, external_id)
        if row is None:
            raise APIError(404, "remote_agent_not_found", f"No remote agent '{external_id}' on this connector")
        if row["claimed_agent_id"] is not None:
            return JSONResponse(status_code=200, content=_claim_response(
                row, real_provider, connector_id, str(row["claimed_agent_id"]), name, False).model_dump())
        if row["gone_at"] is not None:
            raise APIError(409, "remote_agent_gone",
                           f"Remote agent '{external_id}' is no longer listed by the provider")

        display_name = row["name"] or external_id
        provenance = {"provider_id": real_provider, "connector_id": connector_id, "external_id": external_id,
                      "kind": row["kind"], "model": row["model"]}
        # Keyed by the deterministic id and scoped on conflict by tenant_id = $1, so a
        # retry or a concurrent claim converges on one row and never touches another
        # tenant's. Literal here so the audit-provenance guard sees the write.
        registered = await conn.fetchrow(
            "INSERT /* remote_agent_store:registry_upsert */ INTO public.agent_registry (tenant_id, id, name, "
            "display_name, description, status, lifecycle_state, model_provider, model_name, owner, owner_id, "
            "config, last_transition_at, created_at, updated_at) "
            "VALUES ($1, $2, $3, $4, $5, 'active', 'enrolled', $6, $7, $8, $9, $10::jsonb, NOW(), NOW(), NOW()) "
            "ON CONFLICT (id) DO UPDATE SET "
            "model_name = COALESCE(EXCLUDED.model_name, public.agent_registry.model_name), "
            "owner = COALESCE(public.agent_registry.owner, EXCLUDED.owner), "
            "owner_id = COALESCE(public.agent_registry.owner_id, EXCLUDED.owner_id), "
            "config = public.agent_registry.config || EXCLUDED.config, updated_at = NOW() "
            "WHERE public.agent_registry.tenant_id = $1 RETURNING id",
            tenant_id, agent_uuid, name, display_name,
            f"{row['kind'].capitalize()} {external_id} on {real_provider}, claimed from Discovery",
            _MODEL_PROVIDER.get(real_provider, real_provider), row["model"], principal.actor,
            api_compat._try_uuid(principal.user_id) if principal.user_id else None,
            json.dumps({"remote_agent": provenance}),
        )
        if registered is None:
            # The deterministic id is held by another tenant's row: not reachable
            # with a tenant-qualified uuid5, refused rather than overwritten.
            raise APIError(409, "claim_conflict", f"Remote agent '{external_id}' cannot be registered")
        # Set only while unset, and only on a row the provider still lists.
        linked = await conn.fetchrow(
            f"UPDATE /* remote_agent_store:claim_link */ public.remote_agents SET claimed_agent_id = $4, "
            "claimed_at = $5 WHERE tenant_id = $1 AND connector_id = $2 AND external_id = $3 "
            f"AND gone_at IS NULL AND claimed_agent_id IS NULL RETURNING {remote_agent_sync.RA_COLUMNS}",
            tenant_id, connector_id, external_id, agent_uuid, datetime.now(timezone.utc))
        if linked is None:
            # A concurrent claim linked it first: answer with that link.
            current = await conn.fetchrow(remote_agent_sync.SQL_EXISTING_ONE, tenant_id, connector_id, external_id)
            if current is None or current["claimed_agent_id"] is None:
                raise APIError(409, "remote_agent_gone",
                               f"Remote agent '{external_id}' is no longer listed by the provider")
            return JSONResponse(status_code=200, content=_claim_response(
                current, real_provider, connector_id, str(current["claimed_agent_id"]), name, False).model_dump())
        await api_compat._audit_log(
            conn, tenant_id, "agent.claimed", str(agent_uuid), display_name, principal.actor,
            {"action": "claimed", "source": "remote_agent", **provenance,
             "remote_name": row["name"], "remote_status": row["status"], "agent_name": name,
             "owner": principal.actor},
        )

    remote_agent_sync.EVENTS.publish(tenant_id, "remote_agent.upserted", {
        "provider_id": real_provider, "connector_id": connector_id, "agent": remote_agent_sync.agent_from_row(linked)})
    return _claim_response(linked, real_provider, connector_id, str(agent_uuid), name, True)


ANTHROPIC_WEBHOOK_KEY_ENV = "ANTHROPIC_WEBHOOK_SIGNING_KEY"
# "org_id=tenant_id,org_id2=tenant_id2": which tenant an Anthropic organisation's
# events belong to. A Console webhook endpoint belongs to one organisation, so
# this is deployment configuration, not tenant data.
ANTHROPIC_WEBHOOK_ORGS_ENV = "ANTHROPIC_WEBHOOK_ORGANIZATIONS"
_WEBHOOK_SEEN: dict[tuple[str, str], None] = {}
_WEBHOOK_SEEN_MAX = 2048


def _webhook_org_tenants() -> dict[str, str]:
    out: dict[str, str] = {}
    for pair in os.environ.get(ANTHROPIC_WEBHOOK_ORGS_ENV, "").split(","):
        org, sep, tenant = pair.strip().partition("=")
        if sep and org.strip() and tenant.strip():
            out[org.strip()] = tenant.strip()
    return out


def _verify_anthropic_webhook(body: bytes, headers: dict[str, str], key: str) -> dict[str, Any]:
    """The verified event as a dict; raises ValueError on any signature failure."""
    import anthropic

    client = anthropic.Anthropic(api_key="webhook-verification-only")
    try:
        event = client.beta.webhooks.unwrap(body.decode("utf-8"), headers=headers, key=key)
    except Exception as exc:  # standardwebhooks.WebhookVerificationError and friends
        raise ValueError(str(exc) or type(exc).__name__) from None
    return event.model_dump(mode="json")


@router.post("/api/v1/connectors/claude/webhook")
@router.post("/api/connectors/claude/webhook")
@router.post("/connectors/claude/webhook")
async def anthropic_webhook(request: Request) -> JSONResponse:
    """Anthropic's signed, thin event: re-fetch the resource it names, through the sync's diff path.

    Disabled (404) unless ANTHROPIC_WEBHOOK_SIGNING_KEY is set. A bad signature
    is 400; an organisation that maps to no tenant, or a tenant without a
    connected Claude connector, is 404. Duplicate deliveries are answered 200
    and ignored.
    """
    key = os.environ.get(ANTHROPIC_WEBHOOK_KEY_ENV, "").strip()
    if not key:
        raise APIError(404, "webhook_disabled", "Anthropic webhooks are not enabled on this deployment")
    body = await request.body()
    try:
        event = _verify_anthropic_webhook(body, {k.lower(): v for k, v in request.headers.items()}, key)
    except ValueError as exc:
        raise APIError(400, "invalid_signature", f"Webhook signature verification failed: {exc}") from None

    data = event.get("data") or {}
    org_id, resource_type, resource_id = data.get("organization_id"), data.get("type") or "", data.get("id")
    tenant_id = _webhook_org_tenants().get(org_id or "")
    if tenant_id is None:
        raise APIError(404, "unknown_organization", "No tenant is configured for this Anthropic organization")
    pool = await _store_pool("Receiving an Anthropic webhook")
    if pool is None:
        raise APIError(404, "connector_not_configured", "Webhooks apply to live connectors only")
    row = await pool.fetchrow(_SQL_GET, tenant_id, "claude")
    if row is None or row["status"] != "connected":
        raise APIError(404, "connector_not_configured", "No connected Anthropic Claude connector for this tenant")

    event_id = str(event.get("id") or "")
    if (tenant_id, event_id) in _WEBHOOK_SEEN:
        return JSONResponse({"status": "duplicate", "event_id": event_id})
    kind = "session" if resource_type.startswith("session.") else ("agent" if resource_type.startswith("agent.") else None)

    # The caller is the verified sender: Anthropic, for the mapped organisation.
    # Like a manual scan, the refetch is audited before the upstream is asked.
    principal = Principal(tenant=tenant_id, subject=f"anthropic-webhook:{org_id}")
    await _audit_outbound_request(
        principal, "connector.scan_requested",
        {"connector_id": row["connector_id"], "provider_id": "claude", "trigger": "webhook",
         "webhook_event_id": event_id, "event_type": resource_type, "resource_id": resource_id},
        "Anthropic webhook refetch",
    )
    _WEBHOOK_SEEN[(tenant_id, event_id)] = None
    while len(_WEBHOOK_SEEN) > _WEBHOOK_SEEN_MAX:
        _WEBHOOK_SEEN.pop(next(iter(_WEBHOOK_SEEN)))

    if kind is None or not resource_id:
        return JSONResponse({"status": "ignored", "event_id": event_id})
    try:
        result = await remote_agent_sync.SYNC.refresh_item(
            pool, tenant_id, row["connector_id"], kind, str(resource_id), deleted=resource_type.endswith(".deleted"),
        )
    except remote_agent_sync.ProviderError as exc:
        # Accepted and recorded; the next poll retries. Anthropic need not redeliver.
        return JSONResponse({"status": "refetch_failed", "event_id": event_id, "error": str(exc)})
    return JSONResponse({"status": result, "event_id": event_id})


def reset_webhook_dedupe_for_testing() -> None:
    _WEBHOOK_SEEN.clear()


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
            test_supplied_credentials,
            scan_connector,
            get_connector_logs,
            stream_connector_events,
            list_connector_remote_agents,
            claim_remote_agent,
            anthropic_webhook,
        ):
            return
    app.include_router(router)

