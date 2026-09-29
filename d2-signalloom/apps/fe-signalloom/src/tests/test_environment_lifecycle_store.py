from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from functools import wraps

import pytest

from environment_lifecycle_store import InMemoryLifecycleStore, LifecycleRow
from environment_teardown_contract import ORDERED_STAGES


NOW = datetime(2026, 9, 27, tzinfo=timezone.utc)
HASH = "a0314bec"


def async_test(function):
    @wraps(function)
    def run(*args, **kwargs):
        return asyncio.run(function(*args, **kwargs))
    return run


def draining_row() -> LifecycleRow:
    return LifecycleRow(
        customer_hash=HASH,
        company_name="kusari",
        state="draining",
        created_at=NOW - timedelta(hours=1),
        last_heartbeat_at=NOW - timedelta(minutes=30),
        last_activity_at=NOW - timedelta(minutes=30),
        expires_at=NOW - timedelta(minutes=5),
        max_lifetime_expires_at=NOW + timedelta(hours=7),
        grace_period_expires_at=NOW - timedelta(seconds=1),
        reap_reason="ttl_expired",
    )


@async_test
async def test_two_workers_cannot_claim_same_environment():
    store = InMemoryLifecycleStore()
    await store.create(draining_row(), {})

    claims = await asyncio.gather(
        store.claim_due("worker-a", NOW, timedelta(seconds=30)),
        store.claim_due("worker-b", NOW, timedelta(seconds=30)),
    )

    assert sum(claim is not None for claim in claims) == 1


@async_test
async def test_restart_recovery_reads_durable_record_and_expired_claim():
    store = InMemoryLifecycleStore()
    await store.create(draining_row(), {})
    first = await store.claim_due("worker-a", NOW, timedelta(seconds=5))
    assert first is not None

    restarted_view = await store.get(HASH)
    recovered = await store.claim_due("worker-b", NOW + timedelta(seconds=6), timedelta(seconds=5))

    assert restarted_view.teardown_id == first.teardown_id
    assert recovered is not None
    assert recovered.claim_owner == "worker-b"
    assert recovered.teardown_id == first.teardown_id
    assert recovered.claim_fencing_token == first.claim_fencing_token + 1


@async_test
async def test_stage_completion_is_monotonic_and_idempotent():
    store = InMemoryLifecycleStore()
    await store.create(draining_row(), {})
    claim = await store.claim_due("worker-a", NOW, timedelta(seconds=30))

    with pytest.raises(ValueError, match="ordered checkpoint"):
        await store.checkpoint_stage(
            HASH, "worker-a", claim.teardown_id, claim.claim_fencing_token,
            ORDERED_STAGES[1].value, expected_completed=(), event={},
        )

    first = await store.checkpoint_stage(
        HASH, "worker-a", claim.teardown_id, claim.claim_fencing_token,
        ORDERED_STAGES[0].value, expected_completed=(), event={},
    )
    replay = await store.checkpoint_stage(
        HASH, "worker-a", claim.teardown_id, claim.claim_fencing_token,
        ORDERED_STAGES[0].value, expected_completed=(), event={},
    )

    assert first.teardown_stages_completed == [ORDERED_STAGES[0].value]
    assert replay.teardown_stages_completed == first.teardown_stages_completed


@async_test
async def test_completion_requires_every_checkpoint_and_matching_claim():
    store = InMemoryLifecycleStore()
    await store.create(draining_row(), {})
    claim = await store.claim_due("worker-a", NOW, timedelta(seconds=30))

    with pytest.raises(ValueError, match="all teardown stages"):
        await store.complete_claim(
            HASH, "worker-a", claim.teardown_id, claim.claim_fencing_token,
            tuple(s.value for s in ORDERED_STAGES), {},
        )

    with pytest.raises(ValueError, match="claim owner"):
        await store.fail_claim(
            HASH, "worker-b", claim.teardown_id, claim.claim_fencing_token,
            "unknown effect", NOW, {},
        )


@async_test
async def test_expired_claim_cannot_checkpoint_fail_or_complete():
    clock_time = NOW
    store = InMemoryLifecycleStore(clock=lambda: clock_time)
    await store.create(draining_row(), {})
    claim = await store.claim_due("worker-a", NOW, timedelta(seconds=10))
    assert claim is not None

    # Advance clock past lease
    clock_time = NOW + timedelta(seconds=15)

    with pytest.raises(ValueError, match="expired"):
        await store.checkpoint_stage(
            HASH, "worker-a", claim.teardown_id, claim.claim_fencing_token,
            ORDERED_STAGES[0].value, expected_completed=(), event={},
        )

    with pytest.raises(ValueError, match="expired"):
        await store.fail_claim(
            HASH, "worker-a", claim.teardown_id, claim.claim_fencing_token,
            "error", NOW + timedelta(seconds=30), {},
        )

    with pytest.raises(ValueError, match="expired"):
        await store.complete_claim(
            HASH, "worker-a", claim.teardown_id, claim.claim_fencing_token,
            tuple(s.value for s in ORDERED_STAGES), {},
        )

    # Stale fencing token when not expired
    clock_time = NOW + timedelta(seconds=5)
    with pytest.raises(ValueError, match="fencing"):
        await store.checkpoint_stage(
            HASH, "worker-a", claim.teardown_id, claim.claim_fencing_token + 999,
            ORDERED_STAGES[0].value, expected_completed=(), event={},
        )


@async_test
async def test_takeover_increments_fence_and_writes_audit_event():
    clock_time = NOW
    store = InMemoryLifecycleStore(clock=lambda: clock_time)
    await store.create(draining_row(), {})
    first = await store.claim_due("worker-a", NOW, timedelta(seconds=10))
    assert first is not None
    assert first.claim_fencing_token == 1

    # Lease expires
    clock_time = NOW + timedelta(seconds=15)
    recovered = await store.claim_due("worker-b", clock_time, timedelta(seconds=10))
    assert recovered is not None
    assert recovered.claim_owner == "worker-b"
    assert recovered.teardown_id == first.teardown_id
    assert recovered.claim_fencing_token == 2

    # Check takeover event in outbox
    events = [e for e in store.outbox if e.get("event_type") == "eap.teardown.claim_taken_over"]
    assert len(events) == 1
    takeover_event = events[0]
    assert takeover_event["customer_hash"] == HASH
    assert takeover_event["previous_claim_owner"] == "worker-a"
    assert takeover_event["claim_owner"] == "worker-b"
    assert takeover_event["operator_or_system_id"] == "worker-b"
    assert takeover_event["claim_fencing_token"] == 2
