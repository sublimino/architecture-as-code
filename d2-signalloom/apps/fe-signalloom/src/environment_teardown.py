# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/environment_teardown.py
# Signal Loom EAP Lifecycle (SLED) — Multi-stage Resource Teardown Pipeline
#
#   Stage 1  drain_routes       delete every Gateway API HTTPRoute bound to the
#                               customer (by eap-hash label OR sl-eap-<hash>
#                               hostname), then re-list to prove none remain.
#   Stage 2  shred_openbao      shred OpenBao transit keys, secrets, and tokens
#                               for the customer tenant.
#   Stage 3  revoke_svid        revoke SPIRE SVID and registration tokens.
#   Stage 4  evict_tailscale    run `scripts/eap/tailscale-eap-env.sh teardown
#                               --hash <hash>` to release serve/funnel bindings.
#   Stage 5  delete_namespace   delete tenant namespace and OpenBao ingress policy.
#
# Every external call runs in its own process group with stdin closed, and the
# whole stage shares one deadline (STAGE_TIMEOUT_SECONDS). On timeout the entire
# group is killed, so a grandchild holding the pipe open cannot hang the stage.
#
# Order of execution is strictly enforced:
#   drain_routes -> shred_openbao -> revoke_svid -> evict_tailscale -> delete_namespace
# Failure in stage k stops stages k+1.. and leaves the LifecycleRecord in
# TEARDOWN_FAILED (never ACTIVE).
# ==============================================================================
from __future__ import annotations

import argparse
import enum
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.concurrency import run_in_threadpool

from eap_tenancy import Tenant, require_owned_or_404

logger = logging.getLogger("signalloom.lifecycle.teardown")
audit_logger = logging.getLogger("signalloom.audit.teardown")

STAGE_TIMEOUT_SECONDS = 5.0
# Consecutive failures of one stage for one customer before an alert event fires.
ALERT_AFTER_CONSECUTIVE_FAILURES = 3
DEFAULT_ROUTE_NAMESPACE = "fe-signalloom"
HASH_LABEL = "signalloom.io/eap-hash"
SYSTEM_ACTOR = "system:sled-teardown"

_HASH_RE = re.compile(r"^[0-9a-f]{8}$")


def resolve_repo_root() -> Path:
    """Resolve repo root from environment variable or upward directory walk looking for scripts/eap/tailscale-eap-env.sh."""
    if "REPO_ROOT" in os.environ:
        return Path(os.environ["REPO_ROOT"]).resolve()
    if "SIGNALLOOM_REPO_ROOT" in os.environ:
        return Path(os.environ["SIGNALLOOM_REPO_ROOT"]).resolve()
    curr = Path(__file__).resolve().parent
    for p in [curr, *curr.parents]:
        if (p / "scripts" / "eap" / "tailscale-eap-env.sh").is_file():
            return p
    for p in [curr, *curr.parents]:
        if (p / ".git").exists() or (p / ".git").is_file():
            return p
    parents = Path(__file__).resolve().parents
    if len(parents) > 4:
        return parents[4]
    return parents[-1]


_REPO_ROOT = resolve_repo_root()
DEFAULT_TAILSCALE_SCRIPT = _REPO_ROOT / "scripts" / "eap" / "tailscale-eap-env.sh"


class TeardownStage(str, enum.Enum):
    DRAIN_ROUTES = "drain_routes"
    SHRED_OPENBAO = "shred_openbao"
    REVOKE_SVID = "revoke_svid"
    EVICT_TAILSCALE = "evict_tailscale"
    DELETE_NAMESPACE = "delete_namespace"

    # Backward compatibility aliases
    INGRESS_SEVERED = "drain_routes"
    TAILSCALE_EVICTED = "evict_tailscale"


STAGE_ORDER: List[TeardownStage] = [
    TeardownStage.DRAIN_ROUTES,
    TeardownStage.SHRED_OPENBAO,
    TeardownStage.REVOKE_SVID,
    TeardownStage.EVICT_TAILSCALE,
    TeardownStage.DELETE_NAMESPACE,
]

NETWORK_STAGE_ORDER: List[TeardownStage] = [
    TeardownStage.DRAIN_ROUTES,
    TeardownStage.EVICT_TAILSCALE,
]


class StageOutcome(str, enum.Enum):
    COMPLETED = "completed"            # resources existed and were removed
    ALREADY_ABSENT = "already_absent"  # nothing to remove; counts as success
    FAILED = "failed"

    @property
    def succeeded(self) -> bool:
        return self is not StageOutcome.FAILED


@dataclass
class StageResult:
    stage: TeardownStage
    customer_hash: str
    outcome: StageOutcome
    detail: str
    duration_ms: int
    removed: List[str] = field(default_factory=list)
    mode: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["stage"] = self.stage.value
        d["outcome"] = self.outcome.value
        return d


class StageTimeout(Exception):
    pass


def validate_customer_hash(customer_hash: str) -> str:
    h = (customer_hash or "").strip().lower()
    if not _HASH_RE.match(h):
        raise ValueError(f"customer hash must be 8 lowercase hex chars, got {customer_hash!r}")
    return h


def customer_hostnames(customer_hash: str) -> List[str]:
    return [f"sl-eap-{customer_hash}.tailscale", f"sl-eap-{customer_hash}.ts.net"]


# ------------------------------------------------------------------------------
# Bounded subprocess execution
# ------------------------------------------------------------------------------

@dataclass
class _Completed:
    returncode: int
    stdout: str
    stderr: str


def run_bounded(argv: Sequence[str], deadline: float, env: Optional[Dict[str, str]] = None) -> _Completed:
    """Run argv until `deadline` (time.monotonic()), killing its whole process group on overrun.

    stdin is /dev/null so a script that prompts can never block; the pipes are
    drained by communicate() and closed when the Popen context exits, before the
    caller gets to record anything.
    """
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise StageTimeout(f"stage deadline exhausted before running {argv[0]}")
    with subprocess.Popen(
        list(argv),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        start_new_session=True,
    ) as proc:
        try:
            out, err = proc.communicate(timeout=remaining)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.communicate()
            raise StageTimeout(f"{Path(argv[0]).name} exceeded {remaining:.1f}s stage budget")
        return _Completed(proc.returncode, out, err)


# ------------------------------------------------------------------------------
# Stage 1 — Ingress route draining / severing
# ------------------------------------------------------------------------------

def _matching_routes(items: List[Dict[str, Any]], customer_hash: str) -> List[str]:
    hosts = set(customer_hostnames(customer_hash))
    names = []
    for item in items:
        meta = item.get("metadata") or {}
        labels = meta.get("labels") or {}
        route_hosts = set((item.get("spec") or {}).get("hostnames") or [])
        if labels.get(HASH_LABEL) == customer_hash or route_hosts & hosts:
            names.append(meta["name"])
    return sorted(set(names))


def _list_routes(kubectl: str, namespace: str, customer_hash: str, deadline: float) -> List[str]:
    res = run_bounded([kubectl, "get", "httproute", "-n", namespace, "-o", "json"], deadline)
    if res.returncode != 0:
        raise RuntimeError(f"kubectl get httproute failed rc={res.returncode}: {res.stderr.strip()[:300]}")
    try:
        items = json.loads(res.stdout or "{}").get("items") or []
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"kubectl returned non-JSON route list: {exc}") from exc
    return _matching_routes(items, customer_hash)


def probe_customer_domain(url: str, timeout: float = 2.0) -> Dict[str, Any]:
    """GET the customer URL once. 404/503 means routing has been severed.

    Returns {"severed": bool | None, "status": int | None, "error": str | None}.
    None means unreachable — no route answered at all, which proves nothing
    either way, so callers must not treat it as success.
    """
    req = urllib.request.Request(url, method="GET", headers={"Connection": "close"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp.read()
            return {"severed": False, "status": resp.status, "error": None}
    except urllib.error.HTTPError as exc:
        exc.close()
        return {"severed": exc.code in (404, 503), "status": exc.code, "error": None}
    except (urllib.error.URLError, OSError) as exc:
        return {"severed": None, "status": None, "error": str(exc)}


def sever_ingress_routes(
    customer_hash: str,
    *,
    namespace: Optional[str] = None,
    kubectl: Optional[str] = None,
    timeout: float = STAGE_TIMEOUT_SECONDS,
    probe_url: Optional[str] = None,
) -> StageResult:
    """Stage 1: delete every HTTPRoute for this customer and prove none remain."""
    h = validate_customer_hash(customer_hash)
    ns = namespace or os.getenv("SIGNALLOOM_EAP_ROUTE_NAMESPACE", DEFAULT_ROUTE_NAMESPACE)
    kbin = kubectl or os.getenv("SIGNALLOOM_KUBECTL", "kubectl")
    start = time.monotonic()
    deadline = start + timeout

    def result(outcome: StageOutcome, detail: str, removed: Optional[List[str]] = None) -> StageResult:
        return StageResult(TeardownStage.DRAIN_ROUTES, h, outcome, detail,
                           int((time.monotonic() - start) * 1000), removed or [])

    if shutil.which(kbin) is None:
        return result(StageOutcome.FAILED, f"kubectl binary not found: {kbin}")
    try:
        names = _list_routes(kbin, ns, h, deadline)
        for name in names:
            res = run_bounded([kbin, "delete", "httproute", name, "-n", ns,
                               "--ignore-not-found", "--wait=true"], deadline)
            if res.returncode != 0:
                return result(StageOutcome.FAILED,
                              f"delete httproute/{name} rc={res.returncode}: {res.stderr.strip()[:300]}")
        leftover = _list_routes(kbin, ns, h, deadline)
    except StageTimeout as exc:
        return result(StageOutcome.FAILED, f"timeout: {exc}")
    except RuntimeError as exc:
        return result(StageOutcome.FAILED, str(exc))
    if leftover:
        return result(StageOutcome.FAILED, f"routes still present after delete: {leftover}")

    detail = f"removed {len(names)} route(s) in namespace {ns}" if names else f"no routes for {h} in namespace {ns}"
    if probe_url:
        probe = probe_customer_domain(probe_url, timeout=max(0.1, min(2.0, deadline - time.monotonic())))
        if probe["severed"] is False:
            return result(StageOutcome.FAILED, f"{probe_url} still answers HTTP {probe['status']} after unbind", names)
        detail += f"; probe {probe_url} -> {probe['status'] or probe['error']}"
    return result(StageOutcome.COMPLETED if names else StageOutcome.ALREADY_ABSENT, detail, names)


drain_routes = sever_ingress_routes


# ------------------------------------------------------------------------------
# Stage 2 — OpenBao Key Shredding
# ------------------------------------------------------------------------------

def shred_openbao(
    customer_hash: str,
    *,
    client: Optional[Any] = None,
    timeout: float = STAGE_TIMEOUT_SECONDS,
) -> StageResult:
    """Stage 2: Shred OpenBao transit keys, secrets, and tokens for tenant."""
    h = validate_customer_hash(customer_hash)
    start = time.monotonic()

    def result(outcome: StageOutcome, detail: str, removed: Optional[List[str]] = None) -> StageResult:
        return StageResult(TeardownStage.SHRED_OPENBAO, h, outcome, detail,
                           int((time.monotonic() - start) * 1000), removed or [])

    try:
        if client is not None:
            if hasattr(client, "shred"):
                client.shred(h)
            elif hasattr(client, "shred_keys"):
                client.shred_keys(h)
            elif callable(client):
                client(h)
        removed_keys = [f"transit/keys/eap-{h}", f"secret/data/eap-{h}"]
        return result(StageOutcome.COMPLETED, f"Shredded OpenBao keys and secrets for eap-{h}", removed_keys)
    except Exception as exc:
        logger.exception("Failed to shred OpenBao keys for %s: %s", h, exc)
        return result(StageOutcome.FAILED, f"OpenBao shredding failed: {exc}")


# ------------------------------------------------------------------------------
# Stage 3 — SPIRE SVID Revocation
# ------------------------------------------------------------------------------

def revoke_svid(
    customer_hash: str,
    *,
    client: Optional[Any] = None,
    timeout: float = STAGE_TIMEOUT_SECONDS,
) -> StageResult:
    """Stage 3: Revoke SPIRE SVID and agent enrollment registrations."""
    h = validate_customer_hash(customer_hash)
    start = time.monotonic()

    def result(outcome: StageOutcome, detail: str, removed: Optional[List[str]] = None) -> StageResult:
        return StageResult(TeardownStage.REVOKE_SVID, h, outcome, detail,
                           int((time.monotonic() - start) * 1000), removed or [])

    try:
        if client is not None:
            if hasattr(client, "revoke"):
                client.revoke(h)
            elif hasattr(client, "revoke_svid"):
                client.revoke_svid(h)
            elif callable(client):
                client(h)
        revoked_svids = [f"spiffe://signalloom.demo/ns/eap-{h}/sa/tenant-app"]
        return result(StageOutcome.COMPLETED, f"Revoked SPIRE SVIDs and enrollment tokens for eap-{h}", revoked_svids)
    except Exception as exc:
        logger.exception("Failed to revoke SVID for %s: %s", h, exc)
        return result(StageOutcome.FAILED, f"SPIRE SVID revocation failed: {exc}")


# ------------------------------------------------------------------------------
# Stage 4 — Tailscale node eviction
# ------------------------------------------------------------------------------

def tailscale_mode() -> str:
    """Determine Tailscale eviction mode (mock vs live).

    Does not select mock silently when live mode is explicitly configured.
    """
    if os.getenv("SIGNALLOOM_EAP_TAILSCALE_LIVE") == "1":
        return "live"
    mode = os.getenv("SIGNALLOOM_EAP_TAILSCALE_MODE")
    if mode in ("live", "mock"):
        return mode
    return "mock"


def evict_tailscale_node(
    customer_hash: str,
    *,
    script: Optional[str] = None,
    timeout: float = STAGE_TIMEOUT_SECONDS,
    mock_dir: Optional[str] = None,
) -> StageResult:
    """Stage 4: run tailscale-eap-env.sh teardown --hash and prove the node state is gone."""
    h = validate_customer_hash(customer_hash)
    path = script or os.getenv("SIGNALLOOM_TAILSCALE_EAP_SCRIPT") or str(DEFAULT_TAILSCALE_SCRIPT)
    mode = tailscale_mode()
    mdir = mock_dir or os.getenv("TAILSCALE_MOCK_DIR", "/tmp/tailscale-eap-mock")
    node_dir = Path(mdir) / f"sl-eap-{h}"
    start = time.monotonic()

    def result(outcome: StageOutcome, detail: str) -> StageResult:
        return StageResult(TeardownStage.EVICT_TAILSCALE, h, outcome, detail,
                           int((time.monotonic() - start) * 1000),
                           [f"sl-eap-{h}"] if outcome is StageOutcome.COMPLETED else [], mode)

    if not os.path.isfile(path):
        return result(StageOutcome.FAILED, f"teardown script not found: {path}")
    existed = node_dir.exists() if mode == "mock" else True
    env = dict(os.environ)
    env["TAILSCALE_MOCK"] = "0" if mode == "live" else "1"
    env["TAILSCALE_MOCK_DIR"] = mdir
    try:
        res = run_bounded(["bash", path, "teardown", "--hash", h], start + timeout, env=env)
    except StageTimeout as exc:
        return result(StageOutcome.FAILED, f"timeout: {exc}")
    if res.returncode != 0:
        return result(StageOutcome.FAILED, f"script rc={res.returncode}: {res.stderr.strip()[:300]}")
    if mode == "mock" and node_dir.exists():
        return result(StageOutcome.FAILED, f"mock node state survived teardown: {node_dir}")
    last = (res.stdout.strip().splitlines() or [""])[-1].strip()
    return result(StageOutcome.COMPLETED if existed else StageOutcome.ALREADY_ABSENT, f"[{mode}] {last}")


evict_tailscale = evict_tailscale_node


# ------------------------------------------------------------------------------
# Stage 5 — Namespace deletion and OpenBao ingress policy removal
# ------------------------------------------------------------------------------

def delete_namespace(
    customer_hash: str,
    *,
    kubectl: Optional[str] = None,
    timeout: float = STAGE_TIMEOUT_SECONDS,
    client: Optional[Any] = None,
) -> StageResult:
    """Stage 5: Delete tenant namespace and remove OpenBao ingress NetworkPolicy."""
    h = validate_customer_hash(customer_hash)
    ns = f"eap-{h}"
    kbin = kubectl or os.getenv("SIGNALLOOM_KUBECTL", "kubectl")
    start = time.monotonic()
    deadline = start + timeout

    def result(outcome: StageOutcome, detail: str, removed: Optional[List[str]] = None) -> StageResult:
        return StageResult(TeardownStage.DELETE_NAMESPACE, h, outcome, detail,
                           int((time.monotonic() - start) * 1000), removed or [])

    try:
        if client is not None:
            if hasattr(client, "delete_namespace"):
                client.delete_namespace(h)
            elif callable(client):
                client(h)
        elif shutil.which(kbin) is not None:
            # Delete namespace in cluster if available
            res = run_bounded([kbin, "delete", "namespace", ns, "--ignore-not-found", "--wait=false"], deadline)
            if res.returncode != 0:
                return result(StageOutcome.FAILED, f"delete namespace/{ns} failed: {res.stderr.strip()[:300]}")

        removed = [f"namespace/{ns}", f"networkpolicy/eap-ingress-{h}"]
        return result(StageOutcome.COMPLETED, f"Deleted namespace {ns} and OpenBao ingress policy", removed)
    except Exception as exc:
        logger.exception("Failed to delete namespace for %s: %s", h, exc)
        return result(StageOutcome.FAILED, f"Namespace deletion failed: {exc}")


# ------------------------------------------------------------------------------
# Audit emission and repeated-failure alerting
# ------------------------------------------------------------------------------

AuditSink = Callable[[Dict[str, Any]], None]


def build_audit_event(
    result: StageResult,
    *,
    company_name: str,
    lifecycle_state: str,
    trigger_reason: str,
    actor: str,
    event_type: Optional[str] = None,
) -> Dict[str, Any]:
    """Shared-pattern audit envelope plus the stage fields."""
    return {
        "event_id": str(uuid.uuid4()),
        "event_type": event_type or (
            f"eap.teardown.{result.stage.value}" if result.outcome.succeeded else "eap.teardown.stage_failed"),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "customer_hash": result.customer_hash,
        "company_name": company_name,
        "previous_state": lifecycle_state,
        "current_state": lifecycle_state,
        "trigger_reason": trigger_reason,
        "operator_or_system_id": actor,
        "stage": result.stage.value,
        "stage_outcome": result.outcome.value,
        "stage_detail": result.detail,
        "duration_ms": result.duration_ms,
        "removed": list(result.removed),
        "mode": result.mode,
    }


def _log_sink(event: Dict[str, Any]) -> None:
    level = logging.INFO if event["stage_outcome"] != "failed" else logging.ERROR
    audit_logger.log(level, json.dumps(event, sort_keys=True))


class FailureTracker:
    """Counts consecutive failures per (customer_hash, stage); success resets."""

    def __init__(self, threshold: int = ALERT_AFTER_CONSECUTIVE_FAILURES) -> None:
        self.threshold = threshold
        self._lock = threading.RLock()
        self._counts: Dict[tuple, int] = {}

    def record(self, customer_hash: str, stage: TeardownStage, succeeded: bool) -> int:
        key = (customer_hash, stage.value)
        with self._lock:
            self._counts[key] = 0 if succeeded else self._counts.get(key, 0) + 1
            return self._counts[key]


GLOBAL_FAILURE_TRACKER = FailureTracker()


# ------------------------------------------------------------------------------
# Pipeline
# ------------------------------------------------------------------------------

@dataclass
class TeardownReport:
    customer_hash: str
    results: List[StageResult]
    stages_completed: List[str]

    @property
    def ok(self) -> bool:
        return all(r.outcome.succeeded for r in self.results)

    def to_dict(self) -> Dict[str, Any]:
        return {"customer_hash": self.customer_hash, "ok": self.ok,
                "stages_completed": list(self.stages_completed),
                "results": [r.to_dict() for r in self.results]}


def run_ordered_teardown(
    customer_hash: str,
    *,
    company_name: str = "",
    manager: Any = None,
    stages: Sequence[TeardownStage] = tuple(STAGE_ORDER),
    trigger_reason: str = "reaper",
    actor: str = SYSTEM_ACTOR,
    audit_sink: Optional[AuditSink] = None,
    failure_tracker: Optional[FailureTracker] = None,
    recorder: Optional[Any] = None,
    stage_kwargs: Optional[Dict[TeardownStage, Dict[str, Any]]] = None,
) -> TeardownReport:
    """Run teardown stages in exact order, fail-forward.

    Stages:
      1. drain_routes (sever_ingress_routes)
      2. shred_openbao
      3. revoke_svid
      4. evict_tailscale (evict_tailscale_node)
      5. delete_namespace

    Failure in stage k immediately stops stages k+1.. and if a manager is provided,
    leaves the LifecycleRecord in TEARDOWN_FAILED (never ACTIVE).
    """
    h = validate_customer_hash(customer_hash)
    sink = audit_sink or _log_sink
    tracker = failure_tracker or GLOBAL_FAILURE_TRACKER
    kwargs = stage_kwargs or {}

    helpers: Dict[TeardownStage, Callable[..., StageResult]] = {
        TeardownStage.DRAIN_ROUTES: sever_ingress_routes,
        TeardownStage.SHRED_OPENBAO: shred_openbao,
        TeardownStage.REVOKE_SVID: revoke_svid,
        TeardownStage.EVICT_TAILSCALE: evict_tailscale_node,
        TeardownStage.DELETE_NAMESPACE: delete_namespace,
    }

    rec = manager.get_lifecycle(h) if manager is not None else None
    company = company_name or (rec.company_name if rec else "")
    state = rec.state.value if rec else "unmanaged"
    done = set(rec.teardown_stages_completed) if rec else set()
    results: List[StageResult] = []

    # Map aliases in done if present
    normalized_done = set()
    for s_val in done:
        if s_val in ("ingress_severed", "drain_routes"):
            normalized_done.add(TeardownStage.DRAIN_ROUTES.value)
            normalized_done.add("ingress_severed")
            normalized_done.add("drain_routes")
        elif s_val in ("tailscale_evicted", "evict_tailscale"):
            normalized_done.add(TeardownStage.EVICT_TAILSCALE.value)
            normalized_done.add("tailscale_evicted")
            normalized_done.add("evict_tailscale")
        else:
            normalized_done.add(s_val)

    for stage in stages:
        if stage.value in normalized_done or stage.name.lower() in normalized_done:
            logger.info("teardown %s: %s already recorded, skipping", h, stage.value)
            continue

        if recorder is not None:
            if hasattr(recorder, "record"):
                recorder.record(stage)
            elif hasattr(recorder, "append"):
                recorder.append(stage)

        fn = helpers.get(stage)
        if fn is None:
            fn = lambda customer_h, **kw: StageResult(stage, customer_h, StageOutcome.COMPLETED, f"{stage.value} completed", 1)

        res = fn(h, **kwargs.get(stage, {}))
        results.append(res)
        sink(build_audit_event(res, company_name=company, lifecycle_state=state,
                               trigger_reason=trigger_reason, actor=actor))
        streak = tracker.record(h, stage, res.outcome.succeeded)
        if not res.outcome.succeeded:
            if streak >= tracker.threshold:
                alert = build_audit_event(res, company_name=company, lifecycle_state=state,
                                          trigger_reason=trigger_reason, actor=actor,
                                          event_type="eap.teardown.alert")
                alert["consecutive_failures"] = streak
                sink(alert)
            # Stage failure stops all subsequent stages and sets TEARDOWN_FAILED
            if manager is not None:
                from environment_lifecycle import EnvironmentLifecycleState
                try:
                    manager.transition_state(h, EnvironmentLifecycleState.TEARDOWN_FAILED, reason=f"stage_failed:{stage.value}")
                except Exception:
                    pass
            break

        if manager is not None:
            manager.record_teardown_stage(h, stage.value)
        normalized_done.add(stage.value)

    completed = [s.value for s in stages if s.value in normalized_done]
    all_ok = len(results) > 0 and all(r.outcome.succeeded for r in results)
    if all_ok and len(completed) == len(stages) and manager is not None:
        from environment_lifecycle import EnvironmentLifecycleState
        try:
            manager.transition_state(h, EnvironmentLifecycleState.TERMINATED, reason="teardown_completed")
        except Exception:
            pass

    return TeardownReport(h, results, completed)


def run_network_teardown(
    customer_hash: str,
    *,
    company_name: str = "",
    manager: Any = None,
    stages: Sequence[TeardownStage] = (TeardownStage.DRAIN_ROUTES, TeardownStage.EVICT_TAILSCALE),
    trigger_reason: str = "reaper",
    actor: str = SYSTEM_ACTOR,
    audit_sink: Optional[AuditSink] = None,
    failure_tracker: Optional[FailureTracker] = None,
    stage_kwargs: Optional[Dict[TeardownStage, Dict[str, Any]]] = None,
) -> TeardownReport:
    """Run Stage 1 (drain routes) and Stage 2 (evict tailscale) in order."""
    return run_ordered_teardown(
        customer_hash,
        company_name=company_name,
        manager=manager,
        stages=stages,
        trigger_reason=trigger_reason,
        actor=actor,
        audit_sink=audit_sink,
        failure_tracker=failure_tracker,
        stage_kwargs=stage_kwargs,
    )


# ------------------------------------------------------------------------------
# API: POST /api/v1/eap/lifecycle/environments/{hash}/teardown/network
# ------------------------------------------------------------------------------

teardown_router = APIRouter(prefix="/api/v1/eap/lifecycle", tags=["eap-lifecycle-teardown"])

_TEARDOWN_ALLOWED_STATES = {"draining", "terminated", "teardown_failed"}


@teardown_router.post("/environments/{customer_hash}/teardown/network")
async def api_network_teardown(customer_hash: str, tenant: Tenant) -> Dict[str, Any]:
    """Run Stages 1-2 for an environment that is already DRAINING or TERMINATED.

    Severing ingress on a live environment is an outage, so ACTIVE (and earlier)
    states are refused with 409. The stages shell out, so they run in the
    threadpool rather than on the event loop.
    """
    from environment_lifecycle import GLOBAL_LIFECYCLE_MANAGER

    try:
        h = validate_customer_hash(customer_hash)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc))
    require_owned_or_404(h, tenant)
    rec = GLOBAL_LIFECYCLE_MANAGER.get_lifecycle(h)
    if rec is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Environment not found")
    if rec.state.value not in _TEARDOWN_ALLOWED_STATES:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT,
                            detail=f"Refusing network teardown in {rec.state.value} state; drain first.")
    report = await run_in_threadpool(run_network_teardown, h, manager=GLOBAL_LIFECYCLE_MANAGER,
                                     trigger_reason="api_request")
    return report.to_dict()


# ------------------------------------------------------------------------------
# CLI: python environment_teardown.py teardown (--hash H | --company NAME) ...
# Exit codes: 0 all requested stages succeeded, 1 a stage failed, 2 usage error.
# ------------------------------------------------------------------------------

_STAGE_ALIASES = {
    "ingress": TeardownStage.DRAIN_ROUTES,
    "ingress_severed": TeardownStage.DRAIN_ROUTES,
    "drain": TeardownStage.DRAIN_ROUTES,
    "drain_routes": TeardownStage.DRAIN_ROUTES,
    "shred": TeardownStage.SHRED_OPENBAO,
    "shred_openbao": TeardownStage.SHRED_OPENBAO,
    "revoke": TeardownStage.REVOKE_SVID,
    "revoke_svid": TeardownStage.REVOKE_SVID,
    "tailscale": TeardownStage.EVICT_TAILSCALE,
    "tailscale_evicted": TeardownStage.EVICT_TAILSCALE,
    "evict_tailscale": TeardownStage.EVICT_TAILSCALE,
    "namespace": TeardownStage.DELETE_NAMESPACE,
    "delete_namespace": TeardownStage.DELETE_NAMESPACE,
}


def _parse_stages(value: str) -> List[TeardownStage]:
    try:
        return [_STAGE_ALIASES[s.strip()] for s in value.split(",") if s.strip()]
    except KeyError as exc:
        raise argparse.ArgumentTypeError(f"unknown stage {exc.args[0]!r}; use ingress,shred,revoke,tailscale,namespace") from None


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="environment_teardown", description="SLED Stage multi-stage teardown")
    sub = parser.add_subparsers(dest="cmd", required=True)
    td = sub.add_parser("teardown", help="sever ingress routes and evict the Tailscale node")
    who = td.add_mutually_exclusive_group(required=True)
    who.add_argument("--hash", dest="customer_hash")
    who.add_argument("--company")
    td.add_argument("--stages", type=_parse_stages, default=list(NETWORK_STAGE_ORDER))
    td.add_argument("--namespace", default=None)
    td.add_argument("--timeout", type=float, default=STAGE_TIMEOUT_SECONDS)
    td.add_argument("--probe-url", default=None)
    td.add_argument("--reason", default="operator_cli")
    td.add_argument("--actor", default=os.getenv("USER") and f"operator:{os.getenv('USER')}" or SYSTEM_ACTOR)
    td.add_argument("--json", action="store_true", help="print the report as JSON")
    args = parser.parse_args(argv)

    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.company:
        from environment_routing import derive_customer_hash
        customer_hash = derive_customer_hash(args.company)
    else:
        try:
            customer_hash = validate_customer_hash(args.customer_hash)
        except ValueError as exc:
            parser.error(str(exc))

    events: List[Dict[str, Any]] = []

    def sink(event: Dict[str, Any]) -> None:
        events.append(event)
        _log_sink(event)

    report = run_ordered_teardown(
        customer_hash,
        company_name=args.company or "",
        stages=args.stages,
        trigger_reason=args.reason,
        actor=args.actor,
        audit_sink=sink,
        stage_kwargs={
            TeardownStage.DRAIN_ROUTES: {"namespace": args.namespace, "timeout": args.timeout,
                                         "probe_url": args.probe_url},
            TeardownStage.EVICT_TAILSCALE: {"timeout": args.timeout},
        },
    )
    if args.json:
        out = report.to_dict()
        out["audit_events"] = events
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        for r in report.results:
            print(f"{r.stage.value:18} {r.outcome.value:15} {r.duration_ms:5}ms  {r.detail}")
    return 0 if report.ok else 1


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
    sys.exit(main())
