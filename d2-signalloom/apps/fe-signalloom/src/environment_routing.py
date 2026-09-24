"""Signal Loom On-Demand EAP Environment Routing & Tailscale Mesh Engine.

Provides cryptographic customer hashing, RFC 1123 domain synthesis,
Pydantic v2 lifecycle models, thread-safe environment registry, and
FastAPI REST API router for on-demand demo and UAT provisioning.
"""
from __future__ import annotations

import hashlib
import logging
import os
import re
import threading
import uuid
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, FastAPI, HTTPException, Query, Request, WebSocket, status
from pydantic import BaseModel, ConfigDict, Field, field_validator

logger = logging.getLogger(__name__)

DEFAULT_EAP_SALT = "signalloom-eap-salt-2026-q3"
MAX_LIFETIME_HOURS = 72
MAX_INITIAL_TTL_MINUTES = 1440  # 24 hours
MIN_INITIAL_TTL_MINUTES = 5
EXPIRY_WARNING_THRESHOLD_MINUTES = 30
OIDC_CALLBACK_PATH = "/auth/callback"

# Applied to every response under the environments API prefix, errors included.
# Scoped to the prefix rather than the whole app because the strict CSP would
# break the FastAPI /docs page, which loads its assets from a CDN.
EAP_SECURITY_HEADERS: Dict[str, str] = {
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
    "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
}

RFC1123_LABEL_REGEX = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
EAP_SUBDOMAIN_REGEX = re.compile(r"^sl-eap-[a-f0-9]{8}$")


def get_eap_salt() -> str:
    """Retrieve the configured cryptographic salt from env or default."""
    return os.getenv("SIGNAL_LOOM_EAP_SALT", DEFAULT_EAP_SALT)


def normalize_company_name(company_name: str) -> str:
    """Normalize company name for deterministic hashing.

    Trims leading/trailing whitespace and converts to lowercase.
    """
    if not company_name or not isinstance(company_name, str):
        raise ValueError("Company name must be a non-empty string.")
    cleaned = company_name.strip().lower()
    if not cleaned:
        raise ValueError("Company name cannot be empty or whitespace-only.")
    return cleaned


def derive_customer_hash(company_name: str, salt: Optional[str] = None) -> str:
    """Derive an 8-character hex hash from a customer company name and cryptographic salt.

    Canonical vector:
        company_name: "kurasi"
        salt: "signalloom-eap-salt-2026-q3"
        -> "6f82ad81"
    """
    normalized = normalize_company_name(company_name)
    actual_salt = salt if salt is not None else get_eap_salt()
    salted_payload = f"{actual_salt}:{normalized}".encode("utf-8")
    full_digest = hashlib.sha256(salted_payload).hexdigest()
    return full_digest[:8]


def validate_environment_subdomain(subdomain: str) -> bool:
    """Validate that a subdomain matches the sl-eap-HASH format and RFC 1123."""
    if not subdomain or not isinstance(subdomain, str):
        return False
    if len(subdomain) > 63:
        return False
    return bool(EAP_SUBDOMAIN_REGEX.match(subdomain))


def build_environment_urls(customer_hash: str) -> Dict[str, str]:
    """Build the internal tailnet mesh URL and external MagicDNS FQDN for an EAP environment."""
    clean_hash = customer_hash.strip().lower()
    hostname = f"sl-eap-{clean_hash}"
    if not validate_environment_subdomain(hostname):
        raise ValueError(f"Invalid customer hash for subdomain generation: {customer_hash}")

    internal_mesh_url = f"https://{hostname}.tailscale"
    return {
        "hostname": hostname,
        "internal_mesh_url": internal_mesh_url,
        "external_fqdn": f"https://{hostname}.ts.net",
        "oidc_redirect_uri": f"{internal_mesh_url}{OIDC_CALLBACK_PATH}",
    }


def resolve_company_to_urls(company_name: str, salt: Optional[str] = None) -> Dict[str, str]:
    """Helper to resolve a company name directly to customer hash and URL set."""
    h = derive_customer_hash(company_name, salt)
    urls = build_environment_urls(h)
    urls["customer_hash"] = h
    urls["company_name"] = normalize_company_name(company_name)
    return urls


# ── Lifecycle Enums & Pydantic Models ──────────────────────────────────────


class EnvironmentState(str, Enum):
    PENDING = "pending"
    PROVISIONING = "provisioning"
    READY = "ready"
    DEGRADED = "degraded"
    EXPIRING = "expiring"
    TEARING_DOWN = "tearing_down"
    TERMINATED = "terminated"


class EnvironmentTier(str, Enum):
    DEMO = "demo"
    UAT = "uat"
    PILOT = "pilot"


class ProvisionRequest(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    company_name: str = Field(
        ...,
        min_length=2,
        max_length=64,
        description="Target customer company name to normalize and salt-hash",
        examples=["kurasi"],
    )
    tier: EnvironmentTier = Field(
        default=EnvironmentTier.DEMO,
        description="Environment deployment tier",
    )
    ttl_minutes: int = Field(
        default=240,
        ge=MIN_INITIAL_TTL_MINUTES,
        le=MAX_INITIAL_TTL_MINUTES,
        description="Initial time-to-live in minutes (default 4 hours, max 24 hours)",
    )
    metadata: Dict[str, Any] = Field(
        default_factory=dict,
        description="Optional enterprise tenant metadata or contact information",
    )
    enable_funnel: bool = Field(
        default=False,
        description="Whether to expose the environment externally via Tailscale Funnel (*.ts.net)",
    )

    @field_validator("company_name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        clean = normalize_company_name(v)
        # Check that normalized name doesn't contain forbidden chars
        if not re.match(r"^[a-z0-9][a-z0-9 ._-]*[a-z0-9]$", clean) and len(clean) > 1:
            # allow single char if within length constraints, but min_length=2
            raise ValueError("Company name contains invalid characters.")
        return clean


class EnvironmentResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    company_name: str
    customer_hash: str
    hostname: str
    internal_mesh_url: str
    external_fqdn: str
    oidc_redirect_uri: str
    tier: EnvironmentTier
    state: EnvironmentState
    created_at: datetime
    expires_at: datetime
    ttl_remaining_seconds: int
    expiry_warning: bool
    metadata: Dict[str, Any]
    enable_funnel: bool


class DomainResolutionRequest(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    company_name: Optional[str] = Field(default=None, min_length=2, max_length=64)
    customer_hash: Optional[str] = Field(default=None, min_length=8, max_length=8)

    @field_validator("customer_hash")
    @classmethod
    def validate_hash_format(cls, v: Optional[str]) -> Optional[str]:
        if v is not None:
            v = v.lower()
            if not re.match(r"^[a-f0-9]{8}$", v):
                raise ValueError("customer_hash must be an 8-character lowercase hexadecimal string.")
        return v


class DomainResolutionResponse(BaseModel):
    company_name: Optional[str]
    customer_hash: str
    hostname: str
    internal_mesh_url: str
    external_fqdn: str
    oidc_redirect_uri: str
    is_active: bool
    environment_id: Optional[str] = None


class ExtendTtlRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    additional_minutes: int = Field(
        ...,
        ge=1,
        le=1440,
        description="Number of minutes to add to current expiration (max 24 hours per extension)",
    )


class TeardownRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reason: Optional[str] = Field(default="Requested by operator or API client", max_length=256)
    force: bool = Field(default=False, description="Force termination bypassing connection draining")


# ── Thread-Safe Environment Registry ──────────────────────────────────────


class EnvironmentRecord:
    def __init__(
        self,
        record_id: str,
        company_name: str,
        customer_hash: str,
        tier: EnvironmentTier,
        created_at: datetime,
        expires_at: datetime,
        metadata: Dict[str, Any],
        enable_funnel: bool = False,
        state: EnvironmentState = EnvironmentState.PROVISIONING,
    ):
        self.id = record_id
        self.company_name = company_name
        self.customer_hash = customer_hash
        urls = build_environment_urls(customer_hash)
        self.hostname = urls["hostname"]
        self.internal_mesh_url = urls["internal_mesh_url"]
        self.external_fqdn = urls["external_fqdn"]
        self.oidc_redirect_uri = urls["oidc_redirect_uri"]
        self.tier = tier
        self.created_at = created_at
        self.expires_at = expires_at
        self.metadata = metadata
        self.enable_funnel = enable_funnel
        self.state = state
        self.version = 1
        self.teardown_reason: Optional[str] = None
        self.updated_at = created_at
        self.events: List[Dict[str, Any]] = []
        self.record_event("provisioned", {"expires_at": expires_at.isoformat()})

    def record_event(self, event: str, detail: Optional[Dict[str, Any]] = None) -> None:
        """Append a lifecycle event; callers hold the registry lock."""
        self.events.append(
            {
                "seq": len(self.events) + 1,
                "event": event,
                "state": self.state.value,
                "at": datetime.now(timezone.utc).isoformat(),
                "detail": detail or {},
            }
        )

    @property
    def expiry_warning(self) -> bool:
        if self.state == EnvironmentState.TERMINATED:
            return False
        return self.ttl_remaining_seconds < EXPIRY_WARNING_THRESHOLD_MINUTES * 60

    @property
    def ttl_remaining_seconds(self) -> int:
        now = datetime.now(timezone.utc)
        diff = (self.expires_at - now).total_seconds()
        return max(0, int(diff))

    def is_expired(self, now: Optional[datetime] = None) -> bool:
        current_time = now or datetime.now(timezone.utc)
        return current_time >= self.expires_at

    def to_response(self) -> EnvironmentResponse:
        return EnvironmentResponse(
            id=self.id,
            company_name=self.company_name,
            customer_hash=self.customer_hash,
            hostname=self.hostname,
            internal_mesh_url=self.internal_mesh_url,
            external_fqdn=self.external_fqdn,
            oidc_redirect_uri=self.oidc_redirect_uri,
            tier=self.tier,
            state=self.state,
            created_at=self.created_at,
            expires_at=self.expires_at,
            ttl_remaining_seconds=self.ttl_remaining_seconds,
            expiry_warning=self.expiry_warning,
            metadata=self.metadata,
            enable_funnel=self.enable_funnel,
        )


class EnvironmentRegistry:
    """In-memory thread-safe registry for on-demand EAP environments."""

    def __init__(self):
        self._lock = threading.RLock()
        self._records: Dict[str, EnvironmentRecord] = {}  # by id
        self._by_hash: Dict[str, str] = {}  # hash -> id

    def create(self, req: ProvisionRequest) -> EnvironmentRecord:
        with self._lock:
            c_hash = derive_customer_hash(req.company_name)
            existing_id = self._by_hash.get(c_hash)
            if existing_id:
                rec = self._records.get(existing_id)
                if rec and rec.state not in (EnvironmentState.TERMINATED,):
                    raise HTTPException(
                        status_code=status.HTTP_409_CONFLICT,
                        detail=(
                            f"An active environment already exists for customer '{req.company_name}' "
                            f"(hash: {c_hash}, id: {rec.id}, state: {rec.state.value})."
                        ),
                    )

            now = datetime.now(timezone.utc)
            expires = now + timedelta(minutes=req.ttl_minutes)
            rec_id = str(uuid.uuid4())

            record = EnvironmentRecord(
                record_id=rec_id,
                company_name=req.company_name,
                customer_hash=c_hash,
                tier=req.tier,
                created_at=now,
                expires_at=expires,
                metadata=dict(req.metadata),
                enable_funnel=req.enable_funnel,
                state=EnvironmentState.READY,  # Immediately ready for demo routing
            )
            self._records[rec_id] = record
            self._by_hash[c_hash] = rec_id
            logger.info("Created EAP environment: id=%s, hash=%s, company=%s", rec_id, c_hash, req.company_name)
            return record

    def get(self, record_id: str) -> Optional[EnvironmentRecord]:
        with self._lock:
            return self._records.get(record_id)

    def get_by_hash(self, customer_hash: str) -> Optional[EnvironmentRecord]:
        with self._lock:
            rec_id = self._by_hash.get(customer_hash.lower())
            if rec_id:
                return self._records.get(rec_id)
            return None

    def list(
        self,
        state: Optional[EnvironmentState] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> List[EnvironmentRecord]:
        with self._lock:
            items = list(self._records.values())
            if state is not None:
                items = [r for r in items if r.state == state]
            # sort by created_at descending
            items.sort(key=lambda r: r.created_at, reverse=True)
            return items[offset : offset + limit]

    def extend_ttl(self, record_id: str, additional_minutes: int) -> EnvironmentRecord:
        with self._lock:
            rec = self._records.get(record_id)
            if not rec:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Environment with ID '{record_id}' not found.",
                )
            if rec.state == EnvironmentState.TERMINATED:
                raise HTTPException(
                    status_code=status.HTTP_410_GONE,
                    detail="Cannot extend TTL of a terminated environment.",
                )

            new_expires = rec.expires_at + timedelta(minutes=additional_minutes)
            max_ceiling = rec.created_at + timedelta(hours=MAX_LIFETIME_HOURS)
            if new_expires > max_ceiling:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=(
                        f"Requested extension exceeds maximum lifetime ceiling of {MAX_LIFETIME_HOURS} hours "
                        f"from initial creation (cap: {max_ceiling.isoformat()})."
                    ),
                )

            previous_expires = rec.expires_at
            rec.expires_at = new_expires
            rec.version += 1
            rec.updated_at = datetime.now(timezone.utc)
            rec.record_event(
                "ttl_extended",
                {
                    "additional_minutes": additional_minutes,
                    "previous_expires_at": previous_expires.isoformat(),
                    "expires_at": new_expires.isoformat(),
                },
            )
            logger.info("Extended EAP environment: id=%s to %s", record_id, new_expires.isoformat())
            return rec

    def teardown(self, record_id: str, reason: Optional[str] = None, force: bool = False) -> EnvironmentRecord:
        with self._lock:
            rec = self._records.get(record_id)
            if not rec:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Environment with ID '{record_id}' not found.",
                )
            if rec.state == EnvironmentState.TERMINATED:
                return rec  # Idempotent return

            rec.teardown_reason = reason or "De-provisioned via API request"
            rec.state = EnvironmentState.TEARING_DOWN
            rec.record_event("teardown_requested", {"reason": rec.teardown_reason, "force": force})
            rec.state = EnvironmentState.TERMINATED
            rec.version += 1
            rec.updated_at = datetime.now(timezone.utc)
            rec.record_event("terminated", {"reason": rec.teardown_reason})
            logger.info("Torn down EAP environment: id=%s (reason: %s)", record_id, rec.teardown_reason)
            return rec


# Module-level default registry instance
GLOBAL_ENVIRONMENT_REGISTRY = EnvironmentRegistry()


# ── FastAPI Router & Installation ──────────────────────────────────────────


router = APIRouter(prefix="/api/v1/environments", tags=["environments"])
from eap_audit import _audit_eap_decision


@router.post(
    "/provision",
    response_model=EnvironmentResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Provision an on-demand EAP environment",
)
async def provision_environment(req: ProvisionRequest) -> EnvironmentResponse:
    """Provision a new EAP demo/UAT environment with salted domain derivation."""
    rec = GLOBAL_ENVIRONMENT_REGISTRY.create(req)
    await _audit_eap_decision(
        conn=None,
        principal=None,
        action="environment.provision",
        target=rec.customer_hash,
        verdict="allow",
        detail={"environment_id": rec.id, "company_name": rec.company_name},
    )
    return rec.to_response()


@router.post(
    "/resolve-domain",
    response_model=DomainResolutionResponse,
    status_code=status.HTTP_200_OK,
    summary="Resolve company name or customer hash to Tailscale EAP domains",
)
async def resolve_domain(req: DomainResolutionRequest) -> DomainResolutionResponse:
    """Resolve a company name or customer hash to sl-eap-HASH domain names and active status."""
    if not req.company_name and not req.customer_hash:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Must provide either company_name or customer_hash to resolve domain.",
        )

    if req.customer_hash:
        c_hash = req.customer_hash.lower()
        rec = GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(c_hash)
        c_name = rec.company_name if rec else None
    else:
        c_name = normalize_company_name(req.company_name)  # type: ignore[arg-type]
        c_hash = derive_customer_hash(c_name)
        rec = GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(c_hash)

    urls = build_environment_urls(c_hash)
    is_active = bool(rec and rec.state not in (EnvironmentState.TERMINATED,))

    return DomainResolutionResponse(
        company_name=c_name,
        customer_hash=c_hash,
        hostname=urls["hostname"],
        internal_mesh_url=urls["internal_mesh_url"],
        external_fqdn=urls["external_fqdn"],
        oidc_redirect_uri=urls["oidc_redirect_uri"],
        is_active=is_active,
        environment_id=rec.id if rec else None,
    )


@router.get(
    "/",
    response_model=List[EnvironmentResponse],
    status_code=status.HTTP_200_OK,
    summary="List all EAP environments",
)
async def list_environments(
    state: Optional[EnvironmentState] = None,
    limit: int = Query(default=100, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> List[EnvironmentResponse]:
    """List all registered EAP environments with optional state filter and pagination."""
    records = GLOBAL_ENVIRONMENT_REGISTRY.list(state=state, limit=limit, offset=offset)
    return [r.to_response() for r in records]


@router.get(
    "/{environment_id}",
    response_model=EnvironmentResponse,
    status_code=status.HTTP_200_OK,
    summary="Get EAP environment details",
)
async def get_environment(environment_id: str) -> EnvironmentResponse:
    """Retrieve detailed real-time status and TTL metrics for an EAP environment."""
    rec = GLOBAL_ENVIRONMENT_REGISTRY.get(environment_id)
    if not rec:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Environment with ID '{environment_id}' not found.",
        )
    return rec.to_response()


@router.post(
    "/{environment_id}/extend",
    response_model=EnvironmentResponse,
    status_code=status.HTTP_200_OK,
    summary="Extend EAP environment TTL",
)
async def extend_environment_ttl(environment_id: str, req: ExtendTtlRequest) -> EnvironmentResponse:
    """Extend an environment's active lease up to the 72-hour maximum lifetime ceiling."""
    rec = GLOBAL_ENVIRONMENT_REGISTRY.extend_ttl(environment_id, req.additional_minutes)
    await _audit_eap_decision(
        conn=None,
        principal=None,
        action="environment.extend",
        target=rec.customer_hash,
        verdict="allow",
        detail={"environment_id": rec.id, "additional_minutes": req.additional_minutes},
    )
    return rec.to_response()


@router.post(
    "/{environment_id}/teardown",
    response_model=EnvironmentResponse,
    status_code=status.HTTP_200_OK,
    summary="Teardown an EAP environment",
)
async def teardown_environment(environment_id: str, req: Optional[TeardownRequest] = None) -> EnvironmentResponse:
    """Initiate orderly de-provisioning and state termination for an environment."""
    reason = req.reason if req else "API teardown request"
    force = req.force if req else False
    rec = GLOBAL_ENVIRONMENT_REGISTRY.teardown(environment_id, reason=reason, force=force)
    await _audit_eap_decision(
        conn=None,
        principal=None,
        action="environment.teardown",
        target=rec.customer_hash,
        verdict="allow",
        detail={"environment_id": rec.id, "reason": reason},
    )
    return rec.to_response()


@router.get(
    "/{environment_id}/probe",
    status_code=status.HTTP_200_OK,
    summary="Health-probe an EAP environment",
)
async def probe_environment(environment_id: str) -> Dict[str, Any]:
    """Report routability: 200 when serving, 503 while tearing down, 410 once terminated."""
    rec = GLOBAL_ENVIRONMENT_REGISTRY.get(environment_id)
    if not rec:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Environment with ID '{environment_id}' not found.",
        )
    if rec.state == EnvironmentState.TERMINATED:
        raise HTTPException(
            status_code=status.HTTP_410_GONE,
            detail=f"Environment '{environment_id}' has been terminated.",
        )
    if rec.state == EnvironmentState.TEARING_DOWN:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Environment '{environment_id}' is tearing down; retry is not expected to succeed.",
        )
    return {
        "environment_id": rec.id,
        "hostname": rec.hostname,
        "internal_mesh_url": rec.internal_mesh_url,
        "state": rec.state.value,
        "reachable": True,
        "ttl_remaining_seconds": rec.ttl_remaining_seconds,
        "expiry_warning": rec.expiry_warning,
    }


@router.websocket("/{environment_id}/telemetry")
async def stream_environment_telemetry(websocket: WebSocket, environment_id: str) -> None:
    """Stream the environment's lifecycle events as JSON frames, then close normally.

    Unknown environments are refused with close code 4404 before accept.
    """
    rec = GLOBAL_ENVIRONMENT_REGISTRY.get(environment_id)
    if not rec:
        await websocket.close(code=4404)
        return
    await websocket.accept()
    with GLOBAL_ENVIRONMENT_REGISTRY._lock:
        events = [dict(e) for e in rec.events]
    for event in events:
        await websocket.send_json({"environment_id": rec.id, **event})
    await websocket.send_json({"environment_id": rec.id, "event": "stream_end", "count": len(events)})
    await websocket.close(code=1000)


def install_environment_routing_api(app: FastAPI) -> None:
    """Install environment routing router and registry on the FastAPI application."""
    app.include_router(router)

    @app.middleware("http")
    async def eap_security_headers(request: Request, call_next):
        response = await call_next(request)
        if request.url.path.startswith(router.prefix):
            for name, value in EAP_SECURITY_HEADERS.items():
                response.headers[name] = value
        return response

    app.state.environment_registry = GLOBAL_ENVIRONMENT_REGISTRY
    logger.info("Installed Signal Loom on-demand environment routing API at /api/v1/environments")
