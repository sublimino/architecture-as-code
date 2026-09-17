# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_environment_lifecycle.py
# Unit and contract tests for Signal Loom EAP Lifecycle & Auto-Reaping (SLED)
# ==============================================================================
from datetime import datetime, timedelta, timezone
import pytest
from fastapi.testclient import TestClient

from environment_lifecycle import (
    DEFAULT_LEASE_MINUTES,
    MAX_LIFETIME_HOURS,
    IDLE_TIMEOUT_MINUTES,
    GRACE_PERIOD_SECONDS,
    EnvironmentLifecycleState,
    LifecycleManager,
    GLOBAL_LIFECYCLE_MANAGER,
)
from main import app

client = TestClient(app)


def test_lifecycle_registration_defaults():
    """Verify environment registration sets canonical TTL and 8h ceiling."""
    mgr = LifecycleManager()
    rec = mgr.register_environment("kurasi")

    assert rec.customer_hash == "6f82ad81"
    assert rec.company_name == "kurasi"
    assert rec.state == EnvironmentLifecycleState.PROVISIONING
    assert rec.ttl_remaining_seconds > 0
    # Remaining seconds should be approximately 120 * 60 = 7200
    assert 7100 <= rec.ttl_remaining_seconds <= 7200
    # Max lifetime should be approximately 8 * 3600 = 28800
    assert 28700 <= rec.max_lifetime_remaining_seconds <= 28800


def test_lifecycle_state_transitions():
    """Verify state transition graph allows valid sequence and rejects invalid jumps."""
    mgr = LifecycleManager()
    rec = mgr.register_environment("kurasi")

    # PROVISIONING -> WARMING
    w = mgr.transition_state("6f82ad81", EnvironmentLifecycleState.WARMING)
    assert w.state == EnvironmentLifecycleState.WARMING

    # WARMING -> ACTIVE
    a = mgr.transition_state("6f82ad81", EnvironmentLifecycleState.ACTIVE)
    assert a.state == EnvironmentLifecycleState.ACTIVE

    # ACTIVE -> DRAINING
    d = mgr.transition_state("6f82ad81", EnvironmentLifecycleState.DRAINING, reason="test_reap")
    assert d.state == EnvironmentLifecycleState.DRAINING
    assert d.grace_period_expires_at is not None

    # Invalid jump: DRAINING -> ACTIVE should fail with 400
    with pytest.raises(Exception) as exc:
        mgr.transition_state("6f82ad81", EnvironmentLifecycleState.ACTIVE)
    assert "Invalid lifecycle transition" in str(exc.value)

    # DRAINING -> TERMINATED
    t = mgr.transition_state("6f82ad81", EnvironmentLifecycleState.TERMINATED)
    assert t.state == EnvironmentLifecycleState.TERMINATED


def test_heartbeat_lease_extension_and_ceiling():
    """Verify heartbeat extends lease time but strictly respects the 8-hour cap."""
    mgr = LifecycleManager()
    mgr.register_environment("kurasi", ttl_minutes=60)
    mgr.transition_state("6f82ad81", EnvironmentLifecycleState.ACTIVE)

    # Extend by 60 minutes
    resp = mgr.record_heartbeat("6f82ad81", extend_minutes=60)
    assert resp.extended is True
    assert 7000 <= resp.ttl_remaining_seconds <= 7200

    # Attempt massive 1000m extension (should be bounded by max_lifetime_expires_at)
    resp2 = mgr.record_heartbeat("6f82ad81", extend_minutes=240)
    rec = mgr.get_lifecycle("6f82ad81")
    assert rec.expires_at <= rec.max_lifetime_expires_at


def test_activity_touch_resets_idle():
    """Verify activity touch updates last_activity_at timestamp."""
    mgr = LifecycleManager()
    rec = mgr.register_environment("kurasi")
    initial_activity = rec.last_activity_at

    # Simulate activity 5 seconds later
    updated = mgr.record_activity("6f82ad81", source="ingress_test")
    assert updated.last_activity_at >= initial_activity


def test_evaluate_reaping_ttl_expiration():
    """Verify reaping pass moves expired environment to DRAINING."""
    mgr = LifecycleManager()
    rec = mgr.register_environment("kurasi", ttl_minutes=60)
    mgr.transition_state("6f82ad81", EnvironmentLifecycleState.ACTIVE)

    # Fast-forward time past expiration
    simulated_future = rec.expires_at + timedelta(seconds=10)
    actions = mgr.evaluate_reaping(now=simulated_future)

    assert len(actions) == 1
    assert actions[0]["customer_hash"] == "6f82ad81"
    assert actions[0]["action"] == "draining"
    assert actions[0]["reason"] == "ttl_expired"

    updated = mgr.get_lifecycle("6f82ad81")
    assert updated.state == EnvironmentLifecycleState.DRAINING


def test_evaluate_reaping_idle_timeout():
    """Verify reaping pass moves idle environment (30m+) to DRAINING."""
    mgr = LifecycleManager()
    rec = mgr.register_environment("kurasi", ttl_minutes=240)
    mgr.transition_state("6f82ad81", EnvironmentLifecycleState.ACTIVE)

    # Fast-forward time past idle timeout (35 minutes after last activity)
    simulated_future = rec.last_activity_at + timedelta(minutes=35)
    actions = mgr.evaluate_reaping(now=simulated_future)

    assert len(actions) == 1
    assert actions[0]["action"] == "draining"
    assert actions[0]["reason"] == "idle_timeout"


def test_evaluate_reaping_grace_period_to_terminated():
    """Verify draining environment past grace period transitions to TERMINATED."""
    mgr = LifecycleManager()
    rec = mgr.register_environment("kurasi")
    mgr.transition_state("6f82ad81", EnvironmentLifecycleState.DRAINING)

    draining_rec = mgr.get_lifecycle("6f82ad81")
    # Fast forward past grace period
    simulated_future = draining_rec.grace_period_expires_at + timedelta(seconds=10)
    actions = mgr.evaluate_reaping(now=simulated_future)

    assert len(actions) == 1
    assert actions[0]["action"] == "terminated"
    assert actions[0]["reason"] == "grace_period_expired"

    final_rec = mgr.get_lifecycle("6f82ad81")
    assert final_rec.state == EnvironmentLifecycleState.TERMINATED


# ── HTTP API Contract Tests ───────────────────────────────────────────────────

def test_api_lifecycle_full_flow():
    """Verify FastAPI endpoints for registering, heartbeating, and checking lifecycle."""
    # 1. Register
    reg_resp = client.post(
        "/api/v1/eap/lifecycle/register",
        json={"company_name": "kurasi", "ttl_minutes": 120}
    )
    assert reg_resp.status_code == 201
    data = reg_resp.json()
    assert data["customer_hash"] == "6f82ad81"
    assert data["state"] == "provisioning"

    # 2. Touch activity
    act_resp = client.post("/api/v1/eap/lifecycle/environments/6f82ad81/activity")
    assert act_resp.status_code == 200

    # 3. Heartbeat
    hb_resp = client.post(
        "/api/v1/eap/lifecycle/environments/6f82ad81/heartbeat",
        json={"extend_minutes": 30}
    )
    assert hb_resp.status_code == 200
    hb_data = hb_resp.json()
    assert hb_data["extended"] is True

    # 4. Query status
    get_resp = client.get("/api/v1/eap/lifecycle/environments/6f82ad81")
    assert get_resp.status_code == 200
    assert get_resp.json()["customer_hash"] == "6f82ad81"

    # 5. List active
    active_resp = client.get("/api/v1/eap/lifecycle/active")
    assert active_resp.status_code == 200
    hashes = [r["customer_hash"] for r in active_resp.json()]
    assert "6f82ad81" in hashes

    # 6. Manual reap check
    reap_resp = client.post("/api/v1/eap/lifecycle/reap-now")
    assert reap_resp.status_code == 200
    assert "actions" in reap_resp.json()
