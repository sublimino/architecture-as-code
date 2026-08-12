"""Expose the fixed SuperCred demo steps over HTTP without widening control.

This module exists so the dashboard can drive the five-step SuperCred demo
without shell access. The threat model is deliberate remote command execution:
the server is allowed to run one repo-local script against a shared cluster,
and the only client-controlled input is which of five hardcoded step IDs runs.
The security boundary is therefore the server-side step allowlist, server-side
superadmin authorisation on the mutating routes, argv-array spawn, and fixed
child environment below.
"""
from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import threading
from collections import OrderedDict
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from types import MappingProxyType
from typing import Annotated, Any, Literal, Mapping, cast
from uuid import uuid4

from fastapi import APIRouter, Depends, Query
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel

from api_compat import ERROR_RESPONSES, APIError, Principal, authenticated_tenant
from superadmin import require_superadmin

logger = logging.getLogger(__name__)

_ENV_SCRIPT = "SUPERCRED_DEMO_SCRIPT"
_ENV_EVIDENCE_SCRIPT = "SUPERCRED_EVIDENCE_SCRIPT"
_ENV_CWD = "SUPERCRED_DEMO_CWD"
_ENV_TIMEOUT = "SUPERCRED_DEMO_TIMEOUT_SECONDS"
_ENV_CANCEL_GRACE = "SUPERCRED_DEMO_CANCEL_GRACE_SECONDS"

_DEFAULT_TIMEOUT_SECONDS = 900
_DEFAULT_CANCEL_GRACE_SECONDS = 10
_LOG_CAP_BYTES = 4 * 1024 * 1024
_LOG_PAGE_BYTES = 64 * 1024
_MAX_RUN_HISTORY = 20
# Everything the demo script's child process is allowed to inherit. This stays
# an allowlist -- the module docstring names the fixed child environment as one
# of four security boundaries -- so it is widened by naming keys, never by
# handing over os.environ.
#
# KUBERNETES_SERVICE_HOST / KUBERNETES_SERVICE_PORT are how client-go's
# in-cluster config finds the API server. The ServiceAccount token and CA come
# from the projected volume at /var/run/secrets/kubernetes.io/serviceaccount/
# and need no environment at all, so these two keys are the entire environmental
# dependency -- but without them kubectl has no server to talk to and exits
# immediately. That is not a subtle degradation: on 2026-08-03 every step
# invoked from the dashboard died at its first kubectl call, in tens to
# hundreds of milliseconds, having printed only its banner. Step 5 ("Reset
# demo") was the visible one at 333ms; phase 4 failed identically in 53ms.
#
# It is invisible to `kubectl exec ... -- bash scripts/supercred-demo.sh 5`,
# because an interactive exec inherits the pod's full environment, which the
# kubelet has populated. Only the spawned child was starved. See
# tests/test_demo_runner_child_env.py, which asserts against the requirement
# rather than against this tuple.
_ENV_ALLOWLIST = (
    "PATH",
    "HOME",
    "KUBECONFIG",
    "CLUSTER_NAME",
    "AGENT_NAMESPACE_CANDIDATES",
    "KUBERNETES_SERVICE_HOST",
    "KUBERNETES_SERVICE_PORT",
)


@dataclass(frozen=True)
class DemoStep:
    step_id: str
    title: str
    description: str


DEMO_STEPS: Mapping[str, DemoStep] = MappingProxyType(
    {
        "1": DemoStep(
            step_id="1",
            title="Deploy",
            description="Deploy cardvault, policy-engine, and the agent; seed OpenBao secrets and register the SPIRE entry.",
        ),
        "2": DemoStep(
            step_id="2",
            title="Credential chain",
            description="Run the SPIFFE to OpenBao to cardvault credential chain job.",
        ),
        "3": DemoStep(
            step_id="3",
            title="Compliance scan",
            description="Scan policy compliance and mark the agent non-compliant when securityContext is missing.",
        ),
        "4": DemoStep(
            step_id="4",
            title="Stun",
            description="Revoke OpenBao credentials, stun the agent, and verify access is denied.",
        ),
        "5": DemoStep(
            step_id="5",
            title="Teardown",
            description="Delete demo resources, remove the SPIRE entry, and verify cleanup.",
        ),
    }
)
RESET_STEP_ID = "5"
StepId = Literal["1", "2", "3", "4", "5"]
RunStatus = Literal["running", "succeeded", "failed", "cancelled", "timed_out"]


@dataclass
class _Run:
    run_id: str
    step_id: str
    kind: Literal["step", "reset"]
    status: RunStatus
    started_at: datetime
    finished_at: datetime | None
    exit_code: int | None
    error: str | None
    _process: subprocess.Popen[bytes] | None
    _log: bytearray
    _log_truncated: bool
    _timed_out: bool
    _lock: threading.Lock
    _done: threading.Event


# The demo mutates one shared cluster, so runs serialize process-wide rather
# than per tenant.
_STATE_LOCK = threading.RLock()
# Serialises the two mutating operations (start, reset) so a start cannot slip
# between another caller's concurrency check and its spawn. _STATE_LOCK stays
# fine-grained so the read endpoints never block behind a cancellation.
_MUTATION_LOCK = threading.Lock()
_active: _Run | None = None
_runs: OrderedDict[str, _Run] = OrderedDict()

router = APIRouter(prefix="/api/demo/supercred", tags=["demo-runner"])


class DemoStepView(BaseModel):
    step_id: str
    title: str
    description: str


class DemoStepsResponse(BaseModel):
    steps: list[DemoStepView]


class EvidenceStepView(BaseModel):
    """One lifecycle step, and the command that decided its state.

    `state` is a closed vocabulary and deliberately has no "completed":

      observed     a probe ran and confirmed it
      absent       a probe ran and disproved it
      unavailable  the probe could not run — NOT the same as absent

    `command` is the whole point of shipping this to the browser. The card this
    replaces rendered "completed" with a hardcoded timestamp off a single
    boolean; a claim a debugger cannot re-execute is indistinguishable from a
    fabricated one.
    """

    step: int
    label: str
    state: str
    command: str
    detail: str
    summary: str


class EvidenceResponse(BaseModel):
    generated_at: str
    source: str
    steps: list[EvidenceStepView]


class RunRequest(BaseModel):
    step: StepId


class RunView(BaseModel):
    run_id: str
    step_id: str
    kind: Literal["step", "reset"]
    status: RunStatus
    started_at: datetime
    finished_at: datetime | None
    exit_code: int | None
    error: str | None
    log_bytes: int
    truncated: bool


class RunLogResponse(BaseModel):
    run_id: str
    offset: int
    next_offset: int
    chunk: str
    truncated: bool
    eof: bool


class DemoStatusResponse(BaseModel):
    active: RunView | None
    recent: list[RunView]
    script_available: bool


def _repo_root() -> Path:
    override = os.environ.get(_ENV_CWD)
    if override:
        return Path(override)
    # demo_runner.py -> src -> fe-signalloom -> apps -> d2-signalloom -> repo root
    return Path(__file__).resolve().parents[4]


def _script_path() -> Path:
    override = os.environ.get(_ENV_SCRIPT)
    if override:
        return Path(override)
    return _repo_root() / "scripts" / "supercred-demo.sh"


def _evidence_script_path() -> Path:
    override = os.environ.get(_ENV_EVIDENCE_SCRIPT)
    if override:
        return Path(override)
    return _repo_root() / "scripts" / "supercred-evidence.sh"


def _read_int_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        logger.warning("demo runner: invalid %s=%r; falling back to %s", name, raw, default)
        return default
    if value <= 0:
        logger.warning("demo runner: non-positive %s=%r; falling back to %s", name, raw, default)
        return default
    return value


def _timeout_seconds() -> int:
    return _read_int_env(_ENV_TIMEOUT, _DEFAULT_TIMEOUT_SECONDS)


def _cancel_grace_seconds() -> int:
    return _read_int_env(_ENV_CANCEL_GRACE, _DEFAULT_CANCEL_GRACE_SECONDS)


def _argv_for(step_id: str) -> list[str]:
    # The Literal type on the request body is helpful validation, but the
    # server-side allowlist is the real boundary for command execution.
    if step_id not in DEMO_STEPS:
        raise APIError(422, "unknown_step", f"Unknown SuperCred demo step: {step_id}")
    return [str(_script_path()), DEMO_STEPS[step_id].step_id]


def _child_env() -> dict[str, str]:
    child_env: dict[str, str] = {}
    for key in _ENV_ALLOWLIST:
        value = os.environ.get(key)
        if value is not None:
            child_env[key] = value
    return child_env


def _script_is_available(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def _require_script_available() -> Path:
    path = _script_path()
    if not _script_is_available(path):
        raise APIError(503, "demo_script_unavailable", f"SuperCred demo script is unavailable: {path}")
    return path


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _append_log(run: _Run, chunk: bytes) -> None:
    with run._lock:
        remaining = _LOG_CAP_BYTES - len(run._log)
        if remaining <= 0:
            run._log_truncated = True
            return
        run._log.extend(chunk[:remaining])
        if len(chunk) > remaining:
            run._log_truncated = True


def _finalize_run(run: _Run, *, status: RunStatus | None = None, exit_code: int | None = None, error: str | None = None) -> None:
    with _STATE_LOCK:
        if exit_code is not None:
            run.exit_code = exit_code
        if error is not None:
            run.error = error
        if status is not None and run.status != "cancelled":
            run.status = status
        run.finished_at = _utcnow()
        if _active is run:
            globals()["_active"] = None
        _evict_finished_runs_locked()
    run._done.set()


def _evict_finished_runs_locked() -> None:
    while len(_runs) > _MAX_RUN_HISTORY:
        oldest_run_id, oldest_run = next(iter(_runs.items()))
        if oldest_run.status == "running":
            break
        _runs.pop(oldest_run_id, None)


def _kill_process_group(proc: subprocess.Popen[bytes], sig: signal.Signals) -> None:
    pgid = os.getpgid(proc.pid)
    os.killpg(pgid, sig)


def _fire_timeout_kill(run: _Run) -> None:
    """Kill the run's process group once the wall-clock bound is exceeded.

    The monitor thread blocks in ``stdout.read``, so the deadline cannot be
    enforced by ``proc.wait(timeout=...)`` alone -- a script that keeps the pipe
    open would never reach it. Killing the group unblocks the read and lets the
    monitor finish normally.
    """
    with run._lock:
        run._timed_out = True
    proc = run._process
    if proc is None:
        return
    try:
        _kill_process_group(proc, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        logger.info("demo runner: run %s exited before the timeout kill", run.run_id)


def _monitor_run(run: _Run) -> None:
    proc = run._process
    watchdog: threading.Timer | None = None
    timeout = _timeout_seconds()
    try:
        if proc is None or proc.stdout is None:
            raise RuntimeError(f"run {run.run_id} has no subprocess stdout to monitor")
        watchdog = threading.Timer(timeout, _fire_timeout_kill, args=(run,))
        watchdog.daemon = True
        watchdog.start()
        while True:
            chunk = proc.stdout.read(8192)
            if not chunk:
                break
            _append_log(run, chunk)
        try:
            exit_code = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                _kill_process_group(proc, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                logger.info("demo runner: process group already exited during timeout handling for run %s", run.run_id)
            try:
                exit_code = proc.wait(timeout=5)
            except subprocess.TimeoutExpired as exc:
                raise RuntimeError(f"run {run.run_id} did not exit after timeout kill") from exc
        with run._lock:
            hit_timeout = run._timed_out
        if hit_timeout:
            _finalize_run(
                run,
                status="timed_out",
                exit_code=exit_code,
                error=f"Timed out after {timeout} seconds",
            )
            return
        status: RunStatus = "succeeded" if exit_code == 0 else "failed"
        _finalize_run(run, status=status, exit_code=exit_code)
    except Exception as exc:
        logger.exception("demo runner: monitor thread crashed for run %s", run.run_id)
        exit_code: int | None = None
        if proc is not None:
            exit_code = proc.poll()
        _finalize_run(run, status="failed", exit_code=exit_code, error=f"{type(exc).__name__}: {exc}")
    finally:
        if watchdog is not None:
            watchdog.cancel()
        if proc is not None and proc.stdout is not None:
            proc.stdout.close()


def _spawn_run(step_id: str, kind: Literal["step", "reset"]) -> _Run:
    script_path = _require_script_available()
    cwd = _repo_root()
    argv = _argv_for(step_id)
    try:
        proc = subprocess.Popen(
            argv,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            shell=False,
            start_new_session=True,
            env=_child_env(),
        )
    except OSError as exc:
        raise APIError(503, "demo_script_unavailable", f"Failed to start SuperCred demo script {script_path}: {exc}") from exc

    run = _Run(
        run_id=uuid4().hex,
        step_id=step_id,
        kind=kind,
        status="running",
        started_at=_utcnow(),
        finished_at=None,
        exit_code=None,
        error=None,
        _process=proc,
        _log=bytearray(),
        _log_truncated=False,
        _timed_out=False,
        _lock=threading.Lock(),
        _done=threading.Event(),
    )
    with _STATE_LOCK:
        global _active
        _active = run
        _runs[run.run_id] = run
        _evict_finished_runs_locked()
    thread = threading.Thread(target=_monitor_run, args=(run,), name=f"demo-runner-{run.run_id}", daemon=True)
    thread.start()
    return run


def _cancel_active() -> None:
    with _STATE_LOCK:
        run = _active
        if run is None or run.status != "running":
            return
        run.status = "cancelled"
        proc = run._process
    if proc is None:
        with _STATE_LOCK:
            if _active is run:
                globals()["_active"] = None
            if run.finished_at is None:
                run.finished_at = _utcnow()
        run._done.set()
        return

    try:
        _kill_process_group(proc, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        logger.info("demo runner: active run %s exited before SIGTERM", run.run_id)

    grace = _cancel_grace_seconds()
    if run._done.wait(grace):
        return

    try:
        _kill_process_group(proc, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        logger.info("demo runner: active run %s exited before SIGKILL", run.run_id)

    if run._done.wait(5):
        return

    with _STATE_LOCK:
        run.exit_code = proc.poll()
        run.error = run.error or f"Cancellation did not complete within {grace + 5} seconds"
        run.finished_at = _utcnow()
        if _active is run:
            globals()["_active"] = None
    run._done.set()


def _start_step_run(step_id: str) -> _Run:
    with _MUTATION_LOCK:
        with _STATE_LOCK:
            active_run = _active
            if active_run is not None and active_run.status == "running":
                raise APIError(
                    409,
                    "demo_run_in_progress",
                    f"A demo step is already running ({active_run.run_id})",
                )
        return _spawn_run(step_id, "step")


def _start_reset_run() -> _Run:
    # Reset is the one operation that preempts a running step, so it never
    # returns 409 -- it cancels first, then runs the idempotent teardown.
    with _MUTATION_LOCK:
        _cancel_active()
        return _spawn_run(RESET_STEP_ID, "reset")


def _run_view(run: _Run) -> RunView:
    with run._lock:
        log_bytes = len(run._log)
        truncated = run._log_truncated
    return RunView(
        run_id=run.run_id,
        step_id=run.step_id,
        kind=run.kind,
        status=run.status,
        started_at=run.started_at,
        finished_at=run.finished_at,
        exit_code=run.exit_code,
        error=run.error,
        log_bytes=log_bytes,
        truncated=truncated,
    )


def _get_run_or_404(run_id: str) -> _Run:
    with _STATE_LOCK:
        run = _runs.get(run_id)
    if run is None:
        raise APIError(404, "run_not_found", f"SuperCred demo run not found: {run_id}")
    return run


def reset_state_for_testing() -> None:
    with _MUTATION_LOCK:
        _cancel_active()
        with _STATE_LOCK:
            global _active
            _active = None
            _runs.clear()


@router.get("/steps", response_model=DemoStepsResponse, responses=ERROR_RESPONSES)
async def list_demo_steps(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> DemoStepsResponse:
    del tenant_id
    return DemoStepsResponse(
        steps=[
            DemoStepView(step_id=step.step_id, title=step.title, description=step.description)
            for step in DEMO_STEPS.values()
        ]
    )


@router.get("/evidence", response_model=EvidenceResponse, responses=ERROR_RESPONSES)
async def credential_chain_evidence(
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> EvidenceResponse:
    """What is observably true about the credential chain, with proof commands.

    Deliberately the SAME script the CLI runs
    (`make demo-signalloom-supercred-evidence`), not a reimplementation of its
    logic in Python. Two implementations of "is there a SPIRE entry" drift, and
    the one nobody runs from a terminal is the one that drifts silently.

    Read-only: it observes and never mutates, so unlike /runs it needs no lock
    and cannot disturb a demo in flight.
    """
    del tenant_id
    path = _evidence_script_path()
    if not _script_is_available(path):
        raise APIError(
            503,
            "evidence_script_unavailable",
            f"SuperCred evidence script is unavailable: {path}",
        )
    try:
        completed = subprocess.run(  # noqa: S603 - fixed argv, no shell, no user input
            [str(path), "json"],
            capture_output=True,
            timeout=90,
            cwd=str(_repo_root()),
            # Same allowlisted child environment as the demo runs. The module
            # docstring names the fixed child env as one of four security
            # boundaries; a read-only probe is no reason to hand a child
            # os.environ. It also carries KUBERNETES_SERVICE_HOST/PORT, without
            # which kubectl has no server and every probe would report
            # "unavailable" from inside the cluster.
            env=_child_env(),
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise APIError(504, "evidence_timeout", "Evidence collection timed out") from exc
    if completed.returncode != 0:
        raise APIError(
            502,
            "evidence_failed",
            f"Evidence collection failed: {completed.stderr.decode(errors='replace')[:400]}",
        )
    try:
        payload = json.loads(completed.stdout.decode(errors="replace"))
    except ValueError as exc:
        # Malformed output is a bug, not an outage: surface it as 502 rather than
        # degrading to a cheerful empty list, which would render as "no evidence"
        # and read identically to "nothing is deployed".
        raise APIError(502, "evidence_malformed", f"Evidence output was not JSON: {exc}") from exc
    return EvidenceResponse(**payload)


@router.post("/runs", response_model=RunView, responses=ERROR_RESPONSES, status_code=202)
async def start_demo_run(
    request: RunRequest,
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> RunView:
    del principal
    # _start_step_run may block briefly on the mutation lock; keep it off the
    # event loop so a concurrent reset's cancellation cannot stall other requests.
    return _run_view(await run_in_threadpool(_start_step_run, request.step))


@router.get("/runs/{run_id}", response_model=RunView, responses=ERROR_RESPONSES)
async def get_demo_run(
    run_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> RunView:
    del tenant_id
    return _run_view(_get_run_or_404(run_id))


@router.get("/runs/{run_id}/log", response_model=RunLogResponse, responses=ERROR_RESPONSES)
async def get_demo_run_log(
    run_id: str,
    principal: Annotated[Principal, Depends(require_superadmin)],
    offset: int = Query(default=0),
) -> RunLogResponse:
    # Superadmin, not merely authenticated. This returns the demo script's RAW
    # stdout/stderr — kubectl output, resource names, OpenBao policy paths, the
    # failure text of anything that went wrong mid-run. The demo's EVIDENCE is
    # meant to be public (that is what /agents and /compliance are for); the
    # script's console output is instructor material and is scoped accordingly.
    del principal
    if offset < 0:
        raise APIError(422, "invalid_log_offset", f"Log offset must be non-negative: {offset}")
    run = _get_run_or_404(run_id)
    with run._lock:
        log_bytes = len(run._log)
        next_offset = min(log_bytes, offset + _LOG_PAGE_BYTES)
        chunk = bytes(run._log[offset:next_offset])
        truncated = run._log_truncated
    eof = run.status != "running" and next_offset == log_bytes
    return RunLogResponse(
        run_id=run_id,
        offset=offset,
        next_offset=next_offset,
        chunk=chunk.decode("utf-8", errors="replace"),
        truncated=truncated,
        eof=eof,
    )


@router.post("/reset", response_model=RunView, responses=ERROR_RESPONSES, status_code=202)
async def reset_demo(
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> RunView:
    del principal
    # Reset waits on process cancellation, so keep the blocking path off the
    # event loop and let other requests stay responsive.
    return _run_view(await run_in_threadpool(_start_reset_run))


@router.get("/status", response_model=DemoStatusResponse, responses=ERROR_RESPONSES)
async def demo_status(
    principal: Annotated[Principal, Depends(require_superadmin)],
) -> DemoStatusResponse:
    # Superadmin, not merely authenticated. `recent` is the run history of a
    # cluster-mutating control plane — which privileged phase was driven, by
    # whom, when, and whether it failed. That is the instructor console, not
    # audience evidence, so it is scoped the same way the controls that
    # produce it are.
    del principal
    with _STATE_LOCK:
        active_run = _active
        recent_runs = list(reversed(list(_runs.values())))
    return DemoStatusResponse(
        active=_run_view(active_run) if active_run is not None else None,
        recent=[_run_view(run) for run in recent_runs],
        script_available=_script_is_available(_script_path()),
    )


def install_demo_runner_api(app: Any) -> None:
    app.include_router(router)
