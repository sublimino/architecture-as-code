from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import urlsplit, urlunsplit

import asyncpg
import pytest

try:
    import pytest_asyncio
except ImportError:
    pytest_asyncio = None

from db.migrate import apply_migrations
from environment_lifecycle_store import LifecycleRow, PostgresLifecycleStore
from environment_teardown_contract import ORDERED_STAGES


DATABASE_URL = os.environ.get("DATABASE_URL")
pytestmark = pytest.mark.skipif(
    DATABASE_URL is None or pytest_asyncio is None,
    reason="isolated PostgreSQL lifecycle tests require DATABASE_URL and pytest-asyncio",
)
async_test = pytest.mark.asyncio if pytest_asyncio is not None else (lambda function: function)


def _with_database(dsn: str, database: str) -> str:
    parts = urlsplit(dsn)
    return urlunsplit((parts.scheme, parts.netloc, f"/{database}", parts.query, parts.fragment))


if pytest_asyncio is not None:
    @pytest_asyncio.fixture
    async def lifecycle_database():
        name = f"signalloom_lifecycle_{uuid.uuid4().hex[:12]}"
        admin = await asyncpg.connect(DATABASE_URL)
        await admin.execute(f'CREATE DATABASE "{name}"')
        await admin.close()
        dsn = _with_database(DATABASE_URL, name)
        pool = await asyncpg.create_pool(dsn, min_size=1, max_size=4)
        await apply_migrations(pool)
        try:
            yield dsn, pool
        finally:
            await pool.close()
            admin = await asyncpg.connect(DATABASE_URL)
            await admin.execute(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1", name
            )
            await admin.execute(f'DROP DATABASE IF EXISTS "{name}"')
            await admin.close()


def _row(now):
    return LifecycleRow(
        customer_hash="6f82ad81", company_name="kurasi", state="draining",
        created_at=now - timedelta(hours=1), last_heartbeat_at=now,
        last_activity_at=now, expires_at=now - timedelta(minutes=5),
        max_lifetime_expires_at=now + timedelta(hours=7),
        grace_period_expires_at=now - timedelta(seconds=1), reap_reason="ttl_expired",
    )


@async_test
async def test_two_actual_connections_collide_on_one_claim(lifecycle_database):
    dsn, pool = lifecycle_database
    now = datetime.now(timezone.utc)
    await PostgresLifecycleStore(pool).create(_row(now), {})
    conn_a, conn_b = await asyncpg.connect(dsn), await asyncpg.connect(dsn)
    try:
        claims = await __import__("asyncio").gather(
            PostgresLifecycleStore(conn_a).claim_due("worker-a", now, timedelta(seconds=30)),
            PostgresLifecycleStore(conn_b).claim_due("worker-b", now, timedelta(seconds=30)),
        )
    finally:
        await conn_a.close()
        await conn_b.close()
    assert sum(claim is not None for claim in claims) == 1


@async_test
async def test_new_connection_recovers_record_and_expired_claim(lifecycle_database):
    dsn, pool = lifecycle_database
    now = datetime.now(timezone.utc)
    first_store = PostgresLifecycleStore(pool)
    await first_store.create(_row(now), {})
    first = await first_store.claim_due("worker-a", now, timedelta(seconds=1))

    connection = await asyncpg.connect(dsn)
    try:
        restarted = PostgresLifecycleStore(connection)
        recovered = await restarted.claim_due("worker-b", now + timedelta(seconds=2), timedelta(seconds=30))
    finally:
        await connection.close()

    assert recovered.teardown_id == first.teardown_id
    assert recovered.claim_owner == "worker-b"
    assert recovered.claim_fencing_token == first.claim_fencing_token + 1


@async_test
async def test_postgres_rejects_expired_and_stale_fenced_claim_mutations(lifecycle_database):
    dsn, pool = lifecycle_database
    now = datetime.now(timezone.utc)
    store = PostgresLifecycleStore(pool)
    await store.create(_row(now), {})
    claim = await store.claim_due("worker-a", now, timedelta(seconds=2))
    assert claim is not None
    assert claim.claim_fencing_token >= 1

    # Attempt mutation with stale fencing token
    with pytest.raises(ValueError, match="fencing"):
        await store.checkpoint_stage(
            "6f82ad81", "worker-a", claim.teardown_id, claim.claim_fencing_token + 999,
            ORDERED_STAGES[0].value, expected_completed=(), event={},
        )

    # Allow lease to expire and verify mutation rejection
    await __import__("asyncio").sleep(2.1)
    with pytest.raises(ValueError, match="expired"):
        await store.checkpoint_stage(
            "6f82ad81", "worker-a", claim.teardown_id, claim.claim_fencing_token,
            ORDERED_STAGES[0].value, expected_completed=(), event={},
        )



# ---------------------------------------------------------------------------
# SLRC-P2-2: live PostgreSQL collision, restart recovery and transactional
# outbox. Each test runs in its own freshly migrated database (fixture above),
# so outbox counts per customer_hash are counts per teardown_id: a fresh
# database holds exactly one teardown lifetime per record. The outbox payload
# does not carry teardown_id itself; the tests read it from the lifecycle row.
# ---------------------------------------------------------------------------

import asyncio
import json
import statistics
import subprocess
import sys
import threading
import time
from dataclasses import replace as _replace
from pathlib import Path

from environment_lifecycle import LifecycleManager
from environment_teardown_contract import ORDERED_STAGES, StageResult

SRC_DIR = Path(__file__).resolve().parents[1]
STAGE_NAMES = tuple(stage.value for stage in ORDERED_STAGES)
METRICS_OUT = os.environ.get("SLRC_LIFECYCLE_METRICS_OUT")


def _metric(test: str, **payload) -> None:
    """Append one evidence line for the wrapper; a no-op when run bare."""
    if not METRICS_OUT:
        return
    with open(METRICS_OUT, "a", encoding="utf-8") as sink:
        sink.write(json.dumps({"test": test, **payload}, default=str) + "\n")


def _due_row(customer_hash: str, now: datetime) -> LifecycleRow:
    return _replace(_row(now), customer_hash=customer_hash)


def _percentile(samples: list[float], fraction: float) -> float:
    ordered = sorted(samples)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


async def _outbox_counts(pool, customer_hash: str) -> dict[str, int]:
    records = await pool.fetch(
        """SELECT event_type, count(*) AS n FROM public.eap_lifecycle_outbox
           WHERE customer_hash=$1 GROUP BY event_type""",
        customer_hash,
    )
    return {record["event_type"]: record["n"] for record in records}


async def _stage_event_counts(pool, customer_hash: str) -> dict[str, int]:
    records = await pool.fetch(
        """SELECT payload->>'stage' AS stage, count(*) AS n FROM public.eap_lifecycle_outbox
           WHERE customer_hash=$1 AND event_type='eap.teardown.stage_completed'
           GROUP BY payload->>'stage'""",
        customer_hash,
    )
    return {record["stage"]: record["n"] for record in records}


class RecordingExecutor:
    """Thread-safe fixture executor: records calls, never touches infrastructure."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str]] = []
        self._lock = threading.Lock()

    def execute(self, stage, request):
        with self._lock:
            self.calls.append((stage.value, request.teardown_id))
        time.sleep(0.01)  # widen the race window between competing workers
        return StageResult(stage=stage, success=True, detail="fixture")

    def verify(self, stage, request):
        return StageResult(stage=stage, success=True, detail="fixture")


@async_test
async def test_concurrent_claims_admit_one_winner_per_record_across_real_connections(lifecycle_database):
    dsn, pool = lifecycle_database
    workers, rounds = 8, 25
    connections = [await asyncpg.connect(dsn) for _ in range(workers)]
    try:
        pids = [await connection.fetchval("SELECT pg_backend_pid()") for connection in connections]
        assert len(set(pids)) == workers, "every worker must hold its own server backend"
        winners: list[dict] = []
        for round_index in range(rounds):
            now = datetime.now(timezone.utc)
            customer_hash = f"{round_index:08x}"
            await PostgresLifecycleStore(pool).create(_due_row(customer_hash, now), {})
            claims = await asyncio.gather(*(
                PostgresLifecycleStore(connection).claim_due(f"worker-{index}", now, timedelta(seconds=30))
                for index, connection in enumerate(connections)
            ))
            won = [(index, claim) for index, claim in enumerate(claims) if claim is not None]
            assert len(won) == 1, f"round {round_index}: {len(won)} workers claimed one record"
            index, claim = won[0]
            assert claim.customer_hash == customer_hash
            winners.append({"round": round_index, "customer_hash": customer_hash,
                            "worker": f"worker-{index}", "backend_pid": pids[index],
                            "teardown_id": claim.teardown_id})
        durable = await pool.fetch(
            "SELECT customer_hash, claim_owner, teardown_id FROM public.eap_environment_lifecycle ORDER BY customer_hash"
        )
        assert len(durable) == rounds
        assert {(r["customer_hash"], r["claim_owner"], r["teardown_id"]) for r in durable} == {
            (w["customer_hash"], w["worker"], w["teardown_id"]) for w in winners
        }
    finally:
        for connection in connections:
            await connection.close()
    _metric("concurrent_claims_one_winner", workers=workers, rounds=rounds,
            backend_pids=pids, winners=winners,
            distinct_winning_backends=len({w["backend_pid"] for w in winners}))


@async_test
async def test_concurrent_claims_throughput_under_pool_load(lifecycle_database):
    dsn, pool = lifecycle_database
    rows, pool_size, workers = 200, 8, 16
    now = datetime.now(timezone.utc)
    seed_store = PostgresLifecycleStore(pool)
    for index in range(rows):
        await seed_store.create(_due_row(f"{index:08x}", now), {})
    # lock_timeout turns any blocking row-lock wait into LockNotAvailableError,
    # so a pass here proves SKIP LOCKED never queued a claimant behind another.
    load_pool = await asyncpg.create_pool(
        dsn, min_size=pool_size, max_size=pool_size, server_settings={"lock_timeout": "2000"},
    )
    claimed: list[tuple[str, str]] = []
    latencies: list[float] = []
    errors: list[str] = []

    async def worker(worker_id: str) -> None:
        store = PostgresLifecycleStore(load_pool)
        # Bounded: a store that re-grants held claims would otherwise loop
        # forever. Stop once more claims than rows exist; the asserts below fail.
        while len(claimed) <= rows:
            started = time.perf_counter()
            try:
                claim = await store.claim_due(worker_id, now, timedelta(seconds=300))
            except Exception as error:  # recorded and asserted empty below
                errors.append(f"{type(error).__name__}: {error}")
                return
            latencies.append(time.perf_counter() - started)
            if claim is None:
                return
            claimed.append((claim.customer_hash, worker_id))

    try:
        started = time.perf_counter()
        await asyncio.gather(*(worker(f"load-{index}") for index in range(workers)))
        elapsed = time.perf_counter() - started
        backends = await load_pool.fetchval(
            "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()"
        )
        idle, size = load_pool.get_idle_size(), load_pool.get_size()
    finally:
        await load_pool.close()

    hashes = [customer_hash for customer_hash, _ in claimed]
    assert errors == []
    assert len(hashes) == rows
    assert len(set(hashes)) == rows, "a record was claimed more than once"
    assert idle == size == pool_size, "pool connections were not released"
    owners = await pool.fetch("SELECT claim_owner, count(*) AS n FROM public.eap_environment_lifecycle GROUP BY claim_owner")
    assert sum(r["n"] for r in owners) == rows and all(r["claim_owner"] for r in owners)
    per_worker = {r["claim_owner"]: r["n"] for r in owners}
    _metric("concurrent_claims_throughput", rows=rows, pool_size=pool_size, async_workers=workers,
            elapsed_seconds=round(elapsed, 4), claims_per_second=round(rows / elapsed, 1),
            claim_calls=len(latencies),
            latency_ms={"p50": round(_percentile(latencies, 0.5) * 1000, 3),
                        "p95": round(_percentile(latencies, 0.95) * 1000, 3),
                        "p99": round(_percentile(latencies, 0.99) * 1000, 3),
                        "max": round(max(latencies) * 1000, 3),
                        "mean": round(statistics.fmean(latencies) * 1000, 3)},
            lock_timeout_ms=2000, lock_errors=len(errors), duplicate_claims=len(hashes) - len(set(hashes)),
            claims_per_worker=per_worker, other_backends_in_db=backends,
            pool_idle_after=idle, pool_size_after=size)


_CRASHING_CHILD = r"""
import asyncio, json, os, sys
from datetime import datetime
sys.path.insert(0, os.environ["SLRC_SRC_DIR"])
import asyncpg
from environment_lifecycle import LifecycleManager
from environment_lifecycle_store import PostgresLifecycleStore
from environment_teardown_contract import ORDERED_STAGES, StageResult

CRASH_AT = int(os.environ["SLRC_CRASH_AT"])

class CrashingExecutor:
    def execute(self, stage, request):
        if ORDERED_STAGES.index(stage) == CRASH_AT:
            print(json.dumps({"pid": os.getpid(), "crashed_in_stage": stage.value,
                              "teardown_id": request.teardown_id}), flush=True)
            os._exit(137)  # hard process death: no finally, no rollback hooks, no fail_claim
        return StageResult(stage=stage, success=True, detail="fixture")

    def verify(self, stage, request):
        return StageResult(stage=stage, success=True, detail="fixture")

async def main():
    pool = await asyncpg.create_pool(os.environ["SLRC_DSN"], min_size=1, max_size=2)
    manager = LifecycleManager(PostgresLifecycleStore(pool), CrashingExecutor(),
                               worker_id="worker-crashed", stage_timeout_seconds=5)
    await manager.run_reconciliation_pass(now=datetime.fromisoformat(os.environ["SLRC_NOW"]))
    print(json.dumps({"error": "pass returned without crashing"}), flush=True)
    sys.exit(3)

asyncio.run(main())
"""


@pytest.mark.parametrize("crash_at", [0, 2])
@async_test
async def test_restart_recovery_resumes_crashed_process_from_durable_checkpoint(lifecycle_database, crash_at):
    dsn, pool = lifecycle_database
    customer_hash = "6f82ad81"
    now = datetime.now(timezone.utc)
    await PostgresLifecycleStore(pool).create(_due_row(customer_hash, now), {})

    child = await asyncio.to_thread(
        subprocess.run, [sys.executable, "-c", _CRASHING_CHILD],
        env={**os.environ, "SLRC_SRC_DIR": str(SRC_DIR), "SLRC_DSN": dsn,
             "SLRC_CRASH_AT": str(crash_at), "SLRC_NOW": now.isoformat()},
        capture_output=True, text=True, timeout=60,
    )
    assert child.returncode == 137, child.stdout + child.stderr
    crash = json.loads(child.stdout.strip().splitlines()[-1])
    assert crash["crashed_in_stage"] == STAGE_NAMES[crash_at]

    # Durable state left behind by the dead process.
    orphan = await PostgresLifecycleStore(pool).get(customer_hash)
    assert orphan.state == "draining"
    assert orphan.claim_owner == "worker-crashed"
    assert orphan.teardown_id == crash["teardown_id"]
    assert tuple(orphan.teardown_stages_completed) == STAGE_NAMES[:crash_at]
    lease_expiry = orphan.claim_expires_at

    # Restarted process: fresh pool, fresh manager, different worker identity.
    executor = RecordingExecutor()
    restarted_pool = await asyncpg.create_pool(dsn, min_size=1, max_size=2)
    try:
        manager = LifecycleManager(PostgresLifecycleStore(restarted_pool), executor,
                                   worker_id="worker-restarted", stage_timeout_seconds=5)
        before_expiry = await manager.run_reconciliation_pass(now=lease_expiry - timedelta(seconds=1))
        assert before_expiry == [] and executor.calls == [], "live lease was stolen before expiry"
        resumed = await manager.run_reconciliation_pass(now=lease_expiry + timedelta(seconds=1))
    finally:
        await restarted_pool.close()

    assert resumed == [{"customer_hash": customer_hash, "action": "terminated",
                        "reason": "teardown_completed", "current_state": "terminated"}]
    assert executor.calls == [(stage, crash["teardown_id"]) for stage in STAGE_NAMES[crash_at:]]
    final = await PostgresLifecycleStore(pool).get(customer_hash)
    assert final.state == "terminated" and final.claim_owner is None
    assert final.teardown_id == crash["teardown_id"]
    assert tuple(final.teardown_stages_completed) == STAGE_NAMES
    assert await _stage_event_counts(pool, customer_hash) == {stage: 1 for stage in STAGE_NAMES}
    assert (await _outbox_counts(pool, customer_hash)).get("eap.teardown.completed") == 1
    _metric("restart_recovery", crash_at_stage_index=crash_at, child_pid=crash["pid"],
            child_exit_code=child.returncode, crashed_in_stage=crash["crashed_in_stage"],
            teardown_id=crash["teardown_id"], orphan_stages=list(orphan.teardown_stages_completed),
            orphan_claim_owner=orphan.claim_owner, lease_expiry=lease_expiry,
            takeover_before_expiry=before_expiry, resumed_stage_calls=[c[0] for c in executor.calls],
            final_state=final.state, stage_completed_events=await _stage_event_counts(pool, customer_hash),
            outbox_event_counts=await _outbox_counts(pool, customer_hash))


@async_test
async def test_transactional_outbox_emits_one_terminal_event_when_two_managers_race(lifecycle_database):
    dsn, pool = lifecycle_database
    customer_hash = "6f82ad81"
    now = datetime.now(timezone.utc)
    await PostgresLifecycleStore(pool).create(_due_row(customer_hash, now), {})
    executor = RecordingExecutor()
    pools = [await asyncpg.create_pool(dsn, min_size=1, max_size=2) for _ in range(2)]
    try:
        managers = [LifecycleManager(PostgresLifecycleStore(p), executor, worker_id=f"replica-{i}",
                                     stage_timeout_seconds=5) for i, p in enumerate(pools)]
        outcomes = await asyncio.gather(*(m.run_reconciliation_pass(now=now) for m in managers))
    finally:
        for p in pools:
            await p.close()
    final = await PostgresLifecycleStore(pool).get(customer_hash)
    counts = await _outbox_counts(pool, customer_hash)
    terminal = await pool.fetch(
        "SELECT event_id, occurred_at, xmin::text AS xmin FROM public.eap_lifecycle_outbox "
        "WHERE customer_hash=$1 AND event_type='eap.teardown.completed'", customer_hash,
    )
    assert sorted(len(outcome) for outcome in outcomes) == [0, 1]
    assert final.state == "terminated"
    assert len(terminal) == 1 and counts["eap.teardown.completed"] == 1
    assert await _stage_event_counts(pool, customer_hash) == {stage: 1 for stage in STAGE_NAMES}
    assert [stage for stage, _ in executor.calls] == list(STAGE_NAMES)
    assert {teardown_id for _, teardown_id in executor.calls} == {final.teardown_id}
    _metric("outbox_two_managers_race", teardown_id=final.teardown_id, outcomes=outcomes,
            outbox_event_counts=counts, terminal_event=dict(terminal[0]),
            executor_calls=len(executor.calls))


@async_test
async def test_transactional_outbox_emits_one_terminal_event_when_stale_worker_completes_after_takeover(lifecycle_database):
    dsn, pool = lifecycle_database
    customer_hash = "6f82ad81"
    now = datetime.now(timezone.utc)
    store = PostgresLifecycleStore(pool)
    await store.create(_due_row(customer_hash, now), {})
    stale = await store.claim_due("worker-stale", now, timedelta(seconds=1))
    done: tuple[str, ...] = ()
    for stage in STAGE_NAMES:
        await store.checkpoint_stage(customer_hash, "worker-stale", stale.teardown_id, stage, done,
                                     {"customer_hash": customer_hash, "event_type": "eap.teardown.stage_completed",
                                      "stage": stage})
        done = (*done, stage)
    takeover = await store.claim_due("worker-new", now + timedelta(seconds=2), timedelta(seconds=30))
    assert takeover.teardown_id == stale.teardown_id and takeover.claim_owner == "worker-new"

    def terminal_event(worker: str) -> dict:
        return {"event_id": str(uuid.uuid4()), "customer_hash": customer_hash,
                "event_type": "eap.teardown.completed", "worker": worker}

    connections = [await asyncpg.connect(dsn), await asyncpg.connect(dsn)]
    try:
        results = await asyncio.gather(
            PostgresLifecycleStore(connections[0]).complete_claim(
                customer_hash, "worker-stale", stale.teardown_id, STAGE_NAMES, terminal_event("worker-stale")),
            PostgresLifecycleStore(connections[1]).complete_claim(
                customer_hash, "worker-new", takeover.teardown_id, STAGE_NAMES, terminal_event("worker-new")),
            return_exceptions=True,
        )
    finally:
        for connection in connections:
            await connection.close()
    assert isinstance(results[0], ValueError), results[0]
    assert isinstance(results[1], LifecycleRow) and results[1].state == "terminated"
    terminal = await pool.fetch(
        "SELECT payload->>'worker' AS worker FROM public.eap_lifecycle_outbox "
        "WHERE customer_hash=$1 AND event_type='eap.teardown.completed'", customer_hash,
    )
    assert [r["worker"] for r in terminal] == ["worker-new"]
    # A replayed completion by the rightful owner is refused too: the claim is released.
    with pytest.raises(ValueError):
        await store.complete_claim(customer_hash, "worker-new", takeover.teardown_id, STAGE_NAMES,
                                   terminal_event("worker-new-replay"))
    assert (await _outbox_counts(pool, customer_hash))["eap.teardown.completed"] == 1
    _metric("outbox_stale_worker_after_takeover", teardown_id=stale.teardown_id,
            stale_worker_error=str(results[0]), winner="worker-new", replay_refused=True,
            terminal_events=len(terminal))


@async_test
async def test_transactional_outbox_rolls_back_terminal_state_when_outbox_insert_fails(lifecycle_database):
    dsn, pool = lifecycle_database
    customer_hash = "6f82ad81"
    now = datetime.now(timezone.utc)
    store = PostgresLifecycleStore(pool)
    await store.create(_due_row(customer_hash, now), {})
    claim = await store.claim_due("worker-a", now, timedelta(seconds=30))
    done: tuple[str, ...] = ()
    for stage in STAGE_NAMES:
        await store.checkpoint_stage(customer_hash, "worker-a", claim.teardown_id, stage, done,
                                     {"customer_hash": customer_hash, "event_type": "eap.teardown.stage_completed",
                                      "stage": stage})
        done = (*done, stage)
    colliding_id = await pool.fetchval(
        "SELECT event_id::text FROM public.eap_lifecycle_outbox WHERE customer_hash=$1 LIMIT 1", customer_hash
    )
    before = await store.get(customer_hash)
    with pytest.raises(asyncpg.UniqueViolationError):
        await store.complete_claim(customer_hash, "worker-a", claim.teardown_id, STAGE_NAMES,
                                   {"event_id": colliding_id, "customer_hash": customer_hash,
                                    "event_type": "eap.teardown.completed"})
    after = await store.get(customer_hash)
    assert after == before, "terminal state committed without its outbox event"
    assert after.state == "draining" and after.claim_owner == "worker-a"
    assert "eap.teardown.completed" not in await _outbox_counts(pool, customer_hash)

    retried = await store.complete_claim(customer_hash, "worker-a", claim.teardown_id, STAGE_NAMES,
                                         {"customer_hash": customer_hash, "event_type": "eap.teardown.completed"})
    assert retried.state == "terminated"
    assert (await _outbox_counts(pool, customer_hash))["eap.teardown.completed"] == 1
    _metric("outbox_rollback_on_insert_failure", teardown_id=claim.teardown_id,
            injected_fault="duplicate outbox event_id (primary key violation)",
            state_after_fault=after.state, version_before=before.version, version_after=after.version,
            retry_state=retried.state, terminal_events=1)
