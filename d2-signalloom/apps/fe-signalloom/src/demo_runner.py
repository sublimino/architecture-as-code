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

import asyncio
import codecs
import json
import logging
import os
import signal
import subprocess
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from types import MappingProxyType
from typing import Annotated, Any, AsyncIterator, Literal, Mapping, cast
from uuid import uuid4

import httpx
from fastapi import APIRouter, Depends, Header, Query
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from api_compat import (
    ERROR_RESPONSES,
    APIError,
    Principal,
    _audit_log,
    _get_pool,
    _record_memory_audit,
    authenticated_tenant,
)
from superadmin import require_superadmin

logger = logging.getLogger(__name__)

_ENV_SCRIPT = "SUPERCRED_DEMO_SCRIPT"
_ENV_EVIDENCE_SCRIPT = "SUPERCRED_EVIDENCE_SCRIPT"
_ENV_CWD = "SUPERCRED_DEMO_CWD"
_ENV_TIMEOUT = "SUPERCRED_DEMO_TIMEOUT_SECONDS"
_ENV_CANCEL_GRACE = "SUPERCRED_DEMO_CANCEL_GRACE_SECONDS"
#: Base URL of the process that holds the audit database.
#:
#: Empty means this process has no durable sink. That is a legitimate state for
#: a test or a no-database demo and an illegitimate one for a deployed runner,
#: so ``/readyz`` in demo_runner_main.py refuses to report ready when it is
#: empty and no local pool exists. A misconfigured runner then never receives
#: traffic, rather than accepting privileged calls and recording them nowhere.
_ENV_AUDIT_SINK = "SIGNALLOOM_AUDIT_SINK_URL"
_AUDIT_SINK_PATH = "/api/audit/privileged-invocations"
#: Short. The record is written before the spawn, so this timeout is on the
#: critical path of a privileged control -- but a slow sink must fail the call
#: rather than hold the operator's request open indefinitely, and a failure
#: here is a refusal to run, which is the safe direction.
_AUDIT_SINK_TIMEOUT_SECONDS = 5.0

_DEFAULT_TIMEOUT_SECONDS = 900
_DEFAULT_CANCEL_GRACE_SECONDS = 10
_LOG_CAP_BYTES = 4 * 1024 * 1024
_LOG_PAGE_BYTES = 64 * 1024
_MAX_RUN_HISTORY = 20
# How often an open SSE stream re-reads the shared log buffer. There is no
# wakeup to subscribe to -- the log is filled by a plain thread appending to a
# bytearray -- so the push endpoint polls that buffer internally and pushes what
# it finds. That is still a categorical improvement on the browser polling over
# HTTP: one connection instead of two per second, and a quarter of the latency.
_SSE_POLL_SECONDS = 0.25
# An SSE comment line on an otherwise idle stream. Demo phase 2 waits up to 300s
# for the credential-chain Job while printing nothing, and both nginx
# (proxy_read_timeout 300s) and any intermediate proxy will drop a connection
# that goes quiet for long enough. 15s is comfortably inside every default.
_SSE_KEEPALIVE_SECONDS = 15.0
# Ceiling on GET /log?wait=. A waiting request occupies a worker thread and
# cannot be cancelled part-way, so this is the longest a client that has walked
# away can keep one -- the bound on the damage, not a recommended value.
_MAX_LOG_WAIT_SECONDS = 30.0
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

# Constants the runner SETS for the child, as opposed to values it forwards from
# its own environment. These are not part of _ENV_ALLOWLIST because nothing is
# inherited: no parent value can influence them, so they widen the allowlist
# boundary by exactly nothing.
#
# PYTHONUNBUFFERED is the child half of the streaming fix. Reading the pipe with
# read1 (see _monitor_run) makes the PARENT hand bytes over the moment they
# arrive, but it cannot help if the child never wrote them: CPython
# block-buffers stdout at 8KiB whenever it is not a tty, so any Python step in
# the demo script's chain would sit on its output until exit and reproduce the
# original symptom one process further down. Shell builtins write(2) straight
# through and Go tools (kubectl) do not buffer a pipe, so bash and kubectl need
# nothing here.
#
# There is deliberately no equivalent for a libc-stdio child (a C program
# block-buffering a pipe). The only environmental lever for that is coreutils'
# stdbuf, which works by LD_PRELOAD-ing a shim and setting private _STDBUF_*
# variables -- an implementation detail of another package, injected into a
# security-relevant fixed environment. If a C binary in the chain ever buffers,
# the honest fix is stdbuf in the demo script at the call site, where it is
# visible.
_CHILD_CONSTANT_ENV = MappingProxyType(
    {
        "PYTHONUNBUFFERED": "1",
    }
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
    # Shares _lock, so a waiter can test the buffer and park without a window
    # in between for a notify to slip through and be missed. See
    # _wait_for_new_log_bytes.
    _log_changed: threading.Condition
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
# Open SSE log streams. This is instrumentation, and it exists because "a
# disconnected client leaves nothing running behind it" is otherwise an
# unfalsifiable claim -- the generator's cleanup happens inside the server's
# event loop, where a test has nothing to observe. Incremented when a stream
# starts and decremented in its finally, so a test can assert the count returns
# to zero after a client walks away. Cheap enough to keep in production, where
# it is also the number a "why is this pod busy?" question would want.
_STREAM_LOCK = threading.Lock()
_open_log_streams = 0

router = APIRouter(prefix="/api/demo/supercred", tags=["demo-runner"])


class DemoStepView(BaseModel):
    step_id: str
    title: str
    description: str


class DemoStepsResponse(BaseModel):
    steps: list[DemoStepView]


class EvidenceProofView(BaseModel):
    """One command, and what it printed, backing part of a step's verdict.

    A step used to carry exactly one command, so a verdict that rested on
    several observations could only publish one of them — and step 6 ("has the
    platform responded?") rests on three: the OpenBao revocation that is the
    mechanism, the stun annotation that merely corroborates it, and the
    NetworkPolicy that contains it. Publishing one of three made whichever one
    was published the de facto definition of the step.
    """

    label: str
    command: str
    detail: str


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
    # Every proof behind the verdict, the primary one first. Defaulted rather
    # than required so a runner image shipping an older evidence script still
    # deserialises: the browser synthesises a single proof from command/detail
    # in that case, which is exactly what the old shape meant.
    proofs: list[EvidenceProofView] = []


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
    # Applied after the allowlist so a forwarded value can never quietly
    # override a constant the runner depends on.
    child_env.update(_CHILD_CONSTANT_ENV)
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
        # Raw bytes in, raw bytes stored. Nothing here decodes: read1 chops the
        # pipe at arbitrary offsets, and a bytearray is the only representation
        # that can hold half a multi-byte character until its other half
        # arrives. Decoding belongs at the read endpoints, which know whether
        # more bytes are still coming.
        run._log_changed.notify_all()


def _notify_log_waiters(run: _Run) -> None:
    """Wake every long-poll waiter parked on this run.

    Called when a run reaches a terminal state. Missing this is the subtle
    half: a waiter woken only by output would sit out its whole deadline every
    time a run ended quietly, which is exactly what happens at the end of every
    phase -- the last thing a step does is exit, not print.
    """
    with run._lock:
        run._log_changed.notify_all()


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
    # Outside the _STATE_LOCK block on purpose: this takes run._lock, and
    # taking it while holding _STATE_LOCK would invert the order every other
    # path uses.
    _notify_log_waiters(run)


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
            # read1, NOT read. This is the difference between a live console and
            # a console that stays blank for the whole run.
            #
            # BufferedReader.read(n) is a fill-EXACTLY-n read: it loops on the
            # raw pipe until it has n bytes or reaches EOF. Every demo phase
            # prints a few hundred bytes of banner and then blocks on kubectl
            # for seconds to minutes, so with read(8192) the first byte reached
            # run._log only when the child exited and closed the pipe. The
            # dashboard polls /log every 500ms into a purpose-built streaming
            # console; it rendered nothing at all for a multi-minute phase and
            # then filled in one jump.
            #
            # read1(n) issues at most one raw read and returns whatever is
            # already there. Measured against a script printing a line every
            # 250ms for 3s:
            #
            #   read(8192)  -> 1 chunk delivered at 3.01s
            #   read1(8192) -> 12 chunks at 0.00s, 0.25s, 0.50s ... 2.76s
            #
            # Do not "tidy" this back to read(). tests/test_demo_runner_streaming.py
            # asserts the wall-clock property rather than the final text,
            # because every assertion of the form "the finished log contains X"
            # is equally true of the batching behaviour and stayed green
            # throughout the period this was broken.
            chunk = proc.stdout.read1(8192)
            if chunk is None:
                # None and b"" are NOT the same answer, and `if not chunk`
                # cannot tell them apart. b"" means the write end is gone --
                # EOF, stop. None means "nothing ready right now", which is
                # what read1 returns on a non-blocking fd. Nothing here sets
                # O_NONBLOCK, so this should be unreachable; it is written
                # anyway because the failure it prevents is silent. Treating
                # None as EOF would end the capture at whatever had arrived and
                # report the run as complete with a truncated log -- and the
                # dashboard cannot distinguish a truncated log from a short
                # one. Sleep rather than spin, so a genuinely non-blocking fd
                # degrades to a poll instead of burning a core.
                time.sleep(0.01)
                continue
            if chunk == b"":
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

    # Built first so the Condition can share it -- a Condition over a different
    # lock than the one guarding _log would protect nothing.
    run_lock = threading.Lock()
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
        _lock=run_lock,
        _log_changed=threading.Condition(run_lock),
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
    # The status flip is itself a terminal transition a waiter is parked on, so
    # wake them here rather than only when the monitor thread finalises -- a
    # cancelled run may take the full SIGTERM grace period to get that far.
    _notify_log_waiters(run)
    if proc is None:
        with _STATE_LOCK:
            if _active is run:
                globals()["_active"] = None
            if run.finished_at is None:
                run.finished_at = _utcnow()
        run._done.set()
        _notify_log_waiters(run)
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
    _notify_log_waiters(run)


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


def _audit_sink_url() -> str:
    """Base URL of the durable audit sink, or empty when there is none."""
    return os.environ.get(_ENV_AUDIT_SINK, "").strip().rstrip("/")


async def _post_audit_sink(
    url: str, *, json: dict[str, Any], headers: dict[str, str],
) -> None:
    """POST the invocation to fe-signalloom, raising on anything but success.

    Separated from its caller so tests can substitute it. It raises rather than
    returning a status because every non-2xx answer means the same thing to the
    caller -- no row was written -- and collapsing them here keeps the
    fail-closed decision in one place.
    """
    async with httpx.AsyncClient(timeout=_AUDIT_SINK_TIMEOUT_SECONDS) as client:
        response = await client.post(url, json=json, headers=headers)
    response.raise_for_status()


async def _record_privileged_invocation(
    principal: Principal,
    event_type: str,
    detail: dict[str, Any],
    authorization: str | None = None,
) -> None:
    """Record a superadmin invoking a privileged, cluster-mutating control.

    Written BEFORE the process is spawned, and deliberately so. An audit row
    added on completion is missing from exactly the cases worth investigating:
    the pod is killed mid-run, the script wedges, the node goes away. The
    security-relevant fact is that someone with superadmin invoked this against
    the cluster -- that is true the moment the request is authorised, and it
    must not be contingent on the run finishing tidily.

    The run_id ties the row to the outcome, which ``GET /api/demo/status``
    already reports. Recording the exit status here as well would mean either
    two rows per run or a row that cannot be written until the end; the
    invocation is the durable half and the one that cannot be reconstructed
    afterwards.

    Nothing transactional is available: the state change this records is a
    subprocess and a mutated cluster, not a database row, so there is no write
    to bind to. Ordering is the guarantee instead -- audit first, spawn second,
    so a spawn cannot occur without a record, and a failed audit means no run.

    This replaced ``recordStunAudit()`` in SuperCredInstructorPanel.tsx, where
    the browser POSTed the audit event after a phase succeeded. That made the
    record contingent on a tab staying open and a token staying valid, and its
    payload was a hardcoded string the client asserted rather than anything the
    server observed. What is recorded here is only what the runner actually
    knows: which step, which principal, when.

    It follows that this row does NOT claim the cluster action succeeded. The
    relabel and the OpenBao lease revocation belong to the SuperCred proxy,
    which reports to nobody; naming an outcome here would reintroduce the
    fabrication in a new place.

    Where the row goes, and why it stopped going nowhere
    ----------------------------------------------------
    This function used to end at ``_record_memory_audit`` whenever
    ``_get_pool()`` returned None, and in the deployed runner it returned None
    on every call: ``demo_runner_main.py`` mounts this router precisely so the
    workload "must not initialise the PostgreSQL pool", and the Deployment
    carries no database configuration of any kind. So every privileged phase
    run and every reset went into a module-level dict in the pod that the demo
    restarts -- the per-process history this mechanism was built to replace,
    reintroduced one layer down. The test suite could not see it because those
    tests mount ``main:app``, where this router and ``api_compat``'s in-memory
    store share a process and the store is therefore present.

    The fix is not a database connection here. The runner is the one workload
    that executes privileged scripts against the cluster, and its NetworkPolicy
    is written tightly enough to explain in comments what is deliberately
    absent; 5432 is absent. Reachability into Postgres is a large thing to
    grant this pod in exchange for a wider audit trail. Instead the record is
    forwarded to fe-signalloom, which already holds the pool, authenticated
    with the operator's own bearer token -- the same token this process has
    just validated, from the same issuer and for the same audience
    fe-signalloom validates against, so no new credential is minted or stored.

    Only ``step_id`` and ``kind`` travel. ``actor``, ``event_type`` and the
    rest are re-derived at the far end from the token, because a field that
    crosses the wire is a field the next caller could author.

    Three paths, in order of preference:

    1. A local pool -- fe-signalloom's own copy of this router. Writes directly.
    2. A configured sink -- the deployed runner. Forwards, and **fails closed**:
       an unreachable sink raises, the handler never reaches the spawn, and the
       operator gets a 503 instead of an unrecorded privileged run. That
       preserves the property the audit-before-spawn ordering was chosen for.
       Swallowing the error would keep the ordering and lose the guarantee.
    3. Neither -- tests and the no-database demo. Records in memory and says so
       at WARNING. A deployed runner cannot reach this branch quietly:
       ``/readyz`` refuses readiness when there is no pool and no sink, so the
       pod never receives traffic in that state.
    """
    actor = principal.actor
    pool = await _get_pool()
    if pool is not None:
        await _audit_log(
            pool,
            tenant_id=principal.tenant,
            event_type=event_type,
            agent_id=None,
            agent_name=None,
            actor=actor,
            detail=detail,
        )
        return

    sink = _audit_sink_url()
    if sink:
        if not authorization:
            # Unreachable through the routes -- both are superadmin-gated, so a
            # validated bearer got us here. Treated as a failure rather than
            # asserted away because the failure mode of guessing wrong is an
            # unauthenticated forward that 401s and is then swallowed.
            logger.error("privileged invocation not forwarded: no bearer token to present")
            raise APIError(
                503, "audit_unavailable",
                "The privileged invocation could not be recorded, so it was not started.",
            )
        try:
            await _post_audit_sink(
                f"{sink}{_AUDIT_SINK_PATH}",
                json={"step_id": detail["step_id"], "kind": detail["kind"]},
                headers={"Authorization": authorization},
            )
        except Exception as exc:
            # Deliberately broad. Every way this can fail -- connection refused,
            # DNS, timeout, 4xx, 5xx -- means the same thing to the caller: no
            # row was written. Narrowing it to httpx's hierarchy would let an
            # unanticipated error through as a silent success, which is the
            # exact defect being fixed.
            logger.error(
                "privileged invocation not recorded, refusing to start it: %s", exc,
                exc_info=True,
            )
            raise APIError(
                503, "audit_unavailable",
                "The privileged invocation could not be recorded, so it was not started.",
            ) from exc
        return

    logger.warning(
        "no audit pool and no %s configured: recording %s in memory, which does not "
        "survive this process", _ENV_AUDIT_SINK, event_type,
    )
    _record_memory_audit(
        principal.tenant, event_type, None, None, actor, detail,
    )


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


class _WaiterPool:
    """How many `wait=` calls may hold an anyio worker thread at once.

    Sized well under anyio's default limiter (40) so parked waiters can never
    be the reason a control-plane call has no thread to run on. One instructor
    with a handful of tabs is the real load; the cap exists for the abandoned
    ones, which a browser produces every time a tab is closed mid-wait.
    """

    def __init__(self, limit: int) -> None:
        self._limit = limit
        self._held = 0
        self._lock = threading.Lock()

    def acquire(self) -> bool:
        with self._lock:
            if self._held >= self._limit:
                return False
            self._held += 1
            return True

    def release(self) -> None:
        with self._lock:
            self._held = max(0, self._held - 1)

    def held(self) -> int:
        with self._lock:
            return self._held


_MAX_CONCURRENT_LOG_WAITERS = 8
_log_waiters = _WaiterPool(_MAX_CONCURRENT_LOG_WAITERS)


def _more_bytes_possible(run: _Run) -> bool:
    """Whether another byte can still enter ``run._log``.

    Deliberately NOT "is the run still running", and the difference is two
    separate defects that both read as the same innocuous line.

    TOO EARLY. `_cancel_active` flips `status` to "cancelled" the moment it
    sends SIGTERM, while the monitor thread is still draining the pipe. A demo
    script that traps TERM prints its cleanup on the way out -- which is
    precisely the output someone reaching for Reset wants -- so a reader that
    treats the status flip as end-of-stream stops exactly one moment before the
    interesting part. Capture is finished when the monitor says so (`_done`,
    set by `_finalize_run` after the read loop has drained and the child has
    been reaped), not when the control plane changes its mind.

    TOO LATE. Once the log hits `_LOG_CAP_BYTES` nothing further is ever
    appended, but `status` stays "running" for as long as the script does. That
    combination wedges a reader: the trailing-character hold-back waits for a
    continuation that cannot arrive, so `next_offset` stops advancing, while
    `eof` stays False because the run has not ended. The client polls the same
    offset forever, receiving nothing and never being told it is finished.

    One predicate, because both callers -- the hold-back and the eof test --
    are asking the same question and got different wrong answers to it.
    """
    if len(run._log) >= _LOG_CAP_BYTES:
        return False
    if run.status == "running":
        return True
    # Every other terminal status is set BY the monitor thread, in
    # `_finalize_run`, after its read loop has drained the pipe and the child
    # has been reaped -- so by the time one is visible, capture really is over.
    # `cancelled` is the single exception: `_cancel_active` sets it on the way
    # IN to the kill, and only `_done` marks the drain actually finishing.
    if run.status == "cancelled":
        return not run._done.is_set()
    return False


def _wait_for_new_log_bytes(run: _Run, offset: int, seconds: float) -> None:
    """Block until the run has bytes past ``offset``, ends, or the deadline passes.

    This is what turns /log from a 500ms-floor poll into something that
    delivers within milliseconds of the producer emitting. The dashboard polls
    on a timer, so with no wait the best case is half a poll interval of
    latency and the worst is a full one, no matter how fast the script prints.

    The buffer test and the park happen under the same lock the writer takes,
    which is the whole reason _log_changed is a Condition over run._lock rather
    than a bare Event: between "is there anything new?" and "wait", there is no
    window for a notify to be delivered and lost. Returns rather than raises on
    timeout -- a wait that expires is a normal empty read, not an error.
    """
    deadline = time.monotonic() + seconds
    with run._lock:
        while True:
            if len(run._log) > offset or not _more_bytes_possible(run):
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            run._log_changed.wait(remaining)


def _sse_frame(event: str, payload: Mapping[str, Any]) -> bytes:
    # json.dumps escapes newlines, so however many lines the demo script printed
    # the data field stays exactly one SSE line and the frame stays parseable.
    return f"event: {event}\ndata: {json.dumps(dict(payload))}\n\n".encode("utf-8")


def _decodable_prefix(chunk: bytes, *, more_bytes_expected: bool) -> tuple[bytes, bytes]:
    """Split a chunk into (safe to decode now, hold back until more arrives).

    Offsets in this API are BYTE offsets into a stream that is chopped up by
    whatever the child happened to have written when the pipe was read. Under
    the poll endpoint a boundary lands mid-character roughly never, because it
    only chops every 64KiB; a push stream chops at every partial read, so a
    multi-byte character straddling a boundary is a routine event rather than a
    curiosity. Decoding it with errors="replace" would burn it to U+FFFD and no
    later chunk could put it back.

    So an incomplete trailing sequence is held back and re-read on the next
    pass, which costs one poll interval and keeps the offsets exact.

    The distinction that matters is between a truncated character and a
    genuinely malformed one. Holding back bytes that can never become valid --
    a stray 0xFF, say -- would park them until the run ended, waiting for a
    continuation that is not coming. The stdlib's incremental decoder already
    draws exactly this line: with final=False it buffers a truncated sequence
    and reports it through getstate(), while replacing invalid bytes on the
    spot. So malformed input still degrades to errors="replace" precisely as it
    does on /log, and only a real half-character waits.

    Once the run is over nothing more can arrive, there is nothing to wait for,
    and the whole chunk is handed over as-is.
    """
    if not more_bytes_expected:
        return chunk, b""
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    decoder.decode(chunk, False)
    pending, _ = decoder.getstate()
    if not pending:
        return chunk, b""
    return chunk[: len(chunk) - len(pending)], bytes(pending)


async def _iter_run_log_events(run: _Run, offset: int) -> AsyncIterator[bytes]:
    """Push the run's log as SSE frames, resuming from a byte offset.

    Reads the SAME run._log the poll endpoint reads. There is deliberately no
    second capture off the subprocess: one capture with two readers cannot
    disagree about what the script printed, whereas two captures eventually
    will, and the one nobody is watching is the one that drifts.
    """
    global _open_log_streams
    with _STREAM_LOCK:
        _open_log_streams += 1
    try:
        last_frame_at = time.monotonic()
        while True:
            # Sample the terminal flag BEFORE the buffer. status only ever moves
            # forwards (running -> terminal), so a stale "still running" reading
            # costs one more poll and nothing else. Read the other way round, a
            # run that finished between the two reads would report eof against a
            # buffer snapshot taken before the monitor thread's final append,
            # and the stream would end one chunk short of the truth.
            # `_more_bytes_possible`, not `status == "running"`: a cancelled run
            # is still draining its child's TERM-trap cleanup, and a capped log
            # has stopped accepting bytes while the script runs on. See that
            # function -- both mistakes end this stream at the wrong moment.
            still_running = _more_bytes_possible(run)
            with run._lock:
                log_bytes = len(run._log)
                page_end = min(log_bytes, offset + _LOG_PAGE_BYTES)
                chunk = bytes(run._log[offset:page_end])
                truncated = run._log_truncated
            body, _held_back = _decodable_prefix(chunk, more_bytes_expected=still_running)

            if body:
                chunk_start = offset
                offset += len(body)
                yield _sse_frame(
                    "log",
                    {
                        "run_id": run.run_id,
                        "offset": chunk_start,
                        "next_offset": offset,
                        "chunk": body.decode("utf-8", errors="replace"),
                        "truncated": truncated,
                        "eof": False,
                    },
                )
                last_frame_at = time.monotonic()
                # Straight back round without sleeping: a finished run, or a
                # burst larger than one page, drains at full speed.
                continue

            if not still_running and page_end >= log_bytes:
                yield _sse_frame(
                    "end",
                    {
                        "run_id": run.run_id,
                        "offset": offset,
                        "next_offset": offset,
                        "chunk": "",
                        "truncated": truncated,
                        "eof": True,
                        "status": run.status,
                        "exit_code": run.exit_code,
                    },
                )
                return

            now = time.monotonic()
            if now - last_frame_at >= _SSE_KEEPALIVE_SECONDS:
                # A bare SSE comment. Ignored by every EventSource client, and
                # the only thing standing between a silent 300s demo phase and
                # an idle-timeout disconnect.
                yield b": keepalive\n\n"
                last_frame_at = now
            await asyncio.sleep(_SSE_POLL_SECONDS)
    finally:
        # Runs on client disconnect too: Starlette closes the generator when the
        # response task is cancelled, which raises in at the await above.
        with _STREAM_LOCK:
            _open_log_streams -= 1


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
    # Taken raw as well as validated: `Principal` carries the identity but not
    # the token, and a pool-less runner has to present the token itself to the
    # audit sink. Nothing authorises off this header -- `require_superadmin`
    # has already decided that from the validated claims.
    authorization: Annotated[str | None, Header()] = None,
) -> RunView:
    # Audited before the spawn: a privileged phase must not be able to run
    # without a record of who asked for it. This raises 503 rather than
    # returning if the record cannot be made durable, so the ordering is a
    # guarantee and not merely a sequence.
    await _record_privileged_invocation(
        principal, "demo.phase_run", {"step_id": request.step, "kind": "step"},
        authorization,
    )
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
    wait: float = Query(default=0.0),
) -> RunLogResponse:
    """The demo script's console output, from a byte offset.

    `wait` is optional and defaults to 0, which is the original non-blocking
    behaviour exactly. Given a positive value, a caller that is already at the
    end of the buffer parks until new bytes arrive, the run ends, or the
    deadline passes — then answers normally. It changes latency, never shape:
    the response is the same model with the same fields, and a timed-out wait
    is an ordinary empty read rather than an error.

    A long poll is deliberately preferred over the SSE route for the default
    path. The response is an ordinary short HTTP response, so it is immune to
    proxy buffering, gzip block-filling, HTTP/1.0 upstreams and compressor
    filters — every layer that can silently swallow a stream and leave a blank
    console with no error to debug.

    An incomplete trailing character is held back rather than decoded with
    errors="replace", the same as the SSE route. This endpoint used to reason
    that its boundary falls only every _LOG_PAGE_BYTES, so a split character
    was a curiosity worth accepting. `wait` falsified that: a waiting caller is
    released the instant new bytes land and therefore reads to the END of the
    buffer, so the boundary is now wherever read1 happened to stop — every
    poll, not every 64KiB. Measured against a script printing six ✓ across the
    gap, all six came back as ✗-shaped mojibake (twelve U+FFFD) while the raw
    buffer decoded cleanly throughout: the corruption was manufactured here,
    on the path the dashboard actually uses. Phase 3's compliance summary emits
    ✅/❌ from a python3 heredoc, so this is what an audience would have seen.
    """
    # Superadmin, not merely authenticated. This returns the demo script's RAW
    # stdout/stderr — kubectl output, resource names, OpenBao policy paths, the
    # failure text of anything that went wrong mid-run. The demo's EVIDENCE is
    # meant to be public (that is what /agents and /compliance are for); the
    # script's console output is instructor material and is scoped accordingly.
    del principal
    if offset < 0:
        raise APIError(422, "invalid_log_offset", f"Log offset must be non-negative: {offset}")
    if wait < 0:
        raise APIError(422, "invalid_log_wait", f"Log wait must be non-negative: {wait}")
    run = _get_run_or_404(run_id)
    if wait > 0:
        # Off by default, so a client that never sends `wait` gets byte-for-byte
        # the behaviour this endpoint has always had.
        #
        # In a thread because the wait is a blocking Condition on a buffer the
        # producer fills from a plain thread; parking the event loop on it would
        # stall every other request in the pod. The cap bounds what a client can
        # ask a worker thread to hold: an abandoned waiter cannot be cancelled
        # mid-wait, so it returns at its deadline and no later, and the cap is
        # what makes "no later" a short time rather than an arbitrary one.
        # The cap is a liveness guard on the pod, not on the caller. A parked
        # wait holds an anyio worker thread, and that pool is shared with every
        # other threadpool-backed route here -- including POST /runs and POST
        # /reset. `run_in_threadpool` is not cancellable: when a browser tab
        # closes mid-wait the coroutine is cancelled but the thread stays parked
        # until its own deadline, so abandoned waiters accumulate at the rate
        # tabs are closed. Exhaust the pool and Reset stops responding, on
        # stage, which is the exact moment it is needed.
        #
        # Over the cap the request degrades to the non-blocking read it would
        # have been without `wait` -- a little more latency, never a stall.
        if _log_waiters.acquire():
            try:
                await run_in_threadpool(
                    _wait_for_new_log_bytes, run, offset, min(wait, _MAX_LOG_WAIT_SECONDS)
                )
            finally:
                _log_waiters.release()
    with run._lock:
        log_bytes = len(run._log)
        next_offset = min(log_bytes, offset + _LOG_PAGE_BYTES)
        chunk = bytes(run._log[offset:next_offset])
        truncated = run._log_truncated
    # Hold back an incomplete trailing character, exactly as the SSE route does.
    # `more_bytes_expected` is what keeps that safe: once the run is over nothing
    # further can arrive, so the tail is handed over whole and `eof` is always
    # reachable. A run that ends between this read and the next simply releases
    # the held bytes on the following poll -- at most three bytes, one interval.
    more_possible = _more_bytes_possible(run)
    chunk, _held = _decodable_prefix(chunk, more_bytes_expected=more_possible)
    next_offset -= len(_held)
    eof = not more_possible and next_offset == log_bytes
    return RunLogResponse(
        run_id=run_id,
        offset=offset,
        next_offset=next_offset,
        chunk=chunk.decode("utf-8", errors="replace"),
        truncated=truncated,
        eof=eof,
    )


@router.get("/runs/{run_id}/stream", response_class=StreamingResponse, responses=ERROR_RESPONSES)
async def stream_demo_run_log(
    run_id: str,
    principal: Annotated[Principal, Depends(require_superadmin)],
    offset: int = Query(default=0),
) -> StreamingResponse:
    """The same log as /log, pushed instead of polled.

    ADDITIVE. /log stays the tested default and its behaviour is unchanged: a
    client that ignores this route entirely still works exactly as before. This
    exists because a 500ms poll shows a demo audience a console that updates in
    visible steps, and because two requests a second for minutes is a poor way
    to carry a byte stream.

    Superadmin, for the identical reason /log is superadmin and not merely
    authenticated: this is the demo script's RAW stdout/stderr -- kubectl
    output, resource names, OpenBao policy paths, the failure text of whatever
    went wrong. Changing the transport does not change the audience.

    Offset semantics are /log's, exactly: `offset` is where the event's chunk
    starts, `next_offset` is where the next read resumes. A client that
    reconnects with the last `next_offset` it saw gets no gap and no repeat, so
    a dropped connection costs nothing and a client may freely switch between
    this route and /log.

    Both failure modes are resolved BEFORE the response begins. Once the first
    byte of a 200 is on the wire an error can only be delivered as a stream
    event, which no EventSource client would recognise -- so a bad offset or an
    unknown run must 422/404 here, in the handler, not in the generator.
    """
    del principal
    if offset < 0:
        raise APIError(422, "invalid_log_offset", f"Log offset must be non-negative: {offset}")
    run = _get_run_or_404(run_id)
    return StreamingResponse(
        _iter_run_log_events(run, offset),
        media_type="text/event-stream",
        headers={
            # no-transform bars a proxy from gzipping the stream, which would
            # reintroduce buffering at the compressor. X-Accel-Buffering is
            # nginx's per-response opt-out and belt-and-braces with the
            # proxy_buffering off in the dashboard's nginx.conf: the response
            # carries its own requirement even behind a proxy nobody edited.
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no",
        },
    )


@router.post("/reset", response_model=RunView, responses=ERROR_RESPONSES, status_code=202)
async def reset_demo(
    principal: Annotated[Principal, Depends(require_superadmin)],
    # As in start_demo_run: forwarded to the audit sink, never authorised from.
    authorization: Annotated[str | None, Header()] = None,
) -> RunView:
    # The most destructive control in the product: it preempts and cancels
    # whatever privileged phase is running, then tears the demo down. Its only
    # history was a per-process dict that dies with the pod, and in the deployed
    # runner that dict was the only place it ever went.
    await _record_privileged_invocation(
        principal,
        "demo.reset_requested",
        {"step_id": RESET_STEP_ID, "kind": "reset", "preempts_active_run": True},
        authorization,
    )
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
