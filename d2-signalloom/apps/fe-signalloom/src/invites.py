"""Self-service invites: a superadmin issues one, a Dex identity redeems it.

Before migration 053 a new pilot user was three edits by ControlPlane: a Dex
static user, an entry in the ``API_SUBJECT_TENANTS`` environment map of the
``fe-signalloom`` Deployment, and a rollout. The first edit remains (Dex is
the identity provider and this portal does not create identities). This module
replaces the second and third with data.

The three routes, and the property each protects:

* ``POST /api/v1/invites`` -- ``require_superadmin``. Returns the one-time
  token exactly once; the table keeps only its sha256. A leaked database dump
  therefore contains no redeemable secret.
* ``POST /api/v1/invites/redeem`` -- a *verified* Dex identity, bound to a
  tenant or not. ``authenticated_principal`` refuses an unbound subject with
  ``403 tenant_forbidden``, which is correct everywhere except here: the
  purpose of redeeming is to acquire a tenant. So this route verifies the
  bearer with the same checks (``verified_bearer_claims``) and skips only the
  tenant decision. An identity already bound to a *different* tenant is
  refused with 409 rather than silently moved.
* ``GET /api/v1/invites`` -- ``require_superadmin``; never returns a token or
  a hash.

``authenticated_principal`` consults ``subject_tenants`` before the
environment map, with a short per-subject cache that redeem invalidates, so a
subject bound here is live on its next request without a rollout.
"""
from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field, field_validator

from api_compat import (
    ERROR_RESPONSES,
    APIError,
    Principal,
    _audit_log,
    _email_claim,
    _require_pool,
    _write,
    invalidate_subject_binding,
    lookup_subject_binding,
    settings,
    verified_bearer_claims,
)
from superadmin import require_superadmin

router = APIRouter(tags=["invites"])

#: Seven days: long enough to cover a weekend between the email and the
#: first sign-in, short enough that a forgotten invite is not a standing door.
INVITE_LIFETIME = timedelta(days=7)
#: 32 bytes of entropy, URL-safe, so the token survives an email client.
_TOKEN_BYTES = 32
#: Upper bound on one listing; the pilot has tens of invites, not thousands.
_LIST_LIMIT = 200

EVENT_INVITE_CREATED = "invite.created"
EVENT_INVITE_REDEEMED = "invite.redeemed"

InviteStatus = Literal["pending", "redeemed", "expired"]


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _now() -> datetime:
    return datetime.now(timezone.utc)


class InviteCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: str = Field(min_length=3, max_length=254)
    tenant: str = Field(min_length=1, max_length=63)

    @field_validator("email")
    @classmethod
    def _email_shape(cls, value: str) -> str:
        value = value.strip().lower()
        local, at, domain = value.partition("@")
        if not at or not local or not domain or " " in value:
            raise ValueError("email must be a single address")
        return value

    @field_validator("tenant")
    @classmethod
    def _tenant_shape(cls, value: str) -> str:
        value = value.strip()
        # signal-ingest's acting-tenant pattern (ingest_client._TENANT_ID): a
        # tenant that cannot be presented to signal-ingest is not a tenant a
        # user can usefully be bound to.
        if not value or not all(c.isalnum() or c == "-" for c in value) or value[0] == "-" or not value.islower():
            raise ValueError("tenant must be lowercase letters, digits and hyphens")
        return value


class InviteSummary(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    email: str
    tenant: str
    created_by: str
    created_at: datetime
    expires_at: datetime
    redeemed_by: str | None = None
    redeemed_at: datetime | None = None
    status: InviteStatus


class InviteCreatedResponse(InviteSummary):
    #: Shown once. Not stored.
    token: str


class InviteListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    invites: list[InviteSummary]


class InviteRedeemRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    token: str = Field(min_length=16, max_length=256)


class InviteRedeemResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    subject: str
    tenant: str
    bound_via: str
    bound_at: datetime
    email: str | None = None


def _status_of(row: Any, now: datetime) -> InviteStatus:
    if row["redeemed_at"] is not None:
        return "redeemed"
    if row["expires_at"] <= now:
        return "expired"
    return "pending"


def _summary(row: Any, now: datetime) -> InviteSummary:
    return InviteSummary(
        id=str(row["id"]),
        email=row["email"],
        tenant=row["tenant"],
        created_by=row["created_by"],
        created_at=row["created_at"],
        expires_at=row["expires_at"],
        redeemed_by=row["redeemed_by"],
        redeemed_at=row["redeemed_at"],
        status=_status_of(row, now),
    )


async def _invites_pool(what: str) -> Any:
    """The pool, or 503: an invite with nowhere to live is not an invite.

    ``_require_pool`` answers ``None`` for fixture mode, where the in-memory
    audit twin stands in for the audit table. There is no in-memory twin for a
    binding that has to survive the next request, so this module refuses
    rather than pretending.
    """
    pool = await _require_pool(what)
    if pool is None:
        raise APIError(
            503, "database_unavailable", f"{what} requires the database, and this deployment has none",
        )
    return pool


@router.post(
    "/api/v1/invites",
    response_model=InviteCreatedResponse,
    responses=ERROR_RESPONSES,
    status_code=201,
)
async def create_invite(
    body: InviteCreateRequest,
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> InviteCreatedResponse:
    """Issue a one-time invite. Superadmin only; the token is returned once."""
    pool = await _invites_pool("invite creation")
    token = secrets.token_urlsafe(_TOKEN_BYTES)
    now = _now()
    expires_at = now + INVITE_LIFETIME
    async with _write(pool) as conn:
        row = await conn.fetchrow(
            """INSERT INTO invites (token_hash, email, tenant, created_by, created_at, expires_at)
               VALUES ($1, $2, $3, $4, $5, $6)
               RETURNING id, email, tenant, created_by, created_at, expires_at, redeemed_by, redeemed_at""",
            hash_token(token), body.email, body.tenant, principal.actor, now, expires_at,
        )
        if row is None:
            raise APIError(500, "invite_not_recorded", "The invite insert returned no row")
        # Filed under the invite's tenant, not the superadmin's own: the tenant
        # whose membership changed is the one whose audit trail must show it.
        await _audit_log(
            conn, body.tenant, "invite.created", None, None, principal.actor,
            {"invite_id": str(row["id"]), "email": body.email, "tenant": body.tenant, "expires_at": expires_at},
        )
    summary = _summary(row, now)
    return InviteCreatedResponse(**summary.model_dump(), token=token)


@router.get("/api/v1/invites", response_model=InviteListResponse, responses=ERROR_RESPONSES)
async def list_invites(
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> InviteListResponse:
    """Every invite, newest first, without tokens or hashes. Superadmin only."""
    pool = await _invites_pool("invite listing")
    rows = await pool.fetch(
        """SELECT id, email, tenant, created_by, created_at, expires_at, redeemed_by, redeemed_at
             FROM invites
            ORDER BY created_at DESC
            LIMIT $1""",
        _LIST_LIMIT,
    )
    now = _now()
    return InviteListResponse(invites=[_summary(row, now) for row in rows])


class RedeemingIdentity(BaseModel):
    """A verified Dex identity that may or may not have a tenant yet."""

    model_config = ConfigDict(extra="forbid")

    subject: str
    email: str | None
    #: The tenant the identity already has (binding table first, then the
    #: environment map), or ``None`` for a subject that has never been bound.
    current_tenant: str | None

    @property
    def actor(self) -> str:
        """Same rule as ``Principal.actor``: the token's own identity, never a literal."""
        return self.email or self.subject


async def redeeming_identity(
    authorization: Annotated[str | None, Header()] = None,
) -> RedeemingIdentity:
    """``authenticated_principal`` minus the tenant requirement.

    Same header shape, same signature and issuer checks, same host-credential
    refusal; the only thing not enforced is that the subject already has a
    tenant, because acquiring one is what the caller is here to do.
    """
    claims = verified_bearer_claims(authorization)
    subject = claims["sub"]
    current = await lookup_subject_binding(subject)
    if current is None:
        current = settings.api_subject_tenants.get(subject)
    return RedeemingIdentity(subject=subject, email=_email_claim(claims), current_tenant=current)


@router.post(
    "/api/v1/invites/redeem",
    response_model=InviteRedeemResponse,
    responses=ERROR_RESPONSES,
)
async def redeem_invite(
    body: InviteRedeemRequest,
    identity: Annotated[RedeemingIdentity, Depends(redeeming_identity)],
) -> InviteRedeemResponse:
    """Bind the caller's verified subject to the invite's tenant.

    * unknown token: 404 ``invite_not_found``
    * expired, or already redeemed: 410 ``invite_expired`` / ``invite_redeemed``
    * the token's ``email`` claim names someone else: 403 ``invite_email_mismatch``
    * the subject is already bound to another tenant: 409 ``tenant_mismatch``
    """
    pool = await _invites_pool("invite redemption")
    now = _now()
    async with _write(pool) as conn:
        invite = await conn.fetchrow(
            """SELECT id, email, tenant, expires_at, redeemed_by, redeemed_at
                 FROM invites
                WHERE token_hash = $1
                FOR UPDATE""",
            hash_token(body.token),
        )
        if invite is None:
            raise APIError(404, "invite_not_found", "No invite matches this token")
        if invite["redeemed_at"] is not None:
            raise APIError(410, "invite_redeemed", "This invite has already been redeemed")
        if invite["expires_at"] <= now:
            raise APIError(410, "invite_expired", "This invite has expired")
        if identity.email is not None and identity.email.strip().lower() != invite["email"]:
            raise APIError(
                403, "invite_email_mismatch", "This invite was issued to a different email address",
            )
        tenant = invite["tenant"]
        if identity.current_tenant is not None and identity.current_tenant != tenant:
            raise APIError(
                409,
                "tenant_mismatch",
                f"Subject is already bound to tenant {identity.current_tenant!r}; "
                f"this invite is for {tenant!r}",
            )

        await conn.execute(
            "UPDATE invites SET redeemed_by = $2, redeemed_at = $3 WHERE id = $1",
            invite["id"], identity.subject, now,
        )
        await conn.execute(
            """INSERT INTO subject_tenants (subject, tenant, bound_via, bound_at)
               VALUES ($1, $2, 'invite', $3)
               ON CONFLICT (subject) DO UPDATE
                 SET tenant = EXCLUDED.tenant, bound_via = EXCLUDED.bound_via, bound_at = EXCLUDED.bound_at""",
            identity.subject, tenant, now,
        )
        await _audit_log(
            conn, tenant, "invite.redeemed", None, None, identity.actor,
            {"invite_id": str(invite["id"]), "subject": identity.subject, "email": invite["email"], "tenant": tenant},
        )
    # The cache may hold "no binding" for this subject from the lookup a moment
    # ago; the next request must see the row, not the cache.
    invalidate_subject_binding(identity.subject)
    return InviteRedeemResponse(
        subject=identity.subject, tenant=tenant, bound_via="invite", bound_at=now, email=identity.email,
    )


def install_invites_api(app: Any) -> None:
    """Mount the invite router once."""
    for route in app.routes:
        if getattr(route, "endpoint", None) is create_invite:
            return
    app.include_router(router)
