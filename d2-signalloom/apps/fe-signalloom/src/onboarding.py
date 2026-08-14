"""Onboarding status and wizard-state API.

Backs the four calls in the dashboard's ``src/api/onboardingClient.ts``:

    GET  /api/onboarding/status     -> OnboardingStatus
    POST /api/onboarding/skip       -> OnboardingStatus
    POST /api/onboarding/complete   -> OnboardingStatus
    GET  /api/onboarding/state      -> OnboardingWizardState
    PUT  /api/onboarding/state      -> OnboardingWizardState

Why this module exists
----------------------
The dashboard shipped the client but not the server. With no backend, the
client fell back to ``MOCK_MODE``, whose ``skip()`` sets a module-level variable
that resets on reload — so "Skip for now" never persisted and ``ProtectedRoute``
bounced every non-exempt route back to ``/onboarding``. The wizard was
inescapable on any tenant with zero connected connectors.

State model
-----------
One row per tenant in ``tenant_onboarding``. ``status`` is the terminal state
(``pending`` / ``completed`` / ``skipped``) and carries its date; database CHECK
constraints make "completed without a date" unrepresentable. In-progress wizard
navigation lives in ``wizard_state`` so a customer who starts on one device
resumes at the same step on another.

Scope is per tenant, not per user: the wizard connects organisation-level
identity providers, so the first person through the door completes it for the
org. ``authenticated_tenant`` is also the only identity the API has — there is
no users table, and the subject→tenant mapping is server-side config.

Transitions are additionally appended to ``audit_events`` so the history
("skipped in March, completed in June") survives without this table carrying an
event log of its own.
"""
from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from typing import Annotated, Any

import asyncpg
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from api_compat import (
    ERROR_RESPONSES,
    APIError,
    _audit_log,
    _ensure_tenant_settings,
    _get_pool,
    _write,
    authenticated_tenant,
)

router = APIRouter(prefix="/api", tags=["onboarding"])

ACTOR = "onboarding-api"


# ─── Wire contract ──────────────────────────────────────────────────────────
# Field names mirror the TypeScript interfaces in
# dashboard-signalloom/src/types/connectors.ts exactly. `skipped_at` is the only
# field the current client reads from the status response; `status` and
# `completed_at` are additive so the client can adopt them without a server
# change.


class OnboardingStatusResponse(BaseModel):
    skipped_at: str | None = None
    completed_at: str | None = None
    status: str = "pending"


class ProviderRunState(BaseModel):
    status: str
    error: str | None = None


class OnboardingWizardState(BaseModel):
    selected_provider_ids: list[str] = Field(default_factory=list)
    step_index: int = 0
    provider_run_state: dict[str, ProviderRunState] = Field(default_factory=dict)


# ─── In-memory fallback ─────────────────────────────────────────────────────
# Mirrors the pattern in api_compat: when Postgres is unavailable the API serves
# fixtures rather than 500ing, so the demo survives a database outage. This
# store is per-process and deliberately not persisted.

_STORE_LOCK = threading.Lock()
_FALLBACK: dict[str, dict[str, Any]] = {}


def _fallback_row(tenant_id: str) -> dict[str, Any]:
    return _FALLBACK.setdefault(
        tenant_id,
        {"status": "pending", "completed_at": None, "skipped_at": None, "wizard_state": {}},
    )


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    return str(value)


def _status_from(row: Any) -> OnboardingStatusResponse:
    return OnboardingStatusResponse(
        skipped_at=_iso(row["skipped_at"]),
        completed_at=_iso(row["completed_at"]),
        status=row["status"],
    )


async def _ensure_row(pool: asyncpg.Pool, tenant_id: str) -> asyncpg.Record:
    """Ensure a tenant_onboarding row exists; return it.

    The tenant_settings row is ensured first: tenant_onboarding.tenant_id is a
    foreign key onto it, so inserting without it would raise a
    ForeignKeyViolation on a tenant whose settings row has not been created yet.
    """
    await _ensure_tenant_settings(pool, tenant_id)
    row = await pool.fetchrow(
        "SELECT * FROM tenant_onboarding WHERE tenant_id = $1", tenant_id,
    )
    if row is not None:
        return row
    await pool.execute(
        """INSERT INTO tenant_onboarding (tenant_id)
           VALUES ($1)
           ON CONFLICT (tenant_id) DO NOTHING""",
        tenant_id,
    )
    row = await pool.fetchrow(
        "SELECT * FROM tenant_onboarding WHERE tenant_id = $1", tenant_id,
    )
    if row is None:
        raise APIError(500, "internal_error", "Failed to initialize onboarding state")
    return row


async def _terminal_transition(
    tenant_id: str, status: str, column: str, event_type: str,
) -> OnboardingStatusResponse:
    """Move a tenant to a terminal onboarding status, idempotently.

    Re-skipping or re-completing keeps the ORIGINAL timestamp rather than
    refreshing it: the date answers "when did this tenant finish onboarding",
    and a double-clicked button must not rewrite that answer. The guard is in
    SQL (``WHERE status <> $1``) rather than a read-then-write in Python, so two
    concurrent requests cannot both pass a check and race on the update.

    The UPDATE and its audit insert share one ``_write`` transaction. They used
    to be two statements against the pool, and every pool statement is its own
    autocommit — so a rejected audit row left the tenant marked completed with
    nothing recording when. That is the precise failure migration 007 was
    written about; it was fixed across api_compat.py and missed here, because
    this module sits outside the file ``test_write_transactions.py`` covered.

    It matters more here than the shape suggests: ``tenant_onboarding`` holds
    only the terminal state, so the ``audit_events`` row is the sole durable
    evidence that the transition ever happened. Losing it leaves the product
    asserting a completion it cannot evidence.
    """
    pool = await _get_pool()
    now = datetime.now(timezone.utc)

    if pool is None:
        with _STORE_LOCK:
            row = _fallback_row(tenant_id)
            if row["status"] != status:
                row["status"] = status
                row[column] = now
            return _status_from(row)

    await _ensure_row(pool, tenant_id)

    async with _write(pool) as conn:
        updated = await conn.fetchrow(
            f"""UPDATE tenant_onboarding
                   SET status = $2, {column} = $3
                 WHERE tenant_id = $1 AND status <> $2
             RETURNING *""",
            tenant_id, status, now,
        )
        # No row came back: the guard held, nothing moved, and an audit row for
        # a transition that did not happen would be a fabrication of exactly
        # the kind this trail is supposed to be free of.
        if updated is not None:
            await _audit_log(
                conn,
                tenant_id=tenant_id,
                event_type=event_type,
                agent_id=None,
                agent_name=None,
                actor=ACTOR,
                detail={"status": status, "at": _iso(now)},
            )

    if updated is None:
        # Already in this status — return the existing row untouched. Read
        # after the block, not inside it: a read taken on the transaction's
        # connection could not see anything another request had committed.
        existing = await pool.fetchrow(
            "SELECT * FROM tenant_onboarding WHERE tenant_id = $1", tenant_id,
        )
        return _status_from(existing)

    return _status_from(updated)


# ─── Routes ─────────────────────────────────────────────────────────────────


@router.get("/onboarding/status", response_model=OnboardingStatusResponse, responses=ERROR_RESPONSES)
async def onboarding_status(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> OnboardingStatusResponse:
    pool = await _get_pool()
    if pool is None:
        with _STORE_LOCK:
            return _status_from(_fallback_row(tenant_id))
    return _status_from(await _ensure_row(pool, tenant_id))


@router.post("/onboarding/skip", response_model=OnboardingStatusResponse, responses=ERROR_RESPONSES)
async def onboarding_skip(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> OnboardingStatusResponse:
    return await _terminal_transition(tenant_id, "skipped", "skipped_at", "onboarding_skipped")


@router.post("/onboarding/complete", response_model=OnboardingStatusResponse, responses=ERROR_RESPONSES)
async def onboarding_complete(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> OnboardingStatusResponse:
    return await _terminal_transition(tenant_id, "completed", "completed_at", "onboarding_completed")


@router.get("/onboarding/state", response_model=OnboardingWizardState, responses=ERROR_RESPONSES)
async def onboarding_get_state(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> OnboardingWizardState:
    pool = await _get_pool()
    if pool is None:
        with _STORE_LOCK:
            return OnboardingWizardState(**_fallback_row(tenant_id)["wizard_state"])
    row = await _ensure_row(pool, tenant_id)
    raw = row["wizard_state"]
    # asyncpg returns JSONB as str unless a codec is registered.
    return OnboardingWizardState(**(json.loads(raw) if isinstance(raw, str) else (raw or {})))


@router.put("/onboarding/state", response_model=OnboardingWizardState, responses=ERROR_RESPONSES)
async def onboarding_put_state(
    state: OnboardingWizardState,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> OnboardingWizardState:
    payload = state.model_dump()
    pool = await _get_pool()
    if pool is None:
        with _STORE_LOCK:
            _fallback_row(tenant_id)["wizard_state"] = payload
            return state

    await _ensure_row(pool, tenant_id)
    await pool.execute(
        """UPDATE tenant_onboarding
              SET wizard_state = $2::jsonb
            WHERE tenant_id = $1""",
        tenant_id, json.dumps(payload),
    )
    return state


def install_onboarding_api(app: Any) -> None:
    app.include_router(router)
