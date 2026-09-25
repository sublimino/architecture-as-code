# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/environment_lifecycle.py
# Signal Loom EAP Lifecycle, Heartbeat & Auto-Reaping Daemon (SLED)
#
# Provides deterministic state machine management (PROVISIONING, WARMING,
# ACTIVE, DRAINING, TERMINATED), heartbeat lease renewal with hard lifetime caps,
# idle activity detection, automated multi-stage reaping deallocation,
# adaptive polling scheduling, dead-letter queuing, and memory RSS watchdog.
# ==============================================================================
from __future__ import annotations

import asyncio
from contextlib import contextmanager
import enum
import logging
import os
import resource
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from typing import Annotated, Any, Callable, Dict, Generator, List, Optional, Set
from pydantic import BaseModel, ConfigDict, Field
from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Response, status

import api_compat
from eap_tenancy import CUSTOMER_HASH_PATTERN, CustomerHash, Tenant, claim_or_403, owned_hashes, require_owned_or_404
from environment_routing import derive_customer_hash
from superadmin import require_superadmin

#: The reaper is one process-wide daemon: pausing it, forcing a pass, or reading
#: its diagnostics acts on every tenant's environments at once, so those
#: operations cannot be bound to a single tenant.  They are bound to the
#: operator role instead (EAPR-P2-1, after cross-vendor review): a tenant
#: principal gets 403 ``superadmin_required``; the tenant-scoped reads and
#: writes (``/active``, ``/reaper/dlq``, ``/audit-events`` …) stay tenant-bound.
Operator = Annotated[api_compat.Principal, Depends(require_superadmin)]

from eap_audit import _audit_eap_decision
from scenario_seeding import GLOBAL_SCENARIO_MANAGER, ScenarioType

from eap_contract import (
    HEARTBEAT_WINDOW_SECONDS,
    MAX_INITIAL_TTL_MINUTES,
    MAX_LIFETIME_HOURS,
    SPIFFE_TRUST_DOMAIN,
)

logger = logging.getLogger("signalloom.lifecycle")

# Authoritative timeouts, intervals, and ceilings
DEFAULT_LEASE_MINUTES = 120
IDLE_TIMEOUT_MINUTES = 30
GRACE_PERIOD_SECONDS = 300

DEFAULT_REAPER_INTERVAL_SECONDS = 30.0
MIN_REAPER_INTERVAL_SECONDS = 5.0
MAX_REAPER_INTERVAL_SECONDS = 120.0
LOCK_TIMEOUT_SECONDS = 5.0
MAX_RECONCILIATION_FAILURES = 3
MAX_RSS_BYTES = 50 * 1024 * 1024  # 50 MB bounded RSS limit
MASS_REAPING_ALERT_THRESHOLD = 5


class EnvironmentLifecycleState(str, enum.Enum):
    PROVISIONING = "provisioning"
    WARMING = "warming"
    ACTIVE = "active"
    DRAINING = "draining"
    TERMINATED = "terminated"
    TEARDOWN_FAILED = "teardown_failed"


# Permitted lifecycle state transition graph
VALID_TRANSITIONS: Dict[EnvironmentLifecycleState, set[EnvironmentLifecycleState]] = {
    EnvironmentLifecycleState.PROVISIONING: {
        EnvironmentLifecycleState.WARMING,
        EnvironmentLifecycleState.ACTIVE,
        EnvironmentLifecycleState.DRAINING,
        EnvironmentLifecycleState.TERMINATED,
        EnvironmentLifecycleState.TEARDOWN_FAILED,
    },
    EnvironmentLifecycleState.WARMING: {
        EnvironmentLifecycleState.ACTIVE,
        EnvironmentLifecycleState.DRAINING,
        EnvironmentLifecycleState.TERMINATED,
        EnvironmentLifecycleState.TEARDOWN_FAILED,
    },
    EnvironmentLifecycleState.ACTIVE: {
        EnvironmentLifecycleState.DRAINING,
        EnvironmentLifecycleState.TERMINATED,
        EnvironmentLifecycleState.TEARDOWN_FAILED,
    },
    EnvironmentLifecycleState.DRAINING: {
        EnvironmentLifecycleState.TERMINATED,
        EnvironmentLifecycleState.TEARDOWN_FAILED,
    },
    EnvironmentLifecycleState.TEARDOWN_FAILED: {
        EnvironmentLifecycleState.DRAINING,
        EnvironmentLifecycleState.TERMINATED,
        EnvironmentLifecycleState.TEARDOWN_FAILED,
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
    consecutive_reconciliation_failures: int = Field(default=0, description="Count of failed transition attempts")
    transition_timestamp_ns: Optional[int] = Field(default=None, description="Nanosecond timestamp of last transition")

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
    customer_hash: Optional[str] = Field(default=None, pattern=CUSTOMER_HASH_PATTERN)
    ttl_minutes: Optional[int] = Field(default=DEFAULT_LEASE_MINUTES, ge=5, le=480)


class DeadLetterRecord(BaseModel):
    """Record of an environment that repeatedly failed lifecycle reconciliation."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    customer_hash: str = Field(..., min_length=8, max_length=8)
    company_name: str
    state: EnvironmentLifecycleState
    failure_count: int
    last_error: str
    error_code: str
    enqueued_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    enqueued_at_ns: int = Field(default_factory=time.time_ns)


class ReaperAuditEvent(BaseModel):
    """Immutable audit event recording a lifecycle transition or administrative action."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    event_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    timestamp: str
    timestamp_ns: int
    customer_hash: str
    company_name: str
    previous_state: str
    current_state: str
    trigger_reason: str
    operator_or_system_id: str = "system:reaper-daemon"
    metadata: Dict[str, Any] = Field(default_factory=dict)


class ReaperStatusResponse(BaseModel):
    """Diagnostic status model for background reaper daemon."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    is_running: bool
    is_paused: bool
    cycle_count: int
    last_run_at: Optional[str] = None
    last_duration_ms: float = 0.0
    current_interval_seconds: float = DEFAULT_REAPER_INTERVAL_SECONDS
    active_environments_count: int = 0
    dlq_count: int = 0
    rss_bytes: int = 0
    rss_mb: float = 0.0
    memory_healthy: bool = True


class ReaperSummary(BaseModel):
    """Action summary returned after an authoritative reaping evaluation pass."""
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    status: str = "completed"
    evaluated_at: str
    evaluated_at_ns: int
    duration_ms: float = 0.0
    actions: List[Dict[str, Any]] = Field(default_factory=list)
    actions_count: int = 0
    active_remaining: int = 0
    dlq_routed_count: int = 0


# ==============================================================================
# Adaptive Interval Scheduler, Dead Letter Queue & Watchdogs
# ==============================================================================

class AdaptiveIntervalScheduler:
    """Dynamically adjusts polling interval based on fleet activity and idle state."""

    def __init__(
        self,
        base_interval: float = DEFAULT_REAPER_INTERVAL_SECONDS,
        min_interval: float = MIN_REAPER_INTERVAL_SECONDS,
        max_interval: float = MAX_REAPER_INTERVAL_SECONDS,
        backoff_factor: float = 1.5,
    ) -> None:
        self.base_interval = base_interval
        self.min_interval = min_interval
        self.max_interval = max_interval
        self.backoff_factor = backoff_factor
        self.consecutive_empty_cycles = 0
        self.current_interval = base_interval
        self._lock = threading.RLock()

    def record_cycle(self, active_count: int, actions_count: int) -> float:
        """Update interval based on activity in the latest reconciliation cycle."""
        with self._lock:
            if active_count == 0 and actions_count == 0:
                self.consecutive_empty_cycles += 1
                # Exponential backoff on sustained zero-environment fleet idle
                factor = self.backoff_factor ** min(self.consecutive_empty_cycles, 4)
                self.current_interval = min(self.max_interval, self.base_interval * factor)
            else:
                self.consecutive_empty_cycles = 0
                self.current_interval = self.base_interval
            return self.current_interval

    def get_interval(self) -> float:
        with self._lock:
            return self.current_interval

    def reset(self) -> None:
        with self._lock:
            self.consecutive_empty_cycles = 0
            self.current_interval = self.base_interval


class DeadLetterQueue:
    """Thread-safe queue storing environments that failed transitions across reconciliation cycles."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._entries: Dict[str, DeadLetterRecord] = {}

    def enqueue(self, record: DeadLetterRecord) -> None:
        with self._lock:
            self._entries[record.customer_hash.lower()] = record
            logger.warning(
                "Enqueued environment %s to Dead-Letter Queue (failures=%d, error=%s)",
                record.customer_hash,
                record.failure_count,
                record.last_error,
            )

    def get_all(self) -> List[DeadLetterRecord]:
        with self._lock:
            return list(self._entries.values())

    def get(self, customer_hash: str) -> Optional[DeadLetterRecord]:
        with self._lock:
            return self._entries.get(customer_hash.lower())

    def clear(self, customer_hash: Optional[str] = None) -> int:
        with self._lock:
            if customer_hash:
                h = customer_hash.lower()
                if h in self._entries:
                    del self._entries[h]
                    return 1
                return 0
            count = len(self._entries)
            self._entries.clear()
            return count

    def contains(self, customer_hash: str) -> bool:
        with self._lock:
            return customer_hash.lower() in self._entries

    def count(self) -> int:
        with self._lock:
            return len(self._entries)


class MemoryWatchdog:
    """Monitors RSS memory consumption of the worker process across extended runs."""

    def __init__(self, max_rss_bytes: int = MAX_RSS_BYTES) -> None:
        self.max_rss_bytes = max_rss_bytes

    def get_rss_bytes(self) -> int:
        """Measure resident set size (VmRSS) in bytes, falling back to ru_maxrss."""
        try:
            if os.path.exists("/proc/self/status"):
                with open("/proc/self/status", "r", encoding="utf-8") as f:
                    for line in f:
                        if line.startswith("VmRSS:"):
                            parts = line.split()
                            if len(parts) >= 2:
                                return int(parts[1]) * 1024
            # Fallback for non-Linux platforms
            logger.warning("Reading current VmRSS from /proc/self/status failed or unsupported; falling back to ru_maxrss")
            usage = resource.getrusage(resource.RUSAGE_SELF)
            return int(usage.ru_maxrss * 1024)
        except Exception as ex:
            logger.warning("Error reading memory RSS: %s", ex)
            return 0

    def check_rss(self) -> Dict[str, Any]:
        """Verify worker memory footprint remains bounded."""
        rss = self.get_rss_bytes()
        healthy = rss <= self.max_rss_bytes if rss > 0 else True
        if not healthy:
            logger.warning("Memory watchdog alert: RSS %d bytes exceeds bound %d", rss, self.max_rss_bytes)
        return {
            "rss_bytes": rss,
            "rss_mb": round(rss / (1024 * 1024), 2),
            "healthy": healthy,
            "max_rss_mb": round(self.max_rss_bytes / (1024 * 1024), 2),
        }


class ReaperAlertNotifier:
    """Manages notifications dispatched when abnormal or mass reaping events occur."""

    def __init__(self) -> None:
        self._handlers: List[Callable[[str, Dict[str, Any]], None]] = []
        self._lock = threading.RLock()

    def add_handler(self, handler: Callable[[str, Dict[str, Any]], None]) -> None:
        with self._lock:
            self._handlers.append(handler)

    def dispatch(self, event_type: str, details: Dict[str, Any]) -> None:
        with self._lock:
            logger.warning("REAPER ALERT [%s]: %s", event_type, details)
            for handler in self._handlers:
                try:
                    handler(event_type, details)
                except Exception as ex:
                    logger.exception("Error in reaper alert handler: %s", ex)


class PrometheusReaperMetrics:
    """Tracks Prometheus-compatible metrics for reaper duration, cycles, and state."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self.cycles_total: int = 0
        self.active_environments: int = 0
        self.reaped_total: Dict[str, int] = {}
        self.last_duration_seconds: float = 0.0
        self.dlq_total: int = 0

    def record_cycle(
        self,
        duration_seconds: float,
        active_count: int,
        actions: List[Dict[str, Any]],
        dlq_count: int,
    ) -> None:
        with self._lock:
            self.cycles_total += 1
            self.last_duration_seconds = duration_seconds
            self.active_environments = active_count
            self.dlq_total = dlq_count
            for a in actions:
                key = f"{a.get('action', 'unknown')}:{a.get('reason', 'unknown')}"
                self.reaped_total[key] = self.reaped_total.get(key, 0) + 1

    def get_metrics_summary(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "signalloom_eap_reaper_cycles_total": self.cycles_total,
                "signalloom_eap_active_environments": self.active_environments,
                "signalloom_eap_reaped_total": dict(self.reaped_total),
                "signalloom_eap_reaper_duration_seconds": self.last_duration_seconds,
                "signalloom_eap_dlq_total": self.dlq_total,
            }

    def render_openmetrics(self) -> str:
        """Render Prometheus/OpenMetrics text exposition format (ending with # EOF)."""
        with self._lock:
            lines: List[str] = [
                "# HELP signalloom_eap_reaper_cycles Total number of reaper reconciliation cycles executed.",
                "# TYPE signalloom_eap_reaper_cycles counter",
                f"signalloom_eap_reaper_cycles_total {self.cycles_total}",
                "# HELP signalloom_eap_active_environments Current number of active EAP environments.",
                "# TYPE signalloom_eap_active_environments gauge",
                f"signalloom_eap_active_environments {self.active_environments}",
                "# HELP signalloom_eap_dlq_total Current number of records in the dead letter queue.",
                "# TYPE signalloom_eap_dlq_total gauge",
                f"signalloom_eap_dlq_total {self.dlq_total}",
                "# HELP signalloom_eap_reaper_duration_seconds Duration of the last reaper reconciliation cycle in seconds.",
                "# TYPE signalloom_eap_reaper_duration_seconds histogram",
            ]

            buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
            dur = self.last_duration_seconds
            count = 1 if self.cycles_total > 0 else 0
            for b in buckets:
                cum = 1 if (count > 0 and dur <= b) else 0
                lines.append(f'signalloom_eap_reaper_duration_seconds_bucket{{le="{b}"}} {cum}')
            lines.append(f'signalloom_eap_reaper_duration_seconds_bucket{{le="+Inf"}} {count}')
            lines.append(f"signalloom_eap_reaper_duration_seconds_sum {dur if count > 0 else 0.0}")
            lines.append(f"signalloom_eap_reaper_duration_seconds_count {count}")

            lines.append("# HELP signalloom_eap_reaped Total number of environments reaped by action and reason.")
            lines.append("# TYPE signalloom_eap_reaped counter")
            if not self.reaped_total:
                lines.append('signalloom_eap_reaped_total{action="none",reason="none"} 0')
            else:
                for k, v in sorted(self.reaped_total.items()):
                    action, reason = k.split(":", 1) if ":" in k else (k, "unknown")
                    lines.append(f'signalloom_eap_reaped_total{{action="{action}",reason="{reason}"}} {v}')

            lines.append("# EOF")
            return "\n".join(lines) + "\n"


# ==============================================================================
# Lifecycle Manager
# ==============================================================================

class LifecycleManager:
    """Thread-safe lifecycle controller managing heartbeats, state transitions, and reaping."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._records: Dict[str, LifecycleRecord] = {}
        self._audit_log: List[ReaperAuditEvent] = []
        self._dlq = DeadLetterQueue()
        self._alert_notifier = ReaperAlertNotifier()
        self._metrics = PrometheusReaperMetrics()
        self._watchdog = MemoryWatchdog()

    @contextmanager
    def _acquire_lock(self, timeout: float = LOCK_TIMEOUT_SECONDS) -> Generator[None, None, None]:
        """Acquire re-entrant lock with bounded timeout to prevent indefinite deadlocks."""
        acquired = self._lock.acquire(timeout=timeout)
        if not acquired:
            raise TimeoutError(f"Failed to acquire lifecycle manager lock within {timeout:.1f}s")
        try:
            yield
        finally:
            self._lock.release()

    @property
    def dlq(self) -> DeadLetterQueue:
        return self._dlq

    @property
    def alert_notifier(self) -> ReaperAlertNotifier:
        return self._alert_notifier

    @property
    def metrics(self) -> PrometheusReaperMetrics:
        return self._metrics

    @property
    def watchdog(self) -> MemoryWatchdog:
        return self._watchdog

    def register_environment(
        self,
        company_name: str,
        customer_hash: Optional[str] = None,
        ttl_minutes: int = DEFAULT_LEASE_MINUTES,
    ) -> LifecycleRecord:
        """Register an environment into the lifecycle state machine."""
        h = (customer_hash or derive_customer_hash(company_name)).lower()
        now = datetime.now(timezone.utc)
        now_ns = time.time_ns()
        expires = now + timedelta(minutes=ttl_minutes)
        max_expires = now + timedelta(hours=MAX_LIFETIME_HOURS)

        with self._acquire_lock():
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
                teardown_stages_completed=[],
                consecutive_reconciliation_failures=0,
                transition_timestamp_ns=now_ns,
            )
            self._records[h] = rec
            self._emit_audit_event(
                customer_hash=h,
                company_name=company_name,
                previous_state="none",
                current_state=EnvironmentLifecycleState.PROVISIONING.value,
                trigger_reason="registration",
                operator_or_system_id="system:lifecycle-manager",
                metadata={"ttl_minutes": ttl_minutes},
            )
            logger.info("Registered environment %s for lifecycle management (TTL %dm)", h, ttl_minutes)
            try:
                GLOBAL_SCENARIO_MANAGER.execute_scenario(
                    ScenarioType.BASELINE_AGENT_FLOW,
                    company_name=company_name,
                    customer_hash=h,
                )
            except Exception as exc:
                logger.warning("Auto-seeding scenario failed for %s: %s", h, exc)
            return rec

    def transition_state(
        self,
        customer_hash: str,
        new_state: EnvironmentLifecycleState,
        reason: str = "",
        operator_or_system_id: str = "system:lifecycle-manager",
    ) -> LifecycleRecord:
        """Transition an environment to a new state if allowed by transition graph."""
        h = customer_hash.lower()
        now = datetime.now(timezone.utc)
        now_ns = time.time_ns()

        with self._acquire_lock():
            if h not in self._records:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Environment '{customer_hash}' not tracked by lifecycle manager.",
                )

            rec = self._records[h]
            if new_state not in VALID_TRANSITIONS[rec.state]:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"Invalid lifecycle transition from {rec.state.value} to {new_state.value}.",
                )

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
                grace_period_expires_at=grace if grace is not None else rec.grace_period_expires_at,
                reap_reason=reason or rec.reap_reason,
                teardown_stages_completed=list(rec.teardown_stages_completed),
                consecutive_reconciliation_failures=0,
                transition_timestamp_ns=now_ns,
            )
            self._records[h] = updated

            self._emit_audit_event(
                customer_hash=h,
                company_name=rec.company_name,
                previous_state=rec.state.value,
                current_state=new_state.value,
                trigger_reason=reason or "state_transition",
                operator_or_system_id=operator_or_system_id,
            )
            if new_state == EnvironmentLifecycleState.TERMINATED:
                try:
                    GLOBAL_SCENARIO_MANAGER.expunge(h)
                except Exception as exc:
                    logger.warning("Expunging scenario data failed for %s: %s", h, exc)
                try:
                    import host_enrollment
                    reap_principal = api_compat.Principal(
                        tenant=h,
                        subject="system:reaper-daemon",
                        email="system@reaper.internal",
                    )
                    try:
                        loop = asyncio.get_running_loop()
                        loop.create_task(host_enrollment.revoke_all_agents_for_tenant(h, reap_principal, "environment_reaped"))
                    except RuntimeError:
                        asyncio.run(host_enrollment.revoke_all_agents_for_tenant(h, reap_principal, "environment_reaped"))
                except Exception as exc:
                    logger.warning("Revoking agents for reaped environment %s failed: %s", h, exc)
            logger.info("Transitioned %s: %s -> %s (reason: %s)", h, rec.state.value, new_state.value, reason)
            return updated

    def record_heartbeat(
        self,
        customer_hash: str,
        extend_minutes: Optional[int] = 60,
    ) -> HeartbeatResponse:
        """Process heartbeat and extend lease up to the hard maximum lifetime ceiling."""
        h = customer_hash.lower()
        now = datetime.now(timezone.utc)
        now_ns = time.time_ns()

        with self._acquire_lock():
            if h not in self._records:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Environment '{customer_hash}' not found for heartbeat.",
                )

            rec = self._records[h]
            if rec.state in (EnvironmentLifecycleState.DRAINING, EnvironmentLifecycleState.TERMINATED):
                raise HTTPException(
                    status_code=status.HTTP_410_GONE,
                    detail=f"Cannot heartbeat environment in {rec.state.value} state.",
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
                teardown_stages_completed=list(rec.teardown_stages_completed),
                consecutive_reconciliation_failures=0,
                transition_timestamp_ns=now_ns,
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
                extended=extended,
            )

    def record_activity(self, customer_hash: str, source: str = "traffic") -> LifecycleRecord:
        """Record active user, webhook, or network interaction resetting idle timer."""
        h = customer_hash.lower()
        now = datetime.now(timezone.utc)
        with self._acquire_lock():
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
                teardown_stages_completed=list(rec.teardown_stages_completed),
                consecutive_reconciliation_failures=0,
                transition_timestamp_ns=rec.transition_timestamp_ns,
            )
            self._records[h] = updated
            logger.debug("Recorded activity for %s via source %s", h, source)
            return updated

    def evaluate_reaping(self, now: Optional[datetime] = None) -> List[Dict[str, Any]]:
        """Scan environments and advance lifecycle states for expired or idle instances."""
        current_time = now or datetime.now(timezone.utc)
        actions: List[Dict[str, Any]] = []

        with self._acquire_lock():
            # Dynamic priority ranking:
            # Priority 0: Expired TTL or Max Lifetime (negative TTL)
            # Priority 1: DRAINING environments past grace period
            # Priority 2: Inactivity exceeding idle timeout
            # Priority 3: Other active environments
            def _priority(item: tuple[str, LifecycleRecord]) -> int:
                try:
                    _, r = item
                    if r is None or not hasattr(r, "state"):
                        return 0
                    if r.state in (
                        EnvironmentLifecycleState.ACTIVE,
                        EnvironmentLifecycleState.WARMING,
                        EnvironmentLifecycleState.PROVISIONING,
                    ):
                        if r.expires_at is None or r.max_lifetime_expires_at is None:
                            return 0
                        if current_time >= r.expires_at or current_time >= r.max_lifetime_expires_at:
                            return 0
                        if r.last_activity_at is not None and current_time >= r.last_activity_at + timedelta(minutes=IDLE_TIMEOUT_MINUTES):
                            return 2
                    elif r.state == EnvironmentLifecycleState.DRAINING:
                        grace_exp = r.grace_period_expires_at or ((r.expires_at + timedelta(seconds=GRACE_PERIOD_SECONDS)) if r.expires_at else current_time)
                        if current_time >= grace_exp:
                            return 1
                    return 3
                except Exception:
                    return 0

            sorted_items = sorted(list(self._records.items()), key=_priority)

            for h, rec in sorted_items:
                try:
                    now_ns = time.time_ns()
                    now_iso = current_time.isoformat()

                    if rec is None or getattr(rec, "expires_at", None) is None or getattr(rec, "created_at", None) is None:
                        raise ValueError(f"Malformed environment record for {h}: missing required timestamps")

                    # Case 1: Active/Warming/Provisioning expired -> DRAINING
                    if rec.state in (
                        EnvironmentLifecycleState.ACTIVE,
                        EnvironmentLifecycleState.WARMING,
                        EnvironmentLifecycleState.PROVISIONING,
                    ):
                        # Check TTL expiration or absolute ceiling
                        if current_time >= rec.expires_at or current_time >= rec.max_lifetime_expires_at:
                            reason = "ttl_expired" if current_time >= rec.expires_at else "max_lifetime_exceeded"
                            self.transition_state(
                                h,
                                EnvironmentLifecycleState.DRAINING,
                                reason=reason,
                                operator_or_system_id="system:reaper-daemon",
                            )
                            actions.append({
                                "customer_hash": h,
                                "company_name": rec.company_name,
                                "action": "draining",
                                "reason": reason,
                                "trigger_reason": reason,
                                "previous_state": rec.state.value,
                                "current_state": EnvironmentLifecycleState.DRAINING.value,
                                "timestamp_iso": now_iso,
                                "timestamp_ns": now_ns,
                                "description": f"Environment {h} transitioned to DRAINING due to {reason}",
                                "error_code": None,
                            })
                            continue

                        # Check idle expiration (30m without activity)
                        idle_limit = (rec.last_activity_at or rec.created_at) + timedelta(minutes=IDLE_TIMEOUT_MINUTES)
                        if current_time >= idle_limit:
                            reason = "idle_timeout"
                            self.transition_state(
                                h,
                                EnvironmentLifecycleState.DRAINING,
                                reason=reason,
                                operator_or_system_id="system:reaper-daemon",
                            )
                            actions.append({
                                "customer_hash": h,
                                "company_name": rec.company_name,
                                "action": "draining",
                                "reason": reason,
                                "trigger_reason": reason,
                                "previous_state": rec.state.value,
                                "current_state": EnvironmentLifecycleState.DRAINING.value,
                                "timestamp_iso": now_iso,
                                "timestamp_ns": now_ns,
                                "description": f"Environment {h} transitioned to DRAINING due to {reason}",
                                "error_code": None,
                            })
                            continue

                    # Case 2: Draining passed grace period -> TERMINATED
                    elif rec.state == EnvironmentLifecycleState.DRAINING:
                        grace_exp = rec.grace_period_expires_at or (rec.expires_at + timedelta(seconds=GRACE_PERIOD_SECONDS))
                        if current_time >= grace_exp:
                            reason = "grace_period_expired"
                            self.transition_state(
                                h,
                                EnvironmentLifecycleState.TERMINATED,
                                reason=reason,
                                operator_or_system_id="system:reaper-daemon",
                            )
                            actions.append({
                                "customer_hash": h,
                                "company_name": rec.company_name,
                                "action": "terminated",
                                "reason": reason,
                                "trigger_reason": reason,
                                "previous_state": rec.state.value,
                                "current_state": EnvironmentLifecycleState.TERMINATED.value,
                                "timestamp_iso": now_iso,
                                "timestamp_ns": now_ns,
                                "description": f"Environment {h} transitioned to TERMINATED due to {reason}",
                                "error_code": None,
                            })

                except Exception as ex:
                    # Robust exception isolation: record error, increment failure count, route to DLQ
                    logger.exception("Reaper evaluation error on environment %s: %s", h, ex)
                    failures = (getattr(rec, "consecutive_reconciliation_failures", 0) or 0) + 1
                    try:
                        self._records[h] = rec.model_copy(update={"consecutive_reconciliation_failures": failures})
                    except Exception:
                        pass

                    dlq_rec = DeadLetterRecord(
                        customer_hash=h,
                        company_name=getattr(rec, "company_name", "unknown") or "unknown",
                        state=getattr(rec, "state", EnvironmentLifecycleState.ACTIVE) or EnvironmentLifecycleState.ACTIVE,
                        failure_count=failures,
                        last_error=str(ex),
                        error_code="ERR_TRANSITION_FAILED",
                    )
                    self._dlq.enqueue(dlq_rec)
                    self._alert_notifier.dispatch(
                        "dead_letter_enqueued",
                        {"customer_hash": h, "failure_count": failures, "error": str(ex)},
                    )

                    actions.append({
                        "customer_hash": h,
                        "company_name": getattr(rec, "company_name", "unknown") if rec else "unknown",
                        "action": "failed",
                        "reason": "transition_error",
                        "trigger_reason": "transition_error",
                        "previous_state": getattr(getattr(rec, "state", None), "value", "unknown") if rec else "unknown",
                        "current_state": getattr(getattr(rec, "state", None), "value", "unknown") if rec else "unknown",
                        "timestamp_iso": current_time.isoformat(),
                        "timestamp_ns": time.time_ns(),
                        "description": f"Reconciliation failed on {h}: {ex}",
                        "error_code": "ERR_TRANSITION_FAILED",
                    })

            # Check mass reaping threshold for alerting
            if len(actions) >= MASS_REAPING_ALERT_THRESHOLD:
                self._alert_notifier.dispatch(
                    "mass_reaping_triggered",
                    {"actions_count": len(actions), "evaluated_at": current_time.isoformat()},
                )

        return actions

    def _emit_audit_event(
        self,
        customer_hash: str,
        company_name: str,
        previous_state: str,
        current_state: str,
        trigger_reason: str,
        operator_or_system_id: str,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> ReaperAuditEvent:
        """Append an immutable audit event for compliance and traceability."""
        now = datetime.now(timezone.utc)
        event = ReaperAuditEvent(
            event_id=str(uuid.uuid4()),
            timestamp=now.isoformat(),
            timestamp_ns=time.time_ns(),
            customer_hash=customer_hash,
            company_name=company_name,
            previous_state=previous_state,
            current_state=current_state,
            trigger_reason=trigger_reason,
            operator_or_system_id=operator_or_system_id,
            metadata=metadata or {},
        )
        self._audit_log.append(event)
        # Bounded audit log retention in memory (keep last 1000 events)
        if len(self._audit_log) > 1000:
            self._audit_log = self._audit_log[-1000:]
        return event

    def get_lifecycle(self, customer_hash: str) -> Optional[LifecycleRecord]:
        """Retrieve lifecycle record by customer hash."""
        with self._acquire_lock():
            return self._records.get(customer_hash.lower())

    def list_active(self) -> List[LifecycleRecord]:
        """List all non-terminated environments."""
        with self._acquire_lock():
            return [r for r in self._records.values() if r.state != EnvironmentLifecycleState.TERMINATED]

    def get_audit_events(self, customer_hash: Optional[str] = None) -> List[ReaperAuditEvent]:
        """Retrieve recorded audit events."""
        with self._acquire_lock():
            if customer_hash:
                h = customer_hash.lower()
                return [e for e in self._audit_log if e.customer_hash == h]
            return list(self._audit_log)

    def record_teardown_stage(self, customer_hash: str, stage: str) -> LifecycleRecord:
        """Append a completed teardown stage (SLED-P3); a repeat call is a no-op."""
        h = customer_hash.lower()
        with self._acquire_lock():
            if h not in self._records:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Environment not found")
            rec = self._records[h]
            if stage in rec.teardown_stages_completed:
                return rec
            updated = rec.model_copy(update={"teardown_stages_completed": [*rec.teardown_stages_completed, stage]})
            self._records[h] = updated
            logger.info("Teardown stage %s recorded for %s", stage, h)
            return updated


# ==============================================================================
# Reaper Daemon (Background Worker)
# ==============================================================================

class ReaperDaemon:
    """Asynchronous background worker scanning and reaping expired EAP environments."""

    def __init__(
        self,
        lifecycle_manager: Optional[LifecycleManager] = None,
        base_interval: float = DEFAULT_REAPER_INTERVAL_SECONDS,
        min_interval: float = MIN_REAPER_INTERVAL_SECONDS,
        max_interval: float = MAX_REAPER_INTERVAL_SECONDS,
    ) -> None:
        self.lifecycle_manager = lifecycle_manager or GLOBAL_LIFECYCLE_MANAGER
        self.base_interval = base_interval
        self.min_interval = min_interval
        self.max_interval = max_interval
        self._scheduler = AdaptiveIntervalScheduler(
            base_interval=base_interval,
            min_interval=min_interval,
            max_interval=max_interval,
        )
        self._is_running: bool = False
        self._is_paused: bool = False
        self._task: Optional[asyncio.Task[None]] = None
        self._cycle_count: int = 0
        self._last_run_at: Optional[datetime] = None
        self._last_duration_ms: float = 0.0
        self._reconcile_lock = asyncio.Lock()
        self._active_pass_in_progress: bool = False

    @property
    def is_running(self) -> bool:
        """Derive liveness from task status and lifecycle state."""
        if not self._is_running:
            return False
        if self._task is None or self._task.done():
            return False
        return True

    @property
    def is_paused(self) -> bool:
        return self._is_paused

    @property
    def cycle_count(self) -> int:
        return self._cycle_count

    @property
    def scheduler(self) -> AdaptiveIntervalScheduler:
        return self._scheduler

    def pause(self) -> None:
        """Administrative pause suspending background reaping during emergency maintenance."""
        self._is_paused = True
        logger.warning("ReaperDaemon background reconciliation PAUSED by administrative command.")

    def resume(self) -> None:
        """Resume background reaping reconciliation passes."""
        self._is_paused = False
        self._scheduler.reset()
        logger.info("ReaperDaemon background reconciliation RESUMED.")

    def start(self) -> bool:
        """Start the background reaper loop if not already active."""
        if self._is_running and self._task and not self._task.done():
            logger.debug("ReaperDaemon is already running.")
            return False

        self._is_running = True
        try:
            loop = asyncio.get_running_loop()
            self._task = loop.create_task(self._loop(), name="sled-reaper-daemon")
            logger.info("ReaperDaemon started with base interval %.1fs", self.base_interval)
            return True
        except RuntimeError:
            # No running event loop in current thread
            logger.warning("ReaperDaemon start called without active asyncio event loop.")
            return False

    async def stop(self, timeout: float = 5.0) -> None:
        """Gracefully terminate background reaper task and await active drain."""
        if not self._is_running and (self._task is None or self._task.done()):
            return

        self._is_running = False
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await asyncio.wait_for(self._task, timeout=timeout)
            except (asyncio.CancelledError, asyncio.TimeoutError):
                pass

        # Wait for any active reconciliation pass in progress to finish
        deadline = time.monotonic() + timeout
        while self._active_pass_in_progress and time.monotonic() < deadline:
            await asyncio.sleep(0.05)

        logger.info("ReaperDaemon stopped cleanly.")

    async def run_reconciliation_pass(self, now: Optional[datetime] = None) -> ReaperSummary:
        """Execute a single atomic reconciliation pass across all environments."""
        async with self._reconcile_lock:
            self._active_pass_in_progress = True
            start_ns = time.perf_counter_ns()
            eval_time = now or datetime.now(timezone.utc)
            eval_time_iso = eval_time.isoformat()
            eval_time_ns = time.time_ns()

            try:
                # Offload evaluate_reaping from the event loop thread to worker threadpool
                actions = await asyncio.to_thread(self.lifecycle_manager.evaluate_reaping, eval_time)
                duration_ns = time.perf_counter_ns() - start_ns
                duration_ms = duration_ns / 1_000_000.0
                duration_sec = duration_ns / 1_000_000_000.0

                self._cycle_count += 1
                self._last_run_at = eval_time
                self._last_duration_ms = duration_ms

                active_envs = self.lifecycle_manager.list_active()
                active_count = len(active_envs)
                dlq_count = self.lifecycle_manager.dlq.count()

                # Update adaptive polling interval
                self._scheduler.record_cycle(active_count=active_count, actions_count=len(actions))

                # Update Prometheus metrics
                self.lifecycle_manager.metrics.record_cycle(
                    duration_seconds=duration_sec,
                    active_count=active_count,
                    actions=actions,
                    dlq_count=dlq_count,
                )

                # Check watchdog RSS
                self.lifecycle_manager.watchdog.check_rss()

                dlq_routed = sum(1 for a in actions if a.get("action") == "failed")

                return ReaperSummary(
                    status="completed",
                    evaluated_at=eval_time_iso,
                    evaluated_at_ns=eval_time_ns,
                    duration_ms=round(duration_ms, 3),
                    actions=actions,
                    actions_count=len(actions),
                    active_remaining=active_count,
                    dlq_routed_count=dlq_routed,
                )
            finally:
                self._active_pass_in_progress = False

    async def _loop(self) -> None:
        """Continuous background reconciliation loop with adaptive interval scheduling."""
        while self._is_running:
            try:
                if not self._is_paused:
                    await self.run_reconciliation_pass()
                interval = self._scheduler.get_interval()
                await asyncio.sleep(interval)
            except asyncio.CancelledError:
                break
            except Exception as ex:
                logger.exception("Unexpected error in ReaperDaemon loop: %s", ex)
                await asyncio.sleep(self.min_interval)

    def get_status(self) -> ReaperStatusResponse:
        """Produce comprehensive diagnostic status for health probes and dashboards."""
        active_count = len(self.lifecycle_manager.list_active())
        dlq_count = self.lifecycle_manager.dlq.count()
        rss_info = self.lifecycle_manager.watchdog.check_rss()

        return ReaperStatusResponse(
            is_running=self.is_running,
            is_paused=self._is_paused,
            cycle_count=self._cycle_count,
            last_run_at=self._last_run_at.isoformat() if self._last_run_at else None,
            last_duration_ms=round(self._last_duration_ms, 3),
            current_interval_seconds=self._scheduler.get_interval(),
            active_environments_count=active_count,
            dlq_count=dlq_count,
            rss_bytes=rss_info["rss_bytes"],
            rss_mb=rss_info["rss_mb"],
            memory_healthy=rss_info["healthy"],
        )


# Global instances
GLOBAL_LIFECYCLE_MANAGER = LifecycleManager()
GLOBAL_REAPER_DAEMON = ReaperDaemon(lifecycle_manager=GLOBAL_LIFECYCLE_MANAGER)


# ==============================================================================
# FastAPI Routing & Endpoints
# ==============================================================================

router = APIRouter(prefix="/api/v1/eap/lifecycle", tags=["eap-lifecycle-governance"])


@router.post("/register", response_model=LifecycleRecord, status_code=status.HTTP_201_CREATED)
async def api_register_lifecycle(req: RegisterEnvironmentRequest, tenant: Tenant) -> LifecycleRecord:
    """Register an environment into the lifecycle governance engine, bound to the caller's tenant."""
    customer_hash = claim_or_403(req.customer_hash or derive_customer_hash(req.company_name), tenant)
    rec = GLOBAL_LIFECYCLE_MANAGER.register_environment(
        company_name=req.company_name,
        customer_hash=customer_hash,
        ttl_minutes=req.ttl_minutes or DEFAULT_LEASE_MINUTES,
    )
    await _audit_eap_decision(
        None,
        getattr(tenant, "principal", None),
        "environment_lifecycle.register",
        rec.customer_hash,
        "ALLOW",
        {"company_name": req.company_name, "ttl_minutes": req.ttl_minutes},
    )
    return rec


@router.post("/environments/{customer_hash}/heartbeat", response_model=HeartbeatResponse)
async def api_heartbeat(customer_hash: CustomerHash, req: HeartbeatRequest, tenant: Tenant) -> HeartbeatResponse:
    """Record heartbeat and request lease renewal."""
    require_owned_or_404(customer_hash, tenant)
    res = GLOBAL_LIFECYCLE_MANAGER.record_heartbeat(
        customer_hash=customer_hash,
        extend_minutes=req.extend_minutes,
    )
    await _audit_eap_decision(
        None,
        getattr(tenant, "principal", None),
        "environment_lifecycle.heartbeat",
        customer_hash,
        "ALLOW",
        {"extend_minutes": req.extend_minutes, "expires_at": res.expires_at},
    )
    return res


@router.post("/environments/{customer_hash}/activity", response_model=LifecycleRecord)
async def api_record_activity(customer_hash: CustomerHash, tenant: Tenant) -> LifecycleRecord:
    """Touch environment activity timer."""
    require_owned_or_404(customer_hash, tenant)
    rec = GLOBAL_LIFECYCLE_MANAGER.record_activity(customer_hash, source="api_touch")
    await _audit_eap_decision(
        None,
        getattr(tenant, "principal", None),
        "environment_lifecycle.activity",
        customer_hash,
        "ALLOW",
        {"last_activity_at": rec.last_activity_at.isoformat()},
    )
    return rec


@router.get("/environments/{customer_hash}", response_model=LifecycleRecord)
async def api_get_lifecycle(customer_hash: CustomerHash, tenant: Tenant) -> LifecycleRecord:
    """Retrieve current lifecycle status for an environment."""
    require_owned_or_404(customer_hash, tenant)
    rec = GLOBAL_LIFECYCLE_MANAGER.get_lifecycle(customer_hash)
    if not rec:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Environment not found")
    return rec


@router.get("/active", response_model=List[LifecycleRecord])
async def api_list_active_lifecycle(tenant: Tenant) -> List[LifecycleRecord]:
    """List the caller's active (non-terminated) environments."""
    mine = owned_hashes(tenant)
    return [r for r in GLOBAL_LIFECYCLE_MANAGER.list_active() if r.customer_hash in mine]


@router.post("/reap-now", response_model=ReaperSummary)
async def api_trigger_reaping_pass(_operator: Operator) -> ReaperSummary:
    """Manually trigger an authoritative reaping evaluation pass (operator only: acts on every tenant)."""
    summary = await GLOBAL_REAPER_DAEMON.run_reconciliation_pass()
    await _audit_eap_decision(
        None,
        getattr(_operator, "principal", getattr(_operator, "user_id", "operator")),
        "environment_lifecycle.reap_now",
        "all",
        "ALLOW",
        {"actions_count": summary.actions_count, "active_remaining": summary.active_remaining},
    )
    return summary


@router.post("/reaper/pause")
async def api_pause_reaper(_operator: Operator) -> Dict[str, Any]:
    """Administratively pause background reaping operations (operator only: pauses every tenant's cleanup)."""
    GLOBAL_REAPER_DAEMON.pause()
    await _audit_eap_decision(
        None,
        getattr(_operator, "principal", getattr(_operator, "user_id", "operator")),
        "environment_lifecycle.pause_reaper",
        "system",
        "ALLOW",
        {"is_paused": True},
    )
    return {"status": "paused", "is_paused": True}


@router.post("/reaper/resume")
async def api_resume_reaper(_operator: Operator) -> Dict[str, Any]:
    """Administratively resume background reaping operations (operator only)."""
    GLOBAL_REAPER_DAEMON.resume()
    await _audit_eap_decision(
        None,
        getattr(_operator, "principal", getattr(_operator, "user_id", "operator")),
        "environment_lifecycle.resume_reaper",
        "system",
        "ALLOW",
        {"is_paused": False},
    )
    return {"status": "resumed", "is_paused": False}


@router.get("/reaper/status", response_model=ReaperStatusResponse)
async def api_get_reaper_status(_operator: Operator) -> ReaperStatusResponse:
    """Retrieve runtime diagnostics, interval, and memory metrics for the reaper daemon (operator only)."""
    return GLOBAL_REAPER_DAEMON.get_status()


@router.get("/reaper/dlq", response_model=List[DeadLetterRecord])
async def api_get_dlq(tenant: Tenant) -> List[DeadLetterRecord]:
    """Retrieve the caller's dead-letter queue records for failed reconciliation passes."""
    mine = owned_hashes(tenant)
    return [r for r in GLOBAL_LIFECYCLE_MANAGER.dlq.get_all() if r.customer_hash in mine]


@router.post("/reaper/dlq/clear")
async def api_clear_dlq(
    tenant: Tenant,
    customer_hash: Optional[str] = Query(default=None, pattern=CUSTOMER_HASH_PATTERN),
) -> Dict[str, Any]:
    """Clear the caller's dead-letter queue records (one hash, or all of the caller's)."""
    if customer_hash is not None:
        require_owned_or_404(customer_hash, tenant)
        cleared = GLOBAL_LIFECYCLE_MANAGER.dlq.clear(customer_hash)
    else:
        cleared = sum(GLOBAL_LIFECYCLE_MANAGER.dlq.clear(h) for h in owned_hashes(tenant))
    await _audit_eap_decision(
        None,
        getattr(tenant, "principal", None),
        "environment_lifecycle.clear_dlq",
        customer_hash or "all",
        "ALLOW",
        {"cleared_count": cleared},
    )
    return {"status": "cleared", "cleared_count": cleared}


@router.get("/audit-events", response_model=List[ReaperAuditEvent])
async def api_get_audit_events(
    tenant: Tenant,
    customer_hash: Optional[str] = Query(default=None, pattern=CUSTOMER_HASH_PATTERN),
) -> List[ReaperAuditEvent]:
    """Retrieve structured audit events recorded during lifecycle transitions for the caller's hashes."""
    if customer_hash is not None:
        require_owned_or_404(customer_hash, tenant)
        return GLOBAL_LIFECYCLE_MANAGER.get_audit_events(customer_hash)
    mine = owned_hashes(tenant)
    return [e for e in GLOBAL_LIFECYCLE_MANAGER.get_audit_events() if e.customer_hash in mine]


@router.get("/metrics")
async def api_get_lifecycle_metrics(_operator: Operator) -> Response:
    """Retrieve process-wide lifecycle and reaper telemetry (operator only: aggregates every tenant)."""
    metrics_text = GLOBAL_LIFECYCLE_MANAGER.metrics.render_openmetrics()
    return Response(
        content=metrics_text,
        media_type="application/openmetrics-text; version=1.0.0; charset=utf-8",
    )


def install_environment_lifecycle_api(app: FastAPI) -> None:
    """Mount lifecycle API router into FastAPI application.

    The authentication dependency is attached at the mount (EAPR-P2-1, SP-5) so a
    route added to this router is denied by default rather than opt-in.
    """
    from environment_teardown import teardown_router

    app.include_router(router, dependencies=[Depends(api_compat.authenticated_principal)])
    app.include_router(teardown_router, dependencies=[Depends(api_compat.authenticated_principal)])

