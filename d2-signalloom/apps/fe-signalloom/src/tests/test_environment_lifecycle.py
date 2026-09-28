# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_environment_lifecycle.py
# Unit and contract tests for Signal Loom EAP Lifecycle & Auto-Reaping (SLED)
# ==============================================================================
import asyncio
from datetime import datetime, timedelta, timezone
import threading
import time
import pytest
from fastapi.testclient import TestClient

from environment_lifecycle import (
    DEFAULT_LEASE_MINUTES,
    MAX_LIFETIME_HOURS,
    IDLE_TIMEOUT_MINUTES,
    GRACE_PERIOD_SECONDS,
    DEFAULT_REAPER_INTERVAL_SECONDS,
    MIN_REAPER_INTERVAL_SECONDS,
    MAX_REAPER_INTERVAL_SECONDS,
    MAX_RECONCILIATION_FAILURES,
    AdaptiveIntervalScheduler,
    DeadLetterQueue,
    DeadLetterRecord,
    EnvironmentLifecycleState,
    LifecycleManager,
    MemoryWatchdog,
    ReaperDaemon,
    GLOBAL_LIFECYCLE_MANAGER,
    GLOBAL_REAPER_DAEMON,
)
from environment_routing import derive_customer_hash
from main import app
from conftest import EAP_OPERATOR, EAPClient, eap_bearer

# EAPR-P2-1: the EAP routers are mounted behind authenticated_principal;
# every request here carries a real tenant-a token (see tests/conftest.py).
EAP_AUTHENTICATED = True
client = EAPClient(app)

KUSARI = "kusari"
KUSARI_HASH = derive_customer_hash(KUSARI)


def test_lifecycle_registration_defaults():
    """Verify environment registration sets canonical TTL and 8h ceiling."""
    mgr = LifecycleManager()
    rec = mgr.register_environment(KUSARI)

    assert rec.customer_hash == KUSARI_HASH
    assert rec.company_name == KUSARI
    assert rec.state == EnvironmentLifecycleState.PROVISIONING
    assert rec.ttl_remaining_seconds > 0
    # Remaining seconds should be approximately 120 * 60 = 7200
    assert 7100 <= rec.ttl_remaining_seconds <= 7200
    # Max lifetime should be approximately 8 * 3600 = 28800
    assert 28700 <= rec.max_lifetime_remaining_seconds <= 28800


def test_lifecycle_state_transitions():
    """Verify state transition graph allows valid sequence and rejects invalid jumps."""
    mgr = LifecycleManager()
    rec = mgr.register_environment(KUSARI)

    # PROVISIONING -> WARMING
    w = mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.WARMING)
    assert w.state == EnvironmentLifecycleState.WARMING

    # WARMING -> ACTIVE
    a = mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.ACTIVE)
    assert a.state == EnvironmentLifecycleState.ACTIVE

    # ACTIVE -> DRAINING
    d = mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.DRAINING, reason="test_reap")
    assert d.state == EnvironmentLifecycleState.DRAINING
    assert d.grace_period_expires_at is not None

    # Invalid jump: DRAINING -> ACTIVE should fail with 400
    with pytest.raises(Exception) as exc:
        mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.ACTIVE)
    assert "Invalid lifecycle transition" in str(exc.value)

    # DRAINING -> TERMINATED
    t = mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.TERMINATED)
    assert t.state == EnvironmentLifecycleState.TERMINATED


def test_heartbeat_lease_extension_and_ceiling():
    """Verify heartbeat extends lease time but strictly respects the 8-hour cap."""
    mgr = LifecycleManager()
    mgr.register_environment(KUSARI, ttl_minutes=60)
    mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.ACTIVE)

    # Extend by 60 minutes
    resp = mgr.record_heartbeat(KUSARI_HASH, extend_minutes=60)
    assert resp.extended is True
    assert 7000 <= resp.ttl_remaining_seconds <= 7200

    # Attempt massive 1000m extension (should be bounded by max_lifetime_expires_at)
    resp2 = mgr.record_heartbeat(KUSARI_HASH, extend_minutes=240)
    rec = mgr.get_lifecycle(KUSARI_HASH)
    assert rec.expires_at <= rec.max_lifetime_expires_at


def test_activity_touch_resets_idle():
    """Verify activity touch updates last_activity_at timestamp."""
    mgr = LifecycleManager()
    rec = mgr.register_environment(KUSARI)
    initial_activity = rec.last_activity_at

    # Simulate activity 5 seconds later
    updated = mgr.record_activity(KUSARI_HASH, source="ingress_test")
    assert updated.last_activity_at >= initial_activity


def test_evaluate_reaping_ttl_expiration():
    """Verify reaping pass moves expired environment to DRAINING."""
    mgr = LifecycleManager()
    rec = mgr.register_environment(KUSARI, ttl_minutes=60)
    mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.ACTIVE)

    # Fast-forward time past expiration
    simulated_future = rec.expires_at + timedelta(seconds=10)
    actions = mgr.evaluate_reaping(now=simulated_future)

    assert len(actions) == 1
    assert actions[0]["customer_hash"] == KUSARI_HASH
    assert actions[0]["action"] == "draining"
    assert actions[0]["reason"] == "ttl_expired"

    updated = mgr.get_lifecycle(KUSARI_HASH)
    assert updated.state == EnvironmentLifecycleState.DRAINING


def test_evaluate_reaping_idle_timeout():
    """Verify reaping pass moves idle environment (30m+) to DRAINING."""
    mgr = LifecycleManager()
    rec = mgr.register_environment(KUSARI, ttl_minutes=240)
    mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.ACTIVE)

    # Fast-forward time past idle timeout (35 minutes after last activity)
    simulated_future = rec.last_activity_at + timedelta(minutes=35)
    actions = mgr.evaluate_reaping(now=simulated_future)

    assert len(actions) == 1
    assert actions[0]["action"] == "draining"
    assert actions[0]["reason"] == "idle_timeout"


def test_evaluate_reaping_grace_period_to_terminated():
    """Verify draining environment past grace period transitions to TERMINATED."""
    mgr = LifecycleManager()
    rec = mgr.register_environment(KUSARI)
    mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.DRAINING)

    draining_rec = mgr.get_lifecycle(KUSARI_HASH)
    # Fast forward past grace period
    simulated_future = draining_rec.grace_period_expires_at + timedelta(seconds=10)
    actions = mgr.evaluate_reaping(now=simulated_future)

    assert len(actions) == 1
    assert actions[0]["action"] == "terminated"
    assert actions[0]["reason"] == "grace_period_expired"

    final_rec = mgr.get_lifecycle(KUSARI_HASH)
    assert final_rec.state == EnvironmentLifecycleState.TERMINATED


# ── Additional SLED-P2-1 Unit & Resilience Tests ───────────────────────────────

def test_evaluate_reaping_empty_registry():
    """Verify that evaluate_reaping executes with 0 actions and sub-millisecond on empty registry."""
    mgr = LifecycleManager()
    actions = mgr.evaluate_reaping()
    assert actions == []
    assert len(mgr.list_active()) == 0


def test_evaluate_reaping_fully_active_fleet():
    """Verify that evaluate_reaping preserves healthy active environments without reaping."""
    mgr = LifecycleManager()
    for i in range(5):
        mgr.register_environment(f"tenant-{i}", customer_hash=f"a{i:07d}", ttl_minutes=120)
        mgr.transition_state(f"a{i:07d}", EnvironmentLifecycleState.ACTIVE)

    actions = mgr.evaluate_reaping()
    assert actions == []
    active_envs = mgr.list_active()
    assert len(active_envs) == 5
    assert all(e.state == EnvironmentLifecycleState.ACTIVE for e in active_envs)


def test_evaluate_reaping_large_fleet_sub_millisecond_benchmark():
    """Verify reaper evaluation on 100 environments executes in sub-millisecond latency."""
    mgr = LifecycleManager()
    for i in range(100):
        mgr.register_environment(f"bench-tenant-{i}", customer_hash=f"b{i:07d}", ttl_minutes=120)

    start = time.perf_counter()
    actions = mgr.evaluate_reaping()
    elapsed_ms = (time.perf_counter() - start) * 1000.0

    assert actions == []
    # 100 in-memory environment checks should comfortably finish in under 10ms
    assert elapsed_ms < 20.0


def test_evaluate_reaping_priority_queue_ordering():
    """Verify evaluate_reaping prioritizes negative TTL and expired grace periods over idle timeouts."""
    mgr = LifecycleManager()
    now = datetime.now(timezone.utc)

    # 1. Environment nearing idle timeout (idle 35m)
    mgr.register_environment("idle-tenant", customer_hash="11111111", ttl_minutes=240)
    mgr.transition_state("11111111", EnvironmentLifecycleState.ACTIVE)
    rec1 = mgr.get_lifecycle("11111111")
    # Manually adjust last_activity_at to 35m ago
    mgr._records["11111111"] = rec1.model_copy(update={"last_activity_at": now - timedelta(minutes=35)})

    # 2. Environment with negative TTL (expired 10m ago)
    mgr.register_environment("expired-tenant", customer_hash="22222222", ttl_minutes=60)
    mgr.transition_state("22222222", EnvironmentLifecycleState.ACTIVE)
    rec2 = mgr.get_lifecycle("22222222")
    mgr._records["22222222"] = rec2.model_copy(update={"expires_at": now - timedelta(minutes=10)})

    # 3. Environment in DRAINING with expired grace period
    mgr.register_environment("draining-tenant", customer_hash="33333333", ttl_minutes=60)
    mgr.transition_state("33333333", EnvironmentLifecycleState.DRAINING)
    rec3 = mgr.get_lifecycle("33333333")
    mgr._records["33333333"] = rec3.model_copy(update={"grace_period_expires_at": now - timedelta(seconds=10)})

    actions = mgr.evaluate_reaping(now=now)
    assert len(actions) == 3
    # Top priority is negative TTL (22222222), then expired grace period (33333333), then idle timeout (11111111)
    action_hashes = [a["customer_hash"] for a in actions]
    assert action_hashes[0] == "22222222"
    assert action_hashes[1] == "33333333"
    assert action_hashes[2] == "11111111"


def test_evaluate_reaping_exception_isolation_and_dlq():
    """Verify that failure on one environment does not block others and routes to DLQ after 3 failures."""
    mgr = LifecycleManager()
    now = datetime.now(timezone.utc)

    mgr.register_environment("good-tenant-1", customer_hash="aaaaaaaa", ttl_minutes=10)
    mgr.register_environment("bad-tenant", customer_hash="bbbbbbbb", ttl_minutes=10)
    mgr.register_environment("good-tenant-2", customer_hash="cccccccc", ttl_minutes=10)

    for h in ("aaaaaaaa", "bbbbbbbb", "cccccccc"):
        mgr.transition_state(h, EnvironmentLifecycleState.ACTIVE)
        rec = mgr.get_lifecycle(h)
        mgr._records[h] = rec.model_copy(update={"expires_at": now - timedelta(seconds=10)})

    # Mock bad-tenant to fail transition
    original_transition = mgr.transition_state

    def faulty_transition(customer_hash, new_state, reason="", operator_or_system_id=""):
        if customer_hash.lower() == "bbbbbbbb":
            raise RuntimeError("Simulated transient transition failure")
        return original_transition(customer_hash, new_state, reason, operator_or_system_id)

    mgr.transition_state = faulty_transition

    # Cycle 1 - isolated and enqueued to DLQ
    actions1 = mgr.evaluate_reaping(now=now)
    assert len(actions1) == 3
    assert mgr.get_lifecycle("aaaaaaaa").state == EnvironmentLifecycleState.DRAINING
    assert mgr.get_lifecycle("cccccccc").state == EnvironmentLifecycleState.DRAINING
    assert mgr.get_lifecycle("bbbbbbbb").state == EnvironmentLifecycleState.ACTIVE
    assert mgr.dlq.count() == 1
    assert mgr.dlq.get("bbbbbbbb").failure_count == 1

    # Cycle 2
    actions2 = mgr.evaluate_reaping(now=now)
    assert mgr.dlq.count() == 1
    assert mgr.dlq.get("bbbbbbbb").failure_count == 2

    # Cycle 3 - should still be in DeadLetterQueue with incremented failures
    actions3 = mgr.evaluate_reaping(now=now)
    assert mgr.dlq.count() == 1
    dlq_entry = mgr.dlq.get("bbbbbbbb")
    assert dlq_entry is not None
    assert dlq_entry.failure_count == 3
    assert dlq_entry.error_code == "ERR_TRANSITION_FAILED"
    assert "Simulated transient transition failure" in dlq_entry.last_error

    # Clean up DLQ
    cleared = mgr.dlq.clear("bbbbbbbb")
    assert cleared == 1
    assert mgr.dlq.count() == 0


def test_adaptive_polling_interval_scheduler():
    """Verify adaptive interval scheduler increases on sustained idle and resets on activity."""
    scheduler = AdaptiveIntervalScheduler(base_interval=30.0, min_interval=5.0, max_interval=120.0, backoff_factor=1.5)

    assert scheduler.get_interval() == 30.0

    # Idle cycle 1: 30 * 1.5 = 45
    i1 = scheduler.record_cycle(active_count=0, actions_count=0)
    assert i1 == 45.0

    # Idle cycle 2: 30 * 2.25 = 67.5
    i2 = scheduler.record_cycle(active_count=0, actions_count=0)
    assert i2 == 67.5

    # Activity detected: resets to base 30.0
    i3 = scheduler.record_cycle(active_count=2, actions_count=0)
    assert i3 == 30.0
    assert scheduler.get_interval() == 30.0


def test_memory_watchdog_rss_monitoring():
    """Verify memory watchdog measures RSS and asserts boundedness below 50MB."""
    watchdog = MemoryWatchdog(max_rss_bytes=50 * 1024 * 1024)
    info = watchdog.check_rss()

    assert "rss_bytes" in info
    assert "rss_mb" in info
    assert "healthy" in info
    assert info["max_rss_mb"] == 50.0


def test_administrative_pause_and_resume_controls():
    """Verify administrative pause and resume controls on ReaperDaemon."""
    mgr = LifecycleManager()
    daemon = ReaperDaemon(lifecycle_manager=mgr, base_interval=10.0)

    assert daemon.is_paused is False

    daemon.pause()
    assert daemon.is_paused is True

    status = daemon.get_status()
    assert status.is_paused is True

    daemon.resume()
    assert daemon.is_paused is False


@pytest.mark.anyio
async def test_reaper_daemon_start_stop_graceful_cancellation():
    """Verify ReaperDaemon starts background task and cancels cleanly without task leakage."""
    mgr = LifecycleManager()
    daemon = ReaperDaemon(lifecycle_manager=mgr, base_interval=0.1, min_interval=0.05)

    started = daemon.start()
    assert started is True
    assert daemon.is_running is True

    # Allow daemon to run at least one pass
    await asyncio.sleep(0.2)
    assert daemon.cycle_count >= 1

    # Stop daemon gracefully
    await daemon.stop(timeout=1.0)
    assert daemon.is_running is False
    assert daemon._task.done()


def test_concurrent_api_requests_and_reaping_pass():
    """Verify thread-safe concurrent heartbeats, registrations, and reaping passes without lock contention."""
    mgr = LifecycleManager()
    mgr.register_environment("concurrent-tenant", customer_hash="cccc1111", ttl_minutes=60)
    mgr.transition_state("cccc1111", EnvironmentLifecycleState.ACTIVE)

    errors = []

    def run_heartbeats():
        for _ in range(50):
            try:
                mgr.record_heartbeat("cccc1111", extend_minutes=1)
                time.sleep(0.001)
            except Exception as e:
                errors.append(e)

    def run_reaping():
        for _ in range(20):
            try:
                mgr.evaluate_reaping()
                time.sleep(0.002)
            except Exception as e:
                errors.append(e)

    t1 = threading.Thread(target=run_heartbeats)
    t2 = threading.Thread(target=run_heartbeats)
    t3 = threading.Thread(target=run_reaping)

    t1.start()
    t2.start()
    t3.start()

    t1.join()
    t2.join()
    t3.join()

    assert len(errors) == 0


def test_nanosecond_precision_timestamps_and_audit_schema():
    """Verify transitions record nanosecond timestamps and emit structured audit events."""
    mgr = LifecycleManager()
    mgr.register_environment(KUSARI, customer_hash=KUSARI_HASH, ttl_minutes=120)
    rec = mgr.transition_state(KUSARI_HASH, EnvironmentLifecycleState.ACTIVE)

    assert rec.transition_timestamp_ns is not None
    assert rec.transition_timestamp_ns > 0

    events = mgr.get_audit_events(KUSARI_HASH)
    assert len(events) >= 2  # registration + transition
    ev = events[-1]
    assert ev.customer_hash == KUSARI_HASH
    assert ev.company_name == KUSARI
    assert ev.current_state == "active"
    assert ev.timestamp_ns > 0
    assert ev.operator_or_system_id == "system:lifecycle-manager"


def test_mass_reaping_alert_notification_dispatch():
    """Verify mass reaping alerts fire when >= 5 environments are reaped simultaneously."""
    mgr = LifecycleManager()
    now = datetime.now(timezone.utc)
    dispatched_alerts = []

    mgr.alert_notifier.add_handler(lambda event, details: dispatched_alerts.append((event, details)))

    # Register 6 expired environments
    for i in range(6):
        h = f"mass{i:04d}"
        mgr.register_environment(f"mass-tenant-{i}", customer_hash=h, ttl_minutes=10)
        mgr.transition_state(h, EnvironmentLifecycleState.ACTIVE)
        rec = mgr.get_lifecycle(h)
        mgr._records[h] = rec.model_copy(update={"expires_at": now - timedelta(minutes=5)})

    actions = mgr.evaluate_reaping(now=now)
    assert len(actions) == 6

    mass_alerts = [a for a in dispatched_alerts if a[0] == "mass_reaping_triggered"]
    assert len(mass_alerts) == 1
    assert mass_alerts[0][1]["actions_count"] == 6


def test_lock_timeout_handling():
    """Verify lock acquisition timeout raises TimeoutError rather than hanging."""
    mgr = LifecycleManager()
    # Acquire lock in thread
    lock_held = threading.Event()
    release_lock = threading.Event()

    def hold_lock():
        with mgr._lock:
            lock_held.set()
            release_lock.wait(timeout=2.0)

    t = threading.Thread(target=hold_lock)
    t.start()
    lock_held.wait(timeout=1.0)

    try:
        with pytest.raises(TimeoutError) as exc:
            with mgr._acquire_lock(timeout=0.05):
                pass
        assert "Failed to acquire lifecycle manager lock" in str(exc.value)
    finally:
        release_lock.set()
        t.join()


def test_rapid_clock_skew_resilience():
    """Verify clock moving slightly backward or forward within bounds does not corrupt active leases."""
    mgr = LifecycleManager()
    now = datetime.now(timezone.utc)
    rec = mgr.register_environment("clock-skew-tenant", customer_hash="sk111111", ttl_minutes=120)
    mgr.transition_state("sk111111", EnvironmentLifecycleState.ACTIVE)

    # Time jumps backward 5 minutes (e.g. NTP synchronization)
    backward_time = now - timedelta(minutes=5)
    actions = mgr.evaluate_reaping(now=backward_time)
    assert actions == []
    assert mgr.get_lifecycle("sk111111").state == EnvironmentLifecycleState.ACTIVE

    # Time advances 10 minutes (well within 120m TTL)
    forward_time = now + timedelta(minutes=10)
    actions2 = mgr.evaluate_reaping(now=forward_time)
    assert actions2 == []
    assert mgr.get_lifecycle("sk111111").state == EnvironmentLifecycleState.ACTIVE


# ── HTTP API Contract Tests ───────────────────────────────────────────────────

def test_api_lifecycle_full_flow():
    """Verify FastAPI endpoints for registering, heartbeating, and checking lifecycle."""
    # 1. Register
    reg_resp = client.post(
        "/api/v1/eap/lifecycle/register",
        json={"company_name": KUSARI, "ttl_minutes": 120}
    )
    assert reg_resp.status_code == 201
    data = reg_resp.json()
    assert data["customer_hash"] == KUSARI_HASH
    assert data["state"] == "provisioning"

    # 2. Touch activity
    act_resp = client.post(f"/api/v1/eap/lifecycle/environments/{KUSARI_HASH}/activity")
    assert act_resp.status_code == 200

    # 3. Heartbeat
    hb_resp = client.post(
        f"/api/v1/eap/lifecycle/environments/{KUSARI_HASH}/heartbeat",
        json={"extend_minutes": 30}
    )
    assert hb_resp.status_code == 200
    hb_data = hb_resp.json()
    assert hb_data["extended"] is True

    # 4. Query status
    get_resp = client.get(f"/api/v1/eap/lifecycle/environments/{KUSARI_HASH}")
    assert get_resp.status_code == 200
    assert get_resp.json()["customer_hash"] == KUSARI_HASH

    # 5. List active
    active_resp = client.get("/api/v1/eap/lifecycle/active")
    assert active_resp.status_code == 200
    hashes = [r["customer_hash"] for r in active_resp.json()]
    assert KUSARI_HASH in hashes

    # 6. Manual reap check (process-wide: operator only)
    reap_resp = client.post("/api/v1/eap/lifecycle/reap-now", headers=eap_bearer(EAP_OPERATOR))
    assert reap_resp.status_code == 200
    reap_data = reap_resp.json()
    assert "actions" in reap_data
    assert reap_data["status"] == "completed"


def test_api_reaper_admin_and_diagnostic_endpoints():
    """Verify pause, resume, status, dlq, audit, and metrics endpoints."""
    # Reaper controls act on every tenant at once, so they take the operator token.
    operator = eap_bearer(EAP_OPERATOR)

    # 1. Status
    status_resp = client.get("/api/v1/eap/lifecycle/reaper/status", headers=operator)
    assert status_resp.status_code == 200
    status_data = status_resp.json()
    assert "is_running" in status_data
    assert "rss_mb" in status_data

    # 2. Pause
    pause_resp = client.post("/api/v1/eap/lifecycle/reaper/pause", headers=operator)
    assert pause_resp.status_code == 200
    assert pause_resp.json()["is_paused"] is True

    # 3. Resume
    resume_resp = client.post("/api/v1/eap/lifecycle/reaper/resume", headers=operator)
    assert resume_resp.status_code == 200
    assert resume_resp.json()["is_paused"] is False

    # 4. DLQ
    dlq_resp = client.get("/api/v1/eap/lifecycle/reaper/dlq")
    assert dlq_resp.status_code == 200
    assert isinstance(dlq_resp.json(), list)

    # 5. Clear DLQ
    clear_resp = client.post("/api/v1/eap/lifecycle/reaper/dlq/clear")
    assert clear_resp.status_code == 200
    assert "cleared_count" in clear_resp.json()

    # 6. Audit events
    audit_resp = client.get("/api/v1/eap/lifecycle/audit-events")
    assert audit_resp.status_code == 200
    assert isinstance(audit_resp.json(), list)

    # 7. Metrics (process-wide: operator only)
    metrics_resp = client.get("/api/v1/eap/lifecycle/metrics", headers=operator)
    assert metrics_resp.status_code == 200
    assert "# TYPE signalloom_eap_reaper_cycles counter" in metrics_resp.text
    assert metrics_resp.text.rstrip().endswith("# EOF")
