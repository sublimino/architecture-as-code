"""Concurrent Feature Flags page toggles must never lose a change (W24).

Reported 2026-10-17: clicking many toggles quickly on the Feature Flags admin
page, with several requests in flight, sometimes loses changes.

The flag rows themselves are one row per (tenant, flag) written by a single
``INSERT ... ON CONFLICT DO UPDATE`` (migration 057), so two toggles of
different flags never overwrite each other's row. What was not atomic is the
unit of work around that row: the derived account-type record
(``tenant_account_types``, migration 074) was recomputed by
``AccountTypeRepository.refresh`` as read-record, read-flags, write-record in
three autocommit statements, so a toggle whose read ran before a concurrent
change and whose write landed after it persisted a stale ``customised`` marker,
or wrote back a stale ``account_type`` over a preset another request had just
applied. The in-memory route-gating cache (``_flag_cache``) had the same shape:
a read that started before a toggle could fill the cache after the toggle's
invalidation, serving the old value for the whole TTL.

Two fakes drive the same assertions:

* ``FakePool`` -- the existing in-memory ``MockDatabase`` path. Its statements
  never suspend, so units of work cannot interleave mid-flight; it is the
  baseline that the invariants hold with no concurrency at all.
* ``LatencyPool`` -- the same table model with per-statement latency, so
  requests genuinely interleave between statements the way they do over a
  real asyncpg pool. It also models the one piece of SQL locking semantics the
  fix relies on: the per-tenant ``tenant_feature_flag_versions`` upsert takes
  that row's lock and holds it until the transaction ends, exactly as
  ``INSERT ... ON CONFLICT DO UPDATE`` does in PostgreSQL. It does not model
  MVCC visibility; with the lock held, no other writer for the tenant is in
  flight, so there is nothing for visibility to change.

Each concurrency test runs one adversarial latency schedule that forces the
losing interleaving deterministically, plus seeded random schedules.
"""
from __future__ import annotations

import asyncio
import contextvars
import json
import random
from collections.abc import Callable
from typing import Any

import httpx
import pytest
from conftest import EAP_OPERATOR, eap_bearer
from feature_flags import (
    DEFAULT_SYSTEM_FLAGS,
    FEATURE_PRESETS,
    AccountTypeRepository,
    FeatureFlagRepository,
    describe_account_type,
    invalidate_flag_cache,
    is_feature_enabled,
)
from main import app as main_app
from test_feature_flags import FakeConnection, FakePool, MockDatabase

EAP_AUTHENTICATED = True

TENANT = "tenant-w24"

#: Which request (by flag key, or a role name) the current task is serving.
#: The latency schedule reads it to delay one request's statements and not
#: another's -- per-connection latency, the thing that reorders real traffic.
CURRENT_REQUEST: contextvars.ContextVar[str | None] = contextvars.ContextVar("w24_request", default=None)

Schedule = Callable[[str, tuple[Any, ...], str | None], tuple[float, float]]


class LatencyConnection(FakeConnection):
    """FakeConnection whose statements take time, so concurrent units of work
    interleave between statements. ``schedule`` returns (pre, post) delays:
    ``pre`` before the statement executes, ``post`` after it executed but
    before its result reaches the caller (a slow reply)."""

    def __init__(self, db: MockDatabase, pool: LatencyPool) -> None:
        super().__init__(db)
        self.pool = pool
        self.held: list[asyncio.Lock] = []
        self.in_transaction = False

    async def _stmt(self, method: Callable[..., Any], query: str, args: tuple[Any, ...]) -> Any:
        pre, post = self.pool.schedule(query, args, CURRENT_REQUEST.get())
        await asyncio.sleep(pre)
        if "INSERT INTO public.tenant_feature_flag_versions" in query:
            # The upsert locks the tenant's version row until commit/rollback.
            lock = self.pool.tenant_lock(args[0])
            await lock.acquire()
            self.held.append(lock)
        try:
            result = await method(query, *args)
        finally:
            if not self.in_transaction:
                self._release()
        await asyncio.sleep(post)
        return result

    def _release(self) -> None:
        while self.held:
            self.held.pop().release()

    def transaction(self, **_kwargs: Any) -> _LatencyTransaction:
        return _LatencyTransaction(self)

    async def fetch(self, query: str, *args: Any) -> Any:
        return await self._stmt(super().fetch, query, args)

    async def fetchrow(self, query: str, *args: Any) -> Any:
        return await self._stmt(super().fetchrow, query, args)

    async def fetchval(self, query: str, *args: Any) -> Any:
        return await self._stmt(super().fetchval, query, args)

    async def execute(self, query: str, *args: Any) -> Any:
        return await self._stmt(super().execute, query, args)


class _LatencyTransaction:
    def __init__(self, conn: LatencyConnection) -> None:
        self.conn = conn

    async def __aenter__(self) -> _LatencyTransaction:
        self.conn.in_transaction = True
        return self

    async def __aexit__(self, exc_type: object, exc_val: object, exc_tb: object) -> None:
        self.conn.in_transaction = False
        self.conn._release()


class _LatencyPoolContext:
    def __init__(self, conn: LatencyConnection) -> None:
        self.conn = conn

    async def __aenter__(self) -> LatencyConnection:
        return self.conn

    async def __aexit__(self, exc_type: object, exc_val: object, exc_tb: object) -> None:
        self.conn._release()


class LatencyPool(FakePool):
    def __init__(self, db: MockDatabase, schedule: Schedule) -> None:
        super().__init__(db)
        self.schedule = schedule
        self._locks: dict[str, asyncio.Lock] = {}

    def tenant_lock(self, tenant_id: str) -> asyncio.Lock:
        return self._locks.setdefault(tenant_id, asyncio.Lock())

    def acquire(self) -> _LatencyPoolContext:  # type: ignore[override]
        return _LatencyPoolContext(LatencyConnection(self.db, self))


def _jitter(seed: int) -> Schedule:
    rng = random.Random(seed)

    def schedule(_q: str, _a: tuple[Any, ...], _who: str | None) -> tuple[float, float]:
        return rng.uniform(0, 0.003), rng.uniform(0, 0.003)

    return schedule


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def _reset_flag_cache():
    invalidate_flag_cache()
    yield
    invalidate_flag_cache()


def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=main_app),
        base_url="http://testserver",
        headers=eap_bearer(EAP_OPERATOR),
    )


async def _seed(db: MockDatabase, preset: str, overrides: dict[str, bool]) -> None:
    """Sequential setup on the in-memory path: apply ``preset``, then hand-set
    ``overrides`` and re-derive the account type, as the page would have."""
    seed_pool = FakePool(db)
    await FeatureFlagRepository.apply_preset(seed_pool, TENANT, preset, updated_by="seed")
    for key, value in overrides.items():
        await FeatureFlagRepository.set_feature_flag(seed_pool, TENANT, key, value)
    await AccountTypeRepository.refresh(seed_pool, TENANT, "seed")


async def _toggle(client: httpx.AsyncClient, flag: str, enabled: bool) -> httpx.Response:
    CURRENT_REQUEST.set(flag)
    return await client.put(
        f"/api/v1/admin/features/{flag}", params={"tenant_id": TENANT}, json={"enabled": enabled}
    )


def _persisted(db: MockDatabase) -> dict[str, bool]:
    flags = dict(DEFAULT_SYSTEM_FLAGS)
    flags.update({k: bool(r["enabled"]) for (t, k), r in db.rows.items() if t == TENANT})
    return flags


# The flags the main test toggles: page_topology is restored to its eap_view
# value (it starts hand-customised), and twenty others are flipped away from it.
RESTORED = "page_topology"
FLIPPED = sorted(k for k in DEFAULT_SYSTEM_FLAGS if k != RESTORED)[:20]
EAP_VIEW = FEATURE_PRESETS["eap_view"]["flags"]


def _adversarial_toggle_schedule(q: str, _a: tuple[Any, ...], who: str | None) -> tuple[float, float]:
    """Force the lost-update interleaving for the restore of page_topology:
    every flipped flag's row write is slow, so the restore's account-type
    derivation reads a flag set none of them has reached yet, and the restore's
    account-type write is slower still, so it lands after every flip has
    finished re-deriving. Without one unit of work per toggle the stale
    ``customised = false`` is the last write and wins."""
    if who in FLIPPED and "INSERT INTO public.tenant_feature_flags" in q:
        return 0.05, 0.0
    if who == RESTORED and "INSERT INTO public.tenant_account_types" in q:
        return 0.2, 0.0
    return 0.0, 0.0


TOGGLE_PATHS: list[tuple[str, Schedule | None]] = [
    ("in-memory", None),
    ("db-adversarial", _adversarial_toggle_schedule),
    *[(f"db-jitter-{seed}", _jitter(seed)) for seed in range(5)],
]


# ===========================================================================
# 1. Twenty-one concurrent toggles of different flags on one tenant
# ===========================================================================

@pytest.mark.asyncio
@pytest.mark.parametrize(("path", "schedule"), TOGGLE_PATHS, ids=[p for p, _ in TOGGLE_PATHS])
async def test_concurrent_toggles_persist_every_change_and_derive_account_type_from_committed_state(
    path: str, schedule: Schedule | None
) -> None:
    db = MockDatabase()
    await _seed(db, "eap_view", {RESTORED: not EAP_VIEW[RESTORED]})
    assert db.account_types[TENANT]["customised"] is True  # precondition

    intended = {RESTORED: EAP_VIEW[RESTORED], **{k: not EAP_VIEW[k] for k in FLIPPED}}
    assert len(intended) >= 20
    expected = {**_persisted(db), **intended}

    main_app.state.pool = FakePool(db) if schedule is None else LatencyPool(db, schedule)
    async with _client() as client:
        responses = await asyncio.gather(*(_toggle(client, k, v) for k, v in intended.items()))
        assert [r.status_code for r in responses] == [200] * len(intended), [r.text for r in responses]
        final = (await client.get("/api/v1/admin/features", params={"tenant_id": TENANT})).json()

    # Every toggle persisted, and the final state is the union of the changes.
    assert _persisted(db) == expected
    assert final["flags"] == expected

    # The derived account type matches the committed flags, in the row and the API.
    truth = describe_account_type("eap_view", expected)
    assert truth.customised is True
    assert db.account_types[TENANT]["account_type"] == "eap_view"
    assert db.account_types[TENANT]["customised"] is truth.customised, path
    assert final["account_type"]["customised"] is truth.customised, path
    assert final["account_type"]["label"] == truth.label

    # Exactly one audit event per toggle, none lost, each naming its own change.
    events = [a for a in db.audit if a[0] == TENANT and a[1] == "feature_flags.updated"]
    assert len(events) == len(intended)
    audited = {d["flag_key"]: d["enabled"] for d in (json.loads(a[5]) for a in events)}
    assert audited == intended


# ===========================================================================
# 2. Toggles racing an account-type (preset) apply
# ===========================================================================

#: The flags eap_view leaves off; each toggle turns one on, so whatever order
#: the toggles and a concurrent "full" apply commit in, every flag ends on and
#: the tenant is exactly "full", not customised.
ENABLE = sorted(k for k, v in EAP_VIEW.items() if not v)


def _adversarial_preset_schedule(q: str, _a: tuple[Any, ...], who: str | None) -> tuple[float, float]:
    """The toggles' account-type writes are slow, so each lands after the
    concurrent preset apply recorded "full" -- writing back the "eap_view" the
    toggle read before the apply started."""
    if who in ENABLE and "INSERT INTO public.tenant_account_types" in q:
        return 0.2, 0.0
    return 0.0, 0.0


PRESET_PATHS: list[tuple[str, Schedule | None]] = [
    ("in-memory", None),
    ("db-adversarial", _adversarial_preset_schedule),
    *[(f"db-jitter-{seed}", _jitter(100 + seed)) for seed in range(5)],
]


@pytest.mark.asyncio
@pytest.mark.parametrize(("path", "schedule"), PRESET_PATHS, ids=[p for p, _ in PRESET_PATHS])
async def test_toggles_racing_a_preset_apply_never_write_back_a_stale_account_type(
    path: str, schedule: Schedule | None
) -> None:
    db = MockDatabase()
    await _seed(db, "eap_view", {})

    main_app.state.pool = FakePool(db) if schedule is None else LatencyPool(db, schedule)

    async def apply_full(client: httpx.AsyncClient) -> httpx.Response:
        CURRENT_REQUEST.set("preset")
        return await client.put("/api/v1/admin/features", json={"tenant_id": TENANT, "preset": "full"})

    async with _client() as client:
        responses = await asyncio.gather(apply_full(client), *(_toggle(client, k, True) for k in ENABLE))
        assert all(r.status_code == 200 for r in responses), [r.text for r in responses]
        final = (await client.get("/api/v1/admin/features", params={"tenant_id": TENANT})).json()

    assert _persisted(db) == FEATURE_PRESETS["full"]["flags"]
    assert db.account_types[TENANT]["account_type"] == "full", path
    assert db.account_types[TENANT]["customised"] is False, path
    assert final["account_type"]["id"] == "full"
    assert final["account_type"]["customised"] is False


# ===========================================================================
# 3. The in-memory route-gating cache never keeps a value older than a toggle
# ===========================================================================

def _slow_reader_schedule(q: str, _a: tuple[Any, ...], who: str | None) -> tuple[float, float]:
    """The gating read sees the pre-toggle row, and its reply is slow: it
    arrives after the toggle has committed and invalidated the cache."""
    if who == "reader" and "SELECT tenant_id, flag_key, enabled, config_json" in q:
        return 0.0, 0.1
    if who == "page_signals":
        return 0.01, 0.0
    return 0.0, 0.0


@pytest.mark.asyncio
async def test_a_gating_read_racing_a_toggle_does_not_cache_the_old_value() -> None:
    db = MockDatabase()
    await _seed(db, "eap_view", {})
    assert EAP_VIEW["page_signals"] is False
    pool = LatencyPool(db, _slow_reader_schedule)
    main_app.state.pool = pool

    async def reader() -> bool:
        CURRENT_REQUEST.set("reader")
        return await is_feature_enabled(pool, TENANT, "page_signals")

    async with _client() as client:
        raced, resp = await asyncio.gather(reader(), _toggle(client, "page_signals", True))
    assert resp.status_code == 200
    assert raced is False  # the read began before the toggle: old value is fine
    # ...but it must not outlive the toggle in the cache.
    assert await is_feature_enabled(pool, TENANT, "page_signals") is True


# ===========================================================================
# 4. Every mutation reply is stamped with the version it committed
# ===========================================================================

@pytest.mark.asyncio
@pytest.mark.parametrize(("path", "schedule"), TOGGLE_PATHS[:3], ids=[p for p, _ in TOGGLE_PATHS[:3]])
async def test_each_toggle_reply_is_the_state_its_own_version_committed(
    path: str, schedule: Schedule | None
) -> None:
    """The page drops replies older than the one it shows; that needs each
    reply to carry a version that orders it, and to be the state at it."""
    db = MockDatabase()
    await _seed(db, "eap_view", {RESTORED: not EAP_VIEW[RESTORED]})
    intended = {RESTORED: EAP_VIEW[RESTORED], **{k: not EAP_VIEW[k] for k in FLIPPED}}

    main_app.state.pool = FakePool(db) if schedule is None else LatencyPool(db, schedule)
    async with _client() as client:
        before = (await client.get("/api/v1/admin/features", params={"tenant_id": TENANT})).json()["version"]
        responses = await asyncio.gather(*(_toggle(client, k, v) for k, v in intended.items()))
        final = (await client.get("/api/v1/admin/features", params={"tenant_id": TENANT})).json()

    bodies = [r.json() for r in responses]
    versions = sorted(b["version"] for b in bodies)
    assert versions == list(range(before + 1, before + 1 + len(intended))), path
    assert final["version"] == before + len(intended)
    for (key, value), body in zip(intended.items(), bodies, strict=True):
        assert body["flags"][key] is value, (path, key)
    # A reply at version v holds exactly one more of the changes than v - 1.
    by_version = {b["version"]: b for b in bodies}
    seen: set[str] = set()
    for v in versions:
        applied = {k for k in intended if by_version[v]["flags"][k] == intended[k]}
        assert seen < applied and len(applied - seen) == 1, (path, v)
        seen = applied
