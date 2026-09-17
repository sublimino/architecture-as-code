# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/environment_lifecycle.py
# Signal Loom EAP Lifecycle, Heartbeat & Auto-Reaping Daemon (SLED)
#
# Provides deterministic state machine management (PROVISIONING, WARMING,
# ACTIVE, DRAINING, TERMINATED), heartbeat lease renewal with hard lifetime caps,
# idle activity detection, and automated multi-stage reaping deallocation.
# ==============================================================================
from __future__ import annotations

import asyncio
import enum
import logging
import threading
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field, ConfigDict
from fastapi import APIRouter, FastAPI, HTTPException, status

from environment_routing import derive_customer_hash

logger = logging.getLogger("signalloom.lifecycle")

# Authoritative timeouts and ceilings
DEFAULT_LEASE_MINUTES = 120
MAX_LIFETIME_HOURS = 8
IDLE_TIMEOUT_MINUTES = 30
GRACE_PERIOD_SECONDS = 300


class EnvironmentLifecycleState(str, enum.Enum):
    PROVISIONING = "provisioning"
    WARMING = "warming"
    ACTIVE = "active"
    DRAINING = "draining"
    TERMINATED = "terminated"


# Permitted lifecycle state transition graph
VALID_TRANSITIONS: Dict[EnvironmentLifecycleState, set[EnvironmentLifecycleState]] = {
    EnvironmentLifecycleState.PROVISIONING: {
        EnvironmentLifecycleState.WARMING,
        EnvironmentLifecycleState.ACTIVE,
        EnvironmentLifecycleState.DRAINING,
        EnvironmentLifecycleState.TERMINATED,
    },
    EnvironmentLifecycleState.WARMING: {
        EnvironmentLifecycleState.ACTIVE,
        EnvironmentLifecycleState.DRAINING,
        EnvironmentLifecycleState.TERMINATED,
    },
    EnvironmentLifecycleState.ACTIVE: {
        EnvironmentLifecycleState.DRAINING,
        EnvironmentLifecycleState.TERMINATED,
    },
    EnvironmentLifecycleState.DRAINING: {
        EnvironmentLifecycleState.TERMINATED,
    },
    EnvironmentLifecycleState.TERMINATED: set(),
}


class LifecycleRecord(BaseModel):
    """Immutable state snapshot of an on-demand environment's lifecycle."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    customer_hash: str = Field(..., min_length=8, max_length=8, description="Canonical salted 8-char hex hash")
    company_name: str = Field(..., min_length=1, max_length=64, description="Customer company name")
    state: EnvironmentLifecycleState = Field(default=EnvironmentLifecycleState.PROVISIONING)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    last_heartbeat_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    last_activity_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    expires_at: datetime = Field(..., description="Current lease expiration")
    max_lifetime_expires_at: datetime = Field(..., description="Absolute unextendable lifetime cap")
    grace_period_expires_at: Optional[datetime] = Field(default=None, description="Expiration of draining grace period")
    reap_reason: Optional[str] = Field(default=None, description="Reason triggering transition to DRAINING/TERMINATED")
    teardown_stages_completed: List[str] = Field(default_factory=list, description="Stages of teardown pipeline finished")

    @property
    def ttl_remaining_seconds(self) -> int:
        now = datetime.now(timezone.utc)
        diff = (self.expires_at - now).total_seconds()
        return max(0, int(diff))

    @property
    def max_lifetime_remaining_seconds(self) -> int:
        now = datetime.now(timezone.utc)
        diff = (self.max_lifetime_expires_at - now).total_seconds()
        return max(0, int(diff))

    @property
    def idle_seconds(self) -> int:
        now = datetime.now(timezone.utc)
        diff = (now - self.last_activity_at).total_seconds()
        return max(0, int(diff))


class HeartbeatRequest(BaseModel):
    """Request payload to register a heartbeat and request lease extension."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    client_id: Optional[str] = Field(default=None, max_length=64, description="Optional calling agent or client id")
    extend_minutes: Optional[int] = Field(default=60, ge=1, le=240, description="Minutes to extend lease by")


class HeartbeatResponse(BaseModel):
    """Response payload acknowledging heartbeat and reporting updated lease."""
    customer_hash: str
    company_name: str
    state: EnvironmentLifecycleState
    last_heartbeat_at: datetime
    expires_at: datetime
    ttl_remaining_seconds: int
    max_lifetime_remaining_seconds: int
    extended: bool


class RegisterEnvironmentRequest(BaseModel):
    """Payload to register an environment under lifecycle governance."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    company_name: str = Field(..., min_length=1, max_length=64)
    customer_hash: Optional[str] = Field(default=None, min_length=8, max_length=8)
    ttl_minutes: Optional[int] = Field(default=DEFAULT_LEASE_MINUTES, ge=5, le=480)


class LifecycleManager:
    """Thread-safe lifecycle controller managing heartbeats, state transitions, and reaping."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._records: Dict[str, LifecycleRecord] = {}

    def register_environment(
        self,
        company_name: str,
        customer_hash: Optional[str] = None,
        ttl_minutes: int = DEFAULT_LEASE_MINUTES
    ) -> LifecycleRecord:
        """Register an environment into the lifecycle state machine."""
        h = (customer_hash or derive_customer_hash(company_name)).lower()
        now = datetime.now(timezone.utc)
        expires = now + timedelta(minutes=ttl_minutes)
        max_expires = now + timedelta(hours=MAX_LIFETIME_HOURS)

        with self._lock:
            if h in self._records and self._records[h].state not in (EnvironmentLifecycleState.TERMINATED,):
                logger.info("Environment %s already tracked under lifecycle state %s", h, self._records[h].state)
                return self._records[h]

            rec = LifecycleRecord(
                customer_hash=h,
                company_name=company_name,
                state=EnvironmentLifecycleState.PROVISIONING,
                created_at=now,
                last_heartbeat_at=now,
                last_activity_at=now,
                expires_at=expires,
                max_lifetime_expires_at=max_expires,
                teardown_stages_completed=[]
            )
            self._records[h] = rec
            logger.info("Registered environment %s for lifecycle management (TTL %dm)", h, ttl_minutes)
            return rec

    def transition_state(
        self,
        customer_hash: str,
        new_state: EnvironmentLifecycleState,
        reason: str = ""
    ) -> LifecycleRecord:
        """Transition an environment to a new state if allowed by transition graph."""
        h = customer_hash.lower()
        with self._lock:
            if h not in self._records:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Environment '{customer_hash}' not tracked by lifecycle manager."
                )

            rec = self._records[h]
            if new_state not in VALID_TRANSITIONS[rec.state]:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"Invalid lifecycle transition from {rec.state.value} to {new_state.value}."
                )

            now = datetime.now(timezone.utc)
            grace = None
            if new_state == EnvironmentLifecycleState.DRAINING:
                grace = now + timedelta(seconds=GRACE_PERIOD_SECONDS)

            updated = LifecycleRecord(
                customer_hash=rec.customer_hash,
                company_name=rec.company_name,
                state=new_state,
                created_at=rec.created_at,
                last_heartbeat_at=rec.last_heartbeat_at,
                last_activity_at=rec.last_activity_at,
                expires_at=rec.expires_at,
                max_lifetime_expires_at=rec.max_lifetime_expires_at,
                grace_period_expires_at=grace,
                reap_reason=reason or rec.reap_reason,
                teardown_stages_completed=list(rec.teardown_stages_completed)
            )
            self._records[h] = updated
            logger.info("Transitioned %s: %s -> %s (reason: %s)", h, rec.state.value, new_state.value, reason)
            return updated

    def record_heartbeat(
        self,
        customer_hash: str,
        extend_minutes: Optional[int] = 60
    ) -> HeartbeatResponse:
        """Process heartbeat and extend lease up to the hard maximum lifetime ceiling."""
        h = customer_hash.lower()
        now = datetime.now(timezone.utc)

        with self._lock:
            if h not in self._records:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Environment '{customer_hash}' not found for heartbeat."
                )

            rec = self._records[h]
            if rec.state in (EnvironmentLifecycleState.DRAINING, EnvironmentLifecycleState.TERMINATED):
                raise HTTPException(
                    status_code=status.HTTP_410_GONE,
                    detail=f"Cannot heartbeat environment in {rec.state.value} state."
                )

            ext = extend_minutes or 60
            candidate_expires = rec.expires_at + timedelta(minutes=ext)
            # Bound strictly by max_lifetime_expires_at
            bounded_expires = min(candidate_expires, rec.max_lifetime_expires_at)
            extended = bounded_expires > rec.expires_at

            updated = LifecycleRecord(
                customer_hash=rec.customer_hash,
                company_name=rec.company_name,
                state=rec.state,
                created_at=rec.created_at,
                last_heartbeat_at=now,
                last_activity_at=now,
                expires_at=bounded_expires,
                max_lifetime_expires_at=rec.max_lifetime_expires_at,
                grace_period_expires_at=rec.grace_period_expires_at,
                reap_reason=rec.reap_reason,
                teardown_stages_completed=list(rec.teardown_stages_completed)
            )
            self._records[h] = updated
            logger.info("Heartbeat recorded for %s; extended=%s, ttl_sec=%d", h, extended, updated.ttl_remaining_seconds)

            return HeartbeatResponse(
                customer_hash=h,
                company_name=updated.company_name,
                state=updated.state,
                last_heartbeat_at=now,
                expires_at=updated.expires_at,
                ttl_remaining_seconds=updated.ttl_remaining_seconds,
                max_lifetime_remaining_seconds=updated.max_lifetime_remaining_seconds,
                extended=extended
            )

    def record_activity(self, customer_hash: str, source: str = "traffic") -> LifecycleRecord:
        """Record active user, webhook, or network interaction resetting idle timer."""
        h = customer_hash.lower()
        now = datetime.now(timezone.utc)
        with self._lock:
            if h not in self._records:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Environment not found")
            rec = self._records[h]
            updated = LifecycleRecord(
                customer_hash=rec.customer_hash,
                company_name=rec.company_name,
                state=rec.state,
                created_at=rec.created_at,
                last_heartbeat_at=rec.last_heartbeat_at,
                last_activity_at=now,
                expires_at=rec.expires_at,
                max_lifetime_expires_at=rec.max_lifetime_expires_at,
                grace_period_expires_at=rec.grace_period_expires_at,
                reap_reason=rec.reap_reason,
                teardown_stages_completed=list(rec.teardown_stages_completed)
            )
            self._records[h] = updated
            logger.debug("Recorded activity for %s via source %s", h, source)
            return updated

    def evaluate_reaping(self, now: Optional[datetime] = None) -> List[Dict[str, Any]]:
        """Scan environments and advance lifecycle states for expired or idle instances."""
        current_time = now or datetime.now(timezone.utc)
        actions = []

        with self._lock:
            for h, rec in list(self._records.items()):
                # Case 1: Active/Warming/Provisioning expired -> DRAINING
                if rec.state in (EnvironmentLifecycleState.ACTIVE, EnvironmentLifecycleState.WARMING, EnvironmentLifecycleState.PROVISIONING):
                    # Check TTL expiration or absolute ceiling
                    if current_time >= rec.expires_at or current_time >= rec.max_lifetime_expires_at:
                        reason = "ttl_expired" if current_time >= rec.expires_at else "max_lifetime_exceeded"
                        self.transition_state(h, EnvironmentLifecycleState.DRAINING, reason=reason)
                        actions.append({"customer_hash": h, "action": "draining", "reason": reason})
                        continue

                    # Check idle expiration (30m without activity)
                    idle_limit = rec.last_activity_at + timedelta(minutes=IDLE_TIMEOUT_MINUTES)
                    if current_time >= idle_limit:
                        reason = "idle_timeout"
                        self.transition_state(h, EnvironmentLifecycleState.DRAINING, reason=reason)
                        actions.append({"customer_hash": h, "action": "draining", "reason": reason})
                        continue

                # Case 2: Draining passed grace period -> TERMINATED
                elif rec.state == EnvironmentLifecycleState.DRAINING:
                    grace_exp = rec.grace_period_expires_at or (rec.expires_at + timedelta(seconds=GRACE_PERIOD_SECONDS))
                    if current_time >= grace_exp:
                        self.transition_state(h, EnvironmentLifecycleState.TERMINATED, reason="grace_period_expired")
                        actions.append({"customer_hash": h, "action": "terminated", "reason": "grace_period_expired"})

        return actions

    def get_lifecycle(self, customer_hash: str) -> Optional[LifecycleRecord]:
        """Retrieve lifecycle record by customer hash."""
        with self._lock:
            return self._records.get(customer_hash.lower())

    def list_active(self) -> List[LifecycleRecord]:
        """List all non-terminated environments."""
        with self._lock:
            return [r for r in self._records.values() if r.state != EnvironmentLifecycleState.TERMINATED]


GLOBAL_LIFECYCLE_MANAGER = LifecycleManager()


# ==============================================================================
# FastAPI Routing & Endpoints
# ==============================================================================

router = APIRouter(prefix="/api/v1/eap/lifecycle", tags=["eap-lifecycle-governance"])


@router.post("/register", response_model=LifecycleRecord, status_code=status.HTTP_201_CREATED)
async def api_register_lifecycle(req: RegisterEnvironmentRequest) -> LifecycleRecord:
    """Register an environment into the lifecycle governance engine."""
    return GLOBAL_LIFECYCLE_MANAGER.register_environment(
        company_name=req.company_name,
        customer_hash=req.customer_hash,
        ttl_minutes=req.ttl_minutes or DEFAULT_LEASE_MINUTES
    )


@router.post("/environments/{customer_hash}/heartbeat", response_model=HeartbeatResponse)
async def api_heartbeat(customer_hash: str, req: HeartbeatRequest) -> HeartbeatResponse:
    """Record heartbeat and request lease renewal."""
    return GLOBAL_LIFECYCLE_MANAGER.record_heartbeat(
        customer_hash=customer_hash,
        extend_minutes=req.extend_minutes
    )


@router.post("/environments/{customer_hash}/activity", response_model=LifecycleRecord)
async def api_record_activity(customer_hash: str) -> LifecycleRecord:
    """Touch environment activity timer."""
    return GLOBAL_LIFECYCLE_MANAGER.record_activity(customer_hash, source="api_touch")


@router.get("/environments/{customer_hash}", response_model=LifecycleRecord)
async def api_get_lifecycle(customer_hash: str) -> LifecycleRecord:
    """Retrieve current lifecycle status for an environment."""
    rec = GLOBAL_LIFECYCLE_MANAGER.get_lifecycle(customer_hash)
    if not rec:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Environment not found")
    return rec


@router.get("/active", response_model=List[LifecycleRecord])
async def api_list_active_lifecycle() -> List[LifecycleRecord]:
    """List all active (non-terminated) environments."""
    return GLOBAL_LIFECYCLE_MANAGER.list_active()


@router.post("/reap-now")
async def api_trigger_reaping_pass() -> Dict[str, Any]:
    """Manually trigger an authoritative reaping evaluation pass."""
    actions = GLOBAL_LIFECYCLE_MANAGER.evaluate_reaping()
    return {
        "status": "completed",
        "evaluated_at": datetime.now(timezone.utc).isoformat(),
        "actions": actions,
        "actions_count": len(actions)
    }


def install_environment_lifecycle_api(app: FastAPI) -> None:
    """Mount lifecycle API router into FastAPI application."""
    app.include_router(router)
