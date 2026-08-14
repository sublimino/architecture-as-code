"""The audit connection pool must fail closed, not fail open.

``api_compat._get_pool()`` is the single gate between an audited service and an
unaudited one. Every mutating endpoint reaches it, and until this file existed
every mutating endpoint treated ``None`` as "carry on without the audit row".

Three properties are pinned here, each of which the original implementation got
wrong:

1. **A transient failure must not be permanent.** The old code set its
   ``_pool_init_attempted`` latch *before* the connect attempt, so one DB blip
   at first use converted an audited process into an unaudited one until
   restart. Only a ``logger.warning`` marked the transition.

2. **Cold-start concurrency must not leak ``None``.** The old code held a
   ``threading.Lock`` across ``await asyncpg.create_pool(...)``. A threading
   lock provides no mutual exclusion between coroutines on one event loop: the
   holder awaits, yields, and every other first-caller reads the already-set
   latch and returns ``None``. That is a fail-open race on every cold start
   under load, independent of any failure.

3. **"No DSN" and "DB is down" are different states.** Both produced ``None``,
   so a caller could not tell a deliberate fixture deployment (which has an
   in-memory audit twin, ``_record_memory_audit``) from a broken audited one
   (which has nothing). Fixture mode must keep working; an unreachable database
   on a configured deployment must fail closed with 503.

The state-reset helper below is deliberately scheme-agnostic -- it resets
whichever module globals exist -- so these tests fail against the *original*
implementation for the real reason rather than for an ``AttributeError`` on a
name the fix introduces.
"""
from __future__ import annotations

import ast
import asyncio
import socket
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import asyncpg
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI
from fastapi.testclient import TestClient

import api_compat
from api_compat import install_compatibility_api, settings

API_COMPAT_SOURCE = Path(api_compat.__file__)

# A tenant no other test file writes to -- the in-memory stores are module-level
# and outlive a single test.
TENANT = "tenant-pool-failclosed"
SUBJECT = "pool-failclosed-subject"

DSN = "postgresql://unused:unused@127.0.0.1:1/unused"

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------


class _SentinelPool:
    """Stands in for an ``asyncpg.Pool``. Identity is all these tests compare."""


def _reset_pool_state(monkeypatch: pytest.MonkeyPatch) -> None:
    """Return the module's pool globals to their cold-start values.

    Written against *both* the pre-fix scheme (``_pool_init_attempted``) and the
    post-fix scheme (``_pool_mode`` / ``_pool_retry_after``) so that a failure
    reported by these tests is a behavioural failure, never a missing name.
    """
    monkeypatch.setattr(api_compat, "_pool", None, raising=False)
    if hasattr(api_compat, "_pool_init_attempted"):  # original implementation
        monkeypatch.setattr(api_compat, "_pool_init_attempted", False)
    if hasattr(api_compat, "PoolMode"):  # fail-closed implementation
        monkeypatch.setattr(api_compat, "_pool_mode", api_compat.PoolMode.UNKNOWN)
        monkeypatch.setattr(api_compat, "_pool_retry_after", 0.0)
        # The lock is created lazily per event loop; dropping it is how a test
        # gets a clean one. Never done under the original scheme, where
        # ``_pool_lock`` is an eagerly-built threading.Lock and setting it to
        # None would fail the module with a TypeError -- a failure that says
        # nothing about the defect under test.
        monkeypatch.setattr(api_compat, "_pool_lock", None)
        monkeypatch.setattr(api_compat, "_pool_lock_loop", None)
    # Never sleep in a test. Where the implementation supports a retry backoff,
    # collapse it; where it does not, this is a no-op.
    monkeypatch.setattr(api_compat, "POOL_RETRY_BACKOFF_SECONDS", 0.0, raising=False)


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _bearer() -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": SUBJECT,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    """A client over the *production* mount.

    ``install_compatibility_api`` is what ``main`` calls, so an app built this
    way has exactly the routes and exception handlers that ship. Importing
    ``main.app`` would also drag in unrelated middleware and lifespan wiring
    that has nothing to do with the pool.
    """
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {SUBJECT: TENANT})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())

    def reject_external_network(*_args: Any, **_kwargs: Any) -> None:
        raise AssertionError("external network access is forbidden in these tests")

    monkeypatch.setattr(socket.socket, "connect", reject_external_network)

    api_compat.reset_tenant_state(TENANT)
    try:
        with TestClient(app_under_test(), raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        api_compat.reset_tenant_state(TENANT)


def app_under_test() -> FastAPI:
    app = FastAPI()
    install_compatibility_api(app)
    return app


AGENT_NAME = "pool-failclosed-agent"


def _created_agent_count() -> int:
    """Count only agents this file creates.

    A bare ``len(_AGENTS[TENANT])`` also counts whatever ``_ensure_seeded``
    puts in the store on the first fixture-path request, so a create would look
    like it added two agents.
    """
    with api_compat._STORE_LOCK:
        agents = api_compat._AGENTS.get(TENANT, {})
        return sum(1 for a in agents.values() if a.get("name") == AGENT_NAME)


def _agent_create_body() -> dict[str, str]:
    return {"name": AGENT_NAME, "type": "custom", "owner": "qa@example.test"}


# ---------------------------------------------------------------------------
# Defect 1 -- fail-open latch
# ---------------------------------------------------------------------------


def test_transient_connect_failure_does_not_latch_permanently(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """One DB blip must not disable auditing for the life of the process.

    The original code set ``_pool_init_attempted = True`` before attempting the
    connect and never cleared it, so the second call short-circuited to ``None``
    without trying again.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", DSN)

    sentinel = _SentinelPool()
    attempts: list[int] = []

    async def _flaky_create_pool(*_args: Any, **_kwargs: Any) -> _SentinelPool:
        attempts.append(len(attempts) + 1)
        if len(attempts) == 1:
            raise OSError("connection refused")
        return sentinel

    monkeypatch.setattr(asyncpg, "create_pool", _flaky_create_pool)

    first = asyncio.run(api_compat._get_pool())
    assert first is None, "a failed connect must not hand back a pool"

    second = asyncio.run(api_compat._get_pool())
    assert second is sentinel, (
        "the pool must be retried once the backoff has elapsed; a transient "
        "failure that permanently disables auditing is the defect"
    )
    assert attempts == [1, 2], f"expected exactly two connect attempts, saw {attempts}"


def test_connect_failure_is_rate_limited_by_a_backoff(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Retrying is not the same as hammering.

    Between the failure and the end of the backoff window, ``_get_pool`` must
    answer from the recorded state rather than opening a fresh connection on
    every request.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", DSN)
    monkeypatch.setattr(api_compat, "POOL_RETRY_BACKOFF_SECONDS", 3600.0, raising=False)

    attempts: list[int] = []

    async def _always_fails(*_args: Any, **_kwargs: Any) -> None:
        attempts.append(len(attempts) + 1)
        raise OSError("connection refused")

    monkeypatch.setattr(asyncpg, "create_pool", _always_fails)

    for _ in range(5):
        assert asyncio.run(api_compat._get_pool()) is None
    assert attempts == [1], (
        f"expected one connect attempt inside the backoff window, saw {attempts}"
    )


# ---------------------------------------------------------------------------
# Defect 2 -- threading.Lock held across an await
# ---------------------------------------------------------------------------


def test_concurrent_cold_start_callers_all_receive_the_pool(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The cold-start race: every concurrent first-caller gets the pool.

    ``threading.Lock`` does not exclude coroutines. The holder awaits
    ``create_pool``, yields to the loop, and every other caller reads the latch
    that was already set and returns ``None`` -- while the pool is mid-creation
    and about to be perfectly usable. Those callers then take the fixture path
    and their mutations go unaudited.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", DSN)

    sentinel = _SentinelPool()
    attempts: list[int] = []

    async def _slow_create_pool(*_args: Any, **_kwargs: Any) -> _SentinelPool:
        attempts.append(len(attempts) + 1)
        # Yield repeatedly so every other gathered coroutine gets scheduled
        # while this one is still inside create_pool. Deterministic: a bare
        # `sleep(0)` only guarantees one reschedule.
        for _ in range(10):
            await asyncio.sleep(0)
        return sentinel

    monkeypatch.setattr(asyncpg, "create_pool", _slow_create_pool)

    async def _race() -> list[Any]:
        return await asyncio.gather(*(api_compat._get_pool() for _ in range(8)))

    results = asyncio.run(_race())

    assert attempts == [1], f"create_pool must run exactly once, saw {attempts}"
    leaked = [i for i, r in enumerate(results) if r is not sentinel]
    assert not leaked, (
        f"{len(leaked)} of 8 concurrent cold-start callers received None while "
        f"the pool was being created (positions {leaked}); each of those would "
        f"have silently taken the unaudited fixture path"
    )


def test_get_pool_holds_no_synchronous_lock_across_an_await() -> None:
    """Structural guard on the critical section.

    Asserted on the AST rather than on timing so it cannot go green by luck. A
    synchronous ``with`` wrapping an ``await`` is the exact shape of the defect:
    it blocks the thread it runs on and excludes nothing on the event loop.
    """
    tree = ast.parse(API_COMPAT_SOURCE.read_text())
    get_pool = next(
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "_get_pool"
    )

    for node in ast.walk(get_pool):
        if isinstance(node, ast.With):
            awaits = [c for c in ast.walk(node) if isinstance(c, ast.Await)]
            assert not awaits, (
                f"_get_pool holds a synchronous `with` (line {node.lineno}) across "
                f"{len(awaits)} await(s); use `async with` on an asyncio.Lock"
            )

    assert any(isinstance(node, ast.AsyncWith) for node in ast.walk(get_pool)), (
        "_get_pool must serialise pool creation with `async with <asyncio.Lock>`"
    )


def test_pool_lock_survives_successive_event_loops(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An ``asyncio.Lock`` binds to the loop that first awaits it.

    This suite drives coroutines with ``asyncio.run``, so every test is a fresh
    loop. A module-level lock reused across two loops raises "is bound to a
    different event loop" on the second. Guards the fix against introducing
    that.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", DSN)

    sentinel = _SentinelPool()

    async def _create_pool(*_args: Any, **_kwargs: Any) -> _SentinelPool:
        await asyncio.sleep(0)
        return sentinel

    monkeypatch.setattr(asyncpg, "create_pool", _create_pool)

    first = asyncio.run(api_compat._get_pool())
    assert first is sentinel

    _reset_pool_state(monkeypatch)
    second = asyncio.run(api_compat._get_pool())
    assert second is sentinel


def test_asyncio_is_imported_before_the_code_that_uses_it() -> None:
    """``import asyncio`` belongs in the header, not below its first use.

    The original module caught ``asyncio.TimeoutError`` in ``_get_pool`` and
    then imported ``asyncio`` thirty lines further down, relying on the except
    clause never being evaluated before module import finished.
    """
    tree = ast.parse(API_COMPAT_SOURCE.read_text())
    import_lines = [
        node.lineno
        for node in ast.walk(tree)
        if isinstance(node, ast.Import)
        and any(alias.name == "asyncio" for alias in node.names)
    ]
    assert import_lines, "api_compat never imports asyncio"

    first_def = min(
        node.lineno
        for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
    )
    assert min(import_lines) < first_def, (
        f"asyncio is imported at line {min(import_lines)}, below the first "
        f"definition at line {first_def}; move it to the header imports"
    )


# ---------------------------------------------------------------------------
# Defect 3 -- fixture mode conflated with an unreachable database
# ---------------------------------------------------------------------------


def test_empty_dsn_latches_fixture_mode_permanently(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No DSN is a deliberate, permanent configuration choice.

    Unlike a failed connect, it must latch: there is nothing to retry, and
    re-deriving it on every request would be pure overhead.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", "")

    attempts: list[int] = []

    async def _create_pool(*_args: Any, **_kwargs: Any) -> _SentinelPool:
        attempts.append(len(attempts) + 1)
        return _SentinelPool()

    monkeypatch.setattr(asyncpg, "create_pool", _create_pool)

    for _ in range(3):
        assert asyncio.run(api_compat._get_pool()) is None
    assert attempts == [], "an empty DSN must never attempt a connection"


def test_audited_mutation_fails_closed_when_the_database_is_unreachable(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The core invariant: no unaudited mutation.

    A deployment that configures a DSN has declared that its audit trail lives
    in Postgres. If that database cannot be reached, the mutation must not
    happen at all -- a business write with no audit row is worse than no write.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", DSN)

    async def _always_fails(*_args: Any, **_kwargs: Any) -> None:
        raise OSError("connection refused")

    monkeypatch.setattr(asyncpg, "create_pool", _always_fails)

    before = _created_agent_count()
    response = client.post("/api/agents", json=_agent_create_body(), headers=_bearer())

    assert response.status_code == 503, (
        f"expected 503 with no audit database reachable, got "
        f"{response.status_code}: {response.text[:300]}"
    )
    assert response.json()["error"]["code"] == "database_unavailable"
    assert _created_agent_count() == before, (
        "the agent was created despite the audit database being unreachable"
    )


def test_fixture_mode_mutation_still_succeeds(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Fixture mode is a supported deployment, not a degraded one.

    The demo estate runs with ``database_url`` empty and audits into
    ``_AUDIT_EVENTS`` via ``_record_memory_audit``. Failing those mutations
    closed would take the entire demo down, so the fix must key on "DSN
    configured but unreachable", never on "no pool object".
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", "")

    before = _created_agent_count()
    response = client.post("/api/agents", json=_agent_create_body(), headers=_bearer())

    assert response.status_code == 200, (
        f"fixture-mode create must still work, got {response.status_code}: "
        f"{response.text[:300]}"
    )
    assert _created_agent_count() == before + 1


def test_read_endpoints_still_fall_back_to_fixtures_when_db_is_down(
    client: TestClient, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Fail-closed applies to writes, not to reads.

    A read served from fixtures is a degraded answer; a write recorded with no
    audit row is a compliance defect. Guards against over-applying the fix.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", DSN)

    async def _always_fails(*_args: Any, **_kwargs: Any) -> None:
        raise OSError("connection refused")

    monkeypatch.setattr(asyncpg, "create_pool", _always_fails)

    response = client.get("/api/agents", headers=_bearer())
    assert response.status_code == 200, (
        f"GET /api/agents must degrade to fixtures, got {response.status_code}: "
        f"{response.text[:300]}"
    )


def test_pool_states_are_distinguishable(monkeypatch: pytest.MonkeyPatch) -> None:
    """"No DSN" and "DB is down" must be separately observable.

    Both produced a bare ``None`` before, so no caller could tell a deliberate
    fixture deployment from a broken audited one -- which is precisely why the
    fail-open bug was invisible in production logs.
    """
    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", "")
    asyncio.run(api_compat._get_pool())
    fixture_mode = api_compat._pool_mode

    _reset_pool_state(monkeypatch)
    monkeypatch.setattr(settings, "database_url", DSN)

    async def _always_fails(*_args: Any, **_kwargs: Any) -> None:
        raise OSError("connection refused")

    monkeypatch.setattr(asyncpg, "create_pool", _always_fails)
    asyncio.run(api_compat._get_pool())
    unavailable = api_compat._pool_mode

    assert fixture_mode is api_compat.PoolMode.FIXTURE_MODE
    assert unavailable is api_compat.PoolMode.UNAVAILABLE
    assert fixture_mode is not unavailable
