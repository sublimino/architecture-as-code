"""remote_agent_sync: the poll/diff/stream engine and the tenant event bus.

Provider HTTP is respx-stubbed; the database is ``FakeRemoteAgentPool``; time
is an injected clock. Nothing here sleeps longer than a few milliseconds.
"""
from __future__ import annotations

import asyncio
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import httpx
import pytest
import respx

import connector_secret_store
from tests.connector_secret_store_fake import FakeKvStore
import remote_agent_sync as ras
from tests.remote_agent_store_fake import FakeRemoteAgentPool

A = "https://api.anthropic.com"
O = "https://api.openai.com"
T0 = datetime(2026, 10, 16, 12, 0, 0, tzinfo=timezone.utc)


class Clock:
    def __init__(self) -> None:
        self.t = T0

    def __call__(self) -> datetime:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += timedelta(seconds=seconds)


@pytest.fixture
def key_env():
    """The credential store: OpenBao KV v2 (SA-TODO-003), here its in-memory fake."""
    kv = FakeKvStore()
    connector_secret_store.set_store_for_testing(kv)
    yield kv
    connector_secret_store.set_store_for_testing(None)


def _pool_with(*connectors: tuple[str, str, str, dict[str, str]]) -> FakeRemoteAgentPool:
    pool = FakeRemoteAgentPool()
    for tenant, cid, provider, creds in connectors:
        ref, version = connector_secret_store.get_store().put(tenant, cid, creds)
        pool.seed_connector(tenant, cid, provider, ref, version)
    return pool


def _engine(pool: Any, clock: Clock, bus: ras.RemoteAgentEventBus | None = None, **kw: Any) -> ras.RemoteAgentSync:
    async def getter():
        return pool

    async def no_sleep(_s: float) -> None:
        await asyncio.sleep(0)

    return ras.RemoteAgentSync(getter, bus=bus or ras.RemoteAgentEventBus(), interval=30, now=clock,
                               rng=lambda: 1.0, sleep=no_sleep, stream_reconnect_base=0.001, **kw)


def _agent(i: str, name: str, **extra: Any) -> dict[str, Any]:
    return {"id": i, "type": "agent", "name": name, "model": {"id": "claude-opus-4-7"}, "version": 1,
            "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-02T00:00:00Z", "archived_at": None,
            "system": "SECRET SYSTEM PROMPT", "mcp_servers": [{"url": "https://x?token=SECRET"}], **extra}


def _session(i: str, status: str, **extra: Any) -> dict[str, Any]:
    return {"id": i, "type": "session", "title": f"t-{i}", "status": status, "environment_id": "env_1",
            "agent": {"id": "agent_a", "name": "A", "version": 3, "model": {"id": "claude-sonnet-4-6"}},
            "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-03T00:00:00Z", **extra}


def _mock_anthropic(mock: respx.MockRouter, agents_pages: list[list[dict]], sessions: list[dict]) -> respx.Route:
    responses = []
    for n, page in enumerate(agents_pages):
        nxt = f"page{n + 2}" if n + 1 < len(agents_pages) else None
        responses.append(httpx.Response(200, json={"data": page, "next_page": nxt}))
    route = mock.get(f"{A}/v1/agents")
    route.side_effect = responses
    mock.get(f"{A}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": sessions, "next_page": None}))
    return route


def _run(coro):
    return asyncio.run(coro)


# ---------------------------------------------------------------------------
# Listing, pagination, diff
# ---------------------------------------------------------------------------

def test_a_poll_reads_every_page_and_stores_exactly_what_was_listed(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    with respx.mock(assert_all_called=False) as mock:
        route = _mock_anthropic(mock, [[_agent("agent_1", "One")], [_agent("agent_2", "Two")]], [_session("sess_1", "idle")])
        outcome = _run(_engine(pool, clock).sync_connector(pool, "tenant-a", "conn-claude-01"))
    assert route.call_count == 2
    assert route.calls[1].request.url.params["page"] == "page2"
    assert route.calls[0].request.headers["anthropic-beta"] == "managed-agents-2026-04-01"
    assert outcome.counts == {"agent": 2, "session": 1} and outcome.complete
    assert {r["external_id"] for r in pool.agents("tenant-a")} == {"agent_1", "agent_2", "sess_1"}
    sess = pool.agent("tenant-a", "sess_1")
    assert (sess["kind"], sess["status"], sess["model"], sess["version"], sess["name"]) == (
        "session", "idle", "claude-sonnet-4-6", "3", "t-sess_1")
    one = pool.agent("tenant-a", "agent_1")
    assert (one["status"], one["model"], one["version"]) == (None, "claude-opus-4-7", "1")


def test_raw_never_carries_prompts_tools_or_mcp_urls(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    with respx.mock(assert_all_called=False) as mock:
        _mock_anthropic(mock, [[_agent("agent_1", "One")]], [])
        _run(_engine(pool, clock).sync_connector(pool, "tenant-a", "conn-claude-01"))
    raw = str(pool.agent("tenant-a", "agent_1")["raw"])
    assert "SECRET" not in raw and "sk-a" not in raw


def test_an_archived_agent_reports_archived(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    with respx.mock(assert_all_called=False) as mock:
        _mock_anthropic(mock, [[_agent("agent_1", "One", archived_at="2026-10-05T00:00:00Z")]], [])
        _run(_engine(pool, clock).sync_connector(pool, "tenant-a", "conn-claude-01"))
    assert pool.agent("tenant-a", "agent_1")["status"] == "archived"


def test_an_item_missing_from_a_complete_listing_is_marked_gone_never_deleted(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    bus = ras.RemoteAgentEventBus()
    engine = _engine(pool, clock, bus)
    with respx.mock(assert_all_called=False) as mock:
        _mock_anthropic(mock, [[_agent("agent_1", "One"), _agent("agent_2", "Two")]], [])
        _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
    clock.advance(30)
    with respx.mock(assert_all_called=False) as mock:
        _mock_anthropic(mock, [[_agent("agent_1", "One")]], [])
        outcome = _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
    gone = pool.agent("tenant-a", "agent_2")
    assert gone is not None, "a vanished item must stay, marked gone"
    assert gone["gone_at"] == clock.t and outcome.gone == 1
    assert pool.agent("tenant-a", "agent_1")["gone_at"] is None
    events = [e for e in bus._rings["tenant-a"] if e.event == "remote_agent.gone"]
    assert [e.data["external_id"] for e in events] == ["agent_2"]
    assert events[0].data == {"provider_id": "claude", "connector_id": "conn-claude-01", "external_id": "agent_2",
                              "gone_at": ras.iso(clock.t)}

    clock.advance(30)
    with respx.mock(assert_all_called=False) as mock:
        _mock_anthropic(mock, [[_agent("agent_1", "One"), _agent("agent_2", "Two")]], [])
        _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
    back = pool.agent("tenant-a", "agent_2")
    assert back["gone_at"] is None and back["last_changed_at"] == clock.t


def test_a_failed_listing_of_one_kind_marks_none_of_that_kind_gone(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    engine = _engine(pool, clock)
    with respx.mock(assert_all_called=False) as mock:
        _mock_anthropic(mock, [[_agent("agent_1", "One")]], [_session("sess_1", "idle")])
        _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
    clock.advance(30)
    with respx.mock(assert_all_called=False) as mock:
        mock.get(f"{A}/v1/agents").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        mock.get(f"{A}/v1/sessions").mock(return_value=httpx.Response(500))
        outcome = _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
    assert pool.agent("tenant-a", "sess_1")["gone_at"] is None
    assert pool.agent("tenant-a", "agent_1")["gone_at"] == clock.t
    assert not outcome.complete and "HTTP 500" in outcome.error


def test_an_unchanged_item_is_touched_not_republished(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    bus = ras.RemoteAgentEventBus()
    engine = _engine(pool, clock, bus)
    for _ in range(2):
        with respx.mock(assert_all_called=False) as mock:
            _mock_anthropic(mock, [[_agent("agent_1", "One")]], [])
            outcome = _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
        clock.advance(30)
    assert (outcome.upserted, outcome.unchanged) == (0, 1)
    row = pool.agent("tenant-a", "agent_1")
    assert row["last_seen_at"] == T0 + timedelta(seconds=30) and row["last_changed_at"] == T0
    assert [e.event for e in bus._rings["tenant-a"]].count("remote_agent.upserted") == 1


def test_a_status_change_is_upserted_with_a_new_last_changed_at(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    engine = _engine(pool, clock)
    with respx.mock(assert_all_called=False) as mock:
        _mock_anthropic(mock, [[]], [_session("sess_1", "idle")])
        _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
    clock.advance(30)
    with respx.mock(assert_all_called=False) as mock:
        _mock_anthropic(mock, [[]], [_session("sess_1", "terminated")])
        _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
    row = pool.agent("tenant-a", "sess_1")
    assert (row["status"], row["last_changed_at"], row["first_seen_at"]) == ("terminated", clock.t, T0)


# ---------------------------------------------------------------------------
# Scheduling, backoff, locks
# ---------------------------------------------------------------------------

def test_a_429_backs_off_past_retry_after_and_is_not_retried_early(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    engine = _engine(pool, clock)
    with respx.mock(assert_all_called=False) as mock:
        agents = mock.get(f"{A}/v1/agents").mock(return_value=httpx.Response(429, headers={"retry-after": "120"}))
        mock.get(f"{A}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        _run(engine.tick(pool))
        state = pool.sync_state[("tenant-a", "conn-claude-01")]
        assert state["mode"] == "backoff" and state["consecutive_failures"] == 1
        assert state["next_poll_at"] >= T0 + timedelta(seconds=120)
        assert "HTTP 429" in state["last_error"]
        clock.advance(60)  # past the 30 s interval, inside retry-after
        _run(engine.tick(pool))
        assert agents.call_count == 1
        clock.advance(61)
        _run(engine.tick(pool))
        assert agents.call_count == 2


def test_repeated_5xx_backs_off_exponentially(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    engine = _engine(pool, clock)
    delays = []
    with respx.mock(assert_all_called=False) as mock:
        mock.get(f"{A}/v1/agents").mock(return_value=httpx.Response(503))
        mock.get(f"{A}/v1/sessions").mock(return_value=httpx.Response(503))
        for _ in range(3):
            _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01", scheduled=True))
            state = pool.sync_state[("tenant-a", "conn-claude-01")]
            delays.append((state["next_poll_at"] - state["last_poll_at"]).total_seconds())
            clock.t = state["next_poll_at"]
    assert delays == [60.0, 120.0, 240.0]


def test_success_after_failure_resets_backoff_and_records_last_success(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    engine = _engine(pool, clock)
    with respx.mock(assert_all_called=False) as mock:
        mock.get(f"{A}/v1/agents").mock(return_value=httpx.Response(502))
        mock.get(f"{A}/v1/sessions").mock(return_value=httpx.Response(502))
        _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
    clock.advance(100)
    with respx.mock(assert_all_called=False) as mock:
        _mock_anthropic(mock, [[]], [])
        outcome = _run(engine.sync_connector(pool, "tenant-a", "conn-claude-01"))
    assert outcome.sync_state == {
        "mode": "poll", "last_poll_at": ras.iso(clock.t), "last_success_at": ras.iso(clock.t), "last_error": None,
        "next_poll_at": ras.iso(clock.t + timedelta(seconds=30)), "consecutive_failures": 0,
    }


def test_a_connector_locked_by_another_replica_is_not_polled(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    pool.held_elsewhere.add(("tenant-a", "conn-claude-01"))
    with respx.mock(assert_all_called=False) as mock:
        route = _mock_anthropic(mock, [[]], [])
        assert _run(_engine(pool, clock).tick(pool)) == []
    assert route.call_count == 0 and not pool.locks


def test_a_replica_follows_a_next_poll_another_replica_recorded(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    pool.sync_state[("tenant-a", "conn-claude-01")] = {
        "provider_id": "claude", "mode": "poll", "last_poll_at": T0, "last_success_at": T0, "last_error": None,
        "next_poll_at": T0 + timedelta(seconds=20), "consecutive_failures": 0,
    }
    with respx.mock(assert_all_called=False) as mock:
        route = _mock_anthropic(mock, [[]], [])
        engine = _engine(pool, clock)
        _run(engine.tick(pool))
        assert route.call_count == 0
        clock.advance(21)
        _run(engine.tick(pool))
        assert route.call_count == 1
    assert not pool.locks, "the advisory lock is released after every sync"


def test_disconnected_or_adapterless_connectors_are_not_polled(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"}),
                             ("tenant-a", "conn-github-01", "github", {"token": "x"})), Clock()
    pool.connectors[("tenant-a", "conn-claude-01")]["status"] = "disconnected"
    with respx.mock(assert_all_called=True):
        assert _run(_engine(pool, clock).tick(pool)) == []


def test_interval_env_has_a_floor(monkeypatch):
    monkeypatch.setenv("CONNECTOR_SYNC_INTERVAL_SECONDS", "1")
    assert ras.sync_interval_seconds() == 5
    monkeypatch.setenv("CONNECTOR_SYNC_INTERVAL_SECONDS", "45")
    assert ras.sync_interval_seconds() == 45
    monkeypatch.delenv("CONNECTOR_SYNC_INTERVAL_SECONDS")
    assert ras.sync_interval_seconds() == 30


# ---------------------------------------------------------------------------
# Tenant isolation
# ---------------------------------------------------------------------------

def test_each_tenant_sees_only_what_its_own_key_listed(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"}),
                             ("tenant-b", "conn-claude-01", "claude", {"api_key": "sk-b"})), Clock()
    bus = ras.RemoteAgentEventBus()

    def by_key(request: httpx.Request) -> httpx.Response:
        name = {"sk-a": "Alpha", "sk-b": "Bravo"}[request.headers["x-api-key"]]
        return httpx.Response(200, json={"data": [_agent(f"agent_{name}", name)], "next_page": None})

    with respx.mock(assert_all_called=False) as mock:
        mock.get(f"{A}/v1/agents").mock(side_effect=by_key)
        mock.get(f"{A}/v1/sessions").mock(return_value=httpx.Response(200, json={"data": [], "next_page": None}))
        _run(_engine(pool, clock, bus).tick(pool))
    assert [r["name"] for r in pool.agents("tenant-a")] == ["Alpha"]
    assert [r["name"] for r in pool.agents("tenant-b")] == ["Bravo"]
    for tenant, name in (("tenant-a", "Alpha"), ("tenant-b", "Bravo")):
        names = {e.data["agent"]["name"] for e in bus._rings[tenant] if e.event == "remote_agent.upserted"}
        assert names == {name}
    rows, _ = _run(ras.list_remote_agents(pool, "tenant-b", "conn-claude-01"))
    assert [r["name"] for r in rows] == ["Bravo"]


def test_every_store_statement_except_the_scheduler_is_tenant_scoped():
    for name in dir(ras):
        if not name.startswith("SQL_") or name in ("SQL_DUE", "SQL_LOCK", "SQL_UNLOCK"):
            continue
        assert "tenant_id = $1" in " ".join(getattr(ras, name).split()), name


# ---------------------------------------------------------------------------
# Streams
# ---------------------------------------------------------------------------

def test_a_running_session_stream_lands_a_status_change_before_the_next_poll(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()
    bus = ras.RemoteAgentEventBus()
    sse = (b": ping\n\n"
           b"event: message\ndata: {\"type\":\"agent.message\",\"id\":\"e1\"}\n\n"
           b"data: {\"type\":\"session.status_idle\",\"id\":\"e2\"}\n\n")

    async def scenario():
        engine = _engine(pool, clock, bus)
        with respx.mock(assert_all_called=False) as mock:
            _mock_anthropic(mock, [[]], [_session("sess_1", "running")])
            stream = mock.get(f"{A}/v1/sessions/sess_1/events/stream").mock(
                return_value=httpx.Response(200, content=sse, headers={"content-type": "text/event-stream"}))
            one = mock.get(f"{A}/v1/sessions/sess_1").mock(return_value=httpx.Response(200, json=_session("sess_1", "idle")))
            outcome = await engine.sync_connector(pool, "tenant-a", "conn-claude-01")
            assert outcome.sync_state["mode"] == "poll+stream"
            assert ("tenant-a", "conn-claude-01", "sess_1") in engine.stream_keys()
            for _ in range(200):
                if not engine.stream_keys():
                    break
                await asyncio.sleep(0.001)
            await engine.stop()
            return stream.call_count, one.call_count
    stream_calls, fetches = _run(scenario())
    assert stream_calls == 1 and fetches >= 1
    assert pool.agent("tenant-a", "sess_1")["status"] == "idle"
    statuses = [e.data["agent"]["status"] for e in bus._rings["tenant-a"] if e.event == "remote_agent.upserted"]
    assert statuses == ["running", "idle"]


def test_streams_per_tenant_are_bounded(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()

    async def scenario():
        engine = _engine(pool, clock, streams_per_tenant=2)
        never = asyncio.Event()

        async def hang(*_a, **_k):
            await never.wait()
            yield ""  # pragma: no cover

        engine.adapters = {"claude": ras.AnthropicAdapter()}
        engine.adapters["claude"].stream_status_events = hang  # type: ignore[method-assign]
        with respx.mock(assert_all_called=False) as mock:
            _mock_anthropic(mock, [[]], [_session(f"s{i}", "running") for i in range(5)])
            await engine.sync_connector(pool, "tenant-a", "conn-claude-01")
            count = len(engine.stream_keys())
            await engine.stop()
            return count, len(engine.stream_keys())
    assert _run(scenario()) == (2, 0)


def test_sse_parser_reads_data_type_and_event_names():
    async def lines():
        for line in ["event: session.status_running", "data: {}", "", ": c", "data: {\"type\":\"x\"}", "", "data: nope", ""]:
            yield line

    async def collect():
        return [t async for t in ras.parse_sse_types(lines())]
    assert _run(collect()) == ["session.status_running", "x"]


# ---------------------------------------------------------------------------
# OpenAI
# ---------------------------------------------------------------------------

def test_openai_sessions_follow_has_more_and_last_id(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-openai-01", "openai", {"api_key": "sk-o"})), Clock()
    with respx.mock(assert_all_called=False) as mock:
        route = mock.get(f"{O}/v1/agents/sessions")
        route.side_effect = [
            httpx.Response(200, json={"data": [{"id": "sess_a", "status": "idle", "last_active_at": 1760000000,
                                                "agent": {"id": "ag", "model": "gpt-6"}}], "has_more": True, "last_id": "sess_a"}),
            httpx.Response(200, json={"data": [{"id": "sess_b", "status": "in_progress", "agent": {"model": "gpt-6"}}],
                                      "has_more": False, "last_id": "sess_b"}),
        ]
        outcome = _run(_engine(pool, clock).sync_connector(pool, "tenant-a", "conn-openai-01"))
    assert route.calls[0].request.headers["OpenAI-Beta"] == "agents=v1"
    assert route.calls[1].request.url.params["after"] == "sess_a"
    assert outcome.counts == {"session": 2}
    a = pool.agent("tenant-a", "sess_a")
    assert (a["kind"], a["status"], a["model"], a["name"]) == ("session", "idle", "gpt-6", None)
    assert a["external_updated_at"] == datetime.fromtimestamp(1760000000, tz=timezone.utc)


def test_openai_rejecting_the_key_is_reported_not_invented(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-openai-01", "openai", {"api_key": "sk-admin-x"})), Clock()
    with respx.mock(assert_all_called=False) as mock:
        mock.get(f"{O}/v1/agents/sessions").mock(return_value=httpx.Response(403))
        outcome = _run(_engine(pool, clock).sync_connector(pool, "tenant-a", "conn-openai-01"))
    assert pool.agents("tenant-a") == []
    assert outcome.sync_state["mode"] == "poll" and "HTTP 403" in outcome.sync_state["last_error"]


# ---------------------------------------------------------------------------
# Event bus and the SSE frames
# ---------------------------------------------------------------------------

def test_an_event_for_tenant_a_is_never_delivered_to_tenant_b():
    bus = ras.RemoteAgentEventBus()

    async def scenario():
        frames_b: list[str] = []
        frames_a: list[str] = []

        async def never():
            return False

        async def read(tenant, out, n):
            async for f in ras.sse_frames(bus, tenant, None, never, heartbeat=0.01, max_events=n):
                out.append(f)

        tb = asyncio.create_task(read("tenant-b", frames_b, 1))
        ta = asyncio.create_task(read("tenant-a", frames_a, 1))
        await asyncio.sleep(0.005)
        bus.publish("tenant-a", "remote_agent.upserted", {"agent": {"name": "secret-a"}})
        await asyncio.wait_for(ta, 1)
        await asyncio.sleep(0.03)
        tb.cancel()
        return frames_a, frames_b
    frames_a, frames_b = _run(scenario())
    assert any("secret-a" in f for f in frames_a)
    assert not any("secret-a" in f for f in frames_b)
    assert ": heartbeat\n\n" in frames_b and frames_b[0] == "retry: 5000\n\n"


def test_last_event_id_replays_from_the_ring_or_asks_for_a_refetch():
    bus = ras.RemoteAgentEventBus(ring_size=3)
    for i in range(5):
        bus.publish("tenant-a", "remote_agent.upserted", {"n": i})
    sub, replay, complete = bus.subscribe("tenant-a", "3")
    assert [e.data["n"] for e in replay] == [3, 4] and complete
    sub.close()
    sub, replay, complete = bus.subscribe("tenant-a", "1")
    assert not complete
    sub.close()
    assert bus.subscriber_count("tenant-a") == 0

    async def frames():
        async def never():
            return False
        return [f async for f in ras.sse_frames(bus, "tenant-a", "1", never, max_events=3)]
    out = _run(frames())
    assert out[1] == "event: stream.reset\ndata: {}\n\n"
    assert out[2].startswith("id: 3\nevent: remote_agent.upserted\n")


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

def test_the_loop_starts_ticks_and_stops_without_leaking_tasks(key_env):
    pool, clock = _pool_with(("tenant-a", "conn-claude-01", "claude", {"api_key": "sk-a"})), Clock()

    async def scenario():
        engine = _engine(pool, clock)
        with respx.mock(assert_all_called=False) as mock:
            route = _mock_anthropic(mock, [[]], [])
            engine.start()
            for _ in range(200):
                if route.call_count:
                    break
                await asyncio.sleep(0.001)
            await engine.stop()
        others = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
        return route.call_count, engine.running, others
    calls, running, leaked = _run(scenario())
    assert calls >= 1 and not running and leaked == []


def test_fixture_mode_never_runs_the_loop():
    async def scenario():
        async def none():
            return None
        engine = ras.RemoteAgentSync(none, interval=30)
        engine.start()
        await asyncio.sleep(0.01)
        running = engine.running
        await engine.stop()
        return running
    assert _run(scenario()) is False
