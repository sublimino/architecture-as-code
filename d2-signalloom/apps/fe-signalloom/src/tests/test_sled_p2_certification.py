"""SLED-P2-GOV certification probes for the Phase 2 ReaperDaemon.

Each test is one probe cited by docs/signalloom/sled-p2-certification.md.
Properties the daemon has are plain tests. Defects the certification found are
``xfail(strict=True)``: they assert the *correct* behaviour, so the day a defect
is fixed the test XPASSes, the suite goes red, and the marker (and the
certification record) must be updated. A defect cannot be silently fixed or
silently regress.
"""

from __future__ import annotations

import asyncio
import gc
import logging
import threading
import time
import tracemalloc
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi import FastAPI

import environment_lifecycle as el
from environment_lifecycle import (
    EnvironmentLifecycleState,
    LifecycleManager,
    ReaperDaemon,
    install_environment_lifecycle_api,
)

import eap_tenancy
from conftest import EAP_OPERATOR, EAP_TENANT_A, EAPClient, eap_bearer

# EAPR-P2-1: install_environment_lifecycle_api mounts the lifecycle router behind
# authenticated_principal, so the scratch apps below need a real tenant-a token.
EAP_AUTHENTICATED = True

FLEET = 1000


def _fleet(mgr: LifecycleManager, n: int = FLEET, expired_every: int = 2) -> None:
    """Register n ACTIVE environments; every `expired_every`-th one has an expired lease."""
    past = datetime.now(timezone.utc) - timedelta(seconds=10)
    for i in range(n):
        h = f"{i:08x}"
        mgr.register_environment(f"tenant-{i}", customer_hash=h, ttl_minutes=60)
        mgr.transition_state(h, EnvironmentLifecycleState.ACTIVE)
        if i % expired_every == 0:
            mgr._records[h] = mgr._records[h].model_copy(update={"expires_at": past})


async def _max_loop_lag(stop: asyncio.Event, tick: float = 0.001) -> float:
    """Ticker coroutine: the worst observed overshoot of a `tick`-second sleep."""
    worst = 0.0
    while not stop.is_set():
        t0 = time.perf_counter()
        await asyncio.sleep(tick)
        worst = max(worst, time.perf_counter() - t0 - tick)
    return worst


def _app(mgr: LifecycleManager, daemon: ReaperDaemon, monkeypatch) -> FastAPI:
    monkeypatch.setattr(el, "GLOBAL_LIFECYCLE_MANAGER", mgr)
    monkeypatch.setattr(el, "GLOBAL_REAPER_DAEMON", daemon)
    app = FastAPI()
    install_environment_lifecycle_api(app)
    return app


# ---------------------------------------------------------------- event loop


@pytest.mark.anyio
async def test_reaper_pass_over_1000_envs_is_sub_second_and_loop_lag_bounded():
    mgr = LifecycleManager()
    _fleet(mgr)
    daemon = ReaperDaemon(lifecycle_manager=mgr)
    stop = asyncio.Event()
    lag_task = asyncio.create_task(_max_loop_lag(stop))
    durations = []
    for _ in range(3):  # drain -> (grace not yet) -> steady state
        s = await daemon.run_reconciliation_pass()
        durations.append(s.duration_ms)
        await asyncio.sleep(0.005)
    stop.set()
    lag = await lag_task
    print(f"\nCERT pass_duration_ms={durations} max_loop_lag_ms={lag * 1000:.2f}")
    assert max(durations) < 1000.0, durations
    assert lag < 0.25, f"event loop stalled {lag * 1000:.1f}ms during a 1000-env pass"
    assert durations[0] > 0 and daemon.cycle_count == 3


@pytest.mark.anyio
async def test_1000_concurrent_lifecycle_queries_alongside_manual_and_scheduled_reaps(monkeypatch, fresh_tenant_ownership):
    mgr = LifecycleManager()
    _fleet(mgr)
    # The fleet is registered on the manager, not via POST: bind every hash to
    # tenant-a so the hash-addressed GETs below are not 404.
    for i in range(FLEET):
        eap_tenancy.GLOBAL_TENANT_OWNERSHIP.claim(f"{i:08x}", EAP_TENANT_A)
    daemon = ReaperDaemon(lifecycle_manager=mgr, base_interval=0.01, min_interval=0.01, max_interval=0.01)
    app = _app(mgr, daemon, monkeypatch)
    transport = httpx.ASGITransport(app=app)
    daemon.start()
    try:
        # operator: reap-now is process-wide and operator-only; the operator is a tenant-a principal, so the GETs still 200
        async with httpx.AsyncClient(transport=transport, base_url="http://t", headers=eap_bearer(EAP_OPERATOR)) as c:
            gets = [c.get(f"/api/v1/eap/lifecycle/environments/{i:08x}") for i in range(FLEET)]
            reaps = [c.post("/api/v1/eap/lifecycle/reap-now") for _ in range(20)]
            t0 = time.perf_counter()
            responses = await asyncio.gather(*gets, *reaps)
            elapsed = time.perf_counter() - t0
    finally:
        await daemon.stop()
    codes = {r.status_code for r in responses}
    print(f"\nCERT 1000_queries+20_manual_reaps elapsed_s={elapsed:.3f} codes={codes} cycles={daemon.cycle_count}")
    assert codes == {200}
    # Every manual reap produced a completed, serialised pass; scheduled passes also ran.
    assert all(r.json()["status"] == "completed" for r in responses[FLEET:])
    assert daemon.cycle_count >= 20
    # Drain happened exactly once per expired env despite 20+ racing passes.
    drains = [e for e in mgr.get_audit_events() if e.current_state == "draining"]
    assert len({e.customer_hash for e in drains}) == len(drains)


@pytest.mark.anyio
async def test_manual_and_scheduled_passes_never_overlap():
    mgr = LifecycleManager()
    _fleet(mgr, n=200)
    daemon = ReaperDaemon(lifecycle_manager=mgr, base_interval=0.001, min_interval=0.001, max_interval=0.001)
    inside, overlaps = 0, 0
    real = mgr.evaluate_reaping

    def probe(now=None):
        nonlocal inside, overlaps
        inside += 1
        overlaps += inside > 1
        try:
            return real(now=now)
        finally:
            inside -= 1

    mgr.evaluate_reaping = probe
    daemon.start()
    await asyncio.gather(*(daemon.run_reconciliation_pass() for _ in range(50)))
    await daemon.stop()
    assert overlaps == 0


# ----------------------------------------------------------- fault injection


@pytest.mark.anyio
async def test_backend_exceptions_do_not_terminate_the_reaper_loop():
    mgr = LifecycleManager()
    daemon = ReaperDaemon(lifecycle_manager=mgr, base_interval=0.005, min_interval=0.005, max_interval=0.005)
    faults = {"left": 25}
    real = mgr.evaluate_reaping

    def flaky(now=None):
        if faults["left"] > 0:
            faults["left"] -= 1
            raise ConnectionError("simulated backend/API failure")
        return real(now=now)

    mgr.evaluate_reaping = flaky
    daemon.start()
    deadline = time.monotonic() + 5
    while (faults["left"] > 0 or daemon.cycle_count < 5) and time.monotonic() < deadline:
        await asyncio.sleep(0.01)
    alive = daemon._task is not None and not daemon._task.done()
    await daemon.stop()
    print(f"\nCERT injected_faults=25 survived={alive} successful_cycles_after={daemon.cycle_count}")
    assert faults["left"] == 0
    assert alive
    assert daemon.cycle_count >= 5


class _Fatal(BaseException):
    """A non-Exception fault. (SystemExit/KeyboardInterrupt are re-raised out of the
    event loop by asyncio itself, which is the correct process-level behaviour.)"""


def _fatal_daemon() -> ReaperDaemon:
    mgr = LifecycleManager()

    def fatal(now=None):
        raise _Fatal("simulated fatal fault")

    mgr.evaluate_reaping = fatal
    return ReaperDaemon(lifecycle_manager=mgr, base_interval=0.005, min_interval=0.005, max_interval=0.005)


@pytest.mark.anyio
async def test_base_exception_other_than_cancel_is_not_swallowed_silently():
    """A BaseException fault ends the task visibly rather than being looped over."""
    daemon = _fatal_daemon()
    daemon.start()
    await asyncio.sleep(0.05)
    assert daemon._task.done()
    with pytest.raises(_Fatal):
        daemon._task.result()


@pytest.mark.anyio
@pytest.mark.xfail(strict=True, reason="SLED-P2-GOV D5: get_status()/`/reaper/status` reports "
                   "is_running=True from a flag, not from task liveness, after the loop task has died")
async def test_status_reports_dead_reaper_task_as_not_running():
    daemon = _fatal_daemon()
    daemon.start()
    await asyncio.sleep(0.05)
    assert daemon._task.done()
    assert daemon.get_status().is_running is False


def test_per_environment_failure_is_isolated_and_dead_lettered():
    mgr = LifecycleManager()
    _fleet(mgr, n=10, expired_every=1)
    real = mgr.transition_state

    def faulty(customer_hash, new_state, reason="", operator_or_system_id=""):
        if customer_hash == "00000003":
            raise TimeoutError("simulated OpenBao/K8s timeout")
        return real(customer_hash, new_state, reason, operator_or_system_id)

    mgr.transition_state = faulty
    now = datetime.now(timezone.utc)
    for _ in range(3):
        mgr.evaluate_reaping(now=now)
    states = {h: r.state for h, r in mgr._records.items()}
    assert states["00000003"] == EnvironmentLifecycleState.ACTIVE
    assert sum(s == EnvironmentLifecycleState.DRAINING for s in states.values()) == 9
    assert mgr.dlq.contains("00000003")


@pytest.mark.xfail(strict=True, reason="SLED-P2-GOV D4: code outside the per-record try "
                   "(priority sort key) aborts the whole pass, so one malformed record starves the fleet "
                   "and never reaches the DLQ")
def test_malformed_record_does_not_starve_the_fleet():
    mgr = LifecycleManager()
    _fleet(mgr, n=10, expired_every=1)
    bad = mgr._records["00000004"]
    mgr._records["00000004"] = bad.model_construct(**{**bad.__dict__, "expires_at": None})
    try:
        mgr.evaluate_reaping()
    except Exception:
        pass
    drained = sum(r.state == EnvironmentLifecycleState.DRAINING for r in mgr._records.values())
    assert drained == 9


# ------------------------------------------------ cancellation and leakage


@pytest.mark.anyio
async def test_repeated_start_stop_leaves_no_tasks_and_completes_promptly():
    mgr = LifecycleManager()
    _fleet(mgr, n=100)
    baseline = {t for t in asyncio.all_tasks()}
    worst = 0.0
    for _ in range(50):
        d = ReaperDaemon(lifecycle_manager=mgr, base_interval=0.001, min_interval=0.001, max_interval=0.001)
        assert d.start() is True
        assert d.start() is False  # idempotent
        await asyncio.sleep(0.003)
        t0 = time.perf_counter()
        await d.stop(timeout=2.0)
        worst = max(worst, time.perf_counter() - t0)
        assert d._task.done()
    await asyncio.sleep(0)
    leaked = [t for t in asyncio.all_tasks() - baseline if not t.done()]
    print(f"\nCERT start_stop_cycles=50 leaked_tasks={len(leaked)} worst_stop_ms={worst * 1000:.2f}")
    assert leaked == []
    assert worst < 0.5


@pytest.mark.anyio
async def test_stop_while_manual_pass_in_flight_does_not_deadlock():
    mgr = LifecycleManager()
    _fleet(mgr)
    d = ReaperDaemon(lifecycle_manager=mgr, base_interval=0.001, min_interval=0.001, max_interval=0.001)
    d.start()
    manual = asyncio.create_task(d.run_reconciliation_pass())
    await asyncio.sleep(0)
    await asyncio.wait_for(d.stop(timeout=2.0), timeout=3.0)
    summary = await asyncio.wait_for(manual, timeout=3.0)
    assert summary.status == "completed"
    assert d._active_pass_in_progress is False


@pytest.mark.anyio
async def test_steady_state_passes_do_not_grow_memory():
    # The watchdog WARNs on every pass (D2), and pytest's log capture retains each
    # record; that is harness memory, not daemon memory, so logging is muted here.
    # Standalone (no capture) the traced heap plateaus: +379KB@5k, +1.08MB@20k,
    # +1.17MB@30k passes -- a bounded cache, not a per-pass leak.
    logging.disable(logging.CRITICAL)
    try:
        await _steady_state_growth()
    finally:
        logging.disable(logging.NOTSET)


async def _steady_state_growth():
    mgr = LifecycleManager()
    _fleet(mgr, n=200)
    d = ReaperDaemon(lifecycle_manager=mgr)
    for _ in range(50):  # warm-up: drain, allocator settle
        await d.run_reconciliation_pass()
    gc.collect()
    tracemalloc.start()
    s0 = tracemalloc.take_snapshot()
    for _ in range(3000):
        await d.run_reconciliation_pass()
    gc.collect()
    s1 = tracemalloc.take_snapshot()
    tracemalloc.stop()
    growth = sum(st.size_diff for st in s1.compare_to(s0, "filename"))
    print(f"\nCERT passes=3000 fleet=200 traced_heap_growth_bytes={growth} audit_log={len(mgr._audit_log)}")
    assert growth < 1536 * 1024
    assert len(mgr._audit_log) <= 1000


def test_memory_watchdog_bound_is_below_a_live_process_peak(caplog):
    """D2 corollary: with ru_maxrss above the 50MB bound, every pass logs a WARNING."""
    w = el.MemoryWatchdog()
    with caplog.at_level(logging.WARNING, logger=el.logger.name):
        for _ in range(3):
            w.check_rss()
    alerts = sum("Memory watchdog alert" in r.message for r in caplog.records)
    info = w.check_rss()
    print(f"\nCERT watchdog_rss_mb={info['rss_mb']} bound_mb={info['max_rss_mb']} alerts_per_3_checks={alerts}")
    assert info["healthy"] is False
    assert alerts == 3


def test_threaded_heartbeats_racing_reaper_passes_preserve_invariants():
    mgr = LifecycleManager()
    _fleet(mgr, n=256)
    errors: list[BaseException] = []
    stop = threading.Event()

    def worker(offset: int):
        i = offset
        while not stop.is_set():
            h = f"{i % 256:08x}"
            try:
                rec = mgr.get_lifecycle(h)
                if rec.state == EnvironmentLifecycleState.ACTIVE:
                    mgr.record_activity(h)
            except (ValueError, KeyError):
                pass  # lawful refusal once the reaper has drained the env
            except BaseException as ex:  # pragma: no cover - failure path
                errors.append(ex)
            i += 7

    threads = [threading.Thread(target=worker, args=(k,)) for k in range(32)]
    for t in threads:
        t.start()
    for _ in range(200):
        mgr.evaluate_reaping()
    stop.set()
    for t in threads:
        t.join(5)
    assert errors == []
    assert all(r.state in EnvironmentLifecycleState for r in mgr._records.values())
    # every recorded transition is a legal edge and each env drained at most once
    drains = [e.customer_hash for e in mgr.get_audit_events() if e.current_state == "draining"]
    assert len(drains) == len(set(drains))


# --------------------------------------------------------- defect register


@pytest.mark.anyio
@pytest.mark.xfail(strict=True, reason="SLED-P2-GOV D3: evaluate_reaping runs on the event loop and "
                   "blocks in threading.RLock.acquire(timeout=5) while a threadpool caller holds the lock")
async def test_contended_manager_lock_does_not_stall_the_event_loop():
    mgr = LifecycleManager()
    _fleet(mgr, n=10)
    d = ReaperDaemon(lifecycle_manager=mgr)
    held = threading.Event()

    def hog():
        with mgr._acquire_lock():
            held.set()
            time.sleep(0.4)

    threading.Thread(target=hog).start()
    held.wait(1)
    stop = asyncio.Event()
    lag_task = asyncio.create_task(_max_loop_lag(stop))
    await asyncio.sleep(0.01)
    await d.run_reconciliation_pass()
    stop.set()
    lag = await lag_task
    print(f"\nCERT contended_lock_loop_lag_ms={lag * 1000:.1f}")
    assert lag < 0.05


@pytest.mark.xfail(strict=True, reason="SLED-P2-GOV D1: /metrics returns a JSON dict, not "
                   "OpenMetrics/Prometheus text exposition (no # TYPE, no histogram, no labels)")
def test_metrics_endpoint_is_openmetrics_exposition(monkeypatch):
    mgr = LifecycleManager()
    app = _app(mgr, ReaperDaemon(lifecycle_manager=mgr), monkeypatch)
    r = EAPClient(app, EAP_OPERATOR).get("/api/v1/eap/lifecycle/metrics")
    ctype = r.headers.get("content-type", "")
    assert "openmetrics-text" in ctype or ctype.startswith("text/plain")
    assert "# TYPE signalloom_eap_reaper_duration_seconds histogram" in r.text
    assert r.text.rstrip().endswith("# EOF")


def test_metrics_payload_shape_as_delivered(monkeypatch):
    """Records what P2-1 actually ships so the D1 finding is anchored to evidence."""
    mgr = LifecycleManager()
    app = _app(mgr, ReaperDaemon(lifecycle_manager=mgr), monkeypatch)
    r = EAPClient(app, EAP_OPERATOR).get("/api/v1/eap/lifecycle/metrics")
    print(f"\nCERT metrics content-type={r.headers.get('content-type')} keys={sorted(r.json())}")
    assert r.headers["content-type"].startswith("application/json")
    assert isinstance(r.json()["signalloom_eap_reaper_duration_seconds"], float)


def _vmrss_bytes() -> int:
    with open("/proc/self/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) * 1024
    return 0


@pytest.mark.xfail(strict=True, reason="SLED-P2-GOV D2: MemoryWatchdog reads ru_maxrss (peak, "
                   "monotonic) not current RSS, so it cannot observe a leak receding or bounded memory")
def test_memory_watchdog_reports_current_not_peak_rss():
    w = el.MemoryWatchdog()
    blob = bytearray(300 * 1024 * 1024)
    blob[::4096] = b"x" * len(blob[::4096])
    del blob
    gc.collect()
    current = _vmrss_bytes()
    reported = w.get_rss_bytes()
    print(f"\nCERT vmrss_mb={current / 2**20:.1f} watchdog_mb={reported / 2**20:.1f}")
    assert abs(reported - current) < 64 * 1024 * 1024
